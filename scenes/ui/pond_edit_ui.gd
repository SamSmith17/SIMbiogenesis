extends PanelContainer

## Pond settings modal (Ctrl-click a pond → open). Level scrub, Auto/Manual
## capacity & fill, graph toggle, delete. Ponds are never auto-added to the graph.

const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_MUTED := Color(0.62, 0.68, 0.78, 1.0)
const C_ACCENT := Color(0.24, 0.62, 1.0, 1.0)

const DRAWER_HEIGHT := 168.0

var _loader: Node = null
var _idx: int = -1
var _syncing := false

var _title_lbl: Label
var _meta_lbl: Label
var _hint_lbl: Label
var _level_slider: HSlider
var _level_lbl: Label
var _cap_mode_opt: OptionButton
var _vol_spin: SpinBox
var _terrain_cap_lbl: Label
var _recalc_btn: Button
var _fill_mode_opt: OptionButton
var _max_spin: SpinBox
var _max_lbl: Label
var _graph_btn: Button
var _del_btn: Button
var _ws_lbl: Label
var _ws_preview_btn: Button
var _ws_clear_btn: Button
var _ws_designate_btn: Button
var _ws_remove_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_layout_drawer()


func bind_loader(loader: Node) -> void:
	_loader = loader


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout_drawer()


func _layout_drawer() -> void:
	var clearance := UiScreenLayout.timeline_stack_height()
	var main := get_tree().current_scene
	var timeline: Node = null
	if main != null:
		timeline = main.get_node_or_null("UILayer/TimelineUI")
	if timeline != null and timeline.has_method("get_stack_height"):
		clearance = float(timeline.call("get_stack_height"))
	UiScreenLayout.pin_above_timeline(self, DRAWER_HEIGHT, clearance)


