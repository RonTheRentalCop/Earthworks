extends CanvasLayer
## Full-screen menus: the DEPOT screen (machines to unlock and call out, excavator tools,
## the job board, your fleet) and the PAUSE screen (resume, controls, new career, quit).
## The game pauses while a menu is open. Works with mouse, keyboard or controller
## (bumpers / Q·E switch tabs, B / Esc closes).

signal buy(id: String)
signal buy_supply(id: String)
signal deliver(kind: String)
signal take_job(index: int)
signal abandon_job
signal return_vehicle(node: Node3D)
signal right_vehicle(node: Node3D)
signal new_career
signal quality_changed(level: int)
signal host_requested(port: int, password: String, player_name: String)
signal join_requested(address: String, port: int, password: String, player_name: String)
signal leave_requested
signal closed

const Career = preload("res://scripts/career.gd")
const Truck = preload("res://scripts/truck.gd")
const Excavator = preload("res://scripts/excavator.gd")
const Bulldozer = preload("res://scripts/bulldozer.gd")
const Trailer = preload("res://scripts/trailer.gd")

const INK := Color(0.07, 0.07, 0.08, 0.96)
const CARD := Color(0.13, 0.13, 0.15, 1.0)
const CARD_HOVER := Color(0.18, 0.18, 0.2, 1.0)
const ACCENT := Color(1.0, 0.76, 0.1)
const TEXT := Color(0.96, 0.95, 0.9)
const MUTED := Color(0.66, 0.65, 0.6)
const GOOD := Color(0.5, 0.92, 0.42)
const BAD := Color(0.98, 0.36, 0.28)
const TABS := ["MACHINES", "TOOLS", "JOBS", "FLEET"]
const CONTROLS := [
	["ON FOOT", ""], ["Walk", "W A S D  ·  Left stick"], ["Jump", "Space  ·  A"], ["Use / get in", "F  ·  X"],
	["Ratchet strap (press at the thing, then at what to tie it to)", "G  ·  LB"], ["Rope (same)", "R  ·  RB"],
	["Cut a strap or rope", "X  ·  B"],
	["Camera", "Right-drag, Q E I K  ·  Right stick"], ["Depot (hire, jobs)", "Tab  ·  View"], ["Menu", "Esc  ·  Menu"],
	["MACHINES", ""], ["Drive", "W A S D  ·  Left stick"], ["Boom · swing / blade · bed", "I K · Q E  ·  Right stick"],
	["Stick in / out", "J L  ·  LB RB"], ["Bucket curl / dump", "U O  ·  RT LT"], ["Handbrake (trucks)", "Space  ·  A"],
	["Winch (tap hook, hold reel)", "H  ·  B"], ["Tool swap / hitch (and chain) trailers", "N or T  ·  L3"], ["Cab view", "V  ·  R3"],
	["Look around in cab", "Hold Alt + mouse  ·  D-pad"], ["Reset machine", "Backspace  ·  Fleet tab"],
	["MOUSE ONLY", ""], ["Left drag", "Boom + swing  ·  blade  ·  bed"], ["Right drag", "Stick + bucket  ·  blade tilt"],
	["Both / middle drag", "Drive + steer"], ["Wheel", "Zoom  ·  all the way in = cab view"],
]

var main: Node3D
var career: Career
var is_open := false

var _font: SystemFont
var _bold: SystemFont
var _root: Control
var _depot: Control
var _pause: Control
var _controls: Control
var _multi: Control
var _tab := 0
var _tab_buttons: Array[Button] = []
var _body: VBoxContainer
var _money: Label
var _thumbs := {}  # kind -> ViewportTexture
var _confirm_new := false


func setup(main_node: Node3D, career_node: Career) -> void:
	main = main_node
	career = career_node
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "Avenir Next Condensed", "Roboto Condensed", "Segoe UI", "Helvetica Neue", "Arial"])
	_font.font_weight = 600
	_bold = SystemFont.new()
	_bold.font_names = _font.font_names
	_bold.font_weight = 800
	var theme := Theme.new()
	theme.default_font = _font
	theme.default_font_size = 16
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = theme
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.03, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	_build_depot()
	_build_pause()
	_build_controls()
	_multi = _window(Vector2(760, 600))
	_render_thumbnails()
	career.money_changed.connect(func(_m: int, _c: int, _r: String) -> void: _refresh_money())


func open_depot(tab := -1) -> void:
	if tab >= 0:
		_tab = tab
	_show(_depot)
	_fill_tab()


