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


static func draw_envelope(canvas : Control, rect : Rect2, bins : PackedFloat32Array,
		v_max : float, color : Color) -> void:
	if bins.is_empty() or rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var n := bins.size()
	var scale := 1.0 / maxf(v_max, 1e-6)
	var pad := 2.0
	var inner := Rect2(rect.position.x, rect.position.y + pad,
		rect.size.x, maxf(rect.size.y - pad * 2.0, 1.0))
	var pts := PackedVector2Array()
	pts.append(Vector2(inner.position.x, inner.end.y))
	for i in n:
		var x := inner.position.x + (float(i) / float(maxi(n - 1, 1))) * inner.size.x
		var h := clampf(float(bins[i]) * scale, 0.0, 1.0) * inner.size.y
		pts.append(Vector2(x, inner.end.y - h))
	pts.append(Vector2(inner.end.x, inner.end.y))
	canvas.draw_colored_polygon(pts, Color(color.r, color.g, color.b, 0.45))
	for i in n - 1:
		var x0 := inner.position.x + (float(i) / float(maxi(n - 1, 1))) * inner.size.x
		var x1 := inner.position.x + (float(i + 1) / float(maxi(n - 1, 1))) * inner.size.x
		var y0 := inner.end.y - clampf(float(bins[i]) * scale, 0.0, 1.0) * inner.size.y
		var y1 := inner.end.y - clampf(float(bins[i + 1]) * scale, 0.0, 1.0) * inner.size.y
		canvas.draw_line(Vector2(x0, y0), Vector2(x1, y1), Color(color.r, color.g, color.b, 0.95), 1.0)


static func draw_line_fill(canvas : Control, rect : Rect2, bins : PackedFloat32Array,
		v_min : float, v_max : float, color : Color) -> void:
	if bins.is_empty() or rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var span := maxf(v_max - v_min, 1e-6)
	var n := bins.size()
	var pad := 2.0
	var inner := Rect2(rect.position.x, rect.position.y + pad,
		rect.size.x, maxf(rect.size.y - pad * 2.0, 1.0))
	var pts := PackedVector2Array()
	pts.append(Vector2(inner.position.x, inner.end.y))
	for i in n:
		var x := inner.position.x + (float(i) / float(maxi(n - 1, 1))) * inner.size.x
		var norm := (float(bins[i]) - v_min) / span
		var y := inner.end.y - clampf(norm, 0.0, 1.0) * inner.size.y
		pts.append(Vector2(x, y))
	pts.append(Vector2(inner.end.x, inner.end.y))
	canvas.draw_colored_polygon(pts, Color(color.r, color.g, color.b, 0.35))
	for i in n - 1:
		var x0 := inner.position.x + (float(i) / float(maxi(n - 1, 1))) * inner.size.x
		var x1 := inner.position.x + (float(i + 1) / float(maxi(n - 1, 1))) * inner.size.x
		var y0 := inner.end.y - clampf((float(bins[i]) - v_min) / span, 0.0, 1.0) * inner.size.y
		var y1 := inner.end.y - clampf((float(bins[i + 1]) - v_min) / span, 0.0, 1.0) * inner.size.y
		canvas.draw_line(Vector2(x0, y0), Vector2(x1, y1), Color(color.r, color.g, color.b, 0.95), 1.5)


static func vmax_for_bins(bins : PackedFloat32Array, channel : String, capacity_kwh : float) -> float:
	match channel:
		"soc_pct":
			return 100.0
		"soc_kwh":
			return maxf(capacity_kwh, 1.0)
		_:
			var peak := 0.0
			for v in bins:
				peak = maxf(peak, float(v))
			return maxf(peak * 1.15, 0.5)
