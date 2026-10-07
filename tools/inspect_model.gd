extends SceneTree
## Dev tool: prints every mesh's global AABB and renders labelled views of a model.
## Usage: godot --path . -s tools/inspect_model.gd -- res://models/x.glb out_dir

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var scene: PackedScene = load(args[0])
	var model := scene.instantiate() as Node3D
	root.add_child(model)
	await process_frame
	var tint := args.size() > 2
	var colors := [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.MAGENTA, Color.CYAN, Color.ORANGE,
		Color.PURPLE, Color.WHITE, Color.BLACK, Color.PINK, Color.BROWN, Color.LIME, Color.NAVY_BLUE]
	var k := 0
	var total := AABB()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var box := m.global_transform * m.get_aabb()
		total = box if k == 0 else total.merge(box)
		if tint:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = colors[k % colors.size()]
			m.material_override = mat
		print("%-45s parent=%-25s col=%-8s pos=%s size=%s" % [m.name, m.get_parent().name, k, box.position.snapped(Vector3.ONE*0.01), box.size.snapped(Vector3.ONE*0.01)])
		k += 1
	print("TOTAL ", total)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -30, 0)
	root.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.85, 0.85, 0.85)
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.6
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	root.add_child(env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(total.size.y, total.size.z) * 1.15
	root.add_child(cam)
	root.size = Vector2i(1200, 900)
	var c := total.get_center()
	var views := {"side": [c + Vector3(30, 0, 0), Vector3.UP], "top": [c + Vector3(0, 30, 0), Vector3.FORWARD], "front": [c + Vector3(0, 0, -30), Vector3.UP]}
	for v in views:
		cam.global_position = views[v][0]
		cam.look_at(c, views[v][1])
		for i in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(args[1] + "/" + v + ".png")
	quit()
