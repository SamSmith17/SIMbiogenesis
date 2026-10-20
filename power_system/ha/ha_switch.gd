extends Node3D

## Home Assistant Switch Controller
## Links game objects to a Home Assistant switch/light/scene entity for bidirectional control
## Player can approach and press O to toggle
## Automatically detects domain from entity_id (switch.*, light.*, scene.*)

## The Home Assistant entity ID to link to (e.g., "switch.living_room", "light.govee", "scene.movie_time")
@export var ha_entity_id: String = ""

## Nodes to control when the switch state changes (supports Node3D with visible, or lights)
@export var controlled_nodes: Array[NodePath] = []

## Whether to sync game state back to Home Assistant when controlled locally
@export var sync_to_ha: bool = true

## Force lights on regardless of time-of-day logic
@export var override_auto_behavior: bool = true

## Interaction radius for player detection
@export var interaction_radius: float = 2.5

## Display name shown in interaction prompt
@export var display_name: String = "Light Switch"

## Size of the visible switch box
@export var switch_size: Vector3 = Vector3(0.3, 0.5, 0.15)

## Color when switch is ON
@export var on_color: Color = Color(0.2, 0.8, 0.2)

## Color when switch is OFF
@export var off_color: Color = Color(0.3, 0.3, 0.3)

var ha_client: Node
var is_on: bool = false
var _entity_domain: String = "switch"  # Auto-detected from entity_id (switch, light, scene)
var _controlled_node_refs: Array[Node] = []
var _initial_state_received: bool = false
var _state_poll_timer: float = 0.0
const STATE_POLL_INTERVAL: float = 1.0  # Check every second until we get initial state

# Debounce to prevent race conditions when toggling
var _pending_state: bool = false  # The state we're trying to set
var _command_in_flight: bool = false  # Whether we're waiting for HA to confirm our command
var _command_sent_time: float = 0.0  # When we sent the command
const COMMAND_TIMEOUT: float = 2.0  # Ignore stale updates for this long after sending command

# Interaction system
var interaction_area: Area3D
var player_in_range: Node3D = null
var interaction_ui: Node = null

# Visual components
var mesh_instance: MeshInstance3D
var switch_material: StandardMaterial3D

signal state_changed(new_state: bool)

func _ready() -> void:
	# Auto-detect domain from entity_id
	_detect_entity_domain()
	
	# Create visual mesh
	_setup_visual()
	
	# Setup interaction area
	_setup_interaction_area()
	
	# Find HA client
	call_deferred("_connect_to_ha")
	
	# Resolve node paths to actual node references
	call_deferred("_resolve_node_paths")
	
	# Find interaction UI
	call_deferred("_find_interaction_ui")

func _detect_entity_domain() -> void:
	"""Auto-detect the entity domain from the entity_id (e.g., 'light.h7039' -> 'light')"""
	if ha_entity_id == "":
		return
	
	var dot_index = ha_entity_id.find(".")
	if dot_index > 0:
		_entity_domain = ha_entity_id.substr(0, dot_index)
	else:
		_entity_domain = "switch"  # Default fallback

func _setup_visual() -> void:
	# Create mesh for the switch
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "SwitchMesh"
	
	var box_mesh = BoxMesh.new()
	box_mesh.size = switch_size
	mesh_instance.mesh = box_mesh
	
	# Create material
	switch_material = StandardMaterial3D.new()
	switch_material.albedo_color = off_color
	switch_material.emission_enabled = true
	switch_material.emission = off_color
	switch_material.emission_energy_multiplier = 0.5
	mesh_instance.material_override = switch_material
	
	add_child(mesh_instance)
	
	# Position mesh at center (can be adjusted)
	mesh_instance.position = Vector3(0, switch_size.y / 2, 0)

func _setup_interaction_area() -> void:
	# Create Area3D for player detection
	interaction_area = Area3D.new()
	interaction_area.name = "InteractionArea"
	interaction_area.collision_layer = 0
	interaction_area.collision_mask = 1  # Detect player on layer 1
	add_child(interaction_area)
	
	# Create collision shape
	var collision_shape = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = interaction_radius
	collision_shape.shape = sphere_shape
	interaction_area.add_child(collision_shape)
	
	# Connect signals
	interaction_area.body_entered.connect(_on_body_entered)
	interaction_area.body_exited.connect(_on_body_exited)

