extends Node3D
## Earthworks: builds the world (terrain, water, forests, the depot, demolition yard and
## shredders), runs the company (cash, unlocks, jobs) and the fleet (any number of
## machines delivered to the depot bays), and hands input to whatever you're driving.
## Multiplayer (net.gd): the host runs everything below; a joining player builds the same
## world, then mirrors the host (machines, logs and rubble become puppets) and sends
## requests ("let me drive that", "buy this") instead of acting directly.

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
const Menu = preload("res://scripts/menu.gd")
const Grass = preload("res://scripts/grass.gd")
const MouseControls = preload("res://scripts/mouse_controls.gd")
const Career = preload("res://scripts/career.gd")
const Jobs = preload("res://scripts/jobs.gd")
const Shredder = preload("res://scripts/shredder.gd")
const Net = preload("res://scripts/net.gd")
const Winch = preload("res://scripts/winch.gd")
const Forests = preload("res://scripts/forests.gd")
const Conveyor = preload("res://scripts/conveyor.gd")
const Roller = preload("res://scripts/roller.gd")
const Updater = preload("res://scripts/updater.gd")
const MobileShredder = preload("res://scripts/mobile_shredder.gd")
const Tip = preload("res://scripts/tip.gd")
const Forge = preload("res://scripts/forge.gd")
const Ties = preload("res://scripts/ties.gd")
const Ores = preload("res://scripts/ores.gd")
## The quarry tip, where soil and gravel are delivered for cash (position, yaw).
const TIP := [Vector2(266, 310), PI]
## The ore crusher on the quarry floor (position, yaw).
const CRUSHER := [Vector2(220, 346), PI * 0.5]
const BOULDERS := 32
const TIE_REACH := 3.5  # how far the worker reaches to tie or cut
const Kit = preload("res://scripts/model_kit.gd")
const WorldSave = preload("res://scripts/world_save.gd")
const AUTOSAVE_INTERVAL := 60.0
## Where supplies (ground mats) are dropped at the depot (depot space).
const SUPPLY_PAD := Vector2(-24, -4)

const ZONE := Vector2(0, 100)
const PLAYER_SPAWN := Vector2(-6, 106)
const BORROW_MOUND := Vector2(-8, 26)
const DEMOLITION := Vector2(-72, 52)
const LAKE := Vector2(-72, -58)
const LAKE_RADIUS := 24.0
const MUD_PITS: Array[Vector3] = [Vector3(44, 66, 9.0), Vector3(-44, 62, 8.0), Vector3(62, 24, 7.0),
	Vector3(160, 120, 10.0), Vector3(-160, 40, 9.0), Vector3(30, 220, 11.0), Vector3(-90, 230, 9.0), Vector3(150, -260, 10.0),
	Vector3(-60, -230, 8.0), Vector3(380, 40, 10.0), Vector3(-430, 120, 11.0), Vector3(200, 450, 9.0), Vector3(-380, -60, 9.0)]
## Big hills: (x, z, radius, height).
const HILLS: Array[Vector4] = [Vector4(-90, 430, 70, 14), Vector4(390, 370, 55, 10), Vector4(-420, -250, 60, 12),
	Vector4(130, -430, 70, 11), Vector4(440, 250, 45, 8), Vector4(-470, 330, 40, 9)]
## Rock mountains: (x, z, radius, height). Bare rock above the lower slopes, a quarter as
## fast to dig or doze as soil.
const MOUNTAINS: Array[Vector4] = [Vector4(-440, -430, 95, 42), Vector4(450, -460, 100, 48), Vector4(-470, 40, 75, 34)]
## Lakes: (x, z, radius). The first is fed by the stream and drains into the river.
const LAKES: Array[Vector3] = [Vector3(-72, -58, 24), Vector3(255, -80, 42), Vector3(-200, -400, 30)]
## Swamps: (x, z, radius) of soft, sinking ground and standing pools.
const SWAMPS: Array[Vector3] = [Vector3(-320, 260, 150), Vector3(320, -300, 110)]
const QUARRY := Vector2(240, 330)
const FARM := Vector2(190, 210)
## The snowy pine forest in the east (x, z, radius) and its frozen pond.
const SNOWFIELD := Vector3(330, 140, 140)
const ICE_POND := Vector3(362, 178, 20)
## Shredders: position and yaw (the infeed faces the yaw's -Z).
const SHREDDERS := [[Vector2(-26, 62), -PI * 0.5], [Vector2(40, -90), PI * 0.5], [Vector2(-200, 150), PI * 0.5],
	[Vector2(-235, -215), PI * 0.5], [Vector2(215, 60), -PI * 0.5]]
## Forests: [centre, radius, trees, species weights (pine, pine, gold broadleaf, green
## broadleaf, swamp cypress, giant oak), swamp forest?]
const FORESTS := [
	[Vector2(40, -6), 30.0, 110, [1, 1, 1, 1, 0, 0], false], [Vector2(-108, -112), 24.0, 60, [1, 1, 1, 1, 0, 0], false],
	[Vector2(124, 64), 16.0, 35, [1, 1, 1, 1, 0, 0], false], [Vector2(10, -110), 22.0, 60, [1, 1, 1, 1, 0, 0], false],
	[Vector2(62, 106), 12.0, 26, [1, 1, 1, 1, 0, 0], false], [Vector2(-120, 104), 16.0, 40, [1, 1, 1, 1, 0, 0], false],
	[Vector2(-30, -14), 14.0, 35, [1, 1, 1, 1, 0, 0], false],
	[Vector2(-320, 260), 140.0, 420, [0, 0, 0, 1, 6, 0], true], [Vector2(320, -300), 105.0, 220, [0, 0, 0, 1, 5, 0], true],
	[Vector2(-330, -330), 140.0, 520, [1, 0, 1, 2, 0, 3], false], [Vector2(330, 140), 120.0, 480, [4, 4, 0, 1, 0, 0], false],
	[Vector2(180, -200), 40.0, 90, [1, 1, 1, 1, 0, 1], false], [Vector2(-150, -250), 45.0, 100, [1, 1, 2, 1, 0, 0], false],
	[Vector2(150, 340), 40.0, 80, [2, 2, 1, 1, 0, 0], false], [Vector2(0, -330), 50.0, 120, [1, 1, 1, 2, 0, 1], false],
	[Vector2(-420, 40), 45.0, 100, [2, 1, 1, 1, 0, 0], false], [Vector2(420, -60), 40.0, 90, [1, 2, 0, 1, 0, 0], false],
	[Vector2(-200, 420), 40.0, 80, [0, 1, 1, 2, 0, 1], false], [Vector2(430, 430), 45.0, 90, [2, 2, 0, 1, 0, 0], false],
	[Vector2(-440, -440), 40.0, 80, [1, 1, 1, 1, 0, 2], false], [Vector2(300, 460), 35.0, 60, [2, 1, 1, 1, 0, 0], false],
]
const ENTER_DISTANCE := 3.2
## Network ids: rubble blocks are 0.., logs and stumps start here.
const FIRST_DYNAMIC_ID := 100000

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
var career: Career
var jobs: Jobs
var net: Net
var player: Player
var camera: FollowCamera
var hud: Hud
var menu: Menu
var grass: Grass
var mouse: MouseControls
var environment: Environment
var sun: DirectionalLight3D
## Everything you can drive, and the trailers.
var machines: Array = []
var trailers: Array = []
var shredders: Array = []
var updater: Node
var tip: Node3D
var _wood_text := ""
var _wood_timer := 0.0
## The starting fleet (and the test fleet), for the automated checks.
var excavator: Excavator
var dozer: Bulldozer
var truck: Truck
var recovery: Truck
var trailer: Trailer
var debris: Array[RigidBody3D] = []
var props: Array[RigidBody3D] = []
var forests: Forests
var demolition_sites: Array = []  # {name, center, blocks, starts}
var trees_felled := 0
var stumps_cleared := 0
## Network registries: vehicles and loose bodies (rubble, logs, stumps) by id, trees by
## id, and what has happened to each tree ([state 0 standing / 1 felled / 2 stump out,
## log id, stump id]).
var vehicles_by_id := {}
var bodies := {}
var tree_bodies := {}  # tid -> [log id, stump id]
var next_net_id := 1
var next_body_id := FIRST_DYNAMIC_ID
## Joining player: the HUD numbers for the machine they're in (sent by the host).
var remote_hud := {}

var _receivers: Array = []  # trucks the excavators can load (shared with every excavator)
var _driving: Node3D = null
var _winch_states := {}  # peer -> winch button state (1 = this machine)
var _pending_body_id := -1  # joining player: id to give the next log/stump a tree spawns
var _anchor_timer := 0.0
var _joining := false
var _changed_areas: Array[Rect2] = []
var _snowfall: GPUParticles3D
var ties: Node3D  # ratchet straps and ropes
var _dig_tally := {}  # 2 m patch -> m3 dug since its last chance at a find
var _ore_rng := RandomNumberGenerator.new()
var _tie_pending := {}  # first end of a tie being made: {kind, node, local}
var _tie_line: MeshInstance3D  # the strap or rope in the worker's hands meanwhile  # gentle snow round the camera in the snowy forest  # ground changed this frame (see _settle_bodies...)
var _restoring := false  # putting a saved world back: no stats or job progress for it
var _autosave_timer := AUTOSAVE_INTERVAL
var _autotest := false
var _time := 0.0
var _next_report := 1.0
var _done_steps := {}


func _ready() -> void:
	var started := Time.get_ticks_msec()
	InputSetup.setup()
	_autotest = "--autotest" in OS.get_cmdline_user_args()
	var scripted := _autotest or "-s" in OS.get_cmdline_args() or "--script" in OS.get_cmdline_args()
	var joining: bool = Net.pending.get("mode", "") == "join"
	career = Career.new()
	career.persistent = not scripted and not joining
	add_child(career)
	if scripted:
		for item in Career.MACHINES + Career.TOOLS:
			career.owned[item.id] = true  # automated checks use every machine and tool
	net = Net.new()
	net.name = "Net"
	add_child(net)
	Winch.identify = net_id_of
	Winch.resolve = node_by_net_id
	_build_environment()
	_joining = joining

	terrain = Terrain.new()
	add_child(terrain)
	terrain.generate(7)
	terrain.add_mound(BORROW_MOUND, 14.0, 6.0)
	terrain.add_mound(Vector2(22, 44), 8.0, 3.0)
	for hill in HILLS:
		terrain.add_mound(Vector2(hill.x, hill.y), hill.z, hill.w)
	# Rock mountains: a main peak with lesser crags round it, bare rock above the foothills.
	var crag_rng := RandomNumberGenerator.new()
	crag_rng.seed = 4242
	for mountain in MOUNTAINS:
		var mc := Vector2(mountain.x, mountain.y)
		terrain.add_mound(mc, mountain.z, mountain.w * 0.75)
		for k in 6:
			var at := mc + Vector2.from_angle(k * TAU / 6.0 + crag_rng.randf() * 0.6) * mountain.z * crag_rng.randf_range(0.2, 0.45)
			terrain.add_mound(at, mountain.z * crag_rng.randf_range(0.3, 0.45), mountain.w * crag_rng.randf_range(0.2, 0.35))
		terrain.paint_rock(mc, mountain.z * 0.8)
	terrain.deep_zones = SWAMPS
	for pit in MUD_PITS:
		terrain.add_mound(Vector2(pit.x, pit.y), pit.z, -0.5)
	# Lakes: deep basins; each level sits just under the lowest point of its rim.
	var lake_levels: Array[float] = []
	for lake in LAKES:
		var at := Vector2(lake.x, lake.y)
		terrain.add_mound(at, lake.z, -5.5)
		var level := _rim_average(at, lake.z + 0.5) - 0.2
		terrain.raise_ring(at, lake.z - 1.0, lake.z + 6.0, level + 0.5)
		terrain.clear_grass(at, lake.z + 2.0)
		lake_levels.append(level)
	var lake_level: float = lake_levels[0]
	# Main river: meanders down the east side of the whole map, north to south.
	var river := PackedVector2Array()
	var river_beds := PackedFloat32Array()
	var steps := int(Terrain.HALF_SIZE * 2.0 / 7.8) + 1
	for k in steps:
		var z := -Terrain.HALF_SIZE + k * 7.8
		river.append(Vector2(92.0 + 18.0 * sin(z / 40.0) + 6.0 * sin(z / 13.0) + 30.0 * sin(z / 170.0) * smoothstep(150.0, 260.0, absf(z)), z))
		river_beds.append(-1.8 - 0.006 * (z + Terrain.HALF_SIZE))
	river_beds = terrain.carve_channel(river, river_beds, 6.5, 2.0, 0.35)
	# West river: from the western edge, through the Great Swamp and out to the south.
	var west := PackedVector2Array([Vector2(-510, -150), Vector2(-450, -128), Vector2(-400, -90), Vector2(-360, -40),
		Vector2(-330, 30), Vector2(-318, 100), Vector2(-330, 170), Vector2(-312, 240), Vector2(-290, 300),
		Vector2(-300, 360), Vector2(-275, 430), Vector2(-262, 510)])
	var west_beds := PackedFloat32Array()
	for k in west.size():
		west_beds.append(lerpf(0.5, -4.5, k / float(west.size() - 1)))
	west_beds = terrain.carve_channel(west, west_beds, 4.5, 1.6, 0.4)
	# Stream feeding the lake from the western hills.
	var feeder := PackedVector2Array([Vector2(-132, 14), Vector2(-120, 8), Vector2(-108, -2), Vector2(-96, -16), Vector2(-86, -34), Vector2(-82, -42)])
	var feeder_beds := PackedFloat32Array()
	for k in feeder.size():
		feeder_beds.append(lerpf(lake_level + 1.2, lake_level - 0.4, k / float(feeder.size() - 1)))
	feeder_beds = terrain.carve_channel(feeder, feeder_beds, 1.6, 0.8, 0.45)
	# Outlet stream from the lake east into the river.
	var join := _nearest_index(river, Vector2(80, -66))
	var outlet := PackedVector2Array([Vector2(-50, -62), Vector2(-24, -68), Vector2(8, -62), Vector2(40, -70), Vector2(river[join].x - 6.0, river[join].y)])
	var outlet_beds := PackedFloat32Array()
	for k in outlet.size():
		outlet_beds.append(lerpf(lake_level - 0.45, river_beds[join] + 1.2, k / float(outlet.size() - 1)))
	outlet_beds = terrain.carve_channel(outlet, outlet_beds, 1.8, 0.9, 0.45)
	# Swamps: soft ground everywhere, sunk pools of standing water.
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var pools: Array = []
	for swamp in SWAMPS:
		var c := Vector2(swamp.x, swamp.y)
		var r: float = swamp.z
		for k in int(r / 6.0):
			var p := c + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r * 0.85
			var pr := rng.randf_range(7.0, 16.0)
			terrain.add_mound(p, pr, -rng.randf_range(0.6, 1.2))
			pools.append([p, pr])
		terrain.clear_grass(c, r * 0.9)

	var zone_level := Scenery.prepare_zone(terrain, ZONE)
	var shredder_levels: Array[float] = []
	for s in SHREDDERS:
		var at: Vector2 = s[0]
		shredder_levels.append(terrain.flatten(at, Vector2(12, 12), 5.0))
		terrain.protect(at, Vector2(11, 11))
		terrain.paint_gravel(at, Vector2(11, 11))
		terrain.clear_grass(at, 13.0)
	# Gravel quarry: a levelled floor with big gravel stockpiles to load trucks from.
	var quarry_level := terrain.flatten(QUARRY, Vector2(36, 26), 10.0)
	terrain.paint_gravel(QUARRY, Vector2(38, 28))
	for k in 4:
		var pile := QUARRY + Vector2(-24 + k * 16, -10 if k % 2 == 0 else 8)
		terrain.add_mound(pile, 9.0, 4.5)
	terrain.clear_grass(QUARRY, 44.0)
	var sites := [
		{"pos": DEMOLITION + Vector2(2, -4), "nx": 8, "nz": 6, "rows": 6, "style": "brick", "name": "brick warehouse"},
		{"pos": DEMOLITION + Vector2(-20, 20), "nx": 6, "nz": 6, "rows": 5, "style": "concrete", "name": "concrete block"},
		{"pos": DEMOLITION + Vector2(18, 30), "nx": 3, "nz": 3, "rows": 12, "style": "concrete", "name": "concrete tower"},
		{"pos": FARM, "nx": 7, "nz": 5, "rows": 4, "style": "brick", "name": "old farmhouse"},
	]
	var levels: Array[float] = []
	for site in sites:
		levels.append(terrain.flatten(site.pos, Vector2(site.nx, site.nz) * 0.5 + Vector2.ONE, 3.0))
	var wall_level := terrain.flatten(DEMOLITION + Vector2(-4, -30), Vector2(7, 1.5), 3.0)
	# Mud: pits, river banks, lake shores, along the outlet, and the swamps.
	for pit in MUD_PITS:
		terrain.add_mud(Vector2(pit.x, pit.y), pit.z + 2.0, 1.0)
	terrain.add_mud(Vector2(32, 66), 5.0, 0.7)
	for k in range(0, river.size(), 3):
		terrain.add_mud(river[k], 16.0, 0.8)
	for p in west:
		terrain.add_mud(p, 14.0, 0.85)
	for k in LAKES.size():
		var lake: Vector3 = LAKES[k]
		for j in 28:
			terrain.add_mud(Vector2(lake.x, lake.y) + Vector2.from_angle(TAU * j / 28.0) * (lake.z + 1.0), 5.0, 0.85)
	for p in outlet:
		terrain.add_mud(p, 4.5, 0.6)
	for swamp in SWAMPS:
		var c := Vector2(swamp.x, swamp.y)
		var r: float = swamp.z
		for k in int(r * r / 220.0):
			var p := c + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r
			terrain.add_mud(p, rng.randf_range(14.0, 26.0), rng.randf_range(0.7, 1.0))
	# Snow over the eastern pine forest (after the mud, so it lies on top), and a frozen pond.
	terrain.flatten(Vector2(ICE_POND.x, ICE_POND.y), Vector2(ICE_POND.z, ICE_POND.z) * 0.7, 8.0)
	terrain.paint_snow(Vector2(SNOWFIELD.x, SNOWFIELD.y), SNOWFIELD.z)
	terrain.paint_ice(Vector2(ICE_POND.x, ICE_POND.y), ICE_POND.z)
	terrain.flatten(CRUSHER[0], Vector2(12, 12), 4.0)
	terrain.protect(CRUSHER[0], Vector2(11, 11))
	terrain.flatten(TIP[0], Vector2(8, 8), 4.0)
	terrain.protect(TIP[0], Vector2(7, 7))
	terrain.finalize()
	terrain.area_changed.connect(_on_terrain_changed)
	terrain.soil_removed.connect(_on_soil_removed)

	water = Water.new()
	add_child(water)
	water.setup(terrain)
	water.fill_channel(river, river_beds, 6.0, 1.4)
	var source_z := -Terrain.HALF_SIZE + 1.5
	water.add_head(Vector2(river[0].x - 6.0, source_z), Vector2(river[0].x + 6.0, source_z), river_beds[0] + 1.4)
	water.fill_channel(west, west_beds, 4.0, 1.0)
	water.add_head(west[0] + Vector2(0, -4), west[0] + Vector2(0, 4), west_beds[0] + 1.0)
	for k in LAKES.size():
		var lake: Vector3 = LAKES[k]
		water.fill(Vector2(lake.x, lake.y), lake.z + 3.0, lake_levels[k])
	water.fill_channel(feeder, feeder_beds, 1.4, 0.45)
	water.add_head(feeder[0] + Vector2(0, -1.5), feeder[0] + Vector2(0, 1.5), feeder_beds[0] + 0.45)
	water.fill_channel(outlet, outlet_beds, 1.6, 0.4)
	for pool in pools:
		var p: Vector2 = pool[0]
		water.fill(p, pool[1] * 0.6, terrain.get_height(p.x, p.y) + 0.45)

	var debris_root := Node3D.new()
	debris_root.name = "Debris"
	add_child(debris_root)
	for k in sites.size():
		var site: Dictionary = sites[k]
		var pos: Vector2 = site.pos
		var blocks := Buildings.house(debris_root, Vector3(pos.x, levels[k], pos.y), site.nx, site.nz, site.rows, site.style)
		_add_demolition_site(String(site.name), pos, blocks)
	var wall_at := DEMOLITION + Vector2(-4, -30)
	_add_demolition_site("brick wall", wall_at, Buildings.wall(debris_root, Vector3(wall_at.x, wall_level, wall_at.y), 12, 4, "brick"))
	# (No loose boulders or ore chunks any more: ore is in the soil itself, see ores.gd.)
	for k in debris.size():
		_register_body(debris[k], k)
	props = Scenery.build_zone(self, ZONE, zone_level)
	# Stockpiles you can load from: loose material on top of the protected yard, and the
	# quarry's gravel (gravel makes firm ground wherever it's dumped).
	for k in Scenery.BAYS.size():
		var pile := ZONE + Scenery.BAYS[k] + Vector2(0, 0.4)
		for j in 6:
			terrain.deposit(pile.x, pile.y, 3.5, 2.6, Terrain.SURFACE_GRAVEL if k == 0 else Terrain.SURFACE_SOIL)
	var heap := ZONE + Vector2(-8, -9)
	for j in 8:
		terrain.deposit(heap.x, heap.y, 4.0, 4.0)
	Scenery.quarry_props(self, QUARRY, quarry_level)
	for k in SHREDDERS.size():
		var s := Shredder.new()
		var at: Vector2 = SHREDDERS[k][0]
		s.position = Vector3(at.x, shredder_levels[k], at.y)
		s.rotation.y = SHREDDERS[k][1]
		s.remote = joining
		add_child(s)
		s.shredded.connect(_on_shredded)
		s.feeding.connect(func(body: RigidBody3D) -> void: net.send_shred(k, int(body.get_meta("body_id", -1))))
		shredders.append(s)
	# The quarry tip: soil and gravel delivered for cash.
	tip = Tip.new()
	tip.position = Vector3(TIP[0].x, terrain.get_height(TIP[0].x, TIP[0].y), TIP[0].y)
	tip.rotation.y = TIP[1]
	add_child(tip)
	tip.paid.connect(func(value: int, label: String, _at: Vector3) -> void: career.earn(value, label.capitalize()))
	# The ore crusher on the quarry floor (works like a shredder, but takes rock).
	var crusher := Shredder.new()
	crusher.accepts = "ore"
	crusher.machine_name = "Ore crusher"
	crusher.position = Vector3(CRUSHER[0].x, terrain.get_height(CRUSHER[0].x, CRUSHER[0].y), CRUSHER[0].y)
	crusher.rotation.y = CRUSHER[1]
	crusher.remote = joining
	add_child(crusher)
	crusher.shredded.connect(_on_shredded)
	var crusher_index := shredders.size()
	crusher.feeding.connect(func(body: RigidBody3D) -> void: net.send_shred(crusher_index, int(body.get_meta("body_id", -1))))
	shredders.append(crusher)
	_refresh_receivers()
	_build_forests(rng)
	Scenery.tree_ring(self, Terrain.HALF_SIZE + 3.0, Terrain.HALF_SIZE + 70.0, 4200)
	_build_particle_ground()

	camera = FollowCamera.new()
	camera.terrain = terrain
	add_child(camera)
	# (No grass blades: thousands of them cost too much frame rate. The ground's own
	# grass colouring stays.)
	terrain.focus = camera
	water.focus = camera

	player = Player.new()
	player.camera = camera
	player.terrain = terrain
	player.position = Vector3(PLAYER_SPAWN.x, terrain.get_height(PLAYER_SPAWN.x, PLAYER_SPAWN.y) + 0.1, PLAYER_SPAWN.y)
	add_child(player)
	camera.set_target(player, false, 7.0)
	camera.orbit = 0.0
	camera.snap()

	mouse = MouseControls.new()
	hud = Hud.new()
	add_child(hud)
	hud.add_child(mouse)
	hud.view_pressed.connect(func() -> void: camera.toggle_cab_view())
	hud.exit_pressed.connect(_leave_machine)
	hud.utility_pressed.connect(_press_utility)

	jobs = Jobs.new()
	jobs.remote = joining
	add_child(jobs)
	if not joining:
		# Starting fleet: the machines every career begins with.
		excavator = spawn_vehicle("excavator")
		dozer = spawn_vehicle("dozer")
		truck = spawn_vehicle("dump")
		if scripted:
			# Automated checks also want the recovery truck and the trailer.
			recovery = spawn_vehicle("recovery")
			trailer = spawn_vehicle("trailer")
	jobs.setup(self)
	jobs.completed.connect(_on_job_completed)
	jobs.offers_changed.connect(func() -> void: net.send_jobs())
	hud.setup(self)
	hud.set_money(career.money, true)
	career.money_changed.connect(func(money: int, change: int, reason: String) -> void:
		hud.set_money(money)
		hud.money_popup(change, reason)
		net.send_career(change, reason))
	menu = Menu.new()
	add_child(menu)
	menu.setup(self, career)
	menu.buy.connect(func(id: String) -> void: _request(1, "buy", id))
	menu.deliver.connect(func(kind: String) -> void: _request(1, "deliver", kind))
	menu.buy_supply.connect(func(id: String) -> void: _request(1, "supply", id))
	menu.take_job.connect(func(index: int) -> void: _request(1, "take_job", index))
	menu.abandon_job.connect(func() -> void: _request(1, "abandon_job", null))
	menu.return_vehicle.connect(func(node: Node3D) -> void: _request(1, "return", int(node.get_meta("net_id", -1))))
	menu.right_vehicle.connect(func(node: Node3D) -> void: _request(1, "reset", int(node.get_meta("net_id", -1))))
	menu.quality_changed.connect(func(q: int) -> void:
		career.quality = q
		career.save_settings()
		apply_quality(q))
	apply_quality(career.quality)
	ties = Ties.new()
	ties.main = self
	add_child(ties)
	menu.clean_up.connect(clean_up_site)
	menu.new_career.connect(func() -> void:
		career.new_game()
		WorldSave.erase()
		get_tree().reload_current_scene())
	menu.host_requested.connect(_on_host_requested)
	menu.join_requested.connect(_on_join_requested)
	menu.host_online_requested.connect(_on_host_online_requested)
	menu.join_code_requested.connect(_on_join_code_requested)
	menu.leave_requested.connect(func() -> void: net.leave())
	net.players_changed.connect(_on_players_changed)
	# From here on every change to the ground is kept for the world save; put the saved
	# world back (your own game only: never in tests or someone else's world).
	terrain.record_edits = true
	if career.persistent:
		_restoring = true
		if WorldSave.restore(self):
			print("Earthworks: restored the saved world (%d changed ground chunks)" % terrain.edited.size())
		_restoring = false
	_update_anchors()
	terrain.prepare_around(player.global_position)
	# Checks GitHub for a newer version (exported builds) and downloads it in the background.
	updater = Updater.new()
	add_child(updater)
	updater.update_ready.connect(func(version: String) -> void:
		hud.toast("UPDATE %s DOWNLOADED  ·  pause menu → RESTART TO UPDATE (or just restart the game)" % version, Hud.GOOD))
	print("Earthworks: %.0f m map, %d trees, %d blocks, %d job sites, built in %d ms" % [
		Terrain.HALF_SIZE * 2.0, forests.count(), debris.size(), jobs.sites.size(), Time.get_ticks_msec() - started])
	var pending := Net.pending
	Net.pending = {}
	if joining:
		_start_joining(pending)
	elif pending.has("toast"):
		hud.toast(String(pending.toast), Hud.BAD)
	elif not scripted:
		hud.toast("Welcome to the depot  ·  press %s to hire machines and take jobs" % hud.key("menu"), Hud.ACCENT)
	if "--clean-save" in OS.get_cmdline_user_args():
		# Tidy a saved world from the command line: clear loose clutter, save, quit.
		await get_tree().physics_frame
		print("Earthworks: cleaned up %d things" % clean_up_site())
		await get_tree().physics_frame
		save_world()
		get_tree().quit()
		return
	if "--host-online" in OS.get_cmdline_user_args():
		var error := net.host_online(_arg_value("--name", "Host"), _arg_value("--code", ""))
		print("Earthworks: hosting online, room code %s %s" % [net.room_code, error])
	elif "--host" in OS.get_cmdline_user_args():
		_on_host_requested(int(_arg_value("--port", str(Net.DEFAULT_PORT))), _arg_value("--password", "test1234"), _arg_value("--name", "Host"))


