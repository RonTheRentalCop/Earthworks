extends CanvasLayer
## In-game HUD: company cash (with pop-ups when money comes in), minimap and the active
## job, the machine panel (speed gauge, load bar, status chips), the interaction prompt,
## toasts, key hints, and click buttons for mouse-only machine control. Key hints follow
## whichever device was used last (keyboard or controller).

signal view_pressed
signal exit_pressed
signal utility_pressed
signal menu_pressed

const Minimap = preload("res://scripts/minimap.gd")

const INK := Color(0.07, 0.07, 0.08, 0.9)
const INK_LIGHT := Color(0.13, 0.13, 0.15, 0.92)
const ACCENT := Color(1.0, 0.76, 0.1)
const TEXT := Color(0.96, 0.95, 0.9)
const MUTED := Color(0.66, 0.65, 0.6)
const GOOD := Color(0.5, 0.92, 0.42)
const BAD := Color(0.98, 0.36, 0.28)

## [keyboard, controller] labels for each action's key cap.
const KEYS := {
	"interact": ["F", "X"], "menu": ["TAB", "VIEW"], "pause": ["ESC", "MENU"], "winch": ["H", "B"],
	"utility": ["N", "L3"], "view": ["V", "R3"], "handbrake": ["SPACE", "A"], "help": ["F1", "Y"],
}

var minimap: Minimap
var pad := false  # last input came from a controller
var font: SystemFont
var bold: SystemFont

var _money_label: Label
var _money_shown := 0.0
var _money := 0
var _popups: VBoxContainer
var _players: VBoxContainer
var _toasts: VBoxContainer
var _job_panel: PanelContainer
var _job_title: Label
var _job_brief: Label
var _job_bar: ProgressBar
var _job_info: Label
var _machine_panel: PanelContainer
var _machine_name: Label
var _gauge: Control
var _gauge_value := 0.0
var _gauge_max := 40.0
var _load_row: HBoxContainer
var _load_label: Label
var _load_bar: ProgressBar
var _chips: HBoxContainer
var _prompt: HBoxContainer
var _prompt_key: Label
var _prompt_text: Label
var _hints: HBoxContainer
var _buttons: HBoxContainer
var _utility_button: Button
var _in_machine := false
var _hint_state := ""


