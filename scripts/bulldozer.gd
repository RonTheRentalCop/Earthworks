extends CharacterBody3D
## Tracked bulldozer. Wherever the blade's cutting edge drops below the surface it grades
## flat and the cut soil rolls along in front of the blade. Only an overloaded blade
## spills round its ends (mostly off the low end when the blade is tilted); lift the
## blade or reverse and the load drops as a pile.
## Level ground, fill holes, build ramps. The blade tilts for angled cuts and the rear
## ripper tears furrows that loosen ground and stumps. Heavy machine handling: slow to
## get going, slower uphill. The blade and hull are kinematic, so they shove debris,
## logs, freed stumps and stuck trucks. Mud slows it down.

const Terrain = preload("res://scripts/terrain.gd")
const MachineFx = preload("res://scripts/machine_fx.gd")
const ExcavatorModel = preload("res://scripts/excavator_model.gd")
const Winch = preload("res://scripts/winch.gd")
const Kit = preload("res://scripts/model_kit.gd")

const MAX_SPEED := 5.0
const ACCELERATION := 1.6
const DECELERATION := 4.0
const SLOPE_EFFECT := 2.2  # how much climbing slows it (and descending speeds it up)
const TILT_RATE := 0.25
const TILT_LIMIT := 0.15  # blade tilt (rad), left/right
const ANGLE_RATE := 0.5
const ANGLE_LIMIT := 0.5  # angle blade swing (rad, ~29 deg) each way
const SIDECAST := 0.9  # share of an angled blade's load that rolls off per metre pushed (at full angle)
const RIPPER_RATE := 0.6
const RIPPER_LIMITS := Vector2(-1.15, 0.1)  # -1.15 = raised, 0.1 = fully down
const RIPPER_TIP := Vector3(0, -1.3, 0.25)
const RIP_DRAG := 0.35
const RIP_RATE := 0.6  # m3/s the shanks can tear
const TURN_RATE := 0.85
const LIFT_RATE := 0.32
const PITCH_RATE := 0.5
const JOINT_RESPONSE := 6.0
const LIFT_LIMITS := Vector2(-0.35, 0.38)  # push-arm angle; negative digs the blade in
const PIT_DEPTH := 1.0  # deeper than this below natural ground, the blade works off the tracks
const PITCH_LIMITS := Vector2(-0.3, 0.3)
const DOZE_RATE := 7.0  # m3/s the blade can cut; ask for more and the dozer slows down
const CUT_BACK := 0.35  # the cut reaches this far behind the cutting edge (under the blade)
const CUT_FRONT := 0.12
const CAPACITY := 3.5  # m3 a size-1 blade can roll along (scales with the blade's area)
const DROP_RATE := 4.0  # m3/s the load drops when the blade lifts, stops or reverses
const LOAD_DRAG := 0.3  # top-speed loss with a full blade
const RUT_DEPTH := 0.03
const TRACK_WIDTH := 0.56
const TRACK_HALF := Vector2(1.7, 1.05)
const TRACK_SAMPLES := 7  # ground samples along each track
const CG_AHEAD := 0.25  # the blade puts the centre of gravity a little ahead of centre
const GRAVITY := 9.8
const TIP_STIFFNESS := 70.0  # how hard the hull rocks onto new ground...
const TIP_DAMPING := 13.0  # ...and how fast the rocking dies away
const SLIDE_START := 0.5  # slopes steeper than this (rad, ~29 deg) start to slide it downhill
const SLIDE_RATE := 7.0  # m/s of slide per radian past SLIDE_START
const TURN_ACCEL := 2.2  # rad/s2: a heavy machine takes a moment to start and stop turning
const PUSH_FORCE := 170000.0  # N it can shove a truck with
const MUD_SLOW := 0.55
const MUD_SINK := 0.22
const BODY_LAYER := 2
const ARM_LAYER := 8
const SOLID_MASK := 32 | 64  # trees, stumps, site buildings, trucks

const YELLOW := Color(0.96, 0.7, 0.1)
const DARK_YELLOW := Color(0.75, 0.52, 0.08)
const DARK := Color(0.16, 0.16, 0.17)
const STEEL := Color(0.42, 0.42, 0.44)
const GLASS := Color(0.15, 0.22, 0.3, 0.55)
const SOIL := Color(0.52, 0.31, 0.19)

var terrain: Terrain
var driven := false
## True builds only the model (shop thumbnails).
var preview := false
var mouse_input := {}
## Multiplayer: `remote` = driven by another player's controls (remote_axes, sent from
## their machine); `puppet` = a copy on a joining player's machine that follows the host.
var remote := false
var remote_axes := {}
var puppet := false
var _net_xform := Transform3D()
var _net_has := false
var _net_blade := Vector4.ZERO  # lift, pitch, tilt (or angle), ripper
var _th := TRACK_HALF  # track half-size in metres (scaled)
var _blade_width := 3.4  # in model units
var _angle := 0.0  # angle blade: yaw of the blade
var _net_tilt := Vector3.ZERO
var machine_name := "Bulldozer"
## Set before adding to the tree. "straight": a U-blade that carries everything forward
## (overflow piles up ahead of it); "angle": a blade the swing controls angle left/right,
## so soil rolls off its trailing end into a windrow beside the pass.
var blade_type := "straight"
## Model and machine scale (1 = a mid-size dozer).
var size := 1.45
## Blade proportions beyond the machine's size (a carry dozer's blade is far wider and
## taller than a standard one); capacity grows with both. Set before adding to the tree.
var blade_width_mult := 1.0
var blade_height_mult := 1.0
## Shown name (empty: "Bulldozer" / "Angle dozer").
var display_name := ""
var capacity := CAPACITY
var cab: Node3D
var eye: Node3D
var seat: Node3D
var blade_load := 0.0  # m3 of soil rolling in front of the blade
## Gravel or soil on the blade (pushing gravel out builds firm roads).
var blade_material := 0
var bogged := false
## How far (m) the tracks have sunk into mud, beyond the mud's own softness.
var bog := 0.0
var spilling := false
var winch: Winch
var ripping := false

