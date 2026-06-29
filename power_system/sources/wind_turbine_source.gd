class_name WindTurbineSource
extends EnergySource

## Small wind turbine generation source.
##
## Power model (Manwell, McGowan & Rogers, "Wind Energy Explained",
## 2nd ed., 2009):
##     P = ½ · ρ · A · Cp(v) · v³ · η_gen
## with the power coefficient Cp hard-capped at the Betz limit
## Cp_max = 16/27 ≈ 0.593 (Betz, 1920). Output is zero below cut-in and
## above cut-out, follows the cubic law between cut-in and rated speed,
## and is held at nameplate rating between rated and cut-out
## (pitch / furling regulation).
##
## Air density uses the ICAO International Standard Atmosphere troposphere
## relation; hub-height wind speed uses the logarithmic wind profile for a
## neutral surface layer (Stull, 1988).

## Betz limit: maximum fraction of kinetic energy a free-stream rotor can
## extract, Cp_max = 16/27 (Betz, 1920).
const BETZ_LIMIT: float = 16.0 / 27.0

## ISA sea-level standard: ρ0 = 1.225 kg/m³, T0 = 288.15 K, lapse rate
## L = 0.0065 K/m, g = 9.80665 m/s², R_air = 287.058 J/(kg·K).
const AIR_DENSITY_SEA_LEVEL: float = 1.225
const ISA_T0_K: float = 288.15
const ISA_LAPSE_K_PER_M: float = 0.0065
const STANDARD_GRAVITY: float = 9.80665
const R_SPECIFIC_AIR: float = 287.058

## Normalized Cp shape curves: pairs of (v / rated_ms, Cp / cp_peak).
## Generic shapes representative of published small-turbine performance:
## a HAWT builds efficiency quickly and peaks around 70% of rated speed;
## a Darrieus-style VAWT self-starts poorly (low Cp near cut-in) and peaks
## closer to rated speed. Absolute scale comes from config.cp_peak, which
## the user sets inside the realistic 0.35–0.45 (HAWT) / 0.30–0.40 (VAWT)
## bands; the Betz cap is enforced on the final value regardless.
const _CP_SHAPE_HAWT: Array = [
	[0.27, 0.55], [0.45, 0.85], [0.70, 1.00], [1.00, 0.95],
]
const _CP_SHAPE_VAWT: Array = [
	[0.27, 0.35], [0.50, 0.75], [0.75, 1.00], [1.00, 0.90],
]

@export var config: WindTurbineConfig

## Last computed intermediate values, exposed for UIs / debugging.
var last_wind_at_hub_ms: float = 0.0
var last_air_density: float = AIR_DENSITY_SEA_LEVEL
var last_cp: float = 0.0


func _init() -> void:
	source_name = "Wind Turbine"


func _compute_power_kw() -> float:
	if config == null:
		return 0.0
	var v_hub := wind_speed_at_hub_ms()
	last_wind_at_hub_ms = v_hub
	return power_at_wind_speed_kw(v_hub)


## Instantaneous electrical output (kW) for a given hub-height wind speed.
## Pure function of config + speed; used by _compute_power_kw and tests.
func power_at_wind_speed_kw(v_hub: float) -> float:
	if config == null:
		return 0.0
	# Cut-in / cut-out window
	if v_hub < config.cut_in_ms or v_hub > config.cut_out_ms:
		last_cp = 0.0
		return 0.0

	var rho := air_density_at_altitude(config.site_altitude_m)
	last_air_density = rho
	var radius := config.rotor_diameter_m * 0.5
	var swept_area := PI * radius * radius

	# Rated-to-cut-out plateau: regulation holds nameplate output.
	if v_hub >= config.rated_ms:
		last_cp = _cp_at_speed(config.rated_ms)
		return config.rated_power_w / 1000.0

	var cp := _cp_at_speed(v_hub)
	last_cp = cp
	# P = ½·ρ·A·Cp·v³ (Wind Energy Explained, eq. for power in the wind
	# times the power coefficient), then generator/drivetrain efficiency.
	var p_watts := 0.5 * rho * swept_area * cp * v_hub * v_hub * v_hub \
		* config.generator_efficiency
	# Nameplate is an absolute electrical cap.
	return minf(p_watts, config.rated_power_w) / 1000.0


