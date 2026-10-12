extends SceneTree
## The wheel-less machines (forge, portable shredder, rollers, conveyor) drive up a trailer's
## ramp onto its deck, ride strapped while it's towed, and drive off again. Run:
##   godot --headless --path . -s tools/deck_check.gd

var main
var t


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	t = main.terrain
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
	await _frames(60)
	for kind in ["forge", "mobile_shredder", "roller_xl", "conveyor"]:
		var m = main.spawn_vehicle(kind)
		var away: Vector3 = flat.ramp_point() - flat.deck_centre()
		away.y = 0.0
		away = away.normalized()
		var start: Vector3 = flat.ramp_point() + away * 8.0
		m.place(Transform3D(Basis.looking_at(-away, Vector3.UP), Vector3(start.x, t.get_height(start.x, start.z), start.z)))
		await _frames(30)
		main.player.global_position = m.door_position()
		main._enter_machine(m)
		Input.action_press("drive_forward")
		var on := false
		for f in 60 * 20:
			await _frames(1)
			if Vector2(m.global_position.x - flat.deck_centre().x, m.global_position.z - flat.deck_centre().z).length() < 1.5:
				on = true
				break
		Input.action_release("drive_forward")
		await _frames(60)
		main._exit_machine()
		var height: float = m.global_position.y - flat.deck_centre().y
		flat.toggle_ramps()
		await _frames(150)
		var local0: Transform3D = flat.global_transform.affine_inverse() * m.global_transform
		main.player.global_position = tractor.door_position()
		main._enter_machine(tractor)
		Input.action_press("drive_forward")
		await _frames(200)
		Input.action_release("drive_forward")
		Input.action_press("drive_back")
		await _frames(60)
		Input.action_release("drive_back")
		await _frames(60)
		main._exit_machine()
		var shift: float = (flat.global_transform * local0).origin.distance_to(m.global_position)
		print("%s: drove onto the deck %s (sits %.2f m above it), strapped %s, towed: shift %.2f m" % [m.machine_name, on, height, flat.is_strapped(m), shift])
		flat.toggle_ramps()
		await _frames(150)
		main.despawn(m)
		await _frames(10)
	quit()
