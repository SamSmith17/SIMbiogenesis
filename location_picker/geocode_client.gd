extends Node
class_name GeocodeClient
## Nominatim forward geocoding (requires valid User-Agent per ToS)

signal search_done(hits: Array)  # each { "lat", "lng", "label" }
signal search_failed(message: String)

const BASE: String = "https://nominatim.openstreetmap.org/search?format=json&limit=5&q="

var _http: HTTPRequest
var _busy: bool = false

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

func search(query: String) -> void:
	var q: String = query.strip_edges()
	if q.is_empty():
		search_failed.emit("Empty query")
		return
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	var url: String = BASE + q.uri_encode()
	var headers: PackedStringArray = [
		"User-Agent: SIMbiogenesis-LocationPicker/1.0",
		"Accept: application/json",
		"Accept-Language: en",
	]
	var err: Error = _http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		search_failed.emit("Request failed: %d" % err)
		return
	_busy = true

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
