extends SceneTree

## Live load diagnostic for a generated-map site (network). Mirrors the sequential
## terrain_loader.gd pipeline: base DEM -> base imagery -> terrain build -> detail
## DEM -> detail imagery -> OSM/buildings -> vegetation. One heavy apply step per
## phase with idle-frame settle between GPU uploads.
## Run: godot --headless --path . --script core/terrain/load_diag.gd

const LAT := 42.4297785
const LON := -71.3033877
const HALF := 15000.0
const DETAIL_HALF := 1500.0
const AUTO_VEG_HALF := 1500.0
const SETTLE_FRAMES := 3

const _AutoVegRuntime := preload("res://vegetation/auto_vegetation_runtime.gd")

# Production resolutions (mirror terrain_loader.gd).
const MESH_RES := 256
const BASE_GRID_N := 16
const DETAIL_GRID_N := 512
const DETAIL_MESH_RES := 256

var _t0 := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("LOAD_DIAG start %.4f, %.4f (sequential pipeline)" % [LAT, LON])
	await _run()
	print("LOAD_DIAG done total_ms=%d  %s" % [Time.get_ticks_msec() - _t0, _mem()])
	quit(0)


func _mem() -> String:
	return "mem=%.1f MB peak=%.1f MB" % [
		OS.get_static_memory_usage() / 1048576.0,
		OS.get_static_memory_peak_usage() / 1048576.0]


func _log(msg: String) -> void:
	print("LOAD_DIAG +%4dms  %s  (%s)" % [Time.get_ticks_msec() - _t0, msg, _mem()])


func _settle() -> void:
	for _i in SETTLE_FRAMES:
		await process_frame


func _run() -> void:
	var es: Node = load("res://core/terrain/elevation_service.gd").new()
	var img: Node = load("res://core/terrain/imagery_service.gd").new()
	var bs: Node = load("res://core/terrain/building_service.gd").new()
	var vs: Node = load("res://core/terrain/vegetation_osm_service.gd").new()
	root.add_child(es)
	root.add_child(img)
	root.add_child(bs)
	root.add_child(vs)
	await process_frame

	_log("1/8 fetch base dem")
	var base_dem: Dictionary = await _fetch_dem(es, "base", HALF, BASE_GRID_N)
	if not base_dem.has("grid"):
		var reason := str(base_dem.get("error", "unknown"))
		print("LOAD_DIAG base dem failed: %s" % reason)
		push_error("base dem failed: %s" % reason)
		return
	await _settle()

	_log("2/8 fetch base img")
	var base_img: ImageTexture = await _fetch_img(img, HALF, 2048, "base")
	await _settle()

	var base_grid: PackedFloat32Array = TerrainBuilder.resample(
		base_dem["grid"], base_dem["cols"], base_dem["rows"], MESH_RES)
	var center_elev := TerrainBuilder.mean_elevation(base_grid)
	var extent := HALF * 2.0
	var detail_extent := DETAIL_HALF * 2.0

	var terrain := Node3D.new()
	terrain.name = "Terrain"
	root.add_child(terrain)

	_log("3/8 build coarse terrain")
	var t := Time.get_ticks_msec()
	var tnode := TerrainBuilder.build_terrain_node(
		base_grid, MESH_RES, extent, center_elev, base_img, null, detail_extent)
	for c in tnode.get_children():
		tnode.remove_child(c)
		terrain.add_child(c)
	await _settle()
	_log("build coarse terrain ms=%d" % (Time.get_ticks_msec() - t))

	_log("4/8 fetch detail dem")
	var detail_dem: Dictionary = await _fetch_dem(es, "detail", DETAIL_HALF, DETAIL_GRID_N)
	if not detail_dem.has("grid"):
		push_error("detail dem failed: %s" % detail_dem.get("error", "unknown"))
		return
	await _settle()

	var detail_grid: PackedFloat32Array = detail_dem["grid"]
	var detail_res: int = detail_dem["cols"]
	var coarse_foot := base_grid.duplicate()
	var detail_surf := detail_grid.duplicate()
	var built := TerrainBuilder.patch_centre_heights(
		coarse_foot, MESH_RES, detail_surf, detail_res, extent, detail_extent, 40.0)
	TerrainBuilder.sink_coarse_centre_for_detail(
		built, MESH_RES, extent, detail_extent, center_elev)

	t = Time.get_ticks_msec()
	var detail_mesh_grid := detail_surf
	var detail_mesh_res := detail_res
	if detail_res > DETAIL_MESH_RES:
		detail_mesh_grid = TerrainBuilder.resample(detail_surf, detail_res, detail_res, DETAIL_MESH_RES)
		detail_mesh_res = DETAIL_MESH_RES
	TerrainBuilder.upsert_detail_patch(
		terrain, detail_mesh_grid, detail_mesh_res, detail_extent,
		center_elev, base_img, null, extent)
	await _settle()
	_log("build detail patch %d² ms=%d" % [detail_mesh_res, Time.get_ticks_msec() - t])

	_log("5/8 fetch detail img")
	var detail_img: ImageTexture = await _fetch_img(img, DETAIL_HALF, 2048, "detail", 18)
	if detail_img != null:
		TerrainBuilder.upsert_detail_patch(
			terrain, detail_mesh_grid, detail_mesh_res, detail_extent,
			center_elev, base_img, detail_img, extent)
	await _settle()

	_log("6/8 fetch osm vectors + buildings")
	var osm: Dictionary = await _fetch_osm(bs)
	var buildings: Array = osm.get("buildings", [])
	t = Time.get_ticks_msec()
	var visible: Array = []
	for b in buildings:
		if b is Dictionary:
			var pts: PackedVector2Array = (b as Dictionary).get("points", PackedVector2Array())
			if not pts.is_empty():
				for p in pts:
					if absf(p.x) <= DETAIL_HALF and absf(p.y) <= DETAIL_HALF:
						visible.append(b)
						break
	var bnode := BuildingBuilder.build_buildings_node(
		visible, built, MESH_RES, extent, center_elev,
		base_img, detail_img, detail_extent, extent,
		detail_surf, detail_res, detail_res, [], false)
	if bnode != null:
		terrain.add_child(bnode)
	await _settle()
	_log("build buildings n=%d ms=%d" % [visible.size(), Time.get_ticks_msec() - t])

	_log("7/8 fetch osm veg")
	var veg: Dictionary = await _fetch_veg(vs)
	await _settle()

	_log("8/8 scatter vegetation")
	t = Time.get_ticks_msec()
	var gate := LandcoverImageryGate.from_texture_downsampled(
		base_img, extent, 512, detail_img, detail_extent, 512)
	var ctx := {
		"latitude": LAT, "seed": 1337, "exclusions": [], "style": {},
		"half_extent_m": AUTO_VEG_HALF,
		"ground_y_at": func(x: float, z: float) -> float:
			return TerrainBuilder.sample_footing_height(
				x, z, built, MESH_RES, extent, center_elev,
				detail_surf, detail_res, detail_res, detail_extent),
		"gate": gate,
	}
	var layer := AutoVegetationGenerator.generate(veg, ctx)
	_log("auto veg generate bulk=%d ms=%d" % [layer.total_bulk(), Time.get_ticks_msec() - t])
	t = Time.get_ticks_msec()
	_AutoVegRuntime.rebuild(terrain, layer, ctx["ground_y_at"], {}, [])
	await _settle()
	_log("auto veg rebuild ms=%d" % (Time.get_ticks_msec() - t))


