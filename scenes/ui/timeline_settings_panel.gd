extends Control

## Settings modal opened from the timeline gear icon.
## A full-screen backdrop + a wide centred panel: a grouped, searchable page
## list on the left and one page at a time on the right. The pages still live
## in a TabContainer (its tab bar hidden) so every `_build_*_tab(tabs)` builder
## and every caller that selects a page by `current_tab` keeps working; the
## sidebar only drives `current_tab`. Fifteen pages used to share one tab bar
## and seven of them hid behind the ‹ › scroll arrows. Each page is a
## ScrollContainer so content is never clipped by the viewport.

const C_PANEL  := UITheme.C_PANEL
const C_BORDER := UITheme.C_BORDER
const C_PRIMARY := UITheme.C_PRIMARY
const C_TEXT   := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S

## Wanted modal size; UiFit shrinks it to the area above the timeline.
const PANEL_DESIRED_SIZE := Vector2(1180.0, 880.0)
const NAV_WIDTH := 220.0
const PREFS_PATH := "user://ui_prefs.cfg"

## The pages the LAUNCH HUB shows (`hub_mode`, no world running): every one
## reads and writes files, not Main. The Lighting page is built in its
## graphics-preset form there (quality tier, performance, terrain detail,
## shadows); the sky / sun / fog fine-tuning needs a lit world.
const HUB_PAGES := ["Lighting", "Interface", "Player", "Controls", "NPC", "Stars & Planets", "Window Wall"]

## Set BEFORE the node enters the tree (the hub creates it by script): only
## HUB_PAGES are built, the sliders read SimSettingsController.hub_snapshot()
## and every apply_* the hub cannot do live is stored for sim_settings.cfg.
var hub_mode: bool = false

## The sidebar: category -> page titles, in order. A page built by a
## `_build_*_tab` that is not listed here lands under "Other", so it can never
## go missing from the nav.
const CATEGORIES := [
	["Simulation", ["Gameplay", "NPC", "Extreme Weather", "Live Mode"]],
	["Player & controls", ["Player", "Controls", "Drone", "Interface", "Keys"]],
	["Graphics & sky", ["Lighting", "Environment", "Stars & Planets"]],
	["Site & hardware", ["Location", "Solar", "Window Wall"]],
	["Integrations", ["Home Assistant"]],
]

var _timeline: Control = null
var _syncing: bool = false

var _clouds_cutoff: HSlider
var _clouds_weight: HSlider
var _sun_energy: HSlider
var _shadow_quality: HSlider
var _shadow_quality_lbl: Label
var _graphics_quality: OptionButton
var _terrain_quality: HSlider
var _terrain_quality_lbl: Label
var _render_scale: HSlider
var _prop_draw_dist: HSlider
var _prop_shadows: CheckBox
var _prop_shadow_detail: OptionButton
var _perf_hud: CheckBox
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
var _msaa_mode: OptionButton
var _tonemap_exposure: HSlider
var _tonemap_white: HSlider
var _sun_size: HSlider
var _moon_size: HSlider
var _moon_glow: HSlider
var _sun_glow: HSlider
var _sun_glow_size: HSlider
var _sun_aureole: HSlider
var _shadow_opacity: HSlider
var _god_rays: CheckBox
var _cirrus_amount: HSlider
var _cirrus_wave_frequency: HSlider
var _cirrus_wave_intensity: HSlider
var _cloud_shadows: CheckBox
var _building_shadows: CheckBox
var _player_fov: HSlider
var _drone_fov: HSlider
var _drone_max_speed: HSlider
var _drone_vertical_speed: HSlider
var _drone_acceleration: HSlider
var _drone_drag: HSlider
var _drone_steering: HSlider
var _drone_min_altitude: HSlider
var _drone_max_altitude: HSlider
var _drone_tilt_intensity: HSlider
var _drone_tilt_speed: HSlider
var _stars_brightness: HSlider
var _stars_twinkle: HSlider
var _stars_horizon: HSlider
var _stars_glow: HSlider
var _star_reg_lbl: Label
var _stars_point_size: HSlider
var _stars_saturation: HSlider
var _stars_contrast: HSlider
var _stars_bg_cut: HSlider
var _stars_wash: HSlider
var _mw_gain: HSlider
var _mw_sat: HSlider
var _mw_tint: ColorPickerButton
var _star_quality: OptionButton
var _planet_labels: OptionButton
var _twilight_drama: HSlider
var _twilight_length: HSlider
var _sun_warmth: HSlider
var _airglow: HSlider
var _airglow_col: ColorPickerButton
var _light_pollution: HSlider
var _light_pollution_col: ColorPickerButton
var _moon_sky_glow: HSlider
var _star_trails: CheckBox
var _star_trail_length: HSlider
var _lock_sky: CheckBox
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
var _survival: CheckBox
var _plant_growth: CheckBox
var _connector_losses: CheckBox
var _conduits_3d_visible: CheckBox
var _conduit_flow_glow: CheckBox
var _force_rainbow: CheckBox
var _analemma_drift: HSlider
var _analemma_noon: HSlider
var _analemma_thickness: HSlider
var _analemma_solar_col: ColorPickerButton
var _analemma_lunar_col: ColorPickerButton
var _analemma_type: OptionButton
var _show_sun_path: CheckBox
var _show_moon_path: CheckBox
var _show_planet_paths: CheckBox
var _planet_path_frame: OptionButton
var _analemma_star_reveal: HSlider
var _zodiac_mode: OptionButton
var _zodiac_opacity: HSlider
var _zodiac_lines: CheckBox
var _zodiac_labels: CheckBox
var _zodiac_ophiuchus: CheckBox
var _zodiac_ecliptic: CheckBox
var _live_status: Label
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
var _tabs: TabContainer = null
var _nav_box: VBoxContainer = null
var _nav_buttons: Dictionary = {}     # page title -> Button
var _nav_headers: Dictionary = {}     # category -> Label
var _nav_search: LineEdit = null
var _nav_count_lbl: Label = null
var _page_text: Dictionary = {}       # page title -> lower-case searchable text
var _search_hits: Array = []          # page titles matching the search, nav order
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
	# The HUD claim is made by open()/close() under its own owner id.
	UiFit.keep_fitted(_center_panel, PANEL_DESIRED_SIZE, UiFit.MARGIN, false)


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
	# Called separately because refresh_from_controller() early-returns when
	# SimSettingsController has no Main or an empty snapshot, and this tab reads
	# its state from GameplayRules / ExtremeWeatherPrefs / the director instead.
	_refresh_extreme_weather_tab()
	_refresh_window_wall_tab()
	_request_center_layout()
	if _tabs != null and _nav_search != null and _nav_search.text.is_empty():
		var last := _load_last_page()
		if not last.is_empty():
			open_page(last)
	visible = true
	CursorController.request_modal("timeline_settings", Callable(self, "close"))
	HudLayout.claim_modal("timeline_settings")


func close() -> void:
	if not visible:
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.persist_settings()
	visible = false
	CursorController.release_modal("timeline_settings")
	HudLayout.release("timeline_settings")


func refresh_from_controller() -> void:
	if not is_instance_valid(SimSettingsController):
		return
	var snap: Dictionary = SimSettingsController.get_state_snapshot()
	if snap.is_empty() and hub_mode:
		# No Main at the hub: the saved values are the state.
		_refresh_hub(SimSettingsController.hub_snapshot())
		return
	if snap.is_empty():
		return
	_syncing = true
	if _clouds_cutoff:
		_clouds_cutoff.value = snap.get("clouds_cutoff_ui", 0.0)
	if _clouds_weight:
		_clouds_weight.value = snap.get("clouds_weight", 0.5)
	if _sun_energy:
		_sun_energy.value = snap.get("sun_energy_mult", 1.0)
	if _shadow_quality:
		_shadow_quality.value = snap.get("shadow_quality", 2.0)
	if _shadow_opacity:
		_shadow_opacity.value = snap.get("shadow_opacity", 1.0)
	if _graphics_quality:
		_graphics_quality.selected = clampi(int(snap.get("graphics_quality", 2)), 0, 3)
	_sync_terrain_quality()
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
	_sync_gameplay_from_snapshot(snap)
	_sync_advanced_from_snapshot(snap)
	_sync_drone_from_snapshot(snap)
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


## The hub's pages from the saved files (SimSettingsController.hub_snapshot):
## only the controls those pages carry, every write guarded by _syncing.
func _refresh_hub(snap: Dictionary) -> void:
	_syncing = true
	if _shadow_quality:
		_shadow_quality.value = float(snap.get("shadow_quality", 2))
	if _shadow_opacity:
		_shadow_opacity.value = float(snap.get("shadow_opacity", 1.0))
	if _graphics_quality:
		_graphics_quality.selected = clampi(int(snap.get("graphics_quality", 2)), 0, 3)
	_sync_terrain_quality()
	if _player_fov:
		_player_fov.value = float(snap.get("player_fov", 50.0))
	_sync_stars_planets_from_snapshot(snap)
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
	title_lbl.text = "⚙  Settings" if hub_mode else "⚙  Simulation Settings"
	title_lbl.add_theme_color_override("font_color", C_TEXT)
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)
	var close_btn := Button.new()
	IconButton.as_close(close_btn, "Close (Esc)")
	close_btn.pressed.connect(close)
	title_row.add_child(close_btn)

	outer.add_child(HSeparator.new())

	# Body: page list on the left, the page on the right.
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	outer.add_child(body)
	body.add_child(_build_nav())
	body.add_child(VSeparator.new())

	# TabContainer — one per settings section; its own tab bar is hidden and
	# the sidebar selects the page.
	var tabs := TabContainer.new()
	_tabs = tabs
	tabs.tabs_visible = false
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tab_panel_sb := StyleBoxFlat.new()
	tab_panel_sb.bg_color = C_PANEL
	tabs.add_theme_stylebox_override("panel", tab_panel_sb)
	body.add_child(tabs)

	if hub_mode:
		# Only the pages that need no Main (HUB_PAGES), in the sidebar's order.
		_build_lighting_tab(tabs)
		_build_player_tab(tabs)
		_build_controls_tab(tabs)
		_build_interface_tab(tabs)
		_build_npc_tab(tabs)
		_build_window_wall_tab(tabs)
		_build_stars_planets_tab(tabs)
	else:
		_build_gameplay_tab(tabs)
		_build_player_tab(tabs)
		_build_controls_tab(tabs)
		_build_interface_tab(tabs)
		_build_drone_tab(tabs)
		_build_environment_tab(tabs)
		_build_lighting_tab(tabs)
		_build_npc_tab(tabs)
		_build_window_wall_tab(tabs)
		_build_extreme_weather_tab(tabs)
		_build_stars_planets_tab(tabs)
		_build_solar_tab(tabs)
		_build_ha_tab(tabs)
		_build_location_tab(tabs)
		_build_live_tab(tabs)
		_build_keys_tab(tabs)
	_populate_nav()
	tabs.tab_changed.connect(_on_page_changed)
	_on_page_changed(tabs.current_tab)
	_request_center_layout()


# ---------------------------------------------------------------------------
# Sidebar: grouped page list + search
# ---------------------------------------------------------------------------

func _build_nav() -> Control:
	var wrap := MarginContainer.new()
	wrap.custom_minimum_size = Vector2(NAV_WIDTH, 0)
	wrap.add_theme_constant_override("margin_left", 10)
	wrap.add_theme_constant_override("margin_right", 8)
	wrap.add_theme_constant_override("margin_top", 8)
	wrap.add_theme_constant_override("margin_bottom", 8)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	wrap.add_child(col)
	_nav_search = LineEdit.new()
	_nav_search.placeholder_text = "Search settings…"
	_nav_search.clear_button_enabled = true
	_nav_search.tooltip_text = "Type to find a setting; Enter opens the first page that has it."
	_nav_search.text_changed.connect(_on_search_changed)
	_nav_search.text_submitted.connect(_on_search_submitted)
	col.add_child(_nav_search)
	_nav_count_lbl = Label.new()
	_nav_count_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_nav_count_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_nav_count_lbl.visible = false
	col.add_child(_nav_count_lbl)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_nav_box = VBoxContainer.new()
	_nav_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nav_box.add_theme_constant_override("separation", 1)
	scroll.add_child(_nav_box)
	return wrap


func _populate_nav() -> void:
	var titles: Array = []
	for i in _tabs.get_tab_count():
		titles.append(_tabs.get_tab_title(i))
	var placed := {}
	var groups: Array = []
	for cat in CATEGORIES:
		var pages: Array = []
		for t in cat[1]:
			if t in titles:
				pages.append(t)
				placed[t] = true
		groups.append([cat[0], pages])
	var other: Array = []
	for t in titles:
		if not placed.has(t):
			other.append(t)
	if not other.is_empty():
		groups.append(["Other", other])
	for g in groups:
		if (g[1] as Array).is_empty():
			continue
		var hdr := Label.new()
		hdr.text = str(g[0]).to_upper()
		hdr.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hdr.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		if _nav_box.get_child_count() > 0:
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(0, 6)
			_nav_box.add_child(gap)
			hdr.set_meta("gap", gap)
		_nav_box.add_child(hdr)
		_nav_headers[g[0]] = hdr
		for t in g[1]:
			var b := Button.new()
			b.text = t
			b.toggle_mode = true
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.custom_minimum_size = Vector2(0, 26)
			b.focus_mode = Control.FOCUS_NONE
			b.set_meta("category", g[0])
			b.pressed.connect(open_page.bind(t))
			_nav_box.add_child(b)
			_nav_buttons[t] = b
	for i in _tabs.get_tab_count():
		var t := _tabs.get_tab_title(i)
		_page_text[t] = (t + " " + _collect_text(_tabs.get_tab_control(i))).to_lower()
	_style_nav()


## Every visible word on a page (labels, buttons, check boxes, option items,
## tooltips) — what the search box matches against.
func _collect_text(n: Node) -> String:
	var parts := PackedStringArray()
	_collect_text_into(n, parts)
	return " ".join(parts)


func _collect_text_into(n: Node, parts: PackedStringArray) -> void:
	if n is Label:
		parts.append((n as Label).text)
	elif n is Button:
		parts.append((n as Button).text)
	if n is Control and not (n as Control).tooltip_text.is_empty():
		parts.append((n as Control).tooltip_text)
	if n is OptionButton:
		var ob := n as OptionButton
		for i in ob.item_count:
			parts.append(ob.get_item_text(i))
	for c in n.get_children():
		_collect_text_into(c, parts)


## Opens a settings page by its title ("Solar", "Window Wall"…). False when
## there is no such page.
func open_page(title: String) -> bool:
	if _tabs == null:
		return false
	for i in _tabs.get_tab_count():
		if _tabs.get_tab_title(i) == title:
			if _tabs.current_tab != i:
				_tabs.current_tab = i
			else:
				_on_page_changed(i)
			return true
	return false


func current_page() -> String:
	if _tabs == null or _tabs.current_tab < 0:
		return ""
	return _tabs.get_tab_title(_tabs.current_tab)


## Every page title in nav order (the modal audit walks them).
func page_titles() -> Array:
	var out: Array = []
	if _nav_box == null:
		return out
	for c in _nav_box.get_children():
		if c is Button:
			out.append((c as Button).text)
	return out


