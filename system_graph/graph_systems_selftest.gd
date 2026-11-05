extends SceneTree

## Headless self-test for GraphSystems (plans/GRAPH_SYSTEMS_UX_PLAN.md
## Phase 0): a living vehicle's node and a festival camp's compound are power
## ISLANDS. The site's own energy walk (walk_site_power) must give the same
## panels / batteries / controllers with or without them on the graph, the
## island map must cover nested groups, the AC-load reachability must leave
## island loads alone, and an island's AC wire losses are not site load.
## Pure / offline. Run --import first.
##   godot --headless --path . --script system_graph/graph_systems_selftest.gd

const EXPECTED_CHECKS := 42
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_vehicle_island()
	_test_camp_island_and_nesting()
	_test_ac_reach_and_losses()
	_test_status()
	_test_ring()
	_test_arrange_by_site()
	_test_derived_sites()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("GRAPH SYSTEMS SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("GRAPH SYSTEMS SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


## The player's own system at root: two panels, a controller, a battery.
func _site(model) -> void:
	model.add_item({"id": "p1", "type": "panel", "x": 0.0, "y": 0.0,
		"specs": {"wmp": 380.0, "voc": 41.6}})
	model.add_item({"id": "p2", "type": "panel", "x": 200.0, "y": 0.0,
		"specs": {"wmp": 380.0, "voc": 41.6}})
	model.add_item({"id": "c1", "type": "controller", "x": 0.0, "y": 200.0,
		"specs": {"max_voc": 480.0}})
	model.add_item({"id": "b1", "type": "battery", "x": 0.0, "y": 400.0,
		"specs": {"kwh": 20.8, "voltage": 51.2, "soc": 0.5}})


func _vehicle(model, prop_id: String) -> String:
	var d := VehicleDesign.solve(VehiclePresets.builtin("magic_tool_bus"))
	var def_id := VehicleGraph.def_id_for(prop_id)
	var def := VehicleGraph.definition(d, def_id)
	if def.is_empty():
		return ""
	model.put_definition(def)
	var cid: String = GraphComponentDefs.realize(model, def_id, "root", Vector2(0, 900), {
		"name": str(def["name"]), "vehicle_prop_id": prop_id, "bound_prop_id": prop_id,
		"node_banner": false})
	GraphComponentDefs.make_unique(model, cid)
	return cid


func _power_ids(items: Array) -> Array:
	var out: Array = []
	for it in items:
		var ty := str((it as Dictionary).get("type", ""))
		if ty in ["panel", "battery", "smartbattery", "controller"]:
			out.append(str((it as Dictionary).get("id", "")))
	out.sort()
	return out


func _test_vehicle_island() -> void:
	var model = GraphModelScript.new()
	_site(model)
	var before := _power_ids(GraphSystems.walk_site_power(model))
	var cid := _vehicle(model, "prop_bus_1")
	_check("the tool bus makes a graph node", not cid.is_empty())
	var comp: Dictionary = model.get_item(cid)
	var scope := str(comp.get("child_scope_id", ""))
	_check("a vehicle node is a power island", GraphSystems.is_power_island(comp))
	_check("... of kind vehicle", GraphSystems.island_kind(comp) == GraphSystems.KIND_VEHICLE)
	_check("its scope maps to it", str(GraphSystems.island_scopes(model).get(scope, "")) == cid)
	var inside := _power_ids(model.get_items_in_scope(scope))
	_check("the vehicle has panels / battery / controller inside", inside.size() >= 3, str(inside))
	# The bug this module exists for: walk_items(root) counted all of these.
	var all_root := _power_ids(GraphNesting.walk_items(model, "root"))
	_check("the plain walk still descends into it (flow needs that)",
		all_root.size() == before.size() + inside.size(), "%d vs %d" % [all_root.size(), before.size()])
	_check("the site's own power walk is unchanged by the vehicle",
		_power_ids(GraphSystems.walk_site_power(model)) == before,
		str(_power_ids(GraphSystems.walk_site_power(model))))
	var vbat := ""
	for it in model.get_items_in_scope(scope):
		if str((it as Dictionary).get("type", "")) == "battery":
			vbat = str((it as Dictionary).get("id", ""))
	_check("the vehicle battery belongs to the vehicle",
		GraphSystems.island_of(model, model.get_item(vbat)) == cid)
	_check("a site battery belongs to the site", GraphSystems.island_of(model, model.get_item("b1")) == "")
	_check("the compound itself sits in the site", not GraphSystems.in_island(model, comp))
	var listed := GraphSystems.list(model)
	_check("list() names the vehicle", listed.size() == 1 and str((listed[0] as Dictionary)["kind"]) == "vehicle")


func _test_camp_island_and_nesting() -> void:
	var model = GraphModelScript.new()
	_site(model)
	var def := CampTemplates.definition("theme_camp", 24)
	model.put_definition(def)
	var camp: String = GraphComponentDefs.realize(model, str(def["id"]), "root", Vector2(0, 700),
		{"camp_lot_id": "lot_7", "camp_headcount": 24, "name": "Camp Seven"})
	GraphComponentDefs.make_unique(model, camp)
	var cscope := str(model.get_item(camp).get("child_scope_id", ""))
	_check("a camp compound is an island of kind camp",
		GraphSystems.island_kind(model.get_item(camp)) == GraphSystems.KIND_CAMP)
	# A battery the player drops into a group INSIDE the camp is the camp's.
	model.ensure_scope("grp_scope", cscope, "grp", "Camp power")
	model.add_item({"id": "grp", "type": "compound", "x": 0.0, "y": 0.0, "scope_id": cscope,
		"child_scope_id": "grp_scope", "specs": {"compound_kind": ""}})
	model.add_item({"id": "cb", "type": "battery", "x": 0.0, "y": 0.0, "scope_id": "grp_scope",
		"specs": {"kwh": 5.0}})
	var isl := GraphSystems.island_scopes(model)
	_check("the camp's own scope is an island scope", str(isl.get(cscope, "")) == camp)
	_check("a group nested in the camp maps to the camp", str(isl.get("grp_scope", "")) == camp)
	_check("the nested battery is not site power",
		not _power_ids(GraphSystems.walk_site_power(model)).has("cb"))
	_check("site power still holds the site battery",
		_power_ids(GraphSystems.walk_site_power(model)).has("b1"))
	# The player's OWN group at root is not an island.
	model.ensure_scope("mine_scope", "root", "mine", "My system")
	model.add_item({"id": "mine", "type": "compound", "x": 0.0, "y": 0.0,
		"child_scope_id": "mine_scope", "specs": {"compound_kind": ""}})
	model.add_item({"id": "b2", "type": "battery", "x": 0.0, "y": 0.0, "scope_id": "mine_scope",
		"specs": {"kwh": 5.0}})
	_check("a plain group of the player's is not an island",
		not GraphSystems.is_power_island(model.get_item("mine")))
	_check("... and its battery counts for the site",
		_power_ids(GraphSystems.walk_site_power(model)).has("b2"))


func _test_ac_reach_and_losses() -> void:
	var model = GraphModelScript.new()
	_site(model)
	var cid := _vehicle(model, "prop_bus_2")
	var scope := str(model.get_item(cid).get("child_scope_id", ""))
	var reach: Dictionary = GraphAcLoad._reachable_ac_load_ids(model)
	var leaked := 0
	for lid in reach.keys():
		if GraphSystems.in_island(model, model.get_item(str(lid))):
			leaked += 1
	_check("no vehicle load is reachable from the site's controllers", leaked == 0)
	var vloads := 0
	for it in model.get_items_in_scope(scope):
		if str((it as Dictionary).get("type", "")) == "appliance":
			vloads += 1
	_check("the tool bus has loads to test with", vloads > 0)
	# A wire inside the vehicle carries the vehicle's power: no loss stamped
	# onto it for the site (losses forced on).
	var island_wires := 0
	for c in model.connections:
		if str((c as Dictionary).get("scope_id", "")) == scope:
			island_wires += 1
	_check("the vehicle has wires inside", island_wires > 0)
	# The player gives the vehicle's AC run a real cable (wires default to a
	# lossless conceptual type).
	for c in model.connections:
		var cw: Dictionary = c
		if str(cw.get("scope_id", "")) == scope and str(cw.get("polarity", "")) == "ac":
			cw["conduit_type"] = "romex"
	GraphAcLoad.connection_losses_watts(model, null, null, [], 1)
	var stamped := 0
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("scope_id", "")) == scope and cd.has("loss_w"):
			stamped += 1
	_check("the site's loss pass skips every wire inside the vehicle", stamped == 0, str(stamped))


