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
## Chiba 2024 plans in reasonable time. The yard: every piece lies flat, none
## overlap, each rests on the bearers or on a piece under it; a bundle set
## down rests on the ground (or its own pieces) clear of the rack, and is
## carried at hand height.

const EXPECTED_CHECKS := 39

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
	_check_yard(tl)
	# The yard on the rack's side, and the side a crew would pick.
	_check_yard(P.plan(bay, 6, {}, {"yard_side": "+x"}))
	var bnds: AABB = tl["bounds"]
	var c := bnds.get_center()
	var front_slope := func(xz: Vector2) -> float: return maxf(0.0, c.z - xz.y) * 0.6
	_check("yard: a crew puts it on flat ground, not the slope in front",
		P.yard_side(bnds, front_slope) != "-z" and P.yard_side(bnds, func(_xz: Vector2) -> float: return 0.0) == "-z",
		P.yard_side(bnds, front_slope))
	# Chiba 2024 plans in reasonable time.
	var t0 := Time.get_ticks_msec()
	var c24 := P.plan(PalletRackBuilder.design_preset("chiba_2024")["spec"], 8)
	var ms := Time.get_ticks_msec() - t0
	_check("chiba 2024: plans with eight, nothing stuck", (c24["blocked"] as Array).is_empty(), P.summary(c24))
	_check("chiba 2024: plans in under 20 s", ms < 20000, "%d ms, %s" % [ms, P.summary(c24)])
	print("rack build: bay %s; chiba 2024 %s (%d ms)" % [P.summary(tl), P.summary(c24), ms])
	# Tool Camp 26 (joined racks, a pitched roof, benches, inside stairs):
	# every piece gets a job — a pitched roof's "ply:roof:i,j" sheets used to
	# crash the deck pass, and every piece after it stood finished from the
	# first frame — and the racking of BOTH racks goes up before any deck,
	# roof, wall or element.
	var tc_n := PalletRackBuilder.build_units_node(PalletRackBuilder.tool_camp_26_spec())
	var tc_units: Dictionary = tc_n.get_meta("units", {})
	var tc := P.plan(PalletRackBuilder.tool_camp_26_spec(), 12, tc_units)
	tc_n.free()
	var unplanned := 0
	for id in tc_units:
		if not (tc["unit"] as Dictionary).has(id):
			unplanned += 1
	_check("tool camp 26: every piece is planned, nothing stuck",
		unplanned == 0 and (tc["blocked"] as Array).is_empty(), "%d of %d unplanned, %s" % [unplanned, tc_units.size(), P.summary(tc)])
	var last_racking := 0.0
	var first_fit := INF
	for id in tc["unit"]:
		var ii := int(tc["unit"][id]["install"])
		if ii < 0:
			continue
		var leaf := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
		var head := leaf.get_slice(":", 0)
		var j: Dictionary = tc["jobs"][ii]
		if head in ["post", "beam"]:
			last_racking = maxf(last_racking, float(j["t1"]))
		else:
			first_fit = minf(first_fit, float(j["t0"]))
	_check("tool camp 26: the racking stands before the first deck, roof, wall or bench",
		first_fit >= last_racking - 0.01, "racking done %.0f s, first fit-out %.0f s" % [last_racking, first_fit])
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("RACK BUILD PLAN SELFTEST %s  (%d checks)" % ["PASS" if _failures == 0 else "FAIL", _checks])
	quit(0 if _failures == 0 else 1)


## A piece's box (world-aligned: every pose in the yard or set down is a
## quarter turn of its flat frame) under xf.
func _box(u: Dictionary, xf: Transform3D) -> AABB:
	var f: Dictionary = u["flat"]
	var bas: Basis = f["basis"]
	var c: Vector3 = f["centre"]
	var h: Vector3 = (f["size"] as Vector3) * 0.5
	var bb := AABB(xf * (c - bas * h), Vector3.ZERO)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				bb = bb.expand(xf * (c + bas * Vector3(h.x * sx, h.y * sy, h.z * sz)))
	return bb


func _rests_on(bb: AABB, others: Array, floor_y: float) -> bool:
	if absf(bb.position.y - floor_y) < 0.006:
		return true
	for o in others:
		var ob: AABB = o
		if ob == bb or absf(ob.end.y - bb.position.y) > 0.008:
			continue
		var ix := minf(bb.end.x, ob.end.x) - maxf(bb.position.x, ob.position.x)
		var iz := minf(bb.end.z, ob.end.z) - maxf(bb.position.z, ob.position.z)
		if ix > 0.01 and iz > 0.01:
			return true
	return false


func _check_yard(tl: Dictionary) -> void:
	var P := PalletRackBuildPlan
	var um: Dictionary = tl["unit"]
	var boxes := {}
	var not_flat := ""
	for id in um:
		var u: Dictionary = um[id]
		var bb := _box(u, u["pile"])
		boxes[id] = bb
		var sz: Vector3 = (u["flat"] as Dictionary)["size"]
		if absf(bb.size.y - minf(sz.x, minf(sz.y, sz.z))) > 0.002:
			not_flat = "%s %s" % [id, str(bb.size)]
	_check("yard: every piece lies flat", not_flat.is_empty(), not_flat)
	var ids: Array = boxes.keys()
	var clash := ""
	for i in ids.size():
		for k in range(i + 1, ids.size()):
			var a: AABB = (boxes[ids[i]] as AABB).grow(-0.002)
			if a.intersects((boxes[ids[k]] as AABB).grow(-0.002)):
				clash = "%s / %s" % [ids[i], ids[k]]
	_check("yard: no two pieces overlap", clash.is_empty(), clash)
	var floating := ""
	var all_boxes: Array = boxes.values()
	for id in ids:
		if not _rests_on(boxes[id], all_boxes, P.DUNNAGE_H):
			floating = "%s bottom %.3f" % [id, (boxes[id] as AABB).position.y]
	_check("yard: every piece rests on the bearers or on a piece under it", floating.is_empty(), floating)
	# Set down: each bundle on the ground, or on its own pieces, clear of the rack.
	var b: AABB = tl["bounds"]
	var rack := Rect2(Vector2(b.position.x, b.position.z), Vector2(b.size.x, b.size.z))
	var hover := ""
	var in_rack := ""
	var low_carry := ""
	for j in tl["jobs"]:
		if str(j["kind"]) != "carry":
			continue
		var sb: Array = []
		for id in j["units"]:
			sb.append(_box(um[id], um[id]["staged"]))
		for i in sb.size():
			var bb: AABB = sb[i]
			if bb.position.y < -0.01 or (bb.position.y > 0.02 and not _rests_on(bb, sb, 0.003)):
				hover = "%s bottom %.3f" % [j["units"][i], bb.position.y]
			var foot := Rect2(Vector2(bb.position.x, bb.position.z), Vector2(bb.size.x, bb.size.z))
			if not bool(um[j["units"][i]]["fixed"]) and foot.grow(-0.01).intersects(rack):
				in_rack = str(j["units"][i])
		var tm := (float(j["t_lifted"]) + float(j["t_moved"])) * 0.5
		var low := INF
		for id in j["units"]:
			low = minf(low, _box(um[id], P.unit_pose(tl, str(id), tm)["xf"]).position.y)
		if low < 0.75 or low > 1.35:
			low_carry = "%s at %.2f m" % [j.get("label", ""), low]
	_check("set down: every bundle rests on the ground or on its own pieces", hover.is_empty(), hover)
	_check("set down: bundles clear of the rack", in_rack.is_empty(), in_rack)
	_check("carried: bundles at hand height", low_carry.is_empty(), low_carry)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])
