extends Control

## Pond settings (Ctrl-click a pond → open): a `Drawer` above the timeline
## bar for the one pond. Level scrub, Auto / Manual capacity & fill, the max
## fill level (a dam above the rim), the watershed catchment, add to / remove
## from the graph, delete. Ponds are never auto-added to the graph.
##
## The chrome is the kit's: the drawer pins itself above the bar's live
## height, sizes itself to its rows, claims the HUD's bottom region and the
## cursor modal; the rows are `FormRow`s. This file owns only what is a pond.

const DRAWER_NAME := "pond_edit"

var _loader: Node = null
var _idx: int = -1
var _syncing := false

var _drawer: Drawer
var _level_row: FormRow
var _level_slider: HSlider
var _level_lbl: Label
var _max_row: FormRow
var _max_spin: SpinBox
var _max_lbl: Label
var _cap_row: FormRow
var _cap_mode_opt: OptionButton
var _vol_row: FormRow
var _vol_spin: SpinBox
var _terrain_cap_lbl: Label
var _recalc_btn: Button
var _fill_row: FormRow
var _fill_mode_opt: OptionButton
var _graph_btn: Button
var _del_btn: Button
var _ws_lbl: Label
var _ws_preview_btn: Button
var _ws_clear_btn: Button
var _ws_designate_btn: Button
var _ws_remove_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open_for_pond(idx: int) -> void:
	_idx = idx
	if not _load_from_loader():
		return
	visible = true
	_drawer.open()


func close() -> void:
	if not visible and not _drawer.is_open():
		return
	visible = false
	_idx = -1
	_drawer.close()


func is_open() -> bool:
	return _drawer != null and _drawer.is_open()


func _build_ui() -> void:
	_drawer = Drawer.create("Pond settings", DRAWER_NAME)
	add_child(_drawer)
	_drawer.closed.connect(close)

	# Water level ---------------------------------------------------------
	var level_col := Drawer.column(300.0)
	_drawer.body.add_child(level_col)
	_level_slider = HSlider.new()
	_level_slider.step = 0.05
	_level_slider.custom_minimum_size = Vector2(140, 0)
	_level_slider.value_changed.connect(_on_level_changed)
	_level_row = FormRow.make("Water level", _level_slider,
		"The pond's surface. T → Rain / Drain scrubs it in the world too", "", "level_m")
	_level_lbl = Label.new()
	_level_lbl.add_theme_font_override("font", UITheme.font("medium", true))
	_level_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_level_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_level_lbl.custom_minimum_size = Vector2(60, 0)
	_level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_level_row.add_child(_level_lbl)
	level_col.add_child(_level_row)
	# Max fill level: a dam above the basin's natural rim. Map ponds take it
	# too — it is the one thing a player can set on a pond they did not carve.
	_max_row = FormRow.spin("Max fill level", -1000.0, 9000.0, 0.05, "m", _on_max_level_changed,
		"The highest the pond may fill (world metres). Above the basin rim it is a dam: capacity grows as a wall over the footprint, inflow can raise the pond past the rim, and a siphon crest above the rim becomes reachable. Or Ctrl-aim the pond surface in 3D and drag it up.",
		"max_level_m")
	_max_spin = _max_row.control as SpinBox
	var max_reset := Button.new()
	max_reset.text = "Rim"
	max_reset.tooltip_text = "Back to the basin's natural rim"
	max_reset.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(max_reset)
	max_reset.pressed.connect(func() -> void: _on_max_level_changed(NAN))
	_max_row.add_child(max_reset)
	level_col.add_child(_max_row)
	_max_lbl = _note()
	level_col.add_child(_max_lbl)

	# Capacity ------------------------------------------------------------
	var cap_col := Drawer.column(300.0)
	_drawer.body.add_child(cap_col)
	_cap_row = FormRow.option("Capacity", [[0, "Auto (terrain)"], [1, "Manual"]],
		func(_m): _on_cap_mode_selected(_cap_mode_opt.selected),
		"Auto integrates the basin's bathymetry; Manual is a volume you type", "capacity_mode")
	_cap_mode_opt = _cap_row.control as OptionButton
	cap_col.add_child(_cap_row)
	_vol_row = FormRow.spin("Volume", 1.0, 1.0e9, 100.0, "L", _on_volume_changed,
		"The pond's capacity when Manual", "capacity_l")
	_vol_spin = _vol_row.control as SpinBox
	_vol_spin.allow_greater = true
	cap_col.add_child(_vol_row)
	var terr_row := HBoxContainer.new()
	terr_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	cap_col.add_child(terr_row)
	_terrain_cap_lbl = _note()
	_terrain_cap_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	terr_row.add_child(_terrain_cap_lbl)
	_recalc_btn = Button.new()
	_recalc_btn.text = "Recalculate"
	_recalc_btn.tooltip_text = "Recompute Auto capacity from the terrain's bathymetry"
	_recalc_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_recalc_btn)
	_recalc_btn.pressed.connect(_on_recalc)
	terr_row.add_child(_recalc_btn)

	# Fill + watershed ----------------------------------------------------
	var fill_col := Drawer.column(0.0)
	fill_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawer.body.add_child(fill_col)
	_fill_row = FormRow.option("Fill", [[0, "Auto (water surface)"], [1, "Manual"]],
		func(_m): _on_fill_mode_selected(_fill_mode_opt.selected),
		"Auto follows the 3D water surface; Manual holds the level you set", "fill_mode")
	_fill_mode_opt = _fill_row.control as OptionButton
	fill_col.add_child(_fill_row)
	fill_col.add_child(SectionHeader.make("Watershed", "waves"))
	_ws_lbl = _note()
	_ws_lbl.text = "The hillside that drains into this pond"
	fill_col.add_child(_ws_lbl)
	var ws_row := HBoxContainer.new()
	ws_row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	fill_col.add_child(ws_row)
	_ws_preview_btn = _small_button("Preview", "Trace the ground uphill of the pond and outline the basin that drains into it", _on_ws_preview)
	ws_row.add_child(_ws_preview_btn)
	_ws_clear_btn = _small_button("Clear", "Hide the outline", _on_ws_clear)
	ws_row.add_child(_ws_clear_btn)
	_ws_designate_btn = _small_button("Designate", "Add a graph catchment wired to this pond (adds the pond to the graph if needed)", _on_ws_designate)
	ws_row.add_child(_ws_designate_btn)
	_ws_remove_btn = _small_button("Remove", "Take the catchment off the graph", _on_ws_remove)
	ws_row.add_child(_ws_remove_btn)

	# Actions -------------------------------------------------------------
	_graph_btn = _drawer.add_action("Add to graph", Drawer.PRIMARY, _on_graph_toggle,
		"A pond on the graph is a tank the site's water flows through")
	_del_btn = _drawer.add_action("Delete pond", Drawer.DESTRUCTIVE, _on_delete,
		"Remove this pond and its water record")


