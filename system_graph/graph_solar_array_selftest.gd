extends SceneTree

## Offline self-test for GraphSolarArrays: every solar array on the graph is
## one card with a picture of its real layout and its real panels inside.
## Pins that giving a hollow array its panels changes no number the sim reads
## (peak watts, string Voc, panel count, orientation), the string proxies
## above the cap, the layout snapshots, the zoom-in rule, packed / stowed /
## plane propagation, legacy port ids, grouped arrays and a save round trip.
## Run --import first (GraphSolarArrays is a class_name).

const EXPECTED_CHECKS := 50

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_kinds()
	_test_materialize_parity()
	_test_proxies()
	_test_cells()
	_test_zoom_enterable()
	_test_propagate()
	_test_legacy_handles()
	_test_adopt_grouped()
	_test_round_trip()
	_test_card_size()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("GRAPH SOLAR ARRAY SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("GRAPH SOLAR ARRAY SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit()


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL ", what)


## A hollow imported array the way add_imported_solar_panels makes one, wired
## + / − to a controller at root.
func _hollow(model: GraphModel, count: int, series: int, extra: Dictionary = {}) -> String:
	var topo := SolarArrayIntelligence.best_series_parallel(count, 41.62, 480.0)
	topo["series"] = series
	topo["parallel"] = int(ceil(float(count) / float(series)))
	topo["array_topology"] = "%dS x %dP" % [series, int(topo["parallel"])]
	var eq := SolarArrayIntelligence.build_array_equiv_specs(count, 380.0, 41.62, 34.77, 10.93, 11.47, topo)
	var sp := {"name": "Array", "compound_kind": "array", "child_count": 0, "osm_import": true,
		"panel_count": count, "wmp": 380.0, "voc": 41.62, "vmp": 34.77, "isc": 11.47, "imp": 10.93,
		"cost": 300.0 * count, "panel_w_m": 1.052, "panel_h_m": 1.769, "tilt_deg": 30.0, "azimuth_deg": 170.0}
	for k in eq:
		sp[k] = eq[k]
	for k2 in extra:
		sp[k2] = extra[k2]
	var aid := model.generate_item_id()
	model.add_item({"id": aid, "type": "compound", "x": 0.0, "y": 0.0, "width": 300.0, "height": 200.0,
		"scope_id": "root", "specs": sp, "handles": GraphArrayLayout.default_handles(), "is_virtual": false})
	model.ensure_scope("scope_%s" % aid, "root", aid, "Array")
	model.update_item(aid, {"child_scope_id": "scope_%s" % aid})
	return aid


func _controller(model: GraphModel, array_id: String, pos_handle: String = "positive",
		neg_handle: String = "negative") -> String:
	var cid := model.generate_item_id()
	model.add_item({"id": cid, "type": "controller", "x": 0.0, "y": 400.0, "width": 160.0, "height": 120.0,
		"scope_id": "root", "specs": {"name": "EG4", "max_voc": 480.0}, "is_virtual": false})
	GraphPvWiring.add_pv_connection(model, "positive", array_id, pos_handle, cid, "pvPositive", "root")
	GraphPvWiring.add_pv_connection(model, "negative", array_id, neg_handle, cid, "pvNegative", "root")
	return cid


func _panels(model: GraphModel, aid: String) -> Array:
	var out: Array = []
	for it in model.get_items_in_scope(str(model.get_item(aid).get("child_scope_id", ""))):
		if str((it as Dictionary).get("type", "")) == "panel":
			out.append(it)
	return out


func _test_kinds() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 18, 9)
	var it := model.get_item(aid)
	_ok(GraphSolarArrays.is_solar_array(it) and GraphSolarArrays.is_aggregate_array(it)
		and not GraphNesting.is_transparent_compound(it), "a hollow array is an aggregate, opaque")
	_ok(GraphSolarArrays.is_solar_array({"type": "compound", "specs": {"compound_kind": "pv_design"}})
		and GraphSolarArrays.is_materialized({"type": "compound", "specs": {"compound_kind": "pv_design"}}),
		"a designed array is a solar array with its panels inside")
	_ok(not GraphSolarArrays.is_solar_array({"type": "compound", "specs": {"compound_kind": "battery_bank"}})
		and not GraphSolarArrays.is_solar_array({"type": "panel", "specs": {}}), "banks and panels are not arrays")
	_ok(GraphArrayLayout.default_handles()[0]["id"] == "positive"
		and float(GraphArrayLayout.default_handles()[0]["rx"]) < 0.5, "+ sits on the left of the bus")


