class_name BootcampAudit
extends Node

## `--capture=bootcamp`: play all twelve Solar Bootcamp levels the way a player
## does — real mouse drags from port to port on the freeform canvas, the ▶ Run
## button on the run-levels, Ctrl-click + Ctrl+G on the last one — and shoot
## each stage. It is the regression gate for the graph view: the levels are a
## fixed, small, readable set of graphs that exercise wiring, faults, flow,
## runs and grouping.
##
## Hard failures (FAIL lines):
##   - a level that does not complete;
##   - a wire drag that did not create a connection (it is then added through
##     the model so the level can go on — that is how a stale modal eating the
##     pointer showed up: two of 50 drags failed, both right after a level);
##   - a stale card still up when a level starts.
## Per level it writes <shots>/<NN>_<stage>.png, including a CLEAN shot of the
## finished graph with the debrief closed (the debrief otherwise covers the
## circuit the moment it works), runs UiAudit on the seed and clean shots, and
## writes bootcamp_audit.json. Report lines are lower case on purpose (the
## harness counts upper-case FAIL tokens).

const RUN_TIMEOUT_S := 120.0

var main: Node = null
var shots_dir := "user://screenshots/bootcamp"
var strict := false
## --bootcamp-from=N: start at level N (1-based) for quick iteration.
var start_level := 1

var _sgv: Node = null
var _canvas: Control = null
var _td: Node = null
var _vp: Viewport = null
var _levels: Array = []
var _cur: Dictionary = {}
var _fails := 0


func run() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	_vp = get_viewport()
	_sgv = main.find_child("SystemGraphView", true, false) if main != null else null
	if _sgv == null:
		_fail("setup", "no SystemGraphView")
		return _summary()
	_td = _sgv.call("_ensure_tutorial_director")
	if _td == null:
		_fail("setup", "no tutorial director")
		return _summary()
	var ids: Array = TutorialCatalog.ordered_ids()
	var first := clampi(start_level, 1, ids.size()) - 1
	_td.call("start", str(ids[first]))
	await _wait(1.0)
	_canvas = _sgv.get("_graph_canvas")
	for i in range(first, ids.size()):
		var lid := str(ids[i])
		var lvl: Variant = _td.get("_level")
		if lvl == null or str(lvl.get("id")) != lid:
			_note("%s: not current (have %s) — starting it directly" % [lid,
				str(lvl.get("id")) if lvl != null else "none"])
			if bool(_td.call("is_active")):
				_td.call("exit_tutorial")
				await _wait(0.8)
			_td.call("start", lid)
			await _wait(1.0)
		_cur = {"n": i + 1, "id": lid, "drags": 0, "fallbacks": 0, "complete": false,
			"progress": "", "audit": {}}
		await _play_level(i + 1)
		_levels.append(_cur)
	await _shot("99_a_final")
	# Layout ▾ → Tidy on the finished (player-built) graph, then the two new
	# settings popovers, shot and audited.
	if bool(_sgv.call("tidy_layout", true, true)):
		await _wait(1.0)
		await _shot("99_a2_tidied")
	for pop in [["_open_layout_settings", "_layout_settings_popup", "99_a3_layout_settings"],
			["_open_display_settings", "_display_settings_popup", "99_a4_display_settings"]]:
		_sgv.call(str(pop[0]))
		await _wait(0.5)
		await _shot(str(pop[2]))
		var res := UiAudit.run(main.get_tree().root.get_viewport())
		_note("%s: %s" % [str(pop[2]), UiAudit.summary_line(res)])
		var w: Variant = _sgv.get(str(pop[1]))
		if w is Window:
			(w as Window).hide()
		await _wait(0.2)
	if bool(_td.call("is_active")):
		_td.call("exit_tutorial")
	await _wait(1.0)
	await _shot("99_b_exit_restored")
	return _summary()


func _summary() -> Dictionary:
	var drags := 0
	var fb := 0
	var done := 0
	for l in _levels:
		drags += int((l as Dictionary).get("drags", 0))
		fb += int((l as Dictionary).get("fallbacks", 0))
		done += 1 if bool((l as Dictionary).get("complete", false)) else 0
	var s := {"levels": _levels, "drags": drags, "fallbacks": fb, "completed": done,
		"failures": _fails, "viewport": [int(_vp.get_visible_rect().size.x) if _vp else 0,
			int(_vp.get_visible_rect().size.y) if _vp else 0]}
	HarnessReport.write_json("%s/bootcamp_audit.json" % shots_dir, s)
	return s


