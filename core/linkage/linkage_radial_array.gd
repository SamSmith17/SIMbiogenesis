class_name LinkageRadialArray
extends RefCounted
## Radial (polar) array of the whole structure — port of LinkageLab's
## `js/linkage/radial-array.js` (LINKAGE_PARITY.md A3).
##
## A horizontal (cylinder) structure tiles in the ground plane: six rings
## round an optional centre ring is a honeycomb. A vertical (arch) one stands
## on radial planes round the anchor: N arches sweep a bent tunnel. Applied
## LAST, after supports and panels: a copy is a RIGID transform of the whole
## single structure, so the solver stays single-structure.
##
## The plan (anchor, ring radius, phase) is measured on the DEPLOYED pose and
## then held while the structure folds, so every copy folds in place about its
## own deployed centre (the web's ensureDeployedFrame).
##
## Copies are tagged `array_index = slot x linear_count + a` (a = the part's
## own linear-array index), so LinkagePartKeys gives every copy unique keys
## (`beam:vertical:a4:…`); hidden slots are planned (stable numbering) but not
## emitted. Inches, the solver's frame. Pure and static.

const COUNT_MIN := 1
const COUNT_MAX := 12
const DEFAULTS := {"enabled": false, "count": 6, "center": true, "rotateCopies": true,
	"radiusAuto": true, "radius": 0.0, "spacing": 0.0, "startAngle": 0.0, "spin": 0.0,
	"heightOffset": 0.0, "hiddenSlots": []}

## Keys holding points (transformed) and directions (rotated) on any part.
const POINT_KEYS := ["p1", "p2", "center", "pos", "bottom_pos", "v_bolt_pivot", "start", "end"]
const DIR_KEYS := ["axis_x", "axis_y", "axis_z", "beam_dir", "right", "bolt_dir", "dir", "normal"]
const HEIGHT_KEYS := ["bottom_y", "y_top", "y_bottom"]
## Lists of points (beams' and coverings' corners).
const POINT_LIST_KEYS := ["corners", "slab_corners"]


## The design's radial array settings (config `mode.radialArray`, camelCase
## like the web app's), normalised over DEFAULTS.
static func config(p: LinkageParams) -> Dictionary:
	var mode = p.extra.get("mode")
	var raw = (mode as Dictionary).get("radialArray") if mode is Dictionary else null
	var out := DEFAULTS.duplicate(true)
	if raw is Dictionary:
		for k in DEFAULTS:
			if (raw as Dictionary).has(k) and raw[k] != null:
				out[k] = raw[k]
	out["count"] = clampi(int(out["count"]), COUNT_MIN, COUNT_MAX)
	return out


## Write the settings back (into `extra`, which `to_config` merges).
static func set_config(p: LinkageParams, cfg: Dictionary) -> void:
	var mode: Dictionary = p.extra.get("mode", {}) if p.extra.get("mode") is Dictionary else {}
	var d := DEFAULTS.duplicate(true)
	for k in DEFAULTS:
		if cfg.has(k):
			d[k] = cfg[k]
	mode["radialArray"] = d
	p.extra["mode"] = mode


static func is_active(cfg: Dictionary) -> bool:
	return bool(cfg.get("enabled", false)) and int(cfg.get("count", 0)) >= COUNT_MIN


static func hidden_slot_set(cfg: Dictionary) -> Dictionary:
	var out := {}
	for v in cfg.get("hiddenSlots", []):
		if (v is int or v is float) and int(v) == float(v) and int(v) >= 0:
			out[int(v)] = true
	return out


static func slot_of_array_index(array_index: int, linear_count: int) -> int:
	return int(floor(float(array_index) / float(maxi(1, linear_count))))


# ---------------------------------------------------------------------------
# Footprint + plan
# ---------------------------------------------------------------------------

static func _beam_points(b: Dictionary) -> Array:
	var c = b.get("corners")
	if c is Array and not (c as Array).is_empty():
		return c
	var out: Array = []
	for k in ["p1", "p2"]:
		if b.get(k) is Vector3:
			out.append(b[k])
	return out


