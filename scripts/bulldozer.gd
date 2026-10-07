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
const CAPACITY := 3.5  # m3 the blade can roll along; the rest spills off the ends
const SIDE_SPILL := 0.12  # share of the excess that leaks round the ends per metre pushed
const SPILL_START := 0.85  # the blade only starts losing soil past this much of its capacity
const DROP_RATE := 4.0  # m3/s the load drops when the blade lifts, stops or reverses
const LOAD_DRAG := 0.3  # top-speed loss with a full blade
const RUT_DEPTH := 0.03
const TRACK_WIDTH := 0.56
const TRACK_HALF := Vector2(1.7, 1.05)
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
var mouse_input := {}
var machine_name := "Bulldozer"
var cab: Node3D
var eye: Node3D
var seat: Node3D
var blade_load := 0.0  # m3 of soil rolling in front of the blade
var bogged := false
var spilling := false
var winch: Winch
var ripping := false

var _speed := 0.0
var _turn := 0.0
var _joint_velocity := Vector2.ZERO  # lift, pitch
var _visual: Node3D
var _arms: Node3D
var _blade: Node3D
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


func _ready() -> void:
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_model()
	_add_collision(self, Vector3(2.6, 2.0, 3.6), Vector3(0, 1.2, 0.1))
	_blade_shape = _add_collision(self, Vector3(3.4, 1.0, 0.5), Vector3.ZERO)
	var hull := _kinematic_body(self)
	_add_collision(hull, Vector3(2.6, 2.0, 3.6), Vector3(0, 1.2, 0.1))
	var blade_body := _kinematic_body(_blade)
	_add_collision(blade_body, Vector3(3.5, 1.2, 0.5), Vector3(0, 0, -0.05))
	_exhaust = MachineFx.exhaust(_visual, Vector3(0.55, 1.85, -1.0), _material(DARK))
	_dust = MachineFx.dust(self, Color(0.62, 0.46, 0.3), 30)
	for k in 2:
		_side_dust.append(MachineFx.dust(self, Color(0.6, 0.44, 0.28), 16))
		_side_clods.append(MachineFx.spray(self, SOIL.darkened(0.1)))
	winch = Winch.new()
	winch.vehicle = self
	winch.max_force = 180000.0
	winch.position = Vector3(0, 1.55, 2.15)
	add_child(winch)
	add_to_group("winchable")
	set_meta("label", "bulldozer")
	_spawn = global_transform
	_follow_ground(0.0, true)
	_update_linkage()


func _physics_process(delta: float) -> void:
	_ride_platform()
	_time += delta
	var start := global_position
	_drive(delta)
	_operate_blade(delta)
	_follow_ground(delta, false)
	_update_linkage()
	_rip(delta)
	var cut_share := _doze(delta)
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
			terrain.dig_in(global_position + global_basis.x * side * TRACK_HALF.y, -global_basis.z, TRACK_HALF.x, TRACK_WIDTH * 0.5, 0.03, 0.7)
	_rut()
	_animate(delta)


## The tracks press ruts as the machine travels or turns.
func _rut() -> void:
	var moved := global_position.distance_to(_last_rut.origin)
	var turned := absf(global_basis.z.signed_angle_to(_last_rut.basis.z, Vector3.UP))
	if moved < 0.2 and turned < 0.05:
		return
	_last_rut = global_transform
	var fwd := -global_basis.z
	for side in [-1.0, 1.0]:
		terrain.press(global_position + global_basis.x * side * TRACK_HALF.y, fwd, TRACK_HALF.x + 0.3, TRACK_WIDTH * 0.5, RUT_DEPTH)


func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	_speed = 0.0
	_follow_ground(0.0, true)


func door_position() -> Vector3:
	return to_global(Vector3(-1.5, 0.0, 0.8))


## How hard each control is worked (steer, blade lift, -, blade pitch), for the operator's hands.
func controls() -> Vector4:
	return Vector4(_turn / TURN_RATE, _joint_velocity.x / LIFT_RATE, _speed / MAX_SPEED, _joint_velocity.y / PITCH_RATE)


