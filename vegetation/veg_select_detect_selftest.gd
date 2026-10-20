extends SceneTree

## Headless self-test for the V toolbar's per-tree Select and imagery Detect:
##  - the per-tree look (VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE) is the
##    strongest resolution layer, idempotent, a no-op when absent;
##  - a MAP-scope species override (KEY_MAP_SPECIES) makes a generic species'
##    entry beat that map's family edits, and only then;
##  - VegStyleStore map species writes / key removal round-trip on a TEMP path;
##  - painted records keep a per-tree look (incl. colours) through JSON, and
##    the OSM edits file pins a look / resize / clear onto ONE regenerated
##    tree, replacing (looks) or stacking (resizes);
##  - VegTreePick: the ray picks the nearest crown it passes through, misses
##    between crowns, culls behind the ground, works looking straight down;
##  - VegColorDetect on a synthetic photo: Otsu separates the green, single
##    blobs become one plant at their centroid sized to the blob, a canopy
##    patch is filled, specks are dropped, sensitivity loosens, a bare photo
##    finds nothing, results are deterministic, the Mercator path agrees;
##  - every canopy shader reads the species-glow instance uniform.
## Carries EXPECTED_CHECKS: a runtime error aborts the enclosing test function
## while the suite still prints PASS.
## Run with:
##   godot --headless --path . --script vegetation/veg_select_detect_selftest.gd

const EXPECTED_CHECKS := 64
const TEST_SUFFIX := ".vsdtest"
const T_LAT := 23.45
const T_LON := 67.89

var _failures := 0
var _checks := 0


