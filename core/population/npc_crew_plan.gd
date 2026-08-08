class_name NpcCrewPlan
extends RefCounted
## Compound-task crew scheduler — the "pit crew" engine (PACKING_PLAN.md
## Phase 6.5). The player states WHAT must happen (a task graph with
## dependencies and crew limits); how a group of N people divides the work,
## where the bottleneck sits, and what crew size is actually worth bringing
## all EMERGE from list scheduling over the graph. This is the same
## rules-not-avatars contract as NpcHaulModel, one level up: haul strategies
## are per-task physics, this is the coordination between tasks.
##
## Model: each task is {id, label, work_s (total PERSON-seconds),
## min_workers (can't start with fewer — the barn-raising threshold),
## max_workers (more hands stop helping — two people per drill), deps: [ids]}.
## Tasks are malleable: allocated workers within [min,max] consume work at
## `workers` person-seconds per second, and allocation is recomputed at every
## completion event (a pit crew re-shuffles the moment a wheel is done).
##
## Scheduler: event-driven greedy list scheduling, critical-path-first —
## ready tasks sorted by longest downstream path (their own lower-bound
## duration work_s/max_workers plus successors'), workers dealt min-first
## then topped up in the same order. Deterministic by construction (stable
## sort keys + authored order tie-break). Greedy list scheduling is the
## classic heuristic here (optimal DAG scheduling is NP-hard; Graham 1966);
## with malleable tasks it lands near the two lower bounds it can never
## beat: the critical path, and total_work / N.
##
## The selftest pins the EMERGENT properties: makespan ≥ both bounds,
## more workers never hurt, and past the graph's parallelism the makespan
## flatlines at the critical path — the "9 people build it as fast as 40"
## readout that makes this a planning tool, not just a sim.

const MAX_EVENTS := 4096
const EPS := 1e-6


## Schedule a task graph for a crew of n. Returns:
## {feasible, makespan_s, timeline: [{id, label, start_s, end_s}],
##  critical_path_s, floor_s (total/n), utilization, bottleneck_id,
##  blocked_id (when infeasible)}
static func schedule(tasks: Array, n_workers: int) -> Dictionary:
	var out := {"feasible": false, "makespan_s": INF, "timeline": [],
		"critical_path_s": 0.0, "floor_s": 0.0, "utilization": 0.0,
		"bottleneck_id": "", "blocked_id": ""}
	var n := maxi(n_workers, 0)
	if tasks.is_empty():
		out["feasible"] = true
		out["makespan_s"] = 0.0
		return out
	if n <= 0:
		return out

	# Normalize + index.
	var ids: Array = []
	var by_id: Dictionary = {}
	var total_work := 0.0
	for t in tasks:
		var d := (t as Dictionary).duplicate(true)
		var tid := str(d.get("id", ""))
		if tid.is_empty() or by_id.has(tid):
			return out
		d["work_s"] = maxf(float(d.get("work_s", 0.0)), 0.0)
		d["min_workers"] = maxi(int(d.get("min_workers", 1)), 1)
		d["max_workers"] = maxi(int(d.get("max_workers", 1)), int(d["min_workers"]))
		by_id[tid] = d
		ids.append(tid)
		total_work += float(d["work_s"])
	for tid in ids:
		for dep in (by_id[tid] as Dictionary).get("deps", []):
			if not by_id.has(str(dep)):
				out["blocked_id"] = tid
				return out
	out["floor_s"] = total_work / float(n)
	out["critical_path_s"] = _critical_path(ids, by_id)

	# Critical-path rank (own lower bound + longest successor chain).
	var rank := _downstream_rank(ids, by_id)

	var remaining: Dictionary = {}
	for tid in ids:
		remaining[tid] = float((by_id[tid] as Dictionary)["work_s"])
	var done: Dictionary = {}
	var started: Dictionary = {}   # id -> start_s (for the timeline)
	var finished: Dictionary = {}  # id -> end_s
	var t := 0.0
	var busy_s := 0.0

	for _ev in MAX_EVENTS:
		if done.size() == ids.size():
			break
		# Ready set: deps done, work left; zero-work tasks complete instantly.
		var ready: Array = []
		for tid in ids:
			if done.has(tid):
				continue
			var deps_ok := true
			for dep in (by_id[tid] as Dictionary).get("deps", []):
				if not done.has(str(dep)):
					deps_ok = false
					break
			if not deps_ok:
				continue
			if float(remaining[tid]) <= EPS:
				done[tid] = true
				if not started.has(tid):
					started[tid] = t
				finished[tid] = t
				continue
			ready.append(tid)
		if done.size() == ids.size():
			break
		ready.sort_custom(func(a: String, b: String) -> bool:
			var ra := float(rank[a])
			var rb := float(rank[b])
			if absf(ra - rb) > EPS:
				return ra > rb
			return ids.find(a) < ids.find(b))
		# Deal workers: min-first pass so a high-rank hog can't starve a
		# small task's minimum, then top up to max in the same order.
		var alloc: Dictionary = {}
		var pool := n
		for tid in ready:
			var need := int((by_id[tid] as Dictionary)["min_workers"])
			if pool >= need:
				alloc[tid] = need
				pool -= need
		for tid in ready:
			if pool <= 0:
				break
			if not alloc.has(tid):
				continue
			var cap := int((by_id[tid] as Dictionary)["max_workers"])
			var top := mini(cap - int(alloc[tid]), pool)
			alloc[tid] = int(alloc[tid]) + top
			pool -= top
		if alloc.is_empty():
			# Nothing can start: some ready task needs more hands than exist.
			out["blocked_id"] = str(ready[0]) if not ready.is_empty() else ""
			return out
		# Advance to the next completion among allocated tasks.
		var dt := INF
		for tid in alloc:
			dt = minf(dt, float(remaining[tid]) / float(alloc[tid]))
		if dt == INF or dt <= 0.0:
			break
		for tid in alloc:
			if not started.has(tid):
				started[tid] = t
			var w := float(alloc[tid])
			remaining[tid] = float(remaining[tid]) - w * dt
			busy_s += w * dt
			if float(remaining[tid]) <= EPS:
				done[tid] = true
				finished[tid] = t + dt
		t += dt

	if done.size() != ids.size():
		return out
	out["feasible"] = true
	out["makespan_s"] = t
	out["utilization"] = (busy_s / (float(n) * t)) if t > 0.0 else 1.0
	var timeline: Array = []
	var span := 0.0
	var bottleneck := ""
	for tid in ids:
		var s := float(started.get(tid, 0.0))
		var e := float(finished.get(tid, s))
		timeline.append({"id": tid,
			"label": str((by_id[tid] as Dictionary).get("label", tid)),
			"start_s": s, "end_s": e})
		if e - s > span:
			span = e - s
			bottleneck = tid
	out["timeline"] = timeline
	out["bottleneck_id"] = bottleneck
	return out


