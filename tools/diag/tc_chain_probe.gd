extends SceneTree

## The Biochar → genset chain, headless (NOT a selftest): clashes, the
## network's units, then the batch hour by hour — holder fill, genset kW,
## dryer saturation, the electricity made — and the ledgers at the end.
##   Godot --headless --path . --script tools/diag/tc_chain_probe.gd -- --hours=12

func _initialize() -> void:
	var hours := 12.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hours="):
			hours = float(a.substr(8))
	var spec := TcPresets.builtin("biochar_genset")
	var d := TcDesign.solve(spec)
	print("parts %d  clashes %d" % [(spec["parts"] as Array).size(), (d.get("clashes", []) as Array).size()])
	for c in d.get("clashes", []):
		print("  clash ", c)
	for chk in d.get("checks", []):
		if str(chk.get("level", "")) != "info":
			print("  check %s: %s" % [chk.get("level", ""), chk.get("text", "")])
	var sim := TcProcSim.create(d, spec.get("process", {}))
	print("units: ", sim.units.size())
	for u in sim.units:
		print("  %s cv %d  %s" % [u["kind"], int(u["cv"]), u.get("part", "")])
	var acts := TcProcControl.actuators(sim, d, sim.proc)
	var sens := TcProcControl.sensors(sim, d, sim.proc)
	var t0 := Time.get_ticks_msec()
	var steps := int(hours * 3600.0 / TcProcSim.DT_DEFAULT)
	var every := int(1800.0 / TcProcSim.DT_DEFAULT)
	for k in steps:
		sim.step()
		if k % every == 0:
			var r := TcProcControl.read_all(sim, sens)
			var line := "t %5.2f h" % (sim.t_s / 3600.0)
			line += "  charge %.0f C  vessel %.2f kPa" % [float(r.get("sensor.%s_charge_max_temp" % TcProcControl.design_slug(d), 0.0)),
				(sim.p_cv[sim.vessel_cv] - TcSpecies.P_ATM) * 0.001]
			for u in sim.units:
				var i := int(u["cv"])
				line += "  | %s %.2f kPa" % [u["kind"], (sim.p_cv[i] - TcSpecies.P_ATM) * 0.001]
				match str(u["kind"]):
					"holder":
						line += " fill %.0f%% %.1f MJ/Nm3" % [sim.holder_fill(u) * 100.0, sim._lhv_of(sim.gas[i]) * 1e-6 / 0.022414]
					"dryer":
						line += " spent %.1f%%" % (sim.ads_mol[i] / maxf(float(u["cap_mol"]), 1e-12) * 100.0)
					"engine":
						line += " %s %.2f kW" % ["on" if sim.engine_on.get(str(u["part"]), false) else "off", float(sim.engine_kw.get(str(u["part"]), 0.0))]
			line += "  lhv %.1f" % float(r.get("sensor.%s_gas_lhv" % TcProcControl.design_slug(d), 0.0))
			print(line)
	print("ms %d" % (Time.get_ticks_msec() - t0))
	print("energy ledger ", sim.energy_ledger())
	print("mass ledger ", sim.mass_ledger())
	print("engine kWh %.3f" % sim.engine_kwh)
	print("switches ", TcProcControl.states(sim, acts))
	var auto_n := 0
	for e in sim.events:
		auto_n += 1
		if auto_n < 40:
			print("  event ", e)
	quit()
