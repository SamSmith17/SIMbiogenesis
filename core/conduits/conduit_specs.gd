class_name ConduitSpecs
extends RefCounted

## What a conduit run really is: its size choices, outside and inside
## diameters, weight, cost, rating, minimum bend radius and the angles its
## fittings come in. Pure static. ConduitKinds holds the look of a kind; this
## file holds the product data behind it, so the router, the style modal, the
## loss maths and the Process lens all read one table.
##
## A kind with a size table picks its row by the style key it lists
## (`pipe_size_in` for pipe and conduit trade sizes, `size_in` for tube and hose,
## `awg` for cable). The first-listed default row reproduces the numbers the
## kind carried before this table existed, so a run nobody re-sized loses
## nothing in the simulation. Poly penstock and culvert keep their own size
## rules in ConduitKinds / CulvertKit and are delegated to.
##
## Costs are 2026 US retail estimates per metre and are labelled so in the UI.

const IN_M := 0.0254
const LB_FT_TO_KG_M := 1.48816

## Bend rules. "mult_od": minimum radius = mult × OD. "table": radius in mm by
## size. "kit": the fitting kit's own elbows decide (PVC / ABS Sch40).
## "contour" / "culvert": delegated to ConduitKinds / CulvertKit.
const BEND_RULES: Dictionary = {
	# Flexible cord: manufacturers give 6 × OD as the minimum training radius
	# for SJ-type portable cord (e.g. Southwire / General Cable data sheets).
	"extension_cord": {"mult_od": 6.0, "src": "cord makers, 6 × OD"},
	# NEC 334.24: NM cable bends no tighter than 5 × the cable's diameter.
	"romex": {"mult_od": 5.0, "src": "NEC 334.24"},
	# PV wire (UL 4703) single conductor: 5 × OD training radius (makers).
	"dc_solar": {"mult_od": 5.0, "src": "PV wire makers, 5 × OD"},
	# Fine-strand battery / welding cable: about 6 × OD (makers' training radius).
	"battery_cable_pos": {"mult_od": 6.0, "src": "welding cable makers, 6 × OD"},
	"battery_cable_neg": {"mult_od": 6.0, "src": "welding cable makers, 6 × OD"},
	# ANSI/TIA-568: installed UTP 4 × the cable OD.
	"ethernet": {"mult_od": 4.0, "src": "ANSI/TIA-568"},
	# Garden hose kinks below about 6 × OD.
	"garden_hose": {"mult_od": 6.0, "src": "hose makers, 6 × OD"},
	# ASTM F876 PEX: cold bend 6 × OD (makers' minimum without a bend support).
	"pex_red": {"mult_od": 6.0, "src": "PEX makers, 6 × OD"},
	"pex_blue": {"mult_od": 6.0, "src": "PEX makers, 6 × OD"},
	"pex_white": {"mult_od": 6.0, "src": "PEX makers, 6 × OD"},
	# Rigid copper joins with wrought short-radius elbows: about 1 × OD on the
	# centreline (ASME B16.22).
	"copper_type_l": {"mult_od": 1.0, "src": "ASME B16.22 elbows"},
	# NEC Chapter 9 Table 2, one-shot and full-shoe benders (mm by trade size).
	"emt_conduit": {"table": {0.5: 101.6, 0.75: 114.3, 1.0: 146.1, 1.25: 184.2,
		1.5: 209.6, 2.0: 241.3}, "src": "NEC Ch. 9 Table 2"},
	# SMACNA: a standard round duct elbow has a centreline radius of 1.5 × D.
	"ducting": {"mult_od": 1.5, "src": "SMACNA, R/D 1.5"},
	"pvc_pipe": {"kit": true, "src": "Sch40 fitting kit"},
	"pvc_4in": {"kit": true, "src": "Sch40 fitting kit"},
	"pvc_6in": {"kit": true, "src": "Sch40 fitting kit"},
	"abs_dwv": {"kit": true, "src": "Sch40 fitting kit"},
	"poly_penstock": {"contour": true, "src": "PPI Handbook ch. 7"},
	"culvert_pipe": {"culvert": true, "src": "dual-wall PE sweeps"},
	"led_strip": {"mult_od": 8.0, "src": "flex strip"},
	"led_fairy": {"mult_od": 6.0, "src": "wire string"},
	"led_patio": {"mult_od": 6.0, "src": "SPT cord"},
	"conceptual_flow": {"mult_od": 6.0, "src": "diagram"},
}

