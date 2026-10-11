extends CharacterBody3D
## On-foot construction worker. Walks (or runs, Shift / L3) relative to the camera, jumps,
## and climbs in and out of machines (main.gd handles the switch). Movement eases in and
## out, the body leans into it and the walk cycle bends knees and elbows; physics
## interpolation (project settings) keeps it smooth on high-refresh screens.
## Built from model-kit parts until a character model is supplied.

const Kit = preload("res://scripts/model_kit.gd")

const WALK_SPEED := 3.6
const RUN_SPEED := 6.6
const SPEED := WALK_SPEED  # kept for older callers
const ACCELERATION := 13.0
const DECELERATION := 18.0
const AIR_CONTROL := 3.5
const TURN_SPEED := 10.0
const JUMP_VELOCITY := 4.6
const GRAVITY := 12.0
const COYOTE_TIME := 0.12  # can still jump just after walking off an edge...
const JUMP_BUFFER := 0.12  # ...or just before landing
const STRIDE := 1.35  # metres per full walk cycle
const PLAYER_LAYER := 16

const HI_VIS := Color(1.0, 0.45, 0.05)
const STRIPE := Color(0.88, 0.88, 0.84)
const TROUSERS := Color(0.2, 0.26, 0.38)
const BOOTS := Color(0.3, 0.19, 0.1)
const SKIN := Color(0.87, 0.67, 0.52)
const HELMET := Color(1.0, 0.83, 0.1)
const SHIRT := Color(0.22, 0.28, 0.36)

var camera: Camera3D
## The ground, to keep the worker on top of it (set by main).
var terrain: Node3D
var active := true
## Multiplayer: another player's worker, moved by the network.
var puppet := false
var _net_pos := Vector3.ZERO
var _net_yaw := 0.0
var _net_speed := 0.0
var _net_has := false
var _name_tag: Label3D

var _model: Node3D
var _body: Node3D  # bobs and leans (inside the model, which turns)
var _torso: Node3D
var _head: Node3D
var _legs: Array[Node3D] = []  # hip pivots
var _knees: Array[Node3D] = []
var _arms: Array[Node3D] = []  # shoulder pivots
var _elbows: Array[Node3D] = []
var _walk_phase := 0.0
var _stride := 0.0  # 0 standing .. 1 full walk .. 1.8 running
var _lean := 0.0
var _time := 0.0
var _coyote := 0.0
var _jump_buffer := 0.0
var _seated := false
var _last_velocity := Vector3.ZERO
static var _capsules := {}


func _ready() -> void:
	collision_layer = PLAYER_LAYER
	collision_mask = 1 | 2 | 4 | 8
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true
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
	_seated = true
	_body.position = Vector3.ZERO
	_body.rotation = Vector3.ZERO
	for k in 2:
		_legs[k].rotation = Vector3(1.45, 0.0, 0.0)
		_knees[k].rotation = Vector3(-1.5, 0.0, 0.0)
	set_controls(Vector4.ZERO)


func stand() -> void:
	_model.reparent(self, false)
	_model.transform = Transform3D.IDENTITY
	_seated = false
	for limb in _legs + _arms + _knees + _elbows:
		limb.rotation = Vector3.ZERO


## Moves the seated worker's hands with the machine's controls (swing, boom, stick, bucket).
func set_controls(c: Vector4) -> void:
	_arms[0].rotation = Vector3(0.9 + c.y * 0.3, 0.0, -c.x * 0.25)
	_arms[1].rotation = Vector3(0.9 + c.z * 0.3, 0.0, -c.w * 0.25)
	for e in _elbows:
		e.rotation.x = 0.7


func set_body_visible(value: bool) -> void:
	_model.visible = value


func set_active(value: bool) -> void:
	active = value
	visible = value
	velocity = Vector3.ZERO
	if puppet:
		if _name_tag:
			_name_tag.visible = value
		return
	collision_layer = PLAYER_LAYER if value else 0
	collision_mask = (1 | 2 | 4 | 8) if value else 0


## Which way the worker faces (world yaw): the body turns inside the node.
func facing_yaw() -> float:
	return global_rotation.y + _model.rotation.y


## Multiplayer state: [position, facing, walking speed].
func net_state() -> Array:
	return [global_position, _model.rotation.y, Vector2(velocity.x, velocity.z).length()]


