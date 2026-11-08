class_name GlobeMode
extends Control

## Globe mode (Phase 2): the 3D Earth as its own screen, beside the 2D
## location picker (which is unchanged). Opened from the launch hub's "Globe"
## button or in-game with toggle_globe (Shift+L).
##
## - Search a place (GeocodeClient / Nominatim) and fly there.
## - Click the ground: a card with the coordinates, the place name (reverse
##   geocode, through SitePrivacy), the solar zone and its kWh/m²/day (the
##   picker's own GhiService numbers), and "Create world here"
##   (WorldLauncher.create_world_at: the same path as the picker).
## - Every saved world is a pin; click one to Play it.
## - Layers: solar zones (bands / smooth), city lights, and the weather
##   (GlobeWeather): live clouds (the last few hours), rain (IMERG, since
##   1998) and the satellite image of the day (MODIS, since 2000), all at the
##   globe's time. A strip scrubs a year either side of now (the sim clock
##   in-game, the wall clock on the hub) without moving the world's clock.
##   Play runs that strip. Sun, moon and planet paths match the first-person
##   analemma. Earth / Moon swaps which body the view orbits; the Moon stands
##   at its true distance, so from the Earth it is the small disc it really
##   is, and from the Moon the Earth hangs over the horizon.
## - In-game it opens on the running world's site, marked "You are here".
## - Zooming down near a world draws that world's own cached terrain photos
##   over the globe's tiles (GlobeDrape), and Play / Create world here "fly
##   in" first: down to the site, leaning toward the horizon, then launch.
## - In-game: the Sphere of Influence ring and the map's square on the
##   ground; a click on "You are here" compares the sim's weather with GFS.
## Esc or the close button leaves; the mode is a CursorController modal.

signal closed

const MODAL_NAME := "globe_mode"
const PIN_PICK_PX := 18.0
const PANEL_W := 340.0
const GHI := preload("res://scenes/ui/location_picker/ghi_service.gd")
## "Colour by" choices.
const COLOUR_NONE := 0
const COLOUR_ZONES := 1
const COLOUR_TEMP := 2
const COLOUR_POWER := 3
const COLOUR_ATLAS := 4
const COLOUR_IRRADIANCE := 5
## The time strip, hours either side of now. A year, plus a day for the leap.
const TIME_SPAN_H := 366.0 * 24.0
const _PLAY_SPEEDS := [0.0, 1.0, 24.0, 168.0]
const _PLAY_LABELS := ["Play", "1 h/s", "1 d/s", "7 d/s"]
## 2 m air temperature, °C: edges every 12 °C, blue to red.
const TEMP_COLORS := [Color("#2c3e9e"), Color("#4f9bd9"), Color("#bfe6f2"), Color("#f7e08b"),
	Color("#f39a4b"), Color("#c8303b")]
const TEMP_STEPS := [-24.0, -12.0, 0.0, 12.0, 24.0]
## Wind power at 100 m, W/m² (GlobeWindField.power_density).
const POWER_COLORS := [Color("#203a6b"), Color("#2a8c8c"), Color("#5cb85c"), Color("#f0d24a"),
	Color("#f08c3c"), Color("#c9302c")]
const POWER_STEPS := [50.0, 150.0, 300.0, 600.0, 1000.0]

var globe: GlobeView
var _geocode: GeocodeClient
var _search: LineEdit
var _hits: ItemList
var _hit_rows: Array = []
var _search_note: Label
var _card: PanelContainer
var _card_title: Label
var _card_coords: Label
var _card_place: Label
var _card_zone: Label
var _card_zone_chip: PanelContainer
var _card_world_note: Label
var _name_edit: LineEdit
var _create_btn: Button
var _play_btn: Button
var _fly_btn: Button
var _status: Label
var _hover: Label
var _colour_by: OptionButton
var _colour := COLOUR_ZONES
var _wind_toggle: CheckBox
var _wind_info: Dictionary = {}
var _temp_tex: Texture2D
var _power_tex: Texture2D
var _zones_mode: OptionButton
var _lights_toggle: CheckBox
var _labels_toggle: CheckBox
var _legend: HBoxContainer
var _weather: GlobeWeather
var _atlas: GlobeSolarAtlas
var _climate: GlobeClimate
var _clim_key := ""
var _clim_info: Dictionary = {}
var _card_layer: Label
var _zone_row: Control
var _card_atlas: Label
var _atlas_key := ""
var _atlas_info: Dictionary = {}
var _clouds_toggle: CheckBox
var _rain_toggle: CheckBox
var _sat_toggle: CheckBox
var _aurora_toggle: CheckBox
var _aur: Dictionary = {}
var _time_slider: HSlider
var _time_lbl: Label
var _data_lbl: Label
var _in_game := false
var _time_offset_h := 0.0
var _sim_jd: Callable
var _play_h_per_s := 0.0
var _play_btn_time: Button
var _time_dragging := false
var _body_earth: Button
var _body_moon: Button
var _home_btn: Button
var _now_btn: Button
var _search_go: Button
var _time_bar: PanelContainer
var _sun_lbl: Label
var _path_sun: CheckBox
var _path_moon: CheckBox
var _path_planets: CheckBox
var _colour_before_moon := COLOUR_ZONES
var _wx_key := ""
var _wx_poll := 0.0
var _wx_text := {"clouds": "", "rain": "", "sat": "", "wind": "", "aurora": ""}

var _sel := PackedFloat64Array()
var _sel_label := ""
var _sel_world: Dictionary = {}
var _worlds: Array[Dictionary] = []
var _here := PackedFloat64Array()
var _overlay_tex: Texture2D
var _overlay_task := -1
var _closing := false
var _site_info: Dictionary = {}
var _drape_files := PackedStringArray()
var _drape_world := ""
var _drape_task := -1
var _fly_then := Callable()
var _fly_wait := 0.0
var _here_selected := false
## Drapes show below this camera altitude (km) and clear above DRAPE_CLEAR_KM.
const DRAPE_SHOW_KM := 120.0
const DRAPE_CLEAR_KM := 180.0
const DRAPE_NEAR_KM := 40.0


## Opens Globe mode over `parent` (the hub control or Main's UI). In-game,
## `site` is the running world's [lat, lon]; `time_provider` the sim clock.
static func open(parent: Node, site: PackedFloat64Array = PackedFloat64Array(),
		time_provider: Callable = Callable(), site_info: Dictionary = {}) -> GlobeMode:
	var layer := CanvasLayer.new()
	layer.name = "GlobeModeLayer"
	layer.layer = UITheme.LAYER_MODAL
	parent.add_child(layer)
	var gm := GlobeMode.new()
	gm._here = site
	gm._site_info = site_info
	gm._sim_jd = time_provider
	gm._in_game = time_provider.is_valid()
	gm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(gm)
	return gm


func _ready() -> void:
	set_meta("ui_modal", true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	globe = GlobeView.new()
	globe.name = "GlobeView"
	globe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(globe)
	globe.point_clicked.connect(_on_point_clicked)
	globe.point_hovered.connect(_on_point_hovered)
	globe.companion_clicked.connect(_on_companion_clicked)
	globe.body_changed.connect(_on_body_changed)
	globe.time_provider = Callable(self, "_jd_now")
	_geocode = GeocodeClient.new()
	_geocode.name = "Geocode"
	add_child(_geocode)
	_geocode.search_done.connect(_on_search_done)
	_geocode.search_failed.connect(func(m: String) -> void: _show_search_note(m))
	_geocode.reverse_done.connect(_on_reverse_done)
	_weather = GlobeWeather.new()
	_weather.name = "Weather"
	add_child(_weather)
	_weather.clouds_ready.connect(_on_clouds_ready)
	_weather.rain_ready.connect(_on_rain_ready)
	_weather.wind_ready.connect(_on_wind_ready)
	_atlas = GlobeSolarAtlas.new()
	_atlas.name = "SolarAtlas"
	add_child(_atlas)
	_atlas.point_ready.connect(_on_atlas_point)
	_climate = GlobeClimate.new()
	_climate.name = "Climate"
	add_child(_climate)
	_climate.point_ready.connect(_on_climate_point)
	_build_top_bar()
	_build_card()
	_build_bottom()
	_load_worlds()
	_drape_files = DirAccess.get_files_at(GlobeDrape.CACHE_DIR) if DirAccess.dir_exists_absolute(GlobeDrape.CACHE_DIR) else PackedStringArray()
	_draw_site_outlines()
	if _here.size() == 2:
		globe.set_marker("here", _here[0], _here[1], Color(0.35, 1.0, 0.55), "You are here")
		globe.look_at_point(_here[0], _here[1], 2.4)
		globe.fly_to(_here[0], _here[1], 0.05, 2.0)
	elif not _worlds.is_empty():
		var ll := WorldLauncher.world_latlon(_worlds[0])
		globe.look_at_point(ll[0], ll[1], 2.6)
	else:
		globe.look_at_point(25.0, -30.0, 2.8)
	_set_colour(COLOUR_ZONES)
	var cc := get_node_or_null("/root/CursorController")
	if cc != null:
		cc.call("request_modal", MODAL_NAME, Callable(self, "close"))
	HudLayout.claim_modal(MODAL_NAME)
	globe.grab_focus()


func _exit_tree() -> void:
	if _drape_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_drape_task)
		_drape_task = -1
	if _overlay_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_overlay_task)
		_overlay_task = -1


