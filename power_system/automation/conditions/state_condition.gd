class_name StateCondition
extends AutomationCondition

## Condition that checks if a device is in a specific state.
## Equivalent to Home Assistant's state condition.

## Device ID to check
@export var entity_id : String = ""

## Required state (can be multiple, any match passes)
@export var states : Array[String] = []

## Attribute to check (empty = main state)
@export var attribute : String = ""

func get_condition_type() -> String:
	return "state"

func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return true
	
	if entity_id.is_empty() or states.is_empty():
		return true
	
	var device_states : Dictionary = context.get("device_states", {})
	var key := entity_id if attribute.is_empty() else "%s.%s" % [entity_id, attribute]
	
	var current_state : String = device_states.get(key, "unknown")
	
	# Check if current state matches any of the allowed states
	return current_state in states

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["entity_id"] = entity_id
	
	if states.size() == 1:
		result["state"] = states[0]
	else:
		result["state"] = states
	
	if not attribute.is_empty():
		result["attribute"] = attribute
	
	return result

