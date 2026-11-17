extends RefCounted

## SCADA Phase 1 on a real world (sandbox): the tag list, its history, the
## browser and the timeline's tag track.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/scada_tags_check.gd -Label scada_tags
## - the graph view owns a ScadaHub; a refresh lists the world's tanks,
##   machines and site power as tags, and its cost is printed;
## - the automation context still carries every tank key, from the same ids;
## - a seeded tank + load: the tank's level tag follows the tank, a switch
##   command turns the load off and on (through its proxy);
## - history: values recorded as the clock runs, a scrub back drops the
##   future;
## - Graph → View options → Tags… opens the browser; typing narrows it; a
##   REAL click on "Add to timeline" adds a tag track whose lane fills;
##   UiAudit on the open window; Esc closes.
## Removes what it seeded. Shots under screenshots/scada_tags/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/scada_tags"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var view: Node = ServiceLocator.graph()
	var hub: Node = view.call("scada_hub") if view != null and view.has_method("scada_hub") else null
	_ok(hub != null, "the graph view owns a ScadaHub")
	if hub == null:
		return {"ok": false, "fails": _fails}
	var model: GraphModel = view.get("model")

	# ---- seed a tank and a load ----
	var tank_id := "scada_test_tank"
	var load_id := "scada_test_load"
	model.add_item({"id": tank_id, "type": "resource", "x": 60.0, "y": 60.0, "width": 120.0, "height": 120.0,
		"specs": {"name": "Scada Test Tank", "resource_kind": "water", "capacity_qty": 500.0,
		"capacity_unit": "L", "level": 0.25}})
	model.add_item({"id": load_id, "type": "appliance", "x": 260.0, "y": 60.0, "width": 160.0, "height": 100.0,
		"specs": {"name": "Scada Test Load", "avg_watts": 40.0, "rated_watts": 40.0,
		"requested_state": "on", "current_state": "on"}})
	await _settle(tree, 6)

	var t0 := Time.get_ticks_usec()
	hub.call("refresh")
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var book: ScadaTags = hub.call("book")
	var n_tanks := 0
	var n_switch := 0
	for t: Dictionary in book.all():
		if str(t["id"]).begins_with("tank.") and str(t["id"]).ends_with(".level"):
			n_tanks += 1
		if str(t["kind"]) == ScadaTags.KIND_SWITCH:
			n_switch += 1
	print("scada-check: %d tags (%d tank levels, %d switches) gathered in %.2f ms" % [book.all().size(), n_tanks, n_switch, ms])
	_ok(n_tanks >= 1 and n_switch >= 1, "the world's tanks and machines are tags")
	_ok(ms < 20.0, "a refresh costs under 20 ms (%.2f)" % ms)
	_ok(book.has("sensor.battery_level"), "site power is on the list")
	_ok(absf(book.value("tank.%s.level" % tank_id) - 25.0) < 0.6, "the seeded tank reads 25 %% (%.1f)" % book.value("tank.%s.level" % tank_id))

	# ---- the automation context agrees ----
	var ctx: Dictionary = view.call("get_automation_resource_context")
	var num: Dictionary = ctx.get("numeric_values", {})
	_ok(num.has("tank.%s.level" % tank_id) and absf(float(num["tank.%s.level" % tank_id]) - book.value("tank.%s.level" % tank_id)) < 0.6,
		"the automation context carries the same key and value")
	_ok(num.has("tank.scada_test_tank.level"), "and its name alias")

	# ---- command ----
	var sw := "node.%s" % load_id
	_ok(bool(book.tag(sw).get("writable", false)) and book.value(sw) == 1.0, "the load's switch tag is on and writable")
	var rev0: int = model.user_rev
	_ok(bool(hub.call("command", sw, 0.0)), "a command is accepted")
	await _settle(tree, 4)
	hub.call("refresh")
	var sp: Dictionary = model.get_item(load_id).get("specs", {})
	_ok(str(sp.get("requested_state", sp.get("current_state", ""))) == "off" and book.value(sw) == 0.0,
		"…and the load is off on the graph and in the tag")
	_ok(model.user_rev != rev0, "a command is a player's edit (pre-rendered futures are dropped)")
	hub.call("command", sw, 1.0)
	await _settle(tree, 4)
	hub.call("refresh")
	_ok(book.value(sw) == 1.0, "switched back on")
	_ok(not bool(hub.call("command", "tank.%s.level" % tank_id, 50.0)), "a sensor refuses a command")

	# ---- history on the sim clock ----
	var hist: ScadaHistorian = hub.call("history")
	var lvl_tag := "tank.%s.level" % tank_id
	var h0 := float(hub.call("now_h"))
	main.set("time_scale", 0.0)
	for step in 6:
		main.call("set_absolute_hours", h0 + 0.25 * float(step + 1))
		var item := model.get_item(tank_id)
		var s2: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		s2["level"] = 0.25 + 0.1 * float(step + 1)
		view.call("_begin_sim_writes")
		model.update_item(tank_id, {"specs": s2})
		view.call("_end_sim_writes")
		await _settle(tree, 2)
		hub.call("refresh")
	_ok(hist.size(lvl_tag) >= 6, "the tank's level was recorded as the clock moved (%d samples)" % hist.size(lvl_tag))
	_ok(absf(hist.value_at(lvl_tag, h0 + 0.8) - 55.0) < 1.5, "the value held at +0.8 h is the one set at +0.75 h (%.1f)" % hist.value_at(lvl_tag, h0 + 0.8))
	main.call("set_absolute_hours", h0 + 0.6)
	await _settle(tree, 2)
	hub.call("refresh")
	var rng := hist.range_of(lvl_tag)
	_ok(rng[1] <= h0 + 0.6 + 1e-6, "a scrub back drops the future")
	main.call("set_absolute_hours", h0 + 1.5)
	await _settle(tree, 2)
	hub.call("refresh")

	# ---- the browser, through the graph's menu ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	var br: Node = view.call("open_tag_browser")
	await _settle(tree, 10)
	_ok(br != null and bool(br.call("is_open")), "Tags… opens the browser")
	var all_rows: int = (br.call("rows") as Array).size()
	br.call("set_search", "scada test")
	await _settle(tree, 4)
	var rows: Array = br.call("rows")
	_ok(rows.size() >= 3 and rows.size() < all_rows and rows.has(lvl_tag), "typing narrows the list to the seeded nodes (%d of %d)" % [rows.size(), all_rows])
	_shot(main, "01_browser")
	var audit: Dictionary = UiAudit.run(tree.root)
	var errs := int(audit.get("errors", 0))
	print("scada-check: audit %s" % UiAudit.summary_line(audit))
	_ok(errs == 0, "UiAudit finds no errors on the open browser (%d)" % errs)
	var btn: Button = br.call("row_button", lvl_tag, "track")
	_ok(btn != null and btn.is_visible_in_tree(), "the row has Add to timeline")
	if btn != null:
		await HarnessInput.click(tree.root, HarnessInput.center_of(btn))
		await _settle(tree, 6)
	var tl: Node = ServiceLocator.timeline_ui()
	var layout: Variant = tl.get("_track_layout")
	var td: TimelineTrackDef = null
	for t in layout.get("tracks"):
		if t is TimelineTrackDef and (t as TimelineTrackDef).source == "tag" and (t as TimelineTrackDef).channel == lvl_tag:
			td = t
	_ok(td != null, "a REAL click added the tag track")
	_ok(bool(hub.call("is_watched", lvl_tag)), "…and the tag is now kept long and saved")
	await HarnessInput.key(tree.root, KEY_ESCAPE)
	await _settle(tree, 6)
	_ok(not is_instance_valid(br) or not bool(br.call("is_open")), "Esc closes the browser")
	view.call("close_graph_view")
	await _settle(tree, 10)
	var tv: Variant = tl.get("_track_view")
	tv.set("follow_playhead", false)
	tv.call("set_span", 6.0)
	tv.set("start", h0 - 1.0)
	(tl.get("_track") as CanvasItem).queue_redraw()
	await _settle(tree, 20)
	if td != null:
		var cache: Dictionary = tl.get("_waveform_cache")
		var bins: Dictionary = (cache.get(td.id, {}) as Dictionary).get("bins", {})
		var me: PackedFloat32Array = bins.get("mean", PackedFloat32Array())
		var finite := 0
		for v in me:
			if not is_nan(v):
				finite += 1
		_ok(finite >= 3, "the lane is filled from the history (%d bins)" % finite)
	_shot(main, "02_track")

	# ---- save file ----
	hub.call("flush_world_state")
	var path := str(hub.get("_save_path"))
	_ok(not path.is_empty() and FileAccess.file_exists(path), "the watched history is saved with the world")

	# ---- clean up ----
	if td != null:
		layout.call("remove_track", td.id)
		tl.call("_tracks_changed")
	hub.call("unwatch", lvl_tag)
	model.remove_item(tank_id)
	model.remove_item(load_id)
	main.call("set_absolute_hours", h0)
	return {"ok": _fails.is_empty(), "fails": _fails}
