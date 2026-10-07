extends VehicleBody3D
## Six-wheel dump truck with real wheel physics. The excavator loads soil into the bed
## (the heap is shaped to the bed), the bed tips to dump it out of the back, and mud
## robs the wheels of grip and sinks them, so a loaded truck can bog down until it's
## dug out or shoved free by the dozer.
## VehicleBody3D drives along +Z, so the model is built facing -Z under a node turned
## 180 degrees; that node doubles as `cab` for the camera.

const Terrain = preload("res://scripts/terrain.gd")
const MachineFx = preload("res://scripts/machine_fx.gd")
const Winch = preload("res://scripts/winch.gd")
const Kit = preload("res://scripts/model_kit.gd")

const EMPTY_MASS := 9000.0
const SOIL_DENSITY := 1600.0
const CAPACITY := 8.0
const ENGINE_FORCE := 19000.0  # about 0-40 km/h in 7 s empty, much slower loaded
const BRAKE_FORCE := 220.0
const TOP_SPEED := 11.0  # m/s (40 km/h) empty
const LOADED_TOP_SPEED := 8.0  # m/s with a full bed
const REVERSE_SPEED := 3.5
const MAX_STEER := 0.5
const HIGH_SPEED_STEER := 0.18  # steering lock at top speed
const BED_RATE := 0.35
const BED_MAX := 0.85
const DUMP_START := 0.4  # bed angle where soil starts to slide out
const DUMP_RATE := 3.0
const GRIP := 3.0
const MUD_GRIP := 0.3
const MUD_DRAG := 2.2
const MUD_BOG := 0.9  # how much deep mud saps traction (worse with a load)
const RUT_DEPTH := 0.03
const HITCH := Vector3(0, 0.85, 3.75)  # rear tow hitch, model space
const FRONT_HOOK := Vector3(0, 1.0, -3.6)
const BOOM_TIP := Vector3(0, 3.45, 4.2)  # recovery truck's winch sheave
const RED := Color(0.8, 0.13, 0.1)
const BED_HALF := Vector2(1.15, 2.27)  # inside of the bed (x, z half-sizes)
const BED_HEIGHT := 1.0
const TRUCK_LAYER := 64
const TRUCK_MASK := 1 | 2 | 4 | 8 | 32 | 64

const YELLOW := Color(0.97, 0.72, 0.12)
const DARK := Color(0.15, 0.15, 0.16)
const STEEL := Color(0.5, 0.5, 0.52)
const GLASS := Color(0.15, 0.22, 0.3)
const SOIL := Color(0.52, 0.31, 0.19)

var terrain: Terrain
var driven := false
var mouse_input := {}
var machine_name := "Dump truck"
var cab: Node3D
var eye: Node3D
var seat: Node3D
## Set before adding to the tree: true builds the heavy 6x6 recovery truck (boom winch,
## all-wheel drive, mud tyres) instead of the dump truck.
var recovery := false
var winch: Winch
var trailer: Node3D  # hitched trailer, if any
var payload := 0.0
var stuck := false
var mud_level := 0.0

var _model: Node3D
var _bed: Node3D
var _tailgate: Node3D
var _heap: MeshInstance3D
var _heap_fill := -1.0
var _hoist: Node3D
var _wheels: Array[VehicleWheel3D] = []
var _bed_velocity := 0.0
var _stuck_timer := 0.0
var _spawn := Transform3D.IDENTITY
var _engine := 0.0
var _exhaust: GPUParticles3D
var _spray: Array[GPUParticles3D] = []
var _pour: GPUParticles3D
var _materials := {}
var _last_rut := Vector3.INF
var _paint := YELLOW
var _empty_mass := EMPTY_MASS
var _engine_force := ENGINE_FORCE
var _mud_grip := MUD_GRIP
var _mud_bog := MUD_BOG
var _dig_timer := 0.0


