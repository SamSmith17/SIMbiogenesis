class_name TcSpecialty
extends RefCounted

## Specialty sanitary fittings for the TC designer (plan Phase 4): sight
## glass, valves (butterfly, ball 2- and 3-way, check, diaphragm, relief),
## actuators, instruments (thermometer, gauge, thermowell), condensers and
## columns (dephlegmator / Liebig, packed column, bubble plate), filters
## (inline and Y strainers, cartridge housing) and brewing parts (strainer
## basket, funnel, spray ball, heating element). Same contract as TcParts:
## each builder fills a TcGeom (mm) and returns {ports, capsules, mass_kg,
## volume_l}.
##
## The shapes follow the catalogue look (the user's reference GLB has a
## 1½" sight glass 74 mm over its collars and 153 mm long, a 2" Alfa-Laval
## style butterfly 48 mm long with a 91 mm body, a 365 mm TC hot-water
## element, a 2" × 18" dephlegmator with ½" NPT water bosses). Lengths not
## in a fetched table are drawn to that look and listed in
## TcStandards.estimates().
##
## Valves carry a "stem" port on top (+Y, roll reference along the run) for
## an actuator; an actuator mates by its own stem port. Set "manual" off on
## a valve to drop its handle when an actuator drives it.

const STEEL := "steel"
const KG := TcStandards.STEEL_KG_M3 * 1e-9


static func _ring(r0: float, r1: float, z0: float, z1: float) -> Array:
	if r0 <= 0.0:
		return [Vector2(0, z0), Vector2(r1, z0), Vector2(r1, z1), Vector2(0, z1)]
	return [Vector2(r0, z1), Vector2(r0, z0), Vector2(r1, z0), Vector2(r1, z1), Vector2(r0, z1)]


static func _ring_kg(r0: float, r1: float, run: float) -> float:
	return PI * (r1 * r1 - r0 * r0) * run * KG


static func _p(id: String, kind: String, size: String, pos: Vector3, z: Vector3, x: Vector3 = Vector3.UP) -> Dictionary:
	return TcParts.port(id, kind, size, pos, z, x)


## Two clamp ends a and b along Z, `L` apart, with the hub of each drawn.
static func _ends(g: TcGeom, size: String, L: float, hub_k: float = 1.0) -> Array:
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	var pb := _p("b", "tc", size, Vector3(0, 0, L), Vector3(0, 0, 1))
	var hub := float(TcStandards.ferrule(size)["hub"]) * hub_k
	g.ferrule_end(TcParts.into_xform(pa), size, false, STEEL, hub)
	g.ferrule_end(TcParts.into_xform(pb), size, false, STEEL, hub)
	return [pa, pb, hub]


# ---------------------------------------------------------------------------
# Sight glass, column sections
# ---------------------------------------------------------------------------

## Borosilicate tube between two collars pulled together by four tie rods.
static func sight_glass(g: TcGeom, size: String, L: float) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var e := _ends(g, size, L)
	var hub: float = e[2]
	_window(g, size, hub, L - hub)
	return {"ports": [e[0], e[1]], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rf * 1.46]],
		"mass_kg": TcParts._flange_kg(size) * 2.0 + _ring_kg(float(t["r_out"]), rf * 1.46, 20.0) * 2.0,
		"volume_l": TcParts._bore_l_per_mm(size) * L}


## A glass window from z0 to z1: collars, glass tube, tie rods and nuts.
static func _window(g: TcGeom, size: String, z0: float, z1: float) -> void:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var ro := float(t["r_out"])
	var rc := rf * 1.46
	var n := TcGeom.segs_for(rc)
	g.lathe(STEEL, _ring(ro - 0.5, rc, z0, z0 + 10.0), Transform3D.IDENTITY, n)
	g.lathe(STEEL, _ring(ro - 0.5, rc, z1 - 10.0, z1), Transform3D.IDENTITY, n)
	var rg := ro + 1.5
	g.lathe("glass", [Vector2(rg, z0 + 10.0), Vector2(rg, z1 - 10.0)], Transform3D.IDENTITY, n)
	g.lathe("glass", [Vector2(rg - 3.0, z1 - 10.0), Vector2(rg - 3.0, z0 + 10.0)], Transform3D.IDENTITY, n)
	var rr := rc - 5.5
	for k in 4:
		var a := PI * 0.25 + PI * 0.5 * float(k)
		var c := Vector3(cos(a) * rr, sin(a) * rr, 0)
		g.cylinder("hardware", c + Vector3(0, 0, z0 - 4.0), c + Vector3(0, 0, z1 + 4.0), 2.6, 8)
		g.hex("hardware", c + Vector3(0, 0, z0 - 5.0), Vector3(0, 0, 1), 4.5, 8.0)
		g.hex("hardware", c + Vector3(0, 0, z1 + 0.5), Vector3(0, 0, 1), 4.5, 8.0)


