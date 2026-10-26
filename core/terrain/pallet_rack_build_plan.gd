class_name PalletRackBuildPlan
extends RefCounted
## A crew building a pallet rack, piece by piece, as the Mars College build
## lab does it (Gene's "build-bay" sequence, engine/scenarios/build-bay.ts):
## people carry uprights and beams from the material piles, two raise each
## upright frame and HOLD it while two more seat the beams, the frames are let
## go once the bay is stable, then joists are fixed, sheets laid, steps,
## walls and the design's elements set, and at the end a visitor climbs
## onto the new deck.
##
## The plan is a job graph scheduled onto NAMED workers (the fabrication
## swarm's pattern, LinkageBuildTimeline): each worker walks to a job
## (1.3 m/s; 0.9 m/s loaded), waits for the crew, works and walks on.
## `state_at(plan, t)` is a pure function of build time — where every worker
## is and what they do, and where every piece of the rack is (in the pile,
## carried, lying staged, being raised / lifted in, installed) — so a build
## site (PalletRackBuildSite) poses its figures and pieces from it and the
## whole build scrubs with the clock.
##
## Verbs (the web engine's, scaled to whole racks):
##   carry     1–2 people take one piece (frames, beams) or a bundle (a cell's
##             joists, its sheets, an element's parts) from its pile to where
##             it is staged: walk to the pile, lift, carry, set down.
##   raise     two people stand a lying frame up about its base and keep
##             holding it ("hold") until the bay's release.
##   seat      two people seat a beam into both frames from the ground (up to
##             REACH_M); higher beams take four: two givers on the ground and
##             two installers up on the frames' bracing, after the release.
##   release   the bay's frames are let go once the beams within reach are
##             seated on both sides (the bay stands on its own).
##   fix / lay / hang / set   joists, deck sheets, wall sheets and step
##             treads go in one after another; "assemble" an element's parts.
##   visit     one person walks up onto the highest deck (by the stairs when
##             the design has some).
## Frames go up one at a time, bay after bay, rack row after rack row, so at
## most two frames are held at once: six people build any rack (the web
## scenario's crew), more build it faster.
##
## Units are BUILD UNITS (PalletRackBuilder.build_units_node): metres in the
## rack's build frame, ids = part ids ("post:r,bx", "beam:li,r,b,side",
## "joist:<cell>:i", "ply:<cell>:ix,iz", "tread:<key>:i", "wall:<face>,ia,iv",
## "el:<id>…"), a fused rack's prefixed "m<i>|".

const WALK_MPS := 1.3
const CARRY_MPS := 0.9
const T_LIFT_S := 4.0
const T_SET_S := 4.0
const T_RAISE_S := 40.0
const T_SEAT_S := 30.0
const T_SEAT_HIGH_S := 60.0
const T_RELEASE_S := 2.0
const T_JOIST_S := 25.0
const T_SHEET_S := 40.0
const T_TREAD_S := 20.0
const T_WALL_S := 45.0
const T_ELEMENT_S := 30.0
## A beam seated from the ground at most this high (m); higher: climbers.
const REACH_M := 2.0
## Pieces are carried this high (m).
const CARRY_H := 1.0
## Piles stand this far outside the rack's front.
const PILE_GAP_M := 3.0
## The material yard: each pile is stacks of one shape of piece, lying flat
## on timber bearers this tall, at most this high, at most this wide a row of
## pieces side by side, stacks this far apart, piles this far apart, a second
## row of piles this far behind the first.
const DUNNAGE_H := 0.09
const STACK_H := 1.1
const STACK_ROW_W := 1.25
const LAYER_GAP := 0.004
const STACK_GAP := 0.5
const PILE_SPACING := 1.2
const YARD_AISLE := 1.6
const PILE_ORDER := ["frames", "beams", "lumber", "sheets", "walls", "parts"]
## A carried bundle's underside, about hand height.
const CARRY_LOW := 0.8
## A bundle set down by the rack keeps this far clear of it.
const DROP_CLEAR := 0.3
## Workers stand this far off a piece.
const STAND_OFF_M := 0.6

## Activity -> clip (core/population/anims/) and the FabContextRig kind its
## tool / hands follow.
const CLIP_FOR := {"carry": "carry_beam", "lift": "place_beam", "set": "place_beam",
	"raise": "lift_ring", "hold": "hold_brace", "seat": "place_beam", "fix": "fasten_bolt",
	"lay": "place_beam", "hang": "fasten_bolt", "assemble": "fasten_bolt", "give": "place_beam"}
const RIG_FOR := {"carry": "carry", "lift": "place", "set": "place", "raise": "lift",
	"hold": "", "seat": "place", "fix": "fasten", "lay": "place", "hang": "fasten",
	"assemble": "fasten", "give": "place"}


# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

## Plan the build of `spec` (resolved or not) with `crew_n` people. `units` =
## the build units' meta (PalletRackBuilder.build_units_node(...).get_meta(
## "units")); {} builds them here. opts: {visit: bool (default true),
## yard_side: "-z" (in front, the default) | "+z" | "-x" | "+x" — the side of
## the rack the yard stands on (yard_side() picks the flattest)}.
static func plan(spec: Dictionary, crew_n: int, units: Dictionary = {}, opts: Dictionary = {}) -> Dictionary:
	crew_n = maxi(1, crew_n)
	var s := PalletRackBuilder.resolve_spec(spec)
	if units.is_empty():
		var n := PalletRackBuilder.build_units_node(s)
		units = n.get_meta("units", {})
		n.free()
	var bounds := AABB()
	var first := true
	for id in units:
		var bb: AABB = units[id]["aabb"]
		bounds = bb if first else bounds.merge(bb)
		first = false
	var P := {"jobs": [], "unit": {}, "units": units, "bounds": bounds, "piles": {},
		"stacks": [], "rec_order": [], "rests": {}, "spec": s,
		"yard_side": str(opts.get("yard_side", "-z"))}
	# Modules in order: a fused rack's racks go up one after another.
	var mods := {}
	for id in units:
		var pre := (str(id).get_slice("|", 0) + "|") if str(id).contains("|") else ""
		if not mods.has(pre):
			mods[pre] = []
		(mods[pre] as Array).append(str(id))
	var keys: Array = mods.keys()
	keys.sort()
	var mod_specs := PalletRackBuilder.rack_modules(s)
	var prev_end: Array = []
	for pre in keys:
		var mi := 0 if str(pre).is_empty() else int(str(pre).trim_prefix("m").trim_suffix("|"))
		var ms: Dictionary = mod_specs[mini(mi, mod_specs.size() - 1)]["spec"]
		prev_end = _plan_module(P, str(pre), mods[pre], prev_end, int(ms.get("column_count", 1)))
	if bool(opts.get("visit", true)):
		_plan_visit(P, prev_end)
	_layout_yard(P)
	_finish_carries(P)
	var sched := _schedule(P["jobs"], crew_n)
	var tl := {"jobs": P["jobs"], "unit": P["unit"], "workers": sched["workers"],
		"makespan": sched["makespan"], "blocked": sched["blocked"], "crew": crew_n,
		"bounds": bounds, "piles": P["piles"], "stacks": P["stacks"], "rests": P["rests"], "yard_side": P["yard_side"], "radius_m": bounds.size.length() * 0.5}
	return tl


