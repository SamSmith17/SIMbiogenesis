extends RefCounted

## What shedding AC costs once a camp of living vehicles stands (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/ac_shed_cost_probe.gd
## Places VEHICLES vehicles near the player, then times every callable
## connected to AcPowerBus / SolarUI's AC signals, one by one, for "off" and
## "on". Prints `acshed …` lines, slowest first.

const VEHICLES := 40
const PRESETS := ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "rv", "box_truck", "ambulance"]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	main.set("time_scale", 0.0)
	var player := main.get_node_or_null("Player") as Node3D
	var p0 := Vector2(player.global_position.x, player.global_position.z)
	for k in VEHICLES:
		var at := p0 + Vector2(20.0 + float(k % 8) * 10.0, float(k / 8) * 12.0)
		PlacedPropService.place_prepped_at(main, VehicleBuilder.MODEL_ID,
			{"record_extra": {"vehicle_spec": VehicleSpec.to_json_safe(VehiclePresets.builtin(str(PRESETS[k % PRESETS.size()]))),
				"collision_enabled": true}}, at.x, at.y, 0.0)
	for _i in 30:
		await tree.process_frame
	var rows: Array = []
	var apb := main.get_node_or_null("/root/AcPowerBus")
	var sui := ServiceLocator.solar_ui()
	for src in [apb, sui]:
		if src == null:
			continue
		for sig in ["power_availability_changed", "ac_shutdown_changed"]:
			if not src.has_signal(sig):
				continue
			for c in src.get_signal_connection_list(sig):
				var cb: Callable = c["callable"]
				var obj: Object = cb.get_object()
				var who := "%s.%s" % [(obj as Node).get_path() if obj is Node else str(obj), cb.get_method()]
				var t := Time.get_ticks_usec()
				if sig == "power_availability_changed":
					cb.call(false)
				else:
					cb.call(true, "overload")
				var off_ms := float(Time.get_ticks_usec() - t) / 1000.0
				t = Time.get_ticks_usec()
				if sig == "power_availability_changed":
					cb.call(true)
				else:
					cb.call(false, "")
				var on_ms := float(Time.get_ticks_usec() - t) / 1000.0
				rows.append([off_ms + on_ms, "%s %s off %.1f ms on %.1f ms" % [sig, who, off_ms, on_ms]])
	rows.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	print("acshed: %d listeners" % rows.size())
	for r in rows.slice(0, 15):
		print("acshed: " + str(r[1]))
	return {"ok": true}