func _play_level(n: int) -> void:
	var p := "%02d" % n
	await _wait(1.2)
	await _shot(p + "_a_brief")
	await _dismiss_brief()
	await _wait(0.6)
	if _card_showing():
		_fail(p, "a card is still up after the brief was dismissed (stale queue?)")
		await _shot(p + "_a2_stale_card")
		_sgv.get("_fault_card_modal").call("close")
		await _wait(0.4)
	await _park_pointer()
	await _shot(p + "_b_seed")
	_cur["audit"]["seed"] = _audit()
	_cur["layout"] = _layout_report()
	match n:
		1:
			var b: Dictionary = _of("battery")[0]
			await _wire(b, "positive", b, "negative", p)
		2:
			var b: Dictionary = _of("battery")[0]
			var pa: Dictionary = _of("panel")[0]
			await _wire(pa, "positive", b, "positive", p)
			await _wire(pa, "negative", b, "negative", "")
		3:
			var b: Dictionary = _of("battery")[0]
			var pa: Dictionary = _of("panel")[0]
			var c: Dictionary = _of("controller")[0]
			await _wire(pa, "positive", c, "pvPositive", p)
			await _wire(pa, "negative", c, "pvNegative", "")
			await _wire(c, "batteryPositive", b, "positive", "")
			await _wire(c, "batteryNegative", b, "negative", "")
		4:
			var b: Dictionary = _of("battery")[0]
			var c: Dictionary = _of("controller")[0]
			var first := true
			for pa: Dictionary in _of("panel"):
				await _wire(pa, "positive", c, "pvPositive", p if first else "")
				await _wire(pa, "negative", c, "pvNegative", "")
				first = false
			await _wire(c, "batteryPositive", b, "positive", "")
			await _wire(c, "batteryNegative", b, "negative", "")
		5, 6:
			var bs: Array = _of("battery")
			var c: Dictionary = _of("controller")[0]
			for k in range(bs.size() - 1):
				await _wire(bs[k], "positive", bs[k + 1], "negative", p if k == 0 else "")
			for pa: Dictionary in _of("panel"):
				await _wire(pa, "positive", c, "pvPositive", "")
				await _wire(pa, "negative", c, "pvNegative", "")
			await _wire(c, "batteryPositive", bs[bs.size() - 1], "positive", "")
			await _wire(c, "batteryNegative", bs[0], "negative", "")
		7:
			var c: Dictionary = _of("controller")[0]
			var ps: Array = _of("panel")
			for s in [0, 3]:
				await _wire(ps[s], "positive", ps[s + 1], "negative", p if s == 0 else "")
				await _wire(ps[s + 1], "positive", ps[s + 2], "negative", "")
				await _wire(ps[s + 2], "positive", c, "pvPositive", "")
				await _wire(ps[s], "negative", c, "pvNegative", "")
		8, 10, 11:
			await _run_day(p)
		9:
			var c: Dictionary = _of("controller")[0]
			var preset: Dictionary = TutorialCatalog.find_preset("LED Light")
			if preset.is_empty():
				preset = TutorialCatalog.find_preset("Custom Load")
			var model: Object = _sgv.get("model")
			var dims: Vector2 = ComponentPresets.spawn_dimensions(preset)
			var iid: String = model.call("generate_item_id")
			model.call("add_item", {"id": iid, "type": str(preset.get("type", "appliance")),
				"x": float(c.get("x", 0.0)) + 260.0, "y": float(c.get("y", 0.0)) + 200.0,
				"width": dims.x, "height": dims.y, "scope_id": "root",
				"specs": (preset.get("specs", {}) as Dictionary).duplicate(true), "is_virtual": false})
			await _wait(0.5)
			var ap: Dictionary = model.call("get_item", iid)
			await _wire(c, "acOutput", ap, "input", p)
		12:
			var c: Dictionary = _of("controller")[0]
			var b: Dictionary = _of("battery")[0]
			# Exactly what the brief tells the player: Ctrl-click both.
			await _ctrl_click(_center(c))
			await _ctrl_click(_center(b))
			if (_sgv.get("_selected_item_ids") as Array).size() != 2:
				_fail("12", "Ctrl-click did not build a two-node selection (%s)" % str(_sgv.get("_selected_item_ids")))
			await _wait(0.3)
			await _shot(p + "_c_two_selected")
			await HarnessInput.key(_vp, KEY_G, true)
			await _wait(1.0)
			await _shot(p + "_d_grouped")
	await _wait(1.5)
	await _shot(p + "_f_after")
	var waited := 0.0
	while _state() != 3 and waited < 9.0:
		await _close_non_debrief_card(p)
		await _wait(0.5)
		waited += 0.5
	_cur["progress"] = _hud_progress()
	_cur["complete"] = _state() == 3
	if not bool(_cur["complete"]):
		# Level 11 is a tuning puzzle (≥ 60 % of the sun put to work); the
		# audit does not solve it. What it checks is that a clean-but-short run
		# says so and keeps saying so — the HUD used to forget the verdict.
		if n == 11 and str(_cur["progress"]).contains("% of the sun"):
			_cur["verdict_shown"] = true
			_note("%s run verdict shown, puzzle left unsolved: %s" % [p, str(_cur["progress"])])
			await _shot(p + "_g_verdict")
			return
		_fail(p, "level did not complete — %s" % str(_cur["progress"]))
		await _shot(p + "_g_not_complete")
		return
	await _shot(p + "_g_debrief")
	# The finished graph, uncovered — what the player should get to look at.
	var m: Variant = _sgv.get("_fault_card_modal")
	if m != null and bool(m.call("is_showing")):
		m.call("close")
	await _wait(0.5)
	await _park_pointer()
	await _wait(0.3)
	await _shot(p + "_h_clean")
	_cur["audit"]["clean"] = _audit()
	_note("%s complete — %d drag(s), %d fallback(s) · %s" % [p, int(_cur["drags"]),
		int(_cur["fallbacks"]), str(_cur["progress"])])
	_td.call("_on_next_level")
	await _wait(0.8)


