extends VehicleBody3D
## Lowboy equipment trailer: a four-wheel drawbar trailer with a low deck and a pair of
## hydraulic loading ramps at the back. Lower the ramps (walk up to the back, F / X) and
## tracked machines can drive up and ride on the deck (machines look for the "trailer
## deck" layer under their tracks and move with it); raise them for the road and they
## stand up like a tailgate. Hitch it to a truck (T / L3 near its drawbar); it brakes
## itself when unhitched. With the ramps up, everything on the deck (machines, trucks,
## logs, mats) is strapped down and rides locked to it; lowering the ramps lets it go.
## VehicleBody3D faces +Z, so the model is built facing -Z under a node turned 180°.

const Kit = preload("res://scripts/model_kit.gd")

const TRAILER_LAYER := 128
const TRAILER_MASK := 1 | 4 | 32 | 64 | 128
## Per variant: deck length and width, ramp length, axles ([model z, steers]), wheel
## track (half), mass. The wide flatbed is long and broad enough for the big dozers and
## excavators, with a full-width ramp.
const SIZES := {
	"lowboy": {"length": 9.0, "width": 3.0, "ramp": 2.6, "axles": [[-3.6, true], [2.6, false], [3.7, false]], "track": 1.15, "mass": 5500.0},
	"logs": {"length": 9.0, "width": 3.0, "ramp": 2.6, "axles": [[-3.6, true], [2.6, false], [3.7, false]], "track": 1.15, "mass": 5500.0},
	"flatbed": {"length": 14.0, "width": 4.2, "ramp": 3.6, "axles": [[-6.1, true], [-5.1, true], [3.9, false], [4.9, false], [5.9, false]],
		"track": 1.7, "mass": 9500.0},
}
const DECK_HEIGHT := 1.0
const RAMP_RATE := 0.7  # rad/s
const RAMP_UP := -1.42  # ramp angle when raised (standing up behind the deck)

const BODY := Color(0.78, 0.12, 0.1)
const FRAME := Color(0.18, 0.18, 0.2)
const DECK := Color(0.5, 0.37, 0.24)
const STEEL := Color(0.55, 0.56, 0.58)

var machine_name := "Lowboy trailer"
## "lowboy" (flat deck, loading ramps) or "logs" (log bunks with tall stakes; the
## button at the back straps the load down instead of working ramps). Set before adding.
var variant := "lowboy"
var _len := 9.0
var _wid := 3.0
var _ramp_len := 2.6
var _hitch := Vector3(0, 0.85, -6.4)  # drawbar eye, model space (front)
var _size: Dictionary = SIZES.lowboy
## The trailer hitched behind this one (trailers chain into a road train).
var rear: Node3D
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
## What's strapped to the deck: node -> its transform relative to the trailer.
var _strapped := {}
var _straps_on := false


func _ready() -> void:
	_size = SIZES.get(variant, SIZES.lowboy)
	_len = _size.length
	_wid = _size.width
	_ramp_len = _size.ramp
	_hitch = Vector3(0, 0.85, -_len * 0.5 - 1.9)
	mass = _size.mass
	collision_layer = TRAILER_LAYER
	collision_mask = TRAILER_MASK
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.6, 0)
	can_sleep = false
	add_to_group("winchable")
	set_meta("label", "log trailer" if variant == "logs" else "trailer")
	if variant == "logs":
		machine_name = "Log trailer"
	elif variant == "flatbed":
		machine_name = "Wide flatbed trailer"
	_model = Node3D.new()
	_model.rotation.y = PI
	add_child(_model)
	_build()
	var track: float = _size.track
	for a in _size.axles:
		for x in [-track, track]:
			_add_wheel(Vector3(x, 0.85, -float(a[0])), a[1], x > 0.0)
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
	if variant != "logs":
		var target := _ramp_down_angle if ramps_down else RAMP_UP
		_ramp.rotation.x = move_toward(_ramp.rotation.x, target, RAMP_RATE * delta)
		_ramp_shape.transform = _model.transform * _ramp.transform * Transform3D(Basis.IDENTITY, Vector3(0, 0.0, _ramp_len * 0.5))
	if not ramps_down and not _straps_on:
		_strap_load()  # as the ramps start up
	elif ramps_down and _straps_on:
		_release_load()
	_carry_load()


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
	_ramp_shape.transform = _model.transform * _ramp.transform * Transform3D(Basis.IDENTITY, Vector3(0, 0.0, _ramp_len * 0.5))
	_wheel_spin += _net_speed / 0.42 * delta
	for k in _wheels.size():
		_wheels[k].position = _wheel_rest[k]
		_wheels[k].basis = Basis(Vector3.RIGHT, _wheel_spin)


