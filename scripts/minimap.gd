extends Control
## North-up minimap around the player: a painted map of the terrain (hill shading, water,
## gravel, mud, fresh earthworks) with trees, the depot, shredders, the quarry, machines
## and the job waypoint. The 1 km map is painted lazily, 32 m at a time, as blocks come
## into view (without generating any ground just to draw it), and repainted where the
## ground changes. M toggles between a close view and a wide one.

const Terrain = preload("res://scripts/terrain.gd")

const VIEWS := [110.0, 420.0]  # metres shown across the map
const SIZE := 1536  # 1 pixel per metre
const BLOCK := 32
const BLOCKS := 48  # SIZE / BLOCK
const PAINTS_PER_FRAME := 3

var main: Node3D
var zoom := 0
var _image: Image
var _texture: ImageTexture
var _painted := PackedByteArray()
var _queue: Array = []
var _pulse := 0.0
var _font: Font
var _upload := false


func setup(main_node: Node3D, font: Font) -> void:
	main = main_node
	_font = font
	_image = Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	_image.fill(Color(0.6, 0.53, 0.32))
	_texture = ImageTexture.create_from_image(_image)
	_painted.resize(BLOCKS * BLOCKS)
	_painted.fill(0)
	main.terrain.area_changed.connect(func(rect: Rect2) -> void:
		var b0 := Vector2i(floori((rect.position.x + Terrain.HALF_SIZE) / BLOCK), floori((rect.position.y + Terrain.HALF_SIZE) / BLOCK))
		var b1 := Vector2i(floori((rect.end.x + Terrain.HALF_SIZE) / BLOCK), floori((rect.end.y + Terrain.HALF_SIZE) / BLOCK))
		for bz in range(maxi(b0.y, 0), mini(b1.y, BLOCKS - 1) + 1):
			for bx in range(maxi(b0.x, 0), mini(b1.x, BLOCKS - 1) + 1):
				_painted[bz * BLOCKS + bx] = 0)
	clip_contents = true


func toggle_zoom() -> void:
	zoom = (zoom + 1) % VIEWS.size()


func _process(delta: float) -> void:
	_pulse += delta
	if main == null:
		return
	var p: Vector3 = main.focus_node().global_position
	var view: float = VIEWS[zoom]
	var b0 := Vector2i(floori((p.x - view * 0.75 + Terrain.HALF_SIZE) / BLOCK), floori((p.z - view * 0.75 + Terrain.HALF_SIZE) / BLOCK))
	var b1 := Vector2i(floori((p.x + view * 0.75 + Terrain.HALF_SIZE) / BLOCK), floori((p.z + view * 0.75 + Terrain.HALF_SIZE) / BLOCK))
	var painted := 0
	for bz in range(maxi(b0.y, 0), mini(b1.y, BLOCKS - 1) + 1):
		for bx in range(maxi(b0.x, 0), mini(b1.x, BLOCKS - 1) + 1):
			if painted >= PAINTS_PER_FRAME:
				break
			if _painted[bz * BLOCKS + bx] == 0:
				_paint_block(bx, bz)
				painted += 1
	if painted > 0:
		_upload = true
	if _upload and Engine.get_process_frames() % 6 == 0:
		_texture.update(_image)
		_upload = false
	queue_redraw()


