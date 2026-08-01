@tool
extends Node3D

## Govee-style String Lights with Catenary Wire Physics
## 
## USAGE:
## 1. Add child Node3D nodes named "Bulb_0", "Bulb_1", etc. (or any name starting with "Bulb")
## 2. Position the bulbs where you want them in the editor - just drag them!
## 3. The wires will automatically generate with realistic sag between bulbs
## 4. Bulbs are connected in order of their names (alphabetically sorted)
##
## The bulbs define anchor points, and catenary curves are drawn between them.
## Moving a bulb in the editor instantly updates the wire geometry.

## ===== HOME ASSISTANT INTEGRATION =====

@export_group("Home Assistant")
## The Home Assistant entity ID to link to (e.g., "light.govee_h7039")
@export var ha_entity_id: String = "":
	set(value):
		ha_entity_id = value
		_detect_entity_domain()

## Whether to sync game state back to Home Assistant when controlled locally
@export var sync_to_ha: bool = true

@export_group("Interaction")
## Interaction radius for player detection
@export var interaction_radius: float = 3.0

## ===== APPEARANCE =====

@export_group("Bulb Appearance")
## Radius of each light bulb
@export_range(0.01, 0.2, 0.005) var bulb_radius: float = 0.04:
	set(value):
		bulb_radius = value
		_rebuild_all()

## Horizontal spacing between bulbs along the string
@export_range(0.1, 5.0, 0.05) var bulb_spacing: float = 1.0:
	set(value):
		bulb_spacing = maxf(value, 0.1)
		_apply_bulb_spacing()

## Color of the bulb when ON
@export var bulb_color_on: Color = Color(1.0, 0.85, 0.6, 1.0):
	set(value):
		bulb_color_on = value
		_apply_visual_state()

## Color of the bulb when OFF  
@export var bulb_color_off: Color = Color(0.15, 0.12, 0.08, 0.8):
	set(value):
		bulb_color_off = value
		_apply_visual_state()

@export_group("Wire Appearance")
## Thickness of the wire connecting bulbs
@export_range(0.002, 0.02, 0.001) var wire_thickness: float = 0.006:
	set(value):
		wire_thickness = value
		_rebuild_wires()

## Color of the wire
@export var wire_color: Color = Color(0.08, 0.08, 0.08, 1.0):
	set(value):
		wire_color = value
		_update_wire_material()

@export_group("Catenary Physics")
## How much the wire sags between bulbs (0 = straight line, 1 = heavy sag)
@export_range(0.0, 2.0, 0.05) var sag_amount: float = 0.3:
	set(value):
		sag_amount = value
		_rebuild_wires()

## Number of segments per wire span (more = smoother curve)
@export_range(4, 32, 1) var wire_segments: int = 12:
	set(value):
		wire_segments = value
		_rebuild_wires()

@export_group("Lighting")
## Light energy when bulbs are on
@export_range(0.0, 5.0, 0.1) var light_energy: float = 1.0:
	set(value):
		light_energy = value
		_apply_visual_state()

## Range of each bulb's omni light
@export_range(0.5, 10.0, 0.5) var light_range: float = 2.0:
	set(value):
		light_range = value
		_apply_visual_state()

## Light attenuation (higher = faster falloff)
@export_range(0.5, 4.0, 0.1) var light_attenuation: float = 1.5:
	set(value):
		light_attenuation = value
		_apply_visual_state()

## Enable/disable soft glow effect around bulbs
@export var enable_glow: bool = false:
	set(value):
		enable_glow = value
		_apply_visual_state()

## Glow size multiplier relative to bulb
@export_range(2.0, 12.0, 0.5) var glow_size: float = 6.0:
	set(value):
		glow_size = value
		_apply_visual_state()

## Glow intensity (opacity)
@export_range(0.0, 1.0, 0.05) var glow_intensity: float = 0.3:
	set(value):
		glow_intensity = value
		_apply_visual_state()

@export_group("Behavior")
## Hour when lights turn on (24h format)
@export_range(0.0, 24.0, 0.5) var turn_on_hour: float = 18.0

## Hour when lights turn off (24h format)  
@export_range(0.0, 24.0, 0.5) var turn_off_hour: float = 6.0

## Power consumption in Watts
@export_range(1.0, 500.0, 1.0) var wattage: float = 25.0

## Human-readable name for this light string
@export var display_name: String = "Govee Lights"

## Preview lights as ON in the editor
@export var editor_preview_on: bool = false:
	set(value):
		editor_preview_on = value
		if Engine.is_editor_hint():
			_apply_visual_state()

