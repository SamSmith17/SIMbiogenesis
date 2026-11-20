class_name BattBms
extends RefCounted

## Battery management systems the Battery Lab can fit, and their protection
## settings.
##
## A BMS reads every series cell through the balance leads and the pack
## current through a shunt, and opens a CHARGE switch or a DISCHARGE switch
## (MOSFETs, or a contactor for big banks) when something is out of bounds.
## The two switches are separate on most lithium BMSs: a cell at its top
## voltage stops charging but the pack can still power loads, and a cell at
## its bottom stops discharging but can still take a charge.
##
## Products are TRANSCRIBED from maker pages as remembered, not re-checked;
## `est` lists typical figures. Protection numbers are each BMS's factory
## defaults where known, else `defaults_for(chem)` (common practice for the
## chemistry, after the cell makers' limits: EVE LF280K 2.5–3.65 V and charge
## 0–55 °C; Samsung 50E 2.5–4.2 V and charge 0–45 °C). A lead-acid bank has no
## BMS: the "shunt" entry is a battery monitor that measures and disconnects
## nothing.
##
## Every limit is a (trip, release, delay_s) triple: the BMS trips when the
## value has been past `trip` for `delay_s`, and releases once it is back past
## `release` (hysteresis, so a cell sitting on the line does not chatter).

## Protection keys, each {trip, release, delay_s}. Voltages per cell (V),
## currents for the whole pack as a multiple of the BMS's rating (×), so one
## table fits every size; temperatures °C.
const PROTECTIONS: Array = [
	"cell_ov", "cell_uv", "charge_oc", "discharge_oc", "discharge_oc2",
	"short_circuit", "charge_ot", "discharge_ot", "charge_ut", "discharge_ut",
]

## Protection words for the UI and the event log.
const WORDS := {
	"cell_ov": "Cell over-voltage", "cell_uv": "Cell under-voltage",
	"charge_oc": "Charge over-current", "discharge_oc": "Discharge over-current",
	"discharge_oc2": "Discharge over-current (fast)", "short_circuit": "Short circuit",
	"charge_ot": "Charge over-temperature", "discharge_ot": "Discharge over-temperature",
	"charge_ut": "Charge under-temperature", "discharge_ut": "Discharge under-temperature",
}

## Which switch each protection opens: "charge", "discharge" or "both".
const OPENS := {
	"cell_ov": "charge", "cell_uv": "discharge", "charge_oc": "charge",
	"discharge_oc": "discharge", "discharge_oc2": "discharge", "short_circuit": "both",
	"charge_ot": "charge", "discharge_ot": "discharge", "charge_ut": "charge",
	"discharge_ut": "discharge",
}

