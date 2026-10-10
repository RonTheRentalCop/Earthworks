extends StaticBody3D
## A tree that falls when a machine hits it. The trunk topples as a physics log and
## leaves a stump rooted in the ground; the stump blocks machines until enough soil
## is dug from around it, then it breaks loose and can be pushed or scooped away.

signal felled(tree: Node3D)
signal stump_freed(tree: Node3D)
## A loose physics body came off this tree (the felled log, or the torn-out stump).
signal body_spawned(tree: Node3D, body: RigidBody3D, kind: String)

const TREE_LAYER := 32
const DEBRIS_LAYER := 4
const DEBRIS_MASK := 1 | 2 | 4 | 8 | 32 | 64 | 128
const HIT_MASK := 8 | 64  # machine arms/hulls/blades and trucks
const ROOT_DEPTH := 0.4  # how deep you must dig around a stump to free it
const STUMP_HEIGHT := 0.45
const LOG_LENGTH := 4.6  # a felled trunk, per unit of tree size
const LOG_RADIUS := 0.27
const WOOD_DENSITY := 650.0  # kg for a size-1 log; heavier with the cube of size

static var _stump_mesh: ArrayMesh
static var _log_mesh: ArrayMesh

var trunk_mesh: Mesh
var size := 1.0
var is_stump := false
## Stable id in the forest manager, and how much its wood is worth (old giants, swamp cypress).
var tid := -1
var value_mult := 1.0
## Colour of its leaves (they shower off when it falls).
var leaf_color := Color(0.25, 0.45, 0.22)
## Drawn by the forest's batched meshes instead of its own (the node is just the physics).
var pictured := false
var _visual: MeshInstance3D
var _remote := false
var _area: Area3D
var _trunk_shape: CollisionShape3D


func _ready() -> void:
	add_to_group("winchable")
	add_to_group("trees")
	set_meta("label", "tree")
	collision_layer = TREE_LAYER
	collision_mask = 0
	_visual = MeshInstance3D.new()
	_visual.mesh = trunk_mesh
	_visual.scale = Vector3.ONE * size
	_visual.visible = not pictured
	add_child(_visual)
	set_meta("tid", tid)
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.28 * size
	trunk.height = 3.0 * size
	_trunk_shape = CollisionShape3D.new()
	_trunk_shape.shape = trunk
	_trunk_shape.position.y = 1.5 * size
	add_child(_trunk_shape)
	_area = Area3D.new()
	_area.collision_layer = 0
	_area.collision_mask = HIT_MASK
	var reach := CylinderShape3D.new()
	reach.radius = 0.75 * size
	reach.height = 3.2 * size
	var reach_shape := CollisionShape3D.new()
	reach_shape.shape = reach
	reach_shape.position.y = 1.7 * size
	_area.add_child(reach_shape)
	add_child(_area)
	_area.body_entered.connect(_on_hit)


## Multiplayer: on joining players' machines trees only change when the host says so.
func set_remote() -> void:
	_remote = true
	_area.set_deferred("monitoring", false)


func _on_hit(body: Node3D) -> void:
	if not is_stump:
		fell(global_position - body.global_position)
	elif body.has_meta("uproots"):
		pull_out()  # a dozer or excavator shoving on into the stump tears it out


## Topples the tree away from `push`, leaves a stump, and returns the falling log.
func fell(push: Vector3) -> RigidBody3D:
	push.y = 0.0
	if push.length() < 0.01:
		push = Vector3.FORWARD
	push = push.normalized()
	var fallen := make_log(get_parent(), global_transform.translated(Vector3(0, 0.05, 0)), size, trunk_mesh, value_mult)
	# Tip it over (a nudge in proportion to its weight; gravity does the rest), and the
	# crown's leaves shower off as it goes.
	fallen.angular_velocity = Vector3.UP.cross(push) * 0.7
	fallen.linear_velocity = push * 0.4
	if leaf_color.a > 0.0:
		shed_leaves(get_parent(), global_position + Vector3(0, 3.6 * size, 0), size, leaf_color)
	become_stump()
	body_spawned.emit(self, fallen, "log")
	felled.emit(self)
	return fallen


## Turns the standing tree into its stump (also used when a felled tree streams back in).
func become_stump() -> void:
	is_stump = true
	_area.set_deferred("monitoring", false)
	# A moment later the stump watches again: a heavy machine still pushing tears it out.
	if is_inside_tree() and not _remote:
		get_tree().create_timer(0.7).timeout.connect(func() -> void:
			if is_instance_valid(self) and is_stump and not _remote:
				_area.monitoring = true)
	_visual.mesh = stump_mesh()
	_visual.scale = Vector3(size, 1.0, size)
	var stump := CylinderShape3D.new()
	stump.radius = 0.36 * size
	stump.height = STUMP_HEIGHT
	_trunk_shape.shape = stump
	_trunk_shape.position.y = STUMP_HEIGHT * 0.5
	set_meta("label", "stump")


