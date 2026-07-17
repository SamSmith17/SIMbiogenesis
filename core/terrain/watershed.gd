class_name Watershed
extends RefCounted

## D8 steepest-descent hydrology on a regular height grid (row-major).
## Pure / offline — no scene dependencies.


## Packed result of analyze(): flow_dir, accumulation, basin_id arrays + meta.
class Analysis:
	extends RefCounted
	var res: int = 0
	var extent_m: float = 0.0
	## Per-cell D8 neighbour index 0..7, or -1 for pits / flats that drain nowhere.
	var flow_dir: PackedInt32Array = PackedInt32Array()
	var accumulation: PackedFloat32Array = PackedFloat32Array()
	var basin_id: PackedInt32Array = PackedInt32Array()
	var basin_count: int = 0
	var cell_area_m2: float = 0.0


const _D8_DC: Array[int] = [-1, 0, 1, -1, 1, -1, 0, 1]
const _D8_DR: Array[int] = [-1, -1, -1, 0, 0, 1, 1, 1]
## Distance multipliers: cardinal = 1, diagonal = √2 (in cell units).
const _D8_LEN: Array[float] = [
	1.41421356, 1.0, 1.41421356, 1.0, 1.0, 1.41421356, 1.0, 1.41421356]


static func analyze(heights: PackedFloat32Array, res: int, extent_m: float) -> Analysis:
	var out := Analysis.new()
	out.res = res
	out.extent_m = extent_m
	var n := res * res
	if heights.size() < n or res < 2:
		return out
	var cell_m := extent_m / float(res - 1)
	out.cell_area_m2 = cell_m * cell_m
	out.flow_dir.resize(n)
	out.accumulation.resize(n)
	out.basin_id.resize(n)
	for i in n:
		out.flow_dir[i] = -1
		out.accumulation[i] = 1.0
		out.basin_id[i] = -1
	# Steepest descent (D8).
	for r in res:
		for c in res:
			var idx: int = r * res + c
			var h0: float = heights[idx]
			var best_s: float = 0.0
			var best_k: int = -1
			for k in 8:
				var rr: int = r + _D8_DR[k]
				var cc: int = c + _D8_DC[k]
				if rr < 0 or rr >= res or cc < 0 or cc >= res:
					continue
				var drop: float = h0 - heights[rr * res + cc]
				if drop <= 0.0:
					continue
				var slope: float = drop / (_D8_LEN[k] * cell_m)
				if slope > best_s:
					best_s = slope
					best_k = k
			out.flow_dir[idx] = best_k
	# Topological order by descending height for single-pass accumulation.
	var order := _argsort_desc(heights, n)
	for oi in order.size():
		var idx2: int = order[oi]
		var k: int = out.flow_dir[idx2]
		if k < 0:
			continue
		var r2: int = idx2 / res
		var c2: int = idx2 % res
		var dest: int = (r2 + _D8_DR[k]) * res + (c2 + _D8_DC[k])
		out.accumulation[dest] += out.accumulation[idx2]
	# Basin IDs: walk downhill to a pit; each pit is a unique basin root.
	var next_id: int = 0
	for i in n:
		if out.basin_id[i] >= 0:
			continue
		var path: Array[int] = []
		var cur: int = i
		while out.basin_id[cur] < 0 and out.flow_dir[cur] >= 0:
			path.append(cur)
			var k2: int = out.flow_dir[cur]
			var r3: int = cur / res
			var c3: int = cur % res
			cur = (r3 + _D8_DR[k2]) * res + (c3 + _D8_DC[k2])
			# Cycle guard (shouldn't happen with strict descent).
			if path.size() > n:
				break
		var bid: int
		if out.basin_id[cur] >= 0:
			bid = out.basin_id[cur]
		else:
			# Pit / sink cell.
			bid = next_id
			next_id += 1
			out.basin_id[cur] = bid
		for p in path:
			out.basin_id[p] = bid
	out.basin_count = next_id
	return out


static func basin_at(analysis: Analysis, c: int, r: int) -> int:
	if analysis == null or analysis.res <= 0:
		return -1
	if c < 0 or r < 0 or c >= analysis.res or r >= analysis.res:
		return -1
	return analysis.basin_id[r * analysis.res + c]


static func upstream_area_m2(analysis: Analysis, c: int, r: int) -> float:
	if analysis == null or analysis.res <= 0:
		return 0.0
	if c < 0 or r < 0 or c >= analysis.res or r >= analysis.res:
		return 0.0
	return analysis.accumulation[r * analysis.res + c] * analysis.cell_area_m2


## World XZ → flow path as PackedVector2Array of cell centres (world metres).
static func flow_path(analysis: Analysis, c: int, r: int,
		max_steps: int = 4096) -> PackedVector2Array:
	var path := PackedVector2Array()
	if analysis == null or analysis.res <= 0:
		return path
	if c < 0 or r < 0 or c >= analysis.res or r >= analysis.res:
		return path
	var res: int = analysis.res
	var cur_c: int = c
	var cur_r: int = r
	var seen: Dictionary = {}
	for _i in max_steps:
		var idx: int = cur_r * res + cur_c
		if seen.has(idx):
			break
		seen[idx] = true
		path.append(TerrainSculpt.cell_to_world(cur_c, cur_r, res, analysis.extent_m))
		var k: int = analysis.flow_dir[idx]
		if k < 0:
			break
		cur_c += _D8_DC[k]
		cur_r += _D8_DR[k]
		if cur_c < 0 or cur_r < 0 or cur_c >= res or cur_r >= res:
			break
	return path


static func world_to_cell(analysis: Analysis, x: float, z: float) -> Vector2i:
	if analysis == null or analysis.res <= 0:
		return Vector2i(-1, -1)
	return TerrainSculpt.world_to_cell(x, z, analysis.res, analysis.extent_m)


static func _argsort_desc(heights: PackedFloat32Array, n: int) -> PackedInt32Array:
	var order := PackedInt32Array()
	order.resize(n)
	for i in n:
		order[i] = i
	# Simple descending insertion for small n; Array.sort_custom for larger.
	if n <= 64:
		for i in range(1, n):
			var key: int = order[i]
			var kh: float = heights[key]
			var j: int = i - 1
			while j >= 0 and heights[order[j]] < kh:
				order[j + 1] = order[j]
				j -= 1
			order[j + 1] = key
		return order
	var arr: Array = []
	arr.resize(n)
	for i in n:
		arr[i] = i
	arr.sort_custom(func(a: int, b: int) -> bool:
		return heights[a] > heights[b]
	)
	for i in n:
		order[i] = int(arr[i])
	return order
