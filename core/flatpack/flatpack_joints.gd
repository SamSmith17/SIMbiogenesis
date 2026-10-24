class_name FlatpackJoints
extends RefCounted

## The joint solver: every slot, mortise and wedge hole of a flat-pack design
## is DERIVED from the 3D assembly, never placed by hand.
##
## A template emits parts as planar slabs — a straight-edged 2D base polygon in
## the part's own frame plus a Transform3D (inches) whose basis z is the
## sheet's normal and whose xy plane is the sheet's mid-plane — and a list of
## joints between pairs of parts. For each joint the solver intersects the two
## mid-planes, clips that line to both outlines and cuts:
##
##   cross_lap  half-laps (the PlayaTech slot): A is notched from the end of
##              the overlap toward `open` (a world direction), B from the other
##              end; A takes `ratio` of the overlap. Each slot is as wide as the
##              other sheet is thick (divided by sin of the angle between the
##              sheets) plus clearance on each side. ratio 1 = only A is cut (a
##              clearance slot), ratio 0 = only B.
##   tenon      A's outline already carries tabs that pass through B; B gets a
##              mortise (a hole) for every stretch of A that crosses it, or an
##              edge slot when that stretch reaches B's edge. With `wedge`, A
##              gets a wedge hole just past B's far face (drawn in by DRAW_IN so
##              the wedge pulls the joint tight) and the wedge is added as a
##              part of its own.
##
## Designs may have several POSES (the sample sofa: upright, reclined, flat
## daybed) built from the same parts. Slots are found in every pose and laid
## into the parts together, so one set of parts assembles every way — exactly
## what the sample does. Parts in one `match` group are cut identically (the
## union of their slots), so they are interchangeable on site.

const EPS := 1e-5
## Closest two sheets may be to parallel and still lap (degrees between them).
const MIN_LAP_ANGLE_DEG := 45.0
## How far a wedge hole's inner edge sits INSIDE the far face of the part it
## locks, so driving the wedge pulls the joint tight (1/16").
const DRAW_IN := 0.0625
## Wedge: length through the tab, and its width at the tip and the head.
const WEDGE_LEN := 5.0
const WEDGE_TIP := 0.75
const WEDGE_HEAD := 1.6
## Material a wedge hole needs beyond it, toward the tab's end.
const WEDGE_END_MARGIN := 0.375
## A slot deeper than this share of the part's depth along it is flagged.
const DEEP_SLOT_SHARE := 0.6


## Mid-plane geometry of one part, in its pose.
static func _plane(frame: Transform3D) -> Dictionary:
	return {"o": frame.origin, "n": frame.basis.z.normalized()}


## The base polygon used for chords (circle parts tessellated).
static func chord_poly(part: Dictionary) -> PackedVector2Array:
	if part.has("circle"):
		var c: Dictionary = part["circle"]
		return FlatpackProfile.tessellate(FlatpackProfile.circle_ring(c["c"], float(c["r"])), 0.25)
	return part.get("base", PackedVector2Array())


## Crossings of the 2D line p + d t with a polygon, paired into the
## parameter intervals that lie inside it.
static func line_intervals(poly: PackedVector2Array, p: Vector2, d: Vector2) -> Array:
	var ts: Array = []
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var sa := d.x * (a.y - p.y) - d.y * (a.x - p.x)
		var sb := d.x * (b.y - p.y) - d.y * (b.x - p.x)
		if (sa > 0.0) == (sb > 0.0):
			continue
		var k := sa / (sa - sb)
		var x := a + (b - a) * k
		ts.append((x - p).dot(d) / d.length_squared())
	ts.sort()
	var out: Array = []
	var i2 := 0
	while i2 + 1 < ts.size():
		if float(ts[i2 + 1]) - float(ts[i2]) > EPS:
			out.append(Vector2(float(ts[i2]), float(ts[i2 + 1])))
		i2 += 2
	return out


## The line where two mid-planes meet: {p (3D point), d (3D unit dir), sin}.
static func plane_line(fa: Transform3D, fb: Transform3D) -> Dictionary:
	var pa := _plane(fa)
	var pb := _plane(fb)
	var na: Vector3 = pa["n"]
	var nb: Vector3 = pb["n"]
	var raw := na.cross(nb)
	var s := raw.length()
	if s < 1e-4:
		return {}
	var d := raw / s
	var c := na.dot(nb)
	var ha := na.dot(pa["o"])
	var hb := nb.dot(pb["o"])
	var det := 1.0 - c * c
	var p := (na * (ha - hb * c) + nb * (hb - ha * c)) / det
	return {"p": p, "d": d, "sin": s}


