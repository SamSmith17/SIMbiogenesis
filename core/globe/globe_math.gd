class_name GlobeMath
extends RefCounted

## Pure maths for the 3D globe (Globe mode). Autoload-free so the selftest
## loads it under --script.
##
## Frame (earth-fixed, Earth radius = 1.0): +Y = the north pole, longitude 0
## on +Z, 90° E on +X:
##     p = (cos φ · sin λ, sin φ, cos φ · cos λ)
## Seen from outside above (0°, 0°), east is to the right and north is up.
## A sphere, not the WGS84 ellipsoid: at globe scale the 21 km flattening is
## invisible, and lat/lon round-trip exactly through these two functions.
## Coordinates cross APIs as 64-bit floats (PackedFloat64Array [lat, lon]),
## never Vector2: float32 holds a longitude only to ~1 m.

const EARTH_RADIUS_KM := 6371.0088   # IUGG mean radius
## Web Mercator's latitude limit (tile rows end here; the poles are caps).
const MERCATOR_MAX_LAT := 85.0511287798066


static func to_unit(lat_deg: float, lon_deg: float) -> Vector3:
	var la := deg_to_rad(lat_deg)
	var lo := deg_to_rad(lon_deg)
	var c := cos(la)
	return Vector3(c * sin(lo), sin(la), c * cos(lo))


## [lat, lon] degrees of a direction (any length > 0); lon in (-180, 180].
static func to_latlon(p: Vector3) -> PackedFloat64Array:
	var x := float(p.x)
	var y := float(p.y)
	var z := float(p.z)
	var h := sqrt(x * x + z * z)
	var lat := rad_to_deg(atan2(y, h))
	var lon := rad_to_deg(atan2(x, z)) if h > 1e-12 else 0.0
	return PackedFloat64Array([lat, lon])


## Unit east and north vectors at a point (the local tangent frame).
static func east_at(lon_deg: float) -> Vector3:
	var lo := deg_to_rad(lon_deg)
	return Vector3(cos(lo), 0.0, -sin(lo))


static func north_at(lat_deg: float, lon_deg: float) -> Vector3:
	return to_unit(lat_deg, lon_deg).cross(east_at(lon_deg)).normalized()


## Nearest positive t where origin + t·dir meets the sphere of radius r, or
## -1.0. `dir` need not be normalised.
static func ray_sphere(origin: Vector3, dir: Vector3, r: float = 1.0) -> float:
	var a := dir.dot(dir)
	if a < 1e-20:
		return -1.0
	var b := 2.0 * origin.dot(dir)
	var c := origin.dot(origin) - r * r
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return -1.0
	var s := sqrt(disc)
	var t0 := (-b - s) / (2.0 * a)
	var t1 := (-b + s) / (2.0 * a)
	if t0 > 0.0:
		return t0
	if t1 > 0.0:
		return t1
	return -1.0


## Great-circle distance in km (haversine).
static func great_circle_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := p2 - p1
	var dl := deg_to_rad(lon2 - lon1)
	var h := sin(dp * 0.5) * sin(dp * 0.5) + cos(p1) * cos(p2) * sin(dl * 0.5) * sin(dl * 0.5)
	return 2.0 * EARTH_RADIUS_KM * asin(minf(1.0, sqrt(h)))


## Spherical interpolation between two unit directions (t 0..1).
static func slerp_dir(a: Vector3, b: Vector3, t: float) -> Vector3:
	var d := clampf(a.dot(b), -1.0, 1.0)
	var ang := acos(d)
	if ang < 1e-9:
		return a.lerp(b, t).normalized()
	if absf(ang - PI) < 1e-6:
		# Antipodal: go round any perpendicular.
		var axis := a.cross(Vector3.UP)
		if axis.length() < 1e-6:
			axis = a.cross(Vector3.RIGHT)
		return a.rotated(axis.normalized(), ang * t)
	var s := sin(ang)
	return (a * (sin((1.0 - t) * ang) / s) + b * (sin(t * ang) / s)).normalized()


# --- Web Mercator tiles on the sphere ---------------------------------------

## Latitude of a Web Mercator row position, y_norm 0 (north edge) .. 1.
static func mercator_lat(y_norm: float) -> float:
	var n := PI * (1.0 - 2.0 * y_norm)
	return rad_to_deg(atan(0.5 * (exp(n) - exp(-n))))


## Row position 0..1 of a latitude (inverse of mercator_lat).
static func mercator_y(lat_deg: float) -> float:
	var la := deg_to_rad(clampf(lat_deg, -MERCATOR_MAX_LAT, MERCATOR_MAX_LAT))
	return 0.5 - log(tan(PI * 0.25 + la * 0.5)) / (2.0 * PI)


