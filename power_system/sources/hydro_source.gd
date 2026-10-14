class_name HydroSource
extends EnergySource

## Small-scale (micro) hydroelectric generation source.
##
## Power model (standard hydropower relation, see e.g. Paish 2002,
## "Small hydro power: technology and current status", RSER 6:537–556):
##     P = ρ · g · Q · h_net · η_turbine · η_generator
## where h_net is the gross head minus penstock friction losses computed
## with the Darcy–Weisbach equation:
##     h_f = f · (L/D) · v² / (2g)
## The Darcy friction factor f uses the Swamee–Jain (1976) explicit
## approximation of the Colebrook–White relation in the turbulent regime
## and f = 64/Re in the laminar regime.
##
## Seasonal flow variation is a per-month multiplier on the design flow,
## driven by the world clock's month.

## Density of fresh water, kg/m³ — standard hydropower convention.
const WATER_DENSITY: float = 1000.0

## Standard gravity, m/s².
const STANDARD_GRAVITY: float = 9.80665

## Kinematic viscosity of water at 20 °C, m²/s (for Reynolds number).
const WATER_KINEMATIC_VISCOSITY: float = 1.004e-6

## Laminar/turbulent transition Reynolds number for pipe flow.
const RE_LAMINAR_LIMIT: float = 2300.0

@export var config: HydroConfig

## Last computed intermediates, exposed for UIs / debugging.
var last_flow_m3s: float = 0.0
var last_head_loss_m: float = 0.0
var last_net_head_m: float = 0.0


func _init() -> void:
	source_name = "Hydro Turbine"


func _compute_power_kw() -> float:
	if config == null:
		return 0.0
	return power_at_month_kw(_world_month())


## Output for a given calendar month (1–12). Uses the config's multipliers
## when present (12 entries); an empty/invalid config array falls back to
## real precipitation-derived multipliers from WeatherService when a dataset
## covers the sim location, then to the built-in default profile.
func power_at_month_kw(month: int) -> float:
	if config == null:
		return 0.0
	var mult := 1.0
	var mults: Array = config.monthly_flow_multipliers
	if mults == null or mults.size() != 12:
		mults = _weather_flow_multipliers()
	if mults != null and mults.size() == 12:
		mult = maxf(float(mults[clampi(month, 1, 12) - 1]), 0.0)
	return power_at_flow_kw(config.design_flow_m3s * mult)


## Precipitation-derived multipliers from WeatherService, or the default
## profile when unavailable.
func _weather_flow_multipliers() -> Array:
	var ws := _covering_weather_service()
	if ws != null and ws.has_method("monthly_precip_multipliers"):
		var m: Array = ws.call("monthly_precip_multipliers") as Array
		if m.size() == 12:
			return m
	return _DEFAULT_MONTHLY_MULTIPLIERS


## Electrical output (kW) for a given flow through the penstock.
func power_at_flow_kw(flow_m3s: float) -> float:
	if config == null or flow_m3s <= 0.0:
		last_flow_m3s = maxf(flow_m3s, 0.0)
		last_head_loss_m = 0.0
		last_net_head_m = 0.0
		return 0.0
	last_flow_m3s = flow_m3s

	var h_f := pipe_friction_head_loss_m(
		flow_m3s,
		config.penstock_diameter_m,
		config.penstock_length_m,
		config.pipe_roughness_m)
	last_head_loss_m = h_f
	var h_net := maxf(config.gross_head_m - h_f, 0.0)
	last_net_head_m = h_net
	if h_net <= 0.0:
		return 0.0

	# P = ρ·g·Q·h_net·η (Paish 2002)
	var p_watts := WATER_DENSITY * STANDARD_GRAVITY * flow_m3s * h_net \
		* config.effective_turbine_efficiency() \
		* config.generator_efficiency
	return p_watts / 1000.0


## Darcy–Weisbach head loss h_f = f·(L/D)·v²/(2g) for a circular pipe.
static func pipe_friction_head_loss_m(flow_m3s: float, diameter_m: float,
		length_m: float, roughness_m: float) -> float:
	var d := maxf(diameter_m, 1e-4)
	var area := PI * d * d / 4.0
	var velocity := flow_m3s / area
	var f := darcy_friction_factor(velocity, d, roughness_m)
	return f * (length_m / d) * velocity * velocity / (2.0 * STANDARD_GRAVITY)


