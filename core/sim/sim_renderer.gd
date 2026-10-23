class_name SimRenderer
extends Node

## The timeline's Render button: pre-compute the whole simulation from the
## playhead to `end_abs` into the LIVE caches, so the ambient tick can REPLAY
## that range instead of simulating it (CLAUDE.md "Sim pre-render + playback").
##
## What a render does, in order:
##   * refuses while LIVE (HA measurements are authoritative there), while any
##     other system owns the clock (a bake, the video export), inside the
##     tutorial sandbox, or for a range that ends at or before the playhead;
##   * owns the world like the challenge bake does — an exclusive clock claim
##     at time_scale 0 (time stands still; the player can still walk), the
##     ambient flow tick suspended, the pond twin push blocked, NPC tiers
##     frozen so every roster can be restored — and snapshots everything the
##     render will move: item specs, the NPC rosters, the battery, the flow
##     engine's between-step state, the camp power integrators;
##   * cuts every cache at the playhead (`EnergyTimeline.truncate_after`,
##     `ResourceFlowEngine.truncate_timelines_after`, `SimRenderCache.
##     begin_range`), then steps `SimBakeStepper` on a per-frame time budget,
##     reporting progress; the energy evaluator is SolarUI.make_sim_render_
##     evaluator (the SAME GraphAcLoad the live tick integrates, hydro fed
##     back into the battery);
##   * on finish OR cancel (a partial render is kept, as Premiere keeps a
##     partial preview): restores the specs, replays the tanks + hydro at the
##     playhead, applies the first keyframe, restores the rosters / engine
##     state / camp power / battery read cursor, hands the clock back, pushes
##     the pond twins once, and registers the range.
##
## Inside a rendered range the view's ambient tick calls `replay_at`, SolarUI
## reads the rendered SOC + readouts, and a player edit (GraphModel.user_rev)
## truncates the range at the playhead — see SystemGraphView.

signal render_started(start_abs: float, end_abs: float)
signal render_progress(frac: float, eta_s: float, cursor_abs: float)
signal render_finished(ok: bool, start_abs: float, end_abs: float)
signal cache_changed

const CLOCK_OWNER := "sim_render"
## The live timelines are a fixed 1-min grid of 20160 samples INCLUDING the
## history behind the playhead (EnergyTimeline / ResourceTimeline MAX_SAMPLES),
## so a render longer than this would trim its own start.
const MAX_RENDER_H := 7.0 * 24.0
const DEFAULT_RENDER_H := 24.0
## Real milliseconds of stepping per frame (the rest of the frame keeps
## drawing, so the progress card moves instead of the game stalling).
## Measured on Mount Vernon: ~3 s of stepping per 24 h; at 12 ms a frame the
## render took 8.3 s wall, so the budget is most of a frame.
const FRAME_BUDGET_MS := 24.0

var cache := SimRenderCache.new()

var _gv: Node = null
var _main: Node = null
var _solar: Node = null
var _flow: RefCounted = null
var _bridge: RefCounted = null
var _stepper: SimBakeStepper = null

var _active := false
var _start_abs := 0.0
var _end_abs := 0.0
var _cursor := 0.0
var _t_started_ms := 0
var _steps_done := 0

var _specs_snapshot: Dictionary = {}
var _npc_snapshot: Dictionary = {}
var _flow_snapshot: Dictionary = {}
var _camp_snapshot: Dictionary = {}
var _battery_kwh := 0.0


func _ready() -> void:
	set_process(false)
	# SaveSystem's autosave skips a tick while a render is active.
	add_to_group("sim_renderer")


func setup(gv: Node, main_node: Node, solar_ui: Node) -> void:
	_gv = gv
	_main = main_node
	_solar = solar_ui
	if _solar != null and _solar.has_method("set_render_cache"):
		_solar.call("set_render_cache", cache)


func is_active() -> bool:
	return _active


func progress() -> float:
	if not _active:
		return 1.0
	var span := maxf(_end_abs - _start_abs, 1e-9)
	return clampf((_cursor - _start_abs) / span, 0.0, 1.0)


## A pair of absolute hours is a PackedFloat64Array, never a Vector2: its
## float32 components hold ~1.8e7 h only to the nearest 2 h.
func active_range() -> PackedFloat64Array:
	return PackedFloat64Array([_start_abs, _end_abs]) if _active else PackedFloat64Array([NAN, NAN])


func ranges() -> Array:
	return cache.ranges


func covers(t: float) -> bool:
	return not _active and cache.covers(t)


