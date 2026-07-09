extends Node

## Central automation engine that evaluates all automations each frame.
## Add as an autoload singleton named "AutomationEngine".

# ==================== SIGNALS ====================

## Emitted when an automation is triggered
signal automation_triggered(automation_id: String)

## Emitted when an automation completes
signal automation_completed(automation_id: String, success: bool)

## Emitted when automations are exported
signal automations_exported(file_path: String)

# ==================== CONFIGURATION ====================

## How often to evaluate automations (in seconds, 0 = every frame)
@export var evaluation_interval : float = 0.1

## Whether to log automation events
@export var debug_logging : bool = false

# ==================== STATE ====================

## All registered automations
var _automations : Dictionary = {}  # automation_id -> Automation

## Timer for evaluation interval
var _eval_timer : float = 0.0

## Cached context for evaluations
var _context : Dictionary = {}

## Reference to main scene (for time data)
var _main_node : Node = null

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	# Safety check - don't process if tree is not ready
	var tree := get_tree()
	if tree == null:
		return
	
	# Update evaluation timer
	_eval_timer += delta
	if _eval_timer < evaluation_interval:
		return
	_eval_timer = 0.0
	
	# Update context (with error handling)
	_update_context()
	
	# Evaluate all automations (iterate over copy of keys to allow modification)
	var automation_ids := _automations.keys().duplicate()
	for automation_id in automation_ids:
		if not _automations.has(automation_id):
			continue
		var automation : Automation = _automations[automation_id]
		if automation != null and automation.enabled:
			var triggered := automation.evaluate(_context)
			if triggered:
				# Signal was declared but never emitted — UI consumers (graph
				# node flash, badges) rely on it now.
				automation_triggered.emit(automation_id)

func _update_context() -> void:
	var tree := get_tree()
	if tree == null:
		return
	
	# Find main node for time data (check if still valid)
	if _main_node != null and not is_instance_valid(_main_node):
		_main_node = null
	if _main_node == null:
		_main_node = _find_main_node()
	
	_context["scene_tree"] = tree
	_context["game_time"] = Time.get_ticks_msec() / 1000.0
	
	# Get time data from main scene
	if _main_node != null and is_instance_valid(_main_node):
		if "day_time" in _main_node:
			_context["day_time"] = float(_main_node.day_time)
		if "day" in _main_node:
			_context["day"] = int(_main_node.day)
		if "time_scale" in _main_node:
			_context["time_scale"] = float(_main_node.time_scale)
		
		# Get calculated sunrise/sunset from main.gd (based on latitude, date, axial tilt)
		if "sunrise_hour" in _main_node:
			_context["sunrise_hour"] = float(_main_node.sunrise_hour)
		else:
			_context["sunrise_hour"] = 6.0  # Fallback
		
		if "sunset_hour" in _main_node:
			_context["sunset_hour"] = float(_main_node.sunset_hour)
		else:
			_context["sunset_hour"] = 18.0  # Fallback
	
	# Get device states from DeviceRegistry
	var device_states : Dictionary = {}
	var numeric_values : Dictionary = {}
	
	var root : Window = tree.root
	if root == null:
		_context["device_states"] = device_states
		_context["numeric_values"] = numeric_values
		return
	
	var registry : Node = root.get_node_or_null("DeviceRegistry")
	if registry != null and is_instance_valid(registry) and registry.has_method("get_all_devices"):
		var devices : Array = registry.get_all_devices()
		for device in devices:
			if device != null and is_instance_valid(device):
				var device_id : String = device.device_id if "device_id" in device else ""
				if not device_id.is_empty():
					if device.has_method("get_state_string"):
						device_states[device_id] = device.get_state_string()
					if device.has_method("get_current_power"):
						numeric_values["%s.power" % device_id] = device.get_current_power()
					if "power_level" in device:
						numeric_values["%s.power_level" % device_id] = device.power_level * 100.0
	
	_context["device_states"] = device_states
	_context["numeric_values"] = numeric_values
	
	# Get battery/solar data from solar_ui if available
	var solar_ui : Node = _find_node_in_tree("SolarUI")
	if solar_ui != null and is_instance_valid(solar_ui):
		if "battery_kwh_stored" in solar_ui:
			var battery_kwh : float = solar_ui.battery_kwh_stored
			# Read actual capacity from solar_ui instead of hardcoding 16 kWh
			var battery_capacity : float = 16.0
			if "BATTERY_CAPACITY_KWH" in solar_ui:
				battery_capacity = float(solar_ui.BATTERY_CAPACITY_KWH)
			_context["battery_percent"] = (battery_kwh / battery_capacity) * 100.0
			numeric_values["sensor.battery_level"] = _context["battery_percent"]
		if "current_solar_kw" in solar_ui:
			_context["solar_power_kw"] = solar_ui.current_solar_kw
			numeric_values["sensor.solar_power"] = _context["solar_power_kw"]
		if "current_load_kw" in solar_ui:
			_context["load_power_kw"] = solar_ui.current_load_kw
			numeric_values["sensor.load_power"] = _context["load_power_kw"]
			# Total AC output in watts for overload-style numeric triggers
			numeric_values["sensor.total_ac_load"] = solar_ui.current_load_kw * 1000.0

