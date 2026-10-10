extends Node3D
## Shallow water on a 0.5 m grid laid over the terrain. Water flows from higher to
## lower surface levels, so it runs into anything you dig, backs up behind anything
## you dump, and pours off the edge of the map. Rivers are fed by constant-level
## heads at their source. The grid is split into tiles that fall asleep once the
## water in them settles and wake when the terrain or a neighbour changes, so large
## rivers and lakes cost nothing until you disturb them. Ground that floods turns to mud.

const Terrain = preload("res://scripts/terrain.gd")

const STEP := 2  # terrain vertices per water cell
const SIZE := 2049  # Terrain.CELLS / STEP + 1
const CELL := Terrain.CELL_SIZE * STEP
const CELL_AREA := CELL * CELL
const TILE := 32  # 16 m tiles
const TILES := 64  # (SIZE - 1) / TILE
const FLOW := 0.2  # share of the level difference exchanged per tick
const MOMENTUM := 0.55  # share of last tick's flow across an edge that carries on (water keeps moving)
const MAX_SHARE := 0.24  # a cell gives at most this share of its depth to one neighbour
const WET := 0.008
const TILES_PER_FRAME := 3  # far tiles per physics frame; with more awake tiles they take turns
const NEAR_SIM := 90.0  # tiles within this of the camera run every frame...
const SIM_BUDGET_USEC := 2500  # ...as many as fit in this
const WAKE_LEVEL := 0.03  # level difference across a sleeping tile's edge that wakes it
const CALM_EPS := 0.002  # depth change per tick below which a tile counts as settled
const CALM_TICKS := 10
const MESH_INTERVAL := 1.0 / 12.0
const MESH_EPS := 0.004
const MESHES_PER_UPDATE := 10
const VIEW_RANGE := 440.0  # tiles past this aren't drawn, so their meshes wait until they're in view
const NEAR_RANGE := 150.0  # tiles further than this refresh at most once a second

const DEEP := Color(0.2, 0.5, 0.55, 0.93)
const SHALLOW := Color(0.5, 0.82, 0.77, 0.82)
const FOAM := Color(0.95, 0.98, 0.97, 0.95)

var terrain: Terrain
var depth := PackedFloat32Array()
var flow := PackedFloat32Array()
var flux_x := PackedFloat32Array()  # signed flow from cell i to i + 1 on its last tick
var flux_z := PackedFloat32Array()  # signed flow from cell i to i + SIZE

var _ground := PackedFloat32Array()
var _fixed := PackedByteArray()  # 1 = constant-level head or map-edge drain
var _wetted := PackedByteArray()  # 1 = already turned the ground to mud
var _heads := {}  # cell index -> surface level
var _sources: Array[Vector3] = []  # x, z = cell, y = m3 per second
var _awake := PackedByteArray()
var _ground_ready := PackedByteArray()  # per tile: ground heights read from the terrain yet?
var _calm := PackedInt32Array()
var _mesh_change := PackedFloat32Array()  # depth change since the tile's mesh was built
var _snapshots := {}  # tile -> depths at the start of its previous pass
var _wet_boxes := {}  # tile -> Rect2i of its wet cells on the previous pass
var _awake_list: Array[int] = []
var _cursor := 0
var _dirty_meshes := {}
var _mesh_timer := 0.0
var _tile_meshes := {}  # tile -> MeshInstance3D (made when a tile first has water)
var _mesh_built_at := {}  # tile -> time (s) its mesh was last rebuilt
## Where the meshes matter most (the camera); null = everywhere equally.
var focus: Node3D
var _material := ShaderMaterial.new()


func setup(terrain_node: Terrain) -> void:
	terrain = terrain_node
	var count := SIZE * SIZE
	depth.resize(count)
	depth.fill(0.0)
	flow.resize(count)
	flow.fill(0.0)
	flux_x.resize(count)
	flux_x.fill(0.0)
	flux_z.resize(count)
	flux_z.fill(0.0)
	_ground.resize(count)
	_fixed.resize(count)
	_fixed.fill(0)
	_wetted.resize(count)
	_wetted.fill(0)
	for k in SIZE:
		_fixed[k] = 1
		_fixed[(SIZE - 1) * SIZE + k] = 1
		_fixed[k * SIZE] = 1
		_fixed[k * SIZE + SIZE - 1] = 1
	_ground_ready.resize(TILES * TILES)
	_ground_ready.fill(0)
	_awake.resize(TILES * TILES)
	_awake.fill(0)
	_calm.resize(TILES * TILES)
	_mesh_change.resize(TILES * TILES)
	_material.shader = _make_shader()
	terrain.area_changed.connect(_on_terrain_changed)


