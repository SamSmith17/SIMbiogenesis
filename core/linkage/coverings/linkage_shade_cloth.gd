class_name LinkageShadeCloth
extends RefCounted
## Roof shade tarps (port of `js/linkage/shade-cloth.js`, A4): one rectangle
## per module, laid radially.
##
## Each module of the top ring gets its own tarp. Its width is the distance
## between that module's two outer pivots (the roof polygon's edge); it starts
## a little past the outer edge and runs inward toward the ring centre, so the
## N tarps fan round the roof and overlap at the middle. Width and length can
## be overridden, the whole array rotated, and every second tarp lifted so the
## overlaps drape over / under. Nothing is cut.
##
## Pure. Config `shadeCloth` rides `LinkageParams.extra` (camelCase); tarps
## are covering records (kind "shade", band "roof") in snake_case.

const OFF_MAX := 1200.0
const LEN_MIN := 0.05
const LEN_MAX := 2400.0
const THICKNESS_IN := 0.1

const DEFAULTS := {
	"enabled": false, "widthMode": "auto", "widthIn": 120.0, "widthTrimIn": 0.0,
	"lengthMode": "auto", "lengthIn": 240.0, "centerOverlapIn": 12.0, "overhangIn": 6.0,
	"rotationDeg": 0.0, "staggerIn": 0.0, "liftIn": 2.0, "color": "#6f8f86",
	"opacity": 0.75, "visible": true,
}

const PRESETS := {
	"10x10": {"widthIn": 120.0, "lengthIn": 120.0},
	"10x20": {"widthIn": 120.0, "lengthIn": 240.0},
	"12x20": {"widthIn": 144.0, "lengthIn": 240.0},
	"20x20": {"widthIn": 240.0, "lengthIn": 240.0},
}

const SWATCHES := [
	{"name": "Shade mesh", "color": "#6f8f86"}, {"name": "Tarp blue", "color": "#2f6fb3"},
	{"name": "Silver", "color": "#b8bcc0"}, {"name": "Canvas", "color": "#c8b08a"},
	{"name": "Black", "color": "#222222"},
]


static func _num(v, def: float) -> float:
	return float(v) if (v is float or v is int) and is_finite(float(v)) else def


static func _clampn(v, def: float, lo: float, hi: float) -> float:
	return clampf(_num(v, def), lo, hi)


static func normalize_hex(v, def: String) -> String:
	if not (v is String):
		return def
	var s := (v as String).strip_edges().trim_prefix("#")
	if s.length() == 6 and s.is_valid_hex_number():
		return "#" + s.to_lower()
	if s.length() == 3 and s.is_valid_hex_number():
		var out := "#"
		for ch in s:
			out += ch + ch
		return out.to_lower()
	return def


## `normalizeShade`, incl. the Phase-4/5 grid configs (sizes kept as custom).
static func normalize(raw) -> Dictionary:
	var d: Dictionary = DEFAULTS
	var r: Dictionary = raw if raw is Dictionary else {}
	var legacy := not r.has("widthMode") and (r.has("overlapIn") or r.has("offsetXIn") or r.has("widthIn"))
	var mode := func(v, fallback: String) -> String:
		return v if v is String and (v == "auto" or v == "custom") else fallback
	return {
		"enabled": bool(r.get("enabled", false)),
		"widthMode": mode.call(r.get("widthMode"), "custom" if legacy else str(d["widthMode"])),
		"widthIn": _clampn(r.get("widthIn"), d["widthIn"], LEN_MIN, LEN_MAX),
		"widthTrimIn": _clampn(r.get("widthTrimIn"), d["widthTrimIn"], -OFF_MAX, OFF_MAX),
		"lengthMode": mode.call(r.get("lengthMode"), "custom" if legacy else str(d["lengthMode"])),
		"lengthIn": _clampn(r.get("lengthIn"), d["lengthIn"], LEN_MIN, LEN_MAX),
		"centerOverlapIn": _clampn(r.get("centerOverlapIn"), d["centerOverlapIn"], -OFF_MAX, OFF_MAX),
		"overhangIn": _clampn(r.get("overhangIn"), 0.0 if legacy else float(d["overhangIn"]), -OFF_MAX, OFF_MAX),
		"rotationDeg": _clampn(r.get("rotationDeg"), d["rotationDeg"], -360.0, 360.0),
		"staggerIn": _clampn(r.get("staggerIn"), d["staggerIn"], -OFF_MAX, OFF_MAX),
		"liftIn": _clampn(r.get("liftIn"), d["liftIn"], -OFF_MAX, OFF_MAX),
		"color": normalize_hex(r.get("color"), str(d["color"])),
		"opacity": _clampn(r.get("opacity"), d["opacity"], 0.05, 1.0),
		"visible": r.get("visible", true) != false,
	}


