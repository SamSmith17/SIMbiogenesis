extends SceneTree

## Greenhouse designer self-test (offline):
##   Godot --headless --path . --script core/greenhouselab/greenhouselab_selftest.gd
## The spec (clamps, mixes, JSON round trip, key stability), the glazing
## table's angle falloff, every form's frame (profile heights, volumes and
## face areas by hand, outward normals, the lean-to's opaque back, earth
## below grade and under a berm, the dome from DomeLab), the bed layout
## (inside the floor, no overlaps, paths, barrels, keyholes, headroom and
## gantry checks), the design's stats / bill / packed form and the presets.

const EXPECTED_CHECKS := 89

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.4f vs %.4f)" % [what, a, b])


func _initialize() -> void:
	_test_spec()
	_test_materials()
	_test_gable()
	_test_curves()
	_test_lean_to_and_ground()
	_test_dome()
	_test_beds()
	_test_design_and_presets()
	_test_builder()
	if _n != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
		_fails += 1
	print("GREENHOUSELAB SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_spec() -> void:
	var s := GreenhouseSpec.resolve({"form": "nonsense", "width_m": 900.0, "eave_h_m": 3.0, "ridge_h_m": 1.0})
	_ok(str(s["form"]) == "hoop", "an unknown form falls back to a hoop house")
	_near(float(s["width_m"]), GreenhouseSpec.MAX_W, 1e-6, "width clamped")
	_ok(float(s["ridge_h_m"]) >= float(s["eave_h_m"]) + 0.3, "the ridge stays above the eaves")
	var mix: Variant = GreenhouseSpec.clean_mix([{"crop": "tomato", "share": 3.0}, {"crop": "lettuce", "share": 1.0}, {"crop": "nope"}])
	_ok(mix is Array and (mix as Array).size() == 2, "unknown crops dropped from a mix")
	_near(float((mix as Array)[0]["share"]), 0.75, 1e-6, "mix shares normalised")
	_ok(str(GreenhouseSpec.clean_mix("??")) == "garden", "a bad mix becomes the garden rotation")
	var c := GreenhouseSpec.resolve({"control": {"vent_open_c": 30.0, "vent_full_c": 20.0}})
	_ok(float(c["control"]["vent_full_c"]) > float(c["control"]["vent_open_c"]), "vents fully open above where they start")
	var js := GreenhouseSpec.to_json_safe(GreenhouseSpec.default_spec("gable"))
	var back: Variant = JSON.parse_string(JSON.stringify(js))
	_ok(GreenhouseSpec.key_of(back as Dictionary) == GreenhouseSpec.key_of(js), "the key survives a JSON round trip")
	var renamed := js.duplicate(true)
	renamed["name"] = "Another name"
	_ok(GreenhouseSpec.key_of(renamed) == GreenhouseSpec.key_of(js), "the name is not part of the key")
	var dome := GreenhouseSpec.resolve({"form": "dome", "width_m": 12.0, "length_m": 30.0})
	_near(float(dome["length_m"]), 12.0, 1e-6, "a dome is as long as it is wide")


func _test_materials() -> void:
	var g := GreenhouseMaterials.glazing("glass_single")
	_near(GreenhouseMaterials.tau_at(g, 0.0), float(g["tau"]), 1e-6, "beam transmittance at normal incidence")
	_ok(GreenhouseMaterials.tau_at(g, 60.0) < GreenhouseMaterials.tau_at(g, 30.0) and GreenhouseMaterials.tau_at(g, 80.0) < GreenhouseMaterials.tau_at(g, 60.0),
		"transmittance falls off at grazing angles")
	_ok(GreenhouseMaterials.tau_at(g, 30.0) > 0.97 * float(g["tau"]), "barely any loss at 30 degrees")
	var ok := true
	for id in GreenhouseMaterials.GLAZING_ORDER:
		var gg := GreenhouseMaterials.glazing(id)
		if not (float(gg["tau"]) > float(gg["tau_diffuse"]) and float(gg["u"]) > 0.0 and float(gg["tau_lw"]) <= 1.0):
			ok = false
	_ok(ok, "every glazing: diffuse below beam transmittance, a U-value")
	_ok(float(GreenhouseMaterials.glazing("poly_single")["tau_lw"]) > 0.5 and float(GreenhouseMaterials.glazing("pc_twin_8")["tau_lw"]) < 0.05,
		"poly passes thermal IR, polycarbonate does not")


func _test_gable() -> void:
	var s := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "glazing": {"roof": "pc_twin_8", "walls": "pc_twin_8", "ends": "pc_twin_8"}})
	var fr := GreenhouseFrame.solve(s)
	var prof: PackedVector2Array = fr["profile"]
	_near(GreenhouseFrame.height_at(prof, 0.0), 3.6, 1e-6, "gable height at the ridge")
	_near(GreenhouseFrame.height_at(prof, 1.5), 2.9, 1e-6, "gable height halfway down the roof")
	_near(float(fr["volume_m3"]), (6.0 * 2.2 + 0.5 * 6.0 * 1.4) * 12.0, 1e-4, "gable volume by hand")
	var walls := 0.0
	var roofs := 0.0
	var out_ok := true
	for f in fr["faces"]:
		var fd: Dictionary = f
		if str(fd["kind"]) == "wall":
			walls += float(fd["area"])
		elif str(fd["kind"]) == "roof":
			roofs += float(fd["area"])
		if str(fd["kind"]) in ["wall", "roof"]:
			var c: Vector3 = fd["centre"]
			if (fd["normal"] as Vector3).dot(c - Vector3(0.0, 1.0, 0.0)) <= 0.0:
				out_ok = false
	_near(walls, 2.0 * 2.2 * 12.0, 1e-4, "two side walls")
	_near(roofs, 2.0 * sqrt(9.0 + 1.96) * 12.0, 1e-4, "two roof slopes")
	_ok(out_ok, "every wall and roof face points out")
	_ok(int(fr["bays"]) == 10 and (fr["ribs"] as Array).size() == 11, "a rib every 1.2 m bay")
	_ok((fr["doors"] as Array).size() == 2, "a door in each end")


