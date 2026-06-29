class_name ElectricKettle
extends Node3D

## Electric kettle with boil cycle simulation.
## Heats water from ambient to boiling, then auto-shutoff.
## Can be triggered manually or via automation.

# ==================== SIGNALS ====================

signal boil_started()
signal boil_complete()
signal temperature_changed(temp_celsius: float)

# ==================== CONFIGURATION ====================

@export_group("Kettle Settings")

## Kettle capacity in liters
@export_range(0.5, 3.0, 0.1) var capacity_liters : float = 1.7

## Heating element power in Watts
@export_range(1000.0, 3000.0, 100.0) var heating_power_watts : float = 1500.0

## Boiling point (adjustable for altitude)
@export_range(90.0, 100.0, 0.5) var boiling_point_celsius : float = 100.0

## Starting water temperature (ambient)
@export_range(10.0, 30.0, 1.0) var ambient_temp_celsius : float = 20.0

@export_group("Device Identity")

## Device display name
@export var display_name : String = "Electric Kettle"

## Unique device ID
@export var device_id : String = ""

# ==================== STATE ====================

## Current water temperature
var current_temp_celsius : float = 20.0

## Whether kettle is currently boiling
var is_boiling : bool = false

## Whether kettle has water (needs refill after boil)
var has_water : bool = true

## PowerDevice component
var power_device : Node = null

# ==================== INTERNAL ====================

var _main_node : Node = null
var _sim_timer : float = 0.0
const _SIM_INTERVAL : float = 0.1

func _ready() -> void:
	_setup_power_device()
	current_temp_celsius = ambient_temp_celsius

func _setup_power_device() -> void:
	power_device = get_node_or_null("PowerDevice")
	
	if power_device == null:
		var script := load("res://power_system/core/power_device.gd")
		if script:
			power_device = Node.new()
			power_device.set_script(script)
			power_device.name = "PowerDevice"
			add_child(power_device)
	
	if power_device != null:
		power_device.device_name = display_name if not display_name.is_empty() else name
		power_device.device_type = 1  # DeviceTypes.DeviceType.APPLIANCE
		power_device.rated_power_watts = heating_power_watts
		power_device.standby_power_watts = 0.0
		power_device.is_enabled = true
		
		if device_id.is_empty():
			var path_str : String = get_path().get_concatenated_names().to_snake_case()
			power_device.device_id = path_str.replace("/", "_").to_lower()
		else:
			power_device.device_id = device_id

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	
	if not is_boiling:
		return
	
	_sim_timer += delta
	if _sim_timer < _SIM_INTERVAL:
		return
	var step := minf(_sim_timer, _SIM_INTERVAL * 2.0)
	_sim_timer -= _SIM_INTERVAL
	
	var time_scale := _get_time_scale()
	var scaled_delta := step * time_scale
	
	_simulate_heating(scaled_delta)

func _simulate_heating(scaled_delta: float) -> void:
	if not has_water:
		_stop_boiling()
		return
	
	var old_temp := current_temp_celsius
	
	# Calculate heating rate
	# Water mass in kg (1 liter = 1 kg)
	var water_mass_kg := capacity_liters
	var specific_heat := 4186.0  # J/(kg·°C)
	var energy_joules := heating_power_watts * scaled_delta
	var temp_rise := energy_joules / (water_mass_kg * specific_heat)
	
	current_temp_celsius = minf(boiling_point_celsius, current_temp_celsius + temp_rise)
	
	if absf(current_temp_celsius - old_temp) > 0.5:
		temperature_changed.emit(current_temp_celsius)
	
	# Check if boiling complete
	if current_temp_celsius >= boiling_point_celsius:
		_complete_boil()

func _start_boiling() -> void:
	if is_boiling or not has_water:
		return
	
	is_boiling = true
	
	if power_device != null:
		power_device.turn_on()
	
	boil_started.emit()

func _stop_boiling() -> void:
	if not is_boiling:
		return
	
	is_boiling = false
	
	if power_device != null:
		power_device.turn_off()

func _complete_boil() -> void:
	_stop_boiling()
	has_water = false  # Water is "used" after boiling
	boil_complete.emit()

func _get_time_scale() -> float:
	if _main_node == null:
		_main_node = _find_main_node()
	
	if _main_node != null and "time_scale" in _main_node:
		return float(_main_node.time_scale)
	
	return 1.0

func _find_main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	
	var root : Window = tree.root
	for child in root.get_children():
		if "day_time" in child:
			return child
	
	return null

# ==================== PUBLIC API ====================

## Start boiling water
func start_boil() -> void:
	if has_water:
		_start_boiling()

## Alias for automation compatibility
func turn_on() -> void:
	start_boil()

## Stop boiling (cancel)
func turn_off() -> void:
	_stop_boiling()

## Refill the kettle with water
func refill() -> void:
	has_water = true
	current_temp_celsius = ambient_temp_celsius

## Get current temperature
func get_temperature() -> float:
	return current_temp_celsius

## Check if kettle has water
func is_filled() -> bool:
	return has_water

## Check if currently boiling
func is_currently_boiling() -> bool:
	return is_boiling

## Get boil progress (0-100%)
func get_boil_progress() -> float:
	if not has_water:
		return 0.0
	var range_temp := boiling_point_celsius - ambient_temp_celsius
	var current_progress := current_temp_celsius - ambient_temp_celsius
	return clampf((current_progress / range_temp) * 100.0, 0.0, 100.0)

## Get power consumption
func get_power_consumption() -> float:
	if power_device != null:
		return power_device.get_current_power()
	return heating_power_watts if is_boiling else 0.0

## Get estimated time to boil in seconds (real time)
func get_time_to_boil() -> float:
	if not has_water or is_boiling == false:
		return 0.0
	
	var temp_diff := boiling_point_celsius - current_temp_celsius
	if temp_diff <= 0:
		return 0.0
	
	var water_mass_kg := capacity_liters
	var specific_heat := 4186.0
	var energy_needed := water_mass_kg * specific_heat * temp_diff
	
	return energy_needed / heating_power_watts

