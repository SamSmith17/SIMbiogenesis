class_name PeltonLabParts
extends RefCounted

## The Pelton wheel designer's parts: the one cup, and the stock things a
## wheel is bolted together from (bolts, shafts, bearings, couplers, pulleys,
## gears, generators, housing sheet). Pure data + lookups.
##
## THE CUP is `assets/hydro/pelton_cup.stl` — a 79 mm split bucket with a
## single root tab, measured off the file (mm, the STL's own frame):
##   x  0 … 79.04   across the cup (along the shaft); the splitter ridge is the
##                  plane x = 39.52, the cup is symmetric about it
##   y  5.20 … 30.16  the cup's depth; the OPEN face (rim) is at y = 30.16 and
##                  faces the oncoming jet, the back is flat at y = 5.20
##   z  4.61 … 114.81  along the wheel's radius: the notched TIP at z ≈ 4.6 is
##                  the outermost point, the bowl runs to z ≈ 77, the root tab
##                  (x 22.5 … 56.5, 34 mm thick along the shaft) to z = 114.8
##   widest at z = 40 (x 0 … 79): the jet centreline meets the pitch circle
##                  there, so that is the cup's PITCH point
##   volume 63.1 cm³ (signed tetrahedron sum), centroid z = 64.0
## The tab tapers in depth from y 5.2 … 29.5 at z = 77 to y 5.2 … 15.8 at the
## root, so two bolts fit at z = 92 (M8 max) and z = 108 (M6 max), one at z = 98.
## The tab is clamped between the wheel's TWO side discs, bolts axial.

const CUP_STL := "res://assets/hydro/pelton_cup.stl"
const CUP := {
	"width_mm": 79.04, "splitter_x": 39.52,
	"depth_y0": 5.20, "depth_y1": 30.16,
	"tip_z": 4.61, "pitch_z": 40.0, "bowl_root_z": 77.0, "root_z": 114.81,
	"tab_x0": 22.5, "tab_x1": 56.5,
	"tab_y_top_bowl": 29.5, "tab_y_top_root": 15.8,
	"volume_mm3": 63122.0, "centroid_z": 64.02,
}
## Bolt stations on the tab (cup z, mm) and the biggest bolt each takes.
const CUP_BOLT_Z_TWO := [92.0, 108.0]
const CUP_BOLT_Z_ONE := [98.0]

## Cup materials: density (kg/m³) and a working tensile stress (MPa) for the
## tab under centrifugal pull at runaway — yield / tensile from common data
## sheets with a safety factor of ~2 folded in (prints: across the layers).
const CUP_MATERIALS := {
	"pla": {"label": "PLA (3D printed)", "density": 1240.0, "stress_mpa": 15.0},
	"petg": {"label": "PETG (3D printed)", "density": 1270.0, "stress_mpa": 14.0},
	"nylon": {"label": "Nylon PA12 (printed / cast)", "density": 1010.0, "stress_mpa": 20.0},
	"alu_cast": {"label": "Cast aluminium", "density": 2700.0, "stress_mpa": 60.0},
	"bronze": {"label": "Cast bronze", "density": 8800.0, "stress_mpa": 110.0},
	"stainless": {"label": "Cast stainless", "density": 7900.0, "stress_mpa": 170.0},
}

## Disc / housing plate materials: density, working stress (MPa), look.
const PLATE_MATERIALS := {
	"steel": {"label": "Mild steel plate", "density": 7850.0, "stress_mpa": 120.0, "look": "steel"},
	"stainless": {"label": "Stainless plate", "density": 7900.0, "stress_mpa": 140.0, "look": "stainless"},
	"alu": {"label": "Aluminium 6061", "density": 2700.0, "stress_mpa": 90.0, "look": "alu"},
	"hdpe": {"label": "HDPE sheet", "density": 950.0, "stress_mpa": 8.0, "look": "hdpe"},
	"plywood": {"label": "Marine plywood", "density": 600.0, "stress_mpa": 10.0, "look": "ply"},
	"acrylic": {"label": "Acrylic (clear)", "density": 1190.0, "stress_mpa": 20.0, "look": "acrylic"},
}

