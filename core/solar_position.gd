@tool
class_name SolarPosition

## High-precision solar position algorithm.
## Source: Jean Meeus, "Astronomical Algorithms", 2nd ed., Willmann-Bell (1998), Ch. 25.
## Accuracy: ~0.01° in azimuth and elevation — about 10× better than the simplified
## formula in CelestialClock.get_sun_direction().
##
## All functions are static; no Node or instantiation required.

const _DEG2RAD : float = PI / 180.0
const _RAD2DEG : float = 180.0 / PI


## Compute solar altitude and azimuth for a given observer and UTC Julian Day.
##
## lat_deg   Observer latitude  (−90 … +90, north positive)
## lon_deg   Observer longitude (−180 … +180, east positive)
## jd_utc    Julian Day Number in UTC
##
## Returns a Dictionary:
##   elevation_deg : altitude above horizon with atmospheric refraction (degrees)
##   azimuth_deg   : 0 = North, 90 = East, 180 = South, 270 = West (degrees)
##   cos_zenith    : max(0, sin(elevation)) — proportional to horizontal irradiance
static func get_position(lat_deg: float, lon_deg: float, jd_utc: float) -> Dictionary:
	var T : float = (jd_utc - 2451545.0) / 36525.0  # Julian centuries since J2000.0

	# Geometric mean longitude of the Sun (degrees)
	var L0 : float = 280.46646 + 36000.76983 * T + 0.0003032 * T * T
	L0 = fmod(L0, 360.0)
	if L0 < 0.0: L0 += 360.0

	# Sun's mean anomaly (degrees)
	var M : float = 357.52911 + 35999.05029 * T - 0.0001537 * T * T
	M = fmod(M, 360.0)
	if M < 0.0: M += 360.0
	var M_rad : float = M * _DEG2RAD

	# Equation of center
	var C : float = (1.914602 - 0.004817 * T - 0.000014 * T * T) * sin(M_rad) \
	              + (0.019993 - 0.000101 * T) * sin(2.0 * M_rad) \
	              + 0.000289 * sin(3.0 * M_rad)

	# Sun's true geometric longitude
	var sun_lon : float = L0 + C

	# Apparent longitude: nutation + aberration correction (Meeus eq. 25.10)
	var omega : float = 125.04 - 1934.136 * T
	var lam : float = sun_lon - 0.00569 - 0.00478 * sin(omega * _DEG2RAD)

	# Mean obliquity of the ecliptic (Meeus eq. 22.3, arcseconds → degrees)
	var eps0 : float = 23.0 + 26.0 / 60.0 + 21.448 / 3600.0 \
	                 - (46.8150 / 3600.0) * T \
	                 - (0.00059 / 3600.0) * T * T \
	                 + (0.001813 / 3600.0) * T * T * T
	# Apparent obliquity
	var eps : float = eps0 + 0.00256 * cos(omega * _DEG2RAD)

	var lam_rad : float = lam * _DEG2RAD
	var eps_rad : float = eps * _DEG2RAD

	# Sun's right ascension (0–360°)
	var alpha : float = atan2(cos(eps_rad) * sin(lam_rad), cos(lam_rad)) * _RAD2DEG
	if alpha < 0.0: alpha += 360.0

	# Sun's declination
	var sin_delta : float = clamp(sin(eps_rad) * sin(lam_rad), -1.0, 1.0)
	var delta     : float = asin(sin_delta) * _RAD2DEG

	# Greenwich Mean Sidereal Time (degrees, Meeus eq. 12.4)
	var GMST : float = 280.46061837 + 360.98564736629 * (jd_utc - 2451545.0) \
	                 + 0.000387933 * T * T - T * T * T / 38710000.0
	GMST = fmod(GMST, 360.0)
	if GMST < 0.0: GMST += 360.0

	# Local Hour Angle (normalised to −180 … +180)
	var H : float = fmod(GMST + lon_deg - alpha, 360.0)
	if H < 0.0: H += 360.0
	if H > 180.0: H -= 360.0

	var H_rad     : float = H     * _DEG2RAD
	var lat_rad   : float = lat_deg * _DEG2RAD
	var delta_rad : float = delta   * _DEG2RAD

	# Topocentric altitude (geometric, before refraction)
	var sin_alt : float = clamp(
		sin(lat_rad) * sin(delta_rad) + cos(lat_rad) * cos(delta_rad) * cos(H_rad),
		-1.0, 1.0)
	var alt_geo : float = asin(sin_alt) * _RAD2DEG

	# Atmospheric refraction — Bennett (1982), valid above −0.575°
	var alt_ref : float = alt_geo
	if alt_geo > -0.575:
		var x   : float = alt_geo + 10.3 / (alt_geo + 5.11)
		var ref : float = 1.02 / tan(x * _DEG2RAD) / 60.0  # degrees
		alt_ref = alt_geo + ref

	# Solar azimuth (0 = North, clockwise; same convention as CelestialClock)
	var cos_alt : float = cos(asin(sin_alt))
	var cos_az  : float = 0.0
	if abs(cos_alt) > 1e-6 and abs(cos(lat_rad)) > 1e-6:
		cos_az = clamp(
			(sin(delta_rad) - sin(lat_rad) * sin_alt) / (cos(lat_rad) * cos_alt),
			-1.0, 1.0)
	var az : float = acos(cos_az) * _RAD2DEG
	# H > 0 means hour angle is positive → afternoon → sun in western half of sky
	if H > 0.0: az = 360.0 - az

	return {
		"elevation_deg" : alt_ref,
		"azimuth_deg"   : az,
		"cos_zenith"    : maxf(sin(alt_ref * _DEG2RAD), 0.0)
	}


## Cosine of the angle between the sun and a tilted panel's normal vector.
## Returns 0.0 when the sun is behind the panel face.
##
## sun_az_deg    Solar azimuth (0=N, 90=E, 180=S, 270=W)
## sun_el_deg    Solar elevation above horizon (degrees)
## panel_az_deg  Direction the panel faces (0=N, 90=E, 180=S, 270=W)
## panel_tilt_deg Tilt from horizontal: 0 = flat, 90 = vertical wall
static func panel_cos_incidence(
		sun_az_deg   : float, sun_el_deg    : float,
		panel_az_deg : float, panel_tilt_deg : float) -> float:
	var sa : float = sun_az_deg    * _DEG2RAD
	var se : float = sun_el_deg    * _DEG2RAD
	var pa : float = panel_az_deg  * _DEG2RAD
	var pt : float = panel_tilt_deg * _DEG2RAD
	# Unit vector pointing from surface toward the sun
	var sx : float =  cos(se) * sin(sa)
	var sy : float =  sin(se)
	var sz : float = -cos(se) * cos(sa)
	# Panel normal vector (matches the convention in _get_panel_normal())
	var nx : float =  sin(pt) * sin(pa)
	var ny : float =  cos(pt)
	var nz : float = -sin(pt) * cos(pa)
	return maxf(sx * nx + sy * ny + sz * nz, 0.0)
