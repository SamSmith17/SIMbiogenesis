class_name DomeLabMaterials
extends RefCounted

## The stock a dome or zome is built from: strut sections, hub hardware,
## face sheets. Pure tables with cited numbers — the designer, the bill of
## materials and the checks all read them here, so a new section is one entry.
##
## Strut sections (`STRUTS`), metres / mm / kg:
##   kind      "tube" (round), "sq_tube", "bar" (flat, bends along the
##             surface), "lumber" (rectangular solid), "beam" (solid plastic)
##   od_mm / wall_mm for tubes, w_mm × t_mm for bars / lumber / beams
##   kg_m      mass per metre
##   stock_m   the length it is sold in
##   flatten   the ends can be flattened in a press / vise and drilled
##             (steel EMT yes; PVC cracks, wood and plastic beams cannot)
##   bend_strain  the elastic strain a flat bar tolerates when bent to the
##             dome's curve (HDPE ~2 %, PVC 1 %, plywood 0.7 %, steel 0.1 %)
##   e_gpa     Young's modulus, for the slenderness check
##
## Sources: EMT (UL 797 / Allied Tube catalog: 1/2" OD 0.706", wall 0.042",
## 29.5 lb/100 ft; 3/4" 0.922" / 0.049" / 45; 1" 1.163" / 0.057" / 65;
## 1-1/4" 1.510" / 0.065" / 96); PVC sch 40 (ASTM D1785); SPF lumber at
## 450 kg/m³; A513 1" × 16 ga square tube 1.12 kg/m; 6061 tube 2.70 g/cc;
## HDPE 0.95, PP 0.90 g/cc; Baltic birch 0.68 g/cc.

