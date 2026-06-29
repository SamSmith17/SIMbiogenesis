extends Node

## EcoWorthy SL3500 Inverter + Shelly Pro 4PM digital twin bridge.
##
## Autoload singleton that subscribes to every Home Assistant entity from the
## EcoWorthy RS-485/ESPHome dashboard and the Shelly Pro 4PM power meter.
## Exposes live sensor values as typed properties and emits signals on change.
## Provides service-call helpers so any in-game node can read data or control
## Shelly outputs without knowing the HA WebSocket internals.
##
## Usage:
##   # Read a sensor value
##   var soc = InverterBridge.battery_soc_pct
##   # Control a switch
##   InverterBridge.set_shelly_output(0, true)
##   # React to changes
##   InverterBridge.entity_updated.connect(_on_entity_changed)

# ── Signals ──────────────────────────────────────────────────────────────────

## Emitted for every entity update (entity_id, new raw string value).
signal entity_updated(entity_id: String, value: String)
## Emitted when any EcoWorthy inverter sensor changes.
signal inverter_updated()
## Emitted when any Shelly Pro 4PM sensor or switch changes.
signal shelly_updated()
## Emitted when HA connection / authentication state changes.
signal connected_changed(is_connected: bool)

# ── EcoWorthy SL3500 entity IDs ──────────────────────────────────────────────

const INVERTER_ENTITIES: Array[String] = [
	"sensor.canbus_esp32_s3_ac_load_current",
	"sensor.canbus_esp32_s3_ac_output_apparent_power",
	"sensor.canbus_esp32_s3_ac_output_energy_integrated",
	"sensor.canbus_esp32_s3_ac_output_frequency",
	"sensor.canbus_esp32_s3_ac_output_power",
	"sensor.canbus_esp32_s3_ac_output_voltage",
	"sensor.canbus_esp32_s3_active_fault",
	"sensor.canbus_esp32_s3_active_fault_code_1",
	"sensor.canbus_esp32_s3_active_fault_code_2",
	"sensor.canbus_esp32_s3_battery_current",
	"sensor.canbus_esp32_s3_battery_soc_calculated",
	"sensor.canbus_esp32_s3_battery_soc_inverter",
	"sensor.canbus_esp32_s3_battery_surface_temperature",
	"sensor.canbus_esp32_s3_battery_voltage",
	"sensor.canbus_esp32_s3_charge_mode",
	"sensor.canbus_esp32_s3_charge_mode_raw",
	"sensor.canbus_esp32_s3_controller_temperature",
	"sensor.canbus_esp32_s3_dc_bus_voltage",
	"sensor.canbus_esp32_s3_dc_load_current",
	"sensor.canbus_esp32_s3_dc_load_power",
	"sensor.canbus_esp32_s3_dc_load_voltage",
	"sensor.canbus_esp32_s3_grid_current",
	"sensor.canbus_esp32_s3_grid_frequency",
	"sensor.canbus_esp32_s3_grid_voltage",
	"sensor.canbus_esp32_s3_heatsink_a_temperature_dc_dc",
	"sensor.canbus_esp32_s3_heatsink_b_temperature_dc_ac",
	"sensor.canbus_esp32_s3_inverter_inductive_current",
	"sensor.canbus_esp32_s3_inverter_machine_state",
	"sensor.canbus_esp32_s3_inverter_mode",
	"sensor.canbus_esp32_s3_lifetime_load_consumption",
	"sensor.canbus_esp32_s3_lifetime_pv_generation",
	"sensor.canbus_esp32_s3_load_consumption_today",
	"sensor.canbus_esp32_s3_load_percentage",
	"sensor.canbus_esp32_s3_load_power_factor_calculated",
	"sensor.canbus_esp32_s3_mains_charge_current",
	"sensor.canbus_esp32_s3_pv_generation_today",
	"sensor.canbus_esp32_s3_pv_input_current",
	"sensor.canbus_esp32_s3_pv_input_power",
	"sensor.canbus_esp32_s3_pv_input_voltage",
	"sensor.canbus_esp32_s3_solar_energy_integrated",
	"sensor.canbus_esp32_s3_solar_production_integrated",
	"sensor.canbus_esp32_s3_total_running_days",
]

# ── Shelly Pro 4PM entity IDs ─────────────────────────────────────────────────

