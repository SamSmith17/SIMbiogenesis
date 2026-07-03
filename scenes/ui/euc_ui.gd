extends CanvasLayer

## UI for displaying EUC status: battery, distance, speed, range
## Only visible when player is riding the EUC

@onready var title_label : Label = $Panel/MarginContainer/VBoxContainer/TitleContainer/TitleLabel
@onready var battery_bar : ProgressBar = $Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryBarContainer/BatteryBar
@onready var battery_percent_label : Label = $Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryBarContainer/BatteryPercent
@onready var battery_wh_label : Label = $Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryWh
@onready var distance_value : Label = $Panel/MarginContainer/VBoxContainer/StatsContainer/DistanceContainer/DistanceValue
@onready var speed_value : Label = $Panel/MarginContainer/VBoxContainer/StatsContainer/SpeedContainer/SpeedValue
@onready var range_value : Label = $Panel/MarginContainer/VBoxContainer/StatsContainer/RangeContainer/RangeValue

# Reference to the vehicle (EUC, golf cart, etc.)
var euc_vehicle : Node3D = null

func _ready() -> void:
	visible = false

func _process(_delta: float) -> void:
	if not visible or euc_vehicle == null or not is_instance_valid(euc_vehicle):
		return
	
	_update_display()

func show_ui(euc: Node3D) -> void:
	euc_vehicle = euc
	visible = true
	
	# Update title based on vehicle type
	if euc != null and "display_name" in euc:
		var name : String = euc.display_name
		if not name.is_empty():
			title_label.text = " %s" % name.to_upper()
		else:
			title_label.text = " EUC STATUS"
	else:
		title_label.text = " EUC STATUS"
	
	_update_display()

func hide_ui() -> void:
	visible = false
	euc_vehicle = null

func _update_display() -> void:
	if euc_vehicle == null:
		return
	
	# Get data from EUC
	var battery_wh : float = euc_vehicle.get("battery_wh") if "battery_wh" in euc_vehicle else 1000.0
	var battery_capacity : float = euc_vehicle.get("battery_capacity_wh") if "battery_capacity_wh" in euc_vehicle else 1000.0
	var distance_meters : float = euc_vehicle.get("distance_traveled_meters") if "distance_traveled_meters" in euc_vehicle else 0.0
	var current_speed_mps : float = euc_vehicle.get("current_speed_mps") if "current_speed_mps" in euc_vehicle else 0.0
	var wh_per_mile : float = euc_vehicle.get("wh_per_mile") if "wh_per_mile" in euc_vehicle else 30.0
	
	# Calculate values
	var battery_percent : float = (battery_wh / battery_capacity) * 100.0
	var distance_miles : float = distance_meters / 1609.344  # meters to miles
	var speed_mph : float = current_speed_mps * 2.23694  # m/s to mph
	var range_miles : float = battery_wh / wh_per_mile if wh_per_mile > 0 else 0.0
	
	# Update battery bar
	battery_bar.value = battery_percent
	battery_percent_label.text = "%.0f%%" % battery_percent
	battery_wh_label.text = "%.0f / %.0f Wh" % [battery_wh, battery_capacity]
	
	# Color code battery
	if battery_percent > 50.0:
		battery_percent_label.add_theme_color_override("font_color", UITheme.C_OK)
		battery_bar.modulate = UITheme.C_OK
	elif battery_percent > 25.0:
		battery_percent_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2, 1.0))
		battery_bar.modulate = Color(1.0, 0.9, 0.2, 1.0)
	elif battery_percent > 10.0:
		battery_percent_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2, 1.0))
		battery_bar.modulate = Color(1.0, 0.5, 0.2, 1.0)
	else:
		battery_percent_label.add_theme_color_override("font_color", UITheme.C_ERROR)
		battery_bar.modulate = UITheme.C_ERROR
	
	# Update distance
	distance_value.text = "%.1f mi" % distance_miles
	
	# Update speed
	speed_value.text = "%.0f mph" % speed_mph
	
	# Update range
	range_value.text = "%.0f mi" % range_miles
	
	# Color code range based on remaining
	if range_miles > 10.0:
		range_value.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0, 1.0))
	elif range_miles > 5.0:
		range_value.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2, 1.0))
	else:
		range_value.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))