## [lat_north, lat_south, lon_west, lon_east] of tile (z, x, y).
static func tile_bounds(z: int, x: int, y: int) -> PackedFloat64Array:
	var n := float(1 << z)
	return PackedFloat64Array([
		mercator_lat(float(y) / n), mercator_lat(float(y + 1) / n),
		float(x) / n * 360.0 - 180.0, float(x + 1) / n * 360.0 - 180.0])


## Tile (z, x, y) holding a point.
static func tile_at(lat_deg: float, lon_deg: float, z: int) -> Vector3i:
	var n := 1 << z
	var x := int(floor((fposmod(lon_deg + 180.0, 360.0)) / 360.0 * float(n)))
	var y := int(floor(mercator_y(lat_deg) * float(n)))
	return Vector3i(z, clampi(x, 0, n - 1), clampi(y, 0, n - 1))


## Point on the unit sphere at tile-space (u, v) of tile (z, x, y).
static func tile_point(z: int, x: int, y: int, u: float, v: float) -> Vector3:
	var n := float(1 << z)
	var lon := (float(x) + u) / n * 360.0 - 180.0
	var lat := mercator_lat((float(y) + v) / n)
	return to_unit(lat, lon)


## The ancestor of a tile at zoom `z` (z <= key.x).
static func ancestor(key: Vector3i, z: int) -> Vector3i:
	var dz := key.x - z
	if dz <= 0:
		return key
	return Vector3i(z, key.y >> dz, key.z >> dz)


## UV rect (offset.xy, scale.zw) of `key` inside its ancestor `anc`.
static func uv_rect_in(key: Vector3i, anc: Vector3i) -> Vector4:
	var dz := key.x - anc.x
	if dz <= 0:
		return Vector4(0.0, 0.0, 1.0, 1.0)
	var s := 1.0 / float(1 << dz)
	var ox := float(key.y - (anc.y << dz)) * s
	var oy := float(key.z - (anc.z << dz)) * s
	return Vector4(ox, oy, s, s)


# --- Sun ------------------------------------------------------------------

static func jd_from_unix(unix_s: float) -> float:
	return unix_s / 86400.0 + 2440587.5


## The sub-solar point [lat, lon] at a UTC Julian Day: where the Sun is at the
## zenith. Low-precision solar coordinates from the Astronomical Almanac
## (Section C, "low precision formulas for the Sun", ~0.01°), with Meeus's
## GMST (StarSkyMath, eq. 12.4) for the hour angle.
static func subsolar_point(jd_utc: float) -> PackedFloat64Array:
	var n := jd_utc - 2451545.0
	var L := fposmod(280.460 + 0.9856474 * n, 360.0)
	var g := deg_to_rad(fposmod(357.528 + 0.9856003 * n, 360.0))
	var lam := deg_to_rad(L + 1.915 * sin(g) + 0.020 * sin(2.0 * g))
	var eps := deg_to_rad(23.439 - 0.0000004 * n)
	var ra := rad_to_deg(atan2(cos(eps) * sin(lam), cos(lam)))
	var dec := rad_to_deg(asin(sin(eps) * sin(lam)))
	var lon := fposmod(ra - StarSkyMath.gmst_deg(jd_utc) + 180.0, 360.0) - 180.0
	return PackedFloat64Array([dec, lon])


## Unit direction to the Sun in the globe frame.
static func sun_dir(jd_utc: float) -> Vector3:
	var s := subsolar_point(jd_utc)
	return to_unit(s[0], s[1])


## Solar elevation (degrees) of the globe-frame sun at a site. Geometric:
## no refraction.
static func solar_elevation_deg(lat_deg: float, lon_deg: float, jd_utc: float) -> float:
	return rad_to_deg(asin(clampf(to_unit(lat_deg, lon_deg).dot(sun_dir(jd_utc)), -1.0, 1.0)))


## Day length in hours at `lat_deg` from the subsolar latitude that day.
## 24 through the polar day, 0 through the polar night. Geometric horizon.
static func day_length_hours(lat_deg: float, jd_utc: float) -> float:
	var dec := deg_to_rad(subsolar_point(jd_utc)[0])
	var lat := deg_to_rad(clampf(lat_deg, -89.5, 89.5))
	var cos_ha := -tan(lat) * tan(dec)
	if cos_ha <= -1.0:
		return 24.0
	if cos_ha >= 1.0:
		return 0.0
	return rad_to_deg(acos(clampf(cos_ha, -1.0, 1.0))) / 7.5