## Cp at a given wind speed: normalized shape lookup × cp_peak, hard-capped
## at the Betz limit.
func _cp_at_speed(v: float) -> float:
	var shape: Array = _CP_SHAPE_VAWT \
		if config.turbine_type == WindTurbineConfig.TurbineType.VERTICAL_AXIS \
		else _CP_SHAPE_HAWT
	var v_norm := v / maxf(config.rated_ms, 0.01)
	var frac := _interp_shape(shape, v_norm)
	return minf(config.cp_peak * frac, BETZ_LIMIT)


static func _interp_shape(shape: Array, x: float) -> float:
	if x <= float(shape[0][0]):
		return float(shape[0][1])
	for i in range(1, shape.size()):
		var x1 := float(shape[i][0])
		if x <= x1:
			var x0 := float(shape[i - 1][0])
			var y0 := float(shape[i - 1][1])
			var y1 := float(shape[i][1])
			var t := (x - x0) / maxf(x1 - x0, 1e-6)
			return lerpf(y0, y1, t)
	return float(shape[shape.size() - 1][1])


## ICAO ISA troposphere density:
##     ρ(h) = ρ0 · (1 − L·h/T0)^(g/(R·L) − 1)
## Exponent g/(R·L) − 1 = 9.80665/(287.058·0.0065) − 1 ≈ 4.2559.
static func air_density_at_altitude(altitude_m: float) -> float:
	var h := clampf(altitude_m, 0.0, 11000.0)  # troposphere validity
	var base := 1.0 - ISA_LAPSE_K_PER_M * h / ISA_T0_K
	var exponent := STANDARD_GRAVITY / (R_SPECIFIC_AIR * ISA_LAPSE_K_PER_M) - 1.0
	return AIR_DENSITY_SEA_LEVEL * pow(base, exponent)


## Logarithmic wind profile (neutral stability):
##     v(z) = v_ref · ln(z/z0) / ln(z_ref/z0)
static func shear_correct_ms(v_ref: float, ref_height_m: float,
		target_height_m: float, roughness_m: float) -> float:
	var z0 := maxf(roughness_m, 1e-4)
	var z_ref := maxf(ref_height_m, z0 * 1.01)
	var z := maxf(target_height_m, z0 * 1.01)
	return v_ref * log(z / z0) / log(z_ref / z0)


## Standard meteorological measurement height for Open-Meteo wind_speed_10m.
const WEATHER_WIND_REF_HEIGHT_M := 10.0

## Site wind speed at hub height for the current world time. Prefers the
## real Open-Meteo measurement (10 m reference height) when WeatherService
## covers the sim location; otherwise falls back to the synthetic
## mean + diurnal + gust model. Either way the result is shear-corrected
## to hub height with the log profile.
func wind_speed_at_hub_ms() -> float:
	var ws := _covering_weather_service()
	if ws != null:
		var real: float = float(ws.call("wind_speed_ms",
			_world_month(), _world_day(), _world_hour()))
		if not is_nan(real):
			return shear_correct_ms(real, WEATHER_WIND_REF_HEIGHT_M,
				config.hub_height_m, config.surface_roughness_m)
	return _synthetic_wind_at_hub_ms()


