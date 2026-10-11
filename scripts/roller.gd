extends CharacterBody3D
## Smooth-drum roller: grades the ground to a level you set. Set the level first (raise /
## lower it, or snap it to the ground under the drum), then switch levelling on: wherever
## the drum rolls (or sits), high ground is cut down and low ground filled up to that
## level, and rolled firm (no ruts). Built facing -Z (the drum leads).

const Kit = preload("res://scripts/model_kit.gd")
const Terrain = preload("res://scripts/terrain.gd")

const MAX_SPEED := 3.0  # m/s
const ACCELERATION := 1.6
const TURN_RATE := 0.5
const FOOTPRINT := Vector2(2.2, 1.15)  # half length (drum to rear axle), half width
const DRUM := Vector3(0, 0.8, -1.7)  # drum axle (model space)
const DRUM_RADIUS := 0.8
const DRUM_HALF_WIDTH := 1.1
const REAR := Vector3(0, 0.75, 1.6)  # rear axle
const LEVEL_RATE := 0.45  # m/s the level moves while held
const GRADE_RATE := 2.5  # m/s of cut or fill under the drum
const GRADE_EVERY := 0.1  # s between ground edits
const MUD_SINK := 0.12
const MUD_SLOW := 0.4
const BODY_LAYER := 2
const SOLID_MASK := 32 | 64

const YELLOW := Color(0.96, 0.7, 0.1)
const DARK := Color(0.15, 0.15, 0.16)
const STEEL := Color(0.45, 0.46, 0.48)

var terrain: Terrain
var driven := false
var preview := false
var mouse_input := {}
var remote := false
var remote_axes := {}
var puppet := false
var machine_name := "Roller"
var cab: Node3D
var eye: Node3D
var seat: Node3D
var level := NAN  # the height it grades to (NAN until first set)
var levelling := false
var cut := 0.0  # m3 cut down and filled in, in total
var filled := 0.0

var _speed := 0.0
var _turn := 0.0
var _travel := 0.0
var _grade_timer := 0.0
var _snap_held := false
var _spawn := Transform3D()
var _net_xform := Transform3D()
var _net_has := false
var _visual: Node3D
var _drum: Node3D
var _wheels: Array[Node3D] = []
var _beacon: MeshInstance3D


func _ready() -> void:
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_model()
	Kit.merge_tree(_visual)
	if preview:
		set_physics_process(false)
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.5, 2.0, 5.2)
	shape.shape = box
	shape.position = Vector3(0, 1.2, 0)
	add_child(shape)
	add_to_group("winchable")
	add_to_group("vehicles")
	set_meta("label", "roller")
	_spawn = global_transform
	_follow_ground(0.0, true)


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	_drive(delta)
	_follow_ground(delta, false)
	_set_level(delta)
	_grade(delta)
	_animate()


# --- Driving ---------------------------------------------------------------------------

func _axis(negative: StringName, positive: StringName) -> float:
	if not driven:
		return 0.0
	if remote:
		return clampf(float(remote_axes.get(positive, 0.0)) - float(remote_axes.get(negative, 0.0)), -1.0, 1.0)
	return clampf(Input.get_axis(negative, positive) + float(mouse_input.get(positive, 0.0)), -1.0, 1.0)


func _drive(delta: float) -> void:
	var p := global_position
	var mud := terrain.mud_at(p.x, p.z)
	var ice := terrain.is_ice(p.x, p.z)
	var top := MAX_SPEED * (1.0 - MUD_SLOW * mud)
	_speed = move_toward(_speed, _axis("drive_back", "drive_forward") * top, ACCELERATION * (0.2 if ice else 1.0) * delta)
	_turn = move_toward(_turn, _axis("turn_right", "turn_left") * TURN_RATE, 1.5 * delta)
	rotate_y(_turn * delta * clampf(absf(_speed) / 0.6 + 0.35, 0.0, 1.0))  # articulated: steers best rolling
	velocity = -global_basis.z * _speed
	move_and_slide()
	global_position = terrain.clamp_inside(global_position, 4.0)
	_travel += _speed * delta


## Sits it on the ground under the drum and rear wheels, tilted to match.
func _follow_ground(delta: float, instant: bool) -> void:
	var fwd := -global_basis.z * FOOTPRINT.x
	var side := global_basis.x * FOOTPRINT.y
	var p := global_position
	var fl := terrain.get_height((p + fwd - side).x, (p + fwd - side).z)
	var fr := terrain.get_height((p + fwd + side).x, (p + fwd + side).z)
	var bl := terrain.get_height((p - fwd - side).x, (p - fwd - side).z)
	var br := terrain.get_height((p - fwd + side).x, (p - fwd + side).z)
	var pitch := atan2((fl + fr) - (bl + br), 4.0 * FOOTPRINT.x)
	var roll := atan2((fr + br) - (fl + bl), 4.0 * FOOTPRINT.y)
	var t := 1.0 if instant else 1.0 - exp(-8.0 * delta)
	var sink := MUD_SINK * terrain.mud_at(p.x, p.z)
	global_position.y = lerpf(p.y, (fl + fr + bl + br) * 0.25 - sink, t)
	_visual.rotation.x = lerp_angle(_visual.rotation.x, pitch, t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, roll, t)