## A felled log as a physics body: the bare trunk (its leaves came off as it fell),
## weighing what a trunk that size would, worth more for big or rare trees.
static func make_log(parent: Node, xform: Transform3D, log_size: float, _mesh: Mesh, mult := 1.0) -> RigidBody3D:
	var fallen := RigidBody3D.new()
	fallen.mass = WOOD_DENSITY * log_size * log_size * log_size
	fallen.collision_layer = DEBRIS_LAYER
	fallen.collision_mask = DEBRIS_MASK
	# Heavy timber settles where it lands instead of bouncing and rolling away.
	fallen.linear_damp = 0.15
	fallen.angular_damp = 0.35
	fallen.physics_material_override = _log_surface()
	var trunk := CylinderShape3D.new()
	trunk.radius = LOG_RADIUS * log_size
	trunk.height = LOG_LENGTH * log_size
	var trunk_shape := CollisionShape3D.new()
	trunk_shape.shape = trunk
	trunk_shape.position.y = (STUMP_HEIGHT + LOG_LENGTH * 0.5) * log_size
	fallen.add_child(trunk_shape)
	var visual := MeshInstance3D.new()
	visual.mesh = log_mesh()
	visual.scale = Vector3.ONE * log_size
	fallen.add_child(visual)
	fallen.add_to_group("winchable")
	fallen.add_to_group("shreddable")
	fallen.set_meta("label", "log" if mult < 1.5 else "prized log")
	fallen.set_meta("value", int((140.0 + 180.0 * log_size) * mult))
	# Where a grapple can take hold: anywhere along the trunk (local end points).
	fallen.set_meta("grip", [Vector3(0, STUMP_HEIGHT * log_size, 0), Vector3(0, (STUMP_HEIGHT + LOG_LENGTH) * log_size, 0)])
	parent.add_child(fallen)
	fallen.global_transform = xform
	return fallen


static var _log_material: PhysicsMaterial


static func _log_surface() -> PhysicsMaterial:
	if _log_material == null:
		_log_material = PhysicsMaterial.new()
		_log_material.friction = 0.9
		_log_material.bounce = 0.0
	return _log_material


## A bare trunk: tapered bark with branch stubs and a pale sawn end (unit tree size).
static func log_mesh() -> ArrayMesh:
	if _log_mesh:
		return _log_mesh
	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color(0.36, 0.25, 0.16)
	bark.roughness = 1.0
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.85, 0.68, 0.45)
	wood.roughness = 0.9
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = LOG_RADIUS * 0.45
	trunk.bottom_radius = LOG_RADIUS
	trunk.height = LOG_LENGTH
	trunk.radial_segments = 10
	tool.append_from(trunk, 0, Transform3D(Basis.IDENTITY, Vector3(0, STUMP_HEIGHT + LOG_LENGTH * 0.5, 0)))
	# Snapped-off branches up the top half.
	for k in 6:
		var stub := CylinderMesh.new()
		stub.top_radius = 0.025
		stub.bottom_radius = 0.06
		stub.height = 0.55 - k * 0.04
		stub.radial_segments = 5
		var y := STUMP_HEIGHT + LOG_LENGTH * (0.45 + k * 0.09)
		var around := Basis(Vector3.UP, k * 2.4)
		var out := Basis(Vector3.RIGHT, 0.9)
		tool.append_from(stub, 0, Transform3D(around * out, around * Vector3(0, y, -0.16)))
	var mesh := tool.commit()
	mesh.surface_set_material(0, bark)
	var cut := CylinderMesh.new()
	cut.top_radius = LOG_RADIUS - 0.01
	cut.bottom_radius = LOG_RADIUS - 0.01
	cut.height = 0.02
	cut.radial_segments = 10
	var cap := SurfaceTool.new()
	cap.begin(Mesh.PRIMITIVE_TRIANGLES)
	cap.append_from(cut, 0, Transform3D(Basis.IDENTITY, Vector3(0, STUMP_HEIGHT - 0.005, 0)))
	cap.commit(mesh)
	mesh.surface_set_material(1, wood)
	_log_mesh = mesh
	return mesh


