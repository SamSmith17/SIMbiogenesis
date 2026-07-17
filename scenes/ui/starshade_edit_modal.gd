extends Control

## StarShade-specific editor — swap design (catalog family), edit panel/watts
## specs, and re-seed the system graph via StarShadeGraphSeeder.

const MODAL_NAME := "starshade_edit"

const C_BG := Color(0.039, 0.055, 0.098, 0.85)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S := Color(0.580, 0.639, 0.722, 1.0)

var _loader: Node = null
var _prop_id: String = ""
var _active := false
var _dim: ColorRect = null
var _panel: PanelContainer = null
var _design_opt: OptionButton = null
var _designs: Array = []
var _count_spin: SpinBox = null
var _watts_spin: SpinBox = null
var _status: Label = null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open_for_prop(prop_id: String) -> void:
	if prop_id.is_empty():
		return
	_prop_id = prop_id
	_refresh_designs()
	_load_from_prop()
	_activate()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)
	_prop_id = ""


func _activate() -> void:
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = C_BG
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			close())
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(420, 320)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_panel.add_child(v)

	var title := Label.new()
	title.text = "StarShade Editor"
	title.add_theme_color_override("font_color", C_TEXT)
	title.add_theme_font_size_override("font_size", 18)
	v.add_child(title)

	var hint := Label.new()
	hint.text = "Swap design, set PV specs, then re-seed the system graph."
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)

	v.add_child(_labeled_row("Design", func() -> Control:
		_design_opt = OptionButton.new()
		_design_opt.focus_mode = Control.FOCUS_NONE
		_design_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return _design_opt))

	v.add_child(_labeled_row("Panel count", func() -> Control:
		_count_spin = SpinBox.new()
		_count_spin.min_value = 1
		_count_spin.max_value = 48
		_count_spin.step = 1
		_count_spin.value = StarShadeGraphSeeder.DEFAULT_PANEL_COUNT
		_count_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return _count_spin))

	v.add_child(_labeled_row("Watts / panel", func() -> Control:
		_watts_spin = SpinBox.new()
		_watts_spin.min_value = 50
		_watts_spin.max_value = 600
		_watts_spin.step = 10
		_watts_spin.value = StarShadeGraphSeeder.DEFAULT_PANEL_WATTS
		_watts_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return _watts_spin))

	_status = Label.new()
	_status.add_theme_color_override("font_color", C_TEXT_S)
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	btns.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(btns)

	var apply_design := Button.new()
	apply_design.text = "Apply design"
	apply_design.focus_mode = Control.FOCUS_NONE
	apply_design.pressed.connect(_on_apply_design)
	btns.add_child(apply_design)

	var reseed := Button.new()
	reseed.text = "Re-seed graph"
	reseed.focus_mode = Control.FOCUS_NONE
	reseed.add_theme_color_override("font_color", C_PRIMARY)
	reseed.pressed.connect(_on_reseed)
	btns.add_child(reseed)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	btns.add_child(close_btn)


func _labeled_row(label: String, make_ctl: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size.x = 110
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(lbl)
	row.add_child(make_ctl.call())
	return row


func _refresh_designs() -> void:
	_designs.clear()
	if _design_opt == null:
		return
	_design_opt.clear()
	for m in ModelCatalog.starshade_designs():
		_designs.append(m)
		_design_opt.add_item(str(m.get("label", m.get("id", "?"))))


func _load_from_prop() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var layer = _loader.get("_placed_prop_layer")
	if layer == null:
		return
	var rec: Dictionary = layer.find_by_id(_prop_id) if layer.has_method("find_by_id") else {}
	if rec.is_empty():
		return
	var mid := str(rec.get("model_id", ""))
	for i in _designs.size():
		if str((_designs[i] as Dictionary).get("id", "")) == mid:
			_design_opt.select(i)
			break
	var solar: Dictionary = rec.get("solar", {}) as Dictionary
	if solar.is_empty() and rec.has("record_extra"):
		solar = (rec.get("record_extra", {}) as Dictionary).get("solar", {}) as Dictionary
	_count_spin.value = int(solar.get("panelCount", StarShadeGraphSeeder.DEFAULT_PANEL_COUNT))
	_watts_spin.value = float(solar.get("panelWatts", StarShadeGraphSeeder.DEFAULT_PANEL_WATTS))
	_status.text = "Prop %s" % _prop_id


func _on_apply_design() -> void:
	if _loader == null or _prop_id.is_empty() or _designs.is_empty():
		return
	var idx := _design_opt.selected
	if idx < 0 or idx >= _designs.size():
		return
	var mid := str((_designs[idx] as Dictionary).get("id", ""))
	var layer = _loader.get("_placed_prop_layer")
	if layer == null or not layer.has_method("update_prop"):
		return
	layer.update_prop(_prop_id, {
		"model_id": mid,
		"solar": {
			"panelCount": int(_count_spin.value),
			"panelWatts": float(_watts_spin.value),
		},
	})
	if _loader.has_method("rebuild_placed_props"):
		_loader.call("rebuild_placed_props")
	_status.text = "Design set to %s" % mid


func _on_reseed() -> void:
	_on_apply_design()
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		_status.text = "No main scene"
		return
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null:
		_status.text = "System graph not found"
		return
	var model: GraphModel = sgv.get("model") as GraphModel
	if model == null:
		_status.text = "Graph model missing"
		return
	var n := int(_count_spin.value)
	var w := float(_watts_spin.value)
	if StarShadeGraphSeeder.reseed_graph(model, n, w, StarShadeGraphSeeder.STARSHADE_TAG):
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")
		_status.text = "Re-seeded graph: %d × %.0f W" % [n, w]
	else:
		_status.text = "Re-seed failed"
