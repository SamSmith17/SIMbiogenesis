extends RefCounted

## The compact run report: what an AI reads to judge a design and decide the
## next change, in as few tokens as a whole year can be said in.
##
## Rules it keeps (so two runs can be diffed key by key):
##   - every number is rounded to 3 significant figures;
##   - tables are {cols: [...], rows: [[...]]}, never one object per row;
##   - rows are keyed by the DESIGN's node id (gh_3, cistern), the same id a
##     patch names, never the graph's internal id;
##   - no coordinates, place names or addresses (the site is its id only);
##   - "bottlenecks" is the ranked short list of what limited the design,
##     written as plain sentences with the node id first.
## Version `v` moves when a key changes meaning.

const VERSION := 1
const CHECK_IDS := ["water_food", "power", "everyone_stayed", "morale", "no_imports",
	"no_waste_overflow", "stores_trend", "balanced"]


static func summary(y: Object, design: Dictionary, res: Dictionary, ids: Dictionary, meta: Dictionary) -> Dictionary:
	var days: float = res["days"]
	var e: Dictionary = y.energy
	var p: Dictionary = y.people
	var last: Dictionary = p.get("last", {})
	var did := _design_ids(y, ids)
	var checks: Array = []
	var fails: Array = []
	var ci := 0
	for c: Dictionary in res["checks"]:
		var cid: String = CHECK_IDS[ci] if ci < CHECK_IDS.size() else "check_%d" % ci
		ci += 1
		checks.append([cid, 1 if bool(c["ok"]) else 0, str(c["detail"]).substr(0, 220)])
		if not bool(c["ok"]):
			fails.append(cid)
	var raw := float(e["raw_kwh"])
	var kwp := float(meta.get("pv_kwp", 0.0))
	var kpi := {
		"pv_kwp": _r(kwp), "battery_kwh": _r(float(y.cap_kwh)),
		"solar_possible_kwh": _r(raw), "solar_used_kwh": _r(float(e["solar_kwh"])),
		"curtailed_pct": _r(100.0 * float(e["curtailed_kwh"]) / maxf(raw, 1e-6)),
		"yield_kwh_per_kwp": _r(raw / maxf(kwp, 1e-6)) if kwp > 0.0 else 0,
		"load_kwh": _r(float(e["load_kwh"])), "load_kwh_day": _r(float(e["load_kwh"]) / maxf(days, 1e-6)),
		"other_gen_kwh": _r(float(e["aux_kwh"])),
		"ac_off_h": _r(float(e["ac_off_h"])), "outages": int(e["ac_off_events"]),
		"min_soc_pct": _r(float(e["min_soc_pct"])),
		"people_start": int(design.get("people", 0)),
		"people_end": int(last.get("count", design.get("people", 0))),
		"departures": int(p["departures"]),
		"morale_mean": _r(float(res.get("mean_morale", 0.0))) if not is_nan(float(res.get("mean_morale", 0.0))) else "n/a",
		"morale_min": _r(float(p["min_morale"])) if int(p["samples"]) > 0 else "n/a",
	}
	var stores := {"cols": ["id", "kind", "unit", "cap", "start", "end", "min", "in", "out",
		"empty_h", "full_h", "overflow"], "rows": []}
	var machines := {"cols": ["id", "role", "run_pct", "blocked_h", "starved_h", "kwh", "why_blocked"], "rows": []}
	var neck: Array = []   # [weight, text]
	for iid in y.acc:
		var a: Dictionary = y.acc[iid]
		var nid := str(did.get(iid, iid))
		if a["type"] == "tank":
			(stores["rows"] as Array).append([nid, str(a["kind"]), str(a["unit"]), _r(float(a["cap"])),
				_r(float(a["start"])), _r(float(a["end"])), _r(float(a["min"])), _r(float(a["in"])),
				_r(float(a["out"])), _r(float(a["empty_h"])), _r(float(a["full_h"])), _r(float(a["overflow"]))])
			if float(a["empty_h"]) > 0.5 and bool(a["feeds"]):
				neck.append([float(a["empty_h"]) * (3.0 if str(a["kind"]) in ["water", "food"] else 1.0),
					"%s (%s) was empty %s h, first on day %s" % [nid, str(a["kind"]), _r(float(a["empty_h"])),
						_r(float(a["first_empty_day"]))]])
			if float(a["overflow"]) > 0.5:
				neck.append([float(a["overflow"]) / maxf(float(a["cap"]), 1.0) * 24.0,
					"%s overflowed %s %s: too small or nothing draws it down" % [nid, _r(float(a["overflow"])), str(a["unit"])]])
		else:
			var why := ""
			var top := 0.0
			for r in (a["reasons"] as Dictionary).keys():
				if float((a["reasons"] as Dictionary)[r]) > top:
					top = float((a["reasons"] as Dictionary)[r])
					why = str(r)
			(machines["rows"] as Array).append([nid, str(a.get("role", "")),
				_r(100.0 * float(a["running_h"]) / maxf(days * 24.0, 1e-6)),
				_r(float(a["blocked_h"])), _r(float(a["starved_h"])), _r(float(a["kwh"])), why])
			if float(a["blocked_h"]) > 0.05 * days * 24.0:
				neck.append([float(a["blocked_h"]) * 0.5, "%s blocked %s h (%s)" % [nid, _r(float(a["blocked_h"])), why]])
			if float(a["starved_h"]) > 0.05 * days * 24.0:
				neck.append([float(a["starved_h"]) * 0.5, "%s starved %s h" % [nid, _r(float(a["starved_h"]))]])
	if float(e["ac_off_h"]) > 0.5:
		neck.append([float(e["ac_off_h"]) * 4.0, "power: AC off %s h in %d outages, battery low %s %%" % [
			_r(float(e["ac_off_h"])), int(e["ac_off_events"]), _r(float(e["min_soc_pct"]))]])
	if raw > 0.0 and float(e["curtailed_kwh"]) / raw > 0.3:
		neck.append([float(e["curtailed_kwh"]) / maxf(days, 1.0), "power: %s %% of possible solar was curtailed (spare for loads or storage)" % _r(
			100.0 * float(e["curtailed_kwh"]) / raw)])
	for k in (p["blocked_h"] as Dictionary).keys():
		var h := float((p["blocked_h"] as Dictionary)[k])
		if h > 1.0:
			neck.append([h, "people: need '%s' blocked %s person-h" % [str(k), _r(h)]])
	neck.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	var bottlenecks: Array = []
	for i in mini(neck.size(), 10):
		bottlenecks.append(str(neck[i][1]))
	var out := {
		"v": VERSION, "run": str(meta.get("run_id", "")), "design": str(design.get("name", "")),
		"site": str(meta.get("site_id", "")), "start": str(design.get("_start_text", "")),
		"days": _r(days), "verdict": "SUSTAINED" if bool(res["sustained"]) else "NOT_SUSTAINED",
		"fails": fails, "checks": {"cols": ["id", "ok", "detail"], "rows": checks},
		"kpi": kpi, "bottlenecks": bottlenecks, "stores": stores, "machines": machines,
		"people_blocked_h": _round_dict(p["blocked_h"]),
		"flows": flows(y, did, days),
		"monthly": monthly(y),
		"fidelity": {"kernel": "headless", "people": str(meta.get("people_mode", "agents")),
			"step_min": _r(float(meta.get("step_min", 6.0))),
			"hazards": bool(meta.get("hazards", false)),
			"labour": str(meta.get("labour", "crew")),
			"not_simulated": ["terrain ponds and streams", "panel shade from trees or buildings",
				"camp power"] + ([] if bool(meta.get("hazards", false)) else ["weather hazards"])},
		"cost": {"wall_s": _r(float(meta.get("wall_s", 0.0))), "steps": int(y.steps)},
	}
	return out


