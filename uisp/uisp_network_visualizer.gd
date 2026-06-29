@tool
extends Node3D

## UISP Network Visualizer
## Draws 3D connection lines between UISP devices showing signal strength,
## capacity, and traffic flow. Automatically discovers UISPDevice nodes in the scene.

class_name UISPNetworkVisualizer

# ==================== CONFIGURATION ====================

## Reference to the UISP API client
@export var api_client: UISPApiClient :
	set(value):
		if api_client != null:
			api_client.datalinks_updated.disconnect(_on_datalinks_updated)
			api_client.devices_updated.disconnect(_on_devices_updated)
		api_client = value
		if api_client != null:
			api_client.datalinks_updated.connect(_on_datalinks_updated)
			api_client.devices_updated.connect(_on_devices_updated)
			_distribute_api_client()

## Line thickness for connections
@export_range(0.01, 0.5, 0.01) var line_thickness: float = 0.08

## Height offset for connection lines (above ground level)
@export var line_height_offset: float = 0.5

## Show signal strength on lines (color gradient)
@export var show_signal_strength: bool = true

## Show traffic flow animation
@export var show_traffic_flow: bool = true

## Show capacity utilization (line thickness varies)
@export var show_capacity_utilization: bool = true

## Traffic flow animation speed
@export_range(0.1, 5.0, 0.1) var flow_animation_speed: float = 1.0

## Update visualization every N seconds
@export var visualization_update_interval: float = 5.0

## Signal strength color gradient
## Good signal (-30 to -50 dBm) = Green
## Medium signal (-50 to -70 dBm) = Yellow
## Poor signal (-70 to -80 dBm) = Orange
## Bad signal (-80+ dBm) = Red
@export var signal_good_color: Color = Color(0.2, 0.9, 0.3, 0.9)
@export var signal_medium_color: Color = Color(0.9, 0.9, 0.2, 0.9)
@export var signal_poor_color: Color = Color(0.9, 0.5, 0.1, 0.9)
@export var signal_bad_color: Color = Color(0.9, 0.2, 0.2, 0.9)
@export var offline_color: Color = Color(0.4, 0.4, 0.4, 0.5)

# ==================== INTERNAL STATE ====================

var _device_nodes: Dictionary = {}  # device_id -> UISPDevice node
var _link_meshes: Dictionary = {}  # datalink_id -> MeshInstance3D
var _link_labels: Dictionary = {}  # datalink_id -> Label3D
var _flow_particles: Dictionary = {}  # datalink_id -> GPUParticles3D
var _update_timer: float = 0.0
var _flow_time: float = 0.0
var _label_orient_timer: float = 0.0
var _flow_anim_timer: float = 0.0
const _LABEL_ORIENT_INTERVAL: float = 0.1
const _FLOW_ANIM_INTERVAL: float = 0.05

# ==================== SIGNALS ====================

signal link_clicked(datalink_id: String)
signal link_hovered(datalink_id: String)

# ==================== LIFECYCLE ====================

func _ready() -> void:
	add_to_group("uisp_network_visualizer")
	
	if not Engine.is_editor_hint():
		_update_timer = randf() * maxf(visualization_update_interval, 0.1)
		_label_orient_timer = randf() * _LABEL_ORIENT_INTERVAL
		_flow_anim_timer = randf() * _FLOW_ANIM_INTERVAL
		# Find API client if not set
		if api_client == null:
			_find_api_client()
		
		# Discover device nodes
		call_deferred("_discover_devices")

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	
	# Update visualization periodically
	_update_timer += delta
	if _update_timer >= visualization_update_interval:
		_update_timer -= visualization_update_interval
		_update_all_visualizations()
	
	# Animate traffic flow
	if show_traffic_flow:
		_flow_time += delta * flow_animation_speed
		_flow_anim_timer += delta
		if _flow_anim_timer >= _FLOW_ANIM_INTERVAL:
			_flow_anim_timer -= _FLOW_ANIM_INTERVAL
			_animate_traffic_flow()
	
	# Update link labels to face camera (10 Hz is enough for billboarding)
	_label_orient_timer += delta
	if _label_orient_timer >= _LABEL_ORIENT_INTERVAL:
		_label_orient_timer -= _LABEL_ORIENT_INTERVAL
		_update_label_orientations()

