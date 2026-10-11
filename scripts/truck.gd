extends VehicleBody3D
## Wheeled trucks with real wheel physics. One script, several kinds (set `kind` before
## adding to the tree): the dump truck, articulated hauler, log truck, heavy-haul tractor,
## recovery truck and site pickup.
## Dump bodies take soil from the excavator (the heap is shaped to the body) and tip it
## out of the back; the log truck's bed is solid, so logs ride on it and slide off when it
## tips. Mud robs the wheels of grip and sinks them, so a loaded truck can bog down until
## it's dug out, winched or shoved free. Load raises the mass and the centre of gravity.
## VehicleBody3D drives along +Z, so the model is built facing -Z under a node turned
## 180 degrees; that node doubles as `cab` for the camera.

const Terrain = preload("res://scripts/terrain.gd")
const MachineFx = preload("res://scripts/machine_fx.gd")
const Winch = preload("res://scripts/winch.gd")
const Kit = preload("res://scripts/model_kit.gd")

const SOIL_DENSITY := 1600.0
const BRAKE_FORCE := 220.0
const HIGH_SPEED_STEER := 0.18  # steering lock at top speed
const BED_RATE := 0.35
const BED_MAX := 0.85
const DUMP_START := 0.4  # bed angle where soil starts to slide out
const DUMP_RATE := 3.0
const MUD_DRAG := 2.2
const AIR_DRAG := 0.9
const RUT_DEPTH := 0.03
const TRUCK_LAYER := 64
const TRUCK_MASK := 1 | 2 | 4 | 8 | 32 | 64 | 128

const YELLOW := Color(0.97, 0.72, 0.12)
const RED := Color(0.8, 0.13, 0.1)
const DARK := Color(0.15, 0.15, 0.16)
const SOIL := Color(0.52, 0.31, 0.19)

## Axles: [model z, half track, steers, driven, dual tyres]. Model space faces -Z.
const KINDS := {
	"dump": {
		"name": "Dump truck", "paint": Color(0.97, 0.72, 0.12), "mass": 9000.0, "engine": 19000.0,
		"top": 11.0, "loaded_top": 8.0, "reverse": 3.5, "steer": 0.5, "grip": 3.0, "mud_grip": 0.3, "bog": 0.9,
		"radius": 0.55, "width": 0.46, "wheel_y": 0.95, "rest": 0.35,
		"axles": [[-2.3, 1.05, true, false, false], [1.5, 1.05, false, true, true], [2.7, 1.05, false, true, true]],
		"capacity": 8.0, "bed_half": Vector2(1.15, 2.27), "bed_height": 1.0, "bed_pivot": Vector3(0, 1.45, 3.0),
		"winch": [Vector3(0, 1.0, -3.6), 110000.0, 25.0], "hitch": Vector3(0, 0.85, 3.75), "com": 0.9,
	},
	"dump_xl": {
		# Big dump truck: the dump truck at 1.5x (model units scaled; wheels in body space).
		"name": "Big dump truck", "paint": Color(0.97, 0.72, 0.12), "mass": 34000.0, "engine": 130000.0, "launch": 1.8,
		"top": 10.5, "loaded_top": 8.0, "reverse": 3.5, "steer": 0.45, "grip": 3.4, "mud_grip": 0.6, "bog": 0.6,
		"radius": 0.84, "width": 0.7, "wheel_y": 1.42, "rest": 0.45, "travel": 0.4, "scale": 1.5,
		"axles": [[-3.45, 1.6, true, false, false], [2.25, 1.6, false, true, true], [4.05, 1.6, false, true, true]],
		"capacity": 24.0, "bed_half": Vector2(1.15, 2.27), "bed_height": 1.0, "bed_pivot": Vector3(0, 1.45, 3.0),
		"winch": [Vector3(0, 1.0, -3.6), 200000.0, 25.0], "hitch": Vector3(0, 0.85, 3.75), "com": 0.8,
	},
	"recovery": {
		"name": "Recovery truck", "paint": Color(0.8, 0.13, 0.1), "mass": 13000.0, "engine": 32000.0,
		"top": 11.0, "loaded_top": 11.0, "reverse": 3.5, "steer": 0.5, "grip": 3.0, "mud_grip": 1.6, "bog": 0.2,
		"radius": 0.55, "width": 0.46, "wheel_y": 0.95, "rest": 0.35,
		"axles": [[-2.3, 1.05, true, true, false], [1.5, 1.05, false, true, true], [2.7, 1.05, false, true, true]],
		"capacity": 0.0, "winch": [Vector3(0, 3.45, 4.2), 220000.0, 35.0], "hitch": Vector3(0, 0.85, 3.75), "com": 0.9,
	},
	"recovery_xl": {
		# Heavy 8x8 rotator wrecker: everything 1.3x a regular recovery truck (model units
		# below are scaled by "scale"; wheels are placed in body space).
		"name": "Heavy recovery truck", "paint": Color(0.95, 0.72, 0.08), "mass": 34000.0, "engine": 230000.0, "launch": 2.0,
		"top": 10.5, "loaded_top": 10.5, "reverse": 3.5, "steer": 0.45, "grip": 3.4, "mud_grip": 2.0, "bog": 0.1,
		"radius": 0.72, "width": 0.6, "wheel_y": 1.25, "rest": 0.4, "scale": 1.3,
		"axles": [[-3.2, 1.4, true, true, false], [-1.75, 1.4, true, true, false], [2.0, 1.4, false, true, true], [3.55, 1.4, false, true, true]],
		"capacity": 0.0, "winch": [Vector3(0, 3.45, 4.2), 450000.0, 60.0], "hitch": Vector3(0, 0.85, 3.75), "com": 1.1,
	},
	"haul": {
		"name": "Heavy haul tractor", "paint": Color(0.14, 0.3, 0.62), "mass": 14000.0, "engine": 70000.0, "launch": 2.4,
		"top": 17.0, "loaded_top": 17.0, "reverse": 4.0, "steer": 0.5, "grip": 3.3, "mud_grip": 0.5, "bog": 0.7,
		"radius": 0.55, "width": 0.46, "wheel_y": 0.95, "rest": 0.35,
		"axles": [[-2.3, 1.05, true, false, false], [1.5, 1.05, false, true, true], [2.7, 1.05, false, true, true]],
		"capacity": 0.0, "winch": [Vector3(0, 1.0, -3.6), 120000.0, 25.0], "hitch": Vector3(0, 0.85, 3.75), "com": 0.85,
	},
	"log_semi": {
		# A big, stable logging rig: 1.4x scale, a stretched chassis on five axles with a wide
		# stance and a low centre of gravity, and a long, wide bed of tall-staked bunks.
		# (Model units are scaled by "scale"; wheels are placed in body space.)
		"name": "Logging semi", "paint": Color(0.55, 0.1, 0.08), "mass": 30000.0, "engine": 280000.0, "launch": 2.6,
		"top": 15.0, "loaded_top": 13.0, "reverse": 4.0, "steer": 0.42, "grip": 3.6, "mud_grip": 0.7, "bog": 0.5,
		"radius": 0.82, "width": 0.62, "wheel_y": 1.3, "rest": 0.5, "travel": 0.5, "scale": 1.4, "roll": 0.06,
		"axles": [[-3.22, 1.75, true, false, false], [2.1, 1.75, false, true, true], [3.78, 1.75, false, true, true],
			[7.0, 1.75, false, false, true], [8.68, 1.75, false, false, true]],
		# (A low bed and short stakes, so even the standard excavator can load it.)
		"capacity": 0.0, "log_bed": true, "bed_pivot": Vector3(0, 1.25, 6.6),
		"bed_length": 7.6, "bed_width": 2.9, "stake_height": 1.1,
		"winch": [Vector3(0, 1.0, -3.6), 160000.0, 30.0], "hitch": Vector3(0, 0.85, 7.0), "com": 0.3,
		"com_z": -3.2,  # mid-wheelbase: the long rear bogie carries its share
	},
	"logs": {
		"name": "Log truck", "paint": Color(0.18, 0.45, 0.27), "mass": 10000.0, "engine": 26000.0,
		"top": 13.0, "loaded_top": 13.0, "reverse": 3.5, "steer": 0.5, "grip": 3.0, "mud_grip": 0.6, "bog": 0.7,
		"radius": 0.7, "width": 0.54, "wheel_y": 0.95, "rest": 0.35,
		"axles": [[-2.3, 1.05, true, false, false], [1.5, 1.05, false, true, true], [2.7, 1.05, false, true, true]],
		"capacity": 0.0, "log_bed": true, "bed_pivot": Vector3(0, 1.45, 3.0), "stake_height": 1.1,
		"winch": [Vector3(0, 1.0, -3.6), 110000.0, 25.0], "hitch": Vector3(0, 0.85, 3.75), "com": 0.9,
	},
	"adt": {
		"name": "Articulated hauler", "paint": Color(0.95, 0.66, 0.08), "mass": 22000.0, "engine": 62000.0,
		"top": 13.0, "loaded_top": 10.0, "reverse": 4.0, "steer": 0.45, "grip": 3.4, "mud_grip": 1.4, "bog": 0.35,
		"radius": 0.85, "width": 0.72, "wheel_y": 1.2, "rest": 0.35,
		"axles": [[-2.9, 1.32, true, true, false], [1.3, 1.32, false, true, false], [3.1, 1.32, false, true, false]],
		"capacity": 14.0, "bed_half": Vector2(1.35, 2.3), "bed_height": 1.5, "bed_pivot": Vector3(0, 2.05, 4.45),
		"winch": [Vector3(0, 1.3, -4.75), 160000.0, 28.0], "hitch": Vector3(0, 1.05, 4.75), "com": 1.25,
	},
	"pickup": {
		"name": "Site pickup", "paint": Color(0.94, 0.94, 0.92), "mass": 2400.0, "engine": 9500.0,
		"top": 24.0, "loaded_top": 24.0, "reverse": 7.0, "steer": 0.6, "grip": 2.7, "mud_grip": 1.0, "bog": 0.6,
		"radius": 0.4, "width": 0.3, "wheel_y": 0.65, "rest": 0.25,
		"axles": [[-1.6, 0.82, true, true, false], [1.6, 0.82, false, true, false]],
		"capacity": 0.0, "winch": [Vector3(0, 0.62, -2.68), 60000.0, 22.0], "hitch": Vector3(0, 0.55, 2.7), "com": 0.55,
	},
}

