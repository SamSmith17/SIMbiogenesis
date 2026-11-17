extends RefCounted

## Liquid lines in the Process Lab with REAL input (sandbox; writes nothing
## to the player's world). SCADA plan, Phase 6 (first part).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tc_hydraulics_check.gd -Label tc_hydraulics
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tc_hydraulics_check.gd -Label tc_hydraulics_720 -UserArgs @("--window-size=1280x720")
## Opens the tri-clamp designer on the two-tank level rig, Process mode, P&ID:
## - the picture has three vessels, the pump and both control valves;
## - Play: the supply tank falls, the process tank rises to half and stays
##   there (the rig's PID), the pump's tag reads litres a minute;
## - a click on the pump opens its faceplate; a REAL click on Switch off stops
##   it in the model, Switch on starts it again; −10 % slows it;
## - a click on the control valve opens its faceplate with its opening;
## - with the loop in Manual and the valve shut the tank drains;
## - the 3D view draws the new parts; UiAudit is clean.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("tc_hyd %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _els(canvas: Control, kind: String) -> Array:
	var out: Array = []
	for e in (canvas.get("doc") as Dictionary).get("elements", []):
		if str(e["kind"]) == kind:
			out.append(e)
	return out


func _center(canvas: Control, e: Dictionary) -> Vector2:
	return canvas.global_position + (canvas.call("element_rect", e) as Rect2).get_center()


