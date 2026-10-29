extends SceneTree

## A designed wind turbine's numbers, headless: the Cp model, the power
## curve, start-up, the year's energy, the parts and the checks.
## --preset=<id> (WindLabPresets.builtins), --rank to rank the generators.

func _initialize() -> void:
	var id := "lawn_sign"
	var rank := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			id = a.substr(9)
		elif a == "--rank":
			rank = true
	var ids: Array = [id]
	if id == "all":
		ids = []
		for b in WindLabPresets.builtins():
			ids.append(str(b["id"]))
	for pid in ids:
		var t0 := Time.get_ticks_msec()
		var d := WindLabDesign.solve(WindLabPresets.by_id(str(pid)))
		var ms := Time.get_ticks_msec() - t0
		var cp: Dictionary = d["cp"]
		print("=== %s (%d ms) — %s" % [pid, ms, WindLabSpec.describe(d["spec"])])
		print("  area %.3f m²  rho %.3f  R %.3f m  hub %.2f m, mean at hub %.2f m/s" % [float(d["area_m2"]), float(d["rho"]), float(d["R_m"]), float(d["hub_h_m"]), float(d["v_mean_hub"])])
		print("  Cp max %.3f at λ %.2f (run %.2f), cq0 %.3f, cq_start %.3f" % [float(cp["cp_max"]), float(cp["lam_opt"]), float(cp["lam_run"]), float(cp["cq0"]), float(cp["cq_start"])])
		for f in cp["factors"]:
			print("    × %.3f  %s" % [float(f["value"]), str(f["label"])])
		print("  ratio %.2f eff %.2f; start %.2f m/s (needs %.4f N·m); cut-in %s; peak %.1f W at %.1f; cut-out %.1f; AEP %.2f kWh (mean %.2f W)" % [float(d["ratio"]), float(d["drive_eff"]), float(d["start_ms"]), WindLabDesign.start_torque_nm(d), str(d["cut_in_ms"]), float(d["peak_w"]), float(d["peak_v"]), float(d["cut_out_ms"]), float(d["aep_kwh"]), float(d["mean_w"])])
		for p in d["curve"]:
			var v := float(p["v"])
			if fmod(v, 2.0) < 0.01 or v == 5.0 or v == 7.0:
				print("    v %4.1f  rotor %6.0f rpm λ %.2f Cp %.3f  gen %6.0f rpm  %6.2f V %6.2f A  P_aero %7.2f  P_elec %7.2f W%s" % [v, float(p["rpm"]), float(p["lam"]), float(p["cp"]), float(p["gen_rpm"]), float(p["v_dc"]), float(p["i_dc"]), float(p["p_aero"]), float(p["p_elec"]), " (assisted)" if bool(p["assisted"]) else ""])
		print("  parts:")
		for pt in d["parts"]:
			print("    %d × %s %.1f × %.1f mm, %d scores — %s" % [int(pt["qty"]), str(pt["label"]), float(pt["w"]), float(pt["h"]), (pt["fold"] as Array).size(), str(pt["note"])])
		print("  nest: %d sheets of %s, unplaced %s" % [(d["nest"]["sheets"] as Array).size(), str(d["nest"]["sheet_label"]), str(d["nest"]["unplaced"])])
		for pr in d["prints"]:
			print("    print %d × %s %.0f mm, %.1f cm³, %d pieces" % [int(pr["qty"]), str(pr["label"]), float(pr["length_mm"]), float(pr["volume_cm3"]), int(pr["pieces"])])
		print("  mass ", d["mass"])
		print("  BOM $%.0f" % float(WindLabDesign.bom_total(d)["cost"]))
		for c in d["checks"]:
			print("  [%s] %s" % [str(c["level"]), str(c["text"])])
		if rank:
			var t1 := Time.get_ticks_msec()
			var rk := WindLabDesign.rank_generators(d["spec"])
			print("  generator ranking (%d ms):" % (Time.get_ticks_msec() - t1))
			for e in rk:
				print("    %-40s ratio %5.2f  AEP %7.2f kWh  design %6.1f W  start %.1f  cut-in %s" % [str(e["label"]), float(e["ratio"]), float(e["aep_kwh"]), float(e["design_w"]), float(e["start_ms"]), str(e["cut_in_ms"])])
	quit()