func _paint_block(bx: int, bz: int) -> void:
	_painted[bz * BLOCKS + bx] = 1
	var terrain = main.terrain
	var water = main.water
	for py in range(bz * BLOCK, bz * BLOCK + BLOCK):
		for px in range(bx * BLOCK, bx * BLOCK + BLOCK):
			var wx := px - Terrain.HALF_SIZE + 0.5
			var wz := py - Terrain.HALF_SIZE + 0.5
			var info: Vector4 = terrain.info_at(wx, wz)
			var east: float = terrain.info_at(wx + 1.0, wz).x
			var south: float = terrain.info_at(wx, wz + 1.0).x
			var shade := clampf(1.0 + ((east - info.x) - (south - info.x)) * 0.35, 0.55, 1.35)
			var c := Color(0.62, 0.55, 0.32)
			var kind := roundi(info.z)
			if info.w > 0.5:
				c = Color(0.6, 0.38, 0.24)
			elif kind == 1:
				c = Color(0.6, 0.6, 0.58)
			elif kind == 2:
				c = Color(0.9, 0.92, 0.95)  # snow
			elif kind == 3:
				c = Color(0.65, 0.82, 0.92)  # ice
			elif false:
				c = Color(0.6, 0.38, 0.24)
			if info.y > 0.2:
				c = c.lerp(Color(0.3, 0.22, 0.15), info.y)
			c = c * shade
			var depth: float = water.depth_at(wx, wz)
			if depth > 0.03:
				c = Color(0.2, 0.48, 0.62).lerp(Color(0.1, 0.3, 0.45), clampf(depth / 2.0, 0.0, 1.0))
			_image.set_pixel(px, py, Color(c.r, c.g, c.b))


