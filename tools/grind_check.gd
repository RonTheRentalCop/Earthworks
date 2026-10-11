extends SceneTree
## The dozer's grinder grinds trees, stumps and logs it drives into (paid on the spot),
## and the portable shredder takes a log dropped in its infeed. Run:
##   godot --headless --path . -s tools/grind_check.gd

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
	var f = main.forests
	# A standing tree with open ground on one side.
	var tid := -1
	for k in f.count():
		var q: Vector3 = f.pos[k]
		if f.state[k] == 0 and absf(q.x) < 300 and absf(q.z) < 300:
			tid = k
			break
	var tree_at: Vector3 = f.pos[tid]
	var dozer = main.dozer
	var start := tree_at + Vector3(0, 0, 12)
	dozer.place(Transform3D(Basis.IDENTITY, Vector3(start.x, t.get_height(start.x, start.z), start.z)))
	main.player.global_position = dozer.door_position()
	main._update_anchors()
	await _frames(30)
	main._enter_machine(dozer)
	main._press_utility()
	print("grinder on: %s, drum shown %s" % [dozer.grinder, dozer._grinder.visible])
	Input.action_press("boom_up")  # blade up off the ground
	await _frames(60)
	Input.action_release("boom_up")
	var money: int = main.career.money
	Input.action_press("drive_forward")
	var frames := 0
	while f.state[tid] < 2 and frames < 60 * 20:
		await _frames(1)
		frames += 1
		if frames % 120 == 0:
			var g: Vector3 = dozer.grinder_point()
			print("  t=%.0f s dozer %.1f m from the tree, drum %.1f m (reach %.1f), dy %.1f, speed %.1f" % [frames / 60.0,
				Vector2(dozer.global_position.x - tree_at.x, dozer.global_position.z - tree_at.z).length(),
				Vector2(g.x - tree_at.x, g.z - tree_at.z).length(), dozer.grinder_reach(), g.y - tree_at.y, dozer._speed])
	Input.action_release("drive_forward")
	await _frames(10)
	print("grinder: tree %d ground %s after %.1f s, cash +%d, loose wood left near it %d" % [
		tid, f.state[tid] >= 2, frames / 60.0, main.career.money - money, _wood_near(tree_at, 8.0)])
	main._press_utility()
	main._exit_machine()
	# Portable shredder: drop a log in the infeed.
	var ms = main.spawn_vehicle("mobile_shredder")
	var spot := Vector3(60, 0, 130)
	ms.place(Transform3D(Basis.IDENTITY, Vector3(spot.x, t.get_height(spot.x, spot.z), spot.z)))
	await _frames(30)
	var tid2 := -1
	for k in f.count():
		if f.state[k] == 0 and k != tid:
			tid2 = k
			break
	var lg: RigidBody3D = f.apply_event(tid2, "fell", main)
	await _frames(5)
	lg.global_position = ms.infeed_point() + Vector3(0, 1.5, 0)
	lg.linear_velocity = Vector3.ZERO
	money = main.career.money
	await _frames(60 * 4)
	print("portable shredder: shredded %d, log gone %s, cash +%d" % [ms.total_shredded, not is_instance_valid(lg), main.career.money - money])
	quit()


func _wood_near(p: Vector3, r: float) -> int:
	var n := 0
	for id in main.bodies:
		var b = main.bodies[id]
		if is_instance_valid(b) and b.is_in_group("shreddable") and not b.is_queued_for_deletion() and b.global_position.distance_to(p) < r:
			n += 1
	return n
