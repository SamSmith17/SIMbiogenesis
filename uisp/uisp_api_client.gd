extends Node

## UISP API Client
## Handles communication with UISP (Ubiquiti Internet Service Provider) REST API
## Reference: https://help.ui.com/hc/en-us/articles/115002943188-UISP-API

class_name UISPApiClient

# Configuration
@export var base_url: String = "https://your-uisp-instance.com"
@export var api_token: String = "YOUR_API_TOKEN"
@export var poll_interval: float = 30.0  # Seconds between data refreshes
@export var auto_poll: bool = true

## Authentication type for UISP
enum AuthType { SELF_HOSTED, CLOUD }
@export var auth_type: AuthType = AuthType.CLOUD

# Internal state
var _http_request: HTTPRequest
var _poll_timer: float = 0.0
var _is_connected: bool = false
var _pending_requests: Dictionary = {}  # request_id -> callback info
var _request_id: int = 0

# Cached data
var devices: Dictionary = {}  # device_id -> device data
var datalinks: Dictionary = {}  # datalink_id -> datalink data
var sites: Dictionary = {}  # site_id -> site data
var device_statistics: Dictionary = {}  # device_id -> statistics data

# Signals
signal connection_status_changed(connected: bool)
signal devices_updated(devices: Dictionary)
signal datalinks_updated(datalinks: Dictionary)
signal sites_updated(sites: Dictionary)
signal device_statistics_updated(device_id: String, statistics: Dictionary)
signal api_error(endpoint: String, error_message: String)

func _ready() -> void:
	_http_request = HTTPRequest.new()
	_http_request.timeout = 30.0
	add_child(_http_request)
	_http_request.request_completed.connect(_on_request_completed)
	_poll_timer = randf() * maxf(poll_interval, 0.1)

func _process(delta: float) -> void:
	if auto_poll and _is_connected:
		_poll_timer += delta
		if _poll_timer >= poll_interval:
			_poll_timer -= poll_interval
			refresh_all_data()

## Configure and connect to UISP
func connect_to_uisp(url: String = "", token: String = "") -> void:
	if url != "":
		base_url = url
	if token != "":
		api_token = token
	
	# Validate configuration
	if base_url == "https://your-uisp-instance.com" or api_token == "YOUR_API_TOKEN":
		push_warning("UISP API: Please configure URL and API token before connecting")
		return
	
	# Ensure base URL doesn't have trailing slash
	base_url = base_url.rstrip("/")
	
	# Auto-detect UISP Cloud vs self-hosted based on URL
	if ".ui.com" in base_url:
		auth_type = AuthType.CLOUD
	
	# Test connection by fetching NMS info
	_make_request("/nms/api/v2.1/nms/version", "_on_version_check")

## Disconnect from UISP
func disconnect_from_uisp() -> void:
	_is_connected = false
	devices.clear()
	datalinks.clear()
	sites.clear()
	device_statistics.clear()
	connection_status_changed.emit(false)

## Refresh all data from UISP
func refresh_all_data() -> void:
	if not _is_connected:
		return
	
	fetch_devices()
	fetch_datalinks()
	fetch_sites()

## Fetch all devices
func fetch_devices() -> void:
	_make_request("/nms/api/v2.1/devices", "_on_devices_received")

## Fetch single device details
func fetch_device_detail(device_id: String) -> void:
	_make_request("/nms/api/v2.1/devices/%s/detail" % device_id, "_on_device_detail_received", {"device_id": device_id})

## Fetch device statistics
func fetch_device_statistics(device_id: String, interval: String = "hour", period_ms: int = 86400000) -> void:
	var endpoint = "/nms/api/v2.1/devices/%s/statistics?interval=%s&period=%d" % [device_id, interval, period_ms]
	_make_request(endpoint, "_on_device_statistics_received", {"device_id": device_id})

## Fetch all datalinks (network connections between devices)
func fetch_datalinks() -> void:
	_make_request("/nms/api/v2.1/data-links", "_on_datalinks_received")

## Fetch specific datalink
func fetch_datalink(datalink_id: String) -> void:
	_make_request("/nms/api/v2.1/data-links/%s" % datalink_id, "_on_datalink_received", {"datalink_id": datalink_id})

