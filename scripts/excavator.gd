extends CharacterBody3D
## Tracked excavator. Arcade driving, a four-joint arm (swing, boom, stick, bucket)
## and a bucket that scoops soil volume out of the terrain.
## Uses models/excavator.glb when present, otherwise a box placeholder.
## Soil pushes back: the bucket can only advance as fast as its teeth cut, so it digs
## its way down instead of clipping through the ground. The arm and hull are kinematic
## bodies, so they smash through buildings.

const Terrain = preload("res://scripts/terrain.gd")
const ExcavatorModel = preload("res://scripts/excavator_model.gd")
const Water = preload("res://scripts/water.gd")
const Kit = preload("res://scripts/model_kit.gd")
const Winch = preload("res://scripts/winch.gd")
const MachineFx = preload("res://scripts/machine_fx.gd")

## Swappable tools on the end of the stick. Buckets scale the real bucket; the grapple
## replaces it with a pair of jaws (curl closes, dump opens) that hang plumb.
const ATTACHMENTS := [
	{"name": "Bucket", "scale": 1.0, "capacity": 3.5},
	{"name": "Bulk bucket", "scale": 1.25, "capacity": 6.5},
	{"name": "Trench bucket", "scale": 0.75, "capacity": 1.5},
	{"name": "Tree grapple", "scale": 1.0, "capacity": 0.0},
]
const JAW_RATE := 1.6
const GRAB_RADIUS := 1.9
const GRAB_MASS := 9000.0  # heaviest loose thing the grapple will lift (a big oak log)
const BUNDLE := 4  # most logs the grapple closes round at once
const GRIP_CENTRE := Vector3(0, -1.1, 0)  # between the closed jaws, grapple space

const MAX_SPEED := 4.5
const ACCELERATION := 4.0
const TURN_RATE := 0.9
const SCALE := 1.4  # the standard machine: the model is scaled up this much
const SWING_RATE := 0.75
const BOOM_RATE := 0.55
const STICK_RATE := 0.75
const BUCKET_RATE := 1.4
const JOINT_RESPONSE := 6.0  # how quickly hydraulics reach target speed
const BUCKET_CAPACITY := 3.5
const DIG_RADIUS := 0.85
const DIG_RATE := 2.6  # m3/s the teeth can cut; pushing harder than this stalls the arm
const PENETRATION_TOLERANCE := 0.08
const DUMP_RATE := 4.5
const DUMP_RADIUS := 1.6
const DUMP_THRESHOLD := 0.4  # soil spills once the bucket opening tips below ~25 degrees

const IDLE_SHAKE := 0.003  # metres of engine vibration at idle
const WORK_SHAKE := 0.008  # extra vibration at full load
const STALL_SHAKE := 0.02  # judder while the bucket fights the soil

const RUT_DEPTH := 0.05
const TRACK_WIDTH := 0.76
const MUD_SLOW := 0.5
const MUD_SINK := 0.25
const SOLID_MASK := 32 | 64  # trees, stumps, site buildings, trucks
const BODY_LAYER := 2
const ARM_LAYER := 8

const YELLOW := Color(0.96, 0.72, 0.12)
const DARK := Color(0.16, 0.16, 0.17)
const STEEL := Color(0.4, 0.4, 0.42)
const GLASS := Color(0.12, 0.18, 0.24)
const SOIL := Color(0.56, 0.33, 0.2)
const CLOD_COLORS: Array[Color] = [Color(0.42, 0.24, 0.14), Color(0.6, 0.36, 0.2), Color(0.5, 0.3, 0.17)]

var terrain: Terrain
## Optional, for splashes when dumping into water.
var water: Water
var driven := false
## True builds only the model (shop thumbnails).
var preview := false
## Set before adding to the tree: how much the model is scaled (1.4 standard, 2.0 the
## mining excavator). Bucket size, digging rate and reach all grow with it.
var size_scale := SCALE
## Attachments the player owns (indices into ATTACHMENTS).
var allowed_attachments: Array = [0, 1, 2, 3]
## Mouse joystick output (mouse_controls.gd): positive action name -> -1..1.
var mouse_input := {}
## Multiplayer: `remote` = driven by another player's controls (remote_axes, sent from
## their machine); `puppet` = a copy on a joining player's machine that follows the host.
var remote := false
var remote_axes := {}
var puppet := false
var _net_xform := Transform3D()
var _net_has := false
## Operator's eye (cab view) and seat, both riding on the cab.
var eye: Node3D
var seat: Node3D
var cab: Node3D
var machine_name := "Excavator"
var winch: Winch
var attachment := 0
## What the grapple is holding.
var held: RigidBody3D
## Trucks (truck.gd) whose beds catch soil dumped over them.
var receivers: Array = []
var bucket_load := 0.0
## What's in the bucket (Terrain.SURFACE_SOIL / SURFACE_GRAVEL), by majority.
var bucket_material := 0
var _gravel_in_bucket := 0.0
var soil_moved := 0.0
var stalled := false  # soil is currently stopping the bucket

var _rig := {}
var _speed := 0.0
var _joint_velocity := Vector4.ZERO  # swing, boom, stick, bucket
var _spawn := Transform3D.IDENTITY
var _visual: Node3D
var _boom: Node3D
var _stick: Node3D
var _bucket: Node3D
var _load_pivot: Node3D
var _materials := {}
var _track_travel := Vector2.ZERO  # metres each track (left, right) has moved
var _engine := 0.0  # 0 = idle, 1 = working hard
var _time := 0.0
var _exhaust: GPUParticles3D
var _dug := 0.0  # m3 cut this frame
var _spill_point := Vector3.ZERO
var _spilling := false
var _fx_dig: GPUParticles3D
var _fx_dig_dust: GPUParticles3D
var _fx_pour: GPUParticles3D
var _fx_land_dust: GPUParticles3D
var _fx_splash: GPUParticles3D
var _heap: MeshInstance3D
var _heap_fill := -1.0
var _capacity := BUCKET_CAPACITY
var _dig_radius := DIG_RADIUS
var _k := 1.0  # size relative to the standard machine
var _grapple: Node3D
var _jaws: Array[Node3D] = []
var _jaw := 0.0  # 0 open .. 1 closed
var _held_parent: Node
## More logs closed in the jaws with `held`: [body, parent, from, to] (grapple space).
var _bundle: Array = []
var _grip_from := Transform3D()  # held thing relative to the grapple, as grabbed...
var _grip_to := Transform3D()  # ...and settled in the jaws
var _grip_t := 1.0
var _platform: Node3D
var _platform_last := Transform3D()
var _last_rut := Transform3D()
var _net_joints := Vector4.ZERO
var _net_tilt := Vector3.ZERO
var _net_dug := false
var _sink_timer := 0.0
## How far (m) the tracks have sunk into mud, beyond the mud's own softness.
var bog := 0.0


