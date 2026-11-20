class_name BattWire
extends RefCounted

## Battery cable as it really lies: its outside diameter by gauge, how
## tightly it can bend, the ring lug crimped on each end, and the path it
## takes between two lugs at that bend radius. Millimetres. Pure static.
##
## Sources (all ESTIMATES unless a standard is named):
##  - Outside diameters: typical fine-strand welding / battery cable (Class K,
##    EPDM or silicone jacket) from maker tables, 8 AWG to 500 kcmil; small
##    hook-up sizes (22–10 AWG) silicone wire.
##  - Minimum bend radius: flexible fine-strand cable 4 × OD for silicone
##    hook-up and pack wiring, 5 × OD for welding / battery cable in a bank
##    (makers' training radius; NEC 300.34 sets 8 × for shielded MV cable,
##    which is not this).
##  - Ring lugs: tinned copper tube lugs (barrel sized to the conductor, a
##    flat tongue round the stud) — proportions of maker drawings.

## [name, OD mm] — the jacketed cable.
const OD := {
	"22 AWG": 1.6, "20 AWG": 1.9, "18 AWG": 2.3, "16 AWG": 2.7,
	"14 AWG": 3.4, "12 AWG": 3.9, "10 AWG": 4.9, "8 AWG": 7.4, "6 AWG": 8.4,
	"4 AWG": 9.9, "3 AWG": 10.8, "2 AWG": 11.5, "1 AWG": 12.7, "1/0 AWG": 14.0,
	"2/0 AWG": 15.2, "3/0 AWG": 16.5, "4/0 AWG": 18.3, "250 kcmil": 20.3,
	"300 kcmil": 21.6, "350 kcmil": 23.1, "500 kcmil": 26.9,
}
## Bend radius as a multiple of OD, by kind of cable.
const BEND_X := {"silicone": 4.0, "battery": 5.0, "balance": 3.0}
## Paths are sampled every this many degrees of turn.
const STEP_DEG := 10.0


## The cable's outside diameter (mm), by its gauge name, else from its
## copper cross-section (conductor + a jacket a fifth of it, min 0.6 mm).
static func od_mm(name: String, mm2: float = 0.0) -> float:
	if OD.has(name):
		return float(OD[name])
	var dc := conductor_d_mm(mm2)
	return dc + 2.0 * maxf(0.6, dc * 0.2)


## The stranded conductor's diameter (mm): solid-equivalent × 1.12 for the
## gaps between strands.
static func conductor_d_mm(mm2: float) -> float:
	return sqrt(maxf(mm2, 0.05) * 4.0 / PI) * 1.12


## The tightest radius (mm, to the cable's centre line) it should bend to.
static func bend_r_mm(od: float, kind: String = "battery") -> float:
	return od * float(BEND_X.get(kind, 5.0))


## A ring lug for a conductor of `mm2` on a stud of `stud` mm:
## {barrel_od, barrel_len, tongue_w, tongue_len, tongue_t, hole_d, sleeve_len,
## reach (stud centre to barrel end)}.
static func lug(mm2: float, stud: float = 8.0) -> Dictionary:
	var dc := conductor_d_mm(mm2)
	var bid := dc + 0.6
	var bod := bid * 1.3 + 1.0
	var blen := maxf(10.0, dc * 1.7 + 6.0)
	var tw := maxf(stud * 2.1, bod * 1.15)
	var tt := clampf(bod * 0.18, 0.8, 4.5)
	var tl := tw * 0.95
	return {"barrel_od": bod, "barrel_len": blen, "tongue_w": tw, "tongue_len": tl, "tongue_t": tt,
		"hole_d": stud + 0.5, "sleeve_len": blen * 0.7 + 8.0, "reach": tl * 0.5 + blen}


## The barrel's way out of a lug at `p` on a stud along `n`: toward the
## first of `towards` that is not straight along the stud (projected flat
## onto the terminal's face).
static func lug_dir(p: Vector3, n: Vector3, towards: Array) -> Vector3:
	for q in towards:
		var v := (q as Vector3) - p
		var t := v - n * v.dot(n)
		if t.length() > 1e-2 * maxf(v.length(), 1.0):
			return t.normalized()
	return n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()


