class_name CsvPlaybackUI
extends Control

## In-game CSV historical datastream upload and time-lapse playback UI.

const CsvHistoryPlayerScript := preload("res://core/csv_history_player.gd")
const CsvEntityMapperScript := preload("res://core/csv_entity_mapper.gd")

const C_BG := Color(0.039, 0.055, 0.098, 0.97)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_AMBER := Color(0.961, 0.620, 0.043, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S := Color(0.580, 0.639, 0.722, 1.0)

const BAR_HEIGHT := 90
const SPEED_PRESETS : Array = [
	{"label": "1×", "x": 1.0},
	{"label": "10×", "x": 10.0},
	{"label": "60×", "x": 60.0},
	{"label": "300×", "x": 300.0},
	{"label": "1800×", "x": 1800.0},
	{"label": "3600×", "x": 3600.0},
]

var _player: Node = null
var _timeline_ui: Control = null
var _main_node: Node = null
var _selected_path: String = ""
var _user_seeking: bool = false

var _picker_panel: PanelContainer
var _path_lbl: Label
var _load_btn: Button
var _progress_bar: ProgressBar

var _playback_panel: PanelContainer
var _status_lbl: Label
var _entity_btn: Button
var _play_btn: Button
var _scrub_slider: HSlider
var _time_lbl: Label
var _speed_opt: OptionButton
var _file_dialog: FileDialog
var _mapping_window: Window
var _mapping_list: VBoxContainer
var _mapping_role_selectors: Dictionary = {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_player = CsvHistoryPlayerScript.new()
	_player.name = "CsvHistoryPlayer"
	add_child(_player)
	_player.state_changed.connect(_on_player_state_changed)
	_player.loading_progress.connect(_on_loading_progress)
	_player.data_ready.connect(_on_data_ready)
	_player.playback_progress.connect(_on_playback_progress)
	call_deferred("_resolve_nodes")


func open_picker() -> void:
	if _player != null and int(_player.get_state()) in [
			_player.State.PLAYING, _player.State.PAUSED, _player.State.LOADING]:
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_selected_path = ""
	if _path_lbl != null:
		_path_lbl.text = "(no file selected)"
	if _progress_bar != null:
		_progress_bar.visible = false
		_progress_bar.value = 0.0
	if _load_btn != null:
		_load_btn.disabled = true
	move_to_front()
	if _picker_panel != null:
		_picker_panel.move_to_front()
	_show_picker(true)


func close_picker() -> void:
	_show_picker(false)


func is_playback_active() -> bool:
	if _player == null:
		return false
	return int(_player.get_state()) in [
		_player.State.LOADING, _player.State.READY,
		_player.State.PLAYING, _player.State.PAUSED]


func _resolve_nodes() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var ul := get_parent()
	if ul != null:
		_timeline_ui = ul.get_node_or_null("TimelineUI") as Control
	var sc := tree.current_scene
	if sc != null and sc.name == "Main":
		_main_node = sc
	else:
		_main_node = Services.get_main()
	if _player != null and _player.has_method("setup"):
		var ha_client := tree.root.get_node_or_null("HAClient")
		if ha_client == null:
			for child in tree.root.get_children():
				var c := child.get_node_or_null("HAClient")
				if c != null:
					ha_client = c
					break
		var linker: Node = null
		var graph := tree.root.find_child("SystemGraphView", true, false)
		if graph != null:
			linker = graph.get_node_or_null("HAEntityLinker")
		_player.setup(linker, ha_client, _main_node)


func _build_ui() -> void:
	_build_picker()
	_build_playback_bar()
	_build_file_dialog()
	_build_mapping_window()


func _build_picker() -> void:
	_picker_panel = PanelContainer.new()
	_picker_panel.visible = false
	_picker_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_picker_panel.set_anchors_preset(Control.PRESET_CENTER)
	_picker_panel.custom_minimum_size = Vector2(520, 220)
	_picker_panel.offset_left = -260
	_picker_panel.offset_top = -110
	_picker_panel.offset_right = 260
	_picker_panel.offset_bottom = 110
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.75)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_picker_panel.add_theme_stylebox_override("panel", sb)
	add_child(_picker_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_picker_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Historical Datastream Playback"
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Load a Home Assistant CSV export (entity_id,state,last_changed)"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 12)
	vbox.add_child(hint)

	var path_row := HBoxContainer.new()
	path_row.add_theme_constant_override("separation", 8)
	vbox.add_child(path_row)

	_path_lbl = Label.new()
	_path_lbl.text = "(no file selected)"
	_path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_lbl.clip_text = true
	_path_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_path_lbl.add_theme_color_override("font_color", C_TEXT)
	_path_lbl.add_theme_font_size_override("font_size", 13)
	path_row.add_child(_path_lbl)

	var browse_btn := Button.new()
	browse_btn.text = "Browse…"
	browse_btn.pressed.connect(_on_browse_pressed)
	path_row.add_child(browse_btn)

	_progress_bar = ProgressBar.new()
	_progress_bar.visible = false
	_progress_bar.custom_minimum_size = Vector2(0, 18)
	_progress_bar.max_value = 1.0
	vbox.add_child(_progress_bar)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(close_picker)
	btn_row.add_child(cancel_btn)

	_load_btn = Button.new()
	_load_btn.text = "Load & Play"
	_load_btn.disabled = true
	_load_btn.pressed.connect(_on_load_pressed)
	btn_row.add_child(_load_btn)


func _build_playback_bar() -> void:
	_playback_panel = PanelContainer.new()
	_playback_panel.visible = false
	_playback_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_playback_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_playback_panel.offset_top = -float(BAR_HEIGHT)
	_playback_panel.offset_bottom = 0.0
	_playback_panel.custom_minimum_size = Vector2(0, float(BAR_HEIGHT))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.13, 0.98)
	sb.set_border_width(SIDE_TOP, 2)
	sb.border_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.70)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_playback_panel.add_theme_stylebox_override("panel", sb)
	add_child(_playback_panel)

	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	_playback_panel.add_child(outer)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 0)
	outer.add_child(left)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	left.add_child(title_row)

	var icon := Label.new()
	icon.text = "📂"
	icon.add_theme_font_size_override("font_size", 20)
	title_row.add_child(icon)

	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 0)
	title_row.add_child(titles)

	var hist_title := Label.new()
	hist_title.text = "CSV PLAYBACK"
	hist_title.add_theme_color_override("font_color", Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.95))
	hist_title.add_theme_font_size_override("font_size", 11)
	titles.add_child(hist_title)

	_status_lbl = Label.new()
	_status_lbl.text = "Ready"
	_status_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", 13)
	titles.add_child(_status_lbl)

	_entity_btn = Button.new()
	_entity_btn.text = ""
	_entity_btn.flat = true
	_entity_btn.focus_mode = Control.FOCUS_NONE
	_entity_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_entity_btn.add_theme_color_override("font_color", C_PRIMARY)
	_entity_btn.add_theme_color_override("font_hover_color", C_AMBER)
	_entity_btn.add_theme_font_size_override("font_size", 11)
	_entity_btn.tooltip_text = "Click to map CSV entities to SolarUI readings"
	_entity_btn.pressed.connect(_open_mapping_window)
	left.add_child(_entity_btn)

	var center := HBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 8)
	outer.add_child(center)

	_play_btn = Button.new()
	_play_btn.text = "⏸ Pause"
	_play_btn.custom_minimum_size = Vector2(96, 0)
	_play_btn.pressed.connect(_on_play_pressed)
	center.add_child(_play_btn)

	_scrub_slider = HSlider.new()
	_scrub_slider.min_value = 0.0
	_scrub_slider.max_value = 1.0
	_scrub_slider.step = 0.0001
	_scrub_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub_slider.custom_minimum_size = Vector2(260, 28)
	_scrub_slider.drag_started.connect(_on_scrub_drag_started)
	_scrub_slider.drag_ended.connect(_on_scrub_drag_ended)
	_scrub_slider.value_changed.connect(_on_scrub_value_changed)
	center.add_child(_scrub_slider)

	_time_lbl = Label.new()
	_time_lbl.text = "——"
	_time_lbl.custom_minimum_size = Vector2(184, 0)
	_time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_lbl.add_theme_color_override("font_color", C_TEXT)
	_time_lbl.add_theme_font_size_override("font_size", 13)
	center.add_child(_time_lbl)

	var right := HBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_END
	right.add_theme_constant_override("separation", 6)
	outer.add_child(right)

	var speed_lbl := Label.new()
	speed_lbl.text = "Speed"
	speed_lbl.add_theme_color_override("font_color", C_TEXT_S)
	speed_lbl.add_theme_font_size_override("font_size", 11)
	right.add_child(speed_lbl)

	_speed_opt = OptionButton.new()
	_speed_opt.focus_mode = Control.FOCUS_NONE
	_speed_opt.custom_minimum_size = Vector2(90, 0)
	for i: int in SPEED_PRESETS.size():
		_speed_opt.add_item(str(SPEED_PRESETS[i].get("label", "")), i)
	_speed_opt.select(2)
	_speed_opt.item_selected.connect(_on_speed_changed)
	right.add_child(_speed_opt)

	var stop_btn := Button.new()
	stop_btn.text = "■ Stop"
	stop_btn.pressed.connect(_on_stop_pressed)
	right.add_child(stop_btn)