## Controller rumble (weak, strong) for the current effort.
func rumble() -> Vector2:
	var push := blade_load / CAPACITY
	return Vector2(0.15 + push * 0.4, 0.6 if bogged else push * 0.25) if driven else Vector2.ZERO


func status() -> String:
	var note := "   ⛏ BOGGED DOWN" if bogged else ("   ↔ SPILLING" if spilling else "")
	if ripping:
		note += "   ⚒ RIPPING"
	if winch.is_attached():
		note += "   ·   WINCH %.0f m" % winch.length
	return "%d km/h   ·   BLADE %.1f / %.1f m³%s" % [roundi(absf(_speed) * 3.6), blade_load, CAPACITY, note]


func status_fill() -> float:
	return blade_load / CAPACITY


func _axis(negative: StringName, positive: StringName) -> float:
	if not driven:
		return 0.0
	return clampf(Input.get_axis(negative, positive) + float(mouse_input.get(positive, 0.0)), -1.0, 1.0)


func _drive(delta: float) -> void:
	var mud := terrain.mud_at(global_position.x, global_position.z)
	var top := MAX_SPEED * (1.0 - MUD_SLOW * mud) * (1.0 - LOAD_DRAG * blade_load / CAPACITY)
	if ripping:
		top *= 1.0 - RIP_DRAG
	# Climbing slows it, descending lets it run on (pitch > 0 = nose up).
	var climb := _visual.rotation.x * signf(_speed if absf(_speed) > 0.1 else 1.0)
	top *= clampf(1.0 - climb * SLOPE_EFFECT, 0.35, 1.3)
	var target := _axis("drive_back", "drive_forward") * top
	var rate := ACCELERATION if absf(target) > absf(_speed) and signf(target) == signf(_speed) or is_zero_approx(_speed) else DECELERATION
	_speed = move_toward(_speed, target, rate * delta)
	_turn = _axis("turn_right", "turn_left") * TURN_RATE * (1.0 - 0.4 * mud)
	rotate_y(_turn * delta)
	_track_travel += Vector2(_speed - _turn * TRACK_HALF.y, _speed + _turn * TRACK_HALF.y) * delta
	velocity = -global_basis.z * _speed
	move_and_slide()
	global_position = terrain.clamp_inside(global_position, 3.0)


func _operate_blade(delta: float) -> void:
	var target := Vector2(_axis("boom_down", "boom_up") * LIFT_RATE, _axis("bucket_dump", "bucket_curl") * PITCH_RATE)
	_joint_velocity = _joint_velocity.lerp(target, 1.0 - exp(-JOINT_RESPONSE * delta))
	_arms.rotation.x = clampf(_arms.rotation.x + _joint_velocity.x * delta, LIFT_LIMITS.x, LIFT_LIMITS.y)
	_blade.rotation.x = clampf(_blade.rotation.x + _joint_velocity.y * delta, PITCH_LIMITS.x, PITCH_LIMITS.y)
	_tilt = clampf(_tilt + _axis("swing_right", "swing_left") * TILT_RATE * delta, -TILT_LIMIT, TILT_LIMIT)
	_blade.rotation.z = _tilt
	_ripper.rotation.x = clampf(_ripper.rotation.x + _axis("stick_out", "stick_in") * RIPPER_RATE * delta, RIPPER_LIMITS.x, RIPPER_LIMITS.y)


func _follow_ground(delta: float, instant: bool) -> void:
	var fwd := -global_basis.z * TRACK_HALF.x
	var side := global_basis.x * TRACK_HALF.y
	var p := global_position
	var fl := _support(p + fwd - side)
	var fr := _support(p + fwd + side)
	var bl := _support(p - fwd - side)
	var br := _support(p - fwd + side)
	_check_platform(p)
	var pitch := atan2((fl + fr) - (bl + br), 4.0 * TRACK_HALF.x)
	var roll := atan2((fr + br) - (fl + bl), 4.0 * TRACK_HALF.y)
	var sink := MUD_SINK * terrain.mud_at(p.x, p.z)
	var t := 1.0 if instant else 1.0 - exp(-8.0 * delta)
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


