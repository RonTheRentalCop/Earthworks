extends RefCounted
## Rig for models/excavator.glb ("Excavator" by MD.Jobair Hossain, CC-BY-4.0, via Sketchfab).
## The model ships with boom + stick as one mesh and every part sharing one origin, so this
## splits triangles into rig parts, hangs them on pivot nodes at the hinge pins and aims the
## hydraulic cylinders between their pins.
## All positions are in the model's imported space: metres, Y up, arm toward -Z.

const PATH := "res://models/excavator.glb"

const OFFSET := Vector3(0, 0.02, -2.0)  # moves the centre of the tracks to the origin
const SWING := Vector3(0, 0.8, 2.0)
const BOOM_PIN := Vector3(0.22, 1.5, 1.72)
const BOOM_APEX := Vector3(0.22, 3.6, -0.4)
const STICK_PIN := Vector3(0.22, 3.76, -3.42)
const STICK_TOP := Vector3(0.22, 4.6, -3.65)
const BUCKET_PIN := Vector3(0.22, 1.0, -3.48)
const TIP := Vector3(0.22, 0.28, -4.66)
const LIP := Vector3(0.22, 0.62, -4.15)
const SHELL: Array[Vector3] = [Vector3(0.22, 0.75, -4.5), Vector3(0.22, 1.15, -4.3)]
const OPENING := Vector3(0, -0.6, 0.8)  # backhoe bucket: the cavity faces the cab
const LOAD_CENTER := Vector3(0.22, 0.8, -4.0)
const DOOR := Vector3(-1.7, 1.0, 1.3)
const LIFT_BASE := Vector3(0.2, 1.32, 1.06)
const LIFT_END := Vector3(0.2, 3.43, -0.03)
const CROWD_BASE := Vector3(0.2, 3.985, -0.7)
const CROWD_END := Vector3(0.2, 4.55, -3.57)
# Bucket four-bar linkage: guide link on the stick, H-link on the bucket, both meeting the
# bucket cylinder's rod at LINK_JOINT.
const LINK_STICK_PIN := Vector3(0.22, 1.445, -3.511)
const LINK_BUCKET_PIN := Vector3(0.22, 1.307, -3.996)
const LINK_JOINT := Vector3(0.22, 1.754, -4.008)
const BUCKET_CYL_BASE := Vector3(0.22, 3.26, -3.99)
# Track loop (side profile is a stadium): end-circle centres, centre height and radius
# through the middle of the shoes.
const TRACK_FRONT_Z := 0.378
const TRACK_BACK_Z := 3.6
const TRACK_CENTER_Y := 0.38
const TRACK_RADIUS := 0.35
const WHEEL_FRONT := Vector3(1.16, 0.335, 0.32)
const WHEEL_BACK := Vector3(1.16, 0.335, 3.65)
const WHEEL_RADIUS := 0.3
const EXHAUST := Vector3(0.75, 2.08, 2.9)
const EYE := Vector3(-0.63, 2.28, 1.42)  # operator's eye in the cab
const SEAT := Vector3(-0.63, 0.65, 1.52)  # operator's feet when sitting on the cushion

const BODY_GROUPS := ["roller_chamber"]
const TRACK_GROUPS := {"trake_shoe_assembly": "left", "trake_shoe_assembly001": "right"}
const WHEEL_GROUPS := {"Object04": "wheel_front", "Object02": "wheel_back"}

