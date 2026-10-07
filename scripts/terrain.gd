extends Node3D
## Deformable heightmap terrain. Soil is a volume budget: digging removes volume,
## dumping adds it back, and slumping spreads steep piles into natural slopes.
## Rendered as smooth-shaded chunks: golden ground under the grass, gravel yards,
## shiny mud, and soil that shifts from topsoil to red subsoil, clay and rock the
## deeper you cut. Collision is split into tiles so digging only rebuilds nearby ones.

signal area_changed(world_rect: Rect2)
signal chunk_rebuilt(cx: int, cz: int)

const CELLS := 1152
const CELL_SIZE := 0.25
const VERTS := CELLS + 1
const CHUNK_CELLS := 32
const CHUNKS := 36  # CELLS / CHUNK_CELLS
const COLLISION_CELLS := 64
const COLLISION_TILES := 18  # CELLS / COLLISION_CELLS
const HALF_SIZE := CELLS * CELL_SIZE * 0.5
const CELL_AREA := CELL_SIZE * CELL_SIZE
const MIN_HEIGHT := -12.0
const TALUS := CELL_SIZE * 0.72  # max height step between neighbours (~36 degree slopes)
const COLLISION_INTERVAL := 0.1

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
## Volume the last cut_flat() call wanted to remove (it may have removed less).
var last_cut_wanted := 0.0

var _chunk_meshes: Array[MeshInstance3D] = []
var _dirty_chunks := {}
var _material := ShaderMaterial.new()
var _chunk_indices := PackedInt32Array()
var _collision_shapes: Array[HeightMapShape3D] = []
var _dirty_collision := {}
var _collision_timer := 0.0
var _wake_rect := Rect2i()
var _has_wake := false
var _slump_rect := Rect2i()
var _slumping := false
var _full_rect := Rect2i(0, 0, VERTS, VERTS)


func generate(seed_value: int) -> void:
	var count := VERTS * VERTS
	heights.resize(count)
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
	var hills := FastNoiseLite.new()
	hills.seed = seed_value
	hills.frequency = 0.008
	hills.fractal_octaves = 3
	var detail := FastNoiseLite.new()
	detail.seed = seed_value + 1
	detail.frequency = 0.05
	for z in VERTS:
		for x in VERTS:
			var w := grid_to_world(x, z)
			# Fade to flat at the border so the map meets the surrounding meadow.
			var edge := 1.0 - smoothstep(HALF_SIZE - 8.0, HALF_SIZE - 0.5, maxf(absf(w.x), absf(w.y)))
			heights[z * VERTS + x] = (hills.get_noise_2dv(w) * 4.5 + detail.get_noise_2dv(w) * 0.5) * edge


func add_mound(center: Vector2, radius: float, height: float) -> void:
	var r := _world_rect(center, Vector2(radius, radius))
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var d := grid_to_world(x, z).distance_to(center)
			if d < radius:
				heights[z * VERTS + x] += height * 0.5 * (1.0 + cos(PI * d / radius))


## Levels a rectangular pad and returns its height (`level` overrides the average).
func flatten(center: Vector2, half_size: Vector2, blend: float, level := NAN) -> float:
	var inner := _world_rect(center, half_size)
	if is_nan(level):
		var total := 0.0
		var n := 0
		for z in range(inner.position.y, inner.end.y):
			for x in range(inner.position.x, inner.end.x):
				total += heights[z * VERTS + x]
				n += 1
		level = total / maxi(n, 1)
	var outer := _world_rect(center, half_size + Vector2(blend, blend))
	for z in range(outer.position.y, outer.end.y):
		for x in range(outer.position.x, outer.end.x):
			var w := grid_to_world(x, z)
			var dx := maxf(absf(w.x - center.x) - half_size.x, 0.0)
			var dz := maxf(absf(w.y - center.y) - half_size.y, 0.0)
			var t := 1.0 - smoothstep(0.0, blend, sqrt(dx * dx + dz * dz))
			var i := z * VERTS + x
			heights[i] = lerpf(heights[i], level, t)
	return level


