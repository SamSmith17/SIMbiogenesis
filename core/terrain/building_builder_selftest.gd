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
	_test_gabled_ridge()
	_test_ridge_orientation()
	_test_hipped_faces()
	_test_concave_and_degenerate()
	_test_skillion()
	_test_uvs_and_colors()
	_test_materials()
	_test_style_layer()
	_test_style_overrides()
	_test_single_building_parity()
	_test_modal_script()
	_test_facade_elements()
	_test_wall_pick()
	_test_messy_footprints_render()
	_test_element_layout()
	_test_building_sort()
	_test_default_colors()
	_test_model_catalog()
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


func _highest_corner_sample(poly: PackedVector2Array, elev: PackedFloat32Array) -> float:
	var top := -INF
	for p in poly:
		top = maxf(top, TerrainBuilder.sample_footing_height(
			p.x, p.y, elev, GRID_RES, EXTENT_M, 0.0))
	return top


## All surfaces' data for a building built on the given grid.
func _mesh_data(poly: PackedVector2Array, height_m: float, roof: Dictionary,
		grid: PackedFloat32Array, tags: Dictionary = {}) -> Dictionary:
	var buildings := [{"idx": 0, "points": poly, "height_m": height_m, "tags": tags,
		"roof": roof}]
	var node := BuildingBuilder.build_buildings_node(
		buildings, grid, GRID_RES, EXTENT_M, 0.0, null)
	if node == null:
		return {}
	var mi := node.get_node_or_null("BuildingMeshes") as MeshInstance3D
	var out := {"surface_count": mi.mesh.get_surface_count(),
		"verts": PackedVector3Array(), "normals": PackedVector3Array(),
		"surfaces": []}
	for s in mi.mesh.get_surface_count():
		var arrays: Array = mi.mesh.surface_get_arrays(s)
		(out["surfaces"] as Array).append({
			"verts": arrays[Mesh.ARRAY_VERTEX],
			"normals": arrays[Mesh.ARRAY_NORMAL],
			"uvs": arrays[Mesh.ARRAY_TEX_UV],
			"colors": arrays[Mesh.ARRAY_COLOR],
		})
		out["verts"] = (out["verts"] as PackedVector3Array) + \
			(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
		out["normals"] = (out["normals"] as PackedVector3Array) + \
			(arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array)
	node.free()
	return out


func _build_vertices(poly: PackedVector2Array, height_m: float, roof: Dictionary) -> PackedVector3Array:
	var data := _mesh_data(poly, height_m, roof, _tilted_grid())
	if data.is_empty():
		return PackedVector3Array()
	return data["verts"]


func _test_level_roof_on_slope() -> void:
	var poly := _square_poly(5.0)
	var height_m := 8.0
	var verts := _build_vertices(poly, height_m,
		{"shape": "flat", "angle_deg": 30.0, "orientation": "along",
			"direction_deg": NAN, "roof_height_m": 0.0})
	_check("flat: mesh built", not verts.is_empty())
	if verts.is_empty():
		return

	var foot_low := _lowest_corner_sample(poly, _tilted_grid())
	var foot_high := _highest_corner_sample(poly, _tilted_grid())
	_check("flat: DEM actually sloped under footprint", foot_high - foot_low > 1.0,
		"corner spread %f" % (foot_high - foot_low))

	var min_y := INF
	var max_y := -INF
	for v in verts:
		min_y = minf(min_y, v.y)
		max_y = maxf(max_y, v.y)

	# Roof top sits height_m above the HIGHEST corner: the body seats on the
	# uphill terrain so it never buries, and the foundation fills the downhill gap.
	_check("flat: roof top = highest corner + height",
		absf(max_y - (foot_high + height_m)) < 1e-3,
		"max_y %f expected %f" % [max_y, foot_high + height_m])

	# Level-roof invariant: every vertex near the top is at the SAME height
	# (pre-fix the roof followed the terrain and spanned ~SLOPE * 10 m).
	var top_spread := 0.0
	for v in verts:
		if v.y > max_y - 0.5:
			top_spread = maxf(top_spread, max_y - v.y)
	_check("flat: roof is level on slope", top_spread < 1e-3, "spread %f" % top_spread)

	# Foundation invariant: the skirt reaches down to the LOWEST corner (+embed)
	# so the downhill side rests on a plinth instead of floating.
	_check("flat: foundation fills to lowest corner",
		absf(min_y - (foot_low - BuildingBuilder.FOUNDATION_SKIRT_M)) < 1e-3,
		"min_y %f expected %f" % [min_y, foot_low - BuildingBuilder.FOUNDATION_SKIRT_M])


func _test_pyramid_apex_on_slope() -> void:
	var poly := _square_poly(5.0)
	var height_m := 8.0
	var verts := _build_vertices(poly, height_m,
		{"shape": "pyramidal", "angle_deg": 30.0, "orientation": "along",
			"direction_deg": NAN, "roof_height_m": 0.0})
	_check("pyramid: mesh built", not verts.is_empty())
	if verts.is_empty():
		return

	var base_y := _highest_corner_sample(poly, _tilted_grid())
	var max_y := -INF
	for v in verts:
		max_y = maxf(max_y, v.y)
	_check("pyramid: apex = highest corner + height",
		absf(max_y - (base_y + height_m)) < 1e-3,
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

	# Build from the CW input on sloped ground: orientation must still come out
	# deterministic — roof up, floor down, walls outward.
	var data := _mesh_data(cw, 8.0, _roof_spec("flat"), _tilted_grid())
	_check("normals: mesh built from CW input", not data.is_empty())
	if data.is_empty():
		return
	var verts: PackedVector3Array = data["verts"]
	var normals: PackedVector3Array = data["normals"]

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


func _flat_grid() -> PackedFloat32Array:
	var elev := PackedFloat32Array()
	elev.resize(GRID_RES * GRID_RES)
	elev.fill(0.0)
	return elev


## Build on flat ground (base_y == 0) and return combined {verts, normals}.
func _build_arrays(poly: PackedVector2Array, height_m: float, roof: Dictionary) -> Dictionary:
	return _mesh_data(poly, height_m, roof, _flat_grid())


func _roof_spec(shape: String, angle: float = 30.0, direction: float = NAN,
		orientation: String = "along") -> Dictionary:
	return {"shape": shape, "angle_deg": angle, "orientation": orientation,
		"direction_deg": direction, "roof_height_m": 0.0}


func _rect_poly(hx: float, hz: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)])