@export_group("Editor Tools")
## Click to add a new bulb at the end of the string
@export var add_bulb: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_add_new_bulb()

## Click to regenerate all wire geometry
@export var rebuild_wires: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_rebuild_all()

# ===== INTERNAL STATE =====

var is_on: bool = false
var brightness: int = 255  # 0-255, matches Home Assistant
var current_color: Color = Color(1.0, 0.85, 0.6, 1.0)  # Current light color
var external_control: bool = false
var _wire_container: Node3D
var _bulb_meshes: Dictionary = {}  # bulb_node -> MeshInstance3D
var _wire_material: StandardMaterial3D
var _glow_texture: GradientTexture2D
var _main_node: Node = null
var _solar_ui: Node = null
var _power_available: bool = true
var _connect_attempts: int = 0
var _last_bulb_positions: Dictionary = {}
var _editor_update_timer: float = 0.0
const EDITOR_UPDATE_INTERVAL: float = 0.1
const RUNTIME_UPDATE_INTERVAL: float = 0.25
var _runtime_update_timer: float = 0.0

# Home Assistant integration
var _ha_client: Node = null
var _entity_domain: String = "light"
var _initial_state_received: bool = false
var _command_in_flight: bool = false
var _pending_state: bool = false
var _pending_brightness: int = -1
var _pending_color: Color = Color(-1, -1, -1)
var _command_sent_time: float = 0.0
const COMMAND_TIMEOUT: float = 2.0

# Interaction system
var _interaction_area: Area3D = null
var _player_in_range: Node3D = null
var _interaction_ui: Node = null
var _color_menu: Control = null
var _menu_visible: bool = false

# Color palette for the menu (8 colors)
const COLOR_PALETTE: Array[Color] = [
	Color(1.0, 0.85, 0.6),    # Warm White
	Color(0.9, 0.95, 1.0),    # Cool White
	Color(1.0, 0.2, 0.1),     # Red
	Color(1.0, 0.5, 0.0),     # Orange
	Color(1.0, 0.9, 0.2),     # Yellow
	Color(0.2, 1.0, 0.3),     # Green
	Color(0.2, 0.4, 1.0),     # Blue
	Color(0.7, 0.2, 1.0),     # Purple
]

const COLOR_NAMES: Array[String] = [
	"Warm White", "Cool White", "Red", "Orange", 
	"Yellow", "Green", "Blue", "Purple"
]

signal state_changed(new_state: bool)
signal color_changed(new_color: Color)
signal brightness_changed(new_brightness: int)

# Helper to check if we're editing this scene directly (not as an instance in another scene)
func _is_editing_this_scene_directly() -> bool:
	if not Engine.is_editor_hint():
		return false
	var tree = get_tree()
	if tree == null:
		return false
	var edited_root = tree.edited_scene_root
	if edited_root == null:
		return false
	# Check if the edited scene root is this node or one of our ancestors
	# If we're instanced in another scene, edited_scene_root will be that other scene's root
	var node: Node = self
	while node != null:
		if node == edited_root:
			return true
		# If we hit the scene root and it's not the edited root, we're instanced
		if node.scene_file_path != "" and node != edited_root:
			return false
		node = node.get_parent()
	return false

func _set_editor_owner(node: Node) -> void:
	if _is_editing_this_scene_directly():
		var tree = get_tree()
		if tree != null and tree.edited_scene_root != null:
			node.owner = tree.edited_scene_root

func _ready() -> void:
	_setup_materials()
	_ensure_wire_container()
	_detect_entity_domain()
	_rebuild_all()
	
	# Initialize current_color from bulb_color_on
	current_color = bulb_color_on
	
	if not Engine.is_editor_hint():
		add_to_group("power_consumers")
		_runtime_update_timer = randf() * RUNTIME_UPDATE_INTERVAL
		call_deferred("_connect_to_power_system")
		call_deferred("_connect_to_ha")
		call_deferred("_update_lights")
		call_deferred("_setup_interaction_area")
		call_deferred("_find_interaction_ui")

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_editor_update_timer += delta
		if _editor_update_timer >= EDITOR_UPDATE_INTERVAL:
			_editor_update_timer = 0.0
			_check_bulb_positions()
	else:
		if _command_in_flight:
			_command_sent_time += delta
			if _command_sent_time >= COMMAND_TIMEOUT:
				_command_in_flight = false
		
		if not external_control:
			_runtime_update_timer += delta
			if _runtime_update_timer >= RUNTIME_UPDATE_INTERVAL:
				_runtime_update_timer -= RUNTIME_UPDATE_INTERVAL
				_update_lights()

