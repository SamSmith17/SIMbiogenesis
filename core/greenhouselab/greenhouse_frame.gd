class_name GreenhouseFrame
extends RefCounted

## A greenhouse's shape: its cross-section, ribs and purlins, every face of
## its skin with what it is made of (glazing, an opaque wall, or earth below
## grade / under a berm), the vents and doors. Pure; the builder draws it and
## the climate model reads its faces.
##
## Local frame (GreenhouseSpec): origin on the floor at the footprint's
## middle, length along X, width along Z, +Z the front (equator side).
## A tunnel form (gable, lean-to, hoop, gothic) is a cross-section profile in
## the (z, y) plane swept along X; a dome is DomeLab's geodesic.
##
## Face: {kind: "roof"|"wall"|"end"|"back"|"earth", material: GLAZING or WALLS
##   id, glazed: bool, area: m², normal: Vector3 (outward), centre: Vector3,
##   tilt_deg (0 = facing up), poly: PackedVector3Array, depth_m (earth:
##   how far below grade the face's middle is, 0 for a berm)}

const ARC_SEGMENTS := 10
const PURLIN_SPACING_M := 1.5
const DOME_SPEC_STRUT := "emt_1"


static func solve(spec: Dictionary) -> Dictionary:
	var s := GreenhouseSpec.resolve(spec)
	if str(s["form"]) == "dome":
		return _solve_dome(s)
	return _solve_tunnel(s)


# ---------------------------------------------------------------------------
# Tunnel forms
# ---------------------------------------------------------------------------

## The cross-section from the floor at z = -W/2 up over to z = +W/2 (open at
## the floor). Points are (z, y).
static func profile(s: Dictionary) -> PackedVector2Array:
	var w := float(s["width_m"])
	var hw := w * 0.5
	var eave := float(s["eave_h_m"])
	var ridge := float(s["ridge_h_m"])
	var p := PackedVector2Array()
	match str(s["form"]):
		"gable":
			p = PackedVector2Array([Vector2(-hw, 0.0), Vector2(-hw, eave), Vector2(0.0, ridge),
				Vector2(hw, eave), Vector2(hw, 0.0)])
		"lean_to":
			# Back (north, -Z) wall to the ridge, roof down to the front wall.
			var fh := minf(float(s["front_h_m"]), ridge - 0.3)
			p = PackedVector2Array([Vector2(-hw, 0.0), Vector2(-hw, ridge), Vector2(hw, fh),
				Vector2(hw, 0.0)])
		"hoop":
			p.append(Vector2(-hw, 0.0))
			if eave > 0.01:
				p.append(Vector2(-hw, eave))
			var h := ridge - eave
			for i in range(1, ARC_SEGMENTS * 2):
				var a := PI - PI * float(i) / float(ARC_SEGMENTS * 2)
				p.append(Vector2(hw * cos(a), eave + h * sin(a)))
			if eave > 0.01:
				p.append(Vector2(hw, eave))
			p.append(Vector2(hw, 0.0))
		_:
			# Gothic: two circular arcs from the wall tops meeting in a point
			# at the ridge (gothic_arc says where their centre is).
			var h := ridge - eave
			var ga := gothic_arc(hw, h, eave)
			var c: Vector2 = ga["c"]
			var r := float(ga["r"])
			var a0 := atan2(eave - c.y, -hw - c.x)
			var a1 := atan2(ridge - c.y, 0.0 - c.x)
			p.append(Vector2(-hw, 0.0))
			if eave > 0.01:
				p.append(Vector2(-hw, eave))
			var left := PackedVector2Array()
			for i in range(1, ARC_SEGMENTS + 1):
				var a := lerpf(a0, a1, float(i) / float(ARC_SEGMENTS))
				left.append(c + Vector2(cos(a), sin(a)) * r)
			left[left.size() - 1] = Vector2(0.0, ridge)
			for q in left:
				p.append(q)
			for i in range(left.size() - 2, -1, -1):
				p.append(Vector2(-left[i].x, left[i].y))
			if eave > 0.01:
				p.append(Vector2(hw, eave))
			p.append(Vector2(hw, 0.0))
	return p


