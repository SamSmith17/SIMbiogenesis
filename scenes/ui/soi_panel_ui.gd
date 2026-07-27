extends Control

## Modal panel for Sphere of Influence radius and origin editing.

const MODAL_NAME := "soi_panel"

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _radius_slider: HSlider = null
var _radius_label: Label = null
var _area_label: Label = null
var _placement_hint: Label = null
var _active := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_build_ui()
	var svc := get_node_or_null("/root/SoiService")
	if svc != null:
		svc.soi_changed.connect(_refresh_labels)


func open_panel() -> void:
	if _active:
		return
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	CursorController.request_modal(MODAL_NAME, Callable(self, "close_panel"))
	var svc := get_node_or_null("/root/SoiService")
	if svc != null:
		svc.set_edit_mode(true)
	_refresh_labels()
	if _radius_slider != null:
		_radius_slider.grab_focus()


func close_panel() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(MODAL_NAME)
	var svc := get_node_or_null("/root/SoiService")
	if svc != null:
		svc.set_edit_mode(false)
		svc.cancel_placement_mode()


func on_placement_done() -> void:
	_refresh_labels()


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(420, 0)
	add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -210
	_panel.offset_right = 210
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Sphere of Influence — Settings"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Stewardship volume for this site. Prefer the Snowglobe view to resize the sphere visually."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vbox.add_child(subtitle)

	_radius_label = Label.new()
	_radius_label.add_theme_color_override("font_color", UITheme.C_TEXT)
	_radius_label.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	vbox.add_child(_radius_label)

	_radius_slider = HSlider.new()
	_radius_slider.min_value = SoiConfig.MIN_RADIUS_M
	_radius_slider.max_value = SoiConfig.MAX_RADIUS_M
	_radius_slider.step = 5.0
	_radius_slider.value = SoiConfig.DEFAULT_RADIUS_M
	_radius_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_radius_slider.tooltip_text = "Radius in metres — or open Snowglobe to resize while looking at the globe"
	_radius_slider.value_changed.connect(_on_radius_changed)
	vbox.add_child(_radius_slider)

	_area_label = Label.new()
	_area_label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vbox.add_child(_area_label)

	_placement_hint = Label.new()
	_placement_hint.text = "Move the origin: Ctrl/Alt-drag the red map pin in the world."
	_placement_hint.visible = true
	_placement_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_placement_hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vbox.add_child(_placement_hint)

	var snow_btn := Button.new()
	snow_btn.text = "Open Snowglobe (recommended)"
	snow_btn.pressed.connect(_on_snowglobe)
	vbox.add_child(snow_btn)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	var reset_btn := Button.new()
	reset_btn.text = "Reset to map centre"
	reset_btn.pressed.connect(_on_reset_center)
	row.add_child(reset_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close_panel)
	vbox.add_child(close_btn)

	for btn in [reset_btn, snow_btn, close_btn]:
		btn.add_theme_stylebox_override("normal", UITheme.button_style())
		btn.add_theme_stylebox_override("hover", UITheme.button_style("hover"))
		btn.add_theme_stylebox_override("pressed", UITheme.button_style("pressed"))


func _refresh_labels() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc == null:
		return
	var r: float = svc.radius_m()
	if _radius_slider != null and not _radius_slider.has_focus():
		_radius_slider.value = r
	if _radius_label != null:
		_radius_label.text = "Radius: %d m" % int(round(r))
	if _area_label != null:
		var km2: float = svc.area_m2() / 1_000_000.0
		_area_label.text = "Area: %.2f km²" % km2


func _on_radius_changed(v: float) -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc != null:
		svc.set_radius_m(v)
	_refresh_labels()


func _on_reset_center() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc != null:
		svc.reset_to_map_center()
	_refresh_labels()


func _on_snowglobe() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc != null:
		svc.enter_snowglobe()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and _radius_slider != null and _radius_slider.has_focus():
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_radius_slider.value = minf(
					_radius_slider.max_value, _radius_slider.value + 10.0)
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_radius_slider.value = maxf(
					_radius_slider.min_value, _radius_slider.value - 10.0)
				accept_event()
