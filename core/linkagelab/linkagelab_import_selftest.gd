extends SceneTree

## Headless self-test for LinkageLab → Godot import pipeline.

const CircuitMapperScript := preload("res://core/linkagelab/circuit_mapper.gd")
const DesignBundleScript := preload("res://core/linkagelab/design_bundle.gd")


func _init() -> void:
	var fails := 0
	fails += _test_circuit_mapper()
	fails += _test_design_bundle_validation()
	fails += _test_preserve_scale()
	if fails == 0:
		print("linkagelab_import_selftest: PASS (%d checks)" % 3)
	else:
		push_error("linkagelab_import_selftest: FAIL (%d)" % fails)
	quit(1 if fails > 0 else 0)


func _test_circuit_mapper() -> int:
	var circuit := {
		"items": [
			{
				"id": "panel-1",
				"type": "panel",
				"x": 100, "y": 100,
				"width": 120, "height": 100,
				"specs": {"name": "Test", "wmp": 220, "voc": 48, "vmp": 40, "isc": 6, "imp": 5.5},
			},
			{
				"id": "controller-1",
				"type": "controller",
				"x": 100, "y": 240,
				"width": 140, "height": 120,
				"specs": {"name": "MPPT", "maxVoc": 150, "ratedChargeCurrent": 50, "maxWmp": 2400},
			},
		],
		"connections": [
			{
				"id": "conn-1",
				"sourceItemId": "panel-1",
				"sourceHandleKey": "positive",
				"targetItemId": "controller-1",
				"targetHandleKey": "pvPositive",
				"polarity": "positive",
			},
		],
		"itemIdCounter": 2,
		"connectionIdCounter": 1,
	}
	var state: Dictionary = CircuitMapperScript.to_graph_save_state(circuit)
	var graph: Dictionary = state.get("graph", {}) as Dictionary
	var items: Array = graph.get("items", []) as Array
	var conns: Array = graph.get("connections", []) as Array
	if items.size() != 2:
		push_error("circuit_mapper: expected 2 items, got %d" % items.size())
		return 1
	if conns.size() != 1:
		push_error("circuit_mapper: expected 1 connection, got %d" % conns.size())
		return 1
	var panel: Dictionary = items[0] as Dictionary
	if float(panel.get("specs", {}).get("wmp", 0.0)) != 220.0:
		push_error("circuit_mapper: panel wmp not preserved")
		return 1
	var ctrl: Dictionary = items[1] as Dictionary
	if float(ctrl.get("specs", {}).get("max_voc", 0.0)) != 150.0:
		push_error("circuit_mapper: controller max_voc not remapped")
		return 1
	return 0


func _test_design_bundle_validation() -> int:
	var bad := DesignBundleScript.validate({"exportType": "wrong"})
	if bool(bad.get("ok", true)):
		push_error("design_bundle: should reject wrong exportType")
		return 1
	var missing_model := DesignBundleScript.validate({
		"exportType": DesignBundleScript.EXPORT_TYPE,
		"bundleVersion": 1,
		"circuit": {"items": [], "connections": []},
	})
	if bool(missing_model.get("ok", true)):
		push_error("design_bundle: should reject missing model")
		return 1
	var good := DesignBundleScript.validate({
		"exportType": DesignBundleScript.EXPORT_TYPE,
		"bundleVersion": 1,
		"model": {"base64": "AAAA"},
		"circuit": {"items": [{"id": "p1", "type": "panel"}], "connections": []},
	})
	if not bool(good.get("ok", false)):
		push_error("design_bundle: should accept minimal valid bundle")
		return 1
	return 0


func _test_preserve_scale() -> int:
	var entry := {
		"id": "selftest_preserve",
		"label": "Selftest",
		"path": "user://models/selftest_missing.glb",
		"preserve_scale": true,
		"target_height_m": 0.0,
		"mesh_scale": 1.0,
		"file_units_to_meters": ModelCatalog.LINKAGELAB_INCHES_TO_M,
		"source": "linkagelab",
	}
	ModelCatalog.register_user(entry)
	var s := ModelCatalog.resolved_scale("selftest_preserve", 1.0)
	var want := ModelCatalog.LINKAGELAB_INCHES_TO_M
	if absf(s - want) > 0.0001:
		push_error("preserve_scale: expected %.4f, got %s" % [want, s])
		return 1
	return 0