func _ready() -> void:
	_k = size_scale / SCALE
	_capacity = BUCKET_CAPACITY * _k * _k * _k
	_dig_radius = DIG_RADIUS * _k
	if _k > 1.05:
		machine_name = "Mining excavator"
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_visual = _node(self, Vector3.ZERO)
	if ResourceLoader.exists(ExcavatorModel.PATH):
		_rig = ExcavatorModel.build(_visual)
	else:
		_rig = _build_placeholder()
	cab = _rig.cab
	_boom = _rig.boom
	_stick = _rig.stick
	_bucket = _rig.bucket
	var rest: Vector3 = _rig.rest
	_boom.rotation.x = rest.x
	_stick.rotation.x = rest.y
	_bucket.rotation.x = rest.z

	_visual.scale = Vector3.ONE * size_scale
	if preview:
		_update_pistons()
		set_physics_process(false)
		set_process(false)
		return
	var hull: Vector3 = (_rig.hull as Vector3) * size_scale
	var hull_center := Vector3(0, hull.y * 0.5 + 0.2, 0)
	_add_collision(self, hull, hull_center)
	# Kinematic hull: the machine bulldozes through debris instead of stalling on it.
	_add_collision(_kinematic_body(self), hull, hull_center)
	for seg in _rig.segments:
		_segment_body(seg[0], seg[1], seg[2], seg[3], seg[4])
	_build_load_visual()
	_exhaust = _build_exhaust(cab, _rig.exhaust)
	eye = _node(cab, Vector3.ZERO)
	eye.transform = _rig.eye
	seat = _node(cab, _rig.seat)
	_build_dirt_fx()
	_build_grapple()
	# Parts that move together draw as one mesh (a few calls per joint instead of ~45).
	Kit.merge_tree(_visual)
	winch = Winch.new()
	winch.vehicle = self
	winch.max_force = 160000.0
	winch.position = Vector3(0, 1.0, (_rig.track as Vector2).x * size_scale + 0.4)
	add_child(winch)
	add_to_group("winchable")
	set_meta("label", "excavator")
	_spawn = global_transform
	_follow_ground(0.0, true)
	_update_pistons()


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	_ride_platform()
	_dug = 0.0
	var saved_xform := global_transform
	var saved_joints := _joints()
	var before := _penetration()
	_drive(delta)
	_operate_arm(delta)
	_follow_ground(delta, false)
	stalled = _dig(delta, before)
	if stalled:
		# The soil won: undo the machine's travel, then re-apply each joint on its own and
		# keep only the ones that don't push deeper (so a buried bucket can still curl or
		# lift out). The teeth keep cutting, so blocked joints progress at DIG_RATE.
		var wanted := _joints()
		global_transform = saved_xform
		_speed = 0.0
		_set_joints(saved_joints)
		var current := saved_joints
		for axis in [3, 1, 2, 0]:
			var tilt_before := bucket_tilt()
			var trial := current
			trial[axis] = wanted[axis]
			_set_joints(trial)
			var pen := _penetration()
			# Curling the bucket closed always gets through the soil, so a full bucket
			# can be secured before lifting it out.
			var curling_closed: bool = axis == 3 and bucket_tilt() > tilt_before
			if curling_closed or pen <= PENETRATION_TOLERANCE or pen <= before + 0.001:
				current = trial
			else:
				_joint_velocity[axis] *= 0.5
		_set_joints(current)
	if _grapple.visible:
		_operate_grapple(delta)
	else:
		_spill(delta)
	_rut()
	_sink_in(delta)
	_update_pistons()
	_update_load_visual()
	_animate(delta)


func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	bog = 0.0
	global_transform = xform
	_speed = 0.0
	_joint_velocity = Vector4.ZERO
	_follow_ground(0.0, true)
	reset_physics_interpolation()


## The tracks press ruts as the machine travels or turns.
func _rut() -> void:
	var moved := global_position.distance_to(_last_rut.origin)
	var turned := absf(global_basis.z.signed_angle_to(_last_rut.basis.z, Vector3.UP))
	if moved < 0.2 and turned < 0.05:
		return
	_last_rut = global_transform
	var track: Vector2 = (_rig.track as Vector2) * size_scale
	var fwd := -global_basis.z
	for side in [-1.0, 1.0]:
		terrain.press(global_position + global_basis.x * side * track.y, fwd, track.x + 0.2, TRACK_WIDTH * size_scale * 0.5, RUT_DEPTH)


## Swaps to the next attachment (only with an empty bucket / open grapple).
func cycle_attachment() -> String:
	if bucket_load > 0.05 or held:
		return "Empty the bucket first"
	var next := attachment
	for _step in ATTACHMENTS.size():
		next = (next + 1) % ATTACHMENTS.size()
		if next in allowed_attachments:
			break
	return set_attachment(next)


func set_attachment(index: int) -> String:
	attachment = index
	var a: Dictionary = ATTACHMENTS[attachment]
	var grapple: bool = a.capacity <= 0.0
	_capacity = float(a.capacity) * _k * _k * _k
	_dig_radius = DIG_RADIUS * float(a.scale) * _k
	_bucket.scale = Vector3.ONE * float(a.scale)
	for child in _bucket.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = not grapple
		elif child is AnimatableBody3D:
			(child as AnimatableBody3D).collision_layer = 0 if grapple else ARM_LAYER
	_grapple.visible = grapple
	_jaw = 0.0
	if not grapple:
		_bucket.rotation.x = clampf(_bucket.rotation.x, (_rig.bucket_limits as Vector2).x, (_rig.bucket_limits as Vector2).y)
	return "%s%s" % [a.name, "" if _capacity <= 0.0 else " %.1f m³" % _capacity]


## Closing the jaws on something grabs it: loose logs, stumps, props and debris get
## picked up; a standing tree is pulled over and held; a rooted stump is torn out.
func _operate_grapple(delta: float) -> void:
	for k in _jaws.size():
		_jaws[k].rotation.x = lerpf(0.95, 0.05, _jaw) * (1.0 if k == 0 else -1.0)
	var centre := _grapple.to_global(GRIP_CENTRE)
	if held and (_jaw < 0.5 or not is_instance_valid(held)):
		_release()
	elif held and _grip_t < 1.0:
		# Settle the load into the jaws.
		_grip_t = minf(_grip_t + delta / 0.25, 1.0)
		var ease := smoothstep(0.0, 1.0, _grip_t)
		held.global_transform = _grapple.global_transform * _grip_from.interpolate_with(_grip_to, ease)
		for entry in _bundle:
			if is_instance_valid(entry[0]):
				(entry[0] as Node3D).global_transform = _grapple.global_transform * (entry[2] as Transform3D).interpolate_with(entry[3], ease)
	elif held == null and _jaw > 0.85:
		var best: Node3D = null
		var best_d := GRAB_RADIUS * _k
		for node in get_tree().get_nodes_in_group("winchable"):
			var thing := node as Node3D
			if thing == null or thing == self or thing is VehicleBody3D or thing is CharacterBody3D:
				continue
			var rigid := thing as RigidBody3D
			if rigid and rigid.mass > GRAB_MASS * _k * _k * _k:
				continue
			var grab_at := thing.global_position + Vector3(0, 0.6, 0) if thing.is_in_group("trees") else _grip_point(thing, centre)
			var d := grab_at.distance_to(centre)
			if d < best_d:
				best_d = d
				best = thing
		if best and best.is_in_group("trees"):
			best = best.call("pull_out") if best.get("is_stump") else best.call("fell", best.global_position - global_position)
		if best is RigidBody3D:
			_grab(best)
			if best.has_meta("grip"):
				_grab_bundle(centre)


