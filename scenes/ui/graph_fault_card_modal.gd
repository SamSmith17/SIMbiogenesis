class_name GraphFaultCardModal
extends Control

## Education-card modal for electrical faults (and, later, tutorial briefs).
## Replaces the hand-rolled ControllerEduOverlay: proper UITheme styling,
## CursorController modal registration, and a queue so cards that fire in the
## same frame (fault → level-complete) present one at a time instead of
## stacking. Content comes from GraphEducationCards.card_for_fault or any
## {title, body, [actions]} dict; body renders as bbcode.

const MODAL_NAME := "graph_fault_card"
const PANEL_SIZE := Vector2(520.0, 340.0)

## Dev authoring aid: cards that carry an `override_key` grow an ✎ button that
## swaps the labels for editors; "Save as default" persists the text via
## EducationCardOverrides, which then presents as the default from that point
## on. OPT-IN with `--card-editor` on the command line (after `--`): it used to
## be on for every player, a pencil on every tutorial card.
static var TEXT_EDITING_ENABLED: bool = "--card-editor" in OS.get_cmdline_user_args()

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _title_lbl: Label = null
var _body_lbl: RichTextLabel = null
var _actions_row: HBoxContainer = null
var _queue: Array[Dictionary] = []
var _showing: bool = false

# Dev editor state (see TEXT_EDITING_ENABLED).
var _edit_btn: Button = null
var _title_edit: LineEdit = null
var _body_edit: TextEdit = null
var _edit_hint: Label = null
var _editing: bool = false
var _current_card: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build_ui()


## card = {title, body, [title_color: Color], [actions: [{label, callback}]]}.
## With no actions, a single "Got it" button closes the card.
func show_card(card: Dictionary) -> void:
	if card.is_empty():
		return
	if _showing:
		_queue.append(card)
		return
	_present(card)


func close() -> void:
	_showing = false
	visible = false
	CursorController.release_modal(MODAL_NAME)
	if not _queue.is_empty():
		var next: Dictionary = _queue.pop_front()
		# Deferred so the release/request pair doesn't collapse into a no-op.
		call_deferred("_present", next)


func is_showing() -> bool:
	return _showing


## Drop every card still waiting behind the one on screen. A level change or
## leaving the bootcamp must call this: a fault card queued behind level 1's
## debrief used to pop up over level 2 and eat its first wire drag.
func clear_queue() -> void:
	_queue.clear()


## Close the card on screen AND everything queued behind it.
func dismiss_all() -> void:
	_queue.clear()
	if _showing:
		close()


func _present(card: Dictionary) -> void:
	_showing = true
	_set_editing(false)
	# Saved dev copy-edits present as the default (see EducationCardOverrides).
	card = EducationCardOverrides.apply(card)
	_current_card = card
	# Fault cards dock to a corner with a light backdrop so the wreck they are
	# explaining stays visible; briefs/debriefs keep the centered treatment.
	if str(card.get("placement", "center")) == "corner":
		UiScreenLayout.clamped_corner_card(_panel, PANEL_SIZE)
		_backdrop.color = Color(0.0, 0.0, 0.0, 0.25)
	else:
		UiScreenLayout.clamped_center(_panel, PANEL_SIZE)
		_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_title_lbl.text = str(card.get("title", ""))
	var tcol: Variant = card.get("title_color")
	_title_lbl.add_theme_color_override("font_color",
		tcol if tcol is Color else UITheme.C_ERROR)
	_body_lbl.text = _display_body(card)
	_edit_btn.visible = TEXT_EDITING_ENABLED \
			and not str(card.get("override_key", "")).is_empty()
	_rebuild_actions()
	visible = true
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


## Body text + optional non-editable suffix (e.g. the debrief's unlock list —
## per-occurrence, so it must never be baked into a saved default).
static func _display_body(card: Dictionary) -> String:
	var body := str(card.get("body", ""))
	var suffix := str(card.get("body_suffix", ""))
	if suffix.is_empty():
		return body
	return body + "\n\n" + suffix


