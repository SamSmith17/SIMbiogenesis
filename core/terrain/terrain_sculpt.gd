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


## ---------------------------------------------------------------------------
## Brush / shape / pond sculpt — high-precision detail-patch layer.
##
## These operate on the detail sculpt delta (detail_res over the detail patch).
## `base_grid` is the composed detail surface WITHOUT the detail edits, in AMSL
## metres (so current local height = base_grid[idx] - center_elev + delta[idx]).
## Each returns the touched cell bounds Vector4i(min_c, min_r, max_c, max_r) so the
## caller can update just that mesh/collision region; an empty touch → (-1,-1,-1,-1).
## ---------------------------------------------------------------------------

const NO_TOUCH := Vector4i(-1, -1, -1, -1)


## Smoothstep-shaped radial weight. `hardness` in [0,1]: 0 = soft dome from centre,
## →1 = flat full-strength core with a quick shoulder near the rim.
static func brush_weight(t: float, hardness: float) -> float:
	var inner := clampf(hardness, 0.0, 0.95)
	if t <= inner:
		return 1.0
	if t >= 1.0:
		return 0.0
	return 1.0 - smoothstep(inner, 1.0, t)


static func _cell_bounds(res: int, extent_m: float, center: Vector2, radius_m: float) -> Vector4i:
	var half := extent_m * 0.5
	var inv := float(res - 1) / extent_m
	var min_c := int(floor((center.x - radius_m + half) * inv))
	var max_c := int(ceil((center.x + radius_m + half) * inv))
	var min_r := int(floor((center.y - radius_m + half) * inv))
	var max_r := int(ceil((center.y + radius_m + half) * inv))
	min_c = clampi(min_c, 0, res - 1)
	max_c = clampi(max_c, 0, res - 1)
	min_r = clampi(min_r, 0, res - 1)
	max_r = clampi(max_r, 0, res - 1)
	if max_c < min_c or max_r < min_r:
		return NO_TOUCH
	return Vector4i(min_c, min_r, max_c, max_r)


static func _neighbor_mean_local(base_grid: PackedFloat32Array, delta: PackedFloat32Array,
		res: int, center_elev: float, c: int, r: int) -> float:
	var sum := 0.0
	var count := 0
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			var cc := c + dc
			var rr := r + dr
			if cc < 0 or cc >= res or rr < 0 or rr >= res:
				continue
			var idx := rr * res + cc
			sum += base_grid[idx] - center_elev + delta[idx]
			count += 1
	return sum / float(maxi(count, 1))


## Nearest grid cell to a world XZ (clamped in-bounds).
static func _nearest_cell(res: int, extent_m: float, w: Vector2) -> Vector2i:
	return world_to_cell(w.x, w.y, res, extent_m)


## Apply one op to a single cell (shared by brush / polygon / guarantee-touch).
static func _apply_op_cell(delta: PackedFloat32Array, base_grid: PackedFloat32Array,
		res: int, center_elev: float, c: int, r: int, op: String,
		amount: float, rate: float, f: float, target_local_h: float) -> void:
	var idx := r * res + c
	match op:
		"raise":
			delta[idx] += amount * f
		"lower":
			delta[idx] -= amount * f
		"smooth":
			var avg := _neighbor_mean_local(base_grid, delta, res, center_elev, c, r)
			var cur := base_grid[idx] - center_elev + delta[idx]
			delta[idx] += (avg - cur) * rate * f
		"flatten":
			var cur2 := base_grid[idx] - center_elev + delta[idx]
			delta[idx] += (target_local_h - cur2) * rate * f


## Radial brush stamp. For "raise"/"lower" `strength` is metres of change at full
## weight; for "smooth"/"flatten" it is a blend rate in [0,1]. `target_local_h` is
## the flatten goal (local metres, i.e. AMSL − center_elev). Always affects at least
## the nearest cell so a small brush on a coarse DEM still deforms the ground.
static func apply_brush(delta: PackedFloat32Array, res: int, extent_m: float,
		center: Vector2, radius_m: float, strength: float, hardness: float, op: String,
		base_grid: PackedFloat32Array, center_elev: float,
		target_local_h: float = 0.0) -> Vector4i:
	if delta.is_empty() or res < 2 or radius_m <= 0.0:
		return NO_TOUCH
	if not (op in ["raise", "lower", "smooth", "flatten"]):
		return NO_TOUCH
	var bounds := _cell_bounds(res, extent_m, center, radius_m)
	var inv_r := 1.0 / maxf(radius_m, 0.001)
	var rate := clampf(strength, 0.0, 1.0)
	var touched := false
	var tmin := Vector2i(res, res)
	var tmax := Vector2i(-1, -1)
	if bounds != NO_TOUCH:
		for r in range(bounds.y, bounds.w + 1):
			for c in range(bounds.x, bounds.z + 1):
				var w := cell_to_world(c, r, res, extent_m)
				var t := w.distance_to(center) * inv_r
				if t >= 1.0:
					continue
				var f := brush_weight(t, hardness)
				if f <= 0.0:
					continue
				_apply_op_cell(delta, base_grid, res, center_elev, c, r, op, strength, rate, f, target_local_h)
				touched = true
				tmin.x = mini(tmin.x, c)
				tmin.y = mini(tmin.y, r)
				tmax.x = maxi(tmax.x, c)
				tmax.y = maxi(tmax.y, r)
	if not touched:
		var cell := _nearest_cell(res, extent_m, center)
		_apply_op_cell(delta, base_grid, res, center_elev, cell.x, cell.y, op, strength, rate, 1.0, target_local_h)
		return Vector4i(cell.x, cell.y, cell.x, cell.y)
	return Vector4i(tmin.x, tmin.y, tmax.x, tmax.y)


