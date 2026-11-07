extends RefCounted

## The TC Process Lab's Process mode on a real world (sandbox; writes
## nothing to the player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tc_process_check.gd -Label tc_process
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tc_process_check.gd -Label tc_process_720 -UserArgs @("--window-size=1280x720")
## Opens the tri-clamp designer through Main on the biochar reactor and, with
## REAL input: the Process button swaps the columns, Play runs the lab clock
## (the world's clock untouched), Pause, "Run the whole batch" computes the
## batch in frame chunks, the chart is clicked to scrub to 1 h and 3 h
## (drying, then char), a condenser clicked in the studio is the selected
## volume, an element's watts edited restarts the run, UiAudit is clean in
## Process mode, and Design brings the design columns back.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("tc_process %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _reveal(c: Control, tree: SceneTree) -> void:
	var n: Node = c.get_parent()
	while n != null and not (n is ScrollContainer):
		n = n.get_parent()
	if n != null:
		(n as ScrollContainer).ensure_control_visible(c)
	await tree.process_frame
	await tree.process_frame


func _click_named(ui: Control, vp: Viewport, tree: SceneTree, name: String) -> bool:
	var b := ui.find_child(name, true, false) as Control
	if b == null or not b.is_visible_in_tree():
		return false
	await _reveal(b, tree)
	await HarnessInput.click(vp, HarnessInput.center_of(b))
	await _settle(tree, 3)
	return true


