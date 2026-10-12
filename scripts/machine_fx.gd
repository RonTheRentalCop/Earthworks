extends RefCounted
## Shared particle effects and small mesh helpers for machines: exhaust smoke,
## dust clouds, soil clods and mud spray, plus the track-plate mesh for tracked machines.

const TRACK_SHADER := preload("res://scripts/excavator_model.gd").TRACK_SHADER


## Exhaust stack + smoke at `pos` on `parent`; set amount_ratio for engine load.
static func exhaust(parent: Node3D, pos: Vector3, material: Material) -> GPUParticles3D:
	var stack := CylinderMesh.new()
	stack.top_radius = 0.06
	stack.bottom_radius = 0.07
	stack.height = 0.5
	stack.radial_segments = 8
	var pipe := MeshInstance3D.new()
	pipe.mesh = stack
	pipe.material_override = material
	pipe.position = pos + Vector3(0, 0.25, 0)
	parent.add_child(pipe)
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 12.0
	process.initial_velocity_min = 1.2
	process.initial_velocity_max = 1.8
	process.gravity = Vector3(0.3, 0.6, 0)
	process.damping_min = 0.6
	process.damping_max = 0.9
	process.scale_curve = _curve(0.3, 2.2)
	process.color_ramp = _fade(Color(0.18, 0.18, 0.2, 0.85), Color(0.6, 0.6, 0.62, 0.0))
	var particles := GPUParticles3D.new()
	particles.amount = 40
	particles.lifetime = 2.2
	particles.process_material = process
	particles.draw_pass_1 = _puff(0.16)
	particles.position = pos + Vector3(0, 0.5, 0)
	particles.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 8, 8))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(particles)
	return particles


## World-space dust cloud; move it with global_position and toggle `emitting`.
static func dust(parent: Node3D, color: Color, amount: int) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(1.4, 0.2, 0.4)
	process.direction = Vector3.UP
	process.spread = 70.0
	process.initial_velocity_min = 0.4
	process.initial_velocity_max = 1.2
	process.gravity = Vector3(0.2, 0.15, 0)
	process.damping_min = 0.4
	process.damping_max = 0.8
	process.scale_curve = _curve(0.5, 2.4)
	var start := color
	start.a = 0.5
	var end := color.lightened(0.2)
	end.a = 0.0
	process.color_ramp = _fade(start, end)
	return _world_particles(parent, amount, 1.8, _puff(0.3), process)


## World-space spray of mud or soil clods flung backwards from wheels or tracks.
static func spray(parent: Node3D, color: Color) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.25
	process.direction = Vector3(0, 0.8, 1)
	process.spread = 30.0
	process.initial_velocity_min = 2.0
	process.initial_velocity_max = 4.5
	process.gravity = Vector3(0, -9.8, 0)
	process.scale_min = 0.5
	process.scale_max = 1.4
	process.color = color
	process.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	process.collision_bounce = 0.05
	process.collision_friction = 0.9
	var clod := SphereMesh.new()
	clod.radius = 0.06
	clod.height = 0.1
	clod.radial_segments = 5
	clod.rings = 2
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.4
	clod.material = mat
	return _world_particles(parent, 60, 1.2, clod, process)