# --- Grading ----------------------------------------------------------------------------

## Where the drum meets the ground (world space).
func drum_point() -> Vector3:
	var at := to_global(Vector3(DRUM.x, 0.0, DRUM.z))
	at.y = terrain.get_height(at.x, at.z)
	return at


## Level up / down (boom keys); snap it to the ground under the drum (stick out).
func _set_level(delta: float) -> void:
	if is_nan(level):
		level = drum_point().y
	var change := _axis("boom_down", "boom_up")
	if change != 0.0:
		level = clampf(level + change * LEVEL_RATE * delta, Terrain.MIN_HEIGHT + 0.5, 80.0)
	var snap := _axis("stick_in", "stick_out") > 0.5
	if snap and not _snap_held:
		level = drum_point().y
	_snap_held = snap


func toggle_levelling() -> String:
	levelling = not levelling
	if is_nan(level):
		level = drum_point().y
	return ("Levelling ON  ·  grading to %.2f m" % level) if levelling else "Levelling OFF"


func _grade(delta: float) -> void:
	if not levelling:
		return
	_grade_timer -= delta
	if _grade_timer > 0.0:
		return
	_grade_timer = GRADE_EVERY
	var forward := -global_basis.z
	forward.y = 0.0
	var at := drum_point()
	# The drum's footprint plus a little ahead, so a moving drum grades its whole path.
	var done: Vector2 = terrain.level_strip(at, forward.normalized(), 0.8 + absf(_speed) * GRADE_EVERY, DRUM_HALF_WIDTH, level, GRADE_RATE * GRADE_EVERY)
	cut += done.x
	filled += done.y


# --- Game interface ----------------------------------------------------------------------

func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	_speed = 0.0
	_follow_ground(0.0, true)
	reset_physics_interpolation()


func door_position() -> Vector3:
	return to_global(Vector3(-1.9, 0.0, 0.6))


func controls() -> Vector4:
	return Vector4(_turn / TURN_RATE, 0.0, _speed / MAX_SPEED, 0.0)


func rumble() -> Vector2:
	return Vector2(0.1 + (0.25 if levelling else 0.0), 0.0) if driven else Vector2.ZERO


func status() -> String:
	return "%d km/h   ·   LEVEL %.2f m   ·   %s" % [roundi(absf(_speed) * 3.6), level, "LEVELLING" if levelling else "OFF"]


func status_fill() -> float:
	return 0.0


func hud_info() -> Dictionary:
	var ground := drum_point().y
	var diff := ground - level if not is_nan(level) else 0.0
	var where := "ON LEVEL" if absf(diff) < 0.03 else ("CUT %.2f m" % diff if diff > 0.0 else "FILL %.2f m" % -diff)
	var info := {"speed": absf(_speed) * 3.6, "max_speed": MAX_SPEED * 3.6,
		"flags": ["LEVELLING ON" if levelling else "LEVELLING OFF  (tool button)", "LEVEL %.2f m  ·  %s" % [level, where],
			"Level ▲▼ boom keys  ·  stick out: level here"],
		"load": clampf(0.5 + diff * 0.5, 0.0, 1.0), "load_text": "MOVED %.0f m³ CUT  ·  %.0f m³ FILL" % [cut, filled]}
	return info


## Multiplayer state (host -> joining players).
func net_state() -> Array:
	return [_speed, level if not is_nan(level) else 0.0, levelling, driven, _travel, cut, filled]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_speed = s[0]
	level = s[1]
	levelling = s[2]
	driven = s[3]
	_travel = s[4]
	cut = s[5]
	filled = s[6]


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	_animate()


func _animate() -> void:
	_drum.rotation.x = -_travel / DRUM_RADIUS
	for w in _wheels:
		w.rotation.x = -_travel / 0.75
	_beacon.visible = levelling and fmod(Time.get_ticks_msec() * 0.002, 1.0) < 0.5


# --- Model ------------------------------------------------------------------------------