## Longest dependency chain, each task at its own best-case duration
## (work_s / max_workers) — the bound no crew size can beat.
static func _critical_path(ids: Array, by_id: Dictionary) -> float:
	var rank := _downstream_rank(ids, by_id)
	var best := 0.0
	for tid in ids:
		best = maxf(best, float(rank[tid]))
	return best


static func _downstream_rank(ids: Array, by_id: Dictionary) -> Dictionary:
	# Successor lists from dep lists, then DP over the DAG (iterate until
	# fixed point, bounded — inputs are authored, not adversarial).
	var succ: Dictionary = {}
	for tid in ids:
		succ[tid] = []
	for tid in ids:
		for dep in (by_id[tid] as Dictionary).get("deps", []):
			(succ[str(dep)] as Array).append(tid)
	var rank: Dictionary = {}
	for tid in ids:
		rank[tid] = 0.0
	for _pass in ids.size() + 1:
		var changed := false
		for tid in ids:
			var d := by_id[tid] as Dictionary
			var own := float(d["work_s"]) / float(d["max_workers"])
			var tail := 0.0
			for s in succ[tid]:
				tail = maxf(tail, float(rank[s]))
			if absf(float(rank[tid]) - (own + tail)) > EPS:
				rank[tid] = own + tail
				changed = true
		if not changed:
			break
	return rank


## Smallest crew whose makespan lands within `slack` of the saturated
## (parallelism-exhausted) makespan — the "bring 9, not 40" answer.
## Returns {n, makespan_s, utilization, saturated_s} ({} if infeasible).
static func recommend_crew(tasks: Array, max_n: int = 32,
		slack: float = 1.1) -> Dictionary:
	var saturated := schedule(tasks, maxi(max_n, 1))
	if not bool(saturated["feasible"]):
		return {}
	var sat_ms := float(saturated["makespan_s"])
	for n in range(1, maxi(max_n, 1) + 1):
		var r := schedule(tasks, n)
		if not bool(r["feasible"]):
			continue
		if float(r["makespan_s"]) <= sat_ms * slack:
			return {"n": n, "makespan_s": float(r["makespan_s"]),
				"utilization": float(r["utilization"]), "saturated_s": sat_ms}
	return {"n": maxi(max_n, 1), "makespan_s": sat_ms,
		"utilization": float(saturated["utilization"]), "saturated_s": sat_ms}