func _grab(body: RigidBody3D) -> void:
	held = body
	_held_parent = body.get_parent()
	var centre := _grapple.to_global(GRIP_CENTRE)
	var grip_local := body.to_local(_grip_point(body, centre))
	body.remove_meta("awaiting_ground")
	body.remove_meta("bedded")
	if body.has_meta("tie_locked"):
		var ties_node := get_tree().get_first_node_in_group("ties")
		if ties_node:
			ties_node.release(body)
	if body.has_meta("strapped_to"):
		var strap = body.get_meta("strapped_to")
		if is_instance_valid(strap):
			strap.unstrap(body)
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	body.reparent(_grapple, true)
	# Where it should end up: the grip point between the jaws; a log lies across them
	# (its trunk along the grapple's X axis, whichever way round is nearer).
	var jaws := _grapple.global_transform.orthonormalized()
	var basis := body.global_basis.orthonormalized()
	if body.has_meta("grip") and (body.get_meta("grip") as Array)[0] != (body.get_meta("grip") as Array)[1]:
		# Turn the shortest way so its long axis (logs, mats) lies across the jaws.
		var g: Array = body.get_meta("grip")
		var axis := (basis * ((g[1] as Vector3) - (g[0] as Vector3))).normalized()
		var across := jaws.basis.x.normalized()
		if axis.dot(across) < 0.0:
			across = -across
		if axis.cross(across).length() > 0.0001:
			basis = Basis(Quaternion(axis, across)) * basis
	var settled := Transform3D(basis, Vector3.ZERO)
	settled.origin = centre - settled.basis * grip_local
	_grip_from = _grapple.global_transform.affine_inverse() * body.global_transform
	_grip_to = _grapple.global_transform.affine_inverse() * settled
	_grip_t = 0.0


## The point on `body` nearest `near` that a grapple can hold: anywhere along a log's
## trunk, the middle of anything else.
func _grip_point(body: Node3D, near: Vector3) -> Vector3:
	if not body.has_meta("grip"):
		return body.global_position
	var g: Array = body.get_meta("grip")
	var a := body.to_global(g[0])
	var b := body.to_global(g[1])
	var ab := b - a
	if ab.length_squared() < 0.0001:
		return a
	return a + ab * clampf((near - a).dot(ab) / ab.length_squared(), 0.0, 1.0)


func _release() -> void:
	if is_instance_valid(held):
		held.reparent(_held_parent if is_instance_valid(_held_parent) else get_parent(), true)
		held.freeze = false
		held.sleeping = false
	held = null
	for entry in _bundle:
		var body: RigidBody3D = entry[0]
		if is_instance_valid(body):
			body.reparent(entry[1] if is_instance_valid(entry[1]) else get_parent(), true)
			body.freeze = false
			body.sleeping = false
	_bundle.clear()


## Closing on a pile of logs takes the others lying in the jaws too (up to BUNDLE in all),
## settled into a bundle round the first.
func _grab_bundle(centre: Vector3) -> void:
	var g: Array = held.get_meta("grip")
	var held_axis := (held.global_basis * ((g[1] as Vector3) - (g[0] as Vector3))).normalized()
	var picked := []
	for node in get_tree().get_nodes_in_group("shreddable"):
		var log := node as RigidBody3D
		if log == null or log == held or log.freeze or not log.has_meta("grip") or not log.is_inside_tree():
			continue
		var lg: Array = log.get_meta("grip")
		if lg[0] == lg[1] or log.mass > GRAB_MASS * _k * _k * _k:
			continue  # logs only (stumps are one at a time)
		var d := _grip_point(log, centre).distance_to(centre)
		if d < GRAB_RADIUS * 1.25 * _k:
			picked.append([d, log])
	picked.sort_custom(func(a, b): return a[0] < b[0])
	var slots := [Vector3(0, 0.5, 0.0), Vector3(0, 0.22, 0.42), Vector3(0, 0.22, -0.42)]
	var jaws := _grapple.global_transform.orthonormalized()
	for k in mini(picked.size(), BUNDLE - 1):
		var log: RigidBody3D = picked[k][1]
		var parent := log.get_parent()
		var lg: Array = log.get_meta("grip")
		var mid: Vector3 = ((lg[0] as Vector3) + (lg[1] as Vector3)) * 0.5
		log.remove_meta("awaiting_ground")
		if log.has_meta("tie_locked"):
			var ties_node := get_tree().get_first_node_in_group("ties")
			if ties_node:
				ties_node.release(log)
		if log.has_meta("strapped_to"):
			var strap = log.get_meta("strapped_to")
			if is_instance_valid(strap):
				strap.unstrap(log)
		log.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		log.freeze = true
		log.reparent(_grapple, true)
		# Lie it alongside the first log, stacked in the jaws.
		var basis := log.global_basis.orthonormalized()
		var axis := (basis * ((lg[1] as Vector3) - (lg[0] as Vector3))).normalized()
		var along := held_axis if axis.dot(held_axis) >= 0.0 else -held_axis
		if axis.cross(along).length() > 0.0001:
			basis = Basis(Quaternion(axis, along)) * basis
		var spot: Vector3 = centre + jaws.basis * ((slots[k] as Vector3) * _k)
		var settled := Transform3D(basis, spot - basis * mid)
		_bundle.append([log, parent, _grapple.global_transform.affine_inverse() * log.global_transform,
			_grapple.global_transform.affine_inverse() * settled])


