class_name NpcExperimentLab
extends Node

## "How long would this project ACTUALLY take, under different rules?"
##
## The Site Projects panel already shows a planned makespan from
## NpcCrewPlan.schedule — pure critical-path list scheduling, no needs, no
## weather, no morale, no daily windows. This runs the REAL population
## simulation over the same task graph under variant rules and reports what it
## costs, so the gap between the two (the `drag_h` column) is visible.
##
## ## Three decisions everything else follows from
##
## 1. **It never touches NpcPopulationBridge.** `tick_at` moves real props,
##    seeds the graph and persists to specs — running variants through it
##    would physically rearrange the player's camp. It also names the
##    PerfMonitor autoload bare, which fails a `--script` compile and SILENTLY
##    ABORTS the enclosing selftest function while PASS still prints. This file
##    must therefore never reference `main`, `get_tree`, the bridge, or ANY
##    autoload; the setup snapshot is captured for it by the bridge (scene
##    glue) and handed over as plain data.
##
## 2. **Every variant re-rosters, the baseline included.** `configure()`
##    rebuilds the crew at full morale with fresh needs. A baseline that
##    inherited the live camp's half-empty stomachs and 0.6 morale would lose
##    to a fresh twelve-person crew for reasons that have nothing to do with
##    crew size. So the question this answers is precisely: *how long for a
##    FRESH crew of N, starting at the snapshot hour* — and the UI says so.
##
## 3. **DT_H is fixed forever.** Agent RNG reseeds per sim-DAY, so identical
##    inputs and an identical substep schedule give bit-identical results —
##    which is what makes caching legitimate. Change DT_H and every cached
##    number moves, so it is part of the cache signature. Never compare a
##    number from here against one from the live sim.
##
## Deliberate fidelity limits, all surfaced in the UI rather than hidden:
## frozen weather (the live sampler has no notion of "three days from now"),
## straight-line travel (the nav grid is shared with the live sim and has a
## 2-cold-query-per-tick budget this must not raid), and DT_H resolution.

signal progress(frac: float)
signal results_ready(rows: Array, summary: Dictionary)

## 0.25 h ⇒ 3 engine substeps, and above SEPARATION_MAX_DT_H the O(n²) crowd
## separation pass drops out (it is cosmetic and never banked into the ledger).
const DT_H := 0.25
## Runaway guard. tools_down, an impossible quorum, a collapsing colony or a
## deserted roster all mean "never finishes"; report DNF rather than spin.
const MAX_SIM_H := 96.0
## Ticks per frame. Sliced by TICK, not by variant: one variant can be ~384
## ticks × roster × 3 substeps, which is a visible hitch on its own.
const TICKS_PER_FRAME := 48
const CREW_SWEEP: Array = [2, 4, 6, 8, 12, 16]
const SIGNATURE_VERSION := 1
## Long-shift routine for the schedule variant.
const LONG_SHIFT_START := 8.0
const LONG_SHIFT_END := 20.0

var _setup: Dictionary = {}
var _variants: Array = []
var _rows: Array = []
var _v_index := 0
var _active := false
# Per-variant run state.
var _engine: NpcPopulationEngine = null
var _board: NpcChoreBoard = null
var _ctx: Dictionary = {}
var _t := 0.0
var _t0 := 0.0
var _gate_cid := ""
var _stamped: Dictionary = {}
var _acc: Dictionary = {}
var _ticks := 0
var _total_ticks := 0


func _ready() -> void:
	set_process(false)


func is_running() -> bool:
	return _active


func cancel() -> void:
	_active = false
	_engine = null
	_board = null
	set_process(false)


# --- pure statics -------------------------------------------------------------

