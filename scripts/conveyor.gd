extends CharacterBody3D
## Tracked conveyor (a mobile stacker): drive it on its tracks, tip soil into the hopper
## at the back (an excavator bucket or a dump truck), and the belt carries it up and away
## and drops it off the head as a growing pile, or into a truck parked under the head.
## The boom raises and lowers, and it's three sections long: fold it up to drive it,
## unfold it for a 28 m reach. The belt only runs fully unfolded.
## Built facing -Z (its head points forward).

const Kit = preload("res://scripts/model_kit.gd")
const Terrain = preload("res://scripts/terrain.gd")

const MAX_SPEED := 2.2  # m/s on its tracks (half that unfolded)
const ACCELERATION := 1.5
const TURN_RATE := 0.42
const TRACK_HALF := Vector2(2.5, 1.25)  # half length, half spacing
const SECTIONS := [11.0, 9.0, 8.0]  # boom section lengths (m)
const PIVOT := Vector3(0, 1.55, 1.4)  # where the boom hinges, above the hopper end
const RAISE_LIMITS := Vector2(0.06, 0.42)  # boom angle up from flat (rad)
const RAISE_RATE := 0.12
const FOLD_RATE := 0.16  # of the full fold per second
const HOPPER := Vector3(0, 1.75, 2.4)  # hopper mouth centre (model space)
const HOPPER_HALF := Vector2(1.45, 1.25)
const HOPPER_CAPACITY := 40.0  # m3
const FEED_RATE := 12.0  # m3/s from the hopper onto the belt
const BELT_SPEED := 6.0  # m/s
const LUMP_EVERY := 0.25  # s between lumps put on the belt
const MAX_LUMPS := 220
const MUD_SINK := 0.2
const MUD_SLOW := 0.5
const BODY_LAYER := 2
const SOLID_MASK := 32 | 64

const YELLOW := Color(0.96, 0.7, 0.1)
const DARK := Color(0.15, 0.15, 0.16)
const STEEL := Color(0.45, 0.46, 0.48)
const BELT := Color(0.08, 0.08, 0.09)
const SOIL := Color(0.52, 0.31, 0.19)
const GRAVEL := Color(0.58, 0.56, 0.52)

var terrain: Terrain
var driven := false
var preview := false
var mouse_input := {}
var remote := false
var remote_axes := {}
var puppet := false
var machine_name := "Tracked conveyor"
var cab: Node3D
var eye: Node3D
var seat: Node3D
## Loading points: a truck under the head gets the load instead of the ground.
var receivers: Array = []
var hopper := 0.0  # m3 waiting in the hopper
var material := 0  # Terrain.SURFACE_SOIL / SURFACE_GRAVEL (what's in the hopper)
var delivered := 0.0  # m3 dropped off the head in total
var hopper_value := 0.0  # $ of ore in the hopper (see ores.gd), and its gold part
var hopper_gold := 0.0

var _speed := 0.0
var _turn := 0.0
var _raise := 0.2
var _fold := 1.0  # 0 folded for travel .. 1 fully out
var _raise_velocity := 0.0
var _fold_velocity := 0.0
var _lumps: Array = []  # [distance along the belt, m3, material]
var _lump_timer := 0.0
var _track_travel := 0.0
var _spawn := Transform3D()
var _net_xform := Transform3D()
var _net_has := false
var _net_on_belt := 0.0
var _visual: Node3D
var _boom: Node3D  # section 1, hinged at PIVOT
var _hinges: Array[Node3D] = []  # sections 2 and 3, hinged at the end of the one before
var _ram: Node3D
var _lump_view: MultiMeshInstance3D
var _heap: MeshInstance3D  # soil showing in the hopper
var _tracks: Array = []  # track tread materials (scrolled)


func _ready() -> void:
	collision_layer = BODY_LAYER
	collision_mask = SOLID_MASK
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_model()
	Kit.merge_tree(_visual)
	if preview:
		_apply_pose()
		set_physics_process(false)
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 2.2, 5.6)
	shape.shape = box
	shape.position = Vector3(0, 1.2, 0.4)
	add_child(shape)
	# Its tracks knock trees down (and tear out stumps) like the other tracked machines.
	var hull := AnimatableBody3D.new()
	hull.sync_to_physics = false
	hull.collision_layer = 8
	hull.collision_mask = 0
	hull.set_meta("uproots", true)
	var hull_shape := CollisionShape3D.new()
	hull_shape.shape = box
	hull_shape.position = shape.position
	hull.add_child(hull_shape)
	add_child(hull)
	add_to_group("winchable")
	add_to_group("vehicles")
	set_meta("label", "tracked conveyor")
	_spawn = global_transform
	_follow_ground(0.0, true)
	_apply_pose()