func _arg_value(key: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(key + "="):
			return arg.substr(key.length() + 1)
	return fallback


## Graphics quality: 0 low, 1 medium, 2 high.
func apply_quality(q: int) -> void:
	environment.ssao_enabled = q == 2
	sun.directional_shadow_max_distance = [40.0, 60.0, 80.0][q]
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if q == 0 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_DISABLED if q == 0 else Viewport.MSAA_2X
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if q == 0 else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 0.77 if q == 0 else 1.0
	if grass:
		grass.density_scale = [0.35, 0.65, 1.0][q]


# --- Multiplayer: starting and joining ------------------------------------------------------

func _on_host_requested(port: int, password: String, player_name: String) -> void:
	hud.toast("Starting the server (making an encryption key)…", Hud.MUTED)
	var error := net.host(port, password, player_name)
	if error != "":
		hud.toast(error, Hud.BAD)
	else:
		hud.toast("Hosting on port %d  ·  friends join with your address and the password" % port, Hud.GOOD)
		career.save_game()


## Hosts this world online: friends join with the room code (no port forwarding).
func _on_host_online_requested(player_name: String) -> void:
	var error := net.host_online(player_name)
	if error != "":
		hud.toast(error, Hud.BAD)
	else:
		hud.toast("Hosting online  ·  room code %s  ·  friends type it in to join (it's in the pause menu too)" % net.room_code, Hud.GOOD)
		career.save_game()


func _on_join_code_requested(code: String, player_name: String) -> void:
	if net.is_online():
		net.leave()
	Net.pending = {"mode": "join", "code": code, "name": player_name}
	get_tree().reload_current_scene()


## Joining throws away this world: reload, rebuild it in joining mode, then connect.
func _on_join_requested(address: String, port: int, password: String, player_name: String) -> void:
	if net.is_online():
		net.leave()
	Net.pending = {"mode": "join", "address": address, "port": port, "password": password, "name": player_name}
	get_tree().reload_current_scene()


func _start_joining(pending: Dictionary) -> void:
	# Everything that moves is the host's: rubble and trees wait to be told what to do.
	for body in debris:
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
	# Don't appear inside the host's worker.
	var offset := Vector2.from_angle(randf() * TAU) * randf_range(2.5, 4.0)
	player.global_position += Vector3(offset.x, 0.0, offset.y)
	var online := pending.has("code")
	var error: String = net.join_online(String(pending.code), String(pending.name)) if online \
			else net.join(String(pending.address), int(pending.port), String(pending.password), String(pending.name))
	if error != "":
		Net.pending = {"toast": error}
		get_tree().call_deferred("reload_current_scene")
		return
	hud.toast("Looking for the game %s…" % net.room_code if online else "Connecting to %s…" % pending.address, Hud.MUTED)


func _on_players_changed() -> void:
	var list := []
	for peer in net.players:
		list.append([String(net.players[peer].name), net.player_color(peer), peer == net.my_id(), peer == 1])
	hud.set_players(list if net.is_online() else [])


## Joining player: the host's world arrives.
func apply_snapshot(snap: Dictionary) -> void:
	career.set_remote(int(snap.career[0]), snap.career[1], 0, "")
	hud.set_money(career.money, true)
	for entry in snap.trees:
		net_tree_event(int(entry[0]), "fell", int(entry[2]))
		if int(entry[1]) == 2:
			net_tree_event(int(entry[0]), "pulled", int(entry[3]))
	_update_anchors()
	for entry in snap.debris:
		var body: Node3D = bodies.get(int(entry[0]))
		if body:
			body.global_transform = entry[1]
	for entry in snap.loose:
		var body: Node3D = bodies.get(int(entry[0]))
		if body:
			body.global_transform = entry[1]
	for entry in snap.get("mats", []):
		_register_body(make_mat(entry[1]), int(entry[0]))
	for entry in snap.get("ores", []):
		if not bodies.has(int(entry[0])):
			var chunk := Ores.make_chunk(self, String(entry[1]), entry[2])
			chunk.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			chunk.freeze = true
			_register_body(chunk, int(entry[0]))
	for chunk in snap.terrain:
		terrain.net_apply_chunk(chunk)
	for entry in snap.vehicles:
		var v := net_spawn(int(entry[0]), String(entry[1]), entry[2], bool(entry[3]))
		if v:
			v.apply_net_state(entry[2], entry[4])
	for k in mini(shredders.size(), snap.shredded.size()):
		shredders[k].total_shredded = int(snap.shredded[k])
		shredders[k]._grow_pile()
	jobs.apply_net_state(snap.jobs)
	ties.apply_net_state(snap.get("ties", []))
	hud.toast("Joined the game  ·  %d players" % snap.players.size(), Hud.GOOD)


# --- Network ids --------------------------------------------------------------------------

func vehicle_by_id(id: int) -> Node3D:
	var v: Node3D = vehicles_by_id.get(id)
	return v if is_instance_valid(v) else null


## "v12" (vehicle), "b305" (rubble, log, stump) or "t44" (tree) for winch targets.
func net_id_of(node: Node3D) -> String:
	if node.has_meta("net_id"):
		return "v%d" % int(node.get_meta("net_id"))
	if node.has_meta("body_id"):
		return "b%d" % int(node.get_meta("body_id"))
	if node.has_meta("tid"):
		return "t%d" % int(node.get_meta("tid"))
	return ""


func node_by_net_id(id: String) -> Node3D:
	if id.length() < 2:
		return null
	var n := id.substr(1).to_int()
	var node: Node3D
	match id[0]:
		"v": node = vehicles_by_id.get(n)
		"b": node = bodies.get(n)
		"t": node = forests.node_for(n)
	return node if is_instance_valid(node) else null


func _register_body(body: RigidBody3D, id: int) -> void:
	body.set_meta("body_id", id)
	bodies[id] = body
	# Gone for good (shredded, crushed, sold): off the list. (Leaving the tree to be
	# carried by a grapple doesn't count.)
	body.tree_exited.connect(func() -> void:
		if body.is_queued_for_deletion() and bodies.get(id) == body:
			bodies.erase(id))


func _register_vehicle(node: Node3D, id: int, kind: String) -> void:
	node.set_meta("net_id", id)
	node.set_meta("kind", kind)
	vehicles_by_id[id] = node
	if node in trailers:
		return
	node.mouse_input = mouse.output
	machines.append(node)
	_refresh_receivers()


## Joining player: a puppet copy of one of the host's machines.
func net_spawn(id: int, kind: String, xform: Transform3D, broken: bool) -> Node3D:
	if vehicle_by_id(id):
		return vehicle_by_id(id)
	var node := _create_vehicle(kind)
	node.set("puppet", true)
	if node is Truck:
		node.broken = broken
	node.global_transform = xform
	add_child(node)
	if node.has_method("make_puppet"):
		node.make_puppet()
	if node is Trailer:
		trailers.append(node)
	_register_vehicle(node, id, kind)
	return node


## Joining player: a tree fell or lost its stump on the host.
func net_tree_event(tid: int, event: String, body_id: int) -> void:
	_pending_body_id = body_id
	var body := forests.apply_event(tid, event, self)
	if body and not body.has_meta("body_id"):
		_adopt_host_body(body, body_id)
	_pending_body_id = -1


## Joining player: a log or stump made here stands in for the host's (same id, frozen,
## following the host from now on).
func _adopt_host_body(body: RigidBody3D, id: int) -> void:
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	if id >= 0:
		_register_body(body, id)
	else:
		body.queue_free()  # the host's one is already gone


## A tree let go of a log or stump: the host numbers it and tells everyone.
func _on_tree_body(tid: int, body: RigidBody3D, kind: String) -> void:
	if net.is_client():
		_adopt_host_body(body, _pending_body_id)
		return
	var id := next_body_id
	next_body_id += 1
	_register_body(body, id)
	_unbury(body)  # the ground may have been built up round the tree since it grew
	var known: Array = tree_bodies.get(tid, [-1, -1])
	if kind == "log":
		known[0] = id
	else:
		known[1] = id
	tree_bodies[tid] = known
	net.send_tree(tid, "fell" if kind == "log" else "pulled", id)


## A stack of timber crane mats. Heavy, flat and on the deck layer, so trucks roll over
## them and tracked machines sit on them: nothing sinks into mud through a mat.
func spawn_mats(at: Vector3, count: int) -> void:
	for k in count:
		var id := next_body_id
		next_body_id += 1
		var mat := make_mat(Transform3D(Basis(Vector3.UP, 0.05 * k), at + Vector3(0, k * 0.26, 0)))
		_register_body(mat, id)
		net.send_mat(id, mat.global_transform)
	_update_anchors()


func make_mat(xform: Transform3D) -> RigidBody3D:
	var mat := RigidBody3D.new()
	mat.mass = 650.0
	mat.collision_layer = 128
	mat.collision_mask = 1 | 2 | 4 | 8 | 32 | 64 | 128
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.8, 0.22, 1.3)
	shape.shape = box
	mat.add_child(shape)
	var timber := Kit.paint(Color(0.42, 0.3, 0.18), 0.85, 0.0)
	var dark := Kit.paint(Color(0.3, 0.21, 0.13), 0.9, 0.0)
	var steel := Kit.metal(Color(0.45, 0.45, 0.47))
	for k in 4:
		Kit.box(mat, Vector3(4.8, 0.22, 0.31), Vector3(0, 0, -0.48 + k * 0.32), timber if k % 2 == 0 else dark, 0.02)
	for x in [-2.0, -0.7, 0.7, 2.0]:
		Kit.box(mat, Vector3(0.06, 0.23, 1.32), Vector3(x, 0, 0), steel, 0.01)
	for x in [-1.9, 1.9]:
		Kit.add(mat, Kit.cylinder(0.08, 0.03, 8), Vector3(x, 0.12, 0), steel)
	Kit.merge_tree(mat)
	mat.add_to_group("winchable")
	mat.set_meta("label", "ground mat")
	mat.set_meta("grip", [Vector3(-1.8, 0, 0), Vector3(1.8, 0, 0)])
	add_child(mat)
	mat.global_transform = xform
	if net.is_client():
		mat.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		mat.freeze = true
	else:
		# Once it settles it beds into the ground and won't be shoved about by the trucks
		# on it; a grapple or winch lifts it out again.
		mat.sleeping_state_changed.connect(func() -> void:
			if mat.sleeping and not mat.freeze and not mat.has_meta("awaiting_ground"):
				mat.set_meta("bedded", true)
				mat.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				mat.freeze = true)
	return mat


