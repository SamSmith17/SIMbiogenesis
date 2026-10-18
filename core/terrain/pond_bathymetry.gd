class_name PondBathymetry
extends RefCounted

## Pure bathymetric volume integrals for sculpted / gravity ponds.
## Samples a height callable over a polygon and integrates water column volume.

const FREEBOARD_DEFAULT_M := 0.05


## Volume of water (litres) when the free surface is at `level_m`.
## Cells with ground above the surface contribute 0.
static func volume_to_level_l(poly: PackedVector2Array, height_at: Callable,
		level_m: float, cell_m: float = 1.25,
		spill_cap_m: float = INF) -> float:
	if poly.size() < 3 or height_at == null or cell_m < 0.2:
		return 0.0
	var surface := minf(level_m, spill_cap_m)
	var aabb := _poly_aabb(poly)
	var cell_area := cell_m * cell_m
	var vol_m3 := 0.0
	var x := aabb.position.x
	while x <= aabb.end.x + 1e-4:
		var z := aabb.position.y
		while z <= aabb.end.y + 1e-4:
			var p := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(p, poly):
				var gy := float(height_at.call(p.x, p.y))
				var h := surface - gy
				if h > 0.0:
					vol_m3 += h * cell_area
			z += cell_m
		x += cell_m
	return vol_m3 * 1000.0


## The sample grid behind volume_to_level_l, taken ONCE: the ground height at
## every grid cell inside the outline, in the SAME x-outer / z-inner order the
## sweep integrates in, so a volume evaluated over these samples is
## bit-identical to a fresh sweep (same cells, same float64 sum, same order).
## The sweep's cost is one terrain query + one point-in-polygon test per cell;
## a pond twin push used to pay it ~21 times per pond every 0.25 s (a 19-step
## level bisection + the capacity + the stock), measured at 36 ms a frame on
## Mount Vernon. TerrainLoader caches these per outline and ground fingerprint.
static func basin_samples(poly: PackedVector2Array, height_at: Callable,
		cell_m: float = 1.25) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if poly.size() < 3 or height_at == null or cell_m < 0.2:
		return out
	var aabb := _poly_aabb(poly)
	var x := aabb.position.x
	while x <= aabb.end.x + 1e-4:
		var z := aabb.position.y
		while z <= aabb.end.y + 1e-4:
			var p := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(p, poly):
				out.append(float(height_at.call(p.x, p.y)))
			z += cell_m
		x += cell_m
	return out


## volume_to_level_l over cached samples (see basin_samples). Identical maths.
static func volume_from_samples(samples: PackedFloat64Array, cell_m: float,
		level_m: float, spill_cap_m: float = INF) -> float:
	if cell_m < 0.2:
		return 0.0
	var surface := minf(level_m, spill_cap_m)
	var cell_area := cell_m * cell_m
	var vol_m3 := 0.0
	for gy in samples:
		var h := surface - float(gy)
		if h > 0.0:
			vol_m3 += h * cell_area
	return vol_m3 * 1000.0


## capacity_l over cached samples.
static func capacity_from_samples(samples: PackedFloat64Array, cell_m: float,
		spill_m: float, freeboard_m: float = FREEBOARD_DEFAULT_M) -> float:
	var cap_level := spill_m - maxf(freeboard_m, 0.0)
	return volume_from_samples(samples, cell_m, cap_level, spill_m)


## level_for_volume_l over cached samples: the same 18-step bisection.
static func level_for_volume_from_samples(samples: PackedFloat64Array, cell_m: float,
		target_l: float, floor_m: float, spill_m: float,
		freeboard_m: float = FREEBOARD_DEFAULT_M) -> float:
	var lo := floor_m
	var hi := spill_m - maxf(freeboard_m, 0.0)
	if hi <= lo + 1e-4:
		return lo
	var target := maxf(target_l, 0.0)
	var cap := volume_from_samples(samples, cell_m, hi, spill_m)
	if target >= cap:
		return hi
	for _i in 18:
		var mid := (lo + hi) * 0.5
		var v := volume_from_samples(samples, cell_m, mid, spill_m)
		if v < target:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## Auto capacity = volume at spill − freeboard.
