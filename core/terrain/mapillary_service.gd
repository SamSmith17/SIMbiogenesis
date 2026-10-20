extends Node

## MapillaryService — street-level photo REFERENCE for generated maps: an index
## of photo positions/bearings near a site plus on-demand thumbnails, shown in
## the Building Builder's Reference tab so the player can match a real facade.
## Reference/display only — photos are NOT projected onto geometry.
##
## Source: Mapillary Graph API (https://graph.mapillary.com). Imagery is
## CC BY-SA 4.0 — attribution() must be shown wherever thumbs appear. Google
## Street View is NOT an alternative source (its ToS forbids this use).
##
## Token: `user://terrain_config.cfg`  [mapillary] access_token=MLY|...
## (user-local, gitignored — docs/LOCAL_CONFIG.md policy; never log it). Without a
## token every request fails fast with a friendly reason.
##
## HTTP + cache + deferred-signal pattern mirrors imagery_service.gd: one
## HTTPRequest, jobs serialise through a queue, JSON index + thumbs cache under
## user://terrain_cache/mapillary/.

signal photo_index_ready(tag: String, photos: Array)
signal photo_index_failed(reason: String, tag: String)
signal thumb_ready(id: String, tex: ImageTexture)
signal thumb_failed(id: String, reason: String)

const API_URL := "https://graph.mapillary.com/images"
const CACHE_DIR := "user://terrain_cache/mapillary"
const CONFIG_PATH := "user://terrain_config.cfg"
const CACHE_VERSION := "v1"
const INDEX_LIMIT := 500
const ATTRIBUTION := "Photos © Mapillary contributors, CC BY-SA 4.0"

## Photo record (index entries): {id: String, lat: float, lon: float,
## x_m: float, z_m: float (site-local, +X east / −Z north), compass_angle:
## float (degrees, direction the camera FACES), thumb_url: String}.

var _http: HTTPRequest = null
var _busy := false
var _job: Dictionary = {}
var _pending: Array[Dictionary] = []
## Last loaded index (site-local coords) for photos_near queries.
var _photos: Array = []
var _site_lat := 0.0
var _site_lon := 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))


func attribution() -> String:
	return ATTRIBUTION


func is_configured() -> bool:
	return not _access_token().is_empty()


func _access_token() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return ""
	return str(cfg.get_value("mapillary", "access_token", "")).strip_edges()


## Fetch (or load from cache) the photo index for a square site. Photos land in
## photo_index_ready as an Array of records (see above) with site-local metres
## relative to (lat, lon); the index is also kept for photos_near().
func request_photo_index(lat: float, lon: float, half_extent_m: float,
		tag: String = "site") -> void:
	if not is_configured():
		photo_index_failed.emit.call_deferred(
			"No Mapillary token — add [mapillary] access_token= to %s" % CONFIG_PATH, tag)
		return
	_site_lat = lat
	_site_lon = lon
	var key := "idx_%s_%s_%s_%d" % [CACHE_VERSION,
		String.num(lat, 4), String.num(lon, 4), int(half_extent_m)]
	var cache_path := "%s/%s.json" % [CACHE_DIR, key]
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				_photos = _localize(parsed as Array, lat, lon)
				print("MapillaryService: index served from cache (%d photos) — no download" % _photos.size())
				photo_index_ready.emit.call_deferred(tag, _photos)
				return
	var bbox := GeoMath.bbox_for(lat, lon, half_extent_m)
	var url := "%s?fields=id,geometry,compass_angle,thumb_1024_url&bbox=%f,%f,%f,%f&limit=%d" % [
		API_URL, bbox["west"], bbox["south"], bbox["east"], bbox["north"], INDEX_LIMIT]
	_pending.append({"kind": "index", "url": url, "tag": tag,
		"cache_path": cache_path, "lat": lat, "lon": lon})
	_start_next()


## Fetch (or load from cache) one photo thumbnail; emits thumb_ready(id, tex).
func request_thumb(id: String, thumb_url: String) -> void:
	var cache_path := "%s/thumb_%s.jpg" % [CACHE_DIR, id]
	if FileAccess.file_exists(cache_path):
		var img := Image.new()
		if img.load(cache_path) == OK:
			thumb_ready.emit.call_deferred(id, ImageTexture.create_from_image(img))
			return
	if thumb_url.is_empty():
		thumb_failed.emit.call_deferred(id, "no thumb url")
		return
	_pending.append({"kind": "thumb", "url": thumb_url, "id": id,
		"cache_path": cache_path})
	_start_next()


