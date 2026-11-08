class_name GlobeSolarAtlas
extends Node

## Global Solar Atlas 2.0 (Solargis for the World Bank / ESMAP, CC BY 4.0) on
## the globe: a map layer and exact numbers for one point.
##
## - The LAYER is core/globe/data/gsa_pvout.png, built offline by
##   tools/globe/solar_atlas_build.py from the World PVOUT yearly average
##   (kWh/kWp per day of a typical PV system), block-averaged to ~5 km:
##   equirect, north up, lon -180 at the left, R = value / MAX_PVOUT,
##   G = 255 where the atlas has data (land, 60 S to 65 N).
## - A POINT asks the atlas's public API (api.globalsolaratlas.info/data/lta,
##   the one its own web map uses; keyless) for the long-term averages there:
##   GHI, DNI, diffuse, PV output, the best fixed tilt, air temperature and
##   the monthly PV output. Replies are cached per 0.001° under
##   user://globe_cache/gsa/. Over the sea or the poles the atlas has no
##   solar numbers and the reply says so.

signal point_ready(key: String, info: Dictionary)

const LAYER_PATH := "res://core/globe/data/gsa_pvout.png"
const MAX_PVOUT := 7.0
const API := "https://api.globalsolaratlas.info/data/lta?loc=%.4f,%.4f"
const CACHE_DIR := "user://globe_cache/gsa"
const DAYS_PER_YEAR := 365.0
const ATTRIBUTION := "Solar atlas: Global Solar Atlas 2.0 (Solargis, World Bank Group / ESMAP, CC BY 4.0)"
## PV output, kWh/kWp/day: six colours, edges every 0.75 from 2.5 (the
## atlas runs ~2 to ~6.4; poor below 2.5, excellent above 5); the smooth ramp
## puts colour i at RAMP_LO + i * RAMP_STEP.
const COLORS := [Color("#3b3f8f"), Color("#3c7fb1"), Color("#56b2a0"), Color("#c3d66a"),
	Color("#f2a63d"), Color("#d9473a")]
const STEPS := [2.5, 3.25, 4.0, 4.75, 5.5]
const RAMP_LO := 2.0
const RAMP_STEP := 0.75
## The camera distance (globe radii) below which the layer starts to fade:
## ~5 km cells hold up closer than the 1° zone grid's 0.03.
const FADE_FAR := 0.09
const FADE_NEAR := 0.012

static var _layer_tex: Texture2D
static var _layer_img: Image

var offline_for_test := false
var _http: HTTPRequest
var _queue: Array = []        # [key, lat, lon]
var _busy_key := ""
var _mem := {}                # key -> info


## The layer texture, loaded once (null when the build was never run).
static func layer() -> Texture2D:
	if _layer_tex == null and ResourceLoader.exists(LAYER_PATH):
		_layer_tex = load(LAYER_PATH) as Texture2D
	return _layer_tex


## PV output at a point from the layer, kWh/kWp/day (NAN where none).
static func layer_value(lat: float, lon: float) -> float:
	if _layer_img == null:
		var t := layer()
		if t == null:
			return NAN
		_layer_img = t.get_image()
		if _layer_img == null:
			return NAN
		if _layer_img.is_compressed():
			_layer_img.decompress()
	return sample(_layer_img, lat, lon)


