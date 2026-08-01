class_name CsvHistoryPlayer
extends Node
## Replays a Home Assistant CSV export (entity_id,state,last_changed) through
## HAClient.sensor_updated and HAEntityLinker.apply_historical_value, while
## driving main.gd world clock from the CSV timestamps.

signal state_changed(state: int)
signal loading_progress(parsed_rows: int, estimated_total: int)
signal data_ready(window_start_unix: int, window_end_unix: int, entity_count: int)
signal playback_progress(cursor_t_unix: int, fraction: float)
## Emitted instead of auto-playing when a file is loaded as an NLE "clip"
## (parse-only, no world-clock takeover). The owner then builds an ObservedSeries.
signal clip_ready(window_start_unix: int, window_end_unix: int, entity_count: int)

const CsvEntityMapperScript := preload("res://core/csv_entity_mapper.gd")
const ObservedSeriesScript := preload("res://core/observed_series.gd")
const HaTimeUtilScript := preload("res://core/ha_time_util.gd")

enum State { IDLE, LOADING, READY, PLAYING, PAUSED, STOPPED }

const _DEFAULT_SPEED_X := 60.0
const _PARSE_CHUNK_ROWS := 800

var _linker: Node = null
var _ha_client: Node = null
var _main_node: Node = null
var _solar_ui: Node = null
var _sim_mode: Node = null
var _mapper: RefCounted = null

var _state: int = State.IDLE
var _speed_x: float = _DEFAULT_SPEED_X
var _start_t_unix: int = 0
var _end_t_unix: int = 0
var _cursor_t_unix: float = 0.0
var _source_path: String = ""

## entity_id -> Array of {t: int, v: float}
var _timelines: Dictionary = {}
var _cursors: Dictionary = {}
var _last_pushed: Dictionary = {}

var _file: FileAccess = null
var _parse_rows_done: int = 0
var _parse_file_size: int = 0
var _parse_header_skipped: bool = false
var _last_graph_day_key: String = ""
## Clip mode: parse only, no world-clock takeover, no auto-play. Used to load a
## datastream as a comparison "clip" on the NLE timeline rather than replay it.
var _clip_mode: bool = false


func setup(linker: Node = null, ha_client: Node = null, main_node: Node = null) -> void:
	_linker = linker
	_ha_client = ha_client
	_main_node = main_node
	_sim_mode = get_node_or_null("/root/SimMode")
	if _mapper == null:
		_mapper = CsvEntityMapperScript.new()
	_resolve_runtime_nodes()


func get_entity_ids() -> Array[String]:
	var out: Array[String] = []
	for k: Variant in _timelines.keys():
		out.append(str(k))
	out.sort()
	return out


func get_mapper() -> RefCounted:
	if _mapper == null:
		_mapper = CsvEntityMapperScript.new()
	return _mapper


func autolink_entities() -> Dictionary:
	var ids := get_entity_ids()
	var mappings: Dictionary = CsvEntityMapperScript.autolink(ids)
	if _mapper != null:
		_mapper.set_role_mappings(mappings)
	return mappings


func set_role_mappings(mappings: Dictionary) -> void:
	if _mapper == null:
		_mapper = CsvEntityMapperScript.new()
	_mapper.set_role_mappings(mappings)
	_refresh_solar_from_cursor()
	_notify_solar_ui_csv_state()
	_refresh_solar_ui_day_graph()


func _refresh_solar_from_cursor() -> void:
	_cursors.clear()
	_last_pushed.clear()
	_apply_at_cursor()


func get_state() -> int:
	return _state


func get_source_path() -> String:
	return _source_path


func get_entity_count() -> int:
	return _timelines.size()


func get_window_unix() -> Vector2i:
	return Vector2i(_start_t_unix, _end_t_unix)