## The variant catalog. `apply` is a declarative PATCH DICT, never a Callable,
## so the catalog stays pure, printable, diffable and serializable.
static func variants_for(setup: Dictionary) -> Array:
	var roster := maxi(int(setup.get("roster_size", 1)), 1)
	var is_delivery := not (setup.get("haul", {}) as Dictionary).is_empty()
	var out: Array = [{
		"id": "baseline", "label": "As it stands", "group": "baseline",
		"apply": {"roster": roster},
	}]
	var crews: Array = CREW_SWEEP.duplicate()
	if not crews.has(roster):
		crews.append(roster)
	crews.sort()
	for n in crews:
		if int(n) == roster:
			continue   # that IS the baseline
		out.append({"id": "crew_%d" % int(n), "label": "%d people" % int(n),
			"group": "crew", "apply": {"roster": int(n)}})
	# `rules_full` REPLACES the site's rules rather than overlaying them. With
	# an overlay, a site already running night_shift made this row a byte
	# identical clone of the baseline and made the window row a literal no-op
	# (available_for skips the window check entirely under night_shift) — two
	# rows reporting numbers that carried no information.
	out.append({"id": "night", "label": "Night shift", "group": "rules",
		"apply": {"roster": roster, "rules_full": {"night_shift": true}}})
	# A CONTROL, not a scenario: forcing fair weather isolates what the sky is
	# costing. tools_down is deliberately absent — a guaranteed DNF teaches
	# nothing.
	out.append({"id": "fair", "label": "Fair weather", "group": "rules",
		"apply": {"roster": roster, "weather": {}}})
	# Not optional. The default day has NO free blocks and only a WORK block
	# routes to a chore, so chores get ~6 h/person/day entirely inside the
	# default window — which means "night shift" alone barely moves the number
	# and reads as broken without this row beside it.
	out.append({"id": "long_shift", "label": "Long shifts (08–20)",
		"group": "routine", "apply": {"roster": roster, "routine": "long_shifts"}})
	out.append({"id": "crew_big", "label": "Bigger crews per task",
		"group": "crew cap", "apply": {"roster": roster, "cap": 2.0}})
	out.append({"id": "crew_split", "label": "Split the crew",
		"group": "crew cap", "apply": {"roster": roster, "cap": 0.5}})
	# night_shift OFF explicitly, or the window under test is never evaluated.
	out.append({"id": "window", "label": "Longer window (06–20)",
		"group": "window", "apply": {"roster": roster,
			"rules_full": {"night_shift": false},
			"window": {"start_h": 6.0, "end_h": 20.0}}})
	for strat in ["round_trip", "brigade"]:
		out.append({"id": "haul_%s" % strat,
			"label": "Haul: %s" % strat.replace("_", " "), "group": "haul",
			"na": not is_delivery,
			"apply": {"roster": roster, "haul": strat}})
	return out


## Why this variant cannot finish, or "" — evaluated BEFORE any ticks are
## spent. "needs 6+ hands" is a far better answer than a DNF after 96
## simulated hours, and it saves most of the runtime on small-roster rows.
static func infeasible_reason(setup: Dictionary, roster: int) -> String:
	var need := 0
	var labour := 0.0
	for c in setup.get("chore_specs", []):
		var cd := c as Dictionary
		need = maxi(need, int(cd.get("min_workers", 1)))
		labour += float(cd.get("chore_hours", 0.0))
	if need > roster:
		return "needs %d+ hands" % need
	# ~6 workable hours per person per day under the default routine.
	if labour > float(roster) * 6.0 * (MAX_SIM_H / 24.0):
		return "more than %d days of work at this crew size" % int(MAX_SIM_H / 24.0)
	return ""


## Cache key. Digests only STABLE chore fields — never progress_h/workers/
## done_day, which change every tick and would bust the cache constantly.
static func signature_for(setup: Dictionary) -> String:
	var parts := PackedStringArray()
	for c in setup.get("chore_specs", []):
		var cd := c as Dictionary
		parts.append("%s:%.3f:%d:%d:%d:%s" % [
			str(cd.get("task_id", "")), float(cd.get("chore_hours", 0.0)),
			int(cd.get("min_workers", 1)), int(cd.get("max_workers", 1)),
			int(cd.get("priority", 0)), str(cd.get("depends_on", []))])
	return "xlab%d|%s|%s|%d|%d|%d|%s|dt=%.3f" % [
		SIGNATURE_VERSION, str(setup.get("project_id", "")),
		str(setup.get("kind", "")), int(setup.get("day_index", 0)),
		int(setup.get("roster_size", 0)), hash(parts),
		str(setup.get("rules", {})), DT_H]


## Min and max together, ALWAYS. update_chore does no normalization (add_chore
## is where min>=1 / max>=min are enforced), and a chore whose max is below its
## min can be claimed by nobody and silently DNFs the whole variant.
static func _set_crew(board: NpcChoreBoard, cid: String, min_w: int, max_w: int) -> void:
	var lo := maxi(min_w, 1)
	board.update_chore(cid, {"min_workers": lo, "max_workers": maxi(max_w, lo)})