# --- Fleet ---------------------------------------------------------------------------------

func _create_vehicle(kind: String) -> Node3D:
	match kind:
		"excavator":
			var e := Excavator.new()
			e.terrain = terrain
			e.water = water
			e.receivers = _receivers
			e.allowed_attachments = career.allowed_attachments()
			return e
		"excavator_xl":
			var x := Excavator.new()
			x.size_scale = 2.0
			x.terrain = terrain
			x.water = water
			x.receivers = _receivers
			x.allowed_attachments = career.allowed_attachments()
			return x
		"dozer", "dozer_angle", "dozer_xl", "dozer_angle_xl", "dozer_carry":
			var d := Bulldozer.new()
			d.blade_type = "angle" if kind.begins_with("dozer_angle") else "straight"
			match kind:
				"dozer_xl":
					d.size = 2.0
					d.display_name = "Big bulldozer"
				"dozer_angle_xl":
					d.size = 2.0
					d.display_name = "Big angle dozer"
				"dozer_carry":
					# The biggest: a huge high-wall U-blade that carries a small hill ahead of it.
					d.size = 2.3
					d.blade_width_mult = 1.3
					d.blade_height_mult = 1.7
					d.display_name = "Carry dozer"
			d.terrain = terrain
			return d
		"trailer":
			return Trailer.new()
		"log_trailer":
			var lt := Trailer.new()
			lt.variant = "logs"
			return lt
		"flatbed":
			var fb := Trailer.new()
			fb.variant = "flatbed"
			return fb
		"forge":
			var fg := Forge.new()
			fg.terrain = terrain
			return fg
		"mobile_shredder":
			var ms := MobileShredder.new()
			ms.terrain = terrain
			ms.shredded.connect(_on_shredded)
			return ms
		"roller", "roller_xl":
			var ro := Roller.new()
			ro.terrain = terrain
			if kind == "roller_xl":
				ro.size = 1.6
				ro.machine_name = "Big roller"
			return ro
		"conveyor":
			var c := Conveyor.new()
			c.terrain = terrain
			c.receivers = _receivers
			return c
	var t := Truck.new()
	t.kind = kind
	t.terrain = terrain
	t.receivers = _receivers
	return t


## Delivers a new machine to a free bay at the depot; returns it (null if the bays or the
## fleet are full).
func spawn_vehicle(kind: String) -> Node3D:
	if fleet_size() >= Career.MAX_FLEET:
		return null
	var is_trailer := kind == "trailer" or kind == "log_trailer" or kind == "flatbed"
	var bay := _free_bay(is_trailer)
	if bay.x == INF:
		return null
	var node := _create_vehicle(kind)
	var yaw := 0.0
	var lift := 0.0
	if is_trailer:
		yaw = -PI * 0.5
		lift = 0.3
	elif node is Truck:
		yaw = PI
		lift = 0.5 if kind == "adt" else 0.3
	node.position = Vector3(bay.x, terrain.get_height(bay.x, bay.y) + lift, bay.y)
	node.rotation.y = yaw
	add_child(node)
	node.set_meta("bay", int(bay.z))
	if is_trailer:
		trailers.append(node)
	_register_vehicle(node, next_net_id, kind)
	next_net_id += 1
	net.send_spawn(node)
	return node