var _speed := 0.0
var _turn := 0.0
var _vy := 0.0  # vertical speed while airborne (driving off a ledge)
var _tilt_rate := Vector2.ZERO  # pitch, roll angular speeds of the hull
var _ground_pitch := 0.0
var _ground_roll := 0.0
var _joint_velocity := Vector2.ZERO  # lift, pitch
var _visual: Node3D
var _arms: Node3D
var _blade: Node3D
## Grinder (mulcher) drum on the front of the blade: switched on, it grinds up standing
## trees, stumps, logs and loose stumps it reaches, paid for on the spot.
var grinder := false
var _grinder: Node3D
var _grind_timer := 0.0
var _grind_spin := 0.0
var _berm: Node3D
var _blade_shape: CollisionShape3D
var _cylinders: Array = []  # [rod node, base node, blade-local target]
var _tracks: Array[ShaderMaterial] = []
var _idlers: Array[Node3D] = []
var _track_travel := Vector2.ZERO
var _spawn := Transform3D.IDENTITY
var _engine := 0.0
var _time := 0.0
var _exhaust: GPUParticles3D
var _dust: GPUParticles3D
var _side_dust: Array[GPUParticles3D] = []
var _side_clods: Array[GPUParticles3D] = []
var _tilt := 0.0
var _ripper: Node3D
var _last_rip := Vector3.INF
var _platform: Node3D
var _platform_last := Transform3D()
var _dig_timer := 0.0
var _cut_rate := 0.0  # recent cutting rate, m3/s
var _last_rut := Transform3D()
var _materials := {}
var _spill_side := 0.0
var _sink_timer := 0.0  # which end soil is leaving (-1 left, 1 right, 0 none)


func _ready() -> void:
	_th = TRACK_HALF * size
	capacity = CAPACITY * size * size * (1.25 if blade_type == "straight" else 1.0) * blade_width_mult * blade_height_mult
	_blade_width = (3.9 if blade_type == "straight" else 4.2) * blade_width_mult
	machine_name = display_name if display_name != "" else ("Bulldozer" if blade_type == "straight" else "Angle dozer")
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_model()
	_visual.scale = Vector3.ONE * size
	Kit.merge_tree(_visual)
	if preview:
		_blade_shape = CollisionShape3D.new()
		_update_linkage()
		set_physics_process(false)
		return
	_add_collision(self, Vector3(2.6, 2.0, 3.6) * size, Vector3(0, 1.2, 0.1) * size)
	_blade_shape = _add_collision(self, Vector3(_blade_width, 1.0, 0.5), Vector3.ZERO)
	var hull := _kinematic_body(self)
	_add_collision(hull, Vector3(2.6, 2.0, 3.6) * size, Vector3(0, 1.2, 0.1) * size)
	var blade_body := _kinematic_body(_blade)
	_add_collision(blade_body, Vector3(_blade_width + 0.1, 1.2, 0.5), Vector3(0, 0, -0.05))
	_exhaust = MachineFx.exhaust(_visual, Vector3(0.55, 1.85, -1.0), _material(DARK))
	_dust = MachineFx.dust(self, Color(0.62, 0.46, 0.3), 30)
	for k in 2:
		_side_dust.append(MachineFx.dust(self, Color(0.6, 0.44, 0.28), 16))
		_side_clods.append(MachineFx.spray(self, SOIL.darkened(0.1)))
	winch = Winch.new()
	winch.vehicle = self
	winch.max_force = 180000.0 * size * size
	winch.position = Vector3(0, 1.55, 2.15) * size
	add_child(winch)
	add_to_group("winchable")
	set_meta("label", machine_name.to_lower())
	_spawn = global_transform
	_follow_ground(0.0, true)
	_update_linkage()


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	_ride_platform()
	_time += delta
	var start := global_position
	_drive(delta)
	_operate_blade(delta)
	_follow_ground(delta, false)
	_update_linkage()
	_rip(delta)
	var cut_share := _doze(delta)
	if grinder:
		_grind_timer -= delta
		if _grind_timer <= 0.0:
			_grind_timer = 0.2
			var main := get_parent()
			if main.has_method("grind_at"):
				main.grind_at(grinder_point(), grinder_reach(), self)
	if cut_share < 1.0:
		# The blade couldn't cut everything in its path: hold the dozer back so it never
		# rides over soil it hasn't cut. Heavy cuts therefore push slowly.
		var travel := global_position - start
		travel.y = 0.0
		global_position -= travel * (1.0 - cut_share)
		_speed *= 0.5 + 0.5 * cut_share
		_update_linkage()
	# Slipping tracks dig themselves into soft mud.
	_dig_timer -= delta
	if (bogged or cut_share < 0.8) and absf(_axis("drive_back", "drive_forward")) > 0.3 and _dig_timer <= 0.0:
		_dig_timer = 0.3
		for side in [-1.0, 1.0]:
			terrain.dig_in(global_position + global_basis.x * side * _th.y, -global_basis.z, _th.x, TRACK_WIDTH * size * 0.5, 0.03, 0.7)
	_rut()
	_sink_in(delta)
	_animate(delta)


## Heavy tracks slowly press down into soft mud (faster standing still); a deeply sunk
## dozer can only crawl. Mats, decks and gravel stay firm.
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
		bog = minf(bog + 0.5 * 0.025 * mud, 0.55 * mud)
	else:
		bog = maxf(bog - 0.5 * 0.03, 0.0)
	if winch.is_attached() and winch.tension > 1000.0:
		bog = maxf(bog - 0.5 * 0.1, 0.0)
	var press := 0.004 * mud * (2.0 if absf(_speed) < 0.2 else 1.0)
	for side in [-1.0, 1.0]:
		terrain.dig_in(global_position + global_basis.x * side * _th.y, -global_basis.z, _th.x,
				TRACK_WIDTH * size * 0.5, press, 0.3 + 0.5 * mud)


func _sunk_factor() -> float:
	if _platform != null:
		return 1.0
	return 1.0 - clampf((bog - 0.15) / 0.5, 0.0, 0.65)


## The tracks press ruts as the machine travels or turns.
func _rut() -> void:
	var moved := global_position.distance_to(_last_rut.origin)
	var turned := absf(global_basis.z.signed_angle_to(_last_rut.basis.z, Vector3.UP))
	if moved < 0.2 and turned < 0.05:
		return
	_last_rut = global_transform
	var fwd := -global_basis.z
	for side in [-1.0, 1.0]:
		terrain.press(global_position + global_basis.x * side * _th.y, fwd, _th.x + 0.3, TRACK_WIDTH * size * 0.5, RUT_DEPTH)


func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	bog = 0.0
	global_transform = xform
	_speed = 0.0
	_follow_ground(0.0, true)
	reset_physics_interpolation()


func door_position() -> Vector3:
	return to_global(Vector3(-1.5, 0.0, 0.8) * size)


## How hard each control is worked (steer, blade lift, -, blade pitch), for the operator's hands.
func controls() -> Vector4:
	return Vector4(_turn / TURN_RATE, _joint_velocity.x / LIFT_RATE, _speed / MAX_SPEED, _joint_velocity.y / PITCH_RATE)


