extends Node
## Supabase Realtime client (Phoenix channel protocol over WebSocketPeer).
## Uses Broadcast for game messages and Presence for the room member list.

signal status_changed(text: String)
signal joined
signal presence_changed
signal broadcast_received(event: String, payload: Dictionary)

const SUPABASE_URL := "https://bxtfhadwhteljgzmuecy.supabase.co"
# Public anon key (safe to ship in a client; only Realtime broadcast/presence is used).
const SUPABASE_KEY := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ4dGZoYWR3aHRlbGpnem11ZWN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0MzQ3MjIsImV4cCI6MjEwODAxMDcyMn0.Y6RQSJhLSch6exLWpH03vNKHkn6ISp61onpqIwt8nIg"
const HEARTBEAT_SEC := 25.0
const RETRY_SEC := 2.0

var my_id := ""
var my_name := ""
var joined_at := 0
var room := ""
var in_room := false        # joined and received the first presence state
var presences := {}         # id -> meta {id, name, t}

var _ws := WebSocketPeer.new()
var _topic := ""
var _ref := 0
var _join_ref := ""
var _state := "idle"        # idle, connecting, joining, joined, retry
var _hb_timer := 0.0
var _retry_timer := 0.0


func _ready() -> void:
	randomize()
	my_id = "%08x%04x" % [randi(), randi() % 65536]


func join_room(room_code: String, player_name: String) -> void:
	leave()
	room = room_code
	my_name = player_name
	joined_at = int(Time.get_unix_time_from_system() * 1000.0)
	_topic = "realtime:crazy-bubble-" + room
	_open_socket()


func leave() -> void:
	if _state == "joined":
		_push(_topic, "phx_leave", {})
	if _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	_state = "idle"
	room = ""
	in_room = false
	presences.clear()


func send(event: String, payload: Dictionary) -> void:
	if _state != "joined":
		return
	payload["_from"] = my_id
	_push(_topic, "broadcast", {"type": "broadcast", "event": event, "payload": payload})


func member_ids() -> Array:
	## Room members sorted by join time (earliest first). Always includes self.
	var list := []
	var seen_self := false
	for id in presences:
		list.append([int(presences[id].get("t", 0)), str(id)])
		if id == my_id:
			seen_self = true
	if not seen_self and room != "":
		list.append([joined_at, my_id])
	list.sort()
	var out := []
	for e in list:
		out.append(e[1])
	return out


func host_id() -> String:
	var ids := member_ids()
	return my_id if ids.is_empty() else str(ids[0])


func is_host() -> bool:
	return host_id() == my_id


func name_of(id: String) -> String:
	if id == my_id:
		return my_name
	if presences.has(id):
		return str(presences[id].get("name", "?"))
	return "?"


func _open_socket() -> void:
	var url := SUPABASE_URL.replace("https://", "wss://") + "/realtime/v1/websocket?apikey=" + SUPABASE_KEY + "&vsn=1.0.0"
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 18
	_ws.outbound_buffer_size = 1 << 18
	var err := _ws.connect_to_url(url)
	if err != OK:
		status_changed.emit("서버 연결 실패 (%d)" % err)
		_state = "retry"
		_retry_timer = RETRY_SEC
		return
	_state = "connecting"
	status_changed.emit("서버에 연결하는 중...")


func _process(delta: float) -> void:
	if _state == "idle":
		return
	if _state == "retry":
		_retry_timer -= delta
		if _retry_timer <= 0.0 and room != "":
			_open_socket()
		return

	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if _state == "connecting":
			_send_join()
		while _ws.get_available_packet_count() > 0:
			_handle(_ws.get_packet().get_string_from_utf8())
		_hb_timer -= delta
		if _hb_timer <= 0.0:
			_hb_timer = HEARTBEAT_SEC
			_push("phoenix", "heartbeat", {})
	elif st == WebSocketPeer.STATE_CLOSED:
		in_room = false
		_state = "retry"
		_retry_timer = RETRY_SEC
		status_changed.emit("연결이 끊겼습니다. 다시 연결하는 중...")


func _send_join() -> void:
	_state = "joining"
	_hb_timer = HEARTBEAT_SEC
	var cfg := {
		"broadcast": {"self": false, "ack": false},
		"presence": {"key": my_id},
		"private": false,
	}
	_join_ref = ""
	_join_ref = _push(_topic, "phx_join", {"config": cfg, "access_token": SUPABASE_KEY})
	status_changed.emit("방에 입장하는 중...")


func _push(topic: String, event: String, payload: Dictionary) -> String:
	_ref += 1
	var msg := {"topic": topic, "event": event, "payload": payload, "ref": str(_ref)}
	if topic != "phoenix":
		msg["join_ref"] = _join_ref if _join_ref != "" else str(_ref)
	_ws.send_text(JSON.stringify(msg))
	return str(_ref)


func _handle(text: String) -> void:
	var msg = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var event := str(msg.get("event", ""))
	var payload = msg.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}
	match event:
		"phx_reply":
			if str(msg.get("ref", "")) == _join_ref and _state == "joining":
				if str(payload.get("status", "")) == "ok":
					_state = "joined"
					_push(_topic, "presence", {"type": "presence", "event": "track",
						"payload": {"id": my_id, "name": my_name, "t": joined_at}})
					status_changed.emit("입장 완료")
				else:
					status_changed.emit("입장 실패: " + JSON.stringify(payload.get("response", {})))
		"presence_state":
			presences.clear()
			for key in payload:
				_add_presence(str(key), payload[key])
			if not in_room:
				in_room = true
				joined.emit()
			presence_changed.emit()
		"presence_diff":
			var joins = payload.get("joins", {})
			var leaves = payload.get("leaves", {})
			for key in leaves:
				presences.erase(str(key))
			for key in joins:
				_add_presence(str(key), joins[key])
			if not in_room:
				in_room = true
				joined.emit()
			presence_changed.emit()
		"broadcast":
			var inner = payload.get("payload", {})
			if typeof(inner) == TYPE_DICTIONARY:
				broadcast_received.emit(str(payload.get("event", "")), inner)
		"phx_error", "phx_close":
			if _state == "joined" or _state == "joining":
				in_room = false
				_ws.close()
				_state = "retry"
				_retry_timer = RETRY_SEC
				status_changed.emit("채널 오류. 다시 연결하는 중...")


func _add_presence(key: String, entry) -> void:
	if typeof(entry) != TYPE_DICTIONARY:
		return
	var metas = entry.get("metas", [])
	if typeof(metas) == TYPE_ARRAY and metas.size() > 0 and typeof(metas[0]) == TYPE_DICTIONARY:
		presences[key] = metas[0]
