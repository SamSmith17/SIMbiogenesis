extends RefCounted

## What the solar arrays on a world give the energy model, as numbers to diff
## (sandbox, read-only). Written for the array rework of 2026-10-27, which
## gave every hollow array its panels inside: run it on the old build and the
## new one and the "parity" lines must match. Prints, at a fixed date:
##  - per solar array compound: kind, Wmp, Voc, panel count, card size;
##  - the graph's array aggregate SolarUI reads (Wmp, Imp, count, worst string
##    Voc, plane of array);
##  - SolarUI's capacity, tilt, azimuth and its pure solar evaluator at five
##    hours of one day;
##  - each controller's PV string window (cold Voc, hot Vmp).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/solar_array_parity_probe.gd


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _f in 30:
		await tree.process_frame
	var gv: Node = main.find_child("SystemGraphView", true, false)
	var su: Node = main.find_child("SolarUI", true, false)
	if gv == null or su == null:
		return {"ok": false, "error": "no SystemGraphView / SolarUI"}
	var model: Object = gv.get("model")
	if gv.has_method("_sync_solar_ui_from_graph"):
		gv.call("_sync_solar_ui_from_graph")
	for _f2 in 5:
		await tree.process_frame
	var n_arrays := 0
	for it in model.get("items"):
		var d: Dictionary = it
		var sp: Dictionary = d.get("specs", {}) as Dictionary
		var k := str(sp.get("compound_kind", ""))
		if str(d.get("type", "")) != "compound" or not (k in ["array", "pv_design"]):
			continue
		n_arrays += 1
		var kids := 0
		for c in model.call("get_items_in_scope", str(d.get("child_scope_id", ""))):
			if str((c as Dictionary).get("type", "")) == "panel":
				kids += 1
		print("parity-array %s kind=%s name=\"%s\" units=%d equiv_wmp=%.1f equiv_voc=%.2f kids=%d inside=%s" % [
			str(d.get("id", "")), k, str(sp.get("name", "")),
			int(sp.get("array_panel_units", sp.get("panel_count", 0))), float(sp.get("array_equiv_wmp", 0.0)),
			float(sp.get("array_equiv_voc", 0.0)), kids, str(sp.get("array_interior", "-"))])
		print("probe-card %s %.0f x %.0f cells=%d" % [str(d.get("id", "")), float(d.get("width", 0.0)),
			float(d.get("height", 0.0)), ((sp.get("array_cells", {}) as Dictionary).get("cells", []) as Array).size()
				if sp.get("array_cells") is Dictionary else 0])
	var agg: Dictionary = gv.call("_collect_root_array_aggregate")
	print("parity-aggregate wmp=%.1f count=%d voc_max=%.2f orient=%s" % [float(agg.get("panel_wmp", 0.0)),
		int(agg.get("panel_count", 0)), float(agg.get("panel_voc_max", 0.0)), _orient(agg.get("orientation", {}))])
	print("probe-aggregate imp=%.2f (a display figure: the panels' Imp summed, the old aggregate's per parallel)" %
		float(agg.get("panel_imp", 0.0)))
	print("parity-solarui count=%d wattage=%.1f tilt=%.2f az=%.2f" % [int(su.get("PANEL_COUNT")),
		float(su.get("PANEL_WATTAGE")), float(su.get("panel_tilt_degrees")), float(su.get("panel_azimuth_degrees"))])
	# One fixed day (2026-06-21) at five hours, through SolarUI's pure evaluator.
	var base := SiteReportMetrics.date_to_abs_hours(2026, 6, 21, 0.0)
	for h in [7.0, 10.0, 13.0, 16.0, 19.0]:
		print("parity-solar h=%02d kw=%.4f" % [int(h), float(su.call("evaluate_solar_at", base + h))])
	for it2 in model.get("items"):
		var d2: Dictionary = it2
		if str(d2.get("type", "")) != "controller":
			continue
		var rep: Dictionary = PvElectrical.string_window_report(model, str(d2.get("id", "")),
			GraphNesting.flat_connections(model))
		if rep.is_empty():
			continue
		print("parity-window %s voc_cold=%.2f vmp_hot=%.2f ok=%s" % [str(d2.get("id", "")),
			float(rep["voc_cold"]), float(rep["vmp_hot"]), str(rep["ok"])])
	return {"ok": true, "arrays": n_arrays}


func _orient(o: Variant) -> String:
	if not (o is Dictionary) or (o as Dictionary).is_empty():
		return "-"
	return "%.2f/%.2f" % [float((o as Dictionary).get("tilt_deg", 0.0)), float((o as Dictionary).get("azimuth_deg", 0.0))]
