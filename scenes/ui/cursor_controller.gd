extends Node

## Single authority for mouse capture during play, pause, and modal UI.

signal capture_state_changed

var _paused: bool = false
var _modal_stack: Array[String] = []
var _modal_close: Dictionary = {}
var _capture_apply_pending: bool = false


func set_paused(v: bool) -> void:
	if _paused == v:
		return
	_paused = v
	_release_gui_focus()
	_request_apply_capture()
	capture_state_changed.emit()


func _ready() -> void:
	set_process_shortcut_input(true)
	var tree := get_tree()
	if tree != null:
		tree.scene_changed.connect(_on_scene_changed)
	# Apply capture on boot — set_paused(false) is a no-op when already unpaused.
	call_deferred("_apply_capture")


func _on_scene_changed() -> void:
	_modal_stack.clear()
	_modal_close.clear()
	call_deferred("_apply_capture")


func is_paused() -> bool:
	return _paused


func has_blocking_modal() -> bool:
	return not _modal_stack.is_empty()


func should_capture_look() -> bool:
	return not _paused and not has_blocking_modal()


func request_modal(name: String, close_callable: Callable = Callable()) -> void:
	if name in _modal_stack:
		return
	_modal_stack.append(name)
	if close_callable.is_valid():
		_modal_close[name] = close_callable
	_request_apply_capture()
	capture_state_changed.emit()


func release_modal(name: String) -> void:
	var idx := _modal_stack.rfind(name)
	if idx >= 0:
		_modal_stack.remove_at(idx)
	_modal_close.erase(name)
	_request_apply_capture()
	capture_state_changed.emit()


func pop_top_modal() -> bool:
	if _modal_stack.is_empty():
		return false
	var top: String = _modal_stack.back()
	if _modal_close.has(top):
		var cb: Callable = _modal_close[top]
		if cb.is_valid():
			cb.call()
			return true
	release_modal(top)
	return true


func _request_apply_capture() -> void:
	if _capture_apply_pending:
		return
	_capture_apply_pending = true
	call_deferred("_apply_capture_deferred")


func _apply_capture_deferred() -> void:
	_capture_apply_pending = false
	if not is_inside_tree():
		return
	var player := _find_player()
	var want_capture := should_capture_look() and player != null
	var want_mode := Input.MOUSE_MODE_CAPTURED if want_capture else Input.MOUSE_MODE_VISIBLE
	if want_capture:
		_release_gui_focus()
	if Input.mouse_mode != want_mode:
		Input.set_mouse_mode(want_mode)
	if player != null:
		player.is_mouse_captured = want_capture


func _apply_capture() -> void:
	_request_apply_capture()


func _release_gui_focus() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.gui_release_focus()


func _shortcut_input(event: InputEvent) -> void:
	if not event.is_action_pressed("sim_pause_toggle"):
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if not _allow_global_pause():
		return
	var tl := _find_timeline_ui()
	if tl != null and tl.has_method("_on_play_pressed"):
		tl.call("_on_play_pressed")
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()


func _allow_global_pause() -> bool:
	var vp := get_viewport()
	if vp == null:
		return true
	var fo := vp.gui_get_focus_owner()
	if fo == null:
		return true
	if fo is TextEdit:
		return false
	if fo is LineEdit:
		# Timeline date spinners — always allow Space to pause/unpause.
		if _is_timeline_date_line_edit(fo as LineEdit):
			return true
		# Other single-line fields (location coords, etc.) — let Space type.
		return false
	return true


func _is_timeline_date_line_edit(le: LineEdit) -> bool:
	var n: Node = le
	while n != null:
		if n.name == "TimelineUI":
			return true
		n = n.get_parent()
	return false


func _find_timeline_ui() -> Node:
	var main := _find_main()
	if main == null:
		return null
	return main.get_node_or_null("UILayer/TimelineUI")


func _find_player() -> Node:
	var main := _find_main()
	if main == null:
		return null
	return main.get_node_or_null("Player")


func _find_main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene != null and scene.has_method("get_lunar_phase"):
		return scene
	for n in tree.get_nodes_in_group("main_scene"):
		if n.has_method("get_lunar_phase"):
			return n
	return null


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if pop_top_modal():
		get_viewport().set_input_as_handled()
