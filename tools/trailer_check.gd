extends SceneTree
## With the ramps up, loads ride strapped to the lowboy: logs and a dozer stay put
## through acceleration, a hard turn and a sudden stop, and come free (without jumping)
## when the ramps go down. Run:
##   godot --headless --path . -s tools/trailer_check.gd

var main
var t


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _drift(trailer, node: Node3D, local: Transform3D) -> float:
	return (trailer.global_transform * local).origin.distance_to(node.global_position)


func _tow(rec, label: String, trailer, items: Array) -> void:
	var locals := []
	for n in items:
		locals.append(trailer.global_transform.affine_inverse() * n.global_transform)
	trailer.toggle_ramps()  # up
	await _frames(150)
	var strapped := 0
	for n in items:
		if trailer.is_strapped(n):
			strapped += 1
	var start: Vector3 = trailer.global_position
	main.player.global_position = rec.door_position()
	main._enter_machine(rec)
	Input.action_press("drive_forward")
	await _frames(240)
	Input.action_press("turn_left")
	await _frames(150)
	Input.action_release("turn_left")
	Input.action_release("drive_forward")
	Input.action_press("drive_back")  # brake hard
	await _frames(90)
	Input.action_release("drive_back")
	await _frames(60)
	var worst := 0.0
	for k in items.size():
		worst = maxf(worst, _drift(trailer, items[k], locals[k]))
	print("%s: %d/%d strapped, towed %.0f m with a hard turn and stop, worst shift on the deck %.2f m" % [
		label, strapped, items.size(), trailer.global_position.distance_to(start), worst])
	main._exit_machine()
	var before := []
	for n in items:
		before.append(n.global_position)
	trailer.toggle_ramps()  # down: the straps come off
	await _frames(30)
	var jump := 0.0
	var free := 0
	for k in items.size():
		jump = maxf(jump, (items[k] as Node3D).global_position.distance_to(before[k]))
		if not trailer.is_strapped(items[k]) and not items[k].has_meta("strapped_to"):
			free += 1
	print("%s: ramps down, %d/%d released, biggest move on release %.2f m" % [label, free, items.size(), jump])
	await _frames(150)  # ramps fully down before the next load


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	t = main.terrain
	var trailer = main.trailer
	var rec = main.spawn_vehicle("recovery")
	rec.place(Transform3D(Basis(Vector3.UP, PI), Vector3(0, t.get_height(0, 50) + 0.4, 50)))
	await _frames(20)
	trailer.place_behind(rec.hitch_point(), rec.global_basis)
	await _frames(20)
	main.player.global_position = rec.door_position()
	main._enter_machine(rec)
	main._press_utility()
	main._exit_machine()
	print("trailer hitched: %s" % (trailer.towed_by == rec))
	# Three logs lying along the deck.
	var logs := []
	var tids := []
	for tid in main.forests.count():
		if main.forests.state[tid] == 0 and main.forests.size[tid] < 1.0:
			tids.append(tid)
			if tids.size() == 3:
				break
	for k in 3:
		var lg: RigidBody3D = main.forests.apply_event(tids[k], "fell", main)
		var deck: Vector3 = trailer.deck_centre()
		var across: Vector3 = trailer.global_basis.x.normalized()
		var along: Vector3 = trailer.global_basis.z.normalized()
		lg.global_transform = Transform3D(Basis(along.cross(Vector3.UP), Vector3.UP, along).orthonormalized() * Basis(Vector3.RIGHT, PI * 0.5), deck)
		var g: Array = lg.get_meta("grip")
		var mid: Vector3 = lg.to_global(((g[0] as Vector3) + (g[1] as Vector3)) * 0.5)
		lg.global_position += deck + across * (k - 1) * 0.8 + Vector3(0, 0.45, 0) - mid
		lg.linear_velocity = Vector3.ZERO
		logs.append(lg)
	await _frames(90)
	await _tow(rec, "logs", trailer, logs)
	for k in logs.size():  # off the trailer, out of the way
		var lg: RigidBody3D = logs[k]
		lg.global_position = Vector3(30.0 + k * 3.0, t.get_height(30.0 + k * 3.0, 60) + 1.0, 60)
		lg.linear_velocity = Vector3.ZERO
	await _frames(10)
	# Back to the start for the second load.
	rec.place(Transform3D(Basis(Vector3.UP, PI), Vector3(0, t.get_height(0, 50) + 0.4, 50)))
	trailer.place_behind(rec.hitch_point(), rec.global_basis)
	await _frames(30)
	# The dozer.
	var dozer = main.dozer
	dozer.place(Transform3D(trailer.global_basis.rotated(Vector3.UP, PI), trailer.deck_centre()))
	await _frames(60)
	await _tow(rec, "dozer", trailer, [dozer])
	quit()
