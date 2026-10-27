extends SceneTree

## The gantry assembly as built: part count, fasteners, the issues and the
## clash / belt report for each V-slot preset (or --kin=<kinematics>).
## Not a selftest — a probe for the generators.
##   Godot --headless --path . --script tools/diag/gantry_assembly_probe.gd -- [--kin=bedslinger] [--verbose]

func _initialize() -> void:
	var kin := "bedslinger"
	var verbose := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--kin="):
			kin = a.substr(6)
		if a == "--verbose":
			verbose = true
	var specs: Array = []
	if kin == "presets":
		for p in GantryLabPresets.builtins():
			if GantryLabAssembly.uses_assembly(str(GantryLabSpec.resolve(p["spec"])["kinematics"])):
				specs.append(p["spec"])
	elif kin == "all":
		for k in GantryLabAssembly.KINEMATICS:
			specs.append(GantryLabSpec.default_spec(k))
		for p in GantryLabPresets.builtins():
			if GantryLabAssembly.uses_assembly(str(GantryLabSpec.resolve(p["spec"])["kinematics"])):
				specs.append(p["spec"])
	elif kin.begins_with("sweep:"):
		var k := kin.substr(6)
		for sz in [120.0, 220.0, 350.0, 500.0]:
			for tool in ["hotend_04", "pen", "laser_10w", "clay_extruder", "spindle_500w", "flake_extruder_6mm"]:
				for prof in ["2020", "2040", "4040"]:
					for mot in ["nema17", "nema17_hi", "nema23"]:
						var sp := GantryLabSpec.default_spec(k)
						sp["volume"] = {"x_mm": sz, "y_mm": sz * 0.9, "z_mm": sz * 1.1}
						sp["tool"]["id"] = tool
						sp["tool"]["bed"] = str(GantryLabParts.tool(tool)["bed"])
						sp["frame"]["profile"] = prof
						sp["frame"]["gantry_profile"] = prof
						for ax in ["x", "y", "z"]:
							sp["axis"][ax]["motor"] = mot
						sp["name"] = "%s %.0f %s %s %s" % [k, sz, tool, prof, mot]
						specs.append(sp)
	elif kin.begins_with("rods:"):
		# The shaft-guided lowering bed across sizes, tools, frames, shafts
		# and one or two Z motors.
		var k := kin.substr(5)
		for sz in [150.0, 220.0, 330.0, 500.0, 700.0]:
			for tool in ["hotend_04", "pellet_extruder", "flake_extruder_6mm", "laser_10w", "spindle_500w"]:
				if tool == "flake_extruder_6mm" and sz < 330.0:
					continue
				for prof in ["2020", "2040", "4040"]:
					for g in ["rod_8", "rod_10", "rod_12"]:
						for zn in [1, 2]:
							for zmot in ["nema17", "nema23"]:
								var sp := GantryLabSpec.default_spec(k)
								sp["volume"] = {"x_mm": sz, "y_mm": sz * 0.9, "z_mm": sz * 1.1}
								sp["tool"]["id"] = tool
								sp["tool"]["bed"] = str(GantryLabParts.tool(tool)["bed"])
								sp["frame"]["profile"] = prof
								sp["axis"]["z"]["guide"] = g
								sp["axis"]["z"]["motors"] = zn
								sp["axis"]["z"]["motor"] = zmot
								sp["axis"]["z"]["drive"] = "leadscrew_t8_8"
								sp["name"] = "%s %.0f %s %s %s z%d %s" % [k, sz, tool, prof, g, zn, zmot]
								specs.append(sp)
	else:
		specs.append(GantryLabSpec.default_spec(kin))
	for sp in specs:
		var s := GantryLabSpec.resolve(sp)
		var t0 := Time.get_ticks_msec()
		var lay := GantryLabFrame.layout(s)
		var t1 := Time.get_ticks_msec()
		var res: Dictionary = lay.get("assembly", {})
		var issues: Array = lay.get("issues", [])
		var clash := GantryLabClash.check(s, lay)
		var t2 := Time.get_ticks_msec()
		print("== %s (%s): %d parts, %d fasteners, layout %d ms, clash %d ms" % [str(s["name"]), str(s["kinematics"]), res.get("parts", {}).size(), (res.get("fasteners", []) as Array).size(), t1 - t0, t2 - t1])
		print("   origin %s  dims %s  bead %s" % [str(lay["origin"]), str(lay["dims"]), str(lay["bead_origin"])])
		for i in issues:
			if not bool((i as Dictionary).get("note", false)) and not str(i["text"]).begins_with("One Z motor"):
				print("   ISSUE [%s] %s" % [i["level"], i["text"]])
		for c in clash:
			print("   CLASH %s  %s" % [c["text"], str(c.get("parts", []))])
		if verbose:
			for id in res["order"]:
				if res["parts"].has(id):
					var w: Transform3D = res["parts"][id]["world"]
					print("     %-16s %-14s %s  asm=%s" % [id, str(res["parts"][id]["part"].get("ref", "")), str(w.origin), str(res["parts"][id]["asm"])])
	quit()
