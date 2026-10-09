extends Node3D
## Deformable heightmap terrain for a 1 km square world at 25 cm resolution.
##
## The world is far too big to build up front, so everything is lazy:
## - The ground is generated in 8 m blocks the first time anything needs them (driving
##   near, digging, a query): a smooth base (sampled from a 1 m noise grid) plus the
##   world's features — mounds, basins, flattened pads, river channels, mud, gravel,
##   protected ground — which main.gd records while laying out the world and which are
##   replayed onto each block as it's generated.
## - Within NEAR_RADIUS of the camera the ground is drawn in 16 m chunks at full detail
##   (with distance LODs and skirts); beyond that, 128 m horizon tiles at 2 m spacing
##   cover the rest of the map, with holes where the detailed chunks are.
## - Collision tiles exist only around the things that need them (players, machines,
##   loose logs and rubble): main.gd passes those "anchors" in.
## Digging, dumping, ruts, slumping, mud and the network sync work on the full-resolution
## arrays as before.

signal area_changed(world_rect: Rect2)
signal chunk_rebuilt(cx: int, cz: int)

const CELLS := 4096
const CELL_SIZE := 0.25
const VERTS := CELLS + 1
const HALF_SIZE := CELLS * CELL_SIZE * 0.5  # 512 m
const CELL_AREA := CELL_SIZE * CELL_SIZE
const GEN_CELLS := 32  # generated in 8 m blocks
const GEN_CHUNKS := 128  # CELLS / GEN_CELLS
const CHUNK_CELLS := 64  # drawn in 16 m chunks
const CHUNKS := 64  # CELLS / CHUNK_CELLS
const COLLISION_CELLS := 64
const COLLISION_TILES := 64  # CELLS / COLLISION_CELLS
const BASE_STEP := 4  # the smooth base is sampled every metre
const BASE_VERTS := 1025  # CELLS / BASE_STEP + 1
const NEAR_RADIUS := 150.0  # detailed chunks within this of the camera
const STREAM_BUDGET_USEC := 5000  # time per frame for streaming ground in
const SLUMP_BUDGET_USEC := 2000  # per settling pass (two a frame)
const FAR_TILE_CELLS := 512  # 128 m horizon tiles
const FAR_TILES := 8
const FAR_STEP := 8  # 2 m between horizon vertices
const FAR_N := 65  # FAR_TILE_CELLS / FAR_STEP + 1
const MIN_HEIGHT := -14.0
const TALUS := CELL_SIZE * 0.72  # max height step between neighbours (~36 degree slopes)
const COLLISION_INTERVAL := 0.1
const LOD_STEPS: Array[int] = [2, 4, 8, 16]  # coarser index sets for distant chunks
const LOD_ERROR := 0.012  # LOD key (m of error) per vertex step
const SKIRT := 1.5  # chunk edges hang a skirt this deep so LOD seams never show gaps

const GROUND := Color(0.66, 0.52, 0.27)  # under the grass
const GRAVEL := Color(0.6, 0.57, 0.5)
const MUD := Color(0.27, 0.18, 0.11)
const LOOSE := Color(0.56, 0.33, 0.2)  # dumped piles
const TOPSOIL := Color(0.5, 0.29, 0.18)
const SUBSOIL := Color(0.6, 0.34, 0.2)
const CLAY := Color(0.7, 0.44, 0.26)
const ROCK := Color(0.5, 0.47, 0.44)

const SURFACE_SOIL := 0
const SURFACE_GRAVEL := 1

# World features (recorded while laying out the world, replayed onto each block).
const OP_MOUND := 0
const OP_FLATTEN := 1
const OP_CHANNEL := 2
const OP_RING := 3
const OP_MUD := 4
const OP_GRAVEL := 5
const OP_PROTECT := 6
const OP_DISTURB := 7
const OP_NOGRASS := 8

const SHADER := """
shader_type spatial;
render_mode cull_disabled;

// COLOR.a = 1 on exposed soil (darkens on steep cuts), UV.x = wetness (mud shine).
varying vec3 world_pos;
varying float wet;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wet = UV.x;
}

void fragment() {
	vec3 col = pow(COLOR.rgb, vec3(2.2));
	float n = value_noise(world_pos.xz * 1.3) * 0.55 + value_noise(world_pos.xz * 5.0) * 0.3 + value_noise(world_pos.xz * 17.0) * 0.15;
	col *= 0.86 + 0.28 * n;
	vec3 world_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float steep = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	col *= mix(1.0, 0.7, smoothstep(0.2, 0.75, steep) * COLOR.a);
	// Puddly mud: glossy, with darker wet patches.
	float puddle = smoothstep(0.55, 0.75, value_noise(world_pos.xz * 0.9)) * wet;
	col *= 1.0 - puddle * 0.35;
	ALBEDO = col;
	ROUGHNESS = mix(1.0, 0.2, wet * (0.5 + 0.5 * puddle));
	SPECULAR = mix(0.3, 0.7, wet);
}
"""

var heights := PackedFloat32Array()
var original := PackedFloat32Array()
var disturbed := PackedByteArray()
var grass_mask := PackedByteArray()  # 0 where grass never grows (water beds, yards)
var mud := PackedFloat32Array()  # 0 dry .. 1 deep mud
var surface := PackedByteArray()  # SURFACE_SOIL / SURFACE_GRAVEL
var pressed := PackedByteArray()  # 1 = already rutted by tracks or wheels
var protected := PackedByteArray()  # 1 = can't be dug below its original level (the depot)
## Detailed chunks load around this node (the camera).
var focus: Node3D
## The volume the last cut_flat() wanted to remove (for the dozer's hold-back).
var last_cut_wanted := 0.0
## Multiplayer (host): chunks changed since the last sync, and every chunk that differs
## from the generated world (sent to players who join later).
var net_record := false
## Chunks changed since the world was built (what the world save keeps), once recording.
var edited := {}
var record_edits := false
## The world save's copy of each edited chunk, compressed, and which changed since it was
## made (so an autosave only repacks what's new).
var save_cache := {}
var save_stale := {}
var net_dirty := {}
var net_changed := {}

var _base := PackedFloat32Array()  # smooth ground every BASE_STEP cells
var _generated := PackedByteArray()  # per 8 m block
var _ops: Array = []  # recorded world features
var _op_grid: Array = []  # per 64 m cell: indices of the features touching it
const OP_CELL := 64.0
const OP_GRID := 16
var _building := true  # until finalize(): features also shape the "original" ground
var _material := ShaderMaterial.new()
var _chunk_indices := PackedInt32Array()
var _chunk_lods := {}  # LOD key -> index array (same vertices, fewer of them)
var _near := {}  # chunk index -> MeshInstance3D
var _near_queue: Array = []
var _last_focus := Vector3.INF
var _dirty_chunks := {}
var _far_meshes: Array[MeshInstance3D] = []
var _far_vertices := {}  # tile -> [verts, normals, colors, uvs] (cached; holes only change indices)
var _far_dirty := {}  # tile -> true (holes changed)
var _far_stale := {}  # tile -> true (ground under it changed; refresh vertices too)
var _collision_body: StaticBody3D
var _collision := {}  # tile index -> [CollisionShape3D, HeightMapShape3D, last wanted msec]
var _dirty_collision := {}
var _pending_collision := {}  # tile -> distance² to the anchor that wants it
var _collision_timer := 0.0
## Areas changed since the last collision update, announced to the water, minimap and
## loose bodies; kept apart per site (one box round far-apart changes would make them all
## redo most of the map).
var _wake_rects: Array[Rect2i] = []
## Chunks from the network or a save for ground not generated yet: put in when it is.
var _pending_chunks := {}
## Areas where loose soil is still settling: one per dig site (a single box round
## edits far apart would cover most of the map and grind every frame to a halt).
var _slump_rects: Array[Rect2i] = []
var _slumping := false
var _full_rect := Rect2i(0, 0, VERTS, VERTS)


# --- World generation ---------------------------------------------------------------------

