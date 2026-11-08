class_name GlobeWeather
extends Node

## Whole-Earth weather images for the globe (Globe mode Phase 3), keyless.
##
## - Clouds: NOAA nowCOAST's global longwave-infrared mosaic (GOES / Himawari
##   / Meteosat, hourly; only the last ~5 hours are served). One 4096 x 2048
##   equirect gray+alpha PNG per hour; higher gray = colder = higher cloud top.
## - Rain: NASA GIBS IMERG precipitation rate, every 30 min since 1998, ~5 h
##   behind real time. One 2048 x 1024 RGBA PNG per slot (the GIBS colour ramp,
##   transparent where dry). A time GIBS has nothing for comes back as a
##   fully transparent image: the slot steps back 30 min, up to MAX_STEPS.
## - Satellite of the day: MODIS Terra true colour, daily since 2000, as Web
##   Mercator tiles for GlobeTileFetcher (daily_layer_def).
##
## - Wind and temperature: NOAA GFS 1° on the AWS open-data bucket (runs
##   every 6 h, kept since 2021; a run is on the bucket ~4.5 h after its
##   hour). Only the three fields are fetched, by HTTP byte range from the
##   run's .idx: UGRD + VGRD at 10 m and TMP at 2 m (GRIB2 template 5.3,
##   Grib2Decoder). The run is the latest one at or before the asked time
##   (never one not out yet), the forecast hour the nearest 3-hourly step.
##   Streamlines (GlobeWindField) and the colour layers are built on a worker.
##
## Images are cached under user://globe_cache/{clouds,rain}/<stamp>.png and
## decoded on a WorkerThreadPool task; textures are made on the main thread.
## Everything is a function of a UNIX time the caller gives (the sim clock
## in-game), so the layers follow the clock both ways.

signal clouds_ready(info: Dictionary)   # {tex, unix, label} or {tex: null, reason}
signal rain_ready(info: Dictionary)
signal wind_ready(info: Dictionary)    # {u, v, t fields, lines, temp_img, power_img, label} or {reason}

const NOWCOAST_WMS := "https://nowcoast.noaa.gov/geoserver/satellite/ows"
const CLOUD_LAYER := "global_longwave_imagery_mosaic"
const GIBS_WMS := "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"
const RAIN_LAYER := "IMERG_Precipitation_Rate_30min"
const DAILY_LAYER := "MODIS_Terra_CorrectedReflectance_TrueColor"
const CLOUD_W := 4096
const CLOUD_H := 2048
const RAIN_W := 2048
const RAIN_H := 1024
const RAIN_SLOT_S := 1800
## IMERG early run latency: a slot this recent is not served yet.
const RAIN_LATENCY_H := 5.0
const MAX_STEPS := 8
## A cloud frame is used only within this many hours of the asked time.
const CLOUD_MAX_GAP_H := 1.5
const DAILY_LAG_DAYS := 1
const CAPS_TTL_S := 600.0
const CACHE := "user://globe_cache"
const GFS_BUCKET := "https://noaa-gfs-bdp-pds.s3.amazonaws.com"
## 2021-01-01 00:00 UTC: the bucket's runs start about here.
const GFS_EARLIEST := 1609459200.0
## IMERG's record starts in 1998; MODIS Terra a little later, in 2000.
const RAIN_EARLIEST := 883612800.0
const MODIS_EARLIEST := 949449600.0
const GFS_LATENCY_H := 4.5
const GFS_MAX_FHOUR := 384
const GFS_VARS := {"u": "UGRD:10 m above ground", "v": "VGRD:10 m above ground", "t": "TMP:2 m above ground"}
const WIND_CREDIT := "Wind, temperature: NOAA GFS (AWS Open Data)"
const WIND_SHELL_R := 1.0025

const CLOUD_CREDIT := "Clouds: NOAA nowCOAST global infrared mosaic"
const RAIN_CREDIT := "Rain: NASA GPM IMERG (GIBS)"
const DAILY_CREDIT := "Satellite of the day: NASA MODIS Terra (GIBS)"

var _http: HTTPRequest
var _queue: Array = []        # jobs {kind, url, path, ...}
var _busy := false
var _tasks: Array[int] = []
var _cloud_times := PackedFloat64Array()
var _caps_at := -1e9
var _want_cloud := -1.0
var _want_rain := -1.0
var _last := {"clouds": "", "rain": "", "wind": ""}
var _gfs_parts := {}     # var -> bytes for the run being fetched
var _gfs_key := ""


