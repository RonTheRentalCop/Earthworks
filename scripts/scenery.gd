extends RefCounted
## Builds the world's set dressing: tree meshes and forests (destructible trees inside
## the map, a decorative ring outside it) and the construction depot you spawn in:
## fenced gravel yard with gate, guard booth and weighbridge, workshop shed, two-storey
## office, lunch room, fuel station, material bays, container yard, wash bay, parking
## bays, parked pickups and roller, scaffolding, light towers and site clutter.

const ForestTree = preload("res://scripts/tree.gd")
const Terrain = preload("res://scripts/terrain.gd")

const PROP_LAYER := 4  # loose props behave like debris
const PROP_MASK := 1 | 2 | 4 | 8 | 32 | 64
const STATIC_LAYER := 32  # solid site buildings block machines like stumps do

## Half-size of the depot yard (x, z), and the material bays (relative to its centre).
const ZONE_HALF := Vector2(36, 26)
const BAYS: Array[Vector2] = [Vector2(-31, -14), Vector2(-25, -14), Vector2(-19, -14)]

static var _materials := {}


static func pine_mesh(foliage: Color) -> ArrayMesh:
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.14
	trunk.bottom_radius = 0.24
	trunk.height = 1.6
	trunk.radial_segments = 8
	var cones: Array = []
	for c in [[1.5, 2.4, 2.1], [1.15, 2.1, 3.4], [0.8, 1.8, 4.6], [0.45, 1.3, 5.6]]:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = c[0]
		cone.height = c[1]
		cone.radial_segments = 12
		cone.rings = 1
		cones.append([cone, Vector3(0, c[2], 0)])
	var mesh := ArrayMesh.new()
	_merge_surface(mesh, [[trunk, Vector3(0, 0.8, 0)]], Color(0.4, 0.26, 0.16))
	_merge_surface(mesh, cones, foliage)
	return mesh


static func broadleaf_mesh(foliage: Color) -> ArrayMesh:
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.16
	trunk.bottom_radius = 0.26
	trunk.height = 2.6
	trunk.radial_segments = 8
	var blobs: Array = []
	for b in [[1.6, Vector3(0, 3.6, 0)], [1.1, Vector3(0.9, 3.2, 0.3)], [1.0, Vector3(-0.8, 3.4, -0.4)], [0.9, Vector3(0.1, 4.6, 0.2)]]:
		var blob := SphereMesh.new()
		blob.radius = b[0]
		blob.height = b[0] * 1.7
		blob.radial_segments = 10
		blob.rings = 5
		blobs.append([blob, b[1]])
	var mesh := ArrayMesh.new()
	_merge_surface(mesh, [[trunk, Vector3(0, 1.3, 0)]], Color(0.42, 0.28, 0.17))
	_merge_surface(mesh, blobs, foliage)
	return mesh


## Scatters destructible trees in a circle, skipping spots `avoid(Vector2)` rejects.
static func spawn_forest(parent: Node3D, terrain: Terrain, center: Vector2, radius: float, count: int,
		rng: RandomNumberGenerator, meshes: Array, avoid: Callable) -> Array[Node3D]:
	var trees: Array[Node3D] = []
	var tries := 0
	while trees.size() < count and tries < count * 8:
		tries += 1
		var p := center + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * radius
		if avoid.call(p):
			continue
		var too_close := false
		for t in trees:
			if Vector2(t.position.x, t.position.z).distance_to(p) < 2.6:
				too_close = true
				break
		if too_close:
			continue
		var tree := ForestTree.new()
		tree.trunk_mesh = meshes[rng.randi() % meshes.size()]
		tree.size = rng.randf_range(0.8, 1.35)
		tree.position = Vector3(p.x, terrain.get_height(p.x, p.y), p.y)
		tree.rotation.y = rng.randf() * TAU
		parent.add_child(tree)
		trees.append(tree)
	return trees


## Non-interactive forest ringing the map.
static func tree_ring(parent: Node3D, inner: float, outer: float, count: int) -> void:
	var green := pine_mesh(Color(0.2, 0.42, 0.22))
	var golden := pine_mesh(Color(0.93, 0.72, 0.3))
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var spots: Array[Transform3D] = []
	var gold_spots: Array[Transform3D] = []
	while spots.size() + gold_spots.size() < count:
		var p := Vector2(rng.randf_range(-outer, outer), rng.randf_range(-outer, outer))
		if maxf(absf(p.x), absf(p.y)) < inner:
			continue
		var s := rng.randf_range(0.8, 1.7)
		var xform := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), Vector3(p.x, 0, p.y))
		if rng.randf() < 0.12:
			gold_spots.append(xform)
		else:
			spots.append(xform)
	for pair in [[green, spots], [golden, gold_spots]]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pair[0]
		var xforms: Array[Transform3D] = pair[1]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = mm
		parent.add_child(instance)


