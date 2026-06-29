extends Node3D
class_name PlayerAnimationController

## Animation controller for the player's 3D character model
## Handles animation state machine, blending, and synchronization with movement
## Designed for humanoid characters with standard animation sets

# ==================== ANIMATION NAMES ====================
# These should match the animation names in your imported GLTF/GLB model
# Mixamo animations often have names like "mixamo.com" or the action name
# We'll search for partial matches to be flexible

const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_JUMP := "jump"
const ANIM_FALL := "fall"
const ANIM_LAND := "land"

# Cached actual animation names (found during setup)
var anim_idle_name := ""
var anim_walk_name := ""
var anim_run_name := ""
var anim_jump_name := ""
var anim_fall_name := ""
var anim_land_name := ""

# ==================== NODE REFERENCES ====================

## The AnimationPlayer node from the imported character model
@export var animation_player: AnimationPlayer

## The Skeleton3D node from the imported character model
@export var skeleton: Skeleton3D

## Reference to the player (CharacterBody3D) - set automatically if not assigned
@export var player: CharacterBody3D

# ==================== ANIMATION SETTINGS ====================

## Speed threshold to switch from idle to walking
@export var walk_threshold: float = 0.5

## Speed threshold to switch from walking to running
@export var run_threshold: float = 6.0

## Animation crossfade duration in seconds
@export var blend_time: float = 0.2

## Scale animation speed based on movement speed
@export var scale_animation_to_speed: bool = true

## Base walking speed for animation scaling (meters per second)
@export var base_walk_speed: float = 2.5

## Base running speed for animation scaling (meters per second)
@export var base_run_speed: float = 6.0

# ==================== FIRST/THIRD PERSON SETTINGS ====================

## Hide character model in first person view
@export var hide_in_first_person: bool = true

## Show arms/hands in first person (requires separate arm model)
@export var show_first_person_arms: bool = false

## Reference to first-person arms model (optional)
@export var first_person_arms: Node3D

# ==================== STATE ====================

var current_animation: String = ANIM_IDLE
var is_in_air: bool = false
var was_on_floor: bool = true
var horizontal_speed: float = 0.0
var is_first_person: bool = true

# ==================== BONE INDICES ====================
# Cache bone indices for procedural animation (head look, etc.)

var head_bone_idx: int = -1
var spine_bone_idx: int = -1
var left_hand_bone_idx: int = -1
var right_hand_bone_idx: int = -1

func _ready() -> void:
	# Auto-find player if not assigned
	if player == null:
		player = get_parent() as CharacterBody3D
		if player == null:
			player = get_parent().get_parent() as CharacterBody3D
	
	# Auto-find animation player and skeleton in parent's children (the character model)
	var search_root := get_parent()
	if animation_player == null:
		animation_player = _find_animation_player(search_root)
	
	if skeleton == null:
		skeleton = _find_skeleton(search_root)
	
	# Map animation names (handles Mixamo naming conventions)
	_map_animation_names()
	
	# Cache bone indices for procedural animation
	_cache_bone_indices()
	
	# Set initial visibility based on camera mode
	_update_visibility()
	
	# Start with idle or first available animation
	_play_initial_animation()
	
	if animation_player != null:
		var anims = animation_player.get_animation_list()
		if anims.size() > 0:
			animation_player.play(anims[0])
	else:
		var parent = get_parent()
		for child in parent.get_children():
			if child.get_child_count() > 0:
				for grandchild in child.get_children():
					pass

## Map expected animation names to actual animation names in the model
## Handles Mixamo naming conventions and partial matches
func _map_animation_names() -> void:
	if animation_player == null:
		return
	
	var available := animation_player.get_animation_list()
	
	# Map each animation type to the best match found
	anim_idle_name = _find_best_animation_match(available, ["idle", "breathing", "stand"])
	anim_walk_name = _find_best_animation_match(available, ["walk", "walking"])
	anim_run_name = _find_best_animation_match(available, ["run", "running", "jog", "sprint"])
	anim_jump_name = _find_best_animation_match(available, ["jump", "jumping"])
	anim_fall_name = _find_best_animation_match(available, ["fall", "falling", "in air"])
	anim_land_name = _find_best_animation_match(available, ["land", "landing"])
	
	# If we only have one animation, use it for everything (testing with single anim)
	if available.size() == 1:
		var only_anim : String = available[0]
		if anim_walk_name.is_empty():
			anim_walk_name = only_anim
		if anim_idle_name.is_empty():
			anim_idle_name = only_anim
	
	# Fallbacks: if no idle, use walk; if no run, use walk
	if anim_idle_name.is_empty() and not anim_walk_name.is_empty():
		anim_idle_name = anim_walk_name
	if anim_run_name.is_empty() and not anim_walk_name.is_empty():
		anim_run_name = anim_walk_name

