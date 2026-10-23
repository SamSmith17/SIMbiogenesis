class_name ExperimentScore
extends RefCounted

## Scores for an experiment's timelines (pure, over ExperimentSeries).
##
## energy(): what one timeline did — the SiteProjection accounting (made,
## used, unserved, hours with AC off, SOC low / end) plus curtailment and
## battery throughput.
##
## calibration(): how well a simulated timeline matches an observed one over
## the same grid. Per channel: mean absolute error, bias, RMSE, correlation,
## and the two ASHRAE Guideline 14-2014 calibration statistics on HOURLY
## means — NMBE and CV(RMSE). Guideline 14 calls an hourly-calibrated
## simulation |NMBE| ≤ 10 % and CV(RMSE) ≤ 30 %; this uses p = 1 in the
## (n − p) denominators. SOC is judged in percentage points instead (a state,
## not an energy flow): mean absolute error ≤ 5 points good, ≤ 12 fair.

const POWER_CHANNELS := ["solar_kw", "load_kw", "aux_kw", "net_kw"]
const G14_NMBE_PCT := 10.0
const G14_CVRMSE_PCT := 30.0
const SOC_GOOD_PTS := 5.0
const SOC_FAIR_PTS := 12.0


static func energy(s: ExperimentSeries) -> Dictionary:
	var out := {
		"solar_kwh": 0.0, "raw_kwh": 0.0, "curtailed_kwh": 0.0, "aux_kwh": 0.0,
		"demand_kwh": 0.0, "served_kwh": 0.0, "unserved_kwh": 0.0, "ac_off_h": 0.0,
		"soc_start_pct": NAN, "soc_end_pct": NAN, "soc_min_pct": NAN,
		"throughput_kwh": 0.0, "cycles": 0.0, "days": [],
	}
	var n := s.size()
	if n == 0:
		return out
	var dt := s.step_h
	var cap := maxf(s.capacity_kwh, 1e-6)
	var prev_soc := NAN
	var lo := INF
	var day: Dictionary = {}
	for i in n:
		var solar := _z(s.value("solar_kw", i))
		var raw := maxf(_z(s.value("raw_kw", i)), solar)
		var aux := _z(s.value("aux_kw", i))
		var load := _z(s.value("load_kw", i))
		var demand := s.value("demand_kw", i)
		demand = load if is_nan(demand) else maxf(demand, load)
		var ac := s.value("ac", i)
		out["solar_kwh"] = float(out["solar_kwh"]) + solar * dt
		out["raw_kwh"] = float(out["raw_kwh"]) + raw * dt
		out["aux_kwh"] = float(out["aux_kwh"]) + aux * dt
		out["served_kwh"] = float(out["served_kwh"]) + load * dt
		out["demand_kwh"] = float(out["demand_kwh"]) + demand * dt
		out["unserved_kwh"] = float(out["unserved_kwh"]) + (demand - load) * dt
		if not is_nan(ac) and ac < 0.5:
			out["ac_off_h"] = float(out["ac_off_h"]) + dt
		var soc := s.value("soc_kwh", i)
		if not is_nan(soc):
			if is_nan(float(out["soc_start_pct"])):
				out["soc_start_pct"] = 100.0 * soc / cap
			out["soc_end_pct"] = 100.0 * soc / cap
			lo = minf(lo, soc)
			if not is_nan(prev_soc):
				out["throughput_kwh"] = float(out["throughput_kwh"]) + absf(soc - prev_soc)
			prev_soc = soc
		var di := int(floor((s.time_of(i) - SiteTime.day_start(s.start_abs)) / 24.0))
		if day.is_empty() or int(day["i"]) != di:
			if not day.is_empty():
				(out["days"] as Array).append(day)
			day = {"i": di, "start_abs": SiteTime.day_start(s.start_abs) + 24.0 * di,
				"solar_kwh": 0.0, "aux_kwh": 0.0, "served_kwh": 0.0, "demand_kwh": 0.0,
				"ac_off_h": 0.0, "soc_end_pct": NAN}
		day["solar_kwh"] = float(day["solar_kwh"]) + solar * dt
		day["aux_kwh"] = float(day["aux_kwh"]) + aux * dt
		day["served_kwh"] = float(day["served_kwh"]) + load * dt
		day["demand_kwh"] = float(day["demand_kwh"]) + demand * dt
		if not is_nan(ac) and ac < 0.5:
			day["ac_off_h"] = float(day["ac_off_h"]) + dt
		if not is_nan(soc):
			day["soc_end_pct"] = 100.0 * soc / cap
	if not day.is_empty():
		(out["days"] as Array).append(day)
	out["curtailed_kwh"] = maxf(float(out["raw_kwh"]) - float(out["solar_kwh"]), 0.0)
	out["soc_min_pct"] = NAN if is_inf(lo) else 100.0 * lo / cap
	# Equivalent full cycles: half the absolute SOC travel over the capacity.
	out["cycles"] = float(out["throughput_kwh"]) * 0.5 / cap
	return out