## The nav button for a page (the modal audit checks they are all on screen).
func nav_button(title: String) -> Button:
	return _nav_buttons.get(title, null) as Button


func _on_page_changed(_idx: int) -> void:
	_style_nav()
	var t := current_page()
	if not t.is_empty() and (_nav_search == null or _nav_search.text.is_empty()):
		_save_last_page(t)


func _style_nav() -> void:
	var cur := current_page()
	var searching := _nav_search != null and not _nav_search.text.strip_edges().is_empty()
	for t in _nav_buttons.keys():
		var b := _nav_buttons[t] as Button
		var on: bool = t == cur
		b.set_pressed_no_signal(on)
		var normal := _nav_style(on, false)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("pressed", normal)
		b.add_theme_stylebox_override("hover", _nav_style(on, true))
		b.add_theme_stylebox_override("hover_pressed", _nav_style(on, true))
		b.add_theme_font_size_override("font_size", UITheme.FONT_MD)
		var col: Color = UITheme.C_TEXT if on else UITheme.C_TEXT_S
		if searching and not on and t in _search_hits:
			col = UITheme.C_AMBER
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			b.add_theme_color_override(k, UITheme.C_TEXT if k.contains("hover") else col)


## Flat list row; the open page gets a raised fill and a cyan bar on the left.
func _nav_style(on: bool, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.content_margin_left = 12
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	sb.set_corner_radius_all(4)
	if on:
		sb.bg_color = UITheme.C_PANEL_RAISED
		sb.border_color = UITheme.C_PRIMARY
		sb.border_width_left = 3
	elif hover:
		sb.bg_color = Color(UITheme.C_PANEL_RAISED, 0.6)
	else:
		sb.bg_color = Color(0, 0, 0, 0)
	return sb


func _on_search_changed(q: String) -> void:
	q = q.strip_edges().to_lower()
	_search_hits.clear()
	var words := q.split(" ", false)
	for c in _nav_box.get_children():
		if not (c is Button):
			continue
		var t := (c as Button).text
		var ok := true
		for w in words:
			if not str(_page_text.get(t, "")).contains(w):
				ok = false
				break
		(c as Button).visible = ok
		if ok and not q.is_empty():
			_search_hits.append(t)
	# A category header shows while any of its pages does.
	for cat in _nav_headers.keys():
		var any := false
		for t in _nav_buttons.keys():
			var b := _nav_buttons[t] as Button
			if str(b.get_meta("category", "")) == cat and b.visible:
				any = true
				break
		var hdr := _nav_headers[cat] as Label
		hdr.visible = any
		if hdr.has_meta("gap"):
			(hdr.get_meta("gap") as Control).visible = any
	_nav_count_lbl.visible = not q.is_empty()
	if _search_hits.is_empty():
		_nav_count_lbl.text = "No page matches"
	else:
		_nav_count_lbl.text = "%s match" % UiText.count(_search_hits.size(), "page")
	if not q.is_empty() and not _search_hits.is_empty() and not (current_page() in _search_hits):
		open_page(str(_search_hits[0]))
	_style_nav()
	if not q.is_empty():
		_reveal_match(words)


func _on_search_submitted(q: String) -> void:
	if _search_hits.is_empty():
		return
	open_page(str(_search_hits[0]))
	_reveal_match(q.strip_edges().to_lower().split(" ", false))


## Scrolls the open page to the first control whose text matches and flashes it.
func _reveal_match(words: PackedStringArray) -> void:
	if _tabs == null or words.is_empty():
		return
	var page := _tabs.get_tab_control(_tabs.current_tab)
	if not (page is ScrollContainer):
		return
	var hit := _first_match(page, words)
	if hit == null:
		return
	(page as ScrollContainer).ensure_control_visible(hit)
	hit.modulate = Color(1.6, 1.4, 0.7)
	var tw := hit.create_tween()
	tw.tween_property(hit, "modulate", Color.WHITE, 0.9)


func _first_match(n: Node, words: PackedStringArray) -> Control:
	var txt := ""
	if n is Label:
		txt = (n as Label).text
	elif n is Button:
		txt = (n as Button).text
	if not txt.is_empty() and (n as Control).is_visible_in_tree():
		var low := txt.to_lower()
		var ok := true
		for w in words:
			if not low.contains(w):
				ok = false
				break
		if ok:
			return n as Control
	for c in n.get_children():
		var r := _first_match(c, words)
		if r != null:
			return r
	return null


func _load_last_page() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return ""
	return str(cfg.get_value("settings", "page", ""))


func _save_last_page(t: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	if str(cfg.get_value("settings", "page", "")) == t:
		return
	cfg.set_value("settings", "page", t)
	cfg.save(PREFS_PATH)


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


## ---------------------------------------------------------------------------
## Extreme Weather
## ---------------------------------------------------------------------------
## Opt in per hazard, and see which hazards this site is actually at risk for —
## computed from the site's own NWS/IEM alert history back to 1986, falling back
## to climatology derived from WeatherService for non-US sites (which is most of
## them, since the location picker puts maps anywhere).
##
## Persistence is deliberately split: the master switch is a MECHANIC toggle and
## lives on GameplayRules with survival/crisis/fire (save- and scenario-scoped),
## while the per-hazard opt-ins and the Drama slider are a TASTE and live in
## ExtremeWeatherPrefs (user://extreme_weather.cfg).
var _xw_enabled: CheckBox = null
var _xw_intensity: HSlider = null
var _xw_notify: CheckBox = null
var _xw_rows_box: VBoxContainer = null
var _xw_zone_lbl: Label = null
var _xw_preview_opt: OptionButton = null
var _xw_preview_sev: HSlider = null
var _xw_preview_btn: Button = null
var _xw_preview_dur: SpinBox = null
var _xw_rows: Dictionary = {}   # hazard id -> {check, bar, stat}


func _build_extreme_weather_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Extreme Weather")

	_add_section_lbl(v, "Extreme Weather")
	_xw_enabled = _add_check(v, "Simulate extreme weather events", _on_xw_enabled)
	_xw_notify = _add_check(v, "Warn me when a hazard begins", _on_xw_notify)
	_xw_intensity = _add_slider(v, "Drama", 0.25, 2.0, 0.05, _on_xw_intensity)

	var hint := Label.new()
	hint.text = "Hazards are triggered from real data for this site — air-quality readings, the weather archive, and National Weather Service alert history. Drama scales only how severe a hazard LOOKS; it never changes the physics behind solar output or health. Turning a hazard off removes it from the simulation entirely."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(440, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Your site's risk profile")

	_xw_zone_lbl = Label.new()
	_xw_zone_lbl.text = "Loading…"
	_xw_zone_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_xw_zone_lbl.custom_minimum_size = Vector2(440, 0)
	_xw_zone_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_xw_zone_lbl.add_theme_font_size_override("font_size", 10)
	v.add_child(_xw_zone_lbl)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh risk profile"
	refresh_btn.pressed.connect(_on_xw_refresh)
	v.add_child(refresh_btn)

	_xw_rows_box = VBoxContainer.new()
	_xw_rows_box.add_theme_constant_override("separation", 4)
	_xw_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_xw_rows_box)
	for id: String in HazardCatalog.ids():
		_xw_add_hazard_row(_xw_rows_box, id)

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Preview a hazard")

	var prev_hint := Label.new()
	prev_hint.text = "Forces a hazard on so you can watch it play out — this panel closes so you actually see it; the badge at the top of the screen shows what's running (click it to stop early). Ramps in and out like a real event. Works even with the simulation toggle off, changes no settings, and is never saved."
	prev_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prev_hint.custom_minimum_size = Vector2(440, 0)
	prev_hint.add_theme_color_override("font_color", C_TEXT_S)
	prev_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(prev_hint)

	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 8)
	_xw_preview_opt = OptionButton.new()
	for id: String in HazardCatalog.simulated_ids():
		_xw_preview_opt.add_item("%s %s" % [HazardCatalog.icon(id), HazardCatalog.display_name(id)])
		_xw_preview_opt.set_item_metadata(_xw_preview_opt.item_count - 1, id)
	_xw_preview_opt.add_theme_color_override("font_color", C_TEXT)
	prow.add_child(_xw_preview_opt)
	var dur_lbl := Label.new()
	dur_lbl.text = "for"
	dur_lbl.add_theme_color_override("font_color", C_TEXT_S)
	prow.add_child(dur_lbl)
	_xw_preview_dur = SpinBox.new()
	_xw_preview_dur.min_value = 1.0
	_xw_preview_dur.max_value = 48.0
	_xw_preview_dur.step = 1.0
	_xw_preview_dur.value = 6.0
	_xw_preview_dur.suffix = "h"
	prow.add_child(_xw_preview_dur)
	_xw_preview_btn = Button.new()
	_xw_preview_btn.text = "Preview"
	_xw_preview_btn.pressed.connect(_on_xw_preview)
	prow.add_child(_xw_preview_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_on_xw_clear_preview)
	prow.add_child(clear_btn)
	v.add_child(prow)
	# LIVE while a preview runs: dragging retunes the forced severity in place
	# (the old slider was only sampled when Preview was pressed, so dragging
	# during a preview silently did nothing).
	_xw_preview_sev = _add_slider(v, "Severity", 0.1, 1.0, 0.05, _on_xw_preview_sev)
	_xw_preview_sev.value = 0.7

	var attrib := Label.new()
	attrib.text = "Air-quality data: Copernicus Atmosphere Monitoring Service (CAMS) ENSEMBLE via Open-Meteo. Alert history: NOAA/NWS via Iowa Environmental Mesonet."
	attrib.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	attrib.custom_minimum_size = Vector2(440, 0)
	attrib.add_theme_color_override("font_color", C_TEXT_S)
	attrib.add_theme_font_size_override("font_size", 9)
	v.add_child(attrib)


## One hazard row: [x] icon + name | risk bar | rate/worst-year text.
func _xw_add_hazard_row(parent: Control, id: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var chk := CheckBox.new()
	chk.text = "%s %s" % [HazardCatalog.icon(id), HazardCatalog.display_name(id)]
	chk.custom_minimum_size = Vector2(196, 0)
	chk.add_theme_color_override("font_color", C_TEXT)
	chk.toggled.connect(func(on: bool) -> void: _on_xw_hazard_toggled(id, on))
	if not HazardCatalog.is_simulated(id):
		chk.tooltip_text = "Tracked for your risk profile; the simulation for this hazard is not built yet."
	row.add_child(chk)

	# Plain Control + _draw, the same technique timeline_ui._draw_track and
	# site_report_charts use — no texture, no theme dependency.
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(70, 12)
	bar.set_meta("fill", 0.0)
	bar.set_meta("level", HazardCatalog.RISK_UNKNOWN)
	bar.draw.connect(func() -> void: _xw_draw_risk_bar(bar))
	row.add_child(bar)

	var stat := Label.new()
	stat.text = "…"
	stat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stat.add_theme_color_override("font_color", C_TEXT_S)
	stat.add_theme_font_size_override("font_size", 10)
	row.add_child(stat)

	parent.add_child(row)
	_xw_rows[id] = {"check": chk, "bar": bar, "stat": stat}


func _xw_draw_risk_bar(bar: Control) -> void:
	var w := bar.size.x
	var h := bar.size.y
	bar.draw_rect(Rect2(0, 0, w, h), C_BORDER)
	var fill := clampf(float(bar.get_meta("fill", 0.0)), 0.0, 1.0)
	if fill <= 0.0:
		return
	var level := str(bar.get_meta("level", ""))
	var col := UITheme.C_OK
	match level:
		HazardCatalog.RISK_SEVERE: col = UITheme.C_ERROR
		HazardCatalog.RISK_HIGH: col = UITheme.C_ERROR
		HazardCatalog.RISK_MODERATE: col = UITheme.C_WARN
		HazardCatalog.RISK_LOW: col = UITheme.C_INFO
	bar.draw_rect(Rect2(0, 0, w * fill, h), col)


## Called from open(), independently of SimSettingsController's snapshot — that
## path early-returns when the controller has no Main yet, and this tab must
## still populate.
func _refresh_extreme_weather_tab() -> void:
	if _xw_enabled == null:
		return
	ExtremeWeatherPrefs.ensure_loaded()
	var prev := _syncing
	_syncing = true

	var xw := get_node_or_null("/root/ExtremeWeather")
	var gr := GameplayRulesImpl.from_node(self)
	_xw_enabled.button_pressed = gr != null and gr.is_extreme_weather_enabled()
	_xw_notify.button_pressed = ExtremeWeatherPrefs.notify
	_xw_intensity.value = ExtremeWeatherPrefs.intensity

	var profile: Dictionary = {}
	var ready := false
	if xw != null:
		# Opening the tab is itself a request for the profile: on a site with no
		# NWS zone the director would otherwise still be waiting on alert
		# history that is never coming.
		if not bool(xw.call("is_risk_profile_ready")):
			xw.call("refresh_risk_profile")
		profile = xw.call("risk_profile")
		ready = bool(xw.call("is_risk_profile_ready"))
		var zone := str(xw.call("risk_profile_zone"))
		if not ready:
			_xw_zone_lbl.text = "Loading alert history for this site…"
		elif bool(xw.call("risk_profile_is_observed")):
			_xw_zone_lbl.text = "NWS zone %s — from %d years of recorded alerts." % [
				zone, Time.get_date_dict_from_system().get("year", 2026) - 1986 + 1]
		else:
			_xw_zone_lbl.text = "No NWS zone for this site (non-US) — estimated from local climate data."
	else:
		_xw_zone_lbl.text = "Extreme weather service unavailable."

	# Re-order rows by risk so the site's real dangers are at the top.
	if ready and not profile.is_empty() and _xw_rows_box != null:
		var order := HazardRiskProfile.sorted_ids(profile)
		for i in order.size():
			var r: Variant = _xw_rows.get(order[i], null)
			if r is Dictionary:
				var row_node := (r as Dictionary)["check"].get_parent() as Control
				if row_node != null:
					_xw_rows_box.move_child(row_node, i)

	for id: String in _xw_rows.keys():
		var r: Dictionary = _xw_rows[id]
		var chk := r["check"] as CheckBox
		var bar := r["bar"] as Control
		var stat := r["stat"] as Label
		chk.button_pressed = ExtremeWeatherPrefs.is_enabled(id)
		var entry: Dictionary = profile.get(id, {}) as Dictionary
		var level := str(entry.get("level", HazardCatalog.RISK_UNKNOWN))
		bar.set_meta("fill", HazardCatalog.risk_fill(level))
		bar.set_meta("level", level)
		bar.queue_redraw()
		var line := HazardRiskProfile.summary_line(entry) if not entry.is_empty() else "…"
		if HazardCatalog.is_simulated(id):
			stat.text = "%s · %s" % [HazardCatalog.risk_label(level), line]
		else:
			stat.text = "%s · %s · not yet simulated" % [HazardCatalog.risk_label(level), line]

	_syncing = prev


func _on_xw_enabled(on: bool) -> void:
	if _syncing: return
	var gr := GameplayRulesImpl.from_node(self)
	if gr != null:
		gr.extreme_weather_enabled = on
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null:
		xw.call("invalidate")


func _on_xw_notify(on: bool) -> void:
	if _syncing: return
	ExtremeWeatherPrefs.notify = on
	ExtremeWeatherPrefs.save()


func _on_xw_intensity(v: float) -> void:
	if _syncing: return
	ExtremeWeatherPrefs.set_intensity(v)
	ExtremeWeatherPrefs.save()
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null:
		xw.call("invalidate")


func _on_xw_hazard_toggled(id: String, on: bool) -> void:
	if _syncing: return
	ExtremeWeatherPrefs.set_enabled(id, on)
	ExtremeWeatherPrefs.save()
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null:
		xw.call("invalidate")


func _on_xw_refresh() -> void:
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null:
		xw.call("refresh_risk_profile")
	_refresh_extreme_weather_tab()


func _on_xw_preview() -> void:
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw == null or _xw_preview_opt == null:
		return
	var idx := _xw_preview_opt.selected
	if idx < 0:
		return
	var id := str(_xw_preview_opt.get_item_metadata(idx))
	# The director now resolves a FORCED hazard even with the master switch or
	# the per-hazard opt-in off — the old handler force-flipped BOTH of those
	# persistently ("not saved" was only half true) and Clear never restored
	# them. Preview must not write a single pref.
	var dur := _xw_preview_dur.value if _xw_preview_dur != null else 6.0
	xw.call("force_hazard", id, _xw_preview_sev.value, dur)
	if not bool(xw.call("has_forced")):
		return  # refused (clock unresolved) — the director already warned
	# Close the panel so the player SEES the hazard they just triggered; the
	# HazardBadgeUI chip carries the countdown + click-to-clear from here.
	close()
	var main := get_tree().get_first_node_in_group("main_scene")
	if main != null and main.has_method("show_toast"):
		main.call("show_toast", "Previewing %s %s — click the badge up top to stop" % [
			HazardCatalog.icon(id), HazardCatalog.display_name(id)],
			ToastUI.Level.INFO, 4.0)


## Severity slider is LIVE during a preview; idle otherwise (its value is
## sampled when Preview is pressed).
func _on_xw_preview_sev(v: float) -> void:
	if _syncing:
		return
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null and xw.has_method("update_forced_severity") \
			and bool(xw.call("has_forced")):
		xw.call("update_forced_severity", v)


func _on_xw_clear_preview() -> void:
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null:
		xw.call("clear_forced")


func _build_keys_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Keys")
	_add_section_lbl(v, "API Keys  (optional — improve data accuracy)")

	var hint_ot := Label.new()
	hint_ot.text = "OpenTopography: enables 30 m DEM resolution (vs default 90 m), plus 10 m USGS DEM in the US.\nThis SAME key also gates the 1 m USGS lidar option in Terrain options -> Advanced terrain size, but OpenTopography restricts that specific dataset to academic-verified accounts -- an ordinary free key here gets 10 m instead (Terrain options shows which one actually loaded).\nFree key at portal.opentopography.org"
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
	_plant_growth    = _add_check(v, "Plant growth (vegetation aging)", _on_plant_growth)
	_connector_losses = _add_check(v, "Connector losses (wire/pipe loss + burnout)", _on_connector_losses)
	var loss_hint := Label.new()
	loss_hint.text = "Simulates I²R voltage-drop losses in wires/cords and friction losses in hoses/pipes based on their routed 3D length. Sustained overload can burn out a connector."
	loss_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	loss_hint.custom_minimum_size = Vector2(520, 0)
	loss_hint.add_theme_color_override("font_color", C_TEXT_S)
	loss_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(loss_hint)
	_conduits_3d_visible = _add_check(v, "Show 3D wires (world)", _on_conduits_3d_visible)
	_conduit_flow_glow = _add_check(v, "Flow glow on 3D wires", _on_conduit_flow_glow)
	var len_chk := _add_check(v, "Show run lengths on 3D wires", func(on: bool) -> void:
		RunLengthLabels.set_enabled(on)
		var mn := SimSettingsController.main_node if is_instance_valid(SimSettingsController) else null
		var mgr := mn.get_node_or_null("ConduitManager") if mn != null else null
		if mgr != null:
			mgr.set_process(true))
	len_chk.set_pressed_no_signal(RunLengthLabels.enabled())
	len_chk.tooltip_text = ("A length tag over every 3D run (metres and feet, and the kind) — for "
		+ "mapping out how much cord or pipe a site needs. Shows wherever the runs do.")
	var flow_hint := Label.new()
	flow_hint.text = "3D wires are off by default (timeline chip: “3D wires”). Flow glow adds a marching pulse; leave off for a quieter look. Aim a wire → Interact for style, drag to pin a route."
	flow_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	flow_hint.custom_minimum_size = Vector2(520, 0)
	flow_hint.add_theme_color_override("font_color", C_TEXT_S)
	flow_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(flow_hint)
	var reset_routes := Button.new()
	reset_routes.text = "Reset all auto-routes"
	reset_routes.tooltip_text = "Clear locked / stale 3D pins on every connection and re-run metro"
	reset_routes.focus_mode = Control.FOCUS_NONE
	reset_routes.pressed.connect(_on_reset_all_autoroutes)
	v.add_child(reset_routes)
	_force_rainbow = _add_check(v, "Force rainbow (debug)", _on_force_rainbow)
	var rainbow_hint := Label.new()
	rainbow_hint.text = "Shows the antisolar rainbow regardless of rain, for testing. It still only appears when the sun is low (below ~44°) and you look opposite the sun, low above the horizon."
	rainbow_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rainbow_hint.custom_minimum_size = Vector2(520, 0)
	rainbow_hint.add_theme_color_override("font_color", C_TEXT_S)
	rainbow_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(rainbow_hint)
	var growth_hint := Label.new()
	growth_hint.text = "Trees grow year on year with the calendar and live out a life cycle. Off = every plant draws at full size."
	growth_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	growth_hint.custom_minimum_size = Vector2(520, 0)
	growth_hint.add_theme_color_override("font_color", C_TEXT_S)
	growth_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(growth_hint)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "UI sounds")
	# Backend lives on the UiSound autoload (mute + volume already persist to
	# user://audio_prefs.cfg) — this is just the missing control surface.
	# Resolve by path, never bare identifier (CLAUDE.md autoload trap).
	var sfx := get_node_or_null("/root/UiSound")
	var mute_chk := _add_check(v, "Mute UI sound effects", func(on: bool) -> void:
		var s := get_node_or_null("/root/UiSound")
		if s != null:
			s.call("set_muted", on))
	if sfx != null:
		mute_chk.set_pressed_no_signal(bool(sfx.call("is_muted")))
	var vol := _add_slider(v, "Volume", -30.0, 6.0, 1.0, func(db: float) -> void:
		var s := get_node_or_null("/root/UiSound")
		if s != null:
			s.call("set_volume_db", db)
			s.call("play_ui", "success"))
	if sfx != null:
		vol.set_value_no_signal(float(sfx.call("get_volume_db")))
	var sfx_hint := Label.new()
	sfx_hint.text = "Feedback chirps for wiring, warnings and unlocks. Warnings are also rate-limited to one per 1.5 s so repeated mistakes don't machine-gun."
	sfx_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sfx_hint.custom_minimum_size = Vector2(520, 0)
	sfx_hint.add_theme_color_override("font_color", C_TEXT_S)
	sfx_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(sfx_hint)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "∞ / Analemma")
	_analemma_type = OptionButton.new()
	_analemma_type.add_item("Solar Analemma (Mean Solar Noon)", 0)
	_analemma_type.add_item("Lunar Analemma (Mean Lunar Noon)", 1)
	_analemma_type.add_theme_color_override("font_color", C_TEXT)
	_analemma_type.item_selected.connect(_on_analemma_type)
	v.add_child(_analemma_type)
	
	_analemma_noon = _add_slider(v, "Start time (min)", -720.0, 720.0, 0.1, _on_analemma_noon)
	_analemma_drift = _add_slider(v, "Diurnal drift (min/day)", 0.0, 120.0, 0.1, _on_analemma_drift)
	var drift_hint := Label.new()
	drift_hint.text = "Shifts each day's sample time later by this many minutes, layering diurnal motion onto the seasonal analemma. 0 = fixed mean solar noon (classic figure-eight). Non-zero traces a corkscrew path."
	drift_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	drift_hint.custom_minimum_size = Vector2(520, 0)
	drift_hint.add_theme_color_override("font_color", C_TEXT_S)
	drift_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(drift_hint)
	
	_show_sun_path = _add_check(v, "Show sun path", _on_show_sun_path)
	_show_moon_path = _add_check(v, "Show moon path", _on_show_moon_path)
	_show_planet_paths = _add_check(v, "Show planet paths", _on_show_planet_paths)
	_planet_path_frame = _add_option(v, "Planet path frame",
		["Sky — same instants as the sun", "Stars — retrograde loops"], _on_planet_path_frame)
	_planet_path_frame.tooltip_text = "Sky: each planet sampled at the sun's (or moon's) daily instant, drawn where it stood in the sky then — compares against the figure-eight.\nStars: each planet's track against the star field, turned with the sky in real time — the frame real retrograde-loop composites are registered in. Mars, Jupiter and Saturn draw their backward loops around opposition; Mercury and Venus trace theirs near the sun."
	_analemma_star_reveal = _add_slider(v, "Stars through daylight", 0.0, 1.0, 0.05, _on_analemma_star_reveal)
	_analemma_star_reveal.tooltip_text = "Every analemma sample is at noon, so the stars are up but drowned in daylight. This dims the sky dome (not the lighting on the ground) and lets the stars, Milky Way, planets and zodiac through, so you can watch the star field turn once a year behind the sun. 0 = off."
	_show_planet_paths.tooltip_text = "Trace Mercury, Venus, Mars, Jupiter and Saturn at the same instants as the sun (or moon) path. Mercury and Venus loop around the sun's figure-eight; the outer planets sweep the sky once per synodic period. Colours follow the planet colours in Settings → Stars & Planets; a planet switched off there gets no path."
	_analemma_thickness = _add_slider(v, "Path thickness", 0.1, 20.0, 0.1, _on_analemma_thickness)
	_analemma_solar_col = _add_color_picker(v, "Solar path color", _on_analemma_solar_col)
	_analemma_lunar_col = _add_color_picker(v, "Lunar path color", _on_analemma_lunar_col)
	
	var hint := Label.new()
	hint.text = "Random fires and survival rules when time is at or below realtime speed."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)


