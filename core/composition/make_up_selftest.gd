extends SceneTree

## What is in a tank as it really is (resource composition plan Phase 10):
## MakeUp's mix and derivation, CompositionTrack, water grades, and the flow
## engine mixing a tracked tank, deriving a machine's outputs and rewinding.
## Offline:
##   Godot --headless --path . --script core/composition/make_up_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 21
const EngineScript := preload("res://system_graph/resource_flow_engine.gd")

var _checks := 0
var _fails := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _initialize() -> void:
	_test_kind_and_mix()
	_test_derive()
	_test_track()
	_test_grades()
	_test_engine()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("MAKE UP SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("MAKE UP SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _test_kind_and_mix() -> void:
	var u := MakeUp.of_kind("urine")
	_check("urine: 7.27 g N per kg (Rose 2015)", absf(float(u["N"]) - 0.00727) < 0.0005, str(u))
	var w := MakeUp.of_kind("water")
	var m := MakeUp.mix(u, 1.0, w, 3.0)
	_check("mix: a quarter urine in water has a quarter of its N", absf(float(m["N"]) - float(u["N"]) * 0.25) < 1e-9)
	_check("mix: nothing into nothing keeps what it was", MakeUp.same(MakeUp.mix(u, 0.0, w, 0.0), u))


## Every element out is what came in, for every preset the static check
## lets off (the shared make-up does not fit their feed).
func _test_derive() -> void:
	var bad: Array = []
	for label in PresetBalance.EXCEPTIONS.keys():
		var p := ComponentPresets.find_preset_by_label(str(label))
		var sp: Dictionary = p.get("specs", {})
		var ins: Array = []
		var outs: Array = []
		for i in sp.get("inputs", []):
			var k := str((i as Dictionary)["kind"])
			if CompositionCatalog.is_material(k):
				ins.append({"kind": k, "kg_h": float(i["rate"]) * CompositionCatalog.kg_per_unit(k), "make_up": {}})
		for o in sp.get("outputs", []):
			var k2 := str((o as Dictionary)["kind"])
			outs.append({"kind": k2, "kg_h": float(o["rate"]) * CompositionCatalog.kg_per_unit(k2) if CompositionCatalog.is_material(k2) else 0.0})
		var res := MakeUp.derive_outputs(ins, outs)
		for e in MakeUp.ELEMENTS:
			var a := 0.0
			for r in ins:
				a += float(r["kg_h"]) * float(MakeUp.of_kind(str(r["kind"]))[e])
			var b := 0.0
			for j in outs.size():
				b += float(outs[j]["kg_h"]) * float(res[j][e])
			if b > a * (1.0 + 1e-6) + 1e-12:
				bad.append("%s %s in %.5f out %.5f" % [label, e, a, b])
	_check("tracked: every excepted preset's outputs carry no more of an element than came in",
		bad.is_empty() and not PresetBalance.EXCEPTIONS.is_empty(), str(bad))
	# A feed half as rich in N gives outputs half as rich in N.
	var u := MakeUp.of_kind("urine")
	var poor := u.duplicate()
	poor["N"] = float(u["N"]) * 0.5
	var ins2 := [{"kind": "urine", "kg_h": 1.0, "make_up": poor}]
	var outs2 := [{"kind": "nutrients", "kg_h": 0.0085}, {"kind": "irrigation_water", "kg_h": 0.95}]
	var r_static := MakeUp.derive_outputs([{"kind": "urine", "kg_h": 1.0, "make_up": {}}], outs2)
	var r_poor := MakeUp.derive_outputs(ins2, outs2)
	_check("derive: half the N in, half the N out", absf(float(r_poor[0]["N"]) - float(r_static[0]["N"]) * 0.5) < 1e-9,
		"%s vs %s" % [r_poor[0]["N"], r_static[0]["N"]])
	_check("derive: fractions stay within a kg", float(MakeUp.derive_outputs(
		[{"kind": "urine", "kg_h": 1.0, "make_up": {"water": 0.9, "N": 0.5, "C": 0, "P": 0, "K": 0}}], outs2)[0]["N"]) <= 1.0)


func _test_track() -> void:
	var tr := CompositionTrack.new()
	tr.record(10.0, {"water": 0.9, "N": 0.01})
	tr.record(10.1, {"water": 0.8, "N": 0.02})
	tr.record(10.5, {"water": 0.7, "N": 0.03})
	_check("track: one sample per 15-minute bucket, the last write wins", tr.size() == 2
		and absf(float(tr.at(10.2)["water"]) - 0.8) < 1e-6)
	_check("track: before the first sample reads the first", absf(float(tr.at(5.0)["water"]) - 0.8) < 1e-6)
	tr.truncate_after(10.3)
	_check("track: truncated after 10.3 h keeps one", tr.size() == 1 and absf(float(tr.at(11.0)["N"]) - 0.02) < 1e-6)
	var rt := CompositionTrack.from_dict(tr.to_dict())
	_check("track: round trip", rt.size() == 1 and absf(float(rt.at(10.0)["N"]) - 0.02) < 1e-6)


func _test_grades() -> void:
	_check("grades: distilled water feeds a drinking-water input", MakeUp.grade_ok("distilled_water", "water"))
	_check("grades: greywater does not", not MakeUp.grade_ok("greywater", "water")
		and MakeUp.grade_warning("greywater", "water").contains("grade 2"))
	_check("grades: not water is not a grade question", MakeUp.grade_ok("biomass", "water") and MakeUp.grade_ok("urine", "nutrients"))
	_check("ports: distilled water fits a water port; greywater and raw rain are amber (unusual)",
		ResourceKinds.kinds_compatible("distilled_water", "water") and not ResourceKinds.kinds_compatible("greywater", "water")
		and not ResourceKinds.kinds_compatible("rainwater", "water") and ResourceKinds.kinds_compatible("rainwater", "wash_water"))
	_check("rain catchments make rainwater", PbiBiomass.catchment_output_kind({"catchment_kind": "rain"}) == "rainwater")


func _tank(m: GraphModel, id: String, kind: String, cap: float, level: float, tracked: bool) -> void:
	m.add_item({"id": id, "type": "resource", "specs": {"name": id, "resource_kind": kind, "capacity_qty": cap,
		"capacity_unit": "L", "level": level, "track_composition": tracked}})


func _wire(m: GraphModel, s: String, sh: String, t: String, th: String, k: String) -> void:
	m.add_connection({"polarity": "resource", "resource_type": k, "source_item_id": s, "source_handle_id": sh,
		"target_item_id": t, "target_handle_id": th})


func _test_engine() -> void:
	var m := GraphModel.new()
	_tank(m, "ur", "urine", 200.0, 0.5, true)
	_tank(m, "nut", "nutrients", 100.0, 0.0, true)
	_tank(m, "irr", "irrigation_water", 1000.0, 0.0, true)
	_tank(m, "br", "brine", 100.0, 0.0, false)
	var u := MakeUp.of_kind("urine")
	var poor := u.duplicate()
	poor["N"] = float(u["N"]) * 0.5
	var usp: Dictionary = (m.get_item("ur")["specs"] as Dictionary).duplicate()
	usp["make_up"] = poor
	m.update_item("ur", {"specs": usp})
	var p := ComponentPresets.find_preset_by_label("Urine Nutrient Recovery")
	var psp: Dictionary = (p["specs"] as Dictionary).duplicate(true)
	psp["requested_state"] = "on"
	m.add_item({"id": "unr", "type": "processor", "specs": psp})
	_wire(m, "ur", "output", "unr", "res_in_0", "urine")
	_wire(m, "unr", "res_out_0", "nut", "input", "nutrients")
	_wire(m, "unr", "res_out_1", "irr", "input", "irrigation_water")
	_wire(m, "unr", "res_out_2", "br", "input", "brine")
	m.add_item({"id": "ctrl", "type": "controller", "specs": {"name": "Controller"}})
	m.add_connection({"polarity": "ac", "resource_type": "electric", "source_item_id": "ctrl", "source_handle_id": "acOutput",
		"target_item_id": "unr", "target_handle_id": "power_in"})
	var e = EngineScript.new()
	e.setup(m, null)
	e.power_available_override = 1
	e.simulate_step_for_test(0.0, 0.0)
	for h in range(1, 7):
		e.simulate_step_for_test(float(h), 1.0)
	var st := str((m.get_item("unr").get("specs", {}) as Dictionary).get("node_state", ""))
	_check("engine: the machine runs on the tracked urine", st == GraphNodeState.RUNNING,
		"%s %s %s" % [st, str((m.get_item("unr")["specs"] as Dictionary).get("node_state_reason", "")),
		str((m.get_item("unr")["specs"] as Dictionary).get("node_state_kinds", []))])
	var nmu: Dictionary = (m.get_item("nut")["specs"] as Dictionary).get("make_up", {})
	var stat := MakeUp.of_kind("nutrients")
	_check("engine: nutrients from N-poor urine are N-poor (about half)",
		not nmu.is_empty() and absf(float(nmu["N"]) / float(stat["N"]) - 0.5) < 0.05, "%s vs %s" % [str(nmu.get("N", "")), str(stat["N"])])
	var w_in := false
	for c in m.connections:
		if str((c as Dictionary).get("source_item_id", "")) == "unr" and (c as Dictionary).has("make_up"):
			w_in = true
	_check("engine: the machine's wires carry the derived make-up", w_in)
	var tr: CompositionTrack = e.call("composition_track", "nut")
	_check("engine: the tank keeps its make-up over time", tr != null and tr.size() >= 5)
	# Scrub back: the make-up rewinds with the level.
	var spn: Dictionary = (m.get_item("nut")["specs"] as Dictionary).duplicate()
	spn["make_up"] = MakeUp.of_kind("water")
	m.update_item("nut", {"specs": spn})
	e.seek_all_tanks(3.0)
	var back: Dictionary = (m.get_item("nut")["specs"] as Dictionary).get("make_up", {})
	_check("engine: scrubbing back reads the make-up it had then", MakeUp.same(back, tr.at(3.0), 1e-4), str(back))
	e.truncate_timelines_after(3.0)
	_check("engine: an edit truncates the make-up history too", tr.at(6.0).is_empty() or absf(tr.times[tr.size() - 1] - 3.0) < 1e-6)
