extends RefCounted

## The graph inspector's automation cards, authored through the UI (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/inspector_automation_cards_check.gd -Label inspector_autos
## The cards are scenes/ui/automation_card_editor.gd now (shared with the
## designers); this pins that the inspector still authors and runs them the
## way it did, plus the new set_value action. On a graph load with a sim proxy:
##   "+ Custom rule" adds an open card (time 18:00 -> turn on) registered in
##   the AutomationEngine; the THEN row's menu reads the inspector's own
##   wording and offers "Set a value"; picking it stores a set_value spec and
##   registers a ServiceAction; the entity / value rows commit; a second
##   action is added with THEN's "+"; the trigger hour is moved just ahead of
##   the clock; at 2 sim-h/s the rule fires once, the load goes on and
##   AutomationEngine holds the value; collapsed, the summary names both;
##   the HA YAML carries number.set_value; the trash button deletes it and
##   unregisters it. Shots under screenshots\inspector_autos\. Restores the
##   load's specs.

const EDITOR_PATH := "res://scenes/ui/automation_card_editor.gd"
const ENTITY := "number.probe_setpoint"

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("autocards-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/inspector_autos"
	DirAccess.make_dir_recursive_absolute(dir)
	var img := main.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, name])


func _editor(insp: Node) -> Node:
	for n in insp.find_children("*", "VBoxContainer", true, false):
		var sc: Script = n.get_script()
		if sc != null and sc.resource_path == EDITOR_PATH and not n.is_queued_for_deletion():
			return n
	return null


func _button(root: Node, pred: Callable) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if bool(pred.call(n)):
			return n as Button
	return null


## The SpinBox / LineEdit / OptionButton on the row whose label reads `label`.
func _row_control(root: Node, label: String, cls: String) -> Control:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text != label:
			continue
		var row := l.get_parent()
		for c in row.get_children():
			if c.is_class(cls):
				return c as Control
	return null


