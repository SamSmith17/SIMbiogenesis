class_name CampPowerModel
extends RefCounted

## The SIMPLIFIED per-camp energy model (festival plan Phase 6): every camp
## has its own battery charge, PV and load, stepped off the one sun the site
## shares. The player's own system keeps the full SolarUI treatment; a camp
## is four numbers on its compound — `pv_wp`, `battery_kwh`, `inverter_w`,
## `base_load_w` — plus a state of charge.
##
## Per tick: pv_kw = pv_wp/1000 × yield (kW per kWp, from SolarUI's own
## evaluate_solar_at divided by its nameplate, so camps and the player's array
## see the same irradiance, tilt and weather); load = base load + a night
## lighting term per person; SOC via EnergyTimeline.step_soc (the same pure
## step the player's battery uses, 95 %/95 % round trip, a 10 % floor).
## `ac_available` = SOC above the floor OR the sun covering the load.
##
## Pure static over a small state dict so it is selftestable and so the view
## can keep fifty of them in a Dictionary.

const CHARGE_EFF := 0.95
const DISCHARGE_EFF := 0.95
const SOC_FLOOR := 0.10
## Night lighting per person (W) between dusk and this hour.
const LIGHT_W_PER_PERSON := 10.0
const LIGHTS_OFF_H := 1.0
const DUSK_H := 19.5
## A camp with no battery and no PV is simply unpowered.
const EPS_KW := 1e-6

## Style defaults: what a typical camp of each placement style brings.
## (pv_wp, battery_kwh, inverter_w, base_load_w) — base load is the camp's
## always-on draw (a fridge, a router, a pump), per camp not per person.
const STYLE_DEFAULTS := {
	"theme_camp": {"pv_wp": 1800.0, "battery_kwh": 5.12, "inverter_w": 3000.0, "base_load_w": 220.0},
	"rv_park": {"pv_wp": 400.0, "battery_kwh": 2.5, "inverter_w": 2000.0, "base_load_w": 120.0},
	"mixed": {"pv_wp": 600.0, "battery_kwh": 1.2, "inverter_w": 1500.0, "base_load_w": 60.0},
	"glamping": {"pv_wp": 800.0, "battery_kwh": 2.0, "inverter_w": 1500.0, "base_load_w": 90.0},
	"car_camping": {"pv_wp": 200.0, "battery_kwh": 0.5, "inverter_w": 500.0, "base_load_w": 15.0},
	"tent_village": {"pv_wp": 0.0, "battery_kwh": 0.0, "inverter_w": 0.0, "base_load_w": 0.0},
}


static func defaults_for(style: String) -> Dictionary:
	return (STYLE_DEFAULTS.get(style, STYLE_DEFAULTS["mixed"]) as Dictionary).duplicate()


## A fresh state: {soc_kwh, pv_kw, load_kw, ac_available, hours_left, net_kw}.
static func make_state(spec: Dictionary, soc_frac: float = 0.8) -> Dictionary:
	var cap := maxf(float(spec.get("battery_kwh", 0.0)), 0.0)
	return {"soc_kwh": clampf(soc_frac, 0.0, 1.0) * cap, "pv_kw": 0.0, "load_kw": 0.0,
		"ac_available": cap > EPS_KW, "hours_left": INF, "net_kw": 0.0, "deficit_kwh": 0.0}


## What a camp draws at `hour`: its base load plus lights after dusk.
static func load_kw(spec: Dictionary, headcount: int, hour: float, extra_w: float = 0.0) -> float:
	var w := maxf(float(spec.get("base_load_w", 0.0)), 0.0) + maxf(extra_w, 0.0)
	var h := fposmod(hour, 24.0)
	if h >= DUSK_H or h < LIGHTS_OFF_H:
		w += LIGHT_W_PER_PERSON * float(maxi(headcount, 0))
	var inv := float(spec.get("inverter_w", 0.0))
	if inv > 0.0:
		w = minf(w, inv)
	return w / 1000.0


## Advance one camp by dt_hours. `yield_kw_per_kwp` is the site's PV yield
## right now (0 at night, ~0.8 at clear noon). Mutates and returns `state`.
static func step(spec: Dictionary, state: Dictionary, headcount: int, hour: float,
		yield_kw_per_kwp: float, dt_hours: float, extra_w: float = 0.0) -> Dictionary:
	var cap := maxf(float(spec.get("battery_kwh", 0.0)), 0.0)
	var pv := maxf(float(spec.get("pv_wp", 0.0)), 0.0) / 1000.0 * maxf(yield_kw_per_kwp, 0.0)
	var load := load_kw(spec, headcount, hour, extra_w)
	var soc := float(state.get("soc_kwh", 0.0))
	var floor_kwh := cap * SOC_FLOOR
	var served := load
	if cap <= EPS_KW:
		# No battery: the sun powers the load directly or nothing does.
		served = minf(load, pv)
	else:
		var before := soc
		soc = EnergyTimeline.step_soc(soc, pv, 0.0, load, dt_hours, cap,
			CHARGE_EFF, DISCHARGE_EFF, floor_kwh)
		# What the battery could not give is unserved load.
		var net := pv - load
		if net < 0.0 and dt_hours > 0.0:
			var wanted := absf(net) * dt_hours / DISCHARGE_EFF
			var gave := before - soc
			if wanted > 1e-9 and gave < wanted - 1e-9:
				served = pv + gave * DISCHARGE_EFF / dt_hours
	var deficit := maxf(load - served, 0.0)
	state["soc_kwh"] = soc
	state["pv_kw"] = pv
	state["load_kw"] = load
	state["net_kw"] = pv - load
	state["deficit_kwh"] = float(state.get("deficit_kwh", 0.0)) + deficit * dt_hours
	state["ac_available"] = deficit <= 1e-6 and (cap > EPS_KW or pv > EPS_KW)
	var drain := load - pv
	state["hours_left"] = ((soc - floor_kwh) / drain) if (cap > EPS_KW and drain > 1e-6) else INF
	return state


static func soc_frac(spec: Dictionary, state: Dictionary) -> float:
	var cap := maxf(float(spec.get("battery_kwh", 0.0)), 0.0)
	return clampf(float(state.get("soc_kwh", 0.0)) / cap, 0.0, 1.0) if cap > EPS_KW else 0.0


## Daily energy balance from the spec alone (for the ledger / card): kWh of
## PV at `peak_sun_hours`, kWh of load, and the net.
static func daily_balance(spec: Dictionary, headcount: int, peak_sun_hours: float = 5.0) -> Dictionary:
	var pv_kwh := maxf(float(spec.get("pv_wp", 0.0)), 0.0) / 1000.0 * maxf(peak_sun_hours, 0.0)
	var load_kwh := 0.0
	for h in 24:
		load_kwh += load_kw(spec, headcount, float(h))
	return {"pv_kwh": pv_kwh, "load_kwh": load_kwh, "net_kwh": pv_kwh - load_kwh}
