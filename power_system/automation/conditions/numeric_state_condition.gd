class_name NumericStateCondition
extends AutomationCondition

## Condition that checks if a numeric value is within a range.
## Equivalent to Home Assistant's numeric_state condition.

## Entity ID to check
@export var entity_id : String = ""

## Attribute to check (empty = main value)
@export var attribute : String = ""

## Value must be above this (disabled if -INF)
@export var above : float = -INF

## Value must be below this (disabled if INF)
@export var below : float = INF

func get_condition_type() -> String:
	return "numeric_state"

func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return true
	
	if entity_id.is_empty():
		return true
	
	# Get numeric value from context
	var numeric_values : Dictionary = context.get("numeric_values", {})
	var key := entity_id if attribute.is_empty() else "%s.%s" % [entity_id, attribute]
	
	# Handle special known entities
	if not numeric_values.has(key):
		if entity_id == "sensor.battery_level":
			var battery_percent : float = context.get("battery_percent", -1.0)
			if battery_percent >= 0.0:
				numeric_values[key] = battery_percent
		elif entity_id == "sensor.solar_power":
			var solar_kw : float = context.get("solar_power_kw", -1.0)
			if solar_kw >= 0.0:
				numeric_values[key] = solar_kw * 1000.0   # W, as labelled
		elif entity_id == "sensor.load_power":
			var load_kw : float = context.get("load_power_kw", -1.0)
			if load_kw >= 0.0:
				numeric_values[key] = load_kw * 1000.0   # W, as labelled
	
	if not numeric_values.has(key):
		return false
	
	var value : float = numeric_values[key]
	
	# Check range
	if above > -INF and value <= above:
		return false
	if below < INF and value >= below:
		return false
	
	return true

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["entity_id"] = entity_id
	
	if not attribute.is_empty():
		result["attribute"] = attribute
	if above > -INF:
		result["above"] = above
	if below < INF:
		result["below"] = below
	
	return result

