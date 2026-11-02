extends SceneTree

## Living-vehicle designer self-test (offline, deterministic):
##   Godot --headless --path . --script core/vehiclelab/vehiclelab_selftest.gd
## Run `--import` first after adding a class_name. Carries EXPECTED_CHECKS: a
## Godot runtime error aborts the enclosing test function while the suite
## still prints PASS, so the count is what catches it.

const EXPECTED_CHECKS := 200

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_test_catalog()
	_test_spec_round_trip()
	_test_turning_radius()
	_test_presets_solve()
	_test_beds_and_spaces()
	_test_energy_bands()
	_test_trip()
	_test_riding_profile()
	_test_builder_winding()
	_test_builder_metas()
	_test_space_roles()
	var total := _passed + _failed
	_check("check count", total == EXPECTED_CHECKS, "ran %d, expected %d" % [total, EXPECTED_CHECKS])
	print("vehiclelab_selftest: %d passed, %d failed" % [_passed, _failed])
	print("PASS" if _failed == 0 else "FAILURE(S)")
	quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL %s %s" % [name, detail])


func _test_catalog() -> void:
	_check("eleven types", VehicleCatalog.TYPE_ORDER.size() == 11)
	for t in VehicleCatalog.TYPE_ORDER:
		var ti := VehicleCatalog.type_info(t)
		_check("type %s chassis known" % t, VehicleCatalog.CHASSIS.has(str(ti["chassis"])))
		_check("type %s body known" % t, VehicleCatalog.BODIES.has(str(ti["body"])))


func _test_spec_round_trip() -> void:
	var s := VehiclePresets.builtin("shuttle_bus")
	var json := JSON.stringify(VehicleSpec.to_json_safe(s))
	var back: Dictionary = JSON.parse_string(json)
	_check("round trip keeps the key", VehicleSpec.key_of(back) == VehicleSpec.key_of(s))
	var r := VehicleSpec.resolve(back)
	_check("resolve adds ch + bd", r.has("ch") and r.has("bd"))
	_check("to_json_safe strips ch + bd", not VehicleSpec.to_json_safe(r).has("ch"))
	var other := s.duplicate(true)
	other["chassis_id"] = "chevy_express_3500"
	_check("a chassis change moves the key", VehicleSpec.key_of(other) != VehicleSpec.key_of(s))


func _test_turning_radius() -> void:
	# E-450 176" WB, 38 deg: rear-axle radius 4.470 / tan 38 = 5.721; outer
	# front wheel = sqrt((5.721 + 0.875)^2 + 4.470^2) = 7.968 m (Ford quotes a
	# ~54-55 ft curb-to-curb circle on this wheelbase).
	var s := VehicleSpec.default_spec("shuttle_bus")
	var d := VehicleDesign.solve(s)
	_check("E-450 turning radius by hand", absf(float(d["turn_radius_m"]) - 7.968) < 0.02,
		"%.3f" % float(d["turn_radius_m"]))
	var t := VehicleDesign.solve(VehicleSpec.default_spec("trailer"))
	_check("a trailer does not steer", float(t["turn_radius_m"]) == 0.0)


func _test_presets_solve() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var errs: Array = []
		var warns: Array = []
		for c in d["checks"]:
			if str((c as Dictionary)["level"]) == "error":
				errs.append((c as Dictionary)["text"])
			elif str((c as Dictionary)["level"]) == "warn":
				warns.append((c as Dictionary)["text"])
		_check("%s solves with no error" % id, errs.is_empty(), str(errs))
		_check("%s has no overlaps or warnings" % id, warns.is_empty(), str(warns))
		_check("%s length sane" % id, float(d["length_m"]) > 4.0 and float(d["length_m"]) < 17.0,
			"%.2f" % float(d["length_m"]))
		var house: Dictionary = d["house"]
		_check("%s living box has room" % id, float(house["len"]) > 2.5 and float(house["height"]) > 1.5,
			"len %.2f h %.2f" % [float(house["len"]), float(house["height"])])
		_check("%s rear axle inside the length" % id, _axles_inside(d))
		_check("%s payload positive" % id, float(d["payload_kg"]) > 0.0, "%.0f" % float(d["payload_kg"]))


func _axles_inside(d: Dictionary) -> bool:
	for w in d["wheels"]:
		var z: float = float(((w as Dictionary)["pos"] as Vector3).z)
		if absf(z) > float(d["half_len"]):
			return false
	return true


