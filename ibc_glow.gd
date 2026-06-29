class_name IBCGlow
extends Node

## Applies a green emissive glow to the IBC tank meshes, simulating
## translucent plastic lit from within. Fades out during the day (sunlight
## overpowers the glow) and fades in at dusk/night, matching real-world behavior.

@export_group("Glow Material")
@export var glow_color : Color = Color(0.0, 1.0, 0.15, 1.0)
@export_range(0.0, 20.0, 0.1) var emission_energy : float = 5.5
@export_range(0.0, 1.0, 0.01) var albedo_opacity : float = 1.0
@export_range(0.0, 1.0, 0.01) var night_roughness : float = 0.7
@export_range(0.0, 1.0, 0.01) var night_tint_strength : float = 0.22

@export_group("Day Plastic Look")
@export var day_albedo_color : Color = Color(0.93, 0.95, 0.92, 1.0)
@export var day_backlight_color : Color = Color(0.95, 0.99, 0.95, 1.0)
@export_range(0.0, 1.0, 0.01) var day_backlight_strength : float = 0.42
@export_range(0.0, 1.0, 0.01) var day_roughness : float = 0.68
@export_range(0.0, 1.0, 0.01) var day_specular : float = 0.42
@export var opaque_diffuse_translucency : bool = true

@export_group("Interior Light")
@export var light_enabled : bool = true
@export var light_color : Color = Color(0.0, 1.0, 0.15, 1.0)
@export_range(0.0, 20.0, 0.1) var light_energy : float = 5.0
@export_range(0.0, 30.0, 0.1) var light_range : float = 11.0
@export_range(0.0, 1.0, 0.01) var light_attenuation : float = 0.7

@export_group("Mesh Targets")
@export var target_mesh_names : PackedStringArray = PackedStringArray(["Mesh36", "Mesh73"])

@export var wattage : float = 20.0
@export var display_name : String = "IBC Glow Lights"

var _material : StandardMaterial3D
var _found_meshes : Array[MeshInstance3D] = []
var _omni_lights : Array[OmniLight3D] = []
var _sun : DirectionalLight3D
var _night_factor : float = 0.0
var _target_night_factor : float = 0.0
var _update_timer : float = 0.0
var _solar_ui : Node = null
var _power_available : bool = true
var _glow_enabled : bool = true
var _graph_item_id : String = ""
var _graph_view : Node = null
var _connect_attempts : int = 0
const _UPDATE_INTERVAL : float = 0.25

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("power_consumers")
	_material = _create_glow_material()
	_update_timer = randf() * _UPDATE_INTERVAL
	call_deferred("_connect_to_power_system")
	call_deferred("_apply_glow")
	call_deferred("_find_sun")
	call_deferred("_deregister_child_powerdevice")
	call_deferred("_register_graph_load_node")


func _exit_tree() -> void:
	_unregister_graph_load_node()


## The child PowerDevice was the old power-reporting path.  IBCGlow now owns
## the power_consumers slot directly so there is no double-counting.
func _deregister_child_powerdevice() -> void:
	var pd := get_node_or_null("PowerDevice")
	if is_instance_valid(pd) and pd.is_in_group("power_consumers"):
		pd.remove_from_group("power_consumers")


## Called by SceneNodeAction automations — re-enables autonomous glow logic.
func turn_on() -> void:
	_glow_enabled = true


## Called by SceneNodeAction automations — forces glow off until next turn_on().
func turn_off() -> void:
	_glow_enabled = false


func get_current_power() -> float:
	return wattage if (_night_factor > 0.05 and _glow_enabled and _power_available) else 0.0

func _connect_to_power_system() -> void:
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("hook_availability_deferred"):
		apb.call("hook_availability_deferred", self, Callable(self, "_on_power_availability_changed"))
		return
	var tree : SceneTree = get_tree()
	if tree == null:
		return
	var solar_ui : Node = _find_solar_ui(tree.root)
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

