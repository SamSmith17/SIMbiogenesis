class_name SiteReportCharts
extends RefCounted

## Static, UITheme-styled chart drawers for the Site Report panel — the same
## "connect a child Control's draw signal to a static painter" idiom used by
## timeline_ui.gd / record_book_panel.gd. Every function paints onto a passed
## Control using its current `size`, so cards can lay out with containers and
## the charts fill their slot.

const MONTHS := SiteReportMetrics.MONTH_ABBR


# ---------------------------------------------------------------------------
# Monthly bar chart (12 bars) with optional hover highlight + baseline axis.
# ---------------------------------------------------------------------------
static func draw_monthly_bars(c: Control, values: PackedFloat32Array, col: Color,
		unit: String, font: Font, hover_idx: int = -1, value_fmt: String = "%.0f") -> void:
	var w := c.size.x
	var h := c.size.y
	if w < 40.0 or h < 30.0 or values.size() < 12:
		return
	var pad_l := 6.0
	var pad_r := 6.0
	var pad_top := 16.0
	var pad_bot := 16.0
	var plot_w := w - pad_l - pad_r
	var plot_h := h - pad_top - pad_bot
	var baseline := pad_top + plot_h

	var vmax := 0.0
	for i in range(12):
		var v := values[i]
		if not is_nan(v):
			vmax = maxf(vmax, v)
	if vmax <= 0.0:
		vmax = 1.0

	# Gridlines + y-max label.
	c.draw_line(Vector2(pad_l, baseline), Vector2(pad_l + plot_w, baseline),
		Color(UITheme.C_BORDER, 0.55), 1.0)
	c.draw_line(Vector2(pad_l, pad_top), Vector2(pad_l + plot_w, pad_top),
		Color(UITheme.C_BORDER, 0.18), 1.0)
	c.draw_string(font, Vector2(pad_l, pad_top - 4.0),
		"%s %s" % [(value_fmt % vmax), unit], HORIZONTAL_ALIGNMENT_LEFT, -1,
		UITheme.FONT_XS, UITheme.C_TEXT_M)

	var slot := plot_w / 12.0
	var bar_w := slot * 0.64
	for i in range(12):
		var v := values[i]
		if is_nan(v):
			v = 0.0
		var bx := pad_l + float(i) * slot + (slot - bar_w) * 0.5
		var bh := clampf(v / vmax, 0.0, 1.0) * plot_h
		var is_hover := i == hover_idx
		var bar_col := col if not is_hover else col.lightened(0.25)
		if is_hover:
			c.draw_rect(Rect2(pad_l + float(i) * slot, pad_top, slot, plot_h),
				Color(1.0, 1.0, 1.0, 0.06), true)
		c.draw_rect(Rect2(bx, baseline - bh, bar_w, bh), bar_col, true)
		var lbl_col := UITheme.C_TEXT_S if is_hover else UITheme.C_TEXT_M
		c.draw_string(font, Vector2(pad_l + float(i) * slot, h - 3.0),
			MONTHS[i].substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, slot, UITheme.FONT_XS, lbl_col)
	# Hover readout (value) near the top-right.
	if hover_idx >= 0 and hover_idx < 12:
		var hv := values[hover_idx]
		if is_nan(hv):
			hv = 0.0
		var txt := "%s: %s %s" % [MONTHS[hover_idx], (value_fmt % hv), unit]
		c.draw_string(font, Vector2(pad_l, pad_top - 4.0),
			txt, HORIZONTAL_ALIGNMENT_RIGHT, plot_w, UITheme.FONT_XS, col.lightened(0.2))


# ---------------------------------------------------------------------------
# Monthly temperature band (min–max range bars + mean line).
# ---------------------------------------------------------------------------
static func draw_temp_band(c: Control, mean_c: PackedFloat32Array,
		min_c: PackedFloat32Array, max_c: PackedFloat32Array,
		font: Font, hover_idx: int = -1) -> void:
	var w := c.size.x
	var h := c.size.y
	if w < 40.0 or h < 30.0 or mean_c.size() < 12:
		return
	var pad_l := 8.0
	var pad_r := 8.0
	var pad_top := 16.0
	var pad_bot := 16.0
	var plot_w := w - pad_l - pad_r
	var plot_h := h - pad_top - pad_bot

	var lo := INF
	var hi := -INF
	for i in range(12):
		if not is_nan(min_c[i]):
			lo = minf(lo, min_c[i])
		if not is_nan(max_c[i]):
			hi = maxf(hi, max_c[i])
	if not is_finite(lo) or not is_finite(hi) or hi <= lo:
		lo = 0.0
		hi = 1.0
	var span := hi - lo
	var y_of := func(t: float) -> float:
		return pad_top + (1.0 - clampf((t - lo) / span, 0.0, 1.0)) * plot_h

	# Zero line if it falls in range.
	if lo < 0.0 and hi > 0.0:
		var zy: float = y_of.call(0.0)
		c.draw_line(Vector2(pad_l, zy), Vector2(pad_l + plot_w, zy),
			Color(UITheme.C_BORDER, 0.5), 1.0)
	# Range label.
	c.draw_string(font, Vector2(pad_l, pad_top - 4.0),
		"%.0f°C" % hi, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)
	c.draw_string(font, Vector2(pad_l, pad_top + plot_h + 12.0),
		"%.0f°C" % lo, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)

	var slot := plot_w / 12.0
	var col_warm := UITheme.C_ERROR
	var col_cool := Color(0.25, 0.45, 1.0, 1.0)
	var mean_pts := PackedVector2Array()
	for i in range(12):
		var cx := pad_l + float(i) * slot + slot * 0.5
		var y_min: float = y_of.call(min_c[i]) if not is_nan(min_c[i]) else y_of.call(0.0)
		var y_max: float = y_of.call(max_c[i]) if not is_nan(max_c[i]) else y_of.call(0.0)
		if i == hover_idx:
			c.draw_rect(Rect2(pad_l + float(i) * slot, pad_top, slot, plot_h),
				Color(1.0, 1.0, 1.0, 0.06), true)
		# Range bar (blue at bottom → red at top via a simple vertical gradient).
		var bar_w := slot * 0.34
		c.draw_rect(Rect2(cx - bar_w * 0.5, y_max, bar_w, maxf(y_min - y_max, 1.0)),
			Color(col_warm, 0.35), true)
		c.draw_line(Vector2(cx, y_min), Vector2(cx, y_max), Color(col_cool, 0.85), 2.0)
		if not is_nan(mean_c[i]):
			var my: float = y_of.call(mean_c[i])
			mean_pts.append(Vector2(cx, my))
			c.draw_circle(Vector2(cx, my), 2.5, UITheme.C_GOLD)
		c.draw_string(font, Vector2(pad_l + float(i) * slot, h - 3.0),
			MONTHS[i].substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, slot, UITheme.FONT_XS,
			UITheme.C_TEXT_M if i != hover_idx else UITheme.C_TEXT_S)
	if mean_pts.size() >= 2:
		c.draw_polyline(mean_pts, Color(UITheme.C_GOLD, 0.85), 1.5)
	if hover_idx >= 0 and hover_idx < 12:
		var txt := "%s  %.0f/%.0f/%.0f°C (lo/mean/hi)" % [
			MONTHS[hover_idx],
			(min_c[hover_idx] if not is_nan(min_c[hover_idx]) else 0.0),
			(mean_c[hover_idx] if not is_nan(mean_c[hover_idx]) else 0.0),
			(max_c[hover_idx] if not is_nan(max_c[hover_idx]) else 0.0)]
		c.draw_string(font, Vector2(pad_l, pad_top - 4.0),
			txt, HORIZONTAL_ALIGNMENT_RIGHT, plot_w, UITheme.FONT_XS, UITheme.C_GOLD)