const TRACK_SHADER := """
shader_type spatial;
// Moves every vertex of a track around its stadium-shaped loop by `scroll` metres,
// so the shoes really travel over the idlers. Positions are in the machine's space.
uniform vec4 albedo : source_color = vec4(0.2, 0.2, 0.2, 1.0);
uniform float roughness = 0.8;
uniform float metallic = 0.2;
uniform float scroll = 0.0;
uniform float z_front;
uniform float z_back;
uniform float y_center;
uniform float radius;

void vertex() {
	float L = z_back - z_front;
	float half_turn = PI * radius;
	float loop_len = 2.0 * L + 2.0 * half_turn;
	float z = VERTEX.z;
	float y = VERTEX.y - y_center;
	float s; float d; float phi;
	if (z >= z_front && z <= z_back) {
		if (y >= 0.0) { s = z - z_front; d = y - radius; phi = 0.0; }
		else { s = L + half_turn + (z_back - z); d = -y - radius; phi = -PI; }
	} else if (z > z_back) {
		vec2 v = vec2(z - z_back, y);
		float a = atan(v.x, v.y);
		s = L + a * radius; d = length(v) - radius; phi = -a;
	} else {
		vec2 v = vec2(z - z_front, y);
		float a = atan(-v.x, -v.y);
		s = 2.0 * L + half_turn + a * radius; d = length(v) - radius; phi = -PI - a;
	}
	float s2 = mod(s + scroll, loop_len);
	float r = radius + d;
	vec2 p; float phi2;
	if (s2 < L) { p = vec2(z_front + s2, r); phi2 = 0.0; }
	else if (s2 < L + half_turn) { float a = (s2 - L) / radius; p = vec2(z_back + sin(a) * r, cos(a) * r); phi2 = -a; }
	else if (s2 < 2.0 * L + half_turn) { p = vec2(z_back - (s2 - L - half_turn), -r); phi2 = -PI; }
	else { float a = (s2 - 2.0 * L - half_turn) / radius; p = vec2(z_front - sin(a) * r, -cos(a) * r); phi2 = -PI - a; }
	VERTEX.z = p.x;
	VERTEX.y = p.y + y_center;
	float dp = phi2 - phi;
	vec2 n = NORMAL.yz;
	NORMAL.y = n.x * cos(dp) + n.y * sin(dp);
	NORMAL.z = n.y * cos(dp) - n.x * sin(dp);
}

void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
"""


