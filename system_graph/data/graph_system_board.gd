class_name GraphSystemBoard
extends RefCounted
## The Festival board's data (plans/GRAPH_SYSTEMS_UX_PLAN.md, Phase 3): one
## row per power system on the site, what is going wrong in it, how urgent it
## is, and the overlay colours the canvas paints systems with.
##
## A row is built from data that is already stamped or already stepped (the
## camp_* keys, the camp / vehicle power states, CampLedger over the system's
## own scope). It never walks the model per draw: the view rebuilds every row
## once a second and everything else (board, dashboard, tiles, alerts rail)
## reads them. Pure and static (selftests load it under --script).

const LEVEL_RANK := {"idle": 0, "ok": 1, "warn": 2, "crit": 3}

## A system is "short" of water / food below these many days.
const DAYS_CRIT := 1.0
const DAYS_WARN := 3.0
const SOC_WARN := 0.2
const MORALE_CRIT := 0.35
const MORALE_WARN := 0.55

## Board filters.
const FILTERS := ["all", "attention", "camp", "vehicle"]
const FILTER_LABELS := {"all": "All", "attention": "Needs attention",
	"camp": "Camps", "vehicle": "Vehicles"}

## Board sort keys -> column title.
const SORTS := ["attention", "name", "people", "soc", "water", "food"]
const SORT_LABELS := {"attention": "Attention", "name": "Name", "people": "People",
	"soc": "Battery", "water": "Water", "food": "Food"}


## One system's row. `item` is the island compound ({} for the site's own
## system, then `site` carries {name, soc, kwh, cap_kwh, pv_kw, load_kw, ac}).
## `power` = the island's CampPowerModel state (may be {}); `ledger` =
## CampLedger.compute over its scope (may be {}).
static func row(item: Dictionary, power: Dictionary, ledger: Dictionary,
		site: Dictionary = {}) -> Dictionary:
	var r := {"id": "", "kind": GraphSystems.KIND_SITE, "name": "", "scope": GraphModel.ROOT_SCOPE_ID,
		"people": -1, "morale": -1.0, "soc": -1.0, "kwh": 0.0, "cap_kwh": 0.0,
		"pv_kw": 0.0, "load_kw": 0.0, "ac": true, "hours_left": INF,
		"water_days": INF, "food_days": INF, "has_water": false, "has_food": false,
		"open": [], "stores": [], "level": "idle", "reasons": [], "attention": 0.0}
	if item.is_empty():
		r["name"] = str(site.get("name", "Your system"))
		r["soc"] = float(site.get("soc", -1.0))
		r["kwh"] = float(site.get("kwh", 0.0))
		r["cap_kwh"] = float(site.get("cap_kwh", 0.0))
		r["pv_kw"] = float(site.get("pv_kw", 0.0))
		r["load_kw"] = float(site.get("load_kw", 0.0))
		r["ac"] = bool(site.get("ac", true))
		r["hours_left"] = _hours_left(r)
	else:
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		r["id"] = str(item.get("id", ""))
		r["kind"] = GraphSystems.island_kind(item)
		r["name"] = str(sp.get("name", item.get("label", "")))
		r["scope"] = str(item.get("child_scope_id", ""))
		if r["kind"] == GraphSystems.KIND_CAMP:
			r["people"] = int(sp.get("camp_present", sp.get("camp_headcount", 0)))
			r["morale"] = float(sp.get("camp_morale", -1.0))
			var cap := float(sp.get("battery_kwh", 0.0))
			r["cap_kwh"] = cap
			if not power.is_empty() and cap > 0.0:
				r["kwh"] = float(power.get("soc_kwh", 0.0))
				r["soc"] = clampf(r["kwh"] / cap, 0.0, 1.0)
			elif sp.has("camp_soc") and cap > 0.0:
				r["soc"] = float(sp["camp_soc"])
				r["kwh"] = r["soc"] * cap
			r["pv_kw"] = float(power.get("pv_kw", sp.get("camp_pv_kw", 0.0)))
			r["load_kw"] = float(power.get("load_kw", sp.get("camp_load_kw", 0.0)))
			r["ac"] = bool(power.get("ac_available", sp.get("camp_ac", true)))
			r["open"] = (sp.get("camp_open", []) as Array).duplicate()
		else:
			r["cap_kwh"] = float(power.get("cap_kwh", 0.0))
			if not power.is_empty() and float(power.get("cap_kwh", 0.0)) > 0.0:
				r["kwh"] = float(power.get("soc_kwh", 0.0))
				r["soc"] = clampf(r["kwh"] / float(power["cap_kwh"]), 0.0, 1.0)
			r["pv_kw"] = float(power.get("pv_kw", 0.0))
			r["load_kw"] = float(power.get("load_kw", 0.0))
			r["ac"] = bool(power.get("ac_available", true))
		r["hours_left"] = float(power.get("hours_left", _hours_left(r)))
	_apply_ledger(r, ledger)
	_judge(r)
	return r