# ===== HOME ASSISTANT INTEGRATION =====

func _detect_entity_domain() -> void:
	if ha_entity_id == "":
		return
	var dot_index = ha_entity_id.find(".")
	if dot_index > 0:
		_entity_domain = ha_entity_id.substr(0, dot_index)
		if not Engine.is_editor_hint():
			pass

func _connect_to_ha() -> void:
	if ha_entity_id == "":
		return
	
	var tree = get_tree()
	if tree == null:
		return
	
	var root = tree.root
	for child in root.get_children():
		var client = child.get_node_or_null("HAClient")
		if client:
			_ha_client = client
			if _ha_client.has_signal("sensor_updated"):
				if not _ha_client.sensor_updated.is_connected(_on_ha_sensor_updated):
					_ha_client.sensor_updated.connect(_on_ha_sensor_updated)
			if _ha_client.has_signal("authentication_status_changed"):
				if not _ha_client.authentication_status_changed.is_connected(_on_ha_authenticated):
					_ha_client.authentication_status_changed.connect(_on_ha_authenticated)
			if _ha_client.is_authenticated:
				_request_initial_state()
			break

func _on_ha_authenticated(authenticated: bool) -> void:
	if authenticated and not _initial_state_received:
		_request_initial_state()

func _request_initial_state() -> void:
	if _ha_client == null or ha_entity_id == "" or _initial_state_received:
		return
	if _ha_client.has_method("get_single_entity_state"):
		_ha_client.get_single_entity_state(ha_entity_id)

func _on_ha_sensor_updated(entity_id: String, state: Dictionary) -> void:
	if entity_id != ha_entity_id:
		return
	
	var state_value = state.get("state", "")
	var new_state = (state_value == "on")
	
	# Extract attributes for brightness and color
	var attributes = state.get("attributes", {})
	
	# Safely extract brightness (HA may send int, float, or null)
	var brightness_raw = attributes.get("brightness", null)
	var new_brightness: int = brightness
	if brightness_raw != null:
		new_brightness = int(brightness_raw)
	
	var rgb_color = attributes.get("rgb_color", null)
	var new_color: Color = current_color
	
	if rgb_color != null and rgb_color is Array and rgb_color.size() >= 3:
		new_color = Color(
			float(rgb_color[0]) / 255.0,
			float(rgb_color[1]) / 255.0,
			float(rgb_color[2]) / 255.0,
			1.0
		)
	
	# Check if this update matches our pending command
	if _command_in_flight:
		var state_matches = (new_state == _pending_state)
		var brightness_matches = (_pending_brightness < 0 or new_brightness == _pending_brightness)
		var color_matches = (_pending_color.r < 0 or new_color.is_equal_approx(_pending_color))
		
		if state_matches and brightness_matches and color_matches:
			_command_in_flight = false
		else:
			return  # Ignore this update, waiting for our command to be confirmed
	
	_initial_state_received = true
	
	var changed = false
	
	if new_state != is_on:
		is_on = new_state
		changed = true
		state_changed.emit(is_on)
	
	if new_brightness != brightness:
		brightness = new_brightness
		changed = true
		brightness_changed.emit(brightness)
	
	if not new_color.is_equal_approx(current_color):
		current_color = new_color
		changed = true
		color_changed.emit(current_color)
	
	if changed:
		external_control = true
		_apply_visual_state()

func _send_ha_command(turn_on: bool, send_brightness: int = -1, send_color: Color = Color(-1, -1, -1)) -> void:
	if _ha_client == null or ha_entity_id == "" or not sync_to_ha:
		return
	
	_command_in_flight = true
	_pending_state = turn_on
	_pending_brightness = send_brightness
	_pending_color = send_color
	_command_sent_time = 0.0
	
	if turn_on:
		# Build service data with optional brightness and color
		var service_data: Dictionary = {}
		
		if send_brightness >= 0:
			service_data["brightness"] = send_brightness
		
		if send_color.r >= 0:
			service_data["rgb_color"] = [
				int(send_color.r * 255),
				int(send_color.g * 255),
				int(send_color.b * 255)
			]
		
		# call_service supports optional service_data parameter
		_ha_client.call_service(_entity_domain, "turn_on", ha_entity_id, service_data)
	else:
		_ha_client.call_service(_entity_domain, "turn_off", ha_entity_id)

# ===== EDITOR POSITION TRACKING =====