func _test_status() -> void:
	var model = GraphModelScript.new()
	var def := CampTemplates.definition("theme_camp", 12)
	model.put_definition(def)
	var camp: String = GraphComponentDefs.realize(model, str(def["id"]), "root", Vector2.ZERO,
		{"camp_lot_id": "lot_s", "camp_headcount": 12, "name": "Camp S"})
	var set_specs := func(patch: Dictionary) -> Dictionary:
		var sp: Dictionary = (model.get_item(camp).get("specs", {}) as Dictionary).duplicate(true)
		for k in patch.keys():
			sp[k] = patch[k]
		model.update_item(camp, {"specs": sp})
		return GraphSystems.status(model, model.get_item(camp))
	_check("a camp with people and power is ok",
		str(set_specs.call({"camp_ac": true, "camp_open": [], "camp_soc": 0.8})["level"]) == "ok")
	_check("a camp with an open loop warns",
		str(set_specs.call({"camp_open": ["water"]})["level"]) == "warn")
	_check("a camp with no power is critical",
		str(set_specs.call({"camp_ac": false})["level"]) == "crit")
	var veh := _vehicle(model, "prop_s")
	var cap := 0.0
	for it in model.get_items_in_scope(str(model.get_item(veh).get("child_scope_id", ""))):
		if str((it as Dictionary).get("type", "")) == "battery":
			cap += float(((it as Dictionary).get("specs", {}) as Dictionary).get("kwh", 0.0))
	var vi: Dictionary = model.get_item(veh)
	_check("a vehicle with no power state reads parked",
		str(GraphSystems.status(model, vi, {})["level"]) == "idle")
	_check("a vehicle at 10 % warns",
		str(GraphSystems.status(model, vi, {"soc_kwh": cap * 0.1, "ac_available": true})["level"]) == "warn")
	_check("a vehicle whose AC is down is critical",
		str(GraphSystems.status(model, vi, {"soc_kwh": cap * 0.5, "ac_available": false})["level"]) == "crit")