## A column section: TC both ends, optionally a glass window over its middle
## half showing the packing.
static func column(g: TcGeom, size: String, L: float, window: bool, packing: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var e := _ends(g, size, L)
	var hub: float = e[2]
	if window and L > hub * 2.0 + 60.0:
		var w0 := hub + (L - 2.0 * hub) * 0.25
		var w1 := L - hub - (L - 2.0 * hub) * 0.25
		g.tube_body(Transform3D.IDENTITY, size, hub, w0)
		g.tube_body(Transform3D.IDENTITY, size, w1, L - hub)
		_window(g, size, w0, w1)
	else:
		g.tube_body(Transform3D.IDENTITY, size, hub, L - hub)
	if packing != "none":
		var mat := "copper" if packing == "copper_mesh" else "ceramic"
		var rp := float(t["r_in"]) * 0.96
		g.lathe(mat, _ring(0.0, rp, hub + 4.0, L - hub - 4.0), Transform3D.IDENTITY, TcGeom.segs_for(rp))
	return {"ports": [e[0], e[1]], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), float(t["r_flange"]) * (1.46 if window else 1.0)]],
		"mass_kg": TcParts._tube_kg_per_mm(size) * L + TcParts._flange_kg(size) * 2.0,
		"volume_l": TcParts._bore_l_per_mm(size) * L}


## A short glass section with a perforated plate, bubble caps and a
## downcomer.
static func bubble_plate(g: TcGeom, size: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var hub := float(TcStandards.ferrule(size)["hub"])
	var L := hub * 2.0 + 70.0
	var e := _ends(g, size, L)
	_window(g, size, hub, L - hub)
	var ri := float(t["r_in"])
	var zp := L * 0.5
	g.lathe(STEEL, _ring(0.0, ri * 0.97, zp - 1.5, zp + 1.5), Transform3D.IDENTITY, TcGeom.segs_for(ri))
	var cr := ri * 0.22
	for k in 3:
		var a := TAU * float(k) / 3.0
		var c := Vector3(cos(a) * ri * 0.45, sin(a) * ri * 0.45, 0)
		g.lathe("copper", [Vector2(0, zp + 1.5 + cr * 1.3), Vector2(cr, zp + 1.5 + cr * 1.3), Vector2(cr, zp + 3.0)],
			Transform3D(Basis.IDENTITY, c), 14)
	g.cylinder(STEEL, Vector3(-ri * 0.6, 0, zp - 25.0), Vector3(-ri * 0.6, 0, zp + 12.0), ri * 0.12, 10)
	return {"ports": [e[0], e[1]], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), float(t["r_flange"]) * 1.46]],
		"mass_kg": TcParts._flange_kg(size) * 2.0 + 0.4, "volume_l": TcParts._bore_l_per_mm(size) * L}