func _find_main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	
	var root : Window = tree.root
	for child in root.get_children():
		if "day_time" in child:
			return child
	
	var current_scene : Node = tree.current_scene
	if current_scene and "day_time" in current_scene:
		return current_scene
	
	return null

## Cached node references to avoid expensive lookups (must re-resolve after scene changes).
var _solar_ui_cache : Node = null

func _find_node_in_tree(node_name: String) -> Node:
	if node_name == "SolarUI":
		if is_instance_valid(_solar_ui_cache):
			return _solar_ui_cache
		# SolarUI lives at root→Main→UILayer→SolarUI (3 levels deep), so use
		# a full recursive search once and cache the result.
		_solar_ui_cache = _find_node_recursive(node_name)
		return _solar_ui_cache
	return _find_node_shallow(node_name)

func _find_node_recursive(node_name: String) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.find_child(node_name, true, false)

func _find_node_shallow(node_name: String) -> Node:
	# Only search a few levels deep to avoid performance issues
	var tree := get_tree()
	if tree == null:
		return null

	var root : Window = tree.root
	if root == null:
		return null

	# Check direct children of root
	for child in root.get_children():
		if child.name == node_name:
			return child
		# Check one level deeper (UILayer, etc.)
		for grandchild in child.get_children():
			if grandchild.name == node_name:
				return grandchild

	return null

# ==================== AUTOMATION MANAGEMENT ====================

## Register an automation with the engine
func register_automation(automation: Automation) -> void:
	if automation == null:
		push_warning("AutomationEngine: Attempted to register null automation")
		return
	
	var automation_id := automation.automation_id
	if automation_id.is_empty():
		push_warning("AutomationEngine: Automation has empty ID")
		return
	
	_automations[automation_id] = automation
	
	# Connect signals
	if not automation.triggered.is_connected(_on_automation_triggered):
		automation.triggered.connect(_on_automation_triggered)
	if not automation.actions_completed.is_connected(_on_automation_completed):
		automation.actions_completed.connect(_on_automation_completed)
	
	if debug_logging:
		pass

## Unregister an automation
func unregister_automation(automation_id: String) -> void:
	if not _automations.has(automation_id):
		return
	
	var automation : Automation = _automations[automation_id]
	if automation != null:
		if automation.triggered.is_connected(_on_automation_triggered):
			automation.triggered.disconnect(_on_automation_triggered)
		if automation.actions_completed.is_connected(_on_automation_completed):
			automation.actions_completed.disconnect(_on_automation_completed)
	
	_automations.erase(automation_id)
	
	if debug_logging:
		pass

