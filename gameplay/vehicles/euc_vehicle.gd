extends Node3D

## Electric Unicycle (EUC) vehicle controller
## Allows player to mount/dismount and ride with increased speed
## Tracks battery usage and distance, can charge from main power system

signal player_entered_range(euc: Node3D)
signal player_exited_range(euc: Node3D)
signal mounted(player: Node3D)
signal dismounted(player: Node3D)
signal battery_changed(percent: float)
signal battery_depleted()
signal shorted_out()
signal repaired()

# ==================== RIDING SETTINGS ====================

## Interaction range - how close player must be to mount
@export var interaction_radius : float = 2.0

## Speed multiplier when riding
@export var speed_multiplier : float = 3.0

## Maximum riding speed in m/s
@export var max_speed : float = 25.0

## Camera tilt angle in degrees when turning
@export var max_camera_tilt : float = 25.0

## How fast the camera tilts
@export var tilt_speed : float = 5.0

## Vertical offset when mounted (0 = at player's feet/ground level)
@export var mount_height_offset : float = 0.0

## Camera shake intensity while riding
@export var camera_shake_intensity : float = 0.015

## Camera shake speed (frequency)
@export var camera_shake_speed : float = 15.0

## Display name for UI
@export var display_name : String = "Electric Unicycle"

# ==================== BATTERY SETTINGS ====================

## Battery capacity in Watt-hours
@export var battery_capacity_wh : float = 1000.0

## Energy consumption in Wh per mile
@export var wh_per_mile : float = 30.0

## Charging power when plugged in (Watts)
@export var charging_power_watts : float = 500.0

# ==================== STATE ====================

# Riding state
var is_mounted : bool = false
var current_rider : CharacterBody3D = null
var player_in_range : CharacterBody3D = null
var original_position : Vector3

# Battery and distance state
var battery_wh : float = 1000.0  # Current battery level in Wh
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

# Rain damage system
const RAIN_DAMAGE_THRESHOLD_INCHES : float = 0.25  # Rain amount that shorts the EUC
var is_shorted : bool = false  # Whether EUC is shorted and needs repair
var rain_exposure_inches : float = 0.0  # Rain accumulated while exposed
var cover_raycast : RayCast3D = null  # Raycast to detect overhead cover
var short_circuit_light : OmniLight3D = null  # Flash effect
var smoke_particles : GPUParticles3D = null  # Smoke effect

# Interaction area
var interaction_area : Area3D

func _ready() -> void:
	add_to_group("chargeable_vehicles")
	original_position = global_position
	last_position = global_position
	battery_wh = battery_capacity_wh  # Start fully charged
	_setup_interaction_area()
	_setup_charging_light()
	_setup_rain_damage_system()
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

func _setup_charging_light() -> void:
	# Create an OmniLight3D for the charging glow effect
	charging_light = OmniLight3D.new()
	charging_light.name = "ChargingLight"
	charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)  # Green
	charging_light.light_energy = 0.0  # Start off
	charging_light.omni_range = 2.0
	charging_light.omni_attenuation = 1.5
	add_child(charging_light)
	# Position slightly above the EUC
	charging_light.position = Vector3(0, 0.3, 0)