## Darcy friction factor:
##  - Laminar (Re < 2300): f = 64/Re.
##  - Turbulent: Swamee–Jain (1976) explicit form
##        f = 0.25 / [log10( ε/(3.7·D) + 5.74/Re^0.9 )]²
##    valid for 5e3 ≤ Re ≤ 1e8 and 1e-6 ≤ ε/D ≤ 1e-2; we apply it from the
##    laminar limit upward, which is the usual engineering simplification
##    for the narrow transitional band.
static func darcy_friction_factor(velocity_ms: float, diameter_m: float,
		roughness_m: float) -> float:
	var v := absf(velocity_ms)
	if v < 1e-9:
		return 0.0
	var re := v * diameter_m / WATER_KINEMATIC_VISCOSITY
	if re < RE_LAMINAR_LIMIT:
		return 64.0 / re
	var term := roughness_m / (3.7 * diameter_m) + 5.74 / pow(re, 0.9)
	var lg := log(term) / log(10.0)
	return 0.25 / (lg * lg)


## Nameplate: output at design flow (multiplier 1.0).
func get_peak_capacity_kw() -> float:
	if config == null:
		return 0.0
	return power_at_flow_kw(config.design_flow_m3s)


## ---------------------------------------------------------------------------
## Graph-item adapter
## ---------------------------------------------------------------------------

## Default seasonal profile for graph items (temperate snowmelt stream),
## mirrors HydroConfig.monthly_flow_multipliers.
const _DEFAULT_MONTHLY_MULTIPLIERS: Array = [
	0.8, 0.9, 1.2, 1.4, 1.3, 1.1, 0.8, 0.6, 0.6, 0.7, 0.8, 0.8,
]

## Days per month for the representative-year annual-energy estimate (non-leap;
## the leap-day difference is negligible for a kWh/yr figure).
const _DAYS_IN_MONTH: Array = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

## Turbine-kind registry — the single source of truth for turbine metadata across
## the generalized hydro path (estimator, HydroReach conveyance, inspector,
## Hydro Lab). Head bands (m) follow ROADMAP.md; default `eta_t` matches the
## historic per-kind efficiencies (pelton .85 / turgo .80 / else .70). Unknown
## kinds resolve to a "custom" fallback via kind_meta() so a free-text kind from
## an old save is never rejected or mangled.
##   has_penstock  — pressurized penstock with Darcy–Weisbach losses (else the
##                   siphon's own orifice/weir path drives Q).
##   pond_drawdown — drains a stored reservoir (else run-of-river streaming).
const KINDS := {
	"siphon": {
		"display": "Siphon (low head)", "eta_t": 0.60,
		"head_band": [0.5, 5.0], "has_penstock": false, "pond_drawdown": true,
		"model_id": "hydroturbine",
	},
	# Generic Pelton: the historic 30 m floor described utility-scale practice;
	# micro Peltons run usefully well below that (Thake, "The Micro-Hydro
	# Pelton Turbine Manual", covers 10 m-class installs), so the band floor is
	# 10 m — the pico class below that is the PowerSpout entry.
	"pelton": {
		"display": "Pelton", "eta_t": 0.85,
		"head_band": [10.0, 300.0], "has_penstock": true, "pond_drawdown": true,
		"model_id": "hydroturbine",
	},
	# PowerSpout PLT-class pico Pelton (published operating range 3–130 m head,
	# ~1.6 kW max continuous output; typical water-to-wire ≈ 50–55%, which is
	# eta_t 0.65 runner × the 0.85 default generator efficiency here). Uses the
	# NOZZLE model: flow is set by jet velocity × nozzle area at the operating
	# point where penstock delivery meets nozzle demand (PeltonPhysics), not by
	# a design-flow knob. `model_id` names the 3D model the kind wears.
	"powerspout_pelton": {
		"display": "PowerSpout PLT (Pelton)", "eta_t": 0.65,
		"head_band": [3.0, 130.0], "has_penstock": true, "pond_drawdown": true,
		"max_power_w": 1600.0,
		"uses_nozzle_model": true,
		"nozzle_count_max": 2,
		"default_nozzle_mm": 10.0,
		# Measured off the shipped powerspout_plt.glb runner (radius ≈ 0.139 m).
		"runner_pcd_m": 0.28,
		"model_id": "powerspout_plt",
	},
	# AliExpress-class micro Pelton: 8" (0.2 m) bucket runner on a vertical
	# shaft, a Nema 34 stepper as the generator, one 1/4" NPT nozzle fitting.
	# Nozzle-governed like the PowerSpout. The listing-class nameplate for
	# these units is a few hundred watts; 500 W is the ceiling the stepper
	# generator can plausibly deliver, and the head band is the low-head end
	# of the Pelton range (Thake: Pelton down to ~3 m at pico scale).
	"micro_pelton": {
		"display": "Micro Pelton 8\u2033 (vertical shaft)", "eta_t": 0.60,
		"head_band": [3.0, 60.0], "has_penstock": true, "pond_drawdown": true,
		"max_power_w": 500.0,
		"uses_nozzle_model": true,
		"nozzle_count_max": 2,
		"default_nozzle_mm": 8.0,
		# Measured off ali_pelton.glb: the nozzle fitting's centreline passes
		# 0.084 m from the shaft (runner tip radius 0.101 m).
		"runner_pcd_m": 0.168,
		"model_id": "ali_pelton",
	},
	"turgo": {
		"display": "Turgo", "eta_t": 0.80,
		"head_band": [10.0, 30.0], "has_penstock": true, "pond_drawdown": true,
		"model_id": "hydroturbine",
	},
	"run_of_river": {
		"display": "Run-of-River", "eta_t": 0.70,
		"head_band": [1.0, 10.0], "has_penstock": true, "pond_drawdown": false,
		"model_id": "hydroturbine",
	},
}