func _build_file_dialog() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.csv ; CSV files"])
	_file_dialog.title = "Select HA datastream CSV"
	_file_dialog.size = Vector2i(900, 600)
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)


func _build_mapping_window() -> void:
	_mapping_window = Window.new()
	_mapping_window.title = "CSV Entity Mapping"
	_mapping_window.unresizable = false
	_mapping_window.size = Vector2i(760, 520)
	_mapping_window.visible = false
	_mapping_window.close_requested.connect(_close_mapping_window)
	add_child(_mapping_window)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	_mapping_window.add_child(root)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(margin)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 8)
	inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(inner)

	var hint := Label.new()
	hint.text = "Link each CSV entity to an in-game reading. Auto-link guesses from entity names (e.g. pv_input_power → Solar Input)."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 12)
	inner.add_child(hint)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	inner.add_child(header)

	var hdr_entity := Label.new()
	hdr_entity.text = "CSV Entity"
	hdr_entity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_entity.add_theme_color_override("font_color", C_TEXT)
	header.add_child(hdr_entity)

	var hdr_role := Label.new()
	hdr_role.text = "SolarUI Reading"
	hdr_role.custom_minimum_size = Vector2(220, 0)
	hdr_role.add_theme_color_override("font_color", C_TEXT)
	header.add_child(hdr_role)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 320)
	inner.add_child(scroll)

	_mapping_list = VBoxContainer.new()
	_mapping_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mapping_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_mapping_list)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 8)
	inner.add_child(btn_row)

	var autolink_btn := Button.new()
	autolink_btn.text = "Auto-link"
	autolink_btn.pressed.connect(_on_mapping_autolink_pressed)
	btn_row.add_child(autolink_btn)

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.pressed.connect(_on_mapping_apply_pressed)
	btn_row.add_child(apply_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close_mapping_window)
	btn_row.add_child(close_btn)


