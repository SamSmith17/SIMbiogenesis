extends SceneTree

## The gap node, its meter and its brief (resource composition plan Phase 8),
## and a placed chain running in the flow engine. Offline:
##   Godot --headless --path . --script core/composition/design_gap_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 24
const EngineScript := preload("res://system_graph/resource_flow_engine.gd")

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  ok   ", name)
	else:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _initialize() -> void:
	_test_step()
	_test_meter()
	_test_brief()
	_test_engine_gap()
	_test_engine_chain()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("DESIGN GAP SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("DESIGN GAP SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


## Elements leaving in greater quantity than came in plus the shortfall.
func _conserves(r: Dictionary) -> String:
	var bad := PackedStringArray()
	for e in (r["el_out"] as Dictionary).keys():
		if float(r["el_out"][e]) > float((r["el_in"] as Dictionary).get(e, 0.0)) \
				+ float((r["short"] as Dictionary).get(e, 0.0)) + 1e-9:
			bad.append(str(e))
	return ",".join(bad)


func _test_step() -> void:
	# 1 L/h of urine into reclaimed water (0.9 L/h asked) and as much
	# nutrient as the rest makes.
	var avail := [{"kind": "urine", "qty_h": 1.0, "cap_h": 0.0}]
	var outs := [{"kind": "irrigation_water", "want_h": 0.9, "room_h": INF},
		{"kind": "nutrients", "want_h": 0.0, "room_h": INF}]
	var r := DesignGap.step(avail, outs)
	_check("no element leaves in greater quantity than came in plus the shortfall", _conserves(r).is_empty(), _conserves(r))
	_check("the traces urine lacks (calcium) are shortfall, not a stop",
		float((r["short"] as Dictionary).get("Ca", 0.0)) > 0.0 and float((r["short"] as Dictionary).get("N", 0.0)) == 0.0)
	_check("it delivers the water asked for", absf(float(r["give"][0]) - 0.9) < 1e-6, str(r["give"]))
	var booked := true
	for e in (r["el_in"] as Dictionary).keys():
		var lhs := float(r["el_in"][e]) + float((r["short"] as Dictionary).get(e, 0.0))
		var rhs := float((r["el_out"] as Dictionary).get(e, 0.0)) + float((r["residue"] as Dictionary).get(e, 0.0))
		if rhs > lhs + 1e-9 or (not (r["short"] as Dictionary).has(e) and absf(lhs - rhs) > 1e-9 * maxf(1.0, lhs)):
			booked = false
	_check("every element in = out + residue (where nothing is short)", booked)
	_check("the nutrients take what the water left (N goes out as nutrients)",
		float(r["give"][1]) > 0.0 and float((r["el_out"] as Dictionary).get("N", 0.0)) > 0.5 * float((r["el_in"] as Dictionary).get("N", 0.0)),
		"%s kg/h nutrients" % float(r["give"][1]))
	# Asking for far more nutrient than the urine holds: scaled down, a shortfall.
	var r2 := DesignGap.step(avail, [{"kind": "nutrients", "want_h": 5.0, "room_h": INF}])
	_check("asked for more than comes in: scaled down, the lack is a shortfall",
		_conserves(r2).is_empty() and float(r2["give"][0]) < 5.0 and float((r2["short"] as Dictionary).get("N", 0.0)) > 0.0)
	# A residue output takes the salts.
	var r3 := DesignGap.step(avail, [{"kind": "irrigation_water", "want_h": 0.9, "room_h": INF},
		{"kind": "brine", "want_h": 0.0, "room_h": INF, "residue": true}])
	_check("a residue output takes what is left (brine carries the salt)", float(r3["give"][1]) > 0.0
		and _conserves(r3).is_empty())
	var r4 := DesignGap.step(avail, outs, 0.2)
	_check("an energy target is drawn: 0.2 kWh/kg × kg in", absf(float(r4["power_w"]) - 200.0 * float(r4["kg_in"])) < 1e-6
		and float(DesignGap.step(avail, outs)["power_w"]) < 0.0)


func _test_meter() -> void:
	var m := GapMeter.new()
	var t0 := SiteReportMetrics.date_to_abs_hours(2024, 6, 15, 0.0)
	var t := t0
	while t <= t0 + 48.0 + 1e-6:
		# A rate is booked over the step that ENDS at t: the 07:00 hour is
		# the steps ending after 07:00, up to 08:00.
		var hod := fposmod(t - 0.125, 24.0)
		var rate := 3.0 if hod >= 7.0 and hod < 8.0 else 0.5
		m.record(t, {"in:urine": rate, "on": 1.0})
		t += 0.25
	_check("hours metered", absf(m.hours() - 48.0) < 0.01, "%.2f" % m.hours())
	var pk := m.peak("in:urine")
	_check("the busiest hour is 07:00", int(pk["hour_of_day"]) == 7, str(pk))
	_check("June is the month", GapMeter.month_of_day(int(floor(t0 / 24.0))) == 6
		and not is_nan(float(m.by_month("in:urine")[5])) and is_nan(float(m.by_month("in:urine")[0])))
	var back := GapMeter.from_dict(JSON.parse_string(JSON.stringify(m.to_dict())))
	_check("round trip through JSON keeps every total", absf(back.total("in:urine") - m.total("in:urine")) < 1e-9
		and absf(back.duty() - m.duty()) < 1e-9)
	var full := m.total("in:urine")
	m.record(t0 + 24.0, {"in:urine": 0.5, "on": 1.0})
	_check("a scrub back forgets what came after", m.total("in:urine") < 0.6 * full and absf(m.hours() - 24.0) < 0.3,
		"%.2f of %.2f, %.2f h" % [m.total("in:urine"), full, m.hours()])


func _test_brief() -> void:
	var specs := DesignGap.make_specs("Gap: urine to water", [{"kind": "urine", "rate": 0.0}],
		[{"kind": "irrigation_water", "rate": 0.45}, {"kind": "nutrients", "rate": 0.0}],
		{"gap_class": "distillation"})
	var m := GapMeter.new()
	var t0 := SiteReportMetrics.date_to_abs_hours(2024, 3, 1, 0.0)
	var t := t0
	while t <= t0 + 72.0 + 1e-6:
		var r := DesignGap.step([{"kind": "urine", "qty_h": 0.5, "cap_h": 0.0}],
			[{"kind": "irrigation_water", "want_h": 0.45, "room_h": INF}, {"kind": "nutrients", "want_h": 0.0, "room_h": INF}])
		m.record(t, GapMeter.rates_from_step(r, ["urine"], ["irrigation_water", "nutrients"]))
		t += 0.5
	var b := GapBrief.make(specs, m, {"curtailed_kwh_day": 3.1})
	var text := "\n".join((b["lines"] as Array).map(func(x): return str(x["text"])))
	_check("brief: process 12 L/day of urine", text.contains("Process 12 L/day of urine"), text)
	_check("brief: deliver 10.8 L/day of reclaimed water", text.contains("Deliver 10.8 L/day"), text)
	_check("brief: the water and nitrogen split", text.contains("of the water") and text.contains("of the nitrogen"))
	_check("brief: the residue must leave somewhere", text.contains("must leave somewhere"))
	_check("brief: the energy budget and the distillation floor", text.contains("curtails") and text.contains("Distillation would take"))
	var dir := OS.get_user_data_dir().path_join("design_gap_selftest_%d" % OS.get_process_id())
	var md := GapBrief.export(b, dir)
	_check("brief: exported to Markdown and JSON", FileAccess.file_exists(md) and FileAccess.file_exists(md.get_basename() + ".json"))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	var sp2 := specs.duplicate(true)
	sp2["gap_in_kg_h"] = 0.5
	sp2["gap_out_kg_h"] = 0.45
	var card := GraphCardSpecs.for_item({"id": "g", "type": "processor", "specs": sp2}, {})
	_check("card: a gap node reads GAP with what it takes in now",
		str(card.get("chip", "")) == "GAP" and str(card.get("hero", "")).ends_with("/h"), str(card))


func _tank(m: GraphModel, id: String, kind: String, cap: float, level: float) -> void:
	m.add_item({"id": id, "type": "resource", "specs": {"name": id, "resource_kind": kind, "capacity_qty": cap,
		"capacity_unit": "L", "level": level}})


func _wire(m: GraphModel, s: String, sh: String, t: String, th: String, k: String) -> void:
	m.add_connection({"polarity": "resource", "resource_type": k, "source_item_id": s, "source_handle_id": sh,
		"target_item_id": t, "target_handle_id": th})


func _level(m: GraphModel, id: String) -> float:
	return float((m.get_item(id).get("specs", {}) as Dictionary).get("level", 0.0))


func _test_engine_gap() -> void:
	var m := GraphModel.new()
	_tank(m, "ur", "urine", 100.0, 0.5)
	_tank(m, "wat", "irrigation_water", 1000.0, 0.0)
	_tank(m, "nut", "nutrients", 100.0, 0.0)
	m.add_item({"id": "gap", "type": "processor", "specs": DesignGap.make_specs("Gap: urine",
		[{"kind": "urine", "rate": 2.0}], [{"kind": "irrigation_water", "rate": 0.0}, {"kind": "nutrients", "rate": 0.0}])})
	_wire(m, "ur", "output", "gap", "res_in_0", "urine")
	_wire(m, "gap", "res_out_0", "wat", "input", "irrigation_water")
	_wire(m, "gap", "res_out_1", "nut", "input", "nutrients")
	var e = EngineScript.new()
	e.setup(m, null)
	e.simulate_step_for_test(0.0, 0.0)
	for h in range(1, 13):
		e.simulate_step_for_test(float(h), 1.0)
	var taken_l := (0.5 - _level(m, "ur")) * 100.0
	_check("engine: the gap takes its 2 L/h of urine", absf(taken_l - 24.0) < 0.5, "%.2f L" % taken_l)
	_check("engine: water and nutrients come out", _level(m, "wat") > 0.0 and _level(m, "nut") > 0.0)
	var sp: Dictionary = m.get_item("gap")["specs"]
	_check("engine: it reads RUNNING and keeps its meter", str(sp.get("node_state", "")) == GraphNodeState.RUNNING
		and (e.call("gap_meter", "gap") as GapMeter).hours() > 10.0 and sp.has("gap_meter"))


## A chain the loop closer places runs: buffers and stores make every port a
## tank, so nothing blocks.
func _test_engine_chain() -> void:
	var m := GraphModel.new()
	_tank(m, "ur", "urine", 200.0, 0.5)
	m.add_item({"id": "ctrl", "type": "controller", "specs": {"name": "Controller"}})
	var plan := {"side": "sink", "kind": "urine", "steps": [{"id": "preset:Urine Nutrient Recovery", "type": "preset",
		"label": "Urine Nutrient Recovery", "scale": 1.0, "takes": "urine", "gives": ["nutrients", "irrigation_water", "brine"]}]}
	var g := GraphSuggestions.build(m, "root", {"kind": "urine", "side": "sink", "kg_h": 1.0}, plan)
	var ids := ChainWiring.apply(m, "root", {"items": g["items"], "conns": g["conns"]})
	var unr := ""
	for iid in ids:
		if str((m.get_item(str(iid)).get("specs", {}) as Dictionary).get("name", "")) == "Urine Nutrient Recovery":
			unr = str(iid)
	var e = EngineScript.new()
	e.setup(m, null)
	e.power_available_override = 1
	e.simulate_step_for_test(0.0, 0.0)
	for h in range(1, 4):
		e.simulate_step_for_test(float(h), 1.0)
	var st := str((m.get_item(unr).get("specs", {}) as Dictionary).get("node_state", ""))
	var usp: Dictionary = m.get_item(unr).get("specs", {})
	_check("engine: the placed Urine Nutrient Recovery runs", st == GraphNodeState.RUNNING,
		"%s %s %s" % [st, str(usp.get("node_state_reason", "")), str(usp.get("node_state_kinds", []))])
