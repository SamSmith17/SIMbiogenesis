class_name BattChem
extends RefCounted

## The six battery chemistries the Battery Lab designs with, as one table.
##
## `BatteryChemistry` (system_graph/) is the graph's three-class view (LFP,
## Li-ion, lead) and keeps its numbers: the canvas, the DC electrical checks and
## their selftests read it. This table is finer: flooded, sealed, AGM and gel
## lead-acid behave differently enough (charge voltages, Peukert, gassing,
## cycle life) that a designer must tell them apart. `graph_class` maps each id
## back onto BatteryChemistry.
##
## All voltages are PER CELL at 25 °C. Packs multiply by the series count.
##
## Sources (each row's `est` lists the fields that are estimates):
##  - LFP: EVE LF280K data sheet (3.2 V nominal, 2.5–3.65 V, charge 0–55 °C,
##    discharge −20–60 °C, ≥ 6000 cycles at 0.5C/80 % DoD/25 °C); Victron
##    "Lithium battery smart" manual (absorb 14.2 V, float 13.5 V on 4S).
##  - NMC: Samsung INR21700-50E and INR18650-30Q data sheets (3.6 V nominal,
##    4.2 V charge, 2.5 V cut-off, charge 0–45 °C, discharge −20–60 °C).
##  - Flooded: Trojan "Battery Maintenance Guide" (absorb 2.45–2.47 V/cell,
##    float 2.20, equalize 2.58, −5 mV/°C/cell compensation, 10.5 V cut-off on
##    12 V), Trojan T-105 data sheet cycle chart.
##  - AGM: Lifeline Technical Manual (absorb 2.37–2.40, float 2.22–2.27,
##    −4 mV/°C/cell).
##  - Gel: Victron gel data sheet (absorb 14.1 V, float 13.8 V on 12 V).
##  - Sealed lead (small VRLA): Yuasa NP data sheet (cycle 2.40–2.50 V/cell,
##    standby 2.275, cycle life 200 at 100 % DoD, 550 at 50 %, 1200 at 30 %).
##  - Peukert: Victron BMV manual defaults (1.25 lead, 1.05 lithium); AGM / gel
##    values are typical maker figures (estimate).
##  - Resting OCV curves: Battery University BU-903 (lead) and common LFP / NMC
##    rest-voltage charts (estimate: real curves move with temperature, age and
##    the cell).
##  - Gassing / ventilation: IEC 62485-2 (Q = 0.05 · n · Igas · C · 10⁻³ m³/h;
##    Igas on float 5 mA/Ah vented, 1 mA/Ah VRLA; on boost 20 / 8). Faraday:
##    1 Ah splits 0.418 L of hydrogen at STP per cell.

const FLA := "FLA"
const SLA := "SLA"
const AGM := "AGM"
const GEL := "GEL"
const LFP := "LFP"
const NMC := "NMC"

const IDS: Array = [FLA, SLA, AGM, GEL, LFP, NMC]

## Litres of H2 at STP per amp-hour of overcharge, per cell (Faraday:
## 3600 C / 96485 C/mol = 0.0373 mol e⁻ → 0.01866 mol H2 × 22.41 L/mol).
const H2_L_PER_AH_CELL := 0.418

## IEC 62485-2 gas current (mA per Ah of rated capacity).
const IGAS_MA_PER_AH := {
	"vented": {"float": 5.0, "boost": 20.0},
	"vrla": {"float": 1.0, "boost": 8.0},
}

## SOC points of every `ocv` table (0 %, 10 % … 100 %).
const OCV_STEP := 0.1

