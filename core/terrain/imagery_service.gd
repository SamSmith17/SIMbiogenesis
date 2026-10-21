extends Node

## ImageryService — fetches satellite imagery for a location as a single draped
## texture for the generated terrain (ROADMAP Pillar 1, the recognizable-place
## requirement).
##
## Source: ESRI World Imagery XYZ tiles (JPEG, which Godot decodes natively — raw
## Sentinel-2 JP2 is intentionally avoided in v1). Tiles covering the bounding box
## are fetched at a zoom chosen from the extent, stitched into one image, then
## cropped to the exact bbox so UV 0..1 aligns with the terrain mesh.
##   https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer
##   Free for use with attribution (see attribution()).
##
## HTTP + cache + deferred-signal pattern mirrors core/weather_service.gd. Stitched
## results cache as PNG under user://terrain_cache/imagery/. Offline / on failure:
## emits a neutral texture so the world still loads.

## `tag` distinguishes concurrent layers for one site, e.g. "base" (the full ~30 km
## drape) vs "detail" (the high-res centre patch). Callers connecting older 2-arg
## handlers still work — Godot drops the extra arg.
signal imagery_ready(key: String, texture: ImageTexture, tag: String)
signal imagery_failed(reason: String, tag: String)
signal imagery_progress(done: int, total: int)

const TILE_URL := "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d"
const CACHE_DIR := "user://terrain_cache/imagery"
## v3: exact geographic bbox crop (Mercator-linear pixels). Mesh sampling
## corrects Mercator↔equirect in the terrain shader. v2 centre-bias crops broke
## OSM registration (shifted buildings south); do not reuse those files.
const CACHE_VERSION := "v3"
const TILE_PX := 256
const ATTRIBUTION := "Imagery © Esri, Maxar, Earthstar Geographics, and the GIS User Community"
## Polite spacing between tiles, and backoff when a tile server throttles us.
const TILE_DELAY := 0.12
const RETRY_BACKOFF := 3.0
const MAX_RETRIES := 4

var _http: HTTPRequest = null
## Attribution per layer tag for the mosaic that tag last received (the
## sources its tiles actually came from — see ImagerySources).
var _attrib_by_tag: Dictionary = {}
## BC7 compression tasks in flight (key → WorkerThreadPool task id).
var _hq_tasks: Dictionary = {}
var _busy: bool = false
var _job: Dictionary = {}
## Pending jobs (base + detail layers serialise through the single HTTPRequest).
var _pending: Array[Dictionary] = []
## Bumped per job and per reset_session: a retry timer or a stale HTTP reply
## only acts while the job it was armed for is still the current one.
var _job_seq := 0


## Test switch: every download fails as a dropped connection does (cached
## layers still load). Set by checks, or `--imagery-offline` after "--".
static var offline_for_test := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_http()
	if "--imagery-offline" in OS.get_cmdline_user_args():
		offline_for_test = true
		print("ImageryService: --imagery-offline — every download will fail")


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func attribution() -> String:
	var extra: Array = []
	for a in _attrib_by_tag.values():
		if str(a) != ATTRIBUTION and not extra.has(a):
			extra.append(a)
	if extra.is_empty():
		return ATTRIBUTION
	return ATTRIBUTION + " · " + " · ".join(PackedStringArray(extra))


## Drop every queued and in-flight layer (a new map load). This service is an
## autoload and outlives the scene: without this the previous load's hyper /
## site / detail jobs kept downloading ahead of the new load's base drape (the
## base phase then timed out on a slow 8k site patch) and their results were
## taken by the new loader. BC7 tasks already running finish and emit; the
## loader drops results whose key is not its own (TerrainExtents.key_matches).
func reset_session() -> void:
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()
	_job_seq += 1
	_busy = false
	_job = {}
	_pending.clear()


## Attribution for one layer ("hyper", "site", …): the sources its tiles came from.
func attribution_for(tag: String) -> String:
	return str(_attrib_by_tag.get(tag, ATTRIBUTION))


