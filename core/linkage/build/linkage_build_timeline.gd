class_name LinkageBuildTimeline
extends RefCounted
## The fabrication swarm's brain (phase B4): a LinkageLab build sequence
## (LinkageBuildSteps) turned into a crew schedule WITH WORKER IDENTITY, and a
## pure `state_at(t)` that says, for any moment, where every worker is, what
## they are doing with which tool, which parts stand and how far the ring is
## open. Nothing ticks and nothing is stored but the plan: the build site
## (B5) poses its figures from `state_at`, so the whole build scrubs backwards
## like the fire and the forest do.
##
## Unlike NpcCrewPlan.schedule (malleable, anonymous person-hours), every job
## here is done by NAMED workers who walk to it (1.3 m/s), wait for a quorum
## (a raising needs six), hold a bench station (saws and drills are limited),
## work, and walk on — the lanes ARE the animation.
##
## Jobs come from steps:
##   cut / drill  one job per beam (the bench)        T_CUT_BEAM_S, holes x T_DRILL_HOLE_S
##   place        one job per step (panels: per panel) T_PLACE_PART_S per part
##   place from parked (the lift)  one job, quorum ERECT_MIN_WORKERS
##   fasten       one job per JOINT                    bolts x T_BOLT_SET_S
##   view that changes the fold    the DEPLOY job      T_FOLD_TEST_S, quorum 4
## Dependencies: a beam is cut, then drilled, then placed; within a module the
## authored step order holds while modules proceed in parallel; a step with no
## module (the lift, the deploy, supports, panels) is a barrier.
##
## Units: METRES in the structure's frame (LinkageStructureBuilder's: solver
## inches x 0.0254, grounded), seconds of build time.

const IN_TO_M := 0.0254
const WALK_MPS := 1.3
const T_PLACE_PART_S := 60.0
const T_PLACE_PANEL_S := NpcCrewPlan.T_PANEL_MOUNT_S
const T_LIFT_S := 600.0
const T_FOLD_S := NpcCrewPlan.T_FOLD_TEST_S
const FOLD_MIN_WORKERS := 4
const STAND_OFF_M := 0.65            # workers stand this far outside a part
const BENCH_GAP_M := 3.5             # benches stand this far outside the ring
const BENCH_SPACING_M := 2.2

## Job kind -> the clip its workers play (core/population/anims/).
const CLIP_FOR_KIND := {"cut": "saw_cut", "drill": "drill_hole", "fasten": "fasten_bolt",
	"place": "place_beam", "lift": "lift_ring", "deploy": "hold_brace", "carry": "carry_beam"}
const TOOL_FOR_KIND := {"cut": "circular_saw", "drill": "drill", "fasten": "impact_driver"}