const BMS: Array = [
	{
		"id": "jk_b2a24s15p", "label": "JK B2A24S15P (active balance, 150 A)", "maker": "JK (Jikong)",
		"chems": ["LFP", "NMC"], "s_min": 8, "s_max": 24, "cont_a": 150.0, "peak_a": 300.0,
		"peak_s": 10.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "active", "a": 2.0, "start_v": {"LFP": 3.40, "NMC": 4.00}, "delta_v": 0.005},
		"comms": ["BT", "RS485"], "temp_sensors": 2, "precharge": false, "protection": true,
		"source": "JK BMS B2A24S15P product page", "est": ["peak_a", "peak_s"],
	},
	{
		"id": "jk_pb2a16s20p", "label": "JK PB2A16S20P inverter BMS (200 A)", "maker": "JK (Jikong)",
		"chems": ["LFP"], "s_min": 8, "s_max": 16, "cont_a": 200.0, "peak_a": 350.0,
		"peak_s": 10.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "active", "a": 2.0, "start_v": {"LFP": 3.40}, "delta_v": 0.005},
		"comms": ["CAN", "RS485", "BT"], "temp_sensors": 4, "precharge": true, "protection": true,
		"source": "JK inverter BMS PB2A16S20P product page", "est": ["peak_a", "peak_s"],
	},
	{
		"id": "jbd_4s_100a", "label": "JBD / Overkill 4S 100 A", "maker": "JBD (Jiabaida)",
		"chems": ["LFP"], "s_min": 4, "s_max": 4, "cont_a": 100.0, "peak_a": 200.0,
		"peak_s": 5.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.05, "start_v": {"LFP": 3.40}, "delta_v": 0.015},
		"comms": ["BT", "UART"], "temp_sensors": 2, "precharge": false, "protection": true,
		"source": "JBD SP04S034 / Overkill Solar 4S product pages", "est": ["peak_a", "peak_s"],
	},
	{
		"id": "jbd_16s_100a", "label": "JBD / Overkill 16S 100 A", "maker": "JBD (Jiabaida)",
		"chems": ["LFP", "NMC"], "s_min": 8, "s_max": 16, "cont_a": 100.0, "peak_a": 200.0,
		"peak_s": 5.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.05, "start_v": {"LFP": 3.40, "NMC": 4.00}, "delta_v": 0.015},
		"comms": ["BT", "UART", "RS485"], "temp_sensors": 2, "precharge": false, "protection": true,
		"source": "JBD 16S / Overkill Solar 16S product pages", "est": ["peak_a", "peak_s"],
	},
	{
		"id": "daly_16s_100a", "label": "Daly Smart 16S 100 A", "maker": "Daly",
		"chems": ["LFP", "NMC"], "s_min": 16, "s_max": 16, "cont_a": 100.0, "peak_a": 300.0,
		"peak_s": 5.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.03, "start_v": {"LFP": 3.40, "NMC": 4.00}, "delta_v": 0.030},
		"comms": ["BT", "UART", "RS485", "CAN"], "temp_sensors": 2, "precharge": false,
		"protection": true,
		"source": "Daly smart BMS product page", "est": ["peak_a", "peak_s", "delta_v"],
	},
	{
		"id": "seplos_10e", "label": "Seplos 10E 16S 200 A", "maker": "Seplos",
		"chems": ["LFP"], "s_min": 16, "s_max": 16, "cont_a": 200.0, "peak_a": 250.0,
		"peak_s": 10.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.05, "start_v": {"LFP": 3.40}, "delta_v": 0.030},
		"comms": ["CAN", "RS485"], "temp_sensors": 4, "precharge": true, "protection": true,
		"source": "Seplos 10E BMS product page", "est": ["peak_a", "peak_s", "a"],
	},
	{
		"id": "batrium_watchmon", "label": "Batrium WatchMon (contactor)", "maker": "Batrium",
		"chems": ["LFP", "NMC"], "s_min": 4, "s_max": 64, "cont_a": 500.0, "peak_a": 1000.0,
		"peak_s": 10.0, "switch": "contactor", "common_port": true,
		"balance": {"kind": "passive", "a": 1.5, "start_v": {"LFP": 3.45, "NMC": 4.05}, "delta_v": 0.010},
		"comms": ["CAN", "Wi-Fi"], "temp_sensors": 4, "precharge": true, "protection": true,
		"source": "Batrium WatchMon / CellMate product pages; current set by the contactor and shunt",
		"est": ["cont_a", "peak_a", "peak_s"],
	},
	{
		"id": "builtin_dropin_100", "label": "Built into a 12 V 100 Ah drop-in", "maker": "Generic",
		"chems": ["LFP"], "s_min": 4, "s_max": 4, "cont_a": 100.0, "peak_a": 200.0,
		"peak_s": 30.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.05, "start_v": {"LFP": 3.45}, "delta_v": 0.030},
		"comms": [], "temp_sensors": 1, "precharge": false, "protection": true,
		"source": "typical 12 V 100 Ah drop-in LFP data sheets (Battle Born, Renogy, SOK class)",
		"est": ["peak_a", "peak_s", "a", "delta_v"],
	},
	{
		"id": "builtin_rack_100", "label": "Built into a 48 V 100 Ah rack pack", "maker": "Generic",
		"chems": ["LFP"], "s_min": 15, "s_max": 16, "cont_a": 100.0, "peak_a": 150.0,
		"peak_s": 10.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.05, "start_v": {"LFP": 3.40}, "delta_v": 0.030},
		"comms": ["CAN", "RS485"], "temp_sensors": 4, "precharge": true, "protection": true,
		"source": "typical 48 V server-rack LFP data sheets (EG4 LifePower4, Pylontech class)",
		"est": ["peak_a", "peak_s", "a", "delta_v"],
	},
	{
		"id": "builtin_rack_200", "label": "Built into a 48 V 200–314 Ah pack", "maker": "Generic",
		"chems": ["LFP"], "s_min": 16, "s_max": 16, "cont_a": 200.0, "peak_a": 250.0,
		"peak_s": 10.0, "switch": "fet", "common_port": true,
		"balance": {"kind": "passive", "a": 0.05, "start_v": {"LFP": 3.40}, "delta_v": 0.030},
		"comms": ["CAN", "RS485"], "temp_sensors": 4, "precharge": true, "protection": true,
		"source": "typical 48 V 280–314 Ah wall-mount LFP data sheets",
		"est": ["peak_a", "peak_s", "a", "delta_v"],
	},
	{
		"id": "shunt_monitor", "label": "Battery monitor only (shunt, no protection)",
		"maker": "Victron (SmartShunt class)", "chems": ["FLA", "SLA", "AGM", "GEL", "LFP", "NMC"],
		"s_min": 1, "s_max": 999, "cont_a": 500.0, "peak_a": 500.0, "peak_s": 0.0,
		"switch": "none", "common_port": true,
		"balance": {"kind": "none", "a": 0.0, "start_v": {}, "delta_v": 0.0},
		"comms": ["BT"], "temp_sensors": 1, "precharge": false, "protection": false,
		"source": "Victron SmartShunt 500 A product page", "est": [],
	},
]

