extends Node3D

## Skid Steer vehicle controller
## Slow construction vehicle with low shake, based on golf cart mechanics

signal player_entered_range(vehicle: Node3D)
signal player_exited_range(vehicle: Node3D)
signal mounted(player: Node3D)
signal dismounted(player: Node3D)

# ==================== RIDING SETTINGS ====================

## Interaction range - how close player must be to mount
@export var interaction_radius : float = 3.5

## Speed multiplier when riding (affects acceleration)
@export var speed_multiplier : float = 0.8

## Maximum riding speed in m/s (5 mph = 2.24 m/s - slow construction vehicle)
@export var max_speed : float = 2.24

## Camera tilt angle (0 = no tilt)
@export var max_camera_tilt : float = 0.0

## How fast the camera tilts
@export var tilt_speed : float = 0.0

## Camera offset from base camera position (negative Y = lower, for sitting in cab)
## Adjust this to move camera: X=left/right, Y=up/down, Z=forward/back
@export var camera_offset : Vector3 = Vector3(0, 0.3, 0.2)

## Camera shake intensity while riding (lower than Appa for smoother cab)
@export var camera_shake_intensity : float = 0.008

## Camera shake speed (frequency)
@export var camera_shake_speed : float = 8.0

## Minimum speed for shake to start
@export var min_shake_speed : float = 0.3

## Display name for UI
@export var display_name : String = "Skid Steer"

## Custom interaction prompt
@export var interaction_prompt : String = "Drive Skid Steer"

# ==================== STEERING SETTINGS ====================

## Minimum turning radius in meters (skid steers can turn on the spot!)
@export var min_turn_radius : float = 0.5

## How quickly the vehicle can change direction (degrees per second at max speed)
@export var max_turn_rate : float = 90.0

## Whether to use cart-style steering (true) or normal walking controls (false)
@export var use_cart_steering : bool = true

## Rotation offset to align model with direction of travel (radians)
@export var model_rotation_offset : float = 0.0

# ==================== STATE ====================

var is_mounted : bool = false
var current_rider : CharacterBody3D = null
var player_in_range : CharacterBody3D = null
var original_position : Vector3
var current_speed_mps : float = 0.0
var last_position : Vector3 = Vector3.ZERO

# Interaction area
var _interaction_area : Area3D = null
var _collision_shape : CollisionShape3D = null

func _ready() -> void:
	add_to_group("vehicles")
	original_position = global_position
	last_position = global_position
	
	# Setup interaction area for player detection
	_setup_interaction_area()

func _setup_interaction_area() -> void:
	# Check if Area3D already exists as a child
	_interaction_area = get_node_or_null("InteractionArea") as Area3D
	
	if _interaction_area == null:
		# Create new interaction area
		_interaction_area = Area3D.new()
		_interaction_area.name = "InteractionArea"
		add_child(_interaction_area)
	
	# Setup collision shape
	_collision_shape = _interaction_area.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "CollisionShape3D"
		_interaction_area.add_child(_collision_shape)
	
	# Create sphere shape for interaction radius
	var sphere = SphereShape3D.new()
	sphere.radius = interaction_radius
	_collision_shape.shape = sphere
	
	# Setup collision layers
	_interaction_area.collision_layer = 0
	_interaction_area.collision_mask = 1  # Detect player on layer 1
	
	# Connect signals
	if not _interaction_area.body_entered.is_connected(_on_body_entered):
		_interaction_area.body_entered.connect(_on_body_entered)
	if not _interaction_area.body_exited.is_connected(_on_body_exited):
		_interaction_area.body_exited.connect(_on_body_exited)

func _process(delta: float) -> void:
	if not is_mounted or current_rider == null:
		return
	
	# Track speed for UI/shake calculations
	var current_pos := global_position
	var distance := current_pos.distance_to(last_position)
	current_speed_mps = distance / delta if delta > 0 else 0.0
	last_position = current_pos
	
	# Follow the rider (the player controls movement, we just follow)
	global_position = current_rider.global_position
	
	# Rotate to match rider direction with model offset
	rotation.y = current_rider.rotation.y + model_rotation_offset

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player") and body is CharacterBody3D:
		player_in_range = body
		player_entered_range.emit(self)
		
		# Notify player they're near a vehicle
		if body.has_method("on_vehicle_nearby"):
			body.on_vehicle_nearby(self)

func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		player_exited_range.emit(self)
		
		# Notify player they left vehicle range
		if body.has_method("on_vehicle_left_range"):
			body.on_vehicle_left_range(self)

# ==================== PUBLIC API ====================

## Mount the skid steer - called by player
func mount(player: CharacterBody3D) -> bool:
	if is_mounted or player == null:
		return false
	
	is_mounted = true
	current_rider = player
	last_position = global_position
	current_speed_mps = 0.0
	
	# Position vehicle at player
	global_position = player.global_position
	rotation.y = player.rotation.y + model_rotation_offset
	
	mounted.emit(player)
	return true

## Dismount the skid steer - called by player
func dismount() -> void:
	if not is_mounted or current_rider == null:
		return
	
	var rider := current_rider
	is_mounted = false
	current_rider = null
	current_speed_mps = 0.0
	
	dismounted.emit(rider)

## Get riding parameters for player
func get_riding_params() -> Dictionary:
	return {
		"speed_multiplier": speed_multiplier,
		"max_speed": max_speed,
		"max_camera_tilt": max_camera_tilt,
		"tilt_speed": tilt_speed,
		"camera_shake_intensity": camera_shake_intensity,
		"camera_shake_speed": camera_shake_speed,
		"camera_offset": camera_offset,
		"min_shake_speed": min_shake_speed,
		"is_golf_cart": true,  # Use cart-style camera handling
		"use_cart_steering": use_cart_steering,
		"min_turn_radius": min_turn_radius,
		"max_turn_rate": max_turn_rate
	}

## Get custom interaction prompt
func get_interaction_prompt() -> String:
	return interaction_prompt

## Check if player can mount
func can_mount() -> bool:
	return not is_mounted and player_in_range != null

## Get current speed in m/s
func get_speed_mps() -> float:
	return current_speed_mps

## Get current speed in mph
func get_speed_mph() -> float:
	return current_speed_mps * 2.237

