extends Control

## Legacy TimeUI shim — panel hidden; controls live in TimelineUI.
## Kept for signal compatibility (live_mode_changed, simulation_started).

signal live_mode_changed(enabled: bool)
signal simulation_started(initial_battery_soc: float, initial_load_kw: float, initial_solar_kw: float)

@onready var panel: Panel = $Panel

var main_node: Node3D
var player_node: Node3D
var ui_visible: bool = false


func _ready() -> void:
	main_node = get_parent().get_parent()
	if main_node:
		player_node = main_node.get_node_or_null("Player")
	panel.visible = false
	ui_visible = false
	if is_instance_valid(SimSettingsController):
		if not SimSettingsController.live_mode_changed.is_connected(_forward_live_mode):
			SimSettingsController.live_mode_changed.connect(_forward_live_mode)
		if not SimSettingsController.simulation_started.is_connected(_forward_simulation_started):
			SimSettingsController.simulation_started.connect(_forward_simulation_started)


func is_ui_visible() -> bool:
	return false


func refresh_controls_from_main() -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.refresh_from_main()


func _notify_simulation_start() -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.notify_simulation_start()


func _forward_live_mode(enabled: bool) -> void:
	live_mode_changed.emit(enabled)


func _forward_simulation_started(soc: float, load_kw: float, solar_kw: float) -> void:
	simulation_started.emit(soc, load_kw, solar_kw)


# Legacy scene signal handlers — delegate to SimSettingsController.
func _on_year_input_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_year(int(value))


func _on_month_input_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_month(int(value))


func _on_day_input_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_day(int(value))


func _on_latitude_input_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_latitude(value)


func _on_longitude_input_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_longitude(value)


func _on_auto_dst_checkbox_toggled(toggled_on: bool) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.set_auto_dst(toggled_on)


func _on_manual_dst_checkbox_toggled(toggled_on: bool) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.set_manual_dst(toggled_on)


func _on_clouds_cutoff_slider_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_clouds_cutoff_ui(value)


func _on_clouds_weight_slider_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_clouds_weight(value)


func _on_sun_energy_slider_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_sun_energy(value)


func _on_shadow_quality_slider_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_shadow_quality(value)


func _on_moon_energy_slider_value_changed(value: float) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.apply_moon_energy(value)


func _on_live_mode_checkbox_toggled(toggled_on: bool) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.set_live_mode(toggled_on)


func _on_gameplay_toggle_toggled(toggled_on: bool) -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.set_survival_active(toggled_on)
