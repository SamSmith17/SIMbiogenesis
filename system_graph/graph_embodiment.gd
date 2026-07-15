class_name GraphEmbodiment
extends RefCounted

## Resolves 2D graph item bindings for bidirectional 3D↔2D highlight.


static func find_item_by_bound_prop_id(model: GraphModel, prop_id: String,
		scope_id: String = "") -> String:
	if model == null or prop_id.is_empty():
		return ""
	for item: Dictionary in _items_in_scope(model, scope_id):
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("bound_prop_id", "")) == prop_id:
			return str(item.get("id", ""))
	return ""


static func find_items_by_osm_tag(model: GraphModel, tag: String,
		scope_id: String = "") -> Array[String]:
	var out: Array[String] = []
	if model == null or tag.is_empty():
		return out
	for item: Dictionary in _items_in_scope(model, scope_id):
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("osm_tag", "")) == tag:
			out.append(str(item.get("id", "")))
	return out


static func find_item_by_scene_path(model: GraphModel, path_str: String,
		scope_id: String = "") -> String:
	if model == null or path_str.is_empty():
		return ""
	for item: Dictionary in _items_in_scope(model, scope_id):
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var p := str(specs.get("scene_device_path", item.get("device_path", "")))
		if p == path_str:
			return str(item.get("id", ""))
	return ""


## Returns "prop", "solar", "scene", or "" for an item with no 3D binding.
static func binding_kind(item: Dictionary) -> String:
	if item.is_empty():
		return ""
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if not str(specs.get("bound_prop_id", "")).is_empty():
		return "prop"
	if not str(specs.get("osm_tag", "")).is_empty():
		return "solar"
	var scene_path := str(specs.get("scene_device_path", item.get("device_path", "")))
	if not scene_path.is_empty():
		return "scene"
	return ""


static func _items_in_scope(model: GraphModel, scope_id: String) -> Array:
	if scope_id.is_empty():
		return model.items.duplicate()
	return model.get_items_in_scope(scope_id)
