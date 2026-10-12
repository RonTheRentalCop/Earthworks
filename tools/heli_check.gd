extends SceneTree
## The helicopter spools up, climbs, flies forward and turns; its rockets crater the ground
## and wreck a truck; landing hard wrecks it. Also: the pickup's model has its tyres on
## the wheels. Run:
##   godot --headless --path . -s tools/heli_check.gd

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
	# --- Pickup model.
	var pick = main.spawn_vehicle("pickup")
	await _frames(30)
	var tyres := 0
	for w in pick._wheels:
		for c in w.get_children():
			if String(c.name).to_lower().begins_with("tire"):
				tyres += 1
	print("pickup: %d model tyres on its %d wheels, upright %.2f" % [tyres, pick._wheels.size(), pick.global_basis.y.dot(Vector3.UP)])
	# --- Fly.
	var h = main.spawn_vehicle("heli")
	var pad := Vector3(80, 0, 120)
	h.place(Transform3D(Basis.IDENTITY, Vector3(pad.x, t.get_height(pad.x, pad.z), pad.z)))
	main.player.global_position = h.door_position()
	main._update_anchors()
	await _frames(20)
	main._enter_machine(h)
	await _frames(60 * 3)
	print("rotor after 3 s: %.0f%%" % (h.rpm * 100.0))
	Input.action_press("handbrake")
	await _frames(60 * 3)
	Input.action_release("handbrake")
	var alt: float = h.global_position.y - t.get_height(h.global_position.x, h.global_position.z)
	print("climbed: %.1f m up" % alt)
	var start: Vector3 = h.global_position
	Input.action_press("drive_forward")
	await _frames(60 * 4)
	Input.action_press("turn_left")
	await _frames(60)
	Input.action_release("turn_left")
	Input.action_release("drive_forward")
	await _frames(60)
	print("flew %.0f m, top speed so far %.0f km/h, yawed %.0f deg" % [h.global_position.distance_to(start), h.hud_info().speed, rad_to_deg(absf(h.rotation.y))])
	# --- Rockets on a parked truck below and ahead.
	var truck = main.truck
	var ahead: Vector3 = h.global_position - h.global_basis.z * 35.0
	truck.place(Transform3D(Basis.IDENTITY, Vector3(ahead.x, t.get_height(ahead.x, ahead.z) + 0.5, ahead.z)))
	await _frames(30)
	# Hover low and aim down at it.
	h.global_position.y = t.get_height(ahead.x, ahead.z) + 9.0
	var ground_before: float = t.get_height(ahead.x, ahead.z)
	for k in 8:
		var r = main.launch_rocket(h.global_position - h.global_basis.z * 2.0, (truck.global_position - h.global_position).normalized() * 115.0, h)
		await _frames(25)
	await _frames(60)
	print("rockets: truck health %.0f, wrecked %s, crater %.2f m deep" % [float(truck.get_meta("health", 100.0)), truck.has_meta("wrecked"), ground_before - t.get_height(ahead.x, ahead.z)])
	# --- Hard landing.
	h.global_position.y = t.get_height(h.global_position.x, h.global_position.z) + 40.0
	h.rpm = 0.0
	main._exit_machine()
	await _frames(60 * 5)
	print("dropped from 40 m with the rotor stopped: wrecked %s" % h.wrecked)
	quit()
