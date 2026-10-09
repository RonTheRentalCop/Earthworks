extends SceneTree
## Headless checks for the career layer: spawning every machine, the shredder paying out,
## jobs completing, the protected depot, the log truck tipping logs off, dozer gravity
## and pushing, and returning machines. Run:
##   godot --headless --path . -s tools/gameplay_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await _frames(30)
	var t = main.terrain
	var zone: Vector2 = main.ZONE

	# --- Every kind delivers to a bay and settles upright.
	var spawned := {}
	for kind in ["pickup", "adt", "logs", "haul"]:
		spawned[kind] = main.spawn_vehicle(kind)
	await _frames(180)
	var upright := []
	for kind in spawned:
		var v: Node3D = spawned[kind]
		upright.append("%s %.2f" % [kind, v.global_basis.y.y])
	print("upright (1 = level): ", ", ".join(upright), "   fleet ", main.fleet_size())

	# --- Pickup top speed on the haul road.
	var pickup = spawned.pickup
	pickup.place(Transform3D(Basis(Vector3.UP, PI), Vector3(0, t.get_height(0, 70) + 0.5, 70)))
	await _frames(20)
	main.player.global_position = pickup.door_position()
	main._enter_machine(pickup)
	Input.action_press("drive_forward")
	await _frames(4 * 60)
	Input.action_release("drive_forward")
	print("pickup after 4 s of throttle: %.0f km/h" % pickup.hud_info().speed)
	main._exit_machine()

	# --- Log truck: a log on the bed slides off when it tips.
	var logs = spawned.logs
	logs.place(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-40, t.get_height(-40, 10) + 0.4, 10)))
	await _frames(60)
	var log_body := _make_log(logs._bed.to_global(Vector3(0, 0.8, -2.3)), logs.global_basis)
	await _frames(90)
	var on_bed := log_body.global_position.distance_to(logs._bed.to_global(Vector3(0, 0.8, -2.3)))
	main.player.global_position = logs.door_position()
	main._enter_machine(logs)
	Input.action_press("boom_up")
	await _frames(4 * 60)
	Input.action_release("boom_up")
	await _frames(90)
	var slid := log_body.global_position.distance_to(logs._bed.to_global(Vector3(0, 0.8, -2.3)))
	print("log truck: log %.2f m from its bed spot while flat, %.1f m after tipping (bed angle %.2f, log in bed space %s)" % [on_bed, slid, logs._bed.rotation.x, logs._bed.to_local(log_body.global_position).snapped(Vector3.ONE * 0.1)])
	main._exit_machine()

	# --- Shredder pays for logs pushed into the infeed.
	var shredder = main.shredders[0]
	var money_before: int = main.career.money
	var fed := _make_log(shredder.infeed_point() + Vector3(0, 0.6, 0), shredder.global_basis)
	fed.set_meta("value", 400)
	await _frames(4 * 60)
	print("shredder: log gone %s, cash +%d, shredded %d" % [not is_instance_valid(fed), main.career.money - money_before, shredder.total_shredded])

	# --- Jobs: dig, fill and recovery complete and pay.
	for type in ["dig", "fill", "recover"]:
		main.jobs.offers.clear()
		main.jobs.offers.append(main.jobs._make(type))
		var job: Dictionary = main.jobs.accept(0)
		money_before = main.career.money
		var p: Vector2 = job.get("pos", Vector2.ZERO)
		match type:
			"dig":
				for k in 400:
					var at := p + Vector2(randf_range(-job.half.x, job.half.x), randf_range(-job.half.y, job.half.y))
					t.dig(Vector3(at.x, t.original_height(at.x, at.y) - job.depth - 0.2, at.y), 1.2, 1.0)
			"fill":
				for k in 30:
					t.deposit(p.x + randf_range(-2, 2), p.y + randf_range(-2, 2), 1.5, 2.5)
			"recover":
				var v: Node3D = job.vehicle
				await _frames(30)
				v.global_position = Vector3(zone.x + 5, t.get_height(zone.x + 5, zone.y + 4) + 1.0, zone.y + 4)
				v.linear_velocity = Vector3.ZERO
		await _frames(90)
		print("job %-8s progress %.0f%%  active now %s  paid +%d" % [type, float(job.progress) * 100.0, not main.jobs.active.is_empty(), main.career.money - money_before])
		main.jobs.abandon()

	# --- The depot can't be dug.
	var depot_dig: float = t.dig(Vector3(zone.x, t.get_height(zone.x, zone.y) - 1.0, zone.y), 1.0, 5.0)
	var road_dig: float = t.dig(Vector3(zone.x, t.get_height(zone.x, zone.y - 40) - 1.0, zone.y - 40), 1.0, 5.0)
	var field_dig: float = t.dig(Vector3(-60, t.get_height(-60, 0) - 1.0, 0), 1.0, 5.0)
	print("dig in depot %.2f m3, on the haul road %.2f m3, in a field %.2f m3" % [depot_dig, road_dig, field_dig])

	# --- Dozer: drops off a ledge under gravity, and shoves a truck.
	var dozer = main.dozer
	dozer.place(Transform3D(Basis.IDENTITY, Vector3(-60, 0, 20)))
	await _frames(10)
	dozer.global_position.y += 3.0
	var fall := []
	for k in 6:
		await _frames(10)
		fall.append(snappedf(dozer.global_position.y - t.get_height(-60, 20), 0.01))
	print("dozer dropped from 3 m, height above ground every 1/6 s: ", fall)
	var truck = main.truck
	truck.place(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-60, t.get_height(-60, 12) + 0.4, 12)))
	await _frames(60)
	var truck_start: Vector3 = truck.global_position
	main.player.global_position = dozer.door_position()
	main._enter_machine(dozer)
	Input.action_press("boom_up")
	Input.action_press("drive_forward")
	await _frames(6 * 60)
	Input.action_release("drive_forward")
	Input.action_release("boom_up")
	print("dozer pushed the parked truck %.1f m" % truck.global_position.distance_to(truck_start))
	main._exit_machine()

	# --- Return a machine.
	var before: int = main.fleet_size()
	main.despawn(spawned.haul)
	await _frames(5)
	print("returned the haul tractor: fleet %d -> %d" % [before, main.fleet_size()])
	quit()


func _make_log(at: Vector3, basis: Basis) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = 500.0
	body.collision_layer = 4
	body.collision_mask = 1 | 2 | 4 | 8 | 32 | 64 | 128
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 3.6
	shape.shape = cyl
	shape.rotation.x = PI * 0.5
	body.add_child(shape)
	body.add_to_group("shreddable")
	body.add_to_group("winchable")
	body.set_meta("label", "log")
	main.add_child(body)
	body.global_transform = Transform3D(basis, at)
	return body
