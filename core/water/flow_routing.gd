class_name FlowRouting
extends RefCounted

## Where water goes on this site — pure and worker-thread safe.
##
## Over a square grid on the (edited) ground:
##   1. BURN the mapped waterways a few metres in, so the derived network
##      agrees with OSM where OSM knows better than a 5–47 m DEM ("stream
##      burning", Saunders 1999 / the AGREE method, Hellweger 1997).
##   2. Priority-Flood+ε (Barnes, Lehman & Mulla 2014, "Priority-Flood: An
##      optimal depression-filling and watershed-labeling algorithm", Alg. 3):
##      every depression is raised to its spill level PLUS a vanishing ε per
##      cell, so every cell has a strictly lower neighbour and water reaches the
##      map edge. The existing Watershed.analyze skips this, so every DEM dimple
##      was its own sink.
##   3. D8 steepest descent on the filled surface (O'Callaghan & Mark 1984).
##   4. Flow accumulation in the flood's own pop order, reversed (the flood pops
##      cells in ascending filled elevation, so no separate sort is needed).
##   5. Channels: cells draining at least `min_area_m2`, traced from their heads
##      to the junction or outlet, ordered by Strahler (1957), simplified with
##      Ramer–Douglas–Peucker.
##
## The grid is centred on the world origin (the site), cell size `cell_m`.

const MAX_N := 640
const DEFAULT_CELL_M := 5.0
## Burn depth of mapped waterways (m) — deeper than DEM noise, shallower than
## any real ridge, so a mapped stream wins over a phantom DEM path but not over
## genuine terrain.
const BURN_M := 4.0
## ε step of the flood (m). Small against any real relief, large against
## float32 rounding of ~100 m elevations (≈ 8e-6).
const EPS_M := 1e-3

const D8_DC := [1, 1, 0, -1, -1, -1, 0, 1]
const D8_DR := [0, 1, 1, 1, 0, -1, -1, -1]
const D8_LEN := [1.0, 1.41421356, 1.0, 1.41421356, 1.0, 1.41421356, 1.0, 1.41421356]


## Analyse the ground. `surface_fn(x, z)` = the edited surface; `burn_lines` =
## Array of PackedVector2Array (world XZ) to burn in.
## Returns {n, cell_m, half_m, filled, recv, acc (cells), order (pop order)}.
static func analyze(surface_fn: Callable, half_m: float, cell_m: float = DEFAULT_CELL_M,
		burn_lines: Array = []) -> Dictionary:
	var n := clampi(int(ceil(2.0 * half_m / maxf(cell_m, 0.5))) + 1, 3, MAX_N)
	var cell := 2.0 * half_m / float(n - 1)
	var h := PackedFloat32Array()
	h.resize(n * n)
	for r in n:
		var z := -half_m + float(r) * cell
		for c in n:
			h[r * n + c] = float(surface_fn.call(-half_m + float(c) * cell, z))
	_burn(h, n, cell, half_m, burn_lines)
	var fl := priority_flood(h, n)
	var filled: PackedFloat32Array = fl["filled"]
	var order: PackedInt32Array = fl["order"]
	var recv := d8_receivers(filled, n)
	var acc := accumulate(recv, order)
	return {"n": n, "cell_m": cell, "half_m": half_m, "filled": filled,
		"recv": recv, "acc": acc, "order": order}


static func _burn(h: PackedFloat32Array, n: int, cell: float, half_m: float, lines: Array) -> void:
	for l_v in lines:
		if not (l_v is PackedVector2Array):
			continue
		var line: PackedVector2Array = l_v
		var seen := {}
		for i in range(line.size() - 1):
			var a := line[i]
			var b := line[i + 1]
			var steps := maxi(int(ceil(a.distance_to(b) / (cell * 0.5))), 1)
			for k in steps + 1:
				var p := a.lerp(b, float(k) / float(steps))
				var c := int(round((p.x + half_m) / cell))
				var r := int(round((p.y + half_m) / cell))
				if c < 0 or r < 0 or c >= n or r >= n:
					continue
				var idx := r * n + c
				if seen.has(idx):
					continue
				seen[idx] = true
				h[idx] -= BURN_M


