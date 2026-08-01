extends CharacterBody3D

## First-person player controller with mouse/gamepad look and WASD/joystick movement
## Supports keyboard+mouse and PS5/Xbox controllers
## Includes EUC (Electric Unicycle) riding mode with camera tilt

signal player_died(death_message: String)
signal mounted_vehicle(vehicle: Node3D)
signal dismounted_vehicle(vehicle: Node3D)

# Movement settings
@export var move_speed : float = 7.0
@export var sprint_speed : float = 13.0
@export var jump_velocity : float = 4.5
@export var gravity_multiplier : float = 1.0

# Step climbing settings - allows walking up stairs/ledges without jumping.
# Loosened so the player can scramble over placed props/building clutter instead
# of snagging on them (concave trimesh colliders are prone to catching a
# character controller at the edges) — climbing near-anything is a deliberate
# design choice here, not just a stairs convenience.
@export var step_height : float = 1.1  # Maximum height of step to climb (meters)
@export var step_climb_enabled : bool = true  # Enable/disable step climbing
@export var step_climb_tolerance : float = 0.3  # How steep a surface can be to walk up (lower = steeper allowed)
const _STEP_CLIMB_INTERVAL : float = 0.05  # ~20 Hz throttle for the step-climb ray fan
var _step_climb_accum : float = 0.0

# Mouse look settings
@export var mouse_sensitivity : float = 0.002
@export var min_pitch : float = -89.0
@export var max_pitch : float = 89.0

# Controller look settings
@export var controller_sensitivity : float = 3.0
@export var controller_deadzone : float = 0.15
@export var invert_y_axis : bool = true  # Invert vertical look (up stick = look down)

# Fall damage settings
@export var fatal_fall_distance : float = 4.57  # 15 feet in meters
## Respawn when this far below the last grounded height (void / terrain mismatch safety net).
@export var void_fall_respawn_distance : float = 80.0

# Fire damage settings (passed to PlayerHealth)
@export var fire_damage_distance : float = 0.91  # 3 feet in meters (default)

# Node references
@onready var camera_arm : Node3D = $CameraArm
@onready var camera : Camera3D = $CameraArm/Camera3D
@onready var tool_manager : Node = $ToolManager
@onready var character_model : Node3D = $CharacterModel

# Character animation
var character_anim_player : AnimationPlayer = null
var current_anim_state : String = "idle"  # idle, walk, jog
var anim_idle_name : String = ""
var anim_walk_name : String = ""
var anim_jog_name : String = ""

# Animation scenes to load additional animations from (no skin versions for compatibility)
const IDLE_ANIM_PATH := "res://Player Character/Breathing Idle (no skin).fbx"
const JOG_ANIM_PATH := "res://Player Character/Jogging (no skin).fbx"

# Rigged body mesh (optional — see ASSETS.md, gitignored on the public repo).
const CHARACTER_FBX_PATH := "res://Player Character/Walking (in place).fbx"
const CHARACTER_FBX_TRANSFORM := Transform3D(
	Basis(Vector3(-0.5, 0.0, 0.0), Vector3(0.0, 0.5, 0.0), Vector3(0.0, 0.0, -0.5)),
	Vector3(0.0, 0.0, 0.25))

## Procedural stand-in body (core/population/npc_simple_figure.gd), always built
## under CharacterModel as the base — the rigged FBX layers on top of it when the
## asset pack is present (mirrors core/population/npc_avatar.gd's rigged-vs-simple
## pattern for NPCs). Without this, a fresh clone with no asset pack leaves
## CharacterModel empty and every animation lookup silently inert. Player's own
## body is otherwise only ever seen externally (FPV drone view, other multiplayer
## clients via the fully independent RemotePlayerAvatar capsule).
var _simple_figure : NpcSimpleFigure = null

# Animation transition settings
const WALK_SPEED_THRESHOLD := 0.5   # Speed to start walking
const JOG_SPEED_THRESHOLD := 6.0    # Speed to start jogging
const ANIM_BLEND_TIME := 0.2        # Crossfade duration in seconds

# First-person camera
var first_person_near_clip : float = 0.25

# EUC riding character adjustments
var euc_character_height_offset : float = 0.1  # Raise character ~4 inches to stand on pedals
var euc_character_back_offset : float = 0.15   # Move character back slightly so EUC appears under feet
var character_base_offset : Vector3 = Vector3(0, 0, 0.25)  # Normal character offset (from scene)

# State
var is_mouse_captured : bool = false
## Steam trackpad sends mouse deltas and joy axes 2/3; a resting finger biases axes like a
## held stick. After real mouse motion, skip polled gamepad look until axes return to neutral.
var _suppress_gamepad_look_until_axes_released : bool = false
var is_falling : bool = false
var fall_start_height : float = 0.0
var void_reference_y : float = 0.0
var _void_respawn_cooldown_s : float = 0.0
var highest_point_during_fall : float = 0.0

# Coyote time - maintains "grounded" state briefly after leaving floor
# This prevents falling through small gaps between collision objects
var _coyote_timer : float = 0.0
const COYOTE_TIME : float = 0.15  # Seconds to remain "grounded" after leaving floor
var _was_on_floor_last_frame : bool = false
var _last_floor_height : float = 0.0

# EUC/Vehicle riding state
var is_riding : bool = false
var current_vehicle : Node3D = null
var nearby_vehicle : Node3D = null
var riding_speed_multiplier : float = 3.0
var riding_max_speed : float = 25.0
var riding_max_tilt : float = 25.0
var riding_tilt_speed : float = 5.0
var riding_shake_intensity : float = 0.015
var riding_shake_speed : float = 15.0
var riding_min_shake_speed : float = 1.0
var riding_camera_offset : Vector3 = Vector3.ZERO
var is_golf_cart_mode : bool = false
var use_cart_steering : bool = false
var cart_min_turn_radius : float = 3.0
var cart_max_turn_rate : float = 60.0
var cart_current_speed : float = 0.0  # Current forward speed for cart
var current_camera_tilt : float = 0.0
var is_fpv_drone_mode : bool = false  # Special mode: player body stays, camera goes to drone
var shake_time : float = 0.0
var base_camera_position : Vector3

# EUC turn tracking for realistic banking
var previous_rotation_y : float = 0.0
var current_turn_rate : float = 0.0  # How fast player is turning (radians/sec)

# Interaction UI reference (set by main scene)
var interaction_ui : CanvasLayer = null
var euc_ui : CanvasLayer = null

# Charging station state
var nearby_charging_station : Node3D = null
var is_charging_euc : bool = false

# Fire extinguisher pickup state
var nearby_extinguisher : Node3D = null
var extinguisher_count : int = 0  # Number of extinguishers collected (multiplies spray time)
var _interaction_focus : Node = null

func _ready() -> void:
	Services.register(Services.PLAYER, self)
	add_to_group("player")
	call_deferred("_setup_character_animation")
	call_deferred("_init_first_person_camera")
	call_deferred("_setup_interaction_focus")
	_setup_tool_manager()
	if is_instance_valid(CursorController):
		call_deferred("_defer_initial_capture")
	else:
		_capture_mouse()
	void_reference_y = global_position.y


func _defer_initial_capture() -> void:
	CursorController.set_paused(false)


func _setup_interaction_focus() -> void:
	if camera == null:
		return
	_interaction_focus = Node.new()
	_interaction_focus.name = "InteractionFocus"
	var script := load("res://gameplay/interaction_focus.gd") as Script
	if script != null:
		_interaction_focus.set_script(script)
		add_child(_interaction_focus)
		if _interaction_focus.has_method("setup"):
			_interaction_focus.setup(self, camera)
	_setup_grab_controller()
	_setup_conduit_route_controller()


func _setup_conduit_route_controller() -> void:
	if camera == null:
		return
	var ctrl := Node.new()
	ctrl.name = "ConduitRouteController"
	var script := load("res://scenes/gameplay/conduit_route_controller.gd") as Script
	if script != null:
		ctrl.set_script(script)
	add_child(ctrl)


