extends VehicleBody3D
## Lowboy equipment trailer: a four-wheel drawbar trailer with a low deck and a pair of
## hydraulic loading ramps at the back. Lower the ramps (walk up to the back, F / X) and
## tracked machines can drive up and ride on the deck (machines look for the "trailer
## deck" layer under their tracks and move with it); raise them for the road and they
## stand up like a tailgate. Hitch it to a truck (T / L3 near its drawbar); it brakes
## itself when unhitched.
## VehicleBody3D faces +Z, so the model is built facing -Z under a node turned 180°.

const Kit = preload("res://scripts/model_kit.gd")

const TRAILER_LAYER := 128
const TRAILER_MASK := 1 | 4 | 32 | 64 | 128
const DECK_HEIGHT := 1.0
const DECK_LENGTH := 9.0
const DECK_WIDTH := 3.0
const HITCH := Vector3(0, 0.85, -6.4)  # drawbar eye, model space (front)
const RAMP_LENGTH := 2.6
const RAMP_RATE := 0.7  # rad/s
const RAMP_UP := -1.42  # ramp angle when raised (standing up behind the deck)

const BODY := Color(0.78, 0.12, 0.1)
const FRAME := Color(0.18, 0.18, 0.2)
const DECK := Color(0.5, 0.37, 0.24)
const STEEL := Color(0.55, 0.56, 0.58)

var machine_name := "Lowboy trailer"
## True builds only the model (shop thumbnails).
var preview := false
## Multiplayer: a copy on a joining player's machine that follows the host.
var puppet := false
var _net_xform := Transform3D()
var _net_has := false
var _net_ramp := 0.0
var _net_speed := 0.0
var _wheel_spin := 0.0
var _wheels: Array[VehicleWheel3D] = []
var _wheel_rest: Array[Vector3] = []
var towed_by: Node3D
var ramps_down := true
var _joint: PinJoint3D
var _model: Node3D
var _ramp: Node3D
var _ramp_shape: CollisionShape3D
var _ramp_down_angle := 0.0
var _front_wheels: Array[VehicleWheel3D] = []


func _ready() -> void:
	mass = 5500.0
	collision_layer = TRAILER_LAYER
	collision_mask = TRAILER_MASK
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.6, 0)
	can_sleep = false
	add_to_group("winchable")
	set_meta("label", "trailer")
	_model = Node3D.new()
	_model.rotation.y = PI
	add_child(_model)
	_build()
	for w in [[-1.15, -3.6, true], [1.15, -3.6, true], [-1.15, 2.6, false], [1.15, 2.6, false], [-1.15, 3.7, false], [1.15, 3.7, false]]:
		_add_wheel(Vector3(w[0], 0.85, -(w[1] as float)), w[2], w[0] > 0.0)
	Kit.merge_tree(_model)
	if preview:
		freeze = true
		set_physics_process(false)
		return
	add_to_group("trailers")


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	brake = 0.0 if towed_by else 60.0
	if towed_by and is_instance_valid(towed_by):
		# Front axle follows the drawbar.
		var to_hitch := global_transform.affine_inverse() * towed_by.global_position
		var angle := clampf(atan2(to_hitch.x, to_hitch.z), -0.6, 0.6)
		for w in _front_wheels:
			w.steering = angle
	var target := _ramp_down_angle if ramps_down else RAMP_UP
	_ramp.rotation.x = move_toward(_ramp.rotation.x, target, RAMP_RATE * delta)
	_ramp_shape.transform = _model.transform * _ramp.transform * Transform3D(Basis.IDENTITY, Vector3(0, 0.0, RAMP_LENGTH * 0.5))


## Multiplayer state (host -> joining players).
func net_state() -> Array:
	return [_ramp.rotation.x, linear_velocity.dot(global_basis.z), ramps_down]


func make_puppet() -> void:
	puppet = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	for w in _wheels:
		_wheel_rest.append(w.position - Vector3(0, 0.2, 0))


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_net_ramp = s[0]
	_net_speed = s[1]
	ramps_down = s[2]


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	_ramp.rotation.x = lerpf(_ramp.rotation.x, _net_ramp, t)
	_ramp_shape.transform = _model.transform * _ramp.transform * Transform3D(Basis.IDENTITY, Vector3(0, 0.0, RAMP_LENGTH * 0.5))
	_wheel_spin += _net_speed / 0.42 * delta
	for k in _wheels.size():
		_wheels[k].position = _wheel_rest[k]
		_wheels[k].basis = Basis(Vector3.RIGHT, _wheel_spin)


## Drawbar eye in world space.
func hitch_point() -> Vector3:
	return _model.to_global(HITCH)


## Where you stand to work the ramps.
func ramp_point() -> Vector3:
	return _ramp.global_position


func toggle_ramps() -> void:
	ramps_down = not ramps_down


## Lines the trailer up behind a truck with its drawbar eye on `hitch`.
func place_behind(hitch: Vector3, truck_basis: Basis) -> void:
	global_transform = Transform3D(truck_basis.orthonormalized(), global_position)
	global_position += hitch - hitch_point()
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func deck_centre() -> Vector3:
	return _model.to_global(Vector3(0, DECK_HEIGHT + 0.05, 0.5))


func tow_point(_from: Vector3) -> Vector3:
	return hitch_point()


func hitch(truck: RigidBody3D, truck_point: Vector3) -> void:
	# Tip the trailer about its rear axle so the drawbar eye comes to the hitch's height
	# (the rear wheels stay on the ground), slide it onto the hitch, then pin them together.
	var pivot := _model.to_global(Vector3(0, 0.4, 3.15))
	for _step in 4:
		var dy := truck_point.y - hitch_point().y
		var arm := hitch_point() - pivot
		var reach := Vector2(arm.x, arm.z).length()
		if absf(dy) < 0.005 or reach < 0.5:
			break
		var angle := dy / reach
		var axis := global_basis.x.normalized()
		# Rotating about +X raises the -Z end; the eye is at the model's -Z, the body's +Z.
		var turned := Transform3D(Basis(axis, -angle), Vector3.ZERO)
		global_transform = Transform3D(turned.basis * global_basis, pivot + turned.basis * (global_position - pivot))
		if absf(truck_point.y - hitch_point().y) > absf(dy):
			global_transform = Transform3D(Basis(axis, 2.0 * angle) * global_basis, pivot + Basis(axis, 2.0 * angle) * (global_position - pivot))
	global_position += truck_point - hitch_point()
	linear_velocity = truck.linear_velocity
	_joint = PinJoint3D.new()
	get_parent().add_child(_joint)
	_joint.global_position = truck_point
	_joint.node_a = truck.get_path()
	_joint.node_b = get_path()
	towed_by = truck


func unhitch() -> void:
	if _joint:
		_joint.queue_free()
		_joint = null
	towed_by = null