func _level(sim: TcProcSim, cv: int) -> float:
	return sim._liq_volume(sim.liq[cv]) / float(sim.net["cvs"][cv]["volume_m3"]) * 100.0


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var vp := main.get_viewport()
	var ui: Control = main.call("open_tclab", {})
	await _settle(tree, 20)
	_ok(ui != null and bool(ui.call("is_open")), "the designer opened")
	if ui == null:
		return {"ok": false, "failures": _fails}
	ui.call("load_builtin", "level_rig")
	await _settle(tree, 12)
	await _shot(main, "00_rig_3d")
	ui.call("set_run_mode", true)
	await _settle(tree, 10)
	var panel: Node = ui.call("process_panel")
	var sim: TcProcSim = panel.get("sim")
	_ok(sim != null and sim.lines.size() == 2, "Process mode has a run with two liquid lines")
	if sim == null or sim.lines.size() != 2:
		return {"ok": false, "failures": _fails}
	var a_cv := int(sim.lines[0]["a"])
	var b_cv := int(sim.lines[0]["b"])
	var c_cv := int(sim.lines[1]["b"])

	var pid_btn := ui.find_child("proc_pid", true, false) as Button
	await HarnessInput.click(vp, HarnessInput.center_of(pid_btn))
	await _settle(tree, 8)
	var canvas: Control = panel.get("mimic")
	_ok(canvas != null and canvas.is_visible_in_tree(), "the P&ID shows")
	if canvas == null:
		return {"ok": false, "failures": _fails}
	var vessels := _els(canvas, "vessel")
	var pumps := _els(canvas, "pump")
	var valves := _els(canvas, "valve")
	_ok(vessels.size() == 3 and pumps.size() == 1 and valves.size() == 2,
		"three tanks, a pump and two control valves are drawn (%d, %d, %d)" % [vessels.size(), pumps.size(), valves.size()])
	if pumps.is_empty() or valves.size() < 2:
		return {"ok": false, "failures": _fails}
	var view := Rect2(Vector2.ZERO, canvas.size)
	var inside := true
	for e in vessels + pumps + valves:
		if not view.intersects(canvas.call("element_rect", e) as Rect2):
			inside = false
	_ok(inside, "all of them are in view after the fit")
	await _shot(main, "01_pid_start")

	# ---- play: the loop fills the tank to half and holds it ----
	var a0 := _level(sim, a_cv)
	panel.call("seek_h", 0.0)
	panel.call("prerun_batch")
	for _i in 900:
		await tree.process_frame
		if not bool(panel.get("prerunning")):
			break
	await _settle(tree, 10)
	panel.call("seek_h", 0.25)
	await _settle(tree, 10)
	sim = panel.get("sim")
	print("tc_hyd: at %.2f h supply %.1f %% (from %.1f), tank %.1f %%, receiver %.1f %%, pump %s" % [
		float(panel.call("time_h")), _level(sim, a_cv), a0, _level(sim, b_cv), _level(sim, c_cv), str(sim.pump_lpm)])
	_ok(_level(sim, a_cv) < a0 - 5.0, "the supply tank has fallen")
	_ok(absf(_level(sim, b_cv) - 50.0) < 2.0, "the PID holds the process tank at half (%.1f %%)" % _level(sim, b_cv))
	_ok(_level(sim, c_cv) > 3.0, "the receiver has filled from the drain")
	var pump_part := str(pumps[0]["part"])
	_ok(float(sim.pump_lpm.get(pump_part, 0.0)) > 0.5, "the pump is moving liquid (%.2f L/min)" % float(sim.pump_lpm.get(pump_part, 0.0)))
	var st: Dictionary = canvas.get("state")
	var pes: Dictionary = (st.get("el", {}) as Dictionary).get(str(pumps[0]["id"]), {})
	_ok(bool(pes.get("running", false)) and str(pes.get("value", "")).ends_with("L/min"), "the picture's pump runs and reads its flow (%s)" % str(pes.get("value", "")))
	var b_el: Dictionary = {}
	for v in vessels:
		if int(v["cv"]) == b_cv:
			b_el = v
	var bs: Dictionary = (st.get("cv", {}) as Dictionary).get(b_cv, {})
	_ok(not b_el.is_empty() and absf(float(bs.get("level", 0.0)) - 0.5) < 0.03, "the picture's tank is half full (%.2f)" % float(bs.get("level", 0.0)))
	await _shot(main, "02_pid_holding")

	# ---- the pump's faceplate ----
	await HarnessInput.click(vp, _center(canvas, pumps[0]))
	await _settle(tree, 6)
	var face: Control = panel.get("_face")
	_ok(face != null and face.visible and str(face.call("shown_for")) == str(pumps[0]["id"]), "a click on the pump opens its faceplate")
	if face != null and face.visible:
		_ok(Rect2(Vector2.ZERO, vp.get_visible_rect().size).encloses(face.get_global_rect()), "the faceplate is inside the window")
		await _shot(main, "03_pump_faceplate")
		var off: Button = face.call("button", "off")
		_ok(off != null and not off.disabled, "it offers Switch off")
		if off != null:
			await HarnessInput.click(vp, HarnessInput.center_of(off))
			await _settle(tree, 6)
			_ok(not bool(sim.pump_on.get(pump_part, true)), "a REAL click on Switch off stops the pump in the model")
		var on: Button = face.call("button", "on")
		if on != null:
			await HarnessInput.click(vp, HarnessInput.center_of(on))
			await _settle(tree, 6)
			_ok(bool(sim.pump_on.get(pump_part, false)), "Switch on starts it again")
		var less: Button = face.call("button", "less")
		_ok(less != null, "it has a speed step")
		if less != null:
			await HarnessInput.click(vp, HarnessInput.center_of(less))
			await _settle(tree, 6)
			_ok(absf(float(sim.pump_speed.get(pump_part, 1.0)) - 0.9) < 0.001, "−10 %% slows it to 90 %% (%.2f)" % float(sim.pump_speed.get(pump_part, 1.0)))
		panel.call("dismiss_faceplate")
		await _settle(tree, 4)

	# ---- the control valve's faceplate ----
	var feed: Dictionary = {}
	for v2 in valves:
		if int(v2["link"]) in (sim.lines[0]["links"] as Array):
			feed = v2
	_ok(not feed.is_empty(), "the feed valve is in the picture")
	if not feed.is_empty():
		await HarnessInput.click(vp, _center(canvas, feed))
		await _settle(tree, 6)
		face = panel.get("_face")
		_ok(face != null and face.visible and str(face.call("shown_for")) == str(feed["id"]), "a click on the control valve opens its faceplate")
		if face != null and face.visible:
			_ok(face.call("button", "more") != null and face.call("button", "less") != null, "it steps its opening")
			await _shot(main, "04_valve_faceplate")
		panel.call("dismiss_faceplate")
		await _settle(tree, 4)
		# With the loop off and the valve shut, the tank drains.
		var blocks: Array = (sim.logic_blocks as Array).duplicate(true)
		sim.logic_blocks = []
		sim.set_actuator("cvalve:%s" % str(feed["part"]), 0.0)
		var lv := _level(sim, b_cv)
		sim.run_for(300.0, 5.0)
		_ok(_level(sim, b_cv) < lv - 5.0, "loop off and the valve shut: the tank drains (%.1f → %.1f %%)" % [lv, _level(sim, b_cv)])
		sim.logic_blocks = blocks

	var audit: Dictionary = UiAudit.run(vp)
	print("tc_hyd: audit %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors with the picture up")
	await HarnessInput.click(vp, HarnessInput.center_of(pid_btn))
	await _settle(tree, 6)
	await _shot(main, "05_rig_3d_process")
	ui.call("set_run_mode", false)
	await _settle(tree, 4)

	# ---- the three plant presets: built, run to the end, drawn ----
	for spec in [["brewhouse", "b1", 0.93], ["cip_skid", "b2", 0.62], ["water_filter_train", "", 0.3]]:
		var id := str(spec[0])
		ui.call("load_builtin", id)
		await _settle(tree, 12)
		await _shot(main, "10_%s_3d" % id)
		ui.call("set_run_mode", true)
		await _settle(tree, 10)
		panel = ui.call("process_panel")
		sim = panel.get("sim")
		_ok(sim != null and sim.lines.size() >= 2, "%s: Process mode has its liquid lines" % id)
		if sim == null:
			continue
		if not bool(panel.get("pid_on")):
			await HarnessInput.click(vp, HarnessInput.center_of(pid_btn))
			await _settle(tree, 8)
		canvas = panel.get("mimic")
		panel.call("prerun_batch")
		for _j in 1500:
			await tree.process_frame
			if not bool(panel.get("prerunning")):
				break
		await _settle(tree, 8)
		sim = panel.get("sim")
		if str(spec[1]) != "":
			var stx: Dictionary = sim.logic_status.get(str(spec[1]), {})
			_ok(str(stx.get("run", "")) == "done", "%s: its sequence ran to the end in the lab (%s)" % [id, str(stx.get("text", ""))])
		panel.call("seek_h", float(sim.proc.get("duration_h", 1.0)) * float(spec[2]))
		await _settle(tree, 10)
		var n_v := _els(canvas, "vessel").size()
		var n_p := _els(canvas, "pump").size()
		_ok(n_v >= 3 and n_p >= 1, "%s: its tanks and pumps are in the picture (%d, %d)" % [id, n_v, n_p])
		var seen := true
		for e2 in _els(canvas, "vessel"):
			if not Rect2(Vector2.ZERO, canvas.size).intersects(canvas.call("element_rect", e2) as Rect2):
				seen = false
		_ok(seen, "%s: every tank is in view" % id)
		if id == "brewhouse":
			_ok(_els(canvas, "heater").size() == 2 and _els(canvas, "probe_l").size() == 1, "brewhouse: both elements and the level transmitter are drawn")
		if id == "water_filter_train":
			_ok(_els(canvas, "probe_ls").size() == 1, "filter train: the level switch is drawn")
		var au: Dictionary = UiAudit.run(vp)
		print("tc_hyd: %s audit %s" % [id, UiAudit.summary_line(au)])
		_ok(int(au.get("errors", 0)) == 0, "%s: UiAudit finds no errors" % id)
		await _shot(main, "11_%s_pid" % id)
		ui.call("set_run_mode", false)
		await _settle(tree, 4)
	ui.call("close")
	await _settle(tree, 6)
	return {"ok": _fails.is_empty(), "failures": _fails}
