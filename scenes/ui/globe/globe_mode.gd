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
const PANEL_W := 368.0
const WORLDS_W := 424.0
const GHI := preload("res://scenes/ui/location_picker/ghi_service.gd")
const ZONE_BAR := preload("res://scenes/ui/globe/globe_zone_bar.gd")
const DEFAULT_MAP_PATHS := [
	"res://maps/mars_aerial_map.tres",
	"res://maps/soak_camp_map.tres",
]
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
var _sel_builtin: MapDefinition = null
var _worlds: Array[Dictionary] = []
var _all_worlds: Array[Dictionary] = []
var _builtin_maps: Array[MapDefinition] = []
var _here := PackedFloat64Array()
var _host_parent: Node = null
var _top_bar: PanelContainer = null
var _hub_bar: Control = null
var _search_box: HBoxContainer = null
var _search_popup: PanelContainer = null
var _worlds_btn: Button = null
var _worlds_drawer: PanelContainer = null
var _worlds_list: VBoxContainer = null
var _worlds_scroll: ScrollContainer = null
var _worlds_status: Label = null
var _continue_btn: Button = null
var _coord_group: HBoxContainer = null
var _lat_edit: LineEdit = null
var _lon_edit: LineEdit = null
var _card_scroll: ScrollContainer = null
var _card_thumb: TextureRect = null
var _zone_bar: Control = null
var _zone_hint_lbl: Label = null
var _zone_cities_row: HFlowContainer = null
var _new_world_box: VBoxContainer = null
var _cache_note_lbl: Label = null
var _refetch_chk: CheckBox = null
var _guided_btn: Button = null
var _new_on_map_btn: Button = null
var _layer_bar: PanelContainer = null
var _layer_extra_box: VBoxContainer = null
var _layer_fold_btn: Button = null
var _hub_settings: Control = null
var _overlay_tex: Texture2D
var _overlay_task := -1
var _closing := false
var _launching_world := false
var _bg_rect: ColorRect = null
var _site_info: Dictionary = {}
var _drape_files := PackedStringArray()
var _drape_world := ""
var _drape_task := -1
var _drape_loading_key := ""
var _preloaded_drapes := {}   # "lat,lon" -> Array[{slot, tex, params}]
var _preloaded_site := PackedFloat64Array()
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
	gm._host_parent = parent
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
	add_to_group("world_list_listeners")
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_bg_rect = bg
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
	_resolve_builtin_maps()
	_build_top_bar()
	_build_worlds_drawer()
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
	resized.connect(_layout_floating_panels)
	call_deferred("_layout_floating_panels")
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


## Detach from an outgoing scene host when GlobeLaunchTransition takes over
## `GlobeModeLayer` on `/root` across `change_scene_to_packed`.
func prepare_for_world_launch() -> void:
	_launching_world = true
	_host_parent = null
	closed.emit()


func hide_opaque_backdrop_for_crossfade() -> void:
	if _bg_rect != null and is_instance_valid(_bg_rect):
		_bg_rect.visible = false


func _unhandled_key_input(ev: InputEvent) -> void:
	if _launching_world:
		return
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var cc := get_node_or_null("/root/CursorController")
	if cc != null and cc.has_method("top_modal"):
		var top := str(cc.call("top_modal"))
		if not top.is_empty() and top != MODAL_NAME:
			return
	var focus := get_viewport().gui_get_focus_owner() if get_viewport() != null else null
	var typing := focus is LineEdit or focus is TextEdit
	if k.physical_keycode == KEY_ESCAPE:
		if _hits.visible or _search_note.visible:
			_hits.visible = false
			_search_note.visible = false
			_sync_search_popup()
		elif _card.visible or (_worlds_drawer != null and _worlds_drawer.visible):
			_card.visible = false
			if _worlds_drawer != null:
				_worlds_drawer.visible = false
			if _worlds_btn != null:
				_worlds_btn.set_pressed_no_signal(false)
			globe.remove_marker("sel")
		else:
			close()
		get_viewport().set_input_as_handled()
	elif k.physical_keycode == KEY_SPACE and not typing:
		_cycle_play()
		get_viewport().set_input_as_handled()
	elif k.physical_keycode == KEY_HOME and not typing:
		_go_home()
		get_viewport().set_input_as_handled()


# --- UI ---------------------------------------------------------------------

func _glass() -> StyleBoxFlat:
	var sb := UITheme.dock_panel_style(0.88)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _compact_glass() -> StyleBoxFlat:
	var sb := UITheme.dock_panel_style(0.88)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "TopBar"
	_top_bar = bar
	var top_sb := _glass()
	top_sb.content_margin_left = 18
	top_sb.content_margin_right = 18
	top_sb.content_margin_top = 9
	top_sb.content_margin_bottom = 9
	bar.add_theme_stylebox_override("panel", top_sb)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 14
	bar.offset_right = -14
	bar.offset_top = 12
	bar.offset_bottom = 12
	add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	bar.add_child(row)
	var brand := HBoxContainer.new()
	brand.add_theme_constant_override("separation", 8)
	row.add_child(brand)
	var g_ic := TextureRect.new()
	g_ic.texture = UiIcons.icon("globe", 18)
	g_ic.modulate = UITheme.C_PRIMARY
	g_ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	brand.add_child(g_ic)
	var title := Label.new()
	title.text = "Globe" if _in_game else "SIMbiogenesis"
	title.add_theme_font_override("font", UITheme.font("semibold"))
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	brand.add_child(title)
	var bodies := ButtonGroup.new()
	_body_earth = _body_button("BodyEarth", "Earth", bodies,
		"Orbit the Earth. The Moon hangs where it really is; click it to go there.")
	_body_earth.button_pressed = true
	_body_earth.pressed.connect(func() -> void: globe.set_primary_body("earth"))
	brand.add_child(_body_earth)
	_body_moon = _body_button("BodyMoon", "Moon", bodies,
		"Orbit the Moon: an Earthrise over its eastern limb, the sunlight map, the subsolar track.")
	_body_moon.pressed.connect(func() -> void: globe.set_primary_body("moon"))
	brand.add_child(_body_moon)
	row.add_child(VSeparator.new())
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	row.add_child(nav)
	_worlds_btn = Button.new()
	_worlds_btn.name = "GlobeWorldsButton"
	_worlds_btn.text = "Worlds"
	_worlds_btn.toggle_mode = true
	_worlds_btn.focus_mode = Control.FOCUS_NONE
	UiIcons.apply(_worlds_btn, "layers", "Your saved worlds & built-in maps — play, rename, copy, share or delete", 14)
	UITheme.style_toggle(_worlds_btn, false, UITheme.FONT_SM)
	_worlds_btn.toggled.connect(_toggle_worlds_drawer)
	nav.add_child(_worlds_btn)
	_home_btn = IconButton.make("house", "Back to where you are (Home)", _go_home)
	_home_btn.name = "HomeButton"
	_home_btn.visible = _here.size() == 2 or not WorldStore.list().is_empty()
	nav.add_child(_home_btn)
	_search_box = HBoxContainer.new()
	_search_box.add_theme_constant_override("separation", 6)
	_search_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_box.size_flags_stretch_ratio = 1.0
	row.add_child(_search_box)
	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Search address or place…"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size = Vector2(180, 0)
	_search.text_submitted.connect(func(t: String) -> void: _do_search(t))
	_search_box.add_child(_search)
	var go := IconButton.make("search", "Search place or address", func() -> void: _do_search(_search.text))
	_search_go = go
	_search_box.add_child(go)
	_coord_group = HBoxContainer.new()
	_coord_group.name = "CoordGroup"
	_coord_group.add_theme_constant_override("separation", 6)
	_coord_group.set_meta("ui_allow_decimals", true)
	row.add_child(_coord_group)
	_coord_group.add_child(VSeparator.new())
	_lat_edit = LineEdit.new()
	_lat_edit.name = "LatInput"
	_lat_edit.placeholder_text = "Lat °"
	_lat_edit.tooltip_text = "Latitude in decimal degrees (-90 to 90), or paste 'lat, lon'"
	_lat_edit.custom_minimum_size = Vector2(90, 0)
	_lat_edit.text_submitted.connect(func(_t: String) -> void: _on_use_coords())
	_coord_group.add_child(_lat_edit)
	_lon_edit = LineEdit.new()
	_lon_edit.name = "LonInput"
	_lon_edit.placeholder_text = "Lon °"
	_lon_edit.tooltip_text = "Longitude in decimal degrees (-180 to 180)"
	_lon_edit.custom_minimum_size = Vector2(96, 0)
	_lon_edit.text_submitted.connect(func(_t: String) -> void: _on_use_coords())
	_coord_group.add_child(_lon_edit)
	var go_ll := IconButton.make("map-pin", "Fly to these coordinates", _on_use_coords)
	go_ll.name = "GoCoordsButton"
	_coord_group.add_child(go_ll)

	var mid_spacer := Control.new()
	mid_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_spacer.size_flags_stretch_ratio = 0.25
	row.add_child(mid_spacer)

	if _in_game:
		var close_btn := IconButton.close(close)
		close_btn.name = "CloseButton"
		row.add_child(close_btn)
	else:
		row.add_child(VSeparator.new())
		_build_hub_bar(row)

	_search_popup = PanelContainer.new()
	_search_popup.name = "SearchPopup"
	_search_popup.visible = false
	_search_popup.add_theme_stylebox_override("panel", _glass())
	_search_popup.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	add_child(_search_popup)
	var pop_col := VBoxContainer.new()
	pop_col.add_theme_constant_override("separation", 4)
	_search_popup.add_child(pop_col)
	_hits = ItemList.new()
	_hits.name = "SearchHits"
	_hits.visible = false
	_hits.custom_minimum_size = Vector2(400, 140)
	_hits.item_activated.connect(_on_hit_chosen)
	_hits.item_clicked.connect(func(i: int, _p: Vector2, _b: int) -> void: _on_hit_chosen(i))
	pop_col.add_child(_hits)
	_search_note = Label.new()
	_search_note.visible = false
	_search_note.add_theme_color_override("font_color", UITheme.C_WARN)
	_search_note.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	pop_col.add_child(_search_note)


