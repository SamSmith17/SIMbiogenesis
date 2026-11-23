extends Node

## "What can separate this?" (resource composition plan Phase 5): for one
## kind, each part worth recovering (water, nitrogen, phosphorus, potassium,
## carbon), the machines in the library that move it into another kind and
## the classes of process that could, ranked by how much they recover, then
## by energy. A machine has "Place" (the library's own placement); a class
## with no machine yet says so (Phase 7 will suggest it on the graph).
##
##   open_for(view, kind)   view = SystemGraphView

var _view: Node = null
var _kind := ""
var _frame: ModalFrame = null
var _list: VBoxContainer = null


func open_for(view: Node, kind: String) -> void:
	_view = view
	_kind = CompositionCatalog.canonical(kind)
	var nm := ResourceKinds.display_name(_kind)
	_frame = ModalFrame.create("What can separate %s?" % nm.to_lower(),
		"What's worth getting back out of it, and what can do it", Vector2(980, 760), "separate")
	add_child(_frame)
	_frame.closed.connect(queue_free)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	_frame.body.add_child(_list)
	_frame.add_button("Close", ModalFrame.PRIMARY, _frame.close)
	_fill()
	_frame.open()


func _fill() -> void:
	var res := ProcessCapabilities.separate(_kind)
	var targets: Array = res.get("targets", [])
	if targets.is_empty():
		_list.add_child(EmptyState.make("search",
			"%s has no make-up listed, or nothing in it worth recovering." % ResourceKinds.display_name(_kind), "", Callable()))
		return
	for t in targets:
		var td: Dictionary = t
		var pct := _content_text(str(td["target"]), float(td["content"]))
		_list.add_child(SectionHeader.make(str(td["label"]), "", pct))
		var opts: Array = _merged(td["options"])
		if opts.is_empty():
			_list.add_child(_note("Nothing in the library or the process table takes it out yet. A gap to design for."))
			continue
		var shown := 0
		for o in opts:
			if shown >= 6:
				break
			_list.add_child(_row(o as Dictionary, str(td["target"])))
			shown += 1
		if opts.size() > shown:
			_list.add_child(_note("… and %s more." % UiText.count(opts.size() - shown, "way")))


## One row per machine: a machine that sends the target to several places
## lists them on one line ("86 % into nutrients · 14 % into the air").
func _merged(opts: Array) -> Array:
	var out: Array = []
	var by: Dictionary = {}
	for o in opts:
		var od: Dictionary = (o as Dictionary).duplicate()
		var key := "%s|%s" % [od["type"], od["label"]]
		if str(od["type"]) == "class" or not by.has(key):
			od["dests"] = [[str(od["to"]), float(od["recovery"])]]
			out.append(od)
			if str(od["type"]) != "class":
				by[key] = od
		else:
			(by[key]["dests"] as Array).append([str(od["to"]), float(od["recovery"])])
	return out


func _content_text(target: String, per_kg: float) -> String:
	if target == "water":
		return "%s water" % UiText.pct(per_kg)
	return "%s per kg" % ElementLedger.fmt_kg(per_kg)


func _row(o: Dictionary, target: String) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	panel.add_child(h)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	var typ := str(o.get("type", ""))
	var title := Label.new()
	var kind_word: String = str({"preset": "", "recipe": "", "class": "a kind of process · "}.get(typ, ""))
	title.text = "%s%s" % [kind_word, str(o["label"]).trim_prefix("recipe: ")]
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	title.add_theme_font_override("font", UITheme.font("semibold"))
	v.add_child(title)
	var parts := PackedStringArray()
	for d in o.get("dests", [[str(o["to"]), float(o["recovery"])]]):
		var to := str(d[0])
		var to_word := "the air" if to == "air" else ResourceKinds.display_name(to).to_lower()
		parts.append("%s into %s" % [UiText.pct(float(d[1])), to_word])
	var line := " · ".join(parts)
	var e := float(o["kwh_per_kg"])
	var per := "kg of water" if str(o.get("per", "feed")) == "water" else "kg in"
	if e > 0.0:
		line += " · %s per %s" % [UiText.num(e * 1000.0, "Wh"), per]
	var floor_v := float(o.get("kwh_min", NAN))
	if not is_nan(floor_v):
		line += " (the least it could take: %s)" % UiText.num(floor_v * 1000.0, "Wh")
	var sub := Label.new()
	sub.text = line
	sub.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	var extra := str(o.get("what", ""))
	var cls: Array = o.get("classes", [])
	if extra.is_empty() and not cls.is_empty():
		var names := PackedStringArray()
		for c in cls:
			names.append(UnitOps.label(str(c)).to_lower())
		extra = "Works by " + ", ".join(names) + "."
	if not extra.is_empty():
		v.add_child(_note(extra))
	if not str(o.get("src", "")).is_empty():
		var src := _note("Source: " + str(o["src"]))
		v.add_child(src)
	if typ == "preset":
		var b := Button.new()
		b.text = "Place"
		b.name = "place_" + str(o["label"]).to_snake_case()
		b.tooltip_text = I18n.f("Put a {label} on the graph.", {"label": str(o["label"])})
		UITheme.style_button(b)
		b.pressed.connect(func() -> void:
			if _view != null and is_instance_valid(_view) and bool(_view.call("place_preset_by_label", str(o["label"]))):
				_frame.close())
		h.add_child(b)
	elif typ == "class":
		var tag := Label.new()
		tag.text = "No machine yet"
		tag.tooltip_text = "Nothing in the library does this. It is a design to build, or a gap node later."
		tag.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		h.add_child(tag)
	else:
		var tag2 := Label.new()
		tag2.text = "A recipe"
		tag2.tooltip_text = "Run it on a machine that takes recipes."
		tag2.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		h.add_child(tag2)
	return panel


func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	return l