## How far the seeded nodes sit from their catalog positions (the bootcamp
## tidies every seeded level) and whether any two cards overlap.
func _layout_report() -> Dictionary:
	var lvl: Variant = _td.get("_level")
	var seed: Array = lvl.get("seed") if lvl != null else []
	var items: Array = (_sgv.get("model") as Object).call("get_items_in_scope", "root")
	var moved := 0.0
	for i in mini(seed.size(), items.size()):
		var e: Dictionary = seed[i]
		var it: Dictionary = items[i]
		moved = maxf(moved, Vector2(float(e.get("x", 0.0)), float(e.get("y", 0.0))).distance_to(
			Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0)))))
	var overlaps := 0
	for i in items.size():
		for j in range(i + 1, items.size()):
			var a: Dictionary = items[i]
			var b: Dictionary = items[j]
			var ra := Rect2(float(a.get("x", 0.0)), float(a.get("y", 0.0)), float(a.get("width", 0.0)), float(a.get("height", 0.0)))
			var rb := Rect2(float(b.get("x", 0.0)), float(b.get("y", 0.0)), float(b.get("width", 0.0)), float(b.get("height", 0.0)))
			if ra.intersects(rb):
				overlaps += 1
	var drv: Variant = _sgv.get("_layout_driver")
	_note("%02d layout: max move from seed %.0f px, %d overlapping pair(s), driver %s" % [
		int(_cur.get("n", 0)), moved, overlaps, "up" if drv != null else "none"])
	if overlaps > 0:
		_fail("%02d" % int(_cur.get("n", 0)), "%d card pair(s) overlap after the level loaded" % overlaps)
	return {"max_move_px": moved, "overlaps": overlaps}


