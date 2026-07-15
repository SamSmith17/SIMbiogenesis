class_name GraphNodeLabel
extends RefCounted

## Screen-space label sizing for graph nodes (V1 + V2).
##
## Font sizes are **zoom-proportional**: `base_px`/`max_px` are graph-space design
## sizes and the returned value is scaled to screen by `zoom` so text grows and
## shrinks in lock-step with the node geometry (which is drawn at graph_px × zoom).
## The fit-to-rect terms use the incoming screen rect (already zoomed), so they
## also track zoom. Only a tiny absolute floor / generous ceiling remain, letting
## text stay proportional across the full ZOOM_MIN..ZOOM_MAX range instead of
## sticking inside a fixed screen-pixel band (the old bug where text hung off the
## card when zoomed out and never grew when zoomed in).
##
## `zoom` is the LAST, optional parameter on every sizer so existing positional
## callers (and the selftest) keep working at zoom = 1.0.

## Absolute screen-pixel guard rails — wide enough not to fight the zoom scaling.
const BODY_FONT_MIN := 3
const BODY_FONT_MAX := 64
const TITLE_FONT_MIN := 3
const TITLE_FONT_MAX := 72
const STAT_FONT_MIN := 3
const STAT_FONT_MAX := 96
## Title-band height clamps are in GRAPH pixels (scaled by zoom on the way out).
const TITLE_BAND_MIN_PX := 22.0
const TITLE_BAND_MAX_PX := 36.0


static func body_font_size(inner: Rect2, lines: int = 1,
		base_px: float = 11.0, max_px: float = 13.0, zoom: float = 1.0) -> int:
	# Graph-space design size scaled to screen.
	var ideal := minf(base_px, max_px) * maxf(zoom, 0.001)
	# Fit to node width (inner is screen-space → already carries zoom).
	ideal = minf(ideal, maxf(1.0, inner.size.x * 0.13))
	if lines > 0 and inner.size.y > 4.0:
		var per_line := (inner.size.y - 4.0) / float(lines)
		ideal = minf(ideal, per_line * 0.88)
	return clampi(int(round(ideal)), BODY_FONT_MIN, BODY_FONT_MAX)


static func title_font_size(band_h: float, zoom: float = 1.0) -> int:
	# band_h is screen-space (title_band_height already applied zoom), so the
	# 0.42 fraction tracks zoom for free.
	var ideal := band_h * 0.42
	return clampi(int(round(ideal)), TITLE_FONT_MIN, TITLE_FONT_MAX)


static func stat_font_size(inner: Rect2, max_px: float = 20.0, zoom: float = 1.0) -> int:
	var ideal := minf(max_px * maxf(zoom, 0.001), minf(inner.size.x, inner.size.y) * 0.36)
	return clampi(int(round(ideal)), STAT_FONT_MIN, STAT_FONT_MAX)


static func title_band_height(node_screen_h: float, zoom: float = 1.0) -> float:
	# Clamp the band in graph space so it stays a fixed fraction of the card, then
	# scale back to screen — the band grows/shrinks with zoom like everything else.
	var z := maxf(zoom, 0.001)
	var graph_h := node_screen_h / z
	var band_graph := clampf(graph_h * 0.26, TITLE_BAND_MIN_PX, TITLE_BAND_MAX_PX)
	return band_graph * z


static func ellipsis(fnt: Font, text: String, max_width: float, fsize: int) -> String:
	if text.is_empty() or max_width <= 4.0:
		return text
	if fnt.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x <= max_width:
		return text
	var ell := "…"
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		var trial := text.substr(0, mid) + ell
		if fnt.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x <= max_width:
			lo = mid
		else:
			hi = mid - 1
	return text.substr(0, lo) + ell if lo > 0 else ell
