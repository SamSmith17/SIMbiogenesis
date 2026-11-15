class_name CrewJobPlan
extends RefCounted

## A small crew job (a meal, a toilet clean, a water run) as a schedule of
## named workers moving between STATIONS: the generic layer under the meal
## plans (NPC life pass, Phase 7). Pure; deterministic.
##
##   stations = {name: {pos: Vector3 (where a worker stands), face: Vector3
##               (what they face), side: Vector3 (along the counter; more
##               workers stand side by side along it)}}   (local metres)
##   job = {id, kind, label, station, deps: [ids], min, max, work_s (person-
##          seconds), clip, rig, tool, unattended (min 0: it runs by itself
##          for work_s once started)}
##
## `plan(jobs, stations, crew_n)` -> timeline {jobs, workers, makespan,
## blocked, crew, stations}. List scheduling: whenever workers are free, the
## ready job with the longest remaining chain takes as many of the nearest
## free workers as it allows (min..max); they walk to the station (side by
## side along it), work work_s / crew, and are free again. `state_at(tl, t)`
## is a pure function of time: who stands where doing what, every job's
## progress. The Phase 8 plan wanted the pallet rack's scheduler lifted out
## here; that scheduler is bound up with the rack's carries and holds, so
## this is a separate, simpler one and the rack keeps its own (follow-up).

const WALK_MPS := 1.1
const SIDE_STEP_M := 0.7
const START := "start"


static func job(id: int, kind: String, label: String, station: String, deps: Array, crew_min: int,
		crew_max: int, work_s: float, opts: Dictionary = {}) -> Dictionary:
	var j := {"id": id, "kind": kind, "label": label, "station": station,
		"deps": deps.duplicate(), "min": maxi(crew_min, 0), "max": maxi(crew_max, maxi(crew_min, 1)),
		"work_s": maxf(work_s, 0.0), "clip": "", "rig": "", "tool": "", "unattended": crew_min <= 0,
		"t0": -1.0, "t1": -1.0, "crew": []}
	j.merge(opts, true)
	return j


## Where worker k of `n` at a station stands (side by side along `side`).
static func stand_at(st: Dictionary, k: int, n: int) -> Vector3:
	var p: Vector3 = st.get("pos", Vector3.ZERO)
	var side: Vector3 = st.get("side", Vector3.RIGHT)
	if side.length() < 1e-4:
		side = Vector3.RIGHT
	var off := (float(k) - float(n - 1) * 0.5) * SIDE_STEP_M
	return p + side.normalized() * off


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## Longest remaining chain (seconds of work at max crew) from each job.
static func _priorities(jobs: Array) -> Dictionary:
	var succ := {}
	for j in jobs:
		for d in j["deps"]:
			if not succ.has(d):
				succ[d] = []
			(succ[d] as Array).append(j["id"])
	var memo := {}
	var out := {}
	for j in jobs:
		out[j["id"]] = _chain(int(j["id"]), jobs, succ, memo)
	return out


static func _chain(id: int, jobs: Array, succ: Dictionary, memo: Dictionary) -> float:
	if memo.has(id):
		return memo[id]
	var j: Dictionary = jobs[id]
	var own := float(j["work_s"]) / float(maxi(int(j["max"]), 1)) if not bool(j["unattended"]) else float(j["work_s"])
	var best := 0.0
	for s in succ.get(id, []):
		best = maxf(best, _chain(int(s), jobs, succ, memo))
	memo[id] = own + best
	return own + best


