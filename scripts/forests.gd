extends Node3D
## Every tree on the map — thousands of them. Each has a stable id, a species (pines,
## broadleaves, and the valuable swamp cypress and giant oak) and a state: standing,
## stump, or gone. Near the players and the machines in use trees are real
## (fellable, with stumps you dig out); everywhere else each 64 m cell draws its trees
## as a few MultiMeshes. Felled trees stream back in as stumps.

signal felled(tid: int)
signal stump_freed(tid: int)
signal body_spawned(tid: int, body: RigidBody3D, kind: String)

const ForestTree = preload("res://scripts/tree.gd")
const Scenery = preload("res://scripts/scenery.gd")
const Terrain = preload("res://scripts/terrain.gd")

const CELL := 64.0
const GRID := 16  # 1024 m / 64 m
const LIVE_IN := 85.0  # cells come alive within this of an anchor...
const LIVE_OUT := 120.0  # ...and go back to pictures beyond this
const SPAWNS_PER_FRAME := 40
const SPACING := 2.6
const FAR_RANGE := 650.0

## [name, size range, value multiplier]
const SPECIES := [
	["pine", Vector2(0.8, 1.35), 1.0], ["pine", Vector2(0.8, 1.35), 1.0],
	["broadleaf", Vector2(0.8, 1.3), 1.0], ["broadleaf", Vector2(0.8, 1.3), 1.0],
	["swamp cypress", Vector2(1.1, 1.6), 2.4], ["giant oak", Vector2(1.4, 1.9), 3.0],
]

var terrain: Terrain
## Joining players: trees only change when the host says so.
var remote := false
## Where trees must be real: [position, ...] (players, machines in use).
var anchors: Array = []
var meshes: Array = []
## The snowy pine forest (x, z, radius): trees there use snow_meshes (snow-capped pines,
## bare winter broadleaves). Set before setup.
var snow := Vector3.ZERO
var snow_meshes: Array = []
## Leaf colour per species (matches the meshes), for the leaves that shower off a felled tree.
const LEAF_COLORS := [Color(0.2, 0.42, 0.22), Color(0.24, 0.47, 0.25), Color(0.93, 0.72, 0.3),
	Color(0.45, 0.58, 0.25), Color(0.36, 0.42, 0.24), Color(0.3, 0.45, 0.2)]
var pos := PackedVector3Array()
var yaw := PackedFloat32Array()
var size := PackedFloat32Array()
var species := PackedByteArray()
var state := PackedByteArray()  # 0 standing, 1 stump, 2 gone
var cells: Array = []  # per cell: Array of tids
var live := {}  # tid -> ForestTree

var _live_cells := {}
var _dirty_cells := {}  # cells to redraw this frame
var _cell_nodes := {}  # cell -> Node3D of MultiMeshInstance3Ds
var _spawn_queue: Array = []
var _timer := 0.0
var _stump_mesh: Mesh


func setup(terrain_node: Terrain) -> void:
	terrain = terrain_node
	meshes = [Scenery.pine_mesh(Color(0.2, 0.42, 0.22)), Scenery.pine_mesh(Color(0.24, 0.47, 0.25)),
		Scenery.broadleaf_mesh(Color(0.93, 0.72, 0.3)), Scenery.broadleaf_mesh(Color(0.45, 0.58, 0.25)),
		Scenery.cypress_mesh(), Scenery.oak_mesh()]
	var winter := Scenery.winter_tree_mesh()
	snow_meshes = [Scenery.snowy_pine_mesh(Color(0.2, 0.42, 0.22)), Scenery.snowy_pine_mesh(Color(0.24, 0.47, 0.25)),
		winter, winter, winter, winter]
	_stump_mesh = ForestTree.stump_mesh()
	cells.resize(GRID * GRID)
	for k in cells.size():
		cells[k] = []


## Scatters `count` trees in a circle, picking species by `weights` (one per SPECIES entry)
## and skipping spots `avoid(Vector2)` rejects.
func add_forest(center: Vector2, radius: float, count: int, weights: Array, rng: RandomNumberGenerator, avoid: Callable) -> void:
	var total := 0.0
	for w in weights:
		total += float(w)
	var grid := {}  # 3 m buckets for the spacing check
	var placed := 0
	var tries := 0
	while placed < count and tries < count * 6:
		tries += 1
		var p := center + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * radius
		if absf(p.x) > Terrain.HALF_SIZE - 6.0 or absf(p.y) > Terrain.HALF_SIZE - 6.0 or avoid.call(p):
			continue
		var key := Vector2i(floori(p.x / 3.0), floori(p.y / 3.0))
		var crowded := false
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				for q in grid.get(key + Vector2i(dx, dz), []):
					if (q as Vector2).distance_to(p) < SPACING:
						crowded = true
		if crowded:
			continue
		if not grid.has(key):
			grid[key] = []
		grid[key].append(p)
		var pick := rng.randf() * total
		var kind := 0
		for k in weights.size():
			pick -= float(weights[k])
			if pick <= 0.0:
				kind = k
				break
		var range_: Vector2 = SPECIES[kind][1]
		var tid := pos.size()
		pos.append(Vector3(p.x, terrain.sample_height(p.x, p.y), p.y))
		yaw.append(rng.randf() * TAU)
		size.append(rng.randf_range(range_.x, range_.y))
		species.append(kind)
		state.append(0)
		cells[_cell_of(p)].append(tid)
		placed += 1