## The line in a part's 2D frame: {p, d} (d unit; the 3D parameter carries
## over because the frame is rigid).
static func line_in_part(frame: Transform3D, line: Dictionary) -> Dictionary:
	var inv := frame.affine_inverse()
	var p3: Vector3 = inv * (line["p"] as Vector3)
	var d3: Vector3 = inv.basis * (line["d"] as Vector3)
	return {"p": Vector2(p3.x, p3.y), "d": Vector2(d3.x, d3.y)}


## The base-polygon edge a 2D point sits on, and how far along it: {edge, at}.
static func locate_on_edge(poly: PackedVector2Array, q: Vector2, tol: float = 1e-3) -> Dictionary:
	var best := -1
	var best_d := INF
	var best_at := 0.0
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var ab := b - a
		var L2 := ab.length_squared()
		if L2 < EPS:
			continue
		var t := clampf((q - a).dot(ab) / L2, 0.0, 1.0)
		var dist := (a + ab * t).distance_to(q)
		if dist < best_d:
			best_d = dist
			best = i
			best_at = t * sqrt(L2)
	if best < 0 or best_d > tol:
		return {}
	return {"edge": best, "at": best_at}


static func frame_in_pose(part: Dictionary, pose: Dictionary) -> Transform3D:
	var frames: Dictionary = pose.get("frames", {})
	var id := str(part.get("id", ""))
	if frames.has(id):
		return frames[id]
	return part.get("frame", Transform3D.IDENTITY)


static func visible_in_pose(part: Dictionary, pose: Dictionary) -> bool:
	var id := str(part.get("id", ""))
	if (pose.get("hidden", []) as Array).has(id):
		return false
	var only: Array = part.get("poses", [])
	return only.is_empty() or only.has(str(pose.get("id", "")))


## Resolve every joint in every pose. `parts` is an Array of part dicts (each
## gains `notches` and `holes`); returns {parts, warnings, results}. opts:
## thickness (actual), clearance (per side), wedge_clearance.
static func resolve(parts: Array, joints: Array, poses: Array, opts: Dictionary = {}) -> Dictionary:
	var t := float(opts.get("thickness", 0.469))
	var clr := float(opts.get("clearance", 0.01))
	var warnings: Array = []
	var by_id := {}
	for p in parts:
		by_id[str(p["id"])] = p
		if not p.has("notches"):
			p["notches"] = []
		if not p.has("holes"):
			p["holes"] = []
	var all_poses := poses if not poses.is_empty() else [{"id": "", "label": "Assembled"}]
	var results: Array = []
	var wedges: Array = []
	for j in joints:
		var a: Dictionary = by_id.get(str(j.get("a", "")), {})
		var b: Dictionary = by_id.get(str(j.get("b", "")), {})
		if a.is_empty() or b.is_empty():
			warnings.append("a joint names a part that does not exist")
			continue
		var jpose := str(j.get("pose", ""))
		var hit := false
		for pose in all_poses:
			if not jpose.is_empty() and jpose != str(pose.get("id", "")):
				continue
			if not visible_in_pose(a, pose) or not visible_in_pose(b, pose):
				continue
			var r := _resolve_one(a, b, j, pose, t, clr, warnings, wedges)
			if not r.is_empty():
				hit = true
				r["pose"] = str(pose.get("id", ""))
				results.append(r)
		if not hit:
			warnings.append("%s and %s never meet, so no slot was cut" % [
				str(a.get("name", a["id"])), str(b.get("name", b["id"]))])
	for w in wedges:
		parts.append(w)
		by_id[str(w["id"])] = w
	_unify_match_groups(parts)
	_dedupe_all(parts)
	_validate_slots(parts, t, warnings)
	return {"parts": parts, "warnings": warnings, "results": results}


static func _resolve_one(a: Dictionary, b: Dictionary, j: Dictionary, pose: Dictionary,
		t: float, clr: float, warnings: Array, wedges: Array) -> Dictionary:
	var fa := frame_in_pose(a, pose)
	var fb := frame_in_pose(b, pose)
	var line := plane_line(fa, fb)
	if line.is_empty():
		warnings.append("%s and %s are parallel and cannot be slotted together" % [
			str(a.get("name", "")), str(b.get("name", ""))])
		return {}
	var sin_ab := float(line["sin"])
	if rad_to_deg(asin(clampf(sin_ab, 0.0, 1.0))) < MIN_LAP_ANGLE_DEG:
		warnings.append("%s meets %s at too shallow an angle to slot" % [
			str(a.get("name", "")), str(b.get("name", ""))])
		return {}
	var kind := str(j.get("kind", "cross_lap"))
	var open: Vector3 = j.get("open", Vector3.UP)
	if kind == "cross_lap" and (line["d"] as Vector3).dot(open) < 0.0:
		line["d"] = -(line["d"] as Vector3)
	var la := line_in_part(fa, line)
	var lb := line_in_part(fb, line)
	var ia := line_intervals(chord_poly(a), la["p"], la["d"])
	var ib := line_intervals(chord_poly(b), lb["p"], lb["d"])
	var ta := float(a.get("thickness", t))
	var tb := float(b.get("thickness", t))
	if kind == "tenon":
		return _tenon(a, b, j, fa, fb, line, la, lb, ia, ib, ta, tb, sin_ab, clr, warnings, wedges, pose)
	# Cross-lap: the longest overlap of the two chords.
	var best := Vector2.ZERO
	var best_a := Vector2.ZERO
	var best_b := Vector2.ZERO
	for x: Vector2 in ia:
		for y: Vector2 in ib:
			var lo := maxf(x.x, y.x)
			var hi := minf(x.y, y.y)
			if hi - lo > best.y - best.x:
				best = Vector2(lo, hi)
				best_a = x
				best_b = y
	if best.y - best.x < 0.05:
		return {}
	var overlap := best.y - best.x
	var ratio := clampf(float(j.get("ratio", 0.5)), 0.0, 1.0)
	var depth_a := ratio * overlap
	var depth_b := overlap - depth_a
	if ratio > 0.0:
		var entry := best_a.y
		var dep := entry - (best.y - depth_a)
		_add_slot(a, la, entry, -1.0, tb / sin_ab + 2.0 * clr, dep, j, warnings)
	if ratio < 1.0:
		var entry_b := best_b.x
		var dep_b := (best.x + depth_b) - entry_b
		_add_slot(b, lb, entry_b, 1.0, ta / sin_ab + 2.0 * clr, dep_b, j, warnings)
	return {"joint": str(j.get("id", "")), "kind": "cross_lap", "overlap": overlap,
		"depth_a": depth_a, "depth_b": depth_b}


## Lay a slot into a part: it enters at parameter `entry` on the part's line
## and runs `depth` along the line in direction `sgn` (+1 = increasing t).
static func _add_slot(part: Dictionary, l: Dictionary, entry: float, sgn: float,
		width: float, depth: float, j: Dictionary, warnings: Array) -> void:
	if depth <= 0.01:
		return
	if part.has("circle"):
		warnings.append("%s is round; slots can only go into straight edges" % str(part.get("name", "")))
		return
	var poly: PackedVector2Array = part["base"]
	var d: Vector2 = l["d"]
	var q: Vector2 = (l["p"] as Vector2) + d * entry
	var loc := locate_on_edge(poly, q, 0.01)
	if loc.is_empty():
		warnings.append("a slot in %s does not start on an edge" % str(part.get("name", "")))
		return
	(part["notches"] as Array).append(FlatpackProfile.make_notch(int(loc["edge"]),
		float(loc["at"]), width, depth, d * sgn, {"joint": str(j.get("id", ""))}))


