class_name UiDensity
extends RefCounted

## How CROWDED an open modal is, as numbers. UiAudit finds things that are
## broken (overhang, overlap, truncation); a modal can pass all of that and
## still open with 45 rows, 9 px text and a slider 1400 px long. This measures
## what the eye complains about, so "crowded" can be tracked and gated
## (plans/MODAL_UX_PLAN.md rule 10).
##
##   var d := UiDensity.measure(get_tree().root)
##   print(UiDensity.summary_line(d))
##
## Everything is in the modal's own (logical) pixels, taken over the visible
## controls under every panel that carries the `ui_modal` meta.
##
##   controls      interactive controls on screen now (buttons, fields,
##                 sliders, dropdowns, checkboxes; a SpinBox counts once)
##   labels        text labels on screen now
##   overflow      the worst vertical ScrollContainer: content height over
##                 its own height (1.0 = fits; 2.3 = 2.3 screens of rows)
##   overflow_in   that container's name
##   min_font      the smallest font size drawn
##   small_text    how many texts are under SMALL_FONT
##   widest        the widest slider / dropdown / text field, and its kind
##   empty         share of the panel's area no leaf control covers
##   subject       how much of a StudioViewport's subject is in view (0..1;
##                 -1 = no studio); the lowest of the studios shown
##   flags         the budgets broken, in words

const BUDGET_CONTROLS_DESIGNER := 60
const BUDGET_CONTROLS_DIALOG := 30
const BUDGET_OVERFLOW := 1.0
const SMALL_FONT := 11
const BUDGET_SLIDER_W := 320.0
const BUDGET_OPTION_W := 360.0
const BUDGET_FIELD_W := 480.0
const BUDGET_EMPTY := 0.70
const BUDGET_SUBJECT := 0.75


static func measure(root: Node) -> Dictionary:
	var panels: Array = []
	_collect_panels(root, panels)
	var out := {"panels": panels.size(), "controls": 0, "labels": 0, "overflow": 0.0, "overflow_in": "",
		"min_font": 0, "small_text": 0, "widest": 0.0, "widest_kind": "", "empty": 0.0, "subject": -1.0,
		"studio": false, "flags": [], "no_tip": []}
	if panels.is_empty():
		return out
	var area := 0.0
	var covered := 0.0
	var min_font := 999
	for p in panels:
		var panel := p as Control
		# A DesignerShell whose left column is folded into its header button.
		var host := panel.get_parent()
		if host != null and host.has_method("is_folded") and bool(host.call("is_folded")):
			out["folded"] = true
		var prect := UiAudit._screen_rect(panel)
		area += prect.get_area()
		var stack: Array = [panel]
		while not stack.is_empty():
			var n := stack.pop_back() as Node
			# A SpinBox is one control: do not count its inner LineEdit.
			var descend := not (n is SpinBox) and not (n is OptionButton)
			if n is Control and n != panel:
				var c := n as Control
				if not UiAudit._shown(c):
					continue
				var r := UiAudit._visible_rect(c, UiAudit._screen_rect(c)).intersection(prect)
				var on_screen := r.size.x > 1.0 and r.size.y > 1.0
				if c is ScrollContainer:
					var sc := c as ScrollContainer
					if sc.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED and sc.size.y > 40.0 \
							and sc.get_child_count() > 0 and on_screen:
						var inner := 0.0
						for ch in sc.get_children():
							if ch is Control and not (ch is ScrollBar):
								inner = maxf(inner, (ch as Control).get_combined_minimum_size().y)
						# A design list scrolls by nature: it counts as five rows,
						# however many designs the player has saved.
						for g in sc.find_children("*", "DesignGallery", true, false):
							var gh := (g as Control).get_combined_minimum_size().y
							inner -= maxf(gh - 260.0, 0.0)
						var ratio := inner / maxf(sc.size.y, 1.0)
						if ratio > float(out["overflow"]):
							out["overflow"] = snappedf(ratio, 0.01)
							out["overflow_in"] = _where(sc)
				if c is DesignerShell:
					out["studio"] = true   # a designer, with or without a 3D view
				if on_screen:
					if c.get_script() != null and c.has_method("subject_in_view"):
						out["studio"] = true
						var sv := float(c.call("subject_in_view"))
						if sv >= 0.0:
							out["subject"] = sv if float(out["subject"]) < 0.0 else minf(float(out["subject"]), sv)
					elif c is SubViewportContainer:
						out["studio"] = true
					if _is_interactive(c):
						out["controls"] = int(out["controls"]) + 1
						# An icon (or one-glyph) button nobody explains.
						if c is Button and not (c is CheckBox or c is CheckButton or c is OptionButton or c is MenuButton or c is ColorPickerButton) 								and (c as Button).text.strip_edges().length() <= 2 and c.tooltip_text.strip_edges().is_empty() 								and (out["no_tip"] as Array).size() < 24:
							(out["no_tip"] as Array).append("%s '%s' in %s" % [str(c.name), (c as Button).text.strip_edges(), str(c.get_parent().name)])
						covered += r.get_area()
						var kind := ""
						var budget := 0.0
						if c is HSlider:
							kind = "slider"
							budget = BUDGET_SLIDER_W
						elif c is OptionButton:
							kind = "dropdown"
							budget = BUDGET_OPTION_W
						elif c is LineEdit:
							kind = "text field"
							budget = BUDGET_FIELD_W
						if not kind.is_empty() and c.size.x - budget > float(out["widest"]) - _budget_of(str(out["widest_kind"])):
							out["widest"] = snappedf(c.size.x, 1.0)
							out["widest_kind"] = kind
					elif c is Label or c is RichTextLabel:
						var txt := (c as Label).text if c is Label else (c as RichTextLabel).get_parsed_text()
						if not txt.strip_edges().is_empty():
							out["labels"] = int(out["labels"]) + 1
							covered += r.get_area()
					elif c is SubViewportContainer or c is TextureRect or c is ItemList or c is Tree \
							or c is ColorRect and c.get_child_count() == 0 and c.size.y > 2.0:
						covered += r.get_area()
						descend = descend and not (c is ItemList or c is Tree)
					elif c.get_child_count() == 0 and c.get_script() != null:
						# A custom-drawn leaf (a chart, a canvas, a deck).
						covered += r.get_area()
					var fsz := _font_size(c)
					if fsz > 0:
						min_font = mini(min_font, fsz)
						if fsz < SMALL_FONT:
							out["small_text"] = int(out["small_text"]) + 1
			if descend:
				for ch in n.get_children():
					stack.append(ch)
	out["min_font"] = 0 if min_font == 999 else min_font
	out["empty"] = snappedf(clampf(1.0 - covered / maxf(area, 1.0), 0.0, 1.0), 0.01)
	out["flags"] = _flags(out)
	return out