## The left arc of a gothic arch: the circle through the wall top (-hw, eave)
## and the ridge (0, eave + h) that arrives at the ridge rising at angle phi
## (the point). Centre on the arc's normal at the ridge:
##   r = (hw² + h²) / (2 (h cos phi − hw sin phi)).
## phi is 20 degrees, or half the chord's own slope on a flatter arch, so the
## arch is always pointed and always reaches the ridge from below.
static func gothic_arc(hw: float, h: float, eave: float) -> Dictionary:
	var phi := minf(deg_to_rad(20.0), 0.5 * atan2(h, hw))
	var den := 2.0 * (h * cos(phi) - hw * sin(phi))
	var r := (hw * hw + h * h) / maxf(den, 1e-4)
	var c := Vector2(r * sin(phi), eave + h - r * cos(phi))
	return {"c": c, "r": r, "phi": phi}


## The inside height at cross coordinate `z` (the profile's top there).
static func height_at(prof: PackedVector2Array, z: float) -> float:
	var best := 0.0
	for i in prof.size() - 1:
		var a := prof[i]
		var b := prof[i + 1]
		var lo := minf(a.x, b.x)
		var hi := maxf(a.x, b.x)
		if z < lo - 1e-6 or z > hi + 1e-6:
			continue
		var y := a.y if absf(b.x - a.x) < 1e-6 else lerpf(a.y, b.y, (z - a.x) / (b.x - a.x))
		if absf(b.x - a.x) < 1e-6:
			y = maxf(a.y, b.y)
		best = maxf(best, y)
	return best