## Whether a tree stands in the snowy forest.
func in_snow(tid: int) -> bool:
	return snow.z > 0.0 and Vector2(pos[tid].x, pos[tid].z).distance_to(Vector2(snow.x, snow.y)) < snow.z * 0.92


func count() -> int:
	return pos.size()


## Draws every cell (call once the forests are placed).
func finish() -> void:
	for c in cells.size():
		_rebuild_cell(c)


func _cell_of(p: Vector2) -> int:
	var cx := clampi(floori((p.x + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	var cz := clampi(floori((p.y + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	return cz * GRID + cx


func _cell_center(c: int) -> Vector2:
	return Vector2((c % GRID + 0.5) * CELL - Terrain.HALF_SIZE, (c / GRID + 0.5) * CELL - Terrain.HALF_SIZE)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = 0.4
		_update_live()
	for c in _dirty_cells:
		_rebuild_cell(c)
	_dirty_cells.clear()
	var start := Time.get_ticks_usec()
	while not _spawn_queue.is_empty() and Time.get_ticks_usec() - start < 3000:
		var tid: int = _spawn_queue.pop_front()
		if _live_cells.has(_cell_of(Vector2(pos[tid].x, pos[tid].z))) and not live.has(tid) and state[tid] < 2:
			_spawn(tid)


func _update_live() -> void:
	var wanted := {}
	for a in anchors:
		var p: Vector3 = a
		var reach := ceili(LIVE_OUT / CELL)
		var cx := floori((p.x + Terrain.HALF_SIZE) / CELL)
		var cz := floori((p.z + Terrain.HALF_SIZE) / CELL)
		for z in range(maxi(cz - reach, 0), mini(cz + reach, GRID - 1) + 1):
			for x in range(maxi(cx - reach, 0), mini(cx + reach, GRID - 1) + 1):
				var c := z * GRID + x
				var d := _cell_distance(c, Vector2(p.x, p.z))
				if d < LIVE_IN or (d < LIVE_OUT and _live_cells.has(c)):
					wanted[c] = true
	for c in wanted:
		if not _live_cells.has(c):
			_live_cells[c] = true
			for tid in cells[c]:
				if state[tid] < 2:
					_spawn_queue.append(tid)
			_dirty_cells[c] = true  # redrawn with shadows, as live trees cast them
	for c in _live_cells.keys():
		if not wanted.has(c):
			_live_cells.erase(c)
			for tid in cells[c]:
				if live.has(tid):
					(live[tid] as Node).queue_free()
					live.erase(tid)
			_rebuild_cell(c)


## Distance from a point to the nearest edge of a cell (0 inside it).
func _cell_distance(c: int, p: Vector2) -> float:
	var centre := _cell_center(c)
	var dx := maxf(absf(p.x - centre.x) - CELL * 0.5, 0.0)
	var dz := maxf(absf(p.y - centre.y) - CELL * 0.5, 0.0)
	return sqrt(dx * dx + dz * dz)


func _spawn(tid: int) -> void:
	var tree := ForestTree.new()
	tree.tid = tid
	tree.trunk_mesh = snow_meshes[species[tid]] if in_snow(tid) else meshes[species[tid]]
	tree.size = size[tid]
	tree.value_mult = SPECIES[species[tid]][2]
	tree.leaf_color = LEAF_COLORS[species[tid]]
	if in_snow(tid):
		# Pines shake off snow when they fall; bare winter trees have no leaves to lose.
		tree.leaf_color = Color(0.95, 0.96, 0.98) if species[tid] < 2 else Color(0, 0, 0, 0)
	var p := pos[tid]
	tree.position = Vector3(p.x, terrain.get_height(p.x, p.z), p.z)
	tree.rotation.y = yaw[tid]
	tree.pictured = true
	add_child(tree)
	if absf(tree.position.y - p.y) > 0.05:
		_dirty_cells[_cell_of(Vector2(p.x, p.z))] = true  # the ground moved since it was drawn
	if state[tid] == 1:
		tree.become_stump()
	if remote:
		tree.set_remote()
	tree.body_spawned.connect(func(_t: Node3D, body: RigidBody3D, kind: String) -> void: body_spawned.emit(tid, body, kind))
	tree.felled.connect(func(_t: Node3D) -> void:
		state[tid] = 1
		_dirty_cells[_cell_of(Vector2(p.x, p.z))] = true
		felled.emit(tid))
	tree.stump_freed.connect(func(_t: Node3D) -> void:
		state[tid] = 2
		live.erase(tid)
		_dirty_cells[_cell_of(Vector2(p.x, p.z))] = true
		stump_freed.emit(tid))
	live[tid] = tree


## The cell's trees as pictures: one MultiMesh per species, plus stumps. Standing trees
## near players are physics nodes drawn by these too (where the node stands), and those
## cells cast shadows.
func _rebuild_cell(c: int) -> void:
	if _cell_nodes.has(c):
		(_cell_nodes[c] as Node).queue_free()
		_cell_nodes.erase(c)
	if cells[c].is_empty():
		return
	var groups := {}  # species (or -1 for stumps) -> transforms
	for tid in cells[c]:
		if state[tid] == 2:
			continue
		var key := -1 if state[tid] == 1 else int(species[tid]) + (10 if in_snow(tid) else 0)
		if not groups.has(key):
			groups[key] = []
		var s := size[tid]
		var scale := Vector3(s, 1.0, s) if key == -1 else Vector3.ONE * s
		var at := pos[tid]
		var node: Node3D = live.get(tid)
		if is_instance_valid(node):
			at = node.position
		groups[key].append(Transform3D(Basis(Vector3.UP, yaw[tid]).scaled(scale), at))
	var holder := Node3D.new()
	add_child(holder)
	for key in groups:
		var xforms: Array = groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _stump_mesh if key == -1 else (snow_meshes[key - 10] if key >= 10 else meshes[key])
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _live_cells.has(c) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = FAR_RANGE
		mmi.visibility_range_end_margin = 60.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		holder.add_child(mmi)
	_cell_nodes[c] = holder


# --- Queries --------------------------------------------------------------------------------

func node_for(tid: int) -> Node3D:
	var t: Node3D = live.get(tid)
	return t if is_instance_valid(t) else null


## Nearest stump to `from` (Vector3.INF if none), searching outward cell by cell.
func nearest_stump(from: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	var cx := clampi(floori((from.x + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	var cz := clampi(floori((from.z + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	for ring in GRID:
		for z in range(cz - ring, cz + ring + 1):
			for x in range(cx - ring, cx + ring + 1):
				if x < 0 or z < 0 or x >= GRID or z >= GRID or maxi(absi(x - cx), absi(z - cz)) != ring:
					continue
				for tid in cells[z * GRID + x]:
					if state[tid] == 1:
						var d := from.distance_to(pos[tid])
						if d < best_d:
							best_d = d
							best = pos[tid]
		if best_d < ring * CELL:
			break
	return best


## True if a standing tree is within `radius` of `p`.
func tree_near(p: Vector2, radius: float) -> bool:
	for c in _cells_around(p, radius):
		for tid in cells[c]:
			if state[tid] == 0 and Vector2(pos[tid].x, pos[tid].z).distance_to(p) < radius:
				return true
	return false


## Standing trees in a world rectangle (for the minimap).
func standing_in(rect: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for c in _cells_around(rect.get_center(), maxf(rect.size.x, rect.size.y) * 0.75):
		for tid in cells[c]:
			if state[tid] == 0:
				var q := Vector2(pos[tid].x, pos[tid].z)
				if rect.has_point(q):
					out.append(q)
	return out


## Live stumps inside a world rectangle (so digging round them can free them).
func live_stumps_in(rect: Rect2) -> Array:
	var out := []
	for tid in live:
		var t: Node3D = live[tid]
		if is_instance_valid(t) and t.is_stump and rect.has_point(Vector2(t.global_position.x, t.global_position.z)):
			out.append(t)
	return out


func _cells_around(p: Vector2, radius: float) -> Array:
	var out := []
	var x0 := clampi(floori((p.x - radius + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	var x1 := clampi(floori((p.x + radius + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	var z0 := clampi(floori((p.y - radius + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	var z1 := clampi(floori((p.y + radius + Terrain.HALF_SIZE) / CELL), 0, GRID - 1)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			out.append(z * GRID + x)
	return out


# --- Network (joining players) --------------------------------------------------------------

## Fells or uproots a tree whether or not it's live (the host's tools, and joining
## players copying the host). Returns the log / stump body it made.
func apply_event(tid: int, event: String, parent: Node) -> RigidBody3D:
	if tid < 0 or tid >= pos.size():
		return null
	var tree := node_for(tid)
	var body: RigidBody3D
	if event == "fell" and state[tid] == 0:
		if tree:
			body = tree.fell(Vector3.FORWARD)
		else:
			state[tid] = 1
			body = ForestTree.make_log(parent, Transform3D(Basis(Vector3.UP, yaw[tid]), pos[tid] + Vector3(0, 0.05, 0)),
					size[tid], meshes[species[tid]], SPECIES[species[tid]][2])
			_rebuild_cell(_cell_of(Vector2(pos[tid].x, pos[tid].z)))
			body_spawned.emit(tid, body, "log")
			felled.emit(tid)
	elif event == "pulled" and state[tid] < 2:
		if state[tid] == 0:
			apply_event(tid, "fell", parent)
			tree = node_for(tid)
		if tree:
			body = tree.pull_out()
		else:
			state[tid] = 2
			body = ForestTree.make_stump(parent, Transform3D(Basis(Vector3.UP, yaw[tid]), pos[tid] + Vector3(0, 0.15, 0)),
					size[tid], SPECIES[species[tid]][2])
			_rebuild_cell(_cell_of(Vector2(pos[tid].x, pos[tid].z)))
			body_spawned.emit(tid, body, "stump")
			stump_freed.emit(tid)
	return body
