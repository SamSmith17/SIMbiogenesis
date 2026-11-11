extends SceneTree

## Offline checks for the Earthship designer (core/earthshiplab/): spec
## clamps and keys, the solved frame (rooms, walls, glazing line, door),
## the earthworks it asks for, every preset clean, the builder's nodes and
## collision. Run (--import first):
##   Godot --headless --path . --script core/earthshiplab/earthship_selftest.gd

const EXPECTED_CHECKS := 58

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_test_spec()
	_test_frame()
	_test_glazing()
	_test_earthworks()
	_test_presets()
	_test_builder()
	_test_look()
	_test_variants()
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
	var d := EarthshipDesign.solve({"floor_depth": 1.2, "berm_ends": true, "entry": "left", "bottle_ends": false})
	var ew := EarthshipDesign.earthworks({"floor_depth": 1.2, "berm_ends": true, "entry": "left", "bottle_ends": false})
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
	_ok(EarthshipPresets.builtins().size() >= 6, "six presets")
	var looks := {}
	for b2 in EarthshipPresets.builtins():
		var r := EarthshipSpec.resolve(b2["spec"])
		looks["%s|%s|%s|%s" % [r["glazing_style"], r["room_front"], r["entry_style"], r["bottle_pattern"]]] = true
	_ok(looks.size() == EarthshipPresets.builtins().size(), "every preset looks different (%d)" % looks.size())
	_ok(int(EarthshipPresets.builtin("phoenix")["modules"]) == 6, "Phoenix preset")
	_ok(bool(EarthshipPresets.builtin("phoenix")["inner_glazing"]), "Phoenix double glazed")


func _test_builder() -> void:
	var n := EarthshipBuilder.build_node(EarthshipPresets.builtin("global_model"))
	var mesh := n.get_node_or_null("Mesh") as MeshInstance3D
	var glass := n.get_node_or_null("Glazing") as MeshInstance3D
	var col := n.get_node_or_null("CollisionMesh") as MeshInstance3D
	_ok(mesh != null and mesh.mesh.get_surface_count() >= 8, "a surface per material")
	_ok(bool(mesh.get_meta("skip_prop_collision", false)), "drawn mesh skipped for collision")
	_ok(glass != null and glass.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "glass casts no shadow")
	_ok(col != null and not col.visible and col.mesh.get_surface_count() == 1, "hidden collision mesh")
	var spots: Array = n.get_meta("seat_spots", [])
	_ok(spots.size() == 3, "a bed per room")
	var size: Vector3 = n.get_meta("size_m", Vector3.ZERO)
	_ok(size.x > 15.0 and size.z > 8.0, "size meta")
	n.free()


## The look pass (2026-11-11): vigas run front to back, the glass is see
## through, bottles go through real holes, the beds are planted.
func _test_look() -> void:
	var d := EarthshipDesign.solve(EarthshipPresets.builtin("muro_di_gomme"))
	var along_z := 0
	var other := 0
	for p in d["parts"]:
		var part: Dictionary = p
		if part.has("cyl") and str(part["mat"]) == "viga":
			var c: Array = part["cyl"]
			var ax: Vector3 = (c[1] as Vector3) - (c[0] as Vector3)
			if absf(ax.z) > 0.99 * ax.length():
				along_z += 1
			else:
				other += 1
	_ok(along_z > 20 and other == 0, "vigas span front to back (%d, %d otherwise)" % [along_z, other])
	_ok(int(d["stats"]["vigas"]) == along_z, "vigas counted")
	var glass := EarthshipBuilder.material_for("glass", d["spec"]) as StandardMaterial3D
	_ok(glass != null and glass.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and glass.albedo_color.a < 0.4,
		"glass is see-through")
	_ok(int(d["stats"]["bottles"]) > 100, "bottle walls have bottles (%d)" % int(d["stats"]["bottles"]))
	var n := EarthshipBuilder.build_from_design(d)
	var bot := n.get_node_or_null("Bottles") as MeshInstance3D
	_ok(bot != null and bot.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "bottle glass casts no shadow")
	_ok(int(n.get_meta("bottles", 0)) == int(d["stats"]["bottles"]), "every bottle drawn")
	var plants := n.get_node_or_null("Plants")
	_ok(plants != null and int(plants.get_meta("plants", 0)) > 10, "the beds are planted")
	# A bottle's hole: no plaster face covers its middle.
	var panel: Dictionary = {}
	for p2 in d["parts"]:
		if (p2 as Dictionary).has("panel") and not ((p2 as Dictionary)["holes"] as Dictionary).is_empty():
			panel = p2
			break
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bst := SurfaceTool.new()
	bst.begin(Mesh.PRIMITIVE_TRIANGLES)
	EarthshipBuilder.emit_panel(st, bst, null, panel)
	var arr := st.commit().surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var key: Vector2i = (panel["holes"] as Dictionary).keys()[0]
	var cell := float(panel["cell"])
	var go: Vector2 = panel["grid_o"]
	var cuv := go + Vector2(float(key.x) + 0.5, float(key.y) + 0.5) * cell
	var o: Vector3 = panel["o"]
	var u: Vector3 = panel["u"]
	var v: Vector3 = panel["v"]
	var w: Vector3 = panel["w"]
	var hole_pt := o + u * cuv.x + v * cuv.y
	var covered := false
	for k in range(0, verts.size(), 3):
		var a := verts[k]
		if absf((a - hole_pt).dot(w)) > 1e-4:
			continue
		var b := verts[k + 1]
		var c2 := verts[k + 2]
		var a2 := Vector2((a - o).dot(u), (a - o).dot(v))
		var b2 := Vector2((b - o).dot(u), (b - o).dot(v))
		var c3 := Vector2((c2 - o).dot(u), (c2 - o).dot(v))
		if Geometry2D.point_is_inside_triangle(cuv, a2, b2, c3):
			covered = true
	_ok(not covered, "a bottle's hole goes through the plaster")
	# Faces wound to their normals (Godot's front face is clockwise).
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var bad := 0
	for k2 in range(0, verts.size(), 3):
		if (verts[k2 + 1] - verts[k2]).cross(verts[k2 + 2] - verts[k2]).dot(norms[k2]) > 1e-9:
			bad += 1
	_ok(bad == 0, "panel triangles wound to their normals (%d wrong)" % bad)
	n.free()