## What the wires carried over the run, and how much of each resource
## cycled (Finn's cycling index over the run's mean flows, the same maths as
## the graph's Flows lens: LoopSankeyLayout.cycling_metrics). Rows are the
## biggest wires by total, keyed by design node ids:
##   {"cycling": {kind: {pct_cycled, loops, wires}}, "wires": {cols, rows}}
const FLOW_ROWS := 40

static func flows(y: Object, did: Dictionary, days: float) -> Dictionary:
	var tot: Dictionary = y.get("conn_tot") if y.get("conn_tot") != null else {}
	var ends: Dictionary = y.get("_conn_ends") if y.get("_conn_ends") != null else {}
	var hours := maxf(days * 24.0, 1e-6)
	var edges: Array = []
	var rows: Array = []
	for cid in tot:
		var t: Array = tot[cid]
		var e: Array = ends.get(cid, [])
		if e.size() < 2 or float(t[1]) <= 0.0:
			continue
		var a := str(did.get(str(e[0]), e[0]))
		var b := str(did.get(str(e[1]), e[1]))
		edges.append({"id": str(cid), "a": a, "b": b, "key": str(t[0]), "value": float(t[1]) / hours})
		rows.append([a, b, str(t[0]), float(t[1]), float(t[1]) / hours])
	rows.sort_custom(func(x, z) -> bool: return float(x[3]) > float(z[3]))
	var out_rows: Array = []
	for r in rows.slice(0, FLOW_ROWS):
		out_rows.append([r[0], r[1], r[2], _r(float(r[3])), _r(float(r[4]))])
	var ids := {}
	for ed in edges:
		ids[ed["a"]] = true
		ids[ed["b"]] = true
	var m := LoopSankeyLayout.cycling_metrics(ids.keys(), edges, [], [])
	var lay_loops := 0
	if edges.size() <= 600:
		var nodes: Array = []
		for nid in ids:
			nodes.append({"id": str(nid)})
		lay_loops = (LoopSankeyLayout.layout(nodes, edges).get("loops", []) as Array).size()
	var cyc := {}
	for k in m:
		var mm: Dictionary = m[k]
		cyc[str(k)] = {"pct_cycled": _r(100.0 * float(mm["fci"])), "nodes": int(mm.get("nodes", 0))}
	return {"cycling": cyc, "loops": lay_loops,
		"wires": {"cols": ["from", "to", "kind", "total", "mean_per_h"], "rows": out_rows}}