func _build_hub_bar(parent_row: HBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "HubBar"
	row.add_theme_constant_override("separation", 8)
	_hub_bar = row
	parent_row.add_child(row)
	_continue_btn = Button.new()
	_continue_btn.name = "GlobeContinueButton"
	_continue_btn.text = "Continue"
	_continue_btn.tooltip_text = "Resume your most recently played world."
	_continue_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_primary_button(_continue_btn)
	_continue_btn.pressed.connect(_on_continue_pressed)
	row.add_child(_continue_btn)
	var tour_btn := Button.new()
	tour_btn.name = "GlobeTourButton"
	tour_btn.text = "Tour"
	tour_btn.focus_mode = Control.FOCUS_NONE
	UiIcons.apply(tour_btn, "sparkles", "Show me around — a guided tour of the game's features (Esc ends it)", 14)
	UITheme.style_button(tour_btn)
	tour_btn.pressed.connect(_on_show_me_around)
	row.add_child(tour_btn)
	var share_btn := IconButton.make("upload",
		"Share — export your worlds, models & settings as one zip, or install a friend's pack",
		func() -> void: _open_share())
	share_btn.name = "GlobeShareButton"
	row.add_child(share_btn)
	var gear_btn := IconButton.make("settings",
		"Settings — graphics, interface, player, NPCs, stars, window wall",
		_on_hub_settings)
	gear_btn.name = "GlobeSettingsButton"
	row.add_child(gear_btn)
	var map2d := Button.new()
	map2d.name = "CloseButton"
	map2d.text = "2D Map"
	map2d.focus_mode = Control.FOCUS_NONE
	UiIcons.apply(map2d, "map", "Switch to the 2D flat Solar Energy Zones map", 14)
	UITheme.style_button(map2d)
	map2d.pressed.connect(close)
	row.add_child(map2d)
	var quit_btn := Button.new()
	quit_btn.name = "GlobeQuitButton"
	quit_btn.text = "Quit"
	quit_btn.tooltip_text = "Save preferences and quit to desktop"
	quit_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(quit_btn)
	quit_btn.pressed.connect(_on_quit_pressed)
	row.add_child(quit_btn)


func _build_worlds_drawer() -> void:
	_worlds_drawer = PanelContainer.new()
	_worlds_drawer.name = "WorldsDrawer"
	_worlds_drawer.visible = false
	_worlds_drawer.add_theme_stylebox_override("panel", _glass())
	_worlds_drawer.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_worlds_drawer.offset_left = 14
	_worlds_drawer.offset_top = 66
	_worlds_drawer.custom_minimum_size = Vector2(WORLDS_W, 0)
	add_child(_worlds_drawer)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_worlds_drawer.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	var sh := SectionHeader.make("Your worlds", "layers")
	sh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sh)
	head.add_child(IconButton.close(func() -> void: _toggle_worlds_drawer(false)))
	_worlds_scroll = ScrollContainer.new()
	_worlds_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_worlds_scroll.custom_minimum_size = Vector2(WORLDS_W - 24.0, 210)
	_worlds_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_worlds_scroll)
	_worlds_list = VBoxContainer.new()
	_worlds_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_worlds_list.add_theme_constant_override("separation", 4)
	_worlds_scroll.add_child(_worlds_list)
	_worlds_status = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_S)
	_worlds_status.visible = false
	if not _builtin_maps.is_empty():
		col.add_child(HSeparator.new())
		var brow := HFlowContainer.new()
		brow.add_theme_constant_override("h_separation", 6)
		brow.add_theme_constant_override("v_separation", 4)
		col.add_child(brow)
		var bl := Label.new()
		bl.text = "Built-in maps:"
		bl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		bl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		bl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		brow.add_child(bl)
		for md in _builtin_maps:
			var b := Button.new()
			b.text = md.display_name
			b.focus_mode = Control.FOCUS_NONE
			b.tooltip_text = "Start a new world on %s" % md.display_name
			UITheme.style_button(b)
			b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			var m_def := md
			b.pressed.connect(func() -> void: select_builtin_map(m_def))
			brow.add_child(b)