func _setup_grab_controller() -> void:
	var grab := Node.new()
	grab.name = "GrabController"
	var script := load("res://gameplay/grab_controller.gd") as Script
	if script != null:
		grab.set_script(script)
		add_child(grab)
		if grab.has_method("setup"):
			var loader := get_tree().current_scene.get_node_or_null("TerrainLoader")
			grab.call("setup", self, camera, _interaction_focus, loader)

## Build the visible body, then wire up its animation system if a rigged FBX
## body loaded. CharacterModel is empty at scene-load time (see player.tscn) —
## this is the one place a body ever gets added to it.
func _setup_character_animation() -> void:
	if character_model == null:
		return
	_ensure_simple_figure()
	if not _try_load_character_fbx():
		return  # No asset pack: the simple figure stays as the visible body.

	# Find AnimationPlayer in the character model hierarchy
	character_anim_player = _find_animation_player_recursive(character_model)

	if character_anim_player == null:
		return
	# Real rigged body loaded and has an AnimationPlayer — it wins.
	_simple_figure.visible = false

	# Get walk animation from the main model
	var anims := character_anim_player.get_animation_list()
	
	for anim_name in anims:
		if "mixamo" in anim_name.to_lower() or anims.size() == 1:
			anim_walk_name = anim_name
			break
	if anim_walk_name.is_empty() and anims.size() > 0:
		anim_walk_name = anims[0]
	
	# Set walk animation to loop
	if not anim_walk_name.is_empty():
		var walk_anim := character_anim_player.get_animation(anim_walk_name)
		if walk_anim != null:
			walk_anim.loop_mode = Animation.LOOP_LINEAR
		else:
			pass
	
	# Load idle animation from separate FBX
	_load_animation_from_fbx(IDLE_ANIM_PATH, "idle")
	
	# Load jog animation from separate FBX
	_load_animation_from_fbx(JOG_ANIM_PATH, "jog")
	
	# Start with idle animation if available, otherwise walk
	if not anim_idle_name.is_empty():
		character_anim_player.play(anim_idle_name)
		current_anim_state = "idle"
	elif not anim_walk_name.is_empty():
		character_anim_player.play(anim_walk_name)
		current_anim_state = "walk"


## The procedural stand-in body — always present under CharacterModel as the
## base, regardless of whether the rigged FBX pack is installed.
func _ensure_simple_figure() -> void:
	if _simple_figure != null:
		return
	_simple_figure = NpcSimpleFigure.new()
	_simple_figure.name = "SimpleFigureBody"
	_simple_figure.setup("player", Color(0.55, 0.62, 0.78))
	character_model.add_child(_simple_figure)


## Loads and instances the rigged Mixamo body if the (gitignored, optional)
## asset pack is present. Returns false — leaving the simple figure as the
## only visible body — when it isn't, mirroring NpcRig.available()'s
## exists-before-load guard for the same folder.
func _try_load_character_fbx() -> bool:
	if not ResourceLoader.exists(CHARACTER_FBX_PATH):
		return false
	var packed := load(CHARACTER_FBX_PATH) as PackedScene
	if packed == null:
		return false
	var remy := packed.instantiate()
	remy.name = "Remy"
	remy.transform = CHARACTER_FBX_TRANSFORM
	character_model.add_child(remy)
	return true


## Load an animation from a separate FBX file and add it to our AnimationPlayer
func _load_animation_from_fbx(fbx_path: String, anim_type: String) -> void:
	if character_anim_player == null:
		return
	
	if not ResourceLoader.exists(fbx_path):
		return
	
	var scene : PackedScene = load(fbx_path)
	if scene == null:
		return
	
	# Instance the scene temporarily to extract its animation
	var instance := scene.instantiate()
	var source_anim_player := _find_animation_player_recursive(instance)
	
	if source_anim_player == null:
		instance.queue_free()
		return
	
	var source_anims := source_anim_player.get_animation_list()
	
	for source_anim_name in source_anims:
		# Get the animation resource
		var anim : Animation = source_anim_player.get_animation(source_anim_name)
		if anim != null:
			# Duplicate and set to loop
			var anim_copy : Animation = anim.duplicate()
			anim_copy.loop_mode = Animation.LOOP_LINEAR
			
			# Create a unique name for this animation
			var new_name := anim_type + "_" + source_anim_name
			
			# Add to our animation player's library
			var lib : AnimationLibrary
			if character_anim_player.has_animation_library(""):
				lib = character_anim_player.get_animation_library("")
			else:
				lib = AnimationLibrary.new()
				character_anim_player.add_animation_library("", lib)
			
			if not lib.has_animation(new_name):
				lib.add_animation(new_name, anim_copy)
			
			# Store the animation name
			match anim_type:
				"idle":
					anim_idle_name = new_name
				"jog":
					anim_jog_name = new_name
			break  # Only need the first animation from each file
	
	# Clean up the temporary instance
	instance.queue_free()

