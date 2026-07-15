extends PanelContainer

## Edit drawer for a placed prop — transform tweaks + delete/replace.

const C_BG := Color(0.039, 0.055, 0.098, 0.98)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)

const DRAWER_HEIGHT := 300.0

var _loader: Node = null
var _prop_id: String = ""
var _syncing := false

var _model_lbl: Label
var _model_option: OptionButton
var _off_x: SpinBox
var _off_y: SpinBox
var _off_z: SpinBox
var _yaw: SpinBox
var _pitch: SpinBox
var _roll: SpinBox
var _scale: SpinBox
var _collision_check: CheckBox
var _del_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_layout_drawer()


func _layout_drawer() -> void:
	UiScreenLayout.pin_above_timeline(self, DRAWER_HEIGHT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout_drawer()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open_for_prop(prop_id: String) -> void:
	_prop_id = prop_id
	_refresh_model_list()
	_load_from_layer()
	_layout_drawer()
	visible = true
	CursorController.request_modal("placed_prop_edit", Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	visible = false
	_prop_id = ""
	CursorController.release_modal("placed_prop_edit")


func _build_ui() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = C_PANEL
	panel_style.border_color = C_BORDER
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", panel_style)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Placed Prop"
	title.add_theme_color_override("font_color", C_TEXT)
	vbox.add_child(title)

	_model_lbl = Label.new()
	_model_lbl.add_theme_color_override("font_color", C_TEXT)
	vbox.add_child(_model_lbl)

	_model_option = OptionButton.new()
	_model_option.item_selected.connect(_on_model_changed)
	vbox.add_child(_model_option)

	_off_x = _spin(0.01)
	_off_y = _spin(0.01)
	_off_z = _spin(0.01)
	_yaw = _spin(1.0, -360.0, 360.0)
	_pitch = _spin(1.0, -360.0, 360.0)
	_roll = _spin(1.0, -360.0, 360.0)
	_scale = _spin(0.05, 0.05, 20.0)
	vbox.add_child(_labeled_row("Offset X", _off_x))
	vbox.add_child(_labeled_row("Height Offset", _off_y))
	vbox.add_child(_labeled_row("Offset Z", _off_z))
	vbox.add_child(_labeled_row("Yaw °", _yaw))
	vbox.add_child(_labeled_row("Pitch °", _pitch))
	vbox.add_child(_labeled_row("Roll °", _roll))
	vbox.add_child(_labeled_row("Scale", _scale))

	for spin_box in [_off_x, _off_y, _off_z, _yaw, _pitch, _roll, _scale]:
		spin_box.value_changed.connect(_on_spin_changed)

	_collision_check = CheckBox.new()
	_collision_check.text = "Collision enabled"
	_collision_check.button_pressed = true
	_collision_check.add_theme_color_override("font_color", C_TEXT)
	_collision_check.toggled.connect(_on_collision_toggled)
	vbox.add_child(_collision_check)

	var actions := HBoxContainer.new()
	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.pressed.connect(_on_apply)
	actions.add_child(apply_btn)
	_del_btn = Button.new()
	_del_btn.text = "Delete"
	_del_btn.pressed.connect(_on_delete)
	actions.add_child(_del_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	actions.add_child(close_btn)
	vbox.add_child(actions)


func _spin(step: float, min_v: float = -99999.0, max_v: float = 99999.0) -> SpinBox:
	var spin_box := SpinBox.new()
	spin_box.step = step
	spin_box.min_value = min_v
	spin_box.max_value = max_v
	spin_box.allow_greater = true
	spin_box.allow_lesser = true
	return spin_box


func _labeled_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 72.0
	lbl.add_theme_color_override("font_color", C_TEXT)
	row.add_child(lbl)
	row.add_child(control)
	return row


func _refresh_model_list() -> void:
	_model_option.clear()
	for m in ModelCatalog.all_models():
		_model_option.add_item(str(m.get("label", m.get("id", "?"))))
		_model_option.set_item_metadata(_model_option.item_count - 1, str(m.get("id", "")))


func _load_from_layer() -> void:
	if _loader == null or not _loader.has_method("get_prop_record"):
		return
	var rec: Variant = _loader.call("get_prop_record", _prop_id)
	if not (rec is Dictionary):
		return
	var d: Dictionary = rec
	_syncing = true
	_model_lbl.text = "Model: %s" % str(d.get("model_id", ""))
	for i in _model_option.item_count:
		if str(_model_option.get_item_metadata(i)) == str(d.get("model_id", "")):
			_model_option.select(i)
			break
	_off_x.value = float(d.get("x", 0.0))
	if d.has("y_offset"):
		_off_y.value = float(d.get("y_offset", 0.0))
	elif d.has("y"):
		# Convert legacy absolute y coordinate to relative height offset
		var foot_y := ModelCatalog.foot_local_y(str(d.get("model_id", "")))
		var user_scale := float(d.get("scale", 1.0))
		var world_scale := ModelCatalog.resolved_scale(str(d.get("model_id", "")), user_scale)
		var gy := float(d.get("ground_y", 0.0))
		var grounded_y := gy - foot_y * world_scale
		_off_y.value = float(d["y"]) - grounded_y
	else:
		_off_y.value = 0.0
	_off_z.value = float(d.get("z", 0.0))
	_yaw.value = float(d.get("yaw", 0.0))
	_pitch.value = float(d.get("pitch", 0.0))
	_roll.value = float(d.get("roll", 0.0))
	_scale.value = float(d.get("scale", 1.0))
	_collision_check.button_pressed = bool(d.get("collision_enabled", true))

	if _del_btn != null:
		var is_osm := str(d.get("type", "")) == "osm"
		if is_osm:
			_del_btn.text = "Revert to OSM"
		else:
			_del_btn.text = "Delete"
	_syncing = false
	_preview_live()


func _on_model_changed(_idx: int) -> void:
	if _syncing:
		return
	_preview_live()


func _on_spin_changed(_v: float) -> void:
	if _syncing:
		return
	_preview_live()


## Collision is applied immediately (not just previewed) — unlike the transform
## fields, there's no live-preview path for it on the runtime prop, and leaving a
## player able to get stuck inside/on top of a placed object until they hit
## "Apply" would defeat the point of an escape-hatch toggle.
func _on_collision_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, {"collision_enabled": pressed})


func _preview_live() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("preview_prop"):
		var model_id := ""
		if _model_option.selected >= 0:
			model_id = str(_model_option.get_item_metadata(_model_option.selected))
		_loader.call("preview_prop", _prop_id, {
			"model_id": model_id,
			"x": _off_x.value, "y_offset": _off_y.value, "z": _off_z.value,
			"yaw": _yaw.value, "pitch": _pitch.value, "roll": _roll.value,
			"scale": _scale.value,
		})


func _on_apply() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var model_id := ""
	if _model_option.selected >= 0:
		model_id = str(_model_option.get_item_metadata(_model_option.selected))
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, {
			"model_id": model_id,
			"x": _off_x.value, "y_offset": _off_y.value, "z": _off_z.value,
			"yaw": _yaw.value, "pitch": _pitch.value, "roll": _roll.value,
			"scale": _scale.value,
		})
	_model_lbl.text = "Model: %s" % model_id


func _on_delete() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("delete_prop_by_id"):
		_loader.call("delete_prop_by_id", _prop_id)
	close()
