extends Control

## Terrain sculpt toolbar — ortho FPV selection + level/raise/lower on the height grid.

signal edit_applied
signal mode_changed(active: bool)

const MODAL_NAME := "terrain_edit"
const TIMELINE_CLEARANCE := 178.0
const PANEL_HEIGHT := 96.0
const HIGHLIGHT_DEBOUNCE_S := 0.07

@export var toggle_action: String = "terrain_edit"

var _loader: Node = null
var _active := false
var _selecting := false
var _sel_start := Vector2.ZERO
var _sel_end := Vector2.ZERO
var _falloff_m := 5.0
var _amount_m := 1.0
var _level_y := 0.0
var _overlay: ColorRect = null
var _capture: ColorRect = null
var _status: Label = null
var _panel: PanelContainer = null
var _locked_yaw := 0.0
var _saved_camera_projection := Camera3D.PROJECTION_PERSPECTIVE
var _saved_camera_size := 500.0
var _highlight_pending := false
var _highlight_timer := 0.0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScreenLayout.pin_fullscreen(self)
	set_process(false)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func _process(delta: float) -> void:
	if not _highlight_pending:
		return
	_highlight_timer += delta
	if _highlight_timer >= HIGHLIGHT_DEBOUNCE_S:
		_highlight_pending = false
		_highlight_timer = 0.0
		_do_refresh_world_highlight()


func _build_ui() -> void:
	_capture = ColorRect.new()
	_capture.name = "SelectionCapture"
	_capture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_capture.color = Color(0.0, 0.0, 0.0, 0.0)
	_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_capture.gui_input.connect(_on_capture_gui_input)
	add_child(_capture)

	_overlay = ColorRect.new()
	_overlay.color = Color(0.2, 0.7, 1.0, 0.22)
	_overlay.visible = false
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)

	_panel = PanelContainer.new()
	UiScreenLayout.pin_bottom_panel(_panel, PANEL_HEIGHT, TIMELINE_CLEARANCE)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_panel.add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	for spec in [
		["Level", _op_level], ["Raise", _op_raise], ["Lower", _op_lower],
		["Parcel", _op_parcel], ["Exit", func() -> void: _exit_mode()],
	]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		row.add_child(b)
	_status = Label.new()
	_status.text = "Press T: terrain sculpt (drag to select)"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_status)
	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 8)
	col.add_child(slider_row)
	_add_slider(slider_row, "Falloff m", 1.0, 20.0, _falloff_m, func(v: float) -> void: _falloff_m = v)
	_add_slider(slider_row, "Amount m", 0.1, 5.0, _amount_m, func(v: float) -> void: _amount_m = v)


