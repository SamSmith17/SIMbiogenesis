extends SceneTree

## Offline selftest — ImportMaterialFixer (SketchUp gloss fix) + ImagerySources.
##   Godot --headless --path . --script core/placed_models/import_material_fixer_selftest.gd
## Carries EXPECTED_CHECKS: a Godot runtime error aborts a test function while
## the suite would still print PASS.

const EXPECTED_CHECKS := 71

var _checks := 0
var _fails := 0


func _ok(label: String, cond: bool) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", label)


func _initialize() -> void:
	_test_detection()
	_test_classify()
	_test_fix_material()
	_test_real_simlab_glb()
	_test_imagery_sources()
	_test_mercator_series()
	if _fails == 0 and _checks == EXPECTED_CHECKS:
		print("IMPORT MATERIAL FIXER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("IMPORT MATERIAL FIXER SELFTEST FAIL  (%d failed, %d/%d checks ran)" % [
			_fails, _checks, EXPECTED_CHECKS])
	quit()


func _test_detection() -> void:
	_ok("SimLab generator → sketchup",
		ImportMaterialFixer.source_app({"asset": {"generator": "SimLab GLTF"}}) == "sketchup")
	_ok("SketchUp generator → sketchup",
		ImportMaterialFixer.source_app({"asset": {"generator": "SketchUp 2024 glTF exporter"}}) == "sketchup")
	_ok("Sketchfab → not sketchup",
		ImportMaterialFixer.source_app({"asset": {"generator": "Sketchfab-12.65.0"}}) == "")
	var sg := {"extensions": {"KHR_materials_pbrSpecularGlossiness": {"glossinessFactor": 0.5}}}
	_ok("SimLab fingerprint (all gloss 0.5) without a generator → sketchup",
		ImportMaterialFixer.source_app({"asset": {}, "materials": [sg, sg, sg]}) == "sketchup")
	var authored := {"extensions": {"KHR_materials_pbrSpecularGlossiness": {"glossinessFactor": 0.83}}}
	_ok("authored spec-gloss values → not sketchup",
		ImportMaterialFixer.source_app({"asset": {}, "materials": [authored, authored]}) == "")
	var j := {"asset": {"generator": "SimLab GLTF"}}
	_ok("mode auto fixes a SketchUp export", ImportMaterialFixer.should_fix(j, "auto"))
	_ok("mode off never fixes", not ImportMaterialFixer.should_fix(j, "off"))
	_ok("mode force fixes anything", ImportMaterialFixer.should_fix({}, "force"))
	_ok("mode auto leaves a non-SketchUp file", not ImportMaterialFixer.should_fix({"asset": {"generator": "Blender"}}, "auto"))


func _test_classify() -> void:
	# Real names from the user's Halvorsen SketchUp exports.
	var cases := {
		"Brick_Antique": "masonry",
		"Roofing_Shingles_Multi": "masonry",
		"[Cladding_Siding_Tan]": "siding",
		"Oak_Cab_Door_Seamless_L1": "wood",
		"[Wood_Cherry_Original]2": "wood",
		"Wood_Deck": "wood",
		"Wood_Cardboard": "wood",
		"[Metal Seamed]": "metal_roof",
		"[Metal Corrugated Shiny]": "metal_roof",
		"[Metal_Corrogated_Shiny]1": "metal_roof",
		"[Metal_Aluminum_Anodized]1": "metal_shiny",
		"Screw_Gray": "metal",
		"[Translucent Glass Gray]": "glass",
		"PV_phono": "solar",
		"[Color M09]": "paint",
		"<LightGray>1": "paint",
		"A08_Garnet_Shadow": "paint",
		"Textile_Weave": "fabric",
		"PVC_Pipe_White": "plastic",
		"*14": "default",
		"Geolocation /api/v2/tile/bing?x=5354&y=11755&zoom=15&resolution=Tile2048 tile": "ground",
		"[Terrazzo Tile Light]": "glazed",
		"Sree_Complexion_3": "default",
		"mono_x_lg_solar_panel": "solar",
		"Control Panel - Copy": "default",
		"hoverboard_motor_black": "default",
		"[0109_DarkSlateBlue]": "paint",
		"Metal Painted Bumpy Blue 5cm": "metal_roof",
		"[Chipboard]3": "wood",
	}
	for n: String in cases:
		_ok("classify '%s' → %s (got %s)" % [n, cases[n], ImportMaterialFixer.classify(n)],
			ImportMaterialFixer.classify(n) == str(cases[n]))