## Hours to empty at the current draw (INF when charging or no battery).
static func _hours_left(r: Dictionary) -> float:
	var net := float(r["pv_kw"]) - float(r["load_kw"])
	if net >= -1e-6 or float(r["kwh"]) <= 0.0:
		return INF
	return float(r["kwh"]) / -net


static func _apply_ledger(r: Dictionary, ledger: Dictionary) -> void:
	var kinds: Dictionary = ledger.get("kinds", {}) as Dictionary
	var stores: Array = []
	for k: String in kinds.keys():
		var row_k: Dictionary = kinds[k]
		if float(row_k.get("capacity", 0.0)) <= 0.0 and float(row_k.get("stock", 0.0)) <= 0.0:
			continue
		stores.append({"kind": k, "stock": float(row_k.get("stock", 0.0)),
			"capacity": float(row_k.get("capacity", 0.0)), "unit": str(row_k.get("unit", "")),
			"days": float(row_k.get("days_to_empty", INF)),
			"days_full": float(row_k.get("days_to_full", INF)),
			"status": str(row_k.get("status", ""))})
	stores.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["kind"]) < str(b["kind"]))
	r["stores"] = stores
	for s: Dictionary in stores:
		if str(s["kind"]) == "water":
			r["has_water"] = true
			r["water_days"] = minf(float(r["water_days"]), float(s["days"]))
		elif str(s["kind"]) == "food":
			r["has_food"] = true
			r["food_days"] = minf(float(r["food_days"]), float(s["days"]))
	if r["open"].is_empty():
		r["open"] = (ledger.get("open", []) as Array).duplicate()


## Level, the reasons behind it, and the attention score the board sorts by.
static func _judge(r: Dictionary) -> void:
	var level := "ok"
	var reasons: Array = []
	var score := 0.0
	if r["kind"] != GraphSystems.KIND_SITE and int(r["people"]) == 0 and float(r["cap_kwh"]) <= 0.0 \
			and not bool(r["has_water"]):
		level = "idle"
	if not bool(r["ac"]):
		level = _worse(level, "crit")
		reasons.append("no power")
		score += 50.0
	elif float(r["soc"]) >= 0.0 and float(r["soc"]) < SOC_WARN:
		level = _worse(level, "warn")
		reasons.append("battery %d %%" % int(round(float(r["soc"]) * 100.0)))
		score += 10.0 + (SOC_WARN - float(r["soc"])) * 50.0
	for pair: Array in [["water", "water_days"], ["food", "food_days"]]:
		var d := float(r[pair[1]])
		if d < DAYS_CRIT:
			level = _worse(level, "crit")
			reasons.append("%s %s" % [pair[0], fmt_days(d)])
			score += 40.0 + (DAYS_CRIT - maxf(d, 0.0)) * 10.0
		elif d < DAYS_WARN:
			level = _worse(level, "warn")
			reasons.append("%s %s" % [pair[0], fmt_days(d)])
			score += 8.0 + (DAYS_WARN - d) * 2.0
	var morale := float(r["morale"])
	if int(r["people"]) > 0 and morale >= 0.0:
		if morale < MORALE_CRIT:
			level = _worse(level, "crit")
			reasons.append("morale low")
			score += 30.0 + (MORALE_CRIT - morale) * 40.0
		elif morale < MORALE_WARN:
			level = _worse(level, "warn")
			reasons.append("morale falling")
			score += 6.0 + (MORALE_WARN - morale) * 20.0
	# Wastes filling up: a tank that will be full soon is as urgent as an
	# input running out.
	for st: Dictionary in (r["stores"] as Array):
		var k := str(st["kind"])
		if not CampLedger.WASTE_KINDS.has(k):
			continue
		var df := float(st["days_full"])
		if df < DAYS_CRIT:
			level = _worse(level, "crit")
			reasons.append("%s %s" % [k, fmt_full(df)])
			score += 35.0
		elif df < DAYS_WARN:
			level = _worse(level, "warn")
			reasons.append("%s %s" % [k, fmt_full(df)])
			score += 6.0
	# An open loop (used, not made here) is only news when nothing covers it:
	# a camp living off a week of stored water is fine; the days above say
	# when that runs out. A kind with no store at all is a warning.
	var stored: Dictionary = {}
	for st: Dictionary in (r["stores"] as Array):
		stored[str(st["kind"])] = true
	var bare := PackedStringArray()
	for k: Variant in (r["open"] as Array):
		if not stored.has(str(k)):
			bare.append(str(k))
	if not bare.is_empty():
		level = _worse(level, "warn")
		reasons.append("no %s here" % ", ".join(bare))
		score += 3.0 * bare.size()
	r["level"] = level
	r["reasons"] = reasons
	r["attention"] = score + float(LEVEL_RANK[level]) * 100.0