func open_for_pond(idx: int) -> void:
	_idx = idx
	if not _load_from_loader():
		return
	_layout_drawer()
	visible = true
	CursorController.request_modal("pond_edit", Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	visible = false
	_idx = -1
	CursorController.release_modal("pond_edit")


func _build_ui() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = C_PANEL
	panel_style.border_color = C_BORDER
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 14
	panel_style.content_margin_right = 14
	panel_style.content_margin_top = 8
	panel_style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", panel_style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	root.add_child(header)
	_title_lbl = Label.new()
	_title_lbl.text = "Pond settings"
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_title_lbl.add_theme_font_size_override("font_size", 14)
	header.add_child(_title_lbl)
	_meta_lbl = Label.new()
	_meta_lbl.add_theme_color_override("font_color", C_MUTED)
	_meta_lbl.add_theme_font_size_override("font_size", 11)
	_meta_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_meta_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_meta_lbl)
	var close_btn := Button.new()
	IconButton.as_close(close_btn, "Close (Esc)")
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	root.add_child(row)

	# Fill level -----------------------------------------------------------
	var level_col := VBoxContainer.new()
	level_col.add_theme_constant_override("separation", 0)
	level_col.custom_minimum_size.x = 280.0
	row.add_child(level_col)
	var level_head := HBoxContainer.new()
	level_col.add_child(level_head)
	level_head.add_child(_field_label("Water fill level"))
	_level_lbl = Label.new()
	_level_lbl.add_theme_color_override("font_color", C_ACCENT)
	_level_lbl.add_theme_font_size_override("font_size", 11)
	_level_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	level_head.add_child(_level_lbl)
	_level_slider = HSlider.new()
	_level_slider.step = 0.05
	_level_slider.custom_minimum_size = Vector2(280, 20)
	_level_slider.value_changed.connect(_on_level_changed)
	level_col.add_child(_level_slider)
	_hint_lbl = Label.new()
	_hint_lbl.add_theme_color_override("font_color", C_MUTED)
	_hint_lbl.add_theme_font_size_override("font_size", 10)
	_hint_lbl.text = "T → Rain/Drain to scrub level in-world"
	level_col.add_child(_hint_lbl)

	# Capacity -------------------------------------------------------------
	var vol_col := VBoxContainer.new()
	vol_col.add_theme_constant_override("separation", 2)
	row.add_child(vol_col)
	vol_col.add_child(_field_label("Capacity"))
	var cap_row := HBoxContainer.new()
	cap_row.add_theme_constant_override("separation", 6)
	vol_col.add_child(cap_row)
	_cap_mode_opt = OptionButton.new()
	_cap_mode_opt.add_item("Auto (terrain)", 0)
	_cap_mode_opt.add_item("Manual (L)", 1)
	_cap_mode_opt.custom_minimum_size.x = 120.0
	_cap_mode_opt.item_selected.connect(_on_cap_mode_selected)
	cap_row.add_child(_cap_mode_opt)
	_vol_spin = SpinBox.new()
	_vol_spin.step = 100.0
	_vol_spin.min_value = 1.0
	_vol_spin.max_value = 1.0e9
	_vol_spin.allow_greater = true
	_vol_spin.custom_minimum_size.x = 110.0
	_vol_spin.value_changed.connect(_on_volume_changed)
	cap_row.add_child(_vol_spin)
	var terr_row := HBoxContainer.new()
	terr_row.add_theme_constant_override("separation", 6)
	vol_col.add_child(terr_row)
	_terrain_cap_lbl = Label.new()
	_terrain_cap_lbl.add_theme_color_override("font_color", C_MUTED)
	_terrain_cap_lbl.add_theme_font_size_override("font_size", 10)
	_terrain_cap_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	terr_row.add_child(_terrain_cap_lbl)
	# Max fill level: a dam above the basin's natural rim. Map ponds take it
	# too — it is the one thing a player can set on a pond they did not carve.
	var max_row := HBoxContainer.new()
	max_row.add_theme_constant_override("separation", 6)
	terr_row.add_child(max_row)
	max_row.add_child(_field_label("Max fill level (m)"))
	_max_spin = SpinBox.new()
	_max_spin.step = 0.05
	_max_spin.min_value = -1000.0
	_max_spin.max_value = 9000.0
	_max_spin.custom_minimum_size.x = 110.0
	_max_spin.tooltip_text = "The highest the pond may fill (world metres). Above the basin rim it is a dam: capacity grows as a wall over the footprint, inflow can raise the pond past the rim, and a siphon crest above the rim becomes reachable. Or Ctrl-aim the pond surface in 3D and drag it up."
	_max_spin.value_changed.connect(_on_max_level_changed)
	max_row.add_child(_max_spin)
	var max_reset := Button.new()
	max_reset.text = "Rim"
	max_reset.tooltip_text = "Back to the basin's natural rim"
	max_reset.pressed.connect(func() -> void: _on_max_level_changed(NAN))
	max_row.add_child(max_reset)
	_max_lbl = Label.new()
	_max_lbl.add_theme_color_override("font_color", C_MUTED)
	_max_lbl.add_theme_font_size_override("font_size", 10)
	terr_row.add_child(_max_lbl)
	_recalc_btn = Button.new()
	_recalc_btn.text = "Recalculate"
	_recalc_btn.tooltip_text = "Recompute Auto capacity from terrain bathymetry"
	_recalc_btn.custom_minimum_size = Vector2(90, 24)
	_recalc_btn.pressed.connect(_on_recalc)
	terr_row.add_child(_recalc_btn)

	# Fill mode + actions --------------------------------------------------
	var act_col := VBoxContainer.new()
	act_col.add_theme_constant_override("separation", 2)
	act_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(act_col)
	act_col.add_child(_field_label("Fill"))
	_fill_mode_opt = OptionButton.new()
	_fill_mode_opt.add_item("Auto (water surface)", 0)
	_fill_mode_opt.add_item("Manual (%)", 1)
	_fill_mode_opt.item_selected.connect(_on_fill_mode_selected)
	act_col.add_child(_fill_mode_opt)
	var act := HBoxContainer.new()
	act.add_theme_constant_override("separation", 6)
	act.alignment = BoxContainer.ALIGNMENT_END
	act_col.add_child(act)
	_graph_btn = Button.new()
	_graph_btn.custom_minimum_size = Vector2(150, 30)
	_graph_btn.pressed.connect(_on_graph_toggle)
	act.add_child(_graph_btn)
	_del_btn = Button.new()
	_del_btn.text = "Delete pond"
	_del_btn.custom_minimum_size = Vector2(100, 30)
	_del_btn.add_theme_color_override("font_color", Color(1.0, 0.62, 0.62, 1.0))
	_del_btn.pressed.connect(_on_delete)
	act.add_child(_del_btn)

	# Watershed (hillside → pond rain catchment) --------------------------------
	var ws_row := HBoxContainer.new()
	ws_row.add_theme_constant_override("separation", 8)
	root.add_child(ws_row)
	ws_row.add_child(_field_label("Watershed"))
	_ws_lbl = Label.new()
	_ws_lbl.add_theme_color_override("font_color", C_MUTED)
	_ws_lbl.add_theme_font_size_override("font_size", 11)
	_ws_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ws_lbl.text = "Analyze hillside that drains into this pond"
	ws_row.add_child(_ws_lbl)
	_ws_preview_btn = Button.new()
	_ws_preview_btn.text = "Preview"
	_ws_preview_btn.tooltip_text = "Run local D8 analysis and outline the upstream basin"
	_ws_preview_btn.custom_minimum_size = Vector2(72, 26)
	_ws_preview_btn.pressed.connect(_on_ws_preview)
	ws_row.add_child(_ws_preview_btn)
	_ws_clear_btn = Button.new()
	_ws_clear_btn.text = "Clear"
	_ws_clear_btn.custom_minimum_size = Vector2(56, 26)
	_ws_clear_btn.pressed.connect(_on_ws_clear)
	ws_row.add_child(_ws_clear_btn)
	_ws_designate_btn = Button.new()
	_ws_designate_btn.text = "Designate"
	_ws_designate_btn.tooltip_text = "Add graph catchment wired to this pond (adds pond to graph if needed)"
	_ws_designate_btn.custom_minimum_size = Vector2(88, 26)
	_ws_designate_btn.pressed.connect(_on_ws_designate)
	ws_row.add_child(_ws_designate_btn)
	_ws_remove_btn = Button.new()
	_ws_remove_btn.text = "Remove WS"
	_ws_remove_btn.custom_minimum_size = Vector2(88, 26)
	_ws_remove_btn.pressed.connect(_on_ws_remove)
	ws_row.add_child(_ws_remove_btn)


