extends Node2D
## Board simulation and rendering.
## The room host (earliest member) is authoritative for the map, bombs, flames,
## items, bots and deaths, and broadcasts a snapshot ~10x/sec. Every client moves
## its own character locally and broadcasts its position.

const W := 15
const H := 13
const TILE := 46.0
const ORIGIN := Vector2(22, 21)
const R := 0.36                 # player half-size in tiles
const BOMB_TIME := 2.6
const FLAME_TIME := 0.55
const TRAP_TIME := 3.2
const ROUND_TIME := 180.0
const OVER_TIME := 4.5
const MAX_PLAYERS := 4

const EMPTY := 0
const WALL := 1
const BLOCK := 2
const IT_BOMB := 3
const IT_RANGE := 4
const IT_SPEED := 5

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const SPAWNS := [Vector2i(0, 0), Vector2i(14, 12), Vector2i(14, 0), Vector2i(0, 12)]
const KEYMAP := {
	KEY_LEFT: Vector2i(-1, 0), KEY_A: Vector2i(-1, 0),
	KEY_RIGHT: Vector2i(1, 0), KEY_D: Vector2i(1, 0),
	KEY_UP: Vector2i(0, -1), KEY_W: Vector2i(0, -1),
	KEY_DOWN: Vector2i(0, 1), KEY_S: Vector2i(0, 1),
}
const COLORS := [Color("#ff5d73"), Color("#4da3ff"), Color("#ffc93c"), Color("#8ee06b")]
const BOT_NAMES := ["봇 몽실", "봇 콩이", "봇 두부"]

const C_FLOOR_A := Color("#9fd8b8")
const C_FLOOR_B := Color("#93cdac")
const C_FRAME := Color("#2b3350")
const C_WALL := Color("#56648a")
const C_WALL_TOP := Color("#7584ab")
const C_BLOCK := Color("#d99a5b")
const C_BLOCK_EDGE := Color("#a96f39")
const C_BOMB := Color("#2f7de1")
const C_FLAME := Color("#7fe3ff")
const C_TEXT := Color("#f2f4ff")
const C_MUTED := Color("#9aa3c7")


class Player:
	var id := ""
	var name := ""
	var color := 0
	var x := 0.5
	var y := 0.5
	var alive := true
	var trap := 0.0
	var mb := 1          # max bombs
	var rg := 1          # blast range
	var sp := 1          # speed level
	var bot := false
	var dir := Vector2i(0, 1)
	var kills := 0
	var dx := 0.5        # display position (smoothed)
	var dy := 0.5
	var path: Array = []
	var think_t := 0.0


class Bomb:
	var x := 0
	var y := 0
	var t := 0.0
	var r := 1
	var o := ""


class Flame:
	var x := 0
	var y := 0
	var t := 0.0
	var item := 0


var font: Font
var phase := "lobby"            # lobby, playing, over
var round_id := 0
var map: Array = []
var bombs: Array = []
var flames: Array = []
var players := {}
var time_left := 0.0
var winner := ""
var bot_count := 2
var over_timer := 0.0
var remote_pos := {}            # id -> [x, y, recv_time]

var _snap_timer := 0.0
var _pos_timer := 0.0
var _last_sent := Vector2(-99, -99)
var _last_dir_key := -1
var _clock := 0.0
var _touch_id := -1
var _touch_origin := Vector2.ZERO
var _touch_vec := Vector2.ZERO
var _touch_used := false

var _sb_wall := StyleBoxFlat.new()
var _sb_block := StyleBoxFlat.new()
var _sb_panel := StyleBoxFlat.new()
var _sb_frame := StyleBoxFlat.new()


func _ready() -> void:
	_sb_wall.bg_color = C_WALL
	_sb_wall.set_corner_radius_all(8)
	_sb_wall.border_color = C_WALL_TOP
	_sb_wall.border_width_top = 6
	_sb_block.bg_color = C_BLOCK
	_sb_block.set_corner_radius_all(6)
	_sb_block.border_color = C_BLOCK_EDGE
	_sb_block.set_border_width_all(3)
	_sb_panel.bg_color = Color("#262d4a")
	_sb_panel.set_corner_radius_all(14)
	_sb_frame.bg_color = C_FRAME
	_sb_frame.set_corner_radius_all(12)
	gen_map()


func reset_local() -> void:
	phase = "lobby"
	players.clear()
	bombs.clear()
	flames.clear()
	remote_pos.clear()
	winner = ""
	gen_map()


# ---------------------------------------------------------------- grid helpers

func idx(x: int, y: int) -> int:
	return y * W + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < W and y < H


