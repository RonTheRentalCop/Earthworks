extends SceneTree
## The roller: set a level, switch levelling on and drive: the ground along its path ends
## up at that level (cut where high, filled where low) and rolled firm. Run:
##   godot --headless --path . -s tools/roller_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _spread(t, from: Vector3, dir: Vector3, length: float, level: float) -> Vector2:
	# Worst and mean distance from the level along the middle of the drum's path.
	var worst := 0.0
	var total := 0.0
	var n := 0
	for k in range(4, int(length)):
		var p := from + dir * k
		var d: float = absf(t.get_height(p.x, p.z) - level)
		worst = maxf(worst, d)
		total += d
		n += 1
	return Vector2(worst, total / maxf(n, 1))


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var r = main.spawn_vehicle("roller")
	print("roller spawned: %s  (%s)" % [r != null, r.machine_name if r else ""])
	var at := Vector3(40, 0, 150)
	# Rough ground: a mound and a hole on the path ahead.
	t.add_mound(Vector2(at.x, at.z - 10), 3.0, 1.2)
	t.dig(Vector3(at.x, t.get_height(at.x, at.z - 20) - 0.7, at.z - 20), 2.5, 50.0)
	r.place(Transform3D(Basis.IDENTITY, Vector3(at.x, t.get_height(at.x, at.z), at.z)))
	main.player.global_position = r.door_position()
	main._update_anchors()
	await _frames(30)
	main._enter_machine(r)
	await _frames(5)
	var level: float = r.drum_point().y
	print("before: path spread from the level %s" % _spread(t, at, Vector3.FORWARD, 26, level))
	# Snap the level to here, nudge it down 0.2 m, then switch on and drive.
	Input.action_press("stick_out")
	await _frames(3)
	Input.action_release("stick_out")
	Input.action_press("boom_down")
	await _frames(int(0.2 / r.LEVEL_RATE * 60))
	Input.action_release("boom_down")
	level = r.level
	main._press_utility()
	print("levelling: %s at %.2f m" % [r.levelling, level])
	Input.action_press("drive_forward")
	var start: Vector3 = r.global_position
	while r.global_position.distance_to(start) < 30.0:
		await _frames(1)
	Input.action_release("drive_forward")
	await _frames(120)
	var spread := _spread(t, at, Vector3.FORWARD, 26, level)
	print("after one pass: worst %.2f m, mean %.3f m off the level; cut %.1f m3, filled %.1f m3" % [spread.x, spread.y, r.cut, r.filled])
	# Back over it once more (a second pass finishes off the deep bits).
	Input.action_press("drive_back")
	while r.global_position.distance_to(start) > 2.0:
		await _frames(1)
	Input.action_release("drive_back")
	await _frames(60)
	spread = _spread(t, at, Vector3.FORWARD, 26, level)
	print("after two passes: worst %.2f m, mean %.3f m off the level" % [spread.x, spread.y])
	var mid := at + Vector3.FORWARD * 15
	print("rolled firm: %s" % (t.pressed[t._index_at(mid.x, mid.z)] == 1))
	main._press_utility()
	print("levelling after toggle: %s" % r.levelling)
	quit()
