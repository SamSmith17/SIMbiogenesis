extends Control
## Solar location / zone picker. OVERLAY = in-game modal (M); LAUNCH = boot hub.

enum LaunchMode { OVERLAY, LAUNCH }

signal location_confirmed(lat: float, lng: float, place_label: String)
signal picker_dismissed

@export var launch_mode: LaunchMode = LaunchMode.OVERLAY
@export var maps: Array[MapDefinition] = []

var G: GhiService
var _geocode: GeocodeClient
var _map: WorldMapControl
var _chart: ZonePopulationChart
var _legend_hovered: int = -1
var _legend_picked: int = -1
var _sel_lat: float = NAN
var _sel_lng: float = NAN
## The name a created map / world gets. ONE rule keeps it honest: it is only
## ever set by something that names THESE coordinates — a geocode hit, a
## reverse lookup of the current selection, or picking an existing map. Any
## other coordinate change clears it (see _on_coords_changed_manually); it
## used to survive "Use coords", so a new map inherited the last address.
var _place_label: String = ""
## Debounces reverse lookups (Nominatim allows one request per second).
var _reverse_timer: Timer = null
## Shown under the coordinate row: why Create is refusing, or "naming…".
var _coord_note: Label = null
const REVERSE_DEBOUNCE_S := 0.9

var _address_field: LineEdit
var _lat_field: LineEdit
var _lng_field: LineEdit
var _geocode_hits: ItemList
var _geocode_error: Label
var _zone_title: Label
var _zone_ghi: Label
var _zone_pot: Label
var _zone_narr: RichTextLabel
var _zone_pop: RichTextLabel
var _pop_spin_value: float = 0.0
var _pop_spin_tween: Tween = null
var _pop_spin_zone_id: int = 0
var _pop_spin_pct: int = 0
var _pop_spin_year: int = 0
var _sister: RichTextLabel
var _similar: VBoxContainer
var _legend_buttons: Array[Button] = []
var _last_hits: Array[Dictionary] = []
var _panel: PanelContainer = null
var _dim: ColorRect = null
var _hsplit: HSplitContainer = null
var _panel_margin: MarginContainer = null
var _details_scroll: ScrollContainer = null
var _details_root: VBoxContainer = null
var _pending_bundle_path: String = ""
var _pending_starshade: bool = false
var _bundle_status: Label
var _maps_resolved: Array[MapDefinition] = []
## Parallel to `_maps_resolved`: user:// path for deletable maps, else "".
var _maps_file_paths: Array[String] = []
var _maps_list: VBoxContainer = null
var _launch_status: Label = null
var _continue_btn: Button = null
## The hub's settings modal (timeline_settings_panel in hub_mode), made on
## the first press of the gear.
var _settings_panel: Control = null
var _start_btn: Button = null
var _quit_btn: Button = null
var _close_btn: Button = null
var _confirm_btn: Button = null
## Worlds list (launch hub): records newest first, their row panels, the pick.
var _world_recs: Array[Dictionary] = []
var _world_row_panels: Array[PanelContainer] = []
var _world_sel_idx: int = -1
## New-world panel. _nw_builtin_idx >= 0 builds on a built-in map instead of
## the selected location.
var _nw_host: VBoxContainer = null
var _nw_builtin_idx: int = -1
var _nw_builtin_btns: Array[Button] = []
var _nw_source_lbl: Label = null
var _nw_status_lbl: Label = null
var _nw_warn_lbl: Label = null
var _nw_name: LineEdit = null
var _nw_refetch: CheckBox = null
var _nw_start_btn: Button = null

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
const PLACED_PROP_SERVICE_SCRIPT := preload("res://core/placed_models/placed_prop_service.gd")

const _DEFAULT_MAP_PATHS: Array[String] = [
	"res://maps/mars_aerial_map.tres",
	"res://maps/soak_camp_map.tres",
]
const _USER_MAPS_DIR := "user://maps"

const PANEL_INSET := 32.0
const PANEL_MARGIN := 16
const PANEL_MARGIN_V := 12
const _LAUNCH_BG := Color(0.039, 0.055, 0.098, 1.0)
const _TEXT := Color(0.886, 0.910, 0.941, 1.0)
const _TEXT_M := Color(0.392, 0.447, 0.545, 1.0)
const _PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const ZONE_DIFFICULTY: Array[String] = [
	"",
	"Extremely Difficult",
	"Difficult",
	"Hard",
	"Average",
	"Easy",
	"Easy but very hot",
]
const WELCOME_EXPLAINER := (
	"Every single person living on Earth lives in a place that receives at least "
	+ "1 kilowatt-hour of solar energy per square meter per day on average, and at most "
	+ "around 7 kilowatt-hours per m² per day. The vast majority of people living on Earth "
	+ "live in places with a solar basic income of around 4–5 kWh/m²/day. People who share "
	+ "your Energy Zone face similar challenges as you do, no matter their continent or "
	+ "hemisphere! Pick your location to find out your Energy Zone, and see who your "
	+ "teammates are on the other side of the world!"
)


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		G = get_node_or_null("/root/GhiService") as GhiService

func _ready() -> void:
	G = get_node_or_null("/root/GhiService") as GhiService
	anchors_preset = Control.PRESET_FULL_RECT
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("world_list_listeners")
	_build_ui()
	_geocode.search_done.connect(_on_geocode_hits)
	_geocode.search_failed.connect(_on_geocode_err)
	_geocode.reverse_done.connect(_on_reverse_done)
	_geocode.reverse_failed.connect(_on_reverse_failed)
	_reverse_timer = Timer.new()
	_reverse_timer.one_shot = true
	_reverse_timer.wait_time = REVERSE_DEBOUNCE_S
	_reverse_timer.timeout.connect(_fire_reverse_lookup)
	add_child(_reverse_timer)
	if is_instance_valid(G):
		if not G.ghi_data_ready.is_connected(_refresh_panels):
			G.ghi_data_ready.connect(_refresh_panels)
	if _is_launch_mode():
		visible = true
		# Back at the hub no world is running.
		WorldPaths.clear_active()
		_resolve_maps()
		_run_legacy_migration()
		if _nw_host != null:
			_build_new_world_panel(_nw_host)
		_refresh_worlds_list()
		_refresh_panels()
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		call_deferred("_layout_panel")
	else:
		visible = false


func _is_launch_mode() -> bool:
	return launch_mode == LaunchMode.LAUNCH


## The gear on the hub header: the settings modal with only the pages that
## need no Main (TimelineSettingsPanel.HUB_PAGES). Parented to the hub scene's
## root so it draws over this whole panel.
func _open_hub_settings() -> void:
	if _settings_panel == null or not is_instance_valid(_settings_panel):
		var script := load("res://scenes/ui/timeline_settings_panel.gd") as Script
		if script == null:
			return
		var p := Control.new()
		p.name = "HubSettingsPanel"
		p.set_script(script)
		p.set("hub_mode", true)
		UiScreenLayout.pin_fullscreen(p)
		# On a MODAL CanvasLayer like every other modal: drawn over the hub
		# whatever is added later, and the UI audit knows the hub text under
		# the backdrop is covered on purpose.
		var layer := CanvasLayer.new()
		layer.name = "HubSettingsLayer"
		layer.layer = UITheme.LAYER_MODAL
		var host: Node = get_tree().current_scene if get_tree().current_scene != null else self
		host.add_child(layer)
		layer.add_child(p)
		_settings_panel = p
	if _settings_panel.has_method("open"):
		_settings_panel.call("open")


## The hub's settings modal, if it was ever opened (the harness reads it).
func hub_settings_panel() -> Control:
	return _settings_panel

func _solar_panel_style(bg: Color = Color(0.08, 0.1, 0.14, 0.92), bordered: bool = true) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(8)
	if bordered:
		sb.set_border_width_all(1)
		sb.border_color = Color(0.227, 0.290, 0.420, 0.85)
		sb.shadow_color = Color(0, 0, 0, 0.25)
		sb.shadow_size = 3
	return sb

func _style_line_edit(ed: LineEdit) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.11, 0.96)
	sb.border_color = Color(0.227, 0.290, 0.420, 0.75)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	ed.add_theme_stylebox_override("normal", sb)
	var sb_focus := sb.duplicate() as StyleBoxFlat
	sb_focus.border_color = Color(0.35, 0.55, 0.75, 0.95)
	sb_focus.set_border_width_all(1)
	ed.add_theme_stylebox_override("focus", sb_focus)
	ed.add_theme_color_override("font_color", _TEXT)
	ed.add_theme_color_override("font_placeholder_color", _TEXT_M)

func _style_emphasis_label(lbl: Label, accent: Color = Color(0.92, 0.94, 0.98)) -> void:
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.35))
	lbl.add_theme_constant_override("outline_size", 2)

func _style_population_label(lbl: Label) -> void:
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.88, 0.91, 0.96))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.28))
	lbl.add_theme_constant_override("outline_size", 1)

