extends RefCounted

## SCADA Phase 3b, second part, on a real world (sandbox), with REAL input:
## wires, breakers, cables, the checks list and instruments in the Process
## lens.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/process_wiring_check.gd -Label process_wiring -Timeout 900
## - two unwired loads wait under the picture once Power shows; the Wire
##   tool dragged from the inverter to one wires it; the Breaker tool on
##   that wire puts a breaker in; the Wire tool from the breaker to the
##   second load;
## - 4 kW on a 15 A breaker trips it at once; the picture and the Checks
##   button say so; the Checks list opens and a click on its row selects the
##   breaker; the breaker's faceplate resets it (with one load off);
## - the Cable tool joins a server and a switch; a lamp is refused;
## - a placed board measuring a seeded tank and switching a load: its
##   readings are bubbles on the tank; with its cable pulled the load's
##   switch is refused with the reason;
## - UiAudit; one Ctrl+Z takes the last edit back.
## Removes what it made. Shots under screenshots/process_wiring/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("process-wiring %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/process_wiring"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _center(mimic: Control, id: String) -> Vector2:
	var e: Dictionary = mimic.call("element_by_id", id)
	if e.is_empty():
		return Vector2(-1, -1)
	return mimic.get_global_transform() * (mimic.call("element_rect", e) as Rect2).get_center()


func _tool(vp: Viewport, tree: SceneTree, lens: Control, id: String) -> void:
	var b: Button = lens.call("tool_button", id)
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(b))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(b))
	await _settle(tree, 10)


