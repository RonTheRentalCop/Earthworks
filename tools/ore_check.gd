extends SceneTree
## Ore: boulders lie about the map, digging deep turns up ore (what depends on where),
## and the ore crusher at the quarry pays for it. Run:
##   godot --headless --path . -s tools/ore_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _ores() -> Array:
	var out := []
	for id in main.bodies:
		var b = main.bodies[id]
		if is_instance_valid(b) and b.has_meta("ore") and int(id) >= main.FIRST_DYNAMIC_ID:
			out.append(b)
	return out


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var kinds := {}
	for b in main.debris:
		if b.has_meta("ore"):
			kinds[b.get_meta("ore")] = int(kinds.get(b.get_meta("ore"), 0)) + 1
	print("boulders on the map: %s" % kinds)
	# Dig three deep holes (a bucket at a time) in different places, and see what turns up.
	for spot in [main.QUARRY + Vector2(10, -40), Vector2(-90, 400), Vector2(0, 180)]:
		var before := _ores().size()
		main.player.global_position = Vector3(spot.x + 6, t.get_height(spot.x + 6, spot.y) + 1, spot.y)
		main._update_anchors()
		await _frames(20)
		var found := {}
		for k in 60:
			var c := Vector3(spot.x + (k % 4) * 1.5, t.get_height(spot.x, spot.y) - 0.5, spot.y + (k / 4 % 4) * 1.5)
			t.dig(c, 1.4, 2.0)
			await physics_frame
		for b in _ores().slice(before):
			found[b.get_meta("ore")] = int(found.get(b.get_meta("ore"), 0)) + 1
		print("dug a %.1f m deep pit at %s: found %s" % [t.dug_depth(spot.x, spot.y), spot, found])
	# Sell the best find at the crusher.
	var all := _ores()
	if all.is_empty():
		print("nothing found to sell")
		quit()
		return
	all.sort_custom(func(a, b): return int(a.get_meta("value")) > int(b.get_meta("value")))
	var chunk: RigidBody3D = all[0]
	var crusher = main.shredders[main.shredders.size() - 1]
	var money: int = main.career.money
	main.player.global_position = crusher.infeed_point() + Vector3(0, 1, 8)
	main._update_anchors()
	await _frames(30)
	chunk.global_position = crusher.infeed_point() + Vector3(0, 1.2, 0)
	chunk.linear_velocity = Vector3.ZERO
	await _frames(240)
	print("sold the %s at the %s: cash +%d" % [chunk.get_meta("label") if is_instance_valid(chunk) else "chunk", crusher.machine_name, main.career.money - money])
	quit()