static func build(visual: Node3D) -> Dictionary:
	var model := (load(PATH) as PackedScene).instantiate() as Node3D
	var cab := _pivot(visual, SWING + OFFSET)
	var boom := _pivot(cab, BOOM_PIN - SWING)
	var stick := _pivot(boom, STICK_PIN - BOOM_PIN)
	var bucket := _pivot(stick, BUCKET_PIN - STICK_PIN)
	var lift_barrel := _pivot(cab, LIFT_BASE - SWING)
	var lift_rod := _pivot(boom, LIFT_END - BOOM_PIN)
	var crowd_barrel := _pivot(boom, CROWD_BASE - BOOM_PIN)
	var crowd_rod := _pivot(stick, CROWD_END - STICK_PIN)
	var link_a := _pivot(stick, LINK_STICK_PIN - STICK_PIN)
	var link_b := _pivot(bucket, LINK_BUCKET_PIN - BUCKET_PIN)
	var bucket_barrel := _pivot(stick, BUCKET_CYL_BASE - STICK_PIN)
	var bucket_rod := _pivot(stick, LINK_JOINT - STICK_PIN)
	var wheel_front := _pivot(visual, WHEEL_FRONT + OFFSET)
	var wheel_back := _pivot(visual, WHEEL_BACK + OFFSET)
	var nodes := {
		"body": visual, "cab": cab, "boom": boom, "stick": stick, "bucket": bucket,
		"lift_barrel": lift_barrel, "lift_rod": lift_rod, "crowd_barrel": crowd_barrel, "crowd_rod": crowd_rod,
		"link_a": link_a, "link_b": link_b, "bucket_barrel": bucket_barrel, "bucket_rod": bucket_rod,
		"wheel_front": wheel_front, "wheel_back": wheel_back,
	}
	var points := {
		"body": -OFFSET, "cab": SWING, "boom": BOOM_PIN, "stick": STICK_PIN, "bucket": BUCKET_PIN,
		"lift_barrel": LIFT_BASE, "lift_rod": LIFT_END, "crowd_barrel": CROWD_BASE, "crowd_rod": CROWD_END,
		"link_a": LINK_STICK_PIN, "link_b": LINK_BUCKET_PIN, "bucket_barrel": BUCKET_CYL_BASE,
		"bucket_rod": LINK_JOINT, "wheel_front": WHEEL_FRONT, "wheel_back": WHEEL_BACK,
	}
	var track_materials := {}
	var bucket_verts := PackedVector3Array()
	var bucket_indices := PackedInt32Array()
	var rod_rest := {
		"lift_rod": LIFT_BASE - LIFT_END, "crowd_rod": CROWD_BASE - CROWD_END,
		"bucket_rod": BUCKET_CYL_BASE - LINK_JOINT,
	}
	var extenders := {}
	for rod in rod_rest:
		extenders[rod] = _add_extender(nodes, rod, rod_rest[rod])

	for found in model.find_children("*", "MeshInstance3D", true, false):
		var source := found as MeshInstance3D
		var group := String(source.get_parent().name)
		var xform := _model_xform(source, model)
		var parts := {}
		if group in TRACK_GROUPS:
			var side: String = TRACK_GROUPS[group]
			track_materials[side] = _add_track(visual, source, Transform3D(Basis.IDENTITY, OFFSET) * xform)
			continue
		if group in BODY_GROUPS:
			parts["body"] = source.mesh
		elif group in WHEEL_GROUPS:
			parts[WHEEL_GROUPS[group]] = source.mesh
		elif group == "bucket":
			parts["bucket"] = source.mesh
			_collect(source.mesh, Transform3D(Basis.IDENTITY, -BUCKET_PIN) * xform, bucket_verts, bucket_indices)
		elif group == "bucket_cylinder":
			parts["bucket_rod" if "1280" in String(source.name) else "bucket_barrel"] = source.mesh
		elif group == "bucket_link":
			parts = _split(source, xform, _link_part)
		elif group == "arm" or group == "arm_link":
			parts = _split(source, xform, _arm_part)
		elif group == "boom_cylinder":
			var suffix := "_rod" if "1291" in String(source.name) else "_barrel"
			parts = _split(source, xform, func(p: Vector3) -> String:
				return ("lift" if p.y < 3.7 else "crowd") + suffix)
		else:
			parts["cab"] = source.mesh
		for part in parts:
			var instance := MeshInstance3D.new()
			instance.mesh = parts[part]
			if parts[part] == source.mesh:
				for s in source.mesh.get_surface_count():
					instance.set_surface_override_material(s, source.get_active_material(s))
			instance.transform = Transform3D(Basis.IDENTITY, -(points[part] as Vector3)) * xform
			(nodes[part] as Node3D).add_child(instance)
	model.free()
	for rod in extenders:
		_measure_rod(extenders[rod], rod_rest[rod])

	var block_points: Array[Vector3] = []
	for p in SHELL:
		block_points.append(p - BUCKET_PIN)
	return {
		"cab": cab, "boom": boom, "stick": stick, "bucket": bucket,
		"rest": Vector3.ZERO,
		"boom_limits": Vector2(-0.75, 0.35),
		"stick_limits": Vector2(-1.1, 0.9),
		"bucket_limits": Vector2(-2.0, 0.7),
		"curl_sign": -1.0,
		"carve_points": [TIP - BUCKET_PIN, LIP - BUCKET_PIN],
		"block_points": block_points,
		"opening": OPENING.normalized(),
		"load_center": LOAD_CENTER - BUCKET_PIN,
		"hull": Vector3(3.0, 2.4, 4.0),
		"track": Vector2(2.0, 1.15),
		"door": DOOR - SWING,
		"segments": [
			[boom, Vector3.ZERO, BOOM_APEX - BOOM_PIN, 0.5, 0.6],
			[boom, BOOM_APEX - BOOM_PIN, STICK_PIN - BOOM_PIN, 0.5, 0.6],
			[stick, STICK_TOP - STICK_PIN, BUCKET_PIN - STICK_PIN, 0.4, 0.5],
			[bucket, Vector3(0, -0.05, -0.12), Vector3(0, -0.5, -1.07), 1.2, 0.8],
		],
		"pistons": [
			_piston(lift_barrel, boom, LIFT_END - BOOM_PIN, LIFT_END - LIFT_BASE),
			_piston(lift_rod, cab, LIFT_BASE - SWING, LIFT_BASE - LIFT_END, extenders.lift_rod),
			_piston(crowd_barrel, stick, CROWD_END - STICK_PIN, CROWD_END - CROWD_BASE),
			_piston(crowd_rod, boom, CROWD_BASE - BOOM_PIN, CROWD_BASE - CROWD_END, extenders.crowd_rod),
		],
		"linkage": {
			"stick": stick, "bucket": bucket,
			"a_pin": LINK_STICK_PIN - STICK_PIN, "b_pin": LINK_BUCKET_PIN - BUCKET_PIN,
			"base": BUCKET_CYL_BASE - STICK_PIN, "joint": LINK_JOINT - STICK_PIN,
			"len_a": _yz_distance(LINK_JOINT, LINK_STICK_PIN), "len_b": _yz_distance(LINK_JOINT, LINK_BUCKET_PIN),
			"link_a": link_a, "link_b": link_b, "barrel": bucket_barrel, "rod": bucket_rod,
			"extender": extenders.bucket_rod,
			"rest_a": yz_angle(LINK_JOINT - LINK_STICK_PIN), "rest_b": yz_angle(LINK_JOINT - LINK_BUCKET_PIN),
			"rest_barrel": yz_angle(LINK_JOINT - BUCKET_CYL_BASE), "rest_rod": yz_angle(BUCKET_CYL_BASE - LINK_JOINT),
		},
		"tracks": track_materials,
		"track_loop": 2.0 * (TRACK_BACK_Z - TRACK_FRONT_Z) + TAU * TRACK_RADIUS,
		"wheels": [wheel_front, wheel_back],
		"wheel_radius": WHEEL_RADIUS,
		"exhaust": EXHAUST - SWING,
		"cavity": _cavity(bucket_verts, bucket_indices, OPENING.normalized()),
		"eye": Transform3D(Basis.from_euler(Vector3(-0.16, -0.1, 0)), EYE - SWING),
		"seat": SEAT - SWING,
		"heap": {"radii": Vector2(0.48, 0.36), "base": 0.28, "height": 0.5},
	}


