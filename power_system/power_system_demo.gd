extends Node

## Demo script showing how to set up the power system with example devices.
## Add this to your main scene to automatically create and register demo automations.

@export var enable_demo_devices : bool = false
@export var enable_demo_automations : bool = true
@export var debug_output : bool = true

var _devices_created : Array[Node] = []

func _ready() -> void:
	# Wait for autoloads to be ready
	call_deferred("_setup_demo")

func _setup_demo() -> void:
	if enable_demo_devices:
		_create_demo_devices()
	
	if enable_demo_automations:
		_create_demo_automations()
	
	if debug_output:
		_print_system_status()

func _create_demo_devices() -> void:
	# Create water heater
	var water_heater_scene := load("res://power_system/devices/electric_water_heater.tscn")
	if water_heater_scene:
		var heater : Node = water_heater_scene.instantiate()
		heater.name = "DemoWaterHeater"
		heater.device_id = "demo_water_heater"
		heater.display_name = "Demo Water Heater"
		add_child(heater)
		_devices_created.append(heater)
		if debug_output:
			pass
	
	# Create kettle
	var kettle_scene := load("res://power_system/devices/electric_kettle.tscn")
	if kettle_scene:
		var kettle : Node = kettle_scene.instantiate()
		kettle.name = "DemoKettle"
		kettle.device_id = "demo_kettle"
		kettle.display_name = "Demo Kettle"
		add_child(kettle)
		_devices_created.append(kettle)
		if debug_output:
			pass
	
	# Create laptop charger
	var laptop_scene := load("res://power_system/devices/laptop_charger.tscn")
	if laptop_scene:
		var laptop : Node = laptop_scene.instantiate()
		laptop.name = "DemoLaptop"
		laptop.device_id = "demo_laptop"
		laptop.display_name = "Demo Laptop"
		add_child(laptop)
		_devices_created.append(laptop)
		if debug_output:
			pass

func _create_demo_automations() -> void:
	var engine : Node = get_node_or_null("/root/AutomationEngine")
	if engine == null:
		push_warning("[PowerSystemDemo] AutomationEngine not found!")
		return
	
	# Find existing string lights device ID
	var registry : Node = get_node_or_null("/root/DeviceRegistry")
	var string_lights_id := ""
	
	if registry and registry.has_method("get_all_device_ids"):
		var ids : Array = registry.get_all_device_ids()
		for id in ids:
			if "string" in id.to_lower() or "light" in id.to_lower():
				string_lights_id = id
				break
	
	# Create sunset/sunrise automations for string lights
	if not string_lights_id.is_empty():
		var sunset_auto := ExampleAutomations.create_sunset_lights_on(string_lights_id)
		engine.register_automation(sunset_auto)
		
		var sunrise_auto := ExampleAutomations.create_sunrise_lights_off(string_lights_id)
		engine.register_automation(sunrise_auto)
		
		if debug_output:
			pass
	
	# Demo automations for demo devices (if created)
	if enable_demo_devices:
		# Morning kettle
		var kettle_auto := ExampleAutomations.create_morning_kettle("demo_kettle", 7.0)
		engine.register_automation(kettle_auto)
		
		# Water heater schedule
		var heater_autos := ExampleAutomations.create_water_heater_schedule("demo_water_heater")
		for auto in heater_autos:
			engine.register_automation(auto)
		
		# Smart laptop charging
		var laptop_auto := ExampleAutomations.create_smart_laptop_charging("demo_laptop", 50.0)
		engine.register_automation(laptop_auto)
		
		# Load shedding
		var shed_devices : Array[String] = ["demo_kettle", "demo_laptop"]
		var shed_auto := ExampleAutomations.create_load_shedding(shed_devices, 15.0)
		engine.register_automation(shed_auto)
		
		if debug_output:
			pass
	
	if debug_output:
		var auto_count : int = engine.get_automation_ids().size()

func _print_system_status() -> void:
	# Device Registry status
	var registry : Node = get_node_or_null("/root/DeviceRegistry")
	if registry:
		if registry.has_method("get_device_count"):
			pass
		if registry.has_method("get_total_power_kw"):
			pass
		if registry.has_method("get_all_device_ids"):
			for id in registry.get_all_device_ids():
				var device : Node = registry.get_device(id) if registry.has_method("get_device") else null
				if device:
					var power : float = device.get_current_power() if device.has_method("get_current_power") else 0.0
					var state : String = device.get_state_string() if device.has_method("get_state_string") else "unknown"
	
	# Automation Engine status
	var engine : Node = get_node_or_null("/root/AutomationEngine")
	if engine:
		if engine.has_method("get_automation_ids"):
			var ids : Array = engine.get_automation_ids()
			for id in ids:
				var auto : Automation = engine.get_automation(id) if engine.has_method("get_automation") else null
				if auto:
					pass

## Export all automations to Home Assistant YAML (call from console or button)
func export_automations(file_path: String = "user://automations.yaml") -> void:
	var engine : Node = get_node_or_null("/root/AutomationEngine")
	if engine == null:
		push_error("[PowerSystemDemo] AutomationEngine not found!")
		return
	
	if engine.has_method("export_to_file"):
		var success : bool = engine.export_to_file(file_path)
		if success:
			pass
		else:
			pass
	
	# Also export YAML
	if engine.has_method("export_all_to_ha_yaml"):
		var yaml : String = engine.export_all_to_ha_yaml()
