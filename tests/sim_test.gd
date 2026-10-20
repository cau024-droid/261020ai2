extends Node
## Headless check: godot --headless --path . res://tests/sim_test.tscn

const Game := preload("res://scripts/game.gd")


func _ready() -> void:
	await get_tree().process_frame
	var net = get_node("/root/Net")
	net.room = "TEST"
	var host = Game.new()
	host.font = ThemeDB.fallback_font
	add_child(host)
	var client = Game.new()
	client.font = ThemeDB.fallback_font
	add_child(client)
	host.set_process(false)
	client.set_process(false)

	var wins := {}
	for round in 4:
		host.bot_count = 3
		host.host_start()
		var steps := 0
		var placed := 0
		while host.phase == "playing" and steps < 60 * 200:
			var before: int = host.bombs.size()
			host.sim(1.0 / 60.0)
			placed += maxi(0, host.bombs.size() - before)
			steps += 1
			if steps % 6 == 0:
				var snap = JSON.parse_string(JSON.stringify(host.make_snapshot()))
				snap["_from"] = net.host_id()
				client.apply_snapshot(snap)
		var w: String = host.winner if host.winner == "draw" else host.players[host.winner].name
		wins[w] = wins.get(w, 0) + 1
		var blocks: int = host.map.count(Game.BLOCK)
		print("round %d: %s after %.1fs, blocks left %d, client players %d, client map ok %s" % [
			round + 1, w, steps / 60.0, blocks, client.players.size(), str(client.map == host.map)])
	print("results: ", wins)

	# Movement / collision sanity for a human player.
	host.host_start()
	var me = host.players[net.my_id]
	var sx: float = me.x
	for i in 60:
		host.move_player(me, Vector2i(1, 0), 1.0 / 60.0)
	print("human moved from x=%.2f to x=%.2f (blocked by crate expected <= %.2f)" % [sx, me.x, 2.0 - Game.R + 0.01])
	print("bomb placed: ", host.place_bomb(net.my_id, int(me.x), int(me.y)), ", second (max 1): ", host.place_bomb(net.my_id, int(me.x), int(me.y)))
	get_tree().quit()
