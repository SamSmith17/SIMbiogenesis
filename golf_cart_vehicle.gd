extends Node3D

## Golf Cart (Appa) vehicle controller
## Similar to EUC but with driver seat camera position and different characteristics

signal player_entered_range(vehicle: Node3D)
signal player_exited_range(vehicle: Node3D)
signal mounted(player: Node3D)
signal dismounted(player: Node3D)
signal battery_changed(percent: float)
signal battery_depleted()

# ==================== RIDING SETTINGS ====================

## Interaction range - how close player must be to mount
@export var interaction_radius : float = 3.0

## Speed multiplier when riding (affects acceleration)
@export var speed_multiplier : float = 1.5

## Maximum riding speed in m/s (12 mph = 5.36 m/s)
@export var max_speed : float = 5.36

## Camera tilt angle (0 = no tilt for golf cart)
@export var max_camera_tilt : float = 0.0

## How fast the camera tilts
@export var tilt_speed : float = 0.0

## Camera offset from base camera position (negative Y = lower, for sitting)
## Adjust this to move camera: X=left/right, Y=up/down, Z=forward/back
@export var camera_offset : Vector3 = Vector3(0, -0.6, 0)

## Camera shake intensity while riding (more than EUC)
@export var camera_shake_intensity : float = 0.025

## Camera shake speed (frequency)
@export var camera_shake_speed : float = 12.0

## Minimum speed for shake to start (lower than EUC)
@export var min_shake_speed : float = 0.5

## Display name for UI
@export var display_name : String = "Appa"

## Custom interaction prompt
@export var interaction_prompt : String = "Appa, Yip Yip!"

# ==================== STEERING SETTINGS ====================

## Minimum turning radius in meters (larger = wider turns)
@export var min_turn_radius : float = 3.0

## How quickly the cart can change direction (degrees per second at max speed)
@export var max_turn_rate : float = 60.0

## Whether to use cart-style steering (true) or normal walking controls (false)
@export var use_cart_steering : bool = true

## Rotation offset to align cart model with direction of travel (radians)
## -PI/2 = rotate right 90°, PI/2 = rotate left 90°
@export var model_rotation_offset : float = -PI / 2.0

# ==================== BATTERY SETTINGS ====================

## Battery capacity in Watt-hours
@export var battery_capacity_wh : float = 5200.0

## Energy consumption in Wh per mile
@export var wh_per_mile : float = 250.0

## Charging power when plugged in (Watts)
@export var charging_power_watts : float = 1000.0

# ==================== STATE ====================

# Riding state
var is_mounted : bool = false
var current_rider : CharacterBody3D = null
var player_in_range : CharacterBody3D = null
var original_position : Vector3

# Battery and distance state
var battery_wh : float = 5200.0  # Current battery level in Wh
var distance_traveled_meters : float = 0.0  # Total trip distance
var current_speed_mps : float = 0.0  # Current speed in m/s
var last_position : Vector3 = Vector3.ZERO

# Charging state
var is_plugged_in : bool = false
var power_device : Node = null

# Charging visual effect
var charging_light : OmniLight3D = null
var charging_effect_active : bool = false
var charge_pulse_time : float = 0.0

# Power availability tracking
var _solar_ui : Node = null
var _power_available : bool = true

# Interaction area
var interaction_area : Area3D

func _ready() -> void:
	add_to_group("chargeable_vehicles")
	original_position = global_position
	last_position = global_position
	battery_wh = battery_capacity_wh  # Start fully charged
	_setup_interaction_area()
	_setup_charging_light()
	call_deferred("_setup_power_device")
	call_deferred("_connect_to_power_system")

## Connect to the power system to monitor power availability
func _connect_to_power_system() -> void:
	var tree : SceneTree = get_tree()
	if tree == null:
		return
	
	var solar_ui : Node = _find_solar_ui(tree.root)
	if solar_ui != null:
		_solar_ui = solar_ui
		if solar_ui.has_signal("power_availability_changed"):
			solar_ui.power_availability_changed.connect(_on_power_availability_changed)
		if solar_ui.has_method("is_power_available"):
			_power_available = solar_ui.is_power_available()

func _find_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_power_available"):
		return node
	for child in node.get_children():
		var result := _find_solar_ui(child)
		if result != null:
			return result
	return null

func _on_power_availability_changed(available: bool) -> void:
	_power_available = available
	# If power becomes unavailable while charging, pause charging
	if not available and is_plugged_in:
		if power_device != null and is_instance_valid(power_device) and power_device.is_consuming_power():
			power_device.turn_off()