## Priority-Flood+ε over a row-major n×n grid; edge cells are the outlets.
## Returns {filled, order} — `order` is the pop order (ascending filled height).
static func priority_flood(h: PackedFloat32Array, n: int) -> Dictionary:
	var filled := h.duplicate()
	var closed := PackedByteArray()
	closed.resize(n * n)
	var heap := _Heap.new()
	for c in n:
		_seed(heap, filled, closed, c, n)
		_seed(heap, filled, closed, (n - 1) * n + c, n)
	for r in range(1, n - 1):
		_seed(heap, filled, closed, r * n, n)
		_seed(heap, filled, closed, r * n + n - 1, n)
	var order := PackedInt32Array()
	order.resize(n * n)
	var oi := 0
	while not heap.is_empty():
		var c := heap.pop()
		order[oi] = c
		oi += 1
		var cr := c / n
		var cc := c - cr * n
		var hc := filled[c]
		for k in 8:
			var rr: int = cr + int(D8_DR[k])
			var c2: int = cc + int(D8_DC[k])
			if rr < 0 or c2 < 0 or rr >= n or c2 >= n:
				continue
			var nb := rr * n + c2
			if closed[nb] == 1:
				continue
			closed[nb] = 1
			if filled[nb] <= hc + EPS_M:
				filled[nb] = hc + EPS_M
			heap.push(nb, filled[nb])
	order.resize(oi)
	return {"filled": filled, "order": order}


static func _seed(heap: _Heap, filled: PackedFloat32Array, closed: PackedByteArray, idx: int, _n: int) -> void:
	if closed[idx] == 1:
		return
	closed[idx] = 1
	heap.push(idx, filled[idx])


## Steepest-descent receiver per cell (−1 = an edge outlet with no lower
## neighbour). On a Priority-Flood+ε surface every interior cell has one.
static func d8_receivers(filled: PackedFloat32Array, n: int) -> PackedInt32Array:
	var recv := PackedInt32Array()
	recv.resize(n * n)
	for r in n:
		for c in n:
			var i := r * n + c
			var best := -1
			var best_s := 0.0
			var hi := filled[i]
			for k in 8:
				var rr: int = r + int(D8_DR[k])
				var cc: int = c + int(D8_DC[k])
				if rr < 0 or cc < 0 or rr >= n or cc >= n:
					continue
				var s := (hi - filled[rr * n + cc]) / float(D8_LEN[k])
				if s > best_s:
					best_s = s
					best = rr * n + cc
			recv[i] = best
	return recv


## Upstream cell count per cell (itself included), visiting cells highest
## first — the reverse of the flood's ascending pop order.
static func accumulate(recv: PackedInt32Array, order: PackedInt32Array) -> PackedFloat32Array:
	var acc := PackedFloat32Array()
	acc.resize(recv.size())
	acc.fill(1.0)
	for k in range(order.size() - 1, -1, -1):
		var i := order[k]
		var t := recv[i]
		if t >= 0:
			acc[t] += acc[i]
	return acc


static func cell_center(res: Dictionary, idx: int) -> Vector2:
	var n := int(res["n"])
	var cell := float(res["cell_m"])
	var half := float(res["half_m"])
	return Vector2(-half + float(idx % n) * cell, -half + float(idx / n) * cell)


static func cell_at(res: Dictionary, p: Vector2) -> int:
	var n := int(res["n"])
	var cell := float(res["cell_m"])
	var half := float(res["half_m"])
	var c := int(round((p.x + half) / cell))
	var r := int(round((p.y + half) / cell))
	if c < 0 or r < 0 or c >= n or r >= n:
		return -1
	return r * n + c


## Upstream area (m²) at a world point — the max over the 3×3 cells around it,
## since a line drawn by hand (or a burned OSM line) may sit a cell off the
## accumulated thread.
static func area_at(res: Dictionary, p: Vector2) -> float:
	var i := cell_at(res, p)
	if i < 0:
		return 0.0
	var n := int(res["n"])
	var acc: PackedFloat32Array = res["acc"]
	var r0 := i / n
	var c0 := i % n
	var best := 0.0
	for dr in [-1, 0, 1]:
		for dc in [-1, 0, 1]:
			var r: int = r0 + int(dr)
			var c: int = c0 + int(dc)
			if r >= 0 and c >= 0 and r < n and c < n:
				best = maxf(best, acc[r * n + c])
	var cell := float(res["cell_m"])
	return best * cell * cell


## Downstream path from a world point along the receivers, as world XZ —
## the Trace tool. Stops at the edge or after max_steps.
static func trace(res: Dictionary, p: Vector2, max_steps: int = 4000) -> PackedVector2Array:
	var out := PackedVector2Array()
	var i := cell_at(res, p)
	if i < 0:
		return out
	var recv: PackedInt32Array = res["recv"]
	out.append(p)
	var guard := 0
	while i >= 0 and guard < max_steps:
		out.append(cell_center(res, i))
		i = recv[i]
		guard += 1
	return out


