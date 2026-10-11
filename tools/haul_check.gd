extends SceneTree
## The site clean-up, and the wide flatbed: a big dozer drives up its ramp, rides strapped
## and comes off again. Run:
##   godot --headless --path . -s tools/haul_check.gd

var main
var t


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _ore_count() -> int:
	var n := 0
	for id in main.bodies:
		var b = main.bodies[id]
		if is_instance_valid(b) and b.is_in_group("ore") and not b.is_queued_for_deletion():
			n += 1
	return n


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	t = main.terrain
	# --- Clean-up.
	for k in 3:
		main.spawn_ore("rock", Transform3D(Basis.IDENTITY, Vector3(40 + k * 2, t.get_height(40 + k * 2, 125) + 1, 125)))
	var stump_tid := -1
	for tid in main.forests.count():
		if main.forests.state[tid] == 0:
			stump_tid = tid
			break
	main.forests.apply_event(stump_tid, "fell", main)
	var pulled = main.forests.apply_event(stump_tid, "pulled", main)
	await _frames(10)
	print("clean-up: before %d loose rocks/ore, stump pulled %s" % [_ore_count(), is_instance_valid(pulled)])
	var removed: int = main.clean_up_site()
	await _frames(2)
	print("clean-up: removed %d, loose rocks/ore left %d, stump gone %s" % [removed, _ore_count(), not is_instance_valid(pulled)])
	# --- Wide flatbed: a big dozer drives up the ramp.
	var tractor = main.spawn_vehicle("haul")
	var flat = main.spawn_vehicle("flatbed")
	var base := Vector3(-40, 0, 140)
	tractor.place(Transform3D(Basis(Vector3.UP, PI), Vector3(base.x, t.get_height(base.x, base.z) + 0.5, base.z)))
	await _frames(20)
	flat.place_behind(tractor.hitch_point(), tractor.global_basis)
	await _frames(30)
	main.player.global_position = tractor.door_position()
	main._enter_machine(tractor)
	main._press_utility()
	main._exit_machine()
	print("flatbed: %s hitched %s, deck %.1f x %.1f m" % [flat.machine_name, flat.towed_by == tractor, flat._len, flat._wid])
	await _frames(60)
	var dozer = main.spawn_vehicle("dozer_xl")
	# Behind the ramp, facing up it.
	var away: Vector3 = (flat.ramp_point() - flat.deck_centre())
	away.y = 0.0
	away = away.normalized()
	var start: Vector3 = flat.ramp_point() + away * 7.0
	dozer.place(Transform3D(Basis.looking_at(-away, Vector3.UP), Vector3(start.x, t.get_height(start.x, start.z), start.z)))
	await _frames(30)
	main.player.global_position = dozer.door_position()
	main._enter_machine(dozer)
	Input.action_press("drive_forward")
	var climbed := false
	for f in 60 * 14:
		await _frames(1)
		if dozer.global_position.distance_to(flat.deck_centre()) < 2.0:
			climbed = true
			break
	Input.action_release("drive_forward")
	await _frames(90)
	main._exit_machine()
	var deck_y: float = flat.deck_centre().y
	print("flatbed: big dozer on the deck %s (%.1f m from the middle, tracks %.2f m above the deck)" % [
		climbed, dozer.global_position.distance_to(flat.deck_centre()), dozer.global_position.y - deck_y])
	flat.toggle_ramps()
	await _frames(150)
	var local0: Transform3D = flat.global_transform.affine_inverse() * dozer.global_transform
	main.player.global_position = tractor.door_position()
	main._enter_machine(tractor)
	Input.action_press("drive_forward")
	await _frames(300)
	Input.action_press("turn_left")
	await _frames(120)
	Input.action_release("turn_left")
	Input.action_release("drive_forward")
	Input.action_press("drive_back")
	await _frames(90)
	Input.action_release("drive_back")
	await _frames(60)
	main._exit_machine()
	var shift: float = (flat.global_transform * local0).origin.distance_to(dozer.global_position)
	print("flatbed: towed the big dozer strapped %s, shift on the deck %.2f m, trailer upright %.2f" % [
		flat.is_strapped(dozer), shift, flat.global_basis.y.dot(Vector3.UP)])
	quit()
