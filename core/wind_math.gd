class_name WindMath
extends RefCounted

## Shared wind-direction helpers (meteorological FROM degrees → scene XZ drift).


## Downwind unit vector in scene XZ (0=N maps to -Z, 90=E → +X).
static func downwind_xz(from_deg: float) -> Vector2:
	if is_nan(from_deg):
		return Vector2(0.0, 1.0)
	var to_rad := deg_to_rad(from_deg + 180.0)
	return Vector2(sin(to_rad), cos(to_rad)).normalized()


## Sky shader `clouds_direction` / `cirrus_direction` uniform: fraction of full turn.
static func bearing_fraction(from_deg: float) -> float:
	if is_nan(from_deg):
		return 0.0
	var d := downwind_xz(from_deg)
	var ang := atan2(d.x, d.y)
	return ang / TAU


## Fold an extreme-weather HazardState into a measured (speed, gust) pair —
## the one place hazard wind reaches the vegetation shaders
## (VegetationWindDriver multiplies these in before pushing uniforms).
## HazardState invariant 1 holds by construction: blank() carries wind_mult
## 1.0 / gust_mult 1.0 / turbulence 0.0, so ordinary weather is bit-identical.
## A severity-1.0 damaging-winds event is wind_mult 2.6 / gust_mult 3.0
## (hazard_evaluators.gd) — before this the hazard was literally invisible in
## the canopy while the dust VFX blew sideways. `gust` is expected to already
## be floored at `speed` (the driver does that); turbulence lifts gusts
## further so a churning front reads as churn, not a steady lean.
static func apply_hazard_wind(speed_ms: float, gust_ms: float, hz: Dictionary) -> Vector2:
	var wind_mult := maxf(float(hz.get("wind_mult", 1.0)), 0.0)
	var gust_mult := maxf(float(hz.get("gust_mult", 1.0)), 0.0)
	var turbulence := clampf(float(hz.get("turbulence", 0.0)), 0.0, 1.0)
	var s := maxf(speed_ms, 0.0) * wind_mult
	var g := maxf(maxf(gust_ms, 0.0) * gust_mult, s)
	# Half-weight so gust_mult stays the governing channel — at full weight a
	# severity-1 event's turbulence floor (2× mean) out-shouted the profile's
	# own 3.0× gust multiplier and every hazard gusted identically.
	g = maxf(g, s * (1.0 + 0.5 * turbulence))
	return Vector2(s, g)


## Empirical veering for high-altitude wind when only 10 m data exists (archive years).
static func veered_from_deg(surface_from_deg: float, wind_speed_ms: float, latitude_deg: float) -> float:
	if is_nan(surface_from_deg):
		return surface_from_deg
	var veer := clampf(10.0 + wind_speed_ms * 2.0, 10.0, 35.0)
	if latitude_deg < 0.0:
		veer = -veer
	return fmod(surface_from_deg + veer + 360.0, 360.0)
