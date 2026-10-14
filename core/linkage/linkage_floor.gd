class_name LinkageFloor
extends RefCounted
## Raised floor: reciprocal floor beams on the bottom ring + a plywood deck
## (port of `js/linkage/floor-geometry.js`, A4).
##
## The floor beams copy the top-ring reciprocal layout, mirrored onto the
## bottom H-ring: every module gets two beams, each anchored on one of its
## bottom scissor legs at `anchorDist` from the leg crossing and pointing
## toward the ring centre (rotated by the swing angle). Optional radial beams
## run in from each module's outer foot. The deck is the inner polygon of the
## bottom ring (the shared inner pivots), inset, laid on top of the beams and
## nested from plywood sheets like a wall (LinkageCoveringPlan).
##
## Pure. Config `floor` rides `LinkageParams.extra` in the web's camelCase.
## Beams are `LinkageSolver._make_beam` records (stack types `floor-beam` /
## `floor-beam-reciprocal`); the deck is a covering record (kind "wall",
## band "floor") in the game's snake_case.

const STACK_ID_BASE := 2000
const OFF_MAX := 1200.0
const LEN_MIN := 0.05
const LEN_MAX := 2400.0
const SECTION_MIN := 0.05
const SECTION_MAX := 48.0

const DEFAULTS := {
	"enabled": false,
	"beams": {
		"radialEnabled": false, "length": 120.0, "width": 1.5, "thickness": 3.5,
		"offsetH": -46.5, "offsetV": 0.0, "offsetT": 0.0,
		"parallelEnabled": true, "parallelLength": 96.0, "parallelWidth": 2.5,
		"parallelThickness": 1.5, "parallelSwingAngle": 0.0, "seat": "leg",
		"parallelOffsetV": 0.0, "parallelVOffset": 0.0, "anchorDist": 20.0,
		"anchorSideIn": 0.0, "rcpEndOffset": 0.0,
	},
	"deck": {"enabled": true, "thicknessIn": 0.75, "insetIn": 0.5},
	"visibility": {"beams": true, "deck": true},
}


static func _num(v, def: float) -> float:
	return float(v) if (v is float or v is int) and is_finite(float(v)) else def


static func _clampn(v, def: float, lo: float, hi: float) -> float:
	return clampf(_num(v, def), lo, hi)


