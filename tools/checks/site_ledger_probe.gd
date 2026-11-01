extends RefCounted

## One site, one ledger — on a real world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/site_ledger_probe.gd -Label site_ledger -Timeout 900
## A placed dome is a sleep space sized by its floor; a placed electric
## vehicle's charger is an AC load bound to it, drawing only while the load
## is on and the site's AC is up, gone when the prop is deleted; a vegetable
## bed makes FOOD into a food store (and refuses a biomass tank); the site's
## cost reaches SiteBalance's rows; packing a placed rack stows its graph
## array and unpacking it brings it back.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("site-ledger %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s).timeout


func _item_with(model, key: String, value: String) -> Dictionary:
	for it in model.items:
		if it is Dictionary and str(((it as Dictionary).get("specs", {}) as Dictionary).get(key, "")) == value:
			return it
	return {}


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	var gv := ServiceLocator.graph()
	_ok(loader != null and gv != null, "loader + graph view")
	if loader == null or gv == null:
		return {"ok": false, "fails": _fails}
	var model = gv.get("model")
	var was_ts := float(main.get("time_scale"))
	var was_day := float(main.get("day_time"))
	main.set("time_scale", 0.0)

	# -- A dome is shelter ----------------------------------------------------
	var reg: SpaceRegistry = loader.get("npc_spaces")
	_ok(reg != null, "space registry")
	var n0 := reg.spaces_of_type("sleep").size() if reg != null else 0
	var dome := PlacedPropService.place_model(main, DomeLabBuilder.MODEL_ID, true, Vector2(6.0, 0.0))
	_ok(bool(dome.get("ok", false)), "a dome is placed")
	await _frames(tree, 3)
	var dome_pid := str(dome.get("prop_id", ""))
	var dome_space := {}
	if reg != null:
		for s in reg.spaces_of_type("sleep"):
			var t: Dictionary = (s as Dictionary).get("target", {})
			if str(t.get("prop_id", "")) == dome_pid:
				dome_space = s
	_ok(not dome_space.is_empty(), "the dome is tagged as a sleep space")
	var cap := int(dome_space.get("capacity", 0))
	_ok(cap >= 1, "it sleeps someone (capacity %d)" % cap)
	_ok(reg != null and reg.spaces_of_type("sleep").size() == n0 + 1, "one more sleep space on the site")
	_ok(PlacedPropService.dome_sleepers(null) == 1, "a dome with no design sleeps one")
	loader.call("delete_prop_by_id", dome_pid)
	await _frames(tree, 2)

	# -- An electric vehicle's charger is a load -----------------------------
	var veh := PlacedPropService.place_model(main, "vehicle_euc", true, Vector2(-6.0, 0.0))
	_ok(bool(veh.get("ok", false)), "an EUC is placed")
	await _frames(tree, 4)
	var veh_pid := str(veh.get("prop_id", ""))
	var prop := PlacedPropRuntime.find_by_prop_id(main, veh_pid)
	var v: Node = prop.get_node_or_null("PlacedVehicle") if prop != null else null
	_ok(v != null, "PlacedVehicle runtime on the prop")
	if v != null:
		var gid := str(v.get("_load_gid"))
		_ok(not gid.is_empty(), "the charger registered a graph load")
		var it: Dictionary = model.get_item(gid) if not gid.is_empty() else {}
		_ok(not it.is_empty() and str(it.get("type", "")) == "appliance"
			and str((it.get("specs", {}) as Dictionary).get("bound_prop_id", "")) == veh_pid,
			"the load is an appliance bound to the prop")
		_ok(str(gv.call("placed_vehicle_item_id", veh_pid)) == gid, "placed_vehicle_item_id finds it")
		var ac := PlacedLightPower.ac_available(main)
		print("site-ledger: AC available on this site = %s" % str(ac))
		v.set("battery_wh", 100.0)
		await _wait(tree, 0.4)
		var w := float(v.call("get_current_power"))
		if ac:
			_ok(absf(w - 500.0) < 1.0, "charging draws the profile's 500 W (got %.0f)" % w)
		else:
			_ok(w == 0.0, "with AC down the charger draws nothing (got %.0f)" % w)
		# Switch the load off: the charger stops.
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["requested_state"] = "off"
		model.update_item(gid, {"specs": sp})
		await _wait(tree, 0.4)
		_ok(float(v.call("get_current_power")) == 0.0, "the load switched off stops the charger")
		sp["requested_state"] = "on"
		model.update_item(gid, {"specs": sp})
		v.set("battery_wh", float(v.get("battery_capacity_wh")))
		await _wait(tree, 0.4)
		_ok(float(v.call("get_current_power")) == 0.0, "a full battery draws nothing")
		loader.call("delete_prop_by_id", veh_pid)
		await _frames(tree, 3)
		_ok(str(gv.call("placed_vehicle_item_id", veh_pid)).is_empty(), "deleting the vehicle removes its load")

	# -- A vegetable bed makes food --------------------------------------------
	var bed_p := ComponentPresets.find_preset_by_label("Vegetable Bed (10 m²)")
	var food_p := ComponentPresets.find_preset_by_label("Food Store (50 kg)")
	var water_p := ComponentPresets.find_preset_by_label("Water Tank (250 gal)")
	var bio_p := ComponentPresets.find_preset_by_label("Biomass Store")
	_ok(not bed_p.is_empty() and not food_p.is_empty() and not water_p.is_empty() and not bio_p.is_empty(),
		"the presets exist")
	var ws: Dictionary = (water_p.get("specs", {}) as Dictionary).duplicate(true)
	ws["level"] = 1.0
	model.add_item({"id": "probe_water", "type": "resource", "scope_id": "root", "x": -400.0, "y": 900.0,
		"width": 90.0, "height": 100.0, "specs": ws})
	model.add_item({"id": "probe_food", "type": "resource", "scope_id": "root", "x": 0.0, "y": 900.0,
		"width": 90.0, "height": 100.0, "specs": (food_p.get("specs", {}) as Dictionary).duplicate(true)})
	model.add_item({"id": "probe_bio", "type": "resource", "scope_id": "root", "x": 200.0, "y": 900.0,
		"width": 90.0, "height": 100.0, "specs": (bio_p.get("specs", {}) as Dictionary).duplicate(true)})
	model.add_item({"id": "probe_bed", "type": "plant", "scope_id": "root", "x": -200.0, "y": 1100.0,
		"width": 160.0, "height": 130.0, "specs": (bed_p.get("specs", {}) as Dictionary).duplicate(true)})
	model.add_connection({"scope_id": "root", "source_item_id": "probe_water", "source_handle_id": "output",
		"target_item_id": "probe_bed", "target_handle_id": "water_in", "polarity": "resource", "resource_type": "water"})
	var c_food := {"scope_id": "root", "source_item_id": "probe_bed", "source_handle_id": "biomass_out",
		"target_item_id": "probe_food", "target_handle_id": "input", "polarity": "resource", "resource_type": "food"}
	model.add_connection(c_food)   # stamps its id on the dict
	main.set("day_time", 12.0)
	main.set("time_scale", 60.0 / 3600.0)
	await _wait(tree, 2.5)
	var bed: Dictionary = model.get_item("probe_bed")
	var bsp: Dictionary = bed.get("specs", {})
	print("site-ledger: bed → food: display '%s', food %.4f kg/h, biomass %.4f kg/h, ghi %.0f" % [
		str(bsp.get("display_value", "")), float(bsp.get("food_kg_h", 0.0)), float(bsp.get("biomass_kg_h", 0.0)),
		float(bsp.get("irradiance_wm2", 0.0))])
	_ok(str(bsp.get("display_value", "")).find("need") < 0, "a food store is the right tank for the bed")
	_ok(float(bsp.get("food_kg_h", 0.0)) > 0.0, "the bed makes food at noon")
	var food_lvl := float((model.get_item("probe_food").get("specs", {}) as Dictionary).get("level", 0.0))
	print("site-ledger: food store level %.5f" % food_lvl)
	# A biomass tank instead: refused.
	model.remove_connection(str(c_food["id"]))
	model.add_connection({"scope_id": "root", "source_item_id": "probe_bed", "source_handle_id": "biomass_out",
		"target_item_id": "probe_bio", "target_handle_id": "input", "polarity": "resource", "resource_type": "biomass"})
	await _wait(tree, 1.5)
	bsp = model.get_item("probe_bed").get("specs", {})
	_ok(str(bsp.get("display_value", "")) == "need food tank", "a biomass tank is refused (got '%s')" % str(bsp.get("display_value", "")))
	_ok(float(bsp.get("food_kg_h", 0.0)) == 0.0, "no food credited while refused")
	main.set("time_scale", 0.0)
	for iid in ["probe_bed", "probe_food", "probe_water", "probe_bio"]:
		model.remove_item(iid)

	# -- Cost reaches the balance sheet --------------------------------------
	var recs: Array = loader.call("placed_prop_records")
	var pt := SiteCost.placed_total(recs)
	_ok((pt["rows"] as Array).size() == recs.size(), "every placed record has a cost row")
	var extra := {"graph_usd": float(model.call("total_cost")), "placed_usd": pt["usd"],
		"placed_priced": pt["priced"], "placed_unpriced": pt["unpriced"]}
	var rows := SiteBalance.rows(SiteBalance.compute(GraphNesting.walk_items(model, "root"), {}, extra))
	var total_row := {}
	for r in rows:
		if str((r as Dictionary).get("k", "")) == "Site total":
			total_row = r
	print("site-ledger: cost graph $%.0f, placed $%.0f (%d priced, %d unpriced) → %s" % [
		float(extra["graph_usd"]), float(pt["usd"]), int(pt["priced"]), int(pt["unpriced"]), str(total_row.get("v", ""))])
	_ok(not total_row.is_empty(), "the balance sheet carries a Site total row")

	# -- Packing a placed rack stows its array -------------------------------
	var rack := PlacedPropService.place_model(main, PvArrayBuilder.MODEL_ID, true, Vector2(0.0, 8.0))
	_ok(bool(rack.get("ok", false)), "a solar rack is placed")
	await _frames(tree, 4)
	var rack_pid := str(rack.get("prop_id", ""))
	var tag := "pv_%s" % rack_pid
	_ok(bool(gv.call("has_array_with_tag", tag)), "placing the rack made its graph array")
	loader.call("set_prop_packed", rack_pid, true)
	await _frames(tree, 4)
	var arr := _item_with(model, "osm_tag", tag)
	_ok(bool((arr.get("specs", {}) as Dictionary).get("array_stowed", false)), "packing the rack stows its array")
	loader.call("set_prop_packed", rack_pid, false)
	await _frames(tree, 4)
	arr = _item_with(model, "osm_tag", tag)
	_ok(not bool((arr.get("specs", {}) as Dictionary).get("array_stowed", true)), "unpacking brings the array back")
	loader.call("delete_prop_by_id", rack_pid)
	await _frames(tree, 2)

	main.set("day_time", was_day)
	main.set("time_scale", was_ts)
	return {"ok": _fails.is_empty(), "fails": _fails}
