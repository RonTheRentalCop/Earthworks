extends CanvasLayer
## Bucket-fill bar (top centre), stats (top left), controls help (top right, F1 / Y),
## machine buttons for mouse-only play (bottom right), prompt and credits.

signal view_pressed
signal exit_pressed
signal utility_pressed

const MACHINE_CONTROLS := """MOUSE (hold a button and push)
Left drag        Boom · Swing   |  Dozer blade up/down  |  Truck bed
Right drag       Stick · Bucket curl/dump  |  Dozer blade tilt
Both / middle    Drive forward/back · Steer
Scroll           Zoom · scroll all the way in for cab view
In the cab       hold Alt + move the mouse to look around (or Z/C, -/=, D-pad)

KEYBOARD / CONTROLLER  (dozer blade = boom keys, truck bed = boom keys)
Drive            W A S D        Left stick
Swing · Boom     Q E · I K      Right stick
Stick in/out     J / L          LB / RB
Curl / dump      U / O          RT / LT
Cab view         V              R-stick click
Winch            H tap/hold     B tap/hold
Swap tool/hitch  N / T          L3
Climb out        F              X
Reset · Restart  Bksp · F5      Back · Start"""

const FOOT_CONTROLS := """ON FOOT             Keyboard            Controller
Walk                W A S D             Left stick
Jump                Space               A
Camera              Right-drag, Q E I K Right stick
Get in machine      F (near the door)   X
Camera zoom         Wheel, - / =        D-pad U/D
Restart level       F5                  Start
Toggle this help    F1                  Y"""

const CREDITS := "Excavator model: \"Excavator\" by MD.Jobair Hossain (Sketchfab), CC-BY-4.0"
const PANEL := Color(0.08, 0.07, 0.06, 0.62)
const ACCENT := Color(1.0, 0.72, 0.18)

var _fill_label: Label
var _fill_bar: ProgressBar
var _stats: Label
var _help: PanelContainer
var _help_label: Label
var _prompt: Label
var _buttons: HBoxContainer
var _utility_button: Button


func _ready() -> void:
	# Bucket fill, top centre.
	var fill_panel := _panel()
	fill_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	fill_panel.offset_top = 14.0
	fill_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var fill_box := VBoxContainer.new()
	fill_panel.add_child(fill_box)
	_fill_label = Label.new()
	_fill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fill_label.add_theme_font_size_override("font_size", 15)
	fill_box.add_child(_fill_label)
	_fill_bar = ProgressBar.new()
	_fill_bar.custom_minimum_size = Vector2(300, 8)
	_fill_bar.show_percentage = false
	_fill_bar.max_value = 1.0
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = ACCENT
	fill_style.set_corner_radius_all(4)
	_fill_bar.add_theme_stylebox_override("fill", fill_style)
	var back_style := StyleBoxFlat.new()
	back_style.bg_color = Color(1, 1, 1, 0.15)
	back_style.set_corner_radius_all(4)
	_fill_bar.add_theme_stylebox_override("background", back_style)
	fill_box.add_child(_fill_bar)

	# Stats, top left.
	var stats_panel := _panel()
	stats_panel.position = Vector2(16, 14)
	var stats_box := VBoxContainer.new()
	stats_panel.add_child(stats_box)
	var title := Label.new()
	title.text = "EARTHWORKS"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", ACCENT)
	stats_box.add_child(title)
	_stats = Label.new()
	_stats.add_theme_font_size_override("font_size", 14)
	stats_box.add_child(_stats)

	# Help, top right.
	_help = _panel()
	_help.anchor_left = 1.0
	_help.anchor_right = 1.0
	_help.offset_left = -16.0
	_help.offset_right = -16.0
	_help.offset_top = 14.0
	_help.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_help_label = Label.new()
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Courier New", "monospace"])
	_help_label.add_theme_font_override("font", mono)
	_help_label.add_theme_font_size_override("font_size", 13)
	_help.add_child(_help_label)

	# Machine buttons, bottom right (clickable, so the mouse alone is enough).
	_buttons = HBoxContainer.new()
	_buttons.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_buttons.offset_left = -620.0
	_buttons.offset_top = -78.0
	_buttons.offset_right = -16.0
	_buttons.offset_bottom = -34.0
	_buttons.alignment = BoxContainer.ALIGNMENT_END
	_buttons.add_theme_constant_override("separation", 10)
	add_child(_buttons)
	# The winch button acts like the H key: tap to hook / unhook, hold to reel in.
	var winch_button := _button("Winch (H)", Signal())
	winch_button.button_down.connect(func() -> void: Input.action_press("winch"))
	winch_button.button_up.connect(func() -> void: Input.action_release("winch"))
	_buttons.add_child(winch_button)
	_utility_button = _button("Tool", utility_pressed)
	_buttons.add_child(_utility_button)
	_buttons.add_child(_button("Cab view (V)", view_pressed))
	_buttons.add_child(_button("Climb out (F)", exit_pressed))

	_prompt = Label.new()
	_prompt.add_theme_font_size_override("font_size", 24)
	_prompt.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_top = -90.0
	_prompt.offset_bottom = -50.0
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(_prompt)

	var credits := Label.new()
	credits.text = CREDITS
	credits.add_theme_font_size_override("font_size", 12)
	credits.modulate = Color(1, 1, 1, 0.7)
	credits.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	credits.offset_left = -560.0
	credits.offset_top = -24.0
	credits.offset_right = -10.0
	credits.offset_bottom = -6.0
	credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(credits)
	set_mode(false)


func set_mode(in_machine: bool) -> void:
	_help_label.text = MACHINE_CONTROLS if in_machine else FOOT_CONTROLS
	_buttons.visible = in_machine


func set_utility(text: String) -> void:
	_utility_button.text = text
	_utility_button.visible = text != ""


func set_prompt(text: String) -> void:
	_prompt.text = text


func update_stats(headline: String, fill: float, stats: String) -> void:
	_fill_label.text = headline
	_fill_bar.value = fill
	_fill_bar.visible = headline != "ON FOOT"
	_stats.text = stats


func toggle_help() -> void:
	_help.visible = not _help.visible


func _button(text: String, pressed: Signal) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(130, 40)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.25, 0.2, 0.1, 0.8)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	if not pressed.is_null():
		button.pressed.connect(func() -> void: pressed.emit())
	return button


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	return panel