func _test_curves() -> void:
	var h := GreenhouseSpec.resolve({"form": "hoop", "width_m": 6.0, "eave_h_m": 1.0, "ridge_h_m": 3.4})
	var ph: PackedVector2Array = GreenhouseFrame.profile(h)
	_near(GreenhouseFrame.height_at(ph, 0.0), 3.4, 0.02, "hoop at its ridge")
	_near(GreenhouseFrame.height_at(ph, 2.95), 1.0 + 2.4 * sqrt(1.0 - pow(2.95 / 3.0, 2.0)), 0.06, "hoop near its wall on the half ellipse")
	var g := GreenhouseSpec.resolve({"form": "gothic", "width_m": 9.0, "eave_h_m": 1.5, "ridge_h_m": 4.6})
	var pg: PackedVector2Array = GreenhouseFrame.profile(g)
	_near(GreenhouseFrame.height_at(pg, 0.0), 4.6, 1e-4, "gothic arch meets at the ridge")
	var ga := GreenhouseFrame.gothic_arc(4.5, 3.1, 1.5)
	var on := true
	for k in range(2, 12):
		if absf(((pg[k] as Vector2) - (ga["c"] as Vector2)).length() - float(ga["r"])) > 1e-3:
			on = false
	_ok(on, "the arc's points sit on its circle")
	_near(((Vector2(-4.5, 1.5)) - (ga["c"] as Vector2)).length(), float(ga["r"]), 1e-4, "the arc starts at the wall top")
	var n := pg.size()
	_ok(pg[n / 2 - 1].y < 4.6 and pg[n / 2 + 1].y < 4.6 and absf(pg[n / 2].y - 4.6) < 1e-4, "the two arcs meet in a point at the ridge")
	var dh := GreenhouseFrame.height_at(pg, 1.0) - GreenhouseFrame.height_at(GreenhouseFrame.profile(GreenhouseSpec.resolve(
		{"form": "hoop", "width_m": 9.0, "eave_h_m": 1.5, "ridge_h_m": 4.6})), 1.0)
	_ok(dh < 0.0, "a gothic arch is lower than a round hoop off the centre line")
	_near(GreenhouseFrame.profile_area(ph), 6.0 * 1.0 + PI * 3.0 * 2.4 * 0.5, 0.15, "hoop section area ≈ wall band + half ellipse")


