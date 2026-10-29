class_name WindLabParts
extends RefCounted

## The wind turbine designer's parts: the rotor types and what is known about
## each, the sheets and print materials blades are made from, the airfoils,
## the generators (steppers, outrunners, PMAs, hub motors, brushed DC), the
## drives, bearings and masts. Pure data + lookups.
##
## Numbers marked TYPICAL are a class's usual values (makers vary — check
## your own part's data sheet); everything else is cited where it is used.

const IN := 25.4

# ---------------------------------------------------------------------------
# Rotor types
# ---------------------------------------------------------------------------

## axis "vawt" | "hawt"; family "drag" (Savonius-like, high torque, slow),
## "hybrid" (drag + lift), "lift" (Darrieus / propeller). `build` is the way
## it is usually made: "sheet" (bent sheet blades), "foil" (airfoil blades,
## printed or carved), "plate" (bent plates on arms).
const TYPES := {
	"ugrinsky": {"label": "Ugrinsky (semicircle + arc)", "axis": "vawt", "family": "drag", "build": "sheet",
		"blurb": "Two S-shaped blades, a semicircle running in from the rim and a tail arc curving the other way round the shaft. Positive torque all the way round, about 40 % better than a Savonius in the published simulations."},
	"savonius": {"label": "Savonius", "axis": "vawt", "family": "drag", "build": "sheet",
		"blurb": "Two or three half-cylinder buckets with an overlap through the middle. Starts in almost any breeze, turns slowly with lots of torque."},
	"lenz2": {"label": "Lenz2 (lift + drag)", "axis": "vawt", "family": "hybrid", "build": "sheet",
		"blurb": "Ed Lenz's three curved wings with a rolled leading edge: a scoop that also lifts. Runs a little slower than the wind at its best."},
	"darrieus_h": {"label": "Darrieus H-rotor", "axis": "vawt", "family": "lift", "build": "foil",
		"blurb": "Straight airfoil blades on arms. The most efficient vertical axis rotor, but it barely starts on its own."},
	"helical": {"label": "Helical (Gorlov)", "axis": "vawt", "family": "lift", "build": "foil",
		"blurb": "A Darrieus with the blades twisted round the shaft, so some blade is always at a good angle: smoother torque and an easier start."},
	"hawt": {"label": "Propeller (HAWT)", "axis": "hawt", "family": "lift", "build": "foil",
		"blurb": "Two to six twisted, tapered airfoil blades facing the wind, designed by blade element momentum theory. The most efficient rotor; needs a tail to face the wind."},
	"multiblade": {"label": "Multi-blade (farm windmill)", "axis": "hawt", "family": "drag", "build": "plate",
		"blurb": "Many wide curved plates: high solidity, very high starting torque, slow — the water-pumping windmill."},
}

const TYPE_ORDER := ["ugrinsky", "savonius", "lenz2", "darrieus_h", "helical", "hawt", "multiblade"]

# ---------------------------------------------------------------------------
# Sheets (blade material for sheet rotors, discs, end plates, hub plates)
# ---------------------------------------------------------------------------