## One half of the Earth / Moon switch.
static func _body_button(nm: String, text: String, group: ButtonGroup, tip: String) -> Button:
	var b := Button.new()
	b.name = nm
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(60, 0)
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
	_card.offset_right = -14
	_card.offset_left = -14 - PANEL_W
	_card.offset_top = 66
	add_child(_card)
	_card_scroll = ScrollContainer.new()
	_card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_card_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card.add_child(_card_scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 5)
	_card_scroll.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	_card_title = _label(head, UITheme.FONT_LG, UITheme.C_TEXT)
	_card_title.add_theme_font_override("font", UITheme.font("semibold"))
	_card_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(IconButton.close(func() -> void:
		_card.visible = false
		globe.remove_marker("sel")))
	_card_place = _label(col, UITheme.FONT_SM, UITheme.C_TEXT_S)
	_card_coords = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_M)
	_card_coords.set_meta("ui_allow_decimals", true)
	_card_thumb = TextureRect.new()
	_card_thumb.custom_minimum_size = Vector2(0, 96)
	_card_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_card_thumb.visible = false
	col.add_child(_card_thumb)

	# Compact Energy Zone block.
	var zrow := HBoxContainer.new()
	zrow.add_theme_constant_override("separation", 8)
	col.add_child(zrow)
	_zone_row = zrow
	_card_zone_chip = PanelContainer.new()
	_card_zone_chip.custom_minimum_size = Vector2(12, 12)
	_card_zone_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	zrow.add_child(_card_zone_chip)
	_card_zone = _label(zrow, UITheme.FONT_SM, UITheme.C_TEXT)
	_card_zone.add_theme_font_override("font", UITheme.font("semibold"))
	_card_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_bar = ZONE_BAR.new()
	_zone_bar.name = "ZonePopBar"
	_zone_bar.zone_clicked.connect(select_energy_zone)
	col.add_child(_zone_bar)
	_zone_hint_lbl = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_S)
	_zone_hint_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	_zone_cities_row = HFlowContainer.new()
	_zone_cities_row.add_theme_constant_override("h_separation", 4)
	_zone_cities_row.add_theme_constant_override("v_separation", 3)
	col.add_child(_zone_cities_row)

	_card_layer = _label(col, UITheme.FONT_XS, UITheme.C_TEXT)
	_card_layer.name = "LayerLines"
	_card_atlas = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_S)
	_card_atlas.name = "AtlasLine"
	_card_world_note = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_S)
	col.add_child(HSeparator.new())

	_new_world_box = VBoxContainer.new()
	_new_world_box.add_theme_constant_override("separation", 5)
	col.add_child(_new_world_box)
	_name_edit = LineEdit.new()
	_name_edit.name = "WorldName"
	_name_edit.placeholder_text = "World name"
	_name_edit.text_submitted.connect(func(_t: String) -> void: _on_create())
	_new_world_box.add_child(_name_edit)
	_cache_note_lbl = _label(_new_world_box, UITheme.FONT_XS, UITheme.C_TEXT_M)
	_cache_note_lbl.visible = false
	_refetch_chk = CheckBox.new()
	_refetch_chk.name = "RefetchCheck"
	_refetch_chk.text = "Re-download map data (terrain, imagery, OSM)"
	_refetch_chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_refetch_chk.visible = false
	_new_world_box.add_child(_refetch_chk)

	var btns := HFlowContainer.new()
	btns.add_theme_constant_override("h_separation", 6)
	btns.add_theme_constant_override("v_separation", 5)
	col.add_child(btns)
	_guided_btn = Button.new()
	_guided_btn.name = "StartGuidedButton"
	_guided_btn.text = "Start guided"
	_guided_btn.focus_mode = Control.FOCUS_NONE
	UiIcons.apply(_guided_btn, "play", "Start a new world here with a starter site on the graph and the first mission offered.", 14)
	UITheme.style_primary_button(_guided_btn)
	_guided_btn.pressed.connect(_on_create_guided)
	btns.add_child(_guided_btn)
	_create_btn = Button.new()
	_create_btn.name = "CreateWorldButton"
	_create_btn.text = "Create world here"
	_create_btn.focus_mode = Control.FOCUS_NONE
	_create_btn.tooltip_text = "Start a fresh empty world on this map (terrain, imagery, buildings and weather are fetched for it)."
	UITheme.style_button(_create_btn)
	_create_btn.pressed.connect(_on_create)
	btns.add_child(_create_btn)
	_play_btn = Button.new()
	_play_btn.name = "PlayWorldButton"
	_play_btn.text = "Play"
	_play_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_primary_button(_play_btn)
	_play_btn.pressed.connect(_on_play)
	btns.add_child(_play_btn)
	_new_on_map_btn = Button.new()
	_new_on_map_btn.name = "NewOnMapButton"
	_new_on_map_btn.text = "New world here"
	_new_on_map_btn.focus_mode = Control.FOCUS_NONE
	_new_on_map_btn.tooltip_text = "Start a fresh world on this same map without touching the existing world."
	UITheme.style_button(_new_on_map_btn)
	_new_on_map_btn.visible = false
	_new_on_map_btn.pressed.connect(func() -> void:
		if _sel.size() == 2:
			var map_d: Variant = _sel_world.get("map", {})
			var lbl := str((map_d as Dictionary).get("label", "")) if map_d is Dictionary else ""
			select_point(_sel[0], _sel[1], lbl))
	btns.add_child(_new_on_map_btn)
	_fly_btn = Button.new()
	_fly_btn.text = "Fly here"
	_fly_btn.focus_mode = Control.FOCUS_NONE
	UiIcons.apply(_fly_btn, "scan", "Zoom down to this spot.", 14)
	UITheme.style_button(_fly_btn)
	_fly_btn.pressed.connect(func() -> void:
		if _sel.size() == 2:
			globe.fly_to(_sel[0], _sel[1], 0.004 if globe.primary_body() == "earth" else 0.08))
	btns.add_child(_fly_btn)
	_status = _label(col, UITheme.FONT_XS, UITheme.C_TEXT_S)