func tile(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return WALL
	return map[idx(x, y)]


func bomb_at(x: int, y: int):
	for b in bombs:
		if b.x == x and b.y == y:
			return b
	return null


func cell_of(p) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))


func flame_set() -> Dictionary:
	var s := {}
	for f in flames:
		s[Vector2i(f.x, f.y)] = true
	return s


func gen_map() -> void:
	map.resize(W * H)
	for y in H:
		for x in W:
			if x % 2 == 1 and y % 2 == 1:
				map[idx(x, y)] = WALL
			else:
				map[idx(x, y)] = BLOCK if randf() < 0.7 else EMPTY
	for s in SPAWNS:
		for d in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: Vector2i = s + d
			if in_bounds(c.x, c.y) and map[idx(c.x, c.y)] != WALL:
				map[idx(c.x, c.y)] = EMPTY


func blast_tiles(bx: int, by: int, r: int) -> Array:
	var out := [Vector2i(bx, by)]
	for d in DIRS:
		for i in range(1, r + 1):
			var x: int = bx + d.x * i
			var y: int = by + d.y * i
			var t := tile(x, y)
			if t == WALL:
				break
			out.append(Vector2i(x, y))
			if t == BLOCK:
				break
	return out


# ---------------------------------------------------------------- movement

func speed_of(p) -> float:
	return 3.2 + 0.55 * float(p.sp - 1)


func overlaps(px: float, py: float, tx: int, ty: int) -> bool:
	return px + R > tx and px - R < tx + 1 and py + R > ty and py - R < ty + 1


func tile_blocks(p, tx: int, ty: int) -> bool:
	if not in_bounds(tx, ty):
		return true
	var t: int = map[idx(tx, ty)]
	if t == WALL or t == BLOCK:
		return true
	if bomb_at(tx, ty) != null:
		# You can walk off a balloon you are standing on, but not back onto one.
		return not overlaps(p.x, p.y, tx, ty)
	return false


func box_blocked(p, nx: float, ny: float) -> bool:
	for tx in range(floori(nx - R), floori(nx + R) + 1):
		for ty in range(floori(ny - R), floori(ny + R) + 1):
			if tile_blocks(p, tx, ty):
				return true
	return false


func move_player(p, d: Vector2i, dt: float) -> void:
	if d == Vector2i.ZERO:
		return
	p.dir = d
	var dist := speed_of(p) * dt
	if d.x != 0:
		if not box_blocked(p, p.x + d.x * dist, p.y):
			p.x += d.x * dist
		else:
			# Corner assist: slide toward a lane that is open ahead.
			var lane := floorf(p.y) + 0.5
			var off: float = p.y - lane
			if absf(off) > 0.01 and not box_blocked(p, p.x + d.x * dist, lane):
				p.y = move_toward(p.y, lane, dist)
			elif absf(off) > 0.2:
				var other := lane + signf(off)
				if not box_blocked(p, p.x + d.x * dist, other):
					p.y = move_toward(p.y, other, dist)
	else:
		if not box_blocked(p, p.x, p.y + d.y * dist):
			p.y += d.y * dist
		else:
			var lane := floorf(p.x) + 0.5
			var off: float = p.x - lane
			if absf(off) > 0.01 and not box_blocked(p, lane, p.y + d.y * dist):
				p.x = move_toward(p.x, lane, dist)
			elif absf(off) > 0.2:
				var other := lane + signf(off)
				if not box_blocked(p, other, p.y + d.y * dist):
					p.x = move_toward(p.x, other, dist)


func move_axis(p, d: Vector2i, amt: float) -> bool:
	p.dir = d
	var nx: float = p.x + d.x * amt
	var ny: float = p.y + d.y * amt
	if box_blocked(p, nx, ny):
		return false
	p.x = nx
	p.y = ny
	return true


func step_toward(p, tgt: Vector2, dt: float) -> bool:
	var step := speed_of(p) * dt
	var ddx: float = tgt.x - p.x
	var ddy: float = tgt.y - p.y
	var ax := absf(ddx)
	var ay := absf(ddy)
	if ax > 0.001 and ay > 0.001:
		if ax < ay:
			return move_axis(p, Vector2i(1 if ddx > 0 else -1, 0), minf(step, ax))
		return move_axis(p, Vector2i(0, 1 if ddy > 0 else -1), minf(step, ay))
	if ax > 0.001:
		return move_axis(p, Vector2i(1 if ddx > 0 else -1, 0), minf(step, ax))
	if ay > 0.001:
		return move_axis(p, Vector2i(0, 1 if ddy > 0 else -1), minf(step, ay))
	return true