func _physics_process(delta: float) -> void:
	if puppet:
		_puppet_step(delta)
		return
	_drive(delta)
	_follow_ground(delta, false)
	_work_boom(delta)
	_apply_pose()
	_run_belt(delta)
	_animate(delta)


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
	var top := MAX_SPEED * (1.0 - MUD_SLOW * mud) * (0.5 if _fold > 0.05 else 1.0)
	_speed = move_toward(_speed, _axis("drive_back", "drive_forward") * top, ACCELERATION * (0.2 if ice else 1.0) * delta)
	_turn = move_toward(_turn, _axis("turn_right", "turn_left") * TURN_RATE, 1.5 * delta)
	rotate_y(_turn * delta)
	velocity = -global_basis.z * _speed
	move_and_slide()
	global_position = terrain.clamp_inside(global_position, 4.0)
	_track_travel += (_speed + absf(_turn) * TRACK_HALF.y) * delta


## Sits it on the ground under its tracks, tilted to match.
func _follow_ground(delta: float, instant: bool) -> void:
	var fwd := -global_basis.z * TRACK_HALF.x
	var side := global_basis.x * TRACK_HALF.y
	var p := global_position
	var fl := terrain.get_height((p + fwd - side).x, (p + fwd - side).z)
	var fr := terrain.get_height((p + fwd + side).x, (p + fwd + side).z)
	var bl := terrain.get_height((p - fwd - side).x, (p - fwd - side).z)
	var br := terrain.get_height((p - fwd + side).x, (p - fwd + side).z)
	var pitch := atan2((fl + fr) - (bl + br), 4.0 * TRACK_HALF.x)
	var roll := atan2((fr + br) - (fl + bl), 4.0 * TRACK_HALF.y)
	var t := 1.0 if instant else 1.0 - exp(-8.0 * delta)
	var sink := MUD_SINK * terrain.mud_at(p.x, p.z)
	global_position.y = lerpf(p.y, (fl + fr + bl + br) * 0.25 - sink, t)
	_visual.rotation.x = lerp_angle(_visual.rotation.x, pitch, t)
	_visual.rotation.z = lerp_angle(_visual.rotation.z, roll, t)


func _work_boom(delta: float) -> void:
	var raise_in := _axis("boom_down", "boom_up")
	var fold_in := _axis("stick_in", "stick_out")
	_raise_velocity = lerpf(_raise_velocity, raise_in * RAISE_RATE, 1.0 - exp(-6.0 * delta))
	_fold_velocity = lerpf(_fold_velocity, fold_in * FOLD_RATE, 1.0 - exp(-6.0 * delta))
	_raise = clampf(_raise + _raise_velocity * delta, RAISE_LIMITS.x, RAISE_LIMITS.y)
	_fold = clampf(_fold + _fold_velocity * delta, 0.0, 1.0)


## Boom angle and the two fold hinges: folded, each section lies back over the last.
func _apply_pose() -> void:
	_boom.rotation.x = _raise
	# (A touch short of a half turn, so the folded sections stack above one another.)
	_hinges[0].rotation.x = -PI * 0.94 * (1.0 - _fold)
	_hinges[1].rotation.x = PI * 0.94 * (1.0 - _fold)
	# The lift ram from the chassis to the underside of section 1.
	var from := _visual.to_global(Vector3(0, 1.05, -1.2))
	var to := _boom.to_global(Vector3(0, -0.25, -4.0))
	var dir := to - from
	var up := dir.normalized()
	var side := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	_ram.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(1, dir.length(), 1)), from)


# --- The belt ---------------------------------------------------------------------------

func running() -> bool:
	return _fold > 0.995


## The belt's path in world space: the hopper, then along each section to the head.
func _belt_path() -> PackedVector3Array:
	var path := PackedVector3Array()
	path.append(_visual.to_global(HOPPER + Vector3(0, -0.5, 0)))
	path.append(_boom.to_global(Vector3(0, 0.3, 0)))
	path.append(_hinges[0].to_global(Vector3(0, 0.3, 0)))
	path.append(_hinges[1].to_global(Vector3(0, 0.3, 0)))
	path.append(_hinges[1].to_global(Vector3(0, 0.3, -float(SECTIONS[2]))))
	return path


