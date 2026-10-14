class_name LinkageCoverings
extends RefCounted
## Coverings: plywood walls, tables, tensioned fabric (port of
## `js/linkage/coverings-geometry.js`, A4).
##
## Turns the solved beams of a cylinder-mode ring into per-span covering
## shapes.
##   upright  one vertical X-scissor stack (stack type `vertical`, one per
##            module), lying in a near-radial vertical plane on the edge shared
##            by module i and module i+1.
##   span     the perimeter gap between two neighbouring uprights. Span j is
##            module j's wedge: left upright = j-1, right upright = j.
##   band     `lower` (bottom → split height) or `upper` (split height → the
##            top ring's underside − clearance). Each is none / plywood / fabric.
##   table    a horizontal slab on the lower band's top edge, reaching inward.
##
## The inward-leaning (pattern B) beams of two neighbouring uprights, extended,
## meet on the ring axis by rotational symmetry, so one flat plane holds both:
## that is the default wall plane ("inward" lean). Beam layers are offset
## tangentially, so the coplanar object is the pivot-to-pivot pattern line in
## each stack's mid-plane; the beams are projected onto it.
##
## Pure. Config `coverings` rides `LinkageParams.extra` (camelCase); shapes
## are covering records in snake_case (kind wall / fabric / table).

const COVER_TYPES := ["none", "plywood", "fabric"]
const LEAN_MODES := ["inward", "outward", "vertical", "custom"]
const MOUNT_MODES := ["outside", "centerline", "inside"]
const SHEET_PRESETS := {
	"4x8": {"widthIn": 48.0, "lengthIn": 96.0},
	"5x5": {"widthIn": 60.0, "lengthIn": 60.0},
	"4x10": {"widthIn": 48.0, "lengthIn": 120.0},
}
## The ring closes when the last→first upright gap is within this of the mean.
const CLOSURE_TOLERANCE_DEG := 1.0
const MAX_TILT_DEG := 360.0
const OFF_MAX := 1200.0
const LEN_MIN := 0.05
const LEN_MAX := 2400.0
const SECTION_MIN := 0.05
const SECTION_MAX := 48.0
## Warn when the four guide-line ends miss the fitted plane by more than this.
const PLANARITY_WARN_IN := 0.25
const FABRIC_THICK_IN := 0.1

const DEFAULTS := {
	"enabled": false,
	"lowerLean": "inward", "lowerTiltDeg": 0.0,
	"upperLean": "outward", "upperTiltDeg": 0.0,
	"splitHeightIn": 48.0, "bottomIn": 0.0, "bottomMode": "ground",
	"topClearanceIn": 1.0, "edgeGapIn": 0.25, "mount": "outside",
	"sheet": {"widthIn": 48.0, "lengthIn": 96.0, "thicknessIn": 0.5, "orientation": "auto", "align": "center", "kerfIn": 0.125},
	"fabric": {"rollWidthIn": 60.0, "hemIn": 1.0, "seamIn": 0.5, "stretchPct": 2.0, "grommetSpacingIn": 12.0},
	"table": {"depthIn": 24.0, "thicknessIn": 0.75, "slideIn": 0.0, "heightOffsetIn": 0.0},
	"spans": [],
	"visibility": {"walls": true, "fabric": true, "tables": true},
	"showDimensions": false,
}


static func _num(v, def: float) -> float:
	return float(v) if (v is float or v is int) and is_finite(float(v)) else def


static func _clampn(v, def: float, lo: float, hi: float) -> float:
	return clampf(_num(v, def), lo, hi)


static func _pick(v, allowed: Array, def: String) -> String:
	return v if v is String and allowed.has(v) else def


static func default_span() -> Dictionary:
	return {"lower": "none", "upper": "none", "table": false}


static func _norm_span(raw) -> Dictionary:
	var s: Dictionary = raw if raw is Dictionary else {}
	return {"lower": _pick(s.get("lower"), COVER_TYPES, "none"),
		"upper": _pick(s.get("upper"), COVER_TYPES, "none"), "table": bool(s.get("table", false))}


