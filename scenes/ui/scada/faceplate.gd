extends PanelContainer

## A faceplate: the small card that opens on a valve, heater, pump or drain
## in a process picture (plans/SCADA_PROCESS_PLAN.md, Phase 2). It shows what
## the thing is and its state, and carries its buttons (Open / Close, On /
## Off). The owner fills it; it knows nothing about what it controls.
##
##   show_for({title, subtitle, state, state_color, lines: [[key, value]],
##             buttons: [{id, text, on_press: Callable, disabled, tip}]},
##            at)                       `at` = where to stand, global pixels
##   set_state(text, color)             while it is open
##   dismiss()
##
## Top-level (it stands over a picture inside a zoomed modal); closes on Esc
## or when the owner calls dismiss().

signal dismissed

var _title: Label
var _sub: Label
var _state: Label
var _rows: VBoxContainer
var _btns: HBoxContainer
var _shown_for := ""
var _trend: Control
var _trend_lbl: Label
## [{values: PackedFloat32Array, color, lo?, hi?}] (NAN = a gap).
var _trend_series: Array = []
## Operator mode: buttons big enough for a finger.
var touch := false
## Pixels kept clear at the top of the box it stands in (bars, tabs).
var top_clear := 0.0


func _init() -> void:
	top_level = true
	visible = false
	z_index = 20
	custom_minimum_size = Vector2(230, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	_title = Label.new()
	_title.name = "title"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.add_theme_font_override("font", UITheme.font("semibold"))
	head.add_child(_title)
	head.add_child(IconButton.close(dismiss))
	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_sub.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_sub)
	_state = Label.new()
	_state.name = "state"
	_state.add_theme_font_override("font", UITheme.font("semibold", true))
	_state.add_theme_font_size_override("font_size", UITheme.FONT_LG if "FONT_LG" in UITheme else 18)
	v.add_child(_state)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	v.add_child(_rows)
	_trend_lbl = Label.new()
	_trend_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_trend_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	v.add_child(_trend_lbl)
	_trend = Control.new()
	_trend.name = "trend"
	_trend.custom_minimum_size = Vector2(230, 54)
	_trend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_trend.draw.connect(_draw_trend)
	v.add_child(_trend)
	_btns = HBoxContainer.new()
	_btns.name = "buttons"
	_btns.add_theme_constant_override("separation", 6)
	v.add_child(_btns)


func show_for(d: Dictionary, at: Vector2) -> void:
	_shown_for = str(d.get("id", ""))
	_title.text = str(d.get("title", ""))
	_sub.text = str(d.get("subtitle", ""))
	_sub.visible = not _sub.text.is_empty()
	set_state(str(d.get("state", "")), d.get("state_color", UITheme.C_TEXT))
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for ln in d.get("lines", []):
		_rows.add_child(KVRow.make(str(ln[0]), str(ln[1])))
	set_trend(d.get("trend", {}) as Dictionary)
	for c in _btns.get_children():
		_btns.remove_child(c)
		c.queue_free()
	for b in d.get("buttons", []):
		var btn := Button.new()
		btn.name = str(b.get("id", "btn"))
		btn.text = str(b.get("text", ""))
		btn.disabled = bool(b.get("disabled", false))
		btn.tooltip_text = str(b.get("tip", ""))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(btn)
		if touch:
			btn.custom_minimum_size = Vector2(110, 56)
			btn.add_theme_font_size_override("font_size", 18)
		var cb: Callable = b.get("on_press", Callable())
		if cb.is_valid():
			btn.pressed.connect(cb)
		_btns.add_child(btn)
	_btns.visible = _btns.get_child_count() > 0
	visible = true
	# Its own size, never its parent's (a top-level child of a full-rect modal
	# is otherwise stretched to the modal's height).
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	size = get_combined_minimum_size()
	place(at)


## Stand beside `at`, inside the window.
func place(at: Vector2) -> void:
	var vp := get_viewport_rect().size
	var sz := get_combined_minimum_size()
	if size != sz:
		size = sz
	# Inside the picture it belongs to (its parent), else the window.
	var box := Rect2(Vector2.ZERO, vp)
	var par := get_parent_control()
	if par != null and par.size.x > sz.x + 16.0 and par.size.y > sz.y + 16.0:
		box = par.get_global_rect()
		if box.size.y - top_clear > sz.y + 16.0:
			box = Rect2(box.position + Vector2(0.0, top_clear), box.size - Vector2(0.0, top_clear))
	var p := at + Vector2(18.0, -sz.y * 0.5)
	if p.x + sz.x > box.end.x - 8.0:
		p.x = at.x - sz.x - 18.0
	p.x = clampf(p.x, box.position.x + 8.0, maxf(box.end.x - sz.x - 8.0, box.position.x + 8.0))
	p.y = clampf(p.y, box.position.y + 8.0, maxf(box.end.y - sz.y - 8.0, box.position.y + 8.0))
	global_position = p


func set_state(text: String, color: Color = UITheme.C_TEXT) -> void:
	if _state.text != text:
		_state.text = text
	_state.visible = not text.is_empty()
	_state.add_theme_color_override("font_color", color)


func shown_for() -> String:
	return _shown_for if visible else ""


func button(id: String) -> Button:
	return _btns.get_node_or_null(id) as Button


func dismiss() -> void:
	if visible:
		visible = false
		_shown_for = ""
		dismissed.emit()


## A small trend under the lines: {label, series: [{values, color, lo, hi}]}.
## Each series is drawn on its own scale (lo / hi, else its own range).
func set_trend(t: Dictionary) -> void:
	_trend_series = t.get("series", []) as Array
	var any := false
	for s in _trend_series:
		for v in (s as Dictionary).get("values", PackedFloat32Array()):
			if not is_nan(v):
				any = true
				break
	_trend.visible = any
	_trend_lbl.visible = any
	_trend_lbl.text = str(t.get("label", ""))
	_trend.queue_redraw()


func trend_points() -> int:
	var n := 0
	for s in _trend_series:
		for v in (s as Dictionary).get("values", PackedFloat32Array()):
			if not is_nan(v):
				n += 1
	return n


func _draw_trend() -> void:
	var sz := _trend.size
	_trend.draw_rect(Rect2(Vector2.ZERO, sz), Color(0.06, 0.09, 0.16, 0.9))
	for s in _trend_series:
		var vals: PackedFloat32Array = (s as Dictionary).get("values", PackedFloat32Array())
		if vals.size() < 2:
			continue
		var lo := float(s.get("lo", INF))
		var hi := float(s.get("hi", -INF))
		if lo > hi:
			for v in vals:
				if not is_nan(v):
					lo = minf(lo, v)
					hi = maxf(hi, v)
			var pad := maxf((hi - lo) * 0.15, 0.5)
			lo -= pad
			hi += pad
		if hi - lo < 1e-6:
			continue
		var run := PackedVector2Array()
		for i in vals.size():
			if is_nan(vals[i]):
				if run.size() >= 2:
					_trend.draw_polyline(run, s.get("color", Color.WHITE), 1.5, true)
				run = PackedVector2Array()
				continue
			run.append(Vector2(sz.x * float(i) / float(vals.size() - 1), sz.y - 3.0 - (sz.y - 6.0) * clampf((vals[i] - lo) / (hi - lo), 0.0, 1.0)))
		if run.size() >= 2:
			_trend.draw_polyline(run, s.get("color", Color.WHITE), 1.5, true)