## Cuts a channel along `path` (world XZ points). `beds` gives the wanted bed height at
## each point; where the ground is lower the bed drops so the channel always has banks.
## Banks rise at `bank_slope` until they meet the existing ground. Returns the beds used.
func carve_channel(path: PackedVector2Array, wanted: PackedFloat32Array, half_width: float, bank_depth: float, bank_slope: float) -> PackedFloat32Array:
	var beds := PackedFloat32Array()
	for k in path.size():
		beds.append(minf(wanted[k], get_height(path[k].x, path[k].y) - bank_depth * 0.9))
	var reach := half_width + 12.0
	for s in path.size() - 1:
		var a := path[s]
		var b := path[s + 1]
		var r := _world_rect((a + b) * 0.5, Vector2(absf(b.x - a.x), absf(b.y - a.y)) * 0.5 + Vector2(reach, reach))
		var seg := b - a
		var len_sq := maxf(seg.length_squared(), 0.0001)
		for z in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var w := grid_to_world(x, z)
				var t := clampf((w - a).dot(seg) / len_sq, 0.0, 1.0)
				var d := w.distance_to(a + seg * t)
				if d > reach:
					continue
				var bed := lerpf(beds[s], beds[s + 1], t)
				var target: float
				if d < half_width:
					target = bed + bank_depth * pow(d / half_width, 2.0)
				else:
					target = bed + bank_depth + (d - half_width) * bank_slope
				var i := z * VERTS + x
				if target < heights[i]:
					heights[i] = target
					if d < half_width + 1.0:
						grass_mask[i] = 0
	return beds


## Raises low ground in a ring around `center` to at least `height` (a lake's rim).
func raise_ring(center: Vector2, inner: float, outer: float, height: float) -> void:
	var r := _world_rect(center, Vector2(outer, outer))
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var d := grid_to_world(x, z).distance_to(center)
			if d < inner or d > outer:
				continue
			var i := z * VERTS + x
			var t := 1.0 - smoothstep(inner + (outer - inner) * 0.4, outer, d)
			heights[i] = maxf(heights[i], lerpf(heights[i], height, t))


## Makes ground muddy (0..1) in a soft circle.
func add_mud(center: Vector2, radius: float, amount: float) -> void:
	var r := _world_rect(center, Vector2(radius, radius))
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var d := grid_to_world(x, z).distance_to(center)
			if d < radius:
				var i := z * VERTS + x
				mud[i] = maxf(mud[i], amount * smoothstep(radius, radius * 0.4, d))


## Wets ground where water has flowed (called by the water sim); returns true if it changed.
func wet_point(wx: float, wz: float, amount: float) -> void:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 1, VERTS - 2)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 1, VERTS - 2)
	var changed := false
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var i := (z + dz) * VERTS + x + dx
			if mud[i] < amount:
				mud[i] = amount
				changed = true
	if changed:
		_mark_dirty_chunks(Rect2i(x - 2, z - 2, 5, 5))


func mud_at(wx: float, wz: float) -> float:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, VERTS - 1)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, VERTS - 1)
	return mud[z * VERTS + x]


func paint_gravel(center: Vector2, half_size: Vector2) -> void:
	var r := _world_rect(center, half_size)
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := z * VERTS + x
			surface[i] = SURFACE_GRAVEL
			grass_mask[i] = 0


## Marks ground as worked soil (e.g. stockpiles) so it shows soil colour instead of grass.
func mark_disturbed(center: Vector2, radius: float) -> void:
	var r := _world_rect(center, Vector2(radius, radius))
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if grid_to_world(x, z).distance_to(center) <= radius:
				disturbed[z * VERTS + x] = 1


## Stops grass growing within `radius` of `center`.
func clear_grass(center: Vector2, radius: float) -> void:
	var r := _world_rect(center, Vector2(radius, radius))
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if grid_to_world(x, z).distance_to(center) <= radius:
				grass_mask[z * VERTS + x] = 0


## True where the ground is untouched, dry and grassy.
func has_grass(wx: float, wz: float) -> bool:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, VERTS - 1)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, VERTS - 1)
	var i := z * VERTS + x
	return grass_mask[i] == 1 and disturbed[i] == 0 and mud[i] < 0.3 and absf(original[i] - heights[i]) < 0.03


## How far the ground at (wx, wz) has been dug below where it started.
func dug_depth(wx: float, wz: float) -> float:
	var x := clampi(roundi(wx / CELL_SIZE + CELLS * 0.5), 0, VERTS - 1)
	var z := clampi(roundi(wz / CELL_SIZE + CELLS * 0.5), 0, VERTS - 1)
	var i := z * VERTS + x
	return original[i] - heights[i]


