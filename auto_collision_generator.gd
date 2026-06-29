extends Node

## Auto-generates collision shapes for mesh instances in the scene.
## Attach to any node and it will recursively add trimesh collision to all
## MeshInstance3D children that don't already have collision.
##
## This eliminates the need to manually place collision platforms!

class_name AutoCollisionGenerator

## Whether to generate collision on ready
@export var auto_generate_on_ready : bool = true

## Only generate collision for meshes with these keywords in their name (empty = all meshes)
## Common keywords: "floor", "platform", "deck", "roof", "stair", "ramp", "ground"
@export var name_filters : Array[String] = []

## Exclude meshes with these keywords in their name
@export var exclude_filters : Array[String] = ["light", "bulb", "halo", "glass", "window"]

## Minimum mesh size to generate collision for (filters out tiny decorative meshes)
@export var min_mesh_size : float = 0.1

## Generate convex collision instead of trimesh (faster but less accurate)
@export var use_convex_collision : bool = false

## For convex collision: simplify the shape
@export var convex_simplify : bool = true

## Print debug info about generated collisions
@export var debug_output : bool = true

var _collision_count : int = 0
var _skipped_count : int = 0

func _ready() -> void:
	if auto_generate_on_ready:
		# Defer to ensure all nodes are loaded
		call_deferred("generate_collision_for_children")

## Generate collision for all mesh children of this node
func generate_collision_for_children() -> void:
	_collision_count = 0
	_skipped_count = 0
	
	if debug_output:
		pass
	
	_generate_collision_recursive(get_parent())
	
	if debug_output:
		pass

## Generate collision for a specific node and its children
func generate_collision_for_node(node: Node) -> void:
	_collision_count = 0
	_skipped_count = 0
	_generate_collision_recursive(node)
	
	if debug_output:
		pass

func _generate_collision_recursive(node: Node) -> void:
	if node == null:
		return
	
	# Check if this is a MeshInstance3D that needs collision
	if node is MeshInstance3D:
		_maybe_add_collision(node as MeshInstance3D)
	
	# Recurse into children
	for child in node.get_children():
		_generate_collision_recursive(child)

func _maybe_add_collision(mesh_instance: MeshInstance3D) -> void:
	# Skip if already has a StaticBody3D parent or sibling with collision
	if _has_collision_nearby(mesh_instance):
		_skipped_count += 1
		return
	
	# Skip if mesh is null
	if mesh_instance.mesh == null:
		_skipped_count += 1
		return
	
	# Check name filters
	var mesh_name := mesh_instance.name.to_lower()
	
	# Check exclude filters first
	for exclude in exclude_filters:
		if mesh_name.contains(exclude.to_lower()):
			_skipped_count += 1
			return
	
	# Check include filters (if any are specified)
	if name_filters.size() > 0:
		var matches_filter := false
		for filter in name_filters:
			if mesh_name.contains(filter.to_lower()):
				matches_filter = true
				break
		if not matches_filter:
			_skipped_count += 1
			return
	
	# Check minimum size
	var aabb := mesh_instance.mesh.get_aabb()
	var size := aabb.size
	if size.x < min_mesh_size and size.y < min_mesh_size and size.z < min_mesh_size:
		_skipped_count += 1
		return
	
	# Generate collision
	_add_collision_to_mesh(mesh_instance)
	_collision_count += 1

func _has_collision_nearby(mesh_instance: MeshInstance3D) -> bool:
	# Check if parent is a StaticBody3D
	var parent := mesh_instance.get_parent()
	if parent is StaticBody3D:
		# Check if there's already a CollisionShape3D sibling
		for sibling in parent.get_children():
			if sibling is CollisionShape3D:
				return true
	
	# Check if there's a StaticBody3D child with collision
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			for grandchild in child.get_children():
				if grandchild is CollisionShape3D:
					return true
	
	return false

func _add_collision_to_mesh(mesh_instance: MeshInstance3D) -> void:
	# Create a StaticBody3D to hold the collision
	var static_body := StaticBody3D.new()
	static_body.name = "AutoCollision"
	
	# Create the collision shape
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	
	# Generate the shape from the mesh
	if use_convex_collision:
		# Convex collision - faster but less accurate
		var shape := mesh_instance.mesh.create_convex_shape(convex_simplify)
		collision_shape.shape = shape
	else:
		# Trimesh collision - accurate but slower
		var shape := mesh_instance.mesh.create_trimesh_shape()
		collision_shape.shape = shape
	
	static_body.add_child(collision_shape)
	
	# Add to the mesh instance
	mesh_instance.add_child(static_body)
	
	if debug_output and _collision_count < 20:
		pass

## Utility: Remove all auto-generated collision from a node tree
func remove_auto_collision(node: Node) -> void:
	if node == null:
		return
	
	# Check if this is an auto-generated collision
	if node.name == "AutoCollision" and node is StaticBody3D:
		node.queue_free()
		return
	
	# Recurse into children (make a copy of array since we might modify it)
	var children := node.get_children().duplicate()
	for child in children:
		remove_auto_collision(child)