## t_mm thickness; kg_m2 areal mass; free_r_mm the smallest radius it bends
## to without scoring (estimate — corrugated plastic bends round its flutes
## easily, solid sheet much less); scoreable (a knife cut through one skin
## makes a hinge — corrugated plastic only); cost_m2 USD; look for the
## builder. Corrugated plastic ("correx", "coroplast") from sign makers'
## sheets: 4 mm ≈ 0.55–0.8 kg/m² (data sheets), the middle used.
const SHEETS := {
	"correx_4": {"label": "Corrugated plastic 4 mm (lawn sign)", "t_mm": 4.0, "kg_m2": 0.65, "free_r_mm": 60.0,
		"scoreable": true, "cost_m2": 12.0, "look": "correx"},
	"correx_6": {"label": "Corrugated plastic 6 mm", "t_mm": 6.0, "kg_m2": 1.05, "free_r_mm": 90.0,
		"scoreable": true, "cost_m2": 16.0, "look": "correx"},
	"correx_10": {"label": "Corrugated plastic 10 mm", "t_mm": 10.0, "kg_m2": 1.7, "free_r_mm": 160.0,
		"scoreable": true, "cost_m2": 24.0, "look": "correx"},
	"pvc_foam_3": {"label": "PVC foam board 3 mm", "t_mm": 3.0, "kg_m2": 1.65, "free_r_mm": 150.0,
		"scoreable": false, "cost_m2": 20.0, "look": "pvc"},
	"petg_1": {"label": "PETG sheet 1 mm", "t_mm": 1.0, "kg_m2": 1.27, "free_r_mm": 40.0,
		"scoreable": false, "cost_m2": 25.0, "look": "clear"},
	"alu_1": {"label": "Aluminium sheet 1 mm", "t_mm": 1.0, "kg_m2": 2.7, "free_r_mm": 20.0,
		"scoreable": false, "cost_m2": 35.0, "look": "alu"},
	"galv_0_6": {"label": "Galvanised steel 0.6 mm", "t_mm": 0.6, "kg_m2": 4.7, "free_r_mm": 15.0,
		"scoreable": false, "cost_m2": 22.0, "look": "galv"},
	"ply_6": {"label": "Plywood 6 mm", "t_mm": 6.0, "kg_m2": 3.6, "free_r_mm": 600.0,
		"scoreable": false, "cost_m2": 18.0, "look": "ply"},
	"ply_12": {"label": "Plywood 12 mm", "t_mm": 12.0, "kg_m2": 7.2, "free_r_mm": 2000.0,
		"scoreable": false, "cost_m2": 30.0, "look": "ply"},
}

## Sheet sizes parts are nested on (mm, width × height). `flutes`: which way a
## corrugated sheet's flutes run — a yard sign's along its short side (the
## H-stake slides up them), a full sheet's along its length.
const SHEET_SIZES := {
	"sign_18x24": {"label": "18 × 24 in lawn sign", "w": 24.0 * IN, "h": 18.0 * IN, "flutes": "h"},
	"sign_24x36": {"label": "24 × 36 in sign", "w": 36.0 * IN, "h": 24.0 * IN, "flutes": "h"},
	"sheet_4x8": {"label": "4 × 8 ft sheet", "w": 96.0 * IN, "h": 48.0 * IN, "flutes": "w"},
	"sheet_1x2m": {"label": "1 × 2 m sheet", "w": 2000.0, "h": 1000.0, "flutes": "w"},
	"bed_300": {"label": "300 × 300 mm (laser bed)", "w": 300.0, "h": 300.0, "flutes": "h"},
}

# ---------------------------------------------------------------------------
# Printed / carved blade materials (foil rotors)
# ---------------------------------------------------------------------------

## density kg/m³, a working tensile stress (MPa) with a safety factor of ~2
## folded in (prints taken across the layers), cost USD/kg.
const SOLIDS := {
	"pla": {"label": "PLA (printed)", "density": 1240.0, "stress_mpa": 15.0, "cost_kg": 22.0, "look": "pla"},
	"petg": {"label": "PETG (printed)", "density": 1270.0, "stress_mpa": 14.0, "cost_kg": 24.0, "look": "petg"},
	"asa": {"label": "ASA (printed, UV-stable)", "density": 1070.0, "stress_mpa": 16.0, "cost_kg": 30.0, "look": "asa"},
	"nylon_cf": {"label": "Nylon CF (printed)", "density": 1150.0, "stress_mpa": 30.0, "cost_kg": 60.0, "look": "cf"},
	"pine": {"label": "Pine (carved / routed)", "density": 500.0, "stress_mpa": 20.0, "cost_kg": 4.0, "look": "wood"},
	"cedar": {"label": "Western red cedar (carved)", "density": 380.0, "stress_mpa": 16.0, "cost_kg": 8.0, "look": "wood"},
	"pvc_pipe": {"label": "PVC pipe (cut from the pipe)", "density": 1400.0, "stress_mpa": 18.0, "cost_kg": 4.0, "look": "pvc"},
}

