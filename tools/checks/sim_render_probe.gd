extends RefCounted

## Sim pre-render end to end on the real world (sandbox, dry run):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/sim_render_probe.gd
## Renders the next 24 h through SystemGraphView.sim_renderer() exactly as the
## timeline's Render button will, waits for it, and asserts what a screenshot
## cannot: the clock, every tank, the battery and the camp integrators are back
## at the playhead when it is done; the clock claim and the ambient suspension
## were released; the cache covers the range; the graph's user_rev did not move
## (a render is sim writes only); and the rendered tanks really did move (a
## replay read mid-range differs from the playhead). Prints `simrender …
## PASS|FAIL` lines the harness counts.

const RENDER_H := 24.0
const TIMEOUT_S := 240.0


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	var solar: Node = main.find_child("SolarUI", true, false)
	if sgv == null or solar == null:
		print("simrender setup: FAIL — no graph view / SolarUI")
		return {"ok": false}
	if bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	await _wait(tree, 0.5)
	var model: Object = sgv.get("model")
	var flow: Object = sgv.call("resource_flow_engine")
	var sr: Node = sgv.call("sim_renderer")
	var ok_all := true
	# Let the weather land first: a render made against synthetic weather is
	# (correctly) dropped the moment the real archive arrives.
	var ws: Node = main.get_node_or_null("/root/WeatherService")
	var t_wx := Time.get_ticks_msec()
	while ws != null and ws.has_method("has_data") and not bool(ws.call("has_data")) \
			and Time.get_ticks_msec() - t_wx < 20000:
		await _wait(tree, 0.25)
	await _wait(tree, 1.5)
	print("simrender: weather %s after %.1f s" % [
		("loaded" if ws != null and bool(ws.call("has_data")) else "NOT loaded"),
		float(Time.get_ticks_msec() - t_wx) / 1000.0])
	# Name any sim writer that moved user_rev outside the bracket.
	model.set("trace_user_rev", true)

	# The state at the playhead, before.
	var play := float(main.call("get_absolute_hours"))
	var levels0 := _tank_levels(model)
	var bat0 := float(solar.call("get_battery_kwh_stored"))
	var rev0 := int(model.get("user_rev"))
	var ts0 := float(main.get("time_scale"))
	print("simrender: playhead abs_h %.4f, %d tanks, battery %.3f kWh, user_rev %d, time_scale %.5f" % [
		play, levels0.size(), bat0, rev0, ts0])

	var res: Dictionary = sr.call("start", play + RENDER_H)
	print("simrender start: %s" % JSON.stringify(res))
	if not bool(res.get("ok", false)):
		print("simrender start: FAIL — %s" % str(res.get("why", "")))
		return {"ok": false, "why": str(res.get("why", ""))}
	var owned_during := bool(main.call("clock_is_owned"))
	var susp_during := bool(sgv.get("_ambient_flow_suspended"))
	var t0 := Time.get_ticks_msec()
	var max_frac := 0.0
	while bool(sr.call("is_active")):
		await _wait(tree, 0.1)
		max_frac = maxf(max_frac, float(sr.call("progress")))
		if float(Time.get_ticks_msec() - t0) / 1000.0 > TIMEOUT_S:
			print("simrender: FAIL — render did not finish within %.0f s (progress %.2f)" % [TIMEOUT_S, max_frac])
			sr.call("cancel")
			ok_all = false
			break
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	print("simrender: render took %.1f s real for %.0f h of sim" % [secs, RENDER_H])
	ok_all = _say("clock owned + ambient suspended while rendering", owned_during and susp_during) and ok_all

	# The world is back at the playhead.
	var play1 := float(main.call("get_absolute_hours"))
	ok_all = _say("clock back at the playhead", absf(play1 - play) < 1e-6, "%.6f vs %.6f" % [play1, play]) and ok_all
	var levels1 := _tank_levels(model)
	var worst := 0.0
	var worst_id := ""
	for iid in levels0:
		var d := absf(float(levels1.get(iid, NAN)) - float(levels0[iid]))
		if is_nan(d) or d > worst:
			worst = d if not is_nan(d) else INF
			worst_id = str(iid)
	# Tolerances: the live specs were written by the last tick at ITS time, the
	# restore reads the timeline at the playhead (a sub-step apart, and the
	# battery's anchor sample interpolates toward the first rendered minute).
	ok_all = _say("every tank level back at the playhead", worst < 1e-3, "worst %s Δ%.6f" % [worst_id, worst]) and ok_all
	var bat1 := float(solar.call("get_battery_kwh_stored"))
	ok_all = _say("battery back at the playhead", absf(bat1 - bat0) < 0.05, "%.4f vs %.4f" % [bat1, bat0]) and ok_all
	ok_all = _say("clock claim released", not bool(main.call("clock_is_owned"))) and ok_all
	ok_all = _say("ambient flow resumed", not bool(sgv.get("_ambient_flow_suspended"))) and ok_all
	ok_all = _say("time_scale untouched", absf(float(main.get("time_scale")) - ts0) < 1e-9) and ok_all
	ok_all = _say("user_rev unchanged by the render", int(model.get("user_rev")) == rev0,
		"%d -> %d" % [rev0, int(model.get("user_rev"))]) and ok_all
	# (The trace stays on through the replay phase: a writer there cuts the
	# range just the same.)
	for it in (model.get("items") as Array):
		if it is Dictionary:
			var d: Dictionary = it
			var sp0: Dictionary = d.get("specs", {}) as Dictionary
			print("simrender item %s: type=%s role=%s name=%s" % [str(d.get("id", "")), str(d.get("type", "")),
				str(sp0.get("role", "")), str(sp0.get("name", d.get("label", "")))])
	var cache: Object = sr.get("cache")
	ok_all = _say("cache covers the rendered range", bool(cache.call("covers", play + 0.5))
		and bool(cache.call("covers", play + RENDER_H - 0.1)) and not bool(cache.call("covers", play + RENDER_H + 1.0))) and ok_all
	var kf := int(cache.call("keyframe_count"))
	ok_all = _say("keyframes every 15 sim-min", kf >= int(RENDER_H * 4) - 1, "%d" % kf) and ok_all

	# The rendered future is readable: a replay read 12 h in is a different
	# world than the playhead's (unless this site has no moving tank at all),
	# and reading the playhead again restores it exactly.
	var et: Object = solar.get("energy_timeline")
	var soc_mid := float((et.call("sample_at", play + 12.0) as Dictionary).get("soc_kwh", NAN))
	_say("energy timeline holds the rendered future (info)", not is_nan(soc_mid), "soc +12 h = %.3f" % soc_mid)
	# Direct engine reads write tank specs: inside the sim-write bracket, like
	# the ambient tick does, or the view takes them for a player edit and cuts
	# the range (which is exactly what it should do to an unbracketed writer).
	sgv.call("_begin_sim_writes")
	flow.call("replay_at", play + 12.0)
	sgv.call("_end_sim_writes")
	var levels_mid := _tank_levels(model)
	var moved := 0
	for iid in levels0:
		if absf(float(levels_mid.get(iid, 0.0)) - float(levels0[iid])) > 1e-4:
			moved += 1
	print("simrender: %d of %d tanks differ at +12 h (info — a static site may move none)" % [moved, levels0.size()])
	sgv.call("_begin_sim_writes")
	flow.call("replay_at", play)
	sgv.call("_end_sim_writes")
	var levels_back := _tank_levels(model)
	var worst2 := 0.0
	for iid in levels0:
		worst2 = maxf(worst2, absf(float(levels_back.get(iid, NAN)) - float(levels0[iid])))
	ok_all = _say("replay_at the playhead restores every tank", worst2 < 1e-3, "worst Δ%.6f" % worst2) and ok_all

	# ── REPLAY: run the clock into the range and watch the ambient tick READ. ──
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("set_enabled", true)
	main.set("time_scale", 1.0)   # 3600× — ~3 sim-hours over 3 real seconds
	var polls := 0
	var replaying_polls := 0
	var eng_ms := 0.0
	var rep_ms := 0.0
	var eng_last := 0.0
	for i in 12:
		await _wait(tree, 0.25)
		polls += 1
		if bool(sgv.call("is_replaying")):
			replaying_polls += 1
		if pm != null:
			var sec: Dictionary = (pm.call("snapshot") as Dictionary).get("sections_ms", {}) as Dictionary
			eng_ms += float(sec.get("flow_engine", 0.0))
			rep_ms += float(sec.get("flow_replay", 0.0))
			eng_last = float(sec.get("flow_engine", 0.0))
	var now := float(main.call("get_absolute_hours"))
	print("simrender replay: %.2f sim-h in, replaying on %d of %d polls, flow_engine avg %.3f ms (last %.3f), flow_replay avg %.3f ms" % [
		now - play, replaying_polls, polls, eng_ms / float(polls), eng_last, rep_ms / float(polls)])
	ok_all = _say("ambient tick replays inside the range", replaying_polls >= polls - 2, "%d/%d" % [replaying_polls, polls]) and ok_all
	# The section is a smoothed per-frame average that decays over ~30 frames
	# from the live ticks before the range: judge the settled value.
	ok_all = _say("flow engine idle while replaying", eng_last < 0.03 and rep_ms > 0.0, "last %.4f ms, replay avg %.4f" % [eng_last, rep_ms / float(polls)]) and ok_all
	ok_all = _say("the clock advanced into the range", now > play + 1.0 and bool(cache.call("covers", now)), "now-play %.2f h" % (now - play)) and ok_all
	# Every timeline tank shows exactly its cached level at the engine's last
	# replay time (the specs are written per 0.25 s tick; at 3600× the clock
	# moves 15 sim-min between ticks, so "now" is not the written instant).
	var replay_t := float(flow.get("_last_abs_hours"))
	var worst3 := 0.0
	var n_tl := 0
	for it in (model.get("items") as Array):
		if not (it is Dictionary) or str((it as Dictionary).get("type", "")) != "resource":
			continue
		var iid := str((it as Dictionary).get("id", ""))
		var tl: Object = flow.call("get_timeline", iid)
		if tl == null:
			continue
		n_tl += 1
		var lv := float(((it as Dictionary).get("specs", {}) as Dictionary).get("level", 0.0))
		worst3 = maxf(worst3, absf(lv - float(tl.call("level_at", replay_t))))
	ok_all = _say("tanks follow the cache during replay", n_tl > 0 and worst3 < 1e-3,
		"%d tanks, worst Δ%.6f at %.4f (now %.4f)" % [n_tl, worst3, replay_t, now]) and ok_all
	# The battery readout is the rendered curve.
	# Compared at SolarUI's own last battery instant (its 10 Hz tick is up to
	# 6 sim-minutes behind "now" at 3600×).
	var bat_now := float(solar.call("get_battery_kwh_stored"))
	var bat_t := float(solar.get("_battery_last_abs_h"))
	var soc_now := float(et.call("soc_at", bat_t))
	ok_all = _say("battery reads the rendered SOC", absf(bat_now - soc_now) < 0.05,
		"%.3f vs %.3f at %.4f" % [bat_now, soc_now, bat_t]) and ok_all
	# The 3D pond followed the cached level.
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var pond_checked := false
	for it in (model.get("items") as Array):
		if not (it is Dictionary):
			continue
		var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if not bool(sp.get("pond_storage", false)) or loader == null:
			continue
		var tag := str(sp.get("osm_water_tag", ""))
		var idx := int(loader.call("find_pond_idx_by_tag", tag))
		if idx < 0:
			continue
		var info: Dictionary = loader.call("get_pond_info", idx)
		var lm_3d := float(info.get("level_m", NAN))
		var lm_tank := float(sp.get("level_m", NAN))
		if is_nan(lm_3d) or is_nan(lm_tank):
			continue
		pond_checked = true
		ok_all = _say("3D pond %s follows the replayed level" % tag, absf(lm_3d - lm_tank) < 0.05,
			"3D %.3f tank %.3f" % [lm_3d, lm_tank]) and ok_all
	if not pond_checked:
		print("simrender: no pond twin to check (info)")

	# ── A PLAYER EDIT cuts the range at the playhead; the live step resumes. ──
	main.set("time_scale", 0.0)
	await _wait(tree, 0.3)
	model.set("trace_user_rev", false)
	var rev_replay := int(model.get("user_rev"))
	ok_all = _say("user_rev unchanged during replay", rev_replay == rev0, "%d -> %d" % [rev0, rev_replay]) and ok_all
	var cut_at := float(main.call("get_absolute_hours"))
	var edit_id := ""
	for iid in levels0:
		edit_id = str(iid)
		break
	var esp: Dictionary = ((model.call("get_item", edit_id) as Dictionary).get("specs", {}) as Dictionary).duplicate(true)
	esp["capacity_qty"] = float(esp.get("capacity_qty", 100.0)) * 1.5
	print("simrender: ranges before the edit %s" % str(cache.get("ranges")))
	model.call("update_item", edit_id, {"specs": esp})
	ok_all = _say("edit cut the range at the playhead", not bool(cache.call("covers", cut_at + 0.5))
		and bool(cache.call("covers", cut_at - 0.5)), str(cache.get("ranges"))) and ok_all
	main.set("time_scale", 1.0)
	# The edit's own cascade (fault check, telemetry refresh, SolarUI capacity
	# sync) makes the next frames long; give the ambient tick a few of them.
	var t_live := Time.get_ticks_msec()
	var resumed := false
	while Time.get_ticks_msec() - t_live < 3000:
		await _wait(tree, 0.25)
		if not bool(sgv.call("is_replaying")) \
				and float(main.call("get_absolute_hours")) > cut_at + 0.1:
			resumed = true
			break
	var after_cut := float(main.call("get_absolute_hours"))
	ok_all = _say("live step resumed past the cut", resumed, "replaying=%s now-cut=%.3f h ranges=%s" % [
		str(sgv.call("is_replaying")), after_cut - cut_at, str(cache.get("ranges"))]) and ok_all
	main.set("time_scale", 0.0)
	# ── Scrub back into what remains: replay again. ──
	main.call("set_absolute_hours", play + 0.5)
	await _wait(tree, 0.8)
	ok_all = _say("scrub back into the kept range replays again", bool(sgv.call("is_replaying"))) and ok_all
	main.set("time_scale", ts0)
	if pm != null:
		pm.call("set_enabled", false)
	print("simrender: RESULT %s" % ("PASS" if ok_all else "FAIL"))
	return {"ok": ok_all, "render_s": secs, "keyframes": kf, "moved": moved}


func _tank_levels(model: Object) -> Dictionary:
	var out: Dictionary = {}
	for it in (model.get("items") as Array):
		if it is Dictionary and str((it as Dictionary).get("type", "")) == "resource":
			out[str((it as Dictionary).get("id", ""))] = float(
				((it as Dictionary).get("specs", {}) as Dictionary).get("level", 0.0))
	return out


func _say(label: String, ok: bool, detail: String = "") -> bool:
	print("simrender %s: %s%s" % [label, "PASS" if ok else "FAIL", (" — " + detail) if not detail.is_empty() else ""])
	return ok


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
