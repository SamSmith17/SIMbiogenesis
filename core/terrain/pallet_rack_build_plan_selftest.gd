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

const EXPECTED_CHECKS := 54

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
	# Taking it down is the plan backwards: the fit-out is also CARRIED back
	# to the yard before the first beam or frame comes off (the first fit-out
	# carry is after the last racking job).
	var first_fit_carry := INF
	for id in tc["unit"]:
		var leaf2 := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
		var ci := int(tc["unit"][id]["carry"])
		if ci >= 0 and not (leaf2.get_slice(":", 0) in ["post", "beam"]):
			first_fit_carry = minf(first_fit_carry, float(tc["jobs"][ci]["t0"]))
	_check("tool camp 26: struck, the fit-out is in the yard before the racking comes down",
		first_fit_carry >= last_racking - 0.01, "racking done %.0f s, first fit-out carry %.0f s" % [last_racking, first_fit_carry])
	_test_slopes_in_pieces()
	_test_structure_pieces()
	_test_linkage_crew_build()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("RACK BUILD PLAN SELFTEST %s  (%d checks)" % ["PASS" if _failures == 0 else "FAIL", _checks])
	quit(0 if _failures == 0 else 1)


## A slope is built (and struck) member by member: its end walls are 4x8
## sheets, some cut to the slope's angle (they were one zero-thickness quad
## per end, both ends ONE piece that stood upright in the yard), the frame
## is rafters, the roof packing is blocks; and a slope goes up rafters →
## purlins → cover → ends.
func _test_slopes_in_pieces() -> void:
	var P := PalletRackBuildPlan
	var spec: Dictionary = PalletRackBuilder.design_preset("chiba_2024")["spec"]
	var n := PalletRackBuilder.build_units_node(spec)
	var units: Dictionary = n.get_meta("units", {})
	n.free()
	var ends := 0
	var cut := 0
	var thick := ""
	var rafters := 0
	for id in units:
		var sid := str(id)
		var sz: Vector3 = (units[id].get("flat", {}) as Dictionary).get("size", Vector3.ZERO)
		if sid.contains(":ends:") and not sid.contains(":ends:d"):
			ends += 1
			if sz.x < PalletRackBuilder.SHEET_SHORT - 0.02 or sz.z < PalletRackBuilder.SHEET_LONG - 0.02:
				cut += 1
			if sz.x > PalletRackBuilder.SHEET_SHORT + 0.01 or sz.z > PalletRackBuilder.SHEET_LONG + 0.01 \
					or sz.y > 0.05:
				thick = "%s %s" % [sid, sz]
		if sid.contains(":frame:"):
			rafters += 1
		# Only a stair or a ladder (a prefab) is not a flat piece.
		var etype := ""
		if sid.begins_with("el:") or sid.contains("|el:"):
			var leaf := sid.get_slice("|", 1) if sid.contains("|") else sid
			if leaf.split(":").size() == 2:
				etype = "whole element"
		if sz.y > 0.3 and etype.is_empty():
			thick = "%s %s" % [sid, sz]
	_check("chiba 2024: slope end walls are 4x8 sheets, some cut to the slope", ends >= 6 and cut >= 2,
		"%d sheets, %d cut" % [ends, cut])
	_check("chiba 2024: every slope piece lies flat (no whole-slope composites)", thick.is_empty(), thick)
	_check("chiba 2024: a slope frame is its rafters", rafters >= 8, "%d" % rafters)
	var tl := P.plan(spec, 8, units)
	var ok := true
	var why := ""
	var by_el := {}
	for id in tl["unit"]:
		var leaf := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
		if not leaf.begins_with("el:"):
			continue
		var ii := int(tl["unit"][id]["install"])
		if ii < 0:
			continue
		var key := str(id).get_slice(":", 0) + ":" + leaf.get_slice(":", 1)
		if not by_el.has(key):
			by_el[key] = {}
		var st := P._el_stage(leaf)
		var j: Dictionary = tl["jobs"][ii]
		var d: Dictionary = by_el[key]
		var r: Array = d.get(st, [INF, -INF])
		d[st] = [minf(float(r[0]), float(j["t0"])), maxf(float(r[1]), float(j["t1"]))]
	for key in by_el:
		var d: Dictionary = by_el[key]
		for a in d:
			for b in d:
				if int(a) < int(b) and float(d[b][0]) < float(d[a][1]) - 0.01:
					ok = false
					why = "%s stage %d starts before %d ends" % [key, int(b), int(a)]
	_check("chiba 2024: a slope goes up rafters, purlins, cover, then its ends", ok and not by_el.is_empty(), why)
	var tc := PalletRackBuilder.build_units_node(PalletRackBuilder.tool_camp_26_spec())
	var pk := 0
	for id in (tc.get_meta("units", {}) as Dictionary):
		if str(id).begins_with("packing:"):
			pk += 1
	tc.free()
	_check("tool camp 26: the roof packing is its blocks and purlins", pk > 4, "%d" % pk)