## Find the best matching animation name from available animations
func _find_best_animation_match(available: PackedStringArray, keywords: Array) -> String:
	for anim_name in available:
		var lower_name := anim_name.to_lower()
		for keyword in keywords:
			if keyword in lower_name:
				return anim_name
	return ""

## Play the initial animation on startup
func _play_initial_animation() -> void:
	if animation_player == null:
		return
	
	# Try idle first, then walk, then first available
	if not anim_idle_name.is_empty():
		animation_player.play(anim_idle_name)
		current_animation = ANIM_IDLE
	elif not anim_walk_name.is_empty():
		animation_player.play(anim_walk_name)
		current_animation = ANIM_WALK
	elif animation_player.get_animation_list().size() > 0:
		var first_anim : String = animation_player.get_animation_list()[0]
		animation_player.play(first_anim)
		current_animation = first_anim

func _physics_process(delta: float) -> void:
	if player == null:
		return
	
	# Calculate horizontal movement speed
	var velocity_2d := Vector2(player.velocity.x, player.velocity.z)
	horizontal_speed = velocity_2d.length()
	
	# Track floor state for jump/land animations
	var is_on_floor := player.is_on_floor()
	
	# Update animation state
	_update_animation_state(is_on_floor, delta)
	
	# Update animation playback speed based on movement
	_update_animation_speed()
	
	was_on_floor = is_on_floor

func _update_animation_state(is_on_floor: bool, _delta: float) -> void:
	if animation_player == null:
		return
	
	var new_animation := current_animation
	var new_anim_name := ""
	
	# Air state transitions
	if not is_on_floor:
		if player.velocity.y > 0.5:
			# Rising - jump animation
			new_animation = ANIM_JUMP
			new_anim_name = anim_jump_name if not anim_jump_name.is_empty() else anim_idle_name
		else:
			# Falling
			new_animation = ANIM_FALL
			new_anim_name = anim_fall_name if not anim_fall_name.is_empty() else anim_idle_name
		is_in_air = true
	else:
		# Just landed
		if is_in_air and was_on_floor == false:
			if not anim_land_name.is_empty():
				new_animation = ANIM_LAND
				new_anim_name = anim_land_name
				_play_animation_by_name(new_anim_name, new_animation)
				# Land animation plays once, then transitions to ground state
				await get_tree().create_timer(0.2).timeout
				is_in_air = false
				return
		
		is_in_air = false
		
		# Ground movement states based on speed
		if horizontal_speed < walk_threshold:
			new_animation = ANIM_IDLE
			new_anim_name = anim_idle_name
		elif horizontal_speed < run_threshold:
			new_animation = ANIM_WALK
			new_anim_name = anim_walk_name if not anim_walk_name.is_empty() else anim_idle_name
		else:
			new_animation = ANIM_RUN
			new_anim_name = anim_run_name if not anim_run_name.is_empty() else anim_walk_name
	
	# Apply animation change with crossfade
	if new_animation != current_animation and not new_anim_name.is_empty():
		_play_animation_by_name(new_anim_name, new_animation)

func _play_animation(anim_type: String) -> void:
	# Map animation type to actual animation name
	var anim_name := ""
	match anim_type:
		ANIM_IDLE: anim_name = anim_idle_name
		ANIM_WALK: anim_name = anim_walk_name
		ANIM_RUN: anim_name = anim_run_name
		ANIM_JUMP: anim_name = anim_jump_name
		ANIM_FALL: anim_name = anim_fall_name
		ANIM_LAND: anim_name = anim_land_name
		_: anim_name = anim_type  # Use as-is if not a known type
	
	_play_animation_by_name(anim_name, anim_type)

func _play_animation_by_name(anim_name: String, anim_type: String) -> void:
	if animation_player == null:
		return
	
	if anim_name.is_empty():
		return
	
	if not animation_player.has_animation(anim_name):
		push_warning("PlayerAnimationController: Animation '%s' not found" % anim_name)
		return
	
	# Use crossfade for smooth transitions
	animation_player.play(anim_name, blend_time)
	current_animation = anim_type