func _difficulty_for_zone(zid: int) -> String:
	if zid >= 1 and zid < ZONE_DIFFICULTY.size():
		return ZONE_DIFFICULTY[zid]
	return "—"

func _difficulty_line(zid: int) -> String:
	return "Solar Difficulty:  " + _difficulty_for_zone(zid)

func _apply_panel_style(n: Control, bg: Color) -> void:
	if n is PanelContainer:
		(n as PanelContainer).add_theme_stylebox_override("panel", _solar_panel_style(bg, false))

func _style_title_label(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", _PRIMARY)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_font_size_override("font_size", 20)

func _style_section_label(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.55, 0.68, 0.82, 1))
	lbl.add_theme_font_size_override("font_size", 11)

func _style_muted_label(lbl: Label) -> void:
	lbl.add_theme_color_override("font_color", _TEXT_M)

func _style_value_label(lbl: Label, accent: Color = _TEXT) -> void:
	lbl.add_theme_color_override("font_color", accent)

func _style_primary_button(btn: Button) -> void:
	btn.add_theme_color_override("font_color", Color(0.45, 0.95, 0.55, 1))

func _make_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", _solar_panel_style(Color(0.08, 0.1, 0.14, 0.92), false))
	return sep

func _anchor_full_rect(ctrl: Control, inset: float = 0.0) -> void:
	ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	ctrl.offset_left = inset
	ctrl.offset_top = inset
	ctrl.offset_right = -inset
	ctrl.offset_bottom = -inset
	ctrl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ctrl.grow_vertical = Control.GROW_DIRECTION_BOTH

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		call_deferred("_layout_panel")
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		# Every way the picker closes, not only hide_picker().
		HudLayout.release("location_picker")

## Keep split ratio and map aspect in sync after the panel fills the viewport.
func _layout_panel() -> void:
	if _hsplit != null and is_instance_valid(_hsplit) and _hsplit.size.x > 0.0:
		if _is_launch_mode():
			_hsplit.split_offset = int(_hsplit.size.x * 0.58)
		else:
			_hsplit.split_offset = int(_hsplit.size.x * 0.58)
	if _details_scroll != null and _details_root != null and _details_scroll.size.x > 0.0:
		_details_root.custom_minimum_size.x = _details_scroll.size.x
	_deferred_size_map()

func show_picker() -> void:
	visible = true
	if not _is_launch_mode():
		# In a world: the HUD hides under the picker, and the picker stops
		# above the timeline instead of drawing its footer over it.
		HudLayout.claim_modal("location_picker")
		if _panel != null:
			_panel.offset_bottom = -(HudLayout.timeline_height() + 10.0)
	_legend_picked = -1
	_sel_lat = NAN
	_sel_lng = NAN
	_place_label = ""
	_cancel_reverse_lookup()
	_show_coord_note("")
	_geocode_hits.visible = false
	_geocode_error.visible = false
	if is_instance_valid(_map):
		_map.clear_selection()
		_map.set_kml_text("")
		_map.set_focus_zone_id(_compute_map_focus())
	call_deferred("_layout_panel")
	call_deferred("_deferred_size_map")
	_refresh_panels()

func _deferred_size_map() -> void:
	if not is_instance_valid(_map) or not is_instance_valid(_map.get_parent()):
		return
	var c: Control = _map.get_parent() as Control
	if c.size.x <= 0.0:
		return
	var w2: float = maxf(240.0, c.size.x)
	var map_h: float = w2 * 0.5
	# Launch hub also hosts the YOUR WORLDS list + bottom Start/Create row.
	# Cap the world-map min height so those controls stay on-screen.
	if _is_launch_mode() and c.size.y > 1.0:
		const RESERVE_BELOW_MAP := 340.0  # search + coords + maps list + gaps
		map_h = clampf(c.size.y - RESERVE_BELOW_MAP, 140.0, w2 * 0.5)
	_map.custom_minimum_size = Vector2(w2, map_h)

func hide_picker() -> void:
	if _is_launch_mode():
		return
	visible = false
	HudLayout.release("location_picker")
	picker_dismissed.emit()

func _unhandled_input(e: InputEvent) -> void:
	if not visible or not (e is InputEventKey) or not (e as InputEventKey).pressed:
		return
	if (e as InputEventKey).keycode == KEY_ESCAPE:
		# A modal over the hub (Settings, Share…) takes Esc first: this
		# handler runs before the autoloads', so without the guard Esc on the
		# settings modal QUIT the game.
		if CursorController.has_blocking_modal():
			return
		if _is_launch_mode():
			_on_quit_pressed()
		else:
			_close_dismiss()
		get_viewport().set_input_as_handled()

func _compute_map_focus() -> int:
	if _legend_hovered >= 0:
		return _legend_hovered
	if _legend_picked >= 0 and (is_nan(_sel_lat) or is_nan(_sel_lng)):
		return _legend_picked
	if not (is_nan(_sel_lat) or is_nan(_sel_lng)) and is_instance_valid(G):
		return int(G.get_zone(G.ghi_kwh_per_m2_day(_sel_lat, _sel_lng))["id"])
	return -1

