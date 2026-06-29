class_name DeviceAction
extends AutomationAction

## Action to control a power device.
## Equivalent to Home Assistant's service calls for lights/switches.

enum DeviceCommand {
	TURN_ON,
	TURN_OFF,
	TOGGLE,
	SET_STANDBY,
	SET_ECO,
	SET_POWER_LEVEL
}

## Target device ID
@export var device_id : String = ""

## Command to execute
@export var command : DeviceCommand = DeviceCommand.TURN_ON

## Power level (0-100%) for SET_POWER_LEVEL command
@export_range(0.0, 100.0, 1.0) var power_level_percent : float = 100.0

func get_service() -> String:
	match command:
		DeviceCommand.TURN_ON:
			return "switch.turn_on"
		DeviceCommand.TURN_OFF:
			return "switch.turn_off"
		DeviceCommand.TOGGLE:
			return "switch.toggle"
		_:
			return "switch.turn_on"

func execute(context: Dictionary) -> bool:
	if not enabled or device_id.is_empty():
		return false
	
	# Get device from registry
	var tree : SceneTree = context.get("scene_tree", null)
	if tree == null:
		return false
	
	var registry : Node = tree.root.get_node_or_null("DeviceRegistry")
	if registry == null or not registry.has_method("get_device"):
		return false
	
	var device : Node = registry.get_device(device_id)
	if device == null:
		push_warning("DeviceAction: Device '%s' not found" % device_id)
		return false
	
	# Execute command
	match command:
		DeviceCommand.TURN_ON:
			if device.has_method("turn_on"):
				device.turn_on()
				return true
		DeviceCommand.TURN_OFF:
			if device.has_method("turn_off"):
				device.turn_off()
				return true
		DeviceCommand.TOGGLE:
			if device.has_method("toggle"):
				device.toggle()
				return true
		DeviceCommand.SET_STANDBY:
			if device.has_method("set_standby"):
				device.set_standby()
				return true
		DeviceCommand.SET_ECO:
			if device.has_method("set_eco"):
				device.set_eco()
				return true
		DeviceCommand.SET_POWER_LEVEL:
			if device.has_method("set_power_level"):
				device.set_power_level(power_level_percent / 100.0)
				return true
	
	return false

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["service"] = get_service()
	result["target"] = {"entity_id": device_id}
	
	if command == DeviceCommand.SET_POWER_LEVEL:
		result["data"] = {"brightness_pct": int(power_level_percent)}
	
	return result