# ==================== PUBLIC METHODS ====================

## Manually trigger device discovery
func discover_devices() -> void:
	_discover_devices()

## Refresh all visualizations
func refresh_visualizations() -> void:
	_update_all_visualizations()

## Clear all visualization elements
func clear_visualizations() -> void:
	for link_id in _link_meshes.keys():
		_remove_link_visualization(link_id)
	_link_meshes.clear()
	_link_labels.clear()
	_flow_particles.clear()

## Get all discovered device nodes
func get_device_nodes() -> Dictionary:
	return _device_nodes.duplicate()

## Check if a specific device is in the scene
func has_device(device_id: String) -> bool:
	return _device_nodes.has(device_id)

## Get the 3D position of a device
func get_device_position(device_id: String) -> Vector3:
	if _device_nodes.has(device_id):
		return _device_nodes[device_id].global_position
	return Vector3.ZERO

# ==================== INTERNAL METHODS ====================

func _find_api_client() -> void:
	var clients = get_tree().get_nodes_in_group("uisp_api_client")
	if clients.size() > 0:
		api_client = clients[0] as UISPApiClient
	else:
		# Search scene tree
		var root = get_tree().root
		_find_api_client_recursive(root)

func _find_api_client_recursive(node: Node) -> void:
	if api_client != null:
		return
	if node is UISPApiClient:
		api_client = node as UISPApiClient
		api_client.datalinks_updated.connect(_on_datalinks_updated)
		api_client.devices_updated.connect(_on_devices_updated)
		return
	for child in node.get_children():
		_find_api_client_recursive(child)

func _distribute_api_client() -> void:
	# Give the API client reference to all discovered devices
	for device_id in _device_nodes:
		var device = _device_nodes[device_id] as UISPDevice
		if device != null:
			device.set_api_client(api_client)

func _discover_devices() -> void:
	_device_nodes.clear()
	
	# Find all UISPDevice nodes in the scene
	var devices = get_tree().get_nodes_in_group("uisp_devices")
	for device in devices:
		if device is UISPDevice:
			var uisp_device = device as UISPDevice
			if uisp_device.device_id != "":
				_device_nodes[uisp_device.device_id] = uisp_device
				if api_client != null:
					uisp_device.set_api_client(api_client)
	
	# Update visualizations if we have datalink data
	if api_client != null and not api_client.datalinks.is_empty():
		_update_all_visualizations()

func _on_datalinks_updated(_datalinks: Dictionary) -> void:
	_update_all_visualizations()

func _on_devices_updated(_devices: Dictionary) -> void:
	# Re-discover devices in case new ones match
	_discover_devices()

func _update_all_visualizations() -> void:
	if api_client == null:
		return
	
	var active_links: Array[String] = []
	
	# Create/update visualizations for each datalink
	for link_id in api_client.datalinks:
		var link = api_client.datalinks[link_id]
		
		# Get device IDs from the link
		var from_device_id = link.get("from", {}).get("device", {}).get("identification", {}).get("id", "")
		var to_device_id = link.get("to", {}).get("device", {}).get("identification", {}).get("id", "")
		
		# Check if both devices are in our scene
		if _device_nodes.has(from_device_id) and _device_nodes.has(to_device_id):
			active_links.append(link_id)
			_update_link_visualization(link_id, link)
	
	# Remove visualizations for links no longer active
	for link_id in _link_meshes.keys():
		if not active_links.has(link_id):
			_remove_link_visualization(link_id)

