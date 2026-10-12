extends CharacterBody3D
## Portable shredder on tracks: drive it to where the trees are coming down, then drop,
## drag or push logs and stumps into the striped infeed at its back. The rollers pull
## them in and they're shredded for cash on the spot (chips fly off the spout at the
## front). Built facing -Z (the spout leads, the infeed is at +Z).

signal shredded(value: int, label: String, at: Vector3)

const Kit = preload("res://scripts/model_kit.gd")
const MachineFx = preload("res://scripts/machine_fx.gd")
const Terrain = preload("res://scripts/terrain.gd")

const MAX_SPEED := 2.4
const ACCELERATION := 1.4
const TURN_RATE := 0.45
const TRACK_HALF := Vector2(2.4, 1.2)
const INFEED_SIZE := Vector3(4.4, 3.0, 4.0)
const INFEED_CENTER := Vector3(0, 1.3, 4.6)
const MOUTH := Vector3(0, 1.9, 2.1)
const FEED_TIME := 1.4
const MUD_SINK := 0.2
const MUD_SLOW := 0.5
const BODY_LAYER := 2
const SOLID_MASK := 32 | 64

const GREEN := Color(0.2, 0.42, 0.26)
const ORANGE := Color(0.95, 0.5, 0.08)
const DARK := Color(0.15, 0.15, 0.16)
const STEEL := Color(0.5, 0.51, 0.53)

var terrain: Terrain
var driven := false
var preview := false
var mouse_input := {}
var remote := false
var remote_axes := {}
var puppet := false
var machine_name := "Portable shredder"
var cab: Node3D
var eye: Node3D
var seat: Node3D
var total_shredded := 0
var earned := 0

var _speed := 0.0
var _turn := 0.0
var _track_travel := 0.0
var _spawn := Transform3D()
var _net_xform := Transform3D()
var _net_has := false
var _net_busy := false
var _visual: Node3D
var _drum: Node3D
var _rollers: Array[Node3D] = []
var _chips: GPUParticles3D
var _infeed: Area3D
var _feeding: Array = []  # [body, start transform in machine space, time]
var _poll := 0.0
var _spin := 0.4


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
	box.size = Vector3(3.0, 2.8, 5.4)
	shape.shape = box
	shape.position = Vector3(0, 1.6, -0.4)
	add_child(shape)
	_infeed = Area3D.new()
	_infeed.collision_layer = 0
	_infeed.collision_mask = 4  # logs and stumps
	_infeed.monitorable = false
	var feed_shape := CollisionShape3D.new()
	var feed_box := BoxShape3D.new()
	feed_box.size = INFEED_SIZE
	feed_shape.shape = feed_box
	feed_shape.position = INFEED_CENTER
	_infeed.add_child(feed_shape)
	_visual.add_child(_infeed)
	add_to_group("winchable")
	add_to_group("vehicles")
	set_meta("label", "portable shredder")
	_spawn = global_transform
	_follow_ground(0.0, true)


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	MachineFx.ride_deck(self)
	_drive(delta)
	_follow_ground(delta, false)
	_feed(delta)
	_animate(delta, not _feeding.is_empty())


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
	rotate_y(_turn * delta)
	velocity = -global_basis.z * _speed
	move_and_slide()
	global_position = terrain.clamp_inside(global_position, 4.0)
	_track_travel += (_speed + absf(_turn) * TRACK_HALF.y) * delta


func _follow_ground(delta: float, instant: bool) -> void:
	var fwd := -global_basis.z * TRACK_HALF.x
	var side := global_basis.x * TRACK_HALF.y
	var p := global_position
	MachineFx.check_deck(self, p)
	var fl := MachineFx.support(self, terrain, (p + fwd - side))
	var fr := MachineFx.support(self, terrain, (p + fwd + side))
	var bl := MachineFx.support(self, terrain, (p - fwd - side))
	var br := MachineFx.support(self, terrain, (p - fwd + side))
	var pitch := atan2((fl + fr) - (bl + br), 4.0 * TRACK_HALF.x)
	var roll := atan2((fr + br) - (fl + bl), 4.0 * TRACK_HALF.y)
	var t := 1.0 if instant else 1.0 - exp(-8.0 * delta)
	var sink := 0.0 if MachineFx.on_deck(self) else MUD_SINK * terrain.mud_at(p.x, p.z)
	global_position.y = lerpf(p.y, (fl + fr + bl + br) * 0.25 - sink, t)
	_visual.rotation.x = lerp_angle(_visual.rotation.x, pitch, t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, roll, t)


# --- Shredding ----------------------------------------------------------------------------

## Where to bring the wood (markers, the minimap).
func infeed_point() -> Vector3:
	return _visual.to_global(INFEED_CENTER - Vector3(0, 1.3, 0))