## Raw {t,v} sample lists for the currently-mapped roles (battery_soc/solar/load/…).
## Keyed by role id; used to build an ObservedSeries for the comparison track.
func get_role_samples() -> Dictionary:
	var out: Dictionary = {}
	if _mapper == null:
		return out
	for role_v: Variant in _mapper.role_to_entity.keys():
		var role: String = str(role_v)
		var eid: String = str(_mapper.role_to_entity[role_v])
		var samples: Array = _timelines.get(eid, []) as Array
		if not samples.is_empty():
			out[role] = samples
	return out


## Resample the loaded datastream onto the absolute-hours grid as an ObservedSeries.
## `clock` is a CelestialClock (for unix→abs conversion).
func build_observed_series(clock: Object, capacity_kwh: float,
		values_in_watts: bool = true) -> RefCounted:
	var series := ObservedSeriesScript.new()
	series.build(get_role_samples(), clock, capacity_kwh, values_in_watts)
	return series


func get_cursor_unix() -> int:
	return int(_cursor_t_unix)


func get_cursor_fraction() -> float:
	if _end_t_unix <= _start_t_unix:
		return 0.0
	return clampf(
		(_cursor_t_unix - float(_start_t_unix))
			/ float(_end_t_unix - _start_t_unix),
		0.0, 1.0)


func set_speed(speed_x: float) -> void:
	_speed_x = maxf(0.0, speed_x)


func get_speed() -> float:
	return _speed_x


## Parse a datastream as an NLE comparison clip: no auto-play, no world-clock
## takeover, no historical-mode latch. Emits clip_ready when parsed.
func load_clip(file_path: String) -> void:
	start(file_path, {"mode": "clip"})


func start(file_path: String, opts: Dictionary = {}) -> void:
	if _state in [State.LOADING, State.PLAYING, State.PAUSED]:
		stop()
	_resolve_runtime_nodes()
	if file_path.is_empty() or not FileAccess.file_exists(file_path):
		push_warning("[CsvHistoryPlayer] File not found: %s" % file_path)
		_set_state(State.IDLE)
		return

	_clip_mode = str(opts.get("mode", "")) == "clip"
	_speed_x = float(opts.get("speed_x", _DEFAULT_SPEED_X))
	_source_path = file_path
	_timelines.clear()
	_cursors.clear()
	_last_pushed.clear()
	_parse_rows_done = 0
	_parse_header_skipped = false
	_start_t_unix = 0
	_end_t_unix = 0
	_cursor_t_unix = 0.0

	_file = FileAccess.open(file_path, FileAccess.READ)
	if _file == null:
		push_warning("[CsvHistoryPlayer] Failed to open: %s" % file_path)
		_set_state(State.IDLE)
		return

	_parse_file_size = int(_file.get_length())
	if not _clip_mode:
		if _sim_mode != null and _sim_mode.has_method("set_historical_active"):
			_sim_mode.set_historical_active(true)
		_suspend_world_clock()
	_set_state(State.LOADING)
	loading_progress.emit(0, maxi(1, _parse_file_size))
	set_process(true)


func pause() -> void:
	if _state == State.PLAYING:
		_set_state(State.PAUSED)


func resume() -> void:
	if _state in [State.READY, State.PAUSED]:
		_set_state(State.PLAYING)


func toggle_play() -> void:
	if _state == State.PLAYING:
		pause()
	elif _state in [State.READY, State.PAUSED]:
		resume()


func seek(fraction: float) -> void:
	if _state in [State.IDLE, State.STOPPED, State.LOADING]:
		return
	var f := clampf(fraction, 0.0, 1.0)
	_cursor_t_unix = float(_start_t_unix) + f * float(_end_t_unix - _start_t_unix)
	_cursors.clear()
	_last_pushed.clear()
	_apply_at_cursor()
	_sync_world_time_from_cursor()
	playback_progress.emit(int(_cursor_t_unix), get_cursor_fraction())


func stop() -> void:
	set_process(false)
	if _file != null:
		_file.close()
		_file = null
	_timelines.clear()
	_cursors.clear()
	_last_pushed.clear()
	_parse_rows_done = 0
	_source_path = ""
	_last_graph_day_key = ""
	_clip_mode = false
	_notify_solar_ui_csv_state()
	if _sim_mode != null and _sim_mode.has_method("set_historical_active"):
		_sim_mode.set_historical_active(false)
	_restore_world_clock()
	_set_state(State.STOPPED)


