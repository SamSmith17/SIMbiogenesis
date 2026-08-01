extends Node

## Single authority for mouse capture during play, pause, and modal UI.

signal capture_state_changed

## How often the diagnostic reconcile samples Input.mouse_mode. Matches the
## accumulator shape used by scenes/ui/weather_card_ui.gd.
const RECONCILE_INTERVAL := 0.25

var _paused: bool = false
var _modal_stack: Array[String] = []
var _modal_close: Dictionary = {}
var _capture_apply_pending: bool = false
var _reconcile_accum: float = 0.0
## Mismatches already reported, so a persistent desync warns once, not 4×/second.
var _reported_desyncs: Dictionary = {}


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
	# Whatever we just applied is by definition not a desync.
	_reported_desyncs.clear()


## Mouse mode this controller believes is correct, or -1 when it cannot tell
## (no player yet). Single source of the rule, shared with the reconcile.
func _wanted_mode() -> int:
	var player := _find_player()
	if player == null:
		return -1
	return int(Input.MOUSE_MODE_CAPTURED if should_capture_look() else Input.MOUSE_MODE_VISIBLE)


## DIAGNOSTIC ONLY — reports, does not correct.
##
## This file calls itself the single authority for mouse capture, but eight
## other files still call Input.set_mouse_mode() directly, and this controller
## only reconciles on a deferred _request_apply_capture() — never continuously —
## so a direct write leaves Input.mouse_mode and player.is_mouse_captured
## disagreeing until something unrelated happens to trigger a re-apply.
##
## It deliberately does NOT correct the mode. Four of those callers (the CSV
## picker and its mapping window, timeline_ui, game_over_ui, location_picker_ui)
## set MOUSE_MODE_VISIBLE without registering a modal, so a correcting reconcile
## would grab the mouse back out from under them within a quarter second and
## break each one. Warning instead surfaces exactly which caller desyncs, in
## real use, which is the information needed to migrate them — and it cannot
## regress anything in the meantime. Once every caller registers a modal, this
## can start correcting.
func _process(delta: float) -> void:
	_reconcile_accum += delta
	if _reconcile_accum < RECONCILE_INTERVAL:
		return
	_reconcile_accum = 0.0
	if not is_inside_tree() or _capture_apply_pending:
		return
	# Headless has no display server, so a CAPTURED request never takes and
	# Input.mouse_mode reads VISIBLE forever — every --quit-after boot and every
	# selftest would report a desync that does not exist. Likewise an unfocused
	# window: the OS releases the pointer and that is correct, not a bug.
	if DisplayServer.get_name() == "headless":
		return
	if not DisplayServer.window_is_focused():
		return
	var want := _wanted_mode()
	if want < 0 or Input.mouse_mode == want:
		return
	var key := "%d->%d|%s" % [Input.mouse_mode, want, ",".join(_modal_stack)]
	if _reported_desyncs.has(key):
		return
	_reported_desyncs[key] = true
	push_warning(("CursorController: mouse mode is %s but should be %s "
		+ "(paused=%s, modals=[%s]). Something called Input.set_mouse_mode() "
		+ "directly instead of request_modal()/release_modal().") % [
			_mode_name(Input.mouse_mode), _mode_name(want),
			str(_paused), ",".join(_modal_stack)])


func _mode_name(mode: int) -> String:
	match mode:
		Input.MOUSE_MODE_VISIBLE: return "VISIBLE"
		Input.MOUSE_MODE_CAPTURED: return "CAPTURED"
		Input.MOUSE_MODE_HIDDEN: return "HIDDEN"
		Input.MOUSE_MODE_CONFINED: return "CONFINED"
		Input.MOUSE_MODE_CONFINED_HIDDEN: return "CONFINED_HIDDEN"
	return str(mode)


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