## The angles a run's fittings or benders make. A rigid router never turns
## through anything else. 22.5 for EMT is a field bend; kit pipes stay at the
## 45 / 90 elbows the GLB kit has.
const ALLOWED_ANGLES: Dictionary = {
	"emt_conduit": [90.0, 45.0, 30.0, 22.5],
	"copper_type_l": [90.0, 45.0],
	"pvc_pipe": [90.0, 45.0],
	"pvc_4in": [90.0, 45.0],
	"pvc_6in": [90.0, 45.0],
	"abs_dwv": [90.0, 45.0],
	"ducting": [90.0, 45.0],
	"romex": [90.0],
	"ethernet": [90.0, 45.0],
	"conceptual_flow": [90.0, 45.0],
}

## How far apart supports go (m). NEC 358.30: EMT within 3 m. NEC 334.30: NM
## every 1.4 m. PVC pressure pipe: about 1.2 m at 1¼" (makers' hanger tables).
## Copper ¾": 1.8 m (MSS SP-58). PEX ½": 0.8 m (makers).
const SUPPORT_SPACING_M: Dictionary = {
	"emt_conduit": 3.0, "romex": 1.4, "pvc_pipe": 1.2, "pvc_4in": 1.5,
	"pvc_6in": 1.8, "abs_dwv": 1.2, "copper_type_l": 1.8, "pex_red": 0.8,
	"pex_blue": 0.8, "pex_white": 0.8, "ethernet": 1.5, "ducting": 2.4,
	"dc_solar": 1.0, "battery_cable_pos": 1.0, "battery_cable_neg": 1.0,
}

## How a kind is laid. The run solver and the mesh read this one word.
## rigid_ortho: straight legs, bends at the kind's radius (pipe, conduit, NM).
## flex_drape:  lies on the ground with slack (cord, hose).
## flex_route:  routes like rigid but bends wide and may sag (PEX, Cat6, PV).
## hang:        strung overhead between points (patio lights).
## contour / culvert: terrain-following hydraulic runs, own routers.
const ROUTING_STYLE: Dictionary = {
	"extension_cord": "flex_drape", "garden_hose": "flex_drape",
	"led_fairy": "flex_drape", "led_patio": "hang", "led_strip": "flex_route",
	"pex_red": "flex_route", "pex_blue": "flex_route", "pex_white": "flex_route",
	"ethernet": "flex_route", "dc_solar": "flex_route",
	"battery_cable_pos": "flex_route", "battery_cable_neg": "flex_route",
	"romex": "rigid_ortho", "emt_conduit": "rigid_ortho",
	"copper_type_l": "rigid_ortho", "pvc_pipe": "rigid_ortho",
	"pvc_4in": "rigid_ortho", "pvc_6in": "rigid_ortho", "abs_dwv": "rigid_ortho",
	"ducting": "rigid_ortho", "conceptual_flow": "rigid_ortho",
	"poly_penstock": "contour", "culvert_pipe": "culvert",
}

const _CORD_ROWS := [
	{"awg": 16, "label": "16/3 SJTW", "od_mm": 8.4, "kg_m": 0.10, "usd_m": 0.9,
		"ampacity_a": 13.0, "ohm_m": 0.0264},
	{"awg": 14, "label": "14/3 SJTW", "od_mm": 9.6, "kg_m": 0.14, "usd_m": 1.3,
		"ampacity_a": 15.0, "ohm_m": 0.0166},
	{"awg": 12, "label": "12/3 SJTW", "od_mm": 10.9, "kg_m": 0.19, "usd_m": 1.9,
		"ampacity_a": 20.0, "ohm_m": 0.0104},
	{"awg": 10, "label": "10/3 SJTW", "od_mm": 12.7, "kg_m": 0.27, "usd_m": 3.0,
		"ampacity_a": 30.0, "ohm_m": 0.0066},
]