const STRUTS := {
	"emt_12": {"label": "1/2\" EMT conduit", "kind": "tube", "od_mm": 17.9, "wall_mm": 1.07,
		"kg_m": 0.44, "stock_m": 3.048, "flatten": true, "bend_strain": 0.001, "e_gpa": 200.0,
		"color": Color(0.70, 0.72, 0.74)},
	"emt_34": {"label": "3/4\" EMT conduit", "kind": "tube", "od_mm": 23.4, "wall_mm": 1.25,
		"kg_m": 0.67, "stock_m": 3.048, "flatten": true, "bend_strain": 0.001, "e_gpa": 200.0,
		"color": Color(0.70, 0.72, 0.74)},
	"emt_1": {"label": "1\" EMT conduit", "kind": "tube", "od_mm": 29.5, "wall_mm": 1.45,
		"kg_m": 0.97, "stock_m": 3.048, "flatten": true, "bend_strain": 0.001, "e_gpa": 200.0,
		"color": Color(0.70, 0.72, 0.74)},
	"emt_114": {"label": "1-1/4\" EMT conduit", "kind": "tube", "od_mm": 38.4, "wall_mm": 1.65,
		"kg_m": 1.43, "stock_m": 3.048, "flatten": true, "bend_strain": 0.001, "e_gpa": 200.0,
		"color": Color(0.70, 0.72, 0.74)},
	"steel_sq_1": {"label": "1\" × 16 ga steel square tube", "kind": "sq_tube", "od_mm": 25.4,
		"wall_mm": 1.5, "kg_m": 1.12, "stock_m": 6.096, "flatten": false, "bend_strain": 0.001,
		"e_gpa": 200.0, "color": Color(0.35, 0.36, 0.38)},
	"alu_tube_1": {"label": "1\" × 1/16\" aluminium tube", "kind": "tube", "od_mm": 25.4,
		"wall_mm": 1.6, "kg_m": 0.32, "stock_m": 3.66, "flatten": true, "bend_strain": 0.003,
		"e_gpa": 69.0, "color": Color(0.80, 0.82, 0.85)},
	"pvc_34": {"label": "3/4\" PVC sch 40", "kind": "tube", "od_mm": 26.7, "wall_mm": 2.87,
		"kg_m": 0.33, "stock_m": 3.048, "flatten": false, "bend_strain": 0.01, "e_gpa": 2.8,
		"color": Color(0.88, 0.88, 0.86)},
	"pvc_1": {"label": "1\" PVC sch 40", "kind": "tube", "od_mm": 33.4, "wall_mm": 3.38,
		"kg_m": 0.48, "stock_m": 3.048, "flatten": false, "bend_strain": 0.01, "e_gpa": 2.8,
		"color": Color(0.88, 0.88, 0.86)},
	"wood_2x2": {"label": "2×2 lumber (38 × 38 mm)", "kind": "lumber", "w_mm": 38.0, "t_mm": 38.0,
		"kg_m": 0.65, "stock_m": 2.44, "flatten": false, "bend_strain": 0.004, "e_gpa": 9.0,
		"color": Color(0.74, 0.60, 0.40)},
	"wood_2x4": {"label": "2×4 lumber (38 × 89 mm)", "kind": "lumber", "w_mm": 89.0, "t_mm": 38.0,
		"kg_m": 1.52, "stock_m": 2.44, "flatten": false, "bend_strain": 0.004, "e_gpa": 9.0,
		"color": Color(0.74, 0.60, 0.40)},
	"bamboo_40": {"label": "Bamboo pole ~40 mm", "kind": "tube", "od_mm": 40.0, "wall_mm": 8.0,
		"kg_m": 0.65, "stock_m": 3.0, "flatten": false, "bend_strain": 0.005, "e_gpa": 12.0,
		"color": Color(0.80, 0.70, 0.42)},
	"pp_beam_40": {"label": "Recycled PP beam 40 × 40 mm", "kind": "beam", "w_mm": 40.0, "t_mm": 40.0,
		"kg_m": 1.44, "stock_m": 2.0, "flatten": false, "bend_strain": 0.015, "e_gpa": 1.4,
		"color": Color(0.55, 0.72, 0.62)},
	"hdpe_bar_50x6": {"label": "HDPE flat bar 50 × 6 mm", "kind": "bar", "w_mm": 50.0, "t_mm": 6.0,
		"kg_m": 0.285, "stock_m": 3.0, "flatten": false, "bend_strain": 0.02, "e_gpa": 0.9,
		"color": Color(0.20, 0.45, 0.70)},
	"hdpe_bar_75x10": {"label": "HDPE flat bar 75 × 10 mm", "kind": "bar", "w_mm": 75.0, "t_mm": 10.0,
		"kg_m": 0.71, "stock_m": 3.0, "flatten": false, "bend_strain": 0.02, "e_gpa": 0.9,
		"color": Color(0.20, 0.45, 0.70)},
	"ply_bar_12x75": {"label": "Plywood strip 12 × 75 mm", "kind": "bar", "w_mm": 75.0, "t_mm": 12.0,
		"kg_m": 0.61, "stock_m": 2.44, "flatten": false, "bend_strain": 0.007, "e_gpa": 10.0,
		"color": Color(0.80, 0.66, 0.42)},
	"ply_rib_18x90": {"label": "Plywood rib 18 × 90 mm (CNC arc)", "kind": "bar", "w_mm": 90.0,
		"t_mm": 18.0, "kg_m": 1.10, "stock_m": 2.44, "flatten": false, "bend_strain": 0.0,
		"e_gpa": 10.0, "color": Color(0.80, 0.66, 0.42)},
	"steel_bar_25x3": {"label": "Steel flat bar 25 × 3 mm", "kind": "bar", "w_mm": 25.0, "t_mm": 3.0,
		"kg_m": 0.59, "stock_m": 6.0, "flatten": false, "bend_strain": 0.0012, "e_gpa": 200.0,
		"color": Color(0.40, 0.41, 0.44)},
	"alu_bar_40x3": {"label": "Aluminium flat bar 40 × 3 mm", "kind": "bar", "w_mm": 40.0, "t_mm": 3.0,
		"kg_m": 0.32, "stock_m": 3.66, "flatten": false, "bend_strain": 0.003, "e_gpa": 69.0,
		"color": Color(0.80, 0.82, 0.85)},
}
const STRUT_ORDER := ["emt_12", "emt_34", "emt_1", "emt_114", "steel_sq_1", "alu_tube_1", "pvc_34",
	"pvc_1", "wood_2x2", "wood_2x4", "bamboo_40", "pp_beam_40", "hdpe_bar_50x6", "hdpe_bar_75x10",
	"ply_bar_12x75", "ply_rib_18x90", "steel_bar_25x3", "alu_bar_40x3"]

