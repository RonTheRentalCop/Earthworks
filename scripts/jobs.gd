extends Node3D
## Contracts on the job board. Three offers at a time; take one and it's marked out in
## the world with posts, tape and a light beam, and tracked on the HUD until it's done.
##   dig      - dig a foundation pit to depth
##   fill     - dump a volume of soil on a fill site
##   level    - spread spoil heaps and grade a pad flat
##   clear    - shred logs at a shredder
##   stumps   - pull out stumps
##   demolish - knock down a building at the demolition yard
##   recover  - bring a broken-down truck back to the depot (it has no engine)

signal completed(job: Dictionary)
signal offers_changed

const Terrain = preload("res://scripts/terrain.gd")
const Scenery = preload("res://scripts/scenery.gd")
const Kit = preload("res://scripts/model_kit.gd")

const OFFER_COUNT := 3
const UPDATE_INTERVAL := 0.5
const DONE_AT := 0.97  # progress counted as finished (it never needs to be pixel perfect)
const TYPES := ["dig", "fill", "level", "clear", "stumps", "demolish", "recover", "gravel"]

var main: Node3D
var terrain: Terrain
var offers: Array = []
var active := {}
var sites: Array[Vector2] = []
## Multiplayer: on joining players' machines the board mirrors the host's.
var remote := false

var _rng := RandomNumberGenerator.new()
var _marker: Node3D
var _beam: MeshInstance3D
var _sign: Label3D
var _timer := 0.0
var _counters := {"logs": 0, "stumps": 0}
var _next_id := 1


func setup(main_node: Node3D) -> void:
	main = main_node
	terrain = main.terrain
	_rng.seed = Time.get_ticks_usec()
	_find_sites()
	if not remote:
		_refill()


## Lets main report events the jobs count (shredded logs, freed stumps).
func notify(event: String) -> void:
	_counters[event] = int(_counters.get(event, 0)) + 1


func accept(index: int) -> Dictionary:
	if not active.is_empty() or index < 0 or index >= offers.size():
		return {}
	active = offers[index]
	offers.remove_at(index)
	_start(active)
	_refill()
	return active


func abandon() -> void:
	if active.is_empty():
		return
	if active.type == "recover" and is_instance_valid(active.get("vehicle")):
		main.despawn(active.vehicle)
	active = {}
	_clear_marker()
	offers_changed.emit()


## World point the HUD waypoint should point at.
func target() -> Vector3:
	if active.is_empty():
		return Vector3.INF
	match String(active.type):
		"recover":
			var v: Node3D = active.get("vehicle")
			if v == null and active.has("vehicle_id"):
				v = main.vehicle_by_id(int(active.vehicle_id))
			if is_instance_valid(v):
				if _in_depot(v.global_position):
					return Vector3.INF
				return v.global_position
		"clear":
			return main.nearest_shredder(main.player.global_position).infeed_point()
		"stumps":
			return main.forests.nearest_stump(main.focus_node().global_position)
	return Vector3(active.pos.x, terrain.get_height(active.pos.x, active.pos.y), active.pos.y)


## The board for the network: plain data only (no node references).
func net_state() -> Array:
	var clean := func(job: Dictionary) -> Dictionary:
		var out := {}
		for key in job:
			if job[key] is Object:
				if key == "vehicle" and is_instance_valid(job[key]):
					out["vehicle_id"] = int(job[key].get_meta("net_id", -1))
				continue
			out[key] = job[key]
		return out
	var list := []
	for o in offers:
		list.append(clean.call(o))
	return [list, clean.call(active) if not active.is_empty() else {}]


## Joining players: show the host's board and marker.
func apply_net_state(s: Array) -> void:
	offers = s[0]
	var incoming: Dictionary = s[1]
	var changed: bool = incoming.get("id", -1) != active.get("id", -2)
	active = incoming
	if active.is_empty():
		_clear_marker()
	elif changed:
		_build_marker(active)
	else:
		_update_marker()
	offers_changed.emit()


func _process(delta: float) -> void:
	if active.is_empty() or remote:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = UPDATE_INTERVAL
	active.progress = clampf(_measure(active), 0.0, 1.0)
	_update_marker()
	if active.progress >= DONE_AT:
		var job := active
		active = {}
		_clear_marker()
		if job.type == "recover" and is_instance_valid(job.get("vehicle")):
			main.despawn(job.vehicle)
		completed.emit(job)
		offers_changed.emit()


# --- Offers -------------------------------------------------------------------------------

