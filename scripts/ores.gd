extends RefCounted
## What's in the ground: dig below the topsoil and now and then a chunk of ore turns up
## in the hole (iron and copper are common, silver less so, gold and emeralds rare and
## deep). Where each lies is fixed by the map (copper and iron round the quarry, silver
## in the hills, gold along the rivers and the big hills, emeralds in the hills and the
## snowfield), and boulders on the surface, some flecked with ore, hint at it. Take ore to
## the ore crusher at the quarry to sell it.

const KINDS := {
	"rock": {"name": "boulder", "value": 40, "color": Color(0.5, 0.49, 0.46), "metal": 0.0, "size": 0.75},
	"iron": {"name": "iron ore", "value": 160, "color": Color(0.46, 0.27, 0.19), "metal": 0.2, "size": 0.42},
	"copper": {"name": "copper ore", "value": 280, "color": Color(0.7, 0.42, 0.24), "metal": 0.4, "size": 0.4},
	"silver": {"name": "silver ore", "value": 750, "color": Color(0.78, 0.79, 0.8), "metal": 0.85, "size": 0.36},
	"gold": {"name": "gold ore", "value": 1900, "color": Color(0.95, 0.74, 0.22), "metal": 0.95, "size": 0.32},
	"gem": {"name": "emerald", "value": 3400, "color": Color(0.2, 0.85, 0.45), "metal": 0.1, "size": 0.26},
}
const DIG_PER_ROLL := 2.0  # m3 dug out of a 2 m patch per chance at a find
const MIN_DEPTH := 0.5  # finds start below the topsoil

static var _noise: Dictionary = {}
static var _meshes: Dictionary = {}


static func _field(kind: String) -> FastNoiseLite:
	if not _noise.has(kind):
		var n := FastNoiseLite.new()
		n.seed = {"iron": 11, "copper": 23, "silver": 37, "gold": 41, "gem": 53}[kind]
		n.frequency = 0.012
		n.fractal_octaves = 2
		_noise[kind] = n
	return _noise[kind]


## How rich the ground is in each ore at a point and depth (0..1 chances per roll).
static func richness(main: Node, p: Vector2, depth: float) -> Dictionary:
	var out := {}
	if depth < MIN_DEPTH:
		return out
	var deep := clampf((depth - MIN_DEPTH) / 2.0, 0.0, 1.0)
	var near_quarry := 1.0 - clampf(p.distance_to(main.QUARRY) / 140.0, 0.0, 1.0)
	var hills := 0.0
	for h in main.HILLS:
		hills = maxf(hills, 1.0 - clampf(p.distance_to(Vector2(h.x, h.y)) / (h.z * 1.4), 0.0, 1.0))
	var snow := 1.0 - clampf(p.distance_to(Vector2(main.SNOWFIELD.x, main.SNOWFIELD.y)) / main.SNOWFIELD.z, 0.0, 1.0)
	var water := 1.0 if main.water.depth_at(p.x + 12, p.y) > 0.2 or main.water.depth_at(p.x - 12, p.y) > 0.2 \
			or main.water.depth_at(p.x, p.y + 12) > 0.2 or main.water.depth_at(p.x, p.y - 12) > 0.2 else 0.0
	var f := func(kind: String) -> float: return clampf(_field(kind).get_noise_2d(p.x, p.y) * 0.5 + 0.5, 0.0, 1.0)
	out.iron = 0.16 * smoothstep(0.45, 0.75, f.call("iron")) + 0.12 * near_quarry
	out.copper = 0.1 * smoothstep(0.55, 0.8, f.call("copper")) + 0.1 * near_quarry
	out.silver = (0.07 * smoothstep(0.55, 0.85, f.call("silver")) + 0.06 * hills) * (0.4 + 0.6 * deep)
	if depth > 1.0:
		out.gold = (0.04 * smoothstep(0.6, 0.9, f.call("gold")) + 0.035 * water + 0.03 * hills) * deep
		out.gem = (0.03 * smoothstep(0.7, 0.92, f.call("gem")) * (hills + snow)) * deep
	return out