## Plan the build. `steps` = a build sequence (LinkageBuildSteps); [] =
## generate the default. opts: {pose_deg, deployed_deg (null = the design's),
## saws, drills (bench stations; default from the crew)}.
static func plan(p: LinkageParams, steps: Array, crew_n: int, opts: Dictionary = {}) -> Dictionary:
	crew_n = maxi(1, crew_n)
	var deployed_deg: float = float(opts["deployed_deg"]) if opts.get("deployed_deg") != null \
		else rad_to_deg(LinkageKinematics.optimal_closed_angle(p))
	var folded_deg := rad_to_deg(LinkageKinematics.effective_min_fold_angle(p))
	var pose_deg: float = float(opts["pose_deg"]) if opts.get("pose_deg") != null \
		else folded_deg + (deployed_deg - folded_deg) * 0.45
	if steps.is_empty():
		steps = LinkageBuildSteps.generate_for(p, folded_deg, deployed_deg)
	var pose_data := LinkagePartKeys.part_data(p, deg_to_rad(pose_deg))
	var dep_data := LinkagePartKeys.part_data(p, deg_to_rad(deployed_deg))
	var pose_parts := LinkagePartKeys.collect_parts(pose_data)
	var dep_parts := LinkagePartKeys.collect_parts(dep_data)
	var pose_ground := LinkageStructureBuilder.ground_offset_for_frame(pose_data["frame"])
	var dep_ground := LinkageStructureBuilder.ground_offset_for_frame(dep_data["frame"])
	var drill := LinkageBeamHoles.drill_solve(p, deg_to_rad(deployed_deg))
	# The ring's real middle and radius in plan. The solver chains the modules
	# from module 0 AT the origin, so the origin is a point on the ring's edge
	# and the frame's max_rad is measured from there (about the diameter) —
	# and the middle MOVES as the ring folds. So each job carries the ring it
	# is worked round: the half-folded pose before the deploy, the open ring
	# after, both for the deploy itself; benches stand outside both.
	var ring_pose := ring_footprint(pose_parts)
	var ring_dep := ring_footprint(dep_parts)
	var ring_all := ring_union(ring_pose, ring_dep)
	var centre: Vector3 = ring_all["centre"]
	var radius: float = ring_all["radius"]

	var n_saws := int(opts.get("saws", clampi(crew_n / 3, 1, 4)))
	var n_drills := int(opts.get("drills", clampi(crew_n / 3, 1, 4)))
	var stations := _bench_stations(centre, radius, n_saws, n_drills)

	var jobs: Array = []
	var bench_job_for := {}           # beam key -> last bench job id (cut, then drill)
	var last_by_module := {}          # module -> [job ids of its latest step]
	var since_barrier: Array = []     # assembly jobs since the last barrier
	var barrier: Array = []           # the last barrier's job ids
	var deployed := false
	var station_rr := {"saw": 0, "drill": 0}
	for si in steps.size():
		var st: Dictionary = steps[si]
		var kind := str(st.get("kind", ""))
		var parts := pose_parts if not deployed else dep_parts
		var ground := pose_ground if not deployed else dep_ground
		var items: Array = LinkageBuildOps._targets_of(st, parts) if kind != "view" else []
		var module := _module_of(st)
		var new_ids: Array = []
		match kind:
			"cut", "drill":
				for rec in items:
					if rec["kind"] != "beam":
						continue
					var res := "saw" if kind == "cut" else "drill"
					var bench_list: Array = stations[res]
					var station: Dictionary = bench_list[int(station_rr[res]) % bench_list.size()]
					station_rr[res] = int(station_rr[res]) + 1
					var work := NpcCrewPlan.T_CUT_BEAM_S
					if kind == "drill":
						var holes := LinkageBuildSteps.dedupe_holes(LinkageBeamHoles.intersections(rec["obj"], drill["bolts"]))
						work = NpcCrewPlan.T_DRILL_HOLE_S * maxi(1, holes.size())
					var deps: Array = []
					if bench_job_for.has(rec["key"]):
						deps.append(bench_job_for[rec["key"]])
					var j := _job(jobs.size(), si, kind, [rec["key"]], station["pos"], work, 1, 1, deps)
					j["resource"] = station["id"]
					j["stand"] = station["stand"]
					j["face"] = station["pos"]
					jobs.append(j)
					bench_job_for[rec["key"]] = j["id"]
			"view":
				var v = st.get("view")
				if v is Dictionary and v.get("foldAngleDeg") != null and absf(float(v["foldAngleDeg"]) - deployed_deg) < 0.5 and not deployed:
					var deps2: Array = since_barrier + barrier
					var j2 := _job(jobs.size(), si, "deploy", [], centre, T_FOLD_S,
						mini(FOLD_MIN_WORKERS, crew_n), crew_n, deps2)
					j2["radius"] = radius
					j2["ring"] = ring_all
					jobs.append(j2)
					new_ids.append(j2["id"])
					deployed = true
			"place", "fasten":
				if items.is_empty():
					continue
				var groups := _assembly_groups(st, kind, items)
				for g in groups:
					var keys: Array = g["keys"]
					var gc := Vector3.ZERO
					for rec in g["items"]:
						gc += LinkageBuildOps.part_center(rec["obj"], rec["kind"]) * IN_TO_M
					gc /= float((g["items"] as Array).size())
					gc.y += ground
					var gkind: String = g["kind"]
					var deps3: Array = barrier.duplicate()
					for k in keys:
						if bench_job_for.has(k):
							deps3.append(bench_job_for[k])
					if module < 0:
						deps3.append_array(since_barrier)
					else:
						deps3.append_array(last_by_module.get(module, []))
					var j3 := _job(jobs.size(), si, gkind, keys, gc, float(g["work"]),
						mini(int(g["min"]), crew_n), maxi(mini(int(g["max"]), crew_n), 1), _uniq(deps3))
					j3["park"] = g.get("park", Vector3.ZERO)
					j3["approach"] = str((st.get("op", {}) as Dictionary).get("approach", "above"))
					j3["travel"] = float((st.get("op", {}) as Dictionary).get("travelIn", 24.0)) * IN_TO_M
					j3["sequential"] = bool((st.get("op", {}) as Dictionary).get("sequential", false))
					j3["deployed"] = deployed
					j3["joints"] = _joints_of(g["items"])
					j3["ring"] = ring_dep if deployed else ring_pose
					jobs.append(j3)
					new_ids.append(j3["id"])
		if new_ids.is_empty():
			continue
		if module < 0:
			barrier = new_ids
			since_barrier = []
			last_by_module = {}
		else:
			last_by_module[module] = new_ids
			since_barrier.append_array(new_ids)

	_resolve_parking(jobs, steps, pose_parts, pose_ground, radius)
	var sched := _schedule(jobs, crew_n, radius, centre)
	return {
		"jobs": jobs, "workers": sched["workers"], "makespan": sched["makespan"],
		"blocked": sched["blocked"], "crew": crew_n, "radius_m": radius, "centre_m": centre,
		# How far the site reaches from the structure's origin (culling, crew search).
		"reach_m": radius + Vector2(centre.x, centre.z).length(),
		"stations": stations, "steps": steps.size(),
		"fold": {"folded_deg": folded_deg, "pose_deg": pose_deg, "deployed_deg": deployed_deg},
		"critical_path_s": _critical_path(jobs),
		"total_work_s": _total_work(jobs),
	}


