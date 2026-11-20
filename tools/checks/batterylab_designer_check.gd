extends RefCounted

## The Battery Lab on a REAL world (sandbox; writes nothing to the world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/batterylab_designer_check.gd -Label batterylab
## Run it at 1080 and with -UserArgs @("--window-size=1280x720").
## Opens the designer through Main, clicks every built-in in the gallery (a
## shot of each), runs UiAudit, edits the series count through its spin box,
## drags the explode slider, clicks a cell in the 3D view, turns on Show me,
## steps the tour, picks each colour mode, presses a check's Show it, undoes,
## saves to the library and forgets it again (the library file is restored).

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("batterylab %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _reveal(c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is Collapsible:
			(p as Collapsible).set_open(true)
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
		p = p.get_parent()


## At 720 the left column folds into a header button: open its flyout.
func _left(ui: Control, tree: SceneTree) -> void:
	var shell: DesignerShell = ui.get("_shell")
	if shell != null and shell.is_folded() and not shell.left_popup_shown():
		shell.show_left_popup()
		await _settle(tree, 4)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var lib_path := BattPresets.LIBRARY_FILE
	var lib_had := FileAccess.file_exists(lib_path)
	var lib_old := FileAccess.get_file_as_string(lib_path) if lib_had else ""
	_ok(main.has_method("open_batterylab"), "Main hosts the Battery Lab")
	var ui: Control = main.call("open_batterylab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the Battery Lab opened")
	if ui == null:
		return {"ok": false, "fails": _fails}
	var studio: StudioViewport = ui.call("studio")
	# --- Every built-in through a REAL click on its gallery row.
	var gallery: DesignGallery = ui.call("gallery")
	var built := BattPresets.builtins()
	for i in built.size():
		var b: Dictionary = built[i]
		var btn := gallery.row_button(i)
		if btn == null:
			_ok(false, "%s has a gallery row" % b["id"])
			continue
		await _left(ui, tree)
		_reveal(btn)
		await _settle(tree, 2)
		await HarnessInput.click(vp, HarnessInput.center_of(btn))
		await _settle(tree, 12)
		var s: Dictionary = ui.call("spec")
		_ok(str(s["name"]) == str((b["spec"] as Dictionary)["name"]), "a click on %s loads it" % b["id"])
		var d: Dictionary = ui.call("design")
		var e: Dictionary = d["electrical"]
		var bld: BattBuilder = ui.call("builder")
		_ok(bld != null and bld.cell_count() > 0, "%s draws its cells" % b["id"])
		var img := studio.viewport.get_texture().get_image()
		_ok(img != null and img.get_width() > 32, "%s renders" % b["id"])
		if img != null:
			img.save_png("%s/studio_%s.png" % [dir, b["id"]])
		print("batterylab: %s — %.1f V %.0f Ah %.2f kWh, %.0f A, %.1f kg, %d checks" % [b["id"],
			float(e["v_nom"]), float(e["ah"]), float(e["wh"]) * 0.001, float(e["cont_discharge_a"]),
			float(d["mass_kg"]), (d["checks"] as Array).size()])
	# Back to the rack pack for the rest.
	var rack_i := 0
	for i in built.size():
		if str((built[i] as Dictionary)["id"]) == "rack_48v_105":
			rack_i = i
	await _left(ui, tree)
	_reveal(gallery.row_button(rack_i))
	await _settle(tree, 2)
	await HarnessInput.click(vp, HarnessInput.center_of(gallery.row_button(rack_i)))
	await _settle(tree, 14)
	var sh: DesignerShell = ui.get("_shell")
	if sh.left_popup_shown():
		sh.hide_left_popup()
		await _settle(tree, 4)
	main.get_viewport().get_texture().get_image().save_png("%s/modal.png" % dir)
	var audit := UiAudit.run(vp)
	print("batterylab: ui audit — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the open modal has no UI audit errors")
	# --- The series count through its spin box (typed, as a player would).
	var v0 := float((ui.call("design") as Dictionary)["electrical"]["v_nom"])
	var srow := ui.find_child("series", true, false)
	var sb: SpinBox = null
	if srow is FormRow:
		sb = (srow as FormRow).control as SpinBox
	elif srow is SpinBox:
		sb = srow
	_ok(sb != null, "the series spin box")
	if sb != null:
		_reveal(sb)
		await _settle(tree, 3)
		var le := sb.get_line_edit()
		await HarnessInput.click(vp, HarnessInput.center_of(le))
		await _settle(tree, 2)
		le.text = "8"
		le.text_submitted.emit("8")
		await _settle(tree, 10)
		var v1 := float((ui.call("design") as Dictionary)["electrical"]["v_nom"])
		_ok(absf(v1 - v0 * 0.5) < 0.05, "8 in series halves the voltage (%.1f → %.1f V)" % [v0, v1])
		vp.gui_release_focus()
		# Undo with Ctrl+Z (focus off the spin box).
		await HarnessInput.key(vp, KEY_Z, true)
		await _settle(tree, 10)
		var v2 := float((ui.call("design") as Dictionary)["electrical"]["v_nom"])
		_ok(absf(v2 - v0) < 0.05, "Ctrl+Z puts 16 in series back (%.1f V)" % v2)
	# --- Explode through a REAL drag on the slider.
	var sl: HSlider = ui.get("_explode_sl")
	var r := sl.get_global_rect()
	await HarnessInput.drag(vp, Vector2(r.position.x + 2.0, r.get_center().y), Vector2(r.end.x - 2.0, r.get_center().y))
	await _settle(tree, 6)
	var bld2: BattBuilder = ui.call("builder")
	_ok(bld2.get_explode() > 0.8, "dragging the slider explodes the pack (%.2f)" % bld2.get_explode())
	studio.viewport.get_texture().get_image().save_png("%s/exploded.png" % dir)
	ui.call("set_explode", 0.0)
	# --- Click a cell in the 3D view.
	var cell := bld2.part("cell_0_0")
	_ok(not cell.is_empty(), "the pack has a first cell")
	ui.call("set_cutaway", true)
	await _settle(tree, 4)
	if not cell.is_empty():
		var bb: AABB = cell["aabb"]
		var w := bld2.global_transform * bb.get_center()
		var at := studio.camera.unproject_position(w)
		var cont := studio.container
		var local := at * (cont.size / Vector2(studio.viewport.size))
		var gp := cont.get_global_transform() * local
		await HarnessInput.click(vp, gp)
		await _settle(tree, 6)
		var sel := str(ui.call("selected_part"))
		_ok(sel.begins_with("cell_") or sel.begins_with("link") or sel.begins_with("tap"),
			"a click on a cell selects it (%s)" % sel)
		var info: Label = ui.get("_info_lbl")
		_ok(not info.text.begins_with("Click a part"), "the part line names it: %s" % info.text)
		_ok(bld2.highlighted_count() > 0, "the picked part is highlighted")
	# --- Show me.
	var learn: Button = ui.get("_learn_btn")
	await HarnessInput.click(vp, HarnessInput.center_of(learn))
	await _settle(tree, 6)
	_ok(bool(ui.call("learn_on")), "Show me turns the callouts on")
	_ok((ui.call("callouts") as Array).size() >= 5, "callouts for the parts (%d)" % (ui.call("callouts") as Array).size())
	main.get_viewport().get_texture().get_image().save_png("%s/show_me.png" % dir)
	# --- The tour, every step by REAL clicks.
	var tour: Button = ui.get("_tour_btn")
	for i in TOUR_STEPS:
		await HarnessInput.click(vp, HarnessInput.center_of(tour))
		await _settle(tree, 6)
		_ok(int(ui.call("tour_step")) == i, "tour step %d" % (i + 1))
		main.get_viewport().get_texture().get_image().save_png("%s/tour_%d.png" % [dir, i + 1])
	await HarnessInput.click(vp, HarnessInput.center_of(tour))
	await _settle(tree, 4)
	_ok(int(ui.call("tour_step")) == -1 and not bool(ui.call("learn_on")), "Finish ends the tour")
	# --- Colour by, each mode through the option button.
	var opt: OptionButton = ui.get("_colour_opt")
	for i in opt.item_count:
		opt.select(i)
		opt.item_selected.emit(i)
		await _settle(tree, 4)
		var m := str(opt.get_item_metadata(i))
		_ok(str(ui.call("colour_mode")) == m, "colour by %s" % m)
		studio.viewport.get_texture().get_image().save_png("%s/colour_%s.png" % [dir, m])
	ui.call("set_colour", "part")
	# --- A check's Show it: a lithium pack with no BMS is an error that names it.
	ui.call("edit", "bms.id", "")
	ui.call("edit", "series", 30)
	await _settle(tree, 8)
	var checks := (ui.call("design") as Dictionary)["checks"] as Array
	print("batterylab: 30S checks — %s" % ", ".join(PackedStringArray(checks.map(func(c): return str(c["text"])))))
	var show := HarnessInput.find_button(ui, "Show it")
	if show != null:
		_reveal(show)
		await _settle(tree, 3)
		await HarnessInput.click(vp, HarnessInput.center_of(show))
		await _settle(tree, 4)
		_ok(not str(ui.call("selected_part")).is_empty(), "Show it selects the part")
	else:
		print("batterylab: no check with a part to show at 30S")
	ui.call("edit", "series", 16)
	await _settle(tree, 6)
	# --- BMS & test, by REAL clicks on the tab, the scenarios, play and the chart.
	await _test_bench(ui, main, tree, vp, studio, dir)
	# --- Bank, by REAL clicks on its tab, fields, views and Export.
	await _test_bank_tab(ui, main, tree, vp, dir)
	# --- Save to the library and forget it.
	var n0 := int(ui.call("entry_count"))
	var save := HarnessInput.find_button(ui, "Save design")
	_ok(save != null, "the Save design button")
	if save != null:
		await HarnessInput.click(vp, HarnessInput.center_of(save))
		await _settle(tree, 10)
		_ok(int(ui.call("entry_count")) == n0 + 1, "saving adds a ★ design")
		var last := int(ui.call("entry_count")) - 1
		await _left(ui, tree)
		gallery.select(last)
		var fg := HarnessInput.find_button(ui, "Forget")
		if fg == null:
			fg = HarnessInput.find_button(sh.get_tree().root, "Forget")
		_ok(fg != null, "the Forget button")
		if fg != null:
			await HarnessInput.click(vp, HarnessInput.center_of(fg))
		await _settle(tree, 6)
		_ok(int(ui.call("entry_count")) == n0, "Forget removes it")
	# --- Close with the shell.
	ui.call("close")
	await _settle(tree, 4)
	_ok(not bool(ui.call("is_open")), "closed")
	if lib_had:
		var f := FileAccess.open(lib_path, FileAccess.WRITE)
		f.store_string(lib_old)
	elif FileAccess.file_exists(lib_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lib_path))
	print("batterylab: %d failures" % _fails.size())
	return {"ok": _fails.is_empty(), "fails": _fails}


