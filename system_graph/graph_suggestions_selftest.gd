extends SceneTree

## The loop closer's ghosts and the chain wiring they share with the camps
## (resource composition plan Phases 7–8). Offline:
##   Godot --headless --path . --script system_graph/graph_suggestions_selftest.gd
## Carries EXPECTED_CHECKS.

const EXPECTED_CHECKS := 24

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
	_test_anchor_and_ghost()
	_test_tank_and_gap()
	_test_dismissals()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("GRAPH SUGGESTIONS SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("GRAPH SUGGESTIONS SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _camp() -> GraphModel:
	var m := GraphModel.new()
	m.add_item({"id": "hab", "type": "processor", "x": 0.0, "y": 0.0, "width": 160.0, "height": 120.0,
		"specs": {"role": "habitat", "occupants": 4.0,
		"inputs": [{"kind": "water", "rate": 2.0}],
		"outputs": [{"kind": "greywater", "rate": 1.6}, {"kind": "urine", "rate": 0.06}]}})
	m.add_item({"id": "tank", "type": "resource", "x": 0.0, "y": 210.0, "width": 140.0, "height": 120.0,
		"specs": {"resource_kind": "water", "capacity_qty": 1000.0, "level": 0.5}})
	m.add_item({"id": "irr", "type": "resource", "x": 0.0, "y": 420.0, "width": 140.0, "height": 120.0,
		"specs": {"resource_kind": "irrigation_water", "capacity_qty": 1000.0, "level": 0.1}})
	return m


## The habitat's 0.24 L/h of urine through Urine Nutrient Recovery (listed
## at 1 L/h): the step is sized ×0.24.
func _urine_plan() -> Dictionary:
	return {"side": "sink", "kind": "urine", "kg_h": 0.25, "closes": 1.0, "complete": true,
		"adds": {"power_w": 45.0, "cost": 900.0}, "needs": [], "still_open": [],
		"steps": [{"id": "preset:Urine Nutrient Recovery", "type": "preset", "label": "Urine Nutrient Recovery",
			"scale": 0.24, "takes": "urine", "gives": ["nutrients", "irrigation_water", "brine"]}]}


func _by_label(items: Array, label: String) -> Dictionary:
	for it in items:
		if str((it as Dictionary)["label"]) == label:
			return it
	return {}


func _types(m: GraphModel, items: Array) -> Dictionary:
	var t := {}
	for it in m.items:
		t[str((it as Dictionary)["id"])] = str((it as Dictionary)["type"])
	for it2 in items:
		t[str((it2 as Dictionary)["id"])] = str((it2 as Dictionary)["type"])
	return t


func _test_anchor_and_ghost() -> void:
	var m := _camp()
	var a := GraphSuggestions.anchor_for(m, "root", "urine", "sink")
	_check("anchor: the habitat's urine output when there is no urine tank", str(a.get("id", "")) == "hab"
		and str(a.get("handle", "")) == "res_out_1" and not bool(a.get("tank", true)), str(a))
	var od := {"kind": "urine", "side": "sink", "kg_h": 0.25}
	var g := GraphSuggestions.build(m, "root", od, _urine_plan())
	var items: Array = g["items"]
	var unr := _by_label(items, "Urine Nutrient Recovery")
	_check("ghost: the machine", not unr.is_empty() and int(g["machines"]) == 1)
	var labels: Array = items.map(func(x): return str(x["label"]))
	_check("ghost: a urine buffer from the habitat, a nutrients store and a salt pan for the brine",
		labels.has("Urine (diverted) buffer") and labels.has("Nutrients store") and labels.has("Salt Pan (brine)")
		and int(g["tanks"]) == 3, str(labels))
	var types := _types(m, items)
	var m2m := 0
	var from_hab := false
	var to_irr := false
	for c in g["conns"]:
		var cd: Dictionary = c
		if str(types.get(str(cd["source"]), "")) != "resource" and str(types.get(str(cd["target"]), "")) != "resource":
			m2m += 1
		if str(cd["source"]) == "hab" and str(cd["source_handle"]) == "res_out_1":
			from_hab = true
		if str(cd["target"]) == "irr" and str(cd["resource_type"]) == "irrigation_water":
			to_irr = true
	_check("no wire runs machine to machine (the engine moves things only through tanks)", m2m == 0, "%d" % m2m)
	_check("ghost: it takes the habitat's urine port", from_hab, str(g["conns"]))
	_check("ghost: its reclaimed water goes into the camp's irrigation tank", to_irr)
	var sp: Dictionary = unr["specs"]
	_check("ghost: the machine is sized to the 0.24 L/h stream, not its listed 1 L/h",
		absf(float((sp["inputs"] as Array)[0]["rate"]) - 0.24) < 0.02 and float(sp["watts"]) < 50.0,
		str((sp["inputs"] as Array)[0]))
	var clear := true
	for it in items:
		var r := Rect2(float(it["x"]), float(it["y"]), float(it["width"]), float(it["height"]))
		for it2 in m.items:
			var d: Dictionary = it2
			if Rect2(float(d["x"]), float(d["y"]), float(d["width"]), float(d["height"])).intersects(r):
				clear = false
	_check("ghost: no card sits on a real card", clear)
	_check("ghost: below the anchor (a sink plan takes from an output)", float(unr["y"]) >= 120.0)
	_check("ghost: the model is untouched", m.items.size() == 3 and m.connections.is_empty())
	_check("chip: says what it does", str(g["text"]).begins_with("Close the urine loop")
		and str(g["text"]).contains("1 machine and 3 tanks") and str(g["text"]).contains("+45 W"), str(g["text"]))
	_check("two builds agree", JSON.stringify(GraphSuggestions.build(m, "root", od, _urine_plan())["conns"]) == JSON.stringify(g["conns"]))
	var before_rev := m.struct_rev
	var ids := ChainWiring.apply(m, "root", {"items": g["items"], "conns": g["conns"]})
	var wired := 0
	for c2 in m.connections:
		var cd2: Dictionary = c2
		if ids.has(str(cd2["source_item_id"])) or ids.has(str(cd2["target_item_id"])):
			wired += 1
	_check("apply: every card and wire is added, with the model's keys", ids.size() == items.size()
		and wired == (g["conns"] as Array).size() and m.struct_rev > before_rev,
		"%d of %d wires" % [wired, (g["conns"] as Array).size()])
	_check("apply: the open urine loop is gone", not _open_has(m, "urine"))


func _open_has(m: GraphModel, kind: String) -> bool:
	for o in LoopPlanner.find_open(m, "root")["open"]:
		if str(o["kind"]) == kind:
			return true
	return false


func _test_tank_and_gap() -> void:
	var m := _camp()
	m.add_item({"id": "ut", "type": "resource", "x": 400.0, "y": 0.0, "width": 140.0, "height": 120.0,
		"specs": {"resource_kind": "urine", "capacity_qty": 200.0, "level": 0.2}})
	var a := GraphSuggestions.anchor_for(m, "root", "urine", "sink")
	_check("anchor: a urine tank, wired by kind", str(a["id"]) == "ut" and bool(a["tank"]))
	var plan := _urine_plan()
	(plan["steps"] as Array).append({"id": "class:distillation:brine", "type": "class", "label": "Distillation",
		"class": "distillation", "takes": "brine", "gives": ["water"]})
	var g := GraphSuggestions.build(m, "root", {"kind": "urine", "side": "sink", "kg_h": 0.25}, plan)
	var from_tank := false
	for c in g["conns"]:
		if str((c as Dictionary)["source"]) == "ut":
			from_tank = true
	_check("ghost: wired from the urine tank", from_tank)
	var g2 := GraphSuggestions.build(m, "root", {"kind": "urine", "side": "sink", "kg_h": 0.25}, plan, 0, 1, "hab")
	var from_hab := false
	for c3 in g2["conns"]:
		if str((c3 as Dictionary)["source"]) == "hab":
			from_hab = true
	_check("asked from the habitat, the ghost joins its urine port, not the tank", from_hab)
	var gap: Dictionary = {}
	for it in g["items"]:
		if bool((it as Dictionary).get("gap", false)):
			gap = it
	_check("ghost: a step no machine does is a gap node", not gap.is_empty() and int(g["gaps"]) == 1
		and DesignGap.is_gap(gap["specs"]) and str(gap["specs"].get("gap_class", "")) == "distillation"
		and str(g["text"]).contains("1 gap node"), str(g["text"]))
	var brine_buffer := false
	for c4 in g["conns"]:
		var cd4: Dictionary = c4
		if not gap.is_empty() and str(cd4["target"]) == str(gap["id"]) and str(cd4["resource_type"]) == "brine":
			brine_buffer = true
	_check("ghost: the gap node takes the brine through a buffer", brine_buffer)
	var n0 := m.items.size()
	var ids := ChainWiring.apply(m, "root", {"items": g["items"], "conns": g["conns"]})
	var gap_placed := false
	for iid in ids:
		if DesignGap.is_gap((m.get_item(str(iid)).get("specs", {}) as Dictionary)):
			gap_placed = true
	_check("apply: the gap node is placed with the rest", gap_placed and m.items.size() == n0 + ids.size())


func _test_dismissals() -> void:
	var path := OS.get_user_data_dir().path_join("graph_suggestions_selftest_%d.json" % OS.get_process_id())
	var od := {"kind": "urine", "side": "sink"}
	var plan := _urine_plan()
	var g := GraphSuggestions.build(_camp(), "root", od, plan)
	var d: Dictionary = {GraphSuggestions.dismiss_id(g): 1}
	_check("dismissals: saved", GraphSuggestions.save_dismissed(path, d))
	var back := GraphSuggestions.load_dismissed(path)
	_check("dismissals: read back, and the plan is dismissed", GraphSuggestions.is_dismissed(back, "root", od, plan))
	var other := plan.duplicate(true)
	(other["steps"] as Array)[0]["id"] = "preset:Something Else"
	_check("dismissals: another plan for the same loop is not", not GraphSuggestions.is_dismissed(back, "root", od, other))
	_check("dismissals: nor the same plan in another scope", not GraphSuggestions.is_dismissed(back, "camp", od, plan))
	DirAccess.remove_absolute(path)