func _run_day(p: String) -> void:
	var btn := HarnessInput.find_button(main.get_tree().root, "Run 24 h", true)
	if btn != null:
		await HarnessInput.click(_vp, HarnessInput.center_of(btn))
	else:
		_td.call("_on_run_requested")
	await _wait(3.0)
	await _shot(p + "_c_running")
	var t := 0.0
	var mid := false
	while t < RUN_TIMEOUT_S:
		await _wait(1.0)
		t += 1.0
		if not mid and t > 8.0:
			await _shot(p + "_d_playback")
			mid = true
		if _state() == 3:
			break
		var eng: Variant = _td.get("_run_engine")
		if eng != null and int(eng.call("phase")) == ChallengeBakeEngine.Phase.AWAIT_RETRY:
			await _shot(p + "_e_run_failed")
			break
		if eng != null and not bool(eng.call("is_active")) and t > 4.0:
			break  # the run ended without completing — the verdict is the HUD's
		var skip := HarnessInput.find_button(main.get_tree().root, "Skip", true)
		if skip != null and t > 12.0:
			await HarnessInput.click(_vp, HarnessInput.center_of(skip))


func _dismiss_brief() -> void:
	var b := HarnessInput.find_button(main.get_tree().root, "Let's go")
	if b != null:
		await HarnessInput.click(_vp, HarnessInput.center_of(b))
	else:
		var m: Variant = _sgv.get("_fault_card_modal")
		if m != null:
			m.call("close")
		_td.call("_on_brief_done")
	await _wait(0.3)


## A fault card that is not the debrief (the explanation the level's failure is
## about) — shoot it, then close it the way a player would.
func _close_non_debrief_card(p: String) -> void:
	if not _card_showing() or _state() == 3:
		return
	await _shot("%s_f_fault_card" % p)
	_sgv.get("_fault_card_modal").call("close")
	await _wait(0.5)


func _card_showing() -> bool:
	var m: Variant = _sgv.get("_fault_card_modal")
	return m != null and bool(m.call("is_showing"))


func _state() -> int:
	return int(_td.get("_state"))


func _of(t: String) -> Array:
	var model: Object = _sgv.get("model")
	var out: Array = []
	for it in model.call("get_items_in_scope", "root"):
		var d: Dictionary = it
		if str(d.get("type", "")) == t:
			out.append(d)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("x", 0.0)) < float(b.get("x", 0.0)))
	return out


func _to_vp(p: Vector2) -> Vector2:
	return _canvas.get_global_transform_with_canvas() * p


func _handle_screen(item: Dictionary, hid: String) -> Vector2:
	var infos: Array = _canvas.call("_get_all_handle_infos", item, _canvas.size * 0.5)
	for h: Dictionary in infos:
		if str(h.get("handle_id", "")) == hid:
			return _to_vp(h["pos"] as Vector2)
	return Vector2.INF


func _center(item: Dictionary) -> Vector2:
	var c: Vector2 = _canvas.size * 0.5
	var tl: Vector2 = _canvas.call("_item_screen_tl", item, c)
	var sz: Vector2 = _canvas.call("_item_screen_size", item)
	return _to_vp(tl + sz * 0.5)


## Move the pointer off the canvas (onto the timeline) so a hover highlight
## does not dim the shot.
func _park_pointer() -> void:
	var r := _vp.get_visible_rect()
	await HarnessInput.mouse_move(_vp, Vector2(r.size.x * 0.5, r.size.y - 30.0))


func _ctrl_click(pos: Vector2) -> void:
	await HarnessInput.mouse_move(_vp, pos, true)
	await HarnessInput.mouse_press(_vp, pos, true, false, true)
	await HarnessInput.mouse_press(_vp, pos, false, false, true)


func _conn_count() -> int:
	return ((_sgv.get("model") as Object).get("connections") as Array).size()


