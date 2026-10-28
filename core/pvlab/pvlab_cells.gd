class_name PvLabCells
extends RefCounted

## Solar cell technologies and formats for the Solar designer. Pure data.
##
## Each technology carries two things: how it LOOKS (the cell shader's base
## colour, crystal flake, sheen, whether it has front metal) and what it does
## ELECTRICALLY per cell at STC (Voc, short-circuit current density, the
## Vmp/Voc and Imp/Isc ratios, temperature coefficients, NOCT). A module made
## of N cells in series in P parallel paths then has
##   Voc = N · cell_voc,  Isc = P · jsc · cell_area,
##   Vmp = Voc · vm,      Imp = Isc · im.
##
## The electrical numbers are TYPICAL values read back from public data
## sheets of real modules (cell counts and areas divided out):
##   mono_perc  — JA Solar JAM60S20-380/MR (120 half-cut M6, 41.62 V Voc,
##                11.52 A Isc, 34.77 / 10.93 at Pmax; −0.272 %/°C Voc,
##                −0.35 %/°C Pmax, +0.044 %/°C Isc)
##   poly       — 60-cell M2 polycrystalline 275 W class (38.4 V, 9.2 A,
##                31.4 V / 8.76 A; −0.31 / −0.40 / +0.05 %/°C)
##   topcon     — n-type TOPCon 182 mm class (Jinko Tiger Neo; −0.25 / −0.30)
##   hjt        — heterojunction (REC Alpha / Meyer Burger; −0.24 / −0.26)
##   ibc        — back-contact (SunPower Maxeon 3; −0.236 / −0.29), no front metal
##   cdte       — First Solar Series 6 (264 strips, 219 V, 2.54 A; −0.28 / −0.32)
##   cigs       — flexible CIGS laminate class (−0.30 / −0.36)
##   asi        — single-junction amorphous silicon (−0.30 / −0.20)
## They are starting points: a module in "datasheet" mode uses the
## nameplate the player types instead.

const TECH_ORDER := ["mono_perc", "topcon", "hjt", "ibc", "poly", "cigs", "cdte", "asi"]

## look: colour (sRGB, linear in the shader), flake (poly crystal mottling
## 0..1), sheen (specular tint 0..1), metal (front busbars / fingers),
## film (monolithic thin film: strips with scribe lines, no wafer gaps).
## elec: voc (V/cell), jsc (mA/cm²), vm (Vmp/Voc), im (Imp/Isc),
## voc_coeff / isc_coeff / pmax_coeff (%/°C), noct_c.
const TECHS := {
	"mono_perc": {"label": "Mono PERC (p-type)", "crystalline": true,
		"look": {"color": Color(0.035, 0.045, 0.085), "flake": 0.0, "sheen": 0.35, "metal": true, "film": false},
		"elec": {"voc": 0.694, "jsc": 42.0, "vm": 0.835, "im": 0.949,
			"voc_coeff": -0.272, "isc_coeff": 0.044, "pmax_coeff": -0.35, "noct_c": 45.0}},
	"topcon": {"label": "Mono TOPCon (n-type)", "crystalline": true,
		"look": {"color": Color(0.03, 0.04, 0.08), "flake": 0.0, "sheen": 0.32, "metal": true, "film": false},
		"elec": {"voc": 0.715, "jsc": 42.4, "vm": 0.842, "im": 0.954,
			"voc_coeff": -0.25, "isc_coeff": 0.045, "pmax_coeff": -0.30, "noct_c": 45.0}},
	"hjt": {"label": "Heterojunction (HJT)", "crystalline": true,
		"look": {"color": Color(0.04, 0.05, 0.11), "flake": 0.0, "sheen": 0.40, "metal": true, "film": false},
		"elec": {"voc": 0.740, "jsc": 39.6, "vm": 0.850, "im": 0.955,
			"voc_coeff": -0.24, "isc_coeff": 0.04, "pmax_coeff": -0.26, "noct_c": 44.0}},
	"ibc": {"label": "Back-contact (IBC)", "crystalline": true,
		"look": {"color": Color(0.018, 0.02, 0.035), "flake": 0.0, "sheen": 0.25, "metal": false, "film": false},
		"elec": {"voc": 0.720, "jsc": 41.6, "vm": 0.838, "im": 0.960,
			"voc_coeff": -0.236, "isc_coeff": 0.058, "pmax_coeff": -0.29, "noct_c": 44.0}},
	"poly": {"label": "Polycrystalline", "crystalline": true,
		"look": {"color": Color(0.06, 0.14, 0.34), "flake": 0.85, "sheen": 0.55, "metal": true, "film": false},
		"elec": {"voc": 0.640, "jsc": 37.5, "vm": 0.818, "im": 0.952,
			"voc_coeff": -0.31, "isc_coeff": 0.05, "pmax_coeff": -0.40, "noct_c": 45.0}},
	"cigs": {"label": "CIGS thin film", "crystalline": false,
		"look": {"color": Color(0.02, 0.022, 0.026), "flake": 0.0, "sheen": 0.20, "metal": false, "film": true},
		"elec": {"voc": 0.680, "jsc": 33.0, "vm": 0.800, "im": 0.915,
			"voc_coeff": -0.30, "isc_coeff": 0.01, "pmax_coeff": -0.36, "noct_c": 46.0}},
	"cdte": {"label": "CdTe thin film", "crystalline": false,
		"look": {"color": Color(0.045, 0.035, 0.028), "flake": 0.0, "sheen": 0.22, "metal": false, "film": true},
		"elec": {"voc": 0.830, "jsc": 27.5, "vm": 0.823, "im": 0.917,
			"voc_coeff": -0.28, "isc_coeff": 0.04, "pmax_coeff": -0.32, "noct_c": 45.0}},
	"asi": {"label": "Amorphous silicon (a-Si)", "crystalline": false,
		"look": {"color": Color(0.16, 0.085, 0.07), "flake": 0.0, "sheen": 0.30, "metal": false, "film": true},
		"elec": {"voc": 0.880, "jsc": 15.0, "vm": 0.760, "im": 0.850,
			"voc_coeff": -0.30, "isc_coeff": 0.08, "pmax_coeff": -0.20, "noct_c": 46.0}},
}