func make_puppet(player_name: String, color: Color) -> void:
	puppet = true
	collision_layer = 0
	collision_mask = 0
	_name_tag = Label3D.new()
	_name_tag.text = player_name
	_name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_tag.font_size = 48
	_name_tag.pixel_size = 0.006
	_name_tag.outline_size = 12
	_name_tag.modulate = color
	_name_tag.position.y = 2.3
	_name_tag.no_depth_test = true
	add_child(_name_tag)


func apply_net_state(s: Array) -> void:
	_net_pos = s[0]
	_net_yaw = s[1]
	_net_speed = s[2]
	if not _net_has:
		_net_has = true
		global_position = _net_pos
		reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	_time += delta
	if puppet:
		if _net_has and active:
			global_position = global_position.lerp(_net_pos, 1.0 - exp(-14.0 * delta))
			_model.rotation.y = lerp_angle(_model.rotation.y, _net_yaw, 1.0 - exp(-14.0 * delta))
			_animate(delta, _net_speed, true, 0.0)
		return
	if not active:
		return
	var input := Input.get_vector("turn_left", "turn_right", "drive_forward", "drive_back")
	var dir := Vector3(input.x, 0.0, input.y).rotated(Vector3.UP, camera.global_rotation.y)
	var running := Input.is_action_pressed("sprint")
	var wanted := dir * (RUN_SPEED if running else WALK_SPEED)
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var grounded := is_on_floor()
	# Ease in, ease out; little control in the air.
	var rate := (ACCELERATION if wanted.length() > flat.length() else DECELERATION) if grounded else AIR_CONTROL
	flat = flat.move_toward(wanted, rate * delta)
	velocity.x = flat.x
	velocity.z = flat.z
	_coyote = COYOTE_TIME if grounded else maxf(_coyote - delta, 0.0)
	_jump_buffer = JUMP_BUFFER if Input.is_action_just_pressed("jump") else maxf(_jump_buffer - delta, 0.0)
	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		_coyote = 0.0
	elif not grounded:
		velocity.y -= GRAVITY * delta
	move_and_slide()
	_stay_on_ground()
	if dir.length() > 0.1:
		_model.rotation.y = lerp_angle(_model.rotation.y, atan2(-dir.x, -dir.z), 1.0 - exp(-TURN_SPEED * delta))
	var accel := (Vector3(velocity.x, 0, velocity.z) - Vector3(_last_velocity.x, 0, _last_velocity.z)) / maxf(delta, 0.001)
	_last_velocity = velocity
	var forward := Vector3(-sin(_model.rotation.y), 0.0, -cos(_model.rotation.y))
	_animate(delta, Vector2(velocity.x, velocity.z).length(), is_on_floor(), accel.dot(forward))


## The ground's collision only holds things up from above and only exists where it's
## been built, so: where it isn't built yet, stand on the ground's height instead of
## dropping; and if the worker ever ends up under the surface (soil dumped on them, a
## glitch), put them straight back on top, right where they are.
func _stay_on_ground() -> void:
	if terrain == null:
		return
	var p := global_position
	var ground: float = terrain.get_height(p.x, p.z)
	if not terrain.has_collision_at(p.x, p.z):
		if p.y < ground + 0.02:
			global_position.y = ground + 0.02
			velocity.y = maxf(velocity.y, 0.0)
	elif p.y < ground - 0.8:
		global_position = Vector3(p.x, ground + 0.3, p.z)
		velocity = Vector3.ZERO
		reset_physics_interpolation()