const SHELLY_ENTITIES: Array[String] = [
	# Physical inputs
	"binary_sensor.shellypro4pm_ece334ed2e80_input_0",
	"binary_sensor.shellypro4pm_ece334ed2e80_input_1",
	"binary_sensor.shellypro4pm_ece334ed2e80_input_2",
	"binary_sensor.shellypro4pm_ece334ed2e80_input_3",
	# Output switches (controllable)
	"switch.shellypro4pm_ece334ed2e80_output_0",
	"switch.shellypro4pm_ece334ed2e80_output_1",
	"switch.shellypro4pm_ece334ed2e80_output_2",
	"switch.shellypro4pm_ece334ed2e80_output_3",
	# Energy / power sensors
	"sensor.shellypro4pm_ece334ed2e80_output_0_energy",
	"sensor.shellypro4pm_ece334ed2e80_output_0_energy_returned",
	"sensor.shellypro4pm_ece334ed2e80_output_0_power",
	"sensor.shellypro4pm_ece334ed2e80_output_1_energy",
	"sensor.shellypro4pm_ece334ed2e80_output_1_energy_returned",
	"sensor.shellypro4pm_ece334ed2e80_output_1_power",
	"sensor.shellypro4pm_ece334ed2e80_output_2_energy",
	"sensor.shellypro4pm_ece334ed2e80_output_2_energy_returned",
	"sensor.shellypro4pm_ece334ed2e80_output_2_power",
	"sensor.shellypro4pm_ece334ed2e80_output_3_energy",
	"sensor.shellypro4pm_ece334ed2e80_output_3_energy_returned",
	"sensor.shellypro4pm_ece334ed2e80_output_3_power",
	# Protection alerts
	"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overcurrent",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overheating",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overpowering",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overvoltage",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overcurrent",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overheating",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overpowering",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overvoltage",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overcurrent",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overheating",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overpowering",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overvoltage",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overcurrent",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overheating",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overpowering",
	"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overvoltage",
]

# ── EcoWorthy SL3500 live values ─────────────────────────────────────────────
# PV / Solar
var pv_input_power_w: float = 0.0
var pv_input_voltage_v: float = 0.0
var pv_input_current_a: float = 0.0
var pv_generation_today_kwh: float = 0.0
var solar_energy_integrated_kwh: float = 0.0
var solar_production_integrated_kwh: float = 0.0
var lifetime_pv_generation_kwh: float = 0.0

# Battery
var battery_soc_pct: float = 0.0             ## Inverter-reported state of charge (0–100 %)
var battery_soc_calculated_pct: float = 0.0  ## Coulomb-counted SOC from ESPHome
var battery_voltage_v: float = 0.0
var battery_current_a: float = 0.0           ## Positive = charging, negative = discharging
var battery_surface_temperature_c: float = 0.0

# AC Output (= load on the inverter)
var ac_output_power_w: float = 0.0
var ac_output_apparent_power_va: float = 0.0
var ac_output_voltage_v: float = 0.0
var ac_output_frequency_hz: float = 0.0
var ac_output_energy_integrated_kwh: float = 0.0
var ac_load_current_a: float = 0.0
var load_percentage_pct: float = 0.0
var load_power_factor: float = 0.0
var load_consumption_today_kwh: float = 0.0
var lifetime_load_consumption_kwh: float = 0.0

# DC Bus
var dc_bus_voltage_v: float = 0.0
var dc_load_current_a: float = 0.0
var dc_load_power_w: float = 0.0
var dc_load_voltage_v: float = 0.0

# Grid / Mains
var grid_voltage_v: float = 0.0
var grid_current_a: float = 0.0
var grid_frequency_hz: float = 0.0
var mains_charge_current_a: float = 0.0

# Temperatures
var heatsink_a_temp_c: float = 0.0   ## DC-DC converter heatsink
var heatsink_b_temp_c: float = 0.0   ## DC-AC inverter heatsink
var controller_temperature_c: float = 0.0
var inverter_inductive_current_a: float = 0.0

# String / enum states
var inverter_mode: String = ""
var inverter_machine_state: String = ""
var charge_mode: String = ""
var charge_mode_raw: String = ""
var active_fault: String = ""
var active_fault_code_1: String = ""
var active_fault_code_2: String = ""
var total_running_days: int = 0

