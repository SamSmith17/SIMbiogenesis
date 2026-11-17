class_name TcProcSpec
extends RefCounted

## The `process` block of a TC design (TC Process Lab): what is loaded,
## how it is run, what is measured and switched, and the automations. It
## lives in the spec so it travels with the design and the library;
## TcSpec.key_of leaves it out of the GEOMETRY key (a process edit never
## re-solves the assembly), `key_of` here keys the process run.
##
##   {"charge": {"feed", "mass_kg", "moisture", "bulk_kg_m3"},
##    "heaters": {"default_w", "by_part": {pid: {"w", "on"}}},
##    "cooling": {"t_c", "lpm"},            per cooling-water circuit
##    "ambient_c", "back_kpa" (gauge at the product outlet), "relief_bar",
##    "duration_h", "start_hour" (the clock time the batch starts at: time
##    rules count from it), "sensors": [{name, kind, part}] (probes the
##    player dropped), "actuators": [], "automations": [] (the card specs,
##    run in the model by TcProcControl)}

## What can be loaded. Composition on a dry basis (mass fractions);
## moisture is on top of it, as a share of the wet mass. Bulk density of the
## loaded charge, wet (kg/m³).
##  - Softwood chips: Sjöström 1993 (cellulose 42 %, hemicellulose 27 %,
##    lignin 28 %, ash/extractives 3 %); chip bulk ~250 kg/m³ wet (FAO wood
##    fuel tables give 200–300).
##  - Hardwood: Sjöström 1993 (45 / 30 / 22, ash 3).
##  - Plastic pellets: virgin PE / PP, bulk ~550 kg/m³ (estimate).
##  - Water, a 10 % (by volume) ethanol wash: liquids.
const FEEDS := {
	"wood_chips": {"label": "Softwood chips", "solid": {"cellulose": 0.42, "hemicellulose": 0.27, "lignin": 0.28, "ash": 0.03},
		"bulk_kg_m3": 250.0},
	"hardwood": {"label": "Hardwood chips", "solid": {"cellulose": 0.45, "hemicellulose": 0.30, "lignin": 0.22, "ash": 0.03},
		"bulk_kg_m3": 300.0},
	"pe_pellets": {"label": "Polyethylene pellets", "solid": {"pe": 1.0}, "bulk_kg_m3": 550.0},
	"pp_pellets": {"label": "Polypropylene pellets", "solid": {"pp": 1.0}, "bulk_kg_m3": 550.0},
	"water": {"label": "Water", "liquid": {"H2O": 1.0}, "bulk_kg_m3": 1000.0},
	"wash": {"label": "Ethanol wash (10 % ABV)", "liquid_vol": {"ethanol": 0.10, "H2O": 0.90}, "bulk_kg_m3": 985.0},
}


static func defaults() -> Dictionary:
	return {
		"charge": {"feed": "wood_chips", "mass_kg": 10.0, "moisture": 0.20, "bulk_kg_m3": 0.0},
		"heaters": {"default_w": 600.0, "by_part": {}},
		"cooling": {"t_c": 15.0, "lpm": 2.0},
		"ambient_c": 20.0,
		"back_kpa": 0.0,
		"relief_bar": 1.0,
		"jacket_fill": "air",
		"duration_h": 8.0,
		"start_hour": 8.0,
		"sensors": [],
		"actuators": [],
		"automations": [],
		"recipe": {},
	}


## The user's reactor (2026-11-06): ~10 kg of softwood chips at 20 %
## moisture round two 600 W bottom elements, the lid sealed.
static func biochar_default() -> Dictionary:
	var d := defaults()
	d["duration_h"] = 10.0
	# Its jacket gap packed with mineral wool: an air gap loses about two
	# thirds of 1.2 kW at 200 °C and the charge's edge never chars.
	d["jacket_fill"] = "insulation"
	return d


