extends SceneTree
## Dev tool: orthographic side close-up of a model with a 10 cm grid, for locating pivots.
## Usage: godot --path . -s tools/zoom_model.gd -- res://m.glb out.png cy cz size [name_filter,...]

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var model := (load(a[0]) as PackedScene).instantiate() as Node3D
	root.add_child(model)
	await process_frame
	var filters := a[5].split(",") if a.size() > 5 else PackedStringArray()
	var palette := [Color.RED, Color.GREEN, Color.BLUE, Color.ORANGE, Color.MAGENTA, Color.CYAN, Color.YELLOW, Color.PURPLE]
	var k := 0
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var keep := filters.is_empty()
		for f in filters:
			if f in String(m.get_parent().name):
				keep = true
		m.visible = keep
		if keep:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = palette[k % palette.size()]
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color.a = 1.0
			m.material_override = mat
			print(k, " ", m.get_parent().name, "/", m.name, " -> ", palette[k % palette.size()].to_html(false))
			k += 1
	var cy := float(a[2])
	var cz := float(a[3])
	var size := float(a[4])
	# grid lines every 10 cm (thicker every 50 cm), drawn just beside the model
	var im := ImmediateMesh.new()
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.vertex_color_use_as_albedo = true
	im.surface_begin(Mesh.PRIMITIVE_LINES, gm)
	var steps := int(size / 0.1) + 2
	var y0 := snappedf(cy - size, 0.1)
	var z0 := snappedf(cz - size, 0.1)
	for i in steps * 2:
		var y := y0 + i * 0.1
		var z := z0 + i * 0.1
		var col := Color(0.2, 0.2, 0.2) if is_zero_approx(fmod(absf(y) + 0.001, 0.5)) or fmod(absf(y) + 0.001, 0.5) < 0.01 else Color(0.6, 0.6, 0.6)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(-3, y, z0))
		im.surface_add_vertex(Vector3(-3, y, z0 + size * 2))
		col = Color(0.2, 0.2, 0.2) if fmod(absf(z) + 0.001, 0.5) < 0.01 else Color(0.6, 0.6, 0.6)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(-3, y0, z))
		im.surface_add_vertex(Vector3(-3, y0 + size * 2, z))
	im.surface_end()
	var grid := MeshInstance3D.new()
	grid.mesh = im
	root.add_child(grid)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.WHITE
	root.add_child(env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size
	cam.far = 100
	root.add_child(cam)
	root.size = Vector2i(900, 900)
	cam.global_position = Vector3(20, cy, cz)
	cam.look_at(Vector3(0, cy, cz), Vector3.UP)
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(a[1])
	quit()