## Fetch (or load from cache) draped imagery for the square of side
## (2*half_extent_m) centred on (lat, lon). Emits imagery_ready when done.
## `tag` labels the layer ("base", "detail", …) and is echoed back in the signals;
## `max_zoom` caps the zoom pick (raise it for a small high-res centre patch).
## Multiple requests serialise through one HTTPRequest, so base + detail can be
## fired together without colliding.
##
## `sources` is a per-tile fallback chain of ImagerySources ids (empty = plain
## ESRI, byte-identical to before): each tile is taken from the first source
## that holds it. `hq` compresses the GPU copy to BC7 on a worker thread
## instead of DXT1 — for the sharpest layer, where DXT1's two-colour 4×4
## blocks read as pixelation at walking height.
func request_imagery(lat: float, lon: float, half_extent_m: float,
		target_px: int = 2048, tag: String = "base", max_zoom: int = 17,
		force_refetch: bool = false, sources: Array = [], hq: bool = false) -> void:
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var z := GeoMath.pick_zoom(bbox, target_px, max_zoom)
	var chain: Array = sources.duplicate() if not sources.is_empty() else ImagerySources.default_chain()
	var key := layer_key(lat, lon, half_extent_m, target_px, max_zoom, sources)
	var cache_path := cache_path_for(key)
	if not force_refetch and TerrainCacheSettings.cache_enabled():
		var img := Image.new()
		var loaded := false
		var from := ""
		for cand in cache_candidates(key):
			if FileAccess.file_exists(cand) and img.load(cand) == OK:
				loaded = true
				from = cand
				break
		if loaded:
			var pk := plain_key(key)
			var plain := not pk.is_empty() and (from == cache_path_for(pk)
				or from == cache_path_for(pk).replace("img_v3_", "img_v1_"))
			if from != cache_path:
				print("ImageryService: '%s' layer from an older cache file (%s)" % [tag, from.get_file()])
			print("ImageryService: '%s' layer served from cache (%s, z%d) — no download" % [tag, key, z])
			# A pre-source-chain file is a plain ESRI mosaic.
			_attrib_by_tag[tag] = ImagerySources.attribution_for(["esri"] if plain else _cached_sources(key, chain))
			if hq:
				_emit_hq_async(key, img, tag)
			else:
				imagery_ready.emit.call_deferred(key, _make_drape_texture(img), tag)
			return
	print("ImageryService: '%s' layer not cached — fetching z%d tiles …" % [tag, z])

	var rng := GeoMath.tile_range_for_bbox(bbox, z)
	var cols := int(rng["max_x"]) - int(rng["min_x"]) + 1
	var rows := int(rng["max_y"]) - int(rng["min_y"]) + 1
	var tiles := []
	for ty in range(int(rng["min_y"]), int(rng["max_y"]) + 1):
		for tx in range(int(rng["min_x"]), int(rng["max_x"]) + 1):
			tiles.append(Vector2i(tx, ty))
	var stitched := Image.create(cols * TILE_PX, rows * TILE_PX, false, Image.FORMAT_RGB8)
	_pending.append({
		"key": key,
		"tag": tag,
		"z": z,
		"bbox": bbox,
		"min_x": int(rng["min_x"]),
		"min_y": int(rng["min_y"]),
		"cols": cols,
		"rows": rows,
		"tiles": tiles,
		"idx": 0,
		"img": stitched,
		"retries": 0,
		"chain": chain,
		"src_i": 0,
		"used": {},
		"hq": hq,
	})
	_start_next()


## Begin the next queued job if idle.
func _start_next() -> void:
	if _busy or _pending.is_empty():
		return
	_job = _pending.pop_front()
	_job_seq += 1
	_job["seq"] = _job_seq
	_busy = true
	_fire_tile()


