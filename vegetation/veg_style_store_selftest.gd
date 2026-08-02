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
	_test_migration_global_v1()
	_test_migration_map_v1()
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
	_check("pine key splits", VegStyleStore.split_flat_key("pine_card_w") == ["pine", "card_w"])
	_check("unprefixed key stays global",
		VegStyleStore.split_flat_key("haze_strength") == ["", "haze_strength"])
	_check("deciduous compound key splits",
		VegStyleStore.split_flat_key("deciduous_branch_count") == ["deciduous", "branch_count"])


func _test_global_patch_routing() -> void:
	_cleanup_files()
	VegetationStyleConfig.save_global({
		"pine_card_w": 1.30, "haze_strength": 0.22, "spruce_albedo_tint": Color(0.2, 0.5, 0.2),
	})
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("family key applied flat", is_equal_approx(float(flat["pine_card_w"]), 1.30))
	_check("family key marked user-set",
		"pine_card_w" in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	_check("global key applied", is_equal_approx(float(flat["haze_strength"]), 0.22))
	_check("global key NOT in family provenance",
		"haze_strength" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	var overs: Dictionary = flat[VegStyleStore.KEY_SPECIES_OVERRIDES]
	_check("subspecies tint routed to species layer",
		overs.has("spruce") and (overs["spruce"] as Dictionary).has("albedo_tint"))
	# save_global merges — a second one-key save must not clobber the first.
	VegetationStyleConfig.save_global({"wind_strength": 0.09})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("second save keeps first keys", is_equal_approx(float(flat["pine_card_w"]), 1.30))
	# Values equal to defaults() are PRUNED, never stored: the Tune-look Apply
	# sends every slider key, and storing untouched ones as user family edits
	# would shadow every SPECS subspecies variant forever.
	var defaults: Dictionary = VegetationStyleConfig.defaults()
	VegetationStyleConfig.save_global({"deciduous_canopy_w": float(defaults["deciduous_canopy_w"])})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("defaults-equal value never becomes a user family key",
		"deciduous_canopy_w" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	# ...and a key moved away then moved BACK to default is erased again.
	VegetationStyleConfig.save_global({"pine_card_w": float(defaults["pine_card_w"])})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("reverting a key to its default prunes the stored edit",
		"pine_card_w" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	_check("pruned key reads back the default",
		is_equal_approx(float(flat["pine_card_w"]), float(defaults["pine_card_w"])))


func _test_species_override_roundtrip() -> void:
	_cleanup_files()
	# Family-prefixed input (the Tune-look slider form while editing Spruce).
	VegetationStyleConfig.save_species_default("spruce", {
		"pine_card_w": 0.66, "spruce_albedo_tint": Color(0.1, 0.3, 0.1), "hue_jitter": 0.2,
	})
	var over := VegStyleStore.species_override("spruce")
	_check("family prefix stripped", over.has("card_w") and is_equal_approx(float(over["card_w"]), 0.66))
	_check("species tint stripped to unprefixed", over.has("albedo_tint"))
	_check("unprefixed key kept", over.has("hue_jitter"))
	var loaded := VegetationStyleConfig.load_species_default("spruce")
	_check("load re-prefixes dims", loaded.has("pine_card_w"))
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
	_check("spruce gets SPECS width", is_equal_approx(float(spruce["pine_card_w"]), 0.95),
		"got %s" % str(spruce["pine_card_w"]))
	_check("fir gets SPECS width", is_equal_approx(float(fir["pine_card_w"]), 0.78))
	_check("spruce != fir", not is_equal_approx(
		float(spruce["pine_card_h"]), float(fir["pine_card_h"])))
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
	_check("generic pine keeps family default", is_equal_approx(float(pine["pine_card_w"]), 0.85))
	# 3) A USER family edit beats SPECS for every variant.
	VegetationStyleConfig.save_global({"pine_card_w": 1.5})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	spruce = VegSpeciesCatalog.settings_with_variant("spruce", flat, specs)
	_check("user family edit beats SPECS", is_equal_approx(float(spruce["pine_card_w"]), 1.5))
	_check("un-edited dim still from SPECS", is_equal_approx(float(spruce["pine_card_h"]), 5.2))
	# 4) A species override beats both.
	VegetationStyleConfig.save_species_default("spruce", {"pine_card_w": 0.5})
	flat = VegStyleStore.flat_merged(T_LAT, T_LON)
	spruce = VegSpeciesCatalog.settings_with_variant("spruce", flat, specs)
	_check("species override beats family edit", is_equal_approx(float(spruce["pine_card_w"]), 0.5))
	var cedar := VegSpeciesCatalog.settings_with_variant("cedar", flat, specs)
	_check("cedar unaffected by spruce override", is_equal_approx(float(cedar["pine_card_w"]), 1.5))


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


func _test_migration_global_v1() -> void:
	_cleanup_files()
	# Synthetic v1 global cfg: a full defaults dump (the old terrain-options
	# clobber bug) + ONE real user delta.
	var cfg := ConfigFile.new()
	for k in VegetationStyleConfig.defaults():
		cfg.set_value("style", str(k), VegetationStyleConfig.defaults()[k])
	cfg.set_value("style", "deciduous_canopy_w", 14.5)
	cfg.save(VegetationStyleConfig.GLOBAL_PATH + TEST_SUFFIX)
	# Synthetic v1 species defaults: family-prefixed keys under "spruce".
	var f := FileAccess.open(VegetationStyleConfig.SPECIES_DEFAULTS_PATH + TEST_SUFFIX,
		FileAccess.WRITE)
	f.store_string(JSON.stringify({"spruce": {"pine_card_w": 0.7,
		"spruce_albedo_tint": [0.1, 0.4, 0.1, 1.0]}}))
	f.close()
	VegStyleStore.invalidate_cache()
	var store := VegStyleStore.load_global_store()
	var fams: Dictionary = store["family"]
	_check("migration keeps the real delta",
		fams.has("deciduous") and is_equal_approx(float((fams["deciduous"] as Dictionary).get("canopy_w", 0.0)), 14.5))
	var pine_fam: Dictionary = fams.get("pine", {})
	_check("migration drops the defaults dump", not pine_fam.has("card_w"),
		"family.pine=%s" % str(pine_fam))
	var sps: Dictionary = store["species"]
	_check("v1 species entry became unprefixed override",
		sps.has("spruce") and (sps["spruce"] as Dictionary).has("card_w"))
	_check("v1 species tint became unprefixed",
		(sps["spruce"] as Dictionary).has("albedo_tint"))
	_check("v2 file written after migration",
		FileAccess.file_exists(VegStyleStore.global_v2_path()))


func _test_migration_map_v1() -> void:
	_cleanup_files()
	var f := FileAccess.open(VegStyleStore.legacy_map_path(T_LAT, T_LON), FileAccess.WRITE)
	var v1 := VegetationStyleConfig.to_serializable(VegetationStyleConfig.defaults())
	v1["auto_density_scale"] = 1.8
	v1["pine_card_h"] = 6.0
	f.store_string(JSON.stringify(v1))
	f.close()
	var flat := VegStyleStore.flat_merged(T_LAT, T_LON)
	_check("map delta migrated (global key)", is_equal_approx(float(flat["auto_density_scale"]), 1.8))
	_check("map delta migrated (family key)", is_equal_approx(float(flat["pine_card_h"]), 6.0))
	_check("map defaults dump dropped",
		"deciduous_canopy_w" not in (flat[VegStyleStore.KEY_USER_FAMILY] as Array))
	_check("map v2 file written",
		FileAccess.file_exists(VegStyleStore.map_v2_path(T_LAT, T_LON)))


func _test_layer_sparse() -> void:
	var layer := VegetationLayer.create_empty()
	# v1 payload: complete settings dict with one real delta.
	var v1_settings := VegetationLayer.default_settings()
	v1_settings["deciduous_canopy_w"] = 13.7
	layer.deserialize({"version": 1, "bulk": {}, "hero": [], "settings": v1_settings})
	var deltas := layer.user_settings()
	_check("v1 layer sparse-ified to one delta", deltas.size() == 1,
		"got %d: %s" % [deltas.size(), str(deltas.keys())])
	_check("the delta survived", is_equal_approx(float(deltas.get("deciduous_canopy_w", 0.0)), 13.7))
	var out := layer.serialize()
	_check("serialize marks v2", int(out["version"]) == VegetationLayer.VERSION)
	_check("serialize stores sparse", (out["settings"] as Dictionary).size() == 1)
	# v2 round-trip.
	var layer2 := VegetationLayer.create_empty()
	layer2.deserialize(out)
	_check("v2 round-trip keeps sparse deltas",
		layer2.user_settings().size() == 1)
	# erase_settings_keys drops re-expressed deltas.
	layer2.erase_settings_keys(["deciduous_canopy_w"])
	_check("erase_settings_keys clears the delta", layer2.user_settings().is_empty())
	# get_settings() still returns the full fallback dict for legacy readers.
	_check("get_settings stays complete",
		layer2.get_settings().has("pine_card_w"))