## A one-off shower of leaves from a falling crown, drifting down and settling.
static func shed_leaves(parent: Node, at: Vector3, tree_size: float, color: Color) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var leaves := GPUParticles3D.new()
	leaves.one_shot = true
	leaves.explosiveness = 0.85
	leaves.amount = 90
	leaves.lifetime = 4.5
	leaves.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 1.6 * tree_size
	process.direction = Vector3.UP
	process.spread = 180.0
	process.initial_velocity_min = 0.3
	process.initial_velocity_max = 2.0
	process.gravity = Vector3(0, -1.1, 0)  # leaves flutter down slowly
	process.damping_min = 0.8
	process.damping_max = 1.6
	process.angular_velocity_min = -220.0
	process.angular_velocity_max = 220.0
	process.scale_min = 0.6
	process.scale_max = 1.3
	process.color = color
	leaves.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.1)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.roughness = 0.9
	quad.material = mat
	leaves.draw_pass_1 = quad
	parent.add_child(leaves)
	leaves.global_position = at
	leaves.emitting = true
	leaves.finished.connect(leaves.queue_free)


## A torn-out stump as a physics body.
static func make_stump(parent: Node, xform: Transform3D, stump_size: float, mult := 1.0) -> RigidBody3D:
	var loose := RigidBody3D.new()
	loose.mass = 120.0 * stump_size
	loose.collision_layer = DEBRIS_LAYER
	loose.collision_mask = DEBRIS_MASK
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.36 * stump_size
	cyl.height = STUMP_HEIGHT
	shape.shape = cyl
	shape.position.y = STUMP_HEIGHT * 0.5
	loose.add_child(shape)
	var visual := MeshInstance3D.new()
	visual.mesh = stump_mesh()
	visual.scale = Vector3(stump_size, 1.0, stump_size)
	loose.add_child(visual)
	loose.add_to_group("winchable")
	loose.add_to_group("shreddable")
	loose.set_meta("label", "stump")
	loose.set_meta("value", int((80.0 + 90.0 * stump_size) * mult))
	loose.set_meta("grip", [shape.position, shape.position])
	parent.add_child(loose)
	loose.global_transform = xform
	return loose


## Frees the stump once the ground around its roots has been dug out.
func check_roots(terrain: Node) -> void:
	if not is_stump or not is_inside_tree():
		return
	var p := global_position
	var total := 0.0
	for offset in [Vector2.ZERO, Vector2(0.7, 0), Vector2(-0.7, 0), Vector2(0, 0.7), Vector2(0, -0.7)]:
		total += float(terrain.call("dug_depth", p.x + offset.x, p.z + offset.y))
	if total / 5.0 < ROOT_DEPTH:
		return
	pull_out()


## Tears the stump out of the ground (a grapple can do this without digging) and returns it.
func pull_out() -> RigidBody3D:
	var loose := make_stump(get_parent(), global_transform.translated(Vector3(0, 0.15, 0)), size, value_mult)
	loose.apply_central_impulse(Vector3(0, 300.0, 0))
	body_spawned.emit(self, loose, "stump")
	stump_freed.emit(self)
	queue_free()
	return loose


## A cut stump with root flares and pale growth rings on top.
static func stump_mesh() -> ArrayMesh:
	if _stump_mesh:
		return _stump_mesh
	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color(0.38, 0.25, 0.15)
	bark.roughness = 1.0
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.85, 0.68, 0.45)
	wood.roughness = 0.9
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.3
	trunk.bottom_radius = 0.38
	trunk.height = STUMP_HEIGHT
	trunk.radial_segments = 10
	tool.append_from(trunk, 0, Transform3D(Basis.IDENTITY, Vector3(0, STUMP_HEIGHT * 0.5, 0)))
	for k in 5:
		var root := CylinderMesh.new()
		root.top_radius = 0.02
		root.bottom_radius = 0.13
		root.height = 0.7
		root.radial_segments = 6
		var dir := Basis(Vector3.UP, TAU * k / 5.0 + 0.3)
		var tilt := Basis(Vector3.RIGHT, 1.25)
		tool.append_from(root, 0, Transform3D(dir * tilt, dir * Vector3(0, 0.08, -0.38)))
	var mesh := tool.commit()
	mesh.surface_set_material(0, bark)
	var top := CylinderMesh.new()
	top.top_radius = 0.29
	top.bottom_radius = 0.29
	top.height = 0.02
	top.radial_segments = 10
	var cap := SurfaceTool.new()
	cap.begin(Mesh.PRIMITIVE_TRIANGLES)
	cap.append_from(top, 0, Transform3D(Basis.IDENTITY, Vector3(0, STUMP_HEIGHT, 0)))
	cap.commit(mesh)
	mesh.surface_set_material(1, wood)
	_stump_mesh = mesh
	return mesh
