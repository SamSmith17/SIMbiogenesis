class_name ChallengeBakeEngine
extends Node

## Deterministic challenge pre-bake + playback + same-segment retry loop.
##
## Instead of running a challenge in real time, the whole span (1 day / 1
## month / 1 year) is computed in a few seconds of chunked fixed-step
## simulation — energy through SolarUI's sim EnergyTimeline (span-scaled
## sample step), resources through ResourceFlowEngine.render_step (the
## deterministic hook selftested in resource_flow_selftest), and population
## through NpcPopulationBridge.tick_at at steps far below the stochastic
## catch-up threshold. The bake stops at the FIRST failure (total power
## failure, colony collapse, stockout), the timeline plays the baked buffers
## back smoothly to the breakpoint, and retry() restores every snapshot and
## replays the SAME segment against the player's edited graph.
##
## Ownership discipline (mirrors the video exporter's "owns the clock" rule):
## while active, world time_scale is 0, the graph view's ambient flow tick is
## suspended (set_ambient_flow_suspended), and SolarUI's battery reads the
## baked series during playback (set_playback_series_active). Every exit path
## — win, abort, interrupt — goes through _release_world().

signal bake_progress(frac: float, cursor_abs: float)
## Bake hit a failure; playback to the breakpoint is starting.
signal bake_failed_at(abs_h: float, reason: String)
## Playback parked at the breakpoint — show the fix-and-retry UI.
signal retry_ready(abs_h: float, reason: String, attempts: int)
## Clean run: bake finished + playback done. result carries score inputs.
signal run_succeeded(result: Dictionary)
signal state_changed

enum Phase { IDLE, BAKING, PLAYBACK, AWAIT_RETRY, DONE }

const STEPS_PER_FRAME := 120
## Real seconds a full-span playback takes (scrub-able; parks at the end).
const PLAYBACK_REAL_S := 20.0
## Power failure = SOC pinned at the hard floor while net < 0, sustained.
const POWER_FAIL_SUSTAIN_H := 0.25
## Population substeps must stay well under the engine's 6 h stochastic
## catch-up threshold and at/below its 0.1 h native substep.
const POP_SUBSTEP_H := 0.1

var _phase: int = Phase.IDLE
var _def: ChallengeDef = null
var _main: Node = null
var _gv: Node = null
var _solar_ui: Node = null
var _flow: RefCounted = null
var _bridge: RefCounted = null
var _series: EnergyTimeline = null

var _start_abs := 0.0
var _end_abs := 0.0
var _step_h := 1.0 / 60.0
var _cursor := 0.0
var _attempts := 0
var _failure: Dictionary = {}
var _power_fail_h := 0.0
var _pot_solar_kwh := 0.0

var _play_from := 0.0
var _play_to := 0.0
var _play_t := 0.0

# Retry snapshots (taken once at start; restored on every retry).
var _specs_snapshot: Dictionary = {}
var _npc_snapshot: Dictionary = {}
var _battery_soc_kwh := 0.0
var _saved_time_scale := 0.0


func _ready() -> void:
	set_process(false)


func phase() -> int:
	return _phase


func is_active() -> bool:
	return _phase != Phase.IDLE and _phase != Phase.DONE


func attempts() -> int:
	return _attempts


func failure() -> Dictionary:
	return _failure.duplicate(true)


## Sample step sized so any span fits EnergyTimeline/ResourceTimeline
## MAX_SAMPLES (20160) with headroom: day → 1 min, month → 4 min, year → 40 min.
static func step_hours_for(duration_h: float) -> float:
	return maxf(1.0 / 60.0, ceilf(duration_h / 14000.0 * 60.0) / 60.0)