func _ready() -> void:
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "Avenir Next Condensed", "Roboto Condensed", "Segoe UI", "Helvetica Neue", "Arial"])
	font.font_weight = 600
	bold = SystemFont.new()
	bold.font_names = font.font_names
	bold.font_weight = 800
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 16
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme
	add_child(root)

	# --- Cash, top left.
	var cash := _panel(INK, true)
	cash.position = Vector2(22, 18)
	root.add_child(cash)
	var cash_box := VBoxContainer.new()
	cash_box.add_theme_constant_override("separation", -4)
	cash.add_child(cash_box)
	cash_box.add_child(_label("EARTHWORKS CO.  ·  ACCOUNT", 12, MUTED))
	_money_label = _label("$ 0", 34, ACCENT, true)
	cash_box.add_child(_money_label)
	_players = VBoxContainer.new()
	_players.position = Vector2(26, 96)
	_players.add_theme_constant_override("separation", 2)
	_players.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_players)
	_popups = VBoxContainer.new()
	_popups.position = Vector2(30, 92)
	_popups.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_popups)

	# --- Minimap and job card, top right.
	var right := VBoxContainer.new()
	right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	right.offset_left = -262
	right.offset_right = -20
	right.offset_top = 18
	right.add_theme_constant_override("separation", 8)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(right)
	var map_frame := _panel(INK, false)
	right.add_child(map_frame)
	minimap = Minimap.new()
	minimap.custom_minimum_size = Vector2(230, 230)
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_frame.add_child(minimap)
	_job_panel = _panel(INK, false)
	right.add_child(_job_panel)
	var job_box := VBoxContainer.new()
	job_box.add_theme_constant_override("separation", 3)
	_job_panel.add_child(job_box)
	var job_head := HBoxContainer.new()
	job_box.add_child(job_head)
	job_head.add_child(_chip("JOB", INK, ACCENT))
	_job_title = _label("", 17, TEXT, true)
	job_head.add_child(_job_title)
	_job_brief = _label("", 13, MUTED)
	_job_brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_job_brief.custom_minimum_size = Vector2(226, 0)
	job_box.add_child(_job_brief)
	_job_bar = _bar(ACCENT, Vector2(226, 10))
	job_box.add_child(_job_bar)
	_job_info = _label("", 13, TEXT)
	job_box.add_child(_job_info)

	# --- Toasts, top centre.
	_toasts = VBoxContainer.new()
	_toasts.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toasts.offset_top = 22
	_toasts.offset_left = -300
	_toasts.offset_right = 300
	_toasts.alignment = BoxContainer.ALIGNMENT_BEGIN
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toasts)

	# --- Interaction prompt, lower centre.
	_prompt = HBoxContainer.new()
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_top = -170
	_prompt.offset_bottom = -130
	_prompt.offset_left = -300
	_prompt.offset_right = 300
	_prompt.alignment = BoxContainer.ALIGNMENT_CENTER
	_prompt.add_theme_constant_override("separation", 10)
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_prompt)
	var cap := _keycap("F")
	_prompt_key = cap.get_child(0)
	_prompt.add_child(cap)
	_prompt_text = _label("", 22, TEXT, true)
	_prompt_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_prompt_text.add_theme_constant_override("outline_size", 8)
	_prompt.add_child(_prompt_text)
	_prompt.visible = false

	# --- Machine panel, bottom right.
	_machine_panel = _panel(INK, true)
	_machine_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_machine_panel.offset_left = -400
	_machine_panel.offset_top = -168
	_machine_panel.offset_right = -24
	_machine_panel.offset_bottom = -22
	_machine_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_machine_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(_machine_panel)
	var machine_row := HBoxContainer.new()
	machine_row.add_theme_constant_override("separation", 14)
	_machine_panel.add_child(machine_row)
	_gauge = Control.new()
	_gauge.custom_minimum_size = Vector2(118, 118)
	_gauge.draw.connect(_draw_gauge)
	machine_row.add_child(_gauge)
	var machine_box := VBoxContainer.new()
	machine_box.add_theme_constant_override("separation", 5)
	machine_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	machine_row.add_child(machine_box)
	_machine_name = _label("", 20, ACCENT, true)
	machine_box.add_child(_machine_name)
	_load_row = HBoxContainer.new()
	machine_box.add_child(_load_row)
	_load_label = _label("", 14, TEXT)
	_load_label.custom_minimum_size = Vector2(0, 0)
	_load_row.add_child(_load_label)
	_load_bar = _bar(ACCENT, Vector2(210, 12))
	machine_box.add_child(_load_bar)
	_chips = HBoxContainer.new()
	_chips.add_theme_constant_override("separation", 6)
	machine_box.add_child(_chips)

	# --- Click buttons for mouse-only play, above the machine panel.
	_buttons = HBoxContainer.new()
	_buttons.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_buttons.offset_left = -560
	_buttons.offset_top = -214
	_buttons.offset_right = -24
	_buttons.offset_bottom = -178
	_buttons.alignment = BoxContainer.ALIGNMENT_END
	_buttons.add_theme_constant_override("separation", 8)
	root.add_child(_buttons)
	# The winch button acts like the H key: tap to hook / unhook, hold to reel in.
	var winch_button := _button("WINCH")
	winch_button.button_down.connect(func() -> void: Input.action_press("winch"))
	winch_button.button_up.connect(func() -> void: Input.action_release("winch"))
	_buttons.add_child(winch_button)
	_utility_button = _button("TOOL")
	_utility_button.pressed.connect(func() -> void: utility_pressed.emit())
	_buttons.add_child(_utility_button)
	var view_button := _button("CAB VIEW")
	view_button.pressed.connect(func() -> void: view_pressed.emit())
	_buttons.add_child(view_button)
	var exit_button := _button("CLIMB OUT")
	exit_button.pressed.connect(func() -> void: exit_pressed.emit())
	_buttons.add_child(exit_button)

	# --- Key hints, bottom left.
	_hints = HBoxContainer.new()
	_hints.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hints.offset_left = 22
	_hints.offset_top = -52
	_hints.offset_bottom = -20
	_hints.offset_right = 900
	_hints.add_theme_constant_override("separation", 6)
	_hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hints)
	set_mode(false)
	set_job({}, 0.0)


func setup(main: Node3D) -> void:
	minimap.setup(main, bold)


func _input(event: InputEvent) -> void:
	var was := pad
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.4):
		pad = true
	elif event is InputEventKey or event is InputEventMouseButton:
		pad = false
	if pad != was:
		_hint_state = ""


func key(action: String) -> String:
	return KEYS[action][1 if pad else 0]