const TABLE := {
	FLA: {
		"label": "Flooded", "long": "Flooded lead-acid (FLA)",
		"family": "lead", "vented": true, "maintenance": "Top up with distilled water",
		"cell_nominal_v": 2.0, "cell_max_v": 2.47, "cell_absorb_v": 2.47,
		"cell_float_v": 2.20, "cell_equalize_v": 2.58, "cell_min_v": 1.75,
		"cell_storage_v": 2.20,
		"temp_comp_mv_c": -5.0,
		"charge_temp_c": [-20.0, 50.0], "discharge_temp_c": [-20.0, 50.0],
		"coulombic_eff": 0.88, "round_trip_eff": 0.80,
		"peukert": 1.25, "self_discharge_pct_month": 5.0,
		"recommended_dod": 0.5, "max_charge_c": 0.2,
		"cycles": [[0.2, 3000], [0.5, 1200], [0.8, 750], [1.0, 500]],
		"wh_per_kg": [25.0, 50.0], "wh_per_l": [60.0, 115.0],
		"stages": ["bulk", "absorb", "float", "equalize"],
		"runaway": "none",
		"ocv": [1.915, 1.932, 1.957, 1.977, 1.997, 2.017, 2.040, 2.060, 2.077, 2.097, 2.117],
		"est": ["coulombic_eff", "round_trip_eff", "ocv", "charge_temp_c"],
	},
	SLA: {
		"label": "SLA", "long": "Sealed lead-acid (small VRLA)",
		"family": "lead", "vented": false, "maintenance": "None (sealed)",
		"cell_nominal_v": 2.0, "cell_max_v": 2.45, "cell_absorb_v": 2.45,
		"cell_float_v": 2.275, "cell_equalize_v": 0.0, "cell_min_v": 1.75,
		"cell_storage_v": 2.25,
		"temp_comp_mv_c": -3.3,
		"charge_temp_c": [-15.0, 50.0], "discharge_temp_c": [-15.0, 50.0],
		"coulombic_eff": 0.90, "round_trip_eff": 0.82,
		"peukert": 1.15, "self_discharge_pct_month": 3.0,
		"recommended_dod": 0.5, "max_charge_c": 0.25,
		"cycles": [[0.3, 1200], [0.5, 550], [1.0, 200]],
		"wh_per_kg": [25.0, 50.0], "wh_per_l": [60.0, 115.0],
		"stages": ["bulk", "absorb", "float"],
		"runaway": "none",
		"ocv": [1.950, 1.967, 1.985, 2.002, 2.020, 2.037, 2.055, 2.072, 2.090, 2.107, 2.133],
		"est": ["coulombic_eff", "round_trip_eff", "ocv", "peukert"],
	},
	AGM: {
		"label": "AGM", "long": "Absorbed glass mat lead-acid (AGM)",
		"family": "lead", "vented": false, "maintenance": "None (sealed)",
		"cell_nominal_v": 2.0, "cell_max_v": 2.40, "cell_absorb_v": 2.40,
		"cell_float_v": 2.25, "cell_equalize_v": 0.0, "cell_min_v": 1.75,
		"cell_storage_v": 2.25,
		"temp_comp_mv_c": -4.0,
		"charge_temp_c": [-20.0, 50.0], "discharge_temp_c": [-30.0, 50.0],
		"coulombic_eff": 0.92, "round_trip_eff": 0.85,
		"peukert": 1.12, "self_discharge_pct_month": 2.0,
		"recommended_dod": 0.5, "max_charge_c": 0.3,
		"cycles": [[0.3, 1500], [0.5, 800], [0.8, 450], [1.0, 300]],
		"wh_per_kg": [25.0, 50.0], "wh_per_l": [60.0, 115.0],
		"stages": ["bulk", "absorb", "float"],
		"runaway": "none",
		"ocv": [1.967, 1.990, 2.008, 2.027, 2.045, 2.063, 2.080, 2.097, 2.113, 2.128, 2.142],
		"est": ["coulombic_eff", "round_trip_eff", "ocv", "peukert", "cycles"],
	},
	GEL: {
		"label": "Gel", "long": "Gel lead-acid",
		"family": "lead", "vented": false, "maintenance": "None (sealed)",
		"cell_nominal_v": 2.0, "cell_max_v": 2.35, "cell_absorb_v": 2.35,
		"cell_float_v": 2.30, "cell_equalize_v": 0.0, "cell_min_v": 1.75,
		"cell_storage_v": 2.25,
		"temp_comp_mv_c": -4.0,
		"charge_temp_c": [-20.0, 50.0], "discharge_temp_c": [-30.0, 50.0],
		"coulombic_eff": 0.92, "round_trip_eff": 0.85,
		"peukert": 1.12, "self_discharge_pct_month": 2.0,
		"recommended_dod": 0.5, "max_charge_c": 0.2,
		"cycles": [[0.3, 2000], [0.5, 1100], [0.8, 600], [1.0, 400]],
		"wh_per_kg": [25.0, 50.0], "wh_per_l": [60.0, 115.0],
		"stages": ["bulk", "absorb", "float"],
		"runaway": "none",
		"ocv": [1.967, 1.990, 2.008, 2.027, 2.045, 2.063, 2.080, 2.097, 2.113, 2.128, 2.142],
		"est": ["coulombic_eff", "round_trip_eff", "ocv", "peukert", "cycles"],
	},
	LFP: {
		"label": "LFP", "long": "Lithium iron phosphate (LiFePO4)",
		"family": "lithium", "vented": false, "maintenance": "None",
		"cell_nominal_v": 3.2, "cell_max_v": 3.65, "cell_absorb_v": 3.55,
		"cell_float_v": 3.375, "cell_equalize_v": 0.0, "cell_min_v": 2.5,
		"cell_storage_v": 3.30,
		"temp_comp_mv_c": 0.0,
		"charge_temp_c": [0.0, 55.0], "discharge_temp_c": [-20.0, 60.0],
		"coulombic_eff": 0.995, "round_trip_eff": 0.95,
		"peukert": 1.05, "self_discharge_pct_month": 3.0,
		"recommended_dod": 0.9, "max_charge_c": 0.5,
		"cycles": [[0.5, 10000], [0.8, 6000], [1.0, 4000]],
		"wh_per_kg": [90.0, 185.0], "wh_per_l": [140.0, 420.0],
		"stages": ["cc", "cv"],
		"runaway": "low",
		"ocv": [2.80, 3.00, 3.20, 3.22, 3.25, 3.26, 3.27, 3.30, 3.32, 3.33, 3.40],
		"est": ["round_trip_eff", "ocv", "cycles"],
	},
	NMC: {
		"label": "NMC", "long": "Lithium nickel manganese cobalt (NMC)",
		"family": "lithium", "vented": false, "maintenance": "None",
		"cell_nominal_v": 3.6, "cell_max_v": 4.2, "cell_absorb_v": 4.1,
		"cell_float_v": 0.0, "cell_equalize_v": 0.0, "cell_min_v": 2.5,
		"cell_storage_v": 3.80,
		"temp_comp_mv_c": 0.0,
		"charge_temp_c": [0.0, 45.0], "discharge_temp_c": [-20.0, 60.0],
		"coulombic_eff": 0.995, "round_trip_eff": 0.93,
		"peukert": 1.05, "self_discharge_pct_month": 2.0,
		"recommended_dod": 0.8, "max_charge_c": 0.7,
		"cycles": [[0.5, 2000], [0.8, 1000], [1.0, 500]],
		"wh_per_kg": [150.0, 280.0], "wh_per_l": [400.0, 750.0],
		"stages": ["cc", "cv"],
		"runaway": "high",
		"ocv": [3.27, 3.48, 3.60, 3.66, 3.71, 3.76, 3.82, 3.89, 3.98, 4.08, 4.20],
		"est": ["round_trip_eff", "ocv", "cycles"],
	},
}


