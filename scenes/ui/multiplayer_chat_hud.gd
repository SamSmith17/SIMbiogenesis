extends Control

## In-session chat: the last few lines, and a box to type in (Enter).
##
## What was wrong with the first version, so it is not rebuilt:
## - It placed itself 72 px above the bottom edge — ON the 164 px timeline —
##   with MOUSE_FILTER_STOP, so the timeline buttons under it stopped working
##   and the log covered the transport. It now registers with HudLayout
##   (bottom-left, above the timeline, never on another panel) and takes the
##   mouse ONLY while the player is typing.
## - Enter opened the compose box whenever no blocking modal was up, but the
##   edit tools are a tool OVERLAY (not a modal) and use Enter themselves
##   (close a polygon, finish a light string, plant detected trees). It now
##   stands aside while a tool overlay is open, while any control has the
##   keyboard, and while the graph is up.
## - The log stayed on screen forever. Lines now show for a while after they
##   arrive and the panel shrinks to a one-line hint.

const MODAL_NAME := "mp_chat_compose"
const HUD_ID := "mp_chat"
const VISIBLE_LINES := 6
const SHOW_S := 12.0          ## how long new lines stay up
const FADE_S := 1.5
const PANEL_W := 380.0
const LINE_H := 20.0

var _built := false
var _log: RichTextLabel = null
## Named to avoid colliding with the engine's _input(event) virtual callback.
var _compose_edit: LineEdit = null
var _panel: PanelContainer = null
var _hint: Label = null
var _composing := false
var _last_msg_ms := -100000
var _unread := 0
var _registered := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_unhandled_input(true)
	set_process_input(true)
	set_process(true)
	if MultiplayerSession != null and is_instance_valid(MultiplayerSession):
		if not MultiplayerSession.session_changed.is_connected(_on_session_changed):
			MultiplayerSession.session_changed.connect(_on_session_changed)
		_wire_chat_signals()
	_on_session_changed()


func _wire_chat_signals() -> void:
	var chat := _chat()
	if chat == null:
		return
	if chat.has_signal("history_changed") and not chat.history_changed.is_connected(_refresh_log):
		chat.history_changed.connect(_refresh_log)
	if chat.has_signal("message_received") and not chat.message_received.is_connected(_on_message):
		chat.message_received.connect(_on_message)


func _chat() -> Node:
	if MultiplayerSession == null:
		return null
	return MultiplayerSession.get("chat") as Node


func _on_session_changed() -> void:
	_wire_chat_signals()
	var active := MultiplayerSession != null and MultiplayerSession.has_method("is_active") \
			and MultiplayerSession.is_active()
	if active:
		if not _built:
			_build_ui()
			_built = true
		visible = true
		_last_msg_ms = Time.get_ticks_msec()
		_refresh_log()
	else:
		_stop_compose()
		visible = false
	if _panel != null:
		_panel.visible = active


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.name = "ChatPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb: StyleBoxFlat = UITheme.panel_style()
	sb.bg_color = Color(UITheme.C_BG.r, UITheme.C_BG.g, UITheme.C_BG.b, 0.66)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(col)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.fit_content = true
	_log.scroll_active = false
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	col.add_child(_log)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_hint)

	_compose_edit = LineEdit.new()
	_compose_edit.placeholder_text = "Message… (Enter send · Esc cancel)"
	_compose_edit.max_length = 280
	_compose_edit.visible = false
	_compose_edit.text_submitted.connect(_on_submit)
	_compose_edit.focus_exited.connect(func() -> void:
		call_deferred("_maybe_stop_compose_on_focus_loss"))
	col.add_child(_compose_edit)

	_register(true)


## Tuckable while idle (a crowded left column folds it into a pill); while the
## player types it must stay open, so it re-registers untuckable.
func _register(tuckable: bool) -> void:
	HudLayout.register(_panel, HUD_ID, "bottom_left", {
		"order": 20, "priority": 3, "title": "chat", "icon": "users", "tuckable": tuckable,
		"size": func() -> Vector2: return Vector2(PANEL_W, _panel_height()),
		"compact": func() -> String:
			return ("Chat · %s" % UiText.count(_unread, "new message")) if _unread > 0 else "Chat (Enter)",
	})
	_registered = true


func _panel_height() -> float:
	var lines := _shown_lines()
	var h := 26.0 + lines * LINE_H
	if _composing:
		h += 38.0
	return h


func _shown_lines() -> int:
	if _log == null:
		return 0
	var chat := _chat()
	var n := 0
	if chat != null:
		n = (chat.get("history") as Array).size()
	if _composing:
		return mini(n, VISIBLE_LINES)
	var age := (Time.get_ticks_msec() - _last_msg_ms) / 1000.0
	if age > SHOW_S + FADE_S:
		return 0
	return mini(n, 4)