static func _job(id: int, si: int, kind: String, keys: Array, loc: Vector3, work: float,
		min_w: int, max_w: int, deps: Array) -> Dictionary:
	return {"id": id, "step": si, "kind": kind, "keys": keys, "loc": loc, "work_s": work,
		"min": maxi(1, min_w), "max": maxi(maxi(1, min_w), max_w), "deps": deps,
		"resource": "", "stand": [], "face": loc, "t0": -1.0, "t1": -1.0, "crew": [], "joints": []}


## The joints a job's parts belong to (brackets, bolts, washers, hardware
## placements): a renderer that draws the joint hardware its own way (the
## world builder's simple brackets) shows it when the joint's first job starts.
static func _joints_of(items: Array) -> Array:
	var out: Array = []
	for rec in items:
		if not (str(rec["kind"]) in ["bolt", "washer", "bracket", "placement", "hwpart"]):
			continue
		var jk := LinkagePartKeys.joint_key(rec["obj"], rec["kind"])
		if jk.begins_with("joint:") and not out.has(jk):
			out.append(jk)
	return out


static func _uniq(a: Array) -> Array:
	var seen := {}
	var out: Array = []
	for x in a:
		if not seen.has(x):
			seen[x] = true
			out.append(x)
	return out


## The module a step works on (its first selector's moduleIndex), -1 = global.
static func _module_of(step: Dictionary) -> int:
	for sel in step.get("targets", []):
		if sel is Dictionary and (sel.get("moduleIndex") is float or sel.get("moduleIndex") is int):
			return int(sel["moduleIndex"])
	return -1


