extends CharacterBody3D
## Little Bird helicopter: arcade flight in the style of war-game helicopters. The rotor
## spools up when you climb in; then you fly it like a hovering camera that tilts into its
## moves.
##  - W / S (left stick):      fly forward / back (it noses down into the move)
##  - A / D:                   turn (yaw)
##  - Q / E (right stick):     slide sideways (it banks)
##  - Space or I / Up (RT):    climb      Shift or K / Down (LT): descend
##  - R (RB):                  fire a rocket (left and right pods in turn)
## Rockets blow craters in the ground and wreck vehicles. Flying into the ground hard (or
## taking enough rocket hits) wrecks it. Built facing -Z (model: models/littlebird/,
## "Little Bird with Rockets" by RonTheRentalCop, split into body and rotors so they spin).

const Kit = preload("res://scripts/model_kit.gd")
const Terrain = preload("res://scripts/terrain.gd")

const BODY_MESH := "res://models/littlebird/body.obj"
const MAIN_ROTOR := "res://models/littlebird/main_rotor.obj"
const TAIL_ROTOR := "res://models/littlebird/tail_rotor.obj"
const MAIN_HUB := Vector3(0.0, 3.24, -1.32)
const TAIL_HUB := Vector3(-0.354, 2.025, 4.242)
const PODS := [Vector3(-1.35, 0.72, -1.9), Vector3(1.35, 0.72, -1.9)]  # rocket pod muzzles

const MAX_FORWARD := 42.0  # m/s
const MAX_BACK := 12.0
const MAX_STRAFE := 16.0
const MAX_CLIMB := 9.0
const ACCEL := 11.0
const VERTICAL_ACCEL := 9.0
const YAW_RATE := 1.35
const SPOOL_TIME := 3.0  # s for the rotor to come up to speed
const CEILING := 240.0  # m above the ground
const CRASH_SPEED := 13.0  # m/s into the ground wrecks it
const BODY_LAYER := 2
const SOLID_MASK := 32 | 64
const FIRE_EVERY := 0.35

var terrain: Terrain
var driven := false
var preview := false
var mouse_input := {}
var remote := false
var remote_axes := {}
var puppet := false
var machine_name := "Little Bird helicopter"
var cab: Node3D
var eye: Node3D
var seat: Node3D
var passenger_seat: Node3D
var rpm := 0.0  # 0 .. 1 rotor speed
var wrecked := false

var _vel := Vector3.ZERO  # world velocity
var _yaw_rate := 0.0
var _pod := 0
var _fire_timer := 0.0
var _spawn := Transform3D()
var _net_xform := Transform3D()
var _net_has := false
var _visual: Node3D
var _main_rotor: Node3D
var _tail_rotor: Node3D
var _rotor_angle := 0.0
var _dust: GPUParticles3D


func _ready() -> void:
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_model()
	if preview:
		set_physics_process(false)
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.2, 2.4, 6.5)
	shape.shape = box
	shape.position = Vector3(0, 1.4, 0.4)
	add_child(shape)
	add_to_group("winchable")
	add_to_group("vehicles")
	set_meta("label", "helicopter")
	_spawn = global_transform
	_settle()


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	_fire_timer -= delta
	rpm = move_toward(rpm, 1.0 if driven and not wrecked else 0.0, delta / SPOOL_TIME)
	_fly(delta)
	_animate(delta)


func _axis(negative: StringName, positive: StringName) -> float:
	if not driven or wrecked:
		return 0.0
	if remote:
		return clampf(float(remote_axes.get(positive, 0.0)) - float(remote_axes.get(negative, 0.0)), -1.0, 1.0)
	return clampf(Input.get_axis(negative, positive), -1.0, 1.0)


func _pressed(action: StringName) -> float:
	if not driven or wrecked:
		return 0.0
	return float(remote_axes.get(action, 0.0)) if remote else Input.get_action_strength(action)