static func _unit_rec(P: Dictionary, id: String, pile_kind: String) -> Dictionary:
	var r := {"pile": Transform3D(), "staged": Transform3D(), "carry": -1, "install": -1, "i": 0, "n": 1,
		"raise": false, "pivot": Vector3.ZERO, "lie": 0.0, "kind": pile_kind, "fixed": false}
	P["unit"][id] = r
	(P["rec_order"] as Array).append(id)
	return r


## A staged pose the plan sets itself (a beam by its frames, a frame lying
## at its feet), not a bundle laid out at the drop.
static func _fix_staged(u: Dictionary, xf: Transform3D, at: Vector3) -> void:
	u["staged"] = xf
	u["fixed"] = true
	u["gxz_staged"] = Vector2(at.x, at.z)


static func _at(bas: Basis, c: Vector3, p: Vector3) -> Transform3D:
	return Transform3D(bas, p - bas * c)


static func _job(P: Dictionary, kind: String, units: Array, deps: Array, crew_min: int, crew_max: int,
		work_s: float, stands: Array, opts: Dictionary = {}) -> int:
	var jobs: Array = P["jobs"]
	var id := jobs.size()
	var j := {"id": id, "kind": kind, "units": units, "deps": deps.filter(func(d): return int(d) >= 0),
		"min": crew_min, "max": maxi(crew_min, crew_max), "work_s": work_s, "stands": stands,
		"t0": -1.0, "t1": -1.0, "crew": [], "hold": false, "release_of": [], "face": Vector3.ZERO}
	j.merge(opts, true)
	jobs.append(j)
	return id


## Stand points round a piece: the two ends of its long horizontal axis, set
## out sideways; more people fill in along it.
static func _stands_round(bb: AABB, k: int, y: float = 0.0, away: Vector3 = Vector3.ZERO) -> Array:
	var c := bb.get_center()
	var along := Vector3.RIGHT if bb.size.x >= bb.size.z else Vector3.BACK
	var side := along.cross(Vector3.UP).normalized()
	if away.length() > 0.01 and side.dot(away) < 0.0:
		side = -side
	var half := maxf(bb.size.x, bb.size.z) * 0.5
	var off := (bb.size.z if along == Vector3.RIGHT else bb.size.x) * 0.5 + STAND_OFF_M
	var out: Array = []
	for i in k:
		var f := 0.0 if k == 1 else lerpf(-0.8, 0.8, float(i) / float(k - 1))
		var p := c + along * half * f + side * off
		out.append(Vector3(p.x, y, p.z))
	return out


## A carry job taking `ids` (one piece or a bundle) from the yard to `drop`
## (ground). Where they are picked up, the crew's stands, the bundle as it is
## set down and how high it is carried are worked out once the yard is laid
## out (_finish_carries). Returns the job id.
static func _carry(P: Dictionary, ids: Array, crew: int, drop: Vector3, deps: Array, label: String) -> int:
	var jid := _job(P, "carry", ids, deps, crew, crew, T_LIFT_S + T_SET_S, [],
		{"pick": Vector3.ZERO, "drop": Vector3(drop.x, 0.0, drop.z), "label": label})
	for id in ids:
		(P["unit"][id] as Dictionary)["carry"] = jid
	return jid


## One installing job over `ids`, one after another (sequential reveal).
static func _install(P: Dictionary, kind: String, ids: Array, crew_min: int, crew_max: int, per_s: float,
		deps: Array, stands: Array, label: String) -> int:
	var bb: AABB = P["units"][ids[0]]["aabb"]
	for id in ids:
		bb = bb.merge(P["units"][id]["aabb"])
	var jid := _job(P, kind, ids, deps, crew_min, crew_max, per_s * float(ids.size()) * float(crew_min),
		stands, {"label": label, "face": bb.get_center()})
	for i in ids.size():
		var u: Dictionary = P["unit"][ids[i]]
		u["install"] = jid
		u["i"] = i
		u["n"] = ids.size()
	return jid


## Job labels in words (the build site's progress line shows them).
static func _frame_name(fk: String) -> String:
	var b := fk.split(",")
	return "upright frame %d" % (int(b[1]) + 1) if int(b[0]) == 0 		else "upright frame %d of row %d" % [int(b[1]) + 1, int(b[0]) + 1]


static func _beam_name(bid: String) -> String:
	var k := (_parse(bid)[1] as String).get_slice(":", 1).split(",")
	if k.size() < 3:
		return "a beam"
	return "a level-%d beam of bay %d" % [int(k[0]) + 1, int(k[2]) + 1]


static func _cell_name(ck: String) -> String:
	var b := ck.split(",")
	if b.size() < 3:
		return "a bay"
	return "bay %d, level %d" % [int(b[0]) + 1, int(b[2]) + 1] if b[1] == "0" 		else "bay %d, column %d, level %d" % [int(b[0]) + 1, int(b[1]) + 1, int(b[2]) + 1]


static func _wall_name(wk: String) -> String:
	var b := wk.split(",")
	return "the %s wall" % b[0] if b.size() < 2 or b[1] == "0" else "the %s wall, panel %d" % [b[0], int(b[1]) + 1]


const _ELEMENT_WORDS := {"door": "the door", "window": "the window", "stair": "the stairs",
	"lean_to": "the slope", "railing": "the railing", "ladder": "the ladder", "stepped": "the big steps",
	"courtyard": "the courtyard"}


static func _element_name(P: Dictionary, eid: String) -> String:
	for m in PalletRackBuilder.rack_modules(P["spec"]):
		for e in ((m["spec"] as Dictionary).get("elements", []) as Array):
			if str((e as Dictionary).get("id", "")) == eid:
				return str(_ELEMENT_WORDS.get(str(e.get("type", "")), "a fitting"))
	return "a fitting"


static func _parse(id: String) -> Array:
	var leaf := id.get_slice("|", 1) if id.contains("|") else id
	return [leaf.get_slice(":", 0), leaf]


