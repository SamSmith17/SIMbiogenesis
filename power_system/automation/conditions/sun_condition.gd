class_name SunCondition
extends AutomationCondition

## Condition that checks sun position.
## Equivalent to Home Assistant's sun condition.

enum SunState {
	ABOVE_HORIZON,
	BELOW_HORIZON
}

## Required sun state
@export var sun_state : SunState = SunState.ABOVE_HORIZON

## Offset from sunrise/sunset in hours
@export_range(-6.0, 6.0, 0.01) var before_offset_hours : float = 0.0
@export_range(-6.0, 6.0, 0.01) var after_offset_hours : float = 0.0

func get_condition_type() -> String:
	return "sun"

func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return true
	
	var current_time : float = context.get("day_time", -1.0)
	if current_time < 0.0:
		return false
	
	var sunrise : float = context.get("sunrise_hour", 6.0) + after_offset_hours
	var sunset : float = context.get("sunset_hour", 18.0) + before_offset_hours
	
	# Normalize times
	while sunrise < 0.0:
		sunrise += 24.0
	while sunrise >= 24.0:
		sunrise -= 24.0
	while sunset < 0.0:
		sunset += 24.0
	while sunset >= 24.0:
		sunset -= 24.0
	
	# Check if sun is above/below horizon
	var is_daytime : bool
	if sunrise < sunset:
		is_daytime = current_time >= sunrise and current_time < sunset
	else:
		# Handles edge case where sunset is before sunrise (shouldn't happen normally)
		is_daytime = current_time >= sunrise or current_time < sunset
	
	match sun_state:
		SunState.ABOVE_HORIZON:
			return is_daytime
		SunState.BELOW_HORIZON:
			return not is_daytime
	
	return true

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	
	match sun_state:
		SunState.ABOVE_HORIZON:
			result["after"] = "sunrise"
			result["before"] = "sunset"
		SunState.BELOW_HORIZON:
			result["after"] = "sunset"
			result["before"] = "sunrise"
	
	if after_offset_hours != 0.0:
		var negative := after_offset_hours < 0.0
		var abs_off := absf(after_offset_hours)
		var h := int(abs_off)
		var m := int((abs_off - h) * 60)
		result["after_offset"] = "%s%02d:%02d:00" % ["-" if negative else "", h, m]
	
	if before_offset_hours != 0.0:
		var negative := before_offset_hours < 0.0
		var abs_off := absf(before_offset_hours)
		var h := int(abs_off)
		var m := int((abs_off - h) * 60)
		result["before_offset"] = "%s%02d:%02d:00" % ["-" if negative else "", h, m]
	
	return result

