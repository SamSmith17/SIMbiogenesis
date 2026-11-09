class_name TcUnits
extends RefCounted

## Process units for the TC designer (Phase 8 of plans/TC_PROCESS_LAB_PLAN.md):
## the pieces downstream of a reactor that turn its gas into power, so the
## whole chain — reactor, condenser, holder, dryer, engine — is one assembly
## the Process Lab runs end to end.
##
##   gas_holder  a water-sealed holder: the float rises as gas comes in and
##               holds it at its weight's pressure (`hold_kpa`) until it is
##               full; a and b on the side, low. Barrel-in-barrel (30 or
##               55 gal base) or a steel tank and bell.
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


## What a gas holder is built as. The barrel-in-barrel gasometers follow the
## user's model ("Gasometer-low poly.glb", measured 2026-11-08): an open
## 30-gallon barrel of water (Ø526 × 866 mm as modelled) with a 15-gallon
## barrel upside down in it (Ø382 × 730 mm) that floats up on the gas; a
## 1½" riser stands up the middle of the base and a 2" tube hanging from
## the float's top sleeves over it, so the float rises straight; bulkhead
## fittings on the float's top. The 55-gallon version is the same build one
## size up: a 55-gallon drum (23 × 34.5 in) with a 30-gallon barrel
## (19 × 29 in) as the float. "bell" is the older welded tank and bell.
const HOLDER_STYLES := [["barrel_30", "Barrel in barrel: 30 gal base, 15 gal float"],
	["barrel_55", "Barrel in barrel: 55 gal base, 30 gal float"], ["bell", "Steel tank and bell (any size)"]]
## mm and litres: the base barrel, the float, the float's own volume and mass.
const BARRELS := {
	"barrel_30": {"base_d": 526.0, "base_h": 866.0, "float_d": 382.0, "float_h": 730.0, "float_l": 56.8, "float_kg": 3.0, "base_kg": 4.5},
	"barrel_55": {"base_d": 585.0, "base_h": 880.0, "float_d": 480.0, "float_h": 740.0, "float_l": 113.6, "float_kg": 4.5, "base_kg": 9.0},
}
## The share of the float's volume that holds gas between resting on the
## bottom and its rim still a hand deep in the water (an estimate; the
## model is drawn raised 440 mm, which is 0.8 of a 15-gallon barrel).
const BARREL_USABLE := 0.8
const BARREL_WALL := 5.0
const FLOAT_REST := 20.0        # the float's rim above the base's floor when empty
## How far up its travel a holder is drawn in the design (the model's pose).
const HOLDER_SHOWN := 0.75


static func is_barrel(style: String) -> bool:
	return BARRELS.has(style)


## Gas a barrel gasometer holds (L).
static func barrel_capacity_l(style: String) -> float:
	return float(BARRELS[style]["float_l"]) * BARREL_USABLE if BARRELS.has(style) else 0.0


## The gauge pressure a barrel's float keeps the gas at (kPa): its weight
## over its area.
static func barrel_hold_kpa(style: String) -> float:
	if not BARRELS.has(style):
		return 0.8
	var b: Dictionary = BARRELS[style]
	var r := float(b["float_d"]) * 0.0005
	return float(b["float_kg"]) * 9.81 / (PI * r * r) * 0.001


## How far a holder's float rises from empty to full (mm).
static func holder_stroke_mm(style: String, cap_l: float) -> float:
	if BARRELS.has(style):
		var r := float(BARRELS[style]["float_d"]) * 0.5 - BARREL_WALL
		return barrel_capacity_l(style) * 1.0e6 / (PI * r * r)
	var R := pow(cap_l * 1.0e6 / (1.4 * PI), 1.0 / 3.0)
	return R * 1.4 * 0.5


