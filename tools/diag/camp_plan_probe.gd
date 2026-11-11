extends SceneTree

## What the loop planner suggests for a fresh 12-person camp (NOT a selftest):
## each open loop, its presets and the plans with closes / cost / still open.
##   Godot --headless --path . --script tools/diag/camp_plan_probe.gd

func _initialize() -> void:
	var model := GraphModel.new()
	var def := CampTemplates.definition("mixed", 12)
	model.put_definition(def)
	var cid: String = GraphComponentDefs.realize(model, str(def["id"]), "root", Vector2.ZERO,
		{"camp_lot_id": "camp:camp_1", "camp_headcount": 12, "name": "Camp One"})
	GraphComponentDefs.make_unique(model, cid)
	var t0 := Time.get_ticks_usec()
	var rows := CampLoopClosure.suggest(model, cid)
	print("suggest ms ", (Time.get_ticks_usec() - t0) / 1000.0)
	t0 = Time.get_ticks_usec()
	CampLoopClosure.suggest(model, cid)
	print("cached ms ", (Time.get_ticks_usec() - t0) / 1000.0)
	for r in rows:
		print(r["kind"], " presets=", r["presets"])
		for pl in r["plans"]:
			var labs: Array = []
			for st in pl["steps"]:
				labs.append("%s(%s)" % [st["label"], st["type"]])
			print("    ", labs, " closes=%.2f complete=%s cost=%.2f needs=%s open=%s" % [pl["closes"], pl["complete"], pl["cost"], pl["needs"], pl["still_open"]])
	quit(0)