## Poses the bucket four-bar: the joint sits where the guide link (on the stick) and the
## H-link (on the bucket) meet, and the bucket cylinder stretches from its base to the joint.
static func update_linkage(l: Dictionary) -> void:
	var stick: Node3D = l.stick
	var bucket: Node3D = l.bucket
	var a: Vector3 = l.a_pin
	var b := stick.to_local(bucket.to_global(l.b_pin))
	var joint := _circle_intersection(a, l.len_a, b, l.len_b, l.joint)
	l.joint = joint
	var base: Vector3 = l.base
	(l.link_a as Node3D).rotation.x = yz_angle(joint - a) - float(l.rest_a)
	var joint_on_bucket := bucket.to_local(stick.to_global(joint))
	(l.link_b as Node3D).rotation.x = yz_angle(joint_on_bucket - (l.b_pin as Vector3)) - float(l.rest_b)
	(l.barrel as Node3D).rotation.x = yz_angle(joint - base) - float(l.rest_barrel)
	var rod: Node3D = l.rod
	rod.position = joint
	rod.rotation.x = yz_angle(base - joint) - float(l.rest_rod)
	extend_rod(l.extender, joint.distance_to(base))


## Slides a cylinder rod out of its barrel so the ram never shows a gap.
static func extend_rod(extender: Dictionary, distance: float) -> void:
	var stretch := 1.0 + maxf(distance - float(extender.rest_length), 0.0) / float(extender.rod_length)
	(extender.node as Node3D).scale = Vector3(1.0, stretch, 1.0)