## `normalizeFloor`, incl. the Phase-4 legacy `liftIn` configs.
static func normalize(raw) -> Dictionary:
	var d: Dictionary = DEFAULTS
	var r: Dictionary = raw if raw is Dictionary else {}
	var b: Dictionary = r.get("beams", {}) if r.get("beams") is Dictionary else {}
	var k: Dictionary = r.get("deck", {}) if r.get("deck") is Dictionary else {}
	var v: Dictionary = r.get("visibility", {}) if r.get("visibility") is Dictionary else {}
	var db: Dictionary = d["beams"]
	var legacy := b.has("liftIn") and not b.has("seat")
	var legacy_lift = (_num(b.get("liftIn"), 0.0) + _num(b.get("parallelVOffset"), 0.0) / 2.0) if legacy else null
	var off_v = b.get("offsetV") if b.has("offsetV") else (_num(b.get("liftIn"), 0.0) if legacy else null)
	var seat := "ringTop" if str(b.get("seat", "")) == "ringTop" else ("ringTop" if legacy else "leg")
	return {
		"enabled": bool(r.get("enabled", false)),
		"beams": {
			"radialEnabled": bool(b.get("radialEnabled", false)),
			"length": _clampn(b.get("length"), db["length"], LEN_MIN, LEN_MAX),
			"width": _clampn(b.get("width"), db["width"], SECTION_MIN, SECTION_MAX),
			"thickness": _clampn(b.get("thickness"), db["thickness"], SECTION_MIN, SECTION_MAX),
			"offsetH": _clampn(b.get("offsetH"), db["offsetH"], -OFF_MAX, OFF_MAX),
			"offsetV": _clampn(off_v, db["offsetV"], -OFF_MAX, OFF_MAX),
			"offsetT": _clampn(b.get("offsetT"), db["offsetT"], -OFF_MAX, OFF_MAX),
			"parallelEnabled": b.get("parallelEnabled", true) != false,
			"parallelLength": _clampn(b.get("parallelLength"), db["parallelLength"], LEN_MIN, LEN_MAX),
			"parallelWidth": _clampn(b.get("parallelWidth"), db["parallelWidth"], SECTION_MIN, SECTION_MAX),
			"parallelThickness": _clampn(b.get("parallelThickness"), db["parallelThickness"], SECTION_MIN, SECTION_MAX),
			"parallelSwingAngle": _clampn(b.get("parallelSwingAngle"), db["parallelSwingAngle"], -360.0, 360.0),
			"seat": seat,
			"parallelOffsetV": _clampn(b.get("parallelOffsetV") if b.has("parallelOffsetV") else legacy_lift,
				db["parallelOffsetV"], -OFF_MAX, OFF_MAX),
			"parallelVOffset": _clampn(b.get("parallelVOffset"), db["parallelVOffset"], -OFF_MAX, OFF_MAX),
			"anchorDist": _clampn(b.get("anchorDist"), db["anchorDist"], -OFF_MAX, OFF_MAX),
			"anchorSideIn": _clampn(b.get("anchorSideIn"), db["anchorSideIn"], -OFF_MAX, OFF_MAX),
			"rcpEndOffset": _clampn(b.get("rcpEndOffset"), db["rcpEndOffset"], -OFF_MAX, OFF_MAX),
		},
		"deck": {
			"enabled": k.get("enabled", true) != false,
			"thicknessIn": _clampn(k.get("thicknessIn"), d["deck"]["thicknessIn"], SECTION_MIN, SECTION_MAX),
			"insetIn": _clampn(k.get("insetIn"), d["deck"]["insetIn"], -OFF_MAX, OFF_MAX),
		},
		"visibility": {"beams": v.get("beams", true) != false, "deck": v.get("deck", true) != false},
	}


## The design's floor settings, normalised ({enabled: false…} when absent).
static func config(p: LinkageParams) -> Dictionary:
	return normalize(p.extra.get("floor"))


static func set_config(p: LinkageParams, cfg: Dictionary) -> void:
	p.extra["floor"] = normalize(cfg)


static func is_active(p: LinkageParams) -> bool:
	return bool(config(p)["enabled"]) and p.orientation != "vertical"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _beam_top_y(b: Dictionary) -> float:
	var cs = b.get("corners")
	if cs is Array and not (cs as Array).is_empty():
		var m := -INF
		for c in cs:
			m = maxf(m, (c as Vector3).y)
		return m
	return maxf((b["p1"] as Vector3).y, (b["p2"] as Vector3).y)


static func _beam_bottom_y(b: Dictionary) -> float:
	var cs = b.get("corners")
	if cs is Array and not (cs as Array).is_empty():
		var m := INF
		for c in cs:
			m = minf(m, (c as Vector3).y)
		return m
	return minf((b["p1"] as Vector3).y, (b["p2"] as Vector3).y)


static func _rotate_xz(dx: float, dz: float, rad: float) -> Vector2:
	var c := cos(rad)
	var s := sin(rad)
	return Vector2(dx * c - dz * s, dx * s + dz * c)


static func _hyp(x: float, z: float) -> float:
	return sqrt(x * x + z * z)