func _fire_tile() -> void:
	if offline_for_test:
		_fail.call_deferred("offline (test)")
		return
	_ensure_http()
	var tiles: Array = _job["tiles"]
	var t: Vector2i = tiles[int(_job["idx"])]
	var chain: Array = _job.get("chain", ImagerySources.default_chain())
	var src := str(chain[clampi(int(_job.get("src_i", 0)), 0, chain.size() - 1)])
	var url := ImagerySources.tile_url(src, int(_job["z"]), t.x, t.y)
	var err := _http.request(url)
	if err != OK:
		_fail("HTTPRequest error %d" % err)


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if _job.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		if _next_source():
			return
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	if response_code == 429 or response_code >= 500:
		var retries := int(_job.get("retries", 0)) + 1
		_job["retries"] = retries
		if retries > MAX_RETRIES:
			if _next_source():
				return
			_fail("rate limited (HTTP %d) after %d retries" % [response_code, MAX_RETRIES])
			return
		_after(RETRY_BACKOFF * float(retries), _fire_tile)
		return
	if response_code != 200:
		if _next_source():
			return
		_fail("fetch failed (result %d, HTTP %d)" % [result, response_code])
		return
	var tile_img := Image.new()
	# ESRI World Imagery serves JPEG; ArcGIS image caches mix JPEG and PNG.
	if tile_img.load_jpg_from_buffer(body) != OK and tile_img.load_png_from_buffer(body) != OK:
		if _next_source():
			return
		_fail("tile decode failed")
		return
	# A source that does not hold this tile (an empty cache tile, ESRI's
	# placeholder): try the next one in the chain. The LAST source's tile is
	# kept whatever it holds — the whole-mosaic placeholder test in _finish
	# still rejects a layer that is nothing but placeholders.
	var chain: Array = _job.get("chain", ImagerySources.default_chain())
	if int(_job.get("src_i", 0)) < chain.size() - 1 and ImagerySources.is_blank_tile(tile_img):
		if _next_source():
			return
	var used: Dictionary = _job.get("used", {})
	var src_id := str(chain[clampi(int(_job.get("src_i", 0)), 0, chain.size() - 1)])
	used[src_id] = int(used.get(src_id, 0)) + 1
	_job["used"] = used
	if tile_img.get_format() != Image.FORMAT_RGB8:
		tile_img.convert(Image.FORMAT_RGB8)
	var tiles: Array = _job["tiles"]
	var idx := int(_job["idx"])
	var t: Vector2i = tiles[idx]
	var px := (t.x - int(_job["min_x"])) * TILE_PX
	var py := (t.y - int(_job["min_y"])) * TILE_PX
	var stitched: Image = _job["img"]
	stitched.blit_rect(tile_img, Rect2i(0, 0, TILE_PX, TILE_PX), Vector2i(px, py))

	_job["idx"] = idx + 1
	_job["retries"] = 0
	_job["src_i"] = 0
	imagery_progress.emit(idx + 1, tiles.size())
	if idx + 1 < tiles.size():
		_after(TILE_DELAY, _fire_tile)
	else:
		_finish()


## Move the current tile on to the next source in the chain; false at the end.
func _next_source() -> bool:
	var chain: Array = _job.get("chain", [])
	var i := int(_job.get("src_i", 0)) + 1
	if i >= chain.size():
		return false
	_job["src_i"] = i
	_job["retries"] = 0
	_after(TILE_DELAY, _fire_tile)
	return true


func _after(delay: float, cb: Callable) -> void:
	var seq := int(_job.get("seq", -1))
	var fire := func() -> void:
		if _busy and not _job.is_empty() and int(_job.get("seq", -2)) == seq:
			cb.call()
	get_tree().create_timer(delay).timeout.connect(fire, CONNECT_ONE_SHOT)


func _finish() -> void:
	var stitched: Image = _job["img"]
	var z := int(_job["z"])
	var bbox: Dictionary = _job["bbox"]
	# Exact geographic bbox crop — UV 0..1 corners match GeoMath.bbox_for.
	# Mercator nonlinearity vs the tangent-plane mesh is corrected in the
	# terrain shader (equirect_to_mercator_uv), not by shifting this crop.
	var crop := mercator_bbox_crop_rect(
		stitched.get_width(), stitched.get_height(),
		int(_job["min_x"]), int(_job["min_y"]), z, bbox)
	var region := stitched.get_region(crop)

	# ESRI returns HTTP-200 "Map data not yet available" placeholder tiles at
	# zooms it doesn't cover for a region (rural z20+). A mosaic of them is
	# near-uniform light grey — caching/serving that poisons drapes and roof
	# orthos, so treat it as a failed layer instead.
	if _region_is_placeholder(region):
		var bad_tag := str(_job.get("tag", "base"))
		var bad_z := int(_job["z"])
		_busy = false
		_job = {}
		imagery_failed.emit(
			"zoom %d not covered here (placeholder tiles)" % bad_z, bad_tag)
		_start_next()
		return

	var key := str(_job["key"])
	var tag := str(_job.get("tag", "base"))
	var used: Dictionary = _job.get("used", {})
	var hq := bool(_job.get("hq", false))
	if TerrainCacheSettings.cache_enabled():
		region.save_png("%s/%s.png" % [CACHE_DIR, key])
		if used.size() > 1 or (used.size() == 1 and not used.has("esri")):
			_save_sources_sidecar(key, used)
	var used_ids: Array = used.keys()
	_attrib_by_tag[tag] = ImagerySources.attribution_for(used_ids if not used_ids.is_empty() else ["esri"])
	if used.size() > 1 or (used.size() == 1 and not used.has("esri")):
		print("ImageryService: '%s' layer tiles by source %s" % [tag, JSON.stringify(used)])
	_busy = false
	_job = {}
	if hq:
		_emit_hq_async(key, region, tag)
	else:
		imagery_ready.emit(key, _make_drape_texture(region), tag)
	_start_next()


