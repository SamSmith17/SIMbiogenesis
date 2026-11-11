extends Control

## Draws an ElementSankey (resource composition plan Phase 4): three columns
## of bars, sources → machines / people / plants → destinations, joined by
## ribbons as wide as the amount. Hovering a bar or a ribbon names it and
## its amount (`hover_text`). Pure drawing; the modal feeds it.

signal hovered(text: String)

const COL_W := 14.0
const GAP := 8.0
const PAD := Vector2(12.0, 14.0)
const LABEL_W := 270.0
const RIBBON_STEPS := 24

var data: Dictionary = {}
var lens := "N"
## true: amounts are per hour (NOW); false: totals over a window.
var per_hour := true
var hover_text := ""

var _rects: Dictionary = {}     # node id -> Rect2
var _ribbons: Array = []        # [{poly, text, a, b}]
var _hover_node := ""
var _hover_link := -1


func set_data(sk: Dictionary, lens_id: String, rate: bool) -> void:
	data = sk
	lens = lens_id
	per_hour = rate
	_hover_node = ""
	_hover_link = -1
	queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(760, 460)


func _amount(v: float) -> String:
	return ElementLens.fmt_rate(v, lens) if per_hour else ElementLens.fmt_amount(v, lens)


func _layout() -> void:
	_rects.clear()
	_ribbons.clear()
	var nodes: Array = data.get("nodes", [])
	if nodes.is_empty():
		return
	var cols: Array = [[], [], []]
	var col_tot := [0.0, 0.0, 0.0]
	for n in nodes:
		var c := int(n["col"])
		(cols[c] as Array).append(n)
		col_tot[c] = float(col_tot[c]) + float(n["value"])
	var h := size.y - PAD.y * 2.0
	var scale := INF
	for c2 in 3:
		var cnt := (cols[c2] as Array).size()
		if cnt == 0 or float(col_tot[c2]) <= 0.0:
			continue
		scale = minf(scale, (h - GAP * float(cnt - 1)) / float(col_tot[c2]))
	if scale == INF or scale <= 0.0:
		return
	var xs := [PAD.x + LABEL_W, size.x * 0.5 - COL_W * 0.5, size.x - PAD.x - LABEL_W - COL_W]
	for c3 in 3:
		var used := 0.0
		for n2 in cols[c3]:
			used += maxf(float(n2["value"]) * scale, 2.0)
		used += GAP * float(maxi((cols[c3] as Array).size() - 1, 0))
		var y := PAD.y + (h - used) * 0.5
		for n3 in cols[c3]:
			var bh := maxf(float(n3["value"]) * scale, 2.0)
			_rects[str(n3["id"])] = Rect2(Vector2(float(xs[c3]), y), Vector2(COL_W, bh))
			y += bh + GAP
	# Ribbons: each node's links stacked in order down its edge.
	var out_y: Dictionary = {}
	var in_y: Dictionary = {}
	for id in _rects.keys():
		out_y[id] = (_rects[id] as Rect2).position.y
		in_y[id] = (_rects[id] as Rect2).position.y
	for li in (data.get("links", []) as Array).size():
		var l: Dictionary = data["links"][li]
		var a := str(l["a"])
		var b := str(l["b"])
		if not _rects.has(a) or not _rects.has(b):
			continue
		var t := maxf(float(l["value"]) * scale, 1.0)
		var ra: Rect2 = _rects[a]
		var rb: Rect2 = _rects[b]
		var y0 := float(out_y[a])
		var y1 := float(in_y[b])
		out_y[a] = y0 + t
		in_y[b] = y1 + t
		var x0 := ra.end.x
		var x1 := rb.position.x
		var top := PackedVector2Array()
		var bot := PackedVector2Array()
		for k in RIBBON_STEPS + 1:
			var f := float(k) / float(RIBBON_STEPS)
			var e := f * f * (3.0 - 2.0 * f)
			var x := lerpf(x0, x1, f)
			top.append(Vector2(x, lerpf(y0, y1, e)))
			bot.append(Vector2(x, lerpf(y0 + t, y1 + t, e)))
		bot.reverse()
		var poly := top + bot
		_ribbons.append({"poly": poly, "a": a, "b": b,
			"text": "%s → %s: %s" % [_label_of(a), _label_of(b), _amount(float(l["value"]))]})