## Metadata for a turbine kind; unknown → a permissive "custom" entry preserving
## the historic else→0.70 efficiency (never destroys an old free-text kind).
static func kind_meta(kind: String) -> Dictionary:
	var k := kind.strip_edges().to_lower()
	if KINDS.has(k):
		return KINDS[k]
	return {
		"display": ("Custom (%s)" % kind) if not kind.strip_edges().is_empty() else "Custom",
		"eta_t": 0.70, "head_band": [1.0, 300.0],
		"has_penstock": true, "pond_drawdown": true,
	}


static func default_turbine_efficiency(kind: String) -> float:
	return float(kind_meta(kind).get("eta_t", 0.70))

## Compute output (kW) from a flat system-graph specs Dictionary, so 2D graph
## "hydro" items share the exact physics above. `month` is 1–12.
## Recognized keys (defaults model the ~500 W reference Pelton; units chosen
## for inspector friendliness — L/s and mm):
##   kind ("pelton"|"turgo"|"run_of_river"), gross_head_m, design_flow_lps,
##   penstock_length_m, penstock_diameter_mm, pipe_roughness_mm,
##   turbine_efficiency (0 = per-kind default), generator_efficiency,
##   monthly_flow_multipliers (optional 12-entry array)
## `weather_multipliers`: precipitation-derived 12-entry array (from
## WeatherService.monthly_precip_multipliers()); used when specs carry no
## explicit multipliers. Pass [] to use the built-in default profile.
static func power_kw_from_graph_specs(specs: Dictionary, month: int,
		weather_multipliers: Array = []) -> float:
	# Turbine kind: prefer the unified `turbine_kind` key, fall back to the legacy
	# `kind` key that type-"hydro" estimator items still carry.
	var kind_str := str(specs.get("turbine_kind", specs.get("kind", "pelton")))
	var meta := kind_meta(kind_str)

	var d := maxf(float(specs.get("penstock_diameter_mm", 63.0)), 1.0) / 1000.0  # mm → m
	var length := maxf(float(specs.get("penstock_length_m", 60.0)), 0.0)
	var eps := maxf(float(specs.get("pipe_roughness_mm", 0.0015)), 0.0) / 1000.0  # mm → m
	var h_gross := float(specs.get("gross_head_m", 25.0))

	var supply_lps := available_supply_lps(specs, month, weather_multipliers)
	var q: float
	var h_net: float
	if bool(meta.get("uses_nozzle_model", false)):
		# Nozzle-governed (PowerSpout Pelton): flow follows head and nozzle area at
		# the PeltonPhysics operating point, capped by the available supply. When
		# supply is the binding limit the nozzle converts only the head its own flow
		# demands — see operating_point_supply_limited.
		var noz_d := maxf(float(specs.get("nozzle_diameter_mm",
				float(meta.get("default_nozzle_mm", 10.0)))), 0.5) / 1000.0
		var noz_n := clampi(int(specs.get("nozzle_count", 1)), 1,
				maxi(int(meta.get("nozzle_count_max", 2)), 1))
		# NAN through to PeltonPhysics means unconstrained; 0.0 means dry.
		var supply_m3s := supply_lps / 1000.0
		var op := _pelton_op(h_gross, length, d, eps, noz_d, noz_n, supply_m3s)
		q = float(op.get("q_m3s", 0.0))
		h_net = float(op.get("h_net_m", 0.0))
	else:
		q = maxf(float(specs.get("design_flow_lps", 3.0)), 0.0) / 1000.0  # L/s → m³/s
		q *= monthly_flow_multiplier(specs, month, weather_multipliers)
		# A live intake supply also caps a plain pelton/turgo/Francis: the stream
		# cannot deliver more than it runs, whatever the design flow says.
		if not is_nan(supply_lps):
			q = minf(q, supply_lps / 1000.0)
		var h_f := pipe_friction_head_loss_m(q, d, length, eps)
		h_net = maxf(h_gross - h_f, 0.0)
	if q <= 0.0 or h_net <= 0.0:
		return 0.0

	var eta_t := float(specs.get("turbine_efficiency", 0.0))
	if eta_t <= 0.0:
		eta_t = default_turbine_efficiency(kind_str)
	var eta_g := clampf(float(specs.get("generator_efficiency", 0.85)), 0.0, 1.0)
	var p_kw := WATER_DENSITY * STANDARD_GRAVITY * q * h_net * eta_t * eta_g / 1000.0
	# Optional nameplate clamp (absent/0 = uncapped → existing hydro items
	# unchanged); the generator can't exceed its rating regardless of head/flow.
	# Product-modeled nozzle kinds inherit their kind's real nameplate.
	var cap_w := float(specs.get("max_power_w", 0.0))
	if cap_w <= 0.0 and bool(meta.get("uses_nozzle_model", false)):
		cap_w = maxf(float(meta.get("max_power_w", 0.0)), 0.0)
	if cap_w > 0.0:
		p_kw = minf(p_kw, cap_w / 1000.0)
	return p_kw