## A broken-down truck (job vehicle) sunk in mud at `at`.
func spawn_broken_truck(at: Vector3) -> Truck:
	var t := Truck.new()
	t.kind = "dump"
	t.broken = true
	t.terrain = terrain
	t.position = at + Vector3(0, 0.7, 0)
	t.rotation.y = randf() * TAU
	add_child(t)
	t.add_soil(4.0)
	_register_vehicle(t, next_net_id, "dump")
	next_net_id += 1
	net.send_spawn(t)
	return t


func despawn(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	var id := int(node.get_meta("net_id", -1))
	if node == _driving:
		_exit_machine()
	if net.is_host():
		var driver := net.driver_of(id)
		if driver > 1:
			remote_exit(driver)
	for m in machines:
		if m != node and m.get("winch") and m.winch.target == node:
			m.winch.detach()
	if node.get("winch"):
		node.winch.detach()
	if node in trailers:
		var tower: Node3D = node.towed_by
		if is_instance_valid(tower):
			tower.trailer = null
		node.unhitch()
		trailers.erase(node)
	else:
		var towed: Node3D = node.get("trailer")
		if is_instance_valid(towed):
			towed.unhitch()
			node.trailer = null
		machines.erase(node)
	vehicles_by_id.erase(id)
	_refresh_receivers()
	node.queue_free()
	net.send_despawn(id)


func fleet_size() -> int:
	var n := trailers.size()
	for m in machines:
		if not m.get("broken"):
			n += 1
	return n


func focus_node() -> Node3D:
	return _driving if _driving else player


func driving() -> Node3D:
	return _driving


func nearest_shredder(from: Vector3) -> Node3D:
	var best: Node3D = shredders[0]
	for s in shredders:
		if from.distance_to(s.global_position) < from.distance_to(best.global_position):
			best = s
	return best


## Free depot bay as (x, z, bay number); x = INF if all taken.
func _free_bay(for_trailer: bool) -> Vector3:
	var bays: Array[Vector2] = Scenery.TRAILER_BAYS if for_trailer else Scenery.SPAWN_BAYS
	var clearance := 6.5 if for_trailer else 4.2
	for k in bays.size():
		var p := ZONE + bays[k]
		var free := true
		for v in machines + trailers:
			var q: Vector3 = v.global_position if v.is_inside_tree() else v.position
			if Vector2(q.x, q.z).distance_to(p) < clearance:
				free = false
				break
		if free and Vector2(player.position.x, player.position.z).distance_to(p) > 2.0:
			return Vector3(p.x, p.y, k + 1)
	if for_trailer:
		# Trailer bays full (a road train needs several): use a machine bay with room round it.
		for k in Scenery.SPAWN_BAYS.size():
			var p := ZONE + Scenery.SPAWN_BAYS[k]
			var free := true
			for v in machines + trailers:
				var q: Vector3 = v.global_position if v.is_inside_tree() else v.position
				if Vector2(q.x, q.z).distance_to(p) < 7.0:
					free = false
					break
			if free and Vector2(player.position.x, player.position.z).distance_to(p) > 3.0:
				return Vector3(p.x, p.y, 100 + k)
	return Vector3(INF, 0, 0)


func _refresh_receivers() -> void:
	_receivers.clear()
	for m in machines:
		if (m is Truck and m.capacity > 0.0) or m is Conveyor or m is Forge:
			_receivers.append(m)
	# Fixed drop-offs: the quarry tip and the ore crusher (host only: they pay).
	if not net.is_client():
		if tip:
			_receivers.append(tip)
		for s in shredders:
			if s.accepts == "ore":
				_receivers.append(s)


func _right_vehicle(node: Node3D, peer := 1) -> void:
	if not is_instance_valid(node):
		return
	var p := node.global_position
	var yaw := node.global_rotation.y
	var xform := Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, terrain.get_height(p.x, p.z) + 0.6, p.z))
	if node.has_method("place"):
		node.place(xform)
	else:
		node.global_transform = xform
		node.linear_velocity = Vector3.ZERO
		node.angular_velocity = Vector3.ZERO
	net.toast(peer, String(node.machine_name) + " set back on its feet", Hud.MUTED)


# --- Requests (menu actions and the like; a joining player's go to the host) -------------

## Runs an action for `peer` (1 = here). On a joining player's machine it's sent to the host.
func _request(peer: int, action: String, arg: Variant) -> void:
	if net.is_client():
		net.request(action, arg)
	else:
		remote_request(peer, action, arg)


## Host: carries out a player's request (all of them are checked first).
func remote_request(peer: int, action: String, arg: Variant) -> void:
	var who: String = String(net.players[peer].name) if net.players.has(peer) and net.is_online() else ""
	var by := ("  ·  " + who) if who != "" and net.players.size() > 1 else ""
	match action:
		"enter":
			var v := vehicle_by_id(int(arg))
			if v and v in machines:
				remote_enter(peer, v)
		"exit":
			remote_exit(peer)
		"utility":
			var v := vehicle_by_id(int(net.players[peer].driving)) if net.players.has(peer) else null
			if v:
				_use_utility(v, peer)
		"ramps":
			var t := vehicle_by_id(int(arg))
			if t and (t in trailers or t.get("variant") == "logs") and net.players.has(peer):
				var puppet: Node3D = net._puppet_for(peer) if peer != 1 else player
				if puppet.global_position.distance_to(t.ramp_point()) < 6.0:
					t.toggle_ramps()
					net.toast(peer, _ramps_message(t))
		"reset":
			var v := vehicle_by_id(int(arg))
			if v:
				_right_vehicle(v, peer)
		"buy":
			var item := career.find(String(arg))
			if not item.is_empty() and career.buy(String(arg)):
				net.toast_all("UNLOCKED  ·  " + String(item.name).to_upper() + by, Hud.GOOD)
				for m in machines:
					if m is Excavator:
						m.allowed_attachments = career.allowed_attachments()
		"deliver":
			var kind := String(arg)
			var item: Dictionary = {}
			for m in Career.MACHINES:
				if m.kind == kind:
					item = m
			if item.is_empty() or not career.is_owned(String(item.id)):
				return
			var node := spawn_vehicle(kind)
			if node == null:
				net.toast(peer, "No free bay at the depot — move a machine out of the bays first" if fleet_size() < Career.MAX_FLEET
						else "Fleet is full (%d) — return a machine first" % Career.MAX_FLEET, Hud.BAD)
			else:
				net.toast_all("%s delivered to bay %d%s" % [String(node.machine_name).to_upper(), int(node.get_meta("bay")), by], Hud.GOOD)
		"take_job":
			var job := jobs.accept(int(arg))
			if not job.is_empty():
				net.toast_all("JOB STARTED  ·  " + String(job.title).to_upper() + by, Hud.ACCENT)
				net.send_jobs()
		"abandon_job":
			if not jobs.active.is_empty():
				jobs.abandon()
				net.toast_all("Job abandoned" + by, Hud.MUTED)
				net.send_jobs()
		"tie":
			var a: Node3D = node_by_net_id(String(arg[1]))
			var b: Node3D = node_by_net_id(String(arg[2]))
			var who_at: Vector3 = net._puppets[peer].global_position if net._puppets.has(peer) else arg[3]
			if a and b and who_at.distance_to(arg[3]) < 10.0 and who_at.distance_to(arg[4]) < 10.0:
				net.toast(peer, ties.tie(String(arg[0]), a, arg[3], b, arg[4]))
		"cut_tie":
			if ties.cut(int(arg)):
				net.toast(peer, "Cut")
		"supply":
			for item in Career.SUPPLIES:
				if item.id == String(arg) and career.spend(int(item.price), String(item.name)):
					var pad := ZONE + SUPPLY_PAD
					spawn_mats(Vector3(pad.x, terrain.get_height(pad.x, pad.y) + 0.3, pad.y), 4)
					net.toast_all(String(item.name).to_upper() + " delivered to the depot (by the material bays)" + by, Hud.GOOD)
		"return":
			var v := vehicle_by_id(int(arg))
			if v and not v.get("broken"):
				var driver := net.driver_of(int(arg))
				if (driver != 0 and driver != peer) or (v == _driving and peer != 1):
					net.toast(peer, "Someone's driving that one", Hud.BAD)
					return
				net.toast_all(String(v.machine_name) + " returned to the dealer" + by, Hud.MUTED)
				despawn(v)


## Host: let a remote player climb into a machine.
func remote_enter(peer: int, v: Node3D) -> void:
	var id := int(v.get_meta("net_id"))
	if net.driver_of(id) != 0 or v == _driving:
		net.toast(peer, "Someone's already driving the " + String(v.machine_name).to_lower(), Hud.BAD)
		return
	remote_exit(peer)
	v.driven = true
	v.remote = true
	v.remote_axes = {}
	_winch_states[peer] = {}
	net.set_driver(peer, id)
	if v.get("broken"):
		net.toast(peer, "The engine's dead — it needs towing or winching back to the depot", Hud.BAD)


## Host: a remote player gets out (or left the game).
func remote_exit(peer: int) -> void:
	if not net.players.has(peer):
		return
	var v := vehicle_by_id(int(net.players[peer].driving))
	if v:
		v.driven = false
		v.remote = false
		v.remote_axes = {}
		if v.get("winch"):
			v.winch.reel(false)
	_winch_states.erase(peer)
	net.set_driver(peer, -1)


## Host: a remote driver's controls (sent ~30 times a second).
func remote_input(peer: int, axes: Dictionary, winch_held: bool) -> void:
	if not net.players.has(peer):
		return
	var v := vehicle_by_id(int(net.players[peer].driving))
	if v == null or not v.remote:
		return
	v.remote_axes = axes
	_winch_control(v, winch_held, _winch_states.get(peer, {}), peer)


## Joining player: the host put us in the driver's seat.
func client_enter(v: Node3D) -> void:
	_driving = v
	remote_hud = {}
	_seat_player(v)


func client_exit() -> void:
	if _driving:
		_unseat_player(_driving)
	_driving = null


# --- Economy ------------------------------------------------------------------------------