func _find_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_power_available"):
		if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
			pass
		else:
			return node
	for child in node.get_children():
		var result := _find_solar_ui(child)
		if result != null:
			return result
	return null

func _on_power_availability_changed(available: bool) -> void:
	_power_available = available
	_apply_night_fade()

func _find_sun() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.root
	if root == null:
		return
	_sun = _find_node_by_type_and_name(root, "Sun") as DirectionalLight3D

func _find_node_by_type_and_name(node: Node, target_name: String) -> Node:
	if node.name == target_name and node is DirectionalLight3D:
		return node
	for child in node.get_children():
		var result := _find_node_by_type_and_name(child, target_name)
		if result != null:
			return result
	return null

func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _material == null:
		return
	_update_timer += _delta
	if _update_timer >= _UPDATE_INTERVAL:
		_update_timer -= _UPDATE_INTERVAL
		_update_night_factor()
	_night_factor = lerpf(_night_factor, _target_night_factor, clampf(_delta * 5.0, 0.0, 1.0))
	_apply_night_fade()

func _update_night_factor() -> void:
	if not _glow_enabled:
		_target_night_factor = 0.0
		return
	if not is_instance_valid(_sun):
		_target_night_factor = 1.0
		return
	var sun_dir := _sun.to_global(Vector3(0.0, 0.0, 1.0)).normalized()
	var sun_height := sun_dir.y
	# sun_height > 0.1 = full day (glow off), sun_height < -0.05 = full night (glow on)
	_target_night_factor = smoothstep(0.1, -0.05, sun_height)
	_sync_graph_load_node()


func _register_graph_load_node() -> void:
	if Engine.is_editor_hint() or not _graph_item_id.is_empty():
		return
	var tree := get_tree()
	if tree == null:
		return
	_graph_view = tree.root.find_child("SystemGraphView", true, false)
	if _graph_view == null or not ("model" in _graph_view):
		return
	var model: Variant = _graph_view.get("model")
	if model == null or not model.has_method("add_item"):
		return
	_graph_item_id = "ibc_glow_%d" % get_instance_id()
	var dev_path := str(get_path())
	model.add_item({
		"id": _graph_item_id,
		"type": "acload",
		"x": 520.0 + float(get_instance_id() % 120),
		"y": 360.0 + float((get_instance_id() / 120) % 80),
		"width": 140.0,
		"height": 90.0,
		"scope_id": "root",
		"specs": {
			"name": display_name,
			"max_watts": wattage,
			"avg_watts": 0.0,
			"scene_device_path": dev_path,
			"current_output_kw": 0.0,
		},
		"is_virtual": false,
		"device_path": dev_path,
	})


func _sync_graph_load_node() -> void:
	if _graph_item_id.is_empty() or _graph_view == null:
		return
	if not ("model" in _graph_view):
		return
	var model: Variant = _graph_view.get("model")
	if model == null or not model.has_method("update_item"):
		return
	var live_w := get_current_power()
	var kw := live_w / 1000.0
	var item: Dictionary = model.get_item(_graph_item_id) if model.has_method("get_item") else {}
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["name"] = display_name
	specs["max_watts"] = wattage
	specs["avg_watts"] = live_w
	specs["scene_device_path"] = str(get_path())
	specs["current_output_kw"] = kw
	model.update_item(_graph_item_id, {"specs": specs})


func _unregister_graph_load_node() -> void:
	if _graph_item_id.is_empty():
		return
	if _graph_view != null and is_instance_valid(_graph_view) and ("model" in _graph_view):
		var model: Variant = _graph_view.get("model")
		if model != null and model.has_method("remove_item"):
			model.remove_item(_graph_item_id)
	_graph_item_id = ""
	_graph_view = null

