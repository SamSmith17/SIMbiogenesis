extends SceneTree

## TC Process Lab step trace (NOT a selftest): every CV's state for the
## first steps of a run, to find where a number goes wrong.
##   Godot --headless --path . --script tools/diag/tc_proc_trace.gd -- --steps=20 --every=1 [--cv=4]


func _initialize() -> void:
	var steps := 20
	var every := 1
	var only := -1
	var dt := 5.0
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--steps="):
			steps = int(s.substr(8))
		elif s.begins_with("--every="):
			every = int(s.substr(8))
		elif s.begins_with("--cv="):
			only = int(s.substr(5))
		elif s.begins_with("--dt="):
			dt = float(s.substr(5))
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	var sim := TcProcSim.create(d)
	for n in steps:
		sim.step(dt)
		if n % every != 0:
			continue
		print("--- t %.0f s" % sim.t_s)
		for i in sim.n_cv:
			if only >= 0 and i != only:
				continue
			var cs := sim.cv_state(i)
			var comp := ""
			for k in (cs["composition"] as Dictionary).keys():
				if float(cs["composition"][k]) > 0.01:
					comp += "%s %.2f " % [k, float(cs["composition"][k])]
			print("  cv%-2d %-9s Tg %7.1f Tw %7.1f p %+8.2f kPa  n %.4f  liq %.4f L hl %.1f  Tc %s  flow %.4f  %s" % [i, str(sim.net["cvs"][i]["role"]),
				float(cs["t_gas_c"]), float(cs["t_wall_c"]), float(cs["p_kpa_g"]), TcProcSim._sum(sim.gas[i]), float(cs["liquid_l"]),
				sim.h_liq[i], str(cs["t_cool_c"]), float(cs["flow_mol_s"]), comp])
		for li in (sim.net["links"] as Array).size():
			var l: Dictionary = sim.net["links"][li]
			if absf(sim.flow_link[li]) > 1e-6 or only < 0:
				print("    link %d %s %d to %d G %.3e  F %.4f mol/s" % [li, str(l["kind"]), int(l["a"]), int(l["b"]), sim.g_link[li], sim.flow_link[li]])
	quit(0)
