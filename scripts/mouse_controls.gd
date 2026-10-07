extends Control
## Mouse-only machine control. Hold a button and move the mouse like a joystick;
## the further you push, the faster that part moves. Let go and it recentres.
##   Left drag            boom (up/down) + swing (left/right)
##   Right drag           stick (up/down: out/in) + bucket (left curl, right dump)
##   Left+Right / Middle  drive (up/down) + steer (left/right)

const RADIUS := 140.0  # mouse travel (px) for full speed
const DEADZONE := 0.08
const DRAW_RADIUS := 56.0

const MODES := {
	"arm": ["BOOM / SWING", "boom_up", "swing_left"],
	"tool": ["STICK / BUCKET", "stick_out", "bucket_curl"],
	"drive": ["DRIVE", "drive_forward", "turn_left"],
}

var enabled := false:
	set(value):
		enabled = value
		if not value:
			_release()
## Positive action name -> -1..1, read by the excavator.
var output := {}

var _stick := Vector2.ZERO
var _mode := ""
var _buttons := 0
var _anchor := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _exit_tree() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	var button := event as InputEventMouseButton
	if button and button.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		var bit := 1 << (button.button_index - 1)
		if button.pressed:
			_buttons |= bit
		else:
			_buttons &= ~bit
		var mode := _mode_for(_buttons)
		if mode != _mode:
			if _mode == "":
				_anchor = button.position
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_mode = mode
			_stick = Vector2.ZERO
			if _mode == "":
				_release()
		_update_output()
		get_viewport().set_input_as_handled()
		return
	var motion := event as InputEventMouseMotion
	if motion and _mode != "":
		_stick = (_stick + motion.relative).limit_length(RADIUS)
		_update_output()
		get_viewport().set_input_as_handled()


func _mode_for(buttons: int) -> String:
	if buttons & 4 or (buttons & 1 and buttons & 2):
		return "drive"
	if buttons & 1:
		return "arm"
	if buttons & 2:
		return "tool"
	return ""


func _release() -> void:
	_mode = ""
	_buttons = 0
	_stick = Vector2.ZERO
	output.clear()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.warp_mouse(_anchor)
	queue_redraw()


func _update_output() -> void:
	output.clear()
	if _mode != "":
		var v := _stick / RADIUS
		if v.length() < DEADZONE:
			v = Vector2.ZERO
		var mode: Array = MODES[_mode]
		output[mode[1]] = -v.y  # push the mouse away = up / out / forward
		output[mode[2]] = -v.x  # move left = swing left / curl / steer left
	queue_redraw()


func _draw() -> void:
	if _mode == "":
		return
	var centre := _anchor
	draw_circle(centre, DRAW_RADIUS, Color(0, 0, 0, 0.3))
	draw_arc(centre, DRAW_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.7), 2.0, true)
	draw_line(centre - Vector2(DRAW_RADIUS, 0), centre + Vector2(DRAW_RADIUS, 0), Color(1, 1, 1, 0.2), 1.0)
	draw_line(centre - Vector2(0, DRAW_RADIUS), centre + Vector2(0, DRAW_RADIUS), Color(1, 1, 1, 0.2), 1.0)
	draw_circle(centre + _stick / RADIUS * DRAW_RADIUS, 12.0, Color(1.0, 0.75, 0.2, 0.95))
	var font := get_theme_default_font()
	var label: String = MODES[_mode][0]
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	draw_string(font, centre + Vector2(-width * 0.5, DRAW_RADIUS + 20), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
