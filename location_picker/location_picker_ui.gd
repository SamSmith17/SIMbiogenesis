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
var _place_label: String = ""

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
var _bundle_status: Label = null
var _bundle_file_dialog: FileDialog = null
var _maps_resolved: Array[MapDefinition] = []
var _maps_list: ItemList = null
var _launch_status: Label = null
var _continue_btn: Button = null
var _start_btn: Button = null
var _quit_btn: Button = null
var _close_btn: Button = null
var _confirm_btn: Button = null
var _syncing_map_list: bool = false

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
const DESIGN_BUNDLE_SCRIPT := preload("res://core/linkagelab/design_bundle.gd")

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
	_build_ui()
	_geocode.search_done.connect(_on_geocode_hits)
	_geocode.search_failed.connect(_on_geocode_err)
	if is_instance_valid(G):
		if not G.ghi_data_ready.is_connected(_refresh_panels):
			G.ghi_data_ready.connect(_refresh_panels)
	if _is_launch_mode():
		visible = true
		_resolve_maps()
		_refresh_maps_list()
		_refresh_panels()
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		call_deferred("_layout_panel")
	else:
		visible = false


func _is_launch_mode() -> bool:
	return launch_mode == LaunchMode.LAUNCH

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
	_legend_picked = -1
	_sel_lat = NAN
	_sel_lng = NAN
	_place_label = ""
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
	_map.custom_minimum_size = Vector2(w2, w2 * 0.5)

func hide_picker() -> void:
	if _is_launch_mode():
		return
	visible = false
	picker_dismissed.emit()

func _unhandled_input(e: InputEvent) -> void:
	if not visible or not (e is InputEventKey) or not (e as InputEventKey).pressed:
		return
	if (e as InputEventKey).keycode == KEY_ESCAPE:
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
		sub_l.text = "Pick a site on the energy map, open a saved world, or continue your last session."
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
		_continue_btn.tooltip_text = "Load latest autosave or newest manual slot."
		_style_primary_button(_continue_btn)
		_continue_btn.pressed.connect(_on_continue_pressed)
		var sg := _save_game()
		if sg == null or not sg.can_continue():
			_continue_btn.disabled = true
		_quit_btn = Button.new()
		_quit_btn.text = "Quit"
		_quit_btn.pressed.connect(_on_quit_pressed)
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
	crow.add_child(_lat_field)
	crow.add_child(_lng_field)
	crow.add_child(b_co)
	left.add_child(crow)

	if launch:
		left.add_child(_make_separator())
		var maps_panel := PanelContainer.new()
		maps_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		maps_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
		maps_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		maps_inner.add_child(maps_scroll)
		_maps_list = ItemList.new()
		_maps_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_maps_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_maps_list.item_selected.connect(_on_map_list_selected)
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
	var import_btn: Button = Button.new()
	import_btn.text = "Import StarShade design…"
	import_btn.tooltip_text = "Load a LinkageLab .gamebundle.json, then pick a location and create the map"
	import_btn.pressed.connect(_on_import_bundle_pressed)
	_close_btn = Button.new()
	_close_btn.text = "Close"
	_close_btn.pressed.connect(_close_dismiss)
	var make: Button = Button.new()
	make.text = "Create map here  ⊕"
	make.tooltip_text = ("Build a playable world with real elevation, satellite imagery, "
		+ "OSM buildings/water, and auto-vegetation. First visit: ~15–60 s depending on "
		+ "network; repeat visits use local cache (~5–15 s).")
	make.pressed.connect(_create_map)
	_confirm_btn = Button.new()
	_confirm_btn.text = "Set location  ✓"
	_style_primary_button(_confirm_btn)
	_confirm_btn.pressed.connect(_confirm)
	if launch:
		_start_btn = Button.new()
		_start_btn.text = "Start selected"
		_style_primary_button(_start_btn)
		_start_btn.pressed.connect(_on_start_pressed)
		bot.add_child(_start_btn)
		bot.add_child(make)
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
	_place_label = ""
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
	_sel_lat = float(d.get("lat", 0.0))
	_sel_lng = float(d.get("lng", 0.0))
	_place_label = str(d.get("label", ""))
	_address_field.text = _place_label
	_lat_field.text = str(_sel_lat)
	_lng_field.text = str(_sel_lng)
	if is_instance_valid(_map):
		_map.set_selection_lat_lng(_sel_lat, _sel_lng)
		_map.set_focus_zone_id(_compute_map_focus())
	_geocode_hits.visible = false
	_refresh_legend()
	_refresh_panels()
	_try_highlight_map_for_coords(_sel_lat, _sel_lng)

