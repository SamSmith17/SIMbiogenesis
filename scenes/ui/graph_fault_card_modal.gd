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

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _title_lbl: Label = null
var _body_lbl: RichTextLabel = null
var _actions_row: HBoxContainer = null
var _queue: Array[Dictionary] = []
var _showing: bool = false


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


func _present(card: Dictionary) -> void:
	_showing = true
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
	_body_lbl.text = str(card.get("body", ""))
	for child in _actions_row.get_children():
		child.queue_free()
	var actions: Array = card.get("actions", []) as Array
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
	visible = true
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


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

	_title_lbl = Label.new()
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_ERROR)
	root.add_child(_title_lbl)

	_body_lbl = RichTextLabel.new()
	_body_lbl.bbcode_enabled = true
	_body_lbl.fit_content = true
	_body_lbl.scroll_active = false
	_body_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_lbl.custom_minimum_size = Vector2(PANEL_SIZE.x - UITheme.SPACE_LG * 2.0, 0.0)
	_body_lbl.add_theme_color_override("default_color", UITheme.C_TEXT)
	root.add_child(_body_lbl)

	_actions_row = HBoxContainer.new()
	_actions_row.alignment = BoxContainer.ALIGNMENT_END
	_actions_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(_actions_row)


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		close()