func _process(delta: float) -> void:
	# Count the cash display up/down to the real figure.
	_money_shown = lerpf(_money_shown, float(_money), 1.0 - exp(-8.0 * delta))
	if absf(_money_shown - _money) < 1.0:
		_money_shown = _money
	_money_label.text = "$ " + _thousands(roundi(_money_shown))
	_update_hints()


# --- Public API ---------------------------------------------------------------------------

## Who's in the game: [name, colour, is me, is host] per player (empty when playing solo).
func set_players(list: Array) -> void:
	for c in _players.get_children():
		c.queue_free()
	for p in list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var dot := ColorRect.new()
		dot.color = p[1]
		dot.custom_minimum_size = Vector2(10, 10)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		var text := String(p[0]) + ("  (you)" if p[2] else "") + ("  ·  host" if p[3] else "")
		var l := _label(text, 14, TEXT, p[2])
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		l.add_theme_constant_override("outline_size", 5)
		row.add_child(l)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_players.add_child(row)
	_popups.position.y = 92 + 20 * list.size()


func set_money(amount: int, instant := false) -> void:
	_money = amount
	if instant:
		_money_shown = amount


## A "+$350  Log shredded" pop-up under the cash readout.
func money_popup(change: int, reason: String) -> void:
	if change == 0:
		return
	var text := ("+$" if change > 0 else "-$") + _thousands(absi(change)) + "   " + reason.to_upper()
	var l := _label(text, 18, GOOD if change > 0 else BAD, true)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 6)
	_popups.add_child(l)
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_property(l, "modulate:a", 0.0, 0.8)
	tween.tween_callback(l.queue_free)