static func config(p: LinkageParams) -> Dictionary:
	return normalize(p.extra.get("shadeCloth"))


static func set_config(p: LinkageParams, cfg: Dictionary) -> void:
	p.extra["shadeCloth"] = normalize(cfg)


static func _beam_top_y(b: Dictionary) -> float:
	return LinkageFloor._beam_top_y(b)


static func _far_end(b: Dictionary, cx: float, cz: float) -> Vector3:
	var p1: Vector3 = b["p1"]
	var p2: Vector3 = b["p2"]
	return p1 if Vector2(p1.x - cx, p1.z - cz).length() >= Vector2(p2.x - cx, p2.z - cz).length() else p2


## Outer polygon of the top ring (`calculateRoofPolygon`): the outer ends of
## each module's top scissor legs, one vertex per shared outer pivot, plus
## per-edge frames mapped to modules.
static func roof_polygon(beams: Array, num_modules: int) -> Dictionary:
	var top: Array = []
	for b in beams:
		if str(b.get("stack_type", "")) == "horizontal-top" and b.get("p1") is Vector3 and b.get("p2") is Vector3:
			top.append(b)
	if top.is_empty():
		return {}
	var cx := 0.0
	var cz := 0.0
	for b in top:
		cx += ((b["p1"] as Vector3).x + (b["p2"] as Vector3).x) / 2.0
		cz += ((b["p1"] as Vector3).z + (b["p2"] as Vector3).z) / 2.0
	cx /= top.size()
	cz /= top.size()
	var raw: Array = []
	for i in num_modules:
		for b in top:
			if int(b.get("module_index", -1)) == i:
				var far := _far_end(b, cx, cz)
				raw.append(Vector2(far.x, far.z))
	if raw.size() < 3:
		return {}
	var ang := func(p: Vector2) -> float: return atan2(p.y - cz, p.x - cx)
	raw = LinkageFloor._stable_sort_by(raw, ang)
	var tol := PI / maxf(3.0, num_modules)
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
	pts = LinkageFloor._stable_sort_by(pts, func(p: Vector2) -> float: return atan2(p.y - c.y, p.x - c.x))
	var top_y := -INF
	for b in top:
		top_y = maxf(top_y, _beam_top_y(b))
	var mod_mid: Array = []
	for i in num_modules:
		var ends: Array = []
		for b in top:
			if int(b.get("module_index", -1)) == i:
				ends.append(_far_end(b, cx, cz))
		if not ends.is_empty():
			var m2 := Vector2.ZERO
			for e in ends:
				m2 += Vector2((e as Vector3).x, (e as Vector3).z)
			mod_mid.append({"module_index": i, "p": m2 / ends.size()})
	var edges: Array = []
	for i in pts.size():
		var a2: Vector2 = pts[i]
		var b2: Vector2 = pts[(i + 1) % pts.size()]
		var mid := (a2 + b2) / 2.0
		var chord := a2.distance_to(b2)
		if chord == 0.0:
			chord = 1.0
		var apothem := mid.distance_to(c)
		if apothem == 0.0:
			apothem = 1.0
		var module_index := i
		var best := INF
		for mm in mod_mid:
			var dd := (mm["p"] as Vector2).distance_to(mid)
			if dd < best:
				best = dd
				module_index = int(mm["module_index"])
		edges.append({"index": i, "a": a2, "b": b2, "mid": mid, "chord_in": chord, "apothem_in": apothem,
			"u": (b2 - a2) / chord, "n_out": (mid - c) / apothem, "module_index": module_index})
	return {"vertices": pts, "center": c, "top_y": top_y, "edges": edges}


