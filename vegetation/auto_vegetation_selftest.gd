extends SceneTree

## Headless self-test for the auto-vegetation stack (AutoVegetationLayer /
## Generator / Runtime). Pure / offline — no network.
## Run with:
##   godot --headless --path . --script vegetation/auto_vegetation_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise. Grows per phase (biome bands,
## scatter counts, exclusion logic, gate allow/deny).

const VegService := preload("res://core/terrain/vegetation_osm_service.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_layer()
	_test_generator_empty()
	_test_runtime_render()
	_test_biome()
	_test_overpass_parse()
	_test_osm_tree_hero()
	_test_grass_tune_style()
	_test_scatter_and_exclusion()
	_test_runtime_validity()
	_test_imagery_gate()
	_test_bulk_foot_offset()
	_test_auto_veg_edits()
	_test_auto_veg_patches()
	_test_card_orientation()
	_test_deciduous_split_mesh()
	_test_exclusion_builder()
	_test_exclusion_index()
	_test_performance_caps()
	_test_osm_polygon_cap()
	_test_veg_multipolygon_outers_only()
	_test_batched_scatter()
	_test_poisson_performance()
	_test_forest_routing()
	_test_forest_edits()
	_test_grass_species()
	_test_grass_builder()
	_test_leaf_type_weights()
	_test_mix_weights()
	_test_osm_v4_kinds()
	_test_vegetation_undo()
	_test_ground_y_monotonic()
	_test_pick_species_grass()
	_test_height_parse()
	_test_hero_metrics_composition()
	_test_hero_scale_clamp()
	_test_tree_point_height_clamp()
	_test_open_area_exclusion()
	_test_budget_priority()
	_test_grass_detail_radius()
	_test_poly_stats()
	_test_neutral_bulk_wins()
	_test_feature_scatter_order()
	_test_gap_fill_bounded()
	_test_reground_threads_growth()
	_test_osm_key_match()
	_test_forest_params_coverage()
	_test_asset_cache_and_fade()
	_test_area_fill_edits()
	_test_area_fill_scatter()
	_test_incremental_chunk_rebuild()
	_test_deciduous_branch_distribution()
	_test_preview_parity()
	if _failures == 0:
		print("AUTO-VEG SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("AUTO-VEG SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_layer() -> void:
	var layer := AutoVegetationLayer.create_empty()
	_check("fresh layer empty", layer.is_empty())
	_check("add_bulk ok", layer.add_bulk("pine", 1.0, 2.0, 0.0, 1.0, 12.0))
	_check("add_hero ok", layer.add_hero("pine_1", 3.0, 4.0, 0.0, 1.0, 13.0))
	_check("total_bulk counts", layer.total_bulk() == 1, "got %d" % layer.total_bulk())
	_check("slots lists pine", layer.slots().has("pine"))
	_check("all_points has both", layer.all_points().size() == 2,
		"got %d" % layer.all_points().size())
	layer.clear()
	_check("clear empties", layer.is_empty())


func _test_generator_empty() -> void:
	var layer := AutoVegetationGenerator.generate({}, {"latitude": 47.6})
	_check("empty payload -> empty layer", layer != null and layer.is_empty())


func _test_runtime_render() -> void:
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var layer := AutoVegetationLayer.create_empty()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0, 10.0)
	layer.add_bulk("shrub", 5.0, 5.0, 0.0, 1.0, 1.0)
	var ground := func(_x: float, _z: float) -> float: return 0.0
	AutoVegetationRuntime.rebuild(terrain, layer, ground)
	var root := terrain.get_node_or_null(AutoVegetationRuntime.ROOT_NAME)
	_check("AutoVegetation node created", root != null)
	if root != null:
		# Names include LOD tier + spatial chunk: Bulk_pine_0_0_0, Bulk_shrub_0_0, …
		var has_pine := false
		var has_shrub := false
		for c in root.get_children():
			var nm := str(c.name)
			if nm.begins_with("Bulk_pine"):
				has_pine = true
			if nm.begins_with("Bulk_shrub"):
				has_shrub = true
		_check("pine multimesh built", has_pine)
		_check("shrub multimesh built", has_shrub)
	# Slot alias resolution falls back to a known card species.
	_check("conifer -> pine", AutoVegetationRuntime._resolve_species("conifer") == "pine")
	_check("unknown -> deciduous", AutoVegetationRuntime._resolve_species("zzz") == "deciduous")
	AutoVegetationRuntime.clear(terrain)
	terrain.queue_free()


func _test_biome() -> void:
	_check("tropical band", BiomePalette.for_location(10.0).biome == "tropical")
	_check("subtropical band", BiomePalette.for_location(30.0).biome == "subtropical")
	_check("temperate band", BiomePalette.for_location(47.6).biome == "temperate")
	_check("boreal band", BiomePalette.for_location(64.0).biome == "boreal")
	_check("southern hemisphere uses abs lat", BiomePalette.for_location(-47.6).biome == "temperate")
	_check("worldcover shrub override",
		BiomePalette.for_location(47.6, BiomePalette.WC_SHRUB).biome == "shrubland")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	_check("pick_species returns a weighted key",
		BiomePalette.pick_species({"pine": 1.0}, rng) == "pine")


## Pure parse of a synthetic Overpass document (no network).
func _test_overpass_parse() -> void:
	var clat := 47.6
	var clon := -122.3
	var d := 0.001  # ~111 m
	var doc := {"elements": [
		{"type": "node", "id": 1, "lat": clat - d, "lon": clon - d},
		{"type": "node", "id": 2, "lat": clat - d, "lon": clon + d},
		{"type": "node", "id": 3, "lat": clat + d, "lon": clon + d},
		{"type": "node", "id": 4, "lat": clat + d, "lon": clon - d},
		{"type": "way", "id": 100, "nodes": [1, 2, 3, 4, 1], "tags": {"natural": "wood"}},
		{"type": "node", "id": 5, "lat": clat, "lon": clon,
			"tags": {"natural": "tree", "height": "12 m"}},
		{"type": "way", "id": 101, "nodes": [1, 2], "tags": {"natural": "tree_row"}},
	]}
	var payload: Dictionary = VegService._parse_overpass(doc, clat, clon)
	_check("parsed one polygon", (payload["polygons"] as Array).size() == 1,
		"got %d" % (payload["polygons"] as Array).size())
	if not (payload["polygons"] as Array).is_empty():
		_check("polygon kind wood", str(payload["polygons"][0]["kind"]) == "wood")
	_check("parsed one tree point", (payload["tree_points"] as Array).size() == 1)
	if not (payload["tree_points"] as Array).is_empty():
		_check("tree height tag parsed ~12",
			absf(float(payload["tree_points"][0]["height_m"]) - 12.0) < 0.01)
		_check("tree point carries OSM tags",
			(payload["tree_points"][0] as Dictionary).get("tags", {}).has("natural"))
	_check("parsed one tree row", (payload["tree_rows"] as Array).size() == 1)

	# Grass / meadow polygons map to grass_lawn / grass_field kinds.
	var grass_doc := {"elements": [
		{"type": "node", "id": 10, "lat": clat - d, "lon": clon - d},
		{"type": "node", "id": 11, "lat": clat - d, "lon": clon + d},
		{"type": "node", "id": 12, "lat": clat + d, "lon": clon + d},
		{"type": "node", "id": 13, "lat": clat + d, "lon": clon - d},
		{"type": "way", "id": 200, "nodes": [10, 11, 12, 13, 10],
			"tags": {"landuse": "grass"}},
		{"type": "way", "id": 201, "nodes": [10, 11, 12, 13, 10],
			"tags": {"landuse": "meadow"}},
	]}
	var grass_payload: Dictionary = VegService._parse_overpass(grass_doc, clat, clon)
	_check("parsed grass polygons", (grass_payload["polygons"] as Array).size() == 2)
	if (grass_payload["polygons"] as Array).size() >= 2:
		_check("landuse=grass -> grass_lawn",
			str(grass_payload["polygons"][0]["kind"]) == "grass_lawn")
		_check("landuse=meadow -> grass_field",
			str(grass_payload["polygons"][1]["kind"]) == "grass_field")


func _test_osm_tree_hero() -> void:
	_check("horse chestnut maps to deciduous_low",
		HeroTreeCatalog.preset_for_osm_tree_tags(
			{"species": "Aesculus hippocastanum", "natural": "tree"}) == "deciduous_low")
	_check("height tag maps to deciduous_low",
		HeroTreeCatalog.preset_for_osm_tree_tags({"natural": "tree", "height": "20"}) == "deciduous_low")
	var ctx := {"latitude": 42.4, "seed": 7, "exclusions": []}
	var payload := {
		"polygons": [],
		"tree_points": [{
			"pos": Vector2(0.0, 0.0),
			"height_m": 24.0,
			"tags": {
				"natural": "tree",
				"species": "Aesculus hippocastanum",
				"height": "24 m",
			},
		}],
		"tree_rows": [],
	}
	var layer := AutoVegetationGenerator.generate(payload, ctx)
	# Mapped OSM tree points now scatter as procedural bulk trees (NOT low-poly GLB
	# heroes) so every deciduous tree shares the one tuned/preset look. A temperate
	# biome tree point must land in a tree slot (deciduous/pine), never shrub/hero.
	_check("OSM tree becomes procedural bulk, not hero", layer.hero.size() == 0,
		"hero=%d bulk=%d" % [layer.hero.size(), layer.total_bulk()])
	_check("OSM tree placed one bulk instance", layer.total_bulk() == 1,
		"bulk=%d" % layer.total_bulk())
	_check("OSM tree bulk is a tree species (not shrub)",
		int((layer.bulk.get("shrub", []) as Array).size()) == 0)
	# Tree-point tags survive veg-cache serialization.
	var ser: Dictionary = VegService._serialize_payload(payload)
	var deser: Dictionary = VegService.deserialize_payload(ser)
	_check("tree point tags round-trip",
		str((deser["tree_points"][0] as Dictionary).get("tags", {}).get("species", ""))
		== "Aesculus hippocastanum")


func _test_grass_tune_style() -> void:
	var lawn_poly := PackedVector2Array([
		Vector2(-40, -40), Vector2(40, -40), Vector2(40, 40), Vector2(-40, 40)])
	var meadow_poly := PackedVector2Array([
		Vector2(-60, -30), Vector2(60, -30), Vector2(60, 30), Vector2(-60, 30)])
	var lawn_payload := {
		"polygons": [{"points": lawn_poly, "kind": "grass_lawn", "tags": {"landuse": "grass"}}],
		"tree_points": [], "tree_rows": [],
	}
	var meadow_payload := {
		"polygons": [{"points": meadow_poly, "kind": "grass_field", "tags": {"landuse": "meadow"}}],
		"tree_points": [], "tree_rows": [],
	}
	var ctx_dense := {
		"latitude": 42.4, "seed": 3, "exclusions": [],
		"style": {"scatter_lawn_field": true, "grass_lawn_card_w": 0.22,
			"auto_density_scale": 2.0, "grass_lawn_bulk_scale": 1.2},
	}
	var ctx_sparse := {
		"latitude": 42.4, "seed": 3, "exclusions": [],
		"style": {"scatter_lawn_field": true, "grass_lawn_card_w": 0.9,
			"auto_density_scale": 0.5, "grass_lawn_bulk_scale": 1.0},
	}
	var dense := AutoVegetationGenerator.generate(lawn_payload, ctx_dense)
	var sparse := AutoVegetationGenerator.generate(lawn_payload, ctx_sparse)
	_check("tune look lawn card_w affects scatter count",
		dense.total_bulk() > sparse.total_bulk(),
		"dense=%d sparse=%d" % [dense.total_bulk(), sparse.total_bulk()])
	var meadow_layer := AutoVegetationGenerator.generate(meadow_payload,
		{"latitude": 42.4, "seed": 5, "exclusions": [],
			"style": {"scatter_lawn_field": true, "grass_field_bulk_scale": 1.4,
				"auto_density_scale": 1.5}})
	_check("meadow scatter uses grass_field slot", meadow_layer.slots().has("grass_field"))
	_check("meadow scatter produces instances", meadow_layer.total_bulk() > 10,
		"got %d" % meadow_layer.total_bulk())
	var skipped := AutoVegetationGenerator.generate(lawn_payload,
		{"latitude": 42.4, "seed": 3, "exclusions": [], "style": {}})
	_check("default skips OSM lawn scatter", skipped.total_bulk() == 0,
		"got %d" % skipped.total_bulk())


func _test_scatter_and_exclusion() -> void:
	# ~200 m square woodland polygon centred on origin (local metres).
	var poly := PackedVector2Array([
		Vector2(-100, -100), Vector2(100, -100), Vector2(100, 100), Vector2(-100, 100)])
	var payload := {
		"polygons": [{"points": poly, "kind": "wood", "tags": {}}],
		"tree_points": [], "tree_rows": [],
	}
	var ctx := {"latitude": 47.6, "seed": 42, "exclusions": []}
	var open_layer := AutoVegetationGenerator.generate(payload, ctx)
	_check("woodland scatter produced trees", open_layer.total_bulk() > 10,
		"got %d" % open_layer.total_bulk())
	# Same polygon as an exclusion mask should suppress nearly everything.
	var ctx_excl := {"latitude": 47.6, "seed": 42, "exclusions": [poly]}
	var blocked := AutoVegetationGenerator.generate(payload, ctx_excl)
	_check("exclusion suppresses scatter", blocked.total_bulk() < open_layer.total_bulk(),
		"open=%d blocked=%d" % [open_layer.total_bulk(), blocked.total_bulk()])

	var lawn_poly := PackedVector2Array([
		Vector2(-40, -40), Vector2(40, -40), Vector2(40, 40), Vector2(-40, 40)])
	var grass_payload := {
		"polygons": [{"points": lawn_poly, "kind": "grass_lawn", "tags": {"landuse": "grass"}}],
		"tree_points": [], "tree_rows": [],
	}
	var grass_ctx := ctx.duplicate(true)
	grass_ctx["style"] = {"scatter_lawn_field": true}
	var grass_layer := AutoVegetationGenerator.generate(grass_payload, grass_ctx)
	_check("OSM grass_lawn scatter produces instances", grass_layer.total_bulk() > 20,
		"got %d" % grass_layer.total_bulk())
	var slots: Array = grass_layer.slots()
	_check("grass scatter uses grass_lawn slot", slots.has("grass_lawn"))


## Confirms the runtime produces a VALID, VISIBLE, ground-placed MultiMesh — the
## exact thing that appeared to render empty in-app despite 10000 generated.
func _test_runtime_validity() -> void:
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var poly := PackedVector2Array([
		Vector2(-100, -100), Vector2(100, -100), Vector2(100, 100), Vector2(-100, 100)])
	var payload := {"polygons": [{"points": poly, "kind": "wood", "tags": {}}],
		"tree_points": [], "tree_rows": []}
	var layer := AutoVegetationGenerator.generate(payload,
		{"latitude": 47.6, "seed": 1, "exclusions": []})
	var ground := func(_x: float, _z: float) -> float: return 12.5
	AutoVegetationRuntime.rebuild(terrain, layer, ground)
	var root := terrain.get_node_or_null("AutoVegetation")
	var mmi: MultiMeshInstance3D = null
	if root != null:
		for c in root.get_children():
			if c is MultiMeshInstance3D:
				mmi = c as MultiMeshInstance3D
				break
	# NOTE: headless dummy RenderingServer does NOT store MultiMesh transforms or
	# compute AABBs, so get_instance_transform()/get_aabb() are unreliable here —
	# we only assert the structural facts that ARE valid in headless.
	_check("runtime built a MultiMeshInstance3D", mmi != null)
	if mmi != null:
		_check("instance_count > 0", mmi.multimesh.instance_count > 0,
			"count=%d" % mmi.multimesh.instance_count)
		_check("mesh assigned", mmi.multimesh.mesh != null)
		var has_mat := mmi.material_override != null
		if not has_mat and mmi.multimesh.mesh != null:
			has_mat = mmi.multimesh.mesh.get_surface_count() > 0 \
				and mmi.multimesh.mesh.surface_get_material(0) != null
		_check("material assigned", has_mat)
		_check("node visible", mmi.visible)
	terrain.queue_free()


func _test_imagery_gate() -> void:
	# 64x64 drape: bottom half (v>=0.5) dark-green canopy, top half bright brown.
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.6, 0.5, 0.3, 1.0))  # bright brown — not vegetation
	for y in range(32, 64):
		for x in 64:
			img.set_pixel(x, y, Color(0.05, 0.18, 0.06, 1.0))  # dark green canopy
	var tex := ImageTexture.create_from_image(img)
	var gate := LandcoverImageryGate.from_texture(tex, 1000.0)  # 1 km square
	_check("gate valid", gate != null and gate.is_valid())
	_check("classifier accepts dark green",
		LandcoverImageryGate.is_vegetation_color(Color(0.05, 0.18, 0.06)))
	_check("classifier rejects bright pixel",
		not LandcoverImageryGate.is_vegetation_color(Color(0.6, 0.7, 0.5)))
	# v = (z + 500)/1000 → z=+200 lands in the green half, z=-200 in the brown half.
	_check("gate vegetated in canopy region", gate.is_vegetated(0.0, 200.0))
	_check("gate clears in bare region", not gate.is_vegetated(0.0, -200.0))
	# Detail patch overrides base drape inside the centre square.
	var detail_img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	detail_img.fill(Color(0.05, 0.18, 0.06, 1.0))
	var detail_tex := ImageTexture.create_from_image(detail_img)
	var dual := LandcoverImageryGate.from_texture(tex, 1000.0, detail_tex, 200.0)
	_check("dual gate vegetated at centre with detail patch",
		dual != null and dual.is_vegetated(0.0, 0.0))
	_check("dual gate bare outside detail uses base",
		dual != null and not dual.is_vegetated(0.0, -400.0))
	_check("canopy_factor higher in canopy",
		gate.canopy_factor(0.0, 200.0) > gate.canopy_factor(0.0, -200.0))
	# Gap-fill with NO OSM polygons should still populate the canopy half only.
	var layer := AutoVegetationGenerator.generate(
		{"polygons": [], "tree_points": [], "tree_rows": []},
		{"latitude": 47.6, "seed": 3, "half_extent_m": 400.0, "exclusions": [], "gate": gate})
	_check("gap-fill produced trees", layer.total_bulk() > 0,
		"got %d" % layer.total_bulk())
	var stray := 0
	for slot in layer.bulk.keys():
		for rec in layer.bulk[slot]:
			if float(rec["z"]) < -20.0:  # tolerate jitter near the boundary
				stray += 1
	_check("gap-fill trees confined to vegetated region", stray == 0,
		"%d trees outside canopy" % stray)