## Product tube in a cooling-water jacket (Liebig / dephlegmator): TC both
## ends, the jacket a size or more bigger, two ½" FNPT water bosses facing
## local +X (w1 near end a, w2 near end b).
static func dephlegmator(g: TcGeom, size: String, L: float, shell: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var e := _ends(g, size, L)
	var hub: float = e[2]
	var ts := TcStandards.tube(shell)
	var rs := maxf(float(ts["r_out"]), float(t["r_out"]) + 4.0)
	var j0 := hub + 12.0
	var j1 := L - hub - 12.0
	g.tube_body(Transform3D.IDENTITY, size, hub, j0)
	g.tube_body(Transform3D.IDENTITY, size, j1, L - hub)
	var n := TcGeom.segs_for(rs)
	g.lathe(STEEL, [Vector2(float(t["r_out"]), j0), Vector2(rs, j0 + 6.0), Vector2(rs, j1 - 6.0), Vector2(float(t["r_out"]), j1)],
		Transform3D.IDENTITY, n, 0.0, TAU, false)
	g.lathe(STEEL, [Vector2(float(t["r_in"]), j1), Vector2(float(t["r_in"]), j0)], Transform3D.IDENTITY, n)
	var ports: Array = [e[0], e[1]]
	var bod := TcStandards.npt_od("0.5")
	var boss := bod * 0.5 + 4.0
	for spec in [["w1", j0 + 30.0], ["w2", j1 - 30.0]]:
		var z := float(spec[1])
		var base := Vector3(rs - 2.0, 0, z)
		var face := Vector3(rs + 14.0, 0, z)
		g.lathe(STEEL, _ring(bod * 0.5 * 0.8, boss, 0.0, face.x - base.x),
			TcGeom.frame_along(base, Vector3.RIGHT), TcGeom.segs_for(boss))
		ports.append(_p(str(spec[0]), "npt_f", "0.5", face, Vector3.RIGHT, Vector3(0, 0, 1)))
	var jacket_kg := PI * 2.0 * rs * (j1 - j0) * 1.2 * KG
	return {"ports": ports, "capsules": [[Vector3.ZERO, Vector3(0, 0, L), maxf(rs, float(t["r_flange"]))]],
		"mass_kg": TcParts._tube_kg_per_mm(size) * L + TcParts._flange_kg(size) * 2.0 + jacket_kg,
		"volume_l": TcParts._bore_l_per_mm(size) * L, "jacket_l": PI * (rs * rs - pow(float(t["r_out"]), 2.0)) * (j1 - j0) * 1e-6}


# ---------------------------------------------------------------------------
# Valves and actuators
# ---------------------------------------------------------------------------

## The stem boss on top of a valve body centred at `at`, `top` mm above it,
## a lever (along the run when open) and the stem port for an actuator.
static func _stem(g: TcGeom, size: String, at: Vector3, top: float, manual: bool, handle_len: float, open: bool) -> Dictionary:
	var rf := float(TcStandards.tube(size)["r_flange"])
	var boss_h := 14.0
	g.cylinder(STEEL, at + Vector3(0, top - 2.0, 0), at + Vector3(0, top + boss_h, 0), clampf(rf * 0.22, 5.0, 14.0), 14)
	var sy := top + boss_h
	if manual:
		var dir := Vector3(0, 0, 1) if open else Vector3(1, 0, 0)
		var side := Vector3.UP.cross(dir).normalized()
		var c := at + Vector3(0, sy + 4.0, 0) + dir * handle_len * 0.5
		g.box(STEEL, Transform3D(Basis(side, Vector3.UP, dir), c), Vector3(4.0, 2.0, handle_len * 0.5))
		g.box("handle", Transform3D(Basis(side, Vector3.UP, dir), c + dir * handle_len * 0.32 + Vector3(0, 0.5, 0)),
			Vector3(6.0, 4.0, handle_len * 0.2))
	return _p("stem", "stem", TcStandards.clamp_class(size), at + Vector3(0, sy, 0), Vector3.UP, Vector3(0, 0, 1))


## Wafer butterfly valve between two clamp faces (Alfa-Laval style).
static func butterfly(g: TcGeom, size: String, open: bool, manual: bool) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var hub := float(TcStandards.ferrule(size)["hub"]) * 0.8
	var body := 14.0
	var L := hub * 2.0 + body
	var e := _ends(g, size, L, 0.8)
	var rb := rf * 1.42
	g.lathe(STEEL, _ring(float(t["r_out"]) - 0.5, rb, hub, hub + body), Transform3D.IDENTITY, TcGeom.segs_for(rb))
	var normal := Vector3.RIGHT if open else Vector3(0, 0, 1)
	var ri := float(t["r_in"]) * 0.96
	g.lathe(STEEL, _ring(0.0, ri, -1.5, 1.5), TcGeom.frame_along(Vector3(0, 0, L * 0.5) - normal * 0.0, normal), TcGeom.segs_for(ri))
	var stem := _stem(g, size, Vector3(0, 0, L * 0.5), rb, manual, rf * 2.6, open)
	g.cylinder(STEEL, Vector3(0, rb - 2.0, L * 0.5), Vector3(0, -rb + 2.0, L * 0.5), 3.0, 8)
	return {"ports": [e[0], e[1], stem], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rb]],
		"mass_kg": _ring_kg(float(t["r_out"]), rb, body) + TcParts._flange_kg(size) * 2.0 + 0.3,
		"volume_l": TcParts._bore_l_per_mm(size) * L}


## Ball valve with clamp ends: a bulged body, a stem and a lever (along the
## run when open). `three_way` adds an L-port branch c on +X.
static func ball_valve(g: TcGeom, size: String, three_way: bool, open: bool, manual: bool) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var ro := float(t["r_out"])
	var hub := float(TcStandards.ferrule(size)["hub"])
	var rb := rf * 0.98
	var c := hub + rb * 1.05
	var L := c * 2.0
	var e := _ends(g, size, L)
	var prof: Array = []
	var steps := 14
	for i in steps + 1:
		var u := -PI * 0.5 + PI * float(i) / float(steps)
		prof.append(Vector2(maxf(ro, rb * cos(u)), c + rb * 1.05 * sin(u)))
	prof.insert(0, Vector2(ro, hub))
	prof.append(Vector2(ro, L - hub))
	g.lathe(STEEL, prof, Transform3D.IDENTITY, TcGeom.segs_for(rb), 0.0, TAU, true)
	g.lathe(STEEL, [Vector2(float(t["r_in"]), L - hub), Vector2(float(t["r_in"]), hub)], Transform3D.IDENTITY, TcGeom.segs_for(rb))
	var ports: Array = [e[0], e[1]]
	var caps: Array = [[Vector3.ZERO, Vector3(0, 0, L), rb]]
	if three_way:
		var pc := _p("c", "tc", size, Vector3(c, 0, c), Vector3.RIGHT, Vector3.UP)
		var h := g.ferrule_end(TcParts.into_xform(pc), size)
		g.tube_body(TcGeom.frame_along(Vector3(0, 0, c), Vector3.RIGHT), size, rb * 0.6, c - h)
		ports.append(pc)
		caps.append([Vector3(0, 0, c), pc["pos"], rf])
	ports.append(_stem(g, size, Vector3(0, 0, c), rb * 1.02, manual, rf * 3.2, open))
	return {"ports": ports, "capsules": caps,
		"mass_kg": PI * 4.0 / 3.0 * pow(rb, 3.0) * 0.45 * KG + TcParts._flange_kg(size) * float(ports.size() - 1),
		"volume_l": TcParts._bore_l_per_mm(size) * L}