func _use_coords() -> void:
	_legend_picked = -1
	_sel_lat = str(_lat_field.text).to_float()
	_sel_lng = str(_lng_field.text).to_float()
	if is_nan(_sel_lat) or is_nan(_sel_lng):
		return
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
	if is_nan(_sel_lat) or is_nan(_sel_lng):
		return
	var label := _place_label if _place_label != "" else "%.4f, %.4f" % [_sel_lat, _sel_lng]
	var md := MapDefinition.new()
	md.scene_path = MapDefinition.GENERATED_SCENE
	md.display_name = label
	md.description = "User-created location map for %s.\nTerrain + imagery from open data." % label
	md.latitude = _sel_lat
	md.longitude = _sel_lng
	md.half_extent_m = 0.0  # TerrainLoader default (~30 km square)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	# Key the file by coordinates so re-creating the same spot updates in place.
	var path := "user://maps/loc_%s_%s.tres" % [_coord_token(_sel_lat), _coord_token(_sel_lng)]
	if ResourceSaver.save(md, path) != OK:
		push_warning("LocationPicker: could not write %s" % path)

	if not _pending_bundle_path.is_empty():
		var prep := BUNDLE_IMPORTER_SCRIPT.queue_for_new_map(
			_pending_bundle_path, _sel_lat, _sel_lng, label)
		if not bool(prep.get("ok", false)):
			push_warning("LocationPicker: bundle import failed: %s" % str(prep.get("error", "unknown")))
			var ctx := get_node_or_null("/root/MapContext")
			if ctx != null:
				ctx.set_pending(_sel_lat, _sel_lng, label, 0.0)
	else:
		var ctx := get_node_or_null("/root/MapContext")
		if ctx != null:
			ctx.set_pending(_sel_lat, _sel_lng, label, 0.0)
	_pending_bundle_path = ""
	if _bundle_status != null:
		_bundle_status.text = ""
	if not _is_launch_mode():
		hide_picker()
	get_tree().change_scene_to_file(MapDefinition.GENERATED_SCENE)


func _on_import_bundle_pressed() -> void:
	if _bundle_file_dialog == null:
		_bundle_file_dialog = FileDialog.new()
		_bundle_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_bundle_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_bundle_file_dialog.filters = PackedStringArray([
			"*.gamebundle.json ; LinkageLab Game Bundle",
			"*.json ; JSON",
		])
		_bundle_file_dialog.title = "Import StarShade Design"
		_bundle_file_dialog.size = Vector2i(900, 600)
		_bundle_file_dialog.file_selected.connect(_on_bundle_file_selected)
		add_child(_bundle_file_dialog)
	_bundle_file_dialog.popup_centered_ratio(0.6)


func _on_bundle_file_selected(path: String) -> void:
	var loaded: Dictionary = DESIGN_BUNDLE_SCRIPT.load_from_path(path)
	if not bool(loaded.get("ok", false)):
		if _bundle_status != null:
			_bundle_status.text = "Import failed: %s" % str(loaded.get("error", "unknown"))
		return
	_pending_bundle_path = path
	if _bundle_status != null:
		_bundle_status.text = ("Design loaded: %s — pick a location, then Create map here."
			% str(loaded.get("name", path.get_file())))
	var loc: Dictionary = loaded.get("location", {}) as Dictionary
	var lat_v: Variant = loc.get("latitude", null)
	var lon_v: Variant = loc.get("longitude", null)
	if lat_v != null and lon_v != null:
		_sel_lat = float(lat_v)
		_sel_lng = float(lon_v)
		if is_instance_valid(_map):
			_map.set_selection_lat_lng(_sel_lat, _sel_lng)
			_map.set_focus_zone_id(_compute_map_focus())
		_refresh_legend()
		_refresh_panels()

## Filename-safe token for a coordinate, e.g. -122.3321 -> "n122p3321".
static func _coord_token(v: float) -> String:
	var s := "%.4f" % absf(v)
	return ("n" if v < 0.0 else "") + s.replace(".", "p")

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
	_zone_ghi.text = "Stellar Basic Income: 4.167 billion kWh per day"
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


func _resolve_maps() -> void:
	_maps_resolved.clear()
	if not maps.is_empty():
		for m in maps:
			if m is MapDefinition and MapDefinition.is_trusted_scene_path(m.scene_path):
				_maps_resolved.append(m)
		return
	for p in _DEFAULT_MAP_PATHS:
		var r := load(p)
		if r is MapDefinition:
			var md := r as MapDefinition
			if MapDefinition.is_trusted_scene_path(md.scene_path):
				_maps_resolved.append(md)
	_resolve_user_maps()


func _resolve_user_maps() -> void:
	var dir := DirAccess.open(_USER_MAPS_DIR)
	if dir == null:
		return
	for fn in dir.get_files():
		if not fn.ends_with(".tres"):
			continue
		var r := load("%s/%s" % [_USER_MAPS_DIR, fn])
		if r is MapDefinition:
			var md := r as MapDefinition
			if MapDefinition.is_trusted_scene_path(md.scene_path):
				_maps_resolved.append(md)


