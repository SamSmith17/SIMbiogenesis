extends SceneTree

## Live integration self-test for a user map site (network required).
## Default site: Mount St. Helens (46.2445, -121.0722) — reproduces the user's
## volcanic-terrain test location.
## Run:
##   godot --headless --path . --script core/terrain/site_selftest.gd

const LAT := 46.2445
const LON := -121.0722
const LABEL := "Mount St. Helens"
const HALF_EXTENT := 15000.0
const DETAIL_HALF := 1500.0
const AUTO_VEG_HALF := 1500.0
const BASE_GRID_N := 12
const DETAIL_GRID_N := 32

var _failures := 0
var _checks := 0


func _initialize() -> void:
	print("SITE SELFTEST  %s  (%.4f, %.4f)" % [LABEL, LAT, LON])
	_check_offline()
	var ok := await _check_live_pipeline()
	if ok and _failures == 0:
		print("SITE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SITE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _check_offline() -> void:
	var token := TerrainCacheSettings.coord_token(LAT, LON)
	_check("coord token", token == "46.2445_-121.0722")
	var bbox := GeoMath.bbox_for(LAT, LON, HALF_EXTENT)
	_check("bbox valid", float(bbox["north"]) > float(bbox["south"]))
	var warm := TerrainCacheSettings.has_warm_cache(LAT, LON)
	print("  cache warm before fetch: %s" % warm)


func _check_live_pipeline() -> bool:
	var es: Node = load("res://core/terrain/elevation_service.gd").new()
	var img: Node = load("res://core/terrain/imagery_service.gd").new()
	var vs: Node = load("res://core/terrain/vegetation_osm_service.gd").new()
	root.add_child(es)
	root.add_child(img)
	root.add_child(vs)
	await process_frame

	var base_dem: Dictionary = await _fetch_dem(es, "base", HALF_EXTENT, BASE_GRID_N)
	if base_dem.is_empty():
		return false
	var detail_dem: Dictionary = await _fetch_dem(es, "detail", DETAIL_HALF, DETAIL_GRID_N)
	if detail_dem.is_empty():
		return false

	var base_img: ImageTexture = await _fetch_imagery(img, HALF_EXTENT, 1024, "base")
	if base_img == null:
		return false
	var detail_img: ImageTexture = await _fetch_imagery(img, DETAIL_HALF, 2048, "detail", 18)
	if detail_img == null:
		return false

	var veg_payload: Dictionary = await _fetch_vegetation(vs)
	if veg_payload.is_empty():
		return false

	_check_terrain_build(base_dem, detail_dem, base_img, detail_img)
	_check_auto_vegetation(veg_payload, base_img, detail_img)
	_check("warm cache after fetch", TerrainCacheSettings.has_warm_cache(LAT, LON))
	return _failures == 0


func _fetch_dem(es: Node, tag: String, half_extent: float, grid_n: int) -> Dictionary:
	print("  fetching %s DEM (grid %d, %.0f m half-extent)..." % [tag, grid_n, half_extent])
	var result: Array = ["pending", null, null, null]
	es.elevation_ready.connect(func(_k: String, grid: PackedFloat32Array, c: int, r: int, t: String) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "ready"
			result[1] = grid
			result[2] = c
			result[3] = r)
	es.elevation_failed.connect(func(reason: String, t: String) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "failed"
			result[1] = reason)
	es.request_elevation(LAT, LON, half_extent, grid_n, tag)
	await _wait(result, 120.0)
	if result[0] != "ready":
		_check("%s DEM fetch" % tag, false, str(result[1]))
		return {}
	var grid: PackedFloat32Array = result[1]
	var cols: int = result[2]
	var rows: int = result[3]
	var lo := INF
	var hi := -INF
	for v in grid:
		if not is_nan(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	print("    %s DEM OK: %d×%d, %.0f..%.0f m AMSL" % [tag, cols, rows, lo, hi])
	_check("%s DEM has relief" % tag, hi > lo and hi - lo > 10.0, "range %.0f m" % (hi - lo))
	_check("%s DEM grid size" % tag, grid.size() == cols * rows)
	return {"grid": grid, "cols": cols, "rows": rows, "lo": lo, "hi": hi}


func _fetch_imagery(img: Node, half_extent: float, target_px: int,
		tag: String, max_zoom: int = 0) -> ImageTexture:
	print("  fetching %s imagery..." % tag)
	var result: Array = ["pending", null]
	img.imagery_ready.connect(func(_k: String, tex: ImageTexture, t: String) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "ready"
			result[1] = tex)
	img.imagery_failed.connect(func(reason: String, t: String) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "failed"
			result[1] = reason)
	if max_zoom > 0:
		img.request_imagery(LAT, LON, half_extent, target_px, tag, max_zoom)
	else:
		img.request_imagery(LAT, LON, half_extent, target_px, tag)
	await _wait(result, 180.0)
	if result[0] != "ready":
		_check("%s imagery fetch" % tag, false, str(result[1]))
		return null
	var tex: ImageTexture = result[1]
	var sz := tex.get_size()
	print("    %s imagery OK: %d×%d px" % [tag, int(sz.x), int(sz.y)])
	_check("%s imagery non-empty" % tag, sz.x > 0 and sz.y > 0)
	return tex


func _fetch_vegetation(vs: Node) -> Dictionary:
	print("  fetching OSM vegetation (%.0f m square)..." % (AUTO_VEG_HALF * 2.0))
	var result: Array = ["pending", null]
	vs.vegetation_osm_ready.connect(func(_k: String, payload: Dictionary) -> void:
		if result[0] == "pending":
			result[0] = "ready"
			result[1] = payload)
	vs.vegetation_osm_failed.connect(func(reason: String) -> void:
		if result[0] == "pending":
			result[0] = "failed"
			result[1] = reason)
	vs.request_vegetation(LAT, LON, AUTO_VEG_HALF)
	await _wait(result, 120.0)
	if result[0] != "ready":
		_check("OSM vegetation fetch", false, str(result[1]))
		return {}
	var payload: Dictionary = result[1]
	var polys := (payload.get("polygons", []) as Array).size()
	var pts := (payload.get("tree_points", []) as Array).size()
	var rows := (payload.get("tree_rows", []) as Array).size()
	print("    vegetation OK: %d polygons, %d points, %d rows" % [polys, pts, rows])
	_check("OSM veg has polygons", polys > 0, "got %d" % polys)
	return payload


func _check_terrain_build(base_dem: Dictionary, detail_dem: Dictionary,
		base_img: ImageTexture, detail_img: ImageTexture) -> void:
	var base_grid: PackedFloat32Array = TerrainBuilder.resample(
		base_dem["grid"], base_dem["cols"], base_dem["rows"], 32)
	var base_res := 32
	var center := TerrainBuilder.mean_elevation(base_grid)
	var extent := HALF_EXTENT * 2.0
	var detail_extent := DETAIL_HALF * 2.0

	var detail_grid: PackedFloat32Array = TerrainBuilder.resample(
		detail_dem["grid"], detail_dem["cols"], detail_dem["rows"], 32)
	var detail_res := 32
	var offset := TerrainBuilder.compute_detail_vertical_offset(
		detail_grid, detail_res, detail_extent, base_grid, base_res, extent, center)
	var aligned := TerrainBuilder.apply_detail_vertical_offset(detail_grid, offset)
	var feather := TerrainBuilder.compute_adaptive_feather_m(
		aligned, detail_res, detail_extent, base_grid, base_res, extent, center)
	var detail_surf := TerrainBuilder.feather_detail_to_coarse(
		aligned, detail_res, detail_extent, base_grid, base_res, extent, center, feather)
	var built := TerrainBuilder.patch_centre_heights(
		base_grid, base_res, detail_surf, detail_res, extent, detail_extent, feather)
	built = TerrainBuilder.feather_coarse_exterior_ring(
		built, base_res, extent, center, detail_surf, detail_res, detail_extent)
	var seam := TerrainSeamDiag.measure_boundary_delta(
		detail_surf, detail_res, detail_extent, built, base_res, extent, center)
	print("  seam: max_delta=%.2f m rms=%.2f m feather=%.0f m offset=%.1f m" % [
		float(seam.get("max_delta_m", 0.0)), float(seam.get("rms_delta_m", 0.0)), feather, offset])
	_check("seam max_delta < 15 m (live DEM)", float(seam.get("max_delta_m", 99.0)) < 15.0,
		"max=%.1f" % float(seam.get("max_delta_m", 0.0)))

	var terrain := TerrainBuilder.build_terrain_node(
		built, base_res, extent, center, base_img)
	_check("terrain node built", terrain != null)
	if terrain == null:
		return

	var ground_y := TerrainBuilder.height_at_world_xz(
		base_grid, base_res, extent, center, 0.0, 0.0)
	_check("spawn ground height finite", not is_nan(ground_y) and not is_inf(ground_y),
		"y=%.2f" % ground_y)

	TerrainBuilder.upsert_detail_patch(
		terrain, detail_surf, detail_res, detail_extent, center,
		base_img, detail_img, extent, feather)

	_check("DetailGround present", TerrainBuilder.has_detail_ground(terrain))
	_check("DetailCollision present", terrain.get_node_or_null("DetailCollision") != null)

	var ground := terrain.get_node_or_null("Ground") as MeshInstance3D
	var coarse_mat := ground.material_override if ground != null else null
	_check("coarse hide_centre shader", coarse_mat is ShaderMaterial)
	if coarse_mat is ShaderMaterial:
		_check("hide_centre_region set",
			(coarse_mat as ShaderMaterial).get_shader_parameter("hide_centre_region") == true)

	var detail_ground := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if detail_ground != null and detail_ground.material_override is ShaderMaterial:
		var dm := detail_ground.material_override as ShaderMaterial
		_check("detail patch_mesh", dm.get_shader_parameter("patch_mesh") == true)

	terrain.free()


func _check_auto_vegetation(payload: Dictionary, base_img: ImageTexture,
		detail_img: ImageTexture) -> void:
	var gate: LandcoverImageryGate = LandcoverImageryGate.from_texture(
		base_img, HALF_EXTENT * 2.0, detail_img, DETAIL_HALF * 2.0)
	var layer := AutoVegetationGenerator.generate(payload, {
		"latitude": LAT,
		"half_extent_m": AUTO_VEG_HALF,
		"seed": int(LAT * 10000.0) ^ int(LON * 10000.0),
		"exclusions": [],
		"gate": gate,
	})
	var total := layer.total_bulk() + layer.hero.size()
	var near_200 := layer.count_within_radius(0.0, 0.0, 200.0)
	var near_500 := layer.count_within_radius(0.0, 0.0, 500.0)
	var nearest := layer.nearest_distance(0.0, 0.0)
	print("  auto-veg: %d instances; spawn vicinities: %d/200 m, %d/500 m, nearest %.0f m" % [
		total, near_200, near_500, nearest])
	_check("auto-veg scatters instances", total > 100, "got %d" % total)
	_check("nearest tree finite", not is_nan(nearest) and nearest >= 0.0,
		"nearest %.0f m" % nearest)


func _wait(result: Array, timeout: float) -> void:
	var waited := 0.0
	while result[0] == "pending" and waited < timeout:
		await create_timer(0.25).timeout
		waited += 0.25
	if result[0] == "pending":
		result[0] = "failed"
		result[1] = "timeout after %.0fs" % timeout
