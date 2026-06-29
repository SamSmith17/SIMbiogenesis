@tool
extends StaticBody3D

## Invisible collision platform for walkable surfaces.
## Position and scale this to match your existing geometry.
## Enable show_debug to visualize the collision area in the editor.

@export var platform_size: Vector3 = Vector3(2.0, 0.2, 2.0):
	set(value):
		# Enforce minimum thickness for reliable collision
		value.y = maxf(value.y, 0.1)
		platform_size = value
		_update_shape()

## Extra margin around the platform edges to help bridge small gaps
@export var edge_margin: float = 0.1:
	set(value):
		edge_margin = maxf(value, 0.0)
		_update_shape()

@export var show_debug: bool = false:
	set(value):
		show_debug = value
		_update_debug_visual()

## Collision layer (which layers this platform occupies)
@export_flags_3d_physics var platform_collision_layer: int = 1:
	set(value):
		platform_collision_layer = value
		collision_layer = value

## Collision mask (which layers this platform detects)
@export_flags_3d_physics var platform_collision_mask: int = 1:
	set(value):
		platform_collision_mask = value
		collision_mask = value

var _collision_shape: CollisionShape3D = null
var _debug_mesh: MeshInstance3D = null

func _ready() -> void:
	# Ensure collision layers are set
	collision_layer = platform_collision_layer
	collision_mask = platform_collision_mask
	
	_setup_nodes()
	_update_shape()
	_update_debug_visual()

func _setup_nodes() -> void:
	# Find or create collision shape
	_collision_shape = get_node_or_null("CollisionShape3D")
	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "CollisionShape3D"
		add_child(_collision_shape)
		if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root != null:
			_collision_shape.owner = get_tree().edited_scene_root
	
	# Find or create debug mesh
	_debug_mesh = get_node_or_null("DebugMesh")
	if _debug_mesh == null:
		_debug_mesh = MeshInstance3D.new()
		_debug_mesh.name = "DebugMesh"
		_debug_mesh.visible = false
		add_child(_debug_mesh)
		if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root != null:
			_debug_mesh.owner = get_tree().edited_scene_root

func _update_shape() -> void:
	if _collision_shape == null:
		_setup_nodes()
	if _collision_shape == null:
		return
	
	var box_shape = _collision_shape.shape as BoxShape3D
	if box_shape == null:
		box_shape = BoxShape3D.new()
		_collision_shape.shape = box_shape
	
	# Add edge margin to help bridge gaps between adjacent platforms
	var actual_size = Vector3(
		platform_size.x + edge_margin * 2,
		platform_size.y,
		platform_size.z + edge_margin * 2
	)
	box_shape.size = actual_size
	
	# Center the collision shape vertically so the top surface is at Y=0
	_collision_shape.position = Vector3(0, -platform_size.y / 2.0, 0)
	
	_update_debug_visual()

func _update_debug_visual() -> void:
	if _debug_mesh == null:
		_setup_nodes()
	if _debug_mesh == null:
		return
	
	_debug_mesh.visible = show_debug
	
	if show_debug:
		var box_mesh = BoxMesh.new()
		# Show actual collision size (including margin)
		var actual_size = Vector3(
			platform_size.x + edge_margin * 2,
			platform_size.y,
			platform_size.z + edge_margin * 2
		)
		box_mesh.size = actual_size
		_debug_mesh.mesh = box_mesh
		
		# Match collision shape position
		_debug_mesh.position = Vector3(0, -platform_size.y / 2.0, 0)
		
		# Create semi-transparent green material
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.2, 0.8, 0.2, 0.4)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_debug_mesh.material_override = mat