func _belt_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for k in path.size() - 1:
		total += path[k].distance_to(path[k + 1])
	return total


func _point_along(path: PackedVector3Array, d: float) -> Vector3:
	for k in path.size() - 1:
		var seg := path[k].distance_to(path[k + 1])
		if d <= seg:
			return path[k].lerp(path[k + 1], d / maxf(seg, 0.001))
		d -= seg
	return path[path.size() - 1]


## Where the load comes off: the head drum.
func head_point() -> Vector3:
	return _hinges[1].to_global(Vector3(0, 0.0, -float(SECTIONS[2]) - 0.3))


func _run_belt(delta: float) -> void:
	if not running():
		_show_lumps(_belt_path())
		return
	var path := _belt_path()
	var length := _belt_length(path)
	# Feed the hopper onto the belt in lumps.
	_lump_timer -= delta
	if _lump_timer <= 0.0 and hopper > 0.01 and _lumps.size() < MAX_LUMPS:
		_lump_timer = LUMP_EVERY
		var amount := minf(hopper, FEED_RATE * LUMP_EVERY)
		var share := amount / maxf(hopper, 0.0001)
		var value := hopper_value * share
		var gold := hopper_gold * share
		hopper_value -= value
		hopper_gold -= gold
		hopper -= amount
		_lumps.append([0.0, amount, material, value, gold])
		_update_heap()
	# Carry them up, and drop each off the head.
	var k := 0
	while k < _lumps.size():
		var lump: Array = _lumps[k]
		lump[0] = float(lump[0]) + BELT_SPEED * delta
		if float(lump[0]) >= length:
			_discharge(float(lump[1]), int(lump[2]), float(lump[3]) if lump.size() > 3 else 0.0, float(lump[4]) if lump.size() > 4 else 0.0)
			_lumps.remove_at(k)
		else:
			k += 1
	_show_lumps(path)


func _discharge(amount: float, what: int, value := 0.0, gold := 0.0) -> void:
	var head := head_point()
	# It falls straight down: anything below the head with an open body takes it.
	var ground := terrain.get_height(head.x, head.z)
	for r in receivers:
		if not is_instance_valid(r) or r == self:
			continue
		var caught := false
		for y in [ground + 2.2, ground + 1.5, ground + 3.2]:
			if r.accepts_soil(Vector3(head.x, y, head.z)):
				caught = true
				break
		if caught:
			var poured := amount
			amount -= r.add_soil(amount, what)
			if r.has_method("add_value") and poured > 0.0:
				r.add_value(value * (poured - amount) / poured, gold * (poured - amount) / poured)
			break
	if amount > 0.0:
		terrain.deposit(head.x, head.z, amount, 1.7, what)
	delivered += amount


func _show_lumps(path: PackedVector3Array) -> void:
	var mm := _lump_view.multimesh
	var count := mini(_lumps.size(), MAX_LUMPS)
	mm.visible_instance_count = count
	var inverse := _lump_view.global_transform.affine_inverse()
	for k in count:
		var lump: Array = _lumps[k]
		var size := clampf(float(lump[1]) / (FEED_RATE * LUMP_EVERY), 0.35, 1.0)
		var at := _point_along(path, float(lump[0])) + Vector3(0, 0.12, 0)
		mm.set_instance_transform(k, inverse * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * size), at))
		mm.set_instance_color(k, GRAVEL if int(lump[2]) == Terrain.SURFACE_GRAVEL else SOIL)


# --- Taking loads -----------------------------------------------------------------------

## True if soil dropped at `point` would land in the hopper (and there's room).
func accepts_soil(point: Vector3) -> bool:
	if hopper >= HOPPER_CAPACITY - 0.01:
		return false
	var local := _visual.to_local(point) - HOPPER
	# (Low as well as high: a tipping truck's load leaves its tailgate below the hopper rim.)
	return absf(local.x) < HOPPER_HALF.x + 1.1 and absf(local.z) < HOPPER_HALF.y + 2.2 and local.y > -2.6 and local.y < 6.0


func add_value(value: float, gold: float) -> void:
	hopper_value += value
	hopper_gold += gold