func _initialize() -> void:
	VegStyleStore.path_suffix = TEST_SUFFIX
	VegStyleStore.invalidate_cache()
	_cleanup()
	_test_instance_override()
	_test_map_species()
	_test_store_map_scope()
	_test_layer_instance_look()
	_test_auto_tree_pins()
	_test_tree_pick()
	_test_detect_synthetic()
	_test_detect_bare_and_mercator()
	_test_shader_glow()
	_cleanup()
	VegStyleStore.path_suffix = ""
	VegStyleStore.invalidate_cache()
	_check("check count matches EXPECTED_CHECKS (a runtime error would abort a "
		+ "test function early and still print PASS)", _checks + 1 == EXPECTED_CHECKS,
		"ran %d, expected %d" % [_checks + 1, EXPECTED_CHECKS])
	if _failures == 0:
		print("VEG SELECT/DETECT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG SELECT/DETECT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _cleanup() -> void:
	for p in [VegStyleStore.global_v2_path(), VegStyleStore.map_v2_path(T_LAT, T_LON)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	VegStyleStore.invalidate_cache()


func _resolve(species: String, s: Dictionary) -> Dictionary:
	return VegSpeciesCatalog.settings_with_variant(species, s, VegetationCardFactory.SPECS)


# --- resolution ----------------------------------------------------------------

func _test_instance_override() -> void:
	var base := VegetationStyleConfig.defaults()
	base[VegStyleStore.KEY_SPECIES_OVERRIDES] = {"douglas_fir": {"height_m": 30.0}}
	base[VegStyleStore.KEY_USER_FAMILY] = ["pine_crown_width_m"]
	base["pine_crown_width_m"] = 9.0
	var plain := _resolve("douglas_fir", base)
	_check("species override applies without a per-tree look",
		is_equal_approx(float(plain["pine_height_m"]), 30.0), str(plain.get("pine_height_m")))
	var with_inst := base.duplicate(true)
	with_inst[VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE] = {
		"height_m": 12.5, "crown_width_m": 3.0, "archetype": "columnar",
		"albedo_tint": Color(0.2, 0.9, 0.3), "bark_tint": Color(0.9, 0.9, 0.9)}
	var r := _resolve("douglas_fir", with_inst)
	_check("per-tree height beats the species override",
		is_equal_approx(float(r["pine_height_m"]), 12.5), str(r.get("pine_height_m")))
	_check("per-tree crown beats a user family edit (no SPECS ratio)",
		is_equal_approx(float(r["pine_crown_width_m"]), 3.0), str(r.get("pine_crown_width_m")))
	_check("per-tree archetype lands", str(r["pine_archetype"]) == "columnar")
	_check("per-tree albedo lands on the family tint",
		(r["pine_albedo_tint"] as Color).is_equal_approx(Color(0.2, 0.9, 0.3)))
	_check("per-tree bark lands on the family bark key",
		r.get("pine_bark_tint") is Color and (r["pine_bark_tint"] as Color).is_equal_approx(Color(0.9, 0.9, 0.9)))
	_check("per-tree keys count as explicit edits",
		"pine_height_m" in (r[VegStyleStore.KEY_USER_FAMILY] as Array))
	var twice := _resolve("douglas_fir", r)
	_check("resolving twice == once (idempotent)",
		is_equal_approx(float(twice["pine_height_m"]), 12.5)
		and is_equal_approx(float(twice["pine_crown_width_m"]), 3.0))
	# Generic family species: the per-tree look is never gated.
	var g := base.duplicate(true)
	g[VegStyleStore.KEY_USER_FAMILY] = ["pine_height_m"]
	g["pine_height_m"] = 20.0
	g[VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE] = {"height_m": 7.0}
	_check("per-tree look wins on a generic species over a family edit",
		is_equal_approx(float(_resolve("pine", g)["pine_height_m"]), 7.0))
	var empty := base.duplicate(true)
	empty[VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE] = {}
	var re := _resolve("douglas_fir", empty)
	_check("an empty per-tree look resolves like none",
		is_equal_approx(float(re["pine_height_m"]), float(plain["pine_height_m"]))
		and is_equal_approx(float(re["pine_crown_width_m"]), float(plain["pine_crown_width_m"])))


func _test_map_species() -> void:
	var s := VegetationStyleConfig.defaults()
	s[VegStyleStore.KEY_USER_FAMILY] = ["pine_height_m"]
	s["pine_height_m"] = 20.0
	s[VegStyleStore.KEY_SPECIES_OVERRIDES] = {"pine": {"height_m": 11.0}}
	_check("a global generic-species entry yields to a family edit",
		is_equal_approx(float(_resolve("pine", s)["pine_height_m"]), 20.0))
	s[VegStyleStore.KEY_MAP_SPECIES] = ["pine"]
	_check("a MAP generic-species entry beats this map's family edit",
		is_equal_approx(float(_resolve("pine", s)["pine_height_m"]), 11.0))


func _test_store_map_scope() -> void:
	_check("no map species → no side channel",
		not VegStyleStore.flat_merged(T_LAT, T_LON).has(VegStyleStore.KEY_MAP_SPECIES))
	VegStyleStore.save_species_override_map(T_LAT, T_LON, "douglas_fir",
		{"height_m": 22.0, "albedo_tint": Color(0.1, 0.5, 0.2)})
	VegStyleStore.save_species_override("douglas_fir", {"height_m": 40.0, "crown_width_m": 8.0})
	var m := VegStyleStore.flat_merged(T_LAT, T_LON)
	var ov: Dictionary = (m[VegStyleStore.KEY_SPECIES_OVERRIDES] as Dictionary).get("douglas_fir", {})
	_check("map species value wins per key over the global one",
		is_equal_approx(float(ov.get("height_m", 0.0)), 22.0))
	_check("global species keys the map did not set still apply",
		is_equal_approx(float(ov.get("crown_width_m", 0.0)), 8.0))
	_check("map species listed under KEY_MAP_SPECIES",
		"douglas_fir" in (m.get(VegStyleStore.KEY_MAP_SPECIES, []) as Array))
	_check("map species colour survives the file", ov.get("albedo_tint") is Color)
	VegStyleStore.remove_species_override_keys_map(T_LAT, T_LON, "douglas_fir",
		["height_m", "albedo_tint"])
	var m2 := VegStyleStore.flat_merged(T_LAT, T_LON)
	var ov2: Dictionary = (m2[VegStyleStore.KEY_SPECIES_OVERRIDES] as Dictionary).get("douglas_fir", {})
	_check("removing the map keys lets the global default through",
		is_equal_approx(float(ov2.get("height_m", 0.0)), 40.0))
	_check("an emptied map entry is dropped",
		not m2.has(VegStyleStore.KEY_MAP_SPECIES))


# --- layers ----------------------------------------------------------------------

func _test_layer_instance_look() -> void:
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("douglas_fir", 1.0, 2.0, 0.0, 1.0)
	layer.add_bulk("douglas_fir", 9.0, 2.0, 0.0, 1.0)
	var desc := {"source": "painted", "kind": "bulk", "slot": "douglas_fir",
		"species": "douglas_fir", "index": 1}
	var look := {"height_m": 15.0, "albedo_tint": Color(0.3, 0.6, 0.2)}
	_check("set_instance_look resolves the descriptor", layer.set_instance_look(desc, look))
	_check("only that record carries a look",
		not (layer.bulk["douglas_fir"][0] as Dictionary).has("card_settings")
		and (layer.bulk["douglas_fir"][1] as Dictionary).has("card_settings"))
	var round := VegetationLayer.create_empty()
	round.deserialize(JSON.parse_string(JSON.stringify(layer.serialize())))
	var back := round.instance_look(desc)
	_check("per-tree look survives JSON", is_equal_approx(float(back.get("height_m", 0.0)), 15.0))
	_check("per-tree colour comes back a Color", back.get("albedo_tint") is Color
		and (back["albedo_tint"] as Color).is_equal_approx(Color(0.3, 0.6, 0.2)))
	_check("clear_species_looks drops it", layer.clear_species_looks("douglas_fir") == 1
		and layer.instance_look(desc).is_empty())
	layer.set_instance_look(desc, look)
	layer.set_instance_look(desc, {})
	_check("an empty look removes card_settings",
		not (layer.bulk["douglas_fir"][1] as Dictionary).has("card_settings"))


func _test_auto_tree_pins() -> void:
	var make := func() -> AutoVegetationLayer:
		var l := AutoVegetationLayer.create_empty()
		l.add_bulk("conifer", 10.0, 10.0, 0.0, 1.0, 20.0)
		l.add_bulk("conifer", 14.0, 10.0, 0.0, 1.0, 20.0)
		l.add_bulk("conifer", 30.0, 30.0, 0.0, 1.0, 20.0)
		return l
	var edits := AutoVegetationEdits.create_empty()
	edits.add_tree_patch(14.0, 10.0, "conifer", {VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE:
		{"height_m": 9.0, "albedo_tint": Color(0.8, 0.2, 0.2)}})
	edits.add_tree_patch(14.0, 10.0, "conifer", {VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE:
		{"height_m": 6.0}})
	edits.add_tree_patch(30.0, 30.0, "conifer", {"scale_mul": 1.5})
	edits.add_tree_patch(30.0, 30.0, "conifer", {"scale_mul": 2.0})
	edits.add_cleared_polygon(AutoVegetationEdits.tree_pin(10.0, 10.0))
	var reloaded := AutoVegetationEdits.create_empty()
	reloaded.deserialize(JSON.parse_string(JSON.stringify(edits.serialize())))
	var layer: AutoVegetationLayer = make.call()
	reloaded.apply_to_layer(layer)
	var arr: Array = layer.bulk["conifer"]
	_check("the pinned clear removed exactly one tree", arr.size() == 2, str(arr.size()))
	var tree_b: Dictionary = {}
	var tree_c: Dictionary = {}
	for r in arr:
		if is_equal_approx(float(r["x"]), 14.0):
			tree_b = r
		elif is_equal_approx(float(r["x"]), 30.0):
			tree_c = r
	var look: Dictionary = (tree_b.get("card_settings", {}) as Dictionary).get(
		VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE, {})
	_check("a later look REPLACES the earlier one on the same tree",
		is_equal_approx(float(look.get("height_m", 0.0)), 6.0) and not look.has("albedo_tint"),
		str(look))
	_check("resizes stack", is_equal_approx(float(tree_c.get("scale", 0.0)), 3.0),
		str(tree_c.get("scale")))
	_check("the resized tree has no look",
		not (tree_c.get("card_settings", {}) as Dictionary).has(VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE))
	var desc := layer.nearest_plant(Vector2(14.2, 10.1), 2.0)
	_check("auto nearest_plant finds the pinned tree",
		not desc.is_empty() and is_equal_approx(float(desc["x"]), 14.0))
	_check("auto instance_look reads it back",
		is_equal_approx(float(layer.instance_look(desc).get("height_m", 0.0)), 6.0))
	var colour_edits := AutoVegetationEdits.create_empty()
	colour_edits.add_tree_patch(14.0, 10.0, "conifer", {VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE:
		{"albedo_tint": Color(0.8, 0.2, 0.2)}})
	var cr := AutoVegetationEdits.create_empty()
	cr.deserialize(JSON.parse_string(JSON.stringify(colour_edits.serialize())))
	var l2: AutoVegetationLayer = make.call()
	cr.apply_to_layer(l2)
	var d2 := l2.nearest_plant(Vector2(14.0, 10.0), 1.0)
	_check("a pinned colour comes back a Color after JSON",
		l2.instance_look(d2).get("albedo_tint") is Color)
	_check("remove_tree_patches drops the looks of a slot",
		edits.remove_tree_patches("conifer", VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE) == 1)


# --- pick --------------------------------------------------------------------------

func _test_tree_pick() -> void:
	var painted := {"pine": [{"x": 0.0, "z": -20.0, "scale": 1.0}]}
	var auto := {"conifer": [{"x": 0.0, "z": -40.0, "scale": 1.0, "height_m": 20.0},
		{"x": 30.0, "z": -40.0, "scale": 1.0, "height_m": 20.0}]}
	var sources := [{"source": "painted", "bulk": painted, "hero": []},
		{"source": "auto", "bulk": auto, "hero": []}]
	var pick := VegTreePick.new()
	var height_of := func(_slot: String, rec: Dictionary) -> float:
		return float(rec.get("height_m", 10.0))
	pick.rebuild_if_changed(sources, height_of)
	_check("index holds every plant", pick.count() == 3)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	# Eye height, looking north (−Z) along x = 0: the painted pine stands first.
	var h1 := pick.pick(Vector3(0, 1.7, 0), Vector3(0, 0, -1), INF, flat)
	_check("the nearest crown on the ray wins (painted pine at 20 m)",
		str(h1.get("source", "")) == "painted" and is_equal_approx(float(h1.get("z", 0.0)), -20.0),
		str(h1))
	var h2 := pick.pick(Vector3(15, 1.7, 0), Vector3(0, 0, -1), INF, flat)
	_check("a ray between crowns picks nothing", h2.is_empty(), str(h2))
	var h3 := pick.pick(Vector3(30, 1.7, 0), Vector3(0, 0, -1), 25.0, flat)
	_check("a crown wholly behind the ground hit is hidden", h3.is_empty(), str(h3))
	var h4 := pick.pick(Vector3(30, 1.7, 0), Vector3(0, 0, -1), INF, flat)
	_check("the same crown with open ground is picked (auto source)",
		str(h4.get("source", "")) == "auto" and str(h4.get("slot", "")) == "conifer")
	var h5 := pick.pick(Vector3(30.5, 80.0, -40.3), Vector3(0, -1, 0), 80.0, flat)
	_check("looking straight down onto a crown picks it",
		not h5.is_empty() and is_equal_approx(float(h5.get("x", 0.0)), 30.0))
	var h6 := pick.pick(Vector3(0, 50.0, 0), Vector3(0, 0, -1), INF, flat)
	_check("a ray over the treetops misses", h6.is_empty())
	var sig_a := VegTreePick.signature(sources)
	(painted["pine"] as Array).append({"x": 5.0, "z": 5.0, "scale": 1.0})
	_check("adding a plant changes the signature", VegTreePick.signature(sources) != sig_a)


# --- detect --------------------------------------------------------------------

## 200 × 200 m at 0.5 m/px: tan ground, five dark-green shrubs (r 1.5 m),
## one 40 × 30 m canopy, a handful of single-pixel green specks.
func _synthetic_photo() -> Image:
	var img := Image.create(400, 400, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.74, 0.64, 0.49))
	for c in [Vector2(-60, -60), Vector2(-20, -60), Vector2(20, -60), Vector2(60, -60), Vector2(-60, 40)]:
		_disc(img, c as Vector2, 1.5, Color(0.17, 0.22, 0.1))
	for py in range(int((10.0 + 100.0) * 2.0), int((40.0 + 100.0) * 2.0)):
		for px in range(int((10.0 + 100.0) * 2.0), int((50.0 + 100.0) * 2.0)):
			img.set_pixel(px, py, Color(0.12, 0.24, 0.1))
	for sp in [Vector2i(20, 380), Vector2i(380, 20), Vector2i(380, 380)]:
		img.set_pixelv(sp as Vector2i, Color(0.15, 0.3, 0.1))
	return img


func _disc(img: Image, c: Vector2, r_m: float, col: Color) -> void:
	for py in img.get_height():
		for px in img.get_width():
			var w := Vector2((float(px) + 0.5) * 0.5 - 100.0, (float(py) + 0.5) * 0.5 - 100.0)
			if w.distance_to(c) <= r_m:
				img.set_pixel(px, py, col)


func _square(h: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])