func _autos(model: GraphModel, id: String) -> Array:
	return ((model.get_item(id).get("specs", {}) as Dictionary).get("graph_automations", []) as Array)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") if gv != null else null
	var eng: Node = tree.root.get_node_or_null("AutomationEngine")
	var insp: Node = gv.get("_inspector_panel") if gv != null else null
	_ok(model != null and eng != null and insp != null, "graph + inspector + AutomationEngine")
	if model == null or eng == null or insp == null:
		return {"ok": false, "fails": _fails}
	var load_id := ""
	for it in model.items:
		if str(it.get("type", "")) in ["appliance", "acload"] and not str(it.get("device_path", "")).is_empty():
			load_id = str(it["id"])
			break
	_ok(not load_id.is_empty(), "a graph load with a sim proxy (%s)" % load_id)
	if load_id.is_empty():
		return {"ok": false, "fails": _fails}
	var specs0: Dictionary = (model.get_item(load_id)["specs"] as Dictionary).duplicate(true)
	for a in (specs0.get("graph_automations", []) as Array):
		eng.call("unregister_automation", str((a as Dictionary).get("id", "")))
	var ts0 := float(main.get("time_scale"))
	main.set("time_scale", 0.0)
	var clean := specs0.duplicate(true)
	clean["graph_automations"] = []
	clean["requested_state"] = "off"
	model.update_item(load_id, {"specs": clean})

	gv.call("open_graph_view")
	gv.set("_sidebar_r_open", true)
	gv.call("_apply_layout")
	gv.call("_on_canvas_item_selected", load_id)
	await _settle(tree, 4)
	var ed := _editor(insp)
	_ok(ed != null, "the inspector builds its cards with the card editor")
	if ed == null:
		return await _restore(main, model, eng, insp, load_id, specs0, ts0)
	_shot(main, "00_empty")

	# + Custom rule
	var custom := _button(ed, func(b: Button) -> bool: return b.text == "+ Custom rule")
	var preset := _button(ed, func(b: Button) -> bool: return b.text == "+ Preset...")
	_ok(custom != null and preset != null, "the footer keeps '+ Preset...' and '+ Custom rule'")
	if custom == null:
		return await _restore(main, model, eng, insp, load_id, specs0, ts0)
	custom.pressed.emit()
	await _settle(tree, 3)
	var autos := _autos(model, load_id)
	var aid := str((autos[0] as Dictionary).get("id", "")) if autos.size() == 1 else ""
	_ok(autos.size() == 1 and str(((autos[0] as Dictionary)["actions"] as Array)[0].get("kind")) == "scene_node",
		"+ Custom rule adds one rule (time 18:00 -> turn on) to the load's specs")
	_ok(aid.begins_with("graph_autom_"), "the inspector's own id format (%s)" % aid)
	_ok(eng.call("get_automation", aid) != null, "the new rule is registered in the AutomationEngine")
	ed = _editor(insp)
	var kind_opt: OptionButton = null
	for o in ed.find_children("*", "OptionButton", true, false):
		var ob := o as OptionButton
		if ob.selected >= 0 and ob.get_item_text(ob.selected) == "Turn this load on/off/toggle":
			kind_opt = ob
	_ok(kind_opt != null, "the new card is open with the THEN row in the inspector's wording")
	if kind_opt == null:
		return await _restore(main, model, eng, insp, load_id, specs0, ts0)
	var sv_idx := -1
	for i in kind_opt.item_count:
		if kind_opt.get_item_text(i) == "Set a value":
			sv_idx = i
	_ok(sv_idx >= 0 and kind_opt.get_item_text(1) == "Delay (seconds)",
		"the THEN menu keeps turn / delay first and adds 'Set a value'")
	_shot(main, "01_custom_rule")

	# Switch the action to set_value.
	kind_opt.item_selected.emit(sv_idx)
	await _settle(tree, 3)
	var act: Dictionary = ((_autos(model, load_id)[0] as Dictionary)["actions"] as Array)[0]
	_ok(str(act.get("kind")) == "set_value", "picking it stores a set_value action (%s)" % str(act))
	var reg: Automation = eng.call("get_automation", aid)
	_ok(reg != null and reg.actions.size() == 1 and reg.actions[0] is ServiceAction,
		"the engine runs it as a ServiceAction")
	ed = _editor(insp)
	var ent: LineEdit = _row_control(ed, "Entity id", "LineEdit") as LineEdit
	var val: SpinBox = _row_control(ed, "Value", "SpinBox") as SpinBox
	_ok(ent != null and val != null, "the set_value row has an entity id and a value")
	if ent == null or val == null:
		return await _restore(main, model, eng, insp, load_id, specs0, ts0)
	ent.text = ENTITY
	ent.text_submitted.emit(ENTITY)
	val.value = 42.0
	await _settle(tree, 2)
	act = ((_autos(model, load_id)[0] as Dictionary)["actions"] as Array)[0]
	_ok(str(act.get("entity_id")) == ENTITY and is_equal_approx(float(act.get("value", -1.0)), 42.0),
		"the entity and value commit (%s)" % str(act))

	# A second action: THEN's "+".
	var add_then := _button(ed, func(b: Button) -> bool: return b.text == "+" and b.tooltip_text == "Add action")
	_ok(add_then != null, "THEN has its '+'")
	if add_then != null:
		add_then.pressed.emit()
		await _settle(tree, 3)
	var acts: Array = (_autos(model, load_id)[0] as Dictionary)["actions"]
	_ok(acts.size() == 2 and str((acts[1] as Dictionary).get("kind")) == "scene_node"
		and str((acts[1] as Dictionary).get("command")) == "turn_on", "a second action (turn on) is added")

	# Fire it just ahead of the clock.
	ed = _editor(insp)
	var at: SpinBox = _row_control(ed, "At hour", "SpinBox") as SpinBox
	_ok(at != null, "the WHEN row has its hour")
	var t_on := fposmod(float(main.get("day_time")) + 0.5, 24.0)
	if at != null:
		at.value = snappedf(t_on, 0.25)
		t_on = at.value
	await _settle(tree, 2)
	_shot(main, "02_set_value_card")
	var values: Array = []
	var vcb := func(e: String, v: float) -> void: values.append([e, v])
	eng.connect("value_set", vcb)
	var fired: Array = []
	var fcb := func(id: String) -> void:
		if id == aid:
			fired.append(float(main.get("day_time")))
	eng.connect("automation_triggered", fcb)
	main.set("time_scale", 2.0)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1400:
		await tree.process_frame
	main.set("time_scale", 0.0)
	eng.disconnect("value_set", vcb)
	eng.disconnect("automation_triggered", fcb)
	print("autocards-check: fired %s, values %s" % [str(fired), str(values)])
	_ok(fired.size() == 1, "the rule fired once at speed (%d)" % fired.size())
	_ok(str((model.get_item(load_id)["specs"] as Dictionary).get("requested_state", "")) == "on",
		"its turn-on action switched the load on")
	_ok(is_equal_approx(float(eng.call("get_entity_value", ENTITY)), 42.0) and values.size() == 1,
		"its set_value set %s = 42 (value_set once)" % ENTITY)
	var tw := Time.get_ticks_msec()
	while Time.get_ticks_msec() - tw < 350:   # > one 0.1 s engine evaluation
		await tree.process_frame
	var nv: Dictionary = (eng.get("_context") as Dictionary).get("numeric_values", {})
	_ok(is_equal_approx(float(nv.get(ENTITY, -1.0)), 42.0), "numeric triggers can read the set value")
	var yaml := str(eng.call("export_automation_to_ha_yaml", aid))
	_ok(yaml.contains("number.set_value") and yaml.contains(ENTITY), "the HA YAML carries number.set_value")

	# Collapse: the summary.
	ed = _editor(insp)
	var collapse := _button(ed, func(b: Button) -> bool: return b.tooltip_text == "Collapse")
	if collapse != null:
		collapse.pressed.emit()
		await _settle(tree, 3)
	ed = _editor(insp)
	var summ := ""
	for l in ed.find_children("*", "Label", true, false):
		if (l as Label).text.begins_with("When "):
			summ = (l as Label).text
	_ok(summ.contains("set %s = 42" % ENTITY) and summ.contains("turn on"), "collapsed, the summary names both (%s)" % summ)
	_shot(main, "03_collapsed")

	# Delete.
	var trash := _button(ed, func(b: Button) -> bool: return b.tooltip_text == "Delete automation")
	if trash != null:
		trash.pressed.emit()
		await _settle(tree, 3)
	_ok(_autos(model, load_id).is_empty() and eng.call("get_automation", aid) == null,
		"the trash button deletes it and unregisters it")
	return await _restore(main, model, eng, insp, load_id, specs0, ts0)


func _restore(main: Node, model: GraphModel, eng: Node, insp: Node, load_id: String,
		specs0: Dictionary, ts0: float) -> Dictionary:
	for a in _autos(model, load_id):
		eng.call("unregister_automation", str((a as Dictionary).get("id", "")))
	model.update_item(load_id, {"specs": specs0})
	insp.call("sync_all_load_automations", model)
	var gv := ServiceLocator.graph()
	if gv != null and gv.has_method("close_graph_view"):
		gv.call("close_graph_view")
	main.set("time_scale", ts0)
	await main.get_tree().process_frame
	return {"ok": _fails.is_empty(), "fails": _fails}
