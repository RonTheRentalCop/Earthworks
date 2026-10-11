extends Node3D
## Quarry tip: a concrete bay where trucks (and buckets) drop off soil and gravel for cash.
## Clean fill pays a flat rate per m3; any ore in it is paid at half what the crusher pays.
## Takes everything poured in (a loader inside clears it away). Built facing -Z: the open
## side, where trucks back in, is at -Z.

signal paid(value: int, label: String, at: Vector3)

const Kit = preload("res://scripts/model_kit.gd")

const SOIL_RATE := 5.0  # $ per m3 of soil
const GRAVEL_RATE := 3.0
const ORE_SHARE := 0.5
const BAY := Vector2(10.0, 9.0)  # inside width and depth
const PAY_EVERY := 1.0

var machine_name := "Quarry tip"
var taken := 0.0
var _pending := 0.0
var _timer := 0.0
var _pile: MeshInstance3D


func _ready() -> void:
	_build()


## Soil dropped here lands in the bay (from a tailgate or a bucket above it).
func accepts_soil(point: Vector3) -> bool:
	var local := to_local(point)
	return absf(local.x) < BAY.x * 0.5 + 0.5 and local.z > -BAY.y * 0.5 - 1.5 and local.z < BAY.y * 0.5 \
		and local.y > -1.0 and local.y < 7.0


func add_soil(amount: float, what := 0) -> float:
	_pending += amount * (GRAVEL_RATE if what == 1 else SOIL_RATE)
	taken += amount
	_pile.scale.y = clampf(0.2 + fmod(taken, 40.0) / 40.0, 0.2, 1.2)
	return amount


func add_value(value: float, _gold: float) -> void:
	_pending += value * ORE_SHARE


func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = PAY_EVERY
	if _pending >= 1.0:
		paid.emit(int(_pending), "delivered fill", global_position)
		_pending -= floorf(_pending)


func _build() -> void:
	var concrete := Kit.matte(Color(0.68, 0.68, 0.66))
	var dark := Kit.paint(Color(0.18, 0.18, 0.2), 0.6, 0.3)
	var parts := Node3D.new()
	add_child(parts)
	Kit.box(parts, Vector3(BAY.x + 1.2, 0.2, BAY.y + 1.0), Vector3(0, 0.1, 0.3), concrete, 0.04)
	# Push walls on three sides (the -Z side is open for trucks).
	Kit.box(parts, Vector3(BAY.x + 1.2, 2.4, 0.6), Vector3(0, 1.2, BAY.y * 0.5 + 0.5), concrete, 0.05)
	for side in [-1.0, 1.0]:
		Kit.box(parts, Vector3(0.6, 2.4, BAY.y + 1.0), Vector3(side * (BAY.x * 0.5 + 0.3), 1.2, 0.3), concrete, 0.05)
		Kit.box(parts, Vector3(0.62, 0.3, BAY.y + 1.02), Vector3(side * (BAY.x * 0.5 + 0.3), 2.25, 0.3), Kit.hazard(), 0.02)
	Kit.box(parts, Vector3(BAY.x, 0.06, 0.4), Vector3(0, 0.23, -BAY.y * 0.5 + 0.2), Kit.hazard(), 0.02)
	_pile = Kit.add(self, Kit.cylinder(0.2, 1.2, 12, 3.4), Vector3(0, 0.6, 1.5), Kit.matte(Color(0.56, 0.33, 0.2)))
	_pile.set_meta("keep", true)
	_pile.scale.y = 0.2
	# Sign.
	for x in [-BAY.x * 0.5 - 1.2, -BAY.x * 0.5 + 1.8]:
		Kit.box(parts, Vector3(0.15, 3.6, 0.15), Vector3(x, 1.8, -BAY.y * 0.5 - 1.6), dark, 0.03)
	Kit.box(parts, Vector3(3.4, 1.3, 0.1), Vector3(-BAY.x * 0.5 + 0.3, 3.5, -BAY.y * 0.5 - 1.6), Kit.paint(Color(0.98, 0.78, 0.15)), 0.03)
	Kit.label(self, "QUARRY TIP\n$%d / m³ SOIL\n$%d / m³ GRAVEL" % [SOIL_RATE, GRAVEL_RATE], Vector3(-BAY.x * 0.5 + 0.3, 3.5, -BAY.y * 0.5 - 1.67), 0.0022, Color(0.12, 0.1, 0.08), PI)
	Kit.merge_tree(self)
	var solid := StaticBody3D.new()
	solid.collision_layer = 32
	solid.collision_mask = 0
	add_child(solid)
	for b in [[Vector3(BAY.x + 1.2, 2.4, 0.6), Vector3(0, 1.2, BAY.y * 0.5 + 0.5)],
			[Vector3(0.6, 2.4, BAY.y + 1.0), Vector3(-(BAY.x * 0.5 + 0.3), 1.2, 0.3)],
			[Vector3(0.6, 2.4, BAY.y + 1.0), Vector3(BAY.x * 0.5 + 0.3, 1.2, 0.3)]]:
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = b[0]
		col.shape = box
		col.position = b[1]
		solid.add_child(col)
