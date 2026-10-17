extends RefCounted

## Energy-balance check for `--run-script` (sandbox; edits the graph in memory).
##
## Written for the Mt Vernon report of 2026-10-15 ("2.4 kW load, SolarUI says
## deficit, the battery never leaves 100 %"). Three contracts, each a FAIL line:
##  1. Stale cached future: run an hour with the AC load OFF, scrub back, switch
##     the load ON and play forward — the battery must discharge (it used to
##     replay the cached load-off curve, which is what pinned it at 100 %).
##  2. The sun with the graph OPEN: Main stops re-aiming the sun light while the
##     graph hides the 3D world; solar must still follow the clock to sunset.
##  3. Double-clicking a hydro turbine (the canvas's own signal) switches it
##     off — 0 W, no DC generation reaching SolarUI, no Hydro Lab — and a second
##     double-click switches it back on.
## It also prints the graph's energy readouts next to SolarUI's.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/energy_balance_probe.gd

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("energy-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _line(su: Node, main: Node) -> String:
	return ("h=%.2f soc=%.3f/%.2f kWh solar=%.3f raw=%.3f gdc=%.3f load=%.3f net=%+.3f"
		% [fposmod(float(main.call("get_absolute_hours")), 24.0),
			float(su.get("battery_kwh_stored")), float(su.get("BATTERY_CAPACITY_KWH")),
			float(su.get("current_solar_kw")), float(su.get("_raw_solar_kw")),
			float(su.get("current_graph_dc_kw")), float(su.get("current_load_kw")),
			float(su.get("current_solar_kw")) + float(su.get("current_aux_generation_kw"))
				+ float(su.get("current_graph_dc_kw")) - float(su.get("current_load_kw"))])


func _set_loads(model: Object, on: bool) -> void:
	for it in GraphNesting.walk_items(model):
		var d: Dictionary = it
		if str(d.get("type", "")) in ["appliance", "acload"]:
			var sp: Dictionary = (d.get("specs", {}) as Dictionary).duplicate(true)
			sp["requested_state"] = "on" if on else "off"
			model.call("update_item", str(d.get("id", "")), {"specs": sp})


func _full(su: Node) -> void:
	su.call("reanchor_live_battery", float(su.get("BATTERY_CAPACITY_KWH")))
	su.set("_soc_protect_active", false)
	su.set("_ac_shutdown_reason", "")


func _run_for(tree: SceneTree, main: Node, ts: float, secs: float) -> void:
	main.set("time_scale", ts)
	await tree.create_timer(secs).timeout
	main.set("time_scale", 0.0)
	for _f in 3:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = ServiceLocator.graph()
	if sgv == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var model: Object = sgv.get("model")
	var su: Node = sgv.get("_solar_ui")
	if model == null or su == null:
		return {"ok": false, "why": "no model / SolarUI"}
	var orig_ts := float(main.get("time_scale"))
	print("energy-check: as loaded  ", _line(su, main))

	# ---- 1. scrub back, switch the load on, play forward -----------------
	main.set("time_scale", 0.0)
	main.set("day_time", 11.0)
	for _f in 6:
		await tree.process_frame
	_set_loads(model, false)
	_full(su)
	await _run_for(tree, main, 0.5, 2.0)   # ~1 sim-hour with the load off
	var soc_after_off := float(su.get("battery_kwh_stored"))
	print("energy-check: load off, after an hour  ", _line(su, main))
	main.set("day_time", 11.05)            # scrub back into the cached hour
	for _f in 6:
		await tree.process_frame
	_set_loads(model, true)
	for _f in 10:
		await tree.process_frame
	var soc0 := float(su.get("battery_kwh_stored"))
	await _run_for(tree, main, 0.25, 2.0)  # ~0.5 sim-hour, still inside the cache
	var soc1 := float(su.get("battery_kwh_stored"))
	var net := float(su.get("current_solar_kw")) + float(su.get("current_graph_dc_kw")) \
		- float(su.get("current_load_kw"))
	print("energy-check: load on after scrub-back  ", _line(su, main))
	_ok(soc_after_off >= float(su.get("BATTERY_CAPACITY_KWH")) - 0.05,
		"load off: battery stays full (%.3f kWh)" % soc_after_off)
	_ok(net >= -0.01 or soc1 < soc0 - 0.05,
		"load on inside the cached hour: net %+.2f kW moves the battery %.3f -> %.3f kWh"
			% [net, soc0, soc1])

	# ---- 2. sun with the graph open -------------------------------------
	main.set("day_time", 15.0)
	sgv.call("open_graph_view")
	for _f in 10:
		await tree.process_frame
	_full(su)
	await _run_for(tree, main, 30.0 / 3600.0, 1.0)
	var sol_a := float(su.get("_raw_solar_kw"))
	await _run_for(tree, main, 1.0, 3.0)   # ~3 sim-hours, toward sunset
	var sol_b := float(su.get("_raw_solar_kw"))
	print("energy-check: graph open, after 3 h  ", _line(su, main))
	_ok(sol_a > 0.2 and sol_b < sol_a * 0.6,
		"solar follows the sun with the graph open (%.3f kW at 15 h -> %.3f kW at %.1f h)"
			% [sol_a, sol_b, fposmod(float(main.call("get_absolute_hours")), 24.0)])

	# ---- graph readouts vs SolarUI ------------------------------------------
	main.set("day_time", 12.5)
	await _run_for(tree, main, 30.0 / 3600.0, 2.0)
	var dash := ""
	for it in GraphNesting.walk_items(model):
		var d: Dictionary = it
		var sp: Dictionary = d.get("specs", {})
		var t := str(d.get("type", ""))
		if t == "controller":
			dash += " | ctrl delivered %.0f W (offered %.0f, cap %.0f)" % [
				float(sp.get("dc_delivered_w", 0.0)), float(sp.get("dc_array_w", 0.0)),
				float(sp.get("dc_cap_w", 0.0))]
		elif t == "battery":
			dash += " | bank soc %.1f%%" % (100.0 * float(sp.get("soc", 0.0)))
		elif t in ["appliance", "acload"]:
			dash += " | load %s %s" % [str(sp.get("name", d.get("id", ""))),
				str(sp.get("watts", sp.get("power_w", sp.get("rated_w", "?"))))]
		elif str(sp.get("role", "")) == "siphon_hydro":
			dash += " | %s %.0f W" % [str(sp.get("name", d.get("id", ""))),
				float(sp.get("live_power_w", 0.0))]
	print("energy-check: graph readouts%s" % dash)
	print("energy-check: SolarUI  %s  (%.1f %%)" % [_line(su, main),
		100.0 * float(su.get("battery_kwh_stored")) / float(su.get("BATTERY_CAPACITY_KWH"))])

	# ---- 3. double-click a turbine --------------------------------------
	var turbine := ""
	var best_w := -1.0
	for it in GraphNesting.walk_items(model):
		var d: Dictionary = it
		var sp: Dictionary = d.get("specs", {})
		if str(sp.get("role", "")) == "siphon_hydro" and float(sp.get("live_power_w", 0.0)) > best_w:
			best_w = float(sp.get("live_power_w", 0.0))
			turbine = str(d.get("id", ""))
	if turbine.is_empty():
		_ok(false, "a hydro turbine to double-click")
	else:
		var canvas: Node = sgv.get("_graph_canvas")
		var gdc_on := float(su.get("current_graph_dc_kw"))
		canvas.emit_signal("item_double_tapped", turbine)
		await _run_for(tree, main, 30.0 / 3600.0, 1.5)
		var sp_off: Dictionary = (model.call("get_item", turbine) as Dictionary).get("specs", {})
		var lab_open := str(sgv.get("_graph_view_mode")) == GraphSiteLayout.VIEW_SIPHON
		_ok(bool(sp_off.get(HydroSource.SPEC_OFF, false))
				and float(sp_off.get("live_power_w", 1.0)) < 1e-6
				and float(sp_off.get("current_output_kw", 1.0)) < 1e-9 and not lab_open,
			"double-click switches %s off (%.0f W -> %.0f W, Hydro Lab opened: %s)" % [
				turbine, best_w, float(sp_off.get("live_power_w", -1.0)), str(lab_open)])
		var gdc_off := float(su.get("current_graph_dc_kw"))
		_ok(gdc_off < gdc_on - best_w / 1000.0 + 0.02,
			"SolarUI's hydro term drops with it (%.3f -> %.3f kW)" % [gdc_on, gdc_off])
		canvas.emit_signal("item_double_tapped", turbine)
		await _run_for(tree, main, 30.0 / 3600.0, 1.5)
		var sp_on: Dictionary = (model.call("get_item", turbine) as Dictionary).get("specs", {})
		_ok(not bool(sp_on.get(HydroSource.SPEC_OFF, false))
				and float(sp_on.get("live_power_w", 0.0)) > 0.5 * best_w,
			"double-click again switches it back on (%.0f W)" % float(sp_on.get("live_power_w", 0.0)))
	sgv.call("close_graph_view")
	main.set("time_scale", orig_ts)
	print("energy-check: %s" % ("PASS" if _fails.is_empty() else "FAILED %d" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}
