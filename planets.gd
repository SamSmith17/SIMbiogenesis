@tool
extends Node3D
class_name PlanetSystem

## Planet simulation system using Keplerian orbital elements
## Calculates accurate positions for visible planets: Mercury, Venus, Mars, Jupiter, Saturn

# ==================== PLANET VISUAL SETTINGS ====================

@export_group("Mercury")
@export var mercury_enabled: bool = true
@export var mercury_color: Color = Color(0.85, 0.85, 0.8, 1.0)
@export_range(0.0, 5.0, 0.1) var mercury_brightness: float = 1.0
@export_range(0.001, 0.02, 0.001) var mercury_size: float = 0.004
@export_range(0.0, 2.0, 0.05) var mercury_glow: float = 0.3
@export var mercury_glow_color: Color = Color(0.9, 0.9, 0.85, 1.0)

@export_group("Venus")
@export var venus_enabled: bool = true
@export var venus_color: Color = Color(1.0, 0.98, 0.9, 1.0)
@export_range(0.0, 5.0, 0.1) var venus_brightness: float = 2.5
@export_range(0.001, 0.02, 0.001) var venus_size: float = 0.008
@export_range(0.0, 2.0, 0.05) var venus_glow: float = 0.6
@export var venus_glow_color: Color = Color(1.0, 0.98, 0.85, 1.0)

@export_group("Mars")
@export var mars_enabled: bool = true
@export var mars_color: Color = Color(1.0, 0.6, 0.4, 1.0)
@export_range(0.0, 5.0, 0.1) var mars_brightness: float = 1.5
@export_range(0.001, 0.02, 0.001) var mars_size: float = 0.005
@export_range(0.0, 2.0, 0.05) var mars_glow: float = 0.4
@export var mars_glow_color: Color = Color(1.0, 0.7, 0.5, 1.0)

@export_group("Jupiter")
@export var jupiter_enabled: bool = true
@export var jupiter_color: Color = Color(1.0, 0.95, 0.85, 1.0)
@export_range(0.0, 5.0, 0.1) var jupiter_brightness: float = 2.0
@export_range(0.001, 0.02, 0.001) var jupiter_size: float = 0.007
@export_range(0.0, 2.0, 0.05) var jupiter_glow: float = 0.5
@export var jupiter_glow_color: Color = Color(1.0, 0.95, 0.8, 1.0)

@export_group("Saturn")
@export var saturn_enabled: bool = true
@export var saturn_color: Color = Color(1.0, 0.93, 0.75, 1.0)
@export_range(0.0, 5.0, 0.1) var saturn_brightness: float = 1.2
@export_range(0.001, 0.02, 0.001) var saturn_size: float = 0.006
@export_range(0.0, 2.0, 0.05) var saturn_glow: float = 0.35
@export var saturn_glow_color: Color = Color(1.0, 0.9, 0.7, 1.0)

# ==================== KEPLERIAN ORBITAL ELEMENTS ====================
# Elements at J2000.0 epoch (Jan 1, 2000, 12:00 TT)
# Format: [a, e, I, L, long_peri, long_node, da, de, dI, dL, dlong_peri, dlong_node]
# a = semi-major axis (AU), e = eccentricity, I = inclination (deg)
# L = mean longitude (deg), long_peri = longitude of perihelion (deg)
# long_node = longitude of ascending node (deg)
# d* = rate of change per century