## Shapes the ground for the depot (call before terrain.finalize()); returns the pad height.
static func prepare_zone(terrain: Terrain, center: Vector2) -> float:
	var level := terrain.flatten(center, ZONE_HALF, 8.0)
	terrain.paint_gravel(center, ZONE_HALF + Vector2(1.5, 1.5))
	# Haul road out of the gate.
	var road := center + Vector2(0, -ZONE_HALF.y - 12.0)
	terrain.flatten(road, Vector2(5.0, 12.0), 5.0, level)
	terrain.paint_gravel(road, Vector2(4.5, 12.0))
	# Stockpiles in the material bays, plus a soil heap by the parking row for loading practice.
	for bay in BAYS:
		var pile := center + bay + Vector2(0, 0.4)
		terrain.add_mound(pile, 2.4, 1.8)
		terrain.mark_disturbed(pile, 2.4)
	var heap := center + Vector2(-8, -9)
	terrain.add_mound(heap, 4.0, 2.2)
	terrain.mark_disturbed(heap, 4.0)
	return level


## Builds the construction depot; returns loose props (cones, barriers, drums, pipes).
static func build_zone(parent: Node3D, center: Vector2, level: float) -> Array[RigidBody3D]:
	var props: Array[RigidBody3D] = []
	var o := Vector3(center.x, level, center.y)
	var white := Color(0.92, 0.92, 0.9)
	var glass := Color(0.15, 0.22, 0.3)
	var concrete := Color(0.7, 0.7, 0.68)
	var steel := Color(0.55, 0.57, 0.6)
	var hx := ZONE_HALF.x
	var hz := ZONE_HALF.y

	# --- Perimeter fence with a gate on the north side, guard booth and raised barrier.
	var spans := 24
	for i in spans:
		var x := -hx + i * (2.0 * hx / spans)
		var x2 := x + 2.0 * hx / spans
		_fence_panel(parent, o + Vector3(x, 0, hz), o + Vector3(x2, 0, hz))
		if absf((x + x2) * 0.5) > 8.0:
			_fence_panel(parent, o + Vector3(x, 0, -hz), o + Vector3(x2, 0, -hz))
	for i in 18:
		var z := -hz + i * (2.0 * hz / 18)
		var z2 := z + 2.0 * hz / 18
		_fence_panel(parent, o + Vector3(hx, 0, z), o + Vector3(hx, 0, z2))
		_fence_panel(parent, o + Vector3(-hx, 0, z), o + Vector3(-hx, 0, z2))
	var booth := o + Vector3(11, 0, -hz + 3.0)
	_static_box(parent, Vector3(2.4, 2.6, 2.4), booth + Vector3(0, 1.3, 0), white)
	_visual_box(parent, Vector3(2.5, 0.12, 2.5), booth + Vector3(0, 2.66, 0), Color(0.25, 0.4, 0.65))
	_visual_box(parent, Vector3(1.6, 0.8, 0.05), booth + Vector3(0, 1.7, -1.22), glass)
	_label(parent, "SECURITY", booth + Vector3(0, 2.35, -1.25), 0.004, Color(0.15, 0.2, 0.35))
	_static_box(parent, Vector3(0.4, 1.1, 0.4), o + Vector3(8.6, 0.55, -hz), Color(0.9, 0.85, 0.2))
	for k in 6:  # barrier arm, raised, red and white
		_visual_box(parent, Vector3(0.14, 0.7, 0.14), o + Vector3(8.6, 1.45 + k * 0.7, -hz), Color(0.85, 0.15, 0.1) if k % 2 == 0 else white)

	# --- Weighbridge across the gate road, with its office.
	_static_box(parent, Vector3(4.0, 0.22, 14.0), o + Vector3(0, 0.11, -hz + 9.0), Color(0.42, 0.44, 0.46))
	for k in 6:
		_visual_box(parent, Vector3(4.02, 0.03, 0.12), o + Vector3(0, 0.23, -hz + 3.0 + k * 2.4), Color(0.9, 0.75, 0.1))
	var scale_house := o + Vector3(-5.5, 0, -hz + 9.0)
	_static_box(parent, Vector3(3.0, 2.5, 2.6), scale_house + Vector3(0, 1.25, 0), white)
	_visual_box(parent, Vector3(0.05, 0.8, 1.6), scale_house + Vector3(1.52, 1.6, 0), glass)
	_label(parent, "WEIGHBRIDGE", scale_house + Vector3(0, 2.25, -1.32), 0.004, Color(0.15, 0.2, 0.35))

	# --- Workshop: a big steel shed, open on the north side, with benches and drums inside.
	var shed := o + Vector3(-21, 0, 13)
	var shed_size := Vector3(22, 7, 14)
	var cladding := Color(0.55, 0.62, 0.68)
	_static_box(parent, Vector3(shed_size.x, shed_size.y, 0.25), shed + Vector3(0, shed_size.y * 0.5, shed_size.z * 0.5), cladding)
	for side in [-1.0, 1.0]:
		_static_box(parent, Vector3(0.25, shed_size.y, shed_size.z), shed + Vector3(side * shed_size.x * 0.5, shed_size.y * 0.5, 0), cladding)
		_static_box(parent, Vector3(4.0, shed_size.y, 0.25), shed + Vector3(side * 9.0, shed_size.y * 0.5, -shed_size.z * 0.5), cladding)
	_static_box(parent, Vector3(14.0, 1.6, 0.25), shed + Vector3(0, shed_size.y - 0.8, -shed_size.z * 0.5), cladding)
	for side in [-1.0, 1.0]:  # pitched roof
		var roof := Node3D.new()
		parent.add_child(roof)
		roof.position = shed + Vector3(0, shed_size.y + 0.9, side * shed_size.z * 0.25)
		roof.rotation.x = -0.24 * side
		_child_box(roof, Vector3(shed_size.x + 0.6, 0.18, shed_size.z * 0.55), Vector3.ZERO, Color(0.45, 0.5, 0.55))
	for k in 6:  # cladding ribs
		var x := -10.0 + k * 4.0
		_visual_box(parent, Vector3(0.12, shed_size.y, 0.08), shed + Vector3(x, shed_size.y * 0.5, shed_size.z * 0.5 + 0.15), cladding.darkened(0.12))
	_label(parent, "WORKSHOP", shed + Vector3(0, shed_size.y - 0.8, -shed_size.z * 0.5 - 0.15), 0.012, Color(0.12, 0.15, 0.2))
	for b in [Vector3(-7, 0, 5.5), Vector3(-1, 0, 5.5), Vector3(5, 0, 5.5)]:  # benches along the back
		_static_box(parent, Vector3(4.0, 0.9, 1.0), shed + b + Vector3(0, 0.45, 0), Color(0.4, 0.3, 0.2))
		_visual_box(parent, Vector3(3.6, 1.4, 0.05), shed + b + Vector3(0, 1.8, 0.75), Color(0.75, 0.7, 0.6))
		for t in 5:
			_visual_box(parent, Vector3(0.08, 0.35, 0.04), shed + b + Vector3(-1.4 + t * 0.7, 1.9, 0.72), Color(0.2, 0.2, 0.22))
	_static_box(parent, Vector3(1.2, 1.0, 1.6), shed + Vector3(7.5, 0.5, 2.0), Color(0.25, 0.25, 0.28))  # engine block
	_static_box(parent, Vector3(0.2, 3.5, 0.2), shed + Vector3(6.4, 1.75, 2.0), Color(0.85, 0.6, 0.1))  # hoist
	_visual_box(parent, Vector3(2.6, 0.2, 0.2), shed + Vector3(7.5, 3.4, 2.0), Color(0.85, 0.6, 0.1))
	for d in 6:
		props.append(_drum(parent, shed + Vector3(-9.5 + (d % 3) * 0.7, 0.45, -1.0 + floorf(d / 3.0) * 0.7),
				[Color(0.15, 0.35, 0.65), Color(0.75, 0.15, 0.1), Color(0.2, 0.5, 0.3)][d % 3]))
	# Scaffolding against the shed's east wall.
	var scaffold := shed + Vector3(shed_size.x * 0.5 + 1.0, 0, -2)
	for sx in [0.0, 1.6]:
		for sz in [0.0, 2.0, 4.0]:
			_static_box(parent, Vector3(0.06, 6.0, 0.06), scaffold + Vector3(sx, 3.0, sz), steel)
	for level_y in [2.0, 4.0, 5.9]:
		_visual_box(parent, Vector3(1.7, 0.06, 4.2), scaffold + Vector3(0.8, level_y, 2.0), Color(0.6, 0.45, 0.25))

	# --- Two-storey site office with stairs, and a lunch room.
	var office := o + Vector3(18, 0, 18)
	for storey in 2:
		var y := storey * 2.7
		_static_box(parent, Vector3(7.0, 2.6, 3.0), office + Vector3(0, y + 1.3, 0), white)
		_visual_box(parent, Vector3(7.02, 0.22, 3.02), office + Vector3(0, y + 0.2, 0), Color(0.2, 0.35, 0.6))
		for wx in [-2.2, 0.4, 2.4]:
			_visual_box(parent, Vector3(1.0, 0.8, 0.05), office + Vector3(wx, y + 1.65, -1.52), glass)
	_visual_box(parent, Vector3(7.2, 0.15, 3.2), office + Vector3(0, 5.48, 0), Color(0.5, 0.5, 0.52))
	_visual_box(parent, Vector3(0.9, 1.9, 0.05), office + Vector3(-1.0, 1.15, -1.52), Color(0.25, 0.4, 0.65))
	_label(parent, "SITE OFFICE", office + Vector3(0, 5.0, -1.55), 0.008, Color(0.15, 0.2, 0.35))
	var stairs := office + Vector3(4.3, 0, -0.5)
	for step in 12:
		_static_box(parent, Vector3(1.0, 0.22, 0.3), stairs + Vector3(0, 0.12 + step * 0.225, 1.6 - step * 0.28), steel)
	_static_box(parent, Vector3(1.2, 0.15, 1.4), stairs + Vector3(0, 2.7, -2.0), steel)
	_visual_box(parent, Vector3(0.05, 1.0, 3.6), stairs + Vector3(0.55, 2.0, 0.0), steel)
	var lunch := o + Vector3(28.5, 0, 18)
	_static_box(parent, Vector3(6.0, 2.6, 2.6), lunch + Vector3(0, 1.3, 0), Color(0.9, 0.88, 0.8))
	_visual_box(parent, Vector3(6.1, 0.12, 2.7), lunch + Vector3(0, 2.66, 0), Color(0.5, 0.5, 0.52))
	for wx in [-1.6, 1.6]:
		_visual_box(parent, Vector3(1.0, 0.8, 0.05), lunch + Vector3(wx, 1.7, -1.32), glass)
	_label(parent, "LUNCH ROOM", lunch + Vector3(0, 2.35, -1.35), 0.005, Color(0.15, 0.2, 0.35))
	for t in 2:
		var loo := o + Vector3(34, 0, 13.5 + t * 1.5)
		_static_box(parent, Vector3(1.1, 2.3, 1.1), loo + Vector3(0, 1.15, 0), Color(0.2, 0.45, 0.8))
		_visual_box(parent, Vector3(1.2, 0.1, 1.2), loo + Vector3(0, 2.35, 0), white)

	# --- Fuel station: bunded tank and a pump island under a canopy.
	var tank_pos := o + Vector3(29, 0, -12)
	_static_box(parent, Vector3(6.0, 0.5, 3.4), tank_pos + Vector3(0, 0.25, 0), concrete)
	var tank := CylinderMesh.new()
	tank.top_radius = 1.1
	tank.bottom_radius = 1.1
	tank.height = 4.6
	tank.radial_segments = 16
	_static_mesh(parent, tank, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), tank_pos + Vector3(0, 1.75, 0)), Color(0.35, 0.5, 0.3), Vector3(4.6, 2.2, 2.2))
	_label(parent, "DIESEL", tank_pos + Vector3(0, 1.8, -1.13), 0.008, Color.WHITE)
	var pump := o + Vector3(21, 0, -12)
	_static_box(parent, Vector3(1.4, 0.3, 4.0), pump + Vector3(0, 0.15, 0), concrete)
	_static_box(parent, Vector3(0.7, 1.7, 0.5), pump + Vector3(0, 1.15, 0), Color(0.85, 0.2, 0.15))
	_visual_box(parent, Vector3(0.5, 0.3, 0.05), pump + Vector3(0, 1.6, -0.27), Color(0.1, 0.1, 0.1))
	for c in [Vector3(-2.5, 0, -2.5), Vector3(2.5, 0, -2.5), Vector3(-2.5, 0, 2.5), Vector3(2.5, 0, 2.5)]:
		_static_box(parent, Vector3(0.2, 4.6, 0.2), pump + c + Vector3(0, 2.3, 0), white)
	_visual_box(parent, Vector3(6.0, 0.4, 6.0), pump + Vector3(0, 4.8, 0), white)
	_visual_box(parent, Vector3(6.04, 0.12, 6.04), pump + Vector3(0, 4.65, 0), Color(0.85, 0.2, 0.15))

	# --- Material bays: concrete block bins holding the stockpiles.
	for bay in BAYS:
		var bin := o + Vector3(bay.x, 0, bay.y)
		for row in 2:
			var y := 0.4 + row * 0.8
			for k in 4:
				_static_box(parent, Vector3(1.6, 0.8, 0.8), bin + Vector3(-2.4 + k * 1.6, y, -2.6), concrete)
			for side in [-1.0, 1.0]:
				for k in 3:
					_static_box(parent, Vector3(0.8, 0.8, 1.6), bin + Vector3(side * 2.8, y, -1.4 + k * 1.6), concrete)
	_label(parent, "GRAVEL      SAND      TOPSOIL", o + Vector3(BAYS[1].x, 2.2, BAYS[1].y - 3.05), 0.01, Color(0.15, 0.15, 0.15))

	# --- Container yard.
	for c in [[Vector3(30, 0, 1), Color(0.85, 0.42, 0.15), 0.0], [Vector3(30, 0, 4), Color(0.2, 0.42, 0.65), 0.0],
			[Vector3(30, 2.6, 1), Color(0.3, 0.55, 0.3), 0.0], [Vector3(22, 0, 7), Color(0.75, 0.2, 0.15), PI * 0.5]]:
		var base: Vector3 = o + (c[0] as Vector3)
		var container := StaticBody3D.new()
		container.collision_layer = STATIC_LAYER
		parent.add_child(container)
		container.position = base
		container.rotation.y = c[2]
		var shape := BoxShape3D.new()
		shape.size = Vector3(6.0, 2.6, 2.44)
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position.y = 1.3
		container.add_child(col)
		_child_box(container, Vector3(6.0, 2.6, 2.44), Vector3(0, 1.3, 0), c[1])
		for k in 10:
			_child_box(container, Vector3(0.12, 2.4, 2.5), Vector3(-2.7 + k * 0.6, 1.3, 0), (c[1] as Color).darkened(0.15))

	# --- Wash bay.
	var wash := o + Vector3(6, 0, -8)
	_static_box(parent, Vector3(8.0, 0.12, 6.0), wash + Vector3(0, 0.06, 0), concrete.darkened(0.1))
	for side in [-1.0, 1.0]:
		_static_box(parent, Vector3(0.2, 2.2, 0.2), wash + Vector3(side * 4.2, 1.1, -2.6), steel)
		_visual_box(parent, Vector3(0.5, 0.5, 0.3), wash + Vector3(side * 4.2, 1.4, -2.4), Color(0.85, 0.65, 0.1))
	_label(parent, "WASH BAY", wash + Vector3(0, 2.0, -2.7), 0.006, Color(0.15, 0.2, 0.35))

	# --- Parking bays for the machines (painted lines) and parked vehicles.
	for k in 6:
		_visual_box(parent, Vector3(0.14, 0.02, 7.0), o + Vector3(-6.5 + k * 6.5, 0.02, 9.5), white)
	_visual_box(parent, Vector3(32.5, 0.02, 0.14), o + Vector3(9.75, 0.02, 13.0), white)
	_pickup(parent, o + Vector3(14, 0, -4), Color(0.95, 0.95, 0.95))
	_pickup(parent, o + Vector3(18, 0, -4), Color(0.2, 0.4, 0.75))
	_roller(parent, o + Vector3(23, 0, 9.5))

	# --- Yard odds and ends.
	var pipe_base := o + Vector3(4, 0, 21)
	for row in 3:
		for k in 3 - row:
			props.append(_pipe(parent, pipe_base + Vector3(0, 0.62 + row * 1.08, (k - (2 - row) * 0.5) * 1.26)))
	for d in 2:  # cable drums on their sides
		var drum := CylinderMesh.new()
		drum.top_radius = 0.9
		drum.bottom_radius = 0.9
		drum.height = 0.9
		drum.radial_segments = 14
		_static_mesh(parent, drum, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), o + Vector3(-2.5 + d * 1.2, 0.9, 21.5)), Color(0.55, 0.4, 0.25), Vector3(0.9, 1.8, 1.8))
	for r in 12:  # rebar bundle
		_visual_box(parent, Vector3(6.0, 0.05, 0.05), o + Vector3(-8, 0.3 + (r % 3) * 0.06, 21.0 + floorf(r / 3.0) * 0.06), Color(0.45, 0.3, 0.22))
	_static_box(parent, Vector3(6.0, 0.25, 0.6), o + Vector3(-8, 0.12, 21.1), Color(0.6, 0.45, 0.28))
	for px in [9.0, 11.0]:
		var pallet := o + Vector3(px, 0, 21.5)
		_static_box(parent, Vector3(1.2, 0.15, 1.0), pallet + Vector3(0, 0.08, 0), Color(0.6, 0.45, 0.28))
		_visual_box(parent, Vector3(1.1, 0.8, 0.9), pallet + Vector3(0, 0.55, 0), Color(0.72, 0.32, 0.22))
	for c in [Vector3(-34, 0, -22), Vector3(34, 0, -22), Vector3(34, 0, 23.5)]:
		_light_tower(parent, o + c)
	for b in [[Vector3(-10, 0, -22.5), 0.0], [Vector3(-12.2, 0, -22.5), 0.0], [Vector3(10, 0, -18), PI * 0.5],
			[Vector3(10, 0, -15.8), PI * 0.5], [Vector3(-14, 0, -2), PI * 0.5], [Vector3(-14, 0, 0.2), PI * 0.5]]:
		props.append(_rigid_box(parent, Vector3(2.0, 0.8, 0.6), o + (b[0] as Vector3) + Vector3(0, 0.41, 0), concrete, 900.0, b[1]))
	for c in [Vector3(-3, 0, -24), Vector3(3, 0, -24), Vector3(-3, 0, -12), Vector3(3, 0, -12),
			Vector3(1.5, 0, -10.5), Vector3(10.5, 0, -10.5), Vector3(-1, 0, 1.5), Vector3(13, 0, 1.5),
			Vector3(-1, 0, -4), Vector3(25, 0, -6), Vector3(17, 0, -9), Vector3(-16, 0, -8)]:
		props.append(_cone(parent, o + c))
	# Company sign at the gate, readable from both sides.
	var sign := o + Vector3(0, 0, -hz - 1.6)
	_static_box(parent, Vector3(0.15, 3.2, 0.15), sign + Vector3(-3.6, 1.6, 0), Color(0.4, 0.3, 0.2))
	_static_box(parent, Vector3(0.15, 3.2, 0.15), sign + Vector3(3.6, 1.6, 0), Color(0.4, 0.3, 0.2))
	_visual_box(parent, Vector3(7.6, 1.6, 0.1), sign + Vector3(0, 2.7, 0), Color(0.98, 0.78, 0.15))
	for face in [-1.0, 1.0]:
		_label(parent, "EARTHWORKS CO.", sign + Vector3(0, 2.95, 0.07 * face), 0.012, Color(0.12, 0.1, 0.08), face > 0.0)
		_label(parent, "CONSTRUCTION DEPOT  ·  HARD HATS ON", sign + Vector3(0, 2.4, 0.07 * face), 0.006, Color(0.12, 0.1, 0.08), face > 0.0)
	return props