## Call once after generation to build meshes and collision.
func finalize() -> void:
	original = heights.duplicate()
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	var n := CHUNK_CELLS + 1
	for lz in CHUNK_CELLS:
		for lx in CHUNK_CELLS:
			var a := lz * n + lx
			_chunk_indices.append_array([a, a + 1, a + n + 1, a, a + n + 1, a + n])
	for cz in CHUNKS:
		for cx in CHUNKS:
			var mesh_instance := MeshInstance3D.new()
			# Rolling ground barely casts visible shadows; skipping them halves terrain draw calls.
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mesh_instance)
			_chunk_meshes.append(mesh_instance)
			_build_chunk(cx, cz)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var tile_size := COLLISION_CELLS * CELL_SIZE
	for tz in COLLISION_TILES:
		for tx in COLLISION_TILES:
			var shape := HeightMapShape3D.new()
			shape.map_width = COLLISION_CELLS + 1
			shape.map_depth = COLLISION_CELLS + 1
			_collision_shapes.append(shape)
			_update_collision_tile(tx, tz)
			var collision := CollisionShape3D.new()
			collision.shape = shape
			collision.scale = Vector3(CELL_SIZE, 1.0, CELL_SIZE)
			collision.position = Vector3((tx + 0.5) * tile_size - HALF_SIZE, 0, (tz + 0.5) * tile_size - HALF_SIZE)
			body.add_child(collision)


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
	var i := z0 * VERTS + x0
	var top := lerpf(original[i], original[i + 1], gx - x0)
	var bottom := lerpf(original[i + VERTS], original[i + VERTS + 1], gx - x0)
	return lerpf(top, bottom, gz - z0)


## Carves a bowl below `center`, removing at most `max_volume` m3. Returns volume removed.
func dig(center: Vector3, radius: float, max_volume: float) -> float:
	var rect := _vertex_rect(center.x, center.z, radius)
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
			var target := maxf(center.y + t * t * radius * 0.9, MIN_HEIGHT)
			var i := z * VERTS + x
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
func deposit(wx: float, wz: float, volume: float, radius: float) -> void:
	var rect := _vertex_rect(wx, wz, radius)
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
		heights[indices[k]] += volume * weights[k] / (total * CELL_AREA)
		disturbed[indices[k]] = 1
		pressed[indices[k]] = 0
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
			var cut := heights[i] - maxf(lerpf(a.y, b.y, u), MIN_HEIGHT)
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
func deposit_strip(a: Vector3, b: Vector3, forward: Vector3, start: float, length: float, volume: float) -> void:
	var edge := Vector2(b.x - a.x, b.z - a.z)
	var width := edge.length()
	if width < 0.01:
		return
	var along := edge / width
	var fwd := Vector2(forward.x, forward.z).normalized()
	var mid := Vector2(a.x + b.x, a.z + b.z) * 0.5 + fwd * (start + length * 0.5)
	var r := _world_rect(mid, Vector2.ONE * (width * 0.5 + length))
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
		heights[indices[k]] += volume * weights[k] / (total * CELL_AREA)
		disturbed[indices[k]] = 1
		pressed[indices[k]] = 0
	_on_edited(r)


## Presses a rut under a track or wheel (an oriented rectangle). Firm ground ruts once;
## soft, muddy ground keeps giving way on every pass, up to a depth set by how wet it
## is, and the squeezed-out mud heaps up beside the rut. Flattens the grass, shows soil.
func press(center: Vector3, forward: Vector3, half_length: float, half_width: float, depth: float) -> void:
	var fwd := Vector2(forward.x, forward.z).normalized()
	var side := Vector2(-fwd.y, fwd.x)
	var c := Vector2(center.x, center.z)
	var r := _world_rect(c, Vector2.ONE * (half_length + half_width))
	var changed := false
	var squeezed := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := z * VERTS + x
			if surface[i] == SURFACE_GRAVEL:
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
	var removed := 0.0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := z * VERTS + x
			if mud[i] < 0.2 or surface[i] == SURFACE_GRAVEL:
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
	_slump_rect = _slump_rect.merge(grown) if _slumping else grown
	_slumping = true


