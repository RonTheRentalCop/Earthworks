extends SceneTree
## The logging semi: carries a big load of logs strapped down with F at the back, and
## stays steady through a hard turn and stop. Run:
##   godot --headless --path . -s tools/semi_check.gd
var main
func _frames(n: int) -> void:
	for i in n:
		await physics_frame
func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var semi = main.spawn_vehicle("log_semi")
	semi.place(Transform3D(Basis(Vector3.UP, PI), Vector3(160, t.get_height(160, 200) + 0.6, 200)))
	main.player.global_position = semi.door_position()
	main._update_anchors()
	await _frames(60)
	print("SEMI mass %.0f kg, tilt %.1f deg at rest, wheels down %d/%d" % [semi.mass, rad_to_deg(semi.global_basis.y.angle_to(Vector3.UP)), semi._wheels.filter(func(w): return w.is_in_contact()).size(), semi._wheels.size()])
	# Fill the bed with logs.
	var logs := []
	var n := 0
	for tid in main.forests.count():
		if main.forests.state[tid] == 0 and main.forests.size[tid] > 0.9 and n < 14:
			logs.append(main.forests.apply_event(tid, "fell", main))
			n += 1
	await _frames(30)
	var along: Vector3 = semi.global_basis.z.normalized()
	for k in logs.size():
		var lg: RigidBody3D = logs[k]
		var bed_spot: Vector3 = semi._bed.to_global(Vector3(-1.4 + (k % 5) * 0.7, 0.6 + (k / 5) * 0.75, -5.3))
		lg.global_transform = Transform3D(Basis(along.cross(Vector3.UP), Vector3.UP, along).orthonormalized() * Basis(Vector3.RIGHT, PI * 0.5), bed_spot)
		var g: Array = lg.get_meta("grip")
		lg.global_position += bed_spot - lg.to_global((g[0] + g[1]) * 0.5)
		lg.linear_velocity = Vector3.ZERO
	await _frames(120)
	var on_bed := 0
	for lg in logs:
		var local: Vector3 = semi._bed.to_local(lg.global_position)
		if absf(local.x) < 2.2 and local.y > -0.5:
			on_bed += 1
	var mass := 0.0
	for lg in logs:
		mass += lg.mass
	print("SEMI %d/%d logs (%.1f t) loaded on the bed" % [on_bed, logs.size(), mass / 1000.0])
	# Strap it with F at the back (as on foot), then drive hard.
	var back: Vector3 = semi.ramp_point()
	main.player.global_position = Vector3(back.x, t.get_height(back.x, back.z) + 0.1, back.z)
	await _frames(10)
	Input.action_press("interact")
	await process_frame
	await process_frame
	Input.action_release("interact")
	await _frames(10)
	var strapped := 0
	for lg in logs:
		if semi.is_strapped(lg):
			strapped += 1
	print("SEMI pressed F at the back: %d/%d logs strapped" % [strapped, logs.size()])
	var locals := []
	for lg in logs:
		locals.append(semi._bed.global_transform.affine_inverse() * lg.global_transform)
	main.player.global_position = semi.door_position()
	main._enter_machine(semi)
	var tilt := 0.0
	var start: Vector3 = semi.global_position
	Input.action_press("drive_forward")
	for i in 300:
		await physics_frame
		tilt = maxf(tilt, rad_to_deg(semi.global_basis.y.angle_to(Vector3.UP)))
	print("SEMI after 5 s: strapped %d, ramps_down %s, log0 frozen %s, log0 meta %s" % [semi._strapped.size(), semi.ramps_down, logs[0].freeze, logs[0].get_meta("strapped_to", null) if logs[0].has_meta("strapped_to") else "none"])
	Input.action_press("turn_left")
	for i in 180:
		await physics_frame
		tilt = maxf(tilt, rad_to_deg(semi.global_basis.y.angle_to(Vector3.UP)))
	Input.action_release("turn_left")
	Input.action_release("drive_forward")
	Input.action_press("drive_back")
	await _frames(120)
	Input.action_release("drive_back")
	var shift := 0.0
	for k in logs.size():
		if semi.is_strapped(logs[k]):
			shift = maxf(shift, (semi._bed.global_transform * (locals[k] as Transform3D)).origin.distance_to(logs[k].global_position))
	print("SEMI drove %.0f m loaded with a hard turn and stop: max tilt %.1f deg, worst log shift %.2f m" % [semi.global_position.distance_to(start), tilt, shift])
	main._exit_machine()
	quit()
