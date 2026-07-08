class_name ClimelapseSeries
extends RefCounted

## Pre-baked calendar + growth-clock keyframes for climelapse scrub/playback.
## One keyframe per `step_days` (default daily) across [start_abs_h, end_abs_h].

const VERSION := 1
const HOURS_PER_DAY := 24.0

var start_abs_h := 0.0
var end_abs_h := 0.0
var step_days := 1
var latitude := 40.0
var keyframes: Array = []


func configure(start_abs: float, end_abs: float, lat: float, step_days_in: int = 1) -> void:
	start_abs_h = start_abs
	end_abs_h = end_abs
	latitude = lat
	step_days = maxi(1, step_days_in)
	keyframes.clear()


func keyframe_count() -> int:
	return keyframes.size()


func step_hours() -> float:
	return float(step_days) * HOURS_PER_DAY


func is_complete() -> bool:
	if keyframes.is_empty():
		return false
	# fill_forward_chunk stops when the *next* abs would reach end_abs, so the last
	# keyframe is always one step short of end — treat that as complete.
	var last_abs := float((keyframes.back() as Dictionary).get("abs_h", start_abs_h))
	return last_abs + step_hours() >= end_abs_h - 0.01


## Append up to `max_steps` daily keyframes. Returns true when the series is full.
func fill_forward_chunk(initial_growth_clock_h: float, max_steps: int) -> bool:
	var clock := CelestialClock.new()
	if keyframes.is_empty():
		var growth_clock := initial_growth_clock_h
		var prev_doy := -1
		var abs := start_abs_h
		while abs < end_abs_h and max_steps > 0:
			var added := _append_keyframe(clock, abs, growth_clock, prev_doy)
			if added.is_empty():
				break
			growth_clock = float(added.get("growth_clock_h", growth_clock))
			prev_doy = int(added.get("day_of_year", prev_doy))
			abs += step_hours()
			max_steps -= 1
	else:
		var last: Dictionary = keyframes.back()
		var growth_clock := float(last.get("growth_clock_h", initial_growth_clock_h))
		var prev_doy := int(last.get("day_of_year", 1))
		var abs := float(last.get("abs_h", start_abs_h)) + step_hours()
		while abs < end_abs_h and max_steps > 0:
			var added := _append_keyframe(clock, abs, growth_clock, prev_doy)
			if added.is_empty():
				break
			growth_clock = float(added.get("growth_clock_h", growth_clock))
			prev_doy = int(added.get("day_of_year", prev_doy))
			abs += step_hours()
			max_steps -= 1
	return is_complete()


func _append_keyframe(clock: CelestialClock, abs_h: float, growth_clock_h: float,
		prev_doy: int) -> Dictionary:
	var dt: Dictionary = clock.abs_hours_to_date(abs_h)
	clock.year = int(dt.get("year", 1))
	clock.month = int(dt.get("month", 1))
	clock.day = int(dt.get("day", 1))
	clock.day_time = float(dt.get("day_time", 12.0))
	var doy := clock.day_of_year
	var step_h := step_hours()
	var season := VegetationGrowth.structural_growth_factor(doy, latitude)
	if season > VegetationGrowth.DORMANCY_THRESHOLD:
		growth_clock_h += step_h * season
	var sig := SeasonModel.season_signals(doy, latitude)
	var kf := {
		"abs_h": abs_h,
		"year": clock.year,
		"month": clock.month,
		"day": clock.day,
		"day_time": clock.day_time,
		"day_of_year": doy,
		"growth_clock_h": growth_clock_h,
		"season": sig,
	}
	keyframes.append(kf)
	return kf


func keyframe_index_at(abs_h: float) -> int:
	if keyframes.is_empty():
		return -1
	var step := step_hours()
	if step <= 0.0:
		return 0
	var idx := int(floor((abs_h - start_abs_h) / step))
	return clampi(idx, 0, keyframes.size() - 1)


func sample_at(abs_h: float) -> Dictionary:
	var idx := keyframe_index_at(abs_h)
	if idx < 0:
		return {}
	return keyframes[idx] as Dictionary


func growth_clock_at(index: int) -> float:
	if index < 0 or index >= keyframes.size():
		return 0.0
	return float((keyframes[index] as Dictionary).get("growth_clock_h", 0.0))


func to_dict() -> Dictionary:
	var kfs: Array = []
	for kf in keyframes:
		if kf is Dictionary:
			kfs.append(kf)
	return {
		"version": VERSION,
		"start_abs_h": start_abs_h,
		"end_abs_h": end_abs_h,
		"step_days": step_days,
		"latitude": latitude,
		"keyframes": kfs,
	}


func from_dict(data: Dictionary) -> void:
	start_abs_h = float(data.get("start_abs_h", 0.0))
	end_abs_h = float(data.get("end_abs_h", 0.0))
	step_days = int(data.get("step_days", 1))
	latitude = float(data.get("latitude", 40.0))
	keyframes = []
	for item in data.get("keyframes", []):
		if item is Dictionary:
			keyframes.append(item)


func save_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict()))
	return true


static func load_json(path: String) -> ClimelapseSeries:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return null
	var s := ClimelapseSeries.new()
	s.from_dict(parsed as Dictionary)
	return s
