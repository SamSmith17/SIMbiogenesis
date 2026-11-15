class_name GanttRows
extends Control

## Rows of time segments over a shared hour axis: a person per row over a day
## (the Community schedule's Day tab), or a day per row over 24 hours (its
## Week tab). Each row has its own `t0` (the absolute hour at the left edge),
## the axis spans `span_h` hours. Segments that overlap in one row stack into
## lanes; an instant (a == b) is drawn as a marker with its label.
##
##   set_rows([{id, label, sub, t0, segs: [{a, b, kind, label, color, id,
##              editable}]}], span_h)
##   set_now(abs_h)   the white NOW line, in every row it falls inside
##
## Signals carry the segment dict as given. A drag of an editable segment
## (snapped to SNAP_H, onto any row) emits `segment_moved(seg, new_a)` with
## the new absolute start; it is the caller's job to apply it.

signal segment_hovered(row_id: String, seg: Dictionary)
signal segment_clicked(row_id: String, seg: Dictionary)
signal segment_moved(seg: Dictionary, new_a: float)
signal row_clicked(row_id: String)
signal time_clicked(abs_h: float)

const LABEL_W := 150.0
const RULER_H := 22.0
const LANE_H := 18.0
const ROW_PAD := 4.0
const SNAP_H := 0.25
const DRAG_PX := 4.0
const INSTANT_W := 3.0
const SUB_ROW_H := 36.0

var rows: Array = []
var span_h := 24.0
var now_h := NAN
var selected_id := ""
var label_w := LABEL_W

var _layout: Array = []        # per row: {y, h, lanes: [[seg index…]], lane_of: {i: lane}}
var _hover := Vector2i(-1, -1) # row, seg
var _press := Vector2i(-1, -1)
var _press_pos := Vector2.ZERO
var _dragging := false
var _drag_row := -1
var _drag_a := NAN


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	mouse_exited.connect(func() -> void:
		if not _dragging:
			_hover = Vector2i(-1, -1)
			queue_redraw())


func set_rows(r: Array, span: float = 24.0) -> void:
	rows = r
	span_h = maxf(span, 0.25)
	_relayout()
	queue_redraw()


## A press or drag in progress (the owner must not rebuild the rows under it).
func is_busy() -> bool:
	return _dragging or _press.x >= 0


func set_now(h: float) -> void:
	if (is_nan(h) and is_nan(now_h)) or (not is_nan(now_h) and absf(h - now_h) < 1e-4):
		return
	now_h = h
	queue_redraw()


func set_selected(id: String) -> void:
	if id != selected_id:
		selected_id = id
		queue_redraw()


func _relayout() -> void:
	_layout.clear()
	var y := RULER_H
	for r in rows:
		var segs: Array = (r as Dictionary).get("segs", [])
		var order: Array = range(segs.size())
		order.sort_custom(func(i, j) -> bool:
			return float((segs[i] as Dictionary).get("a", 0.0)) < float((segs[j] as Dictionary).get("a", 0.0)))
		var lane_end: Array = []   # last x-end (hours) per lane
		var lane_of := {}
		var min_gap := span_h * 0.06   # an instant's label needs room
		for i in order:
			var s: Dictionary = segs[i]
			var a := float(s.get("a", 0.0))
			var b := maxf(float(s.get("b", a)), a)
			var reach := b if b > a + 1e-6 else a + min_gap
			var lane := -1
			for k in lane_end.size():
				if float(lane_end[k]) <= a + 1e-6:
					lane = k
					break
			if lane < 0:
				lane = lane_end.size()
				lane_end.append(reach)
			else:
				lane_end[lane] = reach
			lane_of[i] = lane
		var n := maxi(lane_end.size(), 1)
		var h := float(n) * LANE_H + ROW_PAD * 2.0
		# Room for the second label line.
		if not str((r as Dictionary).get("sub", "")).is_empty():
			h = maxf(h, SUB_ROW_H)
		_layout.append({"y": y, "h": h, "lane_of": lane_of, "lanes": n})
		y += h
	custom_minimum_size.y = y + 2.0


func _x_of(row: int, abs_h: float) -> float:
	var t0 := float((rows[row] as Dictionary).get("t0", 0.0))
	var w := maxf(size.x - label_w, 1.0)
	return label_w + (abs_h - t0) / span_h * w


func _h_of(row: int, x: float) -> float:
	var t0 := float((rows[row] as Dictionary).get("t0", 0.0))
	var w := maxf(size.x - label_w, 1.0)
	return t0 + (x - label_w) / w * span_h


func _seg_rect(row: int, i: int) -> Rect2:
	var s: Dictionary = (rows[row] as Dictionary)["segs"][i]
	var L: Dictionary = _layout[row]
	var lane := int((L["lane_of"] as Dictionary).get(i, 0))
	var y := float(L["y"]) + ROW_PAD + float(lane) * LANE_H
	var a := float(s.get("a", 0.0))
	var b := float(s.get("b", a))
	if _dragging and _press == Vector2i(row, i) and not is_nan(_drag_a):
		b = _drag_a + (b - a)
		a = _drag_a
		if _drag_row >= 0 and _drag_row != row:
			return Rect2()   # drawn in its new row instead
	var x0 := _x_of(row, a)
	var x1 := _x_of(row, b)
	if b <= a + 1e-6:
		return Rect2(x0 - INSTANT_W, y + 1.0, INSTANT_W * 2.0, LANE_H - 2.0)
	return Rect2(x0, y + 1.0, maxf(x1 - x0, 1.0), LANE_H - 2.0)


