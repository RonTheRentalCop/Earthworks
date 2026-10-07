extends CharacterBody3D
## On-foot construction worker. Walks relative to the camera, jumps, and climbs in
## and out of machines (main.gd handles the switch). Built from model-kit parts until
## a character model is supplied.

const Kit = preload("res://scripts/model_kit.gd")

const SPEED := 4.0
const ACCELERATION := 25.0
const JUMP_VELOCITY := 4.5
const GRAVITY := 12.0
const PLAYER_LAYER := 16

const HI_VIS := Color(1.0, 0.45, 0.05)
const STRIPE := Color(0.85, 0.85, 0.8)
const JEANS := Color(0.2, 0.28, 0.45)
const BOOTS := Color(0.22, 0.15, 0.1)
const SKIN := Color(0.87, 0.67, 0.52)
const HELMET := Color(1.0, 0.85, 0.1)

var camera: Camera3D
var active := true

var _model: Node3D
var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []
var _walk_phase := 0.0
var _materials := {}


func _ready() -> void:
	collision_layer = PLAYER_LAYER
	collision_mask = 1 | 2 | 4 | 8
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(50.0)
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)
	_build_model()


## Sits the worker's body in a machine seat (the controller stays behind, inactive).
func sit(seat: Node3D) -> void:
	_model.reparent(seat, false)
	# Stay life-size even in a scaled-up machine.
	var machine_scale := seat.global_basis.get_scale().x
	_model.transform = Transform3D.IDENTITY.scaled(Vector3.ONE / machine_scale)
	_model.position.y = 0.88 * (1.0 - 1.0 / machine_scale)  # hips on the (scaled) cushion
	for leg in _legs:
		leg.rotation.x = 1.45
	set_controls(Vector4.ZERO)


func stand() -> void:
	_model.reparent(self, false)
	_model.transform = Transform3D.IDENTITY
	for limb in _legs + _arms:
		limb.rotation = Vector3.ZERO


## Moves the seated worker's hands with the machine's controls (swing, boom, stick, bucket).
func set_controls(c: Vector4) -> void:
	_arms[0].rotation = Vector3(1.0 + c.y * 0.3, 0.0, -c.x * 0.25)
	_arms[1].rotation = Vector3(1.0 + c.z * 0.3, 0.0, -c.w * 0.25)


func set_body_visible(value: bool) -> void:
	_model.visible = value


func set_active(value: bool) -> void:
	active = value
	visible = value
	velocity = Vector3.ZERO
	collision_layer = PLAYER_LAYER if value else 0
	collision_mask = (1 | 2 | 4 | 8) if value else 0


func _physics_process(delta: float) -> void:
	if not active:
		return
	var input := Input.get_vector("turn_left", "turn_right", "drive_forward", "drive_back")
	var dir := Vector3(input.x, 0.0, input.y).rotated(Vector3.UP, camera.global_rotation.y)
	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			velocity.y = JUMP_VELOCITY
	else:
		velocity.y -= GRAVITY * delta
	velocity.x = move_toward(velocity.x, dir.x * SPEED, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, dir.z * SPEED, ACCELERATION * delta)
	move_and_slide()
	if global_position.y < -30.0:
		global_position = Vector3(0, 10, 0)
		velocity = Vector3.ZERO
	_animate(delta, dir)


func _animate(delta: float, dir: Vector3) -> void:
	if dir.length() > 0.1:
		_model.rotation.y = lerp_angle(_model.rotation.y, atan2(-dir.x, -dir.z), 1.0 - exp(-12.0 * delta))
	var speed := Vector2(velocity.x, velocity.z).length()
	_walk_phase += speed * delta * 2.6
	var swing := sin(_walk_phase) * clampf(speed / SPEED, 0.0, 1.0) * 0.7
	if not is_on_floor():
		swing = 0.4
	_legs[0].rotation.x = swing
	_legs[1].rotation.x = -swing
	_arms[0].rotation.x = -swing * 0.8
	_arms[1].rotation.x = swing * 0.8


