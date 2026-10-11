extends Node3D
## Industrial wood shredder. Logs and stumps that end up in the striped infeed zone in front
## of it (dragged in with a winch, pushed by the dozer, dropped by the grapple or tipped
## off the log truck) are pulled in by the rollers and shredded for cash: the drum spins
## up, chips fly off the discharge conveyor and the chip pile grows.
## Built facing -Z: the infeed is on the -Z side.

signal shredded(value: int, label: String, at: Vector3)
## Something started going in (the host tells joining players).
signal feeding(body: RigidBody3D)

const Kit = preload("res://scripts/model_kit.gd")

const STATIC_LAYER := 32
const INFEED_SIZE := Vector3(7.0, 3.0, 6.0)
const INFEED_CENTER := Vector3(0, 1.2, -5.2)
const FEED_TIME := 1.6
const BODY := Color(0.2, 0.42, 0.26)
const ORANGE := Color(0.95, 0.5, 0.08)

var machine_name := "Wood shredder"
## What it takes: "shreddable" (logs and stumps) or "ore" (the ore crusher). Set before adding.
var accepts := "shreddable"
var total_shredded := 0
## Multiplayer: on joining players' machines the host decides what gets shredded.
var remote := false

var _infeed: Area3D
var _drum: Node3D
var _rollers: Array[Node3D] = []
var _chips: GPUParticles3D
var _pile: MeshInstance3D
var _feeding: Array = []  # [body, start transform, time]
var _spin := 0.3
var _poll := 0.0
var _sign_label: Label3D
var _soil_pending := 0.0  # (the crusher) $ of ore in soil tipped in, paid each second
var _soil_timer := 0.0
var _soil_busy := 0.0


func _ready() -> void:
	_build()
	_infeed = Area3D.new()
	_infeed.collision_layer = 0
	_infeed.collision_mask = 4  # logs, stumps, debris
	_infeed.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = INFEED_SIZE
	shape.shape = box
	shape.position = INFEED_CENTER
	_infeed.add_child(shape)
	add_child(_infeed)


## Where trucks and machines should bring the wood (for markers and the minimap).
func infeed_point() -> Vector3:
	return to_global(INFEED_CENTER - Vector3(0, 1.2, 0))


