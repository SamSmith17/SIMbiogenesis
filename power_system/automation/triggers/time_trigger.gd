class_name TimeTrigger
extends AutomationTrigger

## Triggers at a specific time of day.
## Equivalent to Home Assistant's time trigger.

## Time to trigger (in 24-hour format, 0.0-24.0)
@export_range(0.0, 24.0, 0.01) var at_hour : float = 12.0

## Tolerance in minutes (trigger will fire within this window)
@export_range(0.0, 60.0, 1.0) var tolerance_minutes : float = 1.0

func get_platform() -> String:
	return "time"

func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return false
	# The engine's sim clock: fire when at_hour is crossed since the last
	# evaluation (exact at any clock speed; AutomationSim.crossed). The window
	# below is the fallback for a context without the clock.
	if context.has("abs_hours") and context.has("prev_abs_hours"):
		return AutomationSim.crossed(at_hour, float(context["prev_abs_hours"]), float(context["abs_hours"]))
	
	var current_time : float = context.get("day_time", -1.0)
	if current_time < 0.0:
		return false
	
	# Check if current time is within tolerance of target time
	var tolerance_hours := tolerance_minutes / 60.0
	var diff := absf(current_time - at_hour)
	
	# Handle wrap-around at midnight
	if diff > 12.0:
		diff = 24.0 - diff
	
	return diff <= tolerance_hours

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	# Convert decimal hours to HH:MM:SS format
	var hours := int(at_hour)
	var minutes := int((at_hour - hours) * 60)
	var seconds := int(((at_hour - hours) * 60 - minutes) * 60)
	result["at"] = "%02d:%02d:%02d" % [hours, minutes, seconds]
	return result

## Helper to set time from hours, minutes, seconds
func set_time(hours: int, minutes: int = 0, seconds: int = 0) -> void:
	at_hour = hours + minutes / 60.0 + seconds / 3600.0

