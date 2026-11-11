extends RefCounted

## Whole-system design harness, part 3: what a run means.
## `assess(year, design)` -> {verdict, checks, ...}; `markdown(...)` the
## readable sheet; `csv(...)` one row per sim day.

const WASTE_KINDS := ["greywater", "blackwater", "food_waste", "packaging_waste",
	"plastic_waste", "manure", "urine", "brine"]
const SUPPLY_KINDS := ["water", "food", "meal"]


static func assess(y: Object, design: Dictionary) -> Dictionary:
	var days: float = (y.cursor - y.start_abs) / 24.0
	var people_n := int(design.get("people", 10))
	var checks: Array = []
	var e: Dictionary = y.energy
	var p: Dictionary = y.people
	var last: Dictionary = p.get("last", {})

	# An empty meal counter is not hunger: people fall back to the pantry.
	var starved_total := 0.0
	for k in (p["starved_h"] as Dictionary).keys():
		if str(k) != "meal":
			starved_total += float((p["starved_h"] as Dictionary)[k])
	_chk(checks, "Nobody went without water or food",
		starved_total <= 2.0, "%s" % _hours_by(p["starved_h"]))
	_chk(checks, "The power never went out",
		float(e["ac_off_h"]) <= 0.5,
		"%.1f h with AC off in %d outage(s), lowest battery %.0f %%" % [
			float(e["ac_off_h"]), int(e["ac_off_events"]), float(e["min_soc_pct"])])
	var present := int(last.get("count", people_n)) if not last.is_empty() else -1
	_chk(checks, "Everyone stayed",
		present == people_n and int(p["departures"]) == 0,
		"%d of %d on site, %d left" % [present, people_n, int(p["departures"])])
	var mean_morale := float(p["morale_sum"]) / maxf(float(p["samples"]), 1.0)
	_chk(checks, "People were doing fine", mean_morale >= 0.6,
		"mean morale %.2f (%s), worst moment %.2f" % [mean_morale,
			NpcMorale.label(mean_morale), float(p["min_morale"])])

	# Nothing from outside: no import node ran, no ideal-supply top-ups.
	# A MATERIAL import (waste plastic to make things with) is reported, not
	# failed: nobody lives on it.
	var import_h := 0.0
	var imp_names: Array = []
	var material: Array = []
	for iid in y.acc:
		var a: Dictionary = y.acc[iid]
		if a["type"] != "processor":
			continue
		var it: Dictionary = y.model.get_item(iid)
		var isp: Dictionary = it.get("specs", {})
		if not bool(isp.get("counts_as_import", false)) or float(a["running_h"]) <= 0.0:
			continue
		if bool(isp.get("material_import", false)):
			material.append("%s %.0f h" % [str(a["name"]), float(a["running_h"])])
			continue
		import_h += float(a["running_h"])
		imp_names.append(str(a["name"]))
	var ideal := 0.0
	for k2 in (p["ideal_import"] as Dictionary).keys():
		ideal += float((p["ideal_import"] as Dictionary)[k2])
	_chk(checks, "Nothing was brought in from outside",
		import_h <= 0.0 and ideal <= 0.01,
		"import nodes ran %.0f h %s; ideal-supply top-ups %.1f%s" % [import_h, str(imp_names), ideal,
			("; material imports (not counted): " + ", ".join(material)) if not material.is_empty() else ""])

	# Nothing dumped: no waste tank overflowed.
	var dumped := {}
	var lost := {}
	for iid2 in y.acc:
		var t: Dictionary = y.acc[iid2]
		if t["type"] != "tank" or float(t["overflow"]) <= 0.5:
			continue
		if str(t["kind"]) in WASTE_KINDS:
			dumped[str(t["name"])] = "%.0f %s" % [float(t["overflow"]), str(t["unit"])]
		else:
			lost[str(t["name"])] = "%.0f %s" % [float(t["overflow"]), str(t["unit"])]
	_chk(checks, "No waste overflowed untreated", dumped.is_empty(), str(dumped) if not dumped.is_empty() else "none")

	# Stores that people live on must not be running down year over year.
	var trend: Array = []
	var trend_ok := true
	for iid3 in y.acc:
		var t2: Dictionary = y.acc[iid3]
		if t2["type"] != "tank" or str(t2["kind"]) not in ["water", "food"] or not bool(t2["feeds"]):
			continue
		var use_per_day := float(t2["out"]) / maxf(days, 1e-6)
		var auton := float(t2["end"]) / maxf(use_per_day, 1e-9)
		trend.append("%s: %.0f -> %.0f %s (low %.0f), %.0f days of use left" % [str(t2["name"]),
			float(t2["start"]), float(t2["end"]), str(t2["unit"]), float(t2["min"]), auton])
		if float(t2["end"]) < float(t2["start"]) * 0.9 and days >= 300.0:
			trend_ok = false
	_chk(checks, "Water and food stores ended the run no lower than they began",
		trend_ok, "; ".join(trend))

	# The flow engine lets a nearly empty store serve a whole step's draw, so a
	# store that keeps hitting empty hands out more than it held. Flag it.
	var phantom := {}
	for iid4 in y.acc:
		var t3: Dictionary = y.acc[iid4]
		if t3["type"] != "tank":
			continue
		var ph := float(t3["end"]) - (float(t3["start"]) + float(t3["in"]) - float(t3["out"]) - float(t3["overflow"]))
		t3["phantom"] = maxf(ph, 0.0)
		if ph > maxf(0.02 * float(t3["out"]), 1.0):
			phantom[str(t3["name"])] = "%.1f %s of %.0f drawn" % [ph, str(t3["unit"]), float(t3["out"])]
	_chk(checks, "No store handed out more than it held", phantom.is_empty(),
		str(phantom) if not phantom.is_empty() else "balanced")

	var ok := true
	for c: Dictionary in checks:
		if not bool(c["ok"]):
			ok = false
	return {"sustained": ok, "checks": checks, "days": days, "mean_morale": mean_morale,
		"lost": lost, "dumped": dumped}