const _NM_ROWS := [
	{"awg": 12, "label": "12/2 NM-B", "od_mm": 9.6, "kg_m": 0.10, "usd_m": 0.85,
		"ampacity_a": 20.0, "ohm_m": 0.0104},
	{"awg": 14, "label": "14/2 NM-B", "od_mm": 8.0, "kg_m": 0.07, "usd_m": 0.55,
		"ampacity_a": 15.0, "ohm_m": 0.0166},
	{"awg": 10, "label": "10/2 NM-B", "od_mm": 11.4, "kg_m": 0.15, "usd_m": 1.45,
		"ampacity_a": 30.0, "ohm_m": 0.0066},
]

const _PV_ROWS := [
	{"awg": 10, "label": "10 AWG PV wire", "od_mm": 6.0, "kg_m": 0.06, "usd_m": 0.8,
		"ampacity_a": 30.0, "ohm_m": 0.0066},
	{"awg": 12, "label": "12 AWG PV wire", "od_mm": 5.3, "kg_m": 0.04, "usd_m": 0.6,
		"ampacity_a": 20.0, "ohm_m": 0.0104},
	{"awg": 8, "label": "8 AWG PV wire", "od_mm": 7.4, "kg_m": 0.09, "usd_m": 1.3,
		"ampacity_a": 40.0, "ohm_m": 0.0041},
	{"awg": 6, "label": "6 AWG PV wire", "od_mm": 8.6, "kg_m": 0.13, "usd_m": 2.0,
		"ampacity_a": 55.0, "ohm_m": 0.0026},
]

## ASTM D1785 Sch40 PVC: OD, ID (in), pressure (psi at 73 °F), lb/ft.
const _SCH40 := {
	0.5: [0.840, 0.622, 600, 0.16], 0.75: [1.050, 0.824, 480, 0.21],
	1.0: [1.315, 1.049, 450, 0.32], 1.25: [1.660, 1.380, 370, 0.43],
	1.5: [1.900, 1.610, 330, 0.51], 2.0: [2.375, 2.067, 280, 0.68],
	2.5: [2.875, 2.469, 300, 1.08], 3.0: [3.500, 3.068, 260, 1.41],
	4.0: [4.500, 4.026, 220, 2.01], 5.0: [5.563, 5.047, 190, 2.73],
	6.0: [6.625, 6.065, 180, 3.53], 8.0: [8.625, 7.981, 160, 5.31],
}
const _SCH40_USD_M := {0.5: 1.5, 0.75: 2.0, 1.0: 2.8, 1.25: 3.6, 1.5: 4.3,
	2.0: 5.6, 2.5: 9.0, 3.0: 11.0, 4.0: 15.0, 5.0: 24.0, 6.0: 30.0, 8.0: 50.0}

## ANSI C80.3 EMT: OD, ID (in), lb/ft.
const _EMT := {0.5: [0.706, 0.622, 0.29], 0.75: [0.922, 0.824, 0.45],
	1.0: [1.163, 1.049, 0.65], 1.25: [1.510, 1.380, 0.96],
	1.5: [1.740, 1.610, 1.11], 2.0: [2.197, 2.067, 1.41]}
const _EMT_USD_M := {0.5: 2.0, 0.75: 3.0, 1.0: 4.8, 1.25: 8.0, 1.5: 9.5, 2.0: 12.0}

## THHN conductors pulled in EMT, per circuit (two conductors + ground).
## Ampacity: NEC 310.16 75 °C column, limited by 240.4(D) for 14–10 AWG.
const _THHN_ROWS := [
	{"awg": 12, "label": "12 AWG THHN", "ampacity_a": 20.0, "ohm_m": 0.0104,
		"kg_m": 0.08, "usd_m": 1.2},
	{"awg": 14, "label": "14 AWG THHN", "ampacity_a": 15.0, "ohm_m": 0.0166,
		"kg_m": 0.05, "usd_m": 0.8},
	{"awg": 10, "label": "10 AWG THHN", "ampacity_a": 30.0, "ohm_m": 0.0066,
		"kg_m": 0.12, "usd_m": 1.9},
	{"awg": 8, "label": "8 AWG THHN", "ampacity_a": 50.0, "ohm_m": 0.0041,
		"kg_m": 0.19, "usd_m": 3.0},
	{"awg": 6, "label": "6 AWG THHN", "ampacity_a": 65.0, "ohm_m": 0.0026,
		"kg_m": 0.29, "usd_m": 4.6},
]


