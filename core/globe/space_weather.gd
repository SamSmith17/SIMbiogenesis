class_name SpaceWeatherService
extends Node

## Real space weather for the aurora (autoload "SpaceWeather"), as a function
## of time like the rest of the weather:
## - Kp, the 3-hourly planetary geomagnetic index:
##   - the last week observed + 3 days forecast from NOAA SWPC
##     (services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json,
##     public domain), refreshed every 30 min;
##   - anything older from GFZ Potsdam's Kp archive (kp.gfz.de, since 1932,
##     CC BY 4.0), one month per request, cached in user://globe_cache/kp/;
##   - beyond the forecast, a quiet Kp of ASSUMED_KP, said as such.
## - The OVATION aurora nowcast (services.swpc.noaa.gov/json/
##   ovation_aurora_latest.json: probability of visible aurora on a 1° grid,
##   ~30 min ahead), refreshed every 10 min, used within OVATION_WINDOW_S of
##   its forecast time.
## Everything answers at once from what is in memory and asks for what is
## missing; `updated` fires when new data lands.

signal updated

const SWPC_KP := "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json"
const GFZ_KP := "https://kp.gfz.de/app/json/?start=%s&end=%s&index=Kp"
const OVATION := "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"
const CACHE_DIR := "user://globe_cache/kp"
const SWPC_REFRESH_S := 1800.0
const OVATION_REFRESH_S := 600.0
const OVATION_WINDOW_S := 5400.0
const ASSUMED_KP := 2.0
const STEP_S := 10800.0
const ATTRIBUTION_KP := "Kp: NOAA SWPC, GFZ Potsdam (CC BY 4.0)"
const ATTRIBUTION_OVATION := "Aurora: NOAA SWPC OVATION"

var offline_for_test := false
## [[unix start of the 3 h interval, kp, source]] from SWPC.
var _swpc: Array = []
var _swpc_at := -1e18
## "YYYY-MM" -> [[unix, kp]] from GFZ.
var _months := {}
var _pending := {}
var _ovation: Dictionary = {}
var _ovation_at := -1e18
var _http := {}


## [[unix, kp, source]] from the SWPC product (rows of dicts).
static func parse_swpc(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		if not r is Dictionary:
			continue
		var t := str(r.get("time_tag", ""))
		if t.is_empty() or r.get("kp") == null:
			continue
		out.append([float(Time.get_unix_time_from_datetime_string(t.trim_suffix("Z"))), float(r.kp),
			str(r.get("observed", "observed"))])
	return out


## [[unix, kp]] from a GFZ reply.
static func parse_gfz(d: Dictionary) -> Array:
	var out: Array = []
	var kp: Array = d.get("Kp", [])
	var dt: Array = d.get("datetime", [])
	for i in mini(kp.size(), dt.size()):
		out.append([float(Time.get_unix_time_from_datetime_string(str(dt[i]).trim_suffix("Z"))), float(kp[i])])
	return out


## The OVATION grid as an L8 image (360 x 181, x = longitude east 0..359,
## y = 90 - latitude, value = probability %) with its times.
static func parse_ovation(d: Dictionary) -> Dictionary:
	var img := Image.create(360, 181, false, Image.FORMAT_L8)
	var hi := 0.0
	for c in (d.get("coordinates", []) as Array):
		var lon := int(c[0]) % 360
		var lat := int(c[1])
		var v := clampf(float(c[2]), 0.0, 100.0)
		hi = maxf(hi, v)
		img.set_pixel(lon, clampi(90 - lat, 0, 180), Color(v / 100.0, 0, 0))
	return {"image": img, "max": hi,
		"obs": float(Time.get_unix_time_from_datetime_string(str(d.get("Observation Time", "")).trim_suffix("Z"))),
		"forecast": float(Time.get_unix_time_from_datetime_string(str(d.get("Forecast Time", "")).trim_suffix("Z")))}


## The Kp of the 3 h interval holding `unix` from a sorted series, or NAN.
static func lookup(series: Array, unix: float) -> float:
	var best := NAN
	for r in series:
		if float(r[0]) <= unix and unix < float(r[0]) + STEP_S:
			best = float(r[1])
	return best


static func month_key(unix: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix))
	return "%04d-%02d" % [d.year, d.month]


