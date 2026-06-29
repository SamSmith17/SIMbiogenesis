class_name TerrainRoadFlatten
extends RefCounted

## Post-processes the terrain height grid: level road corridors and optional
## landuse polygons using OSM vector data.

const DEFAULT_FEATHER_M := 2.0
## Road corridors are only flattened when vertices are spaced finely enough;
## on the 30 km coarse grid (~120 m/cell) stamping would carve berms/canyons.
const MAX_CELL_M_FOR_FLATTEN := 12.0
const PROFILE_SMOOTH_RADIUS_M := 12.0

const HIGHWAY_HALF_WIDTH := {
	"motorway": 8.0,
	"trunk": 7.0,
	"primary": 6.0,
	"secondary": 5.5,
	"tertiary": 5.0,
	"unclassified": 4.5,
	"residential": 4.0,
	"service": 3.0,
	"track": 2.5,
	"path": 1.5,
}


static func highway_half_width(tags: Dictionary) -> float:
	if tags.has("width"):
		var w := str(tags["width"]).to_lower().trim_suffix("m").strip_edges().to_float()
		if not is_nan(w) and w > 0.0:
			return w * 0.5
	var hw := str(tags.get("highway", "residential"))
	return float(HIGHWAY_HALF_WIDTH.get(hw, 4.0))


static func cell_size_m(extent_m: float, res: int) -> float:
	return extent_m / float(maxi(res - 1, 1))


## Closed polygon ribbon around a polyline centreline (for vegetation exclusions).
static func road_corridor_polygon(points: PackedVector2Array, half_width_m: float) -> PackedVector2Array:
	if points.size() < 2 or half_width_m <= 0.0:
		return PackedVector2Array()
	var left: PackedVector2Array = PackedVector2Array()
	var right: PackedVector2Array = PackedVector2Array()
	for i in points.size():
		var p := points[i]
		var tangent := Vector2.ZERO
		if i == 0:
			tangent = (points[i + 1] - p).normalized()
		elif i == points.size() - 1:
			tangent = (p - points[i - 1]).normalized()
		else:
			tangent = ((points[i + 1] - points[i - 1])).normalized()
		if tangent.length_squared() < 1e-8:
			continue
		var normal := Vector2(-tangent.y, tangent.x)
		left.append(p + normal * half_width_m)
		right.append(p - normal * half_width_m)
	if left.size() < 2:
		return PackedVector2Array()
	right.reverse()
	var out := PackedVector2Array()
	out.append_array(left)
	out.append_array(right)
	return out


static func apply_road_corridors(grid: PackedFloat32Array, res: int, extent_m: float,
		roads: Array, feather_m: float = DEFAULT_FEATHER_M) -> PackedFloat32Array:
	var out := grid.duplicate()
	if roads.is_empty() or res < 2:
		return out
	if cell_size_m(extent_m, res) > MAX_CELL_M_FOR_FLATTEN:
		return out
	var half := extent_m * 0.5
	var cell := cell_size_m(extent_m, res)
	for road in roads:
		if not (road is Dictionary):
			continue
		var pts: Variant = road.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 2:
			continue
		var poly: PackedVector2Array = pts
		var half_w: float = TerrainBuilder.dict_float(road, "half_width_m", 4.0)
		_flatten_polyline(out, res, extent_m, half, cell, poly, half_w, feather_m)
	return out


static func apply_polygon_flattens(grid: PackedFloat32Array, res: int, extent_m: float,
		polygons: Array, feather_m: float = DEFAULT_FEATHER_M) -> PackedFloat32Array:
	var out := grid.duplicate()
	if polygons.is_empty() or res < 2:
		return out
	if cell_size_m(extent_m, res) > MAX_CELL_M_FOR_FLATTEN:
		return out
	var half := extent_m * 0.5
	var cell := cell_size_m(extent_m, res)
	for item in polygons:
		if not (item is Dictionary):
			continue
		var pts: Variant = item.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
			continue
		_flatten_polygon_interior(out, res, extent_m, half, cell, pts, feather_m)
	return out


