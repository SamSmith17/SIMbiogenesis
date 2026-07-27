extends Control

## In-session chat HUD — log + compose. Enter focuses compose when session is
## active; Esc / blur releases the cursor modal.

const MODAL_NAME := "mp_chat_compose"
const VISIBLE_LINES := 8

var _built := false
var _log: RichTextLabel = null
var _input: LineEdit = null
var _panel: PanelContainer = null
var _composing := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_unhandled_input(true)
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
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_refresh_log()
	else:
		_stop_compose()
		visible = false


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 15

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb: StyleBoxFlat = UITheme.panel_style()
	sb.bg_color = Color(UITheme.C_BG.r, UITheme.C_BG.g, UITheme.C_BG.b, 0.72)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.anchor_left = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 16.0
	_panel.offset_right = 420.0
	_panel.offset_top = -210.0
	_panel.offset_bottom = -72.0
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_panel.add_child(col)

	var hdr := Label.new()
	hdr.text = "Session chat  (Enter to type)"
	hdr.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	hdr.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	col.add_child(hdr)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.fit_content = false
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 120)
	_log.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(_log)

	_input = LineEdit.new()
	_input.placeholder_text = "Message… (Enter send · Esc cancel)"
	_input.max_length = 280
	_input.visible = false
	_input.text_submitted.connect(_on_submit)
	_input.focus_exited.connect(func() -> void:
		# Delay so clicking Send-equivalent paths can finish.
		call_deferred("_maybe_stop_compose_on_focus_loss"))
	col.add_child(_input)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or MultiplayerSession == null or not MultiplayerSession.is_active():
		return
	if event.is_action_pressed("mp_chat") or (
			event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ENTER):
		if _composing:
			return
		# Don't steal Enter from lobby / graph / other modals.
		if CursorController != null and CursorController.has_method("has_blocking_modal") \
				and CursorController.has_blocking_modal():
			return
		_start_compose()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE and _composing:
		_stop_compose()
		get_viewport().set_input_as_handled()


func _start_compose() -> void:
	if not _built:
		_build_ui()
		_built = true
	_composing = true
	_input.visible = true
	_input.grab_focus()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_stop_compose"))


func _stop_compose() -> void:
	_composing = false
	if _input != null:
		_input.text = ""
		_input.visible = false
		_input.release_focus()
	CursorController.release_modal(MODAL_NAME)


func _maybe_stop_compose_on_focus_loss() -> void:
	if _composing and _input != null and not _input.has_focus():
		_stop_compose()


func _on_submit(text: String) -> void:
	var chat := _chat()
	if chat != null and chat.has_method("send_chat"):
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
		if bool(m.get("system", false)):
			bb += "[color=#94a3b8]%s[/color]\n" % _esc(str(m.get("text", "")))
		else:
			var name_ := _esc(str(m.get("name", "Player")))
			var body := _esc(str(m.get("text", "")))
			bb += "[color=#22d3ee]%s[/color]: %s\n" % [name_, body]
	_log.text = bb


func _on_message(msg: Dictionary) -> void:
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