## BC7 the GPU copy on a worker thread (about 4 s for a 5k² drape — too long
## for the main thread), then emit on the main thread. Falls back to DXT1 if
## BC7 is unavailable on this platform.
func _emit_hq_async(key: String, img: Image, tag: String) -> void:
	var work := img.duplicate() as Image
	var task := func() -> void:
		if not work.has_mipmaps():
			work.generate_mipmaps()
		if can_compress_bc() and work.compress(Image.COMPRESS_BPTC, Image.COMPRESS_SOURCE_SRGB) != OK:
			work.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
		_emit_hq_done.call_deferred(key, work, tag)
	_hq_tasks[key] = WorkerThreadPool.add_task(task, false, "imagery_bc7_%s" % tag)


func _emit_hq_done(key: String, img: Image, tag: String) -> void:
	# Every WorkerThreadPool task must be waited on; an un-waited one crashed
	# the engine on quit (0xC0000005). The task is at its last line here.
	if _hq_tasks.has(key):
		WorkerThreadPool.wait_for_task_completion(int(_hq_tasks[key]))
		_hq_tasks.erase(key)
	imagery_ready.emit(key, ImageTexture.create_from_image(img), tag)


func _exit_tree() -> void:
	for id in _hq_tasks.values():
		WorkerThreadPool.wait_for_task_completion(int(id))
	_hq_tasks.clear()


## The sources a cached mosaic was stitched from (a JSON sidecar beside the
## PNG); a plain-ESRI cache has none.
func _cached_sources(key: String, chain: Array) -> Array:
	var p := "%s/%s.sources.json" % [CACHE_DIR, key]
	if FileAccess.file_exists(p):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if parsed is Dictionary and not (parsed as Dictionary).is_empty():
			return (parsed as Dictionary).keys()
	return ["esri"] if ImagerySources.chain_key(chain).is_empty() else [str(chain[0])]


func _save_sources_sidecar(key: String, used: Dictionary) -> void:
	var f := FileAccess.open("%s/%s.sources.json" % [CACHE_DIR, key], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(used))


## Pixel rect inside a tile mosaic covering `bbox` exactly (no centre shift).
static func mercator_bbox_crop_rect(stitched_w: int, stitched_h: int,
		min_x: int, min_y: int, z: int, bbox: Dictionary) -> Rect2i:
	var f_nw := GeoMath.lonlat_to_tile_f(bbox["west"], bbox["north"], z)
	var f_se := GeoMath.lonlat_to_tile_f(bbox["east"], bbox["south"], z)
	var x0 := int(round((f_nw.x - float(min_x)) * TILE_PX))
	var y0 := int(round((f_nw.y - float(min_y)) * TILE_PX))
	var x1 := int(round((f_se.x - float(min_x)) * TILE_PX))
	var y1 := int(round((f_se.y - float(min_y)) * TILE_PX))
	x0 = clampi(x0, 0, maxi(stitched_w - 1, 0))
	y0 = clampi(y0, 0, maxi(stitched_h - 1, 0))
	var rw := clampi(x1 - x0, 1, stitched_w - x0)
	var rh := clampi(y1 - y0, 1, stitched_h - y0)
	return Rect2i(x0, y0, rw, rh)


