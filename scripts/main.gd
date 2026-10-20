extends Node
## Builds the menu/room UI and routes Realtime messages to the game.

const FONT_PATH := "res://fonts/NotoSansKR-Bold.otf"
const SETTINGS_PATH := "user://settings.cfg"
const Game := preload("res://scripts/game.gd")

var game
var font: Font
var ui: Control

var menu_box: Control
var name_edit: LineEdit
var room_edit: LineEdit
var join_btn: Button
var status_label: Label

var room_box: Control
var room_title: Label
var link_edit: LineEdit
var copy_info: Label
var members_label: Label
var bots_row: HBoxContainer
var bots_value: Label
var start_btn: Button
var wait_label: Label


func _ready() -> void:
	randomize()
	font = ThemeDB.fallback_font
	if ResourceLoader.exists(FONT_PATH):
		font = load(FONT_PATH)

	game = Game.new()
	game.font = font
	add_child(game)

	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new()
	th.default_font = font
	th.default_font_size = 18
	ui.theme = th
	layer.add_child(ui)

	_build_menu()
	_build_room()

	Net.status_changed.connect(func(t): status_label.text = t)
	Net.broadcast_received.connect(_on_broadcast)
	Net.joined.connect(_on_joined)

	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		name_edit.text = str(cfg.get_value("player", "name", ""))
	if name_edit.text == "":
		name_edit.text = "플레이어%d" % (randi() % 900 + 100)
	room_edit.text = _url_room()
	if room_edit.text == "":
		room_edit.text = _random_code()


func _make_box(width: float) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.offset_right = -290   # keep the HUD panel on the right visible
	ui.add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#1d2238f0")
	sb.border_color = Color("#4da3ff")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(16)
	sb.set_content_margin_all(26)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(width, 0)
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	return vb


func _label(text: String, size := 18, color := Color("#f2f4ff")) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _build_menu() -> void:
	var vb := _make_box(360)
	menu_box = vb.get_parent().get_parent() as Control
	vb.add_child(_label("크레이지 버블", 34, Color("#fff3a0")))
	vb.add_child(_label("물풍선으로 상대를 가두고 터뜨리세요. 혼자면 AI 봇과, 같은 방 코드로 들어온 친구와는 실시간으로 함께 합니다.", 14, Color("#9aa3c7")))
	vb.add_child(_label("닉네임", 15, Color("#9aa3c7")))
	name_edit = LineEdit.new()
	name_edit.max_length = 10
	vb.add_child(name_edit)
	vb.add_child(_label("방 코드", 15, Color("#9aa3c7")))
	room_edit = LineEdit.new()
	room_edit.max_length = 8
	vb.add_child(room_edit)
	join_btn = Button.new()
	join_btn.text = "입장하기"
	join_btn.custom_minimum_size = Vector2(0, 46)
	join_btn.pressed.connect(_on_join)
	room_edit.text_submitted.connect(func(_t): _on_join())
	vb.add_child(join_btn)
	status_label = _label("", 14, Color("#7fe3ff"))
	vb.add_child(status_label)


func _build_room() -> void:
	var vb := _make_box(360)
	room_box = vb.get_parent().get_parent() as Control
	room_title = _label("방", 28, Color("#fff3a0"))
	vb.add_child(room_title)
	vb.add_child(_label("친구에게 이 링크를 보내면 같은 방으로 들어옵니다", 14, Color("#9aa3c7")))
	var row := HBoxContainer.new()
	link_edit = LineEdit.new()
	link_edit.editable = false
	link_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	link_edit.add_theme_font_size_override("font_size", 13)
	row.add_child(link_edit)
	var copy_btn := Button.new()
	copy_btn.text = "복사"
	copy_btn.pressed.connect(_on_copy)
	row.add_child(copy_btn)
	vb.add_child(row)
	copy_info = _label("", 13, Color("#8ee06b"))
	vb.add_child(copy_info)

	members_label = _label("", 16)
	vb.add_child(members_label)

	bots_row = HBoxContainer.new()
	bots_row.add_theme_constant_override("separation", 10)
	var bl := _label("AI 봇", 16)
	bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bots_row.add_child(bl)
	var minus := Button.new()
	minus.text = " - "
	minus.pressed.connect(func(): _change_bots(-1))
	bots_row.add_child(minus)
	bots_value = _label("2", 18)
	bots_row.add_child(bots_value)
	var plus := Button.new()
	plus.text = " + "
	plus.pressed.connect(func(): _change_bots(1))
	bots_row.add_child(plus)
	vb.add_child(bots_row)

	start_btn = Button.new()
	start_btn.text = "게임 시작"
	start_btn.custom_minimum_size = Vector2(0, 46)
	start_btn.pressed.connect(_on_start)
	vb.add_child(start_btn)
	wait_label = _label("방장이 게임을 시작하길 기다리는 중...", 15, Color("#7fe3ff"))
	vb.add_child(wait_label)

	var leave_btn := Button.new()
	leave_btn.text = "나가기"
	leave_btn.pressed.connect(_on_leave)
	vb.add_child(leave_btn)


