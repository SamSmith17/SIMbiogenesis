class_name TcStandards
extends RefCounted

## Sanitary ("tri-clamp") dimension tables for the TC designer. Pure data,
## every number in MILLIMETRES, every row carries where it came from. A row
## (or a field) not checked against a published table carries
## `estimate: true`; `estimates()` lists them so the selftest can print what
## is still a guess. CLAUDE.md rule: never invent a constant without saying so.
##
## Series: ASME BPE / 3-A inch tube (OD in inches) with clamp ferrules. The
## metric DIN 32676 / ISO 2852 series is a second table for later; the spec
## carries `standard` from day one so it can be added behind this API.
##
## Sources (fetched 2026-11-06):
##   [SF] sanitaryfittings.us "Tri-Clamp sizing guide" (flange OD, tube ID,
##        tube OD per sanitary size) and its 2CMP 90° elbow table (A =
##        centre-to-face).
##   [DX] Dixon Valve sanitary catalogue, 7MP clamp tee table (A face to
##        face, B centre to face), citing ASME BPE tables DT-4.1.2-2 / -4.
## Wall = (tube OD − tube ID) / 2 from [SF]: 0.065" to 3", 0.083" at 4",
## 0.109" at 6" and 8" (the BPE tube walls).

const IN := 25.4

## Sanitary sizes, in order. Keys are strings: never float dict keys.
const SIZES := ["0.5", "0.75", "1", "1.5", "2", "2.5", "3", "4", "6", "8"]

## size → {od, id (tube, inch), flange (inch), clamp (the clamp/gasket size
## class: 1" and 1.5" share the 1.984" flange, ½" and ¾" the 0.984" mini)}.
const TUBE := {
	"0.5":  {"od": 0.500, "id": 0.370, "flange": 0.984, "clamp": "mini"},
	"0.75": {"od": 0.750, "id": 0.620, "flange": 0.984, "clamp": "mini"},
	"1":    {"od": 1.000, "id": 0.870, "flange": 1.984, "clamp": "1.5"},
	"1.5":  {"od": 1.500, "id": 1.370, "flange": 1.984, "clamp": "1.5"},
	"2":    {"od": 2.000, "id": 1.870, "flange": 2.516, "clamp": "2"},
	"2.5":  {"od": 2.500, "id": 2.370, "flange": 3.047, "clamp": "2.5"},
	"3":    {"od": 3.000, "id": 2.870, "flange": 3.579, "clamp": "3"},
	"4":    {"od": 4.000, "id": 3.834, "flange": 4.682, "clamp": "4"},
	"6":    {"od": 6.000, "id": 5.782, "flange": 6.562, "clamp": "6"},
	"8":    {"od": 8.000, "id": 7.782, "flange": 8.602, "clamp": "8"},
}
const TUBE_SOURCE := "[SF] sanitary sizing guide (flange OD, tube ID, tube OD)"

## 2CMP clamp × clamp 90° elbow, centre-to-face (inch) [SF].
const ELBOW90_CTF := {"0.5": 1.625, "0.75": 1.625, "1": 2.000, "1.5": 2.750, "2": 3.500,
	"2.5": 4.250, "3": 5.000, "4": 6.625, "6": 10.500, "8": 14.000}
const ELBOW90_SOURCE := "[SF] 2CMP elbow table, A = centre to face (8\" estimated)"
const ELBOW90_ESTIMATE := ["8"]

## 7MP clamp tee, centre-to-face B (inch) [DX] (= half the face-to-face A).
const TEE_CTF := {"0.5": 2.250, "0.75": 2.375, "1": 2.625, "1.5": 2.875, "2": 3.375,
	"2.5": 3.625, "3": 3.875, "4": 4.750, "6": 6.000, "8": 7.500}
const TEE_SOURCE := "[DX] 7MP tee table B, ASME BPE DT-4.1.2 (6\" and 8\" estimated)"
const TEE_ESTIMATE := ["6", "8"]

## Clamp ferrule PROFILE (the shape round the flange). Only the flange OD is
## tabulated above; the rim thickness, the 20° back taper the clamp's V
## grips, the hub length and the gasket bead groove are drawn to the usual
## look and flagged as estimates (they change no length an assembly adds up).
const FERRULE_RIM_MM := {"mini": 2.2, "1.5": 2.85, "2": 2.85, "2.5": 2.85, "3": 2.85, "4": 2.85, "6": 3.2, "8": 3.6}
const FERRULE_TAPER_DEG := 20.0
## Short weld ferrule (14WMP) and long (14AMP) hub lengths, face to tube end.
const FERRULE_SHORT_MM := {"mini": 12.7, "default": 21.6}
const FERRULE_LONG_MM := {"mini": 28.6, "default": 44.5}