## Sets up the arrays and the smooth base ground (hills, valleys, small rolls).
func generate(seed_value: int) -> void:
	var count := VERTS * VERTS
	heights.resize(count)
	original.resize(count)
	disturbed.resize(count)
	disturbed.fill(0)
	grass_mask.resize(count)
	grass_mask.fill(1)
	mud.resize(count)
	mud.fill(0.0)
	surface.resize(count)
	surface.fill(SURFACE_SOIL)
	pressed.resize(count)
	pressed.fill(0)
	protected.resize(count)
	protected.fill(0)
	_generated.resize(GEN_CHUNKS * GEN_CHUNKS)
	_generated.fill(0)
	_op_grid.resize(OP_GRID * OP_GRID)
	for k in _op_grid.size():
		_op_grid[k] = PackedInt32Array()
	var macro := FastNoiseLite.new()
	macro.seed = seed_value + 7
	macro.frequency = 0.0022
	macro.fractal_octaves = 3
	var hills := FastNoiseLite.new()
	hills.seed = seed_value
	hills.frequency = 0.008
	hills.fractal_octaves = 3
	var detail := FastNoiseLite.new()
	detail.seed = seed_value + 1
	detail.frequency = 0.05
	_base.resize(BASE_VERTS * BASE_VERTS)
	for z in BASE_VERTS:
		for x in BASE_VERTS:
			var w := Vector2(x * BASE_STEP * CELL_SIZE - HALF_SIZE, z * BASE_STEP * CELL_SIZE - HALF_SIZE)
			# Fade to flat at the border so the map meets the surrounding meadow.
			var edge := 1.0 - smoothstep(HALF_SIZE - 24.0, HALF_SIZE - 1.0, maxf(absf(w.x), absf(w.y)))
			var h := macro.get_noise_2dv(w) * 9.0 + hills.get_noise_2dv(w) * 4.0 + detail.get_noise_2dv(w) * 0.45
			_base[z * BASE_VERTS + x] = h * edge


## Smooth base height at a vertex (bilinear from the 1 m grid).
func _base_at(x: int, z: int) -> float:
	var bx := mini(x / BASE_STEP, BASE_VERTS - 2)
	var bz := mini(z / BASE_STEP, BASE_VERTS - 2)
	var fx := float(x - bx * BASE_STEP) / BASE_STEP
	var fz := float(z - bz * BASE_STEP) / BASE_STEP
	var i := bz * BASE_VERTS + bx
	var top := lerpf(_base[i], _base[i + 1], fx)
	var bottom := lerpf(_base[i + BASE_VERTS], _base[i + BASE_VERTS + 1], fx)
	return lerpf(top, bottom, fz)


func add_mound(center: Vector2, radius: float, height: float) -> void:
	_record({"t": OP_MOUND, "c": center, "r": radius, "h": height,
		"rect": Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)})


## Levels a rectangular pad and returns its height (`level` overrides the average).
func flatten(center: Vector2, half_size: Vector2, blend: float, level := NAN) -> float:
	if is_nan(level):
		var inner := _world_rect(center, half_size)
		_ensure(inner)
		var total := 0.0
		var n := 0
		for z in range(inner.position.y, inner.end.y, 2):
			for x in range(inner.position.x, inner.end.x, 2):
				total += heights[z * VERTS + x]
				n += 1
		level = total / maxi(n, 1)
	_record({"t": OP_FLATTEN, "c": center, "half": half_size, "blend": blend, "level": level,
		"rect": Rect2(center - half_size - Vector2(blend, blend), (half_size + Vector2(blend, blend)) * 2.0)})
	return level


## Cuts a channel along `path` (world XZ points). `beds` gives the wanted bed height at
## each point; where the ground is lower the bed drops so the channel always has banks.
## Banks rise at `bank_slope` until they meet the existing ground. Returns the beds used.
func carve_channel(path: PackedVector2Array, wanted: PackedFloat32Array, half_width: float, bank_depth: float, bank_slope: float) -> PackedFloat32Array:
	var beds := PackedFloat32Array()
	for k in path.size():
		beds.append(minf(wanted[k], get_height(path[k].x, path[k].y) - bank_depth * 0.9))
	var reach := half_width + 12.0
	# One feature per segment keeps the per-block replay cheap.
	for s in path.size() - 1:
		var a := path[s]
		var b := path[s + 1]
		var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(reach, reach)
		var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(reach, reach)
		var before := path[s - 1] if s > 0 else a
		var after := path[s + 2] if s + 2 < path.size() else b
		_record({"t": OP_CHANNEL, "a": a, "b": b, "bed_a": beds[s], "bed_b": beds[s + 1], "hw": half_width,
			"depth": bank_depth, "slope": bank_slope, "reach": reach, "prev": before, "next": after,
			"rect": Rect2(lo, hi - lo)})
	return beds


## Raises low ground in a ring around `center` to at least `height` (a lake's rim).
func raise_ring(center: Vector2, inner: float, outer: float, height: float) -> void:
	_record({"t": OP_RING, "c": center, "inner": inner, "outer": outer, "h": height,
		"rect": Rect2(center - Vector2(outer, outer), Vector2(outer, outer) * 2.0)})


## Makes ground muddy (0..1) in a soft circle.
func add_mud(center: Vector2, radius: float, amount: float) -> void:
	_record({"t": OP_MUD, "c": center, "r": radius, "amount": amount,
		"rect": Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)})


func paint_gravel(center: Vector2, half_size: Vector2) -> void:
	_record({"t": OP_GRAVEL, "c": center, "half": half_size, "rect": Rect2(center - half_size, half_size * 2.0)})


## Makes ground undiggable (it can still take spoil, which can be cleared off again).
func protect(center: Vector2, half_size: Vector2) -> void:
	_record({"t": OP_PROTECT, "c": center, "half": half_size, "rect": Rect2(center - half_size, half_size * 2.0)})


## Marks ground as worked soil (e.g. stockpiles) so it shows soil colour instead of grass.
func mark_disturbed(center: Vector2, radius: float) -> void:
	_record({"t": OP_DISTURB, "c": center, "r": radius, "rect": Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)})


## Stops grass growing within `radius` of `center`.
func clear_grass(center: Vector2, radius: float) -> void:
	_record({"t": OP_NOGRASS, "c": center, "r": radius, "rect": Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)})


## Adds a feature: blocks already generated get it now, the rest when they're generated.
func _record(op: Dictionary) -> void:
	_ops.append(op)
	var rect: Rect2 = op.rect
	var gx0 := clampi(floori((rect.position.x + HALF_SIZE) / OP_CELL), 0, OP_GRID - 1)
	var gx1 := clampi(floori((rect.end.x + HALF_SIZE) / OP_CELL), 0, OP_GRID - 1)
	var gz0 := clampi(floori((rect.position.y + HALF_SIZE) / OP_CELL), 0, OP_GRID - 1)
	var gz1 := clampi(floori((rect.end.y + HALF_SIZE) / OP_CELL), 0, OP_GRID - 1)
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			_op_grid[gz * OP_GRID + gx].append(_ops.size() - 1)
	var r := _rect_of(op.rect)
	var c0 := Vector2i(clampi(r.position.x / GEN_CELLS, 0, GEN_CHUNKS - 1), clampi(r.position.y / GEN_CELLS, 0, GEN_CHUNKS - 1))
	var c1 := Vector2i(clampi((r.end.x - 1) / GEN_CELLS, 0, GEN_CHUNKS - 1), clampi((r.end.y - 1) / GEN_CELLS, 0, GEN_CHUNKS - 1))
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if _generated[cz * GEN_CHUNKS + cx] == 1:
				_apply_op(op, _gen_rect(cx, cz).intersection(r))


func _rect_of(world: Rect2) -> Rect2i:
	return _world_rect(world.get_center(), world.size * 0.5)


## Vertex range of an 8 m block (the last row/column also owns the map's far edge).
func _gen_rect(cx: int, cz: int) -> Rect2i:
	var x0 := cx * GEN_CELLS
	var z0 := cz * GEN_CELLS
	var x1 := VERTS if cx == GEN_CHUNKS - 1 else x0 + GEN_CELLS
	var z1 := VERTS if cz == GEN_CHUNKS - 1 else z0 + GEN_CELLS
	return Rect2i(x0, z0, x1 - x0, z1 - z0)


## Generates every block a vertex rectangle touches.
func _ensure(r: Rect2i) -> void:
	var cx0 := clampi(r.position.x / GEN_CELLS, 0, GEN_CHUNKS - 1)
	var cz0 := clampi(r.position.y / GEN_CELLS, 0, GEN_CHUNKS - 1)
	var cx1 := clampi((r.end.x - 1) / GEN_CELLS, 0, GEN_CHUNKS - 1)
	var cz1 := clampi((r.end.y - 1) / GEN_CELLS, 0, GEN_CHUNKS - 1)
	var made := false
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			if _generated[cz * GEN_CHUNKS + cx] == 0:
				_generate_block(cx, cz)
				made = true
	if made and not _pending_chunks.is_empty():
		_apply_pending(r)