## The size table for a kind: {key, rows: [{value, label, od_m, id_m, kg_m,
## usd_m, pressure_psi (-1 = not pressure rated), ampacity_a, ohm_m,
## max_flow_lpm}]}, default row first. Empty for kinds with no table.
static func table(type_id: String) -> Dictionary:
	match type_id:
		"extension_cord":
			return _cable_table(_CORD_ROWS)
		"romex":
			return _cable_table(_NM_ROWS)
		"dc_solar":
			return _cable_table(_PV_ROWS)
		"ethernet":
			# Cat6 UTP, 23 AWG; 802.3bt Type 4 PoE: 960 mA per pair.
			return {"key": "", "rows": [{"value": 0.0, "label": "Cat6 UTP",
				"od_m": 0.0061, "id_m": 0.0, "kg_m": 0.04, "usd_m": 0.35,
				"pressure_psi": -1.0, "ampacity_a": 0.96, "ohm_m": 0.168}]}
		"garden_hose":
			return {"key": "size_in", "rows": [
				_tube_row(0.625, "5/8\" hose", 22.0, 16.0, 0.25, 1.0, 125.0, 40.0),
				_tube_row(0.5, "1/2\" hose", 19.0, 12.7, 0.20, 0.8, 125.0, 25.0),
				_tube_row(0.75, "3/4\" hose", 25.4, 19.1, 0.32, 1.5, 125.0, 57.0),
			]}
		"pex_red", "pex_blue", "pex_white":
			# ASTM F876 SDR9; 160 psi at 73 °F (ASTM F876 / PPI TR-3).
			return {"key": "size_in", "rows": [
				_tube_row(0.5, "1/2\" PEX", 15.9, 12.1, 0.05, 0.5, 160.0, 30.0),
				_tube_row(0.75, "3/4\" PEX", 22.2, 17.0, 0.09, 0.8, 160.0, 59.0),
				_tube_row(1.0, "1\" PEX", 28.6, 22.2, 0.14, 1.3, 160.0, 100.0),
			]}
		"copper_type_l":
			# ASTM B88 Type L. Working pressures are annealed-temper estimates
			# (soldered joints limit a system below the tube's own rating).
			return {"key": "size_in", "rows": [
				_tube_row(0.75, "3/4\" Type L", 22.2, 19.9, 0.68, 14.0, 600.0, 59.0),
				_tube_row(0.5, "1/2\" Type L", 15.9, 13.8, 0.42, 9.0, 650.0, 30.0),
				_tube_row(1.0, "1\" Type L", 28.6, 26.0, 0.97, 21.0, 500.0, 100.0),
			]}
		"pvc_pipe":
			return _sch40_table(1.25, true)
		"pvc_4in":
			return _sch40_table(4.0, true)
		"pvc_6in":
			return _sch40_table(6.0, true)
		"abs_dwv":
			return _abs_table()
		"emt_conduit":
			return _emt_table()
		"ducting":
			# Round duct: thin wall, rated in CFM at 800 fpm (ASHRAE velocity
			# guide for branch ducts). max_flow_lpm keeps the flow-overload test.
			return {"key": "size_in", "rows": [
				_duct_row(6.0, 152.4), _duct_row(4.0, 101.6), _duct_row(8.0, 203.2),
			]}
	return {}


## True when a kind has more than one size to pick.
static func has_sizes(type_id: String) -> bool:
	return (table(type_id).get("rows", []) as Array).size() > 1


## The style key the kind's size is stored under ("" = single size).
static func size_key(type_id: String) -> String:
	return str(table(type_id).get("key", ""))


