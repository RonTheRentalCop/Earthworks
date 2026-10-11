extends SceneTree
## Checks for this round: strong semi and heavy recovery truck, big dump truck and big
## roller, stump-only grinder, a raised dozer blade not cutting a pile, rock digging
## slower, deep swamp mud, and the trench saw. Run:
##   godot --headless --path . -s tools/v029_check.gd

var main
var t


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _drive(v, seconds: float) -> float:
	var start: Vector3 = v.global_position
	main.player.global_position = v.door_position()
	main._enter_machine(v)
	Input.action_press("drive_forward")
	await _frames(int(seconds * 60))
	Input.action_release("drive_forward")
	main._exit_machine()
	return v.global_position.distance_to(start)


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	t = main.terrain
	var flat := Vector3(60, 0, 130)
	# --- Engines (with 13 t of logs on the semi).
	for kind in ["log_semi", "recovery_xl", "dump_xl"]:
		var v = main.spawn_vehicle(kind)
		v.place(Transform3D(Basis.IDENTITY, Vector3(flat.x, t.get_height(flat.x, flat.z) + 0.6, flat.z)))
		if kind == "log_semi":
			v.mass += 13000.0
		await _frames(60)
		var moved: float = await _drive(v, 6.0)
		print("%s: %.0f m in 6 s from a standstill%s" % [v.machine_name, moved, " (with 13 t of logs)" if kind == "log_semi" else ""])
		main.despawn(v)
		await _frames(5)
	# --- Big roller.
	var r = main.spawn_vehicle("roller_xl")
	r.place(Transform3D(Basis.IDENTITY, Vector3(flat.x, t.get_height(flat.x, flat.z), flat.z)))
	await _frames(20)
	print("big roller: %s, drum half width %.2f m" % [r.machine_name, r.DRUM_HALF_WIDTH * r.size])
	main.despawn(r)
	# --- Grinder: leaves a standing tree, grinds a stump.
	var f = main.forests
	var tree_tid: int = f.nearest_tree(Vector3(0, 0, 0), 400.0)
	var stump_tid := -1
	for k in f.count():
		if f.state[k] == 0 and k != tree_tid:
			stump_tid = k
			break
	var log_body = f.apply_event(stump_tid, "fell", main)
	log_body.global_position += Vector3(8, 1, 0)
	await _frames(5)
	var money: int = main.career.money
	main.grind_at(f.pos[tree_tid], 2.0, main.dozer)
	main.grind_at(f.pos[stump_tid], 2.0, main.dozer)
	print("grinder: standing tree untouched %s, stump ground %s, log left %s, cash +%d" % [
		f.state[tree_tid] == 0, f.state[stump_tid] == 2, is_instance_valid(log_body) and not log_body.is_queued_for_deletion(), main.career.money - money])
	# --- Dozer with the blade raised drives over a pile: the pile stays.
	var dozer = main.dozer
	var pile := Vector3(-60, 0, 150)
	t.deposit(pile.x, pile.z, 6.0, 2.5)
	await _frames(5)
	var pile_top: float = t.get_height(pile.x, pile.z)
	dozer.place(Transform3D(Basis.IDENTITY, Vector3(pile.x, t.get_height(pile.x, pile.z + 10), pile.z + 10)))
	main.player.global_position = dozer.door_position()
	main._enter_machine(dozer)
	Input.action_press("boom_up")
	await _frames(90)
	Input.action_release("boom_up")
	var blade_y: float = dozer._blade.to_global(Vector3(0, -0.58, -0.14)).y
	Input.action_press("drive_forward")
	await _frames(60 * 8)
	Input.action_release("drive_forward")
	main._exit_machine()
	print("dozer, blade raised %.1f m above the ground, drove over a %.2f m pile: pile now %.2f m (lowered %.2f)" % [
		blade_y - t.get_height(pile.x, pile.z + 10), pile_top - t.original_height(pile.x, pile.z), t.get_height(pile.x, pile.z) - t.original_height(pile.x, pile.z),
		pile_top - t.get_height(pile.x, pile.z)])
	# --- Rock digs slower than soil.
	var m: Vector4 = main.MOUNTAINS[0]
	var rock_at := Vector3(m.x + m.z * 0.3, 0, m.y)
	print("mountain: rock at the foot of the peak %s, height %.0f m" % [t.is_rock(rock_at.x, rock_at.z), t.get_height(rock_at.x, rock_at.z)])
	var rock_cut: float = t.dig(Vector3(rock_at.x, t.get_height(rock_at.x, rock_at.z) - 0.5, rock_at.z), 0.85, 50.0)
	var soil_cut: float = t.dig(Vector3(flat.x + 20, t.get_height(flat.x + 20, flat.z) - 0.5, flat.z), 0.85, 50.0)
	print("dig with the same bite: rock %.2f m3, soil %.2f m3" % [rock_cut, soil_cut])
	# --- Deep swamp mud.
	var sw: Vector3 = main.SWAMPS[0]
	var mud_spot := Vector3(sw.x, 0, sw.y)
	var best := 0.0
	for k in 400:
		var q := Vector3(sw.x + randf_range(-60, 60), 0, sw.y + randf_range(-60, 60))
		var d: float = t.mud_depth(q.x, q.z)
		if d > best and main.water.depth_at(q.x, q.z) < 0.05:
			best = d
			mud_spot = q
	var exc = main.excavator
	exc.place(Transform3D(Basis.IDENTITY, Vector3(mud_spot.x, t.get_height(mud_spot.x, mud_spot.z), mud_spot.z)))
	main._update_anchors()
	await _frames(60 * 20)  # left standing in it
	print("swamp mud depth %.2f (dry ground 0, old max 1.0): parked excavator sunk %.2f m, speed factor %.2f" % [best, exc.bog, exc._sunk_factor()])
	var moved_out: float = await _drive(exc, 30.0)
	print("excavator tried to drive out: moved %.1f m in 30 s" % moved_out)
	# --- Trench saw.
	exc.place(Transform3D(Basis.IDENTITY, Vector3(110, t.get_height(110, 170), 170)))
	await _frames(30)
	print("saw: ", exc.set_attachment(4))
	main.player.global_position = exc.door_position()
	main._enter_machine(exc)
	Input.action_press("boom_down")
	await _frames(150)
	Input.action_release("boom_down")
	Input.action_press("stick_in")
	await _frames(240)
	Input.action_release("stick_in")
	main._exit_machine()
	var deepest := 0.0
	var cells := 0
	for dz in range(-60, 61):
		for dx in range(-60, 61):
			var q: Vector3 = exc.global_position + Vector3(dx * 0.25, 0, dz * 0.25)
			var d: float = t.dug_depth(q.x, q.z)
			deepest = maxf(deepest, d)
			if d > 0.8:
				cells += 1
	var tip: Vector3 = exc._saw.to_global(Vector3(0, -0.7 - exc.SAW_LENGTH, 0))
	print("saw: trench up to %.2f m deep, %.1f m2 of it deeper than 0.8 m; bar tip %.2f m below ground; moved %.1f m3" % [
		deepest, cells * 0.0625, t.get_height(tip.x, tip.z) - tip.y, exc.soil_moved])
	quit()
