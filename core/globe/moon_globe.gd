class_name MoonGlobe
extends RefCounted

## The Moon beside the Earth globe, and as the body the camera orbits. It
## stands at its TRUE distance (Meeus Ch. 47: 56-64 Earth radii over the
## month) at the true size ratio, near side toward Earth (mean lock, no
## libration). From the globe's opening view it is a 14-pixel disc, as it is
## in the real sky. Solar irradiance on it is the clear-sky cosine law: there
## is no air. The 2026-11-07 first cut parked it 3.2 radii out "so it would
## be in frame", which made it look like a second planet.

const RADIUS_KM := 1737.4
const RADIUS_RATIO := RADIUS_KM / 6371.0088
const MEAN_DISTANCE_KM := 384400.0
const CREDIT := "Moon: NASA LRO / SVS"
## Public-domain LRO wide-angle colour mosaic (NASA SVS #4720), the 4k cut,
## with the 1k behind it.
const COLOR_URL := "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_poles_4k.jpg"
const COLOR_URL_SMALL := "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_poles_1k.jpg"
const CACHE := "user://globe_cache/moon_color_4k.jpg"
const CACHE_SMALL := "user://globe_cache/moon_color.jpg"
const PHASE_NAMES := ["New Moon", "Waxing crescent", "First quarter", "Waxing gibbous",
	"Full Moon", "Waning gibbous", "Last quarter", "Waning crescent"]


static func earth_scale() -> float:
	return 1.0 / RADIUS_RATIO


## Geocentric distance, km.
static func distance_km(jd: float) -> float:
	return maxf(float(LunarPosition.geocentric_ecliptic(jd).get("distance_km", MEAN_DISTANCE_KM)), 300000.0)


## Where the Moon's centre is in the globe frame (Earth radii).
static func position(jd: float) -> Vector3:
	return direction(jd) * (distance_km(jd) / 6371.0088)


## The Earth's distance from the Moon in MOON radii (the companion's place
## when the camera orbits the Moon).
static func earth_distance_moon_radii(jd: float) -> float:
	return distance_km(jd) / RADIUS_KM


## Illuminated fraction (0..1), the elongation (degrees, 0 = new, 180 =
## full), the name of the phase and whether it is waxing.
static func phase(jd: float) -> Dictionary:
	var m := direction(jd)
	var s := GlobeMath.sun_dir(jd)
	var elong := rad_to_deg(acos(clampf(m.dot(s), -1.0, 1.0)))
	var lit := 0.5 * (1.0 - cos(deg_to_rad(elong)))
	# Waxing when the Moon is east of the Sun (ahead of it in the sky, as the
	# Earth turns): sun x moon along the north pole.
	var waxing := s.cross(m).y >= 0.0
	var age_deg := elong if waxing else 360.0 - elong
	var idx := int(floor((age_deg + 22.5) / 45.0)) % 8
	return {"lit": lit, "elongation": elong, "waxing": waxing, "name": PHASE_NAMES[idx],
		"age_days": age_deg / 360.0 * 29.53}


## [lat, lon] where the Moon is overhead on the Earth. Declination, and
## RA − GMST with the same longitude wrap as GlobeMath.subsolar_point.
static func sublunar_point(jd: float) -> PackedFloat64Array:
	var eq := LunarPosition.equatorial(jd)
	var lon := fposmod(float(eq.ra) - StarSkyMath.gmst_deg(jd) + 180.0, 360.0) - 180.0
	return PackedFloat64Array([float(eq.dec), lon])


## Geocentric unit direction of the Moon in the globe frame.
static func direction(jd: float) -> Vector3:
	var s := sublunar_point(jd)
	return GlobeMath.to_unit(s[0], s[1])


## Moon body axes in the globe frame. Columns: east, north, prime meridian.
## The prime meridian points at Earth (mean lock). North is celestial north
## projected off that axis.
static func basis(jd: float) -> Basis:
	var earth_from_moon := -direction(jd)
	var north := Vector3.UP - earth_from_moon * Vector3.UP.dot(earth_from_moon)
	if north.length() < 1e-6:
		north = Vector3.RIGHT
	north = north.normalized()
	var east := north.cross(earth_from_moon).normalized()
	north = earth_from_moon.cross(east).normalized()
	return Basis(east, north, earth_from_moon)


## Sun direction in the Moon's body frame (the daily spin of the Earth frame
## cancels; what remains walks around once a month).
static func sun_body(jd: float) -> Vector3:
	return (basis(jd).inverse() * GlobeMath.sun_dir(jd)).normalized()


## Selenographic [lat, lon] of the subsolar point, body frame = globe frame
## (+Y north, lon 0 on +Z, the face toward Earth).
static func subsolar_latlon(jd: float) -> PackedFloat64Array:
	var s := sun_body(jd)
	return PackedFloat64Array([
		rad_to_deg(asin(clampf(s.y, -1.0, 1.0))),
		rad_to_deg(atan2(s.x, s.z)),
	])


## Clear-sky irradiance, W/m², on a body-frame unit normal.
static func irradiance(normal_body: Vector3, sun_b: Vector3) -> float:
	return SolarIrradiance.SOLAR_CONSTANT * maxf(0.0, normal_body.normalized().dot(sun_b.normalized()))


## Irradiance at a selenographic point.
static func irradiance_at(lat: float, lon: float, jd: float) -> float:
	return irradiance(GlobeMath.to_unit(lat, lon), sun_body(jd))


## Subsolar ground track on the Moon over one lunation, one sample a day,
## centred on `jd`. Unit directions in the body frame.
static func subsolar_track(jd: float, days: int = 30) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(days)
	var half := int(days / 2)
	for i in days:
		var s := subsolar_latlon(jd + float(i - half))
		out[i] = GlobeMath.to_unit(s[0], s[1])
	return out
