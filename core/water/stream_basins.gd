class_name StreamBasins
extends RefCounted

## Hollows a stream runs into — swales, ponds, a pit dug across its path —
## that must FILL before the water goes on. Pure.
##
## Along a channel's stations, the ground water actually runs over (the edited
## surface at the centreline) is filled from the outlet upward the way
## Priority-Flood fills a grid, in 1-D: level[i] = max(ground[i], level[i+1]).
## Wherever level stands more than MIN_DEPTH_M over the ground, the water has to
## rise to `level` (the rim it spills over) before anything passes: a basin.
## Its real extent is then flood-filled on the ground around it below the spill
## height (find the cells, their depths, the volume, a stage curve), because a
## swale is two-dimensional — the channel only crosses it.
##
## The water in a basin is a running balance, inflow − infiltration, clamped
## at empty and at full (fill-and-spill: once full, what comes in goes out).
## Infiltration is a steady rate over the wetted area: INFIL_MMH is in the
## range of a sandy loam's final infiltration rate (Rawls, Brakensiek & Miller
## 1983: ~10 mm/h; a desert crust is lower) — what a swale is FOR.

const MIN_DEPTH_M := 0.15
const CELL_M := 1.5
const MAX_HALF_M := 160.0
const MAX_CELLS := 50000
const STAGE_LEVELS := 16
const INFIL_MMH := 8.0


## Depressions along a channel: [{i0, i1, i_low, spill_y, floor_y}] (station
## indices, inclusive). `carved[i]` = 1 where the station is in the carved
## (hi-res) region; hollows elsewhere are DEM noise, not anything built.
static func find_pits(ground: PackedFloat32Array, carved: PackedByteArray,
		min_depth: float = MIN_DEPTH_M) -> Array:
	var n := ground.size()
	var out: Array = []
	if n < 3:
		return out
	var level := PackedFloat32Array()
	level.resize(n)
	level[n - 1] = ground[n - 1]
	for i in range(n - 2, -1, -1):
		level[i] = maxf(ground[i], level[i + 1])
	var i := 0
	while i < n:
		var deep := level[i] - ground[i] > min_depth and (i < carved.size() and carved[i] == 1)
		if not deep:
			i += 1
			continue
		var i0 := i
		var low := i
		while i < n and level[i] - ground[i] > 0.02 and (i < carved.size() and carved[i] == 1):
			if ground[i] < ground[low]:
				low = i
			i += 1
		# Back up over the shallow lip at the inlet too.
		while i0 > 0 and level[i0 - 1] - ground[i0 - 1] > 0.02:
			i0 -= 1
		out.append({"i0": i0, "i1": i - 1, "i_low": low, "spill_y": level[low],
			"floor_y": ground[low]})
	return out


## The basin's real extent: every cell (CELL_M) connected to `seed` whose
## ground is below `spill_y`, within MAX_HALF_M. Returns {cells
## (PackedVector2Array centres), z (PackedFloat32Array), cell, spill_y, floor_y,
## volume_m3, area_m2, stage (PackedVector3Array: level, volume, area), open}.
## `open` = the hollow is not closed below spill_y within reach (it leaks out
## sideways somewhere lower than the channel's rim): not a basin.
## `dams` = segments [Vector2 a, Vector2 b] the fill may not cross: the
## channel itself leaves the hollow at the spill station and keeps falling
## below the spill height, so without a dam across it there the fill runs on
## down the channel and every hollow reads as open.
static func flood(seed: Vector2, spill_y: float, ground_fn: Callable,
		cell: float = CELL_M, max_half: float = MAX_HALF_M, dams: Array = []) -> Dictionary:
	var side := int(ceil(2.0 * max_half / cell)) + 1
	var half_idx := side / 2
	var seen := PackedByteArray()
	seen.resize(side * side)
	var cells := PackedVector2Array()
	var zs := PackedFloat32Array()
	var queue := PackedInt32Array([half_idx * side + half_idx])
	seen[half_idx * side + half_idx] = 1
	var head := 0
	var floor_y := INF
	var open := false
	while head < queue.size():
		if cells.size() >= MAX_CELLS:
			open = true
			break
		var idx := queue[head]
		head += 1
		var gx := idx % side
		var gz := idx / side
		var p := seed + Vector2(float(gx - half_idx), float(gz - half_idx)) * cell
		if _on_dam(p, dams, cell * 0.75):
			continue
		var z := float(ground_fn.call(p.x, p.y))
		if not (z < spill_y):
			continue
		cells.append(p)
		zs.append(z)
		floor_y = minf(floor_y, z)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = gx + (d as Vector2i).x
			var nz: int = gz + (d as Vector2i).y
			if nx < 0 or nz < 0 or nx >= side or nz >= side:
				open = true
				continue
			var ni := nz * side + nx
			if seen[ni] == 0:
				seen[ni] = 1
				queue.append(ni)
	var stage := PackedVector3Array()
	var a_cell := cell * cell
	if cells.is_empty():
		return {"cells": cells, "z": zs, "cell": cell, "spill_y": spill_y, "floor_y": spill_y,
			"volume_m3": 0.0, "area_m2": 0.0, "stage": stage, "open": open}
	for k in STAGE_LEVELS + 1:
		var lv := lerpf(floor_y, spill_y, float(k) / float(STAGE_LEVELS))
		var vol := 0.0
		var area := 0.0
		for z2 in zs:
			if z2 < lv:
				vol += (lv - z2) * a_cell
				area += a_cell
		stage.append(Vector3(lv, vol, area))
	return {"cells": cells, "z": zs, "cell": cell, "spill_y": spill_y, "floor_y": floor_y,
		"volume_m3": stage[STAGE_LEVELS].y, "area_m2": stage[STAGE_LEVELS].z, "stage": stage,
		"open": open}


static func _on_dam(p: Vector2, dams: Array, tol: float) -> bool:
	for d in dams:
		var seg: Array = d
		var q := Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1])
		if q.distance_to(p) <= tol:
			return true
	return false


## Water level for a stored volume (linear between stage rows).
static func level_for_volume(stage: PackedVector3Array, v: float) -> float:
	if stage.is_empty():
		return 0.0
	if v <= 0.0:
		return stage[0].x
	for k in range(1, stage.size()):
		if v <= stage[k].y:
			var a := stage[k - 1]
			var b := stage[k]
			var t := (v - a.y) / maxf(b.y - a.y, 1e-9)
			return lerpf(a.x, b.x, clampf(t, 0.0, 1.0))
	return stage[stage.size() - 1].x


## Wetted area (m²) at a stored volume.
static func area_for_volume(stage: PackedVector3Array, v: float) -> float:
	if stage.is_empty() or v <= 0.0:
		return 0.0
	for k in range(1, stage.size()):
		if v <= stage[k].y:
			var a := stage[k - 1]
			var b := stage[k]
			var t := (v - a.y) / maxf(b.y - a.y, 1e-9)
			return lerpf(a.z, b.z, clampf(t, 0.0, 1.0))
	return stage[stage.size() - 1].z


## One step of the basin's balance: volume after `dt_h` hours of `inflow_lps`
## less infiltration over the wetted area, clamped to [0, capacity].
static func step_volume(v: float, inflow_lps: float, dt_h: float, stage: PackedVector3Array,
		capacity_m3: float) -> float:
	var infil := INFIL_MMH / 1000.0 * area_for_volume(stage, v)    # m³/h
	var nv := v + (maxf(inflow_lps, 0.0) * 3.6 - infil) * dt_h
	return clampf(nv, 0.0, capacity_m3)
