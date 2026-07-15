class_name PlacedLightModal
extends Control

signal light_updated
signal light_deleted

var _active := false
var _light_id := ""
var _layer: PlacedLightLayer = null
var _main: Node = null

var _panel: PanelContainer
var _color_picker: ColorPickerButton
var _energy_slider: HSlider
var _range_slider: HSlider
var _type_opt: OptionButton
var _spot_slider: HSlider
var _spot_container: HBoxContainer
var _delete_btn: Button

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

func bind_main(main: Node) -> void:
	_main = main

func open(light_id: String) -> void:
	if _active or _main == null: return
	_layer = PlacedLightService.get_layer(_main)
	if _layer == null: return
	
	_light_id = light_id
	var data = _layer.find_light(light_id)
	if data.is_empty(): return
	
	_type_opt.select(0 if data.get("type", "omni") == "omni" else 1)
	_color_picker.color = Color(str(data.get("color", "ffffff")))
	_energy_slider.value = float(data.get("energy", 1.0))
	_range_slider.value = float(data.get("range", 10.0))
	_spot_slider.value = float(data.get("spot_angle", 45.0))
	_on_type_changed(_type_opt.selected)
	
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP

func close() -> void:
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _main != null and _layer != null:
		PlacedLightService.save_layer(_main)

func _on_type_changed(idx: int) -> void:
	_spot_container.visible = (idx == 1)
	_apply_changes()

func _apply_changes(_v = null) -> void:
	if not _active or _layer == null: return
	var props = {
		"type": "omni" if _type_opt.selected == 0 else "spot",
		"color": _color_picker.color.to_html(false),
		"energy": _energy_slider.value,
		"range": _range_slider.value,
		"spot_angle": _spot_slider.value
	}
	_layer.update_light(_light_id, props)
	light_updated.emit()
	
	var node = PlacedLightRuntime.find_by_id(_main, _light_id)
	if node != null:
		PlacedLightRuntime.apply_record_to_light(node, _layer.find_light(_light_id))

func _on_delete_pressed() -> void:
	if not _active or _layer == null: return
	_layer.remove_light(_light_id)
	var node = PlacedLightRuntime.find_by_id(_main, _light_id)
	if node != null:
		node.queue_free()
	light_deleted.emit()
	close()

func _build_ui() -> void:
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.4)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			close()
	)
	add_child(dim)
	
	_panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = UITheme.C_PANEL
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = UITheme.C_BORDER
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	_panel.add_theme_stylebox_override("panel", style)
	
	_panel.custom_minimum_size = Vector2(300, 0)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	add_child(_panel)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	var marg = MarginContainer.new()
	marg.add_theme_constant_override("margin_left", 16)
	marg.add_theme_constant_override("margin_top", 16)
	marg.add_theme_constant_override("margin_right", 16)
	marg.add_theme_constant_override("margin_bottom", 16)
	marg.add_child(vbox)
	_panel.add_child(marg)
	
	var title = Label.new()
	title.text = "Edit Light"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	
	var sep = HSeparator.new()
	vbox.add_child(sep)
	
	_type_opt = OptionButton.new()
	_type_opt.add_item("Omni Light")
	_type_opt.add_item("Spot Light")
	_type_opt.item_selected.connect(_on_type_changed)
	_add_row("Type", _type_opt, vbox)
	
	_color_picker = ColorPickerButton.new()
	_color_picker.custom_minimum_size = Vector2(100, 30)
	_color_picker.color_changed.connect(_apply_changes)
	_add_row("Color", _color_picker, vbox)
	
	_energy_slider = _make_slider(0.0, 16.0, 0.1)
	_add_row("Energy", _energy_slider, vbox)
	
	_range_slider = _make_slider(1.0, 1000.0, 1.0)
	_add_row("Range (m)", _range_slider, vbox)
	
	_spot_slider = _make_slider(5.0, 90.0, 1.0)
	_spot_container = _add_row("Spot Angle", _spot_slider, vbox)
	
	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	vbox.add_child(close_btn)
	
	_delete_btn = Button.new()
	_delete_btn.text = "Delete Light"
	_delete_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	_delete_btn.pressed.connect(_on_delete_pressed)
	vbox.add_child(_delete_btn)

func _make_slider(min_val: float, max_val: float, step_val: float) -> HSlider:
	var s = HSlider.new()
	s.min_value = min_val
	s.max_value = max_val
	s.step = step_val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(_apply_changes)
	return s

func _add_row(label: String, ctrl: Control, parent: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var l = Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(100, 0)
	row.add_child(l)
	row.add_child(ctrl)
	parent.add_child(row)
	return row