func _physics_process(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0 and not remote:
		_poll = 0.25
		for body in _infeed.get_overlapping_bodies():
			var rb := body as RigidBody3D
			if rb and rb.is_in_group(accepts) and not rb.freeze and not rb.has_meta("shredding"):
				_take(rb)
	var busy := false
	for entry in _feeding.duplicate():
		var rb: RigidBody3D = entry[0]
		entry[2] += delta
		var t: float = entry[2] / FEED_TIME
		if not is_instance_valid(rb):
			_feeding.erase(entry)
			continue
		busy = true
		# Rollers draw it into the mouth, it sinks into the drum and is gone.
		var mouth := to_global(Vector3(0, 1.6, -1.6))
		var start: Transform3D = entry[1]
		var pos := start.origin.lerp(mouth, smoothstep(0.0, 0.6, t))
		pos.y -= maxf(t - 0.6, 0.0) * 3.0
		var shrink := clampf(1.4 - t, 0.05, 1.0)
		rb.global_transform = Transform3D(start.basis.scaled(Vector3.ONE * shrink), pos)
		if t >= 1.0:
			_finish(rb)
			_feeding.erase(entry)
	_soil_busy -= delta
	busy = busy or _soil_busy > 0.0
	_soil_timer -= delta
	if _soil_timer <= 0.0:
		_soil_timer = 1.0
		if _soil_pending >= 1.0 and not remote:
			shredded.emit(int(_soil_pending), "ore", global_position)
			_soil_pending -= floorf(_soil_pending)
	_spin = lerpf(_spin, 9.0 if busy else 0.6, 1.0 - exp(-2.5 * delta))
	_drum.rotation.x += _spin * delta
	for r in _rollers:
		r.rotation.x -= _spin * 0.4 * delta
	_chips.emitting = busy


## The ore crusher also takes soil tipped into its infeed and pays for the ore in it.
func accepts_soil(point: Vector3) -> bool:
	if accepts != "ore":
		return false
	var local := to_local(point) - INFEED_CENTER
	return absf(local.x) < INFEED_SIZE.x * 0.5 + 0.5 and absf(local.z) < INFEED_SIZE.z * 0.5 + 1.0 and local.y > -2.0 and local.y < 6.0


func add_soil(amount: float, _what := 0) -> float:
	_soil_busy = 1.5
	return amount


func add_value(value: float, _gold: float) -> void:
	_soil_pending += value


func take(rb: RigidBody3D) -> void:
	if is_instance_valid(rb) and not rb.has_meta("shredding"):
		_take(rb)


func _take(rb: RigidBody3D) -> void:
	rb.set_meta("shredding", true)
	feeding.emit(rb)
	rb.remove_from_group("winchable")
	rb.freeze = true
	rb.collision_layer = 0
	rb.collision_mask = 0
	_feeding.append([rb, rb.global_transform, 0.0])


func _finish(rb: RigidBody3D) -> void:
	var value := int(rb.get_meta("value", 150))
	var label := String(rb.get_meta("label", "wood"))
	total_shredded += 1
	_grow_pile()
	if not remote:
		shredded.emit(value, label, rb.global_position)
	rb.queue_free()


func _grow_pile() -> void:
	var s := minf(1.0 + total_shredded * 0.08, 2.6)
	_pile.scale = Vector3(s, s * 0.8, s)


func _build() -> void:
	var body := Kit.paint(BODY if accepts == "shreddable" else Color(0.45, 0.45, 0.47))
	var dark := Kit.paint(Color(0.14, 0.14, 0.15), 0.6, 0.3)
	var steel := Kit.metal(Color(0.55, 0.56, 0.58))
	var orange := Kit.paint(ORANGE)
	var concrete := Kit.matte(Color(0.68, 0.68, 0.66))
	var parts := Node3D.new()
	add_child(parts)
	# Concrete pad and the striped infeed zone in front.
	Kit.box(parts, Vector3(9.0, 0.2, 16.0), Vector3(0, 0.1, -1.0), concrete, 0.05)
	for side in [-1.0, 1.0]:
		Kit.box(parts, Vector3(0.4, 0.06, INFEED_SIZE.z), Vector3(side * (INFEED_SIZE.x * 0.5 - 0.2), 0.23, INFEED_CENTER.z), Kit.hazard(), 0.02)
	Kit.box(parts, Vector3(INFEED_SIZE.x, 0.06, 0.4), Vector3(0, 0.23, INFEED_CENTER.z - INFEED_SIZE.z * 0.5 + 0.2), Kit.hazard(), 0.02)
	# Infeed table with two big toothed rollers.
	Kit.box(parts, Vector3(3.2, 0.5, 2.2), Vector3(0, 0.45, -2.5), steel, 0.05)
	for z in [-2.0, -1.2]:
		var roller := Node3D.new()
		roller.position = Vector3(0, 1.15 if z < -1.5 else 1.5, z)
		add_child(roller)
		Kit.axle(roller, 0.35, 2.8, Vector3.ZERO, dark, 16)
		for k in 8:
			var a := TAU * k / 8.0
			Kit.box(roller, Vector3(2.7, 0.12, 0.12), Vector3(0, cos(a), sin(a)) * 0.38, steel, 0.02)
		_rollers.append(roller)
	# Flared hopper over the rollers and the infeed throat frame.
	for side in [-1.0, 1.0]:
		var flare := PackedVector2Array([Vector2(-3.4, 0.9), Vector2(-3.4, 1.5), Vector2(-1.5, 3.1), Vector2(-1.2, 3.1), Vector2(-1.2, 0.9)])
		Kit.add(parts, Kit.prism(flare, 0.14), Vector3(side * 1.95, 0, 0), orange)
	Kit.box(parts, Vector3(3.9, 0.3, 0.3), Vector3(0, 3.1, -1.4), orange, 0.05)
	Kit.box(parts, Vector3(3.9, 0.14, 0.32), Vector3(0, 2.92, -1.4), Kit.hazard(), 0.03)
	# Operator cabin on the side, with a window.
	Kit.box(parts, Vector3(1.4, 1.6, 1.6), Vector3(-2.75, 2.6, 3.0), body, 0.06)
	Kit.box(parts, Vector3(1.42, 0.7, 1.2), Vector3(-2.75, 2.85, 3.0), Kit.glass(), 0.0)
	Kit.box(parts, Vector3(1.5, 0.1, 1.7), Vector3(-2.75, 3.45, 3.0), dark, 0.03)
	Kit.box(parts, Vector3(0.9, 1.8, 0.9), Vector3(-2.75, 0.9, 3.0), dark, 0.05)
	# Main housing over the drum, engine house behind.
	var housing := PackedVector2Array([Vector2(-1.6, 0.2), Vector2(-1.6, 2.6), Vector2(-0.6, 3.6), Vector2(2.4, 3.6), Vector2(2.4, 0.2)])
	for side in [-1.0, 1.0]:
		Kit.add(parts, Kit.prism(housing, 0.2), Vector3(side * 1.7, 0, 0), body)
	Kit.box(parts, Vector3(3.6, 0.2, 3.1), Vector3(0, 3.6, 0.9), body, 0.06)
	Kit.box(parts, Vector3(3.6, 1.2, 0.2), Vector3(0, 0.8, 2.4), body, 0.04)
	_drum = Node3D.new()
	_drum.position = Vector3(0, 1.6, 0.3)
	add_child(_drum)
	Kit.axle(_drum, 0.9, 3.0, Vector3.ZERO, dark, 20)
	for k in 10:
		var a := TAU * k / 10.0
		Kit.box(_drum, Vector3(2.9, 0.2, 0.18), Vector3(0, cos(a), sin(a)) * 0.95, steel, 0.03)
	Kit.box(parts, Vector3(4.0, 3.2, 3.6), Vector3(0, 1.9, 4.2), body, 0.1)
	Kit.box(parts, Vector3(4.02, 0.3, 3.62), Vector3(0, 3.0, 4.2), orange, 0.05)
	for k in 6:
		Kit.box(parts, Vector3(0.05, 1.4, 0.1), Vector3(2.02, 1.8, 2.9 + k * 0.5), dark, 0.01)
		Kit.box(parts, Vector3(0.05, 1.4, 0.1), Vector3(-2.02, 1.8, 2.9 + k * 0.5), dark, 0.01)
	Kit.add(parts, Kit.cylinder(0.14, 1.6, 12), Vector3(1.2, 4.2, 4.8), steel)
	Kit.add(parts, Kit.sphere(0.2, 10, true), Vector3(-1.4, 3.5, 2.6), Kit.glow(Color(1.0, 0.55, 0.05), 2.4))
	# Discharge conveyor throwing chips onto the pile.
	var belt_from := Vector3(0, 0.8, 2.6)
	var belt_to := Vector3(0, 4.6, 9.5)
	Kit.beam(parts, belt_from, belt_to, 0.9, dark)
	Kit.beam(parts, belt_from + Vector3(0, 0.3, 0), belt_to + Vector3(0, 0.3, 0), 0.7, Kit.matte(Color(0.55, 0.38, 0.22)))
	Kit.beam(parts, Vector3(0, 0.2, 7.5), Vector3(0, 3.8, 7.7), 0.18, steel)
	_pile = Kit.add(self, Kit.cylinder(0.05, 1.6, 14, 2.2), Vector3(0, 0.8, 11.0), Kit.matte(Color(0.78, 0.6, 0.38)))
	_pile.set_meta("keep", true)
	_grow_pile()
	_chips = GPUParticles3D.new()
	_chips.amount = 80
	_chips.lifetime = 1.4
	_chips.position = belt_to + Vector3(0, 0.3, 0.3)
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 0.3, 1)
	process.spread = 25.0
	process.initial_velocity_min = 2.0
	process.initial_velocity_max = 4.0
	process.gravity = Vector3(0, -9.8, 0)
	process.scale_min = 0.6
	process.scale_max = 1.2
	_chips.process_material = process
	var chip := BoxMesh.new()
	chip.size = Vector3(0.08, 0.03, 0.12)
	chip.material = Kit.matte(Color(0.85, 0.68, 0.42))
	_chips.draw_pass_1 = chip
	_chips.emitting = false
	add_child(_chips)
	# Price board.
	for x in [-5.3, -2.3]:
		Kit.box(parts, Vector3(0.15, 3.4, 0.15), Vector3(x, 1.7, -8.6), steel, 0.03)
	Kit.box(parts, Vector3(3.4, 1.2, 0.1), Vector3(-3.8, 3.4, -8.6), Kit.paint(Color(0.98, 0.78, 0.15)), 0.03)
	var title := "WOOD SHREDDER" if accepts == "shreddable" else "ORE CRUSHER"
	var offer := "$ FOR LOGS, STUMPS & BARS" if accepts == "shreddable" else "TIP ORE-RICH SOIL
$ FOR THE ORE IN IT"
	_sign_label = Kit.label(self, title + "\n" + offer, Vector3(-3.8, 3.4, -8.67), 0.0024, Color(0.12, 0.1, 0.08), PI)
	Kit.label(parts, title, Vector3(1.82, 2.4, 0.6), 0.0042, Color.WHITE, PI * 0.5)
	Kit.label(parts, title, Vector3(-1.82, 2.4, 0.6), 0.0042, Color.WHITE, -PI * 0.5)
	Kit.merge_tree(self)
	# Solid parts: the housing, engine house, infeed table and pad edge.
	var solid := StaticBody3D.new()
	solid.collision_layer = STATIC_LAYER
	solid.collision_mask = 0
	add_child(solid)
	for b in [[Vector3(3.6, 3.6, 4.0), Vector3(0, 1.8, 0.4)], [Vector3(4.0, 3.2, 3.6), Vector3(0, 1.6, 4.2)],
			[Vector3(3.2, 0.7, 1.6), Vector3(0, 0.35, -2.6)]]:
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = b[0]
		col.shape = box
		col.position = b[1]
		solid.add_child(col)