func _setup_interaction_area() -> void:
	# Create Area3D for player detection
	interaction_area = Area3D.new()
	interaction_area.name = "InteractionArea"
	interaction_area.collision_layer = 0
	interaction_area.collision_mask = 1  # Detect player on layer 1
	add_child(interaction_area)
	
	# Create collision shape
	var collision_shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = interaction_radius
	collision_shape.shape = sphere_shape
	interaction_area.add_child(collision_shape)
	
	# Connect signals
	interaction_area.body_entered.connect(_on_body_entered)
	interaction_area.body_exited.connect(_on_body_exited)

func _setup_charging_light() -> void:
	# Create an OmniLight3D for the charging glow effect
	charging_light = OmniLight3D.new()
	charging_light.name = "ChargingLight"
	charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)  # Green
	charging_light.light_energy = 0.0  # Start off
	charging_light.omni_range = 3.0
	charging_light.omni_attenuation = 1.5
	add_child(charging_light)
	# Position at the cart
	charging_light.position = Vector3(0, 0.5, 0)

func _setup_power_device() -> void:
	# Create PowerDevice for charging from main battery system
	var power_device_script = load("res://power_system/core/power_device.gd")
	if power_device_script:
		power_device = Node.new()
		power_device.set_script(power_device_script)
		power_device.name = "PowerDevice"
		add_child(power_device)
		
		power_device.device_name = display_name + " Charger"
		power_device.device_type = 6  # ELECTRONICS
		power_device.rated_power_watts = charging_power_watts
		power_device.standby_power_watts = 0.0
		power_device.is_enabled = true
		power_device.device_id = "golf_cart_charger_%d" % get_instance_id()
		
		# Start with charger off
		power_device.turn_off()

func _process(delta: float) -> void:
	if is_mounted and current_rider != null and is_instance_valid(current_rider):
		# Golf cart follows player but player is positioned at cart origin
		# The cart stays at player position
		global_position = current_rider.global_position
		rotation.y = current_rider.rotation.y + model_rotation_offset
		
		# Track distance and battery usage
		_update_distance_and_battery(delta)
	elif is_plugged_in:
		# Charge the battery when plugged in and not riding
		_update_charging(delta)
	
	# Update charging visual effect
	_update_charging_effect(delta)

func _update_distance_and_battery(delta: float) -> void:
	if current_rider == null:
		return
	
	# Calculate distance traveled this frame
	var current_pos := global_position
	var distance_this_frame := current_pos.distance_to(last_position)
	last_position = current_pos
	
	# Get current speed from rider velocity
	var rider_velocity := current_rider.velocity
	current_speed_mps = Vector2(rider_velocity.x, rider_velocity.z).length()
	
	# Only count distance if actually moving
	if distance_this_frame > 0.01 and current_speed_mps > 0.5:
		distance_traveled_meters += distance_this_frame
		
		# Calculate energy used (Wh per mile * miles traveled)
		var distance_miles := distance_this_frame / 1609.344
		var energy_used := distance_miles * wh_per_mile
		
		# Drain battery
		battery_wh = maxf(0.0, battery_wh - energy_used)
		
		# Emit signal if battery depleted
		if battery_wh <= 0.0:
			battery_depleted.emit()

func _update_charging(delta: float) -> void:
	if not is_plugged_in or is_mounted:
		return
	
	# Use small tolerance for floating point comparison
	var tolerance := 0.01
	if battery_wh >= battery_capacity_wh - tolerance:
		# Fully charged - ensure battery is at max and turn off charger
		if battery_wh < battery_capacity_wh:
			battery_wh = battery_capacity_wh
			battery_changed.emit(100.0)
		if power_device != null and is_instance_valid(power_device) and power_device.is_consuming_power():
			power_device.turn_off()
		return
	
	# Check power availability - can't charge without power
	if not _power_available:
		if power_device != null and is_instance_valid(power_device) and power_device.is_consuming_power():
			power_device.turn_off()
		return
	
	# Make sure power device is on when we have power
	if power_device != null and is_instance_valid(power_device) and not power_device.is_consuming_power():
		power_device.turn_on()
	
	# Get time scale from main scene for realistic charging
	# time_scale represents hours per real second (e.g., 0.5 = 0.5 hours pass per second)
	var time_scale := _get_time_scale()
	
	# delta * time_scale gives us game hours elapsed this frame
	var hours_elapsed := delta * time_scale
	
	# Calculate charge amount (Power * time = energy)
	# charging_power_watts * hours = Wh
	var charge_wh := charging_power_watts * hours_elapsed
	
	var old_battery := battery_wh
	battery_wh = minf(battery_capacity_wh, battery_wh + charge_wh)
	
	# Emit battery changed signal
	battery_changed.emit(get_battery_percent())
	
	# Check if just became fully charged
	if old_battery < battery_capacity_wh and battery_wh >= battery_capacity_wh - tolerance:
		battery_wh = battery_capacity_wh
		if power_device != null and is_instance_valid(power_device):
			power_device.turn_off()