static func check_valve(g: TcGeom, size: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var hub := float(TcStandards.ferrule(size)["hub"])
	var L := hub * 2.0 + 44.0
	var e := _ends(g, size, L)
	var rb := rf * 0.98
	g.lathe(STEEL, [Vector2(float(t["r_out"]), hub), Vector2(rb, hub + 10.0), Vector2(rb, L - hub - 10.0),
		Vector2(float(t["r_out"]), L - hub)], Transform3D.IDENTITY, TcGeom.segs_for(rb), 0.0, TAU, true)
	g.lathe(STEEL, [Vector2(float(t["r_in"]), L - hub), Vector2(float(t["r_in"]), hub)], Transform3D.IDENTITY, TcGeom.segs_for(rb))
	# A flow arrow on top.
	g.box("dark", Transform3D(Basis.IDENTITY, Vector3(0, rb + 0.6, L * 0.5)), Vector3(1.5, 0.6, 9.0))
	return {"ports": [e[0], e[1]], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rb]],
		"mass_kg": _ring_kg(float(t["r_out"]), rb, L - 2.0 * hub) + TcParts._flange_kg(size) * 2.0,
		"volume_l": TcParts._bore_l_per_mm(size) * L}


static func diaphragm_valve(g: TcGeom, size: String, manual: bool) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var hub := float(TcStandards.ferrule(size)["hub"])
	var L := hub * 2.0 + rf * 2.2
	var e := _ends(g, size, L)
	g.tube_body(Transform3D.IDENTITY, size, hub, L - hub)
	var bw := rf * 1.05
	g.box(STEEL, Transform3D(Basis.IDENTITY, Vector3(0, float(t["r_out"]) * 0.6, L * 0.5)), Vector3(bw * 0.8, float(t["r_out"]) * 0.7, bw))
	var top := float(t["r_out"]) * 1.3
	g.box("dark", Transform3D(Basis.IDENTITY, Vector3(0, top + rf * 0.45, L * 0.5)), Vector3(bw * 0.7, rf * 0.45, bw * 0.85))
	var stem_y := top + rf * 0.9
	if manual:
		g.cylinder(STEEL, Vector3(0, stem_y, L * 0.5), Vector3(0, stem_y + 10.0, L * 0.5), 4.0, 10)
		g.lathe("dark", _ring(rf * 0.25, rf * 0.95, 0.0, 9.0), TcGeom.frame_along(Vector3(0, stem_y + 10.0, L * 0.5), Vector3.UP), 28)
	var stem := _p("stem", "stem", TcStandards.clamp_class(size), Vector3(0, stem_y, L * 0.5), Vector3.UP, Vector3(0, 0, 1))
	return {"ports": [e[0], e[1], stem], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rf], [Vector3(0, 0, L * 0.5), Vector3(0, stem_y, L * 0.5), bw]],
		"mass_kg": TcParts._tube_kg_per_mm(size) * L + TcParts._flange_kg(size) * 2.0 + 0.8,
		"volume_l": TcParts._bore_l_per_mm(size) * L}


## Pressure relief valve on a clamp face: spring body up the axis, a ½"
## FNPT outlet on the side.
static func relief_valve(g: TcGeom, size: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	var h := g.ferrule_end(TcParts.into_xform(pa), size)
	var rb := clampf(rf * 0.62, 12.0, 60.0)
	g.lathe(STEEL, [Vector2(float(t["r_out"]), h), Vector2(rb, h + 6.0), Vector2(rb, h + 46.0), Vector2(rb * 0.7, h + 52.0),
		Vector2(rb * 0.7, h + 92.0), Vector2(0.0, h + 96.0)], Transform3D.IDENTITY, TcGeom.segs_for(rb), 0.0, TAU, false)
	g.box("handle", Transform3D(Basis.IDENTITY, Vector3(0, 0, h + 99.0)), Vector3(rb * 0.9, 2.0, 3.0))
	var od := TcStandards.npt_od("0.5")
	var base := Vector3(rb - 2.0, 0, h + 26.0)
	var face := Vector3(rb + 16.0, 0, h + 26.0)
	g.lathe(STEEL, _ring(od * 0.4, od * 0.5 + 4.0, 0.0, face.x - base.x), TcGeom.frame_along(base, Vector3.RIGHT), 16)
	var pb := _p("b", "npt_f", "0.5", face, Vector3.RIGHT, Vector3(0, 0, 1))
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, h + 96.0), rb]],
		"mass_kg": TcParts._flange_kg(size) + _ring_kg(0.0, rb, 90.0) * 0.4, "volume_l": 0.0}


