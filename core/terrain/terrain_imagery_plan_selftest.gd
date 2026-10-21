extends SceneTree
## TerrainImageryPlan (offline):
##   Godot.exe --headless --path . --script core/terrain/terrain_imagery_plan_selftest.gd
## The loader's tier tables ARE the plan's; each layer's key is the key
## ImageryService would request; infer_tier reads the right tier off a site's
## cached files (and refuses a half-cached tier); record_for_import prefers
## the author's recorded tier, falls back to inference, and returns {} when
## neither is known; GPU cost rises with the tier and an exported game's RGBA8
## costs 8x DXT1; the choice is offered only when the tiers differ.
## Works at a coordinate nobody plays and deletes the files it writes.

const _ImgSvc := preload("res://core/terrain/imagery_service.gd")
const EXPECTED_CHECKS := 30
const LAT := 0.0371
const LON := 0.0613
const DH := 3000.0

var _n := 0
var _fails := 0
var _written: Array[String] = []


func _initialize() -> void:
	_test_tables()
	_test_keys()
	_test_infer_and_import()
	_test_vram_and_choice()
	_cleanup()
	if _n != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != %d (a runtime error aborted a test?)" % [_n, EXPECTED_CHECKS])
	print("TERRAIN IMAGERY PLAN SELFTEST %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if not cond:
		_fails += 1
		print("FAIL ", what)


func _test_tables() -> void:
	var L: Script = load("res://core/terrain/terrain_loader.gd")
	var c := L.get_script_constant_map()
	_ok(c["QUALITY_DETAIL_TARGET_PX"] == TerrainImageryPlan.DETAIL_TARGET_PX, "loader detail px == plan")
	_ok(c["QUALITY_HYPER_HALF_EXTENT"] == TerrainImageryPlan.HYPER_HALF_EXTENT, "loader hyper half == plan")
	_ok(c["QUALITY_HYPER_TARGET_PX"] == TerrainImageryPlan.HYPER_TARGET_PX, "loader hyper px == plan")
	_ok(c["QUALITY_SITE_HALF_EXTENT"] == TerrainImageryPlan.SITE_HALF_EXTENT, "loader site half == plan")
	_ok(int(c["DETAIL_MAX_ZOOM"]) == TerrainImageryPlan.DETAIL_MAX_ZOOM
		and int(c["HYPER_MAX_ZOOM"]) == TerrainImageryPlan.HYPER_MAX_ZOOM, "zoom caps match")


func _test_keys() -> void:
	var d := TerrainImageryPlan.layer("detail", 3, LAT, LON, DH)
	_ok(str(d["key"]) == _ImgSvc.layer_key(LAT, LON, DH, 8192, 19), "Ultra detail key == ImageryService's")
	var h := TerrainImageryPlan.layer("hyper", 1, LAT, LON, DH)
	_ok(is_equal_approx(float(h["half"]), 500.0) and str(h["key"]) == _ImgSvc.layer_key(LAT, LON, 500.0, 8192, 19,
		ImagerySources.chain_for(LAT, LON)), "Medium hyper key == ImageryService's (chain included)")
	_ok(TerrainImageryPlan.layer("site", 0, LAT, LON, DH).is_empty(), "Low has no site patch")
	var s3 := TerrainImageryPlan.layer("site", 3, LAT, LON, DH)
	_ok(not s3.is_empty() and bool(s3["hq"]) and float(s3["half"]) <= 600.0, "Ultra site patch: hq, <= 600 m")
	var small := TerrainImageryPlan.layer("hyper", 3, LAT, LON, 800.0)
	_ok(float(small["half"]) <= 800.0, "hyper never past the hi-res patch")
	var ov := TerrainImageryPlan.layer("hyper", 3, LAT, LON, DH, {"hyper_target_px": 2048})
	_ok(int(ov["px"]) == 2048, "hyper_target_px override wins")
	_ok(TerrainImageryPlan.layers(1, LAT, LON, DH).size() == 3 and TerrainImageryPlan.layers(0, LAT, LON, DH).size() == 2,
		"Medium has 3 layers, Low 2")


func _touch(l: Dictionary) -> void:
	var p := _ImgSvc.cache_path_for(str(l["key"]))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(p.get_base_dir()))
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string("x")
	f.close()
	_written.append(p)


