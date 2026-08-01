@tool
extends Node3D

## UISP Device Node
## Attach this to any 3D object in your scene to link it to a UISP device.
## The script will automatically fetch device data and update visualizations.

class_name UISPDevice

# ==================== CONFIGURATION ====================

## The UISP device ID (UUID) - find this in your UISP interface
@export var device_id: String = "" :
	set(value):
		device_id = value
		_update_editor_label()

## Display name override (if empty, uses UISP device name)
@export var display_name: String = ""

## Show device label in 3D space
@export var show_label: bool = true :
	set(value):
		show_label = value
		_update_label_visibility()

## Label offset from device position
@export var label_offset: Vector3 = Vector3(0, 2, 0)

## Device icon color (used for label background)
@export var device_color: Color = Color(0.2, 0.6, 1.0, 0.9)

## Auto-refresh statistics interval (0 = don't auto-refresh)
@export var stats_refresh_interval: float = 30.0

# ==================== DEVICE STATE ====================

## Current device data from UISP
var device_data: Dictionary = {}

## Device online status
var is_online: bool = false :
	set(value):
		if is_online != value:
			is_online = value
			status_changed.emit(is_online)
			_update_status_indicator()

## Signal strength (dBm) - typically -30 to -90, higher is better
var signal_strength: float = -100.0

## Device model name
var model_name: String = ""

## Device IP address
var ip_address: String = ""

## Device MAC address
var mac_address: String = ""

## Firmware version
var firmware_version: String = ""

## Uptime in seconds
var uptime: int = 0

## Connected datalinks (populated by visualizer)
var connected_links: Array[String] = []

# ==================== INTERNAL ====================

var _api_client: UISPApiClient = null
var _label_3d: Label3D = null
var _status_indicator: MeshInstance3D = null
var _stats_timer: float = 0.0
var _label_billboard_timer: float = 0.0
const _LABEL_BILLBOARD_INTERVAL: float = 0.1

# ==================== SIGNALS ====================

signal device_updated(device_data: Dictionary)
signal status_changed(online: bool)
signal statistics_updated(stats: Dictionary)

# ==================== LIFECYCLE ====================

func _ready() -> void:
	add_to_group("uisp_devices")
	
	if not Engine.is_editor_hint():
		_stats_timer = randf() * maxf(stats_refresh_interval, 0.1)
		_label_billboard_timer = randf() * _LABEL_BILLBOARD_INTERVAL
		_setup_label()
		_setup_status_indicator()
		_find_api_client()

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	
	# Auto-refresh statistics
	if stats_refresh_interval > 0 and _api_client != null and _api_client._is_connected:
		_stats_timer += delta
		if _stats_timer >= stats_refresh_interval:
			_stats_timer -= stats_refresh_interval
			refresh_statistics()
	
	# Make label face camera at 10 Hz (sufficient for readability)
	_label_billboard_timer += delta
	if _label_billboard_timer >= _LABEL_BILLBOARD_INTERVAL:
		_label_billboard_timer -= _LABEL_BILLBOARD_INTERVAL
		if _label_3d != null and show_label:
			var camera = get_viewport().get_camera_3d()
			if camera != null:
				_label_3d.look_at(camera.global_position, Vector3.UP)
				_label_3d.rotate_y(PI)  # Face toward camera

func _exit_tree() -> void:
	if _api_client != null:
		_api_client.devices_updated.disconnect(_on_devices_updated)
		_api_client.device_statistics_updated.disconnect(_on_statistics_updated)

# ==================== PUBLIC METHODS ====================

## Manually refresh device data
func refresh_data() -> void:
	if _api_client != null and device_id != "":
		_api_client.fetch_device_detail(device_id)

## Manually refresh device statistics
func refresh_statistics() -> void:
	if _api_client != null and device_id != "":
		_api_client.fetch_device_statistics(device_id)

## Get datalinks connected to this device
func get_connected_datalinks() -> Array:
	if _api_client != null and device_id != "":
		return _api_client.get_device_datalinks(device_id)
	return []

## Get the effective display name (custom or from UISP)
func get_display_name() -> String:
	if display_name != "":
		return display_name
	if device_data.has("identification"):
		var name = device_data["identification"].get("name", "")
		if name != "":
			return name
	if device_id != "":
		return device_id.substr(0, 8) + "..."
	return "Unknown Device"

## Set the API client reference (called by visualizer or manually)
func set_api_client(client: UISPApiClient) -> void:
	if _api_client != null:
		_api_client.devices_updated.disconnect(_on_devices_updated)
		_api_client.device_statistics_updated.disconnect(_on_statistics_updated)
	
	_api_client = client
	
	if _api_client != null:
		_api_client.devices_updated.connect(_on_devices_updated)
		_api_client.device_statistics_updated.connect(_on_statistics_updated)
		
		# Get initial data if available
		if _api_client.devices.has(device_id):
			_update_from_data(_api_client.devices[device_id])