func _build_model() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	cab = _visual
	var paint := Kit.paint(YELLOW)
	var dark := Kit.paint(DARK, 0.6, 0.2)
	var steel := Kit.metal(STEEL)
	var rubber := Kit.matte(Color(0.07, 0.07, 0.07))
	# The drum, in a yoke frame at the front.
	_drum = Node3D.new()
	_drum.position = DRUM
	_visual.add_child(_drum)
	Kit.axle(_drum, DRUM_RADIUS, DRUM_HALF_WIDTH * 2.0, Vector3.ZERO, steel, 28)
	for x in [-DRUM_HALF_WIDTH - 0.02, DRUM_HALF_WIDTH + 0.02]:
		Kit.axle(_drum, DRUM_RADIUS * 0.55, 0.06, Vector3(x, 0, 0), dark, 16)
	for k in 6:
		# (Weld seams, so you can see it turn.)
		var a := k * TAU / 6.0
		Kit.box(_drum, Vector3(DRUM_HALF_WIDTH * 2.0 + 0.01, 0.04, 0.04), Vector3(0, sin(a), cos(a)) * DRUM_RADIUS, dark, 0.0)
	for side in [-1.0, 1.0]:
		var x: float = side * (DRUM_HALF_WIDTH + 0.18)
		Kit.box(_visual, Vector3(0.22, 0.5, 1.9), Vector3(x, 1.35, DRUM.z + 0.15), paint, 0.06)
		Kit.box(_visual, Vector3(0.2, 0.9, 0.3), Vector3(x, 1.05, DRUM.z), paint, 0.05)
	Kit.box(_visual, Vector3(DRUM_HALF_WIDTH * 2.0 + 0.58, 0.3, 0.5), Vector3(0, 1.6, DRUM.z + 0.95), paint, 0.06)
	Kit.box(_visual, Vector3(DRUM_HALF_WIDTH * 2.0 + 0.2, 0.08, 0.2), Vector3(0, 1.0, DRUM.z - 0.9), Kit.hazard(), 0.01)  # scraper bar
	# Articulation joint, then the rear frame: engine hood, rear tyres, cab.
	Kit.axle(_visual, 0.25, 0.9, Vector3(0, 1.25, -0.35), steel, 12)
	Kit.box(_visual, Vector3(1.9, 0.55, 3.0), Vector3(0, 1.05, 1.2), paint, 0.08)
	Kit.box(_visual, Vector3(1.7, 0.9, 1.5), Vector3(0, 1.75, 1.85), paint, 0.12)  # engine hood
	for k in 6:
		Kit.box(_visual, Vector3(0.05, 0.5, 1.0), Vector3(0.86, 1.75, 1.6 + k * 0.1), dark, 0.0)
	Kit.add(_visual, Kit.cylinder(0.07, 0.7, 10), Vector3(0.5, 2.5, 2.2), dark)
	Kit.box(_visual, Vector3(1.75, 0.2, 0.2), Vector3(0, 0.95, 2.7), dark, 0.03)  # rear bumper
	for x in [-0.6, 0.6]:
		Kit.box(_visual, Vector3(0.3, 0.12, 0.05), Vector3(x, 1.15, 2.72), Kit.glow(Color(0.95, 0.08, 0.04)), 0.01)
	for side in [-1.0, 1.0]:
		var hub := Node3D.new()
		hub.position = REAR + Vector3(side * 0.95, 0, 0)
		_visual.add_child(hub)
		Kit.axle(hub, 0.75, 0.55, Vector3.ZERO, rubber, 20)
		for k in 8:
			var a := k * TAU / 8.0
			Kit.box(hub, Vector3(0.57, 0.12, 0.2), Vector3(0, sin(a), cos(a)) * 0.72, dark, 0.02)  # tread lugs
		Kit.axle(hub, 0.42, 0.57, Vector3.ZERO, paint, 12)
		_wheels.append(hub)
	# Cab: platform, ROPS posts, roof, glass.
	Kit.box(_visual, Vector3(1.7, 0.12, 1.3), Vector3(0, 1.4, 0.45), dark, 0.03)
	for x in [-0.78, 0.78]:
		for z in [-0.1, 1.0]:
			Kit.box(_visual, Vector3(0.1, 1.5, 0.1), Vector3(x, 2.2, z), dark, 0.02)
	Kit.box(_visual, Vector3(1.8, 0.12, 1.4), Vector3(0, 2.98, 0.45), paint, 0.05)
	Kit.box(_visual, Vector3(1.5, 1.1, 0.04), Vector3(0, 2.25, -0.1), Kit.glass(), 0.01)
	Kit.box(_visual, Vector3(0.5, 0.7, 0.5), Vector3(0, 1.8, 0.75), dark, 0.05)  # seat
	Kit.box(_visual, Vector3(0.6, 0.1, 0.35), Vector3(0, 2.0, 0.15), dark, 0.03)  # dash
	_beacon = Kit.add(_visual, Kit.sphere(0.12, 8, true), Vector3(0.6, 3.04, 0.9), Kit.glow(Color(1.0, 0.6, 0.05), 3.0))
	_beacon.set_meta("keep", true)
	Kit.label(_visual, "EARTHWORKS", Vector3(0.96, 1.05, 1.2), 0.005, Color(0.1, 0.1, 0.1), PI * 0.5)
	seat = Node3D.new()
	seat.position = Vector3(0, 1.75, 0.75)
	_visual.add_child(seat)
	eye = Node3D.new()
	eye.position = Vector3(0, 2.75, 0.65)
	eye.rotation.x = -0.25
	_visual.add_child(eye)