var terrain: Terrain
var driven := false
var mouse_input := {}
## Multiplayer: `remote` = driven by another player's controls (remote_axes, sent from
## their machine); `puppet` = a copy on a joining player's machine that follows the host.
var remote := false
var remote_axes := {}
var puppet := false
var _net_xform := Transform3D()
var _net_has := false
var _net_bed := 0.0
var _net_speed := 0.0
var _wheel_spin := 0.0
var _wheel_rest: Array[Vector3] = []
## Set before adding to the tree.
var kind := "dump"
## True builds only the model (shop thumbnails).
var preview := false
## A broken-down truck has no engine: it has to be towed or winched.
var broken := false
var machine_name := "Dump truck"
var cab: Node3D
var eye: Node3D
var seat: Node3D
var recovery := false
var winch: Winch
var trailer: Node3D  # hitched trailer, if any
var payload := 0.0
var payload_value := 0.0  # $ of ore in the load (see ores.gd), and the gold part of it
var payload_gold := 0.0
## What's in the body: Terrain.SURFACE_SOIL or Terrain.SURFACE_GRAVEL.
var material := 0
var capacity := 0.0
var stuck := false
## Things a tipped load can pour into instead of the ground (a conveyor's hopper, another
## truck's body); set by main.
var receivers: Array = []
## How far (m) the wheels have sunk into mud. Builds up while a heavy truck sits or
## crawls in mud, cuts the drive, and only clears on firm ground or under a winch.
var bog := 0.0
## Log trucks: walk to the back and press F to strap the load down (logs then ride locked
## to the bed, even as it tips) or release it. Shares the trailers' interface: variant
## "logs", ramps_down = not strapped, ramp_point(), toggle_ramps().
var variant := ""
var ramps_down := true
var _strapped := {}  # node -> transform in bed space
var mud_level := 0.0

var _spec: Dictionary
var _model: Node3D
var _bed: Node3D
var _tailgate: Node3D
var _heap: MeshInstance3D
var _heap_fill := -1.0
var _hoist: Node3D
var _bed_shapes: Array = []  # [CollisionShape3D, bed-local transform] for the log bed
var _wheels: Array[VehicleWheel3D] = []
var _bed_velocity := 0.0
var _stuck_timer := 0.0
var _spawn := Transform3D.IDENTITY
var _engine := 0.0
var _exhaust: GPUParticles3D
var _spray: Array[GPUParticles3D] = []
var _pour: GPUParticles3D
var _last_rut := Vector3.INF
var _paint := YELLOW
var _bed_half := Vector2.ONE
var _bed_height := 1.0
var _dig_timer := 0.0
var _handbrake := false


func _ready() -> void:
	if recovery and kind != "recovery_xl":
		kind = "recovery"
	_spec = KINDS[kind]
	recovery = kind == "recovery" or kind == "recovery_xl"
	if _spec.has("log_bed"):
		variant = "logs"
	machine_name = "Broken-down truck" if broken else String(_spec.name)
	_paint = _spec.paint
	capacity = _spec.capacity
	_bed_half = _spec.get("bed_half", Vector2.ONE)
	_bed_height = _spec.get("bed_height", 1.0)
	_build_model()
	_model.scale = Vector3.ONE * float(_spec.get("scale", 1.0))
	for a in _spec.axles:
		for side in [-1.0, 1.0]:
			_add_wheel(Vector3(side * float(a[1]), _spec.wheel_y, -float(a[0])), a[2], a[3], a[4])
	Kit.merge_tree(_model)
	if preview:
		_hoist.visible = false
		freeze = true
		set_physics_process(false)
		return
	mass = _spec.mass
	add_to_group("winchable")
	add_to_group("vehicles")
	set_meta("label", machine_name.to_lower())
	collision_layer = TRUCK_LAYER
	collision_mask = TRUCK_MASK
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, _spec.com, float(_spec.get("com_z", 0.0)))
	can_sleep = false
	_add_collisions()
	if _spec.has("log_bed"):
		# Slick steel bunks: logs hold on the flat but slide off when the bed tips.
		physics_material_override = PhysicsMaterial.new()
		physics_material_override.friction = 0.22
	winch = Winch.new()
	winch.vehicle = self
	winch.position = _spec.winch[0]
	winch.max_force = _spec.winch[1]
	winch.reach = _spec.winch[2]
	_model.add_child(winch)
	_exhaust = MachineFx.exhaust(_model, _exhaust_pos(), Kit.matte(DARK))
	for i in 2:
		_spray.append(MachineFx.spray(self, Color(0.3, 0.2, 0.12)))
	_pour = MachineFx.dust(self, Color(0.6, 0.45, 0.3), 30)
	_spawn = global_transform
	if capacity > 0.0:
		_update_heap()


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	var throttle := _axis("drive_back", "drive_forward")
	var speed := linear_velocity.dot(global_basis.z)
	var fill := payload / capacity if capacity > 0.0 else 0.0
	var top := lerpf(_spec.top, _spec.loaded_top, fill)
	if trailer:
		top = minf(top, 13.0)
	# Steering tightens up as speed builds.
	var lock := lerpf(_spec.steer, HIGH_SPEED_STEER, clampf(absf(speed) / float(_spec.top), 0.0, 1.0))
	steering = move_toward(steering, _axis("turn_right", "turn_left") * lock, 1.2 * delta)
	_handbrake = driven and (float(remote_axes.get("handbrake", 0.0)) > 0.5 if remote else Input.is_action_pressed("handbrake"))
	var force: float = 0.0 if broken else _spec.engine
	engine_force = 0.0
	brake = 0.0
	if throttle > 0.05:
		if speed < -0.5:
			brake = BRAKE_FORCE
		else:
			# Pulls hard from a standstill, tails off towards top speed (gearing). Heavy rigs
			# get extra low-gear torque ("launch") to get a big load rolling.
			var launch := lerpf(float(_spec.get("launch", 1.0)), 1.0, clampf(speed / 4.0, 0.0, 1.0))
			engine_force = throttle * force * launch * clampf(1.0 - speed / top, 0.0, 1.0)
	elif throttle < -0.05:
		if speed > 0.5:
			brake = BRAKE_FORCE
		else:
			engine_force = throttle * force * 0.6 * clampf(1.0 + speed / float(_spec.reverse), 0.0, 1.0)
	elif broken or Time.get_ticks_msec() < int(get_meta("winched_until", 0)):
		brake = 0.0  # in neutral while it's towed or winched
	else:
		# Engine braking when coasting, parking brake when nobody's in the cab.
		brake = BRAKE_FORCE * (0.25 if driven else 1.0)
	if speed > top + 0.5:
		brake = maxf(brake, BRAKE_FORCE * 0.5)  # hold it down hills
	if _handbrake:
		brake = BRAKE_FORCE * 1.6
		engine_force = 0.0
	# Parked on a side slope, real tyres don't creep sideways; the wheel model does, so
	# hold a braked, near-still truck in place.
	if brake >= BRAKE_FORCE * 0.9 and engine_force == 0.0 and linear_velocity.length() < 1.0:
		var touching := 0
		for w in _wheels:
			if w.is_in_contact():
				touching += 1
		if touching >= _wheels.size() / 2:
			var slide := linear_velocity - global_basis.y * linear_velocity.dot(global_basis.y)
			apply_central_force(-slide * mass * 6.0)
	# Air drag, so top speed fades out naturally.
	apply_central_force(-linear_velocity * linear_velocity.length() * AIR_DRAG * mass / 9000.0)
	_handle_mud(delta, throttle, speed)
	_rut()
	# Deep mud saps the drive: a light truck can crawl out, a heavy one bogs down.
	engine_force *= clampf(1.0 - mud_level * float(_spec.bog) * (0.3 + 0.45 * _wheel_load()), 0.04, 1.0)
	engine_force *= clampf(1.0 - bog * 1.2, 0.12, 1.0)
	if _bed:
		_operate_bed(delta)
	_carry_straps()
	_animate(delta, throttle)


func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	bog = 0.0
	for w in _wheels:
		w.wheel_radius = _spec.radius
		w.set_meta("mud", 0.0)
	global_transform = xform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()


## Where a winch cable or tow strap hooks on: the front or rear hook, whichever is nearer.
func tow_point(from: Vector3) -> Vector3:
	var front := _model.to_global(_spec.winch[0] if not recovery else Vector3(0, 1.0, -3.6))
	var rear := _model.to_global(_spec.hitch)
	return front if front.distance_to(from) < rear.distance_to(from) else rear


func hitch_point() -> Vector3:
	return _model.to_global(_spec.hitch)


func door_position() -> Vector3:
	return _model.to_global(_door())


## True if soil falling at `point` would land in the bed.
func accepts_soil(point: Vector3) -> bool:
	if capacity <= 0.0:
		return false
	var local := _bed.to_local(point)
	return absf(local.x) < _bed_half.x + 0.15 and local.z > -_bed_half.y * 2.0 - 0.15 and local.z < 0.15 \
		and local.y > -0.3 and local.y < 5.0


## Ore poured in with a load.
func add_value(value: float, gold: float) -> void:
	payload_value += value
	payload_gold += gold


func add_soil(amount: float, what := 0) -> float:
	var taken := minf(amount, capacity - payload)
	if taken > 0.0 and what != material and taken > payload:
		material = what
	payload += taken
	_update_load()
	return taken


func controls() -> Vector4:
	return Vector4(steering / float(_spec.steer), _bed_velocity / BED_RATE, engine_force / maxf(float(_spec.engine), 1.0), 0.0)


