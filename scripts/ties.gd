extends Node3D
## Ratchet straps and ropes the worker ties by hand (on foot: strap G / LB, rope R / RB,
## cut X / B; each tie is two presses, at the thing and then at what to tie it to).
##  - A ratchet strap locks a loose item (log, stump, mat, rubble) where it sits on what
##    it's strapped to: a truck, trailer, machine or tree carries it rigidly. Between two
##    vehicles it's a tight tether.
##  - A rope is a line with a little slack that pulls when it goes tight: drag a log
##    behind a truck, tie things together. Machines on tracks and trees are anchors.
## The host runs them; joining players see them drawn.

const STRAP := "strap"
const ROPE := "rope"
const ROPE_SLACK := 0.5
const STIFFNESS := 70000.0  # N per metre of stretch
const DAMPING := 9000.0
const MAX_FORCE := 320000.0

## Each tie: {id, kind, a, b, pa, pb (points in a's / b's space), length, locked (a rides
## b rigidly), local (a's transform in b's space), view}.
var ties: Array = []
var main: Node
var _next_id := 1
var _strap_material := StandardMaterial3D.new()
var _rope_material := StandardMaterial3D.new()


func _ready() -> void:
	add_to_group("ties")
	_strap_material.albedo_color = Color(0.98, 0.72, 0.08)
	_strap_material.roughness = 0.7
	_rope_material.albedo_color = Color(0.55, 0.42, 0.25)
	_rope_material.roughness = 0.95


## Ties `a` to `b` (host only): points are in world space. Returns what to tell the player.
func tie(kind: String, a: Node3D, pa: Vector3, b: Node3D, pb: Vector3) -> String:
	if not is_instance_valid(a) or not is_instance_valid(b) or a == b:
		return "Can't tie that"
	# A strap locks the loose item onto the other thing (whichever end that is).
	if kind == STRAP and not _is_loose(a) and _is_loose(b):
		var swap := a
		a = b
		b = swap
		var swap_p := pa
		pa = pb
		pb = swap_p
	var entry := {"id": _next_id, "kind": kind, "a": a, "b": b, "pa": a.to_local(pa), "pb": b.to_local(pb),
		"length": pa.distance_to(pb) + (ROPE_SLACK if kind == ROPE else 0.0), "locked": false, "local": Transform3D(), "view": null}
	_next_id += 1
	if kind == STRAP and _is_loose(a):
		var body := a as RigidBody3D
		if body.has_meta("strapped_to"):
			var trailer = body.get_meta("strapped_to")
			if is_instance_valid(trailer):
				trailer.unstrap(body)
		if body.has_meta("tie_locked"):
			release(body)
		entry.locked = true
		entry.local = b.global_transform.affine_inverse() * a.global_transform
		body.set_meta("tie_locked", entry.id)
		body.set_meta("tie_freeze_mode", body.freeze_mode)
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
		if b is PhysicsBody3D:
			body.add_collision_exception_with(b)
	ties.append(entry)
	_changed()
	return "%s %s to the %s" % ["Strapped the" if kind == STRAP else "Tied the", _name(a), _name(b)]


## Cuts one tie; whatever it held carries on with the thing's motion.
func cut(id: int) -> bool:
	for k in ties.size():
		if int(ties[k].id) == id:
			_undo(ties[k])
			ties.remove_at(k)
			_changed()
			return true
	return false


## Cuts the tie passing nearest `point` (within `reach`); returns its id or -1.
func tie_near(point: Vector3, reach: float) -> int:
	var best := -1
	var best_d := reach
	for entry in ties:
		var ends := _ends(entry)
		if ends.is_empty():
			continue
		var d := Geometry3D.get_closest_point_to_segment(point, ends[0], ends[1]).distance_to(point)
		if d < best_d:
			best_d = d
			best = int(entry.id)
	return best


## Lets go of anything strapped to or from `node` (a grapple picking it up).
func release(node: Node) -> void:
	for k in range(ties.size() - 1, -1, -1):
		var entry: Dictionary = ties[k]
		if entry.a == node or entry.b == node:
			_undo(entry)
			ties.remove_at(k)
	_changed()


func _undo(entry: Dictionary) -> void:
	if is_instance_valid(entry.view):
		(entry.view as Node).queue_free()
	if entry.locked and is_instance_valid(entry.a):
		var body := entry.a as RigidBody3D
		body.remove_meta("tie_locked")
		body.freeze_mode = body.get_meta("tie_freeze_mode", RigidBody3D.FREEZE_MODE_STATIC)
		body.remove_meta("tie_freeze_mode")
		if is_instance_valid(entry.b) and entry.b is PhysicsBody3D:
			body.remove_collision_exception_with(entry.b)
		body.freeze = false
		var carrier := entry.b as RigidBody3D
		body.linear_velocity = carrier.linear_velocity if carrier else Vector3.ZERO


