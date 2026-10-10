extends RefCounted
## Registers every input action in code so keyboard and controller bindings
## live in one readable place instead of inside project.godot.

const DEADZONE := 0.2


static func setup() -> void:
	# Driving: WASD / left stick
	_add("drive_forward", [KEY_W], [[JOY_AXIS_LEFT_Y, -1.0]], [])
	_add("drive_back", [KEY_S], [[JOY_AXIS_LEFT_Y, 1.0]], [])
	_add("turn_left", [KEY_A], [[JOY_AXIS_LEFT_X, -1.0]], [])
	_add("turn_right", [KEY_D], [[JOY_AXIS_LEFT_X, 1.0]], [])
	# Arm: Q/E + IJKL + U/O / right stick, bumpers, triggers
	_add("swing_left", [KEY_Q, KEY_LEFT], [[JOY_AXIS_RIGHT_X, -1.0]], [])
	_add("swing_right", [KEY_E, KEY_RIGHT], [[JOY_AXIS_RIGHT_X, 1.0]], [])
	_add("boom_up", [KEY_I, KEY_UP], [[JOY_AXIS_RIGHT_Y, -1.0]], [])
	_add("boom_down", [KEY_K, KEY_DOWN], [[JOY_AXIS_RIGHT_Y, 1.0]], [])
	_add("stick_out", [KEY_L], [], [JOY_BUTTON_RIGHT_SHOULDER])
	_add("stick_in", [KEY_J], [], [JOY_BUTTON_LEFT_SHOULDER])
	_add("bucket_curl", [KEY_U], [[JOY_AXIS_TRIGGER_RIGHT, 1.0]], [])
	_add("bucket_dump", [KEY_O], [[JOY_AXIS_TRIGGER_LEFT, 1.0]], [])
	# Camera: mouse (handled in follow_camera.gd) or D-pad
	_add("camera_left", [KEY_Z], [], [JOY_BUTTON_DPAD_LEFT])
	_add("camera_right", [KEY_C], [], [JOY_BUTTON_DPAD_RIGHT])
	_add("camera_in", [KEY_EQUAL], [], [JOY_BUTTON_DPAD_UP])
	_add("camera_out", [KEY_MINUS], [], [JOY_BUTTON_DPAD_DOWN])
	# On foot / machines
	_add("interact", [KEY_F], [], [JOY_BUTTON_X])
	_add("jump", [KEY_SPACE], [], [JOY_BUTTON_A])
	_add("sprint", [KEY_SHIFT], [], [JOY_BUTTON_LEFT_STICK])
	_add("toggle_view", [KEY_V], [], [JOY_BUTTON_RIGHT_STICK])
	_add("winch", [KEY_H], [], [JOY_BUTTON_B])
	_add("utility", [KEY_N, KEY_T], [], [JOY_BUTTON_LEFT_STICK])
	_add("handbrake", [KEY_SPACE], [], [JOY_BUTTON_A])
	# Menus and utility
	_add("menu", [KEY_TAB], [], [JOY_BUTTON_BACK])
	_add("pause", [KEY_ESCAPE], [], [JOY_BUTTON_START])
	_add("reset_vehicle", [KEY_BACKSPACE], [], [])
	_add("restart", [KEY_F5], [], [])
	_add("toggle_help", [KEY_F1], [], [JOY_BUTTON_Y])
	# On foot: ratchet straps and rope (each tie is two presses: the thing, then what to tie it to).
	_add("strap", [KEY_G], [], [JOY_BUTTON_LEFT_SHOULDER])
	_add("rope", [KEY_R], [], [JOY_BUTTON_RIGHT_SHOULDER])
	_add("cut_tie", [KEY_X], [], [JOY_BUTTON_B])
	_add("map_zoom", [KEY_M], [], [])


static func _add(action: StringName, keys: Array, axes: Array, buttons: Array) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action, DEADZONE)
	for key in keys:
		var key_event := InputEventKey.new()
		key_event.device = -1
		key_event.physical_keycode = key
		InputMap.action_add_event(action, key_event)
	for axis in axes:
		var motion := InputEventJoypadMotion.new()
		motion.device = -1
		motion.axis = axis[0]
		motion.axis_value = axis[1]
		InputMap.action_add_event(action, motion)
	for button in buttons:
		var press := InputEventJoypadButton.new()
		press.device = -1
		press.button_index = button
		InputMap.action_add_event(action, press)
