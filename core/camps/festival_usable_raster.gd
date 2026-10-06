class_name FestivalUsableRaster
extends RefCounted

## The USABLE ground of one placement zone, rasterised: which 2 m cells are
## inside the outline, which of those are flat enough and clear of buildings,
## roads and water, and how steep each one is.
##
## It exists because "equal area" on a hillside is a lie — a lot that is half
## cliff is not the same lot as a flat one. The partition and every readout
## measure USABLE square metres off this raster, so fairness is about ground a
## camp can actually pitch on. Built synchronously (a zone is capped at
## 90 000 m² by the gesture controller, ≈22 500 cells at 2 m, each one height
## sample and one exclusion query — tens of milliseconds) and cached by the
## caller on the zone.
##
## Pure: the height and exclusion sources arrive as Callables in `ctx`, so the
## selftest drives it with a synthetic bank.

const DEFAULT_CELL_M := 2.0
## Never allocate more than this many cells; coarser cells cover a huge zone.
const MAX_CELLS := 60000

## Cell mask values.
const OUTSIDE := 0
const UNUSABLE := 1
const USABLE := 2

var origin := Vector2.ZERO
var cell := DEFAULT_CELL_M
var nx := 0
var nz := 0
var mask := PackedByteArray()
var slope_deg := PackedFloat32Array()
var inside_cells := 0
var usable_cells := 0
var slope_limit_deg := 10.0


## Cell size that keeps the raster fine for small tent lots and bounded for
## big zones: 1 m under ~22 500 m², 2 m by 90 000 m².
static func adaptive_cell(area_m2: float) -> float:
	return clampf(sqrt(maxf(area_m2, 1.0)) / 150.0, 1.0, DEFAULT_CELL_M)


## ctx: {ground_y_at: Callable(x, z) -> float, is_excluded: Callable(Vector2) -> bool}.
## `locked` are polygons that are off limits whatever the ground (lots already
## promised to a camp). `equalise_raw` ignores slope and exclusions entirely.
static func build(poly: PackedVector2Array, holes: Array, locked: Array,
		ctx: Dictionary, limit_deg: float, equalise_raw: bool,
		cell_m: float = 0.0) -> FestivalUsableRaster:
	var r := FestivalUsableRaster.new()
	r.slope_limit_deg = limit_deg
	if poly.size() < 3:
		return r
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var area := CampAreaLayer.polygon_area(poly)
	var c := cell_m if cell_m > 0.0 else adaptive_cell(area)
	# Keep the allocation bounded whatever the outline.
	while ((hi.x - lo.x) / c + 2.0) * ((hi.y - lo.y) / c + 2.0) > float(MAX_CELLS):
		c *= 1.5
	r.cell = c
	r.origin = Vector2(floor(lo.x / c) * c, floor(lo.y / c) * c)
	r.nx = int(ceil((hi.x - r.origin.x) / c)) + 1
	r.nz = int(ceil((hi.y - r.origin.y) / c)) + 1
	var n := r.nx * r.nz
	r.mask.resize(n)
	r.slope_deg.resize(n)
	var ground: Callable = ctx.get("ground_y_at", Callable())
	var excl: Callable = ctx.get("is_excluded", Callable())
	# Heights at the grid NODES (one more than cells on each axis), so a cell's
	# slope is a central difference over its own four corners.
	var hn := PackedFloat32Array()
	var hw := r.nx + 1
	hn.resize(hw * (r.nz + 1))
	for j in r.nz + 1:
		for i in r.nx + 1:
			var x := r.origin.x + float(i) * c
			var z := r.origin.y + float(j) * c
			hn[j * hw + i] = float(ground.call(x, z)) if ground.is_valid() else 0.0
	for j in r.nz:
		for i in r.nx:
			var k := j * r.nx + i
			var centre := r.origin + Vector2((float(i) + 0.5) * c, (float(j) + 0.5) * c)
			var h00 := hn[j * hw + i]
			var h10 := hn[j * hw + i + 1]
			var h01 := hn[(j + 1) * hw + i]
			var h11 := hn[(j + 1) * hw + i + 1]
			var gx := ((h10 + h11) - (h00 + h01)) / (2.0 * c)
			var gz := ((h01 + h11) - (h00 + h10)) / (2.0 * c)
			r.slope_deg[k] = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
			if not Geometry2D.is_point_in_polygon(centre, poly):
				r.mask[k] = OUTSIDE
				continue
			var blocked := false
			for h in holes:
				if h is PackedVector2Array and (h as PackedVector2Array).size() >= 3 \
						and Geometry2D.is_point_in_polygon(centre, h):
					blocked = true
					break
			if not blocked:
				for lp in locked:
					if lp is PackedVector2Array and (lp as PackedVector2Array).size() >= 3 \
							and Geometry2D.is_point_in_polygon(centre, lp):
						blocked = true
						break
			if blocked:
				r.mask[k] = OUTSIDE
				continue
			r.inside_cells += 1
			var usable := true
			if not equalise_raw:
				if r.slope_deg[k] > limit_deg:
					usable = false
				elif excl.is_valid() and bool(excl.call(centre)):
					usable = false
			r.mask[k] = USABLE if usable else UNUSABLE
			if usable:
				r.usable_cells += 1
	return r


func cell_area() -> float:
	return cell * cell


func raw_m2() -> float:
	return float(inside_cells) * cell_area()


func usable_m2() -> float:
	return float(usable_cells) * cell_area()


func index(i: int, j: int) -> int:
	return j * nx + i


func cell_center(i: int, j: int) -> Vector2:
	return origin + Vector2((float(i) + 0.5) * cell, (float(j) + 0.5) * cell)


## Mask value of the cell under a world point (OUTSIDE off the raster).
func mask_at(p: Vector2) -> int:
	var i := int(floor((p.x - origin.x) / cell))
	var j := int(floor((p.y - origin.y) / cell))
	if i < 0 or j < 0 or i >= nx or j >= nz:
		return OUTSIDE
	return mask[index(i, j)]


## {raw_m2, usable_m2, mean_slope_deg, max_slope_deg, cells} of the cells
## whose centres fall inside `poly` (bounding-box limited, so a lot costs its
## own few hundred cells, never the whole zone).
func measure(poly: PackedVector2Array) -> Dictionary:
	var out := {"raw_m2": 0.0, "usable_m2": 0.0, "mean_slope_deg": 0.0,
		"max_slope_deg": 0.0, "cells": 0}
	if poly.size() < 3 or nx == 0:
		return out
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var i0 := clampi(int(floor((lo.x - origin.x) / cell)), 0, nx - 1)
	var i1 := clampi(int(floor((hi.x - origin.x) / cell)), 0, nx - 1)
	var j0 := clampi(int(floor((lo.y - origin.y) / cell)), 0, nz - 1)
	var j1 := clampi(int(floor((hi.y - origin.y) / cell)), 0, nz - 1)
	var raw := 0
	var usable := 0
	var slope_sum := 0.0
	var slope_max := 0.0
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var k := index(i, j)
			if mask[k] == OUTSIDE:
				continue
			if not Geometry2D.is_point_in_polygon(cell_center(i, j), poly):
				continue
			raw += 1
			slope_sum += slope_deg[k]
			slope_max = maxf(slope_max, slope_deg[k])
			if mask[k] == USABLE:
				usable += 1
	out["cells"] = raw
	out["raw_m2"] = float(raw) * cell_area()
	out["usable_m2"] = float(usable) * cell_area()
	out["mean_slope_deg"] = slope_sum / float(raw) if raw > 0 else 0.0
	out["max_slope_deg"] = slope_max
	return out