## Drawbar eye in world space.
func hitch_point() -> Vector3:
	return _model.to_global(_hitch)


## Where you stand to work the ramps.
func ramp_point() -> Vector3:
	return _ramp.global_position


func toggle_ramps() -> void:
	ramps_down = not ramps_down
	if ramps_down and _straps_on:
		_release_load()


## Ramps up: whatever is resting on the deck gets strapped down.
func _strap_load() -> void:
	_straps_on = true
	var inverse := global_transform.affine_inverse()
	for node in get_tree().get_nodes_in_group("winchable"):
		var n := node as Node3D
		if n == null or n == self or n == towed_by or not n.is_inside_tree() or n.has_meta("strapped_to"):
			continue
		if n is RigidBody3D and (n as RigidBody3D).freeze:
			continue  # held by a grapple, already carried, or a joining player's copy
		var local := _model.to_local(n.global_position)
		if absf(local.x) > _wid * 0.5 + 0.4 or absf(local.z - 0.5) > _len * 0.5 + 0.3:
			continue
		if local.y < DECK_HEIGHT - 0.8 or local.y > DECK_HEIGHT + 5.0:
			continue
		_strapped[n] = inverse * n.global_transform
		n.set_meta("strapped_to", self)
		if n is RigidBody3D:
			var b := n as RigidBody3D
			b.set_meta("strap_freeze_mode", b.freeze_mode)
			b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			b.freeze = true
			# Riding locked to the deck it needn't touch it (a rigid load wedged into the
			# deck would jam the trailer), nor the truck pulling it if it overhangs.
			b.add_collision_exception_with(self)
			if towed_by is PhysicsBody3D:
				b.add_collision_exception_with(towed_by)
				b.set_meta("strap_towed_by", towed_by)
		else:
			n.set_physics_process(false)  # a tracked machine: it rides, it doesn't drive


## Keeps everything strapped down exactly where it sits on the deck.
func _carry_load() -> void:
	for n in _strapped.keys():
		if not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			_strapped.erase(n)
			continue
		(n as Node3D).global_transform = global_transform * (_strapped[n] as Transform3D)


## Ramps down: the straps come off and everything carries on with the trailer's motion.
func _release_load() -> void:
	_straps_on = false
	for n in _strapped.keys():
		if not is_instance_valid(n):
			continue
		n.remove_meta("strapped_to")
		if n is RigidBody3D:
			var b := n as RigidBody3D
			b.freeze_mode = b.get_meta("strap_freeze_mode", RigidBody3D.FREEZE_MODE_STATIC)
			b.remove_meta("strap_freeze_mode")
			_drop_exception(b)
			b.freeze = false
			b.linear_velocity = linear_velocity
			b.angular_velocity = Vector3.ZERO
		else:
			n.set("_platform", null)  # it finds the deck afresh (no jump by the whole trip)
			n.set_physics_process(true)
	_strapped.clear()


## Takes one thing out of the straps (a grapple lifting a log off the deck).
func unstrap(n: Node) -> void:
	if not _strapped.has(n):
		return
	_strapped.erase(n)
	n.remove_meta("strapped_to")
	if n is RigidBody3D:
		var b := n as RigidBody3D
		b.freeze_mode = b.get_meta("strap_freeze_mode", RigidBody3D.FREEZE_MODE_STATIC)
		b.remove_meta("strap_freeze_mode")
		_drop_exception(b)
	else:
		n.set("_platform", null)
		n.set_physics_process(true)


func _drop_exception(b: RigidBody3D) -> void:
	b.remove_collision_exception_with(self)
	if b.has_meta("strap_towed_by"):
		var truck = b.get_meta("strap_towed_by")
		if is_instance_valid(truck):
			b.remove_collision_exception_with(truck)
	b.remove_meta("strap_towed_by")


## Whether a node is strapped to this trailer's deck.
func is_strapped(n: Node) -> bool:
	return _strapped.has(n)


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
	var pivot := _model.to_global(Vector3(0, 0.4, float(_size.axles[-1][0]) - 0.5))
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
	add_collision_exception_with(truck)  # the drawbar sits over the tower's tail


func unhitch() -> void:
	if _joint:
		_joint.queue_free()
		_joint = null
	if is_instance_valid(towed_by) and towed_by is PhysicsBody3D:
		remove_collision_exception_with(towed_by)
		if towed_by.get("rear") == self:
			towed_by.set("rear", null)
	towed_by = null


## Where the next trailer's drawbar hooks on, at the back of this one.
func rear_hitch_point() -> Vector3:
	return _model.to_global(Vector3(0, 0.85, _len * 0.5 + 0.5))


