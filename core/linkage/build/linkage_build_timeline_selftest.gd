extends SceneTree
## Offline selftest for LinkageBuildTimeline (fabrication swarm B4): the crew
## schedule with worker identity and its pure state_at.
##
## Run: Godot.exe.exe --headless --path . --script core/linkage/build/linkage_build_timeline_selftest.gd

const EXPECTED_CHECKS := 27

var _fails := 0
var _checks := 0


func _initialize() -> void:
	var p := _soak()
	_test_structure(p)
	_test_crew_scaling(p)
	_test_state_at(p)
	_test_quorum()
	_test_ring_centre(p)
	var count_ok := EXPECTED_CHECKS == 0 or _checks == EXPECTED_CHECKS
	if not count_ok:
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0 and count_ok:
		print("LINKAGE BUILD TIMELINE SELFTEST: PASS (%d checks)" % _checks)
	else:
		print("LINKAGE BUILD TIMELINE SELFTEST: FAIL (%d/%d)" % [_fails, _checks])
	quit(0 if _fails == 0 and count_ok else 1)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", label)


func _soak() -> LinkageParams:
	var f := FileAccess.open("res://core/linkage/presets/ll_starshade_v1_soak_2026.json", FileAccess.READ)
	var p := LinkageParams.new()
	p.from_config(JSON.parse_string(f.get_as_text()))
	return p


func _signature(tl: Dictionary) -> String:
	var parts: PackedStringArray = []
	for j in tl["jobs"]:
		parts.append("%d:%.4f-%.4f:%s" % [int(j["id"]), float(j["t0"]), float(j["t1"]), str(j["crew"])])
	return "|".join(parts)


func _test_structure(p: LinkageParams) -> void:
	var tl := LinkageBuildTimeline.plan(p, [], 9)
	var jobs: Array = tl["jobs"]
	print("  SOAK, crew 9: ", LinkageBuildTimeline.summary(tl), " (critical path %d min, work %d h)" % [
		int(float(tl["critical_path_s"]) / 60.0), int(float(tl["total_work_s"]) / 3600.0)])
	_check(jobs.size() > 100, "the SOAK build makes jobs (%d)" % jobs.size())
	var kinds := {}
	for j in jobs:
		kinds[j["kind"]] = int(kinds.get(j["kind"], 0)) + 1
	_check(kinds.has("cut") and kinds.has("drill") and kinds.has("place") and kinds.has("fasten")
		and kinds.has("lift") and kinds.has("deploy"), "every job kind present: %s" % str(kinds))
	_check((tl["blocked"] as Array).is_empty(), "nothing blocked with 9 hands")
	_check(_signature(tl) == _signature(LinkageBuildTimeline.plan(p, [], 9)), "planning is deterministic")
	# Dependencies, quorum, double-booking.
	var by_id := {}
	for j in jobs:
		by_id[j["id"]] = j
	var dep_bad := 0
	var crew_bad := 0
	for j in jobs:
		for d in j["deps"]:
			if float(by_id[d]["t1"]) > float(j["t0"]) + 1e-6:
				dep_bad += 1
		var n := (j["crew"] as Array).size()
		if n < int(j["min"]) or n > int(j["max"]):
			crew_bad += 1
	_check(dep_bad == 0, "every job starts after its dependencies end (%d late)" % dep_bad)
	_check(crew_bad == 0, "every job's crew within its min..max (%d off)" % crew_bad)
	var overlap := 0
	var carries := 0
	for w in tl["workers"]:
		var last_t1 := 0.0
		for s in w["segments"]:
			if float(s["t0"]) < last_t1 - 1e-6:
				overlap += 1
			last_t1 = float(s["t1"])
			if s["kind"] == "carry":
				carries += 1
	_check(overlap == 0, "no worker is in two places at once (%d overlaps)" % overlap)
	_check(carries > 0, "beams are carried to the structure (%d carry legs)" % carries)
	# A beam is cut before it is drilled before it is placed.
	var order_bad := 0
	var cut_t := {}
	var drill_t := {}
	for j in jobs:
		if j["kind"] == "cut":
			cut_t[j["keys"][0]] = float(j["t1"])
		elif j["kind"] == "drill":
			drill_t[j["keys"][0]] = float(j["t0"])
			if cut_t.has(j["keys"][0]) and float(j["t0"]) < float(cut_t[j["keys"][0]]) - 1e-6:
				order_bad += 1
	for j in jobs:
		if j["kind"] == "place":
			for k in j["keys"]:
				if drill_t.has(k) and float(j["t0"]) < float(drill_t[k]) - 1e-6:
					order_bad += 1
	_check(order_bad == 0, "cut -> drill -> place per beam (%d out of order)" % order_bad)
	var lift_ok := false
	for j in jobs:
		if j["kind"] == "lift":
			lift_ok = (j["crew"] as Array).size() >= NpcCrewPlan.ERECT_MIN_WORKERS
	_check(lift_ok, "the lift waits for a raising crew of %d" % NpcCrewPlan.ERECT_MIN_WORKERS)
	var mk := float(tl["makespan"])
	_check(mk >= float(tl["critical_path_s"]) - 1e-3, "makespan >= the critical path")
	_check(mk >= float(tl["total_work_s"]) / 9.0 - 1e-3, "makespan >= total work / crew")


