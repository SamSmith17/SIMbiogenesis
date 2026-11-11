extends SceneTree

## A FarmBot design's numbers, headless (NOT a selftest):
##   Godot --headless --path . --script tools/diag/farmbot_probe.gd -- --preset=<id>
## Prints the plant count per crop, a steady day's jobs, the averages and the
## money, and how long the solve took.

func _initialize() -> void:
	var preset := "genesis_xl"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			preset = a.substr(9)
	var spec: Dictionary = FarmBotPresets.spec(preset)
	var t0 := Time.get_ticks_usec()
	var d := FarmBotDesign.solve(spec)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var lay: Dictionary = d["layout"]
	print("farmbot probe %s: %.1f x %.1f m, %d plants %s, solve %.0f ms" % [preset,
		float(d["spec"]["bed"]["length_m"]), float(d["spec"]["bed"]["width_m"]), int(lay["total"]),
		JSON.stringify(lay["counts"]), ms])
	var day := FarmBotEconomics.STEADY_FROM_DAY + 3
	var p := FarmBotJobs.day_plan(d["spec"], lay, day, true)
	for j in (p["jobs"] as Array):
		print("  day %d %-14s at %5.2f h  %6.1f min  %d segs" % [day, str(j["label"]), float(j["start_s"]) / 3600.0,
			float(j["dur_s"]) / 60.0, (j["segs"] as Array).size()])
	print("  robot: %s" % JSON.stringify(d["robot"]))
	var m: Dictionary = d["money"]
	print("  hand %.1f min/day (%.0f h/yr), still %.0f h/yr, saved %.0f h/yr = $%.0f; running $%.0f/yr; kit $%.0f, capital $%.0f; payback %.1f yr; lifetime net $%.0f" % [
		float(m["hand"]["min_day"]), float(m["hand"]["h_year"]), float(m["still_h_year"]), float(m["saved_h_year"]),
		float(m["saved_usd_year"]), float(m["running_usd_year"]), float(m["kit_usd"]), float(m["capital_usd"]),
		float(m["payback_years"]), float(m["lifetime_net_usd"])])
	for c in (d["checks"] as Array):
		print("  check %s: %s" % [str(c["level"]), str(c["text"])])
	quit()