func _build_ui() -> void:
	var launch := _is_launch_mode()
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.72) if not launch else _LAUNCH_BG
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	if not launch:
		_dim.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and (e as InputEventMouseButton).pressed: accept_event())
	add_child(_dim)
	_anchor_full_rect(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _solar_panel_style())
	add_child(_panel)
	_anchor_full_rect(_panel, 20.0 if launch else PANEL_INSET)

	_panel_margin = MarginContainer.new()
	_panel_margin.add_theme_constant_override("margin_left", PANEL_MARGIN)
	_panel_margin.add_theme_constant_override("margin_top", PANEL_MARGIN_V)
	_panel_margin.add_theme_constant_override("margin_right", PANEL_MARGIN)
	_panel_margin.add_theme_constant_override("margin_bottom", PANEL_MARGIN_V)
	_panel_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(_panel_margin)

	var vroot: VBoxContainer = VBoxContainer.new()
	vroot.add_theme_constant_override("separation", 8)
	vroot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vroot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_margin.add_child(vroot)

	_geocode = GeocodeClient.new()
	_geocode.name = "Geocode"
	add_child(_geocode)

	if launch:
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 12)
		header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var header_text := VBoxContainer.new()
		header_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header_text.add_theme_constant_override("separation", 2)
		var title_l := Label.new()
		_style_title_label(title_l, "SIMbiogenesis")
		title_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var sub_l := Label.new()
		sub_l.text = "Play one of your worlds, or pick a place on the energy map and start a new one."
		sub_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub_l.add_theme_color_override("font_color", Color(0.392, 0.447, 0.545, 1))
		header_text.add_child(title_l)
		header_text.add_child(sub_l)
		header.add_child(header_text)
		var header_btns := HBoxContainer.new()
		header_btns.alignment = BoxContainer.ALIGNMENT_END
		header_btns.add_theme_constant_override("separation", 8)
		_continue_btn = Button.new()
		_continue_btn.text = "Continue"
		_continue_btn.tooltip_text = "Resume your most recently played world."
		_style_primary_button(_continue_btn)
		_continue_btn.pressed.connect(_on_continue_pressed)
		_quit_btn = Button.new()
		_quit_btn.text = "Quit"
		_quit_btn.pressed.connect(_on_quit_pressed)
		var share_btn := Button.new()
		share_btn.text = "Share…"
		share_btn.tooltip_text = "Export your worlds, models and settings as a zip for a friend, or install one a friend sent you."
		share_btn.pressed.connect(func() -> void: AssetPackModal.open_export(self))
		header_btns.add_child(share_btn)
		# Settings with no world running: graphics presets, UI scale, the
		# player, NPC display, the stars' look, the window wall.
		var gear := IconButton.make("settings", "Settings — graphics, interface, player, NPCs, stars, window wall",
			_open_hub_settings, "", 18)
		gear.name = "HubSettingsButton"
		gear.custom_minimum_size = Vector2(32, 32)
		header_btns.add_child(gear)
		header_btns.add_child(_continue_btn)
		header_btns.add_child(_quit_btn)
		header.add_child(header_btns)
		vroot.add_child(header)
	else:
		var t: Label = Label.new()
		_style_title_label(t, "SIMbiogenesis — Solar Energy Zones")
		vroot.add_child(t)

	vroot.add_child(_make_separator())

	_hsplit = HSplitContainer.new()
	_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hsplit.add_theme_constant_override("separation", 12)
	vroot.add_child(_hsplit)

	var left: VBoxContainer = VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.15
	_hsplit.add_child(left)

	var leg_l: Label = Label.new()
	_style_section_label(leg_l, "SOLAR DIFFICULTY")
	left.add_child(leg_l)
	var leg_h: HBoxContainer = HBoxContainer.new()
	leg_h.add_theme_constant_override("separation", 3)
	leg_h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_instance_valid(G):
		for zd in G.get_zones():
			var bid: int = int(zd["id"])
			var bt: Button = Button.new()
			bt.text = "Zone " + str(bid)
			bt.tooltip_text = _difficulty_for_zone(bid)
			bt.set_meta("zid", bid)
			bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bt.size_flags_stretch_ratio = 1.0
			bt.custom_minimum_size = Vector2(0, 40)
			bt.add_theme_font_size_override("font_size", 11)
			_legend_styling(bt, zd["color"] as Color, bid, false)
			bt.pressed.connect(_on_leg_pressed.bind(bid))
			bt.mouse_entered.connect(_on_leg_in.bind(bid))
			bt.mouse_exited.connect(_on_leg_out)
			leg_h.add_child(bt)
			_legend_buttons.append(bt)
	left.add_child(leg_h)

	_map = WorldMapControl.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map.location_selected.connect(_on_map)
	left.add_child(_map)

	var a_l: Label = Label.new()
	_style_section_label(a_l, "SEARCH LOCATION")
	left.add_child(a_l)
	_address_field = LineEdit.new()
	_address_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address_field.placeholder_text = "Search any address, coordinates, or place on Earth..."
	_style_line_edit(_address_field)
	var arow: HBoxContainer = HBoxContainer.new()
	arow.add_theme_constant_override("separation", 8)
	arow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var b_ad: Button = Button.new()
	b_ad.text = "Search"
	b_ad.pressed.connect(_search_addr)
	_address_field.text_submitted.connect(func(_t: String) -> void: _search_addr())
	arow.add_child(_address_field)
	arow.add_child(b_ad)
	left.add_child(arow)

	_geocode_hits = ItemList.new()
	_geocode_hits.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_geocode_hits.custom_minimum_size = Vector2(0, 88)
	_geocode_hits.visible = false
	_geocode_hits.item_selected.connect(_on_hit_activated)
	left.add_child(_geocode_hits)

	_geocode_error = Label.new()
	_geocode_error.add_theme_color_override("font_color", Color(0.9, 0.45, 0.2))
	_geocode_error.autowrap_mode = TextServer.AUTOWRAP_WORD
	_geocode_error.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_geocode_error.visible = false
	left.add_child(_geocode_error)

	_lat_field = LineEdit.new()
	_lat_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lat_field.placeholder_text = "Latitude"
	_style_line_edit(_lat_field)
	_lng_field = LineEdit.new()
	_lng_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lng_field.placeholder_text = "Longitude"
	_style_line_edit(_lng_field)
	var crow: HBoxContainer = HBoxContainer.new()
	crow.add_theme_constant_override("separation", 8)
	crow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var b_co: Button = Button.new()
	b_co.text = "Use coords"
	b_co.pressed.connect(_use_coords)
	# Typed coordinates take effect on Enter or when the field loses focus —
	# they used to be ignored unless "Use coords" was pressed, so Create built
	# (and overwrote) the PREVIOUS site.
	_lat_field.text_submitted.connect(func(_t: String) -> void: _use_coords())
	_lng_field.text_submitted.connect(func(_t: String) -> void: _use_coords())
	_lat_field.focus_exited.connect(_commit_coord_fields_if_changed)
	_lng_field.focus_exited.connect(_commit_coord_fields_if_changed)
	crow.add_child(_lat_field)
	crow.add_child(_lng_field)
	crow.add_child(b_co)
	left.add_child(crow)
	_coord_note = Label.new()
	_style_muted_label(_coord_note)
	_coord_note.add_theme_font_size_override("font_size", 11)
	_coord_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_coord_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_coord_note.visible = false
	left.add_child(_coord_note)

	if launch:
		left.add_child(_make_separator())
		# Fixed-height scrollable list — expand_fill + large min-height was
		# stealing vertical space from the Start/Create action row below.
		var maps_panel := PanelContainer.new()
		maps_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		maps_panel.size_flags_vertical = Control.SIZE_SHRINK_END
		maps_panel.custom_minimum_size.y = 240.0
		maps_panel.add_theme_stylebox_override("panel", _solar_panel_style(Color(0.06, 0.08, 0.12, 0.9)))
		left.add_child(maps_panel)
		var maps_inner := VBoxContainer.new()
		maps_inner.add_theme_constant_override("separation", 6)
		maps_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		maps_inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var maps_margin := MarginContainer.new()
		maps_margin.add_theme_constant_override("margin_left", 10)
		maps_margin.add_theme_constant_override("margin_right", 10)
		maps_margin.add_theme_constant_override("margin_top", 8)
		maps_margin.add_theme_constant_override("margin_bottom", 8)
		maps_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		maps_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
		maps_panel.add_child(maps_margin)
		maps_margin.add_child(maps_inner)
		var maps_hdr := Label.new()
		_style_section_label(maps_hdr, "YOUR WORLDS")
		maps_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		maps_inner.add_child(maps_hdr)
		var maps_scroll := ScrollContainer.new()
		maps_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		maps_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		maps_scroll.custom_minimum_size.y = 140.0
		maps_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		maps_inner.add_child(maps_scroll)
		_maps_list = VBoxContainer.new()
		_maps_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_maps_list.add_theme_constant_override("separation", 4)
		maps_scroll.add_child(_maps_list)
		_launch_status = Label.new()
		_style_muted_label(_launch_status)
		_launch_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		maps_inner.add_child(_launch_status)

	var right: ScrollContainer = ScrollContainer.new()
	_details_scroll = right
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 0.85
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_hsplit.add_child(right)

	var details_panel := PanelContainer.new()
	details_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_panel.add_theme_stylebox_override("panel", _solar_panel_style(Color(0.06, 0.08, 0.12, 0.92)))
	right.add_child(details_panel)
	var details_margin := MarginContainer.new()
	details_margin.add_theme_constant_override("margin_left", 12)
	details_margin.add_theme_constant_override("margin_right", 12)
	details_margin.add_theme_constant_override("margin_top", 10)
	details_margin.add_theme_constant_override("margin_bottom", 10)
	details_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_panel.add_child(details_margin)

	var rv: VBoxContainer = VBoxContainer.new()
	_details_root = rv
	rv.add_theme_constant_override("separation", 10)
	rv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_margin.add_child(rv)

	if launch:
		_nw_host = VBoxContainer.new()
		_nw_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rv.add_child(_nw_host)
	var details_hdr: Label = Label.new()
	_style_section_label(details_hdr, "ZONE DETAILS")
	details_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rv.add_child(details_hdr)

	_zone_title = Label.new()
	_zone_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	_zone_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_emphasis_label(_zone_title)
	_zone_ghi = Label.new()
	_style_value_label(_zone_ghi, Color(0.75, 0.82, 0.9))
	_zone_ghi.autowrap_mode = TextServer.AUTOWRAP_WORD
	_zone_ghi.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_ghi.add_theme_font_size_override("font_size", 12)
	_zone_pot = Label.new()
	_style_value_label(_zone_pot, Color(0.78, 0.88, 0.98))
	_zone_pot.add_theme_font_size_override("font_size", 14)
	_zone_pot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_narr = RichTextLabel.new()
	_zone_narr.bbcode_enabled = true
	_zone_narr.fit_content = true
	_zone_narr.autowrap_mode = TextServer.AUTOWRAP_WORD
	_zone_narr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_narr.add_theme_color_override("default_color", Color(0.8, 0.82, 0.9))
	_zone_pop = RichTextLabel.new()
	_zone_pop.bbcode_enabled = true
	_zone_pop.fit_content = true
	_zone_pop.scroll_active = false
	_zone_pop.autowrap_mode = TextServer.AUTOWRAP_WORD
	_zone_pop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_pop.add_theme_color_override("default_color", _TEXT)
	_sister = RichTextLabel.new()
	_sister.bbcode_enabled = true
	_sister.fit_content = true
	_sister.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sister.add_theme_color_override("default_color", Color(0.75, 0.8, 0.88))
	_chart = ZonePopulationChart.new()
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.custom_minimum_size = Vector2(240, 180)
	_similar = VBoxContainer.new()
	_similar.add_theme_constant_override("separation", 4)
	_similar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for node in [
		_zone_title, _zone_ghi, _zone_pot, _make_separator(), _zone_narr, _zone_pop,
		_sister, _chart, _make_separator(), _similar,
	]:
		rv.add_child(node)

	vroot.add_child(_make_separator())
	_bundle_status = Label.new()
	_bundle_status.text = ""
	_bundle_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_bundle_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_muted_label(_bundle_status)
	vroot.add_child(_bundle_status)
	var bot: HBoxContainer = HBoxContainer.new()
	bot.alignment = BoxContainer.ALIGNMENT_CENTER
	bot.add_theme_constant_override("separation", 12)
	bot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot.size_flags_vertical = Control.SIZE_SHRINK_END
	bot.custom_minimum_size.y = 40.0
	var import_btn: Button = Button.new()
	import_btn.text = "Add StarShade"
	import_btn.tooltip_text = "Place the V1 StarShade model on the next map load (or begin placement in-game)"
	import_btn.pressed.connect(_on_add_starshade_pressed)
	_close_btn = Button.new()
	_close_btn.text = "Close"
	_close_btn.pressed.connect(_close_dismiss)
	var make: Button = Button.new()
	make.text = "New world here  ⊕"
	make.tooltip_text = ("Start a NEW world on this location: real elevation, satellite imagery, "
		+ "OSM buildings/water and auto-vegetation. Your current world is saved first. "
		+ "First visit to a place: ~15–60 s; cached maps start in seconds.")
	make.pressed.connect(_create_map)
	_confirm_btn = Button.new()
	_confirm_btn.text = "Set location  ✓"
	_style_primary_button(_confirm_btn)
	_confirm_btn.pressed.connect(_confirm)
	if launch:
		_start_btn = Button.new()
		_start_btn.text = "Play selected world"
		_style_primary_button(_start_btn)
		_start_btn.pressed.connect(func() -> void: _play_world(_world_sel_idx))
		bot.add_child(_start_btn)
		bot.add_child(import_btn)
		_close_btn.visible = false
		_confirm_btn.visible = false
	else:
		bot.add_child(import_btn)
		bot.add_child(_close_btn)
		bot.add_child(make)
		bot.add_child(_confirm_btn)
	vroot.add_child(bot)