func _note() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.mouse_entered.connect(func() -> void: l.tooltip_text = l.text)
	return l


func _small_button(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 26)
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _load_from_loader() -> bool:
	if _loader == null or not _loader.has_method("get_pond_info"):
		return false
	var info: Dictionary = _loader.call("get_pond_info", _idx)
	if not bool(info.get("valid", false)):
		return false
	_syncing = true
	var is_user := bool(info.get("user", false))
	var stock := float(info.get("stock_l", 0.0))
	var fill_pct := float(info.get("fill_frac", 0.0)) * 100.0
	var meta := "%s · rim %.1f m · floor %.1f m · %s (%s)" % [
		UiText.num(float(info.get("area_m2", 0.0)), "m²"), float(info.get("rim_m", 0.0)),
		float(info.get("floor_m", 0.0)), UiText.num(stock, "L"), UiText.pct(fill_pct / 100.0)]
	if not is_user:
		# Map ponds are read-only (the level, capacity and fill controls are
		# disabled); say why so the greyed-out rows don't look broken.
		meta += " · a map pond: carve one with the terrain tool to set its level and capacity"
	_drawer.set_title(str(info.get("label", "Pond")) if is_user else "Pond (map)", meta)

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
	_terrain_cap_lbl.text = I18n.f("Terrain volume ≈ {terrain_cap} (Auto)", {"terrain_cap": UiText.num(terrain_cap, "L")})
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
		_max_lbl.text = I18n.f("Basin rim {basin_rim} m — at the rim (inflow spills there)", {
			"basin_rim": "%.2f" % basin_rim,
		}) if (is_nan(mx) or mx <= basin_rim + 0.005) else "Basin rim %.2f m — dammed +%.2f m (capacity +%s over the footprint)" % [ basin_rim, mx - basin_rim, UiText.num((mx - basin_rim) * float(info.get("area_m2", 0.0)) * 1000.0, "L")]

	var on_graph := bool(info.get("on_graph", false))
	_graph_btn.text = "Remove from graph" if on_graph else "Add to graph"
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
		_ws_lbl.text = I18n.f("Upstream ~{ha} ha ({cell_count}){has_ws}", {
			"ha": "%.2f" % ha,
			"cell_count": UiText.count(int(preview.get("cell_count", 0)), "cell"),
			"has_ws": " · on the graph" if has_ws else "",
		})
	elif has_ws:
		_ws_lbl.text = "A watershed catchment is on the graph — Preview refreshes the outline"
	else:
		_ws_lbl.text = "The hillside that drains into this pond"
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
			_ws_lbl.text = I18n.f("Upstream ~{area_m2} ha ({cell_count}) — a teal outline on the ground and in the Elevation and Site Plan lenses", {
				"area_m2": "%.2f" % (float(result.get("area_m2", 0.0)) / 10000.0),
				"cell_count": UiText.count(int(result.get("cell_count", 0)), "cell"),
			})
		else:
			_ws_lbl.text = I18n.f("The watershed could not be traced: {reason}", {"reason": str(result.get("reason", "unknown"))})


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
		_ws_lbl.text = "Could not designate — Preview the watershed first, or add the pond to the graph"


func _on_ws_remove() -> void:
	if _loader == null or _idx < 0:
		return
	if _loader.has_method("remove_pond_watershed"):
		_loader.call("remove_pond_watershed", _idx)
	_load_from_loader()