static func _plan_module(P: Dictionary, _pre: String, ids: Array, prev_end: Array, cols: int) -> Array:
	var units: Dictionary = P["units"]
	var frames := {}      # "r,bx" -> id
	var beams := {}       # "r,b" -> [ids]
	var joists := {}      # cell -> [ids]
	var sheets := {}      # cell -> [ids]
	var treads := {}      # key -> [ids]
	var walls := {}       # "face,ia" -> [ids]
	var elems := {}       # eid -> [ids]
	var misc: Array = []
	ids.sort()
	for id in ids:
		var pr := _parse(id)
		var head: String = pr[0]
		var leaf: String = pr[1]
		match head:
			"post":
				frames[leaf.get_slice(":", 1)] = id
			"beam":
				var k := leaf.get_slice(":", 1).split(",")
				var rb := "%s,%s" % [k[1], k[2]]
				if not beams.has(rb):
					beams[rb] = []
				(beams[rb] as Array).append(id)
			"joist", "ply", "tread":
				var key := leaf.get_slice(":", 1)
				var d: Dictionary = joists if head == "joist" else (sheets if head == "ply" else treads)
				if not d.has(key):
					d[key] = []
				(d[key] as Array).append(id)
			"wall":
				var w := leaf.get_slice(":", 1).split(",")
				var wk := "%s,%s" % [w[0], w[1]]
				if not walls.has(wk):
					walls[wk] = []
				(walls[wk] as Array).append(id)
			"el":
				var eid := leaf.get_slice(":", 1)
				if not elems.has(eid):
					elems[eid] = []
				(elems[eid] as Array).append(id)
			_:
				misc.append(id)
	# ---- Frames and beams: row by row, bay by bay ----
	var rows := {}
	var max_bx := -1
	for fk in frames:
		rows[int(str(fk).get_slice(",", 0))] = true
		max_bx = maxi(max_bx, int(str(fk).get_slice(",", 1)))
	for rb in beams:
		rows[int(str(rb).get_slice(",", 0))] = true
		max_bx = maxi(max_bx, int(str(rb).get_slice(",", 1)) + 1)
	var row_list: Array = rows.keys()
	row_list.sort()
	var seat_of := {}     # beam id -> seat job
	var all_seats: Array = []
	var chain: Array = prev_end.duplicate()     # what the next raise waits for
	var raise_of := {}    # frame key -> raise job
	for r in row_list:
		for b in range(max_bx):
			var bay_beams: Array = beams.get("%d,%d" % [r, b], [])
			var fa := "%d,%d" % [r, b]
			var fb := "%d,%d" % [r, b + 1]
			if bay_beams.is_empty() and not frames.has(fa) and not frames.has(fb):
				continue
			var raised: Array = []
			for fk in [fa, fb]:
				if not frames.has(fk) or raise_of.has(fk):
					continue
				var fid: String = frames[fk]
				var fbb: AABB = units[fid]["aabb"]
				var u := _unit_rec(P, fid, "frames")
				# Lying with its base on its own base line, top away from the
				# frames already up (-X for the first, +X after).
				var sgn := -1.0 if int(str(fk).get_slice(",", 1)) == 0 else 1.0
				# It tips over the foot edge on that side, so lying it rests on
				# the ground rather than half in it.
				var pivot := Vector3(fbb.get_center().x + sgn * fbb.size.x * 0.5, 0.0, fbb.get_center().z)
				u["raise"] = true
				u["pivot"] = pivot
				u["lie"] = sgn * PI * 0.5
				var lie_xf := _pivot_xf(pivot, sgn * PI * 0.5)
				u["lie_xf"] = lie_xf
				var lie_c := lie_xf * fbb.get_center()
				var cj := _carry(P, [fid], 2, Vector3(lie_c.x, 0.0, lie_c.z), chain, "carry " + _frame_name(fk))
				_fix_staged(u, lie_xf, lie_c)
				var base := Vector3(pivot.x, 0.0, pivot.z)
				var top := lie_xf * Vector3(fbb.get_center().x, fbb.end.y - 0.3, fbb.get_center().z)
				var stands := [Vector3(base.x + sgn * 0.5, 0.0, fbb.get_center().z + fbb.size.z * 0.5 + 0.4),
					Vector3(top.x, 0.0, top.z + 0.6)]
				var rj := _job(P, "raise", [fid], [cj] + chain, 2, 2, T_RAISE_S * 2.0, stands,
					{"hold": true, "label": "raise and hold " + _frame_name(fk), "face": base})
				u["install"] = rj
				raise_of[fk] = rj
				raised.append(rj)
			# Beams of the bay: within reach from the ground, then a release,
			# then the high ones from the frames.
			bay_beams.sort_custom(func(a, c): return (units[a]["aabb"] as AABB).get_center().y < (units[c]["aabb"] as AABB).get_center().y)
			var seat_deps: Array = []
			for fk in [fa, fb]:
				if raise_of.has(fk):
					seat_deps.append(raise_of[fk])
			var low_chain: Array = seat_deps.duplicate()
			var high: Array = []
			var low_jobs: Array = []
			for bid in bay_beams:
				var bbb: AABB = units[bid]["aabb"]
				var bu := _unit_rec(P, bid, "beams")
				var c := bbb.get_center()
				var out := Vector3(0, 0, 1) if c.z > 0.0 else Vector3(0, 0, -1)
				var stage := Vector3(c.x, 0.06, c.z) + out * 0.46
				var cj := _carry(P, [bid], 2, stage, [], "carry " + _beam_name(bid))
				_fix_staged(bu, _at(Basis(), c, Vector3(stage.x, bbb.size.y * 0.5 + 0.003, stage.z)), stage)
				if c.y <= REACH_M:
					var sj := _install(P, "seat", [bid], 2, 2, T_SEAT_S, [cj] + low_chain,
						_stands_round(bbb, 2, 0.0, out), "seat " + _beam_name(bid))
					seat_of[bid] = sj
					low_chain = [sj]
					low_jobs.append(sj)
				else:
					high.append([bid, cj])
			var rel := _job(P, "release", [], low_jobs + seat_deps, 0, 0, T_RELEASE_S, [],
				{"release_of": raised, "label": "release the frames of bay %d, row %d" % [b + 1, r + 1]})
			var hi_chain: Array = [rel]
			for h in high:
				var hid: String = h[0]
				var hbb: AABB = units[hid]["aabb"]
				var hc := hbb.get_center()
				var out2 := Vector3(0, 0, 1) if hc.z > 0.0 else Vector3(0, 0, -1)
				var climb := maxf(0.0, hc.y - 1.5)
				var st: Array = _stands_round(hbb, 2, climb, -out2) + _stands_round(hbb, 2, 0.0, out2)
				var sj2 := _install(P, "seat", [hid], 4, 4, T_SEAT_HIGH_S, [h[1]] + hi_chain, st, "seat " + _beam_name(hid) + " from the frames")
				seat_of[hid] = sj2
				hi_chain = [sj2]
			all_seats.append_array(low_jobs)
			all_seats.append(hi_chain[0])
			chain = [rel]
	var structure_done: Array = chain.duplicate() + all_seats
	if structure_done.is_empty():
		structure_done = prev_end.duplicate()
	# ---- Decks: per cell, low levels first ----
	var cells := {}
	for k in joists:
		cells[k] = true
	for k in sheets:
		cells[k] = true
	var cell_list: Array = cells.keys()
	cell_list.sort_custom(func(a, c):
		var la := int(str(a).get_slice(",", 2))
		var lc := int(str(c).get_slice(",", 2))
		if la != lc:
			return la < lc
		return str(a) < str(c))
	var deck_jobs: Array = []
	for ck in cell_list:
		var bits := str(ck).split(",")
		var deps: Array = []
		# The beams carrying the cell: its level, its bay, and the cell the
		# beam's side faces.
		for bid in seat_of:
			var bk := (_parse(bid)[1] as String).get_slice(":", 1).split(",")
			if bk[0] == bits[2] and bk[2] == bits[0] \
					and PalletRackBuilder._beam_cell(int(bk[1]), int(bk[3]), cols) == int(bits[1]):
				deps.append(seat_of[bid])
		if deps.is_empty():
			deps = structure_done.duplicate()
		var js: Array = joists.get(ck, [])
		var ss: Array = sheets.get(ck, [])
		var cbb := AABB()
		var cf := true
		for id in js + ss:
			cbb = units[id]["aabb"] if cf else cbb.merge(units[id]["aabb"])
			cf = false
		var y := cbb.get_center().y
		var stand_y := maxf(0.0, y - 1.5)
		var last := -1
		if not js.is_empty():
			for id in js:
				_unit_rec(P, id, "lumber")
			var cj := _carry(P, js, 2, Vector3(cbb.get_center().x, 0, cbb.position.z - 0.8), deps, "carry the joists for " + _cell_name(ck))
			last = _install(P, "fix", js, 1, 2, T_JOIST_S, [cj] + deps, _stands_round(cbb, 2, stand_y),
				"fix the joists of " + _cell_name(ck))
		if not ss.is_empty():
			for id in ss:
				_unit_rec(P, id, "sheets")
			var cj2 := _carry(P, ss, 2, Vector3(cbb.get_center().x + 0.4, 0, cbb.position.z - 1.6), deps, "carry the deck sheets for " + _cell_name(ck))
			last = _install(P, "lay", ss, 2, 2, T_SHEET_S, [cj2, last] + deps, _stands_round(cbb, 2, stand_y),
				"deck " + _cell_name(ck))
		deck_jobs.append(last)
	var after_decks: Array = deck_jobs + structure_done
	# ---- Steps, walls, elements, the rest ----
	var finish: Array = []
	var tk: Array = treads.keys()
	tk.sort()
	for k in tk:
		var ts: Array = treads[k]
		var tbb := AABB()
		var tf := true
		for id in ts:
			_unit_rec(P, id, "lumber")
			tbb = units[id]["aabb"] if tf else tbb.merge(units[id]["aabb"])
			tf = false
		var cj := _carry(P, ts, 2, Vector3(tbb.get_center().x, 0, tbb.position.z - 0.8), structure_done, "carry the steps")
		finish.append(_install(P, "fix", ts, 1, 2, T_TREAD_S, [cj] + structure_done,
			_stands_round(tbb, 2, maxf(0.0, tbb.get_center().y - 1.5)), "set the steps"))
	var wk: Array = walls.keys()
	wk.sort()
	for k in wk:
		var ws: Array = walls[k]
		ws.sort()
		var wbb := AABB()
		var wf := true
		for id in ws:
			_unit_rec(P, id, "walls")
			wbb = units[id]["aabb"] if wf else wbb.merge(units[id]["aabb"])
			wf = false
		var outw := wbb.get_center() * Vector3(1, 0, 1)
		var cj := _carry(P, ws, 2, Vector3(wbb.get_center().x, 0, wbb.get_center().z) + outw.normalized() * 1.2,
			after_decks, "carry the sheets for " + _wall_name(k))
		finish.append(_install(P, "hang", ws, 2, 2, T_WALL_S, [cj] + after_decks,
			_stands_round(wbb, 2, 0.0, outw), "hang " + _wall_name(k)))
	var ek: Array = elems.keys()
	ek.sort()
	for k in ek:
		var es: Array = elems[k]
		var ebb := AABB()
		var ef := true
		for id in es:
			_unit_rec(P, id, "parts")
			ebb = units[id]["aabb"] if ef else ebb.merge(units[id]["aabb"])
			ef = false
		var oute := ebb.get_center() * Vector3(1, 0, 1)
		var drop := Vector3(ebb.get_center().x, 0, ebb.get_center().z) + oute.normalized() * 1.0
		var cj := _carry(P, es, 2, drop, after_decks, "carry the parts of " + _element_name(P, k))
		finish.append(_install(P, "assemble", es, 2, 2, T_ELEMENT_S, [cj] + after_decks,
			_stands_round(ebb, 2, 0.0, oute), "put up " + _element_name(P, k)))
	if not misc.is_empty():
		var mbb := AABB()
		var mf := true
		for id in misc:
			_unit_rec(P, id, "parts")
			mbb = units[id]["aabb"] if mf else mbb.merge(units[id]["aabb"])
			mf = false
		var cjm := _carry(P, misc, 2, mbb.get_center() * Vector3(1, 0, 1), after_decks, "carry the rest")
		finish.append(_install(P, "assemble", misc, 2, 2, T_ELEMENT_S, [cjm] + after_decks,
			_stands_round(mbb, 2), "finish"))
	return finish + after_decks