## Fills a channel along `path` up to `water_depth` above its bed.
func fill_channel(path: PackedVector2Array, beds: PackedFloat32Array, half_width: float, water_depth: float) -> void:
	# Long straight runs are split up so each piece only scans a small box of cells.
	var fine := PackedVector2Array()
	var fine_beds := PackedFloat32Array()
	for k in path.size() - 1:
		var pieces := maxi(ceili(path[k].distance_to(path[k + 1]) / 6.0), 1)
		for j in pieces:
			fine.append(path[k].lerp(path[k + 1], j / float(pieces)))
			fine_beds.append(lerpf(beds[k], beds[k + 1], j / float(pieces)))
	fine.append(path[path.size() - 1])
	fine_beds.append(beds[beds.size() - 1])
	path = fine
	beds = fine_beds
	for s in path.size() - 1:
		var a := path[s]
		var b := path[s + 1]
		var seg := b - a
		var len_sq := maxf(seg.length_squared(), 0.0001)
		var r := _cell_rect((a + b) * 0.5, Vector2(absf(seg.x), absf(seg.y)) * 0.5 + Vector2.ONE * half_width)
		_ensure_ground(r)
		for z in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var w := _cell_to_world(x, z)
				var t := clampf((w - a).dot(seg) / len_sq, 0.0, 1.0)
				if w.distance_to(a + seg * t) > half_width:
					continue
				var i := z * SIZE + x
				var level := lerpf(beds[s], beds[s + 1], t) + water_depth
				depth[i] = maxf(depth[i], level - _ground[i])
				_mark_filled(i)


## Fills every cell within `radius` of `center` up to the surface `level`.
func fill(center: Vector2, radius: float, level: float) -> void:
	var r := _cell_rect(center, Vector2(radius, radius))
	_ensure_ground(r)
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if _cell_to_world(x, z).distance_to(center) <= radius:
				var i := z * SIZE + x
				depth[i] = maxf(depth[i], level - _ground[i])
				_mark_filled(i)


## Holds the water surface at `level` across a line of cells (a river's source).
func add_head(a: Vector2, b: Vector2, level: float) -> void:
	var steps := ceili(a.distance_to(b) / CELL) + 1
	for k in steps:
		var c := _world_to_cell(a.lerp(b, k / float(maxi(steps - 1, 1))))
		_ensure_ground(Rect2i(c, Vector2i.ONE))
		var i := c.y * SIZE + c.x
		_heads[i] = level
		_fixed[i] = 1
		depth[i] = maxf(level - _ground[i], 0.0)
		_wake(c.x / TILE, c.y / TILE)


func add_source(pos: Vector2, rate: float) -> void:
	var c := _world_to_cell(pos)
	_sources.append(Vector3(c.x, rate, c.y))
	_wake(c.x / TILE, c.y / TILE)


func total_volume() -> float:
	var total := 0.0
	for d in depth:
		total += d
	return total * CELL_AREA


func awake_tiles() -> int:
	return _awake_list.size()


func surface_height(wx: float, wz: float) -> float:
	var c := _world_to_cell(Vector2(wx, wz))
	var i := c.y * SIZE + c.x
	return _ground[i] + depth[i]


func depth_at(wx: float, wz: float) -> float:
	var c := _world_to_cell(Vector2(wx, wz))
	return depth[c.y * SIZE + c.x]


func _mark_filled(i: int) -> void:
	if depth[i] > 0.0:
		_wetted[i] = 1
		var t := _tile_of(i)
		_wake(t.x, t.y)


func _physics_process(delta: float) -> void:
	_tick(delta)


