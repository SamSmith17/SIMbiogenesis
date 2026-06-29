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
	var q := maxf(float(specs.get("design_flow_lps", 3.0)), 0.0) / 1000.0  # L/s → m³/s
	var mults: Array = specs.get("monthly_flow_multipliers", []) as Array
	if mults == null or mults.size() != 12:
		mults = weather_multipliers
	if mults == null or mults.size() != 12:
		mults = _DEFAULT_MONTHLY_MULTIPLIERS
	q *= maxf(float(mults[clampi(month, 1, 12) - 1]), 0.0)
	if q <= 0.0:
		return 0.0

	var d := maxf(float(specs.get("penstock_diameter_mm", 63.0)), 1.0) / 1000.0  # mm → m
	var length := maxf(float(specs.get("penstock_length_m", 60.0)), 0.0)
	var eps := maxf(float(specs.get("pipe_roughness_mm", 0.0015)), 0.0) / 1000.0  # mm → m

	var h_f := pipe_friction_head_loss_m(q, d, length, eps)
	var h_net := maxf(float(specs.get("gross_head_m", 25.0)) - h_f, 0.0)
	if h_net <= 0.0:
		return 0.0

	var eta_t := float(specs.get("turbine_efficiency", 0.0))
	if eta_t <= 0.0:
		match str(specs.get("kind", "pelton")).to_lower():
			"pelton":
				eta_t = 0.85
			"turgo":
				eta_t = 0.80
			_:
				eta_t = 0.70
	var eta_g := clampf(float(specs.get("generator_efficiency", 0.85)), 0.0, 1.0)
	return WATER_DENSITY * STANDARD_GRAVITY * q * h_net * eta_t * eta_g / 1000.0
