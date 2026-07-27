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