const ORBITAL_ELEMENTS := {
	"mercury": {
		"a": 0.38709927, "e": 0.20563593, "I": 7.00497902,
		"L": 252.25032350, "long_peri": 77.45779628, "long_node": 48.33076593,
		"da": 0.00000037, "de": 0.00001906, "dI": -0.00594749,
		"dL": 149472.67411175, "dlong_peri": 0.16047689, "dlong_node": -0.12534081
	},
	"venus": {
		"a": 0.72333566, "e": 0.00677672, "I": 3.39467605,
		"L": 181.97909950, "long_peri": 131.60246718, "long_node": 76.67984255,
		"da": 0.00000390, "de": -0.00004107, "dI": -0.00078890,
		"dL": 58517.81538729, "dlong_peri": 0.00268329, "dlong_node": -0.27769418
	},
	"earth": {
		"a": 1.00000261, "e": 0.01671123, "I": -0.00001531,
		"L": 100.46457166, "long_peri": 102.93768193, "long_node": 0.0,
		"da": 0.00000562, "de": -0.00004392, "dI": -0.01294668,
		"dL": 35999.37244981, "dlong_peri": 0.32327364, "dlong_node": 0.0
	},
	"mars": {
		"a": 1.52371034, "e": 0.09339410, "I": 1.84969142,
		"L": -4.55343205, "long_peri": -23.94362959, "long_node": 49.55953891,
		"da": 0.00001847, "de": 0.00007882, "dI": -0.00813131,
		"dL": 19140.30268499, "dlong_peri": 0.44441088, "dlong_node": -0.29257343
	},
	"jupiter": {
		"a": 5.20288700, "e": 0.04838624, "I": 1.30439695,
		"L": 34.39644051, "long_peri": 14.72847983, "long_node": 100.47390909,
		"da": -0.00011607, "de": -0.00013253, "dI": -0.00183714,
		"dL": 3034.74612775, "dlong_peri": 0.21252668, "dlong_node": 0.20469106
	},
	"saturn": {
		"a": 9.53667594, "e": 0.05386179, "I": 2.48599187,
		"L": 49.95424423, "long_peri": 92.59887831, "long_node": 113.66242448,
		"da": -0.00125060, "de": -0.00050991, "dI": 0.00193609,
		"dL": 1222.49362201, "dlong_peri": -0.41897216, "dlong_node": -0.28867794
	}
}

const PREFS_PATH := "user://planet_prefs.cfg"
const PLANET_NAMES := ["mercury", "venus", "mars", "jupiter", "saturn"]

## Slerp rate (per second) for easing each rendered planet direction toward its
## freshly computed position. High enough to track fast motion at Max speed with
## only ~2° of lag, low enough to erase per-frame stepping. Discrete time jumps
## (date/location/analemma) snap instead of easing — see force_update() and the
## >90° guard in _smooth_render_directions().
const _SMOOTH_RATE : float = 16.0

# Reference to main scene for accessing time/location data
var main_scene: Node = null

# Cached planet directions (normalized vectors pointing to each planet)
var planet_directions := {
	"mercury": Vector3.UP,
	"venus": Vector3.UP,
	"mars": Vector3.UP,
	"jupiter": Vector3.UP,
	"saturn": Vector3.UP
}

# Cached planet altitudes (for visibility checks)
var planet_altitudes := {
	"mercury": 0.0,
	"venus": 0.0,
	"mars": 0.0,
	"jupiter": 0.0,
	"saturn": 0.0
}

# Rendered (smoothed) directions actually sent to the sky shader. planet_directions
# holds the instantaneous target; these ease toward it each frame so the planets
# glide instead of teleporting between updates at high time_scale.
var _render_directions := {
	"mercury": Vector3.UP,
	"venus": Vector3.UP,
	"mars": Vector3.UP,
	"jupiter": Vector3.UP,
	"saturn": Vector3.UP
}

func _ready() -> void:
	# Find main scene reference
	main_scene = get_parent()
	if main_scene == null or not main_scene.has_method("get_julian_day_utc"):
		# Try to find it in the tree
		main_scene = get_tree().get_first_node_in_group("main_scene")
	if not Engine.is_editor_hint():
		_load_prefs()
	if main_scene != null:
		update_all_planets()
		_snap_render_to_target()

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Recompute the true positions every frame (a handful of Kepler solves — cheap)
	# so planets are never stale, then ease the rendered directions toward them.
	# main.gd pushes these to the sky shader every frame, so the motion stays
	# continuous even at Max speed instead of jumping in coarse steps.
	if main_scene != null and main_scene.has_method("get_julian_day_utc"):
		update_all_planets()
	_smooth_render_directions(delta)

func force_update() -> void:
	# Discrete jump (date/location/analemma/save-load): recompute AND snap the
	# rendered directions so the planets don't slowly ease across the whole sky.
	if main_scene != null and main_scene.has_method("get_julian_day_utc"):
		update_all_planets()
	_snap_render_to_target()

## Copy the instantaneous targets into the rendered directions with no easing.
func _snap_render_to_target() -> void:
	for pname in PLANET_NAMES:
		_render_directions[pname] = planet_directions[pname]