static func _tenon(a: Dictionary, b: Dictionary, j: Dictionary, fa: Transform3D, fb: Transform3D,
		line: Dictionary, la: Dictionary, lb: Dictionary, ia: Array, ib: Array, ta: float,
		tb: float, sin_ab: float, clr: float, warnings: Array, wedges: Array,
		pose: Dictionary) -> Dictionary:
	var made := 0
	var holes_a: Array = []
	for x: Vector2 in ia:
		for y: Vector2 in ib:
			var lo := maxf(x.x, y.x)
			var hi := minf(x.y, y.y)
			if hi - lo < 0.05:
				continue
			var touches_lo: bool = x.x <= y.x + 1e-3
			var touches_hi: bool = x.y >= y.y - 1e-3
			var width := ta / sin_ab + 2.0 * clr
			if touches_lo and touches_hi:
				warnings.append("%s is wider than %s where they meet" % [
					str(a.get("name", "")), str(b.get("name", ""))])
				continue
			if touches_lo:
				_add_slot(b, lb, y.x, 1.0, width, (hi - y.x) + clr, j, warnings)
			elif touches_hi:
				_add_slot(b, lb, y.y, -1.0, width, (y.y - lo) + clr, j, warnings)
			else:
				var mid := (lo + hi) * 0.5
				var c2: Vector2 = (lb["p"] as Vector2) + (lb["d"] as Vector2) * mid
				var margin := minf(lo - y.x, y.y - hi)
				if margin < 0.5:
					warnings.append("a mortise in %s is only %s from its edge" % [
						str(b.get("name", "")), FlatpackSpec.fmt_in(margin)])
				(b["holes"] as Array).append({"c": c2, "axis": lb["d"], "length": hi - lo + 2.0 * clr,
					"width": width, "joint": str(j.get("id", "")), "kind": "mortise"})
				holes_a.append(Vector2(lo, hi))
			made += 1
	if made == 0:
		return {}
	if bool(j.get("wedge", false)) and not holes_a.is_empty():
		_add_wedges(a, b, j, fa, fb, la, holes_a, tb, clr, warnings, wedges, pose)
	return {"joint": str(j.get("id", "")), "kind": "tenon", "mortises": made}


## Wedge holes in A just past B's far face, and one wedge part per hole.
static func _add_wedges(a: Dictionary, b: Dictionary, j: Dictionary, fa: Transform3D,
		fb: Transform3D, la: Dictionary, chords: Array, tb: float, clr: float, warnings: Array,
		wedges: Array, pose: Dictionary) -> void:
	var nb := fb.basis.z.normalized()
	var na := fa.basis.z.normalized()
	var inv := fa.affine_inverse()
	var n3: Vector3 = inv.basis * nb
	var n2 := Vector2(n3.x, n3.y).normalized()
	# Which side of B the body of A is on: the tab points the other way.
	var poly: PackedVector2Array = chord_poly(a)
	var cen := Vector2.ZERO
	for p in poly:
		cen += p
	cen /= maxf(poly.size(), 1)
	var cen3 := fa * Vector3(cen.x, cen.y, 0.0)
	var side := signf((cen3 - fb.origin).dot(nb))
	if side == 0.0:
		side = 1.0
	var tab2 := -n2 * side
	var tab3 := -nb * side
	var hole_h := (WEDGE_TIP + WEDGE_HEAD) * 0.5
	var t_wedge := float(j.get("wedge_thickness", float(a.get("thickness", tb))))
	var k := 0
	for ch: Vector2 in chords:
		var mid: float = (ch.x + ch.y) * 0.5
		var on_line: Vector2 = (la["p"] as Vector2) + (la["d"] as Vector2) * mid
		# Distance from B's mid-plane to A's line point along the tab.
		var line3 := fa * Vector3(on_line.x, on_line.y, 0.0)
		var off := (line3 - fb.origin).dot(tab3)
		var start := tb * 0.5 - DRAW_IN - off
		var hc := on_line + tab2 * (start + hole_h * 0.5)
		var end_probe := on_line + tab2 * (start + hole_h + WEDGE_END_MARGIN)
		if not Geometry2D.is_point_in_polygon(end_probe, poly):
			warnings.append("the tab of %s is too short for a wedge" % str(a.get("name", "")))
			continue
		(a["holes"] as Array).append({"c": hc, "axis": la["d"], "length": t_wedge + 2.0 * clr,
			"width": hole_h, "joint": str(j.get("id", "")), "kind": "wedge_hole"})
		# The wedge: its straight edge bears on B's side of the hole.
		var hc3 := fa * Vector3(hc.x, hc.y, 0.0)
		var y0 := hc3 - tab3 * (hole_h * 0.5)
		var xax := na
		var zax := xax.cross(tab3).normalized()
		var basis := Basis(xax, tab3, zax)
		var origin := y0 - xax * (WEDGE_LEN * 0.5)
		var wid := "wedge_%s_%d" % [str(j.get("id", "j")), k]
		var poses_for: Array = []
		if not str(j.get("pose", "")).is_empty():
			poses_for = [str(j.get("pose", ""))]
		wedges.append({
			"id": wid, "name": "Wedge", "group": "Wedge", "match": "Wedge", "role": "wedge",
			"base": PackedVector2Array([Vector2(0, 0), Vector2(WEDGE_LEN, 0),
				Vector2(WEDGE_LEN, WEDGE_HEAD), Vector2(0, WEDGE_TIP)]),
			"corner_r": PackedFloat64Array([0.1, 0.1, 0.1, 0.1]),
			"frame": Transform3D(basis, origin), "grain": "x", "poses": poses_for,
			"thickness": t_wedge, "notches": [], "holes": [],
		})
		k += 1