## Controller rumble (weak, strong) for the current effort.
func rumble() -> Vector2:
	var push := blade_load / capacity
	return Vector2(0.15 + push * 0.4, 0.6 if bogged else push * 0.25) if driven else Vector2.ZERO


func status() -> String:
	var note := "   ⛏ BOGGED DOWN" if bogged else ("   ↔ SPILLING" if spilling else "")
	if ripping:
		note += "   ⚒ RIPPING"
	if winch.is_attached():
		note += "   ·   WINCH %.0f m" % winch.length
	return "%d km/h   ·   BLADE %.1f / %.1f m³%s" % [roundi(absf(_speed) * 3.6), blade_load, capacity, note]


func status_fill() -> float:
	return blade_load / capacity


## Multiplayer state (host -> joining players).
func net_state() -> Array:
	return [Vector4(_arms.rotation.x, _blade.rotation.x, _angle if blade_type == "angle" else _tilt, _ripper.rotation.x), _visual.rotation, blade_load,
		_track_travel, _speed, _joint_velocity, bogged, spilling, _cut_rate, driven, ripping, winch.net_state(), grinder]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_net_blade = s[0]
	_net_tilt = s[1]
	blade_load = s[2]
	_track_travel = s[3]
	_speed = s[4]
	_joint_velocity = s[5]
	bogged = s[6]
	spilling = s[7]
	_cut_rate = s[8]
	driven = s[9]
	ripping = s[10]
	winch.apply_net_state(s[11])
	if s.size() > 12 and bool(s[12]) != grinder:
		grinder = bool(s[12])
		_show_grinder()


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	_time += delta
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	_arms.rotation.x = lerpf(_arms.rotation.x, _net_blade.x, t)
	_blade.rotation.x = lerpf(_blade.rotation.x, _net_blade.y, t)
	if blade_type == "angle":
		_angle = lerpf(_angle, _net_blade.z, t)
		_blade.rotation.y = _angle
	else:
		_tilt = lerpf(_tilt, _net_blade.z, t)
		_blade.rotation.z = _tilt
	_ripper.rotation.x = lerpf(_ripper.rotation.x, _net_blade.w, t)
	_visual.rotation.x = lerp_angle(_visual.rotation.x, _net_tilt.x, t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, _net_tilt.z, t)
	_update_linkage()
	_animate(delta)


## What the HUD shows for this machine.
func hud_info() -> Dictionary:
	var info := {"speed": absf(_speed) * 3.6, "max_speed": MAX_SPEED * 3.6, "flags": ["U-BLADE" if blade_type == "straight" else "ANGLE %+d°" % roundi(rad_to_deg(_angle))],
		"load": blade_load / capacity, "load_text": "BLADE %.1f / %.1f m³" % [blade_load, capacity]}
	if grinder:
		info.flags.append("GRINDER ON")
	if bogged:
		info.flags.append("BOGGED")
	if bog > 0.15:
		info.flags.append("SUNK %.1f m" % bog)
	if blade_load >= capacity * 0.98 and blade_type == "straight":
		info.flags.append("FULL · LIFT BLADE")
	if spilling and blade_type == "angle":
		info.flags.append("WINDROWING")
	if ripping:
		info.flags.append("RIPPING")
	if winch.is_attached():
		info.flags.append("WINCH %.0f m" % winch.length)
	return info


func _axis(negative: StringName, positive: StringName) -> float:
	if not driven:
		return 0.0
	if remote:
		return clampf(float(remote_axes.get(positive, 0.0)) - float(remote_axes.get(negative, 0.0)), -1.0, 1.0)
	return clampf(Input.get_axis(negative, positive) + float(mouse_input.get(positive, 0.0)), -1.0, 1.0)


func _drive(delta: float) -> void:
	var mud := terrain.mud_at(global_position.x, global_position.z)
	var top := MAX_SPEED * (1.0 - MUD_SLOW * mud) * (1.0 - LOAD_DRAG * blade_load / capacity) * _sunk_factor()
	if ripping:
		top *= 1.0 - RIP_DRAG
	# Climbing slows it, descending lets it run on (pitch > 0 = nose up).
	var climb := _visual.rotation.x * signf(_speed if absf(_speed) > 0.1 else 1.0)
	top *= clampf(1.0 - climb * SLOPE_EFFECT, 0.35, 1.3)
	var target := _axis("drive_back", "drive_forward") * top
	var rate := ACCELERATION if absf(target) > absf(_speed) and signf(target) == signf(_speed) or is_zero_approx(_speed) else DECELERATION
	var on_ice := terrain.is_ice(global_position.x, global_position.z)
	if on_ice:
		rate *= 0.18  # the tracks spin on ice: slow to get going, slow to stop
	_speed = move_toward(_speed, target, rate * delta)
	# Steering has inertia, and a full blade (dragging on the ground) resists pivoting.
	var wanted_turn := _axis("turn_right", "turn_left") * TURN_RATE * (1.0 - 0.4 * mud) * (1.0 - 0.35 * blade_load / capacity)
	_turn = move_toward(_turn, wanted_turn * (0.6 if on_ice else 1.0), TURN_ACCEL * (0.3 if on_ice else 1.0) * delta)
	rotate_y(_turn * delta)
	_track_travel += Vector2(_speed - _turn * _th.y, _speed + _turn * _th.y) * delta
	velocity = -global_basis.z * _speed
	# Too steep: the tracks lose their bite and it slides down the slope.
	var steep := Vector2(maxf(absf(_ground_pitch) - SLIDE_START, 0.0), maxf(absf(_ground_roll) - SLIDE_START * 0.85, 0.0))
	if steep.length() > 0.0 and _vy == 0.0:
		velocity += global_basis.z * signf(_ground_pitch) * steep.x * SLIDE_RATE
		velocity += -global_basis.x * signf(_ground_roll) * steep.y * SLIDE_RATE
		if signf(_speed) == signf(_ground_pitch) and steep.x > 0.08:
			_speed = move_toward(_speed, 0.0, DECELERATION * delta)  # can't climb a wall
	move_and_slide()
	# Shove trucks we drive into, rather than stopping dead against them.
	for k in get_slide_collision_count():
		var hit := get_slide_collision(k)
		var body := hit.get_collider() as RigidBody3D
		if body and absf(_speed) > 0.05:
			var dir := -global_basis.z * signf(_speed)
			dir.y = 0.0
			body.apply_central_impulse(dir.normalized() * PUSH_FORCE * size * size * size * delta * clampf(absf(_speed), 0.3, 1.0))
			body.set_meta("winched_until", Time.get_ticks_msec() + 300)  # brakes off while it's shoved
			_speed *= 0.985
	global_position = terrain.clamp_inside(global_position, 3.0)