func _rebuild_actions() -> void:
	for child in _actions_row.get_children():
		child.queue_free()
	if _editing:
		var save_btn := Button.new()
		save_btn.text = "💾 Save as default"
		save_btn.tooltip_text = "Persist this text as the card's default (user://education_card_overrides.json)"
		UITheme.style_button(save_btn)
		save_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		save_btn.pressed.connect(_on_save_edit)
		_actions_row.add_child(save_btn)
		var cancel_btn := Button.new()
		cancel_btn.text = "Cancel"
		UITheme.style_button(cancel_btn)
		cancel_btn.pressed.connect(func() -> void: _set_editing(false))
		_actions_row.add_child(cancel_btn)
		return
	var actions: Array = _current_card.get("actions", []) as Array
	if actions.is_empty():
		actions = [{"label": "Got it"}]
	for a in actions:
		if not (a is Dictionary):
			continue
		var btn := Button.new()
		btn.text = str((a as Dictionary).get("label", "OK"))
		UITheme.style_button(btn)
		var cb: Variant = (a as Dictionary).get("callback")
		btn.pressed.connect(func() -> void:
			close()
			if cb is Callable and (cb as Callable).is_valid():
				(cb as Callable).call()
		)
		_actions_row.add_child(btn)


# ---- Dev text editor (TEMPORARY — see TEXT_EDITING_ENABLED) ----------------

func _set_editing(on: bool) -> void:
	_editing = on and TEXT_EDITING_ENABLED
	if _title_edit == null:
		return
	_title_lbl.visible = not _editing
	_body_lbl.visible = not _editing
	_title_edit.visible = _editing
	_body_edit.visible = _editing
	_edit_hint.visible = _editing
	if _editing:
		_title_edit.text = str(_current_card.get("title", ""))
		_body_edit.text = str(_current_card.get("body", ""))
		_title_edit.grab_focus()
	_rebuild_actions()


func _on_edit_pressed() -> void:
	_set_editing(not _editing)


func _on_save_edit() -> void:
	var key := str(_current_card.get("override_key", ""))
	if key.is_empty():
		_set_editing(false)
		return
	EducationCardOverrides.save_override(key, _title_edit.text, _body_edit.text)
	_current_card["title"] = _title_edit.text
	_current_card["body"] = _body_edit.text
	_title_lbl.text = _title_edit.text
	_body_lbl.text = _display_body(_current_card)
	_set_editing(false)


func _build_ui() -> void:
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.98))
	add_child(_panel)
	UiScreenLayout.clamped_center(_panel, PANEL_SIZE)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", UITheme.SPACE_LG)
	outer.add_theme_constant_override("margin_right", UITheme.SPACE_LG)
	outer.add_theme_constant_override("margin_top", UITheme.SPACE_MD)
	outer.add_theme_constant_override("margin_bottom", UITheme.SPACE_MD)
	_panel.add_child(outer)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_MD)
	outer.add_child(root)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(title_row)

	_title_lbl = Label.new()
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_ERROR)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title_lbl)

	# Dev copy-editor toggle (TEMPORARY — see TEXT_EDITING_ENABLED).
	_edit_btn = Button.new()
	_edit_btn.text = "✎"
	_edit_btn.tooltip_text = "Edit this card's text (dev) — Save persists it as the default"
	UITheme.style_button(_edit_btn)
	_edit_btn.visible = false
	_edit_btn.pressed.connect(_on_edit_pressed)
	title_row.add_child(_edit_btn)

	_body_lbl = RichTextLabel.new()
	_body_lbl.bbcode_enabled = true
	_body_lbl.fit_content = true
	_body_lbl.scroll_active = false
	_body_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_lbl.custom_minimum_size = Vector2(PANEL_SIZE.x - UITheme.SPACE_LG * 2.0, 0.0)
	_body_lbl.add_theme_color_override("default_color", UITheme.C_TEXT)
	root.add_child(_body_lbl)

	# Editor widgets — hidden until ✎ (dev only).
	_title_edit = LineEdit.new()
	_title_edit.visible = false
	root.add_child(_title_edit)
	_body_edit = TextEdit.new()
	_body_edit.visible = false
	_body_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_edit.custom_minimum_size = Vector2(PANEL_SIZE.x - UITheme.SPACE_LG * 2.0, 200.0)
	_body_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body_edit)
	_edit_hint = Label.new()
	_edit_hint.visible = false
	_edit_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_edit_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_edit_hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_edit_hint.text = ("Editing raw bbcode. Note: numbers in fault cards come from " +
		"THIS occurrence and save literally — keep them generic if the card must " +
		"fit other situations.")
	root.add_child(_edit_hint)

	_actions_row = HBoxContainer.new()
	_actions_row.alignment = BoxContainer.ALIGNMENT_END
	_actions_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(_actions_row)


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		close()