func _refill() -> void:
	var tries := 0
	while offers.size() < OFFER_COUNT and tries < 30:
		tries += 1
		var job := _make(TYPES[_rng.randi() % TYPES.size()])
		if job.is_empty():
			continue
		var dup := false
		for o in offers:
			if o.type == job.type:
				dup = true
		if not dup:
			offers.append(job)
	offers_changed.emit()


func _make(type: String) -> Dictionary:
	var job := {"id": _next_id, "type": type, "progress": 0.0}
	_next_id += 1
	match type:
		"dig":
			var half := Vector2(_rng.randf_range(3.0, 5.0), _rng.randf_range(2.5, 4.0))
			var depth := snappedf(_rng.randf_range(0.8, 1.6), 0.1)
			var volume := half.x * half.y * 4.0 * depth
			job.merge({"title": "Foundation dig", "pos": _site(), "half": half, "depth": depth, "volume": volume,
				"brief": "Dig a %d × %d m pit, %.1f m deep (%d m³)." % [roundi(half.x * 2), roundi(half.y * 2), depth, roundi(volume)],
				"reward": _round(volume * 75.0 + 800.0), "tip": "Excavator · dump the spoil anywhere"})
		"fill":
			var volume := float(_rng.randi_range(3, 7) * 4)
			job.merge({"title": "Fill delivery", "pos": _site(), "radius": 5.0, "volume": volume,
				"brief": "Dump %d m³ of soil inside the marked circle." % roundi(volume),
				"reward": _round(volume * 170.0 + 600.0), "tip": "Excavator loads · trucks deliver"})
		"level":
			job.merge({"title": "Level a pad", "pos": _site(), "half": Vector2(5, 5),
				"brief": "Spread the spoil heaps and grade the 10 × 10 m pad flat.",
				"reward": _round(_rng.randf_range(3200.0, 4400.0)), "tip": "Bulldozer · lower the blade a touch"})
		"gravel":
			var along_x := _rng.randf() < 0.5
			var half := Vector2(15, 2.5) if along_x else Vector2(2.5, 15)
			job.merge({"title": "Gravel track", "pos": _site(), "half": half,
				"brief": "Lay gravel over the marked 30 × 5 m track (fetch it from the quarry or the depot bay).",
				"reward": _round(_rng.randf_range(4200.0, 5400.0)), "tip": "Excavator loads gravel · dump it, dozer spreads it"})
		"clear":
			var count := _rng.randi_range(4, 8)
			job.merge({"title": "Land clearing", "count": count,
				"brief": "Fell trees and shred %d logs at a shredder." % count,
				"reward": _round(count * 380.0), "tip": "Grapple or winch the logs to the shredder"})
		"stumps":
			var count := _rng.randi_range(3, 6)
			job.merge({"title": "Stump removal", "count": count,
				"brief": "Pull %d stumps out of the ground." % count,
				"reward": _round(count * 520.0), "tip": "Dig round them or rip them out with the grapple"})
		"demolish":
			var site := _demolition_site()
			if site < 0:
				return {}
			var s: Dictionary = main.demolition_sites[site]
			job.merge({"title": "Demolition", "site": site, "pos": s.center, "share": 0.6,
				"brief": "Knock down 60%% of the %s." % String(s.name),
				"reward": _round(s.blocks.size() * 22.0 + 1500.0), "tip": "Excavator or dozer · watch for falling bricks"})
		"recover":
			var pit: Vector3 = main.MUD_PITS[_rng.randi() % main.MUD_PITS.size()]
			job.merge({"title": "Breakdown recovery", "pos": Vector2(pit.x, pit.y),
				"brief": "A truck's engine died in the mud. Tow or winch it back to the depot.",
				"reward": _round(_rng.randf_range(4200.0, 5600.0)), "tip": "Recovery truck or winches · no engine, no brakes"})
	return job


func _round(value: float) -> int:
	return int(snappedf(value, 50.0))


func _start(job: Dictionary) -> void:
	match String(job.type):
		"level":
			# Dump some spoil heaps on the pad to spread out.
			var p: Vector2 = job.pos
			job.level = 0.0
			var n := 0
			for z in range(-10, 11, 2):
				for x in range(-10, 11, 2):
					job.level += terrain.get_height(p.x + x * 0.5, p.y + z * 0.5)
					n += 1
			job.level /= n
			for k in 3:
				var at := p + Vector2(_rng.randf_range(-3.0, 3.0), _rng.randf_range(-3.0, 3.0))
				terrain.deposit(at.x, at.y, _rng.randf_range(4.0, 6.0), 2.6)
			job.bad_start = maxi(_bad_points(job), 1)
		"clear":
			job.start = int(_counters.logs)
		"stumps":
			job.start = int(_counters.stumps)
		"demolish":
			job.start_moved = _site_moved(job.site)
		"recover":
			var p: Vector2 = job.pos
			job.vehicle = main.spawn_broken_truck(Vector3(p.x, terrain.get_height(p.x, p.y), p.y))
			job.start_distance = maxf(_depot_distance(job.vehicle.global_position), 1.0)
	_build_marker(job)


