extends RefCounted

## The Process Lab's P&ID view with REAL input (sandbox; writes nothing to
## the player's world). SCADA plan, Phase 2.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tc_pid_view_check.gd -Label tc_pid
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tc_pid_view_check.gd -Label tc_pid_720 -UserArgs @("--window-size=1280x720")
## Opens the tri-clamp designer on the biochar reactor, Process mode, then:
## - a REAL click on "P&ID" puts the flat picture over the studio, the same
##   size as it;
## - the picture has the vessel, both elements, the pipework and the ends;
## - Play: the flow marks move and the redraw cost is printed;
## - a click on the vessel selects its volume; a click on a pipe selects that;
## - a click on a heating element opens its faceplate; a REAL click on
##   "Switch off" turns the element off in the model and the plate says Off;
##   "Switch on" brings it back;
## - a click on the drain's butterfly valve opens its faceplate; Open it /
##   Close it move the valve in the model;
## - dragging the vessel moves it AND the pipes joined to it; the offset is
##   saved in the design's process (no restart of the run); Ctrl+Z undoes it;
## - the wheel zooms about the pointer, F fits;
## - UiAudit is clean; P&ID off gives the 3D studio back.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("tc_pid %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _el(canvas: Control, kind: String, n: int = 0) -> Dictionary:
	var k := 0
	for e in (canvas.get("doc") as Dictionary).get("elements", []):
		if str(e["kind"]) == kind:
			if k == n:
				return e
			k += 1
	return {}


