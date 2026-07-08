class_name TerrainSeamDiag
extends RefCounted

## Seam quality metrics for the detail↔coarse terrain boundary (headless-testable).

const DEFAULT_SAMPLE_COUNT := 64


## Sample heights along the detail-square perimeter and in a coarse exterior ring.
## Returns max_delta_m, rms_delta_m, worst_xz (Vector2), sample_count.
static func measure_boundary_delta(detail_surf: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float,
		sample_count: int = DEFAULT_SAMPLE_COUNT) -> Dictionary:
	var result := {
		"max_delta_m": 0.0,
		"rms_delta_m": 0.0,
		"worst_xz": Vector2.ZERO,
		"sample_count": 0,
	}
	if detail_surf.is_empty() or coarse.is_empty() or detail_res < 2 or coarse_res < 2:
		return result
	var half_d := detail_extent_m * 0.5
	var sum_sq := 0.0
	var count := 0
	var max_d := 0.0
	var worst := Vector2.ZERO
	for i in sample_count:
		var t := float(i) / float(maxi(sample_count - 1, 1))
		var x := 0.0
		var z := 0.0
		# Walk the square perimeter: east → north → west → south.
		var perim := t * 4.0
		if perim < 1.0:
			x = lerpf(half_d, -half_d, perim)
			z = half_d
		elif perim < 2.0:
			x = -half_d
			z = lerpf(half_d, -half_d, perim - 1.0)
		elif perim < 3.0:
			x = lerpf(-half_d, half_d, perim - 2.0)
			z = -half_d
		else:
			x = half_d
			z = lerpf(-half_d, half_d, perim - 3.0)
		var d_y := TerrainBuilder.height_at_world_xz_rect(
			detail_surf, detail_res, detail_res, detail_extent_m, center_elev, x, z)
		var c_y := TerrainBuilder.height_at_world_xz(
			coarse, coarse_res, coarse_extent_m, center_elev, x, z)
		var delta := absf(d_y - c_y)
		sum_sq += delta * delta
		count += 1
		if delta > max_d:
			max_d = delta
			worst = Vector2(x, z)
	# Exterior ring: coarse vertices just outside the detail square.
	var ring_m := TerrainBuilder.EXTERIOR_RING_M
	var inv_t := 1.0 / float(maxi(coarse_res - 1, 1))
	for r in coarse_res:
		var z_c := float(r) * inv_t * coarse_extent_m - coarse_extent_m * 0.5
		for c in coarse_res:
			var x_c := float(c) * inv_t * coarse_extent_m - coarse_extent_m * 0.5
			var dist_in := maxf(absf(x_c), absf(z_c))
			if dist_in <= half_d or dist_in > half_d + ring_m:
				continue
			var d_y := TerrainBuilder.height_at_world_xz_rect(
				detail_surf, detail_res, detail_res, detail_extent_m, center_elev, x_c, z_c)
			var c_y := TerrainBuilder.height_at_world_xz(
				coarse, coarse_res, coarse_extent_m, center_elev, x_c, z_c)
			var delta := absf(d_y - c_y)
			sum_sq += delta * delta
			count += 1
			if delta > max_d:
				max_d = delta
				worst = Vector2(x_c, z_c)
	result["max_delta_m"] = max_d
	result["rms_delta_m"] = sqrt(sum_sq / float(maxi(count, 1)))
	result["worst_xz"] = worst
	result["sample_count"] = count
	return result
