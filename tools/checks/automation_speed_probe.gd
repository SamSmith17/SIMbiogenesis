extends RefCounted

## The LIVE automation engine at speed (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/automation_speed_probe.gd
## Gives a graph load two inspector-style rules (on at T, off at T + 1 h) a
## little ahead of the clock, runs the clock at 2 sim-hours per second — one
## engine evaluation (0.1 s) then spans 12 sim-minutes, which the old ±1 min
## time-trigger window stepped straight over — and checks both fired, once
## each, with the load's state following. Also: solar / load numeric signals
## arrive in W, as the inspector labels them. Restores the load's specs.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("auto-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") if gv != null else null
	var eng: Node = tree.root.get_node_or_null("AutomationEngine")
	_ok(model != null and eng != null, "graph + AutomationEngine")
	if model == null or eng == null:
		return {"ok": false, "fails": _fails}
	var load_id := ""
	for it in model.items:
		if str(it.get("type", "")) in ["appliance", "acload"] and not str(it.get("device_path", "")).is_empty():
			load_id = str(it["id"])
			break
	_ok(not load_id.is_empty(), "a graph load with a sim proxy (%s)" % load_id)
	if load_id.is_empty():
		return {"ok": false, "fails": _fails}
	var item := model.get_item(load_id)
	var specs0: Dictionary = (item["specs"] as Dictionary).duplicate(true)
	var ts0 := float(main.get("time_scale"))
	main.set("time_scale", 0.0)
	await _settle(tree, 3)
	var now := float(main.get("day_time"))
	var t_on := fposmod(now + 0.5, 24.0)
	var t_off := fposmod(now + 1.5, 24.0)
	var specs := specs0.duplicate(true)
	specs["graph_automations"] = [
		{"id": "probe_on", "alias": "Probe on", "enabled": true,
			"triggers": [{"kind": "time", "at_hour": t_on}], "conditions": [],
			"actions": [{"kind": "scene_node", "command": "turn_on"}]},
		{"id": "probe_off", "alias": "Probe off", "enabled": true,
			"triggers": [{"kind": "time", "at_hour": t_off}], "conditions": [],
			"actions": [{"kind": "scene_node", "command": "turn_off"}]},
	]
	specs["requested_state"] = "off"
	model.update_item(load_id, {"specs": specs})
	var insp: Variant = gv.get("_inspector_panel")
	if insp != null:
		insp.call("sync_all_load_automations", model)
	var fired: Array = []
	var cb := func(aid: String) -> void:
		if aid.begins_with("probe_"):
			fired.append([aid, float(main.get("day_time"))])
	eng.connect("automation_triggered", cb)
	var states: Array = []
	main.set("time_scale", 2.0)   # sim-hours per real second
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1400:
		await tree.process_frame
		var st := str((model.get_item(load_id)["specs"] as Dictionary).get("requested_state", ""))
		if states.is_empty() or states[states.size() - 1] != st:
			states.append(st)
	main.set("time_scale", 0.0)
	eng.disconnect("automation_triggered", cb)
	print("auto-check: fired %s, load states %s" % [str(fired), str(states)])
	var ons := fired.filter(func(e: Array) -> bool: return e[0] == "probe_on")
	var offs := fired.filter(func(e: Array) -> bool: return e[0] == "probe_off")
	_ok(ons.size() == 1, "the 'on' rule fired once at speed (%d)" % ons.size())
	_ok(offs.size() == 1, "the 'off' rule fired once at speed (%d)" % offs.size())
	_ok(states.has("on") and states[states.size() - 1] == "off", "the load went on, then off")
	var ctx: Dictionary = eng.get("_context")
	var nv: Dictionary = ctx.get("numeric_values", {})
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	if su != null and nv.has("sensor.load_power"):
		_ok(is_equal_approx(float(nv["sensor.load_power"]), float(su.get("current_load_kw")) * 1000.0),
			"sensor.load_power is in W (%.1f)" % float(nv["sensor.load_power"]))
	# Restore.
	model.update_item(load_id, {"specs": specs0})
	if insp != null:
		for aid in ["probe_on", "probe_off"]:
			eng.call("unregister_automation", aid)
		insp.call("sync_all_load_automations", model)
	main.set("time_scale", ts0)
	return {"ok": _fails.is_empty(), "fails": _fails}
