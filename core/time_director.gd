extends Node
## TimeDirector — the single authority over simulation time, mode, and the
## provenance of whatever the user is currently looking at.
##
## It owns three numbers and one state machine:
##   • now_abs_hours      — real wall-clock NOW, in absolute hours (the anchor).
##   • playhead_abs_hours — the current sim time (mirrors main.gd's clock).
##   • mode               — LIVE / PLAYBACK / SIMULATE (see below).
##   • provenance_at(h)   — REAL / OBSERVED / PROJECTED / RECORDED for any time.
##
## Modes:
##   LIVE      — mirroring the real world at ~1× real time, viewing "now".
##   PLAYBACK  — replaying recorded history (CSV / HA timelines).
##   SIMULATE  — projecting forward, paused, fast-forwarding, or scrubbing.
##
## Mode resolution order (highest priority first):
##   1. PLAYBACK while a history latch is active (set_historical_active).
##   2. An explicit user pin (set_explicit_mode) — the mode chips / TimeUI.
##   3. Heuristic auto-resolution (the legacy SimMode rules) when unpinned.
##
## core/sim_mode.gd is now a thin compatibility shim that forwards to this
## node, so existing consumers (HAEntityLinker, HAClient, graph_canvas, …)
## keep calling SimMode.is_live()/should_apply_live_data()/etc unchanged.

enum Mode { LIVE, PLAYBACK, SIMULATE }
enum Provenance { REAL, OBSERVED, PROJECTED, RECORDED }

signal mode_changed(new_mode: int)
signal playhead_changed(abs_hours: float)
signal now_changed(abs_hours: float)

const REALTIME_SCALE_REF := 1.0 / 3600.0
const REALTIME_THRESHOLD := REALTIME_SCALE_REF * 1.5
const HOURS_IN_DAY := 24.0

## How close (in hours) the playhead must be to NOW to count as REAL in LIVE mode.
const NOW_EPSILON_HOURS := 1.0 / 60.0   # one sim-minute

const SOLAR_UI_PATHS := ["Main/UILayer/SolarUI", "UILayer/SolarUI"]

## -1 means "auto-resolve"; otherwise a pinned Mode value.
var _explicit_mode: int = -1
var _historical_active: bool = false
var _effective_mode: int = Mode.SIMULATE

var now_abs_hours: float = 0.0
var playhead_abs_hours: float = 0.0

## Observed-vs-simulated comparison overlay (not a 4th mode — rides on PLAYBACK/
## SIMULATE). `_obs_range_*` marks the absolute-hours span of an imported
## datastream clip so provenance reads OBSERVED inside it.
var _compare_active: bool = false
var _obs_range_start: float = NAN
var _obs_range_end: float = NAN

var _solar_ui: Node = null
var _main_node: Node = null

const _POLL_SEC: float = 0.05
var _poll_left: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep tracking while the game is paused
	now_abs_hours = _system_now_abs_hours()
	_effective_mode = _compute_mode()
	mode_changed.emit(_effective_mode)
	_poll_left = _POLL_SEC


func _process(delta: float) -> void:
	_poll_left -= delta
	if _poll_left > 0.0:
		return
	_poll_left = _POLL_SEC

	# Real wall clock advances independently of sim time.
	var n := _system_now_abs_hours()
	if absf(n - now_abs_hours) > 1e-6:
		now_abs_hours = n
		now_changed.emit(now_abs_hours)

	# Playhead follows main.gd's reversible clock.
	if _main_node != null and is_instance_valid(_main_node) and _main_node.has_method("get_absolute_hours"):
		var p := float(_main_node.call("get_absolute_hours"))
		if absf(p - playhead_abs_hours) > 1e-6:
			playhead_abs_hours = p
			playhead_changed.emit(playhead_abs_hours)

	var m := _compute_mode()
	if m != _effective_mode:
		_effective_mode = m
		mode_changed.emit(m)


# ---------------------------------------------------------------------------
# Public API — mode
# ---------------------------------------------------------------------------

func current_mode() -> int:
	return _effective_mode

func is_live() -> bool:
	return _effective_mode == Mode.LIVE

func is_playback() -> bool:
	return _effective_mode == Mode.PLAYBACK

func is_sim() -> bool:
	return _effective_mode == Mode.SIMULATE

func should_apply_live_data() -> bool:
	return is_live()

func should_run_realworld_actions() -> bool:
	return is_live()


## Pin the mode explicitly (mode chips / TimeUI). Pass -1 to return to auto.
func set_explicit_mode(mode: int) -> void:
	if _explicit_mode == mode:
		return
	_explicit_mode = mode
	_force_recompute()


## Clear the explicit pin and let the heuristics decide again.
func clear_explicit_mode() -> void:
	set_explicit_mode(-1)


func has_explicit_mode() -> bool:
	return _explicit_mode != -1


## Latched by the history players while replaying recorded data.
func set_historical_active(active: bool) -> void:
	if _historical_active == active:
		return
	_historical_active = active
	_force_recompute()


# ---------------------------------------------------------------------------
# Public API — timecode + provenance
# ---------------------------------------------------------------------------

## Mark / clear the absolute-hours span covered by an imported observed clip.
func register_observed_range(start_abs: float, end_abs: float) -> void:
	_obs_range_start = minf(start_abs, end_abs)
	_obs_range_end = maxf(start_abs, end_abs)

