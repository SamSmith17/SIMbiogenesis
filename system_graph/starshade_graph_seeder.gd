class_name StarShadeGraphSeeder
extends RefCounted

const DEFAULT_PANEL_COUNT := 18
const DEFAULT_PANEL_WATTS := 220.0
const STARSHADE_SOURCE := "starshade"
const STARSHADE_TAG := "starshade_site"

const ARRAY_DEF_ID := "starshade_solar_array"

const _SCENE_KEYWORDS := ["starshade", "linkagelab_export"]


## True when a registered PV-array definition already has exactly `panel_count`
## panels at `panel_watts` each (compare the fields we actually vary — Dictionary
## `==` identity is not a reliable deep compare here).
static func _array_def_matches(def: Dictionary, panel_count: int, panel_watts: float) -> bool:
	var items: Array = (def.get("subgraph", {}) as Dictionary).get("items", []) as Array
	if items.size() != maxi(1, panel_count):
		return false
	var want_w := maxf(1.0, panel_watts)
	for it_v: Variant in items:
		var sp: Dictionary = (it_v as Dictionary).get("specs", {}) as Dictionary
		if absf(float(sp.get("wmp", 0.0)) - want_w) > 0.01:
			return false
	return true


static func try_seed_from_main(main: Node, terrain_loader: Node = null,
		prop_id: String = "") -> bool:
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
	var seeded := seed_graph(model, int(info.get("panel_count", DEFAULT_PANEL_COUNT)),
			float(info.get("panel_watts", DEFAULT_PANEL_WATTS)),
			str(info.get("tag", STARSHADE_TAG)))
	# Always attempt prop↔compound bind (covers already-seeded graphs too).
	var bind_id := prop_id
	if bind_id.is_empty():
		bind_id = str(info.get("prop_id", ""))
	if bind_id.is_empty():
		bind_id = find_starshade_prop_id(main, terrain_loader)
	var bound := bind_starshade_prop(model, bind_id)
	if seeded or bound:
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")
		return seeded or bound
	return false


## Stamp bound_prop_id on the top-level StarShade compound so 3D conduits can
## anchor. No-op if already bound to this prop; skips compounds bound to another.
static func bind_starshade_prop(model: GraphModel, prop_id: String) -> bool:
	if model == null or prop_id.is_empty():
		return false
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "compound":
			continue
		if str(item.get("scope_id", "root")) != "root":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var is_ss := str(specs.get("definition_id", "")) == "starshade" \
				or str(specs.get("source", "")) == STARSHADE_SOURCE \
				or str(specs.get("starshade_tag", "")).begins_with("starshade") \
				or str(specs.get("model_id", "")) == "starshade"
		if not is_ss:
			continue
		var existing := str(specs.get("bound_prop_id", ""))
		if existing == prop_id:
			return true
		if not existing.is_empty():
			continue
		var patch: Dictionary = specs.duplicate(true)
		patch["bound_prop_id"] = prop_id
		if str(patch.get("model_id", "")).is_empty():
			patch["model_id"] = "starshade"
		model.update_item(str(item.get("id", "")), {"specs": patch})
		return true
	return false


