extends RefCounted

## The Community schedule with REAL input (sandbox; a world with simulated
## people — Closed Loop Ten has ten and a rota):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/community_schedule_check.gd -Label community_schedule -Timeout 1200
## Opens it from the timeline's people button; the Day tab has a row per
## person whose day tiles midnight to midnight; a REAL click on a person opens
## their Person tab; a profile edit through the slider's box and a REAL click
## on Apply saves the override and plans the week again; the Week tab: a REAL
## Add makes a deploy event, a REAL drag moves it a day and two hours on (the
## timeline's flag moves with it), a REAL click selects it and Remove takes it
## away; Work and Balance fill; Export writes the group calendar and one per
## person, which parse, and a second export keeps every UID. UiAudit on each
## tab (run with -UserArgs @("--window-size=1280x720") too). Shots per tab.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("schedcheck %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _shot(vp: Viewport, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _audit(vp: Viewport, what: String) -> void:
	var audit := UiAudit.run(vp)
	print("schedcheck: audit %s — %s" % [what, UiAudit.summary_line(audit)])
	for f in audit.get("findings", []):
		if str(f.get("severity", "")) == "error":
			print("schedcheck:   %s %s \"%s\"" % [f.get("kind"), f.get("path"), str(f.get("text", "")).left(50)])
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit: no errors (%s)" % what)


func _at(c: Control, local: Vector2) -> Vector2:
	return c.get_global_transform_with_canvas() * local


func _mid(c: Control) -> Vector2:
	return _at(c, c.size * 0.5)


func _find(root: Node, nm: String) -> Node:
	return root.find_child(nm, true, false) if root != null else null


