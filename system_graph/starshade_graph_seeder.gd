class_name StarShadeGraphSeeder
extends RefCounted

const DEFAULT_PANEL_COUNT := 18
const DEFAULT_PANEL_WATTS := 220.0
const STARSHADE_SOURCE := "starshade"
const STARSHADE_TAG := "starshade_site"

const _SCENE_KEYWORDS := ["starshade", "linkagelab_export"]


static func try_seed_from_main(main: Node, terrain_loader: Node = null) -> bool:
	if main == null:
		return false
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null:
		return false
	var model: GraphModel = sgv.get("model") as GraphModel
	if model == null:
		return false
	var info := detect_starshade(main, terrain_loader)
	if not bool(info.get("found", false)):
		return false
	if seed_graph(model, int(info.get("panel_count", DEFAULT_PANEL_COUNT)),
			float(info.get("panel_watts", DEFAULT_PANEL_WATTS)),
			str(info.get("tag", STARSHADE_TAG))):
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")
		return true
	return false


static func has_graph_content(model: GraphModel) -> bool:
	if model == null:
		return false
	for item: Dictionary in model.items:
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("source", "")) == STARSHADE_SOURCE:
			return true
		if str(specs.get("starshade_tag", "")).begins_with("starshade"):
			return true
		if str(item.get("id", "")).begins_with("starshade_"):
			return true
	return false


## Remove every prior StarShade-seeded node/connection so specs can be re-applied.
static func clear_starshade_content(model: GraphModel) -> int:
	if model == null:
		return 0
	var stale: Array[String] = []
	for item: Dictionary in model.items:
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var iid := str(item.get("id", ""))
		if str(specs.get("source", "")) == STARSHADE_SOURCE \
				or str(specs.get("starshade_tag", "")).begins_with("starshade") \
				or iid.begins_with("starshade_"):
			stale.append(iid)
	for sid in stale:
		model.remove_item(sid)
	return stale.size()


## Clear prior StarShade graph content and seed fresh panels/controller/batteries.
static func reseed_graph(model: GraphModel, panel_count: int, panel_watts: float,
		tag: String = STARSHADE_TAG) -> bool:
	if model == null or panel_count <= 0:
		return false
	clear_starshade_content(model)
	return seed_graph(model, panel_count, panel_watts, tag)


static func seed_graph(model: GraphModel, panel_count: int, panel_watts: float,
		tag: String = STARSHADE_TAG) -> bool:
	if model == null or panel_count <= 0:
		return false
	if has_graph_content(model):
		return false
	var n := mini(panel_count, GraphVirtualIds.ARRAY_PANEL_COUNT)
	var panel_ids: Array[String] = []
	for i in range(n):
		var iid := "starshade_pv_%02d" % (i + 1)
		panel_ids.append(iid)
		var pos := GraphVirtualIds.panel_node_position(i)
		model.add_item({
			"id": iid,
			"type": "panel",
			"x": pos.x,
			"y": pos.y,
			"width": 66.0,
			"height": 112.0,
			"scope_id": "root",
			"is_virtual": false,
			"specs": {
				"name": "StarShade PV-%02d" % (i + 1),
				"source": STARSHADE_SOURCE,
				"starshade_tag": tag,
				"wmp": panel_watts,
				"voc": 37.5,
				"vmp": 30.0,
				"isc": 8.7,
				"imp": panel_watts / 30.0,
				"cost": 300.0,
				"current_output_kw": 0.0,
			},
		})
	var ctrl_id := "starshade_ctrl"
	var ctrl_preset: Dictionary = {}
	for p: Dictionary in ComponentPresets.CONTROLLERS:
		if str(p.get("label", "")) == "EcoWorthy SL3500":
			ctrl_preset = p
			break
	var ctrl_specs: Dictionary = (ctrl_preset.get("specs", {}) as Dictionary).duplicate(true)
	ctrl_specs["source"] = STARSHADE_SOURCE
	ctrl_specs["starshade_tag"] = tag
	model.add_item({
		"id": ctrl_id,
		"type": "controller",
		"x": 140.0,
		"y": -120.0,
		"width": float(ctrl_preset.get("width", 140.0)),
		"height": float(ctrl_preset.get("height", 120.0)),
		"scope_id": "root",
		"is_virtual": false,
		"specs": ctrl_specs,
	})
	var bat_specs := {
		"name": "48V 50Ah LiFePO4",
		"voltage": 51.2,
		"ah": 50.0,
		"kwh": 2.56,
		"soc": 0.80,
		"cost": 650.0,
		"source": STARSHADE_SOURCE,
		"starshade_tag": tag,
	}
	for j in range(2):
		var bat_id := "starshade_bat_%c" % char(97 + j)
		model.add_item({
			"id": bat_id,
			"type": "battery",
			"x": 340.0 + float(j) * 140.0,
			"y": -100.0,
			"width": 100.0,
			"height": 136.0,
			"scope_id": "root",
			"is_virtual": false,
			"specs": bat_specs.duplicate(true),
		})
		_wire_battery(model, bat_id, ctrl_id, j)
	if n == GraphVirtualIds.ARRAY_PANEL_COUNT:
		_wire_panel_array(model, panel_ids, ctrl_id)
	else:
		GraphPvWiring.wire_series(model, panel_ids, ctrl_id)
	model.changed.emit("starshade_seed")
	print("StarShadeGraphSeeder: seeded %d panels @ %.0f W + EcoWorthy + 2× battery" % [
		n, panel_watts])
	return true


