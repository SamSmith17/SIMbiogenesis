extends Node

## Close loops… (resource composition plan Phase 7): every open loop in the
## scope the player is in, the most valuable first, with the loop planner's
## plans for each. "Show" puts that plan on the graph as ghosts (the loop
## closer's chip then accepts or dismisses it). Dismissed plans stay listed,
## greyed, with "Show anyway".
##
##   open_for(closer, scope)   closer = the view's LoopCloser node

var _closer: Node = null
var _scope := ""
var _frame: ModalFrame = null
var _list: VBoxContainer = null


func open_for(closer: Node, scope: String) -> void:
	_closer = closer
	_scope = scope
	_frame = ModalFrame.create("Close loops", "What is left over here or brought in, and the machines that would close it",
		Vector2(980, 760), "close_loops")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	_frame.body.add_child(_list)
	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)
	_fill()
	_frame.open()


func _fill() -> void:
	var rows: Array = _closer.call("loops", _scope)
	if rows.is_empty():
		_list.add_child(EmptyState.make("circle-check",
			"Every loop here is closed: nothing is left over or brought in at the listed rates.", "", Callable()))
		return
	for row in rows:
		var od: Dictionary = row["open"]
		var kind := str(od["kind"])
		var nm := ResourceKinds.display_name(kind)
		var what := "%s/h with nowhere to go" % ElementLedger.fmt_kg(float(od["kg_h"])) if str(od["side"]) == "sink" \
			else "%s/h brought in or drawn from a store" % ElementLedger.fmt_kg(float(od["kg_h"]))
		_list.add_child(SectionHeader.make(nm, "", what))
		var plans: Array = row["plans"]
		if plans.is_empty():
			_list.add_child(_note("Nothing in the library closes it yet. A gap to design for."))
			continue
		for i in plans.size():
			_list.add_child(_row(od, plans, i))


func _row(od: Dictionary, plans: Array, i: int) -> Control:
	var plan: Dictionary = plans[i]
	var dismissed := bool(_closer.call("is_dismissed", _scope, od, plan))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	panel.add_child(h)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	var labs := PackedStringArray()
	var machines := 0
	var gaps := 0
	for st in plan["steps"]:
		var sd: Dictionary = st
		if str(sd["type"]) == "preset":
			labs.append(str(sd["label"]))
			machines += 1
		else:
			labs.append("%s (no machine yet)" % str(sd["label"]).trim_prefix("recipe: "))
			gaps += 1
	var title := Label.new()
	title.text = " → ".join(labs)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_override("font", UITheme.font("semibold"))
	title.add_theme_color_override("font_color", UITheme.C_TEXT_M if dismissed else UITheme.C_TEXT)
	v.add_child(title)
	var sub := _note(GraphSuggestions.chip_text(od, plan, machines, gaps) + ("  ·  dismissed" if dismissed else ""))
	v.add_child(sub)
	var b := Button.new()
	b.text = "Show anyway" if dismissed else "Show"
	b.name = "show_%s_%d" % [str(od["kind"]), i]
	b.tooltip_text = "Put it on the graph as ghosts, beside what it joins."
	UITheme.style_button(b)
	b.pressed.connect(func() -> void:
		_frame.close()
		_closer.call("show_plans", _scope, od, plans, i, ""))
	h.add_child(b)
	if dismissed:
		panel.modulate = Color(1, 1, 1, 0.6)
	return panel


func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	return l
