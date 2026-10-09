extends SceneTree
## Checks the world save: digs, fills with gravel, fells a tree, pulls a stump, moves
## rubble and lays mats, saves, builds a fresh world, restores, and compares. Uses its own
## file, never your save. Run:
##   godot --headless --path . -s tools/save_check.gd

const WorldSave = preload("res://scripts/world_save.gd")

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	WorldSave.path = "user://save_check_world.save"
	WorldSave.erase()
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var forests = main.forests
	# Changes: a hole, a gravel pile, a felled tree (its log moved), a pulled stump, a block, mats.
	var hole := Vector2(-60, 20)
	t.dig(Vector3(hole.x, t.get_height(hole.x, hole.y) - 0.5, hole.y), 2.0, 6.0)
	var far := Vector2(430, -430)  # a corner nobody visits, so it isn't generated on restore
	t.dig(Vector3(far.x, t.get_height(far.x, far.y) - 0.6, far.y), 2.0, 5.0)
	var pile := Vector2(-45, 30)
	t.deposit(pile.x, pile.y, 5.0, 2.5, t.SURFACE_GRAVEL)
	var log_tid := -1
	var stump_tid := -1
	for tid in forests.count():
		if forests.state[tid] == 0:
			if log_tid < 0:
				log_tid = tid
			elif stump_tid < 0:
				stump_tid = tid
				break
	var log_body: RigidBody3D = forests.apply_event(log_tid, "fell", main)
	await _frames(30)
	log_body.global_transform = Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(-50, t.get_height(-50, 10) + 0.6, 10))
	forests.apply_event(stump_tid, "fell", main)
	var stump_body: RigidBody3D = forests.apply_event(stump_tid, "pulled", main)
	var block: RigidBody3D = main.debris[0]
	block.global_position = Vector3(-55, t.get_height(-55, 5) + 1.0, 5)
	main.spawn_mats(Vector3(-40, t.get_height(-40, 40) + 0.3, 40), 4)
	await _frames(120)
	var want := {
		"hole": t.get_height(hole.x, hole.y), "pile": t.get_height(pile.x, pile.y), "gravel": t.is_gravel(pile.x, pile.y),
		"log": log_body.global_position, "stump": stump_body.global_position, "block": block.global_position,
		"states": [forests.state[log_tid], forests.state[stump_tid]], "chunks": t.edited.size(),
		"far": t.get_height(far.x, far.y),
	}
	var t0 := Time.get_ticks_msec()
	var ok := WorldSave.save(main)
	var bytes := FileAccess.get_file_as_bytes(WorldSave.path).size()
	print("saved: %s, %d changed chunks, %d KB, %d ms" % [ok, want.chunks, bytes / 1024, Time.get_ticks_msec() - t0])
	main.queue_free()
	await process_frame
	await process_frame

	# A fresh world, then the save put back.
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	t = main.terrain
	forests = main.forests
	print("fresh world: hole %.2f (saved %.2f), tree states %s" % [t.get_height(hole.x, hole.y), want.hole, [forests.state[log_tid], forests.state[stump_tid]]])
	t0 = Time.get_ticks_msec()
	main._restoring = true
	var restored := WorldSave.restore(main)
	main._restoring = false
	print("restored: %s in %d ms" % [restored, Time.get_ticks_msec() - t0])
	await _frames(10)
	var log_now := Vector3.INF
	var stump_now := Vector3.INF
	var mats := 0
	for id in main.bodies:
		var b: Node3D = main.bodies[id]
		if b.get_meta("label", "") == "ground mat":
			mats += 1
	var known: Array = main.tree_bodies.get(log_tid, [-1, -1])
	if main.bodies.has(int(known[0])):
		log_now = main.bodies[int(known[0])].global_position
	known = main.tree_bodies.get(stump_tid, [-1, -1])
	if main.bodies.has(int(known[1])):
		stump_now = main.bodies[int(known[1])].global_position
	print("hole %.2f / %.2f   pile %.2f / %.2f   gravel %s / %s" % [t.get_height(hole.x, hole.y), want.hole, t.get_height(pile.x, pile.y), want.pile, t.is_gravel(pile.x, pile.y), want.gravel])
	print("tree states %s / %s   log %.2f m from where it was left   stump %.2f m   block %.2f m   mats %d / 4" % [
		[forests.state[log_tid], forests.state[stump_tid]], want.states, log_now.distance_to(want.log), stump_now.distance_to(want.stump),
		main.debris[0].global_position.distance_to(want.block), mats])
	var waiting: int = t._pending_chunks.size()
	print("far-off hole: %d chunks waiting for their ground; going there: %.2f / %.2f, waiting now %d" % [waiting, t.get_height(far.x, far.y), want.far, t._pending_chunks.size()])
	print("stats not bumped by the restore: stumps cleared %d" % main.stumps_cleared)
	WorldSave.erase()
	quit()