## Ease each rendered direction toward its target along the great circle. Big
## jumps (>90°, e.g. a scrub that bypassed force_update) snap so we never rotate
## the long way round or lag on a teleport; small motion eases for smoothness.
func _smooth_render_directions(delta: float) -> void:
	var t : float = 1.0 - exp(-_SMOOTH_RATE * delta)
	for pname in PLANET_NAMES:
		var target : Vector3 = planet_directions[pname]
		var cur : Vector3 = _render_directions[pname]
		if cur.length_squared() < 1e-6 or cur.dot(target) <= 0.0:
			_render_directions[pname] = target
		else:
			_render_directions[pname] = cur.slerp(target, t)

func set_all_enabled(on: bool) -> void:
	for pname in PLANET_NAMES:
		set(pname + "_enabled", on)

func get_settings() -> Dictionary:
	var out := {}
	for pname in PLANET_NAMES:
		out[pname + "_enabled"] = get(pname + "_enabled")
		out[pname + "_color"] = get(pname + "_color")
		out[pname + "_brightness"] = get(pname + "_brightness")
		out[pname + "_size"] = get(pname + "_size")
		out[pname + "_glow"] = get(pname + "_glow")
		out[pname + "_glow_color"] = get(pname + "_glow_color")
	return out

func apply_settings(settings: Dictionary) -> void:
	for key in settings:
		if key in self:
			set(key, settings[key])

func save_prefs() -> void:
	var cfg := ConfigFile.new()
	var s := get_settings()
	for key in s:
		var v: Variant = s[key]
		if v is Color:
			var c: Color = v
			cfg.set_value("planets", key, [c.r, c.g, c.b, c.a])
		else:
			cfg.set_value("planets", key, v)
	cfg.save(PREFS_PATH)

func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return
	if not cfg.has_section("planets"):
		return
	for key in cfg.get_section_keys("planets"):
		var v: Variant = cfg.get_value("planets", key)
		if v is Array and (v as Array).size() >= 3:
			var a: Array = v
			set(key, Color(float(a[0]), float(a[1]), float(a[2]),
				float(a[3]) if a.size() >= 4 else 1.0))
		elif key in self:
			set(key, v)

## Update positions for all planets
func update_all_planets() -> void:
	if main_scene == null:
		return
	
	var jd_utc: float = main_scene.get_julian_day_utc()
	var lst: float = main_scene.get_local_sidereal_time(jd_utc)
	var latitude: float = main_scene.latitude
	
	for planet_name in ["mercury", "venus", "mars", "jupiter", "saturn"]:
		var result := calculate_planet_position(planet_name, jd_utc, lst, latitude)
		planet_directions[planet_name] = result.direction
		planet_altitudes[planet_name] = result.altitude

## Calculate a planet's position in the sky
func calculate_planet_position(planet_name: String, jd_utc: float, lst: float, latitude: float) -> Dictionary:
	# Get heliocentric coordinates for the planet and Earth
	var planet_helio := get_heliocentric_coords(planet_name, jd_utc)
	var earth_helio := get_heliocentric_coords("earth", jd_utc)
	
	# Convert to geocentric coordinates (relative to Earth)
	var geo_x: float = planet_helio.x - earth_helio.x
	var geo_y: float = planet_helio.y - earth_helio.y
	var geo_z: float = planet_helio.z - earth_helio.z
	
	# Convert to ecliptic longitude and latitude
	var ecl_lon: float = rad_to_deg(atan2(geo_y, geo_x))
	if ecl_lon < 0.0:
		ecl_lon += 360.0
	
	var distance: float = sqrt(geo_x * geo_x + geo_y * geo_y + geo_z * geo_z)
	var ecl_lat: float = rad_to_deg(asin(geo_z / distance))
	
	# Convert ecliptic to equatorial coordinates
	var equatorial := ecliptic_to_equatorial(ecl_lon, ecl_lat)
	
	# Convert to horizontal coordinates (altitude/azimuth)
	var horizontal := equatorial_to_horizontal(equatorial.ra, equatorial.dec, lst, latitude)
	
	# Convert to direction vector
	var direction := horizontal_to_direction(horizontal.altitude, horizontal.azimuth)
	
	return {
		"direction": direction,
		"altitude": horizontal.altitude,
		"azimuth": horizontal.azimuth,
		"ra": equatorial.ra,
		"dec": equatorial.dec
	}