## Pot still: 20 L of a 10 % ABV wash on a 2 kW element, both condensers
## on 2 L/min. It boils near 92 °C (the wash's bubble point), the first
## condenser sends reflux back down the column, the second collects the
## spirit at the product end.
static func pot_still_default() -> Dictionary:
	var d := defaults()
	d["charge"] = {"feed": "wash", "mass_kg": 20.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["heaters"]["default_w"] = 2000.0
	d["duration_h"] = 4.0
	return d


## Brew kettle: 40 L of water (a stand-in for wort) on a 3 kW element, lid
## vent open: it comes to the boil in about an hour and a half and boils off.
static func kettle_default() -> Dictionary:
	var d := defaults()
	d["charge"] = {"feed": "water", "mass_kg": 40.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["heaters"]["default_w"] = 3000.0
	d["duration_h"] = 2.5
	return d


## Two-tank level rig: 150 L of water in the supply tank, nothing heated, an
## hour's run. `ids` = {supply, tank, pump, valve} part ids and `slug` the
## design's slug: a PID holds the middle tank at half by the control valve.
static func level_rig_default(slug: String, ids: Dictionary) -> Dictionary:
	var d := defaults()
	d["charge"] = {"feed": "water", "mass_kg": 150.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["heaters"]["default_w"] = 0.0
	d["duration_h"] = 0.5
	d["logic"] = [{"id": "b1", "kind": "pid", "name": "Hold the process tank at half", "enabled": true,
		"pv": "sensor.%s_%s_level" % [slug, str(ids.get("tank", ""))],
		"out": "number.%s_%s_opening" % [slug, str(ids.get("valve", ""))],
		"sp": 50.0, "kp": 4.0, "ti_min": 2.0, "td_min": 0.0, "out_min": 0.0, "out_max": 100.0, "reverse": false,
		"mode": "auto", "manual_out": 0.0, "bias": 0.0}]
	return d


## Brewhouse: 40 L of water in the hot liquor tank and a sequence that runs
## the brew day in small (about two hours): heat the liquor, mash in, rest
## with the stirrer... there is no malt in the model: it is water all the way,
## which is what a wet test of a real brewhouse is.
static func brewhouse_default(slug: String, ids: Dictionary) -> Dictionary:
	var d := defaults()
	d["charge"] = {"feed": "water", "mass_kg": 40.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["heaters"]["default_w"] = 3000.0
	d["heaters"]["by_part"] = {str(ids["h_hlt"]): {"w": 3000.0, "on": false}, str(ids["h_kettle"]): {"w": 3500.0, "on": false}}
	d["cooling"] = {"t_c": 12.0, "lpm": 8.0}
	d["duration_h"] = 2.5
	var sw := func(k: String) -> String: return "switch.%s_%s" % [slug, str(ids[k])]
	var lvl := func(k: String) -> String: return "sensor.%s_%s_level" % [slug, str(ids[k])]
	var tmp := func(k: String) -> String: return "sensor.%s_%s_liquid_temp" % [slug, str(ids[k])]
	d["logic"] = [{"id": "b1", "kind": "sequence", "name": "Brew day", "enabled": true, "repeat": false, "autostart": true, "steps": [
		{"name": "Heat the liquor to 70 °C", "set": [{"tag": sw.call("h_hlt"), "value": 1.0}],
			"until": {"tag": tmp.call("hlt"), "op": ">=", "value": 70.0}, "min_s": 0.0, "timeout_s": 7200.0},
		{"name": "Mash in", "set": [{"tag": sw.call("h_hlt"), "value": 0.0}, {"tag": sw.call("p1"), "value": 1.0}],
			"until": {"tag": lvl.call("hlt"), "op": "<=", "value": 14.0}, "min_s": 0.0, "timeout_s": 1800.0},
		{"name": "Mash rest, stirred", "set": [{"tag": sw.call("p1"), "value": 0.0}, {"tag": sw.call("stir"), "value": 1.0}], "until": {}, "min_s": 1200.0, "timeout_s": 0.0},
		{"name": "Run off to the kettle", "set": [{"tag": sw.call("stir"), "value": 0.0}, {"tag": sw.call("p2"), "value": 1.0}],
			"until": {"tag": lvl.call("mash"), "op": "<=", "value": 14.0}, "min_s": 0.0, "timeout_s": 1800.0},
		{"name": "Bring to the boil", "set": [{"tag": sw.call("p2"), "value": 0.0}, {"tag": sw.call("h_kettle"), "value": 1.0}],
			"until": {"tag": tmp.call("kettle"), "op": ">=", "value": 99.0}, "min_s": 0.0, "timeout_s": 7200.0},
		{"name": "Boil", "set": [], "until": {}, "min_s": 600.0, "timeout_s": 0.0},
		{"name": "Knock out through the chiller", "set": [{"tag": sw.call("h_kettle"), "value": 0.0}, {"tag": sw.call("p3"), "value": 1.0}],
			"until": {"tag": lvl.call("kettle"), "op": "<=", "value": 14.0}, "min_s": 0.0, "timeout_s": 3600.0},
		{"name": "Done", "set": [{"tag": sw.call("p3"), "value": 0.0}], "until": {}, "min_s": 1.0, "timeout_s": 0.0}]}]
	return d


## Clean-in-place: 100 L of rinse water, 50 L in the wash tank held hot, a
## sequence: rinse, hot wash, rinse, each drained to the receiver.
static func cip_default(slug: String, ids: Dictionary) -> Dictionary:
	var d := defaults()
	d["charge"] = {"feed": "water", "mass_kg": 100.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["liquids"] = [{"part": str(ids["wash"]), "litres": 50.0, "feed": "water", "t_c": 20.0}]
	d["heaters"]["default_w"] = 0.0
	d["heaters"]["by_part"] = {str(ids["h_wash"]): {"w": 3000.0, "on": true}}
	d["duration_h"] = 1.5
	var sw := func(k: String) -> String: return "switch.%s_%s" % [slug, str(ids[k])]
	var lvl := func(k: String) -> String: return "sensor.%s_%s_level" % [slug, str(ids[k])]
	var wash_t := "sensor.%s_%s_liquid_temp" % [slug, str(ids["wash"])]
	var fill := func(name: String, valve: String, mark: float) -> Dictionary:
		return {"name": name, "set": [{"tag": sw.call("sv_drain"), "value": 0.0}, {"tag": sw.call(valve), "value": 1.0}, {"tag": sw.call("pump"), "value": 1.0}],
			"until": {"tag": lvl.call("target"), "op": ">=", "value": mark}, "min_s": 0.0, "timeout_s": 900.0}
	var drain := func(name: String, valve: String) -> Dictionary:
		return {"name": name, "set": [{"tag": sw.call(valve), "value": 0.0}, {"tag": sw.call("pump"), "value": 0.0}, {"tag": sw.call("sv_drain"), "value": 1.0}],
			"until": {"tag": lvl.call("target"), "op": "<=", "value": 11.0}, "min_s": 60.0, "timeout_s": 1800.0}
	d["logic"] = [
		{"id": "b1", "kind": "band", "name": "Hold the wash at 60–65 °C", "enabled": true, "pv": wash_t,
			"out": "switch.%s_%s" % [slug, str(ids["h_wash"])], "low": 60.0, "high": 65.0, "direction": "fill"},
		{"id": "b2", "kind": "sequence", "name": "Clean in place", "enabled": true, "repeat": false, "autostart": true, "steps": [
			fill.call("Pre-rinse", "sv_rinse", 30.0), drain.call("Drain the rinse", "sv_rinse"),
			{"name": "Wait for the wash to reach 60 °C", "set": [], "until": {"tag": wash_t, "op": ">=", "value": 60.0}, "min_s": 0.0, "timeout_s": 3600.0},
			fill.call("Hot wash", "sv_wash", 30.0),
			{"name": "Soak", "set": [{"tag": sw.call("sv_wash"), "value": 0.0}, {"tag": sw.call("pump"), "value": 0.0}], "until": {}, "min_s": 300.0, "timeout_s": 0.0},
			drain.call("Drain the wash", "sv_wash"),
			fill.call("Final rinse", "sv_rinse", 30.0), drain.call("Drain", "sv_rinse"),
			{"name": "Done", "set": [{"tag": sw.call("sv_drain"), "value": 0.0}], "until": {}, "min_s": 1.0, "timeout_s": 0.0}]}]
	return d


## Water filter train: 180 L of raw water; the pump keeps the clean tank
## between 40 and 80 %, and the high level switch stops it whatever asks.
static func filter_train_default(slug: String, ids: Dictionary) -> Dictionary:
	var d := defaults()
	d["charge"] = {"feed": "water", "mass_kg": 180.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["heaters"]["default_w"] = 0.0
	d["duration_h"] = 0.5
	var pump := "switch.%s_%s" % [slug, str(ids["pump"])]
	d["logic"] = [
		{"id": "b1", "kind": "band", "name": "Keep the clean tank between 40 and 80 %", "enabled": true,
			"pv": "sensor.%s_%s_level" % [slug, str(ids["clean"])], "out": pump, "low": 40.0, "high": 80.0, "direction": "fill"},
		{"id": "b2", "kind": "interlock", "name": "Stop the pump on overfill", "enabled": true, "match": "any", "latch": false,
			"when": [{"tag": "sensor.%s_%s" % [slug, str(ids["switch"])], "op": ">=", "value": 0.5}], "out": pump, "safe": 0.0}]
	return d


## Plastic retort: 8 kg of polypropylene pellets round the two 600 W
## elements. The pellets melt, the melt cracks (~430 °C) into light gas, oil
## and wax; the condensers drop the oil and wax.
static func plastic_default() -> Dictionary:
	var d := biochar_default()
	d["charge"] = {"feed": "pp_pellets", "mass_kg": 8.0, "moisture": 0.0, "bulk_kg_m3": 0.0}
	d["duration_h"] = 8.0
	return d


static func _num(v: Variant, dflt: float, lo: float, hi: float) -> float:
	var f := float(v) if (v is float or v is int) else dflt
	return clampf(f, lo, hi)


## Fill defaults and clamp; never throws.
static func resolve(raw: Variant) -> Dictionary:
	var src: Dictionary = raw if raw is Dictionary else {}
	var d := defaults()
	var ch: Dictionary = src.get("charge", {}) if src.get("charge", {}) is Dictionary else {}
	var feed := str(ch.get("feed", "wood_chips"))
	d["charge"] = {"feed": feed if FEEDS.has(feed) else "wood_chips",
		"mass_kg": _num(ch.get("mass_kg", 10.0), 10.0, 0.0, 2000.0),
		"moisture": _num(ch.get("moisture", 0.20), 0.20, 0.0, 0.7),
		"bulk_kg_m3": _num(ch.get("bulk_kg_m3", 0.0), 0.0, 0.0, 2000.0)}
	var he: Dictionary = src.get("heaters", {}) if src.get("heaters", {}) is Dictionary else {}
	var by := {}
	var rb: Variant = he.get("by_part", {})
	if rb is Dictionary:
		for k in rb:
			if rb[k] is Dictionary:
				by[str(k)] = {"w": _num(rb[k].get("w", 600.0), 600.0, 0.0, 20000.0), "on": bool(rb[k].get("on", true))}
	d["heaters"] = {"default_w": _num(he.get("default_w", 600.0), 600.0, 0.0, 20000.0), "by_part": by}
	var co: Dictionary = src.get("cooling", {}) if src.get("cooling", {}) is Dictionary else {}
	d["cooling"] = {"t_c": _num(co.get("t_c", 15.0), 15.0, 0.0, 95.0), "lpm": _num(co.get("lpm", 2.0), 2.0, 0.0, 100.0)}
	d["ambient_c"] = _num(src.get("ambient_c", 20.0), 20.0, -40.0, 60.0)
	d["back_kpa"] = _num(src.get("back_kpa", 0.0), 0.0, -50.0, 500.0)
	d["relief_bar"] = _num(src.get("relief_bar", 1.0), 1.0, 0.05, 20.0)
	d["jacket_fill"] = "insulation" if str(src.get("jacket_fill", "air")) == "insulation" else "air"
	d["duration_h"] = _num(src.get("duration_h", 8.0), 8.0, 0.1, 72.0)
	d["start_hour"] = _num(src.get("start_hour", 8.0), 8.0, 0.0, 23.99)
	# Jackets fed by a medium: {vessel part: {t_c, lpm, on}}.
	var jk := {}
	var rj: Variant = src.get("jackets", {})
	if rj is Dictionary:
		for kj in rj:
			if rj[kj] is Dictionary:
				jk[str(kj)] = {"t_c": _num(rj[kj].get("t_c", 60.0), 60.0, 0.0, 99.0), "lpm": _num(rj[kj].get("lpm", 10.0), 10.0, 0.0, 200.0),
					"on": bool(rj[kj].get("on", false))}
	d["jackets"] = jk
	for k in ["sensors", "actuators", "automations", "logic", "liquids"]:
		var a: Variant = src.get(k, [])
		d[k] = (a as Array).duplicate(true) if a is Array else []
	# Engines (TcUnits.genset) start off unless the design says on.
	var en := {}
	var re: Variant = src.get("engines", {})
	if re is Dictionary:
		for k2 in re:
			if re[k2] is Dictionary:
				en[str(k2)] = {"on": bool(re[k2].get("on", false))}
	d["engines"] = en
	# What goes on the controller board (TcProcBoard): {on: {entity: bool}}.
	var bo: Variant = src.get("board", {})
	var on := {}
	if bo is Dictionary and (bo as Dictionary).has("on") and bo["on"] is Dictionary:
		for k3 in bo["on"]:
			on[str(k3)] = bool(bo["on"][k3])
	d["board"] = {"on": on}
	# A lab run fitted for the world's graph (TcProcSummary); a placed
	# assembly's node runs it.
	d["recipe"] = (src["recipe"] as Dictionary).duplicate(true) if src.get("recipe") is Dictionary else {}
	# The P&ID picture's own layout (MimicCanvas): where the player dragged
	# things, {pins: {element id: [dx, dy]}} in picture mm. Never restarts a run.
	var mi: Variant = src.get("mimic", {})
	var mp := {}
	if mi is Dictionary and (mi as Dictionary).get("pins") is Dictionary:
		for k4 in mi["pins"]:
			var pv: Variant = mi["pins"][k4]
			if pv is Array and (pv as Array).size() >= 2:
				mp[str(k4)] = [float(pv[0]), float(pv[1])]
	d["mimic"] = {"pins": mp}
	return d


static func key_of(proc: Dictionary) -> String:
	return TcSpec.key_of({"p": proc})


## A heater's watts and on flag in this process.
static func heater(proc: Dictionary, pid: String) -> Dictionary:
	var by: Dictionary = (proc.get("heaters", {}) as Dictionary).get("by_part", {})
	if by.has(pid):
		return by[pid]
	return {"w": float((proc.get("heaters", {}) as Dictionary).get("default_w", 600.0)), "on": true}