func _legend_styling(bt: Button, c: Color, _z: int, _s: bool) -> void:
	var is_sel2: bool = (int(_legend_picked) == int(bt.get_meta("zid", -1))) and _legend_picked > 0 and (is_nan(_sel_lat) or is_nan(_sel_lng))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = c
	if is_sel2:
		sb.set_border_color(Color(0.99, 0.62, 0.12))
		sb.set_border_width_all(2)
	else:
		sb.set_border_width_all(1)
		sb.set_border_color(Color(0, 0, 0, 0.25))
	var lum: float = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	var fc: Color = Color(0.1, 0.1, 0.1) if lum > 0.5 else Color(1, 1, 1)
	bt.add_theme_color_override("font_color", fc)
	var sb2: StyleBoxFlat = (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
	(sb2 as StyleBoxFlat).bg_color = c.lightened(0.09)
	for k2 in [ "normal", "hover", "pressed", "focus" ]:
		if k2 == "normal":
			bt.add_theme_stylebox_override(k2, sb)
		elif k2 == "hover":
			bt.add_theme_stylebox_override(k2, sb2)
		else:
			bt.add_theme_stylebox_override(k2, sb2)
	bt.set_meta("bcol", c)

func _on_leg_pressed(bid: int) -> void:
	_legend_picked = bid
	_sel_lat = NAN
	_sel_lng = NAN
	if is_instance_valid(_map):
		_map.clear_selection()
		_map.set_focus_zone_id(bid)
	_refresh_legend()
	_refresh_panels()

func _on_leg_in(bid: int) -> void:
	_legend_hovered = bid
	_update_map_focus()

func _on_leg_out() -> void:
	_legend_hovered = -1
	_update_map_focus()

func _update_map_focus() -> void:
	if is_instance_valid(_map):
		_map.set_focus_zone_id(_compute_map_focus())

func _on_map(lat2: float, lnn2: float) -> void:
	_legend_picked = -1
	_sel_lat = lat2
	_sel_lng = lnn2
	_lat_field.text = str(snappedf(lat2, 0.0001))
	_lng_field.text = str(snappedf(lnn2, 0.0001))
	_on_coords_changed_manually()
	_update_map_focus()
	if is_instance_valid(_map):
		_map.set_selection_lat_lng(lat2, lnn2)
	_refresh_legend()
	_refresh_panels()
	_try_highlight_map_for_coords(lat2, lnn2)

func _search_addr() -> void:
	_geocode_error.visible = false
	_geocode_hits.clear()
	_geocode_hits.visible = false
	_geocode.search(_address_field.text)

func _on_geocode_hits(hits: Array) -> void:
	_last_hits = []
	_geocode_hits.clear()
	_geocode_hits.visible = true
	_geocode_error.visible = false
	if hits.is_empty():
		_geocode_error.text = "No results."
		_geocode_error.visible = true
		_geocode_hits.visible = false
		return
	if hits.size() == 1:
		_apply_from_hit(hits[0] as Dictionary)
		_geocode_hits.visible = false
		return
	for h in hits:
		if h is Dictionary:
			var d: Dictionary = h
			_last_hits.append(d)
			_geocode_hits.add_item(str(d.get("label", "…")))

func _on_geocode_err(m: String) -> void:
	_geocode_error.text = m
	_geocode_error.visible = true
	_geocode_hits.visible = false
	_last_hits = []

func _on_hit_activated(i: int) -> void:
	if i < 0 or i >= _last_hits.size() or not _geocode_hits or i >= _geocode_hits.item_count:
		return
	_apply_from_hit(_last_hits[i])

func _apply_from_hit(d: Dictionary) -> void:
	_legend_picked = -1
	_nw_builtin_idx = -1
	_sel_lat = float(d.get("lat", 0.0))
	_sel_lng = float(d.get("lng", 0.0))
	_place_label = str(d.get("label", ""))
	_address_field.text = _place_label
	_lat_field.text = str(_sel_lat)
	_lng_field.text = str(_sel_lng)
	_cancel_reverse_lookup()
	_show_coord_note("")
	if is_instance_valid(_map):
		_map.set_selection_lat_lng(_sel_lat, _sel_lng)
		_map.set_focus_zone_id(_compute_map_focus())
	_geocode_hits.visible = false
	_refresh_legend()
	_refresh_panels()
	_try_highlight_map_for_coords(_sel_lat, _sel_lng)

## Parse the two coordinate fields. Returns {ok, lat, lng, error}. Accepts a
## "lat, lon" pair pasted into the latitude field. `to_float()` turns garbage
## into 0.0 (never NAN), which used to send bad input to Null Island.
static func parse_coord_fields(lat_text: String, lng_text: String) -> Dictionary:
	var a := lat_text.strip_edges()
	var b := lng_text.strip_edges()
	if b.is_empty() and a.contains(","):
		var parts := a.split(",", false)
		if parts.size() == 2:
			a = parts[0].strip_edges()
			b = parts[1].strip_edges()
	if a.is_empty() or b.is_empty():
		return {"ok": false, "error": "Enter both a latitude and a longitude."}
	if not a.is_valid_float() or not b.is_valid_float():
		return {"ok": false, "error": "Coordinates must be decimal degrees, e.g. 44.0113 and -123.5911."}
	var lat := a.to_float()
	var lng := b.to_float()
	if absf(lat) > 90.0:
		return {"ok": false, "error": "Latitude must be between -90 and 90."}
	if absf(lng) > 180.0:
		return {"ok": false, "error": "Longitude must be between -180 and 180."}
	return {"ok": true, "lat": lat, "lng": lng}


## The fields differ from the current selection by more than display rounding.
func _coord_fields_differ() -> bool:
	var p := parse_coord_fields(_lat_field.text, _lng_field.text)
	if not bool(p.get("ok", false)):
		return not (_lat_field.text.strip_edges().is_empty() and _lng_field.text.strip_edges().is_empty())
	if is_nan(_sel_lat) or is_nan(_sel_lng):
		return true
	return absf(float(p["lat"]) - _sel_lat) > 0.00005 or absf(float(p["lng"]) - _sel_lng) > 0.00005


func _commit_coord_fields_if_changed() -> void:
	if _coord_fields_differ():
		_use_coords()


## Any coordinate change that did NOT come from naming those coordinates
## (a map click, typed fields, Use coords) drops the old name and the stale
## address text, then asks Nominatim what is actually here.
func _on_coords_changed_manually() -> void:
	_nw_builtin_idx = -1
	_place_label = ""
	if _address_field != null:
		_address_field.text = ""
	if _geocode_hits != null:
		_geocode_hits.visible = false
	if not (is_nan(_sel_lat) or is_nan(_sel_lng)):
		_show_coord_note("Looking up the place name…")
		if _reverse_timer != null:
			_reverse_timer.start()


func _cancel_reverse_lookup() -> void:
	if _reverse_timer != null:
		_reverse_timer.stop()


func _fire_reverse_lookup() -> void:
	if is_nan(_sel_lat) or is_nan(_sel_lng) or not _place_label.is_empty():
		return
	_geocode.reverse(_sel_lat, _sel_lng)


func _on_reverse_done(lat: float, lng: float, label: String) -> void:
	# Drop a stale reply: the selection moved, or something else named it.
	if not _place_label.is_empty() or is_nan(_sel_lat) \
			or absf(lat - _sel_lat) > 1e-6 or absf(lng - _sel_lng) > 1e-6:
		return
	_place_label = label
	if _address_field != null:
		_address_field.text = label
	_show_coord_note("")
	_refresh_new_world_panel()


func _on_reverse_failed(lat: float, lng: float, _msg: String) -> void:
	if is_nan(_sel_lat) or absf(lat - _sel_lat) > 1e-6 or absf(lng - _sel_lng) > 1e-6:
		return
	_show_coord_note("No place name found — the coordinates will be used as the name.")


func _show_coord_note(text: String, is_error: bool = false) -> void:
	if _coord_note == null:
		return
	_coord_note.text = text
	_coord_note.visible = not text.is_empty()
	_coord_note.add_theme_color_override("font_color",
		Color(0.95, 0.5, 0.3) if is_error else _TEXT_M)


func _use_coords() -> void:
	var p := parse_coord_fields(_lat_field.text, _lng_field.text)
	if not bool(p.get("ok", false)):
		_show_coord_note(str(p.get("error", "Invalid coordinates.")), true)
		return
	_legend_picked = -1
	var moved := is_nan(_sel_lat) or absf(float(p["lat"]) - _sel_lat) > 1e-7 \
		or absf(float(p["lng"]) - _sel_lng) > 1e-7
	_sel_lat = float(p["lat"])
	_sel_lng = float(p["lng"])
	if moved:
		_on_coords_changed_manually()
	if is_instance_valid(_map):
		_map.set_selection_lat_lng(_sel_lat, _sel_lng)
		_map.set_focus_zone_id(_compute_map_focus())
	_refresh_legend()
	_refresh_panels()
	_try_highlight_map_for_coords(_sel_lat, _sel_lng)

func _close_dismiss() -> void:
	hide_picker()

func _confirm() -> void:
	if is_nan(_sel_lat) or is_nan(_sel_lng):
		return
	location_confirmed.emit(_sel_lat, _sel_lng, _place_label)
	hide_picker()

## Persist a MapDefinition for the selected site and launch the generated world
## scene, which builds real terrain + satellite imagery from open data.
func _create_map() -> void:
	# Typed-but-uncommitted coordinates win over the old selection.
	if _nw_builtin_idx < 0 and _coord_fields_differ():
		_use_coords()
		if _coord_fields_differ():
			return  # invalid input; _use_coords showed why
	var src := _new_world_source()
	if src.is_empty():
		_show_coord_note("Pick a point on the map, search an address, or enter coordinates first.", true)
		return
	var map: Dictionary = src["map"]
	if bool(src["generated"]):
		map = _register_map_definition(map)
	var world_name := _nw_name.text.strip_edges() if _nw_name != null else ""
	var rec := WorldStore.create(map, world_name)
	if bool(src["generated"]) and not _pending_bundle_path.is_empty():
		var prep := BUNDLE_IMPORTER_SCRIPT.queue_for_new_map(
			_pending_bundle_path, float(map["lat"]), float(map["lon"]), str(map["label"]))
		if not bool(prep.get("ok", false)):
			push_warning("LocationPicker: bundle import failed: %s" % str(prep.get("error", "unknown")))
	_pending_bundle_path = ""
	if _bundle_status != null:
		_bundle_status.text = ""
	var refetch := _nw_refetch != null and _nw_refetch.visible and _nw_refetch.button_pressed
	_launch_world(rec, {"force_refetch": refetch})


## The MAP registry: one loc_<lat>_<lon>.tres per site (label + extents), shared
## by every world on it. Re-creating a site keeps its existing name unless this
## selection has a real one, and never resets its extents or OSM offsets.
func _register_map_definition(map: Dictionary) -> Dictionary:
	return MapRegistry.ensure_generated({"lat": map["lat"], "lon": map["lon"], "label": map["label"]},
		not _place_label.is_empty())


func _on_add_starshade_pressed() -> void:
	## Place the catalog V1 StarShade — no LinkageLab bundle dance.
	if _is_launch_mode():
		_pending_starshade = true
		_queue_starshade_design()
		if _bundle_status != null:
			_bundle_status.text = "StarShade queued — create or start a map to place it."
		return
	var main := _find_main_node()
	if main == null:
		if _bundle_status != null:
			_bundle_status.text = "Could not find Main — open a world first."
		return
	var r: Dictionary = PLACED_PROP_SERVICE_SCRIPT.begin_placement(main, "starshade")
	if bool(r.get("ok", false)):
		var loader := main.get_node_or_null("TerrainLoader")
		if loader != null and loader.has_method("notify_external_placement_started"):
			loader.call("notify_external_placement_started", r)
		if _bundle_status != null:
			_bundle_status.text = "StarShade placement active — aim and click to confirm."
		hide_picker()
	else:
		# Fallback: drop at player / origin immediately.
		var placed: Dictionary = PLACED_PROP_SERVICE_SCRIPT.place_model(main, "starshade", true)
		if _bundle_status != null:
			_bundle_status.text = ("StarShade placed." if bool(placed.get("ok", false))
				else "Could not place StarShade.")


func _queue_starshade_design() -> void:
	var dc := get_node_or_null("/root/DesignContext")
	if dc != null and dc.has_method("set_pending"):
		dc.call("set_pending", "starshade", {}, {}, {}, "StarShade", "")


func _find_main_node() -> Node:
	var st := get_tree()
	if st == null:
		return null
	var cur := st.current_scene
	if cur != null and str(cur.name) == "Main":
		return cur
	return st.root.find_child("Main", true, false)

func _refresh_legend() -> void:
	if G == null:
		return
	for bt in _legend_buttons:
		var zid0: int = int(bt.get_meta("zid", 0))
		if zid0 < 1:
			continue
		var c: Color = (G.get_zones()[(zid0 - 1) as int]["color"] as Color) if (zid0 - 1) < G.get_zones().size() else Color.GRAY
		_legend_styling(bt, c, zid0, zid0 == _legend_picked)

func _refresh_panels() -> void:
	_refresh_new_world_panel()
	if G == null:
		return
	_clear_sim()
	if _legend_picked >= 1 and (is_nan(_sel_lat) or is_nan(_sel_lng)):
		_show_legend_only(_legend_picked)
		return
	if is_nan(_sel_lat) or is_nan(_sel_lng):
		_show_welcome_panel()
		return
	var ghi0: float = G.ghi_kwh_per_m2_day(_sel_lat, _sel_lng)
	_show_for_point(ghi0)


func _show_welcome_panel() -> void:
	_zone_title.text = "Planet Earth"
	_zone_ghi.visible = true
	_zone_ghi.text = "Stellar Basic Income: 4.17 billion kWh per day"
	_zone_pot.text = "Welcome, select your energy zone"
	_zone_pot.add_theme_font_size_override("font_size", 15)
	_zone_narr.text = WELCOME_EXPLAINER
	_zone_narr.add_theme_color_override("default_color", Color(0.8, 0.82, 0.9))
	_stop_population_spin()
	_pop_spin_value = 0.0
	_zone_pop.text = ""
	_sister.text = ""
	_sister.visible = false
	_update_population_chart(0)


func _update_population_chart(highlight_zone_id: int) -> void:
	if G == null:
		return
	if G.is_population_data_loaded():
		_chart.set_data(
			G.get_population_by_zone(),
			G.world_population_total(),
			highlight_zone_id,
			G.get_population_year())
	else:
		_chart.set_data({}, 0, 0, 0)

func _show_legend_only(zid0: int) -> void:
	var zd0: Dictionary = G.get_zones()[(zid0 - 1) as int] if zid0 >= 1 and zid0 <= 6 and G.get_zones().size() >= zid0 else {}
	_zone_title.text = str(zd0.get("label", "Zone")) + "  —  " + _difficulty_for_zone(zid0)
	_zone_ghi.visible = false
	_zone_ghi.text = ""
	_zone_narr.text = G.get_zone_narrative(zid0)
	_zone_pot.text = _difficulty_line(zid0)
	_animate_population_to(zid0)
	_update_population_chart(zid0)
	var cts0: Array[Dictionary] = G.find_cities_in_zone(zid0, 5)
	_build_similar_tiles(cts0, true)
	_sister.text = "Sister city (choose a point on the map to compare GHI in the other hemisphere)."

func _zone_color_for_id(zid: int) -> Color:
	if G == null:
		return Color.WHITE
	for z in G.get_zones():
		if int(z["id"]) == zid:
			return z["color"] as Color
	return Color.WHITE

func _format_pop_count(n: int) -> String:
	var s := str(maxi(0, n))
	var out := ""
	for i in range(s.length()):
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return out

func _stop_population_spin() -> void:
	if _pop_spin_tween != null and _pop_spin_tween.is_valid():
		_pop_spin_tween.kill()
	_pop_spin_tween = null

func _update_population_richtext(count: int, pct: int, year: int, zone_id: int) -> void:
	var col := _zone_color_for_id(zone_id)
	var hex := col.to_html(false)
	var count_s := _format_pop_count(count)
	_zone_pop.text = (
		"[font_size=28][b][color=%s]%s[/color][/b][/font_size] "
		+ "[font_size=17][b]people live in this Energy Zone[/b][/font_size] "
		+ "[font_size=16][b](%d%%, %d)[/b][/font_size]"
	) % [hex, count_s, pct, year]

func _on_population_spin_step(v: float) -> void:
	_pop_spin_value = v
	_update_population_richtext(int(roundi(v)), _pop_spin_pct, _pop_spin_year, _pop_spin_zone_id)

func _animate_population_to(zone_id: int) -> void:
	if G == null or not G.is_population_data_loaded():
		_stop_population_spin()
		_zone_pop.text = "[font_size=16][b]Population data loading…[/b][/font_size]"
		return
	var target: int = G.zone_population_by_id(zone_id)
	var w: int = G.world_population_total()
	var pct: int = roundi(100.0 * float(target) / float(w)) if w > 0 else 0
	var year: int = G.get_population_year()
	_pop_spin_zone_id = zone_id
	_pop_spin_pct = pct
	_pop_spin_year = year
	if int(roundi(_pop_spin_value)) == target and _pop_spin_tween == null:
		_update_population_richtext(target, pct, year, zone_id)
		_pop_spin_value = float(target)
		return
	_stop_population_spin()
	var from_v: float = _pop_spin_value
	var delta: float = absf(float(target) - from_v)
	var dur: float = clampf(delta / 2.5e9, 0.5, 1.35)
	_pop_spin_tween = create_tween()
	_pop_spin_tween.set_trans(Tween.TRANS_CUBIC)
	_pop_spin_tween.set_ease(Tween.EASE_OUT)
	_pop_spin_tween.tween_method(_on_population_spin_step, from_v, float(target), dur)
	_pop_spin_tween.tween_callback(func() -> void:
		_pop_spin_value = float(target)
		_update_population_richtext(target, pct, year, zone_id)
		_pop_spin_tween = null
	)

func _show_for_point(ghi0: float) -> void:
	var zd0: Dictionary = G.get_zone(ghi0)
	var zid0: int = int(zd0["id"])
	_zone_title.text = str(zd0.get("label", "")) + "  —  " + _difficulty_for_zone(zid0)
	_zone_ghi.visible = false
	_zone_ghi.text = ""
	_zone_pot.text = _difficulty_line(zid0)
	var ctag: String = (zd0.get("color", Color("#fee090")) as Color).to_html(true)
	_zone_narr.text = "You are in [color=" + ctag + "]" + str(zd0.get("label", "")) + "[/color] — long-term GHI in the " + G.zone_ghi_range_label(zd0) + " kWh/m²/d band. " + G.get_zone_narrative(zid0)
	_zone_narr.add_theme_color_override("default_color", Color(0.8, 0.82, 0.9))
	_animate_population_to(zid0)
	_update_population_chart(zid0)
	var siv: Variant = G.find_sister_city(_sel_lat, ghi0)
	if siv is Dictionary and not (siv as Dictionary).is_empty():
		var sc: Dictionary = siv as Dictionary
		_sister.text = "[b]Sister city[/b]  " + str(sc.get("name", "")) + ", " + str(sc.get("country", "")) + "  —  GHI " + str(sc.get("ghi", 0.0)) + " kWh/m²/d   (opposite-hemisphere catalog match)"
		_sister.visible = true
	else:
		_sister.text = "No sister city in the reference list for the opposite hemisphere."
	_sister.fit_content = true
	var list2: Array[Dictionary] = G.find_similar_cities(ghi0, 5, siv)
	_build_similar_tiles(list2, false)

func _clear_sim() -> void:
	for c in _similar.get_children():
		(c as Node).queue_free()

func _build_similar_tiles(items: Array[Dictionary], from_leg: bool) -> void:
	_clear_sim()
	if items.is_empty():
		var l: Label = Label.new()
		l.text = "No reference cities in this band."
		_similar.add_child(l)
		return
	for it in items:
		var p := PanelContainer.new()
		_apply_panel_style(p, Color(0.04, 0.06, 0.1, 0.95))
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var h := HBoxContainer.new()
		var zg: float = float((it as Dictionary).get("ghi", 0.0))
		var ccol: Color = (G.get_zone(zg).get("color", Color(0.5, 0.5, 0.55)) as Color) if G else Color.GRAY
		var s := ColorRect.new()
		s.color = ccol
		s.custom_minimum_size = Vector2(3, 40)
		h.add_child(s)
		var v := VBoxContainer.new()
		var n1: Label = Label.new()
		var bmatch: bool = bool((it as Dictionary).get("is_closest_match", false))
		var sfx: String = ""
		if bmatch and not from_leg:
			sfx = "  (best match)"
		elif bmatch and from_leg:
			sfx = "  (typical for band)"
		n1.text = str((it as Dictionary).get("name", "")) + sfx
		var n2: Label = Label.new()
		n2.text = str((it as Dictionary).get("country", "")) + "  /  " + str(zg) + " kWh/m²/d"
		n2.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
		v.add_child(n1)
		v.add_child(n2)
		h.add_child(v)
		p.add_child(h)
		_similar.add_child(p)


func _save_game() -> SaveGameService:
	var st := get_tree()
	if st == null:
		return null
	return st.root.get_node_or_null("SaveSystem") as SaveGameService


## A trusted scene path can still be an unplayable OFFER — e.g. a partially
## restored local copy where the outer .tscn is present (see ASSETS.md's
## restore workflow) but the asset pack behind it isn't. Checked in addition to
## (not instead of) is_trusted_scene_path(), which stays a cheap allow-list
## check used elsewhere for save-routing trust.
func _is_offerable(scene_path: String) -> bool:
	return MapDefinition.is_trusted_scene_path(scene_path) \
		and MapDefinition.is_scene_fully_available(MapDefinition.normalize_scene_path(scene_path))


func _resolve_maps() -> void:
	_maps_resolved.clear()
	_maps_file_paths.clear()
	if not maps.is_empty():
		for m in maps:
			if m is MapDefinition and _is_offerable(m.scene_path):
				_maps_resolved.append(m)
				_maps_file_paths.append("")
		_sort_maps_by_recency()
		return
	for p in _DEFAULT_MAP_PATHS:
		var r := load(p)
		if r is MapDefinition:
			var md := r as MapDefinition
			if _is_offerable(md.scene_path):
				_maps_resolved.append(md)
				_maps_file_paths.append("")
	_resolve_user_maps()
	_sort_maps_by_recency()


func _resolve_user_maps() -> void:
	var dir := DirAccess.open(_USER_MAPS_DIR)
	if dir == null:
		return
	for fn in dir.get_files():
		if not fn.ends_with(".tres"):
			continue
		var path := "%s/%s" % [_USER_MAPS_DIR, fn]
		var r := load(path)
		if r is MapDefinition:
			var md := r as MapDefinition
			if _is_offerable(md.scene_path):
				# Heal maps corrupted by CheckBox toggled(false) on list rebuild
				# (force-refetch every Start → load screen stuck at 0%).
				if not md.load_from_cache:
					md.load_from_cache = true
					ResourceSaver.save(md, path)
				_maps_resolved.append(md)
				_maps_file_paths.append(path)


## Most recently Start/Create'd first; never-launched (0) sink to the bottom.
func _sort_maps_by_recency() -> void:
	var n := _maps_resolved.size()
	if n <= 1:
		return
	var order: Array[int] = []
	for i in n:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ta := float(_maps_resolved[a].last_loaded_unix)
		var tb := float(_maps_resolved[b].last_loaded_unix)
		if ta == tb:
			return a < b
		return ta > tb
	)
	var maps_sorted: Array[MapDefinition] = []
	var paths_sorted: Array[String] = []
	for i in order:
		maps_sorted.append(_maps_resolved[i])
		paths_sorted.append(_maps_file_paths[i] if i < _maps_file_paths.size() else "")
	_maps_resolved = maps_sorted
	_maps_file_paths = paths_sorted