## The table row a style selects: the row whose value is nearest the style's,
## else the default (first) row. {} for kinds with no table.
static func row(type_id: String, style: Dictionary = {}) -> Dictionary:
	var t := table(type_id)
	var rows: Array = t.get("rows", []) as Array
	if rows.is_empty():
		return {}
	var key := str(t.get("key", ""))
	if key.is_empty() or not style.has(key):
		# Kit kinds already store their size as pipe_size_in through the kind's
		# default_pipe_size_in, which equals the default row.
		return rows[0] as Dictionary
	var want := float(style.get(key, 0.0))
	var best: Dictionary = rows[0]
	for r: Variant in rows:
		var rd: Dictionary = r
		if absf(float(rd["value"]) - want) < absf(float(best["value"]) - want):
			best = rd
	return best


## Outside diameter (m). The table first, then the kind's own rules.
static func od_m(type_id: String, style: Dictionary = {}) -> float:
	var r := row(type_id, style)
	if not r.is_empty():
		return float(r["od_m"])
	return ConduitKinds.outer_diameter_m(type_id, style)


## Bore (m) for fluid kinds; 0 for cable.
static func id_m(type_id: String, style: Dictionary = {}) -> float:
	var r := row(type_id, style)
	if not r.is_empty():
		return float(r["id_m"])
	return ConduitKinds.inner_diameter_for(type_id, style)


## Minimum bend radius (m) on the centreline. A style's own bend_radius_m wins
## when it is not tighter than the rule allows.
static func bend_radius_m(type_id: String, style: Dictionary = {}) -> float:
	var rule: Dictionary = BEND_RULES.get(type_id, {"mult_od": 6.0}) as Dictionary
	var r := 0.0
	if rule.has("contour"):
		r = ConduitKinds.contour_bend_radius_m(type_id, style)
	elif rule.has("culvert"):
		r = CulvertKit.bend_radius_for_type(type_id, style)
	elif rule.has("kit"):
		# Sch40 short-radius elbows: centreline radius about 1 × OD.
		r = od_m(type_id, style)
	elif rule.has("table"):
		var tbl: Dictionary = rule["table"]
		var sz := float(style.get("pipe_size_in", float(row(type_id, style).get("value", 0.75))))
		var best := -1.0
		for k: Variant in tbl.keys():
			if best < 0.0 or absf(float(k) - sz) < absf(best - sz):
				best = float(k)
		r = float(tbl.get(best, 120.0)) / 1000.0
	else:
		r = float(rule.get("mult_od", 6.0)) * od_m(type_id, style)
	var own := float(style.get("bend_radius_m", 0.0))
	if own > r:
		return own
	return r


static func bend_source(type_id: String) -> String:
	return str((BEND_RULES.get(type_id, {}) as Dictionary).get("src", "estimate"))


## Angles the run may turn through, largest first.
static func allowed_angles(type_id: String) -> Array:
	if ALLOWED_ANGLES.has(type_id):
		return (ALLOWED_ANGLES[type_id] as Array).duplicate()
	var rs := routing_style(type_id)
	if rs == "rigid_ortho":
		return [90.0, 45.0]
	return []  # flexible: any angle


static func routing_style(type_id: String) -> String:
	if ROUTING_STYLE.has(type_id):
		return str(ROUTING_STYLE[type_id])
	if ConduitKinds.uses_culvert_kit(type_id):
		return "culvert"
	if ConduitKinds.is_flexible_type(type_id):
		return "flex_drape" if ConduitKinds.is_ground_drape_type(type_id) else "flex_route"
	return "rigid_ortho"


static func support_spacing_m(type_id: String) -> float:
	return float(SUPPORT_SPACING_M.get(type_id, 0.0))


