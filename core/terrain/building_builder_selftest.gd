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
	_test_roof_defaults()
	_test_winding_and_normals()
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


func _test_roof_defaults() -> void:
	var house_poly := _square_poly(4.0)  # 64 m²
	var big_poly := _square_poly(15.0)  # 900 m²
	var long_poly := PackedVector2Array([
		Vector2(-10, -4), Vector2(10, -4), Vector2(10, 4), Vector2(-10, 4)])  # 160 m², aspect 2.5

	var spec := BuildingBuilder.infer_roof_spec({"building": "house"}, house_poly)
	_check("defaults: house → gabled", str(spec["shape"]) == "gabled", "got %s" % spec["shape"])
	_check("defaults: house angle 28°", absf(float(spec["angle_deg"]) - 28.0) < 0.01,
		"got %f" % float(spec["angle_deg"]))
	_check("defaults: provenance default", str(spec.get("source", "")) == "default")

	spec = BuildingBuilder.infer_roof_spec({"building": "warehouse"}, house_poly)
	_check("defaults: warehouse → flat", str(spec["shape"]) == "flat", "got %s" % spec["shape"])

	spec = BuildingBuilder.infer_roof_spec(
		{"building": "house", "roof:shape": "flat"}, house_poly)
	_check("defaults: explicit roof:shape wins", str(spec["shape"]) == "flat",
		"got %s" % spec["shape"])
	_check("defaults: provenance osm", str(spec.get("source", "")) == "osm")

	spec = BuildingBuilder.infer_roof_spec({"building": "yes"}, long_poly)
	_check("defaults: yes small+elongated → gabled", str(spec["shape"]) == "gabled",
		"got %s" % spec["shape"])

	spec = BuildingBuilder.infer_roof_spec({"building": "yes"}, big_poly)
	_check("defaults: yes large → flat", str(spec["shape"]) == "flat", "got %s" % spec["shape"])

	spec = BuildingBuilder.infer_roof_spec(
		{"building": "house", "roof:angle": "40"}, house_poly)
	_check("defaults: gabled keeps tagged angle", absf(float(spec["angle_deg"]) - 40.0) < 0.01,
		"got %f" % float(spec["angle_deg"]))


func _test_winding_and_normals() -> void:
	var ccw := _square_poly(5.0)
	var cw := ccw.duplicate()
	cw.reverse()
	var fixed := BuildingBuilder._ensure_ccw(cw)
	_check("winding: CW square reversed", fixed == ccw or _signed_area(fixed) > 0.0,
		"area %f" % _signed_area(fixed))
	_check("winding: CCW square untouched", BuildingBuilder._ensure_ccw(ccw) == ccw)

	# Build from the CW input on flat-ish ground: orientation must still come out
	# deterministic — roof up, floor down, walls outward.
	var buildings := [{"idx": 0, "points": cw, "height_m": 8.0, "tags": {},
		"roof": {"shape": "flat", "angle_deg": 30.0, "orientation": "along",
			"direction_deg": NAN, "roof_height_m": 0.0}}]
	var node := BuildingBuilder.build_buildings_node(
		buildings, _tilted_grid(), GRID_RES, EXTENT_M, 0.0, null)
	_check("normals: mesh built from CW input", node != null)
	if node == null:
		return
	var mi := node.get_node_or_null("BuildingMeshes") as MeshInstance3D
	var arrays: Array = mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	node.free()

	var max_y := -INF
	var min_y := INF
	for v in verts:
		max_y = maxf(max_y, v.y)
		min_y = minf(min_y, v.y)

	var up_ok := true
	var down_ok := true
	var wall_ok := true
	var ups := 0
	var downs := 0
	var walls := 0
	for t in range(0, verts.size(), 3):
		var nrm := normals[t]
		var cy := (verts[t].y + verts[t + 1].y + verts[t + 2].y) / 3.0
		if nrm.y > 0.9:
			ups += 1
			if cy < max_y - 0.01:
				up_ok = false  # an up-facing tri that isn't the roof
		elif nrm.y < -0.9:
			downs += 1
			if cy > min_y + 0.01:
				down_ok = false  # a down-facing tri that isn't the floor
		else:
			walls += 1
			var mid := (verts[t] + verts[t + 1] + verts[t + 2]) / 3.0
			if Vector2(nrm.x, nrm.z).dot(Vector2(mid.x, mid.z)) <= 0.0:
				wall_ok = false  # wall normal points into the building
	_check("normals: roof faces up", ups > 0 and up_ok, "ups=%d" % ups)
	_check("normals: floor faces down", downs > 0 and down_ok, "downs=%d" % downs)
	_check("normals: walls face outward", walls > 0 and wall_ok, "walls=%d" % walls)


func _signed_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return area * 0.5
