extends Node3D
class_name BurnableComponent

## Component that marks a mesh as burnable and tracks fire damage
## Auto-detects wood materials and handles destruction

signal fire_started(fire_node: Node3D)
signal fire_extinguished(fire_node: Node3D)
signal fully_burned()

## The mesh instance this component is attached to
var mesh_instance: MeshInstance3D = null

## Current burn damage (0.0 to 1.0, where 1.0 = fully destroyed)
var burn_damage: float = 0.0

## Fire nodes currently burning this mesh
var active_fires: Array[Node3D] = []

## Whether this mesh is fully burned (destroyed)
var is_destroyed: bool = false

## Flammability factor (0.0 to 1.0, affects how easily it catches fire)
@export var flammability: float = 1.0

## Material to check for (Wood034/plywood or Mars Aerial Located_14)
var wood_material_path: String = "res://Wood034_1K-JPG/Wood034_1K-JPG.tres"
var plywood_texture_path: String = "res://Imported Models/Mars Aerial/Mars 2026 - Aerial Located_14.jpg"

## Whether this component has been initialized
var _initialized: bool = false

func _ready() -> void:
	# Find the MeshInstance3D parent
	mesh_instance = get_parent() as MeshInstance3D
	if mesh_instance == null:
		# Try to find it in children
		for child in get_children():
			if child is MeshInstance3D:
				mesh_instance = child
				break
	
	if mesh_instance == null:
		push_warning("BurnableComponent: No MeshInstance3D found for %s" % get_path())
		return
	
	# Check if this mesh uses wood material
	if _is_wood_material():
		_initialized = true
		add_to_group("burnable_meshes")
	else:
		# Not wood, disable this component
		set_process(false)
		queue_free()

func _is_wood_material() -> bool:
	if mesh_instance == null:
		return false
	
	# Check surface material overrides
	for i in range(mesh_instance.get_surface_override_material_count()):
		var mat := mesh_instance.get_surface_override_material(i)
		if mat != null:
			if _check_material_for_plywood(mat):
				return true
	
	# Check mesh material
	if mesh_instance.mesh != null:
		var mesh_mat := mesh_instance.mesh.surface_get_material(0)
		if mesh_mat != null:
			if _check_material_for_plywood(mesh_mat):
				return true
	
	return false

func _check_material_for_plywood(mat: Material) -> bool:
	if mat == null:
		return false
	
	# Check material resource path
	var mat_path := mat.resource_path
	if "Wood034" in mat_path or "plywood" in mat_path.to_lower():
		return true
	
	# Check if material uses the plywood texture
	if mat is StandardMaterial3D:
		var std_mat := mat as StandardMaterial3D
		# Check albedo texture
		if std_mat.albedo_texture != null:
			var tex_path := std_mat.albedo_texture.resource_path
			if "Mars 2026 - Aerial Located_14" in tex_path:
				return true
			if "Wood034" in tex_path or "plywood" in tex_path.to_lower():
				return true
	
	return false

func _process(_delta: float) -> void:
	if not _initialized or is_destroyed:
		return
	
	# Update burn damage based on active fires
	if active_fires.size() > 0:
		var damage_rate := 0.1 * active_fires.size()  # Damage per second per fire
		burn_damage = minf(burn_damage + damage_rate * get_process_delta_time(), 1.0)
		
		# Check if fully burned
		if burn_damage >= 1.0 and not is_destroyed:
			_destroy_mesh()

## Add a fire to this burnable mesh
func add_fire(fire_node: Node3D) -> void:
	if fire_node in active_fires:
		return
	
	active_fires.append(fire_node)
	fire_started.emit(fire_node)

## Remove a fire from this burnable mesh
func remove_fire(fire_node: Node3D) -> void:
	var index := active_fires.find(fire_node)
	if index >= 0:
		active_fires.remove_at(index)
		fire_extinguished.emit(fire_node)

## Get the position where a fire should spawn (center of mesh)
func get_fire_spawn_position() -> Vector3:
	if mesh_instance == null:
		return global_position
	
	# Get mesh AABB center
	var aabb := mesh_instance.get_aabb()
	var center := mesh_instance.to_global(aabb.get_center())
	return center

## Destroy the mesh (fade out and remove)
func _destroy_mesh() -> void:
	if is_destroyed:
		return
	
	is_destroyed = true
	fully_burned.emit()
	
	# Remove all fires
	for fire in active_fires.duplicate():
		if is_instance_valid(fire):
			fire.queue_free()
	active_fires.clear()
	
	# Fade out and remove collision
	if mesh_instance != null:
		# Create a tween to fade out
		var tween := create_tween()
		tween.set_parallel(true)
		
		# Fade material
		if mesh_instance.material_override == null:
			mesh_instance.material_override = mesh_instance.get_surface_override_material(0)
		if mesh_instance.material_override != null:
			var mat := mesh_instance.material_override.duplicate()
			mesh_instance.material_override = mat
			tween.tween_method(_set_material_alpha, 1.0, 0.0, 2.0)
		
		# Remove collision
		_remove_collision()
		
		# Remove mesh after fade
		tween.tween_callback(func(): 
			if is_instance_valid(mesh_instance):
				mesh_instance.queue_free()
		).set_delay(2.0)

func _set_material_alpha(alpha: float) -> void:
	if mesh_instance == null or mesh_instance.material_override == null:
		return
	
	var mat := mesh_instance.material_override as StandardMaterial3D
	if mat != null:
		var albedo := mat.albedo_color
		albedo.a = alpha
		mat.albedo_color = albedo

func _remove_collision() -> void:
	if mesh_instance == null:
		return
	
	# Find and remove StaticBody3D children (auto-generated collision)
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			child.queue_free()