func _ready() -> void:
	if recovery:
		machine_name = "Recovery truck"
		_paint = RED
		_empty_mass = 13000.0
		_engine_force = 32000.0
		_mud_grip = 1.6
		_mud_bog = 0.2
	mass = _empty_mass
	add_to_group("winchable")
	set_meta("label", machine_name.to_lower())
	collision_layer = TRUCK_LAYER
	collision_mask = TRUCK_MASK
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.9, 0)
	can_sleep = false
	_build_model()
	_add_collision(Vector3(2.3, 0.9, 6.6), Vector3(0, 1.35, 0))
	_add_collision(Vector3(2.3, 1.5, 1.7), Vector3(0, 2.3, 2.5))
	for w in [[-1.05, -2.3, true], [1.05, -2.3, true], [-1.05, 1.5, false], [1.05, 1.5, false], [-1.05, 2.7, false], [1.05, 2.7, false]]:
		_add_wheel(Vector3(w[0], 0.95, -(w[1] as float)), w[2])
	if recovery:
		for w in _wheels:
			w.use_as_traction = true  # 6x6
	winch = Winch.new()
	winch.vehicle = self
	winch.position = BOOM_TIP if recovery else FRONT_HOOK
	winch.max_force = 220000.0 if recovery else 110000.0
	winch.reach = 35.0 if recovery else 25.0
	_model.add_child(winch)
	_exhaust = MachineFx.exhaust(_model, Vector3(1.05, 2.95, -0.72), _material(DARK))
	for i in 2:
		_spray.append(MachineFx.spray(self, Color(0.3, 0.2, 0.12)))
	_pour = MachineFx.dust(self, Color(0.6, 0.45, 0.3), 30)
	_spawn = global_transform
	_update_heap()


func _physics_process(delta: float) -> void:
	var throttle := _axis("drive_back", "drive_forward")
	var speed := linear_velocity.dot(global_basis.z)
	var top := lerpf(TOP_SPEED, LOADED_TOP_SPEED, payload / CAPACITY)
	# Steering tightens up as speed builds.
	var lock := lerpf(MAX_STEER, HIGH_SPEED_STEER, clampf(absf(speed) / TOP_SPEED, 0.0, 1.0))
	steering = move_toward(steering, _axis("turn_right", "turn_left") * lock, 1.2 * delta)
	engine_force = 0.0
	brake = 0.0
	if throttle > 0.05:
		if speed < -0.5:
			brake = BRAKE_FORCE
		else:
			# Pulls hard from a standstill, tails off towards top speed (gearing).
			engine_force = throttle * _engine_force * clampf(1.0 - speed / top, 0.0, 1.0)
	elif throttle < -0.05:
		if speed > 0.5:
			brake = BRAKE_FORCE
		else:
			engine_force = throttle * _engine_force * 0.6 * clampf(1.0 + speed / REVERSE_SPEED, 0.0, 1.0)
	elif Time.get_ticks_msec() < int(get_meta("winched_until", 0)):
		brake = 0.0  # in neutral while it's being winched out
	else:
		# Engine braking when coasting, parking brake when nobody's in the cab.
		brake = BRAKE_FORCE * (0.25 if driven else 1.0)
	if speed > top + 0.5:
		brake = maxf(brake, BRAKE_FORCE * 0.5)  # hold it down hills
	_handle_mud(delta, throttle, speed)
	_rut()
	# Deep mud saps the drive: an empty truck can crawl out, a loaded one bogs down.
	engine_force *= clampf(1.0 - mud_level * _mud_bog * (0.45 + payload / CAPACITY), 0.04, 1.0)
	if not recovery:
		_operate_bed(delta)
	_animate(delta, throttle)


func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## Where a winch cable or tow strap hooks on: the front or rear hook, whichever is nearer.
func tow_point(from: Vector3) -> Vector3:
	var front := _model.to_global(FRONT_HOOK)
	var rear := _model.to_global(HITCH)
	return front if front.distance_to(from) < rear.distance_to(from) else rear


func hitch_point() -> Vector3:
	return _model.to_global(HITCH)


func door_position() -> Vector3:
	return _model.to_global(Vector3(-1.6, 0.0, -2.4))


## True if soil falling at `point` would land in the bed.
func accepts_soil(point: Vector3) -> bool:
	if recovery:
		return false
	var local := _bed.to_local(point)
	return absf(local.x) < BED_HALF.x + 0.15 and local.z > -BED_HALF.y * 2.0 - 0.15 and local.z < 0.15 \
		and local.y > -0.3 and local.y < 5.0


## Adds soil to the bed; returns how much fitted.
func add_soil(amount: float) -> float:
	var taken := minf(amount, CAPACITY - payload)
	payload += taken
	mass = _empty_mass + payload * SOIL_DENSITY
	return taken


func controls() -> Vector4:
	return Vector4(steering / MAX_STEER, _bed_velocity / BED_RATE, engine_force / _engine_force, 0.0)


func rumble() -> Vector2:
	if not driven:
		return Vector2.ZERO
	return Vector2(0.1 + _engine * 0.25, 0.7 if stuck else 0.0)


