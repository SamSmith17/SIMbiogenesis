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
	# The ride dashboard sits at the very bottom of the left edge, above the
	# timeline; toasts and the alarm feed stack over it. This layer shows and
	# hides itself, which frees or takes the slot.
	var panel := get_node_or_null("Panel") as Control
	if panel != null:
		HudLayout.register(panel, "vehicle_dash", "bottom_left", {
			"order": -10, "tuckable": false, "title": "ride dashboard"})

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

## One line under the gauges: what the vehicle can do here (a trailer to
## hitch, the forks), from the vehicle itself (`dashboard_hint()`).
var _hint: Label = null


func _update_hint() -> void:
	var text := str(euc_vehicle.call("dashboard_hint")) if euc_vehicle != null \
		and euc_vehicle.has_method("dashboard_hint") else ""
	if _hint == null:
		var box := get_node_or_null("Panel/MarginContainer/VBoxContainer") as VBoxContainer
		if box == null:
			return
		_hint = Label.new()
		_hint.name = "DashboardHint"
		_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		_hint.add_theme_color_override("font_color", UITheme.C_INFO)
		box.add_child(_hint)
	_hint.text = text
	_hint.visible = not text.is_empty()


func _update_display() -> void:
	if euc_vehicle == null:
		return
	
	# Get data from EUC
	var battery_wh : float = euc_vehicle.get("battery_wh") if "battery_wh" in euc_vehicle else 1000.0
	var battery_capacity : float = euc_vehicle.get("battery_capacity_wh") if "battery_capacity_wh" in euc_vehicle else 1000.0
	var distance_meters : float = euc_vehicle.get("distance_traveled_meters") if "distance_traveled_meters" in euc_vehicle else 0.0
	var current_speed_mps : float = euc_vehicle.get("current_speed_mps") if "current_speed_mps" in euc_vehicle else 0.0
	var wh_per_mile : float = euc_vehicle.get("wh_per_mile") if "wh_per_mile" in euc_vehicle else 30.0
	
	# A living vehicle on liquid fuel: the tank and its range.
	var head := get_node_or_null("Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryLabel") as Label
	var icon := get_node_or_null("Panel/MarginContainer/VBoxContainer/TitleContainer/EUCIcon") as Label
	if head != null:
		head.text = "BATTERY"
	if icon != null:
		icon.text = "⚡"
	if battery_capacity <= 0.0 and euc_vehicle.has_method("get_fuel_litres"):
		var fl: Vector2 = euc_vehicle.call("get_fuel_litres")
		if fl.y > 0.0:
			if head != null:
				head.text = "FUEL"
			if icon != null:
				icon.text = "⛽"
			var pct := 100.0 * fl.x / fl.y
			battery_bar.value = pct
			var col := UITheme.C_OK if pct > 25.0 else (UITheme.C_WARN if pct > 10.0 else UITheme.C_ERROR)
			battery_bar.modulate = col
			battery_percent_label.text = "%.0f%%" % pct
			battery_percent_label.add_theme_color_override("font_color", col)
			battery_wh_label.text = "%s / %s" % [UnitsPref.fuel_l(fl.x, 0), UnitsPref.fuel_l(fl.y, 0)]
			distance_value.text = UnitsPref.dist_m(distance_meters, 1)
			speed_value.text = UnitsPref.speed(current_speed_mps)
			var rmi := float(euc_vehicle.call("get_range_mi")) if euc_vehicle.has_method("get_range_mi") else -1.0
			range_value.text = UnitsPref.dist_mi(rmi) if rmi >= 0.0 else "—"
			_update_hint()
			return
	# A fuel vehicle (a placed bus, van or skid steer reports no battery).
	if battery_capacity <= 0.0:
		battery_bar.value = 100.0
		battery_bar.modulate = UITheme.C_INFO
		battery_percent_label.text = "fuel"
		battery_percent_label.add_theme_color_override("font_color", UITheme.C_INFO)
		battery_wh_label.text = ""
		distance_value.text = UnitsPref.dist_m(distance_meters, 1)
		speed_value.text = UnitsPref.speed(current_speed_mps)
		range_value.text = "—"
		_update_hint()
		return
	# Calculate values
	var battery_percent : float = (battery_wh / battery_capacity) * 100.0
	var distance_miles : float = distance_meters / 1609.344  # meters to miles
	var speed_mph : float = current_speed_mps * 2.23694  # m/s to mph
	var range_miles : float = battery_wh / wh_per_mile if wh_per_mile > 0 else 0.0
	
	# Update battery bar
	battery_bar.value = battery_percent
	battery_percent_label.text = "%.0f%%" % battery_percent
	battery_wh_label.text = I18n.f("{battery_wh} / {battery_capacity} Wh", {"battery_wh": "%.0f" % battery_wh, "battery_capacity": "%.0f" % battery_capacity})
	
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
	distance_value.text = UnitsPref.dist_mi(distance_miles, 1)
	
	# Update speed
	speed_value.text = UnitsPref.speed(current_speed_mps)
	
	# Update range
	range_value.text = UnitsPref.dist_mi(range_miles)
	_update_hint()
	
	# Color code range based on remaining
	if range_miles > 10.0:
		range_value.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0, 1.0))
	elif range_miles > 5.0:
		range_value.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2, 1.0))
	else:
		range_value.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))