func open_pause() -> void:
	_confirm_new = false
	_show(_pause)
	_fill_pause()


func open_controls() -> void:
	_show(_controls)


func close() -> void:
	if not is_open:
		return
	is_open = false
	_root.visible = false
	get_tree().paused = false
	closed.emit()


func _show(screen: Control) -> void:
	is_open = true
	_root.visible = true
	for s in [_depot, _pause, _controls, _multi]:
		s.visible = s == screen
	get_tree().paused = true
	_refresh_money()


func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause") or (event.is_action_pressed("menu") and _depot.visible):
		if _controls.visible or _multi.visible:
			open_pause()
		else:
			close()
		get_viewport().set_input_as_handled()
	elif _depot.visible and (event.is_action_pressed("swing_left") or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER)):
		_set_tab((_tab + TABS.size() - 1) % TABS.size())
		get_viewport().set_input_as_handled()
	elif _depot.visible and (event.is_action_pressed("swing_right") or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER)):
		_set_tab((_tab + 1) % TABS.size())
		get_viewport().set_input_as_handled()


# --- Depot --------------------------------------------------------------------------------

func _build_depot() -> void:
	_depot = _window(Vector2(1180, 700))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_depot.get_child(0).add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	box.add_child(head)
	var title := _label("EARTHWORKS DEPOT", 30, ACCENT, true)
	head.add_child(title)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(24, 0)
	head.add_child(spacer)
	for k in TABS.size():
		var b := _button(TABS[k], 17)
		b.toggle_mode = true
		b.pressed.connect(_set_tab.bind(k))
		head.add_child(b)
		_tab_buttons.append(b)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(fill)
	_money = _label("", 26, GOOD, true)
	head.add_child(_money)
	var close_button := _button("CLOSE", 15)
	close_button.pressed.connect(close)
	head.add_child(close_button)
	box.add_child(_rule())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	scroll.add_child(_body)
	box.add_child(_label("Q / E or LB / RB switch tabs   ·   Esc / B closes", 13, MUTED))


func _set_tab(k: int) -> void:
	_tab = k
	_fill_tab()


func _fill_tab() -> void:
	for k in _tab_buttons.size():
		_tab_buttons[k].button_pressed = k == _tab
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	match _tab:
		0: _fill_machines()
		1: _fill_tools()
		2: _fill_jobs()
		3: _fill_fleet()
	_focus_first()


func _fill_machines() -> void:
	_body.add_child(_label("Unlock a machine once, then call out as many as you like — they're delivered to the depot bays.", 15, MUTED))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	_body.add_child(grid)
	var fleet := int(main.fleet_size())
	for item in Career.MACHINES:
		var card := _card(Vector2(370, 0))
		grid.add_child(card)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		card.add_child(v)
		var thumb := TextureRect.new()
		thumb.custom_minimum_size = Vector2(340, 150)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.texture = _thumbs.get(item.kind)
		v.add_child(thumb)
		var row := HBoxContainer.new()
		v.add_child(row)
		row.add_child(_label(String(item.name).to_upper(), 19, TEXT, true))
		var grow := Control.new()
		grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(grow)
		var owned := career.is_owned(item.id)
		row.add_child(_label("OWNED" if owned else "$" + _thousands(int(item.price)), 17, GOOD if owned else ACCENT, true))
		v.add_child(_label(String(item.blurb), 14, MUTED))
		v.add_child(_label("  ·  ".join(PackedStringArray(item.stats)), 13, TEXT))
		var action: Button
		if owned:
			action = _button("DELIVER TO DEPOT", 15)
			action.disabled = fleet >= Career.MAX_FLEET
			action.pressed.connect(func() -> void:
				deliver.emit(String(item.kind))
				close())
		else:
			action = _button("UNLOCK  $" + _thousands(int(item.price)), 15)
			action.disabled = not career.can_afford(int(item.price))
			action.pressed.connect(func() -> void:
				buy.emit(String(item.id))
				_fill_tab())
		v.add_child(action)
	_body.add_child(_label("Fleet: %d / %d machines on site" % [fleet, Career.MAX_FLEET], 14, MUTED))


func _fill_tools() -> void:
	_body.add_child(_label("SUPPLIES  ·  delivered to the depot by the material bays", 16, MUTED, true))
	for item in Career.SUPPLIES:
		var card := _card(Vector2(1120, 0), Color(0.5, 0.92, 0.42))
		_body.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		card.add_child(row)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		v.add_child(_label(String(item.name).to_upper(), 19, TEXT, true))
		v.add_child(_label(String(item.blurb), 14, MUTED))
		var b := _button("BUY  $" + _thousands(int(item.price)), 15)
		b.disabled = not career.can_afford(int(item.price))
		b.pressed.connect(func() -> void:
			buy_supply.emit(String(item.id))
			_fill_tab())
		row.add_child(b)
	_body.add_child(_label("EXCAVATOR TOOLS  ·  swap tools in the cab with N / L3 (owned tools only)", 16, MUTED, true))
	for item in Career.TOOLS:
		var card := _card(Vector2(1120, 0))
		_body.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		card.add_child(row)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		v.add_child(_label(String(item.name).to_upper(), 19, TEXT, true))
		v.add_child(_label(String(item.blurb), 14, MUTED))
		if career.is_owned(item.id):
			row.add_child(_label("OWNED", 18, GOOD, true))
		else:
			var b := _button("UNLOCK  $" + _thousands(int(item.price)), 15)
			b.disabled = not career.can_afford(int(item.price))
			b.pressed.connect(func() -> void:
				buy.emit(String(item.id))
				_fill_tab())
			row.add_child(b)


func _fill_jobs() -> void:
	var jobs = main.jobs
	if not jobs.active.is_empty():
		var job: Dictionary = jobs.active
		var card := _card(Vector2(1120, 0), ACCENT)
		_body.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		card.add_child(row)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		v.add_child(_label("ACTIVE  ·  " + String(job.title).to_upper(), 20, ACCENT, true))
		v.add_child(_label(String(job.brief), 15, TEXT))
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(500, 12)
		bar.max_value = 1.0
		bar.value = float(job.progress)
		bar.show_percentage = false
		v.add_child(bar)
		v.add_child(_label("%d%% done   ·   pays $%s   ·   %s" % [roundi(float(job.progress) * 100.0), _thousands(int(job.reward)), String(job.tip)], 14, MUTED))
		var quit := _button("ABANDON", 15)
		quit.pressed.connect(func() -> void:
			abandon_job.emit()
			_fill_tab())
		row.add_child(quit)
	_body.add_child(_label("JOB BOARD" + ("   ·   finish your current job to take another" if not jobs.active.is_empty() else ""), 16, MUTED, true))
	for k in jobs.offers.size():
		var job: Dictionary = jobs.offers[k]
		var card := _card(Vector2(1120, 0))
		_body.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		card.add_child(row)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		var where := ""
		if job.has("pos"):
			var p: Vector3 = main.player.global_position
			where = "   ·   %d m away" % roundi(Vector2(p.x, p.z).distance_to(job.pos))
		v.add_child(_label(String(job.title).to_upper() + where, 19, TEXT, true))
		v.add_child(_label(String(job.brief), 15, TEXT))
		v.add_child(_label(String(job.tip), 13, MUTED))
		row.add_child(_label("$" + _thousands(int(job.reward)), 24, GOOD, true))
		var take := _button("TAKE JOB", 15)
		take.disabled = not jobs.active.is_empty()
		take.pressed.connect(func() -> void:
			take_job.emit(k)
			close())
		row.add_child(take)


func _fill_fleet() -> void:
	var list: Array = main.machines + main.trailers
	if list.is_empty():
		_body.add_child(_label("No machines on site. Call one out from the MACHINES tab.", 15, MUTED))
	for m in list:
		if not is_instance_valid(m):
			continue
		var card := _card(Vector2(1120, 0))
		_body.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		card.add_child(row)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		var p: Vector3 = main.player.global_position
		v.add_child(_label(String(m.machine_name).to_upper(), 18, TEXT, true))
		var note := "%d m away" % roundi(p.distance_to(m.global_position))
		if m.has_method("status"):
			note += "   ·   " + String(m.status())
		v.add_child(_label(note, 13, MUTED))
		if m.get("broken"):
			row.add_child(_label("JOB VEHICLE", 15, BAD, true))
			continue
		var upright := _button("RESET", 14)
		upright.pressed.connect(func() -> void:
			right_vehicle.emit(m)
			close())
		row.add_child(upright)
		var back := _button("RETURN TO DEALER", 14)
		back.pressed.connect(func() -> void:
			return_vehicle.emit(m)
			_fill_tab())
		row.add_child(back)


# --- Pause / controls ---------------------------------------------------------------------

func _build_pause() -> void:
	_pause = _window(Vector2(520, 680))