func _ac_wire(model: GraphModel, a: String, b: String) -> String:
	for c in model.get_connections_in_scope("root"):
		if str(c.get("source_item_id", "")) == a and str(c.get("target_item_id", "")) == b and str(c.get("polarity", "")) in ["ac", "load"]:
			return str(c["id"])
	return ""


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null else null
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)
	var ids0 := {}
	for it in model.get_items_in_scope("root"):
		ids0[str(it["id"])] = true

	var inv := ""
	for it in model.get_items_in_scope("root"):
		if str(it.get("type", "")) == "controller" and not bool((it.get("specs", {}) as Dictionary).get("destroyed", false)):
			inv = str(it["id"])
			break
	_ok(not inv.is_empty(), "the site has an inverter to wire from")
	if inv.is_empty():
		return {"ok": false, "fails": _fails}

	# ---- seed: two loads, a tank, a server and a switch ----
	var heater := "pw_test_heater"
	var kettle := "pw_test_kettle"
	var tank := "pw_test_tank"
	var srv := "pw_test_server"
	var sw := "pw_test_switch"
	for pair in [[heater, "Wiring Test Heater"], [kettle, "Wiring Test Kettle"]]:
		model.add_item({"id": pair[0], "type": "appliance", "x": -900.0, "y": -2200.0, "width": 200.0, "height": 128.0,
			"specs": {"name": pair[1], "avg_watts": 2000.0, "rated_watts": 2000.0, "max_watts": 2000.0,
			"requested_state": "on", "current_state": "on"}})
	model.add_item({"id": tank, "type": "resource", "x": -500.0, "y": -2200.0, "width": 120.0, "height": 120.0,
		"specs": {"name": "Wiring Test Tank", "resource_kind": "water", "capacity_qty": 1000.0, "capacity_unit": "L",
		"level": 0.4, "process_show": true}})
	model.add_item({"id": srv, "type": "appliance", "x": -300.0, "y": -2200.0, "width": 200.0, "height": 128.0,
		"specs": ScadaNet.make_specs(ScadaNet.ROLE_SERVER, "Wiring Test Server", 15.0)})
	model.add_item({"id": sw, "type": "appliance", "x": -100.0, "y": -2200.0, "width": 200.0, "height": 128.0,
		"specs": ScadaNet.make_specs(ScadaNet.ROLE_SWITCH, "Wiring Test Switch", 4.0)})
	var pl := main.get_node_or_null("Player") as Node3D
	var at := pl.global_position - pl.global_transform.basis.z * 4.0 if pl != null else Vector3.ZERO
	var spec := {"name": "Wiring Probe", "board": "esp32_devkit_v1", "parts": [
		{"part": "jsnsr04t", "measures": {"distance": "tank.%s.distance_m" % tank}},
		{"part": "relay_1ch", "label": "Heater", "measures": {"relay": "item.%s.switch" % heater}}]}
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, EspBuilder.MODEL_ID, at.x, at.z, {"esp_spec": spec})
	var pid := str(r.get("prop_id", ""))
	await _settle(tree, 90)
	var board := str(PlacedPropService.get_prop_record(main, pid).get("graph_item_id", ""))
	_ok(not board.is_empty(), "the board is placed, with its node")

	# ---- the lens with Power shown ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var chips: Dictionary = view.get("_mode_chip_btns")
	await HarnessInput.mouse_move(vp, HarnessInput.center_of(chips["process"]))
	await _settle(tree, 3)
	await HarnessInput.click(vp, HarnessInput.center_of(chips["process"]))
	await _settle(tree, 30)
	var canvas: Control = view.get("_graph_canvas")
	var lens: Control = canvas.call("process_lens")
	_ok(lens != null and lens.is_visible_in_tree(), "the Process lens is up")
	if lens == null:
		return {"ok": false, "fails": _fails}
	var mimic: Control = lens.get("mimic")
	_ok((mimic.call("element_by_id", heater) as Dictionary).is_empty(), "with pipes alone the loads are not in the picture")

	# ---- the Wire tool (it turns Power on) ----
	await _tool(vp, tree, lens, "wire")
	_ok(str(lens.call("tool")) == "wire" and bool((lens.call("layers") as Dictionary).get("power", false)), "arming Wire shows the Power lines")
	lens.call("fit")
	await _settle(tree, 8)
	var eh: Dictionary = mimic.call("element_by_id", heater)
	_ok(not eh.is_empty() and bool(eh.get("loose", false)), "the unwired heater waits under the picture")
	var vis := Rect2(Vector2.ZERO, vp.get_visible_rect().size)
	_ok(vis.has_point(_center(mimic, inv)) and vis.has_point(_center(mimic, heater)), "the inverter and the heater are both on screen")
	await HarnessInput.drag(vp, _center(mimic, inv), _center(mimic, heater), 14)
	await _settle(tree, 16)
	var w1 := _ac_wire(model, inv, heater)
	_ok(not w1.is_empty(), "a drag from the inverter to the heater wires it")
	_shot(main, "01_wired")

	# ---- a breaker into that wire ----
	await _tool(vp, tree, lens, "breaker")
	lens.call("fit")
	await _settle(tree, 8)
	var on_wire: Vector2 = mimic.get_global_transform() * (mimic.call("pipe_screen_point", w1, 0.5) as Vector2)
	await HarnessInput.mouse_move(vp, on_wire)
	await _settle(tree, 3)
	await HarnessInput.click(vp, on_wire)
	await _settle(tree, 16)
	var brk := ""
	for it in model.get_items_in_scope("root"):
		if not ids0.has(str(it["id"])) and BreakerTrip.is_breaker(it):
			brk = str(it["id"])
	_ok(not brk.is_empty() and not _ac_wire(model, inv, brk).is_empty() and not _ac_wire(model, brk, heater).is_empty(),
		"the Breaker tool on the wire puts a breaker in: inverter → breaker → heater")
	if brk.is_empty():
		return {"ok": false, "fails": _fails}
	await _settle(tree, 40)
	var bs: Dictionary = model.get_item(brk).get("specs", {})
	var ac_ok := PlacedLightPower.ac_available(main)
	print("process-wiring: site AC %s; the breaker reads %s" % ["up" if ac_ok else "DOWN", BreakerTrip.state_words(bs)])
	if ac_ok:
		_ok(absf(float(bs.get("live_amps", 0.0)) - 2000.0 / 120.0) < 1.5 and not bool(bs.get("tripped", false)),
			"one 2 kW heater: it carries about 16.7 A and holds (%.1f A)" % float(bs.get("live_amps", 0.0)))

	# ---- the second load from the breaker: it trips ----
	await _tool(vp, tree, lens, "wire")
	lens.call("fit")
	await _settle(tree, 8)
	await HarnessInput.drag(vp, _center(mimic, brk), _center(mimic, kettle), 14)
	await _settle(tree, 16)
	_ok(not _ac_wire(model, brk, kettle).is_empty(), "a drag from the breaker to the kettle wires it")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 70)
	bs = model.get_item(brk).get("specs", {})
	if ac_ok:
		_ok(bool(bs.get("tripped", false)) and not BreakerTrip.is_closed(bs), "4 kW on a 15 A breaker trips it (%s)" % BreakerTrip.state_words(bs))
		lens.call("recheck")
		await _settle(tree, 6)
		var st: Dictionary = ((mimic.get("state") as Dictionary).get("el", {}) as Dictionary).get(brk, {}) as Dictionary
		_ok(bool(st.get("warn", false)) and str(st.get("value", "")).begins_with("Tripped"), "the picture shows it tripped")
		var cb: Button = lens.find_child("checks_btn", true, false)
		_ok(cb != null and cb.text.contains("problem"), "the Checks button counts a problem (%s)" % (cb.text if cb != null else "?"))
		await HarnessInput.click(vp, HarnessInput.center_of(cb))
		await _settle(tree, 12)
		var panel: PanelContainer = lens.call("checks_panel")
		_ok(panel != null and panel.visible, "a click opens the checks list")
		_shot(main, "02_tripped_checks")
		var row: Button = null
		var checks: Array = lens.call("checks")
		for i in checks.size():
			if (checks[i]["ids"] as Array)[0] == brk and panel != null:
				row = panel.find_child("check_%d" % i, true, false)
		_ok(row != null and row.text.contains("tripped"), "with the tripped breaker on it")
		if row != null:
			await HarnessInput.click(vp, HarnessInput.center_of(row))
			await _settle(tree, 10)
			_ok(str(canvas.get("selected_item_id")) == brk, "a click on the row selects the breaker")
		# The graph's own "tripped" toast stands over the palette for a few
		# seconds; audit once it has gone.
		await tree.create_timer(5.5).timeout
		var audit: Dictionary = UiAudit.run(tree.root)
		print("process-wiring: audit %s" % UiAudit.summary_line(audit))
		for f in audit.get("findings", []):
			if str((f as Dictionary).get("level", (f as Dictionary).get("severity", ""))) == "error":
				print("process-wiring: audit finding %s" % str(f).left(300))
		_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors (%d)" % int(audit.get("errors", 0)))
		await HarnessInput.click(vp, HarnessInput.center_of(cb))
		await _settle(tree, 8)
		# One load off, then reset from the faceplate.
		hub.call("refresh")
		hub.call("command", "node.%s" % kettle, 0.0)
		await _settle(tree, 10)
		var pb := _center(mimic, brk)
		await HarnessInput.mouse_move(vp, pb)
		await _settle(tree, 3)
		await HarnessInput.click(vp, pb)
		await _settle(tree, 10)
		var face: PanelContainer = lens.call("faceplate")
		var reset: Button = face.call("button", "reset") if face != null and face.visible else null
		_ok(reset != null and reset.text == "Reset it", "the breaker's faceplate offers Reset it")
		if reset != null:
			await HarnessInput.click(vp, HarnessInput.center_of(reset))
			await _settle(tree, 70)
		bs = model.get_item(brk).get("specs", {})
		_ok(BreakerTrip.is_closed(bs) and not bool(bs.get("tripped", false)), "reset with one load off, it stays closed (%s)" % BreakerTrip.state_words(bs))
		await HarnessInput.key(vp, KEY_ESCAPE)
		await _settle(tree, 6)

	# ---- the Cable tool ----
	await _tool(vp, tree, lens, "cable")
	_ok(bool((lens.call("layers") as Dictionary).get("data", false)), "arming Cable shows the Network lines")
	lens.call("fit")
	await _settle(tree, 8)
	_ok(not (mimic.call("element_by_id", srv) as Dictionary).is_empty() and not (mimic.call("element_by_id", board) as Dictionary).is_empty(),
		"the unwired server and board wait in the picture")
	await HarnessInput.drag(vp, _center(mimic, srv), _center(mimic, sw), 14)
	await _settle(tree, 16)
	var cabled := false
	for c in model.get_connections_in_scope("root"):
		if ScadaNet.is_data(c) and str(c["source_item_id"]) == srv and str(c["target_item_id"]) == sw:
			cabled = true
	_ok(cabled, "a drag from the server to the switch cables them")
	lens.call("fit")
	await _settle(tree, 8)
	var n_before := model.get_connections_in_scope("root").size()
	await HarnessInput.drag(vp, _center(mimic, heater), _center(mimic, sw), 14)
	await _settle(tree, 12)
	_ok(model.get_connections_in_scope("root").size() == n_before, "a heater is refused (it is not a network device)")
	await HarnessInput.drag(vp, _center(mimic, sw), _center(mimic, board), 14)
	await _settle(tree, 16)
	var board_wire := ""
	for c in model.get_connections_in_scope("root"):
		if ScadaNet.is_data(c) and str(c["source_item_id"]) == sw and str(c["target_item_id"]) == board:
			board_wire = str(c["id"])
	_ok(not board_wire.is_empty(), "the switch to the board")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 40)

	# ---- instruments ----
	lens.call("refresh", true)
	lens.call("fit")
	await _settle(tree, 10)
	var level_bubble := {}
	var relay_bubble := {}
	for e in (mimic.get("doc") as Dictionary).get("elements", []):
		if str(e.get("kind", "")) == "instr" and str(e.get("reads", "")) == tank:
			level_bubble = e
		if str(e.get("kind", "")) == "instr" and str(e.get("reads", "")) == heater:
			relay_bubble = e
	_ok(not level_bubble.is_empty() and str(level_bubble.get("letters", "")) == "LI", "the board's level reading is a bubble on the tank")
	_ok(not relay_bubble.is_empty() and str(relay_bubble.get("letters", "")) == "XY", "its relay is a bubble on the heater")
	if not level_bubble.is_empty():
		var lv: Dictionary = ((mimic.get("state") as Dictionary).get("el", {}) as Dictionary).get(str(level_bubble["id"]), {}) as Dictionary
		print("process-wiring: the level bubble reads '%s'" % str(lv.get("value", "")))
		_ok(not str(lv.get("value", "")).is_empty(), "with its reading")
	var sigs := 0
	for p in (mimic.get("doc") as Dictionary).get("pipes", []):
		if str(p["id"]).begins_with("sig:"):
			sigs += 1
	_ok(sigs >= 2, "and dashed signal lines to the board (%d)" % sigs)
	_shot(main, "03_instruments")

	# ---- an unheard relay refuses ----
	hub.set("_net_key", "")
	hub.call("refresh")
	var heard := str(hub.call("net_fault", board)).is_empty()
	if heard:
		_ok(bool(hub.call("command", "node.%s" % heater, 0.0)), "while the board is heard, the heater switches")
		hub.call("command", "node.%s" % heater, 1.0)
	model.remove_connection(board_wire)
	await _settle(tree, 10)
	hub.set("_net_key", "")
	hub.call("refresh")
	var done := bool(hub.call("command", "node.%s" % heater, 0.0))
	_ok(not done and str(hub.get("last_refusal")).contains("cannot be reached"), "with its cable pulled, the switch is refused (%s)" % str(hub.get("last_refusal")))

	# ---- undo ----
	var n_items := model.get_items_in_scope("root").size()
	await _tool(vp, tree, lens, "valve")
	lens.call("fit")
	await _settle(tree, 6)
	var spot := Vector2(-1, -1)
	for fy in [0.1, 0.5, 0.85]:
		for fx in [0.92, 0.08, 0.7]:
			var lp := Vector2(mimic.size.x * fx, mimic.size.y * fy)
			if spot.x < 0.0 and (mimic.call("pick_element", lp) as Dictionary).is_empty() and (mimic.call("pick_pipe", lp) as Dictionary).is_empty():
				spot = mimic.get_global_transform() * lp
	await HarnessInput.mouse_move(vp, spot)
	await _settle(tree, 3)
	await HarnessInput.click(vp, spot)
	await _settle(tree, 14)
	_ok(model.get_items_in_scope("root").size() == n_items + 1, "a valve set down")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 4)
	await HarnessInput.key(vp, KEY_Z, true)
	await _settle(tree, 14)
	_ok(model.get_items_in_scope("root").size() == n_items, "one Ctrl+Z takes it back")

	# ---- clean up ----
	lens.call("set_layers_data", ["pipes"])
	lens.call("refresh", true)
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and not pid.is_empty():
		loader.call("delete_prop_by_id", pid)
	await _settle(tree, 6)
	for it in model.get_items_in_scope("root").duplicate():
		if not ids0.has(str(it["id"])):
			model.remove_item(str(it["id"]))
	view.call("close_graph_view")
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
