class_name ExampleAutomations
extends RefCounted

## Factory class for creating common automation patterns.
## Use these as templates or directly in your project.

## Create an automation that turns lights on at sunset
static func create_sunset_lights_on(device_id: String, offset_minutes: float = 0.0) -> Automation:
	var auto := Automation.new()
	auto.automation_id = "sunset_%s_on" % device_id
	auto.alias = "Turn on %s at sunset" % device_id
	auto.description = "Automatically turns on lights when the sun sets"
	
	var trigger := SunTrigger.new()
	trigger.event = SunTrigger.SunEvent.SUNSET
	trigger.offset_hours = offset_minutes / 60.0
	auto.triggers.append(trigger)
	
	var action := DeviceAction.new()
	action.device_id = device_id
	action.command = DeviceAction.DeviceCommand.TURN_ON
	auto.actions.append(action)
	
	return auto

## Create an automation that turns lights off at sunrise
static func create_sunrise_lights_off(device_id: String, offset_minutes: float = 0.0) -> Automation:
	var auto := Automation.new()
	auto.automation_id = "sunrise_%s_off" % device_id
	auto.alias = "Turn off %s at sunrise" % device_id
	auto.description = "Automatically turns off lights when the sun rises"
	
	var trigger := SunTrigger.new()
	trigger.event = SunTrigger.SunEvent.SUNRISE
	trigger.offset_hours = offset_minutes / 60.0
	auto.triggers.append(trigger)
	
	var action := DeviceAction.new()
	action.device_id = device_id
	action.command = DeviceAction.DeviceCommand.TURN_OFF
	auto.actions.append(action)
	
	return auto

## Create an automation that runs at a specific time
static func create_scheduled_device(
	device_id: String,
	hour: float,
	turn_on: bool = true
) -> Automation:
	var action_str := "on" if turn_on else "off"
	var time_str := "%02d:%02d" % [int(hour), int((hour - int(hour)) * 60)]
	
	var auto := Automation.new()
	auto.automation_id = "schedule_%s_%s_%s" % [device_id, action_str, time_str.replace(":", "")]
	auto.alias = "Turn %s %s at %s" % [device_id, action_str, time_str]
	
	var trigger := TimeTrigger.new()
	trigger.at_hour = hour
	auto.triggers.append(trigger)
	
	var action := DeviceAction.new()
	action.device_id = device_id
	action.command = DeviceAction.DeviceCommand.TURN_ON if turn_on else DeviceAction.DeviceCommand.TURN_OFF
	auto.actions.append(action)
	
	return auto

## Create a morning kettle automation (boil kettle at wake-up time)
static func create_morning_kettle(kettle_device_id: String, wake_hour: float = 7.0) -> Automation:
	var auto := Automation.new()
	auto.automation_id = "morning_kettle"
	auto.alias = "Morning Kettle"
	auto.description = "Boil kettle for morning coffee/tea"
	
	var trigger := TimeTrigger.new()
	trigger.at_hour = wake_hour
	auto.triggers.append(trigger)
	
	# Only on weekdays
	var condition := TimeCondition.new()
	condition.weekdays = [1, 2, 3, 4, 5]  # Mon-Fri
	auto.conditions.append(condition)
	
	var action := DeviceAction.new()
	action.device_id = kettle_device_id
	action.command = DeviceAction.DeviceCommand.TURN_ON
	auto.actions.append(action)
	
	return auto

## Create a water heater eco mode automation (reduce temp at night)
static func create_water_heater_schedule(
	heater_device_id: String,
	eco_start_hour: float = 23.0,
	normal_start_hour: float = 5.0
) -> Array[Automation]:
	var automations : Array[Automation] = []
	
	# Eco mode at night
	var eco_auto := Automation.new()
	eco_auto.automation_id = "water_heater_eco_mode"
	eco_auto.alias = "Water Heater Eco Mode"
	eco_auto.description = "Reduce water heater power at night"
	
	var eco_trigger := TimeTrigger.new()
	eco_trigger.at_hour = eco_start_hour
	eco_auto.triggers.append(eco_trigger)
	
	var eco_action := DeviceAction.new()
	eco_action.device_id = heater_device_id
	eco_action.command = DeviceAction.DeviceCommand.SET_ECO
	eco_auto.actions.append(eco_action)
	
	automations.append(eco_auto)
	
	# Normal mode in morning
	var normal_auto := Automation.new()
	normal_auto.automation_id = "water_heater_normal_mode"
	normal_auto.alias = "Water Heater Normal Mode"
	normal_auto.description = "Resume normal water heater operation in morning"
	
	var normal_trigger := TimeTrigger.new()
	normal_trigger.at_hour = normal_start_hour
	normal_auto.triggers.append(normal_trigger)
	
	var normal_action := DeviceAction.new()
	normal_action.device_id = heater_device_id
	normal_action.command = DeviceAction.DeviceCommand.TURN_ON
	normal_auto.actions.append(normal_action)
	
	automations.append(normal_auto)
	
	return automations

