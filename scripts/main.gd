extends Node3D
## Test build entry point: builds the world in code (terrain, river, lake, streams,
## mud, forests, demolition site and the construction depot you spawn in) and wires up the
## worker, the machines (excavator, bulldozer, dump truck), water, camera and HUD.
## Run with `-- --autotest` for a scripted check of every machine.

const InputSetup = preload("res://scripts/input_setup.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Water = preload("res://scripts/water.gd")
const Excavator = preload("res://scripts/excavator.gd")
const Bulldozer = preload("res://scripts/bulldozer.gd")
const Truck = preload("res://scripts/truck.gd")
const Trailer = preload("res://scripts/trailer.gd")
const Player = preload("res://scripts/player.gd")
const Buildings = preload("res://scripts/buildings.gd")
const Scenery = preload("res://scripts/scenery.gd")
const FollowCamera = preload("res://scripts/follow_camera.gd")
const Hud = preload("res://scripts/hud.gd")
const Grass = preload("res://scripts/grass.gd")
const MouseControls = preload("res://scripts/mouse_controls.gd")

const ZONE := Vector2(0, 100)
const PLAYER_SPAWN := Vector2(8, 104)
const BORROW_MOUND := Vector2(-10, 40)
const DEMOLITION := Vector2(-72, 52)
const LAKE := Vector2(-72, -58)
const LAKE_RADIUS := 24.0
const MUD_PITS: Array[Vector3] = [Vector3(44, 66, 9.0), Vector3(-44, 62, 8.0), Vector3(62, 24, 7.0)]
const ENTER_DISTANCE := 3.2
const MOVED_THRESHOLD := 0.6  # a block counts as destroyed once displaced this far

# [start, end, action] - scripted inputs for --autotest (machines switch at set times).
const AUTOTEST := [
	[1.0, 2.0, "drive_forward"],
	[2.0, 4.5, "boom_down"],
	[2.0, 3.5, "stick_out"],
	[4.5, 8.5, "bucket_curl"],
	[4.5, 6.0, "stick_in"],
	[6.0, 9.0, "boom_up"],
	[7.0, 8.2, "stick_out"],
	[9.0, 10.9, "swing_left"],
	[11.2, 12.8, "bucket_dump"],
	[13.4, 14.0, "boom_down"],
	[14.0, 18.8, "drive_forward"],
	[20.0, 27.0, "drive_forward"],
	[28.0, 29.5, "drive_back"],
	[28.5, 28.6, "jump"],
]

var terrain: Terrain
var water: Water
var excavator: Excavator
var dozer: Bulldozer
var truck: Truck
var recovery: Truck
var trailer: Trailer
var machines: Array = []
var player: Player
var camera: FollowCamera
var hud: Hud
var grass: Grass
var mouse: MouseControls
var debris: Array[RigidBody3D] = []
var props: Array[RigidBody3D] = []
var trees: Array[Node3D] = []
var trees_felled := 0
var stumps_cleared := 0
var _debris_start := PackedVector3Array()
var _destruction := 0.0
var _destruction_timer := 0.0
var _driving: Node3D = null
var _message := ""
var _message_timer := 0.0
var _winch_down_at := 0.0
var _winch_was_attached := false
var _winch_reeling := false
var _autotest := false
var _time := 0.0
var _next_report := 1.0
var _done_steps := {}


func _ready() -> void:
	var started := Time.get_ticks_msec()
	InputSetup.setup()
	_autotest = "--autotest" in OS.get_cmdline_user_args()
	_build_environment()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11

	terrain = Terrain.new()
	add_child(terrain)
	terrain.generate(7)
	terrain.add_mound(BORROW_MOUND, 14.0, 6.0)
	terrain.add_mound(Vector2(22, 44), 8.0, 3.0)
	for pit in MUD_PITS:
		terrain.add_mound(Vector2(pit.x, pit.y), pit.z, -0.5)
	# Lake: a deep basin; its level sits just under the lowest point of the rim.
	terrain.add_mound(LAKE, LAKE_RADIUS, -5.5)
	var lake_level := _rim_average(LAKE, LAKE_RADIUS + 0.5) - 0.2
	terrain.raise_ring(LAKE, LAKE_RADIUS - 1.0, LAKE_RADIUS + 6.0, lake_level + 0.5)
	terrain.clear_grass(LAKE, LAKE_RADIUS + 2.0)
	# River: meanders down the east side, falling from north to south.
	var river := PackedVector2Array()
	var river_beds := PackedFloat32Array()
	for k in 38:
		var z := -Terrain.HALF_SIZE + k * 7.8
		river.append(Vector2(92.0 + 18.0 * sin(z / 40.0) + 6.0 * sin(z / 13.0), z))
		river_beds.append(-1.8 - 0.012 * (z + Terrain.HALF_SIZE))
	river_beds = terrain.carve_channel(river, river_beds, 6.5, 2.0, 0.35)
	# Stream feeding the lake from the western hills.
	var feeder := PackedVector2Array([Vector2(-132, 14), Vector2(-120, 8), Vector2(-108, -2), Vector2(-96, -16), Vector2(-86, -34), Vector2(-82, -42)])
	var feeder_beds := PackedFloat32Array()
	for k in feeder.size():
		feeder_beds.append(lerpf(lake_level + 1.2, lake_level - 0.4, k / float(feeder.size() - 1)))
	feeder_beds = terrain.carve_channel(feeder, feeder_beds, 1.6, 0.8, 0.45)
	# Outlet stream from the lake east into the river.
	var outlet := PackedVector2Array([Vector2(-50, -62), Vector2(-24, -68), Vector2(8, -62), Vector2(40, -70), Vector2(river[10].x - 6.0, river[10].y)])
	var outlet_beds := PackedFloat32Array()
	for k in outlet.size():
		outlet_beds.append(lerpf(lake_level - 0.45, river_beds[10] + 1.2, k / float(outlet.size() - 1)))
	outlet_beds = terrain.carve_channel(outlet, outlet_beds, 1.8, 0.9, 0.45)

	var zone_level := Scenery.prepare_zone(terrain, ZONE)
	var sites := [
		{"pos": DEMOLITION + Vector2(2, -4), "nx": 8, "nz": 6, "rows": 6, "style": "brick"},
		{"pos": DEMOLITION + Vector2(-20, 20), "nx": 6, "nz": 6, "rows": 5, "style": "concrete"},
		{"pos": DEMOLITION + Vector2(18, 30), "nx": 3, "nz": 3, "rows": 12, "style": "concrete"},
	]
	var levels: Array[float] = []
	for site in sites:
		levels.append(terrain.flatten(site.pos, Vector2(site.nx, site.nz) * 0.5 + Vector2.ONE, 3.0))
	var wall_level := terrain.flatten(DEMOLITION + Vector2(-4, -30), Vector2(7, 1.5), 3.0)
	# Mud: pits near the yard, river banks, the lake shore and along the outlet.
	for pit in MUD_PITS:
		terrain.add_mud(Vector2(pit.x, pit.y), pit.z + 2.0, 1.0)
	terrain.add_mud(Vector2(32, 66), 5.0, 0.7)
	for p in river:
		terrain.add_mud(p, 12.0, 0.8)
	for k in 28:
		terrain.add_mud(LAKE + Vector2.from_angle(TAU * k / 28.0) * (LAKE_RADIUS + 1.0), 5.0, 0.85)
	for p in outlet:
		terrain.add_mud(p, 4.5, 0.6)
	terrain.finalize()
	terrain.area_changed.connect(_on_terrain_changed)

	water = Water.new()
	add_child(water)
	water.setup(terrain)
	water.fill_channel(river, river_beds, 6.0, 1.4)
	var source_z := -Terrain.HALF_SIZE + 1.5
	water.add_head(Vector2(river[0].x - 6.0, source_z), Vector2(river[0].x + 6.0, source_z), river_beds[0] + 1.4)
	water.fill(LAKE, LAKE_RADIUS + 3.0, lake_level)
	water.fill_channel(feeder, feeder_beds, 1.4, 0.45)
	water.add_head(feeder[0] + Vector2(0, -1.5), feeder[0] + Vector2(0, 1.5), feeder_beds[0] + 0.45)
	water.fill_channel(outlet, outlet_beds, 1.6, 0.4)

	var debris_root := Node3D.new()
	debris_root.name = "Debris"
	add_child(debris_root)
	for k in sites.size():
		var site: Dictionary = sites[k]
		var pos: Vector2 = site.pos
		debris.append_array(Buildings.house(debris_root, Vector3(pos.x, levels[k], pos.y),
				site.nx, site.nz, site.rows, site.style))
	var wall_at := DEMOLITION + Vector2(-4, -30)
	debris.append_array(Buildings.wall(debris_root, Vector3(wall_at.x, wall_level, wall_at.y), 12, 4, "brick"))
	for body in debris:
		_debris_start.append(body.position)
		body.add_to_group("winchable")
		body.set_meta("label", "rubble")
	props = Scenery.build_zone(self, ZONE, zone_level)
	for prop in props:
		prop.add_to_group("winchable")
		prop.set_meta("label", "prop")
	_build_forests(rng)
	Scenery.tree_ring(self, Terrain.HALF_SIZE + 3.0, Terrain.HALF_SIZE + 60.0, 1500)
	_build_particle_ground()

	camera = FollowCamera.new()
	camera.terrain = terrain
	add_child(camera)
	grass = Grass.new()
	add_child(grass)
	grass.setup(terrain, camera)
	grass.add_meadow(Terrain.HALF_SIZE, Terrain.HALF_SIZE + 30.0, 45000, 0.0)

	excavator = Excavator.new()
	excavator.terrain = terrain
	excavator.water = water
	_park(excavator, ZONE + Vector2(-3.25, 9.5), 0.0)
	dozer = Bulldozer.new()
	dozer.terrain = terrain
	_park(dozer, ZONE + Vector2(3.25, 9.5), 0.0)
	truck = Truck.new()
	truck.terrain = terrain
	_park(truck, ZONE + Vector2(9.75, 9.5), PI, 0.25)
	recovery = Truck.new()
	recovery.recovery = true
	recovery.terrain = terrain
	_park(recovery, ZONE + Vector2(16.25, 9.5), PI, 0.25)
	trailer = Trailer.new()
	_park(trailer, ZONE + Vector2(22, -20), -PI * 0.5, 0.3)
	excavator.receivers = [truck]
	machines = [excavator, dozer, truck, recovery]

	player = Player.new()
	player.camera = camera
	player.position = Vector3(PLAYER_SPAWN.x, terrain.get_height(PLAYER_SPAWN.x, PLAYER_SPAWN.y) + 0.1, PLAYER_SPAWN.y)
	add_child(player)
	camera.set_target(player, false, 7.0)
	camera.orbit = 0.0
	camera.snap()

	hud = Hud.new()
	add_child(hud)
	hud.view_pressed.connect(func() -> void: camera.toggle_cab_view())
	hud.exit_pressed.connect(_exit_machine)
	hud.utility_pressed.connect(_use_utility)
	mouse = MouseControls.new()
	hud.add_child(mouse)
	for m in machines:
		m.mouse_input = mouse.output
	print("Earthworks: %.0f m map, %d trees, %d blocks, %d props, %.0f m3 water, built in %d ms" % [
		Terrain.HALF_SIZE * 2.0, trees.size(), debris.size(), props.size(), water.total_volume(),
		Time.get_ticks_msec() - started])


func _park(machine: Node3D, at: Vector2, yaw: float, lift := 0.0) -> void:
	machine.position = Vector3(at.x, terrain.get_height(at.x, at.y) + lift, at.y)
	machine.rotation.y = yaw
	add_child(machine)


func _build_forests(rng: RandomNumberGenerator) -> void:
	var meshes := [Scenery.pine_mesh(Color(0.2, 0.42, 0.22)), Scenery.pine_mesh(Color(0.24, 0.47, 0.25)),
		Scenery.broadleaf_mesh(Color(0.93, 0.72, 0.3)), Scenery.broadleaf_mesh(Color(0.45, 0.58, 0.25))]
	var root := Node3D.new()
	root.name = "Forest"
	add_child(root)
	var avoid := func(p: Vector2) -> bool:
		if water.depth_at(p.x, p.y) > 0.0 or terrain.mud_at(p.x, p.y) > 0.25:
			return true
		if absf(p.x - ZONE.x) < Scenery.ZONE_HALF.x + 4.0 and absf(p.y - ZONE.y) < Scenery.ZONE_HALF.y + 4.0:
			return true
		return p.distance_to(BORROW_MOUND) < 17.0 or p.distance_to(DEMOLITION) < 32.0
	for f in [[Vector2(40, -6), 30.0, 110], [Vector2(-108, -112), 24.0, 60], [Vector2(124, 64), 16.0, 35],
			[Vector2(10, -110), 22.0, 60], [Vector2(62, 106), 12.0, 26], [Vector2(-120, 104), 16.0, 40],
			[Vector2(-30, -14), 14.0, 35]]:
		trees.append_array(Scenery.spawn_forest(root, terrain, f[0], f[1], f[2], rng, meshes, avoid))
	for tree in trees:
		tree.felled.connect(func(_t: Node3D) -> void: trees_felled += 1)
		tree.stump_freed.connect(func(t: Node3D) -> void:
			stumps_cleared += 1
			trees.erase(t))


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
		return
	if Input.is_action_just_pressed("reset_vehicle") and _driving:
		_driving.reset()
	if Input.is_action_just_pressed("toggle_help"):
		hud.toggle_help()
	var nearest: Node3D = null
	if not _driving:
		var best := ENTER_DISTANCE
		for m in machines:
			var d := player.global_position.distance_to(m.door_position())
			if d < best:
				best = d
				nearest = m
	# On foot at the back of the trailer: work the ramps.
	var at_ramps := not _driving and player.global_position.distance_to(trailer.ramp_point()) < 3.0 		and (nearest == null or player.global_position.distance_to(trailer.ramp_point()) < player.global_position.distance_to(nearest.door_position()))
	if Input.is_action_just_pressed("interact"):
		if _driving:
			_exit_machine()
		elif at_ramps:
			trailer.toggle_ramps()
			_flash("Lowering the ramps" if trailer.ramps_down else "Raising the ramps")
		elif nearest:
			_enter_machine(nearest)
	if _driving:
		_handle_winch()
		if Input.is_action_just_pressed("utility"):
			_use_utility()
	_message_timer -= _delta
	var stats := "Soil moved    %.1f m³\nDestruction   %d%%\nTrees felled  %d\nStumps out    %d" % [
		excavator.soil_moved, roundi(_destruction * 100.0), trees_felled, stumps_cleared]
	if _message_timer > 0.0:
		hud.set_prompt(_message)
	elif _driving:
		hud.set_prompt("")
	if _driving:
		player.set_controls(_driving.controls())
		player.set_body_visible(not camera.cab_view)
		hud.update_stats(_driving.machine_name.to_upper() + "   ·   " + _driving.status(), _driving.status_fill(), stats)
	else:
		if _message_timer <= 0.0:
			if at_ramps:
				hud.set_prompt("Press F / X to %s the ramps" % ("raise" if trailer.ramps_down else "lower"))
			else:
				hud.set_prompt("Press F / X to drive the %s" % nearest.machine_name.to_lower() if nearest else "")
		hud.update_stats("ON FOOT", 0.0, stats)
	_rumble()


func _flash(text: String) -> void:
	_message = text
	_message_timer = 2.5


## Winch button: tap to hook the nearest thing, hold to reel in, tap again to unhook.
func _handle_winch() -> void:
	var winch = _driving.get("winch")
	if winch == null:
		return
	if Input.is_action_just_pressed("winch"):
		_winch_down_at = Time.get_ticks_msec() / 1000.0
		_winch_was_attached = winch.is_attached()
		if not _winch_was_attached:
			var hooked: String = winch.attach(winch.global_position - _driving.global_position)
			_flash("Winch hooked to the %s — hold H / B to reel in" % hooked if hooked != "" else "Nothing in winch range (%.0f m)" % winch.reach)
	var held := Time.get_ticks_msec() / 1000.0 - _winch_down_at
	var reeling := Input.is_action_pressed("winch") and _winch_was_attached and held > 0.25
	if reeling != _winch_reeling:
		winch.reel(reeling)
		_winch_reeling = reeling
	if Input.is_action_just_released("winch") and _winch_was_attached and held <= 0.25:
		winch.detach()
		_flash("Winch released")


## Tool / hitch button: the excavator swaps attachments, trucks hitch or drop the trailer.
func _use_utility() -> void:
	if _driving == excavator:
		_flash("Attachment: " + excavator.cycle_attachment())
	elif _driving is Truck:
		var t: Truck = _driving
		if t.trailer:
			trailer.unhitch()
			t.trailer = null
			_flash("Trailer unhitched")
		elif trailer.towed_by == null and trailer.hitch_point().distance_to(t.hitch_point()) < 3.5:
			trailer.hitch(t, t.hitch_point())
			t.trailer = trailer
			_flash("Trailer hitched")
		else:
			_flash("Back the hitch up to the trailer's drawbar to hitch (%.0f m away)" % trailer.hitch_point().distance_to(t.hitch_point()))


## Controller vibration follows what the machine is doing (digging, pushing, stuck).
func _rumble() -> void:
	var strength: Vector2 = _driving.rumble() if _driving else Vector2.ZERO
	for device in Input.get_connected_joypads():
		if strength.length() > 0.01:
			Input.start_joy_vibration(device, clampf(strength.x, 0, 1), clampf(strength.y, 0, 1), 0.15)
		else:
			Input.stop_joy_vibration(device)


func _physics_process(delta: float) -> void:
	if _autotest:
		_run_autotest(delta)
	_destruction_timer -= delta
	if _destruction_timer <= 0.0:
		_destruction_timer = 0.5
		_update_destruction()


func _enter_machine(machine: Node3D) -> void:
	_driving = machine
	machine.driven = true
	player.set_active(false)
	player.sit(machine.seat)
	camera.set_target(machine.cab, true, 19.0 if machine == excavator else 16.0)
	hud.set_utility(_utility_label(machine))
	camera.eye = machine.eye
	camera.mouse_orbit = false
	mouse.enabled = true
	hud.set_mode(true)


func _utility_label(machine: Node3D) -> String:
	if machine == excavator:
		return "Swap tool (N)"
	if machine is Truck:
		return "Hitch (T)"
	return ""


func _exit_machine() -> void:
	if not _driving:
		return
	var machine := _driving
	if machine.get("winch"):
		machine.winch.reel(false)
	_driving = null
	machine.driven = false
	mouse.enabled = false
	if camera.cab_view:
		camera.toggle_cab_view()
	camera.eye = null
	camera.mouse_orbit = true
	player.stand()
	var p: Vector3 = machine.door_position()
	player.global_position = Vector3(p.x, terrain.get_height(p.x, p.z) + 0.1, p.z)
	player.set_active(true)
	camera.set_target(player, false, 7.0)
	hud.set_mode(false)


## Average ground height around a basin.
func _rim_average(center: Vector2, radius: float) -> float:
	var total := 0.0
	for k in 72:
		var p := center + Vector2.from_angle(TAU * k / 72.0) * radius
		total += terrain.get_height(p.x, p.y)
	return total / 72.0


func _update_destruction() -> void:
	var moved := 0
	for k in debris.size():
		if debris[k].position.distance_to(_debris_start[k]) > MOVED_THRESHOLD:
			moved += 1
	_destruction = float(moved) / maxi(debris.size(), 1)


## Terrain changed: wake sleeping blocks and props so they fall into holes, and check
## whether any stumps have been dug free.
func _on_terrain_changed(rect: Rect2) -> void:
	var area := rect.grow(1.5)
	for body in debris + props:
		var p := body.global_position
		if area.has_point(Vector2(p.x, p.z)):
			body.sleeping = false
	for tree in trees.duplicate():
		if tree.is_stump and area.has_point(Vector2(tree.global_position.x, tree.global_position.z)):
			tree.check_roots(terrain)


func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.42, 0.64, 0.88)
	sky_material.sky_horizon_color = Color(0.8, 0.87, 0.93)
	sky_material.ground_horizon_color = Color(0.8, 0.87, 0.93)
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.8, 0.87, 0.93)
	env.fog_density = 0.0035
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)

	# Meadow around the playable square: a frame of four strips, so it never covers
	# anything dug below ground level inside the map.
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Terrain.GROUND
	ground_material.roughness = 1.0
	var far := 400.0
	var inner := Terrain.HALF_SIZE - 0.3  # tuck under the map's flat border to hide the seam
	for strip in [
		[Vector2(far * 2.0, far - inner), Vector3(0, 0, (far + inner) * 0.5)],
		[Vector2(far * 2.0, far - inner), Vector3(0, 0, -(far + inner) * 0.5)],
		[Vector2(far - inner, inner * 2.0), Vector3((far + inner) * 0.5, 0, 0)],
		[Vector2(far - inner, inner * 2.0), Vector3(-(far + inner) * 0.5, 0, 0)],
	]:
		var plane := PlaneMesh.new()
		plane.size = strip[0]
		var piece := MeshInstance3D.new()
		piece.mesh = plane
		piece.material_override = ground_material
		piece.position = strip[1] + Vector3(0, -0.03, 0)
		add_child(piece)