func _test_detect_synthetic() -> void:
	_check("ExG: foliage beats sand", VegColorDetect.exg(Color(0.17, 0.22, 0.1))
		> VegColorDetect.exg(Color(0.74, 0.64, 0.49)) + 0.1)
	var d := VegColorDetect.new()
	d.add_layer(_synthetic_photo(), 100.0)
	var res := d.detect(_square(99.0), {"cell_m": 0.5, "spacing_m": 8.0})
	_check("Otsu finds a clear split", bool(res.get("auto_split", false)),
		str(res["separability"]))
	var cut := float(res["cut"])
	_check("the cut sits between sand and foliage",
		cut > VegColorDetect.exg(Color(0.74, 0.64, 0.49))
		and cut < VegColorDetect.exg(Color(0.17, 0.22, 0.1)), str(cut))
	var singles: Array = []
	var canopy: Array = []
	for p in res["plants"]:
		if bool((p as Dictionary)["canopy"]):
			canopy.append(p)
		else:
			singles.append(p)
	_check("five shrubs → five single plants (specks dropped)", singles.size() == 5,
		str(singles.size()))
	var near := 0
	for p in singles:
		var pd: Dictionary = p
		if Vector2(float(pd["x"]), float(pd["z"])).distance_to(Vector2(-20, -60)) < 0.6:
			near += 1
			_check("a shrub is sized to its blob (Ø ≈ 3 m)",
				absf(float(pd["d_m"]) - 3.0) < 0.6, str(pd["d_m"]))
	_check("one plant lands on the shrub at (-20, -60)", near == 1)
	_check("the canopy patch is filled", canopy.size() >= 10, str(canopy.size()))
	var inside := true
	for p in canopy:
		var pd: Dictionary = p
		if float(pd["x"]) < 9.0 or float(pd["x"]) > 51.0 or float(pd["z"]) < 9.0 or float(pd["z"]) > 41.0:
			inside = false
	_check("every canopy plant is inside the canopy", inside)
	var again := d.detect(_square(99.0), {"cell_m": 0.5, "spacing_m": 8.0})
	_check("detection is deterministic", str(again["plants"]) == str(res["plants"]))
	var loose := d.detect(_square(99.0), {"cell_m": 0.5, "spacing_m": 8.0, "sensitivity": 1.0})
	_check("more sensitivity never finds less green",
		float(loose["green_m2"]) >= float(res["green_m2"]))
	var region := d.detect(_square(30.0), {"cell_m": 0.5, "spacing_m": 8.0})
	var outside := false
	for p in region["plants"]:
		if absf(float((p as Dictionary)["x"])) > 30.5 or absf(float((p as Dictionary)["z"])) > 30.5:
			outside = true
	_check("a region only yields plants inside it", not outside)
	var mask := VegColorDetect.mask_image(res["mask"])
	_check("the preview mask is the raster size", mask != null
		and mask.get_width() == int((res["mask"] as Dictionary)["w"]))