func _setup_rain_damage_system() -> void:
	# Create raycast pointing straight up to detect overhead cover
	cover_raycast = RayCast3D.new()
	cover_raycast.name = "CoverRaycast"
	cover_raycast.target_position = Vector3(0, 50, 0)  # Check 50m up for cover
	cover_raycast.collision_mask = 0xFFFFFFFF  # Detect all collision layers
	cover_raycast.enabled = true
	add_child(cover_raycast)
	
	# Create short circuit flash light
	short_circuit_light = OmniLight3D.new()
	short_circuit_light.name = "ShortCircuitLight"
	short_circuit_light.light_color = Color(1.0, 0.9, 0.5, 1.0)  # Bright yellow-white
	short_circuit_light.light_energy = 0.0  # Start off
	short_circuit_light.omni_range = 8.0
	short_circuit_light.omni_attenuation = 1.0
	add_child(short_circuit_light)
	short_circuit_light.position = Vector3(0, 0.5, 0)
	
	# Create smoke particles
	smoke_particles = GPUParticles3D.new()
	smoke_particles.name = "SmokeParticles"
	smoke_particles.emitting = false
	smoke_particles.amount = 50
	smoke_particles.lifetime = 2.0
	smoke_particles.one_shot = true
	smoke_particles.explosiveness = 0.8
	
	# Create particle material
	var particle_material := ParticleProcessMaterial.new()
	particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	particle_material.emission_sphere_radius = 0.2
	particle_material.direction = Vector3(0, 1, 0)
	particle_material.spread = 30.0
	particle_material.initial_velocity_min = 0.5
	particle_material.initial_velocity_max = 1.5
	particle_material.gravity = Vector3(0, 0.2, 0)  # Smoke rises slowly
	particle_material.scale_min = 0.3
	particle_material.scale_max = 0.8
	particle_material.color = Color(0.3, 0.3, 0.3, 0.8)  # Gray smoke
	
	# Color ramp for smoke fading
	var color_ramp := Gradient.new()
	color_ramp.add_point(0.0, Color(0.4, 0.4, 0.4, 0.9))
	color_ramp.add_point(0.5, Color(0.5, 0.5, 0.5, 0.5))
	color_ramp.add_point(1.0, Color(0.6, 0.6, 0.6, 0.0))
	var color_texture := GradientTexture1D.new()
	color_texture.gradient = color_ramp
	particle_material.color_ramp = color_texture
	
	smoke_particles.process_material = particle_material
	
	# Create mesh for smoke particles (simple quad)
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(0.5, 0.5)
	smoke_particles.draw_pass_1 = quad_mesh
	
	add_child(smoke_particles)
	smoke_particles.position = Vector3(0, 0.3, 0)

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
		power_device.device_id = "euc_charger_%d" % get_instance_id()
		
		# Start with charger off
		power_device.turn_off()

func _process(delta: float) -> void:
	if is_mounted and current_rider != null and is_instance_valid(current_rider):
		# Follow the player when mounted
		global_position = current_rider.global_position + Vector3(0, mount_height_offset, 0)
		# Match player's Y rotation + 90 degrees so EUC faces forward
		rotation.y = current_rider.rotation.y + deg_to_rad(90.0)
		
		# Track distance and battery usage
		_update_distance_and_battery(delta)
	elif is_plugged_in:
		# Charge the battery when plugged in and not riding
		_update_charging(delta)
	
	# Update charging visual effect
	_update_charging_effect(delta)
	
	# Update rain damage system (only when not mounted - rider provides some cover)
	if not is_mounted:
		_update_rain_damage(delta)
	
	# Update short circuit flash effect
	_update_short_circuit_effect(delta)

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
	
	# Only count distance if actually moving (avoid floating point drift)
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

## Mount the EUC - called by player
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
	
	# Position EUC under player
	global_position = player.global_position + Vector3(0, mount_height_offset, 0)
	rotation.y = player.rotation.y + deg_to_rad(90.0)
	
	mounted.emit(player)
	return true

## Dismount the EUC - called by player
func dismount() -> void:
	if not is_mounted or current_rider == null:
		return
	
	var rider := current_rider
	is_mounted = false
	current_rider = null
	current_speed_mps = 0.0
	
	# EUC stays where it is (already at correct position from _process)
	dismounted.emit(rider)

## Plug in the EUC for charging
func plug_in() -> void:
	if is_mounted:
		return
	
	is_plugged_in = true
	
	# Turn on power device to draw from main battery
	if power_device != null and is_instance_valid(power_device):
		if battery_wh < battery_capacity_wh:
			power_device.turn_on()
		else:
			power_device.turn_off()

## Unplug the EUC
func unplug() -> void:
	is_plugged_in = false
	
	if power_device != null and is_instance_valid(power_device):
		power_device.turn_off()

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
		"camera_shake_speed": camera_shake_speed
	}

# ==================== CHARGING VISUAL EFFECTS ====================

