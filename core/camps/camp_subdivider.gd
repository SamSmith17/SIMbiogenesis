class_name CampSubdivider
extends RefCounted

## Splits a drawn zone into camp PLOTS with access lanes between them — the way
## a regional festival hands out placement: blocks of plots, back to back in
## pairs, with a lane you can drive down between the blocks and a cross lane
## every few plots.
##
## Pure geometry. Each returned plot becomes its own CampAreaLayer record, so it
## can then be restyled, reseeded or deleted on its own.

## Rows per block: plots sit back-to-back in pairs, then a lane.
const ROWS_PER_BLOCK := 2
## A cross lane after this many plots along a row.
const PLOTS_PER_RUN := 4
## A clipped plot smaller than this share of a full plot is not a plot.
const MIN_PLOT_FRACTION := 0.3
const MAX_PLOTS := 200


## Returns Array of {polygon: PackedVector2Array, row: int, col: int, name: String}.
## heading_deg is a compass bearing (0..180) for the direction rows run along;
## plot_w is measured along it, plot_d across it.
static func subdivide(zone: PackedVector2Array, heading_deg: float, plot_w: float,
		plot_d: float, lane_w: float) -> Array:
	var out: Array = []
	if zone.size() < 3:
		return out
	plot_w = maxf(plot_w, 4.0)
	plot_d = maxf(plot_d, 4.0)
	lane_w = maxf(lane_w, 0.0)
	var phi := CampLayoutGenerator.heading_to_angle(heading_deg)
	var u := Vector2(cos(phi), sin(phi))
	var v := Vector2(-u.y, u.x)
	var u_min := INF
	var u_max := -INF
	var v_min := INF
	var v_max := -INF
	for p in zone:
		u_min = minf(u_min, p.dot(u))
		u_max = maxf(u_max, p.dot(u))
		v_min = minf(v_min, p.dot(v))
		v_max = maxf(v_max, p.dot(v))

	var v_starts := _starts(v_max - v_min, plot_d, lane_w, ROWS_PER_BLOCK)
	var u_starts := _starts(u_max - u_min, plot_w, lane_w, PLOTS_PER_RUN)
	var min_area := plot_w * plot_d * MIN_PLOT_FRACTION
	for r in v_starts.size():
		var col := 0
		for c in u_starts.size():
			var a0 := u_min + float(u_starts[c])
			var c0 := v_min + float(v_starts[r])
			var cell := PackedVector2Array([
				u * a0 + v * c0, u * (a0 + plot_w) + v * c0,
				u * (a0 + plot_w) + v * (c0 + plot_d), u * a0 + v * (c0 + plot_d)])
			for piece: PackedVector2Array in Geometry2D.intersect_polygons(cell, zone):
				if Geometry2D.is_polygon_clockwise(piece):
					continue
				if CampAreaLayer.polygon_area(piece) < min_area:
					continue
				col += 1
				out.append({"polygon": piece, "row": r, "col": col,
					"name": "%s%d" % [row_letters(r), col]})
				if out.size() >= MAX_PLOTS:
					return out
	return out


## Offsets of each strip along one axis: strips of `size`, a lane after every
## `per_block` strips, the whole pattern centred in `span` so the leftover
## margin is shared between both ends.
static func _starts(span: float, size: float, lane: float, per_block: int) -> Array:
	var starts: Array = []
	var at := 0.0
	var n := 0
	while at + size <= span + 0.001:
		starts.append(at)
		n += 1
		at += size
		if n % per_block == 0:
			at += lane
	if starts.is_empty():
		return [maxf((span - size) * 0.5, 0.0)] if span >= size * MIN_PLOT_FRACTION else []
	var used := float(starts[starts.size() - 1]) + size
	var pad := maxf((span - used) * 0.5, 0.0)
	for i in starts.size():
		starts[i] = float(starts[i]) + pad
	return starts


## 0 -> A, 25 -> Z, 26 -> AA.
static func row_letters(row: int) -> String:
	var s := ""
	var n := row
	while true:
		s = char(65 + n % 26) + s
		n = n / 26 - 1
		if n < 0:
			break
	return s
