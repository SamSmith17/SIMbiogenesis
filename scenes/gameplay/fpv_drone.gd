extends Area3D
class_name FPVDrone

## FPV Drone vehicle - player body stays on ground while camera flies with drone
## Left stick / WASD = horizontal flight relative to look direction
## Right trigger / Space = ascend, Left trigger / Shift = descend
## Right stick / mouse = look direction (steering)
## Drone hovers at current altitude when no altitude input

signal mounted(player: CharacterBody3D)
signal dismounted(player: CharacterBody3D)
signal player_entered_range(drone: FPVDrone)
signal player_exited_range(drone: FPVDrone)

# Flight characteristics - tuned for DJI Avata-style FPV feel
@export_group("Flight Settings")
@export var max_forward_speed: float = 45.0  # m/s horizontal at full stick
@export var vertical_speed: float = 25.0  # m/s ascend/descend at full trigger
@export var steering_sensitivity: float = 2.5  # Mouse/head tracking sensitivity
@export var acceleration: float = 28.0  # How fast drone accelerates
@export var drag: float = 8.0  # How fast drone decelerates to hover
@export var tilt_intensity: float = 35.0  # Max visual tilt angle in degrees
@export var tilt_speed: float = 8.0  # How fast drone tilts (visual banking)

@export_group("Controller")
@export var controller_deadzone: float = 0.225

@export_group("Altitude Limits")
@export var min_altitude: float = 0.5  # Minimum height above ground
@export var max_altitude: float = 8000.0  # Maximum height above ground (AGL)

@export_group("Interaction")
@export var interaction_radius: float = 2.0
@export var display_name: String = "FPV Drone"

@export_group("Visuals")
@export var drone_color: Color = Color(0.2, 0.2, 0.2, 1.0)
@export var propeller_color: Color = Color(0.1, 0.1, 0.1, 1.0)
@export var led_color: Color = Color(0.0, 1.0, 0.0, 1.0)  # Green LEDs

# State
var is_mounted: bool = false
var current_rider: CharacterBody3D = null
var player_in_range: CharacterBody3D = null
var player_spawn_position: Vector3 = Vector3.ZERO  # Where to return player on dismount
var drone_spawn_position: Vector3 = Vector3.ZERO  # Where drone started

# Flight state
var current_velocity: Vector3 = Vector3.ZERO
var current_pitch: float = 0.0  # Look pitch (up/down)
var current_yaw: float = 0.0  # Look yaw (left/right)
var visual_tilt: Vector3 = Vector3.ZERO  # Visual bank/pitch of drone body
## Same as player: Steam trackpad biases joy axes while finger rests; ignore until released.
var _suppress_gamepad_look_until_axes_released: bool = false

# Camera reference (taken from player during flight)
var _drone_camera: Camera3D = null
var _player_camera: Camera3D = null
var _original_camera_local_transform: Transform3D  # Local transform relative to camera arm
var _original_camera_global_transform: Transform3D  # For reference

# Node references
var _mesh_instance: MeshInstance3D = null
var _collision_shape: CollisionShape3D = null
var _propellers: Array[MeshInstance3D] = []
var _led_mesh: MeshInstance3D = null
var _camera_mount: Node3D = null

func _ready() -> void:
	add_to_group("vehicles")
	drone_spawn_position = global_position
	
	# Setup collision for player detection
	collision_layer = 0
	collision_mask = 1  # Detect player on layer 1
	
	# Connect signals
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	# Create visual mesh
	_create_drone_mesh()
	
	# Setup interaction area
	_setup_interaction_area()