## Wafer formats (edge length, mm) and the diameter of the ingot they are cut
## from, which sets the corner chamfer of a pseudo-square mono wafer.
## M2/G1/M6 from the ITRPV wafer roadmap; M10 182 mm and G12 210 mm are the
## current full squares.
const FORMATS := {
	"m2": {"label": "M2 156.75 mm", "edge_mm": 156.75, "diameter_mm": 210.0},
	"g1": {"label": "G1 158.75 mm", "edge_mm": 158.75, "diameter_mm": 223.0},
	"m6": {"label": "M6 166 mm", "edge_mm": 166.0, "diameter_mm": 223.0},
	"m10": {"label": "M10 182 mm", "edge_mm": 182.0, "diameter_mm": 247.0},
	"g12": {"label": "G12 210 mm", "edge_mm": 210.0, "diameter_mm": 295.0},
	"m0": {"label": "125 mm (small modules)", "edge_mm": 125.0, "diameter_mm": 150.0},
	"custom": {"label": "Custom size", "edge_mm": 156.0, "diameter_mm": 0.0},
}
const FORMAT_ORDER := ["m2", "g1", "m6", "m10", "g12", "m0", "custom"]

## How a wafer is cut and wired. `parallel` = current paths per module (a
## half-cut module is two halves in parallel), `pieces` = pieces per wafer.
const CUTS := {
	"full": {"label": "Full cells", "pieces": 1, "parallel": 1},
	"half": {"label": "Half-cut (split) cells", "pieces": 2, "parallel": 2},
	"third": {"label": "Third-cut cells", "pieces": 3, "parallel": 3},
	"shingled": {"label": "Shingled strips", "pieces": 5, "parallel": 1},
	"strip": {"label": "Thin-film strips", "pieces": 1, "parallel": 1},
}
const CUT_ORDER := ["full", "half", "third", "shingled", "strip"]

## Front metallisation: busbar counts (0 = IBC / thin film / shingled).
const BUSBARS := [0, 2, 3, 4, 5, 9, 12, 16]

## Schottky bypass-diode forward drop at module current (V). Data sheets of
## SR/SB series 15–20 A Schottkys give 0.4–0.55 V; 0.5 V is the usual figure.
const BYPASS_DROP_V := 0.5

## STC cell temperature and irradiance.
const STC_T_C := 25.0
const STC_G := 1000.0


static func tech(id: String) -> Dictionary:
	return TECHS.get(id, TECHS["mono_perc"])


static func format_edge_mm(fmt: String, custom_mm: float = 156.0) -> float:
	if fmt == "custom":
		return maxf(custom_mm, 10.0)
	return float((FORMATS.get(fmt, FORMATS["m10"]) as Dictionary)["edge_mm"])


## The corner chamfer leg (mm) of a pseudo-square wafer of `edge` cut from an
## ingot of `diameter`: the square's corner lies outside the circle by
## (edge·√2 − diameter)/2 along the diagonal, so each 45° leg is √2 times that.
static func chamfer_mm(edge: float, diameter: float) -> float:
	if diameter <= 0.0 or diameter >= edge * sqrt(2.0):
		return 0.0
	return (edge * sqrt(2.0) - diameter) * 0.5 * sqrt(2.0)


## Area of one FULL wafer (cm²): the square minus its four chamfer triangles.
static func wafer_area_cm2(edge: float, chamfer: float) -> float:
	return (edge * edge - 2.0 * chamfer * chamfer) / 100.0
