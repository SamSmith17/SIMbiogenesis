extends SceneTree

## Headless self-test for the Phase 2 layered style store + real-subspecies
## resolution. Pure / offline — writes only suffixed test files under user://
## and deletes them on exit.
## Run with:
##   godot --headless --path . --script vegetation/veg_style_store_selftest.gd

var _failures := 0
var _checks := 0

const TEST_SUFFIX := ".vsstest"
const T_LAT := 12.34
const T_LON := 56.78


func _initialize() -> void:
	VegStyleStore.path_suffix = TEST_SUFFIX
	VegStyleStore.invalidate_cache()
	_cleanup_files()
	_test_key_split()
	_test_global_patch_routing()
	_test_species_override_roundtrip()
	_test_variant_precedence()
	_test_variant_meshes_differ()
	_test_fresh_start_ignores_legacy()
	_test_stale_version_ignored()
	_test_layer_sparse()
	_cleanup_files()
	VegStyleStore.path_suffix = ""
	VegStyleStore.invalidate_cache()
	if _failures == 0:
		print("VEG STYLE STORE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG STYLE STORE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _cleanup_files() -> void:
	for p in [
		VegStyleStore.global_v2_path(),
		VegStyleStore.map_v2_path(T_LAT, T_LON),
		VegStyleStore.legacy_map_path(T_LAT, T_LON),
		VegetationStyleConfig.GLOBAL_PATH + TEST_SUFFIX,
		VegetationStyleConfig.SPECIES_DEFAULTS_PATH + TEST_SUFFIX,
	]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	VegStyleStore.invalidate_cache()


func _test_key_split() -> void:
	_check("grass_lawn splits as its own family",
		VegStyleStore.split_flat_key("grass_lawn_card_w") == ["grass_lawn", "card_w"])
	_check("pine key splits", VegStyleStore.split_flat_key("pine_height_m") == ["pine", "height_m"])
	_check("unprefixed key stays global",
		VegStyleStore.split_flat_key("haze_strength") == ["", "haze_strength"])
	_check("deciduous compound key splits",
		VegStyleStore.split_flat_key("deciduous_crown_base_pct") == ["deciduous", "crown_base_pct"])


func _test_global_patch_routing() -> void:
	_cleanup_files()
	VegetationStyleConfig.save_global({
		"pine_height_m": 25.0, "haze_strength": 0.22, "spruce_albedo_tint": Color(0.2, 0.5, 0.2),
	})
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("family key applied flat", is_equal_approx(float(flat["pine_height_m"]), 25.0))
	_check("family key marked user-set",
		"pine_height_m" in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	_check("global key applied", is_equal_approx(float(flat["haze_strength"]), 0.22))
	_check("global key NOT in family provenance",
		"haze_strength" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	var overs: Dictionary = flat[VegStyleStore.KEY_SPECIES_OVERRIDES]
	_check("subspecies tint routed to species layer",
		overs.has("spruce") and (overs["spruce"] as Dictionary).has("albedo_tint"))
	# save_global merges — a second one-key save must not clobber the first.
	VegetationStyleConfig.save_global({"wind_strength": 0.09})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("second save keeps first keys", is_equal_approx(float(flat["pine_height_m"]), 25.0))
	# Values equal to defaults() are PRUNED, never stored: the Tune-look Apply
	# sends every slider key, and storing untouched ones as user family edits
	# would shadow every SPECS subspecies variant forever.
	var defaults: Dictionary = VegetationStyleConfig.defaults()
	VegetationStyleConfig.save_global({"deciduous_crown_width_m": float(defaults["deciduous_crown_width_m"])})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("defaults-equal value never becomes a user family key",
		"deciduous_crown_width_m" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	# ...and a key moved away then moved BACK to default is erased again.
	VegetationStyleConfig.save_global({"pine_height_m": float(defaults["pine_height_m"])})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("reverting a key to its default prunes the stored edit",
		"pine_height_m" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	_check("pruned key reads back the default",
		is_equal_approx(float(flat["pine_height_m"]), float(defaults["pine_height_m"])))
	# A species-layer entry for a GENERIC family id ("Save as species default"
	# on plain Deciduous) is the WEAKEST user layer: applies when nothing else
	# is tuned, yields to any user family edit, never leaks onto subspecies.
	# Un-gated it outranked per-map family edits forever — "my per-map tuning
	# does nothing".
	VegStyleStore.save_species_override("deciduous", {"height_m": 20.0})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	var generic := VegSpeciesCatalog.settings_with_variant("deciduous", flat,
		VegetationCardFactory.SPECS)
	_check("generic default applies with no family edit",
		is_equal_approx(float(generic["deciduous_height_m"]), 20.0))
	var birch := VegSpeciesCatalog.settings_with_variant("birch", flat,
		VegetationCardFactory.SPECS)
	_check("generic default never leaks onto subspecies",
		is_equal_approx(float(birch["deciduous_height_m"]),
			float(VegetationCardFactory.SPECS["birch"]["height_m"])),
		"birch height %.2f" % float(birch["deciduous_height_m"]))
	VegetationStyleConfig.save_global({"deciduous_height_m": 17.5})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	generic = VegSpeciesCatalog.settings_with_variant("deciduous", flat,
		VegetationCardFactory.SPECS)
	_check("family edit beats the generic species default",
		is_equal_approx(float(generic["deciduous_height_m"]), 17.5),
		"got %.2f" % float(generic["deciduous_height_m"]))


func _test_species_override_roundtrip() -> void:
	_cleanup_files()
	# Family-prefixed input (the Tune-look slider form while editing Spruce).
	VegetationStyleConfig.save_species_default("spruce", {
		"pine_height_m": 12.0, "spruce_albedo_tint": Color(0.1, 0.3, 0.1), "hue_jitter": 0.2,
	})
	var over := VegStyleStore.species_override("spruce")
	_check("family prefix stripped", over.has("height_m") and is_equal_approx(float(over["height_m"]), 12.0))
	_check("species tint stripped to unprefixed", over.has("albedo_tint"))
	_check("unprefixed key kept", over.has("hue_jitter"))
	var loaded := VegetationStyleConfig.load_species_default("spruce")
	_check("load re-prefixes dims", loaded.has("pine_height_m"))
	_check("load re-prefixes tint", loaded.has("spruce_albedo_tint"))
	_check("saving Spruce leaves Cedar alone",
		VegStyleStore.species_override("cedar").is_empty())


func _test_variant_precedence() -> void:
	_cleanup_files()
	var specs: Dictionary = VegetationCardFactory.SPECS
	# 1) No user edits: SPECS variant dims finally apply over family defaults.
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	var spruce := VegSpeciesCatalog.settings_with_variant("spruce", flat, specs)
	var fir := VegSpeciesCatalog.settings_with_variant("fir", flat, specs)
	_check("spruce gets SPECS height", is_equal_approx(float(spruce["pine_height_m"]), 21.0),
		"got %s" % str(spruce["pine_height_m"]))
	_check("fir gets SPECS height", is_equal_approx(float(fir["pine_height_m"]), 23.0))
	_check("spruce != fir", not is_equal_approx(
		float(spruce["pine_height_m"]), float(fir["pine_height_m"])))
	var birch := VegSpeciesCatalog.settings_with_variant("birch", flat, specs)
	_check("birch white bark reaches material key",
		birch.has("bark_albedo_tint") and (birch["bark_albedo_tint"] as Color).r > 0.8)
	var maple := VegSpeciesCatalog.settings_with_variant("maple", flat, specs)
	_check("maple SPECS highlight applies",
		(maple["deciduous_highlight_tint"] as Color).is_equal_approx(Color(0.55, 0.35, 0.10)))
	_check("maple SPECS albedo replaces family default",
		(maple["deciduous_albedo_tint"] as Color).is_equal_approx(Color(0.20, 0.40, 0.10)))
	# 2) Generic family species keeps the flat/default values.
	var pine := VegSpeciesCatalog.settings_with_variant("pine", flat, specs)
	_check("generic pine keeps family default", is_equal_approx(float(pine["pine_height_m"]), 17.0))
	# 3) A USER family edit SCALES every variant's SPECS dim (ratio over the
	# family default) instead of replacing it — replacement turned birch,
	# beech and chestnut into byte-identical clones on any fully-tuned map.
	VegetationStyleConfig.save_global({"pine_height_m": 25.5})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	spruce = VegSpeciesCatalog.settings_with_variant("spruce", flat, specs)
	var want := 21.0 * (25.5 / 17.0)  # SPECS spruce × user/default ratio
	_check("user family edit scales SPECS dims",
		absf(float(spruce["pine_height_m"]) - want) < 0.01,
		"got %.3f want %.3f" % [float(spruce["pine_height_m"]), want])
	_check("un-edited dim still from SPECS", is_equal_approx(float(spruce["pine_crown_width_m"]), 6.0))
	var fir2 := VegSpeciesCatalog.settings_with_variant("fir", flat, specs)
	_check("variants stay distinct under a family edit",
		absf(float(spruce["pine_height_m"]) - float(fir2["pine_height_m"])) > 0.05)
	# 4) A species override beats both.
	VegetationStyleConfig.save_species_default("spruce", {"pine_height_m": 9.0})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	spruce = VegSpeciesCatalog.settings_with_variant("spruce", flat, specs)
	_check("species override beats family edit", is_equal_approx(float(spruce["pine_height_m"]), 9.0))
	var cedar := VegSpeciesCatalog.settings_with_variant("cedar", flat, specs)
	var cedar_want := 15.0 * (25.5 / 17.0)
	_check("cedar unaffected by spruce override (scaled SPECS)",
		absf(float(cedar["pine_height_m"]) - cedar_want) < 0.01,
		"got %.3f want %.3f" % [float(cedar["pine_height_m"]), cedar_want])


func _test_variant_meshes_differ() -> void:
	_cleanup_files()
	VegAssetCache.clear()
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	var m_spruce := VegetationCardFactory.mesh_for_canopy_lod("spruce", flat,
		VegetationCardFactory.CanopyLodTier.NEAR)
	var m_fir := VegetationCardFactory.mesh_for_canopy_lod("fir", flat,
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("spruce and fir are distinct meshes", m_spruce != m_fir)
	var h_spruce := m_spruce.get_aabb().size.y
	var h_fir := m_fir.get_aabb().size.y
	_check("spruce and fir differ in height (%.2f vs %.2f)" % [h_spruce, h_fir],
		absf(h_spruce - h_fir) > 0.1)


## v3 FRESH START: legacy v1/v2 style files are never read (the v3 store lives
## in new files), so a machine full of stale styles resolves to pure defaults.
func _test_fresh_start_ignores_legacy() -> void:
	_cleanup_files()
	# Legacy v1 cfg + species-defaults JSON + legacy per-map JSON, all present.
	var cfg := ConfigFile.new()
	cfg.set_value("style", "deciduous_height_m", 55.0)
	cfg.save(VegetationStyleConfig.GLOBAL_PATH + TEST_SUFFIX)
	var f := FileAccess.open(VegetationStyleConfig.SPECIES_DEFAULTS_PATH + TEST_SUFFIX,
		FileAccess.WRITE)
	f.store_string(JSON.stringify({"spruce": {"pine_height_m": 3.0}}))
	f.close()
	var f2 := FileAccess.open(VegStyleStore.legacy_map_path(T_LAT, T_LON), FileAccess.WRITE)
	f2.store_string(JSON.stringify({"deciduous_height_m": 44.0}))
	f2.close()
	VegStyleStore.invalidate_cache()
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	var defaults: Dictionary = VegetationStyleConfig.defaults()
	_check("legacy files never resolve",
		is_equal_approx(float(flat["deciduous_height_m"]), float(defaults["deciduous_height_m"])),
		"got %s" % str(flat["deciduous_height_m"]))
	_check("legacy files leave no provenance",
		(flat[VegStyleStore.KEY_USER_FAMILY] as Array).is_empty())
	_check("legacy species defaults never resolve",
		not (flat[VegStyleStore.KEY_SPECIES_OVERRIDES] as Dictionary).has("spruce"))


## An old-VERSION v3-path file (wrong veg_style_version) is ignored, not parsed.
func _test_stale_version_ignored() -> void:
	_cleanup_files()
	var f := FileAccess.open(VegStyleStore.global_v2_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify({"veg_style_version": 2,
		"global": {}, "family": {"deciduous": {"height_m": 60.0}}, "species": {}}))
	f.close()
	VegStyleStore.invalidate_cache()
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("stale-version store is ignored",
		"deciduous_height_m" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))


func _test_layer_sparse() -> void:
	var layer := VegetationLayer.create_empty()
	# ≤v2 payload: settings deltas + a per-record card_settings snapshot, both
	# carrying RETIRED keys. Fresh start keeps the record, drops the styling.
	layer.deserialize({"version": 2, "bulk": {"deciduous": [
		{"x": 1.0, "z": 2.0, "yaw": 0.5, "scale": 1.2,
			"card_settings": {"deciduous_canopy_w": 9.9}},
	]}, "hero": [], "settings": {"deciduous_canopy_w": 13.7}})
	_check("v2 settings deltas dropped (fresh start)", layer.user_settings().is_empty(),
		"got %s" % str(layer.user_settings().keys()))
	var recs: Array = layer.bulk.get("deciduous", [])
	_check("painted record survives", recs.size() == 1
		and is_equal_approx(float((recs[0] as Dictionary).get("scale", 0.0)), 1.2))
	_check("record card_settings stripped",
		not (recs[0] as Dictionary).has("card_settings"))
	# v3 round-trip keeps fresh deltas.
	var layer3 := VegetationLayer.create_empty()
	layer3.apply_settings({"deciduous_height_m": 18.0})
	var out := layer3.serialize()
	_check("serialize marks v3", int(out["version"]) == VegetationLayer.VERSION)
	var layer4 := VegetationLayer.create_empty()
	layer4.deserialize(out)
	_check("v3 round-trip keeps sparse deltas",
		is_equal_approx(float(layer4.user_settings().get("deciduous_height_m", 0.0)), 18.0))
	layer4.erase_settings_keys(["deciduous_height_m"])
	_check("erase_settings_keys clears the delta", layer4.user_settings().is_empty())
	# get_settings() still returns the full fallback dict for legacy readers.
	_check("get_settings stays complete",
		layer4.get_settings().has("pine_height_m"))
