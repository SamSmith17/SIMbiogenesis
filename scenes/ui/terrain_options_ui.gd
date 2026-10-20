extends PanelContainer

## Runtime toggles for generated-map terrain: road/site leveling, OSM buildings,
## cache use, auto-vegetation, and per-layer cache refresh. Collapsed by default.

signal expanded_changed(on: bool)

const C_OK := Color(0.15, 0.90, 0.47, 1.0)
const C_BUSY := Color(0.95, 0.78, 0.22, 1.0)
const C_ERR := Color(0.95, 0.35, 0.35, 1.0)
const C_MUTED := Color(0.58, 0.64, 0.72, 1.0)

var _loader: Node = null
var _expanded := false
var _toggle_btn: Button = null
var _body: VBoxContainer = null
var _roads_cb: CheckBox = null
var _sites_cb: CheckBox = null
var _buildings_cb: CheckBox = null
var _water_cb: CheckBox = null
var _camps_cb: CheckBox = null
var _exclusion_r_spin: SpinBox = null
var _auto_veg_cb: CheckBox = null
var _show_veg_cb: CheckBox = null
var _near_detail_cb: CheckBox = null
## Points of interest (KML pins): the list, its toggle, dialogs.
## The body scrolls: the column outgrew the 620 px it was designed for long
## ago (measured 1500 px with the KML block), and a PanelContainer anchored
## top-right simply grows off the bottom of the screen.
var _scroll: ScrollContainer = null
var _poi_list: VBoxContainer = null
var _poi_title: Label = null
var _poi_show_cb: CheckBox = null
var _poi_empty_lbl: Label = null
var _poi_dialog: FileDialog = null
var _poi_clear_confirm: ConfirmationDialog = null
var _auto_veg_density_spin: SpinBox = null
var _cache_cb: CheckBox = null
var _status_lbl: Label = null

const CONFIG_PATH := "user://terrain_config.cfg"
var _refresh_btns: Array[Button] = []
var _reset_confirm: ConfirmationDialog = null
var _veg_style_confirm: ConfirmationDialog = null
## Earlier vegetation looks of this world (VegLookBackup), newest first.
var _veg_backup_opt: OptionButton = null
var _veg_backup_btn: Button = null
var _veg_backup_dirs: Array = []
var _veg_backup_confirm: ConfirmationDialog = null
var _osm_offset_lbl: Label = null
## The three size boxes hold SIDE lengths in km (edge to edge, what the
## loading screen prints); the loader stores half-extents. Convert only through
## TerrainExtents.half_from_side / side_from_half.
var _world_km_spin: SpinBox = null
var _detail_km_spin: SpinBox = null
var _osm_km_spin: SpinBox = null
var _extent_summary_lbl: Label = null
var _extent_hint_lbl: Label = null
var _dem_status_lbl: Label = null
var _extent_apply_confirm: ConfirmationDialog = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	size = Vector2(PANEL_W, COLLAPSED_H)
	_build_ui()
	_apply_collapsed_size()
	# Placement: the HUD layout manager's top-right column (a dock or tool
	# that claims the right edge tucks this into a pill).
	HudLayout.register(self, "terrain_options", "top_right", {
		"order": 0, "priority": 2, "title": "terrain options", "icon": "mountain",
		# The real minimum width, never less than the design width: a row
		# that outgrows 260 px must widen the slot, not hang off the screen.
		"size": func() -> Vector2: return Vector2(maxf(PANEL_W, get_combined_minimum_size().x), _wanted_height()),
		"compact": func() -> String: return "Terrain options",
	})


func bind_loader(loader: Node) -> void:
	_loader = loader
	if _loader != null and _loader.has_signal("options_status_changed"):
		if not _loader.options_status_changed.is_connected(_on_loader_status):
			_loader.options_status_changed.connect(_on_loader_status)
	_sync_from_loader()
	_maybe_opentopo_hint()


func set_status(msg: String, kind: String = "info") -> void:
	if _status_lbl == null:
		return
	_status_lbl.text = msg
	match kind:
		"ok":
			_status_lbl.add_theme_color_override("font_color", C_OK)
		"busy":
			_status_lbl.add_theme_color_override("font_color", C_BUSY)
		"error":
			_status_lbl.add_theme_color_override("font_color", C_ERR)
		_:
			_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_set_refresh_busy(kind == "busy")


func toggle_expanded() -> void:
	_set_expanded(not _expanded)


func _set_expanded(on: bool) -> void:
	_expanded = on
	if _scroll != null:
		_scroll.visible = on
	if _body != null:
		_body.visible = on
	if _toggle_btn != null:
		_toggle_btn.text = "▾ Terrain options" if on else "▸ Terrain options"
	if on:
		# Pins can arrive outside this panel (a harness / another UI calling the
		# loader's import), so the list is rebuilt every time the panel opens.
		_refresh_poi_list()
		_refresh_veg_backups()
	_apply_collapsed_size()
	expanded_changed.emit(on)


const PANEL_W := 260.0
const COLLAPSED_H := 40.0
const HEADER_H := 60.0


## As tall as the content wants (expanded), but never past the HUD's usable
## height above the timeline — the scroll container carries the rest.
func _wanted_height() -> float:
	if not _expanded:
		return COLLAPSED_H
	var want := HEADER_H + (_body.get_combined_minimum_size().y if _body != null else 560.0)
	var max_h := maxf(220.0, HudLayout.usable_rect().size.y)
	return minf(want, max_h)