func _create_drone_mesh() -> void:
	# Main body - flattened box shape typical of FPV drones
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "DroneBody"
	
	var body_mesh = BoxMesh.new()
	body_mesh.size = Vector3(0.25, 0.06, 0.2)  # ~25cm wide, 6cm tall, 20cm deep
	_mesh_instance.mesh = body_mesh
	
	var body_material = StandardMaterial3D.new()
	body_material.albedo_color = drone_color
	body_material.metallic = 0.3
	body_material.roughness = 0.7
	_mesh_instance.material_override = body_material
	
	add_child(_mesh_instance)
	
	# Camera mount point (front of drone)
	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.position = Vector3(0, 0.02, -0.12)  # Front of drone, slightly up
	add_child(_camera_mount)
	
	# Create 4 propeller arms + propellers
	var arm_positions = [
		Vector3(0.12, 0.02, -0.08),   # Front-right
		Vector3(-0.12, 0.02, -0.08),  # Front-left
		Vector3(0.12, 0.02, 0.08),    # Back-right
		Vector3(-0.12, 0.02, 0.08),   # Back-left
	]
	
	for i in range(4):
		# Arm
		var arm = MeshInstance3D.new()
		var arm_mesh = CylinderMesh.new()
		arm_mesh.top_radius = 0.01
		arm_mesh.bottom_radius = 0.01
		arm_mesh.height = 0.08
		arm.mesh = arm_mesh
		arm.position = arm_positions[i] * 0.5 + Vector3(0, 0.01, 0)
		arm.rotation.x = deg_to_rad(90)
		arm.material_override = body_material
		add_child(arm)
		
		# Propeller disc (spinning effect)
		var prop = MeshInstance3D.new()
		prop.name = "Propeller" + str(i)
		var prop_mesh = CylinderMesh.new()
		prop_mesh.top_radius = 0.04
		prop_mesh.bottom_radius = 0.04
		prop_mesh.height = 0.005
		prop.mesh = prop_mesh
		prop.position = arm_positions[i]
		
		var prop_material = StandardMaterial3D.new()
		prop_material.albedo_color = propeller_color
		prop_material.albedo_color.a = 0.5  # Semi-transparent when spinning
		prop_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		prop.material_override = prop_material
		add_child(prop)
		_propellers.append(prop)
	
	# LED indicator on back
	_led_mesh = MeshInstance3D.new()
	_led_mesh.name = "LED"
	var led_mesh = SphereMesh.new()
	led_mesh.radius = 0.015
	led_mesh.height = 0.03
	_led_mesh.mesh = led_mesh
	_led_mesh.position = Vector3(0, 0.04, 0.1)
	
	var led_material = StandardMaterial3D.new()
	led_material.albedo_color = led_color
	led_material.emission_enabled = true
	led_material.emission = led_color
	led_material.emission_energy_multiplier = 2.0
	_led_mesh.material_override = led_material
	add_child(_led_mesh)

func _setup_interaction_area() -> void:
	# Check if collision shape exists, create if not
	_collision_shape = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "CollisionShape3D"
		add_child(_collision_shape)
	
	var sphere = SphereShape3D.new()
	sphere.radius = interaction_radius
	_collision_shape.shape = sphere

func _process(delta: float) -> void:
	var spin_speed := 20.0
	if is_mounted:
		if _is_terrain_edit_ortho():
			# Terrain sculpt: locked top-down view, no movement.
			current_pitch = deg_to_rad(-89.0)
			current_yaw = _terrain_edit_yaw()
			current_velocity = Vector3.ZERO
			_update_drone_camera()
		elif _is_vegetation_edit_ortho():
			# Veg paint: fly to reposition, keep ortho top-down camera.
			var speed_ratio := current_velocity.length() / maxf(max_forward_speed, 1.0)
			spin_speed = lerpf(30.0, 80.0, clampf(speed_ratio, 0.0, 1.0))
			_handle_flight_input(delta, true)
			current_pitch = deg_to_rad(-89.0)
			visual_tilt = Vector3.ZERO
			if _mesh_instance:
				_mesh_instance.rotation = Vector3.ZERO
			rotation.y = current_yaw
			_update_drone_camera()
		else:
			var speed_ratio := current_velocity.length() / maxf(max_forward_speed, 1.0)
			spin_speed = lerpf(30.0, 80.0, clampf(speed_ratio, 0.0, 1.0))
			_handle_flight_input(delta)
			_update_drone_camera()
	
	for prop in _propellers:
		prop.rotate_y(delta * spin_speed)