## Bulk card transforms subtract foot_local_y * scale from ground Y (hero parity).
func _test_bulk_foot_offset() -> void:
	var gy := 12.5
	var settings := VegetationLayer.default_settings()
	for species in ["pine", "deciduous", "shrub"]:
		var foot := VegetationCardFactory.foot_local_y(species, settings)
		var scale := 2.4
		var xf := VegetationPaint.build_transform(
			0.0, gy, 0.0, 0.0, scale, false, Vector3.UP, 0.0, foot)
		var want_y := gy - foot * scale - VegetationPaint.GROUND_SINK_M
		_check("bulk foot offset %s" % species, absf(xf.origin.y - want_y) < 0.001,
			"foot=%.3f got y=%.3f want %.3f" % [foot, xf.origin.y, want_y])


func _test_auto_veg_edits() -> void:
	var layer := AutoVegetationLayer.create_empty()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0, 10.0)
	layer.add_bulk("pine", 50.0, 50.0, 0.0, 1.0, 10.0)
	var clear_poly := PackedVector2Array([
		Vector2(-10, -10), Vector2(10, -10), Vector2(10, 10), Vector2(-10, 10)])
	var removed := layer.remove_in_polygon(clear_poly)
	_check("remove_in_polygon counts", removed == 1, "got %d" % removed)
	_check("remove_in_polygon keeps outside", layer.total_bulk() == 1)
	var edits := AutoVegetationEdits.create_empty()
	edits.add_cleared_polygon(clear_poly)
	var roundtrip := AutoVegetationEdits.create_empty()
	roundtrip.deserialize(edits.serialize())
	_check("edits roundtrip one cleared poly", roundtrip.cleared.size() == 1)
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0, 10.0)
	roundtrip.apply_to_layer(layer)
	_check("edits replay clears on regen", layer.total_bulk() == 1,
		"got %d" % layer.total_bulk())


func _test_auto_veg_patches() -> void:
	var layer := AutoVegetationLayer.create_empty()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0, 10.0)
	layer.add_bulk("deciduous", 20.0, 0.0, 0.0, 1.5, 10.0)
	var patch_poly := PackedVector2Array([
		Vector2(-5, -5), Vector2(5, -5), Vector2(5, 5), Vector2(-5, 5)])
	var params := {
		"scale_mul": 2.0,
		"vertical_offset_m": 0.4,
		"deciduous_trunk_h": 5.5,
	}
	var n := layer.apply_patch_in_polygon(patch_poly, params)
	_check("patch hits centre tree", n == 1, "got %d" % n)
	var pine: Dictionary = (layer.bulk["pine"] as Array)[0]
	_check("patch scales instance", absf(float(pine.get("scale", 0.0)) - 2.0) < 0.001)
	_check("patch sets vert_off", absf(float(pine.get("vert_off", 0.0)) - 0.4) < 0.001)
	var decid: Dictionary = (layer.bulk["deciduous"] as Array)[0]
	_check("patch outside poly unchanged", absf(float(decid.get("scale", 0.0)) - 1.5) < 0.001)
	var edits := AutoVegetationEdits.create_empty()
	edits.add_patch(patch_poly, params)
	var roundtrip := AutoVegetationEdits.create_empty()
	roundtrip.deserialize(edits.serialize())
	_check("patch roundtrip", roundtrip.patches.size() == 1)
	layer = AutoVegetationLayer.create_empty()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0, 10.0)
	roundtrip.apply_to_layer(layer)
	_check("patch replay on regen", absf(float((layer.bulk["pine"] as Array)[0]["scale"]) - 2.0) < 0.001)