func modal_studio_rect(ui: Control) -> Rect2:
	return (ui.call("studio") as StudioViewport).container.get_global_rect()


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var ui: Control = main.call("open_tclab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false, "failures": _fails}
	var vp := main.get_viewport()
	ui.call("load_builtin", "biochar_reactor")
	await _settle(tree, 8)
	var world_t0 := float(main.call("get_absolute_hours")) if main.has_method("get_absolute_hours") else 0.0
	var world_scale := float(main.get("time_scale"))

	# Process mode by its button.
	_ok(await _click_named(ui, vp, tree, "mode_process"), "the Process button is there")
	_ok(bool(ui.call("is_process_mode")), "Process mode is on")
	var panel: Node = ui.call("process_panel")
	var dl := ui.find_child("design_left", true, false) as Control
	var pl := ui.find_child("process_left", true, false) as Control
	# Own visibility: below 1600 px the left column folds into a flyout.
	_ok(dl != null and not dl.visible and pl != null and pl.visible, "the columns swap to the process ones")
	var sim: TcProcSim = panel.get("sim")
	_ok(sim != null and sim.bed != null and sim.bed.domains.size() == 2, "the reactor's charge sits round its two elements")
	await _shot(main, "00_process_start")

	# Play, by the button.
	_ok(await _click_named(ui, vp, tree, "proc_play"), "the Play button is there")
	_ok(bool(panel.get("playing")), "Play runs the lab clock")
	await _settle(tree, 90)
	var t_play := float(panel.call("time_h"))
	_ok(t_play > 0.01, "the process advanced (%.3f h)" % t_play)
	await _click_named(ui, vp, tree, "proc_play")
	_ok(not bool(panel.get("playing")), "Pause stops it")
	var world_t1 := float(main.call("get_absolute_hours")) if main.has_method("get_absolute_hours") else 0.0
	_ok(absf(float(main.get("time_scale")) - world_scale) < 1e-9, "the world's clock speed is untouched")
	_ok(world_t1 - world_t0 < t_play, "the lab ran on its own clock, not the world's")

	# The whole batch.
	_ok(await _click_named(ui, vp, tree, "proc_prerun"), "the Run-the-whole-batch button is there")
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while bool(panel.get("prerunning")) and frames < 6000:
		await tree.process_frame
		frames += 1
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	var proc: Dictionary = panel.get("proc")
	var done_h := float(panel.get("done_s")) / 3600.0
	print("tc_process: batch of %.1f h computed in %.1f s over %d frames" % [done_h, secs, frames])
	_ok(not bool(panel.get("prerunning")) and done_h >= float(proc["duration_h"]) - 0.01, "the whole batch is computed (%.1f h)" % done_h)
	_ok((panel.get("history") as Array).size() >= int(float(proc["duration_h"]) * 50.0), "with a sample a minute for the chart")
	var ids := {}
	for e in panel.get("run_events"):
		ids[str(e["id"])] = true
	_ok(ids.has("drying") and ids.has("pyrolysis") and ids.has("gas_out"), "the event log tells the story (%s)" % [ids.keys()])
	var ev := ui.find_child("events", true, false) as ItemList
	await _settle(tree, 40)
	_ok(ev != null and ev.item_count == (panel.get("run_events") as Array).size(), "the events are listed")

	# Scrub on the chart: 1 h, then 3 h.
	var chart := ui.find_child("chart", true, false) as Control
	_ok(chart != null and chart.is_visible_in_tree(), "the chart is shown")
	if chart != null:
		await _reveal(chart, tree)
		var r: Rect2 = chart.get_global_rect()
		var plot_l: float = r.position.x + 44.0
		var plot_w: float = r.size.x - 44.0 - 8.0
		for want in [1.0, 3.0]:
			var x: float = plot_l + float(want) / float(proc["duration_h"]) * plot_w
			await HarnessInput.click(vp, Vector2(x, r.position.y + r.size.y * 0.5))
			await _settle(tree, 6)
			var th := float(panel.call("time_h"))
			_ok(absf(th - want) < 0.1, "a click on the chart scrubs to %.0f h (%.2f h)" % [want, th])
			await _shot(main, "01_at_%.0fh" % want)
		var rd: Dictionary = panel.call("readings")
		_ok(float(rd.get("char_kg", 0.0)) > 0.5, "by 3 h there is char (%.2f kg)" % float(rd.get("char_kg", 0.0)))
		var tile := ui.find_child("tile_char", true, false) as Label
		_ok(tile != null and tile.text != "â€”", "the Char tile reads it (%s)" % (tile.text if tile != null else "none"))

	# Click a condenser in the studio.
	var p11: Vector2 = ui.call("part_pos", "p11")
	var studio: StudioViewport = ui.call("studio")
	if p11.x >= 0.0:
		await HarnessInput.click(vp, studio.container.get_global_rect().position + p11)
		await _settle(tree, 6)
	var want_cv := TcProcNet.cv_of_part(sim.net, "p11", "product")
	_ok(int(panel.get("sel_cv")) == want_cv, "a click on a condenser selects its volume (%d vs %d)" % [int(panel.get("sel_cv")), want_cv])
	await _shot(main, "02_condenser_selected")

	# The tint shows the hot vessel.
	var b: TcBuilder = ui.call("builder")
	var vnode := b.get_node_or_null("P_p1") as GeometryInstance3D
	var tint: Variant = vnode.get_instance_shader_parameter("tint") if vnode != null else null
	_ok(vnode != null and (vnode.material_overlay != null or (tint is Color and (tint as Color).a > 0.05)), "the hot vessel is tinted by its temperature")

	# Seeing inside (Phase 4): the views, mid-batch while it pyrolyses.
	var view: Node3D = panel.get("view")
	_ok(view != null, "the process view is made")
	if view != null:
		panel.call("seek_h", 2.2)
		panel.call("select_cv", sim.vessel_cv)
		await _settle(tree, 12)
		var ds: Dictionary = view.call("debug_state")
		print("tc_process: view %s" % [ds])
		_ok(str(ds["mode"]) == "section" and bool(ds["contents_visible"]), "the section view is the default, contents shown")
		_ok(int(ds["gas_tubes"]) >= 6, "gas drawn along the pipework (%d tubes)" % int(ds["gas_tubes"]))
		_ok(bool(ds["has_bed"]), "the charge is drawn")
		var cplane: Vector4 = ds["plane"]
		_ok(absf(cplane.w) < 100.0 and Vector3(cplane.x, cplane.y, cplane.z).length() > 0.9, "the section plane is set (%s)" % [cplane])
		var vmi := b.get_node_or_null("P_p1") as MeshInstance3D
		var sect_ok := vmi != null and vmi.get_surface_override_material(0) is ShaderMaterial
		_ok(sect_ok, "the vessel wears the section material")
		panel.call("play", true)
		await _settle(tree, 40)
		ds = view.call("debug_state")
		_ok((ds["emitting"] as Array).size() >= 1, "vapour / plume / drips emit while it runs (%s)" % [ds["emitting"]])
		panel.call("play", false)
		await _shot(main, "04_section_pyrolysis")
		# The cut follows a clicked condenser.
		if p11.x >= 0.0:
			await HarnessInput.click(vp, studio.container.get_global_rect().position + p11)
			await _settle(tree, 8)
			await _shot(main, "05_section_condenser")
		_ok(await _click_named(ui, vp, tree, "view_xray"), "the X-ray button is there")
		ds = view.call("debug_state")
		_ok(str(ds["mode"]) == "xray" and absf((ds["plane"] as Vector4).w) > 1.0e5, "X-ray: no cut, ghosted steel")
		await _settle(tree, 6)
		await _shot(main, "06_xray")
		_ok(await _click_named(ui, vp, tree, "view_solid"), "the Solid button is there")
		ds = view.call("debug_state")
		_ok(str(ds["mode"]) == "solid" and not bool(ds["contents_visible"]), "Solid hides the contents")
		_ok(vmi != null and is_instance_valid(vmi) and vmi.get_surface_override_material(0) == null, "and puts the built materials back")
		await _click_named(ui, vp, tree, "view_section")

	# The molecule lens (Phase 6): the vessel mid-batch, then a condenser.
	_ok(await _click_named(ui, vp, tree, "view_molecules"), "the Molecules box is there")
	var lens: Control = panel.get("lens")
	_ok(lens != null and lens.is_visible_in_tree(), "the lens opens over the studio")
	if lens != null:
		panel.call("seek_h", 2.2)
		panel.call("select_cv", sim.vessel_cv)
		panel.call("play", true)
		await _settle(tree, 240)
		panel.call("play", false)
		var ls: Dictionary = lens.call("debug_state")
		print("tc_process: lens %s" % [ls])
		var by: Dictionary = ls["by"]
		var solid := 0
		var gas := 0
		for k in by.keys():
			if str(k).ends_with("@solid"):
				solid += int(by[k])
			elif str(k).ends_with("@gas"):
				gas += int(by[k])
		_ok(solid >= 6, "the vessel shows its charge as molecules (%d units)" % solid)
		_ok(by.has("char@solid"), "some of it already char at 2.2 h")
		_ok(gas >= 8, "and its gas (%d molecules, fewer when they are big)" % gas)
		_ok(int(ls["shown_stories"]) >= 1, "a reaction played (%d)" % int(ls["shown_stories"]))
		_ok(int(ls["atoms"]) > 100 and int(ls["bonds"]) > 50, "drawn ball and stick (%d atoms, %d bonds)" % [int(ls["atoms"]), int(ls["bonds"])])
		var sr := (modal_studio_rect(ui))
		_ok(sr.encloses(lens.get_global_rect().grow(-1.0)), "the lens sits inside the studio")
		await _shot(main, "09_lens_vessel")
		var cond := TcProcNet.cv_of_part(sim.net, "p11", "product")
		panel.call("select_cv", cond)
		panel.call("play", true)
		await _settle(tree, 120)
		panel.call("play", false)
		ls = lens.call("debug_state")
		print("tc_process: lens condenser %s" % [ls])
		_ok(int(ls["cv"]) == cond, "the lens follows the selected volume")
		await _shot(main, "10_lens_condenser")
		_ok(await _click_named(ui, vp, tree, "view_molecules"), "Molecules off")
		_ok(panel.get("lens") == null, "and the lens is gone (it costs nothing while off)")

	# Control (Phase 5b): sensors, switches, automations, all by real clicks.
	_ok(await _click_named(ui, vp, tree, "right_control"), "the Control tab is there")
	var cbox := ui.find_child("control_box", true, false) as Control
	_ok(cbox != null and cbox.is_visible_in_tree(), "it shows the control column")
	var slist := ui.find_child("sensor_list", true, false) as GridContainer
	_ok(slist != null and slist.get_child_count() >= 24, "the design's sensors are listed (%d)" % (slist.get_child_count() / 2 if slist != null else 0))
	var cards := ui.find_child("automation_cards", true, false) as Control
	var preset: MenuButton = null
	if cards != null:
		for n in cards.find_children("*", "MenuButton", true, false):
			if (n as MenuButton).text.begins_with("+ Preset"):
				preset = n
	_ok(preset != null, "the automation presets are offered")
	if preset != null:
		await _reveal(preset, tree)
		# A MenuButton opens on PRESS and picks the item under a release (drag
		# to select): a scripted click's release lands on whatever item opens
		# under the cursor. Open it, then pick by id.
		preset.show_popup()
		await _settle(tree, 3)
		var pop := preset.get_popup()
		pop.hide()
		pop.id_pressed.emit(0)   # "Hold the charge near 450 °C" (the editor rebuilds: the menu goes)
		await _settle(tree, 6)
	var sp2: Dictionary = ui.call("spec")
	var autos: Array = (sp2.get("process", {}) as Dictionary).get("automations", [])
	_ok(autos.size() == 2, "the preset's two rules are on the design (%d)" % autos.size())
	var sim2: TcProcSim = panel.get("sim")
	_ok(sim2 != null and sim2.automations != null and sim2.automations.rules.size() == 2, "and run in the model")
	_ok(await _click_named(ui, vp, tree, "proc_prerun"), "pre-run with the rules")
	var fr := 0
	while bool(panel.get("prerunning")) and fr < 6000:
		await tree.process_frame
		fr += 1
	var autos_ev := 0
	for e in panel.get("run_events"):
		if str(e["id"]) == "auto":
			autos_ev += 1
	var peak := 0.0
	for h in panel.get("history"):
		peak = maxf(peak, float(h["bed_max"]))
	print("tc_process: with the hold rules %d switches, hottest charge %.0f °C" % [autos_ev, peak])
	_ok(autos_ev >= 4, "the rules switched the elements (%d times)" % autos_ev)
	_ok(peak < 620.0, "and held the charge well under a free run's ~860 °C (%.0f)" % peak)
	await _settle(tree, 20)
	await _shot(main, "07_control")
	# A switch by hand.
	panel.call("seek_h", 1.0)
	await _settle(tree, 4)
	sim2 = panel.get("sim")
	var slug := TcProcControl.design_slug(ui.call("design"))
	var sw_name := "act_switch_%s_p2" % slug
	var was_on := TcProcControl.is_on(sim2, "heater:p2")
	_ok(await _click_named(ui, vp, tree, sw_name), "the element's switch is there")
	_ok(TcProcControl.is_on(sim2, "heater:p2") != was_on, "clicking it switches the element in the run (was %s)" % ("on" if was_on else "off"))
	var man := false
	for e2 in sim2.events:
		if str(e2["id"]) == "manual":
			man = true
	_ok(man, "and the log says it was done by hand")
	# A probe on the selected volume.
	panel.call("select_cv", sim2.vessel_cv)
	var n_sens := sim2.control_sensors.size()
	_ok(await _click_named(ui, vp, tree, "proc_add_probe"), "the Add probe button is there")
	var sim3: TcProcSim = panel.get("sim")
	_ok(sim3.control_sensors.size() == n_sens + 1, "a probe becomes a sensor (%d → %d)" % [n_sens, sim3.control_sensors.size()])
	# Home Assistant YAML.
	_ok(await _click_named(ui, vp, tree, "proc_ha_yaml"), "the YAML button is there")
	var clip := DisplayServer.clipboard_get()
	_ok(clip.contains("trigger: numeric_state") and clip.contains("switch.turn_off"), "the rules are on the clipboard as HA YAML")
	var audit2 := UiAudit.run(vp)
	print("tc_process: control ui audit — %s" % UiAudit.summary_line(audit2))
	_ok(int(audit2.get("errors", 0)) == 0, "the Control tab audits clean")
	await _shot(main, "08_control_after")
	await _click_named(ui, vp, tree, "right_readings")
	sim = panel.get("sim")

	# Edit an element's watts: the run restarts and the spec carries it.
	var spin_row := ui.find_child("proc_w_p2", true, false)
	_ok(spin_row is SpinBox, "the element's watts are editable")
	if spin_row is SpinBox:
		(spin_row as SpinBox).value = 450.0
		await _settle(tree, 4)
		var sp: Dictionary = ui.call("spec")
		var hw := float((((sp.get("process", {}) as Dictionary).get("heaters", {}) as Dictionary).get("by_part", {}) as Dictionary).get("p2", {}).get("w", 0.0))
		_ok(absf(hw - 450.0) < 1e-6, "the design keeps the element's 450 W")
		_ok(float(panel.call("time_h")) < 1e-6, "and the run starts again")

	# UiAudit in Process mode.
	var audit := UiAudit.run(vp)
	print("tc_process: ui audit â€” %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "Process mode audits clean")
	await _shot(main, "03_process_ui")

	# Back to Design.
	_ok(await _click_named(ui, vp, tree, "mode_design"), "the Design button is there")
	_ok(not bool(ui.call("is_process_mode")) and dl.visible and not pl.visible, "Design brings the design columns back")
	ui.call("close")
	await _settle(tree, 4)

	# Use this run on the graph (Phase 7): a placed reactor, the designer
	# opened on it, the batch fitted onto its node by a real click.
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position if player != null else Vector3.ZERO
	var placed := PlacedPropService.place_model_at_xz(main, "tclab_biochar_reactor", at.x + 6.0, at.z + 6.0)
	await _settle(tree, 20)
	var pid := str(placed.get("prop_id", ""))
	var rec := PlacedPropService.get_prop_record(main, pid)
	var gid := str(rec.get("graph_item_id", ""))
	_ok(not pid.is_empty() and not gid.is_empty(), "a placed reactor has its graph node (%s)" % gid)
	if not gid.is_empty():
		var sgv: Node = ServiceLocator.graph()
		var model: Object = sgv.get("model")
		var before: Dictionary = (model.call("get_item", gid) as Dictionary).get("specs", {})
		_ok(not bool(before.get("batch_mode", false)), "before: the preset's fixed rates")
		ui = main.call("open_tclab", {"prop_id": pid})
		await _settle(tree, 12)
		await _click_named(ui, vp, tree, "mode_process")
		panel = ui.call("process_panel")
		_ok(await _click_named(ui, vp, tree, "proc_use_run"), "the Use-this-run button is there")
		var fr2 := 0
		while bool(panel.get("prerunning")) and fr2 < 6000:
			await tree.process_frame
			fr2 += 1
		await _settle(tree, 6)
		var sp3: Dictionary = ui.call("spec")
		var rcp: Dictionary = (sp3.get("process", {}) as Dictionary).get("recipe", {})
		_ok(not rcp.is_empty(), "the batch is fitted onto the design")
		var after: Dictionary = (model.call("get_item", gid) as Dictionary).get("specs", {})
		print("tc_process: node after %s" % str(after.get("tc_summary", {})))
		_ok(bool(after.get("batch_mode", false)) and str(after.get("selected_recipe_id", "")) == str(rcp.get("id", "")),
			"the reactor's node now runs the lab's batch")
		_ok(float(after.get("gas_lhv_mj_nm3", 0.0)) > 5.0, "and carries the gas's heating value (%.1f)" % float(after.get("gas_lhv_mj_nm3", 0.0)))
		var kinds2: Array = []
		for o in after.get("outputs", []):
			kinds2.append(str(o["kind"]))
		_ok(kinds2.slice(0, 3) == ["biochar", "hot_water", "woodgas"], "its ports keep their order (%s)" % [kinds2])
		var note := ui.find_child("use_note", true, false) as Label
		_ok(note != null and note.text.contains("graph node"), "the panel says where it went (%s)" % (note.text if note != null else ""))
		await _shot(main, "11_use_run")
		ui.call("close")
		var loader := main.find_child("TerrainLoader", true, false)
		if loader != null:
			loader.call("delete_prop_by_id", pid)
		await _settle(tree, 4)

	# The whole chain (Phase 8): placed, it is three graph nodes wired
	# reactor → holder → genset; in the lab the genset runs from the holder.
	var placed2 := PlacedPropService.place_model_at_xz(main, "tclab_biochar_genset", at.x - 6.0, at.z + 6.0)
	await _settle(tree, 20)
	var pid2 := str(placed2.get("prop_id", ""))
	var rec2 := PlacedPropService.get_prop_record(main, pid2)
	var gid2 := str(rec2.get("graph_item_id", ""))
	var ids2: Dictionary = rec2.get("graph_item_ids", {})
	_ok(not gid2.is_empty() and ids2.size() == 2, "the chain has its reactor node and two unit nodes (%s, %s)" % [gid2, ids2])
	var sgv2: Node = ServiceLocator.graph()
	var model2: Object = sgv2.get("model") if sgv2 != null else null
	if model2 != null and ids2.size() == 2:
		var hid := ""
		var genid := ""
		for k in ids2.keys():
			var it: Dictionary = model2.call("get_item", str(ids2[k]))
			if str(it.get("type", "")) == "resource":
				hid = str(ids2[k])
			else:
				genid = str(ids2[k])
		var hspec: Dictionary = (model2.call("get_item", hid) as Dictionary).get("specs", {})
		_ok(str(hspec.get("resource_kind", "")) == "woodgas" and str(hspec.get("bound_prop_id", "")) == pid2,
			"the holder is a woodgas tank bound to the chain")
		var wires := {}
		for c in model2.get("connections"):
			wires["%s>%s" % [c.get("source_item_id", ""), c.get("target_item_id", "")]] = true
		_ok(wires.has("%s>%s" % [gid2, hid]) and wires.has("%s>%s" % [hid, genid]),
			"the reactor feeds the holder and the holder the genset")
		ui = main.call("open_tclab", {"prop_id": pid2})
		await _settle(tree, 12)
		await _click_named(ui, vp, tree, "mode_process")
		panel = ui.call("process_panel")
		panel.call("prerun_batch")
		var fr3 := 0
		while bool(panel.get("prerunning")) and fr3 < 6000:
			await tree.process_frame
			fr3 += 1
		panel.call("seek_h", 8.0)
		await _settle(tree, 4)
		var csim: Object = panel.get("sim")
		var kwh := float(csim.get("engine_kwh")) if csim != null else 0.0
		_ok(kwh > 0.25, "in the lab the genset makes electricity from the batch (%.2f kWh)" % kwh)
		await _click_named(ui, vp, tree, "right_control")
		await _settle(tree, 6)
		var ctl := ui.find_child("control_box", true, false)
		var labels := ""
		if ctl != null:
			for l in ctl.find_children("*", "Label", true, false):
				labels += (l as Label).text + "|"
		_ok(labels.contains("fill") and labels.contains("Electricity made"), "the Control tab lists the holder and the genset")
		await _shot(main, "12_chain")
		ui.call("close")
	var loader2 := main.find_child("TerrainLoader", true, false)
	if loader2 != null and not pid2.is_empty():
		loader2.call("delete_prop_by_id", pid2)
		await _settle(tree, 6)
		if model2 != null:
			var left := 0
			for k2 in ids2.keys():
				if not (model2.call("get_item", str(ids2[k2])) as Dictionary).is_empty():
					left += 1
			_ok(left == 0 and (model2.call("get_item", gid2) as Dictionary).is_empty(), "deleting the chain removes all three nodes")
	return {"ok": _fails.is_empty(), "failures": _fails}