## The run's wires as a LoopSankeyLayout input: each wire's mean flow per
## hour over the run, between design node ids (labels by `labels`).
static func flow_input(y: Object, did: Dictionary, days: float, labels: Dictionary = {}) -> Dictionary:
	var tot: Dictionary = y.get("conn_tot") if y.get("conn_tot") != null else {}
	var ends: Dictionary = y.get("_conn_ends") if y.get("_conn_ends") != null else {}
	var hours := maxf(days * 24.0, 1e-6)
	var edges: Array = []
	var touched := {}
	var keys := {}
	for cid in tot:
		var t: Array = tot[cid]
		var e: Array = ends.get(cid, [])
		if e.size() < 2 or float(t[1]) <= 0.0:
			continue
		var a := str(did.get(str(e[0]), e[0]))
		var b := str(did.get(str(e[1]), e[1]))
		if a == b:
			continue
		edges.append({"id": str(cid), "a": a, "b": b, "key": str(t[0]), "value": float(t[1]) / hours})
		touched[a] = true
		touched[b] = true
		keys[str(t[0])] = true
	var nodes: Array = []
	var labs := {}
	var ids: Array = touched.keys()
	ids.sort()
	for nid in ids:
		labs[nid] = str(labels.get(nid, nid))
		nodes.append({"id": str(nid), "label": labs[nid]})
	return {"nodes": nodes, "edges": edges, "bin": [], "bout": [], "labels": labs, "types": {},
		"keys": keys.keys(), "opts": {"thickness": 30.0, "layer_gap": 90.0, "node_h": 30.0,
			"min_node_w": 150.0}}


## The year's loop Sankey as an SVG (LoopSankeySvg), for the run folder.
static func flows_svg(y: Object, did: Dictionary, days: float, labels: Dictionary, title: String) -> String:
	var inp := flow_input(y, did, days, labels)
	if (inp["edges"] as Array).is_empty() or (inp["edges"] as Array).size() > 900:
		return ""
	var lay := LoopSankeyLayout.layout(inp["nodes"], inp["edges"], [], [], inp["opts"])
	var cyc: Array = []
	var m: Dictionary = lay.get("metrics", {})
	for k in m:
		var fci := float((m[k] as Dictionary).get("fci", 0.0))
		if fci >= 0.005:
			cyc.append("%s %d %% cycled" % [ResourceKinds.display_name(str(k)), int(round(fci * 100.0))])
	var sub := "Mean flow per hour over %s. %s" % [UiText.count(days, "day"),
		", ".join(cyc) if not cyc.is_empty() else "Nothing cycled back."]
	return LoopSankeySvg.render(lay, {"title": title, "subtitle": sub,
		"color_of": func(k: String) -> Color: return ResourceKinds.wire_color(k),
		"name_of": func(k: String) -> String: return ResourceKinds.display_name(k),
		"fmt": func(k: String, v: float) -> String:
			return "%s/h" % UiText.num(v, ResourceKinds.default_unit(k))})