# ---------------------------------------------------------------------------
# Airfoils
# ---------------------------------------------------------------------------

## The design point each blade is set at: lift coefficient, angle of attack,
## lift/drag ratio at Re = 1×10⁵ (small-turbine Reynolds numbers), and the
## section shape as a NACA 4-digit-style camber line + thickness for the
## drawn / printed blade (m camber, p its position, t thickness, chord
## fractions). SG6043: Giguère & Selig, "New airfoils for small horizontal
## axis wind turbines", J. Sol. Energy Eng. 120 (1998) — the shape here is
## its NACA 4-digit look-alike, not the exact coordinates. NACA sections:
## Abbott & von Doenhoff, Theory of Wing Sections (1959), corrected down for
## the low Reynolds number. Curved / flat plate: thin cambered plates at low
## Re (Mueller, AIAA 1999) — L/D 8–15.
const AIRFOILS := {
	"sg6043": {"label": "SG6043 (small-turbine section)", "cl": 1.1, "alpha_deg": 5.0, "ld": 60.0, "m": 0.055, "p": 0.40, "t": 0.10},
	"naca4412": {"label": "NACA 4412", "cl": 0.9, "alpha_deg": 5.0, "ld": 45.0, "m": 0.04, "p": 0.40, "t": 0.12},
	"naca0018": {"label": "NACA 0018 (symmetric)", "cl": 0.8, "alpha_deg": 7.0, "ld": 30.0, "m": 0.0, "p": 0.4, "t": 0.18},
	"naca0012": {"label": "NACA 0012 (symmetric)", "cl": 0.7, "alpha_deg": 6.0, "ld": 35.0, "m": 0.0, "p": 0.4, "t": 0.12},
	"curved_plate": {"label": "Curved plate (PVC pipe / bent sheet)", "cl": 0.9, "alpha_deg": 4.0, "ld": 14.0, "m": 0.07, "p": 0.5, "t": 0.025},
	"flat_plate": {"label": "Flat plate", "cl": 0.6, "alpha_deg": 6.0, "ld": 8.0, "m": 0.0, "p": 0.5, "t": 0.03},
}
const AIR_NU := 1.5e-5        ## kinematic viscosity of air at 20 °C, m²/s
const RE_REF := 1.0e5

# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