func _is_loose(n: Node) -> bool:
	return n is RigidBody3D and not n is VehicleBody3D


func _name(n: Node) -> String:
	return String(n.get_meta("label", n.get("machine_name") if n.get("machine_name") else "thing"))


func _ends(entry: Dictionary) -> Array:
	if not is_instance_valid(entry.a) or not is_instance_valid(entry.b):
		return []
	return [(entry.a as Node3D).to_global(entry.pa), (entry.b as Node3D).to_global(entry.pb)]


func _physics_process(_delta: float) -> void:
	if main == null or main.net.is_client():
		return
	var gone := false
	for k in range(ties.size() - 1, -1, -1):
		var entry: Dictionary = ties[k]
		if not is_instance_valid(entry.a) or not is_instance_valid(entry.b) or not (entry.a as Node).is_inside_tree() or not (entry.b as Node).is_inside_tree():
			_undo(entry)
			ties.remove_at(k)
			gone = true
			continue
		if entry.locked:
			(entry.a as Node3D).global_transform = (entry.b as Node3D).global_transform * (entry.local as Transform3D)
			continue
		# A line: pulls both ends together once it's stretched past its length.
		var ends := _ends(entry)
		var span: Vector3 = ends[1] - ends[0]
		var d := span.length()
		if d <= float(entry.length) or d < 0.001:
			continue
		var dir := span / d
		var closing := (_velocity_at(entry.b, ends[1]) - _velocity_at(entry.a, ends[0])).dot(dir)
		var pull := clampf(STIFFNESS * (d - float(entry.length)) + DAMPING * closing, 0.0, MAX_FORCE)
		for side in 2:
			var node: Node3D = entry.a if side == 0 else entry.b
			var body := node as RigidBody3D
			if body == null or body.freeze:
				continue  # tracked machines, trees and frozen things are anchors
			var at: Vector3 = ends[side]
			body.apply_force(dir * pull * (1.0 if side == 0 else -1.0), at - body.global_position)
			body.sleeping = false
	if gone:
		_changed()


func _velocity_at(node: Node3D, at: Vector3) -> Vector3:
	var body := node as RigidBody3D
	if body:
		return body.linear_velocity + body.angular_velocity.cross(at - body.global_position)
	var moving = node.get("velocity")
	return moving if moving is Vector3 else Vector3.ZERO


func _process(_delta: float) -> void:
	for entry in ties:
		var ends := _ends(entry)
		if ends.is_empty():
			continue
		if not is_instance_valid(entry.view):
			var view := MeshInstance3D.new()
			if entry.kind == STRAP:
				var band := BoxMesh.new()
				band.size = Vector3(0.05, 1.0, 0.012)
				view.mesh = band
				view.material_override = _strap_material
			else:
				var line := CylinderMesh.new()
				line.top_radius = 0.018
				line.bottom_radius = 0.018
				line.height = 1.0
				line.radial_segments = 6
				view.mesh = line
				view.material_override = _rope_material
			view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(view)
			entry.view = view
		_stretch(entry.view, ends[0], ends[1], entry.kind == ROPE and not entry.locked, float(entry.length))


## Lays a unit-long mesh between two points (a slack rope sags a little in the middle).
func _stretch(view: MeshInstance3D, a: Vector3, b: Vector3, sags: bool, length: float) -> void:
	var span := b - a
	var d := span.length()
	if d < 0.01:
		view.visible = false
		return
	view.visible = true
	var mid := (a + b) * 0.5
	if sags and d < length:
		mid.y -= minf(length - d, 1.5) * 0.5
	var up := span / d
	var side := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	view.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(1, d, 1)), mid)


# --- Network ----------------------------------------------------------------------------

## Tells joining players what's tied to what (host).
func _changed() -> void:
	if main and main.net.is_host():
		main.net.send_ties(net_state())


func net_state() -> Array:
	var out := []
	for entry in ties:
		if is_instance_valid(entry.a) and is_instance_valid(entry.b):
			out.append([int(entry.id), entry.kind, main.net_id_of(entry.a), main.net_id_of(entry.b), entry.pa, entry.pb, float(entry.length)])
	return out


## Joining player: draw the host's ties (no physics here; the host moves everything).
func apply_net_state(list: Array) -> void:
	for entry in ties:
		if is_instance_valid(entry.view):
			(entry.view as Node).queue_free()
	ties.clear()
	for item in list:
		var a: Node3D = main.node_by_net_id(String(item[2]))
		var b: Node3D = main.node_by_net_id(String(item[3]))
		if a and b:
			ties.append({"id": int(item[0]), "kind": String(item[1]), "a": a, "b": b, "pa": item[4], "pb": item[5],
				"length": float(item[6]), "locked": false, "local": Transform3D(), "view": null})