func _mark_dirty(rect: Rect2i) -> void:
	_mark_dirty_chunks(rect)
	var tx0 := clampi(floori((rect.position.x - 1) / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	var tz0 := clampi(floori((rect.position.y - 1) / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	var tx1 := clampi(floori(rect.end.x / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	var tz1 := clampi(floori(rect.end.y / float(COLLISION_CELLS)), 0, COLLISION_TILES - 1)
	for tz in range(tz0, tz1 + 1):
		for tx in range(tx0, tx1 + 1):
			_dirty_collision[tz * COLLISION_TILES + tx] = true
	_wake_rect = _wake_rect.merge(rect) if _has_wake else rect
	_has_wake = true


func _mark_dirty_chunks(rect: Rect2i) -> void:
	var cx0 := clampi(floori((rect.position.x - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	var cz0 := clampi(floori((rect.position.y - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	var cx1 := clampi(floori((rect.end.x - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	var cz1 := clampi(floori((rect.end.y - 1) / float(CHUNK_CELLS)), 0, CHUNKS - 1)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			_dirty_chunks[cz * CHUNKS + cx] = true


func _physics_process(delta: float) -> void:
	for _pass in 2:
		if _slumping:
			_slump_pass()
	_collision_timer -= delta
	if not _dirty_collision.is_empty() and _collision_timer <= 0.0:
		for key in _dirty_collision.keys():
			var index: int = key
			_update_collision_tile(index % COLLISION_TILES, floori(index / float(COLLISION_TILES)))
		_dirty_collision.clear()
		_collision_timer = COLLISION_INTERVAL
		if _has_wake:
			var corner := grid_to_world(_wake_rect.position.x, _wake_rect.position.y)
			area_changed.emit(Rect2(corner, Vector2(_wake_rect.size) * CELL_SIZE))
			_has_wake = false


func _process(_delta: float) -> void:
	for key in _dirty_chunks.keys():
		var index: int = key
		_build_chunk(index % CHUNKS, floori(index / float(CHUNKS)))
	_dirty_chunks.clear()


func _update_collision_tile(tx: int, tz: int) -> void:
	var n := COLLISION_CELLS + 1
	var data := PackedFloat32Array()
	data.resize(n * n)
	var k := 0
	for z in n:
		var row := (tz * COLLISION_CELLS + z) * VERTS + tx * COLLISION_CELLS
		for x in n:
			data[k] = heights[row + x]
			k += 1
	_collision_shapes[tz * COLLISION_TILES + tx].map_data = data


## One relaxation pass: any slope steeper than TALUS sheds soil downhill.
func _slump_pass() -> void:
	var r := _slump_rect
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
		_slumping = false
		return
	var changed := Rect2i(min_x, min_z, max_x - min_x + 1, max_z - min_z + 1)
	_mark_dirty(changed)
	_slump_rect = changed.grow(1).intersection(_full_rect)


func _relax(a: int, b: int) -> bool:
	var diff := heights[a] - heights[b]
	if absf(diff) <= TALUS + 0.002:
		return false
	var move := (diff - signf(diff) * TALUS) * 0.25
	heights[a] -= move
	heights[b] += move
	disturbed[b if move > 0.0 else a] = 1
	return true


func _build_chunk(cx: int, cz: int) -> void:
	var n := CHUNK_CELLS + 1
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
			var x := cx * CHUNK_CELLS + lx
			var z := cz * CHUNK_CELLS + lz
			var i := z * VERTS + x
			var w := grid_to_world(x, z)
			verts[k] = Vector3(w.x, heights[i], w.y)
			var left := heights[i - 1] if x > 0 else heights[i]
			var right := heights[i + 1] if x < VERTS - 1 else heights[i]
			var back := heights[i - VERTS] if z > 0 else heights[i]
			var front := heights[i + VERTS] if z < VERTS - 1 else heights[i]
			normals[k] = Vector3(left - right, 2.0 * CELL_SIZE, back - front).normalized()
			colors[k] = _vertex_color(i)
			uvs[k] = Vector2(mud[i], 0.0)
			k += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _chunk_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	_chunk_meshes[cz * CHUNKS + cx].mesh = mesh
	chunk_rebuilt.emit(cx, cz)


func _vertex_color(i: int) -> Color:
	var depth := original[i] - heights[i]
	var c: Color
	if disturbed[i] == 0 and absf(depth) < 0.03:
		c = GRAVEL if surface[i] == SURFACE_GRAVEL else GROUND
		c.a = 0.0
	else:
		if depth <= 0.0:
			c = LOOSE
		elif depth < 1.0:
			c = TOPSOIL.lerp(SUBSOIL, depth)
		elif depth < 2.5:
			c = SUBSOIL.lerp(CLAY, (depth - 1.0) / 1.5)
		else:
			c = CLAY.lerp(ROCK, clampf(depth - 2.5, 0.0, 1.0))
		c.a = 1.0
	if mud[i] > 0.0:
		var a := c.a
		c = c.lerp(MUD, mud[i] * 0.85)
		c.a = a
	return c