func close() -> void:
	if _closing:
		return
	_closing = true
	var cc := get_node_or_null("/root/CursorController")
	if cc != null:
		cc.call("release_modal", MODAL_NAME)
	HudLayout.release(MODAL_NAME)
	closed.emit()
	var layer := get_parent()
	if layer is CanvasLayer:
		layer.queue_free()
	else:
		queue_free()


func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.physical_keycode == KEY_ESCAPE:
		if _hits.visible:
			_hits.visible = false
		elif _card.visible:
			_card.visible = false
			globe.remove_marker("sel")
		else:
			close()
		get_viewport().set_input_as_handled()
	elif k.physical_keycode == KEY_SPACE:
		_cycle_play()
		get_viewport().set_input_as_handled()
	elif k.physical_keycode == KEY_HOME:
		_go_home()
		get_viewport().set_input_as_handled()


# --- UI ---------------------------------------------------------------------

func _glass() -> StyleBoxFlat:
	var sb := UITheme.panel_style(0.86)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "TopBar"
	bar.add_theme_stylebox_override("panel", _glass())
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	bar.offset_left = 16
	bar.offset_top = 16
	add_child(bar)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	bar.add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	var title := Label.new()
	title.text = "Globe"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(title)
	var bodies := ButtonGroup.new()
	_body_earth = _body_button("BodyEarth", "Earth", bodies,
		"Orbit the Earth. The Moon hangs where it really is; click it to go there.")
	_body_earth.button_pressed = true
	_body_earth.pressed.connect(func() -> void: globe.set_primary_body("earth"))
	row.add_child(_body_earth)
	_body_moon = _body_button("BodyMoon", "Moon", bodies,
		"Orbit the Moon: an Earthrise over its eastern limb, the sunlight map, the subsolar track.")
	_body_moon.pressed.connect(func() -> void: globe.set_primary_body("moon"))
	row.add_child(_body_moon)
	row.add_child(VSeparator.new())
	_home_btn = IconButton.make("house", "Back to where you are (Home)", _go_home)
	_home_btn.name = "HomeButton"
	_home_btn.visible = _here.size() == 2 or not WorldStore.list().is_empty()
	row.add_child(_home_btn)
	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Search a place or address…"
	_search.custom_minimum_size = Vector2(300, 0)
	_search.text_submitted.connect(func(t: String) -> void: _do_search(t))
	row.add_child(_search)
	var go := IconButton.make("search", "Search", func() -> void: _do_search(_search.text))
	_search_go = go
	row.add_child(go)
	_hits = ItemList.new()
	_hits.name = "SearchHits"
	_hits.visible = false
	_hits.custom_minimum_size = Vector2(380, 150)
	_hits.item_activated.connect(_on_hit_chosen)
	_hits.item_clicked.connect(func(i: int, _p: Vector2, _b: int) -> void: _on_hit_chosen(i))
	col.add_child(_hits)
	_search_note = Label.new()
	_search_note.visible = false
	_search_note.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_search_note.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	col.add_child(_search_note)
	var close_btn := IconButton.close(close)
	close_btn.name = "CloseButton"
	close_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	close_btn.offset_right = -16
	close_btn.offset_left = -16
	close_btn.offset_top = 16
	add_child(close_btn)


## One half of the Earth / Moon switch.
static func _body_button(nm: String, text: String, group: ButtonGroup, tip: String) -> Button:
	var b := Button.new()
	b.name = nm
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(66, 0)
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	var on := StyleBoxFlat.new()
	on.bg_color = Color(UITheme.C_PRIMARY, 0.22)
	on.border_color = Color(UITheme.C_PRIMARY, 0.8)
	on.set_border_width_all(1)
	on.set_corner_radius_all(UITheme.CORNER_RADIUS)
	on.set_content_margin_all(6)
	on.content_margin_left = 10
	on.content_margin_right = 10
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_color_override("font_pressed_color", UITheme.C_TEXT)
	return b


## Fly back to the running world (in-game) or the newest world (the hub).
func _go_home() -> void:
	if globe.primary_body() != "earth":
		globe.set_primary_body("earth")
	if _here.size() == 2:
		globe.fly_to(_here[0], _here[1], 0.05)
	elif not _worlds.is_empty():
		var ll := WorldLauncher.world_latlon(_worlds[0])
		globe.fly_to(ll[0], ll[1], 0.05)


func _build_card() -> void:
	_card = PanelContainer.new()
	_card.name = "PointCard"
	_card.visible = false
	_card.add_theme_stylebox_override("panel", _glass())
	_card.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_card.custom_minimum_size = Vector2(PANEL_W, 0)
	_card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_card.offset_right = -16
	_card.offset_left = -16 - PANEL_W
	_card.offset_top = 64
	add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_card.add_child(col)
	_card_title = _label(col, UITheme.FONT_LG, UITheme.C_TEXT)
	_card_place = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_S)
	_card_coords = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_M)
	var zrow := HBoxContainer.new()
	zrow.add_theme_constant_override("separation", 8)
	col.add_child(zrow)
	_zone_row = zrow
	_card_zone_chip = PanelContainer.new()
	_card_zone_chip.custom_minimum_size = Vector2(14, 14)
	_card_zone_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	zrow.add_child(_card_zone_chip)
	_card_zone = _label(zrow, UITheme.FONT_MD, UITheme.C_TEXT)
	_card_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_layer = _label(col, UITheme.FONT_SM, UITheme.C_TEXT)
	_card_layer.name = "LayerLines"
	_card_atlas = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_S)
	_card_atlas.name = "AtlasLine"
	_card_world_note = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_S)
	col.add_child(HSeparator.new())
	_name_edit = LineEdit.new()
	_name_edit.name = "WorldName"
	_name_edit.placeholder_text = "World name"
	col.add_child(_name_edit)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	col.add_child(btns)
	_fly_btn = Button.new()
	_fly_btn.text = "Fly here"
	_fly_btn.tooltip_text = "Zoom down to this spot."
	UITheme.style_button(_fly_btn)
	_fly_btn.pressed.connect(func() -> void:
		if _sel.size() == 2:
			globe.fly_to(_sel[0], _sel[1], 0.004 if globe.primary_body() == "earth" else 0.08))
	btns.add_child(_fly_btn)
	_create_btn = Button.new()
	_create_btn.name = "CreateWorldButton"
	_create_btn.text = "Create world here"
	_create_btn.tooltip_text = "Start a new world on a map of this place (terrain, imagery, buildings and weather are fetched for it)."
	UITheme.style_button(_create_btn)
	_create_btn.pressed.connect(_on_create)
	btns.add_child(_create_btn)
	_play_btn = Button.new()
	_play_btn.name = "PlayWorldButton"
	_play_btn.text = "Play"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play)
	btns.add_child(_play_btn)
	_status = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_S)