## A gas holder. `what`: "all" (the design's part: the base and the float
## drawn HOLDER_SHOWN of the way up), "base", or "float" (the moving part
## alone at `lift` mm above empty: the Process view draws it where the gas
## has it). Port a enters low on one side, b leaves the other. The float's
## surfaces use the material keys "bell" / "bell_trim", which the Process
## view hides on the built part while it draws the live one.
static func gas_holder(g: TcGeom, size: String, cap_l: float, hold_kpa: float, style: String = "bell",
		what: String = "all", lift: float = -1.0) -> Dictionary:
	if BARRELS.has(style):
		return _barrel_holder(g, size, hold_kpa, style, what, lift)
	var rf := float(TcStandards.tube(size)["r_flange"])
	var R := pow(cap_l * 1.0e6 / (1.4 * PI), 1.0 / 3.0)
	var H := R * 1.4
	var stub := 90.0
	var cx := stub + R + 20.0
	var c := Vector3(0, 0, cx)
	var base_y := -rf - 60.0
	var up := TcGeom.frame_along(c + Vector3(0, base_y, 0), Vector3.UP)
	var tank_h := H * (SEAL_DEPTH + 0.15)
	var stroke := holder_stroke_mm(style, cap_l)
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	var pb := _p("b", "tc", size, Vector3(0, 0, 2.0 * cx), Vector3(0, 0, 1))
	if what != "float":
		# Tank (open top), the bell's guide posts, the two stubs.
		g.lathe(STEEL, [Vector2(0, 0), Vector2(R + 22.0, 0), Vector2(R + 22.0, tank_h), Vector2(R + 18.0, tank_h),
			Vector2(R + 18.0, 3.0), Vector2(0, 3.0)], up, TcGeom.segs_for(R))
		for k in 3:
			var a := TAU * float(k) / 3.0 + 0.4
			var o := c + Vector3(cos(a) * (R + 40.0), base_y, sin(a) * (R + 40.0))
			g.cylinder("hardware", o, o + Vector3(0, H + tank_h + stroke, 0), 9.0, 10)
		_stub(g, size, pa, cx - R - 15.0)
		_stub(g, size, pb, cx - R - 15.0)
	if what != "base":
		var l := lift if lift >= 0.0 else stroke * HOLDER_SHOWN
		var bell := TcGeom.frame_along(c + Vector3(0, base_y + tank_h * 0.2 + l, 0), Vector3.UP)
		g.lathe("bell", [Vector2(R, 0), Vector2(R, H), Vector2(R * 0.92, H + R * 0.08), Vector2(0, H + R * 0.1)], bell, TcGeom.segs_for(R))
	var area := 2.0 * PI * R * (H + tank_h) + 2.0 * PI * R * R
	return {"ports": [pa, pb], "capsules": [[c + Vector3(0, base_y, 0), c + Vector3(0, base_y + H + tank_h + stroke, 0), R + 22.0],
			[Vector3.ZERO, Vector3(0, 0, 2.0 * cx), rf]],
		"mass_kg": area * 1.5 * TcStandards.STEEL_KG_M3 * 1e-9 + 8.0, "volume_l": cap_l,
		"unit": {"kind": "holder", "cap_l": cap_l, "hold_kpa": hold_kpa, "style": style, "stroke_mm": stroke}}


## A plastic barrel's wall as a lathe outline (solid on the left): radius R,
## height H, two rolling hoops, a closed floor at z = 0 and an open top.
static func _barrel_outline(R: float, H: float, w: float) -> Array:
	var out: Array = [Vector2(0, 0), Vector2(R - 12.0, 0), Vector2(R, 12.0)]
	for f in [0.33, 0.67]:
		var y: float = H * f
		out.append_array([Vector2(R, y - 22.0), Vector2(R + 7.0, y - 9.0), Vector2(R + 7.0, y + 9.0), Vector2(R, y + 22.0)])
	out.append_array([Vector2(R, H - 14.0), Vector2(R + 5.0, H - 8.0), Vector2(R + 5.0, H), Vector2(R - w, H),
		Vector2(R - w, w), Vector2(0, w)])
	return out


