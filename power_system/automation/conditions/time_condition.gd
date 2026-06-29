class_name TimeCondition
extends AutomationCondition

## Condition that checks if current time is within a range.
## Equivalent to Home Assistant's time condition.

## Start of allowed time window (24-hour format)
@export_range(0.0, 24.0, 0.01) var after_hour : float = 0.0

## End of allowed time window (24-hour format)
@export_range(0.0, 24.0, 0.01) var before_hour : float = 24.0

## Days of week when condition is valid (empty = all days)
## 0 = Sunday, 1 = Monday, ..., 6 = Saturday
@export var weekdays : Array[int] = []

func get_condition_type() -> String:
	return "time"

func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return true  # Disabled conditions pass
	
	var current_time : float = context.get("day_time", -1.0)
	if current_time < 0.0:
		return false
	
	# Check time range
	var in_range : bool
	if after_hour < before_hour:
		# Normal range (e.g., 8:00 to 20:00)
		in_range = current_time >= after_hour and current_time < before_hour
	else:
		# Overnight range (e.g., 22:00 to 6:00)
		in_range = current_time >= after_hour or current_time < before_hour
	
	if not in_range:
		return false
	
	# Check weekday if specified
	if not weekdays.is_empty():
		var current_day : int = context.get("weekday", -1)
		if current_day >= 0 and current_day not in weekdays:
			return false
	
	return true

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	
	# Convert to HH:MM:SS format
	var after_h := int(after_hour)
	var after_m := int((after_hour - after_h) * 60)
	var before_h := int(before_hour)
	var before_m := int((before_hour - before_h) * 60)
	
	result["after"] = "%02d:%02d:00" % [after_h, after_m]
	result["before"] = "%02d:%02d:00" % [before_h, before_m]
	
	if not weekdays.is_empty():
		var day_names := ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
		var days : Array[String] = []
		for day in weekdays:
			if day >= 0 and day < 7:
				days.append(day_names[day])
		result["weekday"] = days
	
	return result