func start(main_node: Node, graph_view: Node, solar_ui: Node,
		def: ChallengeDef, start_abs: float) -> bool:
	if is_active() or def == null or main_node == null or graph_view == null \
			or solar_ui == null:
		return false
	_def = def
	_main = main_node
	_gv = graph_view
	_solar_ui = solar_ui
	_flow = _gv.call("resource_flow_engine") if _gv.has_method("resource_flow_engine") else null
	_bridge = _gv.call("npc_population_bridge") if _gv.has_method("npc_population_bridge") else null
	if _flow == null:
		return false
	_start_abs = start_abs
	_end_abs = start_abs + def.resolved_duration_hours()
	_step_h = step_hours_for(def.resolved_duration_hours())
	_attempts = 0

	# Own the world: freeze the clock at the segment start, stand the ambient
	# tick down, pin the playhead.
	_saved_time_scale = float(_main.get("time_scale")) if _main.get("time_scale") != null else 0.0
	_main.set("time_scale", 0.0)
	_main.call("set_absolute_hours", _start_abs)
	_gv.call("set_ambient_flow_suspended", true)

	# Snapshots for the retry loop (dynamic state only — the player's edits
	# BETWEEN attempts are the point and survive).
	_take_snapshots()
	_begin_attempt()
	return true


func retry() -> bool:
	if _phase != Phase.AWAIT_RETRY:
		return false
	_restore_snapshots()
	_begin_attempt()
	return true


## Abort and hand the world back. `commit_end_state` keeps the last baked end
## state on a WIN commit; plain aborts restore the pre-run battery SOC.
func abort(commit_end_state: bool = false) -> void:
	if _phase == Phase.IDLE:
		return
	if not commit_end_state:
		_restore_snapshots()
		if _main != null:
			_main.call("set_absolute_hours", _start_abs)
		if _solar_ui != null and _solar_ui.has_method("reanchor_live_battery"):
			_solar_ui.call("reanchor_live_battery", _battery_soc_kwh)
	_release_world()
	_phase = Phase.DONE
	set_process(false)
	state_changed.emit()


func _begin_attempt() -> void:
	_attempts += 1
	_failure = {}
	_power_fail_h = 0.0
	_pot_solar_kwh = 0.0
	_cursor = _start_abs
	if _main != null:
		_main.call("set_absolute_hours", _start_abs)
	if _solar_ui.has_method("set_playback_series_active"):
		_solar_ui.call("set_playback_series_active", false)
	_series = _solar_ui.call("prepare_challenge_series", _start_abs, _step_h)
	if _flow.has_method("clear_timelines"):
		_flow.call("clear_timelines")
	_phase = Phase.BAKING
	set_process(true)
	state_changed.emit()


func _process(delta: float) -> void:
	match _phase:
		Phase.BAKING:
			_bake_chunk()
		Phase.PLAYBACK:
			_playback_step(delta)
		_:
			pass


func _bake_chunk() -> void:
	var budget := STEPS_PER_FRAME
	var model: GraphModel = _gv.get("model")
	# Every render/population step writes item specs — run the whole chunk
	# under the same history/bulk suppression the ambient tick uses, or 14k
	# steps of telemetry would flood undo history and redraws.
	var was_suppress: bool = bool(_gv.get("_history_suppress"))
	var was_bulk: bool = bool(_gv.get("_sim_bulk_update"))
	_gv.set("_history_suppress", true)
	_gv.set("_sim_bulk_update", true)
	while budget > 0 and _cursor < _end_abs - 1e-9 and _failure.is_empty():
		_cursor = minf(_cursor + _step_h, _end_abs)
		# 1) Energy: fill the sim series up to the cursor.
		_series.fill_forward_chunk(_series.step_of(_cursor), 1 << 30)
		var s := _series.sample_at(_cursor)
		var soc := float(s.get("soc_kwh", 0.0))
		var net := float(s.get("solar_kw", 0.0)) + float(s.get("aux_kw", 0.0)) \
				- float(s.get("load_kw", 0.0))
		var floor_kwh := float(_solar_ui.call("min_battery_kwh"))
		var ac := soc > floor_kwh + 1e-4
		# PV-utilization denominator: what the sky offered, unclipped.
		_pot_solar_kwh += float(_solar_ui.call("evaluate_potential_solar_at", _cursor)) * _step_h
		# 2) Population (before flow, mirroring the ambient tick's order).
		if _bridge != null and bool(_bridge.call("has_pop_driven")):
			var t := _cursor - _step_h
			while t < _cursor - 1e-9:
				var sub := minf(POP_SUBSTEP_H, _cursor - t)
				t += sub
				_bridge.call("tick_at", model, _flow, _main, t)
			for e in (_bridge.call("take_events") as Array):
				var kind := str((e as Dictionary).get("kind", ""))
				if _def.fail_on_collapse and (kind == "collapsed" or kind == "deserted"):
					_failure = {"abs_h": _cursor, "reason": "colony_collapsed"}
		# 3) Resources (deterministic render step with injected AC).
		_flow.call("render_step", _cursor, _step_h, ac)
		# 4) Failure predicates.
		if _failure.is_empty():
			_failure = _detect_failure(soc, net, floor_kwh, model)
		budget -= 1
	_gv.set("_history_suppress", was_suppress)
	_gv.set("_sim_bulk_update", was_bulk)
	if _gv.has_method("_flush_sim_bulk_update"):
		_gv.call("_flush_sim_bulk_update")
	var span := maxf(_end_abs - _start_abs, 1e-6)
	bake_progress.emit(clampf((_cursor - _start_abs) / span, 0.0, 1.0), _cursor)
	if not _failure.is_empty():
		_solar_ui.call("finish_challenge_series", _cursor)
		bake_failed_at.emit(float(_failure.get("abs_h", _cursor)), str(_failure.get("reason", "")))
		_begin_playback(float(_failure.get("abs_h", _cursor)))
	elif _cursor >= _end_abs - 1e-9:
		_solar_ui.call("finish_challenge_series", _end_abs)
		_begin_playback(_end_abs)


