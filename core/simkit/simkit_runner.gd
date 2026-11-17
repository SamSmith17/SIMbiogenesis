extends Node

## The headless simulation kernel's driver (core/simkit/sim_kernel.tscn).
##
## The kernel scene is the game's own Main + SolarUI + SystemGraphView and
## nothing else: no terrain, player, HUD, vegetation or props. So a run uses
## exactly the code a player's world uses (SolarUI's evaluator, the flow
## engine, the people, the automations; see simkit_year.gd) and skips
## everything that only draws. Started by the MCP server (tools/simkit_mcp/)
## or by hand:
##
##   Godot --headless --path . res://core/simkit/sim_kernel.tscn -- --simkit-job=<job.json>
##
## A job is JSON: {mode: "run" | "validate" | "catalog", run_id, design (a
## design dict, see core/simkit/designs/*.json), site: {lat, lon}, days,
## step_min, people: "agents" | "rates", allow_download, out_dir}. Everything
## the kernel writes goes under `out_dir`: status.json (progress, rewritten
## every couple of seconds), summary.json (the compact report an AI reads),
## report.json / report.md / daily.csv / monthly.csv (full), graph.json (the
## built graph, which the game can take as an experiment fork), and log lines
## on stdout.
##
## The launcher runs this with APPDATA (user://) pointed at a throwaway folder
## that holds only weather archives: no worlds, no Home Assistant profile, no
## tokens. The kernel never opens a network connection except Open-Meteo's
## archive, and only when the job says `allow_download`.

const Site := preload("res://core/simkit/simkit_site.gd")
const Year := preload("res://core/simkit/simkit_year.gd")
const Report := preload("res://core/simkit/simkit_report.gd")
const Compact := preload("res://core/simkit/simkit_compact.gd")
const Catalog := preload("res://core/simkit/simkit_catalog.gd")
const Guard := preload("res://core/simkit/simkit_guard.gd")

## Wall time a frame may spend stepping before it yields (headless frames are
## free; yielding lets status writes and weather loads happen).
const FRAME_BUDGET_MS := 250
const STATUS_EVERY_MS := 2000

var _job: Dictionary = {}
var _out := ""
var _t0 := 0
var _last_status := 0


func _ready() -> void:
	var job_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--simkit-job="):
			job_path = a.substr("--simkit-job=".length())
	if job_path.is_empty():
		print("simkit: no --simkit-job=<file>; nothing to do")
		get_tree().quit(2)
		return
	_t0 = Time.get_ticks_msec()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(job_path)) \
		if FileAccess.file_exists(job_path) else null
	if not (parsed is Dictionary):
		print("simkit: the job file is missing or not JSON")
		get_tree().quit(2)
		return
	_job = parsed
	# Offline unless the job lets the weather archive download (SimkitMode
	# gates every other request in the game regardless).
	SimkitMode.allow_weather = bool(_job.get("allow_download", false))
	_out = str(_job.get("out_dir", ""))
	if _out.is_empty():
		print("simkit: the job has no out_dir")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	# Let Main, SolarUI and the graph view finish their own _ready work.
	for i in 10:
		await get_tree().process_frame
	var code := 0
	match str(_job.get("mode", "run")):
		"catalog":
			code = _do_catalog()
		"validate":
			code = await _do_run(true)
		_:
			code = await _do_run(false)
	get_tree().quit(code)


func _do_catalog() -> int:
	var cat := Catalog.build()
	_write(_out.path_join("catalog.json"), JSON.stringify(cat))
	_status("done", 1.0, {"presets": (cat.get("rows", []) as Array).size()})
	print("simkit: catalog of %d presets written" % (cat.get("rows", []) as Array).size())
	return 0


func _fail(why: String, extra: Dictionary = {}) -> int:
	var d := {"why": why}
	d.merge(extra)
	_status("failed", 0.0, d)
	print("simkit: FAILED: ", why)
	return 1


func _do_run(validate_only: bool) -> int:
	var main := get_parent()
	var sgv: Node = main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		return _fail("the kernel scene has no graph view")
	var design: Variant = _job.get("design", {})
	if not (design is Dictionary):
		return _fail("design is not an object")
	var problems := Guard.check_design(design as Dictionary)
	if not problems.is_empty():
		return _fail("design rejected", {"problems": problems})
	design = Guard.clean_design(design as Dictionary)
	var site: Dictionary = _job.get("site", {})
	var lat := float(site.get("lat", NAN))
	var lon := float(site.get("lon", NAN))
	if is_nan(lat) or is_nan(lon) or absf(lat) > 90.0 or absf(lon) > 180.0:
		return _fail("the site has no valid lat / lon")
	main.call("apply_location", lat, lon, "", false)

	if _job.has("start"):
		(design as Dictionary)["start"] = _job["start"]
	var days := clampf(float(_job.get("days", (design as Dictionary).get("days", 366.0))), 1.0, Guard.MAX_DAYS)
	var step_min := clampf(float(_job.get("step_min", (design as Dictionary).get("step_min", 6.0))), 1.0, 60.0)
	var people_mode := str(_job.get("people", "agents"))
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.force_npcs_for_session(true)
	# Extreme weather as the site's world has it (the launcher copies the
	# player's hazard settings and the site's cached alert / air data).
	var hazards := bool(_job.get("hazards", false))
	var rules: Node = get_tree().root.get_node_or_null("GameplayRules")
	if rules != null:
		rules.set("extreme_weather_enabled", hazards)
	var ew: Node = get_tree().root.get_node_or_null("ExtremeWeather")
	if ew != null and ew.has_method("invalidate"):
		ew.call("invalidate")
	main.set("time_scale", 0.0)
	if people_mode == "rates":
		# Nobody is simulated to do a recipe's crew steps, so labour is free
		# (finite labour with no people would leave every hands-on machine
		# idle). The report says so under fidelity.
		(design as Dictionary)["infinite_labor"] = true
		for n: Dictionary in ((design as Dictionary).get("nodes", []) as Array):
			if str(n.get("preset", "")).begins_with("Population"):
				var st: Dictionary = n.get("set", {})
				st["pop_driven"] = false
				n["set"] = st

	_status("building", 0.0)
	var built := Site.apply(main, sgv, design)
	if not bool(built.get("ok", false)):
		return _fail("build errors", {"errors": built.get("errors", [])})
	var model: GraphModel = sgv.get("model")
	# Let the view's deferred work after a whole-graph change run now (it
	# remakes the load proxies; a proxy made after a rule fired starts OFF),
	# as the frames between a build and a run do in a played world.
	for i in 3:
		await get_tree().process_frame
	var load_host: Node = sgv.get_node_or_null("GraphSimLoadHost")
	if load_host != null and load_host.has_method("refresh"):
		load_host.call("refresh")
	var start_abs := float(built["start_abs"])
	var d0: Dictionary = main.get("clock").call("abs_hours_to_date", start_abs)
	(design as Dictionary)["_start_text"] = "%04d-%02d-%02d" % [int(d0.get("year", 0)),
		int(d0.get("month", 0)), int(d0.get("day", 0))]
	if validate_only:
		_write(_out.path_join("graph.json"), JSON.stringify(model.serialize()))
		_status("done", 1.0, {"valid": true, "items": model.items.size(),
			"wires": model.connections.size(), "notes": built.get("notes", [])})
		print("simkit: design is valid (%d items, %d wires)" % [model.items.size(), model.connections.size()])
		return 0

	if not await _ensure_weather(main, start_abs):
		return _fail("no weather archive for this site and year", {"hint":
			"open the site in the game once, or let the run download it (allow_download)"})

	var bridge: Object = sgv.call("npc_population_bridge")
	var n_spaces := Site.tag_spaces(main, bridge, design, built["ids"]) if bridge != null else 0
	print("simkit: '%s' built: %d items, %d wires, %d spaces" % [str((design as Dictionary).get("name", "")),
		model.items.size(), model.connections.size(), n_spaces])
	_write(_out.path_join("graph.json"), JSON.stringify(model.serialize()))

	var y := Year.new()
	var err := y.begin(main, sgv, {"logic": ScadaLogicRun.remap(design.get("logic", []) as Array, built["ids"] as Dictionary),
		"alarms": ScadaLogicRun.remap(design.get("alarms", []) as Array, built["ids"] as Dictionary),
		"start_abs": start_abs, "days": days, "step_min": step_min,
		"start_soc": float((design as Dictionary).get("start_soc", 0.8))})
	if not err.is_empty():
		return _fail(err)
	y.mark_weather_year(int(d0.get("year", 0)))
	var deadline_ms := int(clampf(float(_job.get("max_wall_s", 7200.0)), 60.0, 86400.0) * 1000.0)
	while not y.done():
		var wy := y.weather_year_due()
		if wy != 0:
			await _ensure_weather(main, y.cursor + y.step_h)
			y.mark_weather_year(wy)
		var f0 := Time.get_ticks_msec()
		while not y.done() and Time.get_ticks_msec() - f0 < FRAME_BUDGET_MS and y.weather_year_due() == 0:
			y.step_chunk(60)
		if Time.get_ticks_msec() - _last_status >= STATUS_EVERY_MS:
			_progress(y)
		if Time.get_ticks_msec() - _t0 > deadline_ms:
			y.release()
			return _fail("ran past the wall-time limit", {"day": (y.cursor - y.start_abs) / 24.0})
		if _cancelled():
			y.release()
			return _fail("cancelled")
		await get_tree().process_frame
	y.finish()
	y.release()
	if not OS.get_environment("SIMKIT_DEBUG").is_empty():
		print("simkit debug: rules %d, switches logged %d, steps %d, pop %.1f s flow %.1f s all %.1f s" % [
			y.automations.rules.size() if y.automations != null else -1, y.auto_log_n, y.steps,
			y.t_pop_us / 1e6, y.t_flow_us / 1e6, y.t_misc_us / 1e6])
		if y.automations != null:
			for e in y.automations.log.slice(0, 12):
				print("simkit debug auto: ", JSON.stringify(e))

	var res := Report.assess(y, design)
	var meta := {"run_id": str(_job.get("run_id", "")), "people_mode": people_mode, "hazards": hazards,
		"labour": "free" if bool((design as Dictionary).get("infinite_labor", false)) else "crew",
		"step_min": step_min, "wall_s": (Time.get_ticks_msec() - _t0) / 1000.0,
		"site_id": str(site.get("id", "")), "pv_kwp": float(y.solar.get("PEAK_CAPACITY_KW")) \
			if y.solar != null else 0.0}
	var summary := Compact.summary(y, design, res, built.get("ids", {}), meta)
	_write(_out.path_join("summary.json"), JSON.stringify(summary))
	_write(_out.path_join("report.md"), Report.markdown(y, design, res))
	_write(_out.path_join("daily.csv"), Report.csv(y))
	_write(_out.path_join("monthly.csv"), Compact.monthly_csv(y))
	_write(_out.path_join("daily_ids.csv"), Compact.daily_csv(y, built.get("ids", {})))
	var did: Dictionary = built.get("ids", {})
	var flow_labels := {}
	for gid in did:
		var it := model.get_item(str(gid))
		if not it.is_empty():
			flow_labels[str(did[gid])] = str((it.get("specs", {}) as Dictionary).get("name", did[gid]))
	var svg := Compact.flows_svg(y, did, days, flow_labels,
		"Where it flowed: %s" % str((design as Dictionary).get("name", "")))
	if svg != "":
		_write(_out.path_join("flows.svg"), svg)
	_write(_out.path_join("report.json"), JSON.stringify({"design": (design as Dictionary).get("name", ""),
		"result": res, "energy": y.energy, "people": y.people, "acc": y.acc, "events": y.events}))
	_status("done", 1.0, {"verdict": summary.get("verdict", ""), "wall_s": meta["wall_s"]})
	print("simkit: %s over %.0f days in %.0f s" % [str(summary.get("verdict", "")), days, float(meta["wall_s"])])
	return 0


## The site's archive for the year of `abs_h`. Download only when the job
## allows it; otherwise the launcher must have copied it in.
func _ensure_weather(main: Node, abs_h: float) -> bool:
	var ws: Node = get_tree().root.get_node_or_null("WeatherService")
	if ws == null:
		return false
	var d: Dictionary = main.get("clock").call("abs_hours_to_date", abs_h)
	var want := int(ws.call("effective_year", int(d.get("year", 2024))))
	var lat := float(main.get("latitude"))
	var lon := float(main.get("longitude"))
	if int(ws.get("_data_year")) == want and bool(ws.call("covers", lat, lon)):
		return true
	if not bool(_job.get("allow_download", false)):
		# request_weather reads the cache before it fetches; give it a few
		# frames, then give up rather than reach the network.
		var path := "user://weather_cache/om_%s_%.2f_%.2f_%d.json" % [
			str((ws.get_script() as Script).get_script_constant_map().get("CACHE_VERSION", "v5")), lat, lon, want]
		if not FileAccess.file_exists(path):
			return false
	_status("weather", 0.0, {"year": want})
	return await Site.ensure_weather(main, abs_h)


func _progress(y: Object) -> void:
	var p: float = y.progress()
	var wall := (Time.get_ticks_msec() - _t0) / 1000.0
	_status("running", p, {"day": snappedf((y.cursor - y.start_abs) / 24.0, 0.1),
		"battery_pct": snappedf(100.0 * y.soc / y.cap_kwh, 0.1),
		"wall_s": snappedf(wall, 0.1),
		"eta_s": snappedf(wall * (1.0 - p) / maxf(p, 1e-3), 1.0) if p > 0.01 else -1.0})


func _status(state: String, progress: float, extra: Dictionary = {}) -> void:
	_last_status = Time.get_ticks_msec()
	var d := {"state": state, "progress": snappedf(progress, 0.001),
		"run_id": str(_job.get("run_id", ""))}
	d.merge(extra, true)
	_write(_out.path_join("status.json"), JSON.stringify(d))


## The launcher cancels by creating `cancel` in the out dir.
func _cancelled() -> bool:
	return FileAccess.file_exists(_out.path_join("cancel"))


func _write(path: String, text: String) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	DirAccess.rename_absolute(tmp, path)
