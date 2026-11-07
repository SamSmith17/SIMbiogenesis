class_name TcUnits
extends RefCounted

## Process units for the TC designer (Phase 8 of plans/TC_PROCESS_LAB_PLAN.md):
## the pieces downstream of a reactor that turn its gas into power, so the
## whole chain — reactor, condenser, holder, dryer, engine — is one assembly
## the Process Lab runs end to end.
##
##   gas_holder  a water-sealed bell holder: the bell rises as gas comes in
##               and holds it at its weight's pressure (`hold_kpa`) until it
##               is full; a and b on the side, low.
##   dryer       a column packed with silica gel (or activated carbon) that
##               takes the water vapour out of the gas until it is spent.
##   genset      a small engine-generator (48 V DC) with a clamp gas inlet:
##               burns the gas at `rated_kw` / `efficiency` while it runs.
##   flare       a stack with a flame arrestor that burns what reaches it.
##
## Frames (mm): port a at the origin facing −Z, the unit beyond it (+Z).
## Sizes and masses are estimates (no catalogue fetched); the selftest lists
## them. Each returns {ports, capsules, mass_kg, volume_l, unit} where `unit`
## is what TcFlowPaths hands the Process Lab.

const STEEL := "steel"
const SEAL_DEPTH := 0.45        # share of the bell standing in the water seal
const DESICCANT_BULK := 0.70    # kg/L, silica gel beads (bulk)
const CARBON_BULK := 0.45       # kg/L, granular activated carbon
const PACKINGS := [["silica", "Silica gel"], ["carbon", "Activated carbon"]]


static func _p(id: String, kind: String, size: String, pos: Vector3, z: Vector3, x: Vector3 = Vector3.UP) -> Dictionary:
	return TcParts.port(id, kind, size, pos, z, x)


static func _stub(g: TcGeom, size: String, p: Dictionary, length: float) -> void:
	var hub := g.ferrule_end(TcParts.into_xform(p), size)
	var into := -(p["z"] as Vector3)
	g.tube_body(TcGeom.frame_along(p["pos"], into), size, hub, length)


## A bell gas holder of `cap_l` litres: a water tank and a painted bell
## (height 1.4 × its radius). Port a enters the tank's side low down, b leaves
## the other side.
static func gas_holder(g: TcGeom, size: String, cap_l: float, hold_kpa: float) -> Dictionary:
	var rf := float(TcStandards.tube(size)["r_flange"])
	var R := pow(cap_l * 1.0e6 / (1.4 * PI), 1.0 / 3.0)
	var H := R * 1.4
	var stub := 90.0
	var cx := stub + R + 20.0
	var c := Vector3(0, 0, cx)
	var base_y := -rf - 60.0
	var up := TcGeom.frame_along(c + Vector3(0, base_y, 0), Vector3.UP)
	# Tank (open top), the water in it, the bell, the bell's guide posts.
	var tank_h := H * (SEAL_DEPTH + 0.15)
	g.lathe(STEEL, [Vector2(0, 0), Vector2(R + 22.0, 0), Vector2(R + 22.0, tank_h), Vector2(R + 18.0, tank_h),
		Vector2(R + 18.0, 3.0), Vector2(0, 3.0)], up, TcGeom.segs_for(R))
	var bell_y := tank_h * 0.35
	var bell := TcGeom.frame_along(c + Vector3(0, base_y + bell_y, 0), Vector3.UP)
	g.lathe("actuator", [Vector2(R, 0), Vector2(R, H), Vector2(R * 0.92, H + R * 0.08), Vector2(0, H + R * 0.1)], bell, TcGeom.segs_for(R))
	for k in 3:
		var a := TAU * float(k) / 3.0 + 0.4
		var o := c + Vector3(cos(a) * (R + 40.0), base_y, sin(a) * (R + 40.0))
		g.cylinder("hardware", o, o + Vector3(0, H + tank_h, 0), 9.0, 10)
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	_stub(g, size, pa, cx - R - 15.0)
	var pb := _p("b", "tc", size, Vector3(0, 0, 2.0 * cx), Vector3(0, 0, 1))
	_stub(g, size, pb, cx - R - 15.0)
	var area := 2.0 * PI * R * (H + tank_h) + 2.0 * PI * R * R
	return {"ports": [pa, pb], "capsules": [[c + Vector3(0, base_y, 0), c + Vector3(0, base_y + H + tank_h, 0), R + 22.0],
			[Vector3.ZERO, Vector3(0, 0, 2.0 * cx), rf]],
		"mass_kg": area * 1.5 * TcStandards.STEEL_KG_M3 * 1e-9 + 8.0, "volume_l": cap_l,
		"unit": {"kind": "holder", "cap_l": cap_l, "hold_kpa": hold_kpa}}


