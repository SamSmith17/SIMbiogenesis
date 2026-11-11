extends RefCounted

## The Closed Loop Ten world after closed_loop_sync, run LIVE (sandbox): the
## real game loop with the graph closed, the people drawn, the clock moving.
##   $env:SYSDESIGN = "bombay_ten"
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/closed_loop_sync_check.gd -Label closed_loop_sync_check -Timeout 1500
## Also: the twelve greenhouse domes and their keyhole beds stand as kits the
## crew is asked to build, a chore per dome and per plot is on the board, the
## plots stand at their real size. The sync builds them at once unless
## CLS_CREW_BUILD=1 (then they are kits queued for the crew; CLSC_BUILD_NOW=1
## finishes those at once). CLSC_GROW_DAYS=n shoots a dome n days on.
## Applies the sync, then runs CLSC_DAYS sim days (default 6) at CLSC_SPEED
## (main.time_scale, default 0.5 = 1800x) and prints, once a sim day, the
## stores the new loops fill and drain, which machines run, the people and
## the build. Checks at the end: everyone is still here and the urine,
## digestate and supply chains actually moved. Shots over the camp.

const Sync := preload("res://tools/fixes/closed_loop_sync.gd")

const WATCH := ["potable", "cistern", "reclaim", "grey", "black", "urine", "fert", "nutr",
	"food", "supplies", "plasticbin", "pack", "flake", "biomass", "gas", "saltpan"]