## Recursively find AnimationPlayer in node tree
func _find_animation_player_recursive(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player_recursive(child)
		if found != null:
			return found
	return null

## Initialize first-person camera - resets position/rotation to clean state
func _init_first_person_camera() -> void:
	if camera == null:
		return
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	camera.near = first_person_near_clip
	base_camera_position = camera.position
	if character_model != null:
		character_model.visible = true
		_set_head_visibility(false)

## Set visibility of the character's head (for first-person view)
func _set_head_visibility(visible: bool) -> void:
	if character_model == null:
		return
	
	# Find the skeleton and hide head-related bones/meshes
	var remy := character_model.get_node_or_null("Remy")
	if remy == null:
		return
	
	# For Mixamo characters, we can't easily hide just the head mesh
	# since it's part of the same mesh as the body.
	# Instead, we use a BoneAttachment approach or adjust the skeleton
	
	# Try to find skeleton and scale down head bone to hide it
	var skeleton := _find_skeleton_recursive(remy)
	if skeleton != null:
		var head_bone_idx := skeleton.find_bone("mixamorig:Head")
		if head_bone_idx == -1:
			head_bone_idx = skeleton.find_bone("Head")
		
		if head_bone_idx != -1:
			if visible:
				# Reset head to normal scale
				skeleton.set_bone_pose_scale(head_bone_idx, Vector3.ONE)
			else:
				# Scale head to zero to hide it
				skeleton.set_bone_pose_scale(head_bone_idx, Vector3.ZERO)

## Recursively find Skeleton3D in node tree
func _find_skeleton_recursive(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton_recursive(child)
		if found != null:
			return found
	return null

## Adjust character position for EUC riding (raise up to stand on pedals)
func _set_character_riding_position(riding: bool) -> void:
	if character_model == null:
		return
	
	var remy := character_model.get_node_or_null("Remy") as Node3D
	if remy == null:
		return
	
	if riding:
		# Raise character to stand on EUC pedals, move forward (negative Z) so EUC appears under feet
		remy.position = Vector3(0, euc_character_height_offset, character_base_offset.z - euc_character_back_offset)
	else:
		# Reset to normal position
		remy.position = Vector3(0, 0, character_base_offset.z)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and is_mouse_captured and CursorController.should_capture_look():
		var mm := event as InputEventMouseMotion
		if mm.relative.length_squared() > 1e-12:
			_suppress_gamepad_look_until_axes_released = true
		_handle_mouse_look(mm.relative)

	# Skip all key/action input when a UI text field has keyboard focus so that
	# typing in the location picker (or any other LineEdit/TextEdit) doesn't
	# trigger game shortcuts (equip/unequip, fire-debug, etc.).
	var _fo := get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	if _fo is LineEdit or _fo is TextEdit:
		return

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_X and is_riding:
			_dismount_vehicle()
			return
		# Debug-only: F spawns a fire crisis event. Gated on a debug build so it
		# cannot fire in an exported game. The old condition also matched on
		# `unicode == 'f'/'F'`, which triggered from ANY key event producing that
		# character regardless of layout or modifiers -- physical_keycode only.
		if OS.is_debug_build() and event.physical_keycode == KEY_F:
			_trigger_fire_event_debug()
			return

	# Action-based input (works for both keyboard and controller)
	if event.is_action_pressed("equip_tool"):
		if tool_manager != null:
			tool_manager.equip_tool("fire_extinguisher")
	elif event.is_action_pressed("unequip_tool"):
		if tool_manager != null:
			tool_manager.unequip_tool()
	elif event.is_action_pressed("toggle_tool"):
		if tool_manager != null:
			if tool_manager.is_tool_equipped("fire_extinguisher"):
				tool_manager.unequip_tool()
			else:
				tool_manager.equip_tool("fire_extinguisher")

func _physics_process(delta: float) -> void:
	if _void_respawn_cooldown_s > 0.0:
		_void_respawn_cooldown_s = maxf(0.0, _void_respawn_cooldown_s - delta)
	var currently_on_floor := is_on_floor()
	
	# Update coyote time - allows briefly maintaining "grounded" state after leaving floor
	# This prevents falling through small gaps between collision objects
	if currently_on_floor:
		_coyote_timer = COYOTE_TIME
		_last_floor_height = global_position.y
		_was_on_floor_last_frame = true
	else:
		_coyote_timer -= delta
		if _coyote_timer < 0:
			_coyote_timer = 0
	
	# "Effective" floor check includes coyote time
	var effectively_on_floor := currently_on_floor or (_coyote_timer > 0 and velocity.y <= 0)
	
	# Apply gravity (reduced when riding for smoother feel)
	# During coyote time with small drops, reduce gravity to help bridge gaps
	if not currently_on_floor:
		var gravity_factor := 0.3 if is_riding else 1.0
		
		# If within coyote time and haven't fallen far, reduce gravity
		if _coyote_timer > 0 and (global_position.y >= _last_floor_height - 0.3):
			gravity_factor *= 0.3
		
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * gravity_multiplier * gravity_factor * delta
	
	# Try to bridge small gaps by finding nearby floor when in coyote time
	if not currently_on_floor and _coyote_timer > 0 and not is_riding:
		_try_bridge_gap()
	
	# Track falling for fall damage (disabled when riding)
	if not is_riding:
		_track_fall(_was_on_floor_last_frame)
	
	_was_on_floor_last_frame = currently_on_floor
	
	# Handle vehicle interaction
	_handle_vehicle_interaction()
	
	# Only process player controls when mouse is captured and sim is playing
	if is_mouse_captured and CursorController.should_capture_look():
		# Handle controller look (right stick) - disabled in FPV drone mode (drone handles it)
		if not is_fpv_drone_mode:
			if _suppress_gamepad_look_until_axes_released:
				var look_axes := Input.get_vector("look_left", "look_right", "look_up", "look_down")
				if look_axes.length() < controller_deadzone:
					_suppress_gamepad_look_until_axes_released = false
			if not _suppress_gamepad_look_until_axes_released:
				_handle_controller_look(delta)
		
		# Handle jump (disabled when riding) - use effective floor check for coyote jump
		if not is_riding and Input.is_action_just_pressed("jump") and effectively_on_floor:
			velocity.y = jump_velocity
			_coyote_timer = 0  # Consume coyote time on jump
		
		# Handle tool use (left click) - disabled in FPV drone mode / prop grab
		if not is_fpv_drone_mode:
			var grab := get_node_or_null("GrabController")
			var block_tool: bool = grab != null and grab.has_method("blocks_tool_use") and grab.blocks_tool_use()
			if not block_tool:
				if Input.is_action_pressed("use_tool") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
					if tool_manager != null:
						tool_manager.use_tool()
				else:
					if tool_manager != null:
						tool_manager.stop_using_tool()
		
		# FPV drone mode - player body stays still, drone handles all input
		if is_fpv_drone_mode:
			velocity = Vector3.ZERO
			# Still need to call move_and_slide to stay on ground
		else:
			# Get movement input
			var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
			
			# Periodically fix transform when riding to prevent basis corruption from fast spinning
			if is_riding and Engine.get_physics_frames() % 60 == 0:
				transform.basis = transform.basis.orthonormalized()
			
				# Use cart-style steering when in cart mode
			if is_riding and use_cart_steering:
				_handle_cart_movement(input_dir, delta)
			elif is_riding and not is_golf_cart_mode:
				# EUC movement - forward/backward only, no strafing
				_handle_euc_movement(input_dir, delta)
			else:
				# Normal walking movement
				var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
				
				# Determine speed based on riding state
				var current_speed : float
				if is_riding:
					current_speed = move_speed * riding_speed_multiplier
					current_speed = minf(current_speed, riding_max_speed)
				else:
					current_speed = sprint_speed if Input.is_action_pressed("sprint") else move_speed
				
				# Apply movement
				if direction:
					velocity.x = direction.x * current_speed
					velocity.z = direction.z * current_speed
				else:
					# Smooth deceleration
					var decel_rate := current_speed * (0.5 if is_riding else 1.0)
					velocity.x = move_toward(velocity.x, 0, decel_rate)
					velocity.z = move_toward(velocity.z, 0, decel_rate)
	else:
		# When mouse not captured, decelerate to stop
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)
	
	# Try step climbing if moving horizontally and not riding a vehicle.
	# Throttled to ~20 Hz: the multi-direction/multi-height ray fan is the most
	# expensive per-frame physics query the player does, and step detection does
	# not need 60 Hz resolution for walking/stairs.
	if step_climb_enabled and not is_riding:
		_step_climb_accum += delta
		if _step_climb_accum >= _STEP_CLIMB_INTERVAL:
			_step_climb_accum = 0.0
			_try_step_climb()

	move_and_slide()
	_check_void_fall_respawn()

	# Update character animation based on movement
	_update_character_animation(delta)

## Drives whichever body is actually present — the rigged AnimationPlayer when
## the FBX pack loaded, else the procedural NpcSimpleFigure fallback.
func _update_character_animation(delta: float) -> void:
	if character_anim_player != null:
		_update_character_animation_rig()
	elif _simple_figure != null:
		_update_character_animation_simple(delta)

## Update character animation based on movement speed with smooth transitions
func _update_character_animation_rig() -> void:
	# Don't animate when riding a vehicle - show idle
	if is_riding:
		if current_anim_state != "idle" and not anim_idle_name.is_empty():
			character_anim_player.play(anim_idle_name, ANIM_BLEND_TIME)
			current_anim_state = "idle"
		return

	# Calculate horizontal movement speed
	var speed := Vector2(velocity.x, velocity.z).length()

	# Determine target state based on speed
	var target_state := "idle"
	if speed >= JOG_SPEED_THRESHOLD:
		target_state = "jog"
	elif speed >= WALK_SPEED_THRESHOLD:
		target_state = "walk"

	# Switch animation if state changed
	if target_state != current_anim_state:
		var target_anim := ""
		match target_state:
			"idle":
				target_anim = anim_idle_name if not anim_idle_name.is_empty() else anim_walk_name
			"walk":
				target_anim = anim_walk_name
			"jog":
				target_anim = anim_jog_name if not anim_jog_name.is_empty() else anim_walk_name

		if not target_anim.is_empty():
			character_anim_player.play(target_anim, ANIM_BLEND_TIME)
			current_anim_state = target_state

	# Adjust animation speed based on movement
	match current_anim_state:
		"idle":
			character_anim_player.speed_scale = 1.0
		"walk":
			# Scale walk speed: 0.5-6.0 movement → 0.8-1.2x animation
			var walk_factor := (speed - WALK_SPEED_THRESHOLD) / (JOG_SPEED_THRESHOLD - WALK_SPEED_THRESHOLD)
			character_anim_player.speed_scale = lerpf(0.8, 1.2, clampf(walk_factor, 0.0, 1.0))
		"jog":
			# Scale jog speed: 6.0-12.0 movement → 1.0-1.5x animation
			var jog_factor := (speed - JOG_SPEED_THRESHOLD) / 6.0
			character_anim_player.speed_scale = lerpf(1.0, 1.5, clampf(jog_factor, 0.0, 1.0))

## Same idle/walk/jog read as the rig branch above, but driven through
## NpcSimpleFigure.pose() — jog folds into a faster walk `rate` rather than a
## distinct pose, since the figure has no separate jog clip.
func _update_character_animation_simple(delta: float) -> void:
	if is_riding:
		_simple_figure.pose(NpcRig.CLIP_IDLE, 1.0, delta)
		return

	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < WALK_SPEED_THRESHOLD:
		_simple_figure.pose(NpcRig.CLIP_IDLE, 1.0, delta)
		return

	var rate := 1.0
	if speed >= JOG_SPEED_THRESHOLD:
		var jog_factor := (speed - JOG_SPEED_THRESHOLD) / 6.0
		rate = lerpf(1.2, 1.8, clampf(jog_factor, 0.0, 1.0))
	else:
		var walk_factor := (speed - WALK_SPEED_THRESHOLD) / (JOG_SPEED_THRESHOLD - WALK_SPEED_THRESHOLD)
		rate = lerpf(0.8, 1.2, clampf(walk_factor, 0.0, 1.0))
	_simple_figure.pose(NpcRig.CLIP_WALK, rate, delta)

func _handle_mouse_look(mouse_delta: Vector2) -> void:
	# Rotate player (yaw) on Y axis
	rotate_y(-mouse_delta.x * mouse_sensitivity)
	
	# Rotate camera (pitch) on X axis, clamped
	var y_direction := 1.0 if invert_y_axis else -1.0
	camera.rotate_x(mouse_delta.y * mouse_sensitivity * y_direction)
	camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(min_pitch), deg_to_rad(max_pitch))