func _scroll_to(c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
			return
		p = p.get_parent()


func _click(tree: SceneTree, vp: Viewport, c: Control) -> void:
	_scroll_to(c)
	await _frames(tree, 3)
	await HarnessInput.click(vp, _mid(c))
	await _frames(tree, 3)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	# Let the people simulate long enough for the day's rota to be planned.
	main.set("time_scale", 60.0 / 3600.0)
	var b := ScheduleSources.bridge()
	var t0 := Time.get_ticks_msec()
	while (b == null or b.pop_driven_item_ids().is_empty()) and Time.get_ticks_msec() - t0 < 60000:
		await _frames(tree, 10)
		b = ScheduleSources.bridge()
	_ok(b != null and not b.pop_driven_item_ids().is_empty(), "a simulated camp")
	if b == null or b.pop_driven_item_ids().is_empty():
		return {"ok": false, "fails": _fails}
	await _frames(tree, 30)
	main.set("time_scale", 0.0)

	var tlui: Node = ServiceLocator.timeline_ui()
	var btn: Button = _find(tlui, "CommunityScheduleBtn") as Button
	if btn != null and btn.is_visible_in_tree():
		await _click(tree, vp, btn)
	else:
		print("schedcheck: the people button is folded into ⋯ at this width; opening through TimelineUI")
		tlui.call("open_community_schedule", "Day")
		await _frames(tree, 4)
	var cs: Node = _find(tlui, "CommunityScheduleModal")
	_ok(cs != null and bool(cs.call("is_open")), "the Community schedule opened from the timeline")
	if cs == null:
		return {"ok": false, "fails": _fails}
	await _frames(tree, 6)
	var hab := str(cs.call("habitat"))
	var people := ScheduleSources.people(hab)
	_ok(people.size() >= 2, "a camp with people (%d in %s)" % [people.size(), hab])

	# --- Day ---
	var dg: GanttRows = cs.call("day_gantt")
	_ok(dg != null and dg.rows.size() == people.size() + 1,
		"Day: a Site row and a row per person (%d rows)" % (dg.rows.size() if dg != null else 0))
	var tiles := true
	for r in dg.rows.slice(1):
		var tot := 0.0
		for s in (r as Dictionary)["segs"]:
			tot += float(s["b"]) - float(s["a"])
		if absf(tot - 24.0) > 0.01:
			tiles = false
	_ok(tiles, "Day: every person's day tiles midnight to midnight")
	var sleep_rows := 0
	for r in dg.rows.slice(1):
		for s in (r as Dictionary)["segs"]:
			if str(s["kind"]) == "sleep":
				sleep_rows += 1
				break
	_ok(sleep_rows == people.size(), "Day: everyone sleeps (%d of %d)" % [sleep_rows, people.size()])
	var shift_segs := 0
	for r in dg.rows.slice(1):
		for s in (r as Dictionary)["segs"]:
			if str(s["kind"]) == "shift":
				shift_segs += 1
	print("schedcheck: %d rota shifts drawn today" % shift_segs)
	_ok(not is_nan(dg.now_h), "Day: the NOW line is set")
	_shot(vp, "01_day")
	_audit(vp, "Day")

	# A REAL click on the second person's row label opens their Person tab.
	var target_row: Dictionary = dg.rows[2] if dg.rows.size() > 2 else dg.rows[1]
	var pid := str(target_row["id"])
	var row_pt := dg.point_at(pid, float(target_row["t0"]))
	_scroll_to(dg)
	await _frames(tree, 3)
	await HarnessInput.click(vp, _at(dg, Vector2(40.0, row_pt.y)))
	await _frames(tree, 6)
	_ok(str(cs.call("current_tab")) == "Person" and str(cs.get("_person")) == pid,
		"a REAL click on a person opens their Person tab (%s)" % str(cs.get("_person")))
	var pg: GanttRows = cs.get("_person_gantt")
	_ok(pg != null and pg.rows.size() == 7, "Person: a week of their days")
	_shot(vp, "02_person")
	_audit(vp, "Person")

	# Profile: sleep need through the slider's own box, then a REAL Apply.
	var slider_n := _find(cs.get("_person_form"), "pf_sleep_need_h")
	var row: FormRow = (slider_n if slider_n is FormRow else (slider_n.get_parent() if slider_n != null else null)) as FormRow
	_ok(row != null and row.spin_box != null, "Person: the sleep-need row")
	var before := b.persona_of(hab, pid)
	var want := 9.0 if float(before.get("sleep_need_h", 8.0)) < 8.75 else 7.0
	if row != null and row.spin_box != null:
		row.spin_box.value = want
	var apply_btn: Button = _find(cs.get("_person_form"), "profile_apply") as Button
	if apply_btn != null:
		await _click(tree, vp, apply_btn)
	var after := b.persona_of(hab, pid)
	_ok(absf(float(after.get("sleep_need_h", 0.0)) - want) < 0.01,
		"a REAL Apply saves the profile (sleep %.2f -> %.2f h)" % [float(before.get("sleep_need_h", 0.0)),
			float(after.get("sleep_need_h", 0.0))])
	var g := ServiceLocator.graph()
	var item: Dictionary = g.get("model").get_item(hab) if g != null else {}
	_ok(((item.get("specs", {}) as Dictionary).get("pop_personas", {}) as Dictionary).has(pid),
		"the override is in the habitat's specs (saved with the world)")
	_ok(not b.rota_for(hab).is_empty(), "the week was planned again")
	# Put the person back.
	b.set_persona(hab, pid, {})

	# --- Week: add, drag, select, remove ---
	await _click(tree, vp, _find(cs.get("_frame"), "tab_week") as Control)
	_ok(str(cs.call("current_tab")) == "Week", "a REAL click on the Week tab")
	var sd := ScheduleSources.deploy()
	var n0: int = sd.events().size() if sd != null else 0
	var page: Control = (cs.get("_pages") as Dictionary)["Week"]
	var hour: SpinBox = _find(page, "new_hour") as SpinBox
	hour.value = 15.0
	var dayo: OptionButton = _find(page, "new_day") as OptionButton
	dayo.select(1)
	var day1 := int(dayo.get_item_metadata(1))
	await _click(tree, vp, _find(page, "new_add") as Control)
	var evs: Array = sd.events() if sd != null else []
	var new_ev: Dictionary = {}
	for e in evs:
		if absf(float((e as Dictionary)["at_h"]) - (float(day1) * 24.0 + 15.0)) < 0.01:
			new_ev = e
	_ok(evs.size() == n0 + 1 and not new_ev.is_empty(), "a REAL Add makes a deploy event on day 2 at 15:00")
	await _frames(tree, 4)
	var wg: GanttRows = cs.call("week_gantt")
	var eid := str(new_ev.get("id", ""))
	var a := _at(wg, wg.seg_center("d%d" % day1, eid))
	var to_h := float(day1 + 1) * 24.0 + 17.0
	var bpt := _at(wg, wg.point_at("d%d" % (day1 + 1), to_h))
	_ok(a.x >= 0.0 and bpt.x >= 0.0, "the new flag is drawn in its day's row")
	_scroll_to(wg)
	await _frames(tree, 3)
	a = _at(wg, wg.seg_center("d%d" % day1, eid))
	bpt = _at(wg, wg.point_at("d%d" % (day1 + 1), to_h))
	await HarnessInput.drag(vp, a, bpt, 14)
	await _frames(tree, 6)
	var moved_h := NAN
	for e in sd.events():
		if str((e as Dictionary)["id"]) == eid:
			moved_h = float((e as Dictionary)["at_h"])
	_ok(not is_nan(moved_h) and absf(moved_h - to_h) <= 0.26,
		"a REAL drag moves it to the next day at 17:00 (%.2f h off)" % (moved_h - to_h))
	_ok(absf(float(tlui.call("_deploy_event_time", eid)) - moved_h) < 1e-3,
		"the timeline's flag moved with it")
	_shot(vp, "03_week")
	_audit(vp, "Week")
	var c2 := _at(wg, wg.seg_center("d%d" % (day1 + 1), eid))
	await HarnessInput.click(vp, c2)
	await _frames(tree, 4)
	var rm: Button = _find(page, "sel_remove") as Button
	_ok(rm != null, "a REAL click selects the event (Remove offered)")
	if rm != null:
		await _click(tree, vp, rm)
	var still := false
	for e in sd.events():
		if str((e as Dictionary)["id"]) == eid:
			still = true
	_ok(not still and sd.events().size() == n0, "Remove takes it away")

	# --- Work + Balance ---
	await _click(tree, vp, _find(cs.get("_frame"), "tab_work") as Control)
	var wb: Node = cs.get("_work_box")
	_ok(wb != null and wb.get_child_count() >= 2, "Work: the week's jobs (%d children)" % (wb.get_child_count() if wb != null else 0))
	_shot(vp, "04_work")
	_audit(vp, "Work")
	await _click(tree, vp, _find(cs.get("_frame"), "tab_balance") as Control)
	var bb: Node = cs.get("_balance_box")
	_ok(bb != null and bb.get_child_count() >= people.size(), "Balance: a bar per person")
	_shot(vp, "05_balance")
	_audit(vp, "Balance")

	# --- Export ---
	await _click(tree, vp, _find(cs.get("_frame"), "export_ics") as Control)
	var res: Dictionary = cs.get_meta("last_export", {}) if cs.has_meta("last_export") else {}
	var files: Array = res.get("files", [])
	_ok(files.size() == people.size() + 1, "a REAL Export writes the group calendar + one per person (%d)" % files.size())
	var group_txt := FileAccess.get_file_as_string(str(files[0])) if not files.is_empty() else ""
	var parsed := IcsWriter.parse(group_txt)
	_ok((parsed["events"] as Array).size() > 0 and str(parsed["tzid"]) == IcsWriter.TZID,
		"the group calendar parses (%d events)" % (parsed["events"] as Array).size())
	var uids1 := {}
	for e in parsed["events"]:
		uids1[str((e as Dictionary).get("UID", ""))] = true
	var res2 := ScheduleSources.export_ics(float(ScheduledEvents.day_of(ScheduleSources.now_h())) * 24.0,
		float(ScheduledEvents.day_of(ScheduleSources.now_h())) * 24.0 + 168.0)
	var p2 := IcsWriter.parse(FileAccess.get_file_as_string(str((res2["files"] as Array)[0])))
	var same := (p2["events"] as Array).size() == uids1.size()
	for e in p2["events"]:
		if not uids1.has(str((e as Dictionary).get("UID", ""))):
			same = false
	_ok(same, "a second export keeps every UID (an import updates)")
	var person_txt := FileAccess.get_file_as_string(str(files[1])) if files.size() > 1 else ""
	_ok(person_txt.contains("BEGIN:VCALENDAR") and person_txt.contains("X-WR-CALNAME:"),
		"a person's calendar")
	print("schedcheck: exported to %s" % ProjectSettings.globalize_path(str(res.get("dir", ""))))
	cs.call("close")
	await _frames(tree, 3)
	_ok(not bool(cs.call("is_open")), "closed")
	return {"ok": _fails.is_empty(), "fails": _fails}