const MACHINES := ["sandfilter", "unr", "bwdig", "digfilter", "compost_bays", "unpack",
	"plastic_in", "shredder", "kitchen", "ghb_1", "gfilter_1", "biogas"]

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("clsc %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _stock(model: GraphModel, iid: String) -> float:
	var it := model.get_item(iid)
	if it.is_empty():
		return NAN
	var sp: Dictionary = it.get("specs", {})
	return float(sp.get("level", 0.0)) * float(sp.get("capacity_qty", 0.0))


func _state(model: GraphModel, iid: String) -> String:
	var sp: Dictionary = model.get_item(iid).get("specs", {})
	var s := str(sp.get("node_state", "?"))
	var r := str(sp.get("node_state_reason", ""))
	return s + ("(" + r + ")" if not r.is_empty() else "")


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))

	# 1. The update, exactly as the -Persist fix would run it.
	# CLSC_NOSYNC=1: the world as it was, for a baseline.
	var nosync := OS.get_environment("CLSC_NOSYNC") == "1"
	if not nosync:
		var res: Dictionary = await Sync.new().run(main, harness)
		_ok(bool(res.get("ok", false)), "the sync ran (%s)" % str(res))
	var sgv := ServiceLocator.graph()
	var model: GraphModel = sgv.get("model")
	for nid in ([] if nosync else ["potable", "reclaim", "urine", "unr", "bwdig", "digfilter", "compost_bays",
			"supplies", "unpack", "plasticbin", "plastic_in", "saltpan", "sandfilter"]):
		_ok(not model.get_item(nid).is_empty(), "node %s is on the graph" % nid)
	if not nosync:
		_ok(model.get_item("compost").is_empty() and model.get_item("coolant").is_empty(),
			"the old compost digester and the coolant loop are gone")
	# CLSC_GH=1 checks the greenhouses of a world already synced (no sync run).
	if not nosync or OS.get_environment("CLSC_GH") == "1":
		await _check_greenhouses(main, model, sgv, dir)

	# 2. The build and the people, as the world stands.
	var sd: Object = sgv.call("site_deploy")
	var st: Dictionary = sd.call("status") if sd != null else {}
	print("clsc: deploy status %s" % JSON.stringify(st).substr(0, 600))
	var bridge: Object = sgv.call("npc_population_bridge")
	var hab_sum: Dictionary = bridge.call("summary_for", "hab") if bridge != null else {}
	print("clsc: people at start %s" % JSON.stringify(hab_sum).substr(0, 300))

	# 3. Run it live.
	var days := int(OS.get_environment("CLSC_DAYS")) if not OS.get_environment("CLSC_DAYS").is_empty() else 6
	var speed := float(OS.get_environment("CLSC_SPEED")) if not OS.get_environment("CLSC_SPEED").is_empty() else 0.5
	var start := {}
	for w in WATCH:
		start[w] = _stock(model, w)
	var ran := {}
	var t0 := float(main.call("get_absolute_hours"))
	main.set("time_scale", speed)
	var next_day := t0 + 24.0
	var next_q := t0 + 6.0
	var shots := 0
	var guard := Time.get_ticks_msec()
	var solar: Node = main.get_node_or_null("UILayer/SolarUI")
	var ac_off_since := -1.0
	var ac_off_h := 0.0
	var min_pct := 100.0
	var max_load := 0.0
	while float(main.call("get_absolute_hours")) < t0 + 24.0 * days:
		await _wait(tree, 0.5)
		if solar != null:
			var pct := float(solar.call("get_battery_percent"))
			min_pct = minf(min_pct, pct)
			max_load = maxf(max_load, float(solar.get("current_load_kw")))
			var reason := str(solar.get("_ac_shutdown_reason"))
			var hnow := float(main.call("get_absolute_hours"))
			if not reason.is_empty() and ac_off_since < 0.0:
				ac_off_since = hnow
				print("clsc power: AC OFF at day %.2f (%s), battery %.0f %%, load %.2f kW" % [
					(hnow - t0) / 24.0, reason, pct, float(solar.get("current_load_kw"))])
			elif reason.is_empty() and ac_off_since >= 0.0:
				ac_off_h += hnow - ac_off_since
				print("clsc power: AC back at day %.2f after %.1f h, battery %.0f %%" % [
					(hnow - t0) / 24.0, hnow - ac_off_since, pct])
				ac_off_since = -1.0
		for m in MACHINES:
			if model.get_item(m).is_empty():
				continue
			if str((model.get_item(m).get("specs", {}) as Dictionary).get("node_state", "")) == GraphNodeState.RUNNING:
				ran[m] = true
		var now := float(main.call("get_absolute_hours"))
		if now >= next_q:
			next_q += 6.0
			var sq: Dictionary = bridge.call("summary_for", "hab") if bridge != null else {}
			print("clsc t+%.0fh: %d here morale %.2f doing %s" % [now - t0, int(sq.get("count", 0)),
				float(sq.get("mean_morale", 0.0)), JSON.stringify(sq.get("activities", {}))])
		if now >= next_day:
			next_day += 24.0
			var parts: Array = []
			for w2 in WATCH:
				parts.append("%s %.1f" % [w2, _stock(model, w2)])
			var ms: Array = []
			for m2 in MACHINES:
				if not model.get_item(m2).is_empty():
					ms.append("%s %s" % [m2, _state(model, m2)])
			var s2: Dictionary = bridge.call("summary_for", "hab") if bridge != null else {}
			print("clsc day %.0f: %s" % [(now - t0) / 24.0, ", ".join(parts)])
			print("clsc day %.0f machines: %s" % [(now - t0) / 24.0, ", ".join(ms)])
			print("clsc day %.0f people: %d here, morale %.2f, blocked %s, starved %s" % [(now - t0) / 24.0,
				int(s2.get("count", 0)), float(s2.get("mean_morale", 0.0)), str(s2.get("blocked", {})),
				str((model.get_item("hab").get("specs", {}) as Dictionary).get("starved_kinds", []))])
			print("clsc day %.0f doing: %s needs %s left %s all-hands %s" % [(now - t0) / 24.0,
				JSON.stringify(s2.get("activities", {})), JSON.stringify(s2.get("avg_needs", {})),
				str(s2.get("departure_cause", "")), str(bridge.call("is_all_hands", "hab"))])
			if shots < 2:
				await _shot_camp(main, vp, dir, "day%d" % int((now - t0) / 24.0))
				shots += 1
		if Time.get_ticks_msec() - guard > 1300000:
			print("clsc: out of real time, stopping early")
			break
	main.set("time_scale", 0.0)
	print("clsc power: lowest battery %.0f %%, highest load %.2f kW, AC off %.1f h in total" % [
		min_pct, max_load, ac_off_h])

	# 4. Did the new loops move?
	var end := {}
	for w3 in WATCH:
		end[w3] = _stock(model, w3)
	var hab_end: Dictionary = bridge.call("summary_for", "hab") if bridge != null else {}
	if nosync and OS.get_environment("CLSC_GH") == "1":
		_chore_report(bridge)
	if nosync:
		print("clsc: baseline (no sync) — stores start -> end: %s" % ", ".join(WATCH.filter(func(w5: String) -> bool:
			return not is_nan(float(start[w5]))).map(func(w4: String) -> String:
			return "%s %.1f->%.1f" % [w4, float(start[w4]), float(end[w4])])))
		return {"ok": _fails.is_empty(), "fails": _fails}
	_ok(int(hab_end.get("count", 0)) == 10, "all 10 people still here (%d)" % int(hab_end.get("count", 0)))
	_ok(ran.has("unr") or float(end["urine"]) > float(start["urine"]) + 1.0,
		"urine is collected and processed (urine %.1f -> %.1f L, recovery ran %s)" % [
			float(start["urine"]), float(end["urine"]), str(ran.has("unr"))])
	_ok(ran.has("bwdig"), "the brownwater digester ran")
	_ok(ran.has("digfilter") or ran.has("compost_bays") or ran.has("unr"),
		"something fed the nutrient store (filter %s, compost %s, urine %s)" % [
			str(ran.has("digfilter")), str(ran.has("compost_bays")), str(ran.has("unr"))])
	_ok(ran.has("sandfilter") or float(end["potable"]) > 0.0, "drinking water came through the sand filter")
	print("clsc: stores start -> end: %s" % ", ".join(WATCH.map(func(w4: String) -> String:
		return "%s %.1f->%.1f" % [w4, float(start[w4]), float(end[w4])])))
	print("clsc: machines that ran: %s" % str(ran.keys()))
	_chore_report(bridge)
	var sd2: Object = sgv.call("site_deploy")
	print("clsc: deploy at the end %s" % JSON.stringify(sd2.call("status")).substr(0, 300))
	await _shot_camp(main, vp, dir, "end")
	print("clsc: %s" % ("PASS" if _fails.is_empty() else "FAIL %s" % str(_fails)))
	return {"ok": _fails.is_empty(), "fails": _fails}