## Boulders lying about the map (the same on every machine): mostly plain rock, some
## flecked with whatever ore lies under them, a hint of where to dig.
func _scatter_boulders() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9917
	var placed := 0
	var tries := 0
	while placed < BOULDERS and tries < 600:
		tries += 1
		var p := Vector2(rng.randf_range(-470, 470), rng.randf_range(-470, 470))
		if water.depth_at(p.x, p.y) > 0.0 or terrain.is_protected(p.x, p.y) or terrain.info_at(p.x, p.y).y > 0.3:
			continue
		if absf(p.x - ZONE.x) < 70.0 and absf(p.y - ZONE.y) < 60.0:
			continue
		var rich: Dictionary = Ores.richness(self, p, 2.5)
		var kind := "rock"
		var best := 0.0
		for k in rich:
			if float(rich[k]) > best:
				best = rich[k]
				kind = k
		if kind != "rock" and rng.randf() > best * 6.0:
			kind = "rock"
		var at := Vector3(p.x, terrain.sample_height(p.x, p.y) + float(Ores.KINDS[kind].size) * 0.6, p.y)
		var boulder := Ores.make_chunk(self, kind, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), at))
		if kind == "rock":
			boulder.mass *= 3.0
		debris.append(boulder)
		placed += 1


## Digging (host): every so much soil dug out of a patch below the topsoil is a chance of
## turning up a chunk of ore there.
func _on_soil_removed(_at: Vector3, _volume: float, _depth: float) -> void:
	pass  # (ore is part of the soil now: see ores.gd)


## Clears loose clutter off the whole map to keep the frame rate up: pulled stumps, ore
## chunks and boulders lying about. Anything strapped, tied, in a grapple or riding in a
## machine stays. (Host or solo; joining players are told what went.) Returns how many.
func clean_up_site() -> int:
	if net.is_client():
		return 0
	var gone := []
	var stumps := 0
	var rocks := 0
	for id in bodies.keys():
		var b = bodies[id]
		if not is_instance_valid(b) or not b.is_inside_tree() or b.get_parent() != self:
			continue  # (a grapple holding it reparents it)
		var stump: bool = b.get_meta("label", "") == "stump"
		var rock: bool = b.is_in_group("ore") and not b.has_meta("bar")
		if not (stump or rock) or b.has_meta("strapped_to") or b.has_meta("tie_locked"):
			continue
		ties.release(b)
		gone.append(int(id))
		if stump:
			stumps += 1
		else:
			rocks += 1
		b.queue_free()
	net.send_removed(gone)
	net.toast_all("SITE CLEANED UP  ·  removed %d stumps and %d rocks" % [stumps, rocks], Hud.GOOD)
	return gone.size()


## A dozer's grinder (a stump grinder): stumps within `reach` of `at` are ground up and
## paid for at once: stumps left standing after felling, and loose stumps (not strapped,
## tied or held). Standing trees and logs are left alone. Host only.
func grind_at(at: Vector3, reach: float, by: Node3D) -> void:
	if net.is_client():
		return
	var p := Vector2(at.x, at.z)
	var value := 0
	var count := 0
	var gone := []
	for c in forests._cells_around(p, reach):
		for tid in forests.cells[c]:
			if forests.state[tid] != 1:
				continue  # only felled trees' stumps
			var tp: Vector3 = forests.pos[tid]
			if Vector2(tp.x, tp.z).distance_to(p) > reach or absf(tp.y - at.y) > 3.0:
				continue
			# Fell it and pull the stump through the normal events (so joining players and
			# the world save agree), then grind the pieces.
			var wood := [forests.apply_event(tid, "pulled", self)]
			for b in wood:
				if is_instance_valid(b):
					value += int(b.get_meta("value", 150))
					if b.has_meta("body_id"):
						gone.append(int(b.get_meta("body_id")))
					b.queue_free()
			count += 1
	for id in bodies.keys():
		var b = bodies[id]
		if not is_instance_valid(b) or b.get_meta("label", "") != "stump" or b.get_parent() != self or b.is_queued_for_deletion():
			continue
		if b.has_meta("strapped_to") or b.has_meta("tie_locked") or b.has_meta("shredding"):
			continue
		var q: Vector3 = b.global_position
		if Vector2(q.x, q.z).distance_to(p) > reach + 0.8 or absf(q.y - at.y) > 2.5:
			continue
		ties.release(b)
		value += int(b.get_meta("value", 150))
		gone.append(int(id))
		b.queue_free()
		count += 1
	if count == 0:
		return
	net.send_removed(gone)
	career.earn(value, "Ground up %d stump%s" % [count, "" if count == 1 else "s"])


## Joining player: the host cleared these away.
func net_remove_bodies(ids: Array) -> void:
	for id in ids:
		var b = bodies.get(int(id))
		if is_instance_valid(b):
			b.queue_free()


func spawn_ore(kind: String, xform: Transform3D) -> RigidBody3D:
	var id := next_body_id
	next_body_id += 1
	var chunk := Ores.make_chunk(self, kind, xform)
	if net.is_client():
		chunk.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		chunk.freeze = true
	_register_body(chunk, id)
	net.send_ore(id, kind, xform)
	return chunk


func _on_shredded(value: int, label: String, _at: Vector3) -> void:
	var reason := "Shredded " + label
	if label.ends_with("bar"):
		reason = "Sold a " + label
	elif label == "ore":
		reason = "Crushed ore"
	elif label in Ores.KINDS.values().map(func(k): return k.name):
		reason = "Crushed " + label
	career.earn(value, reason)
	if label.ends_with("log"):
		career.stats.logs = int(career.stats.logs) + 1
		jobs.notify("logs")


func _on_job_completed(job: Dictionary) -> void:
	career.stats.jobs = int(career.stats.jobs) + 1
	career.earn(int(job.reward), "Job: " + String(job.title))
	net.toast_all("JOB COMPLETE  ·  " + String(job.title).to_upper(), Hud.GOOD)


# --- Per frame ----------------------------------------------------------------------------

func _build_forests(rng: RandomNumberGenerator) -> void:
	forests = Forests.new()
	forests.name = "Forests"
	forests.remote = _joining
	add_child(forests)
	forests.snow = SNOWFIELD
	forests.setup(terrain)
	var clear_of_sites := func(p: Vector2) -> bool:
		if terrain.is_protected(p.x, p.y):
			return true
		if absf(p.x - ZONE.x) < Scenery.ZONE_HALF.x + 4.0 and absf(p.y - ZONE.y) < Scenery.ZONE_HALF.y + 4.0:
			return true
		for s in SHREDDERS:
			if p.distance_to(s[0]) < 16.0:
				return true
		return p.distance_to(BORROW_MOUND) < 17.0 or p.distance_to(DEMOLITION) < 32.0 or p.distance_to(FARM) < 16.0 \
				or p.distance_to(QUARRY) < 46.0
	var dry := func(p: Vector2) -> bool:
		return water.depth_at(p.x, p.y) > 0.0 or terrain.info_at(p.x, p.y).y > 0.25 or clear_of_sites.call(p) 				or Vector2(ICE_POND.x, ICE_POND.y).distance_to(p) < ICE_POND.z + 3.0
	# Swamp trees stand in mud and shallow water.
	var swampy := func(p: Vector2) -> bool:
		return water.depth_at(p.x, p.y) > 0.35 or clear_of_sites.call(p)
	for f in FORESTS:
		forests.add_forest(f[0], f[1], f[2], f[3], rng, swampy if f[4] else dry)
	forests.finish()
	forests.body_spawned.connect(_on_tree_body)
	forests.felled.connect(func(_tid: int) -> void: trees_felled += 1)
	forests.stump_freed.connect(func(_tid: int) -> void:
		if _restoring:
			return
		stumps_cleared += 1
		career.stats.stumps = int(career.stats.stumps) + 1
		if jobs:
			jobs.notify("stumps"))


## Collision and live trees go where they're needed: players, machines, loose bodies.
func _update_anchors() -> void:
	var ground := [[player.global_position, 40.0]]
	var live := [focus_node().global_position]
	for v in machines + trailers:
		if is_instance_valid(v):
			ground.append([v.global_position, 28.0])
			# And where it'll be in a moment, if it's moving fast.
			var vel: Vector3 = v.linear_velocity if v is RigidBody3D else v.get("velocity") if v.get("velocity") != null else Vector3.ZERO
			if vel.length() > 4.0:
				ground.append([v.global_position + vel * 1.5, 24.0])
			if v.get("driven"):
				live.append(v.global_position)
	for id in bodies:
		var b = bodies[id]
		if is_instance_valid(b):
			ground.append([b.global_position, 10.0])
	for p in net._puppets.values():
		if is_instance_valid(p):
			ground.append([p.global_position, 40.0])
			live.append(p.global_position)
	terrain.set_anchors(ground)
	forests.anchors = live
	_hold_until_grounded()


## Loose bodies wait in the air until the ground under them has collision (it's built
## a few tiles a frame), and anything that still slips under the ground is put back on top.
func _hold_until_grounded() -> void:
	if net.is_client():
		return
	for v in bodies.values() + machines + trailers:
		if not (v is RigidBody3D) or not is_instance_valid(v):
			continue
		var b: RigidBody3D = v
		var p := b.global_position
		var waiting := b.has_meta("awaiting_ground")
		if not terrain.has_collision_at(p.x, p.z):
			if not waiting and not b.freeze:
				b.set_meta("awaiting_ground", b.freeze_mode)
				b.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				b.freeze = true
			continue
		if waiting:
			b.freeze_mode = b.get_meta("awaiting_ground")
			b.remove_meta("awaiting_ground")
			b.freeze = false
		if b.freeze:
			continue
		if bodies.has(b.get_meta("body_id", -1)) or b in debris:
			_unbury(b)
		else:
			# Machines sink into mud and ruts by design, so only catch a real fall-through.
			var p2 := b.global_position
			var ground := terrain.sample_height(p2.x, p2.z)
			if p2.y < ground - 2.5:
				b.global_position = Vector3(p2.x, ground + 1.5, p2.z)
				b.linear_velocity = Vector3.ZERO
				b.angular_velocity = Vector3.ZERO