## A step's work units: fasten = one per JOINT; place = one for the step, one
## per panel, or the lift (from the parked position, a crew quorum).
static func _assembly_groups(step: Dictionary, kind: String, items: Array) -> Array:
	var out: Array = []
	var op: Dictionary = step.get("op", {})
	if kind == "fasten":
		var by_joint := {}
		for rec in items:
			var jk := LinkagePartKeys.joint_key(rec["obj"], rec["kind"])
			if jk.is_empty():
				jk = rec["key"]
			if not by_joint.has(jk):
				by_joint[jk] = []
			(by_joint[jk] as Array).append(rec)
		for jk in by_joint:
			var recs: Array = by_joint[jk]
			var work := 0.0
			var keys: Array = []
			for rec in recs:
				keys.append(rec["key"])
				match str(rec["kind"]):
					"bolt":
						work += NpcCrewPlan.T_BOLT_SET_S
					"placement":
						work += NpcCrewPlan.T_HW_PART_S * 6.0
					_:
						work += 0.0
			if work <= 0.0:
				continue
			out.append({"kind": "fasten", "items": recs, "keys": keys, "work": work, "min": 1, "max": 1})
		return out
	if str(op.get("from", "")) == "parked":
		var keys2: Array = []
		for rec in items:
			keys2.append(rec["key"])
		return [{"kind": "lift", "items": items, "keys": keys2, "work": T_LIFT_S * float(NpcCrewPlan.ERECT_MIN_WORKERS),
			"min": NpcCrewPlan.ERECT_MIN_WORKERS, "max": 99}]
	var panels: Array = items.filter(func(r): return r["kind"] == "panel")
	if not panels.is_empty() and panels.size() == items.size():
		for rec in panels:
			out.append({"kind": "place", "items": [rec], "keys": [rec["key"]], "work": T_PLACE_PANEL_S, "min": 2, "max": 2})
		return out
	var keys3: Array = []
	var long_beam := false
	for rec in items:
		keys3.append(rec["key"])
		if rec["kind"] == "beam" and LinkageBuildSteps.beam_length_in(rec["obj"]) > 100.0:
			long_beam = true
	return [{"kind": "place", "items": items, "keys": keys3, "work": T_PLACE_PART_S * float(items.size()),
		"min": 2 if long_beam else 1, "max": mini(4, maxi(1, items.size()))}]


## The ring in plan: {centre (y 0), radius} from the deployed parts' centres
## (+ half a beam, so the radius reaches the outer face).
static func ring_footprint(parts: Array) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := -lo
	var pts: Array = []
	for rec in parts:
		var c := LinkageBuildOps.part_center(rec["obj"], rec["kind"]) * IN_TO_M
		var q := Vector2(c.x, c.z)
		pts.append(q)
		lo = lo.min(q)
		hi = hi.max(q)
	if pts.is_empty():
		return {"centre": Vector3.ZERO, "radius": 2.5}
	var mid := (lo + hi) * 0.5
	var r := 0.0
	for q in pts:
		r = maxf(r, (q as Vector2).distance_to(mid))
	return {"centre": Vector3(mid.x, 0.0, mid.y), "radius": r + 0.1}


## The smallest circle round two rings (the pose and the open ring).
static func ring_union(a: Dictionary, b: Dictionary) -> Dictionary:
	var ca: Vector3 = a["centre"]
	var cb: Vector3 = b["centre"]
	var mid := (ca + cb) * 0.5
	var r := maxf(mid.distance_to(ca) + float(a["radius"]), mid.distance_to(cb) + float(b["radius"]))
	return {"centre": mid, "radius": r}


## Saw and drill stations in a row outside the ring (+X side), each with a
## stand point for its worker.
static func _bench_stations(centre: Vector3, radius: float, n_saws: int, n_drills: int) -> Dictionary:
	var out := {"saw": [], "drill": []}
	var x := centre.x + radius + BENCH_GAP_M
	var z := centre.z - (n_saws + n_drills - 1) * BENCH_SPACING_M / 2.0
	for res in ["saw", "drill"]:
		for i in (n_saws if res == "saw" else n_drills):
			var pos := Vector3(x, 0.0, z)
			(out[res] as Array).append({"id": "%s%d" % [res, i], "pos": pos, "stand": [pos + Vector3(-0.55, 0, 0)]})
			z += BENCH_SPACING_M
	return out