static func _light_tower(parent: Node3D, base: Vector3) -> void:
	_static_box(parent, Vector3(1.5, 0.9, 3.0), base + Vector3(0, 0.75, 0), Color(0.95, 0.75, 0.15))
	_visual_box(parent, Vector3(0.14, 7.0, 0.14), base + Vector3(0, 4.7, 0.6), Color(0.6, 0.6, 0.6))
	_visual_box(parent, Vector3(1.8, 0.7, 0.3), base + Vector3(0, 8.2, 0.6), Color(0.2, 0.2, 0.2))
	for lx in [-0.6, 0.0, 0.6]:
		_visual_box(parent, Vector3(0.5, 0.45, 0.05), base + Vector3(lx, 8.2, 0.43), Color(1.0, 0.97, 0.8), true)


static func _drum(parent: Node3D, pos: Vector3, color: Color) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = 180.0
	body.collision_layer = PROP_LAYER
	body.collision_mask = PROP_MASK
	var shape := CylinderShape3D.new()
	shape.radius = 0.3
	shape.height = 0.9
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.3
	mesh.bottom_radius = 0.3
	mesh.height = 0.9
	mesh.radial_segments = 12
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color)
	body.add_child(instance)
	body.position = pos
	parent.add_child(body)
	body.sleeping = true
	return body


## A parked pickup truck (scenery).
static func _pickup(parent: Node3D, pos: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = STATIC_LAYER
	parent.add_child(body)
	body.position = pos
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.0, 1.8, 5.3)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 0.95
	body.add_child(col)
	_child_box(body, Vector3(2.0, 0.7, 5.3), Vector3(0, 0.85, 0), color)
	_child_box(body, Vector3(1.9, 0.75, 2.2), Vector3(0, 1.55, -0.6), color)
	_child_box(body, Vector3(1.92, 0.5, 2.0), Vector3(0, 1.6, -0.6), Color(0.15, 0.22, 0.3))
	for side in [-1.0, 1.0]:
		_child_box(body, Vector3(0.08, 0.45, 2.1), Vector3(side * 0.96, 1.42, 1.55), color)
	_child_box(body, Vector3(1.9, 0.08, 0.3), Vector3(0, 1.95, -0.6), Color(1.0, 0.6, 0.1))
	for wx in [-0.95, 0.95]:
		for wz in [-1.7, 1.7]:
			var wheel := CylinderMesh.new()
			wheel.top_radius = 0.4
			wheel.bottom_radius = 0.4
			wheel.height = 0.3
			wheel.radial_segments = 12
			var instance := MeshInstance3D.new()
			instance.mesh = wheel
			instance.rotation.z = PI * 0.5
			instance.position = Vector3(wx, 0.4, wz)
			instance.material_override = _material(Color(0.12, 0.12, 0.12))
			body.add_child(instance)


