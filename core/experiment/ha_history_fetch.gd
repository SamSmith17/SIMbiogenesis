class_name HaHistoryFetch
extends Node

## Fetches what really happened from Home Assistant for an experiment's span
## and hands back an observed ExperimentSeries.
##
## Which sensors: the world's live links (HAEntityLinker), the same ones that
## drive the sim in Live mode —
##   battery  site.battery_soc, else the first battery node's soc link
##   solar    site.solar_kw, else the sum of the panel nodes' power links
##   load     site.load_kw, else the sum of the inverters' AC output links
##   aux      the sum of the wind / hydro nodes' power links
## Units come from each sensor's unit_of_measurement (HaUnits), then the link's
## own scale / offset / invert, exactly as a live reading is converted.
##
## How far back: the recorder's raw history first (every change). Where it
## starts later than the span (HA purges raw history after 10 days by
## default), the hourly long-term statistics fill the start, and the channel
## says so. Nothing is cached; every run asks again.

signal finished(series: ExperimentSeries, report: Dictionary)

const TIMEOUT_S := 45.0
## A channel whose raw history starts this much after the span start gets the
## hourly statistics for the gap.
const STATS_GAP_H := 1.0

var _svc: Node = null
var _clock: Object = null
var _start := 0.0
var _end := 0.0
var _step := 1.0 / 60.0
var _cap := 16.0
var _sources: Dictionary = {}     # channel -> [source]
var _rows: Dictionary = {}        # entity id -> [[t_unix, raw string]]
var _stats: Dictionary = {}       # entity id -> [[t_unix, mean]]
var _waiting := 0
var _elapsed := 0.0
var _done := true
var _report: Dictionary = {}


## Which links feed which channel: {channel: [{entity_id, target_id, unit,
## scale, offset, invert, factor}]} (factor turns the target's unit into the
## channel's), plus {"_missing": {channel: why}}. Pure over the linker's API.
static func sources_for(linker: Object) -> Dictionary:
	var out := {"soc_kwh": [], "solar_kw": [], "load_kw": [], "aux_kw": [], "_missing": {}}
	if linker == null or not linker.has_method("links"):
		(out["_missing"] as Dictionary)["all"] = "No Home Assistant links in this world."
		return out
	var site := {}
	var items := {"soc": [], "panel": [], "controller": [], "aux": []}
	for l_v in linker.call("links"):
		var l: Dictionary = l_v
		if not bool(l.get("enabled", true)):
			continue
		var tid := str(l.get("target_id", ""))
		var t: Dictionary = linker.call("target", tid)
		if t.is_empty():
			continue
		var src := {"entity_id": str(l.get("entity_id", "")), "target_id": tid,
			"unit": str(t.get("unit", "")), "scale": float(l.get("scale", 1.0)),
			"offset": float(l.get("offset", 0.0)), "invert": bool(l.get("invert", false)),
			"factor": 0.001 if str(t.get("unit", "")) == "W" else 1.0}
		if tid.begins_with("site."):
			site[tid] = src
			continue
		var it := str(t.get("item_type", ""))
		var f := str(t.get("field", ""))
		if it in ["battery", "smartbattery"] and f == "soc":
			items["soc"].append(src)
		elif it == "panel" and f == "power":
			items["panel"].append(src)
		elif it == "controller" and f == "ac_power":
			items["controller"].append(src)
		elif it in ["wind", "hydro"] and f == "power":
			items["aux"].append(src)
	if site.has("site.battery_soc"):
		out["soc_kwh"] = [site["site.battery_soc"]]
	elif not items["soc"].is_empty():
		out["soc_kwh"] = [items["soc"][0]]   # one battery's SOC; never a sum
	if site.has("site.solar_kw"):
		out["solar_kw"] = [site["site.solar_kw"]]
	else:
		out["solar_kw"] = items["panel"]
	if site.has("site.load_kw"):
		out["load_kw"] = [site["site.load_kw"]]
	else:
		out["load_kw"] = items["controller"]
	out["aux_kw"] = items["aux"]
	var miss: Dictionary = out["_missing"]
	if (out["soc_kwh"] as Array).is_empty():
		miss["soc_kwh"] = "No sensor linked to the battery's state of charge."
	if (out["solar_kw"] as Array).is_empty():
		miss["solar_kw"] = "No sensor linked to solar production."
	if (out["load_kw"] as Array).is_empty():
		miss["load_kw"] = "No sensor linked to power use."
	return out


