extends Node
## Renders the real UI and saves screenshots to .tools/ (manual visual check).

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.tools/" + name + ".png")

func _ready() -> void:
	var main = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 20: await get_tree().process_frame
	await _shot("shot_menu")
	var net = get_node("/root/Net")
	net.room = "AB12"
	net.my_name = "나"
	net.in_room = true
	main._on_joined()
	for i in 10: await get_tree().process_frame
	await _shot("shot_room")
	main.game.host_start()
	for i in 240: await get_tree().process_frame
	await _shot("shot_game")
	get_tree().quit()