## Parked parts (the top ring built beside the bottom one) are worked where
## they sit: shift those jobs' locations by the park offset in force.
static func _resolve_parking(jobs: Array, steps: Array, parts: Array, ground: float, radius: float) -> void:
	# compute_displacement(steps, s, parts) for every step s in ONE pass (it
	# replays every earlier step; per job that was ~2 s of a SOAK plan).
	var disp_at: Array = []
	var running := {}
	for si in steps.size():
		var step: Dictionary = steps[si]
		if str(step.get("kind", "")) == "place" and not (step.get("targets", []) as Array).is_empty():
			var park = (step.get("op", {}) as Dictionary).get("parkOffset")
			for rec in parts:
				if LinkageBuildSteps._matches_any(rec, step["targets"]):
					if park == null:
						running.erase(rec["key"])
					else:
						running[rec["key"]] = park
		disp_at.append(running.duplicate())
	for j in jobs:
		if not (str(j["kind"]) in ["place", "fasten"]) or (j["keys"] as Array).is_empty():
			continue
		var disp: Dictionary = disp_at[clampi(int(j["step"]), 0, disp_at.size() - 1)] if not disp_at.is_empty() else {}
		var k0: String = j["keys"][0]
		if disp.has(k0):
			# "beside": past the structure's +X edge by gapIn, resting on the ground.
			var gap := float((disp[k0] as Dictionary).get("gapIn", 24.0)) * IN_TO_M
			var shift := Vector3(radius * 2.0 + gap, 0.0, 0.0)
			j["loc"] = (j["loc"] as Vector3) + shift
			j["park"] = shift


# ---------------------------------------------------------------------------
# The scheduler: event-driven list scheduling with named workers
# ---------------------------------------------------------------------------

## Stand points round a job for k workers: outside the structure, spread on an
## arc facing the job. `centre` = the ring's middle in plan (ring_footprint).
static func stand_points(job: Dictionary, k: int, radius: float, centre: Vector3 = Vector3.ZERO) -> Array:
	if not (job.get("stand", []) as Array).is_empty() and k <= (job["stand"] as Array).size():
		return job["stand"]
	if job.get("ring") is Dictionary:
		centre = (job["ring"] as Dictionary)["centre"]
		radius = float((job["ring"] as Dictionary)["radius"])
	var loc: Vector3 = job["loc"]
	var c := Vector3(loc.x, 0.0, loc.z)
	if str(job["kind"]) in ["deploy", "lift"]:
		# Round the whole ring (or the parked ring), evenly.
		var ring_c := centre + ((job.get("park", Vector3.ZERO) as Vector3) if str(job["kind"]) == "lift" else Vector3.ZERO)
		ring_c.y = 0.0
		var r := radius + STAND_OFF_M * 0.5
		var pts: Array = []
		for i in k:
			var a := TAU * float(i) / float(k)
			pts.append(ring_c + Vector3(cos(a) * r, 0.0, sin(a) * r))
		return pts
	# Outward from the ring's middle (the parked ring's, for its jobs).
	var mid := centre + (job.get("park", Vector3.ZERO) as Vector3)
	var rel := Vector3(c.x - mid.x, 0.0, c.z - mid.z)
	var out_dir := rel.normalized() if rel.length() > 0.2 else Vector3(1, 0, 0)
	var side := out_dir.cross(Vector3.UP).normalized()
	var base := c + out_dir * STAND_OFF_M
	var pts2: Array = []
	for i in k:
		var off := (float(i) - float(k - 1) / 2.0) * 0.75
		pts2.append(base + side * off)
	return pts2


