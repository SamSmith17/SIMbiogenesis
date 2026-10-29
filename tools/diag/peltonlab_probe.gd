extends SceneTree

## Prints a Pelton wheel design's numbers (headless): runner, rules, the
## operating point, strength and every check. --preset=<id> picks a built-in.
func _initialize() -> void:
	var spec := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			spec = PeltonLabPresets.builtin(a.substr(9))
	var d := PeltonLabDesign.solve(spec)
	var rn: Dictionary = d["runner"]
	print("cup mesh from file: ", PeltonLabCup.from_file(), " surfaces ", PeltonLabCup.mesh().get_surface_count())
	print("runner: tip r %.1f pitch r %.1f root r %.1f bowl root r %.1f k %.3f cup %.3f kg" % [rn["tip_r_mm"], rn["pitch_r_mm"], rn["root_r_mm"], rn["bowl_root_r_mm"], rn["k"], rn["cup_mass_kg"]])
	print("rotor: ", d["rotor"])
	print("rules: ", d["rules"])
	print("perf: ", d["perf"])
	print("strength: ", d.get("strength", {}))
	print("housing: ", d["housing"])
	print("shaft: ", d["shaft"]["bearings_x_mm"], " x ", d["shaft"]["x0_mm"], "..", d["shaft"]["x1_mm"])
	print("drive: ", d["drive"])
	print("aabb: ", d["aabb"])
	for c in d["checks"]:
		print("  [%s] %s" % [c["level"], c["text"]])
	print("bom total: ", PeltonLabDesign.bom_total(d))
	quit()