func _update_animation_speed() -> void:
	if animation_player == null or not scale_animation_to_speed:
		return
	
	# Only scale locomotion animations
	if current_animation == ANIM_WALK:
		var speed_scale := horizontal_speed / base_walk_speed
		animation_player.speed_scale = clampf(speed_scale, 0.5, 2.0)
	elif current_animation == ANIM_RUN:
		var speed_scale := horizontal_speed / base_run_speed
		animation_player.speed_scale = clampf(speed_scale, 0.5, 1.5)
	else:
		animation_player.speed_scale = 1.0

func _update_visibility() -> void:
	# Hide full body in first person, show in third person
	if hide_in_first_person and is_first_person:
		visible = false
	else:
		visible = true
	
	# Show/hide first person arms
	if first_person_arms != null:
		first_person_arms.visible = is_first_person and show_first_person_arms

## Switch between first and third person camera modes
func set_camera_mode(first_person: bool) -> void:
	is_first_person = first_person
	_update_visibility()

## Get the current animation state name
func get_current_animation() -> String:
	return current_animation

## Check if character is currently in a locomotion animation
func is_moving() -> bool:
	return current_animation in [ANIM_WALK, ANIM_RUN]

## Force play a specific animation (useful for interactions, emotes, etc.)
func play_action_animation(anim_name: String, return_to_locomotion: bool = true) -> void:
	if animation_player == null:
		return
	
	_play_animation(anim_name)
	
	if return_to_locomotion:
		# Wait for animation to finish, then return to normal state
		await animation_player.animation_finished
		_update_animation_state(player.is_on_floor(), 0.0)

# ==================== BONE HELPERS ====================

func _cache_bone_indices() -> void:
	if skeleton == null:
		return
	
	# Standard humanoid bone names (may vary by model)
	head_bone_idx = skeleton.find_bone("Head")
	if head_bone_idx == -1:
		head_bone_idx = skeleton.find_bone("head")
	
	spine_bone_idx = skeleton.find_bone("Spine")
	if spine_bone_idx == -1:
		spine_bone_idx = skeleton.find_bone("spine")
	
	left_hand_bone_idx = skeleton.find_bone("LeftHand")
	if left_hand_bone_idx == -1:
		left_hand_bone_idx = skeleton.find_bone("mixamorig:LeftHand")
	
	right_hand_bone_idx = skeleton.find_bone("RightHand")
	if right_hand_bone_idx == -1:
		right_hand_bone_idx = skeleton.find_bone("mixamorig:RightHand")

## Apply procedural head look rotation (for looking at targets)
func look_at_target(target_position: Vector3, weight: float = 1.0) -> void:
	if skeleton == null or head_bone_idx == -1:
		return
	
	# Get current head transform
	var head_transform := skeleton.get_bone_global_pose(head_bone_idx)
	var head_pos := skeleton.to_global(head_transform.origin)
	
	# Calculate look direction
	var look_dir := (target_position - head_pos).normalized()
	var forward := -head_transform.basis.z
	
	# Calculate rotation needed
	var angle := forward.angle_to(look_dir)
	if angle > 0.01:
		var axis := forward.cross(look_dir).normalized()
		if axis.length() > 0.01:
			var rotation := Quaternion(axis, angle * weight)
			var new_basis := Basis(rotation) * head_transform.basis
			head_transform.basis = new_basis
			skeleton.set_bone_global_pose_override(head_bone_idx, head_transform, weight, true)

## Get position of a specific bone in world space
func get_bone_world_position(bone_name: String) -> Vector3:
	if skeleton == null:
		return global_position
	
	var bone_idx := skeleton.find_bone(bone_name)
	if bone_idx == -1:
		return global_position
	
	var bone_transform := skeleton.get_bone_global_pose(bone_idx)
	return skeleton.to_global(bone_transform.origin)

## Attach a node to a specific bone (e.g., weapon to hand)
func attach_to_bone(node: Node3D, bone_name: String) -> void:
	if skeleton == null:
		return
	
	var attachment := BoneAttachment3D.new()
	attachment.bone_name = bone_name
	skeleton.add_child(attachment)
	
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	attachment.add_child(node)
	node.transform = Transform3D.IDENTITY

# ==================== AUTO-FIND HELPERS ====================

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	
	return null

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	
	return null

# ==================== DEBUG ====================

func _get_debug_info() -> Dictionary:
	return {
		"current_animation": current_animation,
		"horizontal_speed": horizontal_speed,
		"is_in_air": is_in_air,
		"animation_player_found": animation_player != null,
		"skeleton_found": skeleton != null,
		"head_bone_idx": head_bone_idx,
	}