static func _schedule(jobs: Array, crew_n: int, radius: float, centre: Vector3 = Vector3.ZERO) -> Dictionary:
	var workers: Array = []
	for w in crew_n:
		# The crew gathers at the benches' side to start.
		var a := TAU * float(w) / float(crew_n)
		workers.append({"id": w, "pos": centre + Vector3(radius + 2.0, 0.0, 0.0) + Vector3(cos(a), 0.0, sin(a)) * 1.2,
			"free_at": 0.0, "segments": []})
	var done := {}
	var started := {}
	var res_free := {}                 # resource -> free_at
	var blocked: Array = []
	var prio := _priorities(jobs)
	var now := 0.0
	var remaining := jobs.size()
	var guard := 0
	while remaining > 0 and guard < 200000:
		guard += 1
		# Ready jobs: deps done, not started; highest priority first.
		var ready: Array = []
		for j in jobs:
			if started.has(j["id"]):
				continue
			var ok := true
			for d in j["deps"]:
				if not done.has(d) or float(done[d]) > now + 1e-6:
					ok = false
					break
			if ok:
				ready.append(j)
		ready.sort_custom(func(a, b):
			if float(prio[a["id"]]) != float(prio[b["id"]]):
				return float(prio[a["id"]]) > float(prio[b["id"]])
			return int(a["id"]) < int(b["id"]))
		var assigned_any := false
		for j in ready:
			var res := str(j["resource"])
			if not res.is_empty() and float(res_free.get(res, 0.0)) > now + 1e-6:
				continue
			var free: Array = workers.filter(func(w): return float(w["free_at"]) <= now + 1e-6)
			if free.size() < int(j["min"]):
				continue
			var k := mini(free.size(), int(j["max"]))
			var stands := stand_points(j, k, radius, centre)
			# Nearest workers to the job, deterministic ties on id.
			free.sort_custom(func(a, b):
				var da := (a["pos"] as Vector3).distance_to(stands[0])
				var db := (b["pos"] as Vector3).distance_to(stands[0])
				if absf(da - db) > 1e-6:
					return da < db
				return int(a["id"]) < int(b["id"]))
			var crew: Array = free.slice(0, k)
			var arrive := now
			for i in crew.size():
				var w: Dictionary = crew[i]
				arrive = maxf(arrive, now + (w["pos"] as Vector3).distance_to(stands[mini(i, stands.size() - 1)]) / WALK_MPS)
			var t1 := arrive + float(j["work_s"]) / float(k)
			for i in crew.size():
				var w: Dictionary = crew[i]
				var stand: Vector3 = stands[mini(i, stands.size() - 1)]
				var walk_end := now + (w["pos"] as Vector3).distance_to(stand) / WALK_MPS
				var carry := str(j["kind"]) == "place" and not (j["keys"] as Array).is_empty() \
					and str(j["keys"][0]).begins_with("beam:")
				if walk_end > now + 1e-6:
					(w["segments"] as Array).append({"kind": "carry" if carry else "walk", "t0": now, "t1": walk_end,
						"from": w["pos"], "to": stand, "job": j["id"]})
				if arrive > walk_end + 1e-6:
					(w["segments"] as Array).append({"kind": "wait", "t0": walk_end, "t1": arrive,
						"from": stand, "to": stand, "job": j["id"]})
				(w["segments"] as Array).append({"kind": "work", "t0": arrive, "t1": t1,
					"from": stand, "to": stand, "job": j["id"], "slot": i})
				w["pos"] = stand
				w["free_at"] = t1
			j["t0"] = arrive
			j["t1"] = t1
			j["crew"] = crew.map(func(w): return w["id"])
			started[j["id"]] = true
			done[j["id"]] = t1
			if not res.is_empty():
				res_free[res] = t1
			remaining -= 1
			assigned_any = true
		if remaining <= 0:
			break
		# Advance to the next moment something can change.
		var next := INF
		for w in workers:
			if float(w["free_at"]) > now + 1e-6:
				next = minf(next, float(w["free_at"]))
		for d in done:
			if float(done[d]) > now + 1e-6:
				next = minf(next, float(done[d]))
		for r in res_free:
			if float(res_free[r]) > now + 1e-6:
				next = minf(next, float(res_free[r]))
		if next == INF:
			if not assigned_any:
				# Nothing running and nothing can start: a quorum the crew can
				# never meet (or a dependency on such a job). Record and stop.
				for j in jobs:
					if not started.has(j["id"]):
						blocked.append(j["id"])
				break
			continue
		now = next
	var makespan := 0.0
	for j in jobs:
		makespan = maxf(makespan, float(j["t1"]))
	return {"workers": workers, "makespan": makespan, "blocked": blocked}


## Longest remaining work path from each job (list-scheduling priority).
static func _priorities(jobs: Array) -> Dictionary:
	var succ := {}
	for j in jobs:
		for d in j["deps"]:
			if not succ.has(d):
				succ[d] = []
			(succ[d] as Array).append(j["id"])
	var memo := {}
	for i in range(jobs.size() - 1, -1, -1):
		var j: Dictionary = jobs[i]
		var best := 0.0
		for s in succ.get(j["id"], []):
			best = maxf(best, float(memo.get(s, 0.0)))
		memo[j["id"]] = float(j["work_s"]) / float(j["max"]) + best
	return memo