# --- Progress -----------------------------------------------------------------------------

func _measure(job: Dictionary) -> float:
	match String(job.type):
		"dig":
			return terrain.soil_change(job.pos, job.half, -1.0, float(job.depth)) / float(job.volume)
		"fill":
			var r: float = job.radius
			return terrain.soil_change(job.pos, Vector2(r, r), 1.0, 100.0, r) / float(job.volume)
		"level":
			return 1.0 - float(_bad_points(job)) / float(job.bad_start)
		"gravel":
			var p: Vector2 = job.pos
			var h: Vector2 = job.half
			var covered := 0
			var total := 0
			for z in range(-int(h.y * 2.0), int(h.y * 2.0) + 1):
				for x in range(-int(h.x * 2.0), int(h.x * 2.0) + 1):
					total += 1
					if terrain.is_gravel(p.x + x * 0.5, p.y + z * 0.5):
						covered += 1
			return float(covered) / float(maxi(total, 1)) / 0.9
		"clear":
			return float(int(_counters.logs) - int(job.start)) / float(job.count)
		"stumps":
			return float(int(_counters.stumps) - int(job.start)) / float(job.count)
		"demolish":
			var site: Dictionary = main.demolition_sites[job.site]
			var moved := _site_moved(job.site) - int(job.start_moved)
			return float(moved) / (site.blocks.size() * float(job.share))
		"recover":
			var v: Node3D = job.get("vehicle")
			if not is_instance_valid(v):
				return 0.0
			if _in_depot(v.global_position):
				return 1.0
			return 0.95 * (1.0 - _depot_distance(v.global_position) / float(job.start_distance))
	return 0.0


## Points of a 0.5 m grid on the pad that are more than 12 cm off the target level.
func _bad_points(job: Dictionary) -> int:
	var p: Vector2 = job.pos
	var bad := 0
	for z in range(-10, 11):
		for x in range(-10, 11):
			if absf(terrain.get_height(p.x + x * 0.5, p.y + z * 0.5) - float(job.level)) > 0.12:
				bad += 1
	return bad


## Soil removed (sign -1, counted down to `cap` deep) or added (sign +1) relative to the
## original ground over a rectangle (or a circle, if `radius` > 0), in m3.
func _soil_change(center: Vector2, half: Vector2, sign: float, cap: float, radius := 0.0) -> float:
	var x0 := clampi(roundi((center.x - half.x) / Terrain.CELL_SIZE + Terrain.CELLS * 0.5), 0, Terrain.CELLS)
	var x1 := clampi(roundi((center.x + half.x) / Terrain.CELL_SIZE + Terrain.CELLS * 0.5), 0, Terrain.CELLS)
	var z0 := clampi(roundi((center.y - half.y) / Terrain.CELL_SIZE + Terrain.CELLS * 0.5), 0, Terrain.CELLS)
	var z1 := clampi(roundi((center.y + half.y) / Terrain.CELL_SIZE + Terrain.CELLS * 0.5), 0, Terrain.CELLS)
	var heights := terrain.heights
	var original := terrain.original
	var total := 0.0
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			if radius > 0.0 and terrain.grid_to_world(x, z).distance_to(center) > radius:
				continue
			var i := z * Terrain.VERTS + x
			total += clampf((heights[i] - original[i]) * sign, 0.0, cap)
	return total * Terrain.CELL_AREA


func _site_moved(site: int) -> int:
	var s: Dictionary = main.demolition_sites[site]
	var moved := 0
	for k in s.blocks.size():
		var b: Node3D = s.blocks[k]
		if not is_instance_valid(b) or b.position.distance_to(s.starts[k]) > 0.6:
			moved += 1
	return moved


func _demolition_site() -> int:
	var choices := []
	for k in main.demolition_sites.size():
		var s: Dictionary = main.demolition_sites[k]
		if _site_moved(k) < s.blocks.size() * 0.4:
			choices.append(k)
	return -1 if choices.is_empty() else choices[_rng.randi() % choices.size()]


func _in_depot(p: Vector3) -> bool:
	var zone: Vector2 = main.ZONE
	return absf(p.x - zone.x) < Scenery.ZONE_HALF.x - 1.0 and absf(p.z - zone.y) < Scenery.ZONE_HALF.y - 1.0


