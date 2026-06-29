extends SceneTree

## Headless self-test for vegetation paint helpers (Poisson, polygon, JSON).
## Run with:
##   godot --headless --path . --script vegetation/vegetation_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_polygon()
	_test_poisson_spacing()
	_test_species_mix()
	_test_bulk_patch()
	_test_json_roundtrip()
	_test_transform_ground_y()
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


func _test_transform_ground_y() -> void:
	var xf := VegetationPaint.build_transform(1.0, 12.0, 2.0, 0.5, 1.0, false, Vector3.UP)
	_check("transform Y sinks", absf(xf.origin.y - (12.0 - VegetationPaint.GROUND_SINK_M)) < 1e-5)
	_check("transform XZ", absf(xf.origin.x - 1.0) < 1e-5 and absf(xf.origin.z - 2.0) < 1e-5)