## Fetch all sites
func fetch_sites() -> void:
	_make_request("/nms/api/v2.1/sites", "_on_sites_received")

## Fetch specific site
func fetch_site(site_id: String) -> void:
	_make_request("/nms/api/v2.1/sites/%s" % site_id, "_on_site_received", {"site_id": site_id})

## Get device by ID from cache
func get_device(device_id: String) -> Dictionary:
	return devices.get(device_id, {})

## Get datalink by ID from cache
func get_datalink(datalink_id: String) -> Dictionary:
	return datalinks.get(datalink_id, {})

## Get site by ID from cache
func get_site(site_id: String) -> Dictionary:
	return sites.get(site_id, {})

## Find datalinks connected to a specific device
func get_device_datalinks(device_id: String) -> Array:
	var result: Array = []
	for link_id in datalinks:
		var link = datalinks[link_id]
		var from_device = link.get("from", {}).get("device", {}).get("identification", {}).get("id", "")
		var to_device = link.get("to", {}).get("device", {}).get("identification", {}).get("id", "")
		if from_device == device_id or to_device == device_id:
			result.append(link)
	return result

## Get signal strength for a datalink (returns dBm, lower is worse)
func get_datalink_signal(datalink_id: String) -> float:
	var link = get_datalink(datalink_id)
	if link.is_empty():
		return -100.0
	
	# Try to get signal from the link's interface statistics
	var from_signal = link.get("from", {}).get("interface", {}).get("statistics", {}).get("signal", -100.0)
	var to_signal = link.get("to", {}).get("interface", {}).get("statistics", {}).get("signal", -100.0)
	
	# Return the better (higher/closer to 0) signal
	return max(from_signal, to_signal)

## Get throughput for a datalink (returns Mbps)
func get_datalink_throughput(datalink_id: String) -> Dictionary:
	var link = get_datalink(datalink_id)
	if link.is_empty():
		return {"tx": 0.0, "rx": 0.0}
	
	var from_stats = link.get("from", {}).get("interface", {}).get("statistics", {})
	var to_stats = link.get("to", {}).get("interface", {}).get("statistics", {})
	
	# Get transmit/receive rates in bps, convert to Mbps
	var tx_bps = from_stats.get("txRate", 0.0)
	var rx_bps = from_stats.get("rxRate", 0.0)
	
	return {
		"tx": tx_bps / 1000000.0,
		"rx": rx_bps / 1000000.0
	}

## Get link capacity (max theoretical throughput in Mbps)
func get_datalink_capacity(datalink_id: String) -> float:
	var link = get_datalink(datalink_id)
	if link.is_empty():
		return 0.0
	
	var from_capacity = link.get("from", {}).get("interface", {}).get("statistics", {}).get("linkCapacity", 0.0)
	var to_capacity = link.get("to", {}).get("interface", {}).get("statistics", {}).get("linkCapacity", 0.0)
	
	# Return the lower capacity (bottleneck)
	if from_capacity > 0 and to_capacity > 0:
		return min(from_capacity, to_capacity) / 1000000.0
	return max(from_capacity, to_capacity) / 1000000.0

# ==================== INTERNAL METHODS ====================

func _make_request(endpoint: String, callback: String, metadata: Dictionary = {}) -> void:
	if _http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		# Queue the request or use a request pool for concurrent requests
		await get_tree().create_timer(0.1).timeout
		_make_request(endpoint, callback, metadata)
		return
	
	var url = base_url + endpoint
	var headers: PackedStringArray = []
	
	# UISP uses x-auth-token header (same for Cloud and self-hosted)
	# Token must be generated from UISP Settings → Users → API Tokens
	headers.append("x-auth-token: " + api_token)
	headers.append("Content-Type: application/json")
	headers.append("Accept: application/json")
	
	_request_id += 1
	_pending_requests[_request_id] = {
		"endpoint": endpoint,
		"callback": callback,
		"metadata": metadata
	}
	
	# Make the request - Godot will use system certificates by default
	var error = _http_request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		push_error("UISP API: Request failed for %s: %s" % [endpoint, error])
		api_error.emit(endpoint, "Request failed: %s" % error)
		_pending_requests.erase(_request_id)

