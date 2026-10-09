extends Camera3D
## Orbit camera. In a machine it trails behind the cab, or sits in the operator's seat
## (cab view: scroll all the way in, or V / right-stick click). On foot it orbits freely
## (right-drag, right stick, Q/E/I/K) and the worker walks relative to it.

const Terrain = preload("res://scripts/terrain.gd")

const MIN_DISTANCE := 5.0
const MAX_DISTANCE := 35.0

var target: Node3D
var terrain: Terrain
var follow_yaw := true
var distance := 15.0
var pitch := 0.5
var orbit := 0.0
## Operator's eye inside the cab; when set, cab view is available.
var eye: Node3D
var cab_view := false
## Right-drag orbits only on foot; in a machine the mouse buttons drive the arm.
var mouse_orbit := true
var _yaw := 0.0
var _look := Vector2.ZERO  # cab view head turn: yaw, pitch
var _look_keys := Vector2.ZERO


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	current = true
	fov = 62.0
	near = 0.05
	far = 1500.0


## Switch what the camera looks at; `follow` makes it trail the target's heading.
func set_target(node: Node3D, follow: bool, dist: float) -> void:
	target = node
	if follow != follow_yaw:
		orbit = 0.0 if follow else _yaw
	follow_yaw = follow
	distance = dist


func toggle_cab_view() -> void:
	cab_view = not cab_view and eye != null
	_look = Vector2.ZERO
	_look_keys = Vector2.ZERO
	fov = 72.0 if cab_view else 62.0


func snap() -> void:
	_yaw = _desired_yaw()
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion and cab_view and Input.is_key_pressed(KEY_ALT):
		_look_keys.x = clampf(_look_keys.x - motion.relative.x * 0.004, -2.0, 2.0)
		_look_keys.y = clampf(_look_keys.y - motion.relative.y * 0.004, -0.8, 0.6)
		return
	if motion and mouse_orbit and motion.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		orbit -= motion.relative.x * 0.005
		pitch = clampf(pitch + motion.relative.y * 0.004, 0.05, 1.3)
		return
	var button := event as InputEventMouseButton
	if button and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			if distance <= MIN_DISTANCE and eye and not cab_view:
				toggle_cab_view()
			distance = maxf(distance - 1.0, MIN_DISTANCE)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if cab_view:
				toggle_cab_view()
				distance = MIN_DISTANCE + 3.0
			else:
				distance = minf(distance + 1.0, MAX_DISTANCE)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_view") and eye:
		toggle_cab_view()
	if cab_view and eye:
		_look_around(delta)
		_update_transform()
		return
	var turn := Input.get_axis("camera_right", "camera_left")
	if not follow_yaw:
		turn += Input.get_axis("swing_right", "swing_left")
		pitch = clampf(pitch + Input.get_axis("boom_down", "boom_up") * 1.2 * delta, 0.05, 1.3)
	orbit += turn * 1.8 * delta
	distance = clampf(distance + Input.get_axis("camera_in", "camera_out") * 12.0 * delta, MIN_DISTANCE, MAX_DISTANCE)
	_yaw = lerp_angle(_yaw, _desired_yaw(), 1.0 - exp(-6.0 * delta))
	_update_transform()


## In the cab: turn your head with the D-pad / Z,C,-,= keys, or hold Alt and move the mouse.
func _look_around(delta: float) -> void:
	_look_keys.x = clampf(_look_keys.x + Input.get_axis("camera_right", "camera_left") * 1.6 * delta, -2.0, 2.0)
	_look_keys.y = clampf(_look_keys.y + Input.get_axis("camera_out", "camera_in") * 1.0 * delta, -0.8, 0.6)
	_look = _look.lerp(_look_keys, 1.0 - exp(-8.0 * delta))


func _desired_yaw() -> float:
	return target.get_global_transform_interpolated().basis.get_euler().y + orbit if follow_yaw else orbit


func _update_transform() -> void:
	if cab_view and eye:
		global_transform = (eye.get_global_transform_interpolated() * Transform3D(Basis.from_euler(Vector3(_look.y, _look.x, 0)))).orthonormalized()
		return
	var focus := target.get_global_transform_interpolated().origin + Vector3(0, 1.5, 0)
	var offset := Vector3(sin(_yaw) * cos(pitch), sin(pitch), cos(_yaw) * cos(pitch)) * distance
	var pos := focus + offset
	pos.y = maxf(pos.y, terrain.get_height(pos.x, pos.z) + 0.5)
	global_position = pos
	look_at(focus)