## Why a render cannot start right now, or "" when it can.
func refusal(end_abs: float) -> String:
	if _active:
		return "A render is already running."
	if _gv == null or _main == null or _solar == null:
		return "The simulation is not set up yet."
	var model: Object = _gv.get("model")
	if model == null:
		return "No graph to render."
	var sm := get_node_or_null("/root/SimMode")
	if sm != null and sm.has_method("is_live") and bool(sm.call("is_live")):
		return "Not in Live mode: real measurements drive the site there."
	if _main.has_method("clock_is_owned") and bool(_main.call("clock_is_owned")):
		return "Another system owns the clock (a bake or an export is running)."
	if bool(_gv.get("_sandbox_active")):
		return "Not inside the Solar Bootcamp sandbox."
	var play := float(_main.call("get_absolute_hours"))
	if end_abs <= play + 1.0 / 60.0:
		return "The selection ends before the playhead — the render runs forward from now."
	return ""


## Render from the playhead to `end_abs` (clamped to MAX_RENDER_H ahead).
## Returns {ok, why, start, end}.
func start(end_abs: float) -> Dictionary:
	var why := refusal(end_abs)
	if not why.is_empty():
		return {"ok": false, "why": why}
	var model: Object = _gv.get("model")
	_flow = _gv.call("resource_flow_engine") if _gv.has_method("resource_flow_engine") else null
	_bridge = _gv.call("npc_population_bridge") if _gv.has_method("npc_population_bridge") else null
	if _flow == null:
		return {"ok": false, "why": "No flow engine."}
	_start_abs = float(_main.call("get_absolute_hours"))
	_end_abs = minf(end_abs, _start_abs + MAX_RENDER_H)
	_cursor = _start_abs

	# Own the world.
	if not bool(_main.call("push_clock_claim", CLOCK_OWNER, {"time_scale": 0.0}, true)):
		return {"ok": false, "why": "The clock refused the claim."}
	_gv.call("set_ambient_flow_suspended", true)
	_gv.set("_pond_twin_push_blocked", true)
	if _bridge != null and _bridge.has_method("freeze_tiers"):
		_bridge.call("freeze_tiers", true)

	# Snapshots of everything the render moves.
	_specs_snapshot.clear()
	for item in GraphNesting.walk_items(model, "root"):
		if item is Dictionary:
			_specs_snapshot[str((item as Dictionary).get("id", ""))] = \
				((item as Dictionary).get("specs", {}) as Dictionary).duplicate(true)
	_npc_snapshot = (_bridge.call("snapshot_all", _start_abs) as Dictionary) if _bridge != null else {}
	_flow_snapshot = _flow.call("internal_state_snapshot") if _flow.has_method("internal_state_snapshot") else {}
	_camp_snapshot = _gv.call("camp_power_state_snapshot") if _gv.has_method("camp_power_state_snapshot") else {}
	_battery_kwh = float(_solar.call("get_battery_kwh_stored"))

	# The caches start at the playhead: whatever was ahead is superseded. The
	# seek writes tank specs, so it runs inside the sim-write bracket like
	# every other sim write (it moved user_rev by one when it did not).
	_gv.call("_begin_sim_writes")
	var series: Object = _solar.call("prepare_live_timeline_for_render", _start_abs, model)
	_flow.call("seek_all_tanks", _start_abs)
	_flow.call("truncate_timelines_after", _start_abs)
	var soc_a := float((series.call("sample_at", _start_abs) as Dictionary).get("soc_kwh", NAN))
	cache.begin_range(_start_abs, int(model.get("user_rev")), soc_a)
	cache.capture(model, _flow.call("conn_flow_snapshot"), _start_abs, _flow_snapshot)
	_gv.call("_end_sim_writes")

	_stepper = SimBakeStepper.new()
	_stepper.solar = _solar
	_stepper.flow = _flow
	_stepper.bridge = _bridge
	_stepper.gv = _gv
	_stepper.main = _main
	_stepper.model = model
	_stepper.series = series
	_stepper.cache = cache
	_stepper.step_h = float(series.get("step_hours"))
	_stepper.couple_dc_aux = true
	_stepper.ac_rule = SimBakeStepper.AcRule.HYSTERESIS
	_steps_done = 0
	_t_started_ms = Time.get_ticks_msec()
	_active = true
	set_process(true)
	render_started.emit(_start_abs, _end_abs)
	render_progress.emit(0.0, NAN, _cursor)
	cache_changed.emit()
	return {"ok": true, "why": "", "start": _start_abs, "end": _end_abs}


## Stop early; what was rendered so far stays valid.
func cancel() -> void:
	if not _active:
		return
	_finish(false)