func _build_bottom() -> void:
	var bar := PanelContainer.new()
	bar.name = "LayerBar"
	bar.add_theme_stylebox_override("panel", _glass())
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.offset_left = 16
	bar.offset_bottom = -16
	bar.offset_top = -16
	add_child(bar)
	bar.resized.connect(func() -> void: globe.set_credits_left(bar.position.x + bar.size.x + 16.0))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	bar.add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	_section_label(row, "Colour by")
	_colour_by = OptionButton.new()
	_colour_by.name = "ColourBy"
	_colour_by.add_item("Nothing", COLOUR_NONE)
	_colour_by.add_item("Solar zones", COLOUR_ZONES)
	_colour_by.add_item("Temperature", COLOUR_TEMP)
	_colour_by.add_item("Wind power", COLOUR_POWER)
	if GlobeSolarAtlas.layer() != null:
		_colour_by.add_item("Solar atlas (PV output)", COLOUR_ATLAS)
	_colour_by.selected = COLOUR_ZONES
	_colour_by.tooltip_text = "Solar zones: mean daily sunshine on flat ground (GHI), NASA POWER 2001-2020, the map picker's zones.\nTemperature: air at 2 m, NOAA GFS at the globe's time.\nWind power: the power in the wind at 100 m (from GFS 10 m wind, open land), a snapshot not a climate.\nOn the Moon: sunlight in W/m² (clear sky, no air).\nA layer fades out as you come down to where the photo says more."
	_colour_by.item_selected.connect(func(i: int) -> void: _set_colour(_colour_by.get_item_id(i)))
	row.add_child(_colour_by)
	_zones_mode = OptionButton.new()
	_zones_mode.name = "ZonesMode"
	_zones_mode.add_item("Bands", 0)
	_zones_mode.add_item("Smooth", 1)
	_zones_mode.item_selected.connect(func(_i: int) -> void: _restyle_zones())
	row.add_child(_zones_mode)
	_legend = HBoxContainer.new()
	_legend.name = "Legend"
	_legend.add_theme_constant_override("separation", 6)
	col.add_child(_legend)
	var wrow := HBoxContainer.new()
	wrow.add_theme_constant_override("separation", 10)
	col.add_child(wrow)
	_section_label(wrow, "Weather")
	_wind_toggle = _layer_check(wrow, "WindToggle", "Wind", true,
		"Wind at 10 m as moving streamlines (NOAA GFS 1°, runs every 6 h since 2021), coloured by speed.")
	_clouds_toggle = _layer_check(wrow, "CloudsToggle", "Clouds", true,
		"Cloud tops from geostationary weather satellites (NOAA nowCOAST infrared mosaic, hourly). Only the last few hours are served.")
	_rain_toggle = _layer_check(wrow, "RainToggle", "Rain", false,
		"Rain and snow rate from NASA GPM IMERG, every 30 minutes since 1998, about 5 hours behind real time.")
	_sat_toggle = _layer_check(wrow, "SatelliteToggle", "Satellite", false,
		"The whole Earth as one satellite saw it that day (NASA MODIS Terra true colour, since 2000), clouds and all.")
	_aurora_toggle = _layer_check(wrow, "AuroraToggle", "Aurora", _pref("aurora", true),
		"The northern and southern lights at the globe's time: curtains along the field lines from 100 to 400 km. NOAA's OVATION nowcast near the present, else the oval for that time's Kp (NOAA SWPC, GFZ Potsdam).")
	_aurora_toggle.toggled.connect(func(on: bool) -> void: _set_pref("aurora", on))
	var prow := HBoxContainer.new()
	prow.name = "PathRow"
	prow.add_theme_constant_override("separation", 10)
	col.add_child(prow)
	_section_label(prow, "Sky")
	_lights_toggle = _layer_check(prow, "LightsToggle", "City lights", true,
		"The night side's lights as points (NASA Black Marble): a glow from orbit, towns and roads as you come down.")
	_lights_toggle.toggled.connect(func(on: bool) -> void: globe.set_night_lights(on))
	_path_sun = _layer_check(prow, "PathSun", "Sun", _pref("path_sun", false),
		"The Sun's year: its analemma in the sky of the place you are over (at this time of day), today's Sun on it, and the subsolar track on the ground. On the Moon, the subsolar point and its track.")
	_path_moon = _layer_check(prow, "PathMoon", "Moon", _pref("path_moon", false),
		"The Moon's path over one month, at its true distance, and where it stands overhead.")
	_path_planets = _layer_check(prow, "PathPlanets", "Planets", _pref("path_planets", false),
		"Mercury to Saturn: a year of each among the stars, and where each is today.")
	_labels_toggle = CheckBox.new()
	_labels_toggle.name = "LabelsToggle"
	_labels_toggle.text = "Labels"
	_labels_toggle.tooltip_text = "Names on your worlds' pins"
	_labels_toggle.button_pressed = _pref("labels", true)
	globe.labels_on = _labels_toggle.button_pressed
	_labels_toggle.toggled.connect(func(on: bool) -> void:
		globe.labels_on = on
		_set_pref("labels", on))
	prow.add_child(_labels_toggle)
	_path_sun.toggled.connect(func(on: bool) -> void: _sync_paths(on))
	_path_moon.toggled.connect(func(on: bool) -> void: _sync_paths(on))
	_path_planets.toggled.connect(func(on: bool) -> void: _sync_paths(on))
	globe.set_paths(_path_sun.button_pressed, _path_moon.button_pressed, _path_planets.button_pressed)
	var sw := get_node_or_null("/root/SpaceWeather")
	if sw != null:
		sw.updated.connect(func() -> void:
			if not _closing:
				_wx_key = ""
				_wx_poll = 0.0)
	_data_lbl = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_M)
	_data_lbl.name = "DataTimes"
	_hover = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_S)
	_hover.name = "HoverReadout"
	_hover.text = HINT
	_build_time_bar()


const HINT := "Drag to turn · wheel to zoom · right-drag to tilt · click a place · Space plays the year"