## Puts in waiting chunks around newly generated ground (generating the rest of each
## chunk's ground first: at most a few small blocks).
func _apply_pending(r: Rect2i) -> void:
	var size := CHUNK_CELLS
	var cx0 := clampi((r.position.x - 1) / size, 0, CHUNKS - 1)
	var cz0 := clampi((r.position.y - 1) / size, 0, CHUNKS - 1)
	var cx1 := clampi(r.end.x / size, 0, CHUNKS - 1)
	var cz1 := clampi(r.end.y / size, 0, CHUNKS - 1)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var index := cz * CHUNKS + cx
			if _pending_chunks.has(index):
				var data: Array = _pending_chunks[index]
				_pending_chunks.erase(index)
				_ensure(Rect2i(cx * size, cz * size, size + 1, size + 1).intersection(_full_rect))
				net_apply_chunk(data)


## Whether all the ground under a render chunk (including its far edge) exists yet.
func _chunk_generated(cx: int, cz: int) -> bool:
	var per := CHUNK_CELLS / GEN_CELLS
	for bz in range(cz * per, mini((cz + 1) * per, GEN_CHUNKS - 1) + 1):
		for bx in range(cx * per, mini((cx + 1) * per, GEN_CHUNKS - 1) + 1):
			if _generated[bz * GEN_CHUNKS + bx] == 0:
				return false
	return true


func _ensure_vertex(x: int, z: int) -> void:
	var c := mini(z / GEN_CELLS, GEN_CHUNKS - 1) * GEN_CHUNKS + mini(x / GEN_CELLS, GEN_CHUNKS - 1)
	if _generated[c] == 0:
		_generate_block(c % GEN_CHUNKS, c / GEN_CHUNKS)
		if not _pending_chunks.is_empty():
			_apply_pending(Rect2i(x, z, 1, 1))


func _generate_block(cx: int, cz: int) -> void:
	_generated[cz * GEN_CHUNKS + cx] = 1
	var r := _gen_rect(cx, cz)
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			heights[z * VERTS + x] = _base_at(x, z)
	var area := Rect2(grid_to_world(r.position.x, r.position.y), Vector2(r.size) * CELL_SIZE)
	for k in _ops_near(area.get_center()):
		var op: Dictionary = _ops[k]
		if area.intersects(op.rect):
			_apply_op(op, r.intersection(_rect_of(op.rect)), false)
	for z in range(r.position.y, r.end.y):
		var row := z * VERTS
		for x in range(r.position.x, r.end.x):
			original[row + x] = heights[row + x]


## Applies one feature to the vertices in `r` (tight per-type loops: this runs for
## every 8 m block that's generated). While the world is being laid out a feature added
## to an existing block also reshapes its "original" ground.
func _apply_op(op: Dictionary, r: Rect2i, update_original := true) -> void:
	if r.size.x <= 0 or r.size.y <= 0:
		return
	var keep := update_original and _building
	var x0 := r.position.x
	var x1 := r.end.x
	var t: int = op.t
	if t == OP_MOUND or t == OP_RING or t == OP_MUD or t == OP_DISTURB or t == OP_NOGRASS:
		var cx: float = op.c.x
		var cz: float = op.c.y
		var rad: float = op.get("r", op.get("outer", 0.0))
		var rad_sq := rad * rad
		for z in range(r.position.y, r.end.y):
			var dz := z * CELL_SIZE - HALF_SIZE - cz
			if absf(dz) > rad:
				continue
			var row := z * VERTS
			for x in range(x0, x1):
				var dx := x * CELL_SIZE - HALF_SIZE - cx
				var d_sq := dx * dx + dz * dz
				if d_sq > rad_sq:
					continue
				var i := row + x
				var d := sqrt(d_sq)
				match t:
					OP_MOUND:
						heights[i] += float(op.h) * 0.5 * (1.0 + cos(PI * d / rad))
					OP_RING:
						if d >= float(op.inner):
							var inner: float = op.inner
							var k := 1.0 - smoothstep(inner + (rad - inner) * 0.4, rad, d)
							heights[i] = maxf(heights[i], lerpf(heights[i], op.h, k))
					OP_MUD:
						if surface[i] != SURFACE_GRAVEL:
							mud[i] = maxf(mud[i], float(op.amount) * smoothstep(rad, rad * 0.4, d))
					OP_DISTURB:
						disturbed[i] = 1
					OP_NOGRASS:
						grass_mask[i] = 0
				if keep:
					original[i] = heights[i]
	elif t == OP_FLATTEN:
		var cx: float = op.c.x
		var cz: float = op.c.y
		var hx: float = op.half.x
		var hz: float = op.half.y
		var blend: float = op.blend
		var level: float = op.level
		for z in range(r.position.y, r.end.y):
			var dz := maxf(absf(z * CELL_SIZE - HALF_SIZE - cz) - hz, 0.0)
			var row := z * VERTS
			for x in range(x0, x1):
				var dx := maxf(absf(x * CELL_SIZE - HALF_SIZE - cx) - hx, 0.0)
				var i := row + x
				heights[i] = lerpf(heights[i], level, 1.0 - smoothstep(0.0, blend, sqrt(dx * dx + dz * dz)))
				if keep:
					original[i] = heights[i]
	elif t == OP_GRAVEL or t == OP_PROTECT:
		var cx: float = op.c.x
		var cz: float = op.c.y
		var hx: float = op.half.x
		var hz: float = op.half.y
		for z in range(r.position.y, r.end.y):
			if absf(z * CELL_SIZE - HALF_SIZE - cz) > hz:
				continue
			var row := z * VERTS
			for x in range(x0, x1):
				if absf(x * CELL_SIZE - HALF_SIZE - cx) > hx:
					continue
				var i := row + x
				if t == OP_GRAVEL:
					surface[i] = SURFACE_GRAVEL
					grass_mask[i] = 0
					mud[i] = 0.0
				else:
					protected[i] = 1
	elif t == OP_CHANNEL:
		var ax: float = op.a.x
		var az: float = op.a.y
		var sx: float = op.b.x - ax
		var sz: float = op.b.y - az
		var len_sq := maxf(sx * sx + sz * sz, 0.0001)
		var bed_a: float = op.bed_a
		var bed_b: float = op.bed_b
		var hw: float = op.hw
		var depth: float = op.depth
		var slope: float = op.slope
		var reach: float = op.reach
		for z in range(r.position.y, r.end.y):
			var wz := z * CELL_SIZE - HALF_SIZE
			var row := z * VERTS
			for x in range(x0, x1):
				var wx := x * CELL_SIZE - HALF_SIZE
				var u := clampf(((wx - ax) * sx + (wz - az) * sz) / len_sq, 0.0, 1.0)
				var px := wx - (ax + sx * u)
				var pz := wz - (az + sz * u)
				var d := sqrt(px * px + pz * pz)
				if d > reach:
					continue
				var bed := lerpf(bed_a, bed_b, u)
				var target := bed + depth * (d / hw) * (d / hw) if d < hw else bed + depth + (d - hw) * slope
				var i := row + x
				if target < heights[i]:
					heights[i] = target
					if d < hw + 1.0:
						grass_mask[i] = 0
					if keep:
						original[i] = heights[i]


## Features touching the 64 m cell around `w` (in the order they were added).
func _ops_near(w: Vector2) -> PackedInt32Array:
	var gx := clampi(floori((w.x + HALF_SIZE) / OP_CELL), 0, OP_GRID - 1)
	var gz := clampi(floori((w.y + HALF_SIZE) / OP_CELL), 0, OP_GRID - 1)
	return _op_grid[gz * OP_GRID + gx]


## Distance along / from a channel segment, treating the joints smoothly.
func _channel_distance(op: Dictionary, w: Vector2) -> float:
	var seg: Vector2 = op.b - op.a
	var t := clampf((w - op.a).dot(seg) / maxf(seg.length_squared(), 0.0001), 0.0, 1.0)
	return w.distance_to(op.a + seg * t)


func _channel_target(op: Dictionary, w: Vector2) -> float:
	var seg: Vector2 = op.b - op.a
	var t := clampf((w - op.a).dot(seg) / maxf(seg.length_squared(), 0.0001), 0.0, 1.0)
	var d := w.distance_to(op.a + seg * t)
	if d > op.reach:
		return INF
	var bed := lerpf(op.bed_a, op.bed_b, t)
	if d < op.hw:
		return bed + op.depth * pow(d / op.hw, 2.0)
	return bed + op.depth + (d - op.hw) * op.slope


