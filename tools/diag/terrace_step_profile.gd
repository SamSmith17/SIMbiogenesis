extends RefCounted

## Sandbox: what one live flow step of each terraced field costs, part by
## part (the paddy losses, the intake, the cascade, the water factors, the
## farm's fit + step), on the world's own fields at 60x. TSP_STEPS repeats
## (default 30).
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/terrace_step_profile.gd -Timeout 900

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var view: Node = main.find_child("SystemGraphView", true, false)
	var fe: Object = view.get("_resource_flow") if view != null else null
	var model: GraphModel = view.get("model") if view != null else null
	if fe == null or model == null:
		return {"ok": false, "why": "no flow engine"}
	main.set("time_scale", 60.0 / 3600.0)
	var fields: Array = []
	for it in model.items_of_type("plant"):
		if (it as Dictionary).get("specs", {}).has("terrace_table"):
			fields.append(it)
	print("terraceprof: %d field(s)" % fields.size())
	var n := int(OS.get_environment("TSP_STEPS")) if OS.get_environment("TSP_STEPS") != "" else 30
	for it in fields:
		var specs: Dictionary = (it as Dictionary)["specs"]
		var table: Array = specs.get("terrace_table", [])
		var heads: Array = specs.get("terrace_heads", [])
		var st: Dictionary = (fe.get("_terrace_state") as Dictionary).get(str(it["id"]), {})
		var store: PackedFloat64Array = st.get("s", PackedFloat64Array())
		if store.size() != table.size():
			store.resize(table.size())
		var fs: Dictionary = (st.get("farm", {}) as Dictionary).duplicate(true)
		var t := {"loss": 0, "cascade": 0, "wf": 0, "fit": 0, "farm": 0, "whole": 0}
		var kinds := {}
		for k in n:
			await tree.process_frame
			var abs_h := float(main.call("get_absolute_hours"))
			var u := Time.get_ticks_usec()
			var loss := PackedFloat64Array()
			loss.resize(table.size())
			var fps: Array = (fs.get("p", []) as Array) if not fs.is_empty() else []
			for i in table.size():
				var row: Array = table[i]
				var stg := str((fps[i] as Dictionary).get("st", "")) if i < fps.size() else ""
				var crop := str(row[6]) if row.size() > 6 else str(specs.get("crop", "fallow"))
				var fl := bool(row[7]) if row.size() > 7 else bool(specs.get("flooded", true))
				kinds["%s|%s|%s" % [crop, str(fl), stg]] = true
				loss[i] = TerraceField.paddy_loss_mm_h(specs, crop, fl, 20.0,
					stg == TerraceFarm.STAGE_GROW or stg == TerraceFarm.STAGE_HARVEST)
			t["loss"] += Time.get_ticks_usec() - u
			u = Time.get_ticks_usec()
			var res := TerraceField.cascade_step(table, store, heads, 0.0, 0.0, loss, 0.01)
			t["cascade"] += Time.get_ticks_usec() - u
			u = Time.get_ticks_usec()
			var wf_arr: Array = []
			for i in table.size():
				wf_arr.append(TerraceField.paddy_water_factor(table[i], (res["store"] as PackedFloat64Array)[i]))
			t["wf"] += Time.get_ticks_usec() - u
			u = Time.get_ticks_usec()
			var fs2 := TerraceFarm.fit(fs, table) if not fs.is_empty() else {}
			t["fit"] += Time.get_ticks_usec() - u
			u = Time.get_ticks_usec()
			if not fs2.is_empty():
				var built: Array = []
				for brow in table:
					built.append(float((brow as Array)[2]) > 0.0)
				TerraceFarm.step(table, fs2.duplicate(true), abs_h, 0.01, {"fuel_ok": true, "crews": true,
					"labour": str(specs.get("labour", "people")), "hour": fposmod(abs_h, 24.0),
					"par_wm2": 300.0, "month": 6, "wf": wf_arr, "built": built, "credit": {}})
			t["farm"] += Time.get_ticks_usec() - u
		print("terraceprof: field %s: %d paddies, %d distinct (crop, flooded, stage); per step ms: loss %.3f cascade %.3f wf %.3f fit %.3f farm %.3f" % [
			str(it["id"]), table.size(), kinds.size(), float(t["loss"]) / n / 1000.0, float(t["cascade"]) / n / 1000.0,
			float(t["wf"]) / n / 1000.0, float(t["fit"]) / n / 1000.0, float(t["farm"]) / n / 1000.0])
	return {"ok": true}