func _test_crew_scaling(p: LinkageParams) -> void:
	var m3 := float(LinkageBuildTimeline.plan(p, [], 3)["makespan"])
	var m9 := float(LinkageBuildTimeline.plan(p, [], 9)["makespan"])
	var m18 := float(LinkageBuildTimeline.plan(p, [], 18)["makespan"])
	print("  makespan: crew 3 %.1f h, 9 %.1f h, 18 %.1f h" % [m3 / 3600.0, m9 / 3600.0, m18 / 3600.0])
	_check(m9 < m3, "nine hands beat three")
	_check(m18 <= m9 * 1.05, "more hands never (much) worse")


func _test_state_at(p: LinkageParams) -> void:
	var tl := LinkageBuildTimeline.plan(p, [], 9)
	var mk := float(tl["makespan"])
	var s0 := LinkageBuildTimeline.state_at(tl, 0.0)
	var visible0 := 0
	for k in s0["parts"]:
		if bool(s0["parts"][k]["visible"]):
			visible0 += 1
	_check(visible0 == 0, "nothing stands at t = 0")
	var s1 := LinkageBuildTimeline.state_at(tl, mk + 1.0)
	var hidden := 0
	var offset := 0
	for k in s1["parts"]:
		if not bool(s1["parts"][k]["visible"]):
			hidden += 1
		if (s1["parts"][k]["offset"] as Vector3).length() > 1e-4:
			offset += 1
	_check(hidden == 0 and offset == 0, "at the end every placed part stands seated (%d hidden, %d off)" % [hidden, offset])
	_check(absf(float(s1["fold_deg"]) - float(tl["fold"]["deployed_deg"])) < 1e-3, "and the ring is deployed")
	_check(int(s1["jobs_done"]) == (tl["jobs"] as Array).size(), "and every job is done")
	# Scrub: any t, any order, same answer.
	var mid := mk * 0.37
	var a := JSON.stringify(LinkageBuildTimeline.state_at(tl, mid))
	LinkageBuildTimeline.state_at(tl, mk * 0.9)
	var b := JSON.stringify(LinkageBuildTimeline.state_at(tl, mid))
	_check(a == b, "state_at is pure: scrubbing back gives the same state")
	# Workers mid-build: positions finite, a working one has a clip.
	var sm := LinkageBuildTimeline.state_at(tl, mid)
	var finite := true
	var working := 0
	var tooled := 0
	for w in sm["workers"]:
		var pos: Vector3 = w["pos"]
		if not pos.is_finite():
			finite = false
		if w["activity"] == "work":
			working += 1
			if not str(w["clip"]).is_empty() and NpcAnimClip.load_clip(str(w["clip"])) == null:
				finite = false
		if not str(w["tool"]).is_empty():
			tooled += 1
	_check(finite, "workers have finite positions and real clips")
	_check(working > 0, "someone is working at %.0f%% (%d)" % [37.0, working])
	# Parts appear monotonically.
	var last := -1
	var mono := true
	for i in 21:
		var st := LinkageBuildTimeline.state_at(tl, mk * float(i) / 20.0)
		var v := 0
		for k in st["parts"]:
			if bool(st["parts"][k]["visible"]):
				v += 1
		if v < last:
			mono = false
		last = v
	_check(mono, "the structure only ever grows")