## Two-tine log grapple hanging from the bucket pin (hidden until selected).
func _build_grapple() -> void:
	_grapple = _node(_bucket, Vector3.ZERO)
	var steel := Color(0.3, 0.3, 0.32)
	_box(_grapple, Vector3(0.5, 0.5, 0.5), Vector3(0, -0.2, 0), DARK)  # rotator
	_box(_grapple, Vector3(1.2, 0.3, 0.7), Vector3(0, -0.55, 0), YELLOW)
	for k in 2:
		var side := -1.0 if k == 0 else 1.0
		var jaw := _node(_grapple, Vector3(0, -0.6, 0.25 * side))
		for t in [-0.35, 0.35]:
			_box(jaw, Vector3(0.14, 0.9, 0.14), Vector3(t, -0.45, 0.1 * side), steel)
			var hook := _box(jaw, Vector3(0.14, 0.14, 0.55), Vector3(t, -0.92, -0.12 * side), steel)
			hook.rotation.x = 0.5 * side
		_box(jaw, Vector3(0.84, 0.12, 0.12), Vector3(0, -0.3, 0.1 * side), YELLOW)
		_jaws.append(jaw)
	_grapple.visible = false


## Multiplayer state (host -> joining players).
func net_state() -> Array:
	return [_joints(), bucket_load, attachment, _jaw, _track_travel, _speed, _joint_velocity, stalled, driven,
		_dug > 0.0, _spilling, _spill_point, _visual.rotation, winch.net_state()]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_net_joints = s[0]
	bucket_load = s[1]
	if int(s[2]) != attachment:
		set_attachment(int(s[2]))
	_jaw = s[3]
	_track_travel = s[4]
	_speed = s[5]
	_joint_velocity = s[6]
	stalled = s[7]
	driven = s[8]
	_net_dug = s[9]
	_spilling = s[10]
	_spill_point = s[11]
	_net_tilt = s[12]
	winch.apply_net_state(s[13])


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	var j := _joints()
	_set_joints(Vector4(lerp_angle(j.x, _net_joints.x, t), lerpf(j.y, _net_joints.y, t), lerpf(j.z, _net_joints.z, t), lerpf(j.w, _net_joints.w, t)))
	_visual.rotation.x = lerp_angle(_visual.rotation.x, _net_tilt.x, t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, _net_tilt.z, t)
	for k in _jaws.size():
		_jaws[k].rotation.x = lerpf(0.95, 0.05, _jaw) * (1.0 if k == 0 else -1.0)
	_dug = DIG_RATE * delta * 0.5 if _net_dug else 0.0
	_update_pistons()
	_update_load_visual()
	_animate(delta)


## Heavy tracks slowly press down into soft mud (faster standing still); a deeply sunk
## machine can only crawl. Mats, decks and gravel stay firm.
func _sink_in(delta: float) -> void:
	_sink_timer -= delta
	if _platform != null:
		bog = move_toward(bog, 0.0, delta * 0.5)
		return
	if _sink_timer > 0.0:
		return
	_sink_timer = 0.5
	var mud := terrain.mud_at(global_position.x, global_position.z)
	if mud < 0.3:
		bog = move_toward(bog, 0.0, 0.5 * 0.4)
		return
	# Standing still the weight presses the tracks deeper; driving they slowly climb out.
	if absf(_speed) < 0.2:
		bog = minf(bog + 0.5 * 0.025 * mud * _k, 0.55 * mud * _k)
	else:
		bog = maxf(bog - 0.5 * 0.03, 0.0)
	if winch.is_attached() and winch.tension > 1000.0:
		bog = maxf(bog - 0.5 * 0.1, 0.0)
	var track: Vector2 = (_rig.track as Vector2) * size_scale
	var press := 0.004 * mud * _k * (2.0 if absf(_speed) < 0.2 else 1.0)
	for side in [-1.0, 1.0]:
		terrain.dig_in(global_position + global_basis.x * side * track.y, -global_basis.z, track.x,
				TRACK_WIDTH * size_scale * 0.5, press, 0.3 + 0.5 * mud * _k)


## Top-speed factor for how deep the tracks have sunk.
func _sunk_factor() -> float:
	if _platform != null:
		return 1.0
	return 1.0 - clampf((bog - 0.15) / 0.5, 0.0, 0.65)


## Where soil leaves the bucket when it's tipped.
func spill_point() -> Vector3:
	return _bucket.to_global(_rig.load_center)


## Where the operator climbs in and out.
func door_position() -> Vector3:
	return cab.to_global(_rig.door)


## 1 = bucket opening facing straight up (holding), below DUMP_THRESHOLD = spilling.
func bucket_tilt() -> float:
	return (_bucket.global_basis * (_rig.opening as Vector3)).normalized().y


func _axis(negative: StringName, positive: StringName) -> float:
	if not driven:
		return 0.0
	if remote:
		return clampf(float(remote_axes.get(positive, 0.0)) - float(remote_axes.get(negative, 0.0)), -1.0, 1.0)
	return clampf(Input.get_axis(negative, positive) + float(mouse_input.get(positive, 0.0)), -1.0, 1.0)


## How hard each control is being worked (swing, boom, stick, bucket), for the operator's hands.
func controls() -> Vector4:
	return _joint_velocity / Vector4(SWING_RATE, BOOM_RATE, STICK_RATE, BUCKET_RATE)


## Controller rumble (weak, strong) for the current effort.
func rumble() -> Vector2:
	if not driven:
		return Vector2.ZERO
	return Vector2(0.12 + (0.35 if _dug > 0.0 else 0.0), 0.6 if stalled else 0.0)


func status() -> String:
	var text: String
	if _grapple.visible:
		text = "GRAPPLE   ·   %s" % ("HOLDING " + String(held.get_meta("label", "load")).to_upper() if held else ("CLOSED" if _jaw > 0.8 else "OPEN"))
	else:
		text = "%s   ·   %.2f m³ · %d%%%s" % [String(ATTACHMENTS[attachment].name).to_upper(), bucket_load,
				roundi(bucket_load / _capacity * 100.0), "   ⛏ CUTTING" if stalled else ""]
	if winch.is_attached():
		text += "   ·   WINCH %.0f m" % winch.length
	return text


func status_fill() -> float:
	return _jaw if _grapple.visible else bucket_load / _capacity


## What the HUD shows for this machine.
func hud_info() -> Dictionary:
	var info := {"speed": absf(_speed) * 3.6, "max_speed": MAX_SPEED * 3.6, "flags": [String(ATTACHMENTS[attachment].name).to_upper()]}
	if _grapple.visible:
		info.load = _jaw
		info.load_text = "GRAPPLE  " + ("HOLDING " + String(held.get_meta("label", "load")).to_upper() if is_instance_valid(held) else ("CLOSED" if _jaw > 0.8 else "OPEN"))
	else:
		info.load = bucket_load / _capacity
		info.load_text = "BUCKET %.2f / %.1f m³%s" % [bucket_load, _capacity, "  GRAVEL" if bucket_material == Terrain.SURFACE_GRAVEL and bucket_load > 0.05 else ""]
	if stalled:
		info.flags.append("CUTTING")
	if winch.is_attached():
		info.flags.append("WINCH %.0f m" % winch.length)
	if bog > 0.15:
		info.flags.append("SUNK %.1f m" % bog)
	return info


