class_name PowerDevice
extends Node

## Universal power consumer component.
## Add as a child to any Node3D, Light3D, or other object to track its power consumption.
## Supports variable power draw (0-100%) and multiple states (off/standby/on/eco).

# ==================== SIGNALS ====================

## Emitted when device state changes (on/off/standby/eco)
signal state_changed(device_id: String, old_state: int, new_state: int)

## Emitted when power consumption changes
signal power_changed(device_id: String, watts: float)

## Emitted when device is enabled/disabled
signal enabled_changed(device_id: String, is_enabled: bool)

# ==================== CONFIGURATION ====================

## Unique identifier for this device (used for automations and HA export)
## If empty, will be auto-generated from node path
@export var device_id : String = ""

## Human-readable name for this device
@export var device_name : String = "Unnamed Device"

## Device category (affects HA domain mapping)
@export var device_type : DeviceTypes.DeviceType = DeviceTypes.DeviceType.APPLIANCE

## Maximum power draw in Watts when fully on
@export_range(0.1, 50000.0, 0.1) var rated_power_watts : float = 100.0

## Power draw in Watts when in standby mode
@export_range(0.0, 100.0, 0.1) var standby_power_watts : float = 0.0

## Power draw in Watts when in eco mode (as fraction of rated)
@export_range(0.0, 1.0, 0.01) var eco_power_fraction : float = 0.5

# ==================== STATE ====================

## Master enable/disable - when false, device draws no power regardless of state
@export var is_enabled : bool = true :
	set(value):
		var old_enabled := is_enabled
		is_enabled = value
		if old_enabled != is_enabled:
			enabled_changed.emit(_get_device_id(), is_enabled)
			_emit_power_changed()

## Current power level (0.0 to 1.0) - for variable power devices like dimmers
@export_range(0.0, 1.0, 0.01) var power_level : float = 1.0 :
	set(value):
		var old_level := power_level
		power_level = clampf(value, 0.0, 1.0)
		if old_level != power_level:
			_emit_power_changed()

## Current device state
var current_state : DeviceTypes.DeviceState = DeviceTypes.DeviceState.OFF :
	set(value):
		var old_state := current_state
		current_state = value
		if old_state != current_state:
			state_changed.emit(_get_device_id(), old_state, current_state)
			_emit_power_changed()

# ==================== INTERNAL ====================

var _registered : bool = false
## User intent — survives AC blackout so loads restore when power returns.
var _requested_on : bool = false
var _ac_power_available : bool = true
var _solar_ui : Node = null
var _connect_attempts : int = 0


func _ready() -> void:
	# Auto-generate device_id if not set
	if device_id.is_empty():
		device_id = _generate_device_id()
	
	# Register with DeviceRegistry if available
	_register_device()
	call_deferred("_connect_ac_power_system")

func _exit_tree() -> void:
	_unregister_device()

func _generate_device_id() -> String:
	# Generate ID from node path, converting to snake_case
	var path_str := get_path().get_concatenated_names().to_snake_case()
	# Remove invalid characters for HA entity_id
	var valid_id := ""
	for c in path_str:
		if c.is_valid_identifier() or c == "_":
			valid_id += c
	return valid_id if not valid_id.is_empty() else "device_%d" % get_instance_id()

func _get_device_id() -> String:
	return device_id if not device_id.is_empty() else _generate_device_id()

## Register this device with the DeviceRegistry
## Can be called externally to force registration
func _register_device() -> void:
	if _registered:
		return
	
	# Add to power_consumers group for backward compatibility
	if not is_in_group("power_consumers"):
		add_to_group("power_consumers")
	
	# Try finding registry as an autoload (most common case)
	var tree := get_tree()
	if tree != null:
		var root := tree.root
		if root != null:
			var registry := root.get_node_or_null("DeviceRegistry")
			if registry != null and is_instance_valid(registry) and registry.has_method("register_device"):
				registry.register_device(self)
				_registered = true
				return
	
	# Fallback: Check if DeviceRegistry is an engine singleton
	if Engine.has_singleton("DeviceRegistry"):
		var registry = Engine.get_singleton("DeviceRegistry")
		if registry != null and registry.has_method("register_device"):
			registry.register_device(self)
			_registered = true