## Locks canopy-only texture orientation (trunk is a separate bark surface).
func _test_card_orientation() -> void:
	var mat := VegetationCardFactory.material_for_species("deciduous", {})
	var tex := mat.get_shader_parameter("albedo_tex") as Texture2D
	_check("deciduous canopy albedo present", tex != null)
	if tex == null:
		return
	var img := tex.get_image()
	var size := img.get_width()
	var cx := int(size / 2)
	var green_pixels := 0
	for y in size:
		var c := img.get_pixel(cx, y)
		if c.a > 0.3 and c.g > c.r:
			green_pixels += 1
	_check("deciduous canopy is green-dominant", green_pixels > size / 4,
		"green_pixels=%d" % green_pixels)


func _test_deciduous_split_mesh() -> void:
	var mesh := VegetationCardFactory.mesh_for_species("deciduous", {})
	# NEAR-LOD deciduous now builds 3 surfaces: 0 = trunk/branches (bark),
	# 1 = billboard shadow proxy (crown silhouette caster), 2 = leaf-shell canopy.
	_check("deciduous has 3 surfaces", mesh.get_surface_count() == 3,
		"got %d" % mesh.get_surface_count())
	var trunk_arrays := mesh.surface_get_arrays(0)
	# The leaf-shell surface (last) is the VISIBLE canopy; the shadow-proxy
	# cards (surface 1) sit inside it and start higher.
	var canopy_arrays := mesh.surface_get_arrays(mesh.get_surface_count() - 1)
	var trunk_top := 0.0
	for v in trunk_arrays[Mesh.ARRAY_VERTEX]:
		trunk_top = maxf(trunk_top, (v as Vector3).y)
	var canopy_base := INF
	for v in canopy_arrays[Mesh.ARRAY_VERTEX]:
		canopy_base = minf(canopy_base, (v as Vector3).y)
	var canopy_top := -INF
	for v in canopy_arrays[Mesh.ARRAY_VERTEX]:
		canopy_top = maxf(canopy_top, (v as Vector3).y)
	# v3 frame: crown starts at height_m × crown_base_pct — the clump floor
	# keeps foliage ABOVE it (a visible trunk is the "crown base %" promise)
	# and within about a clump radius of it.
	var d_spec: Dictionary = VegetationCardFactory.SPECS["deciduous"]
	var crown_bottom := float(d_spec["height_m"]) * float(d_spec["crown_base_pct"]) / 100.0
	_check("canopy stays above the crown base (visible trunk)",
		canopy_base >= crown_bottom - 0.6,
		"crown_bottom=%.2f canopy_base=%.2f" % [crown_bottom, canopy_base])
	_check("canopy still starts NEAR the crown base",
		canopy_base <= crown_bottom + 2.5,
		"crown_bottom=%.2f canopy_base=%.2f" % [crown_bottom, canopy_base])
	# ...and never dips below the trunk base, or every instance sinks: the
	# deciduous foot is hardcoded 0.0 without ever measuring the mesh.
	_check("canopy stays above the foot", canopy_base >= 0.0,
		"canopy_base=%.2f" % canopy_base)
	# ...and still covers the top of the trunk (the apex leader), or the crown
	# has the hollow notch that made every distant broadleaf a heart shape.
	_check("canopy covers the trunk top", canopy_top >= trunk_top - 0.5,
		"canopy_top=%.2f trunk_draw_top=%.2f" % [canopy_top, trunk_top])
	_check("deciduous foot at origin", VegetationCardFactory.foot_local_y("deciduous", {}) == 0.0)
	var bark := VegetationCardFactory.bark_material_for_species("deciduous", {})
	var bark_tex := bark.get_shader_parameter("albedo_tex") as Texture2D
	_check("bark texture present", bark_tex != null)
	if bark_tex != null:
		var img := bark_tex.get_image()
		var opaque := 0
		for y in img.get_height():
			var c := img.get_pixel(int(img.get_width() / 2), y)
			if c.a > 0.95:
				opaque += 1
		_check("bark trunk band mostly opaque", opaque > img.get_height() / 3,
			"opaque=%d" % opaque)
	var pine_mesh := VegetationCardFactory.mesh_for_species("pine", {})
	_check("pine has 2 surfaces", pine_mesh.get_surface_count() == 2,
		"got %d" % pine_mesh.get_surface_count())
	var pine_trunk := pine_mesh.surface_get_arrays(0)
	var pine_top_y := 0.0
	for v in pine_trunk[Mesh.ARRAY_VERTEX]:
		pine_top_y = maxf(pine_top_y, (v as Vector3).y)
	_check("pine trunk reaches height", pine_top_y > 3.0, "top=%.2f" % pine_top_y)
	var pine_mat := VegetationCardFactory.material_for_species("pine", {})
	var dec_mat := VegetationCardFactory.material_for_species("deciduous", {})
	var pine_t: Vector3 = pine_mat.get_shader_parameter("albedo_tint")
	var dec_t: Vector3 = dec_mat.get_shader_parameter("albedo_tint")
	_check("pine vs deciduous spec colors differ",
		pine_t.y != dec_t.y)


func _test_exclusion_builder() -> void:
	var building := PackedVector2Array([
		Vector2(-5, -5), Vector2(5, -5), Vector2(5, 5), Vector2(-5, 5)])
	var buildings := [{"points": building}]
	var roads := [{
		"points": PackedVector2Array([Vector2(-50, 0), Vector2(50, 0)]),
		"half_width_m": 4.0,
	}]
	var excl := VegExclusionBuilder.build_all(buildings, roads, [], 3.0, 4.0, 0.0)
	_check("exclusion builder produces polys", excl.size() >= 2)
	var excl_off := VegExclusionBuilder.build_all(buildings, roads, [], 3.0, 4.0, 0.0, false, false)
	_check("exclusion disabled skips building+road", excl_off.is_empty())
	_check("building buffer excludes centre", VegExclusionBuilder.point_excluded(Vector2.ZERO, excl))
	var road_pt := Vector2(0.0, 0.0)
	_check("road corridor excludes centreline", VegExclusionBuilder.point_excluded(road_pt, excl))
	var far := Vector2(200.0, 200.0)
	_check("far point not excluded", not VegExclusionBuilder.point_excluded(far, excl))
	var corridor := TerrainRoadFlatten.road_corridor_polygon(
		PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]), 6.0)
	_check("road corridor polygon closed", corridor.size() >= 4)


func _test_exclusion_index() -> void:
	var building := PackedVector2Array([
		Vector2(-5, -5), Vector2(5, -5), Vector2(5, 5), Vector2(-5, 5)])
	var excl := VegExclusionBuilder.build_all([{"points": building}], [], [], 0.0, 0.0, 0.0)
	var idx := VegExclusionBuilder.build_index(excl, 500.0)
	_check("index excludes centre", idx.is_excluded(Vector2.ZERO))
	_check("index allows far point", not idx.is_excluded(Vector2(200.0, 200.0)))


func _test_performance_caps() -> void:
	var polys: Array = []
	for i in 700:
		var off := float(i) * 30.0
		polys.append({
			"points": PackedVector2Array([
				Vector2(off, off), Vector2(off + 20, off),
				Vector2(off + 20, off + 20), Vector2(off, off + 20)]),
			"kind": "wood", "tags": {},
		})
	var payload := {"polygons": polys, "tree_points": [], "tree_rows": []}
	var ctx := {"latitude": 47.6, "seed": 7, "exclusions": [], "half_extent_m": 1500.0}
	var state := AutoVegetationGenerator.prepare_context(payload, ctx)
	_check("polygon budget keeps largest patches", state.polys.size() <= AutoVegetationGenerator.DENSE_POLY_BUDGET,
		"got %d" % state.polys.size())
	_check("overflow polys trimmed to budget", state.polys.size() == AutoVegetationGenerator.DENSE_POLY_BUDGET,
		"got %d" % state.polys.size())
	var layer := AutoVegetationGenerator.generate(payload, ctx)
	_check("layer respects bulk cap", layer.total_bulk() <= AutoVegetationLayer.MAX_BULK_TOTAL,
		"got %d" % layer.total_bulk())


func _test_veg_multipolygon_outers_only() -> void:
	# Nested hole punch must not run for vegetation (water still punches).
	var clat := 47.6
	var clon := -122.3
	var d := 0.002
	var doc := {"elements": [
		{"type": "node", "id": 1, "lat": clat - d, "lon": clon - d},
		{"type": "node", "id": 2, "lat": clat - d, "lon": clon + d},
		{"type": "node", "id": 3, "lat": clat + d, "lon": clon + d},
		{"type": "node", "id": 4, "lat": clat + d, "lon": clon - d},
		{"type": "node", "id": 5, "lat": clat - d * 0.3, "lon": clon - d * 0.3},
		{"type": "node", "id": 6, "lat": clat - d * 0.3, "lon": clon + d * 0.3},
		{"type": "node", "id": 7, "lat": clat + d * 0.3, "lon": clon + d * 0.3},
		{"type": "node", "id": 8, "lat": clat + d * 0.3, "lon": clon - d * 0.3},
		{"type": "way", "id": 10, "nodes": [1, 2, 3, 4, 1],
			"tags": {"natural": "wood"}},
		{"type": "way", "id": 11, "nodes": [5, 6, 7, 8, 5]},
		{"type": "relation", "id": 20, "tags": {"type": "multipolygon", "natural": "wood"},
			"members": [
				{"type": "way", "ref": 10, "role": "outer"},
				{"type": "way", "ref": 11, "role": "inner"},
			]},
	]}
	var payload: Dictionary = VegService._parse_overpass(doc, clat, clon)
	var polys: Array = payload.get("polygons", [])
	# One outer ring only (relation first; member way skipped; no hole fragments).
	_check("veg mp keeps one outer", polys.size() == 1, "got %d" % polys.size())


func _test_osm_polygon_cap() -> void:
	# Service-level hard cap: keep open-area veto polys + largest woods.
	var polys: Array = []
	for i in 50:
		var s := 10.0 + float(i)  # increasing wood area
		polys.append({
			"points": PackedVector2Array([
				Vector2(0, 0), Vector2(s, 0), Vector2(s, s), Vector2(0, s)]),
			"kind": "wood", "tags": {},
		})
	# Tiny lawn must survive even when many larger woods compete.
	polys.append({
		"points": PackedVector2Array([
			Vector2(1000, 1000), Vector2(1005, 1000),
			Vector2(1005, 1005), Vector2(1000, 1005)]),
		"kind": "grass_lawn", "tags": {"landuse": "grass"},
	})
	var payload := {"polygons": polys, "tree_points": [], "tree_rows": [], "hedge_rows": []}
	var capped: Dictionary = VegService.cap_polygons(payload, 20)
	var out: Array = capped.get("polygons", [])
	_check("cap_polygons shrinks", out.size() == 20, "got %d" % out.size())
	var lawn_kept := false
	var max_wood_side := 0.0
	for rec in out:
		var d: Dictionary = rec
		if str(d.get("kind", "")) == "grass_lawn":
			lawn_kept = true
		elif str(d.get("kind", "")) == "wood":
			var pts: PackedVector2Array = d.get("points", PackedVector2Array())
			if pts.size() >= 2:
				max_wood_side = maxf(max_wood_side, pts[1].x - pts[0].x)
	_check("cap keeps open-area lawn", lawn_kept)
	_check("cap prefers largest woods", max_wood_side >= 40.0,
		"max side=%.1f" % max_wood_side)
	var small: Dictionary = VegService.cap_polygons(payload, 200)
	_check("cap no-op under budget",
		(small.get("polygons", []) as Array).size() == polys.size())