## Interface: the UI scale (UiThemeBuilder). Auto boosts small windows, where
## the 1920×1080 canvas otherwise shrinks every word.
func _build_interface_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Interface")
	_add_section_lbl(v, "Text and panel size")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = "UI scale"
	hdr.custom_minimum_size = Vector2(110, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var opt := OptionButton.new()
	opt.fit_to_longest_item = false
	opt.custom_minimum_size = Vector2(220, 0)
	var cur := UiThemeBuilder.scale_pref()
	var auto_now := UiThemeBuilder.auto_scale(float(DisplayServer.window_get_size().y))
	for i in UiThemeBuilder.SCALE_CHOICES.size():
		var f := float(UiThemeBuilder.SCALE_CHOICES[i])
		var label := "%d %%" % int(round(f * 100.0))
		if f <= 0.0:
			label = "Auto (%d %% here)" % int(round(auto_now * 100.0))
		opt.add_item(label, i)
		if is_equal_approx(f, cur):
			opt.select(i)
	opt.item_selected.connect(func(idx: int) -> void:
		UiThemeBuilder.set_scale_pref(float(UiThemeBuilder.SCALE_CHOICES[idx])))
	row.add_child(opt)
	v.add_child(row)
	var hint := Label.new()
	hint.text = "Auto keeps text readable on small windows (larger at 720p, normal at 1080p and up). The layout always fits the screen; a larger scale tucks more of the HUD into pills."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	v.add_child(hint)


func _build_drone_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Drone")
	_add_section_lbl(v, "Flight")
	_drone_max_speed = _add_slider(v, "Max speed m/s", 5.0, 240.0, 1.0, _on_drone_max_speed)
	_drone_acceleration = _add_slider(v, "Acceleration", 5.0, 100.0, 1.0, _on_drone_acceleration)
	_drone_drag = _add_slider(v, "Deceleration", 2.0, 40.0, 1.0, _on_drone_drag)
	_drone_vertical_speed = _add_slider(v, "Climb speed m/s", 2.0, 80.0, 1.0, _on_drone_vertical_speed)
	_drone_steering = _add_slider(v, "Look sensitivity", 0.5, 6.0, 0.1, _on_drone_steering)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Altitude limits (AGL)")
	_drone_min_altitude = _add_slider(v, "Min altitude m", 0.5, 50.0, 0.5, _on_drone_min_altitude)
	_drone_max_altitude = _add_slider(v, "Max altitude m", 100.0, 20000.0, 100.0, _on_drone_max_altitude)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Visual banking")
	_drone_tilt_intensity = _add_slider(v, "Tilt angle °", 0.0, 60.0, 1.0, _on_drone_tilt_intensity)
	_drone_tilt_speed = _add_slider(v, "Tilt response", 1.0, 20.0, 0.5, _on_drone_tilt_speed)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Camera")
	_drone_fov = _add_slider(v, "Drone FOV°", 30.0, 120.0, 1.0, _on_drone_fov)
	var hint := Label.new()
	hint.text = "Standard FPV controls: WASD / left stick = fly horizontally, Shift or Up / triggers = ascend, Down = descend (Space stays free for look/time toggle), mouse / right stick = look direction. Changes apply immediately to any drone in the world."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)


