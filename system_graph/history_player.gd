class_name HistoryPlayer
extends Node
## Replays recorded Home Assistant sensor history through the existing HA
## Entity Linker, so the canvas can scrub backwards in time and watch the
## real system unfold over the past N days.
##
## Lifecycle:
##   1. start(opts)        — discover linked HA entities, fetch raw history
##                           via HAClient.get_entity_history, parse into per-
##                           entity timelines.
##   2. PLAYING / PAUSED   — cursor advances on _process and the most-recent
##                           sample at-or-before the cursor is pushed into
##                           the graph through linker.apply_historical_value.
##   3. seek(fraction)     — instantaneous jump along the loaded window.
##   4. stop()             — clear timelines, release the SimMode latch, the
##                           linker is once again driven by live HA pushes.
##
## Proof-of-concept choices:
##   - One global request window (default 72 h back to "now").
##   - Step interpolation only (latest sample wins until the next change).
##   - All linked roles loaded in parallel; first response can start play.
##   - On real-network errors we still play whatever loaded successfully.

signal state_changed(state: int)
signal loading_progress(loaded: int, total: int)
signal data_ready(window_start_unix: int, window_end_unix: int)
signal playback_progress(cursor_t_unix: int, fraction: float)

enum State { IDLE, LOADING, READY, PLAYING, PAUSED, STOPPED }

const _DEFAULT_HOURS_BACK := 72
const _DEFAULT_SPEED_X    := 60.0   # 60 sim-seconds per real second
const _LOAD_TIMEOUT_S     := 15.0
const _HaTimeUtil := preload("res://core/ha_time_util.gd")

var _model:     GraphModel = null
var _linker:    Node       = null
var _ha_client: Node       = null
var _sim_mode:  Node       = null

var _state: int = State.IDLE

var _hours_back:    int   = _DEFAULT_HOURS_BACK
var _speed_x:       float = _DEFAULT_SPEED_X
var _start_t_unix:  int   = 0
var _end_t_unix:    int   = 0
var _cursor_t_unix: float = 0.0      # float for sub-second accuracy

## entity_id → Array of {t: int (unix seconds), v: float, u: String}
var _timelines: Dictionary = {}
## entity_id → cursor index pointer (advance-only; reset on seek)
var _cursors:   Dictionary = {}
## entity_id → last value pushed through linker (used to skip duplicates)
var _last_pushed: Dictionary = {}
## entity_id → unit cached from first valid sample (HA history sometimes
## omits unit_of_measurement; we still want _mirror_to_spec to receive it).
var _units: Dictionary = {}

var _pending_entities: Dictionary = {}   # set: entity_id → true
var _expected_total:   int        = 0
var _loaded_total:     int        = 0
var _load_deadline:    float      = 0.0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func setup(model: GraphModel, linker: Node, ha_client: Node) -> void:
	_model     = model
	_linker    = linker
	_ha_client = ha_client
	_sim_mode  = get_node_or_null("/root/SimMode")
	if _ha_client != null and _ha_client.has_signal("raw_history_received"):
		if not _ha_client.raw_history_received.is_connected(_on_history_received):
			_ha_client.raw_history_received.connect(_on_history_received)


func get_state() -> int:
	return _state


func get_window_unix() -> Vector2i:
	return Vector2i(_start_t_unix, _end_t_unix)


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


