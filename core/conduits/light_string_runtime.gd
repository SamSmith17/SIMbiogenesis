class_name LightStringRuntime
extends Node3D

## Shared bulbs-along-a-wire runtime (Wave 8), factored from GoveeLights'
## bulb-visual + day-night + power-consumer logic so conduit light kinds
## (led_strip / led_fairy / led_patio) reuse one path.
##
## ConduitManager owns one of these per light-kind connection: it calls
## configure() with the sampled bulb positions whenever the route rebuilds.
## Day/night switching mirrors govee_lights.gd `_update_lights` (sunset→sunrise
## from Main), and the node registers in "power_consumers" reporting
## watts_per_m × run length while lit.

const UPDATE_INTERVAL := 0.5
## Cap on real OmniLight3D children — bulbs beyond this stay emissive-only
## (shadowless omnis are cheap but not free; long fairy strings can have 100s).
const MAX_OMNI_LIGHTS := 16

var type_id: String = ""
var run_length_m: float = 0.0
var watts_per_m: float = 0.0
var light_color: Color = Color(1.0, 0.9, 0.7, 1.0)
var bulb_radius: float = 0.03
var is_on: bool = false
var severed: bool = false

var _bulb_multimesh: MultiMeshInstance3D = null
var _strip_mesh: MeshInstance3D = null
var _lights: Array[OmniLight3D] = []
var _bulb_mat: StandardMaterial3D = null
var _main_node: Node = null
var _power_available: bool = true
var _timer: float = 0.0


func _ready() -> void:
	add_to_group("power_consumers")
	_timer = randf() * UPDATE_INTERVAL
	call_deferred("_connect_to_power_system")


## (Re)build bulb visuals for the given sampled positions (local to this node).
func configure(kind_id: String, bulb_positions: PackedVector3Array,
		length_m: float) -> void:
	type_id = kind_id
	run_length_m = maxf(length_m, 0.0)
	var meta: Dictionary = ConduitKinds.type_meta(kind_id)
	watts_per_m = float(meta.get("watts_per_m", 0.0))
	light_color = meta.get("light_color", Color(1.0, 0.9, 0.7, 1.0)) as Color
	bulb_radius = maxf(float(meta.get("radius_m", 0.004)) * 5.0, 0.015)
	_rebuild_bulbs(bulb_positions)
	_apply_visual_state()


func _rebuild_bulbs(positions: PackedVector3Array) -> void:
	for l: OmniLight3D in _lights:
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	if _bulb_multimesh != null and is_instance_valid(_bulb_multimesh):
		_bulb_multimesh.queue_free()
		_bulb_multimesh = null
	if positions.is_empty():
		return
	# Bulb spheres in one MultiMesh (hundreds of fairy bulbs = 1 draw call).
	var sphere := SphereMesh.new()
	sphere.radius = bulb_radius
	sphere.height = bulb_radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_bulb_mat = StandardMaterial3D.new()
	_bulb_mat.albedo_color = Color(0.15, 0.12, 0.08, 1.0)
	sphere.material = _bulb_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = positions.size()
	for i: int in range(positions.size()):
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, positions[i]))
	_bulb_multimesh = MultiMeshInstance3D.new()
	_bulb_multimesh.name = "Bulbs"
	_bulb_multimesh.multimesh = mm
	_bulb_multimesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bulb_multimesh)
	# Real omni lights on a subset of bulbs, spread evenly along the run.
	var light_count: int = mini(positions.size(), MAX_OMNI_LIGHTS)
	for li: int in range(light_count):
		var idx: int = int(floorf(float(li) * float(positions.size()) / float(light_count)))
		var light := OmniLight3D.new()
		light.light_color = light_color
		light.light_energy = 0.0
		light.omni_range = 2.0
		light.omni_attenuation = 1.5
		light.shadow_enabled = false
		light.visible = false
		light.position = positions[idx]
		add_child(light)
		_lights.append(light)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < UPDATE_INTERVAL:
		return
	_timer -= UPDATE_INTERVAL
	_update_lights()


## Same schedule as govee_lights.gd: on from sunset to sunrise, gated by power.
func _update_lights() -> void:
	var main_node := _get_main_node()
	if main_node == null:
		return
	var current_time: float = float(main_node.get("day_time")) if "day_time" in main_node else 12.0
	var sunrise: float = float(main_node.get("sunrise_hour")) if "sunrise_hour" in main_node else 6.0
	var sunset: float = float(main_node.get("sunset_hour")) if "sunset_hour" in main_node else 18.0
	var should_be_on: bool = false
	if sunset > sunrise:
		should_be_on = current_time >= sunset or current_time < sunrise
	else:
		should_be_on = current_time >= sunset and current_time < sunrise
	if severed or not _power_available:
		should_be_on = false
	if should_be_on != is_on:
		is_on = should_be_on
		_apply_visual_state()


func set_severed(value: bool) -> void:
	if severed == value:
		return
	severed = value
	if severed and is_on:
		is_on = false
		_apply_visual_state()


## Register the conduit tube mesh of a continuous strip so its material can
## flip between lit-emissive and off along with the schedule.
func set_strip_mesh(mi: MeshInstance3D) -> void:
	_strip_mesh = mi
	_apply_visual_state()


func _apply_visual_state() -> void:
	if _strip_mesh != null and is_instance_valid(_strip_mesh) and not type_id.is_empty():
		_strip_mesh.material_override = make_strip_material(type_id, is_on)
	if _bulb_mat != null:
		if is_on:
			_bulb_mat.albedo_color = light_color
			_bulb_mat.emission_enabled = true
			_bulb_mat.emission = light_color
			_bulb_mat.emission_energy_multiplier = 3.0
		else:
			_bulb_mat.albedo_color = Color(0.15, 0.12, 0.08, 1.0)
			_bulb_mat.emission_enabled = false
	for light: OmniLight3D in _lights:
		if not is_instance_valid(light):
			continue
		light.visible = is_on
		light.light_energy = 1.0 if is_on else 0.0


## Make an emissive material for continuous strips (bulb_spacing_m == 0):
## the tube itself glows instead of discrete bulbs.
static func make_strip_material(kind_id: String, lit: bool) -> StandardMaterial3D:
	var mat := ConduitKinds.make_material(kind_id)
	if lit:
		var meta: Dictionary = ConduitKinds.type_meta(kind_id)
		var col: Color = meta.get("light_color", Color(1.0, 0.9, 0.8, 1.0)) as Color
		mat.albedo_color = col
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 2.0
	return mat


# ===== Power-consumer interface (same shape as govee_lights.gd) =====

func get_current_power() -> float:
	return watts_per_m * run_length_m if is_on else 0.0


func get_power_consumption() -> float:
	return get_current_power()


func is_consuming_power() -> bool:
	return is_on


func _connect_to_power_system() -> void:
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("hook_availability_deferred"):
		apb.call("hook_availability_deferred", self, Callable(self, "_on_power_availability_changed"))


func _on_power_availability_changed(available: bool) -> void:
	_power_available = available
	_update_lights()


func _get_main_node() -> Node:
	if _main_node != null and is_instance_valid(_main_node):
		return _main_node
	var tree := get_tree()
	if tree == null:
		return null
	for child in tree.root.get_children():
		if "day_time" in child:
			_main_node = child
			return _main_node
	var cs := tree.current_scene
	if cs != null and "day_time" in cs:
		_main_node = cs
	return _main_node