## ISO metric bolts, class 8.8: tensile stress area As (mm², ISO 898-1),
## clearance hole (mm, medium), head across flats (mm). Shear capacity is
## 0.6 × proof (600 MPa) × As ÷ a safety factor of 2.5 per shear plane.
const BOLTS := {
	"m4": {"d": 4.0, "as": 8.78, "hole": 4.5, "af": 7.0},
	"m5": {"d": 5.0, "as": 14.2, "hole": 5.5, "af": 8.0},
	"m6": {"d": 6.0, "as": 20.1, "hole": 6.6, "af": 10.0},
	"m8": {"d": 8.0, "as": 36.6, "hole": 9.0, "af": 13.0},
	"m10": {"d": 10.0, "as": 58.0, "hole": 11.0, "af": 16.0},
	"m12": {"d": 12.0, "as": 84.3, "hole": 13.5, "af": 18.0},
}
const BOLT_PROOF_MPA := 600.0
const BOLT_SHEAR_SF := 2.5

const SHAFTS := [12.0, 15.0, 17.0, 20.0, 25.0, 30.0, 35.0, 40.0]
## Allowable shear for a keyed steel shaft (MPa) — the ASME shaft code's
## 0.3 × yield (≈ 0.18 × UTS), × 0.75 for the keyway, on 1045-class steel
## (Shigley, Mechanical Engineering Design, shaft design chapter).
const SHAFT_TAU_ALLOW_MPA := 40.0

## Insert bearings by shaft size. Pillow blocks (UCP2xx, cast iron) and
## two-bolt flange units (UCFL2xx). Dimensions (mm) and the 62xx insert's
## basic dynamic load rating C (kN) from the NTN / SKF catalogues:
##   pillow: H centre height, L base length, J bolt spacing, A base width,
##           Ht overall height
##   flange: L across the bolts' ends, J bolt spacing, A thickness, B housing Ø
## max_rpm is the grease-lubricated insert's limiting speed, rounded down.
const BEARINGS := {
	12.0: {"pillow": "UCP201", "flange": "UCFL201", "C_kN": 12.8, "max_rpm": 6000.0,
		"H": 30.2, "L": 127.0, "J": 95.0, "A": 38.0, "Ht": 62.0, "fL": 113.0, "fJ": 90.0, "fA": 25.5, "fB": 60.0},
	15.0: {"pillow": "UCP202", "flange": "UCFL202", "C_kN": 12.8, "max_rpm": 6000.0,
		"H": 30.2, "L": 127.0, "J": 95.0, "A": 38.0, "Ht": 62.0, "fL": 113.0, "fJ": 90.0, "fA": 25.5, "fB": 60.0},
	17.0: {"pillow": "UCP203", "flange": "UCFL203", "C_kN": 12.8, "max_rpm": 6000.0,
		"H": 30.2, "L": 127.0, "J": 95.0, "A": 38.0, "Ht": 62.0, "fL": 113.0, "fJ": 90.0, "fA": 25.5, "fB": 60.0},
	20.0: {"pillow": "UCP204", "flange": "UCFL204", "C_kN": 12.8, "max_rpm": 5300.0,
		"H": 33.3, "L": 127.0, "J": 95.0, "A": 38.0, "Ht": 65.0, "fL": 113.0, "fJ": 90.0, "fA": 25.5, "fB": 60.0},
	25.0: {"pillow": "UCP205", "flange": "UCFL205", "C_kN": 14.0, "max_rpm": 4500.0,
		"H": 36.5, "L": 140.0, "J": 105.0, "A": 38.0, "Ht": 71.0, "fL": 130.0, "fJ": 99.0, "fA": 27.0, "fB": 68.0},
	30.0: {"pillow": "UCP206", "flange": "UCFL206", "C_kN": 19.5, "max_rpm": 3800.0,
		"H": 42.9, "L": 165.0, "J": 121.0, "A": 48.0, "Ht": 83.0, "fL": 148.0, "fJ": 117.0, "fA": 31.0, "fB": 80.0},
	35.0: {"pillow": "UCP207", "flange": "UCFL207", "C_kN": 25.7, "max_rpm": 3200.0,
		"H": 47.6, "L": 167.0, "J": 127.0, "A": 48.0, "Ht": 93.0, "fL": 161.0, "fJ": 130.0, "fA": 34.0, "fB": 90.0},
	40.0: {"pillow": "UCP208", "flange": "UCFL208", "C_kN": 29.6, "max_rpm": 2800.0,
		"H": 49.2, "L": 184.0, "J": 137.0, "A": 54.0, "Ht": 98.0, "fL": 175.0, "fJ": 144.0, "fA": 36.0, "fB": 100.0},
}

