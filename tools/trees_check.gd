extends SceneTree
## Fells trees of every species, dumps soil on resting logs, and checks no log or stump
## ends up under the ground (the ground only holds things up from above). Run:
##   godot --headless --path . -s tools/trees_check.gd
var main
func _frames(n: int) -> void:
	for i in n:
		await physics_frame
func _mid(b: RigidBody3D) -> Vector3:
	var g: Array = b.get_meta("grip")
	return b.to_global(((g[0] as Vector3) + (g[1] as Vector3)) * 0.5)
func _check(label: String) -> void:
	var t = main.terrain
	var worst := 0.0
	var bad := 0
	var total := 0
	for id in main.bodies:
		var b: RigidBody3D = main.bodies[id]
		if not is_instance_valid(b) or not b.has_meta("grip"):
			continue
		if b.get_meta("label", "") == "ground mat":
			continue
		total += 1
		var g: Array = b.get_meta("grip")
		for p in [b.to_global(g[0]), _mid(b), b.to_global(g[1])]:
			var under: float = t.sample_height(p.x, p.z) - p.y
			worst = maxf(worst, under)
			if under > 0.3:
				bad += 1
				break
	print("%s: %d logs/stumps, %d under the ground, deepest %.2f m below" % [label, total, bad, worst])
func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var forests = main.forests
	# Pick standing trees: the biggest of every species first, then others, across the map.
	var picks := []
	for sp in 6:
		var best := -1
		for tid in forests.count():
			if forests.species[tid] == sp and forests.state[tid] == 0 and (best < 0 or forests.size[tid] > forests.size[best]):
				best = tid
		if best >= 0:
			picks.append(best)
	for tid in range(0, forests.count(), 97):
		if forests.state[tid] == 0 and not tid in picks:
			picks.append(tid)
	print("felling %d trees" % picks.size())
	for tid in picks:
		var at: Vector3 = forests.pos[tid]
		main.player.global_position = Vector3(at.x + 4, main.terrain.get_height(at.x + 4, at.z) + 1, at.z)
		main._update_anchors()
		await _frames(20)
		var tree = forests.node_for(tid)
		if tree:
			tree.fell(Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)))
		else:
			forests.apply_event(tid, "fell", main)
		await _frames(40)
	await _frames(60 * 8)
	_check("8 s after the last fell (player at the last tree)")
	# Bury: dump soil on the resting logs (a truck tipping, or a dozer pushing spoil over them).
	var t = main.terrain
	var n := 0
	for id in main.bodies:
		var b: RigidBody3D = main.bodies[id]
		if is_instance_valid(b) and b.has_meta("grip") and b.get_meta("label", "") != "ground mat" and n < 12:
			var m := _mid(b)
			main.player.global_position = Vector3(m.x + 3, t.get_height(m.x + 3, m.z) + 1, m.z)
			main._update_anchors()
			await _frames(10)
			t.deposit(m.x, m.z, 6.0, 2.0)
			n += 1
			await _frames(90)
	await _frames(120)
	_check("after dumping soil on 12 of them")
	main.player.global_position = Vector3(0, main.terrain.get_height(0, 100) + 1, 100)
	main._update_anchors()
	await _frames(60 * 12)
	_check("12 s after walking back to the depot")
	quit()