## Sim vs observed. Both series must share start and step (the experiment
## builds the sim on the observed grid). Channels either side lacks are left
## out. Returns {channels: {ch: stats}, days: [...], overall}.
static func calibration(obs: ExperimentSeries, sim: ExperimentSeries) -> Dictionary:
	var out := {"channels": {}, "days": [], "overall": ""}
	if obs == null or sim == null or obs.size() == 0:
		return out
	var n := mini(obs.size(), sim.size())
	var chs: Dictionary = out["channels"]
	for ch in ["soc_pct"] + POWER_CHANNELS:
		if not (obs.has(ch) and sim.has(ch)):
			continue
		var st := _stats(obs.values(ch), sim.values(ch), n)
		if int(st["n"]) == 0:
			continue
		if ch != "soc_pct":
			var h := _hourly(obs, sim, ch, n)
			st.merge(_g14(h[0], h[1]), true)
			st["obs_kwh"] = obs.integrate(ch, -INF, obs.time_of(n))
			st["sim_kwh"] = sim.integrate(ch, -INF, sim.time_of(n))
			var ok := float(st["obs_kwh"])
			st["kwh_err_pct"] = NAN if absf(ok) < 1e-6 else 100.0 * (float(st["sim_kwh"]) - ok) / absf(ok)
		st["verdict"] = verdict(ch, st)
		chs[ch] = st
	# Per-day rollup on the observed grid.
	var d0 := SiteTime.day_start(obs.start_abs)
	var t_end := obs.time_of(n)
	var day_t := d0
	while day_t < t_end - 1e-9:
		var a := maxf(day_t, obs.start_abs)
		var b := minf(day_t + 24.0, t_end)
		var row := {"start_abs": day_t, "hours": b - a}
		for ch in ["solar_kw", "load_kw", "aux_kw"]:
			if obs.has(ch):
				row["obs_" + ch] = obs.integrate(ch, a, b)
				row["obs_cov_" + ch] = obs.coverage(ch, a, b)
			if sim.has(ch):
				row["sim_" + ch] = sim.integrate(ch, a, b)
		var ib := mini(obs.index_of(b) - 1, n - 1)
		if ib >= 0:
			row["obs_soc_end_pct"] = obs.value("soc_pct", ib)
			row["sim_soc_end_pct"] = sim.value("soc_pct", ib)
		(out["days"] as Array).append(row)
		day_t += 24.0
	out["overall"] = overall(chs)
	return out


## "good" / "fair" / "poor" for one channel's stats.
static func verdict(ch: String, st: Dictionary) -> String:
	if ch == "soc_pct":
		var mae := float(st.get("mae", INF))
		return "good" if mae <= SOC_GOOD_PTS else ("fair" if mae <= SOC_FAIR_PTS else "poor")
	var nmbe := absf(float(st.get("nmbe_pct", INF)))
	var cv := float(st.get("cvrmse_pct", INF))
	if is_nan(nmbe) or is_nan(cv):
		return "n/a"
	if nmbe <= G14_NMBE_PCT and cv <= G14_CVRMSE_PCT:
		return "good"
	if nmbe <= 2.0 * G14_NMBE_PCT and cv <= 2.0 * G14_CVRMSE_PCT:
		return "fair"
	return "poor"


