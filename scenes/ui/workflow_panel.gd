extends Control

## Lightweight workflow runner UI — list catalog workflows, bind machines by
## role, start/confirm/cancel. Groundwork for multi-machine recipe chains.

const MODAL_NAME := "workflow_panel"

var _built := false
var _list: VBoxContainer = null
var _status: Label = null


func open() -> void:
	if not _built:
		_build_ui()
		_built = true
	refresh()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 480)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)
	UiFit.adopt(panel)  # above the timeline, inside the screen at any size
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	panel.add_child(root)
	var title := Label.new()
	title.text = "Workflow Recipes"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)
	var hint := Label.new()
	hint.text = "Multi-machine sequences. Humans move discrete parts via inventory."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	root.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(480, 0)
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	_status = Label.new()
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	root.add_child(_status)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	root.add_child(row)
	var conf := Button.new()
	conf.text = "Confirm chore"
	conf.pressed.connect(func():
		var sgv := _sgv()
		if sgv != null and sgv.has_method("confirm_workflow_chore"):
			sgv.call("confirm_workflow_chore")
		refresh()
	)
	row.add_child(conf)
	var cancel := Button.new()
	cancel.text = "Cancel workflow"
	cancel.pressed.connect(func():
		var sgv2 := _sgv()
		if sgv2 != null and sgv2.has_method("cancel_workflow"):
			sgv2.call("cancel_workflow")
		refresh()
	)
	row.add_child(cancel)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	row.add_child(close_btn)


func refresh() -> void:
	if not _built:
		return
	for c in _list.get_children():
		c.queue_free()
	var sgv := _sgv()
	var active: Dictionary = {}
	if sgv != null and sgv.has_method("get_active_workflow"):
		active = sgv.call("get_active_workflow") as Dictionary
	if not active.is_empty() and str(active.get("status", "")) != "idle":
		_status.text = "Active: %s  step %d  [%s]" % [
			str(active.get("workflow_id", "")),
			int(active.get("step_index", 0)),
			str(active.get("status", ""))]
	else:
		_status.text = "No active workflow"
	for w: Dictionary in WorkflowRecipeCatalog.all_workflows():
		_list.add_child(_card(w, active))


func _card(w: Dictionary, active: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)
	var name_lbl := Label.new()
	name_lbl.text = str(w.get("label", w.get("id", "")))
	name_lbl.add_theme_font_size_override("font_size", 14)
	v.add_child(name_lbl)
	var note := str(w.get("note", ""))
	if not note.is_empty():
		var nl := Label.new()
		nl.text = note
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_font_size_override("font_size", 11)
		nl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		v.add_child(nl)
	var steps: Array = w.get("steps", []) as Array
	var bits: PackedStringArray = PackedStringArray()
	for s: Variant in steps:
		if s is Dictionary:
			bits.append(str((s as Dictionary).get("label", (s as Dictionary).get("type", ""))))
	var sl := Label.new()
	sl.text = " → ".join(bits)
	sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sl.add_theme_font_size_override("font_size", 11)
	v.add_child(sl)
	var btn := Button.new()
	var wid := str(w.get("id", ""))
	var is_active := str(active.get("workflow_id", "")) == wid \
			and str(active.get("status", "")) not in ["idle", "done", ""]
	btn.text = "Running…" if is_active else "Start"
	btn.disabled = is_active
	btn.pressed.connect(func():
		var sgv := _sgv()
		if sgv != null and sgv.has_method("start_workflow"):
			sgv.call("start_workflow", wid)
		refresh()
	)
	v.add_child(btn)
	return card


func _sgv() -> Node:
	return get_tree().root.find_child("SystemGraphView", true, false)