func _get_time_scale() -> float:
	var tree := get_tree()
	if tree == null:
		return 1.0
	
	var root : Window = tree.root
	for child in root.get_children():
		if "time_scale" in child:
			return float(child.time_scale)
	
	return 1.0

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player") and body is CharacterBody3D:
		player_in_range = body
		player_entered_range.emit(self)

func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		player_exited_range.emit(self)

# ==================== PUBLIC API ====================

## Mount the golf cart - called by player
func mount(player: CharacterBody3D) -> bool:
	if is_mounted or player == null:
		return false
	
	# Check if battery is depleted
	if battery_wh <= 0.0:
		return false
	
	is_mounted = true
	current_rider = player
	last_position = global_position
	current_speed_mps = 0.0
	
	# Unplug when mounting
	if is_plugged_in:
		unplug()
	
	# Position cart at player
	global_position = player.global_position
	rotation.y = player.rotation.y
	
	mounted.emit(player)
	return true

## Dismount the golf cart - called by player
func dismount() -> void:
	if not is_mounted or current_rider == null:
		return
	
	var rider := current_rider
	is_mounted = false
	current_rider = null
	current_speed_mps = 0.0
	
	dismounted.emit(rider)

## Plug in for charging
func plug_in() -> void:
	if is_mounted:
		return
	
	is_plugged_in = true
	
	if power_device != null and is_instance_valid(power_device):
		if battery_wh < battery_capacity_wh:
			power_device.turn_on()
		else:
			power_device.turn_off()

## Unplug
func unplug() -> void:
	is_plugged_in = false
	
	if power_device != null and is_instance_valid(power_device):
		power_device.turn_off()

## Check if player can mount
func can_mount() -> bool:
	return not is_mounted and player_in_range != null and battery_wh > 0.0

## Check if a specific player is in range
func is_player_in_range(player: Node3D) -> bool:
	return player_in_range == player

## Get battery percentage
func get_battery_percent() -> float:
	return (battery_wh / battery_capacity_wh) * 100.0

## Get estimated range in miles
func get_estimated_range_miles() -> float:
	return battery_wh / wh_per_mile if wh_per_mile > 0 else 0.0

## Reset trip distance
func reset_trip() -> void:
	distance_traveled_meters = 0.0

## Get the riding parameters for the player
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
		"is_golf_cart": true,  # Flag for special handling
		"use_cart_steering": use_cart_steering,
		"min_turn_radius": min_turn_radius,
		"max_turn_rate": max_turn_rate
	}

## Get custom interaction prompt
func get_interaction_prompt() -> String:
	return interaction_prompt

# ==================== CHARGING VISUAL EFFECTS ====================

## Start the charging visual effect
func start_charging_effect() -> void:
	charging_effect_active = true
	charge_pulse_time = 0.0

## Stop the charging visual effect
func stop_charging_effect() -> void:
	charging_effect_active = false
	if charging_light != null and is_instance_valid(charging_light):
		charging_light.light_energy = 0.0

func _update_charging_effect(delta: float) -> void:
	if charging_light == null or not is_instance_valid(charging_light):
		return
	
	if not charging_effect_active:
		charging_light.light_energy = lerpf(charging_light.light_energy, 0.0, delta * 5.0)
		return
	
	var is_full := battery_wh >= battery_capacity_wh
	
	if is_full:
		# Steady green glow when fully charged
		charging_light.light_energy = lerpf(charging_light.light_energy, 2.0, delta * 3.0)
		charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)
	else:
		# Pulsing green while charging
		charge_pulse_time += delta * 3.0
		var pulse := (sin(charge_pulse_time) + 1.0) / 2.0
		var min_energy := 0.4
		var max_energy := 1.5
		charging_light.light_energy = lerpf(min_energy, max_energy, pulse)
		charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)