## Rack-and-pinion pneumatic actuator; mates a valve's stem by its own stem
## port (origin, facing −Z: the body stands up +Z). Two ¼" FNPT air ports.
static func actuator_pneumatic(g: TcGeom, size: String) -> Dictionary:
	var rf := float(TcStandards.tube(size)["r_flange"])
	var w := clampf(rf * 2.1, 45.0, 220.0)
	var hh := clampf(rf * 0.75, 18.0, 80.0)
	var bracket := 26.0
	g.box("hardware", Transform3D(Basis.IDENTITY, Vector3(0, 0, bracket * 0.5)), Vector3(hh * 0.8, hh * 0.5, bracket * 0.5))
	var cz := bracket + hh
	g.lathe("actuator", _ring(0.0, hh, -w, w), Transform3D(Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0)), Vector3(0, 0, cz)), 24)
	for sgn in [-1.0, 1.0]:
		g.lathe("dark", _ring(0.0, hh + 1.5, 0.0, 6.0), TcGeom.frame_along(Vector3(sgn * w, 0, cz), Vector3(sgn, 0, 0)), 24)
	g.cylinder("handle", Vector3(0, 0, cz + hh - 1.0), Vector3(0, 0, cz + hh + 10.0), hh * 0.35, 16)
	var ports: Array = [_p("stem", "stem", TcStandards.clamp_class(size), Vector3.ZERO, Vector3(0, 0, -1), Vector3(1, 0, 0))]
	var k := 0
	for sgn in [-1.0, 1.0]:
		k += 1
		var face := Vector3(sgn * w * 0.45, -hh - 6.0, cz)
		g.lathe(STEEL, _ring(4.0, 8.0, 0.0, 7.0), TcGeom.frame_along(face + Vector3(0, 7.0, 0), Vector3.DOWN), 12)
		ports.append(_p("air%d" % k, "npt_f", "0.25", face, Vector3.DOWN, Vector3(1, 0, 0)))
	return {"ports": ports, "capsules": [[Vector3(-w, 0, cz), Vector3(w, 0, cz), hh]],
		"mass_kg": PI * hh * hh * 2.0 * w * 0.35 * 2.7e-9 * 1000.0 + 0.3, "volume_l": 0.0}


static func actuator_electric(g: TcGeom, size: String) -> Dictionary:
	var rf := float(TcStandards.tube(size)["r_flange"])
	var s := clampf(rf * 1.1, 34.0, 120.0)
	var bracket := 26.0
	g.box("hardware", Transform3D(Basis.IDENTITY, Vector3(0, 0, bracket * 0.5)), Vector3(s * 0.35, s * 0.35, bracket * 0.5))
	g.box("actuator", Transform3D(Basis.IDENTITY, Vector3(0, 0, bracket + s)), Vector3(s, s * 0.85, s))
	g.lathe("actuator", _ring(0.0, s * 0.75, 0.0, s * 0.35), TcGeom.frame_along(Vector3(0, 0, bracket + 2.0 * s), Vector3(0, 0, 1)), 28)
	g.cylinder("handle", Vector3(0, 0, bracket + 2.35 * s), Vector3(0, 0, bracket + 2.35 * s + 6.0), s * 0.3, 16)
	g.lathe("dark", _ring(0.0, 7.0, 0.0, 16.0), TcGeom.frame_along(Vector3(s, 0, bracket + s * 0.6), Vector3.RIGHT), 12)
	return {"ports": [_p("stem", "stem", TcStandards.clamp_class(size), Vector3.ZERO, Vector3(0, 0, -1), Vector3(1, 0, 0))],
		"capsules": [[Vector3(0, 0, bracket), Vector3(0, 0, bracket + 2.4 * s), s * 1.1]], "mass_kg": 2.2, "volume_l": 0.0}


# ---------------------------------------------------------------------------
# Instruments
# ---------------------------------------------------------------------------

## The mount of an instrument: a clamp cap (port a, TC) or a male NPT
## thread with a hex (port a, npt_m). Returns [port, top z].
static func _mount(g: TcGeom, size: String, mount: String, npt: String) -> Array:
	if mount == "npt":
		var od := TcStandards.npt_od(npt)
		var tl := od * 0.75
		g.npt_thread(TcGeom.frame_along(Vector3(0, 0, tl), Vector3(0, 0, -1)), npt, tl)
		g.hex(STEEL, Vector3(0, 0, tl), Vector3(0, 0, 1), od * 0.45, od * 1.25)
		return [_p("a", "npt_m", npt, Vector3.ZERO, Vector3(0, 0, -1)), tl + od * 0.45]
	var cap := TcParts._cap(g, size, "")
	var top := float(((cap["capsules"] as Array)[0] as Array)[1].z)
	return [(cap["ports"] as Array)[0], top]