func _drive(delta: float) -> void:
	var mud := terrain.mud_at(global_position.x, global_position.z)
	var ice := terrain.is_ice(global_position.x, global_position.z)  # tracks spin and slide
	_speed = move_toward(_speed, _axis("drive_back", "drive_forward") * MAX_SPEED * (1.0 - MUD_SLOW * mud) * _sunk_factor(), ACCELERATION * (0.18 if ice else 1.0) * delta)
	var turn := _axis("turn_right", "turn_left") * TURN_RATE * (1.0 - 0.4 * mud) * (0.6 if ice else 1.0)
	rotate_y(turn * delta)
	# Skid steer: turning slows one track and speeds up the other.
	var track: Vector2 = (_rig.track as Vector2) * size_scale
	_track_travel += Vector2(_speed - turn * track.y, _speed + turn * track.y) * delta
	velocity = -global_basis.z * _speed
	move_and_slide()
	global_position = terrain.clamp_inside(global_position, 3.0)


func _operate_arm(delta: float) -> void:
	var curl_sign: float = _rig.curl_sign
	var target := Vector4(
		_axis("swing_right", "swing_left") * SWING_RATE / sqrt(_k),
		_axis("boom_down", "boom_up") * BOOM_RATE / sqrt(_k),
		_axis("stick_in", "stick_out") * STICK_RATE / sqrt(_k),
		_axis("bucket_dump", "bucket_curl") * BUCKET_RATE * curl_sign / sqrt(_k))
	_joint_velocity = _joint_velocity.lerp(target, 1.0 - exp(-JOINT_RESPONSE * delta))
	cab.rotation.y = wrapf(cab.rotation.y + _joint_velocity.x * delta, -PI, PI)
	_boom.rotation.x = _clamp_joint(_boom.rotation.x + _joint_velocity.y * delta, _rig.boom_limits)
	_stick.rotation.x = _clamp_joint(_stick.rotation.x + _joint_velocity.z * delta, _rig.stick_limits)
	if _grapple.visible:
		# The grapple hangs plumb; curl/dump drive the jaws instead.
		var up := _stick.global_basis.inverse() * Vector3.UP
		_bucket.rotation.x = atan2(up.z, up.y)
		_jaw = clampf(_jaw + _axis("bucket_dump", "bucket_curl") * JAW_RATE * delta, 0.0, 1.0)
	else:
		_bucket.rotation.x = _clamp_joint(_bucket.rotation.x + _joint_velocity.w * delta, _rig.bucket_limits)


func _clamp_joint(value: float, limits: Vector2) -> float:
	return clampf(value, limits.x, limits.y)


func _joints() -> Vector4:
	return Vector4(cab.rotation.y, _boom.rotation.x, _stick.rotation.x, _bucket.rotation.x)


func _set_joints(j: Vector4) -> void:
	cab.rotation.y = j.x
	_boom.rotation.x = j.y
	_stick.rotation.x = j.z
	_bucket.rotation.x = j.w


## Sits the machine on the terrain and tilts it to match the ground under the tracks.
func _follow_ground(delta: float, instant: bool) -> void:
	var track: Vector2 = (_rig.track as Vector2) * size_scale
	var fwd := -global_basis.z * track.x
	var side := global_basis.x * track.y
	var p := global_position
	var fl := _support(p + fwd - side)
	var fr := _support(p + fwd + side)
	var bl := _support(p - fwd - side)
	var br := _support(p - fwd + side)
	_check_platform(p)
	var pitch := atan2((fl + fr) - (bl + br), 4.0 * track.x)
	var roll := atan2((fr + br) - (fl + bl), 4.0 * track.y)
	var t := 1.0 if instant else 1.0 - exp(-8.0 * delta)
	var sink := 0.0 if _platform != null else MUD_SINK * terrain.mud_at(p.x, p.z) * _k + bog
	global_position.y = lerpf(p.y, (fl + fr + bl + br) * 0.25 - sink, t)
	_visual.rotation.x = lerp_angle(_visual.rotation.x, pitch, t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, roll, t)


## Height the tracks rest on: the terrain, or a trailer deck if one is under them.
func _support(p: Vector3) -> float:
	var ground := _ground(p)
	var deck := MachineFx.deck_below(self, p)
	return maxf(ground, float(deck.height)) if not deck.is_empty() else ground


func _check_platform(p: Vector3) -> void:
	var deck := MachineFx.deck_below(self, p)
	var body: Node3D = deck.get("body")
	if body != _platform:
		_platform = body
		if body:
			_platform_last = body.global_transform


## Carried along by the trailer we're parked on.
func _ride_platform() -> void:
	if _platform == null or not is_instance_valid(_platform):
		_platform = null
		return
	var now := _platform.global_transform
	var moved := now * _platform_last.affine_inverse()
	global_position = moved * global_position
	rotate_y(moved.basis.get_euler().y)
	_platform_last = now


func _ground(p: Vector3) -> float:
	return terrain.get_height(p.x, p.z)


## Deepest point of the bucket below the soil surface (negative = clear of the ground).
func _penetration() -> float:
	var deepest := -INF
	for local in _rig.carve_points + _rig.block_points:
		var p := _bucket.to_global(local)
		deepest = maxf(deepest, _ground(p) - p.y)
	return deepest


## Cuts soil wherever the bucket presses into the ground (teeth first) and reports
## whether the soil stops this frame's motion: a full bucket can't cut, and an empty
## one can only cut DIG_RATE per second.
func _dig(delta: float, before: float) -> bool:
	if not _grapple.visible and bucket_load < _capacity - 0.001:
		var budget := minf(_capacity - bucket_load, DIG_RATE * _k * _k * _k * delta)
		for local in _rig.carve_points + _rig.block_points:
			var p := _bucket.to_global(local)
			if budget > 0.0 and p.y < _ground(p):
				var gravel := terrain.is_gravel(p.x, p.z)
				var removed := terrain.dig(p, _dig_radius, budget)
				_dug += removed
				bucket_load += removed
				if gravel:
					_gravel_in_bucket += removed
				_set_bucket_material(Terrain.SURFACE_GRAVEL if _gravel_in_bucket > bucket_load * 0.5 else Terrain.SURFACE_SOIL)
				budget -= removed
	var after := _penetration()
	return after > PENETRATION_TOLERANCE and after > before + 0.001


func _buried() -> bool:
	for local in _rig.carve_points:
		var p := _bucket.to_global(local)
		if p.y < _ground(p):
			return true
	return false