func _test_detect_bare_and_mercator() -> void:
	var bare := Image.create(200, 200, false, Image.FORMAT_RGBA8)
	bare.fill(Color(0.74, 0.64, 0.49))
	for i in 200:
		bare.set_pixel(i, (i * 7) % 200, Color(0.7, 0.6, 0.47))
	var d := VegColorDetect.new()
	d.add_layer(bare, 100.0)
	var res := d.detect(_square(90.0), {"cell_m": 1.0})
	_check("a bare photo finds no plants", (res["plants"] as Array).is_empty(),
		str((res["plants"] as Array).size()))
	_check("two-tone bare ground is not trusted as a green split (default cut)",
		not bool(res.get("auto_split", true))
		and is_equal_approx(float(res["cut"]), VegColorDetect.FALLBACK_EXG), str(res["cut"]))
	# The Mercator path over a 200 m square at 48° N barely moves anything.
	var bb := GeoMath.bbox_for(48.3, -122.2, 100.0)
	var dm := VegColorDetect.new()
	dm.add_layer(_synthetic_photo(), 100.0, float(bb["north"]), float(bb["south"]))
	var rm := dm.detect(_square(99.0), {"cell_m": 0.5, "spacing_m": 8.0})
	var hit := false
	for p in rm["plants"]:
		var pd: Dictionary = p
		if not bool(pd["canopy"]) and Vector2(float(pd["x"]), float(pd["z"])).distance_to(Vector2(-20, -60)) < 0.8:
			hit = true
	_check("the Mercator path lands the shrub in the same place", hit)
	var two := VegColorDetect.new()
	two.add_layer(bare, 100.0)
	var fine := Image.create(100, 100, false, Image.FORMAT_RGBA8)
	fine.fill(Color(0.74, 0.64, 0.49))
	two.add_layer(fine, 20.0)
	_check("the finest covering layer is used", is_equal_approx(two.resolution_at(0.0, 0.0), 0.4)
		and is_equal_approx(two.resolution_at(50.0, 0.0), 1.0))
	_check("finest_half_m is the sharp square", is_equal_approx(two.finest_half_m(), 20.0))


func _test_shader_glow() -> void:
	var inc := FileAccess.get_file_as_string("res://vegetation/veg_lighting.gdshaderinc")
	_check("the include declares the glow instance uniform",
		inc.contains("instance uniform float veg_hl"))
	for path in ["res://vegetation/foliage.gdshader", "res://vegetation/leaf_canopy.gdshader",
			"res://vegetation/bark.gdshader", "res://vegetation/veg_impostor.gdshader"]:
		var src := FileAccess.get_file_as_string(path)
		_check("%s applies the species glow" % path.get_file(),
			src.contains("veg_hl_albedo(") and src.contains("veg_lighting.gdshaderinc"))