func _apply_coords_to_picker(lat: float, lon: float, label: String = "") -> void:
	_legend_picked = -1
	_sel_lat = lat
	_sel_lng = lon
	_place_label = label
	_lat_field.text = str(snappedf(lat, 0.0001))
	_lng_field.text = str(snappedf(lon, 0.0001))
	_cancel_reverse_lookup()
	_show_coord_note("")
	_address_field.text = label
	if is_instance_valid(_map):
		_map.set_selection_lat_lng(lat, lon)
		_map.set_focus_zone_id(_compute_map_focus())
	_refresh_legend()
	_refresh_panels()


## Outline the world rows whose map stands at these coordinates (a visual
## cue only — it never changes the selection or the new-world source).
func _try_highlight_map_for_coords(lat: float, lon: float) -> void:
	if not _is_launch_mode() or _world_row_panels.is_empty():
		return
	for i in _world_recs.size():
		if i >= _world_row_panels.size() or not is_instance_valid(_world_row_panels[i]):
			continue
		var map: Dictionary = _world_recs[i].get("map", {})
		var here := WorldStore.is_generated_map(map) and absf(float(map.get("lat", 0.0)) - lat) <= 0.0005 \
			and absf(float(map.get("lon", 0.0)) - lon) <= 0.0005
		var sb := _world_row_style(i == _world_sel_idx)
		if here and i != _world_sel_idx:
			sb.set_border_width_all(1)
			sb.border_color = Color(_PRIMARY, 0.45)
		_world_row_panels[i].add_theme_stylebox_override("panel", sb)