## Gasket: compressed face-to-face gap a joint adds, and the bead the gasket
## carries (drawn as the ring between the two flanges).
const GASKET_GAP_MM := 1.6
const GASKETS := {
	"epdm":     {"label": "EPDM", "color": Color(0.08, 0.08, 0.09), "t_min_c": -40.0, "t_max_c": 150.0},
	"silicone": {"label": "Silicone", "color": Color(0.92, 0.90, 0.86), "t_min_c": -60.0, "t_max_c": 230.0},
	"ptfe":     {"label": "PTFE", "color": Color(0.96, 0.96, 0.95), "t_min_c": -70.0, "t_max_c": 260.0},
	"viton":    {"label": "FKM (Viton)", "color": Color(0.10, 0.10, 0.10), "t_min_c": -20.0, "t_max_c": 205.0},
	"buna":     {"label": "Buna-N", "color": Color(0.06, 0.06, 0.06), "t_min_c": -30.0, "t_max_c": 120.0},
}
const GASKET_SOURCE := "typical manufacturer temperature ranges (estimate — check the gasket's own sheet)"

## Clamps: type → label and a typical rated pressure (bar, at 20 °C) by
## clamp size. Ratings fall with size and temperature and differ by brand:
## all flagged estimates; the check names the lowest so the player looks it up.
const CLAMPS := {
	"single_pin": {"label": "Single-pin hinged (13MHHM)", "bar": {"mini": 31.0, "1.5": 31.0, "2": 27.0, "2.5": 24.0, "3": 20.0, "4": 17.0, "6": 10.0, "8": 7.0}},
	"double_pin": {"label": "Double-pin hinged (13MHP)", "bar": {"mini": 31.0, "1.5": 31.0, "2": 27.0, "2.5": 24.0, "3": 20.0, "4": 17.0, "6": 10.0, "8": 7.0}},
	"bolted":     {"label": "High-pressure bolted (13MHHS)", "bar": {"mini": 69.0, "1.5": 69.0, "2": 62.0, "2.5": 55.0, "3": 48.0, "4": 41.0, "6": 24.0, "8": 17.0}},
}
const CLAMP_SOURCE := "typical clamp ratings at room temperature (estimate)"

## NPT pipe ODs (inch), ASME B1.20.1 / B36.10 nominal pipe sizes.
const NPT_OD := {"0.125": 0.405, "0.25": 0.540, "0.375": 0.675, "0.5": 0.840, "0.75": 1.050, "1": 1.315, "1.25": 1.660, "1.5": 1.900, "2": 2.375}
const NPT_SIZES := ["0.25", "0.375", "0.5", "0.75", "1"]
const NPT_SOURCE := "ASME B36.10 nominal pipe OD"

## Hose barb sizes (hose ID, inch).
const BARB_SIZES := ["0.25", "0.375", "0.5", "0.75", "1"]

## Stainless density (kg/m³), 304 / 316.
const STEEL_KG_M3 := 8000.0


static func has_size(size: String) -> bool:
	return TUBE.has(size)


## A size's numbers in mm: {od, id, wall, flange, clamp, r_out, r_in, r_flange}.
static func tube(size: String) -> Dictionary:
	var t: Dictionary = TUBE.get(size, TUBE["1.5"])
	var od := float(t["od"]) * IN
	var idv := float(t["id"]) * IN
	var fl := float(t["flange"]) * IN
	return {"od": od, "id": idv, "wall": (od - idv) * 0.5, "flange": fl, "clamp": str(t["clamp"]),
		"r_out": od * 0.5, "r_in": idv * 0.5, "r_flange": fl * 0.5}


## The clamp class two sizes must share to mate ("1" and "1.5" both "1.5").
static func clamp_class(size: String) -> String:
	return str((TUBE.get(size, {}) as Dictionary).get("clamp", ""))


static func clamps_match(a: String, b: String) -> bool:
	return not clamp_class(a).is_empty() and clamp_class(a) == clamp_class(b)