## Schedule `jobs` (ids must be their indices) for `crew_n` workers who start
## at `stations[START]` (or the first station).
static func plan(jobs: Array, stations: Dictionary, crew_n: int) -> Dictionary:
	var start_pos := Vector3.ZERO
	if stations.has(START):
		start_pos = (stations[START] as Dictionary).get("pos", Vector3.ZERO)
	elif not stations.is_empty():
		start_pos = (stations[stations.keys()[0]] as Dictionary).get("pos", Vector3.ZERO)
	var workers: Array = []
	for w in maxi(crew_n, 0):
		workers.append({"id": w, "pos": start_pos + Vector3.RIGHT * SIDE_STEP_M * (float(w) - float(crew_n - 1) * 0.5),
			"free_at": 0.0, "segments": []})
	var prio := _priorities(jobs)
	var nd := {}
	var succ := {}
	for j in jobs:
		nd[j["id"]] = (j["deps"] as Array).size()
		for d in j["deps"]:
			if not succ.has(d):
				succ[d] = []
			(succ[d] as Array).append(j["id"])
	var ready_at := {}
	for j in jobs:
		if int(nd[j["id"]]) == 0:
			ready_at[j["id"]] = 0.0
	var now := 0.0
	var remaining := jobs.size()
	var guard := 0
	while remaining > 0 and guard < 100000:
		guard += 1
		var ready: Array = []
		for jid in ready_at:
			if float(ready_at[jid]) <= now + 1e-6:
				ready.append(jid)
		ready.sort_custom(func(a, c) -> bool:
			if absf(float(prio[a]) - float(prio[c])) > 1e-9:
				return float(prio[a]) > float(prio[c])
			return int(a) < int(c))
		var assigned := false
		for jid in ready:
			var j: Dictionary = jobs[jid]
			var crew: Array = []
			if not bool(j["unattended"]):
				var free: Array = workers.filter(func(w) -> bool: return float(w["free_at"]) <= now + 1e-6)
				if free.size() < maxi(int(j["min"]), 1):
					continue
				var st: Dictionary = stations.get(str(j["station"]), {})
				var target: Vector3 = st.get("pos", Vector3.ZERO)
				free.sort_custom(func(a, c) -> bool:
					var da := _flat(a["pos"]).distance_to(_flat(target))
					var dc := _flat(c["pos"]).distance_to(_flat(target))
					if absf(da - dc) > 1e-6:
						return da < dc
					return int(a["id"]) < int(c["id"]))
				crew = free.slice(0, mini(free.size(), int(j["max"])))
			_assign(j, crew, now, stations)
			ready_at.erase(jid)
			remaining -= 1
			assigned = true
			for sj in succ.get(jid, []):
				nd[sj] = int(nd[sj]) - 1
				if int(nd[sj]) == 0:
					var t := 0.0
					for d in jobs[sj]["deps"]:
						t = maxf(t, float(jobs[d]["t1"]))
					ready_at[sj] = t
		if remaining <= 0:
			break
		var next := INF
		for w in workers:
			if float(w["free_at"]) > now + 1e-6:
				next = minf(next, float(w["free_at"]))
		for jid in ready_at:
			if float(ready_at[jid]) > now + 1e-6:
				next = minf(next, float(ready_at[jid]))
		if next == INF:
			if not assigned:
				break
			continue
		now = next
	var blocked: Array = []
	var makespan := 0.0
	var person_s := 0.0
	for j in jobs:
		if float(j["t1"]) < 0.0:
			blocked.append(j["id"])
		makespan = maxf(makespan, float(j["t1"]))
		if not bool(j["unattended"]):
			person_s += float(j["work_s"])
	return {"jobs": jobs, "workers": workers, "makespan": makespan, "blocked": blocked,
		"crew": crew_n, "stations": stations, "person_s": person_s}


static func _assign(j: Dictionary, crew: Array, now: float, stations: Dictionary) -> void:
	if crew.is_empty():
		j["t0"] = now
		j["t1"] = now + float(j["work_s"])
		return
	var st: Dictionary = stations.get(str(j["station"]), {})
	var face: Vector3 = st.get("face", st.get("pos", Vector3.ZERO) + Vector3.FORWARD)
	var arrive := now
	var spots: Array = []
	for i in crew.size():
		var w: Dictionary = crew[i]
		var spot := stand_at(st, i, crew.size())
		spots.append(spot)
		arrive = maxf(arrive, now + _flat(w["pos"]).distance_to(_flat(spot)) / WALK_MPS)
	var t1 := arrive + float(j["work_s"]) / float(crew.size())
	j["t0"] = arrive
	j["t1"] = t1
	var ids: Array = []
	for i in crew.size():
		var w: Dictionary = crew[i]
		var spot: Vector3 = spots[i]
		var segs: Array = w["segments"]
		var t_walk := _flat(w["pos"]).distance_to(_flat(spot)) / WALK_MPS
		if t_walk > 1e-3:
			segs.append({"kind": "walk", "t0": now, "t1": now + t_walk, "from": w["pos"], "to": spot})
		if now + t_walk < arrive - 1e-3:
			segs.append({"kind": "wait", "t0": now + t_walk, "t1": arrive, "from": spot, "to": spot,
				"face": face})
		segs.append({"kind": "work", "t0": arrive, "t1": t1, "from": spot, "to": spot, "face": face,
			"job": int(j["id"])})
		w["pos"] = spot
		w["free_at"] = t1
		ids.append(int(w["id"]))
	j["crew"] = ids


