@tool
extends StaticBody3D

## Invisible collision ramp for smooth walkable slopes.
## Use this for ramps/inclines where you want smooth walking (not stairs).
## The ramp slopes up in the -Z direction (forward in Godot).

@export_group("Ramp Dimensions")
## Width of the ramp
@export var ramp_width: float = 2.0:
	set(value):
		ramp_width = maxf(value, 0.1)
		_update_shape()

## Horizontal length of the ramp
@export var ramp_length: float = 3.0:
	set(value):
		ramp_length = maxf(value, 0.1)
		_update_shape()

## Height at the top of the ramp (low end is at Y=0)
@export var ramp_height: float = 1.0:
	set(value):
		ramp_height = maxf(value, 0.0)
		_update_shape()

## Thickness of the ramp collision
@export var ramp_thickness: float = 0.2:
	set(value):
		ramp_thickness = maxf(value, 0.05)
		_update_shape()

@export_group("Visual")
## Show collision geometry for alignment
@export var show_debug: bool = false:
	set(value):
		show_debug = value
		_update_debug_visual()

## Debug color
@export var debug_color: Color = Color(0.2, 0.4, 0.9, 0.4)

@export_group("Collision")
## Collision layer
@export_flags_3d_physics var ramp_collision_layer: int = 1:
	set(value):
		ramp_collision_layer = value
		collision_layer = value

## Collision mask
@export_flags_3d_physics var ramp_collision_mask: int = 1:
	set(value):
		ramp_collision_mask = value
		collision_mask = value

var _collision_shape: CollisionShape3D = null
var _debug_mesh: MeshInstance3D = null

func _ready() -> void:
	collision_layer = ramp_collision_layer
	collision_mask = ramp_collision_mask
	_setup_nodes()
	_update_shape()
	_update_debug_visual()

func _setup_nodes() -> void:
	_collision_shape = get_node_or_null("CollisionShape3D")
	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "CollisionShape3D"
		add_child(_collision_shape)
		if Engine.is_editor_hint() and is_inside_tree() and get_tree().edited_scene_root != null:
			_collision_shape.owner = get_tree().edited_scene_root
	
	_debug_mesh = get_node_or_null("DebugMesh")
	if _debug_mesh == null:
		_debug_mesh = MeshInstance3D.new()
		_debug_mesh.name = "DebugMesh"
		_debug_mesh.visible = false
		add_child(_debug_mesh)
		if Engine.is_editor_hint() and is_inside_tree() and get_tree().edited_scene_root != null:
			_debug_mesh.owner = get_tree().edited_scene_root

func _update_shape() -> void:
	if _collision_shape == null:
		_setup_nodes()
	if _collision_shape == null:
		return
	
	var half_width = ramp_width / 2.0
	var half_length = ramp_length / 2.0
	
	# Create a wedge shape using ConvexPolygonShape3D
	# Low end at +Z, high end at -Z
	var points = PackedVector3Array([
		# Bottom face
		Vector3(-half_width, -ramp_thickness, -half_length),
		Vector3(half_width, -ramp_thickness, -half_length),
		Vector3(-half_width, -ramp_thickness, half_length),
		Vector3(half_width, -ramp_thickness, half_length),
		# Top face (sloped)
		Vector3(-half_width, ramp_height, -half_length),
		Vector3(half_width, ramp_height, -half_length),
		Vector3(-half_width, 0, half_length),
		Vector3(half_width, 0, half_length),
	])
	
	var convex_shape = ConvexPolygonShape3D.new()
	convex_shape.points = points
	_collision_shape.shape = convex_shape
	
	_update_debug_visual()

func _update_debug_visual() -> void:
	if _debug_mesh == null:
		_setup_nodes()
	if _debug_mesh == null:
		return
	
	_debug_mesh.visible = show_debug
	
	if not show_debug:
		_debug_mesh.mesh = null
		return
	
	var half_width = ramp_width / 2.0
	var half_length = ramp_length / 2.0
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = debug_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	
	# Top surface (the ramp slope)
	st.add_vertex(Vector3(-half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(-half_width, 0, half_length))
	
	st.add_vertex(Vector3(half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(half_width, 0, half_length))
	st.add_vertex(Vector3(-half_width, 0, half_length))
	
	# Left side
	st.add_vertex(Vector3(-half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(-half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(-half_width, -ramp_thickness, half_length))
	
	st.add_vertex(Vector3(-half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(-half_width, 0, half_length))
	st.add_vertex(Vector3(-half_width, -ramp_thickness, half_length))
	
	# Right side
	st.add_vertex(Vector3(half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(half_width, -ramp_thickness, half_length))
	st.add_vertex(Vector3(half_width, ramp_height, -half_length))
	
	st.add_vertex(Vector3(half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(half_width, -ramp_thickness, half_length))
	st.add_vertex(Vector3(half_width, 0, half_length))
	
	# Back (high end)
	st.add_vertex(Vector3(-half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(-half_width, ramp_height, -half_length))
	
	st.add_vertex(Vector3(half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(half_width, ramp_height, -half_length))
	st.add_vertex(Vector3(-half_width, ramp_height, -half_length))
	
	# Front (low end)
	st.add_vertex(Vector3(-half_width, -ramp_thickness, half_length))
	st.add_vertex(Vector3(-half_width, 0, half_length))
	st.add_vertex(Vector3(half_width, -ramp_thickness, half_length))
	
	st.add_vertex(Vector3(half_width, -ramp_thickness, half_length))
	st.add_vertex(Vector3(-half_width, 0, half_length))
	st.add_vertex(Vector3(half_width, 0, half_length))
	
	# Bottom
	st.add_vertex(Vector3(-half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(-half_width, -ramp_thickness, half_length))
	st.add_vertex(Vector3(half_width, -ramp_thickness, -half_length))
	
	st.add_vertex(Vector3(half_width, -ramp_thickness, -half_length))
	st.add_vertex(Vector3(-half_width, -ramp_thickness, half_length))
	st.add_vertex(Vector3(half_width, -ramp_thickness, half_length))
	
	_debug_mesh.mesh = st.commit()

## Get the ramp angle in degrees
func get_angle_degrees() -> float:
	return rad_to_deg(atan2(ramp_height, ramp_length))
