extends SceneTree
## Offline: every designer structure cut into crew pieces (StructureUnits)
## and planned (PalletRackBuildPlan.plan_units) — pieces, piles, stages, how
## long the cut and plan take, the makespan for a crew of 8.
##   Godot --headless --path . --script tools/diag/structure_units_diag.gd [-- --only=domelab]


func _initialize() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	var recs: Array = []
	for p in DomeLabPresets.builtins():
		var sp: Dictionary = p.get("spec", p)
		recs.append({"label": "dome " + str(p.get("id", sp.get("name", ""))), "model_id": DomeLabBuilder.MODEL_ID, "domelab_spec": sp})
	for p in ToroidLabPresets.builtins():
		recs.append({"label": "toroid " + str(p.get("id", "")), "model_id": ToroidLabBuilder.MODEL_ID, "toroid_spec": p.get("spec", p)})
	for p in FlatpackPresets.builtins():
		recs.append({"label": "flatpack " + str(p.get("id", "")), "model_id": FlatpackBuilder.MODEL_ID, "flatpack_spec": p.get("spec", p)})
	for p in GantryLabPresets.builtins():
		recs.append({"label": "gantry " + str(p.get("id", "")), "model_id": GantryLabBuilder.MODEL_ID, "gantry_spec": p.get("spec", p)})
	for f in ["starshade_default.json", "ll_constellation.json", "ll_starshade_hex.json"]:
		var txt := FileAccess.get_file_as_string("res://core/linkage/presets/" + f)
		var cfg: Variant = JSON.parse_string(txt)
		if cfg is Dictionary:
			recs.append({"label": "linkage " + f, "model_id": LinkageStructureBuilder.MODEL_ID, "linkage_spec": cfg})
	for m in ["shiftpod", "ez_up", "firepit"]:
		recs.append({"label": "model " + m, "model_id": m})
	var worst_ms := 0
	for r in recs:
		if not only.is_empty() and not str(r["label"]).contains(only):
			continue
		var t0 := Time.get_ticks_msec()
		var n := StructureUnits.units_node(r, Vector3.ONE, root)
		var t1 := Time.get_ticks_msec()
		var units: Dictionary = n.get_meta("units", {})
		var kinds := {}
		var stages := {}
		for id in units:
			var k := str(units[id]["kind"])
			kinds[k] = int(kinds.get(k, 0)) + 1
			stages[int(units[id]["stage"])] = true
		var tl := PalletRackBuildPlan.plan_units(units, 8) if not units.is_empty() else {}
		var t2 := Time.get_ticks_msec()
		worst_ms = maxi(worst_ms, t2 - t0)
		print("%-44s %4d pieces %s, %d stages, cut %d ms, plan %d ms, makespan %s, blocked %s" % [
			str(r["label"]), units.size(), str(kinds), stages.size(), t1 - t0, t2 - t1,
			"%.0f s" % float(tl.get("makespan", 0.0)) if not tl.is_empty() else "-",
			str((tl.get("blocked", []) as Array).size()) if not tl.is_empty() else "-"])
		n.free()
	print("worst cut + plan %d ms" % worst_ms)
	quit(0)