func _field_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 10)
	return l


func _load_from_loader() -> bool:
	if _loader == null or not _loader.has_method("get_pond_info"):
		return false
	var info: Dictionary = _loader.call("get_pond_info", _idx)
	if not bool(info.get("valid", false)):
		return false
	_syncing = true
	var is_user := bool(info.get("user", false))
	_title_lbl.text = str(info.get("label", "Pond")) if is_user else "Pond (map)"
	var stock := float(info.get("stock_l", 0.0))
	var fill_pct := float(info.get("fill_frac", 0.0)) * 100.0
	_meta_lbl.text = "%.0f m²  ·  rim %.1f m  ·  floor %.1f m  ·  %.0f L (%.0f%%)" % [
		float(info.get("area_m2", 0.0)), float(info.get("rim_m", 0.0)),
		float(info.get("floor_m", 0.0)), stock, fill_pct]
	if not is_user:
		# Map ponds are read-only (all the controls below are disabled); say why so
		# the greyed-out slider/capacity/fill don't look broken.
		_meta_lbl.text += "\nMap pond — read-only. Carve a pond with the terrain tool to edit level & capacity."

	var rim := float(info.get("rim_m", 1.0))
	var floor_y := float(info.get("floor_m", 0.0))
	if rim <= floor_y + 0.05:
		rim = floor_y + 1.0
	var lo := floor_y + 0.02
	var hi := rim - 0.05
	if hi <= lo:
		hi = lo + 0.5
	_level_slider.min_value = lo
	_level_slider.max_value = hi
	_level_slider.value = clampf(float(info.get("level_m", hi)), lo, hi)
	_level_slider.editable = is_user
	_level_lbl.text = "%.2f m" % _level_slider.value

	var cap_mode := str(info.get("capacity_mode", "auto"))
	_cap_mode_opt.select(1 if cap_mode == "manual" else 0)
	_cap_mode_opt.disabled = not is_user
	_vol_spin.value = float(info.get("capacity_l", 1000.0))
	_vol_spin.editable = is_user and cap_mode == "manual"
	var terrain_cap := float(info.get("terrain_capacity_l", info.get("default_capacity_l", 0.0)))
	_terrain_cap_lbl.text = "Terrain volume ≈ %.0f L (Auto)" % terrain_cap
	_recalc_btn.disabled = not is_user

	var fill_mode := str(info.get("fill_mode", "auto"))
	_fill_mode_opt.select(1 if fill_mode == "manual" else 0)
	_fill_mode_opt.disabled = not is_user
	_level_slider.editable = is_user and fill_mode != "manual"
	var basin_rim := float(info.get("basin_rim_m", rim))
	var mx := float(info.get("max_level_m", NAN))
	if _max_spin != null:
		_max_spin.value = basin_rim if is_nan(mx) else mx
	if _max_lbl != null:
		_max_lbl.text = "Basin rim %.2f m — at the rim (inflow spills there)" % basin_rim if (is_nan(mx) or mx <= basin_rim + 0.005) \
				else "Basin rim %.2f m — dammed +%.2f m (capacity +%.0f L over the footprint)" % [
					basin_rim, mx - basin_rim, (mx - basin_rim) * float(info.get("area_m2", 0.0)) * 1000.0]

	var on_graph := bool(info.get("on_graph", false))
	_graph_btn.text = "Remove from graph" if on_graph else "Add to graph"

	_del_btn.text = "Delete pond"
	_del_btn.visible = is_user
	_refresh_watershed_row(info)
	_syncing = false
	return true