## Additive pond bowl: deepens the basin by up to `depth_step_m` at the centre,
## tapering to zero at the rim (smooth cosine bowl). Repeated calls dig deeper.
## Always digs at least the nearest cell.
static func apply_pond_stamp(delta: PackedFloat32Array, res: int, extent_m: float,
		center: Vector2, radius_m: float, depth_step_m: float) -> Vector4i:
	if delta.is_empty() or res < 2 or radius_m <= 0.0 or depth_step_m <= 0.0:
		return NO_TOUCH
	var bounds := _cell_bounds(res, extent_m, center, radius_m)
	var inv_r := 1.0 / maxf(radius_m, 0.001)
	var touched := false
	var tmin := Vector2i(res, res)
	var tmax := Vector2i(-1, -1)
	if bounds != NO_TOUCH:
		for r in range(bounds.y, bounds.w + 1):
			for c in range(bounds.x, bounds.z + 1):
				var w := cell_to_world(c, r, res, extent_m)
				var t := w.distance_to(center) * inv_r
				if t >= 1.0:
					continue
				var bowl := 0.5 * (1.0 + cos(PI * clampf(t, 0.0, 1.0)))
				delta[r * res + c] -= depth_step_m * bowl
				touched = true
				tmin.x = mini(tmin.x, c)
				tmin.y = mini(tmin.y, r)
				tmax.x = maxi(tmax.x, c)
				tmax.y = maxi(tmax.y, r)
	if not touched:
		var cell := _nearest_cell(res, extent_m, center)
		delta[cell.y * res + cell.x] -= depth_step_m
		return Vector4i(cell.x, cell.y, cell.x, cell.y)
	return Vector4i(tmin.x, tmin.y, tmax.x, tmax.y)


## Apply a sculpt op inside an arbitrary polygon (circle/rect/lasso/polygon mask),
## feathering the effect to zero within `feather_m` of the polygon edge so the area
## blends smoothly back to the surrounding terrain. `amount` follows the same
## per-op convention as apply_brush's `strength`.
static func apply_polygon_op(delta: PackedFloat32Array, res: int, extent_m: float,
		poly: PackedVector2Array, op: String, amount: float, feather_m: float,
		base_grid: PackedFloat32Array, center_elev: float,
		target_local_h: float = 0.0) -> Vector4i:
	if delta.is_empty() or res < 2 or poly.size() < 3:
		return NO_TOUCH
	var aabb := _poly_aabb(poly)
	var half := extent_m * 0.5
	var inv := float(res - 1) / extent_m
	var min_c := clampi(int(floor((aabb.position.x + half) * inv)), 0, res - 1)
	var max_c := clampi(int(ceil((aabb.end.x + half) * inv)), 0, res - 1)
	var min_r := clampi(int(floor((aabb.position.y + half) * inv)), 0, res - 1)
	var max_r := clampi(int(ceil((aabb.end.y + half) * inv)), 0, res - 1)
	if not (op in ["raise", "lower", "smooth", "flatten"]):
		return NO_TOUCH
	var rate := 1.0 if op == "flatten" else clampf(amount, 0.0, 1.0)
	var touched := false
	var tmin := Vector2i(res, res)
	var tmax := Vector2i(-1, -1)
	for r in range(min_r, max_r + 1):
		for c in range(min_c, max_c + 1):
			var w := cell_to_world(c, r, res, extent_m)
			if not Geometry2D.is_point_in_polygon(w, poly):
				continue
			var edge := _point_edge_distance(w, poly)
			var f := 1.0 if feather_m <= 0.0 else clampf(edge / feather_m, 0.0, 1.0)
			f = smoothstep(0.0, 1.0, f)
			if f <= 0.0:
				continue
			_apply_op_cell(delta, base_grid, res, center_elev, c, r, op, amount, rate, f, target_local_h)
			touched = true
			tmin.x = mini(tmin.x, c)
			tmin.y = mini(tmin.y, r)
			tmax.x = maxi(tmax.x, c)
			tmax.y = maxi(tmax.y, r)
	if not touched:
		# Selection smaller than one grid cell — apply to the nearest cell so the
		# action always does something (no confusing "nothing changed").
		var centroid := Vector2.ZERO
		for p in poly:
			centroid += p
		centroid /= float(maxi(poly.size(), 1))
		var cell := _nearest_cell(res, extent_m, centroid)
		_apply_op_cell(delta, base_grid, res, center_elev, cell.x, cell.y, op, amount, rate, 1.0, target_local_h)
		return Vector4i(cell.x, cell.y, cell.x, cell.y)
	return Vector4i(tmin.x, tmin.y, tmax.x, tmax.y)


## Local surface height (AMSL − center_elev) at a world XZ, from base + edits.
static func sample_local_height(base_grid: PackedFloat32Array, delta: PackedFloat32Array,
		res: int, extent_m: float, center_elev: float, x: float, z: float) -> float:
	if base_grid.is_empty() or res < 2:
		return 0.0
	var cell := world_to_cell(x, z, res, extent_m)
	var idx := cell.y * res + cell.x
	var d := 0.0
	if idx >= 0 and idx < delta.size():
		d = delta[idx]
	return base_grid[idx] - center_elev + d


static func _poly_aabb(poly: PackedVector2Array) -> Rect2:
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	return Rect2(min_x, min_z, max_x - min_x, max_z - min_z)


## Distance from an interior point to the nearest polygon edge (0 on the boundary).
static func _point_edge_distance(p: Vector2, poly: PackedVector2Array) -> float:
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
