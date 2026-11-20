extends SceneTree

## Battery Lab numbers, headless (not a selftest): every built-in (or
## --preset=<id>) solved, with its arrangement, size, electrical figures,
## limits and checks.
##   godot --headless --path . --script tools/diag/batterylab_probe.gd [-- --preset=<id>]


func _initialize() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--preset="):
			only = str(a).substr(9)
	for b in BattPresets.builtins():
		var id := str((b as Dictionary)["id"])
		if not only.is_empty() and id != only:
			continue
		var t0 := Time.get_ticks_usec()
		var d := BattDesign.solve((b as Dictionary)["spec"])
		var ms := float(Time.get_ticks_usec() - t0) * 0.001
		var e: Dictionary = d["electrical"]
		var L: Dictionary = d["layout"]
		var sz: Vector3 = (L["bounds"] as AABB).size
		print("== %s  (%.1f ms)" % [id, ms])
		print("   %s %s %dS%dP  arrange %s  ic %s  bms %s" % [d["chem"], (d["cell"] as Dictionary)["id"],
			int((d["spec"] as Dictionary)["series"]), int((d["spec"] as Dictionary)["parallel"]),
			d["arrange"], d["interconnect"], d["bms_id"]])
		print("   %.0f x %.0f x %.0f mm  %.1f kg  $%.0f ($%.0f/kWh)  rack U %s" % [sz.x, sz.y, sz.z,
			float(d["mass_kg"]), float(d["cost_usd"]), float(d["usd_per_kwh"]),
			(L["enclosure"] as Dictionary).get("rack_u", "-")])
		print("   %.1f V (%.1f–%.1f)  %.0f Ah  %.2f kWh (%.2f usable)  %.0f A dis / %.0f A chg (by %s)  R %.2f mΩ  sag %.2f V" % [
			float(e["v_nom"]), float(e["v_min"]), float(e["v_max"]), float(e["ah"]), float(e["wh"]) * 0.001,
			float(e["usable_wh"]) * 0.001, float(e["cont_discharge_a"]), float(e["cont_charge_a"]),
			e["limit_by"], float(e["r_ohm"]) * 1000.0, float(e["sag_v"])])
		print("   links %d  taps %d  harness %.0f mm  leads %s  bus %s" % [(L["links"] as Array).size(),
			(L["taps"] as Array).size(),
			(L["harness"] as Array).reduce(func(acc, h): return acc + float(h["len_mm"]), 0.0),
			(L["leads"] as Array).map(func(l): return "%s %.0f mm %s" % [l["id"], float(l["len_mm"]), l["wire"]]),
			d["bus"]])
		for c in (d["checks"] as Array):
			print("   [%s] %s" % [c["level"], c["text"]])
	quit(0)