func _label_of(id: String) -> String:
	for n in data.get("nodes", []):
		if str(n["id"]) == id:
			return str(n["label"])
	return id


func _draw() -> void:
	_layout()
	var lc := ElementLens.color(lens)
	var fnt := UITheme.font("medium")
	var fs := 13
	if _rects.is_empty():
		var msg := "Nothing carries %s here yet." % ElementLens.label(lens).to_lower()
		draw_string(fnt, Vector2(PAD.x, size.y * 0.5), msg, HORIZONTAL_ALIGNMENT_CENTER, size.x - PAD.x * 2.0, 15,
			UITheme.C_TEXT_S)
		return
	for ri in _ribbons.size():
		var r: Dictionary = _ribbons[ri]
		var hot := ri == _hover_link or str(r["a"]) == _hover_node or str(r["b"]) == _hover_node
		var a := 0.55 if hot else (0.22 if _hover_node.is_empty() and _hover_link < 0 else 0.10)
		draw_colored_polygon(r["poly"], Color(lc, a))
	var last_y := [-INF, -INF, -INF]
	for n in data.get("nodes", []):
		var id := str(n["id"])
		if not _rects.has(id):
			continue
		var rr: Rect2 = _rects[id]
		var kind := str(n["kind"])
		var bar := lc
		if kind == "air":
			bar = Color(0.80, 0.88, 0.95)
		elif kind == "drained":
			bar = UITheme.C_WARN
		elif kind == "other":
			bar = Color(0.55, 0.58, 0.62)
		draw_rect(rr, bar)
		var txt := "%s  %s" % [str(n["label"]), _amount(float(n["value"]))]
		var col := int(n["col"])
		var tw := LABEL_W - 10.0
		var cy := rr.get_center().y
		# Each column's labels never overlap: a label that would land on the
		# one above it is left out (the hover line names it).
		if cy - float(last_y[col]) < float(fs) + 2.0 and id != _hover_node:
			continue
		last_y[col] = cy
		var pos := Vector2(rr.position.x - tw - 6.0, cy + fs * 0.35)
		var align := HORIZONTAL_ALIGNMENT_RIGHT
		if col >= 1:
			# Middle and right: beside the bar, to its right.
			pos = Vector2(rr.end.x + 6.0, cy + fs * 0.35)
			align = HORIZONTAL_ALIGNMENT_LEFT
		var label := UiText.fit(fnt, txt, fs, tw, "element sankey")
		GraphFastDraw.rrect(self, Rect2(Vector2(pos.x - 3.0 if align == HORIZONTAL_ALIGNMENT_LEFT else pos.x + tw
			- fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x - 3.0, cy - fs * 0.7),
			Vector2(fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 6.0, fs * 1.4)), 4.0,
			Color(0.06, 0.08, 0.13, 0.80))
		draw_string(fnt, pos, label, align, tw, fs,
			UITheme.C_TEXT if id == _hover_node or _hover_node.is_empty() else UITheme.C_TEXT_S)


func _gui_input(ev: InputEvent) -> void:
	if not ev is InputEventMouseMotion:
		return
	var p: Vector2 = (ev as InputEventMouseMotion).position
	var node := ""
	for id in _rects.keys():
		if (_rects[id] as Rect2).grow_individual(4.0, 2.0, 4.0, 2.0).has_point(p):
			node = str(id)
			break
	var link := -1
	if node.is_empty():
		for ri in range(_ribbons.size() - 1, -1, -1):
			if Geometry2D.is_point_in_polygon(p, _ribbons[ri]["poly"]):
				link = ri
				break
	if node == _hover_node and link == _hover_link:
		return
	_hover_node = node
	_hover_link = link
	if not node.is_empty():
		for n in data.get("nodes", []):
			if str(n["id"]) == node:
				hover_text = "%s: %s" % [str(n["label"]), _amount(float(n["value"]))]
	elif link >= 0:
		hover_text = str(_ribbons[link]["text"])
	else:
		hover_text = ""
	tooltip_text = hover_text
	hovered.emit(hover_text)
	queue_redraw()