## The kind's meta with the chosen size's electrical / hydraulic numbers laid
## over it — what ConduitLoss should read. Kinds with no table come back as
## their plain meta, so the default size changes nothing.
static func loss_meta(type_id: String, style: Dictionary = {}) -> Dictionary:
	var meta: Dictionary = ConduitKinds.type_meta(type_id)
	var r := row(type_id, style)
	if type_id == "emt_conduit":
		# The circuit inside the conduit carries the current.
		var c := conductor_row(style)
		meta["resistance_ohm_per_m"] = float(c["ohm_m"])
		meta["ampacity_a"] = float(c["ampacity_a"])
		return meta
	if r.is_empty():
		if not (meta.get("pipe_size_options_in", []) as Array).is_empty():
			meta["inner_diameter_m"] = ConduitKinds.inner_diameter_for(type_id, style)
		return meta
	if meta.has("resistance_ohm_per_m") and float(r.get("ohm_m", 0.0)) > 0.0:
		meta["resistance_ohm_per_m"] = float(r["ohm_m"])
	if meta.has("ampacity_a") and float(r.get("ampacity_a", 0.0)) > 0.0:
		meta["ampacity_a"] = float(r["ampacity_a"])
	if meta.has("inner_diameter_m") and float(r.get("id_m", 0.0)) > 0.0:
		meta["inner_diameter_m"] = float(r["id_m"])
	if float(r.get("max_flow_lpm", 0.0)) > 0.0:
		meta["max_flow_lpm"] = float(r["max_flow_lpm"])
	var psi := float(r.get("pressure_psi", -1.0))
	if psi > 0.0:
		meta["burst_pressure_psi"] = psi
	else:
		meta.erase("burst_pressure_psi")
	return meta


## Everything the style modal and the Process lens show about one run.
static func for_run(conn: Dictionary, length_m: float = -1.0) -> Dictionary:
	var type_id := ConduitKinds.derive_type_for_connection(conn)
	var style: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var len_m := length_m
	if len_m < 0.0:
		len_m = maxf(float(conn.get("route_length_m", 0.0)),
			float(conn.get("estimated_length", 0.0)))
	var r := row(type_id, style)
	var out := {
		"type_id": type_id,
		"label": str(r.get("label", ConduitKinds.display_name_with_size(type_id, style))),
		"od_m": od_m(type_id, style),
		"id_m": id_m(type_id, style),
		"bend_radius_m": bend_radius_m(type_id, style),
		"bend_source": bend_source(type_id),
		"angles": allowed_angles(type_id),
		"routing_style": routing_style(type_id),
		"length_m": len_m,
		"pressure_psi": float(r.get("pressure_psi", -1.0)),
		"ampacity_a": float(r.get("ampacity_a", 0.0)),
		"kg": float(r.get("kg_m", 0.0)) * len_m,
		"usd": float(r.get("usd_m", 0.0)) * len_m,
		"supports": 0,
	}
	if type_id == "emt_conduit":
		var c := conductor_row(style)
		out["ampacity_a"] = float(c["ampacity_a"])
		out["conductors"] = str(c["label"])
		out["kg"] = (float(r.get("kg_m", 0.0)) + float(c["kg_m"])) * len_m
		out["usd"] = (float(r.get("usd_m", 0.0)) + float(c["usd_m"])) * len_m
	if r.is_empty():
		var meta := ConduitKinds.type_meta(type_id)
		if type_id == "poly_penstock":
			out["pressure_psi"] = ConduitKinds.pressure_rating_psi(type_id, style)
		out["ampacity_a"] = float(meta.get("ampacity_a", 0.0))
	var sp := support_spacing_m(type_id)
	if sp > 0.0 and len_m > 0.0:
		out["supports"] = int(ceil(len_m / sp)) + 1
	return out


static func _cable_table(rows: Array) -> Dictionary:
	var out: Array = []
	for r: Variant in rows:
		var rd: Dictionary = r
		out.append({"value": float(rd["awg"]), "label": str(rd["label"]),
			"od_m": float(rd.get("od_mm", 0.0)) / 1000.0, "id_m": 0.0,
			"kg_m": float(rd["kg_m"]), "usd_m": float(rd["usd_m"]),
			"pressure_psi": -1.0, "ampacity_a": float(rd["ampacity_a"]),
			"ohm_m": float(rd["ohm_m"])})
	return {"key": "awg", "rows": out}


static func _tube_row(size_in: float, label: String, od_mm: float, id_mm: float,
		kg_m: float, usd_m: float, psi: float, max_lpm: float) -> Dictionary:
	return {"value": size_in, "label": label, "od_m": od_mm / 1000.0,
		"id_m": id_mm / 1000.0, "kg_m": kg_m, "usd_m": usd_m,
		"pressure_psi": psi, "ampacity_a": 0.0, "ohm_m": 0.0, "max_flow_lpm": max_lpm}