func _process(_delta: float) -> void:
	if not visible or _panel == null:
		return
	var age := (Time.get_ticks_msec() - _last_msg_ms) / 1000.0
	var lines := _shown_lines()
	_log.visible = lines > 0
	# Fade the lines out rather than cutting them.
	var a := 1.0
	if not _composing and age > SHOW_S:
		a = clampf(1.0 - (age - SHOW_S) / FADE_S, 0.0, 1.0)
	_log.modulate.a = a
	_hint.text = "Enter to chat" if not _composing else ""
	_hint.visible = not _composing
	var want_h := _panel_height()
	if absf(_panel.size.y - want_h) > 0.5:
		_panel.update_minimum_size()
		var hud := HudLayout.get_hud()
		if hud != null:
			hud.queue_layout()


## Escape-while-composing and click-outside-the-panel are handled here, not in
## _unhandled_input(): a focused LineEdit sits in front of GUI-input dispatch
## and would swallow them, leaving the modal (and the free cursor) stuck.
func _input(event: InputEvent) -> void:
	if not _composing:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		_stop_compose()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed \
			and not _point_in_panel(event.position):
		# Don't consume it: the click still reaches the game below.
		_stop_compose()


func _point_in_panel(global_pos: Vector2) -> bool:
	return _panel != null and _panel.get_global_rect().has_point(global_pos)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or MultiplayerSession == null or not MultiplayerSession.is_active():
		return
	if _composing:
		return
	var is_enter: bool = event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode in [KEY_ENTER, KEY_KP_ENTER]
	if not (event.is_action_pressed("mp_chat") or is_enter):
		return
	if not _may_open():
		return
	_start_compose()
	get_viewport().set_input_as_handled()


## Enter belongs to whatever else is using it first.
func _may_open() -> bool:
	if CursorController != null:
		if CursorController.has_method("has_blocking_modal") and CursorController.has_blocking_modal():
			return false
		if CursorController.has_method("has_tool_overlay") and CursorController.has_tool_overlay():
			return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and focus.is_visible_in_tree():
		return false
	var sgv := ServiceLocator.graph()
	if sgv != null and sgv is CanvasItem and (sgv as CanvasItem).is_visible_in_tree():
		return false
	return true


func _start_compose() -> void:
	if not _built:
		_build_ui()
		_built = true
	_composing = true
	_unread = 0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_register(false)
	_compose_edit.visible = true
	_compose_edit.grab_focus()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_stop_compose"))
	_refresh_log()


func _stop_compose() -> void:
	if not _composing:
		return
	_composing = false
	if _panel != null:
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_register(true)
	if _compose_edit != null:
		_compose_edit.text = ""
		_compose_edit.visible = false
		_compose_edit.release_focus()
	CursorController.release_modal(MODAL_NAME)
	# Keep the conversation readable for a moment after sending.
	_last_msg_ms = Time.get_ticks_msec()


func _maybe_stop_compose_on_focus_loss() -> void:
	if _composing and _compose_edit != null and not _compose_edit.has_focus():
		_stop_compose()


func _on_submit(text: String) -> void:
	var chat := _chat()
	if chat != null and chat.has_method("send_chat") and not text.strip_edges().is_empty():
		var result: Dictionary = chat.call("send_chat", text)
		if not bool(result.get("ok", false)) and MultiplayerSession != null:
			MultiplayerSession.call("_emit_status", str(result.get("error", "Send failed")), "warn")
	_stop_compose()


func _refresh_log() -> void:
	if _log == null:
		return
	var chat := _chat()
	if chat == null:
		_log.text = ""
		return
	var lines: Array = chat.get("history") as Array
	var start := maxi(0, lines.size() - VISIBLE_LINES)
	var bb := ""
	for i in range(start, lines.size()):
		var m: Dictionary = lines[i] as Dictionary
		if not bb.is_empty():
			bb += "\n"
		if bool(m.get("system", false)):
			bb += "[color=#94a3b8]%s[/color]" % _esc(str(m.get("text", "")))
		else:
			var peer_id := int(m.get("peer_id", 0))
			var col := RemotePlayerAvatar.color_for_peer(peer_id).to_html(false) if peer_id > 0 else "22d3ee"
			bb += "[color=#%s]%s[/color]: %s" % [col, _esc(str(m.get("name", "Player"))),
				_esc(str(m.get("text", "")))]
	_log.text = bb


func _on_message(msg: Dictionary) -> void:
	_last_msg_ms = Time.get_ticks_msec()
	if not _composing:
		_unread += 1
	_refresh_log()
	if bool(msg.get("system", false)):
		return
	var peer_id := int(msg.get("peer_id", 0))
	if peer_id <= 0 or peer_id == multiplayer.get_unique_id():
		return
	if MultiplayerSession != null and MultiplayerSession.has_method("show_peer_chat_bubble"):
		MultiplayerSession.show_peer_chat_bubble(peer_id, str(msg.get("text", "")))


func _esc(s: String) -> String:
	return s.replace("[", "(").replace("]", ")")
