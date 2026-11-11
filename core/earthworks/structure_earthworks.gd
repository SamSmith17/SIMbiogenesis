class_name StructureEarthworks
extends RefCounted

## Earthworks a placed structure asks the terrain for (pure, no nodes).
##
## A record's `earthworks` dict says how the ground meets the building:
##   * a HOLE: the roofed interior. The terrain is cut out of the drawing there
##     (TerrainHoleMask, per pixel, exactly at the wall line) and its collider
##     is sunk, so the structure's own floor, walls and roof are what you walk
##     on. `_ground_height_at` reads the FLOOR inside it, water reads the ROOF.
##   * BERMS against chosen sides (earth piled up the wall, to the roof or a
##     set height, falling away at `run` metres per metre of height).
##   * CUTS (a daylight cut or sunken patio in front of the glazing, a walkout
##     yard) and RAMPS (an entry ramp down to the floor).
##
## All positions are metres in the PROP's frame (its yaw applied, scale
## already in metres: x right, z toward +Z at yaw 0, which faces south).
## Heights are relative to the model's y = 0 ("y0"), which sits at
## grade − sink_m; berm heights are above GRADE (the ground at the origin with
## no structure on it).
##
## `solve` turns a list of placed structures into per-sample deltas for the
## structure tile layer: the delta is target − surface, where surface is the
## ground WITHOUT the structure layer, so a floor or a berm top lands at its
## exact height whatever the player sculpted or the streams carved underneath.

const KEY := "earthworks"
const SIDES := ["-z", "+z", "-x", "+x"]
## The side each edge of a rect footprint faces, in local_footprint's order.
const RECT_EDGE_SIDES := ["-z", "+x", "+z", "-x"]
## Side names as the player reads them (at yaw 0 the +z side faces south).
const SIDE_WORDS := {"-z": "Back", "+z": "Front", "-x": "Left", "+x": "Right"}
## How far below the floor the hidden interior terrain is pushed (m). Deep
## enough that nothing ever pokes through a floor slab, shallow enough that
## the DetailGround boundary ring does not have to follow a chasm.
const INTERIOR_SINK_M := 3.0
## Most the structure layer may move the ground (m), either way.
const MAX_DELTA_M := 40.0
const DEFAULT_RUN_M := 2.0
const DEFAULT_CREST_M := 0.6


static func default_spec() -> Dictionary:
	return {
		"on": true,
		"sink_m": 0.0,
		"rect": [-4.0, -4.0, 4.0, 4.0],
		"poly": [],
		"hole": true,
		"floor_y": -1.0,
		"roof_y": 3.0,
		"slab": false,
		"walls": false,
		"lights": true,
		"wall_sides": [],
		"berm": {},
		"cuts": [],
		"ramps": [],
	}


static func is_on(rec: Dictionary) -> bool:
	var own: Variant = rec.get(KEY, null)
	if own is Dictionary:
		return bool((own as Dictionary).get("on", true))
	return not spec_for_record(rec).is_empty()


## The earthworks a record asks for: its own `earthworks`, or the ones its
## design implies (a parametric building with a basement). {} = none.
static func spec_for_record(rec: Dictionary) -> Dictionary:
	var e: Variant = rec.get(KEY, null)
	if e is Dictionary:
		return e
	if str(rec.get("model_id", "")) == BuildingFeatures.MODEL_ID \
			and rec.get("building_spec", null) is Dictionary:
		return BasementBuilder.earthworks_for_building(rec["building_spec"])
	return {}


static func _f(d: Dictionary, k: String, dv: float) -> float:
	var v: Variant = d.get(k, dv)
	return float(v) if (v is float or v is int) else dv