## Which modules got worked: every per-module chore with its last day done.
func _chore_report(bridge: Object) -> void:
	var board2: Object = bridge.call("chore_board_for", "hab") if bridge != null else null
	if board2 != null:
		var done_tend := 0
		var rows: Array = []
		for c in (board2.get("chores") as Array):
			var cd: Dictionary = c
			var lbl := str(cd.get("label", ""))
			if lbl.contains("greenhouse") or lbl.contains("plot") or lbl.contains("willow") or lbl.contains("coppice"):
				rows.append("%s: done day %d, %.2f h in" % [lbl, int(cd.get("done_day", -1)), float(cd.get("progress_h", 0.0))])
				if lbl.begins_with("Tend greenhouse") and int(cd.get("done_day", -1)) >= 0:
					done_tend += 1
		for r in rows:
			print("clsc chore: ", r)
		print("clsc: %d of 12 greenhouses tended at least once" % done_tend)
		_ok(done_tend == 12, "every greenhouse tended (%d of 12)" % done_tend)


## A shot from the settlement view over the people, if it opens.
func _shot_camp(main: Node, vp: Viewport, dir: String, name: String) -> void:
	var view: Variant = main.call("open_settlement_view", SiteCentre.xz(main), 70.0)
	await main.get_tree().create_timer(2.0, true, false, true).timeout
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])
	if view != null and is_instance_valid(view):
		(view as Object).call("close")
	await main.get_tree().create_timer(0.5, true, false, true).timeout