func _process(delta: float) -> void:
	if _state == State.LOADING:
		_parse_csv_chunk()
		return

	if _state != State.PLAYING:
		return

	_cursor_t_unix += delta * _speed_x
	if _cursor_t_unix >= float(_end_t_unix):
		_cursor_t_unix = float(_end_t_unix)
		_apply_at_cursor()
		_sync_world_time_from_cursor()
		playback_progress.emit(int(_cursor_t_unix), 1.0)
		_set_state(State.PAUSED)
		return

	_apply_at_cursor()
	_sync_world_time_from_cursor()
	playback_progress.emit(int(_cursor_t_unix), get_cursor_fraction())


func _parse_csv_chunk() -> void:
	if _file == null:
		_finalize_load()
		return

	var rows := 0
	while rows < _PARSE_CHUNK_ROWS and _file.get_position() < _file.get_length():
		var line := _file.get_line()
		if line.is_empty():
			continue
		if not _parse_header_skipped:
			_parse_header_skipped = true
			if line.to_lower().begins_with("entity_id"):
				continue
		_parse_csv_line(line)
		rows += 1
		_parse_rows_done += 1

	loading_progress.emit(int(_file.get_position()), maxi(1, _parse_file_size))

	if _file.get_position() >= _file.get_length():
		_file.close()
		_file = null
		_finalize_load()


func _parse_csv_line(line: String) -> void:
	var parts := line.split(",", false, 3)
	if parts.size() < 3:
		return
	var entity_id := str(parts[0]).strip_edges()
	var state_str := str(parts[1]).strip_edges()
	var ts_raw := str(parts[2]).strip_edges()
	if entity_id.is_empty() or state_str in ["unavailable", "unknown", ""]:
		return
	var t_unix := HaTimeUtilScript.utc_iso_to_unix(ts_raw)
	if t_unix <= 0:
		return
	var v := _parse_state_value(state_str)
	if _start_t_unix == 0 or t_unix < _start_t_unix:
		_start_t_unix = t_unix
	if t_unix > _end_t_unix:
		_end_t_unix = t_unix
	var samples: Array = _timelines.get(entity_id, []) as Array
	samples.append({"t": t_unix, "v": v})
	_timelines[entity_id] = samples


func _finalize_load() -> void:
	if _timelines.is_empty():
		push_warning("[CsvHistoryPlayer] No valid rows parsed from CSV.")
		stop()
		_set_state(State.IDLE)
		return

	for eid_v: Variant in _timelines.keys():
		var samples: Array = _timelines[eid_v] as Array
		samples.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("t", 0)) < int(b.get("t", 0))
		)
		_timelines[eid_v] = samples

	_cursor_t_unix = float(_start_t_unix)
	autolink_entities()
	_set_state(State.READY)
	data_ready.emit(_start_t_unix, _end_t_unix, _timelines.size())
	if _clip_mode:
		# NLE clip: leave the world clock alone; the owner builds an ObservedSeries.
		clip_ready.emit(_start_t_unix, _end_t_unix, _timelines.size())
		return
	_cursors.clear()
	_last_pushed.clear()
	_apply_at_cursor()
	_sync_world_time_from_cursor()
	_notify_solar_ui_csv_state()
	_refresh_solar_ui_day_graph()
	_set_state(State.PLAYING)


func _apply_at_cursor() -> void:
	var t_int := int(_cursor_t_unix)
	for eid_v: Variant in _timelines.keys():
		var eid: String = str(eid_v)
		var samples: Array = _timelines[eid] as Array
		if samples.is_empty():
			continue
		var idx: int = int(_cursors.get(eid, 0))
		while idx + 1 < samples.size() \
				and int((samples[idx + 1] as Dictionary).get("t", 0)) <= t_int:
			idx += 1
		while idx > 0 \
				and int((samples[idx] as Dictionary).get("t", 0)) > t_int:
			idx -= 1
		_cursors[eid] = idx
		var sample: Dictionary = samples[idx] as Dictionary
		if int(sample.get("t", 0)) > t_int:
			continue
		var v: float = float(sample.get("v", 0.0))
		var last: Variant = _last_pushed.get(eid, null)
		if last != null and abs(float(last) - v) < 1e-6:
			continue
		_last_pushed[eid] = v
		_push_sample(eid, v, t_int)


