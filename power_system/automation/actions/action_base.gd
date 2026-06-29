class_name AutomationAction
extends Resource

## Base class for automation actions.
## Actions are executed when triggers fire and conditions pass.
## Modeled after Home Assistant action schema.

## Human-readable description
@export var alias : String = ""

## Whether this action is enabled
@export var enabled : bool = true

## Execute the action
## context: Dictionary with current state and references
## Returns true if action executed successfully
func execute(_context: Dictionary) -> bool:
	return false

## Get the service name (for HA export) - overridden by subclasses
func get_service() -> String:
	return "unknown.unknown"

## Export to Home Assistant YAML format as Dictionary
func to_ha_dict() -> Dictionary:
	var result := {}
	if not alias.is_empty():
		result["alias"] = alias
	return result

## Create a duplicate of this action
func duplicate_action() -> AutomationAction:
	return duplicate(true) as AutomationAction