## One Pelton operating point per distinct input set. The flow engine asks for
## power AND flow every tick (two 40-iteration bisections for the same
## point), the Lab's charts ask for dozens per redraw; this memo makes the
## second ask free. Pure: the result is a function of the seven inputs only.
static var _pelton_memo: Dictionary = {}
const _PELTON_MEMO_MAX := 256


static func _pelton_op(h_gross: float, length: float, d: float, eps: float,
		noz_d: float, noz_n: int, supply_m3s: float) -> Dictionary:
	var key := "%.4f|%.3f|%.6f|%.8f|%.6f|%d|%s" % [h_gross, length, d, eps, noz_d, noz_n,
		"nan" if is_nan(supply_m3s) else "%.7f" % supply_m3s]
	var hit: Variant = _pelton_memo.get(key)
	if hit is Dictionary:
		return hit
	if _pelton_memo.size() >= _PELTON_MEMO_MAX:
		_pelton_memo.clear()
	var op := PeltonPhysics.operating_point_supply_limited(
			h_gross, length, d, eps, noz_d, noz_n, supply_m3s)
	_pelton_memo[key] = op
	return op


## Operating flow (L/s) for the SAME operating point power_kw_from_graph_specs
## prices — nozzle kinds take the PeltonPhysics delivery-meets-demand solution
## (supply-capped when design_flow_lps is set), design-flow kinds take
## design × the seasonal multiplier. Telemetry (live_q_lps, the tailwater jet)
## must read THIS, not design_flow_lps: a PowerSpout's design_flow is 0 (the
## nozzle IS the flow control), and a zero-head turbine flows nothing at all.
static func operating_flow_lps_from_graph_specs(specs: Dictionary, month: int,
		weather_multipliers: Array = []) -> float:
	var kind_str := str(specs.get("turbine_kind", specs.get("kind", "pelton")))
	var meta := kind_meta(kind_str)
	var h_gross := float(specs.get("gross_head_m", 25.0))
	if h_gross <= 1e-4:
		return 0.0
	var supply_lps := available_supply_lps(specs, month, weather_multipliers)
	if bool(meta.get("uses_nozzle_model", false)):
		var d := maxf(float(specs.get("penstock_diameter_mm", 63.0)), 1.0) / 1000.0
		var length := maxf(float(specs.get("penstock_length_m", 60.0)), 0.0)
		var eps := maxf(float(specs.get("pipe_roughness_mm", 0.0015)), 0.0) / 1000.0
		var noz_d := maxf(float(specs.get("nozzle_diameter_mm",
				float(meta.get("default_nozzle_mm", 10.0)))), 0.5) / 1000.0
		var noz_n := clampi(int(specs.get("nozzle_count", 1)), 1,
				maxi(int(meta.get("nozzle_count_max", 2)), 1))
		# NAN through to PeltonPhysics means unconstrained; 0.0 means dry.
		var supply_m3s := supply_lps / 1000.0
		var op := _pelton_op(h_gross, length, d, eps, noz_d, noz_n, supply_m3s)
		return float(op.get("q_lps", 0.0))
	var q_lps := maxf(float(specs.get("design_flow_lps", 3.0)), 0.0) \
			* monthly_flow_multiplier(specs, month, weather_multipliers)
	if not is_nan(supply_lps):
		q_lps = minf(q_lps, supply_lps)
	return q_lps


