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
## "units")); {} builds them here. opts: {visit: bool (default true)}.
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
		"pile_fill": {}, "spec": s}
	_make_piles(P)
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
	var sched := _schedule(P["jobs"], crew_n)
	var tl := {"jobs": P["jobs"], "unit": P["unit"], "workers": sched["workers"],
		"makespan": sched["makespan"], "blocked": sched["blocked"], "crew": crew_n,
		"bounds": bounds, "piles": P["piles"], "radius_m": bounds.size.length() * 0.5}
	return tl


## Material piles in a row in front of the rack (the -Z side), one per kind.
static func _make_piles(P: Dictionary) -> void:
	var b: AABB = P["bounds"]
	var x := b.position.x
	var z := b.position.z - PILE_GAP_M
	var widths := {"frames": 2.0, "beams": 1.6, "lumber": 1.4, "sheets": 2.6, "walls": 2.6, "parts": 2.4}
	for k in ["frames", "beams", "lumber", "sheets", "walls", "parts"]:
		var w: float = widths[k]
		P["piles"][k] = Vector3(x + w * 0.5, 0.0, z)
		P["pile_fill"][k] = 0
		x += w + 1.0


## The unit's pose flat on the ground (its tall axis laid down), as a basis.
static func _flat_basis(bb: AABB) -> Basis:
	var sz := bb.size
	if sz.y >= maxf(sz.x, sz.z) * 0.9:
		return Basis(Vector3.BACK, PI * 0.5) if sz.x <= sz.z else Basis(Vector3.RIGHT, PI * 0.5)
	return Basis()


## Transform putting unit centre `c` (rotated by `bas`) at `p`.
static func _at(bas: Basis, c: Vector3, p: Vector3) -> Transform3D:
	return Transform3D(bas, p - bas * c)


## The next slot on pile `kind` for a unit of AABB `bb`: stacked 8 high,
## stacks side by side, lying flat.
static func _pile_pose(P: Dictionary, kind: String, bb: AABB) -> Transform3D:
	var k: int = P["pile_fill"][kind]
	P["pile_fill"][kind] = k + 1
	var bas := _flat_basis(bb)
	var ext := (bas * bb.size).abs()
	var layer := k % 8
	var stack := k / 8
	var org: Vector3 = P["piles"][kind]
	var p := org + Vector3(0.0, 0.03 + ext.y * (float(layer) + 0.5), -float(stack) * (ext.z + 0.25))
	return _at(bas, bb.get_center(), p)


static func _unit_rec(P: Dictionary, id: String, pile_kind: String) -> Dictionary:
	var bb: AABB = P["units"][id]["aabb"]
	var pile := _pile_pose(P, pile_kind, bb)
	var r := {"pile": pile, "staged": pile, "carry": -1, "install": -1, "i": 0, "n": 1,
		"raise": false, "pivot": Vector3.ZERO, "lie": 0.0}
	P["unit"][id] = r
	return r


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


## A carry job taking `ids` (one piece or a bundle) to `drop` (ground): the
## bundle keeps its pile arrangement and is set down there. Returns the job id.
static func _carry(P: Dictionary, ids: Array, crew: int, drop: Vector3, deps: Array, label: String) -> int:
	var first: Dictionary = P["unit"][ids[0]]
	var pick_xf: Transform3D = first["pile"]
	var bb0: AABB = P["units"][ids[0]]["aabb"]
	var pick := pick_xf * bb0.get_center()
	pick.y = 0.0
	var ext := (pick_xf.basis * bb0.size).abs()
	var pbb := AABB(pick - ext * 0.5, ext)
	var jid := _job(P, "carry", ids, deps, crew, crew, T_LIFT_S + T_SET_S, _stands_round(pbb, crew),
		{"pick": pick, "drop": Vector3(drop.x, 0.0, drop.z), "label": label})
	var d := Vector3(drop.x - pick.x, 0.0, drop.z - pick.z)
	for id in ids:
		var u: Dictionary = P["unit"][id]
		u["carry"] = jid
		# Staged where it was set down: the pile arrangement moved to the drop.
		var pile: Transform3D = u["pile"]
		u["staged"] = Transform3D(pile.basis, pile.origin + d)
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
				var pivot := Vector3(fbb.get_center().x, 0.0, fbb.get_center().z)
				u["raise"] = true
				u["pivot"] = pivot
				u["lie"] = sgn * PI * 0.5
				var lie_xf := _pivot_xf(pivot, sgn * PI * 0.5)
				u["lie_xf"] = lie_xf
				var lie_c := lie_xf * fbb.get_center()
				var cj := _carry(P, [fid], 2, Vector3(lie_c.x, 0.0, lie_c.z), chain, "carry " + _frame_name(fk))
				u["staged"] = lie_xf
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
				bu["staged"] = _at(Basis(), c, stage)
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


## One piece's pose at t: {visible, xf}.
static func unit_pose(tl: Dictionary, id: String, t: float) -> Dictionary:
	var u: Dictionary = tl["unit"][id]
	var jobs: Array = tl["jobs"]
	var ci := int(u["carry"])
	var ii := int(u["install"])
	var pile: Transform3D = u["pile"]
	var staged: Transform3D = u["staged"]
	if ci >= 0:
		var c: Dictionary = jobs[ci]
		var c0 := float(c["t0"])
		if c0 < 0.0 or t < c0:
			return {"visible": true, "xf": pile}
		var lifted := float(c["t_lifted"])
		var moved := float(c["t_moved"])
		var c1 := float(c["t1"])
		var up := Vector3(0.0, CARRY_H, 0.0)
		var d := _flat(c["drop"]) - _flat(c["pick"])
		if t < lifted:
			var e := _ease((t - c0) / maxf(lifted - c0, 1e-6))
			return {"visible": true, "xf": Transform3D(pile.basis, pile.origin + up * e)}
		if t < moved:
			var e2 := (t - lifted) / maxf(moved - lifted, 1e-6)
			return {"visible": true, "xf": Transform3D(pile.basis, pile.origin + up + d * e2)}
		if t < c1:
			var e3 := _ease((t - moved) / maxf(c1 - moved, 1e-6))
			var carried := Transform3D(pile.basis, pile.origin + up + d)
			return {"visible": true, "xf": carried.interpolate_with(staged, e3)}
	if ii < 0:
		return {"visible": true, "xf": staged}
	var j: Dictionary = jobs[ii]
	var t0 := float(j["t0"])
	var t1 := float(j["t1"])
	if t0 < 0.0 or t < t0:
		return {"visible": true, "xf": staged}
	if t >= t1:
		return {"visible": true, "xf": Transform3D()}
	var n := int(u["n"])
	var i := int(u["i"])
	var span := (t1 - t0) / float(maxi(n, 1))
	var a := t0 + span * float(i)
	if t < a:
		return {"visible": true, "xf": staged}
	var f := clampf((t - a) / maxf(span, 1e-6), 0.0, 1.0)
	if bool(u["raise"]):
		return {"visible": true, "xf": _pivot_xf(u["pivot"], float(u["lie"]) * (1.0 - _ease(f)))}
	return {"visible": true, "xf": staged.interpolate_with(Transform3D(), _ease(f))}


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
