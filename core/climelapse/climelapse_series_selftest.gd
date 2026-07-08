extends SceneTree

## Headless validation for ClimelapseSeries + ClimelapseScaleBake (Phase 3–4).

const HOURS_PER_YEAR := 8760.0


func _init() -> void:
	var fails := 0
	fails += _test_series_keyframes()
	fails += _test_scale_bake_roundtrip()
	if fails == 0:
		print("climelapse_series_selftest: PASS")
	else:
		print("climelapse_series_selftest: FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _test_series_keyframes() -> int:
	var fails := 0
	var start := 1940.0 * HOURS_PER_YEAR + 60.0 * 24.0
	var end := start + 24.0 * 5.0
	var series := ClimelapseSeries.new()
	series.configure(start, end, 40.0, 1)
	var guard := 0
	while not series.is_complete() and guard < 20:
		series.fill_forward_chunk(0.0, 5)
		guard += 1
	if not series.is_complete():
		fails += 1
		print("  series never reached is_complete()")
	if series.keyframe_count() != 5:
		fails += 1
		print("  expected 5 keyframes, got ", series.keyframe_count())
	var idx := series.keyframe_index_at(start + 24.0 * 3.0)
	if idx != 3:
		fails += 1
		print("  keyframe_index_at day 3: expected 3, got ", idx)
	var sample: Dictionary = series.sample_at(start)
	if sample.is_empty() or not sample.has("growth_clock_h"):
		fails += 1
		print("  sample_at missing growth_clock_h")
	var json_path := "user://climelapse_selftest.json"
	if not series.save_json(json_path):
		fails += 1
	else:
		var loaded := ClimelapseSeries.load_json(json_path)
		if loaded == null or loaded.keyframe_count() != series.keyframe_count():
			fails += 1
			print("  JSON round-trip keyframe count mismatch")
	return fails


func _test_scale_bake_roundtrip() -> int:
	var fails := 0
	var bake := ClimelapseScaleBake.new()
	bake.keyframe_count = 3
	bake.manual_entry_count = 2
	bake.manual_scales = PackedFloat32Array([1.0, 2.0, 1.1, 2.1, 1.2, 2.2])
	var dir := "user://climelapse_selftest_bake"
	var meta := bake.save_to_dir(dir)
	if meta.is_empty():
		fails += 1
		print("  save_to_dir returned empty meta")
		return fails
	var loaded := ClimelapseScaleBake.new()
	if not loaded.load_from_dir(dir, meta):
		fails += 1
		print("  load_from_dir failed")
	elif loaded.manual_scales.size() != bake.manual_scales.size():
		fails += 1
		print("  scale array size mismatch")
	else:
		for i in bake.manual_scales.size():
			if absf(loaded.manual_scales[i] - bake.manual_scales[i]) > 1e-6:
				fails += 1
				print("  scale mismatch at ", i)
				break
	return fails