## The greenhouses after the sync: a dome and its beds per bed node, kits
## queued for the crew, a chore per dome, the plots at their real size.
func _check_greenhouses(main: Node, model: GraphModel, sgv: Node, dir: String) -> void:
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var recs: Array = loader.call("placed_prop_records")
	var beds := 0
	var domes := 0
	var packed := 0
	var plots_ok := 0
	var bed_pids: Array = []
	var dome_pids: Array = []
	for r in recs:
		var rec: Dictionary = r
		var gid := str(rec.get("graph_item_id", ""))
		if gid.begins_with("ghb_"):
			beds += 1
			bed_pids.append(str(rec["id"]))
			if bool(rec.get("packed", false)):
				packed += 1
			var gs: Dictionary = rec.get("grow_bed_spec", {})
			if str(gs.get("layout", "")) != "keyhole":
				_ok(false, "bed %s is a keyhole bed (%s)" % [gid, str(gs)])
		if str(rec.get("greenhouse_for", "")).begins_with("ghb_"):
			domes += 1
			dome_pids.append(str(rec["id"]))
			if bool(rec.get("packed", false)):
				packed += 1
		if gid.begins_with("plot_"):
			var gs2: Dictionary = rec.get("grow_bed_spec", {})
			if str(gs2.get("layout", "")) == "plot" and float(gs2.get("area_m2", 0.0)) >= 49.0:
				plots_ok += 1
	_ok(beds == 12, "twelve keyhole beds on the graph and in the world (%d)" % beds)
	_ok(domes == 12, "a 20 m dome over each (%d)" % domes)
	_ok(plots_ok == 13, "the thirteen plots at their real size (%d)" % plots_ok)
	var gh_nodes := 0
	for it: Dictionary in model.items:
		if str(it.get("id", "")).begins_with("gh_") or str(it.get("id", "")).begins_with("gh_flex"):
			gh_nodes += 1
	_ok(gh_nodes == 0, "the nine small greenhouse beds are gone (%d left)" % gh_nodes)
	var bridge: Object = sgv.call("npc_population_bridge")
	var board: Object = bridge.call("chore_board_for", "hab") if bridge != null else null
	var tend := 0
	var targets := {}
	if board != null:
		for c in (board.get("chores") as Array):
			var cd: Dictionary = c
			if str(cd.get("label", "")).begins_with("Tend greenhouse "):
				tend += 1
				targets[str((cd.get("target", {}) as Dictionary).get("id", ""))] = true
	_ok(tend == 12 and targets.size() == 12, "a tending chore for each dome, each at its own beds (%d chores, %d places)" % [tend, targets.size()])
	var sd: Object = sgv.call("site_deploy")
	print("clsc: %d of %d greenhouse kits packed; deploy status %s" % [packed, beds + domes,
		JSON.stringify(sd.call("status")).substr(0, 300)])
	if OS.get_environment("CLS_CREW_BUILD") != "1":
		_ok(packed == 0, "the greenhouses stand (built at once; %d still packed)" % packed)
	if OS.get_environment("CLSC_BUILD_NOW") == "1":
		for pid in dome_pids + bed_pids:
			sd.call("finish_prop_now", str(pid), SiteDeploySchedule.ACTION_DEPLOY)
		for i in 30:
			await main.get_tree().process_frame
		var planted := 0
		for it2: Dictionary in model.items:
			if str(it2.get("id", "")).begins_with("ghb_") and (it2.get("specs", {}) as Dictionary).has("planted_abs_h"):
				planted += 1
		_ok(planted == 12, "built beds are planted (%d)" % planted)
		# CLSC_GROW_DAYS=n: look at the beds n days on, at noon (a jump; the
		# people take the catch-up path, so only the look is meaningful).
		var grow := float(OS.get_environment("CLSC_GROW_DAYS")) if not OS.get_environment("CLSC_GROW_DAYS").is_empty() else 0.0
		var t_back := float(main.call("get_absolute_hours"))
		if grow > 0.0:
			main.set("time_scale", 0.0)
			main.call("set_absolute_hours", floorf((t_back + grow * 24.0) / 24.0) * 24.0 + 12.0)
			for j in 20:
				await main.get_tree().process_frame
		await _shot_greenhouse(main, dir, str(bed_pids[0]) if not bed_pids.is_empty() else "")
		if grow > 0.0:
			main.call("set_absolute_hours", t_back)


## Shots of one dome: outside, and from its path inside.
func _shot_greenhouse(main: Node, dir: String, bed_pid: String) -> void:
	if bed_pid.is_empty():
		return
	var rec := PlacedPropService.get_prop_record(main, bed_pid)
	var c := Vector3(float(rec.get("x", 0.0)), float(rec.get("ground_y", 0.0)), float(rec.get("z", 0.0)))
	var yaw := deg_to_rad(float(rec.get("yaw", 0.0)))
	var slot := Vector3(sin(yaw), 0.0, cos(yaw))
	var cam := Camera3D.new()
	cam.fov = 60.0
	main.add_child(cam)
	main.call("push_camera_claim", "clsc_shot", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var vp := main.get_viewport()
	var ui: CanvasLayer = main.get_node_or_null("UILayer")
	if ui != null:
		ui.visible = false
	for view in [["dome_outside", c + slot * 26.0 + Vector3(0, 7, 0), c + Vector3(0, 3, 0)],
			["dome_path", c + slot * 9.0 + Vector3(0, 1.65, 0), c + Vector3(0, 0.8, 0)],
			["dome_beds", c + slot.rotated(Vector3.UP, 1.2) * 6.2 + Vector3(0, 1.7, 0), c + slot.rotated(Vector3.UP, 2.2) * 6.0]]:
		cam.look_at_from_position(view[1], view[2], Vector3.UP)
		await main.get_tree().create_timer(1.5, true, false, true).timeout
		vp.get_texture().get_image().save_png("%s/%s.png" % [dir, str(view[0])])
	if ui != null:
		ui.visible = true
	main.call("pop_camera_claim", "clsc_shot")
	cam.queue_free()