## The visitor's climb onto the highest deck: by the first stairs of the
## design when it has any, else straight to the deck's edge.
static func _plan_visit(P: Dictionary, deps: Array) -> void:
	var s: Dictionary = P["spec"]
	var L := PalletRackBuilder._layout(s, PalletRackBuilder._metrics(s))
	var levels: Array = L.levels
	if levels.is_empty():
		return
	var path: Array = []
	for e in (s.get("elements", []) as Array):
		if str(e.get("type", "")) != "stair":
			continue
		var G := PalletRackBuilder._stair_geo(L, e)
		if G.is_empty():
			continue
		path.append_array(PalletRackBuilder.stair_walk_path(G))
		# Onto the deck.
		var fr: Dictionary = G.fr
		var top: Vector3 = path[-1]
		path.append(top - (fr.out as Vector3) * (float(G.o0) + 1.2))
		break
	if path.is_empty():
		var top_li := levels.size() - 1
		var y := PalletRackBuilder._floor_y(L, top_li)
		var b: AABB = P["bounds"]
		path = [Vector3(b.get_center().x, 0.0, b.position.z - 1.0), Vector3(b.get_center().x, y, b.position.z + 1.0)]
	_job(P, "visit", [], deps, 1, 1, 0.0, [path[0]], {"path": path, "label": "the visitor climbs onto the new deck"})


static func _pivot_xf(pivot: Vector3, ang: float) -> Transform3D:
	var r := Transform3D(Basis(Vector3.BACK, -ang), Vector3.ZERO)
	return Transform3D(Basis(), pivot) * r * Transform3D(Basis(), -pivot)


# ---------------------------------------------------------------------------
# The material yard: piles of flat stacks, and where bundles are set down
# ---------------------------------------------------------------------------

## A piece's own frame (PalletRackBuilder.flat_frame, in the units meta), or
## one from its box for units made without it.
static func _flat_of(P: Dictionary, id: String) -> Dictionary:
	var info: Dictionary = P["units"][id]
	var f: Variant = info.get("flat", {})
	if f is Dictionary and (f as Dictionary).has("basis"):
		return f
	var bb: AABB = info["aabb"]
	var dims := [bb.size.x, bb.size.y, bb.size.z]
	var ax := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var thin := 0
	var long := 2
	for i in 3:
		if float(dims[i]) < float(dims[thin]) - 1e-6:
			thin = i
	for i in 3:
		if i != thin and (long == thin or float(dims[i]) > float(dims[long]) + 1e-6):
			long = i
	if long == thin:
		long = (thin + 1) % 3
	var n: Vector3 = ax[thin]
	var l: Vector3 = ax[long]
	var across := n.cross(l)
	var bas := Basis(across, n, l)
	var sz := Vector3(absf(across.dot(bb.size)), float(dims[thin]), float(dims[long]))
	return {"basis": bas, "size": sz, "centre": bb.get_center()}


## The rotation laying a piece flat: across -> X, thin -> up, long -> Z.
static func _lay(f: Dictionary) -> Basis:
	return (f["basis"] as Basis).transposed()


## The bottom of a piece under `xf` (build frame, metres).
static func _bottom_y(u: Dictionary, xf: Transform3D) -> float:
	var f: Dictionary = u["flat"]
	var bas: Basis = f["basis"]
	var c: Vector3 = f["centre"]
	var h: Vector3 = (f["size"] as Vector3) * 0.5
	var lo := INF
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				lo = minf(lo, (xf * (c + bas * Vector3(h.x * sx, h.y * sy, h.z * sz))).y)
	return lo


## Pieces side by side in a stack: snug for timber, a little apart for steel.
static func _side_gap(kind: String) -> float:
	return 0.012 if kind in ["lumber", "sheets", "walls"] else 0.03