func rumble() -> Vector2:
	if not driven:
		return Vector2.ZERO
	return Vector2(0.1 + _engine * 0.25, 0.7 if stuck else 0.0)


func status() -> String:
	var info := hud_info()
	var text := "%d km/h" % roundi(info.speed)
	if info.has("load_text"):
		text += "   ·   " + String(info.load_text)
	for flag in info.flags:
		text += "   ·   " + String(flag)
	return text


func status_fill() -> float:
	return payload / capacity if capacity > 0.0 else 0.0


## Multiplayer state (host -> joining players).
func net_state() -> Array:
	return [_bed.rotation.x if _bed else 0.0, payload, steering, linear_velocity.dot(global_basis.z), driven, stuck,
		_engine, winch.net_state(), material]


## Joining players' copy: a frozen body that follows the host, with its wheels, bed and
## heap animated from the host's numbers.
func make_puppet() -> void:
	puppet = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	for w in _wheels:
		_wheel_rest.append(w.position - Vector3(0, float(_spec.rest) * 0.6, 0))


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_net_bed = s[0]
	if s.size() > 8 and int(s[8]) != material:
		material = s[8]
		_heap_fill = -1.0
	if absf(float(s[1]) - payload) > 0.01 or _heap_fill < 0.0:
		payload = s[1]
		if capacity > 0.0:
			_update_heap()
	steering = s[2]
	_net_speed = s[3]
	driven = s[4]
	stuck = s[5]
	_engine = s[6]
	winch.apply_net_state(s[7])


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	_wheel_spin += _net_speed / float(_spec.radius) * delta
	for k in _wheels.size():
		var w := _wheels[k]
		w.position = _wheel_rest[k]
		w.basis = Basis(Vector3.UP, steering if w.use_as_steering else 0.0) * Basis(Vector3.RIGHT, _wheel_spin)
	if _bed:
		_bed.rotation.x = lerpf(_bed.rotation.x, _net_bed, t)
		if _tailgate:
			_tailgate.rotation.x = -_bed.rotation.x * 0.9
		for entry in _bed_shapes:
			(entry[0] as CollisionShape3D).transform = _model.transform * _bed.transform * (entry[1] as Transform3D)
		_update_hoist()
	_exhaust.amount_ratio = (0.25 + 0.75 * _engine if driven else 0.08) if not broken else 0.0


## What the HUD shows for this machine.
func hud_info() -> Dictionary:
	var info := {"speed": absf(linear_velocity.dot(global_basis.z)) * 3.6, "max_speed": float(_spec.top) * 3.6, "flags": []}
	if capacity > 0.0:
		info.load = payload / capacity
		info.load_text = "BED %.1f / %.0f m³%s" % [payload, capacity, "  GRAVEL" if material == Terrain.SURFACE_GRAVEL and payload > 0.05 else ""]
		if payload_value >= 1.0:
			info.flags.append("ORE $%d  (crusher or forge)" % roundi(payload_value))
	elif _spec.has("log_bed"):
		info.load = clampf(_bed.rotation.x / BED_MAX, 0.0, 1.0)
		info.load_text = "BED TIP %d%%" % roundi(info.load * 100.0)
	if winch and winch.is_attached():
		info.flags.append("WINCH %.0f m%s" % [winch.length, " PULLING" if winch.tension > 1000.0 else ""])
	if trailer:
		info.flags.append("TOWING")
	if _handbrake:
		info.flags.append("HANDBRAKE")
	if broken:
		info.flags.append("NO ENGINE")
	if stuck:
		info.flags.append("STUCK")
	if not ramps_down:
		info.flags.append("LOAD STRAPPED (%d)" % _strapped.size())
	if bog > 0.15:
		info.flags.append("SUNK %.1f m" % bog)
	return info


func _axis(negative: StringName, positive: StringName) -> float:
	if not driven:
		return 0.0
	if remote:
		return clampf(float(remote_axes.get(positive, 0.0)) - float(remote_axes.get(negative, 0.0)), -1.0, 1.0)
	return clampf(Input.get_axis(negative, positive) + float(mouse_input.get(positive, 0.0)), -1.0, 1.0)


func _update_load() -> void:
	var fill := payload / capacity if capacity > 0.0 else 0.0
	mass = float(_spec.mass) + payload * SOIL_DENSITY
	# A heaped body sits high: the centre of gravity climbs with the load.
	center_of_mass = Vector3(0, float(_spec.com) + fill * _bed_height * 0.7, float(_spec.get("com_z", 0.0)))
	# The springs scale with mass by themselves, but their force limit doesn't: keep it in
	# step with the load, or a full body bottoms the suspension out and the truck bucks.
	for w in _wheels:
		w.suspension_max_force = 90000.0 * maxf(mass / 9000.0, 0.4)


## Tyres leave ruts in soft ground (deep in mud, light tracks elsewhere off the gravel).
func _rut() -> void:
	if global_position.distance_to(_last_rut) < 0.25:
		return
	_last_rut = global_position
	var fwd := global_basis.z
	for w in _wheels:
		if w.is_in_contact():
			var p := w.global_position - Vector3(0, w.wheel_radius, 0)
			# Firm ground just gets tyre marks; soft ground takes a real rut.
			var depth := RUT_DEPTH if terrain.mud_at(p.x, p.z) > 0.15 else 0.0
			terrain.press(p, fwd, 0.35, float(_spec.width) * 0.6, depth * (1.0 + mass / 20000.0))


## Mud sinks the wheels, cuts their grip and drags on the truck, all in proportion to
## the load on each wheel: an empty pickup skims over soft ground a loaded hauler sinks
## into. Stopped or crawling, a heavy truck keeps sinking (it presses the mud down under
## its wheels) until it's winched or towed out. Gravel and ground mats stay firm.
func _handle_mud(delta: float, throttle: float, speed: float) -> void:
	var total := 0.0
	var load := _wheel_load()
	for w in _wheels:
		var m := _wheel_mud(w)
		total += m
		var sink := clampf(m * (0.45 + 0.4 * load), 0.0, 1.0)
		w.wheel_friction_slip = lerpf(_spec.grip, float(_spec.mud_grip) * (1.0 - 0.3 * clampf(load - 1.0, 0.0, 1.5)), m)
		if terrain.is_ice(w.global_position.x, w.global_position.z):
			w.wheel_friction_slip = float(_spec.grip) * 0.22  # sheet ice: barely any grip
		w.wheel_rest_length = lerpf(_spec.rest, float(_spec.rest) * 0.3, sink)
	mud_level = total / _wheels.size()
	_sink_wheels(delta, load, speed)
	if mud_level > 0.02:
		var drag := Vector3(linear_velocity.x, 0.0, linear_velocity.z) * mass * MUD_DRAG * mud_level * (0.6 + 0.5 * load)
		if Time.get_ticks_msec() < int(get_meta("winched_until", 0)):
			drag *= 0.4  # a steady winch pull breaks the mud's suction
		apply_central_force(-drag)
	var spinning := driven and not broken and absf(throttle) > 0.5 and absf(speed) < 0.5 and mud_level > 0.3
	_stuck_timer = clampf(_stuck_timer + (delta if spinning else -delta * 2.0), 0.0, 3.0)
	stuck = _stuck_timer > 1.2
	_dig_timer -= delta
	if _dig_timer <= 0.0 and mud_level > 0.2:
		_dig_timer = 0.3
		for w in _wheels:
			var m := _wheel_mud(w)
			if m < 0.25 or not w.is_in_contact():
				continue
			var under := w.global_position - Vector3(0, w.wheel_radius, 0)
			if spinning and w.use_as_traction:
				# Spinning tyres dig themselves in.
				terrain.dig_in(under, global_basis.z, 0.35, 0.3, 0.035, 0.8)
			elif absf(speed) < 3.0:
				# The weight presses the wheels down into the mud, faster when stopped.
				var amount := 0.006 * m * load * (2.0 if absf(speed) < 0.3 else 1.0)
				# A tyre-wide rut, so the mud squeezed out lands beside it rather than under the next wheel.
				terrain.dig_in(under, global_basis.z, 0.3, 0.3, amount, 0.25 + 0.45 * m * minf(load, 2.5))
	for i in 2:
		var wheel := _wheels[_wheels.size() - 2 + i]
		_spray[i].global_transform = Transform3D(_model.global_basis, wheel.global_position - Vector3(0, 0.3, 0))
		_spray[i].emitting = spinning


## Heavy wheels sit deeper into mud the longer they stay (the tyres shrink into the
## ground, lowering the chassis); driving, winching or reaching firm ground brings them up.
func _sink_wheels(delta: float, load: float, speed: float) -> void:
	var limit := clampf(mud_level * (0.12 + 0.32 * load), 0.0, 0.85)
	var winched := Time.get_ticks_msec() < int(get_meta("winched_until", 0))
	if mud_level < 0.1:
		bog = move_toward(bog, 0.0, delta * 0.6)
	elif winched:
		bog = move_toward(bog, 0.0, delta * 0.12)
	elif absf(speed) < 1.5 and bog < limit:
		bog = move_toward(bog, limit, delta * 0.012 * mud_level * load * (2.0 if absf(speed) < 0.3 else 1.0))
	elif bog > limit:
		bog = move_toward(bog, limit, delta * 0.05)  # tipped the load out: she rises a little
	elif absf(speed) >= 1.5:
		bog = move_toward(bog, 0.0, delta * 0.04)
	for w in _wheels:
		var m := _wheel_mud(w)
		w.wheel_radius = maxf(float(_spec.radius) - bog * minf(m * 1.5, 1.0), float(_spec.radius) * 0.35)


## Load on each wheel compared with an empty dump truck's (about 1.5 t).
func _wheel_load() -> float:
	return mass / _wheels.size() / 1500.0