## A parked smooth-drum road roller (scenery).
static func _roller(parent: Node3D, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = STATIC_LAYER
	parent.add_child(body)
	body.position = pos
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.3, 2.8, 5.2)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 1.4
	body.add_child(col)
	var drum := CylinderMesh.new()
	drum.top_radius = 0.75
	drum.bottom_radius = 0.75
	drum.height = 2.1
	drum.radial_segments = 18
	var drum_mesh := MeshInstance3D.new()
	drum_mesh.mesh = drum
	drum_mesh.rotation.z = PI * 0.5
	drum_mesh.position = Vector3(0, 0.75, -1.7)
	drum_mesh.material_override = _material(Color(0.55, 0.55, 0.57))
	body.add_child(drum_mesh)
	var yellow := Color(0.96, 0.7, 0.1)
	_child_box(body, Vector3(2.3, 0.3, 1.8), Vector3(0, 1.6, -1.7), yellow)
	_child_box(body, Vector3(1.9, 1.1, 2.6), Vector3(0, 1.2, 1.0), yellow)
	for side in [-1.0, 1.0]:
		var tyre := CylinderMesh.new()
		tyre.top_radius = 0.6
		tyre.bottom_radius = 0.6
		tyre.height = 0.5
		tyre.radial_segments = 14
		var tyre_mesh := MeshInstance3D.new()
		tyre_mesh.mesh = tyre
		tyre_mesh.rotation.z = PI * 0.5
		tyre_mesh.position = Vector3(side * 0.95, 0.6, 1.3)
		tyre_mesh.material_override = _material(Color(0.12, 0.12, 0.12))
		body.add_child(tyre_mesh)
		for cz in [0.3, 1.5]:
			_child_box(body, Vector3(0.08, 1.4, 0.08), Vector3(side * 0.85, 2.45, cz), yellow)
	_child_box(body, Vector3(1.9, 0.1, 1.4), Vector3(0, 3.15, 0.9), yellow)
	_child_box(body, Vector3(0.6, 0.6, 0.5), Vector3(0, 2.0, 1.3), Color(0.15, 0.15, 0.15))


