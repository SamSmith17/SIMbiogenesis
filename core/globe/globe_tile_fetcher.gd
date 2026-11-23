class_name GlobeTileFetcher
extends Node

## Fetches, caches and hands out the globe's map tiles (one node per GlobeView).
##
## Each frame the view says which tiles it wants (begin_frame / want); queued
## requests nobody wants any more are dropped, the rest go out on a small pool
## of HTTPRequests, nearest-first. Every tile is written to
## user://globe_cache/<layer>/<z>/<x>/<y>.<ext> once and decoded from disk
## after that, a few per frame. Textures live in an LRU of MAX_TEXTURES; a
## failed tile waits RETRY_S before it is asked for again. An ESRI "no data"
## placeholder counts as a failure, so the view keeps the parent's pixels.

signal tile_ready(layer: String, key: Vector3i)

const CACHE_ROOT := "user://globe_cache"
const POOL_SIZE := 10
const TIMEOUT_S := 20.0
const MAX_TEXTURES := 900
const DECODES_PER_FRAME := 8
const MAX_DECODES_BURST := 24
const DECODE_BUDGET_USEC := 3500
const RETRY_S := 30.0

## id -> {url: "%d/%d/%d" in z, y, x order, ext, max_zoom, attribution}.
const LAYERS := {
	"esri": {
		"url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d",
		"ext": "jpg",
		"max_zoom": 17,
		"blank_check": true,
		"attribution": "Imagery © Esri, Maxar, Earthstar Geographics, and the GIS User Community",
	},
	"night": {
		"url": "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_Black_Marble/default/2016-01-01/GoogleMapsCompatible_Level8/%d/%d/%d.png",
		"ext": "png",
		"max_zoom": 8,
		"blank_check": false,
		"attribution": "Night lights: NASA Earth Observatory Black Marble (GIBS)",
	},
}

## Tests (and the harness) set this to make every download fail.
static var offline_for_test := false
## Layers whose decoded pixels are kept beside the texture (get_image): the
## night tiles, which GlobeCityLights turns into points.
var keep_images := {"night": true}

## This fetcher's layers: LAYERS plus any registered at run time (a daily
## satellite layer per date, register_layer).
var layers: Dictionary = LAYERS.duplicate(true)

var _textures := {}      # "layer|z|x|y" -> {tex, used}
var _failed := {}        # key string -> retry-at msec
var _queue := {}         # key string -> {layer, key, prio}
var _in_flight := {}     # key string -> HTTPRequest
var _disk_pending := {}  # key string -> {layer, key, prio}
var _wanted := {}
var _frame := 0
var _pool: Array[HTTPRequest] = []
var _free: Array[HTTPRequest] = []
var stats := {"downloaded": 0, "from_disk": 0, "failed": 0, "evicted": 0}


static func key_str(layer: String, k: Vector3i) -> String:
	return "%s|%d|%d|%d" % [layer, k.x, k.y, k.z]


func cache_path(layer: String, k: Vector3i) -> String:
	return "%s/%s/%d/%d/%d.%s" % [CACHE_ROOT, layer, k.x, k.y, k.z, str(layers[layer].ext)]


func tile_url(layer: String, k: Vector3i) -> String:
	return str(layers[layer].url) % [k.x, k.z, k.y]


func max_zoom(layer: String) -> int:
	return int(layers.get(layer, {}).get("max_zoom", 0))


## Adds (or replaces) a layer; `def` as LAYERS entries.
func register_layer(id: String, def: Dictionary) -> void:
	layers[id] = def


## The attribution line for the layers in `ids`.
func attribution_for(ids: Array) -> String:
	var parts: PackedStringArray = []
	for id in ids:
		if layers.has(id):
			var a := str(layers[id].attribution)
			if not parts.has(a):
				parts.append(a)
	return " · ".join(parts)


static func attribution() -> String:
	var parts: PackedStringArray = []
	for id in LAYERS:
		parts.append(str(LAYERS[id].attribution))
	return " · ".join(parts)


func _ready() -> void:
	for i in POOL_SIZE:
		var h := HTTPRequest.new()
		h.timeout = TIMEOUT_S
		h.use_threads = true
		add_child(h)
		h.request_completed.connect(_on_done.bind(h))
		_pool.append(h)
		_free.append(h)


func begin_frame() -> void:
	_frame += 1
	_wanted.clear()


## Ask for a tile this frame; lower `prio` goes first.
func want(layer: String, k: Vector3i, prio: float) -> void:
	var ks := key_str(layer, k)
	_wanted[ks] = true
	if _textures.has(ks):
		_textures[ks].used = _frame
		return
	if _in_flight.has(ks):
		return
	if _failed.has(ks) and Time.get_ticks_msec() < int(_failed[ks]):
		return
	var job := {"layer": layer, "key": k, "prio": prio}
	if FileAccess.file_exists(cache_path(layer, k)):
		_disk_pending[ks] = job
	else:
		_queue[ks] = job