static func _chk(checks: Array, name: String, ok: bool, detail: String) -> void:
	checks.append({"name": name, "ok": ok, "detail": detail})


static func _hours_by(d: Dictionary) -> String:
	if d.is_empty():
		return "0 h"
	var parts: Array = []
	for k in d.keys():
		parts.append("%s %.1f h" % [str(k), float(d[k])])
	return ", ".join(parts)


static func markdown(y: Object, design: Dictionary, res: Dictionary) -> String:
	var L: Array = []
	var days: float = res["days"]
	L.append("# %s" % str(design.get("name", "design")))
	L.append("")
	L.append("**%s** over %.0f days from %s, %d people, %d-minute steps." % [
		"SUSTAINED" if bool(res["sustained"]) else "NOT SUSTAINED", days,
		str(design.get("_start_text", "")), int(design.get("people", 10)),
		int(round(y.step_h * 60.0))])
	L.append("")
	L.append("| Check | Result | Detail |")
	L.append("|---|---|---|")
	for c: Dictionary in res["checks"]:
		L.append("| %s | %s | %s |" % [str(c["name"]), "yes" if bool(c["ok"]) else "**no**", str(c["detail"])])
	L.append("")
	var e: Dictionary = y.energy
	L.append("## Energy")
	L.append("")
	L.append("- Battery %.1f kWh. Solar the array could make: %.0f kWh; used: %.0f kWh; curtailed: %.0f kWh." % [
		y.cap_kwh, float(e["raw_kwh"]), float(e["solar_kwh"]), float(e["curtailed_kwh"])])
	L.append("- Loads served: %.0f kWh (%.1f kWh a day). Other generation into the bank: %.0f kWh." % [
		float(e["load_kwh"]), float(e["load_kwh"]) / maxf(days, 1e-6), float(e["aux_kwh"])])
	L.append("- Lowest battery: %.0f %%. AC off: %.1f h." % [float(e["min_soc_pct"]), float(e["ac_off_h"])])
	L.append("")
	L.append("## Stores")
	L.append("")
	L.append("| Store | Kind | Size | Start | Low | High | End | In | Out | Overflow | Empty h |")
	L.append("|---|---|---|---|---|---|---|---|---|---|---|")
	for iid in y.acc:
		var t: Dictionary = y.acc[iid]
		if t["type"] != "tank":
			continue
		L.append("| %s | %s | %.0f %s | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f |" % [
			str(t["name"]), str(t["kind"]), float(t["cap"]), str(t["unit"]), float(t["start"]),
			float(t["min"]), float(t["max"]), float(t["end"]), float(t["in"]), float(t["out"]),
			float(t["overflow"]), float(t["empty_h"])])
	L.append("")
	L.append("## Machines")
	L.append("")
	L.append("| Node | Running h | Share | Blocked h | Starved h | kWh | Why blocked |")
	L.append("|---|---|---|---|---|---|---|")
	for iid2 in y.acc:
		var a: Dictionary = y.acc[iid2]
		if a["type"] == "tank":
			continue
		var why: Array = []
		for r in (a["reasons"] as Dictionary).keys():
			why.append("%s %.0f h" % [str(r), float((a["reasons"] as Dictionary)[r])])
		L.append("| %s | %.0f | %.0f %% | %.0f | %.0f | %.0f | %s |" % [str(a["name"]),
			float(a["running_h"]), 100.0 * float(a["running_h"]) / maxf(days * 24.0, 1e-6),
			float(a["blocked_h"]), float(a["starved_h"]), float(a["kwh"]), ", ".join(why)])
	L.append("")
	var p: Dictionary = y.people
	L.append("## People")
	L.append("")
	var last: Dictionary = p.get("last", {})
	L.append("- On site at the end: %d. Departures: %d. Mean morale %.2f; worst single moment %.2f." % [
		int(last.get("count", 0)), int(p["departures"]), float(res["mean_morale"]), float(p["min_morale"])])
	L.append("- Hours a need was blocked (person-hours): %s." % _hours_by(p["blocked_h"]))
	L.append("- Habitat starved: %s." % _hours_by(p["starved_h"]))
	if not last.is_empty():
		L.append("- Walking: %.0f m a person a day (%s)." % [float(last.get("walk_distance_m", 0.0)), str(last.get("walk_label", ""))])
	L.append("")
	if not (y.events as Array).is_empty():
		L.append("## Events (first %d)" % mini((y.events as Array).size(), 40))
		L.append("")
		for i in mini((y.events as Array).size(), 40):
			var ev: Dictionary = y.events[i]
			L.append("- day %.1f: %s" % [float(ev["day"]), str(ev["text"])])
		L.append("")
	L.append("Sim cost: %d steps; people %.0f s, resources %.0f s, all %.0f s." % [y.steps,
		y.t_pop_us / 1e6, y.t_flow_us / 1e6, y.t_misc_us / 1e6])
	return "\n".join(L) + "\n"


static func csv(y: Object) -> String:
	var ids: Array = []
	for iid in y.acc:
		if (y.acc[iid] as Dictionary)["type"] == "tank":
			ids.append(iid)
	var head: Array = ["day", "soc_pct", "solar_kwh", "load_kwh", "ac_off_h", "people", "morale"]
	for iid2 in ids:
		head.append(str((y.acc[iid2] as Dictionary)["name"]).replace(",", " "))
	var rows: Array = [",".join(head)]
	for r: Dictionary in y.daily:
		var cells: Array = [str(r["day"]), "%.1f" % float(r["soc_pct"]), "%.2f" % float(r["solar_kwh"]),
			"%.2f" % float(r["load_kwh"]), "%.2f" % float(r["ac_off_h"]), str(r.get("people", 0)),
			"%.3f" % float(r.get("morale", 0.0))]
		for iid3 in ids:
			cells.append("%.1f" % float((r["tanks"] as Dictionary).get(iid3, 0.0)))
		rows.append(",".join(cells))
	return "\n".join(rows) + "\n"