func _process(delta: float) -> void:
	_mesh_timer -= delta
	if _mesh_timer <= 0.0:
		_mesh_timer = MESH_INTERVAL
		var built := 0
		for t in _mesh_order():
			if built >= MESHES_PER_UPDATE:
				break
			var mesh := _build_tile(t % TILES, t / TILES)
			if mesh and not _tile_meshes.has(t):
				var mi := MeshInstance3D.new()
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.visibility_range_end = 420.0
				mi.visibility_range_end_margin = 40.0
				mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				add_child(mi)
				_tile_meshes[t] = mi
			if _tile_meshes.has(t):
				(_tile_meshes[t] as MeshInstance3D).mesh = mesh
			_mesh_change[t] = 0.0
			_mesh_built_at[t] = Time.get_ticks_msec() * 0.001
			_dirty_meshes.erase(t)
			built += 1


## Dirty tiles worth rebuilding now, nearest the camera first.
func _mesh_order() -> Array:
	if focus == null or not is_instance_valid(focus):
		return _dirty_meshes.keys()
	var now := Time.get_ticks_msec() * 0.001
	var f := Vector2(focus.global_position.x + Terrain.HALF_SIZE, focus.global_position.z + Terrain.HALF_SIZE) / (TILE * CELL)
	var near_sq := pow(NEAR_RANGE / (TILE * CELL), 2.0)
	var view_sq := pow(VIEW_RANGE / (TILE * CELL), 2.0)
	var ready := []
	for key in _dirty_meshes:
		var t: int = key
		var d := Vector2(t % TILES + 0.5, t / TILES + 0.5).distance_squared_to(f)
		if d > view_sq:
			continue
		if d > near_sq and now - float(_mesh_built_at.get(t, -10.0)) < 1.0:
			continue
		ready.append(Vector2(d, t))
	ready.sort()
	var order := []
	for r in ready:
		order.append(int(r.y))
	return order


## A few awake tiles every physics frame, in turn (an even load rather than bursts).
func _tick(delta: float) -> void:
	for s in _sources:
		var i := int(s.z) * SIZE + int(s.x)
		depth[i] += s.y * delta / CELL_AREA
	for i in _heads:
		depth[i] = maxf(float(_heads[i]) - _ground[i], 0.0)
	# Water near the camera runs every frame (so it visibly flows, fills holes and surges
	# down channels), nearest first within a time budget; the rest take turns.
	var start := Time.get_ticks_usec()
	var near: Array = []
	var done := {}
	if focus and is_instance_valid(focus):
		var f := Vector2(focus.global_position.x + Terrain.HALF_SIZE, focus.global_position.z + Terrain.HALF_SIZE) / (TILE * CELL)
		var reach_sq := pow(NEAR_SIM / (TILE * CELL), 2.0)
		for t in _awake_list:
			var d := Vector2(t % TILES + 0.5, t / TILES + 0.5).distance_squared_to(f)
			if d < reach_sq:
				near.append(Vector2(d, t))
		near.sort()
	for entry in near:
		if Time.get_ticks_usec() - start > SIM_BUDGET_USEC:
			break
		var t := int(entry.y)
		_simulate_tile(t)
		done[t] = true
	var count := mini(_awake_list.size(), TILES_PER_FRAME)
	var tiles: Array[int] = []
	for k in count:
		var t: int = _awake_list[(_cursor + k) % _awake_list.size()]
		if not done.has(t):
			tiles.append(t)
	_cursor = (_cursor + count) % maxi(_awake_list.size(), 1)
	for t in tiles:
		_simulate_tile(t)


