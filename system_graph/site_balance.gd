class_name SiteBalance
extends RefCounted

## The whole site as ONE balance sheet, right now — what the graph dashboard's
## "Site balance" card shows. Pure over the graph items + a SolarUI snapshot,
## so the selftest feeds it fixtures. Energy: every generator by name, the
## loads, the net, and how long the battery lasts or takes to fill at this
## rate. Water: every pond's inflows (streams / rain) and outflows (turbines,
## spill), its net, and how long to full or to the siphon's break level.
##
## `solar` keys (all optional): solar_kw, graph_dc_kw, aux_kw, load_kw,
## stored_kwh, cap_kwh, floor_pct.

const DC_KINDS := ["dc_electricity"]


static func compute(items: Array, solar: Dictionary) -> Dictionary:
	var gens: Array = []
	var hydro_kw := 0.0
	for it_v in items:
		if not (it_v is Dictionary):
			continue
		var it: Dictionary = it_v
		if bool(it.get("is_virtual", false)):
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		var itype := str(it.get("type", ""))
		if itype == "processor" and str(sp.get("role", "")) == "siphon_hydro":
			var kw := maxf(float(sp.get("current_output_kw", 0.0)), 0.0)
			hydro_kw += kw
			gens.append({"id": str(it.get("id", "")), "name": str(sp.get("name", "Turbine")),
				"kw": kw, "q_lps": maxf(float(sp.get("live_q_lps", 0.0)), 0.0),
				"regime": str(sp.get("live_regime", "")), "kind": "hydro"})
		elif itype in ["wind", "hydro"]:
			var kw2 := maxf(float(sp.get("current_output_kw", 0.0)), 0.0)
			gens.append({"id": str(it.get("id", "")), "name": str(sp.get("name", itype)),
				"kw": kw2, "q_lps": 0.0, "regime": "", "kind": itype})
	var solar_kw := maxf(float(solar.get("solar_kw", 0.0)), 0.0)
	# What actually reaches the bank (the wired generation SolarUI integrates)
	# vs what the generators make: a gap means something is not wired in.
	var dc_kw := maxf(float(solar.get("graph_dc_kw", 0.0)), 0.0) + maxf(float(solar.get("aux_kw", 0.0)), 0.0)
	# The loads' DEMAND when known: while low-SOC protection has shed them the
	# served load reads 0, and "use 0 kW" hid why the battery sat at its floor.
	var load_kw := maxf(maxf(float(solar.get("load_kw", 0.0)), 0.0),
			maxf(float(solar.get("demand_kw", 0.0)), 0.0))
	var shed := float(solar.get("demand_kw", 0.0)) > float(solar.get("load_kw", 0.0)) + 0.01
	var gen_kw := solar_kw + dc_kw
	var net_kw := gen_kw - load_kw
	var stored := maxf(float(solar.get("stored_kwh", 0.0)), 0.0)
	var cap := maxf(float(solar.get("cap_kwh", 0.0)), 0.0)
	var floor_kwh := cap * clampf(float(solar.get("floor_pct", 10.0)), 0.0, 100.0) / 100.0
	var hours_to_empty := INF
	var hours_to_full := INF
	if net_kw < -1e-4:
		hours_to_empty = maxf(stored - floor_kwh, 0.0) / -net_kw
	elif net_kw > 1e-4 and cap > 0.0:
		hours_to_full = maxf(cap - stored, 0.0) / net_kw
	var energy := {
		"gens": gens, "solar_kw": solar_kw, "hydro_kw": hydro_kw,
		"to_bank_kw": dc_kw, "unwired_kw": maxf(hydro_kw - dc_kw, 0.0),
		"load_kw": load_kw, "gen_kw": gen_kw, "net_kw": net_kw,
		"daily_net_kwh": net_kw * 24.0,
		"load_uncovered": load_kw > gen_kw + 1e-4,
		"loads_shed": shed,
		"stored_kwh": stored, "cap_kwh": cap,
		"hours_to_empty": hours_to_empty, "hours_to_full": hours_to_full,
	}

	var ponds: Array = []
	for it_v in items:
		if not (it_v is Dictionary):
			continue
		var it: Dictionary = it_v
		var ps: Dictionary = it.get("specs", {}) as Dictionary
		if not bool(ps.get("pond_storage", false)):
			continue
		var cap_l := maxf(float(ps.get("capacity_qty", 0.0)), 0.0)
		var stock := maxf(float(ps.get("stock_l", float(ps.get("level", 0.0)) * cap_l)), 0.0)
		var rain := maxf(float(ps.get("budget_rain_lph", 0.0)), 0.0)
		var streams := maxf(float(ps.get("budget_stream_lph", 0.0)), 0.0)
		var spill := maxf(float(ps.get("budget_spill_lph", 0.0)), 0.0)
		# Net from the tank's own integrated rates (inflow − outflow already
		# include turbine draw and the spill cap).
		var net_l := float(ps.get("inflow_rate", 0.0)) - float(ps.get("outflow_rate", 0.0))
		var draw := maxf(rain + streams - spill - net_l, 0.0)
		var to_full := INF
		var to_low := INF
		if net_l > 1.0 and cap_l > 0.0:
			to_full = maxf(cap_l - stock, 0.0) / net_l
		elif net_l < -1.0:
			to_low = stock / -net_l
		ponds.append({"id": str(it.get("id", "")), "name": str(ps.get("name", "Pond")),
			"level_m": float(ps.get("level_m", NAN)), "stock_l": stock, "cap_l": cap_l,
			"rain_lph": rain, "stream_lph": streams, "spill_lph": spill,
			"draw_lph": draw, "net_lph": net_l,
			"hours_to_full": to_full, "hours_to_empty": to_low,
			"spill_to": str(ps.get("spill_outlet_id", ""))})
	return {"energy": energy, "ponds": ponds}