## Hover-camera flight: the stick sets the velocity it heads for; it tilts into the move.
func _fly(delta: float) -> void:
	var ground := terrain.get_height(global_position.x, global_position.z)
	var height := global_position.y - ground
	var lift := smoothstep(0.6, 1.0, rpm)
	var forward := -global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := Vector3(-forward.z, 0, forward.x)
	var fwd_in := _axis("drive_back", "drive_forward")
	var side_in := _axis("swing_left", "swing_right")
	var climb_in := clampf(_pressed("handbrake") + _pressed("boom_up") + _pressed("bucket_curl")
			- _pressed("sprint") - _pressed("boom_down") - _pressed("bucket_dump"), -1.0, 1.0)
	if height > CEILING:
		climb_in = minf(climb_in, 0.0)
	var target := forward * fwd_in * (MAX_FORWARD if fwd_in > 0.0 else MAX_BACK) + right * side_in * MAX_STRAFE
	var flat := Vector3(_vel.x, 0, _vel.z)
	flat = flat.move_toward(target * lift, ACCEL * delta * (1.0 if lift > 0.5 else 0.3))
	var vy := _vel.y
	if lift > 0.5:
		vy = move_toward(vy, climb_in * MAX_CLIMB, VERTICAL_ACCEL * delta)
	else:
		vy -= 9.8 * delta * (1.0 - lift * 0.8)  # no lift: it drops (gently, autorotating)
		vy = maxf(vy, -18.0)
	_vel = Vector3(flat.x, vy, flat.z)
	_yaw_rate = move_toward(_yaw_rate, _axis("turn_right", "turn_left") * YAW_RATE * lift, 3.0 * delta)
	rotate_y(_yaw_rate * delta)
	velocity = _vel
	move_and_slide()
	# The ground: land on it (skids at the bottom), or crash into it.
	ground = terrain.get_height(global_position.x, global_position.z)
	if global_position.y <= ground:
		if _vel.y < -CRASH_SPEED and not wrecked:
			var main := get_parent()
			if main.has_method("damage_vehicle"):
				main.damage_vehicle(self, 1000.0)
		global_position.y = ground
		_vel.y = maxf(_vel.y, 0.0)
		_vel.x *= 0.9
		_vel.z *= 0.9
	global_position = terrain.clamp_inside(global_position, 4.0)
	# Lean into the move: nose down going forward, bank into slides and turns.
	var local := global_basis.inverse() * _vel
	var on_ground := global_position.y - ground < 0.2
	var pitch := 0.0 if on_ground else clampf(local.z / MAX_FORWARD, -1.0, 1.0) * 0.32 - fwd_in * 0.08
	var roll := 0.0 if on_ground else clampf(-local.x / MAX_STRAFE, -1.0, 1.0) * 0.35 - _yaw_rate * 0.15
	_visual.rotation.x = lerp_angle(_visual.rotation.x, pitch, 1.0 - exp(-4.0 * delta))
	_visual.rotation.z = lerp_angle(_visual.rotation.z, roll, 1.0 - exp(-4.0 * delta))
	_dust.emitting = rpm > 0.5 and global_position.y - ground < 12.0
	if _dust.emitting:
		_dust.global_position = Vector3(global_position.x, ground + 0.2, global_position.z)


## Fires a rocket from the next pod; returns it (or null if it's not ready).
func fire() -> Node3D:
	if _fire_timer > 0.0 or wrecked or rpm < 0.6:
		return null
	_fire_timer = FIRE_EVERY
	var muzzle: Vector3 = _visual.to_global(PODS[_pod])
	_pod = (_pod + 1) % PODS.size()
	var aim := -_visual.global_basis.z
	var main := get_parent()
	if main.has_method("launch_rocket"):
		return main.launch_rocket(muzzle, aim * 115.0 + _vel, self)
	return null


func wreck() -> void:
	wrecked = true
	machine_name = "Wrecked helicopter"
	var smoke := MachineFx_smoke()
	_visual.add_child(smoke)
	smoke.position = Vector3(0, 2.2, 0.5)


func _settle() -> void:
	global_position.y = terrain.get_height(global_position.x, global_position.z)


# --- Game interface ----------------------------------------------------------------------

func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	_vel = Vector3.ZERO
	_settle()
	reset_physics_interpolation()


func door_position() -> Vector3:
	return to_global(Vector3(-2.2, 0.0, -1.2))


func controls() -> Vector4:
	return Vector4(_yaw_rate / YAW_RATE, 0.0, 0.0, 0.0)


func rumble() -> Vector2:
	return Vector2(0.08 + 0.12 * rpm, 0.0) if driven else Vector2.ZERO


func status() -> String:
	var height := global_position.y - terrain.get_height(global_position.x, global_position.z)
	return "%d km/h   ·   ALT %d m   ·   ROTOR %d%%" % [roundi(Vector3(_vel.x, 0, _vel.z).length() * 3.6), roundi(height), roundi(rpm * 100.0)]