func _handle_controller_look(delta: float) -> void:
	var look_input := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	
	var look_magnitude := look_input.length()
	if look_magnitude < controller_deadzone:
		return
	
	# Remap from [deadzone, 1.0] to [0.0, 1.0] for smooth ramp from edge of deadzone
	var remapped := (look_magnitude - controller_deadzone) / (1.0 - controller_deadzone)
	var adjusted_magnitude := pow(remapped, 1.5)
	look_input = look_input.normalized() * adjusted_magnitude
	
	rotate_y(-look_input.x * controller_sensitivity * delta)
	
	var y_direction := 1.0 if invert_y_axis else -1.0
	camera.rotate_x(look_input.y * controller_sensitivity * delta * y_direction)
	camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(min_pitch), deg_to_rad(max_pitch))

func _capture_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	is_mouse_captured = true

func _release_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	is_mouse_captured = false
	_suppress_gamepad_look_until_axes_released = false

## Fix player transform after fast spinning to prevent inverted controls
## Orthonormalizes the basis and extracts clean Y rotation
func _fix_player_transform() -> void:
	# Orthonormalize the basis to fix any accumulated floating-point errors
	transform.basis = transform.basis.orthonormalized()
	
	# Extract the current Y rotation and reset to a clean transform
	# This ensures the player is only rotated around Y axis (no X or Z rotation)
	var current_y_rotation := rotation.y
	
	# Reset to identity basis, then apply only the Y rotation
	transform.basis = Basis()
	rotation.y = current_y_rotation
	
	# Ensure player stays upright (no X or Z rotation on the body)
	rotation.x = 0.0
	rotation.z = 0.0

## Step climbing - automatically step up small ledges and stairs
## Uses multiple raycasts to detect steps from different angles
## More forgiving than standard CharacterBody3D movement
func _try_step_climb() -> void:
	# Only try to climb when on or very near floor and moving
	if not is_on_floor():
		# Allow step climbing when slightly in the air (falling onto a step)
		if velocity.y > 0.1:  # Going up, don't interfere
			return
	
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)
	var speed := horizontal_velocity.length()
	if speed < 0.05:  # Very low threshold to catch slow movement
		return
	
	var move_direction := horizontal_velocity.normalized()
	var space_state := get_world_3d().direct_space_state
	
	# Parameters
	var player_pos := global_position
	var player_radius := 0.35
	var check_distance := 0.6 + player_radius  # How far ahead to check
	
	# Try multiple forward directions for better coverage
	var directions_to_check : Array[Vector3] = [
		move_direction,  # Primary direction
		move_direction.rotated(Vector3.UP, deg_to_rad(25)),  # Slightly left
		move_direction.rotated(Vector3.UP, deg_to_rad(-25)),  # Slightly right
	]
	
	for check_dir in directions_to_check:
		var step_result := _check_step_in_direction(space_state, player_pos, check_dir, check_distance, player_radius)
		if step_result.found:
			# Found a valid step - climb it
			global_position.y = step_result.height + 0.02
			velocity.y = maxf(velocity.y, 0.5)  # Give a small upward boost
			return

## Check for a climbable step in a specific direction
func _check_step_in_direction(space_state: PhysicsDirectSpaceState3D, player_pos: Vector3, 
		direction: Vector3, check_distance: float, player_radius: float) -> Dictionary:
	
	var result := { "found": false, "height": 0.0 }
	
	# Cast ray at multiple heights to find obstacles
	var foot_heights := [0.05, 0.15, 0.25]  # Check at different foot levels
	var found_obstacle := false
	var obstacle_pos := Vector3.ZERO
	
	for foot_h in foot_heights:
		var ray_origin := player_pos + Vector3(0, foot_h, 0)
		var ray_end := ray_origin + direction * check_distance
		
		var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
		query.exclude = [self]
		query.collision_mask = collision_mask
		
		var ray_result := space_state.intersect_ray(query)
		if not ray_result.is_empty():
			found_obstacle = true
			obstacle_pos = ray_result.position
			break
	
	if not found_obstacle:
		return result
	
	# Check if there's clearance at head height (is it a step or a wall?)
	var head_clearance_height := step_height + 0.3
	var head_ray_origin := player_pos + Vector3(0, head_clearance_height, 0)
	var head_ray_end := head_ray_origin + direction * check_distance
	
	var head_query := PhysicsRayQueryParameters3D.create(head_ray_origin, head_ray_end)
	head_query.exclude = [self]
	head_query.collision_mask = collision_mask
	
	var head_result := space_state.intersect_ray(head_query)
	
	# If blocked at head height too, it's a wall, not a step
	if not head_result.is_empty():
		# Check if the wall is close (actual wall) vs far (step with wall behind)
		var head_hit_dist := head_ray_origin.distance_to(head_result.position)
		var foot_hit_dist := (player_pos + Vector3(0, 0.1, 0)).distance_to(obstacle_pos)
		if head_hit_dist <= foot_hit_dist + 0.2:
			return result  # It's a wall
	
	# Cast downward from above the obstacle to find the step surface
	var down_ray_origin := obstacle_pos + Vector3(0, step_height + 0.3, 0) + direction * 0.15
	var down_ray_end := down_ray_origin - Vector3(0, step_height + 0.5, 0)
	
	var down_query := PhysicsRayQueryParameters3D.create(down_ray_origin, down_ray_end)
	down_query.exclude = [self]
	down_query.collision_mask = collision_mask
	
	var down_result := space_state.intersect_ray(down_query)
	
	if down_result.is_empty():
		# Try casting from slightly further forward
		down_ray_origin = obstacle_pos + Vector3(0, step_height + 0.3, 0) + direction * 0.35
		down_query = PhysicsRayQueryParameters3D.create(down_ray_origin, down_ray_end)
		down_query.exclude = [self]
		down_query.collision_mask = collision_mask
		down_result = space_state.intersect_ray(down_query)
		
		if down_result.is_empty():
			return result
	
	# Check if the surface normal is acceptable (not too steep to stand on)
	var surface_normal : Vector3 = down_result.normal
	if surface_normal.y < step_climb_tolerance:
		return result
	
	# Calculate actual step height
	var step_top : float = down_result.position.y
	var current_foot : float = player_pos.y
	var actual_step := step_top - current_foot
	
	# Valid step: higher than a tiny lip, but not too high
	if actual_step > 0.03 and actual_step <= step_height:
		result.found = true
		result.height = step_top
	
	return result