## A loop of track shoes around a stadium (front/back circle centres, height, radius),
## drawn with the scrolling track shader. Returns the material so `scroll` can be driven.
static func track(parent: Node3D, x: float, z_front: float, z_back: float, y_center: float,
		radius: float, width: float, color: Color) -> ShaderMaterial:
	var straight := z_back - z_front
	var loop := 2.0 * straight + TAU * radius
	var count := int(loop / 0.21)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var plate := BoxMesh.new()
	plate.size = Vector3(width, 0.07, 0.18)
	var grouser := BoxMesh.new()
	grouser.size = Vector3(width, 0.06, 0.04)
	for k in count:
		var s := k * loop / count
		var pos: Vector2  # (z, y) relative to the loop centre line
		var out: Vector2
		if s < straight:
			pos = Vector2(z_front + s, radius)
			out = Vector2(0, 1)
		elif s < straight + PI * radius:
			var a := (s - straight) / radius
			pos = Vector2(z_back + sin(a) * radius, cos(a) * radius)
			out = Vector2(sin(a), cos(a))
		elif s < 2.0 * straight + PI * radius:
			pos = Vector2(z_back - (s - straight - PI * radius), -radius)
			out = Vector2(0, -1)
		else:
			var a := (s - 2.0 * straight - PI * radius) / radius
			pos = Vector2(z_front - sin(a) * radius, -cos(a) * radius)
			out = Vector2(-sin(a), -cos(a))
		var up := Vector3(0, out.y, out.x)
		var basis := Basis(Vector3.RIGHT, up, Vector3.RIGHT.cross(up))
		var origin := Vector3(x, y_center + pos.y, pos.x)
		tool.append_from(plate, 0, Transform3D(basis, origin))
		tool.append_from(grouser, 0, Transform3D(basis, origin + up * 0.06))
	var shader := Shader.new()
	shader.code = TRACK_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("albedo", color)
	material.set_shader_parameter("z_front", z_front)
	material.set_shader_parameter("z_back", z_back)
	material.set_shader_parameter("y_center", y_center)
	material.set_shader_parameter("radius", radius)
	var mesh := tool.commit()
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.extra_cull_margin = 1.0
	parent.add_child(instance)
	return material


## A trailer deck (or ramp) under point `p`, if any: {"height", "body"}; empty otherwise.
static func deck_below(node: Node3D, p: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(p + Vector3(0, 2.5, 0), p - Vector3(0, 2.0, 0), 128)
	var hit := node.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	return {"height": (hit.position as Vector3).y, "body": hit.collider}


## Height a machine rests on at `p`: the ground, or a trailer deck (or ramp) above it.
static func support(node: Node3D, terrain: Node, p: Vector3) -> float:
	var ground: float = terrain.get_height(p.x, p.z)
	var deck := deck_below(node, p)
	return maxf(ground, float(deck.height)) if not deck.is_empty() else ground


## Notes which trailer (if any) is under the machine's middle, so ride_deck() can carry it.
static func check_deck(node: Node3D, p: Vector3) -> void:
	var body = deck_below(node, p).get("body")
	if body != (node.get_meta("deck") if node.has_meta("deck") else null):
		if body:
			node.set_meta("deck", body)
			node.set_meta("deck_last", (body as Node3D).global_transform)
		elif node.has_meta("deck"):
			node.remove_meta("deck")


## True while the machine sits on a trailer (no mud sinking up there).
static func on_deck(node: Node3D) -> bool:
	return node.has_meta("deck") and is_instance_valid(node.get_meta("deck"))


## Moves the machine with the trailer it's parked on (call before it drives).
static func ride_deck(node: Node3D) -> void:
	if not node.has_meta("deck"):
		return
	var body = node.get_meta("deck")
	if not is_instance_valid(body):
		node.remove_meta("deck")
		return
	var now: Transform3D = (body as Node3D).global_transform
	var moved: Transform3D = now * (node.get_meta("deck_last") as Transform3D).affine_inverse()
	node.global_position = moved * node.global_position
	node.rotate_y(moved.basis.get_euler().y)
	node.set_meta("deck_last", now)


static func _world_particles(parent: Node3D, amount: int, lifetime: float, mesh: Mesh, process: ParticleProcessMaterial) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.process_material = process
	particles.draw_pass_1 = mesh
	particles.emitting = false
	particles.top_level = true
	particles.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(particles)
	return particles


static func _puff(radius: float) -> SphereMesh:
	var puff := SphereMesh.new()
	puff.radius = radius
	puff.height = radius * 1.8
	puff.radial_segments = 7
	puff.rings = 3
	var smoke := StandardMaterial3D.new()
	smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke.vertex_color_use_as_albedo = true
	smoke.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke.cull_mode = BaseMaterial3D.CULL_DISABLED
	puff.material = smoke
	return puff


static func _curve(from: float, to: float) -> CurveTexture:
	var curve := Curve.new()
	curve.max_value = maxf(from, to)
	curve.add_point(Vector2(0, from))
	curve.add_point(Vector2(1, to))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


static func _fade(from: Color, to: Color) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, from)
	gradient.set_color(1, to)
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture
