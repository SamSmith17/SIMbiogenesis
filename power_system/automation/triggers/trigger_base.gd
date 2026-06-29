class_name AutomationTrigger
extends Resource

## Base class for automation triggers.
## Triggers determine WHEN an automation should fire.
## Modeled after Home Assistant trigger schema.

## Unique identifier for this trigger within the automation
@export var trigger_id : String = ""

## Human-readable description
@export var alias : String = ""

## Whether this trigger is enabled
@export var enabled : bool = true

## Platform type (for HA export) - overridden by subclasses
func get_platform() -> String:
	return "unknown"

## Check if the trigger condition is met
## Returns true if the trigger should fire
## context: Dictionary with current state (time, devices, etc.)
func evaluate(_context: Dictionary) -> bool:
	return false

## Check if trigger state changed (for edge detection)
## Returns true only on the transition from false->true
func check_triggered(context: Dictionary, last_state: bool) -> bool:
	var current_state := evaluate(context)
	return current_state and not last_state

## Export to Home Assistant YAML format as Dictionary
func to_ha_dict() -> Dictionary:
	var result := {
		"platform": get_platform()
	}
	if not trigger_id.is_empty():
		result["id"] = trigger_id
	if not alias.is_empty():
		result["alias"] = alias
	return result

## Create a duplicate of this trigger
func duplicate_trigger() -> AutomationTrigger:
	return duplicate(true) as AutomationTrigger