func _unregister_device() -> void:
	if not _registered:
		return
	
	_registered = false  # Set early to prevent re-entry
	
	if Engine.has_singleton("DeviceRegistry"):
		var registry = Engine.get_singleton("DeviceRegistry")
		if registry != null and registry.has_method("unregister_device"):
			registry.unregister_device(_get_device_id())
	else:
		var tree := get_tree()
		if tree == null:
			return
		var root := tree.root
		if root == null:
			return
		var registry := root.get_node_or_null("DeviceRegistry")
		if registry != null and is_instance_valid(registry) and registry.has_method("unregister_device"):
			registry.unregister_device(_get_device_id())

func _emit_power_changed() -> void:
	power_changed.emit(_get_device_id(), get_current_power())

# ==================== PUBLIC API ====================

## Returns the current power consumption in Watts
func get_current_power() -> float:
	if not is_enabled or not _ac_power_available:
		return 0.0
	
	match current_state:
		DeviceTypes.DeviceState.OFF:
			return 0.0
		DeviceTypes.DeviceState.STANDBY:
			return standby_power_watts
		DeviceTypes.DeviceState.ON:
			return rated_power_watts * power_level
		DeviceTypes.DeviceState.ECO:
			return rated_power_watts * eco_power_fraction * power_level
		_:
			return 0.0

## Returns current power consumption in Watts (alias for compatibility)
func get_power_consumption() -> float:
	return get_current_power()

## Returns whether the device is currently consuming power
func is_consuming_power() -> bool:
	return get_current_power() > 0.0

## Turn the device on (full power at current power_level)
func turn_on() -> void:
	_requested_on = true
	_apply_effective_state()


## Turn the device off (no power draw)
func turn_off() -> void:
	_requested_on = false
	_apply_effective_state()


## Toggle between on and off
func toggle() -> void:
	if _requested_on:
		turn_off()
	else:
		turn_on()


func _apply_effective_state() -> void:
	var want_on := _requested_on and _ac_power_available and is_enabled
	var target := DeviceTypes.DeviceState.ON if want_on else DeviceTypes.DeviceState.OFF
	if current_state != target:
		current_state = target
	else:
		_emit_power_changed()


func _connect_ac_power_system() -> void:
	_requested_on = current_state != DeviceTypes.DeviceState.OFF
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("hook_availability_deferred"):
		apb.call("hook_availability_deferred", self, Callable(self, "_on_ac_power_availability_changed"))
		return
	var tree := get_tree()
	if tree == null:
		return
	var solar_ui := _find_primary_solar_ui(tree.root)
	if solar_ui == null:
		if _connect_attempts < 40:
			_connect_attempts += 1
			get_tree().create_timer(0.25).timeout.connect(_connect_ac_power_system, CONNECT_ONE_SHOT)
		return
	_connect_attempts = 0
	_solar_ui = solar_ui
	if solar_ui.has_signal("power_availability_changed"):
		if not solar_ui.power_availability_changed.is_connected(_on_ac_power_availability_changed):
			solar_ui.power_availability_changed.connect(_on_ac_power_availability_changed)
	if solar_ui.has_method("is_power_available"):
		_ac_power_available = bool(solar_ui.call("is_power_available"))
	_apply_effective_state()


func _find_primary_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_power_available"):
		if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
			pass
		else:
			return node
	for child in node.get_children():
		var found := _find_primary_solar_ui(child)
		if found != null:
			return found
	return null


func _on_ac_power_availability_changed(available: bool) -> void:
	_ac_power_available = available
	_apply_effective_state()

## Set to standby mode
func set_standby() -> void:
	current_state = DeviceTypes.DeviceState.STANDBY

## Set to eco mode
func set_eco() -> void:
	current_state = DeviceTypes.DeviceState.ECO

## Set power level (0.0 to 1.0) for variable power devices
func set_power_level(level: float) -> void:
	power_level = level

## Get the current state as a string (for HA compatibility)
func get_state_string() -> String:
	return DeviceTypes.get_state_name(current_state)

## Get Home Assistant entity_id
func get_ha_entity_id() -> String:
	var domain := DeviceTypes.get_ha_domain(device_type)
	return "%s.%s" % [domain, _get_device_id()]

## Get Home Assistant entity configuration as dictionary
func get_ha_entity_config() -> Dictionary:
	return {
		"entity_id": get_ha_entity_id(),
		"name": device_name,
		"device_class": DeviceTypes.get_type_name(device_type).to_lower(),
		"state": get_state_string(),
		"attributes": {
			"power": get_current_power(),
			"power_level": power_level * 100.0,
			"rated_power": rated_power_watts,
			"device_type": DeviceTypes.get_type_name(device_type)
		}
	}