## {kp, source ("observed" | "forecast" | "archive" | "assumed"), loading}.
func kp_at(unix: float) -> Dictionary:
	var now := Time.get_unix_time_from_system()
	if now - _swpc_at > SWPC_REFRESH_S:
		_fetch("swpc", SWPC_KP)
	for r in _swpc:
		if float(r[0]) <= unix and unix < float(r[0]) + STEP_S:
			return {"kp": float(r[1]), "source": "forecast" if str(r[2]) != "observed" else "observed"}
	if unix > now:
		return {"kp": ASSUMED_KP, "source": "assumed", "loading": _swpc.is_empty() and not offline_for_test}
	var mk := month_key(unix)
	if not _months.has(mk):
		_load_month(mk, unix)
	if _months.has(mk):
		var v := lookup(_months[mk], unix)
		if not is_nan(v):
			return {"kp": v, "source": "archive"}
	return {"kp": ASSUMED_KP, "source": "assumed", "loading": _pending.has(mk)}


## The OVATION nowcast if `unix` is close to it: {image, max, obs, forecast}
## or {}.
func ovation_for(unix: float) -> Dictionary:
	if Time.get_unix_time_from_system() - _ovation_at > OVATION_REFRESH_S:
		_fetch("ovation", OVATION)
	if _ovation.is_empty():
		return {}
	if unix < float(_ovation.obs) - OVATION_WINDOW_S or unix > float(_ovation.forecast) + OVATION_WINDOW_S:
		return {}
	return _ovation


func _load_month(mk: String, unix: float) -> void:
	var p := "%s/%s.json" % [CACHE_DIR, mk]
	var this_month := month_key(Time.get_unix_time_from_system()) == mk
	if FileAccess.file_exists(p):
		var fresh := Time.get_unix_time_from_system() - FileAccess.get_modified_time(p) < 86400.0
		if not this_month or fresh:
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if d is Dictionary:
				_months[mk] = parse_gfz(d)
				return
	if offline_for_test or _pending.has(mk):
		return
	var d0 := Time.get_datetime_dict_from_unix_time(int(unix))
	var y := int(d0.year)
	var m := int(d0.month)
	var ny := y + (1 if m == 12 else 0)
	var nm := 1 if m == 12 else m + 1
	var start := "%04d-%02d-01T00:00:00Z" % [y, m]
	var end_unix := Time.get_unix_time_from_datetime_string("%04d-%02d-01T00:00:00" % [ny, nm]) - 1
	var end := Time.get_datetime_string_from_unix_time(end_unix) + "Z"
	_pending[mk] = true
	_fetch("gfz_" + mk, GFZ_KP % [start, end])


func _fetch(kind: String, url: String) -> void:
	if offline_for_test or _http.has(kind):
		return
	if kind == "swpc":
		_swpc_at = Time.get_unix_time_from_system()
	elif kind == "ovation":
		_ovation_at = Time.get_unix_time_from_system()
	var h := HTTPRequest.new()
	h.timeout = 40.0
	add_child(h)
	_http[kind] = h
	h.request_completed.connect(func(result: int, code: int, _hd: PackedStringArray, body: PackedByteArray) -> void:
		_http.erase(kind)
		h.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			_pending.erase(kind.trim_prefix("gfz_"))
			return
		_on_body(kind, body))
	if h.request(url, PackedStringArray(["User-Agent: SIMbiogenesis"])) != OK:
		_http.erase(kind)
		h.queue_free()


func _on_body(kind: String, body: PackedByteArray) -> void:
	var txt := body.get_string_from_utf8()
	var d: Variant = JSON.parse_string(txt)
	if kind == "swpc" and d is Array:
		_swpc = parse_swpc(d)
	elif kind == "ovation" and d is Dictionary:
		_ovation = parse_ovation(d)
		_ovation["texture"] = ImageTexture.create_from_image(_ovation.image)
	elif kind.begins_with("gfz_") and d is Dictionary:
		var mk := kind.trim_prefix("gfz_")
		_pending.erase(mk)
		_months[mk] = parse_gfz(d)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
		var f := FileAccess.open("%s/%s.json" % [CACHE_DIR, mk], FileAccess.WRITE)
		if f != null:
			f.store_string(txt)
	else:
		return
	updated.emit()
