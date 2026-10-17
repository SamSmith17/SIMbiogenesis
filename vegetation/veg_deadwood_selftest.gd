extends SceneTree

## Headless self-test for the Pacific Northwest forest passes (2026-10-15):
## VegMix (the shared brush / preview scatter), VegConiferBuilder (species
## habits, variants, nothing under the ground), VegFloorMoss and trunk moss;
## VegDeadwood (the stump / fallen-log plan and how a log lies on the ground),
## the four PNW species (hemlock, alder, sword fern, blackberry) building real
## meshes, the conifer whorl layout honouring crown base + droop while the
## shipped defaults stay byte-identical, and the VegLookBackup round trip
## (against a coordinate no player has, deleted afterwards).
## Run with (--import first):
##   godot --headless --path . --script vegetation/veg_deadwood_selftest.gd

const EXPECTED_CHECKS := 105

var _failures := 0
var _checks := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _initialize() -> void:
	_test_plan()
	_test_log_lies_on_ground()
	_test_log_mesh()
	_test_species()
	_test_pine_layout()
	_test_backup_round_trip()
	_test_mix_scatter()
	_test_conifer_builder()
	_test_moss()
	_test_broadleaf()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("VEG DEADWOOD SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG DEADWOOD SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _forest(n: int) -> Dictionary:
	var fir: Array = []
	var maple: Array = []
	for i in n:
		var r := {"x": float(i % 40) * 6.3, "z": float(i / 40) * 6.7, "yaw": 0.0, "scale": 1.0}
		if i % 4 == 0:
			maple.append(r)
		else:
			fir.append(r)
	return {"fir": fir, "maple": maple, "sword_fern": [{"x": 1.0, "z": 1.0}],
		"grass_lawn": [{"x": 2.0, "z": 2.0}]}


func _test_plan() -> void:
	var bulk := _forest(2000)
	var off := VegDeadwood.plan([bulk], {})
	_check("deadwood off by default", off.is_empty())
	var s := {VegDeadwood.KEY_DENSITY: 6.0, VegDeadwood.KEY_LOG_SHARE: 0.5,
		VegDeadwood.KEY_MODELS: "stump_a, stump_b"}
	var a := VegDeadwood.plan([bulk], s)
	var b := VegDeadwood.plan([bulk], s)
	_check("plan is deterministic", a == b)
	_check("roughly the asked density", a.size() > 60 and a.size() < 190,
		"%d pieces for 2000 trees at 6/100" % a.size())
	var logs := 0
	var models := {}
	var near_trunk := 0
	for p in a:
		var d: Dictionary = p
		if str(d["kind"]) == "log":
			logs += 1
		else:
			models[str(d["model"])] = true
	_check("both kinds appear", logs > 0 and logs < a.size())
	_check("both stump models used", models.size() == 2)
	# Every piece sits 2.2-6 m off ITS tree, never on the trunk.
	for p in a:
		var d: Dictionary = p
		var off_m := Vector2(float(d["x"]) - float(d["tree_x"]),
			float(d["z"]) - float(d["tree_z"])).length()
		if off_m < 2.1 or off_m > 6.1:
			near_trunk += 1
	_check("every piece 2-6 m off its tree", near_trunk == 0, "%d" % near_trunk)
	var only_logs := VegDeadwood.plan([bulk], {VegDeadwood.KEY_DENSITY: 6.0,
		VegDeadwood.KEY_LOG_SHARE: 0.0})
	var all_logs := true
	for p in only_logs:
		all_logs = all_logs and str((p as Dictionary)["kind"]) == "log"
	_check("no stump models = logs only", all_logs and not only_logs.is_empty())
	var none := VegDeadwood.plan([{"sword_fern": bulk["fir"]}], s)
	_check("understory never gets deadwood", none.is_empty())


func _test_log_lies_on_ground() -> void:
	var flat := func(_x: float, _z: float) -> float: return 5.0
	var d := {"x": 0.0, "z": 0.0, "yaw": 0.0, "length": 8.0, "radius": 0.4}
	var xf: Variant = VegDeadwood.log_transform(d, flat)
	_check("flat log placed", xf is Transform3D)
	if xf is Transform3D:
		var t: Transform3D = xf
		_check("flat log half buried", is_equal_approx(t.origin.y, 5.0 + 0.4 * 0.8),
			"y %.3f" % t.origin.y)
		_check("flat log level", absf(t.basis.x.normalized().y) < 0.001)
		_check("log length", is_equal_approx(t.basis.x.length(), 8.0))
		_check("log radius", is_equal_approx(t.basis.y.length(), 0.4))
	# A 30 % grade along x: the log follows the ground between its ends.
	var slope := func(x: float, _z: float) -> float: return x * 0.3
	var s1: Variant = VegDeadwood.log_transform(d, slope)
	if s1 is Transform3D:
		var a: Vector3 = (s1 as Transform3D).basis.x
		_check("log follows a slope", absf(a.y / Vector2(a.x, a.z).length() - 0.3) < 0.01)
	else:
		_check("log follows a slope", false)
	# A cliff along x: the log turns across the slope (z) and lies level.
	var cliff := func(x: float, _z: float) -> float: return x * 2.0
	var c1: Variant = VegDeadwood.log_transform(d, cliff)
	if c1 is Transform3D:
		var ax: Vector3 = (c1 as Transform3D).basis.x.normalized()
		_check("log on a cliff turns across it", absf(ax.y) < 0.01 and absf(ax.z) > 0.99)
	else:
		_check("log on a cliff turns across it", false)
	var wall := func(x: float, z: float) -> float: return (x + z) * 3.0
	_check("no orientation fits -> no log", VegDeadwood.log_transform(d, wall) == null)
	_check("right-handed log basis", (VegDeadwood.log_transform(d, flat) as Transform3D).basis.determinant() > 0.0)


func _test_log_mesh() -> void:
	var m := VegDeadwood.log_mesh()
	_check("log mesh built", m != null and m.get_surface_count() == 1)
	var box := m.get_aabb()
	_check("unit log along +X", is_equal_approx(box.size.x, 1.0) and box.size.y <= 2.001
		and box.size.y > 1.9)


func _test_species() -> void:
	for sp in ["hemlock", "alder", "sword_fern", "blackberry"]:
		_check("%s paintable" % sp, VegSpeciesCatalog.is_paintable(sp))
	_check("hemlock is a conifer", VegSpeciesCatalog.mesh_family("hemlock") == "pine")
	_check("alder is broadleaf", VegSpeciesCatalog.mesh_family("alder") == "deciduous")
	_check("fern rides the palm builder", VegSpeciesCatalog.mesh_family("sword_fern") == "palm")
	_check("blackberry is a shrub", VegSpeciesCatalog.mesh_family("blackberry") == "shrub")
	var st: Dictionary = VegetationStyleConfig.defaults()
	var fern := VegetationCardFactory.mesh_for_species("sword_fern",
		VegSpeciesCatalog.settings_with_variant("sword_fern", st, VegetationCardFactory.SPECS))
	_check("fern mesh built", fern != null and fern.get_surface_count() == 2)
	if fern != null:
		var fb := fern.get_aabb()
		_check("fern fronds stay above ground", fb.position.y > -0.02, "min y %.3f" % fb.position.y)
		_check("fern is knee high", fb.end.y > 0.4 and fb.end.y < 1.4, "top %.2f" % fb.end.y)
	var bb := VegetationCardFactory.mesh_for_species("blackberry",
		VegSpeciesCatalog.settings_with_variant("blackberry", st, VegetationCardFactory.SPECS))
	_check("blackberry mesh built", bb != null)
	_check("understory has a short draw distance",
		VegetationRuntime._visibility_end_for_species("sword_fern") < 400.0
		and VegetationRuntime._visibility_end_for_species("fir") > 400.0)
	_check("fern is evergreen", VegSpeciesRegistry.deciduousness_for("sword_fern") < 0.2)


func _test_pine_layout() -> void:
	var base := VegetationCardFactory._pine_cluster_layout(7.0, 17.0, {})
	var same := VegetationCardFactory._pine_cluster_layout(7.0, 17.0,
		{"_pine_crown_base": 0.08, "_pine_droop": 0.12})
	_check("default crown base + droop = the old layout", base == same)
	var tall := VegetationCardFactory._pine_cluster_layout(7.0, 17.0,
		{"_pine_crown_base": 0.45})
	_check("crown base lifts the lowest whorl",
		float((tall[0]["pos"] as Vector3).y) > 0.44 * 17.0)
	var weep := VegetationCardFactory._pine_cluster_layout(7.0, 17.0, {"_pine_droop": 0.7})
	_check("droop hangs the boughs longer", float(weep[0]["h"]) > float(base[0]["h"]))


func _test_backup_round_trip() -> void:
	# A coordinate nobody plays: every file this touches is deleted again.
	var lat := -89.4321
	var lon := 179.4321
	var files := VegLookBackup.site_files(lat, lon)
	var style_path := str(files["style"])
	var painted_path := str(files["painted"])
	for k in files:
		if FileAccess.file_exists(str(files[k])):
			DirAccess.remove_absolute(str(files[k]))
	DirAccess.make_dir_recursive_absolute(style_path.get_base_dir())
	_write(style_path, "{\"look\": 1}")
	var dir := VegLookBackup.snapshot(lat, lon, "Test look")
	_check("snapshot written", not dir.is_empty())
	_write(style_path, "{\"look\": 2}")
	_write(painted_path, "{\"new\": true}")
	_check("snapshot listed", VegLookBackup.list(lat, lon).size() >= 1)
	_check("restore ok", VegLookBackup.restore(lat, lon, dir))
	_check("style back as it was", _read(style_path) == "{\"look\": 1}")
	_check("file absent at snapshot time removed", not FileAccess.file_exists(painted_path))
	# Clean up everything this test made.
	for k in files:
		if FileAccess.file_exists(str(files[k])):
			DirAccess.remove_absolute(str(files[k]))
	for b in VegLookBackup.list(lat, lon):
		var d := str((b as Dictionary)["dir"])
		var da := DirAccess.open(d)
		if da != null:
			for fn in da.get_files():
				DirAccess.remove_absolute("%s/%s" % [d, fn])
		DirAccess.remove_absolute(d)
	DirAccess.remove_absolute(VegLookBackup.world_dir(lat, lon))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _test_mix_scatter() -> void:
	var poly := VegetationPaint.circle_polygon(Vector2(500.0, -300.0), 90.0, 40)
	var mix := VegMix.preset("pnw_lowland")
	_check("PNW preset exists", not mix.is_empty() and (mix["trees"] as Dictionary).has("douglas_fir"))
	var a := VegMix.scatter(poly, mix, 99, {})
	var b := VegMix.scatter(poly, mix, 99, {})
	_check("mix scatter deterministic (the preview IS the brush)", a == b and not a.is_empty())
	var trees := 0
	var under := 0
	var counts := {}
	var young := 0
	for it in a:
		var d: Dictionary = it
		if bool(d["understory"]):
			under += 1
		else:
			trees += 1
			counts[d["species"]] = int(counts.get(d["species"], 0)) + 1
			if bool(d["young"]):
				young += 1
	_check("every canopy species appears", counts.size() == (mix["trees"] as Dictionary).size(),
		str(counts))
	var df_share := float(counts.get("douglas_fir", 0)) / float(maxi(trees, 1))
	_check("Douglas-fir about its weight", df_share > 0.25 and df_share < 0.6, "%.2f" % df_share)
	_check("young share honoured", absf(float(young) / float(maxi(trees, 1)) - 0.25) < 0.1)
	_check("understory about its rate per tree",
		float(under) / float(maxi(trees, 1)) > 1.4 and float(under) / float(maxi(trees, 1)) < 2.9,
		"%.2f" % (float(under) / float(maxi(trees, 1))))
	var even := mix.duplicate(true)
	even["patchiness"] = 0.0
	even["young_share"] = 0.0
	even["understory"] = {}
	var big := VegMix.scatter(poly, even, 5, {"scale": 2.0, "size_var": 0.0})
	var all_two := true
	for it in big:
		all_two = all_two and absf(float((it as Dictionary)["scale"]) - 2.0) < 1e-4
	_check("plant scale multiplies every tree", all_two and not big.is_empty())
	var dense := VegMix.scatter(poly, even, 5, {"density": 2.0})
	_check("density 2 packs more trees", dense.size() > big.size() * 2)
	# Patchiness: neighbours agree on species more often than chance.
	var patchy := mix.duplicate(true)
	patchy["patchiness"] = 1.0
	patchy["understory"] = {}
	var pa := VegMix.scatter(poly, patchy, 7, {})
	_check("patchiness clusters species", _neighbour_agreement(pa) > _neighbour_agreement(
		VegMix.scatter(poly, even, 7, {})) + 0.05)
	_check("understory sits round its tree", _max_understory_ring(a) <= 5.5 + 0.01)


func _neighbour_agreement(items: Array) -> float:
	var same := 0
	var n := 0
	for i in items.size():
		var a: Dictionary = items[i]
		var best := -1
		var bd := INF
		for j in items.size():
			if i == j:
				continue
			var b: Dictionary = items[j]
			var d := Vector2(float(a["x"]) - float(b["x"]), float(a["z"]) - float(b["z"])).length()
			if d < bd:
				bd = d
				best = j
		if best >= 0:
			n += 1
			if str((items[best] as Dictionary)["species"]) == str(a["species"]):
				same += 1
	return float(same) / float(maxi(n, 1))


func _max_understory_ring(items: Array) -> float:
	var worst := 0.0
	var last_tree := Vector2.ZERO
	for it in items:
		var d: Dictionary = it
		var p := Vector2(float(d["x"]), float(d["z"]))
		if not bool(d["understory"]):
			last_tree = p
		else:
			worst = maxf(worst, p.distance_to(last_tree))
	return worst


func _test_conifer_builder() -> void:
	var st: Dictionary = VegetationStyleConfig.defaults()
	var shapes := {}
	for sid in ["douglas_fir", "cedar", "hemlock", "spruce", "fir", "pine", "redwood"]:
		var s := VegSpeciesCatalog.settings_with_variant(sid, st, VegetationCardFactory.SPECS)
		var m := VegetationCardFactory.mesh_for_canopy_lod(sid, s,
			VegetationCardFactory.CanopyLodTier.NEAR)
		var ok := m != null and m.get_surface_count() == 2
		var box := m.get_aabb() if m != null else AABB()
		_check("%s: trunk + sprays" % sid, ok)
		_check("%s: exact height, nothing under the ground" % sid,
			absf(box.size.y - float(s.get("pine_height_m", 0.0))) < 0.05
			and box.position.y > -0.05, "%s" % str(box))
		shapes[sid] = box.size.x / maxf(box.size.y, 0.01)
		var s1 := s.duplicate()
		s1["pine_variant_index"] = 1
		var m1 := VegetationCardFactory.mesh_for_canopy_lod(sid, s1,
			VegetationCardFactory.CanopyLodTier.NEAR)
		var v0: PackedVector3Array = m.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
		var v1: PackedVector3Array = m1.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
		_check("%s: variants differ" % sid, v0 != v1)
	_check("cedar broader than true fir", float(shapes["cedar"]) > float(shapes["fir"]) * 1.2)
	var legacy := VegSpeciesCatalog.settings_with_variant("pine", st, VegetationCardFactory.SPECS)
	legacy["pine_builder"] = "whorl"
	var lm := VegetationCardFactory.mesh_for_canopy_lod("pine", legacy,
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("legacy whorl builder still reachable", lm != null and lm.get_surface_count() == 2)
	_check("conifer forms exist for every PNW conifer",
		VegConiferBuilder.FORMS.has("douglas_fir") and VegConiferBuilder.FORMS.has("hemlock"))


## The broadleaf rebuild: leaf sprays on the twigs, per-species habit,
## per-species autumn, the cutout mip chain, the shells fallback, oak.
func _test_broadleaf() -> void:
	var st: Dictionary = VegetationStyleConfig.defaults()
	var specs := VegetationCardFactory.SPECS
	for sid in ["maple", "alder", "oak", "birch", "aspen", "cottonwood", "beech"]:
		var s := VegSpeciesCatalog.settings_with_variant(sid, st, specs)
		var m := VegetationCardFactory.mesh_for_canopy_lod(sid, s,
			VegetationCardFactory.CanopyLodTier.NEAR)
		var mat := m.surface_get_material(1) as ShaderMaterial if m.get_surface_count() > 1 else null
		_check("%s: bark + leaf sprays" % sid, m.get_surface_count() == 2 and mat != null
			and bool(mat.get_shader_parameter("spray_mode")))
		var h := float(specs[sid]["height_m"])
		var floor_y := h * float(specs[sid]["crown_base_pct"]) / 100.0
		var low := INF
		for v in (m.surface_get_arrays(1)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			low = minf(low, v.y)
		_check("%s: exact height, no leaves under the crown base" % sid,
			absf(m.get_aabb().size.y - h) < 0.05 and low >= floor_y - 0.8,
			"h %.2f low %.2f floor %.2f" % [m.get_aabb().size.y, low, floor_y])
	var missing: Array = []
	for sid in VegSpeciesCatalog.DECIDUOUS_IDS:
		if not VegBroadleafBuilder.FORMS.has(sid) and sid != "deciduous":
			missing.append(sid)
	_check("every broadleaf species has a leaf form", missing.is_empty(), str(missing))
	var sp := func(sid: String, extra: Dictionary = {}) -> Dictionary:
		var s := VegSpeciesCatalog.settings_with_variant(sid, st, specs)
		s.merge(extra, true)
		return VegetationCardFactory._deciduous_spec(s, sid)
	var birch: Dictionary = sp.call("birch")
	var oak: Dictionary = sp.call("oak")
	var alder: Dictionary = sp.call("alder")
	_check("birch droops more than oak",
		float(birch["sc_droop"]) > float(oak["sc_droop"]) + 0.3)
	_check("oak is more crooked than alder",
		float(oak["sc_gnarl"]) > float(alder["sc_gnarl"]) + 0.3)
	var shifted: Dictionary = sp.call("birch", {"deciduous_droop": 0.35})
	_check("a family-wide droop edit shifts the species' own value",
		float(shifted["sc_droop"]) > float(birch["sc_droop"]) + 0.1)
	var pm := VegetationCardFactory.autumn_palette("maple", st)
	var pa := VegetationCardFactory.autumn_palette("alder", st)
	_check("maple and alder turn different colours", pm.size() == 3 and pa.size() == 3
		and not (pm[0] as Color).is_equal_approx(pa[0] as Color))
	_check("maple goes gold, alder stays dull",
		(pm[0] as Color).get_luminance() > (pa[0] as Color).get_luminance() + 0.15)
	# Coverage-preserving cutout mips + colour bleed.
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 64:
		for x in 64:
			if (x / 3 + y / 3) % 4 == 0:
				img.set_pixel(x, y, Color(0.2, 0.5, 0.1, 1.0))
	var out := VegBroadleafBuilder.finalize_cutout(img, 0.4)
	var data := out.get_data()
	var cov := func(level: int, w: int) -> float:
		var off := out.get_mipmap_offset(level)
		var n := 0
		for i in w * w:
			if data[off + i * 4 + 3] > 102:
				n += 1
		return float(n) / float(w * w)
	var c0: float = cov.call(0, 64)
	var c2: float = cov.call(2, 16)
	_check("mips keep the leaf coverage", c2 >= c0 * 0.7, "%.2f vs %.2f" % [c2, c0])
	var bleed := out.get_pixel(4, 0)
	_check("empty texels carry the leaf colour, not black", bleed.a < 0.05 and bleed.g > 0.3)
	var shells := st.duplicate()
	shells[VegetationCardFactory.KEY_LEAF_BUILDER] = "shells"
	var sm := VegetationCardFactory.mesh_for_canopy_lod("maple",
		VegSpeciesCatalog.settings_with_variant("maple", shells, specs),
		VegetationCardFactory.CanopyLodTier.NEAR)
	var smat := sm.surface_get_material(sm.get_surface_count() - 1) as ShaderMaterial
	_check("leaf shells still selectable", smat != null
		and smat.shader == VegetationCardFactory.LEAF_CANOPY_SHADER)
	var s0 := VegSpeciesCatalog.settings_with_variant("maple", st, specs)
	var s1 := s0.duplicate()
	s1["deciduous_variant_index"] = 1
	var a0: PackedVector3Array = VegetationCardFactory.mesh_for_canopy_lod("maple", s0,
		VegetationCardFactory.CanopyLodTier.NEAR).surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	var a1: PackedVector3Array = VegetationCardFactory.mesh_for_canopy_lod("maple", s1,
		VegetationCardFactory.CanopyLodTier.NEAR).surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	_check("broadleaf variants differ", a0 != a1)
	_check("Oregon white oak is a registered broadleaf",
		VegSpeciesCatalog.mesh_family("oak") == "deciduous"
		and "oak" in VegSpeciesCatalog.DECIDUOUS_IDS)


func _test_moss() -> void:
	var bulk := {"douglas_fir": [{"x": 10.0, "z": 5.0}, {"x": 16.0, "z": 9.0}],
		"sword_fern": [{"x": 12.0, "z": 6.0}]}
	var fm := VegFloorMoss.build([bulk])
	_check("floor moss mask built", not fm.is_empty() and fm["tex"] is ImageTexture)
	var rect: Vector4 = fm.get("rect", Vector4.ZERO)
	_check("mask covers the trees", rect.x < 10.0 and rect.y < 5.0
		and rect.x + rect.z > 16.0 and rect.y + rect.z > 9.0)
	_check("no trees, no moss", VegFloorMoss.build([{}]).is_empty())
	var st: Dictionary = VegetationStyleConfig.defaults()
	var s := VegSpeciesCatalog.settings_with_variant("maple", st, VegetationCardFactory.SPECS)
	var off := VegetationCardFactory.bark_material_for_species("deciduous", s)
	_check("trunk moss off by default", float(off.get_shader_parameter("moss_amount")) == 0.0)
	var s2 := s.duplicate()
	s2["bark_moss"] = 0.8
	var on := VegetationCardFactory.bark_material_for_species("deciduous", s2)
	_check("maple wears the trunk moss", float(on.get_shader_parameter("moss_amount")) > 0.7)
