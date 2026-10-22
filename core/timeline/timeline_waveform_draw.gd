class_name TimelineWaveformDraw
extends RefCounted

## Draw helpers for downsampled sensor waveforms on timeline tracks.


static func draw_track_background(canvas : Control, rect : Rect2, bg : Color, border : Color) -> void:
	canvas.draw_rect(rect, bg, true)
	canvas.draw_rect(rect, border, false, 1.0)


static func draw_label(canvas : Control, rect : Rect2, text : String, col : Color, font : Font) -> void:
	canvas.draw_string(font, Vector2(rect.position.x + 3.0, rect.end.y - 3.0),
		text, HORIZONTAL_ALIGNMENT_LEFT, int(rect.size.x) - 6, 8,
		Color(col.r, col.g, col.b, 0.82))


## Draw TimelineBinning bins ({w, i0, n, mn, mean, mx}) in a lane showing
## [view_t0, view_t0 + view_span): each bin at its OWN absolute time (anchored,
## so nothing slides while panning). Per run of known bins: a soft fill from
## the lane floor up to the mean, the min–max band (what a bin hides when
## zoomed out — a sawtooth stays a band instead of turning into a smooth
## curve), and the mean line. Gaps where nothing is known.
static func draw_bins(canvas : Control, rect : Rect2, b : Dictionary, view_t0 : float,
		view_span : float, v_min : float, v_max : float, color : Color) -> void:
	var n := int(b.get("n", 0))
	if n <= 0 or rect.size.x <= 1.0 or rect.size.y <= 1.0 or view_span <= 0.0:
		return
	var w := float(b["w"])
	var i0 := int(b["i0"])
	var mn : PackedFloat32Array = b["mn"]
	var me : PackedFloat32Array = b["mean"]
	var mx : PackedFloat32Array = b["mx"]
	var span := maxf(v_max - v_min, 1e-6)
	var pad := 2.0
	var inner := Rect2(rect.position.x, rect.position.y + pad,
		rect.size.x, maxf(rect.size.y - pad * 2.0, 1.0))
	var px_per_h := inner.size.x / view_span
	var mean_pts := PackedVector2Array()
	var hi_pts := PackedVector2Array()
	var lo_pts := PackedVector2Array()
	for k in n + 1:
		var known := k < n and not is_nan(me[k])
		var x := inner.position.x + ((float(i0 + k) + 0.5) * w - view_t0) * px_per_h
		if known and x >= inner.position.x - px_per_h * w and x <= inner.end.x + px_per_h * w:
			x = clampf(x, inner.position.x, inner.end.x)
			mean_pts.append(Vector2(x, _y(me[k], v_min, span, inner)))
			hi_pts.append(Vector2(x, _y(mx[k], v_min, span, inner)))
			lo_pts.append(Vector2(x, _y(mn[k], v_min, span, inner)))
			continue
		if not known or k == n:
			_flush_run(canvas, inner, mean_pts, hi_pts, lo_pts, color, px_per_h * w)
			mean_pts = PackedVector2Array()
			hi_pts = PackedVector2Array()
			lo_pts = PackedVector2Array()


static func _y(v : float, v_min : float, span : float, inner : Rect2) -> float:
	return inner.end.y - clampf((v - v_min) / span, 0.0, 1.0) * inner.size.y


static func _flush_run(canvas : Control, inner : Rect2, mean_pts : PackedVector2Array,
		hi_pts : PackedVector2Array, lo_pts : PackedVector2Array, color : Color, bin_px : float) -> void:
	var m := mean_pts.size()
	if m == 0:
		return
	if m == 1:
		var half := maxf(bin_px * 0.5, 1.5)
		var p := mean_pts[0]
		canvas.draw_rect(Rect2(p.x - half, hi_pts[0].y, half * 2.0, maxf(lo_pts[0].y - hi_pts[0].y, 1.0)),
			Color(color.r, color.g, color.b, 0.30), true)
		canvas.draw_line(Vector2(p.x - half, p.y), Vector2(p.x + half, p.y), Color(color.r, color.g, color.b, 0.95), 1.5)
		return
	# Soft fill under the mean, then the min–max band. Both are strips between
	# two edges sharing x, built as explicit triangles: a polygon outline can
	# be zero-width in places (a flat stretch, a bin where min == max), which
	# Godot's polygon triangulator rejects with an engine error.
	var floor_pts := PackedVector2Array()
	floor_pts.resize(m)
	for i in m:
		floor_pts[i] = Vector2(mean_pts[i].x, inner.end.y)
	_strip(canvas, mean_pts, floor_pts, Color(color.r, color.g, color.b, 0.18))
	_strip(canvas, hi_pts, lo_pts, Color(color.r, color.g, color.b, 0.32))
	canvas.draw_polyline(mean_pts, Color(color.r, color.g, color.b, 0.95), 1.5, true)


## The band between two edges with the same x (top[i].x == bottom[i].x) as one
## triangle list — no triangulation, one draw call.
static func _strip(canvas : Control, top : PackedVector2Array, bottom : PackedVector2Array, col : Color) -> void:
	var m := top.size()
	if m < 2:
		return
	var pts := PackedVector2Array()
	pts.resize(m * 2)
	for i in m:
		pts[i * 2] = top[i]
		pts[i * 2 + 1] = bottom[i]
	var idx := PackedInt32Array()
	for i in m - 1:
		var a := i * 2
		idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	var cols := PackedColorArray()
	cols.resize(pts.size())
	cols.fill(col)
	RenderingServer.canvas_item_add_triangle_array(canvas.get_canvas_item(), idx, pts, cols)


## A track's scale, small at the right end of the lane ("12 – 31 °F").
static func draw_range_label(canvas : Control, rect : Rect2, text : String, col : Color, font : Font) -> void:
	canvas.draw_string(font, Vector2(rect.end.x - 156.0, rect.position.y + 10.0),
		text, HORIZONTAL_ALIGNMENT_RIGHT, 150, 8, Color(col.r, col.g, col.b, 0.75))