## The ground's collision only pushes things up from above, so anything that ends up
## under the surface (soil dumped or dozed over a resting log, a tree felled where spoil
## was piled round its foot) would drop straight through. Lifts it back on top.
## Checked along a log's whole length, not just at its base.
func _unbury(b: RigidBody3D) -> void:
	var points: Array[Vector3] = []
	var clearance := 0.2
	if b.has_meta("grip"):
		var g: Array = b.get_meta("grip")
		var a := b.to_global(g[0])
		var c := b.to_global(g[1])
		points = [a, a.lerp(c, 0.5), c]
	else:
		points = [b.global_position]
		clearance = -0.2  # blocks and mats: their middle may sit a little low on a slope
	var lift := 0.0
	var buried := false
	for p in points:
		var ground := terrain.sample_height(p.x, p.z)
		if p.y < ground - 0.05:
			buried = true
		lift = maxf(lift, ground + clearance - p.y)
	if buried and lift > 0.0:
		b.global_position += Vector3(0, lift + 0.15, 0)
		b.linear_velocity = Vector3(b.linear_velocity.x, maxf(b.linear_velocity.y, 0.0), b.linear_velocity.z)
		b.sleeping = false


## Keeps the world save fresh (your own game only) and writes it on the way out.
func save_world() -> void:
	# (--no-save: tests that load your world but must never write it.)
	if career.persistent and not net.is_client() and not "--no-save" in OS.get_cmdline_user_args():
		WorldSave.save(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_world()


func _unhandled_input(event: InputEvent) -> void:
	if menu == null or menu.is_open:
		return
	if event.is_action_pressed("menu"):
		menu.open_depot()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause"):
		menu.open_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("map_zoom"):
		hud.minimap.toggle_zoom()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_help"):
		menu.open_controls()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_update_snowfall()
	_autosave_timer -= delta
	if _autosave_timer <= 0.0:
		_autosave_timer = AUTOSAVE_INTERVAL
		save_world()
	if not _driving and player.active and menu and not menu.is_open:
		_handle_ties()
	elif not _tie_pending.is_empty():
		_cancel_tie()
	if Input.is_action_just_pressed("restart") and not net.is_online():
		save_world()
		get_tree().reload_current_scene()
		return
	if Input.is_action_just_pressed("reset_vehicle") and _driving:
		_request(1, "reset", int(_driving.get_meta("net_id", -1)))
	var nearest: Node3D = null
	var at_ramps: Node3D = null
	if not _driving:
		var best := ENTER_DISTANCE
		for m in machines:
			var d := player.global_position.distance_to(m.door_position())
			if d < best:
				best = d
				nearest = m
		# On foot at the back of a trailer: work its ramps.
		var ramp_best := 3.0 if nearest == null else minf(3.0, best)
		for t in trailers + machines.filter(func(m): return m.get("variant") == "logs"):
			var d: float = player.global_position.distance_to(t.ramp_point())
			if d < ramp_best:
				ramp_best = d
				at_ramps = t
	if Input.is_action_just_pressed("interact"):
		if _driving:
			_leave_machine()
		elif at_ramps:
			if net.is_client():
				net.request("ramps", int(at_ramps.get_meta("net_id")))
			else:
				at_ramps.toggle_ramps()
				hud.toast(_ramps_message(at_ramps))
		elif nearest:
			if net.is_client():
				net.request("enter", int(nearest.get_meta("net_id")))
			elif net.driver_of(int(nearest.get_meta("net_id"))) > 1:
				hud.toast("Someone's already driving the " + String(nearest.machine_name).to_lower(), Hud.BAD)
			else:
				_enter_machine(nearest)
	var driver_name := ""
	if nearest and net.is_online():
		var driver := net.driver_of(int(nearest.get_meta("net_id")))
		if driver != 0 and net.players.has(driver):
			driver_name = String(net.players[driver].name)
	if _driving:
		if not net.is_client():
			_winch_control(_driving, Input.is_action_pressed("winch"), _winch_states.get(1, {}), 1)
		if Input.is_action_just_pressed("utility"):
			_press_utility()
		if not net.is_client():
			player.set_controls(_driving.controls())
		player.set_body_visible(not camera.cab_view)
		hud.set_machine(_driving.machine_name, remote_hud if net.is_client() else _driving.hud_info())
		hud.set_prompt("", "")
	elif at_ramps:
		if at_ramps.variant == "logs":
			hud.set_prompt("interact", "STRAP THE LOAD DOWN" if at_ramps.ramps_down else "RELEASE THE STRAPS")
		else:
			hud.set_prompt("interact", "RAISE THE RAMPS" if at_ramps.ramps_down else "LOWER THE RAMPS")
	elif nearest and driver_name != "":
		hud.set_prompt("", String(driver_name).to_upper() + " IS DRIVING THE " + String(nearest.machine_name).to_upper())
	elif nearest:
		hud.set_prompt("interact", ("DRIVE THE " if not nearest.get("broken") else "CLIMB INTO THE ") + String(nearest.machine_name).to_upper())
	else:
		hud.set_prompt("", _wood_here())
	var target := jobs.target()
	var from := focus_node().global_position
	hud.set_job(jobs.active, Vector2(target.x, target.z).distance_to(Vector2(from.x, from.z)) if target != Vector3.INF else INF)
	_rumble()


## On foot next to a tree, log or stump: what it is, how big (in studs) and what it's worth.
func _wood_here() -> String:
	_wood_timer -= get_process_delta_time()
	if _wood_timer > 0.0:
		return _wood_text
	_wood_timer = 0.25
	_wood_text = ""
	var p := player.global_position
	var best_d := 3.0
	for id in bodies:
		var b = bodies[id]
		if is_instance_valid(b) and b.is_in_group("shreddable") and b.is_inside_tree():
			var d: float = b.global_position.distance_to(p)
			if b.has_meta("grip"):
				var g: Array = b.get_meta("grip")
				var mid: Vector3 = b.to_global(((g[0] as Vector3) + (g[1] as Vector3)) * 0.5)
				d = minf(d, mid.distance_to(p))
			if d < best_d:
				best_d = d
				var kind := String(b.get_meta("species", ""))
				var what := String(b.get_meta("label", "wood"))
				var length := "  ·  %d studs long" % int(b.get_meta("studs")) if b.has_meta("studs") else ""
				if kind != "":
					what = kind + (" log" if what.ends_with("log") else " " + what)
				_wood_text = "%s%s  ·  worth $%d" % [what.to_upper(), length, int(b.get_meta("value", 0))]
	if _wood_text == "":
		var tid := forests.nearest_tree(p, 3.5)
		if tid >= 0:
			_wood_text = forests.describe(tid)
	return _wood_text


## Winch button for one driver: tap to hook the nearest thing, hold to reel in, tap again
## to unhook. `state` remembers the button between frames for that driver.
func _winch_control(machine: Node3D, held_now: bool, state: Dictionary, peer: int) -> void:
	var winch = machine.get("winch")
	if winch == null:
		return
	var was_held: bool = state.get("held", false)
	var now := Time.get_ticks_msec() / 1000.0
	if held_now and not was_held:
		state.down_at = now
		state.was_attached = winch.is_attached()
		if not state.was_attached:
			var hooked: String = winch.attach(winch.global_position - machine.global_position)
			net.toast(peer, "Winch hooked to the %s — hold %s to reel in" % [hooked, hud.key("winch")] if hooked != "" else "Nothing in winch range (%.0f m)" % winch.reach)
	var held_for: float = now - float(state.get("down_at", now))
	var reeling: bool = held_now and state.get("was_attached", false) and held_for > 0.25
	if reeling != state.get("reeling", false):
		winch.reel(reeling)
		state.reeling = reeling
	if was_held and not held_now and state.get("was_attached", false) and held_for <= 0.25:
		winch.detach()
		net.toast(peer, "Winch released")
	state.held = held_now
	_winch_states[peer] = state


func _press_utility() -> void:
	if not _driving:
		return
	if net.is_client():
		net.request("utility")
	else:
		_use_utility(_driving, 1)


## Tool / hitch button: excavators swap attachments, trucks hitch or drop a trailer.
func _use_utility(machine: Node3D, peer: int) -> void:
	if machine is Excavator:
		net.toast(peer, "Attachment: " + machine.cycle_attachment())
	elif machine is Roller:
		net.toast(peer, machine.toggle_levelling())
	elif machine is Bulldozer:
		net.toast(peer, machine.toggle_grinder())
	elif machine is Truck:
		var t: Truck = machine
		# The end of the train: the truck itself, or the last trailer behind it.
		var last: Node3D = t
		var count := 0
		if t.trailer:
			last = t.trailer
			count = 1
			while is_instance_valid(last.rear):
				last = last.rear
				count += 1
		var hook: Vector3 = t.hitch_point() if last == t else last.rear_hitch_point()
		var best: Node3D = null
		var best_d := INF
		for tr in trailers:
			if tr.towed_by == null and tr != last and tr != t.trailer:
				var d: float = tr.hitch_point().distance_to(hook)
				if d < best_d:
					best_d = d
					best = tr
		if best and best_d < 3.5:
			best.hitch(last, hook)
			if last == t:
				t.trailer = best
			else:
				last.rear = best
			net.toast(peer, "Trailer hitched" if count == 0 else "Trailer %d hitched on behind" % (count + 1))
			return
		if t.trailer:
			# Nothing to add: drop the last trailer in the train.
			var before: Node3D = t if last == t.trailer else last.towed_by
			last.unhitch()
			if before == t:
				t.trailer = null
			else:
				before.rear = null
			net.toast(peer, "Trailer unhitched" if count == 1 else "Last trailer unhitched (%d left)" % (count - 1))
			return
		if best:
			net.toast(peer, "Back the hitch up to the trailer's drawbar (%.0f m away)" % best_d)
		else:
			net.toast(peer, "No trailer nearby")


func _ramps_message(t: Node3D) -> String:
	if t.variant == "logs":
		return "Load released" if t.ramps_down else "Load strapped down"
	return "Lowering the ramps" if t.ramps_down else "Raising the ramps"


## Controller vibration follows what the machine is doing (digging, pushing, stuck).
func _rumble() -> void:
	var strength: Vector2 = _driving.rumble() if _driving and not net.is_client() else Vector2.ZERO
	for device in Input.get_connected_joypads():
		if strength.length() > 0.01:
			Input.start_joy_vibration(device, clampf(strength.x, 0, 1), clampf(strength.y, 0, 1), 0.15)
		else:
			Input.stop_joy_vibration(device)


func _physics_process(delta: float) -> void:
	_settle_bodies_on_changed_ground()
	_anchor_timer -= delta
	if _anchor_timer <= 0.0:
		_anchor_timer = 0.25
		_update_anchors()
	if _autotest:
		_run_autotest(delta)


func _enter_machine(machine: Node3D) -> void:
	_driving = machine
	machine.driven = true
	_seat_player(machine)
	if net.is_host():
		net.set_driver(1, int(machine.get_meta("net_id")))
	if machine.get("broken"):
		hud.toast("The engine's dead — it needs towing or winching back to the depot", Hud.BAD)


func _seat_player(machine: Node3D) -> void:
	player.set_active(false)
	player.sit(machine.seat)
	var view := 16.0
	if machine is Excavator:
		view = 19.0 * machine.size_scale / 1.4
	elif machine is Bulldozer:
		view = 18.0
	elif machine.get("kind") == "pickup":
		view = 10.0
	camera.set_target(machine.cab, true, view)
	hud.set_utility(_utility_label(machine))
	camera.eye = machine.eye
	camera.mouse_orbit = false
	mouse.enabled = true
	hud.set_mode(true)


func _utility_label(machine: Node3D) -> String:
	if machine is Excavator:
		return "Swap tool"
	if machine is Truck:
		return "Hitch"
	if machine is Roller:
		return "Levelling on/off"
	if machine is Bulldozer:
		return "Grinder on/off"
	return ""


## Climb out (a joining player asks the host).
func _leave_machine() -> void:
	if net.is_client():
		net.request("exit")
	else:
		_exit_machine()


func _exit_machine() -> void:
	if not _driving:
		return
	var machine := _driving
	if machine.get("winch"):
		machine.winch.reel(false)
	_driving = null
	machine.driven = false
	_winch_states.erase(1)
	_unseat_player(machine)
	if net.is_host():
		net.set_driver(1, -1)


func _unseat_player(machine: Node3D) -> void:
	mouse.enabled = false
	if camera.cab_view:
		camera.toggle_cab_view()
	camera.eye = null
	camera.mouse_orbit = true
	player.stand()
	var p: Vector3 = machine.door_position()
	player.global_position = Vector3(p.x, terrain.get_height(p.x, p.z) + 0.1, p.z)
	player.reset_physics_interpolation()
	player.set_active(true)
	camera.set_target(player, false, 7.0)
	hud.set_mode(false)


func _nearest_index(path: PackedVector2Array, p: Vector2) -> int:
	var best := 0
	for k in path.size():
		if path[k].distance_to(p) < path[best].distance_to(p):
			best = k
	return best


## Average ground height around a basin.
func _rim_average(center: Vector2, radius: float) -> float:
	var total := 0.0
	for k in 72:
		var p := center + Vector2.from_angle(TAU * k / 72.0) * radius
		total += terrain.get_height(p.x, p.y)
	return total / 72.0


func _add_demolition_site(site_name: String, center: Vector2, blocks: Array[RigidBody3D]) -> void:
	var starts: Array[Vector3] = []
	for body in blocks:
		starts.append(body.position)
		body.add_to_group("winchable")
		body.set_meta("label", "rubble")
	debris.append_array(blocks)
	demolition_sites.append({"name": site_name, "center": center, "blocks": blocks, "starts": starts})


## Terrain changed: wake sleeping blocks so they fall into holes, and check whether any
## stumps have been dug free (the host decides that for everyone).
## On foot: strap (G) or rope (R) the nearest thing, then press again at what to tie it
## to; cut (X) the strap or rope you're standing by.
func _handle_ties() -> void:
	var hands := player.global_position + Vector3(0, 1.1, 0)
	if Input.is_action_just_pressed("cut_tie"):
		var id: int = ties.tie_near(hands, TIE_REACH)
		if id < 0:
			hud.toast("No strap or rope within reach", Hud.MUTED)
		elif net.is_client():
			net.request("cut_tie", id)
		else:
			ties.cut(id)
			hud.toast("Cut", Hud.GOOD)
	for kind in [Ties.STRAP, Ties.ROPE]:
		if not Input.is_action_just_pressed(kind):
			continue
		var target := _tie_target(hands, _tie_pending.get("node") if _tie_pending.get("kind", "") == kind else null)
		if target.is_empty() and not _tie_pending.is_empty() and _tie_pending.kind == kind:
			_cancel_tie()
			hud.toast("Put away", Hud.MUTED)
			continue
		if target.is_empty():
			hud.toast("Nothing within reach to tie", Hud.MUTED)
			continue
		if _tie_pending.is_empty() or _tie_pending.kind != kind:
			_tie_pending = {"kind": kind, "node": target.node, "local": (target.node as Node3D).to_local(target.point)}
			hud.toast("%s hooked to the %s: now press %s at what to tie it to" % ["Strap" if kind == Ties.STRAP else "Rope",
				ties._name(target.node), hud.key(kind)], Hud.ACCENT)
			continue
		var first: Node3D = _tie_pending.node
		if not is_instance_valid(first) or first == target.node:
			_cancel_tie()
			hud.toast("Put away", Hud.MUTED)
			continue
		var pa := first.to_global(_tie_pending.local)
		if net.is_client():
			net.request("tie", [kind, net_id_of(first), net_id_of(target.node), pa, target.point])
		else:
			hud.toast(ties.tie(kind, first, pa, target.node, target.point), Hud.GOOD)
		_cancel_tie()
	if not _tie_pending.is_empty():
		var first: Node3D = _tie_pending.node
		if not is_instance_valid(first) or first.to_global(_tie_pending.local).distance_to(hands) > 40.0:
			_cancel_tie()
			return
		if _tie_line == null:
			_tie_line = MeshInstance3D.new()
			var line := CylinderMesh.new()
			line.top_radius = 0.02
			line.bottom_radius = 0.02
			line.height = 1.0
			line.radial_segments = 6
			_tie_line.mesh = line
			_tie_line.material_override = ties._strap_material if _tie_pending.kind == Ties.STRAP else ties._rope_material
			add_child(_tie_line)
		ties._stretch(_tie_line, first.to_global(_tie_pending.local), hands, false, 0.0)


func _cancel_tie() -> void:
	_tie_pending = {}
	if _tie_line:
		_tie_line.queue_free()
		_tie_line = null


## The nearest thing in reach that can be tied, and the point on it: loose logs, stumps,
## mats and rubble, any machine, truck or trailer, or a standing tree.
func _tie_target(hands: Vector3, exclude: Node3D = null) -> Dictionary:
	var best := {}
	var best_d := TIE_REACH
	var candidates: Array = machines + trailers
	for id in bodies:
		var b = bodies[id]
		if is_instance_valid(b) and b.global_position.distance_to(hands) < 14.0:
			candidates.append(b)
	for tid in forests.live:
		var tree: Node3D = forests.live[tid]
		if is_instance_valid(tree) and tree.global_position.distance_to(hands) < 6.0:
			candidates.append(tree)
	for node in candidates:
		var n := node as Node3D
		if n == null or n == exclude or not n.is_inside_tree():
			continue
		var point: Vector3
		if n.has_meta("grip"):
			var g: Array = n.get_meta("grip")
			point = Geometry3D.get_closest_point_to_segment(hands, n.to_global(g[0]), n.to_global(g[1]))
		elif n.is_in_group("trees"):
			point = n.global_position + Vector3(0, 1.1, 0)
		elif n in bodies.values():
			point = n.global_position
		else:
			# A vehicle: the nearest point on a rough box round it.
			var local := n.to_local(hands)
			local = Vector3(clampf(local.x, -1.3, 1.3), clampf(local.y, 0.6, 2.2), clampf(local.z, -4.5, 4.5))
			point = n.to_global(local)
		var d := point.distance_to(hands)
		# Loose things (the log on the truck) win over the vehicle they're lying on.
		var score := d * (0.6 if n in bodies.values() else 1.0)
		if d < TIE_REACH and score < best_d:
			best_d = score
			best = {"node": n, "point": point}
	return best


## Light snow falls around the camera while it's in the snowy pine forest.
func _update_snowfall() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var p := camera.global_position
	var inside := Vector2(p.x, p.z).distance_to(Vector2(SNOWFIELD.x, SNOWFIELD.y)) < SNOWFIELD.z
	if _snowfall == null:
		if not inside:
			return
		_snowfall = GPUParticles3D.new()
		_snowfall.amount = 700
		_snowfall.lifetime = 6.0
		_snowfall.preprocess = 6.0
		_snowfall.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 45, 60))
		_snowfall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		process.emission_box_extents = Vector3(28, 1, 28)
		process.direction = Vector3.DOWN
		process.spread = 12.0
		process.initial_velocity_min = 1.0
		process.initial_velocity_max = 2.0
		process.gravity = Vector3(0.3, -0.6, 0.15)
		process.turbulence_enabled = true
		process.turbulence_noise_strength = 0.6
		process.scale_min = 0.6
		process.scale_max = 1.2
		_snowfall.process_material = process
		var flake := QuadMesh.new()
		flake.size = Vector2(0.06, 0.06)
		var mat := StandardMaterial3D.new()
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1, 1, 1, 0.9)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		flake.material = mat
		_snowfall.draw_pass_1 = flake
		add_child(_snowfall)
	_snowfall.global_position = p + Vector3(0, 14, 0)
	_snowfall.emitting = inside