func _operate_blade(delta: float) -> void:
	var target := Vector2(_axis("boom_down", "boom_up") * LIFT_RATE, _axis("bucket_dump", "bucket_curl") * PITCH_RATE)
	_joint_velocity = _joint_velocity.lerp(target, 1.0 - exp(-JOINT_RESPONSE * delta))
	_arms.rotation.x = clampf(_arms.rotation.x + _joint_velocity.x * delta, LIFT_LIMITS.x, LIFT_LIMITS.y)
	_blade.rotation.x = clampf(_blade.rotation.x + _joint_velocity.y * delta, PITCH_LIMITS.x, PITCH_LIMITS.y)
	if blade_type == "angle":
		_angle = clampf(_angle + _axis("swing_right", "swing_left") * ANGLE_RATE * delta, -ANGLE_LIMIT, ANGLE_LIMIT)
		_blade.rotation.y = _angle
	else:
		_tilt = clampf(_tilt + _axis("swing_right", "swing_left") * TILT_RATE * delta, -TILT_LIMIT, TILT_LIMIT)
		_blade.rotation.z = _tilt
	_ripper.rotation.x = clampf(_ripper.rotation.x + _axis("stick_out", "stick_in") * RIPPER_RATE * delta, RIPPER_LIMITS.x, RIPPER_LIMITS.y)


## The tracks are rigid beams: each rests on the highest ground under it (the upper hull
## of the samples along it, at the centre of gravity), so the dozer bridges dips, rocks
## forward over a crest, falls off ledges under gravity and settles with a little bounce.
func _follow_ground(delta: float, instant: bool) -> void:
	var fwd := -global_basis.z
	var side := global_basis.x
	var p := global_position
	_check_platform(p)
	var rest: Array[Vector2] = []  # per track: (height at the CG, pitch)
	for s in [-1.0, 1.0]:
		var pts: Array[Vector2] = []
		for k in TRACK_SAMPLES:
			var u := lerpf(-_th.x, _th.x, k / float(TRACK_SAMPLES - 1))
			pts.append(Vector2(u, _support(p + fwd * u + side * s * (_th.y - TRACK_WIDTH * size * 0.35))))
		rest.append(_rest_on(pts, CG_AHEAD * size))
	var height := (rest[0].x + rest[1].x) * 0.5
	var pitch := (rest[0].y + rest[1].y) * 0.5
	var roll := atan2(rest[1].x - rest[0].x, 2.0 * _th.y)
	_ground_pitch = pitch
	_ground_roll = roll
	var target := height - (0.0 if _platform != null else MUD_SINK * terrain.mud_at(p.x, p.z) + bog)
	if instant:
		global_position.y = target
		_vy = 0.0
		_tilt_rate = Vector2.ZERO
		_visual.rotation.x = pitch
		_visual.rotation.z = roll
		return
	if p.y > target + 0.05:
		# Airborne: fall under gravity, land with a thump.
		_vy -= GRAVITY * delta
		global_position.y = maxf(p.y + _vy * delta, target)
		if global_position.y <= target:
			if _vy < -3.0:
				_dust.restart()
			_tilt_rate.x += _vy * 0.08
			_vy = 0.0
	else:
		_vy = 0.0
		global_position.y = lerpf(p.y, target, 1.0 - exp(-14.0 * delta))
	# Rock onto the ground like a heavy body on a spring.
	var current := Vector2(_visual.rotation.x, _visual.rotation.z)
	var aim := Vector2(pitch, roll)
	_tilt_rate += ((aim - current) * TIP_STIFFNESS - _tilt_rate * TIP_DAMPING) * delta
	current += _tilt_rate * delta
	_visual.rotation.x = current.x
	_visual.rotation.z = current.y


## Where a rigid track resting on the points (along-track position, ground height) sits:
## the segment of their upper hull under `cg`. Returns (height at the CG, pitch).
func _rest_on(pts: Array[Vector2], cg: float) -> Vector2:
	var hull: Array[Vector2] = []
	for q in pts:
		while hull.size() >= 2:
			var a := hull[hull.size() - 2]
			var b := hull[hull.size() - 1]
			# Drop b if it lies on or under the line from a to q (keep the upper hull).
			if (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) >= 0.0:
				hull.pop_back()
			else:
				break
		hull.append(q)
	for k in hull.size() - 1:
		var a := hull[k]
		var b := hull[k + 1]
		if cg >= a.x and cg <= b.x:
			var slope := (b.y - a.y) / maxf(b.x - a.x, 0.001)
			return Vector2(a.y + slope * (cg - a.x), atan(slope))
	return Vector2(hull[0].y, 0.0)


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