## Soil pours out once the bucket is lifted clear and tipped past DUMP_THRESHOLD.
func _spill(delta: float) -> void:
	_spilling = bucket_load > 0.0 and bucket_tilt() < DUMP_THRESHOLD and not _buried()
	if not _spilling:
		return
	var amount := minf(bucket_load, DUMP_RATE * _k * _k * _k * delta)
	var p := _bucket.to_global(_rig.load_center)
	_spill_point = p
	_gravel_in_bucket = maxf(_gravel_in_bucket - amount * (_gravel_in_bucket / maxf(bucket_load, 0.001)), 0.0)
	bucket_load -= amount
	soil_moved += amount
	for truck in receivers:
		if truck.accepts_soil(p):
			amount -= truck.add_soil(amount, bucket_material)
			break
	if amount > 0.0:
		terrain.deposit(p.x, p.z, amount, DUMP_RADIUS * _k, bucket_material)


## Aims each hydraulic cylinder half at the pin it connects to.
func _update_pistons() -> void:
	for piston in _rig.pistons:
		var node: Node3D = piston.node
		var target: Node3D = piston.target
		var parent := node.get_parent() as Node3D
		var d := parent.to_local(target.to_global(piston.target_local)) - node.position
		node.rotation.x = ExcavatorModel.yz_angle(d) - float(piston.rest)
		if not (piston.extender as Dictionary).is_empty():
			ExcavatorModel.extend_rod(piston.extender, d.length())


## Tracks, wheels, bucket linkage, engine vibration and exhaust.
func _animate(delta: float) -> void:
	_time += delta
	var tracks: Dictionary = _rig.get("tracks", {})
	if not tracks.is_empty():
		var loop: float = float(_rig.track_loop) * size_scale
		_track_travel = Vector2(fposmod(_track_travel.x, loop), fposmod(_track_travel.y, loop))
		# Moving forward, the top run of each track travels toward the front.
		(tracks.left as ShaderMaterial).set_shader_parameter("scroll", -_track_travel.x / size_scale)
		(tracks.right as ShaderMaterial).set_shader_parameter("scroll", -_track_travel.y / size_scale)
		for wheel in _rig.wheels:
			(wheel as Node3D).rotation.x = -_track_travel.y / (float(_rig.wheel_radius) * size_scale)
	if _rig.has("linkage"):
		ExcavatorModel.update_linkage(_rig.linkage)

	var work := 0.0
	if driven:
		var arm := Vector3(_joint_velocity.y, _joint_velocity.z, _joint_velocity.w).length()
		work = clampf(absf(_speed) / MAX_SPEED + arm * 0.8 + absf(_joint_velocity.x) * 0.5, 0.0, 1.0)
		if stalled:
			work = 1.0
	_engine = lerpf(_engine, work, 1.0 - exp(-3.0 * delta))
	var shake := (IDLE_SHAKE + WORK_SHAKE * _engine) * sin(_time * 70.0) if driven else 0.0
	if stalled:
		shake += STALL_SHAKE * sin(_time * 37.0)
	_visual.position.y = shake
	_exhaust.amount_ratio = 0.25 + 0.75 * _engine if driven else 0.08
	_exhaust.speed_scale = 0.8 + 0.8 * _engine
	_update_dirt_fx(delta)


func _update_dirt_fx(delta: float) -> void:
	var tip := _bucket.to_global(_rig.carve_points[0])
	var cutting := _dug > 0.0
	_fx_dig.global_position = tip
	_fx_dig.emitting = cutting
	_fx_dig.amount_ratio = clampf(_dug / (DIG_RATE * delta), 0.3, 1.0) if cutting else 0.0
	_fx_dig_dust.global_position = tip
	_fx_dig_dust.emitting = cutting or stalled
	_fx_pour.global_position = _spill_point
	_fx_pour.emitting = _spilling
	var ground := Vector3(_spill_point.x, _ground(_spill_point), _spill_point.z)
	var wet := _spilling and water != null and water.depth_at(ground.x, ground.z) > 0.05
	_fx_land_dust.global_position = ground
	_fx_land_dust.emitting = _spilling and not wet
	if wet:
		_fx_splash.global_position = Vector3(ground.x, water.surface_height(ground.x, ground.z), ground.z)
	_fx_splash.emitting = wet


func _build_dirt_fx() -> void:
	var clod := SphereMesh.new()
	clod.radius = 0.06
	clod.height = 0.1
	clod.radial_segments = 5
	clod.rings = 2
	clod.material = _particle_material(false)
	var puff := SphereMesh.new()
	puff.radius = 0.28
	puff.height = 0.5
	puff.radial_segments = 7
	puff.rings = 3
	puff.material = _particle_material(true)
	var drop := SphereMesh.new()
	drop.radius = 0.06
	drop.height = 0.12
	drop.radial_segments = 5
	drop.rings = 2
	drop.material = _particle_material(true)

	var dig := _clod_process(Vector3.UP, 55.0, 1.5, 3.5)
	dig.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	dig.emission_sphere_radius = 0.3
	_fx_dig = _particles(70, 1.8, clod, dig)

	var pour := _clod_process(Vector3.DOWN, 25.0, 0.2, 0.9)
	pour.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pour.emission_box_extents = Vector3(0.4, 0.08, 0.3)
	_fx_pour = _particles(120, 1.5, clod, pour)

	_fx_dig_dust = _particles(20, 1.6, puff, _dust_process(Color(0.62, 0.45, 0.3)))
	_fx_land_dust = _particles(30, 1.8, puff, _dust_process(Color(0.7, 0.55, 0.38)))

	var splash := ParticleProcessMaterial.new()
	splash.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	splash.emission_sphere_radius = 0.5
	splash.direction = Vector3.UP
	splash.spread = 35.0
	splash.initial_velocity_min = 2.0
	splash.initial_velocity_max = 4.5
	splash.gravity = Vector3(0, -9.8, 0)
	splash.scale_min = 0.6
	splash.scale_max = 1.3
	splash.color_ramp = _fade(Color(0.95, 1.0, 1.0, 0.95), Color(0.7, 0.9, 0.9, 0.0))
	_fx_splash = _particles(60, 0.9, drop, splash)


func _clod_process(direction: Vector3, spread: float, speed_min: float, speed_max: float) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.direction = direction
	process.spread = spread
	process.initial_velocity_min = speed_min
	process.initial_velocity_max = speed_max
	process.gravity = Vector3(0, -9.8, 0)
	process.angular_velocity_min = -360.0
	process.angular_velocity_max = 360.0
	process.scale_min = 0.5
	process.scale_max = 1.5
	var tints := Gradient.new()
	tints.set_color(0, CLOD_COLORS[0])
	tints.set_color(1, CLOD_COLORS[1])
	tints.add_point(0.5, CLOD_COLORS[2])
	var tint_texture := GradientTexture1D.new()
	tint_texture.gradient = tints
	process.color_initial_ramp = tint_texture
	# Bounce off the ground (needs the GPUParticlesCollisionHeightField3D in main.gd).
	process.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	process.collision_bounce = 0.15
	process.collision_friction = 0.6
	return process