func _build_model() -> void:
	_model = Node3D.new()
	add_child(_model)
	var vest := Kit.paint(HI_VIS, 0.7, 0.0)
	var stripe := Kit.paint(STRIPE, 0.25, 0.4)
	var jeans := Kit.matte(JEANS)
	var boots := Kit.matte(BOOTS)
	var skin := Kit.matte(SKIN)
	var shirt := Kit.matte(Color(0.25, 0.3, 0.38))
	for side in [-1.0, 1.0]:
		var hip := _pivot(Vector3(0.12 * side, 0.9, 0))
		Kit.box(hip, Vector3(0.18, 0.46, 0.2), Vector3(0, -0.22, 0), jeans, 0.06)
		Kit.box(hip, Vector3(0.16, 0.36, 0.18), Vector3(0, -0.6, 0.01), jeans, 0.06)
		Kit.box(hip, Vector3(0.18, 0.13, 0.3), Vector3(0, -0.83, -0.04), boots, 0.05)
		Kit.box(hip, Vector3(0.19, 0.04, 0.31), Vector3(0, -0.885, -0.04), Kit.matte(Color(0.1, 0.08, 0.06)), 0.01)
		_legs.append(hip)
		var shoulder := _pivot(Vector3(0.31 * side, 1.47, 0))
		Kit.box(shoulder, Vector3(0.14, 0.32, 0.15), Vector3(0, -0.15, 0), shirt, 0.06)
		Kit.box(shoulder, Vector3(0.12, 0.28, 0.13), Vector3(0, -0.44, 0), shirt, 0.05)
		Kit.box(shoulder, Vector3(0.11, 0.12, 0.12), Vector3(0, -0.63, 0), Kit.matte(Color(0.75, 0.6, 0.2)), 0.04)  # gloves
		_arms.append(shoulder)
	# Torso: shirt under a two-tone hi-vis vest with reflective bands; belt.
	Kit.box(_model, Vector3(0.48, 0.62, 0.26), Vector3(0, 1.21, 0), shirt, 0.08)
	Kit.box(_model, Vector3(0.5, 0.5, 0.28), Vector3(0, 1.24, 0), vest, 0.08)
	for y in [1.12, 1.3]:
		Kit.box(_model, Vector3(0.51, 0.045, 0.29), Vector3(0, y, 0), stripe, 0.02)
	Kit.box(_model, Vector3(0.5, 0.07, 0.27), Vector3(0, 0.92, 0), Kit.matte(Color(0.15, 0.1, 0.06)), 0.03)
	Kit.box(_model, Vector3(0.12, 0.08, 0.04), Vector3(0, 0.92, -0.14), Kit.metal(Color(0.7, 0.7, 0.7)), 0.01)
	# Head: neck, face, eyes, safety glasses, hard hat with brim.
	Kit.add(_model, Kit.cylinder(0.07, 0.1, 10), Vector3(0, 1.56, 0), skin)
	Kit.box(_model, Vector3(0.26, 0.28, 0.26), Vector3(0, 1.72, 0), skin, 0.1)
	for x in [-0.06, 0.06]:
		Kit.box(_model, Vector3(0.04, 0.03, 0.02), Vector3(x, 1.74, -0.13), Kit.matte(Color(0.1, 0.1, 0.1)), 0.0)
	Kit.box(_model, Vector3(0.24, 0.05, 0.03), Vector3(0, 1.75, -0.135), Kit.paint(Color(0.2, 0.25, 0.3, 0.7), 0.1, 0.3), 0.01)
	Kit.add(_model, Kit.sphere(0.16, 14, true), Vector3(0, 1.82, 0), Kit.paint(HELMET, 0.35, 0.05))
	Kit.add(_model, Kit.cylinder(0.2, 0.025, 16), Vector3(0, 1.82, -0.02), Kit.paint(HELMET, 0.35, 0.05))
	Kit.box(_model, Vector3(0.03, 0.03, 0.3), Vector3(0, 1.97, 0), Kit.paint(HELMET.darkened(0.1), 0.35, 0.05), 0.01)


func _pivot(pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = pos
	_model.add_child(node)
	return node


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_mesh(parent, mesh, pos, color)


func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> void:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.9
		_materials[color] = mat
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.material_override = _materials[color]
	parent.add_child(instance)
