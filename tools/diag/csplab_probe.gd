extends SceneTree

## The concentrator designer's numbers for every built-in (or one:
## -- --preset=<id>), headless. Prints the efficiency chain, concentration,
## heat and the checks.

func _initialize() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			only = a.substr(9)
	for b in CspLabPresets.builtins():
		var id := str((b as Dictionary)["id"])
		if not only.is_empty() and id != only:
			continue
		var t0 := Time.get_ticks_msec()
		var d := CspLabDesign.solve((b as Dictionary)["spec"] as Dictionary)
		print("---- %s (%d ms)" % [id, Time.get_ticks_msec() - t0])
		print(CspLabDesign.summary(d))
	quit(0)