## True when the stitched result is a near-uniform image (ESRI "Map data not
## yet available" placeholders): sample a coarse grid and measure luminance
## spread. Real satellite imagery of ANY landscape has far more variance.
static func _region_is_placeholder(img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	if w < 8 or h < 8:
		return false
	var lo := 1.0
	var hi := 0.0
	for sy in 8:
		for sx in 8:
			var c := img.get_pixel(w * (2 * sx + 1) / 16, h * (2 * sy + 1) / 16)
			var lum := (c.r + c.g + c.b) / 3.0
			lo = minf(lo, lum)
			hi = maxf(hi, lum)
	return hi - lo < 0.04


## Builds the GPU texture for a drape image: mipmaps + S3TC/DXT compression.
## A 4096² RGBA8 drape with mips is ~89 MB of VRAM; DXT brings it to ~11-22 MB —
## real headroom on the 2 GB shared-memory iGPUs this runs on (and VRAM pressure
## is a contributor to the Vulkan device-lost crashes seen when the editor and
## game share the GPU). CPU-side consumers that call get_image() on the drape
## (landcover gate, scatter samplers, camp scatter) decompress on read.
## Disk cache stays PNG — only the GPU copy is compressed, so cache files and
## every existing code path that loads them are unchanged.
static func _make_drape_texture(img: Image) -> ImageTexture:
	if img.get_width() >= 1024:
		if not img.has_mipmaps():
			img.generate_mipmaps()
		if can_compress_bc():
			img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
	return ImageTexture.create_from_image(img)


## Godot's BC compressors (cvtt / betsy) are editor-only modules: an exported
## game has none, and Image.compress() then logs an engine error and leaves
## the image as RGBA8. Releases therefore upload drapes uncompressed (about 4x
## the VRAM of DXT1); asking first keeps the error out of every load.
static func can_compress_bc() -> bool:
	return not OS.has_feature("template")


func _fail(reason: String) -> void:
	var tag := str(_job.get("tag", "base"))
	_busy = false
	_job = {}
	imagery_failed.emit(reason, tag)
	_start_next()


## The cache key request_imagery() uses for these arguments — the one place
## it is computed, so TerrainImageryPlan's "is this layer cached?" can never
## disagree with the request it predicts.
static func layer_key(lat: float, lon: float, half_extent_m: float, target_px: int,
		max_zoom: int, sources: Array = []) -> String:
	var z := GeoMath.pick_zoom(GeoMath.bbox_for(lat, lon, half_extent_m), target_px, max_zoom)
	var chain: Array = sources if not sources.is_empty() else ImagerySources.default_chain()
	var key := _cache_key(lat, lon, half_extent_m, z)
	var ck := ImagerySources.chain_key(chain)
	if not ck.is_empty():
		key += "_" + ck
	return key


static func cache_path_for(key: String) -> String:
	return "%s/%s.png" % [CACHE_DIR, key]


## The files a layer may already be cached as, best first:
##   1. its own name;
##   2. the pre-v3 name (img_v1_…, exact-bbox crops the shader still corrects);
##   3. for a layer fetched through a source chain (hyper, site: the key ends
##      "_esri_clarity" or a regional source id), the name it had BEFORE source
##      chains existed — the same square at the same zoom, as a plain ESRI
##      mosaic. Every chain ends in ESRI, so that is the chain's last resort
##      anyway, and it keeps caches (and shared packs) made before the chains
##      from being ignored and downloaded again.
static func cache_candidates(key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var p := cache_path_for(key)
	out.append(p)
	out.append(p.replace("img_v3_", "img_v1_"))
	var pk := plain_key(key)
	if not pk.is_empty():
		var pp := cache_path_for(pk)
		out.append(pp)
		out.append(pp.replace("img_v3_", "img_v1_"))
	return out


## The first file in cache_candidates() that exists, "" when none.
static func cached_file_for_key(key: String) -> String:
	for c in cache_candidates(key):
		if FileAccess.file_exists(c):
			return c
	return ""


## A chained layer's key without its source suffix ("img_v3_…_z18_esri_clarity"
## -> "img_v3_…_z18"); "" for a key that has none.
static func plain_key(key: String) -> String:
	var at := key.rfind("_z")
	if at < 0:
		return ""
	var rest := key.substr(at + 2)
	var digits := 0
	while digits < rest.length() and rest[digits] >= "0" and rest[digits] <= "9":
		digits += 1
	if digits == 0 or digits >= rest.length() or rest[digits] != "_":
		return ""
	return key.substr(0, at + 2 + digits)


static func _cache_key(lat: float, lon: float, half_extent_m: float, z: int) -> String:
	return "img_%s_%.4f_%.4f_%d_z%d" % [CACHE_VERSION, lat, lon, int(half_extent_m), z]