func _update_link_visualization(link_id: String, link: Dictionary) -> void:
	var from_device_id = link.get("from", {}).get("device", {}).get("identification", {}).get("id", "")
	var to_device_id = link.get("to", {}).get("device", {}).get("identification", {}).get("id", "")
	
	var from_pos = get_device_position(from_device_id) + Vector3(0, line_height_offset, 0)
	var to_pos = get_device_position(to_device_id) + Vector3(0, line_height_offset, 0)
	
	# Get link stats
	var signal_dbm = api_client.get_datalink_signal(link_id)
	var throughput = api_client.get_datalink_throughput(link_id)
	var capacity = api_client.get_datalink_capacity(link_id)
	
	# Determine link color based on signal strength
	var link_color = _get_signal_color(signal_dbm)
	
	# Determine link thickness based on capacity utilization
	var thickness = line_thickness
	if show_capacity_utilization and capacity > 0:
		var utilization = (throughput.tx + throughput.rx) / (capacity * 2.0)
		thickness = line_thickness * (0.5 + utilization * 1.5)
		thickness = clamp(thickness, line_thickness * 0.5, line_thickness * 2.0)
	
	# Check if link is offline
	var from_status = link.get("from", {}).get("device", {}).get("overview", {}).get("status", "")
	var to_status = link.get("to", {}).get("device", {}).get("overview", {}).get("status", "")
	if from_status != "active" or to_status != "active":
		link_color = offline_color
	
	# Create or update mesh
	if not _link_meshes.has(link_id):
		_create_link_mesh(link_id)
	
	_update_link_mesh(link_id, from_pos, to_pos, link_color, thickness)
	
	# Create or update label
	if not _link_labels.has(link_id):
		_create_link_label(link_id)
	
	_update_link_label(link_id, from_pos, to_pos, signal_dbm, throughput, capacity)

func _create_link_mesh(link_id: String) -> void:
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Link_" + link_id.substr(0, 8)
	
	var cylinder = CylinderMesh.new()
	cylinder.top_radius = line_thickness
	cylinder.bottom_radius = line_thickness
	cylinder.height = 1.0
	cylinder.radial_segments = 8
	mesh_instance.mesh = cylinder
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.emission_enabled = true
	material.emission_energy_multiplier = 0.5
	mesh_instance.material_override = material
	
	add_child(mesh_instance)
	_link_meshes[link_id] = mesh_instance

func _update_link_mesh(link_id: String, from_pos: Vector3, to_pos: Vector3, color: Color, thickness: float) -> void:
	var mesh_instance = _link_meshes.get(link_id) as MeshInstance3D
	if mesh_instance == null:
		return
	
	var cylinder = mesh_instance.mesh as CylinderMesh
	if cylinder != null:
		cylinder.top_radius = thickness
		cylinder.bottom_radius = thickness
		cylinder.height = from_pos.distance_to(to_pos)
	
	# Position at midpoint
	var midpoint = (from_pos + to_pos) / 2.0
	mesh_instance.global_position = midpoint
	
	# Rotate to point from start to end
	var direction = (to_pos - from_pos).normalized()
	if direction.length() > 0.001:
		# CylinderMesh is vertical by default (Y-up), so we need to rotate it
		var up = Vector3.UP
		if abs(direction.dot(up)) > 0.99:
			up = Vector3.FORWARD
		mesh_instance.look_at(to_pos, up)
		mesh_instance.rotate_object_local(Vector3.RIGHT, PI / 2.0)
	
	# Update material color
	var material = mesh_instance.material_override as StandardMaterial3D
	if material != null:
		material.albedo_color = color
		material.emission = Color(color.r, color.g, color.b, 1.0)

func _create_link_label(link_id: String) -> void:
	var label = Label3D.new()
	label.name = "LinkLabel_" + link_id.substr(0, 8)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0015
	label.font_size = 24
	label.outline_size = 6
	label.modulate = Color(1, 1, 1, 0.9)
	label.outline_modulate = Color(0, 0, 0, 0.8)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	add_child(label)
	_link_labels[link_id] = label

