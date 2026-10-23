class_name StateTrigger
extends AutomationTrigger

## Triggers when a device changes to a specific state.
## Equivalent to Home Assistant's state trigger.

## Device ID to monitor
@export var entity_id : String = ""

## State to trigger on (empty = any state change)
@export var to_state : String = ""

## Previous state required (empty = any previous state)
@export var from_state : String = ""

## How long the state must be held before triggering (in seconds, 0 = immediate)
@export_range(0.0, 3600.0, 1.0) var for_seconds : float = 0.0

# Internal tracking
var _state_start_time : float = 0.0
var _last_known_state : String = ""

func get_platform() -> String:
	return "state"

func evaluate(context: Dictionary) -> bool:
	if not enabled or entity_id.is_empty():
		return false
	
	# Get device state from context
	var devices : Dictionary = context.get("devices", {})
	var device_states : Dictionary = context.get("device_states", {})
	
	var current_state : String = device_states.get(entity_id, "unknown")
	var game_time : float = context.get("sim_seconds", context.get("game_time", 0.0))  # `for` on the sim clock
	
	# Check if state matches target
	var state_matches := false
	if to_state.is_empty():
		# Trigger on any state change
		state_matches = (current_state != _last_known_state and not _last_known_state.is_empty())
	else:
		state_matches = (current_state == to_state)
	
	# Check from_state if specified
	if state_matches and not from_state.is_empty():
		state_matches = (_last_known_state == from_state)
	
	# Handle "for" duration
	if state_matches and for_seconds > 0.0:
		if current_state != _last_known_state:
			_state_start_time = game_time
		
		var duration := game_time - _state_start_time
		state_matches = (duration >= for_seconds)
	
	_last_known_state = current_state
	return state_matches

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["entity_id"] = entity_id
	
	if not to_state.is_empty():
		result["to"] = to_state
	if not from_state.is_empty():
		result["from"] = from_state
	if for_seconds > 0.0:
		var hours := int(for_seconds / 3600)
		var minutes := int((for_seconds - hours * 3600) / 60)
		var seconds := int(for_seconds) % 60
		result["for"] = "%02d:%02d:%02d" % [hours, minutes, seconds]
	
	return result

