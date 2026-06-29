class_name ElectricWaterHeater
extends Node3D

## Electric water heater with thermostat cycling simulation.
## Heats water when temperature drops below threshold, turns off when target reached.
## Realistic simulation of tank water heater behavior.

# ==================== SIGNALS ====================

signal temperature_changed(temp_celsius: float)
signal heating_started()
signal heating_stopped()

# ==================== CONFIGURATION ====================

@export_group("Water Heater Settings")

## Tank capacity in gallons
@export_range(10.0, 100.0, 1.0) var tank_capacity_gallons : float = 50.0

## Heating element power in Watts
@export_range(1000.0, 6000.0, 100.0) var heating_power_watts : float = 4500.0

## Standby power when not heating (controls, sensors)
@export_range(0.0, 50.0, 1.0) var standby_power_watts : float = 5.0

## Target water temperature in Celsius
@export_range(40.0, 80.0, 1.0) var target_temp_celsius : float = 60.0

## Temperature hysteresis (heater turns on when temp drops this much below target)
@export_range(2.0, 15.0, 1.0) var hysteresis_celsius : float = 5.0

## Heat loss rate (degrees per hour when idle)
@export_range(0.1, 5.0, 0.1) var heat_loss_rate : float = 1.0

@export_group("Device Identity")

## Device display name
@export var display_name : String = "Water Heater"

## Unique device ID (auto-generated if empty)
@export var device_id : String = ""

# ==================== STATE ====================

## Current water temperature
var current_temp_celsius : float = 55.0

## Whether heating element is active
var is_heating : bool = false

## Whether the heater is enabled (breaker on)
var is_enabled : bool = true

## PowerDevice component reference
var power_device : Node = null

# ==================== INTERNAL ====================

var _main_node : Node = null
var _sim_timer : float = 0.0
const _SIM_INTERVAL : float = 0.2

func _ready() -> void:
	_setup_power_device()
	# Start at a random temperature near target for variety
	current_temp_celsius = target_temp_celsius - randf_range(0.0, hysteresis_celsius * 1.5)

func _setup_power_device() -> void:
	# Check for existing PowerDevice child
	power_device = get_node_or_null("PowerDevice")
	
	if power_device == null:
		# Create PowerDevice dynamically
		var script := load("res://power_system/core/power_device.gd")
		if script:
			power_device = Node.new()
			power_device.set_script(script)
			power_device.name = "PowerDevice"
			add_child(power_device)
	
	if power_device != null:
		power_device.device_name = display_name if not display_name.is_empty() else name
		power_device.device_type = 2  # DeviceTypes.DeviceType.HVAC
		power_device.rated_power_watts = heating_power_watts
		power_device.standby_power_watts = standby_power_watts
		power_device.is_enabled = true
		
		if device_id.is_empty():
			var path_str : String = get_path().get_concatenated_names().to_snake_case()
			power_device.device_id = path_str.replace("/", "_").to_lower()
		else:
			power_device.device_id = device_id

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	
	_sim_timer += delta
	if _sim_timer < _SIM_INTERVAL:
		return
	var step := minf(_sim_timer, _SIM_INTERVAL * 2.0)
	_sim_timer -= _SIM_INTERVAL
	
	if not is_enabled:
		_set_heating(false)
		return
	
	# Get time scale from main scene
	var time_scale := _get_time_scale()
	var scaled_delta := step * time_scale
	
	# Simulate temperature changes
	_simulate_temperature(scaled_delta)
	
	# Thermostat control
	_update_thermostat()

func _simulate_temperature(scaled_delta: float) -> void:
	var old_temp := current_temp_celsius
	
	if is_heating:
		# Calculate heating rate
		# Energy = Power * Time
		# Temperature rise = Energy / (mass * specific heat)
		# Water: 4.186 kJ/(kg·°C), 1 gallon = 3.785 liters = 3.785 kg
		var water_mass_kg := tank_capacity_gallons * 3.785
		var specific_heat := 4186.0  # J/(kg·°C)
		var energy_joules := heating_power_watts * scaled_delta
		var temp_rise := energy_joules / (water_mass_kg * specific_heat)
		
		current_temp_celsius += temp_rise
	else:
		# Heat loss to environment
		# Simplified model: exponential decay toward ambient
		var ambient_temp := 20.0  # Room temperature
		var hours_elapsed := scaled_delta / 3600.0
		var temp_loss := heat_loss_rate * hours_elapsed
		
		# Only lose heat if above ambient
		if current_temp_celsius > ambient_temp:
			current_temp_celsius = maxf(ambient_temp, current_temp_celsius - temp_loss)
	
	if absf(current_temp_celsius - old_temp) > 0.1:
		temperature_changed.emit(current_temp_celsius)

func _update_thermostat() -> void:
	var turn_on_threshold := target_temp_celsius - hysteresis_celsius
	var turn_off_threshold := target_temp_celsius
	
	if not is_heating and current_temp_celsius < turn_on_threshold:
		_set_heating(true)
	elif is_heating and current_temp_celsius >= turn_off_threshold:
		_set_heating(false)

func _set_heating(heating: bool) -> void:
	if is_heating == heating:
		return
	
	is_heating = heating
	
	if power_device != null:
		if is_heating:
			power_device.turn_on()
			heating_started.emit()
		else:
			power_device.set_standby()
			heating_stopped.emit()

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

## Enable/disable the water heater (simulates breaker)
func set_enabled(enabled: bool) -> void:
	is_enabled = enabled
	if power_device != null:
		power_device.is_enabled = enabled
	if not enabled:
		_set_heating(false)

## Get current water temperature
func get_temperature() -> float:
	return current_temp_celsius

## Set target temperature
func set_target_temperature(temp: float) -> void:
	target_temp_celsius = clampf(temp, 40.0, 80.0)

## Check if currently heating
func is_currently_heating() -> bool:
	return is_heating

## Get current power consumption
func get_power_consumption() -> float:
	if power_device != null:
		return power_device.get_current_power()
	return heating_power_watts if is_heating else standby_power_watts

