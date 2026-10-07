extends Node3D
## Shallow water on a 0.5 m grid laid over the terrain. Water flows from higher to
## lower surface levels, so it runs into anything you dig, backs up behind anything
## you dump, and pours off the edge of the map. Rivers are fed by constant-level
## heads at their source. The grid is split into tiles that fall asleep once the
## water in them settles and wake when the terrain or a neighbour changes, so large
## rivers and lakes cost nothing until you disturb them. Ground that floods turns to mud.

const Terrain = preload("res://scripts/terrain.gd")

const STEP := 2  # terrain vertices per water cell
const SIZE := 577  # Terrain.CELLS / STEP + 1
const CELL := Terrain.CELL_SIZE * STEP
const CELL_AREA := CELL * CELL
const TILE := 16
const TILES := 36  # (SIZE - 1) / TILE
const FLOW := 0.24  # share of the level difference exchanged per tick (< 0.25 stays stable)
const MAX_SHARE := 0.24  # a cell gives at most this share of its depth to one neighbour
const WET := 0.008
const SIM_INTERVAL := 1.0 / 20.0
const TILES_PER_TICK := 18  # work budget; with more awake tiles they take turns
const WAKE_LEVEL := 0.03  # level difference across a sleeping tile's edge that wakes it
const CALM_EPS := 0.002  # depth change per tick below which a tile counts as settled
const CALM_TICKS := 10
const MESH_INTERVAL := 1.0 / 12.0
const MESH_EPS := 0.004
const MESHES_PER_UPDATE := 10

const DEEP := Color(0.2, 0.5, 0.55, 0.93)
const SHALLOW := Color(0.5, 0.82, 0.77, 0.82)
const FOAM := Color(0.95, 0.98, 0.97, 0.95)

var terrain: Terrain
var depth := PackedFloat32Array()
var flow := PackedFloat32Array()

var _ground := PackedFloat32Array()
var _fixed := PackedByteArray()  # 1 = constant-level head or map-edge drain
var _wetted := PackedByteArray()  # 1 = already turned the ground to mud
var _heads := {}  # cell index -> surface level
var _sources: Array[Vector3] = []  # x, z = cell, y = m3 per second
var _awake := PackedByteArray()
var _calm := PackedInt32Array()
var _mesh_change := PackedFloat32Array()  # depth change since the tile's mesh was built
var _snapshots := {}  # tile -> depths at the start of its previous pass
var _awake_list: Array[int] = []
var _cursor := 0
var _dirty_meshes := {}
var _sim_timer := 0.0
var _mesh_timer := 0.0
var _tile_meshes: Array[MeshInstance3D] = []
var _material := ShaderMaterial.new()


func setup(terrain_node: Terrain) -> void:
	terrain = terrain_node
	var count := SIZE * SIZE
	depth.resize(count)
	depth.fill(0.0)
	flow.resize(count)
	flow.fill(0.0)
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
	_refresh_ground(Rect2i(0, 0, SIZE, SIZE))
	_awake.resize(TILES * TILES)
	_awake.fill(0)
	_calm.resize(TILES * TILES)
	_mesh_change.resize(TILES * TILES)
	_material.shader = _make_shader()
	for i in TILES * TILES:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mesh_instance)
		_tile_meshes.append(mesh_instance)
	terrain.area_changed.connect(_on_terrain_changed)


## Fills a channel along `path` up to `water_depth` above its bed.
func fill_channel(path: PackedVector2Array, beds: PackedFloat32Array, half_width: float, water_depth: float) -> void:
	for s in path.size() - 1:
		var a := path[s]
		var b := path[s + 1]
		var seg := b - a
		var len_sq := maxf(seg.length_squared(), 0.0001)
		var r := _cell_rect((a + b) * 0.5, Vector2(absf(seg.x), absf(seg.y)) * 0.5 + Vector2.ONE * half_width)
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
	_sim_timer += delta
	if _sim_timer >= SIM_INTERVAL:
		_sim_timer = fmod(_sim_timer, SIM_INTERVAL)
		_tick()


func _process(delta: float) -> void:
	_mesh_timer -= delta
	if _mesh_timer <= 0.0:
		_mesh_timer = MESH_INTERVAL
		var built := 0
		for key in _dirty_meshes.keys():
			if built >= MESHES_PER_UPDATE:
				break
			var t: int = key
			_tile_meshes[t].mesh = _build_tile(t % TILES, t / TILES)
			_mesh_change[t] = 0.0
			_dirty_meshes.erase(key)
			built += 1


func _tick() -> void:
	for s in _sources:
		var i := int(s.z) * SIZE + int(s.x)
		depth[i] += s.y * SIM_INTERVAL / CELL_AREA
	for i in _heads:
		depth[i] = maxf(float(_heads[i]) - _ground[i], 0.0)
	var count := mini(_awake_list.size(), TILES_PER_TICK)
	var tiles: Array[int] = []
	for k in count:
		tiles.append(_awake_list[(_cursor + k) % _awake_list.size()])
	_cursor = (_cursor + count) % maxi(_awake_list.size(), 1)
	for t in tiles:
		_simulate_tile(t)