func _test_batched_scatter() -> void:
	var poly := PackedVector2Array([
		Vector2(-80, -80), Vector2(80, -80), Vector2(80, 80), Vector2(-80, 80)])
	var payload := {
		"polygons": [{"points": poly, "kind": "wood", "tags": {}}],
		"tree_points": [], "tree_rows": [],
	}
	var ctx := {"latitude": 47.6, "seed": 11, "exclusions": [], "half_extent_m": 500.0}
	var whole := AutoVegetationGenerator.generate(payload, ctx)
	var state := AutoVegetationGenerator.prepare_context(payload, ctx)
	while AutoVegetationGenerator.scatter_batch(state, 1):
		pass
	_check("batched matches one-shot bulk", state.layer.total_bulk() == whole.total_bulk(),
		"batched=%d whole=%d" % [state.layer.total_bulk(), whole.total_bulk()])


func _test_poisson_performance() -> void:
	var poly := PackedVector2Array([
		Vector2(-120, -120), Vector2(120, -120), Vector2(120, 120), Vector2(-120, 120)])
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var t0 := Time.get_ticks_msec()
	var spots := VegetationPaint.poisson_fill(poly, 5.0, rng, [] as Array[Vector2], 2000)
	var ms := Time.get_ticks_msec() - t0
	_check("poisson high cap completes quickly", ms < 3000, "ms=%d count=%d" % [ms, spots.size()])
	_check("poisson respects cap", spots.size() <= 2000)


func _test_forest_routing() -> void:
	# Canopy-mesh forest zones were removed: large woods always scatter as
	# individual trees, never a forest zone, regardless of style flags.
	var big_poly := PackedVector2Array([
		Vector2(-200, -200), Vector2(200, -200), Vector2(200, 200), Vector2(-200, 200)])
	var payload := {
		"polygons": [{"points": big_poly, "kind": "wood", "tags": {"leaf_type": "needleleaved"}}],
		"tree_points": [], "tree_rows": [],
	}
	var ctx := {
		"latitude": 47.6, "seed": 99, "exclusions": [],
		"style": {"forest_zones_enabled": true, "forest_auto_min_area_m2": 10000.0},
		"ground_y_at": func(_x: float, _z: float) -> float: return 0.0,
	}
	var layer := AutoVegetationGenerator.generate(payload, ctx)
	_check("large wood never creates a forest zone", layer.forests.size() == 0,
		"forests=%d bulk=%d" % [layer.forests.size(), layer.total_bulk()])
	_check("large wood scatters individual trees", layer.total_bulk() > 0,
		"bulk=%d" % layer.total_bulk())


func _test_forest_edits() -> void:
	# Legacy painted forest zones must still deserialize for save compat, but are
	# no longer replayed into the layer (nothing renders them anymore).
	var poly := PackedVector2Array([
		Vector2(-30, -30), Vector2(30, -30), Vector2(30, 30), Vector2(-30, 30)])
	var edits := AutoVegetationEdits.create_empty()
	edits.add_forest_zone(poly, {"profile": "deciduous", "canopy_height_m": 12.0})
	var rt := AutoVegetationEdits.create_empty()
	rt.deserialize(edits.serialize())
	_check("legacy forest edits still roundtrip", rt.forests.size() == 1)
	var layer := AutoVegetationLayer.create_empty()
	rt.apply_to_layer(layer)
	_check("legacy forest zones are not replayed", layer.forests.size() == 0)


func _test_grass_species() -> void:
	for species in ["grass_lawn", "grass_field"]:
		var mesh := GrassBuilder.mesh_for_lod(species, {}, GrassBuilder.LodTier.NEAR)
		_check("%s grass mesh builds" % species, mesh != null and mesh.get_surface_count() > 0)
		var mat := GrassBuilder.material_for_species(species, {})
		_check("%s grass material builds" % species, mat != null and mat.shader != null)
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("grass_lawn", 1.0, 1.0, 0.0, 1.0)
	layer.add_bulk("grass_field", 2.0, 2.0, 0.0, 1.0)
	var ground := func(_x: float, _z: float) -> float: return 0.0
	VegetationRuntime.rebuild(terrain, layer, ground)
	var root := terrain.get_node_or_null("Vegetation")
	_check("grass bulk LOD nodes render", root != null and root.get_child_count() >= 6)
	terrain.queue_free()


func _test_grass_builder() -> void:
	var foot := GrassBuilder.foot_local_y()
	_check("grass foot at origin", foot == 0.0)
	var mid := GrassBuilder.mesh_for_lod("grass_lawn", {}, GrassBuilder.LodTier.MID)
	var far := GrassBuilder.mesh_for_lod("grass_lawn", {}, GrassBuilder.LodTier.FAR)
	_check("grass mid mesh", mid != null)
	_check("grass far patch mesh", far != null)


## The Tune Look "Mixed woodland" ratios customize the "mixed" OSM binding.
func _test_mix_weights() -> void:
	var style := {"mix_pine": 0.7, "mix_deciduous": 0.2, "mix_shrub": 0.1}
	var mix := BiomePalette.mix_weights_from_style(style)
	_check("mix weights read from style", mix.size() == 3
		and absf(float(mix.get("pine", 0.0)) - 0.7) < 0.001)
	_check("zero-weight mix species dropped",
		BiomePalette.mix_weights_from_style({"mix_pine": 1.0}).size() == 1)
	var osm := {"wood": "mixed"}
	var override := BiomePalette.species_override_for_kind(osm, "wood", mix)
	_check("mixed override uses custom weights",
		absf(float(override.get("pine", 0.0)) - 0.7) < 0.001)
	var default_mix := BiomePalette.species_override_for_kind(osm, "wood", {})
	_check("mixed override falls back to even split",
		absf(float(default_mix.get("pine", 0.0)) - 0.5) < 0.001)
	# End-to-end: a wood bound to mixed with pine-heavy ratio scatters mostly pine.
	var poly := PackedVector2Array([
		Vector2(-60, -60), Vector2(60, -60), Vector2(60, 60), Vector2(-60, 60)])
	var payload := {"polygons": [{"points": poly, "kind": "wood", "tags": {}}],
		"tree_points": [], "tree_rows": []}
	var layer := AutoVegetationGenerator.generate(payload, {"latitude": 47.6, "seed": 3,
		"exclusions": [], "style": {"osm_species_map": {"wood": "mixed"},
			"mix_pine": 0.9, "mix_deciduous": 0.1, "mix_shrub": 0.0}})
	var pine_n: int = (layer.bulk.get("pine", []) as Array).size()
	var decid_n: int = (layer.bulk.get("deciduous", []) as Array).size()
	_check("pine-heavy mix scatters mostly pine", pine_n > decid_n * 3,
		"pine=%d decid=%d" % [pine_n, decid_n])


func _test_leaf_type_weights() -> void:
	var base := {"deciduous": 0.5, "conifer": 0.5}
	var needle := BiomePalette.weights_for_osm_tags(base, {"leaf_type": "needleleaved"})
	_check("leaf_type needle -> conifer", needle.has("conifer") and float(needle["conifer"]) == 1.0)
	var broad := BiomePalette.weights_for_osm_tags(base, {"leaf_type": "broadleaved"})
	_check("leaf_type broad -> deciduous", broad.has("deciduous") and float(broad["deciduous"]) == 1.0)


func _test_osm_v4_kinds() -> void:
	_check("park kind", VegService._veg_kind({"leisure": "park"}) == "park")
	_check("vineyard kind", VegService._veg_kind({"landuse": "vineyard"}) == "vineyard")
	_check("wetland kind", VegService._veg_kind({"natural": "wetland"}) == "wetland")
	_check("heath -> scrub", VegService._veg_kind({"natural": "heath"}) == "scrub")
	_check("cemetery kind", VegService._veg_kind({"landuse": "cemetery"}) == "cemetery")


func _test_vegetation_undo() -> void:
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("shrub", 1.0, 2.0, 0.0, 1.0)
	var undo := VegetationUndo.new()
	undo.push_combined(layer.bulk, null, "test")
	layer.add_bulk("shrub", 3.0, 4.0, 0.0, 1.0)
	_check("before undo 2 shrubs", layer.bulk["shrub"].size() == 2)
	var snap := undo.pop()
	VegetationUndo.restore_manual_bulk(layer, snap)
	_check("after undo 1 shrub", layer.bulk["shrub"].size() == 1)


func _test_ground_y_monotonic() -> void:
	var gy := 10.0
	var foot := 0.35
	var scale := 1.0
	var y_high := gy + 2.0 - foot * scale - VegetationPaint.GROUND_SINK_M
	var y_low := gy - 2.0 - foot * scale - VegetationPaint.GROUND_SINK_M
	_check("lower offset lowers Y", y_low < y_high)
	var grass_y := gy + 1.0 - GrassBuilder.foot_local_y() * scale - VegetationPaint.GROUND_SINK_M
	var grass_y2 := gy - 1.0 - GrassBuilder.foot_local_y() * scale - VegetationPaint.GROUND_SINK_M
	_check("grass offset monotonic", grass_y2 < grass_y)


## OSM height values come with units — "90 ft" must not read as 90 meters.
func _test_height_parse() -> void:
	_check("plain number is meters", absf(VegService.parse_height_m("30") - 30.0) < 0.01)
	_check("explicit meters", absf(VegService.parse_height_m("30 m") - 30.0) < 0.01)
	_check("no-space meters", absf(VegService.parse_height_m("12.5m") - 12.5) < 0.01)
	_check("feet converted", absf(VegService.parse_height_m("90 ft") - 27.432) < 0.01)
	_check("apostrophe feet", absf(VegService.parse_height_m("30'") - 9.144) < 0.01)
	_check("centimeters converted", absf(VegService.parse_height_m("250 cm") - 2.5) < 0.01)
	_check("comma decimal", absf(VegService.parse_height_m("7,5") - 7.5) < 0.01)
	_check("garbage -> 0", VegService.parse_height_m("tall") == 0.0)
	_check("empty -> 0", VegService.parse_height_m("") == 0.0)


## mesh height must compose parent transforms — a GLB with a scaled intermediate
## node used to mis-measure and blow up the target-height fit (~300 ft hero tree).
func _test_hero_metrics_composition() -> void:
	var root := Node3D.new()
	var mid := Node3D.new()
	mid.scale = Vector3.ONE * 0.1
	root.add_child(mid)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 10.0, 1.0)
	mi.mesh = box
	mid.add_child(mi)
	var metrics := HeroTreeCatalog.measure_instance(root)
	_check("parent scale composed into unit_height",
		absf(float(metrics["unit_height"]) - 1.0) < 0.01,
		"got %.3f (10.0 means parent scale ignored)" % float(metrics["unit_height"]))
	_check("foot composes too", absf(float(metrics["foot_local_y"]) + 0.5) < 0.01,
		"got %.3f" % float(metrics["foot_local_y"]))
	root.free()