## Grades flat along the whole cutting edge and spreads what it cut evenly in a berm just
## ahead, which the blade keeps pushing as the dozer drives on. Returns the share of the
## soil in the blade's path that it managed to cut this frame (1 = all of it).
func _doze(delta: float) -> float:
	var budget := DOZE_RATE * delta
	var left := _blade.to_global(Vector3(-1.7, -0.58, -0.14))
	var right := _blade.to_global(Vector3(1.7, -0.58, -0.14))
	var fwd := -global_basis.z
	# Grade control: the blade cuts a set depth (where the operator has put it) below the
	# natural ground, so holding it down cuts a flat trench of constant depth rather than
	# a ramp, and the edge stays level across its width. Down in a pit the depth is
	# measured from the ground under the tracks instead.
	var centre_xz := left.lerp(right, 0.5)
	var reference := terrain.original_height(centre_xz.x, centre_xz.z)
	var rear := global_position + global_basis.z * TRACK_HALF.x
	var tracks := (_ground(rear + global_basis.x * TRACK_HALF.y) + _ground(rear - global_basis.x * TRACK_HALF.y)) * 0.5
	if reference - tracks > PIT_DEPTH:
		reference = tracks
	var edge := reference + _edge_offset()
	# Tilting the blade raises one end and drops the other.
	left.y = edge - sin(_tilt) * 1.7
	right.y = edge + sin(_tilt) * 1.7
	var removed := terrain.cut_flat(left, right, fwd, CUT_BACK, CUT_FRONT, budget)
	blade_load += removed
	var share := 1.0 if terrain.last_cut_wanted <= 0.0 else clampf(removed / terrain.last_cut_wanted, 0.0, 1.0)
	bogged = share < 0.5
	_cut_rate = lerpf(_cut_rate, removed / delta, 1.0 - exp(-4.0 * delta))
	# Soil leaks round both ends of the blade as you push (all of it beyond capacity),
	# leaving windrows beside the path.
	var pushed := maxf(_speed, 0.0) * delta
	# Soil only leaks round the ends once the blade is heaped up, and pours off what
	# won't fit at all. A tilted blade sheds mostly off its low end.
	var excess := maxf(blade_load - CAPACITY * SPILL_START, 0.0)
	var spill := maxf(blade_load - CAPACITY, 0.0) + excess * SIDE_SPILL * pushed * 4.0
	spill = minf(spill, blade_load)
	spilling = spill > 0.002
	if spill > 0.0005:
		blade_load -= spill
		var low_left := clampf(0.5 + _tilt / TILT_LIMIT * 0.45, 0.05, 0.95)
		# Dropped beside the blade ends, clear of its path, so the dozer drives past it.
		for side in [-1.0, 1.0]:
			var portion := low_left if side < 0.0 else 1.0 - low_left
			var p := _blade.to_global(Vector3(side * 2.5, -0.58, 0.35))
			terrain.deposit(p.x, p.z, spill * portion, 0.75)
	# Lift the blade clear or reverse and the load drops in front as a pile.
	var centre := left.lerp(right, 0.5)
	var lifted := _blade.to_global(Vector3(0, -0.58, -0.14)).y > _ground(centre) + 0.15
	if blade_load > 0.0 and (lifted or _speed < -0.1):
		var drop := minf(blade_load, DROP_RATE * delta)
		blade_load -= drop
		terrain.deposit_strip(left, right, fwd, 0.15, 1.1, drop)
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
		var cut := terrain.dig(tip, 0.24, RIP_RATE * delta * 4.0)
		if cut > 0.0:
			for s in [-1.0, 1.0]:
				var heap: Vector3 = tip + side * (0.32 * s)
				terrain.deposit(heap.x, heap.z, cut * 0.5, 0.28)


## Height of the cutting edge above the tracks with the machine sitting level.
func _edge_offset() -> float:
	var arms := Transform3D(Basis(Vector3.RIGHT, _arms.rotation.x), _arms.position)
	var blade := Transform3D(Basis(Vector3.RIGHT, _blade.rotation.x), _blade.position)
	return (arms * blade * Vector3(0, -0.58, -0.14)).y