## Try to find nearby floor when crossing a small gap
## Casts rays downward and forward-down to find floor to snap to
func _try_bridge_gap() -> void:
	var space_state := get_world_3d().direct_space_state
	var player_pos := global_position
	
	# Get movement direction
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)
	var move_dir := horizontal_velocity.normalized() if horizontal_velocity.length() > 0.1 else -transform.basis.z
	
	# Cast rays in a pattern to find floor ahead
	var ray_offsets : Array[Vector3] = [
		Vector3.ZERO,  # Directly below
		move_dir * 0.3,  # Slightly ahead
		move_dir * 0.5,  # More ahead
		move_dir * 0.7,  # Even more ahead
	]
	
	for offset in ray_offsets:
		var ray_origin : Vector3 = player_pos + offset + Vector3(0, 0.2, 0)
		var ray_end : Vector3 = ray_origin - Vector3(0, 1.0, 0)  # Cast 1m down
		
		var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
		query.exclude = [self]
		query.collision_mask = collision_mask
		
		var result := space_state.intersect_ray(query)
		
		if not result.is_empty():
			var hit_pos : Vector3 = result.position
			var surface_normal : Vector3 = result.normal
			
			# Check if it's a floor (not a wall)
			if surface_normal.y > 0.7:
				# Found floor - check if it's at an acceptable height
				var height_diff := hit_pos.y - player_pos.y
				
				# If the floor is close to our height or slightly below, snap to it
				if height_diff > -0.5 and height_diff < 0.3:
					global_position.y = hit_pos.y + 0.02
					velocity.y = 0.0
					_coyote_timer = COYOTE_TIME  # Reset coyote time
					return

func _track_fall(was_on_floor: bool) -> void:
	var current_height := global_position.y
	
	# Started falling (left the ground)
	if was_on_floor and not is_on_floor():
		is_falling = true
		fall_start_height = current_height
		highest_point_during_fall = current_height
	
	# Still in the air - track highest point (for jumps that go up first)
	if is_falling and not is_on_floor():
		if current_height > highest_point_during_fall:
			highest_point_during_fall = current_height
	
	# Landed
	if is_falling and is_on_floor():
		var fall_distance := highest_point_during_fall - current_height
		is_falling = false
		void_reference_y = current_height
		
		# Check for fatal fall
		if fall_distance >= fatal_fall_distance:
			_die_from_fall(fall_distance)


func _check_void_fall_respawn() -> void:
	if void_fall_respawn_distance <= 0.0:
		return
	if is_riding and not is_fpv_drone_mode:
		return
	if _void_respawn_cooldown_s > 0.0:
		return
	if is_fpv_drone_mode:
		_check_fpv_body_void_respawn()
		return
	if is_on_floor():
		void_reference_y = global_position.y
		return
	if global_position.y > void_reference_y - void_fall_respawn_distance:
		return
	_respawn_from_void()


func _check_fpv_body_void_respawn() -> void:
	var main := get_tree().current_scene
	var floor_y := global_position.y
	if main != null:
		var gy := TerrainSurfaceQuery.ground_height_at(main, global_position.x, global_position.z)
		if gy != 0.0:
			floor_y = gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
		elif "player_spawn_position" in main:
			floor_y = main.player_spawn_position.y
	if global_position.y < floor_y - 1.0 \
			or global_position.y < void_reference_y - void_fall_respawn_distance:
		_respawn_from_void()
	elif is_on_floor():
		void_reference_y = global_position.y


func _respawn_from_void() -> void:
	var main := get_tree().current_scene
	var target := global_position
	if main != null and "player_spawn_position" in main:
		target = main.player_spawn_position
	if main != null:
		var gy := TerrainSurfaceQuery.ground_height_at(main, target.x, target.z)
		if gy != 0.0:
			target.y = gy + TerrainBuilder.PLAYER_SPAWN_CLEARANCE_M
	global_position = target
	velocity = Vector3.ZERO
	is_falling = false
	fall_start_height = target.y
	highest_point_during_fall = target.y
	void_reference_y = target.y
	_void_respawn_cooldown_s = 1.5
	push_warning("Player: void fall — respawned at y=%.1f" % target.y)

func _die_from_fall(fall_distance: float) -> void:
	var gr := GameplayRulesImpl.from_node(self)
	if gr == null or not gr.is_survival_active() or not gr.is_fall_damage_enabled():
		return
	
	var feet_fallen := fall_distance * 3.28084  # Convert meters to feet
	
	# Check if we have a health system - use it for damage
	var health_system = get_node_or_null("PlayerHealth")
	if health_system != null and health_system.has_method("take_damage"):
		# Calculate damage based on fall distance (more fall = more damage)
		var fall_damage = 50.0 + (feet_fallen - 15.0) * 5.0  # Base 50 + 5 per foot over 15ft
		fall_damage = minf(fall_damage, 200.0)  # Cap at 200 for instant death falls
		health_system.take_damage(fall_damage, "fall")
	else:
		# Fallback to instant death if no health system
		player_died.emit("You have died of an OSHA violation")

# ==================== VEHICLE/EUC SYSTEM ====================

func _handle_vehicle_interaction() -> void:
	# Check for dismount input when riding (X key)
	# Works for ALL vehicle types (EUC, golf cart, FPV drone, etc.)
	if is_riding:
		if Input.is_action_just_pressed("dismount"):
			_dismount_vehicle()
			return
	
	# Check for repair input when near a shorted vehicle (R key)
	if not is_riding and nearby_vehicle != null:
		if Input.is_action_just_pressed("repair"):
			if nearby_vehicle.has_method("needs_repair") and nearby_vehicle.needs_repair():
				if nearby_vehicle.has_method("repair"):
					nearby_vehicle.repair()
					_update_nearby_vehicle_prompt()
					return
	
	# Check for grab extinguisher input (O key) - prioritize over vehicle mounting
	if not is_riding and nearby_extinguisher != null:
		if Input.is_action_just_pressed("interact"):
			_grab_extinguisher()
			return
	
	# Check for mount input when near a vehicle (O key)
	# Automatically stop charging if needed - user shouldn't have to disconnect manually
	if not is_riding and nearby_vehicle != null:
		if Input.is_action_just_pressed("interact"):
			# Check if vehicle needs repair first
			if nearby_vehicle.has_method("needs_repair") and nearby_vehicle.needs_repair():
				# Can't mount - show repair prompt
				if interaction_ui != null and interaction_ui.has_method("show_repair_prompt"):
					interaction_ui.show_repair_prompt()
				return
			# Stop charging first if the vehicle is currently charging
			if is_charging_euc:
				_stop_charging()
			_mount_vehicle(nearby_vehicle)
			return
	
	# Check for charge input when near a charging station (C key)
	if not is_riding and not is_charging_euc:
		if Input.is_action_just_pressed("charge"):
			if nearby_charging_station != null and is_instance_valid(nearby_charging_station):
				if nearby_charging_station.has_method("can_charge") and nearby_charging_station.can_charge():
					_start_charging()
					return
	
	# Handle stop charging input (X key - same as dismount)
	if is_charging_euc and Input.is_action_just_pressed("dismount"):
		_stop_charging()

func _mount_vehicle(vehicle: Node3D) -> void:
	if vehicle == null or not vehicle.has_method("mount"):
		return
	
	if vehicle.mount(self):
		is_riding = true
		current_vehicle = vehicle
		shake_time = 0.0  # Reset shake timer
		is_golf_cart_mode = false
		use_cart_steering = false
		riding_camera_offset = Vector3.ZERO
		riding_min_shake_speed = 1.0
		cart_current_speed = 0.0
		
		# Get riding parameters from vehicle
		if vehicle.has_method("get_riding_params"):
			var params : Dictionary = vehicle.get_riding_params()
			riding_speed_multiplier = params.get("speed_multiplier", 3.0)
			riding_max_speed = params.get("max_speed", 25.0)
			riding_max_tilt = params.get("max_camera_tilt", 25.0)
			riding_tilt_speed = params.get("tilt_speed", 5.0)
			riding_shake_intensity = params.get("camera_shake_intensity", 0.015)
			riding_shake_speed = params.get("camera_shake_speed", 15.0)
			riding_min_shake_speed = params.get("min_shake_speed", 1.0)
			riding_camera_offset = params.get("camera_offset", Vector3.ZERO)
			is_golf_cart_mode = params.get("is_golf_cart", false)
			use_cart_steering = params.get("use_cart_steering", false)
			cart_min_turn_radius = params.get("min_turn_radius", 3.0)
			cart_max_turn_rate = params.get("max_turn_rate", 60.0)
			is_fpv_drone_mode = params.get("is_fpv_drone", false)
		
		# FPV drone mode - player body stays stationary, drone handles camera
		if is_fpv_drone_mode:
			# Player stays in place, drone handles all movement/camera
			velocity = Vector3.ZERO
			# Brief dismount hint — hidden after a few seconds while flying
			if interaction_ui != null and interaction_ui.has_method("show_dismount_prompt_transient"):
				interaction_ui.show_dismount_prompt_transient(4.0)
			mounted_vehicle.emit(vehicle)
			return
		
		# Apply camera offset for golf cart mode
		if is_golf_cart_mode and riding_camera_offset != Vector3.ZERO:
			camera.position = base_camera_position + riding_camera_offset
		
		# Adjust character model for EUC riding (raise up to stand on pedals)
		if not is_golf_cart_mode:
			_set_character_riding_position(true)
		
		# Update interaction UI
		if interaction_ui != null and interaction_ui.has_method("show_dismount_prompt"):
			interaction_ui.show_dismount_prompt()
		
		# Show EUC UI (works for golf cart too)
		if euc_ui != null and euc_ui.has_method("show_ui"):
			euc_ui.show_ui(vehicle)
		
		mounted_vehicle.emit(vehicle)