## The yard: every piece in a pile by kind, a pile = stacks of one shape of
## piece lying flat (thinnest way up, long way pointing from the rack), a few
## side by side a layer as a bundle is, layers up to STACK_H, each stack on
## bearers. The piece used first is on top. Stacks run along the rack's front
## and wrap to a row behind. Fills P.stacks, P.piles and each unit's pile.
static func _layout_yard(P: Dictionary) -> void:
	var groups := {}
	var gorder: Array = []
	for id in P["rec_order"]:
		var u: Dictionary = P["unit"][id]
		var f := _flat_of(P, id)
		u["flat"] = f
		var sz: Vector3 = f["size"]
		var key := "%s|%d|%d|%d" % [u["kind"], roundi(sz.x * 50.0), roundi(sz.y * 200.0), roundi(sz.z * 50.0)]
		if not groups.has(key):
			groups[key] = {"kind": u["kind"], "size": sz, "ids": []}
			gorder.append(key)
		(groups[key]["ids"] as Array).append(id)
	# Each shape's stacks.
	for key in gorder:
		var gr: Dictionary = groups[key]
		var sz: Vector3 = gr["size"]
		var n := (gr["ids"] as Array).size()
		var gap := _side_gap(str(gr["kind"]))
		var w := maxf(sz.x, 0.01)
		var t := maxf(sz.y, 0.003)
		var row_max := clampi(floori((STACK_ROW_W + gap) / (w + gap)), 1, 10)
		var layers_max := clampi(floori(STACK_H / (t + LAYER_GAP)), 1, 40)
		var per_row := clampi(ceili(sqrt(float(n) * t / w)), 1, row_max)
		per_row = mini(per_row, n)
		var cap := per_row * layers_max
		var stacks: Array = []
		var left := n
		while left > 0:
			var k := mini(left, cap)
			var layers := ceili(float(k) / float(per_row))
			stacks.append({"kind": gr["kind"], "w": per_row * w + (per_row - 1) * gap,
				"l": sz.z, "h": layers * (t + LAYER_GAP)})
			left -= k
		gr["per_row"] = per_row
		gr["cap"] = cap
		gr["gap"] = gap
		gr["stacks"] = stacks
	# Where the stacks stand: piles in order along the front, wrapping behind,
	# laid out as if the yard were in front (-Z) and then turned to its side.
	var T := _yard_xf(P)
	var b := _yard_frame_bounds(P)
	var x0 := b.position.x
	var row_w := maxf(b.size.x, 8.0)
	var x := x0
	var z_near := b.position.z - PILE_GAP_M
	var row_depth := 0.0
	var all: Array = P["stacks"]
	for kind in PILE_ORDER:
		var first := true
		for key in gorder:
			var gr: Dictionary = groups[key]
			if str(gr["kind"]) != kind:
				continue
			for st in gr["stacks"]:
				var W: float = st["w"]
				var L: float = st["l"]
				if x > x0 + 1e-6:
					x += PILE_SPACING if first else STACK_GAP
				if x + W > x0 + row_w and x > x0 + 1e-6:
					z_near -= row_depth + YARD_AISLE
					x = x0
					row_depth = 0.0
				st["x0"] = x
				st["z0"] = z_near
				var wc := T * Vector3(x + W * 0.5, 0.0, z_near - L * 0.5)
				st["centre"] = wc
				st["basis"] = T.basis
				st["size"] = Vector3(W, st["h"], L)
				st["rect"] = _rect_xz(T, Rect2(Vector2(x, z_near - L), Vector2(W, L)))
				st["index"] = all.size()
				all.append(st)
				P["rests"][Vector2(wc.x, wc.z)] = (st["rect"] as Rect2).size * 0.5
				if first:
					P["piles"][kind] = st["centre"]
				first = false
				x += W
				row_depth = maxf(row_depth, L)
	# Each piece's slot: the first used on top.
	for key in gorder:
		var gr: Dictionary = groups[key]
		var ids: Array = gr["ids"]
		var n := ids.size()
		var sz: Vector3 = gr["size"]
		var per_row: int = gr["per_row"]
		var cap: int = gr["cap"]
		var gap: float = gr["gap"]
		for i in n:
			var s := n - 1 - i
			var st: Dictionary = gr["stacks"][s / cap]
			var within := s % cap
			var layer := within / per_row
			var col := within % per_row
			var u: Dictionary = P["unit"][ids[i]]
			var f: Dictionary = u["flat"]
			var p := Vector3(float(st["x0"]) + col * (sz.x + gap) + sz.x * 0.5,
				DUNNAGE_H + layer * (sz.y + LAYER_GAP) + sz.y * 0.5, float(st["z0"]) - sz.z * 0.5)
			u["pile"] = T * _at(_lay(f), f["centre"], p)
			u["slot"] = {"stack": int(st["index"]), "layer": layer, "col": col, "w": sz.x, "t": sz.y,
				"l": sz.z, "gap": gap}
			u["gxz_pile"] = Vector2((st["centre"] as Vector3).x, (st["centre"] as Vector3).z)
			if int(u["carry"]) < 0:
				u["staged"] = u["pile"]
				u["gxz_staged"] = u["gxz_pile"]


## The yard's turn onto its side: front (-Z) to yard_side, about the rack's
## middle.
static func _yard_xf(P: Dictionary) -> Transform3D:
	var ang := {"-z": 0.0, "+z": PI, "-x": PI * 0.5, "+x": -PI * 0.5}
	var r := Basis(Vector3.UP, float(ang.get(str(P.get("yard_side", "-z")), 0.0)))
	var b: AABB = P["bounds"]
	var c := Vector3(b.get_center().x, 0.0, b.get_center().z)
	return Transform3D(r, c - r * c)


## The rack's bounds as seen from the yard's frame (sides swapped for a yard
## off the left or right).
static func _yard_frame_bounds(P: Dictionary) -> AABB:
	var b: AABB = P["bounds"]
	if str(P.get("yard_side", "-z")) in ["-x", "+x"]:
		var c := b.get_center()
		var sz := Vector3(b.size.z, b.size.y, b.size.x)
		return AABB(c - sz * 0.5, sz)
	return b