func clear_observed_range() -> void:
	_obs_range_start = NAN
	_obs_range_end = NAN

func has_observed_range() -> bool:
	return not is_nan(_obs_range_start)


## Toggle the split-screen observed-vs-simulated overlay.
func set_compare_active(active: bool) -> void:
	_compare_active = active

func is_compare_active() -> bool:
	return _compare_active


## What kind of data backs the given absolute time, for UI labelling.
func provenance_at(abs_hours: float) -> int:
	if _effective_mode == Mode.PLAYBACK:
		return Provenance.RECORDED
	# Inside an imported datastream clip we have real measured data.
	if not is_nan(_obs_range_start) and abs_hours >= _obs_range_start and abs_hours <= _obs_range_end:
		return Provenance.OBSERVED
	if abs_hours > now_abs_hours + NOW_EPSILON_HOURS:
		return Provenance.PROJECTED
	if _effective_mode == Mode.LIVE and absf(abs_hours - now_abs_hours) <= NOW_EPSILON_HOURS:
		return Provenance.REAL
	# At or before NOW: real-world observations exist for this time.
	return Provenance.OBSERVED


## Provenance of the current playhead — what the user is looking at right now.
func playhead_provenance() -> int:
	return provenance_at(playhead_abs_hours)


func mode_label(mode: int = -100) -> String:
	var m := _effective_mode if mode == -100 else mode
	match m:
		Mode.LIVE:     return "LIVE"
		Mode.PLAYBACK: return "PLAYBACK"
		Mode.SIMULATE: return "SIM"
	return "SIM"


func provenance_label(prov: int) -> String:
	match prov:
		Provenance.REAL:      return "REAL"
		Provenance.OBSERVED:  return "OBSERVED"
		Provenance.PROJECTED: return "PROJECTED"
		Provenance.RECORDED:  return "RECORDED"
	return "?"


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _force_recompute() -> void:
	var m := _compute_mode()
	if m != _effective_mode:
		_effective_mode = m
		mode_changed.emit(m)
	_poll_left = _POLL_SEC


func _compute_mode() -> int:
	_resolve_nodes()
	# 1) History latch wins over everything else.
	if _historical_active:
		return Mode.PLAYBACK
	# 2) Explicit user pin.
	if _explicit_mode != -1:
		return _explicit_mode
	# 3) Heuristic auto-resolution (legacy SimMode rules).
	if _solar_ui != null and _solar_ui.has_method("is_simulating_from_live"):
		if bool(_solar_ui.call("is_simulating_from_live")):
			return Mode.SIMULATE
	if _solar_ui != null and _solar_ui.has_method("is_in_live_mode"):
		if not bool(_solar_ui.call("is_in_live_mode")):
			return Mode.SIMULATE
	if _main_node != null:
		var ts: Variant = _main_node.get("time_scale")
		if ts != null and float(ts) > REALTIME_THRESHOLD:
			return Mode.SIMULATE
		if ts != null and float(ts) <= 0.0:
			return Mode.SIMULATE
	return Mode.LIVE


func _resolve_nodes() -> void:
	var tr := get_tree()
	if tr == null:
		return
	var sc: Node = tr.current_scene
	if sc == null or str(sc.name) != "Main":
		_solar_ui = null
		_main_node = null
		return
	if _solar_ui != null and not is_instance_valid(_solar_ui):
		_solar_ui = null
	if _main_node != null and not is_instance_valid(_main_node):
		_main_node = null
	if _solar_ui == null:
		for p in SOLAR_UI_PATHS:
			var n := tr.root.get_node_or_null(p)
			if n != null and is_instance_valid(n):
				_solar_ui = n
				break
	if _main_node == null:
		if sc != null and str(sc.name) == "Main":
			_main_node = sc
		else:
			var m := tr.root.get_node_or_null("Main")
			if m != null and is_instance_valid(m):
				_main_node = m


# Pure absolute-hours helpers (proleptic Gregorian, year 1 Jan 1 = 0h).
# Mirrors CelestialClock so TimeDirector stays independent of autoload order.

func _system_now_abs_hours() -> float:
	var dt := Time.get_datetime_dict_from_system()
	var y: int = int(dt.get("year", 2026))
	var mo: int = int(dt.get("month", 1))
	var d: int = int(dt.get("day", 1))
	var hours := float(dt.get("hour", 0)) + float(dt.get("minute", 0)) / 60.0 + float(dt.get("second", 0)) / 3600.0
	return _abs_hours(y, mo, d, hours)

func _abs_hours(y: int, mo: int, d: int, hours: float) -> float:
	return float(_days_before_year(y) + _day_of_year(mo, d, y) - 1) * HOURS_IN_DAY + hours

func _days_before_year(y: int) -> int:
	var yy := y - 1
	return 365 * yy + yy / 4 - yy / 100 + yy / 400

func _is_leap(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)

func _days_in_month(m: int, y: int) -> int:
	match m:
		1, 3, 5, 7, 8, 10, 12: return 31
		4, 6, 9, 11: return 30
		2: return 29 if _is_leap(y) else 28
	return 31

func _day_of_year(mo: int, d: int, y: int) -> int:
	var days := 0
	for m in range(1, mo):
		days += _days_in_month(m, y)
	return days + d
