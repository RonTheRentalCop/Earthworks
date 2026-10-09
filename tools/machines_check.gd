extends SceneTree
## Checks the two dozer blades, the grapple's grip and the mining excavator. Run:
##   godot --headless --path . -s tools/machines_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	main.hud.visible = false

	# --- Dozers: push 12 m with the blade a little down, then look beside and ahead.
	for kind in ["dozer", "dozer_angle"]:
		var d = main.spawn_vehicle(kind)
		var start := Vector3(-60, 0, 30)
		d.place(Transform3D(Basis.IDENTITY, start))
		await _frames(10)
		main.player.global_position = d.door_position()
		main._enter_machine(d)
		if kind == "dozer_angle":
			Input.action_press("swing_left")
			await _frames(70)
			Input.action_release("swing_left")
		Input.action_press("boom_down")
		await _frames(25)
		Input.action_release("boom_down")
		Input.action_press("drive_forward")
		await _frames(8 * 60)
		Input.action_release("drive_forward")
		await _frames(30)
		var left := 0.0
		var right := 0.0
		for k in 8:
			var z := start.z - 2.0 - k
			for x in range(2, 7):
				left += maxf(t.get_height(start.x - 2.4 - x * 0.5, z) - t.original_height(start.x - 2.4 - x * 0.5, z), 0.0)
				right += maxf(t.get_height(start.x + 2.4 + x * 0.5, z) - t.original_height(start.x + 2.4 + x * 0.5, z), 0.0)
		print("%-12s pushed %.1f m, blade %.1f/%.1f m3, spoil beside the cut: left %.2f right %.2f (sum of heights)" % [
			d.machine_name, d.global_position.distance_to(start), d.blade_load, d.capacity, left, right])
		main._exit_machine()
		main.despawn(d)
		await _frames(5)

	# --- Grapple: grab a log lying on the ground near its middle.
	var ex = main.excavator
	ex.place(Transform3D(Basis.IDENTITY, Vector3(-40, 0, 0)))
	while ex.attachment != 3:
		ex.cycle_attachment()
	await _frames(10)
	var log: RigidBody3D = main.forests.apply_event(5, "fell", main)
	await _frames(150)
	# Put the log across the ground in front of the machine, then bring the jaws down onto its middle.
	log.global_transform = Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(-40, t.get_height(-40, -7) + 0.4, -7) - Vector3(1.6, 0, 0))
	log.linear_velocity = Vector3.ZERO
	await _frames(60)
	var g: Array = log.get_meta("grip")
	var mid := log.to_global((g[0] + g[1]) * 0.5)
	var jaw: Vector3 = ex._grapple.to_global(ex.GRIP_CENTRE)
	print("log middle %s, jaws at %s" % [mid.snapped(Vector3.ONE * 0.1), jaw.snapped(Vector3.ONE * 0.1)])
	# Move the excavator so the jaws sit over the log's middle (simplest: slide the machine).
	ex.place(Transform3D(Basis.IDENTITY, Vector3(-40, 0, 0) + Vector3(mid.x - jaw.x, 0, mid.z - jaw.z)))
	await _frames(5)
	main.player.global_position = ex.door_position()
	main._enter_machine(ex)
	for i in 240:
		jaw = ex._grapple.to_global(ex.GRIP_CENTRE)
		mid = log.to_global((g[0] + g[1]) * 0.5)
		if jaw.y - mid.y < 0.25:
			break
		Input.action_press("boom_down")
		await _frames(1)
	Input.action_release("boom_down")
	Input.action_press("bucket_curl")
	await _frames(90)
	Input.action_release("bucket_curl")
	await _frames(30)
	var holding: bool = ex.held == log
	jaw = ex._grapple.to_global(ex.GRIP_CENTRE)
	var a: Vector3 = log.to_global(g[0])
	var b: Vector3 = log.to_global(g[1])
	var axis := (b - a).normalized()
	var off := (jaw - a) - axis * (jaw - a).dot(axis)
	var across := absf(axis.dot(ex._grapple.global_basis.x.normalized()))
	print("grapple holding the log: %s, jaws %.2f m from the trunk's centre line, trunk lies %.0f%% across the jaws" % [holding, off.length(), across * 100.0])
	Input.action_press("boom_up")
	await _frames(90)
	Input.action_release("boom_up")
	print("lifted: log now %.1f m off the ground" % (log.global_position.y - t.get_height(log.global_position.x, log.global_position.z)))
	main._exit_machine()

	# --- Mining excavator: fill the bucket from the borrow mound.
	var xl = main.spawn_vehicle("excavator_xl")
	var mound: Vector2 = main.BORROW_MOUND
	xl.place(Transform3D(Basis.IDENTITY, Vector3(mound.x, 0, mound.y + 19.0)))
	await _frames(10)
	main.player.global_position = xl.door_position()
	main._enter_machine(xl)
	for step in [["boom_down", 150], ["stick_out", 60], ["bucket_curl", 240], ["boom_up", 120]]:
		Input.action_press(step[0])
		await _frames(step[1])
		Input.action_release(step[0])
	print("%s: bucket %.1f / %.1f m3" % [xl.machine_name, xl.bucket_load, xl._capacity])
	quit()