# ---------------------------------------------------------------- frame loop

func _process(delta: float) -> void:
	_clock += delta
	var host: bool = Net.is_host()
	var me = players.get(Net.my_id)

	if phase == "playing" and me != null and me.alive and me.trap <= 0.0:
		move_player(me, read_dir(), delta)

	if Net.in_room and host:
		host_tick(delta)
	else:
		for b in bombs:
			b.t = maxf(0.0, b.t - delta)

	if Net.in_room and phase == "playing" and me != null and not host:
		_pos_timer -= delta
		var cur := Vector2(me.x, me.y)
		if _pos_timer <= 0.0 and (cur != _last_sent or _pos_timer < -0.5):
			_pos_timer = 0.1
			_last_sent = cur
			Net.send("pos", {"id": Net.my_id, "x": snapped(me.x, 0.001), "y": snapped(me.y, 0.001),
				"dx": me.dir.x, "dy": me.dir.y, "rd": round_id})

	var k := minf(1.0, 16.0 * delta)
	for p in players.values():
		if p.id == Net.my_id or absf(p.dx - p.x) + absf(p.dy - p.y) > 2.5:
			p.dx = p.x
			p.dy = p.y
		else:
			p.dx = lerpf(p.dx, p.x, k)
			p.dy = lerpf(p.dy, p.y, k)
	queue_redraw()


func host_tick(delta: float) -> void:
	_snap_timer -= delta
	if phase == "playing":
		sim(delta)
	elif phase == "over":
		over_timer -= delta
		if over_timer <= 0.0:
			phase = "lobby"
			_snap_timer = 0.0
	if _snap_timer <= 0.0:
		_snap_timer = 0.1 if phase == "playing" else 0.5
		Net.send("state", make_snapshot())


func sim(delta: float) -> void:
	time_left -= delta

	# Humans who left the room are out.
	for p in players.values():
		if not p.bot and p.alive and p.id != Net.my_id and not Net.presences.has(p.id):
			p.alive = false
			p.trap = 0.0

	for p in players.values():
		if p.bot:
			bot_update(p, delta)

	for b in bombs:
		b.t -= delta
	var fset := flame_set()
	for b in bombs:
		if fset.has(Vector2i(b.x, b.y)):
			b.t = 0.0
	var again := true
	while again:
		again = false
		for b in bombs:
			if b.t <= 0.0:
				explode(b)
				again = true
				break

	for f in flames.duplicate():
		f.t -= delta
		if f.t <= 0.0:
			flames.erase(f)
			if f.item > 0 and map[idx(f.x, f.y)] == EMPTY and bomb_at(f.x, f.y) == null:
				map[idx(f.x, f.y)] = f.item

	fset = flame_set()
	for p in players.values():
		if not p.alive:
			continue
		var c := cell_of(p)
		if p.trap <= 0.0:
			if fset.has(c):
				p.trap = TRAP_TIME
				p.path = []
			elif in_bounds(c.x, c.y) and map[idx(c.x, c.y)] >= IT_BOMB:
				pickup(p, map[idx(c.x, c.y)])
				map[idx(c.x, c.y)] = EMPTY
		else:
			p.trap -= delta
			if p.trap <= 0.0:
				p.alive = false
				p.trap = 0.0

	# Touching a trapped rival pops their bubble.
	for p in players.values():
		if not (p.alive and p.trap > 0.0):
			continue
		for q in players.values():
			if q != p and q.alive and q.trap <= 0.0 and Vector2(p.x, p.y).distance_to(Vector2(q.x, q.y)) < 0.75:
				p.alive = false
				p.trap = 0.0
				q.kills += 1
				break

	check_end()


func pickup(p, item: int) -> void:
	match item:
		IT_BOMB:
			p.mb = mini(p.mb + 1, 6)
		IT_RANGE:
			p.rg = mini(p.rg + 1, 7)
		IT_SPEED:
			p.sp = mini(p.sp + 1, 5)


func add_flame(x: int, y: int, item := 0) -> void:
	for f in flames:
		if f.x == x and f.y == y:
			f.t = FLAME_TIME
			f.item = maxi(f.item, item)
			return
	var f := Flame.new()
	f.x = x
	f.y = y
	f.t = FLAME_TIME
	f.item = item
	flames.append(f)


func roll_item() -> int:
	if randf() > 0.38:
		return 0
	var r := randf()
	if r < 0.4:
		return IT_BOMB
	if r < 0.75:
		return IT_RANGE
	return IT_SPEED