func _dust_process(color: Color) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.4
	process.direction = Vector3.UP
	process.spread = 80.0
	process.initial_velocity_min = 0.3
	process.initial_velocity_max = 0.9
	process.gravity = Vector3(0.2, 0.15, 0)
	process.damping_min = 0.4
	process.damping_max = 0.8
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.5))
	grow.add_point(Vector2(1, 2.2))
	var grow_texture := CurveTexture.new()
	grow_texture.curve = grow
	process.scale_curve = grow_texture
	var start := color
	start.a = 0.55
	var end := color.lightened(0.2)
	end.a = 0.0
	process.color_ramp = _fade(start, end)
	return process


func _fade(from: Color, to: Color) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, from)
	gradient.set_color(1, to)
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


func _particle_material(soft: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	if soft:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## World-space particle emitter that stays put when the machine moves.
func _particles(amount: int, lifetime: float, mesh: Mesh, process: ParticleProcessMaterial) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.process_material = process
	particles.draw_pass_1 = mesh
	particles.emitting = false
	particles.top_level = true
	particles.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(particles)
	return particles


func _build_exhaust(parent: Node3D, pos: Vector3) -> GPUParticles3D:
	var stack := CylinderMesh.new()
	stack.top_radius = 0.06
	stack.bottom_radius = 0.07
	stack.height = 0.45
	stack.radial_segments = 8
	var pipe := MeshInstance3D.new()
	pipe.mesh = stack
	pipe.material_override = _material(DARK)
	pipe.position = pos + Vector3(0, 0.2, 0)
	parent.add_child(pipe)

	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 12.0
	process.initial_velocity_min = 1.2
	process.initial_velocity_max = 1.8
	process.gravity = Vector3(0.3, 0.6, 0)
	process.damping_min = 0.6
	process.damping_max = 0.9
	process.scale_min = 0.6
	process.scale_max = 1.0
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.3))
	grow.add_point(Vector2(1, 2.2))
	var grow_texture := CurveTexture.new()
	grow_texture.curve = grow
	process.scale_curve = grow_texture
	var fade := Gradient.new()
	fade.set_color(0, Color(0.18, 0.18, 0.2, 0.85))
	fade.set_color(1, Color(0.6, 0.6, 0.62, 0.0))
	var fade_texture := GradientTexture1D.new()
	fade_texture.gradient = fade
	process.color_ramp = fade_texture

	var puff := SphereMesh.new()
	puff.radius = 0.16
	puff.height = 0.32
	puff.radial_segments = 6
	puff.rings = 3
	var smoke := StandardMaterial3D.new()
	smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke.vertex_color_use_as_albedo = true
	smoke.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke.cull_mode = BaseMaterial3D.CULL_DISABLED
	puff.material = smoke

	var particles := GPUParticles3D.new()
	particles.amount = 40
	particles.lifetime = 2.2
	particles.process_material = process
	particles.draw_pass_1 = puff
	particles.position = pos + Vector3(0, 0.45, 0)
	particles.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 8, 8))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(particles)
	return particles


## Soil in the bucket. With the real model it's lofted through slices of the bucket's
## own cavity so it fits the scoop; the placeholder bucket gets a lumpy dome.
## Gravel shows grey in the bucket.
func _set_bucket_material(what: int) -> void:
	if what == bucket_material:
		return
	bucket_material = what
	if _heap:
		_heap.material_override = _material(Color(0.58, 0.56, 0.52) if what == Terrain.SURFACE_GRAVEL else SOIL)


func _build_load_visual() -> void:
	if _rig.has("cavity") and not (_rig.cavity.rings as Array).is_empty():
		_load_pivot = _node(_bucket, Vector3.ZERO)
		_heap = MeshInstance3D.new()
		_heap.set_meta("keep", true)
		_heap.material_override = _material(SOIL)
		_load_pivot.add_child(_heap)
		_load_pivot.visible = false
		return
	var opening: Vector3 = _rig.opening
	var heap: Dictionary = _rig.heap
	_load_pivot = _node(_bucket, (_rig.load_center as Vector3) - opening * float(heap.base))
	_load_pivot.basis = Basis(Quaternion(Vector3.UP, opening))
	var dome := SphereMesh.new()
	dome.radius = 1.0
	dome.height = 1.0
	dome.is_hemisphere = true
	dome.radial_segments = 16
	dome.rings = 6
	var arrays := dome.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var lumps := FastNoiseLite.new()
	lumps.frequency = 1.6
	for i in verts.size():
		if verts[i].y > 0.02:
			verts[i] *= 1.0 + lumps.get_noise_3dv(verts[i]) * 0.22
	arrays[Mesh.ARRAY_VERTEX] = verts
	var raw := ArrayMesh.new()
	raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tool := SurfaceTool.new()
	tool.create_from(raw, 0)
	tool.generate_normals()
	var instance := MeshInstance3D.new()
	instance.mesh = tool.commit()
	instance.material_override = _material(SOIL)
	_load_pivot.add_child(instance)
	_load_pivot.visible = false


func _update_load_visual() -> void:
	if _heap:
		_load_pivot.visible = bucket_load > 0.01
		var fill := clampf(bucket_load / _capacity, 0.0, 1.0) if _capacity > 0.0 else 0.0
		if _load_pivot.visible and absf(fill - _heap_fill) > 0.01:
			_heap_fill = fill
			_heap.mesh = _cavity_mesh(fill)
		return
	var heap: Dictionary = _rig.heap
	var radii: Vector2 = heap.radii
	_load_pivot.visible = bucket_load > 0.01
	var fill := clampf(bucket_load / maxf(_capacity, 0.01), 0.0, 1.0)
	var spread := 0.75 + 0.25 * fill
	_load_pivot.scale = Vector3(radii.x * spread, 0.05 + float(heap.height) * fill, radii.y * spread)