## Tips soil (or gravel) into the hopper; returns how much fitted.
func add_soil(amount: float, what := 0) -> float:
	var taken := minf(amount, HOPPER_CAPACITY - hopper)
	if taken > hopper:
		material = what
	hopper += taken
	_update_heap()
	return taken


func on_belt() -> float:
	var total := 0.0
	for lump in _lumps:
		total += float(lump[1])
	return total


func _update_heap() -> void:
	_heap.visible = hopper > 0.05
	var fill := clampf(hopper / HOPPER_CAPACITY, 0.0, 1.0)
	_heap.scale = Vector3(1.0, 0.15 + fill * 0.85, 1.0)
	_heap.material_override = Kit.matte(GRAVEL if material == Terrain.SURFACE_GRAVEL else SOIL)


# --- Game interface ----------------------------------------------------------------------

func reset() -> void:
	place(_spawn)


func place(xform: Transform3D) -> void:
	global_transform = xform
	_speed = 0.0
	_follow_ground(0.0, true)
	_apply_pose()
	reset_physics_interpolation()


func door_position() -> Vector3:
	return to_global(Vector3(-2.2, 0.0, 1.4))


func controls() -> Vector4:
	return Vector4(_turn / TURN_RATE, _raise_velocity / RAISE_RATE, _speed / MAX_SPEED, _fold_velocity / FOLD_RATE)


func rumble() -> Vector2:
	return Vector2(0.12 + (0.2 if running() and not _lumps.is_empty() else 0.0), 0.0) if driven else Vector2.ZERO


func status() -> String:
	return "%d km/h   ·   HOPPER %.1f / %.0f m³   ·   %s" % [roundi(absf(_speed) * 3.6), hopper, HOPPER_CAPACITY,
		"BELT RUNNING" if running() else "FOLDED %d%%" % roundi((1.0 - _fold) * 100.0)]


func status_fill() -> float:
	return hopper / HOPPER_CAPACITY


func hud_info() -> Dictionary:
	var info := {"speed": absf(_speed) * 3.6, "max_speed": MAX_SPEED * 3.6,
		"flags": ["BELT %.1f m³" % (on_belt() if not puppet else _net_on_belt) if running() else "UNFOLD TO RUN (stick out)"],
		"load": hopper / HOPPER_CAPACITY, "load_text": "HOPPER %.1f / %.0f m³" % [hopper, HOPPER_CAPACITY]}
	info.flags.append("REACH %.0f m" % (_boom.global_position.distance_to(head_point())))
	return info


## Multiplayer state (host -> joining players).
func net_state() -> Array:
	return [_raise, _fold, _speed, hopper, on_belt(), driven, _track_travel, material]


func apply_net_state(xform: Transform3D, s: Array) -> void:
	_net_xform = xform
	if not _net_has:
		_net_has = true
		global_transform = xform
	_raise = s[0]
	_fold = s[1]
	_speed = s[2]
	if absf(float(s[3]) - hopper) > 0.05:
		hopper = s[3]
		_update_heap()
	_net_on_belt = s[4]
	driven = s[5]
	_track_travel = s[6]
	material = s[7]


func _puppet_step(delta: float) -> void:
	if not _net_has:
		return
	var t := 1.0 - exp(-14.0 * delta)
	global_transform = global_transform.interpolate_with(_net_xform, t)
	_apply_pose()
	# Lumps spread evenly along the belt in proportion to what's on it.
	var path := _belt_path()
	var length := _belt_length(path)
	var n := clampi(roundi(_net_on_belt / (FEED_RATE * LUMP_EVERY)), 0, MAX_LUMPS) if running() else 0
	_lumps.clear()
	for k in n:
		_lumps.append([fposmod(k * length / maxf(n, 1) + _track_travel * 0.0 + Time.get_ticks_msec() * 0.001 * BELT_SPEED, length), FEED_RATE * LUMP_EVERY, material])
	_show_lumps(path)
	_animate(delta)


func _animate(_delta: float) -> void:
	for mat in _tracks:
		(mat as ShaderMaterial).set_shader_parameter("scroll", -_track_travel)


# --- Model ------------------------------------------------------------------------------