## After load: re-link player to FPV drone without going through mount() (restores exact flight + view).
func apply_fpv_drone_restore_after_load(vehicle: Node3D) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		return
	is_riding = true
	current_vehicle = vehicle
	shake_time = 0.0
	is_golf_cart_mode = false
	use_cart_steering = false
	riding_camera_offset = Vector3.ZERO
	riding_min_shake_speed = 1.0
	cart_current_speed = 0.0
	current_camera_tilt = 0.0
	is_fpv_drone_mode = true
	velocity = Vector3.ZERO
	if vehicle.has_method("get_riding_params"):
		var params: Dictionary = vehicle.get_riding_params()
		riding_speed_multiplier = float(params.get("speed_multiplier", 0.0))
		riding_max_speed = float(params.get("max_speed", 0.0))
		riding_max_tilt = float(params.get("max_camera_tilt", 25.0))
		riding_tilt_speed = float(params.get("tilt_speed", 5.0))
		riding_shake_intensity = float(params.get("camera_shake_intensity", 0.015))
		riding_shake_speed = float(params.get("camera_shake_speed", 15.0))
		riding_min_shake_speed = float(params.get("min_shake_speed", 1.0))
		riding_camera_offset = params.get("camera_offset", Vector3.ZERO)
	if interaction_ui != null and interaction_ui.has_method("show_dismount_prompt_transient"):
		interaction_ui.show_dismount_prompt_transient(4.0)
	mounted_vehicle.emit(vehicle)


func _dismount_vehicle() -> void:
	if current_vehicle == null:
		return
	
	var vehicle := current_vehicle
	var was_golf_cart := is_golf_cart_mode
	var was_fpv_drone := is_fpv_drone_mode
	
	if vehicle.has_method("dismount"):
		vehicle.dismount()
	
	is_riding = false
	current_vehicle = null
	is_golf_cart_mode = false
	use_cart_steering = false
	is_fpv_drone_mode = false
	cart_current_speed = 0.0
	riding_camera_offset = Vector3.ZERO
	
	# Reset character position after EUC riding (but not after FPV drone)
	if not was_golf_cart and not was_fpv_drone:
		_set_character_riding_position(false)
	
	# Reset camera tilt, shake, and position
	current_camera_tilt = 0.0
	camera.rotation.z = 0.0
	camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
	camera.position = base_camera_position
	shake_time = 0.0
	
	# Fix player transform after fast spinning - orthonormalize to fix any basis corruption
	# This prevents controls from being inverted due to accumulated floating-point errors
	_fix_player_transform()
	
	# Hide EUC UI
	if euc_ui != null and euc_ui.has_method("hide_ui"):
		euc_ui.hide_ui()
	
	# Update interaction UI - check for charging station first, then vehicle prompts
	_update_charging_station_prompt()
	
	dismounted_vehicle.emit(vehicle)

## Handle EUC movement - forward/backward only with realistic banking on turns
func _handle_euc_movement(input_dir: Vector2, delta: float) -> void:
	# EUC only moves forward/backward - ignore strafe input (A/D)
	var forward_input := -input_dir.y  # W/S (negative because forward is -Y in input)
	
	# Calculate current speed
	var current_speed := move_speed * riding_speed_multiplier
	current_speed = minf(current_speed, riding_max_speed)
	
	# Apply forward/backward movement in the direction player is facing
	var forward_dir := -transform.basis.z
	
	if absf(forward_input) > 0.1:
		velocity.x = forward_dir.x * current_speed * forward_input
		velocity.z = forward_dir.z * current_speed * forward_input
	else:
		# Smooth deceleration when not pressing forward/back
		var decel_rate := current_speed * 0.5
		velocity.x = move_toward(velocity.x, 0, decel_rate)
		velocity.z = move_toward(velocity.z, 0, decel_rate)
	
	# Calculate turn rate (how fast player is rotating via mouse look)
	var rotation_delta := rotation.y - previous_rotation_y
	# Normalize to handle wrap-around at +/- PI
	if rotation_delta > PI:
		rotation_delta -= TAU
	elif rotation_delta < -PI:
		rotation_delta += TAU
	
	# Smooth the turn rate for less jittery tilt
	var raw_turn_rate := rotation_delta / delta if delta > 0 else 0.0
	current_turn_rate = lerp(current_turn_rate, raw_turn_rate, 10.0 * delta)
	previous_rotation_y = rotation.y
	
	# Calculate current horizontal speed
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	
	# Calculate tilt based on turn rate AND speed
	# More speed + harder turn = more bank
	var speed_factor := clampf(horizontal_speed / riding_max_speed, 0.0, 1.0)
	var turn_factor := clampf(current_turn_rate / 3.0, -1.0, 1.0)  # Normalize turn rate
	
	# Banking: tilt into the turn, scaled by speed (negative to lean INTO the turn)
	var bank_amount := -turn_factor * speed_factor
	_update_camera_tilt(bank_amount, delta)
	
	# Camera shake based on movement
	_update_camera_shake(delta, horizontal_speed > riding_min_shake_speed)

## Handle cart-style movement with wide turning radius
func _handle_cart_movement(input_dir: Vector2, delta: float) -> void:
	var forward_input := -input_dir.y  # W/S or up/down (negative because forward is -Y in input)
	var steer_input := input_dir.x     # A/D or left/right
	
	# Acceleration/deceleration
	var target_speed := forward_input * riding_max_speed
	var accel_rate := 3.0 if forward_input != 0 else 5.0  # Faster braking than acceleration
	
	# Allow reverse at slower speed
	if forward_input < 0:
		target_speed = forward_input * (riding_max_speed * 0.3)  # Reverse at 30% max speed
	
	cart_current_speed = move_toward(cart_current_speed, target_speed, accel_rate * delta)
	
	# Steering - can only turn when moving
	var speed_factor := absf(cart_current_speed) / riding_max_speed
	if speed_factor > 0.05:  # Need some speed to turn
		# Calculate turn rate based on speed
		# At low speed: tighter turns allowed (but still limited)
		# At high speed: wider turns required
		var turn_rate := cart_max_turn_rate * steer_input
		
		# Reduce turn rate at higher speeds (wider turning radius)
		var high_speed_factor := clampf(speed_factor, 0.3, 1.0)
		turn_rate *= (1.0 / high_speed_factor) * 0.5
		
		# Clamp turn rate to prevent spinning
		turn_rate = clampf(turn_rate, -cart_max_turn_rate, cart_max_turn_rate)
		
		# Reverse steering direction when going backwards
		if cart_current_speed < 0:
			turn_rate = -turn_rate
		
		# Apply rotation to player
		rotation.y -= deg_to_rad(turn_rate) * delta
	
	# Apply velocity in the direction we're facing
	var forward_dir := -transform.basis.z
	velocity.x = forward_dir.x * cart_current_speed
	velocity.z = forward_dir.z * cart_current_speed
	
	# Update camera effects
	_update_camera_tilt(steer_input * 0.3, delta)  # Less tilt for cart
	_update_camera_shake(delta, absf(cart_current_speed) > 0.5)

func _update_camera_tilt(turn_input: float, delta: float) -> void:
	# Target tilt based on turn input (negative = tilt left when turning left)
	var target_tilt := -turn_input * riding_max_tilt
	
	# Smoothly interpolate to target tilt
	current_camera_tilt = lerp(current_camera_tilt, target_tilt, riding_tilt_speed * delta)
	
	# Apply tilt to camera Z rotation (roll)
	camera.rotation.z = deg_to_rad(current_camera_tilt)