## One row per calendar month of the run.
static func monthly(y: Object) -> Dictionary:
	var rows: Array = []
	var cur := ""
	var acc := {}
	for r: Dictionary in y.daily:
		var d: Dictionary = y.main.get("clock").call("abs_hours_to_date",
			float(y.start_abs) + float(r["day"]) * 24.0 + 12.0)
		var key := "%04d-%02d" % [int(d.get("year", 0)), int(d.get("month", 0))]
		if key != cur:
			if not cur.is_empty():
				rows.append(_month_row(cur, acc))
			cur = key
			acc = {"solar": 0.0, "load": 0.0, "off": 0.0, "min_soc": 100.0, "morale": 0.0, "n": 0, "people": 0}
		acc["solar"] += float(r["solar_kwh"])
		acc["load"] += float(r["load_kwh"])
		acc["off"] += float(r["ac_off_h"])
		acc["min_soc"] = minf(float(acc["min_soc"]), float(r["soc_pct"]))
		acc["morale"] += float(r.get("morale", 0.0))
		acc["n"] += 1
		acc["people"] = int(r.get("people", 0))
	if not cur.is_empty():
		rows.append(_month_row(cur, acc))
	return {"cols": ["month", "solar_kwh", "load_kwh", "ac_off_h", "min_soc_pct", "morale", "people"], "rows": rows}


static func _month_row(key: String, a: Dictionary) -> Array:
	return [key, _r(float(a["solar"])), _r(float(a["load"])), _r(float(a["off"])),
		_r(float(a["min_soc"])), _r(float(a["morale"]) / maxf(float(a["n"]), 1.0)), int(a["people"])]


static func monthly_csv(y: Object) -> String:
	var m := monthly(y)
	var lines: Array = [",".join(m["cols"])]
	for r in (m["rows"] as Array):
		var cells: Array = []
		for v in (r as Array):
			cells.append(str(v))
		lines.append(",".join(cells))
	return "\n".join(lines) + "\n"


## One row per sim day, store columns named by design node id (the daily
## table the MCP server slices).
static func daily_csv(y: Object, ids: Dictionary) -> String:
	var did := _design_ids(y, ids)
	var tanks: Array = []
	for iid in y.acc:
		if (y.acc[iid] as Dictionary)["type"] == "tank":
			tanks.append(iid)
	var head: Array = ["day", "soc_pct", "solar_kwh", "load_kwh", "ac_off_h", "people", "morale"]
	for iid2 in tanks:
		head.append(str(did.get(iid2, iid2)))
	var rows: Array = [",".join(head)]
	for r: Dictionary in y.daily:
		var cells: Array = [str(r["day"]), str(_r(float(r["soc_pct"]))), str(_r(float(r["solar_kwh"]))),
			str(_r(float(r["load_kwh"]))), str(_r(float(r["ac_off_h"]))), str(int(r.get("people", 0))),
			str(_r(float(r.get("morale", 0.0))))]
		for iid3 in tanks:
			cells.append(str(_r(float((r["tanks"] as Dictionary).get(iid3, 0.0)))))
		rows.append(",".join(cells))
	return "\n".join(rows) + "\n"


## graph item id -> design node id (gh_3, or gh when there is one).
static func _design_ids(y: Object, ids: Dictionary) -> Dictionary:
	var out := {}
	for nid in ids.keys():
		var list: Array = ids[nid]
		for i in list.size():
			out[str(list[i])] = str(list[i]) if list.size() > 1 else str(nid)
	return out


static func _round_dict(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d.keys():
		out[str(k)] = _r(float(d[k]))
	return out


## 3 significant figures; an int when it is one.
static func _r(x: float) -> Variant:
	if is_nan(x) or is_inf(x):
		return 0
	if absf(x) < 1e-9:
		return 0
	var mag := floorf(log(absf(x)) / log(10.0))
	var step := pow(10.0, mag - 2.0)
	var v := snappedf(x, step)
	if absf(v - roundf(v)) < 1e-9 and absf(v) < 1e15:
		return int(roundf(v))
	return v
