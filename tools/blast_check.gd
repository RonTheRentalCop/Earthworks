extends SceneTree
## The explosives truck drills and plants linked charges; standing too close refuses to
## fire; from a safe distance they all go off, blowing craters (through rock too, leaving
## it diggable). Run:
##   godot --headless --path . -s tools/blast_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var b = main.spawn_vehicle("blaster")
	var m: Vector4 = main.MOUNTAINS[0]
	var at := Vector3(m.x + m.z * 0.25, 0, m.y)
	b.place(Transform3D(Basis.IDENTITY, Vector3(at.x, t.get_height(at.x, at.z) + 0.6, at.z)))
	main.player.global_position = b.door_position()
	main._update_anchors()
	await _frames(60)
	main._enter_machine(b)
	var spots := []
	for k in 4:
		if k > 0:
			Input.action_press("drive_forward")
			await _frames(50)
			Input.action_release("drive_forward")
			await _frames(30)
		main._press_utility()
		spots.append(b.drill_point())
	print("charges planted: %d (rock under them: %s)" % [main.charges.size(), t.is_rock(spots[0].x, spots[0].z)])
	var before := []
	for s in spots:
		before.append(t.get_height(s.x, s.z))
	main._request(1, "detonate", 0)
	print("too close: still %d charges" % main.charges.size())
	Input.action_press("drive_forward")
	await _frames(400)
	Input.action_release("drive_forward")
	await _frames(30)
	print("truck %.0f m from the nearest charge" % b.global_position.distance_to(spots[3]))
	main._request(1, "detonate", 0)
	await _frames(150)
	var deepest := 0.0
	for k in spots.size():
		deepest = maxf(deepest, before[k] - t.get_height(spots[k].x, spots[k].z))
	print("blown: charges left %d, craters up to %.1f m deep, rock left at the first crater %s" % [main.charges.size(), deepest, t.is_rock(spots[0].x, spots[0].z)])
	var cut: float = t.dig(Vector3(spots[0].x, t.get_height(spots[0].x, spots[0].z) - 0.5, spots[0].z), 0.85, 50.0)
	print("digging the fractured rock: %.2f m3 per bite (solid rock gives about 0.1)" % cut)
	quit()