static func _critical_path(jobs: Array) -> float:
	var p := _priorities(jobs)
	var best := 0.0
	for k in p:
		best = maxf(best, float(p[k]))
	return best


static func _total_work(jobs: Array) -> float:
	var s := 0.0
	for j in jobs:
		s += float(j["work_s"])
	return s


# ---------------------------------------------------------------------------
# state_at: a pure function of build time
# ---------------------------------------------------------------------------

## Everything the build site draws at build time t:
##   workers: [{id, pos: Vector3, face: Vector3 (point faced), activity:
##     "idle"|"walk"|"carry"|"wait"|"work", job, kind, clip, clip_t, tool, u}]
##   parts: {key: {visible: bool, offset: Vector3 (metres), u}}
##   joints: {joint key: {visible, offset}} — for hardware a renderer keys by
##     joint rather than by part (see _joints_of)
##   fold_deg, jobs_done, step (the latest step under way)
static func state_at(tl: Dictionary, t: float) -> Dictionary:
	var jobs: Array = tl["jobs"]
	var workers_out: Array = []
	for w in tl["workers"]:
		workers_out.append(_worker_at(w, jobs, t))
	var parts := {}
	var joints := {}
	var done := 0
	var step := -1
	for j in jobs:
		var t0 := float(j["t0"])
		var t1 := float(j["t1"])
		if t0 < 0.0:
			continue
		if t >= t1:
			done += 1
		if t >= t0:
			step = maxi(step, int(j["step"]))
		var kind := str(j["kind"])
		if not (kind in ["place", "lift", "fasten"]):
			continue
		var u := clampf((t - t0) / maxf(t1 - t0, 1e-6), 0.0, 1.0)
		var keys: Array = j["keys"]
		var n := keys.size()
		# Joint hardware: hidden until the joint's first job starts, then where
		# that job's parts are (parked beside the ring until the lift).
		var jpark: Vector3 = j.get("park", Vector3.ZERO)
		if kind == "lift":
			jpark = jpark * (1.0 - LinkageBuildSteps.ease_in_out_cubic(u))
		for jk in j.get("joints", []):
			if t >= t0:
				joints[jk] = {"visible": true, "offset": jpark}
			elif not joints.has(jk):
				joints[jk] = {"visible": false, "offset": Vector3.ZERO}
		if kind == "fasten":
			# Bolts, washers and hardware go in when their joint is fastened.
			var jk0: String = str((j.get("joints", []) as Array).front()) if not (j.get("joints", []) as Array).is_empty() else ""
			for k in keys:
				if t >= t0:
					parts[k] = {"visible": true, "offset": jpark, "u": u, "joint": jk0}
				elif not parts.has(k):
					parts[k] = {"visible": false, "offset": Vector3.ZERO, "u": 0.0}
			continue
		for i in n:
			var k: String = keys[i]
			if kind == "lift":
				# Lifted from the parked spot: the park offset winds back to 0.
				var park: Vector3 = j.get("park", Vector3.ZERO)
				if t < t0:
					continue
				parts[k] = {"visible": true, "offset": park * (1.0 - LinkageBuildSteps.ease_in_out_cubic(u)), "u": u}
				continue
			if t < t0:
				if not parts.has(k):
					parts[k] = {"visible": false, "offset": Vector3.ZERO, "u": 0.0}
				continue
			var uu := LinkageBuildSteps.sequence_progress(u, i, n, LinkageBuildOps.OVERLAP_PLACE) if bool(j.get("sequential", false)) else u
			var e := LinkageBuildSteps.ease_in_out_cubic(uu)
			var dir := Vector3.UP if str(j.get("approach", "above")) != "radial" \
				else Vector3((j["loc"] as Vector3).x, 0, (j["loc"] as Vector3).z).normalized()
			var park2: Vector3 = j.get("park", Vector3.ZERO)
			parts[k] = {"visible": uu > 0.0 or t >= t1, "offset": park2 + dir * float(j.get("travel", 0.6)) * (1.0 - e), "u": uu}
	# (Parked parts keep their park offset until the lift job — later in id
	# order, so it overrides them above — winds it back.) Fastened hardware
	# rides with its joint, which the lift moved.
	for k in parts:
		var jk: String = str(parts[k].get("joint", ""))
		if not jk.is_empty() and joints.has(jk):
			parts[k]["offset"] = joints[jk]["offset"]
	var fold := tl["fold"] as Dictionary
	var fold_deg := float(fold["pose_deg"])
	for j in jobs:
		if str(j["kind"]) == "deploy" and float(j["t0"]) >= 0.0:
			var u2 := clampf((t - float(j["t0"])) / maxf(float(j["t1"]) - float(j["t0"]), 1e-6), 0.0, 1.0)
			fold_deg = lerpf(float(fold["pose_deg"]), float(fold["deployed_deg"]), LinkageBuildSteps.ease_in_out_cubic(u2))
	return {"workers": workers_out, "parts": parts, "joints": joints, "fold_deg": fold_deg, "jobs_done": done, "step": step,
		"t": t, "makespan": float(tl["makespan"])}