func _test_gabled_ridge() -> void:
	# 10×6 rectangle, 30° gable: half_w = 3, rise = 3·tan(30°) ≈ 1.732 (below the
	# 0.3·height clamp), eave = 8 − 1.732, ridge = 8.
	var out := _build_arrays(_rect_poly(5.0, 3.0), 8.0, _roof_spec("gabled"))
	_check("gable: mesh built", not out.is_empty())
	if out.is_empty():
		return
	var verts: PackedVector3Array = out["verts"]
	var normals: PackedVector3Array = out["normals"]
	var rise := 3.0 * tan(deg_to_rad(30.0))
	var eave := 8.0 - rise

	# Every roof vertex is at eave or ridge height, ridge verts on the long axis.
	var heights_ok := true
	var ridge_on_axis := true
	var seen_ridge := false
	var seen_eave := false
	for t in range(0, verts.size(), 3):
		if normals[t].y < 0.1:
			continue
		for k in 3:
			var v := verts[t + k]
			if absf(v.y - 8.0) < 1e-3:
				seen_ridge = true
				if absf(v.z) > 0.01:
					ridge_on_axis = false
			elif absf(v.y - eave) < 1e-3:
				seen_eave = true
			else:
				heights_ok = false
	_check("gable: roof verts at eave or ridge only", heights_ok and seen_ridge and seen_eave)
	_check("gable: ridge parallel to long edge", ridge_on_axis)

	# No flat roof triangles; both slope directions present.
	var pos_z := false
	var neg_z := false
	var no_flat := true
	for t in range(0, verts.size(), 3):
		var nrm := normals[t]
		if nrm.y > 0.1 and (verts[t].y + verts[t + 1].y + verts[t + 2].y) / 3.0 > eave - 0.01:
			if nrm.y > 0.999:
				no_flat = false
			if nrm.z > 0.3:
				pos_z = true
			elif nrm.z < -0.3:
				neg_z = true
	_check("gable: no flat roof tris", no_flat)
	_check("gable: both slopes present", pos_z and neg_z)

	# Gable-end wall fill reaches the ridge (watertight wall/roof boundary).
	var gable_fill := false
	for t in range(0, verts.size(), 3):
		if absf(normals[t].y) < 0.1:
			for k in 3:
				if absf(verts[t + k].y - 8.0) < 1e-3:
					gable_fill = true
	_check("gable: end walls reach ridge", gable_fill)


func _test_ridge_orientation() -> void:
	# orientation=across rotates the ridge 90°: ridge verts on x == 0 instead.
	var out := _build_arrays(_rect_poly(5.0, 3.0), 8.0,
		_roof_spec("gabled", 30.0, NAN, "across"))
	var ok := _ridge_verts_on(out, "x")
	_check("gable: orientation=across rotates ridge", ok)

	# roof:direction=0 pins the ridge along +Z regardless of the long edge.
	out = _build_arrays(_rect_poly(5.0, 3.0), 8.0, _roof_spec("gabled", 30.0, 0.0))
	_check("gable: roof:direction pins ridge", _ridge_verts_on(out, "x"))


