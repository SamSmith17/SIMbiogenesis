extends SceneTree

## BuiltStock (resource composition plan Phase 9): what placed structures are
## made of, the site's built stock, salvage into the graph, and the planner
## finding a use for salvaged lumber and plastic. Offline:
##   Godot --headless --path . --script core/composition/built_stock_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 24

var _checks := 0
var _fails := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _initialize() -> void:
	_test_two_by_four()
	_test_tables()
	_test_designers()
	_test_models()
	_test_site()
	_test_salvage()
	_test_planner()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("BUILT STOCK SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("BUILT STOCK SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


## An 8 ft 2×4 is ~3.6 kg: ~1.6–1.8 kg C, ~0.45 kg water, ~58 MJ.
func _test_two_by_four() -> void:
	var e := BuiltStock.embodied({"lumber": 3.6})
	var c := float((e["elements"] as Dictionary).get("C", 0.0))
	_check("2x4: 1.5–1.9 kg of carbon", c > 1.5 and c < 1.9, "%.3f" % c)
	_check("2x4: 0.4–0.5 kg of water (kiln-dried, 12–13 %)", float(e["water_kg"]) > 0.4 and float(e["water_kg"]) < 0.5, "%.3f" % float(e["water_kg"]))
	_check("2x4: ~58 MJ", absf(float(e["energy_mj"]) - 58.0) < 2.0, "%.1f" % float(e["energy_mj"]))


func _test_tables() -> void:
	var bad: Array = []
	for m in BuiltStock.MATERIALS.keys():
		var row: Dictionary = BuiltStock.MATERIALS[m]
		if not CompositionData.KINDS.has(str(row["kind"])):
			bad.append("%s kind" % m)
		var sk := str(row["salvage"])
		if not sk.is_empty() and (not ResourceKinds.BUILTIN.has(sk) or CompositionCatalog.row(sk).is_empty()):
			bad.append("%s salvage %s" % [m, sk])
	_check("every material composes and salvages into a real kind", bad.is_empty(), str(bad))
	var bad2: Array = []
	for mid in BuiltStock.MODEL_MATERIALS.keys():
		var s := 0.0
		for m2 in (BuiltStock.MODEL_MATERIALS[mid] as Dictionary).keys():
			s += float(BuiltStock.MODEL_MATERIALS[mid][m2])
			if not BuiltStock.MATERIALS.has(m2):
				bad2.append("%s→%s" % [mid, m2])
		if absf(s - 1.0) > 1e-6:
			bad2.append("%s sums %.3f" % [mid, s])
	_check("model shares are real materials summing to 1", bad2.is_empty(), str(bad2))


func _test_designers() -> void:
	var p := LinkageParams.new()
	var lk := BuiltStock.of_record({"model_id": "linkage_structure", "linkage_spec": p.to_config()})
	var ps := LinkageStructureBuilder.packed_spec_for(p)
	var lm: Dictionary = lk.get("materials", {})
	_check("linkage: wood and steel from its own frame, wood the most",
		float(lm.get("lumber", 0.0)) > float(lm.get("steel", 0.0)) and float(lm.get("steel", 0.0)) > 0.0, str(lm))
	_check("linkage: the materials add up to its shipping mass",
		absf(float(lk["kg"]) - float(ps["mass_kg"]) * float(ps.get("count", 1))) < 0.01 * float(lk["kg"]), "%.2f vs %.2f" % [float(lk["kg"]), float(ps["mass_kg"])])
	var rk := BuiltStock.of_record({"model_id": "pallet_rack", "rack_spec": {}})
	var rm: Dictionary = rk.get("materials", {})
	_check("rack: steel frames, lumber and plywood decking",
		float(rm.get("steel", 0.0)) > 0.0 and float(rm.get("lumber", 0.0)) > 0.0 and float(rm.get("plywood", 0.0)) > 0.0, str(rm))
	var domes: Dictionary = {}
	for pr in DomeLabPresets.builtins():
		domes[str(pr["id"])] = pr["spec"]
	var emt := BuiltStock.of_record({"model_id": "domelab_structure", "domelab_spec": domes["2v_conduit"]})
	_check("conduit dome: steel", _top(emt["materials"]) == "steel", str(emt["materials"]))
	var ply := BuiltStock.of_record({"model_id": "domelab_structure", "domelab_spec": domes["helix_zome"]})
	_check("plywood rib zome: plywood", _top(ply["materials"]) == "plywood", str(ply["materials"]))
	var gh := BuiltStock.of_record({"model_id": "domelab_structure", "domelab_spec": domes["covered_3v"]})
	_check("polycarbonate greenhouse: steel frame + polycarbonate cover",
		float((gh["materials"] as Dictionary).get("pc", 0.0)) > 0.0 and float((gh["materials"] as Dictionary).get("steel", 0.0)) > 0.0, str(gh["materials"]))
	var fp := FlatpackPresets.builtins()
	var fpr := BuiltStock.of_record({"model_id": "flatpack_furniture", "flatpack_spec": fp[0]["spec"]})
	_check("flat-pack: all plywood", (fpr["materials"] as Dictionary).keys() == ["plywood"], str(fpr["materials"]))


func _test_models() -> void:
	var sp := BuiltStock.of_record({"model_id": "shiftpod"})
	_check("shiftpod: from the model table, fabric the most, estimated",
		bool(sp["known"]) and _top(sp["materials"]) == "fabric" and bool(sp["est"]) and absf(float(sp["kg"]) - 34.0) < 0.01, str(sp))
	_check("a tree is not built stock", bool(BuiltStock.of_record({"model_id": "pine_1"})["skip"]))
	var unk := BuiltStock.of_record({"model_id": "no_such_model_xyz"})
	_check("an unknown model: not known, not skipped", not bool(unk["known"]) and not bool(unk["skip"]))


func _test_site() -> void:
	var recs := [{"id": "a", "model_id": "shiftpod"}, {"id": "b", "model_id": "firepit"},
		{"id": "c", "model_id": "pine_1"}, {"id": "d", "model_id": "no_such_model_xyz"}]
	var st := BuiltStock.site(recs)
	_check("site: two known, one unknown, the tree left out",
		int(st["structures"]) == 3 and int(st["unknown"]) == 1 and (st["rows"] as Array).size() == 2, str(st["structures"]))
	_check("site: the mass is the sum (34 + 35 kg)", absf(float(st["kg"]) - 69.0) < 0.01, "%.2f" % float(st["kg"]))
	var rows := BuiltStock.rows(BuiltStock.site([{"id": "x", "model_id": "site_gate"}]))
	var txt := ""
	for r in rows:
		txt += str((r as Dictionary).get("k", "")) + " "
	_check("dashboard rows: carbon held and water in the wood for a timber gate",
		txt.contains("Carbon held") and txt.contains("Water in the wood"), txt)


func _test_salvage() -> void:
	var sv := BuiltStock.salvage_kinds({"lumber": 10.0, "plywood": 5.0, "steel": 3.0, "aluminium": 1.0,
		"pp": 2.0, "glass": 4.0, "pv_module": 20.0})
	var k: Dictionary = sv["kinds"]
	_check("salvage: wood to lumber, metal to scrap, plastic, rubble; modules kept whole",
		absf(float(k.get("lumber", 0.0)) - 15.0) < 1e-6 and absf(float(k.get("scrap_metal", 0.0)) - 4.0) < 1e-6
		and absf(float(k.get("plastic_waste", 0.0)) - 2.0) < 1e-6 and absf(float(k.get("rubble", 0.0)) - 4.0) < 1e-6
		and (sv["kept"] as Dictionary).keys() == ["pv_module"], str(sv))
	var m := GraphModel.new()
	var first := BuiltStock.salvage_into(m, "root", {"lumber": 40.0}, Vector2.ZERO)
	var tid := str(first[0]["id"])
	var sp: Dictionary = m.get_item(tid)["specs"]
	_check("salvage: a new lumber store holding it",
		bool(first[0]["created"]) and str(sp["resource_kind"]) == "lumber" and absf(float(sp["level"]) * float(sp["capacity_qty"]) - 40.0) < 1e-6, str(sp))
	var second := BuiltStock.salvage_into(m, "root", {"lumber": 20.0}, Vector2.ZERO)
	var sp2: Dictionary = m.get_item(tid)["specs"]
	_check("salvage again: into the same store",
		str(second[0]["id"]) == tid and not bool(second[0]["created"]) and absf(float(sp2["level"]) * float(sp2["capacity_qty"]) - 60.0) < 1e-6)
	var open: Array = LoopPlanner.find_open(m, "root")["open"]
	var row: Dictionary = {}
	for o in open:
		if str((o as Dictionary)["kind"]) == "lumber" and str(o["side"]) == "sink":
			row = o
	_check("a salvage store nothing uses is an open loop: use 60 kg up in a week",
		not row.is_empty() and absf(float(row["kg_h"]) - 60.0 / LoopPlanner.SALVAGE_USE_H) < 1e-6, str(open))


func _test_planner() -> void:
	var lib := LoopPlanner.library()
	var ctx := {"used": {}, "made": {}, "stocked": {}, "sinks": {}}
	var lp := LoopPlanner.plan(lib, "lumber", "sink", 2.0, ctx)
	_check("salvaged lumber: the kiln first (lumber does not compost or digest)",
		not lp.is_empty() and _has_step([lp[0]], "Biochar Kiln (scrap lumber)"), _first_steps(lp))
	var pp := LoopPlanner.plan(lib, "plastic_waste", "sink", 2.0, ctx)
	_check("salvaged plastic: the planner offers a machine", not pp.is_empty() and str(((pp[0] as Dictionary)["steps"] as Array)[0].get("type", "")) == "preset", _first_steps(pp))


func _has_step(plans: Array, label: String) -> bool:
	for pl in plans:
		for st in (pl as Dictionary)["steps"]:
			if str((st as Dictionary).get("id", "")) == "preset:" + label:
				return true
	return false


func _first_steps(plans: Array) -> String:
	var out := PackedStringArray()
	for pl in plans.slice(0, 3):
		var ids := PackedStringArray()
		for st in (pl as Dictionary)["steps"]:
			ids.append(str((st as Dictionary).get("id", "")))
		out.append("[" + ", ".join(ids) + "]")
	return " ".join(out)


func _top(mats: Dictionary) -> String:
	var best := ""
	for m in mats.keys():
		if best.is_empty() or float(mats[m]) > float(mats[best]):
			best = str(m)
	return best