## Designer structures cut by StructureUnits come apart as the parts a crew
## handles: a folded-plate zome is its plates (no struts or hubs — the
## flanges were cut off the plates and planned as "struts"), the overview
## toroid's canopy is 24 panels of six triangles each, put up after the
## frame.
func _test_structure_pieces() -> void:
	var rd := {}
	var tor := {}
	for p in DomeLabPresets.builtins():
		if str(p.get("id", "")) == "helical_rd":
			rd = p.get("spec", p)
	for p in ToroidLabPresets.builtins():
		if str(p.get("id", "")) == "overview_toroid":
			tor = p.get("spec", p)
	var dn := StructureUnits.units_node({"model_id": DomeLabBuilder.MODEL_ID, "domelab_spec": rd})
	var du: Dictionary = dn.get_meta("units", {})
	dn.free()
	var plates: int = ((DomeLabDesign.solve(rd)["panels"] as Dictionary).get("panels", []) as Array).size()
	var not_plate := 0
	for id in du:
		if str(du[id].get("kind", "")) != "sheets" or (du[id].get("words", []) as Array) != ["a plate", "plates"]:
			not_plate += 1
	_check("helical zome: one piece per folded plate, nothing else", du.size() == plates and not_plate == 0,
		"%d pieces, %d plates, %d not plates" % [du.size(), plates, not_plate])
	var dtl := PalletRackBuildPlan.plan_units(du, 8)
	var strut_words := ""
	for j in dtl["jobs"]:
		if str(j.get("label", "")).contains("strut") or str(j.get("label", "")).contains("hub"):
			strut_words = str(j["label"])
	_check("helical zome: the crew handles plates, never struts or hubs", strut_words.is_empty(), strut_words)
	var tn := StructureUnits.units_node({"model_id": ToroidLabBuilder.MODEL_ID, "toroid_spec": tor})
	var tu: Dictionary = tn.get_meta("units", {})
	# Packed, a canopy fold is flat cut sheets (two corrugated sheets, ~20 mm)
	# and a bent flexible solar panel a flat one: the yard sizes them so and
	# the units node carries the packed shape beside the installed one.
	var sheet_mm: Dictionary = (ToroidLabDesign.solve(tor)["canopy"] as Dictionary)["sheet"]
	var long_m := maxf(float(sheet_mm["w"]), float(sheet_mm["h"])) * 0.001
	var bad_flat := ""
	for c in tn.get_children():
		var uid := str(c.get_meta("unit_id", ""))
		var w: Array = tu[uid].get("words", [])
		if w != ["a canopy panel", "canopy panels"] and w != ["a solar panel", "solar panels"]:
			continue
		var f: Dictionary = tu[uid]["flat"]
		var sz: Vector3 = f["size"]
		var lim := 0.03 if w[0] == "a canopy panel" else 0.01
		if not bool(f.get("packed", false)) or c.get_node_or_null("Packed") == null or sz.y > lim \
				or sz.z > long_m + 0.01:
			bad_flat = "%s %s %s" % [uid, w[0], sz]
	tn.free()
	_check("overview toroid: canopy folds and flexible panels pack flat", bad_flat.is_empty(), bad_flat)
	var canopy: Array = []
	var frame_stage := -1
	for id in tu:
		if (tu[id].get("words", []) as Array) == ["a canopy panel", "canopy panels"]:
			canopy.append(id)
		elif str(tu[id].get("kind", "")) != "sheets":
			frame_stage = maxi(frame_stage, int(tu[id]["stage"]))
	var bays: int = ((ToroidLabDesign.solve(tor)["canopy"] as Dictionary).get("sectors", []) as Array).size()
	var after := true
	for id in canopy:
		if int(tu[id]["stage"]) <= frame_stage:
			after = false
	_check("overview toroid: the canopy is one folded panel per bay (24)", canopy.size() == bays and bays == 24,
		"%d panels, %d bays" % [canopy.size(), bays])
	_check("overview toroid: the canopy goes on after the frame", after)


