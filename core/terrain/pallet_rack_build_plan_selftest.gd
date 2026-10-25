extends SceneTree
## PalletRackBuildPlan (offline): the Mars build lab's sequence on our racks.
##   Godot --headless --path . --script core/terrain/pallet_rack_build_plan_selftest.gd
## Pins: the "Build a rack bay" design plans with the web scenario's crew of
## six and nothing left that can't start; every job after its dependencies,
## within its crew; no worker in two places at once; a raised frame is held
## by its raisers until the bay's release, and beams are seated only while
## both frames stand; high beams wait for the release and take four; decks
## wait for the beams under them; four people can't build (two frames held +
## two seaters); more hands are not slower; state_at: everything in the piles
## at the start, everything installed at the end, installed pieces only grow,
## scrubbing back gives the same state; the visitor ends up on the deck; and
## Chiba 2024 plans in reasonable time.

const EXPECTED_CHECKS := 24

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var P := PalletRackBuildPlan
	var bay: Dictionary = PalletRackBuilder.design_preset("build_bay")["spec"]
	var tl := P.plan(bay, 6)
	var jobs: Array = tl["jobs"]
	_check("bay: plans with six, nothing stuck", (tl["blocked"] as Array).is_empty() and float(tl["makespan"]) > 0.0,
		P.summary(tl))
	var kinds := {}
	for j in jobs:
		kinds[str(j["kind"])] = int(kinds.get(str(j["kind"]), 0)) + 1
	_check("bay: every verb of the sequence is there",
		kinds.has("carry") and int(kinds.get("raise", 0)) == 4 and kinds.has("seat") and kinds.has("release")
		and kinds.has("fix") and kinds.has("lay") and kinds.has("assemble") and kinds.has("visit"), str(kinds))
	var order_ok := true
	var crew_ok := true
	for j in jobs:
		for d in j["deps"]:
			if float(jobs[d]["t1"]) > float(j["t0"]) + 1e-4:
				order_ok = false
		var n := (j["crew"] as Array).size()
		if n < int(j["min"]) or n > int(j["max"]):
			crew_ok = false
	_check("bay: every job after its dependencies", order_ok)
	_check("bay: every job within its crew", crew_ok)
	var raw := ""
	for j in jobs:
		var lb := str(j.get("label", ""))
		if lb.contains(":") or lb.contains("|"):
			raw = lb
	_check("bay: job labels are words, not part ids", raw.is_empty(), raw)
	var overlap := false
	for w in tl["workers"]:
		var segs: Array = w["segments"]
		for i in range(1, segs.size()):
			if float(segs[i]["t0"]) < float(segs[i - 1]["t1"]) - 1e-4:
				overlap = true
	_check("bay: no worker in two places at once", not overlap)
	# Holds: the raisers hold until the release; seats happen while both frames stand.
	var holds_ok := true
	var seat_ok := true
	for j in jobs:
		if str(j["kind"]) == "release":
			for rj in j["release_of"]:
				for wid in jobs[rj]["crew"]:
					var held := false
					for sg in tl["workers"][wid]["segments"]:
						if str(sg["kind"]) == "hold" and absf(float(sg["t1"]) - float(j["t1"])) < 1e-3 \
								and absf(float(sg["t0"]) - float(jobs[rj]["t1"])) < 1e-3:
							held = true
					if not held:
						holds_ok = false
		if str(j["kind"]) == "seat":
			for d in j["deps"]:
				if str(jobs[d]["kind"]) == "carry":
					continue
			var raises_before := 0
			for r in jobs:
				if str(r["kind"]) == "raise" and float(r["t1"]) <= float(j["t0"]) + 1e-4:
					raises_before += 1
			if raises_before < 2:
				seat_ok = false
	_check("bay: raisers hold their frame until the release", holds_ok)
	_check("bay: beams are seated only with both frames up", seat_ok)
	var high_ok := true
	var deck_ok := true
	for j in jobs:
		if str(j["kind"]) == "seat" and int(j["min"]) >= 4:
			var after_rel := false
			for d in j["deps"]:
				if str(jobs[d]["kind"]) in ["release", "seat"]:
					after_rel = true
			if not after_rel:
				high_ok = false
		if str(j["kind"]) in ["fix", "lay"]:
			var seats := 0
			for d in j["deps"]:
				if str(jobs[d]["kind"]) == "seat":
					seats += 1
			if seats == 0 and str(j["kind"]) == "fix" and not str(j.get("label", "")).contains("steps"):
				deck_ok = false
	_check("bay: high beams wait for the release and take four", high_ok)
	_check("bay: decks wait for the beams under them", deck_ok)
	var tl4 := P.plan(bay, 4)
	_check("bay: four people can't build it (two frames held + two seating)", not (tl4["blocked"] as Array).is_empty())
	var tl10 := P.plan(bay, 10)
	_check("bay: more hands are not slower", float(tl10["makespan"]) <= float(tl["makespan"]) * 1.05,
		"%f vs %f" % [float(tl10["makespan"]), float(tl["makespan"])])
	_check("bay: deterministic", is_equal_approx(float(P.plan(bay, 6)["makespan"]), float(tl["makespan"])))
	_check("bay: the plan is at least its critical path", float(tl["makespan"]) >= P.critical_path(tl) - 1e-3)
	# state_at.
	var s0 := P.state_at(tl, 0.0)
	var in_pile := 0
	for id in s0["units"]:
		if not (s0["units"][id]["xf"] as Transform3D).is_equal_approx(Transform3D()):
			in_pile += 1
	_check("state: everything starts in the piles", in_pile == (s0["units"] as Dictionary).size()
		and in_pile > 0, "%d / %d" % [in_pile, (s0["units"] as Dictionary).size()])
	var mk := float(tl["makespan"])
	var s1 := P.state_at(tl, mk + 1.0)
	var installed := 0
	for id in s1["units"]:
		if (s1["units"][id]["xf"] as Transform3D).is_equal_approx(Transform3D()):
			installed += 1
	_check("state: everything installed at the end", installed == (s1["units"] as Dictionary).size())
	var grows := true
	var prev := -1
	for k in 41:
		var st := P.state_at(tl, mk * float(k) / 40.0)
		var n := 0
		for id in st["units"]:
			if (st["units"][id]["xf"] as Transform3D).is_equal_approx(Transform3D()):
				n += 1
		if n < prev:
			grows = false
		prev = n
	_check("state: installed pieces only grow", grows)
	var a := P.state_at(tl, mk * 0.4)
	P.state_at(tl, mk * 0.9)
	var b := P.state_at(tl, mk * 0.4)
	var same := true
	for id in a["units"]:
		if not (a["units"][id]["xf"] as Transform3D).is_equal_approx(b["units"][id]["xf"]):
			same = false
	_check("state: scrubbing back gives the same state", same)
	var carried := false
	for k in 200:
		var st2 := P.state_at(tl, mk * float(k) / 200.0, false)
		for w in st2["workers"]:
			if str(w["activity"]) == "carry" and not str(w["carrying"]).is_empty():
				carried = true
	_check("state: pieces are carried by the crew", carried)
	var end := P.state_at(tl, mk - 1.0, false)
	var top := 0.0
	for w in end["workers"]:
		top = maxf(top, (w["pos"] as Vector3).y)
	_check("state: the visitor ends up on the deck", top > 1.7, "highest worker %.2f m" % top)
	# A switchback stair: still buildable, and the visitor climbs it to the deck.
	var ubay := bay.duplicate(true)
	for e in ubay["elements"]:
		if str(e.get("type", "")) == "stair":
			e["shape"] = "u"
			e["turn"] = "right"
	var tu := P.plan(ubay, 6)
	_check("bay with U stairs: plans with six, nothing stuck", (tu["blocked"] as Array).is_empty(), P.summary(tu))
	var vis_top := 0.0
	for j in tu["jobs"]:
		if str(j["kind"]) == "visit":
			for q in j["path"]:
				vis_top = maxf(vis_top, (q as Vector3).y)
	_check("bay with U stairs: the visitor's path climbs to the deck", vis_top > 1.7, "%.2f m" % vis_top)
	# Chiba 2024 plans in reasonable time.
	var t0 := Time.get_ticks_msec()
	var c24 := P.plan(PalletRackBuilder.design_preset("chiba_2024")["spec"], 8)
	var ms := Time.get_ticks_msec() - t0
	_check("chiba 2024: plans with eight, nothing stuck", (c24["blocked"] as Array).is_empty(), P.summary(c24))
	_check("chiba 2024: plans in under 20 s", ms < 20000, "%d ms, %s" % [ms, P.summary(c24)])
	print("rack build: bay %s; chiba 2024 %s (%d ms)" % [P.summary(tl), P.summary(c24), ms])
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("RACK BUILD PLAN SELFTEST %s  (%d checks)" % ["PASS" if _failures == 0 else "FAIL", _checks])
	quit(0 if _failures == 0 else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])