## Slices the bucket's own geometry into rings across its cavity (planes facing the
## opening), each resampled to the same number of points, so the soil inside can be
## lofted to fit the bucket exactly.
static func _cavity(verts: PackedVector3Array, indices: PackedInt32Array, u: Vector3) -> Dictionary:
	const LEVELS := 10
	const POINTS := 24
	const SHRINK := 0.045  # stay inside the steel
	var e1 := Vector3.RIGHT
	var e2 := u.cross(e1).normalized()
	var lo := INF
	var hi := -INF
	for v in verts:
		lo = minf(lo, v.dot(u))
		hi = maxf(hi, v.dot(u))
	lo += 0.06
	hi -= 0.05
	var rings: Array[PackedVector2Array] = []
	var depths := PackedFloat32Array()
	for k in LEVELS:
		var d := lerpf(lo, hi, k / float(LEVELS - 1))
		var pts := PackedVector2Array()
		for t in range(0, indices.size(), 3):
			var tri := [verts[indices[t]], verts[indices[t + 1]], verts[indices[t + 2]]]
			for e in 3:
				var a: Vector3 = tri[e]
				var b: Vector3 = tri[(e + 1) % 3]
				var da := a.dot(u) - d
				var db := b.dot(u) - d
				if (da < 0.0) != (db < 0.0):
					var x := a + (b - a) * (da / (da - db))
					pts.append(Vector2(x.dot(e1), x.dot(e2)))
		if pts.size() < 3:
			continue
		var hull := Geometry2D.convex_hull(pts)
		var centre := Vector2.ZERO
		for i in hull.size() - 1:
			centre += hull[i]
		centre /= maxf(hull.size() - 1, 1)
		var ring := PackedVector2Array()
		for j in POINTS:
			var dir := Vector2.from_angle(TAU * j / POINTS)
			var reach := 0.0
			for i in hull.size() - 1:
				var hit = Geometry2D.segment_intersects_segment(centre, centre + dir * 5.0, hull[i], hull[i + 1])
				if hit != null:
					reach = maxf(reach, centre.distance_to(hit))
			ring.append(centre + dir * maxf(reach - SHRINK, 0.02))
		rings.append(ring)
		depths.append(d)
	return {"rings": rings, "depths": depths, "e1": e1, "e2": e2, "u": u}


static func _collect(mesh: Mesh, xform: Transform3D, verts: PackedVector3Array, indices: PackedInt32Array) -> void:
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var base := verts.size()
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for v in vs:
			verts.append(xform * v)
		if arrays[Mesh.ARRAY_INDEX] == null:
			for i in vs.size():
				indices.append(base + i)
		else:
			for i in (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array):
				indices.append(base + i)


## Angle of a vector in the YZ plane: 0 points along -Z, positive tilts up (matches rotation.x).
static func yz_angle(v: Vector3) -> float:
	return atan2(v.y, -v.z)


## Boom/stick share one mesh; everything past the boom-stick pin belongs to the stick.
static func _arm_part(p: Vector3) -> String:
	if p.z < STICK_PIN.z + 0.12 or (p.y < 3.45 and p.z < -3.0):
		return "stick"
	return "boom"


## The bucket_link mesh holds both links plus small hose clips; clips stay on the stick.
static func _link_part(p: Vector3) -> String:
	var to_a := _segment_distance(p, LINK_STICK_PIN, LINK_JOINT)
	var to_b := _segment_distance(p, LINK_JOINT, LINK_BUCKET_PIN)
	if minf(to_a, to_b) > 0.14:
		return "stick"
	return "link_a" if to_a < to_b else "link_b"


static func _segment_distance(p: Vector3, a: Vector3, b: Vector3) -> float:
	var q := Vector2(p.z, p.y)
	var qa := Vector2(a.z, a.y)
	var qb := Vector2(b.z, b.y)
	var t := clampf((q - qa).dot(qb - qa) / (qb - qa).length_squared(), 0.0, 1.0)
	return q.distance_to(qa + (qb - qa) * t)


static func _yz_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.z - b.z, a.y - b.y).length()


## Where two circles in the YZ plane meet, picking the solution nearest `near`.
## If they don't meet (linkage at full stretch) the links lie straight.
static func _circle_intersection(c0: Vector3, r0: float, c1: Vector3, r1: float, near: Vector3) -> Vector3:
	var p0 := Vector2(c0.z, c0.y)
	var p1 := Vector2(c1.z, c1.y)
	var d := p0.distance_to(p1)
	if d < 0.0001:
		return near
	if d > r0 + r1 or d < absf(r0 - r1):
		var q := p0 + (p1 - p0) / d * r0
		return Vector3(near.x, q.y, q.x)
	var along := (r0 * r0 - r1 * r1 + d * d) / (2.0 * d)
	var h := sqrt(maxf(r0 * r0 - along * along, 0.0))
	var mid := p0 + (p1 - p0) * (along / d)
	var perp := Vector2(-(p1.y - p0.y), p1.x - p0.x) / d * h
	var n := Vector2(near.z, near.y)
	var best := mid + perp if (mid + perp).distance_to(n) < (mid - perp).distance_to(n) else mid - perp
	return Vector3(near.x, best.y, best.x)


