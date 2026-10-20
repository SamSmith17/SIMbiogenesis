@tool
extends Light3D

## Auto light that turns on at night and off during the day.
## Attach this script to any Light3D node (SpotLight3D, OmniLight3D, etc.)

@export var on_energy : float = 4.0
@export_range(0.0, 24.0) var turn_on_hour : float = 18.0  # 6 PM
@export_range(0.0, 24.0) var turn_off_hour : float = 6.0  # 6 AM
@export var fade_duration : float = 0.5  # Seconds to fade in/out
@export var wattage : float = 25.0
@export var display_name : String = ""

var target_energy : float = 0.0
var is_on : bool = false
var _solar_ui : Node = null
var _power_available : bool = true
var _main_node : Node = null
var _connect_attempts : int = 0
var _state_update_timer : float = 0.0
const _STATE_UPDATE_INTERVAL : float = 0.25
## -1 = forced off by automation, 0 = autonomous sunset logic, 1 = forced on by automation
var _user_override : int = 0

func _ready() -> void:
	if on_energy == 0.0:
		on_energy = light_energy if light_energy > 0.0 else 4.0
	if not Engine.is_editor_hint():
		_state_update_timer = randf() * _STATE_UPDATE_INTERVAL
		add_to_group("power_consumers")
		call_deferred("_connect_to_power_system")
	_update_light_state()


## Called by SceneNodeAction automations — switches to forced-on mode so the
## light stays on regardless of the time-of-day calculation.
func turn_on() -> void:
	_user_override = 1
	_update_light_state()


## Called by SceneNodeAction automations — forces the light off.  Internal
## time-of-day logic resumes at the next turn_on() call.
func turn_off() -> void:
	_user_override = -1
	_update_light_state()


func get_current_power() -> float:
	return wattage if is_on else 0.0

## Connect to the power system to monitor power availability
func _connect_to_power_system() -> void:
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("hook_availability_deferred"):
		apb.call("hook_availability_deferred", self, Callable(self, "_on_power_availability_changed"))
		return
	var tree : SceneTree = get_tree()
	if tree == null:
		return
	var solar_ui : Node = _find_solar_ui(tree.root)
	if solar_ui == null:
		if _connect_attempts < 40:
			_connect_attempts += 1
			get_tree().create_timer(0.25).timeout.connect(_connect_to_power_system, CONNECT_ONE_SHOT)
		return
	_connect_attempts = 0
	_solar_ui = solar_ui
	if solar_ui.has_signal("power_availability_changed"):
		if not solar_ui.power_availability_changed.is_connected(_on_power_availability_changed):
			solar_ui.power_availability_changed.connect(_on_power_availability_changed)
	if solar_ui.has_method("is_power_available"):
		_power_available = solar_ui.is_power_available()
	_update_light_state()

func _find_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_power_available"):
		if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
			pass
		else:
			return node
	for child in node.get_children():
		var result := _find_solar_ui(child)
		if result != null:
			return result
	return null

func _on_power_availability_changed(available: bool) -> void:
	_power_available = available
	_update_light_state()

func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		_state_update_timer += delta
		if _state_update_timer >= _STATE_UPDATE_INTERVAL:
			_state_update_timer -= _STATE_UPDATE_INTERVAL
			_update_light_state()
	
	# Smoothly interpolate to target energy
	if abs(light_energy - target_energy) > 0.01:
		light_energy = move_toward(light_energy, target_energy, on_energy * delta / fade_duration)

func _update_light_state() -> void:
	# Skip in editor
	if Engine.is_editor_hint():
		return
	
	# Find the main node to get current time
	var main_node = _get_main_node()
	if main_node == null:
		return
	
	var current_time : float = main_node.day_time if "day_time" in main_node else 12.0
	
	# Use calculated sunrise/sunset from main.gd if available (based on latitude/date)
	# Otherwise fall back to the configured turn_on/turn_off hours
	var sunrise : float = main_node.sunrise_hour if "sunrise_hour" in main_node else turn_off_hour
	var sunset : float = main_node.sunset_hour if "sunset_hour" in main_node else turn_on_hour
	
	# Determine if light should be on (between sunset and sunrise)
	var should_be_on : bool = false
	if sunset > sunrise:
		should_be_on = current_time >= sunset or current_time < sunrise
	else:
		should_be_on = current_time >= sunset and current_time < sunrise

	# Automation override takes priority over time-of-day logic
	if _user_override > 0:
		should_be_on = true
	elif _user_override < 0:
		should_be_on = false

	if should_be_on and not _power_available:
		should_be_on = false
	
	# Update target energy
	if should_be_on != is_on:
		is_on = should_be_on
		target_energy = on_energy if is_on else 0.0
		visible = true  # Always visible, energy controls brightness

func _get_main_node() -> Node:
	if _main_node != null and is_instance_valid(_main_node):
		return _main_node
	
	# Try to find the main node in the scene tree
	var root = get_tree().root if get_tree() else null
	if root == null:
		return null
	
	# Look for the main scene node that has day_time property
	for child in root.get_children():
		if "day_time" in child:
			_main_node = child
			return _main_node
	
	# Try getting the current scene
	var current_scene = get_tree().current_scene if get_tree() else null
	if current_scene and "day_time" in current_scene:
		_main_node = current_scene
		return _main_node
	
	return null
