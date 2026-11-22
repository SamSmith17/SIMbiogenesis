extends SceneTree

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

## Controller Lab self-test (offline). Every built-in solves with no error,
## every port sits on its face and no two overlap, every library controller
## has a design whose graph numbers are exactly the library's, the roles a
## kind needs are all there, handles follow the roles (a 2-MPPT hybrid gets
## pvPositive2, a hybrid with grid and generator inputs acInput / genInput,
## comms ports "data"), the spec survives a JSON round trip, and the builder
## draws every design with every triangle wound to its normal, the wiring
## bay cover toggles, and a ray picks a port.
##
##   Godot --headless --path . --script core/ctrllab/ctrllab_selftest.gd

const EXPECTED_CHECKS := 33

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _initialize() -> void:
	print("ctrllab selftest")
	_test_presets()
	_test_library_parity()
	_test_roles_and_handles()
	_test_spec()
	_test_builder()
	_test_sheet()
	_test_graph()
	_test_chain()
	_ok(_n == EXPECTED_CHECKS, "ran %d checks (expected %d)" % [_n, EXPECTED_CHECKS])
	print("ctrllab selftest: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_presets() -> void:
	var all := CtrlPresets.builtins()
	var ids := {}
	for s in all:
		ids[s["id"]] = true
	_ok(all.size() >= 28 and ids.size() == all.size(), "%d built-ins, unique ids" % all.size())
	var errs: Array = []
	var off: Array = []
	var over: Array = []
	for s in all:
		var d := CtrlDesign.solve(s)
		for c in (d["checks"] as Array):
			var t := str(c["text"])
			if str(c["level"]) == "error":
				errs.append("%s: %s" % [s["id"], t])
			elif t.contains("runs off"):
				off.append("%s: %s" % [s["id"], t])
			elif t.contains("overlap"):
				over.append("%s: %s" % [s["id"], t])
	_ok(errs.is_empty(), "every built-in solves with no error %s" % str(errs))
	_ok(off.is_empty(), "every port sits on its face %s" % str(off))
	_ok(over.is_empty(), "no two ports overlap %s" % str(over))
	var kinds := {}
	var forms := {}
	for s in all:
		kinds[s["elec"]["kind"]] = true
		forms[s["form"]] = true
	_ok(kinds.size() >= 6 and forms.size() >= 6, "the built-ins cover %d kinds and %d forms" % [kinds.size(), forms.size()])
	var found := CtrlPresets.search("victron mppt")
	_ok(found.size() >= 4 and CtrlPresets.search("eg4 6000xp") == ["eg4_6000xp"], "search finds the Victron MPPTs and the 6000XP")


func _test_library_parity() -> void:
	var bad: Array = []
	var missing: Array = []
	for lp in ComponentPresets.CONTROLLERS:
		var label := str(lp["label"])
		var s := CtrlPresets.for_library_label(label)
		if s.is_empty():
			missing.append(label)
			continue
		var g: Dictionary = CtrlDesign.solve(s)["graph_specs"]
		var want: Dictionary = lp["specs"]
		for k in want:
			var a: Variant = want[k]
			var b: Variant = g.get(k, null)
			if b == null or (a is float or a is int) and absf(float(a) - float(b)) > 1e-6 or (a is String and str(a) != str(b)):
				bad.append("%s.%s: %s ≠ %s" % [label, k, str(a), str(b)])
	_ok(missing.is_empty(), "every library controller has a design %s" % str(missing))
	_ok(bad.is_empty(), "every library controller's graph numbers are the library's %s" % str(bad))


func _test_roles_and_handles() -> void:
	_ok(CtrlRoles.handle_for("pv1+") == "pvPositive" and CtrlRoles.handle_for("pv2-") == "pvNegative2"
		and CtrlRoles.handle_for("bat-") == "batteryNegative" and CtrlRoles.handle_for("ac_out_N") == "acOutput"
		and CtrlRoles.handle_for("gen_L1") == "genInput" and CtrlRoles.handle_for("rs485") == "data",
		"roles map to graph handles (pv1 keeps pvPositive)")
	var eg := CtrlDesign.solve(CtrlPresets.builtin("eg4_6000xp"))
	var hs: Array = eg["handles"]
	_ok(hs.has("pvPositive") and hs.has("pvPositive2") and hs.has("batteryPositive") and hs.has("acOutput")
		and hs.has("acInput") and hs.has("genInput") and hs.has("data"), "the 6000XP has every handle a hybrid needs %s" % str(hs))
	var vic := CtrlDesign.solve(CtrlPresets.builtin("victron_ss_100_30"))
	var r: Dictionary = vic["roles"]
	_ok(r.has("bat+") and r.has("bat-") and r.has("pv1+") and r.has("pv1-") and not r.has("ac_out_L"),
		"the SmartSolar's four terminals are BAT + − and PV − +")
	# A unit with a missing role says so.
	var s := CtrlPresets.builtin("victron_ss_100_30")
	s["ports"] = (s["ports"] as Array).filter(func(p): return str(p["id"]) != "terms")
	var errs := (CtrlDesign.solve(s)["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
	_ok(not errs.is_empty() and str(errs[0]["text"]).contains("Battery +"), "a controller with no battery terminals is an error")


func _test_spec() -> void:
	var s := CtrlPresets.builtin("growatt_spf_5000es")
	var back: Variant = JSON.parse_string(JSON.stringify(s))
	_ok(back is Dictionary and CtrlSpec.key_of(back) == CtrlSpec.key_of(s), "a design survives a JSON round trip (same key)")
	# Too-small current rating: an MC4 on a 40 A input.
	var t := CtrlPresets.builtin("growatt_spf_5000es")
	t["elec"]["max_input_a"] = 40.0
	var errs := (CtrlDesign.solve(t)["checks"] as Array).filter(func(c): return str(c["text"]).contains("rated 30 A"))
	_ok(not errs.is_empty(), "an MC4 on a 40 A PV input is flagged (rated 30 A)")


func _test_builder() -> void:
	var wound: Array = []
	var empty: Array = []
	for s in CtrlPresets.builtins():
		var b := CtrlBuilder.build_node(s)
		for nn in ["Mesh", "Ports", "BayCover"]:
			var mi := b.get_node_or_null(nn) as MeshInstance3D
			if mi == null:
				if nn == "Mesh":
					empty.append(s["id"])
				continue
			var am := mi.mesh as ArrayMesh
			for si in am.get_surface_count():
				var arr := am.surface_get_arrays(si)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				for i in range(0, v.size(), 3):
					if (v[i + 1] - v[i]).cross(v[i + 2] - v[i]).dot(n[i] + n[i + 1] + n[i + 2]) > 1e-12:
						wound.append("%s/%s" % [s["id"], nn])
						break
		b.free()
	_ok(empty.is_empty(), "every built-in draws a body %s" % str(empty))
	_ok(wound.is_empty(), "every triangle is clockwise from its normal's side %s" % str(wound))
	var eg := CtrlBuilder.build_node(CtrlPresets.builtin("eg4_6000xp"))
	var cover_on := eg.cover_visible()
	eg.set_cover_visible(false)
	_ok(cover_on and not eg.cover_visible() and eg.get_node_or_null("Window") != null,
		"the 6000XP's bay cover (with its window) shows, then hides")
	# A ray straight at the battery stud through the open bay picks it.
	var p: Dictionary = {}
	for q in (eg.design["ports"] as Array):
		if str(q["id"]) == "bat_p":
			p = q
	var at := ((p["xf"] as Transform3D).origin) * CtrlBuilder.MM
	var hit := eg.pick(at + Vector3(0, 0, 1.0), Vector3(0, 0, -1))
	_ok(hit == "bat_p", "a ray through the open bay picks BAT + (got %s)" % hit)
	eg.free()


func _test_sheet() -> void:
	_ok(CtrlSheet.short("pv2+") == "PV2 +" and CtrlSheet.short("bat-") == "BAT −" and CtrlSheet.short("ac_out_N") == "AC OUT N"
		and CtrlSheet.wire_color("ac_in_L1") == CtrlSheet.C_BLACK and CtrlSheet.wire_color("gen_L2") == CtrlSheet.C_RED
		and CtrlSheet.wire_color("ac_out_N") == CtrlSheet.C_WHITE and CtrlSheet.wire_color("ground") == CtrlSheet.C_GREEN
		and CtrlSheet.wire_color("bat+") == CtrlSheet.C_RED and CtrlSheet.wire_color("rs485") == CtrlSheet.C_TEAL,
		"terminal words and conductor colours (L1 black, L2 red, N white, PE green, DC + red, data teal)")
	var d := CtrlDesign.solve(CtrlPresets.builtin("eg4_6000xp"))
	var l := CtrlSheet.layout(d, "front")
	var ids := {}
	var outside: Array = []
	var r: Rect2 = l["rect"]
	var role_pins := 0
	for p in (l["ports"] as Array):
		ids[p["id"]] = true
		for pin in (p["pins"] as Array):
			if not r.grow(1.0).has_point(pin["pos"]):
				outside.append("%s.%s" % [p["id"], pin["id"]])
			if str(pin["role"]) != "" and CtrlRoles.group_of(str(pin["role"])) != "ui":
				role_pins += 1
	var leads: Array = l["leads"]
	var ends: Array = leads.map(func(x): return (x["end"] as Vector2).x)
	ends.sort()
	var gap_ok := true
	for i in range(1, ends.size()):
		if float(ends[i]) - float(ends[i - 1]) < float(l["text_mm"]) * 1.4:
			gap_ok = false
	var below := leads.all(func(x): return (x["end"] as Vector2).y < r.position.y)
	_ok(ids.has("bat_p") and bool(l["has_bay"]) and outside.is_empty() and leads.size() == role_pins and gap_ok and below,
		"the 6000XP's front sheet holds its bay, every pin on the face, a lead per wired pin fanned a label apart below it (%d leads) %s" % [leads.size(), str(outside)])
	var svg := CtrlSheet.svg(d)
	var xp := XMLParser.new()
	var err := xp.open_buffer(svg.to_utf8_buffer())
	var nodes := 0
	while err == OK:
		err = xp.read()
		nodes += 1
	_ok(err == ERR_FILE_EOF and nodes > 100 and svg.contains("BAT +") and svg.contains("PV1 +") and svg.contains("GRID L1")
		and svg.contains("face_bottom"), "the wiring sheet is well-formed SVG with every face and its terminals (%d nodes)" % nodes)


func _test_graph() -> void:
	var d := CtrlDesign.solve(CtrlPresets.builtin("eg4_6000xp"))
	var hs := CtrlDesign.graph_handles(d)
	var by := {}
	for h in hs:
		by[str(h["id"])] = h
	var legacy_ok := true
	for l in CtrlDesign.LEGACY_HANDLES:
		legacy_ok = legacy_ok and by.has(str(l["id"]))
	_ok(legacy_ok and by.has("pvPositive2") and by.has("acInput") and by.has("genInput") and by.has("data")
		and float(by["pvPositive2"]["ry"]) == 0.0 and float(by["acInput"]["ry"]) == 0.0 and float(by["data"]["ry"]) == 1.0
		and str(by["acInput"]["polarity"]) == "ac" and str(by["pvNegative2"]["polarity"]) == "negative" and str(by["data"]["polarity"]) == "data",
		"the 6000XP's graph handles: every plain one kept, PV 2, AC in and generator in on top, data below")
	var ports := CtrlDesign.connection_ports(d)
	var bat: Dictionary = {}
	for p in ports:
		if str(p["handle_id"]) == "batteryPositive":
			bat = p
	var stud := Vector3.ZERO
	var nrm := Vector3.ZERO
	for q in (d["ports"] as Array):
		if str(q["id"]) == "bat_p":
			stud = ((q["pins"] as Array)[0]["pos"] as Vector3) * CtrlBuilder.MM
			nrm = (q["xf"] as Transform3D).basis.z
	var at := Vector3(float(bat.get("x", 0)), float(bat.get("y", 0)), float(bat.get("z", 0)))
	_ok(not bat.is_empty() and at.distance_to(stud) < 0.01 and Vector3(float(bat["nx"]), float(bat["ny"]), float(bat["nz"])).dot(nrm) > 0.99
		and ports.size() == (d["handles"] as Array).size(),
		"one 3D port per handle; the battery + port sits on the BAT + stud (%.1f mm off)" % (at.distance_to(stud) * 1000.0))
	var pk := CtrlDesign.packed_spec(d)
	_ok(float(pk["w_m"]) > 0.43 and float(pk["h_m"]) > 0.65 and float(pk["mass_kg"]) > 1.0, "it ships as a box round the unit")
	# A panel string on the second MPPT counts as PV for that controller.
	var m: GraphModel = GraphModelScript.new()
	m.add_item({"id": "ctl", "type": "controller", "x": 0.0, "y": 0.0, "width": 140.0, "height": 120.0, "scope_id": "root",
		"handles": hs, "specs": CtrlDesign.graph_specs(d)})
	for i in 2:
		m.add_item({"id": "p%d" % i, "type": "panel", "x": 0.0, "y": 0.0, "width": 120.0, "height": 100.0, "scope_id": "root",
			"specs": {"voc": 49.0, "vmp": 41.0, "wmp": 400.0, "imp": 9.8, "isc": 10.4}})
	m.add_connection({"scope_id": "root", "polarity": "positive", "source_item_id": "p0", "source_handle_id": "negative",
		"target_item_id": "p1", "target_handle_id": "positive"})
	m.add_connection({"scope_id": "root", "polarity": "positive", "source_item_id": "p1", "source_handle_id": "positive",
		"target_item_id": "ctl", "target_handle_id": "pvPositive2"})
	m.add_connection({"scope_id": "root", "polarity": "negative", "source_item_id": "p0", "source_handle_id": "negative",
		"target_item_id": "ctl", "target_handle_id": "pvNegative2"})
	var src := PvElectrical.pv_sources_for_controller(m, "ctl")
	_ok(src.size() == 2 and absf(PvElectrical.max_string_voc_for_controller(m, "ctl") - 98.0) < 0.5,
		"a string on PV 2 + / − feeds the controller (2 panels, %.0f V)" % PvElectrical.max_string_voc_for_controller(m, "ctl"))
	# What hangs off the grid input is upstream, not a load on the inverter.
	m.add_item({"id": "grid_load", "type": "appliance", "x": 0.0, "y": 0.0, "width": 100.0, "height": 80.0, "scope_id": "root",
		"specs": {"avg_watts": 500.0, "requested_state": "on", "current_state": "on"}})
	m.add_item({"id": "out_load", "type": "appliance", "x": 0.0, "y": 0.0, "width": 100.0, "height": 80.0, "scope_id": "root",
		"specs": {"avg_watts": 300.0, "requested_state": "on", "current_state": "on"}})
	m.add_connection({"scope_id": "root", "polarity": "ac", "source_item_id": "grid_load", "source_handle_id": "input",
		"target_item_id": "ctl", "target_handle_id": "acInput"})
	m.add_connection({"scope_id": "root", "polarity": "ac", "source_item_id": "ctl", "source_handle_id": "acOutput",
		"target_item_id": "out_load", "target_handle_id": "input"})
	var loads := GraphAcLoad._reachable_ac_load_ids(m)
	_ok(loads.has("out_load") and not loads.has("grid_load"), "a load on AC out counts; one on the grid input does not %s" % str(loads.keys()))


## Panels › controller › battery found from any of the three, and the checks
## between them.
func _test_chain() -> void:
	var d := CtrlDesign.solve(CtrlPresets.builtin("eg4_6000xp"))
	var m: GraphModel = GraphModelScript.new()
	m.add_item({"id": "ctl", "type": "controller", "x": 0.0, "y": 0.0, "width": 140.0, "height": 120.0, "scope_id": "root",
		"handles": CtrlDesign.graph_handles(d), "specs": CtrlDesign.graph_specs(d)})
	# An array group with two panels inside, wired to PV 1 through its ports.
	m.add_item({"id": "arr", "type": "compound", "x": 0.0, "y": -200.0, "width": 160.0, "height": 120.0, "scope_id": "root",
		"specs": {"compound_kind": "pv_design", "name": "Roof array", "pvlab_tag": "pvlab_prop7"}})
	for i in 2:
		m.add_item({"id": "ap%d" % i, "type": "panel", "x": 0.0, "y": 0.0, "width": 120.0, "height": 100.0, "scope_id": "arr",
			"specs": {"voc": 49.0, "vmp": 41.0, "wmp": 400.0}})
	m.add_connection({"scope_id": "arr", "polarity": "positive", "source_item_id": "ap0", "source_handle_id": "negative",
		"target_item_id": "ap1", "target_handle_id": "positive"})
	m.add_connection({"scope_id": "root", "polarity": "positive", "source_item_id": "ap0", "source_handle_id": "positive",
		"target_item_id": "ctl", "target_handle_id": "pvPositive"})
	m.add_connection({"scope_id": "root", "polarity": "negative", "source_item_id": "ap1", "source_handle_id": "negative",
		"target_item_id": "ctl", "target_handle_id": "pvNegative"})
	# A loose panel on PV 2.
	m.add_item({"id": "lp", "type": "panel", "x": 200.0, "y": -200.0, "width": 120.0, "height": 100.0, "scope_id": "root",
		"specs": {"name": "Shed panel", "voc": 49.0, "vmp": 41.0, "wmp": 400.0}})
	m.add_connection({"scope_id": "root", "polarity": "positive", "source_item_id": "lp", "source_handle_id": "positive",
		"target_item_id": "ctl", "target_handle_id": "pvPositive2"})
	# A 24 V battery (wrong for a 48 V unit), with a small BMS.
	m.add_item({"id": "bat", "type": "battery", "x": 0.0, "y": 200.0, "width": 110.0, "height": 80.0, "scope_id": "root",
		"specs": {"name": "24 V bank", "voltage": 25.6, "max_charge_a": 50.0, "max_discharge_a": 100.0}})
	m.add_connection({"scope_id": "root", "polarity": "positive", "source_item_id": "ctl", "source_handle_id": "batteryPositive",
		"target_item_id": "bat", "target_handle_id": "positive"})
	var from_c := PowerChain.find(m, "ctl")
	var from_p := PowerChain.find(m, "ap1")
	var from_b := PowerChain.find(m, "bat")
	var arr_ids: Array = (from_c["arrays"] as Array).map(func(u): return str(u["id"]))
	_ok(arr_ids.has("arr") and arr_ids.has("lp") and arr_ids.size() == 2 and str(from_c["battery"]["id"]) == "bat",
		"from the controller: both arrays (%s) and the battery" % ", ".join(PackedStringArray(arr_ids)))
	_ok(str(from_p["start"]) == "panels" and str(from_p["controller"]["id"]) == "ctl" and str(from_p["battery"]["id"]) == "bat",
		"from a panel inside the array: its array is the unit, the same controller and battery")
	var arr_u: Dictionary = (from_c["arrays"] as Array).filter(func(u): return str(u["id"]) == "arr")[0]
	_ok(bool(arr_u["designed"]) and str(arr_u["prop_id"]) == "prop7" and str(from_b["controller"]["id"]) == "ctl",
		"a designed array names its placed prop; from the battery, the same controller")
	var cks := PowerChain.checks(m, from_c)
	var txt := "
".join(PackedStringArray(cks.map(func(c): return str(c["text"]))))
	_ok(cks.any(func(c): return str(c["level"]) == "error" and str(c["text"]).contains("25.6 V"))
		and cks.any(func(c): return str(c["text"]).contains("charges at up to")) and cks.any(func(c): return str(c["text"]).contains("full AC output")),
		"checks: a 25.6 V bank on a 48 V unit, charge current over the BMS, AC load over its discharge (%d)" % cks.size())
	print(txt)
	# Nothing to say about a matched bank.
	m.update_item("bat", {"specs": {"name": "48 V bank", "voltage": 51.2, "max_charge_a": 200.0, "max_discharge_a": 200.0}})
	_ok(PowerChain.checks(m, PowerChain.find(m, "ctl")).is_empty(), "a matched 51.2 V bank raises nothing")
	# Add the missing battery to a lone controller: wired to its battery terminals.
	var m2: GraphModel = GraphModelScript.new()
	m2.add_item({"id": "c2", "type": "controller", "x": 0.0, "y": 0.0, "width": 140.0, "height": 120.0, "scope_id": "root",
		"handles": CtrlDesign.graph_handles(d), "specs": CtrlDesign.graph_specs(d)})
	var nid := PowerChain.add_missing(m2, PowerChain.find(m2, "c2"), "battery")
	var ch2 := PowerChain.find(m2, "c2")
	_ok(nid != "" and str((ch2["battery"] as Dictionary).get("id", "")) == nid and absf(float(m2.get_item(nid)["specs"]["voltage"]) - 48.0) < 5.0
		and m2.connections.size() == 2, "+ Add a battery puts a ~48 V bank on the graph wired to the battery terminals")
	var t := PowerChain.pv_target(CtrlDesign.graph_specs(d))
	_ok(absf(float(t["max_voc"]) - 480.0) < 0.1 and float(t.get("mppt_min_v", 0)) > 0.0 and float(t.get("max_pv_watts", 0)) > 0.0,
		"the solar designer's target from the controller: Voc 480 V, its MPPT window, its per-input watts")