## kind "stepper" (2-phase hybrid, 50 pole pairs: 1.8° step), "ac3" (3-phase
## permanent magnet: outrunner, PMA, hub motor, PMG), "dc" (brushed DC motor
## run as a dynamo). TYPICAL figures for each class.
##   stepper: hold_nm holding torque (both phases at rated current), amps
##            rated phase current, ohm and mh per phase. The torque constant
##            per phase Kt = T_hold / (√2 · I) and the back-EMF constant
##            equals it in SI (V·s/rad = N·m/A) for a permanent-magnet machine.
##   ac3:     v_per_rpm rectified open-circuit DC volts per rpm (a 3-phase
##            bridge gives V_dc = 3√3/π · E_peak), ohm and mh per phase,
##            pole_pairs.
##   dc:      v_per_rpm open-circuit volts per rpm, ohm armature, brush_v.
## detent_nm: the cogging (stepper detent) the rotor must break to start —
## TYPICAL ~4–6 % of a stepper's holding torque; friction_nm the bearing and
## iron drag while turning. max_rpm the highest safe speed, rated_w its
## continuous electrical rating, frame (nema size mm) or can dia_mm, len_mm.
const GENERATORS := {
	"nema17_40": {"label": "NEMA 17 stepper, 40 mm (0.40 N·m)", "kind": "stepper", "hold_nm": 0.40, "amps": 1.7,
		"ohm": 1.5, "mh": 2.8, "pole_pairs": 50, "detent_nm": 0.018, "friction_nm": 0.004, "max_rpm": 1500.0,
		"rated_w": 15.0, "body": "nema", "frame_mm": 42.3, "len_mm": 40.0, "shaft_mm": 5.0, "mass_kg": 0.28, "cost": 12.0},
	"nema17_48": {"label": "NEMA 17 stepper, 48 mm (0.59 N·m)", "kind": "stepper", "hold_nm": 0.59, "amps": 2.0,
		"ohm": 1.4, "mh": 3.0, "pole_pairs": 50, "detent_nm": 0.025, "friction_nm": 0.005, "max_rpm": 1500.0,
		"rated_w": 20.0, "body": "nema", "frame_mm": 42.3, "len_mm": 48.0, "shaft_mm": 5.0, "mass_kg": 0.36, "cost": 15.0},
	"nema23_56": {"label": "NEMA 23 stepper, 56 mm (1.26 N·m)", "kind": "stepper", "hold_nm": 1.26, "amps": 2.8,
		"ohm": 0.9, "mh": 2.5, "pole_pairs": 50, "detent_nm": 0.05, "friction_nm": 0.01, "max_rpm": 1200.0,
		"rated_w": 40.0, "body": "nema", "frame_mm": 57.0, "len_mm": 56.0, "shaft_mm": 8.0, "mass_kg": 0.7, "cost": 25.0},
	"nema23_76": {"label": "NEMA 23 stepper, 76 mm (1.9 N·m)", "kind": "stepper", "hold_nm": 1.9, "amps": 2.8,
		"ohm": 1.13, "mh": 3.6, "pole_pairs": 50, "detent_nm": 0.07, "friction_nm": 0.012, "max_rpm": 1200.0,
		"rated_w": 60.0, "body": "nema", "frame_mm": 57.0, "len_mm": 76.0, "shaft_mm": 8.0, "mass_kg": 1.0, "cost": 30.0},
	"nema34_98": {"label": "NEMA 34 stepper, 98 mm (4.5 N·m)", "kind": "stepper", "hold_nm": 4.5, "amps": 4.2,
		"ohm": 0.9, "mh": 7.5, "pole_pairs": 50, "detent_nm": 0.18, "friction_nm": 0.03, "max_rpm": 1000.0,
		"rated_w": 150.0, "body": "nema", "frame_mm": 86.0, "len_mm": 98.0, "shaft_mm": 14.0, "mass_kg": 2.8, "cost": 55.0},
	"outrunner_5065": {"label": "5065 outrunner, 270 KV", "kind": "ac3", "v_per_rpm": 1.0 / 270.0, "ohm": 0.025,
		"mh": 0.012, "pole_pairs": 7, "detent_nm": 0.004, "friction_nm": 0.008, "max_rpm": 9000.0,
		"rated_w": 1200.0, "body": "can", "dia_mm": 50.0, "len_mm": 65.0, "shaft_mm": 8.0, "mass_kg": 0.4, "cost": 40.0},
	"pma400": {"label": "400 W wind PMA (24 V)", "kind": "ac3", "v_per_rpm": 0.045, "ohm": 0.3, "mh": 1.0,
		"pole_pairs": 6, "detent_nm": 0.06, "friction_nm": 0.05, "max_rpm": 1500.0, "rated_w": 400.0,
		"body": "can", "dia_mm": 150.0, "len_mm": 120.0, "shaft_mm": 20.0, "mass_kg": 6.0, "cost": 140.0},
	"hub500": {"label": "500 W e-bike hub motor (48 V)", "kind": "ac3", "v_per_rpm": 0.145, "ohm": 0.15, "mh": 0.3,
		"pole_pairs": 23, "detent_nm": 0.2, "friction_nm": 0.3, "max_rpm": 600.0, "rated_w": 500.0,
		"body": "hub", "dia_mm": 200.0, "len_mm": 70.0, "shaft_mm": 12.0, "mass_kg": 4.5, "cost": 120.0},
	"pmg1k": {"label": "1 kW low-speed PMG (48 V)", "kind": "ac3", "v_per_rpm": 0.14, "ohm": 0.5, "mh": 3.0,
		"pole_pairs": 8, "detent_nm": 0.5, "friction_nm": 0.5, "max_rpm": 900.0, "rated_w": 1000.0,
		"body": "can", "dia_mm": 230.0, "len_mm": 160.0, "shaft_mm": 25.0, "mass_kg": 14.0, "cost": 380.0},
	"treadmill": {"label": "Treadmill DC motor (130 V, 6700 rpm)", "kind": "dc", "v_per_rpm": 130.0 / 6700.0,
		"ohm": 1.2, "brush_v": 1.5, "detent_nm": 0.12, "friction_nm": 0.15, "max_rpm": 6700.0, "rated_w": 1100.0,
		"body": "can", "dia_mm": 100.0, "len_mm": 200.0, "shaft_mm": 12.0, "mass_kg": 8.0, "cost": 40.0},
	"rs555": {"label": "RS-555 DC motor (24 V, 5000 rpm)", "kind": "dc", "v_per_rpm": 24.0 / 5000.0,
		"ohm": 3.0, "brush_v": 0.6, "detent_nm": 0.003, "friction_nm": 0.004, "max_rpm": 6000.0, "rated_w": 30.0,
		"body": "can", "dia_mm": 36.0, "len_mm": 57.0, "shaft_mm": 3.2, "mass_kg": 0.25, "cost": 6.0},
}