func _open_mapping_window() -> void:
	if _player == null or _mapping_window == null:
		return
	if int(_player.get_state()) in [_player.State.IDLE, _player.State.STOPPED]:
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_populate_mapping_list()
	move_to_front()
	_mapping_window.popup_centered()
	_update_entity_btn_text()


func _close_mapping_window() -> void:
	if _mapping_window != null:
		_mapping_window.hide()


func _populate_mapping_list() -> void:
	if _mapping_list == null or _player == null:
		return
	for child in _mapping_list.get_children():
		child.queue_free()
	_mapping_role_selectors.clear()

	var entity_ids: Array = _player.get_entity_ids()
	var mapper: RefCounted = _player.get_mapper()
	for eid_v: Variant in entity_ids:
		var eid: String = str(eid_v)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mapping_list.add_child(row)

		var name_lbl := Label.new()
		var short_name := eid
		if short_name.begins_with("sensor."):
			short_name = short_name.substr(7)
		name_lbl.text = short_name
		name_lbl.tooltip_text = eid
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.clip_text = true
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.add_theme_color_override("font_color", C_TEXT)
		row.add_child(name_lbl)

		var opt := OptionButton.new()
		opt.custom_minimum_size = Vector2(220, 0)
		opt.focus_mode = Control.FOCUS_NONE
		var selected_idx := 0
		for i: int in CsvEntityMapperScript.ROLES.size():
			var role_def: Dictionary = CsvEntityMapperScript.ROLES[i]
			opt.add_item(str(role_def.get("label", "")), i)
			var role_id: String = str(role_def.get("id", ""))
			if mapper != null and mapper.get_role_for_entity(eid) == role_id:
				selected_idx = i
		opt.select(selected_idx)
		row.add_child(opt)
		_mapping_role_selectors[eid] = opt


func _collect_mappings_from_ui() -> Dictionary:
	var mappings: Dictionary = {}
	for eid_v: Variant in _mapping_role_selectors.keys():
		var eid: String = str(eid_v)
		var opt: OptionButton = _mapping_role_selectors[eid] as OptionButton
		if opt == null:
			continue
		var idx := opt.selected
		if idx < 0 or idx >= CsvEntityMapperScript.ROLES.size():
			continue
		var role_id: String = str(CsvEntityMapperScript.ROLES[idx].get("id", ""))
		if role_id.is_empty():
			continue
		mappings[role_id] = eid
	return mappings


func _on_mapping_autolink_pressed() -> void:
	if _player == null:
		return
	var mappings: Dictionary = _player.autolink_entities()
	_populate_mapping_list()
	_player.set_role_mappings(mappings)
	_update_entity_btn_text()


func _on_mapping_apply_pressed() -> void:
	if _player == null:
		return
	var mappings := _collect_mappings_from_ui()
	_player.set_role_mappings(mappings)
	_update_entity_btn_text()
	_close_mapping_window()


