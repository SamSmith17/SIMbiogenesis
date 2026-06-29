@tool
extends Node3D

## String lights that automatically turn on at night and off during the day.
## Bulbs have halos and omni lights that respond to the day/night cycle.
## Implements power consumer interface directly for reliable power tracking.

@export var light_energy : float = 0.3
@export var halo_opacity : float = 0.8
@export_range(0.0, 24.0) var turn_on_hour : float = 18.0  # 6 PM
@export_range(0.0, 24.0) var turn_off_hour : float = 6.0  # 6 AM

## Power consumption of this string light strand in Watts
@export_range(1.0, 500.0, 1.0) var wattage : float = 40.0

## Human-readable name for this light string
@export var display_name : String = "String Lights"

## When true, external systems (like HA) control the lights instead of time-of-day
var external_control : bool = false

var bulbs_node : Node3D
var is_on : bool = false
var _main_node : Node = null
var _solar_ui : Node = null
var _power_available : bool = true
var _connect_attempts : int = 0
var _update_timer : float = 0.0
const _UPDATE_INTERVAL : float = 0.25

func _ready() -> void:
	bulbs_node = get_node_or_null("Bulbs")
	
	if not Engine.is_editor_hint():
		# Add to power consumers group for power tracking
		add_to_group("power_consumers")
		_update_timer = randf() * _UPDATE_INTERVAL
		# Find and connect to solar UI for power availability
		call_deferred("_connect_to_power_system")
		# Initial state update
		call_deferred("_update_lights")

## Connect to the power system to monitor power availability
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
		var result := _find_solar_ui(child)
		if result != null:
			return result
	
	return null

func _on_power_availability_changed(available: bool) -> void:
	_power_available = available
	# Immediately update lights when power availability changes
	_update_lights()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Skip auto updates if externally controlled (e.g., by Home Assistant)
	if external_control:
		return
	_update_timer += _delta
	if _update_timer >= _UPDATE_INTERVAL:
		_update_timer -= _UPDATE_INTERVAL
		_update_lights()

## Returns current power consumption in Watts
func get_current_power() -> float:
	return wattage if is_on else 0.0

## Alias for compatibility
func get_power_consumption() -> float:
	return get_current_power()

## Returns whether the lights are currently on
func is_consuming_power() -> bool:
	return is_on

func _update_lights() -> void:
	var main_node : Node = _get_main_node()
	if main_node == null:
		return
	
	var current_time : float = float(main_node.get("day_time")) if "day_time" in main_node else 12.0
	
	# Use calculated sunrise/sunset from main.gd if available (based on latitude/date)
	# Otherwise fall back to the configured turn_on/turn_off hours
	var sunrise : float = float(main_node.get("sunrise_hour")) if "sunrise_hour" in main_node else turn_off_hour
	var sunset : float = float(main_node.get("sunset_hour")) if "sunset_hour" in main_node else turn_on_hour
	
	# Determine if lights should be on (between sunset and sunrise)
	var should_be_on : bool = false
	if sunset > sunrise:
		# Normal case: sunset is later in the day than sunrise
		should_be_on = current_time >= sunset or current_time < sunrise
	else:
		# Edge case: polar regions where sunset < sunrise (polar night)
		should_be_on = current_time >= sunset and current_time < sunrise
	
	# Check power availability - if no power, lights can't be on
	if should_be_on and not _power_available:
		should_be_on = false
	
	# Only update visuals if state changed
	if should_be_on != is_on:
		is_on = should_be_on
		_set_lights_state(is_on)

## Set lights state - can be called externally by HA switch or other systems
func set_lights_state(on: bool, from_external: bool = false) -> void:
	if from_external:
		external_control = true
	is_on = on
	_set_lights_state(on)

func _set_lights_state(on: bool) -> void:
	if bulbs_node == null:
		return
	
	for bulb in bulbs_node.get_children():
		if bulb is MeshInstance3D:
			# Update the bulb material emission
			var material : Material = bulb.material_override
			if material is StandardMaterial3D:
				var std_mat : StandardMaterial3D = material as StandardMaterial3D
				if on:
					std_mat.albedo_color = Color(1.0, 0.85, 0.6, 1.0)
					std_mat.emission_enabled = true
					std_mat.emission = Color(1.0, 0.85, 0.6, 1.0)
					std_mat.emission_energy_multiplier = 2.0
				else:
					std_mat.albedo_color = Color(0.1, 0.085, 0.06, 0.1)
					std_mat.emission_enabled = false
			
			# Update the OmniLight3D child
			var light : Node = bulb.get_node_or_null("Light")
			if light is OmniLight3D:
				var omni : OmniLight3D = light as OmniLight3D
				omni.visible = on
				omni.light_energy = light_energy if on else 0.0
			
			# Update the Halo child
			var halo : Node = bulb.get_node_or_null("Halo")
			if halo is MeshInstance3D:
				var halo_mesh : MeshInstance3D = halo as MeshInstance3D
				halo_mesh.visible = on
				var halo_mat : Material = halo_mesh.material_override
				if halo_mat is StandardMaterial3D:
					var halo_std : StandardMaterial3D = halo_mat as StandardMaterial3D
					halo_std.albedo_color.a = halo_opacity if on else 0.0

func _get_main_node() -> Node:
	# Cache the main node reference
	if _main_node != null and is_instance_valid(_main_node):
		return _main_node
	
	var tree : SceneTree = get_tree()
	if tree == null:
		return null
	
	var root : Window = tree.root
	if root == null:
		return null
	
	# Look for the main scene node that has day_time property
	for child in root.get_children():
		if "day_time" in child:
			_main_node = child
			return _main_node
	
	# Try getting the current scene
	var current_scene : Node = tree.current_scene
	if current_scene and "day_time" in current_scene:
		_main_node = current_scene
		return _main_node
	
	return null
