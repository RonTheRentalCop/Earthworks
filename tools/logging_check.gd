extends SceneTree
## The logging semi pulls a train of two log trailers (hitched one behind the other),
## a strapped load of logs rides on the first, and the hitch button drops the last one.
## Run:  godot --headless --path . -s tools/logging_check.gd

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
	var a = main.spawn_vehicle("log_trailer")
	var b = main.spawn_vehicle("log_trailer")
	semi.place(Transform3D(Basis(Vector3.UP, PI), Vector3(60, t.get_height(60, 130) + 0.6, 130)))
	main.player.global_position = semi.door_position()
	main._update_anchors()
	await _frames(30)
	main._enter_machine(semi)
	a.place_behind(semi.hitch_point(), semi.global_basis)
	await _frames(20)
	main._press_utility()
	b.place_behind(a.rear_hitch_point(), a.global_basis)
	await _frames(20)
	main._press_utility()
	print("train: semi -> %s -> %s" % [semi.trailer.machine_name if semi.trailer else "nothing", a.rear.machine_name if a.rear else "nothing"])
	# Logs on the first trailer, strapped down.
	var logs := []
	var tids := []
	for tid in main.forests.count():
		if main.forests.state[tid] == 0 and main.forests.size[tid] < 1.0:
			tids.append(tid)
			if tids.size() == 3:
				break
	for k in 3:
		var lg: RigidBody3D = main.forests.apply_event(tids[k], "fell", main)
		var along: Vector3 = a.global_basis.z.normalized()
		var deck: Vector3 = a.deck_centre()
		lg.global_transform = Transform3D(Basis(along.cross(Vector3.UP), Vector3.UP, along).orthonormalized() * Basis(Vector3.RIGHT, PI * 0.5), deck)
		var g: Array = lg.get_meta("grip")
		lg.global_position += deck + a.global_basis.x.normalized() * (k - 1) * 0.75 + Vector3(0, 0.6, 0) - lg.to_global((g[0] + g[1]) * 0.5)
		lg.linear_velocity = Vector3.ZERO
		logs.append(lg)
	await _frames(90)
	a.toggle_ramps()  # strap the load
	await _frames(10)
	var strapped := 0
	for lg in logs:
		if a.is_strapped(lg):
			strapped += 1
	var locals := []
	for lg in logs:
		locals.append(a.global_transform.affine_inverse() * lg.global_transform)
	var start: Vector3 = b.global_position
	Input.action_press("drive_forward")
	await _frames(300)
	Input.action_press("turn_left")
	await _frames(180)
	Input.action_release("turn_left")
	Input.action_release("drive_forward")
	await _frames(120)
	var gap_a: float = semi.hitch_point().distance_to(a.hitch_point())
	var gap_b: float = a.rear_hitch_point().distance_to(b.hitch_point())
	var shift := 0.0
	for k in logs.size():
		shift = maxf(shift, (a.global_transform * (locals[k] as Transform3D)).origin.distance_to(logs[k].global_position))
	print("drove: last trailer moved %.0f m; hitch gaps %.2f m and %.2f m; %d/3 logs strapped, worst shift %.2f m" % [
		b.global_position.distance_to(start), gap_a, gap_b, strapped, shift])
	main._press_utility()
	print("hitch button with nothing behind: semi -> %s -> %s" % [semi.trailer.machine_name if semi.trailer else "nothing",
		a.rear.machine_name if a.rear else "nothing"])
	quit()