func _test_hero_scale_clamp() -> void:
	var s := HeroTreeCatalog.resolved_hero_scale("deciduous_low", 10000.0)
	_check("hero world scale clamped", s <= HeroTreeCatalog.MAX_HERO_WORLD_SCALE,
		"got %.1f" % s)


## Absurd OSM height tags (mis-entered feet) clamp to a realistic tree height.
func _test_tree_point_height_clamp() -> void:
	var payload := {
		"polygons": [],
		"tree_points": [{"pos": Vector2.ZERO, "height_m": 300.0,
			"tags": {"natural": "tree", "height": "300"}}],
		"tree_rows": [],
	}
	var layer := AutoVegetationGenerator.generate(payload,
		{"latitude": 42.4, "seed": 7, "exclusions": []})
	# Tree points are procedural bulk now; the absurd height still clamps.
	_check("clamped tree places a bulk instance", layer.total_bulk() == 1,
		"bulk=%d hero=%d" % [layer.total_bulk(), layer.hero.size()])
	var rec := {}
	for sp in layer.bulk.keys():
		for item in layer.bulk.get(sp, []):
			rec = item
	if not rec.is_empty():
		_check("bulk tree height clamped to max",
			float(rec.get("height_m", 0.0)) <= AutoVegetationGenerator.TREE_POINT_MAX_HEIGHT_M,
			"got %.1f" % float(rec.get("height_m", 0.0)))


func _count_trees_in_poly(layer: AutoVegetationLayer, poly: PackedVector2Array) -> int:
	var n := 0
	for slot in layer.bulk.keys():
		if str(slot) in VegetationLayer.GRASS_SPECIES:
			continue
		for rec in layer.bulk[slot]:
			var p := Vector2(float(rec["x"]), float(rec["z"]))
			if Geometry2D.is_point_in_polygon(p, poly):
				n += 1
	return n


## A mapped meadow inside a wood polygon must stay tree-free (meadow wins),
## while the rest of the wood still forests — the osm.org semantic.
func _test_open_area_exclusion() -> void:
	var wood := PackedVector2Array([
		Vector2(-100, -100), Vector2(100, -100), Vector2(100, 100), Vector2(-100, 100)])
	var meadow := PackedVector2Array([
		Vector2(-40, -40), Vector2(40, -40), Vector2(40, 40), Vector2(-40, 40)])
	var payload := {
		"polygons": [
			{"points": wood, "kind": "wood", "tags": {"natural": "wood"}},
			{"points": meadow, "kind": "grass_field", "tags": {"landuse": "meadow"}},
		],
		"tree_points": [], "tree_rows": [],
	}
	var layer := AutoVegetationGenerator.generate(payload,
		{"latitude": 47.6, "seed": 42, "exclusions": [],
			"style": {"scatter_lawn_field": true}})
	var inside := _count_trees_in_poly(layer, meadow)
	var total := _count_trees_in_poly(layer, wood)
	_check("no trees inside the meadow", inside == 0, "got %d" % inside)
	_check("wood still forests outside the meadow", total > 10, "got %d" % total)
	var grass_in := 0
	for rec in layer.bulk.get("grass_field", []):
		if Geometry2D.is_point_in_polygon(Vector2(float(rec["x"]), float(rec["z"])), meadow):
			grass_in += 1
	_check("meadow still receives grass when opt-in", grass_in > 10, "got %d" % grass_in)
	# Style toggle off restores the old overlap behavior.
	var layer_off := AutoVegetationGenerator.generate(payload,
		{"latitude": 47.6, "seed": 42, "exclusions": [],
			"style": {"open_areas_exclude_trees": false}})
	_check("toggle off allows trees in meadow",
		_count_trees_in_poly(layer_off, meadow) > 0)


## Wetland shrub swarms (92 polys at the Canaan site) must not starve wood
## polygons of the shared tree budget: woods scatter first, wetlands are capped.
func _test_budget_priority() -> void:
	var polys: Array = []
	# 40 large wetlands FIRST in payload order…
	for i in 40:
		var off := -1400.0 + float(i) * 70.0
		polys.append({"points": PackedVector2Array([
			Vector2(off, 200), Vector2(off + 60, 200),
			Vector2(off + 60, 260), Vector2(off, 260)]),
			"kind": "wetland", "tags": {"natural": "wetland"}})
	# …then one wood.
	polys.append({"points": PackedVector2Array([
		Vector2(-80, -80), Vector2(80, -80), Vector2(80, 80), Vector2(-80, 80)]),
		"kind": "wood", "tags": {"natural": "wood"}})
	var payload := {"polygons": polys, "tree_points": [], "tree_rows": []}
	var ctx := {"latitude": 47.6, "seed": 9, "exclusions": [], "half_extent_m": 1500.0}
	var state := AutoVegetationGenerator.prepare_context(payload, ctx)
	_check("wood sorted before wetlands",
		str((state.polys[0] as Dictionary).get("kind", "")) == "wood")
	while AutoVegetationGenerator.scatter_batch(state, 999999):
		pass
	var wood_poly: PackedVector2Array = (polys.back() as Dictionary)["points"]
	_check("wood polygon got trees", _count_trees_in_poly(state.layer, wood_poly) > 10,
		"got %d" % _count_trees_in_poly(state.layer, wood_poly))
	var wet_cap := int(AutoVegetationLayer.MAX_TREE_BULK_TOTAL
		* AutoVegetationGenerator.WETLAND_TREE_BUDGET_SHARE)
	_check("wetland share respected", int(ctx.get("wetland_bulk_used", 0)) <= wet_cap,
		"used %d cap %d" % [int(ctx.get("wetland_bulk_used", 0)), wet_cap])


## Grass is dense near spawn (matching the Tune Look studio) and skipped past
## the detail radius, so the budget concentrates where the player actually is.
func _test_grass_detail_radius() -> void:
	var near_poly := PackedVector2Array([
		Vector2(-40, -40), Vector2(40, -40), Vector2(40, 40), Vector2(-40, 40)])
	var far_poly := PackedVector2Array([
		Vector2(760, -40), Vector2(840, -40), Vector2(840, 40), Vector2(760, 40)])
	var payload := {
		"polygons": [
			{"points": near_poly, "kind": "grass_field", "tags": {"landuse": "meadow"}},
			{"points": far_poly, "kind": "grass_field", "tags": {"landuse": "meadow"}},
		],
		"tree_points": [], "tree_rows": [],
	}
	var ctx := {"latitude": 42.4, "seed": 4, "exclusions": [], "half_extent_m": 1500.0,
		"style": {"scatter_lawn_field": true, "grass_detail_radius_m": 150.0}}
	var layer := AutoVegetationGenerator.generate(payload, ctx)
	var near_n := 0
	var far_n := 0
	for g in layer.bulk.get("grass_field", []):
		var p := Vector2(float(g["x"]), float(g["z"]))
		if Geometry2D.is_point_in_polygon(p, near_poly):
			near_n += 1
		elif Geometry2D.is_point_in_polygon(p, far_poly):
			far_n += 1
	_check("near meadow densely grassed", near_n > 200, "got %d" % near_n)
	_check("meadow past detail radius skipped", far_n == 0, "got %d" % far_n)
	# Density tracks the Tune Look studio: 80x80 m at ~1.1 m spacing ≈ 5500 tufts.
	_check("near meadow near studio density", near_n > 3000, "got %d" % near_n)


## Every scattered polygon emits one diagnostics record with coherent counts.
func _test_poly_stats() -> void:
	var payload := {
		"polygons": [
			{"points": PackedVector2Array([
				Vector2(-60, -60), Vector2(60, -60), Vector2(60, 60), Vector2(-60, 60)]),
				"kind": "wood", "tags": {"natural": "wood"}},
			{"points": PackedVector2Array([
				Vector2(100, 100), Vector2(140, 100), Vector2(140, 140), Vector2(100, 140)]),
				"kind": "grass_field", "tags": {"landuse": "meadow"}},
		],
		"tree_points": [], "tree_rows": [],
	}
	var state := AutoVegetationGenerator.prepare_context(payload,
		{"latitude": 47.6, "seed": 5, "exclusions": []})
	while AutoVegetationGenerator.scatter_batch(state, 999999):
		pass
	_check("one stats record per polygon", state.poly_stats.size() == 2,
		"got %d" % state.poly_stats.size())
	var placed_sum := 0
	for s in state.poly_stats:
		var d: Dictionary = s
		_check("stats record has kind", not str(d.get("kind", "")).is_empty())
		_check("stats record has tag", not str(d.get("tag", "")).is_empty())
		placed_sum += int(d.get("placed", 0))
	_check("stats placed matches layer bulk", placed_sum == state.layer.total_bulk(),
		"placed=%d bulk=%d" % [placed_sum, state.layer.total_bulk()])


func _test_pick_species_grass() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	_check("grass lawn preset", VegetationPaint.pick_species(
		VegetationPaint.Preset.GRASS_LAWN, 0.0, 0.0, 0.0, rng) == "grass_lawn")
	_check("grass field preset", VegetationPaint.pick_species(
		VegetationPaint.Preset.GRASS_FIELD, 0.0, 0.0, 0.0, rng) == "grass_field")
	var mix_counts := {"grass_lawn": 0, "grass_field": 0}
	for _i in 200:
		var s := VegetationPaint.pick_species(
			VegetationPaint.Preset.MIX, 0.0, 0.0, 0.0, rng, 0.5, 0.5)
		if s in mix_counts:
			mix_counts[s] += 1
	_check("mix includes grass lawn", mix_counts["grass_lawn"] > 20)
	_check("mix includes grass field", mix_counts["grass_field"] > 20)


## --- Phase 0 veg-overhaul regression guards -------------------------------


## v3: tree families are EXACT-size — species_bulk_scale is hard 1.0 for trees
## no matter what the settings claim (no hidden multiplier can ever resize a
## tree again), while shrub/grass_field stay neutralised against their
## scatter-baked bulk factors.
func _test_neutral_bulk_wins() -> void:
	var s := AutoVegetationRuntime.neutralized_settings({
		"shrub_bulk_scale": 0.8, "grass_field_bulk_scale": 1.25,
		"unrelated_key": 42,
	})
	for key in AutoVegetationRuntime.NEUTRAL_BULK:
		_check("neutralized %s == 1.0" % key, is_equal_approx(float(s[key]), 1.0),
			"got %s" % str(s[key]))
	_check("non-bulk keys pass through", int(s.get("unrelated_key", 0)) == 42)
	_check("trees are exact-size (no bulk multiplier, ever)",
		is_equal_approx(VegetationCardFactory.species_bulk_scale("deciduous",
			{"deciduous_bulk_scale": 1.6}), 1.0))
	_check("pine exact-size too",
		is_equal_approx(VegetationCardFactory.species_bulk_scale("pine",
			{"pine_bulk_scale": 6.0}), 1.0))
	_check("shrub bulk still honoured",
		is_equal_approx(VegetationCardFactory.species_bulk_scale("shrub",
			{"shrub_bulk_scale": 1.3}), 1.3))


