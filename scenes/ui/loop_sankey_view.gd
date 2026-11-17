extends Control

## A loop Sankey in a window (plans: now-i-want-to-linked-garden): the same
## layout (LoopSankeyLayout) and drawing (GraphFlowLens, header off) as the
## graph's Flows lens, fitted to this control. Used by "Where it goes…" and
## the run results. Wheel zooms about the pointer, drag pans, double-click
## re-fits; hovering a ribbon lights its loop and names it (`hovered`).
##
##   set_input(input, fmt, color_of, name_of)
##     input = {nodes, edges, bin, bout, labels, types, keys, opts}
##     fmt(key, value) -> String; color_of(key) -> Color; name_of(key) -> String

signal hovered(text: String)

var lens: GraphFlowLens = GraphFlowLens.new()
var fmt: Callable = Callable()
var color_of: Callable = Callable()
var name_of: Callable = Callable()
var style: Dictionary = GraphFlowStyle.resolve({"preset": "sankey"})
var animate := true

var _zoom := 1.0
var _pan := Vector2.ZERO
var _fitted := false
var _drag := false
var _clock := 0.0
var _last_hover := ""
## The Column / Torus chips in the top right corner: [[rect, shape id]].
var _shape_chips: Array = []
## Off for an embedder that wants one fixed shape.
var show_shape_chips := true
var _last_input: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	lens.show_header = false
	resized.connect(func() -> void: _fitted = false)
	set_process(true)


func set_input(input: Dictionary, fmt_fn: Callable, color_fn: Callable, name_fn: Callable) -> void:
	fmt = fmt_fn
	color_of = color_fn
	name_of = name_fn
	_last_input = [input, fmt_fn, color_fn, name_fn]
	var sig := var_to_str([input.get("nodes", []), input.get("edges", []), input.get("bin", []), input.get("bout", [])]).md5_text()
	lens.set_input(sig, input)
	lens.advance(10.0)
	_fitted = false
	queue_redraw()


## "column" or "torus" (ToroidFlowLayout). Call before set_input.
func set_shape(sh: String) -> void:
	lens.set_shape(sh)
	if _last_input.size() == 4:
		set_input(_last_input[0], _last_input[1], _last_input[2], _last_input[3])
	_fitted = false
	queue_redraw()


func _draw_shape_chips() -> void:
	_shape_chips.clear()
	if not show_shape_chips:
		return
	var f := UITheme.font("medium", true)
	var x := size.x - 10.0
	for i in range(GraphFlowLens.SHAPES.size() - 1, -1, -1):
		var item: Array = GraphFlowLens.SHAPES[i]
		var on := str(item[0]) == lens.shape
		var w := f.get_string_size(str(item[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 16.0
		var r := Rect2(Vector2(x - w, 8.0), Vector2(w, 20.0))
		var c := Color(0.98, 0.74, 0.26)
		GraphFastDraw.rrect(self, r, 6.0, Color(c, 0.30 if on else 0.10))
		draw_rect(r, Color(c, 0.85 if on else 0.3), false, 1.0)
		draw_string(f, Vector2(r.position.x + 8.0, r.position.y + 14.0), str(item[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.94, 0.96, 0.99) if on else Color(0.70, 0.76, 0.84))
		_shape_chips.append([r, str(item[0])])
		x -= w + 6.0


func has_picture() -> bool:
	return lens.has_layout() and not (lens.cur.get("nodes", {}) as Dictionary).is_empty()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var fading := lens.advance(delta)
	if animate:
		_clock += delta
	if animate or fading:
		queue_redraw()


func _fit() -> void:
	var f := lens.fit(size, Vector2(30.0, 40.0), 0.0)
	if f.is_empty():
		return
	_zoom = float(f["zoom"])
	_pan = f["pan"] as Vector2
	_fitted = true


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.05, 0.085, 1.0))
	if not has_picture():
		var f := UITheme.font("medium")
		draw_string(f, Vector2(0.0, size.y * 0.5), "Nothing flows in this window.",
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, Color(0.65, 0.70, 0.78))
		return
	if not _fitted:
		_fit()
	lens.draw(self, size * 0.5, _pan, _zoom, {
		"style": style, "clock": _clock, "flowing": animate, "blur": false, "selected": "",
		"font": UITheme.font("semibold"),
		"color_of": color_of, "name_of": name_of, "fmt": fmt,
		"node_color": func(_id: String) -> Color: return Color(0.55, 0.65, 0.85),
	})
	_draw_shape_chips()


func _gui_input(event: InputEvent) -> void:
	var center := size * 0.5
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var f := 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
			var world := (mb.position - center - _pan) / _zoom
			_zoom = clampf(_zoom * f, 0.05, 4.0)
			_pan = mb.position - center - world * _zoom
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				for ch in _shape_chips:
					if (ch[0] as Rect2).has_point(mb.position):
						set_shape(str(ch[1]))
						accept_event()
						return
			if mb.pressed and mb.double_click:
				_fitted = false
				queue_redraw()
			_drag = mb.pressed
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag:
			_pan += mm.relative
			queue_redraw()
			return
		var hn := lens.pick_node(mm.position, center, _pan, _zoom)
		var hr := -1 if hn != "" else lens.pick_ribbon(mm.position, center, _pan, _zoom)
		lens.hover_node = hn
		lens.hover_ribbon = hr
		lens.hover_loop = int(lens.ribbon(hr).get("loop", -1)) if hr >= 0 else -1
		var txt := _hover_text(hn, hr)
		if txt != _last_hover:
			_last_hover = txt
			hovered.emit(txt)
		queue_redraw()


func _hover_text(node_id: String, ri: int) -> String:
	var labels: Dictionary = lens.cur.get("labels", {})
	if node_id != "":
		var nd: Dictionary = (lens.cur.get("nodes", {}) as Dictionary).get(node_id, {})
		var tin := 0.0
		var tout := 0.0
		var key := ""
		for rb in (lens.cur.get("ribbons", []) as Array):
			if str(rb["b"]) == node_id:
				tin += float(rb["value"])
				key = str(rb["key"])
			if str(rb["a"]) == node_id:
				tout += float(rb["value"])
				key = str(rb["key"])
		var t := "%s: %s in · %s out" % [str(labels.get(node_id, node_id)), str(fmt.call(key, tin)), str(fmt.call(key, tout))]
		if int(nd.get("loop", -1)) >= 0:
			t += " · part of a loop"
		return t
	var rb2 := lens.ribbon(ri)
	if rb2.is_empty():
		return ""
	var a := str(labels.get(str(rb2["a"]), rb2["a"])) if str(rb2["a"]) != "" else str(rb2.get("label", "outside"))
	var b := str(labels.get(str(rb2["b"]), rb2["b"])) if str(rb2["b"]) != "" else str(rb2.get("label", "outside"))
	var verb := "returns to" if str(rb2["kind"]) == LoopSankeyLayout.KIND_RETURN else "→"
	return "%s %s %s · %s" % [a, verb, b, str(fmt.call(str(rb2["key"]), float(rb2["value"])))]