func _build_model() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	cab = _visual
	var paint := Kit.paint(YELLOW)
	var dark := Kit.paint(DARK, 0.6, 0.2)
	var steel := Kit.metal(STEEL)
	var belt := Kit.matte(BELT)
	# Tracks: frames with rollers, sprocket and idler, a tread that scrolls.
	for side in [-1.0, 1.0]:
		var x: float = side * TRACK_HALF.y
		Kit.box(_visual, Vector3(0.62, 0.62, TRACK_HALF.x * 2.0 + 0.4), Vector3(x, 0.36, 0), dark, 0.1)
		for k in 6:
			Kit.axle(_visual, 0.18, 0.66, Vector3(x, 0.2, -TRACK_HALF.x + 0.4 + k * (TRACK_HALF.x * 2.0 - 0.8) / 5.0), steel, 12)
		Kit.axle(_visual, 0.34, 0.66, Vector3(x, 0.38, -TRACK_HALF.x - 0.05), steel, 16)
		Kit.axle(_visual, 0.34, 0.66, Vector3(x, 0.38, TRACK_HALF.x + 0.05), steel, 16)
		var tread := _tread_material()
		_tracks.append(tread)
		var pads := Kit.add(_visual, Kit.rounded_box(Vector3(0.66, 0.74, TRACK_HALF.x * 2.0 + 0.7), 0.3, 2), Vector3(x, 0.37, 0), tread)
		pads.set_meta("keep", true)
	# Chassis, engine pack with exhaust, and the operator's platform with its controls.
	Kit.box(_visual, Vector3(2.2, 0.4, 5.4), Vector3(0, 0.9, 0.2), paint, 0.06)
	Kit.box(_visual, Vector3(1.6, 1.1, 1.6), Vector3(0, 1.6, -1.6), paint, 0.1)
	for k in 5:
		Kit.box(_visual, Vector3(0.05, 0.6, 1.2), Vector3(0.81, 1.6, -1.6 - 0.25 + k * 0.12), dark, 0.0)
	Kit.add(_visual, Kit.cylinder(0.08, 0.7, 10), Vector3(0.45, 2.45, -1.9), dark)
	Kit.box(_visual, Vector3(1.0, 0.1, 1.2), Vector3(-1.65, 1.15, 1.4), steel, 0.03)  # platform
	for z in [0.85, 1.95]:
		Kit.beam(_visual, Vector3(-2.1, 1.15, z), Vector3(-2.1, 2.1, z), 0.05, Kit.paint(Color(0.95, 0.75, 0.1)))
	Kit.beam(_visual, Vector3(-2.1, 2.1, 0.85), Vector3(-2.1, 2.1, 1.95), 0.05, Kit.paint(Color(0.95, 0.75, 0.1)))
	Kit.box(_visual, Vector3(0.5, 1.0, 0.4), Vector3(-1.4, 1.7, 0.9), dark, 0.05)  # control box
	Kit.box(_visual, Vector3(0.4, 0.3, 0.05), Vector3(-1.4, 2.0, 1.11), Kit.glow(Color(0.3, 0.9, 0.4), 1.2), 0.01)
	Kit.label(_visual, "EARTHWORKS", Vector3(1.11, 1.0, 0.2), 0.006, Color(0.1, 0.1, 0.1), PI * 0.5)
	seat = Node3D.new()
	seat.position = Vector3(-1.65, 1.2, 1.4)
	seat.rotation.y = 0.0
	_visual.add_child(seat)
	eye = Node3D.new()
	eye.position = Vector3(-1.65, 2.9, 2.6)
	eye.rotation.x = -0.18
	_visual.add_child(eye)
	# Hopper: flared walls round a feeder at the tail of the belt.
	var mouth := HOPPER
	Kit.box(_visual, Vector3(2.0, 0.5, 1.8), mouth + Vector3(0, -0.7, 0), dark, 0.05)
	for side in [-1.0, 1.0]:
		var wall := Kit.box(_visual, Vector3(0.1, 1.3, HOPPER_HALF.y * 2.0), mouth + Vector3(side * (HOPPER_HALF.x - 0.25), 0.05, 0), paint, 0.03)
		wall.rotation.z = -0.35 * side
		var end := Kit.box(_visual, Vector3(HOPPER_HALF.x * 2.0, 1.3, 0.1), mouth + Vector3(0, 0.05, side * (HOPPER_HALF.y - 0.25)), paint, 0.03)
		end.rotation.x = 0.35 * side
	Kit.box(_visual, Vector3(HOPPER_HALF.x * 2.0 + 0.1, 0.08, 0.1), mouth + Vector3(0, 0.7, HOPPER_HALF.y), Kit.hazard(), 0.01)
	_heap = MeshInstance3D.new()
	var dome := SphereMesh.new()
	dome.radius = 1.05
	dome.height = 1.2
	dome.is_hemisphere = true
	dome.radial_segments = 12
	dome.rings = 4
	_heap.mesh = dome
	_heap.position = mouth + Vector3(0, -0.4, 0)
	_heap.set_meta("keep", true)
	_heap.visible = false
	_visual.add_child(_heap)
	# The boom: three sections, each a lattice frame carrying the belt, hinged end to end.
	_boom = Node3D.new()
	_boom.position = PIVOT
	_visual.add_child(_boom)
	var parent := _boom
	for k in SECTIONS.size():
		var length: float = SECTIONS[k]
		var width := 1.1 - k * 0.12
		_build_section(parent, length, width, paint, dark, steel, belt)
		if k < SECTIONS.size() - 1:
			var hinge := Node3D.new()
			hinge.position = Vector3(0, 0, -length)
			parent.add_child(hinge)
			_hinges.append(hinge)
			parent = hinge
	# Head drum and a spill hood at the far end.
	Kit.axle(parent, 0.32, 0.9, Vector3(0, 0.1, -float(SECTIONS[2])), steel, 16)
	Kit.box(parent, Vector3(1.0, 0.5, 0.6), Vector3(0, 0.45, -float(SECTIONS[2]) + 0.1), paint, 0.05)
	_ram = Node3D.new()
	_visual.add_child(_ram)
	Kit.add(_ram, Kit.cylinder(0.12, 1.0, 12, 0.09), Vector3(0, 0.5, 0), Kit.metal(Color(0.8, 0.8, 0.82)))
	# Lumps of soil riding the belt.
	_lump_view = MultiMeshInstance3D.new()
	_lump_view.top_level = true
	var lump := SphereMesh.new()
	lump.radius = 0.32
	lump.height = 0.4
	lump.radial_segments = 6
	lump.rings = 3
	var lump_mat := StandardMaterial3D.new()
	lump_mat.vertex_color_use_as_albedo = true
	lump_mat.roughness = 1.0
	lump.material = lump_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = lump
	mm.instance_count = MAX_LUMPS
	mm.visible_instance_count = 0
	_lump_view.multimesh = mm
	_lump_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lump_view)