func _find_interaction_ui() -> void:
	var tree = get_tree()
	if tree == null:
		return
	
	# Find the InteractionPromptUI
	var root = tree.root
	for child in root.get_children():
		var ui_layer = child.get_node_or_null("UILayer")
		if ui_layer:
			interaction_ui = ui_layer.get_node_or_null("InteractionPromptUI")
			if interaction_ui:
				break

func _connect_to_ha() -> void:
	var tree = get_tree()
	if tree == null:
		return
	
	# Find HAClient in the scene
	var root = tree.root
	for child in root.get_children():
		var client = child.get_node_or_null("HAClient")
		if client:
			ha_client = client
			# Connect to sensor updates
			if ha_client.has_signal("sensor_updated"):
				if not ha_client.sensor_updated.is_connected(_on_sensor_updated):
					ha_client.sensor_updated.connect(_on_sensor_updated)
			# Connect to authentication to request initial state
			if ha_client.has_signal("authentication_status_changed"):
				if not ha_client.authentication_status_changed.is_connected(_on_ha_authenticated):
					ha_client.authentication_status_changed.connect(_on_ha_authenticated)
			# Connect to initial_states_received signal
			if ha_client.has_signal("initial_states_received"):
				if not ha_client.initial_states_received.is_connected(_on_initial_states_received):
					ha_client.initial_states_received.connect(_on_initial_states_received)
			# If already authenticated, request state now
			if ha_client.is_authenticated:
				_request_initial_state()
			break
	
	if ha_client == null:
		pass

func _on_initial_states_received() -> void:
	"""Called when HA client receives initial states - request our state if we don't have it"""
	if not _initial_state_received:
		_request_initial_state()

func _on_ha_authenticated(authenticated: bool) -> void:
	if authenticated and not _initial_state_received:
		# Request initial state when we authenticate
		_request_initial_state()

func _request_initial_state() -> void:
	"""Request the current state of our entity from Home Assistant"""
	if ha_client == null or ha_entity_id == "":
		return
	
	if _initial_state_received:
		return  # Already have state, don't request again
	
	if ha_client.has_method("get_single_entity_state"):
		ha_client.get_single_entity_state(ha_entity_id)

func _process(delta: float) -> void:
	# Poll for initial state until we get it
	if not _initial_state_received and ha_entity_id != "":
		_state_poll_timer += delta
		if _state_poll_timer >= STATE_POLL_INTERVAL:
			_state_poll_timer = 0.0
			if ha_client and ha_client.is_authenticated:
				_request_initial_state()
	
	# Clear command in flight after timeout
	if _command_in_flight:
		_command_sent_time += delta
		if _command_sent_time >= COMMAND_TIMEOUT:
			_command_in_flight = false

func _resolve_node_paths() -> void:
	_controlled_node_refs.clear()
	for path in controlled_nodes:
		var node = get_node_or_null(path)
		if node:
			_controlled_node_refs.append(node)
		else:
			pass

func _on_body_entered(body: Node3D) -> void:
	# Check if it's the player
	if body.is_in_group("player") or body.name == "Player" or body is CharacterBody3D:
		player_in_range = body
		_show_interaction_prompt()

func _on_body_exited(body: Node3D) -> void:
	if body == player_in_range:
		player_in_range = null
		_hide_interaction_prompt()

func _show_interaction_prompt() -> void:
	if interaction_ui and interaction_ui.has_method("show_action_prompt"):
		if _entity_domain == "scene":
			# Scenes are one-shot activations
			interaction_ui.show_action_prompt("interact", "Activate %s" % display_name)
		else:
			var state_text = "ON" if is_on else "OFF"
			interaction_ui.show_action_prompt("interact", "Toggle %s (currently %s)" % [display_name, state_text])

func _hide_interaction_prompt() -> void:
	if interaction_ui and interaction_ui.has_method("hide_prompt"):
		interaction_ui.hide_prompt()

func _input(event: InputEvent) -> void:
	# Only handle input when player is in range
	if player_in_range == null:
		return
	
	# Check for interact action (O key)
	if event.is_action_pressed("interact"):
		toggle()
		# Update the prompt to show new state
		_show_interaction_prompt()
		get_viewport().set_input_as_handled()