static func _flatten_polyline(grid: PackedFloat32Array, res: int, extent_m: float,
		half: float, cell: float, points: PackedVector2Array, half_w: float,
		feather_m: float) -> void:
	var stamps: Array = []
	for seg_i in points.size() - 1:
		var a := points[seg_i]
		var b := points[seg_i + 1]
		var seg_len := a.distance_to(b)
		if seg_len < 0.01:
			continue
		var steps := int(ceil(seg_len / maxf(cell * 0.35, 0.5))) + 1
		for s in steps + 1:
			var t := float(s) / float(steps)
			var p := a.lerp(b, t)
			stamps.append({
				"p": p,
				"y": _sample_grid_world(grid, res, extent_m, half, p.x, p.y),
			})
	if stamps.is_empty():
		return
	var smooth_n := maxi(1, int(round(PROFILE_SMOOTH_RADIUS_M / maxf(cell, 0.5))))
	for i in stamps.size():
		var lo := maxi(0, i - smooth_n)
		var hi := mini(stamps.size() - 1, i + smooth_n)
		var total := 0.0
		var count := 0
		for j in range(lo, hi + 1):
			total += float(stamps[j]["y"])
			count += 1
		stamps[i]["y_smooth"] = total / float(count)
	for stamp in stamps:
		_stamp_disc(grid, res, extent_m, half, cell, stamp["p"], half_w,
			float(stamp["y_smooth"]), feather_m)


static func _flatten_polygon_interior(grid: PackedFloat32Array, res: int, extent_m: float,
		half: float, cell: float, poly: PackedVector2Array, feather_m: float) -> void:
	var n := poly.size()
	if n < 3:
		return
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	var heights: Array[float] = []
	for r in res:
		var z := float(r) / float(maxi(res - 1, 1)) * extent_m - half
		if z < min_z - feather_m or z > max_z + feather_m:
			continue
		for c in res:
			var x := float(c) / float(maxi(res - 1, 1)) * extent_m - half
			if x < min_x - feather_m or x > max_x + feather_m:
				continue
			if not Geometry2D.is_point_in_polygon(Vector2(x, z), poly):
				continue
			heights.append(grid[r * res + c])
	if heights.is_empty():
		return
	heights.sort()
	var target := heights[heights.size() / 2]
	for r in res:
		var z := float(r) / float(maxi(res - 1, 1)) * extent_m - half
		for c in res:
			var x := float(c) / float(maxi(res - 1, 1)) * extent_m - half
			var pt := Vector2(x, z)
			if not Geometry2D.is_point_in_polygon(pt, poly):
				var dist := _dist_to_polygon_edge(pt, poly)
				if dist > feather_m:
					continue
				var blend := 1.0 - clampf(dist / feather_m, 0.0, 1.0)
				var idx := r * res + c
				grid[idx] = lerpf(grid[idx], target, blend)
			else:
				grid[r * res + c] = target


static func _stamp_disc(grid: PackedFloat32Array, res: int, extent_m: float, half: float,
		cell: float, center: Vector2, radius: float, y_target: float,
		feather_m: float) -> void:
	var reach := radius + feather_m + cell
	var min_c := int(floor((center.x - reach + half) / extent_m * float(res - 1)))
	var max_c := int(ceil((center.x + reach + half) / extent_m * float(res - 1)))
	var min_r := int(floor((center.y - reach + half) / extent_m * float(res - 1)))
	var max_r := int(ceil((center.y + reach + half) / extent_m * float(res - 1)))
	min_c = clampi(min_c, 0, res - 1)
	max_c = clampi(max_c, 0, res - 1)
	min_r = clampi(min_r, 0, res - 1)
	max_r = clampi(max_r, 0, res - 1)
	for r in range(min_r, max_r + 1):
		var z := float(r) / float(maxi(res - 1, 1)) * extent_m - half
		for c in range(min_c, max_c + 1):
			var x := float(c) / float(maxi(res - 1, 1)) * extent_m - half
			var dist := Vector2(x, z).distance_to(center)
			if dist > radius + feather_m:
				continue
			var blend := 1.0
			if dist > radius:
				blend = 1.0 - clampf((dist - radius) / feather_m, 0.0, 1.0)
			var idx := r * res + c
			grid[idx] = lerpf(grid[idx], y_target, blend)


static func _sample_grid_world(grid: PackedFloat32Array, res: int, extent_m: float,
		half: float, x: float, z: float) -> float:
	var u := clampf((x + half) / extent_m, 0.0, 1.0)
	var v := clampf((z + half) / extent_m, 0.0, 1.0)
	return TerrainBuilder.sample_bilinear(grid, res, res, u, v)


static func _dist_to_polygon_edge(pt: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		best = minf(best, _dist_point_segment(pt, a, b))
	return best


static func _dist_point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-8:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
