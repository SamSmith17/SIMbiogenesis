#!/usr/bin/env python3
"""One-off generator for core/lunar_position.gd Meeus Ch.47 term tables."""

from pathlib import Path

LNG = [
    (6288774, 0, 0, 1, 0), (1274027, 2, 0, -1, 0), (658314, 2, 0, 0, 0), (213618, 0, 0, 2, 0),
    (-185116, 0, 1, 0, 0), (-114332, 0, 0, 0, 2), (58793, 2, 0, -2, 0), (57066, 2, -1, -1, 0),
    (53322, 2, 0, 1, 0), (45758, 2, -1, 0, 0), (-40923, 0, 1, -1, 0), (-34720, 0, 0, 1, 0),
    (-30383, 0, 1, 1, 0), (15327, 2, 0, 0, -2), (-12528, 0, 0, 1, 2), (10980, 0, 0, 1, -2),
    (10675, 0, 0, 4, 0), (10034, 0, 0, 3, 0), (8548, 0, 0, 4, -2), (-7888, 2, 1, -1, 0),
    (-6766, 2, 1, 0, 0), (-5163, 0, 0, 1, -1), (4987, 0, 1, 1, 0), (4036, 2, -1, 1, 0),
    (3994, 2, 0, 2, 0), (3861, 0, 0, 4, 0), (3665, 2, 0, -3, 0), (-2689, 0, 1, -2, 0),
    (-2602, 2, 0, -1, 2), (2390, 2, -1, -2, 0), (-2348, 0, 0, 1, 1), (2236, 2, -2, 0, 0),
    (-2120, 0, 1, 2, 0), (-2069, 2, 0, 0, 0), (2048, 2, -2, -1, 0), (-1773, 2, 0, 1, -2),
    (-1595, 2, 0, 0, 2), (1215, 0, 0, 1, -3), (-1110, 0, 0, 3, 1), (-892, 2, 0, -2, 0),
    (-810, 0, 1, 1, 1), (759, 2, -1, -2, 0), (-713, 2, 1, 0, -2), (-700, 0, 0, 3, -1),
    (691, 2, 1, 2, 0), (596, 2, -1, 0, -2), (549, 4, 0, 1, 0), (537, 0, 0, 4, 0),
    (520, 4, -1, 0, 0), (-487, 1, 0, -2, 0), (-399, 2, 0, 0, -2), (-381, 0, 0, 2, -2),
    (351, 1, 1, 1, 0), (-340, 3, 0, -2, 0), (330, 4, 0, -3, 0), (327, 2, -1, 2, 0),
    (-323, 0, 2, 1, 0), (299, 1, 1, -1, 0), (294, 2, 0, 3, 0),
]

LAT = [
    (5128122, 0, 0, 0, 1), (280602, 0, 0, 1, 1), (277693, 0, 0, 1, -1), (173237, 2, 0, 0, -1),
    (55413, 2, 0, 0, 1), (46271, 2, 0, 0, -1), (32573, 2, 0, 0, 1), (17198, 0, 0, 2, 1),
    (9266, 2, 0, 1, -1), (8822, 0, 0, 2, -1), (8216, 2, -1, 0, 0), (4324, 2, 0, 1, 1),
    (4200, 2, 0, 1, -1), (-3359, 2, 1, 0, 0), (2463, 2, -1, 0, -2), (2211, 2, 0, 0, -2),
    (2065, 2, 0, -1, 2), (-1870, 2, 0, -1, -2), (1828, 2, 0, 1, 2), (-1794, 2, 0, 1, -2),
    (-1749, 2, 0, -1, 0), (-1565, 2, 1, -1, 0), (-1491, 2, -1, 1, 0), (-1475, 2, 0, 0, 1),
    (-1410, 2, 0, -1, -1), (-1344, 2, 1, 1, 0), (-1335, 2, 1, 0, 0), (1107, 2, 0, -1, 1),
    (1021, 2, 0, 1, 0), (833, 2, 0, 0, -1), (777, 0, 0, 2, 0), (671, 2, 0, 1, -2),
    (607, 2, 0, -1, 2), (596, 2, -1, 0, 2), (491, 2, -1, 0, -2), (-451, 2, 0, 1, 2),
    (439, 2, 0, -1, -2), (422, 2, 0, 1, 1), (421, 2, 0, -1, 1), (-366, 2, 1, -1, -1),
    (-351, 2, 1, 0, 1), (331, 4, 0, 0, 1), (315, 2, -1, 1, 1), (302, 2, -2, 0, 0),
    (-283, 0, 0, 1, 3), (-229, 2, 1, 1, -1), (223, 1, 1, 0, -1), (223, 1, 1, 0, 1),
    (-220, 0, 1, -2, -1), (-220, 2, 1, -1, -1), (-185, 1, 0, 1, 1), (181, 2, -1, -2, -1),
    (-177, 0, 1, 2, 1), (176, 4, 0, -2, -1), (166, 4, -1, -1, -1), (-164, 1, 0, 1, -1),
    (132, 4, 0, 1, -1), (-119, 1, 0, -1, -1), (115, 4, -1, 0, -1), (107, 2, -2, 0, 1),
]

