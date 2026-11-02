extends SceneTree

## Every living-vehicle type x chassis combination the catalog allows,
## solved and measured (offline, read-only):
##   Godot --headless --path . --script tools/diag/vehicle_catalog_probe.gd
## Prints length, wheelbase, rear overhang (last axle to the back wall) and
## its share of the wheelbase, where the box starts against the cab, and
## the payload — the numbers vehiclelab_selftest's catalog test holds.


func _initialize() -> void:
	print("%-16s %-22s %6s %6s %6s %6s %7s %7s %8s" % ["type", "chassis", "len", "wb", "ovh", "ovh/wb",
		"box_z0", "cab_len", "payload"])
	for t in VehicleCatalog.TYPE_ORDER:
		var ti := VehicleCatalog.type_info(str(t))
		for cid in ti.get("chassis_ok", [ti["chassis"]]):
			var s := VehicleSpec.default_spec(str(t))
			s["chassis_id"] = str(cid)
			var d := VehicleDesign.solve(s)
			var ch: Dictionary = VehicleCatalog.chassis(str(cid))
			var half := float(d["half_len"])
			var last_axle := -INF
			for a in d["axles"]:
				last_axle = maxf(last_axle, float((a as Dictionary)["zf"]))
			var ovh := float(d["length_m"]) - last_axle
			var wb := float(ch.get("wheelbase_m", 0.0))
			var b: Dictionary = d["body"]
			print("%-16s %-22s %6.2f %6.2f %6.2f %6.2f %7.2f %7.2f %8.0f" % [t, cid, float(d["length_m"]), wb,
				ovh, (ovh / wb) if wb > 0.0 else 0.0, float(b["z0"]) + half, float(ch.get("cab_len_m", 0.0)),
				float(d["payload_kg"])])
	quit(0)