static var _by_id: Dictionary = {}


static func _index() -> void:
	if not _by_id.is_empty():
		return
	for b in BMS:
		_by_id[str((b as Dictionary)["id"])] = b


static func has(id: String) -> bool:
	_index()
	return _by_id.has(id)


## A BMS by id ({} when unknown). Shared: copy before changing.
static func get_bms(id: String) -> Dictionary:
	_index()
	return _by_id.get(id, {}) as Dictionary


static func ids() -> Array:
	var out: Array = []
	for b in BMS:
		out.append(str((b as Dictionary)["id"]))
	return out


## BMSs that fit a pack: the chemistry is supported, the series count is in
## range and the rated current covers `need_a` (0 = any).
static func fitting(chem: String, series: int, need_a: float = 0.0) -> Array:
	var out: Array = []
	for b in BMS:
		var d: Dictionary = b
		if not (d["chems"] as Array).has(chem):
			continue
		if series < int(d["s_min"]) or series > int(d["s_max"]):
			continue
		if need_a > 0.0 and float(d["cont_a"]) < need_a:
			continue
		out.append(d)
	return out


## Common-practice protection settings for a chemistry: per-cell volts,
## pack currents as × the BMS rating, °C. Lead returns {} (no BMS).
static func defaults_for(chem: String) -> Dictionary:
	var r := BattChem.row(chem)
	if not BattChem.is_lithium(chem):
		return {}
	var vmax := float(r["cell_max_v"])
	var vmin := float(r["cell_min_v"])
	var ct: Array = r["charge_temp_c"]
	var dt: Array = r["discharge_temp_c"]
	var ov_release := 3.40 if chem == BattChem.LFP else 4.10
	var uv_release := 2.90 if chem == BattChem.LFP else 3.10
	return {
		"cell_ov": {"trip": vmax, "release": ov_release, "delay_s": 1.0},
		"cell_uv": {"trip": vmin, "release": uv_release, "delay_s": 1.0},
		"charge_oc": {"trip": 1.0, "release": 0.0, "delay_s": 10.0},
		"discharge_oc": {"trip": 1.0, "release": 0.0, "delay_s": 10.0},
		"discharge_oc2": {"trip": 1.5, "release": 0.0, "delay_s": 1.0},
		"short_circuit": {"trip": 5.0, "release": 0.0, "delay_s": 0.0003},
		"charge_ot": {"trip": float(ct[1]), "release": float(ct[1]) - 5.0, "delay_s": 5.0},
		"discharge_ot": {"trip": float(dt[1]), "release": float(dt[1]) - 5.0, "delay_s": 5.0},
		"charge_ut": {"trip": float(ct[0]), "release": float(ct[0]) + 5.0, "delay_s": 5.0},
		"discharge_ut": {"trip": float(dt[0]), "release": float(dt[0]) + 5.0, "delay_s": 5.0},
	}