func _fill_pause() -> void:
	var holder: Control = _pause.get_child(0)
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	holder.add_child(box)
	box.add_child(_label("EARTHWORKS", 40, ACCENT, true))
	box.add_child(_label("PAUSED", 16, MUTED, true))
	box.add_child(_rule())
	var quality_name: String = ["LOW", "MEDIUM", "HIGH"][career.quality]
	var items := [["RESUME", close], ["DEPOT  ·  HIRE & JOBS", func() -> void: open_depot()],
			["MULTIPLAYER" + ("  ·  %d PLAYERS" % main.net.players.size() if main.net.is_online() else ""), open_multiplayer],
			["CONTROLS", open_controls], ["GRAPHICS:  " + quality_name, _cycle_quality]]
	if not main.net.is_client():
		items.append(["NEW CAREER", _ask_new])
	items.append(["QUIT TO DESKTOP", _quit])
	for item in items:
		var b := _button(item[0], 19)
		b.custom_minimum_size = Vector2(0, 50)
		b.pressed.connect(item[1])
		box.add_child(b)
	if _confirm_new:
		var warn := _label("This wipes your cash and unlocks. Press NEW CAREER again to confirm.", 14, BAD)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(warn)
	var stats: Dictionary = career.stats
	box.add_child(_label("Earned $%s  ·  %d jobs  ·  %d logs shredded" % [_thousands(int(stats.earned)), int(stats.jobs), int(stats.logs)], 13, MUTED))
	var credit := _label("Excavator model: \"Excavator\" by MD.Jobair Hossain (Sketchfab), CC-BY-4.0", 11, MUTED)
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(credit)
	_focus_first()


func _cycle_quality() -> void:
	quality_changed.emit((career.quality + 1) % 3)
	_fill_pause()


## Host a game on this world, or join a friend's (up to 4 players).
func open_multiplayer() -> void:
	_show(_multi)
	var holder: Control = _multi.get_child(0)
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	holder.add_child(box)
	box.add_child(_label("MULTIPLAYER", 30, ACCENT, true))
	var net = main.net
	if net.is_online():
		box.add_child(_label("Hosting this world" if net.is_host() else "Playing in a friend's world", 18, TEXT, true))
		for peer in net.players:
			var p: Dictionary = net.players[peer]
			var row := HBoxContainer.new()
			var dot := ColorRect.new()
			dot.color = net.player_color(peer)
			dot.custom_minimum_size = Vector2(14, 14)
			dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(dot)
			row.add_child(_label("  " + String(p.name) + ("  ·  host" if peer == 1 else ""), 17, TEXT))
			box.add_child(row)
		box.add_child(_label("%d / %d players" % [net.players.size(), net.MAX_PLAYERS], 14, MUTED))
		if net.is_host():
			var addresses := _addresses()
			box.add_child(_label("Friends join with one of these addresses, port %d, and your password:" % career.last_port, 14, MUTED))
			box.add_child(_label("   ".join(PackedStringArray(addresses)) if not addresses.is_empty() else "(no network found)", 18, GOOD, true))
		var stop := _button("STOP HOSTING" if net.is_host() else "LEAVE GAME", 18)
		stop.pressed.connect(func() -> void:
			leave_requested.emit()
			close())
		box.add_child(stop)
	else:
		var name_edit := _field(box, "YOUR NAME", career.player_name if career.player_name != "" else "Player", false)
		var pass_edit := _field(box, "ROOM PASSWORD (everyone uses the same one, 4+ characters)", "", true)
		var port_edit := _field(box, "PORT", str(career.last_port), false)
		box.add_child(_rule())
		var host_button := _button("HOST THIS WORLD  (up to 4 players)", 18)
		box.add_child(host_button)
		box.add_child(_rule())
		var addr_edit := _field(box, "HOST'S ADDRESS (their Tailscale or LAN IP)", career.last_address, false)
		var join_button := _button("JOIN GAME", 18)
		box.add_child(join_button)
		var note := _label("", 14, BAD)
		box.add_child(note)
		var remember := func() -> void:
			career.player_name = name_edit.text.strip_edges()
			career.last_address = addr_edit.text.strip_edges()
			career.last_port = clampi(port_edit.text.to_int(), 1024, 65535) if port_edit.text.is_valid_int() else 24680
			career.save_settings()
		host_button.pressed.connect(func() -> void:
			if pass_edit.text.length() < 4:
				note.text = "Pick a password of at least 4 characters."
				return
			remember.call()
			host_requested.emit(career.last_port, pass_edit.text, career.player_name)
			close())
		join_button.pressed.connect(func() -> void:
			if addr_edit.text.strip_edges() == "" or pass_edit.text.length() < 4:
				note.text = "Enter the host's address and the room password."
				return
			remember.call()
			close()
			join_requested.emit(career.last_address, career.last_port, pass_edit.text, career.player_name))
	var help := _label("Traffic is encrypted (DTLS) and the password is checked without ever being sent. To play " +
			"over the internet without opening ports, install Tailscale (tailscale.com, free) on every PC, sign " +
			"in to the same network and join with the host's 100.x.x.x address. On the same Wi-Fi, use the LAN address. " +
			"Joining replaces your world with the host's; your own cash and unlocks stay safe.", 13, MUTED)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(700, 0)
	box.add_child(help)
	var back := _button("BACK", 16)
	back.pressed.connect(open_pause)
	box.add_child(back)
	_focus_first()