func toast(text: String, color := TEXT) -> void:
	var panel := _panel(INK, true)
	var l := _label(text, 18, color, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(l)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_toasts.add_child(panel)
	while _toasts.get_child_count() > 3:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.queue_free()
	var tween := create_tween()
	tween.tween_interval(2.6)
	tween.tween_property(panel, "modulate:a", 0.0, 0.6)
	tween.tween_callback(panel.queue_free)


## Shows "[F] Drive the bulldozer" (action names a KEYS entry), or hides it with "".
func set_prompt(action: String, text: String) -> void:
	_prompt.visible = text != ""
	if text != "":
		_prompt_key.text = key(action) if action != "" else "!"
		_prompt_key.get_parent().visible = action != ""
		_prompt_text.text = text


func set_mode(in_machine: bool) -> void:
	_in_machine = in_machine
	_machine_panel.visible = in_machine
	_buttons.visible = in_machine
	_hint_state = ""


func set_utility(text: String) -> void:
	_utility_button.visible = text != ""
	_utility_button.text = text.to_upper()


## Machine panel contents (from the machine's hud_info()).
func set_machine(machine_name: String, info: Dictionary) -> void:
	_machine_name.text = machine_name.to_upper()
	_gauge_value = float(info.get("speed", 0.0))
	_gauge_max = maxf(float(info.get("max_speed", 40.0)), 10.0)
	_gauge.queue_redraw()
	var has_load := info.has("load")
	_load_row.visible = has_load
	_load_bar.visible = has_load
	if has_load:
		_load_label.text = String(info.get("load_text", ""))
		_load_bar.value = float(info.load)
	var flags: Array = info.get("flags", [])
	var key_text := ",".join(flags)
	if _chips.get_meta("flags", "") != key_text:
		_chips.set_meta("flags", key_text)
		for c in _chips.get_children():
			c.queue_free()
		for f in flags:
			var text := String(f)
			var warn := text.begins_with("STUCK") or text.begins_with("BOGGED") or text.begins_with("NO ENGINE")
			_chips.add_child(_chip(text, BAD if warn else Color(0.25, 0.25, 0.27), Color.WHITE))


func set_job(job: Dictionary, distance: float) -> void:
	_job_panel.visible = not job.is_empty()
	if job.is_empty():
		return
	_job_title.text = String(job.title).to_upper()
	_job_brief.text = String(job.brief)
	_job_bar.value = float(job.progress)
	var where := "   ·   %d m" % roundi(distance) if distance < INF else "   ·   DONE — HEAD BACK" if job.type == "recover" else ""
	_job_info.text = "%d%%   ·   $%s%s" % [roundi(float(job.progress) * 100.0), _thousands(int(job.reward)), where]


# --- Drawing helpers ----------------------------------------------------------------------

func _draw_gauge() -> void:
	var c := _gauge.size * 0.5
	var r := minf(c.x, c.y) - 6.0
	var start := PI * 0.75
	var sweep := PI * 1.5
	var t := clampf(_gauge_value / _gauge_max, 0.0, 1.0)
	_gauge.draw_circle(c, r + 4.0, Color(0, 0, 0, 0.35))
	_gauge.draw_arc(c, r - 4.0, start, start + sweep, 48, Color(1, 1, 1, 0.12), 8.0, true)
	if t > 0.005:
		_gauge.draw_arc(c, r - 4.0, start, start + sweep * t, 48, ACCENT if t < 0.92 else BAD, 8.0, true)
	for k in 11:
		var a := start + sweep * k / 10.0
		var dir := Vector2(cos(a), sin(a))
		_gauge.draw_line(c + dir * (r - 14.0), c + dir * (r - 9.0 - (3.0 if k % 5 == 0 else 0.0)), Color(1, 1, 1, 0.5), 2.0)
	var text := str(roundi(_gauge_value))
	_gauge.draw_string(bold, c + Vector2(-40, 10), text, HORIZONTAL_ALIGNMENT_CENTER, 80, 34, TEXT)
	_gauge.draw_string(font, c + Vector2(-40, 30), "KM/H", HORIZONTAL_ALIGNMENT_CENTER, 80, 12, MUTED)


func _update_hints() -> void:
	var state := "%s%s" % [pad, _in_machine]
	if state == _hint_state:
		return
	_hint_state = state
	for c in _hints.get_children():
		c.queue_free()
	var items := [["menu", "DEPOT"], ["pause", "MENU"]]
	if _in_machine:
		items += [["interact", "CLIMB OUT"], ["view", "CAB VIEW"], ["winch", "WINCH"], ["utility", "TOOL / HITCH"]]
	else:
		items += [["interact", "USE"], ["help", "CONTROLS"]]
	for item in items:
		_hints.add_child(_keycap(key(item[0])))
		var l := _label(item[1], 13, TEXT)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
		l.add_theme_constant_override("outline_size", 5)
		_hints.add_child(l)
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(10, 0)
		_hints.add_child(gap)


func _panel(color: Color, skewed: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	style.border_width_bottom = 3
	style.border_color = ACCENT
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 9
	if skewed:
		style.skew = Vector2(0.12, 0)
		style.content_margin_left = 20
		style.content_margin_right = 20
	style.shadow_color = Color(0, 0, 0, 0.3)
	style.shadow_size = 6
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return panel


func _label(text: String, size: int, color: Color, heavy := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if heavy:
		l.add_theme_font_override("font", bold)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _chip(text: String, bg: Color, fg: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg if bg != INK else ACCENT
	style.set_corner_radius_all(3)
	style.content_margin_left = 7
	style.content_margin_right = 7
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	style.skew = Vector2(0.15, 0)
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(_label(text, 12, fg if bg != INK else INK, true))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return panel


## A keyboard key / controller button cap.
func _keycap(text: String) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.93, 0.92, 0.88)
	style.set_corner_radius_all(5)
	style.border_width_bottom = 3
	style.border_color = Color(0.55, 0.54, 0.5)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	panel.add_theme_stylebox_override("panel", style)
	var l := _label(text, 14, Color(0.1, 0.1, 0.1), true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(l)
	panel.custom_minimum_size = Vector2(30, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return panel


func _bar(color: Color, min_size: Vector2) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = min_size
	bar.show_percentage = false
	bar.max_value = 1.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(2)
	fill.skew = Vector2(0.3, 0)
	bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(1, 1, 1, 0.12)
	back.set_corner_radius_all(2)
	back.skew = Vector2(0.3, 0)
	bar.add_theme_stylebox_override("background", back)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bar


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", bold)
	b.add_theme_font_size_override("font_size", 14)
	for state in ["normal", "hover", "pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = {"normal": INK_LIGHT, "hover": Color(0.22, 0.22, 0.24, 0.95), "pressed": ACCENT}[state]
		style.set_corner_radius_all(3)
		style.border_width_bottom = 3
		style.border_color = ACCENT if state != "pressed" else Color(0.6, 0.45, 0.05)
		style.content_margin_left = 14
		style.content_margin_right = 14
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		style.skew = Vector2(0.15, 0)
		b.add_theme_stylebox_override(state, style)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", ACCENT)
	b.add_theme_color_override("font_pressed_color", INK)
	return b


static func _thousands(value: int) -> String:
	var s := str(absi(value))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if value < 0 else "") + s + out