static func _worse(a: String, b: String) -> String:
	return b if int(LEVEL_RANK[b]) > int(LEVEL_RANK[a]) else a


## "0.6 days", "2.4 days", "never" — for reasons and board cells.
static func fmt_days(d: float) -> String:
	if not is_finite(d):
		return "lasting"
	if d < 0.1:
		return "empty"
	if d < 1.0:
		return "%d h left" % int(round(d * 24.0))
	return "%.1f days" % d


## "full now", "full in 5 h", "full in 2.4 days", "room to spare".
static func fmt_full(d: float) -> String:
	if not is_finite(d):
		return "room to spare"
	if d < 0.05:
		return "full now"
	if d < 1.0:
		return "full in %d h" % maxi(1, int(round(d * 24.0)))
	return "full in %.1f days" % d


static func sorted(rows: Array, key: String, descending: bool = true) -> Array:
	var out := rows.duplicate()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var va: Variant = _sort_value(a, key)
		var vb: Variant = _sort_value(b, key)
		if va == vb:
			return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0
		if key == "name":
			return (str(va).naturalnocasecmp_to(str(vb)) < 0) != descending
		return (float(va) > float(vb)) == descending)
	return out


static func _sort_value(r: Dictionary, key: String) -> Variant:
	match key:
		"name":
			return str(r["name"])
		"people":
			return float(r["people"])
		"soc":
			return float(r["soc"])
		"water":
			return minf(float(r["water_days"]), 1.0e6) if r["has_water"] else -1.0
		"food":
			return minf(float(r["food_days"]), 1.0e6) if r["has_food"] else -1.0
	return float(r["attention"])


static func filtered(rows: Array, f: String) -> Array:
	if f == "all" or f.is_empty():
		return rows.duplicate()
	var out: Array = []
	for r: Dictionary in rows:
		match f:
			"attention":
				if str(r["level"]) in ["warn", "crit"]:
					out.append(r)
			_:
				if str(r["kind"]) == f:
					out.append(r)
	return out