## Deterministic fallback wind model (used offline / before data loads).
func _synthetic_wind_at_hub_ms() -> float:
	var v := config.site_mean_wind_ms
	if config.enable_wind_variation:
		var h := _world_hour()
		# Diurnal cycle peaking mid-afternoon (~15:00), a common surface-wind
		# pattern driven by daytime convective mixing.
		var diurnal := sin((h - 9.0) / 24.0 * TAU)
		# Slow deterministic gust/lull variation (two incommensurate sines so
		# the pattern does not visibly repeat within a day).
		var gust := 0.6 * sin(h * 7.3) + 0.4 * sin(h * 13.7)
		v *= 1.0 + config.diurnal_amplitude * diurnal + config.gust_amplitude * gust
	v = maxf(v, 0.0)
	return shear_correct_ms(v, config.anemometer_height_m,
		config.hub_height_m, config.surface_roughness_m)


func get_peak_capacity_kw() -> float:
	if config == null:
		return 0.0
	return config.rated_power_w / 1000.0


## ---------------------------------------------------------------------------
## Graph-item adapter
## ---------------------------------------------------------------------------

## Compute output (kW) from a flat system-graph specs Dictionary, so 2D graph
## "wind" items share the exact physics above without holding a Node or a
## WindTurbineConfig. `hour` is the world clock's day_time (0–24).
## Recognized keys (defaults model the 1 kW reference HAWT):
##   kind ("hawt"|"vawt"), rated_w, rotor_diameter_m, cp_peak, cut_in_ms,
##   rated_ms, cut_out_ms, hub_height_m, anemometer_height_m,
##   surface_roughness_m, site_altitude_m, site_mean_wind_ms,
##   generator_efficiency
## `real_wind_10m_ms`: measured wind at 10 m reference height (from
## WeatherService); pass NAN to use the synthetic site model.
static func power_kw_from_graph_specs(specs: Dictionary, hour: float,
		real_wind_10m_ms: float = NAN) -> float:
	var rated_ms := maxf(float(specs.get("rated_ms", 11.0)), 0.1)
	var cut_in := float(specs.get("cut_in_ms", 3.0))
	var cut_out := float(specs.get("cut_out_ms", 20.0))
	var rated_w := maxf(float(specs.get("rated_w", 1000.0)), 0.0)

	var v_hub: float
	if not is_nan(real_wind_10m_ms):
		v_hub = shear_correct_ms(maxf(real_wind_10m_ms, 0.0),
			WEATHER_WIND_REF_HEIGHT_M,
			float(specs.get("hub_height_m", 10.0)),
			float(specs.get("surface_roughness_m", 0.03)))
	else:
		# Site wind with the same deterministic diurnal + gust model as
		# the synthetic fallback (fixed default amplitudes for graph items).
		var v := maxf(float(specs.get("site_mean_wind_ms", 6.0)), 0.0)
		var diurnal := sin((hour - 9.0) / 24.0 * TAU)
		var gust := 0.6 * sin(hour * 7.3) + 0.4 * sin(hour * 13.7)
		v *= 1.0 + 0.25 * diurnal + 0.15 * gust
		v = maxf(v, 0.0)
		v_hub = shear_correct_ms(v,
			float(specs.get("anemometer_height_m", 10.0)),
			float(specs.get("hub_height_m", 10.0)),
			float(specs.get("surface_roughness_m", 0.03)))

	if v_hub < cut_in or v_hub > cut_out:
		return 0.0
	if v_hub >= rated_ms:
		return rated_w / 1000.0

	var rho := air_density_at_altitude(float(specs.get("site_altitude_m", 0.0)))
	var d := maxf(float(specs.get("rotor_diameter_m", 2.1)), 0.05)
	var area := PI * d * d * 0.25
	var is_vawt := str(specs.get("kind", "hawt")).to_lower() == "vawt"
	var shape: Array = _CP_SHAPE_VAWT if is_vawt else _CP_SHAPE_HAWT
	var cp := minf(
		float(specs.get("cp_peak", 0.42)) * _interp_shape(shape, v_hub / rated_ms),
		BETZ_LIMIT)
	var p := 0.5 * rho * area * cp * v_hub * v_hub * v_hub \
		* clampf(float(specs.get("generator_efficiency", 0.90)), 0.0, 1.0)
	return minf(p, rated_w) / 1000.0