func _simulate_tile(t: int) -> void:
	var tx := t % TILES
	var tz := t / TILES
	_ensure_tile_ground(tx, tz)
	_ensure_tile_ground(tx + 1, tz)
	_ensure_tile_ground(tx, tz + 1)
	_ensure_tile_ground(tx - 1, tz)
	_ensure_tile_ground(tx, tz - 1)
	var x0 := tx * TILE
	var z0 := tz * TILE
	var x1 := mini(x0 + TILE + (1 if tx == TILES - 1 else 0), SIZE)
	var z1 := mini(z0 + TILE + (1 if tz == TILES - 1 else 0), SIZE)
	var before := PackedFloat32Array()
	before.resize((x1 - x0) * (z1 - z0))
	var k := 0
	var wx0 := x1
	var wz0 := z1
	var wx1 := x0 - 1
	var wz1 := z0 - 1
	for z in range(z0, z1):
		var row := z * SIZE
		for x in range(x0, x1):
			var i := row + x
			var d := depth[i]
			before[k] = d
			flow[i] *= 0.85
			if d > 0.0:
				if x < wx0:
					wx0 = x
				if x > wx1:
					wx1 = x
				if z < wz0:
					wz0 = z
				if z > wz1:
					wz1 = z
			k += 1
	# Settled = the tile looks the same as on its last pass (a steady river still flows).
	var drift := INF
	var last: PackedFloat32Array = _snapshots.get(t, PackedFloat32Array())
	if last.size() == before.size():
		drift = 0.0
		for n in before.size():
			var dd := absf(before[n] - last[n])
			if dd > drift:
				drift = dd
	_snapshots[t] = before
	# Only part of the tile can move water: cells wet now, cells whose flow (momentum) is
	# still non-zero from the last pass, and one cell round them. Within a pass water can
	# run on to the right and down (cells are visited in that order), so a row carries on
	# past the box while water keeps moving right, and the next row also takes in wherever
	# water was pushed down. Everything else is dry on both sides of every edge and still,
	# so skipping it gives exactly the same result as visiting the whole tile.
	# Our right and lower edges reach into the neighbours: water just across them counts.
	if x1 < SIZE:
		for z in range(z0, z1):
			if depth[z * SIZE + x1] > 0.0:
				wx0 = mini(wx0, x1 - 1)
				wx1 = maxi(wx1, x1 - 1)
				wz0 = mini(wz0, z)
				wz1 = maxi(wz1, z)
	if z1 < SIZE:
		for x in range(x0, x1):
			if depth[z1 * SIZE + x] > 0.0:
				wx0 = mini(wx0, x)
				wx1 = maxi(wx1, x)
				wz0 = mini(wz0, z1 - 1)
				wz1 = maxi(wz1, z1 - 1)
	var box := Rect2i(wx0, wz0, wx1 - wx0 + 1, wz1 - wz0 + 1) if wx1 >= wx0 else Rect2i()
	var prev: Rect2i = _wet_boxes.get(t, Rect2i())
	if prev.has_area():
		box = box.merge(prev) if box.has_area() else prev
	var bx0 := x1
	var bz0 := z1
	var bx1 := x0
	var bz1 := z0
	if box.has_area():
		box = box.grow(1)
		bx0 = maxi(box.position.x, x0)
		bz0 = maxi(box.position.y, z0)
		bx1 = mini(box.end.x, x1)
		bz1 = mini(box.end.y, z1)
	# Flow across every cell's right and lower edge (_exchange, inlined here for speed: a
	# neighbour in a sleeping tile is a wall unless the levels differ enough to wake it).
	var east_awake := tx + 1 < TILES and _awake[t + 1] == 1
	var south_awake := tz + 1 < TILES and _awake[t + TILES] == 1
	var push_lo := x1  # columns of the next row that water was pushed down into
	var push_hi := x0 - 1
	var seen_x0 := x1  # extent of the cells visited (their depths may have changed)
	var seen_x1 := x0
	var seen_z1 := z0
	var fx0 := x1  # extent of the cells left with non-zero flow
	var fx1 := x0 - 1
	var fz0 := z1
	var fz1 := z0 - 1
	for z in range(bz0, z1):
		var lo := bx0 if z < bz1 else x1
		var hi := bx1 if z < bz1 else x0
		if push_lo <= push_hi:
			lo = mini(lo, maxi(push_lo - 1, x0))
			hi = maxi(hi, push_hi + 1)
		if lo >= hi:
			if z >= bz1:
				break
			continue
		push_lo = x1
		push_hi = x0 - 1
		if lo < seen_x0:
			seen_x0 = lo
		seen_z1 = z + 1
		var row := z * SIZE
		var last_row := z + 1 >= z1
		var x := lo
		while x < hi:
			var a := row + x
			if x + 1 < SIZE:
				var b := a + 1
				var da := depth[a]
				var db := depth[b]
				var q := 0.0
				if da > 0.0 or db > 0.0:
					var diff := (_ground[a] + da) - (_ground[b] + db)
					var blocked := false
					if x + 1 >= x1 and not east_awake:
						if absf(diff) < WAKE_LEVEL:
							blocked = true
						else:
							_wake(tx + 1, tz)
							east_awake = true
					if not blocked:
						q = diff * FLOW + flux_x[a] * MOMENTUM
						if q > 0.0:
							q = minf(q, da * MAX_SHARE)
						else:
							q = maxf(q, -db * MAX_SHARE)
						if absf(q) < 0.000001:
							q = 0.0
						else:
							depth[a] = da - q
							depth[b] = db + q
							var aq := absf(q)
							flow[a] += aq
							flow[b] += aq
							if q > 0.0 and x + 1 >= hi and x + 1 < x1:
								hi = x + 2  # water ran on into the next cell: visit it too
				flux_x[a] = q
				if q != 0.0:
					if x < fx0:
						fx0 = x
					if x > fx1:
						fx1 = x
					if z < fz0:
						fz0 = z
					if z > fz1:
						fz1 = z
			if z + 1 < SIZE:
				var b := a + SIZE
				var da := depth[a]
				var db := depth[b]
				var q := 0.0
				if da > 0.0 or db > 0.0:
					var diff := (_ground[a] + da) - (_ground[b] + db)
					var blocked := false
					if last_row and not south_awake:
						if absf(diff) < WAKE_LEVEL:
							blocked = true
						else:
							_wake(tx, tz + 1)
							south_awake = true
					if not blocked:
						q = diff * FLOW + flux_z[a] * MOMENTUM
						if q > 0.0:
							q = minf(q, da * MAX_SHARE)
						else:
							q = maxf(q, -db * MAX_SHARE)
						if absf(q) < 0.000001:
							q = 0.0
						else:
							depth[a] = da - q
							depth[b] = db + q
							var aq := absf(q)
							flow[a] += aq
							flow[b] += aq
							if q > 0.0:
								if x < push_lo:
									push_lo = x
								if x > push_hi:
									push_hi = x
				flux_z[a] = q
				if q != 0.0:
					if x < fx0:
						fx0 = x
					if x > fx1:
						fx1 = x
					if z < fz0:
						fz0 = z
					if z > fz1:
						fz1 = z
			x += 1
		if hi > seen_x1:
			seen_x1 = hi
	if push_lo <= push_hi:
		seen_z1 = mini(seen_z1 + 1, z1)  # water pushed into the last row we didn't visit
	_wet_boxes[t] = Rect2i(fx0, fz0, fx1 - fx0 + 1, fz1 - fz0 + 1) if fx1 >= fx0 else Rect2i()
	# Our left and top edges belong to the neighbours' passes; wake them if needed.
	if tx > 0 and _awake[t - 1] == 0:
		for z in range(z0, z1):
			_check_edge(z * SIZE + x0, z * SIZE + x0 - 1, tx - 1, tz)
	if tz > 0 and _awake[t - TILES] == 0:
		for x in range(x0, x1):
			_check_edge(z0 * SIZE + x, (z0 - 1) * SIZE + x, tx, tz - 1)
	# Map-edge drains and constant heads.
	var change := 0.0
	var cx1 := mini(seen_x1 + 1, x1)
	for z in range(mini(bz0, seen_z1), seen_z1):
		var row := z * SIZE
		k = (z - z0) * (x1 - x0) + seen_x0 - x0
		for x in range(seen_x0, cx1):
			var i := row + x
			if _fixed[i] == 1:
				if _heads.has(i):
					depth[i] = maxf(float(_heads[i]) - _ground[i], 0.0)
				else:
					depth[i] = 0.0
			else:
				var di := depth[i]
				var dc := absf(di - before[k])
				if dc > change:
					change = dc
				if di > 0.03 and _wetted[i] == 0:
					_wetted[i] = 1
					var wp := _cell_to_world(x, z)
					terrain.wet_point(wp.x, wp.y, 0.75)
			k += 1
	_mesh_change[t] += change
	if _mesh_change[t] > MESH_EPS:
		_dirty_meshes[t] = true
	if drift < CALM_EPS:
		_calm[t] += 1
		if _calm[t] > CALM_TICKS:
			_sleep(t)
	else:
		_calm[t] = 0