func _update_camera_shake(delta: float, _is_moving: bool) -> void:
	if not is_riding:
		# Reset camera position when not riding
		camera.position = base_camera_position
		return
	
	# Calculate current horizontal speed
	var current_speed : float = Vector2(velocity.x, velocity.z).length()
	
	# Determine base position (with offset for golf cart)
	var target_base : Vector3 = base_camera_position
	if is_golf_cart_mode and riding_camera_offset != Vector3.ZERO:
		target_base = base_camera_position + riding_camera_offset
	
	# No shake when stationary or very slow - scales smoothly from 0
	if current_speed < riding_min_shake_speed:
		# Smoothly return to base position when slow/stopped
		camera.position = camera.position.lerp(target_base, delta * 5.0)
		return
	
	shake_time += delta * riding_shake_speed
	
	# Calculate shake intensity based on speed (0 at min_speed, full at max_speed)
	var speed_factor : float = clampf((current_speed - riding_min_shake_speed) / (riding_max_speed - riding_min_shake_speed), 0.0, 1.0)
	var shake_amount : float = riding_shake_intensity * speed_factor
	
	# Golf cart gets more shake even at lower speeds
	if is_golf_cart_mode:
		shake_amount = riding_shake_intensity * (0.3 + speed_factor * 0.7)  # Always at least 30% shake
	
	# Multi-frequency shake for more natural feel
	var shake_x : float = sin(shake_time * 1.0) * 0.3 + sin(shake_time * 2.3) * 0.4 + sin(shake_time * 3.7) * 0.3
	var shake_y : float = sin(shake_time * 1.1 + 0.5) * 0.4 + sin(shake_time * 2.7) * 0.35 + sin(shake_time * 4.1) * 0.25
	
	# Apply shake offset to camera position
	camera.position = target_base + Vector3(
		shake_x * shake_amount,
		shake_y * shake_amount * 0.7,  # Less vertical shake
		0
	)

## Called by EUC/vehicle when player enters interaction range
func on_vehicle_nearby(vehicle: Node3D) -> void:
	if is_riding:
		return
	
	nearby_vehicle = vehicle
	
	# Show interaction prompt (custom or default)
	_update_nearby_vehicle_prompt()

## Called by EUC/vehicle when player exits interaction range
func on_vehicle_left_range(vehicle: Node3D) -> void:
	if nearby_vehicle == vehicle:
		nearby_vehicle = null
	
	# Update prompt (unless riding)
	if not is_riding:
		_update_nearby_vehicle_prompt()

# ==================== FIRE EXTINGUISHER PICKUP SYSTEM ====================

## Called by extinguisher pickup when player enters range
func on_extinguisher_nearby(extinguisher: Node3D) -> void:
	nearby_extinguisher = extinguisher
	_update_nearby_vehicle_prompt()

## Called by extinguisher pickup when player exits range
func on_extinguisher_left_range(extinguisher: Node3D) -> void:
	if nearby_extinguisher == extinguisher:
		nearby_extinguisher = null
	_update_nearby_vehicle_prompt()

## Grab the nearby extinguisher
func _grab_extinguisher() -> void:
	if nearby_extinguisher == null:
		return
	
	if nearby_extinguisher.has_method("grab"):
		if nearby_extinguisher.grab():
			extinguisher_count += 1
			
			# Equip fire extinguisher tool if not already equipped
			if tool_manager != null:
				tool_manager.equip_tool("fire_extinguisher")
				
				# Update the tool's charge multiplier
				var current_tool : Node3D = tool_manager.get_current_tool()
				if current_tool != null and current_tool.has_method("set_charge_multiplier"):
					current_tool.set_charge_multiplier(extinguisher_count)
			
			nearby_extinguisher = null
			_update_nearby_vehicle_prompt()

## Get extinguisher count (for tool manager to query)
func get_extinguisher_count() -> int:
	return extinguisher_count

## Update the interaction prompt based on nearby objects (extinguisher, vehicle, charging station)
func _update_nearby_vehicle_prompt() -> void:
	if interaction_ui == null:
		return
	if _interaction_focus != null and _interaction_focus.has_method("get_focused"):
		if _interaction_focus.get_focused() != null:
			return
	
	# Check for nearby fire extinguisher pickup (highest priority)
	if nearby_extinguisher != null and is_instance_valid(nearby_extinguisher):
		var prompt_text := "Grab Fire Extinguisher"
		if nearby_extinguisher.has_method("get_interaction_prompt"):
			prompt_text = nearby_extinguisher.get_interaction_prompt()
		if interaction_ui.has_method("show_action_prompt"):
			interaction_ui.show_action_prompt("interact", prompt_text)
		return
	
	# Check if vehicle needs repair (shorted from rain)
	var needs_repair := false
	if nearby_vehicle != null and nearby_vehicle.has_method("needs_repair"):
		needs_repair = nearby_vehicle.needs_repair()
	
	# If vehicle needs repair, show repair prompt
	if needs_repair:
		if interaction_ui.has_method("show_repair_prompt"):
			interaction_ui.show_repair_prompt()
		return
	
	# Check if charging is available
	var can_charge := false
	var charge_vehicle_name := "Vehicle"
	if nearby_charging_station != null and is_instance_valid(nearby_charging_station):
		if nearby_charging_station.has_method("can_charge") and nearby_charging_station.can_charge():
			can_charge = true
			if nearby_charging_station.has_method("get_euc_in_range"):
				var charge_vehicle = nearby_charging_station.get_euc_in_range()
				if charge_vehicle != null and "display_name" in charge_vehicle:
					charge_vehicle_name = charge_vehicle.display_name
	
	# Get ride prompt text
	var ride_prompt := ""
	if nearby_vehicle != null:
		if nearby_vehicle.has_method("get_interaction_prompt"):
			ride_prompt = nearby_vehicle.get_interaction_prompt()
		if ride_prompt.is_empty():
			ride_prompt = "Ride Electric Unicycle"
	
	# Show appropriate prompt(s)
	if nearby_vehicle != null and can_charge:
		# Both actions available - show combined prompt
		if interaction_ui.has_method("show_ride_and_charge_prompt"):
			interaction_ui.show_ride_and_charge_prompt(ride_prompt, charge_vehicle_name)
		else:
			# Fallback to just charge prompt
			interaction_ui.show_custom_charge_prompt(charge_vehicle_name)
	elif nearby_vehicle != null:
		# Only ride available
		if interaction_ui.has_method("show_custom_ride_prompt"):
			interaction_ui.show_custom_ride_prompt(ride_prompt)
		elif interaction_ui.has_method("show_ride_prompt"):
			interaction_ui.show_ride_prompt()
	elif can_charge:
		# Only charge available
		if interaction_ui.has_method("show_custom_charge_prompt"):
			interaction_ui.show_custom_charge_prompt(charge_vehicle_name)
	else:
		# No actions available - hide prompt
		if interaction_ui.has_method("hide_prompt"):
			interaction_ui.hide_prompt()

## Check if currently riding a vehicle
func is_on_vehicle() -> bool:
	return is_riding

# ==================== CHARGING STATION SYSTEM ====================

# Note: Charging interaction is now handled in _handle_vehicle_interaction() 
# to properly prioritize charging over mounting when near a charging station

func _start_charging() -> void:
	if nearby_charging_station == null or not is_instance_valid(nearby_charging_station):
		return
	
	if not nearby_charging_station.has_method("can_charge"):
		return
	
	if not nearby_charging_station.can_charge():
		return
	
	if nearby_charging_station.has_method("start_charging"):
		var euc : Node3D = null
		if nearby_charging_station.has_method("get_euc_in_range"):
			euc = nearby_charging_station.get_euc_in_range()
		if nearby_charging_station.start_charging(euc):
			is_charging_euc = true
			
			# Update UI
			if interaction_ui != null and interaction_ui.has_method("show_stop_charge_prompt"):
				interaction_ui.show_stop_charge_prompt()