func _build_bottom() -> void:
	var bar := PanelContainer.new()
	bar.name = "LayerBar"
	_layer_bar = bar
	bar.add_theme_stylebox_override("panel", _compact_glass())
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.offset_left = 14
	bar.offset_bottom = -14
	bar.offset_top = -14
	add_child(bar)
	bar.resized.connect(func() -> void:
		globe.set_credits_left(bar.position.x + bar.size.x + 16.0)
		_layout_floating_panels())
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	bar.add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	col.add_child(row)
	_section_label(row, "Layer")
	_colour_by = OptionButton.new()
	_colour_by.name = "ColourBy"
	_colour_by.add_item("Nothing", COLOUR_NONE)
	_colour_by.add_item("Solar zones", COLOUR_ZONES)
	_colour_by.add_item("Temperature", COLOUR_TEMP)
	_colour_by.add_item("Wind power", COLOUR_POWER)
	if GlobeSolarAtlas.layer() != null:
		_colour_by.add_item("Solar atlas (PV output)", COLOUR_ATLAS)
	_colour_by.selected = COLOUR_ZONES
	_colour_by.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_style_compact_option(_colour_by)
	_colour_by.tooltip_text = "Solar zones: mean daily sunshine on flat ground (GHI), NASA POWER 2001-2020, the map picker's zones.\nTemperature: air at 2 m, NOAA GFS at the globe's time.\nWind power: the power in the wind at 100 m (from GFS 10 m wind, open land), a snapshot not a climate.\nOn the Moon: sunlight in W/m² (clear sky, no air).\nA layer fades out as you come down to where the photo says more."
	_colour_by.item_selected.connect(func(i: int) -> void: _set_colour(_colour_by.get_item_id(i)))
	row.add_child(_colour_by)
	_zones_mode = OptionButton.new()
	_zones_mode.name = "ZonesMode"
	_zones_mode.add_item("Bands", 0)
	_zones_mode.add_item("Smooth", 1)
	_zones_mode.selected = 0
	_zones_mode.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_style_compact_option(_zones_mode)
	_zones_mode.item_selected.connect(func(_i: int) -> void: _restyle_zones())
	row.add_child(_zones_mode)
	_hover = Label.new()
	_hover.name = "HoverReadout"
	_hover.text = HINT
	_hover.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hover.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hover.clip_text = true
	_hover.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hover.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover.custom_minimum_size = Vector2(120, 0)
	row.add_child(_hover)
	_layer_fold_btn = IconButton.make("chevron-down", "Collapse or expand weather & sky layer toggles", func() -> void:
		if _layer_extra_box != null:
			_layer_extra_box.visible = not _layer_extra_box.visible
			_layer_fold_btn.icon = UiIcons.icon("chevron-down" if _layer_extra_box.visible else "chevron-up", 13)
			call_deferred("_layout_floating_panels"), "", 13)
	_layer_fold_btn.custom_minimum_size = Vector2(22, 22)
	row.add_child(_layer_fold_btn)
	_legend = HBoxContainer.new()
	_legend.name = "Legend"
	_legend.add_theme_constant_override("separation", 3)
	col.add_child(_legend)
	_layer_extra_box = VBoxContainer.new()
	_layer_extra_box.add_theme_constant_override("separation", 1)
	col.add_child(_layer_extra_box)
	var wrow := HBoxContainer.new()
	wrow.add_theme_constant_override("separation", 6)
	_layer_extra_box.add_child(wrow)
	_wind_toggle = _layer_check(wrow, "WindToggle", "Wind", false,
		"Wind at 10 m as moving streamlines (NOAA GFS 1°, runs every 6 h since 2021), coloured by speed.")
	_clouds_toggle = _layer_check(wrow, "CloudsToggle", "Clouds", false,
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
	prow.add_theme_constant_override("separation", 6)
	_layer_extra_box.add_child(prow)
	_lights_toggle = _layer_check(prow, "LightsToggle", "Lights", true,
		"The night side's city lights as points (NASA Black Marble): a glow from orbit, towns and roads as you come down.")
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
	_style_compact_check(_labels_toggle)
	_labels_toggle.button_pressed = false
	globe.labels_on = false
	_labels_toggle.toggled.connect(func(on: bool) -> void:
		globe.labels_on = on)
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
	_data_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	_data_lbl.clip_text = true
	_data_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_data_lbl.visible = false
	_build_time_bar()


const HINT := "Drag orbit · wheel zoom · click site"

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
	l.custom_minimum_size = Vector2(44, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(l)
	return l


func _style_compact_option(ob: OptionButton) -> void:
	for st in ["normal", "hover", "pressed", "focus"]:
		var base := ob.get_theme_stylebox(st)
		var sb: StyleBoxFlat = base.duplicate() if base is StyleBoxFlat else StyleBoxFlat.new()
		if not (base is StyleBoxFlat):
			sb.bg_color = UITheme.C_PANEL_RAISED
			sb.border_color = UITheme.C_BORDER
			sb.set_border_width_all(1)
			sb.set_corner_radius_all(5)
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		sb.content_margin_left = 7
		sb.content_margin_right = 20
		ob.add_theme_stylebox_override(st, sb)


static var _chk_off_13: Texture2D = null
static var _chk_on_13: Texture2D = null


static func _ensure_compact_check_icons() -> void:
	if _chk_off_13 != null:
		return
	var s := 13
	var off_img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	off_img.fill(Color(0, 0, 0, 0))
	var bcol := UITheme.C_BORDER.lightened(0.15)
	var bg := Color(UITheme.C_BG, 0.9)
	for y in range(1, s - 1):
		for x in range(1, s - 1):
			var edge := x == 1 or x == s - 2 or y == 1 or y == s - 2
			off_img.set_pixel(x, y, bcol if edge else bg)
	_chk_off_13 = ImageTexture.create_from_image(off_img)
	var on_img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	on_img.fill(Color(0, 0, 0, 0))
	for y in range(1, s - 1):
		for x in range(1, s - 1):
			on_img.set_pixel(x, y, UITheme.C_PRIMARY)
	var ink := Color(0.04, 0.06, 0.10, 1.0)
	for pt in [Vector2i(3, 6), Vector2i(4, 7), Vector2i(5, 8), Vector2i(6, 7), Vector2i(7, 6), Vector2i(8, 5), Vector2i(9, 4)]:
		on_img.set_pixel(pt.x, pt.y, ink)
		on_img.set_pixel(pt.x, pt.y + 1, ink)
	_chk_on_13 = ImageTexture.create_from_image(on_img)


func _style_compact_check(c: CheckBox) -> void:
	_ensure_compact_check_icons()
	c.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	c.add_theme_constant_override("h_separation", 4)
	c.add_theme_icon_override("unchecked", _chk_off_13)
	c.add_theme_icon_override("checked", _chk_on_13)
	var empty := StyleBoxEmpty.new()
	empty.content_margin_top = 0
	empty.content_margin_bottom = 0
	empty.content_margin_left = 1
	empty.content_margin_right = 2
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		c.add_theme_stylebox_override(st, empty)


func _layer_check(parent: Node, nm: String, text: String, on: bool, tip: String) -> CheckBox:
	var c := CheckBox.new()
	c.name = nm
	c.text = text
	c.tooltip_text = tip
	_style_compact_check(c)
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
	var zone_ids: Array = []
	var unit := ""
	match _colour:
		COLOUR_ZONES:
			for z in GHI.ZONES:
				var hi := float(z.range_hi)
				var zid_l := int(z.id)
				colors.append(z.color)
				zone_ids.append(zid_l)
				labels.append("Z%d %s" % [zid_l, ("<%d" % int(hi)) if float(z.range_lo) <= 0.0 \
					else (("%d+" % int(z.range_lo)) if is_inf(hi) else "%d–%d" % [int(z.range_lo), int(hi)])])
			unit = "kWh/m²/d"
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
		var col_i: Color = colors[i]
		var ink := Color(0.05, 0.05, 0.08) if col_i.get_luminance() > 0.5 else Color.WHITE
		if i < zone_ids.size():
			var zid := int(zone_ids[i])
			var btn := Button.new()
			btn.text = str(labels[i])
			btn.custom_minimum_size = Vector2(44, 20)
			btn.focus_mode = Control.FOCUS_NONE
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.tooltip_text = "Zone %d (%s) — %s\nClick to inspect this Solar Energy Zone and its reference cities." % [
				zid, str(labels[i]), ZONE_BAR.difficulty_of(zid)]
			var bsb := StyleBoxFlat.new()
			bsb.bg_color = col_i
			bsb.set_corner_radius_all(5)
			bsb.content_margin_left = 5
			bsb.content_margin_right = 5
			bsb.content_margin_top = 1
			bsb.content_margin_bottom = 1
			var bhv := bsb.duplicate() as StyleBoxFlat
			bhv.bg_color = col_i.lightened(0.12)
			bhv.border_color = Color.WHITE
			bhv.set_border_width_all(1)
			btn.add_theme_stylebox_override("normal", bsb)
			btn.add_theme_stylebox_override("hover", bhv)
			btn.add_theme_stylebox_override("pressed", bhv)
			btn.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			btn.add_theme_color_override("font_color", ink)
			btn.add_theme_color_override("font_hover_color", ink)
			btn.add_theme_color_override("font_pressed_color", ink)
			btn.pressed.connect(func() -> void: select_energy_zone(zid))
			_legend.add_child(btn)
		else:
			var chip := PanelContainer.new()
			var csb := StyleBoxFlat.new()
			csb.bg_color = col_i
			csb.set_corner_radius_all(6)
			csb.content_margin_left = 6
			csb.content_margin_right = 6
			csb.content_margin_top = 1
			csb.content_margin_bottom = 1
			chip.add_theme_stylebox_override("panel", csb)
			var l := Label.new()
			l.text = str(labels[i])
			l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			l.add_theme_color_override("font_color", ink)
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

func _resolve_builtin_maps() -> void:
	_builtin_maps.clear()
	for p in DEFAULT_MAP_PATHS:
		if not ResourceLoader.exists(p):
			continue
		var r := load(p)
		if r is MapDefinition:
			var md := r as MapDefinition
			if MapDefinition.is_trusted_scene_path(md.scene_path) \
					and MapDefinition.is_scene_fully_available(MapDefinition.normalize_scene_path(md.scene_path)):
				_builtin_maps.append(md)


func refresh_world_list() -> void:
	if globe != null:
		_load_worlds()


func _load_worlds() -> void:
	var prev_n := _worlds.size()
	for k in prev_n:
		globe.remove_marker("world_%d" % k)
	_worlds.clear()
	_all_worlds = WorldStore.list()
	var i := 0
	for rec in _all_worlds:
		var ll := WorldLauncher.world_latlon(rec)
		if ll.size() == 2:
			_worlds.append(rec)
			globe.set_marker("world_%d" % i, ll[0], ll[1], Color(1.0, 0.78, 0.25), short_name(world_title(rec)))
			i += 1
	if _worlds_btn != null:
		_worlds_btn.text = "Worlds (%d)" % _all_worlds.size() if not _all_worlds.is_empty() else "Worlds"
	if _home_btn != null:
		_home_btn.visible = _here.size() == 2 or not _worlds.is_empty()
	if _continue_btn != null:
		_continue_btn.disabled = _all_worlds.is_empty()
		_continue_btn.tooltip_text = ("Resume “%s” where you left off." % world_title(_all_worlds[0])) \
			if not _all_worlds.is_empty() else "No saved worlds yet."
	_rebuild_worlds_drawer()


func _toggle_worlds_drawer(on: bool) -> void:
	if _worlds_drawer == null:
		return
	_worlds_drawer.visible = on
	if _worlds_btn != null:
		_worlds_btn.set_pressed_no_signal(on)
		UITheme.style_toggle(_worlds_btn, on, UITheme.FONT_SM)
	if on:
		_rebuild_worlds_drawer()
		_layout_floating_panels()


func _rebuild_worlds_drawer() -> void:
	if _worlds_list == null:
		return
	for c in _worlds_list.get_children():
		_worlds_list.remove_child(c)
		c.queue_free()
	if _all_worlds.is_empty():
		_worlds_list.add_child(EmptyState.row("globe", "No saved worlds yet — click any place on Earth, search an address, or enter coordinates."))
		return
	for idx in _all_worlds.size():
		_worlds_list.add_child(_make_world_drawer_row(idx))


func _make_world_drawer_row(index: int) -> PanelContainer:
	var rec: Dictionary = _all_worlds[index]
	var row := PanelContainer.new()
	var rsb := UITheme.card_style()
	var sel_match := not _sel_world.is_empty() and str(_sel_world.get("id", "")) == str(rec.get("id", "?"))
	if sel_match:
		rsb.border_color = UITheme.C_PRIMARY
		rsb.bg_color = Color(UITheme.C_PRIMARY, 0.14)
	row.add_theme_stylebox_override("panel", rsb)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := ev as InputEventMouseButton
			if mb.double_click:
				_play_world_record(rec)
			else:
				var ll := WorldLauncher.world_latlon(rec)
				if ll.size() == 2:
					globe.fly_to(ll[0], ll[1], 0.015)
				select_world(rec)
				_rebuild_worlds_drawer())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	row.add_child(h)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(72, 42)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tp := WorldStore.thumb_path(str(rec.get("id", "")))
	if FileAccess.file_exists(tp):
		var img := Image.load_from_file(tp)
		if img != null and not img.is_empty():
			thumb.texture = ImageTexture.create_from_image(img)
	h.add_child(thumb)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 1)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	var nm_lbl := Label.new()
	nm_lbl.name = "Name"
	nm_lbl.text = world_title(rec)
	nm_lbl.clip_text = true
	nm_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	nm_lbl.add_theme_font_override("font", UITheme.font("semibold"))
	nm_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	nm_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nm_lbl)
	var nm_edit := LineEdit.new()
	nm_edit.name = "NameEdit"
	nm_edit.visible = false
	nm_edit.placeholder_text = world_title(rec)
	nm_edit.text_submitted.connect(func(_t: String) -> void: _commit_world_rename(rec, nm_lbl, nm_edit))
	nm_edit.focus_exited.connect(func() -> void: _commit_world_rename(rec, nm_lbl, nm_edit))
	v.add_child(nm_edit)
	var sub := Label.new()
	sub.text = _world_subline(rec)
	sub.clip_text = true
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sub.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(sub)
	var play_b := Button.new()
	play_b.text = "Play"
	play_b.focus_mode = Control.FOCUS_NONE
	UITheme.style_primary_button(play_b)
	play_b.tooltip_text = "Fly down and resume this world where you left off."
	play_b.pressed.connect(func() -> void: _play_world_record(rec))
	h.add_child(play_b)
	var ren_b := IconButton.make("pencil", "Rename this world", func() -> void:
		nm_edit.text = str(rec.get("name", ""))
		nm_lbl.visible = false
		nm_edit.visible = true
		nm_edit.grab_focus()
		nm_edit.select_all(), "", 14)
	h.add_child(ren_b)
	var dup_b := IconButton.make("copy", "Duplicate this world as an independent checkpoint", func() -> void:
		var cp := WorldStore.duplicate_world(str(rec.get("id", "")), "%s (copy)" % WorldStore.display_name(rec))
		if not cp.is_empty():
			_notify_world_listeners()
			_show_worlds_status("Copied “%s”." % world_title(cp)), "", 14)
	h.add_child(dup_b)
	var sh_b := IconButton.make("upload", "Export this world as a shareable pack (.simbiopack)",
		func() -> void: _open_share(str(rec.get("id", ""))), "", 14)
	h.add_child(sh_b)
	var del_b := IconButton.make("trash-2", "Move this world to trash (terrain cache is kept)",
		func() -> void: _confirm_delete_world(rec), "", 14)
	del_b.add_theme_color_override("icon_hover_color", UITheme.C_ERROR)
	h.add_child(del_b)
	return row