## Walk / run cycle with bending knees and elbows, a bob, a lean into the stride and
## into speed changes, a jump pose, and a slow breath when standing.
func _animate(delta: float, speed: float, grounded: bool, forward_accel: float) -> void:
	if _seated:
		return
	var target := clampf(speed / WALK_SPEED, 0.0, 1.8)
	_stride = lerpf(_stride, target, 1.0 - exp(-8.0 * delta))
	_walk_phase = fmod(_walk_phase + speed / STRIDE * TAU * delta, TAU)
	var amp := minf(_stride, 1.0)
	var run := clampf(_stride - 1.0, 0.0, 0.8) / 0.8
	var swing := sin(_walk_phase) * (0.5 + 0.35 * run) * amp
	_lean = lerpf(_lean, clampf(forward_accel * 0.012, -0.12, 0.12) + run * 0.18 + amp * 0.04, 1.0 - exp(-6.0 * delta))
	if not grounded:
		for k in 2:
			_legs[k].rotation.x = lerpf(_legs[k].rotation.x, 0.5 if k == 0 else 0.15, 1.0 - exp(-10.0 * delta))
			_knees[k].rotation.x = lerpf(_knees[k].rotation.x, -0.9 if k == 0 else -0.4, 1.0 - exp(-10.0 * delta))
		for k in 2:
			_arms[k].rotation.x = lerpf(_arms[k].rotation.x, -0.5, 1.0 - exp(-8.0 * delta))
			_elbows[k].rotation.x = lerpf(_elbows[k].rotation.x, 0.6, 1.0 - exp(-8.0 * delta))
		_body.position.y = 0.0
	else:
		for k in 2:
			var side := 1.0 if k == 0 else -1.0
			var phase := _walk_phase + (0.0 if k == 0 else PI)
			_legs[k].rotation.x = swing * side
			# The knee bends as the leg swings through, more when running.
			_knees[k].rotation.x = -maxf(0.0, sin(phase + 0.9)) * (0.55 + 0.9 * run) * amp - 0.05 * amp
			_arms[k].rotation.x = -swing * side * (0.9 + 0.4 * run)
			_arms[k].rotation.z = 0.06 * side
			_elbows[k].rotation.x = 0.15 + (0.25 + 1.0 * run) * amp + maxf(0.0, -sin(phase)) * 0.2 * amp
		# Two small bobs per stride; a slow breath when standing still.
		_body.position.y = -absf(sin(_walk_phase)) * (0.035 + 0.04 * run) * amp + sin(_time * 1.6) * 0.006 * (1.0 - amp)
	_body.rotation.x = -_lean
	_torso.rotation.y = sin(_walk_phase) * 0.08 * amp
	_head.rotation.y = -_torso.rotation.y * 0.8