## Start fetching. `svc` = the HomeAssistant autoload, `linker` the world's
## HAEntityLinker, `clock` Main's CelestialClock.
func start(svc: Node, linker: Object, clock: Object, start_abs: float, end_abs: float,
		step_h: float, cap_kwh: float) -> void:
	_svc = svc
	_clock = clock
	_start = start_abs
	_end = end_abs
	_step = step_h
	_cap = cap_kwh
	_rows.clear()
	_stats.clear()
	_sources = sources_for(linker)
	_report = {"channels": {}, "missing": _sources.get("_missing", {}), "error": ""}
	_elapsed = 0.0
	_done = false
	if _svc == null or not bool(_svc.call("is_authed")):
		_report["error"] = "Home Assistant is not connected. Connect it in Settings → Home Assistant."
		_finish()
		return
	var eids := {}
	for ch in ["soc_kwh", "solar_kw", "load_kw", "aux_kw"]:
		for src in _sources[ch]:
			eids[str(src["entity_id"])] = true
	if eids.is_empty():
		_report["error"] = "This world has no Home Assistant sensors linked to its battery, solar or loads. Link them in Live links."
		_finish()
		return
	var t0 := SiteTime.site_abs_to_unix(_clock, _start)
	var t1 := SiteTime.site_abs_to_unix(_clock, _end)
	_waiting = eids.size()
	for eid in eids:
		_svc.call("request_history", eid, t0, t1, _on_history.bind(eid))
	set_process(true)


func is_running() -> bool:
	return not _done


func cancel() -> void:
	_done = true
	set_process(false)


func _process(delta: float) -> void:
	if _done:
		set_process(false)
		return
	_elapsed += delta
	if _elapsed > TIMEOUT_S:
		_report["error"] = "Home Assistant did not answer within %d s; showing what arrived." % int(TIMEOUT_S)
		_finish()


func _on_history(rows: Array, eid: String) -> void:
	if _done:
		return
	var pts: Array = []
	for r in rows:
		if not (r is Dictionary):
			continue
		var tu := HaObservedStore.row_unix(r)
		if is_nan(tu):
			continue
		pts.append([tu, str((r as Dictionary).get("s", (r as Dictionary).get("state", "")))])
	_rows[eid] = pts
	var t0 := SiteTime.site_abs_to_unix(_clock, _start)
	var first := INF
	for p in pts:
		first = minf(first, float(p[0]))
	if first > t0 + STATS_GAP_H * 3600.0:
		# Raw history starts late (purged): ask the hourly statistics for the gap.
		var to := first if not is_inf(first) else SiteTime.site_abs_to_unix(_clock, _end)
		_svc.call("request_statistics", eid, t0, to, _on_stats.bind(eid))
		return
	_one_done()


func _on_stats(rows: Array, eid: String) -> void:
	if _done:
		return
	var pts: Array = []
	for r in rows:
		if not (r is Dictionary):
			continue
		var d: Dictionary = r
		var mean: Variant = d.get("mean", null)
		if mean == null:
			continue
		var st: Variant = d.get("start", null)
		var tu := NAN
		if st is float or st is int:
			tu = float(st) / 1000.0 if float(st) > 1e11 else float(st)
		elif st is String:
			tu = HaObservedStore.row_unix({"last_changed": st})
		if not is_nan(tu):
			pts.append([tu, float(mean)])
	_stats[eid] = pts
	_one_done()


func _one_done() -> void:
	_waiting -= 1
	if _waiting <= 0:
		_finish()


func _finish() -> void:
	_done = true
	set_process(false)
	var by_ch := {}
	var chans: Dictionary = _report["channels"]
	for ch in ["soc_kwh", "solar_kw", "load_kw", "aux_kw"]:
		var streams: Array = []
		var names: Array = []
		var readings := 0
		var hourly := false
		for src in _sources.get(ch, []):
			var eid := str(src["entity_id"])
			var unit := ""
			if _svc != null and _svc.has_method("catalog_entry"):
				unit = str((_svc.call("catalog_entry", eid) as Dictionary).get("unit", ""))
			var stream: Array = []
			for p in _stats.get(eid, []):
				stream.append([float(p[0]), _convert(str(p[1]), unit, src)])
				hourly = true
			for p in _rows.get(eid, []):
				stream.append([float(p[0]), _convert(str(p[1]), unit, src)])
			readings += stream.size()
			names.append(eid)
			if not stream.is_empty():
				streams.append(stream)
		if not streams.is_empty() and streams.size() == (_sources.get(ch, []) as Array).size():
			by_ch[ch] = streams
		chans[ch] = {"entities": names, "readings": readings, "hourly": hourly,
			"complete": not streams.is_empty() and streams.size() == names.size()}
	var series := ExperimentObserved.build(by_ch, _clock, _start, _end, _step, _cap)
	series.label = "Observed (Home Assistant)"
	for ch in chans:
		var c: Dictionary = chans[ch]
		c["coverage"] = series.coverage(ch) if series.has(ch) else 0.0
		if bool(c["hourly"]):
			series.notes[ch] = "partly hourly statistics (raw history purged)"
	finished.emit(series, _report)


## A raw reading in the channel's unit (NAN when unavailable or unconvertible).
static func _convert(raw: String, from_unit: String, src: Dictionary) -> float:
	var c := HaUnits.convert(raw, from_unit, str(src.get("unit", "")))
	if not bool(c.get("ok", false)):
		return NAN
	var v := HaUnits.adjust(float(c["value"]), float(src.get("scale", 1.0)),
		float(src.get("offset", 0.0)), bool(src.get("invert", false)))
	return v * float(src.get("factor", 1.0))