## True when every max-height roof vertex sits on the given axis plane.
func _ridge_verts_on(out: Dictionary, zero_coord: String) -> bool:
	if out.is_empty():
		return false
	var verts: PackedVector3Array = out["verts"]
	var normals: PackedVector3Array = out["normals"]
	var max_y := -INF
	for v in verts:
		max_y = maxf(max_y, v.y)
	var ok := false
	for t in range(0, verts.size(), 3):
		if normals[t].y < 0.1:
			continue
		for k in 3:
			var v := verts[t + k]
			if absf(v.y - max_y) < 1e-3:
				ok = true
				var coord := v.x if zero_coord == "x" else v.z
				if absf(coord) > 0.01:
					return false
	return ok


func _test_hipped_faces() -> void:
	var out := _build_arrays(_rect_poly(5.0, 3.0), 8.0, _roof_spec("hipped"))
	_check("hip: mesh built", not out.is_empty())
	if out.is_empty():
		return
	var verts: PackedVector3Array = out["verts"]
	var normals: PackedVector3Array = out["normals"]
	var max_y := -INF
	for v in verts:
		max_y = maxf(max_y, v.y)
	_check("hip: ridge at total height", absf(max_y - 8.0) < 1e-3, "max %f" % max_y)

	var dir_px := false
	var dir_nx := false
	var dir_pz := false
	var dir_nz := false
	for t in range(0, verts.size(), 3):
		var nrm := normals[t]
		if nrm.y < 0.1 or nrm.y > 0.999:
			continue
		if nrm.x > 0.3:
			dir_px = true
		elif nrm.x < -0.3:
			dir_nx = true
		if nrm.z > 0.3:
			dir_pz = true
		elif nrm.z < -0.3:
			dir_nz = true
	_check("hip: four slope directions", dir_px and dir_nx and dir_pz and dir_nz,
		"px=%s nx=%s pz=%s nz=%s" % [dir_px, dir_nx, dir_pz, dir_nz])

	# Ridge verts confined to the shortened segment |x| <= half_len - half_w = 2.
	var seg_ok := true
	for t in range(0, verts.size(), 3):
		for k in 3:
			var v := verts[t + k]
			if absf(v.y - max_y) < 1e-3 and absf(v.x) > 2.01:
				seg_ok = false
	_check("hip: ridge shortened to segment", seg_ok)


func _test_concave_and_degenerate() -> void:
	# L-shaped concave footprint builds clean, roof within [eave, height].
	var l_poly := PackedVector2Array([
		Vector2(0, 0), Vector2(10, 0), Vector2(10, 4),
		Vector2(4, 4), Vector2(4, 10), Vector2(0, 10)])
	var out := _build_arrays(l_poly, 8.0, _roof_spec("gabled"))
	_check("L-shape: mesh built", not out.is_empty())
	if not out.is_empty():
		var verts: PackedVector3Array = out["verts"]
		var ok := true
		for v in verts:
			if v.y > 8.0 + 1e-3:
				ok = false
		_check("L-shape: nothing above total height", ok)

	# Star-shaped footprint (OBB fill « 0.3) falls back to a flat roof.
	var star := PackedVector2Array()
	for i in 10:
		var ang := TAU * float(i) / 10.0
		var rad := 10.0 if i % 2 == 0 else 1.5
		star.append(Vector2(cos(ang) * rad, sin(ang) * rad))
	out = _build_arrays(star, 8.0, _roof_spec("gabled"))
	_check("star: mesh built", not out.is_empty())
	if not out.is_empty():
		var verts: PackedVector3Array = out["verts"]
		var normals: PackedVector3Array = out["normals"]
		var flat_ok := true
		for t in range(0, verts.size(), 3):
			if normals[t].y > 0.1 and normals[t].y < 0.999:
				flat_ok = false
		_check("star: guardrail forces flat roof", flat_ok)


func _test_skillion() -> void:
	var out := _build_arrays(_rect_poly(5.0, 3.0), 8.0, _roof_spec("skillion"))
	_check("skillion: mesh built", not out.is_empty())
	if out.is_empty():
		return
	var verts: PackedVector3Array = out["verts"]
	var normals: PackedVector3Array = out["normals"]
	var max_y := -INF
	for v in verts:
		max_y = maxf(max_y, v.y)
	_check("skillion: capped at total height", max_y <= 8.0 + 1e-3, "max %f" % max_y)
	var sloped := false
	for t in range(0, verts.size(), 3):
		if normals[t].y > 0.1 and normals[t].y < 0.999:
			sloped = true
	_check("skillion: has sloped face", sloped)