static func _fence_panel(parent: Node3D, a: Vector3, b: Vector3) -> void:
	var mid := (a + b) * 0.5
	var length := a.distance_to(b)
	var yaw := atan2(-(b.z - a.z), b.x - a.x)
	var body := StaticBody3D.new()
	body.collision_layer = STATIC_LAYER
	body.collision_mask = 0
	parent.add_child(body)
	body.global_transform = Transform3D(Basis(Vector3.UP, yaw), mid)
	var shape := BoxShape3D.new()
	shape.size = Vector3(length, 2.0, 0.08)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 1.0
	body.add_child(col)
	var post := Color(0.55, 0.57, 0.6)
	_child_box(body, Vector3(0.08, 2.1, 0.08), Vector3(-length * 0.5, 1.05, 0), post)
	_child_box(body, Vector3(length, 0.05, 0.05), Vector3(0, 2.0, 0), post)
	_child_box(body, Vector3(length, 0.05, 0.05), Vector3(0, 0.1, 0), post)
	var mesh := MeshInstance3D.new()
	var panel := QuadMesh.new()
	panel.size = Vector2(length, 1.9)
	mesh.mesh = panel
	mesh.position.y = 1.05
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.albedo_color = Color(0.6, 0.62, 0.65, 0.35)
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mesh_mat
	body.add_child(mesh)


