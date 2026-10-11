extends CharacterBody3D
## Portable forge on tracks: tip ore-rich soil into the hopper at its back (excavator
## bucket, dump truck or conveyor) and it smelts it, pouring the metal into ingots that
## slide out of the chute at the front: gold bars from the gold bands, silver bars from
## the rest. Smelting is worth half as much again as crushing. Pick the bars up with the
## excavator's magnet and sell them at a shredder or the ore crusher. Built facing -Z.

const Kit = preload("res://scripts/model_kit.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Ores = preload("res://scripts/ores.gd")

const MAX_SPEED := 2.0
const ACCELERATION := 1.3
const TURN_RATE := 0.45
const TRACK_HALF := Vector2(2.2, 1.2)
const HOPPER := Vector3(0, 1.9, 2.5)  # hopper mouth (model space), low at the back for a tailgate
const HOPPER_HALF := Vector2(1.4, 1.2)
const CAPACITY := 12.0  # m3
const SMELT_RATE := 0.8  # m3 a second
const BONUS := 1.5  # bars are worth this much more than the crusher pays
const CHUTE := Vector3(0, 1.0, -3.4)
const BAR_EVERY := 0.6
const MUD_SINK := 0.2
const MUD_SLOW := 0.5
const BODY_LAYER := 2
const SOLID_MASK := 32 | 64

const RED := Color(0.62, 0.16, 0.1)
const DARK := Color(0.15, 0.15, 0.16)
const STEEL := Color(0.5, 0.51, 0.53)

var terrain: Terrain
var driven := false
var preview := false
var mouse_input := {}
var remote := false
var remote_axes := {}
var puppet := false
var machine_name := "Portable forge"
var cab: Node3D
var eye: Node3D
var seat: Node3D
var hopper := 0.0  # m3 of soil waiting to smelt
var hopper_value := 0.0  # $ of ore in it, and the gold part
var hopper_gold := 0.0
var gold_metal := 0.0  # $ of molten metal waiting to make a bar
var silver_metal := 0.0
var bars_made := 0

var _speed := 0.0
var _turn := 0.0
var _track_travel := 0.0
var _bar_timer := 0.0
var _spawn := Transform3D()
var _net_xform := Transform3D()
var _net_has := false
var _visual: Node3D
var _glow: MeshInstance3D
var _glow_mat: StandardMaterial3D
var _smoke: GPUParticles3D
var _heap: MeshInstance3D


func _ready() -> void:
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_model()
	Kit.merge_tree(_visual)
	if preview:
		set_physics_process(false)
		return
	# Solid: the furnace end, and only a low deck under the hopper (so a truck can back
	# its tailgate over it).
	for b in [[Vector3(2.8, 3.2, 3.8), Vector3(0, 1.7, -0.9)], [Vector3(2.6, 1.1, 1.6), Vector3(0, 0.75, 2.3)]]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = b[0]
		shape.shape = box
		shape.position = b[1]
		add_child(shape)
	add_to_group("winchable")
	add_to_group("vehicles")
	set_meta("label", "portable forge")
	_spawn = global_transform
	_follow_ground(0.0, true)


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	_drive(delta)
	_follow_ground(delta, false)
	_smelt(delta)
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
	_speed = move_toward(_speed, _axis("drive_back", "drive_forward") * MAX_SPEED * (1.0 - MUD_SLOW * mud), ACCELERATION * (0.2 if ice else 1.0) * delta)
	_turn = move_toward(_turn, _axis("turn_right", "turn_left") * TURN_RATE, 1.5 * delta)
	rotate_y(_turn * delta)
	velocity = -global_basis.z * _speed
	move_and_slide()
	global_position = terrain.clamp_inside(global_position, 4.0)
	_track_travel += _speed * delta


func _follow_ground(delta: float, instant: bool) -> void:
	var fwd := -global_basis.z * TRACK_HALF.x
	var side := global_basis.x * TRACK_HALF.y
	var p := global_position
	var fl := terrain.get_height((p + fwd - side).x, (p + fwd - side).z)
	var fr := terrain.get_height((p + fwd + side).x, (p + fwd + side).z)
	var bl := terrain.get_height((p - fwd - side).x, (p - fwd - side).z)
	var br := terrain.get_height((p - fwd + side).x, (p - fwd + side).z)
	var t := 1.0 if instant else 1.0 - exp(-8.0 * delta)
	global_position.y = lerpf(p.y, (fl + fr + bl + br) * 0.25 - MUD_SINK * terrain.mud_at(p.x, p.z), t)
	_visual.rotation.x = lerp_angle(_visual.rotation.x, atan2((fl + fr) - (bl + br), 4.0 * TRACK_HALF.x), t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, atan2((fr + br) - (fl + bl), 4.0 * TRACK_HALF.y), t)


# --- Smelting -----------------------------------------------------------------------------

## Soil dropped at `point` lands in the hopper (and there's room).
func accepts_soil(point: Vector3) -> bool:
	if hopper >= CAPACITY - 0.01:
		return false
	var local := _visual.to_local(point) - HOPPER
	# (Generous behind the machine: a tipping truck's tailgate swings back as it rises.)
	return absf(local.x) < HOPPER_HALF.x + 1.5 and local.z > -HOPPER_HALF.y - 1.0 and local.z < HOPPER_HALF.y + 4.0 		and local.y > -4.0 and local.y < 7.0


func add_soil(amount: float, _what := 0) -> float:
	var taken := minf(amount, CAPACITY - hopper)
	hopper += taken
	_update_heap()
	return taken


func add_value(value: float, gold: float) -> void:
	hopper_value += value
	hopper_gold += gold


func smelting() -> bool:
	return hopper > 0.01


func _smelt(delta: float) -> void:
	if hopper > 0.0:
		var amount := minf(hopper, SMELT_RATE * delta)
		var share := amount / hopper
		var value := hopper_value * share
		var gold := hopper_gold * share
		hopper -= amount
		hopper_value -= value
		hopper_gold -= gold
		gold_metal += gold * BONUS
		silver_metal += (value - gold) * BONUS
		_update_heap()
	_bar_timer -= delta
	if _bar_timer > 0.0:
		return
	var kind := ""
	if gold_metal >= Ores.BAR_VALUE.gold_bar:
		kind = "gold_bar"
		gold_metal -= Ores.BAR_VALUE.gold_bar
	elif silver_metal >= Ores.BAR_VALUE.silver_bar:
		kind = "silver_bar"
		silver_metal -= Ores.BAR_VALUE.silver_bar
	if kind == "":
		return
	_bar_timer = BAR_EVERY
	bars_made += 1
	var main := get_parent()
	if main.has_method("spawn_ore"):
		var at := _visual.to_global(CHUTE) + global_basis.x * randf_range(-0.3, 0.3)
		var bar: RigidBody3D = main.spawn_ore(kind, Transform3D(global_basis, at))
		bar.linear_velocity = -global_basis.z * 1.5


# --- Game interface ----------------------------------------------------------------------

func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	_speed = 0.0
	_follow_ground(0.0, true)
	reset_physics_interpolation()


func door_position() -> Vector3:
	return to_global(Vector3(-2.0, 0.0, -0.8))


func controls() -> Vector4:
	return Vector4(_turn / TURN_RATE, 0.0, _speed / MAX_SPEED, 0.0)


func rumble() -> Vector2:
	return Vector2(0.1 + (0.15 if smelting() else 0.0), 0.0) if driven else Vector2.ZERO


func status() -> String:
	return "%d km/h   ·   HOPPER %.1f / %.0f m³   ·   %s" % [roundi(absf(_speed) * 3.6), hopper, CAPACITY, "SMELTING" if smelting() else "IDLE"]


func status_fill() -> float:
	return hopper / CAPACITY


func hud_info() -> Dictionary:
	return {"speed": absf(_speed) * 3.6, "max_speed": MAX_SPEED * 3.6,
		"flags": ["SMELTING" if smelting() else "TIP ORE-RICH SOIL IN THE HOPPER",
			"GOLD $%d / %d" % [roundi(gold_metal), Ores.BAR_VALUE.gold_bar], "SILVER $%d / %d" % [roundi(silver_metal), Ores.BAR_VALUE.silver_bar],
			"%d BARS MADE" % bars_made],
		"load": hopper / CAPACITY, "load_text": "HOPPER %.1f / %.0f m³  ·  ORE $%d" % [hopper, CAPACITY, roundi(hopper_value)]}


func net_state() -> Array:
	return [_speed, driven, _track_travel, hopper, bars_made]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_speed = s[0]
	driven = s[1]
	_track_travel = s[2]
	if absf(float(s[3]) - hopper) > 0.05:
		hopper = s[3]
		_update_heap()
	bars_made = s[4]


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	global_transform = global_transform.interpolate_with(_net_xform, 1.0 - exp(-14.0 * delta))
	_animate()


func _animate() -> void:
	var hot := smelting()
	_glow_mat.emission_energy_multiplier = lerpf(_glow_mat.emission_energy_multiplier, 3.5 if hot else 0.6, 0.05)
	_smoke.emitting = hot


func _update_heap() -> void:
	_heap.visible = hopper > 0.05
	_heap.scale = Vector3(1.0, 0.15 + clampf(hopper / CAPACITY, 0.0, 1.0) * 0.85, 1.0)


# --- Model ------------------------------------------------------------------------------

func _build_model() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	cab = _visual
	var body := Kit.paint(RED)
	var dark := Kit.paint(DARK, 0.6, 0.2)
	var steel := Kit.metal(STEEL)
	for side in [-1.0, 1.0]:
		var x: float = side * TRACK_HALF.y
		Kit.box(_visual, Vector3(0.66, 0.72, TRACK_HALF.x * 2.0 + 0.6), Vector3(x, 0.37, 0), Kit.matte(Color(0.08, 0.08, 0.08)), 0.3)
		for k in 5:
			Kit.axle(_visual, 0.18, 0.7, Vector3(x, 0.22, -TRACK_HALF.x + 0.3 + k * (TRACK_HALF.x * 2.0 - 0.6) / 4.0), steel, 12)
	Kit.box(_visual, Vector3(2.4, 0.4, 5.0), Vector3(0, 0.95, 0), dark, 0.05)
	# The furnace: a squat brick-lined drum with a glowing mouth, chimney and hopper.
	Kit.add(_visual, Kit.cylinder(1.25, 2.4, 14), Vector3(0, 2.3, -0.3), body)
	for y in [1.4, 3.2]:
		Kit.add(_visual, Kit.cylinder(1.3, 0.12, 14), Vector3(0, y, -0.3), steel)
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.albedo_color = Color(1.0, 0.45, 0.1)
	_glow_mat.emission_enabled = true
	_glow_mat.emission = Color(1.0, 0.4, 0.08)
	_glow_mat.emission_energy_multiplier = 0.6
	_glow = Kit.box(_visual, Vector3(0.9, 0.6, 0.06), Vector3(0, 2.0, -1.56), _glow_mat, 0.02)
	_glow.set_meta("keep", true)
	Kit.add(_visual, Kit.cylinder(0.25, 2.2, 10), Vector3(0.6, 4.5, -0.7), dark)
	# Hopper at the back.
	var mouth := HOPPER
	Kit.box(_visual, Vector3(1.6, 0.8, 1.4), mouth + Vector3(0, -0.6, 0), dark, 0.05)
	Kit.beam(_visual, mouth + Vector3(0, -0.6, -0.6), Vector3(0, 2.2, 0.8), 0.5, dark)  # feed screw into the furnace
	for side in [-1.0, 1.0]:
		var wall := Kit.box(_visual, Vector3(0.1, 1.2, HOPPER_HALF.y * 2.0), mouth + Vector3(side * (HOPPER_HALF.x - 0.25), 0.1, 0), body, 0.03)
		wall.rotation.z = -0.35 * side
		var end := Kit.box(_visual, Vector3(HOPPER_HALF.x * 2.0, 1.2, 0.1), mouth + Vector3(0, 0.1, side * (HOPPER_HALF.y - 0.25)), body, 0.03)
		end.rotation.x = 0.35 * side
	_heap = MeshInstance3D.new()
	var dome := SphereMesh.new()
	dome.radius = 1.0
	dome.height = 1.1
	dome.is_hemisphere = true
	dome.radial_segments = 12
	dome.rings = 4
	dome.material = Kit.matte(Color(0.56, 0.33, 0.2))
	_heap.mesh = dome
	_heap.position = mouth + Vector3(0, -0.5, 0)
	_heap.set_meta("keep", true)
	_heap.visible = false
	_visual.add_child(_heap)
	# Ingot chute at the front.
	var chute := Kit.box(_visual, Vector3(1.0, 0.1, 1.8), Vector3(0, 1.3, -2.6), steel, 0.02)
	chute.rotation.x = 0.35
	for side in [-1.0, 1.0]:
		var lip := Kit.box(_visual, Vector3(0.08, 0.25, 1.8), Vector3(side * 0.5, 1.42, -2.6), steel, 0.01)
		lip.rotation.x = 0.35
	# Operator's platform on the left.
	Kit.box(_visual, Vector3(0.9, 0.1, 1.3), Vector3(-1.75, 1.2, -0.8), steel, 0.03)
	Kit.box(_visual, Vector3(0.4, 0.9, 0.35), Vector3(-1.75, 1.7, -1.2), dark, 0.04)
	Kit.box(_visual, Vector3(0.3, 0.25, 0.04), Vector3(-1.75, 2.0, -1.01), Kit.glow(Color(1.0, 0.6, 0.1), 1.2), 0.01)
	Kit.label(_visual, "FORGE", Vector3(1.27, 2.3, -0.3), 0.005, Color.WHITE, PI * 0.5)
	Kit.label(_visual, "FORGE", Vector3(-1.27, 2.3, -0.3), 0.005, Color.WHITE, -PI * 0.5)
	seat = Node3D.new()
	seat.position = Vector3(-1.75, 1.25, -0.8)
	_visual.add_child(seat)
	eye = Node3D.new()
	eye.position = Vector3(-1.9, 3.4, 1.4)
	eye.rotation.x = -0.25
	_visual.add_child(eye)
	_smoke = GPUParticles3D.new()
	_smoke.amount = 40
	_smoke.lifetime = 2.5
	_smoke.position = Vector3(0.6, 5.7, -0.7)
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 1, 0)
	process.spread = 12.0
	process.initial_velocity_min = 1.0
	process.initial_velocity_max = 2.0
	process.gravity = Vector3(0, 0.3, 0)
	process.scale_min = 0.6
	process.scale_max = 1.6
	_smoke.process_material = process
	var puff := SphereMesh.new()
	puff.radius = 0.3
	puff.height = 0.6
	puff.radial_segments = 6
	puff.rings = 3
	var smoke_mat := StandardMaterial3D.new()
	smoke_mat.albedo_color = Color(0.35, 0.35, 0.36, 0.6)
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.material = smoke_mat
	_smoke.draw_pass_1 = puff
	_smoke.emitting = false
	_visual.add_child(_smoke)