## Create a battery-aware charging automation
## Only charge laptop when battery is full enough
static func create_smart_laptop_charging(
	laptop_device_id: String,
	min_battery_percent: float = 50.0
) -> Automation:
	var auto := Automation.new()
	auto.automation_id = "smart_laptop_charge"
	auto.alias = "Smart Laptop Charging"
	auto.description = "Only charge laptop when solar battery has surplus"
	
	# Trigger when laptop battery drops below threshold
	var trigger := NumericStateTrigger.new()
	trigger.entity_id = laptop_device_id
	trigger.attribute = "power_level"
	trigger.below = 30.0  # Start charging when laptop battery < 30%
	auto.triggers.append(trigger)
	
	# Only if main battery has enough charge
	var condition := NumericStateCondition.new()
	condition.entity_id = "sensor.battery_level"
	condition.above = min_battery_percent
	auto.conditions.append(condition)
	
	var action := DeviceAction.new()
	action.device_id = laptop_device_id
	action.command = DeviceAction.DeviceCommand.TURN_ON
	auto.actions.append(action)
	
	return auto

## Create a load shedding automation
## Turn off non-essential devices when battery is low
static func create_load_shedding(
	device_ids: Array[String],
	battery_threshold: float = 20.0
) -> Automation:
	var auto := Automation.new()
	auto.automation_id = "load_shedding"
	auto.alias = "Low Battery Load Shedding"
	auto.description = "Turn off non-essential loads when battery is low"
	
	# Trigger when battery drops below threshold
	var trigger := NumericStateTrigger.new()
	trigger.entity_id = "sensor.battery_level"
	trigger.below = battery_threshold
	auto.triggers.append(trigger)
	
	# Only at night (when solar isn't helping)
	var condition := SunCondition.new()
	condition.sun_state = SunCondition.SunState.BELOW_HORIZON
	auto.conditions.append(condition)
	
	# Turn off all specified devices
	for device_id in device_ids:
		var action := DeviceAction.new()
		action.device_id = device_id
		action.command = DeviceAction.DeviceCommand.TURN_OFF
		auto.actions.append(action)
	
	return auto

## Create a daytime charging preference automation
## Prefer charging during peak solar hours
static func create_solar_charging_window(
	device_id: String,
	start_hour: float = 10.0,
	end_hour: float = 15.0
) -> Array[Automation]:
	var automations : Array[Automation] = []
	
	# Enable charging at start of solar window
	var start_auto := Automation.new()
	start_auto.automation_id = "solar_charge_start_%s" % device_id
	start_auto.alias = "Start Solar Charging %s" % device_id
	
	var start_trigger := TimeTrigger.new()
	start_trigger.at_hour = start_hour
	start_auto.triggers.append(start_trigger)
	
	# Only if sun is actually up
	var sun_condition := SunCondition.new()
	sun_condition.sun_state = SunCondition.SunState.ABOVE_HORIZON
	start_auto.conditions.append(sun_condition)
	
	var start_action := DeviceAction.new()
	start_action.device_id = device_id
	start_action.command = DeviceAction.DeviceCommand.TURN_ON
	start_auto.actions.append(start_action)
	
	automations.append(start_auto)
	
	# Disable charging at end of solar window
	var end_auto := Automation.new()
	end_auto.automation_id = "solar_charge_end_%s" % device_id
	end_auto.alias = "End Solar Charging %s" % device_id
	
	var end_trigger := TimeTrigger.new()
	end_trigger.at_hour = end_hour
	end_auto.triggers.append(end_trigger)
	
	var end_action := DeviceAction.new()
	end_action.device_id = device_id
	end_action.command = DeviceAction.DeviceCommand.TURN_OFF
	end_auto.actions.append(end_action)
	
	automations.append(end_auto)
	
	return automations