## How muddy the ground under a wheel is (0 on gravel, mats, decks or rubble).
## A wheel off the ground keeps its last reading, so shortening a muddy wheel's
## suspension can't lift it clear and make it think it's out of the mud.
func _wheel_mud(w: VehicleWheel3D) -> float:
	if not w.is_in_contact():
		return float(w.get_meta("mud", 0.0))
	var m := 0.0
	var body := w.get_contact_body()
	if body != null and body.get_parent() == terrain:
		var p := w.global_position
		m = terrain.mud_at(p.x, p.z)
	w.set_meta("mud", m)
	return m


func _operate_bed(delta: float) -> void:
	var raise := _axis("boom_down", "boom_up") + _axis("bucket_curl", "bucket_dump")
	_bed_velocity = lerpf(_bed_velocity, clampf(raise, -1.0, 1.0) * BED_RATE, 1.0 - exp(-6.0 * delta))
	_bed.rotation.x = clampf(_bed.rotation.x + _bed_velocity * delta, 0.0, BED_MAX)
	if _tailgate:
		_tailgate.rotation.x = -_bed.rotation.x * 0.9
	# The log bed is solid: its collision follows it up.
	for entry in _bed_shapes:
		(entry[0] as CollisionShape3D).transform = _model.transform * _bed.transform * (entry[1] as Transform3D)
	if capacity > 0.0:
		var tilt := _bed.rotation.x
		var pouring := payload > 0.0 and tilt > DUMP_START
		if pouring:
			var amount := minf(payload, DUMP_RATE * delta * (tilt - DUMP_START) / (BED_MAX - DUMP_START))
			var share := amount / maxf(payload, 0.0001)
			var value := payload_value * share
			var gold := payload_gold * share
			payload_value -= value
			payload_gold -= gold
			payload -= amount
			_update_load()
			var drop := _bed.to_global(Vector3(0, -0.6, 1.0))
			for r in receivers:
				if is_instance_valid(r) and r != self and r.accepts_soil(drop):
					var poured := amount
					amount -= r.add_soil(amount, material)
					if r.has_method("add_value") and poured > 0.0:
						r.add_value(value * (poured - amount) / poured, gold * (poured - amount) / poured)
					break
			if amount > 0.0:
				terrain.deposit(drop.x, drop.z, amount, 1.4 + _bed_half.x * 0.2, material)
			_pour.global_position = Vector3(drop.x, terrain.get_height(drop.x, drop.z), drop.z)
		_pour.emitting = pouring
		if absf(payload - _heap_fill) > 0.04:
			_update_heap()
	_update_hoist()


## Where you stand to strap or release the load: the back of the bed.
func ramp_point() -> Vector3:
	return _bed.to_global(Vector3(0, 0.3, 0.6)) if _bed else global_position


func toggle_ramps() -> void:
	if variant != "logs":
		return
	ramps_down = not ramps_down
	if ramps_down:
		_release_straps()
	else:
		_strap_load()


## Straps down whatever lies on the log bed (logs, stumps, mats, ore, rubble).
func _strap_load() -> void:
	var length: float = _spec.get("bed_length", 4.7)
	var width: float = _spec.get("bed_width", 2.5)
	var stake: float = _spec.get("stake_height", 1.7)
	var inverse := _bed.global_transform.affine_inverse()
	for node in get_tree().get_nodes_in_group("winchable"):
		var b := node as RigidBody3D
		if b == null or b is VehicleBody3D or b.freeze or b.has_meta("strapped_to") or not b.is_inside_tree():
			continue
		var local := _bed.to_local(b.global_position)
		if absf(local.x) > width * 0.5 + 0.3 or local.z > 0.6 or local.z < -length - 0.4 or local.y < -0.6 or local.y > stake + 2.0:
			continue
		_strapped[b] = inverse * b.global_transform
		b.set_meta("strapped_to", self)
		b.set_meta("strap_freeze_mode", b.freeze_mode)
		b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		b.freeze = true
		b.add_collision_exception_with(self)


func _carry_straps() -> void:
	if _strapped.is_empty():
		return
	var bed := _bed.global_transform
	for n in _strapped.keys():
		if not is_instance_valid(n) or not (n as Node).is_inside_tree():
			_strapped.erase(n)
			continue
		(n as Node3D).global_transform = bed * (_strapped[n] as Transform3D)


func _release_straps() -> void:
	for n in _strapped.keys():
		if is_instance_valid(n):
			_free_strap(n)
			(n as RigidBody3D).linear_velocity = linear_velocity
	_strapped.clear()


## Takes one thing out of the straps (a grapple lifting a log off the bed).
func unstrap(n: Node) -> void:
	if _strapped.has(n):
		_strapped.erase(n)
		_free_strap(n)


func _free_strap(n: Node) -> void:
	var b := n as RigidBody3D
	b.remove_meta("strapped_to")
	b.freeze_mode = b.get_meta("strap_freeze_mode", RigidBody3D.FREEZE_MODE_STATIC)
	b.remove_meta("strap_freeze_mode")
	b.remove_collision_exception_with(self)
	b.freeze = false


func is_strapped(n: Node) -> bool:
	return _strapped.has(n)


## Hoist ram from the chassis to the underside of the bed.
func _update_hoist() -> void:
	var pivot: Vector3 = _spec.bed_pivot
	var from := _model.to_global(Vector3(0, pivot.y - 0.45, pivot.z - 2.4))
	var to := _bed.to_global(Vector3(0, -0.05, -2.6))
	var dir := to - from
	var up := dir.normalized()
	var side := up.cross(Vector3.RIGHT if absf(up.dot(_model.global_basis.x)) < 0.9 else Vector3.FORWARD).normalized()
	_hoist.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(1, dir.length(), 1)), from)


func _animate(delta: float, throttle: float) -> void:
	var work := clampf(absf(throttle) + absf(_bed_velocity) * 2.0, 0.0, 1.0) if driven and not broken else 0.0
	_engine = lerpf(_engine, work, 1.0 - exp(-3.0 * delta))
	_exhaust.amount_ratio = (0.25 + 0.75 * _engine if driven else 0.08) if not broken else 0.0


## Soil heap shaped to the inside of the body: a flat fill with a mound in the middle.
func _update_heap() -> void:
	_heap_fill = payload
	_heap.visible = payload > 0.02
	if not _heap.visible:
		return
	var fill := payload / capacity
	var level := fill * _bed_height * 0.75
	var mound := fill * 0.35 * _bed_height
	var nx := 8
	var nz := 14
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top: Array[Vector3] = []
	for iz in nz + 1:
		for ix in nx + 1:
			var u := ix / float(nx) * 2.0 - 1.0
			var v := iz / float(nz) * 2.0 - 1.0
			var bump := mound * (1.0 - u * u) * (1.0 - v * v) + sin(ix * 2.1 + iz * 1.3) * 0.03 * fill
			top.append(Vector3(u * (_bed_half.x - 0.02), 0.07 + level + bump, -_bed_half.y + v * (_bed_half.y - 0.02)))
	for iz in nz:
		for ix in nx:
			var a := top[iz * (nx + 1) + ix]
			var b := top[iz * (nx + 1) + ix + 1]
			var c := top[(iz + 1) * (nx + 1) + ix]
			var d := top[(iz + 1) * (nx + 1) + ix + 1]
			for p in [a, b, d, a, d, c]:  # wound to face up (clockwise seen from above)
				tool.add_vertex(p)
	tool.generate_normals()
	var mesh := tool.commit()
	mesh.surface_set_material(0, Kit.matte(Color(0.58, 0.56, 0.52) if material == Terrain.SURFACE_GRAVEL else SOIL))
	_heap.mesh = mesh


# --- Layout per kind ----------------------------------------------------------------------

func _door() -> Vector3:
	match kind:
		"adt": return Vector3(-1.8, 0.0, -1.6)
		"pickup": return Vector3(-1.35, 0.0, -0.3)
	return Vector3(-1.6, 0.0, -2.4)


func _exhaust_pos() -> Vector3:
	match kind:
		"adt": return Vector3(1.05, 3.55, -3.0)
		"pickup": return Vector3(0.6, 0.4, 2.7)
		"haul": return Vector3(1.0, 3.75, 0.75)
	return Vector3(1.05, 2.95, -0.72)


## Collision boxes in model space ([size, centre]), turned to match the body.
func _add_collisions() -> void:
	var boxes: Array
	match kind:
		"adt":
			boxes = [[Vector3(2.5, 1.4, 4.0), Vector3(0, 2.0, -2.7)], [Vector3(2.0, 1.4, 1.7), Vector3(0, 3.1, -1.5)],
					[Vector3(2.9, 1.0, 5.0), Vector3(0, 2.0, 2.0)]]
		"pickup":
			boxes = [[Vector3(1.9, 0.6, 5.2), Vector3(0, 0.82, 0)], [Vector3(1.7, 0.7, 1.4), Vector3(0, 1.5, -0.25)]]
		_:
			boxes = [[Vector3(2.3, 0.9, 6.6), Vector3(0, 1.35, 0)], [Vector3(2.3, 1.5, 1.7), Vector3(0, 2.3, -2.5)]]
	if kind == "log_semi":
		var back: float = float(_spec.bed_pivot.z) + 0.6
		boxes.append([Vector3(2.3, 0.6, back - 3.2), Vector3(0, 1.15, (3.2 + back) * 0.5)])
	for b in boxes:
		_shape(b[0], Transform3D(Basis.IDENTITY, b[1]))


func _shape(size: Vector3, model_xform: Transform3D) -> CollisionShape3D:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.transform = _model.transform * model_xform
	add_child(shape)
	return shape