func _commit_world_rename(rec: Dictionary, lbl: Label, ed: LineEdit) -> void:
	if not ed.visible:
		return
	ed.visible = false
	var wid := str(rec.get("id", ""))
	WorldStore.rename(wid, ed.text)
	rec["name"] = ed.text.strip_edges()
	lbl.text = world_title(rec)
	lbl.visible = true
	_notify_world_listeners()


func _confirm_delete_world(rec: Dictionary) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete world"
	dlg.dialog_text = ("Move “%s” to the trash?\n\nIts files stay in user://worlds/_trash, and the map's terrain cache is kept.") % world_title(rec)
	dlg.ok_button_text = "Move to trash"
	var host := CanvasLayer.new()
	host.layer = UITheme.LAYER_MODAL + 3
	add_child(host)
	host.add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		var wid := str(rec.get("id", ""))
		var ok := WorldStore.trash(wid)
		if not _sel_world.is_empty() and str(_sel_world.get("id", "")) == wid:
			_sel_world = {}
			_card.visible = false
		_notify_world_listeners()
		_show_worlds_status("Moved to trash." if ok else "Could not delete that world.")
		host.queue_free())
	dlg.canceled.connect(host.queue_free)
	dlg.popup_centered()


func _notify_world_listeners() -> void:
	if get_tree() != null:
		get_tree().call_group("world_list_listeners", "refresh_world_list")
	else:
		_load_worlds()


func _show_worlds_status(msg: String) -> void:
	if _worlds_status == null:
		return
	_worlds_status.text = msg
	_worlds_status.visible = not msg.is_empty()


static func _world_subline(rec: Dictionary) -> String:
	var parts: PackedStringArray = []
	var lp := float(rec.get("last_played_unix", 0.0))
	if lp > 0.0:
		parts.append("played " + _rel_time(lp))
	var pt := float(rec.get("playtime_s", 0.0))
	if pt >= 60.0:
		parts.append("%dh %02dm" % [int(pt / 3600.0), int(fmod(pt, 3600.0) / 60.0)])
	var ll := WorldLauncher.world_latlon(rec)
	if ll.size() != 2:
		parts.append("built-in map")
	return " · ".join(parts) if not parts.is_empty() else "saved world"


static func _rel_time(unix: float) -> String:
	var d := Time.get_unix_time_from_system() - unix
	if d < 90.0:
		return "just now"
	if d < 3600.0:
		return "%d min ago" % int(d / 60.0)
	if d < 86400.0:
		return "%d h ago" % int(d / 3600.0)
	if d < 86400.0 * 14.0:
		return "%d d ago" % int(d / 86400.0)
	var dt := Time.get_datetime_dict_from_unix_time(int(unix))
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %d" % [months[clampi(int(dt.month) - 1, 0, 11)], int(dt.day), int(dt.year)]


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
	if _search_box != null:
		_search_box.visible = not moon
	_search.visible = not moon
	if _search_go != null:
		_search_go.visible = not moon
	if _coord_group != null:
		_coord_group.visible = not moon
	if _worlds_btn != null:
		_worlds_btn.visible = not moon
	if moon and _worlds_drawer != null and _worlds_drawer.visible:
		_toggle_worlds_drawer(false)
	_hits.visible = false
	_search_note.visible = false
	_sync_search_popup()
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
	_sel_builtin = null
	_here_selected = false
	_card.visible = true
	_card_thumb.visible = false
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
	_zone_bar.visible = false
	_zone_hint_lbl.visible = false
	_zone_cities_row.visible = false
	_card_layer.text = ""
	_card_layer.visible = false
	_new_world_box.visible = false
	_guided_btn.visible = false
	_create_btn.visible = false
	_play_btn.visible = false
	_new_on_map_btn.visible = false
	_fly_btn.visible = true
	_card_world_note.text = "A lunar day is 29.5 Earth days: the sunlight map turns once a month."
	if _card_atlas != null:
		_card_atlas.text = ""
		_card_atlas.visible = false
	_status.text = ""
	call_deferred("_layout_floating_panels")


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


func _sync_coord_inputs(lat: float, lon: float) -> void:
	if _lat_edit == null or _lon_edit == null:
		return
	if SitePrivacy.redact:
		_lat_edit.text = ""
		_lon_edit.text = ""
		return
	_lat_edit.text = "%.4f" % lat
	_lon_edit.text = "%.4f" % lon


func select_point(lat: float, lon: float, label: String = "") -> void:
	_fly_btn.visible = true
	_card_atlas.visible = _colour == COLOUR_ATLAS or _colour == COLOUR_ZONES
	_sel = PackedFloat64Array([lat, lon])
	_sel_world = {}
	_sel_builtin = null
	_here_selected = false
	_sync_coord_inputs(lat, lon)
	_play_btn.text = "Fly in and play"
	_sel_label = label
	globe.set_marker("sel", lat, lon, Color(0.4, 0.85, 1.0))
	_card.visible = true
	_card_thumb.visible = false
	_card_title.text = "New world here" if label.is_empty() else SitePrivacy.place(label)
	_card_place.text = "" if not label.is_empty() else "Looking up the place…"
	_card_coords.text = SitePrivacy.coords(lat, lon)
	_fill_zone(lat, lon)
	_card_world_note.text = _nearby_world_note(lat, lon)
	_new_world_box.visible = true
	_name_edit.visible = true
	_name_edit.text = ""
	_name_edit.placeholder_text = "World name (default: the place)"
	_update_cache_ui(lat, lon)
	_guided_btn.visible = true
	_create_btn.visible = true
	_play_btn.visible = false
	_new_on_map_btn.visible = false
	_status.text = ""
	if label.is_empty():
		_geocode.reverse(lat, lon)
	call_deferred("_layout_floating_panels")