## Ground height without generating anything (for the horizon, maps and planning):
## the real height where the ground exists, otherwise the base plus the features.
func sample_height(wx: float, wz: float) -> float:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	if _generated[mini(z / GEN_CELLS, GEN_CHUNKS - 1) * GEN_CHUNKS + mini(x / GEN_CELLS, GEN_CHUNKS - 1)] == 1:
		return heights[z * VERTS + x]
	return _sample(x, z).x


## (height, mud, gravel 0/1, protected 0/1) of an ungenerated vertex, from the features.
func _sample(x: int, z: int) -> Vector4:
	var h := _base_at(x, z)
	var m := 0.0
	var g := 0.0
	var p := 0.0
	var w := grid_to_world(x, z)
	for k in _ops_near(w):
		var op: Dictionary = _ops[k]
		if not (op.rect as Rect2).has_point(w):
			continue
		match int(op.t):
			OP_MOUND:
				var d := w.distance_to(op.c)
				if d < op.r:
					h += op.h * 0.5 * (1.0 + cos(PI * d / op.r))
			OP_FLATTEN:
				var dx := maxf(absf(w.x - op.c.x) - op.half.x, 0.0)
				var dz := maxf(absf(w.y - op.c.y) - op.half.y, 0.0)
				h = lerpf(h, op.level, 1.0 - smoothstep(0.0, op.blend, sqrt(dx * dx + dz * dz)))
			OP_CHANNEL:
				h = minf(h, _channel_target(op, w))
			OP_RING:
				var d := w.distance_to(op.c)
				if d >= op.inner and d <= op.outer:
					var t := 1.0 - smoothstep(op.inner + (op.outer - op.inner) * 0.4, op.outer, d)
					h = maxf(h, lerpf(h, op.h, t))
			OP_MUD:
				var d := w.distance_to(op.c)
				if d < op.r and g < 0.5:
					m = maxf(m, op.amount * smoothstep(op.r, op.r * 0.4, d))
			OP_GRAVEL:
				g = 1.0
				m = 0.0
			OP_PROTECT:
				p = 1.0
	return Vector4(h, m, g, p)


## Height, mud and surface at a point without generating it: (height, mud, gravel, changed).
func info_at(wx: float, wz: float) -> Vector4:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	if _generated[mini(z / GEN_CELLS, GEN_CHUNKS - 1) * GEN_CHUNKS + mini(x / GEN_CELLS, GEN_CHUNKS - 1)] == 1:
		var i := z * VERTS + x
		var changed := 1.0 if disturbed[i] == 1 or absf(original[i] - heights[i]) > 0.05 else 0.0
		return Vector4(heights[i], mud[i], float(surface[i]), changed)
	var s := _sample(x, z)
	return Vector4(s.x, s.y, s.z, 0.0)


## Call once the world is laid out: sets up drawing and the horizon.
func finalize() -> void:
	_building = false
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	_chunk_indices = _grid_indices(1)
	for step in LOD_STEPS:
		_chunk_lods[step * LOD_ERROR] = _grid_indices(step)
	_collision_body = StaticBody3D.new()
	_collision_body.collision_layer = 1
	_collision_body.collision_mask = 0
	add_child(_collision_body)
	for t in FAR_TILES * FAR_TILES:
		var mi := MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_far_meshes.append(mi)
		_far_stale[t] = true
		_far_dirty[t] = true


## Builds everything near `point` straight away (call before the first frame).
func prepare_around(point: Vector3) -> void:
	_last_focus = Vector3.INF
	_update_near(point)
	# The closest ground now; the rest of the detailed ring streams in over the first frames.
	while not _near_queue.is_empty() and (_near_queue[0] as Vector2).x < 64.0:
		_build_next_near()
	for t in _far_dirty.keys():
		_build_far_tile(t)
	_far_dirty.clear()


func grid_to_world(x: int, z: int) -> Vector2:
	return Vector2(x * CELL_SIZE - HALF_SIZE, z * CELL_SIZE - HALF_SIZE)


func clamp_inside(p: Vector3, margin: float) -> Vector3:
	var limit := HALF_SIZE - margin
	return Vector3(clampf(p.x, -limit, limit), p.y, clampf(p.z, -limit, limit))


## Surface height at a world position, matching the rendered triangles.
func get_height(wx: float, wz: float) -> float:
	var gx := clampf(wx / CELL_SIZE + CELLS * 0.5, 0.0, CELLS - 0.001)
	var gz := clampf(wz / CELL_SIZE + CELLS * 0.5, 0.0, CELLS - 0.001)
	var x0 := floori(gx)
	var z0 := floori(gz)
	_ensure_vertex(x0, z0)
	_ensure_vertex(x0 + 1, z0 + 1)
	var fx := gx - x0
	var fz := gz - z0
	var i := z0 * VERTS + x0
	var h00 := heights[i]
	var h10 := heights[i + 1]
	var h01 := heights[i + VERTS]
	var h11 := heights[i + VERTS + 1]
	if fx > fz:
		return h00 + (h10 - h00) * fx + (h11 - h10) * fz
	return h00 + (h11 - h01) * fx + (h01 - h00) * fz


## Ground height before any digging or dumping, at a world position.
func original_height(wx: float, wz: float) -> float:
	var gx := clampf(wx / CELL_SIZE + CELLS * 0.5, 0.0, CELLS - 0.001)
	var gz := clampf(wz / CELL_SIZE + CELLS * 0.5, 0.0, CELLS - 0.001)
	var x0 := floori(gx)
	var z0 := floori(gz)
	_ensure_vertex(x0, z0)
	_ensure_vertex(x0 + 1, z0 + 1)
	var i := z0 * VERTS + x0
	var top := lerpf(original[i], original[i + 1], gx - x0)
	var bottom := lerpf(original[i + VERTS], original[i + VERTS + 1], gx - x0)
	return lerpf(top, bottom, gz - z0)


func _index_at(wx: float, wz: float) -> int:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	_ensure_vertex(x, z)
	return z * VERTS + x


## Wets ground where water has flowed (called by the water sim).
func wet_point(wx: float, wz: float, amount: float) -> void:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 2, VERTS - 3)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 2, VERTS - 3)
	_ensure(Rect2i(x - 2, z - 2, 5, 5))
	var changed := false
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var i := (z + dz) * VERTS + x + dx
			if mud[i] < amount and surface[i] != SURFACE_GRAVEL:
				mud[i] = amount
				changed = true
	if changed:
		# Every PC runs its own water, so wetting is redrawn here but never sent to players.
		var record := net_record
		var keep := record_edits
		net_record = false
		record_edits = false  # (and comes back with the water every session, so isn't saved)
		_mark_dirty_chunks(Rect2i(x - 2, z - 2, 5, 5))
		net_record = record
		record_edits = keep


func mud_at(wx: float, wz: float) -> float:
	return mud[_index_at(wx, wz)]


func is_gravel(wx: float, wz: float) -> bool:
	return surface[_index_at(wx, wz)] == SURFACE_GRAVEL


func is_protected(wx: float, wz: float) -> bool:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, CELLS)
	if _generated[mini(z / GEN_CELLS, GEN_CHUNKS - 1) * GEN_CHUNKS + mini(x / GEN_CELLS, GEN_CHUNKS - 1)] == 1:
		return protected[z * VERTS + x] == 1
	return _sample(x, z).w > 0.5


## Lowest a vertex may be cut to.
func _floor(i: int) -> float:
	return original[i] if protected[i] == 1 else MIN_HEIGHT


## True where the ground is untouched, dry and grassy.
func has_grass(wx: float, wz: float) -> bool:
	var i := _index_at(wx, wz)
	return grass_mask[i] == 1 and disturbed[i] == 0 and mud[i] < 0.3 and absf(original[i] - heights[i]) < 0.03


## How far the ground at (wx, wz) has been dug below where it started.
func dug_depth(wx: float, wz: float) -> float:
	var i := _index_at(wx, wz)
	return original[i] - heights[i]


## Volume (m3) dug out below the original ground (sign -1, counted down to `cap` deep) or
## piled above it (sign +1) over a rectangle, or a circle if `radius` > 0.
func soil_change(center: Vector2, half: Vector2, sign: float, cap: float, radius := 0.0) -> float:
	var r := _world_rect(center, half)
	_ensure(r)
	var total := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if radius > 0.0 and grid_to_world(x, z).distance_to(center) > radius:
				continue
			var i := z * VERTS + x
			total += clampf((heights[i] - original[i]) * sign, 0.0, cap)
	return total * CELL_AREA


func dig(center: Vector3, radius: float, max_volume: float) -> float:
	var rect := _vertex_rect(center.x, center.z, radius)
	_ensure(rect)
	var indices := PackedInt32Array()
	var cuts := PackedFloat32Array()
	var total := 0.0
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var w := grid_to_world(x, z)
			var d := Vector2(w.x - center.x, w.y - center.z).length()
			if d > radius:
				continue
			var t := d / radius
			var i := z * VERTS + x
			var target := maxf(center.y + t * t * radius * 0.9, _floor(i))
			var cut := heights[i] - target
			if cut > 0.0:
				indices.append(i)
				cuts.append(cut)
				total += cut
	if total <= 0.0:
		return 0.0
	var scale_factor := minf(1.0, max_volume / (total * CELL_AREA))
	for k in indices.size():
		heights[indices[k]] -= cuts[k] * scale_factor
		disturbed[indices[k]] = 1
		pressed[indices[k]] = 0
	_on_edited(rect)
	return total * CELL_AREA * scale_factor


## Drops `volume` m3 of soil in a cone around (wx, wz).
func deposit(wx: float, wz: float, volume: float, radius: float, material := SURFACE_SOIL) -> void:
	var rect := _vertex_rect(wx, wz, radius)
	_ensure(rect)
	var indices := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var w := grid_to_world(x, z)
			var weight := 1.0 - Vector2(w.x - wx, w.y - wz).length() / radius
			if weight > 0.0:
				indices.append(z * VERTS + x)
				weights.append(weight)
				total += weight
	if total <= 0.0:
		return
	for k in indices.size():
		var i := indices[k]
		heights[i] += volume * weights[k] / (total * CELL_AREA)
		disturbed[i] = 1
		pressed[i] = 0
		if material == SURFACE_GRAVEL:
			# Gravel makes firm ground: no mud, nothing sinks in.
			surface[i] = SURFACE_GRAVEL
			mud[i] = 0.0
	_on_edited(rect)


## Grades soil flat: everything above the line from `a` to `b` (a blade's cutting edge)
## within `back` behind and `front` ahead of it is cut down to the edge, removing at most
## `max_volume` m3. Returns the volume removed.
func cut_flat(a: Vector3, b: Vector3, forward: Vector3, back: float, front: float, max_volume: float) -> float:
	var edge := Vector2(b.x - a.x, b.z - a.z)
	var width := edge.length()
	if width < 0.01:
		return 0.0
	var along := edge / width
	var fwd := Vector2(forward.x, forward.z).normalized()
	var mid := Vector2(a.x + b.x, a.z + b.z) * 0.5
	var r := _world_rect(mid + fwd * (front - back) * 0.5, Vector2.ONE * (width * 0.5 + back + front))
	_ensure(r)
	var indices := PackedInt32Array()
	var cuts := PackedFloat32Array()
	var total := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var w := grid_to_world(x, z) - Vector2(a.x, a.z)
			var u := w.dot(along) / width
			var v := w.dot(fwd)
			if u < 0.0 or u > 1.0 or v < -back or v > front:
				continue
			var i := z * VERTS + x
			var cut := heights[i] - maxf(lerpf(a.y, b.y, u), _floor(i))
			if cut > 0.0:
				indices.append(i)
				cuts.append(cut)
				total += cut
	last_cut_wanted = total * CELL_AREA
	if total <= 0.0:
		return 0.0
	var scale_factor := minf(1.0, max_volume / (total * CELL_AREA))
	for k in indices.size():
		heights[indices[k]] -= cuts[k] * scale_factor
		disturbed[indices[k]] = 1
		pressed[indices[k]] = 0
	_on_edited(r)
	return total * CELL_AREA * scale_factor


## Spreads `volume` m3 evenly over a band ahead of the edge `a`-`b`, from `start` to
## `start + length` along `forward` (the berm in front of a dozer blade).
func deposit_strip(a: Vector3, b: Vector3, forward: Vector3, start: float, length: float, volume: float, material := SURFACE_SOIL) -> void:
	var edge := Vector2(b.x - a.x, b.z - a.z)
	var width := edge.length()
	if width < 0.01:
		return
	var along := edge / width
	var fwd := Vector2(forward.x, forward.z).normalized()
	var mid := Vector2(a.x + b.x, a.z + b.z) * 0.5 + fwd * (start + length * 0.5)
	var r := _world_rect(mid, Vector2.ONE * (width * 0.5 + length))
	_ensure(r)
	var indices := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var w := grid_to_world(x, z) - Vector2(a.x, a.z)
			var u := w.dot(along) / width
			var v := w.dot(fwd) - start
			if u < 0.0 or u > 1.0 or v < 0.0 or v > length:
				continue
			# Even across the blade, easing off at the very ends and the far side.
			var weight := minf(1.0, minf(u, 1.0 - u) * 8.0 + 0.25) * (1.0 - 0.5 * v / length)
			indices.append(z * VERTS + x)
			weights.append(weight)
			total += weight
	if total <= 0.0:
		return
	for k in indices.size():
		var i := indices[k]
		heights[i] += volume * weights[k] / (total * CELL_AREA)
		disturbed[i] = 1
		pressed[i] = 0
		if material == SURFACE_GRAVEL:
			surface[i] = SURFACE_GRAVEL
			mud[i] = 0.0
	_on_edited(r)


## Presses a rut under a track or wheel (an oriented rectangle). Firm ground ruts once;
## soft, muddy ground keeps giving way on every pass, up to a depth set by how wet it
## is, and the squeezed-out mud heaps up beside the rut. Flattens the grass, shows soil.
func press(center: Vector3, forward: Vector3, half_length: float, half_width: float, depth: float) -> void:
	var fwd := Vector2(forward.x, forward.z).normalized()
	var side := Vector2(-fwd.y, fwd.x)
	var c := Vector2(center.x, center.z)
	var r := _world_rect(c, Vector2.ONE * (half_length + half_width))
	_ensure(r)
	var changed := false
	var squeezed := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := z * VERTS + x
			if surface[i] == SURFACE_GRAVEL or protected[i] == 1:
				continue
			var soft := mud[i] > 0.3
			if pressed[i] == 1 and not soft:
				continue
			var w := grid_to_world(x, z) - c
			if absf(w.dot(fwd)) > half_length or absf(w.dot(side)) > half_width:
				continue
			if depth > 0.0:
				var sink := depth + 0.14 * mud[i] if pressed[i] == 0 else 0.03 * mud[i]
				var floor_height := original[i] - (depth + 0.7 * mud[i])
				var drop := clampf(heights[i] - floor_height, 0.0, sink) if soft else sink
				heights[i] -= drop
				if soft:
					squeezed += drop
			disturbed[i] = 1
			pressed[i] = 1
			changed = true
	if changed:
		_mark_dirty(r)
	if squeezed > 0.0:
		_push_aside(center, forward, half_width, squeezed * CELL_AREA)


## Spinning wheels and slipping tracks dig into soft ground: lowers the patch under them
## (no deeper than `max_depth` below the original ground) and throws the mud to the sides.
func dig_in(center: Vector3, forward: Vector3, half_length: float, half_width: float, amount: float, max_depth: float) -> float:
	var fwd := Vector2(forward.x, forward.z).normalized()
	var side := Vector2(-fwd.y, fwd.x)
	var c := Vector2(center.x, center.z)
	var r := _world_rect(c, Vector2.ONE * (half_length + half_width))
	_ensure(r)
	var removed := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := z * VERTS + x
			if mud[i] < 0.2 or surface[i] == SURFACE_GRAVEL or protected[i] == 1:
				continue
			var w := grid_to_world(x, z) - c
			if absf(w.dot(fwd)) > half_length or absf(w.dot(side)) > half_width:
				continue
			var drop := clampf(heights[i] - (original[i] - max_depth * mud[i]), 0.0, amount * mud[i])
			heights[i] -= drop
			disturbed[i] = 1
			removed += drop
	if removed <= 0.0:
		return 0.0
	_mark_dirty(r)
	_push_aside(center, forward, half_width, removed * CELL_AREA)
	return removed * CELL_AREA


func _push_aside(center: Vector3, forward: Vector3, half_width: float, volume: float) -> void:
	var side := Vector3(-forward.z, 0, forward.x).normalized() * (half_width + 0.3)
	for s in [-1.0, 1.0]:
		var p: Vector3 = center + side * s
		deposit(p.x, p.z, volume * 0.5, half_width * 0.8 + 0.2)


func _world_rect(center: Vector2, half_size: Vector2) -> Rect2i:
	var x0 := clampi(floori((center.x - half_size.x + HALF_SIZE) / CELL_SIZE), 0, VERTS - 1)
	var z0 := clampi(floori((center.y - half_size.y + HALF_SIZE) / CELL_SIZE), 0, VERTS - 1)
	var x1 := clampi(ceili((center.x + half_size.x + HALF_SIZE) / CELL_SIZE), 0, VERTS - 1)
	var z1 := clampi(ceili((center.y + half_size.y + HALF_SIZE) / CELL_SIZE), 0, VERTS - 1)
	return Rect2i(x0, z0, x1 - x0 + 1, z1 - z0 + 1)


func _vertex_rect(wx: float, wz: float, radius: float) -> Rect2i:
	return _world_rect(Vector2(wx, wz), Vector2(radius, radius))


func _on_edited(rect: Rect2i) -> void:
	_mark_dirty(rect)
	var grown := rect.grow(1).intersection(_full_rect)
	_add_slump_rect(grown)
	_slumping = true