func _simulate_tile(t: int) -> void:
	var tx := t % TILES
	var tz := t / TILES
	var x0 := tx * TILE
	var z0 := tz * TILE
	var x1 := mini(x0 + TILE + (1 if tx == TILES - 1 else 0), SIZE)
	var z1 := mini(z0 + TILE + (1 if tz == TILES - 1 else 0), SIZE)
	var before := PackedFloat32Array()
	before.resize((x1 - x0) * (z1 - z0))
	var k := 0
	for z in range(z0, z1):
		for x in range(x0, x1):
			var i := z * SIZE + x
			before[k] = depth[i]
			flow[i] *= 0.85
			k += 1
	# Settled = the tile looks the same as on its last pass (a steady river still flows).
	var drift := INF
	var last: PackedFloat32Array = _snapshots.get(t, PackedFloat32Array())
	if last.size() == before.size():
		drift = 0.0
		for n in before.size():
			drift = maxf(drift, absf(before[n] - last[n]))
	_snapshots[t] = before
	for z in range(z0, z1):
		for x in range(x0, x1):
			var i := z * SIZE + x
			if x + 1 < SIZE:
				_exchange(i, i + 1, x + 1 >= x1)
			if z + 1 < SIZE:
				_exchange(i, i + SIZE, z + 1 >= z1)
	# Our left and top edges belong to the neighbours' passes; wake them if needed.
	if tx > 0 and _awake[t - 1] == 0:
		for z in range(z0, z1):
			_check_edge(z * SIZE + x0, z * SIZE + x0 - 1, tx - 1, tz)
	if tz > 0 and _awake[t - TILES] == 0:
		for x in range(x0, x1):
			_check_edge(z0 * SIZE + x, (z0 - 1) * SIZE + x, tx, tz - 1)
	# Map-edge drains and constant heads.
	var change := 0.0
	k = 0
	for z in range(z0, z1):
		for x in range(x0, x1):
			var i := z * SIZE + x
			if _fixed[i] == 1:
				if _heads.has(i):
					depth[i] = maxf(float(_heads[i]) - _ground[i], 0.0)
				else:
					depth[i] = 0.0
			else:
				change = maxf(change, absf(depth[i] - before[k]))
				if depth[i] > 0.03 and _wetted[i] == 0:
					_wetted[i] = 1
					var w := _cell_to_world(x, z)
					terrain.wet_point(w.x, w.y, 0.75)
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


## `crosses` = the neighbour lies in another tile. A sleeping neighbour acts as a wall
## (so a settled river stays asleep) unless the levels differ enough to wake it.
func _exchange(a: int, b: int, crosses: bool) -> void:
	var da := depth[a]
	var db := depth[b]
	if da <= 0.0 and db <= 0.0:
		return
	var diff := (_ground[a] + da) - (_ground[b] + db)
	if crosses:
		var tb := _tile_of(b)
		if _awake[tb.y * TILES + tb.x] == 0:
			if absf(diff) < WAKE_LEVEL:
				return
			_wake(tb.x, tb.y)
	var q := diff * FLOW
	if q > 0.0:
		q = minf(q, da * MAX_SHARE)
	else:
		q = maxf(q, -db * MAX_SHARE)
	if absf(q) < 0.000001:
		return
	depth[a] = da - q
	depth[b] = db + q
	flow[a] += absf(q)
	flow[b] += absf(q)


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
	_snapshots.erase(t)
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
	var heights := terrain.heights
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_ground[z * SIZE + x] = heights[(z * STEP) * Terrain.VERTS + x * STEP]


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
	verts.resize(n * n)
	normals.resize(n * n)
	colors.resize(n * n)
	uvs.resize(n * n)
	var k := 0
	for lz in n:
		for lx in n:
			var x := tx * TILE + lx
			var z := tz * TILE + lz
			var i := z * SIZE + x
			verts[k] = _corner(x, z, i)
			var here := verts[k].y
			var left := _level(i - 1, here) if x > 0 else here
			var right := _level(i + 1, here) if x < SIZE - 1 else here
			var back := _level(i - SIZE, here) if z > 0 else here
			var front := _level(i + SIZE, here) if z < SIZE - 1 else here
			normals[k] = Vector3(left - right, 2.0 * CELL, back - front).normalized()
			var d := depth[i]
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
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	return mesh


## Water surface height of a wet cell; dry cells borrow `fallback` so shores stay flat.
func _level(i: int, fallback: float) -> float:
	return _ground[i] + depth[i] if depth[i] >= WET else fallback


## Wet corners sit at the water surface; dry ones tuck under the bank to make a shoreline.
func _corner(x: int, z: int, i: int) -> Vector3:
	var w := _cell_to_world(x, z)
	var h := _ground[i] + depth[i] if depth[i] >= WET else _ground[i] - 0.08
	return Vector3(w.x, h, w.y)


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

// UV.x = water depth, UV.y = foam
varying float foam;

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float amp = clamp(UV.x, 0.0, 0.5) * 0.05 + UV.y * 0.02;
	VERTEX.y += (sin(w.x * 1.6 + TIME * 1.4) * cos(w.z * 1.2 + TIME * 1.1)) * amp;
	foam = UV.y;
}

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 col = pow(COLOR.rgb, vec3(2.2));
	// Drifting streaks so even settled water looks like it's moving.
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float streak = sin(world.x * 2.3 + world.z * 0.7 + TIME * 1.5) * sin(world.z * 1.9 - TIME * 1.1);
	col = mix(col, vec3(0.85, 0.95, 0.95), smoothstep(0.75, 1.0, streak) * 0.18 * (1.0 - foam));
	ALBEDO = mix(col, vec3(0.75, 0.9, 0.95), fresnel * 0.35 * (1.0 - foam));
	ALPHA = COLOR.a;
	ROUGHNESS = mix(0.08, 0.6, foam);
	SPECULAR = 0.6;
}
"""
	return shader
