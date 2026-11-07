class_name GlobeClimate
extends Node

## Long-term averages at a point for the globe's point card: NASA POWER's
## climatology API (power.larc.nasa.gov, keyless, a 20-year average on a
## ~0.5° grid): wind at 10 m and 50 m, air temperature at 2 m, rain and
## cloud cover, by month and for the year. Cached per 0.5° under
## user://globe_cache/power/. The card shows the lines for the layers that
## are on (`lines_for`), beside what GFS / IMERG say at the globe's time.

signal point_ready(key: String, info: Dictionary)

const API := "https://power.larc.nasa.gov/api/temporal/climatology/point?parameters=WS10M,WS50M,T2M,PRECTOTCORR,CLOUD_AMT&community=RE&longitude=%.3f&latitude=%.3f&format=JSON"
const CACHE_DIR := "user://globe_cache/power"
const ATTRIBUTION := "Averages: NASA POWER (LaRC)"
const MONTHS := ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
## Air density at sea level, kg/m³ (ISA), and the open-land roughness the
## GFS wind-power layer uses, m.
const RHO := 1.225
const Z0 := 0.03

var offline_for_test := false
var _http: HTTPRequest
var _queue: Array = []
var _busy_key := ""
var _mem := {}


## The grid cell a point falls in (POWER is ~0.5°).
static func key_of(lat: float, lon: float) -> String:
	return "%.1f,%.1f" % [snappedf(lat, 0.5), snappedf(lon, 0.5)]


static func cache_path(key: String) -> String:
	return "%s/%s.json" % [CACHE_DIR, key.replace(",", "_")]


## {ok, ws10, ws50, t2m, rain (mm/day), cloud (%)} each {ann, monthly[12]}.
## POWER marks a missing value -999.
static func parse(d: Dictionary) -> Dictionary:
	var p: Dictionary = ((d.get("properties", {}) as Dictionary).get("parameter", {}))
	var out := {"ok": not p.is_empty()}
	for pair in [["ws10", "WS10M"], ["ws50", "WS50M"], ["t2m", "T2M"], ["rain", "PRECTOTCORR"], ["cloud", "CLOUD_AMT"]]:
		var src: Dictionary = p.get(pair[1], {})
		if src.is_empty():
			continue
		var m := PackedFloat64Array()
		for k in MONTHS:
			var v := float(src.get(k, -999.0))
			m.append(NAN if v <= -998.0 else v)
		var ann := float(src.get("ANN", -999.0))
		out[pair[0]] = {"ann": NAN if ann <= -998.0 else ann, "monthly": m}
	return out


## Mean wind power at 100 m from a mean speed at 50 m: the log law to 100 m,
## then a Rayleigh spread (mean of v³ = 6/π × mean³). W/m².
static func power_100m(v50: float) -> float:
	var v100 := v50 * log(100.0 / Z0) / log(50.0 / Z0)
	return 0.5 * RHO * (6.0 / PI) * v100 * v100 * v100


## [index of the lowest month, index of the highest] (NAN-safe).
static func extremes(m: PackedFloat64Array) -> Array:
	var lo := -1
	var hi := -1
	for i in m.size():
		if is_nan(m[i]):
			continue
		if lo < 0 or m[i] < m[lo]:
			lo = i
		if hi < 0 or m[i] > m[hi]:
			hi = i
	return [lo, hi]


static func wind_line(info: Dictionary) -> String:
	if not info.has("ws50"):
		return ""
	var v50 := float(info.ws50.ann)
	var v10 := float(info.ws10.ann) if info.has("ws10") else NAN
	var e := extremes(info.ws50.monthly)
	var s := "Average wind %.1f m/s at 50 m" % v50
	if not is_nan(v10):
		s += ", %.1f at 10 m" % v10
	s += " · ~%d W/m² at 100 m" % roundi(power_100m(v50))
	if e[1] >= 0:
		s += " · windiest %s" % MONTH_NAMES[e[1]]
	return s


static func temp_line(info: Dictionary) -> String:
	if not info.has("t2m"):
		return ""
	var m: PackedFloat64Array = info.t2m.monthly
	var e := extremes(m)
	var s := "Average %.1f °C" % float(info.t2m.ann)
	if e[0] >= 0:
		s += " · %s %.0f °C, %s %.0f °C" % [MONTH_NAMES[e[0]], m[e[0]], MONTH_NAMES[e[1]], m[e[1]]]
	return s


static func rain_line(info: Dictionary) -> String:
	if not info.has("rain"):
		return ""
	var r := float(info.rain.ann)
	var e := extremes(info.rain.monthly)
	var s := "Average rain %.1f mm/day (%s mm/yr)" % [r, UiText.thousands(roundi(r * 365.25))]
	if e[1] >= 0:
		s += " · wettest %s, driest %s" % [MONTH_NAMES[e[1]], MONTH_NAMES[e[0]]]
	return s


static func cloud_line(info: Dictionary) -> String:
	if not info.has("cloud"):
		return ""
	var e := extremes(info.cloud.monthly)
	var s := "Average cloud cover %d %%" % roundi(float(info.cloud.ann))
	if e[0] >= 0:
		s += " · clearest %s" % MONTH_NAMES[e[0]]
	return s


func request_point(lat: float, lon: float) -> String:
	var key := key_of(lat, lon)
	if _mem.has(key):
		point_ready.emit.call_deferred(key, _mem[key])
		return key
	var p := cache_path(key)
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			_mem[key] = parse(d)
			point_ready.emit.call_deferred(key, _mem[key])
			return key
	if offline_for_test:
		point_ready.emit.call_deferred(key, {"ok": false, "error": "offline"})
		return key
	for q in _queue:
		if q[0] == key:
			return key
	_queue.append([key, snappedf(lat, 0.5), snappedf(lon, 0.5)])
	_next()
	return key


func _next() -> void:
	if not _busy_key.is_empty() or _queue.is_empty():
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = 45.0
		add_child(_http)
		_http.request_completed.connect(_on_done)
	var q: Array = _queue.pop_front()
	_busy_key = q[0]
	var err := _http.request(API % [float(q[2]), float(q[1])], PackedStringArray(["User-Agent: SIMbiogenesis"]))
	if err != OK:
		_finish({"ok": false, "error": "request failed (%d)" % err})


func _on_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish({"ok": false, "error": "NASA POWER did not answer (%d)" % code})
		return
	var txt := body.get_string_from_utf8()
	var d: Variant = JSON.parse_string(txt)
	if not d is Dictionary:
		_finish({"ok": false, "error": "unreadable reply"})
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var f := FileAccess.open(cache_path(_busy_key), FileAccess.WRITE)
	if f != null:
		f.store_string(txt)
	_finish(parse(d))


func _finish(info: Dictionary) -> void:
	var key := _busy_key
	_busy_key = ""
	if not info.has("error"):
		_mem[key] = info
	point_ready.emit(key, info)
	_next()
