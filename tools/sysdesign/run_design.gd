extends RefCounted

## Whole-system design harness: load a design onto the world, run it, report.
## Dry run (the sandbox copy of the world is thrown away afterwards):
##
##   $env:SYSDESIGN = "bombay_ten"          # tools/sysdesign/designs/<name>.json
##   $env:SYSDESIGN_DAYS = "366"            # optional, default the design's
##   tools\harness.ps1 -World <world id> -RunScript res://tools/sysdesign/run_design.gd `
##       -Label sysdesign -Timeout 3000
##
## Writes report.md, report.json and daily.csv under
## user://screenshots/<label>/ (the real screenshots folder) and prints the
## check table. SYSDESIGN_PEOPLE=0 runs without simulated people (the
## habitat bills its headcount at the preset rates) for a fast first look.

const Site := preload("res://tools/sysdesign/sysdesign_site.gd")
const Year := preload("res://tools/sysdesign/sysdesign_year.gd")
const Report := preload("res://tools/sysdesign/sysdesign_report.gd")


func run(main: Node, harness: Node) -> Dictionary:
	for i in 20:
		await main.get_tree().process_frame
	var design_name := OS.get_environment("SYSDESIGN")
	if design_name.is_empty():
		design_name = "bombay_ten"
	var design := Site.load_design(design_name)
	if design.is_empty():
		print("sysdesign: no design '%s'" % design_name)
		return {"ok": false}
	var sgv: Node = ServiceLocator.graph()
	if sgv == null:
		return {"ok": false, "why": "no graph view"}
	# The player's testing switches (ideal supply, no departures) would make
	# any design pass.
	PopTestPrefs.reset_defaults()
	NpcDisplayPrefs.force_npcs_for_session(true)
	main.set("time_scale", 0.0)
	var with_people := OS.get_environment("SYSDESIGN_PEOPLE") != "0"
	if not with_people:
		for n: Dictionary in (design.get("nodes", []) as Array):
			if str(n.get("preset", "")) == "Population":
				(n["set"] as Dictionary)["pop_driven"] = false

	var built := Site.apply(main, sgv, design)
	for e in (built.get("errors", []) as Array):
		print("sysdesign build error: ", e)
	if not bool(built.get("ok", false)):
		return {"ok": false, "why": "build errors"}
	var start_abs := float(built["start_abs"])
	var d0: Dictionary = main.get("clock").call("abs_hours_to_date", start_abs)
	design["_start_text"] = "%04d-%02d-%02d" % [int(d0.get("year", 0)), int(d0.get("month", 0)), int(d0.get("day", 0))]
	await Site.ensure_weather(main, start_abs)

	# The bridge exists after the first ambient tick.
	var bridge: Object = sgv.call("npc_population_bridge")
	for i in 120:
		if bridge != null:
			break
		await main.get_tree().process_frame
		bridge = sgv.call("npc_population_bridge")
	var n_spaces := Site.tag_spaces(main, bridge, design, built["ids"]) if bridge != null else 0
	var model: GraphModel = sgv.get("model")
	print("sysdesign: '%s' built: %d items, %d wires, %d spaces" % [str(design.get("name", design_name)),
		model.items.size(), model.connections.size(), n_spaces])

	var days := float(design.get("days", 365.0))
	if not OS.get_environment("SYSDESIGN_DAYS").is_empty():
		days = float(OS.get_environment("SYSDESIGN_DAYS"))
	var y := Year.new()
	var err := y.begin(main, sgv, {"start_abs": start_abs, "days": days,
		"step_min": float(design.get("step_min", 6.0)),
		"start_soc": float(design.get("start_soc", 0.8))})
	if not err.is_empty():
		print("sysdesign: ", err)
		return {"ok": false}
	y.mark_weather_year(int(d0.get("year", 0)))
	var t_wall := Time.get_ticks_msec()
	var last_print := 0.0
	while not y.done():
		var wy := y.weather_year_due()
		if wy != 0:
			var ok_w: bool = await Site.ensure_weather(main, y.cursor + y.step_h)
			y.mark_weather_year(wy)
			print("sysdesign: weather year %d %s" % [wy, "loaded" if ok_w else "NOT loaded (the last one is held)"])
		y.step_chunk(120)
		await main.get_tree().process_frame
		if y.progress() - last_print >= 0.1:
			last_print = y.progress()
			print("sysdesign: %3.0f %%  day %.0f  battery %.0f %%  (%.0f s; people %.0f s, resources %.0f s, all steps %.0f s)" % [
				y.progress() * 100.0, (y.cursor - y.start_abs) / 24.0, 100.0 * y.soc / y.cap_kwh,
				(Time.get_ticks_msec() - t_wall) / 1000.0, y.t_pop_us / 1e6, y.t_flow_us / 1e6, y.t_misc_us / 1e6])
	y.finish()
	y.release()

	# SYSDESIGN_DUMP=kitchen,reactor prints those nodes' state keys at the end.
	for want in OS.get_environment("SYSDESIGN_DUMP").split(",", false):
		for iid: String in (built["ids"] as Dictionary).get(want, []):
			var it: Dictionary = model.get_item(iid)
			var sp: Dictionary = it.get("specs", {})
			var keep := {}
			for k in sp.keys():
				var ks := str(k)
				if ks.begins_with("recipe_") and ks != "recipe_def" or ks.begins_with("node_state") \
						or ks.begins_with("batch") or ks in ["requested_state", "current_state", "selected_recipe_id", "inputs", "outputs", "watts", "packed_3d"]:
					keep[ks] = sp[k]
			print("sysdesign dump %s: %s item=%s" % [iid, JSON.stringify(keep), JSON.stringify({"batch_error": it.get("batch_error", ""), "baw": it.get("batch_active_watts", null)})])
		if want == "autos":
			for e in y.automations.log.slice(0, 60):
				print("sysdesign auto: day %.2f %s %s (%s)" % [(float(e["t"]) - y.start_abs) / 24.0, str(e["item_id"]), str(e["command"]), str(e["alias"])])
		if want == "board" and bridge != null:
			for hid: String in (built["ids"] as Dictionary).get("hab", []):
				var board: Object = bridge.call("chore_board_for", hid)
				if board != null:
					for ch in (board.get("chores") as Array):
						print("sysdesign chore: ", JSON.stringify(ch).substr(0, 400))

	var res := Report.assess(y, design)
	var md := Report.markdown(y, design, res)
	var label := str(harness.get("_shots_label")) if harness != null else "sysdesign"
	var dir := "user://screenshots/%s" % label
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("report.md"), md)
	_write(dir.path_join("daily.csv"), Report.csv(y))
	_write(dir.path_join("report.json"), JSON.stringify({"design": design.get("name", ""),
		"result": res, "energy": y.energy, "people": y.people, "acc": y.acc,
		"events": y.events}, "  "))
	print("sysdesign report -> ", ProjectSettings.globalize_path(dir.path_join("report.md")))
	for c: Dictionary in res["checks"]:
		print("sysdesign check: [%s] %s: %s" % ["ok" if bool(c["ok"]) else "NO", str(c["name"]), str(c["detail"])])
	print("sysdesign verdict: %s over %.0f days" % ["SUSTAINED" if bool(res["sustained"]) else "NOT SUSTAINED", float(res["days"])])
	return {"ok": true, "sustained": res["sustained"]}


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