# ==================== INTERNAL METHODS ====================

func _find_api_client() -> void:
	# Look for API client in the scene
	var clients = get_tree().get_nodes_in_group("uisp_api_client")
	if clients.size() > 0:
		set_api_client(clients[0] as UISPApiClient)
	else:
		# Try to find by class
		var root = get_tree().root
		_find_api_client_recursive(root)

func _find_api_client_recursive(node: Node) -> void:
	if _api_client != null:
		return
	if node is UISPApiClient:
		set_api_client(node as UISPApiClient)
		return
	for child in node.get_children():
		_find_api_client_recursive(child)

func _setup_label() -> void:
	_label_3d = Label3D.new()
	_label_3d.name = "DeviceLabel"
	_label_3d.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_label_3d.no_depth_test = true
	_label_3d.fixed_size = true
	_label_3d.pixel_size = 0.002
	_label_3d.font_size = 32
	_label_3d.outline_size = 8
	_label_3d.modulate = device_color
	_label_3d.outline_modulate = Color(0, 0, 0, 0.8)
	_label_3d.position = label_offset
	_label_3d.visible = show_label
	add_child(_label_3d)
	_update_label_text()

func _setup_status_indicator() -> void:
	# Create a small sphere to indicate device status
	_status_indicator = MeshInstance3D.new()
	_status_indicator.name = "StatusIndicator"
	
	var sphere = SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	_status_indicator.mesh = sphere
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.5, 0.5)  # Gray = unknown
	material.emission_enabled = true
	material.emission = Color(0.5, 0.5, 0.5)
	material.emission_energy_multiplier = 0.5
	_status_indicator.material_override = material
	
	_status_indicator.position = label_offset + Vector3(0, 0.5, 0)
	add_child(_status_indicator)
	_update_status_indicator()

func _update_label_visibility() -> void:
	if _label_3d != null:
		_label_3d.visible = show_label

func _update_label_text() -> void:
	if _label_3d == null:
		return
	
	var text = get_display_name()
	
	if is_online and signal_strength > -100:
		text += "\n📶 %d dBm" % int(signal_strength)
	elif not is_online and device_id != "":
		text += "\n⚠️ Offline"
	
	if ip_address != "":
		text += "\n🌐 %s" % ip_address
	
	_label_3d.text = text

func _update_status_indicator() -> void:
	if _status_indicator == null:
		return
	
	var material = _status_indicator.material_override as StandardMaterial3D
	if material == null:
		return
	
	if device_id == "":
		# Not configured
		material.albedo_color = Color(0.5, 0.5, 0.5)
		material.emission = Color(0.5, 0.5, 0.5)
	elif is_online:
		# Online - green
		material.albedo_color = Color(0.2, 0.9, 0.3)
		material.emission = Color(0.2, 0.9, 0.3)
		material.emission_energy_multiplier = 1.0
	else:
		# Offline - red
		material.albedo_color = Color(0.9, 0.2, 0.2)
		material.emission = Color(0.9, 0.2, 0.2)
		material.emission_energy_multiplier = 1.0

func _update_editor_label() -> void:
	if Engine.is_editor_hint():
		# Update node name in editor to show device ID
		if device_id != "":
			name = "UISPDevice_" + device_id.substr(0, 8)

func _on_devices_updated(devices: Dictionary) -> void:
	if device_id != "" and devices.has(device_id):
		_update_from_data(devices[device_id])

func _on_statistics_updated(dev_id: String, stats: Dictionary) -> void:
	if dev_id == device_id:
		statistics_updated.emit(stats)

func _update_from_data(data: Dictionary) -> void:
	device_data = data
	
	# Extract common fields
	var identification = data.get("identification", {})
	var overview = data.get("overview", {})
	
	model_name = identification.get("model", "")
	mac_address = identification.get("mac", "")
	firmware_version = overview.get("firmwareVersion", "")
	
	# Get IP address
	var ip_addresses = data.get("ipAddress", [])
	if ip_addresses.size() > 0:
		ip_address = ip_addresses[0]
	
	# Get status
	var status = overview.get("status", "")
	is_online = (status == "active" or status == "connected")
	
	# Get signal strength if available
	var interfaces = data.get("interfaces", [])
	for iface in interfaces:
		var iface_stats = iface.get("statistics", {})
		var sig = iface_stats.get("signal", null)
		if sig != null and sig > signal_strength:
			signal_strength = sig
	
	# Get uptime
	uptime = overview.get("uptime", 0)
	
	_update_label_text()
	_update_status_indicator()
	device_updated.emit(device_data)

