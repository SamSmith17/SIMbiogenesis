extends Control

## Placed props toolbar — upload, pick model, place / OSM replace modes.

signal mode_changed(active: bool)

const TIMELINE_CLEARANCE := 178.0
const PANEL_HEIGHT := 200.0

var _loader: Node = null
var _active := false
var _place_mode := false
var _osm_mode := false
var _model_id := ""
var _status: Label
var _panel: PanelContainer
var _model_option: OptionButton
var _file_dialog: FileDialog
var _bundle_dialog: FileDialog

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScreenLayout.pin_fullscreen(self)
	_build_ui()
	set_process(false)


func is_panel_open() -> bool:
	return _active


func bind_loader(loader: Node) -> void:
	_loader = loader
	_refresh_models()
	if _model_option.item_count > 0:
		_model_id = str(_model_option.get_item_metadata(0))


func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


func _enter_mode() -> void:
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = true
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_sync_process_flags()
	_layout_panel()
	move_to_front()
	CursorController.request_modal("placed_props", Callable(self, "_exit_mode"))
	mode_changed.emit(true)


func _exit_mode() -> void:
	if not _active:
		return
	_active = false
	_panel.visible = false
	CursorController.release_modal("placed_props")
	_sync_process_flags()
	mode_changed.emit(_place_mode or _osm_mode)


func _cancel_all() -> void:
	_place_mode = false
	_osm_mode = false
	if _active:
		_active = false
		_panel.visible = false
		CursorController.release_modal("placed_props")
	visible = false
	_sync_process_flags()
	mode_changed.emit(false)


func _sync_process_flags() -> void:
	var placing := PlacedPropService.is_placement_active()
	var needs_input := _active or _place_mode or _osm_mode or placing
	set_process(needs_input)
	set_process_shortcut_input(_active or placing or (_place_mode and not _active))
	set_process_input(placing or (_place_mode and not _active))
	set_process_unhandled_input(_place_mode or _osm_mode or placing)
	if not needs_input:
		visible = false


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	margin.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "Placed Props"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "Close (Esc / P)"
	close_btn.pressed.connect(_cancel_all)
	header.add_child(close_btn)
	vbox.add_child(header)

	var row1 := HBoxContainer.new()
	var upload := Button.new()
	upload.text = "Upload GLB/GLTF…"
	upload.pressed.connect(_on_upload)
	row1.add_child(upload)
	_model_option = OptionButton.new()
	_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_option.item_selected.connect(_on_model_pick)
	row1.add_child(_model_option)
	vbox.add_child(row1)

	var row2 := HBoxContainer.new()
	var origin_btn := Button.new()
	origin_btn.text = "Place at origin"
	origin_btn.pressed.connect(_on_place_at_origin)
	row2.add_child(origin_btn)
	var place_btn := Button.new()
	place_btn.text = "Place mode"
	place_btn.toggled.connect(_on_place_toggled)
	place_btn.toggle_mode = true
	row2.add_child(place_btn)
	var osm_btn := Button.new()
	osm_btn.text = "OSM replace"
	osm_btn.toggled.connect(_on_osm_toggled)
	osm_btn.toggle_mode = true
	row2.add_child(osm_btn)
	vbox.add_child(row2)

	var bundle_btn := Button.new()
	bundle_btn.text = "Import LinkageLab bundle…"
	bundle_btn.pressed.connect(_on_import_bundle)
	vbox.add_child(bundle_btn)

	_status = Label.new()
	_status.text = "P — toggle panel"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.glb ; GLB", "*.gltf ; GLTF"])
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)

	_bundle_dialog = FileDialog.new()
	_bundle_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_bundle_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_bundle_dialog.filters = PackedStringArray([
		"*.gamebundle.json ; LinkageLab Game Bundle",
		"*.json ; JSON",
	])
	_bundle_dialog.title = "Import LinkageLab Game Bundle"
	_bundle_dialog.file_selected.connect(_on_bundle_file_selected)
	add_child(_bundle_dialog)