func _apply_night_fade() -> void:
	var effective_night : float = _night_factor if _power_available else 0.0
	if _material != null:
		_material.emission_energy_multiplier = emission_energy * effective_night
		var day_albedo := Color(day_albedo_color.r, day_albedo_color.g, day_albedo_color.b, albedo_opacity)
		# Keep the tank mostly white at night, but let the green glow tint it softly.
		var glow_tinted_albedo := Color(
			lerpf(day_albedo.r, maxf(day_albedo.r, glow_color.r * 0.45 + 0.55), night_tint_strength),
			lerpf(day_albedo.g, maxf(day_albedo.g, glow_color.g * 0.45 + 0.55), night_tint_strength),
			lerpf(day_albedo.b, maxf(day_albedo.b, glow_color.b * 0.45 + 0.55), night_tint_strength),
			albedo_opacity
		)
		_material.albedo_color = day_albedo.lerp(glow_tinted_albedo, effective_night)
		_material.roughness = lerpf(day_roughness, night_roughness, effective_night)
		var base_backlight := day_backlight_color * day_backlight_strength
		_material.backlight = base_backlight + (glow_color * 0.6 * effective_night)
		if opaque_diffuse_translucency:
			_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		else:
			_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	for light in _omni_lights:
		if is_instance_valid(light):
			light.light_energy = light_energy * effective_night
			light.visible = effective_night > 0.01

	# Drive a child SpotLight3D (accent light) with night factor.
	var spot := get_parent().get_node_or_null("SpotLight3D") if get_parent() != null else null
	if spot is SpotLight3D:
		(spot as SpotLight3D).light_energy = 0.795 * effective_night

	# Drive a child PowerDevice (20 W draw when glow is active).
	var pd: Node = get_node_or_null("PowerDevice")
	if is_instance_valid(pd) and pd.has_method("turn_on"):
		if effective_night > 0.05:
			pd.call("turn_on")
		else:
			pd.call("turn_off")

func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _create_glow_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(day_albedo_color.r, day_albedo_color.g, day_albedo_color.b, albedo_opacity)
	mat.roughness = day_roughness
	mat.metallic = 0.0
	mat.metallic_specular = day_specular
	mat.emission_enabled = true
	mat.emission = glow_color
	mat.emission_energy_multiplier = 0.0
	mat.backlight_enabled = true
	mat.backlight = day_backlight_color * day_backlight_strength
	if opaque_diffuse_translucency:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	return mat

func _apply_glow() -> void:
	var starshade := get_parent()
	if starshade == null:
		push_warning("IBCGlow: No parent node found")
		return

	_found_meshes.clear()
	_find_target_meshes(starshade)

	if _found_meshes.is_empty():
		push_warning("IBCGlow: No IBC meshes found matching: %s" % str(target_mesh_names))
		return

	for mesh in _found_meshes:
		mesh.material_override = _material

	if light_enabled:
		_add_interior_lights()

func _find_target_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		for target_name in target_mesh_names:
			if node.name == target_name:
				_found_meshes.append(node as MeshInstance3D)
				break
	for child in node.get_children():
		_find_target_meshes(child)

func _add_interior_lights() -> void:
	for old_light in _omni_lights:
		if is_instance_valid(old_light):
			old_light.queue_free()
	_omni_lights.clear()

	for mesh in _found_meshes:
		var aabb := mesh.get_aabb()
		var center := mesh.to_global(aabb.get_center())

		var light := OmniLight3D.new()
		light.name = "IBCGlowLight_%s" % mesh.name
		light.light_color = light_color
		light.light_energy = 0.0
		light.omni_range = light_range
		light.omni_attenuation = light_attenuation
		light.shadow_enabled = false
		light.light_bake_mode = Light3D.BAKE_DISABLED
		light.light_indirect_energy = 0.0
		light.light_volumetric_fog_energy = 0.0
		light.light_specular = 0.0
		light.distance_fade_enabled = true
		light.distance_fade_begin = light_range * 0.8
		light.distance_fade_length = light_range * 0.2
		light.visible = false

		get_parent().add_child(light)
		light.global_position = center
		_omni_lights.append(light)
