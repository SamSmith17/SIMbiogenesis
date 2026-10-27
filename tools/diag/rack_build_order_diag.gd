extends SceneTree
## Offline: the crew-build plan of a pallet-rack preset in order — every job's
## time and kind, which units no job moves (they would stand finished from the
## first frame), and the share of pieces up at a few points of the build.
##   Godot --headless --path . --script tools/diag/rack_build_order_diag.gd -- --preset=tool_camp_26 --crew=12


func _initialize() -> void:
	var preset := "tool_camp_26"
	var crew := 12
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			preset = a.trim_prefix("--preset=")
		elif a.begins_with("--crew="):
			crew = int(a.trim_prefix("--crew="))
	var spec := {}
	for d in PalletRackBuilder.design_presets():
		if str(d.get("id", "")) == preset:
			spec = d.get("spec", {})
	if spec.is_empty():
		print("no preset ", preset)
		quit(1)
		return
	var n := PalletRackBuilder.build_units_node(spec)
	var units: Dictionary = n.get_meta("units", {})
	var t0 := Time.get_ticks_msec()
	var tl := PalletRackBuildPlan.plan(spec, crew, units)
	print("units %d, planned %d, jobs %d, makespan %.0f s, blocked %d, plan %d ms" % [units.size(),
		(tl["unit"] as Dictionary).size(), (tl["jobs"] as Array).size(), float(tl["makespan"]),
		(tl["blocked"] as Array).size(), Time.get_ticks_msec() - t0])
	var missing := 0
	for id in units:
		if not (tl["unit"] as Dictionary).has(id):
			missing += 1
			if missing < 20:
				print("  NOT PLANNED: ", id)
	print("not planned: ", missing)
	var kinds := {}
	for id in units:
		var k := str(units[id].get("kind", "?"))
		kinds[k] = int(kinds.get(k, 0)) + 1
	print("unit kinds: ", kinds)
	var jobs: Array = tl["jobs"]
	var order := range(jobs.size())
	order.sort_custom(func(a, b): return float(jobs[a]["t0"]) < float(jobs[b]["t0"]))
	var i := 0
	for ji in order:
		var j: Dictionary = jobs[ji]
		if str(j["kind"]) == "carry":
			continue
		if i < 60 or i % 20 == 0:
			print("  %6.0f-%6.0f %-8s %s" % [float(j["t0"]), float(j["t1"]), str(j["kind"]), str(j.get("label", ""))])
		i += 1
	var mk := float(tl["makespan"])
	for f in [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]:
		var st := PalletRackBuildPlan.state_at(tl, f * mk)
		var installed := 0
		var heads := {}
		for id in st["units"]:
			var s: Dictionary = st["units"][id]
			if float(s["g"]) <= 0.001 and (s["xf"] as Transform3D).is_equal_approx(Transform3D()):
				installed += 1
				var leaf := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
				var h := leaf.get_slice(":", 0)
				heads[h] = int(heads.get(h, 0)) + 1
		print("at %3d %%: %d of %d installed %s" % [int(f * 100), installed, units.size(), heads])
	n.free()
	quit(0)