func _process(_delta: float) -> void:
	var in_room: bool = Net.in_room
	menu_box.visible = not in_room
	room_box.visible = in_room and game.phase == "lobby"
	if not room_box.visible:
		return
	var host: bool = Net.is_host()
	var ids: Array = Net.member_ids()
	var lines := PackedStringArray()
	for i in ids.size():
		var id: String = ids[i]
		var tag := ""
		if i == 0:
			tag = "  · 방장"
		if id == Net.my_id:
			tag += "  · 나"
		if i >= Game.MAX_PLAYERS:
			tag += "  · 관전"
		lines.append("● " + Net.name_of(id) + tag)
	members_label.text = "참가자 %d명\n" % ids.size() + "\n".join(lines)
	var max_bots := maxi(0, Game.MAX_PLAYERS - mini(ids.size(), Game.MAX_PLAYERS))
	game.bot_count = clampi(game.bot_count, 0, max_bots)
	bots_value.text = str(game.bot_count)
	bots_row.visible = host
	start_btn.visible = host
	wait_label.visible = not host


func _on_join() -> void:
	var player_name := name_edit.text.strip_edges()
	if player_name == "":
		status_label.text = "닉네임을 입력하세요"
		return
	var code := _clean_code(room_edit.text)
	if code == "":
		status_label.text = "방 코드는 영문/숫자로 입력하세요"
		return
	room_edit.text = code
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.save(SETTINGS_PATH)
	game.reset_local()
	Net.join_room(code, player_name)


func _on_joined() -> void:
	room_title.text = "방 " + Net.room
	link_edit.text = _invite_link()
	copy_info.text = ""
	ui.get_viewport().gui_release_focus()


func _on_leave() -> void:
	Net.leave()
	game.reset_local()
	status_label.text = ""


func _on_start() -> void:
	ui.get_viewport().gui_release_focus()
	game.host_start()


func _change_bots(d: int) -> void:
	if Net.is_host():
		game.bot_count += d


func _on_copy() -> void:
	DisplayServer.clipboard_set(link_edit.text)
	copy_info.text = "링크를 복사했습니다"


func _on_broadcast(event: String, payload: Dictionary) -> void:
	match event:
		"state":
			game.apply_snapshot(payload)
		"pos":
			game.on_pos(payload)
		"bomb":
			game.on_bomb_request(payload)


func _clean_code(s: String) -> String:
	var out := ""
	for ch in s.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out.substr(0, 8)


func _random_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var s := ""
	for i in 4:
		s += chars[randi() % chars.length()]
	return s


func _page_url() -> String:
	if OS.has_feature("web"):
		var u = JavaScriptBridge.eval("window.location.origin + window.location.pathname", true)
		if typeof(u) == TYPE_STRING:
			return u
	return "https://<배포-주소>/"


func _url_room() -> String:
	if OS.has_feature("web"):
		var r = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('room') || ''", true)
		if typeof(r) == TYPE_STRING:
			return _clean_code(r)
	return ""


func _invite_link() -> String:
	return _page_url() + "?room=" + Net.room