func _update_entity_btn_text() -> void:
	if _entity_btn == null or _player == null:
		return
	var fname := _selected_path.get_file()
	if fname.is_empty():
		fname = _player.get_source_path().get_file()
	var count: int = _player.get_entity_count()
	var linked := 0
	var mapper: RefCounted = _player.get_mapper()
	if mapper != null:
		linked = mapper.linked_role_count()
	_entity_btn.text = "%s  ·  %d entities  ·  %d linked  ▸" % [fname, count, linked]



func _show_picker(show: bool) -> void:
	if _picker_panel != null:
		_picker_panel.visible = show
	mouse_filter = Control.MOUSE_FILTER_IGNORE if not show and not is_playback_active() else Control.MOUSE_FILTER_STOP


func _show_playback_bar(show: bool) -> void:
	if _playback_panel != null:
		_playback_panel.visible = show
	if _timeline_ui != null:
		_timeline_ui.visible = not show


func _on_browse_pressed() -> void:
	if _file_dialog != null:
		_file_dialog.popup_centered_ratio(0.65)


func _on_file_selected(path: String) -> void:
	_selected_path = path
	if _path_lbl != null:
		_path_lbl.text = path.get_file()
	if _load_btn != null:
		_load_btn.disabled = path.is_empty()


func _on_load_pressed() -> void:
	if _selected_path.is_empty() or _player == null:
		return
	_resolve_nodes()
	var speed_x := 60.0
	if _speed_opt != null and _speed_opt.selected >= 0 and _speed_opt.selected < SPEED_PRESETS.size():
		speed_x = float(SPEED_PRESETS[_speed_opt.selected].get("x", 60.0))
	close_picker()
	_show_playback_bar(true)
	if _status_lbl != null:
		_status_lbl.text = "Loading…"
	if _progress_bar != null:
		_progress_bar.visible = true
		_progress_bar.value = 0.0
	_player.start(_selected_path, {"speed_x": speed_x})


func _on_stop_pressed() -> void:
	if _player != null:
		_player.stop()
	_show_playback_bar(false)
	_show_picker(false)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _on_play_pressed() -> void:
	if _player != null:
		_player.toggle_play()


func _on_speed_changed(idx: int) -> void:
	if _player == null or idx < 0 or idx >= SPEED_PRESETS.size():
		return
	_player.set_speed(float(SPEED_PRESETS[idx].get("x", 60.0)))
	_on_player_state_changed(int(_player.get_state()))


func _on_scrub_drag_started() -> void:
	_user_seeking = true


func _on_scrub_drag_ended(_changed: bool) -> void:
	_user_seeking = false
	if _player != null and _scrub_slider != null:
		_player.seek(_scrub_slider.value)


func _on_scrub_value_changed(_v: float) -> void:
	if _user_seeking and _player != null and _scrub_slider != null:
		_player.seek(_scrub_slider.value)


func _on_player_state_changed(s: int) -> void:
	if _player == null:
		return
	if _play_btn != null:
		match s:
			_player.State.PLAYING:
				_play_btn.text = "⏸ Pause"
			_player.State.PAUSED, _player.State.READY:
				_play_btn.text = "▶ Play"
			_player.State.LOADING:
				_play_btn.text = "…"
			_:
				_play_btn.text = "▶ Play"
	if _status_lbl != null:
		match s:
			_player.State.LOADING:
				_status_lbl.text = "Loading CSV…"
			_player.State.READY:
				_status_lbl.text = "Ready"
			_player.State.PLAYING:
				_status_lbl.text = "Playing %.0f×" % _player.get_speed()
			_player.State.PAUSED:
				_status_lbl.text = "Paused"
			_player.State.STOPPED:
				_status_lbl.text = "Stopped"
				_show_playback_bar(false)
				mouse_filter = Control.MOUSE_FILTER_IGNORE


func _on_loading_progress(parsed: int, total: int) -> void:
	if _progress_bar != null and _picker_panel != null and _picker_panel.visible:
		_progress_bar.visible = true
		if total > 0:
			_progress_bar.value = clampf(float(parsed) / float(total), 0.0, 1.0)
	if _status_lbl != null:
		var pct := 0
		if total > 0:
			pct = int(round(100.0 * float(parsed) / float(total)))
		_status_lbl.text = "Loading CSV… %d%%" % pct


func _on_data_ready(start_t: int, end_t: int, entity_count: int) -> void:
	_update_entity_btn_text()
	if _time_lbl != null:
		_time_lbl.text = "%s … %s" % [
			_format_unix_local(start_t),
			_format_unix_local(end_t),
		]
	if _progress_bar != null:
		_progress_bar.visible = false


func _on_playback_progress(cursor_t: int, fraction: float) -> void:
	if _user_seeking:
		return
	if _scrub_slider != null:
		_scrub_slider.set_value_no_signal(fraction)
	if _time_lbl != null:
		_time_lbl.text = _format_unix_local(cursor_t)


func _format_unix_local(t_unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(t_unix, false)