const TOUR_STEPS := 5


func _pick_scenario(tp: Control, vp: Viewport, tree: SceneTree, id: String) -> void:
	var opt: OptionButton = tp.get("_sc_opt")
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == id:
			await HarnessInput.click(vp, HarnessInput.center_of(opt))
			await _settle(tree, 4)
			opt.select(i)
			opt.item_selected.emit(i)
			var pop := opt.get_popup()
			if pop.visible:
				pop.hide()
			await _settle(tree, 6)
			return


func _ev_t(tp: Control, key: String, what: String) -> float:
	var res: Dictionary = tp.get("result")
	for ev in (res.get("events", []) as Array):
		if str(ev["key"]) == key and str(ev["what"]) == what:
			return float(ev["t"])
	return -1.0


func _test_bench(ui: Control, main: Node, tree: SceneTree, vp: Viewport, studio: StudioViewport, dir: String) -> void:
	var tabs: TabBar = ui.get("_tabs")
	var r := tabs.get_tab_rect(1)
	await HarnessInput.click(vp, tabs.get_global_transform() * r.get_center())
	await _settle(tree, 10)
	_ok(str(ui.call("mode")) == "test", "a click on the BMS & test tab opens the bench")
	var tp: Control = ui.call("test_panel")
	_ok(tp != null and tp.visible, "the bench is shown")
	if tp == null:
		return
	var res: Dictionary = tp.get("result")
	_ok(not res.is_empty() and (res["frames"] as Array).size() > 10, "the charge scenario ran (%d frames)" % (res.get("frames", []) as Array).size())
	# Play by a real click; the clock moves on its own.
	var play: Button = tp.get("_play_btn")
	await HarnessInput.click(vp, HarnessInput.center_of(play))
	await _settle(tree, 40)
	_ok(bool(tp.call("is_playing")) or float(tp.call("time_s")) > 0.0, "Play moves the lab clock (%s)" % BattSim.time_words(float(tp.call("time_s"))))
	var t1 := float(tp.call("time_s"))
	await _settle(tree, 20)
	_ok(float(tp.call("time_s")) > t1, "and keeps moving")
	await HarnessInput.click(vp, HarnessInput.center_of(play))
	await _settle(tree, 4)
	_ok(not bool(tp.call("is_playing")), "a second click pauses")
	# Scrub: a click three quarters along the chart.
	var chart: Control = tp.get("_chart")
	var pr: Rect2 = chart.call("_plot")
	var at := chart.get_global_transform() * (pr.position + Vector2(pr.size.x * 0.75, pr.size.y * 0.5))
	await HarnessInput.click(vp, at)
	await _settle(tree, 4)
	var want := 0.75 * float(tp.call("duration"))
	_ok(absf(float(tp.call("time_s")) - want) < float(tp.call("duration")) * 0.02, "a click on the chart scrubs to 75 %% (%s)" % BattSim.time_words(float(tp.call("time_s"))))
	main.get_viewport().get_texture().get_image().save_png("%s/test_charge.png" % dir)
	var audit := UiAudit.run(vp)
	print("batterylab: ui audit (bench) — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the bench has no UI audit errors")
	# The frozen morning: charging blocked, then resumed.
	await _pick_scenario(tp, vp, tree, "cold")
	_ok(str(tp.call("scenario_id")) == "cold", "the cold scenario is picked")
	var ut := _ev_t(tp, "charge_ut", "trip")
	var ur := _ev_t(tp, "charge_ut", "release")
	_ok(ut >= 0.0 and ur > ut, "cold: charge blocked at %s, released at %s" % [BattSim.time_words(ut), BattSim.time_words(ur)])
	tp.call("seek", (ut + ur) * 0.5)
	await _settle(tree, 4)
	var f: Dictionary = tp.call("frame")
	_ok(not bool(f["chg"]) and bool(f["dsg"]), "mid-way the charge switch is open, the discharge switch closed")
	var lamp: Label = tp.get("_chg_lamp")
	_ok(lamp.get_theme_color("font_color").is_equal_approx(UITheme.C_ERROR), "the charge lamp is red")
	main.get_viewport().get_texture().get_image().save_png("%s/test_cold.png" % dir)
	# An event in the log jumps to it.
	var log: ItemList = tp.get("_log")
	if log.item_count > 1:
		log.select(1)
		log.item_selected.emit(1)
		await _settle(tree, 4)
		_near_ok(float(tp.call("time_s")), float(log.get_item_metadata(1)), "a log entry jumps to its time")
	# The short in slow motion.
	await _pick_scenario(tp, vp, tree, "short")
	var sc := _ev_t(tp, "short_circuit", "trip")
	_ok(sc > 0.0 and sc < 0.002, "short: the BMS opens at %s" % BattSim.time_words(sc))
	tp.call("seek", float(tp.call("duration")))
	await _settle(tree, 4)
	main.get_viewport().get_texture().get_image().save_png("%s/test_short.png" % dir)
	# A protection edited in the BMS section changes the run.
	await _pick_scenario(tp, vp, tree, "discharge")
	var uv0 := _ev_t(tp, "cell_uv", "trip")
	var sb := ui.find_child("prot_cell_uv_trip", true, false) as SpinBox
	_ok(sb != null, "the cell under-voltage setting")
	if sb != null:
		_reveal(sb)
		await _settle(tree, 3)
		var le := sb.get_line_edit()
		await HarnessInput.click(vp, HarnessInput.center_of(le))
		le.text = "3.0"
		le.text_submitted.emit("3.0")
		vp.gui_release_focus()
		await _settle(tree, 20)
		var uv1 := _ev_t(tp, "cell_uv", "trip")
		_ok(uv1 > 0.0 and uv1 < uv0, "a 3.0 V cut-off stops the load sooner (%s vs %s)" % [BattSim.time_words(uv1), BattSim.time_words(uv0)])
		var rs := HarnessInput.find_button(ui, "Back to the BMS's own settings")
		if rs != null:
			_reveal(rs)
			await _settle(tree, 3)
			await HarnessInput.click(vp, HarnessInput.center_of(rs))
			await _settle(tree, 12)
		_near_ok(_ev_t(tp, "cell_uv", "trip"), uv0, "Back to the BMS's settings restores it")
	# Lead-acid: no BMS, the charger's stages.
	ui.call("load_builtin", "agm_12v_100")
	await _settle(tree, 10)
	_ok(not (tp.get("_sc_opt") as OptionButton).get_item_text(0).is_empty(), "lead-acid scenarios listed")
	await _pick_scenario(tp, vp, tree, "charge")
	var stages := 0
	for ev in ((tp.get("result") as Dictionary)["events"] as Array):
		if str(ev["key"]) == "charger":
			stages += 1
	_ok(stages >= 2, "lead-acid: the charger steps through its stages (%d events)" % stages)
	studio.viewport.get_texture().get_image().save_png("%s/test_agm.png" % dir)
	# Back to the pack tab.
	await HarnessInput.click(vp, tabs.get_global_transform() * tabs.get_tab_rect(0).get_center())
	await _settle(tree, 6)
	_ok(str(ui.call("mode")) == "pack" and not tp.visible, "the Pack tab hides the bench")
	ui.call("load_builtin", "rack_48v_105")
	await _settle(tree, 10)