static func _worker_at(w: Dictionary, jobs: Array, t: float) -> Dictionary:
	var segs: Array = w["segments"]
	var out := {"id": w["id"], "activity": "idle", "job": -1, "kind": "", "clip": "", "clip_t": 0.0,
		"tool": "", "u": 0.0}
	if segs.is_empty():
		out["pos"] = w["pos"]
		out["face"] = (w["pos"] as Vector3) + Vector3(0, 0, 1)
		return out
	# The segment under way (binary search would do; lanes are short).
	var seg: Dictionary = segs[0]
	if t < float(seg["t0"]):
		out["pos"] = seg["from"]
		out["face"] = seg["to"]
		return out
	var cur: Dictionary = {}
	for s in segs:
		if t >= float(s["t0"]) and t < float(s["t1"]):
			cur = s
			break
	if cur.is_empty():
		# Between segments (idle where the last one left off) or after the end.
		var last: Dictionary = segs[0]
		for s in segs:
			if float(s["t1"]) <= t:
				last = s
		out["pos"] = last["to"]
		out["face"] = (last["to"] as Vector3) + ((last["to"] as Vector3) - (last["from"] as Vector3)).normalized() \
			if (last["to"] as Vector3).distance_to(last["from"]) > 0.01 else (last["to"] as Vector3) + Vector3(0, 0, 1)
		return out
	var job: Dictionary = jobs[int(cur["job"])]
	var kind := str(job["kind"])
	var u := clampf((t - float(cur["t0"])) / maxf(float(cur["t1"]) - float(cur["t0"]), 1e-6), 0.0, 1.0)
	out["job"] = job["id"]
	out["kind"] = kind
	out["u"] = u
	match str(cur["kind"]):
		"walk", "carry":
			out["activity"] = cur["kind"]
			out["pos"] = (cur["from"] as Vector3).lerp(cur["to"], u)
			out["face"] = cur["to"]
			if str(cur["kind"]) == "carry":
				out["clip"] = CLIP_FOR_KIND["carry"]
				out["clip_t"] = t - float(cur["t0"])
		"wait":
			out["activity"] = "wait"
			out["pos"] = cur["to"]
			out["face"] = job["face"] if job.has("face") else job["loc"]
		"work":
			out["activity"] = "work"
			out["pos"] = cur["to"]
			out["face"] = Vector3((job["face"] as Vector3).x, 0.0, (job["face"] as Vector3).z) \
				if str(job["kind"]) in ["cut", "drill"] else Vector3((job["loc"] as Vector3).x, 0.0, (job["loc"] as Vector3).z)
			out["clip"] = str(CLIP_FOR_KIND.get(kind, "hold_brace"))
			out["clip_t"] = t - float(cur["t0"])
			out["tool"] = str(TOOL_FOR_KIND.get(kind, ""))
	return out


## A one-line readout: "crew 9 · 3 h 10 min · 214 jobs".
static func summary(tl: Dictionary) -> String:
	var s := int(tl["makespan"])
	return "crew %d · %d h %02d min · %s%s" % [int(tl["crew"]), s / 3600, (s % 3600) / 60,
		UiText.count((tl["jobs"] as Array).size(), "job"), (" · %d blocked" % (tl["blocked"] as Array).size()) if not (tl["blocked"] as Array).is_empty() else ""]