## Who is where doing what at time t (seconds): {t, workers: [{id, pos, face,
## activity "walk" | "wait" | "work" | "idle", job, clip, rig, tool, label,
## u (0..1 through the job)}], jobs: {id: frac done}, done: n, current: [labels]}.
static func state_at(tl: Dictionary, t: float) -> Dictionary:
	var jobs: Array = tl.get("jobs", [])
	var ws: Array = []
	for w in tl.get("workers", []):
		ws.append(_worker_at(w, jobs, t))
	var fr := {}
	var done := 0
	var cur: Array = []
	for j in jobs:
		var a := float(j["t0"])
		var b := float(j["t1"])
		var f := 0.0
		if a >= 0.0:
			f = 1.0 if t >= b else (clampf((t - a) / maxf(b - a, 1e-6), 0.0, 1.0) if t > a else 0.0)
		fr[j["id"]] = f
		if f >= 1.0:
			done += 1
		elif f > 0.0:
			cur.append(str(j["label"]))
	return {"t": t, "workers": ws, "jobs": fr, "done": done, "current": cur}


static func _worker_at(w: Dictionary, jobs: Array, t: float) -> Dictionary:
	var segs: Array = w["segments"]
	var out := {"id": int(w["id"]), "pos": w["pos"], "face": Vector3.ZERO, "activity": "idle", "job": -1,
		"clip": "", "rig": "", "tool": "", "label": "", "u": 0.0}
	if segs.is_empty():
		return out
	var s: Dictionary = segs[0]
	if t < float(s["t0"]):
		out["pos"] = s["from"]
		return out
	for sd in segs:
		if t >= float(sd["t0"]) and t < float(sd["t1"]):
			s = sd
			break
		if t >= float(sd["t1"]):
			s = sd
	var a := float(s["t0"])
	var b := float(s["t1"])
	var inside := t < b
	match str(s["kind"]):
		"walk":
			if inside:
				var f := clampf((t - a) / maxf(b - a, 1e-6), 0.0, 1.0)
				var p: Vector3 = (s["from"] as Vector3).lerp(s["to"], f)
				out["pos"] = p
				out["face"] = s["to"]
				out["activity"] = "walk"
			else:
				out["pos"] = s["to"]
		"wait":
			out["pos"] = s["to"]
			out["face"] = s.get("face", Vector3.ZERO)
			out["activity"] = "wait" if inside else "idle"
		"work":
			out["pos"] = s["to"]
			out["face"] = s.get("face", Vector3.ZERO)
			if inside:
				var j: Dictionary = jobs[int(s["job"])]
				out["activity"] = "work"
				out["job"] = int(s["job"])
				out["clip"] = str(j.get("clip", ""))
				out["rig"] = str(j.get("rig", ""))
				out["tool"] = str(j.get("tool", ""))
				out["label"] = str(j.get("label", ""))
				out["u"] = clampf((t - a) / maxf(b - a, 1e-6), 0.0, 1.0)
	return out


## The longest dependency chain in seconds (each job at its scheduled length).
static func critical_path(tl: Dictionary) -> float:
	var jobs: Array = tl.get("jobs", [])
	var memo := {}
	var best := 0.0
	for j in jobs:
		best = maxf(best, _cp(int(j["id"]), jobs, memo))
	return best


static func _cp(id: int, jobs: Array, memo: Dictionary) -> float:
	if memo.has(id):
		return memo[id]
	var j: Dictionary = jobs[id]
	var own := maxf(float(j["t1"]) - float(j["t0"]), 0.0)
	var best := 0.0
	for d in j["deps"]:
		best = maxf(best, _cp(int(d), jobs, memo))
	memo[id] = own + best
	return own + best


static func summary(tl: Dictionary) -> String:
	return "%d jobs, crew %d, %s, %s of work" % [(tl.get("jobs", []) as Array).size(), int(tl.get("crew", 0)),
		UiText.duration(float(tl.get("makespan", 0.0)) / 3600.0),
		UiText.duration(float(tl.get("person_s", 0.0)) / 3600.0)]