## Parts in one `match` group (same base) take the union of their slots.
static func _unify_match_groups(parts: Array) -> void:
	var groups := {}
	for p in parts:
		var m := str(p.get("match", ""))
		if m.is_empty():
			continue
		if not groups.has(m):
			groups[m] = []
		(groups[m] as Array).append(p)
	for m in groups:
		var members: Array = groups[m]
		if members.size() < 2:
			continue
		var all_n: Array = []
		var all_h: Array = []
		for p in members:
			all_n.append_array(p["notches"])
			all_h.append_array(p["holes"])
		for p in members:
			p["notches"] = all_n.duplicate(true)
			p["holes"] = all_h.duplicate(true)


## One slot where two were found at the same place (another pose, or a match
## group): the deeper one wins.
static func _dedupe_all(parts: Array) -> void:
	for p in parts:
		var out: Array = []
		for nt in p["notches"]:
			var merged := false
			for o in out:
				if int(o["edge"]) == int(nt["edge"]) and absf(float(o["at"]) - float(nt["at"])) < 0.02 \
						and absf(float(o["width"]) - float(nt["width"])) < 0.02 \
						and _same_dir(o["dir"], nt["dir"]):
					o["depth"] = maxf(float(o["depth"]), float(nt["depth"]))
					merged = true
					break
			if not merged:
				out.append((nt as Dictionary).duplicate())
		p["notches"] = out
		var hout: Array = []
		for h in p["holes"]:
			var dup := false
			for o in hout:
				if (o["c"] as Vector2).distance_to(h["c"]) < 0.02 \
						and absf(float(o["length"]) - float(h["length"])) < 0.02 \
						and absf(float(o["width"]) - float(h["width"])) < 0.02:
					dup = true
					break
			if not dup:
				hout.append((h as Dictionary).duplicate())
		p["holes"] = hout


## Two slot directions agree (an unset direction means square to the edge).
static func _same_dir(a: Vector2, b: Vector2) -> bool:
	if a.length() < 1e-6 or b.length() < 1e-6:
		return a.length() < 1e-6 and b.length() < 1e-6
	return a.normalized().dot(b.normalized()) > 0.999


static func _validate_slots(parts: Array, t: float, warnings: Array) -> void:
	for p in parts:
		if p.has("circle"):
			continue
		var poly: PackedVector2Array = p["base"]
		var name := str(p.get("name", p.get("id", "")))
		for nt in p["notches"]:
			if bool(nt.get("arch", false)):
				continue
			var u: Vector2 = (nt["dir"] as Vector2).normalized()
			var lo := INF
			var hi := -INF
			for q in poly:
				var s := q.dot(u)
				lo = minf(lo, s)
				hi = maxf(hi, s)
			if float(nt["depth"]) > DEEP_SLOT_SHARE * (hi - lo) + 1e-3:
				warnings.append("a slot in %s cuts %d%% of the way through it" % [
					name, int(round(100.0 * float(nt["depth"]) / maxf(hi - lo, 0.01)))])
		# Material between neighbouring slots on one edge.
		var by_edge := {}
		for nt in p["notches"]:
			var e := int(nt["edge"])
			if not by_edge.has(e):
				by_edge[e] = []
			(by_edge[e] as Array).append(nt)
		for e in by_edge:
			var list: Array = by_edge[e]
			list.sort_custom(func(x, y): return float(x["at"]) < float(y["at"]))
			for i in range(1, list.size()):
				var gap := float(list[i]["at"]) - float(list[i - 1]["at"]) \
					- (float(list[i]["width"]) + float(list[i - 1]["width"])) * 0.5
				if gap < 2.0 * t and gap > -1e-3:
					warnings.append("only %s of %s is left between two slots" % [
						FlatpackSpec.fmt_in(gap), name])


# ---------------------------------------------------------------------------
# Interference check (does the assembly actually go together?)
# ---------------------------------------------------------------------------