func explode(b) -> void:
	bombs.erase(b)
	add_flame(b.x, b.y)
	for d in DIRS:
		for i in range(1, b.r + 1):
			var x: int = b.x + d.x * i
			var y: int = b.y + d.y * i
			var t := tile(x, y)
			if t == WALL:
				break
			if t == BLOCK:
				map[idx(x, y)] = EMPTY
				add_flame(x, y, roll_item())
				break
			if t >= IT_BOMB:
				map[idx(x, y)] = EMPTY
			add_flame(x, y)
			var other = bomb_at(x, y)
			if other != null:
				other.t = 0.0
				break


func check_end() -> void:
	var alive := []
	for p in players.values():
		if p.alive:
			alive.append(p)
	if alive.is_empty():
		end_round("draw")
	elif alive.size() == 1 and alive[0].trap <= 0.0 and players.size() > 1:
		end_round(alive[0].id)
	elif time_left <= 0.0:
		end_round("draw")


func end_round(w: String) -> void:
	phase = "over"
	winner = w
	over_timer = OVER_TIME
	_snap_timer = 0.0


func host_start() -> void:
	if not Net.is_host() or phase == "playing":
		return
	round_id += 1
	gen_map()
	players.clear()
	bombs.clear()
	flames.clear()
	remote_pos.clear()
	var ids: Array = Net.member_ids().slice(0, MAX_PLAYERS)
	var nb := clampi(bot_count, 0, MAX_PLAYERS - ids.size())
	if ids.size() + nb < 2:
		nb = 1
	var order := [0, 1, 2, 3]
	order.shuffle()
	var i := 0
	for id in ids:
		_spawn(str(id), Net.name_of(str(id)), false, i, order[i])
		i += 1
	for k in nb:
		_spawn("bot%d" % k, BOT_NAMES[k], true, i, order[i])
		i += 1
	time_left = ROUND_TIME
	winner = ""
	phase = "playing"
	_snap_timer = 0.0


func _spawn(id: String, pname: String, is_bot: bool, color: int, spawn: int) -> void:
	var p := Player.new()
	p.id = id
	p.name = pname
	p.bot = is_bot
	p.color = color
	var s: Vector2i = SPAWNS[spawn]
	p.x = s.x + 0.5
	p.y = s.y + 0.5
	p.dx = p.x
	p.dy = p.y
	p.dir = Vector2i(0, 1)
	players[id] = p


func place_bomb(id: String, x: int, y: int) -> bool:
	var p = players.get(id)
	if phase != "playing" or p == null or not p.alive or p.trap > 0.0:
		return false
	if not in_bounds(x, y):
		return false
	var t: int = map[idx(x, y)]
	if t == WALL or t == BLOCK:
		return false
	if absf(p.x - (x + 0.5)) > 1.2 or absf(p.y - (y + 0.5)) > 1.2:
		return false
	if bomb_at(x, y) != null:
		return false
	var n := 0
	for b in bombs:
		if b.o == id:
			n += 1
	if n >= p.mb:
		return false
	var b := Bomb.new()
	b.x = x
	b.y = y
	b.t = BOMB_TIME
	b.r = p.rg
	b.o = id
	bombs.append(b)
	return true


func request_bomb() -> void:
	var me = players.get(Net.my_id)
	if phase != "playing" or me == null or not me.alive or me.trap > 0.0:
		return
	var c := cell_of(me)
	if Net.is_host():
		place_bomb(Net.my_id, c.x, c.y)
	elif bomb_at(c.x, c.y) == null:
		Net.send("bomb", {"id": Net.my_id, "x": c.x, "y": c.y})


# ---------------------------------------------------------------- network sync

func make_snapshot() -> Dictionary:
	var ps := {}
	for id in players:
		var p = players[id]
		ps[id] = [p.name, p.color, snapped(p.x, 0.001), snapped(p.y, 0.001), p.alive,
			snapped(p.trap, 0.01), p.mb, p.rg, p.sp, p.bot, p.dir.x, p.dir.y, p.kills]
	var bs := []
	for b in bombs:
		bs.append([b.x, b.y, snapped(b.t, 0.01), b.r, b.o])
	var fs := []
	for f in flames:
		fs.append([f.x, f.y, snapped(f.t, 0.01), f.item])
	var m := ""
	for v in map:
		m += str(v)
	return {"ph": phase, "rd": round_id, "m": m, "b": bs, "f": fs, "p": ps,
		"tl": snapped(time_left, 0.1), "w": winner, "bc": bot_count, "ot": snapped(over_timer, 0.1)}