func _simlab_like(name: String, alpha: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = name
	m.metallic = 0.0
	m.roughness = 0.5
	m.metallic_specular = 0.5
	m.albedo_color = Color(0.6, 0.5, 0.4, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if alpha >= 0.99 \
		else BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _test_fix_material() -> void:
	var brick := _simlab_like("Brick_Antique")
	ImportMaterialFixer.fix_material(brick)
	_ok("brick goes matte (rough 0.92)", is_equal_approx(brick.roughness, 0.92))
	_ok("brick stays dielectric", brick.metallic == 0.0)
	_ok("opaque MASK material becomes opaque", brick.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED)
	var glass := _simlab_like("[Translucent Glass Gray]", 0.5)
	ImportMaterialFixer.fix_material(glass)
	_ok("glass smooth", glass.roughness <= 0.06)
	_ok("glass keeps its transparency", glass.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA)
	var tint := _simlab_like("*15", 0.29)
	ImportMaterialFixer.fix_material(tint)
	_ok("an unnamed see-through material is treated as glass",
		str(tint.get_meta("sketchup_fix", "")) == "glass")
	# A leaf texture with real alpha keeps its alpha test.
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.5, 0.1, 1.0))
	img.set_pixel(1, 1, Color(0, 0, 0, 0))
	var leaf := _simlab_like("Leaves_Maple")
	leaf.albedo_texture = ImageTexture.create_from_image(img)
	ImportMaterialFixer.fix_material(leaf)
	_ok("a texture with alpha keeps the alpha test",
		leaf.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)
	var roof := _simlab_like("[Metal Seamed]")
	ImportMaterialFixer.fix_material(roof)
	_ok("painted metal roofing: mostly dielectric, mid rough",
		roof.metallic < 0.5 and roof.roughness > 0.5)
	var anod := _simlab_like("[Metal_Aluminum_Anodized]1")
	ImportMaterialFixer.fix_material(anod)
	_ok("anodized aluminium is a metal", anod.metallic >= 0.99)


## The fix end to end on a real SimLab export shipped in the repo.
func _test_real_simlab_glb() -> void:
	var path := "res://Imported Models/Appa.glb"
	var j := ImportMaterialFixer.read_gltf_json(path)
	_ok("read the glb's JSON chunk", not j.is_empty())
	_ok("Appa.glb is recognised as a SketchUp export", ImportMaterialFixer.source_app(j) == "sketchup")
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), st) != OK:
		_ok("GLTFDocument loaded Appa.glb", false)
		return
	_ok("GLTFDocument loaded Appa.glb", true)
	_ok("state.json matches the file's JSON", ImportMaterialFixer.source_app(st.json) == "sketchup")
	var root := doc.generate_scene(st)
	var rep := ImportMaterialFixer.fix_scene(root)
	_ok("materials were fixed (%d)" % int(rep.get("fixed", 0)), int(rep.get("fixed", 0)) > 0)
	var still_half := 0
	for m in st.get_materials():
		if m is StandardMaterial3D and is_equal_approx((m as StandardMaterial3D).roughness, 0.5):
			still_half += 1
	_ok("no material left at the invented roughness 0.5 (%d)" % still_half, still_half == 0)
	root.free()


