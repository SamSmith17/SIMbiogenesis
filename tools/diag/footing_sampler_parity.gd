extends SceneTree

## Offline: TerrainBuilder.sample_bilinear and sample_footing_height against a
## frozen copy of the versions before 2026-11-18 (an Array per call for the
## NaN fallback, the coarse grid sampled on every query), on random points
## inside, across and outside the detail patch, with NaN corners, a fallback
## grid and no crossfade; every answer compared exactly (bit for bit, NaN
## matching NaN). Then the time per query, old and new.
##   Godot --headless --path . --script tools/diag/footing_sampler_parity.gd

static func _old_bilinear(src: PackedFloat32Array, src_cols: int, src_rows: int,
		u: float, v: float) -> float:
	if src.is_empty() or src_cols < 1 or src_rows < 1:
		return 0.0
	var fx := clampf(u, 0.0, 1.0) * float(src_cols - 1)
	var fy := clampf(v, 0.0, 1.0) * float(src_rows - 1)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, src_cols - 1)
	var y1 := mini(y0 + 1, src_rows - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var v00 := src[y0 * src_cols + x0]
	var v10 := src[y0 * src_cols + x1]
	var v01 := src[y1 * src_cols + x0]
	var v11 := src[y1 * src_cols + x1]
	var samples := [v00, v10, v01, v11]
	var first_finite := NAN
	for s in samples:
		if not is_nan(s):
			first_finite = s
			break
	if is_nan(first_finite):
		return 0.0
	if is_nan(v00): v00 = first_finite
	if is_nan(v10): v10 = first_finite
	if is_nan(v01): v01 = first_finite
	if is_nan(v11): v11 = first_finite
	var top := lerpf(v00, v10, tx)
	var bot := lerpf(v01, v11, tx)
	return lerpf(top, bot, ty)


static func _old_xz(elev: PackedFloat32Array, cols: int, rows: int,
		extent_m: float, center_elev: float, x: float, z: float) -> float:
	if elev.is_empty() or cols < 1 or rows < 1:
		return 0.0
	var half := extent_m * 0.5
	var u := clampf((x + half) / extent_m, 0.0, 1.0)
	var v := clampf((z + half) / extent_m, 0.0, 1.0)
	return _old_bilinear(elev, cols, rows, u, v) - center_elev


static func _old_footing(x: float, z: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float, detail: PackedFloat32Array,
		detail_cols: int, detail_rows: int, detail_extent_m: float,
		detail_fallback_coarse: PackedFloat32Array, crossfade_m: float) -> float:
	var detail_half := detail_extent_m * 0.5 if detail_extent_m > 0.0 else 0.0
	var has_detail := not detail.is_empty() and detail_cols > 1 and detail_rows > 1 and detail_half > 0.0
	var in_detail := detail_half > 0.0 and absf(x) <= detail_half and absf(z) <= detail_half
	var coarse_y := 0.0
	var has_coarse := not coarse.is_empty() and coarse_res > 1
	if has_coarse:
		coarse_y = _old_xz(coarse, coarse_res, coarse_res, coarse_extent_m, center_elev, x, z)
	if in_detail and not has_detail and not detail_fallback_coarse.is_empty() and coarse_res > 1:
		return _old_xz(detail_fallback_coarse, coarse_res, coarse_res, coarse_extent_m, center_elev, x, z)
	if not has_detail:
		if has_coarse:
			return coarse_y
		return 0.0
	var detail_y := _old_xz(detail, detail_cols, detail_rows, detail_extent_m, center_elev, x, z)
	var dist_in := maxf(absf(x), absf(z))
	if dist_in >= detail_half:
		return coarse_y
	if crossfade_m <= 0.0 or dist_in <= detail_half - crossfade_m:
		return detail_y
	var edge_dist := detail_half - dist_in
	var t := clampf(edge_dist / crossfade_m, 0.0, 1.0)
	return lerpf(coarse_y, detail_y, t)


static func _grid(n: int, seed_v: int, nan_share: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var g := PackedFloat32Array()
	g.resize(n * n)
	for i in g.size():
		g[i] = NAN if rng.randf() < nan_share else rng.randf_range(-50.0, 400.0)
	return g


static func _same(a: float, b: float) -> bool:
	return (is_nan(a) and is_nan(b)) or a == b


func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var fails := 0
	var checked := 0
	var cases := [
		{"nan": 0.0, "detail": true, "fallback": false, "fade": TerrainBuilder.FOOTING_CROSSFADE_M},
		{"nan": 0.05, "detail": true, "fallback": false, "fade": TerrainBuilder.FOOTING_CROSSFADE_M},
		{"nan": 0.6, "detail": true, "fallback": false, "fade": 40.0},
		{"nan": 0.0, "detail": false, "fallback": true, "fade": TerrainBuilder.FOOTING_CROSSFADE_M},
		{"nan": 0.0, "detail": false, "fallback": false, "fade": 0.0},
		{"nan": 0.0, "detail": true, "fallback": false, "fade": 0.0},
	]
	for ci in cases.size():
		var c: Dictionary = cases[ci]
		var coarse := _grid(64, 11 + ci, float(c["nan"]))
		var detail := _grid(96, 23 + ci, float(c["nan"])) if bool(c["detail"]) else PackedFloat32Array()
		var fb := _grid(64, 37 + ci, 0.0) if bool(c["fallback"]) else PackedFloat32Array()
		for i in 20000:
			var x := rng.randf_range(-2200.0, 2200.0)
			var z := rng.randf_range(-2200.0, 2200.0)
			if i % 3 == 0:
				x = rng.randf_range(-760.0, 760.0)
				z = rng.randf_range(-760.0, 760.0)
			var a := _old_footing(x, z, coarse, 64, 4000.0, 120.5, detail, 96, 96, 1500.0, fb, float(c["fade"]))
			var b := TerrainBuilder.sample_footing_height(x, z, coarse, 64, 4000.0, 120.5, detail, 96, 96,
				1500.0, fb, float(c["fade"]))
			checked += 1
			if not _same(a, b):
				fails += 1
				if fails < 5:
					print("footparity MISMATCH case %d at (%.2f, %.2f): old %s new %s" % [ci, x, z, str(a), str(b)])
			var u := rng.randf_range(-0.1, 1.1)
			var v := rng.randf_range(-0.1, 1.1)
			var ba := _old_bilinear(coarse, 64, 64, u, v)
			var bb := TerrainBuilder.sample_bilinear(coarse, 64, 64, u, v)
			checked += 1
			if not _same(ba, bb):
				fails += 1
				if fails < 5:
					print("footparity bilinear MISMATCH case %d (%.4f, %.4f): %s vs %s" % [ci, u, v, str(ba), str(bb)])
	print("footparity: %d answers compared, %d different" % [checked, fails])
	# Time per query inside the detail patch (the common case).
	var coarse_t := _grid(256, 3, 0.0)
	var detail_t := _grid(256, 5, 0.0)
	var n := 200000
	var t := Time.get_ticks_usec()
	var acc := 0.0
	for i in n:
		acc += _old_footing(float(i % 997) - 498.0, float(i % 991) - 495.0, coarse_t, 256, 30000.0, 0.0,
			detail_t, 256, 256, 3000.0, PackedFloat32Array(), TerrainBuilder.FOOTING_CROSSFADE_M)
	var t_old := float(Time.get_ticks_usec() - t) / n
	t = Time.get_ticks_usec()
	for i in n:
		acc += TerrainBuilder.sample_footing_height(float(i % 997) - 498.0, float(i % 991) - 495.0,
			coarse_t, 256, 30000.0, 0.0, detail_t, 256, 256, 3000.0)
	var t_new := float(Time.get_ticks_usec() - t) / n
	print("footparity time per query: old %.2f us, new %.2f us (%.0f)" % [t_old, t_new, acc * 0.0])
	print("footparity %s" % ("PASS" if fails == 0 else "FAIL"))
	quit()