## Couplers between the runner shaft and the generator. Jaw (Lovejoy L-type,
## rated torque from the maker's table), rigid sleeve, Oldham disc.
const COUPLERS := {
	"jaw": {"label": "Jaw coupler (L-type, rubber spider)", "eff": 0.995},
	"rigid": {"label": "Rigid sleeve coupler", "eff": 0.999},
	"oldham": {"label": "Oldham coupler", "eff": 0.99},
}
## Jaw couplers by size: outer Ø, length (mm), max bore, rated torque (N·m).
const JAW_SIZES := [
	{"id": "L-050", "od": 27.4, "len": 43.4, "bore": 16.0, "torque": 3.5},
	{"id": "L-075", "od": 44.5, "len": 54.0, "bore": 22.0, "torque": 10.2},
	{"id": "L-090", "od": 53.6, "len": 54.0, "bore": 24.0, "torque": 16.3},
	{"id": "L-100", "od": 64.3, "len": 88.9, "bore": 28.0, "torque": 47.7},
	{"id": "L-110", "od": 84.1, "len": 108.0, "bore": 42.0, "torque": 98.0},
]

## Drives. Efficiencies are typical published figures for a well-tensioned
## drive: V-belt 0.95, synchronous (timing) belt 0.97, one stage of spur
## gears 0.97, a coupler ~1. min_* are the smallest pulley / gear the drive
## should run on (A-section V-belt 75 mm pitch Ø; HTD 5M 14 teeth; 20°
## spur gears 17 teeth to avoid undercut).
const DRIVES := {
	"direct": {"label": "Direct (coupler)", "eff": 1.0},
	"vbelt": {"label": "V-belt (A section)", "eff": 0.95, "min_d_mm": 75.0, "belt_w_mm": 13.0},
	"timing": {"label": "Timing belt (HTD 5M)", "eff": 0.97, "min_teeth": 14, "pitch_mm": 5.0, "belt_w_mm": 15.0},
	"gear": {"label": "Spur gears", "eff": 0.97, "min_teeth": 17},
}