# ── Shelly Pro 4PM live values ────────────────────────────────────────────────
## Physical input state (index 0–3)
var shelly_input: Array[bool] = [false, false, false, false]
## Output relay state (index 0–3)
var shelly_output: Array[bool] = [false, false, false, false]
## Active power per output in watts (index 0–3)
var shelly_output_power_w: Array[float] = [0.0, 0.0, 0.0, 0.0]
## Cumulative energy consumed per output in kWh (index 0–3)
var shelly_output_energy_kwh: Array[float] = [0.0, 0.0, 0.0, 0.0]
## Cumulative energy returned per output in kWh (index 0–3)
var shelly_output_energy_returned_kwh: Array[float] = [0.0, 0.0, 0.0, 0.0]
## Protection flags (index 0–3)
var shelly_output_overcurrent: Array[bool] = [false, false, false, false]
var shelly_output_overheating: Array[bool] = [false, false, false, false]
var shelly_output_overpowering: Array[bool] = [false, false, false, false]
var shelly_output_overvoltage: Array[bool] = [false, false, false, false]

# ── Raw state cache ───────────────────────────────────────────────────────────
## Maps every entity_id to its current raw state string.
var raw_states: Dictionary = {}

# ── Internal ──────────────────────────────────────────────────────────────────
var _ha_client: Node = null
var _subscribed: bool = false

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	call_deferred("_find_and_connect")

func _find_and_connect() -> void:
	await get_tree().create_timer(0.5).timeout
	var root := get_tree().root
	for child in root.get_children():
		var client := child.get_node_or_null("HAClient")
		if client != null:
			_ha_client = client
			break
	if _ha_client == null:
		return
	_ha_client.sensor_updated.connect(_on_sensor_updated)
	_ha_client.authentication_status_changed.connect(_on_auth_changed)
	if _ha_client.get("is_authenticated"):
		_subscribe_all()

func _on_auth_changed(authenticated: bool) -> void:
	connected_changed.emit(authenticated)
	if authenticated:
		_subscribed = false  # Allow re-subscribe after reconnect
		_subscribe_all()

func _subscribe_all() -> void:
	if _ha_client == null or _subscribed:
		return
	_subscribed = true
	var all_entities: Array[String] = []
	all_entities.append_array(INVERTER_ENTITIES)
	all_entities.append_array(SHELLY_ENTITIES)
	if _ha_client.has_method("subscribe_to_entities"):
		_ha_client.subscribe_to_entities(all_entities)
	if _ha_client.has_method("get_entity_states"):
		_ha_client.get_entity_states(all_entities)

# ── Sensor update handler ─────────────────────────────────────────────────────