## Extract channels draining ≥ min_area_m2: Array of {points (world XZ,
## downstream), order (Strahler), area_m2 (at the downstream end)}.
static func channels(res: Dictionary, min_area_m2: float, simplify_m: float = -1.0) -> Array:
	var n := int(res["n"])
	var cell := float(res["cell_m"])
	var acc: PackedFloat32Array = res["acc"]
	var recv: PackedInt32Array = res["recv"]
	var order: PackedInt32Array = res["order"]
	var min_cells := maxf(min_area_m2 / (cell * cell), 2.0)
	var is_ch := PackedByteArray()
	is_ch.resize(n * n)
	var inflow := PackedInt32Array()   # channel tributaries into each cell
	inflow.resize(n * n)
	for i in n * n:
		if acc[i] >= min_cells:
			is_ch[i] = 1
	for i in n * n:
		if is_ch[i] == 1 and recv[i] >= 0 and is_ch[recv[i]] == 1:
			inflow[recv[i]] += 1
	# Strahler: visit channel cells highest first (reverse pop order).
	var strahler := PackedInt32Array()
	strahler.resize(n * n)
	var top := PackedInt32Array()      # highest tributary order into the cell
	top.resize(n * n)
	var top_count := PackedInt32Array()
	top_count.resize(n * n)
	for k in range(order.size() - 1, -1, -1):
		var i := order[k]
		if is_ch[i] == 0:
			continue
		var s := 1
		if top[i] > 0:
			s = top[i] + (1 if top_count[i] >= 2 else 0)
		strahler[i] = s
		var t := recv[i]
		if t >= 0 and is_ch[t] == 1:
			if s > top[t]:
				top[t] = s
				top_count[t] = 1
			elif s == top[t]:
				top_count[t] += 1
	# Trace segments: start at heads (no channel inflow) and at every junction
	# (inflow >= 2) — each segment runs to the next junction or the outlet.
	var out: Array = []
	var started := PackedByteArray()
	started.resize(n * n)
	var starts: Array = []
	for i in n * n:
		if is_ch[i] == 1 and inflow[i] != 1:
			starts.append(i)
	var tol := simplify_m if simplify_m > 0.0 else cell * 0.75
	for st in starts:
		var i: int = st
		if started[i] == 1:
			continue
		started[i] = 1
		var pts := PackedVector2Array()
		pts.append(cell_center(res, i))
		var ord := strahler[i]
		var j := recv[i]
		while j >= 0 and is_ch[j] == 1:
			pts.append(cell_center(res, j))
			if inflow[j] >= 2:
				break
			j = recv[j]
		var end_i := cell_at(res, pts[pts.size() - 1])
		if pts.size() >= 2:
			out.append({"points": rdp(pts, tol), "order": ord,
				"area_m2": acc[end_i] * cell * cell if end_i >= 0 else 0.0})
	return out


## Ramer–Douglas–Peucker simplification (iterative).
static func rdp(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := pts.size()
	if n <= 2:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var a: int = seg[0]
		var b: int = seg[1]
		var best := -1.0
		var bi := -1
		for k in range(a + 1, b):
			var d := Geometry2D.get_closest_point_to_segment(pts[k], pts[a], pts[b]).distance_to(pts[k])
			if d > best:
				best = d
				bi = k
		if bi >= 0 and best > tol:
			keep[bi] = 1
			stack.append([a, bi])
			stack.append([bi, b])
	var out := PackedVector2Array()
	for k in n:
		if keep[k] == 1:
			out.append(pts[k])
	return out


## Binary min-heap of (key, id) in packed arrays.
class _Heap:
	var keys := PackedFloat32Array()
	var ids := PackedInt32Array()
	var size := 0

	func is_empty() -> bool:
		return size == 0

	func push(id: int, key: float) -> void:
		if size >= keys.size():
			var cap := maxi(1024, keys.size() * 2)
			keys.resize(cap)
			ids.resize(cap)
		var i := size
		size += 1
		while i > 0:
			var p := (i - 1) >> 1
			if keys[p] <= key:
				break
			keys[i] = keys[p]
			ids[i] = ids[p]
			i = p
		keys[i] = key
		ids[i] = id

	func pop() -> int:
		var top := ids[0]
		size -= 1
		if size > 0:
			var key := keys[size]
			var id := ids[size]
			var i := 0
			while true:
				var l := 2 * i + 1
				if l >= size:
					break
				var r := l + 1
				var m := l
				if r < size and keys[r] < keys[l]:
					m = r
				if keys[m] >= key:
					break
				keys[i] = keys[m]
				ids[i] = ids[m]
				i = m
			keys[i] = key
			ids[i] = id
		return top