func _test_lean_to_and_ground() -> void:
	var s := GreenhouseSpec.default_spec("lean_to")
	var fr := GreenhouseFrame.solve(s)
	var back := {}
	var roof := {}
	for f in fr["faces"]:
		var fd: Dictionary = f
		if str(fd["kind"]) == "back":
			back = fd
		if str(fd["kind"]) == "roof":
			roof = fd
	_ok(not back.is_empty() and not bool(back["glazed"]), "the lean-to's back wall is opaque")
	_ok((back["normal"] as Vector3).z < -0.9, "the back wall faces north (-Z)")
	_ok((roof["normal"] as Vector3).z > 0.3 and (roof["normal"] as Vector3).y > 0.3, "the roof glazing faces up and south")
	_ok(GreenhouseDesign.facing_of(roof["normal"]) in ["south", "up"], "the roof reads as south or up")
	var sunk := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 10.0, "eave_h_m": 2.0,
		"ridge_h_m": 3.4, "ground": {"sink_m": 1.0}})
	var fs := GreenhouseFrame.solve(sunk)
	var earth := 0.0
	var deepest := 0.0
	for f in fs["faces"]:
		var fd2: Dictionary = f
		if str(fd2["kind"]) == "earth":
			earth += float(fd2["area"])
			deepest = maxf(deepest, float(fd2["depth_m"]))
	_near(earth, 2.0 * 1.0 * 10.0 + 2.0 * 1.0 * 6.0, 1e-4, "earth walls below grade: sides and ends")
	_near(deepest, 0.5, 1e-4, "a 1 m deep wall's middle is half a metre down")
	var bermed := GreenhouseFrame.solve(GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 10.0,
		"eave_h_m": 2.0, "ridge_h_m": 3.4, "ground": {"berm": "north"}}))
	var north_glass := 0.0
	var north_earth := 0.0
	for f in bermed["faces"]:
		var fd3: Dictionary = f
		if (fd3["normal"] as Vector3).z < -0.9:
			if str(fd3["kind"]) == "earth":
				north_earth += float(fd3["area"])
			elif bool(fd3["glazed"]):
				north_glass += float(fd3["area"])
	_near(north_earth, 20.0, 1e-4, "a north berm covers the north wall to the eave")
	_near(north_glass, 0.0, 1e-4, "no glazing left on the bermed north wall")


func _test_dome() -> void:
	var s := GreenhouseSpec.resolve({"form": "dome", "width_m": 10.0, "dome": {"frequency": 4, "fraction": 0.625}})
	var fr := GreenhouseFrame.solve(s)
	var dd := DomeLabDesign.solve(GreenhouseFrame.dome_spec(s))
	_ok((fr["faces"] as Array).size() == (dd["geo"]["faces"] as Array).size(), "one face per dome panel")
	_near(float(fr["floor_area_m2"]), float(dd["stats"]["floor_area_m2"]), 1e-6, "the dome's floor area")
	var area := 0.0
	var out_ok := true
	var c0 := Vector3(0.0, float(fr["dome"]["height_m"]) - 5.0, 0.0)
	for f in fr["faces"]:
		area += float(f["area"])
		if (f["normal"] as Vector3).dot((f["centre"] as Vector3) - c0) <= 0.0:
			out_ok = false
	_near(area, float(dd["stats"]["surface_m2"]), 0.01, "the dome's faces add up to its surface")
	_ok(out_ok, "every dome face points out")
	_near(GreenhouseFrame.height_at_xz(fr, 0.0, 0.0), float(fr["dome"]["height_m"]), 1e-4, "dome height at the middle")
	_ok(GreenhouseFrame.height_at_xz(fr, 4.0, 0.0) < GreenhouseFrame.height_at_xz(fr, 2.0, 0.0), "lower toward the edge")