## Explicitly-mapped features (points/rows/hedges) scatter BEFORE polygons so a
## spent tree budget can no longer silently erase them, and their outcomes are
## counted in feature_stats.
func _test_feature_scatter_order() -> void:
	var payload := {
		"polygons": [{"points": PackedVector2Array([
			Vector2(-220, -220), Vector2(220, -220), Vector2(220, 220), Vector2(-220, 220)]),
			"kind": "wood", "tags": {"natural": "wood"}}],
		"tree_points": [
			{"pos": Vector2(400, 400), "height_m": 14.0},
			{"pos": Vector2(410, 400), "height_m": 9.0},
			{"pos": Vector2(420, 400), "height_m": 20.0},
		],
		"tree_rows": [], "hedge_rows": [],
	}
	var state := AutoVegetationGenerator.prepare_context(payload, {
		"latitude": 47.6, "seed": 7, "exclusions": [],
		"style": {"auto_max_tree_instances": 1000},
	})
	_check("fresh state scatters mapped features first",
		state.phase == AutoVegetationGenerator.ScatterPhase.POINTS)
	while AutoVegetationGenerator.scatter_batch(state, 999999):
		pass
	_check("tree budget exhausted by wood poly",
		state.layer.tree_bulk_count() >= 1000,
		"got %d" % state.layer.tree_bulk_count())
	_check("all mapped tree points survived the budget",
		int(state.feature_stats.get("points_placed", 0)) == 3,
		"stats=%s" % str(state.feature_stats))
	_check("no budget-rejected points",
		int(state.feature_stats.get("points_rej_budget", 0)) == 0)


class _GateStub:
	extends RefCounted
	var samples := 0
	func is_valid() -> bool:
		return true
	func is_vegetated(_x: float, _z: float) -> bool:
		samples += 1
		return false
	func canopy_factor(_x: float, _z: float) -> float:
		return 0.5


## The gap-fill scan is bounded: the scanned square is clamped and the sample
## cap covers it with headroom, so a 15 km sparse map can no longer freeze a
## frame on ~7.4M synchronous point-in-polygon tests.
func _test_gap_fill_bounded() -> void:
	var side := 2.0 * AutoVegetationGenerator.GAP_FILL_SCAN_HALF_MAX_M \
		/ AutoVegetationGenerator.GAP_FILL_SPACING_M
	_check("sample cap covers the clamped scan square",
		side * side <= float(AutoVegetationGenerator.GAP_FILL_MAX_SAMPLES),
		"square=%d cap=%d" % [int(side * side), AutoVegetationGenerator.GAP_FILL_MAX_SAMPLES])
	var layer := AutoVegetationLayer.create_empty()
	var gate := _GateStub.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var t0 := Time.get_ticks_msec()
	AutoVegetationGenerator._fill_imagery_gaps(layer, {"polygons": []}, gate,
		{"weights": {"deciduous": 1.0}, "default_height_m": 12.0}, null,
		{"half_extent_m": 15000.0}, rng)
	var elapsed := Time.get_ticks_msec() - t0
	_check("gap-fill scan bounded on 15 km ctx",
		gate.samples <= AutoVegetationGenerator.GAP_FILL_MAX_SAMPLES + 1,
		"samples=%d" % gate.samples)
	_check("gap-fill returns promptly (got %d ms)" % elapsed, elapsed < 5000)


## reground() must thread settings + growth map: the bare rebuild it used to do
## rebuilt the manual layer style-less at full size (the "V pops full detail"
## bug) and left the growth map pointing at freed MultiMeshes.
func _test_reground_threads_growth() -> void:
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0)
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var map := VegetationInstanceMap.new()
	var settings := {"pine_growth_years": 5.0, "growth_now_h": 1000.0}
	VegetationRuntime.reground(terrain, layer, ground, settings, map)
	_check("reground repopulates the growth map", not map.is_empty())
	terrain.queue_free()


## Stale-payload guard: the ready-signal key must identify the site.
func _test_osm_key_match() -> void:
	var key := VegService._cache_key(48.3252, -122.2469, 3000.0)
	_check("key matches its own site",
		VegService.matches_site(key, 48.3252, -122.2469, 3000.0))
	_check("key rejects another site",
		not VegService.matches_site(key, 47.0, -122.2469, 3000.0))
	_check("key rejects another extent",
		not VegService.matches_site(key, 48.3252, -122.2469, 6000.0))


## _forest_params_changed must cover every generator-read key (a key it misses
## persists in the style but never re-scatters — "Tune-look doesn't apply").
func _test_forest_params_coverage() -> void:
	var tl_script: GDScript = load("res://core/terrain/terrain_loader.gd")
	var tl: Node = tl_script.new()
	var base := {"slope_max_deg": 25.0, "auto_detail_radius_m": 800.0,
		"auto_distant_density": 0.35, "scatter_lawn_field": false,
		"local_mix": {"birch": 0.5}}
	for key_val in [["slope_max_deg", 10.0], ["auto_detail_radius_m", 300.0],
			["auto_distant_density", 0.1], ["auto_max_tree_instances", 5000.0],
			["forest_edge_feather_m", 40.0], ["grass_detail_radius_m", 90.0],
			["mix_pine", 0.8]]:
		var next := base.duplicate(true)
		next[key_val[0]] = key_val[1]
		_check("generator key %s triggers re-scatter" % key_val[0],
			bool(tl._forest_params_changed(base, next)))
	var flipped := base.duplicate(true)
	flipped["scatter_lawn_field"] = true
	_check("scatter_lawn_field triggers re-scatter",
		bool(tl._forest_params_changed(base, flipped)))
	var mixed := base.duplicate(true)
	mixed["local_mix"] = {"birch": 0.2}
	_check("local_mix change triggers re-scatter",
		bool(tl._forest_params_changed(base, mixed)))
	var same := base.duplicate(true)
	_check("unchanged style does NOT re-scatter",
		not bool(tl._forest_params_changed(base, same)))
	tl.free()


## Phase 1: built assets are shared per (species, tier, settings-hash) — the
## old path rebuilt an identical mesh + procedural texture per 256 m chunk per
## LOD tier — and every veg MultiMesh gets a dithered FADE_SELF band instead of
## Godot's default hard on/off visibility pop.
func _test_asset_cache_and_fade() -> void:
	VegAssetCache.clear()
	var s := {"deciduous_canopy_w": 11.0}
	var m1 := VegetationCardFactory.mesh_for_canopy_lod("deciduous", s,
		VegetationCardFactory.CanopyLodTier.NEAR)
	var m2 := VegetationCardFactory.mesh_for_canopy_lod("deciduous", s.duplicate(),
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("identical settings share one mesh", m1 == m2)
	var m3 := VegetationCardFactory.mesh_for_canopy_lod("deciduous", s,
		VegetationCardFactory.CanopyLodTier.FAR)
	_check("tiers fork meshes", m1 != m3)
	var m4 := VegetationCardFactory.mesh_for_canopy_lod("deciduous",
		{"deciduous_canopy_w": 9.0}, VegetationCardFactory.CanopyLodTier.NEAR)
	_check("different settings fork meshes", m1 != m4)
	var mat1 := VegetationCardFactory.material_for_species("shrub", s)
	var mat2 := VegetationCardFactory.material_for_species("shrub", s.duplicate())
	_check("identical settings share one material", mat1 == mat2)
	VegAssetCache.clear()
	var m5 := VegetationCardFactory.mesh_for_canopy_lod("deciduous", s,
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("clear() forks a fresh mesh", m5 != m1)

	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var layer := AutoVegetationLayer.create_empty()
	layer.add_bulk("deciduous", 0.0, 0.0, 0.0, 1.0, 10.0)
	layer.add_bulk("grass_field", 5.0, 5.0, 0.0, 1.0, 0.0)
	var ground := func(_x: float, _z: float) -> float: return 0.0
	AutoVegetationRuntime.rebuild(terrain, layer, ground)
	var root := terrain.get_node_or_null(AutoVegetationRuntime.ROOT_NAME)
	var checked := 0
	if root != null:
		for child in root.get_children():
			if child is MultiMeshInstance3D:
				var gi := child as MultiMeshInstance3D
				_check("%s uses FADE_SELF" % gi.name,
					gi.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF)
				if gi.visibility_range_end > 0.0:
					_check("%s has an end fade margin" % gi.name,
						gi.visibility_range_end_margin > 0.0)
				checked += 1
	_check("fade check covered batches", checked >= 2, "got %d" % checked)
	terrain.queue_free()


## --- Per-area fill (veg overhaul Phase 7) -----------------------------------

func _fill_area_poly() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-60, -60), Vector2(60, -60), Vector2(60, 60), Vector2(-60, 60)])


## Persistence: v4 fills round-trip, are keyed by tag (one per area), and a v3
## file still loads — the schema bump must not orphan an existing map.
func _test_area_fill_edits() -> void:
	var poly := _fill_area_poly()
	var edits := AutoVegetationEdits.create_empty()
	var tag := AutoVegetationEdits.centroid_tag(poly)
	edits.add_fill(tag, poly, {"species": "pine", "density": 1.5, "height_m": 9.0})
	_check("fill recorded", edits.fills.size() == 1)
	# Re-filling the same area REPLACES rather than stacking a second forest.
	edits.add_fill(tag, poly, {"species": "shrub", "density": 0.5})
	_check("re-fill replaces by tag", edits.fills.size() == 1)
	_check("re-fill kept the new species",
		str((edits.fills[0] as Dictionary).get("species", "")) == "shrub")

	var round_trip := AutoVegetationEdits.create_empty()
	round_trip.deserialize(edits.serialize())
	_check("fills survive serialize/deserialize", round_trip.fills.size() == 1)
	var f: Dictionary = round_trip.fills[0]
	_check("fill tag round-trips", str(f.get("tag", "")) == tag)
	_check("fill species round-trips", str(f.get("species", "")) == "shrub")
	_check("fill density round-trips", is_equal_approx(float(f.get("density", 0.0)), 0.5))
	_check("fill polygon round-trips",
		(f.get("polygon", PackedVector2Array()) as PackedVector2Array).size() == 4)
	_check("fill seed round-trips",
		int(f.get("seed", -1)) == int((edits.fills[0] as Dictionary).get("seed", -2)))
	_check("serialize declares v4", int(edits.serialize().get("version", 0)) == 4)

	# A v3 payload (no `fills` key at all) loads with an empty fill list rather
	# than failing — an existing map just has no per-area fills yet.
	var legacy := AutoVegetationEdits.create_empty()
	legacy.deserialize({"version": 3, "cleared": [], "patches": [], "forests": []})
	_check("v3 file loads with no fills", legacy.fills.is_empty())

	# Filling an area that was cleared earlier must LIFT that clear: the
	# subtractive pass runs after all scatter and would otherwise erase the
	# forest the player just planted.
	var mixed := AutoVegetationEdits.create_empty()
	mixed.add_cleared_polygon(poly)
	_check("clear recorded", mixed.cleared.size() == 1)
	mixed.add_fill(tag, poly, {"species": "pine"})
	_check("filling lifts the area's clear", mixed.cleared.is_empty())
	_check("removing a fill reports whether it existed",
		mixed.remove_fill_for_tag(tag) and not mixed.remove_fill_for_tag(tag))


