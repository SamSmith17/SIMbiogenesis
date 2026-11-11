extends Node

## Design challenges (resource composition plan Phase 8): every gap node on
## the graph with its design brief, measured. Look goes to it; Export saves
## the brief (Markdown + JSON in user://design_challenges/); Export all saves
## every one.
##
##   open_for(closer)   closer = the view's LoopCloser node

var _closer: Node = null
var _frame: ModalFrame = null
var _list: VBoxContainer = null


func open_for(closer: Node) -> void:
	_closer = closer
	_frame = ModalFrame.create("Design challenges",
		"Machines nobody has built yet: what each one would have to do, measured by its gap node",
		Vector2(980, 760), "design_challenges")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	_frame.body.add_child(_list)
	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)
	var gaps: Array = _closer.call("gaps")
	if not gaps.is_empty():
		_frame.add_button("Export all", ModalFrame.SECONDARY, func() -> void:
			for g in gaps:
				_closer.call("export_brief", str((g as Dictionary)["id"])))
	_fill(gaps)
	_frame.open()


func _fill(gaps: Array) -> void:
	if gaps.is_empty():
		_list.add_child(EmptyState.make("search",
			"No gap nodes yet. Close loops… adds one where nothing in the library closes a loop, and a group can be replaced by one.",
			"", Callable()))
		return
	for g in gaps:
		var gd: Dictionary = g
		var brief: Dictionary = _closer.call("brief_for", str(gd["id"]))
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UITheme.card_style())
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		panel.add_child(h)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(v)
		var title := Label.new()
		title.text = str(brief.get("title", gd["title"]))
		title.add_theme_font_override("font", UITheme.font("semibold"))
		title.add_theme_color_override("font_color", UITheme.C_TEXT)
		v.add_child(title)
		for l in brief.get("lines", []):
			var lab := Label.new()
			lab.text = "• " + str((l as Dictionary)["text"])
			lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lab.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			lab.add_theme_color_override("font_color", UITheme.C_WARN if str((l as Dictionary)["key"]) == "short" else UITheme.C_TEXT_S)
			v.add_child(lab)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 6)
		h.add_child(col)
		var look := Button.new()
		look.text = "Look"
		look.name = "look_" + str(gd["id"])
		look.tooltip_text = "Go to it on the graph."
		UITheme.style_button(look)
		var gid := str(gd["id"])
		look.pressed.connect(func() -> void:
			_frame.close()
			var gv := ServiceLocator.graph()
			if gv != null:
				gv.call("focus_graph_item", gid, false))
		col.add_child(look)
		var ex := Button.new()
		ex.text = "Export"
		ex.name = "export_" + gid
		ex.tooltip_text = "Save the brief as Markdown and JSON."
		UITheme.style_button(ex)
		ex.pressed.connect(func() -> void: _closer.call("export_brief", gid))
		col.add_child(ex)
		_list.add_child(panel)