func _update_linkage() -> void:
	_blade_shape.transform = global_transform.affine_inverse() * _blade.global_transform
	for c in _cylinders:
		var rod: Node3D = c[0]
		var base: Node3D = c[1]
		var from := base.global_position
		var to := _blade.to_global(c[2])
		var dir := to - from
		var up := dir.normalized()
		var side := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
		rod.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(1, dir.length(), 1)), from)


func _animate(delta: float) -> void:
	var loop := 2.0 * (TRACK_HALF.x * 2.0 - 0.2) + TAU * 0.38
	_track_travel = Vector2(fposmod(_track_travel.x, loop), fposmod(_track_travel.y, loop))
	_tracks[0].set_shader_parameter("scroll", -_track_travel.x)
	_tracks[1].set_shader_parameter("scroll", -_track_travel.y)
	for i in _idlers.size():
		_idlers[i].rotation.x = -(_track_travel.x if i < _idlers.size() / 2 else _track_travel.y) / 0.36
	var effort := clampf(blade_load / CAPACITY, 0.0, 1.0)
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
		_side_dust[k].global_position = _blade.to_global(Vector3(2.3 * end, -0.4, 0.1))
		_side_dust[k].emitting = spilling
		# Clods tumble outward off the blade end.
		_side_clods[k].global_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5 * end) * global_basis, _blade.to_global(Vector3(1.75 * end, -0.1, -0.5)))
		_side_clods[k].emitting = spilling and effort > 0.6


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
	eye = _node(_visual, Vector3(0, 2.62, 1.0))
	eye.rotation.x = -0.32
	seat = _node(_visual, Vector3(0, 0.95, 1.12))

	# --- Push arms on trunnions, and the curved moldboard blade.
	_arms = _node(_visual, Vector3(0, 0.55, -0.2))
	for side in [-1.0, 1.0]:
		Kit.axle(_arms, 0.14, 0.3, Vector3(side * 1.2, 0, 0), dark)
		Kit.beam(_arms, Vector3(side * 1.2, 0, 0), Vector3(side * 1.32, 0.05, -2.3), 0.22, paint_dark)
		Kit.beam(_arms, Vector3(side * 1.25, 0.02, -1.4), Vector3(side * 0.7, 0.3, -2.3), 0.12, paint_dark)
	_blade = _node(_arms, Vector3(0, 0.025, -2.4))
	var face := [Vector2(-0.2, -0.58), Vector2(-0.04, -0.32), Vector2(0.05, -0.02), Vector2(0.03, 0.28), Vector2(-0.08, 0.5), Vector2(-0.24, 0.63)]
	var moldboard := PackedVector2Array()
	for p in face:
		moldboard.append(p)
	for k in range(face.size() - 1, -1, -1):
		moldboard.append(face[k] + Vector2(0.14, 0.0))
	Kit.add(_blade, Kit.prism(moldboard, 3.4), Vector3.ZERO, paint)
	Kit.box(_blade, Vector3(3.46, 0.1, 0.22), Vector3(0, -0.58, -0.12), Kit.metal(Color(0.3, 0.3, 0.32)), 0.03)
	for side in [-1.0, 1.0]:
		Kit.box(_blade, Vector3(0.1, 1.25, 0.5), Vector3(side * 1.73, 0.02, -0.04), paint, 0.04)
		Kit.box(_blade, Vector3(0.22, 0.16, 0.26), Vector3(side * 1.66, -0.56, -0.18), Kit.metal(Color(0.3, 0.3, 0.32)), 0.04)
	for k in 5:
		Kit.box(_blade, Vector3(0.08, 1.0, 0.14), Vector3(-1.4 + k * 0.7, 0.0, 0.2), paint_dark, 0.03)
	Kit.box(_blade, Vector3(3.42, 0.06, 0.14), Vector3(0, 0.64, -0.2), Kit.hazard(), 0.02)
	Kit.beam(_arms, Vector3(0.9, 0.35, -1.0), Vector3(0.75, 0.6, -2.3), 0.09, steel)  # tilt ram
	# Soil heaped on the blade face while pushing.
	_berm = _node(_blade, Vector3(0, -0.6, -0.6))
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
