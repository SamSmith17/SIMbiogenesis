class_name NumericStateTrigger
extends AutomationTrigger

## Triggers when a numeric value crosses a threshold.
## Equivalent to Home Assistant's numeric_state trigger.

## Entity ID to monitor (e.g., "sensor.battery_level")
@export var entity_id : String = ""

## Attribute to check (empty = use main value)
@export var attribute : String = ""

## Trigger when value goes above this (empty = no upper check)
@export var above : float = -INF

## Trigger when value goes below this (empty = no lower check)
@export var below : float = INF

## How long the condition must be true before triggering (seconds)
@export_range(0.0, 3600.0, 1.0) var for_seconds : float = 0.0

# Internal tracking
var _condition_start_time : float = 0.0
var _last_in_range : bool = false

func get_platform() -> String:
	return "numeric_state"

func evaluate(context: Dictionary) -> bool:
	if not enabled or entity_id.is_empty():
		return false
	
	# Get numeric value from context
	var numeric_values : Dictionary = context.get("numeric_values", {})
	var key := entity_id if attribute.is_empty() else "%s.%s" % [entity_id, attribute]
	
	if not numeric_values.has(key):
		# Try getting from battery level or other known values
		if entity_id == "sensor.battery_level":
			var battery_percent : float = context.get("battery_percent", -1.0)
			if battery_percent >= 0.0:
				numeric_values[key] = battery_percent
	
	if not numeric_values.has(key):
		return false
	
	var value : float = numeric_values[key]
	var game_time : float = context.get("game_time", 0.0)
	
	# Check if value is in range
	var in_range := true
	if above > -INF:
		in_range = in_range and (value > above)
	if below < INF:
		in_range = in_range and (value < below)
	
	# Handle "for" duration
	if in_range and for_seconds > 0.0:
		if not _last_in_range:
			_condition_start_time = game_time
		
		var duration := game_time - _condition_start_time
		in_range = (duration >= for_seconds)
	
	# Trigger on transition into range
	var should_trigger := in_range and not _last_in_range
	_last_in_range = in_range
	
	return should_trigger

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["entity_id"] = entity_id
	
	if not attribute.is_empty():
		result["attribute"] = attribute
	if above > -INF:
		result["above"] = above
	if below < INF:
		result["below"] = below
	if for_seconds > 0.0:
		var hours := int(for_seconds / 3600)
		var minutes := int((for_seconds - hours * 3600) / 60)
		var seconds := int(for_seconds) % 60
		result["for"] = "%02d:%02d:%02d" % [hours, minutes, seconds]
	
	return result