static func summarize(rows: Array) -> Dictionary:
	var best := ""
	var best_h := INF
	var base_h := 0.0
	for r in rows:
		var rd := r as Dictionary
		if str(rd.get("status", "")) != "done":
			continue
		var h := float(rd.get("makespan_h", INF))
		if str(rd.get("id", "")) == "baseline":
			base_h = h
		if h < best_h:
			best_h = h
			best = str(rd.get("label", ""))
	# A saving is only meaningful against a baseline that FINISHED. When it
	# didn't, say so — "0.0 h saved" against a DNF baseline reads as "no
	# improvement" when the truth is the opposite.
	return {"best_label": best, "best_h": best_h if best_h < INF else -1.0,
		"baseline_h": base_h, "baseline_done": base_h > 0.0,
		"saving_h": (base_h - best_h) if (base_h > 0.0 and best_h < INF) else 0.0}


# --- running ------------------------------------------------------------------

## Chunked run for the UI. Emits progress() per frame and results_ready() once.
func start(setup: Dictionary) -> void:
	cancel()
	_setup = setup
	_variants = variants_for(setup)
	_rows = []
	_v_index = 0
	_total_ticks = 0
	_active = true
	_begin_variant()
	set_process(true)
	progress.emit(0.0)


## Same computation with no SceneTree — what the selftest drives, which is also
## the structural guard that nothing in here reaches for a scene.
func run_blocking(setup: Dictionary) -> Dictionary:
	_setup = setup
	_variants = variants_for(setup)
	_rows = []
	_v_index = 0
	_total_ticks = 0
	_active = true
	_begin_variant()
	var guard := 0
	while _active and guard < 100000:
		_step_once()
		guard += 1
	return {"rows": _rows, "summary": summarize(_rows), "ticks": _total_ticks}


func _process(_delta: float) -> void:
	if not _active:
		set_process(false)
		return
	for _i in TICKS_PER_FRAME:
		if not _active:
			break
		_step_once()
	if _active:
		progress.emit(clampf(float(_v_index) / maxf(float(_variants.size()), 1.0), 0.0, 1.0))


## One tick of the current variant, advancing to the next when it settles.
func _step_once() -> void:
	if _v_index >= _variants.size():
		_finish()
		return
	if _engine == null:
		_next_variant()
		return
	_t += DT_H
	_ticks += 1
	_total_ticks += 1
	_engine.tick(_t, _ctx)
	_sample()
	if _board.remaining(_gate_cid) <= 0.0001 and not _stamped.has(_gate_cid):
		_stamped[_gate_cid] = _t
	var done := _stamped.has(_gate_cid)
	var dnf := ""
	if not done:
		if _engine.is_deserted():
			dnf = "everyone left"
		elif _engine.has_collapsed():
			dnf = "the camp collapsed"
		elif _t - _t0 >= MAX_SIM_H:
			dnf = "hour cap"
	if done or not dnf.is_empty():
		_close_variant(done, dnf)
		_next_variant()


func _begin_variant() -> void:
	while _v_index < _variants.size():
		if _setup_variant(_variants[_v_index] as Dictionary):
			return
		_v_index += 1
	_finish()


func _next_variant() -> void:
	_v_index += 1
	_begin_variant()