func _addresses() -> Array:
	var out := []
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			out.append(ip)
	out.sort_custom(func(a: String, b: String) -> bool: return a.begins_with("100.") and not b.begins_with("100."))
	return out


func _field(box: Control, title: String, value: String, secret: bool) -> LineEdit:
	box.add_child(_label(title, 13, MUTED, true))
	var edit := LineEdit.new()
	edit.text = value
	edit.secret = secret
	edit.custom_minimum_size = Vector2(700, 38)
	edit.add_theme_font_size_override("font_size", 17)
	var style := StyleBoxFlat.new()
	style.bg_color = CARD_HOVER
	style.set_corner_radius_all(3)
	style.content_margin_left = 10
	style.border_width_bottom = 2
	style.border_color = ACCENT
	edit.add_theme_stylebox_override("normal", style)
	edit.add_theme_stylebox_override("focus", style)
	box.add_child(edit)
	return edit


## Saves the world (your own game) and closes the game.
func _quit() -> void:
	if main.has_method("save_world"):
		main.save_world()
	get_tree().quit()


func _ask_new() -> void:
	if _confirm_new:
		new_career.emit()
		close()
	else:
		_confirm_new = true
		_fill_pause()


func _build_controls() -> void:
	_controls = _window(Vector2(820, 690))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_controls.get_child(0).add_child(box)
	box.add_child(_label("CONTROLS", 30, ACCENT, true))
	for row in CONTROLS:
		if row[1] == "":
			box.add_child(_label(row[0], 15, ACCENT, true))
			continue
		var h := HBoxContainer.new()
		box.add_child(h)
		var name_label := _label(row[0], 15, TEXT)
		name_label.custom_minimum_size = Vector2(300, 0)
		h.add_child(name_label)
		h.add_child(_label(row[1], 15, MUTED))
	var back := _button("BACK", 16)
	back.pressed.connect(open_pause)
	box.add_child(back)


# --- Thumbnails ---------------------------------------------------------------------------

## Renders each machine once into a small offscreen viewport for the shop cards.
func _render_thumbnails() -> void:
	for item in Career.MACHINES:
		var kind := String(item.kind)
		var vp := SubViewport.new()
		vp.size = Vector2i(512, 224)
		vp.own_world_3d = true
		vp.transparent_bg = true
		vp.msaa_3d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		add_child(vp)
		var node: Node3D
		match kind:
			"excavator":
				node = Excavator.new()
			"excavator_xl":
				node = Excavator.new()
				node.size_scale = 2.0
			"dozer", "dozer_angle", "dozer_xl", "dozer_angle_xl", "dozer_carry", "conveyor":
				node = main._create_vehicle(kind)  # the same machine the game builds
			"trailer":
				node = Trailer.new()
			"log_trailer":
				node = Trailer.new()
				node.variant = "logs"
			_:
				node = Truck.new()
				node.kind = kind
		node.set("preview", true)
		vp.add_child(node)
		var light := DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-40, -35, 0)
		light.light_energy = 1.3
		vp.add_child(light)
		var env := WorldEnvironment.new()
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_CLEAR_COLOR
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color(0.75, 0.78, 0.85)
		env.environment.ambient_light_energy = 0.9
		env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		vp.add_child(env)
		var cam := Camera3D.new()
		cam.fov = 30.0
		vp.add_child(cam)
		# Each family is framed from the same distance, so the big versions look big.
		var reach: float = {"excavator": 22.0, "excavator_xl": 22.0, "trailer": 19.0, "log_trailer": 19.0, "adt": 17.0, "pickup": 11.0,
			"dozer": 26.0, "dozer_angle": 26.0, "dozer_xl": 26.0, "dozer_angle_xl": 26.0, "dozer_carry": 26.0,
			"recovery": 19.0, "recovery_xl": 19.0, "conveyor": 34.0, "log_semi": 17.0}.get(kind, 14.5)
		var look := Vector3(0, 1.6 if kind != "pickup" else 0.9, 0)
		cam.position = look + Vector3(-0.62, 0.34, -0.7).normalized() * reach
		if kind in ["dozer", "dozer_angle", "dozer_xl", "dozer_angle_xl", "dozer_carry", "excavator", "excavator_xl"]:
			cam.position = look + Vector3(-0.62, 0.34, 0.7).normalized() * reach
		cam.look_at_from_position(cam.position, look)
		_thumbs[kind] = vp.get_texture()
	_bake_thumbnails()


