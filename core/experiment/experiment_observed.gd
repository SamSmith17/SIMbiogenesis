class_name ExperimentObserved
extends RefCounted

## Turns real readings into an observed ExperimentSeries on the experiment's
## grid (pure; the network fetch is HaHistoryFetch, the CSV parse is
## CsvHistoryPlayer).
##
## A channel's readings are one or more STREAMS (one per Home Assistant entity
## — two inverters' load sensors, say), each a list of [t_unix, value] with the
## value already in the channel's unit (kW, or % for state of charge) and NAN
## for "unavailable". Each stream is held from one reading to the next
## (zero-order hold — HA records a sensor only when it changes, so silence
## means "unchanged"); before a stream's first reading it is unknown. A
## channel's sample is the SUM of its streams, unknown if any stream is.
## Times go through SiteTime, so the readings land on the hours the sim's sun
## and weather use.

## The channels an observed series can carry and their reading units.
const UNITS := {"soc_kwh": "%", "solar_kw": "kW", "load_kw": "kW", "aux_kw": "kW"}


## `streams_by_channel`: {channel: [stream, …]}, stream = Array of [t_unix, v].
static func build(streams_by_channel: Dictionary, clock: Object, start_abs: float,
		end_abs: float, step_h: float, capacity_kwh: float) -> ExperimentSeries:
	var s := ExperimentSeries.new()
	s.capacity_kwh = maxf(capacity_kwh, 1e-6)
	var n := maxi(int(ceil((end_abs - start_abs) / step_h - 1e-9)), 0)
	var chans: Array = []
	for ch in streams_by_channel:
		if UNITS.has(str(ch)) and not (streams_by_channel[ch] as Array).is_empty():
			chans.append(str(ch))
	s.setup(start_abs, step_h, n, chans)
	for ch in chans:
		var total := PackedFloat32Array()
		total.resize(n)
		total.fill(0.0)
		for stream in streams_by_channel[ch]:
			var held := _hold(stream as Array, clock, s, ch != "soc_kwh")
			for i in n:
				total[i] += held[i]   # NAN propagates: unknown if any stream is
		if ch == "soc_kwh":
			for i in n:
				total[i] = clampf(total[i], 0.0, 100.0) / 100.0 * s.capacity_kwh \
					if not is_nan(total[i]) else NAN
		s.data[ch] = total
	return s


## From a CSV clip's role samples ({role: [{t, v}]}, CsvHistoryPlayer
## .get_role_samples()). `values_in_watts` = the power columns are W.
static func from_csv_roles(role_samples: Dictionary, clock: Object, start_abs: float,
		end_abs: float, step_h: float, capacity_kwh: float,
		values_in_watts: bool) -> ExperimentSeries:
	var k := 0.001 if values_in_watts else 1.0
	var by_ch := {}
	for pair in [["battery_soc", "soc_kwh", 1.0], ["solar", "solar_kw", k], ["load", "load_kw", k]]:
		var rows: Array = role_samples.get(pair[0], []) as Array
		if rows.is_empty():
			continue
		var stream: Array = []
		for r in rows:
			stream.append([float((r as Dictionary).get("t", 0)), float((r as Dictionary).get("v", NAN)) * float(pair[2])])
		by_ch[pair[1]] = [stream]
	return build(by_ch, clock, start_abs, end_abs, step_h, capacity_kwh)


## The span a CSV clip's readings cover, on the site clock (Vector2(NAN) if none).
static func csv_span(role_samples: Dictionary, clock: Object) -> Vector2:
	var lo := INF
	var hi := -INF
	for role in role_samples:
		for r in role_samples[role]:
			var t := float((r as Dictionary).get("t", 0))
			lo = minf(lo, t)
			hi = maxf(hi, t)
	if is_inf(lo):
		return Vector2(NAN, NAN)
	return Vector2(SiteTime.unix_to_site_abs(clock, lo), SiteTime.unix_to_site_abs(clock, hi))


## One stream onto the series grid. A STATE (state of charge) is the reading
## held at the sample's start — the battery at t(i), as the sim records it. A
## FLOW (power) is the time-weighted mean of the held readings over the
## sample's interval, as the sim's inputs are; unknown when less than half
## the interval is known. NAN before the first reading.
static func _hold(stream: Array, clock: Object, s: ExperimentSeries,
		flow: bool) -> PackedFloat32Array:
	var n := s.size()
	var out := PackedFloat32Array()
	out.resize(n)
	out.fill(NAN)
	var pts: Array = []
	for p in stream:
		var a := p as Array
		if a.size() < 2:
			continue
		pts.append([SiteTime.unix_to_site_abs(clock, float(a[0])), float(a[1])])
	if pts.is_empty():
		return out
	pts.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	var m := pts.size()
	var ci := -1
	for i in n:
		var t0 := s.time_of(i)
		while ci + 1 < m and float(pts[ci + 1][0]) <= t0 + 1e-9:
			ci += 1
		if not flow:
			if ci >= 0:
				out[i] = float(pts[ci][1])
			continue
		var t1 := t0 + s.step_h
		var known := 0.0
		var acc := 0.0
		var k := ci
		var seg_a := t0
		while seg_a < t1 - 1e-12:
			var seg_b := t1
			if k + 1 < m:
				seg_b = minf(seg_b, float(pts[k + 1][0]))
			if k >= 0:
				var v := float(pts[k][1])
				if not is_nan(v):
					known += seg_b - seg_a
					acc += v * (seg_b - seg_a)
			seg_a = seg_b
			k += 1
		if known >= 0.5 * s.step_h:
			out[i] = acc / known
	return out