static func summary_line(d: Dictionary) -> String:
	if int(d.get("panels", 0)) == 0:
		return "no modal panel"
	var parts := PackedStringArray()
	parts.append("%d controls" % int(d["controls"]))
	parts.append("%d labels" % int(d["labels"]))
	if float(d["overflow"]) > 0.0:
		parts.append("scroll %.1fx (%s)" % [float(d["overflow"]), str(d["overflow_in"])])
	parts.append("min font %d" % int(d["min_font"]))
	if float(d["widest"]) > 0.0:
		parts.append("widest %s %d" % [str(d["widest_kind"]), int(d["widest"])])
	parts.append("empty %d%%" % int(round(float(d["empty"]) * 100.0)))
	if float(d["subject"]) >= 0.0:
		parts.append("subject %d%%" % int(round(float(d["subject"]) * 100.0)))
	var flags: Array = d.get("flags", [])
	return " · ".join(parts) + ("" if flags.is_empty() else "  [" + "; ".join(PackedStringArray(flags)) + "]")


static func _flags(d: Dictionary) -> Array:
	var out: Array = []
	var budget := BUDGET_CONTROLS_DESIGNER if bool(d["studio"]) else BUDGET_CONTROLS_DIALOG
	if int(d["controls"]) > budget:
		out.append("%d controls on open (budget %d)" % [int(d["controls"]), budget])
	if float(d["overflow"]) > BUDGET_OVERFLOW + 0.02:
		out.append("%s is %.1f screens long" % [str(d["overflow_in"]), float(d["overflow"])])
	if int(d["small_text"]) > 0:
		out.append("%d texts under %d px" % [int(d["small_text"]), SMALL_FONT])
	var wk := str(d["widest_kind"])
	if not wk.is_empty() and float(d["widest"]) > _budget_of(wk):
		out.append("%s %d px wide (budget %d)" % [wk, int(d["widest"]), int(_budget_of(wk))])
	if float(d["empty"]) > BUDGET_EMPTY and not bool(d["studio"]):
		out.append("%d%% of the panel is empty" % int(round(float(d["empty"]) * 100.0)))
	if not (d.get("no_tip", []) as Array).is_empty():
		out.append("%d icon buttons with no tooltip" % (d["no_tip"] as Array).size())
	if bool(d.get("folded", false)):
		out.append("left column folded away")
	if float(d["subject"]) >= 0.0 and float(d["subject"]) < BUDGET_SUBJECT:
		out.append("studio subject only %d%% in view" % int(round(float(d["subject"]) * 100.0)))
	return out


static func _budget_of(kind: String) -> float:
	match kind:
		"slider": return BUDGET_SLIDER_W
		"dropdown": return BUDGET_OPTION_W
		"text field": return BUDGET_FIELD_W
	return 0.0


static func _collect_panels(n: Node, out: Array) -> void:
	if n is Control:
		var c := n as Control
		if c.has_meta(UiAudit.MODAL_META) and bool(c.get_meta(UiAudit.MODAL_META)) and UiAudit._shown(c) \
				and c.size.x > 8.0 and c.size.y > 8.0:
			out.append(c)
			return
	# No pruning on a hidden CanvasItem: a CanvasLayer under a hidden Control
	# still draws (ModalFrame lives under whatever opened it).
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return
	for ch in n.get_children():
		_collect_panels(ch, out)


static func _is_interactive(c: Control) -> bool:
	if c is BaseButton:
		return not (c as BaseButton).disabled or true
	return c is LineEdit or c is SpinBox or c is Slider or c is TextEdit or c is ColorPickerButton


static func _font_size(c: Control) -> int:
	if c is Label:
		if (c as Label).text.strip_edges().is_empty():
			return 0
		return int(UiAudit._font_of(c)[1])
	if c is Button:
		if (c as Button).text.strip_edges().is_empty():
			return 0
		return c.get_theme_font_size("font_size")
	if c is LineEdit:
		return c.get_theme_font_size("font_size")
	return 0


static func _where(c: Control) -> String:
	var n: Node = c
	for i in 4:
		if n == null:
			break
		var nm := str(n.name)
		if not nm.begins_with("@"):
			return nm
		n = n.get_parent()
	return "scroll"
