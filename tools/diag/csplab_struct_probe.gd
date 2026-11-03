extends SceneTree

## The concentrator designer's support structures, headless: per built-in
## the mount, pivot, steel, concrete, counterweight, swing, stress and the
## drive, plus every structure check. -- --preset=<id> for one.

func _initialize() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			only = a.substr(9)
	for b in CspLabPresets.builtins():
		var id := str((b as Dictionary)["id"])
		if not only.is_empty() and id != only:
			continue
		var d := CspLabDesign.solve((b as Dictionary)["spec"] as Dictionary)
		var st: Dictionary = d["structure"]
		var ld: Dictionary = st.get("loads", {}) as Dictionary
		var labels := {}
		for m in (st["members"] as Array):
			var l := str((m as Dictionary).get("label", ""))
			labels[l] = int(labels.get(l, 0)) + 1
		print("---- %s  mount=%s pivot_w=%s pivot_l=%s swing=%.2f" % [id, str(st["mount"]), str(st["pivot_world"]), str(st["pivot_local"]), float(st.get("swing_r", 0.0))])
		print("  steel %.0f kg, concrete %.2f m3 (%.0f kg), counterweight %.0f kg (arm %.2f m), optic %.0f kg, members %d" % [
			float(st["mass_kg"]), float(st["concrete_m3"]), float(st["concrete_kg"]), float(st["counterweight_kg"]), float(st.get("cw_arm_m", 0.0)),
			float(d["optic_mass_kg"]), (st["members"] as Array).size()])
		print("  stress %.0f MPa util %.2f drive %s" % [float(ld.get("stress_mpa", 0.0)), float(ld.get("utilisation", 0.0)), str((st.get("drive", {}) as Dictionary).get("label", "-"))])
		print("  ", labels)
		for c in (st["checks"] as Array):
			print("  [%s] %s" % [str((c as Dictionary)["level"]), str((c as Dictionary)["text"])])
	quit(0)