func _add_wheel(pos: Vector3, steer: bool, drive: bool, dual: bool) -> void:
	var wheel := VehicleWheel3D.new()
	wheel.position = pos
	wheel.use_as_steering = steer
	wheel.use_as_traction = drive
	wheel.wheel_radius = _spec.radius
	wheel.wheel_rest_length = _spec.rest
	wheel.suspension_travel = float(_spec.get("travel", 0.3 if kind != "pickup" else 0.22))
	var weight: float = float(_spec.mass) / 9000.0
	wheel.suspension_stiffness = 60.0 if kind != "pickup" else 45.0
	wheel.suspension_max_force = 90000.0 * maxf(weight, 0.4)
	wheel.damping_compression = 1.6
	wheel.damping_relaxation = 2.2
	wheel.wheel_friction_slip = _spec.grip
	wheel.wheel_roll_influence = float(_spec.get("roll", 0.2))
	add_child(wheel)
	var rim := Color(0.88, 0.88, 0.88) if kind != "adt" else Color(0.95, 0.66, 0.08)
	Kit.wheel(wheel, _spec.radius, _spec.width if not dual else float(_spec.width) * 0.7, rim, 1.0 if pos.x > 0.0 else -1.0, dual)
	_wheels.append(wheel)


# --- Models -------------------------------------------------------------------------------

func _build_model() -> void:
	_model = Node3D.new()
	_model.rotation.y = PI
	add_child(_model)
	cab = _model
	_hoist = Node3D.new()
	_model.add_child(_hoist)
	match kind:
		"adt":
			_build_adt()
		"pickup":
			_build_pickup()
		_:
			_build_cab_truck()
			match kind:
				"dump", "dump_xl": _build_dump_body(_spec.bed_pivot)
				"recovery", "recovery_xl": _build_wrecker()
				"haul": _build_haul()
				"logs": _build_log_bed()
				"log_semi":
					_build_semi_chassis()
					_build_log_bed()
					_build_semi_stacks()
	if _bed:
		Kit.add(_hoist, Kit.cylinder(0.12, 1.0, 12, 0.08), Vector3(0, 0.5, 0), Kit.metal(Color(0.8, 0.8, 0.82)))
	else:
		_hoist.visible = false


func _seat_and_eye(seat_pos: Vector3, eye_pos: Vector3, pitch: float) -> void:
	eye = Node3D.new()
	eye.position = eye_pos
	eye.rotation.x = pitch
	_model.add_child(eye)
	seat = Node3D.new()
	seat.position = seat_pos
	_model.add_child(seat)