func _on_sensor_updated(entity_id: String, state: Dictionary) -> void:
	var state_value: String = state.get("state", "")
	if state_value in ["unavailable", "unknown", ""]:
		return
	raw_states[entity_id] = state_value
	var num: float = state_value.to_float()
	var is_on: bool = state_value.to_lower() in ["on", "true", "1", "yes"]

	match entity_id:
		# ── PV / Solar ───────────────────────────────────────────────────────
		"sensor.canbus_esp32_s3_pv_input_power":
			pv_input_power_w = num
		"sensor.canbus_esp32_s3_pv_input_voltage":
			pv_input_voltage_v = num
		"sensor.canbus_esp32_s3_pv_input_current":
			pv_input_current_a = num
		"sensor.canbus_esp32_s3_pv_generation_today":
			pv_generation_today_kwh = num
		"sensor.canbus_esp32_s3_solar_energy_integrated":
			solar_energy_integrated_kwh = num
		"sensor.canbus_esp32_s3_solar_production_integrated":
			solar_production_integrated_kwh = num
		"sensor.canbus_esp32_s3_lifetime_pv_generation":
			lifetime_pv_generation_kwh = num

		# ── Battery ──────────────────────────────────────────────────────────
		"sensor.canbus_esp32_s3_battery_soc_inverter":
			battery_soc_pct = num
		"sensor.canbus_esp32_s3_battery_soc_calculated":
			battery_soc_calculated_pct = num
		"sensor.canbus_esp32_s3_battery_voltage":
			battery_voltage_v = num
		"sensor.canbus_esp32_s3_battery_current":
			battery_current_a = num
		"sensor.canbus_esp32_s3_battery_surface_temperature":
			battery_surface_temperature_c = num

		# ── AC Output ────────────────────────────────────────────────────────
		"sensor.canbus_esp32_s3_ac_output_power":
			ac_output_power_w = num
		"sensor.canbus_esp32_s3_ac_output_apparent_power":
			ac_output_apparent_power_va = num
		"sensor.canbus_esp32_s3_ac_output_voltage":
			ac_output_voltage_v = num
		"sensor.canbus_esp32_s3_ac_output_frequency":
			ac_output_frequency_hz = num
		"sensor.canbus_esp32_s3_ac_output_energy_integrated":
			ac_output_energy_integrated_kwh = num
		"sensor.canbus_esp32_s3_ac_load_current":
			ac_load_current_a = num
		"sensor.canbus_esp32_s3_load_percentage":
			load_percentage_pct = num
		"sensor.canbus_esp32_s3_load_power_factor_calculated":
			load_power_factor = num
		"sensor.canbus_esp32_s3_load_consumption_today":
			load_consumption_today_kwh = num
		"sensor.canbus_esp32_s3_lifetime_load_consumption":
			lifetime_load_consumption_kwh = num

		# ── DC Bus ───────────────────────────────────────────────────────────
		"sensor.canbus_esp32_s3_dc_bus_voltage":
			dc_bus_voltage_v = num
		"sensor.canbus_esp32_s3_dc_load_current":
			dc_load_current_a = num
		"sensor.canbus_esp32_s3_dc_load_power":
			dc_load_power_w = num
		"sensor.canbus_esp32_s3_dc_load_voltage":
			dc_load_voltage_v = num

		# ── Grid / Mains ─────────────────────────────────────────────────────
		"sensor.canbus_esp32_s3_grid_voltage":
			grid_voltage_v = num
		"sensor.canbus_esp32_s3_grid_current":
			grid_current_a = num
		"sensor.canbus_esp32_s3_grid_frequency":
			grid_frequency_hz = num
		"sensor.canbus_esp32_s3_mains_charge_current":
			mains_charge_current_a = num

		# ── Temperatures & Thermal ────────────────────────────────────────────
		"sensor.canbus_esp32_s3_heatsink_a_temperature_dc_dc":
			heatsink_a_temp_c = num
		"sensor.canbus_esp32_s3_heatsink_b_temperature_dc_ac":
			heatsink_b_temp_c = num
		"sensor.canbus_esp32_s3_controller_temperature":
			controller_temperature_c = num
		"sensor.canbus_esp32_s3_inverter_inductive_current":
			inverter_inductive_current_a = num

		# ── String / Enum States ──────────────────────────────────────────────
		"sensor.canbus_esp32_s3_inverter_mode":
			inverter_mode = state_value
		"sensor.canbus_esp32_s3_inverter_machine_state":
			inverter_machine_state = state_value
		"sensor.canbus_esp32_s3_charge_mode":
			charge_mode = state_value
		"sensor.canbus_esp32_s3_charge_mode_raw":
			charge_mode_raw = state_value
		"sensor.canbus_esp32_s3_active_fault":
			active_fault = state_value
		"sensor.canbus_esp32_s3_active_fault_code_1":
			active_fault_code_1 = state_value
		"sensor.canbus_esp32_s3_active_fault_code_2":
			active_fault_code_2 = state_value
		"sensor.canbus_esp32_s3_total_running_days":
			total_running_days = int(num)

		# ── Shelly Pro 4PM – Physical Inputs ─────────────────────────────────
		"binary_sensor.shellypro4pm_ece334ed2e80_input_0":
			shelly_input[0] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_input_1":
			shelly_input[1] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_input_2":
			shelly_input[2] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_input_3":
			shelly_input[3] = is_on

		# ── Shelly Pro 4PM – Output Switches ─────────────────────────────────
		"switch.shellypro4pm_ece334ed2e80_output_0":
			shelly_output[0] = is_on
		"switch.shellypro4pm_ece334ed2e80_output_1":
			shelly_output[1] = is_on
		"switch.shellypro4pm_ece334ed2e80_output_2":
			shelly_output[2] = is_on
		"switch.shellypro4pm_ece334ed2e80_output_3":
			shelly_output[3] = is_on

		# ── Shelly Pro 4PM – Power Sensors ───────────────────────────────────
		"sensor.shellypro4pm_ece334ed2e80_output_0_power":
			shelly_output_power_w[0] = num
		"sensor.shellypro4pm_ece334ed2e80_output_1_power":
			shelly_output_power_w[1] = num
		"sensor.shellypro4pm_ece334ed2e80_output_2_power":
			shelly_output_power_w[2] = num
		"sensor.shellypro4pm_ece334ed2e80_output_3_power":
			shelly_output_power_w[3] = num
		"sensor.shellypro4pm_ece334ed2e80_output_0_energy":
			shelly_output_energy_kwh[0] = num
		"sensor.shellypro4pm_ece334ed2e80_output_1_energy":
			shelly_output_energy_kwh[1] = num
		"sensor.shellypro4pm_ece334ed2e80_output_2_energy":
			shelly_output_energy_kwh[2] = num
		"sensor.shellypro4pm_ece334ed2e80_output_3_energy":
			shelly_output_energy_kwh[3] = num
		"sensor.shellypro4pm_ece334ed2e80_output_0_energy_returned":
			shelly_output_energy_returned_kwh[0] = num
		"sensor.shellypro4pm_ece334ed2e80_output_1_energy_returned":
			shelly_output_energy_returned_kwh[1] = num
		"sensor.shellypro4pm_ece334ed2e80_output_2_energy_returned":
			shelly_output_energy_returned_kwh[2] = num
		"sensor.shellypro4pm_ece334ed2e80_output_3_energy_returned":
			shelly_output_energy_returned_kwh[3] = num

		# ── Shelly Pro 4PM – Protection Alerts ───────────────────────────────
		"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overcurrent":
			shelly_output_overcurrent[0] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overcurrent":
			shelly_output_overcurrent[1] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overcurrent":
			shelly_output_overcurrent[2] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overcurrent":
			shelly_output_overcurrent[3] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overheating":
			shelly_output_overheating[0] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overheating":
			shelly_output_overheating[1] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overheating":
			shelly_output_overheating[2] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overheating":
			shelly_output_overheating[3] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overpowering":
			shelly_output_overpowering[0] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overpowering":
			shelly_output_overpowering[1] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overpowering":
			shelly_output_overpowering[2] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overpowering":
			shelly_output_overpowering[3] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_0_overvoltage":
			shelly_output_overvoltage[0] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_1_overvoltage":
			shelly_output_overvoltage[1] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_2_overvoltage":
			shelly_output_overvoltage[2] = is_on
		"binary_sensor.shellypro4pm_ece334ed2e80_output_3_overvoltage":
			shelly_output_overvoltage[3] = is_on

	entity_updated.emit(entity_id, state_value)
	if "canbus_esp32_s3" in entity_id:
		inverter_updated.emit()
	elif "shellypro4pm" in entity_id:
		shelly_updated.emit()