## The protection settings a BMS runs on a chemistry: its own (`protect`)
## over the chemistry's defaults, then the player's `overrides` (same shape,
## any subset of keys / fields). A monitor returns {}.
static func params(bms_id: String, chem: String, overrides: Dictionary = {}) -> Dictionary:
	var b := get_bms(bms_id)
	if b.is_empty() or not bool(b.get("protection", false)):
		return {}
	var out := defaults_for(chem).duplicate(true)
	for layer in [b.get("protect", {}), overrides]:
		for k in (layer as Dictionary):
			if not out.has(k):
				continue
			var cur: Dictionary = out[k]
			var patch: Dictionary = (layer as Dictionary)[k]
			for f in patch:
				cur[f] = patch[f]
	return out


## Current limits in amps for a protection that is a multiple of the rating.
static func current_trip_a(bms_id: String, p: Dictionary, key: String) -> float:
	var b := get_bms(bms_id)
	return float(b.get("cont_a", 0.0)) * float((p.get(key, {}) as Dictionary).get("trip", 0.0))


## Balance settings for a chemistry: {kind, a, start_v, delta_v}.
static func balance_for(bms_id: String, chem: String) -> Dictionary:
	var b := get_bms(bms_id)
	var bal: Dictionary = b.get("balance", {}) as Dictionary
	var starts: Dictionary = bal.get("start_v", {}) as Dictionary
	return {
		"kind": str(bal.get("kind", "none")), "a": float(bal.get("a", 0.0)),
		"start_v": float(starts.get(chem, 0.0)), "delta_v": float(bal.get("delta_v", 0.0)),
	}


## Hours a balancer needs to even out `delta_ah` of mismatch between cells
## (a passive bleeder only works while the top cell is above its start
## voltage, i.e. near full charge: this is the time spent there).
static func balance_hours(bms_id: String, chem: String, delta_ah: float) -> float:
	var a := float(balance_for(bms_id, chem)["a"])
	return INF if a <= 0.0 else delta_ah / a


## Whether `p` is self-consistent; returns problem sentences ([] = fine).
static func check_params(p: Dictionary) -> Array:
	var out: Array = []
	if p.is_empty():
		return out
	var ov: Dictionary = p.get("cell_ov", {})
	var uv: Dictionary = p.get("cell_uv", {})
	if float(ov.get("release", 0.0)) >= float(ov.get("trip", 0.0)):
		out.append("Over-voltage release must be below its trip.")
	if float(uv.get("release", 0.0)) <= float(uv.get("trip", 0.0)):
		out.append("Under-voltage release must be above its trip.")
	if float(uv.get("release", 0.0)) >= float(ov.get("release", 0.0)):
		out.append("The under-voltage and over-voltage windows overlap.")
	for k in ["charge_ot", "discharge_ot"]:
		var t: Dictionary = p.get(k, {})
		if float(t.get("release", 0.0)) >= float(t.get("trip", 0.0)):
			out.append("%s release must be below its trip." % WORDS[k])
	for k in ["charge_ut", "discharge_ut"]:
		var t: Dictionary = p.get(k, {})
		if float(t.get("release", 0.0)) <= float(t.get("trip", 0.0)):
			out.append("%s release must be above its trip." % WORDS[k])
	return out