## ASCII Gantt of a schedule — drops straight into build docs / console
## output, the documentation half of the swarm-manufacturing direction.
static func timeline_text(result: Dictionary, width: int = 40) -> String:
	if not bool(result.get("feasible", false)):
		return "infeasible (blocked: %s)" % str(result.get("blocked_id", "?"))
	var ms := maxf(float(result.get("makespan_s", 0.0)), EPS)
	var lines: Array = []
	for row in result.get("timeline", []):
		var r := row as Dictionary
		var s := float(r["start_s"])
		var e := float(r["end_s"])
		var a := clampi(roundi(s / ms * width), 0, width)
		var b := clampi(maxi(roundi(e / ms * width), a + 1), 0, width)
		var bar := " ".repeat(a) + "█".repeat(b - a) + " ".repeat(width - b)
		lines.append("%s| %s  %s" % [bar, _fmt_hm(s), str(r["label"])])
	lines.append("total %s" % _fmt_hm(ms))
	return "\n".join(lines)


static func _fmt_hm(seconds: float) -> String:
	var m := int(roundf(seconds / 60.0))
	return "%d:%02d" % [floori(m / 60.0), m % 60]


# ---------------------------------------------------------------------------
# Swarm-manufacturing factory: LinkageLab structure → fabrication task graph
# ---------------------------------------------------------------------------

## Per-unit fabrication timings (person-seconds; shop-floor estimates for
## dimensional lumber + hand power tools — mark/clamp/drill a pivot hole,
## chop-saw a beam, wrench a bolt set. Deliberately conservative).
const T_CUT_BEAM_S := 120.0
const T_DRILL_HOLE_S := 90.0
const HOLES_PER_BEAM := 3        # two ends + pivot
const T_ASSEMBLE_MODULE_S := 1800.0   # one scissor module, 2-person job
const T_BRACKET_S := 300.0
const T_BOLT_SET_S := 180.0
const T_FOLD_TEST_S := 1200.0
const T_ERECT_BASE_S := 2700.0        # raising, scaled by module count
const ERECT_MIN_WORKERS := 6          # the barn-raising threshold
const T_PANEL_MOUNT_S := 600.0        # per panel, 2-person job
## Threading ONE hardware piece — a washer, bushing, lock washer or nut — onto
## a live pivot while somebody else holds the joint. Small, but a detailed
## assembly is a dozen of them per joint per module, which is precisely why
## the hardware editor is worth scheduling from.
const T_HW_PART_S := 45.0


## Build the fabrication DAG from a structure's REAL part counts
## (LinkageStructureBuilder.get_stats() keys, or hand-authored counts:
## beam_count / bracket_count / bolt_count / module_count / panel_count).
## Cutting and drilling are embarrassingly parallel (every beam is an
## independent workpiece — the swarm phase); assembly is pairwise-limited;
## the raise needs many hands at once. The pit-crew shape of the whole job
## emerges from those three facts.
##
## Two optional keys, both supplied by `LinkageBom.fab_counts`, sharpen the
## plan when a real bill of materials exists:
## [br]• `bom_bolt_count` — the analytic bolt total, used instead of the
##   modules*6 estimate below.
## [br]• `assembly_steps` — per-joint hardware stacks, which split the single
##   flat "assemble" task into one task per assembly with labour priced from
##   the actual piece count.
## [br]Omit both and the emitted graph is byte-identical to the estimate-only
## version, which is what keeps the pinned schedules in npc_population_selftest
## and packing_selftest valid.
static func linkage_fab_tasks(counts: Dictionary) -> Array:
	var beams := maxi(int(counts.get("beam_count", 0)), 1)
	var brackets := maxi(int(counts.get("bracket_count", 0)), 0)
	var bolts := maxi(int(counts.get("bolt_count", 0)), 0)
	var modules := maxi(int(counts.get("module_count", 1)), 1)
	if int(counts.get("bom_bolt_count", 0)) > 0:
		bolts = int(counts["bom_bolt_count"])
	elif bolts <= 0:
		# The solver only emits bolt GEOMETRY when "show bolts" is on, but the
		# hardware exists regardless — estimate ~6 per module (2 V-stack sets,
		# H-stack, H-pivot) so the plan never prices a boltless structure.
		bolts = modules * 6
	var panels := maxi(int(counts.get("panel_count", 0)), 0)
	var tasks: Array = [
		{"id": "cut", "label": "Cut beams to length",
			"work_s": beams * T_CUT_BEAM_S,
			"min_workers": 1, "max_workers": maxi(floori(beams / 4.0), 1), "deps": []},
		{"id": "drill", "label": "Drill pivot holes",
			"work_s": beams * HOLES_PER_BEAM * T_DRILL_HOLE_S,
			"min_workers": 1, "max_workers": maxi(floori(beams / 2.0), 1),
			"deps": ["cut"]},
	]
	var assemble_ids := _append_assemble_tasks(tasks, counts, modules)
	tasks.append({"id": "brackets", "label": "Fit brackets",
		"work_s": brackets * T_BRACKET_S,
		"min_workers": 1, "max_workers": maxi(floori(brackets / 2.0), 1),
		"deps": ["drill"]})
	var bolt_deps: Array = assemble_ids.duplicate()
	bolt_deps.append("brackets")
	tasks.append({"id": "bolts", "label": "Bolt up the ring",
		"work_s": bolts * T_BOLT_SET_S,
		"min_workers": 1, "max_workers": maxi(modules, 1),
		"deps": bolt_deps})
	tasks.append({"id": "fold_test", "label": "Fold test",
		"work_s": T_FOLD_TEST_S,
		"min_workers": 2, "max_workers": 4, "deps": ["bolts"]})
	tasks.append({"id": "erect", "label": "Stage & raise",
		"work_s": T_ERECT_BASE_S * (1.0 + modules / 8.0),
		"min_workers": ERECT_MIN_WORKERS, "max_workers": ERECT_MIN_WORKERS * 2,
		"deps": ["fold_test"]})
	if panels > 0:
		tasks.append({"id": "panels", "label": "Mount panels",
			"work_s": panels * T_PANEL_MOUNT_S,
			"min_workers": 2, "max_workers": maxi(mini(panels, 8), 2),
			"deps": ["erect"]})
	return tasks


