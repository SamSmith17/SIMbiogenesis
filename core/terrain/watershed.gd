class_name Watershed
extends RefCounted

## D8 steepest-descent hydrology on a regular height grid (row-major).
## Pure / offline — no scene dependencies.


## Packed result of analyze(): flow_dir, accumulation, basin_id arrays + meta.
class Analysis:
	extends RefCounted
	var res: int = 0
	var extent_m: float = 0.0
	## World XZ centre of the grid (0,0 = SoI-centred full analysis).
	var origin_xz: Vector2 = Vector2.ZERO
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
		path.append(cell_to_world(analysis, cur_c, cur_r))
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
	var lx := x - analysis.origin_xz.x
	var lz := z - analysis.origin_xz.y
	return TerrainSculpt.world_to_cell(lx, lz, analysis.res, analysis.extent_m)


static func cell_to_world(analysis: Analysis, c: int, r: int) -> Vector2:
	if analysis == null or analysis.res <= 0:
		return Vector2.ZERO
	var local := TerrainSculpt.cell_to_world(c, r, analysis.res, analysis.extent_m)
	return local + analysis.origin_xz


## Cells whose downhill path reaches the pour cell (inclusive). Reverse BFS on flow_dir.
static func upstream_cells(analysis: Analysis, pour_c: int, pour_r: int) -> PackedInt32Array:
	if analysis == null or analysis.res <= 0:
		return PackedInt32Array()
	var res: int = analysis.res
	if pour_c < 0 or pour_r < 0 or pour_c >= res or pour_r >= res:
		return PackedInt32Array()
	var seeds := PackedInt32Array()
	seeds.append(pour_r * res + pour_c)
	return upstream_cells_multi(analysis, seeds)