func _test_variants() -> void:
	var base := {"modules": 3}
	for style in EarthshipSpec.GLAZING_STYLES:
		for front in EarthshipSpec.ROOM_FRONTS:
			for entry in EarthshipSpec.ENTRY_STYLES:
				var sp := base.duplicate()
				sp["glazing_style"] = style
				sp["room_front"] = front
				sp["entry_style"] = entry
				var d := EarthshipDesign.solve(sp)
				if (d["parts"] as Array).size() < 40:
					_ok(false, "%s/%s/%s solves" % [style, front, entry])
					return
	_ok(true, "every front, room front and entry solves")
	var vest := EarthshipDesign.solve({"entry_style": "vestibule", "entry": "centre"})
	_ok(float(vest["frame"]["door_z"]) > float(vest["frame"]["z_front"]), "a vestibule's door stands out front")
	_ok(float(vest["earthworks_simple"]["cut_w"]) >= EarthshipDesign.VEST_D + 1.0, "the cut fits the vestibule")
	var sweeps := 0
	for p in vest["parts"]:
		if (p as Dictionary).has("sweep"):
			sweeps += 1
	_ok(sweeps == 2, "two curved wing walls")
	var up := EarthshipDesign.solve({"glazing_style": "vertical"})
	_near(float(up["frame"]["zg"]), float(up["spec"]["corridor_d"]), 1e-5, "upright windows stand at the kneewall")
	var pv := EarthshipDesign.solve({"pv_panels": 8, "pv_watts": 400.0})
	_near(float(pv["stats"]["pv_kw"]), 3.2, 1e-5, "solar kW from the panels")
	var old := EarthshipSpec.resolve({"inner_glazing": true})
	_ok(str(old["room_front"]) == "glass", "an old design's inner glazing becomes glass room fronts")
	var ends := EarthshipDesign.earthworks({"bottle_ends": true, "berm_ends": true})
	_ok(not (ends["berm"] as Dictionary).has("-x"), "bottle ends are not buried")
	var cut := EarthshipBuilder.build_node(EarthshipPresets.builtin("global_model"), "E", {"cutaway": true})
	var full := EarthshipBuilder.build_node(EarthshipPresets.builtin("global_model"), "E")
	var cm := (cut.get_node("Mesh") as MeshInstance3D).mesh
	var fm := (full.get_node("Mesh") as MeshInstance3D).mesh
	_ok(_tri_count(cm) < _tri_count(fm), "roof off leaves the roofs out")
	cut.free()
	full.free()
	var pl := EarthshipPlants.scatter([{"x0": 0.0, "x1": 6.0, "z0": 0.0, "z1": 0.8, "y": 0.0,
		"head0": 0.8, "head1": 0.8}], "tropical", 3)
	var tallest := 0.0
	for id in pl.keys():
		for xf in pl[id]:
			tallest = maxf(tallest, EarthshipPlants.height(str(id)) * (xf as Transform3D).basis.get_scale().y)
	_ok(tallest <= 0.81, "plants fit under the glass (%.2f m)" % tallest)


func _tri_count(m: Mesh) -> int:
	var t := 0
	for i in m.get_surface_count():
		t += (m.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t