func _on_terrain_changed(rect: Rect2) -> void:
	if net and net.is_client():
		return
	# Collected and handled once a frame: one pass over the loose bodies however many
	# patches of ground changed (many at once when soil settles at several sites).
	_changed_areas.append(rect)


## Wakes and unburies loose bodies (rubble, logs, stumps, mats) on ground that changed, so
## they drop into holes dug under them and come up on top of soil dumped over them, and
## frees stumps whose roots have been dug out.
func _settle_bodies_on_changed_ground() -> void:
	if _changed_areas.is_empty():
		return
	const GRID_M := 8.0
	var hit := {}
	for rect in _changed_areas:
		# A log reaches up to ~9 m from its base, so take in the bodies around too.
		var area: Rect2 = rect.grow(6.5)
		for gz in range(floori(area.position.y / GRID_M), floori(area.end.y / GRID_M) + 1):
			for gx in range(floori(area.position.x / GRID_M), floori(area.end.x / GRID_M) + 1):
				hit[Vector2i(gx, gz)] = true
	_changed_areas.clear()
	for id in bodies:
		var b = bodies[id]
		if not is_instance_valid(b) or b.freeze:
			continue
		var p: Vector3 = b.global_position
		if hit.has(Vector2i(floori(p.x / GRID_M), floori(p.z / GRID_M))):
			b.sleeping = false
			_unbury(b)
	for tid in forests.live:
		var tree: Node3D = forests.live[tid]
		if is_instance_valid(tree) and tree.is_stump:
			var p := tree.global_position
			if hit.has(Vector2i(floori(p.x / GRID_M), floori(p.z / GRID_M))):
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
	env.fog_density = 0.0024
	environment = env
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
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
	var far := 1600.0
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
