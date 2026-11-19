extends RefCounted

## Sandbox, read-only: what SystemGraphView._sync_solar_ui_from_graph spends,
## part by part (median of 15 calls each, after one warm-up).
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/solar_sync_profile.gd

func _time(c: Callable, n: int = 15) -> float:
	c.call()
	var ts: Array = []
	for i in n:
		var t := Time.get_ticks_usec()
		c.call()
		ts.append(float(Time.get_ticks_usec() - t) / 1000.0)
	ts.sort()
	return float(ts[ts.size() / 2])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var v: Node = main.find_child("SystemGraphView", true, false)
	if v == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var solar: Node = v.get("_solar_ui")
	var parts := {
		"whole sync": func() -> void: v.call("_sync_solar_ui_from_graph"),
		"array aggregate": func() -> void: v.call("_collect_root_array_aggregate"),
		"battery aggregate": func() -> void: v.call("_collect_battery_aggregate"),
		"average battery soc": func() -> void: v.call("_average_graph_battery_soc"),
		"controller limits": func() -> void: v.call("_controller_power_limits"),
		"energy from solar": func() -> void:
			v.call("_begin_sim_writes")
			v.call("_sync_graph_energy_from_solar")
			v.call("_end_sim_writes"),
	}
	if solar != null:
		var agg: Dictionary = v.call("_collect_root_array_aggregate")
		var bat: Dictionary = v.call("_collect_battery_aggregate")
		var payload := {
			"panel_count": int(agg.get("panel_count", 0)),
			"panel_watts": float(agg.get("panel_wmp", 0.0)) / maxf(float(agg.get("panel_count", 1)), 1.0),
			"peak_kw": float(agg.get("panel_wmp", 0.0)) / 1000.0,
			"battery_kwh": float(bat.get("total_kwh", 0.0)),
			"battery_count": int(bat.get("count", 0)),
			"battery_soc": float(v.call("_average_graph_battery_soc")),
			"planes": agg.get("planes", []),
		}
		parts["SolarUI.apply_from_graph"] = func() -> void: solar.call("apply_from_graph", payload)
		parts["SolarUI.set_graph_has_solar"] = func() -> void: solar.call("set_graph_has_solar", true)
	for k in parts.keys():
		print("solarsync %-28s median %7.3f ms" % [k, _time(parts[k])])
	var same := true
	if v.has_method("_controller_power_limits_now"):
		same = v.call("_controller_power_limits") == v.call("_controller_power_limits_now")
		print("solarsync cached controller limits == fresh: %s" % str(same))
	return {"ok": same}
