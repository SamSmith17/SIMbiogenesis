extends RefCounted

## A living vehicle's own power + its cargo door (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/vehicle_power_doors_check.gd -Label vehicle_power_doors -Timeout 900
## 1. A van's appliances run off its OWN house battery: the site inverter
##    going down leaves them on while a site load goes off; the vehicle's
##    power state is stepped and its battery card follows it.
## 2. Its battery run flat at night: its own loads go off, the site's stay.
## 3. A box truck with a kit in its bay: while the crew unloads it, its
##    cargo door stands open (ModelRoot/DoorsOpen); a host with no unload
##    stays shut.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("vehiclepower %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _place(main: Node, preset: String, x: float, z: float) -> String:
	return PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
		{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(preset)),
			"collision_enabled": true}}, x, z, 0.0)


func _vehicle_comp(sgv: Node, prop_id: String) -> Dictionary:
	var model: GraphModel = sgv.get("model")
	for it in model.items:
		var d: Dictionary = it
		if str((d.get("specs", {}) as Dictionary).get("vehicle_prop_id", "")) == prop_id:
			return d
	return {}


func _appliances(sgv: Node, scope: String) -> Array:
	var model: GraphModel = sgv.get("model")
	var out: Array = []
	for it in model.get_items_in_scope(scope):
		if str((it as Dictionary).get("type", "")) == "appliance":
			out.append(str((it as Dictionary).get("id", "")))
	return out


func _state(sgv: Node, iid: String) -> String:
	var model: GraphModel = sgv.get("model")
	return str((model.get_item(iid).get("specs", {}) as Dictionary).get("current_state", ""))


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _frames(tree, 10)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	var sgv := ServiceLocator.graph()
	var player := main.get_node_or_null("Player") as Node3D
	_ok(loader != null and sgv != null and player != null, "a map with a graph and a player")
	if loader == null or sgv == null or player == null:
		return {"ok": false, "fails": _fails}
	var host: Node = sgv.get("_sim_load_host")
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	var cleanup: Array = []
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 12.0)
	main.set("time_scale", 60.0 / 3600.0)

	# --- 1. the van's loads off its own battery -----------------------------
	var vid := _place(main, "van", p0.x + 18.0, p0.y)
	cleanup.append(vid)
	await _wait(tree, 2.0)
	var comp := _vehicle_comp(sgv, vid)
	var scope := str(comp.get("child_scope_id", ""))
	var loads := _appliances(sgv, scope)
	_ok(not comp.is_empty() and not loads.is_empty(), "the van on the graph with %d loads" % loads.size())
	var states: Dictionary = sgv.call("vehicle_power_states")
	var cid := str(comp.get("id", ""))
	_ok(states.has(cid), "the van's own power is stepped")
	# A site load to compare with: the first appliance outside every vehicle.
	var model: GraphModel = sgv.get("model")
	var vscopes := GraphAcLoad.vehicle_scopes(model)
	# Only loads the proxy host runs (a scene-bound charger or light is not one).
	var site_load := ""
	var proxied: Dictionary = host.get("_loads")
	for lid in proxied.keys():
		var d: Dictionary = model.get_item(str(lid))
		if str(d.get("type", "")) == "appliance" and not vscopes.has(str(d.get("scope_id", "root"))) \
				and str((d.get("specs", {}) as Dictionary).get("requested_state", "on")) == "on":
			site_load = str(lid)
			break
	if site_load.is_empty():
		# None on this site: put a plain AC load at root for the comparison.
		site_load = "vpd_site_load"
		model.add_item({"id": site_load, "type": "appliance", "x": 0.0, "y": 0.0,
			"scope_id": "root", "specs": {"name": "Probe site load", "max_watts": 60.0,
				"avg_watts": 60.0, "requested_state": "on"}})
		await _frames(tree, 4)
	print("vehiclepower: comparing with site load %s (%s)" % [site_load,
		str((model.get_item(site_load).get("specs", {}) as Dictionary).get("name", ""))])
	host.call("fan_ac_available", false)
	await _frames(tree, 3)
	var on_count := 0
	for l in loads:
		if _state(sgv, str(l)) == "on":
			on_count += 1
	_ok(on_count == loads.size(), "site inverter down: the van's %d loads stay on (%d on)" % [loads.size(), on_count])
	if not site_load.is_empty():
		_ok(_state(sgv, site_load) == "off", "site inverter down: a site load goes off")
	host.call("fan_ac_available", true)
	await _frames(tree, 3)

	# --- 2. the van's battery flat at night -------------------------------
	main.call("set_absolute_hours", day0 + 24.0 + 1.0)
	await _frames(tree, 2)
	var st: Dictionary = (sgv.call("vehicle_power_states") as Dictionary).get(cid, {})
	if not st.is_empty():
		st["soc_kwh"] = 0.0
	await _wait(tree, 2.0)
	st = (sgv.call("vehicle_power_states") as Dictionary).get(cid, {})
	_ok(not st.is_empty() and not bool(st.get("ac_available", true)), "a flat battery at night: no AC in the van")
	var off_count := 0
	for l in loads:
		if _state(sgv, str(l)) == "off":
			off_count += 1
	_ok(off_count == loads.size(), "a flat battery: the van's loads go off (%d of %d)" % [off_count, loads.size()])
	if not site_load.is_empty():
		_ok(_state(sgv, site_load) != "off" or not bool(get_node_bus(main).get("power_available")),
			"the site's loads follow the site, not the van")
	var bat_soc := -1.0
	for it in model.get_items_in_scope(scope):
		if str((it as Dictionary).get("type", "")) == "battery":
			bat_soc = float(((it as Dictionary).get("specs", {}) as Dictionary).get("soc", -1.0))
	_ok(bat_soc >= 0.0 and bat_soc <= 0.12, "the van's battery card reads its own charge (%.3f)" % bat_soc)
	main.call("set_absolute_hours", day0 + 36.0)

	# --- 3. the cargo door open while unloading ---------------------------
	var bridge: Variant = sgv.call("npc_population_bridge")
	if bridge == null or str(bridge.call("first_crewable_habitat")).is_empty():
		if main.has_method("open_festival_mode"):
			main.call("open_festival_mode")
			await _wait(tree, 4.0)
			if main.has_method("close_settlement_view"):
				main.call("close_settlement_view")
	var tid := _place(main, "box_truck", p0.x + 30.0, p0.y + 10.0)
	cleanup.append(tid)
	await _frames(tree, 6)
	var res: Dictionary = loader.call("deliver_kit_in_vehicle", "starter_camp", tid)
	cleanup.append_array(res.get("crate_ids", []))
	var opened := false
	var shut_other := true
	for _i in 30:
		await _wait(tree, 0.5)
		var prop := PlacedPropRuntime.find_by_prop_id(main, tid)
		if CargoDoors.is_open(prop):
			opened = true
			break
	var vprop := PlacedPropRuntime.find_by_prop_id(main, vid)
	if CargoDoors.is_open(vprop):
		shut_other = false
	_ok(opened, "the box truck's door stands open while its crew unloads it")
	_ok(shut_other, "the van (nothing to unload) stays shut")

	for pid in cleanup:
		loader.call("delete_prop_by_id", str(pid))
	if site_load == "vpd_site_load":
		model.remove_item(site_load)
	await _frames(tree, 4)
	main.set("time_scale", 0.0)
	print("HARNESS vehiclepower %s (%d fails)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}


func get_node_bus(main: Node) -> Node:
	return main.get_node_or_null("/root/AcPowerBus")
