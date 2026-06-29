class_name WindTurbineConfig
extends Resource

## Inspector-editable parameters for a small wind turbine.
## Physics references:
##  - Power equation P = ½·ρ·A·Cp·v³ and the Betz limit Cp_max = 16/27:
##    Manwell, McGowan & Rogers, "Wind Energy Explained", 2nd ed. (2009).
##  - Air density vs altitude: ICAO International Standard Atmosphere.
##  - Wind shear: logarithmic wind profile (neutral surface layer), e.g.
##    Stull, "An Introduction to Boundary Layer Meteorology" (1988).

enum TurbineType {
	HORIZONTAL_AXIS,  ## HAWT — propeller-style; peak Cp typically 0.35–0.45
	VERTICAL_AXIS,    ## VAWT (Darrieus-style); peak Cp typically 0.30–0.40
}

@export var turbine_type: TurbineType = TurbineType.HORIZONTAL_AXIS

## Rotor diameter in metres. Swept area A = π·(D/2)² for a HAWT.
## For a VAWT interpret as the equivalent capture diameter (A treated the same).
@export_range(0.5, 20.0, 0.05) var rotor_diameter_m: float = 2.1

## Nameplate (rated) electrical output in watts. Output is held at this
## value between rated speed and cut-out (pitch/furling regulation).
@export_range(50.0, 50000.0, 10.0) var rated_power_w: float = 1000.0

## Peak power coefficient. Good small HAWTs reach 0.35–0.45; VAWTs are
## typically lower (0.30–0.40). Hard-capped at the Betz limit (0.593) at
## runtime regardless of what is entered here.
@export_range(0.05, 0.593, 0.005) var cp_peak: float = 0.42

## Cut-in wind speed (m/s) — below this the rotor produces nothing.
## Typical small turbines: 2.5–3.5 m/s.
@export_range(1.0, 6.0, 0.1) var cut_in_ms: float = 3.0

## Rated wind speed (m/s) — speed at which nameplate output is reached.
@export_range(6.0, 20.0, 0.1) var rated_ms: float = 11.0

## Cut-out wind speed (m/s) — turbine brakes/furls above this for safety.
@export_range(12.0, 40.0, 0.5) var cut_out_ms: float = 20.0

## Generator + drivetrain electrical efficiency applied after the rotor.
@export_range(0.5, 1.0, 0.01) var generator_efficiency: float = 0.90

## Hub height above ground (m). Wind speed is shear-corrected from the
## reference (anemometer) height to this height with the log profile.
@export_range(2.0, 60.0, 0.5) var hub_height_m: float = 10.0

## Height (m) at which `site_mean_wind_ms` is specified. 10 m is the
## standard meteorological anemometer height.
@export_range(2.0, 60.0, 0.5) var anemometer_height_m: float = 10.0

## Aerodynamic roughness length z0 (m) for the log wind profile.
## Davenport–Wieringa classes: open water ≈ 0.0002, open flat grassland
## ≈ 0.03, low crops ≈ 0.1, scattered obstacles/shrubs ≈ 0.25.
@export_range(0.0001, 1.0, 0.0001) var surface_roughness_m: float = 0.03

## Site elevation above sea level (m); reduces air density per ISA.
@export_range(0.0, 4000.0, 10.0) var site_altitude_m: float = 0.0

## Long-term mean wind speed (m/s) at the anemometer height.
@export_range(0.0, 15.0, 0.1) var site_mean_wind_ms: float = 6.0

## Adds a deterministic diurnal cycle (afternoon peak) and slow gust
## variation around the site mean so output is not a flat line.
@export var enable_wind_variation: bool = true

## Fractional amplitude of the diurnal cycle (0.25 = ±25% around mean).
@export_range(0.0, 0.6, 0.01) var diurnal_amplitude: float = 0.25

## Fractional amplitude of the slow gust/lull variation.
@export_range(0.0, 0.6, 0.01) var gust_amplitude: float = 0.15
