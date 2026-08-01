extends Node3D
class_name FireExtinguisher

## First-person fire extinguisher tool with spray mechanics
## Supports multiple extinguishers for extended spray time

signal ammo_changed(current: float, max: float)

## Base maximum pressure/charge (0.0 to 100.0) per extinguisher
@export var base_max_pressure: float = 100.0

## How many extinguishers the player has collected (multiplies capacity)
var charge_multiplier: int = 1

## Effective maximum pressure (base * multiplier)
var max_pressure: float = 100.0

## Current pressure/charge
var current_pressure: float = 100.0

## Pressure consumption rate per second when spraying
@export var consumption_rate: float = 20.0

## Pressure regeneration rate per second when not spraying
@export var regeneration_rate: float = 5.0

## Minimum pressure needed to spray
@export var min_pressure_to_spray: float = 10.0

## Spray range (meters)
@export var spray_range: float = 5.0

## Spray cone angle (degrees)
@export var spray_cone_angle: float = 30.0

## Damage per second to fire
@export var fire_damage_per_second: float = 25.0

## Whether currently spraying
var is_spraying: bool = false

## Player reference
var player: CharacterBody3D = null

## Camera reference
var camera: Camera3D = null

## Mist particle system
var mist_particles: GPUParticles3D = null

## Spray area for detection
var spray_area: Area3D = null

## Audio stream player for spray sound
var audio_player: AudioStreamPlayer3D = null
var _nearby_fire_candidates: Array[Node3D] = []
var _fire_candidate_refresh_timer: float = 0.0
const _FIRE_CANDIDATE_REFRESH_INTERVAL: float = 0.2

## Visual model / placeholder — see FireExtinguisherPickup.build_extinguisher_visual,
## shared so this and the world pickup never drift out of sync.
var visual_mesh: Node3D = null

func _ready() -> void:
	# Get node references
	mist_particles = get_node_or_null("MistParticles")
	spray_area = get_node_or_null("SprayArea")
	audio_player = get_node_or_null("AudioStreamPlayer3D")

	visual_mesh = FireExtinguisherPickup.build_extinguisher_visual("ExtinguisherModel", Vector3.ONE)
	add_child(visual_mesh)

	# Calculate max pressure based on multiplier
	_update_max_pressure()
	
	# Start with full pressure
	current_pressure = max_pressure

## Set the charge multiplier (number of extinguishers collected)
func set_charge_multiplier(count: int) -> void:
	charge_multiplier = maxi(count, 1)
	_update_max_pressure()
	# Refill to new max
	current_pressure = max_pressure

## Update max pressure based on multiplier
func _update_max_pressure() -> void:
	max_pressure = base_max_pressure * charge_multiplier
	
	# Set up mist particles
	if mist_particles != null:
		mist_particles.emitting = false
	
	# Set up spray area (collision shape should be in scene, but ensure it exists)
	if spray_area != null:
		var has_collision := false
		for child in spray_area.get_children():
			if child is CollisionShape3D:
				has_collision = true
				break
		
		if not has_collision:
			# Create collision shape for spray detection
			var collision_shape := CollisionShape3D.new()
			var shape := SphereShape3D.new()
			shape.radius = spray_range
			collision_shape.shape = shape
			spray_area.add_child(collision_shape)
			
			# Position at spray origin
			collision_shape.position = Vector3(0, 0, -spray_range * 0.5)

func _process(delta: float) -> void:
	if is_spraying:
		# Consume pressure
		current_pressure -= consumption_rate * delta
		current_pressure = maxf(current_pressure, 0.0)
		
		# Stop spraying if out of pressure
		if current_pressure < min_pressure_to_spray:
			stop_using()
	else:
		# Regenerate pressure
		current_pressure += regeneration_rate * delta
		current_pressure = minf(current_pressure, max_pressure)
	
	# Update mist particles based on pressure
	if mist_particles != null:
		var pressure_factor := current_pressure / max_pressure
		if is_spraying and current_pressure >= min_pressure_to_spray:
			mist_particles.emitting = true
			mist_particles.amount = int(lerpf(20, 100, pressure_factor))
		else:
			mist_particles.emitting = false
	
	# Emit ammo changed signal
	ammo_changed.emit(current_pressure, max_pressure)
	
	# Apply fire damage
	if is_spraying:
		_fire_candidate_refresh_timer += delta
		if _fire_candidate_refresh_timer >= _FIRE_CANDIDATE_REFRESH_INTERVAL:
			_fire_candidate_refresh_timer -= _FIRE_CANDIDATE_REFRESH_INTERVAL
			_refresh_fire_candidates()
		_apply_fire_damage(delta)
	else:
		_fire_candidate_refresh_timer = 0.0

func setup(player_ref: CharacterBody3D, camera_ref: Camera3D) -> void:
	player = player_ref
	camera = camera_ref
	
	# Get player's extinguisher count for charge multiplier
	if player != null and player.has_method("get_extinguisher_count"):
		var count : int = player.get_extinguisher_count()
		if count > 0:
			set_charge_multiplier(count)

func cleanup() -> void:
	stop_using()

func get_tool_id() -> String:
	return "fire_extinguisher"

func use() -> void:
	if current_pressure < min_pressure_to_spray:
		return
	
	if not is_spraying:
		is_spraying = true
		_refresh_fire_candidates()
		
		# Play spray sound
		if audio_player != null and not audio_player.playing:
			audio_player.play()

func stop_using() -> void:
	if is_spraying:
		is_spraying = false
		_nearby_fire_candidates.clear()
		
		# Stop spray sound
		if audio_player != null:
			audio_player.stop()

func _apply_fire_damage(delta: float) -> void:
	if camera == null:
		return
	
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	
	for fire_node in _nearby_fire_candidates:
		if not is_instance_valid(fire_node):
			continue
		
		if not fire_node.has_method("apply_extinguisher_damage"):
			continue
		
		# Check if fire is in spray cone
		var fire_pos: Vector3 = fire_node.global_position
		var to_fire: Vector3 = fire_pos - origin
		var distance: float = to_fire.length()
		
		if distance > spray_range:
			continue
		
		# Check angle
		var angle := rad_to_deg(forward.angle_to(to_fire.normalized()))
		if angle > spray_cone_angle:
			continue
		
		# Apply damage
		var damage: float = fire_damage_per_second * delta
		fire_node.apply_extinguisher_damage(damage)

func _refresh_fire_candidates() -> void:
	_nearby_fire_candidates.clear()
	var tree := get_tree()
	if tree == null:
		return
	var fire_nodes := tree.get_nodes_in_group("fire_nodes")
	if fire_nodes.is_empty():
		return
	if camera == null:
		return
	var origin := camera.global_position
	var range_sq := spray_range * spray_range
	for fire_node in fire_nodes:
		if not is_instance_valid(fire_node):
			continue
		var fire_pos: Vector3 = (fire_node as Node3D).global_position
		var to_fire: Vector3 = fire_pos - origin
		if to_fire.length_squared() <= range_sq:
			_nearby_fire_candidates.append(fire_node)

## Get current pressure percentage (0.0 to 1.0)
func get_pressure_percentage() -> float:
	return current_pressure / max_pressure

## Check if extinguisher can spray
func can_spray() -> bool:
	return current_pressure >= min_pressure_to_spray
