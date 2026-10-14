class_name SiteProjection
extends RefCounted

## Forward look at the site's battery: step the SAME battery model SolarUI
## integrates (EnergyTimeline.step_soc, its charge/discharge efficiencies and
## floor) hour by hour over the next `hours`, with solar from a time-pure
## evaluator (SolarUI.evaluate_solar_at — real sun + the weather archive /
## forecast at each instant), hydro / other DC held at today's rate, and the
## loads' DEMAND. It also mirrors SolarUI's low-SOC protection: AC is shed at
## `floor_pct` and comes back at `resume_pct`, so the "AC off" hours are the
## hours the site would actually be dark.
##
## Pure: `inputs_at` is a Callable(abs_h) -> {solar_kw, aux_kw, load_kw}, so
## the selftest drives it with fixtures. Not a challenge bake — it never
## touches the clock, the timeline or any tank.

static func project(start_abs_h: float, hours: float, step_h: float,
		inputs_at: Callable, cap_kwh: float, soc_kwh: float,
		ceff: float = 0.95, deff: float = 0.95,
		floor_pct: float = 10.0, resume_pct: float = 20.0) -> Dictionary:
	var out := {
		"hours": hours, "soc_start": soc_kwh, "soc_end": soc_kwh,
		"soc_min": soc_kwh, "soc_max": soc_kwh, "soc_min_h": 0.0,
		"solar_kwh": 0.0, "aux_kwh": 0.0, "demand_kwh": 0.0,
		"served_kwh": 0.0, "unserved_kwh": 0.0,
		"ac_off_h": 0.0, "first_ac_off_h": INF, "full_h": 0.0,
		"days": [],
	}
	if cap_kwh <= 0.0 or hours <= 0.0 or step_h <= 0.0 or not inputs_at.is_valid():
		return out
	var floor_kwh := cap_kwh * clampf(floor_pct, 0.0, 100.0) / 100.0
	var resume_kwh := cap_kwh * clampf(resume_pct, floor_pct, 100.0) / 100.0
	var soc := clampf(soc_kwh, 0.0, cap_kwh)
	var ac_on := soc > floor_kwh + 1e-6
	var day: Dictionary = {}
	var t := 0.0
	while t < hours - 1e-9:
		var dt := minf(step_h, hours - t)
		var inp: Dictionary = inputs_at.call(start_abs_h + t + dt * 0.5)
		var solar := maxf(float(inp.get("solar_kw", 0.0)), 0.0)
		var aux := maxf(float(inp.get("aux_kw", 0.0)), 0.0)
		var demand := maxf(float(inp.get("load_kw", 0.0)), 0.0)
		var load := demand if ac_on else 0.0
		soc = EnergyTimeline.step_soc(soc, solar, aux, load, dt, cap_kwh, ceff, deff, floor_kwh)
		# Same hysteresis as SolarUI._apply_soc_hysteresis.
		if ac_on and soc <= floor_kwh + 1e-6:
			ac_on = false
			if is_inf(float(out["first_ac_off_h"])):
				out["first_ac_off_h"] = t + dt
		elif not ac_on and soc >= resume_kwh - 1e-6:
			ac_on = true
		out["solar_kwh"] = float(out["solar_kwh"]) + solar * dt
		out["aux_kwh"] = float(out["aux_kwh"]) + aux * dt
		out["demand_kwh"] = float(out["demand_kwh"]) + demand * dt
		out["served_kwh"] = float(out["served_kwh"]) + load * dt
		if not ac_on:
			out["ac_off_h"] = float(out["ac_off_h"]) + dt
			out["unserved_kwh"] = float(out["unserved_kwh"]) + demand * dt
		if soc >= cap_kwh - 1e-4:
			out["full_h"] = float(out["full_h"]) + dt
		if soc < float(out["soc_min"]):
			out["soc_min"] = soc
			out["soc_min_h"] = t + dt
		out["soc_max"] = maxf(float(out["soc_max"]), soc)
		# Per-day rollup (day index from the start, 24 h buckets).
		var di := int(floor((t + 1e-6) / 24.0))
		if day.is_empty() or int(day.get("i", -1)) != di:
			if not day.is_empty():
				(out["days"] as Array).append(day)
			day = {"i": di, "solar_kwh": 0.0, "aux_kwh": 0.0, "demand_kwh": 0.0,
				"ac_off_h": 0.0, "soc_end": soc}
		day["solar_kwh"] = float(day["solar_kwh"]) + solar * dt
		day["aux_kwh"] = float(day["aux_kwh"]) + aux * dt
		day["demand_kwh"] = float(day["demand_kwh"]) + demand * dt
		if not ac_on:
			day["ac_off_h"] = float(day["ac_off_h"]) + dt
		day["soc_end"] = soc
		t += dt
	if not day.is_empty():
		(out["days"] as Array).append(day)
	out["soc_end"] = soc
	return out


## One-line verdict for the dashboard: what the next `hours` look like.
static func summary_line(p: Dictionary, cap_kwh: float) -> Dictionary:
	var hrs := float(p.get("hours", 0.0))
	var days := hrs / 24.0
	var make := float(p.get("solar_kwh", 0.0)) + float(p.get("aux_kwh", 0.0))
	var use := float(p.get("demand_kwh", 0.0))
	var pct_min := 100.0 * float(p.get("soc_min", 0.0)) / maxf(cap_kwh, 1e-6)
	var off := float(p.get("ac_off_h", 0.0))
	var text := "Next %.0f d: make %.1f kWh (solar %.1f) · use %.1f · battery low %.0f %%" % [
		days, make, float(p.get("solar_kwh", 0.0)), use, pct_min]
	if off > 0.05:
		text += " · AC off %s" % SiteBalance.fmt_hours(off)
	return {"text": text, "tone": "warn" if off > 0.05 else "ok"}