## Bimetal dial thermometer (3" dial facing up the stem) with a probe into
## the line.
static func thermometer(g: TcGeom, size: String, mount: String, npt: String, probe: float) -> Dictionary:
	var m := _mount(g, size, mount, npt)
	var top: float = m[1]
	g.cylinder(STEEL, Vector3(0, 0, top), Vector3(0, 0, top + 22.0), 4.0, 10)
	var r := 38.0
	var z0 := top + 22.0
	g.lathe(STEEL, [Vector2(0, z0), Vector2(r, z0 + 2.0), Vector2(r, z0 + 16.0), Vector2(r - 3.0, z0 + 18.0)], Transform3D.IDENTITY, 36)
	g.lathe("dial", _ring(0.0, r - 3.0, z0 + 14.0, z0 + 15.0), Transform3D.IDENTITY, 36)
	g.box("dark", Transform3D(Basis(Vector3.UP, 0.6), Vector3(0, 0, z0 + 15.6)), Vector3(r * 0.42, 1.0, 0.6))
	g.cylinder(STEEL, Vector3(0, 0, 0.5), Vector3(0, 0, -probe), 3.2, 10)
	return {"ports": [m[0]], "capsules": [[Vector3(0, 0, top), Vector3(0, 0, z0 + 18.0), r]],
		"mass_kg": 0.35, "volume_l": 0.0}


## Bourdon pressure gauge (2½" dial, bottom connection: the dial faces +Y).
static func gauge(g: TcGeom, size: String, mount: String, npt: String) -> Dictionary:
	var m := _mount(g, size, mount, npt)
	var top: float = m[1]
	var r := 32.0
	g.cylinder(STEEL, Vector3(0, 0, top), Vector3(0, 0, top + 14.0), 5.0, 10)
	if mount == "npt":
		# On a threaded bung the gauge is back-connected: the dial faces out
		# along the stem, like the thermometer.
		var xb := TcGeom.frame_along(Vector3(0, 0, top + 14.0), Vector3(0, 0, 1))
		g.lathe(STEEL, [Vector2(0, 0), Vector2(r, 2.0), Vector2(r, 18.0), Vector2(r - 3.0, 20.0)], xb, 36)
		g.lathe("dial", _ring(0.0, r - 3.0, 16.0, 17.0), xb, 36)
		g.box("dark", Transform3D(Basis(Vector3(0, 0, 1), 0.9), Vector3(0, 0, top + 14.0 + 17.6)), Vector3(r * 0.4, 1.0, 0.6))
		return {"ports": [m[0]], "capsules": [[Vector3(0, 0, top), Vector3(0, 0, top + 34.0), r]], "mass_kg": 0.3, "volume_l": 0.0}
	var c := Vector3(0, 0, top + 14.0 + r)
	var xf := TcGeom.frame_along(c - Vector3(0, 10, 0), Vector3.UP)
	g.lathe(STEEL, [Vector2(0, 0), Vector2(r, 0), Vector2(r, 18.0), Vector2(r - 3.0, 20.0)], xf, 36)
	g.lathe("dial", _ring(0.0, r - 3.0, 16.0, 17.0), xf, 36)
	g.box("dark", Transform3D(Basis.IDENTITY, c + Vector3(r * 0.2, 7.6, 0)), Vector3(r * 0.4, 0.6, 1.0))
	return {"ports": [m[0]], "capsules": [[Vector3(0, 0, top), c, r]], "mass_kg": 0.3, "volume_l": 0.0}


## Thermowell on a clamp cap: a closed tube into the line, ½" FNPT on top
## for a probe.
static func thermowell(g: TcGeom, size: String, length: float) -> Dictionary:
	var cap := TcParts._cap(g, size, "0.5")
	g.lathe(STEEL, [Vector2(0, -length), Vector2(5.0, -length + 3.0), Vector2(6.5, 0.0)], Transform3D.IDENTITY, 12)
	return {"ports": cap["ports"], "capsules": cap["capsules"], "mass_kg": float(cap["mass_kg"]) + 0.08, "volume_l": 0.0}


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------

static func inline_strainer(g: TcGeom, size: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var hub := float(TcStandards.ferrule(size)["hub"])
	var L := hub * 2.0 + rf * 2.6
	var e := _ends(g, size, L)
	var rb := rf * 1.02
	g.lathe(STEEL, [Vector2(float(t["r_out"]), hub), Vector2(rb, hub + 14.0), Vector2(rb, L - hub - 14.0),
		Vector2(float(t["r_out"]), L - hub)], Transform3D.IDENTITY, TcGeom.segs_for(rb), 0.0, TAU, true)
	g.lathe("mesh", _ring(0.0, float(t["r_in"]) * 0.9, hub + 2.0, hub + 3.0), Transform3D.IDENTITY, 24)
	return {"ports": [e[0], e[1]], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rb]],
		"mass_kg": _ring_kg(float(t["r_out"]), rb, L - 2.0 * hub) * 0.4 + TcParts._flange_kg(size) * 2.0,
		"volume_l": PI * rb * rb * (L - 2.0 * hub) * 1e-6}