func _check_edge(i: int, j: int, tx: int, tz: int) -> void:
	if depth[i] <= 0.0 and depth[j] <= 0.0:
		return
	if absf((_ground[i] + depth[i]) - (_ground[j] + depth[j])) >= WAKE_LEVEL:
		_wake(tx, tz)


func _wake(tx: int, tz: int) -> void:
	if tx < 0 or tz < 0 or tx >= TILES or tz >= TILES:
		return
	var t := tz * TILES + tx
	_calm[t] = 0
	if _awake[t] == 0:
		_awake[t] = 1
		_awake_list.append(t)
		_dirty_meshes[t] = true


func _sleep(t: int) -> void:
	_awake[t] = 0
	_snapshots.erase(t)  # (its flow box stays: sleeping cells keep their flow)
	_awake_list.erase(t)
	_dirty_meshes[t] = true


func _tile_of(i: int) -> Vector2i:
	return Vector2i(mini((i % SIZE) / TILE, TILES - 1), mini((i / SIZE) / TILE, TILES - 1))


func _on_terrain_changed(rect: Rect2) -> void:
	var r := _cell_rect(rect.get_center(), rect.size * 0.5 + Vector2(CELL, CELL))
	_refresh_ground(r)
	for tz in range(r.position.y / TILE - 1, r.end.y / TILE + 1):
		for tx in range(r.position.x / TILE - 1, r.end.x / TILE + 1):
			_wake(tx, tz)


