class_name ServiceAction
extends AutomationAction

## Generic service call action for extensibility.
## Allows calling arbitrary methods on nodes/objects.

## Target node path (relative to scene root)
@export var target_path : String = ""

## Method name to call
@export var method_name : String = ""

## Arguments to pass (as array)
@export var arguments : Array = []

## Service name for HA export
@export var ha_service : String = ""

## HA export: the call's `target` and `data` blocks. When `ha_data` is set
## it replaces the arg0.. dump of `arguments` (a set_value exports as
## {service: number.set_value, target: {entity_id}, data: {value}}).
@export var ha_target : Dictionary = {}
@export var ha_data : Dictionary = {}


## The automation card's set_value action ({entity_id, value}) as a live
## action: AutomationEngine.set_entity_value(entity_id, value), exported as
## number.set_value (input_number.set_value for an input_number entity).
static func make_set_value(entity_id: String, value: float) -> ServiceAction:
	var a := ServiceAction.new()
	a.target_path = "AutomationEngine"
	a.method_name = "set_entity_value"
	a.arguments = [entity_id, value]
	a.ha_service = set_value_service(entity_id)
	a.ha_target = {"entity_id": entity_id}
	a.ha_data = {"value": value}
	return a


static func set_value_service(entity_id: String) -> String:
	return ("input_number" if entity_id.begins_with("input_number.") else "number") + ".set_value"


## Whether this action is a set_value made by make_set_value.
func is_set_value() -> bool:
	return method_name == "set_entity_value" and arguments.size() >= 2

func get_service() -> String:
	return ha_service if not ha_service.is_empty() else "script.%s" % method_name

func execute(context: Dictionary) -> bool:
	if not enabled or target_path.is_empty() or method_name.is_empty():
		return false
	
	var tree : SceneTree = context.get("scene_tree", null)
	if tree == null:
		return false
	
	# Find target node
	var target : Node = tree.root.get_node_or_null(target_path)
	if target == null:
		push_warning("ServiceAction: Target '%s' not found" % target_path)
		return false
	
	# Check if method exists
	if not target.has_method(method_name):
		push_warning("ServiceAction: Method '%s' not found on '%s'" % [method_name, target_path])
		return false
	
	# Call method with arguments
	var result = target.callv(method_name, arguments)
	return true

func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["service"] = get_service()
	if not ha_target.is_empty():
		result["target"] = ha_target.duplicate(true)
	if not ha_data.is_empty():
		result["data"] = ha_data.duplicate(true)
		return result
	
	if not arguments.is_empty():
		result["data"] = {}
		for i in range(arguments.size()):
			result["data"]["arg%d" % i] = arguments[i]
	
	return result