# ---------------------------------------------------------------------------
# WORLDS — the launch hub lists worlds (a map + everything built on it), most
# recently played first. Maps are the shared, regenerable half; a NEW world on
# a map starts empty without touching any other world on it.
# ---------------------------------------------------------------------------

## One-time, idempotent: every site that already has a build in the old
## one-world-per-site layout becomes a "legacy" world (nothing is moved). The
## old global autosave becomes that world's starting snapshot when it matches.
func _run_legacy_migration() -> void:
	var entries: Array = []
	for i in _maps_resolved.size():
		entries.append({"md": _maps_resolved[i],
			"path": _maps_file_paths[i] if i < _maps_file_paths.size() else ""})
	var autosave := {}
	var sg := _save_game()
	if sg != null and sg.has_autosave():
		autosave = sg.load_autosave()
	var made := WorldStore.migrate_legacy(entries, autosave)
	if not made.is_empty():
		print("LocationPicker: migrated %d existing site(s) into worlds." % made.size())


## Called (group "world_list_listeners") when an asset pack added worlds.
func refresh_world_list() -> void:
	if _maps_list != null:
		_refresh_worlds_list()


func _refresh_worlds_list(select_id: String = "") -> void:
	if _maps_list == null:
		return
	_world_recs = WorldStore.list()
	for c in _maps_list.get_children():
		_maps_list.remove_child(c)
		c.queue_free()
	_world_row_panels.clear()
	_world_sel_idx = -1
	for i in _world_recs.size():
		_maps_list.add_child(_make_world_row(i))
	if _continue_btn != null:
		_continue_btn.disabled = _world_recs.is_empty()
		_continue_btn.tooltip_text = ("Resume “%s” where you left off." % WorldStore.display_name(_world_recs[0])) \
			if not _world_recs.is_empty() else "No worlds yet."
	if _world_recs.is_empty():
		if _launch_status != null:
			_launch_status.text = "No worlds yet — pick a place on the map (or a built-in map) and start a new world."
		_refresh_new_world_panel()
		return
	if _launch_status != null:
		_launch_status.text = ""
	var idx := 0
	if not select_id.is_empty():
		for i in _world_recs.size():
			if str(_world_recs[i].get("id", "")) == select_id:
				idx = i
	_select_world_row(idx)