## An xz rectangle through T (quarter turns: still a rectangle).
static func _rect_xz(T: Transform3D, r: Rect2) -> Rect2:
	var a := T * Vector3(r.position.x, 0.0, r.position.y)
	var out := Rect2(Vector2(a.x, a.z), Vector2.ZERO)
	for q in [Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var w := T * Vector3(q.x, 0.0, q.y)
		out = out.expand(Vector2(w.x, w.z))
	return out


## The side of the rack a crew would put its yard on: the one whose ground,
## over a band like the yard's, is flattest; the front unless another side is
## clearly flatter. `ground` (Callable(Vector2 xz) -> float, the build frame)
## None = the front.
static func yard_side(bounds: AABB, ground: Callable) -> String:
	if not ground.is_valid():
		return "-z"
	var best := "-z"
	var best_r := INF
	for side in ["-z", "+z", "-x", "+x"]:
		var P := {"bounds": bounds, "yard_side": side}
		var T := _yard_xf(P)
		var b := _yard_frame_bounds(P)
		var lo := INF
		var hi := -INF
		for i in 5:
			for k in 4:
				var x := lerpf(b.position.x, b.position.x + maxf(b.size.x, 6.0), float(i) / 4.0)
				var z := b.position.z - PILE_GAP_M - 6.0 * float(k) / 3.0
				var w := T * Vector3(x, 0.0, z)
				var y := float(ground.call(Vector2(w.x, w.z)))
				lo = minf(lo, y)
				hi = maxf(hi, y)
		var r := hi - lo - (0.3 if side == "-z" else 0.0)
		if r < best_r - 1e-4:
			best_r = r
			best = side
	return best


## The bounds of a rack's build units (their meta).
static func units_bounds(units: Dictionary) -> AABB:
	var bounds := AABB()
	var first := true
	for id in units:
		var bb: AABB = units[id]["aabb"]
		bounds = bb if first else bounds.merge(bb)
		first = false
	return bounds


## Each carry: where it is picked up (the bundle in the yard), the crew's
## stands, the bundle laid out where it is set down, how high it is carried.
static func _finish_carries(P: Dictionary) -> void:
	var b: AABB = P["bounds"]
	var keep_out := Rect2(Vector2(b.position.x, b.position.z), Vector2(b.size.x, b.size.z)).grow(DROP_CLEAR)
	var placed: Array = []
	var T := _yard_xf(P)
	for st in P["stacks"]:
		placed.append((st["rect"] as Rect2).grow(0.4))
	for j in P["jobs"]:
		if str(j["kind"]) != "carry":
			continue
		var ids: Array = j["units"]
		var pr := Rect2()
		var pile_low := INF
		for i in ids.size():
			var u: Dictionary = P["unit"][ids[i]]
			var sl: Dictionary = u["slot"]
			var st: Dictionary = P["stacks"][int(sl["stack"])]
			var r := _rect_xz(T, Rect2(Vector2(float(st["x0"]) + int(sl["col"]) * (float(sl["w"]) + float(sl["gap"])),
				float(st["z0"]) - float(sl["l"])), Vector2(float(sl["w"]), float(sl["l"]))))
			pr = r if i == 0 else pr.merge(r)
			pile_low = minf(pile_low, _bottom_y(u, u["pile"]))
		var pick := Vector3(pr.get_center().x, 0.0, pr.get_center().y)
		j["pick"] = pick
		j["stands"] = _stands_round(AABB(Vector3(pr.position.x, 0.0, pr.position.y),
			Vector3(pr.size.x, 0.1, pr.size.y)), int(j["min"]))
		var loose := ids.filter(func(id): return not bool(P["unit"][id]["fixed"]))
		if not loose.is_empty():
			_stage_bundle(P, j, loose, placed, keep_out)
		var staged_low := INF
		for id in ids:
			var u: Dictionary = P["unit"][id]
			staged_low = minf(staged_low, _bottom_y(u, u["staged"]))
		# Carried at hand height, but lifted clear of what stays in the stack.
		j["lift_y"] = maxf(CARRY_LOW, pile_low + 0.03) - staged_low


## A bundle set down at its drop: the pieces of each stack it came from
## restacked from the ground, those side by side, lying along the face of the
## rack it is beside, clear of the rack and of the bundles and stacks before
## it (slid along the face until it is).
static func _stage_bundle(P: Dictionary, j: Dictionary, ids: Array, placed: Array, keep_out: Rect2) -> void:
	var b: AABB = P["bounds"]
	var drop: Vector3 = j["drop"]
	var dd := Vector2(drop.x - b.get_center().x, drop.z - b.get_center().z)
	var along_x := absf(dd.y) >= absf(dd.x)
	var turn := Basis(Vector3.UP, PI * 0.5) if along_x else Basis()
	var by_stack := {}
	var order: Array = []
	for id in ids:
		var si := int(P["unit"][id]["slot"]["stack"])
		if not by_stack.has(si):
			by_stack[si] = []
			order.append(si)
		(by_stack[si] as Array).append(id)
	var local := {}
	var cx := 0.0
	var depth := 0.0
	for si in order:
		var grp: Array = by_stack[si]
		var c_lo := 1 << 30
		var c_hi := -1
		var l_lo := 1 << 30
		for id in grp:
			var sl: Dictionary = P["unit"][id]["slot"]
			c_lo = mini(c_lo, int(sl["col"]))
			c_hi = maxi(c_hi, int(sl["col"]))
			l_lo = mini(l_lo, int(sl["layer"]))
		var w := 0.0
		for id in grp:
			var sl: Dictionary = P["unit"][id]["slot"]
			var pw: float = float(sl["w"]) + float(sl["gap"])
			local[id] = Vector3(cx + (int(sl["col"]) - c_lo) * pw + float(sl["w"]) * 0.5,
				(int(sl["layer"]) - l_lo) * (float(sl["t"]) + LAYER_GAP) + float(sl["t"]) * 0.5 + 0.003, 0.0)
			w = (c_hi - c_lo + 1) * pw - float(sl["gap"])
			depth = maxf(depth, float(sl["l"]))
		cx += w + 0.3
	var total_w := maxf(cx - 0.3, 0.01)
	var half := Vector2(depth * 0.5, total_w * 0.5) if along_x else Vector2(total_w * 0.5, depth * 0.5)
	var out := Vector2(0.0, -1.0 if dd.y < 0.0 else 1.0) if along_x else Vector2(-1.0 if dd.x < 0.0 else 1.0, 0.0)
	var side := Vector2(out.y, -out.x)
	var c := Vector2(drop.x, drop.z)
	for _k in 60:
		if not Rect2(c - half, half * 2.0).intersects(keep_out):
			break
		c += out * 0.25
	var base := c
	for k in 40:
		var off := 0.0 if k == 0 else ceilf(k / 2.0) * 0.6 * (1.0 if k % 2 == 1 else -1.0)
		var cc := base + side * off
		var r := Rect2(cc - half, half * 2.0)
		var hit := r.intersects(keep_out)
		for q in placed:
			if r.intersects(q):
				hit = true
				break
		if not hit:
			c = cc
			break
	placed.append(Rect2(c - half, half * 2.0).grow(0.25))
	P["rests"][c] = half
	for id in ids:
		var u: Dictionary = P["unit"][id]
		var f: Dictionary = u["flat"]
		var at: Vector3 = Vector3(c.x, 0.0, c.y) + turn * ((local[id] as Vector3) - Vector3(total_w * 0.5, 0.0, 0.0))
		u["staged"] = _at(turn * _lay(f), f["centre"], at)
		u["gxz_staged"] = c


# ---------------------------------------------------------------------------
# Scheduling onto named workers
# ---------------------------------------------------------------------------

static func _schedule(jobs: Array, crew_n: int) -> Dictionary:
	var workers: Array = []
	var b0 := Vector3.ZERO
	for j in jobs:
		if str(j["kind"]) == "carry":
			b0 = j["pick"]
			break
	for w in crew_n:
		workers.append({"id": w, "pos": b0 + Vector3(-2.0 + 0.8 * float(w), 0.0, -2.5), "free_at": 0.0,
			"segments": []})
	var prio := _priorities(jobs)
	var nd := {}          # job id -> number of deps not yet scheduled
	var succ := {}
	for j in jobs:
		nd[j["id"]] = (j["deps"] as Array).size()
		for d in j["deps"]:
			if not succ.has(d):
				succ[d] = []
			(succ[d] as Array).append(j["id"])
	var ready_at := {}    # schedulable job -> time its deps are all done
	for j in jobs:
		if int(nd[j["id"]]) == 0:
			ready_at[j["id"]] = 0.0
	var holders := {}     # raise job -> [worker ids]
	var now := 0.0
	var remaining := jobs.size()
	var guard := 0
	while remaining > 0 and guard < 400000:
		guard += 1
		var ready: Array = []
		for jid in ready_at:
			if float(ready_at[jid]) <= now + 1e-6:
				ready.append(jid)
		ready.sort_custom(func(a, c):
			if float(prio[a]) != float(prio[c]):
				return float(prio[a]) > float(prio[c])
			return int(a) < int(c))
		var assigned := false
		for jid in ready:
			var j: Dictionary = jobs[jid]
			var free: Array = workers.filter(func(w): return float(w["free_at"]) <= now + 1e-6)
			if free.size() < int(j["min"]):
				continue
			var k := mini(free.size(), int(j["max"]))
			var stands: Array = j["stands"]
			var target: Vector3 = stands[0] if not stands.is_empty() else now_pos(free)
			free.sort_custom(func(a, c):
				var da := _flat(a["pos"]).distance_to(_flat(target))
				var dc := _flat(c["pos"]).distance_to(_flat(target))
				if absf(da - dc) > 1e-6:
					return da < dc
				return int(a["id"]) < int(c["id"]))
			var crew: Array = free.slice(0, k)
			_assign(j, crew, now, holders, workers)
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
			if float(w["free_at"]) > now + 1e-6 and float(w["free_at"]) < INF:
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
	for j in jobs:
		if float(j["t1"]) < 0.0:
			blocked.append(j["id"])
		makespan = maxf(makespan, float(j["t1"]))
	return {"workers": workers, "makespan": makespan, "blocked": blocked}


static func now_pos(free: Array) -> Vector3:
	return free[0]["pos"] if not free.is_empty() else Vector3.ZERO


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## Put `crew` on job `j` starting `now`: their walking, waiting and work
## segments, the job's times, and the holds a raise starts / a release ends.
static func _assign(j: Dictionary, crew: Array, now: float, holders: Dictionary, workers: Array) -> void:
	var kind := str(j["kind"])
	if crew.is_empty():
		j["t0"] = now
		j["t1"] = now + float(j["work_s"])
		for rj in j.get("release_of", []):
			for wid in holders.get(rj, []):
				var w: Dictionary = workers[wid]
				var segs: Array = w["segments"]
				var from := float(segs[-1]["t1"]) if not segs.is_empty() else now
				segs.append({"kind": "hold", "t0": from, "t1": float(j["t1"]), "from": w["pos"], "to": w["pos"],
					"job": int(rj)})
				w["free_at"] = float(j["t1"])
			holders.erase(rj)
		return
	var stands: Array = j["stands"]
	var arrive := now
	var legs: Array = []
	for i in crew.size():
		var w: Dictionary = crew[i]
		var st: Vector3 = stands[mini(i, stands.size() - 1)] if not stands.is_empty() else w["pos"]
		var t_walk := _flat(w["pos"]).distance_to(_flat(st)) / WALK_MPS
		legs.append([st, now + t_walk])
		arrive = maxf(arrive, now + t_walk)
	var t1 := arrive + float(j["work_s"]) / float(maxi(crew.size(), 1))
	if kind == "carry":
		var dist := _flat(j["pick"]).distance_to(_flat(j["drop"]))
		j["t_lifted"] = arrive + T_LIFT_S
		j["t_moved"] = arrive + T_LIFT_S + dist / CARRY_MPS
		t1 = float(j["t_moved"]) + T_SET_S
	elif kind == "visit":
		var path: Array = j["path"]
		var tt := arrive
		var times: Array = [tt]
		for i in range(1, path.size()):
			tt += maxf((path[i] as Vector3).distance_to(path[i - 1]) / (WALK_MPS * 0.7), 0.1)
			times.append(tt)
		j["path_t"] = times
		t1 = tt + 30.0
	j["t0"] = arrive
	j["t1"] = t1
	j["crew"] = crew.map(func(w): return w["id"])
	for i in crew.size():
		var w: Dictionary = crew[i]
		var st: Vector3 = legs[i][0]
		var walk_end: float = legs[i][1]
		var segs: Array = w["segments"]
		if walk_end > now + 1e-6:
			segs.append({"kind": "walk", "t0": now, "t1": walk_end, "from": w["pos"], "to": st, "job": j["id"]})
		if arrive > walk_end + 1e-6:
			segs.append({"kind": "wait", "t0": walk_end, "t1": arrive, "from": st, "to": st, "job": j["id"]})
		if kind == "carry":
			var d := _flat(j["drop"]) - _flat(j["pick"])
			var dst: Vector3 = st + d
			segs.append({"kind": "lift", "t0": arrive, "t1": float(j["t_lifted"]), "from": st, "to": st, "job": j["id"]})
			segs.append({"kind": "carry", "t0": float(j["t_lifted"]), "t1": float(j["t_moved"]), "from": st,
				"to": dst, "job": j["id"]})
			segs.append({"kind": "set", "t0": float(j["t_moved"]), "t1": t1, "from": dst, "to": dst, "job": j["id"]})
			w["pos"] = dst
		elif kind == "visit":
			var path: Array = j["path"]
			var times: Array = j["path_t"]
			for k in range(1, path.size()):
				segs.append({"kind": "walk", "t0": times[k - 1], "t1": times[k], "from": path[k - 1], "to": path[k],
					"job": j["id"]})
			segs.append({"kind": "look", "t0": times[-1], "t1": t1, "from": path[-1], "to": path[-1], "job": j["id"]})
			w["pos"] = path[-1]
		else:
			var act := kind
			if kind == "seat" and int(j["min"]) >= 4 and i >= 2:
				act = "give"
			segs.append({"kind": act, "t0": arrive, "t1": t1, "from": st, "to": st, "job": j["id"], "slot": i})
			w["pos"] = st
		w["free_at"] = t1
	if bool(j.get("hold", false)):
		holders[j["id"]] = j["crew"].duplicate()
		for w in crew:
			w["free_at"] = INF


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
		memo[j["id"]] = float(j["work_s"]) / float(maxi(int(j["max"]), 1)) + best
	return memo


static func critical_path(tl: Dictionary) -> float:
	var p := _priorities(tl["jobs"])
	var best := 0.0
	for k in p:
		best = maxf(best, float(p[k]))
	return best


# ---------------------------------------------------------------------------
# state_at: a pure function of build time
# ---------------------------------------------------------------------------

## Everything a build site draws at build time t:
##   workers: [{id, pos (y = height above the ground), face, activity, clip,
##     rig, u, job, carrying: unit id}]
##   units: {id: {visible, xf: Transform3D (identity = installed)}}
##   done (jobs finished), stage (label of the latest job under way).
static func state_at(tl: Dictionary, t: float, with_units: bool = true) -> Dictionary:
	var jobs: Array = tl["jobs"]
	var ws: Array = []
	for w in tl["workers"]:
		ws.append(_worker_at(w, jobs, t))
	var units := {}
	if with_units:
		var um: Dictionary = tl["unit"]
		for id in um:
			units[id] = unit_pose(tl, str(id), t)
	var done := 0
	var stage := ""
	var stage_t := -1.0
	for j in jobs:
		if float(j["t1"]) >= 0.0 and t >= float(j["t1"]):
			done += 1
		if float(j["t0"]) >= 0.0 and t >= float(j["t0"]) and t < float(j["t1"]) and float(j["t0"]) > stage_t:
			stage_t = float(j["t0"])
			stage = str(j.get("label", j["kind"]))
	return {"workers": ws, "units": units, "done": done, "stage": stage, "t": t,
		"makespan": float(tl["makespan"])}


## One piece's pose at t: {visible, xf, g, gxz, rest}. g (0..1) is how much
## the piece sits on the ground rather than in the rack, and gxz the point
## whose ground it sits on: a site on uneven ground lifts or lowers it by g x
## that ground's height (and tilts it to the ground's slope by rest), so the
## yard and the bundles lie on the terrain the crew walks on while the rack
## stays on its own base.
static func unit_pose(tl: Dictionary, id: String, t: float) -> Dictionary:
	var u: Dictionary = tl["unit"][id]
	var jobs: Array = tl["jobs"]
	var ci := int(u["carry"])
	var ii := int(u["install"])
	var pile: Transform3D = u["pile"]
	var staged: Transform3D = u["staged"]
	var cen: Vector3 = (u.get("flat", {}) as Dictionary).get("centre", Vector3.ZERO)
	var gp: Vector2 = u.get("gxz_pile", Vector2.ZERO)
	var gs: Vector2 = u.get("gxz_staged", gp)
	if ci >= 0:
		var c: Dictionary = jobs[ci]
		var c0 := float(c["t0"])
		if c0 < 0.0 or t < c0:
			return _pose(pile, 1.0, gp)
		var lifted := float(c["t_lifted"])
		var moved := float(c["t_moved"])
		var c1 := float(c["t1"])
		var up := Vector3(0.0, float(c.get("lift_y", CARRY_H)), 0.0)
		var back := _flat(c["pick"]) - _flat(c["drop"])
		if t < lifted:
			var e := _ease((t - c0) / maxf(lifted - c0, 1e-6))
			return _pose(_blend(pile, Transform3D(staged.basis, staged.origin + up + back), cen, e), 1.0, gp, 1.0 - e)
		if t < moved:
			var e2 := (t - lifted) / maxf(moved - lifted, 1e-6)
			return _pose(Transform3D(staged.basis, staged.origin + up + back * (1.0 - e2)), 1.0, gp.lerp(gs, e2), 0.0)
		if t < c1:
			var e3 := _ease((t - moved) / maxf(c1 - moved, 1e-6))
			return _pose(_blend(Transform3D(staged.basis, staged.origin + up), staged, cen, e3), 1.0, gs, e3)
	if ii < 0:
		return _pose(staged, 1.0, gs)
	var j: Dictionary = jobs[ii]
	var t0 := float(j["t0"])
	var t1 := float(j["t1"])
	if t0 < 0.0 or t < t0:
		return _pose(staged, 1.0, gs)
	if t >= t1:
		return _pose(Transform3D(), 0.0, gs)
	var n := int(u["n"])
	var i := int(u["i"])
	var span := (t1 - t0) / float(maxi(n, 1))
	var a := t0 + span * float(i)
	if t < a:
		return _pose(staged, 1.0, gs)
	var f := _ease(clampf((t - a) / maxf(span, 1e-6), 0.0, 1.0))
	if bool(u["raise"]):
		return _pose(_pivot_xf(u["pivot"], float(u["lie"]) * (1.0 - f)), 1.0 - f, gs)
	return _pose(_blend(staged, Transform3D(), cen, f), 1.0 - f, gs)


## rest (0..1, default g): how much it lies on the ground there, taking the
## ground's slope (a stack or a bundle set down); 0 while carried.
static func _pose(xf: Transform3D, g: float, gxz: Vector2, rest: float = -1.0) -> Dictionary:
	return {"visible": true, "xf": xf, "g": g, "gxz": gxz, "rest": g if rest < 0.0 else rest}


## From a to b by f, the piece's centre `c` on a straight line (a plain
## interpolate_with turns about the build origin, metres away, and swings the
## piece through the air).
static func _blend(a: Transform3D, b: Transform3D, c: Vector3, f: float) -> Transform3D:
	var bas := a.basis.orthonormalized().slerp(b.basis.orthonormalized(), f)
	var p := (a * c).lerp(b * c, f)
	return Transform3D(bas, p - bas * c)


static func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


static func _worker_at(w: Dictionary, jobs: Array, t: float) -> Dictionary:
	var segs: Array = w["segments"]
	var out := {"id": w["id"], "activity": "idle", "job": -1, "clip": "", "rig": "", "u": 0.0, "carrying": ""}
	if segs.is_empty() or t < float(segs[0]["t0"]):
		var p0: Vector3 = segs[0]["from"] if not segs.is_empty() else w["pos"]
		out["pos"] = p0
		out["face"] = p0 + Vector3(0, 0, 1)
		return out
	# Binary search: the last segment starting at or before t.
	var lo := 0
	var hi := segs.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if float(segs[mid]["t0"]) <= t:
			lo = mid
		else:
			hi = mid - 1
	var s: Dictionary = segs[lo]
	var job: Dictionary = jobs[int(s["job"])]
	if t >= float(s["t1"]):
		var p: Vector3 = s["to"]
		out["pos"] = p
		var from: Vector3 = s["from"]
		out["face"] = p + (_flat(p - from).normalized() if _flat(p - from).length() > 0.01 else Vector3(0, 0, 1))
		return out
	var u := clampf((t - float(s["t0"])) / maxf(float(s["t1"]) - float(s["t0"]), 1e-6), 0.0, 1.0)
	var kind := str(s["kind"])
	out["activity"] = kind
	out["job"] = job["id"]
	out["u"] = u
	out["pos"] = (s["from"] as Vector3).lerp(s["to"], u)
	out["clip"] = str(CLIP_FOR.get(kind, ""))
	out["rig"] = str(RIG_FOR.get(kind, ""))
	match kind:
		"walk":
			out["face"] = s["to"]
		"carry", "lift", "set":
			var heading := (_flat(job["drop"]) - _flat(job["pick"])).normalized()
			out["face"] = (out["pos"] as Vector3) + (heading if kind == "carry" else Vector3.ZERO)
			if kind != "carry":
				out["face"] = _flat(job["pick"] if kind == "lift" else job["drop"])
			out["carrying"] = str((job["units"] as Array).front()) if not (job["units"] as Array).is_empty() else ""
		"look":
			out["face"] = (s["to"] as Vector3) + Vector3(0, 0, 1)
		_:
			var focus: Vector3 = job.get("face", Vector3.ZERO)
			if focus == Vector3.ZERO:
				var st: Array = job["stands"]
				var c := Vector3.ZERO
				for p in st:
					c += p as Vector3
				focus = c / float(maxi(st.size(), 1))
				if st.size() <= 1:
					focus = (s["to"] as Vector3) + Vector3(0, 0, 1)
			out["face"] = focus
	return out


## "crew 6 · 1 h 12 min · 86 jobs".
static func summary(tl: Dictionary) -> String:
	var s := int(tl["makespan"])
	var b: Array = tl["blocked"]
	var span := "%d h %02d min" % [s / 3600, (s % 3600) / 60] if s >= 3600 else "%d min" % maxi(1, s / 60)
	return "crew %d · %s · %s%s" % [int(tl["crew"]), span,
		UiText.count((tl["jobs"] as Array).size(), "job"),
		(" · %d can't start" % b.size()) if not b.is_empty() else ""]
