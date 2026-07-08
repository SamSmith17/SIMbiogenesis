extends SceneTree

## Headless seam diagnostic runner (offline, synthetic mismatch grid).
## Run: godot --headless --path . --script core/terrain/terrain_seam_diag_run.gd

func _initialize() -> void:
	var coarse_res := 17
	var detail_res := 17
	var coarse := PackedFloat32Array()
	coarse.resize(coarse_res * coarse_res)
	coarse.fill(100.0)
	var detail := PackedFloat32Array()
	detail.resize(detail_res * detail_res)
	detail.fill(200.0)
	var center := 150.0
	var terrain_extent := 3000.0
	var detail_extent := 1000.0
	var offset := TerrainBuilder.compute_detail_vertical_offset(
		detail, detail_res, detail_extent, coarse, coarse_res, terrain_extent, center)
	var aligned := TerrainBuilder.apply_detail_vertical_offset(detail, offset)
	var feather := TerrainBuilder.compute_adaptive_feather_m(
		aligned, detail_res, detail_extent, coarse, coarse_res, terrain_extent, center)
	var feathered := TerrainBuilder.feather_detail_to_coarse(
		aligned, detail_res, detail_extent, coarse, coarse_res, terrain_extent, center, feather)
	var patched := TerrainBuilder.patch_centre_heights(
		coarse, coarse_res, feathered, detail_res, terrain_extent, detail_extent, feather)
	var exterior := TerrainBuilder.feather_coarse_exterior_ring(
		patched, coarse_res, terrain_extent, center, feathered, detail_res, detail_extent)
	var diag := TerrainSeamDiag.measure_boundary_delta(
		feathered, detail_res, detail_extent, exterior, coarse_res, terrain_extent, center)
	print("SEAM_DIAG offset=%.1f m feather=%.0f m max_delta=%.2f rms=%.2f samples=%d" % [
		offset, feather, float(diag.get("max_delta_m", 0.0)), float(diag.get("rms_delta_m", 0.0)),
		int(diag.get("sample_count", 0))])
	var ok := float(diag.get("max_delta_m", 99.0)) < 2.0
	print("SEAM_DIAG %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