func _make_world_row(index: int) -> PanelContainer:
	var rec: Dictionary = _world_recs[index]
	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(_on_world_row_gui_input.bind(index))
	row.add_theme_stylebox_override("panel", _world_row_style(false))
	_world_row_panels.append(row)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	row.add_child(h)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(96, 54)
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
	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = SitePrivacy.place(WorldStore.display_name(rec))
	name_lbl.clip_text = true
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.add_theme_color_override("font_color", _TEXT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_lbl)
	var name_edit := LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.visible = false
	name_edit.placeholder_text = _world_map_label(rec)
	_style_line_edit(name_edit)
	name_edit.text_submitted.connect(func(_t: String) -> void: _commit_rename(index))
	name_edit.focus_exited.connect(func() -> void: _commit_rename(index))
	v.add_child(name_edit)
	var sub := Label.new()
	sub.text = _world_subline(rec)
	sub.clip_text = true
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", _TEXT_M)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.tooltip_text = sub.text
	v.add_child(sub)
	var play := Button.new()
	play.text = "Play"
	_style_primary_button(play)
	play.tooltip_text = "Jump back in exactly where you left off."
	play.pressed.connect(_play_world.bind(index))
	h.add_child(play)
	var ren := Button.new()
	ren.text = "Rename"
	ren.pressed.connect(_begin_rename.bind(index))
	h.add_child(ren)
	var dup := Button.new()
	dup.text = "Copy"
	dup.tooltip_text = "Make an independent copy of this world (a checkpoint)."
	dup.pressed.connect(_duplicate_world.bind(index))
	h.add_child(dup)
	var share := Button.new()
	share.text = "Share…"
	share.tooltip_text = "Export this world (and what it needs) as a zip for a friend."
	share.pressed.connect(func() -> void: AssetPackModal.open_export(self, str(rec.get("id", ""))))
	h.add_child(share)
	var del := Button.new()
	del.text = "Delete"
	del.tooltip_text = "Move this world to the trash (user://worlds/_trash). The map's terrain cache is kept."
	del.pressed.connect(_confirm_delete_world.bind(index))
	h.add_child(del)
	return row


func _world_row_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_content_margin_all(6)
	sb.set_corner_radius_all(4)
	if selected:
		sb.bg_color = Color(0.14, 0.28, 0.36, 0.95)
		sb.set_border_width_all(1)
		sb.border_color = _PRIMARY
	else:
		sb.bg_color = Color(0.10, 0.13, 0.18, 0.92)
	return sb


func _world_map_label(rec: Dictionary) -> String:
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var label := str(map.get("label", "")).strip_edges()
	if not label.is_empty():
		return SitePrivacy.place(label)
	return SitePrivacy.place(WorldStore.display_name({"map": map}))


## "location · played 3 h ago · Sep 3 21:30 · 2 h 10 m · ⚡ 4,114"
func _world_subline(rec: Dictionary) -> String:
	var parts: Array[String] = []
	if not str(rec.get("name", "")).strip_edges().is_empty():
		parts.append(_world_map_label(rec))
	var lp := float(rec.get("last_played_unix", 0.0))
	if lp > 0.0:
		parts.append("played " + _relative_time(lp))
	var gt: Dictionary = rec.get("game_time", {}) if rec.get("game_time", {}) is Dictionary else {}
	if int(gt.get("month", 0)) > 0:
		var dt := float(gt.get("day_time", 0.0))
		parts.append("%s %d, %d  %02d:%02d" % [_month_abbr(int(gt["month"])), int(gt.get("day", 1)),
			int(gt.get("year", 0)), int(floor(dt)), int(fmod(dt, 1.0) * 60.0)])
	var pt := float(rec.get("playtime_s", 0.0))
	if pt >= 60.0:
		parts.append("%dh %02dm played" % [int(pt / 3600.0), int(fmod(pt, 3600.0) / 60.0)])
	var sm: Dictionary = rec.get("summary", {}) if rec.get("summary", {}) is Dictionary else {}
	if int(sm.get("peak_total", 0)) > 0:
		parts.append("⚡ %s" % _format_pop_count(int(sm["peak_total"])))
	if str(rec.get("storage", "")) == WorldPaths.STORAGE_LEGACY:
		parts.append("original build")
	return "  ·  ".join(parts)


static func _month_abbr(m: int) -> String:
	const M := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return M[clampi(m - 1, 0, 11)]


static func _relative_time(unix: float) -> String:
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
	return "%s %d, %d" % [_month_abbr(int(dt.month)), int(dt.day), int(dt.year)]


func _on_world_row_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_select_world_row(index)
			if mb.double_click:
				_play_world(index)


func _select_world_row(index: int) -> void:
	if index < 0 or index >= _world_recs.size():
		return
	_world_sel_idx = index
	for i in _world_row_panels.size():
		if is_instance_valid(_world_row_panels[i]):
			_world_row_panels[i].add_theme_stylebox_override("panel", _world_row_style(i == index))
	# The new-world panel follows the selected world's map, so "start fresh on
	# this map" is one click away.
	var map: Dictionary = _world_recs[index].get("map", {})
	if WorldStore.is_generated_map(map):
		_nw_builtin_idx = -1
		_apply_coords_to_picker(float(map.get("lat", 0.0)), float(map.get("lon", 0.0)), str(map.get("label", "")))
	else:
		_nw_builtin_idx = _builtin_index_for_scene(str(map.get("scene_path", "")))
	_refresh_new_world_panel()


func _play_world(index: int) -> void:
	if index < 0 or index >= _world_recs.size():
		return
	_launch_world(_world_recs[index], {})


func _launch_world(rec: Dictionary, opts: Dictionary) -> void:
	if _pending_starshade:
		_queue_starshade_design()
		_pending_starshade = false
	if not _is_launch_mode():
		_save_running_world()
		hide_picker()
	var err := WorldSession.launch(rec, opts)
	if err != OK and _launch_status != null:
		_launch_status.text = "Could not open that world (error %d)." % err


## In-game (overlay) the running world is saved before switching.
func _save_running_world() -> void:
	var main := _find_main_node()
	if main != null and WorldPaths.has_active_world():
		WorldSession.save_now(main, true, true)