func _test_beds_and_spaces() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var house: Dictionary = d["house"]
		_check("%s sleeps someone" % id, int(d["sleeps"]) >= 1)
		var ok := true
		for bed in d["beds"]:
			var p: Vector3 = (bed as Dictionary)["pos"]
			if p.y < float(house["floor_y"]) + 0.2:
				ok = false
			if absf(p.x) > float(house["w"]) * 0.5 + 0.01:
				ok = false
			if p.z < float(house["z0"]) - 2.5 or p.z > float(house["z1"]) + 0.01:
				ok = false
			var yaw := float((bed as Dictionary)["yaw"])
			if not (is_equal_approx(yaw, 0.0) or is_equal_approx(yaw, PI * 0.5)):
				ok = false
		_check("%s beds inside, raised, along an axis" % id, ok)
	var sh := VehicleDesign.solve(VehiclePresets.builtin("shuttle_bus"))
	var types := {}
	for sp in VehicleDesign.spaces(sh):
		types[str((sp as Dictionary)["space_type"])] = sp
	_check("shuttle offers sleep", types.has("sleep") and int((types["sleep"] as Dictionary)["capacity"]) == 2)
	_check("shuttle offers a kitchen", types.has("kitchen"))
	_check("shuttle offers a shower", types.has("shower"))
	_check("shuttle offers a restroom", types.has("restroom"))
	var kitchen: Vector3 = (types["kitchen"] as Dictionary)["anchor"]
	_check("kitchen spot on the floor", absf(kitchen.y - float((sh["house"] as Dictionary)["floor_y"])) < 0.01)
	# The skoolie's bunks stack two sleepers on one footprint.
	var bus := VehicleDesign.solve(VehiclePresets.builtin("school_bus"))
	var bunk_ys: Array = []
	for bed in bus["beds"]:
		if str((bed as Dictionary)["bed"]) == "bunks":
			bunk_ys.append(((bed as Dictionary)["pos"] as Vector3).y)
	_check("bunks stack", bunk_ys.size() == 2 and absf(float(bunk_ys[0]) - float(bunk_ys[1])) > 0.7)
	# A transverse bed lies across.
	var box := VehicleDesign.solve(VehiclePresets.builtin("box_truck"))
	_check("transverse bed lies across", is_equal_approx(float((box["beds"][0] as Dictionary)["yaw"]), PI * 0.5))
	# The RV's cab-over sits over the cab.
	var rv := VehicleDesign.solve(VehiclePresets.builtin("rv"))
	var cab_top := float((rv["cab_geo"] as Dictionary)["h"])
	var over := false
	for bed in rv["beds"]:
		if ((bed as Dictionary)["pos"] as Vector3).y > cab_top:
			over = true
	_check("RV cab-over bed is up over the cab", over)


func _test_energy_bands() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var band: Array = ((d["spec"] as Dictionary)["ch"] as Dictionary).get("mpg", [])
		var e: Dictionary = d["energy_55"]
		if band.size() == 2:
			var mpg := float(e["mpg"])
			_check("%s mpg %.1f within %s" % [id, mpg, str(band)],
				mpg >= float(band[0]) and mpg <= float(band[1]))
		else:
			_check("%s has no fuel band (trailer / EV)" % id, str(d["fuel"]) in ["none", "electric"])
	# The EV van: ~0.5-0.8 kWh per mile at 55 mph (Ford's E-Transit figures).
	var ev := VehiclePresets.builtin("van")
	ev["chassis_id"] = "ford_etransit"
	var de := VehicleDesign.solve(ev)
	var kwh_mi := float((de["energy_55"] as Dictionary)["kwh_per_km"]) * VehicleEnergy.MI_M / 1000.0
	_check("E-Transit kWh/mi in range", kwh_mi > 0.45 and kwh_mi < 0.85, "%.3f" % kwh_mi)
	# More drag costs more fuel; heavier costs more fuel.
	var lo := VehicleEnergy.source_j_per_m(4000.0, 0.4, 6.0, 25.0, "gasoline")
	var hi := VehicleEnergy.source_j_per_m(4000.0, 0.7, 6.0, 25.0, "gasoline")
	_check("drag costs fuel", hi > lo)
	_check("weight costs fuel", VehicleEnergy.source_j_per_m(8000.0, 0.4, 6.0, 25.0, "gasoline") > lo)
	_check("diesel beats gasoline per joule", VehicleEnergy.source_j_per_m(4000.0, 0.4, 6.0, 25.0, "diesel") < lo)


func _test_trip() -> void:
	var s := VehiclePresets.builtin("shuttle_bus")
	s["trip"] = {"one_way_mi": 300.0, "fuel_price_per_gal": 4.0, "kwh_price": 0.3}
	var d := VehicleDesign.solve(s)
	var t: Dictionary = d["trip_estimate"]
	var mpg := float((d["energy_55"] as Dictionary)["mpg"])
	_check("trip gallons = 600 mi / mpg", absf(float(t["gallons"]) - 600.0 / mpg) < 0.5,
		"%.2f vs %.2f" % [float(t["gallons"]), 600.0 / mpg])
	_check("trip cost = gallons x price", absf(float(t["cost"]) - float(t["gallons"]) * 4.0) < 0.01)
	_check("range from the tank", float(t["range_km"]) > 300.0)


