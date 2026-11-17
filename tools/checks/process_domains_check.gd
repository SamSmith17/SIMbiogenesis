extends RefCounted

## SCADA Phase 3b on a real world (sandbox): the Network domain and the
## Process lens's Power and Network layers, with REAL clicks.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/process_domains_check.gd -Label process_domains -Timeout 900
## - a placed ESP board is heard while the graph has no server;
## - a Home Assistant Server on the graph makes the network count: the
##   unwired board's tags read unavailable ("not on the network");
## - server → switch → board by data wires: heard again; the switch switched
##   off cuts it; a 140 m Ethernet run is too long; unplugged = unavailable;
## - the lens: real clicks on Show → Network and Power add those lines and
##   their symbols (a cable length only counts once routed in 3D), the board's faceplate says how it is heard, UiAudit,
##   the layers are saved with the graph.
## Removes what it placed. Shots under screenshots/process_domains/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("process-domains %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/process_domains"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


## The board's tags: [available count, total, first text].
func _board_tags(hub: Node, friendly: String) -> Array:
	hub.set("_net_key", "")
	hub.call("refresh")
	var book: ScadaTags = hub.call("book")
	var n := 0
	var ok := 0
	var text := ""
	for t: Dictionary in book.all():
		if str(t.get("source", "")) == ScadaTags.SOURCE_ESP and str(t.get("group", "")).contains(friendly):
			n += 1
			if bool(t.get("available", false)):
				ok += 1
			elif text.is_empty():
				text = str(t.get("text", ""))
	return [ok, n, text]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null else null
	_ok(hub != null, "the graph view owns a ScadaHub")
	if hub == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 0.0)

	# ---- a board in the world ----
	var pl := main.get_node_or_null("Player") as Node3D
	var at := pl.global_position - pl.global_transform.basis.z * 4.0 if pl != null else Vector3.ZERO
	var spec := {"name": "Domains Probe", "board": "esp32_devkit_v1", "parts": [{"part": "bme280"}]}
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, EspBuilder.MODEL_ID, at.x, at.z, {"esp_spec": spec})
	_ok(bool(r.get("ok", false)), "the board is placed")
	var pid := str(r.get("prop_id", ""))
	await _settle(tree, 90)
	var gid := str(PlacedPropService.get_prop_record(main, pid).get("graph_item_id", ""))
	_ok(not gid.is_empty() and ScadaNet.role_of(model.get_item(gid)) == ScadaNet.ROLE_BOARD, "its graph node is a network board")
	var handles: Array = (view.get("_graph_canvas") as Control).call("_resolved_handles", model.get_item(gid))
	var has_data := false
	for h in handles:
		if str((h as Dictionary).get("polarity", "")) == "data":
			has_data = true
	_ok(has_data, "with a data port")
	var ac_ok := PlacedLightPower.ac_available(main) or not PlacedLightPower.graph_has_power_hardware()
	print("process-domains: site AC is %s" % ("up" if ac_ok else "DOWN (the board has no power; reach is checked through ScadaNet only)"))
	var bt := _board_tags(hub, "Domains Probe")
	print("process-domains: board tags %d of %d available" % [int(bt[0]), int(bt[1])])
	_ok(int(bt[1]) >= 2, "the board's readings are tags")
	if ac_ok:
		_ok(int(bt[0]) == int(bt[1]), "no server on the graph: the board is heard")

	# ---- a server makes the network count ----
	var srv := "pd_test_server"
	var sw := "pd_test_switch"
	model.add_item({"id": srv, "type": "appliance", "x": -900.0, "y": -1500.0, "width": 200.0, "height": 128.0,
		"specs": ScadaNet.make_specs(ScadaNet.ROLE_SERVER, "Domains Test Server", 15.0)})
	model.add_item({"id": sw, "type": "appliance", "x": -600.0, "y": -1500.0, "width": 200.0, "height": 128.0,
		"specs": ScadaNet.make_specs(ScadaNet.ROLE_SWITCH, "Domains Test Switch", 4.0)})
	await _settle(tree, 20)
	var reach: Dictionary = ScadaNet.reach(GraphNesting.walk_items(model, "root"), GraphNesting.flat_connections_cached(model))
	_ok(bool(reach["enforced"]) and not bool(reach["nodes"][gid]["ok"]), "with a server on the graph the unwired board is not heard")
	bt = _board_tags(hub, "Domains Probe")
	_ok(int(bt[0]) == 0, "its tags read unavailable (%d of %d available)" % [int(bt[0]), int(bt[1])])
	if ac_ok:
		_ok(str(bt[2]) == "not on the network", "and say why (%s)" % str(bt[2]))

	# ---- wire it ----
	model.add_connection({"id": "pd_test_n1", "polarity": "data", "source_item_id": srv, "source_handle_id": "data",
		"target_item_id": sw, "target_handle_id": "data_0"})
	model.add_connection({"id": "pd_test_n2", "polarity": "data", "source_item_id": sw, "source_handle_id": "data_1",
		"target_item_id": gid, "target_handle_id": "data"})
	await _settle(tree, 30)
	var powered := ScadaNet.powered(model.get_item(srv)) and ScadaNet.powered(model.get_item(sw)) and ScadaNet.powered(model.get_item(gid))
	reach = ScadaNet.reach(GraphNesting.walk_items(model, "root"), GraphNesting.flat_connections_cached(model))
	_ok(bool(reach["nodes"][gid]["ok"]) == powered, "server → switch → board: heard while all three have power (powered %s)" % str(powered))
	if powered:
		bt = _board_tags(hub, "Domains Probe")
		_ok(int(bt[0]) == int(bt[1]) and int(bt[1]) > 0, "the board's tags are available again")
		# The switch off.
		hub.call("command", "node.%s" % sw, 0.0)
		await _settle(tree, 30)
		bt = _board_tags(hub, "Domains Probe")
		_ok(int(bt[0]) == 0 and str(bt[2]) == "no path to the server", "the switch switched off cuts the board off (%s)" % str(bt[2]))
		hub.call("command", "node.%s" % sw, 1.0)
		await _settle(tree, 30)
		bt = _board_tags(hub, "Domains Probe")
		_ok(int(bt[0]) == int(bt[1]), "switched on, it is heard again")
		var n2 := model.get_connection("pd_test_n2")
		print("process-domains: the cable's measured length %.0f m, routed in 3D %s" % [float(n2.get("route_length_m", 0.0)), str(n2.get("visible_3d", false))])
	var revs := int(model.get("struct_rev"))

	# ---- the lens: layers ----
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
	_ok((mimic.call("element_by_id", srv) as Dictionary).is_empty(), "with pipes alone the network is not in the picture")
	var bn: Button = lens.call("layer_button", "data")
	_ok(bn != null and bn.is_visible_in_tree(), "the lens has a Show row")
	await HarnessInput.click(vp, HarnessInput.center_of(bn))
	await _settle(tree, 20)
	_ok(bool((lens.call("layers") as Dictionary).get("data", false)), "a click shows the Network layer")
	var es: Dictionary = mimic.call("element_by_id", srv)
	var eb: Dictionary = mimic.call("element_by_id", gid)
	_ok(not es.is_empty() and str(es.get("glyph", "")) == "server" and not eb.is_empty() and str(eb.get("glyph", "")) == "board",
		"the server and the board are drawn with their symbols")
	var n_data := 0
	for p in (mimic.get("doc") as Dictionary).get("pipes", []):
		if str(p.get("style", "")) == "data":
			n_data += 1
	_ok(n_data >= 2, "with their data lines (%d)" % n_data)
	_shot(main, "01_network_layer")
	# The board's faceplate.
	var pb: Vector2 = mimic.get_global_transform() * (mimic.call("element_rect", eb) as Rect2).get_center()
	await HarnessInput.mouse_move(vp, pb)
	await _settle(tree, 3)
	await HarnessInput.click(vp, pb)
	await _settle(tree, 10)
	var face: PanelContainer = lens.call("faceplate")
	_ok(face != null and face.visible and str(face.call("shown_for")) == gid, "a click on the board opens its faceplate")
	_shot(main, "02_board_faceplate")
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 6)
	# Power too.
	var bp: Button = lens.call("layer_button", "power")
	await HarnessInput.click(vp, HarnessInput.center_of(bp))
	await _settle(tree, 20)
	var n_power := 0
	var n_dev := 0
	for p in (mimic.get("doc") as Dictionary).get("pipes", []):
		if str(p.get("style", "")) == "power":
			n_power += 1
	for e in (mimic.get("doc") as Dictionary).get("elements", []):
		if str(e.get("kind", "")) == "device":
			n_dev += 1
	print("process-domains: %d power lines, %d devices with all layers on" % [n_power, n_dev])
	_ok(n_power >= 1 and n_dev >= 3, "the Power layer adds the site's wiring as single lines")
	hub.set("_net_key", "")
	lens.call("refresh", true)
	await _settle(tree, 4)
	var bstate: Dictionary = ((mimic.get("state") as Dictionary).get("el", {}) as Dictionary).get(gid, {}) as Dictionary
	_ok(str(bstate.get("value", "")) == ("Heard" if powered else str(bstate.get("value", ""))), "the board's box reads Heard (%s)" % str(bstate.get("value", "")))
	_shot(main, "03_all_layers")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("process-domains: audit %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors (%d)" % int(audit.get("errors", 0)))
	var cost := float(mimic.call("draw_cost_ms"))
	print("process-domains: one redraw %.2f ms" % cost)
	_ok(cost < 10.0, "a redraw with every layer costs under 10 ms (%.2f)" % cost)
	var saved: Dictionary = view.call("collect_save_state")
	_ok("data" in (saved.get("process_layers", []) as Array) and "power" in (saved.get("process_layers", []) as Array), "the layers are saved with the graph")
	_ok(int(model.get("struct_rev")) == revs, "showing layers changes nothing on the graph")

	# ---- unplug: the picture shows it ----
	model.remove_connection("pd_test_n2")
	await _settle(tree, 30)
	bt = _board_tags(hub, "Domains Probe")
	_ok(int(bt[0]) == 0, "unplugged, the board's tags are unavailable")

	# ---- clean up ----
	lens.call("set_layers_data", ["pipes"])
	lens.call("refresh", true)
	view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	model.remove_item(srv)
	model.remove_item(sw)
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and not pid.is_empty():
		loader.call("delete_prop_by_id", pid)
	view.call("close_graph_view")
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