func _center(canvas: Control, e: Dictionary) -> Vector2:
	return canvas.global_position + (canvas.call("element_rect", e) as Rect2).get_center()


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
	ui.call("load_builtin", "biochar_reactor")
	await _settle(tree, 8)
	ui.call("set_run_mode", true)
	await _settle(tree, 10)
	var panel: Node = ui.call("process_panel")
	var sim: TcProcSim = panel.get("sim")
	_ok(sim != null, "Process mode has a run")

	# ---- P&ID by its button ----
	var pid_btn := ui.find_child("proc_pid", true, false) as Button
	_ok(pid_btn != null and pid_btn.is_visible_in_tree(), "the transport has a P&ID button")
	await HarnessInput.click(vp, HarnessInput.center_of(pid_btn))
	await _settle(tree, 8)
	var canvas: Control = panel.get("mimic")
	_ok(canvas != null and canvas.is_visible_in_tree() and bool(panel.get("pid_on")), "a REAL click shows the picture")
	if canvas == null:
		return {"ok": false, "failures": _fails}
	var st: StudioViewport = ui.call("studio")
	var srect := Rect2(st.container.get_global_transform().origin, st.container.size * st.container.get_global_transform().get_scale())
	_ok(canvas.global_position.distance_to(srect.position) < 2.0 and (canvas.size - srect.size).length() < 2.0,
		"it covers the studio exactly (%s vs %s)" % [canvas.size, srect.size])
	var doc: Dictionary = canvas.get("doc")
	var kinds := {}
	for e in doc.get("elements", []):
		kinds[str(e["kind"])] = int(kinds.get(str(e["kind"]), 0)) + 1
	_ok(int(kinds.get("vessel", 0)) == 1 and int(kinds.get("heater", 0)) == 2 and int(kinds.get("end", 0)) >= 6
		and (doc.get("pipes", []) as Array).size() >= 10, "the picture has the vessel, both elements, the pipes and the ends (%s)" % str(kinds))
	var vessel := _el(canvas, "vessel")
	var vr: Rect2 = canvas.call("element_rect", vessel)
	_ok(Rect2(Vector2.ZERO, canvas.size).encloses(vr), "the vessel is in view after the fit")
	await _shot(main, "00_pid_start")

	# ---- play: flow marks, cost ----
	panel.call("seek_h", 0.0)
	panel.call("play", true)
	await _settle(tree, 240)
	var signs: Dictionary = canvas.get("flow_signs")
	var moving := 0
	for k in signs:
		if int(signs[k]) != 0:
			moving += 1
	var cost := float(canvas.call("draw_cost_ms"))
	print("tc_pid: %d of %d lines flowing at %.2f h, redraw %.2f ms" % [moving, signs.size(), float(panel.call("time_h")), cost])
	_ok(moving >= 1, "gas is drawn moving in the pipework once the charge heats")
	_ok(cost < 14.0, "one redraw is under 14 ms (%.2f)" % cost)
	panel.call("play", false)
	panel.call("seek_h", 2.0)
	await _settle(tree, 12)
	var state: Dictionary = canvas.get("state")
	_ok(float((state.get("bed", {}) as Dictionary).get("t_max_c", 0.0)) > 250.0, "at 2 h the picture's charge is hot (%d °C)" % int(float((state.get("bed", {}) as Dictionary).get("t_max_c", 0.0))))
	await _shot(main, "01_pid_2h")

	# ---- selection ----
	await HarnessInput.click(vp, _center(canvas, vessel) + Vector2(0, -vr.size.y * 0.3))
	await _settle(tree, 4)
	_ok(int(panel.get("sel_cv")) == sim.vessel_cv and int(canvas.get("selected_cv")) == sim.vessel_cv, "a click on the vessel selects its volume")
	var pipe: Dictionary = {}
	for p in doc.get("pipes", []):
		if int(p["shell"]) >= 0:
			pipe = p
			break
	var pp: Vector2 = canvas.global_position + (canvas.call("pipe_screen_point", str(pipe["id"]), 0.5) as Vector2)
	await HarnessInput.click(vp, pp)
	await _settle(tree, 4)
	_ok(int(panel.get("sel_cv")) != sim.vessel_cv and int(panel.get("sel_cv")) >= 0,
		"a click on a condenser selects it (volume %d, wanted %d)" % [int(panel.get("sel_cv")), int(pipe["cv"])])

	# ---- a heater's faceplate ----
	var heater := _el(canvas, "heater")
	var pid := str(heater["part"])
	await HarnessInput.click(vp, _center(canvas, heater))
	await _settle(tree, 6)
	var face: Control = panel.get("_face")
	_ok(face != null and face.visible and str(face.call("shown_for")) == str(heater["id"]), "a click on an element opens its faceplate")
	if face != null and face.visible:
		_ok(Rect2(Vector2.ZERO, vp.get_visible_rect().size).encloses(face.get_global_rect()), "the faceplate is inside the window")
		var off: Button = face.call("button", "off")
		_ok(off != null and not off.disabled, "it offers Switch off")
		await _shot(main, "02_faceplate")
		await HarnessInput.click(vp, HarnessInput.center_of(off))
		await _settle(tree, 6)
		_ok(not TcProcControl.is_on(sim, "heater:%s" % pid), "a REAL click on Switch off turns the element off in the model")
		_ok(not bool(((canvas.get("state") as Dictionary).get("heater", {}) as Dictionary).get(pid, {}).get("on", true)), "…and in the picture")
		var on: Button = face.call("button", "on")
		_ok(on != null and not on.disabled, "the plate now offers Switch on")
		if on != null:
			await HarnessInput.click(vp, HarnessInput.center_of(on))
			await _settle(tree, 6)
		_ok(TcProcControl.is_on(sim, "heater:%s" % pid), "Switch on brings it back")

	# ---- the drain valve ----
	await HarnessInput.key(vp, KEY_ESCAPE)
	await _settle(tree, 4)
	_ok(face == null or not face.visible, "Esc puts the faceplate away")
	_ok(bool(ui.call("is_open")), "…and leaves the designer open")
	var valve := _el(canvas, "valve")
	_ok(not valve.is_empty(), "the drain's valve is on the picture")
	if not valve.is_empty():
		await HarnessInput.click(vp, _center(canvas, valve))
		await _settle(tree, 6)
		_ok(face != null and face.visible and str(face.call("shown_for")) == str(valve["id"]), "a click on the valve opens its faceplate")
		var was := TcProcControl.is_on(sim, "valve:%s" % str(valve["part"]))
		var btn: Button = face.call("button", "off" if was else "on")
		if btn != null:
			await HarnessInput.click(vp, HarnessInput.center_of(btn))
			await _settle(tree, 6)
		_ok(TcProcControl.is_on(sim, "valve:%s" % str(valve["part"])) != was, "its button moves the valve in the model (%s → %s)" % ["open" if was else "closed", "closed" if was else "open"])
		# Put it back.
		var back: Button = face.call("button", "on" if was else "off")
		if back != null:
			await HarnessInput.click(vp, HarnessInput.center_of(back))
			await _settle(tree, 6)

	# ---- empty click closes the plate ----
	await HarnessInput.click(vp, canvas.global_position + Vector2(14, canvas.size.y - 14))
	await _settle(tree, 4)
	_ok(face == null or not face.visible, "a click on empty picture puts the faceplate away")

	# ---- drag the vessel ----
	var t_before := float(panel.call("time_h"))
	var done_before := float(panel.get("done_s"))
	var c0 := _center(canvas, vessel)
	var pipe_near: Vector2 = canvas.call("pipe_screen_point", str(pipe["id"]), 0.5)
	var offs0 := {}
	for e in (canvas.get("doc") as Dictionary).get("elements", []):
		offs0[str(e["id"])] = canvas.call("offset_of", str(e["id"]))
	await HarnessInput.drag(vp, c0, c0 + Vector2(90, 40), 10)
	await _settle(tree, 8)
	canvas = panel.get("mimic")
	vessel = _el(canvas, "vessel")
	var c1 := _center(canvas, vessel)
	_ok(c1.distance_to(c0 + Vector2(90, 40)) < 12.0, "dragging the vessel moves it (%s)" % str(c1 - c0))
	var spec: Dictionary = ui.get("_spec")
	var pins: Dictionary = ((spec.get("process", {}) as Dictionary).get("mimic", {}) as Dictionary).get("pins", {})
	_ok(pins.has(str(vessel["id"])), "the move is saved in the design's process")
	_ok(panel.get("sim") == sim and absf(float(panel.call("time_h")) - t_before) < 1e-6 and absf(float(panel.get("done_s")) - done_before) < 1e-6,
		"and the run was not restarted")
	var pipe_after: Vector2 = canvas.call("pipe_screen_point", str(pipe["id"]), 0.5)
	print("tc_pid: a condenser's middle moved %s with the vessel" % str(pipe_after - pipe_near))
	var sq: Array = _square_lines(canvas)
	_ok(int(sq[0]) >= 1 and int(sq[1]) == 0, "the pipes on the vessel follow it and stay square (%d moved, %d bent)" % [int(sq[0]), int(sq[1])])
	var lab_far := 0
	for e in (canvas.get("doc") as Dictionary).get("elements", []):
		if str(e["id"]) != str(vessel["id"]) and str(e["kind"]) != "widget" and int(e.get("cv", -1)) != int(vessel["cv"]) \
				and (canvas.call("offset_of", str(e["id"])) as Vector2) != (offs0.get(str(e["id"]), Vector2.ZERO) as Vector2):
			lab_far += 1
	_ok(lab_far == 0, "nothing that is not on the vessel moved with it (%d)" % lab_far)
	await _shot(main, "03_dragged")
	await HarnessInput.key(vp, KEY_Z, true)
	await _settle(tree, 8)
	spec = ui.get("_spec")
	pins = ((spec.get("process", {}) as Dictionary).get("mimic", {}) as Dictionary).get("pins", {})
	_ok(not pins.has(str(vessel["id"])), "Ctrl+Z puts it back")

	# ---- zoom and fit ----
	canvas = panel.get("mimic")
	var z0 := float(canvas.call("zoom"))
	var at := canvas.global_position + canvas.size * 0.5
	await HarnessInput.mouse_move(vp, at)
	for _i in 3:
		# Press AND release: an unreleased wheel "button" keeps the mouse
		# focus on the picture, and the next click never reaches its button.
		for down in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_WHEEL_UP
			ev.pressed = down
			ev.position = at
			ev.global_position = at
			vp.push_input(ev, true)
		await tree.process_frame
	_ok(float(canvas.call("zoom")) > z0 * 1.3, "the wheel zooms in (%.2f → %.2f)" % [z0, float(canvas.call("zoom"))])
	await _shot(main, "04_zoomed")
	canvas.call("fit")
	await _settle(tree, 3)
	_ok(absf(float(canvas.call("zoom")) - z0) < z0 * 0.05, "fit comes back")

	# ---- audit, then off ----
	var audit: Dictionary = UiAudit.run(vp)
	print("tc_pid: audit %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors with the picture up")
	await HarnessInput.click(vp, HarnessInput.center_of(pid_btn))
	await _settle(tree, 6)
	_ok(not canvas.visible and not bool(panel.get("pid_on")), "P&ID off gives the 3D studio back (visible %s, on %s, button %s)" % [
		canvas.visible, panel.get("pid_on"), pid_btn.button_pressed])
	ui.call("set_run_mode", false)
	await _settle(tree, 4)
	ui.call("close")
	await _settle(tree, 6)
	return {"ok": _fails.is_empty(), "failures": _fails}