## Once drawn, the thumbnails become plain images and their little worlds (a whole
## machine, light and camera each) are freed.
func _bake_thumbnails() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for i in 3:
		await RenderingServer.frame_post_draw
	for vp in get_children():
		if not vp is SubViewport:
			continue
		var image := (vp as SubViewport).get_texture().get_image()
		if image == null or image.is_empty():
			continue
		var baked := ImageTexture.create_from_image(image)
		for kind in _thumbs:
			if _thumbs[kind] == (vp as SubViewport).get_texture():
				_thumbs[kind] = baked
		vp.queue_free()
	if is_open:
		_fill_tab()


# --- Widgets ------------------------------------------------------------------------------

func _window(min_size: Vector2) -> Control:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = INK
	style.set_corner_radius_all(4)
	style.border_width_top = 4
	style.border_color = ACCENT
	style.set_content_margin_all(22)
	style.shadow_color = Color(0, 0, 0, 0.5)
	style.shadow_size = 18
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = min_size
	center.add_child(panel)
	center.visible = false
	return center  # child 0 of a screen is its panel


func _card(min_size: Vector2, border := Color(0, 0, 0, 0)) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CARD
	style.set_corner_radius_all(4)
	style.set_content_margin_all(14)
	if border.a > 0.0:
		style.border_width_left = 4
		style.border_color = border
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = min_size
	return panel


func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.1)
	r.custom_minimum_size = Vector2(0, 2)
	return r


func _label(text: String, size: int, color: Color, heavy := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if heavy:
		l.add_theme_font_override("font", _bold)
	return l


func _button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", _bold)
	b.add_theme_font_size_override("font_size", size)
	var states := {"normal": CARD_HOVER, "hover": Color(0.26, 0.26, 0.28), "pressed": ACCENT, "focus": Color(0, 0, 0, 0),
			"disabled": Color(0.12, 0.12, 0.13), "hover_pressed": ACCENT}
	for state in states:
		var style := StyleBoxFlat.new()
		style.bg_color = states[state]
		style.set_corner_radius_all(3)
		style.content_margin_left = 16
		style.content_margin_right = 16
		style.content_margin_top = 7
		style.content_margin_bottom = 7
		style.skew = Vector2(0.12, 0)
		if state == "focus":
			style.draw_center = false
			style.set_border_width_all(2)
			style.border_color = ACCENT
		else:
			style.border_width_bottom = 3
			style.border_color = ACCENT if state != "disabled" else Color(0.3, 0.3, 0.3)
		b.add_theme_stylebox_override(state, style)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", ACCENT)
	b.add_theme_color_override("font_focus_color", ACCENT)
	b.add_theme_color_override("font_pressed_color", INK)
	b.add_theme_color_override("font_hover_pressed_color", INK)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.4, 0.4))
	return b


func _focus_first() -> void:
	await get_tree().process_frame
	var screen: Control = _depot if _depot.visible else _pause if _pause.visible else _multi if _multi.visible else _controls
	var stack: Array[Node] = [screen]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if n is Button and not (n as Button).disabled and (n as Button).is_visible_in_tree():
			if _depot.visible and n in _tab_buttons:
				pass
			else:
				(n as Button).grab_focus()
				return
		stack.append_array(n.get_children())


func _refresh_money() -> void:
	if _money:
		_money.text = "$ " + _thousands(career.money)


static func _thousands(value: int) -> String:
	var s := str(absi(value))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if value < 0 else "") + s + out