## The decoded pixels of a tile of a keep_images layer, or null.
func get_image(layer: String, k: Vector3i) -> Image:
	var ks := key_str(layer, k)
	if _textures.has(ks):
		return _textures[ks].get("img")
	return null


func get_texture(layer: String, k: Vector3i) -> Texture2D:
	var ks := key_str(layer, k)
	if _textures.has(ks):
		_textures[ks].used = _frame
		return _textures[ks].tex
	return null


func has_failed(layer: String, k: Vector3i) -> bool:
	return _failed.has(key_str(layer, k))


func pending_count() -> int:
	return _queue.size() + _in_flight.size() + _disk_pending.size()


func texture_count() -> int:
	return _textures.size()


func _process(_dt: float) -> void:
	_drop_unwanted(_queue)
	_drop_unwanted(_disk_pending)
	_decode_from_disk()
	_dispatch()
	_evict()


func _drop_unwanted(d: Dictionary) -> void:
	for ks in d.keys():
		if not _wanted.has(ks):
			d.erase(ks)


func _sorted(d: Dictionary) -> Array:
	var jobs := d.values()
	jobs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.prio) < float(b.prio))
	return jobs


func _decode_from_disk() -> void:
	if _disk_pending.is_empty():
		return
	var start_us := Time.get_ticks_usec()
	var n := 0
	for job in _sorted(_disk_pending):
		if n >= DECODES_PER_FRAME and (n >= MAX_DECODES_BURST or Time.get_ticks_usec() - start_us >= DECODE_BUDGET_USEC):
			break
		n += 1
		var ks := key_str(job.layer, job.key)
		_disk_pending.erase(ks)
		var bytes := FileAccess.get_file_as_bytes(cache_path(job.layer, job.key))
		if not _accept(job.layer, job.key, bytes):
			# A bad cached file: fetch it again.
			DirAccess.remove_absolute(ProjectSettings.globalize_path(cache_path(job.layer, job.key)))
			_queue[ks] = job
		else:
			stats.from_disk += 1


func _dispatch() -> void:
	if _free.is_empty() or _queue.is_empty():
		return
	for job in _sorted(_queue):
		if _free.is_empty():
			break
		var ks := key_str(job.layer, job.key)
		_queue.erase(ks)
		if offline_for_test:
			_fail(ks)
			continue
		var h: HTTPRequest = _free.pop_back()
		h.set_meta("job", job)
		var err := h.request(tile_url(job.layer, job.key))
		if err != OK:
			_free.append(h)
			_fail(ks)
			continue
		_in_flight[ks] = h


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		h: HTTPRequest) -> void:
	var job: Dictionary = h.get_meta("job", {})
	_free.append(h)
	if job.is_empty():
		return
	var ks := key_str(job.layer, job.key)
	_in_flight.erase(ks)
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.is_empty():
		_fail(ks)
		return
	if not _accept(job.layer, job.key, body):
		_fail(ks)
		return
	var path := cache_path(job.layer, job.key)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(body)
		f.close()
	stats.downloaded += 1


func _accept(layer: String, k: Vector3i, bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		return false
	var img := Image.new()
	var png := str(layers[layer].ext) == "png"
	var err := img.load_png_from_buffer(bytes) if png else img.load_jpg_from_buffer(bytes)
	if err != OK:
		# Some servers send PNG for a .jpg request and the other way round.
		err = img.load_jpg_from_buffer(bytes) if png else img.load_png_from_buffer(bytes)
	if err != OK or img.is_empty():
		return false
	if bool(layers[layer].get("blank_check", false)) and ImagerySources.is_blank_tile(img):
		return false
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var ks := key_str(layer, k)
	_textures[ks] = {"tex": ImageTexture.create_from_image(img), "used": _frame}
	if keep_images.has(layer):
		_textures[ks]["img"] = img
	_failed.erase(ks)
	tile_ready.emit(layer, k)
	return true


func _fail(ks: String) -> void:
	_failed[ks] = Time.get_ticks_msec() + int(RETRY_S * 1000.0)
	stats.failed += 1


func _evict() -> void:
	if _textures.size() <= MAX_TEXTURES:
		return
	var keys := _textures.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		return int(_textures[a].used) < int(_textures[b].used))
	var over := _textures.size() - MAX_TEXTURES
	for ks: String in keys:
		if over <= 0:
			break
		# Never evict what was asked for this frame or anything at z <= 3.
		if int(_textures[ks].used) >= _frame or int(ks.split("|")[1]) <= 3:
			continue
		_textures.erase(ks)
		stats.evicted += 1
		over -= 1