func _test_imagery_sources() -> void:
	var mv := ImagerySources.chain_for(48.3252, -122.2469)
	_ok("Mount Vernon chain starts with the Skagit flight (%s)" % str(mv),
		not mv.is_empty() and str(mv[0]) == "skagit_2021_9in")
	_ok("chain always ends with plain ESRI", str(mv[mv.size() - 1]) == "esri")
	var walton := ImagerySources.chain_for(44.0113, -123.5911)
	_ok("outside Skagit: Clarity then ESRI (%s)" % str(walton),
		walton.size() == 2 and str(walton[0]) == "esri_clarity")
	_ok("native zoom for a 9-inch flight at 48°N is z19",
		ImagerySources.native_zoom(mv, 48.3252) == 19)
	_ok("plain ESRI chain keeps the old cache key", ImagerySources.chain_key(["esri"]) == "")
	_ok("a regional chain has its own cache key", ImagerySources.chain_key(mv) == "skagit_2021_9in")
	var grey := Image.create(256, 256, false, Image.FORMAT_RGB8)
	grey.fill(Color(0.8, 0.8, 0.8))
	_ok("a uniform placeholder tile is blank", ImagerySources.is_blank_tile(grey))
	var clear := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	clear.fill(Color(1, 1, 1, 0))
	_ok("a fully transparent cache tile is blank", ImagerySources.is_blank_tile(clear))
	var real := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in 256:
		for x in 256:
			var v := rng.randf_range(0.1, 0.7)
			real.set_pixel(x, y, Color(v * 0.8, v, v * 0.6))
	_ok("real imagery is not blank", not ImagerySources.is_blank_tile(real))
	_ok("Skagit attribution names the county",
		ImagerySources.attribution_for(["skagit_2021_9in", "esri"]).contains("Skagit County"))
	_ok("tile URL is z/y/x", ImagerySources.tile_url("esri", 19, 1, 2).ends_with("/19/2/1"))


## The drape shaders' Mercator correction (mirrored by
## TerrainBuilder.mercator_v_relative) against the exact asinh(tan) form in
## double precision: the series must match to well under a centimetre on a
## 1.2 km site patch and a 120 km base drape, at mid and high latitude.
func _test_mercator_series() -> void:
	for case_v: Array in [[48.3252, 600.0], [48.3252, 60000.0], [44.01, 1500.0], [69.6, 30000.0]]:
		var lat: float = case_v[0]
		var half: float = case_v[1]
		var bb := GeoMath.bbox_for(lat, -122.0, half)
		var n: float = bb["north"]
		var s: float = bb["south"]
		var my_n := asinh(tan(deg_to_rad(n)))
		var my_s := asinh(tan(deg_to_rad(s)))
		var worst := 0.0
		for i in 21:
			var t := float(i) / 20.0
			var la := lerpf(n, s, t)
			var exact := (my_n - asinh(tan(deg_to_rad(la)))) / (my_n - my_s)
			var series := TerrainBuilder.mercator_v_relative(t, n, s)
			worst = maxf(worst, absf(exact - series) * half * 2.0)
		_ok("Mercator series within 1 cm at lat %.1f over %.0f m (%.5f m)" % [lat, half * 2.0, worst],
			worst < 0.01)
	_ok("series is exact at the edges",
		absf(TerrainBuilder.mercator_v_relative(0.0, 48.33, 48.32)) < 1e-12
		and absf(TerrainBuilder.mercator_v_relative(1.0, 48.33, 48.32) - 1.0) < 1e-12)
	# The shader form and the GDScript mirror must not drift: same constants.
	var sh := FileAccess.get_file_as_string("res://core/terrain/terrain_detail.gdshader")
	var roof := FileAccess.get_file_as_string("res://core/terrain/building_roof.gdshader")
	var term := "tan0 * (5.0 * sec0 * sec0 + tan0 * tan0) * d * d * d / 24.0"
	_ok("terrain shader uses the centre-relative series", sh.contains(term) and not sh.contains("_asinh(tan(radians(lat)))"))
	_ok("roof shader uses the centre-relative series", roof.contains(term) and not roof.contains("_asinh(tan(radians(lat)))"))