func _test_riding_profile() -> void:
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		var d := VehicleDesign.solve((b as Dictionary)["spec"])
		var p := VehicleDesign.riding_profile(d)
		if id == "trailer":
			_check("trailer has no riding profile", p.is_empty())
			continue
		_check("%s drivable" % id, not p.is_empty())
		for k in PlacedVehicle.PROFILES["van"]:
			if not p.has(k):
				_check("%s profile key %s" % [id, k], false)
		var cam: Vector3 = p["camera_offset"]
		_check("%s driver in front half, on the left" % id, cam.z < 0.0 and cam.x < 0.0, str(cam))
		_check("%s eye above the ground" % id, cam.y + 1.65 > 1.5, str(cam))


func _test_builder_winding() -> void:
	for id in ["van", "shuttle_bus", "school_bus", "rv", "motorhome", "trailer", "semi_container"]:
		var root := VehicleBuilder.build_node(VehiclePresets.builtin(id))
		var bad := 0
		var tris := 0
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var mesh := (mi as MeshInstance3D).mesh as ArrayMesh
			for si in mesh.get_surface_count():
				var arr := mesh.surface_get_arrays(si)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				var count := idx.size() if idx.size() > 0 else v.size()
				for t in range(0, count, 3):
					var i0 := idx[t] if idx.size() > 0 else t
					var i1 := idx[t + 1] if idx.size() > 0 else t + 1
					var i2 := idx[t + 2] if idx.size() > 0 else t + 2
					var fn := (v[i1] - v[i0]).cross(v[i2] - v[i0])
					if fn.length_squared() < 1e-14:
						continue
					tris += 1
					var avg := n[i0] + n[i1] + n[i2]
					if fn.dot(avg) >= 0.0:
						bad += 1
		_check("%s winding (clockwise from outside)" % id, bad == 0, "%d of %d" % [bad, tris])
		_check("%s has geometry" % id, tris > 300, str(tris))
		root.free()


func _test_builder_metas() -> void:
	var root := VehicleBuilder.build_node(VehiclePresets.builtin("shuttle_bus"))
	_check("living_vehicle meta", root.has_meta("living_vehicle"))
	var spots: Array = root.get_meta("seat_spots", [])
	var lie := 0
	for sp in spots:
		if str((sp as Dictionary)["kind"]) == "lie":
			lie += 1
	_check("seat_spots carry the beds", lie == 2)
	var roles: Dictionary = root.get_meta("role_spots", {})
	_check("role spots for the kitchen", not (roles.get("kitchen", []) as Array).is_empty())
	_check("a Shell node", root.get_node_or_null("Shell") != null)
	root.free()
	var cut := VehicleBuilder.build_node(VehiclePresets.builtin("shuttle_bus"), VehicleBuilder.MODEL_ID,
		{"cutaway": true})
	_check("cutaway has no shell", cut.get_node_or_null("Shell") == null)
	cut.free()
	_check("handles preset ids", VehicleBuilder.handles("vehiclelab_rv"))
	_check("preset for an id", str(VehicleBuilder.preset_for_model("vehiclelab_rv")["type"]) == "rv")


## One prop, several spaces: a role tells them apart; a role-less target is
## still the old single space; an anchor lands on the prop, turned with it.
func _test_space_roles() -> void:
	var reg := SpaceRegistry.create_empty()
	var sleep_id := reg.set_space_type({"kind": "prop", "prop_id": "p1"}, "sleep", 2, "Van")
	var kit_id := reg.set_space_type({"kind": "prop", "prop_id": "p1", "role": "kitchen",
		"anchor": [-0.5, 1.0]}, "kitchen", 1, "Van kitchen")
	_check("two spaces on one prop", not sleep_id.is_empty() and not kit_id.is_empty() and sleep_id != kit_id)
	_check("role-less target finds the sleep space",
		str(reg.space_for_target({"kind": "prop", "prop_id": "p1"}).get("id", "")) == sleep_id)
	var again := reg.set_space_type({"kind": "prop", "prop_id": "p1", "role": "kitchen"}, "kitchen", 1, "")
	_check("re-tagging a role upserts", again == kit_id and reg.spaces.size() == 2)
	var rec := {"x": 10.0, "z": 20.0, "yaw": 90.0, "scale": 1.0}
	var p := SpaceRegistry.prop_point(rec, [1.0, 0.0])
	# +X turned 90 deg about +Y lands on -Z.
	_check("anchor turns with the prop", p.distance_to(Vector2(10.0, 19.0)) < 1e-4, str(p))
	_check("no anchor = the prop's origin", SpaceRegistry.prop_point(rec, null) == Vector2(10.0, 20.0))