func _check_bulb_positions() -> void:
	var bulbs = _get_bulb_nodes()
	var needs_rebuild = false
	
	for bulb in bulbs:
		var current_pos = bulb.position
		var last_pos = _last_bulb_positions.get(bulb, null)
		if last_pos == null or not current_pos.is_equal_approx(last_pos):
			needs_rebuild = true
			_last_bulb_positions[bulb] = current_pos
	
	if _last_bulb_positions.size() != bulbs.size():
		needs_rebuild = true
		_last_bulb_positions.clear()
		for bulb in bulbs:
			_last_bulb_positions[bulb] = bulb.position
	
	if needs_rebuild:
		_rebuild_wires()

# ===== SETUP =====

func _setup_materials() -> void:
	# Wire material
	_wire_material = StandardMaterial3D.new()
	_wire_material.albedo_color = wire_color
	_wire_material.roughness = 0.9
	
	# Create soft radial gradient texture for glow
	_glow_texture = GradientTexture2D.new()
	_glow_texture.width = 64
	_glow_texture.height = 64
	_glow_texture.fill = GradientTexture2D.FILL_RADIAL
	_glow_texture.fill_from = Vector2(0.5, 0.5)
	_glow_texture.fill_to = Vector2(0.5, 0.0)
	
	var gradient = Gradient.new()
	gradient.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	_glow_texture.gradient = gradient

func _ensure_wire_container() -> void:
	_wire_container = get_node_or_null("_WireContainer")
	if _wire_container == null:
		_wire_container = Node3D.new()
		_wire_container.name = "_WireContainer"
		add_child(_wire_container)
		_set_editor_owner(_wire_container)

# ===== BULB MANAGEMENT =====

func _get_bulb_nodes() -> Array[Node3D]:
	var bulbs: Array[Node3D] = []
	for child in get_children():
		if child is Node3D and child.name.begins_with("Bulb") and child != _wire_container:
			bulbs.append(child)
	bulbs.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return bulbs

func _add_new_bulb() -> void:
	var bulbs = _get_bulb_nodes()
	var new_index = bulbs.size()
	var new_pos = Vector3.ZERO
	
	if bulbs.size() >= 2:
		var last = bulbs[-1].position
		var second_last = bulbs[-2].position
		var direction = (last - second_last).normalized()
		new_pos = last + direction * bulb_spacing
	elif bulbs.size() == 1:
		new_pos = bulbs[0].position + Vector3(bulb_spacing, 0, 0)
	
	var bulb = Node3D.new()
	bulb.name = "Bulb_%d" % new_index
	bulb.position = new_pos
	add_child(bulb)
	_set_editor_owner(bulb)
	
	_rebuild_all()

func _apply_bulb_spacing() -> void:
	if not is_inside_tree():
		return
	
	var bulbs = _get_bulb_nodes()
	if bulbs.size() < 2:
		return
	
	var start_x = bulbs[0].position.x
	for i in range(1, bulbs.size()):
		var bulb = bulbs[i]
		var pos = bulb.position
		pos.x = start_x + (float(i) * bulb_spacing)
		bulb.position = pos
	
	_last_bulb_positions.clear()
	for bulb in bulbs:
		_last_bulb_positions[bulb] = bulb.position
	
	_rebuild_wires()

func _create_bulb_visuals(bulb_node: Node3D) -> void:
	# Check if visuals already exist
	if bulb_node.get_node_or_null("BulbMesh") != null:
		return
	
	# Create bulb mesh
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "BulbMesh"
	var sphere = SphereMesh.new()
	sphere.radius = bulb_radius
	sphere.height = bulb_radius * 2
	sphere.radial_segments = 12
	sphere.rings = 6
	mesh_instance.mesh = sphere
	
	# Create bulb material with emission support
	var bulb_mat = StandardMaterial3D.new()
	bulb_mat.albedo_color = bulb_color_off
	mesh_instance.material_override = bulb_mat
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bulb_node.add_child(mesh_instance)
	_set_editor_owner(mesh_instance)
	
	_bulb_meshes[bulb_node] = mesh_instance
	
	# Create omni light - this is what actually illuminates the scene
	var light = OmniLight3D.new()
	light.name = "Light"
	light.light_color = bulb_color_on
	light.light_energy = 0.0
	light.omni_range = light_range
	light.omni_attenuation = light_attenuation
	light.shadow_enabled = false  # Disable shadows for performance with many lights
	light.visible = false
	bulb_node.add_child(light)  # Add to bulb_node, not mesh, so it's at the bulb center
	_set_editor_owner(light)
	
	# Create soft glow sprite (billboard quad with radial gradient)
	var glow = MeshInstance3D.new()
	glow.name = "Glow"
	var quad = QuadMesh.new()
	quad.size = Vector2(bulb_radius * glow_size, bulb_radius * glow_size)
	glow.mesh = quad
	
	# Glow material with soft gradient texture
	var glow_mat = StandardMaterial3D.new()
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.albedo_color = Color(bulb_color_on.r, bulb_color_on.g, bulb_color_on.b, 0.0)
	glow_mat.albedo_texture = _glow_texture
	glow_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	glow_mat.billboard_keep_scale = true
	glow_mat.render_priority = 1  # Render after opaque objects
	glow.material_override = glow_mat
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.visible = false
	bulb_node.add_child(glow)
	_set_editor_owner(glow)