## Begin a fresh history-playback session.
##   opts:
##     hours_back: int    — how far back to fetch (default 72)
##     speed_x:    float  — playback speed multiplier (default 60)
func start(opts: Dictionary = {}) -> void:
	if _state in [State.LOADING, State.PLAYING, State.PAUSED]:
		stop()
	_hours_back = int(opts.get("hours_back", _DEFAULT_HOURS_BACK))
	_speed_x    = float(opts.get("speed_x",    _DEFAULT_SPEED_X))
	_timelines.clear()
	_cursors.clear()
	_last_pushed.clear()
	_units.clear()
	_pending_entities.clear()
	_expected_total = 0
	_loaded_total   = 0

	var entity_ids := _collect_linked_entities()
	if entity_ids.is_empty():
		push_warning("[HistoryPlayer] No HA-linked entities found in graph.")
		_set_state(State.IDLE)
		return
	if _ha_client == null:
		push_warning("[HistoryPlayer] No HA client.")
		_set_state(State.IDLE)
		return

	_end_t_unix    = int(Time.get_unix_time_from_system())
	_start_t_unix  = _end_t_unix - _hours_back * 3600
	_cursor_t_unix = float(_start_t_unix)

	# Activate HISTORICAL mode immediately so live HA pushes are silenced.
	if _sim_mode != null and _sim_mode.has_method("set_historical_active"):
		_sim_mode.set_historical_active(true)

	_set_state(State.LOADING)
	var start_iso := _unix_to_iso(_start_t_unix)
	var end_iso   := _unix_to_iso(_end_t_unix)
	_expected_total = entity_ids.size()
	_load_deadline = Time.get_ticks_msec() / 1000.0 + _LOAD_TIMEOUT_S
	for eid in entity_ids:
		_pending_entities[eid] = true
		_ha_client.get_entity_history(eid, start_iso, end_iso, true)
	loading_progress.emit(_loaded_total, _expected_total)
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
	# Reset per-entity cursors so the scan re-evaluates the new position.
	_cursors.clear()
	_last_pushed.clear()
	_apply_at_cursor()
	playback_progress.emit(int(_cursor_t_unix), get_cursor_fraction())


func stop() -> void:
	set_process(false)
	_timelines.clear()
	_cursors.clear()
	_last_pushed.clear()
	_units.clear()
	_pending_entities.clear()
	_expected_total = 0
	_loaded_total   = 0
	if _sim_mode != null and _sim_mode.has_method("set_historical_active"):
		_sim_mode.set_historical_active(false)
	_set_state(State.STOPPED)


# ---------------------------------------------------------------------------
# Tick loop
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	# Loading-timeout guard: if any entities are still pending after the
	# deadline, kick playback off with whatever we have.
	if _state == State.LOADING:
		var now := Time.get_ticks_msec() / 1000.0
		if now >= _load_deadline and not _pending_entities.is_empty():
			push_warning("[HistoryPlayer] Load timeout; %d entities never returned." %
				_pending_entities.size())
			_pending_entities.clear()
			_finalize_load()
		return

	if _state != State.PLAYING:
		return

	_cursor_t_unix += delta * _speed_x
	if _cursor_t_unix >= float(_end_t_unix):
		_cursor_t_unix = float(_end_t_unix)
		_apply_at_cursor()
		playback_progress.emit(int(_cursor_t_unix), 1.0)
		_set_state(State.PAUSED)   # park at the end; user can restart
		return
	_apply_at_cursor()
	playback_progress.emit(int(_cursor_t_unix), get_cursor_fraction())


# ---------------------------------------------------------------------------
# History response handling
# ---------------------------------------------------------------------------

func _on_history_received(entity_id: String, history: Array) -> void:
	if not _pending_entities.has(entity_id):
		return     # stale response from an older session
	_pending_entities.erase(entity_id)
	_loaded_total += 1
	loading_progress.emit(_loaded_total, _expected_total)

	var samples: Array = []
	for entry_v: Variant in history:
		if not (entry_v is Dictionary):
			continue
		var entry: Dictionary = entry_v
		var state_raw: Variant = entry.get("s", entry.get("state", null))
		var ts_raw:    Variant = entry.get("lu", entry.get("last_updated",
			entry.get("lc", entry.get("last_changed", null))))
		if state_raw == null or ts_raw == null:
			continue
		var s_str: String = str(state_raw)
		if s_str in ["unavailable", "unknown", ""]:
			continue
		var v: float = _parse_state_value(s_str)
		var t_unix: int = _HaTimeUtil.utc_iso_to_unix(ts_raw)
		if t_unix <= 0:
			continue
		samples.append({"t": t_unix, "v": v})
		# Cache unit if attached.
		var attrs: Variant = entry.get("a", entry.get("attributes", null))
		if attrs is Dictionary:
			var unit: String = str((attrs as Dictionary).get("unit_of_measurement", ""))
			if not unit.is_empty() and not _units.has(entity_id):
				_units[entity_id] = unit
	# HA usually returns chronological order, but sort defensively.
	samples.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("t", 0)) < int(b.get("t", 0))
	)
	_timelines[entity_id] = samples

	if _pending_entities.is_empty():
		_finalize_load()