## Per-module frames on the BOTTOM ring (`extractFloorFrames`): the highest
## layer of each module's bottom scissor, the A/B legs, their crossing, inner
## ends, and the outer foot of the module's vertical stack.
static func extract_frames(beams: Array, num_modules: int) -> Dictionary:
	var bot: Array = []
	for b in beams:
		if str(b.get("stack_type", "")) == "horizontal-bottom" and b.get("p1") is Vector3 and b.get("p2") is Vector3:
			bot.append(b)
	if bot.is_empty():
		return {"frames": [], "cx": 0.0, "cz": 0.0, "ring_top_y": 0.0}
	var cx := 0.0
	var cz := 0.0
	var ring_top := -INF
	for b in bot:
		cx += ((b["p1"] as Vector3).x + (b["p2"] as Vector3).x) / 2.0
		cz += ((b["p1"] as Vector3).z + (b["p2"] as Vector3).z) / 2.0
		ring_top = maxf(ring_top, _beam_top_y(b))
	cx /= bot.size()
	cz /= bot.size()
	var frames: Array = []
	for i in num_modules:
		var mod: Array = []
		for b in bot:
			if int(b.get("module_index", -1)) == i:
				mod.append(b)
		if mod.is_empty():
			continue
		var pick := func(pat: String):
			var best = null
			for b in mod:
				if str(b.get("pattern_id", "")) != pat:
					continue
				if best == null or (b["center"] as Vector3).y > (best["center"] as Vector3).y:
					best = b
			return best
		var beam_a: Dictionary = pick.call("A") if pick.call("A") != null else mod[0]
		var beam_b: Dictionary = pick.call("B") if pick.call("B") != null else mod[0]
		var inner_a := _inner_end(beam_a, cx, cz)
		var inner_b := _inner_end(beam_b, cx, cz)
		var h_center: Vector2
		var isect := LinkageGeometry.seg_seg_intersect_xz(beam_a["p1"], beam_a["p2"], beam_b["p1"], beam_b["p2"])
		if not isect.is_empty() and float(isect["t"]) > -0.2 and float(isect["t"]) < 1.2 \
				and float(isect["s"]) > -0.2 and float(isect["s"]) < 1.2:
			var a1: Vector3 = beam_a["p1"]
			var a2: Vector3 = beam_a["p2"]
			var t := float(isect["t"])
			h_center = Vector2(a1.x + t * (a2.x - a1.x), a1.z + t * (a2.z - a1.z))
		else:
			h_center = Vector2((inner_a.x + inner_b.x) / 2.0, (inner_a.z + inner_b.z) / 2.0)
		# Outer foot of the module's vertical stack (lowest endpoint farthest from the centre).
		var foot = null
		var foot_r := -INF
		var foot_beam = null
		for vb in beams:
			var st := str(vb.get("stack_type", ""))
			if (st != "vertical" and st != "fixed-beam") or int(vb.get("module_index", -1)) != i:
				continue
			var p1: Vector3 = vb["p1"]
			var p2: Vector3 = vb["p2"]
			var lo := p1 if p1.y <= p2.y else p2
			var r := _hyp(lo.x - cx, lo.z - cz)
			if r > foot_r:
				foot_r = r
				foot = lo
				foot_beam = vb
		if foot == null:
			var o := _outer_end(beam_a, cx, cz)
			foot = o
		var in_x := 0.0
		var in_z := 0.0
		if foot_beam != null:
			var q1: Vector3 = foot_beam["p1"]
			var q2: Vector3 = foot_beam["p2"]
			var lo2 := q1 if q1.y <= q2.y else q2
			var hi2 := q2 if q1.y <= q2.y else q1
			in_x = hi2.x - lo2.x
			in_z = hi2.z - lo2.z
		if _hyp(in_x, in_z) < 1e-3:
			in_x = cx - (foot as Vector3).x
			in_z = cz - (foot as Vector3).z
		var in_len := _hyp(in_x, in_z)
		if in_len == 0.0:
			in_len = 1.0
		frames.append({
			"module_index": i, "beam_a": beam_a, "beam_b": beam_b,
			"inner_a": inner_a, "inner_b": inner_b, "h_center": h_center,
			"scissor_a": _scissor(inner_a, h_center), "scissor_b": _scissor(inner_b, h_center),
			"foot": Vector2((foot as Vector3).x, (foot as Vector3).z),
			"in_dir": Vector2(in_x / in_len, in_z / in_len),
		})
	return {"frames": frames, "cx": cx, "cz": cz, "ring_top_y": ring_top}


