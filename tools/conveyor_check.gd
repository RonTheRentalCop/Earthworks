extends SceneTree
## The tracked conveyor: a dump truck tips into its hopper, the belt carries the load up
## and piles it under the head (or loads a truck parked there); it folds (and won't run
## folded), raises its boom and drives. Run:
##   godot --headless --path . -s tools/conveyor_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var c = main.spawn_vehicle("conveyor")
	var at := Vector3(-70, 0, 20)
	c.place(Transform3D(Basis.IDENTITY, at))
	main.player.global_position = Vector3(at.x + 6, t.get_height(at.x + 6, at.z) + 1, at.z)
	main._update_anchors()
	await _frames(30)
	var head: Vector3 = c.head_point()
	print("conveyor: reach %.1f m, head %.1f m above the ground, belt running %s" % [
		Vector2(head.x - at.x, head.z - at.z).length(), head.y - t.get_height(head.x, head.z), c.running()])
	# A loaded dump truck backs up and tips into the hopper.
	var truck = main.truck
	truck.add_soil(8.0)
	var hopper: Vector3 = c._visual.to_global(c.HOPPER)
	truck.place(Transform3D(Basis.IDENTITY, Vector3(hopper.x, t.get_height(hopper.x, hopper.z + 7.0) + 0.6, hopper.z + 7.0)))
	await _frames(60)
	var bed_drop: Vector3 = truck._bed.to_global(Vector3(0, -0.6, 1.0))
	truck.global_position += Vector3(hopper.x - bed_drop.x, 0, hopper.z - bed_drop.z)
	await _frames(30)
	var ground_before: float = t.get_height(head.x, head.z)
	main.player.global_position = truck.door_position()
	main._enter_machine(truck)
	Input.action_press("boom_up")
	await _frames(240)
	Input.action_release("boom_up")
	Input.action_press("boom_down")  # bed back down
	await _frames(240)
	Input.action_release("boom_down")
	main._exit_machine()
	print("truck tipped: %.1f m3 left in the body, hopper took %.1f m3" % [truck.payload, c.hopper + c.on_belt() + c.delivered])
	await _frames(60 * 14)
	print("belt: delivered %.1f m3 off the head, pile under it %.2f m high, hopper %.1f, on the belt %.1f" % [
		c.delivered, t.get_height(head.x, head.z) - ground_before, c.hopper, c.on_belt()])
	# Folded it stops; the head comes in.
	c.add_soil(3.0)
	main.player.global_position = c.door_position()
	main._enter_machine(c)
	Input.action_press("stick_in")
	await _frames(60 * 8)
	Input.action_release("stick_in")
	var folded_reach := Vector2(c.head_point().x - c.global_position.x, c.head_point().z - c.global_position.z).length()
	var before: float = c.delivered
	await _frames(120)
	print("folded: running %s, reach %.1f m, delivered while folded %.2f m3" % [c.running(), folded_reach, c.delivered - before])
	# Drive it folded, then unfold and raise the boom.
	var start: Vector3 = c.global_position
	Input.action_press("drive_forward")
	await _frames(240)
	Input.action_release("drive_forward")
	print("drove %.1f m folded" % c.global_position.distance_to(start))
	Input.action_press("stick_out")
	await _frames(60 * 8)
	Input.action_release("stick_out")
	var low: float = c.head_point().y
	Input.action_press("boom_up")
	await _frames(180)
	Input.action_release("boom_up")
	print("unfolded again: running %s; raising the boom lifted the head %.1f m" % [c.running(), c.head_point().y - low])
	main._exit_machine()
	# A truck parked under the head gets loaded.
	var under: Vector3 = c.head_point()
	truck.place(Transform3D(Basis.IDENTITY, Vector3(under.x, t.get_height(under.x, under.z - 2.3) + 0.6, under.z - 2.3)))
	await _frames(30)
	var bed_mid: Vector3 = truck._bed.to_global(Vector3(0, 0.5, -truck._bed_half.y))
	truck.global_position += Vector3(under.x - bed_mid.x, 0, under.z - bed_mid.z)
	var payload_before: float = truck.payload
	c.add_soil(5.0)
	await _frames(60 * 14)
	print("truck under the head: loaded %.1f m3 from the belt" % (truck.payload - payload_before))
	quit()