## Lofts soil from the back of the cavity up to the fill level, capped with a heaped top.
func _cavity_mesh(fill: float) -> ArrayMesh:
	var cavity: Dictionary = _rig.cavity
	var rings: Array[PackedVector2Array] = cavity.rings
	var depths: PackedFloat32Array = cavity.depths
	var e1: Vector3 = cavity.e1
	var e2: Vector3 = cavity.e2
	var u: Vector3 = cavity.u
	var top := fill * (rings.size() - 1)
	var layers: Array[PackedVector3Array] = []
	var centres: Array[Vector3] = []
	var steps := floori(top)
	for k in steps + 2:
		var level := minf(float(k), top)
		var i0 := mini(floori(level), rings.size() - 1)
		var i1 := mini(i0 + 1, rings.size() - 1)
		var t := level - i0
		var d := lerpf(depths[i0], depths[i1], t)
		var layer := PackedVector3Array()
		var centre := Vector3.ZERO
		for j in rings[i0].size():
			var q := rings[i0][j].lerp(rings[i1][j], t)
			var p := e1 * q.x + e2 * q.y + u * d
			layer.append(p)
			centre += p
		layers.append(layer)
		centres.append(centre / layer.size())
		if level >= top:
			break
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := layers[0].size()
	for j in n:
		var j1 := (j + 1) % n
		_tri(tool, centres[0], layers[0][j], layers[0][j1])
		for k in layers.size() - 1:
			_tri(tool, layers[k][j], layers[k + 1][j], layers[k + 1][j1])
			_tri(tool, layers[k][j], layers[k + 1][j1], layers[k][j1])
	# Heaped, lumpy top.
	var last := layers[layers.size() - 1]
	var peak := centres[centres.size() - 1] + u * (0.04 + 0.14 * fill)
	for j in n:
		var j1 := (j + 1) % n
		var a := last[j] + u * (sin(j * 1.7) * 0.02 * fill)
		var b := last[j1] + u * (sin(j1 * 1.7) * 0.02 * fill)
		_tri(tool, peak, b, a)
	tool.generate_normals()
	return tool.commit()


func _tri(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	tool.add_vertex(a)
	tool.add_vertex(b)
	tool.add_vertex(c)


func _build_placeholder() -> Dictionary:
	_box(_visual, Vector3(0.8, 0.8, 3.4), Vector3(-1.1, 0.4, 0), DARK)
	_box(_visual, Vector3(0.8, 0.8, 3.4), Vector3(1.1, 0.4, 0), DARK)
	_box(_visual, Vector3(1.4, 0.5, 2.2), Vector3(0, 0.6, 0), STEEL)
	var pivot := _node(_visual, Vector3(0, 0.85, 0))
	_box(pivot, Vector3(2.6, 0.9, 2.8), Vector3(0, 0.45, 0.3), YELLOW)
	_box(pivot, Vector3(2.6, 0.8, 0.6), Vector3(0, 0.5, 1.9), DARK.lerp(YELLOW, 0.35))
	_box(pivot, Vector3(1.0, 1.3, 1.2), Vector3(-0.75, 1.55, -0.55), YELLOW)
	_box(pivot, Vector3(1.04, 0.6, 1.24), Vector3(-0.75, 1.7, -0.55), GLASS)
	_box(pivot, Vector3(0.18, 0.7, 0.18), Vector3(0.9, 1.25, 1.1), DARK)
	var boom := _node(pivot, Vector3(0.35, 0.9, -1.2))
	_box(boom, Vector3(0.45, 0.55, 4.2), Vector3(0, 0, -2.1), YELLOW)
	var stick := _node(boom, Vector3(0, 0, -4.2))
	_box(stick, Vector3(0.35, 0.45, 3.0), Vector3(0, 0, -1.5), YELLOW)
	_box(stick, Vector3(0.5, 0.5, 0.5), Vector3.ZERO, DARK)
	var bucket := _node(stick, Vector3(0, 0, -3.0))
	_box(bucket, Vector3(1.2, 0.8, 0.08), Vector3(0, -0.4, -0.04), STEEL)
	_box(bucket, Vector3(1.2, 0.08, 1.0), Vector3(0, -0.8, -0.5), STEEL)
	_box(bucket, Vector3(0.08, 0.8, 1.0), Vector3(-0.6, -0.4, -0.5), STEEL)
	_box(bucket, Vector3(0.08, 0.8, 1.0), Vector3(0.6, -0.4, -0.5), STEEL)
	for k in 4:
		_box(bucket, Vector3(0.12, 0.08, 0.2), Vector3(-0.45 + k * 0.3, -0.8, -1.08), DARK)
	var block_points: Array[Vector3] = [Vector3(0, -0.8, 0.0), Vector3(0, -0.4, 0.0)]
	return {
		"cab": pivot, "boom": boom, "stick": stick, "bucket": bucket,
		"rest": Vector3(0.6, -1.5, 1.0),
		"boom_limits": Vector2(-0.6, 1.1),
		"stick_limits": Vector2(-2.6, -0.25),
		"bucket_limits": Vector2(-2.2, 2.4),
		"curl_sign": 1.0,
		"carve_points": [Vector3(0, -0.8, -1.0), Vector3(0, -0.8, -0.5)],
		"block_points": block_points,
		"opening": Vector3.UP,
		"load_center": Vector3(0, -0.55, -0.5),
		"hull": Vector3(2.9, 2.2, 3.4),
		"track": Vector2(1.6, 1.1),
		"door": Vector3(-1.4, 0.3, -0.5),
		"segments": [
			[boom, Vector3.ZERO, Vector3(0, 0, -4.2), 0.45, 0.55],
			[stick, Vector3.ZERO, Vector3(0, 0, -3.0), 0.35, 0.45],
			[bucket, Vector3(0, -0.42, 0), Vector3(0, -0.42, -1.05), 1.2, 0.85],
		],
		"pistons": [],
		"exhaust": Vector3(0.9, 1.6, 1.1),
		"eye": Transform3D(Basis.from_euler(Vector3(-0.22, -0.1, 0)), Vector3(-0.75, 1.75, -0.45)),
		"seat": Vector3(-0.75, 0.05, -0.35),
		"heap": {"radii": Vector2(0.54, 0.44), "base": 0.25, "height": 0.45},
	}


func _node(parent: Node3D, pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = pos
	parent.add_child(node)
	return node


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.material_override = _material(color)
	parent.add_child(instance)
	return instance


func _kinematic_body(parent: Node3D) -> AnimatableBody3D:
	var body := AnimatableBody3D.new()
	# Parent nodes move the arm, so push the global transform to physics every change.
	body.sync_to_physics = false
	body.collision_layer = ARM_LAYER
	body.collision_mask = 0
	parent.add_child(body)
	body.set_meta("uproots", true)  # tracks and arm tear out stumps they shove into
	return body


## A box collider running from a to b (parent-local, in the YZ plane) so the arm can smash things.
func _segment_body(parent: Node3D, a: Vector3, b: Vector3, width: float, thickness: float) -> void:
	var body := _kinematic_body(parent)
	var box := BoxShape3D.new()
	box.size = Vector3(width, thickness, (b - a).length())
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.transform = Transform3D(Basis(Vector3.RIGHT, ExcavatorModel.yz_angle(b - a)), (a + b) * 0.5)
	body.add_child(shape)


func _add_collision(body: CollisionObject3D, size: Vector3, pos: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = pos
	body.add_child(shape)


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		_materials[color] = mat
	return _materials[color]
