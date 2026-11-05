extends RefCounted

## Graph systems, Phase 0 (plans/GRAPH_SYSTEMS_UX_PLAN.md), on a real world
## (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/graph_systems_check.gd -Label graph_systems -Timeout 900
## 1. Placing a living vehicle with roof solar and a house battery leaves the
##    SITE's solar peak, battery capacity and stored kWh where they were, and
##    the vehicle's battery card keeps its own SOC (the site SOC used to be
##    written over it).
## 2. Every festival camp carries its site position at the top level (where
##    Site Plan, pins, Locate and Watch read it) and no two camp / vehicle
##    cards overlap at root.
## 3. Standing inside the vehicle's sub-graph: rebuilding the vehicle follows
##    the player to its new scope; deleting it drops them back to root, never
##    into an empty scope.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("graphsystems %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _place(main: Node, preset: String, x: float, z: float) -> String:
	return PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(preset)),
			"collision_enabled": true}}, x, z, 0.0)


func _comp_for(model: GraphModel, prop_id: String) -> Dictionary:
	for it in model.items:
		var d: Dictionary = it
		if str((d.get("specs", {}) as Dictionary).get("vehicle_prop_id", "")) == prop_id:
			return d
	return {}


func _site_totals(sui: Node) -> Dictionary:
	return {"peak": float(sui.get("PEAK_CAPACITY_KW")), "cap": float(sui.get("BATTERY_CAPACITY_KWH")),
		"stored": float(sui.get("battery_kwh_stored")), "max": float(sui.get("INVERTER_MAX_SOLAR_KW"))}


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _frames(tree, 10)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var sgv := ServiceLocator.graph()
	var player := main.get_node_or_null("Player") as Node3D
	var sui := tree.root.find_child("SolarUI", true, false)
	_ok(loader != null and sgv != null and player != null and sui != null, "a map with a graph, SolarUI and a player")
	if loader == null or sgv == null or player == null or sui == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = sgv.get("model")
	main.set("time_scale", 0.0)

	# --- 1. a vehicle does not move the site's own power ---------------------
	await _frames(tree, 6)
	var before := _site_totals(sui)
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var vid := _place(main, "magic_tool_bus", p0.x + 22.0, p0.y)
	await _frames(tree, 30)
	var comp := _comp_for(model, vid)
	_ok(not comp.is_empty(), "the tool bus is on the graph")
	var after := _site_totals(sui)
	print("graphsystems: site before %s after %s" % [str(before), str(after)])
	_ok(absf(float(after["peak"]) - float(before["peak"])) < 1e-4, "site solar peak unchanged by the vehicle")
	_ok(absf(float(after["cap"]) - float(before["cap"])) < 1e-4, "site battery capacity unchanged")
	_ok(absf(float(after["stored"]) - float(before["stored"])) < 0.05, "site stored kWh did not jump")
	_ok(absf(float(after["max"]) - float(before["max"])) < 1e-4, "site PV clamp unchanged (vehicle MPPT is not a site controller)")
	var scope := str(comp.get("child_scope_id", ""))
	var vbat := ""
	for it in model.get_items_in_scope(scope):
		if str((it as Dictionary).get("type", "")) == "battery":
			vbat = str((it as Dictionary).get("id", ""))
	# Drive the graph's energy sync (it runs on model changes and at 10 Hz
	# with the graph open) and step the vehicle's own power.
	main.set("time_scale", 60.0 / 3600.0)
	sgv.call("_sync_graph_energy_from_solar")
	await _frames(tree, 60)
	var states: Dictionary = sgv.call("vehicle_power_states")
	var st: Dictionary = states.get(str(comp.get("id", "")), {})
	var bat_soc := float((model.get_item(vbat).get("specs", {}) as Dictionary).get("soc", -1.0))
	var site_soc := float(sui.get("battery_kwh_stored")) / maxf(float(sui.get("BATTERY_CAPACITY_KWH")), 1e-6)
	print("graphsystems: vehicle battery soc %.3f  site soc %.3f  own state %s" % [bat_soc, site_soc, str(st)])
	_ok(not st.is_empty(), "the vehicle's own power is stepped")
	var own_kwh := float(st.get("soc_kwh", -1.0))
	var cap := 0.0
	for it in model.get_items_in_scope(scope):
		if str((it as Dictionary).get("type", "")) == "battery":
			cap = float(((it as Dictionary).get("specs", {}) as Dictionary).get("kwh", 0.0))
	_ok(cap > 0.0 and absf(bat_soc - own_kwh / cap) < 0.02,
		"the vehicle battery card reads its own SOC (%.3f vs %.3f)" % [bat_soc, own_kwh / maxf(cap, 1e-6)])
	main.set("time_scale", 0.0)

	# --- 2. camps on the map, no stacked cards --------------------------------
	var camps: Array = sgv.call("festival_camps")
	var no_top := 0
	for c in camps:
		var d := model.get_item(str((c as Dictionary)["id"]))
		if not GraphSiteLayout.has_site_coords(d):
			no_top += 1
	print("graphsystems: %d camps, %d without top-level site coords" % [camps.size(), no_top])
	_ok(no_top == 0, "every camp carries its site position at the top level")
	var rects: Array = []
	for it in model.get_items_in_scope("root"):
		var d: Dictionary = it
		if GraphSystems.is_power_island(d):
			rects.append(Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
				float(d.get("width", 220.0)), float(d.get("height", 150.0))).grow(-4.0))
	var overlaps := 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j] as Rect2):
				overlaps += 1
	print("graphsystems: %d system cards, %d overlapping pairs" % [rects.size(), overlaps])
	_ok(overlaps == 0, "no two camp / vehicle cards overlap")

	# --- 3. the scope trail survives a rebuild and a delete -------------------
	sgv.call("_enter_compound", str(comp.get("id", "")))
	_ok(str(sgv.get("_active_scope_id")) == scope, "entered the vehicle's sub-graph")
	var d2 := VehicleDesign.solve(VehiclePresets.builtin("van"))
	var wp := Vector3(p0.x + 22.0, player.global_position.y, p0.y)
	sgv.call("sync_vehicle_system", vid, d2, wp)
	await _frames(tree, 4)
	var comp2 := _comp_for(model, vid)
	var scope2 := str(comp2.get("child_scope_id", ""))
	print("graphsystems: rebuilt scope %s -> %s, active %s" % [scope, scope2, str(sgv.get("_active_scope_id"))])
	_ok(not scope2.is_empty() and str(sgv.get("_active_scope_id")) == scope2,
		"a rebuilt vehicle keeps the player inside it")
	loader.call("delete_prop_by_id", vid)
	await _frames(tree, 6)
	var active := str(sgv.get("_active_scope_id"))
	_ok(active == "root" or not model.get_scope(active).is_empty(),
		"deleting it never leaves an empty scope (active: %s)" % active)
	_ok(active == "root", "back at root after the vehicle is gone")
	return {"ok": _fails.is_empty(), "fails": _fails}