## Get heliocentric coordinates for a body at given Julian Day
func get_heliocentric_coords(body_name: String, jd: float) -> Dictionary:
	var elements: Dictionary = ORBITAL_ELEMENTS[body_name]
	
	# Centuries since J2000.0
	var T: float = (jd - 2451545.0) / 36525.0
	
	# Calculate current orbital elements
	var a: float = elements.a + elements.da * T
	var e: float = elements.e + elements.de * T
	var I: float = elements.I + elements.dI * T
	var L: float = elements.L + elements.dL * T
	var long_peri: float = elements.long_peri + elements.dlong_peri * T
	var long_node: float = elements.long_node + elements.dlong_node * T
	
	# Argument of perihelion
	var omega: float = long_peri - long_node
	
	# Mean anomaly
	var M: float = L - long_peri
	M = fmod(M, 360.0)
	if M < 0.0:
		M += 360.0
	
	# Solve Kepler's equation for eccentric anomaly (iterative)
	var E: float = solve_kepler(deg_to_rad(M), e)
	
	# True anomaly
	var nu: float = 2.0 * atan2(
		sqrt(1.0 + e) * sin(E / 2.0),
		sqrt(1.0 - e) * cos(E / 2.0)
	)
	
	# Distance from Sun
	var r: float = a * (1.0 - e * cos(E))
	
	# Heliocentric coordinates in orbital plane
	var x_orb: float = r * cos(nu)
	var y_orb: float = r * sin(nu)
	
	# Convert to ecliptic coordinates
	var omega_rad: float = deg_to_rad(omega)
	var long_node_rad: float = deg_to_rad(long_node)
	var I_rad: float = deg_to_rad(I)
	
	var cos_omega: float = cos(omega_rad)
	var sin_omega: float = sin(omega_rad)
	var cos_node: float = cos(long_node_rad)
	var sin_node: float = sin(long_node_rad)
	var cos_I: float = cos(I_rad)
	var sin_I: float = sin(I_rad)
	
	var x_ecl: float = (cos_omega * cos_node - sin_omega * sin_node * cos_I) * x_orb + \
					   (-sin_omega * cos_node - cos_omega * sin_node * cos_I) * y_orb
	var y_ecl: float = (cos_omega * sin_node + sin_omega * cos_node * cos_I) * x_orb + \
					   (-sin_omega * sin_node + cos_omega * cos_node * cos_I) * y_orb
	var z_ecl: float = (sin_omega * sin_I) * x_orb + (cos_omega * sin_I) * y_orb
	
	return {"x": x_ecl, "y": y_ecl, "z": z_ecl}

## Solve Kepler's equation using Newton-Raphson iteration
func solve_kepler(M: float, e: float) -> float:
	var E: float = M + e * sin(M)  # Initial guess
	
	for i in range(10):  # Usually converges in 3-4 iterations
		var dE: float = (M - E + e * sin(E)) / (1.0 - e * cos(E))
		E += dE
		if abs(dE) < 1e-8:
			break
	
	return E

## Convert ecliptic coordinates to equatorial (RA/Dec)
func ecliptic_to_equatorial(ecl_lon: float, ecl_lat: float) -> Dictionary:
	# Obliquity of ecliptic (Earth's axial tilt) - approximately 23.44°
	var epsilon: float = 23.4392911  # More precise value at J2000
	if main_scene != null and "planet_axial_tilt" in main_scene:
		epsilon = main_scene.planet_axial_tilt
	
	var eps_rad: float = deg_to_rad(epsilon)
	var lon_rad: float = deg_to_rad(ecl_lon)
	var lat_rad: float = deg_to_rad(ecl_lat)
	
	# Convert to equatorial
	var sin_dec: float = sin(lat_rad) * cos(eps_rad) + cos(lat_rad) * sin(eps_rad) * sin(lon_rad)
	sin_dec = clamp(sin_dec, -1.0, 1.0)
	var dec: float = asin(sin_dec)
	
	var y: float = sin(lon_rad) * cos(eps_rad) - tan(lat_rad) * sin(eps_rad)
	var x: float = cos(lon_rad)
	var ra: float = atan2(y, x)
	
	# Convert to degrees
	var ra_deg: float = rad_to_deg(ra)
	if ra_deg < 0.0:
		ra_deg += 360.0
	
	return {"ra": ra_deg, "dec": rad_to_deg(dec)}