static func _barrel_holder(g: TcGeom, size: String, hold_kpa: float, style: String, what: String, lift: float) -> Dictionary:
	var b: Dictionary = BARRELS[style]
	var rf := float(TcStandards.tube(size)["r_flange"])
	var Rb := float(b["base_d"]) * 0.5
	var Hb := float(b["base_h"])
	var Rf := float(b["float_d"]) * 0.5
	var Hf := float(b["float_h"])
	var w := BARREL_WALL
	var cap_l := barrel_capacity_l(style)
	var stroke := holder_stroke_mm(style, cap_l)
	var stub := 90.0
	var cx := stub + Rb + 20.0
	var base_y := -rf - 60.0
	var foot := Vector3(0, base_y, cx)
	var up := TcGeom.frame_along(foot, Vector3.UP)
	var n := TcGeom.segs_for(Rb)
	var riser_r := 24.1          # 1½" schedule 40 PVC, 1.900 in OD
	var sleeve_r := 30.2         # 2" schedule 40 PVC, 2.375 in OD
	var riser_h := Hb * 0.85
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	var pb := _p("b", "tc", size, Vector3(0, 0, 2.0 * cx), Vector3(0, 0, 1))
	if what != "float":
		g.lathe("drum", _barrel_outline(Rb, Hb, w), up, n, 0.0, TAU, false)
		# The water, seen in the gap round the float.
		g.lathe("water", TcSpecialty._ring(0.0, Rb - w, Hb * 0.90, Hb * 0.90 + 1.0), up, n)
		# The cut-out lid: a ring that keeps the float upright.
		g.lathe("drum_dark", TcSpecialty._ring(Rf + 9.0, Rb - w - 1.0, Hb - 30.0, Hb - 12.0), up, n)
		# The riser up the middle (the gas comes up it, above the water).
		g.lathe("pvc", TcSpecialty._ring(riser_r - 3.7, riser_r, w, riser_h), up, 18)
		_stub(g, size, pa, cx - Rb - 15.0)
		_stub(g, size, pb, cx - Rb - 15.0)
	if what != "base":
		var l := lift if lift >= 0.0 else stroke * HOLDER_SHOWN
		# The float: a barrel upside down (its floor is the top).
		var top := foot + Vector3(0, FLOAT_REST + l + Hf, 0)
		g.lathe("bell", _barrel_outline(Rf, Hf, w), TcGeom.frame_along(top, Vector3.DOWN), TcGeom.segs_for(Rf), 0.0, TAU, false)
		# The guide tube hanging from its top, over the riser.
		var sleeve := minf(Hf * 0.93, riser_h)
		g.lathe("pvc", TcSpecialty._ring(sleeve_r - 3.9, sleeve_r, 0.0, sleeve), TcGeom.frame_along(top - Vector3(0, sleeve, 0), Vector3.UP), 18)
		# Bulkhead fittings on top: the tube's, and two small ones for probes.
		g.lathe("bell_trim", TcSpecialty._ring(0.0, 49.0, 0.0, 16.0), TcGeom.frame_along(top, Vector3.UP), 24)
		g.hex("bell_trim", top + Vector3(0, 16.0, 0), Vector3.UP, 10.0, 70.0)
		for sx in [-1.0, 1.0]:
			var at := top + Vector3(sx * Rf * 0.5, 0, 0)
			g.hex("bell_trim", at, Vector3.UP, 12.0, 30.0)
			g.cylinder("hardware", at + Vector3(0, 12.0, 0), at + Vector3(0, 30.0, 0), 6.0, 10)
	return {"ports": [pa, pb], "capsules": [[foot, foot + Vector3(0, FLOAT_REST + Hf + stroke, 0), Rb + 6.0],
			[Vector3.ZERO, Vector3(0, 0, 2.0 * cx), rf]],
		"mass_kg": float(b["base_kg"]) + float(b["float_kg"]) + 2.0, "volume_l": cap_l,
		"unit": {"kind": "holder", "cap_l": cap_l, "hold_kpa": hold_kpa, "style": style, "stroke_mm": stroke}}


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