func _test_beds() -> void:
	var s := GreenhouseSpec.resolve({"form": "hoop", "width_m": 9.1, "length_m": 29.3, "eave_h_m": 1.5,
		"ridge_h_m": 4.3, "beds": {"bed_w_m": 0.76, "path_w_m": 0.45}})
	var fr := GreenhouseFrame.solve(s)
	var lay := GreenhouseBeds.layout(s, fr)
	var beds: Array = lay["beds"]
	_ok(beds.size() >= 6, "a 30 ft house takes at least six 30\" beds across")
	var inside := true
	for b in beds:
		var bd: Dictionary = b
		if absf(float(bd["x"])) + float(bd["length_m"]) * 0.5 > 29.3 * 0.5 + 1e-4 \
				or absf(float(bd["z"])) + float(bd["width_m"]) * 0.5 > 9.1 * 0.5 + 1e-4:
			inside = false
	_ok(inside, "every bed inside the walls")
	var gap_ok := true
	for i in beds.size():
		for j in range(i + 1, beds.size()):
			var a: Dictionary = beds[i]
			var b2: Dictionary = beds[j]
			var dz := absf(float(a["z"]) - float(b2["z"])) - (float(a["width_m"]) + float(b2["width_m"])) * 0.5
			var dx := absf(float(a["x"]) - float(b2["x"])) - (float(a["length_m"]) + float(b2["length_m"])) * 0.5
			if dz < 0.45 - 1e-4 and dx < 0.0:
				gap_ok = false
	_ok(gap_ok, "beds are at least a path apart")
	_near(float(lay["bed_area_m2"]), GreenhouseBeds.total_area(beds), 1e-6, "bed area totals")
	# Barrels along the back take a strip from the beds.
	var sb := s.duplicate(true)
	sb["mass"]["barrels"] = 30
	var lb := GreenhouseBeds.layout(sb, fr)
	_ok(int(lb["barrels"]["count"]) == 30 and float(lb["barrels"]["litres"]) == 30.0 * 208.0, "thirty 208 L barrels")
	var back_ok := true
	for p in lb["barrels"]["positions"]:
		if (p as Vector2).y > -9.1 * 0.5 + 0.8:
			back_ok = false
	_ok(back_ok, "the barrels stand along the back wall")
	var nearest := INF
	for b in lb["beds"]:
		nearest = minf(nearest, float(b["z"]) - float(b["width_m"]) * 0.5)
	_ok(nearest >= -9.1 * 0.5 + GreenhouseBeds.BARREL_ROW_W, "no bed on the barrels' strip")
	# A low hoop: tall crops at the wall are flagged.
	var low := GreenhouseSpec.resolve({"form": "hoop", "width_m": 4.0, "length_m": 8.0, "eave_h_m": 0.0, "ridge_h_m": 2.0,
		"beds": {"crops": "tomato"}})
	var ll := GreenhouseBeds.layout(low, GreenhouseFrame.solve(low))
	var flagged := false
	for c in ll["checks"]:
		if str(c["text"]).contains("want"):
			flagged = true
	_ok(flagged, "tomatoes against a low hoop wall are flagged")
	# Gantry beds are cut to a FarmBot track.
	var gs := s.duplicate(true)
	gs["beds"]["gantry"] = true
	var lg := GreenhouseBeds.layout(gs, fr)
	var longest := 0.0
	for b in lg["beds"]:
		longest = maxf(longest, float(b["length_m"]))
	_ok(longest <= GreenhouseBeds.GANTRY_MAX_LEN + 1e-4, "gantry beds no longer than a track")
	# Lights size the LEDs from the target PPFD.
	var ls := s.duplicate(true)
	ls["beds"]["lights"] = true
	var lt := GreenhouseBeds.layout(ls, fr)
	var b0: Dictionary = lt["beds"][0]
	_near(float(b0["light"]["w"]), 200.0 * float(b0["area_m2"]) / GreenhouseMaterials.LED_EFFICACY_UMOL_J, 1e-3,
		"LED watts = PPFD × area / efficacy")
	# A dome gets a keyhole that fits inside it.
	var ds := GreenhouseSpec.resolve({"form": "dome", "width_m": 20.0, "dome": {"frequency": 6}, "mass": {"barrels": 20}})
	var dfr := GreenhouseFrame.solve(ds)
	var dl := GreenhouseBeds.layout(ds, dfr)
	var kb: Dictionary = dl["beds"][0]
	_ok(str(kb["kind"]) == "keyhole" and float(kb["keyhole"]["outer_r"]) < float(dfr["floor"]["r"]), "a dome holds a keyhole inside its floor")
	_ok(float(kb["area_m2"]) > 100.0, "the 20 m dome's keyhole grows over 100 m²")
	var rb := INF
	for p in dl["barrels"]["positions"]:
		rb = minf(rb, (p as Vector2).length())
	_ok(rb > float(kb["keyhole"]["outer_r"]), "dome barrels stand outside the keyhole")


