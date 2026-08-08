extends SceneTree

## Headless self-test for vegetation paint helpers (Poisson, polygon, JSON).
## Run with:
##   godot --headless --path . --script vegetation/vegetation_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_polygon()
	_test_poisson_spacing()
	_test_square_grid_fill()
	_test_species_mix()
	_test_bulk_patch()
	_test_json_roundtrip()
	_test_transform_ground_y()
	_test_style_defaults_and_materials()
	_test_osm_species_override()
	if _failures == 0:
		print("VEGETATION SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEGETATION SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_polygon() -> void:
	var rect := VegetationPaint.rect_to_polygon(Vector2(-10.0, -5.0), Vector2(10.0, 5.0))
	_check("rect polygon 4 verts", rect.size() == 4)
	_check("rect area 200 m2", absf(VegetationPaint.polygon_area(rect) - 200.0) < 0.01)
	_check("center inside rect", VegetationPaint.point_in_polygon(Vector2.ZERO, rect))
	_check("outside rect", not VegetationPaint.point_in_polygon(Vector2(20.0, 0.0), rect))
	var circle := VegetationPaint.circle_polygon(Vector2.ZERO, 10.0, 32)
	_check("circle polygon verts", circle.size() == 32)
	_check("circle area ~314 m2", absf(VegetationPaint.polygon_area(circle) - PI * 100.0) < 5.0)
	_check("circle center inside", VegetationPaint.point_in_polygon(Vector2.ZERO, circle))
	var clamped := VegetationPaint.clamp_polygon_radius(circle, Vector2.ZERO, 5.0)
	_check("clamp radius shrinks", clamped[0].length() <= 5.01)
	_check("estimate fill count", VegetationPaint.estimate_fill_count(rect, 4.0) > 0)
	var noisy := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.01), Vector2(2.0, 0.0), Vector2(3.0, 0.0),
	])
	var simplified := VegetationPaint.simplify_polyline(noisy, 0.5)
	_check("polyline simplify keeps endpoints", simplified.size() >= 2)


