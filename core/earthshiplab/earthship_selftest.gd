extends SceneTree

## Offline checks for the Earthship designer (core/earthshiplab/): spec
## clamps and keys, the solved frame (rooms, walls, glazing line, door),
## the earthworks it asks for, every preset clean, the builder's nodes and
## collision. Run (--import first):
##   Godot --headless --path . --script core/earthshiplab/earthship_selftest.gd

const EXPECTED_CHECKS := 38

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_test_spec()
	_test_frame()
	_test_glazing()
	_test_earthworks()
	_test_presets()
	_test_builder()
	var total := _pass + _fail
	if total != EXPECTED_CHECKS:
		_fail += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [total, EXPECTED_CHECKS])
	print("earthship_selftest: %d passed, %d failed" % [_pass, _fail])
	print("PASS" if _fail == 0 else "FAILED")
	quit(1 if _fail > 0 else 0)


func _ok(c: bool, what: String) -> void:
	if c:
		_pass += 1
	else:
		_fail += 1
		print("FAIL ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f)" % [what, a, b])


func _test_spec() -> void:
	var s := EarthshipSpec.resolve({"modules": 40, "module_w": 0.5, "entry": "upside"})
	_ok(int(s["modules"]) == EarthshipSpec.MAX_MODULES, "modules clamped")
	_ok(float(s["module_w"]) >= 2.0, "room width clamped")
	_ok(str(s["entry"]) == "left", "unknown entry falls back")
	_ok(EarthshipSpec.key_of({"modules": 3}) == EarthshipSpec.key_of({"modules": 3.0}),
		"key ignores int vs float")
	_ok(EarthshipSpec.key_of({"modules": 3}) != EarthshipSpec.key_of({"modules": 4}), "key follows a change")
	_near(EarthshipDesign.glazing_for_lat(33.3), 56.74, 0.01, "glazing angle for the latitude")


func _test_frame() -> void:
	var d := EarthshipDesign.solve({"modules": 3, "module_w": 5.0, "wall_t": 1.0, "module_d": 5.0,
		"floor_depth": 1.0, "wall_h": 2.5, "corridor_d": 3.0})
	var fr: Dictionary = d["frame"]
	_near(float(fr["x1"]) - float(fr["x0"]), 3.0 * 5.0 + 4.0 * 1.0, 1e-5, "row length")
	_near(float(fr["yf"]), -1.0, 1e-6, "floor below grade")
	_near(float(fr["yc"]), 1.5, 1e-6, "ceiling = floor + wall height")
	_ok((d["rooms"] as Array).size() == 3, "a room per module")
	var r0: Dictionary = d["rooms"][0]
	_near(float(r0["x1"]) - float(r0["x0"]), 5.0, 1e-5, "room width")
	_near(float(fr["z_back"]), -6.0, 1e-5, "back wall outside")
	_near(float(fr["z_front"]), 3.0 + EarthshipDesign.KNEE_T, 1e-5, "front kneewall outside")
	_ok(float(d["stats"]["floor_area_m2"]) > 3.0 * 25.0, "floor area counts the greenhouse")
	_ok(int(d["stats"]["tyres"]) > 100, "tyres counted")


func _test_glazing() -> void:
	var d := EarthshipDesign.solve({"glazing_deg": 60.0, "corridor_d": 3.0, "floor_depth": 0.9,
		"wall_h": 2.6, "sill_h": 0.75})
	var fr: Dictionary = d["frame"]
	var rise := float(fr["yt"]) - float(fr["ys"])
	var run := 3.0 - float(fr["zg"])
	_near(rad_to_deg(atan2(rise, run)), 60.0, 0.01, "glazing at its angle")
	_near(float(fr["yt"]), float(fr["yc"]), 1e-5, "glazing meets the ceiling line")
	var flat := EarthshipDesign.solve({"glazing_deg": 35.0, "corridor_d": 1.5})
	_ok(float(flat["frame"]["yt"]) < float(flat["frame"]["yc"]), "a shallow angle on a short corridor stops lower")
	_ok(float(fr["door_z"]) < 3.0 and float(fr["door_z"]) > 0.3, "the doorway is set back inside the glazing")
	var glass := 0
	for p in d["parts"]:
		if (p as Dictionary).has("quad"):
			glass += 1
	_ok(glass >= 3, "glazing bays drawn (%d)" % glass)


func _test_earthworks() -> void:
	var d := EarthshipDesign.solve({"floor_depth": 1.2, "berm_ends": true, "entry": "left"})
	var ew := EarthshipDesign.earthworks({"floor_depth": 1.2, "berm_ends": true, "entry": "left"})
	_ok(bool(ew["hole"]), "the rooms are an opening")
	_near(float(ew["floor_y"]), -1.2, 1e-5, "opening floor = room floor")
	_near(float(ew["roof_y"]), float(d["frame"]["roof"]), 1e-5, "roof line for the berms and rain")
	_ok((ew["berm"] as Dictionary).has("-z") and (ew["berm"] as Dictionary).has("-x"), "bermed back and ends")
	_ok(not (ew["berm"] as Dictionary).has("+z"), "the glazing side is open")
	_ok((ew["cuts"] as Array).size() == 1 and (ew["ramps"] as Array).size() == 1, "a daylight cut and a ramp")
	var ramp: Dictionary = ew["ramps"][0]
	_near(float(ramp["b"][0]), float(d["entry_x"]), 1e-4, "the ramp comes in at the door")
	var no_ramp := EarthshipDesign.earthworks({"ramp": false})
	_ok((no_ramp["ramps"] as Array).is_empty(), "no ramp when asked")


func _test_presets() -> void:
	var all_ok := true
	for b in EarthshipPresets.builtins():
		var d := EarthshipDesign.solve(b["spec"])
		for c in d["checks"]:
			if str(c["level"]) == "error":
				all_ok = false
	_ok(all_ok, "no preset has an error")
	_ok(EarthshipPresets.builtins().size() >= 4, "four presets")
	_ok(int(EarthshipPresets.builtin("phoenix")["modules"]) == 6, "Phoenix preset")
	_ok(bool(EarthshipPresets.builtin("phoenix")["inner_glazing"]), "Phoenix double glazed")


func _test_builder() -> void:
	var n := EarthshipBuilder.build_node(EarthshipPresets.builtin("global_model"))
	var mesh := n.get_node_or_null("Mesh") as MeshInstance3D
	var glass := n.get_node_or_null("Glazing") as MeshInstance3D
	var col := n.get_node_or_null("CollisionMesh") as MeshInstance3D
	_ok(mesh != null and mesh.mesh.get_surface_count() >= 5, "a surface per material")
	_ok(bool(mesh.get_meta("skip_prop_collision", false)), "drawn mesh skipped for collision")
	_ok(glass != null and glass.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "glass casts no shadow")
	_ok(col != null and not col.visible and col.mesh.get_surface_count() == 1, "hidden collision mesh")
	var spots: Array = n.get_meta("seat_spots", [])
	_ok(spots.size() == 3, "a bed per room")
	var size: Vector3 = n.get_meta("size_m", Vector3.ZERO)
	_ok(size.x > 15.0 and size.z > 8.0, "size meta")
	n.free()