func _build_section(parent: Node3D, length: float, width: float, paint: Material, dark: Material, steel: Material, belt: Material) -> void:
	var half := width * 0.5
	for side in [-1.0, 1.0]:
		Kit.beam(parent, Vector3(side * half, 0.0, 0.0), Vector3(side * half, 0.0, -length), 0.14, paint)  # top chord
		Kit.beam(parent, Vector3(side * half * 0.8, -0.6, -0.2), Vector3(side * half * 0.8, -0.45, -length + 0.2), 0.1, paint)
		var bays := int(length / 1.5)
		for b in bays:
			var z0 := -b * length / bays
			var z1 := -(b + 1) * length / bays
			Kit.beam(parent, Vector3(side * half, 0.0, z0), Vector3(side * half * 0.8, -0.55, z1), 0.06, paint)  # lattice
	Kit.box(parent, Vector3(width - 0.2, 0.06, length), Vector3(0, 0.2, -length * 0.5), belt, 0.01)  # belt
	var rollers := int(length / 1.2)
	for r in rollers:
		Kit.axle(parent, 0.07, width - 0.15, Vector3(0, 0.12, -0.5 - r * (length - 1.0) / maxf(rollers - 1, 1)), steel, 8)
	for side in [-1.0, 1.0]:
		Kit.box(parent, Vector3(0.05, 0.25, length), Vector3(side * (half - 0.05), 0.32, -length * 0.5), dark, 0.0)  # skirts
	Kit.axle(parent, 0.22, width + 0.1, Vector3(0, -0.05, 0.0), steel, 14)  # hinge pin


func _tread_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform float scroll = 0.0;
varying vec3 local_pos;
void vertex() { local_pos = VERTEX; }
void fragment() {
	float lug = step(0.5, fract((local_pos.z + scroll) * 3.0));
	ALBEDO = mix(vec3(0.05), vec3(0.11), lug);
	ROUGHNESS = 0.9;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat
