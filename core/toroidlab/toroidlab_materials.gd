class_name ToroidLabMaterials
extends RefCounted

## The stock a toroid is built from: bent tube, the pipe connectors that join
## it, tension cable, the canopy's sheet and the panels on top. Pure tables
## with cited numbers — the designer, the bill of materials and the checks
## all read them here, so a new section is one entry.
##
## Tubes (`TUBES`), mm / kg / m:
##   od_mm / wall_mm, kg_m (steel 7850 kg/m³: π/4·(OD² − ID²)·ρ), stock_m (the
##   length it is sold in), min_bend_r_m (the tightest centreline radius a
##   hand / roll bender puts in it without kinking, ~4–6 × OD for thin wall),
##   fits: the connector series it slides into, look (how it is drawn).
## Sources: 1" × 0.065" ERW / DOM mild steel 0.968 kg/m (A513, 1.65 mm wall);
## EMT (UL 797 / Allied Tube: 3/4" 0.922" OD × 0.049", 45 lb/100 ft; 1"
## 1.163" × 0.057", 65 lb/100 ft); 6061 1" × 1/16" tube 0.32 kg/m; PVC sch 40
## (ASTM D1785).
##
## Connectors: structural pipe fittings of the clamp / set-screw kind (Steel
## Tek, Maker Pipe, Kee Klamp style) for 1" OD tube. A fitting is named by how
## many tube ends it takes and how: a coupler joins two ends in line, a tee
## takes a run and a branch, a cross two runs, a crossover clamps two tubes
## that pass each other, a swivel takes a brace at any angle, an eye anchors
## a cable, a foot stands a rib end on the ground.
##
## Sheets: corrugated polypropylene (correx / coroplast) at its sold sizes;
## 10 mm board ~1.5 kg/m² (Coroplast / Primex data sheets list 1,500–1,800
## g/m² for 10 mm), 6 mm ~1.0, 4 mm ~0.7. They score and fold along the flutes
## and across them with a scoring wheel.
##
## Panels: flexible monocrystalline modules bend to the frame's curve
## (manufacturers allow ~30° of arc); rigid ones must lie flat.

const STEEL_KG_M3 := 7850.0

const TUBES := {
	"steel_1_065": {"label": "1\" OD × 0.065\" mild steel tube", "od_mm": 25.4, "wall_mm": 1.65,
		"kg_m": 0.968, "stock_m": 6.096, "min_bend_r_m": 0.15, "fits": "1in", "look": "corten",
		"e_gpa": 200.0, "color": Color(0.45, 0.25, 0.15)},
	"steel_34_065": {"label": "3/4\" OD × 0.065\" mild steel tube", "od_mm": 19.05, "wall_mm": 1.65,
		"kg_m": 0.708, "stock_m": 6.096, "min_bend_r_m": 0.11, "fits": "34in", "look": "corten",
		"e_gpa": 200.0, "color": Color(0.45, 0.25, 0.15)},
	"steel_114_083": {"label": "1-1/4\" OD × 0.083\" mild steel tube", "od_mm": 31.75, "wall_mm": 2.11,
		"kg_m": 1.54, "stock_m": 6.096, "min_bend_r_m": 0.2, "fits": "114in", "look": "corten",
		"e_gpa": 200.0, "color": Color(0.45, 0.25, 0.15)},
	"emt_34": {"label": "3/4\" EMT conduit (0.922\" OD)", "od_mm": 23.4, "wall_mm": 1.25,
		"kg_m": 0.67, "stock_m": 3.048, "min_bend_r_m": 0.14, "fits": "1in", "look": "galv",
		"e_gpa": 200.0, "color": Color(0.70, 0.72, 0.74)},
	"emt_1": {"label": "1\" EMT conduit (1.163\" OD)", "od_mm": 29.5, "wall_mm": 1.45,
		"kg_m": 0.97, "stock_m": 3.048, "min_bend_r_m": 0.17, "fits": "114in", "look": "galv",
		"e_gpa": 200.0, "color": Color(0.70, 0.72, 0.74)},
	"alu_1_062": {"label": "1\" × 1/16\" 6061 aluminium tube", "od_mm": 25.4, "wall_mm": 1.6,
		"kg_m": 0.32, "stock_m": 3.66, "min_bend_r_m": 0.2, "fits": "1in", "look": "alu",
		"e_gpa": 69.0, "color": Color(0.80, 0.82, 0.85)},
	"pvc_34": {"label": "3/4\" PVC sch 40 (1.05\" OD)", "od_mm": 26.7, "wall_mm": 2.87,
		"kg_m": 0.33, "stock_m": 3.048, "min_bend_r_m": 0.5, "fits": "pvc34", "look": "plastic",
		"e_gpa": 2.8, "color": Color(0.88, 0.88, 0.86)},
}
const TUBE_ORDER := ["steel_1_065", "steel_34_065", "steel_114_083", "emt_34", "emt_1", "alu_1_062", "pvc_34"]