## Get an automation by ID
func get_automation(automation_id: String) -> Automation:
	return _automations.get(automation_id, null)

## Get all registered automations
func get_all_automations() -> Array[Automation]:
	var result : Array[Automation] = []
	for automation in _automations.values():
		if automation != null:
			result.append(automation)
	return result

## Get automation IDs
func get_automation_ids() -> Array[String]:
	var result : Array[String] = []
	for key in _automations.keys():
		result.append(key)
	return result

## Enable/disable an automation
func set_automation_enabled(automation_id: String, enabled: bool) -> void:
	var automation := get_automation(automation_id)
	if automation != null:
		automation.enabled = enabled

## Manually trigger an automation (bypasses triggers)
func trigger_automation(automation_id: String) -> bool:
	var automation := get_automation(automation_id)
	if automation == null:
		return false
	
	if not automation.check_conditions(_context):
		return false
	
	return automation.execute_actions(_context)

# ==================== FACTORY METHODS ====================

## Create a simple time-based automation
func create_time_automation(
	automation_id: String,
	alias: String,
	at_hour: float,
	device_id: String,
	turn_on: bool = true
) -> Automation:
	var automation := Automation.new()
	automation.automation_id = automation_id
	automation.alias = alias
	
	var trigger := TimeTrigger.new()
	trigger.at_hour = at_hour
	automation.triggers.append(trigger)
	
	var action := DeviceAction.new()
	action.device_id = device_id
	action.command = DeviceAction.DeviceCommand.TURN_ON if turn_on else DeviceAction.DeviceCommand.TURN_OFF
	automation.actions.append(action)
	
	return automation

## Create a sun-based automation
func create_sun_automation(
	automation_id: String,
	alias: String,
	event: SunTrigger.SunEvent,
	offset_hours: float,
	device_id: String,
	turn_on: bool = true
) -> Automation:
	var automation := Automation.new()
	automation.automation_id = automation_id
	automation.alias = alias
	
	var trigger := SunTrigger.new()
	trigger.event = event
	trigger.offset_hours = offset_hours
	automation.triggers.append(trigger)
	
	var action := DeviceAction.new()
	action.device_id = device_id
	action.command = DeviceAction.DeviceCommand.TURN_ON if turn_on else DeviceAction.DeviceCommand.TURN_OFF
	automation.actions.append(action)
	
	return automation

# ==================== HOME ASSISTANT EXPORT ====================

## Export all automations to Home Assistant YAML format
func export_all_to_ha_yaml() -> String:
	var yaml := "# Home Assistant Automations\n"
	yaml += "# Exported from Godot Micro-Grid Simulation\n"
	yaml += "# Generated: %s\n\n" % Time.get_datetime_string_from_system()
	
	for automation_id in _automations.keys():
		var automation : Automation = _automations[automation_id]
		if automation != null:
			yaml += "- %s\n" % automation.to_ha_yaml().replace("\n", "\n  ")
			yaml += "\n"
	
	return yaml

## Export all automations to a file
func export_to_file(file_path: String) -> bool:
	var yaml := export_all_to_ha_yaml()
	
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("AutomationEngine: Could not open file for writing: %s" % file_path)
		return false
	
	file.store_string(yaml)
	file.close()
	
	automations_exported.emit(file_path)
	
	if debug_logging:
		pass
	
	return true

## Export a single automation to Home Assistant YAML
func export_automation_to_ha_yaml(automation_id: String) -> String:
	var automation := get_automation(automation_id)
	if automation == null:
		return ""
	return automation.to_ha_yaml()

# ==================== SIGNAL HANDLERS ====================

func _on_automation_triggered(automation_id: String) -> void:
	automation_triggered.emit(automation_id)

func _on_automation_completed(automation_id: String, success: bool) -> void:
	automation_completed.emit(automation_id, success)