func _test_ring() -> void:
	var model = GraphModelScript.new()
	var def := CampTemplates.definition("theme_camp", 12)
	model.put_definition(def)
	var camp: String = GraphComponentDefs.realize(model, str(def["id"]), "root", Vector2.ZERO,
		{"camp_lot_id": "lot_r", "camp_headcount": 12, "name": "Camp R"})
	var sp: Dictionary = (model.get_item(camp).get("specs", {}) as Dictionary).duplicate(true)
	sp["camp_ac"] = true
	sp["camp_soc"] = 0.8
	sp["camp_open"] = ["greywater"]
	sp["camp_morale"] = 0.3
	model.update_item(camp, {"specs": sp})
	var r := GraphSystems.ring(model, model.get_item(camp))
	_check("ring: power ok with charge", r["power"] == "ok", str(r))
	_check("ring: an open greywater loop warns on water", r["water"] == "warn")
	_check("ring: food closed is ok", r["food"] == "ok")
	_check("ring: low morale is critical", r["people"] == "crit")
	sp["camp_ac"] = false
	model.update_item(camp, {"specs": sp})
	_check("ring: no power is critical", GraphSystems.ring(model, model.get_item(camp))["power"] == "crit")
	var veh := _vehicle(model, "prop_ring")
	var vr := GraphSystems.ring(model, model.get_item(veh))
	_check("ring: a parked vehicle with no power state is idle", vr["power"] == "idle", str(vr))
	_check("ring: a vehicle has a water arc from its tanks", vr["water"] != "idle", str(vr))


func _test_arrange_by_site() -> void:
	var cards: Array = []
	for i in 12:
		# A tight festival: twelve camps 10 m apart in a row.
		cards.append({"id": "c%02d" % i, "site": Vector2(float(i) * 10.0 - 55.0, 40.0), "size": Vector2(220, 150)})
	var home := Rect2(-200, -150, 400, 300)
	var ppm := GraphSystems.auto_px_per_m(cards.map(func(c): return c["site"]), Vector2(220, 150))
	_check("auto scale spreads 10 m neighbours a card apart", ppm * 10.0 >= 220.0, str(ppm))
	var pos := GraphSystems.arrange_by_site(cards, [home], Vector2.ZERO, ppm)
	var rects: Array[Rect2] = []
	for c: Dictionary in cards:
		rects.append(Rect2(pos[c["id"]] as Vector2, c["size"] as Vector2))
	var overlaps := 0
	for i in rects.size():
		if rects[i].intersects(home):
			overlaps += 1
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				overlaps += 1
	_check("no two system cards overlap, none on the site's nodes", overlaps == 0, str(overlaps))
	var ordered := true
	for i in range(1, rects.size()):
		if rects[i].get_center().x < rects[i - 1].get_center().x - 1.0:
			ordered = false
	_check("west to east on the map stays west to east on the canvas", ordered)
	var again := GraphSystems.arrange_by_site(cards, [home], Vector2.ZERO, ppm)
	_check("arrange by site is deterministic", again == pos)


func _test_derived_sites() -> void:
	var model = GraphModelScript.new()
	var def := CampTemplates.definition("theme_camp", 12)
	model.put_definition(def)
	var camp: String = GraphComponentDefs.realize(model, str(def["id"]), "root", Vector2.ZERO,
		{"camp_lot_id": "lot_d", "camp_headcount": 12, "name": "Camp D"})
	model.update_item(camp, {"site_x_m": 100.0, "site_z_m": -40.0})
	var comp: Dictionary = model.get_item(camp)
	var kids := model.get_items_in_scope(str(comp.get("child_scope_id", "")))
	var keep := str((kids[0] as Dictionary).get("id", ""))
	model.update_item(keep, {"site_x_m": 1.0, "site_z_m": 2.0})
	var want := GraphSystems.derived_child_sites(model, model.get_item(camp), 14.0)
	_check("every unplaced camp item gets a map place", want.size() == kids.size() - 1, "%d of %d" % [want.size(), kids.size()])
	_check("an item with its own place keeps it", not want.has(keep))
	var far := 0.0
	for id in want.keys():
		far = maxf(far, (want[id] as Vector2).distance_to(Vector2(100.0, -40.0)))
	_check("the places sit round the camp, inside its radius", far <= 14.0 * 1.42 + 0.01, str(far))