## A crew smaller than a job's quorum (the raising wants six) lifts with
## everyone it has: the quorum is clamped to the crew, so a small crew's
## rehearsal still finishes — slower, with all hands on the ring.
func _test_quorum() -> void:
	var p := _soak()
	var tl := LinkageBuildTimeline.plan(p, [], 3)
	var lift_crew := 0
	for j in tl["jobs"]:
		if j["kind"] == "lift":
			lift_crew = (j["crew"] as Array).size()
	_check(lift_crew == 3, "a crew of three lifts together (quorum clamped to the crew)")


## The crew's circles (deploy, lift) and the benches are measured from the
## ring's real middle. The solver chains the modules from module 0 at the
## origin, so the origin is on the ring's edge: centring the deploy circle
## there put the whole crew in a ring off to one side of the structure.
func _test_ring_centre(p: LinkageParams) -> void:
	var tl := LinkageBuildTimeline.plan(p, [], 12)
	var fold: Dictionary = tl["fold"]
	var mids := {}
	for which in ["pose_deg", "deployed_deg"]:
		var parts := LinkagePartKeys.collect_parts(LinkagePartKeys.part_data(p, deg_to_rad(float(fold[which]))))
		var lo := Vector2(INF, INF)
		var hi := -lo
		for rec in parts:
			var c := LinkageBuildOps.part_center(rec["obj"], rec["kind"]) * LinkageBuildTimeline.IN_TO_M
			lo = lo.min(Vector2(c.x, c.z))
			hi = hi.max(Vector2(c.x, c.z))
		mids[which] = (lo + hi) * 0.5
	var dep_mid: Vector2 = mids["deployed_deg"]
	var pose_mid: Vector2 = mids["pose_deg"]
	var lift: Dictionary = {}
	var deploy: Dictionary = {}
	var fasten_after: Dictionary = {}
	for j in tl["jobs"]:
		match str(j["kind"]):
			"lift":
				if lift.is_empty():
					lift = j
			"deploy":
				deploy = j
			"fasten":
				if bool(j.get("deployed", false)) and fasten_after.is_empty():
					fasten_after = j
	var lc: Vector3 = (lift["ring"] as Dictionary)["centre"]
	_check(Vector2(lc.x, lc.z).distance_to(pose_mid) < 0.05 and dep_mid.length() > 1.0,
		"the lift is worked round the half-folded ring's middle (%s), not the origin" % lc)
	var dc: Vector3 = (deploy["ring"] as Dictionary)["centre"]
	var dr := float((deploy["ring"] as Dictionary)["radius"])
	_check(dr >= Vector2(dc.x, dc.z).distance_to(dep_mid) and dr >= Vector2(dc.x, dc.z).distance_to(pose_mid),
		"the deploy circle encloses both the folded and the open ring")
	var pts := LinkageBuildTimeline.stand_points(deploy, 12, 0.0)
	var mean := Vector3.ZERO
	var outside := true
	for q in pts:
		mean += q as Vector3
		if Vector2((q as Vector3).x - dc.x, (q as Vector3).z - dc.z).length() < dr:
			outside = false
	mean /= float(pts.size())
	_check(Vector2(mean.x - dc.x, mean.z - dc.z).length() < 0.05 and outside,
		"the deploy crew stands evenly round that circle, everyone outside it")
	var centre: Vector3 = tl["centre_m"]
	var radius := float(tl["radius_m"])
	var benches_out := true
	for res in ["saw", "drill"]:
		for st in tl["stations"][res]:
			var bp: Vector3 = st["pos"]
			if Vector2(bp.x - centre.x, bp.z - centre.z).length() < radius + 1.0:
				benches_out = false
	_check(benches_out and (fasten_after.is_empty() or (fasten_after["ring"] as Dictionary)["centre"] != lc),
		"the benches stand outside both rings; work after the deploy is round the open ring")