func _layout_panel() -> void:
	UiScreenLayout.pin_bottom_panel(_panel, PANEL_HEIGHT, TIMELINE_CLEARANCE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _active:
		_layout_panel()


func _process(_delta: float) -> void:
	if PlacedPropService.is_placement_active():
		_tick_bundle_placement()
		return
	if not _active:
		return
	if _place_mode or _osm_mode:
		_update_status_from_focus()


func _tick_bundle_placement() -> void:
	var main := _main_node()
	if main == null:
		return
	var cam := main.get_node_or_null("Player/CameraArm/Camera3D") as Camera3D
	if cam == null:
		return
	PlacedPropService.update_placement_aim(main, cam)


func _shortcut_input(event: InputEvent) -> void:
	if PlacedPropService.is_placement_active():
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_confirm_bundle_placement()
			get_viewport().set_input_as_handled()
			return
	if _place_mode and not _active:
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_place_at_screen(event.position)
			get_viewport().set_input_as_handled()
			return
	if not event.is_action_pressed("ui_cancel"):
		return
	if PlacedPropService.is_placement_active():
		_cancel_bundle_placement()
		get_viewport().set_input_as_handled()
		return
	if _active:
		_exit_mode()
		get_viewport().set_input_as_handled()
	elif _place_mode or _osm_mode:
		_place_mode = false
		_osm_mode = false
		_sync_process_flags()
		get_viewport().set_input_as_handled()


func _refresh_models() -> void:
	_model_option.clear()
	for m in ModelCatalog.all_models():
		_model_option.add_item(str(m.get("label", m.get("id", "?"))))
		_model_option.set_item_metadata(_model_option.item_count - 1, str(m.get("id", "")))


func _on_upload() -> void:
	_file_dialog.popup_centered(Vector2i(700, 450))


func _on_import_bundle() -> void:
	_bundle_dialog.popup_centered(Vector2i(900, 600))


func _on_bundle_file_selected(path: String) -> void:
	var result := BUNDLE_IMPORTER_SCRIPT.apply_bundle_file(get_tree(), path)
	if not bool(result.get("ok", false)):
		_set_status("Bundle import failed: %s" % str(result.get("error", "unknown")))
		return
	_refresh_models()
	var model_id := str(result.get("model_id", ""))
	if not model_id.is_empty():
		for i in _model_option.item_count:
			if str(_model_option.get_item_metadata(i)) == model_id:
				_model_option.select(i)
				_model_id = model_id
				break
	_set_status("Imported design — model=%s graph=%s solar=%s" % [
		model_id,
		"yes" if bool(result.get("graph_applied", false)) else "no",
		"yes" if bool(result.get("solar_applied", false)) else "no",
	])
	if bool(result.get("placement_active", false)):
		_begin_bundle_placement_ui()


func notify_bundle_imported(result: Dictionary) -> void:
	if not bool(result.get("placement_active", false)):
		return
	_begin_bundle_placement_ui()


func _begin_bundle_placement_ui() -> void:
	if _active:
		_exit_mode()
	_set_crosshair_prompt("Aim at terrain — Left click to place, Esc to cancel")
	_sync_process_flags()


func _confirm_bundle_placement() -> void:
	if PlacedPropService.confirm_placement():
		_set_status("Placed")
		_place_mode = false
		_clear_crosshair_prompt()
	else:
		# Invalid aim (crosshair not on terrain) — keep placing so the user can re-aim.
		_set_status("Aim at terrain to place")
		_set_crosshair_prompt("Aim at terrain — click to place, Esc to cancel")
	_sync_process_flags()


func _cancel_bundle_placement() -> void:
	if PlacedPropService.is_placement_active():
		PlacedPropService.cancel_placement()
	_place_mode = false
	_clear_crosshair_prompt()
	_set_status("Placement cancelled")
	_sync_process_flags()


func _main_node() -> Node:
	if _loader != null and _loader.get_parent() != null:
		return _loader.get_parent()
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene


func _set_crosshair_prompt(text: String) -> void:
	var ui := get_parent()
	if ui == null:
		return
	var cross := ui.get_node_or_null("CrosshairUI")
	if cross != null and cross.has_method("set_prompt_text"):
		cross.call("set_prompt_text", text)
	if cross != null and cross.has_method("set_target_active"):
		cross.call("set_target_active", true)


func _clear_crosshair_prompt() -> void:
	var ui := get_parent()
	if ui == null:
		return
	var cross := ui.get_node_or_null("CrosshairUI")
	if cross != null and cross.has_method("set_prompt_text"):
		cross.call("set_prompt_text", "")
	if cross != null and cross.has_method("set_target_active"):
		cross.call("set_target_active", false)


func _on_file_selected(path: String) -> void:
	var entry := ModelImporter.import_from_path(path)
	if entry.is_empty():
		_set_status("Import failed")
		return
	_refresh_models()
	for i in _model_option.item_count:
		if str(_model_option.get_item_metadata(i)) == str(entry.get("id", "")):
			_model_option.select(i)
			_model_id = str(entry.get("id", ""))
			break
	_set_status("Imported %s" % str(entry.get("label", "")))


func _on_model_pick(idx: int) -> void:
	_model_id = str(_model_option.get_item_metadata(idx))


func _on_place_toggled(on: bool) -> void:
	_place_mode = on
	if on:
		_osm_mode = false
		if _model_id.is_empty():
			_place_mode = false
			_set_status("Pick a model first")
			_sync_process_flags()
			return
		var main := _main_node()
		if main != null:
			var r := PlacedPropService.begin_placement(main, _model_id)
			if bool(r.get("ok", false)):
				# Close the panel so the mouse is captured for crosshair aiming.
				if _active:
					_exit_mode()
				_set_crosshair_prompt("Aim at terrain — click to place, Esc to cancel")
				_set_status("Placing… aim and click")
			else:
				_place_mode = false
				_set_status("Could not start placement")
	else:
		if PlacedPropService.is_placement_active():
			PlacedPropService.cancel_placement()
		_clear_crosshair_prompt()
		_set_status("Place mode off")
	_sync_process_flags()


func _on_place_at_origin() -> void:
	if _model_id.is_empty():
		_set_status("Pick a model first")
		return
	var main := _main_node()
	if main == null:
		return
	if _loader != null and _loader.has_method("place_prop_at_site_origin"):
		var ok: bool = bool(_loader.call("place_prop_at_site_origin", _model_id))
		_set_status("Placed at site origin (0, 0)" if ok else "Could not place")
		return
	var result := PlacedPropService.place_model(main, _model_id, false)
	_set_status("Placed at site origin (0, 0)" if bool(result.get("ok", false)) else "Could not place")


func _on_osm_toggled(on: bool) -> void:
	_osm_mode = on
	if on:
		_place_mode = false
	_sync_process_flags()
	_set_status("Close panel (Esc/P) then aim at OSM building + click" if on else "OSM replace off")


func _input(event: InputEvent) -> void:
	if PlacedPropService.is_placement_active():
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_confirm_bundle_placement()
			get_viewport().set_input_as_handled()
		return
	if _place_mode and not _active:
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_place_at_screen(event.position)
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if PlacedPropService.is_placement_active():
		return
	if _active:
		return
	if not (_place_mode or _osm_mode):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _osm_mode:
			_replace_osm_at_screen(event.position)
			get_viewport().set_input_as_handled()


func _place_at_screen(screen_pos: Vector2) -> void:
	var main := _main_node()
	if main == null or _model_id.is_empty():
		_set_status("Pick a model first")
		return
	var cam := main.get_node_or_null("Player/CameraArm/Camera3D") as Camera3D
	if cam == null:
		return
	if _loader != null and _loader.has_method("place_prop_from_screen"):
		var ok: bool = bool(_loader.call("place_prop_from_screen", screen_pos, _model_id))
		_set_status("Placed prop" if ok else "Could not place")
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, cam, screen_pos)
	var result := PlacedPropService.place_model_at_hit(main, _model_id, hit)
	_set_status("Placed prop" if bool(result.get("ok", false)) else "Could not place — aim at terrain")


func _replace_osm_at_screen(screen_pos: Vector2) -> void:
	if _loader == null or _model_id.is_empty():
		return
	if _loader.has_method("replace_osm_building_at_screen"):
		var ok: bool = bool(_loader.call("replace_osm_building_at_screen", screen_pos, _model_id))
		_set_status("Building replaced" if ok else "No building under cursor")


func _update_status_from_focus() -> void:
	if _loader == null or not is_instance_valid(_loader):
		return
	if not _loader.has_method("get_building_focus_idx"):
		return
	if _osm_mode:
		var idx: int = int(_loader.call("get_building_focus_idx"))
		if idx >= 0:
			_set_status("Building #%d — close panel then click to replace" % idx)


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg
