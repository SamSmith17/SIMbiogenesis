class_name PatternData
extends RefCounted

## The numbers behind the pattern charts (plans/FLOW_VIZ_PLAN.md Part D):
## a day × hour grid for a carpet plot, an hourly series pair for a phase
## orbit and how it drifts day to day, and an energy budget as waterfall
## steps. Pure: the Patterns window, the Site Report and the selftest share it.
##
## Time is absolute sim hours (CelestialClock: hour 0 is local midnight), so a
## day starts at floor(t / 24) * 24.


## Mean of a regular series per hour of each day: `values` starts at `base_t`
## with one sample every `step` hours; the grid covers `days` days from the
## midnight `day0_t`, row-major by day (index = day * 24 + hour). NAN where no
## sample falls in the hour.
static func hour_grid(values: PackedFloat32Array, base_t: float, step: float,
		day0_t: float, days: int) -> PackedFloat32Array:
	var n := maxi(days, 0) * 24
	var out := PackedFloat32Array()
	out.resize(n)
	if n == 0:
		return out
	var sums := PackedFloat64Array()
	sums.resize(n)
	var cnt := PackedInt32Array()
	cnt.resize(n)
	for i in values.size():
		var t := base_t + float(i) * step
		var cell := int(floor(t - day0_t + 1e-9))
		if cell < 0 or cell >= n:
			continue
		sums[cell] += float(values[i])
		cnt[cell] += 1
	for c in n:
		out[c] = float(sums[c] / float(cnt[c])) if cnt[c] > 0 else NAN
	return out


## A function of time sampled at each hour's middle over [t0, t1).
static func hourly(fn: Callable, t0: float, t1: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var t := floorf(t0) + 0.5
	while t < t1:
		out.append(float(fn.call(t)))
		t += 1.0
	return out


## The lowest and highest finite values (NAN when there are none).
static func finite_range(v: PackedFloat32Array) -> Vector2:
	var lo := INF
	var hi := -INF
	for x in v:
		if is_nan(x) or is_inf(x):
			continue
		lo = minf(lo, x)
		hi = maxf(hi, x)
	if lo > hi:
		return Vector2(NAN, NAN)
	return Vector2(lo, hi)


## How an orbit moves from one day to the next: the change at the same hour a
## day apart, averaged (per day). A system in a steady daily rhythm returns
## to the same point (drift near 0); one running down spirals out.
static func orbit_drift(xs: PackedFloat32Array, ys: PackedFloat32Array) -> Vector2:
	var n := mini(xs.size(), ys.size())
	if n <= 24:
		return Vector2.ZERO
	var dx := 0.0
	var dy := 0.0
	var k := 0
	for i in range(0, n - 24):
		if is_nan(xs[i]) or is_nan(xs[i + 24]) or is_nan(ys[i]) or is_nan(ys[i + 24]):
			continue
		dx += float(xs[i + 24]) - float(xs[i])
		dy += float(ys[i + 24]) - float(ys[i])
		k += 1
	if k == 0:
		return Vector2.ZERO
	return Vector2(dx / float(k), dy / float(k))


## A day-to-day drift in words, against each axis's span: "a steady daily
## cycle", "running down", "filling up".
static func drift_words(drift: Vector2, span: Vector2, x_name: String, y_name: String) -> String:
	var parts: Array = []
	for pair in [[drift.x, span.x, x_name], [drift.y, span.y, y_name]]:
		var d := float(pair[0])
		var s := maxf(float(pair[1]), 1e-9)
		if absf(d) < 0.02 * s:
			continue
		parts.append("%s %s" % [str(pair[2]), "falls a little each day" if d < 0.0 else "rises a little each day"]
			if absf(d) < 0.08 * s else "%s %s" % [str(pair[2]), "runs down day by day" if d < 0.0 else "climbs day by day"])
	if parts.is_empty():
		return "A steady daily cycle: each day comes back round to where it started."
	var txt := ", ".join(parts)
	return txt.substr(0, 1).to_upper() + txt.substr(1) + "."


## An energy budget (EnergyRunSankey flows) as waterfall steps, in kWh:
## the sun on offer, less what was not used, plus wind and hydro and the
## charge the battery started with, less the battery's losses and the charge
## kept, ending at what did work. Steps: {label, value, kind start|add|sub|total}.
static func energy_waterfall(f: Dictionary) -> Array:
	if f.is_empty():
		return []
	var steps: Array = [{"label": "Sun on offer", "value": float(f.get("potential", 0.0)), "kind": "start"}]
	var add := func(label: String, v: float, kind: String) -> void:
		if v >= 1e-4:
			steps.append({"label": label, "value": v, "kind": kind})
	add.call("Not used", float(f.get("not_used", 0.0)), "sub")
	add.call("Wind & hydro", float(f.get("aux", 0.0)), "add")
	add.call("Charge it started with", float(f.get("from_store", 0.0)), "add")
	add.call("Battery losses", float(f.get("batt_loss", 0.0)), "sub")
	add.call("Kept in the battery", float(f.get("kept", 0.0)), "sub")
	steps.append({"label": "Did work", "value": float(f.get("load", 0.0)), "kind": "total"})
	return steps


## Where each step's bar runs: [{from, to}] along the value axis, the running
## total carried from step to step.
static func waterfall_spans(steps: Array) -> Array:
	var out: Array = []
	var run := 0.0
	for s in steps:
		var v := float(s.get("value", 0.0))
		match str(s.get("kind", "add")):
			"start":
				run = v
				out.append({"from": 0.0, "to": v})
			"total":
				out.append({"from": 0.0, "to": v})
				run = v
			"sub":
				out.append({"from": run - v, "to": run})
				run -= v
			_:
				out.append({"from": run, "to": run + v})
				run += v
	return out
