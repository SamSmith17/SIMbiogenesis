extends SceneTree
## Terrain extents (offline): TerrainExtents' side <-> half rules, clamping,
## the hi-res-patch cap on sharp overlays, the stale-result key test against
## the REAL ElevationService / ImageryService key formats, and the elevation
## fetch plan — the source ladder (always ending at Open-Meteo), tiling a big
## world's request, stitching the tiles back bit-identical to one request, and
## the retry delay.
##   Godot --headless --path . --script core/terrain/terrain_extents_selftest.gd

const ElevationServiceScript := preload("res://core/terrain/elevation_service.gd")
const ImageryServiceScript := preload("res://core/terrain/imagery_service.gd")

const EXPECTED_CHECKS := 64

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _initialize() -> void:
	_test_side_half()
	_test_sanitize()
	_test_overlay_half()
	_test_key_matches()
	_test_source_ladder()
	_test_terrarium()
	_test_tiling()
	_test_tile_stitch()
	_test_retry_delay()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("terrain_extents_selftest: %d checks, %d failures — %s" % [
		_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _test_side_half() -> void:
	# The bug: the panel showed the HALF-extent as "World size", so typing 80
	# built 160 km and the loading screen printed double.
	_check(is_equal_approx(TerrainExtents.side_from_half(40000.0), 80000.0), "80 km world = 40 km half")
	_check(is_equal_approx(TerrainExtents.half_from_side(80000.0), 40000.0), "half_from_side inverts")
	_check(is_equal_approx(TerrainExtents.side_from_half(TerrainExtents.half_from_side(3000.0)), 3000.0),
		"round trip")
	var progress := TerrainLoadProgress.new()
	progress.configure_for_extents(TerrainExtents.half_from_side(80000.0), 1500.0)
	progress.mark_done("detail_dem")
	_check(progress.active_label() == "Elevation (80 km world)", "loading screen prints the side typed (%s)" % progress.active_label())
	_check(TerrainExtents.format_side(60000.0) == "60 km", "format 60 km")
	_check(TerrainExtents.format_side(3000.0) == "3.0 km", "format 3.0 km")
	_check(TerrainExtents.format_side(500.0) == "500 m", "format 500 m")


func _test_sanitize() -> void:
	var d := TerrainExtents.sanitize(0.0, 0.0, 0.0)
	_check(is_equal_approx(float(d["world_half_m"]), TerrainExtents.WORLD_HALF_DEFAULT), "unset world takes the default")
	_check(is_equal_approx(float(d["detail_half_m"]), TerrainExtents.DETAIL_HALF_DEFAULT), "unset detail takes the default")
	_check(is_equal_approx(float(d["osm_half_m"]), TerrainExtents.OSM_HALF_DEFAULT), "unset osm takes the default")
	var big := TerrainExtents.sanitize(500000.0, 99999.0, 99999.0)
	_check(is_equal_approx(float(big["world_half_m"]), TerrainExtents.WORLD_SIDE_MAX_M * 0.5), "world clamps to the max side")
	_check(is_equal_approx(float(big["detail_half_m"]), TerrainExtents.DETAIL_SIDE_MAX_M * 0.5), "detail clamps to the max side")
	_check(is_equal_approx(float(big["osm_half_m"]), TerrainExtents.OSM_SIDE_MAX_M * 0.5), "osm clamps to the max side")
	var small := TerrainExtents.sanitize(5000.0, 4500.0, 7000.0)
	_check(float(small["detail_half_m"]) <= float(small["world_half_m"]), "hi-res patch stays inside the world")
	_check(float(small["osm_half_m"]) <= float(small["world_half_m"]), "osm square stays inside the world")
	var keep := TerrainExtents.sanitize(90000.0, 5000.0, 5000.0)
	_check(is_equal_approx(float(keep["world_half_m"]), 90000.0) and is_equal_approx(float(keep["detail_half_m"]), 5000.0),
		"a valid saved 180 km / 10 km set is left alone")


func _test_overlay_half() -> void:
	_check(is_equal_approx(TerrainExtents.overlay_half(1500.0, 1000.0), 1000.0), "Ultra hyper capped at a 2 km patch")
	_check(is_equal_approx(TerrainExtents.overlay_half(500.0, 1500.0), 500.0), "a smaller overlay is unchanged")
	_check(is_equal_approx(TerrainExtents.overlay_half(0.0, 1500.0), 0.0), "an off overlay stays off")


func _test_key_matches() -> void:
	var lat := 33.3629
	var lon := -115.716
	var img_key: String = ImageryServiceScript._cache_key(lat, lon, 3000.0, 15)
	var dem_key: String = ElevationServiceScript._cache_key(lat, lon, 90000.0, 256, "base", "opentopo_COP90")
	_check(TerrainExtents.key_matches(img_key, lat, lon, 3000.0), "imagery key of this square matches")
	_check(not TerrainExtents.key_matches(img_key, lat, lon, 5000.0), "imagery key of the OLD square is stale")
	_check(TerrainExtents.key_matches(img_key + "_esri_clarity", lat, lon, 3000.0), "a source-chain suffix still matches")
	_check(TerrainExtents.key_matches(dem_key, lat, lon, 90000.0), "DEM key of this square matches")
	_check(not TerrainExtents.key_matches(dem_key, lat, lon, 9000.0), "9 km is not 90 km (whole-field token)")
	_check(not TerrainExtents.key_matches(dem_key, 3.3629, lon, 90000.0), "another site is stale")
	_check(TerrainExtents.key_matches("", lat, lon, 1.0), "an empty key is accepted")


func _rung_names(ladder: Array) -> String:
	var names: Array[String] = []
	for r in ladder:
		names.append(str((r as Dictionary)["cache_source"]))
	return ",".join(names)


func _test_source_ladder() -> void:
	var lat := 48.3252
	var lon := -122.2469
	var base_big: Array = ElevationServiceScript.source_ladder(lat, lon, "base", 90000.0, true, false)
	_check(_rung_names(base_big) == "opentopo_COP90,terrarium,openmeteo", "180 km base: COP90, Terrarium, Open-Meteo (%s)" % _rung_names(base_big))
	var base_small: Array = ElevationServiceScript.source_ladder(lat, lon, "base", 5000.0, true, false)
	_check(_rung_names(base_small) == "opentopo_SRTMGL1,opentopo_SRTMGL3,opentopo_COP90,terrarium,openmeteo",
		"10 km base walks every global product (%s)" % _rung_names(base_small))
	var det_us: Array = ElevationServiceScript.source_ladder(lat, lon, "detail", 1500.0, true, false)
	_check(_rung_names(det_us) == "opentopo_usgs1,opentopo_usgs10,opentopo_SRTMGL1,opentopo_COP90,terrarium,openmeteo",
		"US 3 km detail: 1 m, 10 m, global, Open-Meteo (%s)" % _rung_names(det_us))
	var det_miss: Array = ElevationServiceScript.source_ladder(lat, lon, "detail", 1500.0, true, true)
	_check(str((det_miss[0] as Dictionary)["cache_source"]) == "opentopo_usgs10", "a recorded 1 m miss starts at 10 m")
	var det_big: Array = ElevationServiceScript.source_ladder(lat, lon, "detail", 5000.0, true, false)
	_check(str((det_big[0] as Dictionary)["cache_source"]) == "opentopo_usgs10", "a 10 km patch is too big for 1 m")
	var det_eu: Array = ElevationServiceScript.source_ladder(46.0, 8.0, "detail", 1500.0, true, false)
	_check(_rung_names(det_eu) == "opentopo_SRTMGL1,opentopo_COP90,terrarium,openmeteo", "non-US detail is global only")
	var nokey: Array = ElevationServiceScript.source_ladder(lat, lon, "base", 15000.0, false, false)
	_check(_rung_names(nokey) == "terrarium,openmeteo", "no key: Terrarium tiles, then Open-Meteo (%s)" % _rung_names(nokey))
	_check(int(ElevationServiceScript.rung_grid_n(nokey[0], 87, "base")) == ElevationServiceScript.OPENTOPO_GRID_N,
		"a Terrarium base is at least 256²")
	_check(int(ElevationServiceScript.rung_grid_n(nokey[0], 512, "detail")) == ElevationServiceScript.DETAIL_GRID_N,
		"a Terrarium detail is 512²")
	# Open-Meteo bills one call per coordinate, 600 a minute: its grids must
	# fit one minute or the 7th batch is refused (the flat-world bug).
	var om_n := ElevationServiceScript.OPENMETEO_BASE_MAX_N
	_check(om_n * om_n <= 600, "an Open-Meteo base fits one minute's 600 calls (%d points)" % (om_n * om_n))
	var om_d := ElevationServiceScript.OPENMETEO_DETAIL_N
	_check(om_d * om_d <= 600, "an Open-Meteo detail fits one minute's 600 calls (%d points)" % (om_d * om_d))
	_check(not ElevationServiceScript._is_openmeteo_daily_limit(429,
		'{"error":true,"reason":"Minutely API request limit exceeded. Please try again in one minute."}'),
		"the MINUTELY limit is not the daily quota")
	_check(ElevationServiceScript._is_openmeteo_minutely_limit(
		'{"reason":"Minutely API request limit exceeded. Please try again in one minute.","error":true}'),
		"the minutely limit is recognised")
	var om: Dictionary = base_big[base_big.size() - 1]
	_check(int(ElevationServiceScript.rung_grid_n(om, 256, "base")) == ElevationServiceScript.OPENMETEO_BASE_MAX_N,
		"an Open-Meteo fallback of a keyed base is capped at %d²" % ElevationServiceScript.OPENMETEO_BASE_MAX_N)
	_check(int(ElevationServiceScript.rung_grid_n(base_big[0], 64, "base")) == ElevationServiceScript.OPENTOPO_GRID_N,
		"an OpenTopography base is at least 256²")


func _test_terrarium() -> void:
	# Bombay Beach, the default 60 km world: a handful of tiles at a zoom whose
	# pixels are no coarser than the 256² grid's spacing.
	var bbox := GeoMath.bbox_for(33.3626, -115.7146, 30000.0)
	var plan: Dictionary = ElevationServiceScript.terrarium_plan(bbox, 256)
	var tiles: Array = plan["tiles"]
	_check(int(plan["z"]) == 10, "60 km at 256²: z10 (got z%d)" % int(plan["z"]))
	_check(tiles.size() >= 4 and tiles.size() <= 16, "60 km at 256²: 4-16 tiles (%d)" % tiles.size())
	var px_deg := 360.0 / (256.0 * float(1 << int(plan["z"])))
	var spacing := (float(bbox["east"]) - float(bbox["west"])) / 255.0
	_check(px_deg <= spacing, "tile pixels no coarser than the sample spacing")
	# The mosaic covers the bbox with a pixel to spare on every side.
	var z := int(plan["z"])
	var xw := ElevationServiceScript.terrarium_tile_xf(float(bbox["west"]), z) - float(plan["x0"])
	var xe := ElevationServiceScript.terrarium_tile_xf(float(bbox["east"]), z) - float(plan["x0"])
	var yn := ElevationServiceScript.terrarium_tile_yf(float(bbox["north"]), z) - float(plan["y0"])
	var ys := ElevationServiceScript.terrarium_tile_yf(float(bbox["south"]), z) - float(plan["y0"])
	_check(xw > 0.0 and yn > 0.0 and xe < float(plan["ntx"]) and ys < float(plan["nty"]),
		"the mosaic covers the whole bbox")
	# A 180 km world drops zoom to stay under the tile cap.
	var big: Dictionary = ElevationServiceScript.terrarium_plan(GeoMath.bbox_for(33.3626, -115.7146, 90000.0), 256)
	_check((big["tiles"] as Array).size() <= ElevationServiceScript.TERRARIUM_MAX_TILES,
		"180 km stays under the tile cap (%d tiles, z%d)" % [(big["tiles"] as Array).size(), int(big["z"])])
	var det: Dictionary = ElevationServiceScript.terrarium_plan(GeoMath.bbox_for(33.3626, -115.7146, 3000.0), 512)
	_check(int(det["z"]) >= 13, "a 6 km detail patch at 512² is z13+ (z%d)" % int(det["z"]))
	# Tile y in 64-bit: z14 at Bombay Beach is ~3289.
	var ty := ElevationServiceScript.terrarium_tile_yf(33.3626, 13)
	_check(int(floor(ty)) == 3289, "tile y at z13 matches the slippy-map formula (%.3f)" % ty)
	# Decode: R·256 + G + B/256 − 32768, through a real PNG round trip.
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in 256:
		for x in 256:
			var m := -69.0 + float(x) * 4.0 + float(y) * 0.5   # metres
			var v := m + 32768.0
			var r := int(floor(v / 256.0))
			var g := int(floor(v)) - r * 256
			var b := int(round((v - floor(v)) * 256.0))
			img.set_pixel(x, y, Color8(r, g, b))
	var dec: PackedFloat32Array = ElevationServiceScript.decode_terrarium_png(img.save_png_to_buffer())
	_check(dec.size() == 65536, "a Terrarium tile decodes to 256² heights")
	if dec.size() == 65536:
		_check(absf(dec[0] - (-69.0)) < 0.01, "below-sea-level height decodes (%.2f)" % dec[0])
		_check(absf(dec[255 * 256 + 255] - (-69.0 + 1020.0 + 127.5)) < 0.01, "corner height decodes")
		# Sample the mosaic at a tile's own pixel centres: identity.
		var tb := {
			"west": ElevationServiceScript.terrarium_tile_x_to_lon(0.5 / 256.0, 0),
			"east": ElevationServiceScript.terrarium_tile_x_to_lon(255.5 / 256.0, 0),
			"north": ElevationServiceScript.terrarium_tile_y_to_lat(100.5 / 256.0, 0),
			"south": ElevationServiceScript.terrarium_tile_y_to_lat(155.5 / 256.0, 0),
		}
		var g2: PackedFloat32Array = ElevationServiceScript.sample_terrarium_mosaic(dec, 256, 256, 0, 0, 0, tb, 2)
		_check(absf(g2[0] - dec[100 * 256]) < 0.05 and absf(g2[3] - dec[155 * 256 + 255]) < 0.05,
			"mosaic sampling lands on pixel centres (%.2f vs %.2f)" % [g2[0], dec[100 * 256]])


func _test_tiling() -> void:
	var bbox := GeoMath.bbox_for(33.3629, -115.716, 90000.0)
	var tiles: Array = ElevationServiceScript.tile_bboxes(bbox, "COP90", ElevationServiceScript.OPENTOPO_MAX_TILE_CELLS)
	_check(tiles.size() >= 4, "a 180 km COP90 square goes up as tiles (%d)" % tiles.size())
	var cell := ElevationServiceScript.dem_cell_deg("COP90")
	var worst := 0.0
	var area := 0.0
	var padded := true
	for t in tiles:
		var req: Dictionary = (t as Dictionary)["req"]
		var own: Dictionary = (t as Dictionary)["own"]
		worst = maxf(worst, ((float(req["east"]) - float(req["west"])) / cell)
			* ((float(req["north"]) - float(req["south"])) / cell))
		area += (float(own["east"]) - float(own["west"])) * (float(own["north"]) - float(own["south"]))
		padded = padded and float(req["west"]) < float(own["west"]) and float(req["north"]) > float(own["north"])
	_check(padded, "every tile request is padded past its own share")
	_check(worst <= ElevationServiceScript.OPENTOPO_MAX_TILE_CELLS * 1.05, "every tile is under the cell cap (%.0f)" % worst)
	var full := (float(bbox["east"]) - float(bbox["west"])) * (float(bbox["north"]) - float(bbox["south"]))
	_check(absf(area - full) < full * 1e-9, "the tiles' own shares cover the square exactly")
	var one: Array = ElevationServiceScript.tile_bboxes(GeoMath.bbox_for(48.0, -122.0, 1500.0), "SRTMGL1",
		ElevationServiceScript.OPENTOPO_MAX_TILE_CELLS)
	_check(one.size() == 1 and (one[0] as Dictionary)["req"] == (one[0] as Dictionary)["own"],
		"a small square is one unpadded request")


## A synthetic geographic AAIGrid covering `b` (padded), value = a smooth
## function of lon/lat so bilinear sampling is exact enough to compare.
func _fake_grid(b: Dictionary, cell: float) -> Dictionary:
	var west := float(b["west"]) - cell * 3.0
	var south := float(b["south"]) - cell * 3.0
	var cols := int(ceil((float(b["east"]) + cell * 3.0 - west) / cell))
	var rows := int(ceil((float(b["north"]) + cell * 3.0 - south) / cell))
	var g := PackedFloat32Array()
	g.resize(cols * rows)
	for r in rows:
		var lat := south + (float(rows - r) - 0.5) * cell
		for c in cols:
			var lon := west + (float(c) + 0.5) * cell
			g[r * cols + c] = 100.0 + 400.0 * (lon + 116.0) + 250.0 * (lat - 33.0)
	return {"cols": cols, "rows": rows, "grid": g, "xllcorner": west, "yllcorner": south, "cellsize": cell}


func _test_tile_stitch() -> void:
	var bbox := GeoMath.bbox_for(33.3629, -115.716, 20000.0)
	var cell := 0.01
	var n := 64
	var whole := ElevationServiceScript.resample_aaigrid_to_bbox(_fake_grid(bbox, cell), bbox, n)
	var tiles: Array = ElevationServiceScript.tile_bboxes(bbox, "COP90", 1.0)  # force the max split
	var out := PackedFloat32Array()
	out.resize(n * n)
	out.fill(NAN)
	var written := 0
	for t in tiles:
		var td: Dictionary = t
		written += int(ElevationServiceScript.sample_tile_into(out, n, bbox, _fake_grid(td["req"], cell), td["own"]))
	var nan_left := 0
	var worst := 0.0
	for i in out.size():
		if is_nan(out[i]):
			nan_left += 1
		else:
			worst = maxf(worst, absf(out[i] - whole[i]))
	_check(nan_left == 0, "every sample is filled by some tile (%d missing)" % nan_left)
	_check(written >= n * n, "tiles wrote every sample (%d of %d)" % [written, n * n])
	_check(worst < 0.01, "stitched tiles == one request (worst %.4f m)" % worst)


func _test_retry_delay() -> void:
	var base := float(ElevationServiceScript.RETRY_BACKOFF)
	_check(is_equal_approx(ElevationServiceScript.retry_delay_s(1), base), "first retry waits the base backoff")
	_check(is_equal_approx(ElevationServiceScript.retry_delay_s(3), base * 4.0), "the backoff doubles")
	_check(is_equal_approx(ElevationServiceScript.retry_delay_s(1, PackedStringArray(["Retry-After: 30"])), 30.0),
		"Retry-After is honoured")
	_check(is_equal_approx(ElevationServiceScript.retry_delay_s(1, PackedStringArray(["retry-after: 9999"])), 120.0),
		"Retry-After is clamped")
