extends SceneTree

## Live fetch smoke test for the terrain pipeline (requires network — NOT part of
## the standard self-test). Fetches a small elevation grid + stitched imagery for
## a known location and confirms the data is real and cached.
## Run: godot --headless --path . --script core/terrain/terrain_fetch_smoketest.gd

const LAT := 47.6062   # Seattle — varied relief, water, urban
const LON := -122.3321
const HALF_EXTENT := 15000.0   # 30 km square
const GRID_N := 12             # small grid → ~2 batches → fast

const VEG_LAT := 48.27         # Black Forest, DE — dense OSM wood/forest cover
const VEG_LON := 8.20
const VEG_HALF_EXTENT := 1500.0


func _initialize() -> void:
	var es: Node = load("res://core/terrain/elevation_service.gd").new()
	var is_: Node = load("res://core/terrain/imagery_service.gd").new()
	var vs: Node = load("res://core/terrain/vegetation_osm_service.gd").new()
	root.add_child(es)
	root.add_child(is_)
	root.add_child(vs)
	await process_frame

	var ok := true
	ok = await _test_elevation(es) and ok
	ok = await _test_imagery(is_) and ok
	ok = await _test_vegetation(vs) and ok
	print("TERRAIN SMOKETEST %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _test_vegetation(vs: Node) -> bool:
	print("SMOKETEST OSM vegetation %.4f,%.4f (%.0f m square)..." % [
		VEG_LAT, VEG_LON, VEG_HALF_EXTENT * 2.0])
	var result: Array = ["pending", null]
	vs.vegetation_osm_ready.connect(func(_k: String, payload: Dictionary) -> void:
		if result[0] == "pending":
			result[0] = "ready"
			result[1] = payload)
	vs.vegetation_osm_failed.connect(func(reason: String) -> void:
		if result[0] == "pending":
			result[0] = "failed"
			result[1] = reason)
	vs.request_vegetation(VEG_LAT, VEG_LON, VEG_HALF_EXTENT)
	await _wait(result, 120.0)
	if result[0] != "ready":
		print("  vegetation FAIL: %s" % str(result[1]))
		return false
	var payload: Dictionary = result[1]
	var polys := (payload.get("polygons", []) as Array).size()
	var pts := (payload.get("tree_points", []) as Array).size()
	var rows := (payload.get("tree_rows", []) as Array).size()
	print("  vegetation OK: %d polygons, %d tree points, %d tree rows" % [polys, pts, rows])
	# Feed the real payload through the generator to confirm it scatters instances.
	var layer := AutoVegetationGenerator.generate(payload, {
		"latitude": VEG_LAT, "seed": 7, "exclusions": []})
	print("  generator scattered %d bulk instances" % layer.total_bulk())
	return polys > 0 and layer.total_bulk() > 0


func _test_elevation(es: Node) -> bool:
	print("SMOKETEST elevation %.4f,%.4f (%dx%d grid)..." % [LAT, LON, GRID_N, GRID_N])
	var result: Array = ["pending", null, null]
	es.elevation_ready.connect(func(_k: String, grid: PackedFloat32Array, c: int, r: int) -> void:
		if result[0] == "pending":
			result[0] = "ready"
			result[1] = grid
			result[2] = Vector2i(c, r))
	es.elevation_failed.connect(func(reason: String) -> void:
		if result[0] == "pending":
			result[0] = "failed"
			result[1] = reason)
	es.request_elevation(LAT, LON, HALF_EXTENT, GRID_N)
	await _wait(result, 90.0)
	if result[0] != "ready":
		print("  elevation FAIL: %s" % str(result[1]))
		return false
	var grid: PackedFloat32Array = result[1]
	var dims: Vector2i = result[2]
	var lo := INF
	var hi := -INF
	for v in grid:
		if not is_nan(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	print("  elevation OK: %dx%d, range %.0f..%.0f m" % [dims.x, dims.y, lo, hi])
	# Seattle area has real relief — a flat zero grid means a parse/source failure.
	return grid.size() == dims.x * dims.y and hi > lo and hi > 5.0


func _test_imagery(is_: Node) -> bool:
	print("SMOKETEST imagery %.4f,%.4f (base + high-res detail)..." % [LAT, LON])
	# Capture base and detail layers separately by tag — both fire on the same
	# signal and serialise through the one HTTPRequest.
	var base_res: Array = ["pending", null]
	var det_res: Array = ["pending", null]
	is_.imagery_ready.connect(func(_k: String, tex: ImageTexture, tag: String) -> void:
		var slot: Array = det_res if tag == "detail" else base_res
		if slot[0] == "pending":
			slot[0] = "ready"
			slot[1] = tex)
	is_.imagery_failed.connect(func(reason: String, tag: String) -> void:
		var slot: Array = det_res if tag == "detail" else base_res
		if slot[0] == "pending":
			slot[0] = "failed"
			slot[1] = reason)
	is_.request_imagery(LAT, LON, HALF_EXTENT, 1024)
	is_.request_imagery(LAT, LON, 1500.0, 4096, "detail", 18)
	await _wait(base_res, 120.0)
	await _wait(det_res, 120.0)
	if base_res[0] != "ready":
		print("  base imagery FAIL: %s" % str(base_res[1]))
		return false
	var tex: ImageTexture = base_res[1]
	var sz := tex.get_size()
	print("  base imagery OK: %dx%d px" % [int(sz.x), int(sz.y)])
	if det_res[0] != "ready":
		print("  detail imagery FAIL: %s" % str(det_res[1]))
		return false
	var dtex: ImageTexture = det_res[1]
	var dsz := dtex.get_size()
	print("  detail imagery OK: %dx%d px (high-res 1 km centre patch)" % [int(dsz.x), int(dsz.y)])
	# The detail patch covers 1 km; it must be meaningfully higher-res than the
	# base mosaic's pixels-per-metre or it isn't buying anything.
	var base_mpp := (HALF_EXTENT * 2.0) / maxf(sz.x, 1.0)
	var det_mpp := 1000.0 / maxf(dsz.x, 1.0)
	print("  base ≈ %.1f m/px, detail ≈ %.2f m/px" % [base_mpp, det_mpp])
	return sz.x > 0 and sz.y > 0 and dsz.x > 0 and dsz.y > 0 and det_mpp < base_mpp


func _wait(result: Array, timeout: float) -> void:
	var waited := 0.0
	while result[0] == "pending" and waited < timeout:
		await create_timer(0.25).timeout
		waited += 0.25
	if result[0] == "pending":
		result[0] = "failed"
		result[1] = "timeout after %.0fs" % timeout