## The time strip: bottom right, above the credits. A year either side of
## now, Play through it, Now to come back.
func _build_time_bar() -> void:
	_time_bar = PanelContainer.new()
	_time_bar.name = "TimeBar"
	_time_bar.add_theme_stylebox_override("panel", _glass())
	_time_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_time_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_time_bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_time_bar.offset_right = -16
	_time_bar.offset_left = -16
	_time_bar.offset_bottom = -36
	_time_bar.offset_top = -36
	add_child(_time_bar)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_time_bar.add_child(col)
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 6)
	col.add_child(trow)
	_now_btn = Button.new()
	_now_btn.name = "TimeNow"
	_now_btn.text = "Now"
	_now_btn.tooltip_text = "Back to the present (the sim clock in-game)."
	_now_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_now_btn)
	_now_btn.pressed.connect(func() -> void:
		_set_play(0.0)
		set_time_offset_h(0.0))
	trow.add_child(_now_btn)
	var back := IconButton.make("rewind", "A day back", func() -> void: set_time_offset_h(_time_offset_h - 24.0))
	trow.add_child(back)
	_time_slider = HSlider.new()
	_time_slider.name = "TimeSlider"
	_time_slider.min_value = -TIME_SPAN_H
	_time_slider.max_value = TIME_SPAN_H
	_time_slider.step = 0.5
	_time_slider.value = 0.0
	_time_slider.custom_minimum_size = Vector2(300, 0)
	_time_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_time_slider.focus_mode = Control.FOCUS_NONE
	_time_slider.tooltip_text = "A year either side of now. The Sun, the Moon, the stars and the paths follow. Clouds, rain and wind only where those records exist."
	_time_slider.value_changed.connect(func(v: float) -> void:
		_time_offset_h = v
		_wx_poll = 0.0
		globe.refresh_sun()
		_time_lbl.text = _time_text(globe_unix()))
	_time_slider.drag_started.connect(func() -> void:
		_time_dragging = true
		globe.sun_continuous = true)
	_time_slider.drag_ended.connect(func(_changed: bool) -> void:
		_time_dragging = false
		globe.sun_continuous = _play_h_per_s != 0.0)
	trow.add_child(_time_slider)
	var fwd := IconButton.make("fast-forward", "A day on", func() -> void: set_time_offset_h(_time_offset_h + 24.0))
	trow.add_child(fwd)
	_play_btn_time = IconButton.make("play", "Play the year: 1 hour, 1 day, then 7 days per second. Click again to pause (Space).", _cycle_play, "Play")
	_play_btn_time.name = "TimePlay"
	_play_btn_time.custom_minimum_size = Vector2(84, 0)
	trow.add_child(_play_btn_time)
	_time_lbl = _label(col, UITheme.FONT_SM, UITheme.C_TEXT)
	_time_lbl.name = "TimeLabel"
	_time_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	_time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sun_lbl = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_M)
	_sun_lbl.name = "SunLine"
	_sun_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	_sun_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _section_label(parent: Node, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	l.custom_minimum_size = Vector2(58, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(l)
	return l


func _layer_check(parent: Node, nm: String, text: String, on: bool, tip: String) -> CheckBox:
	var c := CheckBox.new()
	c.name = nm
	c.text = text
	c.tooltip_text = tip
	c.button_pressed = on
	c.toggled.connect(func(_on: bool) -> void:
		_wx_key = ""
		_wx_poll = 0.0
		_refresh_layer_lines())
	parent.add_child(c)
	return c


func _label(parent: Node, fs: int, c: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", c)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(0, 0)
	parent.add_child(l)
	return l


# --- Layers -----------------------------------------------------------------

func _set_colour(mode: int) -> void:
	_colour = mode
	_zones_mode.disabled = mode == COLOUR_NONE
	_zones_mode.visible = mode != COLOUR_IRRADIANCE
	_build_legend()
	_refresh_layer_lines()
	if _data_lbl != null:
		_show_data_times()
	_wx_key = ""
	_wx_poll = 0.0
	if mode == COLOUR_NONE:
		globe.clear_overlay()
		return
	if mode == COLOUR_ZONES and _overlay_tex == null:
		globe.clear_overlay()
		var ghi := get_node_or_null("/root/GhiService")
		if ghi == null:
			return
		_hover.text = "Preparing the solar zones…"
		_overlay_task = GlobeGhiOverlay.build_async(ghi, func(tex: Texture2D) -> void:
			if _closing or not is_instance_valid(self):
				return
			_overlay_tex = tex
			_hover.text = HINT
			if _colour == COLOUR_ZONES:
				_apply_colour())
		return
	_apply_colour()


## Puts the chosen colour layer on the globe (or clears it until its data
## is in: temperature and wind power come with the GFS run).
func _apply_colour() -> void:
	if _colour != COLOUR_IRRADIANCE:
		globe.set_moon_irradiance(false)
	var m := _zones_mode.selected
	match _colour:
		COLOUR_ZONES:
			if _overlay_tex != null:
				globe.set_overlay(_overlay_tex, GlobeGhiOverlay.colors(), GlobeGhiOverlay.steps(),
					GlobeGhiOverlay.MAX_GHI, m, 0.55)
		COLOUR_TEMP:
			if _temp_tex != null:
				globe.set_overlay(_temp_tex, TEMP_COLORS, TEMP_STEPS, 100.0, m, 0.6, -50.0, -30.0, 12.0)
			else:
				globe.clear_overlay()
		COLOUR_POWER:
			if _power_tex != null:
				globe.set_overlay(_power_tex, POWER_COLORS, POWER_STEPS, 1500.0, m, 0.6, 0.0, 0.0, 250.0)
			else:
				globe.clear_overlay()
		COLOUR_ATLAS:
			globe.set_overlay(GlobeSolarAtlas.layer(), GlobeSolarAtlas.COLORS, GlobeSolarAtlas.STEPS,
				GlobeSolarAtlas.MAX_PVOUT, m, 0.6, 0.0, GlobeSolarAtlas.RAMP_LO, GlobeSolarAtlas.RAMP_STEP,
				GlobeSolarAtlas.FADE_FAR)
		COLOUR_IRRADIANCE:
			globe.clear_overlay()
			globe.set_moon_irradiance(true)
		_:
			globe.clear_overlay()
			globe.set_moon_irradiance(false)


func _restyle_zones() -> void:
	globe.set_overlay_style(_zones_mode.selected, 0.55 if _colour == COLOUR_ZONES else 0.6)


func _build_legend() -> void:
	for c in _legend.get_children():
		_legend.remove_child(c)
		c.queue_free()
	var colors: Array = []
	var labels: Array = []
	var unit := ""
	match _colour:
		COLOUR_ZONES:
			for z in GHI.ZONES:
				var hi := float(z.range_hi)
				colors.append(z.color)
				labels.append("%s · %s" % [str(z.label), ("< %d" % int(hi)) if float(z.range_lo) <= 0.0 \
					else (("%d+" % int(z.range_lo)) if is_inf(hi) else "%d–%d" % [int(z.range_lo), int(hi)])])
			unit = "kWh/m²/day"
		COLOUR_TEMP:
			colors = TEMP_COLORS
			labels = _step_labels(TEMP_STEPS)
			unit = "°C at 2 m"
		COLOUR_POWER:
			colors = POWER_COLORS
			labels = _step_labels(POWER_STEPS)
			unit = "W/m² at 100 m"
		COLOUR_ATLAS:
			colors = GlobeSolarAtlas.COLORS
			labels = _step_labels(GlobeSolarAtlas.STEPS)
			unit = "kWh/kWp/day from PV"
		COLOUR_IRRADIANCE:
			for w in [0.0, 200.0, 400.0, 600.0, 800.0, 1000.0, 1200.0, 1361.0]:
				colors.append(irradiance_color(w))
				labels.append("%d" % int(w))
			unit = "W/m² of sunlight, no air (1361 at the subsolar point)"
	_legend.visible = not colors.is_empty()
	for i in colors.size():
		var chip := PanelContainer.new()
		var csb := StyleBoxFlat.new()
		csb.bg_color = colors[i]
		csb.set_corner_radius_all(6)
		csb.content_margin_left = 6
		csb.content_margin_right = 6
		csb.content_margin_top = 1
		csb.content_margin_bottom = 1
		chip.add_theme_stylebox_override("panel", csb)
		var l := Label.new()
		l.text = str(labels[i])
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", Color(0.05, 0.05, 0.08) if Color(colors[i]).get_luminance() > 0.5 else Color.WHITE)
		chip.add_child(l)
		_legend.add_child(chip)
	var ul := Label.new()
	ul.text = unit
	ul.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	ul.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_legend.add_child(ul)


## The Moon shader's irradiance ramp (globe_moon.gdshader irr_color), mirrored.
static func irradiance_color(w: float) -> Color:
	var e := clampf(w / 1361.0, 0.0, 1.0)
	var c := Color(0.03, 0.06, 0.16).lerp(Color(0.30, 0.55, 0.92), smoothstep(0.0, 0.3, e))
	c = c.lerp(Color(0.96, 0.95, 0.88), smoothstep(0.3, 0.72, e))
	c = c.lerp(Color(1.0, 0.80, 0.25), smoothstep(0.72, 1.0, e))
	return c


static func _step_labels(steps: Array) -> Array:
	var out: Array = ["< %s" % _num(steps[0])]
	for i in steps.size() - 1:
		out.append("%s–%s" % [_num(steps[i]), _num(steps[i + 1])])
	out.append("%s+" % _num(steps[-1]))
	return out


## 12 → "12", 3.25 → "3.25", 2.5 → "2.5".
static func _num(v: float) -> String:
	if is_equal_approx(v, roundf(v)):
		return "%d" % roundi(v)
	return ("%.2f" % v).rstrip("0")


## [ghi, zone dict] at a point, from the picker's own service.
func _zone_at(lat: float, lon: float) -> Array:
	var ghi := get_node_or_null("/root/GhiService")
	if ghi == null:
		return [NAN, {}]
	var g := float(ghi.call("ghi_kwh_per_m2_day", lat, lon))
	return [g, ghi.call("get_zone", g)]


# --- Worlds -----------------------------------------------------------------

func _load_worlds() -> void:
	_worlds.clear()
	var i := 0
	for rec in WorldStore.list():
		var ll := WorldLauncher.world_latlon(rec)
		if ll.size() != 2:
			continue
		_worlds.append(rec)
		globe.set_marker("world_%d" % i, ll[0], ll[1], Color(1.0, 0.78, 0.25), short_name(world_title(rec)))
		i += 1


## A world's name; a name that is just the site's address goes through
## SitePrivacy like every other place label.
static func world_title(rec: Dictionary) -> String:
	var n := WorldStore.display_name(rec)
	var map: Variant = rec.get("map", {})
	var label := str((map as Dictionary).get("label", "")) if map is Dictionary else ""
	if n == label or n.is_empty():
		return SitePrivacy.place(n, "A world")
	return n


## What a pin says: a world named after its address gets the place's name
## ("1234 Fir Road, Mount Vernon, Skagit County, …" → "Mount Vernon"), any
## name is cut to PIN_NAME_MAX. The card keeps the whole name.
const PIN_NAME_MAX := 22
const _ROAD_WORDS := ["road", "rd", "street", "st", "avenue", "ave", "lane", "ln", "drive", "dr",
	"way", "highway", "hwy", "boulevard", "blvd", "court", "ct", "place", "pl", "trail", "loop",
	"circle", "parkway", "pkwy", "terrace", "route"]

static func short_name(text: String) -> String:
	var t := text.strip_edges()
	if t.contains(","):
		var keep: Array[String] = []
		for raw in t.split(","):
			var p := raw.strip_edges()
			if p.is_empty() or _has_digit(p):
				continue
			keep.append(p)
		while keep.size() > 1 and _is_road(keep[0]):
			keep.remove_at(0)
		if not keep.is_empty():
			t = keep[0]
	if t.length() > PIN_NAME_MAX:
		t = t.left(PIN_NAME_MAX - 1).strip_edges() + "…"
	return t


static func _has_digit(s: String) -> bool:
	for c in s:
		if c >= "0" and c <= "9":
			return true
	return false


static func _is_road(s: String) -> bool:
	var w := s.to_lower().split(" ", false)
	return not w.is_empty() and w[w.size() - 1].trim_suffix(".") in _ROAD_WORDS


## Globe-mode preferences (ui_prefs.cfg [globe]).
static func _pref(key: String, def: Variant) -> Variant:
	var cf := ConfigFile.new()
	if cf.load("user://ui_prefs.cfg") != OK:
		return def
	return cf.get_value("globe", key, def)


static func _set_pref(key: String, v: Variant) -> void:
	var cf := ConfigFile.new()
	cf.load("user://ui_prefs.cfg")
	cf.set_value("globe", key, v)
	cf.save("user://ui_prefs.cfg")


func world_count() -> int:
	return _worlds.size()


func _world_near(local_pos: Vector2) -> Dictionary:
	var best := {}
	var best_d := PIN_PICK_PX
	for rec in _worlds:
		var ll := WorldLauncher.world_latlon(rec)
		var sp := globe.latlon_to_local(ll[0], ll[1])
		if sp == Vector2.INF:
			continue
		var d := sp.distance_to(local_pos)
		if d < best_d:
			best_d = d
			best = rec
	return best


# --- Selection --------------------------------------------------------------

func _on_companion_clicked() -> void:
	globe.set_primary_body("moon" if globe.primary_body() == "earth" else "earth")


func _on_body_changed(body: String) -> void:
	var moon := body == "moon"
	if _body_earth != null:
		_body_earth.set_pressed_no_signal(not moon)
		_body_moon.set_pressed_no_signal(moon)
	_search.visible = not moon
	if _search_go != null:
		_search_go.visible = not moon
	_hits.visible = false
	_card.visible = false
	globe.remove_marker("sel")
	if moon:
		if _colour != COLOUR_IRRADIANCE:
			_colour_before_moon = _colour
		if _colour_by.get_item_index(COLOUR_IRRADIANCE) < 0:
			_colour_by.add_item("Sunlight on the Moon", COLOUR_IRRADIANCE)
		_colour_by.select(_colour_by.get_item_index(COLOUR_IRRADIANCE))
		_set_colour(COLOUR_IRRADIANCE)
		_hover.text = "The Moon, %s km away · drag to turn · wheel to zoom · click a point" % UiText.thousands(int(globe.moon_distance_km()))
	else:
		var idx := _colour_by.get_item_index(COLOUR_IRRADIANCE)
		if idx >= 0:
			_colour_by.remove_item(idx)
		var back := _colour_before_moon
		if _colour_by.get_item_index(back) < 0:
			back = COLOUR_ZONES
		_colour_by.select(_colour_by.get_item_index(back))
		_set_colour(back)
		_hover.text = HINT
	_wx_key = ""
	_wx_poll = 0.0


func _show_moon_point(lat: float, lon: float) -> void:
	var jd := globe.current_jd()
	var ph := MoonGlobe.phase(jd)
	_sel = PackedFloat64Array([lat, lon])
	_sel_world = {}
	_here_selected = false
	_card.visible = true
	_card_title.text = "On the Moon"
	_card_place.text = "Selenographic; the prime meridian faces the Earth. %s, %d %% lit, %.1f days old, %s km from Earth." % [
		str(ph.name), int(round(float(ph.lit) * 100.0)), float(ph.age_days), UiText.thousands(int(MoonGlobe.distance_km(jd)))]
	_card_coords.text = SitePrivacy.coords(lat, lon)
	var w := MoonGlobe.irradiance_at(lat, lon, jd)
	var elev := rad_to_deg(asin(clampf(GlobeMath.to_unit(lat, lon).dot(MoonGlobe.sun_body(jd)), -1.0, 1.0)))
	_card_zone_chip.visible = true
	_card_zone_chip.add_theme_stylebox_override("panel", UITheme.chip_style(irradiance_color(w)))
	_card_zone.text = "%.0f W/m² of sunlight here · Sun %s" % [w,
		("%.0f° up" % elev) if elev > 0.0 else "below the horizon (lunar night, about two weeks)"]
	_zone_row.visible = true
	_card_layer.text = ""
	_card_layer.visible = false
	_name_edit.visible = false
	_create_btn.visible = false
	_play_btn.visible = false
	_fly_btn.visible = true
	_card_world_note.text = "A lunar day is 29.5 Earth days: the sunlight map turns once a month."
	if _card_atlas != null:
		_card_atlas.text = ""
		_card_atlas.visible = false
	_status.text = ""


func _on_point_clicked(lat: float, lon: float) -> void:
	if globe.primary_body() == "moon":
		_show_moon_point(lat, lon)
		return
	var pos := globe.get_local_mouse_position()
	if _here.size() == 2:
		var hp := globe.latlon_to_local(_here[0], _here[1])
		if hp != Vector2.INF and hp.distance_to(pos) < PIN_PICK_PX:
			select_here()
			return
	var rec := _world_near(pos)
	if not rec.is_empty():
		select_world(rec)
		return
	select_point(lat, lon)


func select_point(lat: float, lon: float, label: String = "") -> void:
	_fly_btn.visible = true
	_card_atlas.visible = _colour == COLOUR_ATLAS or _colour == COLOUR_ZONES
	_sel = PackedFloat64Array([lat, lon])
	_sel_world = {}
	_here_selected = false
	_play_btn.text = "Fly in and play"
	_sel_label = label
	globe.set_marker("sel", lat, lon, Color(0.4, 0.85, 1.0))
	_card.visible = true
	_card_title.text = "New world here" if label.is_empty() else SitePrivacy.place(label)
	_card_place.text = "" if not label.is_empty() else "Looking up the place…"
	_card_coords.text = SitePrivacy.coords(lat, lon)
	_fill_zone(lat, lon)
	_card_world_note.text = _nearby_world_note(lat, lon)
	_name_edit.visible = true
	_name_edit.text = ""
	_name_edit.placeholder_text = "World name (default: the place)"
	_create_btn.visible = true
	_play_btn.visible = false
	_status.text = ""
	if label.is_empty():
		_geocode.reverse(lat, lon)


func select_world(rec: Dictionary) -> void:
	var ll := WorldLauncher.world_latlon(rec)
	_sel = ll
	_sel_world = rec
	_here_selected = false
	_play_btn.text = "Fly in and play"
	globe.remove_marker("sel")
	_card.visible = true
	_card_title.text = world_title(rec)
	var map: Variant = rec.get("map", {})
	_card_place.text = SitePrivacy.place(str((map as Dictionary).get("label", ""))) if map is Dictionary else ""
	_card_coords.text = SitePrivacy.coords(ll[0], ll[1])
	_fill_zone(ll[0], ll[1])
	_card_world_note.text = "One of your worlds."
	_name_edit.visible = false
	_create_btn.visible = false
	_play_btn.visible = true
	_status.text = ""


func _fill_zone(lat: float, lon: float) -> void:
	var zr := _zone_at(lat, lon)
	var z: Dictionary = zr[1]
	if z.is_empty() or is_nan(float(zr[0])):
		_card_zone.text = "Solar data unavailable"
		_card_zone_chip.visible = false
		_request_atlas(lat, lon)
		_request_climate(lat, lon)
		return
	_card_zone_chip.visible = true
	_card_zone_chip.add_theme_stylebox_override("panel", UITheme.chip_style(z.color))
	_card_zone.text = "%s · %.1f kWh/m²/day of sun" % [str(z.label), float(zr[0])]
	_request_atlas(lat, lon)
	_request_climate(lat, lon)


## The long-term averages at the selected point (NASA POWER), for the lines
## of the layers that are on.
func _request_climate(lat: float, lon: float) -> void:
	_clim_info = {}
	_clim_key = _climate.request_point(lat, lon)
	_refresh_layer_lines()


func _on_climate_point(key: String, info: Dictionary) -> void:
	if key != _clim_key or _closing:
		return
	_clim_info = info
	_refresh_layer_lines()
	_show_data_times()


## What GFS says at a point at the globe's time: {speed, dir, temp} or {}.
func gfs_at(lat: float, lon: float) -> Dictionary:
	if not _wind_info.has("u"):
		return {}
	var uu := Grib2Decoder.sample(_wind_info.u, lat, lon)
	var vv := Grib2Decoder.sample(_wind_info.v, lat, lon)
	return {"speed": sqrt(uu * uu + vv * vv), "dir": int(round(GlobeWindField.from_dir_deg(uu, vv))) % 360,
		"temp": Grib2Decoder.sample(_wind_info.t, lat, lon) - 273.15}


## The card follows the layers: the solar zone for Solar zones / nothing,
## the atlas line for the Solar atlas, temperature / wind lines (now from
## GFS, the average from NASA POWER) for those layers, and a line each for
## Wind, Rain and Clouds when they are on.
func _refresh_layer_lines() -> void:
	if _card_layer == null:
		return
	_zone_row.visible = _colour == COLOUR_ZONES or _colour == COLOUR_NONE
	_card_atlas.visible = _colour == COLOUR_ATLAS or _colour == COLOUR_ZONES
	if _sel.size() != 2:
		_card_layer.text = ""
		return
	var lat := _sel[0]
	var lon := _sel[1]
	var now := gfs_at(lat, lon)
	var waiting := _clim_info.is_empty()
	var lines := PackedStringArray()
	if _colour == COLOUR_TEMP:
		var s := "Temperature now %d °C (GFS)" % roundi(float(now.temp)) if not now.is_empty() else "Temperature"
		var a := GlobeClimate.temp_line(_clim_info)
		lines.append(s + (" · " + a if not a.is_empty() else (" · averages loading…" if waiting else "")))
	if _colour == COLOUR_POWER or _wind_toggle.button_pressed:
		var s := ("Wind now %.1f m/s from %d° (GFS)" % [float(now.speed), int(now.dir)]) if not now.is_empty() else "Wind"
		if _colour == COLOUR_POWER and not now.is_empty():
			s += ", ~%d W/m² at 100 m" % roundi(GlobeWindField.power_density(float(now.speed)))
		var a := GlobeClimate.wind_line(_clim_info)
		lines.append(s + (" · " + a if not a.is_empty() else (" · averages loading…" if waiting else "")))
	if _rain_toggle.button_pressed:
		var a := GlobeClimate.rain_line(_clim_info)
		if not a.is_empty():
			lines.append(a)
	if _clouds_toggle.button_pressed:
		var a := GlobeClimate.cloud_line(_clim_info)
		if not a.is_empty():
			lines.append(a)
	if _aurora_toggle.button_pressed:
		var a := aurora_text(lat, lon)
		if not a.is_empty():
			lines.append(a)
	if _clim_info.has("error") and lines.is_empty():
		lines.append(str(_clim_info.error))
	_card_layer.text = "\n".join(lines)
	_card_layer.visible = not lines.is_empty()


## What the card's layer lines say now (for checks).
func layer_text() -> String:
	return _card_layer.text if _card_layer.visible else ""


## The Global Solar Atlas numbers for the selected point (asked once per
## point; the reply fills the card's atlas line).
func _request_atlas(lat: float, lon: float) -> void:
	_atlas_info = {}
	_card_atlas.text = "Solar atlas: asking…"
	_atlas_key = _atlas.request_point(lat, lon)


func _on_atlas_point(key: String, info: Dictionary) -> void:
	if key != _atlas_key or _closing:
		return
	_atlas_info = info
	_card_atlas.text = str(info.error) if info.has("error") else GlobeSolarAtlas.card_text(info)
	_show_data_times()


## What the card's atlas line says now (for checks).
func atlas_text() -> String:
	return _card_atlas.text


func _nearby_world_note(lat: float, lon: float) -> String:
	var best := INF
	var name := ""
	for rec in _worlds:
		var ll := WorldLauncher.world_latlon(rec)
		var d := GlobeMath.great_circle_km(lat, lon, ll[0], ll[1])
		if d < best:
			best = d
			name = world_title(rec)
	if best <= 25.0:
		return "%.1f km from your world “%s”." % [best, name]
	return ""


func _on_reverse_done(lat: float, lng: float, label: String) -> void:
	if _sel.size() != 2 or not _sel_world.is_empty():
		return
	if absf(lat - _sel[0]) > 1e-6 or absf(lng - _sel[1]) > 1e-6:
		return
	_sel_label = label
	_card_place.text = SitePrivacy.place(label)


func _on_point_hovered(lat: float, lon: float, on_globe: bool) -> void:
	if globe.hovered_body != "":
		if globe.hovered_body == "moon":
			var ph := MoonGlobe.phase(globe.current_jd())
			_hover.text = "The Moon · %s km · %s, %d %% lit — click to go there" % [
				UiText.thousands(int(globe.moon_distance_km())), str(ph.name), int(round(float(ph.lit) * 100.0))]
		else:
			_hover.text = "The Earth · %s km — click to go back" % UiText.thousands(int(globe.moon_distance_km()))
		return
	if not on_globe:
		_hover.text = "Altitude %s" % _alt_text()
		return
	var zr := _zone_at(lat, lon)
	var ztxt := ""
	if not is_nan(float(zr[0])) and not (zr[1] as Dictionary).is_empty():
		ztxt = " · %.1f kWh/m²/day (%s)" % [float(zr[0]), str(zr[1].label)]
	if _colour == COLOUR_ATLAS:
		var pv := GlobeSolarAtlas.layer_value(lat, lon)
		if not is_nan(pv):
			ztxt += " · PV %.2f kWh/kWp/day" % pv
	if globe.primary_body() == "moon":
		ztxt = " · %.0f W/m²" % MoonGlobe.irradiance_at(lat, lon, globe.current_jd())
	_hover.text = "%s%s%s · altitude %s" % [_fmt_ll(lat, lon), ztxt, wind_text(lat, lon), _alt_text()]


## " · wind 5.2 m/s from 240° · 12 °C" from the loaded GFS run, or "".
func wind_text(lat: float, lon: float) -> String:
	if not _wind_info.has("u"):
		return ""
	var uu := Grib2Decoder.sample(_wind_info.u, lat, lon)
	var vv := Grib2Decoder.sample(_wind_info.v, lat, lon)
	var tc := Grib2Decoder.sample(_wind_info.t, lat, lon) - 273.15
	return " · wind %.1f m/s from %d° · %d °C" % [sqrt(uu * uu + vv * vv),
		int(round(GlobeWindField.from_dir_deg(uu, vv))) % 360, int(round(tc))]


func _alt_text() -> String:
	var km := globe.altitude_km()
	return "%.0f m" % (km * 1000.0) if km < 1.0 else ("%.1f km" % km if km < 100.0 else "%s km" % UiText.thousands(int(km)))


static func _fmt_ll(lat: float, lon: float) -> String:
	if SitePrivacy.redact:
		return SitePrivacy.COORDS_STAND_IN
	return "%.4f° %s, %.4f° %s" % [absf(lat), "N" if lat >= 0.0 else "S", absf(lon), "E" if lon >= 0.0 else "W"]


# --- Actions ----------------------------------------------------------------

func _on_create() -> void:
	if _sel.size() != 2:
		return
	var lat := _sel[0]
	var lon := _sel[1]
	var label := _sel_label if not _sel_label.is_empty() else "%.4f, %.4f" % [lat, lon]
	var nm := _name_edit.text.strip_edges()
	var prefer := not _sel_label.is_empty()
	fly_in(lat, lon, func() -> void:
		_status.text = "Creating the world…"
		var err := WorldLauncher.create_world_at(get_tree(), lat, lon, label, nm, {}, prefer)
		if err != OK:
			_status.text = "Could not create the world (error %d)." % err
			return
		close())


func _on_play() -> void:
	if _here_selected:
		fly_in(_here[0], _here[1], close)
		return
	if _sel_world.is_empty():
		return
	var rec := _sel_world
	var ll := WorldLauncher.world_latlon(rec)
	var is_here := _here.size() == 2 and ll.size() == 2 \
		and GlobeMath.great_circle_km(ll[0], ll[1], _here[0], _here[1]) < 0.05
	fly_in(ll[0], ll[1], func() -> void:
		if is_here:
			close()   # already in this world
			return
		var err := WorldLauncher.play(get_tree(), rec, {})
		if err != OK:
			_status.text = "Could not open that world (error %d)." % err
			return
		close())


## Flies down to a place (about 1.5 km up, leaning toward the horizon), then
## runs `then` once the flight has landed and the photos had a moment.
func fly_in(lat: float, lon: float, then: Callable) -> void:
	_status.text = "Flying in…"
	_fly_then = then
	_fly_wait = 0.8
	globe.fly_to(lat, lon, 0.00024, maxf(2.2, 1.2 + globe.altitude_km() / 4000.0), 58.0)


func is_flying_in() -> bool:
	return _fly_then.is_valid()


## "You are here": the world itself, its weather in the sim and the GFS's.
func select_here() -> void:
	_sel = _here
	_sel_world = {}
	_here_selected = true
	globe.remove_marker("sel")
	_card.visible = true
	_card_title.text = "This world"
	_card_place.text = ""
	_card_coords.text = SitePrivacy.coords(_here[0], _here[1])
	_fill_zone(_here[0], _here[1])
	_card_world_note.text = site_weather_text()
	_name_edit.visible = false
	_create_btn.visible = false
	_play_btn.visible = true
	_play_btn.text = "Back to the world"
	_status.text = ""


## The sim's weather here now beside the GFS's at this point.
func site_weather_text() -> String:
	var lines := PackedStringArray()
	var wcb: Variant = _site_info.get("weather")
	if wcb is Callable and (wcb as Callable).is_valid():
		var w: Dictionary = (wcb as Callable).call()
		if not w.is_empty():
			lines.append("In the sim now: %d °C, wind %.1f m/s" % [int(round(float(w.temp_c))), float(w.wind_ms)])
	if _wind_info.has("u") and _here.size() == 2:
		var uu := Grib2Decoder.sample(_wind_info.u, _here[0], _here[1])
		var vv := Grib2Decoder.sample(_wind_info.v, _here[0], _here[1])
		var tc := Grib2Decoder.sample(_wind_info.t, _here[0], _here[1]) - 273.15
		lines.append("GFS here: %d °C, wind %.1f m/s (%s)" % [int(round(tc)), sqrt(uu * uu + vv * vv), str(_wind_info.label)])
	if lines.is_empty():
		return "Weather here appears once the wind layer has loaded."
	return "\n".join(lines)


## In-game: the Sphere of Influence and the map's square on the ground.
func _draw_site_outlines() -> void:
	if _site_info.has("soi_lat") and float(_site_info.get("soi_r", 0.0)) > 0.0:
		globe.set_outline("soi", circle_points(float(_site_info.soi_lat), float(_site_info.soi_lon),
			float(_site_info.soi_r), 72), Color(0.35, 1.0, 0.55))
	if _here.size() == 2 and float(_site_info.get("map_half", 0.0)) > 0.0:
		globe.set_outline("map", square_points(_here[0], _here[1], float(_site_info.map_half)),
			Color(1.0, 1.0, 1.0, 0.8))


## A circle of `radius_m` round a point as [lat, lon, ...] (local tangent
## metres, GeoMath's meters_per_deg; fine up to tens of km).
static func circle_points(lat: float, lon: float, radius_m: float, n: int) -> PackedFloat64Array:
	var mpd := GeoMath.meters_per_deg(lat)
	var out := PackedFloat64Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(lat + cos(a) * radius_m / float(mpd.y))
		out.append(lon + sin(a) * radius_m / float(mpd.x))
	return out


static func square_points(lat: float, lon: float, half_m: float) -> PackedFloat64Array:
	var bb := GeoMath.bbox_for(lat, lon, half_m)
	return PackedFloat64Array([bb.north, bb.west, bb.north, bb.east, bb.south, bb.east, bb.south, bb.west])


# --- World drapes -------------------------------------------------------------

## Near a world (camera low, centre within DRAPE_NEAR_KM), its cached photos
## go on the globe; high up they come off again.
func _update_drapes() -> void:
	if _drape_task >= 0:
		return
	var alt := globe.altitude_km()
	if alt > DRAPE_CLEAR_KM:
		if not _drape_world.is_empty():
			_drape_world = ""
			globe.set_drape(0, null)
			globe.set_drape(1, null)
		return
	if alt > DRAPE_SHOW_KM:
		return
	var c := globe.center_latlon()
	var best := PackedFloat64Array()
	var best_d := DRAPE_NEAR_KM
	var sites: Array = []
	for rec in _worlds:
		sites.append(WorldLauncher.world_latlon(rec))
	if _here.size() == 2:
		sites.append(_here)
	for ll: PackedFloat64Array in sites:
		var d := GlobeMath.great_circle_km(c[0], c[1], ll[0], ll[1])
		if d < best_d:
			best_d = d
			best = ll
	if best.size() != 2:
		return
	var key := "%.4f,%.4f" % [best[0], best[1]]
	if key == _drape_world:
		return
	_drape_world = key
	var pick := GlobeDrape.pick(GlobeDrape.drapes_for(best[0], best[1], _drape_files))
	var jobs: Array = []
	for slot in 2:
		var d: Dictionary = pick["wide" if slot == 0 else "fine"]
		if not d.is_empty():
			jobs.append({"slot": slot, "d": d, "path": ProjectSettings.globalize_path(
				"%s/%s" % [GlobeDrape.CACHE_DIR, str(d.file)]), "max_px": 2048 if slot == 0 else 4096})
	if jobs.is_empty():
		globe.set_drape(0, null)
		globe.set_drape(1, null)
		return
	_drape_task = WorkerThreadPool.add_task(func() -> void:
		var out: Array = []
		for j in jobs:
			var img := Image.load_from_file(str(j.path))
			if img == null or img.is_empty():
				continue
			if img.is_compressed():
				img.decompress()
			var m := maxi(img.get_width(), img.get_height())
			if m > int(j.max_px):
				var f := float(j.max_px) / float(m)
				img.resize(maxi(1, int(img.get_width() * f)), maxi(1, int(img.get_height() * f)), Image.INTERPOLATE_BILINEAR)
			img.generate_mipmaps()
			out.append({"slot": j.slot, "d": j.d, "img": img})
		_drapes_loaded.call_deferred(key, out))


func _drapes_loaded(key: String, out: Array) -> void:
	if _drape_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_drape_task)
		_drape_task = -1
	if _closing or key != _drape_world:
		return
	var shown := [false, false]
	for r in out:
		var slot := int(r.slot)
		globe.set_drape(slot, ImageTexture.create_from_image(r.img),
			GlobeDrape.shader_params("d%d_" % slot, r.d))
		shown[slot] = true
	for slot in 2:
		if not shown[slot]:
			globe.set_drape(slot, null)


func drape_world() -> String:
	return _drape_world


# --- Search -----------------------------------------------------------------

func _do_search(q: String) -> void:
	q = q.strip_edges()
	if q.is_empty():
		return
	var ll := _parse_coords(q)
	if ll.size() == 2:
		_hits.visible = false
		globe.fly_to(ll[0], ll[1], 0.01)
		select_point(ll[0], ll[1])
		return
	_show_search_note("Searching…")
	_geocode.search(q)


## "48.33, -122.25" style input.
static func _parse_coords(q: String) -> PackedFloat64Array:
	var parts := q.replace(";", ",").split(",", false)
	if parts.size() != 2 or not parts[0].strip_edges().is_valid_float() \
			or not parts[1].strip_edges().is_valid_float():
		return PackedFloat64Array()
	var la := parts[0].strip_edges().to_float()
	var lo := parts[1].strip_edges().to_float()
	if absf(la) > 90.0 or absf(lo) > 180.0:
		return PackedFloat64Array()
	return PackedFloat64Array([la, lo])


func _show_search_note(t: String) -> void:
	_search_note.text = t
	_search_note.visible = not t.is_empty()


func _on_search_done(hits: Array) -> void:
	_hit_rows = hits
	_hits.clear()
	if hits.is_empty():
		_show_search_note("No places found.")
		_hits.visible = false
		return
	_show_search_note("")
	if hits.size() == 1:
		_on_hit_chosen(0)
		return
	for h in hits:
		_hits.add_item(str((h as Dictionary).get("label", "…")))
	_hits.visible = true


func _on_hit_chosen(i: int) -> void:
	if i < 0 or i >= _hit_rows.size():
		return
	var d: Dictionary = _hit_rows[i]
	_hits.visible = false
	var la := float(d.get("lat", 0.0))
	var lo := float(d.get("lng", 0.0))
	globe.fly_to(la, lo, 0.01)
	select_point(la, lo, str(d.get("label", "")))


# --- Weather and time ---------------------------------------------------------

func _process(dt: float) -> void:
	if _fly_then.is_valid() and not globe.is_flying():
		_fly_wait -= dt
		if _fly_wait <= 0.0:
			var cb := _fly_then
			_fly_then = Callable()
			cb.call()
			if _closing:
				return
			if _status.text.begins_with("Flying"):
				_status.text = ""
	if _play_h_per_s != 0.0 and not _time_dragging:
		var nxt := clampf(_time_offset_h + _play_h_per_s * dt, -TIME_SPAN_H, TIME_SPAN_H)
		if absf(nxt - _time_offset_h) < 1e-5:
			_set_play(0.0)
		else:
			_time_offset_h = nxt
			_time_slider.set_value_no_signal(nxt)
	if _time_lbl != null and globe != null:
		_time_lbl.text = _time_text(globe_unix())
	_wx_poll -= dt
	if _wx_poll > 0.0:
		return
	_wx_poll = 0.5
	if _sun_lbl != null:
		_sun_lbl.text = _sun_line()
	# The time bar sits above the credits, however many lines they wrap to.
	var lift := -(globe.credits_height() + 14.0)
	if _time_bar != null and absf(_time_bar.offset_bottom - lift) > 0.5:
		_time_bar.offset_bottom = lift
		_time_bar.offset_top = lift
	if globe.primary_body() == "earth":
		_update_drapes()
	var u := globe_unix()
	# Re-ask on a new half hour, a new day for the satellite, or a toggle.
	var key := "%d|%s|%s|%s|%s|%d" % [int(floor(u / 1800.0)), _clouds_toggle.button_pressed,
		_rain_toggle.button_pressed, _sat_toggle.button_pressed, _wind_toggle.button_pressed, _colour]
	if key == _wx_key:
		return
	_wx_key = key
	_refresh_weather(u)


## The globe's instant as UNIX seconds.
func globe_unix() -> float:
	return GlobeWeather.unix_from_jd(globe.current_jd())


func _jd_now() -> float:
	var base := GlobeMath.jd_from_unix(Time.get_unix_time_from_system())
	if _sim_jd.is_valid():
		base = float(_sim_jd.call())
	return base + _time_offset_h / 24.0


## Hours from now. Does not move the world's clock.
func set_time_offset_h(hours: float) -> void:
	_time_offset_h = clampf(hours, -TIME_SPAN_H, TIME_SPAN_H)
	if _time_slider != null:
		_time_slider.set_value_no_signal(_time_offset_h)
	_wx_poll = 0.0
	if globe != null:
		globe.refresh_sun()
		if _time_lbl != null:
			_time_lbl.text = _time_text(globe_unix())


func _cycle_play() -> void:
	var i := 0
	for s in _PLAY_SPEEDS.size():
		if is_equal_approx(_play_h_per_s, _PLAY_SPEEDS[s]):
			i = s
			break
	_set_play(_PLAY_SPEEDS[(i + 1) % _PLAY_SPEEDS.size()])


func _set_play(hours_per_s: float) -> void:
	_play_h_per_s = hours_per_s
	var label := "Play"
	for s in _PLAY_SPEEDS.size():
		if is_equal_approx(hours_per_s, _PLAY_SPEEDS[s]):
			label = _PLAY_LABELS[s]
			break
	if _play_btn_time != null:
		_play_btn_time.text = label
		_play_btn_time.icon = UiIcons.icon("pause" if hours_per_s != 0.0 else "play", 16)
	if globe != null:
		globe.sun_continuous = hours_per_s != 0.0


func _sync_paths(_on: bool = false) -> void:
	if _path_sun == null:
		return
	_set_pref("path_sun", _path_sun.button_pressed)
	_set_pref("path_moon", _path_moon.button_pressed)
	_set_pref("path_planets", _path_planets.button_pressed)
	globe.set_paths(_path_sun.button_pressed, _path_moon.button_pressed, _path_planets.button_pressed)


func _time_text(u: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(u))
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var t := "%d %s %d, %02d:%02d UTC" % [d.day, months[int(d.month) - 1], d.year, d.hour, d.minute]
	if _in_game and absf(_time_offset_h) < 0.25:
		return "Sim clock · " + t
	return "%s · %s" % [_offset_phrase(), t]


func _offset_phrase() -> String:
	if absf(_time_offset_h) < 0.25:
		return "Now"
	var mag := absf(_time_offset_h)
	var n := "%s h" % str(snappedf(mag, 0.5)).trim_suffix(".0")
	if mag >= 48.0:
		n = "%s d" % str(snappedf(mag / 24.0, 0.1)).trim_suffix(".0")
	return ("%s ago" % n) if _time_offset_h < 0.0 else ("%s ahead" % n)


func _refresh_weather(u: float) -> void:
	_refresh_aurora(u)
	var now := Time.get_unix_time_from_system()
	var cloud_gap := GlobeWeather.layer_gap("clouds", u, now)
	if _clouds_toggle.button_pressed and cloud_gap.is_empty():
		if _weather.request_clouds(u):
			_wx_text.clouds = "Clouds: loading…"
	else:
		globe.set_clouds(null)
		_wx_text.clouds = cloud_gap if _clouds_toggle.button_pressed else ""
		_weather.forget("clouds")
	var rain_gap := GlobeWeather.layer_gap("rain", u, now)
	if _rain_toggle.button_pressed and rain_gap.is_empty():
		if _weather.request_rain(u):
			_wx_text.rain = "Rain: loading…"
	else:
		globe.set_rain(null)
		_wx_text.rain = rain_gap if _rain_toggle.button_pressed else ""
		_weather.forget("rain")
	var wind_gap := GlobeWeather.layer_gap("wind", u, now)
	if (_wind_toggle.button_pressed or _colour == COLOUR_TEMP or _colour == COLOUR_POWER) and wind_gap.is_empty():
		if _weather.request_wind(u):
			_wx_text.wind = "Wind: loading…"
		else:
			_show_wind()
	else:
		globe.set_wind_lines({})
		_wx_text.wind = wind_gap if (_wind_toggle.button_pressed or _colour == COLOUR_TEMP or _colour == COLOUR_POWER) else ""
	var sat_gap := GlobeWeather.layer_gap("sat", u, now)
	if _sat_toggle.button_pressed and sat_gap.is_empty():
		var date := GlobeWeather.daily_date(u, now)
		globe.set_base_layer("daily_" + date, GlobeWeather.daily_layer_def(date))
		_wx_text.sat = "Satellite image %s" % date
	else:
		if globe.base_layer != "esri":
			globe.set_base_layer("esri")
		_wx_text.sat = sat_gap if _sat_toggle.button_pressed else ""
	_show_data_times()


func _on_clouds_ready(info: Dictionary) -> void:
	if not _clouds_toggle.button_pressed:
		return
	globe.set_clouds(info.get("tex"))
	_wx_text.clouds = ("Clouds %s" % str(info.label)) if info.get("tex") != null else str(info.get("reason", ""))
	if info.get("tex") == null and not _sat_toggle.button_pressed:
		_wx_text.clouds += ": the Satellite of the day shows that day's clouds"
	_show_data_times()


func _on_rain_ready(info: Dictionary) -> void:
	if not _rain_toggle.button_pressed:
		return
	globe.set_rain(info.get("tex"))
	_wx_text.rain = ("Rain %s" % str(info.label)) if info.get("tex") != null else str(info.get("reason", ""))
	_show_data_times()


func _on_wind_ready(info: Dictionary) -> void:
	if info.has("reason"):
		_wx_text.wind = str(info.reason)
		_show_data_times()
		return
	_wind_info = info
	_temp_tex = ImageTexture.create_from_image(info.temp_img)
	_power_tex = ImageTexture.create_from_image(info.power_img)
	_wx_text.wind = "Wind %s" % str(info.label)
	_show_wind()
	_refresh_layer_lines()
	_show_data_times()


## Puts the loaded run on the globe: lines if Wind is on, the colour layer
## if it is one of the run's.
func _show_wind() -> void:
	if _wind_info.is_empty():
		return
	globe.set_wind_lines(_wind_info.lines if _wind_toggle.button_pressed else {})
	if _colour == COLOUR_TEMP or _colour == COLOUR_POWER:
		_apply_colour()


func wind_line_segments() -> int:
	return globe.wind_segments()


## The aurora at the globe's time `u` (unix): the Kp (observed, forecast,
## archive or assumed) and, near the present, the OVATION nowcast.
func _refresh_aurora(u: float) -> void:
	var sw := get_node_or_null("/root/SpaceWeather") as SpaceWeatherService
	if sw == null or not _aurora_toggle.button_pressed:
		_aur = {}
		globe.set_aurora(false)
		_wx_text.aurora = ""
		return
	var k := sw.kp_at(u)
	var ov := sw.ovation_for(u)
	_aur = {"kp": float(k.kp), "source": str(k.source), "ovation": ov}
	globe.set_aurora(true, float(k.kp), ov.get("texture") as Texture2D)
	var g := AuroraModel.g_scale(float(k.kp))
	var src := {"observed": "observed", "forecast": "forecast", "archive": "GFZ archive",
		"assumed": "quiet, assumed: no data for that time"}
	_wx_text.aurora = "Aurora: Kp %.1f%s (%s)%s" % [float(k.kp), (" " + g) if not g.is_empty() else "",
		str(src.get(str(k.source), k.source)),
		(" · OVATION %s" % _time_text(float(ov.forecast)).get_slice(", ", 1)) if not ov.is_empty() else ""]
	_refresh_layer_lines()


## The aurora at a point, for the card: OVATION's probability there near the
## present, else where the Kp oval is seen from.
func aurora_text(lat: float, lon: float) -> String:
	if _aur.is_empty():
		return ""
	var ov: Dictionary = _aur.ovation
	if not ov.is_empty():
		var img: Image = ov.image
		var pc := img.get_pixel(int(wrapf(lon, 0.0, 360.0)) % 360, clampi(90 - roundi(lat), 0, 180)).r * 100.0
		return "Aurora: %d %% chance overhead now (NOAA OVATION), Kp %.1f" % [roundi(pc), float(_aur.kp)]
	var seen := AuroraModel.seen_from(lat, lon, float(_aur.kp), globe.sun_direction())
	if seen.is_empty():
		return "Aurora: Kp %.1f, too far from the oval to see here" % float(_aur.kp)
	return "Aurora: Kp %.1f, after dark it would be %s" % [float(_aur.kp), seen]


func _show_data_times() -> void:
	var parts := PackedStringArray()
	var credits: Array = []
	if not str(_wx_text.get("aurora", "")).is_empty():
		parts.append(str(_wx_text.aurora))
		credits.append(SpaceWeatherService.ATTRIBUTION_KP)
		if not (_aur.get("ovation", {}) as Dictionary).is_empty():
			credits.append(SpaceWeatherService.ATTRIBUTION_OVATION)
	if not str(_wx_text.clouds).is_empty():
		parts.append(str(_wx_text.clouds))
	if not str(_wx_text.rain).is_empty():
		parts.append(str(_wx_text.rain))
	if not str(_wx_text.sat).is_empty():
		parts.append(str(_wx_text.sat))
	if not str(_wx_text.get("wind", "")).is_empty():
		parts.append(str(_wx_text.wind))
	if globe.wind_segments() > 0 or (not _wind_info.is_empty() and (_colour == COLOUR_TEMP or _colour == COLOUR_POWER)):
		credits.append(GlobeWeather.WIND_CREDIT)
	if globe.has_clouds():
		credits.append(GlobeWeather.CLOUD_CREDIT)
	if globe.has_rain():
		credits.append(GlobeWeather.RAIN_CREDIT)
	_data_lbl.text = " · ".join(parts)
	_data_lbl.visible = not parts.is_empty()
	if _colour == COLOUR_ATLAS or not _atlas_info.is_empty():
		credits.append(GlobeSolarAtlas.ATTRIBUTION)
	if _card_layer != null and _card_layer.visible and _clim_info.get("ok", false):
		credits.append(GlobeClimate.ATTRIBUTION)
	globe.set_extra_credits(credits)


func _sun_line() -> String:
	var jd := globe.current_jd()
	var here := globe.center_latlon()
	if globe.primary_body() == "moon":
		var sub := MoonGlobe.subsolar_latlon(jd)
		var w := MoonGlobe.irradiance_at(here[0], here[1], jd)
		var ph := MoonGlobe.phase(jd)
		return "Sun over %.1f°%s %.0f°%s · here %.0f W/m² · %s %d %%" % [absf(sub[0]), "N" if sub[0] >= 0.0 else "S",
			absf(sub[1]), "E" if sub[1] >= 0.0 else "W", w, str(ph.name), int(round(float(ph.lit) * 100.0))]
	var sub_e := GlobeMath.subsolar_point(jd)
	var elev := GlobeMath.solar_elevation_deg(here[0], here[1], jd)
	var day := GlobeMath.day_length_hours(here[0], jd)
	return "Sun overhead %.1f°%s · here elev %.0f° · day %.1f h" % [
		absf(sub_e[0]), "N" if sub_e[0] >= 0.0 else "S", elev, day]