func _build_environment_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Environment")
	_add_section_lbl(v, "Clouds")
	_clouds_weight      = _add_slider(v, "Cloud cover",    0.0, 1.0, 0.01, _on_clouds_weight)
	_clouds_cutoff      = _add_slider(v, "Cloud density",  0.0, 1.0, 0.05, _on_clouds_cutoff)
	_cirrus_amount      = _add_slider(v, "Cirrus amount",  0.0, 2.0, 0.05, _on_cirrus_amount)
	_cirrus_wave_frequency = _add_slider(v, "Cirrus wave scale", 0.0, 5.0, 0.1, _on_cirrus_wave_frequency)
	_cirrus_wave_intensity = _add_slider(v, "Cirrus wave intensity", 0.0, 2.0, 0.05, _on_cirrus_wave_intensity)
	_cloud_shadows      = _add_check(v, "Cloud shadows", _on_cloud_shadows)
	
	v.add_child(HSeparator.new())
	var cs_hint := Label.new()
	cs_hint.text = "Cirrus adds high, streaky clouds (auto-driven by weather; slider is a boost). Cloud shadows dim the direct sun as clouds drift over — cheap global lighting, no ground projection."
	cs_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cs_hint.custom_minimum_size = Vector2(420, 0)
	cs_hint.add_theme_color_override("font_color", C_TEXT_S)
	cs_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(cs_hint)

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
	_graphics_quality.add_item("Ultra (strong GPUs)", 3)
	_graphics_quality.add_theme_color_override("font_color", C_TEXT)
	_graphics_quality.item_selected.connect(_on_graphics_quality)
	v.add_child(_graphics_quality)
	var gq_hint := Label.new()
	gq_hint.text = "Presets scale shadow-map size, soft-shadow filtering, TAA, and the vegetation tier (detail-ring size, leaf density, tree budgets). Ultra adds tree shadows and bigger detail rings."
	gq_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gq_hint.custom_minimum_size = Vector2(420, 0)
	gq_hint.add_theme_color_override("font_color", C_TEXT_S)
	gq_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(gq_hint)
	v.add_child(HSeparator.new())
	_build_prop_perf_section(v)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Terrain detail (imagery resolution)")
	var tq_row := HBoxContainer.new()
	tq_row.add_theme_constant_override("separation", 8)
	var tq_hdr := Label.new()
	tq_hdr.text = "Quality"
	tq_hdr.custom_minimum_size = Vector2(110, 0)
	tq_hdr.add_theme_color_override("font_color", C_TEXT_S)
	tq_row.add_child(tq_hdr)
	_terrain_quality = HSlider.new()
	_terrain_quality.min_value = 0.0
	_terrain_quality.max_value = 3.0
	_terrain_quality.step = 1.0
	_terrain_quality.ticks_on_borders = true
	_terrain_quality.tick_count = 4
	_terrain_quality.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terrain_quality.value_changed.connect(_on_terrain_quality)
	tq_row.add_child(_terrain_quality)
	v.add_child(tq_row)
	_terrain_quality_lbl = Label.new()
	_terrain_quality_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_terrain_quality_lbl.custom_minimum_size = Vector2(420, 0)
	_terrain_quality_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_terrain_quality_lbl.add_theme_font_size_override("font_size", 10)
	v.add_child(_terrain_quality_lbl)
	var tq_hint := Label.new()
	tq_hint.text = "Sharpens close-up (walking) terrain by fetching higher-zoom aerial tiles over a wider area. Higher tiers use more VRAM and a longer first download (then cached); only applies to generated location maps. Sculpting speed is unaffected."
	tq_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tq_hint.custom_minimum_size = Vector2(420, 0)
	tq_hint.add_theme_color_override("font_color", C_TEXT_S)
	tq_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(tq_hint)
	_sync_terrain_quality()
	v.add_child(HSeparator.new())
	if hub_mode:
		# The graphics-preset form: what can be set with no world lit.
		_shadow_quality     = _add_slider(v, "Shadow quality", 0.0, 3.0, 1.0,  _on_shadow_quality)
		_shadow_opacity     = _add_slider(v, "Shadow darkness", 0.0, 1.0, 0.05, _on_shadow_opacity)
		_shadow_quality_lbl = _add_status_label(v, "Shadow Quality: High")
		_add_hint(v, "Sun, moon, ambient, glow, fog, tonemapping and the night sky are tuned inside a world (Settings ⚙ on the timeline), where you can see them.")
		return
	_sun_energy         = _add_slider(v, "Sun energy",     0.0, 3.0, 0.05, _on_sun_energy)
	_shadow_quality     = _add_slider(v, "Shadow quality", 0.0, 3.0, 1.0,  _on_shadow_quality)
	_shadow_opacity     = _add_slider(v, "Shadow darkness", 0.0, 1.0, 0.05, _on_shadow_opacity)
	_shadow_quality_lbl = _add_status_label(v, "Shadow Quality: High")
	_building_shadows   = _add_check(v, "Building shadows", _on_building_shadows)
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
	# SDFGI voxelises a handful of cascades CENTRED ON THE CAMERA — roughly 400 m
	# across at the default cell size. On a 120 km terrain that is a small box that
	# follows the player: ground inside it picks up bounced light, ground outside it
	# gets none, and the seam reads as a lit square around the camera that fades out
	# as a drone climbs past the cascade. It is worst at night, and worst of all with
	# "Ambient x" at 0, where SDFGI is then the ONLY thing lighting that square.
	# Off by default for that reason; the lighting model (DaylightModel) already
	# carries direct beam + skylight on its own.
	_sdfgi_enabled.tooltip_text = "Bounced-light GI. Not recommended at this world scale: SDFGI only covers a ~400 m box centred on the camera, so it lights a square patch of ground that follows you and stops at a hard edge — very visible at night, especially with Ambient × turned down."
	_volumetric_fog = _add_check(v, "Volumetric fog", _on_volumetric_fog_enabled)
	_fog_amount = _add_slider(v, "Fog amount", 0.0, 1.0, 0.01, _on_fog_amount)
	_tonemap_mode = _add_option(v, "Tonemap", ["Linear", "Reinhard", "Filmic", "ACES", "AgX"], _on_tonemap_mode)
	_tonemap_exposure = _add_slider(v, "Exposure", 0.1, 4.0, 0.05, _on_tonemap_exposure)
	_tonemap_white = _add_slider(v, "Tonemap white", 0.1, 16.0, 0.1, _on_tonemap_white)
	_msaa_mode = _add_option(v, "MSAA", ["Off", "2x", "4x", "8x"], _on_msaa_mode)
	var msaa_hint := Label.new()
	msaa_hint.text = "Alternative to TAA's smoothing — sharper edges, no ghosting on wind-animated foliage, more GPU cost."
	msaa_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msaa_hint.custom_minimum_size = Vector2(420, 0)
	msaa_hint.add_theme_color_override("font_color", C_TEXT_S)
	msaa_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(msaa_hint)
	_sun_size = _add_slider(v, "Sun disc size", 0.02, 0.5, 0.005, _on_sun_size)
	_sun_glow = _add_slider(v, "Sun glow", 0.0, 4.0, 0.05, _on_sun_glow)
	_sun_glow_size = _add_slider(v, "Sun glow size", 1.0, 30.0, 0.5, _on_sun_glow_size)
	_sun_aureole = _add_slider(v, "Sun aureole", 0.0, 3.0, 0.05, _on_sun_aureole)
	_twilight_drama = _add_slider(v, "Twilight drama", 0.0, 2.0, 0.05, _on_twilight_drama)
	var td_hint := Label.new()
	td_hint.text = "Scales the horizon fire band, the sun's aureole and glow near the horizon, and the pink Belt of Venus opposite the sun. 1.0 = natural, 0 = flat."
	td_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	td_hint.custom_minimum_size = Vector2(420, 0)
	td_hint.add_theme_color_override("font_color", C_TEXT_S)
	td_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(td_hint)
	_twilight_length = _add_slider(v, "Twilight length", 0.25, 3.0, 0.05, _on_twilight_length)
	_sun_warmth = _add_slider(v, "Low-sun warmth", 0.0, 2.0, 0.05, _on_sun_warmth)
	var tl_hint := Label.new()
	tl_hint.text = "Sunlight follows the real atmosphere: none until the disc clears the horizon, then a few percent of noon in deep orange, half strength by 10°, white by 30°. Twilight length stretches how slowly the sky and ground fade after sunset (1 = natural, compressed for the screen). Low-sun warmth is the reddening of the direct light near the horizon (0 = white)."
	tl_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tl_hint.custom_minimum_size = Vector2(420, 0)
	tl_hint.add_theme_color_override("font_color", C_TEXT_S)
	tl_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(tl_hint)
	_god_rays = _add_check(v, "God rays (light shafts via volumetric fog)", _on_god_rays)
	var gr_hint := Label.new()
	gr_hint.text = "God rays enable a thin volumetric fog so the sun casts crepuscular shafts, strongest at sunrise/sunset. Adds some GPU cost."
	gr_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gr_hint.custom_minimum_size = Vector2(420, 0)
	gr_hint.add_theme_color_override("font_color", C_TEXT_S)
	gr_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(gr_hint)
	_moon_size = _add_slider(v, "Moon disc size", 0.01, 0.2, 0.005, _on_moon_size)
	_moon_glow = _add_slider(v, "Moon glow", 0.0, 2.0, 0.05, _on_moon_glow)
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Night sky")
	_airglow = _add_slider(v, "Airglow", 0.0, 1.0, 0.01, _on_airglow)
	_airglow_col = _add_color_row(v, "Airglow colour", Color(0.16, 0.30, 0.22), _on_airglow_color)
	_light_pollution = _add_slider(v, "Light pollution", 0.0, 1.0, 0.01, _on_light_pollution)
	_light_pollution_col = _add_color_row(v, "Pollution colour", Color(0.95, 0.62, 0.35), _on_light_pollution_color)
	_moon_sky_glow = _add_slider(v, "Moonlit sky", 0.0, 2.0, 0.05, _on_moon_sky_glow)
	var ns_hint := Label.new()
	ns_hint.text = "The dark sky is a near-black gradient plus three light sources: airglow (the faint green band real dark skies show low down), a light-pollution dome, and moonlight. All zero on a moonless night = a Bortle-1 wilderness sky. Bright skies wash out faint stars (Stars tab → Sky-glow washout)."
	ns_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ns_hint.custom_minimum_size = Vector2(420, 0)
	ns_hint.add_theme_color_override("font_color", C_TEXT_S)
	ns_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(ns_hint)
	# (The player's field of view moved to the Player tab.)


func _build_stars_planets_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Stars & Planets")
	_add_section_lbl(v, "Stars")
	# No RA/Dec/flip "calibration" here any more: orientation is computed from
	# the clock + latitude and the map's registration comes from its sidecar
	# (StarSystem / StarSkyMath). HOME shows the computed reference-star markers.
	_stars_brightness = _add_slider(v, "Brightness", 0.0, 3.0, 0.05, _on_stars_brightness)
	_stars_point_size = _add_slider(v, "Point size", -1.0, 1.0, 0.05, _on_stars_point_size)
	_stars_saturation = _add_slider(v, "Colour saturation", 0.0, 3.0, 0.05, _on_stars_saturation)
	_stars_contrast = _add_slider(v, "Contrast", 1.0, 4.0, 0.05, _on_stars_contrast)
	_stars_bg_cut = _add_slider(v, "Faint-star cut", 0.0, 0.3, 0.005, _on_stars_bg_cut)
	_stars_twinkle = _add_slider(v, "Twinkle", 0.0, 1.0, 0.05, _on_stars_twinkle)
	_stars_horizon = _add_slider(v, "Horizon fade", 0.0, 1.0, 0.05, _on_stars_horizon_fade)
	_stars_wash = _add_slider(v, "Sky-glow washout", 0.0, 1.0, 0.05, _on_stars_wash)
	_stars_glow = _add_slider(v, "Star glow (halo)", 0.0, 1.0, 0.05, _on_stars_glow)
	var stars_hint := _add_status_label(v, "Point size erodes/dilates every star disc by a texel. Colour comes from each disc's fringe (the export clips cores to white). Washout is how much moonlight and light pollution hide the faint stars.")
	stars_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_add_section_lbl(v, "Milky Way")
	_mw_gain = _add_slider(v, "Brightness", 0.0, 4.0, 0.05, _on_mw_gain)
	_mw_sat = _add_slider(v, "Colour saturation", 0.0, 3.0, 0.05, _on_mw_sat)
	_mw_tint = _add_color_row(v, "Tint", Color(1.0, 0.94, 0.88), _on_mw_tint)
	_add_section_lbl(v, "Effects")
	_star_trails = _add_check(v, "Star trails (long exposure)", _on_star_trails)
	_star_trail_length = _add_slider(v, "Trail length", 0.0, 1.0, 0.05, _on_star_trail_length)
	_lock_sky = _add_check(v, "Lock camera to sky (astro still)", _on_lock_camera_to_sky)
	_add_section_lbl(v, "Star map")
	_star_quality = _add_option(v, "Texture quality", ["Standard (8k, 32 MB VRAM)", "High (16k, 128 MB VRAM)"], _on_star_quality)
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
	_star_reg_lbl = _add_status_label(v, "")
	var reg_hint := _add_status_label(v, "Registration is measured by tools/starmap_prepare.py (sidecar .json next to the image). HOME toggles reference-star markers.")
	reg_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_add_section_lbl(v, "Zodiac")
	_zodiac_mode = _add_option(v, "Show zodiac", ["Off", "With the stars", "Always"], _on_zodiac_mode)
	_zodiac_mode.tooltip_text = "With the stars: at night, and in analemma mode when 'Stars through daylight' is on. Always: over the daytime sky too."
	_zodiac_opacity = _add_slider(v, "Brightness", 0.0, 2.0, 0.05, _on_zodiac_opacity)
	_zodiac_lines = _add_check(v, "Constellation figures", _on_zodiac_lines)
	_zodiac_labels = _add_check(v, "Names", _on_zodiac_labels)
	_zodiac_ophiuchus = _add_check(v, "Ophiuchus (the 13th)", _on_zodiac_ophiuchus)
	_zodiac_ophiuchus.tooltip_text = "The ecliptic also crosses Ophiuchus (IAU constellation boundaries, 1930): the sun spends about 18 days of each year there, between Scorpius and Sagittarius."
	_zodiac_ecliptic = _add_check(v, "Ecliptic (the planets' plane)", _on_zodiac_ecliptic)
	var zod_hint := _add_status_label(v, "Figures from Stellarium's 'modern' sky culture (CC BY-SA 4.0), in the same registration as the star map.")
	zod_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Planets")
	_planets_master = _add_check(v, "Show planets", _on_planets_master)
	_planet_labels = _add_option(v, "Planet labels", ["Off", "On highlight (look at a planet)", "Always"], _on_planet_labels)
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
	# "Title  (aside)" puts the aside in the header's right-hand note.
	var cut := text.find("  (")
	if cut > 0 and text.ends_with(")"):
		parent.add_child(SectionHeader.make(text.substr(0, cut), "",
			text.substr(cut + 3, text.length() - cut - 4)))
	else:
		parent.add_child(SectionHeader.make(text))


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
	var val_spin := SpinBox.new()
	val_spin.custom_minimum_size = Vector2(70, 0)
	val_spin.min_value = min_v
	val_spin.max_value = max_v
	val_spin.step = step
	val_spin.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_spin)
	
	sl.value_changed.connect(func(v: float) -> void:
		if val_spin.value != v: val_spin.value = v
		cb.call(v)
	)
	
	val_spin.value_changed.connect(func(v: float) -> void:
		if sl.value != v: sl.value = v
	)
	
	# Defer initialization so it grabs the initial value correctly
	val_spin.value = sl.value
	
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