## Bakes a track mesh into machine space and gives it the scrolling-loop shader.
static func _add_track(visual: Node3D, source: MeshInstance3D, xform: Transform3D) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = TRACK_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	var original := source.get_active_material(0) as BaseMaterial3D
	if original:
		material.set_shader_parameter("albedo", original.albedo_color)
		material.set_shader_parameter("roughness", original.roughness)
		material.set_shader_parameter("metallic", original.metallic)
	material.set_shader_parameter("z_front", TRACK_FRONT_Z + OFFSET.z)
	material.set_shader_parameter("z_back", TRACK_BACK_Z + OFFSET.z)
	material.set_shader_parameter("y_center", TRACK_CENTER_Y + OFFSET.y)
	material.set_shader_parameter("radius", TRACK_RADIUS)
	var mesh := ArrayMesh.new()
	var normal_basis := xform.basis.inverse().transposed()
	for s in source.mesh.get_surface_count():
		var arrays := source.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] = xform * verts[i]
		arrays[Mesh.ARRAY_VERTEX] = verts
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for i in normals.size():
				normals[i] = (normal_basis * normals[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TANGENT] = null
		mesh.add_surface_from_arrays(source.mesh.surface_get_primitive_type(s), arrays)
		mesh.surface_set_material(s, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	# The shader moves vertices, so give culling some slack.
	instance.extra_cull_margin = 1.0
	visual.add_child(instance)
	return material


static func _piston(node: Node3D, target: Node3D, target_local: Vector3, rest_dir: Vector3,
		extender: Dictionary = {}) -> Dictionary:
	return {"node": node, "target": target, "target_local": target_local, "rest": yz_angle(rest_dir),
		"extender": extender}


## Inserts two nodes under a rod pivot: the outer one's Y axis points along the rod, so
## scaling it in Y telescopes the rod; the inner one undoes the rotation for the meshes.
static func _add_extender(nodes: Dictionary, rod: String, rest_dir: Vector3) -> Dictionary:
	var align := Basis(Quaternion(Vector3.UP, rest_dir.normalized()))
	var outer := Node3D.new()
	outer.basis = align
	(nodes[rod] as Node3D).add_child(outer)
	var inner := Node3D.new()
	inner.basis = align.inverse()
	outer.add_child(inner)
	nodes[rod] = inner
	return {"node": outer, "rest_length": rest_dir.length(), "rod_length": 0.3}


## How far the rod meshes reach from their pin toward the barrel.
static func _measure_rod(extender: Dictionary, rest_dir: Vector3) -> void:
	var axis := rest_dir.normalized()
	var reach := 0.05
	var inner := (extender.node as Node3D).get_child(0) as Node3D
	for child in inner.get_children():
		var instance := child as MeshInstance3D
		var box := instance.transform * instance.mesh.get_aabb()
		for i in 8:
			reach = maxf(reach, box.get_endpoint(i).dot(axis))
	extender.rod_length = reach


static func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = pos
	parent.add_child(node)
	return node


static func _model_xform(node: Node3D, root: Node3D) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var current: Node = node
	while current != root:
		xform = (current as Node3D).transform * xform
		current = current.get_parent()
	return xform


## Splits a mesh's triangles into parts using `classify(centroid_in_model_space) -> part name`.
static func _split(source: MeshInstance3D, xform: Transform3D, classify: Callable) -> Dictionary:
	var meshes := {}
	var mesh := source.mesh
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] == null:
			indices.resize(verts.size())
			for i in verts.size():
				indices[i] = i
		else:
			indices = arrays[Mesh.ARRAY_INDEX]
		var lists := {}
		for t in range(0, indices.size(), 3):
			var a := indices[t]
			var b := indices[t + 1]
			var c := indices[t + 2]
			var part: String = classify.call(xform * ((verts[a] + verts[b] + verts[c]) / 3.0))
			if not lists.has(part):
				lists[part] = []
			(lists[part] as Array).append_array([a, b, c])
		for part in lists:
			if not meshes.has(part):
				meshes[part] = ArrayMesh.new()
			var part_arrays := arrays.duplicate()
			part_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(lists[part])
			var out: ArrayMesh = meshes[part]
			out.add_surface_from_arrays(mesh.surface_get_primitive_type(s), part_arrays)
			out.surface_set_material(out.get_surface_count() - 1, source.get_active_material(s))
	return meshes
