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
	
	if not arguments.is_empty():
		result["data"] = {}
		for i in range(arguments.size()):
			result["data"]["arg%d" % i] = arguments[i]
	
	return result