# ── Shelly switch control ─────────────────────────────────────────────────────

## Toggle a Shelly Pro 4PM output relay (output_index: 0–3).
func toggle_shelly_output(output_index: int) -> void:
	var entity_id := _shelly_switch_id(output_index)
	if entity_id.is_empty():
		return
	if _ha_client != null and _ha_client.has_method("call_service"):
		_ha_client.call_service("switch", "toggle", entity_id)

## Turn a Shelly Pro 4PM output on (on=true) or off (on=false).
func set_shelly_output(output_index: int, on: bool) -> void:
	var entity_id := _shelly_switch_id(output_index)
	if entity_id.is_empty():
		return
	var service := "turn_on" if on else "turn_off"
	if _ha_client != null and _ha_client.has_method("call_service"):
		_ha_client.call_service("switch", service, entity_id)

func _shelly_switch_id(output_index: int) -> String:
	if output_index < 0 or output_index > 3:
		return ""
	return "switch.shellypro4pm_ece334ed2e80_output_%d" % output_index

# ── Convenience helpers ───────────────────────────────────────────────────────

## Get the raw cached state string for any entity.
func get_state(entity_id: String) -> String:
	return raw_states.get(entity_id, "")

## Sum of active power across all four Shelly outputs (W).
func get_shelly_total_power_w() -> float:
	var total: float = 0.0
	for p: float in shelly_output_power_w:
		total += p
	return total

## True if the inverter is currently reporting any active fault.
func has_active_fault() -> bool:
	return active_fault != "" and active_fault.to_lower() not in ["none", "no fault", "0", "ok", "normal"]

## Efficiency ratio: PV input → AC output (0–1). Returns 0 if no PV.
func get_inverter_efficiency() -> float:
	if pv_input_power_w <= 0.0:
		return 0.0
	return clampf(ac_output_power_w / pv_input_power_w, 0.0, 1.0)