func _test_uvs_and_colors() -> void:
	# Two surfaces: walls (0) and roof (1).
	var data := _mesh_data(_square_poly(5.0), 8.0, _roof_spec("flat"), _flat_grid())
	_check("surfaces: exactly 2", int(data.get("surface_count", 0)) == 2,
		"got %d" % int(data.get("surface_count", 0)))
	if data.is_empty():
		return

	# Wall UVs are metric: U spans 0..edge length (10 m per facade), V spans
	# -skirt..height above base.
	var wall: Dictionary = (data["surfaces"] as Array)[0]
	var wuvs: PackedVector2Array = wall["uvs"]
	var wverts: PackedVector3Array = wall["verts"]
	var wnorms: PackedVector3Array = wall["normals"]
	var max_u := -INF
	var min_v := INF
	var max_v := -INF
	var u_in_range := true
	for t in range(0, wverts.size(), 3):
		if absf(wnorms[t].y) > 0.1:
			continue  # skip floor tris sharing the walls surface
		for k in 3:
			var uv := wuvs[t + k]
			max_u = maxf(max_u, uv.x)
			min_v = minf(min_v, uv.y)
			max_v = maxf(max_v, uv.y)
			if uv.x < -0.001 or uv.x > 10.001:
				u_in_range = false
	_check("wall UV: U spans facade length", absf(max_u - 10.0) < 1e-3 and u_in_range,
		"max_u %f" % max_u)
	_check("wall UV: V spans skirt..height",
		absf(min_v + BuildingBuilder.FOUNDATION_SKIRT_M) < 1e-3 and absf(max_v - 8.0) < 1e-3,
		"%f..%f" % [min_v, max_v])

	# Roof UVs are isometric with 3D distances on sloped faces (true metres).
	data = _mesh_data(_rect_poly(5.0, 3.0), 8.0, _roof_spec("gabled"), _flat_grid())
	var roofd: Dictionary = (data["surfaces"] as Array)[1]
	var ruvs: PackedVector2Array = roofd["uvs"]
	var rverts: PackedVector3Array = roofd["verts"]
	var metric_ok := true
	for t in range(0, rverts.size(), 3):
		for k in 3:
			var k2 := (k + 1) % 3
			var d3 := rverts[t + k].distance_to(rverts[t + k2])
			var d2 := ruvs[t + k].distance_to(ruvs[t + k2])
			if absf(d3 - d2) > 0.01:
				metric_ok = false
	_check("roof UV: metric on slopes", metric_ok)

	# COLOR.a encodes pitched (1) vs flat (0) per building for the roof shader.
	var rcols: PackedColorArray = roofd["colors"]
	var pitched_a_ok := rcols.size() > 0
	for ccol in rcols:
		if absf(ccol.a - 1.0) > 0.01:
			pitched_a_ok = false
	_check("roof color: pitched alpha flag", pitched_a_ok)
	data = _mesh_data(_square_poly(5.0), 8.0, _roof_spec("flat"), _flat_grid())
	var fcols: PackedColorArray = ((data["surfaces"] as Array)[1] as Dictionary)["colors"]
	var flat_a_ok := fcols.size() > 0
	for ccol in fcols:
		if absf(ccol.a) > 0.01:
			flat_a_ok = false
	_check("roof color: flat alpha flag", flat_a_ok)

	# OSM colour tags honored; palette deterministic per stable tag.
	var cols := BuildingBuilder.resolve_building_colors({"roof:colour": "red"}, "bldg_1_1")
	_check("colors: roof:colour honored",
		(cols["roof"] as Color).r > 0.9 and (cols["roof"] as Color).g < 0.1)
	var c1 := BuildingBuilder.resolve_building_colors({}, "bldg_5_9")
	var c2 := BuildingBuilder.resolve_building_colors({}, "bldg_5_9")
	var c3 := BuildingBuilder.resolve_building_colors({}, "bldg_100_-42")
	_check("colors: deterministic", c1["wall"] == c2["wall"] and c1["roof"] == c2["roof"])
	_check("colors: tag-dependent", c1["wall"] != c3["wall"] or c1["roof"] != c3["roof"])

	# Stable tag: same poly → same tag; translated poly → a different tag.
	var tag1 := BuildingBuilder.building_tag(_square_poly(5.0))
	var moved := PackedVector2Array()
	for p in _square_poly(5.0):
		moved.append(p + Vector2(50, 50))
	_check("tag: stable", tag1 == BuildingBuilder.building_tag(_square_poly(5.0)))
	_check("tag: position-keyed", tag1 != BuildingBuilder.building_tag(moved))


func _test_materials() -> void:
	var wall := BuildingBuilder.make_wall_material()
	var roof := BuildingBuilder.make_roof_material()
	_check("materials: wall is ShaderMaterial", wall is ShaderMaterial)
	_check("materials: roof is ShaderMaterial", roof is ShaderMaterial)
	_check("materials: wall shader loaded",
		wall is ShaderMaterial and (wall as ShaderMaterial).shader != null)
	_check("materials: roof shader loaded",
		roof is ShaderMaterial and (roof as ShaderMaterial).shader != null)
	_check("materials: independent instances",
		BuildingBuilder.make_wall_material() != wall)