func _apply_collapsed_size() -> void:
	var h := _wanted_height()
	size = Vector2(PANEL_W, h)
	if _scroll != null:
		_scroll.custom_minimum_size = Vector2(0.0, maxf(120.0, h - HEADER_H)) if _expanded else Vector2.ZERO


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	var header := HBoxContainer.new()
	col.add_child(header)
	_toggle_btn = Button.new()
	_toggle_btn.text = "▸ Terrain options"
	_toggle_btn.flat = true
	_toggle_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toggle_btn.pressed.connect(_on_toggle_pressed)
	header.add_child(_toggle_btn)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.visible = false
	col.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)

	# FIRST in the body: the panel is a top-right box with no scrolling, so
	# anything near the bottom of this long column falls off a 720p / 1080p
	# screen (the KML import was unfindable down there).
	_build_poi_ui(_body)

	_roads_cb = _add_toggle(_body, "Flatten roads",
		"Level highway corridors on the hi-res DEM grid (the hi-res patch only)", _on_roads_toggled)
	_sites_cb = _add_toggle(_body, "Flatten sites / parking",
		"Level landuse polygons (parking, industrial yards)", _on_sites_toggled)
	_buildings_cb = _add_toggle(_body, "Show OSM buildings",
		"Extrude building footprints inside the hi-res DEM square", _on_buildings_toggled)
	_water_cb = _add_toggle(_body, "Show OSM water",
		"Drape rivers and lakes on terrain", _on_water_toggled)
	_camps_cb = _add_toggle(_body, "Generate BRC camps",
		"Procedurally populate Black Rock City street blocks with camps and lights", _on_camps_toggled)
	var camps_row := HBoxContainer.new()
	_body.add_child(camps_row)
	var camps_edit_btn := Button.new()
	camps_edit_btn.text = "🏕 Street camps (Shift+C)"
	camps_edit_btn.tooltip_text = "Open the camp scatter UI (also C key)"
	camps_edit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camps_edit_btn.pressed.connect(_on_camps_edit_pressed)
	camps_row.add_child(camps_edit_btn)

	# Playa exclusion radius row.
	var excl_row := HBoxContainer.new()
	excl_row.add_theme_constant_override("separation", 6)
	_body.add_child(excl_row)
	var excl_lbl := Label.new()
	excl_lbl.text = "Playa excl."
	excl_lbl.tooltip_text = "Block radius from city centre (the Man) where no camps spawn. 0.5 mi ≈ 804 m covers the open playa."
	excl_lbl.add_theme_color_override("font_color", Color(0.58, 0.64, 0.72))
	excl_lbl.add_theme_font_size_override("font_size", 11)
	excl_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	excl_row.add_child(excl_lbl)
	_exclusion_r_spin = SpinBox.new()
	_exclusion_r_spin.min_value = 0.0
	_exclusion_r_spin.max_value = 2.0
	_exclusion_r_spin.step = 0.05
	_exclusion_r_spin.value = 0.5
	_exclusion_r_spin.suffix = " mi"
	_exclusion_r_spin.tooltip_text = "Exclusion radius in miles (0 = auto-detect from road network)"
	_exclusion_r_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exclusion_r_spin.value_changed.connect(_on_exclusion_r_changed)
	excl_row.add_child(_exclusion_r_spin)

	_show_veg_cb = _add_toggle(_body, "Show vegetation",
		"Show or hide ALL plants: painted trees and shrubs, the forest generated "
		+ "from OSM, stumps and logs, and the moss and leaf litter on the ground. "
		+ "Hiding keeps everything; turn it back on and it returns as it was.",
		_on_show_veg_toggled)
	_auto_veg_cb = _add_toggle(_body, "Auto-scatter vegetation",
		"Fill forest/grass OSM polygons with procedural trees (OSM radius)", _on_auto_veg_toggled)
	
	var veg_row := HBoxContainer.new()
	veg_row.add_theme_constant_override("separation", 6)
	_body.add_child(veg_row)
	var veg_lbl := Label.new()
	veg_lbl.text = "Tree density"
	veg_lbl.tooltip_text = "Density multiplier for auto-scattered trees (1.0 = normal, 0.5 = sparse, 2.0 = dense)"
	veg_lbl.add_theme_color_override("font_color", Color(0.58, 0.64, 0.72))
	veg_lbl.add_theme_font_size_override("font_size", 11)
	veg_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	veg_row.add_child(veg_lbl)
	_auto_veg_density_spin = SpinBox.new()
	_auto_veg_density_spin.min_value = 0.25
	_auto_veg_density_spin.max_value = 3.0
	_auto_veg_density_spin.step = 0.05
	_auto_veg_density_spin.value = 1.0
	_auto_veg_density_spin.suffix = "x"
	_auto_veg_density_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auto_veg_density_spin.value_changed.connect(_on_auto_veg_density_changed)
	veg_row.add_child(_auto_veg_density_spin)
	_near_detail_cb = _add_toggle(_body, "Near-field ground texture",
		"Blend a tiling ground texture and surface relief into the aerial photo "
		+ "within ~30 m of the camera. The set is dirt/sand, so it sells bare "
		+ "ground (playa, desert, gravel) but fights grass and forest floor — "
		+ "turn it off on green sites. Applies instantly.",
		_on_near_detail_toggled)
	_cache_cb = _add_toggle(_body, "Show terrain geometry",
		"Show/hide DEM + OSM world meshes (ground, buildings, water, camps, veg). "
		+ "Does not control cache loading — use map-select “Load from cache” for that.",
		_on_cache_toggled)

	# AI spawn-area enhancement: UI intentionally not exposed yet (not verified
	# working/secure enough to recommend patrons wire up a Gemini key). The
	# backend (AiImageryService, terrain_loader.gd's _ai_hero_enabled()/
	# refresh_ai_hero()) is untouched and still reachable by hand-editing
	# terrain_config.cfg — see LOCAL_CONFIG.md.

	var align_lbl := SectionHeader.make("Align OSM to imagery")
	align_lbl.tooltip_text = "Slide buildings/roads/camps onto the aerial when OSM and the photo disagree (e.g. BRC year mismatch)."
	_body.add_child(align_lbl)
	_osm_offset_lbl = Label.new()
	_osm_offset_lbl.text = "Offset: 0 m E, 0 m N"
	_osm_offset_lbl.add_theme_font_size_override("font_size", 11)
	_osm_offset_lbl.add_theme_color_override("font_color", C_MUTED)
	_body.add_child(_osm_offset_lbl)
	var nudge := GridContainer.new()
	nudge.columns = 4
	nudge.add_theme_constant_override("h_separation", 4)
	nudge.add_theme_constant_override("v_separation", 4)
	_body.add_child(nudge)
	_add_nudge_btn(nudge, "N", "Nudge OSM 25 m north", 0.0, 25.0)
	_add_nudge_btn(nudge, "S", "Nudge OSM 25 m south", 0.0, -25.0)
	_add_nudge_btn(nudge, "E", "Nudge OSM 25 m east", 25.0, 0.0)
	_add_nudge_btn(nudge, "W", "Nudge OSM 25 m west", -25.0, 0.0)
	var align_row := HBoxContainer.new()
	align_row.add_theme_constant_override("separation", 6)
	_body.add_child(align_row)
	var auto_btn := Button.new()
	auto_btn.text = "Auto (BRC)"
	auto_btn.tooltip_text = "Match OSM Golden Spike / The Man to the published spike nearest the map centre (imagery scars)."
	auto_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_btn.pressed.connect(_on_auto_align_osm)
	align_row.add_child(auto_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Reset"
	clear_btn.tooltip_text = "Clear OSM↔imagery offset"
	clear_btn.pressed.connect(_on_clear_osm_offset)
	align_row.add_child(clear_btn)

	_build_extent_ui(_body)

	_body.add_child(SectionHeader.make("Refresh from network"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 4)
	_body.add_child(grid)
	_add_refresh_btn(grid, "Elevation", "Refresh elevation", _on_refresh_dem)
	_add_refresh_btn(grid, "Imagery", "Re-fetch satellite drape tiles", _on_refresh_imagery)
	_add_refresh_btn(grid, "Map data", "Re-fetch buildings, roads, water", _on_refresh_osm_map)
	_add_refresh_btn(grid, "Vegetation", "Re-fetch OSM landcover + re-scatter", _on_refresh_osm_veg)
	var all_row := HBoxContainer.new()
	_body.add_child(all_row)
	var all_btn := Button.new()
	all_btn.text = "Refresh all"
	all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all_btn.tooltip_text = "Clear all cached layers for this site and re-download"
	all_btn.pressed.connect(_on_refresh_all)
	all_row.add_child(all_btn)
	_refresh_btns.append(all_btn)

	# Overhaul v2: veg style resets that actually work (the old reset-site path
	# built wrong filenames and deleted nothing).
	# Stacked, not side by side: the pair is 328 px wide in a 260 px panel and
	# was pushing the WHOLE panel 84 px past the right edge of the screen
	# (measured by a headless min-size probe, 2026-10-12).
	var style_row := VBoxContainer.new()
	_body.add_child(style_row)
	var map_style_btn := Button.new()
	map_style_btn.text = "Reset map veg style"
	map_style_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_style_btn.tooltip_text = "Forget this map's vegetation styling (trees stay planted; global defaults apply again)"
	map_style_btn.pressed.connect(func() -> void:
		if _loader != null and _loader.has_method("reset_map_veg_style"):
			_loader.call("reset_map_veg_style"))
	style_row.add_child(map_style_btn)
	var all_style_btn := Button.new()
	all_style_btn.text = "Reset ALL veg styles"
	all_style_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all_style_btn.tooltip_text = "Forget every saved vegetation style (all maps back to shipped defaults)"
	all_style_btn.pressed.connect(func() -> void:
		if _veg_style_confirm != null:
			_veg_style_confirm.popup_centered())
	style_row.add_child(all_style_btn)
	_veg_style_confirm = ConfirmationDialog.new()
	_veg_style_confirm.title = "Reset ALL vegetation styles?"
	_veg_style_confirm.dialog_text = "Every saved vegetation look (global + this map) returns to shipped defaults. Painted trees stay planted."
	_veg_style_confirm.ok_button_text = "Reset styles"
	_veg_style_confirm.confirmed.connect(func() -> void:
		if _loader != null and _loader.has_method("reset_all_veg_styles"):
			_loader.call("reset_all_veg_styles"))
	add_child(_veg_style_confirm)
	# Earlier looks of THIS world (taken before a big re-style), restorable.
	var bk_lbl := Label.new()
	bk_lbl.text = "Earlier vegetation looks"
	bk_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	bk_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	style_row.add_child(bk_lbl)
	_veg_backup_opt = OptionButton.new()
	_veg_backup_opt.fit_to_longest_item = false
	_veg_backup_opt.clip_text = true
	_veg_backup_opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_veg_backup_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_veg_backup_opt.tooltip_text = "Saved before big vegetation changes to this world"
	style_row.add_child(_veg_backup_opt)
	_veg_backup_btn = Button.new()
	_veg_backup_btn.text = "Restore this look"
	_veg_backup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_veg_backup_btn.tooltip_text = "Put back this world's styles, painted plants and area fills as they were then (today's look is saved first)"
	_veg_backup_btn.pressed.connect(func() -> void:
		if _veg_backup_confirm != null and _veg_backup_opt.selected >= 0:
			_veg_backup_confirm.popup_centered())
	style_row.add_child(_veg_backup_btn)
	_veg_backup_confirm = ConfirmationDialog.new()
	_veg_backup_confirm.title = "Restore an earlier vegetation look?"
	_veg_backup_confirm.dialog_text = "This world's vegetation styles, painted plants and area fills go back to the chosen snapshot. Today's look is saved as a snapshot first, so you can come back to it."
	_veg_backup_confirm.ok_button_text = "Restore"
	_veg_backup_confirm.confirmed.connect(_on_restore_veg_backup)
	add_child(_veg_backup_confirm)

	var reset_row := HBoxContainer.new()
	_body.add_child(reset_row)
	var reset_btn := Button.new()
	var in_world := WorldPaths.has_active_world()
	reset_btn.text = "Re-download map data" if in_world else "Reset site (fresh load)"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if in_world:
		reset_btn.tooltip_text = ("Re-download this map's terrain, imagery and OSM now. Your world (props, "
			+ "vegetation, sculpting, graph, people) is kept. For a clean slate start a new world on this map.")
	else:
		reset_btn.tooltip_text = "Delete all painted vegetation and cached terrain for this site, then re-download now"
	reset_btn.pressed.connect(_on_reset_site_pressed)
	reset_row.add_child(reset_btn)
	_refresh_btns.append(reset_btn)

	_reset_confirm = ConfirmationDialog.new()
	_reset_confirm.title = "Re-download map data?" if in_world else "Reset site?"
	if in_world:
		_reset_confirm.dialog_text = ("Re-downloads this map's terrain, imagery and OSM features. Your world is kept; "
			+ "other worlds on this map will also load the refreshed terrain.")
	else:
		_reset_confirm.dialog_text = "Deletes all painted vegetation and cached terrain data for this map, then re-downloads as if loading for the first time."
	_reset_confirm.ok_button_text = "Re-download" if in_world else "Reset now"
	_reset_confirm.confirmed.connect(_on_reset_site_confirmed)
	add_child(_reset_confirm)

	_status_lbl = Label.new()
	_status_lbl.text = "Click ▸ to expand"
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_font_size_override("font_size", 11)
	_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_body.add_child(_status_lbl)


## ---------------------------------------------------------------------------
## Points of interest: Google Earth KML pins (core/poi/). Import, a show
## toggle, the list with Go / remove per pin, clear all.
## ---------------------------------------------------------------------------

func _build_poi_ui(parent: Control) -> void:
	var title := Label.new()
	# The panel is 260 px wide; a longer title overflowed past the screen's
	# right edge (the harness measured it). Clip rather than grow.
	title.text = "Points of interest (KML pins)"
	title.clip_text = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.tooltip_text = ("Import a KML / KMZ exported from Google Earth: every placemark becomes a pin "
		+ "in the world at its real coordinates, paths and areas become ribbons on the ground.")
	parent.add_child(title)
	_poi_title = title
	var row := HBoxContainer.new()
	parent.add_child(row)
	var imp := Button.new()
	imp.text = "Import KML / KMZ…"
	imp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	imp.tooltip_text = "Importing the same file again replaces its pins (move a pin in Google Earth, export, re-import)."
	imp.pressed.connect(_on_import_kml_pressed)
	row.add_child(imp)
	_poi_list = VBoxContainer.new()
	_poi_list.add_theme_constant_override("separation", 2)
	parent.add_child(_poi_list)
	_poi_empty_lbl = Label.new()
	_poi_empty_lbl.text = "No pins yet — import a KML."
	_poi_empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_poi_empty_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_poi_empty_lbl.modulate = Color(1, 1, 1, 0.6)
	parent.add_child(_poi_empty_lbl)
	# One row for the two small controls: the panel is 260 px wide, and the
	# import button beside the checkbox pushed it 76 px off the screen.
	var clear_row := HBoxContainer.new()
	parent.add_child(clear_row)
	_poi_show_cb = CheckBox.new()
	_poi_show_cb.text = "Show"
	_poi_show_cb.button_pressed = true
	_poi_show_cb.tooltip_text = "Show the pins in the world and on the Site Plan (off keeps them saved, just hidden)"
	_poi_show_cb.toggled.connect(func(on: bool) -> void:
		if _loader != null and _loader.has_method("set_show_pois"):
			_loader.call("set_show_pois", on))
	clear_row.add_child(_poi_show_cb)
	var clear_btn := Button.new()
	clear_btn.text = "Clear all pins"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(func() -> void:
		if _poi_clear_confirm != null:
			_poi_clear_confirm.popup_centered())
	clear_row.add_child(clear_btn)
	parent.add_child(HSeparator.new())
	_poi_clear_confirm = ConfirmationDialog.new()
	_poi_clear_confirm.title = "Remove every point of interest?"
	_poi_clear_confirm.dialog_text = "Removes all imported pins from this site. Import the KML again to get them back."
	_poi_clear_confirm.ok_button_text = "Remove pins"
	_poi_clear_confirm.confirmed.connect(func() -> void:
		if _loader != null and _loader.has_method("clear_pois"):
			_loader.call("clear_pois")
		_refresh_poi_list())
	add_child(_poi_clear_confirm)


func _on_import_kml_pressed() -> void:
	if _poi_dialog == null:
		_poi_dialog = FileDialog.new()
		_poi_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_poi_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_poi_dialog.use_native_dialog = true
		_poi_dialog.filters = PackedStringArray(["*.kml, *.kmz ; Google Earth KML"])
		_poi_dialog.title = "Import points of interest (KML / KMZ)"
		_poi_dialog.file_selected.connect(_on_kml_file_selected)
		add_child(_poi_dialog)
	_poi_dialog.popup_centered_ratio(0.6)


func _on_kml_file_selected(path: String) -> void:
	if _loader == null or not _loader.has_method("import_kml_file"):
		return
	_loader.call("import_kml_file", path)
	_refresh_poi_list()


func _refresh_veg_backups() -> void:
	if _veg_backup_opt == null:
		return
	_veg_backup_opt.clear()
	_veg_backup_dirs.clear()
	var list: Array = []
	if _loader != null and _loader.has_method("veg_look_backups"):
		list = _loader.call("veg_look_backups")
	for b in list:
		var d: Dictionary = b
		var when := str(d.get("stamp", "")).replace("T", " ").replace("_", " ")
		_veg_backup_opt.add_item("%s · %s" % [str(d.get("label", "Snapshot")), when.substr(0, 16)])
		_veg_backup_dirs.append(str(d.get("dir", "")))
	if list.is_empty():
		_veg_backup_opt.add_item("None saved yet")
		_veg_backup_opt.disabled = true
		_veg_backup_btn.disabled = true
	else:
		_veg_backup_opt.disabled = false
		_veg_backup_btn.disabled = false
		_veg_backup_opt.select(0)


func _on_restore_veg_backup() -> void:
	var i := _veg_backup_opt.selected if _veg_backup_opt != null else -1
	if i < 0 or i >= _veg_backup_dirs.size():
		return
	if _loader != null and _loader.has_method("restore_veg_look"):
		_loader.call("restore_veg_look", str(_veg_backup_dirs[i]))
	_refresh_veg_backups()


func _refresh_poi_list() -> void:
	if _poi_list == null:
		return
	for ch in _poi_list.get_children():
		_poi_list.remove_child(ch)
		ch.queue_free()
	var recs: Array = []
	if _loader != null and _loader.has_method("poi_records"):
		recs = _loader.call("poi_records")
	if _poi_show_cb != null and _loader != null and _loader.has_method("show_pois"):
		_poi_show_cb.set_block_signals(true)
		_poi_show_cb.button_pressed = bool(_loader.call("show_pois"))
		_poi_show_cb.set_block_signals(false)
	if _poi_empty_lbl != null:
		_poi_empty_lbl.visible = recs.is_empty()
	var host: Control = _poi_list
	if recs.size() > 8:
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, 200)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_poi_list.add_child(scroll)
		var inner := VBoxContainer.new()
		inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.add_theme_constant_override("separation", 2)
		scroll.add_child(inner)
		host = inner
	for rec_v in recs:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var id := str(rec.get("id", ""))
		var row := HBoxContainer.new()
		host.add_child(row)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(10, 10)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		swatch.color = PoiLayer.color_of(rec)
		row.add_child(swatch)
		var kind := str(rec.get("kind", "point"))
		var lbl := Label.new()
		lbl.text = str(rec.get("name", "")) + ("" if kind == "point" else "  (%s)" % ("area" if kind == "polygon" else "path"))
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.clip_text = true
		var desc := str(rec.get("desc", ""))
		lbl.tooltip_text = desc if not desc.is_empty() else "%.6f, %.6f" % [float(rec.get("lat", 0.0)), float(rec.get("lon", 0.0))]
		row.add_child(lbl)
		var go := Button.new()
		go.text = "Go"
		go.tooltip_text = "Put the player at this pin"
		go.pressed.connect(func() -> void:
			if _loader != null and _loader.has_method("teleport_to_poi"):
				_loader.call("teleport_to_poi", id))
		row.add_child(go)
		var del := Button.new()
		IconButton.style(del, "trash-2", "Remove this pin")
		del.pressed.connect(func() -> void:
			if _loader != null and _loader.has_method("remove_poi"):
				_loader.call("remove_poi", id)
			_refresh_poi_list())
		row.add_child(del)


func _add_toggle(parent: Control, label: String, tip: String, handler: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = label
	cb.tooltip_text = tip
	cb.toggled.connect(handler)
	parent.add_child(cb)
	return cb


func _add_refresh_btn(parent: Control, label: String, tip: String, handler: Callable) -> void:
	var btn := Button.new()
	btn.text = label
	btn.icon = UiIcons.icon("refresh-cw", 14)
	btn.tooltip_text = tip
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Two to a row in a 260 px panel: the text may ellipsize rather than
	# widen the panel past the screen edge (the grid made it 284 px).
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.pressed.connect(handler)
	parent.add_child(btn)
	_refresh_btns.append(btn)


func _sync_from_loader() -> void:
	if _loader == null or not _loader.has_method("get_terrain_options"):
		return
	var opts: Dictionary = _loader.call("get_terrain_options")
	_refresh_poi_list()
	_set_cb(_roads_cb, bool(opts.get("flatten_roads", false)))
	_set_cb(_sites_cb, bool(opts.get("flatten_landuse", false)))
	_set_cb(_buildings_cb, bool(opts.get("show_buildings", true)))
	_set_cb(_water_cb, bool(opts.get("show_water", true)))
	_set_cb(_camps_cb, bool(opts.get("generate_camps", true)))
	_set_cb(_near_detail_cb, bool(opts.get("near_field_detail", true)))
	if _exclusion_r_spin != null:
		_exclusion_r_spin.set_block_signals(true)
		_exclusion_r_spin.value = float(opts.get("camp_exclusion_r", 804.672)) / 1609.344
		_exclusion_r_spin.set_block_signals(false)
	_set_cb(_auto_veg_cb, bool(opts.get("show_auto_vegetation", true)))
	_set_cb(_show_veg_cb, bool(opts.get("show_vegetation", true)))
	if _auto_veg_density_spin != null:
		_auto_veg_density_spin.set_block_signals(true)
		# Show the MAP'S live density, not defaults() (which always displayed 1.0
		# regardless of what the map actually uses).
		var style: Dictionary = {}
		if _loader != null and _loader.has_method("get_vegetation_style"):
			style = _loader.call("get_vegetation_style")
		if style.is_empty():
			style = VegetationStyleConfig.defaults()
		_auto_veg_density_spin.value = float(style.get("auto_density_scale", 1.0))
		_auto_veg_density_spin.set_block_signals(false)
	_set_cb(_cache_cb, bool(opts.get("cached_geometry_visible", true)))
	_sync_osm_offset_lbl(opts)
	_set_side_km(_world_km_spin, float(opts.get("half_extent_m", TerrainExtents.WORLD_HALF_DEFAULT)))
	_set_side_km(_detail_km_spin, float(opts.get("detail_half_extent_m", TerrainExtents.DETAIL_HALF_DEFAULT)))
	_set_side_km(_osm_km_spin, float(opts.get("osm_half_extent_m", TerrainExtents.OSM_HALF_DEFAULT)))
	_update_extent_hint()
	_update_dem_status_label()


func _set_side_km(spin: SpinBox, half_m: float) -> void:
	if spin == null:
		return
	spin.set_block_signals(true)
	spin.value = TerrainExtents.side_from_half(half_m) / 1000.0
	spin.set_block_signals(false)


## The half-extent (m) a size box asks for.
func _half_from_spin(spin: SpinBox) -> float:
	if spin == null:
		return 0.0
	return TerrainExtents.half_from_side(spin.value * 1000.0)


func _sync_osm_offset_lbl(opts: Dictionary = {}) -> void:
	if _osm_offset_lbl == null:
		return
	var ee := float(opts.get("osm_offset_east_m", 0.0))
	var nn := float(opts.get("osm_offset_north_m", 0.0))
	if opts.is_empty() and _loader != null and _loader.has_method("get_terrain_options"):
		var live: Dictionary = _loader.call("get_terrain_options")
		ee = float(live.get("osm_offset_east_m", 0.0))
		nn = float(live.get("osm_offset_north_m", 0.0))
	_osm_offset_lbl.text = "Offset: %+.0f m E, %+.0f m N" % [ee, nn]


func _add_nudge_btn(parent: Control, label: String, tip: String,
		east_m: float, north_m: float) -> void:
	var btn := Button.new()
	btn.text = label
	btn.tooltip_text = tip
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void:
		if _loader != null and _loader.has_method("nudge_osm_imagery_offset"):
			_loader.call("nudge_osm_imagery_offset", east_m, north_m)
			_sync_osm_offset_lbl()
	)
	parent.add_child(btn)


## World/detail/OSM half-extent controls. Restores what was accidentally dropped
## from location_picker_ui.gd's old "Advanced terrain size" section during a
## later batch commit — TerrainLoader.apply_terrain_extents() has been fully
## built and correct this whole time, just with no UI caller. Living here
## (rather than only at map-creation time) is what lets an ALREADY-VISITED site
## change size: per-site cache metadata (TerrainCacheSettings.get_meta_extents)
## always wins over terrain_config.cfg once a site has loaded once, so hand-
## editing the config file does nothing for a returning site.
func _build_extent_ui(parent: Control) -> void:
	parent.add_child(SectionHeader.make("Advanced terrain size"))
	var hint := Label.new()
	hint.text = "Reloads the map to rebuild terrain at the new size."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", C_MUTED)
	parent.add_child(hint)

	var world_row := HBoxContainer.new()
	world_row.add_theme_constant_override("separation", 6)
	parent.add_child(world_row)
	var world_lbl := Label.new()
	world_lbl.text = "World size"
	world_lbl.tooltip_text = "Width of the whole lo-res terrain square, edge to edge. Over 20 km the elevation comes from SRTMGL3 (90 m), over 60 km from COP90 -- both coarser than the 30 m default. Big worlds download in tiles the first time."
	world_lbl.add_theme_color_override("font_color", C_MUTED)
	world_lbl.add_theme_font_size_override("font_size", 11)
	world_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	world_row.add_child(world_lbl)
	_world_km_spin = _make_side_spin(TerrainExtents.WORLD_SIDE_MIN_M, TerrainExtents.WORLD_SIDE_MAX_M,
		1.0, TerrainExtents.WORLD_HALF_DEFAULT)
	world_row.add_child(_world_km_spin)

	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 6)
	parent.add_child(detail_row)
	var detail_lbl := Label.new()
	detail_lbl.text = "Hi-res DEM/imagery"
	detail_lbl.tooltip_text = "Width of the hi-res elevation + imagery patch in the middle, edge to edge. The sharpest imagery layers stay inside it. 1 m USGS lidar (US sites, key required) needs %s or less." % TerrainExtents.format_side(ElevationService.USGS1M_MAX_SIDE_M)
	detail_lbl.add_theme_color_override("font_color", C_MUTED)
	detail_lbl.add_theme_font_size_override("font_size", 11)
	detail_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	detail_row.add_child(detail_lbl)
	_detail_km_spin = _make_side_spin(TerrainExtents.DETAIL_SIDE_MIN_M, TerrainExtents.DETAIL_SIDE_MAX_M,
		0.2, TerrainExtents.DETAIL_HALF_DEFAULT)
	detail_row.add_child(_detail_km_spin)

	_extent_hint_lbl = Label.new()
	_extent_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_extent_hint_lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(_extent_hint_lbl)

	_dem_status_lbl = Label.new()
	_dem_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dem_status_lbl.add_theme_font_size_override("font_size", 11)
	_dem_status_lbl.add_theme_color_override("font_color", C_MUTED)
	parent.add_child(_dem_status_lbl)

	var osm_row := HBoxContainer.new()
	osm_row.add_theme_constant_override("separation", 6)
	parent.add_child(osm_row)
	var osm_lbl := Label.new()
	osm_lbl.text = "Buildings/water/veg"
	osm_lbl.tooltip_text = "Width of the square OpenStreetMap buildings, roads, water and vegetation are loaded from, edge to edge. Independent of the hi-res patch: outside the patch they sit on the lo-res terrain."
	osm_lbl.add_theme_color_override("font_color", C_MUTED)
	osm_lbl.add_theme_font_size_override("font_size", 11)
	osm_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	osm_row.add_child(osm_lbl)
	_osm_km_spin = _make_side_spin(TerrainExtents.OSM_SIDE_MIN_M, TerrainExtents.OSM_SIDE_MAX_M,
		0.2, TerrainExtents.OSM_HALF_DEFAULT)
	osm_row.add_child(_osm_km_spin)

	_extent_summary_lbl = Label.new()
	_extent_summary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_extent_summary_lbl.add_theme_font_size_override("font_size", 11)
	_extent_summary_lbl.add_theme_color_override("font_color", C_MUTED)
	parent.add_child(_extent_summary_lbl)
	for spin in [_world_km_spin, _detail_km_spin, _osm_km_spin]:
		(spin as SpinBox).value_changed.connect(func(_v: float) -> void: _update_extent_hint())

	var apply_btn := Button.new()
	apply_btn.text = "Apply & reload"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_btn.tooltip_text = "Rebuild this map's terrain at the sizes above (reloads the scene)"
	apply_btn.pressed.connect(_on_extent_apply_pressed)
	parent.add_child(apply_btn)
	_refresh_btns.append(apply_btn)

	_extent_apply_confirm = ConfirmationDialog.new()
	_extent_apply_confirm.title = "Change terrain size?"
	_extent_apply_confirm.dialog_text = "Reloads this map to rebuild the terrain at the new size. Painted vegetation edits for this site will be cleared (regenerated fresh)."
	_extent_apply_confirm.ok_button_text = "Apply & reload"
	_extent_apply_confirm.confirmed.connect(_on_apply_extents_confirmed)
	add_child(_extent_apply_confirm)

	_update_extent_hint()