func select_builtin_map(md: MapDefinition) -> void:
	if md == null:
		return
	_sel = PackedFloat64Array()
	_sel_world = {}
	_sel_builtin = md
	_here_selected = false
	globe.remove_marker("sel")
	_card.visible = true
	_card_thumb.visible = false
	_card_title.text = md.display_name
	_card_place.text = "Built-in map scene — starts empty or with a starter system."
	_card_coords.text = ""
	_zone_row.visible = false
	_zone_bar.visible = false
	_zone_hint_lbl.visible = false
	_zone_cities_row.visible = false
	_card_layer.visible = false
	_card_atlas.visible = false
	var map_ref := WorldStore.map_ref_from_definition(md, "")
	var others := WorldStore.worlds_on_map(map_ref).size()
	_card_world_note.text = ("%s already on this map — a new one starts fresh." % UiText.count(others, "world")) if others > 0 else ""
	_new_world_box.visible = true
	_name_edit.visible = true
	_name_edit.text = ""
	_name_edit.placeholder_text = "World name (default: %s)" % md.display_name
	_cache_note_lbl.visible = false
	_refetch_chk.visible = false
	_guided_btn.visible = true
	_create_btn.visible = true
	_play_btn.visible = false
	_new_on_map_btn.visible = false
	_fly_btn.visible = false
	_status.text = ""
	call_deferred("_layout_floating_panels")


func select_energy_zone(zone_id: int) -> void:
	var ghi := get_node_or_null("/root/GhiService")
	if ghi == null or zone_id < 1 or zone_id > 6:
		return
	var zones: Array = ghi.call("get_zones")
	if zone_id > zones.size():
		return
	var zd: Dictionary = zones[zone_id - 1]
	_sel = PackedFloat64Array()
	_sel_world = {}
	_sel_builtin = null
	_here_selected = false
	globe.remove_marker("sel")
	_card.visible = true
	_card_thumb.visible = false
	_card_title.text = "%s — %s" % [str(zd.get("label", "Zone")), ZONE_BAR.difficulty_of(zone_id)]
	_card_place.text = "Click a city below or anywhere on the globe to pick a site."
	_card_coords.text = ""
	_zone_row.visible = true
	_card_zone_chip.visible = true
	_card_zone_chip.add_theme_stylebox_override("panel", UITheme.chip_style(zd.get("color", Color.WHITE)))
	_card_zone.text = "%s kWh/m²/day band" % str(ghi.call("zone_ghi_range_label", zd))
	_zone_bar.visible = true
	_zone_bar.call("refresh", zone_id)
	var pop_s := ZONE_BAR.pop_summary_line(ghi, zone_id)
	var hint_s := ZONE_BAR.short_hint_of(zone_id)
	_zone_hint_lbl.text = pop_s + ("\n" + hint_s if not hint_s.is_empty() else "")
	_zone_hint_lbl.tooltip_text = str(ghi.call("get_zone_narrative", zone_id))
	_zone_hint_lbl.visible = true
	_populate_city_chips({}, ghi.call("find_cities_in_zone", zone_id, 5))
	_card_layer.visible = false
	_card_atlas.visible = false
	_card_world_note.text = ""
	_new_world_box.visible = false
	_guided_btn.visible = false
	_create_btn.visible = false
	_play_btn.visible = false
	_new_on_map_btn.visible = false
	_fly_btn.visible = false
	_status.text = ""
	call_deferred("_layout_floating_panels")


func select_world(rec: Dictionary) -> void:
	var ll := WorldLauncher.world_latlon(rec)
	_sel = ll
	_sel_world = rec
	_sel_builtin = null
	_here_selected = false
	if ll.size() == 2:
		_sync_coord_inputs(ll[0], ll[1])
	_play_btn.text = "Fly in and play" if ll.size() == 2 else "Play world"
	globe.remove_marker("sel")
	_card.visible = true
	var tp := WorldStore.thumb_path(str(rec.get("id", "")))
	var shown_thumb := false
	if FileAccess.file_exists(tp):
		var img := Image.load_from_file(tp)
		if img != null and not img.is_empty():
			_card_thumb.texture = ImageTexture.create_from_image(img)
			shown_thumb = true
	_card_thumb.visible = shown_thumb
	_card_title.text = world_title(rec)
	var map: Variant = rec.get("map", {})
	_card_place.text = SitePrivacy.place(str((map as Dictionary).get("label", ""))) if map is Dictionary else ""
	_card_coords.text = SitePrivacy.coords(ll[0], ll[1]) if ll.size() == 2 else "Built-in map"
	if ll.size() == 2:
		_fill_zone(ll[0], ll[1])
	else:
		_zone_row.visible = false
		_zone_bar.visible = false
		_zone_hint_lbl.visible = false
		_zone_cities_row.visible = false
		_card_layer.visible = false
		_card_atlas.visible = false
	_card_world_note.text = _world_subline(rec)
	_new_world_box.visible = false
	_guided_btn.visible = false
	_create_btn.visible = false
	_play_btn.visible = true
	_new_on_map_btn.visible = ll.size() == 2
	_fly_btn.visible = ll.size() == 2
	_status.text = ""
	call_deferred("_layout_floating_panels")


func _update_cache_ui(lat: float, lon: float) -> void:
	if _cache_note_lbl == null or _refetch_chk == null:
		return
	var cached := TerrainCacheSettings.has_warm_cache(lat, lon)
	var map_ref := {"scene_path": MapDefinition.GENERATED_SCENE, "lat": lat, "lon": lon}
	var others := WorldStore.worlds_on_map(map_ref).size()
	var bits: PackedStringArray = []
	if cached:
		bits.append("Map cached — starts in seconds")
	else:
		bits.append("First visit — fetches terrain, imagery & OSM (~15–60 s)")
	if others > 0:
		bits.append("%s on this map" % UiText.count(others, "world"))
	_cache_note_lbl.text = " · ".join(bits)
	_cache_note_lbl.visible = true
	_refetch_chk.set_pressed_no_signal(false)
	_refetch_chk.visible = cached


func _fill_zone(lat: float, lon: float) -> void:
	var zr := _zone_at(lat, lon)
	var z: Dictionary = zr[1]
	var ghi := get_node_or_null("/root/GhiService")
	if z.is_empty() or is_nan(float(zr[0])):
		_card_zone.text = "Solar data unavailable"
		_card_zone_chip.visible = false
		_zone_bar.visible = false
		_zone_hint_lbl.visible = false
		_zone_cities_row.visible = false
		_request_atlas(lat, lon)
		_request_climate(lat, lon)
		return
	var zid := int(z.get("id", 0))
	var g_val := float(zr[0])
	_card_zone_chip.visible = true
	_card_zone_chip.add_theme_stylebox_override("panel", UITheme.chip_style(z.color))
	var diff := ZONE_BAR.difficulty_of(zid)
	_card_zone.text = "%s%s · %.1f kWh/m²/day of sun" % [str(z.label),
		(" (" + diff + ")") if not diff.is_empty() else "", g_val]
	_zone_bar.visible = true
	_zone_bar.call("refresh", zid)
	if ghi != null:
		var pop_s := ZONE_BAR.pop_summary_line(ghi, zid)
		_zone_hint_lbl.text = pop_s
		_zone_hint_lbl.tooltip_text = ZONE_BAR.short_hint_of(zid) + "\n\n" + str(ghi.call("get_zone_narrative", zid))
		_zone_hint_lbl.visible = not pop_s.is_empty()
		var sis: Variant = ghi.call("find_sister_city", lat, g_val)
		var peers: Array = ghi.call("find_similar_cities", g_val, 3, sis)
		_populate_city_chips(sis if sis is Dictionary else {}, peers)
	else:
		_zone_hint_lbl.visible = false
		_zone_cities_row.visible = false
	_request_atlas(lat, lon)
	_request_climate(lat, lon)


func _populate_city_chips(sister: Dictionary, peers: Array) -> void:
	for c in _zone_cities_row.get_children():
		_zone_cities_row.remove_child(c)
		c.queue_free()
	var added := false
	if not sister.is_empty():
		var sl := Label.new()
		sl.text = "Sister:"
		sl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		sl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_zone_cities_row.add_child(sl)
		_zone_cities_row.add_child(_city_fly_chip(sister, true))
		added = true
	var max_peers := 2 if not sister.is_empty() else 4
	var shown := 0
	for pv in peers:
		if shown >= max_peers:
			break
		var pd: Dictionary = pv
		if shown == 0:
			var pl := Label.new()
			pl.text = "Peers:"
			pl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			pl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			pl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_zone_cities_row.add_child(pl)
		_zone_cities_row.add_child(_city_fly_chip(pd, false))
		shown += 1
		added = true
	_zone_cities_row.visible = added


