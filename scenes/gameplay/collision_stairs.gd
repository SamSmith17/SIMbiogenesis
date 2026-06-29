@tool
extends StaticBody3D

## Invisible staircase collision - creates actual step geometry for reliable climbing.
## Unlike angled planks, stepped collision works perfectly with CharacterBody3D.
## 
## USAGE:
## - Position the node at the bottom of your stairs (at floor level)
## - The stairs will build upward in the -Z direction (forward)
## - Adjust total_height, total_length, and stair_width to match your geometry
## - Use show_debug to visualize and align with your stair mesh

@export_group("Stair Dimensions")
## Total height of the staircase from bottom to top
@export var total_height: float = 2.0:
	set(value):
		total_height = maxf(value, 0.1)
		_rebuild_stairs()

## Total horizontal length of the staircase
@export var total_length: float = 3.0:
	set(value):
		total_length = maxf(value, 0.1)
		_rebuild_stairs()

## Width of the staircase
@export var stair_width: float = 1.0:
	set(value):
		stair_width = maxf(value, 0.1)
		_rebuild_stairs()

## Number of steps (auto-calculated if 0)
@export var step_count: int = 0:
	set(value):
		step_count = maxi(value, 0)
		_rebuild_stairs()

## Extra overlap at the top to connect with platforms (prevents falling through gaps)
@export var top_overlap: float = 0.3:
	set(value):
		top_overlap = maxf(value, 0.0)
		_rebuild_stairs()

## Extra overlap at the bottom to connect with lower floor
@export var bottom_overlap: float = 0.1:
	set(value):
		bottom_overlap = maxf(value, 0.0)
		_rebuild_stairs()

@export_group("Visual")
## Show collision geometry for alignment
@export var show_debug: bool = false:
	set(value):
		show_debug = value
		_update_debug_visual()

## Debug color
@export var debug_color: Color = Color(0.9, 0.6, 0.2, 0.4)

@export_group("Collision")
## Collision layer
@export_flags_3d_physics var stair_collision_layer: int = 1:
	set(value):
		stair_collision_layer = value
		collision_layer = value

## Collision mask  
@export_flags_3d_physics var stair_collision_mask: int = 1:
	set(value):
		stair_collision_mask = value
		collision_mask = value

# Internal
var _collision_container: Node3D = null
var _debug_mesh: MeshInstance3D = null
const MAX_STEP_HEIGHT: float = 0.3  # Maximum comfortable step height
const MIN_STEP_HEIGHT: float = 0.1  # Minimum step height

func _ready() -> void:
	collision_layer = stair_collision_layer
	collision_mask = stair_collision_mask
	_setup_nodes()
	_rebuild_stairs()

func _setup_nodes() -> void:
	# Container for step collision shapes
	_collision_container = get_node_or_null("StepCollisions")
	if _collision_container == null:
		_collision_container = Node3D.new()
		_collision_container.name = "StepCollisions"
		add_child(_collision_container)
		if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root != null:
			_collision_container.owner = get_tree().edited_scene_root
	
	# Debug mesh
	_debug_mesh = get_node_or_null("DebugMesh")
	if _debug_mesh == null:
		_debug_mesh = MeshInstance3D.new()
		_debug_mesh.name = "DebugMesh"
		_debug_mesh.visible = false
		add_child(_debug_mesh)
		if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root != null:
			_debug_mesh.owner = get_tree().edited_scene_root

func _rebuild_stairs() -> void:
	if not is_inside_tree():
		return
	
	_setup_nodes()
	
	# Clear existing collision shapes
	for child in _collision_container.get_children():
		child.queue_free()
	
	# Calculate number of steps
	var num_steps = step_count
	if num_steps <= 0:
		# Auto-calculate based on comfortable step height
		num_steps = ceili(total_height / MAX_STEP_HEIGHT)
		num_steps = maxi(num_steps, 2)  # At least 2 steps
	
	var step_height = total_height / float(num_steps)
	var step_depth = total_length / float(num_steps)
	
	# Create each step as a box collision
	for i in range(num_steps):
		var step_collision = CollisionShape3D.new()
		step_collision.name = "Step_%d" % i
		
		var box = BoxShape3D.new()
		# Each step is the full width, the step height tall, and step depth deep
		# Make steps overlap to prevent gaps between them
		var extra_depth = 0.05  # Overlap between steps
		
		# First step extends backward (bottom_overlap), last step extends forward (top_overlap)
		var front_extension = top_overlap if i == num_steps - 1 else extra_depth
		var back_extension = bottom_overlap if i == 0 else extra_depth
		
		box.size = Vector3(stair_width, step_height + 0.02, step_depth + front_extension + back_extension)
		step_collision.shape = box
		
		# Position: X centered, Y at half step height above current level, Z adjusted for extensions
		var step_y = step_height * i + step_height / 2.0
		var step_z = -step_depth * i - step_depth / 2.0 - (front_extension - back_extension) / 2.0
		step_collision.position = Vector3(0, step_y, step_z)
		
		_collision_container.add_child(step_collision)
		if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root != null:
			step_collision.owner = get_tree().edited_scene_root
	
	_update_debug_visual()

func _update_debug_visual() -> void:
	if _debug_mesh == null:
		return
	
	_debug_mesh.visible = show_debug
	
	if not show_debug:
		_debug_mesh.mesh = null
		return
	
	# Build a mesh showing all the steps
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = debug_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	
	var num_steps = step_count
	if num_steps <= 0:
		num_steps = ceili(total_height / MAX_STEP_HEIGHT)
		num_steps = maxi(num_steps, 2)
	
	var step_height = total_height / float(num_steps)
	var step_depth = total_length / float(num_steps)
	var half_width = stair_width / 2.0
	
	for i in range(num_steps):
		var base_y = step_height * i
		var top_y = base_y + step_height
		var front_z = -step_depth * i
		var back_z = front_z - step_depth
		
		# Top face of step
		_add_quad(st, 
			Vector3(-half_width, top_y, front_z),
			Vector3(half_width, top_y, front_z),
			Vector3(half_width, top_y, back_z),
			Vector3(-half_width, top_y, back_z))
		
		# Front face (riser)
		_add_quad(st,
			Vector3(-half_width, base_y, front_z),
			Vector3(half_width, base_y, front_z),
			Vector3(half_width, top_y, front_z),
			Vector3(-half_width, top_y, front_z))
		
		# Left side
		_add_quad(st,
			Vector3(-half_width, base_y, back_z),
			Vector3(-half_width, base_y, front_z),
			Vector3(-half_width, top_y, front_z),
			Vector3(-half_width, top_y, back_z))
		
		# Right side
		_add_quad(st,
			Vector3(half_width, base_y, front_z),
			Vector3(half_width, base_y, back_z),
			Vector3(half_width, top_y, back_z),
			Vector3(half_width, top_y, front_z))
	
	_debug_mesh.mesh = st.commit()

func _add_quad(st: SurfaceTool, v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3) -> void:
	# Triangle 1
	st.add_vertex(v1)
	st.add_vertex(v2)
	st.add_vertex(v3)
	# Triangle 2
	st.add_vertex(v1)
	st.add_vertex(v3)
	st.add_vertex(v4)

## Get the calculated step dimensions
func get_step_dimensions() -> Dictionary:
	var num_steps = step_count
	if num_steps <= 0:
		num_steps = ceili(total_height / MAX_STEP_HEIGHT)
		num_steps = maxi(num_steps, 2)
	
	return {
		"num_steps": num_steps,
		"step_height": total_height / float(num_steps),
		"step_depth": total_length / float(num_steps)
	}
