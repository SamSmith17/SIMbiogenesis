class_name LaptopCharger
extends Node3D

## Laptop charger with battery simulation.
## Simulates realistic charging curve and discharge when unplugged.
## Power draw varies based on battery level (CC/CV charging).

# ==================== SIGNALS ====================

signal battery_changed(percent: float)
signal charging_started()
signal charging_stopped()
signal fully_charged()
signal low_battery(percent: float)

# ==================== CONFIGURATION ====================

@export_group("Battery Settings")

## Battery capacity in Watt-hours
@export_range(30.0, 100.0, 1.0) var battery_capacity_wh : float = 60.0

## Maximum charging power in Watts (during CC phase)
@export_range(30.0, 140.0, 5.0) var max_charging_power_watts : float = 65.0

## Idle power consumption when laptop is on (screen, CPU, etc.)
@export_range(5.0, 50.0, 1.0) var idle_power_watts : float = 15.0

## Power consumption during active use
@export_range(15.0, 100.0, 5.0) var active_power_watts : float = 35.0

## Low battery warning threshold (percent)
@export_range(5.0, 30.0, 1.0) var low_battery_threshold : float = 20.0

@export_group("Charging Behavior")

## CC to CV transition point (percent)
@export_range(70.0, 90.0, 1.0) var cv_transition_percent : float = 80.0

## Charging efficiency (accounts for heat loss)
@export_range(0.8, 0.98, 0.01) var charging_efficiency : float = 0.90

@export_group("Device Identity")

## Device display name
@export var display_name : String = "Laptop Charger"

## Unique device ID
@export var device_id : String = ""

# ==================== STATE ====================

## Current battery level (0-100%)
var battery_percent : float = 50.0

## Whether charger is plugged in
var is_plugged_in : bool = true

## Whether laptop is powered on
var is_laptop_on : bool = true

## Current usage mode (idle vs active)
var is_active_use : bool = false

## PowerDevice component
var power_device : Node = null

# ==================== INTERNAL ====================

var _main_node : Node = null
var _low_battery_warned : bool = false
var _sim_timer : float = 0.0
const _SIM_INTERVAL : float = 0.2

func _ready() -> void:
	_setup_power_device()
	# Random starting battery level
	battery_percent = randf_range(30.0, 80.0)

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
		power_device.device_type = 3  # DeviceTypes.DeviceType.CHARGER
		power_device.rated_power_watts = max_charging_power_watts
		power_device.standby_power_watts = 0.5  # Tiny vampire draw
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
	
	var time_scale := _get_time_scale()
	var scaled_delta := step * time_scale
	
	_simulate_battery(scaled_delta)
	_update_power_device()

func _simulate_battery(scaled_delta: float) -> void:
	var old_percent := battery_percent
	var hours_elapsed := scaled_delta / 3600.0
	
	if is_plugged_in:
		# Charging
		var charge_power := _calculate_charge_power()
		var effective_charge := charge_power * charging_efficiency
		
		# Net power: charging minus laptop consumption
		var laptop_consumption := _get_laptop_consumption()
		var net_charge_power := effective_charge - laptop_consumption
		
		if net_charge_power > 0:
			# Convert Watts to Wh, then to percent
			var wh_gained := net_charge_power * hours_elapsed
			var percent_gained := (wh_gained / battery_capacity_wh) * 100.0
			battery_percent = minf(100.0, battery_percent + percent_gained)
			
			if battery_percent >= 100.0 and old_percent < 100.0:
				fully_charged.emit()
		else:
			# Draining even while plugged in (high usage)
			var wh_lost := absf(net_charge_power) * hours_elapsed
			var percent_lost := (wh_lost / battery_capacity_wh) * 100.0
			battery_percent = maxf(0.0, battery_percent - percent_lost)
	else:
		# Not plugged in - draining
		if is_laptop_on:
			var consumption := _get_laptop_consumption()
			var wh_lost := consumption * hours_elapsed
			var percent_lost := (wh_lost / battery_capacity_wh) * 100.0
			battery_percent = maxf(0.0, battery_percent - percent_lost)
	
	# Emit signal if battery changed significantly
	if absf(battery_percent - old_percent) > 0.1:
		battery_changed.emit(battery_percent)
	
	# Low battery warning
	if battery_percent <= low_battery_threshold and not _low_battery_warned:
		_low_battery_warned = true
		low_battery.emit(battery_percent)
	elif battery_percent > low_battery_threshold:
		_low_battery_warned = false

