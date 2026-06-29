class_name DeviceTypes
extends RefCounted

## Device type categories for power consumers.
## Used for filtering, grouping, and Home Assistant domain mapping.

enum DeviceType {
	LIGHT,       ## Lighting (string lights, lamps, etc.) -> light.*
	APPLIANCE,   ## General appliances (kettle, instant pot) -> switch.*
	HVAC,        ## Heating/cooling (water heater, AC) -> climate.*
	CHARGER,     ## Battery chargers (laptop, EV, phone) -> switch.*
	PUMP,        ## Pumps (water, fuel) -> switch.*
	MOTOR,       ## Motors (fans, compressors) -> fan.*
	ELECTRONICS, ## Electronics (computers, displays) -> switch.*
	OTHER        ## Miscellaneous -> switch.*
}

## Maps DeviceType to Home Assistant domain
static func get_ha_domain(device_type: DeviceType) -> String:
	match device_type:
		DeviceType.LIGHT:
			return "light"
		DeviceType.HVAC:
			return "climate"
		DeviceType.MOTOR:
			return "fan"
		_:
			return "switch"

## Human-readable device type names
static func get_type_name(device_type: DeviceType) -> String:
	match device_type:
		DeviceType.LIGHT:
			return "Light"
		DeviceType.APPLIANCE:
			return "Appliance"
		DeviceType.HVAC:
			return "HVAC"
		DeviceType.CHARGER:
			return "Charger"
		DeviceType.PUMP:
			return "Pump"
		DeviceType.MOTOR:
			return "Motor"
		DeviceType.ELECTRONICS:
			return "Electronics"
		_:
			return "Other"

## Device state enumeration
enum DeviceState {
	OFF,      ## Completely off, no power draw
	STANDBY,  ## Idle but consuming standby power
	ON,       ## Fully on at set power level
	ECO       ## Energy-saving mode (reduced power)
}

static func get_state_name(state: DeviceState) -> String:
	match state:
		DeviceState.OFF:
			return "off"
		DeviceState.STANDBY:
			return "standby"
		DeviceState.ON:
			return "on"
		DeviceState.ECO:
			return "eco"
		_:
			return "unknown"