## One tarp per module (`calculateShadeCloths`). `beams` must include the
## support beams (tarps lie above them); `coverings_top_y` = the top of the
## upper wall bands when those reach higher (NAN = none).
static func compute(beams: Array, p: LinkageParams, coverings_top_y: float = NAN) -> Dictionary:
	var shade := config(p)
	var empty := {"enabled": bool(shade["enabled"]), "supported": false, "shapes": [], "count": 0,
		"coverage_pct": 0.0, "overhang_in2": 0.0, "canopy_area_in2": 0.0, "sizes": [], "warnings": []}
	if not bool(shade["enabled"]) or p.orientation == "vertical":
		empty["unsupported_reason"] = "arch" if p.orientation == "vertical" else ""
		return empty
	var roof := roof_polygon(beams, p.modules)
	if roof.is_empty() or (roof["edges"] as Array).is_empty():
		empty["unsupported_reason"] = "no-ring"
		return empty
	var c: Vector2 = roof["center"]
	var width_auto := str(shade["widthMode"]) != "custom"
	var length_auto := str(shade["lengthMode"]) != "custom"
	var trim := float(shade["widthTrimIn"])
	var overhang := float(shade["overhangIn"])
	var center_overlap := float(shade["centerOverlapIn"])
	var rot := deg_to_rad(float(shade["rotationDeg"]))
	var stagger := float(shade["staggerIn"])
	var cos_r := cos(rot)
	var sin_r := sin(rot)
	var rot_xz := func(q: Vector2) -> Vector2:
		return Vector2(c.x + (q.x - c.x) * cos_r - (q.y - c.y) * sin_r, c.y + (q.x - c.x) * sin_r + (q.y - c.y) * cos_r)
	var rot_dir := func(dv: Vector2) -> Vector2:
		return Vector2(dv.x * cos_r - dv.y * sin_r, dv.x * sin_r + dv.y * cos_r)
	# Above the support / reciprocal beams when present, else the ring's top
	# face, and never below the upper wall / fabric bands.
	var base_y := float(roof["top_y"])
	var over := beams.filter(func(b): return str(b.get("stack_type", "")).begins_with("support-beam"))
	if not over.is_empty():
		base_y = -INF
		for b in over:
			base_y = maxf(base_y, _beam_top_y(b))
	if is_finite(coverings_top_y):
		base_y = maxf(base_y, coverings_top_y)
	var y_base := base_y + float(shade["liftIn"])
	var roof_xz: Array = roof["vertices"]
	var canopy_area := LinkageSheetNesting.polygon_area(roof_xz)
	var shapes: Array = []
	var warnings: Array = []
	var overhang_total := 0.0
	var edges: Array = roof["edges"]
	for i in edges.size():
		var e: Dictionary = edges[i]
		var w := maxf(0.05, (float(e["chord_in"]) if width_auto else float(shade["widthIn"])) + trim)
		var l := maxf(0.05, float(e["apothem_in"]) + overhang + center_overlap if length_auto else float(shade["lengthIn"]))
		var u: Vector2 = rot_dir.call(e["u"])
		var n_out: Vector2 = rot_dir.call(e["n_out"])
		var oc: Vector2 = rot_xz.call((e["mid"] as Vector2) + (e["n_out"] as Vector2) * overhang)
		var y := y_base + (stagger if i % 2 == 1 else 0.0)
		var cxz := [oc - u * w / 2.0, oc + u * w / 2.0, oc + u * w / 2.0 - n_out * l, oc - u * w / 2.0 - n_out * l]
		var local: Array = []
		for q in roof_xz:
			var dq: Vector2 = (q as Vector2) - oc
			local.append(Vector2(dq.dot(u), -dq.dot(n_out)))
		var inside := LinkageSheetNesting.clip_polygon_to_rect(local, -w / 2.0, 0.0, w / 2.0, l)
		var inside_area := LinkageSheetNesting.polygon_area(inside) if inside.size() >= 3 else 0.0
		var corners: Array = []
		var slab_lo: Array = []
		var slab_hi: Array = []
		for q in cxz:
			corners.append(Vector3((q as Vector2).x, y, (q as Vector2).y))
			slab_lo.append(Vector3((q as Vector2).x, y - THICKNESS_IN / 2.0, (q as Vector2).y))
			slab_hi.append(Vector3((q as Vector2).x, y + THICKNESS_IN / 2.0, (q as Vector2).y))
		var plan: Array = []
		for q in cxz:
			plan.append(Vector2(LinkageSheetNesting.rnd((q as Vector2).x), LinkageSheetNesting.rnd((q as Vector2).y)))
		var cen: Vector2 = ((cxz[0] as Vector2) + (cxz[2] as Vector2)) / 2.0
		shapes.append({
			"type": "covering", "kind": "shade", "band": "roof", "cover_type": "shade",
			"span_index": i, "module_index": int(e["module_index"]),
			"label": "Shade tarp %d · Module %d" % [i + 1, int(e["module_index"]) + 1],
			"corners": corners, "slab_corners": slab_lo + slab_hi,
			"center": Vector3(cen.x, y, cen.y), "normal": Vector3.UP, "plan_2d": plan,
			"frame": {"origin": oc, "u": u, "inward": -n_out},
			"width_in": LinkageSheetNesting.rnd(w), "length_in": LinkageSheetNesting.rnd(l),
			"outer_pivot_dist_in": LinkageSheetNesting.rnd(float(e["chord_in"])),
			"inside_area_in2": LinkageSheetNesting.rnd(inside_area, 1), "overhang_in2": LinkageSheetNesting.rnd(w * l - inside_area, 1),
			"thickness_in": THICKNESS_IN, "area_in2": LinkageSheetNesting.rnd(w * l, 1), "warnings": [],
		})
		overhang_total += w * l - inside_area
	# Coverage: sample the roof polygon on a grid, count points under a tarp.
	var bb := LinkageSheetNesting.bbox(roof_xz)
	var hits := 0
	var total := 0
	var n := 48
	for i in n:
		for j in n:
			var pt := Vector2(float(bb["min_x"]) + (i + 0.5) / n * float(bb["w"]),
				float(bb["min_y"]) + (j + 0.5) / n * float(bb["h"]))
			if not _inside_poly(pt, roof_xz):
				continue
			total += 1
			if _under_tarp(pt, shapes):
				hits += 1
	var coverage := LinkageSheetNesting.rnd(100.0 * hits / total, 1) if total > 0 else 0.0
	if coverage < 99.0:
		warnings.append({"code": "gaps", "message": "Tarps cover %s%% of the roof; add width trim, centre overlap or length to close the gaps." % str(coverage)})
	# Size groups for the BOM (rounded to 1/4").
	var size_map := {}
	var order: Array = []
	for sh in shapes:
		var sw := roundf(float(sh["width_in"]) * 4.0) / 4.0
		var sl := roundf(float(sh["length_in"]) * 4.0) / 4.0
		var key := "%sx%s" % [str(sw), str(sl)]
		if not size_map.has(key):
			size_map[key] = {"width_in": sw, "length_in": sl, "qty": 0}
			order.append(key)
		size_map[key]["qty"] = int(size_map[key]["qty"]) + 1
	var sizes: Array = []
	for k in order:
		sizes.append(size_map[k])
	sizes = _stable_sort_sizes(sizes)
	var cloth := 0.0
	for sh in shapes:
		cloth += float(sh["area_in2"])
	var poly3: Array = []
	for q in roof_xz:
		poly3.append(Vector3((q as Vector2).x, y_base, (q as Vector2).y))
	return {
		"enabled": true, "supported": true, "unsupported_reason": "",
		"polygon": {"vertices": poly3, "center": Vector3(c.x, y_base, c.y)},
		"y": LinkageSheetNesting.rnd(y_base), "shapes": shapes, "count": shapes.size(),
		"canopy_area_in2": LinkageSheetNesting.rnd(canopy_area, 1), "cloth_area_in2": LinkageSheetNesting.rnd(cloth, 1),
		"overhang_in2": LinkageSheetNesting.rnd(overhang_total, 1), "coverage_pct": coverage, "sizes": sizes,
		"width_in": float(sizes[0]["width_in"]) if not sizes.is_empty() else 0.0,
		"length_in": float(sizes[0]["length_in"]) if not sizes.is_empty() else 0.0,
		"width_mode": "auto" if width_auto else "custom", "length_mode": "auto" if length_auto else "custom",
		"rotation_deg": float(shade["rotationDeg"]), "stagger_in": stagger, "overhang_in": overhang,
		"color": str(shade["color"]), "opacity": float(shade["opacity"]), "warnings": warnings,
	}


