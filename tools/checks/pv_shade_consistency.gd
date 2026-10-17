extends RefCounted

## Free-play shade check for `--run-script` (sandbox only; it edits the graph).
##
## Places four 380 W panels in series on the world's controller — one where a
## ray toward the sun hits something (a tree, a building), three in the sun —
## and takes the existing PV off the controller so the cards are the whole
## array. Then, over several of SolarUI's ticks with the graph open, asserts the
## one-shade-model contract: the panel cards sum to the controller's delivered
## watts and to SolarUI's current_solar_kw ("Making"), the shaded panel reads
## about a fifth of a sunlit one, and SolarUI's output is the unshaded array
## times the Wmp-weighted shade factor.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/pv_shade_consistency.gd

const PANEL_SPECS := {"name": "JA Solar JAM60S20 380W", "wmp": 380.0, "voc": 41.62,
	"vmp": 34.77, "isc": 11.47, "imp": 10.93, "sunlight_factor": 1.0}


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv: Node = ServiceLocator.graph()
	if sgv == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var model: Object = sgv.get("model")
	var su: Node = sgv.get("_solar_ui")
	if model == null or su == null:
		return {"ok": false, "why": "no model / SolarUI"}
	# Early afternoon, clock held, so the sun is up and still.
	main.set("time_scale", 0.0)
	main.set("day_time", 13.0)
	for _i in 10:
		await tree.process_frame

	var ctrl_id := ""
	for it in model.call("items_of_type", "controller"):
		ctrl_id = str((it as Dictionary).get("id", ""))
		break
	if ctrl_id.is_empty():
		return {"ok": false, "why": "no controller in this world"}
	# The existing PV comes off the controller AND out of the graph, so the
	# four test panels are the whole array (an unrouted array would make power
	# no panel card shows).
	var removed: Array = []
	for it in (model.get("items") as Array).duplicate():
		var d: Dictionary = it
		if PvElectrical.is_pv_source_item(d):
			removed.append(str(d.get("id", "")))
			model.call("remove_item", str(d.get("id", "")))

	# Find a shaded spot and a clear row near the site centre.
	var sun_dir: Vector3 = (main.get("clock") as Object).call("get_sun_direction")
	var space := (main as Node3D).get_world_3d().direct_space_state
	var center := Vector3.ZERO
	var soi := tree.root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		center = soi.call("world_center") as Vector3
	var shaded := Vector2.INF
	var clear: Array = []
	for r in range(4, 90, 3):
		for k in 24:
			var a := TAU * float(k) / 24.0
			var p := Vector2(cos(a), sin(a)) * float(r)
			var f := GraphSolarShading.shade_factor_for_item(
				{"site_x_m": p.x, "site_z_m": p.y}, main, center, sun_dir, space)
			if f < 0.5 and shaded == Vector2.INF:
				shaded = p
			elif f >= 0.999 and clear.size() < 3:
				clear.append(p)
		if shaded != Vector2.INF and clear.size() >= 3:
			break
	if shaded == Vector2.INF or clear.size() < 3:
		return {"ok": false, "why": "no shaded / clear spots found (sun %s)" % sun_dir}

	var spots: Array = [shaded] + clear
	var ids: Array = []
	for i in 4:
		var sp: Vector2 = spots[i]
		var pid := "shade_chk_%d" % i
		ids.append(pid)
		model.call("add_item", {
			"id": pid, "type": "panel", "x": 100.0 + 140.0 * i, "y": -200.0,
			"width": 120.0, "height": 100.0,
			"site_x_m": sp.x, "site_z_m": sp.y,
			"handles": [
				{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
				{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0}],
			"specs": PANEL_SPECS.duplicate(),
		})
	# 4S: panel i − → panel i+1 +, ends on the controller's PV terminals.
	# `polarity` is the source terminal's, as the canvas stamps it — the PV
	# walk ignores a wire without one.
	model.call("add_connection", {"source_item_id": ids[0], "source_handle_id": "positive",
		"target_item_id": ctrl_id, "target_handle_id": "pvPositive", "polarity": "positive"})
	for i in 3:
		model.call("add_connection", {"source_item_id": ids[i], "source_handle_id": "negative",
			"target_item_id": ids[i + 1], "target_handle_id": "positive", "polarity": "negative"})
	model.call("add_connection", {"source_item_id": ids[3], "source_handle_id": "negative",
		"target_item_id": ctrl_id, "target_handle_id": "pvNegative", "polarity": "negative"})

	sgv.call("open_graph_view")
	# Shade tick (12 rays / 0.25 s), the graph → SolarUI sync, a few SolarUI ticks.
	for _i in 150:
		await tree.process_frame
	await tree.create_timer(2.0).timeout

	# Why the throttle pass does (not) treat the controller as a PV route.
	var fc := GraphNesting.flat_connections(model)
	var an := GraphDcElectrical.analyze(model, fc)
	var cspec: Dictionary = (model.call("get_item", ctrl_id) as Dictionary).get("specs", {})
	print("pvshade route: sources %s | bank %s | pv reversed %s | destroyed %s | live_w %s" % [
		PvElectrical.pv_sources_for_controller_flat(model, ctrl_id, fc),
		not GraphDcElectrical.bank_for_controller(model, ctrl_id, fc, an).is_empty(),
		GraphDcElectrical.controller_pv_reversed(model, ctrl_id, fc),
		bool(cspec.get("destroyed", false)), (sgv.get("_pv_live_w") as Dictionary).keys()])

	var fails: PackedStringArray = PackedStringArray()
	var last := {}
	for sample in 6:
		await tree.create_timer(0.35).timeout
		var panels: Array = []
		var panels_w := 0.0
		var factors: Array = []
		for pid in ids:
			var sp2: Dictionary = (model.call("get_item", pid) as Dictionary).get("specs", {})
			var w := float(sp2.get("current_output_kw", 0.0)) * 1000.0
			panels.append(w)
			panels_w += w
			factors.append(float(sp2.get("sunlight_factor", 1.0)))
		var cs: Dictionary = (model.call("get_item", ctrl_id) as Dictionary).get("specs", {})
		var delivered := float(cs.get("dc_delivered_w", 0.0))
		var making := float(su.get("current_solar_kw")) * 1000.0
		var raw := float(su.get("_raw_solar_kw")) * 1000.0
		var shade_f := float(su.call("graph_pv_shade_factor"))
		var want_f := 0.0
		for f in factors:
			want_f += float(f) / 4.0
		var tol := maxf(2.0, 0.02 * making)
		last = {"panels_w": panels, "sum_w": panels_w, "controller_w": delivered,
			"making_w": making, "raw_w": raw, "shade_factor": shade_f, "factors": factors,
			"shaded_xz": [shaded.x, shaded.y], "removed": removed}
		print("pvshade sample %d: panels %s = %.1f W | controller %.1f W | making %.1f W | raw %.1f W | array shade %.3f (factors %s)" % [
			sample, panels, panels_w, delivered, making, raw, shade_f, factors])
		if absf(panels_w - making) > tol:
			fails.append("s%d panels %.1f vs making %.1f" % [sample, panels_w, making])
		if absf(delivered - making) > tol:
			fails.append("s%d controller %.1f vs making %.1f" % [sample, delivered, making])
		if absf(shade_f - want_f) > 0.01:
			fails.append("s%d SolarUI shade %.3f vs Wmp-weighted %.3f" % [sample, shade_f, want_f])
		if float(factors[0]) > 0.5:
			fails.append("s%d the shaded panel was not stamped shaded (%.2f)" % [sample, float(factors[0])])
		var sunny := (float(panels[1]) + float(panels[2]) + float(panels[3])) / 3.0
		if sunny > 5.0 and absf(float(panels[0]) / sunny - float(factors[0])) > 0.05:
			fails.append("s%d shaded card %.1f W is not %.2f of a sunlit one (%.1f W)" % [
				sample, float(panels[0]), float(factors[0]), sunny])
		if making < 5.0:
			fails.append("s%d no sun (making %.1f W) — pick another hour" % [sample, making])
	# The batch render (challenge bake) casts its own shadows per instant: at
	# this hour its shaded/unshaded ratio must be the live array factor.
	var abs_h := float(main.call("get_absolute_hours"))
	var bake_shaded := float(su.call("evaluate_potential_solar_at", abs_h))
	var keep_rec: Array = (su.get("_pv_shade_receivers") as Array).duplicate(true)
	var keep_tot := float(su.get("_pv_shade_total_wmp"))
	su.call("set_graph_pv_shade", [], 0.0)
	var bake_clear := float(su.call("evaluate_potential_solar_at", abs_h))
	su.call("set_graph_pv_shade", keep_rec, keep_tot)
	var bake_ratio := bake_shaded / bake_clear if bake_clear > 1e-6 else 1.0
	print("pvshade bake: %.1f W shaded / %.1f W clear = %.3f (live %.3f)" % [
		bake_shaded * 1000.0, bake_clear * 1000.0, bake_ratio, float(su.call("graph_pv_shade_factor"))])
	last["bake_ratio"] = bake_ratio
	if bake_clear > 0.005 and absf(bake_ratio - float(su.call("graph_pv_shade_factor"))) > 0.02:
		fails.append("bake shade %.3f vs live %.3f" % [bake_ratio, float(su.call("graph_pv_shade_factor"))])
	sgv.call("close_graph_view")
	var ok := fails.is_empty()
	print("pvshade %s%s" % ["PASS" if ok else "FAIL", "" if ok else " — " + "; ".join(fails)])
	last["ok"] = ok
	last["fails"] = fails
	return last