func _test_design_and_presets() -> void:
	var s := GreenhouseSpec.default_spec("hoop")
	var d := GreenhouseDesign.solve(s)
	_ok(GreenhouseDesign.solve(s) == d, "solve is cached")
	var tot := 0.0
	for r in d["bom"]:
		if not bool((r as Dictionary).get("total", false)):
			tot += float(r["usd"])
	_near(GreenhouseDesign.cost_usd(d), tot, 1e-6, "the bill's total is its rows' sum")
	_ok(GreenhouseDesign.cost_usd(d) > 0.0 and GreenhouseDesign.mass_kg(d) > 0.0, "it costs something and weighs something")
	var st: Dictionary = d["stats"]
	_near(float(st["ua_w_k"]) > 0.0, true, 0.0, "a heat-loss coefficient")
	_ok(float(st["glazed_m2"]) > float(st["floor_area_m2"]), "more glazing than floor")
	_ok(float(st["bed_share"]) > 0.4 and float(st["bed_share"]) < 0.9, "beds take a sensible share of the floor")
	var ps := GreenhouseDesign.packed_spec(d)
	_ok(float(ps["mass_kg"]) > 0.0 and float(ps["w_m"]) <= 6.11, "packs into a bundle no longer than a stock length")
	var names := {}
	var all_ok := true
	var faces_ok := true
	for p in GreenhousePresets.builtins():
		var pd := GreenhouseDesign.solve(p["spec"])
		names[str(p["id"])] = true
		for c in pd["checks"]:
			if str(c["level"]) == "error":
				all_ok = false
		if (pd["frame"]["faces"] as Array).is_empty() or (pd["beds"] as Array).is_empty():
			faces_ok = false
	_ok(all_ok, "no built-in has an error")
	_ok(faces_ok, "every built-in has faces and beds")
	_ok(names.size() == GreenhousePresets.builtins().size() and names.has("walipini") and names.has("dome_20m"), "built-ins have unique ids")
	var wal := GreenhouseDesign.solve(GreenhousePresets.builtin("walipini")["spec"])
	_ok(float(wal["stats"]["earth_m2"]) > float(wal["stats"]["glazed_m2"]) * 0.5, "the walipini is mostly earth-sheltered")
	var lean := GreenhouseDesign.solve(GreenhousePresets.builtin("solar_lean_to")["spec"])
	var sf: Dictionary = lean["stats"]["glazed_by_facing"]
	_ok(float(sf["south"]) + float(sf["up"]) > float(sf["north"]) * 5.0, "the solar lean-to's glazing faces the sun")
	var tmp := "user://greenhouselab_selftest_library.json"
	_ok(GreenhousePresets.save_library([{"id": "x", "name": "X", "spec": s}], tmp), "library saves")
	var back := GreenhousePresets.load_library(tmp)
	_ok(back.size() == 1 and GreenhouseSpec.key_of(back[0]["spec"]) == GreenhouseSpec.key_of(s), "library loads the same design")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