## The whole festival in one dict: systems by level, people, power, stores.
static func totals(rows: Array) -> Dictionary:
	var t := {"systems": 0, "camps": 0, "vehicles": 0, "people": 0, "crit": 0, "warn": 0,
		"pv_kw": 0.0, "load_kw": 0.0, "kwh": 0.0, "cap_kwh": 0.0, "no_power": 0,
		"short_water": 0, "short_food": 0}
	for r: Dictionary in rows:
		if str(r["kind"]) == GraphSystems.KIND_SITE:
			continue
		t["systems"] += 1
		t["camps" if str(r["kind"]) == GraphSystems.KIND_CAMP else "vehicles"] += 1
		t["people"] += maxi(0, int(r["people"]))
		match str(r["level"]):
			"crit":
				t["crit"] += 1
			"warn":
				t["warn"] += 1
		t["pv_kw"] += float(r["pv_kw"])
		t["load_kw"] += float(r["load_kw"])
		t["kwh"] += float(r["kwh"])
		t["cap_kwh"] += float(r["cap_kwh"])
		if not bool(r["ac"]):
			t["no_power"] += 1
		if float(r["water_days"]) < DAYS_WARN:
			t["short_water"] += 1
		if float(r["food_days"]) < DAYS_WARN:
			t["short_food"] += 1
	return t


# ---------------------------------------------------------------------------
# Overlays (View ▾ → Colour systems by): one value per system, four bins on
# one legend. NAN = no data (drawn neutral, never filtered out).
# ---------------------------------------------------------------------------

const OVERLAYS := ["none", "soc", "water", "morale", "margin"]
const OVERLAY_LABELS := {"none": "Nothing", "soc": "Battery", "water": "Water days",
	"morale": "Morale", "margin": "Power margin"}
const BIN_COLORS := [GraphTheme.LEVEL_CRIT, GraphTheme.LEVEL_WARN,
	Color(0.80, 0.84, 0.36), GraphTheme.LEVEL_OK]
const NO_DATA_COLOR := GraphTheme.LEVEL_IDLE


static func overlay_value(r: Dictionary, mode: String) -> float:
	match mode:
		"soc":
			return float(r["soc"]) if float(r["soc"]) >= 0.0 else NAN
		"water":
			return float(r["water_days"]) if bool(r["has_water"]) else NAN
		"morale":
			return float(r["morale"]) if int(r["people"]) > 0 and float(r["morale"]) >= 0.0 else NAN
		"margin":
			if float(r["cap_kwh"]) <= 0.0 and float(r["pv_kw"]) <= 0.0 and float(r["load_kw"]) <= 0.0:
				return NAN
			if not bool(r["ac"]):
				return 0.0
			var net := float(r["pv_kw"]) - float(r["load_kw"])
			if net >= 0.02:
				return INF
			return float(r["hours_left"])
	return NAN


## The bin a value falls in (0 = worst … 3 = best), -1 for no data.
static func overlay_bin(mode: String, v: float) -> int:
	if is_nan(v):
		return -1
	match mode:
		"soc":
			return 0 if v < 0.2 else (1 if v < 0.5 else (2 if v < 0.8 else 3))
		"water":
			return 0 if v < 1.0 else (1 if v < 3.0 else (2 if v < 7.0 else 3))
		"morale":
			return 0 if v < 0.35 else (1 if v < 0.55 else (2 if v < 0.75 else 3))
		"margin":
			return 0 if v < 6.0 else (1 if v < 24.0 else (2 if is_finite(v) else 3))
	return -1


static func overlay_color(mode: String, v: float) -> Color:
	var b := overlay_bin(mode, v)
	return NO_DATA_COLOR if b < 0 else BIN_COLORS[b]


## [{label, color}] worst first, for the canvas legend.
static func legend(mode: String) -> Array:
	var labels: Array = []
	match mode:
		"soc":
			labels = ["under 20 %", "20–50 %", "50–80 %", "80 % +"]
		"water":
			labels = ["under 1 day", "1–3 days", "3–7 days", "a week +"]
		"morale":
			labels = ["very low", "low", "fine", "good"]
		"margin":
			labels = ["out in < 6 h", "out in < 24 h", "lasts a day +", "charging"]
	var out: Array = []
	for i in labels.size():
		out.append({"label": labels[i], "color": BIN_COLORS[i]})
	return out


## {system id: value} for every row, for the canvas.
static func overlay_values(rows: Array, mode: String) -> Dictionary:
	var out: Dictionary = {}
	if mode == "none":
		return out
	for r: Dictionary in rows:
		if not str(r["id"]).is_empty():
			out[str(r["id"])] = overlay_value(r, mode)
	return out