func _handle_flight_input(delta: float, yaw_only_look: bool = false) -> void:
	if current_rider == null:
		return
	
	# Right stick / mouse steering (polled axes skipped after mouse motion until axes neutral)
	var controller_look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if _suppress_gamepad_look_until_axes_released:
		if controller_look.length() < controller_deadzone:
			_suppress_gamepad_look_until_axes_released = false
	if not _suppress_gamepad_look_until_axes_released and controller_look.length() > controller_deadzone:
		var look_scale := steering_sensitivity * delta * 60.0
		current_yaw -= controller_look.x * 0.03 * look_scale
		if not yaw_only_look:
			current_pitch -= controller_look.y * 0.03 * look_scale
	
	if not yaw_only_look:
		current_pitch = clamp(current_pitch, deg_to_rad(-85), deg_to_rad(85))
	
	# Left stick / WASD for horizontal movement.
	# Using get_vector keeps keyboard/controller mapping consistent with player movement.
	var move_input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var input_forward := -move_input.y
	var input_strafe := move_input.x
	
	# Shift / Ctrl (or triggers) for altitude; no vertical input while sim is paused.
	var input_altitude := 0.0
	var main := get_tree().get_first_node_in_group("main_scene") if get_tree() != null else null
	var sim_paused := main != null and float(main.get("time_scale") if main.get("time_scale") != null else 1.0) == 0.0
	if not sim_paused:
		input_altitude = Input.get_action_strength("drone_ascend") - Input.get_action_strength("drone_descend")
	
	# Horizontal movement is relative to look yaw (pitch doesn't affect flight direction)
	var yaw_basis := Basis().rotated(Vector3.UP, current_yaw)
	var forward_dir := -yaw_basis.z
	var right_dir := yaw_basis.x
	
	var target_velocity := Vector3.ZERO
	target_velocity += forward_dir * input_forward * max_forward_speed
	target_velocity += right_dir * input_strafe * max_forward_speed
	target_velocity.y = input_altitude * vertical_speed
	
	# Accelerate toward target; decelerate (drag) toward hover when no input
	if target_velocity.length_squared() > 0.001:
		current_velocity = current_velocity.move_toward(target_velocity, acceleration * delta)
	else:
		current_velocity = current_velocity.move_toward(Vector3.ZERO, drag * delta)
	
	global_position += current_velocity * delta
	
	# Enforce altitude limits
	var ground_height := _get_ground_height()
	if global_position.y < ground_height + min_altitude:
		global_position.y = ground_height + min_altitude
		current_velocity.y = maxf(current_velocity.y, 0)
	if global_position.y > ground_height + max_altitude:
		global_position.y = ground_height + max_altitude
		current_velocity.y = minf(current_velocity.y, 0)
	
	if not yaw_only_look:
		_update_visual_tilt(delta)

func _get_ground_height() -> float:
	# Raycast down to find ground
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position,
		global_position + Vector3.DOWN * maxf(500.0, max_altitude + 500.0)
	)
	query.exclude = [self]
	
	var result := space_state.intersect_ray(query)
	if result:
		return result.position.y
	return 0.0

func _update_visual_tilt(delta: float) -> void:
	var horizontal_vel := Vector3(current_velocity.x, 0, current_velocity.z)
	var speed := horizontal_vel.length()
	
	var target_roll := 0.0
	var target_pitch := 0.0
	
	if speed > 0.5:
		var yaw_basis := Basis().rotated(Vector3.UP, current_yaw)
		var local_vel := yaw_basis.inverse() * horizontal_vel
		
		target_roll = -local_vel.x / max_forward_speed * tilt_intensity
		target_pitch = local_vel.z / max_forward_speed * tilt_intensity
	
	visual_tilt.z = lerpf(visual_tilt.z, deg_to_rad(clampf(target_roll, -tilt_intensity, tilt_intensity)), tilt_speed * delta)
	visual_tilt.x = lerpf(visual_tilt.x, deg_to_rad(clampf(target_pitch, -tilt_intensity, tilt_intensity)), tilt_speed * delta)
	
	if _mesh_instance:
		_mesh_instance.rotation = visual_tilt
	
	rotation.y = current_yaw

