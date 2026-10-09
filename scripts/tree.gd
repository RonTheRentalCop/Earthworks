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

static var _stump_mesh: ArrayMesh

var trunk_mesh: Mesh
var size := 1.0
var is_stump := false
## Stable id in the forest manager, and how much its wood is worth (old giants, swamp cypress).
var tid := -1
var value_mult := 1.0
## Drawn by the forest's batched meshes instead of its own (the node is just the physics).
var pictured := false
var _visual: MeshInstance3D
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
	_area.set_deferred("monitoring", false)


func _on_hit(body: Node3D) -> void:
	if not is_stump:
		fell(global_position - body.global_position)


## Topples the tree away from `push`, leaves a stump, and returns the falling log.
func fell(push: Vector3) -> RigidBody3D:
	push.y = 0.0
	if push.length() < 0.01:
		push = Vector3.FORWARD
	push = push.normalized()
	var fallen := make_log(get_parent(), global_transform.translated(Vector3(0, 0.05, 0)), size, trunk_mesh, value_mult)
	# Tip it over: spin about the horizontal axis perpendicular to the push.
	fallen.apply_torque_impulse(Vector3.UP.cross(push) * 900.0 * size)
	fallen.apply_central_impulse(push * 400.0 * size)
	become_stump()
	body_spawned.emit(self, fallen, "log")
	felled.emit(self)
	return fallen


## Turns the standing tree into its stump (also used when a felled tree streams back in).
func become_stump() -> void:
	is_stump = true
	_area.set_deferred("monitoring", false)
	_visual.mesh = stump_mesh()
	_visual.scale = Vector3(size, 1.0, size)
	var stump := CylinderShape3D.new()
	stump.radius = 0.36 * size
	stump.height = STUMP_HEIGHT
	_trunk_shape.shape = stump
	_trunk_shape.position.y = STUMP_HEIGHT * 0.5
	set_meta("label", "stump")


## A felled log as a physics body (whole trunk and crown), worth more for big or rare trees.
static func make_log(parent: Node, xform: Transform3D, log_size: float, mesh: Mesh, mult := 1.0) -> RigidBody3D:
	var fallen := RigidBody3D.new()
	fallen.mass = 350.0 * log_size
	fallen.collision_layer = DEBRIS_LAYER
	fallen.collision_mask = DEBRIS_MASK
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.28 * log_size
	trunk.height = 3.6 * log_size
	var trunk_shape := CollisionShape3D.new()
	trunk_shape.shape = trunk
	trunk_shape.position.y = (STUMP_HEIGHT + 1.8) * log_size
	fallen.add_child(trunk_shape)
	var crown := SphereShape3D.new()
	crown.radius = 1.2 * log_size
	var crown_shape := CollisionShape3D.new()
	crown_shape.shape = crown
	crown_shape.position.y = 3.6 * log_size
	fallen.add_child(crown_shape)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.scale = Vector3.ONE * log_size
	fallen.add_child(visual)
	fallen.add_to_group("winchable")
	fallen.add_to_group("shreddable")
	fallen.set_meta("label", "log" if mult < 1.5 else "prized log")
	fallen.set_meta("value", int((140.0 + 180.0 * log_size) * mult))
	# Where a grapple can take hold: anywhere along the trunk (local end points).
	fallen.set_meta("grip", [Vector3(0, STUMP_HEIGHT * log_size, 0), Vector3(0, (STUMP_HEIGHT + 3.6) * log_size, 0)])
	parent.add_child(fallen)
	fallen.global_transform = xform
	return fallen


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