func status() -> String:
	var kmh := absf(linear_velocity.dot(global_basis.z)) * 3.6
	var text := "%d km/h" % roundi(kmh)
	if not recovery:
		text += "   ·   BED %.1f / %.0f m³" % [payload, CAPACITY]
	if winch.is_attached():
		text += "   ·   WINCH %.0f m%s" % [winch.length, " (pulling)" if winch.tension > 1000.0 else ""]
	if trailer:
		text += "   ·   TOWING"
	if stuck:
		text += "   ⚠ STUCK IN MUD"
	return text


func status_fill() -> float:
	return payload / CAPACITY


func _axis(negative: StringName, positive: StringName) -> float:
	if not driven:
		return 0.0
	return clampf(Input.get_axis(negative, positive) + float(mouse_input.get(positive, 0.0)), -1.0, 1.0)


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
			terrain.press(p, fwd, 0.35, 0.28 if w.use_as_steering else 0.34, depth)


## Mud sinks the wheels, cuts their grip (worse when loaded) and drags on the truck.
func _handle_mud(delta: float, throttle: float, speed: float) -> void:
	var total := 0.0
	var heavy := payload / CAPACITY
	for w in _wheels:
		var p := w.global_position
		var m := terrain.mud_at(p.x, p.z)
		total += m
		w.wheel_friction_slip = lerpf(GRIP, _mud_grip * (1.0 - 0.5 * heavy), m)
		w.wheel_rest_length = lerpf(0.35, 0.14, m)
	mud_level = total / _wheels.size()
	if mud_level > 0.02:
		var drag := Vector3(linear_velocity.x, 0.0, linear_velocity.z) * mass * MUD_DRAG * mud_level * (1.0 + heavy)
		if Time.get_ticks_msec() < int(get_meta("winched_until", 0)):
			drag *= 0.4  # a steady winch pull breaks the mud's suction
		apply_central_force(-drag)
	var spinning := driven and absf(throttle) > 0.5 and absf(speed) < 0.5 and mud_level > 0.3
	_stuck_timer = clampf(_stuck_timer + (delta if spinning else -delta * 2.0), 0.0, 3.0)
	stuck = _stuck_timer > 1.2
	# Spinning tyres dig themselves into the mud.
	_dig_timer -= delta
	if spinning and _dig_timer <= 0.0:
		_dig_timer = 0.25
		for w in _wheels:
			if w.use_as_traction and w.is_in_contact():
				terrain.dig_in(w.global_position - Vector3(0, w.wheel_radius, 0), global_basis.z, 0.35, 0.3, 0.035, 0.8)
	for i in 2:
		var wheel := _wheels[2 + i * 2]
		_spray[i].global_transform = Transform3D(_model.global_basis, wheel.global_position - Vector3(0, 0.3, 0))
		_spray[i].emitting = spinning


func _operate_bed(delta: float) -> void:
	var raise := _axis("boom_down", "boom_up") + _axis("bucket_curl", "bucket_dump")
	_bed_velocity = lerpf(_bed_velocity, clampf(raise, -1.0, 1.0) * BED_RATE, 1.0 - exp(-6.0 * delta))
	_bed.rotation.x = clampf(_bed.rotation.x + _bed_velocity * delta, 0.0, BED_MAX)
	_tailgate.rotation.x = -_bed.rotation.x * 0.9
	var tilt := _bed.rotation.x
	var pouring := payload > 0.0 and tilt > DUMP_START
	if pouring:
		var amount := minf(payload, DUMP_RATE * delta * (tilt - DUMP_START) / (BED_MAX - DUMP_START))
		payload -= amount
		mass = _empty_mass + payload * SOIL_DENSITY
		var drop := _model.to_global(Vector3(0, 0, 4.0))
		terrain.deposit(drop.x, drop.z, amount, 1.4)
		_pour.global_position = Vector3(drop.x, terrain.get_height(drop.x, drop.z), drop.z)
	_pour.emitting = pouring
	if absf(payload - _heap_fill) > 0.04:
		_update_heap()
	# Hoist ram from the chassis to the underside of the bed.
	var from := _model.to_global(Vector3(0, 1.0, 0.6))
	var to := _bed.to_global(Vector3(0, -0.05, -2.6))
	var dir := to - from
	var up := dir.normalized()
	var side := up.cross(Vector3.RIGHT if absf(up.dot(_model.global_basis.x)) < 0.9 else Vector3.FORWARD).normalized()
	_hoist.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(1, dir.length(), 1)), from)