static func profile_area(prof: PackedVector2Array) -> float:
	var a := 0.0
	for i in prof.size():
		var p := prof[i]
		var q := prof[(i + 1) % prof.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


static func _solve_tunnel(s: Dictionary) -> Dictionary:
	var prof := profile(s)
	var L := float(s["length_m"])
	var W := float(s["width_m"])
	var hl := L * 0.5
	var sink := float(s["ground"]["sink_m"])
	var berm := str(s["ground"]["berm"])
	var eave := float(s["eave_h_m"])
	var ridge := float(s["ridge_h_m"])
	var form := str(s["form"])
	var gl: Dictionary = s["glazing"]
	var faces: Array = []
	# Long faces: one per profile segment, split at grade.
	for i in prof.size() - 1:
		var a := prof[i]
		var b := prof[i + 1]
		var seg := b - a
		if seg.length() < 1e-4:
			continue
		var steep := absf(seg.y) > absf(seg.x) * 2.0
		# Outward normal in the (z, y) plane: the profile runs clockwise
		# over the top (left to right), so outward is (-dy, dx) rotated.
		var n2 := Vector2(-seg.y, seg.x).normalized()
		var mid := (a + b) * 0.5
		if n2.dot(mid - Vector2(0.0, ridge * 0.4)) < 0.0:
			n2 = -n2
		var kind := "wall" if steep else "roof"
		var mat := str(gl["walls"]) if steep else str(gl["roof"])
		var glazed := true
		if form == "lean_to" and i == 0:
			kind = "back"
			mat = str(s["back_wall"])
			glazed = false
		var bermed := false
		if berm != "none" and n2.y < 0.6:
			# A berm covers the back (-Z) side below the eave; "three" the
			# ends too (handled with the end faces).
			bermed = n2.x < -0.3
		for part in _split_at(a, b, sink if not bermed else maxf(sink, eave)):
			var pa: Vector2 = part[0]
			var pb: Vector2 = part[1]
			var below: bool = part[2]
			var fa := {"kind": kind, "material": mat, "glazed": glazed}
			if below:
				fa = {"kind": "earth", "material": str(s["ground"]["walls"]), "glazed": false}
			var poly := PackedVector3Array([Vector3(-hl, pa.y, pa.x), Vector3(hl, pa.y, pa.x),
				Vector3(hl, pb.y, pb.x), Vector3(-hl, pb.y, pb.x)])
			fa["area"] = (pb - pa).length() * L
			fa["normal"] = Vector3(0.0, n2.y, n2.x)
			fa["centre"] = Vector3(0.0, (pa.y + pb.y) * 0.5, (pa.x + pb.x) * 0.5)
			fa["tilt_deg"] = rad_to_deg(acos(clampf(n2.y, -1.0, 1.0)))
			fa["poly"] = poly
			fa["depth_m"] = maxf(sink - (pa.y + pb.y) * 0.5, 0.0) if below else 0.0
			if fa["area"] > 1e-4:
				faces.append(fa)
	# End walls (x = ±L/2): the profile closed by the floor.
	var end_area := profile_area(prof)
	var door_a := float(s["doors"]["w_m"]) * float(s["doors"]["h_m"])
	var ends_glazed := str(gl["ends"]) != "stud"
	for sx: float in [-1.0, 1.0]:
		var poly2 := PackedVector3Array()
		for pt in prof:
			poly2.append(Vector3(sx * hl, pt.y, pt.x))
		var below_a := minf(sink, ridge) * W
		var berm_a := 0.0
		if berm == "three":
			berm_a = clampf(eave - sink, 0.0, ridge) * W
		var has_door: bool = int(s["doors"]["count"]) == 2 or float(sx) > 0.0
		var open_a := door_a if has_door else 0.0
		var above := maxf(end_area - below_a - berm_a - open_a, 0.0)
		var f_end := {"kind": "end", "material": str(gl["ends"]) if ends_glazed else "stud_insulated",
			"glazed": ends_glazed, "area": above, "normal": Vector3(sx, 0.0, 0.0),
			"centre": Vector3(sx * hl, (sink + ridge) * 0.5, 0.0), "tilt_deg": 90.0, "poly": poly2,
			"depth_m": 0.0}
		faces.append(f_end)
		if open_a > 0.0:
			faces.append({"kind": "door", "material": "stud_insulated", "glazed": false, "area": open_a,
				"normal": Vector3(sx, 0.0, 0.0), "centre": Vector3(sx * hl, float(s["doors"]["h_m"]) * 0.5, 0.0),
				"tilt_deg": 90.0, "poly": PackedVector3Array(), "depth_m": 0.0})
		if below_a > 0.0:
			faces.append({"kind": "earth", "material": str(s["ground"]["walls"]), "glazed": false,
				"area": below_a, "normal": Vector3(sx, 0.0, 0.0), "centre": Vector3(sx * hl, sink * 0.5, 0.0),
				"tilt_deg": 90.0, "poly": PackedVector3Array(), "depth_m": sink * 0.5})
		if berm_a > 0.0:
			faces.append({"kind": "earth", "material": str(s["ground"]["walls"]), "glazed": false,
				"area": berm_a, "normal": Vector3(sx, 0.0, 0.0),
				"centre": Vector3(sx * hl, (sink + eave) * 0.5, 0.0), "tilt_deg": 90.0,
				"poly": PackedVector3Array(), "depth_m": 0.0})
	# Ribs every bay, purlins along the length.
	var bays := maxi(int(ceil(L / float(s["bay_m"]))), 1)
	var ribs: Array = []
	for i in bays + 1:
		var x := -hl + L * float(i) / float(bays)
		var rib := PackedVector3Array()
		for pt in prof:
			rib.append(Vector3(x, pt.y, pt.x))
		ribs.append(rib)
	var rib_len := 0.0
	for i in prof.size() - 1:
		rib_len += (prof[i + 1] - prof[i]).length()
	var purlin_pts := _purlin_points(prof)
	var purlins: Array = []
	for pp in purlin_pts:
		purlins.append([Vector3(-hl, pp.y, pp.x), Vector3(hl, pp.y, pp.x)])
	var frame_m := rib_len * float(bays + 1) + L * float(purlin_pts.size())
	var doors: Array = []
	for sx2: float in [1.0, -1.0]:
		if sx2 < 0.0 and int(s["doors"]["count"]) < 2:
			break
		doors.append({"x": sx2 * hl, "z": 0.0, "normal": Vector3(sx2, 0.0, 0.0),
			"w_m": float(s["doors"]["w_m"]), "h_m": minf(float(s["doors"]["h_m"]), height_at(prof, 0.0) - 0.1)})
	return {"spec": s, "form": str(s["form"]), "profile": prof, "faces": faces, "ribs": ribs,
		"purlins": purlins, "bays": bays, "frame_m": frame_m, "doors": doors,
		"vents": _vents(s, prof), "floor": {"kind": "rect", "w": L, "d": W},
		"floor_area_m2": L * W, "volume_m3": end_area * L, "roof_plan_m2": L * W,
		"ridge_h_m": ridge, "dome": {}}


## The profile split at height `cut`: [[a, b, below]] pieces.
static func _split_at(a: Vector2, b: Vector2, cut: float) -> Array:
	if cut <= 0.0:
		return [[a, b, false]]
	var a_below := a.y < cut - 1e-6
	var b_below := b.y < cut - 1e-6
	if a_below == b_below:
		var lo := minf(a.y, b.y)
		var hi := maxf(a.y, b.y)
		if not a_below and lo >= cut - 1e-6:
			return [[a, b, false]]
		if a_below and hi <= cut + 1e-6:
			return [[a, b, true]]
		return [[a, b, a_below]]
	var t := (cut - a.y) / (b.y - a.y)
	var m := a.lerp(b, t)
	return [[a, m, a_below], [m, b, b_below]]


## Points along the profile about PURLIN_SPACING_M apart (the eaves and the
## ridge always among them), skipping the floor ends.
static func _purlin_points(prof: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var acc := 0.0
	for i in range(1, prof.size() - 1):
		acc += (prof[i] - prof[i - 1]).length()
		var corner := false
		if i > 0 and i < prof.size() - 1:
			var d0 := (prof[i] - prof[i - 1]).normalized()
			var d1 := (prof[i + 1] - prof[i]).normalized()
			corner = d0.dot(d1) < 0.94
		if corner or acc >= PURLIN_SPACING_M:
			out.append(prof[i])
			acc = 0.0
	return out


static func _vents(s: Dictionary, prof: PackedVector2Array) -> Array:
	var v: Dictionary = s["vents"]
	var L := float(s["length_m"])
	var out: Array = []
	var ridge := float(s["ridge_h_m"])
	var form := str(s["form"])
	if bool(v["ridge"]):
		var rh := ridge - 0.15
		if form == "lean_to":
			rh = ridge - 0.3
		out.append({"kind": "ridge", "area_m2": float(v["ridge_w_m"]) * L, "height_m": rh,
			"z": -float(s["width_m"]) * 0.5 + 0.3 if form == "lean_to" else 0.0})
	var sides := str(v["sides"])
	if sides != "none":
		var sh := minf(float(v["side_h_m"]), maxf(float(s["eave_h_m"]), float(s["front_h_m"])) + 0.6)
		var free := 1.0 if sides == "rollup" else 0.4
		var n_sides := 1 if form == "lean_to" else 2
		out.append({"kind": "sides", "area_m2": sh * L * free * float(n_sides),
			"height_m": float(s["ground"]["sink_m"]) + sh * 0.5, "z": 0.0})
	if bool(v["ends"]) and float(v["end_m2"]) > 0.0:
		var eh := float(s["eave_h_m"]) + (ridge - float(s["eave_h_m"])) * 0.6
		out.append({"kind": "ends", "area_m2": float(v["end_m2"]) * 2.0, "height_m": eh, "z": 0.0})
	return out


# ---------------------------------------------------------------------------
# Dome
# ---------------------------------------------------------------------------

## The DomeLab spec this greenhouse's dome is drawn and measured from.
static func dome_spec(s: Dictionary) -> Dictionary:
	var d := DomeLabSpec.default_spec("geodesic")
	d["name"] = str(s["name"])
	d["radius_m"] = float(s["width_m"]) * 0.5
	d["geodesic"]["frequency"] = int(s["dome"]["frequency"])
	d["geodesic"]["fraction"] = float(s["dome"]["fraction"])
	var fr := GreenhouseMaterials.frame(str(s["frame"]))
	d["strut"]["material"] = str(fr.get("strut", DOME_SPEC_STRUT))
	var g := GreenhouseMaterials.glazing(str(s["glazing"]["roof"]))
	d["face"]["material"] = str(g.get("look", "polycarb_6"))
	return d


static func _solve_dome(s: Dictionary) -> Dictionary:
	var ds := dome_spec(s)
	var dd := DomeLabDesign.solve(ds)
	var geo: Dictionary = dd["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var stats: Dictionary = dd["stats"]
	var sink := float(s["ground"]["sink_m"])
	var berm := str(s["ground"]["berm"])
	var gl: Dictionary = s["glazing"]
	var faces: Array = []
	var height := float(stats.get("height_m", float(s["width_m"]) * 0.5))
	for f in geo["faces"]:
		var pf: PackedInt32Array = f
		var poly := PackedVector3Array()
		var c := Vector3.ZERO
		for vi in pf:
			poly.append(verts[vi])
			c += verts[vi]
		c /= float(pf.size())
		var area := 0.0
		var nrm := Vector3.ZERO
		for k in range(1, pf.size() - 1):
			var cr := (verts[pf[k]] - verts[pf[0]]).cross(verts[pf[k + 1]] - verts[pf[0]])
			area += cr.length() * 0.5
			nrm += cr
		nrm = nrm.normalized()
		if nrm.dot(c - Vector3(0.0, height - float(ds["radius_m"]), 0.0)) < 0.0:
			nrm = -nrm
		var steep := nrm.y < 0.45
		var fa := {"kind": "wall" if steep else "roof", "material": str(gl["walls"]) if steep else str(gl["roof"]),
			"glazed": true, "area": area, "normal": nrm, "centre": c,
			"tilt_deg": rad_to_deg(acos(clampf(nrm.y, -1.0, 1.0))), "poly": poly, "depth_m": 0.0}
		if c.y < sink or (berm != "none" and c.y < height * 0.3 and (nrm.z < -0.3 or berm == "three")):
			fa["kind"] = "earth"
			fa["material"] = str(s["ground"]["walls"])
			fa["glazed"] = false
			fa["depth_m"] = maxf(sink - c.y, 0.0)
		faces.append(fa)
	var fr_r := float(stats.get("floor_radius_m", float(s["width_m"]) * 0.5))
	var floor_a := float(stats.get("floor_area_m2", PI * fr_r * fr_r))
	var door_h := minf(float(s["doors"]["h_m"]), height - 0.2)
	var doors := [{"x": 0.0, "z": fr_r, "normal": Vector3(0.0, 0.0, 1.0),
		"w_m": float(s["doors"]["w_m"]), "h_m": door_h}]
	var vents: Array = []
	var v: Dictionary = s["vents"]
	if bool(v["ridge"]):
		# An opening ring of panels round the top: about 10 % of the floor.
		vents.append({"kind": "ridge", "area_m2": floor_a * 0.10, "height_m": height - 0.4, "z": 0.0})
	if str(v["sides"]) != "none":
		var free := 1.0 if str(v["sides"]) == "rollup" else 0.4
		vents.append({"kind": "sides", "area_m2": TAU * fr_r * float(v["side_h_m"]) * 0.5 * free,
			"height_m": sink + float(v["side_h_m"]) * 0.5, "z": 0.0})
	return {"spec": s, "form": "dome", "profile": PackedVector2Array(), "faces": faces, "ribs": [],
		"purlins": [], "bays": 0, "frame_m": float(stats.get("strut_m", 0.0)), "doors": doors,
		"vents": vents, "floor": {"kind": "circle", "r": fr_r}, "floor_area_m2": floor_a,
		"volume_m3": float(stats.get("volume_m3", 0.0)), "roof_plan_m2": PI * pow(float(stats.get("radius_max_m", fr_r)), 2.0),
		"ridge_h_m": height, "dome": {"spec": ds, "radius_m": float(ds["radius_m"]), "height_m": height}}


## Inside height above the floor at a plan point (x, z): what a bed or a
## light rack has above it.
static func height_at_xz(fr: Dictionary, x: float, z: float) -> float:
	if str(fr["form"]) == "dome":
		var R := float(fr["dome"]["radius_m"])
		var top := float(fr["dome"]["height_m"])
		var yc := top - R
		var r := Vector2(x, z).length()
		if r >= R:
			return 0.0
		return maxf(yc + sqrt(R * R - r * r), 0.0)
	return height_at(fr["profile"], z)
