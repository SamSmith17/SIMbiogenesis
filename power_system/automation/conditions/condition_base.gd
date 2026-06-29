class_name AutomationCondition
extends Resource

## Base class for automation conditions.
## Conditions are checked AFTER a trigger fires to determine if actions should run.
## Modeled after Home Assistant condition schema.

## Human-readable description
@export var alias : String = ""

## Whether this condition is enabled
@export var enabled : bool = true

## Condition type (for HA export) - overridden by subclasses
func get_condition_type() -> String:
	return "unknown"

## Evaluate the condition
## Returns true if the condition is satisfied
## context: Dictionary with current state (time, devices, etc.)
func evaluate(context: Dictionary) -> bool:
	return true

## Export to Home Assistant YAML format as Dictionary
func to_ha_dict() -> Dictionary:
	var result := {
		"condition": get_condition_type()
	}
	if not alias.is_empty():
		result["alias"] = alias
	return result

## Create a duplicate of this condition
func duplicate_condition() -> AutomationCondition:
	return duplicate(true) as AutomationCondition