func apply_snapshot(s: Dictionary) -> void:
	if str(s.get("_from", "")) != Net.host_id():
		return
	var rd := int(s.get("rd", 0))
	var new_round := rd != round_id
	phase = str(s.get("ph", "lobby"))
	round_id = rd
	time_left = float(s.get("tl", 0.0))
	winner = str(s.get("w", ""))
	bot_count = int(s.get("bc", 2))
	over_timer = float(s.get("ot", 0.0))

	var ms := str(s.get("m", ""))
	if ms.length() == W * H:
		for i in W * H:
			map[i] = ms.unicode_at(i) - 48

	bombs = []
	for a in s.get("b", []):
		var b := Bomb.new()
		b.x = int(a[0])
		b.y = int(a[1])
		b.t = float(a[2])
		b.r = int(a[3])
		b.o = str(a[4])
		bombs.append(b)
	flames = []
	for a in s.get("f", []):
		var f := Flame.new()
		f.x = int(a[0])
		f.y = int(a[1])
		f.t = float(a[2])
		f.item = int(a[3])
		flames.append(f)

	var ps: Dictionary = s.get("p", {})
	var now := Time.get_ticks_msec() / 1000.0
	for id in players.keys():
		if not ps.has(id):
			players.erase(id)
	for id in ps:
		var a = ps[id]
		var p = players.get(id)
		var fresh: bool = p == null
		if fresh:
			p = Player.new()
			p.id = str(id)
			players[id] = p
		p.name = str(a[0])
		p.color = int(a[1])
		p.alive = bool(a[4])
		p.trap = float(a[5])
		p.mb = int(a[6])
		p.rg = int(a[7])
		p.sp = int(a[8])
		p.bot = bool(a[9])
		p.kills = int(a[12])
		var sx := float(a[2])
		var sy := float(a[3])
		if id == Net.my_id:
			if fresh or new_round:
				p.x = sx
				p.y = sy
		else:
			var rp = remote_pos.get(id)
			if rp != null and now - float(rp[2]) < 0.6 and not new_round:
				p.x = float(rp[0])
				p.y = float(rp[1])
			else:
				p.x = sx
				p.y = sy
				p.dir = Vector2i(int(a[10]), int(a[11]))
		if fresh or new_round:
			p.dx = p.x
			p.dy = p.y
			p.path = []


func on_pos(d: Dictionary) -> void:
	if int(d.get("rd", -1)) != round_id:
		return
	var id := str(d.get("id", ""))
	if id == Net.my_id:
		return
	var x := float(d.get("x", 0.5))
	var y := float(d.get("y", 0.5))
	remote_pos[id] = [x, y, Time.get_ticks_msec() / 1000.0]
	var p = players.get(id)
	if p != null and p.alive and p.trap <= 0.0:
		p.x = clampf(x, R, W - R)
		p.y = clampf(y, R, H - R)
		p.dir = Vector2i(int(d.get("dx", 0)), int(d.get("dy", 1)))


func on_bomb_request(d: Dictionary) -> void:
	if Net.is_host():
		place_bomb(str(d.get("id", "")), int(d.get("x", -1)), int(d.get("y", -1)))


# ---------------------------------------------------------------- bots

func walkable(c: Vector2i, start: Vector2i, fset: Dictionary) -> bool:
	if not in_bounds(c.x, c.y):
		return false
	var t: int = map[idx(c.x, c.y)]
	if t == WALL or t == BLOCK:
		return false
	if c != start and bomb_at(c.x, c.y) != null:
		return false
	return not fset.has(c)


func bfs(start: Vector2i, goal: Callable, avoid: Dictionary, fset: Dictionary, max_depth: int):
	var prev := {start: start}
	var depth := {start: 0}
	var q := [start]
	var head := 0
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		if goal.call(c):
			var path := []
			var k := c
			while k != start:
				path.push_front(k)
				k = prev[k]
			return path
		if depth[c] >= max_depth:
			continue
		var dirs := DIRS.duplicate()
		dirs.shuffle()
		for d in dirs:
			var n: Vector2i = c + d
			if prev.has(n) or avoid.has(n) or not walkable(n, start, fset):
				continue
			prev[n] = c
			depth[n] = depth[c] + 1
			q.append(n)
	return null


func danger_map() -> Dictionary:
	var dm := {}
	for b in bombs:
		for c in blast_tiles(b.x, b.y, b.r):
			dm[c] = true
	for f in flames:
		dm[Vector2i(f.x, f.y)] = true
	return dm


func bomb_count(id: String) -> int:
	var n := 0
	for b in bombs:
		if b.o == id:
			n += 1
	return n