func _winding_ok(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for si in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if idx.size() > 0 else v.size()
		for k in range(0, count, 3):
			var i0 := idx[k] if idx.size() > 0 else k
			var i1 := idx[k + 1] if idx.size() > 0 else k + 1
			var i2 := idx[k + 2] if idx.size() > 0 else k + 2
			var cr := (v[i1] - v[i0]).cross(v[i2] - v[i0])
			if cr.length() > 1e-9 and cr.dot(nn[i0]) > 0.0:
				return false
	return true


func _test_builder() -> void:
	var wind_ok := true
	var parts_ok := true
	for p in GreenhousePresets.builtins():
		var n := GreenhouseBuilder.build_node(p["spec"])
		for nm in ["Mesh", "Glazing", "CollisionMesh"]:
			if n.get_node_or_null(nm) == null and not (nm == "Glazing" and str(p["spec"]["form"]) == "dome"):
				parts_ok = false
		var m := n.get_node_or_null("Mesh") as MeshInstance3D
		if m == null or not _winding_ok(m.mesh):
			wind_ok = false
		if n.get_node_or_null("Doors") == null:
			parts_ok = false
		n.free()
	_ok(parts_ok, "every built-in builds its mesh, glazing, doors and collision")
	_ok(wind_ok, "every triangle wound clockwise to its normal (Godot's front face)")
	var s := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "fans": {"count": 2}, "vents": {"ridge": true, "sides": "rollup", "ends": true}})
	var g := GreenhouseBuilder.build_node(s)
	var col := (g.get_node("CollisionMesh") as MeshInstance3D).mesh.get_faces()
	_ok(col.size() > 30, "the collision mesh has the walls and floor")
	var blocked := false
	var from := Vector3(8.0, 1.0, 0.0)
	var to := Vector3(4.0, 1.0, 0.0)
	for k in range(0, col.size(), 3):
		if Geometry3D.segment_intersects_triangle(from, to, col[k], col[k + 1], col[k + 2]) != null:
			blocked = true
	_ok(not blocked, "the doorway in the end wall is open")
	var wall_hit := false
	for k2 in range(0, col.size(), 3):
		if Geometry3D.segment_intersects_triangle(Vector3(0.0, 1.0, 5.0), Vector3(0.0, 1.0, 1.0), col[k2], col[k2 + 1], col[k2 + 2]) != null:
			wall_hit = true
	_ok(wall_hit, "the side wall is solid")
	var vents := g.get_node("Vents")
	_ok(vents.get_child_count() == 5, "a ridge flap, two roll-up sides and a louvre in each end")
	GreenhouseBuilder.set_vents(g, 0.5)
	var side := vents.get_node("Side0").get_node("Curtain") as Node3D
	_near(side.scale.y, 0.5, 1e-6, "a half-open roll-up shows half its curtain")
	var ridge := vents.get_node("Ridge0") as Node3D
	_ok(ridge.basis != Basis.IDENTITY, "the ridge flap opens")
	GreenhouseBuilder.set_vents(g, 0.0)
	_ok((vents.get_node("Ridge0") as Node3D).basis.is_equal_approx(Basis.IDENTITY), "and closes again")
	_ok(g.get_node("Fans").get_child_count() == 2, "two fans in the end wall")
	GreenhouseBuilder.spin_fans(g, 0.7)
	_near((g.get_node("Fans/F0/Blades") as Node3D).rotation.x, 0.7, 1e-6, "fan blades turn")
	g.free()
	var r := GrowLightRack.build_node({"length_m": 6.0, "width_m": 1.2, "hang_m": 1.1})
	_ok(GrowLightRack.bars({"length_m": 6.0, "width_m": 1.2}).size() == 4, "a 1.2 m bed gets four bars")
	_ok(not GrowLightRack.is_lit(r), "lights start off")
	GrowLightRack.set_lit(r, true)
	_ok(GrowLightRack.is_lit(r), "lights turn on")
	_ok(_winding_ok((r.get_node("Bars") as MeshInstance3D).mesh), "light bars wound right")
	r.free()
	_near(GrowBed.layout_area_m2({"layout": "rect", "size_m": [5.0, 1.2]}), 6.0, 1e-6, "a rect grow bed is its size")
	var gb := GrowBed.build_node({"layout": "rect", "size_m": [5.0, 1.2], "crops": ["lettuce", "kale"], "wall_h": 0.3})
	_ok(gb.get_child_count() >= 2, "a rect grow bed builds its frame and crops")
	gb.free()