static func beam_bounds(beams: Array) -> Dictionary:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for b in beams:
		for pt in _beam_points(b):
			lo = lo.min(pt)
			hi = hi.max(pt)
	if not is_finite(lo.x):
		return {}
	return {"min": lo, "max": hi, "cx": (lo.x + hi.x) / 2.0, "cz": (lo.z + hi.z) / 2.0,
		"width": hi.x - lo.x, "depth": hi.z - lo.z}


## Mean XZ of the horizontal-ring beam centres per module, module order.
static func module_centers_xz(beams: Array) -> Array:
	var sums := {}
	for b in beams:
		if not str(b.get("stack_type", "")).begins_with("horizontal") or not (b.get("center") is Vector3):
			continue
		var mi := int(b.get("module_index", 0))
		var acc: Array = sums.get(mi, [0.0, 0.0, 0])
		acc[0] += float((b["center"] as Vector3).x)
		acc[1] += float((b["center"] as Vector3).z)
		acc[2] += 1
		sums[mi] = acc
	var keys: Array = sums.keys()
	keys.sort()
	var out: Array = []
	for mi in keys:
		var a: Array = sums[mi]
		out.append({"module_index": mi, "x": a[0] / a[2], "z": a[1] / a[2]})
	return out


## Circumcentre of three XZ points, or {} when (nearly) collinear.
static func circumcenter_xz(a: Dictionary, b: Dictionary, c: Dictionary) -> Dictionary:
	var ax := float(a["x"]); var az := float(a["z"])
	var bx := float(b["x"]); var bz := float(b["z"])
	var cx := float(c["x"]); var cz := float(c["z"])
	var d := 2.0 * (ax * (bz - cz) + bx * (cz - az) + cx * (az - bz))
	var scale := maxf(1.0, maxf(Vector2(bx - ax, bz - az).length(), Vector2(cx - ax, cz - az).length()))
	if absf(d) < 1e-6 * scale * scale:
		return {}
	var a2 := ax * ax + az * az
	var b2 := bx * bx + bz * bz
	var c2 := cx * cx + cz * cz
	return {"x": (a2 * (bz - cz) + b2 * (cz - az) + c2 * (az - bz)) / d,
		"z": (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d}


## Anchor + the ring radius at which copies just touch the centre structure.
static func analyze_footprint(beams: Array, orientation: String, count: int) -> Dictionary:
	var bounds := beam_bounds(beams)
	if bounds.is_empty():
		return {}
	var n := maxi(1, count)
	if orientation == "vertical":
		var half_w := float(bounds["width"]) / 2.0
		var depth := float(bounds["depth"])
		var inner_r := depth / (2.0 * sin(PI / n)) if n >= 2 else depth
		return {"anchor": Vector2(bounds["cx"], bounds["cz"]), "auto_radius": half_w + inner_r,
			"auto_start_rad": 0.0, "footprint": {"half_width": half_w, "depth": depth}}
	var centers := module_centers_xz(beams)
	var anchor := {}
	if centers.size() >= 3:
		anchor = circumcenter_xz(centers[0], centers[1], centers[2])
	if anchor.is_empty():
		anchor = {"x": bounds["cx"], "z": bounds["cz"]}
	var auto_start := 0.0
	var face_reach := maxf(float(bounds["width"]), float(bounds["depth"])) / 2.0
	if not centers.is_empty():
		var m0: Dictionary = centers[0]
		var dx := float(m0["x"]) - float(anchor["x"])
		var dz := float(m0["z"]) - float(anchor["z"])
		var ln := sqrt(dx * dx + dz * dz)
		if ln > 1e-9:
			auto_start = atan2(dz, dx)
			var ux := dx / ln
			var uz := dz / ln
			var reach := 0.0
			for b in beams:
				if int(b.get("module_index", -1)) != int(m0["module_index"]):
					continue
				if not str(b.get("stack_type", "")).begins_with("horizontal"):
					continue
				for pt in _beam_points(b):
					var d := (float(pt.x) - float(anchor["x"])) * ux + (float(pt.z) - float(anchor["z"])) * uz
					reach = maxf(reach, d)
			if reach > 0.0:
				face_reach = reach
	return {"anchor": Vector2(float(anchor["x"]), float(anchor["z"])), "auto_radius": 2.0 * face_reach,
		"auto_start_rad": auto_start, "footprint": {"face_reach": face_reach}}


## The copies ("slots") to emit, or {} when the footprint is empty.
static func plan(cfg: Dictionary, beams: Array, orientation: String) -> Dictionary:
	var count := clampi(int(cfg.get("count", 6)), COUNT_MIN, COUNT_MAX)
	var an := analyze_footprint(beams, orientation, count)
	if an.is_empty():
		return {}
	var spacing := float(cfg.get("spacing", 0.0))
	var base_r := float(cfg.get("radius", 0.0)) if not bool(cfg.get("radiusAuto", true)) else float(an["auto_radius"])
	var radius := maxf(0.0, base_r + spacing)
	var user_start := deg_to_rad(float(cfg.get("startAngle", 0.0)))
	var spin := deg_to_rad(float(cfg.get("spin", 0.0)))
	var height := float(cfg.get("heightOffset", 0.0))
	var rotate := bool(cfg.get("rotateCopies", true))
	var step := TAU / float(count)
	var slots: Array = []
	var si := 0
	if bool(cfg.get("center", true)):
		slots.append({"slot": si, "is_center": true, "theta_rad": 0.0, "phi_rad": 0.0, "offset": Vector3.ZERO})
		si += 1
	for k in count:
		var theta := float(an["auto_start_rad"]) + user_start + k * step
		var phi := (user_start + k * step if rotate else 0.0) + spin
		slots.append({"slot": si, "is_center": false, "ring_index": k, "theta_rad": theta, "phi_rad": phi,
			"offset": Vector3(radius * cos(theta), height, radius * sin(theta))})
		si += 1
	var hidden := hidden_slot_set(cfg)
	var any_visible := false
	for sl in slots:
		if not hidden.has(int(sl["slot"])):
			any_visible = true
	var hidden_slots: Array = []
	for sl in slots:
		sl["hidden"] = any_visible and hidden.has(int(sl["slot"]))
		if sl["hidden"]:
			hidden_slots.append(sl["slot"])
	return {"orientation": orientation, "count": count, "anchor": an["anchor"], "radius": radius,
		"auto_radius": an["auto_radius"], "auto_start_rad": an["auto_start_rad"],
		"start_rad": float(an["auto_start_rad"]) + user_start, "footprint": an["footprint"],
		"slots": slots, "hidden_slots": hidden_slots, "visible_count": slots.size() - hidden_slots.size()}


## A slot's rigid transform (inches): rotate about the anchor's vertical axis
## by phi (the web's rotateXZ: x' = x cos - z sin, z' = x sin + z cos), then
## move by the slot offset.
static func slot_transform(pl: Dictionary, slot: Dictionary) -> Transform3D:
	var c := cos(float(slot["phi_rad"]))
	var s := sin(float(slot["phi_rad"]))
	var basis := Basis(Vector3(c, 0, s), Vector3(0, 1, 0), Vector3(-s, 0, c))
	var a2: Vector2 = pl["anchor"]
	var anchor := Vector3(a2.x, 0.0, a2.y)
	var off: Vector3 = slot["offset"]
	return Transform3D(basis, anchor + off - basis * anchor)


## A rigid copy of one part dictionary (points, directions, corners, bases,
## heights), tagged with its array index.
static func clone_part(d: Dictionary, xf: Transform3D, array_index: int) -> Dictionary:
	var out := d.duplicate()
	out["array_index"] = array_index
	for k in POINT_KEYS:
		if d.get(k) is Vector3:
			out[k] = xf * (d[k] as Vector3)
	for k in DIR_KEYS:
		if d.get(k) is Vector3:
			out[k] = xf.basis * (d[k] as Vector3)
	for k in HEIGHT_KEYS:
		if d.get(k) is float or d.get(k) is int:
			out[k] = float(d[k]) + xf.origin.y - (xf.basis * Vector3.ZERO).y
	for lk in POINT_LIST_KEYS:
		var pts = d.get(lk)
		if pts is Array:
			var cs: Array = []
			for pt in pts:
				cs.append(xf * (pt as Vector3) if pt is Vector3 else pt)
			out[lk] = cs
	var plane = d.get("plane")
	if plane is Dictionary:
		var pl2: Dictionary = (plane as Dictionary).duplicate()
		if pl2.get("origin") is Vector3:
			pl2["origin"] = xf * (pl2["origin"] as Vector3)
		for dk in ["n", "u", "v"]:
			if pl2.get(dk) is Vector3:
				pl2[dk] = xf.basis * (pl2[dk] as Vector3)
		out["plane"] = pl2
	var basis = d.get("basis")
	if basis is Basis:
		out["basis"] = xf.basis * (basis as Basis)
	elif basis is Transform3D:
		out["basis"] = xf * (basis as Transform3D)
	return out


## Linear (tunnel) copies already in the parts: max array_index + 1.
static func linear_count_of(lists: Array) -> int:
	var n := 1
	for lst in lists:
		for o in lst:
			if o is Dictionary and (o as Dictionary).has("array_index"):
				n = maxi(n, int(o["array_index"]) + 1)
	return n


## Every part list in `geo` (keys: beams, brackets, bolts, washers,
## placements, panels, supports — whichever are present) copied into every
## visible slot. Panels are renumbered across the copies (`index`), as the
## web numbers them. Returns {geo, plan} with plan.max_rad / base_max_rad.
## `slot_geo` (slot index -> a geo dict of the same shape) supplies a copy's
## own source — the sequential fold solves a copy at its own angle
## (LinkageFoldSequence); every other slot copies `geo`. Copies stay in slot
## order either way, so part order (and keys) never depends on the fold.
static func apply(pl: Dictionary, geo: Dictionary, slot_geo: Dictionary = {}) -> Dictionary:
	var lists: Array = []
	for k in ["beams", "brackets", "bolts", "washers", "placements", "walls"]:
		if geo.get(k) is Array:
			lists.append(geo[k])
	var linear := linear_count_of(lists)
	var out := {}
	for k in geo:
		if geo[k] is Array:
			out[k] = []
		else:
			out[k] = geo[k]
	for slot in pl.get("slots", []):
		if bool(slot.get("hidden", false)):
			continue
		var xf := slot_transform(pl, slot)
		var src: Dictionary = slot_geo.get(int(slot["slot"]), geo)
		for k in geo:
			if not (geo[k] is Array):
				continue
			for o in src.get(k, []):
				if not (o is Dictionary):
					continue
				var a := int((o as Dictionary).get("array_index", 0))
				(out[k] as Array).append(clone_part(o, xf, int(slot["slot"]) * linear + a))
	if out.get("panels") is Array:
		var i := 0
		for pnl in out["panels"]:
			pnl["index"] = i
			i += 1
	var res := pl.duplicate()
	res["linear_count"] = linear
	res["base_max_rad"] = _max_rad(geo.get("beams", []), pl["anchor"])
	res["max_rad"] = _max_rad(out.get("beams", []), pl["anchor"])
	return {"geo": out, "plan": res}


static func _max_rad(beams: Array, anchor: Vector2) -> float:
	var m := 0.0
	for b in beams:
		for pt in _beam_points(b):
			m = maxf(m, Vector2(float(pt.x) - anchor.x, float(pt.z) - anchor.y).length())
	return m


# ---------------------------------------------------------------------------
# The deployed-pose plan, cached per design
# ---------------------------------------------------------------------------

static var _plan_cache: Dictionary = {}

## The plan measured on the DEPLOYED pose (so copies fold in place), or {}
## when the array is off. Cached on the design (fold excluded).
static func deployed_plan(p: LinkageParams) -> Dictionary:
	var cfg := config(p)
	if not is_active(cfg):
		return {}
	var c2 := p.to_config()
	c2.erase("foldAngle")
	var key := hash(JSON.stringify(c2))
	if _plan_cache.has(key):
		return _plan_cache[key]
	var q := p.duplicate_params()
	var dep := LinkageKinematics.optimal_closed_angle(q)
	var fr := LinkageSolver.solve(q, dep)
	var pl := plan(cfg, fr.get("beams", []), q.orientation)
	if _plan_cache.size() > 16:
		_plan_cache.clear()
	_plan_cache[key] = pl
	return pl