## Generators a small Pelton is commonly run on. TYPICAL figures for each
## class (makers vary): rated output and the shaft speed it is reached at,
## the highest safe speed, open-circuit volts per rpm (rectified DC), peak
## efficiency, shaft Ø, and the drawn body (frame: nema N mm square, can Ø,
## alternator Ø) — `len_mm` its length.
const GENERATORS := {
	"nema23": {"label": "NEMA 23 stepper (as generator)", "rated_w": 60.0, "rated_rpm": 600.0,
		"max_rpm": 1500.0, "v_per_rpm": 0.04, "eff": 0.55, "shaft_mm": 8.0,
		"body": "nema", "frame_mm": 57.0, "len_mm": 76.0, "mass_kg": 1.0, "cost": 25.0},
	"nema34": {"label": "NEMA 34 stepper (as generator)", "rated_w": 200.0, "rated_rpm": 500.0,
		"max_rpm": 1200.0, "v_per_rpm": 0.07, "eff": 0.60, "shaft_mm": 14.0,
		"body": "nema", "frame_mm": 86.0, "len_mm": 118.0, "mass_kg": 3.8, "cost": 60.0},
	"pma400": {"label": "400 W wind PMA (24 V)", "rated_w": 400.0, "rated_rpm": 800.0,
		"max_rpm": 1500.0, "v_per_rpm": 0.045, "eff": 0.75, "shaft_mm": 20.0,
		"body": "can", "dia_mm": 150.0, "len_mm": 120.0, "mass_kg": 6.0, "cost": 140.0},
	"hub500": {"label": "500 W e-bike hub motor (48 V)", "rated_w": 500.0, "rated_rpm": 330.0,
		"max_rpm": 600.0, "v_per_rpm": 0.145, "eff": 0.80, "shaft_mm": 12.0,
		"body": "can", "dia_mm": 200.0, "len_mm": 70.0, "mass_kg": 4.5, "cost": 120.0},
	"pmg1k": {"label": "1 kW low-speed PMG (48 V)", "rated_w": 1000.0, "rated_rpm": 500.0,
		"max_rpm": 900.0, "v_per_rpm": 0.14, "eff": 0.85, "shaft_mm": 25.0,
		"body": "can", "dia_mm": 230.0, "len_mm": 160.0, "mass_kg": 14.0, "cost": 380.0},
	"bldc6374": {"label": "6374 outrunner, 170 KV", "rated_w": 1500.0, "rated_rpm": 3000.0,
		"max_rpm": 6000.0, "v_per_rpm": 0.0059, "eff": 0.85, "shaft_mm": 8.0,
		"body": "can", "dia_mm": 63.0, "len_mm": 74.0, "mass_kg": 0.9, "cost": 70.0},
	"alt12": {"label": "12 V car alternator", "rated_w": 900.0, "rated_rpm": 3000.0,
		"max_rpm": 12000.0, "v_per_rpm": 0.012, "eff": 0.55, "shaft_mm": 17.0,
		"cut_in_rpm": 1100.0,
		"body": "alternator", "dia_mm": 130.0, "len_mm": 160.0, "mass_kg": 5.5, "cost": 80.0},
}

const ORIENTATIONS := ["horizontal", "vertical"]
const ORIENTATION_LABELS := {"horizontal": "Horizontal shaft", "vertical": "Vertical shaft"}
## Jets one runner can take: two on a horizontal shaft (the rest would spray
## up into the housing roof), up to six round a vertical one.
const MAX_JETS := {"horizontal": 2, "vertical": 6}
const BEARING_TYPES := ["pillow", "flange"]
const BEARING_LAYOUTS := ["overhung", "straddle"]
const BEARING_LAYOUT_LABELS := {"overhung": "Both on the drive side (overhung)",
	"straddle": "One each side (straddle)"}
const GEN_SIDES := ["above", "beside"]


static func cup_material(id: String) -> Dictionary:
	return CUP_MATERIALS.get(id, CUP_MATERIALS["nylon"])


static func plate_material(id: String) -> Dictionary:
	return PLATE_MATERIALS.get(id, PLATE_MATERIALS["steel"])


static func bolt(id: String) -> Dictionary:
	return BOLTS.get(id, BOLTS["m6"])


## Shear capacity (N) of one bolt through one shear plane.
static func bolt_shear_n(id: String) -> float:
	return 0.6 * BOLT_PROOF_MPA * float(bolt(id)["as"]) / BOLT_SHEAR_SF


## The insert bearing for a shaft (the nearest catalogue bore at or above it).
static func bearing_for(shaft_mm: float) -> Dictionary:
	var best := 40.0
	for s in SHAFTS:
		if float(s) >= shaft_mm - 0.01:
			best = float(s)
			break
	var b: Dictionary = (BEARINGS[best] as Dictionary).duplicate()
	b["bore"] = best
	return b


## The smallest jaw coupler taking the bigger of the two bores and the torque.
static func jaw_for(bore_mm: float, torque_nm: float = 0.0) -> Dictionary:
	for j in JAW_SIZES:
		if float(j["bore"]) >= bore_mm - 0.01 and float(j["torque"]) >= torque_nm:
			return j
	return JAW_SIZES[JAW_SIZES.size() - 1]


static func generator(id: String) -> Dictionary:
	return GENERATORS.get(id, GENERATORS["pma400"])


## A V-belt / timing pulley's pitch diameter (mm) from its teeth (timing) or
## as given (V-belt).
static func timing_pitch_d_mm(teeth: int) -> float:
	return float(teeth) * float(DRIVES["timing"]["pitch_mm"]) / PI