## Total power failure accumulator: SOC hard-clamped at the floor while demand
## is unserved (the floor clamp means SOC never reads below it — detect the
## PIN, not zero). Pure static so the selftest can drive canned series.
static func power_fail_accumulate(acc_h: float, soc: float, net: float,
		floor_kwh: float, step_h: float) -> float:
	if soc <= floor_kwh + 1e-4 and net < -1e-6:
		return acc_h + step_h
	return 0.0


func _detect_failure(soc: float, net: float, floor_kwh: float,
		model: GraphModel) -> Dictionary:
	# Sustained so a single dusk minute doesn't fail a whole run.
	if _def.fail_on_power_failure:
		_power_fail_h = power_fail_accumulate(_power_fail_h, soc, net, floor_kwh, _step_h)
		if _power_fail_h >= POWER_FAIL_SUSTAIN_H - 1e-9:
			return {"abs_h": _cursor, "reason": "power_failure"}
	# Stockouts: the flow engine writes starved_kinds onto habitats each step.
	if model != null and (_def.fail_on_starvation or not _def.fail_on_kinds.is_empty()):
		for item in model.items_of_type("processor"):
			var sp: Dictionary = (item as Dictionary).get("specs", {}) as Dictionary
			if str(sp.get("role", "")) != "habitat":
				continue
			var starved: Array = sp.get("starved_kinds", []) as Array
			if starved.is_empty():
				continue
			if _def.fail_on_starvation:
				return {"abs_h": _cursor, "reason": "starvation"}
			for kind in _def.fail_on_kinds:
				if str(kind) in starved.map(func(v: Variant) -> String: return str(v)):
					return {"abs_h": _cursor, "reason": "stockout_%s" % str(kind)}
	return {}


func _begin_playback(to_abs: float) -> void:
	_phase = Phase.PLAYBACK
	_play_from = _start_abs
	_play_to = maxf(to_abs, _start_abs + 1e-6)
	_play_t = _start_abs
	_solar_ui.call("set_playback_series_active", true)
	state_changed.emit()


func _playback_step(delta: float) -> void:
	var span := _end_abs - _start_abs
	_play_t = minf(_play_t + span * delta / PLAYBACK_REAL_S, _play_to)
	_main.call("set_absolute_hours", _play_t)
	if _flow.has_method("seek_all_tanks"):
		_flow.call("seek_all_tanks", _play_t)
	if _play_t < _play_to - 1e-9:
		return
	# Parked.
	if _failure.is_empty():
		_finish_success()
	else:
		_phase = Phase.AWAIT_RETRY
		set_process(false)
		retry_ready.emit(float(_failure.get("abs_h", _play_to)),
			str(_failure.get("reason", "")), _attempts)
		state_changed.emit()