func _animate(delta: float, throttle: float) -> void:
	var work := clampf(absf(throttle) + absf(_bed_velocity) * 2.0, 0.0, 1.0) if driven else 0.0
	_engine = lerpf(_engine, work, 1.0 - exp(-3.0 * delta))
	_exhaust.amount_ratio = 0.25 + 0.75 * _engine if driven else 0.08


## Soil heap shaped to the inside of the bed: a flat fill with a mound in the middle.
func _update_heap() -> void:
	_heap_fill = payload
	_heap.visible = payload > 0.02
	if not _heap.visible:
		return
	var fill := payload / CAPACITY
	var level := fill * BED_HEIGHT * 0.75
	var mound := fill * 0.35
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
			top.append(Vector3(u * (BED_HALF.x - 0.02), 0.07 + level + bump, -BED_HALF.y + v * (BED_HALF.y - 0.02)))
	for iz in nz:
		for ix in nx:
			var a := top[iz * (nx + 1) + ix]
			var b := top[iz * (nx + 1) + ix + 1]
			var c := top[(iz + 1) * (nx + 1) + ix]
			var d := top[(iz + 1) * (nx + 1) + ix + 1]
			for p in [a, d, b, a, c, d]:
				tool.add_vertex(p)
	tool.generate_normals()
	var mesh := tool.commit()
	mesh.surface_set_material(0, _material(SOIL))
	_heap.mesh = mesh