## Y strainer: the run along Z, the screen leg 45° down (−Y) closed by a cap.
static func y_strainer(g: TcGeom, size: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var hub := float(TcStandards.ferrule(size)["hub"])
	var L := hub * 2.0 + rf * 2.4
	var e := _ends(g, size, L)
	g.tube_body(Transform3D.IDENTITY, size, hub, L - hub)
	var dir := Vector3(0, -1, 1).normalized()
	var leg := rf * 2.4
	var c := Vector3(0, 0, L * 0.42)
	var rl := float(t["r_out"]) * 1.05
	g.lathe(STEEL, [Vector2(rl, 0.0), Vector2(rl, leg)], TcGeom.frame_along(c, dir), TcGeom.segs_for(rl))
	g.lathe(STEEL, _ring(0.0, rf, leg, leg + 6.0), TcGeom.frame_along(c, dir), TcGeom.segs_for(rf))
	g.hex(STEEL, c + dir * (leg + 6.0), dir, 7.0, rf * 0.7)
	return {"ports": [e[0], e[1]], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rf], [c, c + dir * (leg + 13.0), rf]],
		"mass_kg": TcParts._tube_kg_per_mm(size) * (L + leg) + TcParts._flange_kg(size) * 2.0 + 0.2,
		"volume_l": TcParts._bore_l_per_mm(size) * (L + leg)}


## Cartridge filter housing: the head carries ports a (−X) and b (+X), the
## bowl hangs below (−Y) to fit `element` mm, a ¼" FNPT drain at the bottom.
static func cartridge_housing(g: TcGeom, size: String, element: float) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var rh := maxf(rf * 1.5, 45.0)
	var hh := rf * 0.9
	var hub := float(TcStandards.ferrule(size)["hub"])
	var c := rh + hub + 6.0
	g.lathe(STEEL, _ring(0.0, rh, -hh, hh), TcGeom.frame_along(Vector3.ZERO, Vector3.UP), TcGeom.segs_for(rh))
	var pa := _p("a", "tc", size, Vector3(-c, 0, 0), Vector3(-1, 0, 0), Vector3.UP)
	var pb := _p("b", "tc", size, Vector3(c, 0, 0), Vector3(1, 0, 0), Vector3.UP)
	for p in [pa, pb]:
		var h := g.ferrule_end(TcParts.into_xform(p), size)
		var into := -(p["z"] as Vector3)
		g.tube_body(TcGeom.frame_along(p["pos"], into), size, h, c - rh + 4.0)
	var rbowl := rh * 0.9
	var depth := element + 40.0
	g.lathe(STEEL, [Vector2(rbowl, -hh), Vector2(rbowl, -hh - depth + rbowl * 0.3), Vector2(rbowl * 0.7, -hh - depth),
		Vector2(0.0, -hh - depth - 3.0)], TcGeom.frame_along(Vector3.ZERO, Vector3.UP), TcGeom.segs_for(rbowl),
		0.0, TAU, true)
	g.lathe("dark", _ring(rbowl, rbowl + 4.0, -hh - 14.0, -hh), TcGeom.frame_along(Vector3.ZERO, Vector3.UP), TcGeom.segs_for(rbowl))
	var dface := Vector3(0, -hh - depth - 3.0 - 12.0, 0)
	g.lathe(STEEL, _ring(4.0, 9.0, 0.0, 12.0), TcGeom.frame_along(dface, Vector3.UP), 12)
	var pd := _p("drain", "npt_f", "0.25", dface, Vector3.DOWN, Vector3(1, 0, 0))
	return {"ports": [pa, pb, pd], "capsules": [[pa["pos"], pb["pos"], rf], [Vector3(0, hh, 0), Vector3(0, -hh - depth, 0), rh]],
		"mass_kg": 1.2 + element * 0.004, "volume_l": PI * rbowl * rbowl * depth * 1e-6}


# ---------------------------------------------------------------------------
# Brewing and process
# ---------------------------------------------------------------------------

## A strainer basket hung through a clamp port (wort / hop strainer): the
## face at the origin facing −Z, the basket hanging on beyond it (−Z, into
## the vessel), a bail handle on the outside.
static func strainer_basket(g: TcGeom, size: String, depth: float) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var ri := float(t["r_in"])
	var f := TcStandards.ferrule(size)
	g.lathe(STEEL, _ring(ri * 0.9, rf, 0.0, float(f["rim"]) + 1.0), Transform3D.IDENTITY, TcGeom.segs_for(rf))
	var rb := ri * 0.88
	var n := TcGeom.segs_for(rb)
	g.lathe("mesh", [Vector2(0.0, -depth), Vector2(rb, -depth), Vector2(rb, 0.0)], Transform3D.IDENTITY, n)
	g.lathe("mesh", [Vector2(rb - 1.0, 0.0), Vector2(rb - 1.0, -depth + 1.0), Vector2(0.0, -depth + 1.0)], Transform3D.IDENTITY, n)
	var path := PackedVector3Array()
	for i in 13:
		var a := PI * float(i) / 12.0
		path.append(Vector3(cos(a) * ri * 0.85, 0, float(f["rim"]) + 1.0 + sin(a) * ri * 0.7))
	g.sweep(STEEL, path, 1.6, true, 8)
	return {"ports": [_p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))],
		"capsules": [[Vector3.ZERO, Vector3(0, 0, ri * 0.7), rf]], "mass_kg": 0.25 + depth * 0.001, "volume_l": 0.0}