## Grades flat along the whole cutting edge and spreads what it cut evenly in a berm just
## ahead, which the blade keeps pushing as the dozer drives on. Returns the share of the
## soil in the blade's path that it managed to cut this frame (1 = all of it).
func _doze(delta: float) -> float:
	var budget := DOZE_RATE * size * size * delta
	var half_edge := _blade_width * 0.5
	var left := _blade.to_global(Vector3(-half_edge, -0.58, -0.14))
	var right := _blade.to_global(Vector3(half_edge, -0.58, -0.14))
	var fwd := -global_basis.z
	# Grade control: the blade cuts a set depth (where the operator has put it) below the
	# natural ground, so holding it down cuts a flat trench of constant depth rather than
	# a ramp, and the edge stays level across its width. Down in a pit the depth is
	# measured from the ground under the tracks instead.
	var centre_xz := left.lerp(right, 0.5)
	var reference := terrain.original_height(centre_xz.x, centre_xz.z)
	var rear := global_position + global_basis.z * _th.x
	var tracks := (_ground(rear + global_basis.x * _th.y) + _ground(rear - global_basis.x * _th.y)) * 0.5
	if reference - tracks > PIT_DEPTH:
		reference = tracks
	var edge := reference + _edge_offset()
	# Tilting the blade raises one end and drops the other.
	left.y = edge - sin(_tilt) * half_edge * size
	right.y = edge + sin(_tilt) * half_edge * size
	var edge_mid := left.lerp(right, 0.5) + fwd * 0.3 * size
	var cutting_gravel := terrain.is_gravel(edge_mid.x, edge_mid.z)
	terrain.digger = self
	var removed := terrain.cut_flat(left, right, fwd, CUT_BACK * size, CUT_FRONT * size, budget)
	terrain.digger = null
	if removed > blade_load * 0.5 and removed > 0.001:
		blade_material = Terrain.SURFACE_GRAVEL if cutting_gravel else Terrain.SURFACE_SOIL
	blade_load += removed
	var share := 1.0 if terrain.last_cut_wanted <= 0.0 else clampf(removed / terrain.last_cut_wanted, 0.0, 1.0)
	bogged = share < 0.5
	_cut_rate = lerpf(_cut_rate, removed / delta, 1.0 - exp(-4.0 * delta))
	var pushed := maxf(_speed, 0.0) * delta
	var spill := 0.0
	if blade_type == "angle":
		# An angled blade sheds its load off the trailing end as it moves: a windrow.
		var shed := SIDECAST * pushed * absf(sin(_angle)) / sin(ANGLE_LIMIT)
		spill = blade_load * clampf(shed, 0.0, 1.0) + maxf(blade_load - capacity, 0.0)
		spill = minf(spill, blade_load)
		if spill > 0.0005:
			blade_load -= spill
			# The trailing end is the one swept back; drop the soil just outside it.
			var trailing := -1.0 if _angle > 0.0 else 1.0
			var p := _blade.to_global(Vector3(trailing * (half_edge + 0.7), -0.58, 0.2))
			terrain.deposit(p.x, p.z, spill, 0.9 * size, blade_material)
		_spill_side = -1.0 if _angle > 0.0 else 1.0
	else:
		# The U-blade's wings hold everything: what won't fit rolls over the top of the
		# heap and piles up just ahead, so the blade keeps pushing it.
		spill = maxf(blade_load - capacity, 0.0)
		if spill > 0.0005:
			blade_load -= spill
			terrain.deposit_strip(left, right, fwd, 0.6 * size, 0.9 * size, spill, blade_material)
		_spill_side = 0.0
	spilling = spill > 0.002
	# Lift the blade clear or reverse and the load drops in front as a pile.
	var centre := left.lerp(right, 0.5)
	var lifted := _blade.to_global(Vector3(0, -0.58, -0.14)).y > _ground(centre) + 0.15
	if blade_load > 0.0 and (lifted or _speed < -0.1):
		var drop := minf(blade_load, DROP_RATE * size * size * delta)
		blade_load -= drop
		terrain.deposit_strip(left, right, fwd, 0.15 * size, 1.1 * size, drop, blade_material)
	return share


## Ripper shanks dragged through the ground tear furrows (soil heaped either side),
## loosening it; ripping round a stump frees it.
func _rip(delta: float) -> void:
	ripping = false
	if absf(_speed) < 0.05:
		return
	var tips: Array[Vector3] = []
	for x in [-0.65, 0.0, 0.65]:
		tips.append(_ripper.to_global(RIPPER_TIP + Vector3(x, 0, 0)))
	for tip in tips:
		if tip.y < _ground(tip) - 0.05:
			ripping = true
	if not ripping or global_position.distance_to(_last_rip) < 0.12:
		return
	_last_rip = global_position
	var side := global_basis.x
	for tip in tips:
		var cut := terrain.dig(tip, 0.24 * size, RIP_RATE * size * delta * 4.0)
		if cut > 0.0:
			for s in [-1.0, 1.0]:
				var heap: Vector3 = tip + side * (0.32 * size * s)
				terrain.deposit(heap.x, heap.z, cut * 0.5, 0.28 * size)


func toggle_grinder() -> String:
	grinder = not grinder
	_show_grinder()
	return "Grinder ON  ·  drive into trees, stumps and logs to grind them for cash" if grinder else "Grinder OFF"


## The middle of the grinder drum (world space) and how far round it it grinds.
func grinder_point() -> Vector3:
	return _blade.to_global(Vector3(0, -0.15, -0.95))


func grinder_reach() -> float:
	return _blade_width * 0.5 * size * 0.9 + 0.4


func _show_grinder() -> void:
	if _grinder == null:
		var dark := Kit.paint(Color(0.14, 0.14, 0.15), 0.6, 0.3)
		var steel := Kit.metal(Color(0.6, 0.6, 0.62))
		var orange := Kit.paint(Color(0.95, 0.5, 0.08))
		_grinder = Node3D.new()
		_grinder.position = Vector3(0, -0.15, -0.95)
		_blade.add_child(_grinder)
		var length := _blade_width * 0.92
		var drum := Node3D.new()
		drum.name = "Drum"
		_grinder.add_child(drum)
		Kit.axle(drum, 0.42, length, Vector3.ZERO, dark, 18)
		for k in 10:
			var a := TAU * k / 10.0
			for j in int(length / 0.45):
				var x := -length * 0.5 + 0.22 + j * 0.45 + (0.2 if k % 2 == 0 else 0.0)
				if absf(x) < length * 0.5 - 0.1:
					Kit.box(drum, Vector3(0.08, 0.16, 0.08), Vector3(x, cos(a), sin(a)) * 0.5 + Vector3(x, 0, 0) * 0.0, steel, 0.0)
		# Hood over the top and side plates bolted to the blade.
		Kit.box(_grinder, Vector3(length + 0.2, 0.08, 0.9), Vector3(0, 0.55, 0.15), orange, 0.03)
		for side in [-1.0, 1.0]:
			Kit.box(_grinder, Vector3(0.08, 0.9, 1.0), Vector3(side * (length * 0.5 + 0.1), 0.1, 0.25), orange, 0.02)
	_grinder.visible = grinder


## Ore the blade cuts out rolls up in front of it, to be pushed along with the soil.
func take_ore(kind: String) -> bool:
	var main := get_parent()
	if not main.has_method("spawn_ore"):
		return false
	var at := _blade.to_global(Vector3(randf_range(-0.8, 0.8) * size, 0.0, -0.9 * size))
	at.y = terrain.get_height(at.x, at.z) + 0.5
	main.spawn_ore(kind, Transform3D(Basis(Vector3.UP, randf() * TAU), at))
	return true


## Height of the cutting edge above the tracks with the machine sitting level.
func _edge_offset() -> float:
	var arms := Transform3D(Basis(Vector3.RIGHT, _arms.rotation.x), _arms.position)
	var blade := Transform3D(Basis(Vector3.RIGHT, _blade.rotation.x), _blade.position)
	return (arms * blade * Vector3(0, -0.58, -0.14)).y * size


func _update_linkage() -> void:
	if grinder and _grinder:
		_grind_spin += 0.35
		(_grinder.get_node("Drum") as Node3D).rotation.x = -_grind_spin
	_blade_shape.transform = global_transform.affine_inverse() * _blade.global_transform
	for c in _cylinders:
		var rod: Node3D = c[0]
		var base: Node3D = c[1]
		var from := base.global_position
		var to := _blade.to_global(c[2])
		var dir := to - from
		var up := dir.normalized()
		var side := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
		rod.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(size, dir.length(), size)), from)