func _city_fly_chip(city: Dictionary, is_sister: bool) -> Button:
	var nm := str(city.get("name", ""))
	var ctry := str(city.get("country", ""))
	var cg := float(city.get("ghi", 0.0))
	var clat := float(city.get("lat", 0.0))
	var clon := float(city.get("lng", 0.0))
	var b := Button.new()
	b.text = "%s · %.1f" % [nm, cg]
	b.custom_minimum_size = Vector2(0, 22)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.tooltip_text = "%s, %s (%.1f kWh/m²/d)%s\nClick to fly the globe there." % [
		nm, ctry, cg, " — opposite-hemisphere solar match" if is_sister else ""]
	var col := UITheme.C_PRIMARY if is_sister else UITheme.C_TEXT_S
	var sb := UITheme.chip_style(col)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", UITheme.chip_style(UITheme.C_PRIMARY))
	b.add_theme_stylebox_override("pressed", UITheme.chip_style(UITheme.C_AMBER))
	b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	b.add_theme_color_override("font_color", UITheme.C_TEXT if is_sister else UITheme.C_TEXT_S)
	b.pressed.connect(func() -> void:
		globe.fly_to(clat, clon, 0.02)
		select_point(clat, clon, "%s, %s" % [nm, ctry]))
	return b


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
	var earth_pt := globe.primary_body() == "earth" and (_sel.size() == 2 or (_sel.is_empty() and _sel_builtin == null and _sel_world.is_empty()))
	var show_z := (_colour == COLOUR_ZONES or _colour == COLOUR_NONE) and earth_pt
	_zone_row.visible = show_z
	if _zone_bar != null:
		_zone_bar.visible = show_z
	if _zone_hint_lbl != null:
		_zone_hint_lbl.visible = show_z and not _zone_hint_lbl.text.is_empty()
	if _zone_cities_row != null:
		_zone_cities_row.visible = show_z and _zone_cities_row.get_child_count() > 0
	_card_atlas.visible = (_colour == COLOUR_ATLAS or _colour == COLOUR_ZONES) and _sel.size() == 2 and globe.primary_body() == "earth"
	if _sel.size() != 2:
		_card_layer.text = ""
		_card_layer.visible = false
		call_deferred("_layout_floating_panels")
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
	call_deferred("_layout_floating_panels")


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
	call_deferred("_layout_floating_panels")


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
	_launch_new_world({})


func _on_create_guided() -> void:
	_launch_new_world({"starter": true})


func _launch_new_world(base_opts: Dictionary) -> void:
	if _launching_world:
		return
	var nm := _name_edit.text.strip_edges() if _name_edit != null else ""
	if _sel_builtin != null:
		var map_ref := WorldStore.map_ref_from_definition(_sel_builtin, "")
		var rec := WorldStore.create(map_ref, nm)
		var err := WorldLauncher.play(get_tree(), rec, base_opts)
		if err != OK:
			_status.text = "Could not create the world (error %d)." % err
			return
		close()
		return
	if _sel.size() != 2:
		return
	var lat := _sel[0]
	var lon := _sel[1]
	var label := _sel_label if not _sel_label.is_empty() else "%.4f, %.4f" % [lat, lon]
	var prefer := not _sel_label.is_empty()
	var opts := base_opts.duplicate()
	if _refetch_chk != null and _refetch_chk.visible and _refetch_chk.button_pressed:
		opts["force_refetch"] = true
	var map := WorldLauncher.register_map(lat, lon, label, prefer)
	var new_rec := WorldStore.create(map, nm)
	_start_world_transition(new_rec, opts)


func _on_play() -> void:
	if _launching_world:
		return
	if _here_selected:
		fly_in(_here[0], _here[1], close)
		return
	if _sel_world.is_empty():
		return
	_play_world_record(_sel_world)


func _play_world_record(rec: Dictionary, opts: Dictionary = {}) -> void:
	if _launching_world:
		return
	var ll := WorldLauncher.world_latlon(rec)
	if ll.size() != 2:
		var err0 := WorldLauncher.play(get_tree(), rec, opts)
		if err0 != OK:
			_status.text = "Could not open that world (error %d)." % err0
			return
		close()
		return
	var is_here := _here.size() == 2 \
		and GlobeMath.great_circle_km(ll[0], ll[1], _here[0], _here[1]) < 0.05
	if is_here and opts.is_empty():
		fly_in(ll[0], ll[1], close)
		return
	_start_world_transition(rec, opts)


func _start_world_transition(rec: Dictionary, opts: Dictionary = {}) -> void:
	if _launching_world:
		return
	if DisplayServer.get_name() == "headless":
		var err_h := WorldLauncher.play(get_tree(), rec, opts)
		if err_h == OK:
			close()
		return
	var trans := GlobeLaunchTransition.new()
	var err := trans.begin(self, rec, opts)
	if err != OK:
		trans.queue_free()
		_launching_world = false
		_status.text = "Could not open that world (error %d)." % err


func _on_continue_pressed() -> void:
	if _all_worlds.is_empty():
		_load_worlds()
	if _all_worlds.is_empty():
		return
	_play_world_record(_all_worlds[0])


func _on_show_me_around() -> void:
	if not _all_worlds.is_empty():
		_play_world_record(_all_worlds[0], {"tour": true})
		return
	if _sel.size() == 2:
		_launch_new_world({"starter": true, "tour": true})
		return
	var c := globe.center_latlon()
	select_point(c[0], c[1])
	_launch_new_world({"starter": true, "tour": true})


func _on_hub_settings() -> void:
	if _host_parent != null and is_instance_valid(_host_parent) and _host_parent.has_method("_open_hub_settings"):
		_host_parent.call("_open_hub_settings")
		return
	if _hub_settings == null or not is_instance_valid(_hub_settings):
		var script := load("res://scenes/ui/timeline_settings_panel.gd") as Script
		if script == null:
			return
		var p := Control.new()
		p.name = "HubSettingsPanel"
		p.set_script(script)
		p.set("hub_mode", true)
		UiScreenLayout.pin_fullscreen(p)
		var layer := CanvasLayer.new()
		layer.name = "GlobeSettingsLayer"
		layer.layer = UITheme.LAYER_MODAL + 2
		add_child(layer)
		layer.add_child(p)
		_hub_settings = p
	if _hub_settings.has_method("open"):
		_hub_settings.call("open")


func _open_share(world_id: String = "") -> void:
	var apm := load("res://scenes/ui/asset_pack_modal.gd")
	if apm != null and apm.has_method("open_export"):
		apm.call("open_export", self, world_id)


func _on_quit_pressed() -> void:
	var ssc := get_node_or_null("/root/SimSettingsController")
	if ssc != null and ssc.has_method("persist_settings"):
		ssc.call("persist_settings")
	if get_tree() != null:
		get_tree().quit()


func _on_use_coords() -> void:
	if _lat_edit == null or _lon_edit == null:
		return
	var a := _lat_edit.text.strip_edges()
	var b := _lon_edit.text.strip_edges()
	if b.is_empty() and (a.contains(",") or a.contains(";")):
		var ll_pair := _parse_coords(a)
		if ll_pair.size() == 2:
			_show_search_note("")
			globe.fly_to(ll_pair[0], ll_pair[1], 0.01)
			select_point(ll_pair[0], ll_pair[1])
			return
	if a.is_empty() or b.is_empty() or not a.is_valid_float() or not b.is_valid_float():
		_show_search_note("Enter decimal degrees in Lat and Lon (e.g. 48.3252 and -122.2469).")
		return
	var la := a.to_float()
	var lo := b.to_float()
	if absf(la) > 90.0 or absf(lo) > 180.0:
		_show_search_note("Latitude must be -90..90 and Longitude -180..180.")
		return
	_show_search_note("")
	_hits.visible = false
	_sync_search_popup()
	globe.fly_to(la, lo, 0.01)
	select_point(la, lo)


func _sync_search_popup() -> void:
	if _search_popup == null:
		return
	var show_pop := (_hits != null and _hits.visible) or (_search_note != null and _search_note.visible)
	_search_popup.visible = show_pop
	if show_pop and _top_bar != null and _search != null:
		var sx := _search.global_position.x - global_position.x
		_search_popup.offset_left = maxf(sx, 14.0)
		_search_popup.offset_top = _top_bar.position.y + _top_bar.size.y + 6.0
		_search_popup.custom_minimum_size.x = maxf(_search.size.x + 36.0, 380.0)