## A funnel / hopper: the clamp end at the bottom (port a, facing −Z), the
## cone opening up to a rolled rim.
static func funnel(g: TcGeom, size: String, rim_d: float, height: float) -> Dictionary:
	var t := TcStandards.tube(size)
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	var h := g.ferrule_end(TcParts.into_xform(pa), size)
	var R := maxf(rim_d * 0.5, float(t["r_out"]) + 10.0)
	var n := TcGeom.segs_for(R)
	g.lathe(STEEL, [Vector2(float(t["r_out"]), h), Vector2(R, h + height)], Transform3D.IDENTITY, n)
	g.lathe(STEEL, [Vector2(R - 1.5, h + height), Vector2(float(t["r_in"]), h)], Transform3D.IDENTITY, n)
	g.lathe(STEEL, [Vector2(R - 1.5, h + height), Vector2(R + 1.5, h + height + 2.0), Vector2(R + 3.0, h + height),
		Vector2(R, h + height - 2.5)], Transform3D.IDENTITY, n, 0.0, TAU, true)
	var area := PI * (R + float(t["r_out"])) * sqrt(pow(R - float(t["r_out"]), 2.0) + height * height)
	return {"ports": [pa], "capsules": [[Vector3.ZERO, Vector3(0, 0, h + height), (R + float(t["r_out"])) * 0.5]],
		"mass_kg": area * 1.2 * KG + TcParts._flange_kg(size),
		"volume_l": PI * height * (R * R + R * float(t["r_in"]) + pow(float(t["r_in"]), 2.0)) / 3.0 * 1e-6}


## CIP spray ball through a clamp port (into the vessel, −Z).
static func spray_ball(g: TcGeom, size: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var f := TcStandards.ferrule(size)
	g.lathe(STEEL, _ring(0.0, rf, 0.0, float(f["rim"]) + 1.0), Transform3D.IDENTITY, TcGeom.segs_for(rf))
	var rt := float(t["r_out"]) * 0.45
	g.lathe(STEEL, _ring(0.0, rt, -60.0, 0.0), Transform3D.IDENTITY, 16)
	var rb := clampf(rf * 0.55, 14.0, 60.0)
	var prof: Array = []
	for i in 13:
		var u := PI * 0.5 - PI * float(i) / 12.0
		prof.append(Vector2(rb * cos(u), -60.0 - rb + rb * sin(u)))
	prof.reverse()
	g.lathe(STEEL, prof, Transform3D.IDENTITY, 24, 0.0, TAU, true)
	for k in 10:
		var a := TAU * float(k) / 10.0
		var p := Vector3(cos(a) * rb * 0.95, sin(a) * rb * 0.95, -60.0 - rb * 0.7)
		g.box("dark", Transform3D(Basis.IDENTITY, p), Vector3(1.0, 1.0, 1.0))
	return {"ports": [_p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))],
		"capsules": [[Vector3.ZERO, Vector3(0, 0, float(f["rim"])), rf]], "mass_kg": 0.3, "volume_l": 0.0}


## TC immersion heating element (hot-water style): the clamp face at the
## origin facing −Z, the terminal head outside (+Z), two folded U loops
## reaching `length` mm through the port into the vessel (−Z).
static func heating_element(g: TcGeom, size: String, length: float) -> Dictionary:
	var t := TcStandards.tube(size)
	var rf := float(t["r_flange"])
	var f := TcStandards.ferrule(size)
	var thick := float(f["rim"]) + 2.0
	g.lathe(STEEL, _ring(0.0, rf, 0.0, thick), Transform3D.IDENTITY, TcGeom.segs_for(rf))
	var rh := rf * 0.82
	g.lathe("dark", [Vector2(0, thick), Vector2(rh, thick), Vector2(rh, thick + 46.0), Vector2(rh * 0.9, thick + 52.0),
		Vector2(0.0, thick + 52.0)], Transform3D.IDENTITY, TcGeom.segs_for(rh))
	g.lathe("dark", _ring(0.0, 8.0, 0.0, 16.0), TcGeom.frame_along(Vector3(rh, 0, thick + 26.0), Vector3.RIGHT), 12)
	var ri := float(t["r_in"])
	var spread := [ri * 0.62, ri * 0.22]
	for s in spread:
		var a := float(s)
		var path := PackedVector3Array()
		path.append(Vector3(-a, 0, 0))
		path.append(Vector3(-a, 0, -length + a))
		var arc := TcGeom.arc_points(Vector3(0, 0, -length + a), Vector3(-a, 0, -length + a), Vector3.UP, PI, 10)
		for i in range(1, arc.size()):
			path.append(arc[i])
		path.append(Vector3(a, 0, 0))
		g.sweep(STEEL, path, 4.2, true, 10)
	return {"ports": [_p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))],
		"capsules": [[Vector3.ZERO, Vector3(0, 0, thick + 52.0), rf]], "mass_kg": 0.9, "volume_l": 0.0,
		"reach_mm": length}