## Photos within radius of a site-local point, nearest first. Pass facing_deg
## (the outward normal bearing of the wall being inspected) to keep only photos
## whose camera looks roughly AT it (±60°); NAN skips the filter.
func photos_near(x_m: float, z_m: float, radius_m: float,
		facing_deg: float = NAN) -> Array:
	var out: Array = []
	for p in _photos:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p
		var dx := float(d.get("x_m", 0.0)) - x_m
		var dz := float(d.get("z_m", 0.0)) - z_m
		var dist := sqrt(dx * dx + dz * dz)
		if dist > radius_m:
			continue
		if not is_nan(facing_deg):
			var cam := float(d.get("compass_angle", 0.0))
			# The photo should face TOWARD the wall, i.e. opposite its normal.
			var want := fmod(facing_deg + 180.0, 360.0)
			var diff := absf(fmod(cam - want + 540.0, 360.0) - 180.0)
			if diff > 60.0:
				continue
		var rec := d.duplicate()
		rec["dist_m"] = dist
		out.append(rec)
	out.sort_custom(func(a: Variant, b: Variant) -> bool:
		return float((a as Dictionary)["dist_m"]) < float((b as Dictionary)["dist_m"]))
	return out


func photo_count() -> int:
	return _photos.size()


func _start_next() -> void:
	if _busy or _pending.is_empty():
		return
	_ensure_http()
	_job = _pending.pop_front()
	_busy = true
	var headers := PackedStringArray()
	if str(_job.get("kind", "")) == "index":
		headers.append("Authorization: OAuth %s" % _access_token())
	var err := _http.request(str(_job["url"]), headers)
	if err != OK:
		_finish_job_failed("http request error %d" % err)


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	var job := _job
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		_finish_job_failed("HTTP %d (result %d)" % [code, result])
		return
	if str(job.get("kind", "")) == "index":
		_handle_index_body(job, body)
	else:
		_handle_thumb_body(job, body)
	_busy = false
	_job = {}
	_start_next()


func _handle_index_body(job: Dictionary, body: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("data") is Array):
		photo_index_failed.emit(str("unexpected index payload"), str(job["tag"]))
		return
	var raw: Array = []
	for item in ((parsed as Dictionary)["data"] as Array):
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var geom: Dictionary = d.get("geometry", {}) if d.get("geometry") is Dictionary else {}
		var coords: Array = geom.get("coordinates", []) if geom.get("coordinates") is Array else []
		if coords.size() < 2:
			continue
		raw.append({
			"id": str(d.get("id", "")),
			"lon": float(coords[0]),
			"lat": float(coords[1]),
			"compass_angle": float(d.get("compass_angle", 0.0)),
			"thumb_url": str(d.get("thumb_1024_url", "")),
		})
	var f := FileAccess.open(str(job["cache_path"]), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(raw))
		f.close()
	_photos = _localize(raw, float(job["lat"]), float(job["lon"]))
	print("MapillaryService: indexed %d photos for site" % _photos.size())
	photo_index_ready.emit(str(job["tag"]), _photos)


func _handle_thumb_body(job: Dictionary, body: PackedByteArray) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(body)
	if err != OK:
		err = img.load_png_from_buffer(body)
	if err != OK:
		thumb_failed.emit(str(job["id"]), "undecodable image")
		return
	var fa := FileAccess.open(str(job["cache_path"]), FileAccess.WRITE)
	if fa != null:
		fa.store_buffer(body)
		fa.close()
	thumb_ready.emit(str(job["id"]), ImageTexture.create_from_image(img))


func _finish_job_failed(reason: String) -> void:
	var job := _job
	_busy = false
	_job = {}
	if str(job.get("kind", "")) == "index":
		push_warning("MapillaryService: index fetch failed (%s)" % reason)
		photo_index_failed.emit(reason, str(job.get("tag", "site")))
	else:
		thumb_failed.emit(str(job.get("id", "")), reason)
	_start_next()


func _localize(raw: Array, lat: float, lon: float) -> Array:
	var out: Array = []
	for item in raw:
		if not (item is Dictionary):
			continue
		var d: Dictionary = (item as Dictionary).duplicate()
		var local := GeoMath.lonlat_to_local_m(
			float(d.get("lat", 0.0)), float(d.get("lon", 0.0)), lat, lon)
		d["x_m"] = local.x
		d["z_m"] = local.y
		out.append(d)
	return out