## Connector kinds (per tube series the mass scales with the OD).
const CONNECTORS := {
	"coupler": {"label": "Straight coupler (180°)", "kg": 0.12,
		"detail": "joins two tube ends in line"},
	"tee": {"label": "Tee", "kg": 0.18, "detail": "a run with a branch at the node"},
	"cross": {"label": "Cross (4-way)", "kg": 0.24, "detail": "two runs crossing at the node"},
	"cross5": {"label": "5-way cross", "kg": 0.30, "detail": "cross with a side outlet for a post"},
	"crossover": {"label": "Crossover clamp", "kg": 0.20,
		"detail": "two tubes passing each other, one OD apart"},
	"swivel": {"label": "Swivel brace clamp", "kg": 0.16, "detail": "takes a brace at any angle"},
	"eye": {"label": "Eye clamp (cable anchor)", "kg": 0.10, "detail": "a cable's eye on a tube"},
	"foot": {"label": "Base foot / flange", "kg": 0.25, "detail": "stands a tube end on the ground"},
	"elbow": {"label": "Adjustable elbow", "kg": 0.16, "detail": "two ends at an angle"},
}
const CONNECTOR_SERIES := {"1in": "1\" pipe series", "34in": "3/4\" pipe series",
	"114in": "1-1/4\" pipe series", "pvc34": "3/4\" PVC fittings"}

## Tension lines and their hardware (turnbuckle + two thimbles + clips).
const CABLES := {
	"cable_18": {"label": "1/8\" galvanised wire rope 7×19", "d_mm": 3.2, "kg_m": 0.04,
		"break_kn": 7.6, "color": Color(0.55, 0.57, 0.6)},
	"cable_316": {"label": "3/16\" galvanised wire rope 7×19", "d_mm": 4.8, "kg_m": 0.09,
		"break_kn": 16.9, "color": Color(0.55, 0.57, 0.6)},
	"dyneema_4": {"label": "4 mm Dyneema (SK78) line", "d_mm": 4.0, "kg_m": 0.011,
		"break_kn": 16.0, "color": Color(0.95, 0.85, 0.2)},
	"paracord": {"label": "550 paracord", "d_mm": 4.0, "kg_m": 0.008, "break_kn": 2.4,
		"color": Color(0.2, 0.25, 0.3)},
}
const CABLE_ORDER := ["cable_18", "cable_316", "dyneema_4", "paracord"]

const SHEETS := {
	"correx_10": {"label": "Correx (corrugated PP) 10 mm, 4' × 8'", "t_mm": 10.0, "kg_m2": 1.5,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "color": Color(0.93, 0.94, 0.95)},
	"correx_6": {"label": "Correx (corrugated PP) 6 mm, 4' × 8'", "t_mm": 6.0, "kg_m2": 1.0,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "color": Color(0.93, 0.94, 0.95)},
	"correx_4": {"label": "Correx (corrugated PP) 4 mm, 4' × 8'", "t_mm": 4.0, "kg_m2": 0.7,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "color": Color(0.93, 0.94, 0.95)},
	"correx_10_5x10": {"label": "Correx 10 mm, 5' × 10'", "t_mm": 10.0, "kg_m2": 1.5,
		"sheet_w": 1524.0, "sheet_h": 3048.0, "color": Color(0.93, 0.94, 0.95)},
	"hdpe_3": {"label": "HDPE sheet 3 mm, 4' × 8'", "t_mm": 3.0, "kg_m2": 2.85,
		"sheet_w": 1220.0, "sheet_h": 2440.0, "color": Color(0.25, 0.5, 0.75)},
}
const SHEET_ORDER := ["correx_10", "correx_6", "correx_4", "correx_10_5x10", "hdpe_3"]

## Panels: long_mm runs along the meridian (over the crown), short_mm round
## the ring. Electrical numbers from typical 12 V module data sheets; the
## 100 W flexible size is measured off the reference model.
const PANELS := {
	"flex_100": {"label": "100 W flexible mono (1180 × 470 mm)", "long_mm": 1180.0, "short_mm": 470.0,
		"watts": 100.0, "voc": 22.6, "vmp": 18.6, "isc": 5.8, "imp": 5.38, "kg": 2.0, "flexible": true,
		"max_arc_deg": 40.0},
	"flex_50": {"label": "50 W flexible mono (630 × 540 mm)", "long_mm": 630.0, "short_mm": 540.0,
		"watts": 50.0, "voc": 21.6, "vmp": 18.0, "isc": 3.0, "imp": 2.78, "kg": 1.0, "flexible": true,
		"max_arc_deg": 40.0},
	"flex_200": {"label": "200 W flexible mono (1580 × 680 mm)", "long_mm": 1580.0, "short_mm": 680.0,
		"watts": 200.0, "voc": 23.2, "vmp": 19.2, "isc": 11.2, "imp": 10.4, "kg": 3.9, "flexible": true,
		"max_arc_deg": 40.0},
	"rigid_100": {"label": "100 W rigid mono (1010 × 670 mm)", "long_mm": 1010.0, "short_mm": 670.0,
		"watts": 100.0, "voc": 22.5, "vmp": 18.8, "isc": 5.7, "imp": 5.32, "kg": 6.5, "flexible": false,
		"max_arc_deg": 0.0},
}
const PANEL_ORDER := ["flex_100", "flex_50", "flex_200", "rigid_100"]

const CORREX_BOLT_DEFAULT := "m6"


static func tube(id: String) -> Dictionary:
	return TUBES.get(id, TUBES["steel_1_065"])


static func cable(id: String) -> Dictionary:
	return CABLES.get(id, CABLES["cable_18"])


static func sheet(id: String) -> Dictionary:
	return SHEETS.get(id, SHEETS["correx_10"])


static func panel(id: String) -> Dictionary:
	return PANELS.get(id, PANELS["flex_100"])


static func connector(kind: String) -> Dictionary:
	return CONNECTORS.get(kind, CONNECTORS["tee"])


## A connector's mass scaled with the tube's OD (the table is for 1").
static func connector_kg(kind: String, od_mm: float) -> float:
	return float(connector(kind)["kg"]) * pow(od_mm / 25.4, 1.6)