static func _inner_end(b: Dictionary, cx: float, cz: float) -> Vector3:
	var p1: Vector3 = b["p1"]
	var p2: Vector3 = b["p2"]
	return p1 if _hyp(p1.x - cx, p1.z - cz) <= _hyp(p2.x - cx, p2.z - cz) else p2


static func _outer_end(b: Dictionary, cx: float, cz: float) -> Vector3:
	var p1: Vector3 = b["p1"]
	return b["p2"] if _inner_end(b, cx, cz) == p1 else p1


static func _scissor(inner_end: Vector3, h_center: Vector2) -> Dictionary:
	var dx := inner_end.x - h_center.x
	var dz := inner_end.z - h_center.y
	var ln := _hyp(dx, dz)
	if ln == 0.0:
		ln = 1.0
	return {"inner_end": inner_end, "dir": Vector2(dx / ln, dz / ln), "max_dist": ln}


# ---------------------------------------------------------------------------
# Beams
# ---------------------------------------------------------------------------

## Floor beams (`generateFloorBeams`): empty when disabled, in arch mode, or
## below the reciprocal visibility fold angle. `beams` = the solved frame's.
static func floor_beams(beams: Array, p: LinkageParams, fold_rad: float) -> Array:
	var out: Array = []
	var floor := config(p)
	if not bool(floor["enabled"]) or p.orientation == "vertical":
		return out
	if rad_to_deg(fold_rad) < p.rcp_visible_angle:
		return out
	var cfg: Dictionary = floor["beams"]
	var ex := extract_frames(beams, p.modules)
	var frames: Array = ex["frames"]
	if frames.is_empty():
		return out
	var ring_top := float(ex["ring_top_y"])
	if bool(cfg["radialEnabled"]):
		var ln := float(cfg["length"])
		var w := float(cfg["width"])
		var t := float(cfg["thickness"])
		var y := ring_top + float(cfg["offsetV"]) + t / 2.0
		var oh := float(cfg["offsetH"])
		var ot := float(cfg["offsetT"])
		for f in frames:
			var ind: Vector2 = f["in_dir"]
			var tg := Vector2(-ind.y, ind.x)   # +90° from the inward radial in plan
			var ft: Vector2 = f["foot"]
			var start := Vector3(ft.x + ind.x * oh + tg.x * ot, y, ft.y + ind.y * oh + tg.y * ot)
			var end := Vector3(start.x + ind.x * ln, y, start.z + ind.y * ln)
			out.append(LinkageSolver._make_beam(start, end, w, t, {
				"module_index": f["module_index"], "stack_type": "floor-beam",
				"stack_id": STACK_ID_BASE + int(f["module_index"])}))
	if bool(cfg["parallelEnabled"]):
		var ln2 := float(cfg["parallelLength"])
		var w2 := float(cfg["parallelWidth"])
		var t2 := float(cfg["parallelThickness"])
		var swing := deg_to_rad(float(cfg["parallelSwingAngle"]))
		var split := float(cfg["parallelVOffset"])
		var off_v := float(cfg["parallelOffsetV"])
		var end_off := float(cfg["rcpEndOffset"])
		var side_in := float(cfg["anchorSideIn"])
		var dist := float(cfg["anchorDist"])
		var seat_on_leg := str(cfg["seat"]) != "ringTop"
		for f in frames:
			for side in 2:
				var sc: Dictionary = f["scissor_a"] if side == 0 else f["scissor_b"]
				var leg: Dictionary = f["beam_a"] if side == 0 else f["beam_b"]
				var sign := 1.0 if side == 0 else -1.0
				var sd: Vector2 = sc["dir"]
				var hc: Vector2 = f["h_center"]
				# Perpendicular to the leg in plan, mirrored for the two sides.
				var px := -sd.y * sign
				var pz := sd.x * sign
				var ax := hc.x + sd.x * dist + px * side_in
				var az := hc.y + sd.y * dist + pz * side_in
				var seat_y := _beam_top_y(leg) if seat_on_leg else ring_top
				var y := seat_y + t2 / 2.0 + off_v + sign * split / 2.0
				var d := _rotate_xz(sd.x, sd.y, swing * sign)
				var p1 := Vector3(ax - d.x * end_off, y, az - d.y * end_off)
				var p2 := Vector3(ax + d.x * ln2, y, az + d.y * ln2)
				out.append(LinkageSolver._make_beam(p1, p2, w2, t2, {
					"module_index": f["module_index"], "stack_type": "floor-beam-reciprocal",
					"stack_id": STACK_ID_BASE + 100 + int(f["module_index"]) * 2 + side,
					"pattern_id": "A" if side == 0 else "B"}))
	return out