func _calculate_charge_power() -> float:
	if battery_percent >= 100.0:
		return 0.0
	
	if battery_percent < cv_transition_percent:
		# Constant Current phase - full power
		return max_charging_power_watts
	else:
		# Constant Voltage phase - power tapers off
		# Linear taper from CV transition to 100%
		var cv_range := 100.0 - cv_transition_percent
		var cv_progress := (battery_percent - cv_transition_percent) / cv_range
		var taper_factor := 1.0 - (cv_progress * 0.9)  # Drops to 10% at full
		return max_charging_power_watts * taper_factor

func _get_laptop_consumption() -> float:
	if not is_laptop_on:
		return 0.0
	return active_power_watts if is_active_use else idle_power_watts

func _update_power_device() -> void:
	if power_device == null:
		return
	
	var current_power := get_power_consumption()
	
	if current_power > 1.0:
		# Set power level proportional to current draw
		var power_fraction := current_power / max_charging_power_watts
		power_device.power_level = clampf(power_fraction, 0.0, 1.0)
		power_device.turn_on()
	elif is_plugged_in:
		power_device.set_standby()
	else:
		power_device.turn_off()

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

## Plug in the charger
func plug_in() -> void:
	if not is_plugged_in:
		is_plugged_in = true
		charging_started.emit()

## Alias for automation
func turn_on() -> void:
	plug_in()

## Unplug the charger
func unplug() -> void:
	if is_plugged_in:
		is_plugged_in = false
		charging_stopped.emit()

## Alias for automation
func turn_off() -> void:
	unplug()

## Toggle plugged state
func toggle() -> void:
	if is_plugged_in:
		unplug()
	else:
		plug_in()

## Power on the laptop
func power_on_laptop() -> void:
	is_laptop_on = true

## Power off the laptop (sleep/hibernate)
func power_off_laptop() -> void:
	is_laptop_on = false

## Set active use mode
func set_active_use(active: bool) -> void:
	is_active_use = active

## Get current battery percentage
func get_battery_percent() -> float:
	return battery_percent

## Get current power consumption from wall
func get_power_consumption() -> float:
	if not is_plugged_in:
		return 0.0
	
	var charge_power := _calculate_charge_power()
	var laptop_power := _get_laptop_consumption() if is_laptop_on else 0.0
	
	# Total wall power = charge power + direct laptop power
	# (accounting for charger efficiency)
	return charge_power + laptop_power

## Check if charging
func is_charging() -> bool:
	return is_plugged_in and battery_percent < 100.0

## Get estimated time to full charge in seconds
func get_time_to_full() -> float:
	if not is_plugged_in or battery_percent >= 100.0:
		return 0.0
	
	var remaining_wh := (100.0 - battery_percent) / 100.0 * battery_capacity_wh
	var net_charge := _calculate_charge_power() * charging_efficiency - _get_laptop_consumption()
	
	if net_charge <= 0:
		return -1.0  # Will never charge at current rate
	
	return (remaining_wh / net_charge) * 3600.0

## Get estimated time until battery dies in seconds
func get_time_to_empty() -> float:
	if is_plugged_in:
		var net_charge := _calculate_charge_power() * charging_efficiency - _get_laptop_consumption()
		if net_charge >= 0:
			return -1.0  # Won't die while charging
	
	if not is_laptop_on:
		return -1.0  # Not consuming power
	
	var remaining_wh := battery_percent / 100.0 * battery_capacity_wh
	var consumption := _get_laptop_consumption()
	
	if consumption <= 0:
		return -1.0
	
	return (remaining_wh / consumption) * 3600.0