func _on_sensor_updated(entity_id: String, state: Dictionary) -> void:
	# Check if this update is for our entity
	if entity_id != ha_entity_id:
		return
	
	var state_value = state.get("state", "")
	var new_state = (state_value == "on")
	
	# If we have a command in flight, only accept updates that match our pending state
	# This prevents stale state_changed events from flipping us back
	if _command_in_flight:
		if new_state == _pending_state:
			# HA confirmed our command - clear the in-flight flag
			_command_in_flight = false
		else:
			# Stale update that doesn't match what we're trying to set - ignore it
			return
	
	var was_initial = not _initial_state_received
	_initial_state_received = true  # Mark that we've received state
	
	var state_changed_flag = (new_state != is_on)
	is_on = new_state
	
	# Always apply state on updates (ensures initial state sync)
	_apply_state_to_controlled_nodes()
	_update_visual()
	
	if state_changed_flag:
		state_changed.emit(is_on)
	
	# Update prompt if player is nearby
	if player_in_range:
		_show_interaction_prompt()

func _apply_state_to_controlled_nodes() -> void:
	"""Apply the current state to all controlled nodes"""
	for node in _controlled_node_refs:
		_set_node_state(node, is_on)

func _update_visual() -> void:
	"""Update the switch visual to reflect current state"""
	if switch_material:
		var color = on_color if is_on else off_color
		switch_material.albedo_color = color
		switch_material.emission = color
		switch_material.emission_energy_multiplier = 1.5 if is_on else 0.3

func _set_node_state(node: Node, state: bool) -> void:
	"""Set the state of a single node"""
	if node == null:
		return
	
	# Handle StringLights specifically - they have the set_lights_state method
	if node.has_method("set_lights_state"):
		# Use the public method with external flag to prevent auto-updates overriding
		node.call("set_lights_state", state, true)
	
	# Fallback for older StringLights without the new method
	elif node.has_method("_set_lights_state"):
		node.call("_set_lights_state", state)
		if "is_on" in node:
			node.is_on = state
		if "external_control" in node:
			node.external_control = true
	
	# Handle OmniLight3D, SpotLight3D, DirectionalLight3D
	elif node is Light3D:
		node.visible = state
	
	# Handle generic Node3D visibility
	elif node is Node3D:
		node.visible = state
	
	# Handle CanvasItem (2D nodes)
	elif node is CanvasItem:
		node.visible = state

func set_state(new_state: bool) -> void:
	"""Set the switch state - also syncs to Home Assistant if enabled"""
	# Scenes are one-shot (turn_on only), so handle them specially
	if _entity_domain == "scene":
		_activate_scene()
		return
	
	if new_state == is_on and not _command_in_flight:
		return
	
	is_on = new_state
	_apply_state_to_controlled_nodes()
	_update_visual()
	state_changed.emit(is_on)
	
	# Sync to Home Assistant
	if sync_to_ha and ha_client and ha_entity_id != "":
		# Mark command in flight to prevent stale updates from reverting state
		_command_in_flight = true
		_pending_state = new_state
		_command_sent_time = 0.0
		
		if is_on:
			ha_client.call_service(_entity_domain, "turn_on", ha_entity_id)
		else:
			ha_client.call_service(_entity_domain, "turn_off", ha_entity_id)

func _activate_scene() -> void:
	"""Activate a Home Assistant scene (scenes are one-shot, no toggle)"""
	if ha_client and ha_entity_id != "":
		ha_client.call_service("scene", "turn_on", ha_entity_id)
		# Briefly flash the switch visual to indicate activation
		is_on = true
		_update_visual()
		# Reset after a short delay (visual feedback only)
		await get_tree().create_timer(0.5).timeout
		is_on = false
		_update_visual()

func toggle() -> void:
	"""Toggle the switch state"""
	set_state(not is_on)

func turn_on() -> void:
	"""Turn the switch on"""
	set_state(true)

func turn_off() -> void:
	"""Turn the switch off"""
	set_state(false)

func get_state() -> bool:
	"""Get the current switch state"""
	return is_on

func get_interaction_prompt() -> String:
	"""Return the interaction prompt text"""
	if _entity_domain == "scene":
		return "Activate %s" % display_name
	var state_text = "ON" if is_on else "OFF"
	return "Toggle %s (currently %s)" % [display_name, state_text]