func _refresh_ground(r: Rect2i) -> void:
	r = r.intersection(Rect2i(0, 0, SIZE, SIZE))
	if r.size.x <= 0 or r.size.y <= 0:
		return
	terrain._ensure(Rect2i(r.position * STEP, r.size * STEP + Vector2i.ONE).intersection(Rect2i(0, 0, Terrain.VERTS, Terrain.VERTS)))
	var heights := terrain.heights
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_ground[z * SIZE + x] = heights[(z * STEP) * Terrain.VERTS + x * STEP]


## Reads the ground under a tile from the terrain the first time the tile is used.
func _ensure_tile_ground(tx: int, tz: int) -> void:
	if tx < 0 or tz < 0 or tx >= TILES or tz >= TILES or _ground_ready[tz * TILES + tx] == 1:
		return
	_ground_ready[tz * TILES + tx] = 1
	_refresh_ground(Rect2i(tx * TILE, tz * TILE, TILE + 1, TILE + 1))


func _ensure_ground(r: Rect2i) -> void:
	r = r.intersection(Rect2i(0, 0, SIZE, SIZE))
	for tz in range(r.position.y / TILE, mini((r.end.y - 1) / TILE, TILES - 1) + 1):
		for tx in range(r.position.x / TILE, mini((r.end.x - 1) / TILE, TILES - 1) + 1):
			_ensure_tile_ground(tx, tz)


func _build_tile(tx: int, tz: int) -> ArrayMesh:
	var n := TILE + 1
	var indices := PackedInt32Array()
	for lz in TILE:
		for lx in TILE:
			var i := (tz * TILE + lz) * SIZE + tx * TILE + lx
			if depth[i] < WET and depth[i + 1] < WET and depth[i + SIZE] < WET and depth[i + SIZE + 1] < WET:
				continue
			var a := lz * n + lx
			indices.append_array([a, a + 1, a + n + 1, a, a + n + 1, a + n])
	if indices.is_empty():
		return null
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var currents := PackedVector2Array()
	verts.resize(n * n)
	normals.resize(n * n)
	colors.resize(n * n)
	uvs.resize(n * n)
	currents.resize(n * n)
	var k := 0
	var ox := tx * TILE * CELL - Terrain.HALF_SIZE
	var oz := tz * TILE * CELL - Terrain.HALF_SIZE
	var two_cell := 2.0 * CELL
	for lz in n:
		var z := tz * TILE + lz
		var wz := oz + lz * CELL
		for lx in n:
			var x := tx * TILE + lx
			var i := z * SIZE + x
			var d := depth[i]
			# Wet corners sit at the water surface; dry ones tuck under the bank (a shoreline).
			var here := _ground[i] + d if d >= WET else _ground[i] - 0.08
			verts[k] = Vector3(ox + lx * CELL, here, wz)
			# Current through the cell (average flow over its edges) per metre of depth.
			var fx := flux_x[i] + (flux_x[i - 1] if x > 0 else flux_x[i])
			var fz := flux_z[i] + (flux_z[i - SIZE] if z > 0 else flux_z[i])
			currents[k] = (Vector2(fx, fz) * 0.5 / maxf(d, 0.15)).limit_length(0.25)
			# Neighbour surface levels (dry neighbours borrow ours so shores stay flat).
			var left := here
			var right := here
			var back := here
			var front := here
			if x > 0 and depth[i - 1] >= WET:
				left = _ground[i - 1] + depth[i - 1]
			if x < SIZE - 1 and depth[i + 1] >= WET:
				right = _ground[i + 1] + depth[i + 1]
			if z > 0 and depth[i - SIZE] >= WET:
				back = _ground[i - SIZE] + depth[i - SIZE]
			if z < SIZE - 1 and depth[i + SIZE] >= WET:
				front = _ground[i + SIZE] + depth[i + SIZE]
			normals[k] = Vector3(left - right, two_cell, back - front).normalized()
			var shore := 1.0 - smoothstep(0.02, 0.16, d)
			var foam := maxf(shore, clampf(flow[i] * 6.0, 0.0, 1.0))
			colors[k] = SHALLOW.lerp(DEEP, clampf(d / 1.5, 0.0, 1.0)).lerp(FOAM, foam * 0.9)
			uvs[k] = Vector2(d, foam)
			k += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = currents
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	return mesh