static func capacity_l(poly: PackedVector2Array, height_at: Callable,
		spill_m: float, freeboard_m: float = FREEBOARD_DEFAULT_M,
		cell_m: float = 1.25) -> float:
	var cap_level := spill_m - maxf(freeboard_m, 0.0)
	return volume_to_level_l(poly, height_at, cap_level, cell_m, spill_m)


## Fill fraction from stock/capacity (not linear elevation).
static func fill_frac(stock_l: float, capacity_l: float) -> float:
	if capacity_l <= 1e-3:
		return 0.0
	return clampf(stock_l / capacity_l, 0.0, 1.0)


## Inverse: find level_m whose volume ≈ target_l (binary search on elevation).
static func level_for_volume_l(poly: PackedVector2Array, height_at: Callable,
		target_l: float, floor_m: float, spill_m: float,
		cell_m: float = 1.25, freeboard_m: float = FREEBOARD_DEFAULT_M) -> float:
	var lo := floor_m
	var hi := spill_m - maxf(freeboard_m, 0.0)
	if hi <= lo + 1e-4:
		return lo
	var target := maxf(target_l, 0.0)
	# Cap at capacity.
	var cap := volume_to_level_l(poly, height_at, hi, cell_m, spill_m)
	if target >= cap:
		return hi
	for _i in 18:
		var mid := (lo + hi) * 0.5
		var v := volume_to_level_l(poly, height_at, mid, cell_m, spill_m)
		if v < target:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## --- Stage–storage curves ---------------------------------------------------
## A curve is [[stock_l, level_m], ...] ascending in both (TerrainLoader.
## pond_stage_curve builds one off the basin). These three are the ONE
## conversion the flow engine, the siphon reach and the 3D water share.

## Level (m) at `stock_l`. Clamped to the curve's ends; NAN if malformed.
static func stage_level_for_stock(curve: Array, stock_l: float) -> float:
	return _stage_interp(curve, stock_l, 0, 1)


## Stock (L) at `level_m`. Clamped to the curve's ends; NAN if malformed.
static func stage_stock_for_level(curve: Array, level_m: float) -> float:
	return _stage_interp(curve, level_m, 1, 0)


## Open water area (m²) at `level_m`: dV/dh between the bracketing rows.
static func stage_area_at_level(curve: Array, level_m: float) -> float:
	if curve.size() < 2:
		return NAN
	for i in range(1, curve.size()):
		var a: Variant = curve[i - 1]
		var b: Variant = curve[i]
		if not (a is Array) or not (b is Array) or (a as Array).size() < 2 or (b as Array).size() < 2:
			return NAN
		var lb := float((b as Array)[1])
		if level_m <= lb or i == curve.size() - 1:
			var dh := maxf(lb - float((a as Array)[1]), 1e-4)
			return maxf(float((b as Array)[0]) - float((a as Array)[0]), 0.0) / 1000.0 / dh
	return NAN


static func _stage_interp(curve: Array, x: float, xi: int, yi: int) -> float:
	if curve.size() < 2:
		return NAN
	var prev: Variant = curve[0]
	if not (prev is Array) or (prev as Array).size() < 2:
		return NAN
	if x <= float((prev as Array)[xi]):
		return float((prev as Array)[yi])
	for i in range(1, curve.size()):
		var row: Variant = curve[i]
		if not (row is Array) or (row as Array).size() < 2:
			return NAN
		var x1 := float((row as Array)[xi])
		if x <= x1:
			var x0 := float((prev as Array)[xi])
			var t := 0.0 if x1 - x0 <= 1e-9 else (x - x0) / (x1 - x0)
			return lerpf(float((prev as Array)[yi]), float((row as Array)[yi]), clampf(t, 0.0, 1.0))
		prev = row
	return float((prev as Array)[yi])


## Suggested sample cell for a footprint area (finer on small selections).
static func suggested_cell_m(area_m2: float) -> float:
	if area_m2 < 500.0:
		return 1.0
	if area_m2 < 2000.0:
		return 1.25
	return clampf(sqrt(maxf(area_m2, 1.0)) / 48.0, 1.25, 4.0)


static func _poly_aabb(poly: PackedVector2Array) -> Rect2:
	var aabb := Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		aabb = aabb.expand(poly[i])
	return aabb