func _finalize_load() -> void:
	# Trim or extend window to the actual data span if needed.
	# For PoC we keep the requested window (so the scrubber maps cleanly to
	# wall-clock time even when some entities have less history).
	_set_state(State.READY)
	data_ready.emit(_start_t_unix, _end_t_unix)
	# Start playing immediately for the proof-of-concept.
	_set_state(State.PLAYING)


# ---------------------------------------------------------------------------
# Per-tick application
# ---------------------------------------------------------------------------

func _apply_at_cursor() -> void:
	if _linker == null:
		return
	var t_int := int(_cursor_t_unix)
	for eid_v: Variant in _timelines.keys():
		var eid: String = str(eid_v)
		var samples: Array = _timelines[eid] as Array
		if samples.is_empty():
			continue
		var idx: int = int(_cursors.get(eid, 0))
		# Advance idx forward while the next sample is still <= cursor.
		while idx + 1 < samples.size() \
				and int((samples[idx + 1] as Dictionary).get("t", 0)) <= t_int:
			idx += 1
		# But also handle backwards seeks: if the current idx sample is
		# beyond the cursor, walk back.
		while idx > 0 \
				and int((samples[idx] as Dictionary).get("t", 0)) > t_int:
			idx -= 1
		_cursors[eid] = idx
		var sample: Dictionary = samples[idx] as Dictionary
		# If the only sample is in the future from the cursor, push 0 (or skip).
		if int(sample.get("t", 0)) > t_int:
			continue
		var v: float = float(sample.get("v", 0.0))
		var last: Variant = _last_pushed.get(eid, null)
		if last != null and abs(float(last) - v) < 1e-6:
			continue   # nothing changed; skip redundant linker call
		_last_pushed[eid] = v
		var unit: String = str(_units.get(eid, ""))
		_linker.apply_historical_value(eid, v, unit, t_int)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _set_state(s: int) -> void:
	if _state == s:
		return
	_state = s
	state_changed.emit(s)


func _collect_linked_entities() -> Array[String]:
	var out: Array[String] = []
	# The world's Live links (HAEntityLinker) — specs.ha_links is the old
	# place, read only for graphs that were never migrated.
	if _linker != null and _linker.has_method("linked_entity_ids"):
		for e in _linker.call("linked_entity_ids"):
			if not out.has(str(e)):
				out.append(str(e))
		if not out.is_empty():
			return out
	if _model == null:
		return out
	var seen: Dictionary = {}
	for it: Dictionary in _model.items:
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var links: Dictionary = (specs.get("ha_links", {}) as Dictionary)
		for role: String in links.keys():
			var eid: String = str(links[role]).strip_edges()
			if eid.is_empty() or seen.has(eid):
				continue
			seen[eid] = true
			out.append(eid)
	return out


func _parse_state_value(s: String) -> float:
	var lower := s.to_lower()
	if lower == "on":
		return 1.0
	if lower == "off":
		return 0.0
	return s.to_float()


func _unix_to_iso(t_unix: int) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(t_unix)
	return "%04d-%02d-%02dT%02d:%02d:%02d+00:00" % [
		dt["year"], dt["month"], dt["day"],
		dt["hour"], dt["minute"], dt["second"],
	]