func _cell_to_world(x: int, z: int) -> Vector2:
	return Vector2(x * CELL - Terrain.HALF_SIZE, z * CELL - Terrain.HALF_SIZE)


func _world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(
		clampi(roundi((p.x + Terrain.HALF_SIZE) / CELL), 0, SIZE - 1),
		clampi(roundi((p.y + Terrain.HALF_SIZE) / CELL), 0, SIZE - 1))


func _cell_rect(center: Vector2, half_size: Vector2) -> Rect2i:
	var a := _world_to_cell(center - half_size)
	var b := _world_to_cell(center + half_size)
	return Rect2i(a, b - a + Vector2i.ONE)


func _make_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque;

// UV.x = water depth, UV.y = foam, UV2 = current (flow per tick per metre of depth).
varying float foam;
varying vec3 world;
varying vec2 current;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float ripples(vec2 p) {
	return noise(p) * 0.6 + noise(p * 2.7 + 13.0) * 0.4;
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float amp = clamp(UV.x, 0.0, 0.5) * 0.05 + UV.y * 0.02;
	VERTEX.y += (sin(world.x * 1.6 + TIME * 1.4) * cos(world.z * 1.2 + TIME * 1.1)) * amp;
	foam = UV.y;
	current = UV2 * 25.0;
}

void fragment() {
	// Flow map: two ripple layers slide along the current, each fading out as it resets,
	// so the surface visibly runs downstream (and swirls into new channels).
	float phase0 = fract(TIME * 0.35);
	float phase1 = fract(TIME * 0.35 + 0.5);
	float blend = abs(phase0 - 0.5) * 2.0;
	vec2 p = world.xz * 0.6;
	vec2 off0 = current * phase0 * 2.2;
	vec2 off1 = current * phase1 * 2.2 - vec2(0.37, 0.71);
	float e = 0.08;
	float r = mix(ripples(p - off0), ripples(p - off1), blend);
	float rx = mix(ripples(p + vec2(e, 0.0) - off0), ripples(p + vec2(e, 0.0) - off1), blend);
	float rz = mix(ripples(p + vec2(0.0, e) - off0), ripples(p + vec2(0.0, e) - off1), blend);
	float speed = clamp(length(current), 0.0, 1.5);
	vec3 bump = vec3(r - rx, 0.0, r - rz) * (0.6 + speed * 1.2);
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(bump, 0.0)).xyz);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 col = pow(COLOR.rgb, vec3(2.2));
	// White water where it runs fast.
	float white = smoothstep(0.62, 0.85, r) * clamp(speed * 0.7, 0.0, 0.45) * (1.0 - foam);
	col = mix(col, vec3(0.9, 0.96, 0.97), white);
	ALBEDO = mix(col, vec3(0.75, 0.9, 0.95), fresnel * 0.35 * (1.0 - foam));
	ALPHA = COLOR.a;
	ROUGHNESS = mix(0.06, 0.6, max(foam, white));
	SPECULAR = 0.6;
}
"""
	return shader
