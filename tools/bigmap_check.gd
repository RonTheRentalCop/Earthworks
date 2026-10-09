extends SceneTree
## Checks for the big map: heavy vehicles sinking into swamp mud (and not on mats),
## gravel from the quarry making firm ground, mats from the shop, valuable trees, and
## trees streaming back in as stumps. Run:
##   godot --headless --path . -s tools/bigmap_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	main.hud.visible = false
	# A muddy spot in the Great Swamp, out of the water.
	var spot := Vector2(-260, 300)
	for k in 200:
		var q := Vector2(-320, 260) + Vector2.from_angle(k * 2.4) * (20.0 + k * 0.5)
		if main.water.depth_at(q.x, q.y) <= 0.0 and t.mud_at(q.x, q.y) > 0.8:
			spot = q
			break
	print("swamp test spot %s, mud %.2f" % [spot, t.mud_at(spot.x, spot.y)])

	# --- Sinking: a loaded dump truck vs an empty pickup, parked 20 s.
	var truck = main.truck
	var pickup = main.spawn_vehicle("pickup")
	truck.add_soil(8.0)
	var results := []
	for pair in [[truck, spot], [pickup, spot + Vector2(14, 0)]]:
		var v = pair[0]
		var at: Vector2 = pair[1]
		v.place(Transform3D(Basis.IDENTITY, Vector3(at.x, t.get_height(at.x, at.y) + 0.6, at.y)))
		main.player.global_position = Vector3(at.x + 5, t.get_height(at.x + 5, at.y) + 1, at.y)
		main._update_anchors()
	await _frames(60)
	await _frames(20 * 60)
	for k in 2:
		var v = [truck, pickup][k]
		var ruts := 0.0
		for w in v._wheels:
			ruts = maxf(ruts, t.dug_depth(w.global_position.x, w.global_position.z))
		results.append("%s wheels sunk %.2f m (ruts %.2f m)" % [v.machine_name, v.bog, ruts])
	print("parked in swamp mud for 20 s: ", ", ".join(results))

	# --- Mats: buy a pack, lay one in the mud, park the loaded truck on it.
	var money_before: int = main.career.money
	var bodies_before: int = main.bodies.size()
	main.remote_request(1, "supply", "mats")
	main.remote_request(1, "supply", "mats")
	await _frames(10)
	print("bought two packs of ground mats: cash -%d, mats delivered %d" % [money_before - main.career.money, main.bodies.size() - bodies_before])
	var mat_at := spot + Vector2(0, 30)
	var mats := []
	for id in main.bodies:
		if main.bodies[id].get_meta("label", "") == "ground mat":
			mats.append(main.bodies[id])
	# Laid crosswise, side by side, the way crane mats make a pad: 8 x 1.3 m = 10.4 m long.
	for k in mats.size():
		var m: RigidBody3D = mats[k]
		var z := mat_at.y + (k - 3.5) * 1.32
		m.global_transform = Transform3D(Basis.IDENTITY, Vector3(mat_at.x, t.get_height(mat_at.x, z) + 0.3, z))
		m.linear_velocity = Vector3.ZERO
	main._update_anchors()
	await _frames(60)
	truck.place(Transform3D(Basis.IDENTITY, Vector3(mat_at.x, t.get_height(mat_at.x, mat_at.y) + 0.5, mat_at.y)))
	await _frames(90)
	await _frames(20 * 60)
	var on_mats := 0
	for w in truck._wheels:
		if w.is_in_contact() and w.get_contact_body() is RigidBody3D:
			on_mats += 1
	print("loaded truck on mats in the same mud: wheels sunk %.2f m, %d/%d wheels on mats" % [truck.bog, on_mats, truck._wheels.size()])

	# --- Tracked machines sink too.
	var ex = main.excavator
	var ex_at := spot + Vector2(-14, 0)
	ex.place(Transform3D(Basis.IDENTITY, Vector3(ex_at.x, 0, ex_at.y)))
	main._update_anchors()
	await _frames(20 * 60)
	var under_track: Vector3 = ex.global_position + ex.global_basis.x * 1.6
	print("excavator parked 20 s in the swamp: sunk %.2f m, top speed now %d%%" % [ex.bog, ex._sunk_factor() * 100.0])

	# --- Gravel: dig at the quarry, dump on mud, the ground there turns to firm gravel.
	var quarry: Vector2 = main.QUARRY
	var pile := quarry + Vector2(-24, -10)
	var dig_at := Vector3(pile.x, t.get_height(pile.x, pile.y) - 0.4, pile.y)
	var got: float = t.dig(dig_at, 1.0, 3.0)
	var gravel: bool = t.is_gravel(pile.x, pile.y)
	var dump := spot + Vector2(30, 10)
	var mud_before: float = t.mud_at(dump.x, dump.y)
	t.deposit(dump.x, dump.y, got, 1.6, t.SURFACE_GRAVEL if gravel else t.SURFACE_SOIL)
	print("quarry pile is gravel: %s (dug %.1f m3); dumped on mud %.2f -> gravel %s, mud now %.2f" % [gravel, got, mud_before, t.is_gravel(dump.x, dump.y), t.mud_at(dump.x, dump.y)])

	# --- Valuable trees, and felled trees streaming back as stumps.
	var forests = main.forests
	var best := -1
	for tid in forests.count():
		if forests.species[tid] >= 4 and forests.state[tid] == 0:
			best = tid
			break
	var normal := -1
	for tid in forests.count():
		if forests.species[tid] < 4 and forests.state[tid] == 0:
			normal = tid
			break
	var prized: RigidBody3D = forests.apply_event(best, "fell", main)
	var plain: RigidBody3D = forests.apply_event(normal, "fell", main)
	print("%s log worth $%d, %s log worth $%d" % [forests.SPECIES[forests.species[best]][0], prized.get_meta("value"),
		forests.SPECIES[forests.species[normal]][0], plain.get_meta("value")])
	var tree_at: Vector3 = forests.pos[best]
	main.player.global_position = Vector3(tree_at.x + 6, t.get_height(tree_at.x + 6, tree_at.z) + 1, tree_at.z)
	main._update_anchors()
	await _frames(120)
	var live = forests.node_for(best)
	print("felled tree streamed in as a stump: %s" % (live != null and live.is_stump))
	quit()