DIST = [
    (-20905355, 0, 0, 1, 0), (-3699111, 2, 0, -1, 0), (-2955968, 2, 0, 0, 0), (-569925, 0, 0, 2, 0),
    (48888, 0, 1, 0, 0), (-3149, 0, 0, 0, 2), (246158, 2, 0, -2, 0), (-152138, 2, -1, -1, 0),
    (-170733, 2, 0, 1, 0), (-204586, 2, -1, 0, 0), (-129620, 0, 1, -1, 0), (108743, 0, 0, 1, 0),
    (104755, 0, 1, 1, 0), (10321, 2, 0, 0, -2), (0, 0, 0, 1, 2), (79661, 2, 0, 2, 0),
    (-34782, 2, 0, 1, -2), (-23210, 2, 0, 1, 2), (-21636, 2, -1, 1, 0), (24208, 2, -1, -2, 0),
    (30824, 2, 1, 0, 0), (-8379, 2, 0, -2, 0), (-16675, 2, -1, 0, 2), (-12831, 2, -1, 0, -2),
    (-10445, 2, 1, -1, 0), (-11650, 4, 0, 1, 0), (14403, 4, -1, -1, 0), (-7003, 2, 1, 1, 0),
    (0, 4, 0, 0, 0), (10056, 2, -1, 2, 0), (6322, 2, 1, -2, 0), (-9884, 0, 0, 3, 1),
    (5751, 4, 0, -2, 0), (0, 2, 1, 0, 0), (-3958, 2, -2, 0, 0), (0, 2, 0, 1, 0),
    (3258, 4, -1, -1, 0), (2616, 0, 0, 1, -3), (-1897, 2, 0, -2, 0), (-2117, 2, 0, 0, 2),
    (2354, 2, 0, 2, 0), (0, 2, -1, 0, 0), (0, 1, 1, 0, 0), (-1423, 2, 0, 0, -2),
    (-1117, 0, 0, 2, -2), (-1571, 4, -1, 0, 0), (-1739, 0, 0, 0, 2), (0, 2, 0, -2, 0),
    (-4421, 2, 0, 0, -2), (0, 2, 0, 0, 2), (0, 0, 0, 1, 0), (1165, 2, 1, 0, -2),
    (0, 0, 0, 1, -2), (8752, 2, -1, 0, -2),
]


def emit_terms(name: str, rows: list) -> str:
    lines = [f"const _{name}_TERMS: Array = ["]
    for c, d, m, mp, f in rows:
        lines.append(f"\t[{c}, {d}, {m}, {mp}, {f}],")
    lines.append("]")
    return "\n".join(lines)


BODY = r'''class_name LunarPosition
extends RefCounted

## High-precision lunar position (Meeus "Astronomical Algorithms" Ch. 47).
## Accuracy ~0.01-0.1 deg — sufficient for solar-eclipse sky rendering and totality dimming.
## Not a substitute for Besselian-element shadow-path prediction.

const _DEG2RAD: float = PI / 180.0
const _RAD2DEG: float = 180.0 / PI
const _1E6: float = 1000000.0
const _EARTH_EQUATOR_KM: float = 6378.137
const _MOON_MEAN_DIST_KM: float = 385000.56
const _MOON_RADIUS_KM: float = 1737.4

'''


