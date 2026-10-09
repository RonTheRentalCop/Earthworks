extends RefCounted
## Mesh and material helpers for building the vehicles in code: rounded/bevelled boxes,
## side-profile prisms (sloped hoods, cabs, curved blades), cylinders, wheels with tread
## lugs, painted / glass / glowing / hazard-stripe materials, and labels.
## Meshes and materials are cached, so many parts share a few resources.

static var _meshes := {}
static var _materials := {}
static var _hazard: ShaderMaterial
static var _plain: ShaderMaterial
static var _plain_test := StandardMaterial3D.new()

const HAZARD_SHADER := """
shader_type spatial;
// Diagonal yellow/black warning stripes in the part's own space.
varying vec3 local_pos;
void vertex() { local_pos = VERTEX; }
void fragment() {
	float s = fract((local_pos.x + local_pos.y + local_pos.z) * 3.0);
	ALBEDO = s < 0.5 ? vec3(0.95, 0.72, 0.05) : vec3(0.06, 0.06, 0.06);
	ROUGHNESS = 0.55;
}
"""


# --- Materials --------------------------------------------------------------------------

static func paint(color: Color, roughness := 0.42, metallic := 0.15) -> StandardMaterial3D:
	var key := "p%s%.2f%.2f" % [color.to_html(), roughness, metallic]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = roughness
		mat.metallic = metallic
		_materials[key] = mat
	return _materials[key]


static func matte(color: Color) -> StandardMaterial3D:
	return paint(color, 0.9, 0.0)


static func metal(color: Color) -> StandardMaterial3D:
	return paint(color, 0.35, 0.7)


static func glass() -> StandardMaterial3D:
	if not _materials.has("glass"):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.25, 0.35, 0.42, 0.28)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.05
		mat.metallic = 0.3
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials["glass"] = mat
	return _materials["glass"]


static func glow(color: Color, energy := 1.6) -> StandardMaterial3D:
	var key := "g%s%.1f" % [color.to_html(), energy]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = energy
		_materials[key] = mat
	return _materials[key]


static func hazard() -> ShaderMaterial:
	if _hazard == null:
		var shader := Shader.new()
		shader.code = HAZARD_SHADER
		_hazard = ShaderMaterial.new()
		_hazard.shader = shader
	return _hazard


## One material for every plain painted surface: colour, roughness and metalness come
## from each vertex (COLOR, UV2), so parts of any colour merge into a single draw call.
## Lit exactly like a StandardMaterial3D with those settings.
const PLAIN_SHADER := """
shader_type spatial;
void fragment() {
	vec3 c = COLOR.rgb;
	ALBEDO = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
	ROUGHNESS = UV2.x;
	METALLIC = UV2.y;
	SPECULAR = 0.5;
}
"""


static func plain_material() -> ShaderMaterial:
	if _plain == null:
		var shader := Shader.new()
		shader.code = PLAIN_SHADER
		_plain = ShaderMaterial.new()
		_plain.shader = shader
	return _plain


## A StandardMaterial3D that's only a colour, roughness and metalness (no textures,
## transparency, glow or special modes), so it can be baked into plain_material().
static func is_plain(mat: Material) -> bool:
	var m := mat as StandardMaterial3D
	if m == null:
		return false
	var d := _plain_test
	return m.transparency == d.transparency and m.cull_mode == d.cull_mode and m.shading_mode == d.shading_mode \
			and not m.emission_enabled and m.albedo_texture == null and not m.normal_enabled \
			and not m.vertex_color_use_as_albedo and not m.rim_enabled and not m.clearcoat_enabled \
			and not m.ao_enabled and m.metallic_specular == d.metallic_specular and m.billboard_mode == d.billboard_mode \
			and m.diffuse_mode == d.diffuse_mode and m.specular_mode == d.specular_mode and not m.no_depth_test \
			and m.metallic_texture == null and m.roughness_texture == null and not m.heightmap_enabled \
			and not m.backlight_enabled and not m.subsurf_scatter_enabled and not m.refraction_enabled \
			and not m.detail_enabled and not m.use_point_size and m.grow == false and m.albedo_color.a >= 1.0