## `normalizeCoverings` (legacy single `lean` / `customTiltDeg` = the lower
## band). `n` >= 0 resizes the per-span list.
static func normalize(raw, n: int = -1) -> Dictionary:
	var d: Dictionary = DEFAULTS
	var r: Dictionary = raw if raw is Dictionary else {}
	var sheet: Dictionary = r.get("sheet", {}) if r.get("sheet") is Dictionary else {}
	var fabric: Dictionary = r.get("fabric", {}) if r.get("fabric") is Dictionary else {}
	var table: Dictionary = r.get("table", {}) if r.get("table") is Dictionary else {}
	var vis: Dictionary = r.get("visibility", {}) if r.get("visibility") is Dictionary else {}
	var spans: Array = []
	if r.get("spans") is Array:
		for sp in r["spans"]:
			spans.append(_norm_span(sp))
	var ds: Dictionary = d["sheet"]
	var df: Dictionary = d["fabric"]
	var dt: Dictionary = d["table"]
	var cov := {
		"enabled": bool(r.get("enabled", false)),
		"lowerLean": _pick(r.get("lowerLean", r.get("lean")), LEAN_MODES, str(d["lowerLean"])),
		"lowerTiltDeg": _clampn(r.get("lowerTiltDeg", r.get("customTiltDeg")), d["lowerTiltDeg"], -MAX_TILT_DEG, MAX_TILT_DEG),
		"upperLean": _pick(r.get("upperLean"), LEAN_MODES, str(d["upperLean"])),
		"upperTiltDeg": _clampn(r.get("upperTiltDeg"), d["upperTiltDeg"], -MAX_TILT_DEG, MAX_TILT_DEG),
		"splitHeightIn": _clampn(r.get("splitHeightIn"), d["splitHeightIn"], -OFF_MAX, OFF_MAX),
		"bottomIn": _clampn(r.get("bottomIn"), d["bottomIn"], -OFF_MAX, OFF_MAX),
		"bottomMode": "floor" if str(r.get("bottomMode", "")) == "floor" else "ground",
		"topClearanceIn": _clampn(r.get("topClearanceIn"), d["topClearanceIn"], -OFF_MAX, OFF_MAX),
		"edgeGapIn": _clampn(r.get("edgeGapIn"), d["edgeGapIn"], -OFF_MAX, OFF_MAX),
		"mount": _pick(r.get("mount"), MOUNT_MODES, str(d["mount"])),
		"sheet": {
			"widthIn": _clampn(sheet.get("widthIn"), ds["widthIn"], LEN_MIN, LEN_MAX),
			"lengthIn": _clampn(sheet.get("lengthIn"), ds["lengthIn"], LEN_MIN, LEN_MAX),
			"thicknessIn": _clampn(sheet.get("thicknessIn"), ds["thicknessIn"], SECTION_MIN, SECTION_MAX),
			"orientation": _pick(sheet.get("orientation"), ["auto", "landscape", "portrait"], str(ds["orientation"])),
			"align": _pick(sheet.get("align"), ["center", "left"], str(ds["align"])),
			"kerfIn": _clampn(sheet.get("kerfIn"), ds["kerfIn"], 0.0, SECTION_MAX),
		},
		"fabric": {
			"rollWidthIn": _clampn(fabric.get("rollWidthIn"), df["rollWidthIn"], LEN_MIN, LEN_MAX),
			"hemIn": _clampn(fabric.get("hemIn"), df["hemIn"], 0.0, LEN_MAX),
			"seamIn": _clampn(fabric.get("seamIn"), df["seamIn"], 0.0, LEN_MAX),
			"stretchPct": _clampn(fabric.get("stretchPct"), df["stretchPct"], -50.0, 90.0),
			"grommetSpacingIn": _clampn(fabric.get("grommetSpacingIn"), df["grommetSpacingIn"], 0.5, LEN_MAX),
		},
		"table": {
			"depthIn": _clampn(table.get("depthIn"), dt["depthIn"], LEN_MIN, LEN_MAX),
			"thicknessIn": _clampn(table.get("thicknessIn"), dt["thicknessIn"], SECTION_MIN, SECTION_MAX),
			"slideIn": _clampn(table.get("slideIn"), dt["slideIn"], -OFF_MAX, OFF_MAX),
			"heightOffsetIn": _clampn(table.get("heightOffsetIn"), dt["heightOffsetIn"], -OFF_MAX, OFF_MAX),
		},
		"spans": spans,
		"visibility": {"walls": vis.get("walls", true) != false, "fabric": vis.get("fabric", true) != false,
			"tables": vis.get("tables", true) != false},
		"showDimensions": bool(r.get("showDimensions", false)),
	}
	if n >= 0:
		resize_spans(cov, n)
	return cov


static func resize_spans(cov: Dictionary, n: int) -> void:
	var spans: Array = (cov.get("spans", []) as Array).slice(0, maxi(0, n))
	while spans.size() < n:
		spans.append(default_span())
	cov["spans"] = spans


static func config(p: LinkageParams) -> Dictionary:
	return normalize(p.extra.get("coverings"), p.modules)


static func set_config(p: LinkageParams, cfg: Dictionary) -> void:
	p.extra["coverings"] = normalize(cfg, p.modules)


# ---------------------------------------------------------------------------
# Small geometry helpers
# ---------------------------------------------------------------------------

## Least-squares (Kasa) circle fit in XZ: {x, z, r} or {}.
static func fit_circle_xz(points: Array) -> Dictionary:
	if points.size() < 3:
		return {}
	var sxx := 0.0
	var sxz := 0.0
	var szz := 0.0
	var sx := 0.0
	var sz := 0.0
	var sxr := 0.0
	var szr := 0.0
	var sr := 0.0
	for p in points:
		var q: Vector3 = p
		var r2 := q.x * q.x + q.z * q.z
		sxx += q.x * q.x
		sxz += q.x * q.z
		szz += q.z * q.z
		sx += q.x
		sz += q.z
		sxr += q.x * r2
		szr += q.z * r2
		sr += r2
	var sol := _solve3([[sxx, sxz, sx], [sxz, szz, sz], [sx, sz, float(points.size())]], [-sxr, -szr, -sr])
	if sol.is_empty():
		return {}
	var cx := -float(sol[0]) / 2.0
	var cz := -float(sol[1]) / 2.0
	var r2c := cx * cx + cz * cz - float(sol[2])
	if not (r2c > 0.0):
		return {}
	return {"x": cx, "z": cz, "r": sqrt(r2c)}