func _update_link_label(link_id: String, from_pos: Vector3, to_pos: Vector3, signal_dbm: float, throughput: Dictionary, capacity: float) -> void:
	var label = _link_labels.get(link_id) as Label3D
	if label == null:
		return
	
	# Position above the link midpoint
	var midpoint = (from_pos + to_pos) / 2.0 + Vector3(0, 0.8, 0)
	label.global_position = midpoint
	
	# Build label text
	var text_lines: Array[String] = []
	
	if signal_dbm > -100:
		text_lines.append("📶 %d dBm" % int(signal_dbm))
	
	var total_throughput = throughput.tx + throughput.rx
	if total_throughput > 0:
		if total_throughput >= 1000:
			text_lines.append("⬆️⬇️ %.1f Gbps" % (total_throughput / 1000.0))
		else:
			text_lines.append("⬆️⬇️ %.1f Mbps" % total_throughput)
	
	if capacity > 0 and total_throughput > 0:
		var utilization = (total_throughput / capacity) * 100.0
		text_lines.append("📊 %.0f%%" % utilization)
	
	label.text = "\n".join(text_lines) if text_lines.size() > 0 else ""
	label.visible = label.text != ""

func _remove_link_visualization(link_id: String) -> void:
	if _link_meshes.has(link_id):
		var mesh = _link_meshes[link_id]
		if mesh != null:
			mesh.queue_free()
		_link_meshes.erase(link_id)
	
	if _link_labels.has(link_id):
		var label = _link_labels[link_id]
		if label != null:
			label.queue_free()
		_link_labels.erase(link_id)
	
	if _flow_particles.has(link_id):
		var particles = _flow_particles[link_id]
		if particles != null:
			particles.queue_free()
		_flow_particles.erase(link_id)

func _get_signal_color(signal_dbm: float) -> Color:
	if signal_dbm <= -100:
		return offline_color
	elif signal_dbm >= -50:
		# Good signal: interpolate from green to yellow
		var t = clamp((signal_dbm + 30) / 20.0, 0.0, 1.0)
		return signal_good_color.lerp(signal_medium_color, 1.0 - t)
	elif signal_dbm >= -70:
		# Medium signal: interpolate from yellow to orange
		var t = clamp((signal_dbm + 50) / 20.0, 0.0, 1.0)
		return signal_medium_color.lerp(signal_poor_color, 1.0 - t)
	elif signal_dbm >= -80:
		# Poor signal: interpolate from orange to red
		var t = clamp((signal_dbm + 70) / 10.0, 0.0, 1.0)
		return signal_poor_color.lerp(signal_bad_color, 1.0 - t)
	else:
		return signal_bad_color

func _animate_traffic_flow() -> void:
	# Animate link materials with a subtle pulsing effect based on throughput
	for link_id in _link_meshes:
		var mesh = _link_meshes[link_id] as MeshInstance3D
		if mesh == null:
			continue
		
		var material = mesh.material_override as StandardMaterial3D
		if material == null:
			continue
		
		if api_client != null:
			var throughput = api_client.get_datalink_throughput(link_id)
			var total = throughput.tx + throughput.rx
			
			# Pulse intensity based on throughput (more traffic = more visible pulse)
			if total > 0:
				var pulse_intensity = clamp(total / 1000.0, 0.1, 1.0)  # Max at 1 Gbps
				var pulse = sin(_flow_time * 3.0 + link_id.hash() * 0.001) * 0.3 * pulse_intensity
				material.emission_energy_multiplier = 0.5 + pulse

func _update_label_orientations() -> void:
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		return
	
	for link_id in _link_labels:
		var label = _link_labels[link_id] as Label3D
		if label != null and label.visible:
			label.look_at(camera.global_position, Vector3.UP)
			label.rotate_y(PI)