func _mark_dirty(rect: Rect2i) -> void:
	_mark_dirty_chunks(rect)
	var tx0 := clampi(floori((rect.position.x - 1) / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	var tz0 := clampi(floori((rect.position.y - 1) / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	var tx1 := clampi(floori(rect.end.x / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	var tz1 := clampi(floori(rect.end.y / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	for tz in range(tz0, tz1 + 1):
		for tx in range(tx0, tx1 + 1):
			if _collision.has(tz * COLLISION_TILES + tx):
				_dirty_collision[tz * COLLISION_TILES + tx] = true
	_merge_rect(_wake_rects, rect, 8)


func _mark_dirty_chunks(rect: Rect2i) -> void:
	var cx0 := clampi(floori((rect.position.x - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	var cz0 := clampi(floori((rect.position.y - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	var cx1 := clampi(floori((rect.end.x - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	var cz1 := clampi(floori((rect.end.y - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var index := cz * CHUNKS + cx
			if _near.has(index):
				_dirty_chunks[index] = true
			_far_stale[_far_tile_of(cx, cz)] = true
			if net_record:
				net_dirty[index] = true
				net_changed[index] = true
			if record_edits:
				edited[index] = true
				save_stale[index] = true


func _physics_process(delta: float) -> void:
	for _pass in 2:
		if _slumping:
			_slump_pass()
	_collision_timer -= delta
	if not _dirty_collision.is_empty() and _collision_timer <= 0.0:
		for key in _dirty_collision.keys():
			_update_collision_tile(key)
		_dirty_collision.clear()
		_collision_timer = COLLISION_INTERVAL
		var waking := _wake_rects
		_wake_rects = []
		for w in waking:
			area_changed.emit(Rect2(grid_to_world(w.position.x, w.position.y), Vector2(w.size) * CELL_SIZE))


func _process(_delta: float) -> void:
	if _far_meshes.is_empty():
		return
	if focus:
		_update_near(focus.global_position)
	# Ground under things that need it first, then edited chunks (what you're digging must
	# update now), then streaming, all within a few milliseconds a frame.
	var start := Time.get_ticks_usec()
	while not _pending_collision.is_empty():
		var best: int = -1
		var best_d := INF
		for key in _pending_collision:
			if _pending_collision[key] < best_d:
				best_d = _pending_collision[key]
				best = key
		_pending_collision.erase(best)
		_add_collision_tile(best, Time.get_ticks_msec())
		# The close ones always go in at once; the rest a few at a time.
		if best_d > 400.0 and Time.get_ticks_usec() - start > 3000:
			break
	for key in _dirty_chunks.keys():
		if Time.get_ticks_usec() - start > 6000:
			break
		_dirty_chunks.erase(key)
		if _near.has(key):
			_build_chunk(key % CHUNKS, key / CHUNKS)
	while not _near_queue.is_empty() and Time.get_ticks_usec() - start < STREAM_BUDGET_USEC:
		_build_next_near()
	if not _far_dirty.is_empty() and Time.get_ticks_usec() - start < STREAM_BUDGET_USEC:
		var t: int = _far_dirty.keys()[0]
		_far_dirty.erase(t)
		_build_far_tile(t)


# --- Detailed chunks around the camera ------------------------------------------------------

func _update_near(p: Vector3) -> void:
	if p.distance_to(_last_focus) < 6.0:
		return
	_last_focus = p
	var size := CHUNK_CELLS * CELL_SIZE
	var reach := ceili(NEAR_RADIUS / size) + 1
	var cx := clampi(floori((p.x + HALF_SIZE) / size), 0, CHUNKS - 1)
	var cz := clampi(floori((p.z + HALF_SIZE) / size), 0, CHUNKS - 1)
	var wanted: Array = []
	for z in range(maxi(cz - reach, 0), mini(cz + reach, CHUNKS - 1) + 1):
		for x in range(maxi(cx - reach, 0), mini(cx + reach, CHUNKS - 1) + 1):
			var d := _chunk_center(x, z).distance_to(Vector2(p.x, p.z))
			if d < NEAR_RADIUS and not _near.has(z * CHUNKS + x):
				wanted.append(Vector2(d, z * CHUNKS + x))
	wanted.sort()
	_near_queue = wanted
	for index in _near.keys():
		if _chunk_center(index % CHUNKS, index / CHUNKS).distance_to(Vector2(p.x, p.z)) > NEAR_RADIUS + 24.0:
			(_near[index] as Node).queue_free()
			_near.erase(index)
			_dirty_chunks.erase(index)
			_far_dirty[_far_tile_of(index % CHUNKS, index / CHUNKS)] = true


func _build_next_near() -> void:
	var entry: Vector2 = _near_queue.pop_front()
	var index := int(entry.y)
	if _near.has(index):
		return
	var mi := MeshInstance3D.new()
	# Rolling ground barely casts visible shadows; skipping them halves terrain draw calls.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_near[index] = mi
	_build_chunk(index % CHUNKS, index / CHUNKS)
	_far_dirty[_far_tile_of(index % CHUNKS, index / CHUNKS)] = true


func _chunk_center(cx: int, cz: int) -> Vector2:
	var size := CHUNK_CELLS * CELL_SIZE
	return Vector2((cx + 0.5) * size - HALF_SIZE, (cz + 0.5) * size - HALF_SIZE)


## Triangles over every `step`-th vertex of a chunk, plus its edge skirts.
func _grid_indices(step: int) -> PackedInt32Array:
	var n := CHUNK_CELLS + 1
	var indices := PackedInt32Array()
	for lz in range(0, CHUNK_CELLS, step):
		for lx in range(0, CHUNK_CELLS, step):
			var a := lz * n + lx
			indices.append_array([a, a + step, a + step * n + step, a, a + step * n + step, a + step * n])
	# Skirt vertices follow the grid: one row per edge (top, bottom, left, right).
	var skirt := n * n
	for t in range(0, CHUNK_CELLS, step):
		for edge in 4:
			var v0: int
			var v1: int
			match edge:
				0: v0 = t; v1 = t + step
				1: v0 = CHUNK_CELLS * n + t; v1 = v0 + step
				2: v0 = t * n; v1 = (t + step) * n
				_: v0 = t * n + CHUNK_CELLS; v1 = (t + step) * n + CHUNK_CELLS
			var s0 := skirt + edge * n + t
			var s1 := s0 + step
			indices.append_array([v0, v1, s1, v0, s1, s0])
	return indices


func _build_chunk(cx: int, cz: int) -> void:
	var n := CHUNK_CELLS + 1
	_ensure(Rect2i(cx * CHUNK_CELLS - 1, cz * CHUNK_CELLS - 1, n + 2, n + 2).intersection(_full_rect))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var total := n * n + 4 * n
	verts.resize(total)
	normals.resize(total)
	colors.resize(total)
	uvs.resize(total)
	var k := 0
	var two_cell := 2.0 * CELL_SIZE
	# Vertex colour: natural ground, gravel, dug layers or spoil, muddied (inlined: this loop
	# runs 4,225 times a chunk).
	for lz in n:
		var z := cz * CHUNK_CELLS + lz
		var wz := z * CELL_SIZE - HALF_SIZE
		for lx in n:
			var x := cx * CHUNK_CELLS + lx
			var i := z * VERTS + x
			var h := heights[i]
			verts[k] = Vector3(x * CELL_SIZE - HALF_SIZE, h, wz)
			var left := heights[i - 1] if x > 0 else h
			var right := heights[i + 1] if x < VERTS - 1 else h
			var back := heights[i - VERTS] if z > 0 else h
			var front := heights[i + VERTS] if z < VERTS - 1 else h
			normals[k] = Vector3(left - right, two_cell, back - front).normalized()
			var m := mud[i]
			var gravel := surface[i] == SURFACE_GRAVEL
			var dug := original[i] - h
			var c: Color
			if disturbed[i] == 0 and absf(dug) < 0.03:
				c = GRAVEL if gravel else GROUND
				c.a = 0.0
			else:
				if gravel:
					c = GRAVEL.darkened(0.08)
				elif dug <= 0.0:
					c = LOOSE
				elif dug < 1.0:
					c = TOPSOIL.lerp(SUBSOIL, dug)
				elif dug < 2.5:
					c = SUBSOIL.lerp(CLAY, (dug - 1.0) / 1.5)
				else:
					c = CLAY.lerp(ROCK, clampf(dug - 2.5, 0.0, 1.0))
				c.a = 1.0
			if m > 0.0:
				var a := c.a
				c = c.lerp(MUD, m * 0.85)
				c.a = a
			colors[k] = c
			uvs[k] = Vector2(m, 0.0)
			k += 1
	# Skirts: copies of the edge vertices, dropped down.
	for edge in 4:
		for t in n:
			var src: int
			match edge:
				0: src = t
				1: src = (n - 1) * n + t
				2: src = t * n
				_: src = t * n + n - 1
			verts[k] = verts[src] - Vector3(0, SKIRT, 0)
			normals[k] = normals[src]
			colors[k] = colors[src]
			uvs[k] = uvs[src]
			k += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _chunk_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], _chunk_lods)
	mesh.surface_set_material(0, _material)
	(_near[cz * CHUNKS + cx] as MeshInstance3D).mesh = mesh
	chunk_rebuilt.emit(cx, cz)


# --- Horizon tiles ----------------------------------------------------------------------------

func _far_tile_of(cx: int, cz: int) -> int:
	var per := FAR_TILE_CELLS / CHUNK_CELLS
	return (cz / per) * FAR_TILES + cx / per


## A 128 m tile of coarse ground, leaving holes where detailed chunks are drawn.
func _build_far_tile(t: int) -> void:
	var tx := t % FAR_TILES
	var tz := t / FAR_TILES
	if _far_stale.has(t) or not _far_vertices.has(t):
		_far_stale.erase(t)
		var verts := PackedVector3Array()
		var colors := PackedColorArray()
		var uvs := PackedVector2Array()
		verts.resize(FAR_N * FAR_N)
		colors.resize(FAR_N * FAR_N)
		uvs.resize(FAR_N * FAR_N)
		var k := 0
		for lz in FAR_N:
			for lx in FAR_N:
				var x := tx * FAR_TILE_CELLS + lx * FAR_STEP
				var z := tz * FAR_TILE_CELLS + lz * FAR_STEP
				var w := grid_to_world(x, z)
				var info := info_at(w.x, w.y)
				verts[k] = Vector3(w.x, info.x - 0.04, w.y)
				var c := GRAVEL if info.z > 0.5 else (LOOSE if info.w > 0.5 else GROUND)
				c = c.lerp(MUD, info.y * 0.85)
				c.a = info.w
				colors[k] = c
				uvs[k] = Vector2(info.y, 0.0)
				k += 1
		var normals := PackedVector3Array()
		normals.resize(FAR_N * FAR_N)
		for lz in FAR_N:
			for lx in FAR_N:
				var i := lz * FAR_N + lx
				var l := verts[i - 1].y if lx > 0 else verts[i].y
				var r := verts[i + 1].y if lx < FAR_N - 1 else verts[i].y
				var b := verts[i - FAR_N].y if lz > 0 else verts[i].y
				var f := verts[i + FAR_N].y if lz < FAR_N - 1 else verts[i].y
				normals[i] = Vector3(l - r, 2.0 * FAR_STEP * CELL_SIZE, b - f).normalized()
		_far_vertices[t] = [verts, normals, colors, uvs]
	var cached: Array = _far_vertices[t]
	# Skip the 2 m quads under detailed chunks.
	var per := CHUNK_CELLS / FAR_STEP
	var indices := PackedInt32Array()
	for lz in FAR_N - 1:
		for lx in FAR_N - 1:
			var cx := (tx * FAR_TILE_CELLS) / CHUNK_CELLS + lx / per
			var cz := (tz * FAR_TILE_CELLS) / CHUNK_CELLS + lz / per
			if _near.has(cz * CHUNKS + cx):
				continue
			var a := lz * FAR_N + lx
			indices.append_array([a, a + 1, a + FAR_N + 1, a, a + FAR_N + 1, a + FAR_N])
	if indices.is_empty():
		_far_meshes[t].mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = cached[0]
	arrays[Mesh.ARRAY_NORMAL] = cached[1]
	arrays[Mesh.ARRAY_COLOR] = cached[2]
	arrays[Mesh.ARRAY_TEX_UV] = cached[3]
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	_far_meshes[t].mesh = mesh


# --- Collision around the things that need it ------------------------------------------------

## Keeps collision tiles around each anchor: [position, radius] pairs (players, machines,
## loose bodies). Tiles nobody has needed for a few seconds are dropped.
func set_anchors(anchors: Array) -> void:
	if _collision_body == null:
		return
	var now := Time.get_ticks_msec()
	var size := COLLISION_CELLS * CELL_SIZE
	for a in anchors:
		var p: Vector3 = a[0]
		var r: float = a[1]
		var tx0 := clampi(floori((p.x - r + HALF_SIZE) / size), 0, COLLISION_TILES - 1)
		var tx1 := clampi(floori((p.x + r + HALF_SIZE) / size), 0, COLLISION_TILES - 1)
		var tz0 := clampi(floori((p.z - r + HALF_SIZE) / size), 0, COLLISION_TILES - 1)
		var tz1 := clampi(floori((p.z + r + HALF_SIZE) / size), 0, COLLISION_TILES - 1)
		for tz in range(tz0, tz1 + 1):
			for tx in range(tx0, tx1 + 1):
				var key := tz * COLLISION_TILES + tx
				if _collision.has(key):
					_collision[key][2] = now
				elif not _pending_collision.has(key):
					# Nearest-first queue, a few built a frame (see _process).
					_pending_collision[key] = p.distance_squared_to(Vector3((tx + 0.5) * size - HALF_SIZE, p.y, (tz + 0.5) * size - HALF_SIZE))
	for key in _collision.keys():
		if now - int(_collision[key][2]) > 4000:
			(_collision[key][0] as Node).queue_free()
			_collision.erase(key)
			_dirty_collision.erase(key)


func has_collision_at(wx: float, wz: float) -> bool:
	var size := COLLISION_CELLS * CELL_SIZE
	var tx := clampi(floori((wx + HALF_SIZE) / size), 0, COLLISION_TILES - 1)
	var tz := clampi(floori((wz + HALF_SIZE) / size), 0, COLLISION_TILES - 1)
	return _collision.has(tz * COLLISION_TILES + tx)


func _add_collision_tile(key: int, now: int) -> void:
	var tx := key % COLLISION_TILES
	var tz := key / COLLISION_TILES
	var shape := HeightMapShape3D.new()
	shape.map_width = COLLISION_CELLS + 1
	shape.map_depth = COLLISION_CELLS + 1
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.scale = Vector3(CELL_SIZE, 1.0, CELL_SIZE)
	var size := COLLISION_CELLS * CELL_SIZE
	collision.position = Vector3((tx + 0.5) * size - HALF_SIZE, 0, (tz + 0.5) * size - HALF_SIZE)
	_collision_body.add_child(collision)
	_collision[key] = [collision, shape, now]
	_update_collision_tile(key)


func _update_collision_tile(key: int) -> void:
	if not _collision.has(key):
		return
	var tx := key % COLLISION_TILES
	var tz := key / COLLISION_TILES
	var n := COLLISION_CELLS + 1
	_ensure(Rect2i(tx * COLLISION_CELLS, tz * COLLISION_CELLS, n, n).intersection(_full_rect))
	var data := PackedFloat32Array()
	data.resize(n * n)
	var k := 0
	for z in n:
		var row := mini(tz * COLLISION_CELLS + z, CELLS) * VERTS + tx * COLLISION_CELLS
		for x in n:
			data[k] = heights[row + mini(x, CELLS - tx * COLLISION_CELLS)]
			k += 1
	(_collision[key][1] as HeightMapShape3D).map_data = data


# --- Slumping ------------------------------------------------------------------------------

func _add_slump_rect(r: Rect2i) -> void:
	_merge_rect(_slump_rects, r, 4)


## Adds a rectangle to a list, joined onto any it touches or nearly does (within `gap`).
static func _merge_rect(list: Array[Rect2i], r: Rect2i, gap: int) -> void:
	var near := r.grow(gap)
	var k := 0
	while k < list.size():
		if list[k].intersects(near):
			r = r.merge(list[k])
			near = r.grow(gap)
			list.remove_at(k)
			k = 0
		else:
			k += 1
	list.append(r)


## One relaxation pass over every settling area: any slope steeper than TALUS sheds
## soil downhill.
func _slump_pass() -> void:
	var still: Array[Rect2i] = []
	var waiting: Array[Rect2i] = []  # out of time this pass: first in line next time
	var start := Time.get_ticks_usec()
	var queue := _slump_rects
	var k := 0
	while k < queue.size():
		var r: Rect2i = queue[k]
		k += 1
		if Time.get_ticks_usec() - start > SLUMP_BUDGET_USEC:
			waiting.append(r)  # many sites at once share the time rather than stall a frame
			continue
		var min_x := VERTS
		var min_z := VERTS
		var max_x := -1
		var max_z := -1
		for z in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var i := z * VERTS + x
				if x + 1 < VERTS and _relax(i, i + 1):
					min_x = mini(min_x, x)
					max_x = maxi(max_x, x + 1)
					min_z = mini(min_z, z)
					max_z = maxi(max_z, z)
				if z + 1 < VERTS and _relax(i, i + VERTS):
					min_x = mini(min_x, x)
					max_x = maxi(max_x, x)
					min_z = mini(min_z, z)
					max_z = maxi(max_z, z + 1)
		if max_x < 0:
			continue
		var changed := Rect2i(min_x, min_z, max_x - min_x + 1, max_z - min_z + 1)
		_mark_dirty(changed)
		var next := changed.grow(1).intersection(_full_rect)
		_ensure(next)
		still.append(next)
	_slump_rects = []
	for r in waiting + still:
		_add_slump_rect(r)
	_slumping = not _slump_rects.is_empty()


func _relax(a: int, b: int) -> bool:
	var diff := heights[a] - heights[b]
	if absf(diff) <= TALUS + 0.002:
		return false
	# Natural slopes stay as they are (a riverbank or hillside steeper than loose soil's
	# angle would otherwise keep eroding forever once a dig nearby set it going); only
	# what digging and dumping made steeper than that settles, back to the natural slope.
	var limit := maxf(TALUS, absf(original[a] - original[b]))
	if absf(diff) <= limit + 0.002:
		return false
	var move := (diff - signf(diff) * limit) * 0.25
	# Protected ground holds its shape: it only sheds spoil piled on top of it.
	var giver := a if move > 0.0 else b
	if protected[giver] == 1:
		var spare := heights[giver] - original[giver]
		if spare <= 0.0005:
			return false
		move = signf(move) * minf(absf(move), spare)
	heights[a] -= move
	heights[b] += move
	disturbed[b if move > 0.0 else a] = 1
	return true


# --- Network ---------------------------------------------------------------------------------

## One chunk's ground (heights, mud, dug and rutted flags, surface) for the network.
func net_pack_chunk(index: int) -> Array:
	var cx := index % CHUNKS
	var cz := index / CHUNKS
	var n := CHUNK_CELLS + 1
	_ensure(Rect2i(cx * CHUNK_CELLS, cz * CHUNK_CELLS, n, n).intersection(_full_rect))
	var h := PackedFloat32Array()
	var m := PackedFloat32Array()
	var d := PackedByteArray()
	var p := PackedByteArray()
	var s := PackedByteArray()
	h.resize(n * n)
	m.resize(n * n)
	d.resize(n * n)
	p.resize(n * n)
	s.resize(n * n)
	var k := 0
	for lz in n:
		var row := mini(cz * CHUNK_CELLS + lz, CELLS) * VERTS + cx * CHUNK_CELLS
		for lx in n:
			var i := row + mini(lx, CELLS - cx * CHUNK_CELLS)
			h[k] = heights[i]
			m[k] = mud[i]
			d[k] = disturbed[i]
			p[k] = pressed[i]
			s[k] = surface[i]
			k += 1
	return [index, h, m, d, p, s]


## A chunk packed small for the network: each height as millimetres off the untouched
## ground (which every player generates identically, so unchanged ground is all zeros
## and compresses to almost nothing), mud in 1/255 steps, the flags as they are.
func net_pack_delta(index: int) -> Array:
	var cx := index % CHUNKS
	var cz := index / CHUNKS
	var n := CHUNK_CELLS + 1
	_ensure(Rect2i(cx * CHUNK_CELLS, cz * CHUNK_CELLS, n, n).intersection(_full_rect))
	var h := PackedByteArray()
	var m := PackedByteArray()
	var d := PackedByteArray()
	var p := PackedByteArray()
	var s := PackedByteArray()
	h.resize(n * n * 2)
	m.resize(n * n)
	d.resize(n * n)
	p.resize(n * n)
	s.resize(n * n)
	var k := 0
	for lz in n:
		var row := mini(cz * CHUNK_CELLS + lz, CELLS) * VERTS + cx * CHUNK_CELLS
		for lx in n:
			var i := row + mini(lx, CELLS - cx * CHUNK_CELLS)
			h.encode_s16(k * 2, clampi(roundi((heights[i] - original[i]) * 1000.0), -32767, 32767))
			m[k] = clampi(roundi(mud[i] * 255.0), 0, 255)
			d[k] = disturbed[i]
			p[k] = pressed[i]
			s[k] = surface[i]
			k += 1
	return [index, "delta", h, m, d, p, s]


## Applies a chunk from the host or a save; false if it's waiting for its ground to be
## generated (it goes in then, so far-off changes cost nothing until you get near).
func net_apply_chunk(data: Array) -> bool:
	var index: int = data[0]
	var cx := index % CHUNKS
	var cz := index / CHUNKS
	var n := CHUNK_CELLS + 1
	if not _chunk_generated(cx, cz):
		_pending_chunks[index] = data
		return false
	_pending_chunks.erase(index)
	if data.size() == 7 and data[1] is String:
		var dh: PackedByteArray = data[2]
		var dm: PackedByteArray = data[3]
		var dd: PackedByteArray = data[4]
		var dp: PackedByteArray = data[5]
		var ds: PackedByteArray = data[6]
		var j := 0
		for lz in n:
			var row := mini(cz * CHUNK_CELLS + lz, CELLS) * VERTS + cx * CHUNK_CELLS
			for lx in n:
				var i := row + mini(lx, CELLS - cx * CHUNK_CELLS)
				heights[i] = original[i] + dh.decode_s16(j * 2) * 0.001
				mud[i] = dm[j] / 255.0
				disturbed[i] = dd[j]
				pressed[i] = dp[j]
				surface[i] = ds[j]
				j += 1
		_mark_dirty(Rect2i(cx * CHUNK_CELLS, cz * CHUNK_CELLS, n, n))
		return true
	var h: PackedFloat32Array = data[1]
	var m: PackedFloat32Array = data[2]
	var d: PackedByteArray = data[3]
	var p: PackedByteArray = data[4]
	var s: PackedByteArray = data[5] if data.size() > 5 else PackedByteArray()
	var k := 0
	for lz in n:
		var row := mini(cz * CHUNK_CELLS + lz, CELLS) * VERTS + cx * CHUNK_CELLS
		for lx in n:
			var i := row + mini(lx, CELLS - cx * CHUNK_CELLS)
			heights[i] = h[k]
			mud[i] = m[k]
			disturbed[i] = d[k]
			pressed[i] = p[k]
			if not s.is_empty():
				surface[i] = s[k]
			k += 1
	_mark_dirty(Rect2i(cx * CHUNK_CELLS, cz * CHUNK_CELLS, n, n))
	return true
