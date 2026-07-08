extends SceneTree

## Offline checks for blank-graph migration, StarShade seeding idempotency, and aggregate math.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const SolarBridgeScript := preload("res://system_graph/solar_bridge.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_legacy_strip()
	fails += _test_bridge_no_autoseed()
	fails += _test_starshade_idempotent()
	fails += _test_aggregate_sync()
	if fails == 0:
		print("GRAPH SEED SELFTEST PASS  (4 checks)")
	else:
		print("GRAPH SEED SELFTEST FAIL  (%d failed)" % fails)
	quit()


func _populate_legacy_virtual_graph(model: GraphModel) -> void:
	for i in range(GraphVirtualIds.ARRAY_PANEL_COUNT):
		var iid := GraphVirtualIds.panel_node_id(i)
		var pos := GraphVirtualIds.panel_node_position(i)
		model.add_item({
			"id": iid,
			"type": "panel",
			"x": pos.x,
			"y": pos.y,
			"width": 66.0,
			"height": 112.0,
			"is_virtual": true,
			"specs": {"name": "PV-%02d" % (i + 1), "wmp": 220.0, "voc": 37.5, "cost": 0.0},
		})
	model.add_item({
		"id": GraphVirtualIds.V_CTRL_ID,
		"type": "controller",
		"x": 140.0,
		"y": -120.0,
		"width": 140.0,
		"height": 120.0,
		"is_virtual": true,
		"specs": {"name": "Hybrid Inverter", "max_voc": 150.0, "max_pv_watts": 3960.0},
	})
	model.add_item({
		"id": GraphVirtualIds.V_BATTERY_ID,
		"type": "battery",
		"x": 340.0,
		"y": -100.0,
		"width": 100.0,
		"height": 136.0,
		"is_virtual": true,
		"specs": {"name": "Battery Bank", "kwh": 16.0, "voltage": 48.0},
	})


func _test_legacy_strip() -> int:
	var model: GraphModel = GraphModelScript.new()
	_populate_legacy_virtual_graph(model)
	if not GraphVirtualIds.is_legacy_auto_virtual_only(model):
		push_error("legacy strip setup: should detect auto-virtual-only graph")
		return 1
	if not GraphVirtualIds.strip_legacy_virtual_solar(model):
		push_error("legacy strip: strip returned false")
		return 1
	if not model.items.is_empty():
		push_error("legacy strip: items remain after strip")
		return 1
	var bridge := SolarBridgeScript.new()
	bridge.setup(model, null)
	bridge.suppressed_ids = GraphVirtualIds.suppression_dictionary()
	bridge.tick(1.0)
	if not model.items.is_empty():
		push_error("legacy strip: bridge recreated virtual stack after strip+suppress")
		return 1
	return 0


func _test_bridge_no_autoseed() -> int:
	var model: GraphModel = GraphModelScript.new()
	var bridge := SolarBridgeScript.new()
	bridge.setup(model, null)
	bridge.suppressed_ids = GraphVirtualIds.suppression_dictionary()
	bridge.tick(1.0)
	if not model.items.is_empty():
		push_error("bridge no-autoseed: created items on blank graph")
		return 1
	return 0


func _test_starshade_idempotent() -> int:
	var model: GraphModel = GraphModelScript.new()
	if not StarShadeGraphSeeder.seed_graph(model, 18, 220.0, "test_tag"):
		push_error("starshade seed: first seed failed")
		return 1
	var first_count: int = model.items.size()
	if not StarShadeGraphSeeder.has_graph_content(model):
		push_error("starshade seed: missing starshade content after seed")
		return 1
	if StarShadeGraphSeeder.seed_graph(model, 18, 220.0, "test_tag"):
		push_error("starshade seed: second seed should be skipped")
		return 1
	if model.items.size() != first_count:
		push_error("starshade seed: item count changed on re-seed")
		return 1
	return 0


func _test_aggregate_sync() -> int:
	var model: GraphModel = GraphModelScript.new()
	StarShadeGraphSeeder.seed_graph(model, 6, 200.0, "agg_test")
	if StarShadeGraphSeeder.count_panels(model) != 6:
		push_error("aggregate sync: expected 6 panels got %d" % StarShadeGraphSeeder.count_panels(model))
		return 1
	if absf(StarShadeGraphSeeder.total_battery_kwh(model) - 5.12) > 0.01:
		push_error("aggregate sync: expected 5.12 kWh bank got %.2f" % StarShadeGraphSeeder.total_battery_kwh(model))
		return 1
	return 0