func _build_model() -> void:
	_model = Node3D.new()
	add_child(_model)
	_body = Node3D.new()
	_model.add_child(_body)
	var jacket := Kit.paint(HI_VIS, 0.75, 0.0)
	var stripe := Kit.paint(STRIPE, 0.25, 0.4)
	var trousers := Kit.matte(TROUSERS)
	var boots := Kit.paint(BOOTS, 0.6, 0.0)
	var sole := Kit.matte(Color(0.1, 0.08, 0.06))
	var skin := Kit.paint(SKIN, 0.75, 0.0)
	var shirt := Kit.matte(SHIRT)
	var glove := Kit.paint(Color(0.85, 0.65, 0.25), 0.8, 0.0)
	var hat := Kit.paint(HELMET, 0.3, 0.05)
	var dark := Kit.matte(Color(0.08, 0.08, 0.09))
	# Legs: thigh and shin on hip and knee pivots, work boots with soles and toe caps.
	for side in [-1.0, 1.0]:
		var hip := _pivot(_body, Vector3(0.1 * side, 0.92, 0))
		Kit.add(hip, _capsule(0.085, 0.48), Vector3(0, -0.22, 0), trousers)
		var knee := _pivot(hip, Vector3(0, -0.44, 0))
		Kit.add(knee, _capsule(0.075, 0.46), Vector3(0, -0.2, 0), trousers)
		Kit.box(knee, Vector3(0.13, 0.1, 0.05), Vector3(0, -0.04, -0.07), trousers, 0.03)  # knee pad
		Kit.box(knee, Vector3(0.15, 0.13, 0.27), Vector3(0, -0.4, -0.04), boots, 0.05)
		Kit.box(knee, Vector3(0.16, 0.04, 0.29), Vector3(0, -0.465, -0.045), sole, 0.01)
		Kit.box(knee, Vector3(0.14, 0.06, 0.08), Vector3(0, -0.42, -0.15), Kit.paint(BOOTS.darkened(0.2), 0.5, 0.1), 0.03)
		_legs.append(hip)
		_knees.append(knee)
	_torso = _pivot(_body, Vector3(0, 0.95, 0))
	# Pelvis, belt with a tape measure, torso under a hi-vis jacket with reflective bands.
	Kit.box(_torso, Vector3(0.34, 0.16, 0.2), Vector3(0, 0.0, 0), trousers, 0.06)
	Kit.box(_torso, Vector3(0.36, 0.06, 0.22), Vector3(0, 0.07, 0), dark, 0.02)
	Kit.box(_torso, Vector3(0.08, 0.08, 0.06), Vector3(0.16, 0.05, -0.08), Kit.paint(Color(0.95, 0.75, 0.1)), 0.02)
	# A rounded chest: a capsule squashed front to back, under the jacket.
	var chest := Kit.add(_torso, _capsule(0.2, 0.62), Vector3(0, 0.3, 0), jacket)
	chest.scale = Vector3(1.05, 1.0, 0.68)
	var collar := Kit.add(_torso, Kit.cylinder(0.08, 0.06, 12), Vector3(0, 0.57, 0), shirt)
	collar.scale = Vector3(1.2, 1, 1)
	for y in [0.2, 0.36]:
		var band := Kit.add(_torso, Kit.cylinder(0.205, 0.035, 20), Vector3(0, y, 0), stripe)
		band.scale = Vector3(1.05, 1.0, 0.7)
	for side in [-1.0, 1.0]:
		Kit.box(_torso, Vector3(0.035, 0.4, 0.02), Vector3(side * 0.08, 0.3, -0.135), stripe, 0.01)  # front bands
	Kit.label(_torso, "EARTHWORKS", Vector3(0, 0.42, 0.145), 0.0013, Color(0.1, 0.1, 0.1), 0.0)
	# Arms: shoulder and elbow pivots, sleeves, gloves.
	for side in [-1.0, 1.0]:
		var shoulder := _pivot(_torso, Vector3(0.24 * side, 0.5, 0))
		Kit.add(shoulder, _capsule(0.065, 0.36), Vector3(0, -0.12, 0), jacket)
		var elbow := _pivot(shoulder, Vector3(0, -0.28, 0))
		elbow.rotation.x = 0.15
		Kit.add(elbow, _capsule(0.055, 0.28), Vector3(0, -0.12, 0), shirt)
		Kit.add(elbow, Kit.sphere(0.065, 10), Vector3(0, -0.29, -0.01), glove)
		Kit.box(elbow, Vector3(0.11, 0.06, 0.1), Vector3(0, -0.24, 0), glove, 0.03)  # glove cuff
		_arms.append(shoulder)
		_elbows.append(elbow)
	# Head: neck, face (eyes, brows, nose, ears), safety glasses, hard hat with ridge and brim.
	_head = _pivot(_torso, Vector3(0, 0.56, 0))
	Kit.add(_head, Kit.cylinder(0.055, 0.1, 10), Vector3(0, 0.03, 0), skin)
	Kit.add(_head, Kit.sphere(0.115, 16), Vector3(0, 0.17, 0), skin)
	Kit.box(_head, Vector3(0.17, 0.08, 0.1), Vector3(0, 0.08, -0.03), skin, 0.04)  # jaw
	Kit.box(_head, Vector3(0.035, 0.05, 0.04), Vector3(0, 0.15, -0.115), skin, 0.015)  # nose
	for x in [-1.0, 1.0]:
		Kit.add(_head, Kit.sphere(0.03, 8), Vector3(x * 0.115, 0.16, 0.0), skin)  # ears
		Kit.add(_head, Kit.sphere(0.015, 8), Vector3(x * 0.042, 0.19, -0.1), dark)  # eyes
		Kit.box(_head, Vector3(0.05, 0.012, 0.01), Vector3(x * 0.045, 0.22, -0.105), Kit.matte(Color(0.25, 0.17, 0.1)), 0.0)
	Kit.box(_head, Vector3(0.2, 0.045, 0.02), Vector3(0, 0.19, -0.115), Kit.paint(Color(0.3, 0.4, 0.45, 0.6), 0.05, 0.4), 0.01)  # glasses
	Kit.box(_head, Vector3(0.06, 0.012, 0.01), Vector3(0, 0.12, -0.112), Kit.matte(Color(0.55, 0.3, 0.28)), 0.0)  # mouth
	Kit.add(_head, Kit.sphere(0.135, 16, true), Vector3(0, 0.22, 0.005), hat)
	Kit.add(_head, Kit.cylinder(0.165, 0.02, 20), Vector3(0, 0.225, -0.015), hat)
	Kit.box(_head, Vector3(0.1, 0.03, 0.06), Vector3(0, 0.235, -0.17), Kit.paint(HELMET, 0.3, 0.05), 0.012)  # peak
	# Each limb segment's parts merge into one mesh (they move together), so the worker
	# draws in a handful of calls instead of ~70.
	Kit.merge_tree(_model)


func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = pos
	parent.add_child(node)
	return node


static func _capsule(radius: float, height: float) -> CapsuleMesh:
	var key := Vector2(radius, height)
	if not _capsules.has(key):
		var mesh := CapsuleMesh.new()
		mesh.radius = radius
		mesh.height = height
		mesh.radial_segments = 12
		mesh.rings = 3
		_capsules[key] = mesh
	return _capsules[key]
