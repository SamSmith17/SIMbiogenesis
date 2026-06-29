class_name SceneNodeAction
extends AutomationAction

## Runs turn_on / turn_off / toggle on a scene node by absolute NodePath.
## Use for graph-bound loads. Optional ha_entity_id for Home Assistant YAML export.

enum NodeCommand {
	TURN_ON,
	TURN_OFF,
	TOGGLE,
}

@export var node_path: String = ""
@export var ha_entity_id: String = ""
@export var command: NodeCommand = NodeCommand.TURN_ON


func execute(context: Dictionary) -> bool:
	if not enabled or node_path.is_empty():
		return false
	var tree: SceneTree = context.get("scene_tree") as SceneTree
	if tree == null:
		return false
	var n: Node = tree.root.get_node_or_null(NodePath(node_path))
	if n == null or not is_instance_valid(n):
		push_warning("SceneNodeAction: node not found: %s" % node_path)
		return false
	match command:
		NodeCommand.TURN_ON:
			if n.has_method("turn_on"):
				n.call("turn_on")
				return true
		NodeCommand.TURN_OFF:
			if n.has_method("turn_off"):
				n.call("turn_off")
				return true
		NodeCommand.TOGGLE:
			if n.has_method("toggle"):
				n.call("toggle")
				return true
	return false


func get_service() -> String:
	return _ha_domain() + "." + _ha_service_name()


func _ha_domain() -> String:
	if ha_entity_id.begins_with("light."):
		return "light"
	if ha_entity_id.begins_with("fan."):
		return "fan"
	return "switch"


func _ha_service_name() -> String:
	match command:
		NodeCommand.TURN_ON:
			return "turn_on"
		NodeCommand.TURN_OFF:
			return "turn_off"
		NodeCommand.TOGGLE:
			return "toggle"
	return "turn_on"


func to_ha_dict() -> Dictionary:
	var result := super.to_ha_dict()
	result["service"] = get_service()
	if not ha_entity_id.is_empty():
		result["target"] = {"entity_id": ha_entity_id}
	return result
