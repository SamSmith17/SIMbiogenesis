class_name Automation
extends Resource

## Represents a complete automation rule.
## Combines triggers, conditions, and actions in Home Assistant style.
## Can be saved/loaded as .tres resources and exported to HA YAML.

# ==================== SIGNALS ====================

## Emitted when the automation is triggered
signal triggered(automation_id: String)

## Emitted when actions complete
signal actions_completed(automation_id: String, success: bool)

# ==================== CONFIGURATION ====================

## Unique identifier for this automation
@export var automation_id : String = ""

## Human-readable name
@export var alias : String = "New Automation"

## Description of what this automation does
@export_multiline var description : String = ""

## Whether the automation is enabled
@export var enabled : bool = true

## Mode for handling overlapping triggers
## single: Only one instance runs at a time (default)
## restart: Cancel current run and restart
## queued: Queue new triggers
## parallel: Allow multiple simultaneous runs
@export_enum("single", "restart", "queued", "parallel") var mode : String = "single"

## Maximum queued instances (for queued mode)
@export_range(1, 100, 1) var max_queued : int = 10

# ==================== COMPONENTS ====================

## Triggers that can start this automation (OR logic - any trigger fires it)
@export var triggers : Array[AutomationTrigger] = []

## Conditions that must ALL be true for actions to run (AND logic)
@export var conditions : Array[AutomationCondition] = []

## Actions to execute when triggered and conditions pass
@export var actions : Array[AutomationAction] = []

# ==================== INTERNAL STATE ====================

var _trigger_states : Dictionary = {}  # trigger_id -> last state (for edge detection)
var _is_running : bool = false
var _current_action_index : int = 0
var _queued_runs : int = 0

func _init() -> void:
	if automation_id.is_empty():
		automation_id = "automation_%d" % Time.get_ticks_msec()

# ==================== EVALUATION ====================

## Check if any trigger should fire
## Returns true if automation should run
func check_triggers(context: Dictionary) -> bool:
	if not enabled or triggers.is_empty():
		return false
	
	for trigger in triggers:
		if trigger == null or not trigger.enabled:
			continue
		
		var trigger_id := trigger.trigger_id if not trigger.trigger_id.is_empty() else str(triggers.find(trigger))
		var last_state : bool = _trigger_states.get(trigger_id, false)
		var current_state := trigger.evaluate(context)
		
		_trigger_states[trigger_id] = current_state
		
		# Edge detection: trigger on false -> true transition
		if current_state and not last_state:
			return true
	
	return false

## Check if all conditions pass
func check_conditions(context: Dictionary) -> bool:
	if not enabled:
		return false
	
	# Empty conditions = always pass
	if conditions.is_empty():
		return true
	
	# All conditions must pass (AND logic)
	for condition in conditions:
		if condition == null or not condition.enabled:
			continue
		
		if not condition.evaluate(context):
			return false
	
	return true

## Execute all actions in sequence
## Returns true if all actions completed successfully
func execute_actions(context: Dictionary) -> bool:
	if not enabled or actions.is_empty():
		return true
	
	# Check mode for overlapping runs
	if _is_running:
		match mode:
			"single":
				return false  # Ignore new trigger
			"restart":
				_reset_execution()  # Reset and restart
			"queued":
				if _queued_runs < max_queued:
					_queued_runs += 1
				return false
			"parallel":
				pass  # Allow parallel execution
	
	_is_running = true
	_current_action_index = 0
	triggered.emit(automation_id)
	
	var all_success := true
	for action in actions:
		if action == null or not action.enabled:
			continue
		
		var success := action.execute(context)
		if not success:
			all_success = false
			# Continue to next action even on failure
	
	_is_running = false
	actions_completed.emit(automation_id, all_success)
	
	# Process queued runs
	if _queued_runs > 0:
		_queued_runs -= 1
		call_deferred("execute_actions", context)
	
	return all_success

## Full evaluation cycle: check triggers, conditions, then execute
func evaluate(context: Dictionary) -> bool:
	if not enabled:
		return false
	
	if not check_triggers(context):
		return false
	
	if not check_conditions(context):
		return false
	
	return execute_actions(context)

func _reset_execution() -> void:
	_is_running = false
	_current_action_index = 0
	for action in actions:
		if action is DelayAction:
			action.reset()

# ==================== HOME ASSISTANT EXPORT ====================

## Export to Home Assistant YAML format as Dictionary
func to_ha_dict() -> Dictionary:
	var result := {
		"id": automation_id,
		"alias": alias,
		"mode": mode
	}
	
	if not description.is_empty():
		result["description"] = description
	
	if mode == "queued":
		result["max"] = max_queued
	
	# Triggers
	if not triggers.is_empty():
		var trigger_list : Array = []
		for trigger in triggers:
			if trigger != null:
				trigger_list.append(trigger.to_ha_dict())
		result["trigger"] = trigger_list
	
	# Conditions
	if not conditions.is_empty():
		var condition_list : Array = []
		for condition in conditions:
			if condition != null:
				condition_list.append(condition.to_ha_dict())
		result["condition"] = condition_list
	
	# Actions
	if not actions.is_empty():
		var action_list : Array = []
		for action in actions:
			if action != null:
				action_list.append(action.to_ha_dict())
		result["action"] = action_list
	
	return result

## Export to Home Assistant YAML string
func to_ha_yaml() -> String:
	var dict := to_ha_dict()
	return _dict_to_yaml(dict, 0)

## Helper to convert dictionary to YAML format
func _dict_to_yaml(data: Variant, indent: int) -> String:
	var indent_str := "  ".repeat(indent)
	var result := ""
	
	if data is Dictionary:
		for key in data.keys():
			var value = data[key]
			if value is Dictionary:
				result += "%s%s:\n%s" % [indent_str, key, _dict_to_yaml(value, indent + 1)]
			elif value is Array:
				result += "%s%s:\n" % [indent_str, key]
				for item in value:
					if item is Dictionary:
						result += "%s- %s" % [indent_str, _dict_to_yaml(item, indent + 1).strip_edges().replace("\n", "\n%s  " % indent_str)]
						result += "\n"
					else:
						result += "%s- %s\n" % [indent_str, str(item)]
			else:
				result += "%s%s: %s\n" % [indent_str, key, _format_yaml_value(value)]
	
	return result

func _format_yaml_value(value: Variant) -> String:
	if value is String:
		if value.contains(":") or value.contains("#") or value.begins_with(" "):
			return '"%s"' % value.replace('"', '\\"')
		return value
	elif value is bool:
		return "true" if value else "false"
	else:
		return str(value)

