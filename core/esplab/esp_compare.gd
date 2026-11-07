class_name EspCompare
extends RefCounted

## The real board against its twin, pure.
##
##   match_entities(design, catalog)   which Home Assistant entity is the real
##                                     one for each of the twin's: the id the
##                                     naming contract predicts, else the one
##                                     catalog entity in the same domain whose
##                                     id ends with the entity's own slug and
##                                     whose unit agrees
##   parse_history(rows, clock)        HA history rows -> [[site abs h, value]]
##                                     (numbers; on / off as 1 / 0; unknown /
##                                     unavailable as gaps)
##   stats(real, twin, t0, t1, step)   both held on one grid: n, coverage,
##                                     bias (real - twin), MAE, RMSE, r, and
##                                     the line real = a·twin + b
##   verdict(st, ent)                  good / fair / poor against the part's
##                                     own datasheet accuracy
##   calibration(st, mode)             the ESPHome filter that makes the real
##                                     board read like the twin: `offset`
##                                     (-bias) or `calibrate_linear` (the
##                                     inverse line over the range seen),
##                                     marked `cal` (the twin skips it)
##
## The twin side is the IDEAL reading (EspSim ideal: no invented per-unit
## bias or noise), so the difference is the real sensor's error plus how far
## the spot's weather is from the weather data.

const MIN_POINTS := 6


## {twin entity_id: real entity_id} for the design's own entities (not the
## board's diagnostics). `catalog` = HomeAssistantService.catalog() rows.
static func match_entities(design: Dictionary, catalog: Array, prior: Dictionary = {}) -> Dictionary:
	var by_id := {}
	for row in catalog:
		by_id[str(row.get("entity_id", ""))] = row
	var out := {}
	for e in design.get("entities", []):
		if str(e.get("iid", "")) == "":
			continue
		var eid := str(e["entity_id"])
		var kept := str(prior.get(eid, ""))
		if kept != "" and by_id.has(kept):
			out[eid] = kept
			continue
		if by_id.has(eid):
			out[eid] = eid
			continue
		var tail := "_" + EspEntityNames.ha_slug(str(e["name"]))
		var dom := str(e["kind"])
		var hits: Array = []
		for row in catalog:
			var rid := str(row.get("entity_id", ""))
			if not rid.begins_with(dom + ".") or not rid.ends_with(tail):
				continue
			var ru := str(row.get("unit", ""))
			if dom == "sensor" and ru != "" and str(e.get("unit", "")) != "" and not units_agree(ru, str(e["unit"])):
				continue
			hits.append(rid)
		if hits.size() == 1:
			out[eid] = hits[0]
	return out


static func units_agree(a: String, b: String) -> bool:
	if a == b:
		return true
	var fa := HaUnits.family_of(a)
	return fa != "" and fa == HaUnits.family_of(b)


## A Home Assistant state string as a number (NAN = no reading).
static func state_value(s: String) -> float:
	var t := s.strip_edges().to_lower()
	match t:
		"on", "true", "detected", "open", "home", "wet":
			return 1.0
		"off", "false", "clear", "closed", "not_home", "dry":
			return 0.0
		"", "unknown", "unavailable", "none", "nan":
			return NAN
	return float(t) if t.is_valid_float() else NAN


## HA history rows (minimal_response {s, lu} or full {state, last_updated})
## -> [[site abs hours, value]] sorted, gaps as NAN.
static func parse_history(rows: Array, clock: Object) -> Array:
	var out: Array = []
	for r in rows:
		if not (r is Dictionary):
			continue
		var d := r as Dictionary
		var s := str(d.get("s", d.get("state", "")))
		var tu := NAN
		for k in ["lu", "lc", "last_updated", "last_changed"]:
			if d.has(k):
				var v: Variant = d[k]
				tu = float(v) if (v is float or v is int) else HaObservedStore.iso_to_unix(str(v))
				break
		if is_nan(tu):
			continue
		out.append([SiteTime.unix_to_site_abs(clock, tu), state_value(s)])
	out.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	return out


## The twin's series (EspSim.series rows, values float / bool / NAN) as
## numbers.
static func numeric(series: Array) -> Array:
	var out: Array = []
	for r in series:
		var v: Variant = r[1]
		var x := NAN
		if v is bool:
			x = 1.0 if v else 0.0
		elif v is float or v is int:
			x = float(v)
		out.append([float(r[0]), x])
	return out