## 9S × 2P → 18 panels in two strings; nothing the sim reads moves.
func _test_materialize_parity() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 18, 9)
	var ctrl := _controller(model, aid)
	var sp0: Dictionary = model.get_item(aid)["specs"]
	var flat0 := GraphNesting.flat_connections(model)
	var voc0 := PvElectrical.max_string_voc_for_controller_flat(model, ctrl, flat0, 25.0)
	var wmp0 := float(sp0["array_equiv_wmp"])
	_ok(GraphSolarArrays.materialize(model, aid), "materialize changed the hollow array")
	var it := model.get_item(aid)
	var panels := _panels(model, aid)
	_ok(panels.size() == 18, "18 panels inside (%d)" % panels.size())
	_ok(GraphNesting.is_transparent_compound(it) and not GraphSolarArrays.is_aggregate_array(it),
		"the array is transparent now")
	var strings := {}
	var wmp := 0.0
	for p in panels:
		var ps: Dictionary = (p as Dictionary)["specs"]
		strings[int(ps.get("array_string", -1))] = true
		wmp += float(ps.get("wmp", 0.0))
	_ok(strings.size() == 2, "two strings (%d)" % strings.size())
	_ok(absf(wmp - wmp0) < 0.01, "peak watts unchanged (%.1f vs %.1f)" % [wmp, wmp0])
	var flat := GraphNesting.flat_connections(model)
	var voc := PvElectrical.max_string_voc_for_controller_flat(model, ctrl, flat, 25.0)
	_ok(absf(voc - voc0) < 0.01 and absf(voc - 9.0 * 41.62) < 0.01,
		"string Voc unchanged (%.2f vs %.2f)" % [voc, voc0])
	var src := PvElectrical.pv_sources_for_controller_flat(model, ctrl, flat)
	_ok(src.size() == 18, "the controller sees 18 panels (%d)" % src.size())
	var pos := GraphNesting.resolve_port(model, aid, "positive")
	var neg := GraphNesting.resolve_port(model, aid, "negative")
	_ok(str(pos["item_id"]) != aid and str(pos["handle_id"]) == "positive"
		and str(neg["handle_id"]) == "negative" and str(pos["item_id"]) != str(neg["item_id"]),
		"the + and − ports lead out of the string ends")
	_ok(int(it["specs"].get("child_count", 0)) == 18 and str(it["specs"].get("array_interior", "")) == "panels"
		and bool(it["specs"].get("array_generated", false)), "specs mark the inside")
	_ok(not GraphSolarArrays.materialize(model, aid), "materialize again changes nothing")
	_ok(not PvElectrical.is_pv_source_item(it), "the compound itself is no longer a PV source")
	# The inside is the picture, enlarged: same aspect.
	var cells: Dictionary = it["specs"]["array_cells"]
	var bb := Rect2()
	var first := true
	for p2 in panels:
		var r := Rect2(float(p2["x"]), float(p2["y"]), float(p2["width"]), float(p2["height"]))
		bb = r if first else bb.merge(r)
		first = false
	var a_cells := float(cells["w_m"]) / float(cells["h_m"])
	var a_in := (bb.size.x + GraphSolarArrays.NODE_GAP) / (bb.size.y + GraphSolarArrays.NODE_GAP)
	_ok(absf(a_cells - a_in) / a_cells < 0.03, "inside has the picture's aspect (%.3f vs %.3f)" % [a_in, a_cells])
	var summary := GraphSolarArrays.live_summary(model, it)
	_ok(int(summary["count"]) == 18 and absf(float(summary["peak_w"]) - wmp0) < 0.01, "live summary counts the panels")
	# A count that does not divide: the last string is short, watts still exact.
	var m2 := GraphModel.new()
	var a2 := _hollow(m2, 7, 3)
	GraphSolarArrays.materialize(m2, a2)
	var lens: Array = []
	var by_s := {}
	for p3 in _panels(m2, a2):
		var si := int((p3 as Dictionary)["specs"].get("array_string", -1))
		by_s[si] = int(by_s.get(si, 0)) + 1
	for k in by_s:
		lens.append(by_s[k])
	lens.sort()
	_ok(lens == [1, 3, 3], "7 panels at 3S make strings of 3, 3, 1 (%s)" % [lens])