## Sheet stock for faces and plates: kg/m², the sheet it is sold as (mm),
## whether it folds (a flange can be bent along an edge) and the thickness.
const SHEETS := {
	"none": {"label": "No covering", "kg_m2": 0.0, "t_mm": 0.0, "sheet_w": 0.0, "sheet_h": 0.0,
		"folds": false, "color": Color(1, 1, 1, 0)},
	"tarp_pe": {"label": "Poly tarp / shade cloth", "kg_m2": 0.2, "t_mm": 0.3, "sheet_w": 3000.0,
		"sheet_h": 6000.0, "folds": false, "color": Color(0.85, 0.87, 0.80, 0.75)},
	"canvas": {"label": "Canvas", "kg_m2": 0.55, "t_mm": 0.8, "sheet_w": 1500.0, "sheet_h": 10000.0,
		"folds": false, "color": Color(0.86, 0.80, 0.66, 0.9)},
	"ply_6": {"label": "Plywood 6 mm (1/4\")", "kg_m2": 3.6, "t_mm": 6.0, "sheet_w": 1220.0,
		"sheet_h": 2440.0, "folds": false, "color": Color(0.80, 0.66, 0.42)},
	"ply_12": {"label": "Plywood 12 mm (1/2\")", "kg_m2": 7.2, "t_mm": 12.0, "sheet_w": 1220.0,
		"sheet_h": 2440.0, "folds": false, "color": Color(0.80, 0.66, 0.42)},
	"polycarb_6": {"label": "Twin-wall polycarbonate 6 mm", "kg_m2": 1.3, "t_mm": 6.0,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "folds": false, "color": Color(0.80, 0.92, 1.0, 0.45)},
	"polycarb_4": {"label": "Solid polycarbonate 4 mm", "kg_m2": 4.8, "t_mm": 4.0,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "folds": true, "color": Color(0.85, 0.95, 1.0, 0.35)},
	"steel_06": {"label": "Sheet steel 0.6 mm (24 ga)", "kg_m2": 4.7, "t_mm": 0.6,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "folds": true, "color": Color(0.62, 0.64, 0.67)},
	"alu_1": {"label": "Aluminium sheet 1 mm", "kg_m2": 2.7, "t_mm": 1.0, "sheet_w": 1220.0,
		"sheet_h": 2440.0, "folds": true, "color": Color(0.82, 0.84, 0.87)},
	"hdpe_3": {"label": "HDPE sheet 3 mm", "kg_m2": 2.85, "t_mm": 3.0, "sheet_w": 1220.0,
		"sheet_h": 2440.0, "folds": true, "color": Color(0.25, 0.50, 0.75)},
	"pp_sheet_8": {"label": "Recycled PP sheet 8 mm", "kg_m2": 7.2, "t_mm": 8.0, "sheet_w": 1000.0,
		"sheet_h": 1000.0, "folds": false, "color": Color(0.55, 0.72, 0.62)},
	"corflute_5": {"label": "Corrugated plastic 5 mm", "kg_m2": 1.0, "t_mm": 5.0,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "folds": true, "color": Color(0.95, 0.95, 0.92, 0.9)},
}
const SHEET_ORDER := ["none", "tarp_pe", "canvas", "ply_6", "ply_12", "polycarb_6", "polycarb_4",
	"steel_06", "alu_1", "hdpe_3", "pp_sheet_8", "corflute_5"]