static func _stable_sort_sizes(sizes: Array) -> Array:
	var idx: Array = []
	for i in sizes.size():
		idx.append([sizes[i], i])
	idx.sort_custom(func(a, b):
		var qa := int(a[0]["qty"])
		var qb := int(b[0]["qty"])
		if qa != qb:
			return qa > qb
		var wa := float(a[0]["width_in"])
		var wb := float(b[0]["width_in"])
		if wa != wb:
			return wa > wb
		return a[1] < b[1])
	var out: Array = []
	for e in idx:
		out.append(e[0])
	return out


static func _inside_poly(p: Vector2, poly: Array) -> bool:
	var inside := false
	var j := poly.size() - 1
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[j]
		if (a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
			inside = not inside
		j = i
	return inside


static func _under_tarp(p: Vector2, shapes: Array) -> bool:
	for sh in shapes:
		var f: Dictionary = sh["frame"]
		var dq := p - (f["origin"] as Vector2)
		var s := dq.dot(f["u"])
		var d := dq.dot(f["inward"])
		if s >= -float(sh["width_in"]) / 2.0 - 1e-6 and s <= float(sh["width_in"]) / 2.0 + 1e-6 \
				and d >= -1e-6 and d <= float(sh["length_in"]) + 1e-6:
			return true
	return false


static func _ft(v: float) -> String:
	return String.num(v / 12.0, 1 if absf(fmod(v, 12.0)) > 1e-6 else 0)


## ENCLOSURE BOM rows, one per tarp size (`shadeBomItems`).
static func bom_items(shade_data: Dictionary, p: LinkageParams) -> Array:
	if shade_data.is_empty() or int(shade_data.get("count", 0)) == 0:
		return []
	var unit := LinkageCoveringPlan.price(p, "shadeCloth", 60.0)
	var sizes: Array = shade_data.get("sizes", [])
	var out: Array = []
	for i in sizes.size():
		var sz: Dictionary = sizes[i]
		var label := "Shade tarps %s × %s ft" % [_ft(float(sz["width_in"])), _ft(float(sz["length_in"]))]
		if i == 0:
			label += " (one per module, %s%% roof coverage)" % str(shade_data["coverage_pct"])
		out.append(LinkageBom._line(int(sz["qty"]), label, unit, 0.0, "enclosure", "shade_cloth" if i == 0 else "shade_cloth%d" % i))
	return out