static func _solve3(m: Array, r: Array) -> Array:
	var a: float = m[0][0]
	var b: float = m[0][1]
	var c: float = m[0][2]
	var d: float = m[1][0]
	var e: float = m[1][1]
	var f: float = m[1][2]
	var g: float = m[2][0]
	var h: float = m[2][1]
	var i: float = m[2][2]
	var det := a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	if absf(det) < 1e-12:
		return []
	var inv := [
		[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
		[(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
		[(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det],
	]
	var out: Array = []
	for row in inv:
		out.append(float(row[0]) * float(r[0]) + float(row[1]) * float(r[1]) + float(row[2]) * float(r[2]))
	return out


## Degrees into (-180, 180].
static func wrap_deg(a: float) -> float:
	var d := fmod(fmod(a + 180.0, 360.0) + 360.0, 360.0) - 180.0
	return 180.0 if d == -180.0 else d


## 2D lines p + s·d in XZ (y carried from p1), or null when parallel.
static func _line_line_xz(p1: Vector3, d1: Vector3, p2: Vector3, d2: Vector3):
	var den := d1.x * d2.z - d1.z * d2.x
	if absf(den) < 1e-12:
		return null
	var s := ((p2.x - p1.x) * d2.z - (p2.z - p1.z) * d2.x) / den
	return Vector3(p1.x + d1.x * s, p1.y, p1.z + d1.z * s)


static func _interior_angle_deg(a: Vector2, b: Vector2, c: Vector2) -> float:
	var v1 := a - b
	var v2 := c - b
	var m := v1.length() * v2.length()
	if m == 0.0:
		m = 1.0
	return rad_to_deg(acos(clampf(v1.dot(v2) / m, -1.0, 1.0)))


static func _area_2d(pts: Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) / 2.0


static func _r(v: float, places: int = 3) -> float:
	return LinkageSheetNesting.rnd(v, places)


# ---------------------------------------------------------------------------
# Uprights
# ---------------------------------------------------------------------------

## One upright per vertical X-stack (`collectUprights`), sorted by module (cap last).
static func collect_uprights(beams: Array, vert_end_offset: float) -> Array:
	var groups := {}
	var order: Array = []
	for b in beams:
		var st := str(b.get("stack_type", ""))
		if st != "vertical" and st != "vertical-cap":
			continue
		var key := "%s:%d" % [st, int(b.get("stack_id", -1))]
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		(groups[key] as Array).append(b)
	var uprights: Array = []
	for key in order:
		var bs: Array = groups[key]
		var la: Array = bs.filter(func(b): return str(b.get("pattern_id", "")) == "A")
		var lb: Array = bs.filter(func(b): return str(b.get("pattern_id", "")) == "B")
		if la.is_empty() or lb.is_empty():
			continue
		var dir_a := (_top_of(la[0]) - _bot_of(la[0])).normalized()
		var dir_b := (_top_of(lb[0]) - _bot_of(lb[0])).normalized()
		var normal := dir_a.cross(dir_b)
		if normal.length() < 1e-3:
			normal = (dir_a + dir_b).normalized().cross(Vector3.UP)
		normal = normal.normalized()
		if normal.y < 0.0:
			normal = -normal
		var center := Vector3.ZERO
		for b in bs:
			center += b["center"] as Vector3
		center /= bs.size()
		var half := 0.0
		for b in bs:
			half = maxf(half, absf(((b["center"] as Vector3) - center).dot(normal)) + _num(b.get("w"), 0.0) / 2.0)
		var first: Dictionary = bs[0]
		uprights.append({
			"index": -1, "module_index": int(first.get("module_index", -1)),
			"stack_id": int(first.get("stack_id", -1)), "stack_type": str(first["stack_type"]),
			"is_cap": str(first["stack_type"]) == "vertical-cap",
			"center": center, "normal": normal, "half_width_in": half, "azimuth_deg": 0.0,
			"A": _line_from(la, center, normal, vert_end_offset),
			"B": _line_from(lb, center, normal, vert_end_offset),
			"beams": bs,
		})
	uprights = _stable_sort(uprights, func(a, b):
		if bool(a["is_cap"]) != bool(b["is_cap"]):
			return not bool(a["is_cap"])
		if int(a["module_index"]) != int(b["module_index"]):
			return int(a["module_index"]) < int(b["module_index"])
		return int(a["stack_id"]) < int(b["stack_id"]))
	for i in uprights.size():
		uprights[i]["index"] = i
	return uprights


static func _bot_of(b: Dictionary) -> Vector3:
	return b["p1"] if (b["p1"] as Vector3).y <= (b["p2"] as Vector3).y else b["p2"]


static func _top_of(b: Dictionary) -> Vector3:
	return b["p2"] if (b["p1"] as Vector3).y <= (b["p2"] as Vector3).y else b["p1"]


static func _line_from(lst: Array, center: Vector3, normal: Vector3, end_off: float) -> Dictionary:
	var bot := Vector3.ZERO
	var top := Vector3.ZERO
	for b in lst:
		var ob := _bot_of(b)
		var ot := _top_of(b)
		bot += ob - normal * (ob - center).dot(normal)
		top += ot - normal * (ot - center).dot(normal)
	bot /= lst.size()
	top /= lst.size()
	var dir := (top - bot).normalized()
	return {"bot": bot, "top": top, "dir": dir, "pivot_bot": bot + dir * end_off, "pivot_top": top - dir * end_off}


## A stable sort with a "less" callable (JS sort is stable; Godot's is not).
static func _stable_sort(arr: Array, less: Callable) -> Array:
	var idx: Array = []
	for i in arr.size():
		idx.append([arr[i], i])
	idx.sort_custom(func(a, b):
		if less.call(a[0], b[0]):
			return true
		if less.call(b[0], a[0]):
			return false
		return a[1] < b[1])
	var out: Array = []
	for e in idx:
		out.append(e[0])
	return out


# ---------------------------------------------------------------------------
# Spans
# ---------------------------------------------------------------------------

## Pairs neighbouring uprights into spans (`collectSpans`) and decides
## whether the ring closes.
static func collect_spans(uprights: Array, ring_center_hint: Vector2) -> Dictionary:
	var regular: Array = uprights.filter(func(u): return not bool(u["is_cap"]))
	var cap = null
	for u in uprights:
		if bool(u["is_cap"]):
			cap = u
			break
	var n := regular.size()
	var pts: Array = []
	for u in regular:
		pts.append(u["B"]["pivot_bot"])
	var fit := fit_circle_xz(pts)
	var rc := Vector2(float(fit["x"]), float(fit["z"])) if not fit.is_empty() else ring_center_hint
	for u in uprights:
		var pb: Vector3 = u["B"]["pivot_bot"]
		u["azimuth_deg"] = rad_to_deg(atan2(pb.z - rc.y, pb.x - rc.x))
	var closed := false
	var closure_err := NAN
	var mean_gap := 0.0
	if n >= 3:
		var gaps := 0.0
		for i in range(1, n):
			gaps += wrap_deg(float(regular[i]["azimuth_deg"]) - float(regular[i - 1]["azimuth_deg"]))
		mean_gap = gaps / (n - 1)
		var closing_gap := wrap_deg(float(regular[0]["azimuth_deg"]) - float(regular[n - 1]["azimuth_deg"]))
		closure_err = absf(closing_gap - mean_gap)
		closed = closure_err < CLOSURE_TOLERANCE_DEG
	var spans: Array = []
	for j in n:
		var right: Dictionary = regular[j]
		var left = null
		var closing := false
		if j > 0:
			left = regular[j - 1]
		elif closed:
			left = regular[n - 1]
			closing = true
		elif cap != null:
			left = cap
		if left == null:
			continue
		var al := float(left["azimuth_deg"])
		var ar := float(right["azimuth_deg"])
		spans.append({
			"index": j, "module_index": int(right["module_index"]),
			"left": int(left["index"]), "right": int(right["index"]), "closing": closing,
			"azimuth_left_deg": al, "azimuth_right_deg": ar, "azimuth_deg": al + wrap_deg(ar - al) / 2.0,
			"chord_bottom_in": ((right["B"]["pivot_bot"] as Vector3) - (left["B"]["pivot_bot"] as Vector3)).length(),
		})
	return {"spans": spans, "closed": closed, "closure_error_deg": closure_err, "ring_center": rc, "mean_gap_deg": mean_gap}


# ---------------------------------------------------------------------------
# Wall plane per span
# ---------------------------------------------------------------------------

## The covering plane for a span (`solveSpanPlane`), or {} when degenerate.
static func solve_span_plane(lu: Dictionary, ru: Dictionary, lean: String, custom_tilt_deg: float, rc: Vector2) -> Dictionary:
	var warnings: Array = []
	var l_l: Dictionary = lu["A"] if lean == "outward" else lu["B"]
	var l_r: Dictionary = ru["A"] if lean == "outward" else ru["B"]
	var origin: Vector3
	var n: Vector3
	var planarity := 0.0
	var guide = null
	var u0 := ((l_r["pivot_bot"] as Vector3) - (l_l["pivot_bot"] as Vector3)).normalized()
	if lean == "inward" or lean == "outward":
		guide = "A" if lean == "outward" else "B"
		var pts := [l_l["pivot_bot"], l_l["pivot_top"], l_r["pivot_bot"], l_r["pivot_top"]]
		origin = Vector3.ZERO
		for q in pts:
			origin += q
		origin *= 0.25
		var w := ((l_l["dir"] as Vector3) + (l_r["dir"] as Vector3)).normalized()
		n = u0.cross(w).normalized()
		if n.dot(Vector3(origin.x - rc.x, 0.0, origin.z - rc.y)) < 0.0:
			n = -n
		for q in pts:
			planarity = maxf(planarity, absf(((q as Vector3) - origin).dot(n)))
		if planarity > PLANARITY_WARN_IN:
			warnings.append({"code": "non-planar",
				"message": "Guide beams are not coplanar (off by %.2f in); using a best-fit plane." % planarity})
	else:
		origin = ((l_l["pivot_bot"] as Vector3) + (l_r["pivot_bot"] as Vector3)) * 0.5
		var nh := Vector3.UP.cross(u0).normalized()
		if nh.dot(Vector3(origin.x - rc.x, 0.0, origin.z - rc.y)) < 0.0:
			nh = -nh
		if lean == "custom":
			var tau := deg_to_rad(custom_tilt_deg)
			n = (nh * cos(tau) + Vector3.UP * sin(tau)).normalized()
		else:
			n = nh
	if not is_finite(n.x) or n.length() < 0.5:
		return {}
	var u := Vector3.UP.cross(n).normalized()
	if u.length() < 1e-6:
		return {}
	if u.dot(u0) < 0.0:
		u = -u
	var v := n.cross(u)
	if v.y < 0.0:
		v = -v
	var tilt := rad_to_deg(asin(clampf(n.y, -1.0, 1.0)))
	if absf(tilt) > MAX_TILT_DEG:
		warnings.append({"code": "too-flat", "message": "Wall plane is tilted %.0f° from vertical; span skipped." % tilt})
		return {"plane": {}, "planarity_error_in": planarity, "tilt_from_vertical_deg": tilt, "guide": guide, "warnings": warnings}
	return {"plane": {"origin": origin, "n": n, "u": u, "v": v}, "planarity_error_in": planarity,
		"tilt_from_vertical_deg": tilt, "guide": guide, "warnings": warnings}


## Plane ∩ plane → {p, dir} (dir.y > 0), or {} when (nearly) parallel.
static func _plane_plane_line(n1: Vector3, d1: float, n2: Vector3, d2: float) -> Dictionary:
	var dot := n1.dot(n2)
	var den := 1.0 - dot * dot
	if den < 1e-4:
		return {}
	var dir := n1.cross(n2).normalized()
	if dir.y < 0.0:
		dir = -dir
	return {"p": (n1 * (d1 - d2 * dot) + n2 * (d2 - d1 * dot)) / den, "dir": dir}


## The covering's side edge (`sideLineFor`): wall plane ∩ the upright's side
## face, as s(t) = s0 + (t − t0)·slope in plane coordinates.
static func _side_line_for(plane: Dictionary, upright: Dictionary, span_mid: Vector3, edge_gap: float) -> Dictionary:
	var un: Vector3 = upright["normal"]
	var uc: Vector3 = upright["center"]
	var sigma := 1.0 if (span_mid - uc).dot(un) >= 0.0 else -1.0
	var q := uc + un * sigma * (float(upright["half_width_in"]) + edge_gap)
	var pn: Vector3 = plane["n"]
	var po: Vector3 = plane["origin"]
	var line := _plane_plane_line(pn, pn.dot(po), un, un.dot(q))
	if line.is_empty():
		return {}
	var rel := (line["p"] as Vector3) - po
	var s0 := rel.dot(plane["u"])
	var t0 := rel.dot(plane["v"])
	var ds := (line["dir"] as Vector3).dot(plane["u"])
	var dt := (line["dir"] as Vector3).dot(plane["v"])
	if absf(dt) < 1e-6:
		return {}
	return {"s0": s0, "t0": t0, "slope": ds / dt, "line_3d": line}


# ---------------------------------------------------------------------------
# Shapes
# ---------------------------------------------------------------------------

## The trapezoid for one band of one span (`buildBandShape`), or {}.
static func build_band_shape(ctx: Dictionary, y_bottom: float, y_top: float, thickness_in: float) -> Dictionary:
	var plane: Dictionary = ctx.get("plane", {})
	var side_l: Dictionary = ctx.get("side_l", {})
	var side_r: Dictionary = ctx.get("side_r", {})
	if plane.is_empty() or side_l.is_empty() or side_r.is_empty() or not (y_top > y_bottom):
		return {}
	var pv: Vector3 = plane["v"]
	var po: Vector3 = plane["origin"]
	if absf(pv.y) < 1e-6:
		return {}
	var t_bot := (y_bottom - po.y) / pv.y
	var t_top := (y_top - po.y) / pv.y
	var s_at := func(side: Dictionary, t: float) -> float:
		return float(side["s0"]) + (t - float(side["t0"])) * float(side["slope"])
	var raw := [Vector2(s_at.call(side_l, t_bot), t_bot), Vector2(s_at.call(side_r, t_bot), t_bot),
		Vector2(s_at.call(side_r, t_top), t_top), Vector2(s_at.call(side_l, t_top), t_top)]
	if not ((raw[1] as Vector2).x > (raw[0] as Vector2).x) or not ((raw[2] as Vector2).x > (raw[3] as Vector2).x):
		return {}
	var mount := float(ctx.get("mount_offset_in", 0.0))
	var to3 := func(q: Vector2, d: float) -> Vector3:
		return po + (plane["u"] as Vector3) * q.x + pv * q.y + (plane["n"] as Vector3) * d
	var corners: Array = []
	var lo: Array = []
	var hi: Array = []
	var half := thickness_in / 2.0
	for q in raw:
		corners.append(to3.call(q, mount))
		lo.append(to3.call(q, mount - half))
		hi.append(to3.call(q, mount + half))
	var center := Vector3.ZERO
	for c in corners:
		center += c
	center *= 0.25
	var s0 := (raw[0] as Vector2).x
	var c2: Array = []
	for q in raw:
		c2.append(Vector2(_r((q as Vector2).x - s0, 4), _r((q as Vector2).y - t_bot, 4)))
	var slant := t_top - t_bot
	var angles: Array = []
	for i in 4:
		angles.append(_r(_interior_angle_deg(c2[(i + 3) % 4], c2[i], c2[(i + 1) % 4]), 2))
	return {
		"type": "covering", "plane": plane, "corners": corners, "slab_corners": lo + hi,
		"center": center, "normal": plane["n"], "corners_2d": c2,
		"width_bottom_in": _r((raw[1] as Vector2).x - (raw[0] as Vector2).x),
		"width_top_in": _r((raw[2] as Vector2).x - (raw[3] as Vector2).x),
		"slant_height_in": _r(slant), "vertical_height_in": _r(y_top - y_bottom),
		"y_bottom": _r(y_bottom), "y_top": _r(y_top),
		"tilt_from_vertical_deg": _r(float(ctx.get("tilt_from_vertical_deg", 0.0)), 2),
		"side_taper_deg": {
			"left": _r(rad_to_deg(atan2((raw[3] as Vector2).x - (raw[0] as Vector2).x, slant)), 2),
			"right": _r(rad_to_deg(atan2((raw[1] as Vector2).x - (raw[2] as Vector2).x, slant)), 2)},
		"corner_angles_deg": angles, "area_in2": _r(_area_2d(c2), 1),
		"thickness_in": thickness_in, "mount_offset_in": _r(mount), "warnings": [],
	}


## A horizontal table slab on the lower band's top edge (`buildTableShape`), or {}.
static func build_table_shape(ctx: Dictionary) -> Dictionary:
	var plane: Dictionary = ctx.get("plane", {})
	if plane.is_empty():
		return {}
	var lu: Dictionary = ctx["L"]
	var ru: Dictionary = ctx["R"]
	var y_surface := float(ctx["y_surface"])
	var pv: Vector3 = plane["v"]
	var po: Vector3 = plane["origin"]
	var pn: Vector3 = plane["n"]
	if absf(pv.y) < 1e-6:
		return {}
	# Outer line: the wall's inner face ∩ y = y_surface (direction u is horizontal).
	var o_wall := po + pn * float(ctx["wall_inner_offset_in"]) + pv * ((y_surface - po.y) / pv.y)
	var outer_dir: Vector3 = plane["u"]
	var nh := Vector3(pn.x, 0.0, pn.z)
	if nh.length() < 1e-6:
		return {}
	var inward := -nh / nh.length()
	var slide := float(ctx.get("slide_in", 0.0))
	var o := o_wall + inward * slide if slide != 0.0 else o_wall
	var depth := float(ctx["depth_in"])
	var inner_point := o + inward * depth
	var span_mid := ((lu["B"]["pivot_bot"] as Vector3) + (ru["B"]["pivot_bot"] as Vector3)) * 0.5
	var edge_gap := float(ctx["edge_gap_in"])
	var side_at := func(uu: Dictionary) -> Dictionary:
		var un: Vector3 = uu["normal"]
		var uc: Vector3 = uu["center"]
		var sigma := 1.0 if (span_mid - uc).dot(un) >= 0.0 else -1.0
		var ref := uc + un * sigma * (float(uu["half_width_in"]) + edge_gap)
		var q := Vector3(ref.x, y_surface, ref.z)
		q = q - un * (q - ref).dot(un)
		var d := Vector3.UP.cross(un)
		if d.length() < 1e-6:
			return {}
		return {"p": q, "d": d.normalized()}
	var s_l: Dictionary = side_at.call(lu)
	var s_r: Dictionary = side_at.call(ru)
	if s_l.is_empty() or s_r.is_empty():
		return {}
	var outer_l = _line_line_xz(o, outer_dir, s_l["p"], s_l["d"])
	var outer_r = _line_line_xz(o, outer_dir, s_r["p"], s_r["d"])
	var inner_r = _line_line_xz(inner_point, outer_dir, s_r["p"], s_r["d"])
	var inner_l = _line_line_xz(inner_point, outer_dir, s_l["p"], s_l["d"])
	if outer_l == null or outer_r == null or inner_r == null or inner_l == null:
		return {}
	var corners: Array = []
	for q in [outer_l, outer_r, inner_r, inner_l]:
		corners.append(Vector3((q as Vector3).x, y_surface, (q as Vector3).z))
	var c2: Array = []
	for q in corners:
		var rel := (q as Vector3) - (corners[0] as Vector3)
		c2.append(Vector2(_r(rel.dot(outer_dir), 4), _r(rel.dot(inward), 4)))
	var w_outer := ((corners[1] as Vector3) - (corners[0] as Vector3)).length()
	var w_inner := ((corners[2] as Vector3) - (corners[3] as Vector3)).length()
	if not (w_outer > 0.5) or not (w_inner > 0.0):
		return {}
	var t := float(ctx["thickness_in"])
	var down: Array = []
	for q in corners:
		down.append((q as Vector3) - Vector3(0.0, t, 0.0))
	var center := Vector3.ZERO
	for q in corners:
		center += q
	center *= 0.25
	center.y -= t / 2.0
	var angles: Array = []
	for i in 4:
		angles.append(_r(_interior_angle_deg(c2[(i + 3) % 4], c2[i], c2[(i + 1) % 4]), 2))
	return {
		"type": "covering",
		"plane": {"origin": corners[0], "n": Vector3.UP, "u": outer_dir, "v": inward},
		"corners": corners, "slab_corners": down + corners, "center": center, "normal": Vector3.UP,
		"corners_2d": c2, "width_bottom_in": _r(w_outer), "width_top_in": _r(w_inner),
		"width_outer_in": _r(w_outer), "width_inner_in": _r(w_inner),
		"slant_height_in": _r(depth), "depth_in": _r(depth), "vertical_height_in": 0.0,
		"y_bottom": _r(y_surface - t), "y_top": _r(y_surface), "tilt_from_vertical_deg": 90.0,
		"side_taper_deg": {
			"left": _r(rad_to_deg(atan2((c2[3] as Vector2).x - (c2[0] as Vector2).x, depth)), 2),
			"right": _r(rad_to_deg(atan2((c2[1] as Vector2).x - (c2[2] as Vector2).x, depth)), 2)},
		"corner_angles_deg": angles, "area_in2": _r(_area_2d(c2), 1),
		"thickness_in": t, "mount_offset_in": 0.0, "warnings": [],
	}


# ---------------------------------------------------------------------------
# Main entry
# ---------------------------------------------------------------------------

static func _empty_totals() -> Dictionary:
	return {"plywood_walls": 0, "fabric_bands": 0, "tables": 0, "plywood_area_in2": 0.0,
		"fabric_area_in2": 0.0, "table_area_in2": 0.0, "spans_covered": 0}


static func _unsupported(reason: String, cov: Dictionary) -> Dictionary:
	return {"enabled": bool(cov.get("enabled", false)), "supported": false, "unsupported_reason": reason,
		"closed": false, "uprights": [], "spans": [], "shapes": [], "pick_quads": [], "warnings": [],
		"totals": _empty_totals()}


## Every covering shape for one structure (`computeCoverings`). `beams` = the
## solved frame's beams; `floor_top_y` = the deck's top (NAN = no deck), used
## when bottomMode is "floor".
static func compute(beams: Array, p: LinkageParams, floor_top_y: float = NAN) -> Dictionary:
	var c := config(p)
	if p.orientation == "vertical":
		return _unsupported("arch", c)
	if p.use_fixed_beams:
		return _unsupported("fixed-beams", c)
	var uprights := collect_uprights(beams, p.vert_end_offset)
	if uprights.filter(func(u): return not bool(u["is_cap"])).size() < 2:
		return _unsupported("no-uprights", c)
	var sp := collect_spans(uprights, Vector2.ZERO)
	var spans: Array = sp["spans"]
	var rc: Vector2 = sp["ring_center"]
	# Ring reference heights from the horizontal scissors.
	var ring_top := -INF
	var ring_under := INF
	var h_beams: Array = []
	for b in beams:
		var st := str(b.get("stack_type", ""))
		if not st.begins_with("horizontal"):
			continue
		h_beams.append(b)
		var cs: Array = b.get("corners", []) if not (b.get("corners", []) as Array).is_empty() else [b["p1"], b["p2"]]
		for q in cs:
			if st == "horizontal-bottom":
				ring_top = maxf(ring_top, (q as Vector3).y)
			if st == "horizontal-top":
				ring_under = minf(ring_under, (q as Vector3).y)
	if not is_finite(ring_top):
		ring_top = 0.0
	if not is_finite(ring_under):
		ring_under = -INF
		for u in uprights:
			ring_under = maxf(ring_under, maxf((u["A"]["top"] as Vector3).y, (u["B"]["top"] as Vector3).y))
	var warnings: Array = []
	var shapes: Array = []
	var pick_quads: Array = []
	var totals := _empty_totals()
	var sheet_thick := float(c["sheet"]["thicknessIn"])
	var on_floor := str(c["bottomMode"]) == "floor" and is_finite(floor_top_y)
	var bottom_in := (floor_top_y if on_floor else 0.0) + float(c["bottomIn"])
	var upper_top := ring_under - float(c["topClearanceIn"])
	var split_in := maxf(bottom_in + 1.0, minf(float(c["splitHeightIn"]), upper_top - 1.0))
	var table_y := split_in + float(c["table"]["heightOffsetIn"])
	var lean_of := func(band: String) -> String:
		return str(c["upperLean"] if band == "upper" else c["lowerLean"])
	var tilt_of := func(band: String) -> float:
		return float(c["upperTiltDeg"] if band == "upper" else c["lowerTiltDeg"])
	var same_bands: bool = lean_of.call("lower") == lean_of.call("upper") and tilt_of.call("lower") == tilt_of.call("upper")
	var edge_gap := float(c["edgeGapIn"])
	var solve_band := func(span: Dictionary, lu: Dictionary, ru: Dictionary, lean: String, tilt_deg: float) -> Dictionary:
		var solved := solve_span_plane(lu, ru, lean, tilt_deg, rc)
		var out := {"plane": solved.get("plane", {}) if not solved.is_empty() else {},
			"planarity_error_in": _r(float(solved["planarity_error_in"])) if not solved.is_empty() else null,
			"tilt_from_vertical_deg": _r(float(solved["tilt_from_vertical_deg"]), 2) if not solved.is_empty() else null,
			"guide": solved.get("guide") if not solved.is_empty() else null, "lean": lean,
			"side_l": {}, "side_r": {}, "face_outside_in": 0.0, "face_inside_in": 0.0, "dihedral_to_next_deg": null}
		if not solved.is_empty():
			for w in solved["warnings"]:
				var ww: Dictionary = (w as Dictionary).duplicate()
				ww["span_index"] = int(span["index"])
				ww["band"] = null
				warnings.append(ww)
		if (out["plane"] as Dictionary).is_empty():
			return out
		var span_mid := ((lu["B"]["pivot_bot"] as Vector3) + (ru["B"]["pivot_bot"] as Vector3)) * 0.5
		out["side_l"] = _side_line_for(out["plane"], lu, span_mid, edge_gap)
		out["side_r"] = _side_line_for(out["plane"], ru, span_mid, edge_gap)
		if (out["side_l"] as Dictionary).is_empty() or (out["side_r"] as Dictionary).is_empty():
			warnings.append({"span_index": int(span["index"]), "band": null, "code": "side-parallel",
				"message": "Wall plane is parallel to an upright; span skipped."})
			out["plane"] = {}
			return out
		# Mount offset from the guide beams' physical faces.
		var guide_pat := "A" if lean == "outward" else "B"
		var d_max := -INF
		var d_min := INF
		var pl: Dictionary = out["plane"]
		for uu in [lu, ru]:
			for b in uu["beams"]:
				if str(b.get("pattern_id", "")) != guide_pat:
					continue
				for q in b.get("corners", []):
					var d := ((q as Vector3) - (pl["origin"] as Vector3)).dot(pl["n"])
					d_max = maxf(d_max, d)
					d_min = minf(d_min, d)
		if not is_finite(d_max):
			d_max = 0.0
			d_min = 0.0
		out["face_outside_in"] = _r(d_max)
		out["face_inside_in"] = _r(d_min)
		return out
	# Pass 1: planes and side lines, per band.
	for span in spans:
		var lu: Dictionary = uprights[int(span["left"])]
		var ru: Dictionary = uprights[int(span["right"])]
		var bands := {}
		bands["lower"] = solve_band.call(span, lu, ru, lean_of.call("lower"), tilt_of.call("lower"))
		bands["upper"] = bands["lower"] if same_bands else solve_band.call(span, lu, ru, lean_of.call("upper"), tilt_of.call("upper"))
		span["bands"] = bands
		var lb: Dictionary = bands["lower"]
		span["plane"] = lb["plane"]
		span["side_l"] = lb["side_l"]
		span["side_r"] = lb["side_r"]
		span["tilt_from_vertical_deg"] = lb["tilt_from_vertical_deg"]
	# Dihedral to the next span, per band.
	var by_index := {}
	for s in spans:
		by_index[int(s["index"])] = s
	var n_up := uprights.filter(func(u): return not bool(u["is_cap"])).size()
	for span in spans:
		var nxt = by_index.get((int(span["index"]) + 1) % n_up)
		for band in ["lower", "upper"]:
			var a: Dictionary = span["bands"][band]
			var b = nxt["bands"][band] if nxt != null and (nxt as Dictionary).has("bands") else null
			if not (a["plane"] as Dictionary).is_empty() and b != null and not (b["plane"] as Dictionary).is_empty():
				a["dihedral_to_next_deg"] = _r(rad_to_deg(acos(clampf((a["plane"]["n"] as Vector3).dot(b["plane"]["n"]), -1.0, 1.0))), 2)
			else:
				a["dihedral_to_next_deg"] = null
	var mount_for := func(info: Dictionary, thick: float) -> float:
		if str(c["mount"]) == "centerline":
			return 0.0
		if str(c["mount"]) == "inside":
			return float(info["face_inside_in"]) - thick / 2.0
		return float(info["face_outside_in"]) + thick / 2.0
	# Pass 2: shapes.
	var cfg_spans: Array = c["spans"]
	for span in spans:
		var cfg: Dictionary = cfg_spans[int(span["index"])] if int(span["index"]) < cfg_spans.size() else default_span()
		var lower_shape: Dictionary = {}
		if (span["bands"]["lower"]["plane"] as Dictionary).is_empty() and (span["bands"]["upper"]["plane"] as Dictionary).is_empty():
			continue
		var lu2: Dictionary = uprights[int(span["left"])]
		var ru2: Dictionary = uprights[int(span["right"])]
		for bd in [{"band": "lower", "type": str(cfg["lower"]), "y_bot": bottom_in, "y_top": split_in},
				{"band": "upper", "type": str(cfg["upper"]), "y_bot": split_in, "y_top": upper_top}]:
			var info: Dictionary = span["bands"][bd["band"]]
			if (info["plane"] as Dictionary).is_empty():
				continue
			var is_fabric := str(bd["type"]) == "fabric"
			var thick := FABRIC_THICK_IN if is_fabric else sheet_thick
			var body_thick := sheet_thick if str(bd["type"]) == "none" else thick
			var ctx := {"plane": info["plane"], "side_l": info["side_l"], "side_r": info["side_r"],
				"mount_offset_in": mount_for.call(info, body_thick),
				"tilt_from_vertical_deg": info["tilt_from_vertical_deg"]}
			var shape := build_band_shape(ctx, float(bd["y_bot"]), float(bd["y_top"]), body_thick)
			if shape.is_empty():
				continue
			shape["span_index"] = int(span["index"])
			shape["module_index"] = int(span["module_index"])
			shape["band"] = str(bd["band"])
			shape["dihedral_to_next_deg"] = info["dihedral_to_next_deg"]
			shape["edge_bevel_deg"] = _r(float(info["dihedral_to_next_deg"]) / 2.0, 2) if info["dihedral_to_next_deg"] != null else null
			shape["planarity_error_in"] = info["planarity_error_in"]
			shape["lean"] = info["lean"]
			shape["label"] = "Span %d · %s" % [int(span["index"]) + 1, "Lower" if bd["band"] == "lower" else "Upper"]
			pick_quads.append({"span_index": int(span["index"]), "band": bd["band"], "corners": shape["corners"], "type": bd["type"]})
			if str(bd["type"]) == "none":
				continue
			shape["cover_type"] = str(bd["type"])
			shape["kind"] = "fabric" if is_fabric else "wall"
			# Clearance: does an H-beam of this wedge poke through the slab's inner face?
			var inner_face := float(ctx["mount_offset_in"]) - thick / 2.0
			var s_l: Dictionary = info["side_l"]
			var s_r: Dictionary = info["side_r"]
			var plane: Dictionary = info["plane"]
			var worst := 0.0
			for b in h_beams:
				var mi := int(b.get("module_index", -1))
				if mi != int(span["module_index"]) and mi != ((int(span["module_index"]) + n_up - 1) % n_up):
					continue
				for q in b.get("corners", []):
					var pq: Vector3 = q
					if pq.y < float(bd["y_bot"]) - 0.01 or pq.y > float(bd["y_top"]) + 0.01:
						continue
					var rel := pq - (plane["origin"] as Vector3)
					var dd := rel.dot(plane["n"]) - inner_face
					if dd <= 0.5:
						continue
					var s := rel.dot(plane["u"])
					var t := rel.dot(plane["v"])
					var s_min := float(s_l["s0"]) + (t - float(s_l["t0"])) * float(s_l["slope"]) + 2.0
					var s_max := float(s_r["s0"]) + (t - float(s_r["t0"])) * float(s_r["slope"]) - 2.0
					if s > s_min and s < s_max and dd > worst:
						worst = dd
			if worst > 0.0:
				var w := {"span_index": int(span["index"]), "band": bd["band"], "code": "beam-protrudes",
					"message": "A horizontal beam pokes %.1f in through the %s covering of span %d. Raise Bottom or change Mount." % [
						worst, bd["band"], int(span["index"]) + 1]}
				(shape["warnings"] as Array).append(w)
				warnings.append(w)
			if bd["band"] == "lower":
				lower_shape = shape
			shapes.append(shape)
			if is_fabric:
				totals["fabric_bands"] = int(totals["fabric_bands"]) + 1
				totals["fabric_area_in2"] = float(totals["fabric_area_in2"]) + float(shape["area_in2"])
			else:
				totals["plywood_walls"] = int(totals["plywood_walls"]) + 1
				totals["plywood_area_in2"] = float(totals["plywood_area_in2"]) + float(shape["area_in2"])
		if bool(cfg["table"]) and not (span["bands"]["lower"]["plane"] as Dictionary).is_empty():
			var lower_wall: Dictionary = lower_shape if not lower_shape.is_empty() and str(lower_shape.get("kind", "")) == "wall" else {}
			var wall_inner := float(lower_wall["mount_offset_in"]) - float(lower_wall["thickness_in"]) / 2.0 if not lower_wall.is_empty() else 0.0
			var table := build_table_shape({"plane": span["plane"], "L": lu2, "R": ru2, "edge_gap_in": edge_gap,
				"wall_inner_offset_in": wall_inner, "y_surface": table_y,
				"depth_in": float(c["table"]["depthIn"]), "thickness_in": float(c["table"]["thicknessIn"]),
				"slide_in": float(c["table"]["slideIn"])})
			if not table.is_empty():
				table["span_index"] = int(span["index"])
				table["module_index"] = int(span["module_index"])
				table["band"] = "table"
				table["kind"] = "table"
				table["cover_type"] = "table"
				table["label"] = "Span %d · Table" % (int(span["index"]) + 1)
				if lower_wall.is_empty():
					var w2 := {"span_index": int(span["index"]), "band": "table", "code": "table-unsupported",
						"message": "Table on span %d has no plywood lower wall to rest on." % (int(span["index"]) + 1)}
					(table["warnings"] as Array).append(w2)
					warnings.append(w2)
				shapes.append(table)
				totals["tables"] = int(totals["tables"]) + 1
				totals["table_area_in2"] = float(totals["table_area_in2"]) + float(table["area_in2"])
		if str(cfg["lower"]) != "none" or str(cfg["upper"]) != "none":
			totals["spans_covered"] = int(totals["spans_covered"]) + 1
	if not bool(sp["closed"]) and n_up >= 3:
		warnings.append({"span_index": 0, "band": null, "code": "ring-open",
			"message": "Ring is open (%.1f° off); span 1 is unavailable until the ring closes." % float(sp["closure_error_deg"])})
	for k in ["plywood_area_in2", "fabric_area_in2", "table_area_in2"]:
		totals[k] = _r(float(totals[k]), 1)
	return {
		"enabled": bool(c["enabled"]), "supported": true, "unsupported_reason": "",
		"ring_center": rc, "closed": bool(sp["closed"]),
		"closure_error_deg": _r(float(sp["closure_error_deg"]), 2) if is_finite(float(sp["closure_error_deg"])) else null,
		"mean_gap_deg": _r(float(sp["mean_gap_deg"]), 2),
		"ring_top_y": _r(ring_top), "ring_underside_y": _r(ring_under),
		"split_height_in": _r(split_in), "bottom_in": _r(bottom_in),
		"bottom_mode": "floor" if on_floor else "ground", "table_height_in": _r(table_y),
		"upper_top_in": _r(upper_top), "uprights": uprights, "spans": spans,
		"shapes": shapes, "pick_quads": pick_quads, "warnings": warnings, "totals": totals,
	}


## The split height that makes the lower band one sheet (short side) tall
## along the slant (`splitHeightForOneSheet`).
static func split_height_for_one_sheet(cov: Dictionary, tilt_from_vertical_deg: float) -> float:
	var short := minf(float(cov["sheet"]["widthIn"]), float(cov["sheet"]["lengthIn"]))
	var h := float(cov["bottomIn"]) + short * cos(deg_to_rad(tilt_from_vertical_deg))
	return floorf(h * 4.0) / 4.0
