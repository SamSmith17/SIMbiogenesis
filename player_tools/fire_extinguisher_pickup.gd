extends Node3D
class_name FireExtinguisherPickup

## A world-placed fire extinguisher that can be picked up by the player
## When grabbed, adds to the player's extinguisher count (increases spray time)

signal player_entered
signal player_exited
signal grabbed(by_player: Node3D)

## Display name for interaction prompt
@export var display_name : String = "Fire Extinguisher"

## Has this extinguisher been grabbed?
var is_grabbed : bool = false

## Reference to player in range
var player_in_range : Node3D = null

## Detection area
var detection_area : Area3D = null

## Visual mesh
var visual_mesh : Node3D = null

func _ready() -> void:
	_create_detection_area()
	_setup_visual()

func _create_detection_area() -> void:
	detection_area = Area3D.new()
	detection_area.name = "DetectionArea"
	detection_area.collision_layer = 0
	detection_area.collision_mask = 2  # Player layer
	
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 2.0  # Interaction range
	shape.shape = sphere
	detection_area.add_child(shape)
	
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)
	
	add_child(detection_area)

func _setup_visual() -> void:
	# Try to find existing mesh child or load the extinguisher model
	visual_mesh = get_node_or_null("ExtinguisherModel")
	
	if visual_mesh == null:
		# Try to load the GLB model
		var model_scene := load("res://Imported Models/Fire Extinguisher/FireExtinguisher.glb") as PackedScene
		if model_scene != null:
			visual_mesh = model_scene.instantiate()
			visual_mesh.name = "ExtinguisherModel"
			visual_mesh.scale = Vector3(0.8, 0.8, 0.8)  # Slightly smaller than handheld
			add_child(visual_mesh)
		else:
			# Fallback: create a simple cylinder
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.name = "ExtinguisherModel"
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.1
			cylinder.bottom_radius = 0.1
			cylinder.height = 0.5
			mesh_instance.mesh = cylinder
			
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.8, 0.1, 0.1)  # Red
			mesh_instance.material_override = mat
			
			add_child(mesh_instance)
			visual_mesh = mesh_instance

func _on_body_entered(body: Node3D) -> void:
	if is_grabbed:
		return
	
	# Check if it's the player
	if body.is_in_group("player") or body.name == "Player":
		player_in_range = body
		player_entered.emit()
		
		# Notify player
		if body.has_method("on_extinguisher_nearby"):
			body.on_extinguisher_nearby(self)

func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		player_exited.emit()
		
		# Notify player
		if body.has_method("on_extinguisher_left_range"):
			body.on_extinguisher_left_range(self)

## Called when player grabs this extinguisher
func grab() -> bool:
	if is_grabbed:
		return false
	
	is_grabbed = true
	grabbed.emit(player_in_range)
	
	# Hide the visual
	if visual_mesh != null:
		visual_mesh.visible = false
	
	# Disable detection
	if detection_area != null:
		detection_area.set_deferred("monitoring", false)
	
	return true

## Get interaction prompt text
func get_interaction_prompt() -> String:
	return "Grab " + display_name

## Check if player is in range
func is_player_nearby() -> bool:
	return player_in_range != null and not is_grabbed