## Scatter: a fill plants the chosen species inside its outline, `replace`
## clears first, density moves the count, and a live apply matches the
## generator's replay exactly (same seed => same forest).
func _test_area_fill_scatter() -> void:
	var poly := _fill_area_poly()
	var payload := {
		"polygons": [{"points": poly, "kind": "wood", "tags": {}}],
		"tree_points": [], "tree_rows": [],
	}
	var base_ctx := {"latitude": 47.6, "seed": 7, "exclusions": [], "half_extent_m": 500.0}
	var no_fill := AutoVegetationGenerator.generate(payload, base_ctx.duplicate(true))

	var tag := AutoVegetationEdits.centroid_tag(poly)
	var edits := AutoVegetationEdits.create_empty()
	edits.add_fill(tag, poly, {"species": "pine", "density": 1.0, "replace": true})
	var fill: Dictionary = edits.fills[0]

	var fill_ctx := base_ctx.duplicate(true)
	fill_ctx["fills"] = [fill]
	var filled := AutoVegetationGenerator.generate(payload, fill_ctx)
	_check("filled area produced trees", filled.total_bulk() > 10,
		"got %d" % filled.total_bulk())
	# The OSM wood would have scattered a temperate mix; the fill replaces it
	# with pine only. This is the whole point of the feature.
	var slots: Array = filled.slots()
	_check("fill planted the chosen species", slots.has("pine"))
	var pine_n := (filled.bulk.get("pine", []) as Array).size()
	_check("fill dominates the outline", pine_n > int(float(filled.total_bulk()) * 0.9),
		"pine=%d total=%d" % [pine_n, filled.total_bulk()])
	_check("baseline had trees to replace", no_fill.total_bulk() > 0)

	# Live apply (loader path) == generator replay (load path): one function,
	# seeded per fill, so a filled area does not change shape on reload.
	var live := AutoVegetationGenerator.generate(payload, base_ctx.duplicate(true))
	var biome := BiomePalette.for_location(47.6)
	var res := AutoVegetationGenerator.apply_fill(live, fill, biome, null,
		base_ctx.duplicate(true))
	_check("live apply placed trees", int(res.get("placed", 0)) > 10,
		"got %d" % int(res.get("placed", 0)))
	_check("live apply cleared the old trees", int(res.get("removed", 0)) > 0)
	_check("live apply matches generator replay",
		live.total_bulk() == filled.total_bulk(),
		"live=%d replay=%d" % [live.total_bulk(), filled.total_bulk()])

	# Two replays of the same fill are identical — the RNG is seeded from the
	# fill, not the run.
	var again := AutoVegetationGenerator.generate(payload, fill_ctx.duplicate(true))
	_check("fill replay is deterministic", again.total_bulk() == filled.total_bulk(),
		"%d vs %d" % [again.total_bulk(), filled.total_bulk()])

	# Density scales spacing, so a denser fill plants more in the same outline.
	var dense_edits := AutoVegetationEdits.create_empty()
	dense_edits.add_fill(tag, poly, {"species": "pine", "density": 2.5, "replace": true})
	var dense_ctx := base_ctx.duplicate(true)
	dense_ctx["fills"] = [dense_edits.fills[0]]
	var dense := AutoVegetationGenerator.generate(payload, dense_ctx)
	_check("higher density plants more", dense.total_bulk() > filled.total_bulk(),
		"dense=%d normal=%d" % [dense.total_bulk(), filled.total_bulk()])

	# replace=false keeps whatever was already inside the outline.
	var add_edits := AutoVegetationEdits.create_empty()
	add_edits.add_fill(tag, poly, {"species": "pine", "density": 1.0, "replace": false})
	var add_layer := AutoVegetationGenerator.generate(payload, base_ctx.duplicate(true))
	var before := add_layer.total_bulk()
	var add_res := AutoVegetationGenerator.apply_fill(add_layer, add_edits.fills[0],
		biome, null, base_ctx.duplicate(true))
	_check("replace=false removes nothing", int(add_res.get("removed", 0)) == 0)
	_check("replace=false adds on top", add_layer.total_bulk() > before,
		"%d -> %d" % [before, add_layer.total_bulk()])

	# Species resolution: auto keeps the biome mix, mixed honours the tuned
	# composition, a named species is that species alone.
	_check("auto fill keeps the biome weights",
		AutoVegetationGenerator.fill_weights("auto", biome, {}).size()
			== (biome["weights"] as Dictionary).size())
	var mix := AutoVegetationGenerator.fill_weights("mixed", biome,
		{"mix_pine": 3.0, "mix_deciduous": 1.0})
	_check("mixed fill uses the tuned mix",
		is_equal_approx(float(mix.get("pine", 0.0)), 3.0)
			and is_equal_approx(float(mix.get("deciduous", 0.0)), 1.0))
	var single := AutoVegetationGenerator.fill_weights("spruce", biome, {})
	_check("named species fill is that species alone",
		single.size() == 1 and single.has("spruce"))


## --- Incremental chunk rebuild ----------------------------------------------

## An area fill touches a few 256 m chunks; rebuilding those must leave the map
## in the SAME state a whole-layer rebuild would, and must not disturb chunks
## outside the polygon.
func _test_incremental_chunk_rebuild() -> void:
	# Chunk-key helpers first — the rebuild is only as good as its chunk set.
	var cs := VegetationRuntime.CHUNK_SIZE_M
	_check("origin maps to chunk 0,0",
		VegetationRuntime.chunk_key_at(1.0, 1.0) == Vector2i(0, 0))
	_check("negative coords floor, not truncate",
		VegetationRuntime.chunk_key_at(-1.0, -1.0) == Vector2i(-1, -1))
	var small := VegetationPaint.rect_to_polygon(Vector2(10.0, 10.0), Vector2(50.0, 50.0))
	var keys_small := VegetationRuntime.chunk_keys_for_polygon(small)
	_check("a small polygon touches one chunk", keys_small.size() == 1, str(keys_small))
	var wide := VegetationPaint.rect_to_polygon(
		Vector2(-cs * 1.5, -cs * 0.5), Vector2(cs * 1.5, cs * 0.5))
	var keys_wide := VegetationRuntime.chunk_keys_for_polygon(wide)
	_check("a wide polygon spans several chunks", keys_wide.size() >= 4, str(keys_wide.size()))
	_check("degenerate polygon touches nothing",
		VegetationRuntime.chunk_keys_for_polygon(PackedVector2Array()).is_empty())

	# Batch node names carry their chunk, which is how the rebuild knows what to
	# free. All three builders name differently; all three must parse.
	_check("plain batch name parses",
		VegetationRuntime.chunk_of_batch_node("Bulk_pine_3_-2") == Vector2i(3, -2))
	_check("tiered batch name parses",
		VegetationRuntime.chunk_of_batch_node("Bulk_deciduous_0_5_7") == Vector2i(5, 7))
	_check("impostor batch name parses",
		VegetationRuntime.chunk_of_batch_node("Bulk_pine_imp_-1_4") == Vector2i(-1, 4))
	_check("a non-batch node has no chunk",
		VegetationRuntime.chunk_of_batch_node("VegLeafFall") == null)

	# Full rebuild vs incremental, over the same layer.
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var settings := {"auto_visibility_end_m": 800.0}
	var layer := AutoVegetationLayer.create_empty()
	# Three chunks' worth of trees: one inside the edit, two outside.
	for i in 8:
		layer.add_bulk("pine", 20.0 + float(i), 20.0, 0.0, 1.0, 10.0)          # chunk 0,0
		layer.add_bulk("pine", cs * 2.0 + float(i), 20.0, 0.0, 1.0, 10.0)      # chunk 2,0
		layer.add_bulk("pine", 20.0, cs * 3.0 + float(i), 0.0, 1.0, 10.0)      # chunk 0,3
	var full_terrain := Node3D.new()
	get_root().add_child(full_terrain)
	AutoVegetationRuntime.rebuild(full_terrain, layer, ground, settings)
	var full_names := _batch_name_set(full_terrain)
	_check("full rebuild produced batches", full_names.size() > 0)

	var inc_terrain := Node3D.new()
	get_root().add_child(inc_terrain)
	AutoVegetationRuntime.rebuild(inc_terrain, layer, ground, settings)
	# Now edit chunk 0,0 only: drop its trees and rebuild just that chunk.
	var edit_poly := VegetationPaint.rect_to_polygon(Vector2(0.0, 0.0), Vector2(60.0, 60.0))
	var edit_keys := VegetationRuntime.chunk_keys_for_polygon(edit_poly)
	var removed := layer.remove_in_polygon(edit_poly)
	_check("edit removed the chunk's trees", removed == 8, "got %d" % removed)
	var rebuilt := AutoVegetationRuntime.rebuild_chunks(
		inc_terrain, layer, ground, settings, edit_keys)
	_check("incremental freed the edited chunk's batches", rebuilt > 0, "got %d" % rebuilt)

	# The authority: a full rebuild of the SAME edited layer must produce the
	# same set of batch nodes the incremental path left behind.
	var ref_terrain := Node3D.new()
	get_root().add_child(ref_terrain)
	AutoVegetationRuntime.rebuild(ref_terrain, layer, ground, settings)
	var inc_names := _batch_name_set(inc_terrain)
	var ref_names := _batch_name_set(ref_terrain)
	_check("incremental == full rebuild after the edit", inc_names == ref_names,
		"inc=%s ref=%s" % [str(inc_names), str(ref_names)])
	_check("the edited chunk is gone from both",
		not inc_names.has("Bulk_pine_0_0") and not ref_names.has("Bulk_pine_0_0"),
		str(inc_names))
	_check("untouched chunks survived", inc_names.size() >= 2, str(inc_names))
	_check("incremental kept the same instance total",
		_batch_instance_total(inc_terrain) == _batch_instance_total(ref_terrain),
		"%d vs %d" % [_batch_instance_total(inc_terrain), _batch_instance_total(ref_terrain)])

	# A chunk set that matches nothing is a no-op, not a wipe.
	var before := _batch_name_set(inc_terrain).size()
	AutoVegetationRuntime.rebuild_chunks(inc_terrain, layer, ground, settings,
		{Vector2i(99, 99): true})
	_check("rebuilding an empty chunk changes nothing",
		_batch_name_set(inc_terrain).size() == before)
	_check("an empty chunk set is refused",
		AutoVegetationRuntime.rebuild_chunks(inc_terrain, layer, ground, settings, {}) == 0)

	full_terrain.queue_free()
	inc_terrain.queue_free()
	ref_terrain.queue_free()


func _batch_name_set(terrain: Node3D) -> Dictionary:
	var out := {}
	var root := terrain.get_node_or_null(AutoVegetationRuntime.ROOT_NAME)
	if root == null:
		return out
	for child in root.get_children():
		if child is MultiMeshInstance3D and not child.is_queued_for_deletion():
			out[str(child.name)] = true
	return out