# ---------------------------------------------------------------------------
# Deck
# ---------------------------------------------------------------------------

## Inner polygon of the bottom ring (`calculateFloorPolygon`): the shared
## inner pivots, clustered by angle, sorted round the centre and inset.
static func floor_polygon(beams: Array, inset_in: float, num_modules: int) -> Dictionary:
	var ex := extract_frames(beams, num_modules)
	var frames: Array = ex["frames"]
	var raw: Array = []
	for f in frames:
		for p in [f["inner_a"], f["inner_b"]]:
			raw.append(Vector2((p as Vector3).x, (p as Vector3).z))
	if raw.size() < 3:
		return {}
	var c0 := Vector2.ZERO
	for p in raw:
		c0 += p
	c0 /= raw.size()
	var ang := func(p: Vector2) -> float: return atan2(p.y - c0.y, p.x - c0.x)
	raw = _stable_sort_by(raw, ang)
	var tol := PI / maxf(3.0, frames.size())   # half a module
	var clusters: Array = []
	for p in raw:
		var a: float = ang.call(p)
		if not clusters.is_empty() and absf(a - float(clusters[-1]["ang"])) < tol:
			var cl: Dictionary = clusters[-1]
			(cl["pts"] as Array).append(p)
			var s := 0.0
			for q in cl["pts"]:
				s += float(ang.call(q))
			cl["ang"] = s / (cl["pts"] as Array).size()
		else:
			clusters.append({"pts": [p], "ang": a})
	if clusters.size() > 1:
		var first: Dictionary = clusters[0]
		var last: Dictionary = clusters[-1]
		if absf((float(last["ang"]) - TAU) - float(first["ang"])) < tol:
			(first["pts"] as Array).append_array(last["pts"])
			clusters.pop_back()
	var pts: Array = []
	for cl in clusters:
		var m := Vector2.ZERO
		for p in cl["pts"]:
			m += p
		pts.append(m / (cl["pts"] as Array).size())
	if pts.size() < 3:
		return {}
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	pts = _stable_sort_by(pts, func(p: Vector2) -> float: return atan2(p.y - c.y, p.x - c.x))
	var inset: Array = []
	for p in pts:
		var dx: float = (p as Vector2).x - c.x
		var dz: float = (p as Vector2).y - c.y
		var r := _hyp(dx, dz)
		if r == 0.0:
			r = 1.0
		var k := maxf(0.0, r - inset_in / cos(PI / pts.size())) / r   # inset the edges, not the vertices
		inset.append(Vector2(c.x + dx * k, c.y + dz * k))
	return {"vertices": inset, "center": c, "ring_center": Vector2(float(ex["cx"]), float(ex["cz"]))}


## A stable sort (JS Array.sort is stable; Godot's sort_custom is not).
static func _stable_sort_by(arr: Array, key: Callable) -> Array:
	var idx: Array = []
	for i in arr.size():
		idx.append([float(key.call(arr[i])), i])
	idx.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var out: Array = []
	for e in idx:
		out.append(arr[int(e[1])])
	return out


static func _round(v: float, places: int = 3) -> float:
	var m := pow(10.0, places)
	return roundf(v * m) / m


## The deck (`computeFloorDeck`): a covering record (kind "wall", band
## "floor") resting on the floor beams, or {} when the deck is off or no
## floor beams exist. `beams` must include the floor beams.
static func deck(beams: Array, p: LinkageParams) -> Dictionary:
	var floor := config(p)
	if not bool(floor["enabled"]) or not bool(floor["deck"]["enabled"]) or p.orientation == "vertical":
		return {}
	var fb: Array = []
	for b in beams:
		var st := str(b.get("stack_type", ""))
		if st == "floor-beam" or st == "floor-beam-reciprocal":
			fb.append(b)
	if fb.is_empty():
		return {}
	var poly := floor_polygon(beams, float(floor["deck"]["insetIn"]), p.modules)
	if poly.is_empty():
		return {}
	var t := float(floor["deck"]["thicknessIn"])
	var beams_top := -INF
	for b in fb:
		beams_top = maxf(beams_top, _beam_top_y(b))
	var y_top := beams_top + t
	var y_bot := beams_top
	var top: Array = []
	var bot: Array = []
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for v in poly["vertices"]:
		var q: Vector2 = v
		top.append(Vector3(q.x, y_top, q.y))
		bot.append(Vector3(q.x, y_bot, q.y))
		mn = mn.min(q)
		mx = mx.max(q)
	var corners_2d: Array = []
	for q in top:
		corners_2d.append(Vector2(_round((q as Vector3).x - mn.x, 4), _round((q as Vector3).z - mn.y, 4)))
	var n := top.size()
	var angles: Array = []
	for i in n:
		var pp: Vector3 = top[i]
		var a: Vector3 = top[(i + n - 1) % n]
		var b2: Vector3 = top[(i + 1) % n]
		var v1 := Vector2(a.x - pp.x, a.z - pp.z)
		var v2 := Vector2(b2.x - pp.x, b2.z - pp.z)
		var m := v1.length() * v2.length()
		if m == 0.0:
			m = 1.0
		angles.append(_round(rad_to_deg(acos(clampf(v1.dot(v2) / m, -1.0, 1.0))), 2))
	var area := 0.0
	for i in n:
		var pa: Vector3 = top[i]
		var pb: Vector3 = top[(i + 1) % n]
		area += pa.x * pb.z - pb.x * pa.z
	area = absf(area) / 2.0
	var p0: Vector3 = top[0]
	var p1: Vector3 = top[1]
	return {
		"type": "covering", "kind": "wall", "band": "floor", "cover_type": "plywood",
		"span_index": 0, "module_index": 0, "label": "Floor deck",
		"plane": {"origin": Vector3(mn.x, y_top, mn.y), "n": Vector3.UP, "u": Vector3.RIGHT, "v": Vector3.BACK},
		"normal": Vector3.UP,
		"corners": top,
		"slab_corners": bot + top,
		"center": Vector3((mn.x + mx.x) / 2.0, (y_top + y_bot) / 2.0, (mn.y + mx.y) / 2.0),
		"corners_2d": corners_2d,
		"sides": n,
		"edge_in": _round(Vector2(p1.x - p0.x, p1.z - p0.z).length()),
		"across_in": _round(mx.x - mn.x),
		"width_bottom_in": _round(mx.x - mn.x),
		"width_top_in": _round(mx.y - mn.y),
		"slant_height_in": _round(mx.y - mn.y),
		"vertical_height_in": 0.0,
		"y_bottom": _round(y_bot), "y_top": _round(y_top),
		"tilt_from_vertical_deg": 90.0,
		"corner_angles_deg": angles,
		"area_in2": _round(area, 1),
		"thickness_in": t,
		"mount_offset_in": 0.0,
		"beams_top_in": _round(beams_top),
		"warnings": [],
	}