## Lets dirt clods bounce off the ground near the camera instead of falling through it.
func _build_particle_ground() -> void:
	var field := GPUParticlesCollisionHeightField3D.new()
	field.size = Vector3(60.0, 30.0, 60.0)
	field.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_256
	field.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_ALWAYS
	field.follow_camera_enabled = true
	add_child(field)


func _run_autotest(delta: float) -> void:
	_time += delta
	for step in AUTOTEST:
		Input.action_release(step[2])
	for step in AUTOTEST:
		if _time >= step[0] and _time < step[1]:
			Input.action_press(step[2])
	if _once(0.0):
		# Excavator at the borrow mound with the truck parked to its left for loading.
		excavator.place(Transform3D(Basis.IDENTITY, Vector3(BORROW_MOUND.x, 0, BORROW_MOUND.y + 17.0)))
		truck.place(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(BORROW_MOUND.x - 8.0, terrain.get_height(BORROW_MOUND.x - 8.0, BORROW_MOUND.y + 19.0) + 0.4, BORROW_MOUND.y + 19.0)))
		_enter_machine(excavator)
	if _once(11.0):
		# Back the truck in under the bucket (bed centre sits 0.73 m behind the truck's origin).
		var spill: Vector3 = excavator.spill_point()
		var yaw := excavator.cab.global_rotation.y
		var origin := spill - Basis(Vector3.UP, yaw) * Vector3(0, 0, -0.73)
		truck.place(Transform3D(Basis(Vector3.UP, yaw), Vector3(origin.x, terrain.get_height(origin.x, origin.z) + 0.3, origin.z)))
	if _once(13.0):
		_exit_machine()
		dozer.place(Transform3D(Basis.IDENTITY, Vector3(40, 0, 31)))
		player.global_position = dozer.door_position()
		_enter_machine(dozer)
		print("[autotest] truck bed after loading: %.2f m3" % truck.payload)
	if _once(19.0):
		_exit_machine()
		truck.add_soil(6.0)
		truck.place(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(26.0, terrain.get_height(26, 66) + 0.4, 66.0)))
		player.global_position = truck.door_position()
		_enter_machine(truck)
	if _once(27.2):
		print("[autotest] truck stuck=%s mud=%.2f after %.1f s of throttle" % [truck.stuck, truck.mud_level, 7.0])
		_exit_machine()
	if _time >= _next_report:
		_next_report += 1.0
		var who: Node3D = _driving if _driving else player
		print("[autotest] t=%4.1f  %-11s pos=%s  %s  felled=%d  truck=%.1fm3 stuck=%s mud=%.2f  water_awake=%d  fps=%d" % [
			_time, _driving.machine_name if _driving else "on foot", who.global_position.snapped(Vector3.ONE * 0.1),
			_driving.status() if _driving else "", trees_felled, truck.payload, truck.stuck, truck.mud_level,
			water.awake_tiles(), Engine.get_frames_per_second()])
	for shot in [11.0, 18.0, 26.5, 29.5]:
		if _once(shot) and DisplayServer.get_name() != "headless":
			for arg in OS.get_cmdline_user_args():
				if arg.begins_with("--shot="):
					var path := arg.trim_prefix("--shot=").replace(".png", "_%d.png" % roundi(shot * 10))
					get_viewport().get_texture().get_image().save_png(path)
	if _time >= 30.0:
		print("[autotest] done  soil_moved=%.2f  felled=%d  stumps=%d  truck_stuck=%s" % [
			excavator.soil_moved, trees_felled, stumps_cleared, truck.stuck])
		get_tree().quit()


func _once(at: float) -> bool:
	if _time >= at and not _done_steps.has(at):
		_done_steps[at] = true
		return true
	return false