func _feed(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.25
		for body in _infeed.get_overlapping_bodies():
			var rb := body as RigidBody3D
			if rb and rb.is_in_group("shreddable") and not rb.freeze and not rb.has_meta("shredding") \
					and not rb.has_meta("strapped_to") and not rb.has_meta("tie_locked"):
				_take(rb)
	for entry in _feeding.duplicate():
		var rb: RigidBody3D = entry[0]
		if not is_instance_valid(rb):
			_feeding.erase(entry)
			continue
		entry[2] = float(entry[2]) + delta
		var t: float = float(entry[2]) / FEED_TIME
		# Drawn in by the rollers (following the machine as it moves), down into the drum.
		var start: Transform3D = _visual.global_transform * (entry[1] as Transform3D)
		var pos := start.origin.lerp(_visual.to_global(MOUTH), smoothstep(0.0, 0.6, t))
		pos.y -= maxf(t - 0.6, 0.0) * 3.0
		rb.global_transform = Transform3D(start.basis.orthonormalized().scaled(Vector3.ONE * clampf(1.4 - t, 0.05, 1.0)), pos)
		if t >= 1.0:
			_finish(rb)
			_feeding.erase(entry)


func _take(rb: RigidBody3D) -> void:
	var main := get_parent()
	if main.get("ties"):
		main.ties.release(rb)
	rb.set_meta("shredding", true)
	rb.remove_from_group("winchable")
	rb.freeze = true
	rb.collision_layer = 0
	rb.collision_mask = 0
	_feeding.append([rb, _visual.global_transform.affine_inverse() * rb.global_transform, 0.0])


func _finish(rb: RigidBody3D) -> void:
	var value := int(rb.get_meta("value", 150))
	total_shredded += 1
	earned += value
	shredded.emit(value, String(rb.get_meta("label", "wood")), rb.global_position)
	var main := get_parent()
	if main.get("net") and rb.has_meta("body_id"):
		main.net.send_removed([int(rb.get_meta("body_id"))])
	rb.queue_free()


# --- Game interface ----------------------------------------------------------------------

func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	_speed = 0.0
	_follow_ground(0.0, true)
	reset_physics_interpolation()


func door_position() -> Vector3:
	return to_global(Vector3(-2.1, 0.0, -1.2))


func controls() -> Vector4:
	return Vector4(_turn / TURN_RATE, 0.0, _speed / MAX_SPEED, 0.0)


func rumble() -> Vector2:
	return Vector2(0.12 + (0.3 if not _feeding.is_empty() else 0.0), 0.0) if driven else Vector2.ZERO


func status() -> String:
	return "%d km/h   ·   SHREDDED %d  ·  $%d" % [roundi(absf(_speed) * 3.6), total_shredded, earned]


func status_fill() -> float:
	return 0.0


func hud_info() -> Dictionary:
	return {"speed": absf(_speed) * 3.6, "max_speed": MAX_SPEED * 3.6,
		"flags": ["SHREDDING" if not _feeding.is_empty() else "INFEED AT THE BACK", "%d SHREDDED" % total_shredded],
		"load": 0.0, "load_text": "EARNED $%d" % earned}


func net_state() -> Array:
	return [_speed, driven, _track_travel, not _feeding.is_empty(), total_shredded, earned]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_speed = s[0]
	driven = s[1]
	_track_travel = s[2]
	_net_busy = s[3]
	total_shredded = s[4]
	earned = s[5]


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	_animate(delta, _net_busy)


func _animate(delta: float, busy: bool) -> void:
	_spin = lerpf(_spin, 9.0 if busy else 0.6, 1.0 - exp(-2.5 * delta))
	_drum.rotation.x += _spin * delta
	for r in _rollers:
		r.rotation.x -= _spin * 0.4 * delta
	_chips.emitting = busy


# --- Model ------------------------------------------------------------------------------

func _build_model() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	cab = _visual
	var body := Kit.paint(GREEN)
	var orange := Kit.paint(ORANGE)
	var dark := Kit.paint(DARK, 0.6, 0.2)
	var steel := Kit.metal(STEEL)
	# Tracks.
	for side in [-1.0, 1.0]:
		var x: float = side * TRACK_HALF.y
		Kit.box(_visual, Vector3(0.66, 0.72, TRACK_HALF.x * 2.0 + 0.6), Vector3(x, 0.37, 0), Kit.matte(Color(0.08, 0.08, 0.08)), 0.3)
		for k in 6:
			Kit.axle(_visual, 0.18, 0.7, Vector3(x, 0.22, -TRACK_HALF.x + 0.3 + k * (TRACK_HALF.x * 2.0 - 0.6) / 5.0), steel, 12)
	Kit.box(_visual, Vector3(2.4, 0.4, 5.2), Vector3(0, 0.95, 0), dark, 0.05)
	# Drum housing in the middle, engine house at the front, spout over the front.
	var housing := PackedVector2Array([Vector2(-1.4, 1.1), Vector2(-1.4, 2.9), Vector2(-0.4, 3.5), Vector2(1.9, 3.5), Vector2(1.9, 1.1)])
	for side in [-1.0, 1.0]:
		Kit.add(_visual, Kit.prism(housing, 0.16), Vector3(side * 1.25, 0, 0.6), body)
	Kit.box(_visual, Vector3(2.66, 0.16, 2.4), Vector3(0, 3.5, 0.85), body, 0.05)
	_drum = Node3D.new()
	_drum.position = Vector3(0, 2.0, 0.7)
	_visual.add_child(_drum)
	Kit.axle(_drum, 0.7, 2.3, Vector3.ZERO, dark, 18)
	for k in 8:
		var a := TAU * k / 8.0
		Kit.box(_drum, Vector3(2.2, 0.16, 0.14), Vector3(0, cos(a), sin(a)) * 0.74, steel, 0.02)
	Kit.box(_visual, Vector3(2.6, 2.2, 1.8), Vector3(0, 2.2, -1.7), body, 0.1)
	Kit.box(_visual, Vector3(2.62, 0.25, 1.82), Vector3(0, 3.0, -1.7), orange, 0.04)
	for k in 5:
		Kit.box(_visual, Vector3(0.05, 1.0, 0.1), Vector3(1.31, 2.1, -2.3 + k * 0.3), dark, 0.0)
	Kit.add(_visual, Kit.cylinder(0.1, 1.0, 10), Vector3(0.8, 3.7, -2.1), dark)
	Kit.beam(_visual, Vector3(0, 3.0, -0.6), Vector3(0, 4.6, -3.6), 0.6, dark)  # chip spout
	Kit.box(_visual, Vector3(0.8, 0.4, 0.6), Vector3(0, 4.6, -3.7), orange, 0.04)
	# Infeed at the back: table, toothed rollers, flared hopper sides, hazard stripes.
	Kit.box(_visual, Vector3(2.6, 0.3, 2.6), Vector3(0, 1.25, 3.4), steel, 0.04)
	for z in [2.4, 3.0]:
		var roller := Node3D.new()
		roller.position = Vector3(0, 1.75 if z < 2.7 else 1.55, z)
		_visual.add_child(roller)
		Kit.axle(roller, 0.3, 2.3, Vector3.ZERO, dark, 14)
		for k in 6:
			var a := TAU * k / 6.0
			Kit.box(roller, Vector3(2.2, 0.1, 0.1), Vector3(0, cos(a), sin(a)) * 0.32, steel, 0.02)
		_rollers.append(roller)
	for side in [-1.0, 1.0]:
		var flare := PackedVector2Array([Vector2(1.8, 1.3), Vector2(1.8, 2.8), Vector2(4.6, 1.9), Vector2(4.6, 1.3)])
		var wall := Kit.add(_visual, Kit.prism(flare, 0.1), Vector3(side * 1.35, 0, 0), orange)
		wall.rotation.y = 0.0
		Kit.box(_visual, Vector3(0.3, 0.05, 2.6), Vector3(side * 1.15, 1.42, 3.4), Kit.hazard(), 0.01)
	Kit.box(_visual, Vector3(2.6, 0.05, 0.3), Vector3(0, 1.42, 4.6), Kit.hazard(), 0.01)
	# Operator's platform on the left with a control box.
	Kit.box(_visual, Vector3(0.9, 0.1, 1.4), Vector3(-1.75, 1.2, -1.2), steel, 0.03)
	Kit.box(_visual, Vector3(0.4, 0.9, 0.35), Vector3(-1.75, 1.7, -1.6), dark, 0.04)
	Kit.box(_visual, Vector3(0.3, 0.25, 0.04), Vector3(-1.75, 2.0, -1.41), Kit.glow(Color(0.3, 0.9, 0.4), 1.2), 0.01)
	for z in [-1.85, -0.55]:
		Kit.beam(_visual, Vector3(-2.15, 1.2, z), Vector3(-2.15, 2.1, z), 0.05, orange)
	Kit.beam(_visual, Vector3(-2.15, 2.1, -1.85), Vector3(-2.15, 2.1, -0.55), 0.05, orange)
	Kit.add(_visual, Kit.sphere(0.16, 10, true), Vector3(-1.0, 3.55, 0.2), Kit.glow(ORANGE, 2.4))
	Kit.label(_visual, "SHREDDER", Vector3(1.34, 2.4, 0.7), 0.0042, Color.WHITE, PI * 0.5)
	Kit.label(_visual, "SHREDDER", Vector3(-1.34, 2.4, 0.7), 0.0042, Color.WHITE, -PI * 0.5)
	seat = Node3D.new()
	seat.position = Vector3(-1.75, 1.25, -1.2)
	_visual.add_child(seat)
	eye = Node3D.new()
	eye.position = Vector3(-1.9, 3.4, 1.0)
	eye.rotation.x = -0.25
	_visual.add_child(eye)
	_chips = GPUParticles3D.new()
	_chips.amount = 60
	_chips.lifetime = 1.3
	_chips.position = Vector3(0, 4.7, -3.9)
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 0.3, -1)
	process.spread = 25.0
	process.initial_velocity_min = 2.0
	process.initial_velocity_max = 4.0
	process.gravity = Vector3(0, -9.8, 0)
	_chips.process_material = process
	var chip := BoxMesh.new()
	chip.size = Vector3(0.08, 0.03, 0.12)
	chip.material = Kit.matte(Color(0.85, 0.68, 0.42))
	_chips.draw_pass_1 = chip
	_chips.emitting = false
	_visual.add_child(_chips)
