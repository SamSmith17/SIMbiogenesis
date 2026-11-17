extends RefCounted

## The Flows lens's reading order and the Process lens's direction on a real
## world (sandbox; Mount Vernon: two arrays, the EG4 hybrid, its battery):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/flows_lens_tiers_check.gd -Label flows_tiers -Timeout 900
## At noon and at night: the arrays on the top row, the inverter under them,
## the battery under the inverter (a discharging battery feeds it UP); a DC
## pair is one flow (no doubled values); sunlight comes in as broad bands,
## never "from store"; the inverter's card shows its AC output; an array is
## drawn big enough to show its panels. Then REAL Shift-clicks select two
## nodes, a REAL click on the "Group" chip groups them, and the Process lens
## is turned top to bottom. Shots of each.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("flowstiers %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


static func _is_array(it: Dictionary) -> bool:
	var ck := str((it.get("specs", {}) as Dictionary).get("compound_kind", ""))
	return str(it.get("type", "")) == "compound" and (ck == "array" or ck == "pv_design")


func _of_type(model: GraphModel, ids: Array, pred: Callable) -> Array:
	var out: Array = []
	for id in ids:
		if pred.call(model.get_item(str(id))):
			out.append(str(id))
	return out


func _check_hour(tree: SceneTree, vp: Viewport, dir: String, main: Node, canvas: Control,
		model: GraphModel, hour: float) -> void:
	var tag := "h%02d" % int(hour)
	main.set("time_scale", 0.0)
	main.set("day_time", hour)
	await _wait(tree, 1.5)
	var lens: GraphFlowLens = canvas.call("flows_lens")
	canvas.set("_flows_inp", [])
	lens.clear_pins()
	lens.force_next()
	await _wait(tree, 1.5)
	canvas.call("flows_fit")
	await _wait(tree, 0.8)
	var inp: Array = canvas.call("_flows_input")
	var d: Dictionary = inp[1]
	var su: Node = main.get_node_or_null("UILayer/SolarUI")
	var apb := main.get_node_or_null("/root/AcPowerBus")
	print("flowstiers %s: hint %s | solar %s aux %s gdc %s load %s | ac_enabled %s" % [tag, str(canvas.get("live_power_hint").get("battery_w", "?")),
		str(su.get("current_solar_kw")) if su else "?", str(su.get("current_aux_generation_kw")) if su else "?",
		str(su.get("current_graph_dc_kw")) if su else "?", str(su.get("current_load_kw")) if su else "?",
		str(apb.get("ac_output_enabled")) if apb else "?"])
	var pairs := {}
	var doubled := false
	for e in (d["edges"] as Array):
		var k := "%s>%s" % [str(e["a"]), str(e["b"])]
		if pairs.has(k):
			doubled = true
		pairs[k] = true
	_ok(not doubled, "%s: every pair of things is one flow (no doubled DC pair)" % tag)
	var labels: Array = []
	for b in (d["bin"] as Array) + (d["bout"] as Array):
		labels.append(str(b["label"]))
	_ok(not labels.has("from store") and not labels.has("into store"), "%s: no 'from store' stubs (%s)" % [tag, str(labels)])
	var nodes: Dictionary = lens.cur.get("nodes", {})
	var ids: Array = nodes.keys()
	var arrays := _of_type(model, ids, func(it: Dictionary) -> bool:
		return str(it.get("type", "")) == "panel" or _is_array(it))
	var ctrls := _of_type(model, ids, func(it: Dictionary) -> bool: return str(it.get("type", "")) == "controller")
	var bats := _of_type(model, ids, func(it: Dictionary) -> bool: return str(it.get("type", "")) in ["battery", "smartbattery"])
	print("flowstiers %s: arrays %s, controllers %s, batteries %s" % [tag, str(arrays), str(ctrls), str(bats)])
	var lay := func(id: String) -> int: return int(nodes[id]["layer"])
	if not ctrls.is_empty() and not bats.is_empty():
		var below := true
		for b in bats:
			for c in ctrls:
				if lay.call(b) <= lay.call(c):
					below = false
		_ok(below, "%s: every battery sits under the inverter" % tag)
	for a in arrays:
		for c in ctrls:
			_ok(lay.call(a) < lay.call(c), "%s: %s is above the inverter" % [tag, a])
	var info: Dictionary = d.get("info", {})
	# The battery's card agrees with SolarUI's battery flow (charging / giving).
	var hint_w := float(canvas.get("live_power_hint").get("battery_w", 0.0))
	for b in bats:
		var bv := str((info.get(b, {}) as Dictionary).get("value", ""))
		if hint_w > 50.0:
			_ok(bv.begins_with("charging"), "%s: the battery charges as SolarUI says (+%.0f W): %s" % [tag, hint_w, bv])
		elif hint_w < -50.0:
			_ok(bv.begins_with("giving"), "%s: the battery gives as SolarUI says (%.0f W): %s" % [tag, hint_w, bv])
	for c in ctrls:
		_ok(str((info.get(c, {}) as Dictionary).get("value", "")).begins_with("AC out"),
			"%s: the inverter says its AC output (%s)" % [tag, str(info.get(c, {}))])
	var sun := 0
	for rb in (lens.cur.get("ribbons", []) as Array):
		if bool(rb.get("sun", false)):
			sun += 1
	if not arrays.is_empty():
		_ok(sun == arrays.size(), "%s: sunlight falls on each array (%d bands)" % [tag, sun])
		for a in arrays:
			if _is_array(model.get_item(a)):
				_ok((nodes[a]["rect"] as Rect2).size.y > 100.0, "%s: the array %s is drawn big (%s)" % [tag, a,
					str((nodes[a]["rect"] as Rect2).size)])
	_shot(vp, dir, "flows_%s" % tag)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _wait(tree, 1.0)
	var sgv := ServiceLocator.graph()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	sgv.call("open_graph_view")
	await _wait(tree, 1.0)
	sgv.call("_jump_to_scope_index", 0)
	var canvas: Control = sgv.get("_graph_canvas")
	var model: GraphModel = sgv.get("model")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FLOWS)
	canvas.call("set_flows_shape", "column")
	await _wait(tree, 1.0)
	await _check_hour(tree, vp, dir, main, canvas, model, 12.5)
	await _check_hour(tree, vp, dir, main, canvas, model, 18.0)
	await _check_hour(tree, vp, dir, main, canvas, model, 23.0)

	# --- Multi-select with REAL Shift-clicks, then the Group chip ----------
	main.set("day_time", 12.5)
	canvas.set("_flows_inp", [])
	var lens: GraphFlowLens = canvas.call("flows_lens")
	lens.force_next()
	await _wait(tree, 1.5)
	canvas.call("flows_fit")
	await _wait(tree, 0.6)
	var nodes: Dictionary = lens.cur.get("nodes", {})
	var picks: Array = []
	for id in nodes:
		var t := str(model.get_item(str(id)).get("type", ""))
		if t in ["appliance", "acload", "battery", "controller"]:
			picks.append(str(id))
	picks.sort()
	_ok(picks.size() >= 2, "two nodes to select (%s)" % str(picks))
	if picks.size() >= 2:
		var xf := canvas.get_global_transform_with_canvas()
		for id in picks.slice(0, 2):
			var r := lens.node_rect(id, canvas.size * 0.5, canvas.get("_pan"), float(canvas.get("_zoom")))
			var p := xf * r.get_center()
			await HarnessInput.mouse_move(vp, p, false, true)
			await HarnessInput.mouse_press(vp, p, true, false, false, true)
			await HarnessInput.mouse_press(vp, p, false, false, false, true)
			await _wait(tree, 0.2)
		var sel: Array = canvas.get("selected_item_ids")
		_ok(sel.size() == 2, "Shift-clicks select two nodes (%s)" % str(sel))
		var vsel: Array = sgv.get("_selected_item_ids")
		_ok(vsel.size() == 2, "the view has the same selection (%s)" % str(vsel))
		await _wait(tree, 0.3)
		_shot(vp, dir, "flows_selected")
		var chip := {}
		for c in lens.chips:
			if str(c["kind"]) == "group":
				chip = c
		_ok(not chip.is_empty(), "a Group chip shows for the selection")
		if not chip.is_empty():
			var before := model.items.size()
			await HarnessInput.click(vp, xf * (chip["rect"] as Rect2).get_center())
			await _wait(tree, 1.0)
			var grouped := false
			for it in model.items:
				if str((it as Dictionary).get("type", "")) == "compound":
					var kids: Array = model.get_items_in_scope(str((it as Dictionary).get("child_scope_id", "")))
					var kid_ids: Array = kids.map(func(k): return str((k as Dictionary)["id"]))
					if kid_ids.has(picks[0]) and kid_ids.has(picks[1]):
						grouped = true
			_ok(grouped, "a REAL click on Group puts both in one group (items %d -> %d)" % [before, model.items.size()])
			canvas.set("_flows_inp", [])
			lens.force_next()
			await _wait(tree, 1.5)
			canvas.call("flows_fit")
			await _wait(tree, 0.6)
			_shot(vp, dir, "flows_grouped")

	# --- The Process lens, left to right and top to bottom ---------------
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_PROCESS)
	await _wait(tree, 2.0)
	var pl: Control = canvas.get("_process_lens")
	_ok(pl != null, "the Process lens is up")
	if pl != null:
		_shot(vp, dir, "process_right")
		var opt: OptionButton = pl.get("_flow_opt")
		_ok(opt != null, "a Flow direction picker in the palette")
		opt.select(1)
		opt.item_selected.emit(1)
		await _wait(tree, 1.5)
		var doc: Dictionary = pl.get("_doc")
		_ok(str(doc.get("flow", "")) == "down" and str(pl.call("flow_dir")) == "down", "the picture reads top to bottom")
		var downs := 0
		var ups := 0
		var by := {}
		for e in (doc.get("elements", []) as Array):
			by[str(e["id"])] = e
		for p in (doc.get("pipes", []) as Array):
			if bool(p.get("returns", false)) or not by.has(str(p.get("from", ""))) or not by.has(str(p.get("to", ""))):
				continue
			if (by[str(p["to"])]["pos"] as Vector2).y > (by[str(p["from"])]["pos"] as Vector2).y:
				downs += 1
			else:
				ups += 1
		_ok(downs > 0 and ups == 0, "every forward line runs down (%d down, %d not)" % [downs, ups])
		var ico: Dictionary = pl.call("icons_data")
		_ok(str(ico.get("flow", "")) == "down", "the direction is saved with the picture's views")
		_shot(vp, dir, "process_down")
		opt.select(0)
		opt.item_selected.emit(0)
		await _wait(tree, 1.0)
	return {"ok": _fails.is_empty(), "fails": _fails}