## Build a fresh engine + board for one variant. Returns false when the row was
## settled without simulating (n/a or infeasible).
func _setup_variant(v: Dictionary) -> bool:
	_engine = null
	var apply: Dictionary = v.get("apply", {})
	var roster := maxi(int(apply.get("roster", _setup.get("roster_size", 1))), 1)
	if bool(v.get("na", false)):
		_rows.append(_row(v, "na", 0.0, roster, "not a delivery"))
		return false

	# Rows: either re-planned for a forced haul strategy, or the live plan.
	var specs: Array = _setup.get("chore_specs", [])
	var haul_force := str(apply.get("haul", ""))
	if not haul_force.is_empty():
		var hd: Dictionary = _setup.get("haul", {})
		specs = SiteProject.unload_spec_rows(hd.get("crates", []),
			hd.get("from", Vector2.ZERO) as Vector2, roster, haul_force)["rows"]
	var probe := _setup.duplicate()
	probe["chore_specs"] = specs
	var why := infeasible_reason(probe, roster)
	if not why.is_empty():
		_rows.append(_row(v, "infeasible", 0.0, roster, why))
		return false

	_board = NpcChoreBoard.create_empty()
	var made: Array = _board.add_plan(specs,
		_setup.get("window", {"start_h": 7.0, "end_h": 19.0}) as Dictionary,
		_setup.get("target", {}) as Dictionary)
	if made.is_empty():
		_rows.append(_row(v, "infeasible", 0.0, roster, "plan does not fit a board"))
		return false
	_gate_cid = str(made[made.size() - 1])
	# Board rules ride the blob normally; a variant may OVERLAY (`rules`) or
	# REPLACE (`rules_full`) them. Replacement is what lets a rules row mean
	# the same thing whatever the site happens to be running.
	if apply.has("rules_full"):
		_board.rules = (apply["rules_full"] as Dictionary).duplicate()
	else:
		_board.rules = (_setup.get("rules", {}) as Dictionary).duplicate()
		for k in (apply.get("rules", {}) as Dictionary):
			_board.rules[k] = (apply["rules"] as Dictionary)[k]
	if apply.has("cap"):
		var mult := float(apply["cap"])
		for c in _board.chores:
			var cd: Dictionary = c
			var mx := int(cd.get("max_workers", 1))
			var mn := int(cd.get("min_workers", 1))
			var want := maxi(int(round(float(mx) * mult)), 1)
			_set_crew(_board, str(cd.get("id", "")), mn, mini(want, roster))
	if apply.has("window"):
		for c2 in _board.chores:
			_board.update_chore(str((c2 as Dictionary).get("id", "")),
				{"window": (apply["window"] as Dictionary).duplicate()})

	_engine = NpcPopulationEngine.new()
	# Board BEFORE configure: configure only mints one when it is still null.
	_engine.chore_board = _board
	if str(apply.get("routine", "")) == "long_shifts":
		_engine.routine = _long_shift_routine()
	elif not (_setup.get("routine", []) as Array).is_empty():
		_engine.routine = NpcRoutine.from_array(_setup.get("routine", []) as Array)
	else:
		_engine.routine = null   # configure installs the default day
	_engine.configure(roster, str(_setup.get("iid", "lab")),
		_setup.get("home", Vector2.ZERO) as Vector2)
	_engine.set_weather((apply.get("weather", _setup.get("weather", {})) as Dictionary))
	_engine.set_starved(_setup.get("starved", []) as Array)
	# A FRESH registry per variant: agents claim occupancy slots, and a shared
	# one would leak claims from the previous variant into this one.
	var reg := SpaceRegistry.create_empty()
	reg.deserialize(_setup.get("registry_blob", {}) as Dictionary)
	var space_pos: Dictionary = _setup.get("space_pos", {})
	var prop_pos: Dictionary = _setup.get("prop_pos", {})
	# Deliberately WITHOUT plan_path/height_at/walkable/trace — straight-line
	# travel, no climb accounting, no desire tracing. The nav grid belongs to
	# the live sim and has a 2-cold-query-per-tick budget this must not raid.
	_ctx = {
		"registry": reg,
		"pos_of": func(space: Dictionary) -> Variant:
			return space_pos.get(str(space.get("id", "")), null),
		"chore_pos_of": func(chore: Dictionary) -> Variant:
			var tgt: Dictionary = chore.get("target", {})
			match str(tgt.get("kind", "")):
				"pos":
					return Vector2(float(tgt.get("x", 0.0)), float(tgt.get("z", 0.0)))
				"prop":
					return prop_pos.get(str(tgt.get("id", "")), null)
				"space":
					return space_pos.get(str(tgt.get("id", "")), null)
			return null,
		"hour_of_day": 0.0,
	}
	_t0 = float(_setup.get("start_h", 0.0))
	_t = _t0
	_stamped = {}
	_ticks = 0
	_acc = {"worker_h": 0.0, "gathering_h": 0.0, "need_h": 0.0, "idle_h": 0.0,
		"prod_sum": 0.0, "prod_n": 0.0}
	# Priming tick: configure() left _last_abs_h NAN, so the first call only
	# establishes the baseline and advances nothing.
	_ctx["hour_of_day"] = fposmod(_t, 24.0)
	_engine.tick(_t, _ctx)
	return true