## Rectifier diode forward drop (V): silicon bridge 0.9, Schottky 0.45.
const DIODES := {"schottky": {"label": "Schottky bridge", "v": 0.45}, "silicon": {"label": "Silicon bridge", "v": 0.9}}

# ---------------------------------------------------------------------------
# Drives, bearings, masts
# ---------------------------------------------------------------------------

## Efficiency of one stage: synchronous belt 0.97, spur gears 0.97, a
## planetary stage 0.95 (typical published figures).
const DRIVES := {
	"direct": {"label": "Direct (rotor on the generator)", "eff": 1.0},
	"gt2": {"label": "GT2 timing belt (2 mm)", "eff": 0.97, "pitch_mm": 2.0, "min_teeth": 16, "belt_w_mm": 6.0},
	"htd5": {"label": "HTD 5M timing belt", "eff": 0.97, "pitch_mm": 5.0, "min_teeth": 14, "belt_w_mm": 15.0},
	"spur": {"label": "Spur gears", "eff": 0.97, "min_teeth": 17, "module_mm": 1.5},
	"planetary": {"label": "Planetary gearbox", "eff": 0.95},
}
const PLANETARY_RATIOS := [3.0, 4.0, 5.0, 7.0, 10.0, 16.0, 20.0, 25.0]

## Deep-groove ball bearings by bore: basic dynamic rating C (kN) from the
## SKF catalogue, outer Ø, width, the friction torque of a sealed small
## bearing (N·m, estimate).
const BEARINGS := {
	8.0: {"id": "608-2RS", "C_kN": 3.45, "od": 22.0, "w": 7.0, "friction_nm": 0.002},
	10.0: {"id": "6000-2RS", "C_kN": 4.75, "od": 26.0, "w": 8.0, "friction_nm": 0.003},
	12.0: {"id": "6001-2RS", "C_kN": 5.4, "od": 28.0, "w": 8.0, "friction_nm": 0.003},
	15.0: {"id": "6002-2RS", "C_kN": 5.85, "od": 32.0, "w": 9.0, "friction_nm": 0.004},
	17.0: {"id": "6003-2RS", "C_kN": 6.37, "od": 35.0, "w": 10.0, "friction_nm": 0.005},
	20.0: {"id": "6004-2RS", "C_kN": 9.95, "od": 42.0, "w": 12.0, "friction_nm": 0.008},
	25.0: {"id": "6005-2RS", "C_kN": 11.9, "od": 47.0, "w": 12.0, "friction_nm": 0.01},
	30.0: {"id": "6006-2RS", "C_kN": 13.8, "od": 55.0, "w": 13.0, "friction_nm": 0.015},
}
const SHAFTS := [8.0, 10.0, 12.0, 15.0, 17.0, 20.0, 25.0, 30.0]