# ---------------------------------------------------------------------------
# Windrose — petals per sector, length ∝ frequency, tint ∝ mean speed.
# ---------------------------------------------------------------------------
static func draw_windrose(c: Control, freq: PackedFloat32Array,
		mean_ms: PackedFloat32Array, font: Font, hover_idx: int = -1) -> void:
	var w := c.size.x
	var h := c.size.y
	var n := freq.size()
	if w < 40.0 or h < 40.0 or n < 4:
		return
	var center := Vector2(w * 0.5, h * 0.5)
	var radius := minf(w, h) * 0.5 - 18.0
	if radius <= 4.0:
		return

	var fmax := 0.0
	var smax := 1.0
	for i in range(n):
		fmax = maxf(fmax, freq[i])
		smax = maxf(smax, mean_ms[i])
	if fmax <= 0.0:
		fmax = 1.0

	# Concentric guide rings + cardinal labels.
	for r in [0.33, 0.66, 1.0]:
		c.draw_arc(center, radius * r, 0.0, TAU, 48, Color(UITheme.C_BORDER, 0.35), 1.0)
	var card := {0: "N", int(n / 4): "E", int(n / 2): "S", int(3 * n / 4): "W"}
	for si in card.keys():
		var ang := float(si) / float(n) * TAU - PI / 2.0
		var lp := center + Vector2(cos(ang), sin(ang)) * (radius + 10.0)
		c.draw_string(font, lp - Vector2(4, -4), card[si], HORIZONTAL_ALIGNMENT_LEFT,
			-1, UITheme.FONT_XS, UITheme.C_TEXT_S)

	var half := (TAU / float(n)) * 0.42
	for i in range(n):
		var frac := clampf(freq[i] / fmax, 0.0, 1.0)
		if frac <= 0.001:
			continue
		var r := radius * frac
		var ang0 := float(i) / float(n) * TAU - PI / 2.0
		# Tint: low speed = cyan, high speed = amber/red.
		var t := clampf(mean_ms[i] / maxf(smax, 0.1), 0.0, 1.0)
		var col := UITheme.C_PRIMARY.lerp(UITheme.C_ERROR, t)
		if i == hover_idx:
			col = col.lightened(0.3)
		var poly := PackedVector2Array()
		poly.append(center)
		var steps := 6
		for s in range(steps + 1):
			var a := ang0 - half + (2.0 * half) * float(s) / float(steps)
			poly.append(center + Vector2(cos(a), sin(a)) * r)
		c.draw_colored_polygon(poly, Color(col, 0.8))
	if hover_idx >= 0 and hover_idx < n:
		var labels := SiteReportMetrics.sector_labels(n)
		var txt := "%s  %.0f%%  %.1f m/s" % [
			labels[hover_idx], freq[hover_idx] * 100.0, mean_ms[hover_idx]]
		c.draw_string(font, Vector2(4, h - 4), txt, HORIZONTAL_ALIGNMENT_LEFT,
			w - 8, UITheme.FONT_XS, UITheme.C_TEXT_S)


## Sector index under a local point in a windrose Control (or -1). Mirrors
## draw_windrose geometry so the panel can drive hover.
static func windrose_sector_at(c: Control, pos: Vector2, n: int) -> int:
	var center := Vector2(c.size.x * 0.5, c.size.y * 0.5)
	var radius := minf(c.size.x, c.size.y) * 0.5 - 18.0
	var d := pos - center
	if d.length() > radius or d.length() < 2.0:
		return -1
	var ang := atan2(d.y, d.x) + PI / 2.0  # 0 at N (up), clockwise
	var deg := rad_to_deg(ang)
	return SiteReportMetrics.windrose_sector_index(deg, n)