func _cleanup() -> void:
	for p in _written:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _test_infer_and_import() -> void:
	_cleanup()
	_written.clear()
	_ok(TerrainImageryPlan.infer_tier(LAT, LON, DH) == -1, "nothing cached -> tier -1")
	# Ultra's detail alone is not a tier: hyper must be there too.
	_touch(TerrainImageryPlan.layer("detail", 3, LAT, LON, DH))
	_ok(TerrainImageryPlan.infer_tier(LAT, LON, DH) != 3, "half a tier is not inferred")
	_touch(TerrainImageryPlan.layer("hyper", 3, LAT, LON, DH))
	_ok(TerrainImageryPlan.infer_tier(LAT, LON, DH) == 3, "detail + hyper cached -> Ultra")
	_ok(TerrainImageryPlan.is_cached(TerrainImageryPlan.layer("detail", 3, LAT, LON, DH)), "is_cached sees the file")
	_ok(TerrainImageryPlan.cached_count(3, LAT, LON, DH) == Vector2i(2, 3), "Ultra: 2 of 3 layers on disk")
	var rec := {"map": {"scene_path": MapDefinition.GENERATED_SCENE, "lat": LAT, "lon": LON,
		"detail_half_extent_m": DH}}
	var r1 := TerrainImageryPlan.record_for_import(rec)
	_ok(r1 == {"tier": 3, "saved_tier": 3, "mode": "saved"}, "old pack: tier inferred, opens saved (%s)" % str(r1))
	var rec2 := rec.duplicate(true)
	rec2["terrain_imagery"] = {"tier": 2, "saved_tier": -1, "mode": "local"}
	_ok(TerrainImageryPlan.record_for_import(rec2) == {"tier": 2, "saved_tier": 2, "mode": "saved"},
		"author's recorded tier beats inference")
	var snap := {"world_extras": {"terrain_imagery": {"tier": 0, "mode": "local"}}}
	_ok(int(TerrainImageryPlan.record_for_import(rec, snap)["saved_tier"]) == 0, "snapshot's record when world.json has none")
	_cleanup()
	_ok(TerrainImageryPlan.record_for_import(rec).is_empty(), "unknown tier -> {} (this computer's quality)")
	# A pack made before source chains: the hyper square is cached under its
	# plain ESRI name. It counts, so the tier is still read as Ultra.
	var hyper := TerrainImageryPlan.layer("hyper", 3, LAT, LON, DH)
	var pk := _ImgSvc.plain_key(str(hyper["key"]))
	_ok(not pk.is_empty() and str(hyper["key"]).begins_with(pk + "_") and _ImgSvc.plain_key(pk).is_empty(),
		"plain_key strips the chain suffix only (%s)" % pk)
	_touch(TerrainImageryPlan.layer("detail", 3, LAT, LON, DH))
	_touch({"key": pk})
	_ok(TerrainImageryPlan.is_cached(hyper) and _ImgSvc.cached_file_for_key(str(hyper["key"])) == _ImgSvc.cache_path_for(pk),
		"a chained layer finds its pre-chain file")
	_ok(TerrainImageryPlan.infer_tier(LAT, LON, DH) == 3, "pre-chain Ultra pack still reads as Ultra")
	_touch(hyper)
	_ok(_ImgSvc.cached_file_for_key(str(hyper["key"])) == _ImgSvc.cache_path_for(str(hyper["key"])),
		"its own file beats the pre-chain one")
	_cleanup()


func _test_vram_and_choice() -> void:
	var low := TerrainImageryPlan.vram_bytes(0, LAT, LON, DH, {}, true)
	var ultra := TerrainImageryPlan.vram_bytes(3, LAT, LON, DH, {}, true)
	_ok(low > 0 and ultra > low * 4, "Ultra costs far more than Low (%d vs %d)" % [ultra, low])
	var raw0 := TerrainImageryPlan.vram_bytes(0, LAT, LON, DH, {}, false)
	_ok(absi(raw0 - low * 8) <= 8, "exported RGBA8 = 8x DXT1 on Low (no BC7 layer): %d vs %d" % [raw0, low])
	_ok(TerrainImageryPlan.format_bytes(1610612736) == "1.5 GB" and TerrainImageryPlan.format_bytes(314572800) == "300 MB",
		"format_bytes")
	_ok(TerrainImageryChoice.has_choice({"saved_tier": 3, "local_tier": 1}), "choice when tiers differ")
	_ok(not TerrainImageryChoice.has_choice({"saved_tier": 1, "local_tier": 1})
		and not TerrainImageryChoice.has_choice({"saved_tier": -1, "local_tier": 1}), "no choice when equal / unknown")