FUNCS = r'''
static func _poly(T: float, coeffs: Array) -> float:
	var r: float = 0.0
	var p: float = 1.0
	for c in coeffs:
		r += float(c) * p
		p *= T
	return r


static func _norm360(deg: float) -> float:
	deg = fmod(deg, 360.0)
	if deg < 0.0:
		deg += 360.0
	return deg


static func _eccentricity(T: float) -> float:
	return _poly(T, [1.0, -0.002516, -0.0000074])


static func _fundamentals(T: float) -> Dictionary:
	var Lp: float = _norm360(_poly(T, [218.3164477, 481267.88123421, -0.0015786, 1.0 / 538841.0, -1.0 / 65194000.0]))
	var D: float = _norm360(_poly(T, [297.8501921, 445267.1114034, -0.0018819, 1.0 / 545868.0, -1.0 / 113065000.0]))
	var M: float = _norm360(_poly(T, [357.5291092, 35999.0502909, -0.0001536, 1.0 / 24490000.0]))
	var Mp: float = _norm360(_poly(T, [134.9633964, 477198.8675055, 0.0087414, 1.0 / 69699.0, -1.0 / 14712000.0]))
	var F: float = _norm360(_poly(T, [93.2720950, 483202.0175233, -0.0036539, -1.0 / 3526000.0, 1.0 / 863310000.0]))
	return {"Lp": Lp, "D": D, "M": M, "Mp": Mp, "F": F, "E": _eccentricity(T)}


static func _nutation_longitude_deg(T: float) -> float:
	var omega: float = 125.04 - 1934.136 * T
	var L: float = 280.47 + 36000.77 * T
	var Lp: float = 218.32 + 481267.88 * T
	var dpsi_arcsec: float = -17.20 * sin(deg_to_rad(omega)) - 1.32 * sin(deg_to_rad(2.0 * L)) \
			- 0.23 * sin(deg_to_rad(2.0 * Lp)) + 0.21 * sin(deg_to_rad(2.0 * omega))
	return dpsi_arcsec / 3600.0


static func _obliquity_deg(T: float) -> float:
	var omega: float = 125.04 - 1934.136 * T
	var eps0: float = 23.0 + 26.0 / 60.0 + 21.448 / 3600.0 \
			- (46.8150 / 3600.0) * T - (0.00059 / 3600.0) * T * T + (0.001813 / 3600.0) * T * T * T
	return eps0 + 0.00256 * cos(deg_to_rad(omega))


static func _sigma_sin(terms: Array, D: float, M: float, Mp: float, F: float, E: float) -> float:
	var s: float = 0.0
	for row in terms:
		var coeff: float = float(row[0])
		var d: int = int(row[1])
		var m: int = int(row[2])
		var mp: int = int(row[3])
		var f: int = int(row[4])
		var arg: float = deg_to_rad(float(d) * D + float(m) * M + float(mp) * Mp + float(f) * F)
		var factor: float = pow(E, absf(float(m))) if m != 0 else 1.0
		s += coeff * factor * sin(arg)
	return s


static func _sigma_cos(terms: Array, D: float, M: float, Mp: float, F: float, E: float) -> float:
	var s: float = 0.0
	for row in terms:
		var coeff: float = float(row[0])
		var d: int = int(row[1])
		var m: int = int(row[2])
		var mp: int = int(row[3])
		var f: int = int(row[4])
		var arg: float = deg_to_rad(float(d) * D + float(m) * M + float(mp) * Mp + float(f) * F)
		var factor: float = pow(E, absf(float(m))) if m != 0 else 1.0
		s += coeff * factor * cos(arg)
	return s


static func geocentric_ecliptic(jd_utc: float) -> Dictionary:
	var T: float = (jd_utc - 2451545.0) / 36525.0
	var fund: Dictionary = _fundamentals(T)
	var Lp: float = fund.Lp
	var D: float = fund.D
	var M: float = fund.M
	var Mp: float = fund.Mp
	var F: float = fund.F
	var E: float = fund.E
	var sum_l: float = _sigma_sin(_LNG_TERMS, D, M, Mp, F, E)
	var sum_b: float = _sigma_sin(_LAT_TERMS, D, M, Mp, F, E)
	var sum_r: float = _sigma_cos(_DIST_TERMS, D, M, Mp, F, E)
	var venus: float = 3958.0 / _1E6 * sin(deg_to_rad(119.75 + 131.849 * T))
	var jupiter: float = 318.0 / _1E6 * sin(deg_to_rad(53.09 + 479264.29 * T))
	var flat: float = 1962.0 / _1E6 * sin(deg_to_rad(Lp - F))
	var lon: float = _norm360(Lp + sum_l / _1E6 + venus + jupiter + flat + _nutation_longitude_deg(T))
	var lat: float = sum_b / _1E6
	var dist_km: float = _MOON_MEAN_DIST_KM + sum_r / 1000.0
	return {"longitude": lon, "latitude": lat, "distance_km": dist_km}


static func ecliptic_to_equatorial(ecl_lon: float, ecl_lat: float, obliquity_deg: float) -> Dictionary:
	var eps: float = deg_to_rad(obliquity_deg)
	var lon: float = deg_to_rad(ecl_lon)
	var lat: float = deg_to_rad(ecl_lat)
	var sin_dec: float = clampf(sin(lat) * cos(eps) + cos(lat) * sin(eps) * sin(lon), -1.0, 1.0)
	var dec: float = asin(sin_dec)
	var y: float = sin(lon) * cos(eps) - tan(lat) * sin(eps)
	var x: float = cos(lon)
	var ra: float = atan2(y, x)
	var ra_deg: float = rad_to_deg(ra)
	if ra_deg < 0.0:
		ra_deg += 360.0
	return {"ra": ra_deg, "dec": rad_to_deg(dec)}


## Geocentric angular semidiameter (degrees) from distance.
static func angular_radius_deg(jd_utc: float) -> float:
	var geo: Dictionary = geocentric_ecliptic(jd_utc)
	var dist_km: float = maxf(float(geo.get("distance_km", _MOON_MEAN_DIST_KM)), 350000.0)
	return rad_to_deg(asin(_MOON_RADIUS_KM / dist_km))


static func _gmst_deg(jd_utc: float) -> float:
	var T: float = (jd_utc - 2451545.0) / 36525.0
	var gmst: float = 280.46061837 + 360.98564736629 * (jd_utc - 2451545.0) \
			+ 0.000387933 * T * T - T * T * T / 38710000.0
	return _norm360(gmst)


## Topocentric altitude/azimuth for observer (same azimuth convention as SolarPosition).
static func get_position(lat_deg: float, lon_deg: float, jd_utc: float) -> Dictionary:
	var T: float = (jd_utc - 2451545.0) / 36525.0
	var geo: Dictionary = geocentric_ecliptic(jd_utc)
	var obliq: float = _obliquity_deg(T)
	var eq: Dictionary = ecliptic_to_equatorial(float(geo.longitude), float(geo.latitude), obliq)
	var ra: float = float(eq.ra)
	var dec: float = float(eq.dec)
	var dist_km: float = float(geo.distance_km)

	var gmst: float = _gmst_deg(jd_utc)
	var H: float = gmst + lon_deg - ra
	H = fmod(H + 540.0, 360.0) - 180.0

	var lat_rad: float = deg_to_rad(lat_deg)
	var dec_rad: float = deg_to_rad(dec)
	var H_rad: float = deg_to_rad(H)

	var sin_alt: float = clampf(
		sin(lat_rad) * sin(dec_rad) + cos(lat_rad) * cos(dec_rad) * cos(H_rad),
		-1.0, 1.0)
	var alt_geo: float = asin(sin_alt)

	var cos_alt: float = cos(alt_geo)
	var cos_az: float = 0.0
	if absf(cos_alt) > 1e-6 and absf(cos(lat_rad)) > 1e-6:
		cos_az = clampf(
			(sin(dec_rad) - sin(lat_rad) * sin_alt) / (cos(lat_rad) * cos_alt),
			-1.0, 1.0)
	var az: float = acos(cos_az)
	if H > 0.0:
		az = TAU - az

	# Topocentric parallax lowers apparent altitude (Meeus Ch. 11 simplified).
	var hp: float = asin(_EARTH_EQUATOR_KM / dist_km)
	var parallax: float = asin(sin(hp) * cos(alt_geo))
	var alt_topo: float = alt_geo - parallax

	return {
		"elevation_deg": rad_to_deg(alt_topo),
		"azimuth_deg": rad_to_deg(az),
		"angular_radius_deg": angular_radius_deg(jd_utc),
		"distance_km": dist_km,
	}


static func direction_from_position(pos: Dictionary) -> Vector3:
	return SolarPosition.direction_from_horizon(float(pos.azimuth_deg), float(pos.elevation_deg))
'''


def main() -> None:
    out = Path(__file__).resolve().parents[1] / "core" / "lunar_position.gd"
    text = "\n\n".join([
        BODY.strip(),
        emit_terms("LNG", LNG),
        emit_terms("LAT", LAT),
        emit_terms("DIST", DIST),
        FUNCS.strip(),
    ]) + "\n"
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out} ({len(text)} bytes)")


if __name__ == "__main__":
    main()