func _push_sample(entity_id: String, value: float, t_unix: int) -> void:
	if _ha_client != null and _ha_client.has_signal("sensor_updated"):
		_ha_client.sensor_updated.emit(entity_id, {"state": str(value)})
	if _linker != null and _linker.has_method("apply_historical_value"):
		_linker.apply_historical_value(entity_id, value, "", t_unix)
	if _mapper != null and _solar_ui != null:
		var role: String = _mapper.get_role_for_entity(entity_id)
		if not role.is_empty() and _solar_ui.has_method("apply_csv_playback_reading"):
			_solar_ui.call("apply_csv_playback_reading", role, value)


func _sync_world_time_from_cursor() -> void:
	if _main_node == null:
		return
	if _main_node.has_method("set_world_time_from_unix"):
		_main_node.call("set_world_time_from_unix", int(_cursor_t_unix))
	_maybe_refresh_solar_ui_day_graph()


const CLOCK_OWNER := "csv_playback"


# Claim rather than save/restore: another subsystem (the SoI snowglobe, the
# elevation view) can open on top of playback, and the old private
# _saved_time_scale made each of them snapshot the other's temporary 0.0 and
# restore that. See core/clock_claims.gd.
func _suspend_world_clock() -> void:
	if _main_node == null:
		return
	if _main_node.has_method("push_clock_claim"):
		_main_node.call("push_clock_claim", CLOCK_OWNER, {"time_scale": 0.0})


func _restore_world_clock() -> void:
	if _main_node == null:
		return
	if _main_node.has_method("pop_clock_claim"):
		_main_node.call("pop_clock_claim", CLOCK_OWNER)


func _resolve_runtime_nodes() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if not is_instance_valid(_ha_client):
		_ha_client = tree.root.get_node_or_null("HAClient")
		if _ha_client == null:
			for child in tree.root.get_children():
				var candidate := child.get_node_or_null("HAClient")
				if candidate != null:
					_ha_client = candidate
					break
	if not is_instance_valid(_main_node):
		var sc := tree.current_scene
		if sc != null and ("day_time" in sc or sc.name == "Main"):
			_main_node = sc
		else:
			_main_node = ServiceLocator.main()
	if not is_instance_valid(_solar_ui):
		for p: String in ["Main/UILayer/SolarUI", "UILayer/SolarUI"]:
			var n := tree.root.get_node_or_null(p)
			if n != null:
				_solar_ui = n
				break
		if _solar_ui == null:
			_solar_ui = tree.root.find_child("SolarUI", true, false)
	if _linker == null:
		var graph := tree.root.find_child("SystemGraphView", true, false)
		if graph != null:
			var linker := graph.get_node_or_null("HAEntityLinker")
			if linker != null:
				_linker = linker


func _set_state(s: int) -> void:
	if _state == s:
		return
	_state = s
	state_changed.emit(s)


func _parse_state_value(s: String) -> float:
	var lower := s.to_lower()
	if lower == "on":
		return 1.0
	if lower == "off":
		return 0.0
	return s.to_float()


func _notify_solar_ui_csv_state() -> void:
	_resolve_runtime_nodes()
	if _solar_ui == null or not _solar_ui.has_method("set_csv_playback_active"):
		return
	var active := _state in [State.READY, State.PLAYING, State.PAUSED] and not _timelines.is_empty()
	var linked_roles: Dictionary = {}
	if active and _mapper != null:
		for role_v: Variant in _mapper.role_to_entity.keys():
			linked_roles[str(role_v)] = true
	_solar_ui.call(
		"set_csv_playback_active",
		active,
		linked_roles,
		_source_path,
	)