func good_bomb_spot(p, c: Vector2i) -> bool:
	for t in blast_tiles(c.x, c.y, p.rg):
		if tile(t.x, t.y) == BLOCK:
			return true
		for q in players.values():
			if q != p and q.alive and q.trap <= 0.0 and cell_of(q) == t:
				return true
	return false


func trapped_rival_at(p, c: Vector2i) -> bool:
	for q in players.values():
		if q != p and q.alive and q.trap > 0.0 and cell_of(q) == c:
			return true
	return false


func bot_goal(p, cur: Vector2i, c: Vector2i) -> bool:
	if c == cur:
		return false
	return tile(c.x, c.y) >= IT_BOMB or trapped_rival_at(p, c) or good_bomb_spot(p, c)


func bot_think(p) -> void:
	var cur := cell_of(p)
	var fset := flame_set()
	var danger := danger_map()

	if danger.has(cur):
		var esc = bfs(cur, func(c): return not danger.has(c), {}, fset, 14)
		p.path = esc if esc != null else []
		return

	if bomb_count(p.id) < p.mb and randf() < 0.85 and good_bomb_spot(p, cur):
		var d2 := danger.duplicate()
		for c in blast_tiles(cur.x, cur.y, p.rg):
			d2[c] = true
		var esc = bfs(cur, func(c): return not d2.has(c), {}, fset, 7)
		if esc != null and esc.size() > 0 and place_bomb(p.id, cur.x, cur.y):
			p.path = esc
			return

	var path = bfs(cur, func(c): return bot_goal(p, cur, c), danger, fset, 30)
	if path != null and path.size() > 0:
		p.path = path.slice(0, 4)
		return
	# Nothing to do: wander one safe step.
	var opts := []
	for d in DIRS:
		var n: Vector2i = cur + d
		if walkable(n, cur, fset) and not danger.has(n):
			opts.append(n)
	p.path = [opts.pick_random()] if opts.size() > 0 and randf() < 0.5 else []


func bot_update(p, dt: float) -> void:
	if not p.alive or p.trap > 0.0:
		return
	p.think_t -= dt
	if p.think_t <= 0.0 or p.path.is_empty():
		p.think_t = randf_range(0.18, 0.32)
		bot_think(p)
	if p.path.size() > 0:
		var nxt: Vector2i = p.path[0]
		var tgt := Vector2(nxt.x + 0.5, nxt.y + 0.5)
		if absf(tgt.x - p.x) < 0.002 and absf(tgt.y - p.y) < 0.002:
			p.path.pop_front()
		elif not step_toward(p, tgt, dt):
			p.path = []
			p.think_t = 0.05
	else:
		var c := cell_of(p)
		step_toward(p, Vector2(c.x + 0.5, c.y + 0.5), dt)


# ---------------------------------------------------------------- input

func read_dir() -> Vector2i:
	if _touch_id >= 0 and _touch_vec.length() > 16.0:
		if absf(_touch_vec.x) > absf(_touch_vec.y):
			return Vector2i(1 if _touch_vec.x > 0 else -1, 0)
		return Vector2i(0, 1 if _touch_vec.y > 0 else -1)
	if _last_dir_key != -1 and Input.is_physical_key_pressed(_last_dir_key):
		return KEYMAP[_last_dir_key]
	for key in KEYMAP:
		if Input.is_physical_key_pressed(key):
			return KEYMAP[key]
	return Vector2i.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.physical_keycode
		if k == KEY_SPACE or k == KEY_ENTER:
			request_bomb()
		elif KEYMAP.has(k):
			_last_dir_key = k
	elif event is InputEventScreenTouch:
		_touch_used = true
		if event.pressed:
			if event.position.x < 512.0 and _touch_id < 0:
				_touch_id = event.index
				_touch_origin = event.position
				_touch_vec = Vector2.ZERO
			elif event.position.x >= 512.0:
				request_bomb()
		elif event.index == _touch_id:
			_touch_id = -1
			_touch_vec = Vector2.ZERO
	elif event is InputEventScreenDrag and event.index == _touch_id:
		_touch_vec = event.position - _touch_origin


# ---------------------------------------------------------------- drawing

func px(x: float, y: float) -> Vector2:
	return ORIGIN + Vector2(x, y) * TILE


