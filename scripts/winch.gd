extends Node3D
## A winch with a steel cable. attach() hooks the nearest thing in the "winchable" group
## (vehicles, trailers, logs, stumps, props, standing trees as anchors). The cable is a
## one-way spring: slack until it's paid out, then it pulls both ends together, limited
## to `max_force`. Physics bodies get pulled; static things (trees, buildings) and the
## kinematic machines act as anchors, so a stuck truck can drag itself out against a
## tree or be dragged out by the dozer. reel() shortens the cable.

const REEL_SPEED := 1.4  # m/s
const STIFFNESS := 60000.0  # N per metre of stretch
const DAMPING := 9000.0  # N per m/s
const MIN_LENGTH := 1.5

## The vehicle this winch is mounted on.
var vehicle: Node3D
var max_force := 150000.0
var reach := 30.0
var target: Node3D
var length := 0.0
var tension := 0.0

var _target_point := Vector3.ZERO  # in the target's local space
var _cable: MeshInstance3D
var _reeling := false
## Multiplayer: on joining players' machines the winch only draws the cable.
var puppet := false
## Resolves a network id to a node (set by main on joining players' machines).
static var resolve: Callable
## Network id of a node (set by main on the host).
static var identify: Callable


func _ready() -> void:
	var rope := CylinderMesh.new()
	rope.top_radius = 0.025
	rope.bottom_radius = 0.025
	rope.height = 1.0
	rope.radial_segments = 6
	_cable = MeshInstance3D.new()
	_cable.mesh = rope
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.2, 0.2, 0.22)
	steel.metallic = 0.6
	steel.roughness = 0.4
	_cable.material_override = steel
	_cable.top_level = true
	_cable.visible = false
	add_child(_cable)
	var drum := CylinderMesh.new()
	drum.top_radius = 0.16
	drum.bottom_radius = 0.16
	drum.height = 0.4
	drum.radial_segments = 10
	var drum_mesh := MeshInstance3D.new()
	drum_mesh.mesh = drum
	drum_mesh.rotation.z = PI * 0.5
	drum_mesh.material_override = steel
	add_child(drum_mesh)


func is_attached() -> bool:
	return target != null and is_instance_valid(target)


## Hooks the nearest winchable thing within reach (preferring things behind the hook
## direction `prefer`). Returns its name, or "" if nothing is in range.
func attach(prefer: Vector3) -> String:
	var best: Node3D = null
	var best_score := INF
	var origin := global_position
	for node in get_tree().get_nodes_in_group("winchable"):
		var candidate := node as Node3D
		if candidate == null or candidate == vehicle or vehicle.is_ancestor_of(candidate):
			continue
		var to := candidate.global_position - origin
		var d := to.length()
		if d > reach or d < 0.5:
			continue
		# Big things first, then closeness, then direction.
		var score := d * (1.5 - 0.5 * to.normalized().dot(prefer.normalized()))
		if candidate is VehicleBody3D or candidate is CharacterBody3D:
			score *= 0.35  # a stuck machine beats the tree beside you
		if score < best_score:
			best_score = score
			best = candidate
	if best == null:
		return ""
	target = best
	_target_point = best.to_local(_hook_point_on(best))
	length = global_position.distance_to(_target_world()) + 0.3
	_cable.visible = true
	return String(best.get_meta("label", best.name))


func detach() -> void:
	target = null
	tension = 0.0
	_cable.visible = false


func reel(on: bool) -> void:
	_reeling = on


## Multiplayer: [target id, hook point on the target, cable length] ("" = not hooked).
func net_state() -> Array:
	if not is_attached() or not identify.is_valid():
		return [""]
	return [identify.call(target), _target_point, length]


func apply_net_state(s: Array) -> void:
	puppet = true
	var id := String(s[0])
	if id == "" or not resolve.is_valid():
		if target:
			detach()
		return
	var node: Node3D = resolve.call(id)
	if node == null:
		return
	target = node
	_target_point = s[1]
	length = s[2]
	_cable.visible = true


func _physics_process(delta: float) -> void:
	if puppet:
		if is_attached():
			_draw_cable(global_position, _target_world())
		elif _cable.visible:
			_cable.visible = false
		return
	if not is_attached():
		if _cable.visible:
			detach()
		return
	var a := global_position
	var b := _target_world()
	var d := a.distance_to(b)
	if _reeling:
		length = maxf(length - REEL_SPEED * delta, MIN_LENGTH)
	else:
		length = minf(length, d + 0.3)  # take in slack, never pay out by itself
	tension = 0.0
	if d > length:
		var dir := (b - a) / d
		var closing := (_velocity_at(vehicle, a) - _velocity_at(target, b)).dot(dir)
		tension = clampf(STIFFNESS * (d - length) - DAMPING * closing, 0.0, max_force)
		var pull := dir * tension
		# Tell the far end it's being pulled (a parked truck knocks its brakes off).
		target.set_meta("winched_until", Time.get_ticks_msec() + 250)
		var target_body := target as RigidBody3D
		if target_body and target_body.has_meta("bedded") and tension > 2000.0:
			target_body.remove_meta("bedded")  # a bedded ground mat comes loose
			target_body.freeze = false
		if target_body and not target_body.freeze:
			target_body.apply_force(-pull, b - target_body.global_position)
		var own := vehicle as RigidBody3D
		if own:
			own.apply_force(pull, a - own.global_position)
	_draw_cable(a, b)


func _target_world() -> Vector3:
	return target.to_global(_target_point)


## Where the hook bites: low on trees and stumps, a tow point on vehicles, the centre otherwise.
func _hook_point_on(node: Node3D) -> Vector3:
	if node.has_method("tow_point"):
		return node.tow_point(global_position)
	if node is StaticBody3D:
		return node.global_position + Vector3(0, 0.6, 0)
	return node.global_position


func _velocity_at(node: Node3D, point: Vector3) -> Vector3:
	var body := node as RigidBody3D
	if body:
		return body.linear_velocity + body.angular_velocity.cross(point - body.global_position)
	var mover := node as CharacterBody3D
	if mover:
		return mover.velocity
	return Vector3.ZERO


func _draw_cable(a: Vector3, b: Vector3) -> void:
	var dir := b - a
	var up := dir.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	_cable.global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3(1, dir.length(), 1)), (a + b) * 0.5)