func _refresh_watershed_row(info: Dictionary) -> void:
	if _ws_lbl == null:
		return
	var has_ws := false
	if _loader != null and _loader.has_method("pond_has_watershed_catchment"):
		has_ws = bool(_loader.call("pond_has_watershed_catchment", _idx))
	var preview: Dictionary = {}
	if _loader != null and _loader.has_method("get_watershed_preview"):
		preview = _loader.call("get_watershed_preview") as Dictionary
	var tag := str(info.get("tag", ""))
	if bool(preview.get("valid", false)) and str(preview.get("pond_tag", "")) == tag:
		var ha := float(preview.get("area_m2", 0.0)) / 10000.0
		_ws_lbl.text = "Upstream ~%.2f ha (%d cells)%s" % [
			ha, int(preview.get("cell_count", 0)),
			" · on graph" if has_ws else ""]
	elif has_ws:
		_ws_lbl.text = "Watershed catchment on graph — Preview to refresh outline"
	else:
		_ws_lbl.text = "Analyze hillside that drains into this pond"
	if _ws_remove_btn != null:
		_ws_remove_btn.disabled = not has_ws


func _on_level_changed(v: float) -> void:
	if _level_lbl != null:
		_level_lbl.text = "%.2f m" % v
	if _syncing or _loader == null or _idx < 0:
		return
	if _loader.has_method("set_pond_fill_level"):
		_loader.call("set_pond_fill_level", _idx, v)
	_load_from_loader()


func _on_max_level_changed(v: float) -> void:
	if _syncing or _loader == null or _idx < 0:
		return
	if _loader.has_method("set_pond_max_level"):
		_loader.call("set_pond_max_level", _idx, v)
	_load_from_loader()


func _on_volume_changed(v: float) -> void:
	if _syncing or _loader == null or _idx < 0:
		return
	if _loader.has_method("set_pond_capacity"):
		_loader.call("set_pond_capacity", _idx, v)
	_load_from_loader()


func _on_cap_mode_selected(idx: int) -> void:
	if _syncing or _loader == null or _idx < 0:
		return
	var mode := "manual" if idx == 1 else "auto"
	if _loader.has_method("set_pond_capacity_mode"):
		_loader.call("set_pond_capacity_mode", _idx, mode)
	_load_from_loader()


func _on_fill_mode_selected(idx: int) -> void:
	if _syncing or _loader == null or _idx < 0:
		return
	var mode := "manual" if idx == 1 else "auto"
	if _loader.has_method("set_pond_fill_mode"):
		_loader.call("set_pond_fill_mode", _idx, mode)
	_load_from_loader()


func _on_recalc() -> void:
	if _loader == null or _idx < 0:
		return
	if _loader.has_method("recompute_pond_volume"):
		_loader.call("recompute_pond_volume", _idx)
	_load_from_loader()


func _on_graph_toggle() -> void:
	if _loader == null or _idx < 0:
		return
	var info: Dictionary = _loader.call("get_pond_info", _idx)
	var on_graph := bool(info.get("on_graph", false))
	if on_graph:
		if _loader.has_method("remove_pond_from_graph"):
			_loader.call("remove_pond_from_graph", _idx)
	else:
		if _loader.has_method("add_pond_to_graph"):
			_loader.call("add_pond_to_graph", _idx)
	_load_from_loader()


func _on_delete() -> void:
	if _loader == null or _idx < 0:
		return
	if _loader.has_method("delete_pond"):
		_loader.call("delete_pond", _idx)
	close()


func _on_ws_preview() -> void:
	if _loader == null or _idx < 0:
		return
	var result: Dictionary = {}
	if _loader.has_method("preview_pond_watershed"):
		result = _loader.call("preview_pond_watershed", _idx) as Dictionary
	_load_from_loader()
	if _ws_lbl != null:
		if bool(result.get("valid", false)):
			_ws_lbl.text = "Upstream ~%.2f ha (%d cells) — teal outline on ground + Elev/Site Plan" % [
				float(result.get("area_m2", 0.0)) / 10000.0,
				int(result.get("cell_count", 0))]
		else:
			_ws_lbl.text = "Watershed failed: %s" % str(result.get("reason", "unknown"))


func _on_ws_clear() -> void:
	if _loader == null:
		return
	if _loader.has_method("clear_watershed_preview"):
		_loader.call("clear_watershed_preview")
	_load_from_loader()


func _on_ws_designate() -> void:
	if _loader == null or _idx < 0:
		return
	var ok := false
	if _loader.has_method("designate_pond_watershed"):
		ok = bool(_loader.call("designate_pond_watershed", _idx))
	_load_from_loader()
	if _ws_lbl != null and not ok:
		_ws_lbl.text = "Designate failed — try Preview first / Add to graph"


func _on_ws_remove() -> void:
	if _loader == null or _idx < 0:
		return
	if _loader.has_method("remove_pond_watershed"):
		_loader.call("remove_pond_watershed", _idx)
	_load_from_loader()