static func find_starshade_prop_id(main: Node, terrain_loader: Node = null) -> String:
	var layer: Variant = null
	if terrain_loader != null:
		layer = terrain_loader.get("_placed_prop_layer")
	if layer == null and main != null:
		var terrain := main.get_node_or_null("Terrain")
		if terrain != null:
			for child in terrain.get_children():
				if child.has_method("find_by_id") and child.get("props") != null:
					layer = child
					break
	if layer == null or layer.get("props") == null:
		return ""
	for item: Variant in (layer.get("props") as Array):
		if not (item is Dictionary):
			continue
		var d := item as Dictionary
		var mid := str(d.get("model_id", ""))
		if ModelCatalog.is_starshade_model(mid):
			return str(d.get("id", ""))
	return ""


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
	# Realize the multi-level StarShade COMPONENT (solar array / hybrid inverter /
	# battery bank -> panels / CC+inverter circuits / batteries) instead of flat
	# nodes. `source`/`starshade_tag` ride as instance-only identity so HA linking,
	# dedupe (has_graph_content) and clear_starshade_content keep working, and the
	# structure stays live-editable (edits inside it propagate to any sibling).
	# The PV array definition is sized to the REQUESTED panel count/watts — those
	# are player-facing (StarShade edit modal spinboxes, imported LinkageLab
	# `solar.panelCount`/`panelWatts`), so a fixed 18×220 W template would make
	# Re-seed a no-op.
	var defs: Dictionary = ComponentPresets.starshade_component_tree(panel_count, panel_watts)
	for did in defs.keys():
		var want: Dictionary = defs[did] as Dictionary
		var have: Dictionary = model.get_definition(str(did))
		# Re-register the array whenever the stored template no longer matches the
		# request: reseed_graph clears the INSTANCE, but the definition survives,
		# so a size change would otherwise re-realize the previous array.
		if have.is_empty() or (str(did) == ARRAY_DEF_ID \
				and not _array_def_matches(have, panel_count, panel_watts)):
			model.put_definition(want)
	var comp_id := GraphComponentDefs.realize(model, "starshade", "root",
		Vector2(0.0, -60.0), {"source": STARSHADE_SOURCE, "starshade_tag": tag})
	if comp_id.is_empty():
		return false
	# Tidy each realized child scope so the structure reads cleanly regardless of
	# the template's seed positions (mirrors PuzzleStarterGraphSeeder._finish_seed).
	_layout_realized_scopes(model, comp_id)
	model.changed.emit("starshade_seed")
	print("StarShadeGraphSeeder: seeded StarShade component (nested array + hybrid inverter + battery bank)")
	return true


## Lay out every realized child scope of a just-stamped component — panel-heavy
## scopes get a clean grid, everything else a light force-directed relaxation
## (same path Arrange uses via SystemGraphView._layout_compound_scopes).
static func _layout_realized_scopes(model: GraphModel, comp_id: String) -> void:
	if model == null or comp_id.is_empty():
		return
	var comp := model.get_item(comp_id)
	var root_child := str(comp.get("child_scope_id", ""))
	if root_child.is_empty():
		return
	for sid in GraphNesting.descendant_scopes(model, root_child):
		var items: Array = GraphLayout.filter_layout_items(
				model.get_items_in_scope(str(sid)))
		if items.size() < 2:
			continue
		var panels := 0
		for it: Dictionary in items:
			if str(it.get("type", "")) == "panel":
				panels += 1
		var patches: Dictionary
		if panels >= items.size() * 0.6:
			var cols := maxi(1, int(round(sqrt(float(items.size())))))
			patches = GraphLayout.layout_grid(items, cols, Vector2(24.0, 24.0))
		else:
			var conns: Array = model.get_connections_in_scope(str(sid)) \
					if model.has_method("get_connections_in_scope") else []
			patches = GraphLayout.relax_forces(items, conns)
		for iid_v in patches.keys():
			var pos: Vector2 = patches[iid_v] as Vector2
			model.update_item(str(iid_v), {"x": pos.x, "y": pos.y})


static func count_panels(model: GraphModel) -> int:
	var n := 0
	if model == null:
		return 0
	# Walk nested scopes — StarShade panels now live inside the component tree.
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if bool(item.get("is_virtual", false)):
			continue
		if str(item.get("type", "")) == "panel":
			n += 1
	return n


static func total_battery_kwh(model: GraphModel) -> float:
	var kwh := 0.0
	if model == null:
		return 0.0
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
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
		"prop_id": "",
	}
	if main == null:
		return out
	var pid := find_starshade_prop_id(main, terrain_loader)
	if not pid.is_empty():
		out["found"] = true
		out["prop_id"] = pid
	elif _scene_has_starshade(main):
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
			# Same indexing as SolarBridge: group stride + string offset within group.
			var base := g * (s_count * series) + s * series
			if base + series - 1 >= panel_ids.size():
				continue
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