## Bolts: nominal diameter (mm), the drill for it, nut + two washers' height,
## and standard lengths (mm) a hardware store carries.
const BOLTS := {
	"m6": {"label": "M6", "d_mm": 6.0, "hole_mm": 6.6, "nut_mm": 5.0, "washer_mm": 1.6,
		"kg_each": 0.012, "lengths": [20, 25, 30, 40, 50, 60, 70, 80, 100, 120]},
	"m8": {"label": "M8", "d_mm": 8.0, "hole_mm": 8.5, "nut_mm": 6.5, "washer_mm": 1.6,
		"kg_each": 0.024, "lengths": [25, 30, 40, 50, 60, 70, 80, 100, 120, 150]},
	"m10": {"label": "M10", "d_mm": 10.0, "hole_mm": 10.5, "nut_mm": 8.0, "washer_mm": 2.0,
		"kg_each": 0.045, "lengths": [30, 40, 50, 60, 70, 80, 100, 120, 150]},
	"5_16": {"label": "5/16\"", "d_mm": 7.94, "hole_mm": 8.5, "nut_mm": 6.9, "washer_mm": 1.6,
		"kg_each": 0.022, "lengths": [25, 32, 38, 51, 64, 76, 89, 102, 127]},
	"3_8": {"label": "3/8\"", "d_mm": 9.53, "hole_mm": 10.3, "nut_mm": 8.3, "washer_mm": 2.0,
		"kg_each": 0.040, "lengths": [25, 32, 38, 51, 64, 76, 89, 102, 127, 152]},
}
const BOLT_ORDER := ["m6", "m8", "m10", "5_16", "3_8"]

const STEEL_KG_M3 := 7850.0
const ALU_KG_M3 := 2700.0
const PLA_KG_M3 := 1240.0


static func strut(id: String) -> Dictionary:
	return STRUTS.get(id, STRUTS["emt_34"])


static func sheet(id: String) -> Dictionary:
	return SHEETS.get(id, SHEETS["none"])


static func bolt(id: String) -> Dictionary:
	return BOLTS.get(id, BOLTS["3_8"])


## The section's outside size across (mm): tube OD, bar width.
static func strut_width_mm(s: Dictionary) -> float:
	if str(s.get("kind", "tube")) in ["tube", "sq_tube"]:
		return float(s.get("od_mm", 25.0))
	return float(s.get("w_mm", 40.0))


## The section's thickness (mm) in the direction a stack grows: tube OD
## flattened = ~2 walls; a bar its thickness; lumber its thickness.
static func strut_stack_mm(s: Dictionary, flattened: bool) -> float:
	var kind := str(s.get("kind", "tube"))
	if kind in ["tube", "sq_tube"]:
		if flattened:
			return 2.0 * float(s.get("wall_mm", 1.2)) + 0.4
		return float(s.get("od_mm", 25.0))
	return float(s.get("t_mm", 10.0))


## Radius of gyration (mm) for the slenderness check.
static func strut_gyration_mm(s: Dictionary) -> float:
	var kind := str(s.get("kind", "tube"))
	if kind == "tube":
		var ro := float(s.get("od_mm", 25.0)) * 0.5
		var ri := ro - float(s.get("wall_mm", 1.2))
		return 0.5 * sqrt(ro * ro + ri * ri)
	if kind == "sq_tube":
		var a := float(s.get("od_mm", 25.0))
		var b := a - 2.0 * float(s.get("wall_mm", 1.5))
		return sqrt((a * a + b * b) / 12.0)
	# Solid rectangle about its weak axis.
	return float(s.get("t_mm", 10.0)) / sqrt(12.0)


## The smallest standard bolt at least `need_mm` long.
static func bolt_length_mm(b: Dictionary, need_mm: float) -> int:
	for L in b.get("lengths", []):
		if float(L) >= need_mm - 1e-6:
			return int(L)
	var lens: Array = b.get("lengths", [100])
	return int(lens[lens.size() - 1])
