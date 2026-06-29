class_name DelayAction
extends AutomationAction

## Action that waits for a specified duration before continuing.
## Equivalent to Home Assistant's delay action.

## Delay duration in seconds
@export_range(0.0, 86400.0, 0.1) var delay_seconds : float = 1.0

## Whether to use game time (scaled by time_scale) or real time
@export var use_game_time : bool = true

# Internal state for async execution
var _remaining_time : float = 0.0
var _is_waiting : bool = false

func get_service() -> String:
	return "delay"

func execute(context: Dictionary) -> bool:
	if not enabled:
		return true  # Skip delay if disabled
	
	# This action is special - it signals that execution should pause
	# The AutomationEngine handles the actual delay
	_remaining_time = delay_seconds
	_is_waiting = true
	return true

## Called by AutomationEngine to update delay progress
## Returns true when delay is complete
func update_delay(delta: float, time_scale: float = 1.0) -> bool:
	if not _is_waiting:
		return true
	
	var effective_delta := delta * time_scale if use_game_time else delta
	_remaining_time -= effective_delta
	
	if _remaining_time <= 0.0:
		_is_waiting = false
		return true
	
	return false

func is_waiting() -> bool:
	return _is_waiting

func get_remaining_time() -> float:
	return _remaining_time

func reset() -> void:
	_remaining_time = 0.0
	_is_waiting = false

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	
	var hours := int(delay_seconds / 3600)
	var minutes := int((delay_seconds - hours * 3600) / 60)
	var seconds := delay_seconds - hours * 3600 - minutes * 60
	
	result["delay"] = "%02d:%02d:%05.2f" % [hours, minutes, seconds]
	return result