## After a drag: every line whose end moved is still square (each leg along
## an axis or along a leg it had) and still ends on the thing it joins.
## [lines that moved, lines that broke].
func _square_lines(canvas: Control) -> Array:
	var moved := 0
	var bad := 0
	for p in (canvas.get("doc") as Dictionary).get("pipes", []):
		var ends: Array = canvas.call("pipe_ends", str(p["id"]))
		var da: Vector2 = canvas.call("offset_of", str(ends[0]))
		var db: Vector2 = canvas.call("offset_of", str(ends[1]))
		if da == Vector2.ZERO and db == Vector2.ZERO:
			continue
		moved += 1
		var c0: PackedVector2Array = p.get("corners", p["pts"])
		var c: PackedVector2Array = canvas.call("pipe_corners", p)
		var dirs: Array = []
		for i in range(1, c0.size()):
			dirs.append((c0[i] - c0[i - 1]).normalized())
		var ok := c.size() >= 2 and c[0].distance_to(c0[0] + da) < 0.5 and c[c.size() - 1].distance_to(c0[c0.size() - 1] + db) < 0.5
		for i in range(1, c.size()):
			var d := (c[i] - c[i - 1]).normalized()
			var leg_ok := absf(d.x) < 0.002 or absf(d.y) < 0.002
			for q in dirs:
				if absf(d.cross(q as Vector2)) < 0.002:
					leg_ok = true
			if not leg_ok:
				ok = false
		if not ok:
			bad += 1
			print("  bent line %s: %s" % [str(p["id"]), str(c)])
	return [moved, bad]
