extends PanelContainer

## Pond settings modal (Ctrl-click a pond → open). Lets the player override the
## water fill level and storage volume, add the pond to the system graph as a
## catchment + storage tank (or remove it), and delete the pond entirely. Ponds
## are NOT auto-added to the graph anymore — this drawer is the single control
## surface, so cleared/deleted ponds never leave orphaned graph nodes behind.

const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_MUTED := Color(0.62, 0.68, 0.78, 1.0)
const C_ACCENT := Color(0.24, 0.62, 1.0, 1.0)

const DRAWER_HEIGHT := 72.0

var _loader: Node = null
var _idx: int = -1
var _syncing := false

var _title_lbl: Label
var _meta_lbl: Label
var _level_slider: HSlider
var _level_lbl: Label
var _vol_spin: SpinBox
var _graph_btn: Button
var _del_btn: Button


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
	close_btn.text = "✕"
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.custom_minimum_size = Vector2(30, 26)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	root.add_child(row)

	# Fill level -----------------------------------------------------------
	var level_col := VBoxContainer.new()
	level_col.add_theme_constant_override("separation", 0)
	level_col.custom_minimum_size.x = 320.0
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
	_level_slider.custom_minimum_size = Vector2(320, 20)
	_level_slider.value_changed.connect(_on_level_changed)
	level_col.add_child(_level_slider)

	# Volume ---------------------------------------------------------------
	var vol_col := VBoxContainer.new()
	vol_col.add_theme_constant_override("separation", 0)
	row.add_child(vol_col)
	vol_col.add_child(_field_label("Storage volume (L)"))
	_vol_spin = SpinBox.new()
	_vol_spin.step = 100.0
	_vol_spin.min_value = 1.0
	_vol_spin.max_value = 1.0e9
	_vol_spin.allow_greater = true
	_vol_spin.custom_minimum_size.x = 130.0
	_vol_spin.value_changed.connect(_on_volume_changed)
	vol_col.add_child(_vol_spin)

	# Actions --------------------------------------------------------------
	var act_col := VBoxContainer.new()
	act_col.add_theme_constant_override("separation", 2)
	act_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	act_col.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(act_col)
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
	_meta_lbl.text = "%.0f m²   ·   rim %.1f m   ·   floor %.1f m" % [
		float(info.get("area_m2", 0.0)), float(info.get("rim_m", 0.0)),
		float(info.get("floor_m", 0.0))]

	var rim := float(info.get("rim_m", 1.0))
	var floor_y := float(info.get("floor_m", 0.0))
	if rim <= floor_y:
		rim = floor_y + 1.0
	# A little headroom above the rim so the player can raise it into a mound-top pool.
	_level_slider.min_value = floor_y
	_level_slider.max_value = rim + 1.0
	_level_slider.value = clampf(float(info.get("level_m", rim)), floor_y, rim + 1.0)
	_level_slider.editable = is_user
	_level_lbl.text = "%.2f m" % _level_slider.value

	_vol_spin.value = float(info.get("capacity_l", 1000.0))
	_vol_spin.editable = is_user

	var on_graph := bool(info.get("on_graph", false))
	_graph_btn.text = "Remove from graph" if on_graph else "Add to graph"

	# Delete removes the water body itself — only sculpted (user) ponds own their
	# water; OSM map water is deleted upstream, so it only offers the graph toggle.
	_del_btn.text = "Delete pond"
	_del_btn.visible = is_user
	_syncing = false
	return true


func _on_level_changed(v: float) -> void:
	if _level_lbl != null:
		_level_lbl.text = "%.2f m" % v
	if _syncing or _loader == null or _idx < 0:
		return
	if _loader.has_method("set_pond_fill_level"):
		_loader.call("set_pond_fill_level", _idx, v)


func _on_volume_changed(v: float) -> void:
	if _syncing or _loader == null or _idx < 0:
		return
	if _loader.has_method("set_pond_capacity"):
		_loader.call("set_pond_capacity", _idx, v)


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