## The worst verdict over the primary channels (SOC, solar, load).
static func overall(chs: Dictionary) -> String:
	var rank := {"good": 0, "fair": 1, "poor": 2}
	var worst := -1
	for ch in ["soc_pct", "solar_kw", "load_kw"]:
		if chs.has(ch):
			var v := str((chs[ch] as Dictionary).get("verdict", ""))
			if rank.has(v):
				worst = maxi(worst, int(rank[v]))
	return "" if worst < 0 else ["good", "fair", "poor"][worst]


# --- internals ----------------------------------------------------------------

static func _z(v: float) -> float:
	return 0.0 if is_nan(v) else v


## Sample-level stats over the samples both sides know.
static func _stats(o: PackedFloat32Array, s: PackedFloat32Array, n: int) -> Dictionary:
	var k := 0
	var sum_abs := 0.0
	var sum_d := 0.0
	var sum_d2 := 0.0
	var so := 0.0
	var ss := 0.0
	var soo := 0.0
	var sss := 0.0
	var sos := 0.0
	for i in n:
		var a := o[i]
		var b := s[i]
		if is_nan(a) or is_nan(b):
			continue
		var d := b - a
		k += 1
		sum_abs += absf(d)
		sum_d += d
		sum_d2 += d * d
		so += a
		ss += b
		soo += a * a
		sss += b * b
		sos += a * b
	if k == 0:
		return {"n": 0}
	var kf := float(k)
	var cov := sos / kf - (so / kf) * (ss / kf)
	var vo := soo / kf - (so / kf) * (so / kf)
	var vs := sss / kf - (ss / kf) * (ss / kf)
	var r := NAN
	if vo > 1e-12 and vs > 1e-12:
		r = clampf(cov / sqrt(vo * vs), -1.0, 1.0)
	return {"n": k, "mae": sum_abs / kf, "bias": sum_d / kf, "rmse": sqrt(sum_d2 / kf),
		"obs_mean": so / kf, "sim_mean": ss / kf, "r": r}


## Hourly means of a channel where the observed hour is at least half known.
static func _hourly(obs: ExperimentSeries, sim: ExperimentSeries, ch: String, n: int) -> Array:
	var ho := PackedFloat32Array()
	var hs := PackedFloat32Array()
	var per := maxi(int(round(1.0 / obs.step_h)), 1)
	var ov := obs.values(ch)
	var sv := sim.values(ch)
	var i := 0
	while i < n:
		var j := mini(i + per, n)
		var a := 0.0
		var b := 0.0
		var k := 0
		for q in range(i, j):
			if is_nan(ov[q]) or is_nan(sv[q]):
				continue
			a += ov[q]
			b += sv[q]
			k += 1
		if k * 2 >= (j - i):
			ho.append(a / float(k))
			hs.append(b / float(k))
		i = j
	return [ho, hs]


## ASHRAE Guideline 14 statistics (measured y, simulated ŷ, p = 1):
## NMBE = Σ(y − ŷ) / ((n − p) · ȳ), CV(RMSE) = √(Σ(y − ŷ)² / (n − p)) / ȳ.
static func _g14(y: PackedFloat32Array, yh: PackedFloat32Array) -> Dictionary:
	var n := y.size()
	if n < 2:
		return {"hours": n, "nmbe_pct": NAN, "cvrmse_pct": NAN}
	var mean := 0.0
	for v in y:
		mean += v
	mean /= float(n)
	if absf(mean) < 1e-6:
		return {"hours": n, "nmbe_pct": NAN, "cvrmse_pct": NAN}
	var sd := 0.0
	var sd2 := 0.0
	for i in n:
		var d := y[i] - yh[i]
		sd += d
		sd2 += d * d
	var dof := float(n - 1)
	return {"hours": n, "nmbe_pct": 100.0 * sd / (dof * absf(mean)),
		"cvrmse_pct": 100.0 * sqrt(sd2 / dof) / absf(mean)}