func _test_proxies() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 300, 10)
	var ctrl := _controller(model, aid)
	GraphSolarArrays.materialize(model, aid)
	var panels := _panels(model, aid)
	var count := 0
	var wmp := 0.0
	var all_proxy := true
	for p in panels:
		var ps: Dictionary = (p as Dictionary)["specs"]
		count += int(ps.get("panel_count", 1))
		wmp += float(ps.get("wmp", 0.0))
		all_proxy = all_proxy and bool(ps.get("string_proxy", false))
	_ok(panels.size() == 30 and all_proxy, "300 panels → 30 string proxies (%d)" % panels.size())
	_ok(count == 300 and absf(wmp - 300.0 * 380.0) < 0.5, "proxies keep the count and watts (%d, %.0f)" % [count, wmp])
	var flat := GraphNesting.flat_connections(model)
	_ok(absf(PvElectrical.max_string_voc_for_controller_flat(model, ctrl, flat, 25.0) - 10.0 * 41.62) < 0.01,
		"a proxy carries its string's Voc")
	_ok(str(model.get_item(aid)["specs"].get("array_interior", "")) == "strings", "marked as strings inside")
	_ok((model.get_item(aid)["specs"]["array_cells"]["cells"] as Array).size() == 300,
		"the picture still has every panel")


func _test_cells() -> void:
	var g := GraphSolarArrays.cells_grid(6, 2, 12, 1.0, 1.7, 0.02, 0.4, 6)
	_ok((g["cells"] as Array).size() == 12 and absf(float(g["w_m"]) - (6.0 + 5.0 * 0.02)) < 0.01
		and absf(float(g["h_m"]) - (3.4 + 0.4)) < 0.01, "a 6 × 2 grid measures its modules and gaps")
	var row0 := (g["cells"] as Array)[0] as Array
	_ok(float(row0[1]) > 1.0, "row 0 (the front row) is drawn at the bottom")
	_ok(int(((g["cells"] as Array)[7] as Array)[5]) == 1, "cell 7 is in string 2")
	var sp := {"array_panel_units": 9, "array_series": 9, "array_cols": 3, "array_rows": 3,
		"panel_w_m": 1.0, "panel_h_m": 1.7}
	var c := GraphSolarArrays.cells_for_specs(sp)
	_ok(float(c["w_m"]) < float(c["h_m"]) * 1.2, "a placed rack of 3 × 3 draws 3 across (%.2f × %.2f)" % [c["w_m"], c["h_m"]])
	var c2 := GraphSolarArrays.cells_for_specs({"array_panel_units": 18, "array_series": 9, "array_parallel": 2})
	_ok(float(c2["w_m"]) > float(c2["h_m"]) * 2.0, "an unplaced 9S × 2P draws two rows of nine")
	# A designed array: modules where they sit on the rack.
	var spec: Dictionary = (PvLabPresets.builtins()[0] as Dictionary)["spec"]
	var d := PvLabDesign.solve(spec)
	var pre := PvLabDesign.graph_preset(d)
	var grp: Dictionary = (pre["groups"] as Array)[0]
	var dc := GraphSolarArrays.cells_for_design(d, grp["strings"] as Array)
	_ok((dc["cells"] as Array).size() == int(grp["count"]), "a designed MPPT input draws each of its modules")
	_ok(float(dc["w_m"]) > float(dc["h_m"]), "the backyard rack (6 across, 2 up) is wider than tall")
	var fit := GraphSolarArrays.fit_cells(dc, Rect2(0, 0, 200, 100))
	var grid: Rect2 = fit["grid"]
	_ok(grid.size.x <= 200.5 and grid.size.y <= 100.5 and (absf(grid.size.x - 200.0) < 0.5 or absf(grid.size.y - 100.0) < 0.5),
		"the picture fits its zone with its aspect kept")


