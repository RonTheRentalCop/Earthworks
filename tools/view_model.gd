extends SceneTree
## Dev tool: perspective render of a model from any position.
## Usage: godot --path . -s tools/view_model.gd -- res://m.glb out.png tx,ty,tz cx,cy,cz fov

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var model := (load(a[0]) as PackedScene).instantiate() as Node3D
	root.add_child(model)
	await process_frame
	var t := a[2].split_floats(",")
	var c := a[3].split_floats(",")
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.8, 0.85, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.5
	root.add_child(env)
	var cam := Camera3D.new()
	cam.fov = float(a[4])
	root.add_child(cam)
	root.size = Vector2i(900, 900)
	cam.global_position = Vector3(c[0], c[1], c[2])
	cam.look_at(Vector3(t[0], t[1], t[2]), Vector3.UP)
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(a[1])
	quit()
