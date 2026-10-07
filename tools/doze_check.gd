extends SceneTree
## Dev check: shallow blade cut over a long push, then back off and photograph the strip.
## Usage: godot --path . -s tools/doze_check.gd -- out.png
var main
func _press(action: String, seconds: float) -> void:
	Input.action_press(action)
	for i in int(seconds * 60):
		await physics_frame
	Input.action_release(action)

func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	root.size = Vector2i(1600, 900)
	for i in 30:
		await process_frame
	var dozer = main.dozer
	dozer.place(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-48, 0, 118)))
	main.player.global_position = dozer.door_position()
	main._enter_machine(dozer)
	main.hud.visible = false
	var start_h: float = main.terrain.get_height(-54, 118)
	await _press("boom_down", 0.3)
	Input.action_press("drive_forward")
	var last: Vector3 = dozer.global_position
	for i in int(12.0 * 60):
		await physics_frame
		if i % 60 == 59:
			print("t=%2ds  speed %.2f m/s  %s" % [(i + 1) / 60, dozer.global_position.distance_to(last), dozer.status()])
			last = dozer.global_position
	Input.action_release("drive_forward")
	await _press("boom_up", 1.2)
	await _press("drive_back", 3.0)
	# Sample the graded strip's profile along its length.
	var samples := []
	for k in 10:
		var x := -56.0 - k * 2.5
		samples.append(snappedf(main.terrain.get_height(x, 118) - main.terrain.get_height(x, 123.5), 0.01))
	print("strip depth below the untouched ground beside it (m): ", samples)
	var ridge := []
	for k in 6:
		var x := -58.0 - k * 4.0
		ridge.append(snappedf(main.terrain.get_height(x, 120.1) - main.terrain.get_height(x, 123.5), 0.01))
	print("windrow height beside the strip (m): ", ridge)
	var cam: Camera3D = main.camera
	cam.set_process(false)
	var p: Vector3 = dozer.global_position
	cam.global_position = p + Vector3(-6, 15, 12)
	cam.look_at(p + Vector3(9, 0, 0))
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
	quit()