func _batch_instance_total(terrain: Node3D) -> int:
	var n := 0
	var root := terrain.get_node_or_null(AutoVegetationRuntime.ROOT_NAME)
	if root == null:
		return 0
	for child in root.get_children():
		if child is MultiMeshInstance3D and not child.is_queued_for_deletion():
			var mm: MultiMesh = (child as MultiMeshInstance3D).multimesh
			if mm != null:
				n += mm.instance_count
	return n


## --- WYSIWYG parity: preview settings == render settings -------------------

## The Tune-look studio and the map render path must resolve the SAME store
## state to the IDENTICAL mesh — every "preview looks different from my
## painted trees" bug traced back to these two paths diverging.
func _test_preview_parity() -> void:
	VegStyleStore.path_suffix = ".paritytest"
	VegStyleStore.invalidate_cache()
	for p in [VegStyleStore.global_v2_path(), VegStyleStore.map_v2_path(0.0, 0.0)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	VegStyleStore.invalidate_cache()
	# A family edit + a species override + an archetype switch in the store.
	VegetationStyleConfig.save_global({"deciduous_height_m": 19.0,
		"deciduous_archetype": "spreading"})
	VegetationStyleConfig.save_species_default("maple", {"deciduous_crown_width_m": 9.0})
	var flat := VegStyleStore.flat_merged(0.0, 0.0)
	VegAssetCache.clear()
	# RENDER path: what a painted/auto maple batch builds from the flat style.
	var render_mesh := VegetationCardFactory.mesh_for_canopy_lod("maple", flat,
		VegetationCardFactory.CanopyLodTier.NEAR)
	# PREVIEW path: the modal's own merged settings over the same state.
	var editor_script: GDScript = load("res://scenes/ui/vegetation_preview_editor.gd")
	var editor: Control = editor_script.new()
	editor._species = "maple"
	editor._load_from_state({}, flat)
	var merged: Dictionary = editor._merged_settings()
	VegAssetCache.clear()
	var preview_mesh := VegetationCardFactory.mesh_for_canopy_lod("maple", merged,
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("parity: same surface count",
		render_mesh.get_surface_count() == preview_mesh.get_surface_count())
	for si in mini(render_mesh.get_surface_count(), preview_mesh.get_surface_count()):
		var va: PackedVector3Array = render_mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
		var vb: PackedVector3Array = preview_mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
		_check("parity: surface %d vert count" % si, va.size() == vb.size(),
			"%d vs %d" % [va.size(), vb.size()])
	var ra := render_mesh.get_aabb()
	var rb := preview_mesh.get_aabb()
	_check("parity: identical AABB", ra.size.is_equal_approx(rb.size),
		"render %s vs preview %s" % [str(ra.size), str(rb.size)])
	# maple SPECS height 16 × family ratio (user 19 / default 14) = 21.71 —
	# proves the store edits actually resolved rather than both paths agreeing
	# on stale defaults.
	_check("parity: the store edits actually resolved",
		absf(ra.size.y - 16.0 * 19.0 / 14.0) < 0.05,
		"got %.2f" % ra.size.y)
	editor.free()
	for p in [VegStyleStore.global_v2_path(), VegStyleStore.map_v2_path(0.0, 0.0)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	VegStyleStore.path_suffix = ""
	VegStyleStore.invalidate_cache()
	VegAssetCache.clear()


## --- Deciduous branch distribution (the "bunched at the trunk" rebuild) ------

## Asserted against VegetationCardFactory.deciduous_primary_placements, which is
## the SAME function the mesh builder consumes. A test that re-derived the
## placement maths here would pass happily against a broken generator.
func _test_deciduous_branch_distribution() -> void:
	var st := VegetationStyleConfig.defaults()
	# v3: builder params come from the archetype/macro adapter (the raw style
	# no longer carries branch keys) — assert against the SAME derived dict the
	# mesh builder consumes.
	var d_spec := VegetationCardFactory._deciduous_spec(st)
	var s := VegetationCardFactory._deciduous_adapter_settings(d_spec, st)
	var trunk_h := float(d_spec["trunk_h"])
	var trunk_w := float(d_spec["trunk_w"])
	var places := VegetationCardFactory.deciduous_primary_placements(trunk_w, trunk_h, s)
	var n := clampi(int(round(float(s["deciduous_branch_count"]))), 2, 12)
	_check("one placement per primary", places.size() == n, "got %d" % places.size())

	# 1. Attachment heights must SPREAD over the crown-bearing trunk. The old
	# generator packed every primary into the top ~30% with zero jitter.
	var lo := INF
	var hi := -INF
	for p in places:
		var y := float((p as Dictionary)["height"])
		lo = minf(lo, y)
		hi = maxf(hi, y)
	var span := (hi - lo) / maxf(trunk_h, 0.01)
	_check("attachment span covers >=40% of the trunk", span >= 0.40,
		"span %.0f%% (%.2f..%.2f of %.2f)" % [span * 100.0, lo, hi, trunk_h])
	_check("lowest limb sits near the crown base",
		lo <= trunk_h * float(s["deciduous_crown_base"]) + trunk_h * 0.12,
		"lowest %.2f, crown base %.2f" % [lo, trunk_h * float(s["deciduous_crown_base"])])
	_check("highest limb stays on the trunk", hi <= trunk_h * 1.001,
		"highest %.2f of %.2f" % [hi, trunk_h])

	# 2. No two primaries may share an azimuth. The old jitter was 0..34 deg
	# ONE-SIDED against a 21.8 deg golden gap, so pairs landed on top of each
	# other — the visible bunching.
	var azs: Array = []
	for p in places:
		azs.append(float((p as Dictionary)["azimuth"]))
	azs.sort()
	var min_gap := TAU
	for i in azs.size():
		var a: float = azs[i]
		var b: float = azs[(i + 1) % azs.size()]
		min_gap = minf(min_gap, fposmod(b - a, TAU))
	_check("primaries never collide in azimuth", rad_to_deg(min_gap) > 8.0,
		"min gap %.1f deg over %d primaries" % [rad_to_deg(min_gap), n])

	# 3. Limbs emerge from the trunk SURFACE, not the centre line — the first
	# ~0.65 m of every limb used to be buried inside the trunk card.
	var on_axis := 0
	for p in places:
		var o: Vector3 = (p as Dictionary)["origin"]
		if Vector2(o.x, o.z).length() < 1e-4:
			on_axis += 1
	_check("no primary starts on the trunk axis", on_axis == 0, "%d on axis" % on_axis)

	# 4. Low limbs reach OUT, high limbs reach UP: that gradient is what stops
	# the crown floating on a bare pole.
	var first: Dictionary = places[0]
	var last: Dictionary = places[places.size() - 1]
	_check("lowest limb is flatter than the highest",
		(first["dir"] as Vector3).y < (last["dir"] as Vector3).y,
		"low y=%.2f high y=%.2f" % [(first["dir"] as Vector3).y, (last["dir"] as Vector3).y])

	# 5. Species archetypes actually reach the builder: birch (columnar) vs
	# chestnut (spreading) differ in the archetype table AND in built geometry.
	var birch := VegSpeciesCatalog.settings_with_variant("birch", st, VegetationCardFactory.SPECS)
	var chestnut := VegSpeciesCatalog.settings_with_variant("chestnut", st, VegetationCardFactory.SPECS)
	_check("birch resolves columnar",
		str(birch["deciduous_archetype"]) == "columnar",
		"got %s" % str(birch.get("deciduous_archetype")))
	_check("chestnut resolves spreading",
		str(chestnut["deciduous_archetype"]) == "spreading")
	_check("spreading splays wider than columnar (archetype table)",
		float(VegTreeArchetypes.ARCHETYPES["spreading"]["tilt_low"])
			> float(VegTreeArchetypes.ARCHETYPES["columnar"]["tilt_low"]))
	# ...and produce genuinely different trees, not just different numbers.
	var b_mesh := VegetationCardFactory.mesh_for_canopy_lod("birch", st,
		VegetationCardFactory.CanopyLodTier.NEAR)
	var c_mesh := VegetationCardFactory.mesh_for_canopy_lod("chestnut", st,
		VegetationCardFactory.CanopyLodTier.NEAR)
	_check("archetypes yield different geometry",
		b_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
			!= c_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		or not is_equal_approx(b_mesh.get_aabb().size.x, c_mesh.get_aabb().size.x),
		"birch w %.2f chestnut w %.2f" % [b_mesh.get_aabb().size.x, c_mesh.get_aabb().size.x])

	# 6. The NEAR tree must stay inside its triangle budget at the shipping
	# defaults (v3 baseline ~6.6k; NEAR only exists inside the detail range,
	# so the per-tree cost is structurally bounded).
	var near := VegetationCardFactory.mesh_for_canopy_lod("deciduous", st,
		VegetationCardFactory.CanopyLodTier.NEAR)
	var tris := 0
	for si in near.get_surface_count():
		tris += (near.surface_get_arrays(si)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	_check("NEAR deciduous stays within the tri budget", tris <= 7200,
		"%d tris" % tris)
	_check("NEAR deciduous still has geometry", tris > 1500, "%d tris" % tris)
	# Nothing may dip below the foot at either tier (foot_local_y is hardcoded 0).
	for tier in [VegetationCardFactory.CanopyLodTier.NEAR,
			VegetationCardFactory.CanopyLodTier.FAR]:
		var m := VegetationCardFactory.mesh_for_canopy_lod("maple", st, tier)
		_check("maple tier %d foot at origin" % tier, m.get_aabb().position.y >= -0.001,
			"foot %.3f" % m.get_aabb().position.y)

	# 7. EXACT SIZE (the v3 headline contract): height == authored ±1 cm at
	# every archetype; crown RADIAL width within −20%/+15% of authored (radial,
	# not AABB — a diagonal clump under-fills the axis-aligned box).
	for sid in ["deciduous", "birch", "chestnut", "maple", "pine", "spruce"]:
		var fam := VegSpeciesCatalog.mesh_family(sid)
		var res := VegSpeciesCatalog.settings_with_variant(sid, st, VegetationCardFactory.SPECS)
		var want_h := float(res["%s_height_m" % fam])
		var want_w := float(res["%s_crown_width_m" % fam])
		var m2 := VegetationCardFactory.mesh_for_canopy_lod(sid, st,
			VegetationCardFactory.CanopyLodTier.NEAR)
		var max_y := 0.0
		var max_r := 0.0
		for si in m2.get_surface_count():
			for v in m2.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				var p3 := v as Vector3
				max_y = maxf(max_y, p3.y)
				max_r = maxf(max_r, Vector2(p3.x, p3.z).length())
		_check("%s height is exact" % sid, absf(max_y - want_h) < 0.02,
			"built %.3f authored %.1f" % [max_y, want_h])
		_check("%s crown width lands near authored" % sid,
			max_r * 2.0 >= want_w * 0.80 and max_r * 2.0 <= want_w * 1.15,
			"built %.2f authored %.1f" % [max_r * 2.0, want_w])
		_check("%s foot at origin" % sid, m2.get_aabb().position.y >= -0.02,
			"foot %.3f" % m2.get_aabb().position.y)