# ===== WIRE GENERATION =====

func _rebuild_all() -> void:
	if not is_inside_tree():
		return
	
	_ensure_wire_container()
	
	var bulbs = _get_bulb_nodes()
	for bulb in bulbs:
		_create_bulb_visuals(bulb)
	
	_rebuild_wires()
	_apply_visual_state()  # Apply current state to all visuals

func _rebuild_wires() -> void:
	if _wire_container == null or not is_inside_tree():
		return
	
	for child in _wire_container.get_children():
		child.queue_free()
	
	var bulbs = _get_bulb_nodes()
	if bulbs.size() < 2:
		return
	
	for i in range(bulbs.size() - 1):
		var start_pos = bulbs[i].position
		var end_pos = bulbs[i + 1].position
		_create_catenary_wire(start_pos, end_pos, i)

func _create_catenary_wire(start: Vector3, end: Vector3, index: int) -> void:
	var points = _calculate_catenary_points(start, end)
	for i in range(points.size() - 1):
		_create_wire_segment(points[i], points[i + 1], index, i)

func _calculate_catenary_points(start: Vector3, end: Vector3) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var horizontal_dist = Vector3(end.x - start.x, 0, end.z - start.z).length()
	var max_sag = horizontal_dist * sag_amount * 0.3
	
	for i in range(wire_segments + 1):
		var t = float(i) / float(wire_segments)
		var pos = start.lerp(end, t)
		var sag_factor = 4.0 * t * (1.0 - t)
		pos.y -= max_sag * sag_factor
		points.append(pos)
	
	return points

func _create_wire_segment(start: Vector3, end: Vector3, wire_index: int, segment_index: int) -> void:
	var direction = end - start
	var length = direction.length()
	
	if length < 0.001:
		return
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Wire_%d_%d" % [wire_index, segment_index]
	
	var cylinder = CylinderMesh.new()
	cylinder.top_radius = wire_thickness
	cylinder.bottom_radius = wire_thickness
	cylinder.height = length
	cylinder.radial_segments = 6
	cylinder.rings = 1
	mesh_instance.mesh = cylinder
	mesh_instance.material_override = _wire_material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	mesh_instance.position = (start + end) / 2.0
	mesh_instance.transform.basis = _create_alignment_basis(direction.normalized())
	
	_wire_container.add_child(mesh_instance)
	_set_editor_owner(mesh_instance)

func _create_alignment_basis(y_axis: Vector3) -> Basis:
	var y = y_axis.normalized()
	var not_parallel = Vector3.UP if abs(y.dot(Vector3.UP)) < 0.999 else Vector3.RIGHT
	var x = y.cross(not_parallel).normalized()
	var z = x.cross(y).normalized()
	return Basis(x, y, z)

# ===== VISUAL STATE =====

func _apply_visual_state() -> void:
	"""Apply the current on/off state to all visual elements"""
	if not is_inside_tree():
		return
	
	# In editor, use preview setting; at runtime, use actual is_on state
	var show_on = editor_preview_on if Engine.is_editor_hint() else is_on
	
	var bulbs = _get_bulb_nodes()
	for bulb in bulbs:
		_update_bulb_visual(bulb, show_on)

