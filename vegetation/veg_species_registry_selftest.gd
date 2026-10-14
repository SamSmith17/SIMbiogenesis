extends SceneTree

## Headless self-test for the Phase 5 species registry, exotic builders and
## climate envelopes. Pure / offline.
## Run with:
##   godot --headless --path . --script vegetation/veg_species_registry_selftest.gd

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_registry_schema()
	_test_facade_parity()
	_test_families_resolve()
	_test_phenology()
	_test_climate_envelopes()
	_test_food_data()
	_test_exotic_meshes()
	_test_photocard_hook()
	if _failures == 0:
		print("VEG SPECIES REGISTRY SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG SPECIES REGISTRY SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_registry_schema() -> void:
	var ids := VegSpeciesRegistry.all_ids()
	_check("registry loads", ids.size() >= 25, "got %d" % ids.size())
	for id in ids:
		var e := VegSpeciesRegistry.entry(id)
		_check("%s has family" % id, not str(e.get("family", "")).is_empty())
		_check("%s family is a mesh family" % id,
			str(e.get("family")) in VegSpeciesCatalog.MESH_FAMILIES,
			"got %s" % str(e.get("family")))
		_check("%s phenology known" % id,
			VegSpeciesRegistry.PHENOLOGY_DECIDUOUSNESS.has(str(e.get("phenology", ""))),
			"got %s" % str(e.get("phenology")))
		var c := VegSpeciesRegistry.climate(id)
		if not c.is_empty():
			_check("%s lat range ordered" % id,
				float(c.get("abs_lat_min", 0.0)) <= float(c.get("abs_lat_max", 90.0)))
		_check("%s growth positive" % id, VegSpeciesRegistry.growth_years(id) > 0.0)
		var fd := VegSpeciesRegistry.food(id)
		if not fd.is_empty():
			_check("%s kcal positive" % id, float(fd.get("kcal_per_kg", 0.0)) > 0.0)
			_check("%s yield positive" % id, float(fd.get("yield_kg_per_year", 0.0)) > 0.0)


func _test_facade_parity() -> void:
	# Legacy ids keep their legacy labels/families through the facade.
	_check("legacy spruce family", VegSpeciesCatalog.mesh_family("spruce") == "pine")
	_check("legacy label", VegSpeciesCatalog.label_for("joshua_tree") == "Joshua tree")
	# Registry species resolve through the same facade calls.
	_check("mango is paintable", VegSpeciesCatalog.is_paintable("mango"))
	_check("saguaro family via facade", VegSpeciesCatalog.mesh_family("saguaro") == "cactus")
	_check("coconut label via facade",
		VegSpeciesCatalog.label_for("coconut_palm") == "Coconut palm")
	_check("selectable ids include palms",
		"coconut_palm" in VegSpeciesCatalog.all_selectable_ids())
	_check("selectable ids include cacti",
		"saguaro" in VegSpeciesCatalog.all_selectable_ids())


func _test_families_resolve() -> void:
	_check("palm is a real family now", VegSpeciesCatalog.mesh_family("palm") == "palm")
	_check("cactus is a real family now", VegSpeciesCatalog.mesh_family("cactus") == "cactus")
	_check("banana rides deciduous builder", VegSpeciesCatalog.mesh_family("banana") == "deciduous")
	# Every selectable id must produce a mesh (no builder holes).
	for id in VegSpeciesCatalog.all_selectable_ids():
		var mesh := VegetationCardFactory.mesh_for_species(id, {})
		_check("%s builds a mesh" % id, mesh != null and mesh.get_surface_count() >= 1)


func _test_phenology() -> void:
	# The palm winter-drop bug: palms/tropicals must be (near-)evergreen.
	_check("palm deciduousness ~0",
		VegSpeciesRegistry.deciduousness("coconut_palm") < 0.1,
		"got %.2f" % VegSpeciesRegistry.deciduousness("coconut_palm"))
	_check("mango evergreen", VegSpeciesRegistry.deciduousness("mango") < 0.1)
	_check("maple fully deciduous",
		is_equal_approx(VegSpeciesRegistry.deciduousness("maple"), 1.0))
	_check("spruce conifer",
		is_equal_approx(VegSpeciesRegistry.deciduousness("spruce"), 0.0))
	_check("orange keeps leaves (evergreen citrus)",
		VegSpeciesRegistry.deciduousness("orange") < 0.1)
	_check("no registry opinion -> -1",
		VegSpeciesRegistry.deciduousness("no_such_species") < 0.0)

	# deciduousness_for is the ONE renderer-facing resolution (registry first,
	# string fallback second) — the Tune-look preview once kept its own copy
	# that skipped the registry, so spruce/fir/cedar/redwood previewed at 0.8
	# and palm at 1.0. Every named conifer must resolve evergreen through it.
	for conifer in ["pine", "spruce", "fir", "cedar", "redwood"]:
		_check("%s resolves evergreen via deciduousness_for" % conifer,
			VegSpeciesRegistry.deciduousness_for(conifer) < 0.1,
			"got %.2f" % VegSpeciesRegistry.deciduousness_for(conifer))
	_check("palm resolves evergreen via deciduousness_for",
		VegSpeciesRegistry.deciduousness_for("coconut_palm") < 0.1)
	_check("deciduous family resolves 1.0",
		is_equal_approx(VegSpeciesRegistry.deciduousness_for("deciduous"), 1.0))
	_check("grass resolves 0.0",
		VegSpeciesRegistry.deciduousness_for("grass_lawn") < 0.1)
	_check("unknown species falls back to 0.8",
		is_equal_approx(VegSpeciesRegistry.deciduousness_for("mystery_bush_x"), 0.8))
	# The bulk-name parser feeding the env-sync fallback: a chunk-suffixed name
	# must yield the bare species (a raw substr(5) yielded "spruce_0_3_4",
	# missed the registry, and rendered the batch 80% deciduous).
	_check("bulk name resolves species not suffix",
		VegetationRuntime.species_from_bulk_name("Bulk_spruce_0_3_4") == "spruce",
		VegetationRuntime.species_from_bulk_name("Bulk_spruce_0_3_4"))


func _test_climate_envelopes() -> void:
	_check("no coconut at 48N", not VegSpeciesRegistry.species_allowed_at("coconut_palm", 48.3))
	_check("coconut in the tropics", VegSpeciesRegistry.species_allowed_at("coconut_palm", 9.0))
	_check("no spruce in the tropics", not VegSpeciesRegistry.species_allowed_at("spruce", 5.0))
	_check("spruce in the boreal", VegSpeciesRegistry.species_allowed_at("spruce", 60.0))
	_check("saguaro in the Sonoran band", VegSpeciesRegistry.species_allowed_at("saguaro", 33.0))
	_check("no saguaro at 50N", not VegSpeciesRegistry.species_allowed_at("saguaro", 50.0))
	_check("southern hemisphere uses abs lat",
		VegSpeciesRegistry.species_allowed_at("coconut_palm", -9.0))
	# Weight filtering: tropical biome mix at 48N loses its palms but never
	# empties; unknown ids pass through.
	var w := {"palm": 0.45, "deciduous": 0.45, "shrub": 0.10}
	var filtered := VegSpeciesRegistry.filter_weights_by_climate(w, 48.3)
	_check("palm dropped at 48N", not filtered.has("palm"))
	_check("deciduous kept at 48N", filtered.has("deciduous"))
	var all_bad := {"coconut_palm": 1.0}
	_check("never empties a forest",
		VegSpeciesRegistry.filter_weights_by_climate(all_bad, 60.0).has("coconut_palm"))
	# The generator applies the filter to biome weights: a temperate-lat ctx
	# must not scatter palms even though the tropical table lists them.
	var state := AutoVegetationGenerator.prepare_context(
		{"polygons": [], "tree_points": [], "tree_rows": []},
		{"latitude": 48.3, "seed": 1, "exclusions": []})
	_check("prepare_context filters biome weights",
		not (state.biome.get("weights", {}) as Dictionary).has("coconut_palm"))
	var trop := AutoVegetationGenerator.prepare_context(
		{"polygons": [], "tree_points": [], "tree_rows": []},
		{"latitude": 9.0, "seed": 1, "exclusions": []})
	_check("tropical ctx keeps palm weight",
		(trop.biome.get("weights", {}) as Dictionary).has("palm"))


func _test_food_data() -> void:
	var foods := VegSpeciesRegistry.food_ids()
	_check("food species exist", foods.size() >= 8, "got %d" % foods.size())
	for id in ["apple", "walnut", "coconut_palm", "date_palm", "mango", "olive"]:
		_check("%s is a food species" % id, VegSpeciesRegistry.is_food_species(id))
	_check("harvest window plain", VegSpeciesRegistry.in_harvest_window("apple", 270))
	_check("harvest window outside", not VegSpeciesRegistry.in_harvest_window("apple", 100))
	# Orange wraps the new year (335 -> 90).
	_check("wrapped window before NY", VegSpeciesRegistry.in_harvest_window("orange", 350))
	_check("wrapped window after NY", VegSpeciesRegistry.in_harvest_window("orange", 30))
	_check("wrapped window outside", not VegSpeciesRegistry.in_harvest_window("orange", 200))


func _test_exotic_meshes() -> void:
	VegAssetCache.clear()
	# Generic "palm" has NO shipped photocard, so it exercises the procedural
	# frond builder; coconut/date/fan ship photocards (full swap, 1 surface).
	var palm := VegetationCardFactory.mesh_for_species("palm", {})
	_check("procedural palm has bark + frond surfaces", palm.get_surface_count() == 2)
	_check("procedural palm is tall (%.1f m)" % palm.get_aabb().size.y,
		palm.get_aabb().size.y > 8.0)
	var coco := VegetationCardFactory.mesh_for_species("coconut_palm", {})
	_check("shipped coconut photocard swaps in (1 surface)", coco.get_surface_count() == 1)
	var aabb := coco.get_aabb()
	_check("coconut palm is tall (%.1f m)" % aabb.size.y, aabb.size.y > 10.0)
	var saguaro := VegetationCardFactory.mesh_for_species("saguaro", {})
	_check("saguaro single surface", saguaro.get_surface_count() == 1)
	_check("saguaro taller than wide",
		saguaro.get_aabb().size.y > saguaro.get_aabb().size.x * 0.9)
	var pear := VegetationCardFactory.mesh_for_species("prickly_pear", {})
	_check("prickly pear is low", pear.get_aabb().size.y < 2.5)
	var fan := VegetationCardFactory.mesh_for_species("fan_palm", {})
	_check("palm variants differ", fan.get_aabb().size.y < aabb.size.y - 1.0,
		"fan %.1f vs coconut %.1f" % [fan.get_aabb().size.y, aabb.size.y])
	# Palms must NOT be classified deciduous by the runtimes anymore.
	_check("palm not aliased to deciduous",
		AutoVegetationRuntime._resolve_species("palm") == "palm")


func _test_photocard_hook() -> void:
	var dir := ProjectSettings.globalize_path(VegSpeciesRegistry.PHOTOCARD_USER_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var maple_path := "%s/maple.png" % dir
	var saguaro_path := "%s/saguaro.png" % dir
	img.save_png(maple_path)
	img.save_png(saguaro_path)
	VegSpeciesRegistry.reset()
	VegAssetCache.clear()
	_check("photocard texture found", VegSpeciesRegistry.photocard_texture("maple") != null)
	# Canopy families: NEAR keeps the procedural leaf shells (a flat card at
	# 10 m is worse); the photocard rides the FAR tier only.
	var near := VegetationCardFactory.mesh_for_canopy_lod("maple", {},
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("canopy NEAR stays procedural (2 surfaces)", near.get_surface_count() == 2,
		"got %d" % near.get_surface_count())
	var far := VegetationCardFactory.mesh_for_canopy_lod("maple", {},
		VegetationCardFactory.CanopyLodTier.FAR)
	_check("canopy FAR becomes the photocard (1 surface)", far.get_surface_count() == 1,
		"got %d" % far.get_surface_count())
	# Non-canopy families swap the whole species mesh.
	var cactus := VegetationCardFactory.mesh_for_species("saguaro", {})
	_check("non-canopy photocard full swap (1 surface)", cactus.get_surface_count() == 1)
	_check("photocard species carries its material",
		VegetationCardFactory.mesh_has_surface_materials("saguaro"))
	DirAccess.remove_absolute(maple_path)
	DirAccess.remove_absolute(saguaro_path)
	VegSpeciesRegistry.reset()
	VegAssetCache.clear()
	_check("removal restores procedural FAR (2 surfaces)",
		VegetationCardFactory.mesh_for_canopy_lod("maple", {},
			VegetationCardFactory.CanopyLodTier.FAR).get_surface_count() == 2)
	_check("removal restores procedural cactus (no embedded material)",
		not VegetationCardFactory.mesh_has_surface_materials("saguaro"))
