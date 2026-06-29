extends Node

## Global registry for all power-consuming devices.
## Add as an autoload singleton named "DeviceRegistry".

# ==================== SIGNALS ====================

## Emitted when a new device is registered
signal device_registered(device_id: String, device: PowerDevice)

## Emitted when a device is unregistered
signal device_unregistered(device_id: String)

## Emitted when total power consumption changes significantly
signal total_power_changed(total_watts: float)

# ==================== INTERNAL STATE ====================

## All registered devices indexed by device_id
var _devices : Dictionary = {}  # String -> PowerDevice

## Cached total power (updated on changes)
var _cached_total_power : float = 0.0

## Track last emitted power to avoid spam
var _last_emitted_power : float = 0.0
const POWER_CHANGE_THRESHOLD : float = 1.0  # Watts

const _SAFETY_CHECK_INTERVAL : float = 8.0
var _safety_timer : float = 0.0
var _time_since_signal_update : float = 0.0

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	_safety_timer += delta
	_time_since_signal_update += delta
	if _safety_timer < _SAFETY_CHECK_INTERVAL:
		return
	_safety_timer -= _SAFETY_CHECK_INTERVAL
	
	# Signal-driven path is primary; only perform safety scan when we've been idle.
	if _time_since_signal_update < 3.0:
		return

	if get_tree() == null:
		return

	var new_total := calculate_total_power()
	if absf(new_total - _last_emitted_power) > POWER_CHANGE_THRESHOLD:
		_cached_total_power = new_total
		_last_emitted_power = new_total
		total_power_changed.emit(new_total)

# ==================== DEVICE MANAGEMENT ====================

## Register a power device with the registry
func register_device(device: PowerDevice) -> void:
	if device == null:
		push_warning("DeviceRegistry: Attempted to register null device")
		return
	
	var device_id : String = device.device_id
	if device_id.is_empty():
		push_warning("DeviceRegistry: Device has empty device_id")
		return
	
	if _devices.has(device_id):
		push_warning("DeviceRegistry: Device '%s' already registered, updating reference" % device_id)
	
	_devices[device_id] = device
	
	# Connect to device signals
	if not device.power_changed.is_connected(_on_device_power_changed):
		device.power_changed.connect(_on_device_power_changed)
	if not device.state_changed.is_connected(_on_device_state_changed):
		device.state_changed.connect(_on_device_state_changed)
	
	device_registered.emit(device_id, device)
	_update_total_power()

## Unregister a power device from the registry
func unregister_device(device_id: String) -> void:
	if not _devices.has(device_id):
		return
	
	var device : PowerDevice = _devices[device_id]
	
	# Disconnect signals (only if device is still valid)
	if device != null and is_instance_valid(device):
		if device.power_changed.is_connected(_on_device_power_changed):
			device.power_changed.disconnect(_on_device_power_changed)
		if device.state_changed.is_connected(_on_device_state_changed):
			device.state_changed.disconnect(_on_device_state_changed)
	
	_devices.erase(device_id)
	device_unregistered.emit(device_id)
	_update_total_power()

# ==================== QUERIES ====================

## Get a device by its ID
func get_device(device_id: String) -> PowerDevice:
	return _devices.get(device_id, null)

## Get all registered devices
func get_all_devices() -> Array[PowerDevice]:
	var result : Array[PowerDevice] = []
	for device in _devices.values():
		if device != null and is_instance_valid(device):
			result.append(device)
	return result

## Get all device IDs
func get_all_device_ids() -> Array[String]:
	var result : Array[String] = []
	for key in _devices.keys():
		result.append(key)
	return result

## Get total number of registered devices
func get_device_count() -> int:
	return _devices.size()

## Get devices filtered by type
func get_devices_by_type(device_type: DeviceTypes.DeviceType) -> Array[PowerDevice]:
	var result : Array[PowerDevice] = []
	for device in _devices.values():
		if device != null and device.device_type == device_type:
			result.append(device)
	return result

## Get devices that are currently consuming power
func get_active_devices() -> Array[PowerDevice]:
	var result : Array[PowerDevice] = []
	for device in _devices.values():
		if device != null and device.is_consuming_power():
			result.append(device)
	return result

# ==================== POWER CALCULATIONS ====================

## Calculate total power consumption from all devices (in Watts)
func calculate_total_power() -> float:
	var total : float = 0.0
	var to_remove : Array[String] = []
	
	for device_id in _devices.keys():
		var device = _devices[device_id]
		if device == null or not is_instance_valid(device):
			to_remove.append(device_id)
			continue
		total += device.get_current_power()
	
	# Clean up freed devices
	for device_id in to_remove:
		_devices.erase(device_id)
	
	return total

## Get cached total power (faster, updated periodically)
func get_total_power() -> float:
	return _cached_total_power

## Get total power in kilowatts
func get_total_power_kw() -> float:
	return _cached_total_power / 1000.0

## Get power consumption by device type
func get_power_by_type(device_type: DeviceTypes.DeviceType) -> float:
	var total : float = 0.0
	for device in _devices.values():
		if device != null and device.device_type == device_type:
			total += device.get_current_power()
	return total

## Get power breakdown by device type
func get_power_breakdown() -> Dictionary:
	var breakdown : Dictionary = {}
	for device in _devices.values():
		if device != null:
			var type_name := DeviceTypes.get_type_name(device.device_type)
			if not breakdown.has(type_name):
				breakdown[type_name] = 0.0
			breakdown[type_name] += device.get_current_power()
	return breakdown

# ==================== BULK OPERATIONS ====================

## Turn off all devices
func turn_off_all() -> void:
	for device in _devices.values():
		if device != null:
			device.turn_off()

## Turn on all devices
func turn_on_all() -> void:
	for device in _devices.values():
		if device != null:
			device.turn_on()

## Set all devices to standby
func standby_all() -> void:
	for device in _devices.values():
		if device != null:
			device.set_standby()

## Turn off devices by type
func turn_off_by_type(device_type: DeviceTypes.DeviceType) -> void:
	for device in _devices.values():
		if device != null and device.device_type == device_type:
			device.turn_off()

# ==================== HOME ASSISTANT EXPORT ====================

## Get all devices as HA entity configurations
func get_all_ha_configs() -> Array[Dictionary]:
	var configs : Array[Dictionary] = []
	for device in _devices.values():
		if device != null:
			configs.append(device.get_ha_entity_config())
	return configs

# ==================== SIGNAL HANDLERS ====================

func _on_device_power_changed(_device_id: String, _watts: float) -> void:
	_time_since_signal_update = 0.0
	_update_total_power()

func _on_device_state_changed(_device_id: String, _old_state: int, _new_state: int) -> void:
	_time_since_signal_update = 0.0
	_update_total_power()

func _update_total_power() -> void:
	_cached_total_power = calculate_total_power()
	if absf(_cached_total_power - _last_emitted_power) > POWER_CHANGE_THRESHOLD:
		_last_emitted_power = _cached_total_power
		total_power_changed.emit(_cached_total_power)