func _stop_charging() -> void:
	if nearby_charging_station != null and is_instance_valid(nearby_charging_station):
		if nearby_charging_station.has_method("stop_charging"):
			nearby_charging_station.stop_charging()
	
	is_charging_euc = false
	
	# Update UI
	if interaction_ui != null:
		if nearby_charging_station != null and nearby_charging_station.has_method("can_charge") and nearby_charging_station.can_charge():
			if interaction_ui.has_method("show_charge_prompt"):
				interaction_ui.show_charge_prompt()
		elif interaction_ui.has_method("hide_prompt"):
			interaction_ui.hide_prompt()

## Update charging station prompt after dismounting
func _update_charging_station_prompt() -> void:
	# First check for charging station (takes priority)
	if nearby_charging_station != null and is_instance_valid(nearby_charging_station):
		# Give the charging station a moment to detect the now-dismounted vehicle
		call_deferred("_check_and_show_charge_prompt")
	else:
		# No charging station, show vehicle prompt if applicable
		_update_nearby_vehicle_prompt()

func _check_and_show_charge_prompt() -> void:
	# Use the unified prompt system that handles both ride and charge
	_update_nearby_vehicle_prompt()

## Called by charging station when player enters range
func on_charging_station_nearby(station: Node3D) -> void:
	# Always remember the nearby charging station (even when riding)
	# so we can interact with it after dismounting
	nearby_charging_station = station
	
	# Don't show UI prompts if currently riding or already charging
	if is_riding or is_charging_euc:
		return
	
	# Update prompts (will show combined prompt if vehicle also nearby)
	_update_nearby_vehicle_prompt()

## Called by charging station when player leaves range
func on_charging_station_left_range(station: Node3D) -> void:
	if nearby_charging_station == station:
		# Stop charging if we were charging
		if is_charging_euc:
			_stop_charging()
		
		nearby_charging_station = null
		
		# Hide prompt unless near a vehicle
		if not is_riding and interaction_ui != null:
			if nearby_vehicle != null and interaction_ui.has_method("show_ride_prompt"):
				interaction_ui.show_ride_prompt()
			elif interaction_ui.has_method("hide_prompt"):
				interaction_ui.hide_prompt()

# ==================== TOOL SYSTEM ====================

## Setup tool manager
func _setup_tool_manager() -> void:
	# Create tool manager if it doesn't exist
	if tool_manager == null:
		var tool_mgr := preload("res://player_tools/tool_manager.gd").new()
		tool_mgr.name = "ToolManager"
		add_child(tool_mgr)
		tool_manager = tool_mgr
		tool_mgr.add_to_group("tool_manager")
	
	# Set up tool manager references
	if tool_manager != null:
		tool_manager.player = self
		tool_manager.camera = camera

## Debug: Force trigger a fire event (F key). Always works regardless of
## survival / pause state. Prints diagnostics and shows an on-screen toast.
func _trigger_fire_event_debug() -> void:
	print("[FireDebug] F pressed — attempting to trigger manual fire event…")
	var tree := get_tree()
	if tree == null:
		_show_fire_debug_toast("⚠ No scene tree", false)
		return
	
	var manager := tree.get_first_node_in_group("crisis_event_manager")
	if manager == null:
		var main_scene := tree.current_scene
		if main_scene != null:
			manager = main_scene.get_node_or_null("CrisisEventManager")
	
	if manager == null:
		push_warning("[FireDebug] CrisisEventManager not found in scene")
		_show_fire_debug_toast("⚠ CrisisEventManager missing", false)
		return
	
	if not manager.has_method("trigger_event_manual"):
		push_warning("[FireDebug] manager has no trigger_event_manual()")
		_show_fire_debug_toast("⚠ Manager API mismatch", false)
		return
	
	var fire_event_script := load("res://crisis_events/fire/fire_event.gd") as GDScript
	if fire_event_script == null:
		_show_fire_debug_toast("⚠ Fire script missing", false)
		return
	var fire_event = fire_event_script.new()
	if fire_event == null:
		_show_fire_debug_toast("⚠ Fire event alloc failed", false)
		return
	
	# Build context: fire locks to ONE selected structure (focused or nearest
	# burnable PlacedProp). Never spreads to player / drone / SoI poles.
	var context := {}
	context["scene_tree"] = tree
	context["player"] = self
	context["prefer_near_player"] = true
	context["prefer_bottom"] = true
	context["restrict_to_structure"] = true

	var scope: Node3D = null
	# Prefer the interactable currently under the crosshair.
	if _interaction_focus != null and _interaction_focus.has_method("get_focused"):
		var focused = _interaction_focus.get_focused()
		if focused is PlacedProp and (focused as PlacedProp).burnable:
			scope = focused as PlacedProp
	# Else nearest burnable placed prop within 80 m.
	if scope == null:
		scope = _find_nearest_burnable_prop(80.0)
	if scope != null:
		context["structure"] = scope
		var roots: Array[Node3D] = []
		roots.append(scope)
		context["burnable_roots"] = roots
	else:
		# Fallback: classic scene structures (Soak / LinkageLab) if no prop nearby.
		var main_scene := tree.current_scene
		if main_scene != null:
			var structure_node := _find_structure_node(main_scene)
			if structure_node != null:
				context["structure"] = structure_node
				var roots2: Array[Node3D] = []
				roots2.append(structure_node)
				context["burnable_roots"] = roots2

	if not fire_event.can_trigger(context):
		push_warning("[FireDebug] FireEvent.can_trigger() = false — aim at a burnable prop (Burnable toggle) or stand near one")
		_show_fire_debug_toast("⚠ No burnable geometry found", false)
		return

	var ok : bool = manager.trigger_event_manual(fire_event, context)
	if ok:
		print("[FireDebug] 🔥 Fire spawned on '%s'" % str(context.get("structure", "?")))
		_show_fire_debug_toast("🔥 Fire triggered!", true)
	else:
		push_warning("[FireDebug] trigger_event_manual returned false")
		_show_fire_debug_toast("⚠ Fire failed to start", false)


func _find_nearest_burnable_prop(max_dist_m: float) -> PlacedProp:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var best: PlacedProp = null
	var best_d := max_dist_m * max_dist_m
	for node in tree.current_scene.find_children("*", "PlacedProp", true, false):
		var prop := node as PlacedProp
		if prop == null or not prop.burnable:
			continue
		var d := global_position.distance_squared_to(prop.global_position)
		if d < best_d:
			best_d = d
			best = prop
	return best


## Brief on-screen toast for fire-debug feedback — top of screen (CrisisEventUI).
func _show_fire_debug_toast(message: String, success: bool) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var main_scene := tree.current_scene
	if main_scene == null:
		return
	var crisis_ui := main_scene.get_node_or_null("UILayer/CrisisEventUI")
	if crisis_ui != null and crisis_ui.has_method("_show_alert"):
		var title := "FIRE" if success else "FIRE"
		crisis_ui.call("_show_alert", title, message)
		if crisis_ui.has_method("_hide_alert_after_delay"):
			crisis_ui.call("_hide_alert_after_delay", 2.5)
		return
	# Fallback: ToastUI (bottom-right) if crisis UI missing.
	if main_scene.has_method("show_toast"):
		main_scene.call("show_toast", message, 1 if success else 2, 2.5)

func _find_structure_node(root: Node) -> Node3D:
	# Unstable soak scene preferred burnable root
	var node = root.get_node_or_null("Soak Site Camps2")
	if node != null:
		return node
	
	# Try LinkageLab_Export2 first (main structure)
	node = root.get_node_or_null("LinkageLab_Export2")
	if node != null:
		return node
	
	# Try LinkageLab_Export as fallback
	node = root.get_node_or_null("LinkageLab_Export")
	if node != null:
		return node
	
	# Try Mars Aerial Located scene
	node = root.get_node_or_null("Mars 2026 - Aerial Located")
	if node != null:
		return node
	
	# Recursively search for LinkageLab
	return _find_node_recursive(root, "LinkageLab")

func _find_node_recursive(node: Node, name: String) -> Node3D:
	# Check if node name contains the search string (case insensitive)
	if name.to_lower() in node.name.to_lower():
		if node is Node3D:
			return node as Node3D
	for child in node.get_children():
		var found := _find_node_recursive(child, name)
		if found != null:
			return found
	return null