## Readout (`describeFloorSeating`): per pattern, the beam's bottom face vs
## the leg it rests on.
static func seating(beams: Array, floor_beams_list: Array, num_modules: int) -> Dictionary:
	var ex := extract_frames(beams, num_modules)
	var out := {"ring_top_y": _round(float(ex["ring_top_y"])), "A": null, "B": null, "radial": null}
	var frames: Array = ex["frames"]
	if frames.is_empty():
		return out
	for pat in ["A", "B"]:
		var bs: Array = floor_beams_list.filter(func(b): return str(b.get("stack_type", "")) == "floor-beam-reciprocal" and str(b.get("pattern_id", "")) == pat)
		if bs.is_empty():
			continue
		var leg_top := -INF
		for f in frames:
			leg_top = maxf(leg_top, _beam_top_y(f["beam_a"] if pat == "A" else f["beam_b"]))
		leg_top = _round(leg_top)
		var bottom := INF
		for b in bs:
			bottom = minf(bottom, _beam_bottom_y(b))
		bottom = _round(bottom)
		out[pat] = {"leg_top_y": leg_top, "bottom_y": bottom, "gap_in": _round(bottom - leg_top)}
	var rad: Array = floor_beams_list.filter(func(b): return str(b.get("stack_type", "")) == "floor-beam")
	if not rad.is_empty():
		var bottom2 := INF
		for b in rad:
			bottom2 = minf(bottom2, _beam_bottom_y(b))
		bottom2 = _round(bottom2)
		out["radial"] = {"bottom_y": bottom2, "gap_in": _round(bottom2 - float(ex["ring_top_y"]))}
	return out


## Structure BOM rows for the floor beams (`computeFloorBomContribution`),
## priced like the web (radial beams at the H-beam price, reciprocal at the
## V-beam price); masses metric off LinkageBom.beam_mass_kg.
static func bom_contribution(p: LinkageParams) -> Dictionary:
	var res := {"items": [], "cost": 0.0, "mass_kg": 0.0, "radial": 0, "reciprocal": 0}
	var floor := config(p)
	if not bool(floor["enabled"]) or p.orientation == "vertical":
		return res
	var cfg: Dictionary = floor["beams"]
	var n := p.modules
	if bool(cfg["radialEnabled"]):
		var ft := float(cfg["length"]) / 12.0
		var unit_mass := LinkageBom.beam_mass_kg(float(cfg["width"]), float(cfg["thickness"]), ft)
		(res["items"] as Array).append(LinkageBom._line(n,
			"Floor radial beams (%s)" % LinkageBom.format_beam_spec(ft, float(cfg["width"]), float(cfg["thickness"])),
			float(p.costs["h_beam"]), unit_mass, "structure", "floor_radial"))
		res["radial"] = n
	if bool(cfg["parallelEnabled"]):
		var ft2 := float(cfg["parallelLength"]) / 12.0
		var unit_mass2 := LinkageBom.beam_mass_kg(float(cfg["parallelWidth"]), float(cfg["parallelThickness"]), ft2)
		(res["items"] as Array).append(LinkageBom._line(2 * n,
			"Floor beams, reciprocal (%s)" % LinkageBom.format_beam_spec(ft2, float(cfg["parallelWidth"]), float(cfg["parallelThickness"])),
			float(p.costs["v_beam"]), unit_mass2, "structure", "floor_reciprocal"))
		res["reciprocal"] = 2 * n
	for it in res["items"]:
		res["cost"] = float(res["cost"]) + float(it["total_cost"])
		res["mass_kg"] = float(res["mass_kg"]) + float(it["total_mass_kg"])
	return res