## Compact human durations: "40 min", "6.5 h", "3.2 d", "—" for never.
static func fmt_hours(h: float) -> String:
	if is_inf(h) or is_nan(h):
		return "—"
	if h < 1.0:
		return "%d min" % int(round(h * 60.0))
	if h < 48.0:
		return "%.1f h" % h
	return "%.1f d" % (h / 24.0)


## The card's text lines: [{text, tone}] where tone is ok | warn | muted.
static func lines(b: Dictionary) -> Array:
	var out: Array = []
	var e: Dictionary = b.get("energy", {}) as Dictionary
	for g_v in (e.get("gens", []) as Array):
		var g: Dictionary = g_v
		var extra := ""
		if str(g.get("kind", "")) == "hydro":
			extra = " · %.1f L/s" % float(g.get("q_lps", 0.0)) if float(g.get("q_lps", 0.0)) > 0.0 \
					else (" · %s" % str(g.get("regime", ""))) if not str(g.get("regime", "")).is_empty() else ""
		out.append({"text": "%s  %.0f W%s" % [str(g.get("name", "")), float(g.get("kw", 0.0)) * 1000.0, extra],
			"tone": "ok" if float(g.get("kw", 0.0)) > 0.001 else "muted"})
	if float(e.get("unwired_kw", 0.0)) > 0.005:
		out.append({"text": "%.0f W of hydro is not wired to the battery" % (float(e.get("unwired_kw", 0.0)) * 1000.0),
			"tone": "warn"})
	var net := float(e.get("net_kw", 0.0))
	out.append({"text": "Make %.2f kW · use %.2f kW → %+.2f kW (%+.1f kWh/day)" % [
			float(e.get("gen_kw", 0.0)), float(e.get("load_kw", 0.0)), net, float(e.get("daily_net_kwh", 0.0))],
		"tone": "warn" if bool(e.get("load_uncovered", false)) else "ok"})
	if bool(e.get("loads_shed", false)):
		out.append({"text": "AC is off — battery at its floor; loads shed until it recovers to the resume level",
			"tone": "warn"})
	elif bool(e.get("load_uncovered", false)):
		out.append({"text": "Loads exceed generation — battery empties in %s" % fmt_hours(float(e.get("hours_to_empty", INF))),
			"tone": "warn"})
	elif net > 1e-4:
		out.append({"text": "Battery full in %s" % fmt_hours(float(e.get("hours_to_full", INF))), "tone": "muted"})
	for p_v in (b.get("ponds", []) as Array):
		var p: Dictionary = p_v
		var head := "%s  %.2f m" % [str(p.get("name", "")), float(p.get("level_m", 0.0))] \
				if not is_nan(float(p.get("level_m", NAN))) else str(p.get("name", ""))
		out.append({"text": head, "tone": "muted"})
		out.append({"text": "  in %.1f m³/h (streams %.1f · rain %.1f) · out %.1f · spill %.1f" % [
				(float(p.get("stream_lph", 0.0)) + float(p.get("rain_lph", 0.0))) / 1000.0,
				float(p.get("stream_lph", 0.0)) / 1000.0, float(p.get("rain_lph", 0.0)) / 1000.0,
				float(p.get("draw_lph", 0.0)) / 1000.0, float(p.get("spill_lph", 0.0)) / 1000.0],
			"tone": "muted"})
		var nl := float(p.get("net_lph", 0.0))
		if float(p.get("spill_lph", 0.0)) > 1.0:
			out.append({"text": "  full — spilling%s" % ("" if not str(p.get("spill_to", "")).is_empty()
					else " (no outlet set: the surplus leaves unrouted)"), "tone": "warn"})
		elif nl > 1.0:
			out.append({"text": "  rising %.1f m³/h · full in %s" % [nl / 1000.0, fmt_hours(float(p.get("hours_to_full", INF)))], "tone": "ok"})
		elif nl < -1.0:
			out.append({"text": "  falling %.1f m³/h" % (-nl / 1000.0), "tone": "muted"})
	return out