func _update_drone_camera() -> void:
	if _drone_camera == null:
		return
	
	# Position camera at drone's camera mount
	_drone_camera.global_position = _camera_mount.global_position
	
	# FPV camera follows look direction exactly in WORLD space, so visible heading
	# always matches movement heading and avoids parent-space yaw offsets.
	# Add subtle roll effect when banking for immersion (like real FPV footage).
	var camera_roll := visual_tilt.z * 0.4  # Camera rolls slightly with drone bank
	_drone_camera.global_rotation = Vector3(current_pitch, current_yaw, camera_roll)

func _input(event: InputEvent) -> void:
	if not is_mounted:
		return
	if _is_terrain_edit_ortho():
		return
	
	# Handle mouse look for steering (head tracking simulation)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mouse_event := event as InputEventMouseMotion
		if mouse_event.relative.length_squared() > 1e-12:
			_suppress_gamepad_look_until_axes_released = true
		current_yaw -= mouse_event.relative.x * 0.002 * steering_sensitivity
		current_pitch -= mouse_event.relative.y * 0.002 * steering_sensitivity
		current_pitch = clamp(current_pitch, deg_to_rad(-85), deg_to_rad(85))


func _is_terrain_edit_ortho() -> bool:
	if not is_mounted:
		return false
	return has_meta("terrain_edit_ortho") and bool(get_meta("terrain_edit_ortho"))


func _is_vegetation_edit_ortho() -> bool:
	if not is_mounted:
		return false
	return has_meta("vegetation_edit_ortho") and bool(get_meta("vegetation_edit_ortho"))


func _is_ortho_edit_mode() -> bool:
	return _is_terrain_edit_ortho() or _is_vegetation_edit_ortho()


func _is_terrain_edit_mode() -> bool:
	return _is_terrain_edit_ortho()


func _terrain_edit_yaw() -> float:
	var loader := get_parent().get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("get_sculpt_locked_yaw"):
		return float(loader.call("get_sculpt_locked_yaw"))
	return current_yaw


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player") and body is CharacterBody3D:
		player_in_range = body
		player_entered_range.emit(self)
		
		# Notify player
		if body.has_method("on_vehicle_nearby"):
			body.on_vehicle_nearby(self)

func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		player_exited_range.emit(self)
		
		# Notify player
		if body.has_method("on_vehicle_left_range"):
			body.on_vehicle_left_range(self)

# ==================== PUBLIC API ====================

## Mount the drone - called by player
func mount(player: CharacterBody3D) -> bool:
	if is_mounted or player == null:
		return false
	
	is_mounted = true
	current_rider = player
	player_spawn_position = player.global_position
	
	# Get player's camera
	_player_camera = player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	if _player_camera == null:
		push_error("FPV Drone: Could not find player camera!")
		is_mounted = false
		current_rider = null
		return false
	
	# Store original camera state (local transform for proper restoration)
	_original_camera_local_transform = _player_camera.transform
	_original_camera_global_transform = _player_camera.global_transform
	
	# Use player's camera for drone view
	_drone_camera = _player_camera
	
	# Initialize drone orientation from player's CURRENT camera look direction.
	current_yaw = _player_camera.global_rotation.y
	current_pitch = clamp(_player_camera.global_rotation.x, deg_to_rad(-85), deg_to_rad(85))
	
	current_velocity = Vector3.ZERO
	visual_tilt = Vector3.ZERO
	_suppress_gamepad_look_until_axes_released = false
	
	# Reset drone position to spawn point + some height (takeoff!)
	global_position = drone_spawn_position + Vector3(0, 1.5, 0)
	rotation.y = current_yaw  # Face the same direction as player
	
	# Set LED to red when flying
	if _led_mesh != null:
		var mat := _led_mesh.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = Color(1, 0, 0, 1)
			mat.emission = Color(1, 0, 0, 1)
	
	mounted.emit(player)
	return true

