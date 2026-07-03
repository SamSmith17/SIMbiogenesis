extends SceneTree

## Headless self-test for BuildingBuilder geometry (pure / offline — no network).
## Run with:
##   godot --headless --path . --script core/terrain/building_builder_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const GRID_RES := 8
const EXTENT_M := 100.0
const SLOPE := 0.2  # ~11° tilt along +X

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_level_roof_on_slope()
	_test_pyramid_apex_on_slope()
	if _failures == 0:
		print("BUILDING SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("BUILDING SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


## DEM tilted along +X: elevation = SLOPE * x_world.
func _tilted_grid() -> PackedFloat32Array:
	var elev := PackedFloat32Array()
	elev.resize(GRID_RES * GRID_RES)
	for row in GRID_RES:
		for col in GRID_RES:
			var x := -EXTENT_M * 0.5 + EXTENT_M * float(col) / float(GRID_RES - 1)
			elev[row * GRID_RES + col] = SLOPE * x
	return elev


func _square_poly(half: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half)])


func _lowest_corner_sample(poly: PackedVector2Array, elev: PackedFloat32Array) -> float:
	var base := INF
	for p in poly:
		base = minf(base, TerrainBuilder.sample_footing_height(
			p.x, p.y, elev, GRID_RES, EXTENT_M, 0.0))
	return base


func _build_vertices(poly: PackedVector2Array, height_m: float, roof: Dictionary) -> PackedVector3Array:
	var buildings := [{"idx": 0, "points": poly, "height_m": height_m, "tags": {}, "roof": roof}]
	var node := BuildingBuilder.build_buildings_node(
		buildings, _tilted_grid(), GRID_RES, EXTENT_M, 0.0, null)
	if node == null:
		return PackedVector3Array()
	var mi := node.get_node_or_null("BuildingMeshes") as MeshInstance3D
	var verts: PackedVector3Array = PackedVector3Array()
	if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
		verts = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	node.free()
	return verts


func _test_level_roof_on_slope() -> void:
	var poly := _square_poly(5.0)
	var height_m := 8.0
	var verts := _build_vertices(poly, height_m,
		{"shape": "flat", "angle_deg": 30.0, "orientation": "along",
			"direction_deg": NAN, "roof_height_m": 0.0})
	_check("flat: mesh built", not verts.is_empty())
	if verts.is_empty():
		return

	var base_y := _lowest_corner_sample(poly, _tilted_grid())
	_check("flat: DEM actually sloped under footprint", base_y < -0.5,
		"lowest corner sample %f" % base_y)

	var min_y := INF
	var max_y := -INF
	for v in verts:
		min_y = minf(min_y, v.y)
		max_y = maxf(max_y, v.y)

	# Roof top sits exactly height_m above the lowest corner sample.
	_check("flat: roof top = base + height", absf(max_y - (base_y + height_m)) < 1e-3,
		"max_y %f expected %f" % [max_y, base_y + height_m])

	# Level-roof invariant: every vertex near the top is at the SAME height
	# (pre-fix the roof followed the terrain and spanned ~SLOPE * 10 m).
	var top_spread := 0.0
	for v in verts:
		if v.y > max_y - 0.5:
			top_spread = maxf(top_spread, max_y - v.y)
	_check("flat: roof is level on slope", top_spread < 1e-3, "spread %f" % top_spread)

	# Skirt invariant: walls extend below the lowest ground sample.
	_check("flat: skirt below lowest sample",
		min_y <= base_y and absf(min_y - (base_y - BuildingBuilder.FOUNDATION_SKIRT_M)) < 1e-3,
		"min_y %f base_y %f" % [min_y, base_y])


func _test_pyramid_apex_on_slope() -> void:
	var poly := _square_poly(5.0)
	var height_m := 8.0
	var verts := _build_vertices(poly, height_m,
		{"shape": "pyramidal", "angle_deg": 30.0, "orientation": "along",
			"direction_deg": NAN, "roof_height_m": 0.0})
	_check("pyramid: mesh built", not verts.is_empty())
	if verts.is_empty():
		return

	var base_y := _lowest_corner_sample(poly, _tilted_grid())
	var max_y := -INF
	for v in verts:
		max_y = maxf(max_y, v.y)
	_check("pyramid: apex = base + height", absf(max_y - (base_y + height_m)) < 1e-3,
		"max_y %f expected %f" % [max_y, base_y + height_m])

	# All eave corners level: vertices in the eave band share one height.
	var eave_candidates: Array[float] = []
	for v in verts:
		if v.y > base_y + 0.5 and v.y < max_y - 0.5:
			eave_candidates.append(v.y)
	_check("pyramid: has eave ring", not eave_candidates.is_empty())
	if not eave_candidates.is_empty():
		var lo: float = eave_candidates[0]
		var hi: float = eave_candidates[0]
		for y in eave_candidates:
			lo = minf(lo, y)
			hi = maxf(hi, y)
		_check("pyramid: eaves level on slope", hi - lo < 1e-3, "spread %f" % (hi - lo))