func row_at(p: Vector2) -> int:
	for r in _layout.size():
		var L: Dictionary = _layout[r]
		if p.y >= float(L["y"]) and p.y < float(L["y"]) + float(L["h"]):
			return r
	return -1


func seg_at(p: Vector2) -> Vector2i:
	var r := row_at(p)
	if r < 0 or p.x < label_w:
		return Vector2i(r, -1)
	var segs: Array = (rows[r] as Dictionary).get("segs", [])
	# Instants first (they sit on top), then the smallest span under p.
	var best := -1
	var best_w := INF
	for i in segs.size():
		var rc := _seg_rect(r, i).grow(2.0)
		if not rc.has_point(p):
			continue
		var w := rc.size.x
		if w < best_w:
			best_w = w
			best = i
	return Vector2i(r, best)


## Where a segment is drawn, in this control's coordinates (the harness clicks it).
func seg_center(row_id: String, seg_id: String) -> Vector2:
	for r in rows.size():
		if str((rows[r] as Dictionary).get("id", "")) != row_id:
			continue
		var segs: Array = (rows[r] as Dictionary).get("segs", [])
		for i in segs.size():
			if str((segs[i] as Dictionary).get("id", "")) == seg_id:
				return _seg_rect(r, i).get_center()
	return Vector2(-1, -1)


## The point for absolute hour `abs_h` in row `row_id` (the harness drags to it).
func point_at(row_id: String, abs_h: float) -> Vector2:
	for r in rows.size():
		if str((rows[r] as Dictionary).get("id", "")) == row_id:
			var L: Dictionary = _layout[r]
			return Vector2(_x_of(r, abs_h), float(L["y"]) + ROW_PAD + LANE_H * 0.5)
	return Vector2(-1, -1)


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if _press.x >= 0 and _press.y >= 0:
			var seg: Dictionary = (rows[_press.x] as Dictionary)["segs"][_press.y]
			if bool(seg.get("editable", false)) and (_dragging or mm.position.distance_to(_press_pos) > DRAG_PX):
				_dragging = true
				var r := row_at(mm.position)
				_drag_row = r if r >= 0 else _press.x
				var a0 := float(seg.get("a", 0.0))
				var grab := _h_of(_press.x, _press_pos.x) - a0
				_drag_a = snappedf(_h_of(_drag_row, mm.position.x) - grab, SNAP_H)
				queue_redraw()
				accept_event()
				return
		var h := seg_at(mm.position)
		if h != _hover:
			_hover = h
			if h.x >= 0 and h.y >= 0:
				segment_hovered.emit(str((rows[h.x] as Dictionary).get("id", "")),
					(rows[h.x] as Dictionary)["segs"][h.y])
			queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if mb.position.y < RULER_H and mb.position.x >= label_w and not rows.is_empty():
				time_clicked.emit(_h_of(0, mb.position.x))
				accept_event()
				return
			_press = seg_at(mb.position)
			_press_pos = mb.position
			_dragging = false
			_drag_a = NAN
			_drag_row = -1
			accept_event()
		else:
			var p := _press
			_press = Vector2i(-1, -1)
			if _dragging and p.x >= 0 and p.y >= 0:
				var seg: Dictionary = (rows[p.x] as Dictionary)["segs"][p.y]
				var na := _drag_a
				_dragging = false
				_drag_a = NAN
				_drag_row = -1
				queue_redraw()
				if not is_nan(na) and absf(na - float(seg.get("a", 0.0))) > 1e-4:
					segment_moved.emit(seg, na)
				accept_event()
				return
			_dragging = false
			if p.x >= 0 and p.y >= 0:
				var seg2: Dictionary = (rows[p.x] as Dictionary)["segs"][p.y]
				selected_id = str(seg2.get("id", ""))
				segment_clicked.emit(str((rows[p.x] as Dictionary).get("id", "")), seg2)
				queue_redraw()
			elif p.x >= 0:
				row_clicked.emit(str((rows[p.x] as Dictionary).get("id", "")))
			accept_event()