func _layout_floating_panels() -> void:
	if not is_inside_tree() or get_viewport() == null:
		return
	var vp_h := get_viewport().get_visible_rect().size.y
	var bar_bottom := (_top_bar.position.y + _top_bar.size.y + 8.0) if _top_bar != null else 64.0
	if _worlds_drawer != null:
		_worlds_drawer.offset_top = bar_bottom
		var lb_top := _layer_bar.position.y if _layer_bar != null and _layer_bar.visible else (vp_h - 140.0)
		var max_wh := maxf(lb_top - bar_bottom - 12.0, 140.0)
		if _worlds_scroll != null:
			_worlds_scroll.custom_minimum_size.y = clampf(max_wh - 86.0, 100.0, 260.0)
	if _card != null and _card_scroll != null:
		_card.offset_top = bar_bottom
		var tb_top := _time_bar.position.y if _time_bar != null and _time_bar.visible else (vp_h - 110.0)
		var max_ch := maxf(tb_top - bar_bottom - 12.0, 180.0)
		var content_c := _card_scroll.get_child(0) as Control if _card_scroll.get_child_count() > 0 else null
		var want_ch := content_c.get_combined_minimum_size().y + 4.0 if content_c != null else 220.0
		_card_scroll.custom_minimum_size.y = minf(want_ch, max_ch)
	_sync_search_popup()


## Flies down to a place (about 1.2 km up, leaning toward the horizon), pre-staging
## the destination zoom-tile spine + cached world drapes so imagery stays crisp,
## then runs `then` once the flight has landed.
func fly_in(lat: float, lon: float, then: Callable) -> void:
	_status.text = "Flying in…"
	_fly_then = then
	_fly_wait = 0.45
	preload_drapes_for_site(lat, lon)
	globe.set_prestage_target(lat, lon)
	var dur := clampf(2.8 + log(maxf(globe.altitude_km(), 1.0)) * 0.28, 3.0, 5.6)
	globe.fly_to(lat, lon, 0.00022, dur, 58.0)


func is_flying_in() -> bool:
	return _fly_then.is_valid() or _launching_world


## "You are here": the world itself, its weather in the sim and the GFS's.
func select_here() -> void:
	_sel = _here
	_sel_world = {}
	_sel_builtin = null
	_here_selected = true
	_sync_coord_inputs(_here[0], _here[1])
	globe.remove_marker("sel")
	_card.visible = true
	_card_thumb.visible = false
	_card_title.text = "This world"
	_card_place.text = ""
	_card_coords.text = SitePrivacy.coords(_here[0], _here[1])
	_fill_zone(_here[0], _here[1])
	_card_world_note.text = site_weather_text()
	_new_world_box.visible = false
	_guided_btn.visible = false
	_create_btn.visible = false
	_new_on_map_btn.visible = false
	_play_btn.visible = true
	_play_btn.text = "Back to the world"
	_status.text = ""
	call_deferred("_layout_floating_panels")


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

## Pre-decodes a target site's cached terrain drapes on a worker thread right
## away (even while the camera is still in orbit) so they bind in 0 ms the
## moment the descending camera crosses DRAPE_SHOW_KM / DRAPE_CLEAR_KM.
func preload_drapes_for_site(lat: float, lon: float) -> void:
	_preloaded_site = PackedFloat64Array([lat, lon])
	if _drape_files.is_empty() and DirAccess.dir_exists_absolute(GlobeDrape.CACHE_DIR):
		_drape_files = DirAccess.get_files_at(GlobeDrape.CACHE_DIR)
	var key := "%.4f,%.4f" % [lat, lon]
	if _preloaded_drapes.has(key):
		tick_launch_drapes()
		return
	if _drape_task >= 0:
		return
	_start_drape_worker(lat, lon, key)


func tick_launch_drapes() -> void:
	if globe == null or globe.primary_body() != "earth":
		return
	_update_drapes()


## Near a world (camera low, centre within DRAPE_NEAR_KM), its cached photos
## go on the globe; high up they come off again.
func _update_drapes() -> void:
	var alt := globe.altitude_km()
	if alt > DRAPE_CLEAR_KM:
		if not _drape_world.is_empty():
			_drape_world = ""
			globe.set_drape(0, null)
			globe.set_drape(1, null)
		return
	var show_ceiling := DRAPE_CLEAR_KM if (_launching_world or _fly_then.is_valid()) else DRAPE_SHOW_KM
	if alt > show_ceiling:
		return
	var c := globe.center_latlon()
	var best := PackedFloat64Array()
	var best_d := DRAPE_NEAR_KM
	var sites: Array = []
	for rec in _worlds:
		sites.append(WorldLauncher.world_latlon(rec))
	if _here.size() == 2:
		sites.append(_here)
	if _preloaded_site.size() == 2:
		sites.append(_preloaded_site)
	for ll: PackedFloat64Array in sites:
		if ll.size() != 2:
			continue
		var d := GlobeMath.great_circle_km(c[0], c[1], ll[0], ll[1])
		if d < best_d:
			best_d = d
			best = ll
	if best.size() != 2:
		return
	var key := "%.4f,%.4f" % [best[0], best[1]]
	if key == _drape_world:
		return
	if _preloaded_drapes.has(key):
		_drape_world = key
		_apply_ready_drapes(_preloaded_drapes[key] as Array)
		return
	if _drape_task >= 0:
		return
	_drape_world = key
	_start_drape_worker(best[0], best[1], key)


func _start_drape_worker(lat: float, lon: float, key: String) -> void:
	var pick := GlobeDrape.pick(GlobeDrape.drapes_for(lat, lon, _drape_files))
	var jobs: Array = []
	for slot in 2:
		var d: Dictionary = pick["wide" if slot == 0 else "fine"]
		if not d.is_empty():
			jobs.append({"slot": slot, "d": d, "path": ProjectSettings.globalize_path(
				"%s/%s" % [GlobeDrape.CACHE_DIR, str(d.file)]), "max_px": 2048 if slot == 0 else 4096})
	if jobs.is_empty():
		if key == _drape_world:
			globe.set_drape(0, null)
			globe.set_drape(1, null)
		return
	_drape_loading_key = key
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
	_drape_loading_key = ""
	if _closing:
		return
	var ready_entries: Array = []
	for r in out:
		var slot := int(r.slot)
		ready_entries.append({
			"slot": slot,
			"tex": ImageTexture.create_from_image(r.img),
			"params": GlobeDrape.shader_params("d%d_" % slot, r.d),
		})
	if _preloaded_drapes.size() >= 4:
		_preloaded_drapes.erase(_preloaded_drapes.keys()[0])
	_preloaded_drapes[key] = ready_entries
	if key == _drape_world and globe.altitude_km() <= DRAPE_CLEAR_KM:
		_apply_ready_drapes(ready_entries)
	elif globe.altitude_km() <= DRAPE_CLEAR_KM:
		_update_drapes()


func _apply_ready_drapes(entries: Array) -> void:
	var shown := [false, false]
	for e in entries:
		var slot := int(e.slot)
		globe.set_drape(slot, e.tex as Texture2D, e.params as Dictionary)
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
		_sync_search_popup()
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
	_sync_search_popup()


func _on_search_done(hits: Array) -> void:
	_hit_rows = hits
	_hits.clear()
	if hits.is_empty():
		_hits.visible = false
		_show_search_note("No places found.")
		return
	_search_note.text = ""
	_search_note.visible = false
	if hits.size() == 1:
		_sync_search_popup()
		_on_hit_chosen(0)
		return
	for h in hits:
		_hits.add_item(str((h as Dictionary).get("label", "…")))
	_hits.visible = true
	_sync_search_popup()


func _on_hit_chosen(i: int) -> void:
	if i < 0 or i >= _hit_rows.size():
		return
	var d: Dictionary = _hit_rows[i]
	_hits.visible = false
	_sync_search_popup()
	var la := float(d.get("lat", 0.0))
	var lo := float(d.get("lng", 0.0))
	globe.fly_to(la, lo, 0.01)
	select_point(la, lo, str(d.get("label", "")))


# --- Weather and time ---------------------------------------------------------

func _process(dt: float) -> void:
	if _fly_then.is_valid():
		if globe.primary_body() == "earth":
			_update_drapes()
		if not globe.is_flying():
			_fly_wait -= dt
			if _fly_wait <= 0.0:
				globe.clear_prestage_target()
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