func _build() -> void:
	var top := DECK_HEIGHT
	var half := _len * 0.5
	var paint := Kit.paint(BODY)
	var frame := Kit.paint(FRAME, 0.6, 0.3)
	# Main I-beams and cross members.
	for x in [-0.55, 0.55]:
		Kit.box(_model, Vector3(0.22, 0.42, _len + 0.6), Vector3(x, top - 0.38, 0.2), frame, 0.03)
	var members := int(_len / 1.3) + 1
	for k in members:
		Kit.box(_model, Vector3(_wid - 1.0, 0.12, 0.14), Vector3(0, top - 0.32, -half + 0.6 + k * (_len - 1.2) / (members - 1)), frame, 0.02)
	# Deck: side rails in paint, hardwood planks between, stake pockets and tie-down rings.
	for x in [-1.0, 1.0]:
		Kit.box(_model, Vector3(0.22, 0.34, _len), Vector3(x * (_wid * 0.5 - 0.11), top - 0.17, 0), paint, 0.04)
		var pockets := int(_len / 1.1)
		for k in pockets:
			Kit.box(_model, Vector3(0.1, 0.12, 0.12), Vector3(x * (_wid * 0.5 - 0.02), top - 0.06, -half + 0.6 + k * 1.1), frame, 0.02)
			Kit.add(_model, Kit.cylinder(0.05, 0.02, 8), Vector3(x * (_wid * 0.5 - 0.3), top + 0.02, -half + 0.6 + k * 1.1), Kit.metal(STEEL))
	var plank_count := int(_len / 0.75)
	for k in plank_count:
		var shade := DECK.lightened(0.06) if k % 2 == 0 else DECK.darkened(0.05)
		Kit.box(_model, Vector3(_wid - 0.44, 0.08, _len / plank_count - 0.02),
				Vector3(0, top - 0.04, -half + (k + 0.5) * _len / plank_count), Kit.matte(shade), 0.01)
	# Headboard with a hazard band, drawbar, jack stand.
	Kit.box(_model, Vector3(_wid, 0.9, 0.18), Vector3(0, top + 0.45, -half), paint, 0.05)
	Kit.box(_model, Vector3(_wid + 0.02, 0.18, 0.2), Vector3(0, top + 0.78, -half), Kit.hazard(), 0.03)
	Kit.beam(_model, Vector3(-0.5, 0.85, -half + 0.2), _hitch, 0.16, frame)
	Kit.beam(_model, Vector3(0.5, 0.85, -half + 0.2), _hitch, 0.16, frame)
	Kit.add(_model, Kit.cylinder(0.12, 0.12, 12), _hitch, Kit.metal(STEEL), Vector3(PI * 0.5, 0, 0))
	Kit.add(_model, Kit.cylinder(0.05, 0.7, 8), Vector3(0.45, 0.45, -half - 0.6), frame)
	# Mudguards over the axles, mudflaps, lights and reflectors.
	var track: float = _size.track
	for x in [-1.0, 1.0]:
		for a in _size.axles:
			var arch := PackedVector2Array()
			for k in 9:
				var t := PI * k / 8.0
				arch.append(Vector2(-cos(t) * 0.6, sin(t) * 0.62))
			Kit.add(_model, Kit.prism(arch, 0.5), Vector3(x * track, 0.58, float(a[0])), Kit.paint(FRAME, 0.7, 0.1))
		Kit.box(_model, Vector3(0.5, 0.5, 0.03), Vector3(x * track, 0.45, float(_size.axles[-1][0]) + 0.65), Kit.matte(Color(0.1, 0.1, 0.1)), 0.01)
		Kit.box(_model, Vector3(0.24, 0.14, 0.06), Vector3(x * (_wid * 0.5 - 0.2), top - 0.25, half + 0.04), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
		Kit.box(_model, Vector3(0.12, 0.08, 0.04), Vector3(x * (_wid * 0.5 + 0.02), top - 0.22, -half + 1.0), Kit.glow(Color(1.0, 0.55, 0.05), 1.2), 0.01)
	Kit.box(_model, Vector3(_wid, 0.16, 0.08), Vector3(0, top - 0.42, half + 0.03), Kit.hazard(), 0.02)
	Kit.label(_model, "EARTHWORKS CO.", Vector3(-_wid * 0.5 - 0.01, top - 0.17, 0), 0.006, Color.WHITE, -PI * 0.5)
	Kit.label(_model, "EARTHWORKS CO.", Vector3(_wid * 0.5 + 0.01, top - 0.17, 0), 0.006, Color.WHITE, PI * 0.5)

	if variant == "logs":
		_build_log_bunks(top, half, paint, frame)
		return
	# Hydraulic ramps on a hinge at the back of the deck.
	_ramp_down_angle = atan2(top, _ramp_len)
	_ramp = Node3D.new()
	_ramp.position = Vector3(0, top, half)
	_ramp.rotation.x = _ramp_down_angle
	_model.add_child(_ramp)
	# Two ramps on the lowboy; two broad plates (nearly full width) on the wide flatbed.
	var plate := 0.95 if variant != "flatbed" else _wid * 0.5 - 0.15
	var plate_x := 0.85 if variant != "flatbed" else _wid * 0.25 + 0.02
	for x in [-plate_x, plate_x]:
		Kit.box(_ramp, Vector3(plate, 0.1, _ramp_len), Vector3(x, -0.05, _ramp_len * 0.5), Kit.metal(STEEL), 0.02)
		for side in [-1.0, 1.0]:
			Kit.box(_ramp, Vector3(0.06, 0.16, _ramp_len), Vector3(x + side * (plate * 0.5 - 0.02), 0.0, _ramp_len * 0.5), paint, 0.02)
		for k in int(_ramp_len / 0.28):
			Kit.box(_ramp, Vector3(plate - 0.05, 0.04, 0.05), Vector3(x, 0.02, 0.15 + k * 0.28), Kit.matte(FRAME), 0.01)
	for x in [-(_wid * 0.5 - 0.2), _wid * 0.5 - 0.2]:
		Kit.add(_model, Kit.cylinder(0.07, 0.5, 8), Vector3(x, top - 0.25, half - 0.3), Kit.metal(STEEL), Vector3(0.8, 0, 0))

	# Collision: deck, headboard, drawbar, and the ramp (moved with it each frame).
	_shape(Vector3(_wid, 0.3, _len), Transform3D(Basis.IDENTITY, Vector3(0, top - 0.15, 0)))
	_shape(Vector3(_wid, 0.9, 0.2), Transform3D(Basis.IDENTITY, Vector3(0, top + 0.45, -half)))
	_shape(Vector3(0.3, 0.25, 2.0), Transform3D(Basis.IDENTITY, Vector3(0, 0.85, -half - 1.0)))
	_ramp_shape = _shape(Vector3(_wid, 0.12, _ramp_len), Transform3D.IDENTITY)


## Log trailer: four bunks with tall stakes along the deck and a log guard at the front,
## solid so logs dropped on it ride along. (No ramps: an empty ramp node keeps the shared
## code happy.)
func _build_log_bunks(top: float, half: float, paint: Material, frame: Material) -> void:
	var steel := Kit.paint(Color(0.2, 0.2, 0.22), 0.5, 0.4)
	for k in 4:
		var z := -half + 1.0 + k * (_len - 2.0) / 3.0
		Kit.box(_model, Vector3(_wid, 0.2, 0.26), Vector3(0, top + 0.1, z), steel, 0.03)
		for x in [-1.0, 1.0]:
			Kit.box(_model, Vector3(0.14, 1.9, 0.14), Vector3(x * (_wid * 0.5 - 0.08), top + 1.05, z), paint, 0.03)
			Kit.box(_model, Vector3(0.16, 0.16, 0.16), Vector3(x * (_wid * 0.5 - 0.08), top + 2.02, z), Kit.hazard(), 0.03)
	for k in 6:
		Kit.box(_model, Vector3(0.08, 1.4, 0.08), Vector3(-1.2 + k * 0.48, top + 1.2, -half), steel, 0.02)
	Kit.label(_model, "TIMBER", Vector3(-_wid * 0.5 - 0.02, top + 0.4, 0), 0.006, Color.WHITE, -PI * 0.5)
	Kit.label(_model, "TIMBER", Vector3(_wid * 0.5 + 0.02, top + 0.4, 0), 0.006, Color.WHITE, PI * 0.5)
	_ramp = Node3D.new()
	_ramp.position = Vector3(0, top, half)
	_model.add_child(_ramp)
	_shape(Vector3(_wid, 0.3, _len), Transform3D(Basis.IDENTITY, Vector3(0, top - 0.15, 0)))
	_shape(Vector3(0.14, 1.9, _len), Transform3D(Basis.IDENTITY, Vector3(-(_wid * 0.5 - 0.08), top + 0.95, 0)))
	_shape(Vector3(0.14, 1.9, _len), Transform3D(Basis.IDENTITY, Vector3(_wid * 0.5 - 0.08, top + 0.95, 0)))
	_shape(Vector3(_wid, 1.6, 0.2), Transform3D(Basis.IDENTITY, Vector3(0, top + 0.8, -half)))
	_shape(Vector3(0.3, 0.25, 2.0), Transform3D(Basis.IDENTITY, Vector3(0, 0.85, -half - 1.0)))
	_ramp_shape = _shape(Vector3(0.1, 0.1, 0.1), Transform3D(Basis.IDENTITY, Vector3(0, top, half)))
	_ramp_shape.disabled = true


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
