extends SceneTree

## Prints a living vehicle preset's floor as the interior access check sees
## it (VehicleInterior.access): # blocked, . walkable but not reached from a
## door, o reached, with each element's footprint letter on top and the
## entries listed. Front of the box at the top.
##   Godot --headless --path . --script tools/diag/vehicle_access_diag.gd -- --preset=shuttle_bus


func _initialize() -> void:
	var want := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			want = a.substr(9)
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		if not want.is_empty() and id != want:
			continue
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var ac := VehicleInterior.access(d)
		var house: Dictionary = d["house"]
		var nx := int(ac["nx"])
		var nz := int(ac["nz"])
		var walk: PackedByteArray = ac["walk"]
		print("== %s  house %.2f × %.2f m  entries %s  reach %s" % [id, float(house["w"]), float(house["len"]),
			str(VehicleInterior.entries(d)), str(ac["reachable"])])
		var hw := float(house["w"])
		var z0 := float(house["z0"])
		for e in d["interior"]:
			var el: Dictionary = e
			print("  %-10s x %+.2f ±%.2f  z %+.2f ±%.2f (from front %.2f..%.2f)  top %.2f  blocks %s" % [el["id"],
				float(el["x"]), float(el["fx"]) * 0.5, float(el["z"]), float(el["fz"]) * 0.5,
				float(el["z"]) - float(el["fz"]) * 0.5 - z0, float(el["z"]) + float(el["fz"]) * 0.5 - z0,
				float(el["top_y"]) - float(house["floor_y"]), VehicleInterior.blocks_floor(d, el)])
		for iz in nz:
			var line := ""
			var z := z0 + (float(iz) + 0.5) * VehicleInterior.CELL_M
			for ix in nx:
				var x := -hw * 0.5 + (float(ix) + 0.5) * VehicleInterior.CELL_M
				var ch := "#" if walk[iz * nx + ix] == 0 else ("o" if walk[iz * nx + ix] == 2 else ".")
				for e in d["interior"]:
					var el: Dictionary = e
					if not VehicleInterior.blocks_floor(d, el):
						continue
					if absf(x - float(el["x"])) <= float(el["fx"]) * 0.5 and absf(z - float(el["z"])) <= float(el["fz"]) * 0.5:
						ch = str(el["type"]).substr(0, 1).to_upper()
				line += ch
			print(line)
	quit()
