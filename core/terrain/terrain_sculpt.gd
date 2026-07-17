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
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var half_w := maxf((x1 - x0) * 0.5, 0.5)
	var half_d := maxf((z1 - z0) * 0.5, 0.5)
	# Ridge axis along the longer rect side (berm / swale).
	var ridge_along_x := half_w >= half_d
	var touched := PackedByteArray()
	touched.resize(res * res)
	for r in res:
		for c in res:
			var w := cell_to_world(c, r, res, extent_m)
			if w.x < x0 or w.x > x1 or w.y < z0 or w.y > z1:
				continue
			var edge_dist := minf(minf(w.x - x0, x1 - w.x), minf(w.y - z0, z1 - w.y))
			var blend := 1.0 if falloff_m <= 0.0 else clampf(edge_dist / falloff_m, 0.0, 1.0)
			var idx := r * res + c
			var abs_h := base_grid[idx] - center_elev
			var dx := (w.x - cx) / half_w
			var dz := (w.y - cz) / half_d
			match op:
				"level":
					delta[idx] = lerpf(delta[idx], value - abs_h, blend)
				"raise":
					delta[idx] = lerpf(delta[idx], delta[idx] + value, blend)
				"lower":
					delta[idx] = lerpf(delta[idx], delta[idx] - value, blend)
				"hill":
					var radial := 1.0 - clampf(sqrt(dx * dx + dz * dz), 0.0, 1.0)
					var bump := value * radial * radial * blend
					delta[idx] = lerpf(delta[idx], delta[idx] + bump, blend)
				"berm":
					var flank := absf(dz) if ridge_along_x else absf(dx)
					var crest := 1.0 - clampf(flank, 0.0, 1.0)
					# Soft flanks: cosine lobe along the short axis.
					var lobe := 0.5 * (1.0 + cos(PI * clampf(flank, 0.0, 1.0)))
					var bump := value * crest * lobe * blend
					delta[idx] = lerpf(delta[idx], delta[idx] + bump, blend)
				"swale":
					var flank := absf(dz) if ridge_along_x else absf(dx)
					var crest := 1.0 - clampf(flank, 0.0, 1.0)
					var lobe := 0.5 * (1.0 + cos(PI * clampf(flank, 0.0, 1.0)))
					var ditch := value * crest * lobe * blend
					delta[idx] = lerpf(delta[idx], delta[idx] - ditch, blend)
			touched[idx] = 1
	if op == "level":
		_smooth_perimeter(delta, res, touched, 2)


## Multi-ring box average on cells that touch unselected neighbours — softens
## the level falloff shoulder after the main pass.
static func _smooth_perimeter(delta: PackedFloat32Array, res: int,
		touched: PackedByteArray, rings: int) -> void:
	var border := PackedByteArray()
	border.resize(res * res)
	for r in res:
		for c in res:
			var idx := r * res + c
			if touched[idx] == 0:
				continue
			var is_border := false
			for dr in range(-1, 2):
				for dc in range(-1, 2):
					if dr == 0 and dc == 0:
						continue
					var rr := r + dr
					var cc := c + dc
					if rr < 0 or rr >= res or cc < 0 or cc >= res \
							or touched[rr * res + cc] == 0:
						is_border = true
						break
				if is_border:
					break
			if is_border:
				border[idx] = 1
	# Grow the border ring outward within the selection for multi-ring averages.
	for _pass in rings:
		var next := border.duplicate()
		for r in res:
			for c in res:
				var idx := r * res + c
				if touched[idx] == 0 or border[idx] != 0:
					continue
				for dr in range(-1, 2):
					for dc in range(-1, 2):
						var rr := r + dr
						var cc := c + dc
						if rr < 0 or rr >= res or cc < 0 or cc >= res:
							continue
						if border[rr * res + cc] != 0:
							next[idx] = 1
							break
		border = next
	var scratch := delta.duplicate()
	for r in res:
		for c in res:
			var idx := r * res + c
			if border[idx] == 0:
				continue
			var sum := 0.0
			var wsum := 0.0
			for dr in range(-1, 2):
				for dc in range(-1, 2):
					var rr := r + dr
					var cc := c + dc
					if rr < 0 or rr >= res or cc < 0 or cc >= res:
						continue
					# Approximate Gaussian 3×3: centre 4, edges 2, corners 1.
					var w := 4.0 if (dr == 0 and dc == 0) \
							else (2.0 if (dr == 0 or dc == 0) else 1.0)
					sum += scratch[rr * res + cc] * w
					wsum += w
			if wsum > 0.0:
				delta[idx] = sum / wsum


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
