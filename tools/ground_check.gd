extends SceneTree
## The worker never ends up under the ground: walking onto ground whose collision isn't
## built yet, soil dumped on top of them, or being pushed under the surface. Run:
##   godot --headless --path . -s tools/ground_check.gd

var main


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _gap() -> float:
	var p: Vector3 = main.player.global_position
	return p.y - main.terrain.get_height(p.x, p.z)


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var t = main.terrain
	var p = main.player
	# 1. Straight onto far ground with no collision built there yet.
	var far := Vector2(380, -380)
	p.global_position = Vector3(far.x, t.get_height(far.x, far.y) + 1.0, far.y)
	var lowest := INF
	for i in 120:
		await physics_frame
		lowest = minf(lowest, _gap())
	print("onto unbuilt ground: lowest %.2f m relative to the ground, now %.2f (collision there now %s)" % [lowest, _gap(), t.has_collision_at(far.x, far.y)])
	# 2. Soil dumped right on top of them.
	await _frames(60)
	var here := Vector2(p.global_position.x, p.global_position.z)
	t.deposit(here.x, here.y, 12.0, 2.5)
	lowest = INF
	for i in 120:
		await physics_frame
		lowest = minf(lowest, _gap())
	print("buried under 12 m3 of soil: lowest %.2f m, now %.2f m above the new ground" % [lowest, _gap()])
	# 3. Pushed 3 m under the surface.
	p.global_position.y -= 3.0 + _gap()
	await _frames(5)
	print("pushed 3 m under: now %.2f m above the ground" % _gap())
	await _frames(120)
	print("two seconds later: %.2f m above the ground (never fell through: %s)" % [_gap(), _gap() > -0.5])
	quit()