## Dismount the drone - called by player
func dismount() -> void:
	if not is_mounted or current_rider == null:
		return
	
	var rider := current_rider
	
	# Return camera to player - restore local transform so it's relative to player again
	if _drone_camera != null and rider != null:
		_drone_camera.transform = _original_camera_local_transform
	
	is_mounted = false
	current_rider = null
	_drone_camera = null
	current_velocity = Vector3.ZERO
	_suppress_gamepad_look_until_axes_released = false
	
	# Set LED back to green
	if _led_mesh != null:
		var mat := _led_mesh.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = led_color
			mat.emission = led_color
	
	# Return drone to spawn
	global_position = drone_spawn_position
	rotation = Vector3.ZERO
	
	dismounted.emit(rider)

## Get interaction prompt text
func get_interaction_prompt() -> String:
	return "Fly " + display_name

## Get riding parameters for player (tells player this is special)
func get_riding_params() -> Dictionary:
	return {
		"speed_multiplier": 0.0,  # Player doesn't move
		"max_speed": 0.0,
		"is_fpv_drone": true,  # Special flag for player to handle differently
		"keep_player_stationary": true,  # Player body stays in place
	}

## Check if mounted
func is_active() -> bool:
	return is_mounted


func collect_save_state() -> Dictionary:
	return {
		"global_position": SaveSerialization.vec3_to_dict(global_position),
		"rotation": SaveSerialization.vec3_to_dict(rotation),
		"current_velocity": SaveSerialization.vec3_to_dict(current_velocity),
		"current_pitch": current_pitch,
		"current_yaw": current_yaw,
		"visual_tilt": SaveSerialization.vec3_to_dict(visual_tilt),
		"drone_spawn_position": SaveSerialization.vec3_to_dict(drone_spawn_position),
		"player_spawn_position": SaveSerialization.vec3_to_dict(player_spawn_position),
		"camera_local_rest": SaveSerialization.transform3d_to_dict(_original_camera_local_transform),
	}


## Restore mounted flight from a save snapshot (player already positioned on the ground).
func restore_from_save(player: CharacterBody3D, data: Dictionary) -> bool:
	if player == null or data.is_empty():
		return false
	global_position = SaveSerialization.dict_to_vec3(data.get("global_position", {}))
	rotation = SaveSerialization.dict_to_vec3(data.get("rotation", {}))
	current_velocity = SaveSerialization.dict_to_vec3(data.get("current_velocity", {}))
	current_pitch = float(data.get("current_pitch", 0.0))
	current_yaw = float(data.get("current_yaw", 0.0))
	current_pitch = clampf(current_pitch, deg_to_rad(-85), deg_to_rad(85))
	visual_tilt = SaveSerialization.dict_to_vec3(data.get("visual_tilt", {}))
	drone_spawn_position = SaveSerialization.dict_to_vec3(data.get("drone_spawn_position", {}))
	player_spawn_position = SaveSerialization.dict_to_vec3(data.get("player_spawn_position", {}))
	_player_camera = player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	if _player_camera == null:
		push_error("FPV Drone: restore_from_save could not find player camera")
		return false
	var cam_rest: Variant = data.get("camera_local_rest", {})
	if cam_rest is Dictionary:
		var cr: Dictionary = cam_rest
		if not cr.is_empty():
			_original_camera_local_transform = SaveSerialization.dict_to_transform3d(cam_rest)
		else:
			_original_camera_local_transform = _player_camera.transform
	else:
		_original_camera_local_transform = _player_camera.transform
	_drone_camera = _player_camera
	is_mounted = true
	current_rider = player
	if _mesh_instance != null:
		_mesh_instance.rotation = visual_tilt
	rotation.y = current_yaw
	if _led_mesh != null:
		var mat := _led_mesh.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = Color(1, 0, 0, 1)
			mat.emission = Color(1, 0, 0, 1)
	_update_drone_camera()
	return true


## Get current altitude
func get_altitude() -> float:
	return global_position.y - _get_ground_height()

## Get current speed
func get_speed() -> float:
	return current_velocity.length()