## Append the assembly phase and return the task ids the bolt-up depends on.
##
## With no `assembly_steps` this emits the single flat "assemble" task the
## fabrication graph has always carried. With them, each detailed hardware
## assembly becomes its own task: the joint still costs its share of the base
## module time, plus real seconds for every washer, bushing and nut somebody
## has to thread onto that pivot. Two people minimum either way — one holds the
## joint, one drives the fastener.
static func _append_assemble_tasks(tasks: Array, counts: Dictionary, modules: int) -> Array:
	var steps: Array = counts.get("assembly_steps", []) as Array
	if steps.is_empty():
		tasks.append({"id": "assemble", "label": "Assemble scissor modules",
			"work_s": modules * T_ASSEMBLE_MODULE_S,
			"min_workers": 2, "max_workers": maxi(modules * 2, 2),
			"deps": ["drill"]})
		return ["assemble"]
	var share := T_ASSEMBLE_MODULE_S / float(steps.size())
	var ids: Array = []
	for entry in steps:
		var e := entry as Dictionary
		var id := "assemble_%s" % str(e.get("assembly_id", "joint"))
		var pieces := maxi(int(e.get("per_module_pieces", 0)), 0)
		tasks.append({
			"id": id,
			"label": "Assemble %s" % str(e.get("label", "joint")),
			"work_s": modules * (pieces * T_HW_PART_S + share),
			"min_workers": 2, "max_workers": maxi(modules * 2, 2),
			"deps": ["drill"],
		})
		ids.append(id)
	return ids


## Chore-board bridge: schedule → ordered NpcChoreBoard-shaped chores.
## Dependencies are real on the v2 board; the start-time ordering + ascending
## priority still mirrors the schedule so ties resolve in build order.
## `overrides` (optional, keyed by task_id) attaches per-task board fields —
## exposure / target / effect / carry_to / haul — for Site Projects. Omitted
## ⇒ output identical to the pre-overrides bridge (the frozen back-compat
## literal in the selftests depends on that).
static func chore_specs(tasks: Array, result: Dictionary,
		overrides: Dictionary = {}) -> Array:
	if not bool(result.get("feasible", false)):
		return []
	var timeline: Array = (result.get("timeline", []) as Array).duplicate()
	timeline.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["start_s"]) < float((b as Dictionary)["start_s"]))
	var by_id: Dictionary = {}
	for t in tasks:
		by_id[str((t as Dictionary).get("id", ""))] = t
	var out: Array = []
	for i in timeline.size():
		var row := timeline[i] as Dictionary
		var task: Dictionary = by_id.get(str(row["id"]), {})
		var spec := {
			"task_id": str(row["id"]),
			"label": str(row["label"]),
			"chore_hours": maxf(float(task.get("work_s", 0.0)) / 3600.0, 0.05),
			"exposure": "outdoor",
			# The board sorts LOWER priority first — earlier phases first.
			# Uncapped: a >9-phase plan (assembly_steps splits) must keep its
			# order, and priority is an int, not an enum.
			"priority": i + 1,
			"repeat": "once",
			"depends_on": (task.get("deps", []) as Array).duplicate(),
			"min_workers": int(task.get("min_workers", 1)),
			"max_workers": int(task.get("max_workers", 1)),
		}
		var over: Dictionary = overrides.get(str(row["id"]), {})
		for k in over:
			spec[k] = over[k]
		out.append(spec)
	return out
