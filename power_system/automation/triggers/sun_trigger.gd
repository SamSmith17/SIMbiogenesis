class_name SunTrigger
extends AutomationTrigger

## Triggers at sunrise or sunset with optional offset.
## Equivalent to Home Assistant's sun trigger.

enum SunEvent {
	SUNRISE,
	SUNSET
}

## Which sun event to trigger on
@export var event : SunEvent = SunEvent.SUNSET

## Offset in hours (negative = before, positive = after)
@export_range(-6.0, 6.0, 0.01) var offset_hours : float = 0.0

## Tolerance in minutes
@export_range(0.0, 60.0, 1.0) var tolerance_minutes : float = 5.0

func get_platform() -> String:
	return "sun"

func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return false
	
	var current_time : float = context.get("day_time", -1.0)
	if current_time < 0.0:
		return false
	
	# Get sunrise/sunset times from context (calculated by main.gd or similar)
	var sunrise : float = context.get("sunrise_hour", 6.0)
	var sunset : float = context.get("sunset_hour", 18.0)
	
	# Determine target time based on event
	var target_time : float
	match event:
		SunEvent.SUNRISE:
			target_time = sunrise + offset_hours
		SunEvent.SUNSET:
			target_time = sunset + offset_hours
	
	# Normalize to 0-24 range
	while target_time < 0.0:
		target_time += 24.0
	while target_time >= 24.0:
		target_time -= 24.0
	
	# Check if current time is within tolerance
	var tolerance_hours := tolerance_minutes / 60.0
	var diff := absf(current_time - target_time)
	
	if diff > 12.0:
		diff = 24.0 - diff
	
	return diff <= tolerance_hours

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["event"] = "sunrise" if event == SunEvent.SUNRISE else "sunset"
	
	if offset_hours != 0.0:
		# Convert to HH:MM:SS offset format
		var negative := offset_hours < 0.0
		var abs_offset := absf(offset_hours)
		var hours := int(abs_offset)
		var minutes := int((abs_offset - hours) * 60)
		var seconds := int(((abs_offset - hours) * 60 - minutes) * 60)
		var sign_str := "-" if negative else ""
		result["offset"] = "%s%02d:%02d:%02d" % [sign_str, hours, minutes, seconds]
	
	return result

## Helper to set offset from hours, minutes
func set_offset(hours: int, minutes: int = 0, before: bool = false) -> void:
	offset_hours = hours + minutes / 60.0
	if before:
		offset_hours = -offset_hours