func _test_style_layer() -> void:
	var layer := BuildingStyleLayer.create_empty()
	var ok := layer.set_style("bldg_3_4", {
		"roof_shape": "gabled",
		"roof_pitch_deg": 35.0,
		"wall_color": Color(0.2, 0.4, 0.6, 1.0),
		"height_m": 11.5,
		"base_y_offset_m": -0.5,
		"elements": [{"kind": "door", "edge": 0, "u_m": 2.0, "v_m": 0.0,
			"w_m": 1.0, "h_m": 2.05}],
	})
	_check("style layer: set_style accepts", ok)

	# Round-trip through actual JSON text (what lands on disk).
	var json_text := JSON.stringify(layer.serialize())
	var reparsed: Variant = JSON.parse_string(json_text)
	var layer2 := BuildingStyleLayer.create_empty()
	layer2.deserialize(reparsed as Dictionary)
	var got := layer2.get_style("bldg_3_4")
	_check("style layer: round-trips shape", str(got.get("roof_shape", "")) == "gabled")
	_check("style layer: round-trips height", absf(float(got.get("height_m", 0.0)) - 11.5) < 1e-6)
	var col := BuildingStyleLayer.array_to_color(got.get("wall_color"), Color.BLACK)
	_check("style layer: color survives JSON",
		absf(col.r - 0.2) < 1e-5 and absf(col.g - 0.4) < 1e-5 and absf(col.b - 0.6) < 1e-5)
	var elems: Array = got.get("elements", [])
	_check("style layer: elements survive", elems.size() == 1
		and str((elems[0] as Dictionary).get("kind", "")) == "door")
	_check("style layer: all_tags", layer2.all_tags() == ["bldg_3_4"])
	layer2.remove_style("bldg_3_4")
	_check("style layer: remove", not layer2.has_style("bldg_3_4"))


