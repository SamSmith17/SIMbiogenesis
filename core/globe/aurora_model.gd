class_name AuroraModel
extends RefCounted

## Where the aurora is, as a pure function of the geomagnetic Kp index and
## the time (through the Sun's direction), for the globe's aurora layer, the
## ground sky and the point card. core/globe/aurora.gdshaderinc is its
## line-for-line MIRROR (constants and the oval); globe_selftest parses the
## include's constants and fails if they drift apart.
##
## - Geomagnetic frame: a centred dipole, its north pole at POLE_LAT /
##   POLE_LON (IGRF-14, epoch 2025: 80.8° N, 72.6° W). Magnetic latitude
##   from the dipole axis; magnetic local time from the angle round the axis
##   between the point and the sub-solar point (noon = toward the Sun).
## - The oval (both hemispheres, mirrored): its equatorward edge at magnetic
##   midnight is EQ_MID0 − EQ_PER_KP·Kp (Kp 3 → 59°, Kp 6 → 53°, Kp 9 →
##   46°: the usual "Kp → how far south" rule of thumb), EQ_NOON higher on
##   the day side; its width grows with Kp and is thinnest at noon; it is
##   brightest toward midnight. This is a simplified Feldstein-oval shape fit
##   to those rules of thumb, not a physics model — for the real thing near
##   the present the layer uses NOAA SWPC's OVATION nowcast instead.
## - Strength ~0..1.5; ~0.2 is about where a dark-sky eye starts to see it.

const POLE_LAT := 80.8
const POLE_LON := -72.6
const EQ_MID0 := 66.0
const EQ_PER_KP := 2.2
const EQ_NOON := 9.0
const WIDTH0 := 4.0
const WIDTH_PER_KP := 0.6
## Earth's radius and the green line's emission height, km.
const R_KM := 6371.0
const H_GREEN_KM := 110.0
## Strength a dark-sky eye can see.
const VISIBLE := 0.2
## OVATION probability (%) that maps to a strength of 1.
const OVATION_FULL := 30.0
## OVATION probability (%) below which nothing is drawn.
const OVATION_MIN := 5.0


static func pole_dir() -> Vector3:
	return GlobeMath.to_unit(POLE_LAT, POLE_LON)


## Magnetic latitude of a unit direction, degrees (+ north).
static func mag_lat(p: Vector3, pole: Vector3 = pole_dir()) -> float:
	return rad_to_deg(asin(clampf(p.dot(pole), -1.0, 1.0)))


## Angle from magnetic midnight, radians in [0, PI]: 0 = midnight (away from
## the Sun round the dipole axis), PI = noon.
static func from_midnight(p: Vector3, sun: Vector3, pole: Vector3 = pole_dir()) -> float:
	var a := p - pole * p.dot(pole)
	var s := sun - pole * sun.dot(pole)
	if a.length() < 1e-6 or s.length() < 1e-6:
		return 0.0
	var c := clampf(a.normalized().dot(s.normalized()), -1.0, 1.0)
	return PI - acos(c)


## The equatorward edge of the oval at this angle from midnight, magnetic
## latitude (degrees, absolute).
static func edge_lat(kp: float, phi: float) -> float:
	return EQ_MID0 - EQ_PER_KP * kp + EQ_NOON * 0.5 * (1.0 - cos(phi))


static func width(kp: float, phi: float) -> float:
	return (WIDTH0 + WIDTH_PER_KP * kp) * (0.55 + 0.45 * cos(phi))


## The oval's brightness at a unit direction (both hemispheres).
static func strength(p: Vector3, kp: float, sun: Vector3, pole: Vector3 = pole_dir()) -> float:
	var ml := absf(mag_lat(p, pole))
	var phi := from_midnight(p, sun, pole)
	var w := width(kp, phi)
	var c := edge_lat(kp, phi) + 0.5 * w
	var x := (ml - c) / (0.5 * w)
	var bright := clampf((kp + 0.5) / 5.0, 0.15, 1.6) * (0.55 + 0.45 * cos(phi))
	return bright * exp(-2.0 * x * x)


## The ground distance (km) at which a ray at elevation `elev_deg` reaches
## height `h_km`.
static func ground_km(elev_deg: float, h_km: float = H_GREEN_KM) -> float:
	var e := deg_to_rad(elev_deg)
	var g := acos(clampf(R_KM * cos(e) / (R_KM + h_km), -1.0, 1.0)) - e
	return g * R_KM


## The unit direction `km` away from `p` toward the bearing (degrees from
## north, clockwise).
static func offset(p: Vector3, bearing_deg: float, km: float) -> Vector3:
	var ll := GlobeMath.to_latlon(p)
	var north := GlobeMath.north_at(ll[0], ll[1])
	var east := GlobeMath.east_at(ll[1])
	var b := deg_to_rad(bearing_deg)
	var g := km / R_KM
	return (p * cos(g) + (north * cos(b) + east * sin(b)) * sin(g)).normalized()


## Can the aurora be seen from here: "overhead", "high in the sky",
## "low toward the pole" or "" — from the strength overhead and at the
## ground points a 10° and a 30° ray toward the magnetic pole reach.
static func seen_from(lat: float, lon: float, kp: float, sun: Vector3) -> String:
	var p := GlobeMath.to_unit(lat, lon)
	var pole := pole_dir()
	if strength(p, kp, sun, pole) >= VISIBLE:
		return "overhead"
	var toward := 0.0 if mag_lat(p, pole) >= 0.0 else 180.0
	var north := GlobeMath.north_at(lat, lon)
	var east := GlobeMath.east_at(lon)
	var target := pole if mag_lat(p, pole) >= 0.0 else -pole
	var t := target - p * target.dot(p)
	if t.length() > 1e-6:
		toward = wrapf(rad_to_deg(atan2(t.dot(east), t.dot(north))), 0.0, 360.0)
	if strength(offset(p, toward, ground_km(30.0)), kp, sun, pole) >= VISIBLE:
		return "high in the sky"
	if strength(offset(p, toward, ground_km(8.0)), kp, sun, pole) >= VISIBLE:
		return "low toward the pole"
	return ""


## NOAA's G scale from Kp (G1 = Kp 5 … G5 = Kp 9), "" below.
static func g_scale(kp: float) -> String:
	if kp < 4.67:
		return ""
	return "G%d" % clampi(int(floorf(kp + 0.34)) - 4, 1, 5)