func _build() -> void:
	var top := DECK_HEIGHT
	var half := DECK_LENGTH * 0.5
	var paint := Kit.paint(BODY)
	var frame := Kit.paint(FRAME, 0.6, 0.3)
	# Main I-beams and cross members.
	for x in [-0.55, 0.55]:
		Kit.box(_model, Vector3(0.22, 0.42, DECK_LENGTH + 0.6), Vector3(x, top - 0.38, 0.2), frame, 0.03)
	for k in 7:
		Kit.box(_model, Vector3(2.0, 0.12, 0.14), Vector3(0, top - 0.32, -half + 0.6 + k * 1.3), frame, 0.02)
	# Deck: side rails in paint, hardwood planks between, stake pockets and tie-down rings.
	for x in [-1.0, 1.0]:
		Kit.box(_model, Vector3(0.22, 0.34, DECK_LENGTH), Vector3(x * (DECK_WIDTH * 0.5 - 0.11), top - 0.17, 0), paint, 0.04)
		for k in 8:
			Kit.box(_model, Vector3(0.1, 0.12, 0.12), Vector3(x * (DECK_WIDTH * 0.5 - 0.02), top - 0.06, -half + 0.6 + k * 1.1), frame, 0.02)
			Kit.add(_model, Kit.cylinder(0.05, 0.02, 8), Vector3(x * (DECK_WIDTH * 0.5 - 0.3), top + 0.02, -half + 0.6 + k * 1.1), Kit.metal(STEEL))
	var plank_count := 12
	for k in plank_count:
		var shade := DECK.lightened(0.06) if k % 2 == 0 else DECK.darkened(0.05)
		Kit.box(_model, Vector3(DECK_WIDTH - 0.44, 0.08, DECK_LENGTH / plank_count - 0.02),
				Vector3(0, top - 0.04, -half + (k + 0.5) * DECK_LENGTH / plank_count), Kit.matte(shade), 0.01)
	# Headboard with a hazard band, drawbar, jack stand.
	Kit.box(_model, Vector3(DECK_WIDTH, 0.9, 0.18), Vector3(0, top + 0.45, -half), paint, 0.05)
	Kit.box(_model, Vector3(DECK_WIDTH + 0.02, 0.18, 0.2), Vector3(0, top + 0.78, -half), Kit.hazard(), 0.03)
	Kit.beam(_model, Vector3(-0.5, 0.85, -half + 0.2), HITCH, 0.16, frame)
	Kit.beam(_model, Vector3(0.5, 0.85, -half + 0.2), HITCH, 0.16, frame)
	Kit.add(_model, Kit.cylinder(0.12, 0.12, 12), HITCH, Kit.metal(STEEL), Vector3(PI * 0.5, 0, 0))
	Kit.add(_model, Kit.cylinder(0.05, 0.7, 8), Vector3(0.45, 0.45, -half - 0.6), frame)
	# Mudguards over the axles, mudflaps, lights and reflectors.
	for x in [-1.0, 1.0]:
		for z in [-3.6, 3.15]:
			var arch := PackedVector2Array()
			for k in 9:
				var a := PI * k / 8.0
				arch.append(Vector2(-cos(a) * 0.75 + (0.0 if z < 0.0 else 0.0), sin(a) * 0.62))
			Kit.add(_model, Kit.prism(arch, 0.5), Vector3(x * 1.15, 0.58, z * 1.0), Kit.paint(FRAME, 0.7, 0.1))
		Kit.box(_model, Vector3(0.5, 0.5, 0.03), Vector3(x * 1.15, 0.45, 4.35), Kit.matte(Color(0.1, 0.1, 0.1)), 0.01)
		Kit.box(_model, Vector3(0.24, 0.14, 0.06), Vector3(x * 1.3, top - 0.25, half + 0.04), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
		Kit.box(_model, Vector3(0.12, 0.08, 0.04), Vector3(x * 1.52, top - 0.22, -half + 1.0), Kit.glow(Color(1.0, 0.55, 0.05), 1.2), 0.01)
	Kit.box(_model, Vector3(DECK_WIDTH, 0.16, 0.08), Vector3(0, top - 0.42, half + 0.03), Kit.hazard(), 0.02)
	Kit.label(_model, "EARTHWORKS CO.", Vector3(-DECK_WIDTH * 0.5 - 0.01, top - 0.17, 0), 0.006, Color.WHITE, -PI * 0.5)
	Kit.label(_model, "EARTHWORKS CO.", Vector3(DECK_WIDTH * 0.5 + 0.01, top - 0.17, 0), 0.006, Color.WHITE, PI * 0.5)

	# Hydraulic ramps on a hinge at the back of the deck.
	_ramp_down_angle = atan2(top, RAMP_LENGTH)
	_ramp = Node3D.new()
	_ramp.position = Vector3(0, top, half)
	_ramp.rotation.x = _ramp_down_angle
	_model.add_child(_ramp)
	for x in [-0.85, 0.85]:
		Kit.box(_ramp, Vector3(0.95, 0.1, RAMP_LENGTH), Vector3(x, -0.05, RAMP_LENGTH * 0.5), Kit.metal(STEEL), 0.02)
		for side in [-1.0, 1.0]:
			Kit.box(_ramp, Vector3(0.06, 0.16, RAMP_LENGTH), Vector3(x + side * 0.46, 0.0, RAMP_LENGTH * 0.5), paint, 0.02)
		for k in 9:
			Kit.box(_ramp, Vector3(0.9, 0.04, 0.05), Vector3(x, 0.02, 0.15 + k * 0.28), Kit.matte(FRAME), 0.01)
	for x in [-1.3, 1.3]:
		Kit.add(_model, Kit.cylinder(0.07, 0.5, 8), Vector3(x, top - 0.25, half - 0.3), Kit.metal(STEEL), Vector3(0.8, 0, 0))

	# Collision: deck, headboard, drawbar, and the ramp (moved with it each frame).
	_shape(Vector3(DECK_WIDTH, 0.3, DECK_LENGTH), Transform3D(Basis.IDENTITY, Vector3(0, top - 0.15, 0)))
	_shape(Vector3(DECK_WIDTH, 0.9, 0.2), Transform3D(Basis.IDENTITY, Vector3(0, top + 0.45, -half)))
	_shape(Vector3(0.3, 0.25, 2.0), Transform3D(Basis.IDENTITY, Vector3(0, 0.85, -half - 1.0)))
	_ramp_shape = _shape(Vector3(DECK_WIDTH, 0.12, RAMP_LENGTH), Transform3D.IDENTITY)


## Collision shapes are built in model space (facing -Z) and turned to match.
func _shape(size: Vector3, model_xform: Transform3D) -> CollisionShape3D:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.transform = _model.transform * model_xform
	add_child(shape)
	return shape


func _add_wheel(pos: Vector3, steer: bool, positive_x: bool) -> void:
	var wheel := VehicleWheel3D.new()
	wheel.position = pos
	wheel.use_as_steering = steer
	wheel.wheel_radius = 0.42
	wheel.wheel_rest_length = 0.3
	wheel.suspension_travel = 0.25
	wheel.suspension_stiffness = 70.0
	wheel.suspension_max_force = 60000.0
	wheel.damping_compression = 1.8
	wheel.damping_relaxation = 2.4
	wheel.wheel_friction_slip = 2.5
	add_child(wheel)
	_wheels.append(wheel)
	if steer:
		_front_wheels.append(wheel)
	Kit.wheel(wheel, 0.42, 0.4, Color(0.85, 0.85, 0.85), 1.0 if positive_x else -1.0)  # hub faces outward