func _update_bulb_visual(bulb_node: Node3D, on: bool) -> void:
	"""Update a single bulb's visual state with current color and brightness"""
	# Calculate brightness factor (0.0 to 1.0)
	var brightness_factor: float = float(brightness) / 255.0
	
	# Get the active color (current_color when on, bulb_color_off when off)
	var active_color: Color = current_color if on else bulb_color_off
	
	# Update bulb mesh material
	var mesh = bulb_node.get_node_or_null("BulbMesh") as MeshInstance3D
	if mesh and mesh.material_override:
		var mat = mesh.material_override as StandardMaterial3D
		if on:
			mat.albedo_color = active_color
			mat.emission_enabled = true
			mat.emission = active_color
			mat.emission_energy_multiplier = 3.0 * brightness_factor
		else:
			mat.albedo_color = bulb_color_off
			mat.emission_enabled = false
	
	# Update omni light
	var light = bulb_node.get_node_or_null("Light") as OmniLight3D
	if light:
		light.visible = on
		light.light_energy = light_energy * brightness_factor if on else 0.0
		light.light_color = active_color
		light.omni_range = light_range
		light.omni_attenuation = light_attenuation
	
	# Update glow sprite
	var glow = bulb_node.get_node_or_null("Glow") as MeshInstance3D
	if glow:
		glow.visible = on and enable_glow
		
		if glow.mesh is QuadMesh:
			var quad = glow.mesh as QuadMesh
			quad.size = Vector2(bulb_radius * glow_size, bulb_radius * glow_size)
		
		if glow.material_override is StandardMaterial3D:
			var mat = glow.material_override as StandardMaterial3D
			var glow_alpha: float = glow_intensity * brightness_factor if on else 0.0
			mat.albedo_color = Color(active_color.r, active_color.g, active_color.b, glow_alpha)

func _update_wire_material() -> void:
	if _wire_material:
		_wire_material.albedo_color = wire_color

# ===== POWER SYSTEM INTEGRATION =====

func _connect_to_power_system() -> void:
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("hook_availability_deferred"):
		apb.call("hook_availability_deferred", self, Callable(self, "_on_power_availability_changed"))
		return
	var tree = get_tree()
	if tree == null:
		return
	var solar_ui = _find_solar_ui(tree.root)
	if solar_ui == null:
		if _connect_attempts < 40:
			_connect_attempts += 1
			get_tree().create_timer(0.25).timeout.connect(_connect_to_power_system, CONNECT_ONE_SHOT)
		return
	_connect_attempts = 0
	_solar_ui = solar_ui
	if solar_ui.has_signal("power_availability_changed"):
		if not solar_ui.power_availability_changed.is_connected(_on_power_availability_changed):
			solar_ui.power_availability_changed.connect(_on_power_availability_changed)
	if solar_ui.has_method("is_power_available"):
		_power_available = solar_ui.is_power_available()
	_update_lights()

func _find_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_power_available"):
		if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
			pass
		else:
			return node
	for child in node.get_children():
		var result = _find_solar_ui(child)
		if result != null:
			return result
	return null

func _on_power_availability_changed(available: bool) -> void:
	_power_available = available
	_update_lights()

# ===== LIGHT STATE MANAGEMENT =====

func _update_lights() -> void:
	var main_node = _get_main_node()
	if main_node == null:
		return
	
	var current_time: float = float(main_node.get("day_time")) if "day_time" in main_node else 12.0
	var sunrise: float = float(main_node.get("sunrise_hour")) if "sunrise_hour" in main_node else turn_off_hour
	var sunset: float = float(main_node.get("sunset_hour")) if "sunset_hour" in main_node else turn_on_hour
	
	var should_be_on: bool = false
	if sunset > sunrise:
		should_be_on = current_time >= sunset or current_time < sunrise
	else:
		should_be_on = current_time >= sunset and current_time < sunrise
	
	if should_be_on and not _power_available:
		should_be_on = false
	
	if should_be_on != is_on:
		is_on = should_be_on
		_apply_visual_state()
		state_changed.emit(is_on)

func set_lights_state(on: bool, from_external: bool = false) -> void:
	if from_external:
		external_control = true
	
	if on == is_on and not _command_in_flight:
		return
	
	is_on = on
	_apply_visual_state()
	state_changed.emit(is_on)
	
	if not from_external and sync_to_ha:
		_send_ha_command(on)

func toggle() -> void:
	set_lights_state(not is_on)

func turn_on() -> void:
	set_lights_state(true)

func turn_off() -> void:
	set_lights_state(false)

func _get_main_node() -> Node:
	if _main_node != null and is_instance_valid(_main_node):
		return _main_node
	
	var tree = get_tree()
	if tree == null:
		return null
	
	var root = tree.root
	if root == null:
		return null
	
	for child in root.get_children():
		if "day_time" in child:
			_main_node = child
			return _main_node
	
	var current_scene = tree.current_scene
	if current_scene and "day_time" in current_scene:
		_main_node = current_scene
		return _main_node
	
	return null

# ===== POWER CONSUMER INTERFACE =====

func get_current_power() -> float:
	return wattage if is_on else 0.0

func get_power_consumption() -> float:
	return get_current_power()

func is_consuming_power() -> bool:
	return is_on

func get_state() -> bool:
	return is_on

func get_brightness() -> int:
	return brightness

func get_color() -> Color:
	return current_color

# ===== INTERACTION SYSTEM =====

