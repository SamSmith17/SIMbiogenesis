extends SceneTree

## The BOM rows of a design (diag): Godot --headless --path . --script tools/diag/gantry_bom_probe.gd -- [--kin=corexy]
func _initialize() -> void:
	var kin := "corexy"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--kin="):
			kin = a.substr(6)
	var d := GantryLabDesign.solve(GantryLabSpec.default_spec(kin))
	for r in d["bom"]["rows"]:
		print("%-12s %4d  %-40s %8.2f" % [r["cat"], int(r["qty"]), str(r["item"]), float(r["usd"]) * float(r["qty"])])
	print("TOTAL $%.0f  %.1f kg" % [float(d["bom"]["usd"]), float(d["bom"]["kg"])])
	quit()