## Drag a wire with the mouse; if no connection appears, record a fallback
## (a FAIL) and add it through the model so the level can carry on.
func _wire(a: Dictionary, ah: String, b: Dictionary, bh: String, shot_prefix: String) -> void:
	var model: Object = _sgv.get("model")
	a = model.call("get_item", str(a.get("id")))
	b = model.call("get_item", str(b.get("id")))
	var pa := _handle_screen(a, ah)
	var pb := _handle_screen(b, bh)
	var before := _conn_count()
	var diag := ""
	if pa != Vector2.INF and pb != Vector2.INF:
		await HarnessInput.mouse_move(_vp, pa)
		await HarnessInput.mouse_press(_vp, pa, true)
		var started := bool(_canvas.get("_wire_dragging"))
		for i in range(1, 13):
			await HarnessInput.mouse_move(_vp, pa.lerp(pb, float(i) / 12.0), false, false, true)
			if i == 10 and not shot_prefix.is_empty():
				await _shot(shot_prefix + "_c_dragging_wire")
		# The OS's own motion from the previous warp can land AFTER the last
		# synthetic one and leave the wire a step short (level 4 dropped at
		# the 11/12 point twice running). Re-assert the drop point first.
		await get_tree().process_frame
		await HarnessInput.mouse_move(_vp, pb, false, false, true)
		var snap: Variant = _canvas.get("_wire_snap")
		var b_now: Dictionary = model.call("get_item", str(b.get("id")))
		var pb_now := _handle_screen(b_now, bh)
		var near: Dictionary = _canvas.call("_port_at_screen", _canvas.get_global_transform_with_canvas().affine_inverse() * pb, "", "", 40.0)
		diag = "port now %s (moved %.1f px) · nearest %s.%s · " % [str(pb_now), pb_now.distance_to(pb),
			str(near.get("item_id", "-")), str(near.get("handle_id", "-"))]
		diag += "canvas cursor %s · " % str(_canvas.get_global_transform_with_canvas() * (_canvas.get("_wire_cursor_pos") as Vector2))
		diag += "started=%s dragging=%s snap=%s valid=%s modal=%s" % [started,
			_canvas.get("_wire_dragging"),
			str((snap as Dictionary).get("handle_id", "-")) if snap is Dictionary else "-",
			_canvas.get("_wire_snap_valid"), CursorController.has_blocking_modal()]
		await HarnessInput.mouse_press(_vp, pb, false)
		await _wait(0.25)
	if _conn_count() > before:
		_cur["drags"] = int(_cur["drags"]) + 1
		return
	_cur["fallbacks"] = int(_cur["fallbacks"]) + 1
	_fail("%02d" % int(_cur["n"]), "drag %s.%s → %s.%s made no wire (screen %s → %s; %s)" % [
		str(a.get("type")), ah, str(b.get("type")), bh, str(pa), str(pb), diag])
	var pol := "negative" if ah.to_lower().contains("neg") else "positive"
	if ah.begins_with("ac"):
		pol = "ac"
	model.call("add_connection", {"scope_id": str(a.get("scope_id", "root")), "polarity": pol,
		"source_item_id": str(a.get("id")), "source_handle_id": ah,
		"target_item_id": str(b.get("id")), "target_handle_id": bh})
	_sgv.call("_check_electrical_faults")
	_canvas.queue_redraw()
	await _wait(0.2)


func _audit() -> Dictionary:
	var res := UiAudit.run(main.get_tree().root.get_viewport())
	var errs := int(res.get("errors", 0))
	print("bootcampaudit %02d: %s" % [int(_cur.get("n", 0)), UiAudit.summary_line(res)])
	if strict and errs > 0:
		_fail("%02d" % int(_cur.get("n", 0)), "%d ui audit error(s)" % errs)
	return {"errors": errs, "warnings": int(res.get("warnings", 0)), "counts": res.get("counts", {})}


func _hud_progress() -> String:
	var hud: Variant = _td.get("_hud")
	if hud == null:
		return ""
	var bits: PackedStringArray = PackedStringArray()
	for l in (hud as Node).find_children("*", "Label", true, false):
		var t := str((l as Label).text)
		if not t.is_empty() and (l as Label).is_visible_in_tree():
			bits.append(t)
	return " | ".join(bits)


func _fail(where: String, what: String) -> void:
	_fails += 1
	print("bootcamp FAIL %s: %s" % [where, what])


func _note(s: String) -> void:
	print("bootcampaudit: " + s)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	_energy_report(name)
	var img := _vp.get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [shots_dir, name])


func _wait(s: float) -> void:
	await main.get_tree().create_timer(s).timeout