## Union of cells that drain into any seed cell (inclusive). Use for pond
## footprints: every DEM cell inside the water body is a pour sink.
static func upstream_cells_multi(analysis: Analysis, seed_indices: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	if analysis == null or analysis.res <= 0 or seed_indices.is_empty():
		return out
	var res: int = analysis.res
	var n: int = res * res
	var parents: Array = []
	parents.resize(n)
	for i in n:
		parents[i] = []
	for i in n:
		var k: int = analysis.flow_dir[i]
		if k < 0:
			continue
		var r0: int = i / res
		var c0: int = i % res
		var rr: int = r0 + _D8_DR[k]
		var cc: int = c0 + _D8_DC[k]
		if rr < 0 or rr >= res or cc < 0 or cc >= res:
			continue
		var dest: int = rr * res + cc
		(parents[dest] as Array).append(i)
	var stack: Array = []
	var seen: Dictionary = {}
	for s_v in seed_indices:
		var s: int = int(s_v)
		if s < 0 or s >= n:
			continue
		if not seen.has(s):
			stack.append(s)
	while not stack.is_empty():
		var cur: int = int(stack.pop_back())
		if seen.has(cur):
			continue
		seen[cur] = true
		out.append(cur)
		for p_v in parents[cur] as Array:
			var p: int = int(p_v)
			if not seen.has(p):
				stack.append(p)
	return out

## Outer polygon (world XZ) for an upstream cell set — cell-boundary merge.
static func upstream_polygon_world(analysis: Analysis, cells: PackedInt32Array) -> PackedVector2Array:
	if analysis == null or analysis.res <= 0 or cells.is_empty():
		return PackedVector2Array()
	var res: int = analysis.res
	var n: int = res * res
	var mask := PackedByteArray()
	mask.resize(n)
	for idx_v in cells:
		var idx: int = int(idx_v)
		if idx >= 0 and idx < n:
			mask[idx] = 1
	var cell_m: float = analysis.extent_m / float(maxi(res - 1, 1))
	# Mask origin = NW corner of cell (0,0) in world XZ.
	var c0w := cell_to_world(analysis, 0, 0)
	var origin := Vector2(c0w.x - cell_m * 0.5, c0w.y - cell_m * 0.5)
	var poly := _mask_to_polygon(mask, res, res, origin, cell_m)
	return poly


## Sample `height_at(x,z)->float` into a local square window and run D8.
static func analyze_local(height_at: Callable, center_xz: Vector2,
		half_extent_m: float, res: int = 128) -> Analysis:
	var out := Analysis.new()
	var r: int = clampi(res, 16, 256)
	var half := maxf(half_extent_m, 8.0)
	var extent := half * 2.0
	out.res = r
	out.extent_m = extent
	out.origin_xz = center_xz
	out.cell_area_m2 = (extent / float(r - 1)) * (extent / float(r - 1))
	if height_at == null:
		return out
	var heights := PackedFloat32Array()
	heights.resize(r * r)
	for row in r:
		for col in r:
			var w := cell_to_world(out, col, row)
			heights[row * r + col] = float(height_at.call(w.x, w.y))
	var full := analyze(heights, r, extent)
	full.origin_xz = center_xz
	return full


## Gravity-fill closed depressions inside a selection polygon.
##
## Samples `height_at(x, z) -> float` (world Y) on a local grid, runs a
## priority-flood that can spill across the selection boundary, then returns
## one water body per flooded pit: `{points: PackedVector2Array, level_m: float,
## area_m2: float, depth_m: float}`.
##
## `fill_frac` 0..1 = how full each depression is (0 ≈ puddle at the bottom,
## 1 = filled to the spill elevation — the natural pour point).
static func fill_depressions_in_polygon(poly: PackedVector2Array, height_at: Callable,
		fill_frac: float = 0.85, cell_m: float = 2.0,
		min_depth_m: float = 0.10, min_area_m2: float = 80.0) -> Array:
	var out: Array = []
	if poly.size() < 3 or height_at == null:
		return out
	var aabb := _poly_aabb(poly)
	if aabb.size.x < cell_m or aabb.size.y < cell_m:
		return out
	# Pad one cell so boundary seeds have neighbours.
	var pad := cell_m
	var origin := Vector2(aabb.position.x - pad, aabb.position.y - pad)
	var span := aabb.size + Vector2(pad * 2.0, pad * 2.0)
	var cols := clampi(int(ceil(span.x / cell_m)) + 1, 4, 180)
	var rows := clampi(int(ceil(span.y / cell_m)) + 1, 4, 180)
	var n := cols * rows
	var dem := PackedFloat32Array()
	var inside := PackedByteArray()
	dem.resize(n)
	inside.resize(n)
	for r in rows:
		for c in cols:
			var idx := r * cols + c
			var x := origin.x + (float(c) + 0.5) * cell_m
			var z := origin.y + (float(r) + 0.5) * cell_m
			var inn: bool = Geometry2D.is_point_in_polygon(Vector2(x, z), poly)
			inside[idx] = 1 if inn else 0
			dem[idx] = float(height_at.call(x, z)) if inn else 0.0
	var filled: PackedFloat32Array = dem.duplicate()
	var resolved := PackedByteArray()
	resolved.resize(n)
	# Priority-flood (lowest outlet first). Selection-boundary cells can spill
	# out of the polygon, so they seed the open list at their DEM height.
	var open: Array = []
	for r in rows:
		for c in cols:
			var idx := r * cols + c
			if inside[idx] == 0:
				continue
			if _touches_outside(inside, cols, rows, c, r):
				resolved[idx] = 1
				filled[idx] = dem[idx]
				open.append({"h": dem[idx], "i": idx})
	if open.is_empty():
		return out
	while not open.is_empty():
		# Pop lowest (linear scan — fine for local selection grids).
		var best_i := 0
		var best_h := float((open[0] as Dictionary)["h"])
		for oi in range(1, open.size()):
			var oh := float((open[oi] as Dictionary)["h"])
			if oh < best_h:
				best_h = oh
				best_i = oi
		var cur: Dictionary = open[best_i]
		open.remove_at(best_i)
		var i: int = int(cur["i"])
		var h: float = float(cur["h"])
		if h > filled[i] + 1e-4:
			continue  # stale
		var cr := i / cols
		var cc := i % cols
		for k in 8:
			var rr: int = cr + _D8_DR[k]
			var cc2: int = cc + _D8_DC[k]
			if rr < 0 or rr >= rows or cc2 < 0 or cc2 >= cols:
				continue
			var j := rr * cols + cc2
			if inside[j] == 0:
				continue
			var fh := maxf(dem[j], h)
			if resolved[j] == 0 or fh < filled[j] - 1e-4:
				resolved[j] = 1
				filled[j] = fh
				open.append({"h": fh, "i": j})
	# Flooded cells = needed water to drain to the selection edge.
	var flooded := PackedByteArray()
	flooded.resize(n)
	for i in n:
		flooded[i] = 1 if (inside[i] != 0 and (filled[i] - dem[i]) >= min_depth_m) else 0
	var components: Array = _connected_components(flooded, cols, rows)
	var frac := clampf(fill_frac, 0.05, 0.98)
	for comp_v in components:
		if not (comp_v is Array):
			continue
		var cells: Array = comp_v as Array
		if cells.is_empty():
			continue
		var pit := INF
		var spill := -INF
		for idx_v in cells:
			var idx: int = int(idx_v)
			pit = minf(pit, dem[idx])
			spill = maxf(spill, filled[idx])
		if not is_finite(pit) or not is_finite(spill) or spill - pit < min_depth_m:
			continue
		var level := lerpf(pit, spill, frac)
		# Water footprint = cells in this depression below the waterline.
		var mask := PackedByteArray()
		mask.resize(n)
		var wet := 0
		for idx_v2 in cells:
			var idx2: int = int(idx_v2)
			if dem[idx2] < level - 0.02:
				mask[idx2] = 1
				wet += 1
		var area := float(wet) * cell_m * cell_m
		if area < min_area_m2:
			continue
		var water_poly: PackedVector2Array = _mask_to_polygon(mask, cols, rows, origin, cell_m)
		if water_poly.size() < 3:
			continue
		if BuildingBuilder.footprint_area_m2(water_poly) < min_area_m2:
			continue
		out.append({
			"points": water_poly,
			"level_m": level,
			"area_m2": area,
			"depth_m": level - pit,
			"spill_m": spill,
			"pit_m": pit,
		})
	return out


## Diagnose the primary closed basin under a selection without creating water.
## Returns `{valid, reason, floor_m, spill_m, area_m2, depth_m, points, level_m}`
## where `reason` is empty on success, else `too_small` / `no_closed_basin` /
## `too_shallow` / `open_edge`.
static func analyze_primary_basin(poly: PackedVector2Array, height_at: Callable,
		cell_m: float = 1.25, min_depth_m: float = 0.10,
		min_area_m2: float = 80.0) -> Dictionary:
	var empty := {
		"valid": false, "reason": "no_closed_basin",
		"floor_m": 0.0, "spill_m": 0.0, "area_m2": 0.0, "depth_m": 0.0,
		"points": PackedVector2Array(), "level_m": 0.0,
	}
	if poly.size() < 3 or height_at == null:
		empty["reason"] = "too_small"
		return empty
	var sel_area := BuildingBuilder.footprint_area_m2(poly)
	if sel_area < min_area_m2:
		empty["reason"] = "too_small"
		empty["area_m2"] = sel_area
		return empty
	# Prefer a near-full flood footprint for geometry; level is set by caller.
	var bodies: Array = fill_depressions_in_polygon(
		poly, height_at, 0.98, cell_m, min_depth_m, min_area_m2)
	if not bodies.is_empty():
		var best: Dictionary = bodies[0]
		var best_a := float(best.get("area_m2", 0.0))
		for i in range(1, bodies.size()):
			var b: Dictionary = bodies[i]
			var a := float(b.get("area_m2", 0.0))
			if a > best_a:
				best = b
				best_a = a
		var floor_m := float(best.get("pit_m", 0.0))
		var spill_m := float(best.get("spill_m", floor_m))
		return {
			"valid": true, "reason": "",
			"floor_m": floor_m, "spill_m": spill_m,
			"area_m2": best_a,
			"depth_m": spill_m - floor_m,
			"points": best.get("points", PackedVector2Array()),
			"level_m": float(best.get("level_m", spill_m)),
		}
	# Soften thresholds to classify shallow vs truly open.
	var shallow: Array = fill_depressions_in_polygon(
		poly, height_at, 0.98, cell_m, 0.01, 1.0)
	if not shallow.is_empty():
		var s: Dictionary = shallow[0]
		var depth := float(s.get("spill_m", 0.0)) - float(s.get("pit_m", 0.0))
		empty["floor_m"] = float(s.get("pit_m", 0.0))
		empty["spill_m"] = float(s.get("spill_m", 0.0))
		empty["depth_m"] = depth
		empty["area_m2"] = float(s.get("area_m2", 0.0))
		empty["points"] = s.get("points", PackedVector2Array())
		if depth > 0.0 and depth < min_depth_m:
			empty["reason"] = "too_shallow"
		elif float(s.get("area_m2", 0.0)) < min_area_m2:
			empty["reason"] = "too_small"
		else:
			empty["reason"] = "open_edge"
		return empty
	return empty


static func _poly_aabb(poly: PackedVector2Array) -> Rect2:
	var min_v := poly[0]
	var max_v := poly[0]
	for p in poly:
		min_v.x = minf(min_v.x, p.x)
		min_v.y = minf(min_v.y, p.y)
		max_v.x = maxf(max_v.x, p.x)
		max_v.y = maxf(max_v.y, p.y)
	return Rect2(min_v, max_v - min_v)


static func _touches_outside(inside: PackedByteArray, cols: int, rows: int,
		c: int, r: int) -> bool:
	for k in 8:
		var rr: int = r + _D8_DR[k]
		var cc: int = c + _D8_DC[k]
		if rr < 0 or rr >= rows or cc < 0 or cc >= cols:
			return true
		if inside[rr * cols + cc] == 0:
			return true
	return false


static func _connected_components(mask: PackedByteArray, cols: int, rows: int) -> Array:
	var n := cols * rows
	var seen := PackedByteArray()
	seen.resize(n)
	var comps: Array = []
	var stack: Array[int] = []
	for i in n:
		if mask[i] == 0 or seen[i] != 0:
			continue
		var cells: Array = []
		stack.clear()
		stack.append(i)
		seen[i] = 1
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			cells.append(cur)
			var cr := cur / cols
			var cc := cur % cols
			# 4-connected for cleaner footprints.
			for k in 4:
				var d4c: int = 0
				var d4r: int = 0
				match k:
					0:
						d4r = -1
					1:
						d4c = 1
					2:
						d4r = 1
					_:
						d4c = -1
				var rr: int = cr + d4r
				var cc2: int = cc + d4c
				if rr < 0 or rr >= rows or cc2 < 0 or cc2 >= cols:
					continue
				var j := rr * cols + cc2
				if mask[j] == 0 or seen[j] != 0:
					continue
				seen[j] = 1
				stack.append(j)
		comps.append(cells)
	return comps


## Outline a binary mask as a single polygon (outer ring). Cell squares are
## merged via boundary-edge chaining — good enough for pond footprints.
static func _mask_to_polygon(mask: PackedByteArray, cols: int, rows: int,
		origin: Vector2, cell_m: float) -> PackedVector2Array:
	# Emit axis-aligned boundary segments, then walk the longest loop.
	var edges: Dictionary = {}  # "x1,y1>x2,y2" → true (directed)
	for r in rows:
		for c in cols:
			if mask[r * cols + c] == 0:
				continue
			var x0 := origin.x + float(c) * cell_m
			var z0 := origin.y + float(r) * cell_m
			var x1 := x0 + cell_m
			var z1 := z0 + cell_m
			# N, E, S, W — add edge if neighbour empty (CCW around cell).
			if r == 0 or mask[(r - 1) * cols + c] == 0:
				_edge_add(edges, Vector2(x0, z0), Vector2(x1, z0))
			if c == cols - 1 or mask[r * cols + c + 1] == 0:
				_edge_add(edges, Vector2(x1, z0), Vector2(x1, z1))
			if r == rows - 1 or mask[(r + 1) * cols + c] == 0:
				_edge_add(edges, Vector2(x1, z1), Vector2(x0, z1))
			if c == 0 or mask[r * cols + c - 1] == 0:
				_edge_add(edges, Vector2(x0, z1), Vector2(x0, z0))
	if edges.is_empty():
		return PackedVector2Array()
	# Build adjacency keyed by string so float Vector2 dict keys stay stable.
	var adj: Dictionary = {}
	for key_v in edges:
		var parts: PackedStringArray = str(key_v).split(">")
		if parts.size() != 2:
			continue
		var a_key: String = str(parts[0])
		var b_key: String = str(parts[1])
		if not adj.has(a_key):
			adj[a_key] = []
		(adj[a_key] as Array).append(b_key)
	var best := PackedVector2Array()
	var used: Dictionary = {}
	for start_key_v in adj:
		var start_key: String = str(start_key_v)
		var ring := PackedVector2Array()
		var cur_key: String = start_key
		var guard := 0
		while guard < edges.size() + 4:
			guard += 1
			ring.append(_parse_vz(cur_key))
			var nexts: Array = adj.get(cur_key, []) as Array
			var nxt_key: String = ""
			for cand_v in nexts:
				var cand_key: String = str(cand_v)
				var ek: String = "%s>%s" % [cur_key, cand_key]
				if used.has(ek):
					continue
				nxt_key = cand_key
				used[ek] = true
				break
			if nxt_key.is_empty():
				break
			cur_key = nxt_key
			if cur_key == start_key:
				ring.append(_parse_vz(start_key))
				break
		if ring.size() >= 4 and ring.size() > best.size():
			best = ring
	if best.size() >= 4 and best[0].distance_squared_to(best[best.size() - 1]) < 1e-6:
		best.remove_at(best.size() - 1)
	return _decimate_colinear(best, cell_m * 0.25)


static func _edge_add(edges: Dictionary, a: Vector2, b: Vector2) -> void:
	var k := _edge_key(a, b)
	var rk := _edge_key(b, a)
	# Cancel opposite edges (internal).
	if edges.has(rk):
		edges.erase(rk)
		return
	edges[k] = true


static func _edge_key(a: Vector2, b: Vector2) -> String:
	return "%.3f,%.3f>%.3f,%.3f" % [a.x, a.y, b.x, b.y]


static func _parse_vz(s: String) -> Vector2:
	var parts := s.split(",")
	if parts.size() < 2:
		return Vector2.ZERO
	return Vector2(float(parts[0]), float(parts[1]))


static func _decimate_colinear(poly: PackedVector2Array, eps: float) -> PackedVector2Array:
	if poly.size() < 4:
		return poly
	var out := PackedVector2Array()
	var n := poly.size()
	for i in n:
		var prev: Vector2 = poly[(i - 1 + n) % n]
		var cur: Vector2 = poly[i]
		var next: Vector2 = poly[(i + 1) % n]
		var e1 := (cur - prev).normalized()
		var e2 := (next - cur).normalized()
		var cross_z := e1.x * e2.y - e1.y * e2.x
		if e1.dot(e2) > 0.999 and absf(cross_z) < 0.02:
			continue
		out.append(cur)
	return out if out.size() >= 3 else poly


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


## Continuous-space steepest-descent walk from a world XZ point — "which way
## would water actually flow from here", used to route a culvert outlet to a
## real downhill point instead of an arbitrary straight chord. Re-samples the
## local gradient (8 compass directions, reusing the D8 offsets) at EVERY step
## so the path bends to follow the real terrain contour rather than committing
## to one initial direction. Stops at whichever comes first: `target_drop_m`
## total descent reached, `max_steps` used up, or a local minimum (no downhill
## neighbor at all — the natural low point / daylight spot, even short of the
## target drop — a real terrain feature, not a bug).
## Returns `{points: PackedVector2Array (world XZ, len ≥ 1, first = start),
## final_elev, total_drop_m, reached_target: bool}`.
static func trace_downhill(start_xz: Vector2, height_at: Callable,
		target_drop_m: float = 9.0, step_m: float = 4.0, max_steps: int = 60) -> Dictionary:
	var pts := PackedVector2Array([start_xz])
	var cur := start_xz
	var cur_h := float(height_at.call(cur.x, cur.y))
	var start_h := cur_h
	var reached := false
	for _i in max_steps:
		if start_h - cur_h >= target_drop_m:
			reached = true
			break
		var best_dir := Vector2.ZERO
		var best_h := cur_h
		for k in 8:
			var dir := Vector2(float(_D8_DC[k]), float(_D8_DR[k])).normalized()
			var cand := cur + dir * step_m
			var h := float(height_at.call(cand.x, cand.y))
			if h < best_h:
				best_h = h
				best_dir = dir
		if best_dir == Vector2.ZERO:
			break
		cur += best_dir * step_m
		cur_h = best_h
		pts.append(cur)
	return {
		"points": pts,
		"final_elev": cur_h,
		"total_drop_m": start_h - cur_h,
		"reached_target": reached,
	}