func _maybe_refresh_solar_ui_day_graph() -> void:
	if _main_node == null:
		return
	var day_key := "%d-%02d-%02d" % [
		int(_main_node.get("year")),
		int(_main_node.get("month")),
		int(_main_node.get("day")),
	]
	if day_key != _last_graph_day_key:
		_refresh_solar_ui_day_graph()


func _refresh_solar_ui_day_graph() -> void:
	if _state in [State.IDLE, State.STOPPED, State.LOADING]:
		return
	if _mapper == null or _solar_ui == null:
		return
	if not _solar_ui.has_method("set_csv_day_graph"):
		return
	var day_range := _local_day_range_unix()
	if day_range.y <= day_range.x:
		return
	_last_graph_day_key = "%d-%02d-%02d" % [
		int(_main_node.get("year")) if _main_node != null else 0,
		int(_main_node.get("month")) if _main_node != null else 0,
		int(_main_node.get("day")) if _main_node != null else 0,
	]
	var values_in_watts := true
	if _solar_ui.get("ha_values_in_watts") != null:
		values_in_watts = bool(_solar_ui.ha_values_in_watts)
	var solar_eid: String = _mapper.get_entity_for_role("solar")
	var load_eid: String = _mapper.get_entity_for_role("load")
	var solar_samples: Array = _timelines.get(solar_eid, []) as Array
	var load_samples: Array = _timelines.get(load_eid, []) as Array
	var solar_kw := _build_hourly_kw_profile(
		solar_samples, day_range.x, day_range.y, values_in_watts,
	)
	var load_kw := _build_hourly_kw_profile(
		load_samples, day_range.x, day_range.y, values_in_watts,
	)
	_solar_ui.call("set_csv_day_graph", solar_kw, load_kw)


func _local_day_range_unix() -> Vector2i:
	if _main_node == null:
		return Vector2i(0, 0)
	var y := int(_main_node.get("year"))
	var m := int(_main_node.get("month"))
	var d := int(_main_node.get("day"))
	var start_dict := {
		"year": y, "month": m, "day": d,
		"hour": 0, "minute": 0, "second": 0,
	}
	var start := int(Time.get_unix_time_from_datetime_dict(start_dict))
	var nd := d + 1
	var nm := m
	var ny := y
	var max_days := 31
	if _main_node.has_method("get_days_in_month"):
		max_days = int(_main_node.call("get_days_in_month", m, y))
	if nd > max_days:
		nd = 1
		nm += 1
		if nm > 12:
			nm = 1
			ny += 1
	var end_dict := {
		"year": ny, "month": nm, "day": nd,
		"hour": 0, "minute": 0, "second": 0,
	}
	var end := int(Time.get_unix_time_from_datetime_dict(end_dict))
	return Vector2i(start, end)


func _build_hourly_kw_profile(
	samples: Array,
	day_start_unix: int,
	day_end_unix: int,
	values_in_watts: bool,
) -> Array:
	var buckets: Array = []
	for _h in range(24):
		buckets.append([] as Array)
	for sample_v: Variant in samples:
		var sample: Dictionary = sample_v as Dictionary
		var t := int(sample.get("t", 0))
		if t < day_start_unix or t >= day_end_unix:
			continue
		var dt := Time.get_datetime_dict_from_unix_time(t)
		var hour := int(dt.get("hour", 0))
		if hour < 0 or hour >= 24:
			continue
		var v := float(sample.get("v", 0.0))
		if values_in_watts and v > 100.0:
			v /= 1000.0
		elif not values_in_watts and v > 50.0:
			# Likely watts despite config — keep graph readable.
			v /= 1000.0
		(buckets[hour] as Array).append(v)
	var out: Array = []
	for h in range(24):
		var bucket: Array = buckets[h] as Array
		if bucket.is_empty():
			out.append(0.0)
			continue
		var total := 0.0
		for val_v: Variant in bucket:
			total += float(val_v)
		out.append(total / float(bucket.size()))
	return out