## Does the assembly go together? For every pair of visible parts that are
## not parallel, walk the line where their mid-planes meet: a point of that
## line that is solid in BOTH finished outlines is a clash (each slot must
## leave the other part's material room). Parallel sheets that overlap in
## thickness are checked on a coarse grid. Returns [{a, b, length_in}].
static func interference(design: Dictionary, pose_id: String = "", step: float = 0.05) -> Array:
	var parts: Array = design.get("parts", [])
	var poses: Array = design.get("poses", [])
	var pose: Dictionary = {"id": pose_id}
	for p in poses:
		if str(p.get("id", "")) == pose_id:
			pose = p
	var info: Array = []
	for p in parts:
		if not visible_in_pose(p, pose) or bool(p.get("hidden", false)):
			continue
		var outer := FlatpackProfile.tessellate(p["ring"], 0.1)
		var holes: Array = []
		for h in p.get("hole_rings", []):
			holes.append(FlatpackProfile.tessellate(h, 0.1))
		var fr := frame_in_pose(p, pose)
		var tt := float(p.get("thickness", 0.5))
		var aabb := AABB()
		var first := true
		for q in outer:
			for zz in [-tt * 0.5, tt * 0.5]:
				var w := fr * Vector3(q.x, q.y, zz)
				if first:
					aabb = AABB(w, Vector3.ZERO)
					first = false
				else:
					aabb = aabb.expand(w)
		info.append({"part": p, "outer": outer, "holes": holes, "frame": fr, "aabb": aabb, "t": tt})
	var out: Array = []
	for i in info.size():
		var A: Dictionary = info[i]
		for k in range(i + 1, info.size()):
			var B: Dictionary = info[k]
			if not (A["aabb"] as AABB).grow(0.01).intersects((B["aabb"] as AABB)):
				continue
			var clash := _line_clash(A, B, step)
			if clash > 0.0:
				out.append({"a": str(A["part"]["id"]), "b": str(B["part"]["id"]), "length_in": clash})
	return out


static func _solid(q: Vector2, P: Dictionary) -> bool:
	return Geometry2D.is_point_in_polygon(q, P["outer"]) and not _in_any(q, P["holes"])


static func _line_clash(A: Dictionary, B: Dictionary, step: float) -> float:
	var fa: Transform3D = A["frame"]
	var fb: Transform3D = B["frame"]
	var line := plane_line(fa, fb)
	if line.is_empty():
		return _parallel_clash(A, B)
	var la := line_in_part(fa, line)
	var lb := line_in_part(fb, line)
	var ia := line_intervals(A["outer"], la["p"], la["d"])
	var ib := line_intervals(B["outer"], lb["p"], lb["d"])
	var total := 0.0
	for x: Vector2 in ia:
		for y: Vector2 in ib:
			var lo := maxf(x.x, y.x)
			var hi := minf(x.y, y.y)
			if hi - lo <= step:
				continue
			var t := lo + step * 0.5
			while t < hi:
				var qa: Vector2 = (la["p"] as Vector2) + (la["d"] as Vector2) * t
				var qb: Vector2 = (lb["p"] as Vector2) + (lb["d"] as Vector2) * t
				if _solid(qa, A) and _solid(qb, B):
					total += step
				t += step
	return total


static func _parallel_clash(A: Dictionary, B: Dictionary) -> float:
	var fa: Transform3D = A["frame"]
	var fb: Transform3D = B["frame"]
	var gap := absf((fb.origin - fa.origin).dot(fa.basis.z.normalized()))
	if gap >= (float(A["t"]) + float(B["t"])) * 0.5 - 0.01:
		return 0.0
	var inv_b := fb.affine_inverse()
	var bb := FlatpackProfile.bbox(A["outer"])
	var hits := 0
	var y := bb.position.y + 0.37
	while y < bb.end.y:
		var x := bb.position.x + 0.37
		while x < bb.end.x:
			var q := Vector2(x, y)
			if _solid(q, A):
				var lb: Vector3 = inv_b * (fa * Vector3(x, y, 0.0))
				if _solid(Vector2(lb.x, lb.y), B):
					hits += 1
			x += 1.0
		y += 1.0
	return float(hits)


static func _in_any(q: Vector2, polys: Array) -> bool:
	for h in polys:
		if Geometry2D.is_point_in_polygon(q, h):
			return true
	return false