## The last value at or before t (NAN before the first or in a gap).
static func held_at(series: Array, t: float) -> float:
	var lo := 0
	var hi := series.size() - 1
	if hi < 0 or float(series[0][0]) > t:
		return NAN
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if float(series[mid][0]) <= t:
			lo = mid
		else:
			hi = mid - 1
	return float(series[lo][1])


static func stats(real: Array, twin: Array, t0: float, t1: float, step_h: float) -> Dictionary:
	var n := 0
	var total := 0
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	var sad := 0.0
	var lo := INF
	var hi := -INF
	var t := t0
	while t <= t1 + 1e-9:
		total += 1
		var y := held_at(real, t)
		var x := held_at(twin, t)
		if not is_nan(x) and not is_nan(y):
			n += 1
			sx += x
			sy += y
			sxx += x * x
			syy += y * y
			sxy += x * y
			sad += absf(y - x)
			lo = minf(lo, x)
			hi = maxf(hi, x)
		t += step_h
	var out := {"n": n, "coverage": float(n) / float(maxi(total, 1)), "bias": NAN, "mae": NAN,
		"rmse": NAN, "r": NAN, "a": NAN, "b": NAN, "twin_lo": lo, "twin_hi": hi}
	if n < MIN_POINTS:
		return out
	var fn := float(n)
	var mx := sx / fn
	var my := sy / fn
	out["bias"] = my - mx
	out["mae"] = sad / fn
	var sse := syy - 2.0 * sxy + sxx
	out["rmse"] = sqrt(maxf(0.0, sse / fn))
	var vx := sxx / fn - mx * mx
	var vy := syy / fn - my * my
	var cov := sxy / fn - mx * my
	if vx > 1e-12 and vy > 1e-12:
		out["r"] = cov / sqrt(vx * vy)
	if vx > 1e-12:
		out["a"] = cov / vx
		out["b"] = my - float(out["a"]) * mx
	return out


## How the real board does against the part's own accuracy at the twin's
## mean value: good within it, fair within twice it, else poor.
static func verdict(st: Dictionary, ent: Dictionary) -> String:
	if int(st.get("n", 0)) < MIN_POINTS or is_nan(float(st.get("bias", NAN))):
		return "no data"
	var sim: Dictionary = ent.get("sim", {})
	var mid := (float(st["twin_lo"]) + float(st["twin_hi"])) * 0.5
	var acc := float(sim.get("acc", 0.0)) + float(sim.get("acc_pct", 0.0)) * 0.01 * absf(mid) + float(sim.get("res", 0.0))
	if acc <= 0.0:
		acc = maxf(0.5, absf(mid) * 0.05)
	var err := maxf(absf(float(st["bias"])), float(st.get("mae", 0.0)) * 0.8)
	if err <= acc:
		return "good"
	if err <= 2.0 * acc:
		return "fair"
	return "poor"


## The filter that makes the real board read like the twin.
##   "offset": {offset: -bias}
##   "linear": calibrate_linear through the inverse of real = a·twin + b at
##             the ends of the range seen (needs r and a sane slope)
static func calibration(st: Dictionary, mode: String = "offset") -> Dictionary:
	if is_nan(float(st.get("bias", NAN))):
		return {}
	if mode == "linear":
		var a := float(st.get("a", NAN))
		var b := float(st.get("b", NAN))
		var lo := float(st.get("twin_lo", NAN))
		var hi := float(st.get("twin_hi", NAN))
		if is_nan(a) or absf(a) < 0.2 or absf(a) > 5.0 or not (hi > lo):
			return {}
		# Real readings at the twin's lo / hi map back onto lo / hi.
		return {"calibrate_linear": [[snappedf(a * lo + b, 0.001), snappedf(lo, 0.001)],
			[snappedf(a * hi + b, 0.001), snappedf(hi, 0.001)]], "cal": true}
	return {"offset": snappedf(-float(st["bias"]), 0.01), "cal": true}


## A spec with a calibration filter set on one entity (replacing an earlier
## calibration on it; the player's other filters kept).
static func with_calibration(spec: Dictionary, iid: String, k: String, filt: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	for p in s.get("parts", []):
		if str(p.get("iid", "")) != iid:
			continue
		var fl: Dictionary = p.get("filters", {})
		var keep: Array = []
		for f in fl.get(k, []):
			if not bool((f as Dictionary).get("cal", false)):
				keep.append(f)
		if not filt.is_empty():
			keep.append(filt)
		fl[k] = keep
		p["filters"] = fl
	return s
