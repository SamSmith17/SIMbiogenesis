extends SceneTree

## TC Process Lab probe (NOT a selftest): runs a built-in design's process
## and prints what happens hour by hour — temperatures, pressure, fronts,
## gas out, condensate, the energy ledger and the events — plus the step
## cost. --preset=<builtin id> (default biochar_reactor), --hours=N,
## --dt=S, --every=M (minutes between lines).
##   Godot --headless --path . --script tools/diag/tc_proc_probe.gd -- --hours=10


func _initialize() -> void:
	var preset := "biochar_reactor"
	var hours := 10.0
	var dt := 5.0
	var every := 30.0
	var feed := ""
	var mass := -1.0
	var watts := -1.0
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--preset="):
			preset = s.substr(9)
		elif s.begins_with("--hours="):
			hours = float(s.substr(8))
		elif s.begins_with("--dt="):
			dt = float(s.substr(5))
		elif s.begins_with("--every="):
			every = float(s.substr(8))
		elif s.begins_with("--feed="):
			feed = s.substr(7)
		elif s.begins_with("--mass="):
			mass = float(s.substr(7))
		elif s.begins_with("--watts="):
			watts = float(s.substr(8))
	var spec := TcPresets.builtin(preset)
	var pr := TcProcSpec.resolve(spec.get("process", {}))
	if feed != "":
		pr["charge"]["feed"] = feed
	if mass > 0.0:
		pr["charge"]["mass_kg"] = mass
	if watts >= 0.0:
		pr["heaters"]["default_w"] = watts
	var d := TcDesign.solve(spec)
	var sim := TcProcSim.create(d, pr)
	print("probe %s: %d CVs, feed %s %.1f kg" % [preset, sim.n_cv, pr["charge"]["feed"], float(pr["charge"]["mass_kg"])])
	if sim.bed != null and not sim.bed.is_empty():
		print("  bed: %d domains, %.0f mm deep, %.2f kg dry + %.2f kg water" % [sim.bed.domains.size(), sim.bed.height_m * 1000.0,
			sim.bed.initial_dry_kg, sim.bed.initial_moisture_kg])
	var t0 := Time.get_ticks_usec()
	var steps := 0
	var next := 0.0
	while sim.t_s < hours * 3600.0 - 1e-6:
		sim.step(dt)
		steps += 1
		if sim.t_s >= next - 1e-6:
			next += every * 60.0
			var r := sim.readings()
			var lg := sim.energy_ledger()
			var resid := float(lg["in"]) - float(lg["stored"]) - float(lg["loss"]) - float(lg["coolant"]) - float(lg["reaction"]) - float(lg["out"])
			var comp := ""
			var gc: Dictionary = r["gas_out_composition"]
			for k in ["H2O", "CO", "CO2", "H2", "CH4", "N2", "tar", "acetic"]:
				if gc.has(k) and float(gc[k]) > 0.005:
					comp += " %s %.0f%%" % [k, float(gc[k]) * 100.0]
			var cond: Dictionary = r["condensate_total"]
			var ckg := 0.0
			for k in cond.keys():
				ckg += float(cond[k])
			var held := 0.0
			for k in (r["condensate_held"] as Dictionary).keys():
				held += float(r["condensate_held"][k])
			print("%5.2f h  bed max %4.0f mean %4.0f °C  vessel %4.0f °C %+5.2f kPa  wall %4.0f  dry %3.0f%% pyro %3.0f%%  fronts %3.0f/%3.0f mm  elem %s  gas %5.2f L/min (%5.2f dry) LHV %4.1f%s  cond %.2f kg (+%.2f held)  char %.2f  cool %s  E in %.2f kWh resid %.1f%%" % [
				sim.t_s / 3600.0, float(r.get("bed_t_max_c", 0.0)), float(r.get("bed_t_mean_c", 0.0)), float(r.get("vessel_t_c", 0.0)),
				float(r.get("vessel_p_kpa_g", 0.0)), float(r.get("vessel_wall_c", 0.0)), float(r.get("dry_frac", 0.0)) * 100.0,
				float(r.get("pyro_frac", 0.0)) * 100.0, float(r.get("dry_front_mm", 0.0)), float(r.get("pyro_front_mm", 0.0)),
				_fmt(r.get("element_t_c", [])), float(r["gas_out_l_min"]), float(r["gas_out_dry_l_min"]), float(r["gas_lhv_mj_nm3"]),
				comp, ckg, held, float(r.get("char_kg", 0.0)), _fmt(r.get("coolant_out_c", [])), float(r["energy_in_kwh"]),
				resid / maxf(float(lg["in"]), 1.0) * 100.0])
	var us := Time.get_ticks_usec() - t0
	print("steps %d, %.3f ms/step, %.2f s for %.1f h" % [steps, float(us) / float(maxi(steps, 1)) / 1000.0, float(us) / 1e6, hours])
	print("section µs/step: bed %.0f pools %.0f walls %.0f phase %.0f crack %.0f flow %.0f drain %.0f" % [
		float(TcProcSim.prof[0]) / steps, float(TcProcSim.prof[1]) / steps, float(TcProcSim.prof[2]) / steps,
		float(TcProcSim.prof[3]) / steps, float(TcProcSim.prof[4]) / steps, float(TcProcSim.prof[5]) / steps, float(TcProcSim.prof[6]) / steps])
	var lg2 := sim.energy_ledger()
	print("ledger: in %.2f MJ stored %.2f loss %.2f coolant %.2f reaction %.2f out %.2f" % [float(lg2["in"]) / 1e6, float(lg2["stored"]) / 1e6,
		float(lg2["loss"]) / 1e6, float(lg2["coolant"]) / 1e6, float(lg2["reaction"]) / 1e6, float(lg2["out"]) / 1e6])
	var r2 := sim.readings()
	print("products: gas %s" % [_kg(r2["product_total"])])
	print("  condensate %s held %s" % [_kg(r2["condensate_total"]), _kg(r2["condensate_held"])])
	for e in sim.events:
		print("  event %5.2f h  %s" % [float(e["t_s"]) / 3600.0, str(e["text"])])
	quit(0)


func _fmt(a: Variant) -> String:
	var s := ""
	for v in a:
		s += "%.0f " % float(v)
	return s.strip_edges()


func _kg(d: Dictionary) -> String:
	var s := ""
	for k in d.keys():
		if float(d[k]) > 0.001:
			s += "%s %.3f  " % [k, float(d[k])]
	return s