func _long_shift_routine() -> NpcRoutine:
	return NpcRoutine.from_array([
		{"kind": "sleep", "start_h": 22.0, "end_h": 6.5},
		{"kind": "free", "start_h": 6.5, "end_h": LONG_SHIFT_START},
		{"kind": "work", "start_h": LONG_SHIFT_START, "end_h": LONG_SHIFT_END},
		{"kind": "free", "start_h": LONG_SHIFT_END, "end_h": 22.0},
	])


## Per-tick diagnostics — the columns that explain WHY a makespan is what it is.
func _sample() -> void:
	_ctx["hour_of_day"] = fposmod(_t, 24.0)
	for a in _engine.agents:
		var ag: NpcAgent = a
		if ag.activity == NpcAgent.CHORE_ACTIVITY and ag.state == NpcAgent.State.DOING:
			if _board.has_quorum(ag.chore_id):
				_acc["worker_h"] = float(_acc["worker_h"]) + DT_H
				_acc["prod_sum"] = float(_acc["prod_sum"]) + NpcMorale.productivity(ag.morale)
				_acc["prod_n"] = float(_acc["prod_n"]) + 1.0
			else:
				_acc["gathering_h"] = float(_acc["gathering_h"]) + DT_H
		elif ag.activity.is_empty():
			_acc["idle_h"] = float(_acc["idle_h"]) + DT_H
		else:
			_acc["need_h"] = float(_acc["need_h"]) + DT_H


func _close_variant(done: bool, dnf: String) -> void:
	var v: Dictionary = _variants[_v_index]
	var roster := _engine.agents.size()
	var span := (float(_stamped.get(_gate_cid, _t)) - _t0) if done else 0.0
	var row := _row(v, "done" if done else "dnf", span,
		int((v.get("apply", {}) as Dictionary).get("roster", roster)), dnf)
	row["worker_h"] = snappedf(float(_acc["worker_h"]), 0.01)
	row["gathering_h"] = snappedf(float(_acc["gathering_h"]), 0.01)
	row["need_h"] = snappedf(float(_acc["need_h"]), 0.01)
	row["idle_h"] = snappedf(float(_acc["idle_h"]), 0.01)
	row["productivity_mean"] = snappedf(
		float(_acc["prod_sum"]) / maxf(float(_acc["prod_n"]), 1.0), 0.001)
	row["mean_morale_end"] = snappedf(_engine.mean_morale(), 0.01)
	row["roster_end"] = roster
	_rows.append(row)
	_engine = null


func _row(v: Dictionary, status: String, makespan_h: float, roster: int,
		note: String) -> Dictionary:
	# The pure scheduler's answer for the SAME crew — the lower bound the
	# simulated number is measured against.
	var plan_h := 0.0
	var tasks: Array = _setup.get("plan_tasks", [])
	if not tasks.is_empty():
		var sched := NpcCrewPlan.schedule(tasks, maxi(roster, 1))
		if bool(sched.get("feasible", false)):
			plan_h = float(sched.get("makespan_s", 0.0)) / 3600.0
	return {
		"id": str(v.get("id", "")), "label": str(v.get("label", "")),
		"group": str(v.get("group", "")), "status": status,
		"makespan_h": snappedf(makespan_h, 0.01),
		"plan_h": snappedf(plan_h, 0.01),
		# Drag is only meaningful against a KNOWN plan. With no task graph
		# (plan_h == 0) reporting `makespan - 0` would claim the entire job
		# was overhead, which is worse than reporting nothing: -1 = unknown.
		"drag_h": (snappedf(maxf(makespan_h - plan_h, 0.0), 0.01)
			if (status == "done" and plan_h > 0.0) else -1.0),
		"roster": roster, "dnf_reason": note,
		"worker_h": 0.0, "gathering_h": 0.0, "need_h": 0.0, "idle_h": 0.0,
		"productivity_mean": 0.0, "mean_morale_end": 0.0, "roster_end": 0,
	}


func _finish() -> void:
	_active = false
	set_process(false)
	progress.emit(1.0)
	results_ready.emit(_rows, summarize(_rows))
