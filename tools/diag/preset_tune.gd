extends SceneTree

## Rates that would make a preset close its elements (resource composition
## plan Phase 3), for tuning presets by hand. Offline:
##   Godot --headless --path . --script tools/diag/preset_tune.gd -- --preset="Biochar Reactor" --free=woodgas,wood_vinegar,tar [--elements=C,H,O] [--extra-out=biochar:2.0]
## The free outputs' rates are solved by least squares over the elements
## (the preset's other outputs stay as listed); then the balance with the
## preset's own `air` is printed for the solved rates.


func _initialize() -> void:
	var label := ""
	var free: Array = []
	var elements: Array = ["C", "H", "O"]
	var extra: Dictionary = {}
	var drop: Array = []
	var air: Variant = null
	var gas_mix: Dictionary = {}
	var gas_rate := -1.0
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--preset="):
			label = s.substr(9).trim_prefix("\"").trim_suffix("\"")
		elif s.begins_with("--free="):
			free = Array(s.substr(7).split(","))
		elif s.begins_with("--elements="):
			elements = Array(s.substr(11).split(","))
		elif s.begins_with("--drop="):
			drop = Array(s.substr(7).split(","))
		elif s.begins_with("--gas="):
			var mix: Dictionary = {}
			for q in s.substr(6).split(","):
				var qv: PackedStringArray = str(q).split(":")
				mix[qv[0]] = float(qv[1])
			gas_mix["woodgas"] = mix
		elif s.begins_with("--gas-rate="):
			gas_rate = float(s.substr(11))
		elif s.begins_with("--air="):
			air = s.substr(6)
		elif s.begins_with("--extra-out="):
			for p in s.substr(12).split(","):
				var kv: PackedStringArray = str(p).split(":")
				extra[kv[0]] = float(kv[1])
	var preset := ComponentPresets.find_preset_by_label(label)
	if preset.is_empty():
		print("no preset '%s'" % label)
		quit(1)
		return
	var specs: Dictionary = preset["specs"]
	var fixed: Array = []
	for o in specs.get("outputs", []):
		var ok := str((o as Dictionary).get("kind", ""))
		if not free.has(ok) and not extra.has(ok) and not drop.has(ok):
			fixed.append(o)
	for k in extra.keys():
		fixed.append({"kind": k, "rate": float(extra[k])})
	if gas_rate >= 0.0 and gas_mix.has("woodgas"):
		fixed.append({"kind": "woodgas", "rate": gas_rate, "composition": gas_mix["woodgas"]})
	var sol := MassBalance.solve_free_outputs(specs.get("inputs", []), fixed, free, elements, gas_mix)
	print("solved: ", sol)
	var outs: Array = fixed.duplicate()
	for k2 in sol.keys():
		var o2 := {"kind": k2, "rate": float(sol[k2])}
		if gas_mix.has(k2):
			o2["composition"] = gas_mix[k2]
		outs.append(o2)
	var mb := MassBalance.check(specs.get("inputs", []), outs, [], [], 0.05, air if air != null else specs.get("air", ""),
		{"retain": specs.get("retain", [])})
	print("verdict %s  mass in %.4f out %.4f  loses %s creates %s minor %s  air %s" % [mb["verdict"],
		float((mb["in"] as Dictionary)["kg"]), float((mb["out"] as Dictionary)["kg"]), mb["loses"],
		mb["creates"], mb["minor"], mb["air"]])
	for e in MassBalance.MAIN_ELEMENTS:
		print("  %s in %.5f out %.5f" % [e, float((mb["in"]["elements"] as Dictionary).get(e, 0.0)),
			float((mb["out"]["elements"] as Dictionary).get(e, 0.0))])
	quit(0)