## Mast stock: od, wall (0 = solid rod), kg/m. Steel 7850 kg/m³.
const MASTS := {
	"rod_8": {"label": "8 mm steel rod (stake)", "od": 8.0, "wall": 0.0},
	"rod_12": {"label": "12 mm steel rod", "od": 12.0, "wall": 0.0},
	"emt_19": {"label": "3/4 in EMT conduit", "od": 23.4, "wall": 1.65},
	"pipe_33": {"label": "1 in steel pipe", "od": 33.4, "wall": 3.38},
	"pipe_48": {"label": "1-1/2 in steel pipe", "od": 48.3, "wall": 3.68},
	"pipe_60": {"label": "2 in steel pipe", "od": 60.3, "wall": 3.91},
	"pipe_89": {"label": "3 in steel pipe", "od": 88.9, "wall": 5.49},
}
const STEEL_KG_M3 := 7850.0
const STEEL_YIELD_MPA := 250.0   ## structural steel (ASTM A36 / S235 class)

const MOUNTS := {
	"body_spins": {"label": "Rotor clamped to the motor body (shaft on the mast)"},
	"on_shaft": {"label": "Rotor on the generator shaft"},
	"bearings": {"label": "Rotor on its own shaft and bearings, drive to the generator"},
}

const LOADS := {
	"battery": {"label": "Battery (through a rectifier)"},
	"mppt": {"label": "MPPT charge controller"},
	"resistor": {"label": "Resistor / heater (dump load)"},
}


static func type_info(id: String) -> Dictionary:
	return TYPES.get(id, TYPES["ugrinsky"])


static func is_vawt(id: String) -> bool:
	return str(type_info(id)["axis"]) == "vawt"


static func sheet(id: String) -> Dictionary:
	return SHEETS.get(id, SHEETS["correx_4"])


static func sheet_size(id: String) -> Dictionary:
	return SHEET_SIZES.get(id, SHEET_SIZES["sign_18x24"])


static func solid(id: String) -> Dictionary:
	return SOLIDS.get(id, SOLIDS["petg"])


static func airfoil(id: String) -> Dictionary:
	return AIRFOILS.get(id, AIRFOILS["sg6043"])


static func generator(id: String) -> Dictionary:
	return GENERATORS.get(id, GENERATORS["nema17_48"])


static func mast(id: String) -> Dictionary:
	return MASTS.get(id, MASTS["pipe_33"])


static func bearing_for(shaft_mm: float) -> Dictionary:
	var best := 30.0
	for s in SHAFTS:
		if float(s) >= shaft_mm - 0.01:
			best = float(s)
			break
	var b: Dictionary = (BEARINGS[best] as Dictionary).duplicate()
	b["bore"] = best
	return b


## Mass per metre of a mast.
static func mast_kg_m(id: String) -> float:
	var m := mast(id)
	var ro := float(m["od"]) * 0.0005
	var ri := maxf(ro - float(m["wall"]) * 0.001, 0.0) if float(m["wall"]) > 0.0 else 0.0
	return PI * (ro * ro - ri * ri) * STEEL_KG_M3


## Second moment of area (m⁴) and section modulus (m³) of a mast.
static func mast_section(id: String) -> Dictionary:
	var m := mast(id)
	var ro := float(m["od"]) * 0.0005
	var ri := maxf(ro - float(m["wall"]) * 0.001, 0.0) if float(m["wall"]) > 0.0 else 0.0
	var i := PI * 0.25 * (pow(ro, 4.0) - pow(ri, 4.0))
	return {"I": i, "Z": i / maxf(ro, 1e-6)}


## Pitch diameter (mm) of a timing pulley / spur gear.
static func pulley_pitch_d_mm(drive_id: String, teeth: int) -> float:
	var dr: Dictionary = DRIVES.get(drive_id, DRIVES["gt2"])
	if drive_id == "spur":
		return float(dr["module_mm"]) * float(teeth)
	return float(teeth) * float(dr.get("pitch_mm", 2.0)) / PI


## Standard timing-pulley tooth counts (what you can buy).
const PULLEY_TEETH := [16, 20, 24, 30, 36, 40, 48, 60, 72, 80, 90, 100, 120]