## The ferrule profile numbers in mm: rim (flange edge thickness), taper
## (the back face's run along the axis from the rim to the tube), hub (face
## to the end of the ferrule), groove (r0, r1 of the gasket bead groove).
static func ferrule(size: String, long: bool = false) -> Dictionary:
	var t := tube(size)
	var cls := str(t["clamp"])
	var rim := float(FERRULE_RIM_MM.get(cls, 2.85))
	var drop := float(t["r_flange"]) - float(t["r_out"])
	var taper := drop * tan(deg_to_rad(FERRULE_TAPER_DEG)) if drop > 0.0 else 0.0
	var key := "mini" if cls == "mini" else "default"
	var hub := float((FERRULE_LONG_MM if long else FERRULE_SHORT_MM)[key])
	hub = maxf(hub, rim + taper + 2.0)
	var r_in := float(t["r_in"])
	var g0 := r_in + (float(t["r_flange"]) - r_in) * 0.38
	var g1 := r_in + (float(t["r_flange"]) - r_in) * 0.56
	return {"rim": rim, "taper": taper, "hub": hub, "groove": [g0, g1], "groove_depth": 0.6}


## 90° elbow centre-to-face (mm).
static func elbow90_ctf(size: String) -> float:
	return float(ELBOW90_CTF.get(size, 2.75)) * IN


## 45° elbow centre-to-face (mm): the same bend radius as the 90° (CTF minus
## the straight hub) carried through 45°. Estimate: published 2KMP tables
## were not fetched.
static func elbow45_ctf(size: String) -> float:
	var hub := float(ferrule(size)["hub"])
	var r := bend_radius(size)
	return r * tan(deg_to_rad(22.5)) + hub


## The 2CMP elbow's centre-line bend radius (mm): CTF less a straight run of
## one short ferrule hub, floored at 1 × OD (estimate — the tables give CTF).
static func bend_radius(size: String) -> float:
	var t := tube(size)
	var hub := float(ferrule(size)["hub"])
	return maxf(elbow90_ctf(size) - hub, float(t["od"]))


## Tee centre-to-face (mm).
static func tee_ctf(size: String) -> float:
	return float(TEE_CTF.get(size, 2.875)) * IN


## Concentric reducer length face to face (mm). Estimate: 31MP tables vary
## (≈ 4" for small, longer for big steps); drawn as two ferrule hubs plus a
## cone of 15° half-angle.
static func reducer_len(big: String, small: String) -> float:
	var a := tube(big)
	var b := tube(small)
	var cone := absf(float(a["r_out"]) - float(b["r_out"])) / tan(deg_to_rad(15.0))
	return float(ferrule(big)["hub"]) + float(ferrule(small)["hub"]) + maxf(cone, 6.0)


## Short-pattern (cast-style) elbow / tee centre-to-face (mm): half the OD
## plus one short ferrule hub plus 6 mm. Estimate: no short-fitting table
## was fetched.
static func short_ctf(size: String) -> float:
	return float(tube(size)["od"]) * 0.5 + float(ferrule(size)["hub"]) + 6.0


static func short_radius(size: String) -> float:
	return short_ctf(size) - float(ferrule(size)["hub"])


static func npt_od(size: String) -> float:
	return float(NPT_OD.get(size, 0.840)) * IN


static func clamp_rating_bar(clamp_type: String, size: String) -> float:
	var c: Dictionary = CLAMPS.get(clamp_type, CLAMPS["single_pin"])
	return float((c["bar"] as Dictionary).get(clamp_class(size), 10.0))


static func size_label(size: String) -> String:
	match size:
		"0.5": return "½\""
		"0.75": return "¾\""
		"0.125": return "⅛\""
		"0.25": return "¼\""
		"0.375": return "⅜\""
		"1.5": return "1½\""
		"2.5": return "2½\""
		"1.25": return "1¼\""
	return "%s\"" % size


## Every field still a guess, for the selftest's report.
static func estimates() -> Array:
	var out := []
	for s in ELBOW90_ESTIMATE:
		out.append("2CMP elbow CTF %s" % s)
	for s in TEE_ESTIMATE:
		out.append("7MP tee CTF %s" % s)
	out.append("ferrule rim / taper / hub / groove (drawn)")
	out.append("45° elbow CTF (from the 90° bend radius)")
	out.append("reducer length (15° cone)")
	out.append("clamp ratings")
	out.append("gasket temperature ranges")
	out.append("short-pattern elbow / tee CTF (half OD + hub + 6 mm)")
	out.append("specialty fitting bodies (drawn to the reference GLB's look)")
	return out
