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


## Empirical veering for high-altitude wind when only 10 m data exists (archive years).
static func veered_from_deg(surface_from_deg: float, wind_speed_ms: float, latitude_deg: float) -> float:
	if is_nan(surface_from_deg):
		return surface_from_deg
	var veer := clampf(10.0 + wind_speed_ms * 2.0, 10.0, 35.0)
	if latitude_deg < 0.0:
		veer = -veer
	return fmod(surface_from_deg + veer + 360.0, 360.0)