## Generator models. "small" is the user's portable generator ("small
## generator.glb", a light-duty open-frame set, 680 × 560 × 620 mm): drawn
## to that size and layout — a tube frame, the tank on top, the engine and
## alternator under it, a panel on the front, the muffler on the back. It
## charges a 48 V bank anywhere from `min_kw` to `rated_kw` (350–750 W): its
## governor follows the gas it has. "skid" is the older boxed set, sized
## with its rating.
const GENSET_MODELS := [["small", "Small open-frame generator"], ["skid", "Skid genset"]]
const SMALL_GEN := Vector3(560.0, 620.0, 680.0)     # wide, high, long (mm)


## A 48 V DC genset; the gas inlet on the clamp end a. Returns `unit` with
## its rating, floor (`min_kw`), efficiency and where the exhaust leaves
## (`exhaust_mm`, part frame) for the Process view.
static func genset(g: TcGeom, size: String, rated_kw: float, efficiency: float, model: String = "skid", min_kw: float = 0.0) -> Dictionary:
	if model == "small":
		return _small_generator(g, size, rated_kw, efficiency, min_kw)
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
		"unit": {"kind": "engine", "rated_kw": rated_kw, "min_kw": min_kw, "efficiency": efficiency,
			"exhaust_mm": ex + Vector3(0, by * 0.6, 0), "exhaust_dir": Vector3.UP}}


static func _small_generator(g: TcGeom, size: String, rated_kw: float, efficiency: float, min_kw: float) -> Dictionary:
	var W := SMALL_GEN.x
	var H := SMALL_GEN.y
	var L := SMALL_GEN.z
	var rf := float(TcStandards.tube(size)["r_flange"])
	var stub := 110.0
	var y0 := -rf - 60.0                       # the feet's level, as the other units
	var c := Vector3(0, y0, stub + L * 0.5)    # under its middle
	var hx := W * 0.5
	var hz := L * 0.5
	var tube := 12.5
	# The frame: two side loops of tube, joined by cross tubes, on rubber feet.
	for sx in [-1.0, 1.0]:
		var x: float = sx * (hx - tube)
		var loop := PackedVector3Array()
		var corners: Array = [Vector3(x, 40.0, -hz + 40.0), Vector3(x, 40.0, hz - 40.0), Vector3(x, H - 30.0, hz - 40.0), Vector3(x, H - 30.0, -hz + 40.0)]
		for k in 4:
			var p0: Vector3 = corners[k]
			var p1: Vector3 = corners[(k + 1) % 4]
			var pm: Vector3 = corners[(k + 3) % 4]
			var d_in := (p0 - pm).normalized()
			var d_out := (p1 - p0).normalized()
			# A rounded corner.
			for j in 5:
				var t := float(j) / 4.0
				loop.append(c + p0 - d_in * 40.0 * (1.0 - t) * (1.0 - t) + d_out * 40.0 * t * t)
		loop.append(loop[0])
		g.sweep("frame", loop, tube, true, 10)
		for sz in [-1.0, 1.0]:
			g.cylinder("dark", c + Vector3(x, 0.0, sz * (hz - 110.0)), c + Vector3(x, 40.0 - tube, sz * (hz - 110.0)), 22.0, 12)
	for e in [[40.0, -hz + 40.0], [40.0, hz - 40.0], [H - 30.0, -hz + 40.0], [H - 30.0, hz - 40.0]]:
		g.cylinder("frame", c + Vector3(-hx + tube, float(e[0]), float(e[1])), c + Vector3(hx - tube, float(e[0]), float(e[1])), tube, 10)
	# The fuel tank across the top (the gas line bypasses it; it is the set's look).
	g.box("actuator", Transform3D(Basis.IDENTITY, c + Vector3(0, H - 125.0, -10.0)), Vector3(hx - 42.0, 82.0, hz - 80.0))
	g.cylinder("dark", c + Vector3(-hx * 0.4, H - 43.0, -hz * 0.3), c + Vector3(-hx * 0.4, H - 22.0, -hz * 0.3), 34.0, 16)
	# Engine: crankcase, the cylinder's cooling fins, the recoil starter.
	var ec := c + Vector3(0, 215.0, -hz * 0.28)
	g.box("engine", Transform3D(Basis.IDENTITY, ec), Vector3(hx - 80.0, 150.0, 130.0))
	for k in 6:
		g.box("hardware", Transform3D(Basis.IDENTITY, ec + Vector3(40.0, 158.0 + 13.0 * float(k), 0.0)), Vector3(80.0, 3.5, 100.0))
	g.cylinder("dark", ec + Vector3(0, 0, -130.0), ec + Vector3(0, 0, -172.0), 110.0, 24)
	g.cylinder("actuator", ec + Vector3(0, 0, -172.0), ec + Vector3(0, 0, -180.0), 70.0, 20)
	# Alternator (the 48 V end), bolted to the engine.
	var ac := c + Vector3(0, 205.0, hz * 0.05)
	g.cylinder("hardware", ac, ac + Vector3(0, 0, hz * 0.62), 125.0, 24)
	g.cylinder("dark", ac + Vector3(0, 0, hz * 0.62), ac + Vector3(0, 0, hz * 0.62 + 22.0), 105.0, 24)
	# Control panel on one side: outlets, a meter, the switch.
	var pc := c + Vector3(hx - 40.0, 300.0, hz * 0.32)
	g.box("dark", Transform3D(Basis.IDENTITY, pc), Vector3(14.0, 105.0, 135.0))
	g.box("dial", Transform3D(Basis.IDENTITY, pc + Vector3(15.0, 45.0, -40.0)), Vector3(2.0, 28.0, 45.0))
	for k in 2:
		g.cylinder("handle", pc + Vector3(14.0, -35.0, -60.0 + 70.0 * float(k)), pc + Vector3(20.0, -35.0, -60.0 + 70.0 * float(k)), 20.0, 14)
	# Muffler on the other side, its outlet to the back.
	var mc := c + Vector3(-hx + 70.0, 330.0, -hz * 0.1)
	g.box("hardware", Transform3D(Basis.IDENTITY, mc), Vector3(38.0, 70.0, 150.0))
	var ex := mc + Vector3(-38.0, -30.0, 110.0)
	g.cylinder("dark", ex, ex + Vector3(-45.0, 0, 0), 13.0, 10)
	# Air cleaner / gas mixer where the line comes in.
	var mx := c + Vector3(0, 250.0, -hz + 70.0)
	g.box("dark", Transform3D(Basis.IDENTITY, mx), Vector3(70.0, 55.0, 40.0))
	var pa := _p("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1))
	_stub(g, size, pa, stub + 30.0)
	# The hose from the clamp end up to the mixer.
	g.sweep("dark", PackedVector3Array([Vector3(0, 0, stub + 20.0), Vector3(0, 60.0, stub + 60.0), mx - c + c + Vector3(0, -40.0, 0), mx]), 11.0, true, 8)
	return {"ports": [pa], "capsules": [[c + Vector3(0, H * 0.5, -hz + hx), c + Vector3(0, H * 0.5, hz - hx), hx]],
		"mass_kg": 21.0, "volume_l": 0.6,
		"unit": {"kind": "engine", "rated_kw": rated_kw, "min_kw": min_kw, "efficiency": efficiency,
			"exhaust_mm": ex + Vector3(-45.0, 0, 0), "exhaust_dir": Vector3(-1, 0, 0)}}


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