static func has(id: String) -> bool:
	return TABLE.has(id)


## The row for a chemistry, LFP when unknown.
static func row(id: String) -> Dictionary:
	return TABLE.get(id, TABLE[LFP]) as Dictionary


static func field(id: String, key: String) -> Variant:
	return row(id).get(key)


static func label(id: String) -> String:
	return str(row(id).get("label", ""))


static func long_name(id: String) -> String:
	return str(row(id).get("long", ""))


static func is_lead(id: String) -> bool:
	return str(row(id).get("family", "")) == "lead"


static func is_lithium(id: String) -> bool:
	return str(row(id).get("family", "")) == "lithium"


## BatteryChemistry's class for this chemistry (what the graph sees).
static func graph_class(id: String) -> String:
	if id == LFP:
		return BatteryChemistry.LFP
	if id == NMC:
		return BatteryChemistry.LI_ION
	if is_lead(id):
		return BatteryChemistry.LEAD
	return BatteryChemistry.UNKNOWN


## A chemistry id from a typed name ("agm", "LiFePO4", "flooded" …); "" when
## nothing matches. Plain "lead" / "lead-acid" read as AGM, the common
## solar lead battery.
static func normalize(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	match s:
		"fla", "flooded", "flooded lead-acid", "wet":
			return FLA
		"sla", "vrla", "sealed", "sealed lead-acid":
			return SLA
		"agm", "lead", "lead-acid", "lead acid":
			return AGM
		"gel":
			return GEL
		"lfp", "lifepo4", "lifepo", "lithium iron phosphate":
			return LFP
		"nmc", "li-ion", "liion", "lithium-ion", "nca", "lipo":
			return NMC
	return ""


## A chemistry for a graph battery's specs: the explicit key, then words in
## the name, then BatteryChemistry's class (lead → AGM, Li-ion → NMC).
static func infer(specs: Dictionary) -> String:
	var explicit := normalize(str(specs.get("chemistry", "")))
	if not explicit.is_empty():
		var named := _from_name(str(specs.get("name", "")))
		# "SLA" is the graph's word for all sealed lead; a name can say which.
		if explicit == SLA and is_lead(named):
			return named
		return explicit
	var by_name := _from_name(str(specs.get("name", "")))
	if not by_name.is_empty():
		return by_name
	match BatteryChemistry.infer(specs):
		BatteryChemistry.LFP:
			return LFP
		BatteryChemistry.LI_ION:
			return NMC
		BatteryChemistry.LEAD:
			return AGM
	return ""


static func _from_name(name: String) -> String:
	var n := name.to_lower()
	if n.contains("lifepo") or n.contains("lfp"):
		return LFP
	if n.contains("nmc") or n.contains("li-ion") or n.contains("lithium-ion"):
		return NMC
	if n.contains("flooded") or n.contains(" fla") or n.begins_with("fla"):
		return FLA
	if n.contains("agm"):
		return AGM
	if n.contains("gel"):
		return GEL
	if n.contains("sla"):
		return SLA
	return ""


## Resting open-circuit voltage of one cell at a state of charge (0..1),
## linear between the table's 10 % points.
static func ocv(id: String, soc: float) -> float:
	var t: Array = row(id).get("ocv", []) as Array
	if t.is_empty():
		return float(row(id).get("cell_nominal_v", 0.0))
	var u := clampf(soc, 0.0, 1.0) / OCV_STEP
	var i := mini(int(floorf(u)), t.size() - 2)
	var f := u - float(i)
	return lerpf(float(t[i]), float(t[i + 1]), f)


## State of charge (0..1) at a resting cell voltage; the inverse of `ocv`.
## Flat stretches give the lowest SOC with that voltage.
static func soc_from_ocv(id: String, v: float) -> float:
	var t: Array = row(id).get("ocv", []) as Array
	if t.size() < 2:
		return 0.5
	if v <= float(t[0]):
		return 0.0
	for i in range(t.size() - 1):
		var a := float(t[i])
		var b := float(t[i + 1])
		if v <= b:
			var f := 0.0 if b <= a else (v - a) / (b - a)
			return (float(i) + f) * OCV_STEP
	return 1.0


## Charge voltage of one cell compensated for temperature (lead only;
## lithium chargers do not compensate). `stage` is "absorb" | "float" |
## "equalize".
static func charge_v(id: String, stage: String, temp_c: float = 25.0) -> float:
	var r := row(id)
	var v := float(r.get("cell_%s_v" % stage, 0.0))
	if v <= 0.0:
		return 0.0
	return v + float(r.get("temp_comp_mv_c", 0.0)) * 0.001 * (temp_c - 25.0)


## Whether a cell may be charged at this temperature.
static func can_charge_at(id: String, temp_c: float) -> bool:
	var w: Array = row(id).get("charge_temp_c", [-20.0, 50.0]) as Array
	return temp_c >= float(w[0]) and temp_c <= float(w[1])


static func can_discharge_at(id: String, temp_c: float) -> bool:
	var w: Array = row(id).get("discharge_temp_c", [-20.0, 60.0]) as Array
	return temp_c >= float(w[0]) and temp_c <= float(w[1])


## Cycles to end of life at a depth of discharge (0..1), log-linear between
## the table's points (cycle life vs DoD is close to a power law).
static func cycles_at_dod(id: String, dod: float) -> float:
	var t: Array = row(id).get("cycles", []) as Array
	if t.is_empty():
		return 0.0
	var d := clampf(dod, 0.01, 1.0)
	var first: Array = t[0]
	if d <= float(first[0]):
		return float(first[1])
	for i in range(t.size() - 1):
		var a: Array = t[i]
		var b: Array = t[i + 1]
		if d <= float(b[0]):
			var f := (log(d) - log(float(a[0]))) / (log(float(b[0])) - log(float(a[0])))
			return exp(lerpf(log(float(a[1])), log(float(b[1])), f))
	var last: Array = t[t.size() - 1]
	return float(last[1])


## Lifetime energy through the battery per Wh of capacity at a DoD (how many
## times its capacity it can deliver before end of life).
static func lifetime_throughput(id: String, dod: float) -> float:
	return cycles_at_dod(id, dod) * clampf(dod, 0.0, 1.0)


## Effective capacity at a discharge current by Peukert's law, given the
## rated capacity `c_rated` at the rated hours `h_rated` (20 h for lead).
## C_eff = C_rated · (I_rated / I)^(k − 1), I_rated = C_rated / h_rated.
static func peukert_capacity(id: String, c_rated_ah: float, current_a: float,
		h_rated: float = 20.0) -> float:
	if c_rated_ah <= 0.0 or current_a <= 0.0 or h_rated <= 0.0:
		return c_rated_ah
	var k := float(row(id).get("peukert", 1.0))
	var i_rated := c_rated_ah / h_rated
	return c_rated_ah * pow(i_rated / current_a, k - 1.0)


## Required ventilation (m³/h of fresh air) for a lead bank by IEC 62485-2:
## Q = 0.05 · n · Igas · C · 10⁻³. `cells` = cells in the room, `c_ah` the
## rated capacity, `mode` "float" | "boost". 0 for lithium.
static func ventilation_m3h(id: String, cells: int, c_ah: float, mode: String = "boost") -> float:
	if not is_lead(id):
		return 0.0
	var kind := "vented" if bool(row(id).get("vented", false)) else "vrla"
	var igas := float((IGAS_MA_PER_AH[kind] as Dictionary).get(mode, 0.0))
	return 0.05 * float(cells) * igas * c_ah * 0.001


## Hydrogen given off (litres at STP) by `ah` of overcharge on `cells` cells.
static func hydrogen_l(cells: int, ah: float) -> float:
	return H2_L_PER_AH_CELL * float(cells) * ah


## Self-discharge after `days` at rest (fraction of capacity lost).
static func self_discharge(id: String, days: float) -> float:
	var per_month := float(row(id).get("self_discharge_pct_month", 0.0)) * 0.01
	return 1.0 - pow(1.0 - per_month, days / 30.0)
