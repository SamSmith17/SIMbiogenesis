extends RefCounted

## The loop planner on a real graph (resource composition plan Phase 6,
## sandbox, read-only apart from one throwaway placement):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/loop_planner_check.gd -Label loop_planner -Timeout 900
## Prints every open loop of the whole site with its plans and the time the
## search took; asserts the site has open loops, they are planned in time,
## no plan leans on a delivery, and two runs agree. Then the same for a camp
## (if the world has one): suggestions come from the planner and placing
## the first chain adds its machines to the camp.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("loopplan %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _plan_line(pl: Dictionary) -> String:
	var labs := PackedStringArray()
	for st in pl["steps"]:
		labs.append("%s%s" % [str(st["label"]), " (class)" if str(st["type"]) == "class" else ""])
	return "%s  closes %d %%%s, +%s, $%d" % [" → ".join(labs), int(round(float(pl["closes"]) * 100.0)),
		"" if bool(pl["complete"]) else " (partial)", UiText.num(float(pl["adds"]["power_w"]), "W"),
		int(pl["adds"]["cost"])]


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.create_timer(0.5, true, false, true).timeout
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = sgv.get("model")
	var lib := LoopPlanner.library()
	print("loopplan: library has %d edges" % (lib["edges"] as Array).size())
	var t0 := Time.get_ticks_usec()
	var rows := LoopPlanner.plan_scope(model, "root", 6, lib)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("loopplan: %d open loops planned in %.1f ms" % [rows.size(), ms])
	var planned := 0
	var import_used := false
	for r in rows:
		var od: Dictionary = r["open"]
		print("loopplan: %s %s %s/h" % [str(od["side"]), str(od["kind"]), UiText.num(float(od["kg_h"]), "kg")])
		if not (r["plans"] as Array).is_empty():
			planned += 1
		for pl in r["plans"]:
			print("loopplan:     " + _plan_line(pl))
			for st in pl["steps"]:
				var pre := ComponentPresets.find_preset_by_label(str(st["label"]))
				if str((pre.get("specs", {}) as Dictionary).get("role", "")) == "import":
					import_used = true
	_ok(not rows.is_empty(), "the site has open loops")
	_ok(planned > 0, "%d of %d open loops have a plan" % [planned, rows.size()])
	_ok(ms < 1500.0, "planned in %.0f ms" % ms)
	_ok(not import_used, "no plan leans on a delivery")
	_ok(JSON.stringify(LoopPlanner.plan_scope(model, "root", 6, lib)) == JSON.stringify(rows), "two runs agree")
	var camp := ""
	for it in model.items:
		var d: Dictionary = it
		if str(d.get("type", "")) == "compound" and not str((d.get("specs", {}) as Dictionary).get("camp_lot_id", "")).is_empty():
			camp = str(d.get("id", ""))
			break
	if camp.is_empty():
		print("loopplan: no festival camp on this world, camp checks skipped")
	else:
		var sugg := CampLoopClosure.suggest(model, camp)
		var opt: Dictionary = {}
		for s in sugg:
			var opts := CampLoopClosure.options(s)
			print("loopplan: camp %s: %s  →  %s" % [camp, str(s["text"]), str(opts.map(func(x): return x["text"]))])
			if opt.is_empty() and not opts.is_empty():
				opt = opts[0]
		_ok(not opt.is_empty(), "the camp gets planner suggestions")
		if not opt.is_empty():
			var before := model.items.size()
			var ids := CampLoopClosure.apply_option(model, camp, opt)
			_ok(ids.size() == (opt["labels"] as Array).size() and model.items.size() == before + ids.size(),
				"placing %s adds %s" % [str(opt["text"]), UiText.count(ids.size(), "machine")])
			for id in ids:
				model.remove_item(str(id))
	print("loopplan %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