func _build_model() -> void:
	_model = Node3D.new()
	_model.rotation.y = PI
	add_child(_model)
	cab = _model
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
	# Fuel tank, battery box, air tanks, exhaust stack with heat shield.
	Kit.add(_model, Kit.cylinder(0.3, 1.2, 18), Vector3(-1.0, 1.05, -0.35), chrome, Vector3(PI * 0.5, 0, 0))
	Kit.box(_model, Vector3(0.55, 0.5, 0.8), Vector3(1.0, 1.05, -0.4), dark, 0.04)
	Kit.add(_model, Kit.cylinder(0.12, 0.9, 12), Vector3(0.75, 0.82, 0.6), dark, Vector3(PI * 0.5, 0, 0))
	Kit.add(_model, Kit.cylinder(0.08, 1.6, 12), Vector3(1.05, 2.2, -0.72), chrome)
	Kit.add(_model, Kit.cylinder(0.11, 0.7, 12), Vector3(1.05, 2.3, -0.72), Kit.metal(Color(0.6, 0.6, 0.62)))
	eye = Node3D.new()
	eye.position = Vector3(-0.5, 2.75, -1.95)
	eye.rotation.x = -0.1
	_model.add_child(eye)
	seat = Node3D.new()
	seat.position = Vector3(-0.5, 0.95, -1.4)
	_model.add_child(seat)
	# Rear lights, mudflaps, tow hitch.
	for x in [-1.0, 1.0]:
		Kit.box(_model, Vector3(0.3, 0.14, 0.06), Vector3(x * 1.05, 0.95, 3.82), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
		Kit.box(_model, Vector3(0.6, 0.55, 0.03), Vector3(x * 1.05, 0.5, 3.4), black, 0.01)
	Kit.box(_model, Vector3(0.3, 0.22, 0.42), HITCH, dark, 0.04)
	Kit.add(_model, Kit.cylinder(0.05, 0.3, 8), HITCH + Vector3(0, 0.05, 0.08), chrome)

	# Tipping dump body (pivot at the back, reaching forward over the chassis).
	_bed = Node3D.new()
	_bed.position = Vector3(0, 1.45, 3.0)
	_model.add_child(_bed)
	var length := BED_HALF.y * 2.0 + 0.06
	Kit.box(_bed, Vector3(2.44, 0.14, length), Vector3(0, -0.02, -length * 0.5), paint, 0.03)
	var wall := PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.0, BED_HEIGHT), Vector2(-length, BED_HEIGHT + 0.22), Vector2(-length, 0.0)])
	for x in [-1.0, 1.0]:
		Kit.add(_bed, Kit.prism(wall, 0.1), Vector3(x * 1.21, 0, 0), paint)
		Kit.box(_bed, Vector3(0.16, 0.12, length + 0.05), Vector3(x * 1.25, BED_HEIGHT + 0.12, -length * 0.5), paint, 0.04)
		for k in 5:
			var z := -0.35 - k * (length - 0.6) / 4.0
			Kit.box(_bed, Vector3(0.12, BED_HEIGHT - 0.1, 0.12), Vector3(x * 1.3, BED_HEIGHT * 0.5, z), Kit.paint(_paint.darkened(0.12)), 0.03)
		Kit.box(_bed, Vector3(0.24, 0.12, 0.05), Vector3(x * 1.02, 0.3, 0.06), Kit.glow(Color(0.95, 0.08, 0.04)), 0.02)
	Kit.box(_bed, Vector3(2.5, 1.45, 0.12), Vector3(0, 0.7, -length), paint, 0.04)
	Kit.box(_bed, Vector3(2.55, 0.1, 1.05), Vector3(0, 1.42, -length - 0.45), paint, 0.04)  # cab guard
	for x in [-1.0, 1.0]:
		Kit.beam(_bed, Vector3(x * 1.1, 1.1, -length), Vector3(x * 1.1, 1.38, -length - 0.85), 0.08, paint)
	_tailgate = Node3D.new()
	_tailgate.position = Vector3(0, BED_HEIGHT, 0.0)
	_bed.add_child(_tailgate)
	Kit.box(_tailgate, Vector3(2.44, 0.98, 0.1), Vector3(0, -0.5, 0.03), Kit.paint(_paint.darkened(0.08)), 0.03)
	Kit.box(_tailgate, Vector3(2.46, 0.14, 0.11), Vector3(0, -0.08, 0.03), Kit.hazard(), 0.02)
	_heap = MeshInstance3D.new()
	_bed.add_child(_heap)
	if recovery:
		_bed.visible = false
		_build_wrecker()
	_hoist = Node3D.new()
	_model.add_child(_hoist)
	Kit.add(_hoist, Kit.cylinder(0.12, 1.0, 12, 0.08), Vector3(0, 0.5, 0), chrome)
	_hoist.visible = not recovery


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
func _build_wrecker() -> void:
	var paint := Kit.paint(_paint)
	var white := Kit.paint(Color(0.93, 0.93, 0.9))
	var dark := Kit.paint(Color(0.15, 0.15, 0.16), 0.6, 0.2)
	var chrome := Kit.metal(Color(0.8, 0.8, 0.82))
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
	Kit.box(_model, Vector3(0.9, 0.28, 0.3), BOOM_TIP + Vector3(0, 0.05, -0.1), paint, 0.05)
	Kit.axle(_model, 0.18, 0.12, BOOM_TIP + Vector3(0, -0.1, 0.12), chrome)
	Kit.axle(_model, 0.32, 1.0, Vector3(0, 1.85, 0.4), dark, 18)
	for k in 5:
		Kit.axle(_model, 0.34, 0.06, Vector3(-0.4 + k * 0.2, 1.85, 0.4), Kit.matte(Color(0.08, 0.08, 0.08)), 18)
	Kit.box(_model, Vector3(0.3, 0.2, 1.4), Vector3(0, 0.75, 3.9), dark, 0.04)
	Kit.box(_model, Vector3(1.3, 0.18, 0.22), Vector3(0, 0.78, 4.55), Kit.hazard(), 0.04)
	# Roof light bar.
	Kit.box(_model, Vector3(1.7, 0.1, 0.3), Vector3(0, 3.2, -1.95), dark, 0.03)
	for k in 4:
		Kit.box(_model, Vector3(0.3, 0.1, 0.26), Vector3(-0.6 + k * 0.4, 3.27, -1.95), Kit.glow(Color(1.0, 0.55, 0.05), 2.2), 0.04)


func _add_wheel(pos: Vector3, steer: bool) -> void:
	var wheel := VehicleWheel3D.new()
	wheel.position = pos
	wheel.use_as_steering = steer
	wheel.use_as_traction = not steer
	wheel.wheel_radius = 0.55
	wheel.wheel_rest_length = 0.35
	wheel.suspension_travel = 0.3
	wheel.suspension_stiffness = 60.0
	wheel.suspension_max_force = 90000.0
	wheel.damping_compression = 1.6
	wheel.damping_relaxation = 2.2
	wheel.wheel_friction_slip = GRIP
	wheel.wheel_roll_influence = 0.25
	add_child(wheel)
	# Singles on the steer axle, duals behind; hubs face outward.
	Kit.wheel(wheel, 0.55, 0.46 if steer else 0.32, Color(0.88, 0.88, 0.88), 1.0 if pos.x > 0.0 else -1.0, not steer)
	_wheels.append(wheel)


func _add_collision(size: Vector3, pos: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = pos
	add_child(shape)


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.material_override = _material(color)
	parent.add_child(instance)
	return instance


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.8
		if color == GLASS:  # see-through from the cab
			mat.albedo_color.a = 0.3
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.roughness = 0.05
		_materials[color] = mat
	return _materials[color]
