extends SceneTree

## Headless checks for GraphEmbodiment binding lookups.

const GraphEmbodimentScript := preload("res://system_graph/graph_embodiment.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _failed := 0
var _passed := 0


func _initialize() -> void:
	_run()
	_print_summary()
	quit(1 if _failed > 0 else 0)


func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		push_error("FAIL: %s %s" % [name, detail])


func _run() -> void:
	var model: GraphModel = GraphModelScript.new()
	model.add_item({
		"id": "wind1",
		"type": "wind",
		"specs": {"bound_prop_id": "prop_a", "name": "Turbine"},
	})
	model.add_item({
		"id": "hab1",
		"type": "processor",
		"specs": {"role": "habitat", "bound_prop_id": "prop_h", "occupants": 1},
	})
	model.add_item({
		"id": "pan1",
		"type": "panel",
		"specs": {"osm_tag": "osm_solar_1_2", "osm_import": true},
	})
	model.add_item({
		"id": "pan2",
		"type": "panel",
		"specs": {"osm_tag": "osm_solar_1_2", "osm_import": true},
	})
	model.add_item({
		"id": "dev1",
		"type": "appliance",
		"specs": {"scene_device_path": "/Main/World/Light"},
	})

	_check("find prop wind", GraphEmbodimentScript.find_item_by_bound_prop_id(model, "prop_a") == "wind1")
	_check("find prop habitat", GraphEmbodimentScript.find_item_by_bound_prop_id(model, "prop_h") == "hab1")
	_check("find osm tag count", GraphEmbodimentScript.find_items_by_osm_tag(model, "osm_solar_1_2").size() == 2)
	_check("find scene path", GraphEmbodimentScript.find_item_by_scene_path(model, "/Main/World/Light") == "dev1")
	_check("binding kind prop", GraphEmbodimentScript.binding_kind(model.get_item("wind1")) == "prop")
	_check("binding kind solar", GraphEmbodimentScript.binding_kind(model.get_item("pan1")) == "solar")
	_check("binding kind scene", GraphEmbodimentScript.binding_kind(model.get_item("dev1")) == "scene")
	_check("binding kind habitat graph-only", GraphEmbodimentScript.binding_kind({
		"specs": {"role": "habitat"},
	}) == "")


func _print_summary() -> void:
	if _failed == 0:
		print("GRAPH EMBODIMENT SELFTEST PASS  (%d checks)" % _passed)
	else:
		print("GRAPH EMBODIMENT SELFTEST FAIL  (%d pass, %d fail)" % [_passed, _failed])