static func count_panels(model: GraphModel) -> int:
	var n := 0
	if model == null:
		return 0
	for item: Dictionary in model.get_items_in_scope("root"):
		if bool(item.get("is_virtual", false)):
			continue
		if str(item.get("type", "")) == "panel":
			n += 1
	return n


static func total_battery_kwh(model: GraphModel) -> float:
	var kwh := 0.0
	if model == null:
		return 0.0
	for item: Dictionary in model.get_items_in_scope("root"):
		if bool(item.get("is_virtual", false)):
			continue
		var itype := str(item.get("type", ""))
		if itype in ["battery", "smartbattery"]:
			kwh += float((item.get("specs", {}) as Dictionary).get("kwh", 0.0))
	return kwh


static func detect_starshade(main: Node, terrain_loader: Node = null) -> Dictionary:
	var out := {
		"found": false,
		"panel_count": DEFAULT_PANEL_COUNT,
		"panel_watts": DEFAULT_PANEL_WATTS,
		"tag": STARSHADE_TAG,
	}
	if main == null:
		return out
	if _placed_has_starshade(main, terrain_loader) or _scene_has_starshade(main):
		out["found"] = true
	return out


static func _wire_battery(model: GraphModel, bat_id: String, ctrl_id: String, idx: int) -> void:
	model.add_connection({
		"id": "starshade_bat_%d_pos" % idx,
		"polarity": "positive",
		"source_item_id": bat_id,
		"source_handle_id": "positive",
		"target_item_id": ctrl_id,
		"target_handle_id": "batteryPositive",
		"waypoints": [],
		"voltage_mismatch": false,
	})
	model.add_connection({
		"id": "starshade_bat_%d_neg" % idx,
		"polarity": "negative",
		"source_item_id": bat_id,
		"source_handle_id": "negative",
		"target_item_id": ctrl_id,
		"target_handle_id": "batteryNegative",
		"waypoints": [],
		"voltage_mismatch": false,
	})


static func _wire_panel_array(model: GraphModel, panel_ids: Array[String], ctrl_id: String) -> void:
	var g_count := GraphVirtualIds.ARRAY_GROUPS
	var s_count := GraphVirtualIds.ARRAY_STRINGS_PER_GROUP
	var series := GraphVirtualIds.ARRAY_SERIES_PER_STRING
	for g in range(g_count):
		for s in range(s_count):
			var base := g * (s_count * series)
			var p0 := panel_ids[base + 0]
			var p1 := panel_ids[base + 1]
			var p2 := panel_ids[base + 2]
			GraphPvWiring.add_pv_connection(model, "positive", p0, "positive", p1, "negative")
			GraphPvWiring.add_pv_connection(model, "positive", p1, "positive", p2, "negative")
			GraphPvWiring.add_pv_connection(model, "positive", p2, "positive", ctrl_id, "pvPositive")
			GraphPvWiring.add_pv_connection(model, "negative", p0, "negative", ctrl_id, "pvNegative")


static func _placed_has_starshade(main: Node, terrain_loader: Node) -> bool:
	var layer: Variant = null
	if terrain_loader != null:
		layer = terrain_loader.get("_placed_prop_layer")
	if layer == null:
		var terrain := main.get_node_or_null("Terrain")
		if terrain != null:
			for child in terrain.get_children():
				if child.has_method("find_by_id") and child.get("props") != null:
					layer = child
					break
	if layer == null or layer.get("props") == null:
		return false
	for item: Variant in (layer.get("props") as Array):
		if not (item is Dictionary):
			continue
		var mid := str((item as Dictionary).get("model_id", ""))
		if ModelCatalog.is_starshade_model(mid):
			return true
	return false


static func _scene_has_starshade(main: Node) -> bool:
	for node: Node in main.find_children("*", "", true, false):
		if node == null:
			continue
		var nm := str(node.name).to_lower()
		for kw: String in _SCENE_KEYWORDS:
			if nm.contains(kw):
				return true
		var scene_path := ""
		if "scene_file_path" in node:
			scene_path = str(node.scene_file_path).to_lower()
		if scene_path.contains("starshade"):
			return true
	return false
