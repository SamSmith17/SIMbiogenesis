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
## A card may carry "energy_flows" (EnergyRunSankey): drawn under the body.
var _flows_box: VBoxContainer = null
const FLOWS_H := 240.0
var _actions_row: HBoxContainer = null
var _queue: Array[Dictionary] = []
var _showing: bool = false

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
	_current_card = card
	# Fault cards dock to a corner with a light backdrop so the wreck they are
	# explaining stays visible; briefs/debriefs keep the centered treatment.
	var size := PANEL_SIZE
	# The Sankey takes the room left above the timeline (a corner card is
	# anchored over the bar, which can be tall); with too little room the
	# card keeps just the one-line split.
	var bar := HudLayout.timeline_height() + 4.0
	var room := get_viewport_rect().size.y - bar \
			- UiScreenLayout.SIDE_MARGIN * 2.0 - PANEL_SIZE.y - 50.0
	var fh := minf(FLOWS_H, room)
	var flows := card.get("energy_flows", {}) as Dictionary
	var has_flows := _fill_flows(flows, fh if fh >= 110.0 else 0.0)
	_body_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if has_flows else Control.SIZE_EXPAND_FILL
	_flows_box.size_flags_vertical = Control.SIZE_EXPAND_FILL if has_flows else Control.SIZE_FILL
	if has_flows:
		size += Vector2(60.0, (fh if fh >= 110.0 else 0.0) + 40.0)
	if str(card.get("placement", "center")) == "corner":
		UiScreenLayout.clamped_corner_card(_panel, size, bar)
		_backdrop.color = Color(0.0, 0.0, 0.0, 0.25)
	else:
		UiScreenLayout.clamped_center(_panel, size)
		_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_title_lbl.text = str(card.get("title", ""))
	var tcol: Variant = card.get("title_color")
	_title_lbl.add_theme_color_override("font_color",
		tcol if tcol is Color else UITheme.C_ERROR)
	_body_lbl.text = _display_body(card)
	_rebuild_actions()
	visible = true
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


## The run's energy split as a small loop Sankey under the body; false when
## the card carries none.
func _fill_flows(flows: Dictionary, h: float = FLOWS_H) -> bool:
	for c in _flows_box.get_children():
		_flows_box.remove_child(c)
		c.queue_free()
	_flows_box.visible = not EnergyRunSankey.loop_input(flows).is_empty()
	if not _flows_box.visible:
		return false
	var view := EnergyRunSankey.make_view(flows, h) if h > 0.0 else null
	var line := Label.new()
	line.text = "Where the energy went · " + EnergyRunSankey.summary(flows)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	line.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_flows_box.add_child(line)
	if view != null:
		# The picture takes the card's spare height, not the body text.
		view.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_flows_box.add_child(view)
	return true


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
	var actions: Array = _current_card.get("actions", []) as Array
	if actions.is_empty():
		actions = [{"label": "Got it"}]
	for i in actions.size():
		var a: Variant = actions[i]
		if not (a is Dictionary):
			continue
		var btn := Button.new()
		btn.text = str((a as Dictionary).get("label", "OK"))
		if i == actions.size() - 1:
			UITheme.style_primary_button(btn)
		else:
			UITheme.style_button(btn)
		var cb: Variant = (a as Dictionary).get("callback")
		btn.pressed.connect(func() -> void:
			close()
			if cb is Callable and (cb as Callable).is_valid():
				(cb as Callable).call()
		)
		_actions_row.add_child(btn)


func _build_ui() -> void:
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", UITheme.modal_panel_style(0.99))
	_panel.set_meta("ui_modal", true)
	add_child(_panel)
	UiScreenLayout.clamped_center(_panel, PANEL_SIZE)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", UITheme.SPACE_MD)
	outer.add_theme_constant_override("margin_right", UITheme.SPACE_MD)
	outer.add_theme_constant_override("margin_top", UITheme.SPACE_XS)
	outer.add_theme_constant_override("margin_bottom", UITheme.SPACE_XS)
	_panel.add_child(outer)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	outer.add_child(root)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(title_row)

	var alert_ic := TextureRect.new()
	alert_ic.texture = UiIcons.icon("triangle-alert", 18)
	alert_ic.modulate = UITheme.C_ERROR
	alert_ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	title_row.add_child(alert_ic)

	_title_lbl = Label.new()
	_title_lbl.add_theme_font_override("font", UITheme.font("semibold"))
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_ERROR)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title_lbl)
	root.add_child(HSeparator.new())

	_body_lbl = RichTextLabel.new()
	_body_lbl.bbcode_enabled = true
	_body_lbl.fit_content = true
	_body_lbl.scroll_active = false
	_body_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_lbl.custom_minimum_size = Vector2(PANEL_SIZE.x - UITheme.SPACE_LG * 2.0, 0.0)
	_body_lbl.add_theme_color_override("default_color", UITheme.C_TEXT)
	root.add_child(_body_lbl)

	_flows_box = VBoxContainer.new()
	_flows_box.name = "CardFlows"
	_flows_box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_flows_box.visible = false
	root.add_child(_flows_box)

	_actions_row = HBoxContainer.new()
	_actions_row.alignment = BoxContainer.ALIGNMENT_END
	_actions_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(_actions_row)


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		close()