func status_fill() -> float:
	return rpm


func hud_info() -> Dictionary:
	var height := global_position.y - terrain.get_height(global_position.x, global_position.z)
	var flags := ["ALT %d m" % roundi(height), "CLIMB %+.1f m/s" % _vel.y]
	if rpm < 0.99:
		flags.append("ROTOR SPOOLING %d%%" % roundi(rpm * 100.0))
	if wrecked:
		flags.append("WRECKED")
	flags.append("ROCKETS: R / RB")
	return {"speed": Vector3(_vel.x, 0, _vel.z).length() * 3.6, "max_speed": MAX_FORWARD * 3.6, "flags": flags,
		"load": rpm, "load_text": "ROTOR %d%%" % roundi(rpm * 100.0)}


func net_state() -> Array:
	return [rpm, _vel, _visual.rotation, driven, wrecked]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	rpm = s[0]
	_vel = s[1]
	_visual.rotation = s[2]
	driven = s[3]
	if bool(s[4]) and not wrecked:
		wreck()


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	global_transform = global_transform.interpolate_with(_net_xform, 1.0 - exp(-14.0 * delta))
	_animate(delta)


func _animate(delta: float) -> void:
	_rotor_angle += rpm * 42.0 * delta
	_main_rotor.rotation.y = _rotor_angle
	_tail_rotor.rotation.x = _rotor_angle * 1.6


# --- Model ------------------------------------------------------------------------------

func _build_model() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	cab = _visual
	var body := MeshInstance3D.new()
	body.mesh = load(BODY_MESH)
	_visual.add_child(body)
	_main_rotor = Node3D.new()
	_main_rotor.position = MAIN_HUB
	_visual.add_child(_main_rotor)
	var blades := MeshInstance3D.new()
	blades.mesh = load(MAIN_ROTOR)
	_main_rotor.add_child(blades)
	_tail_rotor = Node3D.new()
	_tail_rotor.position = TAIL_HUB
	_visual.add_child(_tail_rotor)
	var tail := MeshInstance3D.new()
	tail.mesh = load(TAIL_ROTOR)
	_tail_rotor.add_child(tail)
	seat = Node3D.new()
	seat.position = Vector3(-0.45, 1.05, -2.2)
	_visual.add_child(seat)
	passenger_seat = Node3D.new()
	passenger_seat.position = Vector3(0.45, 1.05, -2.2)
	_visual.add_child(passenger_seat)
	eye = Node3D.new()
	eye.position = Vector3(-0.45, 2.0, -2.5)
	eye.rotation.x = -0.12
	_visual.add_child(eye)
	_dust = GPUParticles3D.new()
	_dust.amount = 50
	_dust.lifetime = 1.4
	_dust.top_level = true
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	process.emission_ring_radius = 4.0
	process.emission_ring_inner_radius = 2.0
	process.emission_ring_height = 0.1
	process.emission_ring_axis = Vector3.UP
	process.direction = Vector3(0, 0.2, 0)
	process.spread = 180.0
	process.initial_velocity_min = 3.0
	process.initial_velocity_max = 7.0
	process.scale_min = 0.8
	process.scale_max = 1.8
	_dust.process_material = process
	var puff := SphereMesh.new()
	puff.radius = 0.4
	puff.height = 0.8
	puff.radial_segments = 6
	puff.rings = 3
	var dust_mat := StandardMaterial3D.new()
	dust_mat.albedo_color = Color(0.6, 0.52, 0.4, 0.35)
	dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.material = dust_mat
	_dust.draw_pass_1 = puff
	_dust.emitting = false
	add_child(_dust)


static func MachineFx_smoke() -> GPUParticles3D:
	var smoke := GPUParticles3D.new()
	smoke.amount = 40
	smoke.lifetime = 3.0
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 1, 0)
	process.spread = 15.0
	process.initial_velocity_min = 1.5
	process.initial_velocity_max = 3.0
	process.gravity = Vector3(0, 0.4, 0)
	process.scale_min = 0.8
	process.scale_max = 2.0
	smoke.process_material = process
	var puff := SphereMesh.new()
	puff.radius = 0.4
	puff.height = 0.8
	puff.radial_segments = 6
	puff.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.12, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.material = mat
	smoke.draw_pass_1 = puff
	return smoke
