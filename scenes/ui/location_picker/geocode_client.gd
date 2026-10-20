extends Node
class_name GeocodeClient
## Nominatim forward + reverse geocoding (requires valid User-Agent per ToS).
##
## Forward (`search`) and reverse (`reverse`) use SEPARATE HTTPRequests so a
## reverse lookup fired by a coordinate edit never cancels a search the player
## typed. Nominatim's usage policy is one request per second — the picker
## debounces reverse lookups; this client does not queue.

signal search_done(hits: Array)  # each { "lat", "lng", "label" }
signal search_failed(message: String)
## A reverse lookup finished. `lat`/`lng` are the coordinates that were ASKED
## about (not Nominatim's snapped point), so the caller can drop a stale reply
## whose selection has since moved.
signal reverse_done(lat: float, lng: float, label: String)
signal reverse_failed(lat: float, lng: float, message: String)

const BASE: String = "https://nominatim.openstreetmap.org/search?format=json&limit=5&q="
const REVERSE_BASE: String = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=14&addressdetails=1"

const _HEADERS: PackedStringArray = [
	"User-Agent: SIMbiogenesis-LocationPicker/1.0",
	"Accept: application/json",
	"Accept-Language: en",
]

var _http: HTTPRequest
var _rev_http: HTTPRequest
var _busy: bool = false
var _rev_lat: float = NAN
var _rev_lng: float = NAN

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_rev_http = HTTPRequest.new()
	add_child(_rev_http)
	_rev_http.request_completed.connect(_on_reverse_completed)

func search(query: String) -> void:
	var q: String = query.strip_edges()
	if q.is_empty():
		search_failed.emit("Empty query")
		return
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	var url: String = BASE + q.uri_encode()
	var err: Error = _http.request(url, _HEADERS, HTTPClient.METHOD_GET)
	if err != OK:
		search_failed.emit("Request failed: %d" % err)
		return
	_busy = true


## Name the place at (lat, lng). A newer call cancels an older one in flight.
func reverse(lat: float, lng: float) -> void:
	if is_nan(lat) or is_nan(lng):
		return
	if _rev_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_rev_http.cancel_request()
	_rev_lat = lat
	_rev_lng = lng
	var url := "%s&lat=%.6f&lon=%.6f" % [REVERSE_BASE, lat, lng]
	var err: Error = _rev_http.request(url, _HEADERS, HTTPClient.METHOD_GET)
	if err != OK:
		reverse_failed.emit(lat, lng, "Request failed: %d" % err)


## Short human label from a Nominatim reverse result: the nearest named
## settlement + county + state/country ("Walton, Lane County, Oregon"), never
## the house-number-and-postcode form display_name gives. Pure, so the
## selftest can pin it.
static func compact_label(d: Dictionary) -> String:
	var addr: Dictionary = d.get("address", {}) if d.get("address", {}) is Dictionary else {}
	var parts: Array[String] = []
	for k in ["village", "hamlet", "town", "city", "municipality", "suburb", "locality"]:
		var v := str(addr.get(k, "")).strip_edges()
		if not v.is_empty():
			parts.append(v)
			break
	if parts.is_empty():
		var nm := str(d.get("name", "")).strip_edges()
		if not nm.is_empty():
			parts.append(nm)
	for k in ["county", "state", "country"]:
		var v2 := str(addr.get(k, "")).strip_edges()
		if not v2.is_empty() and not parts.has(v2):
			parts.append(v2)
		if parts.size() >= 3:
			break
	if parts.is_empty():
		return str(d.get("display_name", "")).strip_edges()
	return ", ".join(parts)


func _on_reverse_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var lat := _rev_lat
	var lng := _rev_lng
	if response_code != 200 or body.is_empty():
		reverse_failed.emit(lat, lng, "HTTP %d" % response_code)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or (parsed as Dictionary).has("error"):
		reverse_failed.emit(lat, lng, "No place here")
		return
	var label := compact_label(parsed as Dictionary)
	if label.is_empty():
		reverse_failed.emit(lat, lng, "No place here")
		return
	reverse_done.emit(lat, lng, label)


func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if body.is_empty():
		search_failed.emit("Empty response")
		return
	var text: String = body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Array):
		search_failed.emit("Invalid response")
		return
	var arr: Array = parsed
	var hits: Array = []
	for item in arr:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var lat: float = float(d.get("lat", "nan"))
		var lon: float = float(d.get("lon", "nan"))
		if is_nan(lat) or is_nan(lon):
			continue
		hits.append({
			"lat": lat,
			"lng": lon,
			"label": str(d.get("display_name", "")),
		})
	search_done.emit(hits)
