extends Node3D
## A rocket: flies straight (a little drop), trailing smoke, and blows up on whatever it
## hits first: the ground, a machine, a tree or a building. The host's rockets do the
## damage (main.explode); joining players see a copy that just vanishes when it lands.

const SPEED_DROP := 2.5  # m/s2 of gravity on it
const LIFETIME := 6.0
const MASK := 1 | 2 | 4 | 8 | 32 | 64 | 128

var velocity := Vector3.ZERO
var shooter: Node3D
var harmless := false  # a joining player's copy
var main: Node
var _age := 0.0
var _trail: GPUParticles3D


func _ready() -> void:
	var body := MeshInstance3D.new()
	var tube := CylinderMesh.new()
	tube.top_radius = 0.06
	tube.bottom_radius = 0.06
	tube.height = 0.9
	tube.radial_segments = 8
	body.mesh = tube
	body.rotation.x = PI * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.32, 0.3)
	body.material_override = mat
	add_child(body)
	var flame := MeshInstance3D.new()
	var glow := SphereMesh.new()
	glow.radius = 0.14
	glow.height = 0.28
	flame.mesh = glow
	var hot := StandardMaterial3D.new()
	hot.albedo_color = Color(1.0, 0.6, 0.15)
	hot.emission_enabled = true
	hot.emission = Color(1.0, 0.5, 0.1)
	hot.emission_energy_multiplier = 4.0
	hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame.material_override = hot
	flame.position = Vector3(0, 0, 0.5)
	add_child(flame)
	_trail = GPUParticles3D.new()
	_trail.amount = 60
	_trail.lifetime = 1.2
	_trail.local_coords = false
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 1, 0)
	process.spread = 20.0
	process.initial_velocity_min = 0.3
	process.initial_velocity_max = 1.0
	process.gravity = Vector3(0, 0.6, 0)
	process.scale_min = 0.5
	process.scale_max = 1.4
	_trail.process_material = process
	var puff := SphereMesh.new()
	puff.radius = 0.18
	puff.height = 0.36
	puff.radial_segments = 6
	puff.rings = 3
	var smoke := StandardMaterial3D.new()
	smoke.albedo_color = Color(0.8, 0.8, 0.8, 0.5)
	smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.material = smoke
	_trail.draw_pass_1 = puff
	_trail.position = Vector3(0, 0, 0.5)
	add_child(_trail)
	_face()


func _face() -> void:
	if velocity.length() > 0.1:
		look_at(global_position + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.99 else Vector3.RIGHT)


func _physics_process(delta: float) -> void:
	_age += delta
	velocity.y -= SPEED_DROP * delta
	var from := global_position
	var to := from + velocity * delta
	var hit := {}
	var query := PhysicsRayQueryParameters3D.create(from, to, MASK)
	if is_instance_valid(shooter) and shooter is CollisionObject3D:
		query.exclude = [(shooter as CollisionObject3D).get_rid()]
	hit = get_world_3d().direct_space_state.intersect_ray(query)
	var at := to
	var struck: Node = null
	if not hit.is_empty():
		at = hit.position
		struck = hit.collider
	elif main and to.y <= main.terrain.get_height(to.x, to.z):
		at = Vector3(to.x, main.terrain.get_height(to.x, to.z), to.z)
	elif _age < LIFETIME:
		global_position = to
		_face()
		return
	if not harmless and main and _age < LIFETIME:
		main.explode(at, struck, shooter)
	_trail.emitting = false
	_trail.reparent(get_parent(), true)  # the smoke trail lingers a moment
	get_tree().create_timer(1.5).timeout.connect(_trail.queue_free)
	queue_free()