## A packed drying column between two clamp ends, with a window.
static func dryer(g: TcGeom, size: String, L: float, packing: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var r := TcSpecialty.column(g, size, L, true, "none")
	var hub := float(TcStandards.ferrule(size)["hub"])
	var rp := float(t["r_in"]) * 0.96
	g.lathe("desiccant" if packing == "silica" else "carbon", TcSpecialty._ring(0.0, rp, hub + 4.0, L - hub - 4.0),
		Transform3D.IDENTITY, TcGeom.segs_for(rp))
	var bed_l := PI * rp * rp * maxf(L - 2.0 * hub - 8.0, 1.0) * 1e-6
	var kg := bed_l * (DESICCANT_BULK if packing == "silica" else CARBON_BULK)
	r["mass_kg"] = float(r["mass_kg"]) + kg
	r["volume_l"] = float(r["volume_l"]) * 0.4   # the gas between the beads
	r["unit"] = {"kind": "dryer", "packing": packing, "sorbent_kg": kg}
	return r


## A 48 V DC genset on a skid: engine block, alternator, exhaust, the gas
## inlet on the clamp end a. Sized with its rating (a 2.5 kW unit is about
## 600 × 450 × 480 mm).
static func genset(g: TcGeom, size: String, rated_kw: float, efficiency: float) -> Dictionary:
	var s := pow(maxf(rated_kw, 0.3) / 2.5, 1.0 / 3.0)
	var bx := 450.0 * s
	var by := 480.0 * s
	var bz := 600.0 * s
	var stub := 120.0
	var c := Vector3(0, by * 0.5 - 140.0 * s, stub + bz * 0.5)
	g.box("actuator", Transform3D(Basis.IDENTITY, c), Vector3(bx * 0.5, by * 0.5, bz * 0.5) * Vector3(0.9, 0.8, 0.55))
	g.box("dark", Transform3D(Basis.IDENTITY, c + Vector3(0, -by * 0.48, 0)), Vector3(bx * 0.55, 18.0, bz * 0.55))
	var alt0 := c + Vector3(0, -by * 0.05, bz * 0.27)
	g.cylinder("hardware", alt0, alt0 + Vector3(0, 0, bz * 0.3), by * 0.22, 20)
	var ex := c + Vector3(bx * 0.3, by * 0.4, -bz * 0.1)
	g.cylinder("dark", ex, ex + Vector3(0, by * 0.6, 0), 22.0 * s, 12)
	g.box("dark", Transform3D(Basis.IDENTITY, c + Vector3(-bx * 0.47, by * 0.1, 0)), Vector3(8.0, by * 0.18, bz * 0.18))
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	_stub(g, size, pa, stub + 20.0)
	return {"ports": [pa], "capsules": [[Vector3(0, c.y, stub + 40.0), Vector3(0, c.y, stub + bz * 0.9), maxf(bx, by) * 0.5]],
		"mass_kg": 25.0 + 22.0 * rated_kw, "volume_l": 0.6,
		"unit": {"kind": "engine", "rated_kw": rated_kw, "efficiency": efficiency}}


## A flare stack: a flame arrestor on the inlet, the stack up, a wind shield
## at the tip.
static func flare(g: TcGeom, size: String, height: float) -> Dictionary:
	var rf := float(TcStandards.tube(size)["r_flange"])
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	var run := 140.0
	_stub(g, size, pa, run)
	var foot := Vector3(0, 0, run)
	g.lathe("mesh", TcSpecialty._ring(0.0, rf * 1.3, -40.0, 40.0), TcGeom.frame_along(foot, Vector3.UP), TcGeom.segs_for(rf))
	var top := foot + Vector3(0, height, 0)
	g.lathe(STEEL, [Vector2(rf * 0.9, 40.0), Vector2(rf * 0.9, height)], TcGeom.frame_along(foot, Vector3.UP), TcGeom.segs_for(rf))
	g.lathe("dark", [Vector2(rf * 1.6, 0.0), Vector2(rf * 1.6, 90.0)], TcGeom.frame_along(top - Vector3(0, 40.0, 0), Vector3.UP), TcGeom.segs_for(rf))
	for k in 3:
		var a := TAU * float(k) / 3.0
		var o := foot + Vector3(cos(a) * rf * 3.0, -60.0, sin(a) * rf * 3.0)
		g.cylinder("hardware", o, foot + Vector3(cos(a) * rf, height * 0.3, sin(a) * rf), 5.0, 8)
	return {"ports": [pa], "capsules": [[Vector3.ZERO, foot, rf], [foot, top, rf * 1.6]],
		"mass_kg": 4.0 + height * 0.004, "volume_l": PI * pow(rf * 0.9, 2.0) * height * 1e-6,
		"unit": {"kind": "flare"}}