## A Linkage Lab structure on the crew build site: a placed structure folds
## about its own middle (centre_fixed — the solver hangs the ring off module
## 0, and its middle used to swing round as it folded, so the crew's folded
## frame and the opened structure stood in different places); the deployed
## pose is where it always was; the folded cut stands on the deployed ring's
## middle; and the pieces go up in the Lab's step order.
func _test_linkage_crew_build() -> void:
	var worst := 0.0
	var worst_dep := 0.0
	var worst_cut := 0.0
	var order_ok := true
	var why := ""
	for f in ["starshade_default.json", "ll_constellation.json"]:
		var cfg: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/linkage/presets/" + f))
		var b := LinkageStructureBuilder.build_node(cfg) as LinkageStructureBuilder
		root.add_child(b)
		var closed := b.closed_angle()
		var lo := maxf(b.min_fold_angle(), LinkageKinematics.MIN_FOLD_ANGLE)
		b.set_fold_angle(closed)
		var ref := LinkageStructureBuilder.plan_centre_of(b.last_frame()) + b.frame_offset() * Vector3(1, 0, 1)
		worst_dep = maxf(worst_dep, (b.frame_offset() * Vector3(1, 0, 1)).length())
		for u in [0.0, 0.3, 0.7]:
			b.set_fold_angle(lerpf(lo, closed, u))
			var c := LinkageStructureBuilder.plan_centre_of(b.last_frame()) + b.frame_offset() * Vector3(1, 0, 1)
			worst = maxf(worst, c.distance_to(ref))
		# The crew's folded cut, in the same frame.
		var n := StructureUnits.units_node({"model_id": LinkageStructureBuilder.MODEL_ID, "linkage_spec": cfg})
		var units: Dictionary = n.get_meta("units", {})
		n.free()
		var bb := PalletRackBuildPlan.units_bounds(units)
		var cc := bb.get_center() * Vector3(1, 0, 1)
		worst_cut = maxf(worst_cut, cc.distance_to(ref))
		# Step order: bottom ring, V modules, top ring, supports.
		var first := {}
		var last := {}
		for id in units:
			var w: Array = units[id].get("words", [])
			if w.is_empty():
				continue
			var k := str(w[1])
			first[k] = mini(int(first.get(k, 1 << 30)), int(units[id]["stage"]))
			last[k] = maxi(int(last.get(k, -1)), int(units[id]["stage"]))
		var seq := ["bottom-ring beams", "V-module beams", "top-ring beams", "support beams"]
		for i in range(1, seq.size()):
			if first.has(seq[i]) and last.has(seq[i - 1]) and f == "starshade_default.json" \
					and int(first[seq[i]]) < int(last[seq[i - 1]]):
				order_ok = false
				why = "%s: %s before %s are all up" % [f, seq[i], seq[i - 1]]
		b.free()
	_check("linkage: the ring folds about its own middle", worst < 0.002, "%.4f m" % worst)
	_check("linkage: the deployed pose stands where it always did", worst_dep < 0.002, "%.4f m" % worst_dep)
	_check("linkage: the crew's part-open frame stands on the deployed ring's middle", worst_cut < 0.05, "%.3f m" % worst_cut)
	_check("linkage: pieces go up bottom ring, V modules, top ring, supports", order_ok, why)


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