static func _cone(parent: Node3D, pos: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = 3.0
	body.collision_layer = PROP_LAYER
	body.collision_mask = PROP_MASK
	var shape := CylinderShape3D.new()
	shape.radius = 0.18
	shape.height = 0.7
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 0.35
	body.add_child(col)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.03
	cone.bottom_radius = 0.18
	cone.height = 0.7
	cone.radial_segments = 10
	var mesh := MeshInstance3D.new()
	mesh.mesh = cone
	mesh.position.y = 0.35
	mesh.material_override = _material(Color(1.0, 0.4, 0.05))
	body.add_child(mesh)
	var band := CylinderMesh.new()
	band.top_radius = 0.105
	band.bottom_radius = 0.125
	band.height = 0.1
	band.radial_segments = 10
	var band_mesh := MeshInstance3D.new()
	band_mesh.mesh = band
	band_mesh.position.y = 0.42
	band_mesh.material_override = _material(Color.WHITE)
	body.add_child(band_mesh)
	_child_box(body, Vector3(0.42, 0.04, 0.42), Vector3(0, 0.02, 0), Color(0.15, 0.15, 0.15))
	body.position = pos
	parent.add_child(body)
	body.sleeping = true
	return body


static func _pipe(parent: Node3D, pos: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = 1200.0
	body.collision_layer = PROP_LAYER
	body.collision_mask = PROP_MASK
	var shape := CylinderShape3D.new()
	shape.radius = 0.6
	shape.height = 2.4
	var col := CollisionShape3D.new()
	col.shape = shape
	col.rotation.z = PI * 0.5
	body.add_child(col)
	var outer := CylinderMesh.new()
	outer.top_radius = 0.6
	outer.bottom_radius = 0.6
	outer.height = 2.4
	outer.radial_segments = 14
	var mesh := MeshInstance3D.new()
	mesh.mesh = outer
	mesh.rotation.z = PI * 0.5
	mesh.material_override = _material(Color(0.72, 0.71, 0.68))
	body.add_child(mesh)
	for side in [-1.0, 1.0]:
		var hole := CylinderMesh.new()
		hole.top_radius = 0.45
		hole.bottom_radius = 0.45
		hole.height = 0.02
		hole.radial_segments = 14
		var hole_mesh := MeshInstance3D.new()
		hole_mesh.mesh = hole
		hole_mesh.rotation.z = PI * 0.5
		hole_mesh.position.x = 1.205 * side
		hole_mesh.material_override = _material(Color(0.15, 0.15, 0.15))
		body.add_child(hole_mesh)
	body.position = pos
	parent.add_child(body)
	body.sleeping = true
	return body


static func _rigid_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, mass: float, yaw: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass
	body.collision_layer = PROP_LAYER
	body.collision_mask = PROP_MASK
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	_child_box(body, size, Vector3.ZERO, color)
	body.position = pos
	body.rotation.y = yaw
	parent.add_child(body)
	body.sleeping = true
	return body


static func _static_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = STATIC_LAYER
	body.collision_mask = 0
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	_child_box(body, size, Vector3.ZERO, color)
	body.position = pos
	parent.add_child(body)


static func _static_mesh(parent: Node3D, mesh: Mesh, xform: Transform3D, color: Color, box: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = STATIC_LAYER
	body.collision_mask = 0
	var shape := BoxShape3D.new()
	shape.size = box
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	body.position = xform.origin
	parent.add_child(body)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.basis = xform.basis
	instance.material_override = _material(color)
	body.add_child(instance)


static func _visual_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, glow := false) -> void:
	var instance := _child_box(parent, size, pos, color)
	if glow:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 1.5
		instance.material_override = mat


static func _child_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.material_override = _material(color)
	parent.add_child(instance)
	return instance


static func _label(parent: Node3D, text: String, pos: Vector3, pixel: float, color: Color, face_south := false) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 96
	label.pixel_size = pixel
	label.modulate = color
	label.outline_size = 0
	label.double_sided = false
	label.position = pos
	label.rotation.y = 0.0 if face_south else PI
	parent.add_child(label)


static func _merge_surface(mesh: ArrayMesh, parts: Array, color: Color) -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		tool.append_from(part[0], 0, Transform3D(Basis.IDENTITY, part[1]))
	tool.commit(mesh)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)


static func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		_materials[color] = mat
	return _materials[color]