func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if _pending_requests.is_empty():
		return
	
	# Get the oldest pending request
	var request_id = _pending_requests.keys()[0]
	var request_info = _pending_requests[request_id]
	_pending_requests.erase(request_id)
	
	var endpoint = request_info["endpoint"]
	var callback = request_info["callback"]
	var metadata = request_info["metadata"]
	
	var body_text = body.get_string_from_utf8()
	
	if result != HTTPRequest.RESULT_SUCCESS:
		var error_names = {
			HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: "Chunked body size mismatch",
			HTTPRequest.RESULT_CANT_CONNECT: "Can't connect to host",
			HTTPRequest.RESULT_CANT_RESOLVE: "Can't resolve hostname",
			HTTPRequest.RESULT_CONNECTION_ERROR: "Connection error",
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS/SSL handshake error",
			HTTPRequest.RESULT_NO_RESPONSE: "No response from server",
			HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "Body size limit exceeded",
			HTTPRequest.RESULT_REQUEST_FAILED: "Request failed",
			HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: "Can't open download file",
			HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: "Download file write error",
			HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: "Redirect limit reached",
			HTTPRequest.RESULT_TIMEOUT: "Request timeout"
		}
		var error_name = error_names.get(result, "Unknown error %s" % result)
		push_error("UISP API: %s for %s" % [error_name, endpoint])
		api_error.emit(endpoint, error_name)
		return
	
	if response_code != 200:
		push_error("UISP API: HTTP %s for %s" % [response_code, endpoint])
		api_error.emit(endpoint, "HTTP %s" % response_code)
		
		if response_code == 401:
			_is_connected = false
			connection_status_changed.emit(false)
		return
	
	# Check if response is HTML (login page) instead of JSON
	if body_text.strip_edges().begins_with("<!") or body_text.strip_edges().begins_with("<html"):
		push_error("UISP API: Received HTML instead of JSON - authentication failed")
		api_error.emit(endpoint, "Auth failed - check console for token instructions")
		return
	
	var json = JSON.new()
	var parse_error = json.parse(body_text)
	if parse_error != OK:
		push_error("UISP API: JSON parse error for %s at line %s" % [endpoint, json.get_error_line()])
		api_error.emit(endpoint, "JSON parse error - check console for details")
		return
	
	var data = json.data
	
	# Call the appropriate handler
	if has_method(callback):
		call(callback, data, metadata)

func _on_version_check(data: Dictionary, _metadata: Dictionary) -> void:
	var version = data.get("version", "unknown")
	_is_connected = true
	connection_status_changed.emit(true)
	
	# Fetch initial data
	refresh_all_data()

func _on_devices_received(data: Array, _metadata: Dictionary) -> void:
	devices.clear()
	for device in data:
		var device_id = device.get("identification", {}).get("id", "")
		if device_id != "":
			devices[device_id] = device
	
	devices_updated.emit(devices)

func _on_device_detail_received(data: Dictionary, metadata: Dictionary) -> void:
	var device_id = metadata.get("device_id", "")
	if device_id != "" and not data.is_empty():
		devices[device_id] = data
		devices_updated.emit(devices)

func _on_device_statistics_received(data: Dictionary, metadata: Dictionary) -> void:
	var device_id = metadata.get("device_id", "")
	if device_id != "":
		device_statistics[device_id] = data
		device_statistics_updated.emit(device_id, data)

func _on_datalinks_received(data: Array, _metadata: Dictionary) -> void:
	datalinks.clear()
	for link in data:
		var link_id = link.get("id", "")
		if link_id != "":
			datalinks[link_id] = link
	
	datalinks_updated.emit(datalinks)

func _on_datalink_received(data: Dictionary, metadata: Dictionary) -> void:
	var datalink_id = metadata.get("datalink_id", "")
	if datalink_id != "" and not data.is_empty():
		datalinks[datalink_id] = data
		datalinks_updated.emit(datalinks)

func _on_sites_received(data: Array, _metadata: Dictionary) -> void:
	sites.clear()
	for site in data:
		var site_id = site.get("id", "")
		if site_id != "":
			sites[site_id] = site
	
	sites_updated.emit(sites)

func _on_site_received(data: Dictionary, metadata: Dictionary) -> void:
	var site_id = metadata.get("site_id", "")
	if site_id != "" and not data.is_empty():
		sites[site_id] = data
		sites_updated.emit(sites)