func _test_zoom_enterable() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 4, 4)
	_ok(not GraphSolarArrays.zoom_enterable(model, model.get_item(aid)), "a hollow array does not open on zoom")
	GraphSolarArrays.materialize(model, aid)
	_ok(GraphSolarArrays.zoom_enterable(model, model.get_item(aid)), "an array with panels inside opens on zoom")
	var gid := model.generate_item_id()
	model.add_item({"id": gid, "type": "compound", "scope_id": "root", "child_scope_id": "scope_g",
		"specs": {"compound_kind": ""}})
	_ok(GraphSolarArrays.zoom_enterable(model, model.get_item(gid)), "a generic group opens on zoom")
	var bid := model.generate_item_id()
	model.add_item({"id": bid, "type": "compound", "scope_id": "root", "child_scope_id": "scope_b",
		"specs": {"compound_kind": "battery_bank"}})
	_ok(not GraphSolarArrays.zoom_enterable(model, model.get_item(bid)), "a battery bank does not")


func _test_propagate() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 4, 4)
	GraphSolarArrays.materialize(model, aid)
	var sp: Dictionary = (model.get_item(aid)["specs"] as Dictionary).duplicate(true)
	sp["packed_3d"] = true
	sp["azimuth_deg"] = 200.0
	model.update_item(aid, {"specs": sp})
	GraphSolarArrays.propagate_state(model, aid)
	var all_packed := true
	var all_turned := true
	for p in _panels(model, aid):
		all_packed = all_packed and bool((p as Dictionary)["specs"].get("packed_3d", false))
		all_turned = all_turned and is_equal_approx(float((p as Dictionary)["specs"].get("azimuth_deg", 0.0)), 200.0)
	_ok(all_packed, "a packed array's panels are packed")
	_ok(all_turned, "a turned rack turns its panels")
	_ok(GraphSolarArrays.panel_off((_panels(model, aid)[0] as Dictionary)["specs"]), "a packed panel makes nothing")
	sp.erase("packed_3d")
	sp["array_stowed"] = true
	model.update_item(aid, {"specs": sp})
	GraphSolarArrays.propagate_state(model, aid)
	var p0: Dictionary = (_panels(model, aid)[0] as Dictionary)["specs"]
	_ok(not bool(p0.get("packed_3d", false)) and bool(p0.get("array_stowed", false)), "unpacked, then stowed")


func _test_legacy_handles() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 4, 4)
	var ctrl := _controller(model, aid, "pv_positive_1", "pv_negative_1")
	GraphSolarArrays.materialize(model, aid)
	var handles := []
	for c in model.connections_for_item(aid):
		var cd: Dictionary = c
		handles.append(str(cd["source_handle_id"]) if str(cd["source_item_id"]) == aid else str(cd["target_handle_id"]))
	handles.sort()
	_ok(handles == ["negative", "positive"], "legacy port ids become the bus pair (%s)" % [handles])
	var src := PvElectrical.pv_sources_for_controller_flat(model, ctrl, GraphNesting.flat_connections(model))
	_ok(src.size() == 4, "and still reach every panel (%d)" % src.size())