static func _sch40_row(sz: float, pressure: bool) -> Dictionary:
	var d: Array = _SCH40[sz]
	var id := float(d[1]) * IN_M
	# A 2.4 m/s design velocity caps the flow (common pressure-pipe practice).
	var max_lpm := PI * 0.25 * id * id * 2.4 * 60000.0
	return {"value": sz, "label": "%s\" Sch40" % _frac(sz),
		"od_m": float(d[0]) * IN_M, "id_m": id,
		"kg_m": float(d[3]) * LB_FT_TO_KG_M, "usd_m": float(_SCH40_USD_M[sz]),
		"pressure_psi": float(d[2]) if pressure else -1.0,
		"ampacity_a": 0.0, "ohm_m": 0.0, "max_flow_lpm": max_lpm}


static func _sch40_table(default_sz: float, pressure: bool) -> Dictionary:
	var rows: Array = [_sch40_row(default_sz, pressure)]
	for sz: Variant in _SCH40.keys():
		if not is_equal_approx(float(sz), default_sz):
			rows.append(_sch40_row(float(sz), pressure))
	return {"key": "pipe_size_in", "rows": rows}


## ABS DWV (ASTM D2661): Sch40 dimensions, sold in 1½–4", not pressure rated.
## About 75 % of the PVC weight.
static func _abs_table() -> Dictionary:
	var rows: Array = []
	for sz: float in [2.0, 1.5, 3.0, 4.0]:
		var r := _sch40_row(sz, false)
		r["label"] = "%s\" ABS DWV" % _frac(sz)
		r["kg_m"] = float(r["kg_m"]) * 0.75
		rows.append(r)
	return {"key": "pipe_size_in", "rows": rows}


static func _emt_table() -> Dictionary:
	var rows: Array = []
	for sz: float in [0.75, 0.5, 1.0, 1.25, 1.5, 2.0]:
		var d: Array = _EMT[sz]
		rows.append({"value": sz, "label": "%s\" EMT" % _frac(sz),
			"od_m": float(d[0]) * IN_M, "id_m": float(d[1]) * IN_M,
			"kg_m": float(d[2]) * LB_FT_TO_KG_M, "usd_m": float(_EMT_USD_M[sz]),
			"pressure_psi": -1.0, "ampacity_a": 0.0, "ohm_m": 0.0})
	return {"key": "pipe_size_in", "rows": rows}


## Conductors inside EMT (style key awg). The conduit's own size is the
## table above; these give the circuit's ampacity and resistance.
static func conductor_rows() -> Array:
	return (_cable_table(_THHN_ROWS).get("rows", []) as Array)


static func conductor_row(style: Dictionary) -> Dictionary:
	var rows := conductor_rows()
	var want := float(style.get("awg", 12.0))
	var best: Dictionary = rows[0]
	for r: Variant in rows:
		if absf(float((r as Dictionary)["value"]) - want) < absf(float(best["value"]) - want):
			best = r
	return best


static func _duct_row(size_in: float, d_mm: float) -> Dictionary:
	var area_ft2 := PI * 0.25 * pow(size_in / 12.0, 2.0)
	var cfm := area_ft2 * 800.0
	return {"value": size_in, "label": "%d\" round duct" % int(size_in),
		"od_m": (d_mm + 1.6) / 1000.0, "id_m": d_mm / 1000.0,
		"kg_m": 0.9 * size_in / 6.0, "usd_m": 5.0 * size_in / 6.0,
		"pressure_psi": -1.0, "ampacity_a": 0.0, "ohm_m": 0.0,
		"cfm": cfm, "max_flow_lpm": cfm * 28.3168}


## 1.25 -> "1-1/4", 0.5 -> "1/2", 2 -> "2".
static func _frac(sz: float) -> String:
	var whole := int(floor(sz + 1e-6))
	var part := sz - float(whole)
	var tail := ""
	if absf(part - 0.25) < 0.01:
		tail = "1/4"
	elif absf(part - 0.5) < 0.01:
		tail = "1/2"
	elif absf(part - 0.75) < 0.01:
		tail = "3/4"
	if whole == 0:
		return tail
	if tail.is_empty():
		return str(whole)
	return "%d-%s" % [whole, tail]
