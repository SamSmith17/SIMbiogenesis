extends Control

## Settings modal opened from the timeline gear icon.
## Renders as a full-screen backdrop + centred PanelContainer with a TabContainer
## so future sections can be added without touching layout.  Each tab is a
## ScrollContainer so content is never clipped by the viewport.

const C_PANEL  := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_TEXT   := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S := Color(0.580, 0.639, 0.722, 1.0)

var _timeline: Control = null
var _syncing: bool = false

var _clouds_cutoff: HSlider
var _clouds_weight: HSlider
var _sun_energy: HSlider
var _shadow_quality: HSlider
var _shadow_quality_lbl: Label
var _graphics_quality: OptionButton
var _moon_energy: HSlider
var _moon_phase_lbl: Label
var _ambient_energy: HSlider
var _ambient_sky: HSlider
var _glow_intensity: HSlider
var _glow_enabled: CheckBox
var _ssao_enabled: CheckBox
var _ssil_enabled: CheckBox
var _sdfgi_enabled: CheckBox
var _volumetric_fog: CheckBox
var _fog_amount: HSlider
var _tonemap_mode: OptionButton
var _tonemap_exposure: HSlider
var _tonemap_white: HSlider
var _sun_size: HSlider
var _moon_size: HSlider
var _moon_glow: HSlider
var _stars_brightness: HSlider
var _stars_scale: HSlider
var _stars_twinkle: HSlider
var _stars_horizon: HSlider
var _stars_north: HSlider
var _stars_decl: HSlider
var _stars_flip_v: CheckBox
var _stars_flip_h: CheckBox
var _planets_master: CheckBox
var _star_texture_lbl: Label
var _star_file_dialog: FileDialog = null
var _planet_enabled: Dictionary = {}
var _planet_brightness: Dictionary = {}
var _planet_size: Dictionary = {}
var _planet_glow: Dictionary = {}
var _planet_color: Dictionary = {}
var _latitude: SpinBox
var _longitude: SpinBox
var _lat_lbl: Label
var _lon_lbl: Label
var _auto_dst: CheckBox
var _manual_dst: CheckBox
var _dst_status: Label
var _live_mode: CheckBox
var _live_status: Label
var _survival: CheckBox
var _survival_status: Label

var _scenario_opt:   OptionButton = null
var _opentopo_input: LineEdit     = null
var _cds_input:      LineEdit     = null
var _keys_status:    Label        = null
var _solar_panel_count: HSlider = null
var _solar_panel_wattage: HSlider = null
var _solar_panel_tilt: HSlider = null
var _solar_panel_azimuth: HSlider = null
var _solar_battery_capacity: HSlider = null
var _solar_inverter_max: HSlider = null
var _solar_calibration: HSlider = null
var _solar_high_accuracy: CheckBox = null
var _solar_shadow_raycast: CheckBox = null
var _ha_url_input: LineEdit = null
var _ha_token_input: LineEdit = null
var _ha_entities_input: TextEdit = null
var _ha_status_lbl: Label = null
var _center_panel: PanelContainer = null
var _center_layout_pending: bool = false
var _line_edit_sanitize_guard: bool = false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScreenLayout.pin_fullscreen(self)
	_build_ui()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_request_center_layout()


func _request_center_layout() -> void:
	if _center_layout_pending:
		return
	_center_layout_pending = true
	call_deferred("_layout_center_panel")


func _layout_center_panel() -> void:
	_center_layout_pending = false
	if _center_panel == null:
		return
	UiScreenLayout.clamped_center(_center_panel, Vector2(540.0, 640.0))


func bind_timeline(timeline: Control) -> void:
	_timeline = timeline


func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	refresh_from_controller()
	_request_center_layout()
	visible = true
	CursorController.request_modal("timeline_settings", Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.persist_settings()
	visible = false
	CursorController.release_modal("timeline_settings")


func refresh_from_controller() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	var snap: Dictionary = SimSettingsController.get_state_snapshot()
	if snap.is_empty():
		return
	_syncing = true
	if _clouds_cutoff:
		_clouds_cutoff.value = snap.get("clouds_cutoff_ui", 0.0)
	if _clouds_weight:
		_clouds_weight.value = snap.get("clouds_weight", 0.5)
	if _sun_energy:
		_sun_energy.value = snap.get("sun_energy", 1.0)
	if _shadow_quality:
		_shadow_quality.value = snap.get("shadow_quality", 2)
	if _graphics_quality:
		_graphics_quality.selected = clampi(int(snap.get("graphics_quality", 2)), 0, 2)
	if _moon_energy:
		_moon_energy.value = snap.get("moon_energy", 0.3)
	if _latitude:
		_latitude.value = snap.get("latitude", 0.0)
	if _longitude:
		_longitude.value = snap.get("longitude", 0.0)
	if _auto_dst:
		_auto_dst.button_pressed = snap.get("auto_dst", true)
	if _manual_dst:
		_manual_dst.button_pressed = snap.get("manual_dst", false)
	if _live_mode:
		_live_mode.button_pressed = snap.get("live_mode", false)
	if _survival:
		_survival.button_pressed = snap.get("survival_active", false)
	_sync_advanced_from_snapshot(snap)
	_sync_stars_planets_from_snapshot(snap)
	_sync_solar_from_snapshot(snap)
	_sync_ha_from_snapshot(snap)
	# Climate scenario — read from ClimateProjectionService directly.
	if _scenario_opt:
		var cps := get_node_or_null("/root/ClimateProjectionService")
		if cps != null:
			_scenario_opt.selected = clampi(int(cps.get("active_scenario")), 0, 3)
	# API keys — read from config files.
	if _opentopo_input:
		var cfg_ot := ConfigFile.new()
		if cfg_ot.load("user://terrain_config.cfg") == OK:
			_line_edit_sanitize_guard = true
			_opentopo_input.text = _sanitize_api_key(str(cfg_ot.get_value("opentopography", "api_key", "")))
			_line_edit_sanitize_guard = false
	if _cds_input:
		var cfg_cds := ConfigFile.new()
		if cfg_cds.load("user://keys_config.cfg") == OK:
			_line_edit_sanitize_guard = true
			_cds_input.text = _normalize_cds_key(str(cfg_cds.get_value("copernicus", "api_key", "")))
			_line_edit_sanitize_guard = false
	_syncing = false
	_refresh_labels()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Dark backdrop — click outside the panel to dismiss.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.60)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			close()
	)
	add_child(backdrop)

	# Centred modal panel — sized to viewport in _layout_center_panel().
	var panel := PanelContainer.new()
	_center_panel = panel
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var psb := StyleBoxFlat.new()
	psb.bg_color     = C_PANEL
	psb.border_color = C_BORDER
	psb.set_border_width_all(1)
	psb.set_corner_radius_all(8)
	psb.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	psb.shadow_size  = 14
	panel.add_theme_stylebox_override("panel", psb)
	add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	panel.add_child(outer)

	# Title bar.
	var tbm := MarginContainer.new()
	tbm.add_theme_constant_override("margin_left",   16)
	tbm.add_theme_constant_override("margin_right",   8)
	tbm.add_theme_constant_override("margin_top",    12)
	tbm.add_theme_constant_override("margin_bottom",  8)
	outer.add_child(tbm)
	var title_row := HBoxContainer.new()
	tbm.add_child(title_row)
	var title_lbl := Label.new()
	title_lbl.text = "⚙  Simulation Settings"
	title_lbl.add_theme_color_override("font_color", C_TEXT)
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_color_override("font_color", C_TEXT_S)
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(close)
	title_row.add_child(close_btn)

	outer.add_child(HSeparator.new())

	# TabContainer — one per settings section.
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 500)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tab_panel_sb := StyleBoxFlat.new()
	tab_panel_sb.bg_color = C_PANEL
	tabs.add_theme_stylebox_override("panel", tab_panel_sb)
	outer.add_child(tabs)

	_build_gameplay_tab(tabs)
	_build_environment_tab(tabs)
	_build_lighting_tab(tabs)
	_build_stars_planets_tab(tabs)
	_build_solar_tab(tabs)
	_build_ha_tab(tabs)
	_build_location_tab(tabs)
	_build_live_tab(tabs)
	_build_keys_tab(tabs)
	_request_center_layout()


## Returns the inner VBoxContainer for a new tab called `title`.
func _make_tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	tabs.add_child(scroll)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left",   16)
	m.add_theme_constant_override("margin_right",  16)
	m.add_theme_constant_override("margin_top",    12)
	m.add_theme_constant_override("margin_bottom", 12)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(m)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(vbox)
	return vbox


func _build_keys_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Keys")
	_add_section_lbl(v, "API Keys  (optional — improve data accuracy)")

	var hint_ot := Label.new()
	hint_ot.text = "OpenTopography: enables 30 m DEM resolution (vs default 90 m).\nFree key at portal.opentopography.org"
	hint_ot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_ot.custom_minimum_size = Vector2(420, 0)
	hint_ot.add_theme_color_override("font_color", C_TEXT_S)
	hint_ot.add_theme_font_size_override("font_size", 10)
	v.add_child(hint_ot)
	_opentopo_input = _add_key_row(v, "OpenTopography API key", "Enter key…",
		_save_opentopo_key, false)

	v.add_child(HSeparator.new())

	var hint_cds := Label.new()
	hint_cds.text = "Copernicus CDS: regional CMIP6 climate projections (higher accuracy).\nFree account at cds.climate.copernicus.eu\nPaste your personal access token, or a single `key: …` line from ~/.cdsapirc."
	hint_cds.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_cds.custom_minimum_size = Vector2(420, 0)
	hint_cds.add_theme_color_override("font_color", C_TEXT_S)
	hint_cds.add_theme_font_size_override("font_size", 10)
	v.add_child(hint_cds)
	_cds_input = _add_key_row(v, "Copernicus CDS API key", "Enter key…",
		_save_cds_key, true)

	_keys_status = Label.new()
	_keys_status.text = ""
	_keys_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_keys_status.custom_minimum_size = Vector2(420, 0)
	_keys_status.add_theme_color_override("font_color", C_TEXT_S)
	_keys_status.add_theme_font_size_override("font_size", 10)
	v.add_child(_keys_status)


func _build_solar_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Solar")
	_add_section_lbl(v, "Array & Battery")
	var hint := Label.new()
	hint.text = "Panel and battery parameters for the power scoreboard. Changes apply instantly and save to user://solar_panel_config.cfg."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)

	_solar_panel_count = _add_slider(v, "Panel count", 1.0, 100.0, 1.0, _on_solar_panel_count)
	_solar_panel_wattage = _add_slider(v, "Panel wattage (W)", 50.0, 600.0, 5.0, _on_solar_panel_wattage)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Orientation")
	_solar_panel_tilt = _add_slider(v, "Panel tilt (°)", 0.0, 90.0, 1.0, _on_solar_panel_tilt)
	_solar_panel_azimuth = _add_slider(v, "Panel azimuth (°)", 0.0, 360.0, 1.0, _on_solar_panel_azimuth)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "System Limits")
	_solar_battery_capacity = _add_slider(v, "Battery (kWh)", 1.0, 200.0, 0.5, _on_solar_battery_capacity)
	_solar_inverter_max = _add_slider(v, "Inverter max (kW)", 1.0, 20.0, 0.1, _on_solar_inverter_max)
	_solar_calibration = _add_slider(v, "Calibration", 0.1, 1.5, 0.01, _on_solar_calibration)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Physics")
	_solar_high_accuracy = _add_check(v, "High accuracy physics (Meeus SPA + real GHI)", _on_solar_high_accuracy)
	_solar_shadow_raycast = _add_check(v, "3D shadow raycast toward sun", _on_solar_shadow_raycast)


func _build_ha_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Home Assistant")
	_add_section_lbl(v, "WebSocket Connection")
	var hint := Label.new()
	hint.text = (
		"Credentials are stored only in user://ha_connection.cfg on your machine — never in the project or git.\n"
		+ "Create a long-lived access token in Home Assistant → Profile → Security."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)

	_ha_url_input = _add_ha_line_row(v, "WebSocket URL", "ws://192.168.1.10:8123/api/websocket", false)
	_ha_token_input = _add_ha_line_row(v, "Access token", "Paste long-lived token…", true)
	if _ha_url_input:
		_ha_url_input.text_changed.connect(_on_ha_fields_changed)
	if _ha_token_input:
		_ha_token_input.text_changed.connect(_on_ha_fields_changed)

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Entity Subscriptions")
	var ent_hint := Label.new()
	ent_hint.text = "Optional: one entity_id per line (or comma-separated). Subscribed on connect."
	ent_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ent_hint.custom_minimum_size = Vector2(420, 0)
	ent_hint.add_theme_color_override("font_color", C_TEXT_S)
	ent_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(ent_hint)
	_ha_entities_input = TextEdit.new()
	_ha_entities_input.custom_minimum_size = Vector2(420, 72)
	_ha_entities_input.placeholder_text = "sensor.battery_soc\nsensor.solar_power"
	_ha_entities_input.text_changed.connect(_on_ha_fields_changed)
	v.add_child(_ha_entities_input)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var connect_btn := Button.new()
	connect_btn.text = "Save & Connect"
	connect_btn.tooltip_text = "Save credentials to user:// and open the WebSocket connection"
	connect_btn.pressed.connect(_on_ha_connect_pressed)
	btn_row.add_child(connect_btn)
	var disconnect_btn := Button.new()
	disconnect_btn.text = "Disconnect"
	disconnect_btn.pressed.connect(_on_ha_disconnect_pressed)
	btn_row.add_child(disconnect_btn)
	var subscribe_btn := Button.new()
	subscribe_btn.text = "Subscribe entities"
	subscribe_btn.tooltip_text = "Subscribe to the entity list without reconnecting"
	subscribe_btn.pressed.connect(_on_ha_subscribe_pressed)
	btn_row.add_child(subscribe_btn)
	v.add_child(btn_row)

	_ha_status_lbl = _add_status_label(v, "Status: —")
	_connect_ha_status_signals()


func _add_ha_line_row(parent: Control, label_text: String, placeholder: String, secret: bool) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(120, 0)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(lbl)
	var ed := LineEdit.new()
	ed.placeholder_text = placeholder
	ed.secret = secret
	ed.max_length = 512
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ed)
	if secret:
		var show_btn := Button.new()
		show_btn.text = "Show"
		show_btn.toggle_mode = true
		show_btn.toggled.connect(func(on: bool) -> void:
			ed.secret = not on
			show_btn.text = "Hide" if on else "Show"
		)
		row.add_child(show_btn)
	parent.add_child(row)
	return ed


func _connect_ha_status_signals() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	var main: Node = SimSettingsController.main_node
	if main == null:
		return
	var client := main.get_node_or_null("HAClient")
	if client == null:
		return
	if client.has_signal("connection_status_changed") \
			and not client.connection_status_changed.is_connected(_on_ha_client_connection_changed):
		client.connection_status_changed.connect(_on_ha_client_connection_changed)
	if client.has_signal("authentication_status_changed") \
			and not client.authentication_status_changed.is_connected(_on_ha_client_auth_changed):
		client.authentication_status_changed.connect(_on_ha_client_auth_changed)


func _on_ha_client_connection_changed(_connected: bool) -> void:
	_refresh_ha_status()


func _on_ha_client_auth_changed(_authenticated: bool) -> void:
	_refresh_ha_status()


func _on_ha_fields_changed(_arg: Variant = null) -> void:
	if _syncing or not is_instance_valid(SimSettingsController):
		return
	var url := _ha_url_input.text if _ha_url_input else ""
	var token := _ha_token_input.text if _ha_token_input else ""
	var entities := _ha_entities_input.text if _ha_entities_input else ""
	SimSettingsController.set_pending_ha_connection(url, token, entities)


func _on_ha_connect_pressed() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	var url := _ha_url_input.text.strip_edges() if _ha_url_input else ""
	var token := _ha_token_input.text.strip_edges() if _ha_token_input else ""
	var entities := _ha_entities_input.text if _ha_entities_input else ""
	SimSettingsController.connect_ha(url, token, entities)
	if not entities.strip_edges().is_empty():
		SimSettingsController.subscribe_ha_entities(entities)
	_refresh_ha_status()


func _on_ha_disconnect_pressed() -> void:
	if is_instance_valid(SimSettingsController):
		SimSettingsController.disconnect_ha()
	_refresh_ha_status()


func _on_ha_subscribe_pressed() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	var entities := _ha_entities_input.text if _ha_entities_input else ""
	SimSettingsController.subscribe_ha_entities(entities)
	_on_ha_fields_changed()
	_refresh_ha_status()


func _refresh_ha_status() -> void:
	if _ha_status_lbl == null or not is_instance_valid(SimSettingsController):
		return
	var txt: String = SimSettingsController.get_ha_status_text()
	_ha_status_lbl.text = "Status: %s" % txt
	var col := C_TEXT_S
	if txt.begins_with("Connected and"):
		col = Color(0.15, 0.90, 0.47, 1.0)
	elif txt.begins_with("Connected"):
		col = Color(0.95, 0.78, 0.22, 1.0)
	elif txt == "Disconnected":
		col = Color(0.95, 0.35, 0.35, 1.0)
	_ha_status_lbl.add_theme_color_override("font_color", col)


func _sync_solar_from_snapshot(snap: Dictionary) -> void:
	if _solar_panel_count:
		_solar_panel_count.value = float(snap.get("panel_count", 18))
	if _solar_panel_wattage:
		_solar_panel_wattage.value = float(snap.get("panel_wattage", 220.0))
	if _solar_panel_tilt:
		_solar_panel_tilt.value = float(snap.get("panel_tilt", 0.0))
	if _solar_panel_azimuth:
		_solar_panel_azimuth.value = float(snap.get("panel_azimuth", 180.0))
	if _solar_battery_capacity:
		_solar_battery_capacity.value = float(snap.get("battery_capacity", 16.0))
	if _solar_inverter_max:
		_solar_inverter_max.value = float(snap.get("inverter_max", 4.4))
	if _solar_calibration:
		_solar_calibration.value = float(snap.get("calibration", 0.85))
	if _solar_high_accuracy:
		_solar_high_accuracy.button_pressed = bool(snap.get("high_accuracy_physics", false))
	if _solar_shadow_raycast:
		_solar_shadow_raycast.button_pressed = bool(snap.get("shadow_raycast", false))


func _sync_ha_from_snapshot(snap: Dictionary) -> void:
	if _ha_url_input:
		_ha_url_input.text = str(snap.get("ha_url", ""))
	if _ha_token_input:
		_ha_token_input.text = str(snap.get("ha_token", ""))
	if _ha_entities_input:
		_ha_entities_input.text = str(snap.get("ha_entities", ""))
	if is_instance_valid(SimSettingsController):
		SimSettingsController.set_pending_ha_connection(
			_ha_url_input.text if _ha_url_input else "",
			_ha_token_input.text if _ha_token_input else "",
			_ha_entities_input.text if _ha_entities_input else "")
	_refresh_ha_status()


func _on_solar_panel_count(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("panel_count", int(v))


func _on_solar_panel_wattage(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("panel_wattage", v)


func _on_solar_panel_tilt(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("panel_tilt", v)


func _on_solar_panel_azimuth(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("panel_azimuth", v)


func _on_solar_battery_capacity(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("battery_capacity", v)


func _on_solar_inverter_max(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("inverter_max", v)


func _on_solar_calibration(v: float) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("calibration", v)


func _on_solar_high_accuracy(on: bool) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("high_accuracy_physics", on)


func _on_solar_shadow_raycast(on: bool) -> void:
	if _syncing:
		return
	SimSettingsController.apply_solar_panel_setting("shadow_raycast", on)


func _add_key_row(parent: Control, label_text: String, placeholder: String,
		save_cb: Callable, cds_format: bool) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(140, 0)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(lbl)
	var ed := LineEdit.new()
	ed.placeholder_text = placeholder
	ed.max_length = 256
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ed.text_changed.connect(func(_t: String) -> void:
		if _line_edit_sanitize_guard:
			return
		_sanitize_line_edit(ed, cds_format)
	)
	ed.text_submitted.connect(func(_t: String) -> void:
		if save_cb.is_valid():
			save_cb.call()
		var vp := ed.get_viewport()
		if vp != null:
			vp.set_input_as_handled()
	)
	row.add_child(ed)
	var show_btn := Button.new()
	show_btn.text = "Show"
	show_btn.toggle_mode = true
	show_btn.toggled.connect(func(on: bool) -> void:
		ed.secret = not on
		show_btn.text = "Hide" if on else "Show"
	)
	row.add_child(show_btn)
	var btn := Button.new()
	btn.text = "Save"
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(func() -> void:
		if save_cb.is_valid():
			save_cb.call()
	)
	row.add_child(btn)
	parent.add_child(row)
	return ed


func _build_gameplay_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Gameplay")
	_survival        = _add_check(v, "Survival mechanics active", _on_survival)
	_survival_status = _add_status_label(v, "")
	var hint := Label.new()
	hint.text = "Random fires and survival rules when time is at or below realtime speed."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)


func _build_environment_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Environment")
	_add_section_lbl(v, "Clouds")
	_clouds_cutoff = _add_slider(v, "Cloud cover",  0.0, 1.0, 0.01, _on_clouds_cutoff)
	_clouds_weight = _add_slider(v, "Cloud weight", 0.0, 1.0, 0.01, _on_clouds_weight)

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Future Climate Scenario")
	_scenario_opt = OptionButton.new()
	_scenario_opt.add_item("Low (+1.5 °C by 2100, SSP1-2.6)",   0)
	_scenario_opt.add_item("Moderate (+2 °C, SSP2-4.5)",         1)
	_scenario_opt.add_item("High (+3–4 °C, SSP3-7.0)",           2)
	_scenario_opt.add_item("Very high (+5 °C, SSP5-8.5)",        3)
	_scenario_opt.add_theme_color_override("font_color", C_TEXT)
	_scenario_opt.item_selected.connect(_on_scenario_changed)
	v.add_child(_scenario_opt)
	var hint2 := Label.new()
	hint2.text = "Affects weather simulation and projected record book columns after the current year."
	hint2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint2.custom_minimum_size = Vector2(420, 0)
	hint2.add_theme_color_override("font_color", C_TEXT_S)
	hint2.add_theme_font_size_override("font_size", 10)
	v.add_child(hint2)


func _build_lighting_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Lighting")
	_add_section_lbl(v, "Graphics Quality (performance)")
	_graphics_quality = OptionButton.new()
	_graphics_quality.add_item("Low (fastest)",  0)
	_graphics_quality.add_item("Medium",          1)
	_graphics_quality.add_item("High (default)",  2)
	_graphics_quality.add_theme_color_override("font_color", C_TEXT)
	_graphics_quality.item_selected.connect(_on_graphics_quality)
	v.add_child(_graphics_quality)
	var gq_hint := Label.new()
	gq_hint.text = "Lower presets reduce shadow-map size, soft-shadow filtering, and disable TAA for higher FPS on weaker GPUs."
	gq_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gq_hint.custom_minimum_size = Vector2(420, 0)
	gq_hint.add_theme_color_override("font_color", C_TEXT_S)
	gq_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(gq_hint)
	v.add_child(HSeparator.new())
	_sun_energy         = _add_slider(v, "Sun energy",     0.0, 3.0, 0.05, _on_sun_energy)
	_shadow_quality     = _add_slider(v, "Shadow quality", 0.0, 3.0, 1.0,  _on_shadow_quality)
	_shadow_quality_lbl = _add_status_label(v, "Shadow Quality: High")
	_moon_energy        = _add_slider(v, "Moon energy",    0.0, 2.0, 0.05, _on_moon_energy)
	_moon_phase_lbl     = _add_status_label(v, "")
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Advanced")
	_ambient_energy = _add_slider(v, "Ambient ×", 0.0, 3.0, 0.05, _on_ambient_energy_mult)
	_ambient_sky = _add_slider(v, "Sky ambient", 0.0, 1.0, 0.01, _on_ambient_sky_contribution)
	_glow_enabled = _add_check(v, "Glow / bloom enabled", _on_glow_enabled)
	_glow_intensity = _add_slider(v, "Glow intensity ×", 0.0, 3.0, 0.05, _on_glow_intensity_mult)
	_ssao_enabled = _add_check(v, "SSAO (ambient occlusion)", _on_ssao_enabled)
	_ssil_enabled = _add_check(v, "SSIL (indirect light)", _on_ssil_enabled)
	_sdfgi_enabled = _add_check(v, "SDFGI (global illumination)", _on_sdfgi_enabled)
	_volumetric_fog = _add_check(v, "Volumetric fog", _on_volumetric_fog_enabled)
	_fog_amount = _add_slider(v, "Fog amount", 0.0, 1.0, 0.01, _on_fog_amount)
	_tonemap_mode = _add_option(v, "Tonemap", ["Linear", "Reinhard", "Filmic", "ACES", "AgX"], _on_tonemap_mode)
	_tonemap_exposure = _add_slider(v, "Exposure", 0.1, 4.0, 0.05, _on_tonemap_exposure)
	_tonemap_white = _add_slider(v, "Tonemap white", 0.1, 16.0, 0.1, _on_tonemap_white)
	_sun_size = _add_slider(v, "Sun disc size", 0.02, 0.5, 0.005, _on_sun_size)
	_moon_size = _add_slider(v, "Moon disc size", 0.01, 0.2, 0.005, _on_moon_size)
	_moon_glow = _add_slider(v, "Moon glow", 0.0, 2.0, 0.05, _on_moon_glow)


func _build_stars_planets_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Stars & Planets")
	_add_section_lbl(v, "Stars")
	_stars_brightness = _add_slider(v, "Brightness", 0.0, 3.0, 0.05, _on_stars_brightness)
	_stars_scale = _add_slider(v, "Scale", 0.5, 2.0, 0.05, _on_stars_scale)
	_stars_twinkle = _add_slider(v, "Twinkle", 0.0, 1.0, 0.05, _on_stars_twinkle)
	_stars_horizon = _add_slider(v, "Horizon fade", 0.0, 1.0, 0.05, _on_stars_horizon_fade)
	_stars_north = _add_slider(v, "RA offset", -360.0, 360.0, 0.5, _on_stars_north_offset)
	_stars_decl = _add_slider(v, "Dec offset", -180.0, 180.0, 0.5, _on_stars_decl_offset)
	_stars_flip_v = _add_check(v, "Flip vertical", _on_stars_flip_vertical)
	_stars_flip_h = _add_check(v, "Flip horizontal", _on_stars_flip_horizontal)
	var tex_row := HBoxContainer.new()
	tex_row.add_theme_constant_override("separation", 6)
	var upload_btn := Button.new()
	upload_btn.text = "Upload star image…"
	upload_btn.pressed.connect(_on_upload_star_texture)
	tex_row.add_child(upload_btn)
	var reset_btn := Button.new()
	reset_btn.text = "Reset texture"
	reset_btn.pressed.connect(_on_reset_star_texture)
	tex_row.add_child(reset_btn)
	v.add_child(tex_row)
	_star_texture_lbl = _add_status_label(v, "")
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Planets")
	_planets_master = _add_check(v, "Show planets", _on_planets_master)
	for spec in [
		["mercury", "Mercury"], ["venus", "Venus"], ["mars", "Mars"],
		["jupiter", "Jupiter"], ["saturn", "Saturn"],
	]:
		_build_planet_section(v, spec[0], spec[1])


func _build_location_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Location")
	var loc_row := HBoxContainer.new()
	loc_row.add_theme_constant_override("separation", 8)
	v.add_child(loc_row)
	_latitude  = _mk_coord_spin(-90.0, 90.0)
	_longitude = _mk_coord_spin(-180.0, 180.0)
	_latitude.value_changed.connect(_on_latitude)
	_longitude.value_changed.connect(_on_longitude)
	loc_row.add_child(_wrap_spin("Lat", _latitude))
	loc_row.add_child(_wrap_spin("Lon", _longitude))
	_lat_lbl    = _add_status_label(v, "")
	_lon_lbl    = _add_status_label(v, "")
	_auto_dst   = _add_check(v, "Auto DST", _on_auto_dst)
	_manual_dst = _add_check(v, "Manual DST (force +1 h)", _on_manual_dst)
	_dst_status = _add_status_label(v, "")
	var loc_btn := Button.new()
	loc_btn.text = "Open location picker (M)"
	loc_btn.pressed.connect(_on_open_location_picker)
	v.add_child(loc_btn)


func _build_live_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Live Mode")
	var hint := Label.new()
	hint.text = "Locks simulation to wall clock at 1× speed for live Home Assistant data. Turn off to scrub and speed up time."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)
	_live_mode   = _add_check(v, "Live mode (sync to system clock)", _on_live_mode)
	_live_status = _add_status_label(v, "")


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

func _add_section_lbl(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", 12)
	parent.add_child(lbl)


func _add_slider(parent: Control, label: String, min_v: float, max_v: float,
		step: float, cb: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(110, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = step
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(cb)
	row.add_child(sl)
	parent.add_child(row)
	return sl


func _add_check(parent: Control, text: String, cb: Callable) -> CheckBox:
	var cbn := CheckBox.new()
	cbn.text = text
	cbn.add_theme_color_override("font_color", C_TEXT)
	cbn.toggled.connect(cb)
	parent.add_child(cbn)
	return cbn


func _add_option(parent: Control, label: String, items: Array, cb: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(110, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in items.size():
		opt.add_item(str(items[i]), i)
	opt.item_selected.connect(cb)
	row.add_child(opt)
	parent.add_child(row)
	return opt


func _add_color_row(parent: Control, label: String, start: Color, cb: Callable) -> ColorPickerButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(110, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var cp := ColorPickerButton.new()
	cp.color = start
	cp.custom_minimum_size = Vector2(52, 24)
	cp.color_changed.connect(cb)
	row.add_child(cp)
	parent.add_child(row)
	return cp


func _build_planet_section(parent: Control, id: String, title: String) -> void:
	_add_section_lbl(parent, title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var en := CheckBox.new()
	en.text = "Show"
	en.add_theme_color_override("font_color", C_TEXT)
	var pid := id
	en.toggled.connect(func(on: bool) -> void: _on_planet_enabled(pid, on))
	row.add_child(en)
	_planet_enabled[id] = en
	_planet_brightness[id] = _add_slider(parent, "Brightness", 0.0, 5.0, 0.1,
		func(v: float) -> void: _on_planet_brightness(pid, v))
	_planet_size[id] = _add_slider(parent, "Size", 0.001, 0.02, 0.0005,
		func(v: float) -> void: _on_planet_size(pid, v))
	_planet_glow[id] = _add_slider(parent, "Glow", 0.0, 2.0, 0.05,
		func(v: float) -> void: _on_planet_glow(pid, v))
	_planet_color[id] = _add_color_row(parent, "Color", Color.WHITE,
		func(c: Color) -> void: _on_planet_color(pid, c))


func _add_status_label(parent: Control, text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	return lbl


func _mk_coord_spin(min_v: float, max_v: float) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = 0.0000001
	sp.custom_arrow_step = 0.001
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sp


func _wrap_spin(title: String, spin: SpinBox) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hdr := Label.new()
	hdr.text = title
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	hdr.add_theme_font_size_override("font_size", 9)
	box.add_child(hdr)
	box.add_child(spin)
	return box


# ---------------------------------------------------------------------------
# Label refresh
# ---------------------------------------------------------------------------

func _refresh_labels() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	var snap: Dictionary = SimSettingsController.get_state_snapshot()
	if _shadow_quality_lbl and _shadow_quality:
		var names: Array = ["Low", "Medium", "High", "Ultra"]
		var lvl: int = clampi(int(_shadow_quality.value), 0, 3)
		_shadow_quality_lbl.text = "Shadow Quality: %s" % names[lvl]
	if _moon_phase_lbl:
		_moon_phase_lbl.text = snap.get("moon_phase_text", "")
	if _latitude and _lat_lbl:
		var lat: float = _latitude.value
		var dir: String = "N" if lat >= 0.0 else "S"
		_lat_lbl.text = "%.6f° %s %s" % [absf(lat), dir, SimSettingsController.get_latitude_hint(lat)]
	if _longitude and _lon_lbl:
		var lon: float = _longitude.value
		var dir2: String = "E" if lon >= 0.0 else "W"
		_lon_lbl.text = "%.6f° %s" % [absf(lon), dir2]
	if _manual_dst:
		_manual_dst.visible = _auto_dst == null or not _auto_dst.button_pressed
	if _dst_status:
		_dst_status.text = snap.get("dst_status", "")
	if _live_status:
		var lm: Dictionary = snap.get("live_mode_status", {})
		_live_status.text = lm.get("text", "")
		_live_status.add_theme_color_override("font_color", lm.get("color", C_TEXT_S))
	if _survival_status:
		var gp: Dictionary = snap.get("gameplay_status", {})
		_survival_status.text = gp.get("text", "")
		_survival_status.add_theme_color_override("font_color", gp.get("color", C_TEXT_S))
	if _star_texture_lbl:
		var tp := str(snap.get("texture_path", ""))
		_star_texture_lbl.text = "Texture: %s" % (tp if not tp.is_empty() else "default starmap")


func _sync_advanced_from_snapshot(snap: Dictionary) -> void:
	if _ambient_energy:
		_ambient_energy.value = snap.get("ambient_energy_mult", 1.0)
	if _ambient_sky:
		_ambient_sky.value = snap.get("ambient_sky_contribution", 0.15)
	if _glow_intensity:
		_glow_intensity.value = snap.get("glow_intensity_mult", 1.0)
	if _glow_enabled:
		_glow_enabled.button_pressed = snap.get("glow_user_enabled", true)
	if _ssao_enabled:
		_ssao_enabled.button_pressed = snap.get("ssao_enabled", true)
	if _ssil_enabled:
		_ssil_enabled.button_pressed = snap.get("ssil_enabled", true)
	if _sdfgi_enabled:
		_sdfgi_enabled.button_pressed = snap.get("sdfgi_enabled", false)
	if _volumetric_fog:
		_volumetric_fog.button_pressed = snap.get("volumetric_fog_enabled", false)
	if _fog_amount:
		_fog_amount.value = snap.get("fog_amount", 0.2)
	if _tonemap_mode:
		_tonemap_mode.selected = clampi(int(snap.get("tonemap_mode", Environment.TONE_MAPPER_LINEAR)), 0, 4)
	if _tonemap_exposure:
		_tonemap_exposure.value = snap.get("tonemap_exposure", 1.0)
	if _tonemap_white:
		_tonemap_white.value = snap.get("tonemap_white", 1.0)
	if _sun_size:
		_sun_size.value = snap.get("sun_size", 0.15)
	if _moon_size:
		_moon_size.value = snap.get("moon_size", 0.05)
	if _moon_glow:
		_moon_glow.value = snap.get("moon_glow", 0.5)


func _sync_stars_planets_from_snapshot(snap: Dictionary) -> void:
	if _stars_brightness:
		_stars_brightness.value = snap.get("stars_brightness", 1.0)
	if _stars_scale:
		_stars_scale.value = snap.get("stars_scale", 1.0)
	if _stars_twinkle:
		_stars_twinkle.value = snap.get("stars_twinkle", 0.3)
	if _stars_horizon:
		_stars_horizon.value = snap.get("stars_horizon_fade", 0.5)
	if _stars_north:
		_stars_north.value = snap.get("stars_north_offset", 0.0)
	if _stars_decl:
		_stars_decl.value = snap.get("stars_declination_offset", 0.0)
	if _stars_flip_v:
		_stars_flip_v.button_pressed = snap.get("stars_flip_vertical", false)
	if _stars_flip_h:
		_stars_flip_h.button_pressed = snap.get("stars_flip_horizontal", false)
	if _planets_master:
		var all_on := true
		for pid in _planet_enabled:
			if not bool(snap.get("%s_enabled" % pid, true)):
				all_on = false
				break
		_planets_master.button_pressed = all_on
	for pid in _planet_enabled:
		if _planet_enabled[pid]:
			(_planet_enabled[pid] as CheckBox).button_pressed = snap.get("%s_enabled" % pid, true)
		if _planet_brightness.has(pid):
			(_planet_brightness[pid] as HSlider).value = snap.get("%s_brightness" % pid, 1.0)
		if _planet_size.has(pid):
			(_planet_size[pid] as HSlider).value = snap.get("%s_size" % pid, 0.005)
		if _planet_glow.has(pid):
			(_planet_glow[pid] as HSlider).value = snap.get("%s_glow" % pid, 0.3)
		if _planet_color.has(pid):
			(_planet_color[pid] as ColorPickerButton).color = snap.get("%s_color" % pid, Color.WHITE)


# ---------------------------------------------------------------------------
# Signal handlers (unchanged from original)
# ---------------------------------------------------------------------------

func _on_clouds_cutoff(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_clouds_cutoff_ui(v)

func _on_clouds_weight(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_clouds_weight(v)

func _on_sun_energy(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sun_energy(v)

func _on_shadow_quality(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_shadow_quality(v)
	_refresh_labels()

func _on_graphics_quality(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_graphics_quality(idx)

func _on_moon_energy(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_moon_energy(v)

func _on_ambient_energy_mult(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_ambient_energy_mult(v)

func _on_ambient_sky_contribution(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_ambient_sky_contribution(v)

func _on_glow_intensity_mult(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_glow_intensity_mult(v)

func _on_glow_enabled(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_glow_user_enabled(on)

func _on_ssao_enabled(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_ssao_enabled(on)

func _on_ssil_enabled(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_ssil_enabled(on)

func _on_sdfgi_enabled(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_sdfgi_enabled(on)

func _on_volumetric_fog_enabled(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_volumetric_fog_enabled(on)

func _on_fog_amount(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_fog_amount(v)

func _on_tonemap_mode(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_tonemap_mode(idx)

func _on_tonemap_exposure(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_tonemap_exposure(v)

func _on_tonemap_white(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_tonemap_white(v)

func _on_sun_size(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sun_size(v)

func _on_moon_size(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_moon_size(v)

func _on_moon_glow(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_moon_glow(v)

func _on_stars_brightness(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_brightness", v)

func _on_stars_scale(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_scale", v)

func _on_stars_twinkle(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_twinkle", v)

func _on_stars_horizon_fade(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_horizon_fade", v)

func _on_stars_north_offset(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_north_offset", v)

func _on_stars_decl_offset(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_declination_offset", v)

func _on_stars_flip_vertical(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_flip_vertical", on)

func _on_stars_flip_horizontal(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_flip_horizontal", on)

func _on_upload_star_texture() -> void:
	if _star_file_dialog == null:
		_star_file_dialog = FileDialog.new()
		_star_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_star_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_star_file_dialog.filters = PackedStringArray(["*.png ; PNG", "*.jpg ; JPEG", "*.jpeg ; JPEG", "*.webp ; WebP"])
		_star_file_dialog.file_selected.connect(_on_star_texture_selected)
		add_child(_star_file_dialog)
	_star_file_dialog.popup_centered_ratio(0.6)

func _on_star_texture_selected(path: String) -> void:
	if not is_instance_valid(SimSettingsController):
		return
	if SimSettingsController.upload_star_texture(path):
		refresh_from_controller()

func _on_reset_star_texture() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	SimSettingsController.reset_star_texture()
	refresh_from_controller()

func _on_planets_master(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_all_planets_enabled(on)
	for pid in _planet_enabled:
		if _planet_enabled[pid]:
			(_planet_enabled[pid] as CheckBox).button_pressed = on

func _on_planet_enabled(pid: String, on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_setting("%s_enabled" % pid, on)

func _on_planet_brightness(pid: String, v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_setting("%s_brightness" % pid, v)

func _on_planet_size(pid: String, v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_setting("%s_size" % pid, v)

func _on_planet_glow(pid: String, v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_setting("%s_glow" % pid, v)

func _on_planet_color(pid: String, c: Color) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_setting("%s_color" % pid, c)

func _on_latitude(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_latitude(v)
	_refresh_labels()

func _on_longitude(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_longitude(v)
	_refresh_labels()

func _on_auto_dst(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_auto_dst(on)
	_refresh_labels()

func _on_manual_dst(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_manual_dst(on)
	_refresh_labels()

func _on_live_mode(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_live_mode(on)
	_refresh_labels()

func _on_survival(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_survival_active(on)
	_refresh_labels()

func _on_scenario_changed(idx: int) -> void:
	if _syncing:
		return
	var cps := get_node_or_null("/root/ClimateProjectionService")
	if cps != null and cps.has_method("set_scenario"):
		cps.call("set_scenario", idx)


func _save_opentopo_key() -> void:
	if _opentopo_input == null:
		return
	var key := _sanitize_api_key(_opentopo_input.text.strip_edges())
	_line_edit_sanitize_guard = true
	_opentopo_input.text = key
	_line_edit_sanitize_guard = false
	var cfg := ConfigFile.new()
	cfg.load("user://terrain_config.cfg")
	cfg.set_value("opentopography", "api_key", key)
	var err := cfg.save("user://terrain_config.cfg")
	if err != OK:
		_set_keys_status("OpenTopography save failed (error %d)." % err, true)
		return
	_set_keys_status("OpenTopography key saved.", false)


func _save_cds_key() -> void:
	if _cds_input == null:
		return
	var key := _normalize_cds_key(_cds_input.text)
	_line_edit_sanitize_guard = true
	_cds_input.text = key
	_line_edit_sanitize_guard = false
	var err := _write_cds_key_config(key)
	if err != OK:
		_set_keys_status("CDS key save failed (error %d)." % err, true)
		return
	_set_keys_status("CDS key saved. Climate data loads when you open the Record Book.", false)


func _write_cds_key_config(key: String) -> Error:
	_ensure_user_config_dir()
	var cfg := ConfigFile.new()
	cfg.load("user://keys_config.cfg")
	cfg.set_value("copernicus", "api_key", key)
	return cfg.save("user://keys_config.cfg")


func _ensure_user_config_dir() -> void:
	var dir_path := "user://".trim_suffix("/")
	if dir_path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))


func _set_keys_status(msg: String, is_error: bool) -> void:
	if _keys_status == null:
		return
	_keys_status.text = msg
	_keys_status.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45) if is_error else C_TEXT_S)


static func _sanitize_api_key(raw: String) -> String:
	var out := PackedStringArray()
	for i in raw.length():
		var code := raw.unicode_at(i)
		if code >= 32 and code <= 126:
			out.append(raw.substr(i, 1))
	return "".join(out).strip_edges()


static func _normalize_cds_key(raw: String) -> String:
	var text := _sanitize_api_key(raw.replace("\r", ""))
	if text.is_empty():
		return ""
	# Multi-line ~/.cdsapirc paste — keep the key line only.
	var best := ""
	for line in text.split("\n", false):
		var t := line.strip_edges()
		if t.is_empty():
			continue
		var lower := t.to_lower()
		if lower.begins_with("url:"):
			continue
		if lower.begins_with("key:"):
			return _sanitize_api_key(t.substr(4).strip_edges())
		if best.is_empty():
			best = t
	return best


func _sanitize_line_edit(ed: LineEdit, cds_format: bool) -> void:
	if ed == null:
		return
	var normalized := _normalize_cds_key(ed.text) if cds_format else _sanitize_api_key(ed.text)
	if normalized == ed.text:
		return
	_line_edit_sanitize_guard = true
	ed.text = normalized
	_line_edit_sanitize_guard = false


func _resolve_main_for_settings() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene != null and "day_time" in scene:
		return scene
	for child in tree.root.get_children():
		if "day_time" in child and "sun" in child:
			return child
	return null


func _on_open_location_picker() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var ui_layer := get_parent()
	if ui_layer == null:
		return
	var picker := ui_layer.get_node_or_null("LocationPickerUI")
	if picker != null and picker.has_method("show_picker"):
		picker.show_picker()