## Make array over two panels each wired to the controller on its own: one
## + and one − leave the compound; inside they are joined in parallel.
func _test_adopt_grouped() -> void:
	var model := GraphModel.new()
	var aid := model.generate_item_id()
	model.add_item({"id": aid, "type": "compound", "x": 0.0, "y": 0.0, "width": 300.0, "height": 200.0,
		"scope_id": "root", "child_scope_id": "scope_%s" % aid,
		"specs": {"compound_kind": "array", "array_panel_units": 2}, "is_virtual": false})
	model.ensure_scope("scope_%s" % aid, "root", aid, "Array")
	var ids: Array = []
	for i in 2:
		var pid := model.generate_item_id()
		model.add_item({"id": pid, "type": "panel", "x": float(i) * 240.0, "y": 0.0, "width": 210.0,
			"height": 128.0, "scope_id": "scope_%s" % aid, "specs": {"wmp": 380.0, "voc": 41.62}})
		ids.append(pid)
	var ctrl := model.generate_item_id()
	model.add_item({"id": ctrl, "type": "controller", "scope_id": "root", "specs": {"max_voc": 150.0}})
	var eps: Array = []
	for pid2 in ids:
		eps.append({"handle_id": "positive", "child_item_id": pid2, "child_handle_id": "positive", "direction": "out"})
		eps.append({"handle_id": "negative", "child_item_id": pid2, "child_handle_id": "negative", "direction": "out"})
		GraphPvWiring.add_pv_connection(model, "positive", aid, "positive", ctrl, "pvPositive", "root")
		GraphPvWiring.add_pv_connection(model, "negative", aid, "negative", ctrl, "pvNegative", "root")
	var sp: Dictionary = (model.get_item(aid)["specs"] as Dictionary).duplicate(true)
	sp["exposed_ports"] = eps
	model.update_item(aid, {"specs": sp})
	GraphSolarArrays.materialize(model, aid)
	var it := model.get_item(aid)
	_ok((it["specs"]["exposed_ports"] as Array).size() == 2, "one + and one − leave the grouped array")
	_ok(model.connections_for_item(aid).size() == 2, "duplicate outside wires collapse to two")
	var src := PvElectrical.pv_sources_for_controller_flat(model, ctrl, GraphNesting.flat_connections(model))
	_ok(src.size() == 2, "both panels still reach the controller (%d)" % src.size())
	_ok((it["specs"]["array_cells"]["cells"] as Array).size() == 2, "the grouped array's picture has both panels")


func _test_round_trip() -> void:
	var model := GraphModel.new()
	var aid := _hollow(model, 18, 9)
	_controller(model, aid)
	GraphSolarArrays.materialize(model, aid)
	var m2 := GraphModel.new()
	m2.deserialize(model.serialize())
	var it := m2.get_item(aid)
	_ok(GraphNesting.is_transparent_compound(it) and _panels(m2, aid).size() == 18,
		"a saved materialized array loads with its panels")
	_ok((it["specs"]["array_cells"]["cells"] as Array).size() == 18, "and its picture")


func _test_card_size() -> void:
	var c := GraphSolarArrays.cells_for_specs({"array_panel_units": 18, "array_series": 9, "array_parallel": 2})
	var sz := GraphSolarArrays.card_size(c)
	_ok(sz.x >= GraphSolarArrays.CARD_MEDIA_MIN_W and sz.x <= GraphSolarArrays.CARD_MEDIA_MAX_W + 20.0,
		"card width in range (%.0f)" % sz.x)
	var media_h := sz.y - GraphSolarArrays.CARD_HEAD_H - GraphSolarArrays.CARD_FOOT_H \
		- GraphSolarArrays.CARD_HERO_H - GraphSolarArrays.CARD_MEDIA_GAP * 2.0
	var media_w := sz.x - GraphSolarArrays.CARD_PAD * 2.0
	_ok(absf(media_w / media_h - float(c["w_m"]) / float(c["h_m"])) < 0.15,
		"the card's picture zone has the layout's aspect")
	var sz_old := GraphArrayLayout.legacy_compound_size({"array_series": 9, "array_parallel": 2,
		"array_panel_units": 18})
	_ok(sz.x < sz_old.x * 0.5, "smaller than the old panel-sized tiles (%.0f vs %.0f)" % [sz.x, sz_old.x])