# --- Pure helpers (selftested) ---------------------------------------------

static func unix_from_jd(jd: float) -> float:
	return (jd - 2440587.5) * 86400.0


static func iso(unix_s: float) -> String:
	return Time.get_datetime_string_from_unix_time(int(floorf(unix_s))) + "Z"


static func stamp(unix_s: float) -> String:
	return iso(unix_s).replace(":", "").replace("-", "")


static func date_of(unix_s: float) -> String:
	return Time.get_date_string_from_unix_time(int(floorf(unix_s)))


## "2026-11-05T19:00:00.000Z" -> UNIX seconds (NAN if unreadable).
static func parse_iso(s: String) -> float:
	var t := s.strip_edges().trim_suffix("Z")
	var dot := t.find(".")
	if dot >= 0:
		t = t.substr(0, dot)
	if t.length() < 19:
		return NAN
	return float(Time.get_unix_time_from_datetime_string(t))


## The time values a WMS 1.3.0 capabilities document lists for one layer.
static func layer_times(caps_xml: String, layer: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var i := caps_xml.find("<Name>%s</Name>" % layer)
	if i < 0:
		return out
	var d := caps_xml.find("<Dimension", i)
	var next_layer := caps_xml.find("<Layer", i + 1)
	if d < 0 or (next_layer >= 0 and d > next_layer):
		return out
	var open_end := caps_xml.find(">", d)
	var close := caps_xml.find("</Dimension>", open_end)
	if open_end < 0 or close < 0:
		return out
	for part in caps_xml.substr(open_end + 1, close - open_end - 1).split(","):
		var u := parse_iso(part)
		if not is_nan(u):
			out.append(u)
	out.sort()
	return out


## Index of the frame nearest `t` within max_gap_h hours, else -1.
static func nearest_frame(times: PackedFloat64Array, t: float, max_gap_h: float) -> int:
	var best := -1
	var gap := max_gap_h * 3600.0
	for i in times.size():
		var g := absf(times[i] - t)
		if g <= gap:
			gap = g
			best = i
	return best


## The rain slot for a time: down to the half hour, never newer than
## now - RAIN_LATENCY_H.
static func rain_slot(t: float, now: float) -> float:
	var latest := now - RAIN_LATENCY_H * 3600.0
	var u := minf(t, latest)
	return floorf(u / float(RAIN_SLOT_S)) * float(RAIN_SLOT_S)


## The daily image's date for a time: that day, but never later than
## yesterday (MODIS lands about a day late).
static func daily_date(t: float, now: float) -> String:
	return date_of(minf(t, now - float(DAILY_LAG_DAYS) * 86400.0))


## The GFS run + forecast hour for a time: the newest run at or before `t`
## that is already out at `now`, and the 3-hourly step nearest t. {} before
## the archive starts.
static func gfs_choice(t: float, now: float) -> Dictionary:
	if t < GFS_EARLIEST:
		return {}
	var six := 6.0 * 3600.0
	var latest := floorf((now - GFS_LATENCY_H * 3600.0) / six) * six
	var cycle := minf(latest, floorf(t / six) * six)
	var fh := clampi(roundi((t - cycle) / 10800.0) * 3, 0, GFS_MAX_FHOUR)
	return {"cycle": cycle, "fhour": fh}


## Why a layer has no picture at `t`, or "" when it might. `now` is the
## computer's clock (UNIX s). Clouds are only the last few hours; the
## archives start in 1998 (rain), 2000 (MODIS) and 2021 (GFS).
static func layer_gap(kind: String, t: float, now: float) -> String:
	if kind == "clouds" and absf(t - now) > 6.0 * 3600.0:
		return "Clouds: live clouds cover only the last few hours"
	if kind == "wind" and t < GFS_EARLIEST:
		return "Wind: no image before 2021"
	if kind == "rain" and t < RAIN_EARLIEST:
		return "Rain: no image before 1998"
	if kind == "sat" and t < MODIS_EARLIEST:
		return "Satellite: no image before 2000"
	return ""


static func gfs_url(cycle: float, fhour: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(cycle))
	return "%s/gfs.%04d%02d%02d/%02d/atmos/gfs.t%02dz.pgrb2.1p00.f%03d" % [GFS_BUCKET,
		d.year, d.month, d.day, d.hour, d.hour, fhour]


## Byte ranges of named fields in a GFS .idx ("n:offset:d=..:VAR:LEVEL:..."):
## key -> Vector2i(start, end_exclusive), end -1 for the last record.
static func idx_ranges(idx: String, wanted: Dictionary) -> Dictionary:
	var lines := idx.split("\n", false)
	var out := {}
	for i in lines.size():
		var parts := lines[i].split(":")
		if parts.size() < 5:
			continue
		var tag := "%s:%s" % [parts[3], parts[4]]
		for k in wanted:
			if str(wanted[k]) == tag and not out.has(k):
				var end := -1
				if i + 1 < lines.size():
					var nx := lines[i + 1].split(":")
					if nx.size() > 1:
						end = int(nx[1])
				out[k] = Vector2i(int(parts[1]), end)
	return out


static func gfs_label(cycle: float, fhour: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(cycle))
	return "GFS %04d-%02d-%02d %02dz +%d h" % [d.year, d.month, d.day, d.hour, fhour]


## A GlobeTileFetcher layer for the satellite image of `date`.
static func daily_layer_def(date: String) -> Dictionary:
	return {
		"url": "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/%s/default/%s/GoogleMapsCompatible_Level9/%%d/%%d/%%d.jpg" % [DAILY_LAYER, date],
		"ext": "jpg",
		"max_zoom": 9,
		"blank_check": false,
		"attribution": "%s, %s" % [DAILY_CREDIT, date],
	}


static func cloud_url(unix_s: float) -> String:
	return "%s?service=WMS&version=1.3.0&request=GetMap&layers=%s&styles=&crs=EPSG:4326&bbox=-90,-180,90,180&width=%d&height=%d&format=image/png&transparent=true&time=%s" % [
		NOWCOAST_WMS, CLOUD_LAYER, CLOUD_W, CLOUD_H, iso(unix_s)]


static func rain_url(unix_s: float) -> String:
	return "%s?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=%s&CRS=EPSG:4326&BBOX=-90,-180,90,180&WIDTH=%d&HEIGHT=%d&FORMAT=image/png&TRANSPARENT=true&TIME=%s" % [
		GIBS_WMS, RAIN_LAYER, RAIN_W, RAIN_H, iso(unix_s)]


## True when an image has (almost) no opaque pixel: no data for that time.
static func is_empty_image(img: Image) -> bool:
	if img == null or img.is_empty():
		return true
	var step := maxi(1, img.get_width() / 128)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			if img.get_pixel(x, y).a > 0.05:
				return false
	return true


# --- Service ------------------------------------------------------------------

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	_http.use_threads = true
	_http.download_chunk_size = 262144
	add_child(_http)
	_http.request_completed.connect(_on_http_done)


func _exit_tree() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()


func _process(_dt: float) -> void:
	for i in range(_tasks.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_tasks[i])
			_tasks.remove_at(i)


## The cloud frame nearest `t` (UNIX s). Emits clouds_ready once ready, or
## with tex null and a reason when no live frame is near that time. True
## when something new is on its way (the caller may say "loading").
## Forget what was last asked for, so turning a layer off and on again asks
## (and answers) afresh rather than being taken as a repeat.
func forget(kind: String) -> void:
	if _last.has(kind):
		_last[kind] = ""


func request_clouds(t: float) -> bool:
	_want_cloud = t
	var now := Time.get_unix_time_from_system()
	if now - _caps_at > CAPS_TTL_S or _cloud_times.is_empty():
		_caps_at = now
		_enqueue({"kind": "caps", "url": "%s?service=WMS&request=GetCapabilities&version=1.3.0" % NOWCOAST_WMS})
		return true
	return _pick_cloud_frame()


func cloud_times() -> PackedFloat64Array:
	return _cloud_times


func _pick_cloud_frame() -> bool:
	var t := _want_cloud
	var i := nearest_frame(_cloud_times, t, CLOUD_MAX_GAP_H)
	if i < 0:
		var reason := "Live clouds cover only the last few hours"
		if not _cloud_times.is_empty():
			reason += " (%s to %s UTC)" % [iso(_cloud_times[0]).substr(11, 5), iso(_cloud_times[-1]).substr(11, 5)]
		_last.clouds = ""
		clouds_ready.emit({"tex": null, "reason": reason})
		return false
	var u := _cloud_times[i]
	var key := stamp(u)
	if _last.clouds == key:
		return false
	_last.clouds = key
	_load_or_fetch({"kind": "clouds", "unix": u, "url": cloud_url(u),
		"path": "%s/clouds/%s.png" % [CACHE, key]})
	return true


## The rain frame for `t` (UNIX s). True when a new frame is on its way.
func request_rain(t: float) -> bool:
	_want_rain = t
	var u := rain_slot(t, Time.get_unix_time_from_system())
	var key := stamp(u)
	if _last.rain == key:
		return false
	_last.rain = key
	_load_or_fetch({"kind": "rain", "unix": u, "url": rain_url(u),
		"path": "%s/rain/%s.png" % [CACHE, key], "steps": 0})
	return true


## Wind + temperature for `t` (UNIX s). True when a new run is on its way.
func request_wind(t: float) -> bool:
	var ch := gfs_choice(t, Time.get_unix_time_from_system())
	if ch.is_empty():
		_last.wind = ""
		wind_ready.emit({"reason": "Wind: the GFS archive starts in 2021"})
		return false
	return _start_gfs(float(ch.cycle), int(ch.fhour), 0)


func _start_gfs(cycle: float, fhour: int, tries: int) -> bool:
	var key := "%s_f%03d" % [stamp(cycle), fhour]
	if _last.wind == key:
		return false
	_last.wind = key
	_gfs_key = key
	_gfs_parts = {}
	var all_cached := true
	for k in GFS_VARS:
		var path := "%s/gfs/%s_%s.grb2" % [CACHE, key, k]
		if FileAccess.file_exists(path):
			_gfs_parts[k] = FileAccess.get_file_as_bytes(path)
		else:
			all_cached = false
	if all_cached:
		_decode_gfs(key, cycle, fhour)
		return true
	_enqueue({"kind": "gfs_idx", "url": gfs_url(cycle, fhour) + ".idx", "cycle": cycle,
		"fhour": fhour, "tries": tries, "key": key})
	return true


func _decode_gfs(key: String, cycle: float, fhour: int) -> void:
	var parts := _gfs_parts.duplicate()
	var tid := WorkerThreadPool.add_task(func() -> void:
		var fields := {}
		var err := ""
		for k in GFS_VARS:
			var msg := Grib2Decoder.decode(parts[k])
			if not bool(msg.ok):
				err = "%s: %s" % [k, str(msg.error)]
				break
			fields[k] = Grib2Decoder.to_field(msg)
		var info := {"key": key}
		if err.is_empty():
			var lines := GlobeWindField.trace(fields.u, fields.v)
			info = {"key": key, "u": fields.u, "v": fields.v, "t": fields.t,
				"lines": GlobeWindField.line_arrays(lines, WIND_SHELL_R, float(GlobeWindField.DEFAULTS.step_deg)),
				"line_count": lines.size(),
				"temp_img": GlobeWindField.overlay_image(func(la: float, lo: float) -> float:
					return Grib2Decoder.sample(fields.t, la, lo) - 273.15, 100.0, 50.0),
				"power_img": GlobeWindField.overlay_image(func(la: float, lo: float) -> float:
					return GlobeWindField.power_density(GlobeWindField.speed_at(fields.u, fields.v, la, lo)), 1500.0, 0.0),
				"cycle": cycle, "fhour": fhour, "label": gfs_label(cycle, fhour)}
		else:
			info["reason"] = "Wind unreadable (%s)" % err
		_finish_gfs.call_deferred(info))
	_tasks.append(tid)


func _finish_gfs(info: Dictionary) -> void:
	if str(info.get("key", "")) != _gfs_key:
		return   # a newer request won
	if info.has("reason"):
		_last.wind = ""
	wind_ready.emit(info)


func _load_or_fetch(job: Dictionary) -> void:
	if FileAccess.file_exists(str(job.path)):
		_decode(job, FileAccess.get_file_as_bytes(str(job.path)), false)
	else:
		_enqueue(job)


func _enqueue(job: Dictionary) -> void:
	# A newer request of the same kind replaces a queued one.
	for i in range(_queue.size() - 1, -1, -1):
		if str(_queue[i].kind) == str(job.kind):
			_queue.remove_at(i)
	_queue.append(job)
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	if GlobeTileFetcher.offline_for_test:
		_fail(job, "offline")
		_pump()
		return
	_http.set_meta("job", job)
	var headers := PackedStringArray(job.get("headers", []))
	if _http.request(str(job.url), headers) != OK:
		_fail(job, "request failed")
		_pump()
		return
	_busy = true


func _on_http_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	var job: Dictionary = _http.get_meta("job", {})
	var kind := str(job.get("kind", ""))
	if kind == "gfs_idx" and (code == 404 or code == 403) and int(job.tries) < 3 \
			and str(job.key) == _gfs_key:
		# This run is not on the bucket yet: the one 6 h earlier, same valid time.
		_last.wind = ""
		_start_gfs(float(job.cycle) - 21600.0, mini(int(job.fhour) + 6, GFS_MAX_FHOUR), int(job.tries) + 1)
	elif result != HTTPRequest.RESULT_SUCCESS or (code != 200 and code != 206) or body.is_empty():
		_fail(job, "HTTP %d" % code)
	elif kind == "gfs_idx":
		_on_gfs_idx(job, body.get_string_from_utf8())
	elif kind.begins_with("gfs_var:"):
		_on_gfs_var(job, body)
	elif kind == "caps":
		_cloud_times = layer_times(body.get_string_from_utf8(), CLOUD_LAYER)
		_pick_cloud_frame()
	else:
		_decode(job, body, true)
	_pump()


func _on_gfs_idx(job: Dictionary, idx: String) -> void:
	if str(job.key) != _gfs_key:
		return
	var r := idx_ranges(idx, GFS_VARS)
	if r.size() != GFS_VARS.size():
		_fail(job, "fields missing from the run's index")
		return
	for k in GFS_VARS:
		if _gfs_parts.has(k):
			continue
		var rg: Vector2i = r[k]
		var hdr := "Range: bytes=%d-%s" % [rg.x, "" if rg.y < 0 else str(rg.y - 1)]
		_enqueue({"kind": "gfs_var:" + k, "var": k, "key": job.key, "cycle": job.cycle,
			"fhour": job.fhour, "url": gfs_url(float(job.cycle), int(job.fhour)), "headers": [hdr]})


func _on_gfs_var(job: Dictionary, body: PackedByteArray) -> void:
	if str(job.key) != _gfs_key:
		return
	var path := "%s/gfs/%s_%s.grb2" % [CACHE, str(job.key), str(job.var)]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(body)
		f.close()
	_gfs_parts[str(job.var)] = body
	if _gfs_parts.size() == GFS_VARS.size():
		_decode_gfs(str(job.key), float(job.cycle), int(job.fhour))


func _fail(job: Dictionary, why: String) -> void:
	var k := str(job.get("kind", ""))
	if k.begins_with("gfs"):
		_last.wind = ""
		wind_ready.emit({"reason": "Wind unavailable (%s)" % why})
		return
	if k == "clouds" or k == "caps":
		_last.clouds = ""
		clouds_ready.emit({"tex": null, "reason": "Clouds unavailable (%s)" % why})
	elif k == "rain":
		_last.rain = ""
		rain_ready.emit({"tex": null, "reason": "Rain unavailable (%s)" % why})


## PNG -> mipmapped Image on a worker; the texture on the main thread.
func _decode(job: Dictionary, bytes: PackedByteArray, save: bool) -> void:
	var tid := WorkerThreadPool.add_task(func() -> void:
		var img := Image.new()
		var ok := img.load_png_from_buffer(bytes) == OK and not img.is_empty()
		var empty := not ok or is_empty_image(img)
		if ok and not empty:
			img.generate_mipmaps()
		_finish.call_deferred(job, img, ok, empty, bytes if save else PackedByteArray()))
	_tasks.append(tid)


func _finish(job: Dictionary, img: Image, ok: bool, empty: bool, save_bytes: PackedByteArray) -> void:
	var kind := str(job.kind)
	if empty:
		if kind == "rain" and int(job.get("steps", 0)) < MAX_STEPS:
			# Nothing for that slot yet: one slot back.
			var u := float(job.unix) - float(RAIN_SLOT_S)
			var key := stamp(u)
			_last.rain = key
			_load_or_fetch({"kind": "rain", "unix": u, "url": rain_url(u),
				"path": "%s/rain/%s.png" % [CACHE, key], "steps": int(job.get("steps", 0)) + 1})
			return
		_fail(job, "no data" if ok else "unreadable image")
		return
	if not save_bytes.is_empty():
		var path := str(job.path)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(save_bytes)
			f.close()
	var tex := ImageTexture.create_from_image(img)
	var info := {"tex": tex, "unix": float(job.unix), "label": iso(float(job.unix)).substr(0, 16).replace("T", " ") + " UTC"}
	if kind == "clouds":
		clouds_ready.emit(info)
	else:
		rain_ready.emit(info)