func _add_slider(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(72, 0)
	row.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = 0.1
	sl.value = start
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size = Vector2(80, 0)
	sl.value_changed.connect(handler)
	row.add_child(sl)


func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


func _enter_mode() -> void:
	_active = true
	visible = true
	_capture.mouse_filter = Control.MOUSE_FILTER_STOP
	mode_changed.emit(true)
	_status.text = "Top-down view — drag on terrain to select (Esc to exit)"
	CursorController.request_modal(MODAL_NAME, Callable(self, "_exit_mode"))
	_lock_drone_ortho(true)


func _exit_mode() -> void:
	if not _active:
		return
	_active = false
	_selecting = false
	_highlight_pending = false
	set_process(false)
	_overlay.visible = false
	_capture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	mode_changed.emit(false)
	CursorController.release_modal(MODAL_NAME)
	_lock_drone_ortho(false)
	if _loader != null and _loader.has_method("clear_selection_highlight"):
		_loader.call("clear_selection_highlight")
	if _loader != null and _loader.has_method("clear_parcel_rect"):
		_loader.call("clear_parcel_rect")


func _lock_drone_ortho(on: bool) -> void:
	var main: Node = null
	if _loader != null:
		main = _loader.get_parent()
	if main == null:
		return
	var player := main.get_node_or_null("Player") as CharacterBody3D
	if player == null:
		return
	var drone := main.get_node_or_null("FPVDrone")
	if on:
		if player.has_method("_release_mouse"):
			player.call("_release_mouse")
		if player.has_method("_mount_vehicle") and drone != null and drone.has_method("mount"):
			if not drone.is_mounted:
				player.call("_mount_vehicle", drone)
		if drone != null:
			_locked_yaw = drone.rotation.y
			if _loader != null and _loader.has_method("set_sculpt_locked_yaw"):
				_loader.call("set_sculpt_locked_yaw", _locked_yaw)
			drone.set_meta("terrain_edit_ortho", true)
			drone.set_meta("vegetation_edit_ortho", false)
			drone.current_pitch = deg_to_rad(-89.0)
			drone.current_yaw = _locked_yaw
			var cam := _find_drone_camera(drone)
			if cam != null:
				_saved_camera_projection = cam.projection
				_saved_camera_size = cam.size
				cam.projection = Camera3D.PROJECTION_ORTHOGONAL
				cam.size = 500.0
	else:
		if drone != null:
			drone.set_meta("terrain_edit_ortho", false)
			var cam := _find_drone_camera(drone)
			if cam != null:
				cam.projection = _saved_camera_projection
				cam.size = _saved_camera_size
		if drone != null and drone.is_mounted and player.has_method("_capture_mouse"):
			player.call("_capture_mouse")


func _find_drone_camera(drone: Node) -> Camera3D:
	for child in drone.get_children():
		if child is Camera3D:
			return child as Camera3D
		for sub in child.get_children():
			if sub is Camera3D:
				return sub as Camera3D
	return null


func _on_capture_gui_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_exit_mode()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_selecting = true
				_sel_start = mb.position
				_sel_end = mb.position
				_update_overlay()
			else:
				_selecting = false
				_do_refresh_world_highlight()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_exit_mode()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if _selecting:
			_sel_end = (event as InputEventMouseMotion).position
			_update_overlay()
			_schedule_highlight()
			get_viewport().set_input_as_handled()


func _schedule_highlight() -> void:
	_highlight_pending = true
	if not is_processing():
		set_process(true)


func _update_overlay() -> void:
	var r := Rect2(_sel_start, _sel_end - _sel_start)
	r = r.abs()
	_overlay.visible = r.size.length_squared() > 4.0
	_overlay.position = r.position
	_overlay.size = r.size


func set_selection_from_world_rect(rect_min: Vector2, rect_max: Vector2) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_sel_start = cam.unproject_position(Vector3(rect_min.x, 0.0, rect_min.y))
	_sel_end = cam.unproject_position(Vector3(rect_max.x, 0.0, rect_max.y))
	_update_overlay()
	_do_refresh_world_highlight()


func _world_rect_from_screen() -> Dictionary:
	if _loader != null and _loader.has_method("get_parcel_rect"):
		var pr: Rect2 = _loader.call("get_parcel_rect")
		if pr.size.length_squared() > 1.0:
			return {"min": pr.position, "max": pr.position + pr.size}
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return {}
	var a: Variant = _loader.call("terrain_pick_ray", _sel_start)
	var b: Variant = _loader.call("terrain_pick_ray", _sel_end)
	if not (a is Vector3) or not (b is Vector3):
		return {}
	return {
		"min": Vector2(minf((a as Vector3).x, (b as Vector3).x), minf((a as Vector3).z, (b as Vector3).z)),
		"max": Vector2(maxf((a as Vector3).x, (b as Vector3).x), maxf((a as Vector3).z, (b as Vector3).z)),
	}


func _refresh_world_highlight() -> void:
	_schedule_highlight()


func _do_refresh_world_highlight() -> void:
	if _loader == null or not _loader.has_method("update_selection_highlight"):
		return
	var rect := _world_rect_from_screen()
	if rect.is_empty():
		return
	_loader.call("update_selection_highlight", rect["min"], rect["max"])


func _apply_op(op: String) -> void:
	if _loader == null or not _loader.has_method("apply_sculpt_op"):
		return
	var rect := _world_rect_from_screen()
	if rect.is_empty():
		_status.text = "Select an area first (drag on terrain)"
		return
	_loader.call("apply_sculpt_op", op, rect["min"], rect["max"], _falloff_m, _amount_m, _level_y)
	edit_applied.emit()
	_status.text = "Applied %s" % op


func _op_level() -> void:
	_apply_op("level")


func _op_raise() -> void:
	_apply_op("raise")


func _op_lower() -> void:
	_apply_op("lower")


func _op_parcel() -> void:
	if _loader == null or not _loader.has_method("select_nearest_parcel"):
		return
	var center := get_viewport().get_visible_rect().size * 0.5
	var hit: Variant = _loader.call("terrain_pick_ray", center)
	if hit is Vector3:
		_loader.call("select_nearest_parcel", Vector2((hit as Vector3).x, (hit as Vector3).z))
