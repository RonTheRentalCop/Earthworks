extends SceneTree
## Ratchet straps and rope: a log strapped onto a dump truck rides with it (made with the
## real key presses on foot), a roped log is dragged along behind, a log strapped to a
## tree stays put, and cutting lets each one go. Run:
##   godot --headless --path . -s tools/ties_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _tap(action: String) -> void:
	Input.action_press(action)
	await process_frame
	await process_frame
	Input.action_release(action)
	await process_frame


func _log(index: int) -> RigidBody3D:
	var n := 0
	for tid in main.forests.count():
		if main.forests.state[tid] == 0 and main.forests.size[tid] < 1.0:
			if n == index:
				return main.forests.apply_event(tid, "fell", main)
			n += 1
	return null


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var truck = main.truck
	truck.place(Transform3D(Basis(Vector3.UP, PI), Vector3(-40, t.get_height(-40, 40) + 0.4, 40)))
	main.player.global_position = Vector3(-36, t.get_height(-36, 40) + 1, 40)
	main._update_anchors()
	await _frames(40)
	# 1. A log lying in the truck's body, strapped on with G at the log then G at the truck.
	var lg := _log(0)
	var bed_mid: Vector3 = truck._bed.to_global(Vector3(0, 0.6, -truck._bed_half.y))
	lg.global_transform = Transform3D(truck.global_basis * Basis(Vector3.RIGHT, PI * 0.5), bed_mid)
	var g: Array = lg.get_meta("grip")
	lg.global_position += bed_mid - lg.to_global((g[0] + g[1]) * 0.5)
	lg.linear_velocity = Vector3.ZERO
	await _frames(60)
	var near_log: Vector3 = lg.to_global((g[0] + g[1]) * 0.5) + truck.global_basis.x.normalized() * 1.9
	main.player.global_position = Vector3(near_log.x, t.get_height(near_log.x, near_log.z) + 0.1, near_log.z)
	await _frames(10)
	await _tap("strap")
	await _frames(5)
	await _tap("strap")  # the truck's right there too: nearest new thing
	await _frames(5)
	var tied: int = main.ties.ties.size()
	var local: Transform3D = truck.global_transform.affine_inverse() * lg.global_transform
	main.player.global_position = truck.door_position()
	main._enter_machine(truck)
	Input.action_press("drive_forward")
	await _frames(240)
	Input.action_press("turn_left")
	await _frames(120)
	Input.action_release("turn_left")
	Input.action_release("drive_forward")
	await _frames(90)
	var drift: float = (truck.global_transform * local).origin.distance_to(lg.global_position)
	print("strap: %d tie(s) made with the keys, log shifted %.2f m on the truck through a drive and turn" % [tied, drift])
	main._exit_machine()
	var id: int = main.ties.ties[0].id if tied > 0 else -1
	main.ties.cut(id)
	await _frames(30)
	print("cut: log free %s, ties left %d" % [not lg.freeze, main.ties.ties.size()])
	# 2. A log on the ground roped behind the truck, dragged along.
	var dragged := _log(1)
	var back: Vector3 = truck.hitch_point()
	dragged.global_transform = Transform3D(Basis(Vector3.FORWARD, PI * 0.5), back + truck.global_basis.z.normalized() * 4.0 + Vector3(0, 0.3, 0))
	dragged.linear_velocity = Vector3.ZERO
	await _frames(60)
	var dg: Array = dragged.get_meta("grip")
	print(main.ties.tie("rope", truck, back, dragged, dragged.to_global(dg[0])))
	var start: Vector3 = dragged.global_position
	main.player.global_position = truck.door_position()
	main._enter_machine(truck)
	Input.action_press("drive_forward")
	await _frames(300)
	Input.action_release("drive_forward")
	await _frames(60)
	main._exit_machine()
	print("rope: log dragged %.1f m behind the truck" % dragged.global_position.distance_to(start))
	# 3. A log strapped to a standing tree stays put when shoved.
	var tree: Node3D = null
	for tid in main.forests.live:
		tree = main.forests.live[tid]
		if is_instance_valid(tree) and not tree.is_stump:
			break
	if tree:
		var held := _log(2)
		held.global_position = tree.global_position + Vector3(1.2, 0.5, 0)
		held.linear_velocity = Vector3.ZERO
		await _frames(30)
		print(main.ties.tie("strap", held, held.global_position, tree, tree.global_position + Vector3(0, 1, 0)))
		var at: Vector3 = held.global_position
		held.apply_central_impulse(Vector3(0, 0, 4000))
		await _frames(60)
		print("tree strap: log moved %.2f m when shoved" % held.global_position.distance_to(at))
	quit()