## Where a cable leaves a lug: the barrel's end (stud point + lift + reach)
## and its direction. No lug: the point itself, heading at the next point.
static func lug_exit(p: Vector3, n: Vector3, towards: Array, lg: Dictionary) -> Dictionary:
	if lg.is_empty():
		var nx: Vector3 = towards[0] if not towards.is_empty() else p + n
		var d := nx - p
		return {"p": p, "t": d.normalized() if d.length() > 1e-4 else n, "s": p}
	var t := lug_dir(p, n, towards)
	var lift := float(lg["tongue_t"]) * 0.5 + float(lg["barrel_od"]) * 0.5
	return {"p": p, "t": t, "s": p + n * lift + t * float(lg["reach"])}


## The cable between two lugs: each lug at its stud point `a` / `b` on a face
## with normal `na` / `nb`, its barrel pointing at the first / last waypoint
## (or the other end), straight out of the barrel for a bend radius, then
## through `mids` with every corner bent at `r`. An empty lug dict = no lug
## at that end (the cable starts at the point). {path (barrel end to barrel
## end), lug_a / lug_b: {p, n, t, lug}, length (incl. the barrels), min_r,
## tight, r, od}.
static func route(a: Vector3, na: Vector3, b: Vector3, nb: Vector3, mids: Array, od: float, r: float,
		lga: Dictionary, lgb: Dictionary = {}) -> Dictionary:
	var ta_list: Array = mids.duplicate()
	ta_list.append(b)
	var tb_list: Array = mids.duplicate()
	tb_list.reverse()
	tb_list.append(a)
	var xa := lug_exit(a, na, ta_list, lga)
	var xb := lug_exit(b, nb, tb_list, lgb)
	var s: Vector3 = xa["s"]
	var e: Vector3 = xb["s"]
	var ta: Vector3 = xa["t"]
	var tb: Vector3 = xb["t"]
	var corners := PackedVector3Array()
	corners.append(s)
	if not lga.is_empty():
		corners.append(s + ta * r)
	for m in mids:
		corners.append(m)
	if not lgb.is_empty():
		corners.append(e + tb * r)
	corners.append(e)
	corners = _clean(corners)
	var res := ConduitFillet.apply(corners, r, STEP_DEG)
	var path: PackedVector3Array = res["points"]
	var mr := min_radius(path)
	var barrels := (float(lga.get("barrel_len", 0.0)) + float(lgb.get("barrel_len", 0.0)))
	return {"path": path, "lug_a": {"p": a, "n": na, "t": ta, "lug": lga}, "lug_b": {"p": b, "n": nb, "t": tb, "lug": lgb},
		"length": length(path) + barrels, "min_r": mr, "tight": not (res["tight"] as Array).is_empty(),
		"r": r, "od": od}


## A cable through `corners` with every corner bent at r: {path, tight,
## min_r, length}.
static func bend(corners: PackedVector3Array, r: float) -> Dictionary:
	var c := _clean(corners)
	var res := ConduitFillet.apply(c, r, STEP_DEG)
	var path: PackedVector3Array = res["points"]
	return {"path": path, "tight": not (res["tight"] as Array).is_empty(), "min_r": min_radius(path),
		"length": length(path)}


## Waypoints for a cable that leaves both lugs and runs at height `via_y`:
## up (or down) from each exit to that height, across in two legs.
static func via_mids(sa: Vector3, sb: Vector3, via_y: float) -> Array:
	return [Vector3(sa.x, via_y, sa.z), Vector3(sb.x, via_y, sa.z), Vector3(sb.x, via_y, sb.z)]


## Drop repeated points and points in a straight line with their
## neighbours (the fillet only needs real corners).
static func _clean(c: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in c:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.5:
			out.append(p)
	var i := 1
	while i < out.size() - 1:
		var d0 := (out[i] - out[i - 1]).normalized()
		var d1 := (out[i + 1] - out[i]).normalized()
		if d0.dot(d1) > 0.9995:
			out.remove_at(i)
		else:
			i += 1
	return out


static func length(path: PackedVector3Array) -> float:
	var l := 0.0
	for i in range(1, path.size()):
		l += path[i].distance_to(path[i - 1])
	return l


## The smallest radius of curvature along a sampled path (circumradius of
## each three consecutive points; straight stretches are INF).
static func min_radius(path: PackedVector3Array) -> float:
	var m := INF
	for i in range(1, path.size() - 1):
		var a := path[i - 1]
		var b := path[i]
		var c := path[i + 1]
		var ab := a.distance_to(b)
		var bc := b.distance_to(c)
		var ca := c.distance_to(a)
		var area2 := (b - a).cross(c - a).length()
		if area2 < 1e-6 * maxf(ab * bc, 1e-9):
			continue
		m = minf(m, ab * bc * ca / (2.0 * area2))
	return m