## Convert equatorial coordinates to horizontal (altitude/azimuth)
func equatorial_to_horizontal(ra: float, dec: float, lst: float, latitude: float) -> Dictionary:
	# Hour angle
	var ha: float = lst - ra
	while ha > 180.0:
		ha -= 360.0
	while ha < -180.0:
		ha += 360.0
	
	var ha_rad: float = deg_to_rad(ha)
	var dec_rad: float = deg_to_rad(dec)
	var lat_rad: float = deg_to_rad(latitude)
	
	# Calculate altitude
	var sin_alt: float = sin(lat_rad) * sin(dec_rad) + cos(lat_rad) * cos(dec_rad) * cos(ha_rad)
	sin_alt = clamp(sin_alt, -1.0, 1.0)
	var altitude: float = asin(sin_alt)
	
	# Calculate azimuth
	var cos_alt: float = cos(altitude)
	var cos_az: float = 0.0
	if abs(cos_alt) > 0.0001 and abs(cos(lat_rad)) > 0.0001:
		cos_az = (sin(dec_rad) - sin(lat_rad) * sin_alt) / (cos(lat_rad) * cos_alt)
		cos_az = clamp(cos_az, -1.0, 1.0)
	var azimuth: float = acos(cos_az)
	
	# Adjust azimuth for western sky
	if sin(ha_rad) > 0.0:
		azimuth = TAU - azimuth
	
	return {"altitude": rad_to_deg(altitude), "azimuth": rad_to_deg(azimuth)}

## Convert horizontal coordinates to direction vector
func horizontal_to_direction(altitude: float, azimuth: float) -> Vector3:
	var alt_rad: float = deg_to_rad(altitude)
	var az_rad: float = deg_to_rad(azimuth)
	
	var cos_alt: float = cos(alt_rad)
	var dir_x: float = cos_alt * sin(az_rad)
	var dir_y: float = sin(alt_rad)
	var dir_z: float = -cos_alt * cos(az_rad)
	
	return Vector3(dir_x, dir_y, dir_z).normalized()

## Get planet data for shader (called by main scene)
func get_shader_data() -> Dictionary:
	var directions: Array[Vector3] = []
	var colors: Array[Color] = []
	var sizes: Array[float] = []
	var enabled: Array[bool] = []
	var glows: Array[float] = []
	var glow_colors: Array[Color] = []
	
	# Mercury (directions use the eased _render_directions for smooth motion)
	directions.append(_render_directions.mercury)
	colors.append(mercury_color * mercury_brightness)
	sizes.append(mercury_size)
	enabled.append(mercury_enabled and planet_altitudes.mercury > -5.0)
	glows.append(mercury_glow)
	glow_colors.append(mercury_glow_color)
	
	# Venus
	directions.append(_render_directions.venus)
	colors.append(venus_color * venus_brightness)
	sizes.append(venus_size)
	enabled.append(venus_enabled and planet_altitudes.venus > -5.0)
	glows.append(venus_glow)
	glow_colors.append(venus_glow_color)
	
	# Mars
	directions.append(_render_directions.mars)
	colors.append(mars_color * mars_brightness)
	sizes.append(mars_size)
	enabled.append(mars_enabled and planet_altitudes.mars > -5.0)
	glows.append(mars_glow)
	glow_colors.append(mars_glow_color)
	
	# Jupiter
	directions.append(_render_directions.jupiter)
	colors.append(jupiter_color * jupiter_brightness)
	sizes.append(jupiter_size)
	enabled.append(jupiter_enabled and planet_altitudes.jupiter > -5.0)
	glows.append(jupiter_glow)
	glow_colors.append(jupiter_glow_color)
	
	# Saturn
	directions.append(_render_directions.saturn)
	colors.append(saturn_color * saturn_brightness)
	sizes.append(saturn_size)
	enabled.append(saturn_enabled and planet_altitudes.saturn > -5.0)
	glows.append(saturn_glow)
	glow_colors.append(saturn_glow_color)
	
	return {
		"directions": directions,
		"colors": colors,
		"sizes": sizes,
		"enabled": enabled,
		"glows": glows,
		"glow_colors": glow_colors
	}

## Get info about a specific planet (for UI/debugging)
func get_planet_info(planet_name: String) -> Dictionary:
	if planet_name not in planet_directions:
		return {}
	
	return {
		"direction": planet_directions[planet_name],
		"altitude": planet_altitudes[planet_name],
		"visible": planet_altitudes[planet_name] > 0.0
	}