func _begin_rename(index: int) -> void:
	if index < 0 or index >= _world_row_panels.size():
		return
	var row := _world_row_panels[index]
	var lbl := row.find_child("Name", true, false) as Label
	var ed := row.find_child("NameEdit", true, false) as LineEdit
	if lbl == null or ed == null:
		return
	ed.text = str(_world_recs[index].get("name", ""))
	lbl.visible = false
	ed.visible = true
	ed.grab_focus()
	ed.select_all()


func _commit_rename(index: int) -> void:
	if index < 0 or index >= _world_row_panels.size():
		return
	var row := _world_row_panels[index]
	var lbl := row.find_child("Name", true, false) as Label
	var ed := row.find_child("NameEdit", true, false) as LineEdit
	if ed == null or not ed.visible:
		return
	ed.visible = false
	var id := str(_world_recs[index].get("id", ""))
	WorldStore.rename(id, ed.text)
	_world_recs[index]["name"] = ed.text.strip_edges()
	if lbl != null:
		lbl.text = SitePrivacy.place(WorldStore.display_name(_world_recs[index]))
		lbl.visible = true


func _duplicate_world(index: int) -> void:
	if index < 0 or index >= _world_recs.size():
		return
	var src: Dictionary = _world_recs[index]
	var copy := WorldStore.duplicate_world(str(src.get("id", "")), "%s (copy)" % WorldStore.display_name(src))
	if copy.is_empty():
		if _launch_status != null:
			_launch_status.text = "Could not copy that world."
		return
	_refresh_worlds_list(str(copy.get("id", "")))
	if _launch_status != null:
		_launch_status.text = "Copied — “%s” is an independent world." % WorldStore.display_name(copy)


func _confirm_delete_world(index: int) -> void:
	if index < 0 or index >= _world_recs.size():
		return
	var rec: Dictionary = _world_recs[index]
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete world"
	dlg.dialog_text = ("Move “%s” to the trash?\n\nIts files are kept in user://worlds/_trash, "
		+ "and the map's terrain cache is not touched.") % WorldStore.display_name(rec)
	dlg.ok_button_text = "Move to trash"
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		var ok := WorldStore.trash(str(rec.get("id", "")))
		_refresh_worlds_list()
		if _launch_status != null:
			_launch_status.text = "Moved to trash." if ok else "Could not delete that world."
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered()


func _on_continue_pressed() -> void:
	if _world_recs.is_empty():
		_world_recs = WorldStore.list()
	if _world_recs.is_empty():
		if _launch_status != null:
			_launch_status.text = "No worlds yet."
		return
	_launch_world(_world_recs[0], {})


# -- New world panel ------------------------------------------------------------

func _build_new_world_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _solar_panel_style(Color(0.07, 0.11, 0.15, 0.95)))
	parent.add_child(panel)
	var m := MarginContainer.new()
	for k in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		m.add_theme_constant_override(k, 10)
	panel.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	m.add_child(v)
	var hdr := Label.new()
	_style_section_label(hdr, "NEW WORLD")
	v.add_child(hdr)
	_nw_source_lbl = Label.new()
	_nw_source_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nw_source_lbl.add_theme_font_size_override("font_size", 15)
	_nw_source_lbl.add_theme_color_override("font_color", _TEXT)
	v.add_child(_nw_source_lbl)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 6)
	v.add_child(bh)
	var bl := Label.new()
	bl.text = "or a built-in map:"
	_style_muted_label(bl)
	bh.add_child(bl)
	_nw_builtin_btns.clear()
	for i in _maps_resolved.size():
		var md: MapDefinition = _maps_resolved[i]
		if md.is_generated():
			continue
		var b := Button.new()
		b.text = md.display_name
		b.toggle_mode = true
		b.pressed.connect(func() -> void:
			_nw_builtin_idx = i if _nw_builtin_idx != i else -1
			_refresh_new_world_panel())
		b.set_meta("map_idx", i)
		bh.add_child(b)
		_nw_builtin_btns.append(b)
	_nw_status_lbl = Label.new()
	_nw_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nw_status_lbl.add_theme_font_size_override("font_size", 12)
	_style_muted_label(_nw_status_lbl)
	v.add_child(_nw_status_lbl)
	_nw_name = LineEdit.new()
	_nw_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_line_edit(_nw_name)
	_nw_name.text_submitted.connect(func(_t: String) -> void: _create_map())
	v.add_child(_nw_name)
	_nw_refetch = CheckBox.new()
	_nw_refetch.text = "Re-download map data (terrain, imagery, OSM)"
	_nw_refetch.toggled.connect(func(_on: bool) -> void: _refresh_new_world_panel())
	v.add_child(_nw_refetch)
	_nw_warn_lbl = Label.new()
	_nw_warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nw_warn_lbl.add_theme_font_size_override("font_size", 11)
	_nw_warn_lbl.add_theme_color_override("font_color", Color(0.95, 0.72, 0.35))
	v.add_child(_nw_warn_lbl)
	_nw_start_btn = Button.new()
	_nw_start_btn.text = "Start new world  ⊕"
	_style_primary_button(_nw_start_btn)
	_nw_start_btn.tooltip_text = ("A new world starts EMPTY on this map. Existing worlds on the same "
		+ "map are not touched.")
	_nw_start_btn.pressed.connect(_create_map)
	v.add_child(_nw_start_btn)
	_refresh_new_world_panel()


func _builtin_index_for_scene(scene_path: String) -> int:
	var want := MapDefinition.normalize_scene_path(scene_path)
	for i in _maps_resolved.size():
		if not _maps_resolved[i].is_generated() \
				and MapDefinition.normalize_scene_path(_maps_resolved[i].scene_path) == want:
			return i
	return -1


## The map a new world would be built on: {map, generated, label} or {}.
func _new_world_source() -> Dictionary:
	if _nw_builtin_idx >= 0 and _nw_builtin_idx < _maps_resolved.size():
		var md: MapDefinition = _maps_resolved[_nw_builtin_idx]
		return {"map": WorldStore.map_ref_from_definition(md, ""), "generated": false, "label": md.display_name}
	if is_nan(_sel_lat) or is_nan(_sel_lng):
		return {}
	var label := _place_label if not _place_label.is_empty() else "%.4f, %.4f" % [_sel_lat, _sel_lng]
	return {"map": {"scene_path": MapDefinition.GENERATED_SCENE, "lat": _sel_lat, "lon": _sel_lng,
		"label": label}, "generated": true, "label": label}


func _refresh_new_world_panel() -> void:
	if _nw_source_lbl == null:
		return
	for b in _nw_builtin_btns:
		if is_instance_valid(b):
			b.set_pressed_no_signal(int(b.get_meta("map_idx", -2)) == _nw_builtin_idx)
	var src := _new_world_source()
	if src.is_empty():
		_nw_source_lbl.text = "Pick a place on the map, search an address, or enter coordinates."
		_nw_status_lbl.text = ""
		_nw_name.placeholder_text = "World name"
		_nw_refetch.visible = false
		_nw_warn_lbl.text = ""
		_nw_start_btn.disabled = true
		return
	_nw_start_btn.disabled = false
	var map: Dictionary = src["map"]
	_nw_source_lbl.text = SitePrivacy.place(str(src["label"]))
	_nw_name.placeholder_text = "World name (default: %s)" % str(src["label"])
	var others := WorldStore.worlds_on_map(map).size()
	var bits: Array[String] = []
	if bool(src["generated"]):
		var lat := float(map["lat"])
		var lon := float(map["lon"])
		var cached := TerrainCacheSettings.has_warm_cache(lat, lon)
		if cached:
			var meta_path := "user://terrain_cache/extents_%s.json" % TerrainCacheSettings.coord_token(lat, lon)
			var when := ""
			if FileAccess.file_exists(meta_path):
				when = " (downloaded %s)" % _relative_time(float(FileAccess.get_modified_time(meta_path)))
			bits.append("Map data cached%s — starts in seconds." % when)
		else:
			bits.append("Map data not downloaded yet — the first start fetches terrain, imagery and OSM (~15–60 s).")
		_nw_refetch.visible = cached
	else:
		bits.append("Built-in map.")
		_nw_refetch.visible = false
	if others > 0:
		bits.append("%d world%s already on this map — a new one starts empty and leaves %s untouched." % [
			others, "" if others == 1 else "s", "it" if others == 1 else "them"])
	_nw_status_lbl.text = "  ".join(bits)
	if _nw_refetch.visible and _nw_refetch.button_pressed:
		_nw_warn_lbl.text = ("Re-downloads this map's terrain, imagery and OSM features. %s"
			% ("Worlds already on this map will load the refreshed terrain; their builds are kept."
				if others > 0 else ""))
	else:
		_nw_warn_lbl.text = ""


func _on_quit_pressed() -> void:
	var ssc := get_node_or_null("/root/SimSettingsController")
	if ssc != null and ssc.has_method("persist_settings"):
		ssc.persist_settings()
	get_tree().quit()