## One mesh from many [mesh, transform, StandardMaterial3D] parts, every part's material
## written into its vertices for plain_material().
static func plain_mesh(parts: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()
	var indices := PackedInt32Array()
	for part in parts:
		var mesh: Mesh = part[0]
		var xform: Transform3D = part[1]
		var mat: StandardMaterial3D = part[2]
		var normal_basis := xform.basis.inverse().transposed()
		var flip := xform.basis.determinant() < 0.0
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n = arrays[Mesh.ARRAY_NORMAL]
			var idx = arrays[Mesh.ARRAY_INDEX]
			var base := verts.size()
			var c := mat.albedo_color
			var rm := Vector2(mat.roughness, mat.metallic)
			for k in v.size():
				verts.append(xform * v[k])
				normals.append((normal_basis * n[k]).normalized() if n != null and n.size() > k else Vector3.UP)
				colors.append(c)
				uv2.append(rm)
			if idx == null or (idx as PackedInt32Array).is_empty():
				for k in range(0, v.size() - 2, 3):
					if flip:
						indices.append_array([base + k, base + k + 2, base + k + 1])
					else:
						indices.append_array([base + k, base + k + 1, base + k + 2])
			else:
				var ii: PackedInt32Array = idx
				for k in range(0, ii.size() - 2, 3):
					if flip:
						indices.append_array([base + ii[k], base + ii[k + 2], base + ii[k + 1]])
					else:
						indices.append_array([base + ii[k], base + ii[k + 1], base + ii[k + 2]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var out := ArrayMesh.new()
	if not verts.is_empty():
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(0, plain_material())
	return out


## The same mesh in one plain_material() surface, if every surface's material is plain
## (a tree's trunk and foliage then draw in one call); otherwise the mesh unchanged.
static func flatten_plain(mesh: ArrayMesh) -> ArrayMesh:
	var parts := []
	for surface in mesh.get_surface_count():
		var mat := mesh.surface_get_material(surface)
		if not is_plain(mat):
			return mesh
		var single := ArrayMesh.new()
		single.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(surface))
		parts.append([single, Transform3D.IDENTITY, mat])
	return plain_mesh(parts)


# --- Meshes -----------------------------------------------------------------------------

## A box with rounded edges and corners (`segments` steps around each edge).
static func rounded_box(size: Vector3, radius: float, segments := 2) -> ArrayMesh:
	var key := "rb%s%.3f%d" % [size, radius, segments]
	if _meshes.has(key):
		return _meshes[key]
	var half := size * 0.5
	var r := minf(radius, minf(half.x, minf(half.y, half.z)) * 0.95)
	var inner := half - Vector3(r, r, r)
	var axes := [_coords(half.x, inner.x, r, segments), _coords(half.y, inner.y, r, segments), _coords(half.z, inner.z, r, segments)]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis in 3:
		for side in [-1.0, 1.0]:
			var u_axis := (axis + 1) % 3
			var v_axis := (axis + 2) % 3
			var us: PackedFloat32Array = axes[u_axis]
			var vs: PackedFloat32Array = axes[v_axis]
			var grid: Array[PackedVector3Array] = []
			var normals: Array[PackedVector3Array] = []
			for v in vs:
				var row := PackedVector3Array()
				var nrow := PackedVector3Array()
				for u in us:
					var q := Vector3.ZERO
					q[axis] = half[axis] * side
					q[u_axis] = u
					q[v_axis] = v
					var c := q.clamp(-inner, inner)
					var n := (q - c).normalized()
					row.append(c + n * r)
					nrow.append(n)
				grid.append(row)
				normals.append(nrow)
			for j in vs.size() - 1:
				for i in us.size() - 1:
					_quad(tool, grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i],
							normals[j][i], normals[j][i + 1], normals[j + 1][i + 1], normals[j + 1][i])
	var mesh := tool.commit()
	_meshes[key] = mesh
	return mesh


## A side profile (points as (z, y), any winding) extruded `width` along X, centred.
static func prism(profile: PackedVector2Array, width: float) -> ArrayMesh:
	var key := "pr%s%.3f" % [profile, width]
	if _meshes.has(key):
		return _meshes[key]
	var pts := profile
	if _area(pts) < 0.0:
		pts = profile.duplicate()
		pts.reverse()
	var w := width * 0.5
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := Geometry2D.triangulate_polygon(pts)
	for side in [-1.0, 1.0]:
		var n := Vector3(side, 0, 0)
		for t in range(0, tris.size(), 3):
			var a := Vector3(w * side, pts[tris[t]].y, pts[tris[t]].x)
			var b := Vector3(w * side, pts[tris[t + 1]].y, pts[tris[t + 1]].x)
			var c := Vector3(w * side, pts[tris[t + 2]].y, pts[tris[t + 2]].x)
			_tri(tool, a, b, c, n, n, n)
	for k in pts.size():
		var p0 := pts[k]
		var p1 := pts[(k + 1) % pts.size()]
		var edge := p1 - p0
		var n := Vector3(0, -edge.x, edge.y).normalized()  # outward for counter-clockwise (z, y)
		_quad(tool, Vector3(-w, p0.y, p0.x), Vector3(w, p0.y, p0.x), Vector3(w, p1.y, p1.x), Vector3(-w, p1.y, p1.x), n, n, n, n)
	var mesh := tool.commit()
	_meshes[key] = mesh
	return mesh


static func cylinder(radius: float, length: float, segments := 16, top_radius := -1.0) -> CylinderMesh:
	var key := "cy%.3f%.3f%d%.3f" % [radius, length, segments, top_radius]
	if not _meshes.has(key):
		var mesh := CylinderMesh.new()
		mesh.bottom_radius = radius
		mesh.top_radius = radius if top_radius < 0.0 else top_radius
		mesh.height = length
		mesh.radial_segments = segments
		mesh.rings = 1
		_meshes[key] = mesh
	return _meshes[key]


static func sphere(radius: float, segments := 12, hemisphere := false) -> SphereMesh:
	var key := "sp%.3f%d%s" % [radius, segments, hemisphere]
	if not _meshes.has(key):
		var mesh := SphereMesh.new()
		mesh.radius = radius
		mesh.height = radius * (1.0 if hemisphere else 2.0)
		mesh.is_hemisphere = hemisphere
		mesh.radial_segments = segments
		mesh.rings = maxi(segments / 2, 3)
		_meshes[key] = mesh
	return _meshes[key]


# --- Placing parts ----------------------------------------------------------------------

static func add(parent: Node3D, mesh: Mesh, pos: Vector3, material: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.rotation = rot
	instance.material_override = material
	parent.add_child(instance)
	return instance


static func box(parent: Node3D, size: Vector3, pos: Vector3, material: Material, radius := 0.04, rot := Vector3.ZERO) -> MeshInstance3D:
	return add(parent, rounded_box(size, radius, 2 if radius > 0.03 else 1), pos, material, rot)


## A cylinder lying along X (axles, drums, lights, tanks).
static func axle(parent: Node3D, radius: float, length: float, pos: Vector3, material: Material, segments := 16) -> MeshInstance3D:
	return add(parent, cylinder(radius, length, segments), pos, material, Vector3(0, 0, PI * 0.5))


## A beam from a to b (rounded square section).
static func beam(parent: Node3D, a: Vector3, b: Vector3, thickness: float, material: Material) -> MeshInstance3D:
	var instance := add(parent, rounded_box(Vector3(thickness, thickness, a.distance_to(b)), thickness * 0.25), (a + b) * 0.5, material)
	instance.basis = Basis.looking_at(b - a, Vector3.UP if absf((b - a).normalized().y) < 0.95 else Vector3.RIGHT)
	return instance


## A truck wheel facing along X: tyre with tread lugs, painted rim, hub and nuts.
## `outward` is +1 or -1 for which side the hub faces. Duals get a second tyre.
static func wheel(parent: Node3D, radius: float, width: float, rim: Color, outward: float, dual := false) -> Node3D:
	var node := Node3D.new()
	parent.add_child(node)
	var rubber := matte(Color(0.09, 0.09, 0.1))
	var tyres: Array = [0.0] if not dual else [-width * 0.52, width * 0.52]
	for offset in tyres:
		axle(node, radius - 0.04, width, Vector3(offset, 0, 0), rubber, 20)
		for k in 18:
			var angle := TAU * k / 18.0
			var lug := box(node, Vector3(width * 0.42, 0.06, 0.13), Vector3(offset + (width * 0.26 if k % 2 == 0 else -width * 0.26), 0, 0), rubber, 0.02)
			lug.position += Vector3(0, cos(angle), sin(angle)) * (radius - 0.03)
			lug.rotation.x = angle
		axle(node, radius * 0.62, width * 0.4, Vector3(offset + width * 0.32 * outward, 0, 0), paint(rim, 0.5, 0.3), 16)
	var hub_x: float = (tyres[tyres.size() - 1] if outward > 0.0 else tyres[0]) + width * 0.52 * outward
	axle(node, radius * 0.3, 0.08, Vector3(hub_x, 0, 0), metal(Color(0.6, 0.6, 0.62)), 12)
	for k in 6:
		var angle := TAU * k / 6.0
		axle(node, 0.025, 0.06, Vector3(hub_x + 0.03 * outward, cos(angle) * radius * 0.22, sin(angle) * radius * 0.22), metal(Color(0.75, 0.75, 0.75)), 6)
	merge_tree(node)
	return node


# --- Batching ---------------------------------------------------------------------------

## Merges the plain mesh parts directly under each node of the tree into one mesh per
## material (a model built from hundreds of small parts then draws in a handful of calls).
## Moving sub-assemblies keep working, since each node's own children merge separately.
## Skipped: parts that are hidden, have children, have no mesh yet, or have meta "keep".
static func merge_tree(root: Node) -> void:
	for child in root.get_children():
		if not child is MeshInstance3D or child.get_child_count() > 0:
			merge_tree(child)
	_merge_children(root)


static func _merge_children(node: Node) -> void:
	var groups := {}
	var plain: Array = []
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible or mi.get_child_count() > 0 or mi.has_meta("keep"):
			continue
		if mi.mesh.get_surface_count() != 1 or mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			continue
		var mat := mi.material_override if mi.material_override else mi.get_active_material(0)
		if mat == null:
			continue
		if is_plain(mat):
			plain.append(mi)
			continue
		if not groups.has(mat):
			groups[mat] = []
		groups[mat].append(mi)
	if plain.size() >= 2:
		var parts := []
		for mi in plain:
			var m := mi as MeshInstance3D
			parts.append([m.mesh, m.transform, m.material_override if m.material_override else m.get_active_material(0)])
		var merged_plain := MeshInstance3D.new()
		merged_plain.mesh = plain_mesh(parts)
		node.add_child(merged_plain)
		for mi in plain:
			node.remove_child(mi)
			(mi as Node).queue_free()
	elif plain.size() == 1:
		var only := plain[0] as MeshInstance3D
		groups[only.material_override if only.material_override else only.get_active_material(0)] = plain
	for mat in groups:
		var parts: Array = groups[mat]
		if parts.size() < 2:
			continue
		var tool := SurfaceTool.new()
		for mi in parts:
			tool.append_from((mi as MeshInstance3D).mesh, 0, (mi as MeshInstance3D).transform)
		var merged := MeshInstance3D.new()
		merged.mesh = tool.commit()
		merged.material_override = mat
		node.add_child(merged)
		for mi in parts:
			node.remove_child(mi)
			(mi as Node).queue_free()


static func label(parent: Node3D, text: String, pos: Vector3, pixel: float, color: Color, yaw := 0.0) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = 96
	l.pixel_size = pixel
	l.modulate = color
	l.outline_size = 0
	l.double_sided = false
	l.position = pos
	l.rotation.y = yaw
	parent.add_child(l)
	return l


# --- Internals --------------------------------------------------------------------------

static func _coords(h: float, i: float, r: float, segments: int) -> PackedFloat32Array:
	var out := PackedFloat32Array([-h])
	for k in range(1, segments):
		out.append(-i - r * (1.0 - float(k) / segments))
	out.append(-i)
	if i > 0.0005:
		out.append(i)
	for k in range(1, segments):
		out.append(i + r * float(k) / segments)
	out.append(h)
	return out


static func _quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
	_tri(tool, a, b, c, na, nb, nc)
	_tri(tool, a, c, d, na, nc, nd)


## Adds a triangle wound so it faces the way its normals point (Godot front = clockwise).
static func _tri(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	if (b - a).cross(c - a).length_squared() < 1e-12:
		return
	var face := (a - c).cross(a - b)
	if face.dot(na + nb + nc) < 0.0:
		var t := b
		b = c
		c = t
		var tn := nb
		nb = nc
		nc = tn
	tool.set_normal(na)
	tool.add_vertex(a)
	tool.set_normal(nb)
	tool.add_vertex(b)
	tool.set_normal(nc)
	tool.add_vertex(c)


static func _area(pts: PackedVector2Array) -> float:
	var total := 0.0
	for k in pts.size():
		var p0 := pts[k]
		var p1 := pts[(k + 1) % pts.size()]
		total += p0.x * p1.y - p1.x * p0.y
	return total * 0.5