static func _pt(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


static func _poly_of(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if v is Array:
		for p in v:
			out.append(_pt(p))
	elif v is PackedVector2Array:
		out = v
	return out


## Fill defaults and clamp. Unknown keys survive (a newer build's data).
static func resolve(spec_in: Variant) -> Dictionary:
	var s := default_spec()
	if spec_in is Dictionary:
		for k in (spec_in as Dictionary).keys():
			s[k] = (spec_in as Dictionary)[k]
	s["sink_m"] = clampf(_f(s, "sink_m", 0.0), -10.0, 20.0)
	var r: Variant = s.get("rect", [])
	if not (r is Array) or (r as Array).size() < 4:
		r = [-4.0, -4.0, 4.0, 4.0]
	var x0 := float(r[0])
	var z0 := float(r[1])
	var x1 := float(r[2])
	var z1 := float(r[3])
	s["rect"] = [minf(x0, x1), minf(z0, z1), maxf(maxf(x0, x1), minf(x0, x1) + 0.5),
		maxf(maxf(z0, z1), minf(z0, z1) + 0.5)]
	s["floor_y"] = clampf(_f(s, "floor_y", -1.0), -15.0, 10.0)
	s["roof_y"] = clampf(_f(s, "roof_y", 3.0), float(s["floor_y"]) + 0.5, 30.0)
	var berm: Dictionary = {}
	var bin: Variant = s.get("berm", {})
	if bin is Dictionary:
		for side in SIDES:
			var b: Variant = (bin as Dictionary).get(side, null)
			if b is Dictionary:
				var bd: Dictionary = b
				var h := _f(bd, "h", 0.0)
				if absf(h) < 0.01:
					continue
				berm[side] = {
					"h": clampf(h, -1.0, 20.0) if h >= 0.0 else -1.0,
					"run": clampf(_f(bd, "run", DEFAULT_RUN_M), 0.3, 12.0),
					"crest": clampf(_f(bd, "crest", DEFAULT_CREST_M), 0.0, 6.0),
				}
	s["berm"] = berm
	var cuts: Array = []
	var cin: Variant = s.get("cuts", [])
	if cin is Array:
		for c in cin:
			if c is Dictionary and _poly_of((c as Dictionary).get("poly", [])).size() >= 3:
				var cd: Dictionary = c
				cuts.append({
					"poly": cd["poly"],
					"floor_y": clampf(_f(cd, "floor_y", float(s["floor_y"])), -15.0, 10.0),
					"run": clampf(_f(cd, "run", DEFAULT_RUN_M), 0.3, 12.0),
				})
	s["cuts"] = cuts
	var ramps: Array = []
	var rin: Variant = s.get("ramps", [])
	if rin is Array:
		for rv in rin:
			if rv is Dictionary:
				var rd: Dictionary = rv
				ramps.append({
					"a": [_pt(rd.get("a", [0, 0])).x, _pt(rd.get("a", [0, 0])).y],
					"b": [_pt(rd.get("b", [0, 1])).x, _pt(rd.get("b", [0, 1])).y],
					"ya": clampf(_f(rd, "ya", 0.0), -15.0, 10.0),
					"yb": clampf(_f(rd, "yb", float(s["floor_y"])), -15.0, 10.0),
					"w": clampf(_f(rd, "w", 1.5), 0.6, 8.0),
					"run": clampf(_f(rd, "run", DEFAULT_RUN_M), 0.3, 12.0),
				})
	s["ramps"] = ramps
	s["on"] = bool(s.get("on", true))
	s["hole"] = bool(s.get("hole", true))
	s["slab"] = bool(s.get("slab", false))
	s["walls"] = bool(s.get("walls", false))
	s["lights"] = bool(s.get("lights", true))
	var ws: Array = []
	var wsin: Variant = s.get("wall_sides", [])
	if wsin is Array:
		for w in wsin:
			if SIDES.has(str(w)):
				ws.append(str(w))
	s["wall_sides"] = ws
	return s


static func key_of(spec: Dictionary) -> String:
	return JSON.stringify(spec)


## The footprint in the prop frame: the polygon when one is given, else the rect.
static func local_footprint(spec: Dictionary) -> PackedVector2Array:
	var p := _poly_of(spec.get("poly", []))
	if p.size() >= 3:
		return p
	var r: Array = spec["rect"]
	return PackedVector2Array([Vector2(r[0], r[1]), Vector2(r[2], r[1]),
		Vector2(r[2], r[3]), Vector2(r[0], r[3])])


## Prop frame → world XZ (yaw in degrees, Godot's rotation about +Y).
static func to_world(local: Vector2, origin: Vector2, yaw_deg: float) -> Vector2:
	var v := Vector3(local.x, 0.0, local.y).rotated(Vector3.UP, deg_to_rad(yaw_deg))
	return origin + Vector2(v.x, v.z)


static func to_world_poly(local: PackedVector2Array, origin: Vector2, yaw_deg: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in local:
		out.append(to_world(p, origin, yaw_deg))
	return out


## One structure, placed: everything the solver and the runtime need, in world
## space. `grade_y` = the ground at the origin with no structure on it.
static func placement(rec: Dictionary, grade_y: float) -> Dictionary:
	var spec := resolve(spec_for_record(rec))
	var origin := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	var yaw := float(rec.get("yaw", 0.0))
	var y0 := grade_y - float(spec["sink_m"]) + float(rec.get("y_offset", 0.0))
	var foot := to_world_poly(local_footprint(spec), origin, yaw)
	var cuts: Array = []
	for c in spec["cuts"]:
		cuts.append({"poly": to_world_poly(_poly_of(c["poly"]), origin, yaw),
			"floor": y0 + float(c["floor_y"]), "run": float(c["run"])})
	var ramps: Array = []
	for r in spec["ramps"]:
		ramps.append({"a": to_world(_pt(r["a"]), origin, yaw), "b": to_world(_pt(r["b"]), origin, yaw),
			"ya": grade_y + float(r["ya"]), "yb": y0 + float(r["yb"]),
			"w": float(r["w"]), "run": float(r["run"])})
	var berms: Array = []
	var rp := local_footprint({"rect": spec["rect"], "poly": []})
	# Rect corners in order: (x0,z0) (x1,z0) (x1,z1) (x0,z1). Edge per side,
	# wound so the outward normal is the edge direction turned right.
	var edges := {"-z": [rp[1], rp[0]], "+x": [rp[2], rp[1]],
		"+z": [rp[3], rp[2]], "-x": [rp[0], rp[3]]}
	for side in spec["berm"].keys():
		var b: Dictionary = spec["berm"][side]
		var e: Array = edges[side]
		var a := to_world(e[0], origin, yaw)
		var bb := to_world(e[1], origin, yaw)
		var n := outward(to_world_poly(rp, origin, yaw), a, bb)
		var top := y0 + float(spec["roof_y"]) if float(b["h"]) < 0.0 else grade_y + float(b["h"])
		berms.append({"a": a, "b": bb, "n": n, "top": top, "grade": grade_y,
			"run": float(b["run"]), "crest": float(b["crest"])})
	var hole := {}
	if bool(spec["hole"]):
		hole = {"poly": foot, "floor": y0 + float(spec["floor_y"]),
			"roof": y0 + float(spec["roof_y"]), "slab": bool(spec["slab"]),
			"walls": bool(spec["walls"]), "id": str(rec.get("id", "")),
			"lights": bool(spec["lights"]), "grade": grade_y,
			"wall_sides": spec["wall_sides"],
			"rect_edges": _poly_of(spec.get("poly", [])).size() < 3}
	return {"id": str(rec.get("id", "")), "spec": spec, "origin": origin, "yaw": yaw,
		"grade": grade_y, "y0": y0, "foot": foot, "cuts": cuts, "ramps": ramps,
		"berms": berms, "hole": hole}


## The unit normal of edge a→b pointing out of the polygon.
static func outward(poly: PackedVector2Array, a: Vector2, b: Vector2) -> Vector2:
	var d := (b - a).normalized()
	var n := Vector2(d.y, -d.x)
	var mid := (a + b) * 0.5
	if Geometry2D.is_point_in_polygon(mid + n * 0.05, poly):
		n = -n
	return n


## World-XZ bounds a placement can touch (footprint grown by every run).
static func reach_rect(pl: Dictionary) -> Rect2:
	var pts := PackedVector2Array(pl["foot"])
	var pad := 1.5
	for b in pl["berms"]:
		pad = maxf(pad, float(b["crest"]) + float(b["run"]) * maxf(1.0, absf(float(b["top"]) - float(b["grade"]))) + 1.5)
	for c in pl["cuts"]:
		for p in c["poly"]:
			pts.append(p)
		pad = maxf(pad, float(c["run"]) * 6.0 + 1.5)
	for r in pl["ramps"]:
		pts.append(r["a"])
		pts.append(r["b"])
		pad = maxf(pad, float(r["w"]) + float(r["run"]) * 6.0)
	var rect := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		rect = rect.expand(p)
	return rect.grow(pad)


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Distance from p to the boundary of a polygon.
static func poly_edge_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	var n := poly.size()
	for i in n:
		best = minf(best, _seg_dist(p, poly[i], poly[(i + 1) % n]))
	return best


## What one placement asks of a world point, given the surface there without
## the structure layer: [raise_to or -INF, lower_to or INF, sink_to or INF].
static func ask_at(pl: Dictionary, p: Vector2, cell_m: float) -> Vector3:
	var raise := -INF
	var lower := INF
	var sink := INF
	for b in pl["berms"]:
		var a: Vector2 = b["a"]
		var n: Vector2 = b["n"]
		# A cell inside the wall line rises too (hidden by the opening or the
		# building's own wall): on a 1.5 m grid that is what lets the berm
		# reach its full height AT the wall face instead of a cell out.
		var depth_in := -(p - a).dot(n)
		if depth_in > cell_m * 1.05:
			continue
		var ab: Vector2 = b["b"] - a
		var along := (p - a).dot(ab) / maxf(ab.length_squared(), 1e-9)
		if depth_in > 0.0 and (along < 0.0 or along > 1.0):
			continue
		var d := 0.0 if depth_in > 0.0 else _seg_dist(p, a, b["b"])
		var top := float(b["top"])
		var grade := float(b["grade"])
		var crest := float(b["crest"])
		var run := float(b["run"])
		var y := top if d <= crest else top - (d - crest) / run
		if y > grade - 0.25:
			raise = maxf(raise, y)
	for c in pl["cuts"]:
		var poly: PackedVector2Array = c["poly"]
		var fl := float(c["floor"])
		if Geometry2D.is_point_in_polygon(p, poly):
			lower = minf(lower, fl)
		else:
			lower = minf(lower, fl + poly_edge_dist(p, poly) / float(c["run"]))
	for r in pl["ramps"]:
		var a2: Vector2 = r["a"]
		var ab: Vector2 = r["b"] - a2
		var l2 := ab.length_squared()
		if l2 < 1e-6:
			continue
		var u := (p - a2).dot(ab) / l2
		if u < -0.05 or u > 1.05:
			continue
		var uc := clampf(u, 0.0, 1.0)
		var centre := lerpf(float(r["ya"]), float(r["yb"]), uc)
		var lat := p.distance_to(a2 + ab * uc)
		var hw := float(r["w"]) * 0.5
		var y2 := centre if lat <= hw else centre + (lat - hw) / float(r["run"])
		lower = minf(lower, y2)
	var hole: Dictionary = pl["hole"]
	if not hole.is_empty():
		var poly2: PackedVector2Array = hole["poly"]
		# Only samples a full cell inside the wall line are pushed down: the
		# triangles that cross the wall keep their corners at the outside
		# ground, so the soil meets the wall face exactly where the shader
		# cuts the drawing (nothing slopes into a trench outside the wall).
		if Geometry2D.is_point_in_polygon(p, poly2):
			if poly_edge_dist(p, poly2) >= cell_m * 1.05:
				sink = float(hole["floor"]) - INTERIOR_SINK_M
			else:
				# A cell inside the wall on the open side: the cut runs on
				# flat to the wall, or the ground there rises into a lip at
				# the door (the drawn cut hides it; the edge collar does not).
				for c2 in pl["cuts"]:
					if poly_edge_dist(p, c2["poly"]) <= cell_m * 1.5:
						lower = minf(lower, float(hole["floor"]))
	return Vector3(raise, lower, sink)


## The structure layer for a set of placements: global sample index → delta.
## `surface_fn(x, z)` = ground WITHOUT the structure layer. Order of the
## combine: berms raise, then cuts and ramps lower (a cut always wins over a
## neighbour's berm), then a hole's interior sinks.
static func solve(placements: Array, surface_fn: Callable, cell_m: float) -> Dictionary:
	var out := {}
	for pl in placements:
		var rect := reach_rect(pl)
		var i0 := floori(rect.position.x / cell_m)
		var j0 := floori(rect.position.y / cell_m)
		var i1 := ceili(rect.end.x / cell_m)
		var j1 := ceili(rect.end.y / cell_m)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var p := Vector2(float(i) * cell_m, float(j) * cell_m)
				var ask := ask_at(pl, p, cell_m)
				if ask.x == -INF and ask.y == INF and ask.z == INF:
					continue
				var key := Vector2i(i, j)
				var prev: Vector3 = out.get(key, Vector3(-INF, INF, INF))
				out[key] = Vector3(maxf(prev.x, ask.x), minf(prev.y, ask.y), minf(prev.z, ask.z))
	var deltas := {}
	for key in out.keys():
		var a: Vector3 = out[key]
		var k: Vector2i = key
		var s := float(surface_fn.call(float(k.x) * cell_m, float(k.y) * cell_m))
		var t := s
		if a.x != -INF:
			t = maxf(t, a.x)
		if a.y != INF:
			t = minf(t, a.y)
		if a.z != INF:
			t = minf(t, a.z)
		var d := clampf(t - s, -MAX_DELTA_M, MAX_DELTA_M)
		if absf(d) > 1e-3:
			deltas[key] = d
	return deltas


## The holes of a set of placements (world polygons with floor and roof).
static func holes_of(placements: Array) -> Array:
	var out: Array = []
	for pl in placements:
		if not (pl["hole"] as Dictionary).is_empty():
			out.append(pl["hole"])
	return out


## The hole whose polygon holds p, or {} (the first one wins).
static func hole_at(holes: Array, p: Vector2) -> Dictionary:
	for h in holes:
		var r: Rect2 = h.get("rect", Rect2())
		if r.size != Vector2.ZERO and not r.has_point(p):
			continue
		if Geometry2D.is_point_in_polygon(p, h["poly"]):
			return h
	return {}


## Stamp each hole with its bounding rect (fast rejection in hole_at).
static func index_holes(holes: Array) -> void:
	for h in holes:
		var poly: PackedVector2Array = h["poly"]
		var r := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			r = r.expand(p)
		h["rect"] = r


## A daylight cut in front of one side: the strip `width` m out from that
## wall, floor at the hole's floor, sides falling back at `run`.
static func daylight_cut(spec: Dictionary, side: String, width: float, run: float = DEFAULT_RUN_M) -> Dictionary:
	var r: Array = resolve(spec)["rect"]
	var x0 := float(r[0])
	var z0 := float(r[1])
	var x1 := float(r[2])
	var z1 := float(r[3])
	var poly: Array = []
	match side:
		"+z": poly = [[x0, z1], [x1, z1], [x1, z1 + width], [x0, z1 + width]]
		"-z": poly = [[x0, z0 - width], [x1, z0 - width], [x1, z0], [x0, z0]]
		"+x": poly = [[x1, z0], [x1 + width, z0], [x1 + width, z1], [x1, z1]]
		_: poly = [[x0 - width, z0], [x0, z0], [x0, z1], [x0 - width, z1]]
	return {"poly": poly, "floor_y": float(resolve(spec)["floor_y"]), "run": run}


# ---------------------------------------------------------------------------
# The simple form: what the prop editor (and a designer) edits. One dict of
# plain numbers becomes the full spec; it rides along as spec["simple"] so the
# editor can read its own settings back.
#   {sink_m, rect, hole, floor_y, roof_y, slab, walls,
#    berm: {side: height m above grade, -1 = to the roof, 0 = none},
#    berm_run, daylight: side or "", cut_w, ramp_len, ramp_w}
# ---------------------------------------------------------------------------

const OUTWARD := {"-z": Vector2(0, -1), "+z": Vector2(0, 1), "-x": Vector2(-1, 0), "+x": Vector2(1, 0)}


static func default_simple() -> Dictionary:
	return {"sink_m": 0.0, "rect": [-4.0, -4.0, 4.0, 4.0], "hole": true,
		"floor_y": 0.0, "roof_y": 2.6, "slab": false, "walls": false, "lights": true,
		"berm": {}, "berm_run": 1.5, "daylight": "", "cut_w": 3.0,
		"ramp_len": 0.0, "ramp_w": 1.6}


static func from_simple(simple_in: Dictionary) -> Dictionary:
	var sm := default_simple()
	for k in simple_in.keys():
		sm[k] = simple_in[k]
	var spec := {"on": true, "sink_m": float(sm["sink_m"]), "rect": sm["rect"],
		"hole": bool(sm["hole"]), "floor_y": float(sm["floor_y"]), "roof_y": float(sm["roof_y"]),
		"slab": bool(sm["slab"]), "walls": bool(sm["walls"]), "lights": bool(sm["lights"]),
		"simple": sm.duplicate(true)}
	var berm := {}
	var bsrc: Variant = sm.get("berm", {})
	if bsrc is Dictionary:
		for side in SIDES:
			var h := float((bsrc as Dictionary).get(side, 0.0))
			if absf(h) > 0.01:
				berm[side] = {"h": h if h > 0.0 else -1.0, "run": float(sm["berm_run"]), "crest": DEFAULT_CREST_M}
	spec["berm"] = berm
	var side_d := str(sm.get("daylight", ""))
	var cuts: Array = []
	var ramps: Array = []
	var walls: Array = []
	for side in SIDES:
		if side != side_d:
			walls.append(side)
	spec["wall_sides"] = walls
	if SIDES.has(side_d):
		var cw := maxf(float(sm["cut_w"]), 0.5)
		cuts.append(daylight_cut(spec, side_d, cw, float(sm["berm_run"])))
		var rl := float(sm["ramp_len"])
		if rl > 0.3:
			var r: Array = spec["rect"]
			var c := Vector2((float(r[0]) + float(r[2])) * 0.5, (float(r[1]) + float(r[3])) * 0.5)
			var o: Vector2 = OUTWARD[side_d]
			var half := Vector2((float(r[2]) - float(r[0])) * 0.5, (float(r[3]) - float(r[1])) * 0.5)
			var edge := c + Vector2(o.x * half.x, o.y * half.y) + o * cw
			# `ramp_at`: where along the open side the ramp comes in (the
			# entry door), in the prop frame; default the middle.
			var at_v: Variant = sm.get("ramp_at", null)
			if at_v is float or at_v is int:
				if absf(o.y) > 0.5:
					edge.x = float(at_v)
				else:
					edge.y = float(at_v)
			var top := edge + o * rl
			ramps.append({"a": [top.x, top.y], "b": [edge.x, edge.y], "ya": 0.0,
				"yb": float(sm["floor_y"]), "w": float(sm["ramp_w"]), "run": float(sm["berm_run"])})
	spec["cuts"] = cuts
	spec["ramps"] = ramps
	return resolve(spec)


## The simple form a spec was made from (or one read off a hand-made spec).
static func simple_of(spec_in: Variant) -> Dictionary:
	if spec_in is Dictionary and (spec_in as Dictionary).get("simple", null) is Dictionary:
		var sm := default_simple()
		var src: Dictionary = (spec_in as Dictionary)["simple"]
		for k in src.keys():
			sm[k] = src[k]
		return sm
	var spec := resolve(spec_in)
	var sm2 := default_simple()
	for k in ["sink_m", "rect", "hole", "floor_y", "roof_y", "slab", "walls", "lights"]:
		sm2[k] = spec[k]
	var berm := {}
	for side in (spec["berm"] as Dictionary).keys():
		berm[side] = float(spec["berm"][side]["h"])
	sm2["berm"] = berm
	return sm2