## Picks what (if anything) a roll turns up.
static func roll(main: Node, p: Vector2, depth: float, rng: RandomNumberGenerator) -> String:
	var r := rng.randf()
	for kind in ["gem", "gold", "silver", "copper", "iron"]:
		var chance: float = richness(main, p, depth).get(kind, 0.0)
		if r < chance:
			return kind
		r -= chance
	return ""


## A chunk of ore (or a boulder) as a physics body: heavy, worth its value at the crusher.
static func make_chunk(parent: Node, kind: String, xform: Transform3D) -> RigidBody3D:
	var spec: Dictionary = KINDS[kind]
	var size: float = spec.size
	var body := RigidBody3D.new()
	body.mass = 2700.0 * size * size * size * 4.2  # roughly a rock that size
	body.collision_layer = 4
	body.collision_mask = 1 | 2 | 4 | 8 | 32 | 64 | 128
	body.linear_damp = 0.2
	body.angular_damp = 1.0
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = size
	shape.shape = sphere
	body.add_child(shape)
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh(kind)
	body.add_child(visual)
	body.add_to_group("ore")
	body.add_to_group("winchable")
	body.set_meta("label", spec.name)
	body.set_meta("ore", kind)
	body.set_meta("value", int(spec.value))
	body.set_meta("grip", [Vector3.ZERO, Vector3.ZERO])
	parent.add_child(body)
	body.global_transform = xform
	return body


## A lumpy rock, its mineral showing in bright flecks (a gem is one big crystal).
static func _mesh(kind: String) -> ArrayMesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var spec: Dictionary = KINDS[kind]
	var size: float = spec.size
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rock := SphereMesh.new()
	rock.radius = size
	rock.height = size * 1.7
	rock.radial_segments = 9
	rock.rings = 5
	var arrays := rock.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var lumps := FastNoiseLite.new()
	lumps.seed = kind.hash()
	lumps.frequency = 2.0
	for i in verts.size():
		verts[i] *= 1.0 + lumps.get_noise_3dv(verts[i] / maxf(size, 0.01)) * 0.28
	arrays[Mesh.ARRAY_VERTEX] = verts
	var raw := ArrayMesh.new()
	raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	tool.create_from(raw, 0)
	tool.generate_normals()
	var mesh := tool.commit()
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.42, 0.4, 0.38) if kind != "rock" else spec.color
	stone.roughness = 0.95
	if kind == "gem":
		stone.albedo_color = Color(0.36, 0.34, 0.33)
	mesh.surface_set_material(0, stone)
	if kind != "rock":
		# Flecks / crystals of the mineral, poking out of the rock.
		var flecks := SurfaceTool.new()
		flecks.begin(Mesh.PRIMITIVE_TRIANGLES)
		var count := 7 if kind != "gem" else 4
		for k in count:
			var dir := Vector3(sin(k * 2.4) * cos(k * 1.3), cos(k * 1.9) * 0.6, cos(k * 2.4) * cos(k * 1.3)).normalized()
			var bit: PrimitiveMesh = BoxMesh.new() if kind != "gem" else PrismMesh.new()
			var s := size * (0.32 if kind != "gem" else 0.55)
			if bit is BoxMesh:
				(bit as BoxMesh).size = Vector3(s, s * 0.5, s * 0.8)
			else:
				(bit as PrismMesh).size = Vector3(s * 0.6, s * 1.2, s * 0.6)
			flecks.append_from(bit, 0, Transform3D(Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT), dir * size * 0.92))
		flecks.commit(mesh)
		var mineral := StandardMaterial3D.new()
		mineral.albedo_color = spec.color
		mineral.metallic = spec.metal
		mineral.roughness = 0.25 if spec.metal > 0.5 else 0.5
		if kind == "gem":
			mineral.emission_enabled = true
			mineral.emission = spec.color
			mineral.emission_energy_multiplier = 0.6
			mineral.roughness = 0.05
		mesh.surface_set_material(1, mineral)
	_meshes[kind] = mesh
	return mesh