func _text(pos: Vector2, s: String, size: int, col: Color, width := -1.0, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(font, pos, s, align, width, size, col)


func _draw() -> void:
	var board := Rect2(ORIGIN - Vector2(8, 8), Vector2(W, H) * TILE + Vector2(16, 16))
	_sb_frame.draw(get_canvas_item(), board)

	for y in H:
		for x in W:
			var r := Rect2(px(x, y), Vector2(TILE, TILE))
			draw_rect(r, C_FLOOR_A if (x + y) % 2 == 0 else C_FLOOR_B)

	for f in flames:
		var c := px(f.x + 0.5, f.y + 0.5)
		var s := TILE * (0.46 + 0.04 * sin(_clock * 30.0))
		draw_rect(Rect2(c - Vector2(s, s), Vector2(s, s) * 2), Color(C_FLAME, 0.85))
		draw_circle(c, TILE * 0.26, Color("#e9fbff"))

	for y in H:
		for x in W:
			var t: int = map[idx(x, y)]
			var r := Rect2(px(x, y), Vector2(TILE, TILE)).grow(-2)
			if t == WALL:
				_sb_wall.draw(get_canvas_item(), r)
			elif t == BLOCK:
				_sb_block.draw(get_canvas_item(), r)
				draw_line(r.position + Vector2(6, r.size.y / 2), r.end - Vector2(6, r.size.y / 2), C_BLOCK_EDGE, 2)
			elif t >= IT_BOMB:
				_draw_item(px(x + 0.5, y + 0.5 + 0.05 * sin(_clock * 4.0 + x)), t)

	for b in bombs:
		var c := px(b.x + 0.5, b.y + 0.5)
		var pulse := 1.0 + 0.08 * sin(_clock * (8.0 + 10.0 * (1.0 - b.t / BOMB_TIME)))
		var rad := TILE * 0.36 * pulse
		draw_circle(c + Vector2(0, rad * 0.8), rad * 0.6, Color(0, 0, 0, 0.18))
		draw_circle(c, rad, C_BOMB)
		draw_circle(c + Vector2(-rad * 0.35, -rad * 0.35), rad * 0.28, Color(1, 1, 1, 0.65))
		draw_circle(c + Vector2(0, -rad - 2), 4.0, Color("#1f5fb5"))

	var sorted := players.values()
	sorted.sort_custom(func(a, b): return a.dy < b.dy)
	for p in sorted:
		if p.alive:
			_draw_player(p)

	_draw_hud()
	_draw_overlay()
	if _touch_used and phase == "playing":
		_draw_touch()


func _draw_item(c: Vector2, t: int) -> void:
	var bg: Color = {IT_BOMB: Color("#3b5bdb"), IT_RANGE: Color("#f59f00"), IT_SPEED: Color("#e8590c")}[t]
	draw_circle(c, TILE * 0.34, Color(1, 1, 1, 0.9))
	draw_circle(c, TILE * 0.29, bg)
	match t:
		IT_BOMB:
			draw_circle(c + Vector2(0, 2), 8.0, Color("#a5d8ff"))
			_text(c + Vector2(-12, -2), "+", 14, Color.WHITE, 24, HORIZONTAL_ALIGNMENT_CENTER)
		IT_RANGE:
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -11), c + Vector2(7, 2), c + Vector2(-7, 2)]), Color("#e7f5ff"))
			draw_circle(c + Vector2(0, 3), 7.0, Color("#e7f5ff"))
		IT_SPEED:
			draw_colored_polygon(PackedVector2Array([c + Vector2(3, -11), c + Vector2(-6, 2), c + Vector2(0, 2),
				c + Vector2(-3, 11), c + Vector2(6, -2), c + Vector2(0, -2)]), Color("#fff3bf"))