## Nearest-pixel read of an equirect atlas image (pure; tests feed images).
static func sample(img: Image, lat: float, lon: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var x := clampi(int(floorf((wrapf(lon, -180.0, 180.0) + 180.0) / 360.0 * w)), 0, w - 1)
	var y := clampi(int(floorf((90.0 - lat) / 180.0 * h)), 0, h - 1)
	var c := img.get_pixel(x, y)
	if c.g < 0.5:
		return NAN
	return c.r * MAX_PVOUT


static func key_of(lat: float, lon: float) -> String:
	return "%.3f,%.3f" % [lat, lon]


## The API reply as the numbers the globe shows. Yearly sums come back in
## kWh/m² (or kWh/kWp) per year; per day = / 365. `ok` is false where the
## atlas has no solar data (sea, poles).
static func parse_lta(d: Dictionary) -> Dictionary:
	var a: Dictionary = (d.get("annual", {}) as Dictionary).get("data", {})
	var m: Dictionary = (d.get("monthly", {}) as Dictionary).get("data", {})
	if not a.has("GHI") or not a.has("PVOUT_csi"):
		return {"ok": false, "temp_c": float(a.get("TEMP", NAN))}
	var pv_m := PackedFloat64Array()
	for v in (m.get("PVOUT_csi", []) as Array):
		pv_m.append(float(v))
	return {
		"ok": true,
		"ghi_year": float(a.GHI), "ghi_day": float(a.GHI) / DAYS_PER_YEAR,
		"dni_year": float(a.get("DNI", NAN)), "dni_day": float(a.get("DNI", NAN)) / DAYS_PER_YEAR,
		"dif_year": float(a.get("DIF", NAN)),
		"pvout_year": float(a.PVOUT_csi), "pvout_day": float(a.PVOUT_csi) / DAYS_PER_YEAR,
		"gti_year": float(a.get("GTI_opta", NAN)),
		"tilt_deg": float(a.get("OPTA", NAN)), "temp_c": float(a.get("TEMP", NAN)),
		"pvout_monthly": pv_m,
	}


## One line for the point card.
static func card_text(info: Dictionary) -> String:
	if info.is_empty():
		return ""
	if not bool(info.get("ok", false)):
		return "Solar atlas: no data here (it covers land from 60° S to 65° N)"
	var best := ""
	var pm: PackedFloat64Array = info.get("pvout_monthly", PackedFloat64Array())
	if pm.size() == 12:
		var lo := 0
		var hi := 0
		for i in 12:
			if pm[i] < pm[lo]:
				lo = i
			if pm[i] > pm[hi]:
				hi = i
		var mn := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		best = " · best %s, worst %s" % [mn[hi], mn[lo]]
	return "Solar atlas: 1 kWp makes %.2f kWh/day (%s kWh/yr) · sun %.2f kWh/m²/day · best tilt %d°%s" % [
		float(info.pvout_day), UiText.thousands(roundi(float(info.pvout_year))), float(info.ghi_day),
		roundi(float(info.tilt_deg)), best]


static func cache_path(key: String) -> String:
	return "%s/%s.json" % [CACHE_DIR, key.replace(",", "_")]


## Asks for the numbers at a point; `point_ready` answers (at once from the
## memory or disk cache). Returns the key.
func request_point(lat: float, lon: float) -> String:
	var key := key_of(lat, lon)
	if _mem.has(key):
		point_ready.emit.call_deferred(key, _mem[key])
		return key
	var p := cache_path(key)
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			_mem[key] = parse_lta(d)
			point_ready.emit.call_deferred(key, _mem[key])
			return key
	if offline_for_test:
		point_ready.emit.call_deferred(key, {"ok": false, "error": "offline"})
		return key
	for q in _queue:
		if q[0] == key:
			return key
	_queue.append([key, lat, lon])
	_next()
	return key


func _next() -> void:
	if not _busy_key.is_empty() or _queue.is_empty():
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = 30.0
		add_child(_http)
		_http.request_completed.connect(_on_done)
	var q: Array = _queue.pop_front()
	_busy_key = q[0]
	var err := _http.request(API % [float(q[1]), float(q[2])], PackedStringArray(["User-Agent: SIMbiogenesis"]))
	if err != OK:
		_finish({"ok": false, "error": "request failed (%d)" % err})


func _on_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_finish({"ok": false, "error": "the atlas did not answer (%d)" % code})
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
	_finish(parse_lta(d))


func _finish(info: Dictionary) -> void:
	var key := _busy_key
	_busy_key = ""
	if not info.has("error"):
		_mem[key] = info
	point_ready.emit(key, info)
	_next()
