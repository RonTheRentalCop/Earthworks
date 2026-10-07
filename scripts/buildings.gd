extends RefCounted
## Spawns destructible structures out of stacked rigid-body blocks.
## Blocks start asleep so a standing town costs almost nothing until you hit it.

const BLOCK := Vector3(1.0, 0.6, 0.5)
const BLOCK_MASS := 40.0
const ROOF_MASS := 120.0
const DEBRIS_LAYER := 4
const DEBRIS_MASK := 1 | 2 | 4 | 8
const GAP := 0.001

const STYLES := {
	"brick": [Color(0.72, 0.32, 0.22), Color(0.64, 0.27, 0.19), Color(0.78, 0.38, 0.26)],
	"concrete": [Color(0.72, 0.72, 0.7), Color(0.64, 0.64, 0.62), Color(0.79, 0.78, 0.75)],
}
const ROOF := Color(0.36, 0.3, 0.28)

static var _materials := {}
static var _shapes := {}
static var _meshes := {}


## A box-shaped building with a plank roof. `base` is the centre of the floor.
static func house(parent: Node3D, base: Vector3, nx: int, nz: int, rows: int, style: String) -> Array[RigidBody3D]:
	var bodies: Array[RigidBody3D] = []
	var colors: Array = STYLES[style]
	var hx := nx * 0.5
	var hz := nz * 0.5
	for row in rows:
		var y := base.y + BLOCK.y * (row + 0.5) + GAP * row
		# Alternate which walls own the corners so rows interlock like real brickwork
		# (this also staggers the joints); straight stacks topple as soon as they wake.
		var odd := row % 2
		for bx in nx - odd:
			var x := base.x - hx + 0.5 + odd * 0.5 + bx
			var color: Color = colors[(row * 7 + bx * 3) % colors.size()]
			bodies.append(_block(parent, BLOCK, Vector3(x, y, base.z - hz + BLOCK.z * 0.5), 0.0, color, BLOCK_MASS))
			color = colors[(row * 5 + bx * 2 + 1) % colors.size()]
			bodies.append(_block(parent, BLOCK, Vector3(x, y, base.z + hz - BLOCK.z * 0.5), 0.0, color, BLOCK_MASS))
		for bz in nz - 1 + odd:
			var z := base.z - hz + 1.0 - odd * 0.5 + bz
			var color: Color = colors[(row * 3 + bz) % colors.size()]
			bodies.append(_block(parent, BLOCK, Vector3(base.x - hx + BLOCK.z * 0.5, y, z), PI * 0.5, color, BLOCK_MASS))
			color = colors[(row + bz * 2 + 2) % colors.size()]
			bodies.append(_block(parent, BLOCK, Vector3(base.x + hx - BLOCK.z * 0.5, y, z), PI * 0.5, color, BLOCK_MASS))
	var roof_size := Vector3(nx, 0.25, 1.0)
	var roof_y := base.y + rows * (BLOCK.y + GAP) + roof_size.y * 0.5 + GAP
	for k in nz:
		bodies.append(_block(parent, roof_size, Vector3(base.x, roof_y, base.z - hz + 0.5 + k), 0.0, ROOF, ROOF_MASS))
	return bodies


## A straight free-standing wall along the X axis.
static func wall(parent: Node3D, base: Vector3, length: int, rows: int, style: String) -> Array[RigidBody3D]:
	var bodies: Array[RigidBody3D] = []
	var colors: Array = STYLES[style]
	for row in rows:
		var y := base.y + BLOCK.y * (row + 0.5) + GAP * row
		for bx in length:
			var color: Color = colors[(row * 7 + bx * 3) % colors.size()]
			var x := base.x - length * 0.5 + 0.5 + bx
			bodies.append(_block(parent, BLOCK, Vector3(x, y, base.z), 0.0, color, BLOCK_MASS))
	return bodies


static func _block(parent: Node3D, size: Vector3, pos: Vector3, yaw: float, color: Color, mass: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass
	body.collision_layer = DEBRIS_LAYER
	body.collision_mask = DEBRIS_MASK
	var shape := CollisionShape3D.new()
	shape.shape = _box_shape(size)
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.mesh = _box_mesh(size)
	mesh.material_override = _material(color)
	body.add_child(mesh)
	body.position = pos
	body.rotation.y = yaw
	parent.add_child(body)
	body.sleeping = true
	return body


static func _box_shape(size: Vector3) -> BoxShape3D:
	if not _shapes.has(size):
		var shape := BoxShape3D.new()
		shape.size = size
		_shapes[size] = shape
	return _shapes[size]


static func _box_mesh(size: Vector3) -> BoxMesh:
	if not _meshes.has(size):
		var mesh := BoxMesh.new()
		mesh.size = size
		_meshes[size] = mesh
	return _meshes[size]


static func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.9
		_materials[color] = mat
	return _materials[color]