## Available water (L/s) at the turbine, or NAN when nothing constrains it.
##
## `supply_lps` is written by the flow engine from a live stream/spring intake and
## may legitimately be 0.0, meaning DRY. `design_flow_lps` is the authored knob and
## its 0 means "unlimited" for nozzle kinds. Those two zeroes mean opposite things,
## which is exactly why this discriminates on has() and why the keys must never be
## merged: a `> 0` test would silently turn a dried-up spring back into a nozzle
## running at full bore.
static func available_supply_lps(specs: Dictionary, month: int,
		weather_multipliers: Array = []) -> float:
	if specs.has("supply_lps"):
		return maxf(float(specs["supply_lps"]), 0.0)
	var design := maxf(float(specs.get("design_flow_lps", 0.0)), 0.0)
	if design <= 0.0:
		return NAN
	return design * monthly_flow_multiplier(specs, month, weather_multipliers)


## Seasonal flow multiplier for `month` (1–12): explicit specs array > weather-
## derived array > built-in default profile. Extracted from
## power_kw_from_graph_specs so telemetry (live_q_lps display) and physics use
## the SAME multiplier and can never disagree.
static func monthly_flow_multiplier(specs: Dictionary, month: int,
		weather_multipliers: Array = []) -> float:
	var mults: Array = specs.get("monthly_flow_multipliers", []) as Array
	if mults == null or mults.size() != 12:
		mults = weather_multipliers
	if mults == null or mults.size() != 12:
		mults = _DEFAULT_MONTHLY_MULTIPLIERS
	return maxf(float(mults[clampi(month, 1, 12) - 1]), 0.0)


## Representative-year annual/monthly energy for ONE turbine spec (the closed
## form the Site Report uses, factored out so the Hydro Lab estimate card and the
## report share exactly one calculation). Returns
## `{monthly_kwh: PackedFloat32Array(12), annual_kwh: float, mean_kw: float}`.
## `monthly_supply_lps`: optional 12-entry per-month available supply for a live
## stream/spring intake. Without it every month reuses the SINGLE instantaneous
## `supply_lps` the engine last stamped, which freezes the annual figure at
## whatever the spring happened to be running at the moment you opened the panel
## — inflated mid-storm, deflated in a dry spell, and completely blind to the
## seasonal rainfall that is the whole reason the rain coefficient exists.
static func annual_energy_kwh_from_specs(specs: Dictionary,
		weather_multipliers: Array = [],
		monthly_supply_lps: Array = []) -> Dictionary:
	var monthly := PackedFloat32Array()
	monthly.resize(12)
	var annual := 0.0
	var kw_sum := 0.0
	var per_month := monthly_supply_lps.size() == 12
	for mo in range(12):
		var month := mo + 1
		var s := specs
		if per_month:
			s = specs.duplicate(true)
			s["supply_lps"] = maxf(float(monthly_supply_lps[mo]), 0.0)
		var kw := power_kw_from_graph_specs(s, month, weather_multipliers)
		var hours := float(int(_DAYS_IN_MONTH[mo]) * 24)
		var kwh := kw * hours
		monthly[mo] = kwh
		annual += kwh
		kw_sum += kw
	return {"monthly_kwh": monthly, "annual_kwh": annual, "mean_kw": kw_sum / 12.0}