func _animate(delta: float) -> void:
	var loop := (2.0 * (TRACK_HALF.x * 2.0 - 0.2) + TAU * 0.38) * size
	_track_travel = Vector2(fposmod(_track_travel.x, loop), fposmod(_track_travel.y, loop))
	_tracks[0].set_shader_parameter("scroll", -_track_travel.x / size)
	_tracks[1].set_shader_parameter("scroll", -_track_travel.y / size)
	for i in _idlers.size():
		_idlers[i].rotation.x = -(_track_travel.x if i < _idlers.size() / 2 else _track_travel.y) / (0.36 * size)
	var effort := clampf(blade_load / capacity, 0.0, 1.0)
	_berm.visible = blade_load > 0.05
	var depth := 0.35 + 0.75 * effort
	_berm.scale = Vector3(1.65, 0.2 + 0.85 * effort, depth)
	_berm.position = Vector3(0, -0.6, -0.2 - depth * 0.55)
	var work := clampf(absf(_speed) / MAX_SPEED + effort + absf(_joint_velocity.x) * 2.0, 0.0, 1.0) if driven else 0.0
	_engine = lerpf(_engine, work, 1.0 - exp(-3.0 * delta))
	var shake := (0.003 + 0.008 * _engine) * sin(_time * 70.0) if driven else 0.0
	if bogged:
		shake += 0.02 * sin(_time * 37.0)
	_visual.position.y = shake
	_exhaust.amount_ratio = 0.25 + 0.75 * _engine if driven else 0.08
	_dust.global_position = _blade.to_global(Vector3(0, -0.3, -0.8))
	_dust.emitting = _cut_rate > 0.6
	for k in 2:
		var end := -1.0 if k == 0 else 1.0
		_side_dust[k].global_position = _blade.to_global(Vector3((_blade_width * 0.5 + 0.6) * end, -0.4, 0.1))
		_side_dust[k].emitting = spilling and _spill_side == end
		# Clods tumble outward off the blade end.
		_side_clods[k].global_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5 * end) * global_basis, _blade.to_global(Vector3(_blade_width * 0.5 * end, -0.1, -0.5)))
		_side_clods[k].emitting = spilling and _spill_side == end and effort > 0.2