func _depot_distance(p: Vector3) -> float:
	var zone: Vector2 = main.ZONE
	var gate := Vector2(zone.x, zone.y - Scenery.ZONE_HALF.y + 4.0)
	return Vector2(p.x, p.z).distance_to(gate)


# --- Sites --------------------------------------------------------------------------------

## Open, fairly flat ground away from water, trees, the depot and the demolition yard.
func _find_sites() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var zone: Vector2 = main.ZONE
	var limit := Terrain.HALF_SIZE - 20.0
	for attempt in 1500:
		var p := Vector2(rng.randf_range(-limit, limit), rng.randf_range(-limit, limit))
		if absf(p.x - zone.x) < Scenery.ZONE_HALF.x + 18.0 and absf(p.y - zone.y) < Scenery.ZONE_HALF.y + 40.0:
			continue
		if p.distance_to(main.DEMOLITION) < 40.0 or terrain.is_protected(p.x, p.y):
			continue
		var ok := true
		var lo := INF
		var hi := -INF
		for off in [Vector2.ZERO, Vector2(7, 0), Vector2(-7, 0), Vector2(0, 7), Vector2(0, -7), Vector2(5, 5), Vector2(-5, -5), Vector2(5, -5), Vector2(-5, 5)]:
			var q: Vector2 = p + off
			var info := terrain.info_at(q.x, q.y)
			if main.water.depth_at(q.x, q.y) > 0.0 or info.y > 0.1 or info.z > 0.5:
				ok = false
				break
			var h := info.x
			lo = minf(lo, h)
			hi = maxf(hi, h)
		if not ok or hi - lo > 1.2:
			continue
		if ok and main.forests.tree_near(p, 10.0):
			ok = false
		for s in sites:
			if s.distance_to(p) < 40.0:
				ok = false
				break
		if ok:
			sites.append(p)
		if sites.size() >= 60:
			break


func _site() -> Vector2:
	return sites[_rng.randi() % sites.size()] if not sites.is_empty() else Vector2(-40, 10)


# --- Marker -------------------------------------------------------------------------------

func _build_marker(job: Dictionary) -> void:
	_clear_marker()
	_marker = Node3D.new()
	add_child(_marker)
	var orange := Kit.glow(Color(1.0, 0.5, 0.08), 1.4)
	var white := Kit.paint(Color(0.95, 0.95, 0.95))
	if job.has("half") or job.has("radius"):
		var p: Vector2 = job.pos
		var corners: Array[Vector2] = []
		if job.has("half"):
			var h: Vector2 = job.half
			corners = [p + Vector2(-h.x, -h.y), p + Vector2(h.x, -h.y), p + Vector2(h.x, h.y), p + Vector2(-h.x, h.y)]
		else:
			for k in 12:
				corners.append(p + Vector2.from_angle(TAU * k / 12.0) * float(job.radius))
		for k in corners.size():
			var a := corners[k]
			var b := corners[(k + 1) % corners.size()]
			var ha := terrain.original_height(a.x, a.y)
			var hb := terrain.original_height(b.x, b.y)
			for s in 3:
				Kit.box(_marker, Vector3(0.12, 0.4, 0.12), Vector3(a.x, ha + 0.2 + s * 0.4, a.y), orange if s % 2 == 0 else white, 0.02)
			Kit.beam(_marker, Vector3(a.x, ha + 0.95, a.y), Vector3(b.x, hb + 0.95, b.y), 0.04, orange)
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.9
	cyl.height = 60.0
	cyl.radial_segments = 12
	cyl.cap_top = false
	cyl.cap_bottom = false
	_beam.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.6, 0.12, 0.28)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beam.material_override = mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.add_child(_beam)
	_sign = Label3D.new()
	_sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sign.font_size = 64
	_sign.pixel_size = 0.02
	_sign.outline_size = 14
	_sign.no_depth_test = true
	_sign.fixed_size = false
	_sign.modulate = Color(1.0, 0.85, 0.3)
	_marker.add_child(_sign)
	_update_marker()


func _update_marker() -> void:
	if _marker == null or active.is_empty():
		return
	var t := target()
	_beam.visible = t != Vector3.INF
	_sign.visible = _beam.visible
	if t == Vector3.INF:
		return
	_beam.global_position = t + Vector3(0, 30.0, 0)
	_sign.global_position = t + Vector3(0, 6.0, 0)
	_sign.text = "%s\n%d%%" % [String(active.title).to_upper(), roundi(float(active.progress) * 100.0)]


func _clear_marker() -> void:
	if _marker:
		_marker.queue_free()
		_marker = null
