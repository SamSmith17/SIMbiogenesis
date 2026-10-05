extends SceneTree

## Headless validation for ClimelapseSeries + the drone-path rig.

const HOURS_PER_YEAR := 8760.0


func _init() -> void:
	var fails := 0
	fails += _test_series_keyframes()
	fails += _test_drone_path_interpolate()
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


func _test_drone_path_interpolate() -> int:
	var fails := 0
	var rig := ClimelapseCameraRig.new()
	rig.valid = true
	rig.add_waypoint(Vector3(0, 10, 0), 0.0, -0.3)
	rig.add_waypoint(Vector3(100, 20, 0), PI * 0.5, -0.5)
	if not rig.has_path():
		fails += 1
		print("  expected has_path with 2 waypoints")
	var mid := rig.interpolate_at(0.5)
	if absf(mid.origin.x - 50.0) > 0.01 or absf(mid.origin.y - 15.0) > 0.01:
		fails += 1
		print("  path midpoint mismatch: ", mid.origin)
	var end := rig.interpolate_at(1.0)
	if absf(end.origin.x - 100.0) > 0.01:
		fails += 1
		print("  path end mismatch: ", end.origin)
	return fails