func _build_model() -> void:
	_visual = _node(self, Vector3.ZERO)
	cab = _visual
	var paint := Kit.paint(YELLOW)
	var paint_dark := Kit.paint(DARK_YELLOW)
	var dark := Kit.paint(DARK, 0.6, 0.25)
	var steel := Kit.metal(STEEL)
	var black := Kit.matte(Color(0.07, 0.07, 0.08))

	# --- Undercarriage: track frames, bottom and carrier rollers, idler, sprocket, shoes.
	for side in [-1.0, 1.0]:
		var x: float = side * TRACK_HALF.y
		Kit.box(_visual, Vector3(0.36, 0.34, 3.0), Vector3(x, 0.42, 0), dark, 0.05)
		for k in 6:
			Kit.axle(_visual, 0.13, 0.4, Vector3(x, 0.2, -1.2 + k * 0.48), steel, 12)
		for z in [-0.6, 0.6]:
			Kit.axle(_visual, 0.09, 0.3, Vector3(x, 0.68, z), steel, 10)
		for z in [-1.6, 1.6]:
			var wheel := _node(_visual, Vector3(x, 0.38, z))
			Kit.axle(wheel, 0.32, 0.44, Vector3.ZERO, steel, 18)
			Kit.axle(wheel, 0.18, 0.48, Vector3.ZERO, dark, 12)
			if z > 0.0:  # drive sprocket teeth
				for k in 10:
					var a := TAU * k / 10.0
					Kit.box(wheel, Vector3(0.12, 0.1, 0.08), Vector3(0, cos(a), sin(a)) * 0.34, dark, 0.02).rotation.x = a
			_idlers.append(wheel)
		_tracks.append(MachineFx.track(_visual, x, -1.6, 1.6, 0.38, 0.38, 0.56, Color(0.15, 0.15, 0.16)))
		Kit.box(_visual, Vector3(0.66, 0.06, 3.5), Vector3(x, 0.9, 0.05), paint_dark, 0.03)  # track guard

	# --- Frame, engine hood with vents, radiator guard.
	Kit.box(_visual, Vector3(1.5, 0.5, 3.4), Vector3(0, 0.85, 0), dark, 0.05)
	var hood := PackedVector2Array([Vector2(-1.78, 1.0), Vector2(-1.78, 1.86), Vector2(-1.62, 1.98), Vector2(0.15, 2.06), Vector2(0.15, 1.0)])
	Kit.add(_visual, Kit.prism(hood, 1.92), Vector3.ZERO, paint)
	for side in [-1.0, 1.0]:
		for k in 5:
			Kit.box(_visual, Vector3(0.03, 0.06, 1.2), Vector3(side * 0.97, 1.25 + k * 0.13, -0.75), black, 0.01)
		Kit.label(_visual, "EARTHWORKS", Vector3(side * 0.97, 1.95, -0.85), 0.0028, Color(0.1, 0.1, 0.1), PI * 0.5 * side)
	Kit.box(_visual, Vector3(1.75, 0.95, 0.12), Vector3(0, 1.42, -1.83), dark, 0.04)
	for row in 5:
		for col in 7:
			Kit.box(_visual, Vector3(0.18, 0.1, 0.03), Vector3(-0.66 + col * 0.22, 1.12 + row * 0.15, -1.9), black, 0.0)
	Kit.box(_visual, Vector3(2.5, 0.12, 3.4), Vector3(0, 1.0, 0.1), paint_dark, 0.03)  # fenders / walkways
	var cleaner := Kit.add(_visual, Kit.cylinder(0.14, 0.36, 12), Vector3(-0.55, 2.24, -0.9), black)
	Kit.add(_visual, Kit.sphere(0.15, 10, true), cleaner.position + Vector3(0, 0.18, 0), black)

	# --- Cab: roll-over frame, glass all round, roof with work lights, seat and levers.
	Kit.box(_visual, Vector3(2.0, 0.6, 1.6), Vector3(0, 1.3, 0.95), paint, 0.05)
	for cx in [-0.86, 0.86]:
		for cz in [0.18, 1.72]:
			Kit.box(_visual, Vector3(0.12, 1.55, 0.12), Vector3(cx, 2.35, cz), paint, 0.04)
	Kit.box(_visual, Vector3(2.14, 0.16, 1.9), Vector3(0, 3.14, 0.95), paint, 0.06)
	Kit.box(_visual, Vector3(1.9, 0.06, 1.7), Vector3(0, 3.05, 0.95), dark, 0.02)
	for pane in [[Vector3(1.62, 1.35, 0.02), Vector3(0, 2.35, 0.18)], [Vector3(1.62, 1.35, 0.02), Vector3(0, 2.35, 1.72)],
			[Vector3(0.02, 1.35, 1.44), Vector3(-0.86, 2.35, 0.95)], [Vector3(0.02, 1.35, 1.44), Vector3(0.86, 2.35, 0.95)]]:
		Kit.box(_visual, pane[0], pane[1], Kit.glass(), 0.0)
	for x in [-0.86, 0.86]:
		Kit.box(_visual, Vector3(0.04, 0.04, 0.18), Vector3(x * 1.02, 2.1, 0.9), steel, 0.015)
	for corner in [Vector3(-0.85, 3.25, 0.12), Vector3(0.85, 3.25, 0.12), Vector3(-0.85, 3.25, 1.78), Vector3(0.85, 3.25, 1.78)]:
		Kit.box(_visual, Vector3(0.2, 0.13, 0.1), corner, Kit.glow(Color(1, 0.97, 0.85), 1.8), 0.03)
	Kit.add(_visual, Kit.sphere(0.1, 10, true), Vector3(0.6, 3.22, 1.4), Kit.glow(Color(1.0, 0.55, 0.05), 2.2))
	Kit.box(_visual, Vector3(0.55, 0.15, 0.55), Vector3(0, 1.75, 1.15), dark, 0.05)
	Kit.box(_visual, Vector3(0.55, 0.7, 0.12), Vector3(0, 2.1, 1.42), dark, 0.05)
	for x in [-0.32, 0.32]:
		Kit.add(_visual, Kit.cylinder(0.02, 0.3, 6), Vector3(x, 1.95, 0.95), black)
		Kit.add(_visual, Kit.sphere(0.04, 8), Vector3(x, 2.1, 0.95), black)
	# --- Rear: fuel tank, lights, steps and handrails.
	Kit.box(_visual, Vector3(1.9, 0.7, 0.45), Vector3(0, 1.3, 1.95), paint_dark, 0.06)
	for side in [-1.0, 1.0]:
		Kit.box(_visual, Vector3(0.22, 0.12, 0.05), Vector3(side * 0.75, 1.5, 2.19), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
		Kit.box(_visual, Vector3(0.35, 0.05, 0.28), Vector3(side * 1.3, 0.75, 0.9), steel, 0.015)
		Kit.box(_visual, Vector3(0.35, 0.05, 0.28), Vector3(side * 1.3, 1.1, 0.9), steel, 0.015)
		Kit.beam(_visual, Vector3(side * 0.95, 2.08, -1.4), Vector3(side * 0.95, 2.08, 0.1), 0.045, steel)
		Kit.beam(_visual, Vector3(side * 0.95, 2.0, -1.4), Vector3(side * 0.95, 2.08, -1.4), 0.045, steel)
		Kit.beam(_visual, Vector3(side * 1.2, 1.05, 0.25), Vector3(side * 1.2, 2.3, 0.25), 0.045, steel)
	eye = _node(_visual, Vector3(0, 2.85, 0.55))
	eye.rotation.x = -0.42
	seat = _node(_visual, Vector3(0, 0.95, 1.12))

	# --- Push arms on trunnions, and the curved moldboard blade.
	_arms = _node(_visual, Vector3(0, 0.55, -0.2))
	for side in [-1.0, 1.0]:
		Kit.axle(_arms, 0.14, 0.3, Vector3(side * 1.2, 0, 0), dark)
		if blade_type == "straight":
			Kit.beam(_arms, Vector3(side * 1.2, 0, 0), Vector3(side * 1.32, 0.05, -2.3), 0.22, paint_dark)
			Kit.beam(_arms, Vector3(side * 1.25, 0.02, -1.4), Vector3(side * 0.7, 0.3, -2.3), 0.12, paint_dark)
	_blade = _node(_arms, Vector3(0, 0.025, -2.4 if blade_type == "straight" else -2.7))
	if blade_type == "straight":
		_build_u_blade(paint, paint_dark, steel)
	else:
		_build_angle_blade(paint, paint_dark, steel, dark)
	_blade.scale.y = blade_height_mult  # a high-wall blade (its soil heap grows with it)
	# Soil heaped on the blade face while pushing.
	_berm = _node(_blade, Vector3(0, -0.6, -0.6))
	_berm.scale = Vector3(_blade_width / 3.4, 1, 1)
	var dome := SphereMesh.new()
	dome.radius = 1.0
	dome.height = 1.0
	dome.is_hemisphere = true
	dome.radial_segments = 18
	dome.rings = 6
	var arrays := dome.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var lumps := FastNoiseLite.new()
	lumps.frequency = 2.2
	for i in verts.size():
		if verts[i].y > 0.02:
			verts[i] *= 1.0 + lumps.get_noise_3dv(verts[i]) * 0.25
	arrays[Mesh.ARRAY_VERTEX] = verts
	var raw := ArrayMesh.new()
	raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tool := SurfaceTool.new()
	tool.create_from(raw, 0)
	tool.generate_normals()
	var heap := MeshInstance3D.new()
	heap.mesh = tool.commit()
	heap.material_override = Kit.matte(SOIL)
	_berm.add_child(heap)
	_berm.visible = false
	# Lift rams from the hood to the back of the blade.
	for side in [-1.0, 1.0]:
		var base := _node(_visual, Vector3(side * 0.75, 1.6, -1.45))
		Kit.axle(base, 0.1, 0.2, Vector3.ZERO, dark)
		var rod := _node(_visual, Vector3.ZERO)
		Kit.add(rod, Kit.cylinder(0.1, 0.55, 12), Vector3(0, 0.28, 0), dark)
		Kit.add(rod, Kit.cylinder(0.055, 1.0, 10), Vector3(0, 0.5, 0), Kit.metal(Color(0.85, 0.85, 0.88)))
		_cylinders.append([rod, base, Vector3(side * 0.75, 0.35, 0.12)])

	# --- Rear ripper: frame on a pivot with three shanks and lift rams.
	_ripper = _node(_visual, Vector3(0, 0.8, 2.1))
	_ripper.rotation.x = RIPPER_LIMITS.x
	Kit.box(_ripper, Vector3(1.8, 0.24, 0.32), Vector3(0, -0.1, 0.15), paint_dark, 0.05)
	for x in [-0.65, 0.0, 0.65]:
		Kit.box(_ripper, Vector3(0.13, 1.25, 0.22), Vector3(x, -0.7, 0.25), paint_dark, 0.04)
		Kit.box(_ripper, Vector3(0.11, 0.14, 0.32), Vector3(x, -1.28, 0.12), Kit.metal(Color(0.3, 0.3, 0.32)), 0.03)
	for side in [-1.0, 1.0]:
		Kit.beam(_visual, Vector3(side * 0.7, 1.05, 2.0), Vector3(side * 0.7, 0.75, 2.35), 0.1, steel)


## Semi-U blade: a deep curved moldboard with wings turned forward at the ends, so the
## load can't escape sideways.
func _build_u_blade(paint: Material, paint_dark: Material, steel: Material) -> void:
	var w := _blade_width
	var face := [Vector2(-0.2, -0.58), Vector2(-0.04, -0.3), Vector2(0.06, 0.02), Vector2(0.04, 0.36), Vector2(-0.08, 0.62), Vector2(-0.28, 0.78)]
	var moldboard := PackedVector2Array()
	for p in face:
		moldboard.append(p)
	for k in range(face.size() - 1, -1, -1):
		moldboard.append(face[k] + Vector2(0.14, 0.0))
	Kit.add(_blade, Kit.prism(moldboard, w - 0.8), Vector3.ZERO, paint)
	for side in [-1.0, 1.0]:
		# Wings: the outer 0.45 m of the blade turned forward ~25 degrees.
		var wing := _node(_blade, Vector3(side * (w * 0.5 - 0.4), 0, 0))
		wing.rotation.y = -0.45 * side
		Kit.add(wing, Kit.prism(moldboard, 0.85), Vector3(side * 0.42, 0, 0), paint)
		Kit.box(wing, Vector3(0.9, 0.1, 0.22), Vector3(side * 0.42, -0.58, -0.12), Kit.metal(Color(0.3, 0.3, 0.32)), 0.03)
		Kit.box(wing, Vector3(0.1, 1.45, 0.55), Vector3(side * 0.86, 0.08, -0.04), paint, 0.04)
		Kit.box(_blade, Vector3(0.22, 0.16, 0.26), Vector3(side * (w * 0.5 - 0.5), -0.56, -0.18), Kit.metal(Color(0.3, 0.3, 0.32)), 0.04)
	Kit.box(_blade, Vector3(w - 0.75, 0.1, 0.22), Vector3(0, -0.58, -0.12), Kit.metal(Color(0.3, 0.3, 0.32)), 0.03)
	for k in 6:
		Kit.box(_blade, Vector3(0.08, 1.15, 0.14), Vector3(-1.25 + k * 0.5, 0.05, 0.2), paint_dark, 0.03)
	Kit.box(_blade, Vector3(w - 0.8, 0.06, 0.14), Vector3(0, 0.8, -0.26), Kit.hazard(), 0.02)
	# Spill guard (rock guard) on top, and the tilt ram.
	for x in [-0.9, 0.0, 0.9]:
		Kit.beam(_blade, Vector3(x, 0.78, -0.22), Vector3(x, 1.35, 0.15), 0.07, paint_dark)
	Kit.beam(_blade, Vector3(-1.1, 1.33, 0.14), Vector3(1.1, 1.33, 0.14), 0.07, paint_dark)
	Kit.beam(_arms, Vector3(0.9, 0.35, -1.0), Vector3(0.75, 0.6, -2.3), 0.09, steel)  # tilt ram


## Angle blade: a long, lower blade on a C-frame that wraps round the front of the
## machine, with a centre pivot and an angling ram each side.
func _build_angle_blade(paint: Material, paint_dark: Material, steel: Material, dark: Material) -> void:
	var w := _blade_width
	var face := [Vector2(-0.16, -0.58), Vector2(-0.03, -0.32), Vector2(0.04, -0.04), Vector2(0.02, 0.22), Vector2(-0.1, 0.42)]
	var moldboard := PackedVector2Array()
	for p in face:
		moldboard.append(p)
	for k in range(face.size() - 1, -1, -1):
		moldboard.append(face[k] + Vector2(0.12, 0.0))
	Kit.add(_blade, Kit.prism(moldboard, w), Vector3.ZERO, paint)
	Kit.box(_blade, Vector3(w + 0.04, 0.1, 0.2), Vector3(0, -0.58, -0.1), Kit.metal(Color(0.3, 0.3, 0.32)), 0.03)
	for side in [-1.0, 1.0]:
		Kit.box(_blade, Vector3(0.08, 1.0, 0.4), Vector3(side * w * 0.5, -0.08, -0.02), paint, 0.03)
		Kit.box(_blade, Vector3(0.24, 0.16, 0.24), Vector3(side * (w * 0.5 - 0.1), -0.56, -0.16), Kit.metal(Color(0.3, 0.3, 0.32)), 0.04)
	for k in 7:
		Kit.box(_blade, Vector3(0.07, 0.8, 0.12), Vector3(-w * 0.5 + 0.4 + k * (w - 0.8) / 6.0, -0.05, 0.16), paint_dark, 0.03)
	Kit.box(_blade, Vector3(w, 0.06, 0.12), Vector3(0, 0.44, -0.14), Kit.hazard(), 0.02)
	# Centre pivot casting on the back of the blade.
	Kit.axle(_blade, 0.2, 0.5, Vector3(0, -0.2, 0.35), dark)
	Kit.box(_blade, Vector3(0.7, 0.5, 0.3), Vector3(0, -0.2, 0.25), paint_dark, 0.05)
	# The C-frame: a heavy U of box section from the trunnions round to the pivot.
	for side in [-1.0, 1.0]:
		Kit.beam(_arms, Vector3(side * 1.25, 0.0, -0.1), Vector3(side * 1.45, -0.05, -2.2), 0.26, paint_dark)
		Kit.beam(_arms, Vector3(side * 1.45, -0.05, -2.2), Vector3(side * 0.25, -0.15, -2.45), 0.24, paint_dark)
		# Angling rams from the frame to the back of the blade.
		Kit.beam(_arms, Vector3(side * 1.3, 0.05, -1.6), Vector3(side * 1.25, -0.05, -2.45), 0.1, steel)
	Kit.box(_arms, Vector3(0.6, 0.3, 0.3), Vector3(0, -0.15, -2.45), paint_dark, 0.05)


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
	body.sync_to_physics = false
	body.collision_layer = ARM_LAYER
	body.collision_mask = 0
	body.set_meta("uproots", true)  # shoving into a stump tears it out
	parent.add_child(body)
	return body


func _add_collision(body: CollisionObject3D, size: Vector3, pos: Vector3) -> CollisionShape3D:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = pos
	body.add_child(shape)
	return shape


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.8
		_materials[color] = mat
	return _materials[color]
