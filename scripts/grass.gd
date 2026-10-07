extends Node3D
## Dense golden grass that sways in the wind. One MultiMesh per terrain chunk, built
## only for chunks near the camera (a few per frame) and freed when far away, and
## rebuilt whenever its chunk changes so grass vanishes wherever you dig or dump.
## A static field outside the map fills the surrounding meadow.

const Terrain = preload("res://scripts/terrain.gd")

const PATCH_CELLS := 16  # grass is built in 4 m patches
const PATCHES := 72  # Terrain.CELLS / PATCH_CELLS
const TUFTS_PER_CHUNK := 800
const BLADES := 4
const LOAD_RADIUS := 42.0
const UNLOAD_RADIUS := 52.0
const BUILDS_PER_FRAME := 3
const FADE_START := 34.0
const BASE := Color(0.5, 0.38, 0.18)
const TIP := Color(0.96, 0.8, 0.46)

const SHADER := """
shader_type spatial;
render_mode cull_disabled;

// UV.y: 0 at the root, 1 at the tip.
void vertex() {
	vec3 root = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float gust = sin(TIME * 1.7 + root.x * 0.45 + root.z * 0.3) * 0.6 + sin(TIME * 3.3 + root.x * 1.4) * 0.25;
	float bend = UV.y * UV.y;
	VERTEX.x += gust * 0.09 * bend;
	VERTEX.z += gust * 0.05 * bend;
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.35, 0.28, 0.1);
}
"""

var terrain: Terrain
## Grass loads around this node (the camera).
var focus: Node3D
var _instances := {}  # chunk index -> MultiMeshInstance3D
var _stale := {}  # loaded chunks whose terrain changed
var _mesh: ArrayMesh


func setup(terrain_node: Terrain, focus_node: Node3D) -> void:
	terrain = terrain_node
	focus = focus_node
	_mesh = _make_tuft()
	# A rebuilt terrain chunk covers several grass patches; refresh the loaded ones.
	terrain.chunk_rebuilt.connect(func(cx: int, cz: int) -> void:
		var per := Terrain.CHUNK_CELLS / PATCH_CELLS
		for dz in per:
			for dx in per:
				var index := (cz * per + dz) * PATCHES + cx * per + dx
				if _instances.has(index):
					_stale[index] = true)


func _process(_delta: float) -> void:
	if focus == null:
		return
	var p := focus.global_position
	var size := PATCH_CELLS * Terrain.CELL_SIZE
	var built := 0
	for index in _stale.keys():
		if built >= BUILDS_PER_FRAME:
			break
		_build(index)
		_stale.erase(index)
		built += 1
	# Load the nearest missing chunks, unload far ones.
	var cx0 := clampi(floori((p.x - LOAD_RADIUS + Terrain.HALF_SIZE) / size), 0, PATCHES - 1)
	var cx1 := clampi(floori((p.x + LOAD_RADIUS + Terrain.HALF_SIZE) / size), 0, PATCHES - 1)
	var cz0 := clampi(floori((p.z - LOAD_RADIUS + Terrain.HALF_SIZE) / size), 0, PATCHES - 1)
	var cz1 := clampi(floori((p.z + LOAD_RADIUS + Terrain.HALF_SIZE) / size), 0, PATCHES - 1)
	var wanted: Array[Vector2] = []
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var index := cz * PATCHES + cx
			if _instances.has(index):
				continue
			var d := _chunk_center(cx, cz).distance_to(Vector2(p.x, p.z))
			if d < LOAD_RADIUS:
				wanted.append(Vector2(d, index))
	wanted.sort()
	for w in wanted:
		if built >= BUILDS_PER_FRAME:
			break
		_build(int(w.y))
		built += 1
	for index in _instances.keys():
		var c := _chunk_center(index % PATCHES, index / PATCHES)
		if c.distance_to(Vector2(p.x, p.z)) > UNLOAD_RADIUS:
			(_instances[index] as Node).queue_free()
			_instances.erase(index)
			_stale.erase(index)


func _chunk_center(cx: int, cz: int) -> Vector2:
	var size := PATCH_CELLS * Terrain.CELL_SIZE
	return Vector2((cx + 0.5) * size - Terrain.HALF_SIZE, (cz + 0.5) * size - Terrain.HALF_SIZE)


func _build(index: int) -> void:
	var cx := index % PATCHES
	var cz := index / PATCHES
	var rng := RandomNumberGenerator.new()
	rng.seed = cz * 1009 + cx * 31 + 7
	var size := PATCH_CELLS * Terrain.CELL_SIZE
	var origin := terrain.grid_to_world(cx * PATCH_CELLS, cz * PATCH_CELLS)
	var xforms: Array[Transform3D] = []
	var tints: Array[Color] = []
	for n in TUFTS_PER_CHUNK:
		# Always draw the same random numbers so tufts keep their spots between rebuilds.
		var wx := origin.x + rng.randf() * size
		var wz := origin.y + rng.randf() * size
		var yaw := rng.randf() * TAU
		var size_factor := rng.randf_range(0.7, 1.3)
		var shade := rng.randf_range(0.85, 1.1)
		if not terrain.has_grass(wx, wz):
			continue
		xforms.append(_tuft_xform(wx, terrain.get_height(wx, wz), wz, yaw, size_factor))
		tints.append(Color(shade, shade, shade * 0.95))
	var instance: MultiMeshInstance3D = _instances.get(index)
	if instance == null:
		instance = MultiMeshInstance3D.new()
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.visibility_range_end = UNLOAD_RADIUS
		instance.visibility_range_end_margin = UNLOAD_RADIUS - FADE_START
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(instance)
		_instances[index] = instance
	instance.multimesh = _make_multimesh(xforms, tints)


## Scatter tufts over the meadow between `inner` and `outer` half-widths around the map.
func add_meadow(inner: float, outer: float, count: int, height: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var xforms: Array[Transform3D] = []
	var tints: Array[Color] = []
	while xforms.size() < count:
		var p := Vector2(rng.randf_range(-outer, outer), rng.randf_range(-outer, outer))
		if maxf(absf(p.x), absf(p.y)) < inner:
			continue
		var shade := rng.randf_range(0.85, 1.1)
		xforms.append(_tuft_xform(p.x, height, p.y, rng.randf() * TAU, rng.randf_range(0.8, 1.4)))
		tints.append(Color(shade, shade, shade * 0.95))
	var instance := MultiMeshInstance3D.new()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.multimesh = _make_multimesh(xforms, tints)
	add_child(instance)


func _tuft_xform(x: float, y: float, z: float, yaw: float, size_factor: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(size_factor, size_factor, size_factor)), Vector3(x, y - 0.02, z))


func _make_multimesh(xforms: Array[Transform3D], tints: Array[Color]) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, tints[i])
	return mm


## A tuft of thin leaning blades, darker at the root.
func _make_tuft() -> ArrayMesh:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for b in BLADES:
		var angle := TAU * b / BLADES + rng.randf_range(-0.4, 0.4)
		var out := Vector3(cos(angle), 0, sin(angle))
		var side := Vector3(-out.z, 0, out.x) * 0.035
		var height := rng.randf_range(0.32, 0.58)
		var tip := out * rng.randf_range(0.08, 0.18) + Vector3(0, height, 0)
		for v in [[-side, 0.0], [side, 0.0], [tip, 1.0]]:
			verts.append(v[0])
			colors.append(BASE.lerp(TIP, v[1]))
			uvs.append(Vector2(0.5, v[1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	material.shader = shader
	mesh.surface_set_material(0, material)
	return mesh