func _draw_player(p) -> void:
	var c := px(p.dx, p.dy)
	var col: Color = COLORS[p.color % COLORS.size()]
	var bob := sin(_clock * 10.0 + p.color) * 1.5
	draw_circle(c + Vector2(0, TILE * 0.32), TILE * 0.2, Color(0, 0, 0, 0.18))
	draw_circle(c + Vector2(0, 5 + bob * 0.3), TILE * 0.27, col)
	draw_circle(c + Vector2(0, -6 + bob), TILE * 0.25, Color("#ffe3c9"))
	draw_arc(c + Vector2(0, -6 + bob), TILE * 0.25, PI, TAU, 16, col.darkened(0.15), 7.0)
	var e := Vector2(p.dir.x, p.dir.y) * 3.0
	draw_circle(c + Vector2(-5, -6 + bob) + e, 2.6, Color("#222"))
	draw_circle(c + Vector2(5, -6 + bob) + e, 2.6, Color("#222"))
	if p.trap > 0.0:
		var wob := 1.0 + 0.05 * sin(_clock * 12.0)
		draw_circle(c, TILE * 0.56 * wob, Color(0.65, 0.92, 1.0, 0.42))
		draw_arc(c, TILE * 0.56 * wob, 0, TAU, 32, Color(1, 1, 1, 0.8), 2.0)
		draw_circle(c + Vector2(-9, -11), 4.0, Color(1, 1, 1, 0.8))
		_text(c + Vector2(-30, TILE * 0.62 + 12), "%.1f" % p.trap, 13, Color.WHITE, 60, HORIZONTAL_ALIGNMENT_CENTER)
	var name_col := Color("#fff3a0") if p.id == Net.my_id else Color.WHITE
	_text(c + Vector2(-50, -TILE * 0.55), p.name, 13, name_col, 100, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_hud() -> void:
	var x0 := ORIGIN.x + W * TILE + 22
	var panel := Rect2(Vector2(x0, 13), Vector2(1024 - x0 - 14, 614))
	_sb_panel.draw(get_canvas_item(), panel)
	var x := x0 + 18
	var y := 52.0
	_text(Vector2(x, y), "크레이지 버블", 24, C_TEXT)
	y += 26
	_text(Vector2(x, y), "방 코드  " + (Net.room if Net.room != "" else "-"), 15, C_MUTED)
	y += 36
	if phase == "playing" or phase == "over":
		var tl := maxi(0, int(ceil(time_left)))
		_text(Vector2(x, y), "남은 시간  %d:%02d" % [tl / 60, tl % 60], 18, C_TEXT)
	else:
		_text(Vector2(x, y), "대기실", 18, C_TEXT)
	y += 30

	var list := players.values()
	list.sort_custom(func(a, b): return a.color < b.color)
	for p in list:
		var col: Color = COLORS[p.color % COLORS.size()]
		var dim := 1.0 if p.alive else 0.4
		draw_circle(Vector2(x + 8, y + 12), 8.0, Color(col, dim))
		var label: String = p.name + ("  (나)" if p.id == Net.my_id else "")
		_text(Vector2(x + 24, y + 18), label, 16, Color(C_TEXT, dim), 190)
		var status := "탈락" if not p.alive else ("갇힘!" if p.trap > 0.0 else "")
		if status != "":
			_text(Vector2(x + 24, y + 18), status, 14, Color("#ff8fa3") if not p.alive else Color("#7fe3ff"),
				panel.end.x - x - 40, HORIZONTAL_ALIGNMENT_RIGHT)
		_text(Vector2(x + 24, y + 40), "풍선 %d · 물줄기 %d · 속도 %d" % [p.mb, p.rg, p.sp], 13, Color(C_MUTED, dim))
		y += 58

	var hy := panel.end.y - 92
	_text(Vector2(x, hy), "이동  방향키 / WASD", 14, C_MUTED)
	_text(Vector2(x, hy + 22), "물풍선  Space", 14, C_MUTED)
	_text(Vector2(x, hy + 44), "갇힌 상대를 건드리면 터뜨립니다", 13, C_MUTED)
	_text(Vector2(x, hy + 64), "모바일  왼쪽 드래그 이동 · 오른쪽 탭", 13, C_MUTED)


func _draw_overlay() -> void:
	var center := ORIGIN + Vector2(W, H) * TILE * 0.5
	if phase == "over":
		draw_rect(Rect2(center - Vector2(240, 60), Vector2(480, 120)), Color(0.1, 0.12, 0.22, 0.88))
		var msg := "무승부!"
		if winner != "draw" and players.has(winner):
			msg = players[winner].name + " 승리!"
		_text(center + Vector2(-240, 4), msg, 36, Color("#fff3a0"), 480, HORIZONTAL_ALIGNMENT_CENTER)
		_text(center + Vector2(-240, 40), "잠시 후 대기실로 돌아갑니다", 15, C_MUTED, 480, HORIZONTAL_ALIGNMENT_CENTER)
	elif phase == "playing":
		var me = players.get(Net.my_id)
		var note := ""
		if me == null:
			note = "관전 중 · 다음 판부터 참가합니다"
		elif not me.alive:
			note = "탈락했습니다 · 관전 중"
		if note != "":
			draw_rect(Rect2(Vector2(center.x - 200, ORIGIN.y + 6), Vector2(400, 34)), Color(0.1, 0.12, 0.22, 0.8))
			_text(Vector2(center.x - 200, ORIGIN.y + 29), note, 16, C_TEXT, 400, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_touch() -> void:
	if _touch_id >= 0:
		draw_circle(_touch_origin, 56.0, Color(1, 1, 1, 0.12))
		draw_circle(_touch_origin + _touch_vec.limit_length(56.0), 24.0, Color(1, 1, 1, 0.3))