func _make_side_spin(min_side_m: float, max_side_m: float, step_km: float, default_half_m: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_side_m / 1000.0
	spin.max_value = max_side_m / 1000.0
	spin.step = step_km
	spin.value = TerrainExtents.side_from_half(default_half_m) / 1000.0
	spin.suffix = " km"
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin


## Necessary-but-not-sufficient by design: fitting under the size cap is only
## half the story. OpenTopography also gates the 1 m dataset to academic-tier
## keys (confirmed: an ordinary self-registered key gets HTTP 401 there
## regardless of coverage) -- so this can only ever promise an ATTEMPT, not a
## result. _update_dem_status_label (synced from the loader, not predicted from
## the spinbox) is what tells you whether it actually landed.
func _update_extent_hint() -> void:
	var s := TerrainExtents.sanitize(_half_from_spin(_world_km_spin),
		_half_from_spin(_detail_km_spin), _half_from_spin(_osm_km_spin))
	var world_half := float(s["world_half_m"])
	var detail_half := float(s["detail_half_m"])
	var osm_half := float(s["osm_half_m"])
	if _extent_summary_lbl != null:
		var lines: Array[String] = [TerrainExtents.describe(world_half, detail_half, osm_half)]
		if TerrainExtents.side_from_half(world_half) > TerrainExtents.WORLD_SIDE_SLOW_M:
			lines.append("A world this big downloads its elevation in tiles the first time (a few minutes); it is cached after.")
		_extent_summary_lbl.text = "\n".join(lines)
	if _extent_hint_lbl == null:
		return
	var cap: float = ElevationService.USGS1M_MAX_SIDE_M
	if TerrainExtents.side_from_half(detail_half) <= cap:
		_extent_hint_lbl.text = "Small enough to attempt 1 m USGS lidar, using your OpenTopography key from Settings -> Keys. That dataset needs an ACADEMIC-tier key though -- an ordinary key falls back to 10 m (see below)."
	else:
		_extent_hint_lbl.text = "Over %s -- the hi-res patch uses the 10 m DEM" % TerrainExtents.format_side(cap)
	_extent_hint_lbl.add_theme_color_override("font_color", C_MUTED)


## The REAL outcome for THIS site, read from the actual cache (not predicted).
func _update_dem_status_label() -> void:
	if _dem_status_lbl == null or _loader == null or not _loader.has_method("get_detail_dem_status"):
		return
	var status: Dictionary = _loader.call("get_detail_dem_status")
	var label := str(status.get("label", "not loaded yet"))
	var text := "Detail DEM in use: %s" % label
	var reason := str(status.get("miss_reason", ""))
	if not reason.is_empty():
		text += "  (1 m rejected: %s)" % _clean_dem_reason(reason)
	_dem_status_lbl.text = text
	_dem_status_lbl.add_theme_color_override(
		"font_color", C_OK if bool(status.get("is_best", false)) else C_MUTED)


## OpenTopography's own error bodies are raw XML ("<?xml ...?><error>text</error>").
## The stored diagnostic (ElevationService.usgs1m_miss_reason) keeps that verbatim
## for anyone reading the flag file directly; this display-only cleanup pulls
## just the human sentence out of it so the settings panel isn't showing markup.
func _clean_dem_reason(reason: String) -> String:
	var open_tag := reason.find("<error>")
	if open_tag >= 0:
		var start := open_tag + "<error>".length()
		var close_tag := reason.find("</error>", start)
		var inner := reason.substr(start, (close_tag - start) if close_tag >= 0 else -1)
		if not inner.strip_edges().is_empty():
			return inner.strip_edges()
	return reason


func _on_extent_apply_pressed() -> void:
	if _extent_apply_confirm != null:
		_extent_apply_confirm.popup_centered()


func _on_apply_extents_confirmed() -> void:
	if _loader == null or not _loader.has_method("apply_terrain_extents"):
		set_status("Terrain not ready", "error")
		return
	_loader.call("apply_terrain_extents", _half_from_spin(_world_km_spin),
		_half_from_spin(_detail_km_spin), _half_from_spin(_osm_km_spin))


func _on_auto_align_osm() -> void:
	if _loader != null and _loader.has_method("auto_align_osm_to_imagery"):
		_loader.call("auto_align_osm_to_imagery")
		_sync_osm_offset_lbl()


func _on_clear_osm_offset() -> void:
	if _loader != null and _loader.has_method("clear_osm_imagery_offset"):
		_loader.call("clear_osm_imagery_offset")
		_sync_osm_offset_lbl()


func _set_cb(cb: CheckBox, on: bool) -> void:
	if cb == null:
		return
	cb.set_block_signals(true)
	cb.button_pressed = on
	cb.set_block_signals(false)


func _on_toggle_pressed() -> void:
	toggle_expanded()


func _on_loader_status(msg: String, kind: String) -> void:
	set_status(msg, kind)
	# Cheap filename-only lookup (ElevationService.cached_dem_source) -- safe to
	# re-check on every completed action rather than tracking which ones could
	# plausibly have touched the DEM cache (refresh elevation/all, reset site, …).
	if kind == "ok":
		_update_dem_status_label()


func _maybe_opentopo_hint() -> void:
	if _loader == null or not _loader.has_method("needs_opentopo_hint"):
		return
	if bool(_loader.call("needs_opentopo_hint")):
		set_status("Tip: add a free OpenTopography key in Settings -> Keys for 30 m (or 10 m US) DEM", "info")


func _set_refresh_busy(on: bool) -> void:
	for btn in _refresh_btns:
		if btn != null:
			btn.disabled = on


func _on_roads_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_flatten_roads"):
		_loader.call("set_flatten_roads", on)


func _on_sites_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_flatten_landuse"):
		_loader.call("set_flatten_landuse", on)


func _on_buildings_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_show_buildings"):
		_loader.call("set_show_buildings", on)


func _on_water_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_show_water"):
		_loader.call("set_show_water", on)


func _on_near_detail_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_near_field_detail"):
		_loader.call("set_near_field_detail", on)


func _on_camps_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_generate_camps"):
		_loader.call("set_generate_camps", on)


func _on_exclusion_r_changed(miles: float) -> void:
	if _loader != null and _loader.has_method("set_camp_exclusion_r"):
		_loader.call("set_camp_exclusion_r", miles * 1609.344)


func _on_camps_edit_pressed() -> void:
	# Forward to the camp scatter UI via terrain_loader.
	if _loader != null and _loader.has_method("toggle_camp_scatter_ui"):
		_loader.call("toggle_camp_scatter_ui")


func _on_show_veg_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_show_vegetation"):
		_loader.call("set_show_vegetation", on)


func _on_auto_veg_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_show_auto_vegetation"):
		_loader.call("set_show_auto_vegetation", on)


func _on_auto_veg_density_changed(val: float) -> void:
	# Persist ONLY this key. Writing a whole defaults() dict here used to reset
	# every tuned global style value back to defaults (save_global merges
	# key-by-key into the cfg, so a one-key dict touches nothing else).
	VegetationStyleConfig.save_global({"auto_density_scale": val})
	# Route the live map through set_vegetation_style: persists per-map AND
	# _forest_params_changed covers auto_density_scale → full re-scatter.
	if _loader != null and _loader.has_method("set_vegetation_style"):
		_loader.call("set_vegetation_style", {"auto_density_scale": val})
	elif _auto_veg_cb != null and _auto_veg_cb.button_pressed:
		if _loader != null and _loader.has_method("request_auto_vegetation_regen"):
			_loader.call("request_auto_vegetation_regen")


func _on_cache_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_cached_geometry_visible"):
		_loader.call("set_cached_geometry_visible", on)


func _on_refresh_dem() -> void:
	_call_refresh("refresh_dem", "elevation")


func _on_refresh_imagery() -> void:
	_call_refresh("refresh_imagery", "imagery")


func _on_refresh_osm_map() -> void:
	_call_refresh("refresh_osm_vectors", "map data")


func _on_refresh_osm_veg() -> void:
	_call_refresh("refresh_osm_vegetation", "vegetation")


func _on_refresh_all() -> void:
	_call_refresh("refresh_all_cached_layers", "all layers")


func _on_reset_site_pressed() -> void:
	if _reset_confirm != null:
		_reset_confirm.popup_centered()


func _on_reset_site_confirmed() -> void:
	if _loader == null or not _loader.has_method("reset_site_to_fresh"):
		set_status("Terrain not ready", "error")
		return
	_loader.call("reset_site_to_fresh")
	if not _expanded:
		_set_expanded(true)


func _call_refresh(method: String, label: String) -> void:
	if _loader == null or not _loader.has_method(method):
		set_status("Terrain not ready", "error")
		return
	_loader.call(method)
	if not _expanded:
		_set_expanded(true)