func _add_color_picker(parent: Control, label: String, cb: Callable) -> ColorPickerButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(110, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var cpb := ColorPickerButton.new()
	cpb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cpb.color_changed.connect(cb)
	row.add_child(cpb)
	parent.add_child(row)
	return cpb


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
	if _star_reg_lbl:
		_star_reg_lbl.text = "Registration: %s" % str(snap.get("registration_summary", "?"))


func _sync_gameplay_from_snapshot(snap: Dictionary) -> void:
	if _survival:
		_survival.button_pressed = bool(snap.get("survival_enabled", false))
	if _plant_growth:
		_plant_growth.button_pressed = bool(snap.get("plant_growth_enabled", true))
	if _connector_losses:
		_connector_losses.button_pressed = SimSettingsController.connector_losses_enabled \
				if is_instance_valid(SimSettingsController) else false
	if _conduits_3d_visible:
		_conduits_3d_visible.button_pressed = SimSettingsController.conduits_3d_visible \
				if is_instance_valid(SimSettingsController) else true
	if _conduit_flow_glow:
		_conduit_flow_glow.button_pressed = SimSettingsController.conduit_flow_glow_enabled \
				if is_instance_valid(SimSettingsController) else false
	if _force_rainbow:
		_force_rainbow.button_pressed = SimSettingsController.force_rainbow \
				if is_instance_valid(SimSettingsController) else false
	if _analemma_drift:
		_analemma_drift.value = float(snap.get("analemma_diurnal_offset_min_per_day", 0.0))
	if _analemma_noon:
		_analemma_noon.value = float(snap.get("analemma_noon_offset_minutes", 0.0))
	if _analemma_thickness:
		_analemma_thickness.value = float(snap.get("analemma_path_thickness", 1.0))
	if _analemma_solar_col:
		_analemma_solar_col.color = snap.get("analemma_solar_color", Color(1.0, 0.9, 0.3)) as Color
	if _analemma_lunar_col:
		_analemma_lunar_col.color = snap.get("analemma_lunar_color", Color(0.7, 0.85, 1.0)) as Color
	if _show_sun_path:
		_show_sun_path.button_pressed = bool(snap.get("show_sun_path", true))
	if _show_moon_path:
		_show_moon_path.button_pressed = bool(snap.get("show_moon_path", false))
	if _show_planet_paths:
		_show_planet_paths.button_pressed = bool(snap.get("show_planet_paths", false))
	if _planet_path_frame:
		_planet_path_frame.select(clampi(int(snap.get("planet_path_frame", 0)), 0, 1))
	if _analemma_star_reveal:
		_analemma_star_reveal.value = float(snap.get("analemma_star_reveal", 0.75))
	if _zodiac_mode:
		_zodiac_mode.select(clampi(int(snap.get("zodiac_mode", 0)), 0, 2))
		_zodiac_mode.disabled = not bool(snap.get("zodiac_available", false))
	if _zodiac_opacity:
		_zodiac_opacity.value = float(snap.get("zodiac_opacity", 0.8))
	if _zodiac_lines:
		_zodiac_lines.button_pressed = bool(snap.get("zodiac_show_lines", true))
	if _zodiac_labels:
		_zodiac_labels.button_pressed = bool(snap.get("zodiac_show_labels", true))
	if _zodiac_ophiuchus:
		_zodiac_ophiuchus.button_pressed = bool(snap.get("zodiac_show_ophiuchus", false))
	if _zodiac_ecliptic:
		_zodiac_ecliptic.button_pressed = bool(snap.get("zodiac_show_ecliptic", true))
	if _analemma_type:
		var atype := int(snap.get("analemma_type", 0))
		if atype >= 0 and atype < _analemma_type.item_count:
			_analemma_type.select(atype)


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
		_tonemap_mode.selected = clampi(int(snap.get("tonemap_mode", Environment.TONE_MAPPER_ACES)), 0, 4)
	if _msaa_mode:
		_msaa_mode.selected = clampi(int(snap.get("msaa_level", 0)), 0, 3)
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
	if _sun_glow:
		_sun_glow.value = snap.get("sun_glow", 1.4)
	if _sun_glow_size:
		_sun_glow_size.value = snap.get("sun_glow_size", 9.0)
	if _sun_aureole:
		_sun_aureole.value = snap.get("sun_aureole", 0.8)
	if _twilight_drama:
		_twilight_drama.value = snap.get("twilight_drama", 1.2)
	if _twilight_length:
		_twilight_length.value = snap.get("twilight_length", 1.0)
	if _sun_warmth:
		_sun_warmth.value = snap.get("sun_warmth", 1.0)
	if _airglow:
		_airglow.value = snap.get("airglow_strength", 0.25)
	if _airglow_col and snap.get("airglow_color") is Color:
		_airglow_col.color = snap.get("airglow_color")
	if _light_pollution:
		_light_pollution.value = snap.get("light_pollution", 0.0)
	if _light_pollution_col and snap.get("light_pollution_color") is Color:
		_light_pollution_col.color = snap.get("light_pollution_color")
	if _moon_sky_glow:
		_moon_sky_glow.value = snap.get("moon_sky_glow", 1.0)
	if _god_rays:
		_god_rays.button_pressed = snap.get("god_rays_enabled", false)
	if _player_fov:
		_player_fov.value = snap.get("player_fov", 50.0)
	if _cirrus_amount:
		_cirrus_amount.value = snap.get("cirrus_user_scale", 1.0)
	if _cirrus_wave_frequency:
		_cirrus_wave_frequency.value = snap.get("cirrus_wave_frequency_scale", 1.0)
	if _cirrus_wave_intensity:
		_cirrus_wave_intensity.value = snap.get("cirrus_wave_intensity_scale", 1.0)
	if _cloud_shadows:
		_cloud_shadows.button_pressed = snap.get("cloud_shadows_enabled", true)
	if _building_shadows:
		_building_shadows.button_pressed = snap.get("building_shadows_enabled", false)


func _sync_drone_from_snapshot(snap: Dictionary) -> void:
	var defaults: Dictionary = SimSettingsController.DRONE_DEFAULTS if is_instance_valid(SimSettingsController) else {}
	if _drone_max_speed:
		_drone_max_speed.value = snap.get("max_forward_speed", defaults.get("max_forward_speed", 65.0))
	if _drone_vertical_speed:
		_drone_vertical_speed.value = snap.get("vertical_speed", defaults.get("vertical_speed", 35.0))
	if _drone_acceleration:
		_drone_acceleration.value = snap.get("acceleration", defaults.get("acceleration", 45.0))
	if _drone_drag:
		_drone_drag.value = snap.get("drag", defaults.get("drag", 10.0))
	if _drone_steering:
		_drone_steering.value = snap.get("steering_sensitivity", defaults.get("steering_sensitivity", 2.5))
	if _drone_min_altitude:
		_drone_min_altitude.value = snap.get("min_altitude", defaults.get("min_altitude", 0.5))
	if _drone_max_altitude:
		_drone_max_altitude.value = snap.get("max_altitude", defaults.get("max_altitude", 8000.0))
	if _drone_tilt_intensity:
		_drone_tilt_intensity.value = snap.get("tilt_intensity", defaults.get("tilt_intensity", 35.0))
	if _drone_tilt_speed:
		_drone_tilt_speed.value = snap.get("tilt_speed", defaults.get("tilt_speed", 8.0))
	if _drone_fov:
		_drone_fov.value = snap.get("drone_fov", 50.0)


func _sync_stars_planets_from_snapshot(snap: Dictionary) -> void:
	if _stars_brightness:
		_stars_brightness.value = snap.get("stars_brightness", 1.0)
	if _stars_twinkle:
		_stars_twinkle.value = snap.get("stars_twinkle", 0.3)
	if _stars_horizon:
		_stars_horizon.value = snap.get("stars_horizon_fade", 0.5)
	if _stars_glow:
		_stars_glow.value = snap.get("stars_glow", 0.0)
	if _stars_point_size:
		_stars_point_size.value = snap.get("stars_point_size", 0.0)
	if _stars_saturation:
		_stars_saturation.value = snap.get("stars_saturation", 1.5)
	if _stars_contrast:
		_stars_contrast.value = snap.get("stars_contrast", 1.4)
	if _stars_bg_cut:
		_stars_bg_cut.value = snap.get("stars_background_cut", 0.02)
	if _stars_wash:
		_stars_wash.value = snap.get("stars_wash", 0.7)
	if _mw_gain:
		_mw_gain.value = snap.get("milkyway_gain", 1.3)
	if _mw_sat:
		_mw_sat.value = snap.get("milkyway_saturation", 1.2)
	if _mw_tint and snap.get("milkyway_tint") is Color:
		_mw_tint.color = snap.get("milkyway_tint")
	if _star_quality:
		var high_ok := bool(snap.get("texture_quality_high_available", false))
		_star_quality.set_item_disabled(1, not high_ok)
		_star_quality.selected = 1 if str(snap.get("texture_quality", "standard")) == "high" and high_ok else 0
	if _planet_labels:
		_planet_labels.selected = clampi(int(snap.get("planet_labels_mode", 0)), 0, 2)
	if _star_trails:
		_star_trails.button_pressed = float(snap.get("star_trails", 0.0)) > 0.5
	if _star_trail_length:
		_star_trail_length.value = snap.get("star_trail_length", 0.35)
	if _lock_sky:
		_lock_sky.button_pressed = snap.get("lock_camera_to_sky", false)
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


func _on_analemma_type(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_type(idx)

func _on_show_sun_path(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_show_sun_path(on)

func _on_show_moon_path(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_show_moon_path(on)

func _on_show_planet_paths(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_show_planet_paths(on)

func _on_analemma_star_reveal(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_star_reveal(v)

func _on_zodiac_mode(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("zodiac_mode", idx)

func _on_zodiac_opacity(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("zodiac_opacity", v)

func _on_zodiac_lines(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("zodiac_show_lines", on)

func _on_zodiac_labels(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("zodiac_show_labels", on)

func _on_zodiac_ophiuchus(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("zodiac_show_ophiuchus", on)

func _on_zodiac_ecliptic(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("zodiac_show_ecliptic", on)

func _on_planet_path_frame(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_path_frame(idx)

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

func _on_shadow_opacity(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_shadow_opacity(v)

func _on_graphics_quality(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_graphics_quality(idx)


## Placed-prop render tuning (Tier 2 perf) — distance culling + shadow policy for
## user-placed props, which dominate the frame on prop-heavy sites. See
## core/perf/prop_render_tuning.gd.
func _build_prop_perf_section(v: Control) -> void:
	PropRenderTuning.ensure_loaded()
	_add_section_lbl(v, "Performance")
	_render_scale = _add_slider(v, "Render resolution %", 50.0, 100.0, 5.0, _on_render_scale)
	var rs_hint := Label.new()
	rs_hint.text = "Renders the 3D world below native resolution and upscales it — the biggest lever for GPU-limited (low-FPS) scenes. UI stays crisp. 100% = native."
	rs_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rs_hint.custom_minimum_size = Vector2(420, 0)
	rs_hint.add_theme_color_override("font_color", C_TEXT_S)
	rs_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(rs_hint)
	_prop_draw_dist = _add_slider(v, "Prop draw distance", 80.0, 1200.0, 20.0, _on_prop_draw_dist)
	_prop_shadows = _add_check(v, "Placed props cast shadows", _on_prop_shadows)
	var sd_row := HBoxContainer.new()
	sd_row.add_theme_constant_override("separation", 8)
	var sd_hdr := Label.new()
	sd_hdr.text = "Shadow detail"
	sd_hdr.custom_minimum_size = Vector2(110, 0)
	sd_hdr.add_theme_color_override("font_color", C_TEXT_S)
	sd_row.add_child(sd_hdr)
	_prop_shadow_detail = OptionButton.new()
	_prop_shadow_detail.add_item("Full (every part)", 0)
	_prop_shadow_detail.add_item("High", 1)
	_prop_shadow_detail.add_item("Medium (drop fine detail)", 2)
	_prop_shadow_detail.add_item("Low (main structure only)", 3)
	_prop_shadow_detail.add_theme_color_override("font_color", C_TEXT)
	_prop_shadow_detail.item_selected.connect(_on_prop_shadow_detail)
	sd_row.add_child(_prop_shadow_detail)
	v.add_child(sd_row)
	_perf_hud = _add_check(v, "Show performance overlay (F3)", _on_perf_hud)
	# Seed initial values without firing the apply callbacks (guarded by _syncing).
	var prev_sync := _syncing
	_syncing = true
	var main: Node = SimSettingsController.main_node
	if main != null and main.has_method("get_render_scale_3d"):
		_render_scale.value = float(main.call("get_render_scale_3d")) * 100.0
	else:
		_render_scale.value = RenderProfile.load_render_scale(1.0) * 100.0
	_prop_draw_dist.value = PropRenderTuning.base_distance_m
	_prop_shadows.button_pressed = PropRenderTuning.shadows_enabled
	_prop_shadow_detail.selected = clampi(PropRenderTuning.shadow_detail, 0, 3)
	_perf_hud.button_pressed = PerfMonitor.is_enabled()
	_syncing = prev_sync
	var hint := Label.new()
	hint.text = "Small props fade out past the draw distance to save GPU; large landmarks (StarShade, domes, racks) stay visible. Turning off prop shadows helps on sites with thousands of props. F3 opens the live frame-cost overlay."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)

func _on_render_scale(pct: float) -> void:
	if _syncing: return
	var main: Node = SimSettingsController.main_node
	if main != null and main.has_method("set_render_scale_3d"):
		main.call("set_render_scale_3d", clampf(pct / 100.0, 0.5, 1.0))
	elif main == null:
		# The hub: the file Main reads at boot (_load_render_scale_pref).
		RenderProfile.save_render_scale(clampf(pct / 100.0, 0.5, 1.0))

func _on_prop_draw_dist(val: float) -> void:
	if _syncing: return
	PropRenderTuning.base_distance_m = val
	PropRenderTuning.save()
	PropRenderTuning.apply_to_all(SimSettingsController.main_node)

func _on_prop_shadows(on: bool) -> void:
	if _syncing: return
	PropRenderTuning.shadows_enabled = on
	PropRenderTuning.save()
	PropRenderTuning.apply_to_all(SimSettingsController.main_node)

func _on_prop_shadow_detail(idx: int) -> void:
	if _syncing: return
	PropRenderTuning.shadow_detail = clampi(idx, 0, 3)
	PropRenderTuning.save()
	PropRenderTuning.apply_to_all(SimSettingsController.main_node)

func _on_perf_hud(on: bool) -> void:
	if _syncing: return
	PerfMonitor.set_enabled(on)

func _on_terrain_quality(v: float) -> void:
	var tier := int(round(v))
	_update_terrain_quality_label(tier)
	if _syncing: return
	var loader := _find_terrain_loader()
	if loader != null and loader.has_method("set_terrain_quality"):
		loader.call("set_terrain_quality", tier)
	elif hub_mode:
		# No loader at the hub: the global tier the next map reads
		# (the same key _sync_terrain_quality falls back to).
		var cfg := ConfigFile.new()
		cfg.load("user://terrain_config.cfg")
		cfg.set_value("terrain", "quality_tier", tier)
		cfg.save("user://terrain_config.cfg")

## Locate the active generated-map TerrainLoader (built-in maps have none).
func _find_terrain_loader() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.get_current_scene()
	if scene != null:
		var tl := scene.find_child("TerrainLoader", true, false)
		if tl != null:
			return tl
	var main := tree.get_first_node_in_group("main_scene")
	if main != null:
		return main.get_node_or_null("TerrainLoader")
	return null

## Refresh the terrain-quality slider + label from the active loader (or the saved
## config for built-in maps that have no loader).
func _sync_terrain_quality() -> void:
	if _terrain_quality == null:
		return
	var tier := 1
	var loader := _find_terrain_loader()
	if loader != null and loader.has_method("get_terrain_quality"):
		tier = int(loader.call("get_terrain_quality"))
	else:
		var cfg := ConfigFile.new()
		if cfg.load("user://terrain_config.cfg") == OK:
			tier = int(cfg.get_value("terrain", "quality_tier", 1))
	tier = clampi(tier, 0, 3)
	var was_syncing := _syncing
	_syncing = true
	_terrain_quality.value = float(tier)
	_syncing = was_syncing
	_update_terrain_quality_label(tier)

func _update_terrain_quality_label(tier: int) -> void:
	if _terrain_quality_lbl == null:
		return
	var loader := _find_terrain_loader()
	if loader != null and loader.has_method("terrain_quality_label"):
		_terrain_quality_lbl.text = str(loader.call("terrain_quality_label", tier))
	else:
		var names := ["Low", "Medium", "High", "Ultra"]
		_terrain_quality_lbl.text = names[clampi(tier, 0, 3)]

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

func _on_msaa_mode(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_msaa_level(idx)

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

func _on_sun_glow(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sun_glow(v)

func _on_sun_glow_size(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sun_glow_size(v)

func _on_sun_aureole(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sun_aureole(v)

func _on_god_rays(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_god_rays_enabled(on)

func _on_player_fov(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_player_fov(v)

func _on_drone_fov(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_fov(v)

func _on_drone_max_speed(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("max_forward_speed", v)

func _on_drone_vertical_speed(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("vertical_speed", v)

func _on_drone_acceleration(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("acceleration", v)

func _on_drone_drag(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("drag", v)

func _on_drone_steering(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("steering_sensitivity", v)

func _on_drone_min_altitude(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("min_altitude", v)

func _on_drone_max_altitude(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("max_altitude", v)

func _on_drone_tilt_intensity(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("tilt_intensity", v)

func _on_drone_tilt_speed(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_flight_setting("tilt_speed", v)

func _on_drone_controller_pitch_inverted(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_drone_bool_setting("controller_pitch_inverted", on)

func _on_cirrus_amount(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_cirrus_scale(v)

func _on_cirrus_wave_frequency(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_cirrus_wave_frequency_scale(v)

func _on_cirrus_wave_intensity(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_cirrus_wave_intensity_scale(v)

func _on_cloud_shadows(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_cloud_shadows_enabled(on)

func _on_building_shadows(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_building_shadows_enabled(on)

func _on_stars_brightness(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_brightness", v)

func _on_stars_twinkle(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_twinkle", v)

func _on_stars_horizon_fade(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_horizon_fade", v)

func _on_stars_glow(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_glow", v)

func _on_star_trails(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("star_trails", 1.0 if on else 0.0)

func _on_star_trail_length(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("star_trail_length", v)

func _on_lock_camera_to_sky(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("lock_camera_to_sky", on)

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

func _on_plant_growth(on: bool) -> void:
	if _syncing: return
	SimSettingsController.apply_plant_growth_enabled(on)
	_refresh_labels()

func _on_connector_losses(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_connector_losses_enabled(on)

func _on_conduits_3d_visible(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_conduits_3d_visible(on)


func _on_reset_all_autoroutes() -> void:
	var main := SimSettingsController.main_node if is_instance_valid(SimSettingsController) else null
	if main == null:
		return
	var mgr := main.get_node_or_null("ConduitManager")
	if mgr != null and mgr.has_method("reset_all_autoroutes"):
		mgr.call("reset_all_autoroutes")


func _on_conduit_flow_glow(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_conduit_flow_glow_enabled(on)

func _on_force_rainbow(on: bool) -> void:
	if _syncing: return
	SimSettingsController.set_force_rainbow(on)


func _on_analemma_drift(value: float) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_diurnal_offset(value)

func _on_analemma_noon(value: float) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_noon_offset(value)

func _on_analemma_thickness(value: float) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_path_thickness(value)

func _on_analemma_solar_col(value: Color) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_solar_color(value)

func _on_analemma_lunar_col(value: Color) -> void:
	if _syncing: return
	SimSettingsController.apply_analemma_lunar_color(value)


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


## How simulated people are drawn and controlled. A style choice, not a
## quality setting: the rigged body is photoreal enough that any imperfection
## in how it is driven reads as uncanny, while a stylised figure has no such
## contract with the viewer and the same approximate motion reads as
## deliberate.
##
## Both styles are posed from the SAME NpcPoseMachine, so behaviour is
## identical either way — people still walk the whole route, lie down on
## arrival and sit for the bathroom. Only the rendering differs.
## Settings → Window Wall (multi-monitor viewport). The tab body lives in its
## own script (scenes/ui/window_wall_settings_tab.gd) so this file does not
## grow another few hundred lines; it rebuilds itself from WindowWallPrefs on
## every open.
var _window_wall_tab: Control = null

func _build_window_wall_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Window Wall")
	var script := load("res://scenes/ui/window_wall_settings_tab.gd") as Script
	if script == null:
		return
	_window_wall_tab = VBoxContainer.new()
	_window_wall_tab.set_script(script)
	_window_wall_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_window_wall_tab)
	_window_wall_tab.call("bind", self)
	_window_wall_tab.call("refresh")


func _refresh_window_wall_tab() -> void:
	if _window_wall_tab != null and is_instance_valid(_window_wall_tab):
		_window_wall_tab.call("refresh")


## ---------------------------------------------------------------------------
## Settings → Controls: every project.godot [input] action with its key,
## click-to-capture rebinding, ↺ per row. The data layer is InputOverrides
## (user://input_overrides.cfg, applied in CursorController._ready); the
## rows' descriptions and groups are the F1 help overlay's own table, so the
## two never disagree about what a key does. Actions with no InputMap handler
## of the player's (ui_*) are left out.
## ---------------------------------------------------------------------------
var _ctl_rows: Dictionary = {}        # action -> {btn, reset, lbl}
var _ctl_capture := ""                # the action waiting for a key press
var _ctl_status: Label = null
var _ctl_conflicts: Label = null


func _build_controls_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Controls")
	_add_section_lbl(v, "Key bindings")
	_add_hint(v, "Click a key to change it, then press the new key (or a mouse side button; Esc cancels). Keys are remembered by position, so they stay put on any keyboard layout. ↺ puts a key back to the default. The F1 help, the on-screen prompts and the tour show whatever you choose.")
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_ctl_status = Label.new()
	_ctl_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ctl_status.add_theme_color_override("font_color", C_TEXT_S)
	_ctl_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_ctl_status.text = ""
	top.add_child(_ctl_status)
	var reset_all := Button.new()
	reset_all.text = "Reset all to defaults"
	reset_all.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(reset_all)
	reset_all.pressed.connect(func() -> void:
		InputOverrides.clear_all()
		_ctl_status.text = "Every key is back to its default."
		_ctl_refresh_rows())
	top.add_child(reset_all)
	v.add_child(top)
	_ctl_conflicts = Label.new()
	_ctl_conflicts.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ctl_conflicts.custom_minimum_size = Vector2(420, 0)
	_ctl_conflicts.add_theme_color_override("font_color", UITheme.C_WARN)
	_ctl_conflicts.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_ctl_conflicts.visible = false
	v.add_child(_ctl_conflicts)
	# The help overlay's groups and descriptions; then whatever project
	# action it does not list.
	var listed := {}
	var groups: Array = []
	var help_script := load("res://scenes/ui/help_overlay_ui.gd") as Script
	if help_script != null:
		groups = help_script.get_script_constant_map().get("_GROUPS", [])
	var project := InputOverrides.project_actions()
	for g in groups:
		var rows: Array = []
		for entry in (g[1] as Array):
			var action := str(entry[0])
			if action.begins_with("key:") or action.begins_with("ui_") or listed.has(action):
				continue
			if not project.has(action):
				continue
			listed[action] = true
			rows.append([action, str(entry[1])])
		if rows.is_empty():
			continue
		v.add_child(HSeparator.new())
		_add_section_lbl(v, str(g[0]))
		for r in rows:
			_ctl_add_row(v, r[0], r[1])
	var rest: Array = []
	for action in project.keys():
		var a := str(action)
		if not listed.has(a) and not a.begins_with("ui_"):
			rest.append(a)
	rest.sort()
	if not rest.is_empty():
		v.add_child(HSeparator.new())
		_add_section_lbl(v, "Other")
		for a in rest:
			_ctl_add_row(v, a, UiText.from_id(a))
	_ctl_refresh_rows()


func _ctl_add_row(parent: Control, action: String, description: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = description
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.tooltip_text = action
	lbl.add_theme_color_override("font_color", C_TEXT)
	row.add_child(lbl)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(150, 26)
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_meta("action", action)
	UITheme.style_button(btn)
	btn.pressed.connect(_ctl_begin_capture.bind(action))
	row.add_child(btn)
	var reset := IconButton.make("undo-2", "Back to the default key", _ctl_reset.bind(action))
	reset.focus_mode = Control.FOCUS_NONE
	reset.custom_minimum_size = Vector2(26, 26)
	row.add_child(reset)
	parent.add_child(row)
	_ctl_rows[action] = {"btn": btn, "reset": reset, "lbl": lbl}


## Every row's key chip from the LIVE InputMap (what the game actually fires).
func _ctl_refresh_rows() -> void:
	for action in _ctl_rows:
		var r: Dictionary = _ctl_rows[action]
		var btn := r["btn"] as Button
		var reset := r["reset"] as Button
		var over := InputOverrides.is_overridden(str(action))
		if _ctl_capture == str(action):
			btn.text = "Press a key…"
			btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		else:
			var label := HarnessInput.action_label(str(action))
			btn.text = label if not label.is_empty() else "—"
			if over:
				btn.add_theme_color_override("font_color", UITheme.C_WARN)
			else:
				btn.remove_theme_color_override("font_color")
		btn.tooltip_text = ("Changed from the default — ↺ restores it" if over else "Click, then press the new key")
		# The ↺ keeps its slot so the chips line up; it only shows when
		# there is something to undo.
		reset.modulate.a = 1.0 if over else 0.0
		reset.disabled = not over
		reset.mouse_filter = Control.MOUSE_FILTER_STOP if over else Control.MOUSE_FILTER_IGNORE


func _ctl_begin_capture(action: String) -> void:
	_ctl_capture = action
	_ctl_status.text = "Press the new key for \"%s\" — Esc cancels." % (_ctl_rows[action]["lbl"] as Label).text
	_ctl_conflicts.visible = false
	_ctl_refresh_rows()


func _ctl_reset(action: String) -> void:
	InputOverrides.clear_binding(action)
	_ctl_status.text = "%s is back to %s." % [(_ctl_rows[action]["lbl"] as Label).text, HarnessInput.action_label(action)]
	_ctl_conflicts.visible = false
	_ctl_refresh_rows()


## Bind `action` to `ev` (the capture's result, or a harness's). The one
## path every rebind takes: the file, the InputMap, the rows, the warning.
func rebind(action: String, ev: InputEvent) -> bool:
	if not _ctl_rows.has(action):
		return false
	var clash := InputOverrides.conflicts(action, ev)
	if not InputOverrides.set_binding(action, ev):
		_ctl_status.text = "That key cannot be bound."
		return false
	_ctl_capture = ""
	_ctl_status.text = "%s is now %s." % [(_ctl_rows[action]["lbl"] as Label).text, HarnessInput.action_label(action)]
	if clash.is_empty():
		_ctl_conflicts.visible = false
	else:
		var names := PackedStringArray()
		for c in clash:
			names.append((_ctl_rows[c]["lbl"] as Label).text if _ctl_rows.has(c) else UiText.from_id(c))
		_ctl_conflicts.text = "⚠ %s also fires: %s. Both will respond to that key." % [
			HarnessInput.event_label(ev), ", ".join(names)]
		_ctl_conflicts.visible = true
	_ctl_refresh_rows()
	return true


## The capture: the next key (or mouse side button) goes to the row that
## asked. Runs before every _unhandled_input, so Esc here cancels the capture
## instead of closing the panel.
func _input(event: InputEvent) -> void:
	if _ctl_capture.is_empty() or not visible:
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_ESCAPE:
			_ctl_capture = ""
			_ctl_status.text = "Unchanged."
			_ctl_refresh_rows()
			get_viewport().set_input_as_handled()
			return
		if code in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META, KEY_NONE]:
			return
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.ctrl_pressed = k.ctrl_pressed
		ev.shift_pressed = k.shift_pressed
		ev.alt_pressed = k.alt_pressed
		ev.meta_pressed = k.meta_pressed
		rebind(_ctl_capture, ev)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var m := event as InputEventMouseButton
		if not m.pressed or int(m.button_index) < InputOverrides.MOUSE_MIN_BUTTON:
			return
		var ev := InputEventMouseButton.new()
		ev.button_index = m.button_index
		rebind(_ctl_capture, ev)
		get_viewport().set_input_as_handled()


## Settings → Player: your own camera and body (PlayerPrefs; the FOV stays in
## SimSettingsController's sim_settings.cfg, only its slider lives here now).
func _build_player_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "Player")
	_add_section_lbl(v, "Camera")
	var view := _add_option(v, "View", ["First person", "Third person (follow)"],
		func(idx: int) -> void:
			PlayerPrefs.set_camera_mode(PlayerPrefs.CAMERA_THIRD if idx == 1 else PlayerPrefs.CAMERA_FIRST))
	view.selected = 1 if PlayerPrefs.third_person() else 0
	_add_hint(v, "F5 switches between them in play. Third person is a follow camera: the mouse orbits it, you walk the way it faces and your body turns to follow; on a vehicle it chases behind.")
	_player_fov = _add_slider(v, "Field of view°", 30.0, 120.0, 1.0, _on_player_fov)
	_add_hint(v, "Horizontal field of view on foot, in both views. Wider = more peripheral view (and more lens distortion). Drone FOV is under the Drone tab.")
	var dist := _add_slider(v, "Follow distance", PlayerPrefs.TP_DISTANCE_MIN,
		PlayerPrefs.TP_DISTANCE_MAX, 0.1, func(m: float) -> void: PlayerPrefs.set_tp_distance(m))
	dist.set_value_no_signal(PlayerPrefs.tp_distance())
	var shoulder := _add_option(v, "Shoulder", ["Left", "Centred", "Right"],
		func(idx: int) -> void: PlayerPrefs.set_tp_shoulder(idx - 1))
	shoulder.selected = PlayerPrefs.tp_shoulder() + 1
	var recenter := _add_check(v, "Swing the camera back behind a vehicle while driving",
		func(on: bool) -> void: PlayerPrefs.set_tp_recenter(on))
	recenter.set_pressed_no_signal(PlayerPrefs.tp_recenter())

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Character")
	var body_opt := OptionButton.new()
	body_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var body_row := HBoxContainer.new()
	body_row.add_theme_constant_override("separation", 8)
	var bh := Label.new()
	bh.text = "Body"
	bh.custom_minimum_size = Vector2(110, 0)
	bh.add_theme_color_override("font_color", C_TEXT_S)
	body_row.add_child(bh)
	body_row.add_child(body_opt)
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.tooltip_text = "Look for new character files"
	UITheme.style_button(rescan)
	body_row.add_child(rescan)
	v.add_child(body_row)
	var fill_bodies := func() -> void:
		body_opt.clear()
		var opts := PlayerPrefs.body_options()
		var cur := PlayerPrefs.body()
		var sel := 0
		for i in opts.size():
			var o: Dictionary = opts[i]
			body_opt.add_item(str(o["label"]), i)
			body_opt.set_item_metadata(i, str(o["id"]))
			if str(o["id"]) == cur:
				sel = i
		body_opt.selected = sel
	fill_bodies.call()
	body_opt.item_selected.connect(func(idx: int) -> void:
		PlayerPrefs.set_body(str(body_opt.get_item_metadata(idx))))
	rescan.pressed.connect(fill_bodies)
	_add_color_row(v, "Outline colour", PlayerPrefs.tint(),
		func(c: Color) -> void: PlayerPrefs.set_tint(c))
	var folder := Button.new()
	folder.text = "Open characters folder…"
	UITheme.style_button(folder)
	folder.pressed.connect(func() -> void:
		OS.shell_open(PlayerPrefs.ensure_custom_dir()))
	v.add_child(folder)
	_add_hint(v, "The default body is a detailed version of the NPCs' stick figure. To play as another character, drop a .glb, .gltf or .fbx into the characters folder and press Rescan. Its own clips are used when they are named idle / walk / run; a Mixamo-rigged character without them borrows Remy's idle, walk and jog (needs the Player Character pack). Remy appears in the list when that pack is installed.")


## Settings -> NPCs -> Crowd detail: the LOOK vs PERFORMANCE knobs, each
## 0 = Auto (the graphics tier's number), with a live readout of what is on
## screen right now and the frame rate, so the player can turn a number up
## and watch both.
func _build_crowd_detail(v: VBoxContainer) -> void:
	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Crowd detail (look vs performance)")
	_add_budget_row(v, "Full-detail figures", NpcDisplayPrefs.FULL_FIGURES_MAX, 8,
		NpcDisplayPrefs.full_figures(), "",
		func(n: float) -> void: NpcDisplayPrefs.set_full_figures(int(n)),
		"People drawn as full stick figures (or rigged bodies), nearest first. Everyone past this number is drawn as a simpler crowd figure. About 0.1 ms each. Auto = the graphics quality's number (16 / 24 / 40 / 64; 64 with the light crowd off).")
	_add_budget_row(v, "Simulated in full", NpcDisplayPrefs.FULL_SIM_MAX, 10,
		NpcDisplayPrefs.full_sim(), "",
		func(n: float) -> void: NpcDisplayPrefs.set_full_sim(int(n)),
		"People run by the full simulation (paths, chores, individual poses) — the camps nearest you first. Only these can be full-detail figures; everyone else runs in the light crowd. Costs simulation time per tick. Auto = 150.")
	_add_budget_row(v, "Crowd figure reach", int(NpcDisplayPrefs.FIGURE_DIST_MAX), 10,
		int(NpcDisplayPrefs.figure_dist_m()), " m",
		func(n: float) -> void: NpcDisplayPrefs.set_figure_dist_m(n),
		"How far crowd figures are drawn as bodies before they become dots. Cheap (GPU only). Auto = the graphics quality's distance.")
	var shed := _add_check(v, "Lighter at high speed (fewer full figures and full simulation above 300×)",
		func(on: bool) -> void: NpcDisplayPrefs.set_speed_shed(on))
	shed.button_pressed = NpcDisplayPrefs.speed_shed()
	shed.tooltip_text = "At 300× and faster a full figure is a blur: shrink both budgets (to about 60 % at 300×, 30 % at 1000×) to keep the frame rate up."
	var live := Label.new()
	live.add_theme_color_override("font_color", C_TEXT)
	live.add_theme_font_size_override("font_size", 11)
	v.add_child(live)
	var tick := Timer.new()
	tick.wait_time = 0.5
	tick.autostart = true
	live.add_child(tick)
	var refresh := func() -> void:
		if not live.is_visible_in_tree():
			return
		var main0 := get_tree().current_scene
		var host := main0.get_node_or_null("NpcPopulationHost") if main0 != null else null
		var cr := main0.get_node_or_null("CrowdRenderer") if main0 != null else null
		if host == null:
			live.text = "Now: no people simulated on this map."
			return
		var heroes: int = (host.get("_hero_ids") as Dictionary).size() if host.get("_hero_ids") is Dictionary else 0
		var budget := int(host.call("hero_budget"))
		var over := int(cr.call("full_people_drawn")) if cr != null else 0
		var crowd := int(cr.call("people_drawn")) - over if cr != null else 0
		live.text = "Now: %s (budget %d) · %s · %d light crowd%s · %d fps" % [
			UiText.count(heroes, "full-detail figure"), budget, UiText.count(over, "full-tier as crowd figure"), maxi(crowd, 0),
			"" if NpcDisplayPrefs.light_crowd() else " (hidden)", Engine.get_frames_per_second()]
	tick.timeout.connect(refresh)
	refresh.call()
	_add_hint(v, "Turn a number up and watch the frame rate here (or F3). The full simulation and the full figures cost CPU; the crowd figures and their reach cost GPU. 0 / far left = Auto.")


## A 0 = Auto slider row with a value label ("Auto" or the number + suffix).
func _add_budget_row(v: VBoxContainer, title: String, max_v: int, step: int, cur: int,
		suffix: String, setter: Callable, tip: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = title
	hdr.custom_minimum_size = Vector2(150, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var sl := HSlider.new()
	sl.min_value = 0
	sl.max_value = max_v
	sl.step = step
	sl.custom_minimum_size = Vector2(200, 0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value = cur
	sl.tooltip_text = tip
	hdr.tooltip_text = tip
	hdr.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(sl)
	var val := Label.new()
	val.custom_minimum_size = Vector2(64, 0)
	val.add_theme_color_override("font_color", C_TEXT)
	val.text = "Auto" if cur <= 0 else "%d%s" % [cur, suffix]
	row.add_child(val)
	sl.value_changed.connect(func(n: float) -> void:
		val.text = "Auto" if n <= 0.0 else "%d%s" % [int(n), suffix]
		setter.call(n))
	v.add_child(row)


func _add_hint(parent: Control, text: String) -> Label:
	var hint := Label.new()
	hint.text = text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	parent.add_child(hint)
	return hint


func _build_npc_tab(tabs: TabContainer) -> void:
	var v := _make_tab(tabs, "NPC")
	# The master switch: no population simulation and nothing drawn, for site
	# analysis without the people's cost (NpcDisplayPrefs.npcs_enabled).
	_add_section_lbl(v, "Population")
	var npc_on_check := _add_check(v, "Simulate & draw NPCs",
		func(on: bool) -> void: NpcDisplayPrefs.set_npcs_enabled(on))
	npc_on_check.set_pressed_no_signal(NpcDisplayPrefs.npcs_enabled_saved())
	npc_on_check.tooltip_text = "Off: every person is frozen and hidden, with no simulation or rendering cost. Habitats bill their authored headcount at the classic constant rate, so the graph's water/food/waste numbers still mean something. Switch back on and the community resumes where it was left (a long gap is caught up the usual way). Festival mode switches it back on."
	_add_hint(v, "Turn off for site analysis — no NPC logic, figures, crowd, chips or alarms. The people are paused, not deleted.")
	# The fabrication clips the build crews play (saw, drill, fasten, carry,
	# lift) are authored here.
	var anim_btn := Button.new()
	anim_btn.text = "Animation editor…"
	anim_btn.tooltip_text = "Pose and keyframe the stick figure with a tool in its hands — sawing, drilling, fastening, carrying — and save the clips the build crews play."
	UITheme.style_button(anim_btn)
	anim_btn.pressed.connect(func() -> void:
		var m := get_tree().current_scene
		if m != null and m.has_method("open_npc_anim_editor"):
			m.call("open_npc_anim_editor", ""))
	v.add_child(anim_btn)
	_add_section_lbl(v, "Body style")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = "Body style"
	hdr.custom_minimum_size = Vector2(110, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var opt := OptionButton.new()
	opt.add_item("Humanoid (rigged)", 0)
	opt.add_item("Simplified (stylised)", 1)
	opt.selected = 1 if NpcDisplayPrefs.wants_simple() else 0
	opt.item_selected.connect(func(idx: int) -> void:
		NpcDisplayPrefs.set_style(NpcDisplayPrefs.STYLE_SIMPLE if idx == 1
			else NpcDisplayPrefs.STYLE_HUMANOID))
	row.add_child(opt)
	v.add_child(row)
	var hint := Label.new()
	hint.text = "Simplified draws articulated stick figures with elbows and knees. Behaviour is identical — only the look changes. Takes effect as people come back into view."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 10)
	v.add_child(hint)
	# Mo-cap SPICE: how often a nearby stick figure breaks into a real
	# motion-captured clip (NpcMocapSpice), then eases back to procedural.
	var mc_row := HBoxContainer.new()
	mc_row.add_theme_constant_override("separation", 8)
	var mc_lbl := Label.new()
	mc_lbl.text = "Mo-cap spice"
	mc_lbl.custom_minimum_size = Vector2(110, 0)
	mc_lbl.add_theme_color_override("font_color", C_TEXT_S)
	mc_row.add_child(mc_lbl)
	var mc := HSlider.new()
	mc.min_value = 0.0
	mc.max_value = 1.0
	mc.step = 0.05
	mc.custom_minimum_size = Vector2(160, 0)
	mc.value = NpcDisplayPrefs.mocap_spice()
	mc.tooltip_text = "Simplified style: how often a nearby stick figure breaks into a real motion-captured clip (FUCK YES, a cheer, a dance break, a story, a stretch…) before easing back. 0 = never (procedural only), middle = as designed, right = twice as often. Clips live in Imported Models/NPC/mocap/<moment>/ (see ASSETS.md); a moment with none stays procedural."
	var mc_val := Label.new()
	mc_val.custom_minimum_size = Vector2(60, 0)
	mc_val.add_theme_color_override("font_color", C_TEXT_S)
	mc_val.text = "off" if mc.value <= 0.001 else "%d %%" % int(round(mc.value * 100.0))
	mc.value_changed.connect(func(val: float) -> void:
		NpcDisplayPrefs.set_mocap_spice(val)
		mc_val.text = "off" if val <= 0.001 else "%d %%" % int(round(val * 100.0)))
	mc_row.add_child(mc)
	mc_row.add_child(mc_val)
	v.add_child(mc_row)
	if not NpcRig.available():
		var miss := Label.new()
		miss.text = "The humanoid character pack is not installed (see ASSETS.md) — simplified is in use regardless."
		miss.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		miss.custom_minimum_size = Vector2(420, 0)
		miss.add_theme_color_override("font_color", UITheme.C_WARN)
		miss.add_theme_font_size_override("font_size", 10)
		v.add_child(miss)

	var beat_check := _add_check(v, "Dance to the beat",
		func(on: bool) -> void: NpcDisplayPrefs.set_beat_sync(on))
	beat_check.set_pressed_no_signal(NpcDisplayPrefs.beat_sync())
	_add_hint(v, "People dancing near a playing stage move on its beat, put their hands up as a drop builds and jump when it lands; the DJ holds an arm up through the run-up. A stage's own track (its Music) is analysed live; a set with no track gets a made-up one at a typical tempo. LED lights have their own \"Sound reactive\" switch in the Light Studio (J).")

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Names")
	var names_edit := TextEdit.new()
	names_edit.custom_minimum_size = Vector2(420, 64)
	names_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	names_edit.placeholder_text = "Alex, Sam, River, …"
	names_edit.text = ", ".join(NpcDisplayPrefs.custom_names())
	v.add_child(names_edit)
	var names_row := HBoxContainer.new()
	names_row.add_theme_constant_override("separation", 8)
	var names_apply := Button.new()
	names_apply.text = "Add to the name list"
	UITheme.style_button(names_apply)
	var names_clear := Button.new()
	names_clear.text = "Clear"
	UITheme.style_button(names_clear)
	var names_status := Label.new()
	names_status.add_theme_color_override("font_color", C_TEXT_S)
	names_status.add_theme_font_size_override("font_size", 10)
	var n0 := NpcDisplayPrefs.custom_names().size()
	names_status.text = "%d of your names in the list" % n0 if n0 > 0 else "using the built-in names"
	names_apply.pressed.connect(func() -> void:
		var kept := NpcDisplayPrefs.set_custom_names(NpcDisplayPrefs.parse_names(names_edit.text))
		names_edit.text = ", ".join(kept)
		names_status.text = "%d of your names in the list" % kept.size() if kept.size() > 0 \
			else "using the built-in names")
	names_clear.pressed.connect(func() -> void:
		NpcDisplayPrefs.set_custom_names(PackedStringArray())
		names_edit.text = ""
		names_status.text = "using the built-in names")
	names_row.add_child(names_apply)
	names_row.add_child(names_clear)
	names_row.add_child(names_status)
	v.add_child(names_row)
	_add_hint(v, "Comma-separated names (friends, crew…) added to the %d built-in ones; people are dealt names from the whole list, so yours turn up among everyone else. Names are dealt by a hash of each person, so changing the list re-deals names (people simulated up close pick up their new name when the site reloads)." % NpcAgent.NAME_POOL.size())

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Appearance")
	var colors_check := _add_check(v, "Show NPC tint colors",
		func(on: bool) -> void: _on_npc_colors_toggled(on))
	colors_check.button_pressed = NpcDisplayPrefs.colors_enabled()
	var colors_hint := Label.new()
	colors_hint.text = "Each person gets a distinct pastel outline by default. Turn off to render everyone in plain black — no individual colors."
	colors_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	colors_hint.custom_minimum_size = Vector2(420, 0)
	colors_hint.add_theme_color_override("font_color", C_TEXT_S)
	colors_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(colors_hint)

	var overhead_row := HBoxContainer.new()
	overhead_row.add_theme_constant_override("separation", 8)
	var oh_hdr := Label.new()
	oh_hdr.text = "Overhead status"
	oh_hdr.custom_minimum_size = Vector2(110, 0)
	oh_hdr.add_theme_color_override("font_color", C_TEXT_S)
	overhead_row.add_child(oh_hdr)
	var oh_opt := OptionButton.new()
	oh_opt.add_item("Always (nearby)", 0)
	oh_opt.add_item("Only when aimed at", 1)
	oh_opt.add_item("Off", 2)
	oh_opt.selected = NpcDisplayPrefs.OVERHEAD_MODES.find(
		NpcDisplayPrefs.overhead_mode())
	oh_opt.item_selected.connect(func(idx: int) -> void:
		NpcDisplayPrefs.set_overhead_mode(
			str(NpcDisplayPrefs.OVERHEAD_MODES[clampi(idx, 0, 2)])))
	overhead_row.add_child(oh_opt)
	v.add_child(overhead_row)
	var oh_hint := Label.new()
	oh_hint.text = "The task tag (and, if enabled below, the morale bar) above each head. 'Always' shows them for people within ~30 m; 'Off' keeps clean silhouettes (aiming still names people)."
	oh_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	oh_hint.custom_minimum_size = Vector2(420, 0)
	oh_hint.add_theme_color_override("font_color", C_TEXT_S)
	oh_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(oh_hint)
	var bars_check := _add_check(v, "Show mood bars over heads",
		func(on: bool) -> void: NpcDisplayPrefs.set_mood_bars(on))
	bars_check.button_pressed = NpcDisplayPrefs.mood_bars()
	var peak_check := _add_check(v, "Peak Experience toasts (FUCK YES!!!)",
		func(on: bool) -> void: NpcDisplayPrefs.set_peak_toasts(on))
	peak_check.button_pressed = NpcDisplayPrefs.peak_toasts()
	var beacon_check := _add_check(v, "Beacon over each FUCK YES!!! (where it happened)",
		func(on: bool) -> void: NpcDisplayPrefs.set_peak_beacons(on))
	beacon_check.button_pressed = NpcDisplayPrefs.peak_beacons()
	var fun_check := _add_check(v, "Fun Meter (the crowd's overall vibe, a needle gauge)",
		func(on: bool) -> void: NpcDisplayPrefs.set_fun_meter(on))
	fun_check.button_pressed = NpcDisplayPrefs.fun_meter()
	# How contagious FUCK YES!!! is: 0 = every peak is its own spark, 1 = as
	# shipped, 4 = wildfire. Live (the field reads it every tick).
	var cont_row := HBoxContainer.new()
	cont_row.add_theme_constant_override("separation", 8)
	var cont_lbl := Label.new()
	cont_lbl.text = "FUCK YES contagion"
	cont_lbl.custom_minimum_size = Vector2(150, 0)
	cont_lbl.add_theme_color_override("font_color", C_TEXT_S)
	cont_row.add_child(cont_lbl)
	var cont_slider := HSlider.new()
	cont_slider.min_value = 0.0
	cont_slider.max_value = PopTestPrefs.MAX_PEAK_CONTAGION
	cont_slider.step = 0.05
	cont_slider.custom_minimum_size = Vector2(160, 0)
	cont_slider.value = PopTestPrefs.peak_contagion()
	cont_slider.tooltip_text = "How strongly one person at FUCK YES!!! raises the odds of the people round them. 0 = no spread (every peak is its own spark), 1 = as designed, 4 = wildfire."
	cont_row.add_child(cont_slider)
	var cont_val := Label.new()
	cont_val.custom_minimum_size = Vector2(60, 0)
	cont_val.add_theme_color_override("font_color", C_TEXT_S)
	cont_val.text = _contagion_text(cont_slider.value)
	cont_row.add_child(cont_val)
	cont_slider.value_changed.connect(func(val: float) -> void:
		PopTestPrefs.set_peak_contagion(val)
		cont_val.text = _contagion_text(val))
	cont_slider.drag_ended.connect(func(_c: bool) -> void: PopTestPrefs.save())
	v.add_child(cont_row)
	# Venue music (StageMusic): a stage's track while its set is on.
	var mus_row := HBoxContainer.new()
	mus_row.add_theme_constant_override("separation", 8)
	var mus_lbl := Label.new()
	mus_lbl.text = "Stage music volume"
	mus_lbl.custom_minimum_size = Vector2(150, 0)
	mus_lbl.add_theme_color_override("font_color", C_TEXT_S)
	mus_row.add_child(mus_lbl)
	var mus := HSlider.new()
	mus.min_value = 0.0
	mus.max_value = 1.0
	mus.step = 0.05
	mus.custom_minimum_size = Vector2(160, 0)
	mus.value = NpcDisplayPrefs.stage_music_volume()
	mus.tooltip_text = "Volume of the tracks venues play during their sets (set a venue's track in its Ctrl-focus row → Music). 0 = off."
	mus.value_changed.connect(func(val: float) -> void: NpcDisplayPrefs.set_stage_music_volume(val))
	mus_row.add_child(mus)
	v.add_child(mus_row)
	var glow_hint := Label.new()
	glow_hint.text = "People glow with how good a time they are having; a crowd that is vibing with its needs met builds a CHARGE toward FUCK YES!!! — a green shimmer that grows and quickens on the body, faster with peakers nearby (the meter over their head shows it, with ↑ while someone is feeding it) — then tips into a green, pulsing glow and the samba. Every one scores a Peak Experience. Each person's state (FUCK THIS!!! … Fuck It!) shows over their head; the bars are off by default."
	glow_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	glow_hint.custom_minimum_size = Vector2(420, 0)
	glow_hint.add_theme_color_override("font_color", C_TEXT_S)
	glow_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(glow_hint)

	# Festival scale: which people are DRAWN. The simulation runs regardless.
	var crowd_row := HBoxContainer.new()
	crowd_row.add_theme_constant_override("separation", 8)
	var cr_hdr := Label.new()
	cr_hdr.text = "Draw people"
	cr_hdr.custom_minimum_size = Vector2(110, 0)
	cr_hdr.add_theme_color_override("font_color", C_TEXT_S)
	crowd_row.add_child(cr_hdr)
	var cr_opt := OptionButton.new()
	cr_opt.add_item("Home camp only", 0)
	cr_opt.add_item("All camps", 1)
	cr_opt.add_item("Within a distance", 2)
	cr_opt.add_item("Nobody", 3)
	cr_opt.selected = NpcDisplayPrefs.CROWD_MODES.find(NpcDisplayPrefs.crowd_draw())
	cr_opt.item_selected.connect(func(idx: int) -> void:
		NpcDisplayPrefs.set_crowd_draw(str(NpcDisplayPrefs.CROWD_MODES[clampi(idx, 0, 3)])))
	crowd_row.add_child(cr_opt)
	var cr_dist := SpinBox.new()
	cr_dist.min_value = 50
	cr_dist.max_value = 5000
	cr_dist.step = 50
	cr_dist.suffix = " m"
	cr_dist.value = NpcDisplayPrefs.crowd_lod_m()
	cr_dist.custom_minimum_size = Vector2(96, 0)
	cr_dist.tooltip_text = "Reach of 'Within a distance'"
	cr_dist.value_changed.connect(func(v2: float) -> void:
		NpcDisplayPrefs.set_crowd_lod_m(v2))
	crowd_row.add_child(cr_dist)
	v.add_child(crowd_row)
	var lc_check := _add_check(v, "Distant crowd as dots (the light crowd past the figure reach)",
		func(on: bool) -> void: NpcDisplayPrefs.set_light_crowd(on))
	lc_check.button_pressed = NpcDisplayPrefs.light_crowd()
	lc_check.tooltip_text = "The far field of the festival crowd, drawn as dots out to 3 km. Off: no dots — the light crowd is drawn only as figures near you and dissolves out toward the edge of the Crowd figure reach. Nobody near you ever pops in or out either way."
	_build_crowd_detail(v)
	var cr_hint := Label.new()
	cr_hint.text = "At festival scale the camp you are in keeps full bodies; every other camp is a light crowd drawn as figures up close and dots far away. 'Home camp only' draws just your camp; 'Nobody' hides everyone (the simulation and the Site Plan keep running)."
	cr_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cr_hint.custom_minimum_size = Vector2(420, 0)
	cr_hint.add_theme_color_override("font_color", C_TEXT_S)
	cr_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(cr_hint)

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Testing & provisioning")
	var t_hint := Label.new()
	t_hint.text = "Guardrails off, for trying things out. 'Ideal supply' meets every need as if the infrastructure were perfect and reports what it would have to deliver (the optimal demand); the others stop queues, departures and the alarm feed."
	t_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t_hint.custom_minimum_size = Vector2(420, 0)
	t_hint.add_theme_color_override("font_color", C_TEXT_S)
	t_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(t_hint)
	var ideal_chk := _add_check(v, "Ideal supply — every need met, shortfalls counted as imports", func(on: bool) -> void:
		PopTestPrefs.set_ideal_supply(on)
		PopTestPrefs.save())
	# The SAVED flags, not the accessors: festival mode's session override
	# makes every accessor read ON, and the boxes must not pretend the
	# player ticked them.
	var saved_flags := PopTestPrefs.saved_flags()
	ideal_chk.button_pressed = bool(saved_flags["ideal_supply"])
	var cap_chk := _add_check(v, "Ignore space capacity (no queues)", func(on: bool) -> void:
		PopTestPrefs.set_ignore_capacity(on)
		PopTestPrefs.save())
	cap_chk.button_pressed = bool(saved_flags["ignore_capacity"]) and not bool(saved_flags["ideal_supply"])
	var dep_chk := _add_check(v, "Nobody leaves, perishes or collapses the colony", func(on: bool) -> void:
		PopTestPrefs.set_no_departures(on)
		PopTestPrefs.save())
	dep_chk.button_pressed = bool(saved_flags["no_departures"])
	var mute_chk2 := _add_check(v, "Mute the settlement feed, alarms and toasts", func(on: bool) -> void:
		PopTestPrefs.set_mute_alarms(on)
		PopTestPrefs.save())
	mute_chk2.button_pressed = bool(saved_flags["mute_alarms"])
	var prov_row := HBoxContainer.new()
	prov_row.add_theme_constant_override("separation", 8)
	var prov_lbl := Label.new()
	prov_lbl.text = "New camps stocked for"
	prov_lbl.custom_minimum_size = Vector2(150, 0)
	prov_lbl.add_theme_color_override("font_color", C_TEXT_S)
	prov_row.add_child(prov_lbl)
	var prov_opt := OptionButton.new()
	for i in CampProvisioning.PRESET_ORDER.size():
		prov_opt.add_item(CampProvisioning.preset_label(str(CampProvisioning.PRESET_ORDER[i])), i)
	prov_opt.selected = maxi(CampProvisioning.PRESET_ORDER.find(PopTestPrefs.provision_preset()), 0)
	prov_opt.tooltip_text = "How many days of water, food and firewood a camp stamped from a placement lot starts with (also the inspector's default)"
	prov_opt.item_selected.connect(func(idx: int) -> void:
		PopTestPrefs.set_provision_preset(str(CampProvisioning.PRESET_ORDER[clampi(idx, 0, CampProvisioning.PRESET_ORDER.size() - 1)]))
		PopTestPrefs.save())
	prov_row.add_child(prov_opt)
	v.add_child(prov_row)
	# Festival population: the total the camps are scaled to (0 = natural).
	# A performance knob as much as a taste — fewer people, faster sim.
	var pop_row := HBoxContainer.new()
	pop_row.add_theme_constant_override("separation", 8)
	var pop_lbl := Label.new()
	pop_lbl.text = "Festival population"
	pop_lbl.custom_minimum_size = Vector2(150, 0)
	pop_lbl.add_theme_color_override("font_color", C_TEXT_S)
	pop_row.add_child(pop_lbl)
	var pop_spin := SpinBox.new()
	pop_spin.min_value = 0
	pop_spin.max_value = PopTestPrefs.MAX_FESTIVAL_TARGET
	pop_spin.step = 10
	pop_spin.value = PopTestPrefs.festival_target_people()
	pop_spin.tooltip_text = "Total people across every festival camp, split by each camp's painted size. 0 = natural (from the camps' areas). Applies live; rosters grow and shrink in place."
	pop_spin.value_changed.connect(func(val: float) -> void:
		var main0 := get_tree().current_scene
		var fm0: Variant = main0.get("festival_mode") if main0 != null and "festival_mode" in main0 else null
		if fm0 is Node and is_instance_valid(fm0) and (fm0 as Node).has_method("set_target_people"):
			(fm0 as Node).call("set_target_people", int(val))
		else:
			PopTestPrefs.set_festival_target_people(int(val))
			PopTestPrefs.save()
			var ld := TerrainSurfaceQuery.find_terrain_loader(main0)
			if ld != null and ld.has_method("apply_festival_population_target"):
				ld.call("apply_festival_population_target"))
	pop_row.add_child(pop_spin)
	v.add_child(pop_row)

	v.add_child(HSeparator.new())
	_add_section_lbl(v, "Routines")
	var routines_btn := Button.new()
	routines_btn.text = "Routines & chores…"
	routines_btn.pressed.connect(_on_open_npc_routines)
	v.add_child(routines_btn)
	var routines_hint := Label.new()
	routines_hint.text = "Opens the roster, schedules, and chore board for the nearest active habitat. Also available from that habitat's inspector panel in the graph."
	routines_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	routines_hint.custom_minimum_size = Vector2(420, 0)
	routines_hint.add_theme_color_override("font_color", C_TEXT_S)
	routines_hint.add_theme_font_size_override("font_size", 10)
	v.add_child(routines_hint)


## "Colors off" is a live-render toggle, not a body-style choice — flip it and
## already-spawned avatars re-tint immediately (unlike body style, which only
## takes effect as people come back into view) since it is a much cheaper,
## purely cosmetic change to apply.
func _on_npc_colors_toggled(on: bool) -> void:
	NpcDisplayPrefs.set_colors_enabled(on)
	var graph := ServiceLocator.graph()
	if graph == null or not graph.has_method("npc_population_host"):
		return
	var host: Node = graph.call("npc_population_host")
	if host != null and host.has_method("refresh_tints"):
		host.call("refresh_tints")


## Opens Routines & chores for the first active pop-driven habitat (same modal
## the per-habitat inspector button opens). With none active yet, this still
## opens the modal so its own "turn on Simulated individuals" guidance shows.
static func _contagion_text(v: float) -> String:
	return "off" if v <= 0.001 else "%.2f×" % v


func _on_open_npc_routines() -> void:
	var graph := ServiceLocator.graph()
	if graph == null or not graph.has_method("open_npc_routines"):
		return
	var item_id := ""
	if graph.has_method("npc_population_bridge"):
		var bridge: NpcPopulationBridge = graph.call("npc_population_bridge")
		if bridge != null:
			var ids: Array = bridge.habitat_ids()
			if not ids.is_empty():
				item_id = str(ids[0])
	graph.call("open_npc_routines", item_id)


# ==================== Star look / night sky / planet labels ====================

func _on_stars_point_size(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_point_size", v)

func _on_stars_saturation(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_saturation", v)

func _on_stars_contrast(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_contrast", v)

func _on_stars_bg_cut(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_background_cut", v)

func _on_stars_wash(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("stars_wash", v)

func _on_mw_gain(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("milkyway_gain", v)

func _on_mw_sat(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("milkyway_saturation", v)

func _on_star_quality(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("texture_quality", "high" if idx == 1 else "standard")

func _on_planet_labels(idx: int) -> void:
	if _syncing: return
	SimSettingsController.apply_planet_setting("planet_labels_mode", idx)

func _on_twilight_drama(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("twilight_drama", v)

func _on_airglow(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("airglow_strength", v)

func _on_airglow_color(c: Color) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("airglow_color", c)

func _on_light_pollution(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("light_pollution", v)

func _on_light_pollution_color(c: Color) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("light_pollution_color", c)

func _on_moon_sky_glow(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("moon_sky_glow", v)

func _on_mw_tint(c: Color) -> void:
	if _syncing: return
	SimSettingsController.apply_star_setting("milkyway_tint", c)


func _on_twilight_length(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("twilight_length", v)

func _on_sun_warmth(v: float) -> void:
	if _syncing: return
	SimSettingsController.apply_sky_setting("sun_warmth", v)