func _setup_interaction_area() -> void:
	"""Create Area3D for player detection"""
	if Engine.is_editor_hint():
		return
	
	_interaction_area = Area3D.new()
	_interaction_area.name = "InteractionArea"
	_interaction_area.collision_layer = 0
	_interaction_area.collision_mask = 1  # Detect player on layer 1
	add_child(_interaction_area)
	
	# Create collision shape centered on the light string
	var collision_shape = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = interaction_radius
	collision_shape.shape = sphere_shape
	_interaction_area.add_child(collision_shape)
	
	# Connect signals
	_interaction_area.body_entered.connect(_on_body_entered)
	_interaction_area.body_exited.connect(_on_body_exited)

func _find_interaction_ui() -> void:
	"""Find the InteractionPromptUI in the scene"""
	var tree = get_tree()
	if tree == null:
		return
	
	var root = tree.root
	for child in root.get_children():
		var ui_layer = child.get_node_or_null("UILayer")
		if ui_layer:
			_interaction_ui = ui_layer.get_node_or_null("InteractionPromptUI")
			if _interaction_ui:
				break

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_in_range = body
		_show_interaction_prompt()

func _on_body_exited(body: Node3D) -> void:
	if body == _player_in_range:
		_player_in_range = null
		_hide_interaction_prompt()
		if _menu_visible:
			_close_color_menu()

func _show_interaction_prompt() -> void:
	if _interaction_ui and _interaction_ui.has_method("show_prompt"):
		var state_text = "ON" if is_on else "OFF"
		var il : String = _interaction_ui.get_action_label("interact") if _interaction_ui.has_method("get_action_label") else "O"
		var ml : String = _interaction_ui.get_action_label("toggle_light_menu") if _interaction_ui.has_method("get_action_label") else "P"
		_interaction_ui.show_prompt("%s/%s" % [il, ml], "%s (%s) - %s:Toggle %s:Colors" % [display_name, state_text, il, ml])

func _hide_interaction_prompt() -> void:
	if _interaction_ui and _interaction_ui.has_method("hide_prompt"):
		_interaction_ui.hide_prompt()

func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return

	# Only handle input when player is in range
	if _player_in_range == null:
		return

	# Standing near a light is not a reason to steal keystrokes: both branches
	# below call set_input_as_handled(), so typing "o" or "p" into a text field
	# used to toggle the light and swallow the character.
	if InputGuard.blocked(get_viewport()):
		return

	# Check for toggle action (O key)
	if event.is_action_pressed("interact"):
		toggle()
		_show_interaction_prompt()  # Update prompt with new state
		get_viewport().set_input_as_handled()
		return
	
	# Check for menu action (P key / D-pad Up)
	if event.is_action_pressed("toggle_light_menu"):
		if _menu_visible:
			_close_color_menu()
		else:
			_open_color_menu()
		get_viewport().set_input_as_handled()
		return
	
	# Check for Escape to close menu
	if event.is_action_pressed("ui_cancel") and _menu_visible:
		_close_color_menu()
		get_viewport().set_input_as_handled()

# ===== COLOR/BRIGHTNESS MENU =====

