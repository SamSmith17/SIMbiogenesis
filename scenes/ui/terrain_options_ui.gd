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
var _auto_veg_density_spin: SpinBox = null
var _cache_cb: CheckBox = null
var _status_lbl: Label = null
var _refresh_btns: Array[Button] = []
var _reset_confirm: ConfirmationDialog = null
var _osm_offset_lbl: Label = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -272.0
	offset_top = 12.0
	offset_right = -12.0
	offset_bottom = 52.0
	_build_ui()
	_apply_collapsed_size()


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
	if _body != null:
		_body.visible = on
	if _toggle_btn != null:
		_toggle_btn.text = "▾ Terrain options" if on else "▸ Terrain options"
	_apply_collapsed_size()
	expanded_changed.emit(on)


func _apply_collapsed_size() -> void:
	if _expanded:
		offset_bottom = 520.0
	else:
		offset_bottom = 52.0


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

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.visible = false
	col.add_child(_body)

	_roads_cb = _add_toggle(_body, "Flatten roads (hi-res patch)",
		"Level highway corridors on the hi-res DEM grid", _on_roads_toggled)
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
	camps_edit_btn.text = "🏕 Edit camps (C)"
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
	_cache_cb = _add_toggle(_body, "Show terrain geometry",
		"Show/hide DEM + OSM world meshes (ground, buildings, water, camps, veg). "
		+ "Does not control cache loading — use map-select “Load from cache” for that.",
		_on_cache_toggled)

	var align_sep := HSeparator.new()
	_body.add_child(align_sep)
	var align_lbl := Label.new()
	align_lbl.text = "Align OSM to imagery"
	align_lbl.tooltip_text = "Slide buildings/roads/camps onto the aerial when OSM and the photo disagree (e.g. BRC year mismatch)."
	align_lbl.add_theme_font_size_override("font_size", 12)
	align_lbl.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
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

	var sep := HSeparator.new()
	_body.add_child(sep)
	var refresh_lbl := Label.new()
	refresh_lbl.text = "Refresh from network"
	refresh_lbl.add_theme_font_size_override("font_size", 12)
	refresh_lbl.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	_body.add_child(refresh_lbl)
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

	var reset_row := HBoxContainer.new()
	_body.add_child(reset_row)
	var reset_btn := Button.new()
	reset_btn.text = "Reset site (fresh load)"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.tooltip_text = "Delete all painted vegetation and cached terrain for this site, then re-download now"
	reset_btn.pressed.connect(_on_reset_site_pressed)
	reset_row.add_child(reset_btn)
	_refresh_btns.append(reset_btn)

	_reset_confirm = ConfirmationDialog.new()
	_reset_confirm.title = "Reset site?"
	_reset_confirm.dialog_text = "Deletes all painted vegetation and cached terrain data for this map, then re-downloads as if loading for the first time."
	_reset_confirm.ok_button_text = "Reset now"
	_reset_confirm.confirmed.connect(_on_reset_site_confirmed)
	add_child(_reset_confirm)

	_status_lbl = Label.new()
	_status_lbl.text = "Click ▸ to expand"
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_font_size_override("font_size", 11)
	_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_body.add_child(_status_lbl)


func _add_toggle(parent: Control, label: String, tip: String, handler: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = label
	cb.tooltip_text = tip
	cb.toggled.connect(handler)
	parent.add_child(cb)
	return cb


func _add_refresh_btn(parent: Control, label: String, tip: String, handler: Callable) -> void:
	var btn := Button.new()
	btn.text = "↻ %s" % label
	btn.tooltip_text = tip
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(handler)
	parent.add_child(btn)
	_refresh_btns.append(btn)


func _sync_from_loader() -> void:
	if _loader == null or not _loader.has_method("get_terrain_options"):
		return
	var opts: Dictionary = _loader.call("get_terrain_options")
	_set_cb(_roads_cb, bool(opts.get("flatten_roads", false)))
	_set_cb(_sites_cb, bool(opts.get("flatten_landuse", false)))
	_set_cb(_buildings_cb, bool(opts.get("show_buildings", true)))
	_set_cb(_water_cb, bool(opts.get("show_water", true)))
	_set_cb(_camps_cb, bool(opts.get("generate_camps", true)))
	if _exclusion_r_spin != null:
		_exclusion_r_spin.set_block_signals(true)
		_exclusion_r_spin.value = float(opts.get("camp_exclusion_r", 804.672)) / 1609.344
		_exclusion_r_spin.set_block_signals(false)
	_set_cb(_auto_veg_cb, bool(opts.get("show_auto_vegetation", true)))
	if _auto_veg_density_spin != null:
		_auto_veg_density_spin.set_block_signals(true)
		var style: Dictionary = VegetationStyleConfig.defaults()
		_auto_veg_density_spin.value = float(style.get("auto_density_scale", 1.0))
		_auto_veg_density_spin.set_block_signals(false)
	_set_cb(_cache_cb, bool(opts.get("cached_geometry_visible", true)))
	_sync_osm_offset_lbl(opts)


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


func _maybe_opentopo_hint() -> void:
	if _loader == null or not _loader.has_method("needs_opentopo_hint"):
		return
	if bool(_loader.call("needs_opentopo_hint")):
		set_status("Tip: add OpenTopography key in terrain_config.cfg for 30 m DEM", "info")


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


func _on_auto_veg_toggled(on: bool) -> void:
	if _loader != null and _loader.has_method("set_show_auto_vegetation"):
		_loader.call("set_show_auto_vegetation", on)


func _on_auto_veg_density_changed(val: float) -> void:
	var style: Dictionary = VegetationStyleConfig.defaults()
	style["auto_density_scale"] = val
	VegetationStyleConfig.save_global(style)
	# Trigger a regen if veg is on
	if _auto_veg_cb != null and _auto_veg_cb.button_pressed:
		if _loader != null and _loader.has_method("request_auto_vegetation_regen"):
			_loader.call("request_auto_vegetation_regen")
		elif _loader != null and _loader.has_method("set_show_auto_vegetation"):
			# Hacky fallback to trigger regen via the toggle
			_loader.call("set_show_auto_vegetation", true)


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
