class_name TerrainSculpt
extends RefCounted

## Pure terrain sculpt operations on a height delta grid.


static func world_to_cell(x: float, z: float, res: int, extent_m: float) -> Vector2i:
	var half := extent_m * 0.5
	var u := clampf((x + half) / extent_m, 0.0, 1.0)
	var v := clampf((z + half) / extent_m, 0.0, 1.0)
	var c := int(round(u * float(res - 1)))
	var r := int(round(v * float(res - 1)))
	return Vector2i(clampi(c, 0, res - 1), clampi(r, 0, res - 1))


static func cell_to_world(c: int, r: int, res: int, extent_m: float) -> Vector2:
	var half := extent_m * 0.5
	var inv := 1.0 / float(maxi(res - 1, 1))
	return Vector2(float(c) * inv * extent_m - half, float(r) * inv * extent_m - half)


static func apply_rect(delta: PackedFloat32Array, res: int, extent_m: float,
		rect_min: Vector2, rect_max: Vector2, op: String, value: float,
		falloff_m: float, base_grid: PackedFloat32Array, center_elev: float) -> void:
	var x0 := minf(rect_min.x, rect_max.x)
	var x1 := maxf(rect_min.x, rect_max.x)
	var z0 := minf(rect_min.y, rect_max.y)
	var z1 := maxf(rect_min.y, rect_max.y)
	for r in res:
		for c in res:
			var w := cell_to_world(c, r, res, extent_m)
			if w.x < x0 or w.x > x1 or w.y < z0 or w.y > z1:
				continue
			var edge_dist := minf(minf(w.x - x0, x1 - w.x), minf(w.y - z0, z1 - w.y))
			var blend := 1.0 if falloff_m <= 0.0 else clampf(edge_dist / falloff_m, 0.0, 1.0)
			var idx := r * res + c
			var abs_h := base_grid[idx] - center_elev
			match op:
				"level":
					delta[idx] = lerpf(delta[idx], value - abs_h, blend)
				"raise":
					delta[idx] = lerpf(delta[idx], delta[idx] + value, blend)
				"lower":
					delta[idx] = lerpf(delta[idx], delta[idx] - value, blend)


static func nearest_parcel(polygons: Array, world_xz: Vector2) -> PackedVector2Array:
	var best: PackedVector2Array = PackedVector2Array()
	var best_d := INF
	for item in polygons:
		if not (item is Dictionary):
			continue
		var pts: Variant = item.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
			continue
		var poly: PackedVector2Array = pts
		var d := _dist_to_poly(world_xz, poly)
		if d < best_d:
			best_d = d
			best = poly
	return best


static func _dist_to_poly(p: Vector2, poly: PackedVector2Array) -> float:
	if Geometry2D.is_point_in_polygon(p, poly):
		return 0.0
	var best := INF
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var ab := b - a
		var len_sq := ab.length_squared()
		var t := 0.0 if len_sq < 1e-8 else clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best