func _draw() -> void:
	if main == null:
		return
	var player: Node3D = main.focus_node()
	var centre := Vector2(player.global_position.x, player.global_position.z)
	var view: float = VIEWS[zoom]
	var scale_px := size.x / view
	var src := Rect2(centre + Vector2(Terrain.HALF_SIZE, Terrain.HALF_SIZE) - Vector2(view, view) * 0.5, Vector2(view, view))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.36, 0.33, 0.2))
	draw_texture_rect_region(_texture, Rect2(Vector2.ZERO, size), src)
	var to_map := func(p: Vector3) -> Vector2:
		return (Vector2(p.x, p.z) - centre) * scale_px + size * 0.5
	# Trees as dark dots.
	var dot := 1.6 if zoom == 0 else 0.9
	for q in main.forests.standing_in(Rect2(centre - Vector2(view, view) * 0.5, Vector2(view, view))):
		draw_circle((q - centre) * scale_px + size * 0.5, dot, Color(0.16, 0.3, 0.16))
	# Depot and quarry outlines.
	var zone: Vector2 = main.ZONE
	var half: Vector2 = main.Scenery.ZONE_HALF
	var a: Vector2 = to_map.call(Vector3(zone.x - half.x, 0, zone.y - half.y))
	var b: Vector2 = to_map.call(Vector3(zone.x + half.x, 0, zone.y + half.y))
	draw_rect(Rect2(a, b - a), Color(1.0, 0.78, 0.15, 0.9), false, 2.0)
	var quarry: Vector2 = main.QUARRY
	var qa: Vector2 = to_map.call(Vector3(quarry.x - 38, 0, quarry.y - 28))
	var qb: Vector2 = to_map.call(Vector3(quarry.x + 38, 0, quarry.y + 28))
	draw_rect(Rect2(qa, qb - qa), Color(0.85, 0.85, 0.85, 0.9), false, 2.0)
	if Rect2(Vector2.ZERO, size).has_point((qa + qb) * 0.5):
		_draw_letter((qa + qb) * 0.5, "Q")
	# The quarry tip (fill delivered for cash).
	if main.tip:
		var tq: Vector2 = to_map.call(main.tip.global_position)
		if Rect2(Vector2(-8, -8), size + Vector2(16, 16)).has_point(tq):
			draw_circle(tq, 7.0, Color(0.1, 0.1, 0.1, 0.8))
			draw_circle(tq, 5.5, Color(0.95, 0.75, 0.2))
			_draw_letter(tq, "T")
	# Shredders.
	for s in main.shredders:
		var q: Vector2 = to_map.call(s.global_position)
		if not Rect2(Vector2(-8, -8), size + Vector2(16, 16)).has_point(q):
			continue
		draw_circle(q, 7.0, Color(0.1, 0.1, 0.1, 0.8))
		draw_circle(q, 5.5, Color(0.35, 0.75, 0.35))
		_draw_letter(q, "S")
	# Trailers and machines.
	for t in main.trailers:
		_draw_box(to_map.call(t.global_position), t.global_rotation.y, Vector2(3, 9) * scale_px, Color(0.85, 0.2, 0.15))
	for m in main.machines:
		var col := Color(1.0, 0.78, 0.15)
		if m.get("broken"):
			col = Color(0.95, 0.3, 0.25)
		elif m == main.driving():
			col = Color(1, 1, 1)
		_draw_box(to_map.call(m.global_position), m.global_rotation.y, Vector2(3, 6) * scale_px, col)
	# Job waypoint (clamped to the edge with an arrow when off the map).
	var target: Vector3 = main.jobs.target()
	if target != Vector3.INF:
		var q: Vector2 = to_map.call(target)
		var inner := Rect2(Vector2(10, 10), size - Vector2(20, 20))
		var pulse := 6.0 + 2.5 * sin(_pulse * 5.0)
		if inner.has_point(q):
			draw_circle(q, pulse + 2.0, Color(0, 0, 0, 0.5))
			draw_circle(q, pulse, Color(1.0, 0.55, 0.1))
		else:
			var dir := (q - size * 0.5).normalized()
			var edge := size * 0.5 + dir * (size.x * 0.5 - 12.0)
			var side := Vector2(-dir.y, dir.x)
			draw_colored_polygon(PackedVector2Array([edge + dir * 10.0, edge - dir * 6.0 + side * 7.0, edge - dir * 6.0 - side * 7.0]), Color(1.0, 0.55, 0.1))
	# The player (or the machine being driven): an arrow pointing the way it faces.
	var yaw: float = player.facing_yaw() if player.has_method("facing_yaw") else player.global_rotation.y
	var heading := Vector2(-sin(yaw), -cos(yaw))
	if player is VehicleBody3D:
		heading = -heading
	var c := size * 0.5
	var side2 := Vector2(-heading.y, heading.x)
	var arrow := PackedVector2Array([c + heading * 9.0, c - heading * 6.0 + side2 * 6.0, c - heading * 3.0, c - heading * 6.0 - side2 * 6.0])
	draw_colored_polygon(arrow, Color(0, 0, 0, 0.6))
	draw_colored_polygon(PackedVector2Array([arrow[0] * 0.85 + c * 0.15, arrow[1] * 0.85 + c * 0.15, arrow[2] * 0.85 + c * 0.15, arrow[3] * 0.85 + c * 0.15]), Color.WHITE)
	_draw_letter(Vector2(size.x * 0.5, 11), "N")
	_draw_letter(Vector2(size.x - 22, size.y - 10), "%dm" % roundi(view))


func _draw_box(q: Vector2, yaw: float, dims: Vector2, col: Color) -> void:
	if not Rect2(Vector2(-10, -10), size + Vector2(20, 20)).has_point(q):
		return
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var side := Vector2(-fwd.y, fwd.x)
	var hx := side * maxf(dims.x * 0.5, 2.5)
	var hz := fwd * maxf(dims.y * 0.5, 4.0)
	var pts := PackedVector2Array([q + hx + hz, q - hx + hz, q - hx - hz, q + hx - hz])
	var outline := PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]])
	draw_colored_polygon(pts, col)
	draw_polyline(outline, Color(0, 0, 0, 0.8), 1.5)


func _draw_letter(q: Vector2, letter: String) -> void:
	if _font == null:
		return
	draw_string_outline(_font, q + Vector2(-5, 5), letter, HORIZONTAL_ALIGNMENT_CENTER, 10, 13, 4, Color(0, 0, 0, 0.8))
	draw_string(_font, q + Vector2(-5, 5), letter, HORIZONTAL_ALIGNMENT_CENTER, 10, 13, Color.WHITE)