func _test_style_overrides() -> void:
	var d := {"idx": 0, "points": _rect_poly(5.0, 3.0), "height_m": 8.0,
		"tags": {"building": "house"}}

	# No style: house defaults to gabled (record has no precomputed roof).
	var params := BuildingBuilder.resolve_building_params(d, {})
	_check("params: default roof from tags",
		str((params["roof"] as Dictionary).get("shape", "")) == "gabled")

	# Style overrides shape, pitch, height, colors, base offset.
	params = BuildingBuilder.resolve_building_params(d, {
		"roof_shape": "flat", "roof_pitch_deg": 45.0, "height_m": 12.0,
		"wall_color": [0.1, 0.2, 0.3, 1.0], "roof_color": "red",
		"base_y_offset_m": 1.25})
	var roof: Dictionary = params["roof"]
	_check("params: style shape wins", str(roof.get("shape", "")) == "flat")
	_check("params: style pitch wins", absf(float(roof.get("angle_deg", 0.0)) - 45.0) < 1e-5)
	_check("params: provenance user", str(roof.get("source", "")) == "user")
	_check("params: style height wins", absf(float(params["height_m"]) - 12.0) < 1e-5)
	var wall_c: Color = (params["colors"] as Dictionary)["wall"]
	_check("params: wall color array decoded", absf(wall_c.b - 0.3) < 1e-5)
	var roof_c: Color = (params["colors"] as Dictionary)["roof"]
	_check("params: roof color css decoded", roof_c.r > 0.9 and roof_c.g < 0.1)
	_check("params: base offset", absf(float(params["base_offset_m"]) - 1.25) < 1e-6)

	# Base offset moves the whole mesh vertically.
	var v0 := _mesh_data(_square_poly(5.0), 8.0, _roof_spec("flat"), _flat_grid())
	var buildings := [{"idx": 0, "points": _square_poly(5.0), "height_m": 8.0,
		"tags": {}, "roof": _roof_spec("flat")}]
	var mi := BuildingBuilder.build_single_building(
		buildings[0], {"base_y_offset_m": 2.0}, _flat_grid(), GRID_RES, EXTENT_M, 0.0)
	_check("params: offset mesh built", mi != null)
	if mi != null and not v0.is_empty():
		var max_y := -INF
		for s in mi.mesh.get_surface_count():
			for v in (mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				max_y = maxf(max_y, v.y)
		var base_max := -INF
		for v in (v0["verts"] as PackedVector3Array):
			base_max = maxf(base_max, v.y)
		_check("params: offset shifts mesh +2 m", absf(max_y - (base_max + 2.0)) < 1e-3,
			"max %f vs %f" % [max_y, base_max])
		mi.free()


func _test_single_building_parity() -> void:
	# build_single_building with an empty style must vertex-match the same
	# building's merged-mesh build (one shared geometry code path).
	var d := {"idx": 0, "points": _rect_poly(5.0, 3.0), "height_m": 8.0,
		"tags": {"building": "house"}}
	var merged := _mesh_data(_rect_poly(5.0, 3.0), 8.0,
		BuildingBuilder.infer_roof_spec({"building": "house"}, _rect_poly(5.0, 3.0)),
		_tilted_grid())
	var mi := BuildingBuilder.build_single_building(
		d, {}, _tilted_grid(), GRID_RES, EXTENT_M, 0.0)
	_check("parity: single build ok", mi != null and not merged.is_empty())
	if mi == null or merged.is_empty():
		return
	_check("parity: same surface count",
		mi.mesh.get_surface_count() == int(merged["surface_count"]))
	var single_verts := PackedVector3Array()
	for s in mi.mesh.get_surface_count():
		single_verts += mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var merged_verts: PackedVector3Array = merged["verts"]
	var same := single_verts.size() == merged_verts.size()
	if same:
		for i in single_verts.size():
			if single_verts[i].distance_to(merged_verts[i]) > 1e-5:
				same = false
				break
	_check("parity: identical vertices", same,
		"single=%d merged=%d" % [single_verts.size(), merged_verts.size()])
	mi.free()


func _test_modal_script() -> void:
	var script := load("res://scenes/ui/building_builder_modal.gd")
	_check("modal: script loads", script != null and script is GDScript)
	_check("modal: hotkey action registered", InputMap.has_action("building_builder"))


func _test_facade_elements() -> void:
	# Door centered on edge 0 of a 10×10 square: edge (-5,-5)→(5,-5), outward -Z.
	var d := {"idx": 0, "points": _square_poly(5.0), "height_m": 8.0, "tags": {},
		"roof": _roof_spec("flat")}
	var style := {"elements": [
		{"kind": "door", "edge": 0, "u_m": 5.0, "v_m": 0.0, "w_m": 1.0, "h_m": 2.05}]}
	var mi := BuildingBuilder.build_single_building(
		d, style, _flat_grid(), GRID_RES, EXTENT_M, 0.0)
	_check("facade: mesh built", mi != null)
	if mi == null:
		return
	_check("facade: third surface", mi.mesh.get_surface_count() == 3,
		"got %d" % mi.mesh.get_surface_count())
	if mi.mesh.get_surface_count() < 3:
		mi.free()
		return
	var arrays: Array = mi.mesh.surface_get_arrays(2)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var pos_ok := true
	var nrm_ok := true
	for i in verts.size():
		var v := verts[i]
		# Proud of the -Z wall, horizontally near the door, vertically 0..~2.11.
		if v.z < -5.12 or v.z > -5.02 or absf(v.x) > 0.6 or v.y < -0.01 or v.y > 2.2:
			pos_ok = false
		if normals[i].distance_to(Vector3(0, 0, -1)) > 0.01:
			nrm_ok = false
	_check("facade: door quad on wall", pos_ok)
	_check("facade: normal faces outward", nrm_ok)
	mi.free()

	# Oversized element clamps inside the wall rectangle.
	var big := {"elements": [
		{"kind": "window", "edge": 0, "u_m": 100.0, "v_m": 50.0, "w_m": 50.0, "h_m": 50.0}]}
	mi = BuildingBuilder.build_single_building(
		d, big, _flat_grid(), GRID_RES, EXTENT_M, 0.0)
	_check("facade: clamped mesh built", mi != null and mi.mesh.get_surface_count() == 3)
	if mi != null and mi.mesh.get_surface_count() == 3:
		var cl_verts: PackedVector3Array = \
			mi.mesh.surface_get_arrays(2)[Mesh.ARRAY_VERTEX]
		var inside := true
		for v in cl_verts:
			if absf(v.x) > 5.2 or v.y < -0.1 or v.y > 8.2:
				inside = false
		_check("facade: oversize clamped into wall", inside)
	if mi != null:
		mi.free()


func _test_wall_pick() -> void:
	var poly := _square_poly(5.0)
	# Ray straight at the -Z face: hits edge 0 at u = 6 (x = +1), v = 2.5.
	var pick := BuildingBuilder.pick_wall_point(
		poly, 0.0, 8.0, Vector3(1, 2.5, -20), Vector3(0, 0, 1))
	_check("pick: hit valid", bool(pick.get("valid", false)))
	if bool(pick.get("valid", false)):
		_check("pick: edge 0", int(pick["edge"]) == 0, "got %d" % int(pick["edge"]))
		_check("pick: u along edge", absf(float(pick["u_m"]) - 6.0) < 1e-4,
			"got %f" % float(pick["u_m"]))
		_check("pick: v above base", absf(float(pick["v_m"]) - 2.5) < 1e-4,
			"got %f" % float(pick["v_m"]))

	# Nearest face wins: ray through the whole building still reports edge 0.
	var through := BuildingBuilder.pick_wall_point(
		poly, 0.0, 8.0, Vector3(0, 4.0, -30), Vector3(0, 0, 1))
	_check("pick: nearest face wins", bool(through.get("valid", false))
		and int(through.get("edge", -1)) == 0)

	# Miss above the walls.
	var miss := BuildingBuilder.pick_wall_point(
		poly, 0.0, 8.0, Vector3(0, 20.0, -20), Vector3(0, 0, 1))
	_check("pick: miss above walls", not bool(miss.get("valid", false)))


## Regression: residential pitched footprints that arrive "messy" from OSM
## (duplicate vertices, near-collinear spikes, tiny gables) must still render
## BOTH walls and a roof — the "houses missing on first load" bug.
func _test_messy_footprints_render() -> void:
	# 1. Gabled house with a duplicated vertex + a collinear midpoint spike on
	#    one edge. Raw triangulation may reject this; the cleanup retry rescues it.
	var messy := PackedVector2Array([
		Vector2(-5, -3), Vector2(-5, -3),         # exact duplicate
		Vector2(0, -3.001),                        # near-collinear midpoint
		Vector2(5, -3), Vector2(5, 3), Vector2(-5, 3)])
	var out := _mesh_data(messy, 8.0, _roof_spec("gabled"), _flat_grid())
	_check("messy: gabled house renders", not out.is_empty())
	if not out.is_empty():
		var surfaces: Array = out["surfaces"]
		var walls: PackedVector3Array = (surfaces[0] as Dictionary)["verts"]
		var roof: PackedVector3Array = (surfaces[1] as Dictionary)["verts"]
		_check("messy: has wall geometry", walls.size() > 0)
		_check("messy: has roof geometry", roof.size() > 0,
			"roof verts %d" % roof.size())

	# 2. A small gabled footprint (5 m × 4 m = 20 m², just over the min-area
	#    filter) — a modest residential house/outbuilding.
	var tiny := _mesh_data(_rect_poly(2.5, 2.0), 3.0, _roof_spec("gabled"), _flat_grid())
	_check("messy: tiny gable renders", not tiny.is_empty())
	if not tiny.is_empty():
		var s2: Array = tiny["surfaces"]
		_check("messy: tiny gable has roof",
			(s2[1] as Dictionary)["verts"].size() > 0)

	# 3. Fallback: a star-shaped (self-crossing-ish) footprint tagged gabled must
	#    never come back roofless — the flat-cap fallback covers it.
	var star := PackedVector2Array([
		Vector2(-6, 0), Vector2(-1, 1), Vector2(0, 6), Vector2(1, 1),
		Vector2(6, 0), Vector2(1, -1), Vector2(0, -6), Vector2(-1, -1)])
	var star_out := _mesh_data(star, 7.0, _roof_spec("gabled"), _flat_grid())
	_check("messy: star footprint renders", not star_out.is_empty())
	if not star_out.is_empty():
		var s3: Array = star_out["surfaces"]
		_check("messy: star has walls + roof",
			(s3[0] as Dictionary)["verts"].size() > 0
			and (s3[1] as Dictionary)["verts"].size() > 0)


## Centered facade layout: door pins to the wall center, windows flank it
## symmetrically; with no door the windows form a symmetric centered group.
func _test_element_layout() -> void:
	var poly := _square_poly(5.0)  # edge 0 length 10 m, center at u = 5
	# 1 door + 2 windows on edge 0 → window, door(center), window.
	var elems: Array = [
		{"kind": "door", "edge": 0, "u_m": 0.0, "v_m": 0.0, "w_m": 1.0, "h_m": 2.05},
		{"kind": "window", "edge": 0, "u_m": 0.0, "v_m": 0.9, "w_m": 1.2, "h_m": 1.4},
		{"kind": "window", "edge": 0, "u_m": 0.0, "v_m": 0.9, "w_m": 1.2, "h_m": 1.4}]
	BuildingBuilder.layout_elements_on_edge(poly, 0, elems)
	var door_u := float((elems[0] as Dictionary)["u_m"])
	var w1_u := float((elems[1] as Dictionary)["u_m"])
	var w2_u := float((elems[2] as Dictionary)["u_m"])
	_check("layout: door centered", absf(door_u - 5.0) < 1e-4, "door u=%f" % door_u)
	_check("layout: windows straddle door",
		(w1_u - 5.0) * (w2_u - 5.0) < 0.0, "w1=%f w2=%f" % [w1_u, w2_u])
	_check("layout: windows symmetric about center",
		absf((w1_u - 5.0) + (w2_u - 5.0)) < 1e-4, "w1=%f w2=%f" % [w1_u, w2_u])

	# No door: 2 windows centered symmetrically about u = 5.
	var wins: Array = [
		{"kind": "window", "edge": 0, "u_m": 0.0, "v_m": 0.9, "w_m": 1.2, "h_m": 1.4},
		{"kind": "window", "edge": 0, "u_m": 0.0, "v_m": 0.9, "w_m": 1.2, "h_m": 1.4}]
	BuildingBuilder.layout_elements_on_edge(poly, 0, wins)
	var a := float((wins[0] as Dictionary)["u_m"])
	var b := float((wins[1] as Dictionary)["u_m"])
	_check("layout: windows centered group", absf((a + b) * 0.5 - 5.0) < 1e-4,
		"mid=%f" % ((a + b) * 0.5))
	_check("layout: windows non-overlapping", absf(a - b) >= 1.2, "gap=%f" % absf(a - b))

	# Everything stays inside the wall (u in [w/2, L - w/2]).
	for e in elems:
		var u := float((e as Dictionary)["u_m"])
		_check("layout: inside wall", u >= 0.4 and u <= 9.6, "u=%f" % u)


## When a dense city overflows MAX_BUILDINGS, build_buildings_node keeps the
## footprints nearest the map centre. Verify the distance sort orders records
## nearest-first and leaves the caller's array untouched.
func _test_building_sort() -> void:
	var far := _offset_square(500.0, 0.0, 4.0)
	var near := _offset_square(10.0, 0.0, 4.0)
	var mid := _offset_square(0.0, 120.0, 4.0)
	var recs: Array = [
		{"idx": 0, "points": far},
		{"idx": 1, "points": near},
		{"idx": 2, "points": mid}]
	var sorted: Array = BuildingBuilder._sort_by_distance_to_centre(recs)
	_check("sort: nearest first", int((sorted[0] as Dictionary)["idx"]) == 1,
		"got idx=%d" % int((sorted[0] as Dictionary)["idx"]))
	_check("sort: middle second", int((sorted[1] as Dictionary)["idx"]) == 2,
		"got idx=%d" % int((sorted[1] as Dictionary)["idx"]))
	_check("sort: farthest last", int((sorted[2] as Dictionary)["idx"]) == 0,
		"got idx=%d" % int((sorted[2] as Dictionary)["idx"]))
	_check("sort: input array not reordered", int((recs[0] as Dictionary)["idx"]) == 0,
		"input mutated")


## Autoloaded OSM houses must default to a dark-grey shingle roof + a typical
## siding colour, with OSM colour tags still overriding both.
func _test_default_colors() -> void:
	var colors := BuildingBuilder.resolve_building_colors({}, "bldg_10_20")
	var roof: Color = colors["roof"]
	_check("colors: default roof is dark", roof.r < 0.4 and roof.g < 0.4 and roof.b < 0.4,
		"roof=(%.2f,%.2f,%.2f)" % [roof.r, roof.g, roof.b])
	_check("colors: default roof is neutral grey (not brown/red)",
		absf(roof.r - roof.b) < 0.06 and absf(roof.g - roof.b) < 0.06,
		"roof=(%.2f,%.2f,%.2f)" % [roof.r, roof.g, roof.b])
	var wall: Color = colors["wall"]
	_check("colors: default siding within house range",
		wall.r > 0.2 and wall.g > 0.2 and wall.b > 0.2 and wall.r < 1.0,
		"wall=(%.2f,%.2f,%.2f)" % [wall.r, wall.g, wall.b])
	# Different footprints draw different siding tints (variation across a street).
	var other := BuildingBuilder.resolve_building_colors({}, "bldg_400_120")
	var w2: Color = other["wall"]
	_check("colors: siding varies between houses",
		absf(wall.r - w2.r) + absf(wall.g - w2.g) + absf(wall.b - w2.b) > 0.02)
	# roof:colour tag overrides the grey default with a warm brown.
	var tagged := BuildingBuilder.resolve_building_colors(
		{"roof:colour": "#804020"}, "bldg_10_20")
	var troof: Color = tagged["roof"]
	_check("colors: roof:colour overrides default", troof.r > troof.b + 0.1,
		"roof=(%.2f,%.2f,%.2f)" % [troof.r, troof.g, troof.b])


func _offset_square(cx: float, cz: float, half: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(cx - half, cz - half), Vector2(cx + half, cz - half),
		Vector2(cx + half, cz + half), Vector2(cx - half, cz + half)])


func _test_model_catalog() -> void:
	var structures := ModelCatalog.models_in_category("structures")
	_check("catalog: structures category populated", structures.size() >= 4,
		"got %d" % structures.size())
	var ids: Array[String] = []
	for m in structures:
		ids.append(str((m as Dictionary).get("id", "")))
	_check("catalog: starshade present", "starshade" in ids)
	for m in structures:
		var id := str((m as Dictionary).get("id", ""))
		_check("catalog: %s scene loads" % id, ModelCatalog.load_scene(id) != null)
	# StarShade real-world size stays sane through the inch-unit fit.
	var s := ModelCatalog.resolved_scale("starshade", 1.0)
	var h := float(ModelCatalog.mesh_metrics("starshade").unit_height) * s
	_check("catalog: starshade height sane", h > 1.5 and h < 12.0, "h=%.2f m" % h)