func _fetch_dem(es: Node, tag: String, half: float, grid_n: int) -> Dictionary:
	var result: Array = ["pending", null, null, null, ""]
	es.elevation_ready.connect(func(_k, grid, c, r, t) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "ready"
			result[1] = grid
			result[2] = c
			result[3] = r)
	es.elevation_failed.connect(func(reason, t) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "fail"
			result[4] = reason)
	es.request_elevation(LAT, LON, half, grid_n, tag)
	await _wait(result, 180.0)
	if result[0] != "ready":
		return {"error": result[4]}
	return {"grid": result[1], "cols": result[2], "rows": result[3]}


func _fetch_img(img: Node, half: float, px: int, tag: String, z: int = 15) -> ImageTexture:
	var result: Array = ["pending", null]
	img.imagery_ready.connect(func(_k, tex, t) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "ready"
			result[1] = tex)
	img.imagery_failed.connect(func(_r, t) -> void:
		if t == tag and result[0] == "pending":
			result[0] = "fail")
	if tag == "detail":
		img.request_imagery(LAT, LON, half, px, tag, z)
	else:
		img.request_imagery(LAT, LON, half, px, tag)
	await _wait(result, 180.0)
	return result[1] as ImageTexture


func _fetch_osm(bs: Node) -> Dictionary:
	var result: Array = ["pending", null]
	bs.osm_vectors_ready.connect(func(_k, payload) -> void:
		if result[0] == "pending":
			result[0] = "ready"
			result[1] = payload)
	bs.buildings_failed.connect(func(_r) -> void:
		if result[0] == "pending":
			result[0] = "fail")
	bs.request_osm_vectors(LAT, LON, AUTO_VEG_HALF, false)
	await _wait(result, 180.0)
	if result[0] != "ready":
		return {}
	return result[1] as Dictionary


func _fetch_veg(vs: Node) -> Dictionary:
	var result: Array = ["pending", null]
	vs.vegetation_osm_ready.connect(func(_k, payload) -> void:
		if result[0] == "pending":
			result[0] = "ready"
			result[1] = payload)
	vs.vegetation_osm_failed.connect(func(_r) -> void:
		if result[0] == "pending":
			result[0] = "fail")
	vs.request_vegetation(LAT, LON, AUTO_VEG_HALF)
	await _wait(result, 180.0)
	if result[0] != "ready":
		return {}
	return result[1] as Dictionary


func _wait(result: Array, timeout_s: float) -> void:
	var elapsed := 0.0
	while result[0] == "pending" and elapsed < timeout_s:
		await create_timer(0.25).timeout
		elapsed += 0.25