func _draw() -> void:
	var fnt := UITheme.font("regular")
	var fnt_n := UITheme.font("regular", true)
	var fs := UITheme.FONT_XS
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG, true)
	var w := maxf(size.x - label_w, 1.0)
	# Ruler: hour ticks every 1–6 h by width.
	draw_rect(Rect2(0, 0, size.x, RULER_H), UITheme.C_PANEL, true)
	var step := 1.0
	for s in [1.0, 2.0, 3.0, 6.0, 12.0]:
		step = s
		if w / span_h * s >= 34.0:
			break
	var t0 := float((rows[0] as Dictionary).get("t0", 0.0)) if not rows.is_empty() else 0.0
	var first := ceilf(t0 / step) * step
	var t := first
	while t <= t0 + span_h + 1e-6:
		var x := label_w + (t - t0) / span_h * w
		draw_line(Vector2(x, RULER_H - 5), Vector2(x, size.y), Color(UITheme.C_BORDER, 0.35), 1.0)
		draw_string(fnt_n, Vector2(x + 2, RULER_H - 7), NpcRoutine.format_hour(fposmod(t, 24.0)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_M)
		t += step
	for r in rows.size():
		var row: Dictionary = rows[r]
		var L: Dictionary = _layout[r]
		var y := float(L["y"])
		var h := float(L["h"])
		if r % 2 == 1:
			draw_rect(Rect2(0, y, size.x, h), Color(1, 1, 1, 0.025), true)
		draw_line(Vector2(0, y + h), Vector2(size.x, y + h), Color(UITheme.C_BORDER, 0.25), 1.0)
		var lbl := UiText.fit(fnt, str(row.get("label", "")), fs + 1, label_w - 10.0)
		draw_string(fnt, Vector2(6, y + ROW_PAD + 13), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 1, UITheme.C_TEXT)
		var sub := str(row.get("sub", ""))
		if not sub.is_empty() and h > LANE_H + ROW_PAD * 2.0 - 1.0:
			draw_string(fnt, Vector2(6, y + ROW_PAD + 26), UiText.fit(fnt, sub, fs - 1, label_w - 10.0),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, UITheme.C_TEXT_M)
		var segs: Array = row.get("segs", [])
		for i in segs.size():
			_draw_seg(r, i, segs[i], fnt, fs)
		# A segment being dragged onto this row.
		if _dragging and _drag_row == r and _press.x >= 0 and _press.x != r:
			var sd: Dictionary = (rows[_press.x] as Dictionary)["segs"][_press.y]
			var dur := float(sd.get("b", 0.0)) - float(sd.get("a", 0.0))
			var x0 := _x_of(r, _drag_a)
			var rc := Rect2(x0, y + ROW_PAD + 1, maxf(_x_of(r, _drag_a + dur) - x0, INSTANT_W * 2.0), LANE_H - 2)
			draw_rect(rc, Color(UITheme.C_AMBER, 0.8), true)
		# NOW.
		if not is_nan(now_h):
			var rt0 := float(row.get("t0", 0.0))
			if now_h >= rt0 and now_h <= rt0 + span_h:
				var nx := _x_of(r, now_h)
				draw_line(Vector2(nx, y), Vector2(nx, y + h), Color(1, 1, 1, 0.9), 1.5)
	draw_line(Vector2(label_w, 0), Vector2(label_w, size.y), Color(UITheme.C_BORDER, 0.6), 1.0)
	if not is_nan(now_h) and not rows.is_empty():
		var t00 := float((rows[0] as Dictionary).get("t0", 0.0))
		if now_h >= t00 and now_h <= t00 + span_h:
			var nx0 := _x_of(0, now_h)
			draw_rect(Rect2(nx0 - 15, 2, 30, 13), Color(1, 1, 1, 0.9), true)
			draw_string(fnt_n, Vector2(nx0 - 13, 12), "NOW", HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, UITheme.C_BG)


func _draw_seg(r: int, i: int, s: Dictionary, fnt: Font, fs: int) -> void:
	var rc := _seg_rect(r, i)
	if rc.size.x <= 0.0:
		return
	var col: Color = s.get("color", ScheduledEvents.color_of(str(s.get("kind", ""))))
	var instant := float(s.get("b", 0.0)) <= float(s.get("a", 0.0)) + 1e-6
	var hot := _hover == Vector2i(r, i)
	var sel := not selected_id.is_empty() and str(s.get("id", "")) == selected_id
	if _dragging and _press == Vector2i(r, i):
		col = UITheme.C_AMBER
	if instant:
		draw_rect(rc, Color(col, 0.95), true)
		var tx := rc.end.x + 3.0
		var txt := str(s.get("label", ""))
		draw_string(fnt, Vector2(tx, rc.position.y + 12), UiText.fit(fnt, txt, fs, maxf(size.x - tx - 4, 20.0)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 1.0))
	else:
		draw_rect(rc, Color(col, 0.95 if hot or sel else 0.78), true)
		if rc.size.x > 26.0:
			var txt2 := UiText.fit(fnt, str(s.get("label", "")), fs, rc.size.x - 6.0)
			draw_string(fnt, Vector2(rc.position.x + 3, rc.position.y + 12), txt2,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.06, 0.07, 0.10, 0.95))
	if hot or sel:
		draw_rect(rc.grow(1.0), Color(1, 1, 1, 0.9 if sel else 0.6), false, 1.5)
	if bool(s.get("editable", false)) and hot:
		draw_rect(Rect2(rc.position.x, rc.end.y - 2.0, rc.size.x, 2.0), Color(1, 1, 1, 0.9), true)