func _finish_success() -> void:
	var delivered_kwh := 0.0
	var load_kwh := 0.0
	var start_soc := _battery_soc_kwh
	var end_soc := _battery_soc_kwh
	if _series != null:
		delivered_kwh = float(_series.integrate_channel(_start_abs, _end_abs, "solar"))
		load_kwh = float(_series.integrate_channel(_start_abs, _end_abs, "load"))
		start_soc = float(_series.sample_at(_start_abs).get("soc_kwh", start_soc))
		end_soc = float(_series.sample_at(_end_abs).get("soc_kwh", end_soc))
	var util := 100.0
	if _pot_solar_kwh > 1e-6:
		util = clampf(delivered_kwh / _pot_solar_kwh * 100.0, 0.0, 100.0)
	# "Useful" utilization — the tutorial's real lesson. The solar channel
	# records what the array GENERATED, but a full battery silently drops the
	# charge at the clamp, so generated/potential reads high even when the sun
	# is wasted. Energy that actually did something = loads served + net
	# charge banked; against the sky's offer, that is the number dump loads
	# and automation raise.
	var useful_kwh := load_kwh + maxf(end_soc - start_soc, 0.0)
	var useful_util := 100.0
	if _pot_solar_kwh > 1e-6:
		useful_util = clampf(useful_kwh / _pot_solar_kwh * 100.0, 0.0, 100.0)
	# Commit the run: the world continues from the segment end.
	if _solar_ui.has_method("reanchor_live_battery"):
		_solar_ui.call("reanchor_live_battery", end_soc)
	_release_world()
	_phase = Phase.DONE
	set_process(false)
	run_succeeded.emit({
		"utilization_pct": util,
		"useful_utilization_pct": useful_util,
		"useful_kwh": useful_kwh,
		"solar_kwh": delivered_kwh,
		"load_kwh": load_kwh,
		"potential_kwh": _pot_solar_kwh,
		"start_soc_kwh": start_soc,
		"end_soc_kwh": end_soc,
		"attempts": _attempts,
		"elapsed_h": _end_abs - _start_abs,
		"span": _def.span,
	})
	state_changed.emit()


func _take_snapshots() -> void:
	_specs_snapshot.clear()
	var model: GraphModel = _gv.get("model")
	if model != null:
		for item in GraphNesting.walk_items(model, "root"):
			if item is Dictionary:
				_specs_snapshot[str((item as Dictionary).get("id", ""))] = \
					((item as Dictionary).get("specs", {}) as Dictionary).duplicate(true)
	_npc_snapshot = (_bridge.call("snapshot_all", _start_abs) as Dictionary) \
			if _bridge != null else {}
	_battery_soc_kwh = float(_solar_ui.call("get_battery_kwh_stored"))


## Restore DYNAMIC state (tank stocks, SOCs, faults, population) for items
## that still exist. Items the player added/removed/rewired between attempts
## keep their new wiring — that is the whole point of the retry loop.
func _restore_snapshots() -> void:
	var model: GraphModel = _gv.get("model")
	if model != null:
		# Bulk state rewrite — suppress per-item history/undo churn exactly the
		# way the sim ticks do.
		var was_suppress: bool = bool(_gv.get("_history_suppress"))
		var was_bulk: bool = bool(_gv.get("_sim_bulk_update"))
		_gv.set("_history_suppress", true)
		_gv.set("_sim_bulk_update", true)
		for iid in _specs_snapshot:
			if not model.get_item(str(iid)).is_empty():
				model.update_item(str(iid),
					{"specs": (_specs_snapshot[iid] as Dictionary).duplicate(true)})
		_gv.set("_history_suppress", was_suppress)
		_gv.set("_sim_bulk_update", was_bulk)
		if _gv.has_method("_flush_sim_bulk_update"):
			_gv.call("_flush_sim_bulk_update")
	if _bridge != null and not _npc_snapshot.is_empty():
		_bridge.call("restore_all", _npc_snapshot)
	if _flow != null and _flow.has_method("clear_timelines"):
		_flow.call("clear_timelines")
	if _solar_ui != null and _solar_ui.has_method("reanchor_live_battery"):
		_solar_ui.call("reanchor_live_battery", _battery_soc_kwh)


func _release_world() -> void:
	if _solar_ui != null:
		if _solar_ui.has_method("release_challenge_series"):
			_solar_ui.call("release_challenge_series")
	if _gv != null and _gv.has_method("set_ambient_flow_suspended"):
		_gv.call("set_ambient_flow_suspended", false)
	if _main != null:
		_main.set("time_scale", _saved_time_scale)