## Conventional truck: chassis, hood, see-through cab with its interior, lights.
func _build_cab_truck() -> void:
	var paint := Kit.paint(_paint)
	var dark := Kit.paint(Color(0.12, 0.12, 0.13), 0.6, 0.2)
	var chrome := Kit.metal(Color(0.8, 0.8, 0.82))
	var black := Kit.matte(Color(0.07, 0.07, 0.08))
	# Chassis: twin rails with cross members.
	for x in [-0.55, 0.55]:
		Kit.box(_model, Vector3(0.22, 0.32, 7.1), Vector3(x, 1.0, 0.3), dark, 0.03)
	for z in [-2.9, -1.0, 1.0, 2.4, 3.5]:
		Kit.box(_model, Vector3(1.1, 0.14, 0.14), Vector3(0, 1.0, z), dark, 0.02)
	# Hood and grille.
	var hood := PackedVector2Array([Vector2(-3.55, 0.95), Vector2(-3.55, 1.72), Vector2(-3.44, 1.92), Vector2(-2.55, 2.04), Vector2(-2.55, 0.95)])
	Kit.add(_model, Kit.prism(hood, 1.96), Vector3.ZERO, paint)
	for k in 4:
		Kit.box(_model, Vector3(0.05, 0.03, 0.55), Vector3(-0.5 + k * 0.33, 2.03, -3.0), dark, 0.01)
	Kit.box(_model, Vector3(1.6, 0.66, 0.08), Vector3(0, 1.38, -3.58), black, 0.03)
	for k in 6:
		Kit.box(_model, Vector3(1.56, 0.04, 0.05), Vector3(0, 1.1 + k * 0.11, -3.63), chrome, 0.01)
	Kit.box(_model, Vector3(1.7, 0.08, 0.1), Vector3(0, 1.74, -3.6), chrome, 0.03)
	for x in [-0.82, 0.82]:
		Kit.add(_model, Kit.cylinder(0.13, 0.08, 16), Vector3(x, 1.72, -3.58), Kit.glow(Color(1, 0.97, 0.88), 2.0), Vector3(PI * 0.5, 0, 0))
		Kit.add(_model, Kit.cylinder(0.16, 0.06, 16), Vector3(x, 1.72, -3.55), chrome, Vector3(PI * 0.5, 0, 0))
		Kit.box(_model, Vector3(0.16, 0.09, 0.05), Vector3(x * 1.17, 1.72, -3.52), Kit.glow(Color(1.0, 0.55, 0.05), 1.2), 0.02)
	Kit.label(_model, "EARTHWORKS", Vector3(0, 1.88, -3.61), 0.003, Color(0.9, 0.9, 0.9), PI)
	# Bumper with fog lamps and tow hooks.
	Kit.box(_model, Vector3(2.5, 0.32, 0.3), Vector3(0, 0.95, -3.66), dark, 0.07)
	Kit.box(_model, Vector3(2.52, 0.06, 0.31), Vector3(0, 1.06, -3.66), chrome, 0.02)
	for x in [-0.95, 0.95]:
		Kit.add(_model, Kit.cylinder(0.07, 0.05, 12), Vector3(x, 0.92, -3.82), Kit.glow(Color(1, 0.95, 0.8), 1.2), Vector3(PI * 0.5, 0, 0))
		Kit.add(_model, Kit.cylinder(0.05, 0.2, 8), Vector3(x * 0.5, 0.82, -3.85), Kit.paint(Color(0.85, 0.1, 0.08)), Vector3(PI * 0.5, 0, 0))
	# Cab: painted lower body, pillars and roof around real glass, so the cab is see-through.
	var lower := PackedVector2Array([Vector2(-2.62, 1.0), Vector2(-2.62, 2.1), Vector2(-0.85, 2.1), Vector2(-0.85, 1.0)])
	Kit.add(_model, Kit.prism(lower, 2.36), Vector3.ZERO, paint)
	Kit.box(_model, Vector3(2.38, 0.16, 1.45), Vector3(0, 3.08, -1.58), paint, 0.06)
	Kit.box(_model, Vector3(2.36, 0.08, 0.3), Vector3(0, 3.02, -2.38), dark, 0.03)  # sun visor
	Kit.box(_model, Vector3(2.36, 0.98, 0.08), Vector3(0, 2.57, -0.89), paint, 0.03)
	for x in [-1.13, 1.13]:
		Kit.beam(_model, Vector3(x, 2.08, -2.6), Vector3(x, 3.04, -2.26), 0.09, paint)
		Kit.beam(_model, Vector3(x, 2.08, -1.5), Vector3(x, 3.04, -1.5), 0.08, paint)
		Kit.beam(_model, Vector3(x, 2.08, -0.92), Vector3(x, 3.04, -0.92), 0.09, paint)
		Kit.box(_model, Vector3(0.025, 0.86, 0.95), Vector3(x * 1.02, 2.56, -2.0), Kit.glass(), 0.0)
		Kit.box(_model, Vector3(0.025, 0.86, 0.5), Vector3(x * 1.02, 2.56, -1.2), Kit.glass(), 0.0)
		Kit.box(_model, Vector3(0.02, 1.0, 0.02), Vector3(x * 1.04, 1.6, -1.52), black, 0.0)  # door gap
		Kit.box(_model, Vector3(0.04, 0.04, 0.2), Vector3(x * 1.05, 1.95, -1.75), chrome, 0.015)  # handle
		Kit.box(_model, Vector3(0.36, 0.06, 0.3), Vector3(x * 1.13, 0.72, -1.75), chrome, 0.015)  # steps
		Kit.box(_model, Vector3(0.36, 0.06, 0.3), Vector3(x * 1.13, 1.12, -1.75), chrome, 0.015)
		# Mirror on its arm.
		Kit.beam(_model, Vector3(x * 1.15, 2.4, -2.45), Vector3(x * 1.42, 2.55, -2.55), 0.04, black)
		Kit.box(_model, Vector3(0.08, 0.42, 0.24), Vector3(x * 1.45, 2.55, -2.55), black, 0.03)
	var windshield := PackedVector2Array([Vector2(-2.6, 2.08), Vector2(-2.27, 3.02), Vector2(-2.25, 3.02), Vector2(-2.58, 2.08)])
	Kit.add(_model, Kit.prism(windshield, 2.2), Vector3.ZERO, Kit.glass())
	# Inside: dashboard, steering wheel, seats.
	Kit.box(_model, Vector3(2.2, 0.28, 0.4), Vector3(0, 2.18, -2.38), dark, 0.05)
	Kit.add(_model, Kit.cylinder(0.2, 0.04, 16), Vector3(-0.5, 2.38, -2.12), black, Vector3(PI * 0.5 - 0.5, 0, 0))
	for x in [-0.5, 0.5]:
		Kit.box(_model, Vector3(0.5, 0.15, 0.5), Vector3(x, 1.75, -1.35), dark, 0.05)
		Kit.box(_model, Vector3(0.5, 0.6, 0.12), Vector3(x, 2.1, -1.08), dark, 0.05)
	# Roof beacons and air horns.
	for x in [-0.7, 0.7]:
		Kit.add(_model, Kit.sphere(0.11, 10, true), Vector3(x, 3.16, -1.9), Kit.glow(Color(1.0, 0.55, 0.05), 2.0))
	Kit.add(_model, Kit.cylinder(0.04, 0.5, 8, 0.08), Vector3(0.3, 3.2, -1.3), chrome, Vector3(PI * 0.5, 0, 0))
	# Front wheel arches.
	for x in [-1.0, 1.0]:
		Kit.add(_model, Kit.prism(_arch(0.62, 0.78), 0.66), Vector3(x * 1.05, 0.62, -2.3), dark)
	# Fuel tank, battery box, air tanks.
	Kit.add(_model, Kit.cylinder(0.3, 1.2, 18), Vector3(-1.0, 1.05, -0.35), chrome, Vector3(PI * 0.5, 0, 0))
	Kit.box(_model, Vector3(0.55, 0.5, 0.8), Vector3(1.0, 1.05, -0.4), dark, 0.04)
	Kit.add(_model, Kit.cylinder(0.12, 0.9, 12), Vector3(0.75, 0.82, 0.6), dark, Vector3(PI * 0.5, 0, 0))
	if kind != "haul":
		Kit.add(_model, Kit.cylinder(0.08, 1.6, 12), Vector3(1.05, 2.2, -0.72), chrome)
		Kit.add(_model, Kit.cylinder(0.11, 0.7, 12), Vector3(1.05, 2.3, -0.72), Kit.metal(Color(0.6, 0.6, 0.62)))
	_seat_and_eye(Vector3(-0.5, 0.95, -1.4), Vector3(-0.5, 2.75, -1.95), -0.1)
	# Rear lights, mudflaps, tow hitch.
	for x in [-1.0, 1.0]:
		Kit.box(_model, Vector3(0.3, 0.14, 0.06), Vector3(x * 1.05, 0.95, 3.82), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
		Kit.box(_model, Vector3(0.6, 0.55, 0.03), Vector3(x * 1.05, 0.5, 3.4), black, 0.01)
	Kit.box(_model, Vector3(0.3, 0.22, 0.42), _spec.hitch, dark, 0.04)
	Kit.add(_model, Kit.cylinder(0.05, 0.3, 8), _spec.hitch + Vector3(0, 0.05, 0.08), chrome)


## Tipping dump body (pivot at the back, reaching forward over the chassis).
func _build_dump_body(pivot: Vector3) -> void:
	var paint := Kit.paint(_paint)
	_bed = Node3D.new()
	_bed.position = pivot
	_model.add_child(_bed)
	var length := _bed_half.y * 2.0 + 0.06
	var width := _bed_half.x * 2.0 + 0.14
	var h := _bed_height
	Kit.box(_bed, Vector3(width, 0.14, length), Vector3(0, -0.02, -length * 0.5), paint, 0.03)
	var wall := PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.0, h), Vector2(-length, h + 0.22), Vector2(-length, 0.0)])
	for x in [-1.0, 1.0]:
		Kit.add(_bed, Kit.prism(wall, 0.1), Vector3(x * (width * 0.5 - 0.01), 0, 0), paint)
		Kit.box(_bed, Vector3(0.16, 0.12, length + 0.05), Vector3(x * (width * 0.5 + 0.03), h + 0.12, -length * 0.5), paint, 0.04)
		for k in 5:
			var z := -0.35 - k * (length - 0.6) / 4.0
			Kit.box(_bed, Vector3(0.12, h - 0.1, 0.12), Vector3(x * (width * 0.5 + 0.08), h * 0.5, z), Kit.paint(_paint.darkened(0.12)), 0.03)
		Kit.box(_bed, Vector3(0.24, 0.12, 0.05), Vector3(x * (width * 0.5 - 0.2), 0.3, 0.06), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
	Kit.box(_bed, Vector3(width + 0.06, h + 0.45, 0.12), Vector3(0, (h + 0.45) * 0.5 - 0.02, -length), paint, 0.04)
	Kit.box(_bed, Vector3(width + 0.11, 0.1, 1.05), Vector3(0, h + 0.42, -length - 0.45), paint, 0.04)  # cab guard
	for x in [-1.0, 1.0]:
		Kit.beam(_bed, Vector3(x * (width * 0.5 - 0.12), h + 0.1, -length), Vector3(x * (width * 0.5 - 0.12), h + 0.38, -length - 0.85), 0.08, paint)
	_tailgate = Node3D.new()
	_tailgate.position = Vector3(0, h, 0.0)
	_bed.add_child(_tailgate)
	Kit.box(_tailgate, Vector3(width, h - 0.02, 0.1), Vector3(0, -h * 0.5, 0.03), Kit.paint(_paint.darkened(0.08)), 0.03)
	Kit.box(_tailgate, Vector3(width + 0.02, 0.14, 0.11), Vector3(0, -0.08, 0.03), Kit.hazard(), 0.02)
	_heap = MeshInstance3D.new()
	_heap.set_meta("keep", true)  # changes colour with what it's carrying
	_bed.add_child(_heap)


## Log bed: a tipping steel frame with bunks and tall stakes. It's solid, so logs the
## grapple drops on it ride along, and slide off the back when the bed tips.
func _build_log_bed() -> void:
	var paint := Kit.paint(_paint)
	var steel := Kit.paint(Color(0.2, 0.2, 0.22), 0.5, 0.4)
	_bed = Node3D.new()
	_bed.position = _spec.bed_pivot
	_model.add_child(_bed)
	var length: float = _spec.get("bed_length", 4.7)
	var width: float = _spec.get("bed_width", 2.5)
	var stake: float = _spec.get("stake_height", 1.7)
	var half := width * 0.5
	for x in [-width * 0.38, width * 0.38]:
		Kit.box(_bed, Vector3(0.2, 0.22, length), Vector3(x, 0.0, -length * 0.5), steel, 0.03)
	var slats := int(length / 0.53)
	for k in slats:
		Kit.box(_bed, Vector3(width - 0.3, 0.08, 0.3), Vector3(0, 0.12, -0.2 - k * 0.53), Kit.matte(Color(0.45, 0.33, 0.22)), 0.01)
	var bunks := maxi(3, int(round(length / 2.0)))
	for k in bunks:
		var z := -0.35 - k * (length - 0.7) / float(bunks - 1)
		Kit.box(_bed, Vector3(width, 0.2, 0.24), Vector3(0, 0.25, z), steel, 0.03)
		for x in [-half + 0.07, half - 0.07]:
			Kit.box(_bed, Vector3(0.14, stake, 0.14), Vector3(x, stake * 0.5 + 0.25, z), paint, 0.03)
			Kit.box(_bed, Vector3(0.16, 0.16, 0.16), Vector3(x, stake + 0.28, z), Kit.hazard(), 0.03)
	# Headboard (log guard) of welded bars.
	Kit.box(_bed, Vector3(width, 0.16, 0.16), Vector3(0, 0.3, -length), paint, 0.03)
	Kit.box(_bed, Vector3(width, 0.16, 0.16), Vector3(0, stake + 0.3, -length), paint, 0.03)
	var bars := int(width / 0.42) + 1
	for k in bars:
		Kit.box(_bed, Vector3(0.08, stake, 0.08), Vector3(-half + 0.15 + k * (width - 0.3) / maxf(bars - 1, 1), stake * 0.5 + 0.3, -length), steel, 0.02)
	Kit.box(_bed, Vector3(0.24, 0.12, 0.05), Vector3(-width * 0.38, 0.0, 0.06), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
	Kit.box(_bed, Vector3(0.24, 0.12, 0.05), Vector3(width * 0.38, 0.0, 0.06), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
	Kit.label(_bed, "TIMBER", Vector3(-half - 0.01, stake * 0.5, -length * 0.5), 0.005, Color.WHITE, -PI * 0.5)
	Kit.label(_bed, "TIMBER", Vector3(half + 0.01, stake * 0.5, -length * 0.5), 0.005, Color.WHITE, PI * 0.5)
	if preview:
		return
	# Collision in bed space: floor, stake walls, headboard.
	for b in [[Vector3(width - 0.1, 0.3, length), Vector3(0, 0.05, -length * 0.5)],
			[Vector3(0.14, stake + 0.1, length), Vector3(-half + 0.05, stake * 0.5 + 0.15, -length * 0.5)],
			[Vector3(0.14, stake + 0.1, length), Vector3(half - 0.05, stake * 0.5 + 0.15, -length * 0.5)],
			[Vector3(width, stake + 0.1, 0.16), Vector3(0, stake * 0.5 + 0.15, -length)]]:
		var box := BoxShape3D.new()
		box.size = b[0]
		var shape := CollisionShape3D.new()
		shape.shape = box
		add_child(shape)
		var local := Transform3D(Basis.IDENTITY, b[1])
		_bed_shapes.append([shape, local])
		shape.transform = _model.transform * _bed.transform * local


## The semi's stretched chassis behind the cab: long rails out to the rear bogie, its
## mudguards, the rear light bar and the hitch.
func _build_semi_chassis() -> void:
	var dark := Kit.paint(Color(0.12, 0.12, 0.13), 0.6, 0.2)
	var paint := Kit.paint(_paint)
	var back: float = float(_spec.bed_pivot.z) + 0.6
	for x in [-0.55, 0.55]:
		Kit.box(_model, Vector3(0.22, 0.34, back - 3.0), Vector3(x, 1.0, (3.0 + back) * 0.5), dark, 0.03)
	var z := 4.0
	while z < back:
		Kit.box(_model, Vector3(1.1, 0.14, 0.14), Vector3(0, 1.0, z), dark, 0.02)
		z += 1.2
	var scale: float = _spec.get("scale", 1.0)
	for a in _spec.axles:
		if float(a[0]) < 4.5:
			continue
		var mz: float = float(a[0]) / scale
		for x in [-1.0, 1.0]:
			Kit.add(_model, Kit.prism(_arch(0.62, 0.78), 0.6), Vector3(x * float(a[1]) / scale, 0.62, mz), dark)
	Kit.box(_model, Vector3(2.4, 0.18, 0.2), Vector3(0, 0.95, back), Kit.hazard(), 0.03)
	for x in [-0.95, 0.95]:
		Kit.box(_model, Vector3(0.24, 0.14, 0.06), Vector3(x, 1.2, back + 0.1), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
	Kit.box(_model, Vector3(0.3, 0.25, 0.5), Vector3(0, 0.85, back + 0.2), paint, 0.04)


## The logging semi's twin chrome stacks and its name on the doors.
func _build_semi_stacks() -> void:
	var chrome := Kit.metal(Color(0.85, 0.85, 0.87))
	for x in [-1.0, 1.0]:
		Kit.add(_model, Kit.cylinder(0.1, 2.6, 14), Vector3(x * 1.08, 2.45, -0.75), chrome)
		Kit.label(_model, "LOGGING", Vector3(x * 1.2, 1.55, -1.75), 0.004, Color.WHITE, PI * 0.5 * x)


## Heavy-haul tractor: sleeper cab, twin chrome stacks, ballast box over the drive axles.
func _build_haul() -> void:
	var paint := Kit.paint(_paint)
	var dark := Kit.paint(Color(0.12, 0.12, 0.13), 0.6, 0.2)
	var chrome := Kit.metal(Color(0.85, 0.85, 0.87))
	var sleeper := PackedVector2Array([Vector2(-0.86, 1.0), Vector2(-0.86, 3.2), Vector2(0.55, 3.2), Vector2(0.62, 3.0), Vector2(0.62, 1.0)])
	Kit.add(_model, Kit.prism(sleeper, 2.36), Vector3.ZERO, paint)
	Kit.box(_model, Vector3(2.3, 0.5, 1.4), Vector3(0, 3.42, -0.15), paint, 0.12)  # roof fairing
	for x in [-1.0, 1.0]:
		Kit.add(_model, Kit.cylinder(0.11, 2.9, 14), Vector3(x * 1.0, 2.55, 0.75), chrome)
		Kit.add(_model, Kit.cylinder(0.14, 0.9, 14), Vector3(x * 1.0, 2.0, 0.75), Kit.metal(Color(0.7, 0.7, 0.72)))
		Kit.add(_model, Kit.cylinder(0.32, 1.3, 20), Vector3(x * 1.0, 1.05, 0.0), chrome, Vector3(PI * 0.5, 0, 0))
		Kit.label(_model, "HEAVY HAUL", Vector3(x * 1.19, 2.6, -0.1), 0.004, Color.WHITE, PI * 0.5 * x)
	Kit.box(_model, Vector3(2.3, 0.12, 2.8), Vector3(0, 1.26, 2.3), dark, 0.03)  # deck plate
	Kit.box(_model, Vector3(1.9, 1.0, 1.6), Vector3(0, 1.85, 2.45), paint, 0.08)  # ballast box
	Kit.box(_model, Vector3(1.94, 0.16, 1.64), Vector3(0, 2.0, 2.45), Kit.hazard(), 0.03)
	Kit.label(_model, "BALLAST 8t", Vector3(0, 1.8, 3.26), 0.004, Color.WHITE, 0.0)
	for x in [-1.0, 1.0]:
		Kit.add(_model, Kit.prism(_arch(0.62, 0.78), 1.9), Vector3(x * 1.05, 0.62, 2.1), dark)


## Articulated hauler: tractor unit (engine, centre cab) on a big single axle, pivot
## joint, and a deep dump body on two rear axles.
func _build_adt() -> void:
	var paint := Kit.paint(_paint)
	var dark := Kit.paint(Color(0.12, 0.12, 0.13), 0.6, 0.2)
	var chrome := Kit.metal(Color(0.8, 0.8, 0.82))
	var black := Kit.matte(Color(0.07, 0.07, 0.08))
	# Front frame and engine hood (sloping down to the nose).
	Kit.box(_model, Vector3(1.4, 0.6, 4.4), Vector3(0, 1.35, -2.6), dark, 0.05)
	var hood := PackedVector2Array([Vector2(-4.75, 1.4), Vector2(-4.75, 2.1), Vector2(-4.5, 2.35), Vector2(-2.5, 2.55), Vector2(-2.5, 1.4)])
	Kit.add(_model, Kit.prism(hood, 2.1), Vector3.ZERO, paint)
	for k in 5:
		Kit.box(_model, Vector3(1.7, 0.04, 0.06), Vector3(0, 1.6 + k * 0.12, -4.78), dark, 0.01)
	for x in [-0.75, 0.75]:
		Kit.box(_model, Vector3(0.36, 0.18, 0.08), Vector3(x, 2.15, -4.74), Kit.glow(Color(1, 0.97, 0.88), 2.0), 0.03)
	Kit.box(_model, Vector3(2.7, 0.35, 0.35), Vector3(0, 1.25, -4.85), dark, 0.06)  # bumper
	Kit.box(_model, Vector3(2.72, 0.12, 0.36), Vector3(0, 1.4, -4.85), Kit.hazard(), 0.03)
	# Fenders over the front wheels.
	for x in [-1.0, 1.0]:
		Kit.add(_model, Kit.prism(_arch(0.92, 1.05), 0.8), Vector3(x * 1.32, 1.12, -2.9), paint)
	# Centre cab: wide glass on all sides.
	var cab_base := PackedVector2Array([Vector2(-2.5, 1.9), Vector2(-2.5, 2.7), Vector2(-0.7, 2.7), Vector2(-0.7, 1.9)])
	Kit.add(_model, Kit.prism(cab_base, 2.2), Vector3.ZERO, paint)
	Kit.box(_model, Vector3(2.3, 0.18, 2.0), Vector3(0, 4.05, -1.6), paint, 0.08)
	var glass := PackedVector2Array([Vector2(-2.5, 2.7), Vector2(-2.35, 3.98), Vector2(-0.7, 3.98), Vector2(-0.7, 2.7)])
	Kit.add(_model, Kit.prism(glass, 2.12), Vector3.ZERO, Kit.glass())
	for p in [[-1.08, -2.47, -2.33], [1.08, -2.47, -2.33], [-1.08, -0.72, -0.72], [1.08, -0.72, -0.72]]:
		Kit.beam(_model, Vector3(p[0], 2.7, p[1]), Vector3(p[0], 3.98, p[2]), 0.09, paint)
	Kit.box(_model, Vector3(2.2, 0.28, 0.35), Vector3(0, 2.85, -2.25), dark, 0.05)  # dash
	Kit.add(_model, Kit.cylinder(0.2, 0.04, 16), Vector3(0, 3.05, -2.0), black, Vector3(PI * 0.5 - 0.6, 0, 0))
	Kit.box(_model, Vector3(0.6, 0.18, 0.55), Vector3(0, 2.35, -1.25), dark, 0.05)
	Kit.box(_model, Vector3(0.6, 0.75, 0.14), Vector3(0, 2.75, -0.95), dark, 0.05)
	Kit.add(_model, Kit.sphere(0.12, 10, true), Vector3(0.7, 4.14, -1.2), Kit.glow(Color(1.0, 0.55, 0.05), 2.0))
	# Ladder up to the cab door.
	for k in 4:
		Kit.box(_model, Vector3(0.08, 0.05, 0.5), Vector3(-1.2, 0.7 + k * 0.38, -1.6), Kit.metal(Color(0.6, 0.6, 0.6)), 0.01)
	Kit.beam(_model, Vector3(-1.2, 0.6, -1.85), Vector3(-1.2, 2.2, -1.85), 0.05, black)
	Kit.beam(_model, Vector3(-1.2, 0.6, -1.35), Vector3(-1.2, 2.2, -1.35), 0.05, black)
	Kit.add(_model, Kit.cylinder(0.09, 1.3, 12), Vector3(1.05, 2.9, -3.0), chrome)
	# Articulation joint and the rear frame.
	Kit.add(_model, Kit.cylinder(0.32, 0.9, 16), Vector3(0, 1.45, -0.35), Kit.metal(Color(0.55, 0.55, 0.57)))
	Kit.box(_model, Vector3(1.5, 0.6, 5.2), Vector3(0, 1.45, 2.3), dark, 0.05)
	for x in [-1.0, 1.0]:
		for z in [1.3, 3.1]:
			Kit.add(_model, Kit.prism(_arch(0.92, 1.02), 0.78), Vector3(x * 1.32, 1.12, z), dark)
		Kit.box(_model, Vector3(0.3, 0.16, 0.06), Vector3(x * 1.1, 1.5, 4.92), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
	Kit.box(_model, Vector3(0.34, 0.24, 0.42), _spec.hitch, dark, 0.04)
	_seat_and_eye(Vector3(0, 1.55, -1.25), Vector3(0, 3.5, -1.75), -0.14)
	_build_dump_body(_spec.bed_pivot)
	Kit.label(_bed, "EARTHWORKS", Vector3(-1.57, 0.55, -2.4), 0.0045, Color(0.12, 0.1, 0.08), -PI * 0.5)
	Kit.label(_bed, "EARTHWORKS", Vector3(1.57, 0.55, -2.4), 0.0045, Color(0.12, 0.1, 0.08), PI * 0.5)


## Site pickup: crew cab, short bed, roof beacon bar, bull bar with a winch.
func _build_pickup() -> void:
	var paint := Kit.paint(_paint)
	var dark := Kit.paint(Color(0.12, 0.12, 0.13), 0.6, 0.2)
	var black := Kit.matte(Color(0.07, 0.07, 0.08))
	var body := PackedVector2Array([Vector2(-2.62, 0.5), Vector2(-2.66, 0.92), Vector2(-2.45, 1.12), Vector2(-1.0, 1.2),
			Vector2(-0.9, 1.22), Vector2(2.6, 1.22), Vector2(2.66, 0.5)])
	Kit.add(_model, Kit.prism(body, 1.86), Vector3.ZERO, paint)
	Kit.box(_model, Vector3(1.6, 0.06, 2.1), Vector3(0, 1.0, 1.55), dark, 0.02)  # bed floor
	for x in [-0.88, 0.88]:
		Kit.box(_model, Vector3(0.1, 0.18, 2.15), Vector3(x, 1.3, 1.55), paint, 0.04)
		Kit.add(_model, Kit.prism(_arch(0.44, 0.5), 0.12), Vector3(x * 1.065, 0.43, -1.6), dark)
		Kit.add(_model, Kit.prism(_arch(0.44, 0.5), 0.12), Vector3(x * 1.065, 0.43, 1.6), dark)
		Kit.box(_model, Vector3(0.14, 0.18, 0.05), Vector3(x * 0.85, 1.05, 2.66), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
		Kit.box(_model, Vector3(0.3, 0.12, 0.05), Vector3(x * 0.72, 1.0, -2.66), Kit.glow(Color(1, 0.97, 0.88), 2.0), 0.03)
		Kit.box(_model, Vector3(0.06, 0.18, 0.14), Vector3(x * 1.0, 1.55, -0.9), black, 0.02)  # mirror
	Kit.box(_model, Vector3(1.86, 0.5, 0.08), Vector3(0, 1.0, 2.62), paint, 0.03)  # tailgate
	Kit.box(_model, Vector3(1.0, 0.25, 0.06), Vector3(0, 0.82, -2.68), black, 0.02)  # grille
	# Bull bar with the winch.
	Kit.box(_model, Vector3(1.9, 0.22, 0.2), Vector3(0, 0.62, -2.72), dark, 0.05)
	for x in [-0.55, 0.55]:
		Kit.beam(_model, Vector3(x, 0.62, -2.75), Vector3(x, 1.12, -2.72), 0.07, dark)
	Kit.beam(_model, Vector3(-0.55, 1.12, -2.72), Vector3(0.55, 1.12, -2.72), 0.07, dark)
	Kit.axle(_model, 0.1, 0.5, Vector3(0, 0.62, -2.84), Kit.paint(Color(0.85, 0.1, 0.08)))
	Kit.box(_model, Vector3(1.9, 0.18, 0.2), Vector3(0, 0.6, 2.72), dark, 0.05)
	# Crew cab: glass all round, roof and beacon bar.
	var glass := PackedVector2Array([Vector2(-0.98, 1.2), Vector2(-0.5, 1.84), Vector2(0.52, 1.84), Vector2(0.58, 1.2)])
	Kit.add(_model, Kit.prism(glass, 1.7), Vector3.ZERO, Kit.glass())
	Kit.box(_model, Vector3(1.74, 0.07, 1.1), Vector3(0, 1.87, 0.02), paint, 0.03)
	for p in [[-0.85, -0.98, -0.5], [0.85, -0.98, -0.5], [-0.85, 0.58, 0.52], [0.85, 0.58, 0.52]]:
		Kit.beam(_model, Vector3(p[0], 1.2, p[1]), Vector3(p[0], 1.86, p[2]), 0.06, paint)
	Kit.box(_model, Vector3(1.2, 0.08, 0.24), Vector3(0, 1.95, -0.2), dark, 0.03)
	for k in 3:
		Kit.box(_model, Vector3(0.28, 0.08, 0.2), Vector3(-0.38 + k * 0.38, 2.01, -0.2), Kit.glow(Color(1.0, 0.55, 0.05), 2.2), 0.03)
	Kit.box(_model, Vector3(1.7, 0.2, 0.3), Vector3(0, 1.25, -0.9), dark, 0.04)  # dash
	Kit.add(_model, Kit.cylinder(0.16, 0.03, 16), Vector3(-0.38, 1.38, -0.68), black, Vector3(PI * 0.5 - 0.5, 0, 0))
	for x in [-0.38, 0.38]:
		Kit.box(_model, Vector3(0.45, 0.12, 0.45), Vector3(x, 0.92, -0.1), dark, 0.04)
		Kit.box(_model, Vector3(0.45, 0.55, 0.1), Vector3(x, 1.22, 0.14), dark, 0.04)
	Kit.box(_model, Vector3(0.6, 0.4, 0.6), Vector3(0, 1.25, 1.6), Kit.paint(Color(0.85, 0.6, 0.1)), 0.06)  # toolbox
	Kit.label(_model, "SITE", Vector3(-0.94, 0.95, 0.2), 0.004, Color(0.85, 0.15, 0.1), -PI * 0.5)
	Kit.label(_model, "SITE", Vector3(0.94, 0.95, 0.2), 0.004, Color(0.85, 0.15, 0.1), PI * 0.5)
	_seat_and_eye(Vector3(-0.38, 0.12, -0.1), Vector3(-0.38, 1.6, -0.35), -0.08)


## A thick half-ring (wheel arch) profile in (z, y).
func _arch(inner: float, outer: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 11:
		var a := PI * k / 10.0
		pts.append(Vector2(-cos(a) * outer, sin(a) * outer))
	for k in 11:
		var a := PI * (10 - k) / 10.0
		pts.append(Vector2(-cos(a) * inner, sin(a) * inner))
	return pts


## Recovery body: deck, roller-shutter toolboxes, an A-frame boom with the winch sheave,
## lift rams, the winch drum, an underlift and outriggers at the back.
## The heavy wrecker's extra kit: a rotating crane base with a second, longer boom over
## the first, twin winch drums, folding stabiliser legs each side, chevrons and beacons.
func _build_heavy_wrecker_extras(paint: Material, dark: Material, chrome: Material) -> void:
	var black := Kit.matte(Color(0.08, 0.08, 0.09))
	Kit.axle(_model, 0.7, 0.35, Vector3(0, 2.45, 1.2), dark, 24)  # rotator turntable
	Kit.box(_model, Vector3(1.5, 0.6, 1.6), Vector3(0, 2.85, 1.2), paint, 0.08)
	for x in [-1.0, 1.0]:
		Kit.beam(_model, Vector3(x * 0.45, 3.0, 0.8), Vector3(x * 0.25, 4.3, 4.6), 0.24, paint)  # upper boom
		Kit.beam(_model, Vector3(x * 0.5, 2.9, 1.8), Vector3(x * 0.35, 3.7, 3.0), 0.11, chrome)  # its ram
		# Stabiliser legs folded down at the back and middle.
		for z in [0.2, 3.3]:
			Kit.box(_model, Vector3(0.9, 0.22, 0.26), Vector3(x * 1.55, 1.05, z), Kit.hazard(), 0.03)
			Kit.box(_model, Vector3(0.2, 0.75, 0.2), Vector3(x * 1.95, 0.7, z), black, 0.03)
			Kit.box(_model, Vector3(0.5, 0.06, 0.5), Vector3(x * 1.95, 0.32, z), dark, 0.02)
	for k in 2:
		Kit.axle(_model, 0.3, 0.7, Vector3(-0.45 + k * 0.9, 2.25, 2.3), dark, 18)  # twin winch drums
	Kit.box(_model, Vector3(2.5, 0.35, 0.2), Vector3(0, 1.05, 4.62), Kit.hazard(), 0.04)  # chevron board
	for x in [-1.1, 1.1]:
		Kit.add(_model, Kit.cylinder(0.12, 0.2, 12), Vector3(x, 3.32, -1.95), Kit.glow(Color(1.0, 0.55, 0.05), 2.4))
	Kit.label(_model, "HEAVY RECOVERY", Vector3(0, 3.28, -2.12), 0.004, Color(0.1, 0.1, 0.1), PI)


func _build_wrecker() -> void:
	var paint := Kit.paint(_paint)
	var white := Kit.paint(Color(0.93, 0.93, 0.9))
	var dark := Kit.paint(Color(0.15, 0.15, 0.16), 0.6, 0.2)
	var chrome := Kit.metal(Color(0.8, 0.8, 0.82))
	var boom_tip: Vector3 = _spec.winch[0]
	Kit.box(_model, Vector3(2.4, 0.18, 4.6), Vector3(0, 1.35, 1.4), dark, 0.03)
	for x in [-1.0, 1.0]:
		Kit.box(_model, Vector3(0.48, 0.85, 3.6), Vector3(x, 1.86, 1.2), white, 0.06)
		for k in 6:
			Kit.box(_model, Vector3(0.49, 0.02, 1.0), Vector3(x, 1.55 + k * 0.11, 0.25), Kit.matte(Color(0.75, 0.75, 0.75)), 0.0)
			Kit.box(_model, Vector3(0.49, 0.02, 1.0), Vector3(x, 1.55 + k * 0.11, 2.0), Kit.matte(Color(0.75, 0.75, 0.75)), 0.0)
		Kit.box(_model, Vector3(0.5, 0.05, 3.62), Vector3(x, 2.3, 1.2), paint, 0.02)
		Kit.label(_model, "RECOVERY", Vector3(x * 1.25, 1.9, 1.2), 0.006, Color(0.8, 0.13, 0.1), PI * 0.5 * x)
		var foot := Vector3(x * 0.7, 1.45, 0.6)
		var head := Vector3(x * 0.3, 3.45, 4.1)
		Kit.beam(_model, foot, head, 0.2, paint)
		Kit.beam(_model, Vector3(x * 0.55, 1.45, 2.4), foot.lerp(head, 0.55), 0.1, chrome)  # lift ram
		Kit.box(_model, Vector3(0.28, 0.65, 0.32), Vector3(x * 1.3, 0.55, 3.75), Kit.hazard(), 0.03)  # outrigger
	Kit.box(_model, Vector3(0.9, 0.28, 0.3), boom_tip + Vector3(0, 0.05, -0.1), paint, 0.05)
	Kit.axle(_model, 0.18, 0.12, boom_tip + Vector3(0, -0.1, 0.12), chrome)
	Kit.axle(_model, 0.32, 1.0, Vector3(0, 1.85, 0.4), dark, 18)
	for k in 5:
		Kit.axle(_model, 0.34, 0.06, Vector3(-0.4 + k * 0.2, 1.85, 0.4), Kit.matte(Color(0.08, 0.08, 0.08)), 18)
	Kit.box(_model, Vector3(0.3, 0.2, 1.4), Vector3(0, 0.75, 3.9), dark, 0.04)
	Kit.box(_model, Vector3(1.3, 0.18, 0.22), Vector3(0, 0.78, 4.55), Kit.hazard(), 0.04)
	if kind == "recovery_xl":
		_build_heavy_wrecker_extras(paint, dark, chrome)
	# Roof light bar.
	Kit.box(_model, Vector3(1.7, 0.1, 0.3), Vector3(0, 3.2, -1.95), dark, 0.03)
	for k in 4:
		Kit.box(_model, Vector3(0.3, 0.1, 0.26), Vector3(-0.6 + k * 0.4, 3.27, -1.95), Kit.glow(Color(1.0, 0.55, 0.05), 2.2), 0.04)
