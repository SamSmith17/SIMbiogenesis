class_name LakeSpill
extends RefCounted

## Where a lake's water can actually REACH at a given level — pure and
## worker-thread safe.
##
## A flat plane at the lake's level floods every hollow lower than it, but
## water only gets where a path from the lake stays under the level: the
## blocks behind Bombay Beach's berm sit below the 1990s sea and stayed dry.
## Over a square grid of ground heights this finds, per cell, the SPILL
## level: the lowest lake level at which lake water reaches the cell, i.e.
## the minimum over every path from the lake of the highest ground on it
## (the minimax / "fill-and-spill" level). Computed once by a Priority-Flood
## seeded at the lake's own cells (Barnes, Lehman & Mulla 2014, the seeded
## form of Alg. 1, 4-connected): pop the lowest open cell, give each unvisited neighbour
## max(its ground, this cell's spill). Then a cell is wet at level L exactly
## when spill < L, so the water shader masks the plane with one texture and
## one uniform, and the level stays a pure function of the clock.
##
## The grid is centred on the world origin (the site), cell size `cell_m`,
## row = z, column = x, like FlowRouting.

const MAX_N := 800
## Spill of a cell no lake water can reach. Finite on purpose: the shader
## filters the texture linearly, and INF beside a number interpolates to NaN,
## which compares false and would draw water there.
const UNREACHED := 1.0e6
## FOUR neighbours, not eight: on a raster a diagonal berm is a staircase of
## crest cells that touch only at their corners, and an 8-neighbour flood
## walks straight through it. At Bombay Beach that flooded the town behind its
## dike at a level 0.2 m above one the dike held.
const D4_DC := [1, 0, -1, 0]
const D4_DR := [0, 1, 0, -1]


## Grid size for a half-extent and a wanted cell size (clamped to MAX_N).
static func grid_n(half_m: float, cell_m: float) -> int:
	return clampi(int(ceil(2.0 * half_m / maxf(cell_m, 0.5))) + 1, 3, MAX_N)


## Spill levels from ground heights `h` (n×n, row-major) and seed cells
## (`seed` 1 = lake). Cells never reached (no seed) are UNREACHED.
static func spill(h: PackedFloat32Array, n: int, seed: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n * n)
	out.fill(UNREACHED)
	var closed := PackedByteArray()
	closed.resize(n * n)
	var heap := _Heap.new()
	for i in n * n:
		if seed[i] == 1:
			out[i] = h[i]
			closed[i] = 1
			heap.push(i, h[i])
	while not heap.is_empty():
		var c := heap.pop()
		var cr := c / n
		var cc := c - cr * n
		var sc := out[c]
		for k in 4:
			var r := cr + int(D4_DR[k])
			var col := cc + int(D4_DC[k])
			if r < 0 or r >= n or col < 0 or col >= n:
				continue
			var nb := r * n + col
			if closed[nb] == 1:
				continue
			closed[nb] = 1
			out[nb] = maxf(h[nb], sc)
			heap.push(nb, out[nb])
	return out


## Seeds: grid cells inside one of the lake outlines whose ground is at or
## under `water_y` + `tol` (the lake's own surface in the DEM). World XZ.
static func seeds(h: PackedFloat32Array, n: int, half_m: float, outlines: Array,
		water_y: float, tol: float = 0.5) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n * n)
	var cell := 2.0 * half_m / float(n - 1)
	for r in n:
		var z := -half_m + float(r) * cell
		for c in n:
			var i := r * n + c
			if h[i] > water_y + tol:
				continue
			var p := Vector2(-half_m + float(c) * cell, z)
			for poly_v in outlines:
				if Geometry2D.is_point_in_polygon(p, poly_v as PackedVector2Array):
					out[i] = 1
					break
	return out


## The spill level of the cell nearest world (x, z); NAN outside the grid.
static func spill_at(sp: PackedFloat32Array, n: int, half_m: float, x: float, z: float) -> float:
	var cell := 2.0 * half_m / float(n - 1)
	var fx := (x + half_m) / cell
	var fz := (z + half_m) / cell
	if fx < 0.0 or fz < 0.0 or fx > float(n - 1) or fz > float(n - 1):
		return NAN
	return sp[mini(int(round(fz)), n - 1) * n + mini(int(round(fx)), n - 1)]


## Min-heap of (key, id) in packed arrays (FlowRouting's, kept local so this
## file stands alone on a worker thread).
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