func _refresh_maps_list() -> void:
	if _maps_list == null:
		return
	_maps_list.clear()
	for i in _maps_resolved.size():
		var m: MapDefinition = _maps_resolved[i]
		_maps_list.add_item(m.display_name)
	if _maps_resolved.is_empty():
		if _launch_status != null:
			_launch_status.text = "No saved worlds yet — click the map and press Create map here."
		return
	if _launch_status != null:
		_launch_status.text = ""
	_maps_list.select(0)
	_on_map_list_selected(0)


func _on_map_list_selected(index: int) -> void:
	if index < 0 or index >= _maps_resolved.size():
		return
	var m: MapDefinition = _maps_resolved[index]
	if m.is_generated() and not _syncing_map_list:
		_syncing_map_list = true
		_apply_coords_to_picker(m.latitude, m.longitude, m.display_name)
		_syncing_map_list = false


func _apply_coords_to_picker(lat: float, lon: float, label: String = "") -> void:
	_legend_picked = -1
	_sel_lat = lat
	_sel_lng = lon
	_place_label = label
	_lat_field.text = str(snappedf(lat, 0.0001))
	_lng_field.text = str(snappedf(lon, 0.0001))
	if label != "":
		_address_field.text = label
	if is_instance_valid(_map):
		_map.set_selection_lat_lng(lat, lon)
		_map.set_focus_zone_id(_compute_map_focus())
	_refresh_legend()
	_refresh_panels()


func _try_highlight_map_for_coords(lat: float, lon: float) -> void:
	if not _is_launch_mode() or _maps_list == null or _syncing_map_list:
		return
	var idx := _find_map_index_for_coords(lat, lon)
	if idx >= 0:
		_syncing_map_list = true
		_maps_list.select(idx)
		_on_map_list_selected(idx)
		_syncing_map_list = false


func _find_map_index_for_coords(lat: float, lon: float) -> int:
	const EPS := 0.0005
	for i in _maps_resolved.size():
		var m: MapDefinition = _maps_resolved[i]
		if not m.is_generated():
			continue
		if absf(m.latitude - lat) <= EPS and absf(m.longitude - lon) <= EPS:
			return i
	return -1


func _on_start_pressed() -> void:
	if _maps_list == null:
		return
	var sel := _maps_list.get_selected_items()
	if sel.is_empty():
		if _launch_status != null:
			_launch_status.text = "Select a world from the list, or create one on the map."
		return
	var idx := int(sel[0])
	if idx < 0 or idx >= _maps_resolved.size():
		return
	var md: MapDefinition = _maps_resolved[idx]
	var path: String = md.scene_path.strip_edges()
	if not MapDefinition.is_trusted_scene_path(path):
		if _launch_status != null:
			_launch_status.text = "Invalid map path."
		return
	if md.is_generated():
		var ctx := get_node_or_null("/root/MapContext")
		if ctx != null:
			ctx.set_pending(md.latitude, md.longitude, md.display_name, md.half_extent_m)
	var path_file := MapDefinition.resolve_playable_scene_path(MapDefinition.normalize_scene_path(path))
	var err := get_tree().change_scene_to_file(path_file)
	if err != OK and _launch_status != null:
		_launch_status.text = "Could not load scene (error %d)." % err


func _on_continue_pressed() -> void:
	var sg := _save_game()
	if sg == null:
		if _launch_status != null:
			_launch_status.text = "Save system not available."
		return
	var data := sg.load_continue_payload()
	if data.is_empty() or not sg.validate_payload(data):
		if _launch_status != null:
			_launch_status.text = "No valid save to continue."
		return
	var want := MapDefinition.normalize_scene_path(str(data.get("scene_path", "")).strip_edges())
	if not MapDefinition.is_trusted_scene_path(want):
		want = MapDefinition.snapshot_scene_path(self)
	var want_file := MapDefinition.resolve_playable_scene_path(want)
	var payload := data.duplicate(true)
	payload["scene_path"] = want
	sg.set_pending_resume_payload(payload)
	if MapDefinition.normalize_scene_path(want) == MapDefinition.GENERATED_SCENE:
		var m: Dictionary = data.get("main", {}) as Dictionary
		var ctx := get_node_or_null("/root/MapContext")
		if ctx != null:
			ctx.set_pending(float(m.get("latitude", 0.0)), float(m.get("longitude", 0.0)),
				"", 0.0, true)
	var err := get_tree().change_scene_to_file(want_file)
	if err != OK:
		sg.clear_pending_resume_payload()
		if _launch_status != null:
			_launch_status.text = "Could not load saved map (error %d)." % err


func _on_quit_pressed() -> void:
	get_tree().quit()