## The four energy readouts a player sees on one frame — each panel card, the
## controller card, the battery card footer, the dashboard's "Making" — dumped
## side by side, so a frame whose numbers disagree is a line in the log.
func _energy_report(tag: String) -> Dictionary:
	var model: Object = _sgv.get("model")
	var su: Variant = _sgv.get("_solar_ui")
	if model == null or su == null or _of("panel").is_empty():
		return {}
	var panels_w := 0.0
	var per: PackedStringArray = PackedStringArray()
	for pa: Dictionary in _of("panel"):
		var w := float((pa.get("specs", {}) as Dictionary).get("current_output_kw", 0.0)) * 1000.0
		panels_w += w
		per.append("%.1f" % w)
	var offered := 0.0
	var delivered := 0.0
	for c: Dictionary in _of("controller"):
		var sp: Dictionary = c.get("specs", {}) as Dictionary
		offered += float(sp.get("dc_array_w", 0.0))
		delivered += float(sp.get("dc_delivered_w", 0.0))
	var hint: Dictionary = _canvas.get("live_power_hint") if _canvas != null else {}
	var r := {
		"panels_w": panels_w, "offered_w": offered, "delivered_w": delivered,
		"solar_w": float(su.get("current_solar_kw")) * 1000.0,
		"raw_w": float(su.get("_raw_solar_kw")) * 1000.0,
		"load_w": float(su.get("current_load_kw")) * 1000.0,
		"battery_w": float(hint.get("battery_w", 0.0)),
		"soc_pct": float(su.call("get_battery_percent")),
		"ts": float(main.get("time_scale")),
		"playback": bool(su.get("_playback_series_active")),
	}
	var walk_panels := 0
	for it in GraphNesting.walk_items(model, "root"):
		if it is Dictionary and str((it as Dictionary).get("type", "")) == "panel":
			walk_panels += 1
	r["walk_panels"] = walk_panels
	# One frame, one story — checked on the settled shots of the run levels:
	# panels sum to what the array delivers ("Making"), a controller wired to
	# the whole array delivers that same figure, and a full battery is not
	# "charging".
	var settled := tag.ends_with("_c_running") or tag.ends_with("_d_playback") \
			or tag.ends_with("_h_clean") or tag.ends_with("_g_verdict") or tag.ends_with("_f_after")
	var tol := maxf(2.0, 0.02 * float(r["solar_w"]))
	var bad: PackedStringArray = PackedStringArray()
	if absf(panels_w - float(r["solar_w"])) > tol:
		bad.append("panels %.1f W vs making %.1f W" % [panels_w, float(r["solar_w"])])
	if offered > 0.0 and _of("controller").size() == 1 and absf(delivered - float(r["solar_w"])) > tol:
		bad.append("controller %.1f W vs making %.1f W" % [delivered, float(r["solar_w"])])
	if float(r["soc_pct"]) >= 99.95 and float(r["battery_w"]) > 5.0:
		bad.append("a full battery reads +%.0f W" % float(r["battery_w"]))
	# The dashboard's own "Making" row — what the player reads, not SolarUI.
	var dash: Variant = _sgv.get("_graph_dashboard")
	var dash_making := ""
	if dash != null and is_instance_valid(dash) and (dash as Control).is_visible_in_tree():
		for row in (dash as Node).find_children("*", "KVRow", true, false):
			var labels: Array = (row as Node).find_children("*", "Label", true, false)
			if labels.size() >= 2 and str((labels[0] as Label).text) == "Making":
				dash_making = str((labels[1] as Label).text)
		if not dash_making.is_empty() and dash_making != UiText.num(float(r["solar_w"]), "W"):
			bad.append("dashboard Making %s vs %s" % [dash_making, UiText.num(float(r["solar_w"]), "W")])
	r["dash_making"] = dash_making
	if settled and not bad.is_empty():
		_fail(tag, "energy readouts disagree: " + "; ".join(bad))
	print("bootcampaudit energy %s: panels %s = %.1f W | controller %.1f of %.1f offered | making %.1f (raw %.1f) | load %.1f | battery %+.1f W @ %.1f%% | ts %.4f%s | dash %s" % [
		tag, "/".join(per), panels_w, delivered, offered, float(r["solar_w"]), float(r["raw_w"]),
		float(r["load_w"]), float(r["battery_w"]), float(r["soc_pct"]), float(r["ts"]),
		" playback" if bool(r["playback"]) else "", dash_making if not dash_making.is_empty() else "-"])
	if walk_panels != _of("panel").size():
		print("bootcampaudit energy %s: %d panel(s) in the model, %d on the root canvas" % [
			tag, walk_panels, _of("panel").size()])
	return r