func _process(_delta: float) -> void:
	if not _active:
		set_process(false)
		return
	var t0 := Time.get_ticks_usec()
	var budget_us := int(FRAME_BUDGET_MS * 1000.0)
	_gv.call("_begin_sim_writes")
	while _cursor < _end_abs - 1e-9 and Time.get_ticks_usec() - t0 < budget_us:
		_cursor = minf(_cursor + _stepper.step_h, _end_abs)
		_stepper.step(_cursor)
		_steps_done += 1
	_gv.call("_end_sim_writes")
	# Redraw only between chunks; the heavy telemetry rescans wait for the end.
	if _gv.has_method("_flush_sim_bulk_update"):
		_gv.call("_flush_sim_bulk_update", false)
	var elapsed_s := float(Time.get_ticks_msec() - _t_started_ms) / 1000.0
	var frac := progress()
	var eta := NAN
	if frac > 0.02 and elapsed_s > 0.2:
		eta = elapsed_s * (1.0 - frac) / frac
	render_progress.emit(frac, eta, _cursor)
	if _cursor >= _end_abs - 1e-9:
		_finish(true)


func _finish(completed: bool) -> void:
	var model: Object = _gv.get("model")
	# Make sure the range covers exactly what was stepped, with a final keyframe.
	_gv.call("_begin_sim_writes")
	if _cursor > _start_abs + 1e-9:
		cache.capture(model, _flow.call("conn_flow_snapshot"), _cursor,
			_flow.call("internal_state_snapshot") if _flow.has_method("internal_state_snapshot") else {})
	cache.extend_range(_cursor)
	# The world back to the playhead, all of it under the sim-write bracket.
	# Keyframe first (it also restores the engine's between-step state at the
	# playhead), then the tank replay, which leaves the engine's clock at the
	# playhead.
	for iid in _specs_snapshot:
		if not (model.call("get_item", str(iid)) as Dictionary).is_empty():
			model.call("update_item", str(iid), {"specs": (_specs_snapshot[iid] as Dictionary).duplicate(true)})
	cache.apply_at(model, _flow, _start_abs)
	if _flow.has_method("restore_internal_state"):
		_flow.call("restore_internal_state", _flow_snapshot)
	_flow.call("replay_at", _start_abs)
	if _bridge != null and not _npc_snapshot.is_empty():
		_bridge.call("restore_all", _npc_snapshot)
	if _gv.has_method("restore_camp_power_state"):
		_gv.call("restore_camp_power_state", _camp_snapshot)
	_gv.call("_end_sim_writes")
	if _gv.has_method("_flush_sim_bulk_update"):
		_gv.call("_flush_sim_bulk_update", true)
	_main.call("set_absolute_hours", _start_abs)
	_solar.call("end_render_evaluator")
	_solar.call("reseat_battery_at", _start_abs)
	# Hand the world back.
	if _bridge != null and _bridge.has_method("freeze_tiers"):
		_bridge.call("freeze_tiers", false)
	_gv.set("_pond_twin_push_blocked", false)
	_gv.call("set_ambient_flow_suspended", false)
	_main.call("pop_clock_claim", CLOCK_OWNER)
	if _gv.has_method("push_pond_levels_to_mesh"):
		_gv.call("push_pond_levels_to_mesh")
	_active = false
	set_process(false)
	var ms := Time.get_ticks_msec() - _t_started_ms
	print("SimRenderer: %s %.1f h in %d ms — %s · %d keyframes" % [
		"rendered" if completed else "cancelled after",
		_cursor - _start_abs, ms,
		_stepper.report_line("steps", _cursor - _start_abs) if _stepper != null else "",
		cache.keyframe_count()])
	var a := _start_abs
	var b := _cursor
	_specs_snapshot.clear()
	_npc_snapshot.clear()
	_stepper = null
	render_finished.emit(completed, a, b)
	cache_changed.emit()


# ---------------------------------------------------------------------------
# Invalidation (called by the view)
# ---------------------------------------------------------------------------

## A player edit at `playhead`: the rendered future is no longer this graph's.
## Returns true when a range was cut or dropped.
func invalidate_from(playhead: float) -> bool:
	if _active:
		return false
	var changed := cache.truncate_after(playhead)
	if changed:
		if _solar != null:
			var et: Object = _solar.get("energy_timeline")
			if et != null:
				et.call("truncate_after", playhead)
		if _flow != null and _flow.has_method("truncate_timelines_after"):
			_flow.call("truncate_timelines_after", playhead)
		cache_changed.emit()
	return changed


## Everything the sim depends on outside the graph changed (weather data,
## a physics setting): drop the lot.
func invalidate_all() -> bool:
	if _active:
		return false
	if cache.invalidate_all():
		cache_changed.emit()
		return true
	return false