func _test_poisson_spacing() -> void:
	var poly := VegetationPaint.rect_to_polygon(Vector2(-20.0, -20.0), Vector2(20.0, 20.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var spacing := 4.0
	var spots := VegetationPaint.poisson_fill(poly, spacing, rng, [], 200)
	_check("poisson produces instances", spots.size() > 5, "got %d" % spots.size())
	var min_dist_sq := spacing * spacing * 0.99
	for i in spots.size():
		var a := Vector2(float(spots[i]["x"]), float(spots[i]["z"]))
		for j in range(i + 1, spots.size()):
			var b := Vector2(float(spots[j]["x"]), float(spots[j]["z"]))
			_check("poisson min spacing", a.distance_squared_to(b) >= min_dist_sq,
				"%.2f m apart" % sqrt(a.distance_squared_to(b)))


func _test_square_grid_fill() -> void:
	var poly := VegetationPaint.rect_to_polygon(Vector2(-10.0, -10.0), Vector2(10.0, 10.0))
	var mat_w := 0.45
	var spots := VegetationPaint.square_grid_fill(poly, mat_w, [], 500)
	_check("square grid produces instances", spots.size() > 10, "got %d" % spots.size())
	for spot in spots:
		var yaw := float(spot.get("yaw", 0.0))
		var rem := fmod(yaw, PI / 2.0)
		_check("square grid 90-deg yaw", absf(rem) < 1e-5 or absf(rem - PI / 2.0) < 1e-5)
		_check("square grid unit scale", absf(float(spot.get("scale", 1.0)) - 1.0) < 1e-5)
	var defs := VegetationStyleConfig.defaults()
	var near := VegetationCardFactory.mesh_for_deciduous_lod(
		defs, VegetationCardFactory.CanopyLodTier.NEAR)
	var far := VegetationCardFactory.mesh_for_deciduous_lod(
		defs, VegetationCardFactory.CanopyLodTier.FAR)
	_check("deciduous near lod mesh", near != null and near.get_surface_count() == 3)
	_check("deciduous far lod mesh", far != null and far.get_surface_count() == 2)
	var proxy_mat := near.surface_get_material(1) as ShaderMaterial
	var leaf_surf_mat := near.surface_get_material(2) as ShaderMaterial
	_check("deciduous shadow proxy", proxy_mat != null
		and float(proxy_mat.get_shader_parameter("color_fade")) < 0.15)
	_check("deciduous leaf overlay", leaf_surf_mat != null and leaf_surf_mat.shader != null)
	var pine_near := VegetationCardFactory.mesh_for_pine_lod(
		defs, VegetationCardFactory.CanopyLodTier.NEAR)
	var pine_far := VegetationCardFactory.mesh_for_pine_lod(
		defs, VegetationCardFactory.CanopyLodTier.FAR)
	_check("pine near lod mesh", pine_near != null and pine_near.get_surface_count() == 2)
	_check("pine far lod mesh", pine_far != null and pine_far.get_surface_count() == 2)
	var pine_near_mat := pine_near.surface_get_material(1) as ShaderMaterial
	var pine_far_mat := pine_far.surface_get_material(1) as ShaderMaterial
	_check("pine near fur", pine_near_mat != null
		and float(pine_near_mat.get_shader_parameter("fur_strength")) > 0.2)
	_check("pine far plain", pine_far_mat != null
		and float(pine_far_mat.get_shader_parameter("fur_strength")) < 0.01)
	var leaf_mat := VegetationCardFactory.leaf_canopy_material_for_species("deciduous", defs)
	_check("leaf canopy material", leaf_mat != null and leaf_mat.shader != null)
	var lawn_mesh := GrassBuilder.mesh_for_lod("grass_lawn", {}, GrassBuilder.LodTier.NEAR)
	_check("lawn hex shell mesh", lawn_mesh != null and lawn_mesh.get_surface_count() > 0)


func _test_species_mix() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	_check("pine preset", VegetationPaint.pick_species(
		VegetationPaint.Preset.PINE, 0.0, 0.0, 1.0, rng) == "pine")
	_check("decid preset", VegetationPaint.pick_species(
		VegetationPaint.Preset.DECIDUOUS, 1.0, 0.0, 0.0, rng) == "deciduous")
	var counts := {"pine": 0, "deciduous": 0, "shrub": 0}
	for _i in 300:
		var s := VegetationPaint.pick_species(
			VegetationPaint.Preset.MIX, 0.4, 0.4, 0.2, rng)
		counts[s] = counts.get(s, 0) + 1
	_check("mix assigns all species", counts["pine"] > 0 and counts["deciduous"] > 0 and counts["shrub"] > 0)


func _test_bulk_patch() -> void:
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0)
	layer.add_bulk("pine", 20.0, 0.0, 0.0, 1.0)
	var poly := VegetationPaint.circle_polygon(Vector2.ZERO, 5.0, 16)
	var n := layer.patch_bulk_in_polygon(poly, {"scale_mul": 2.0})
	_check("patch hits one tree", n == 1)
	var inner: Dictionary = layer.bulk["pine"][0]
	var outer: Dictionary = layer.bulk["pine"][1]
	_check("patch doubles inner scale", absf(float(inner.get("scale", 0.0)) - 2.0) < 0.01)
	_check("patch skips outer scale", absf(float(outer.get("scale", 0.0)) - 1.0) < 0.01)
	_check("count in polygon", layer.count_bulk_in_polygon(poly) == 1)


func _test_json_roundtrip() -> void:
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("shrub", 1.5, -2.0, 0.5, 1.1)
	layer.add_bulk("pine", 3.0, 4.0, 1.2, 0.9)
	layer.add_hero("pine_1", 0.0, 0.0, 0.0, 1.4)
	var data := layer.serialize()
	var restored := VegetationLayer.create_empty()
	restored.deserialize(data)
	_check("bulk shrub count", restored.bulk["shrub"].size() == 1)
	_check("bulk pine count", restored.bulk["pine"].size() == 1)
	_check("hero count", restored.hero.size() == 1)
	_check("hero preset preserved", str(restored.hero[0].get("preset", "")) == "pine_1")
	var path := layer.save_path_for_map(47.6062, -122.3321)
	_check("save path under user maps", path.begins_with("user://maps/vegetation_"))
	_test_card_settings_json()


## Regression: "Apply to brush" stamps a Color tint into per-instance
## card_settings. Plain JSON.stringify would turn that Color into a String
## ("(r, g, b, a)"), and the card factory's typed `Color` assignment would then
## throw on reload — the map "sometimes fails to load". Verify the full
## stringify -> parse -> deserialize cycle restores a real Color.
func _test_card_settings_json() -> void:
	var layer := VegetationLayer.create_empty()
	# All four color-valued tint families the card factory/grass builder read
	# via a typed `var x: Color = settings.get(...)` — a regression test for the
	# bug where only "_albedo_tint" round-tripped and "_highlight_tint" (etc.)
	# stayed a raw [r,g,b,a] array, crashing "map load" the instant a saved site
	# had a non-default highlight/bark/seasonal tint (see coerce_card_colors).
	var card := {
		"pine_card_h": 6.5,
		"pine_albedo_tint": Color(0.8, 0.5, 0.3, 1.0),
		"pine_highlight_tint": Color(0.1, 0.6, 0.2, 1.0),
		"pine_bark_tint": Color(0.4, 0.3, 0.2, 1.0),
		"seasonal_tint": Color(0.9, 0.7, 0.1, 1.0),
	}
	layer.add_bulk("pine", 2.0, 2.0, 0.0, 1.3, card)
	var text := JSON.stringify(layer.serialize())
	var parsed: Variant = JSON.parse_string(text)
	_check("card json parses", parsed is Dictionary)
	var restored := VegetationLayer.create_empty()
	restored.deserialize(parsed as Dictionary)
	var recs: Array = restored.bulk.get("pine", [])
	_check("card record restored", recs.size() == 1)
	if recs.size() == 1:
		var cs: Dictionary = (recs[0] as Dictionary).get("card_settings", {})
		_check("card tint is Color after roundtrip", cs.get("pine_albedo_tint") is Color)
		var c: Color = cs.get("pine_albedo_tint", Color.WHITE)
		_check("card tint value preserved",
			absf(c.r - 0.8) < 1e-3 and absf(c.g - 0.5) < 1e-3 and absf(c.b - 0.3) < 1e-3)
		_check("card scalar preserved", absf(float(cs.get("pine_card_h", 0.0)) - 6.5) < 1e-3)
		_check("card highlight tint is Color after roundtrip",
			cs.get("pine_highlight_tint") is Color, "got %s" % [typeof(cs.get("pine_highlight_tint"))])
		_check("card bark tint is Color after roundtrip",
			cs.get("pine_bark_tint") is Color, "got %s" % [typeof(cs.get("pine_bark_tint"))])
		_check("card seasonal tint is Color after roundtrip",
			cs.get("seasonal_tint") is Color, "got %s" % [typeof(cs.get("seasonal_tint"))])
	# Legacy-corrupt recovery: a String tint (old broken save) coerces to Color.
	var legacy := VegetationLayer.coerce_card_colors({"pine_albedo_tint": "(0.2, 0.4, 0.6, 1.0)"})
	_check("legacy string tint coerces to Color", legacy.get("pine_albedo_tint") is Color)
	# The actual bug: coerce_card_colors used to only match "_albedo_tint",
	# leaving these three as raw arrays for _apply_foliage_uniforms /
	# _apply_leaf_canopy_uniforms / grass_builder's typed Color reads to crash on.
	var mixed := VegetationLayer.coerce_card_colors({
		"pine_highlight_tint": [0.1, 0.6, 0.2, 1.0],
		"pine_bark_tint": [0.4, 0.3, 0.2, 1.0],
		"seasonal_tint": [0.9, 0.7, 0.1, 1.0],
	})
	_check("array highlight tint coerces to Color", mixed.get("pine_highlight_tint") is Color)
	_check("array bark tint coerces to Color", mixed.get("pine_bark_tint") is Color)
	_check("array seasonal tint coerces to Color", mixed.get("seasonal_tint") is Color)


func _test_transform_ground_y() -> void:
	var xf := VegetationPaint.build_transform(1.0, 12.0, 2.0, 0.5, 1.0, false, Vector3.UP)
	_check("transform Y sinks", absf(xf.origin.y - (12.0 - VegetationPaint.GROUND_SINK_M)) < 1e-5)
	_check("transform XZ", absf(xf.origin.x - 1.0) < 1e-5 and absf(xf.origin.z - 2.0) < 1e-5)


func _test_style_defaults_and_materials() -> void:
	var defs := VegetationStyleConfig.defaults()
	for k in ["translucency_strength", "canopy_roundness", "color_variation",
			"foliage_roughness", "ao_strength", "bark_roughness",
			"bark_ao_strength", "bark_color_jitter",
			"pine_whorl_count", "deciduous_cluster_count", "deciduous_branch_count"]:
		_check("style default %s" % k, defs.has(k))
	var settings := defs.duplicate(true)
	settings["pine_whorl_count"] = 10
	settings["deciduous_cluster_count"] = 12
	settings["deciduous_branch_count"] = 6
	for species in ["pine", "deciduous", "shrub"]:
		var mesh := VegetationCardFactory.mesh_for_species(species, settings)
		_check("%s preview mesh" % species, mesh != null and mesh.get_surface_count() > 0)
		var mat := VegetationCardFactory.material_for_species(species, settings)
		_check("%s preview mat" % species, mat != null)
		_check("%s translucency uniform" % species,
			mat.get_shader_parameter("translucency_strength") != null)
		var bark := VegetationCardFactory.bark_material_for_species(species, settings)
		_check("%s bark mat" % species, bark != null)
		_check("%s bark jitter uniform" % species,
			bark.get_shader_parameter("bark_color_jitter") != null)


func _test_osm_species_override() -> void:
	_check("osm_species_map default present",
		VegetationStyleConfig.defaults().has("osm_species_map"))
	_check("auto override empty",
		BiomePalette.species_override_for_kind({}, "wood").is_empty())
	_check("auto value empty",
		BiomePalette.species_override_for_kind({"wood": "auto"}, "wood").is_empty())
	_check("pine override",
		BiomePalette.species_override_for_kind({"wood": "pine"}, "wood").has("pine"))
	_check("shrub override single",
		BiomePalette.override_single_species(
			BiomePalette.species_override_for_kind({"wood": "shrub"}, "wood"), "deciduous") == "shrub")
	_check("mixed override two species",
		BiomePalette.species_override_for_kind({"scrub": "mixed"}, "scrub").size() == 2)

	# End-to-end: a wood polygon forced to pine must scatter only pine.
	var square := PackedVector2Array([
		Vector2(-40, -40), Vector2(40, -40), Vector2(40, 40), Vector2(-40, 40)])
	var payload := {"polygons": [{"points": square, "kind": "wood", "tags": {}}]}
	var ctx := {"latitude": 42.0, "seed": 7, "half_extent_m": 100.0,
		"style": {"osm_species_map": {"wood": "pine"}}}
	var layer := AutoVegetationGenerator.generate(payload, ctx)
	var only_pine := layer.bulk.has("pine") and not layer.bulk.has("deciduous")
	_check("forced pine wood scatters pine only", only_pine and layer.total_bulk() > 0,
		"bulk keys=%s" % str(layer.bulk.keys()))

	# Round-trip osm_species_map through the JSON style persistence.
	var saved := VegetationStyleConfig._color_dict_to_json({"osm_species_map": {"wood": "pine"}})
	var loaded := VegetationStyleConfig._json_to_color_dict(saved)
	_check("osm map survives json roundtrip",
		str((loaded.get("osm_species_map", {}) as Dictionary).get("wood", "")) == "pine")
