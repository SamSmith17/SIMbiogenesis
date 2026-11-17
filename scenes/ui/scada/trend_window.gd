extends Node
## The Trends window (plans/SCADA_PROCESS_PLAN.md, Phase 8): any tags over
## time on one chart. Opened by SystemGraphView.open_trend_window (the Process
## lens's Trends button, a widget's "Open in Trends").
##
##   open(view, hub)
##   chart() -> TrendChart, button(name), is_open(), close()
##   buttons for checks: add_pen, now, span_<hours>, pen_<i>_remove, pen_<i>_axis
##
## The pens are the hub's (`trend_pens`), saved with the graph; a pen's tag is
## watched, so its history is kept long and saved with the world.

const SPANS := [[1.0, "1 h"], [6.0, "6 h"], [24.0, "24 h"], [168.0, "7 days"]]

var _view: Node = null
var _hub: Node = null
var _frame: ModalFrame = null
var _chart: TrendChart = null
var _pen_row: HFlowContainer = null
var _span_btns: Dictionary = {}
var _now_btn: Button = null
var _note: Label = null


func open(view: Node, hub: Node) -> void:
	_view = view
	_hub = hub
	_frame = ModalFrame.create("Trends", "Any readings over time on one chart. Wheel zooms, drag pans, the cursor reads every pen.",
		Vector2(1180, 720), "scada_trend_window")
	_frame.content_max_w = 0.0
	add_child(_frame)
	_frame.closed.connect(queue_free)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	_frame.body.add_child(bar)
	var add := _btn("add_pen", "Add a pen…", func() -> void: _add_pen())
	add.tooltip_text = "Pick a tag to draw (up to %d)." % int(_hub.get("MAX_PENS")) if _hub != null else ""
	bar.add_child(add)
	bar.add_child(VSeparator.new())
	for sp in SPANS:
		var hours := float(sp[0])
		var b := _btn("span_%d" % int(hours), str(sp[1]), func() -> void:
			_chart.set_span(hours)
			_sync_bar())
		b.toggle_mode = true
		bar.add_child(b)
		_span_btns[hours] = b
	_now_btn = _btn("now", "Back to now", func() -> void:
		_chart.follow_now()
		_sync_bar())
	bar.add_child(_now_btn)
	_note = Label.new()
	_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_note.clip_text = true
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	bar.add_child(_note)
	_pen_row = HFlowContainer.new()
	_pen_row.add_theme_constant_override("h_separation", 8)
	_pen_row.add_theme_constant_override("v_separation", 4)
	_frame.body.add_child(_pen_row)
	_chart = TrendChart.new()
	_chart.name = "trend_chart"
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chart.custom_minimum_size = Vector2(400, 300)
	_chart.fetch = func(id: String, t0: float, t1: float, n: int) -> PackedFloat32Array:
		return _hub.call("trend_span", id, t0, t1, n) if _hub != null else PackedFloat32Array()
	_chart.now_fn = func() -> float:
		var h := float(_hub.call("now_h")) if _hub != null else 0.0
		return h if not is_nan(h) else 0.0
	_chart.view_changed.connect(_sync_bar)
	_frame.body.add_child(_chart)
	_frame.add_button("Close", ModalFrame.SECONDARY, _frame.close)
	_frame.open()
	if _hub != null and _hub.get("modal_layer") != null:
		_frame.layer = int(_hub.get("modal_layer"))
	if _hub != null and _hub.has_signal("trends_changed"):
		_hub.connect("trends_changed", _rebuild_pens)
	_rebuild_pens()
	_sync_bar()


func _btn(id: String, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.name = id
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func chart() -> TrendChart:
	return _chart


func button(id: String) -> Button:
	return _frame.find_child(id, true, false) as Button if _frame != null else null


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func close() -> void:
	if _frame != null:
		_frame.close()


func _exit_tree() -> void:
	if _hub != null and is_instance_valid(_hub) and _hub.has_signal("trends_changed") and _hub.is_connected("trends_changed", _rebuild_pens):
		_hub.disconnect("trends_changed", _rebuild_pens)


func _sync_bar() -> void:
	for h in _span_btns:
		(_span_btns[h] as Button).set_pressed_no_signal(absf(_chart.span_h - float(h)) < 0.01)
	_now_btn.disabled = _chart.following()
	_note.text = "Showing the last %s" % _span_text(_chart.span_h) if _chart.following() else "Looking back: %s wide" % _span_text(_chart.span_h)


static func _span_text(h: float) -> String:
	if h < 1.0:
		return "%d min" % int(round(h * 60.0))
	if h < 48.0:
		return "%s h" % (("%.1f" % h) if h < 10.0 and absf(h - round(h)) > 0.05 else str(int(round(h))))
	return "%.1f days" % (h / 24.0)


func _add_pen() -> void:
	if _view == null or not _view.has_method("open_tag_browser"):
		return
	_view.call("open_tag_browser", {"title": "Pick a tag to draw", "pick": func(t: Dictionary) -> void:
		var pens: Array = _hub.call("trend_pens")
		var id := str(t.get("id", ""))
		if pens.has(id):
			return
		if pens.size() >= int(_hub.get("MAX_PENS")):
			if _view.has_method("_show_toast"):
				_view.call("_show_toast", "The chart holds %d pens. Remove one first." % int(_hub.get("MAX_PENS")), 3.5)
			return
		pens.append(id)
		_hub.call("set_trend_pens", pens)})


func _rebuild_pens() -> void:
	if _pen_row == null or _chart == null:
		return
	for c in _pen_row.get_children():
		_pen_row.remove_child(c)
		c.queue_free()
	var ids: Array = _hub.call("trend_pens") if _hub != null else []
	var book: Object = _hub.call("book") if _hub != null else null
	var pens: Array = []
	for i in ids.size():
		var id := str(ids[i])
		var t: Dictionary = book.call("tag", id) if book != null else {}
		var col: Color = TrendChart.PEN_COLORS[i % TrendChart.PEN_COLORS.size()]
		pens.append({"id": id, "label": str(t.get("label", id)), "unit": str(t.get("unit", "")),
			"binary": ScadaTags.is_bool_kind(str(t.get("kind", ""))), "color": col})
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", UITheme.chip_style(Color(0.08, 0.10, 0.16, 0.95)))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		chip.add_child(row)
		var sw := ColorRect.new()
		sw.color = col
		sw.custom_minimum_size = Vector2(12, 12)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sw)
		var idx := i
		var name_b := _btn("pen_%d_axis" % i, str(t.get("label", id)), func() -> void:
			_chart.axis_pen = idx
			_chart.queue_redraw())
		name_b.flat = true
		name_b.tooltip_text = "%s\nClick: show this pen's scale on the left axis." % id
		name_b.clip_text = true
		name_b.custom_minimum_size.x = minf(maxf(float(str(t.get("label", id)).length()) * 7.5, 60.0), 220.0)
		row.add_child(name_b)
		var rm := IconButton.make("x", "Remove this pen", func() -> void:
			var cur: Array = _hub.call("trend_pens")
			cur.erase(id)
			_hub.call("set_trend_pens", cur))
		rm.name = "pen_%d_remove" % i
		row.add_child(rm)
		_pen_row.add_child(chip)
	_chart.set_pens(pens)