func _open_color_menu() -> void:
	if _menu_visible:
		return
	
	_menu_visible = true
	_create_color_menu()
	
	# Release mouse for menu interaction
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _close_color_menu() -> void:
	if not _menu_visible:
		return
	
	_menu_visible = false
	
	if _color_menu != null:
		_color_menu.queue_free()
		_color_menu = null
	
	# Recapture mouse for gameplay
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _create_color_menu() -> void:
	"""Create a simple color/brightness control panel"""
	if _color_menu != null:
		_color_menu.queue_free()
	
	# Create main container
	_color_menu = Control.new()
	_color_menu.name = "GoveeLightsMenu"
	_color_menu.set_anchors_preset(Control.PRESET_CENTER)
	_color_menu.size = Vector2(320, 380)
	_color_menu.position = -_color_menu.size / 2
	
	# Add to UI layer or root
	var ui_parent = _get_ui_parent()
	if ui_parent:
		ui_parent.add_child(_color_menu)
	else:
		get_tree().root.add_child(_color_menu)
	
	# Background panel
	var panel = Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_color_menu.add_child(panel)
	
	# Apply dark theme
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.95)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.3, 0.3, 0.35)
	panel.add_theme_stylebox_override("panel", style)
	
	# Main VBox
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_color_menu.add_child(margin)
	margin.add_child(vbox)
	
	# Title
	var title = Label.new()
	title.text = display_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1, 1, 1))
	vbox.add_child(title)
	
	# On/Off Toggle Button
	var toggle_btn = Button.new()
	toggle_btn.text = "Turn OFF" if is_on else "Turn ON"
	toggle_btn.custom_minimum_size = Vector2(0, 40)
	toggle_btn.pressed.connect(_on_menu_toggle_pressed.bind(toggle_btn))
	vbox.add_child(toggle_btn)
	
	# Brightness section
	var brightness_label = Label.new()
	brightness_label.text = "Brightness: %d%%" % int(float(brightness) / 255.0 * 100)
	brightness_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(brightness_label)
	
	var brightness_slider = HSlider.new()
	brightness_slider.min_value = 10
	brightness_slider.max_value = 255
	brightness_slider.value = brightness
	brightness_slider.custom_minimum_size = Vector2(0, 30)
	brightness_slider.value_changed.connect(_on_brightness_changed.bind(brightness_label))
	vbox.add_child(brightness_slider)
	
	# Color section
	var color_label = Label.new()
	color_label.text = "Color"
	color_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(color_label)
	
	# Color grid (2 rows of 4)
	var color_grid = GridContainer.new()
	color_grid.columns = 4
	color_grid.add_theme_constant_override("h_separation", 8)
	color_grid.add_theme_constant_override("v_separation", 8)
	vbox.add_child(color_grid)
	
	for i in range(COLOR_PALETTE.size()):
		var color_btn = Button.new()
		color_btn.custom_minimum_size = Vector2(60, 50)
		color_btn.tooltip_text = COLOR_NAMES[i]
		
		# Create colored style
		var btn_style = StyleBoxFlat.new()
		btn_style.bg_color = COLOR_PALETTE[i]
		btn_style.corner_radius_top_left = 6
		btn_style.corner_radius_top_right = 6
		btn_style.corner_radius_bottom_left = 6
		btn_style.corner_radius_bottom_right = 6
		
		# Highlight if this is the current color
		if current_color.is_equal_approx(COLOR_PALETTE[i]):
			btn_style.border_width_left = 3
			btn_style.border_width_right = 3
			btn_style.border_width_top = 3
			btn_style.border_width_bottom = 3
			btn_style.border_color = Color(1, 1, 1)
		
		color_btn.add_theme_stylebox_override("normal", btn_style)
		color_btn.add_theme_stylebox_override("hover", btn_style)
		color_btn.add_theme_stylebox_override("pressed", btn_style)
		color_btn.pressed.connect(_on_color_selected.bind(i))
		color_grid.add_child(color_btn)
	
	# Close button
	var close_btn = Button.new()
	close_btn.text = "Close (Esc)"
	close_btn.custom_minimum_size = Vector2(0, 35)
	close_btn.pressed.connect(_close_color_menu)
	vbox.add_child(close_btn)

func _get_ui_parent() -> Node:
	"""Find the best parent for UI elements"""
	var tree = get_tree()
	if tree == null:
		return null
	
	var root = tree.root
	for child in root.get_children():
		var ui_layer = child.get_node_or_null("UILayer")
		if ui_layer:
			return ui_layer
	
	return tree.root

func _on_menu_toggle_pressed(btn: Button) -> void:
	toggle()
	btn.text = "Turn OFF" if is_on else "Turn ON"

func _on_brightness_changed(value: float, label: Label) -> void:
	brightness = int(value)
	label.text = "Brightness: %d%%" % int(float(brightness) / 255.0 * 100)
	_apply_visual_state()
	brightness_changed.emit(brightness)
	
	# Send to HA if on
	if is_on and sync_to_ha:
		_send_ha_command(true, brightness, Color(-1, -1, -1))

func _on_color_selected(color_index: int) -> void:
	current_color = COLOR_PALETTE[color_index]
	_apply_visual_state()
	color_changed.emit(current_color)
	
	# Send to HA if on
	if is_on and sync_to_ha:
		_send_ha_command(true, -1, current_color)
	
	# Refresh menu to show selection
	if _menu_visible:
		_create_color_menu()

# ===== PUBLIC API =====

func set_color(new_color: Color, sync: bool = true) -> void:
	"""Set the light color programmatically"""
	current_color = new_color
	_apply_visual_state()
	color_changed.emit(current_color)
	
	if sync and is_on and sync_to_ha:
		_send_ha_command(true, -1, current_color)

func set_brightness_value(new_brightness: int, sync: bool = true) -> void:
	"""Set the brightness programmatically (0-255)"""
	brightness = clampi(new_brightness, 0, 255)
	_apply_visual_state()
	brightness_changed.emit(brightness)
	
	if sync and is_on and sync_to_ha:
		_send_ha_command(true, brightness, Color(-1, -1, -1))