func _near_ok(a: float, b: float, what: String) -> void:
	_ok(absf(a - b) < maxf(1.0, absf(b) * 0.001), "%s (%.3f vs %.3f)" % [what, a, b])


func _test_bank_tab(ui: Control, main: Node, tree: SceneTree, vp: Viewport, dir: String) -> void:
	var tabs: TabBar = ui.get("_tabs")
	_ok(tabs.tab_count >= 3, "a Bank tab")
	if tabs.tab_count < 3:
		return
	await HarnessInput.click(vp, tabs.get_global_transform() * tabs.get_tab_rect(2).get_center())
	await _settle(tree, 12)
	_ok(str(ui.call("mode")) == "bank", "a click on the Bank tab opens the bank")
	var bp: Control = ui.call("bank_panel")
	_ok(bp != null and bp.visible, "the bank panel is shown")
	if bp == null:
		return
	var bb: Node = ui.call("bank_builder")
	_ok(bb != null and int(bb.call("pack_count")) >= 1, "the studio draws the bank")
	# Parallel by typing in the field.
	var sb := ui.find_child("bank_parallel", true, false) as SpinBox
	_ok(sb != null, "the parallel field")
	if sb != null:
		_reveal(sb)
		await _settle(tree, 3)
		var le := sb.get_line_edit()
		await HarnessInput.click(vp, HarnessInput.center_of(le))
		le.text = "4"
		le.text_submitted.emit("4")
		vp.gui_release_focus()
		await _settle(tree, 20)
		var d: Dictionary = ui.call("bank_design")
		_ok(int(d["electrical"]["packs"]) == 4, "typing 4 makes four packs in parallel (%d)" % int(d["electrical"]["packs"]))
		_ok(int((ui.call("bank_builder") as Node).call("pack_count")) == 4, "and the studio draws four")
		var summ := ui.find_child("bank_summary", true, false) as Label
		_ok(summ != null and summ.text.find("420") >= 0, "the summary says 420 Ah")
	main.get_viewport().get_texture().get_image().save_png("%s/bank_cabinet.png" % dir)
	# Undo puts it back to one.
	ui.call("_undo_step")
	await _settle(tree, 10)
	_ok(int((ui.call("bank_design") as Dictionary)["electrical"]["packs"]) != 4, "Ctrl+Z undoes the parallel edit")
	ui.call("_redo_step")
	await _settle(tree, 10)
	# Mount on the wall through the dropdown's own signal.
	var ob := ui.find_child("bank_mount", true, false) as OptionButton
	_ok(ob != null, "the mount dropdown")
	if ob != null:
		var wi := -1
		for i in ob.item_count:
			if str(ob.get_item_metadata(i)) == "floor":
				wi = i
		ob.select(wi)
		ob.item_selected.emit(wi)
		await _settle(tree, 12)
		_ok(str((ui.call("bank_design") as Dictionary)["mount"]) == "floor", "the mount changes to the floor")
		main.get_viewport().get_texture().get_image().save_png("%s/bank_floor.png" % dir)
	# The cable table, then the BOM by a real click on its tab.
	var t: Tree = bp.call("tree")
	var root := t.get_root()
	_ok(root != null and root.get_child_count() >= 8, "the cable table lists every cable (%d)" % (root.get_child_count() if root != null else 0))
	var btabs := ui.find_child("bank_tabs", true, false) as TabBar
	if btabs != null:
		_reveal(btabs)
		await _settle(tree, 3)
		await HarnessInput.click(vp, btabs.get_global_transform() * btabs.get_tab_rect(1).get_center())
		await _settle(tree, 6)
		_ok(str(bp.call("view")) == "bom", "a click shows the bill of materials")
		root = t.get_root()
		_ok(root != null and root.get_child_count() > 0, "the BOM has rows")
		await HarnessInput.click(vp, btabs.get_global_transform() * btabs.get_tab_rect(2).get_center())
		await _settle(tree, 6)
		_ok(str(bp.call("view")) == "checks", "a click shows the checks")
	# A cable picked in the 3D view.
	var d2: Dictionary = ui.call("bank_design")
	var cid := ""
	for cb in (d2["cables"] as Array):
		if str(cb["kind"]) == "main":
			cid = str(cb["id"])
	ui.call("select_bank_part", cid)
	await _settle(tree, 4)
	_ok(int((ui.call("bank_builder") as Node).call("highlighted_count")) >= 1, "selecting the main cable lights it")
	var audit := UiAudit.run(vp)
	print("batterylab: ui audit (bank) — %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "the bank tab has no UI audit errors")
	# A bus bar too small for the bank, picked through its dropdown: the checks say so.
	var bob := ui.find_child("bank_bus_bar", true, false) as OptionButton
	_ok(bob != null, "the bus bar dropdown")
	ui.call("edit_bank", "bus", "busbar")
	await _settle(tree, 8)
	_ok(not bob.disabled, "with a busbar bus the bar size can be picked")
	if bob != null:
		var bi := -1
		for i in bob.item_count:
			if str(bob.get_item_metadata(i)) == "20x3":
				bi = i
		bob.select(bi)
		bob.item_selected.emit(bi)
		ui.call("edit_bank", "bus_stack", "1")
		await _settle(tree, 10)
		var bad := false
		for c in ((ui.call("bank_design") as Dictionary)["checks"] as Array):
			if str(c["level"]) == "error" and str(c["text"]).find("busbars") >= 0:
				bad = true
		_ok(bad, "a 20 × 3 mm bar on the bank is an error in the checks")
		for i in bob.item_count:
			if str(bob.get_item_metadata(i)) == "auto":
				bi = i
		bob.select(bi)
		bob.item_selected.emit(bi)
		ui.call("edit_bank", "bus_stack", "0")
		await _settle(tree, 10)
	# The bank bench by a real click on its tab.
	if btabs != null:
		await HarnessInput.click(vp, btabs.get_global_transform() * btabs.get_tab_rect(3).get_center())
		await _settle(tree, 12)
		_ok(str(bp.call("view")) == "bench", "a click opens the bank bench")
		var bench: Control = bp.call("bench")
		_ok(bench != null and bench.visible and not (bench.get("result") as Dictionary).is_empty(), "the bench ran its first scenario")
		var sco := ui.find_child("bank_bench_scenario", true, false) as OptionButton
		if sco != null:
			var wi := -1
			for i in sco.item_count:
				if str(sco.get_item_metadata(i)) == "weak":
					wi = i
			sco.select(wi)
			sco.item_selected.emit(wi)
			await _settle(tree, 6)
		_ok(str(bench.call("scenario_id")) == "weak", "the weak-pack scenario is picked")
		var res: Dictionary = bench.get("result")
		var keys: Array = []
		for ev in (res["events"] as Array):
			if str(ev["what"]) == "trip":
				keys.append(str(ev["key"]))
		_ok(keys.has("cell_uv") and keys.has("discharge_oc"), "weak: one string trips, the others are overloaded and trip (%s)" % ", ".join(PackedStringArray(keys.slice(0, 5))))
		var play := ui.find_child("bank_bench_play", true, false) as Button
		await HarnessInput.click(vp, HarnessInput.center_of(play))
		await _settle(tree, 30)
		_ok(float(bench.call("time_s")) > 0.0, "Play moves the bench clock")
		await HarnessInput.click(vp, HarnessInput.center_of(play))
		await _settle(tree, 3)
		# A click on the chart just after the cascade.
		var t_oc := 0.0
		for ev in (res["events"] as Array):
			if str(ev["key"]) == "discharge_oc" and str(ev["what"]) == "trip":
				t_oc = maxf(t_oc, float(ev["t"]))
		var chart := ui.find_child("bank_bench_chart", true, false) as Control
		var pr: Rect2 = chart.call("plot")
		var u := clampf((t_oc + 5.0) / maxf(float(bench.call("duration")), 1.0), 0.0, 1.0)
		await HarnessInput.click(vp, chart.get_global_transform() * (pr.position + Vector2(pr.size.x * u, pr.size.y * 0.5)))
		await _settle(tree, 4)
		var f: Dictionary = bench.call("frame")
		var off := 0
		for c in (f.get("state_str", PackedInt32Array()) as PackedInt32Array):
			if c != 0:
				off += 1
		_ok(off >= 1, "just after the cascade strings are out (%d at %s)" % [off, BattSim.time_words(float(bench.call("time_s")))])
		_ok(int((ui.call("bank_builder") as Node).call("tinted_count")) >= 1, "the studio paints the packs from the bench")
		main.get_viewport().get_texture().get_image().save_png("%s/bank_bench.png" % dir)
		var audit2 := UiAudit.run(vp)
		print("batterylab: ui audit (bank bench) — %s" % UiAudit.summary_line(audit2))
		_ok(int(audit2.get("errors", 0)) == 0, "the bank bench has no UI audit errors")
		var lg := ui.find_child("bank_bench_log", true, false) as ItemList
		if lg != null and lg.item_count > 1:
			lg.select(1)
			lg.item_selected.emit(1)
			await _settle(tree, 4)
			_near_ok(float(bench.call("time_s")), float(lg.get_item_metadata(1)), "a bench log entry jumps to its time")
		await HarnessInput.click(vp, btabs.get_global_transform() * btabs.get_tab_rect(0).get_center())
		await _settle(tree, 6)
		_ok(int((ui.call("bank_builder") as Node).call("tinted_count")) == 0, "leaving the bench takes the paint off")
	# Export by a real click.
	var ex := ui.find_child("bank_export", true, false) as Button
	if ex != null:
		_reveal(ex)
		await _settle(tree, 3)
		await HarnessInput.click(vp, HarnessInput.center_of(ex))
		await _settle(tree, 6)
		var slug := BankExport.slug(str((ui.call("bank_spec") as Dictionary)["name"]))
		var base := "user://batterylab_designs/%s" % slug
		_ok(FileAccess.file_exists(base + "/single_line.svg") and FileAccess.file_exists(base + "/bom.csv"), "Export writes the single-line SVG and the BOM")
		_ok(FileAccess.file_exists(base + "/cables.csv"), "and the cable list")
	ui.call("set_mode", "pack")
	await _settle(tree, 6)