## Start the charging visual effect (called by charging station)
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
		# Fade out light if effect not active
		charging_light.light_energy = lerpf(charging_light.light_energy, 0.0, delta * 5.0)
		return
	
	# Check if fully charged
	var is_full := battery_wh >= battery_capacity_wh
	
	if is_full:
		# Steady green glow when fully charged
		charging_light.light_energy = lerpf(charging_light.light_energy, 1.5, delta * 3.0)
		charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)  # Bright green
	else:
		# Pulsing green while charging
		charge_pulse_time += delta * 3.0  # Pulse speed
		var pulse := (sin(charge_pulse_time) + 1.0) / 2.0  # 0.0 to 1.0
		var min_energy := 0.3
		var max_energy := 1.2
		charging_light.light_energy = lerpf(min_energy, max_energy, pulse)
		charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)  # Green

# ==================== RAIN DAMAGE SYSTEM ====================

## Check if EUC is under cover (roof, structure, etc.)
func _is_under_cover() -> bool:
	if cover_raycast == null or not is_instance_valid(cover_raycast):
		return false
	
	cover_raycast.force_raycast_update()
	return cover_raycast.is_colliding()

## Get current rain rate from solar_ui
func _get_rain_rate_per_hour() -> float:
	if _solar_ui == null:
		# Try to find solar_ui
		var tree := get_tree()
		if tree == null:
			return 0.0
		_solar_ui = _find_solar_ui(tree.root)
	
	if _solar_ui != null and "rain_rate_per_hour" in _solar_ui:
		return _solar_ui.rain_rate_per_hour
	return 0.0

## Check if it's currently raining
func _is_raining() -> bool:
	if _solar_ui == null:
		var tree := get_tree()
		if tree == null:
			return false
		_solar_ui = _find_solar_ui(tree.root)
	
	if _solar_ui != null and "weather" in _solar_ui:
		# WeatherType.RAINY is 3
		return _solar_ui.weather == 3
	return false

## Update rain damage each frame
func _update_rain_damage(delta: float) -> void:
	# Skip if already shorted
	if is_shorted:
		return
	
	# Check if it's raining
	if not _is_raining():
		return
	
	# Check if under cover
	if _is_under_cover():
		return  # Protected from rain
	
	# Get time scale for simulation speed
	var time_scale := _get_time_scale()
	var simulated_hours := delta * time_scale
	
	# Get rain rate and accumulate exposure
	var rain_rate := _get_rain_rate_per_hour()
	rain_exposure_inches += rain_rate * simulated_hours
	
	# Check if threshold exceeded
	if rain_exposure_inches >= RAIN_DAMAGE_THRESHOLD_INCHES:
		_trigger_short_circuit()

## Trigger short circuit effect
func _trigger_short_circuit() -> void:
	if is_shorted:
		return  # Already shorted
	
	is_shorted = true
	
	# Trigger flash effect
	if short_circuit_light != null and is_instance_valid(short_circuit_light):
		short_circuit_light.light_energy = 15.0  # Bright flash
		short_circuit_light.light_color = Color(1.0, 0.95, 0.7, 1.0)  # Bright yellow-white
	
	# Trigger smoke
	if smoke_particles != null and is_instance_valid(smoke_particles):
		smoke_particles.emitting = true
	
	# Dismount rider if mounted
	if is_mounted and current_rider != null:
		dismount()
	
	shorted_out.emit()

## Update short circuit flash effect (fade out)
func _update_short_circuit_effect(delta: float) -> void:
	if short_circuit_light == null or not is_instance_valid(short_circuit_light):
		return
	
	# Fade out flash
	if short_circuit_light.light_energy > 0.0:
		short_circuit_light.light_energy = lerpf(short_circuit_light.light_energy, 0.0, delta * 8.0)
		if short_circuit_light.light_energy < 0.01:
			short_circuit_light.light_energy = 0.0

## Repair the EUC (called by player pressing R)
func repair() -> bool:
	if not is_shorted:
		return false  # Nothing to repair
	
	is_shorted = false
	rain_exposure_inches = 0.0
	
	# Flash green to indicate repair
	if charging_light != null and is_instance_valid(charging_light):
		charging_light.light_energy = 3.0
		charging_light.light_color = Color(0.2, 1.0, 0.3, 1.0)
	
	repaired.emit()
	return true

## Check if player can mount (includes short circuit check)
func can_mount() -> bool:
	return not is_mounted and not is_shorted and player_in_range != null and battery_wh > 0.0

## Check if EUC needs repair
func needs_repair() -> bool:
	return is_shorted

## Get rain exposure amount
func get_rain_exposure() -> float:
	return rain_exposure_inches
