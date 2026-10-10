extends SceneTree
## Water flows: a trench dug from the river to a pit fills, and how fast. Run:
##   godot --headless --path . -s tools/water_check.gd

var main


func _initialize() -> void:
	Engine.max_physics_steps_per_frame = 1
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var w = main.water
	# A river cell near the middle of the map, with dry land to the west of it.
	var river := Vector2.INF
	for z in range(-100, 260, 6):
		for x in range(-300, 400, 3):
			if w.depth_at(x, z) > 0.6 and w.depth_at(x - 24, z) <= 0.0 and not t.is_protected(x - 24, z):
				river = Vector2(x, z)
				break
		if river != Vector2.INF:
			break
	print("river at %s, water %.2f m deep" % [river, w.depth_at(river.x, river.y)])
	main.player.global_position = Vector3(river.x - 12, t.get_height(river.x - 12, river.y) + 1, river.y)
	main.camera.global_position = main.player.global_position + Vector3(0, 8, 8)
	main._update_anchors()
	for i in 30:
		await physics_frame
	# A trench 1.5 m below the river bed level, running 20 m west into a pit.
	var bed: float = t.get_height(river.x, river.y)
	for k in 42:
		var x := river.x - 2.0 - k * 0.5
		var target := bed - 0.4 - k * 0.01
		var guard := 0
		while t.get_height(x, river.y) > target and guard < 400:
			t.dig(Vector3(x, target, river.y), 1.3, 4.0)
			guard += 1
	# Let the trench walls settle, then cut it down again so it really is below the river.
	for i in 120:
		await physics_frame
	for k in 42:
		var x := river.x - 2.0 - k * 0.5
		var target := bed - 0.4 - k * 0.01
		var guard := 0
		while t.get_height(x, river.y) > target and guard < 200:
			t.dig(Vector3(x, target, river.y), 1.3, 4.0)
			guard += 1
	var pit := Vector2(river.x - 24, river.y)
	for k in 80:
		t.dig(Vector3(pit.x, bed - 1.2, pit.y), 2.5, 4.0)
	var dry := ""
	for k in range(0, 26, 4):
		dry += " %d:%.2f" % [k, t.get_height(river.x - k, river.y) - bed]
	print("  trench floor vs river bed before the water gets in:", dry)
	var t0 := Time.get_ticks_msec()
	var arrived := -1.0
	var worst := 0
	for f in 60 * 20:
		var s0 := Time.get_ticks_usec()
		await physics_frame
		worst = maxi(worst, Time.get_ticks_usec() - s0)
		if arrived < 0.0 and w.depth_at(pit.x, pit.y) > 0.15:
			arrived = f / 60.0
		if f % 600 == 599:
			print("  %d s: water at the trench middle %.2f m, in the pit %.2f m" % [(f + 1) / 60, w.depth_at(river.x - 12, river.y), w.depth_at(pit.x, pit.y)])
	var prof := ""
	for k in range(0, 26, 2):
		var x := river.x - k
		prof += " %d:%.2f/%.2f" % [k, w.depth_at(x, river.y), t.get_height(x, river.y) - bed]
	print("  along the trench (m from river: water depth / ground vs river bed):", prof)
	print("water reached the pit 24 m from the river after %s; worst frame %d ms" % ["%.1f s" % arrived if arrived >= 0.0 else "never (40 s)", worst / 1000])
	quit()
