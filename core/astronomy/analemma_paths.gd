class_name AnalemmaPaths
extends RefCounted

## Sun, moon and planet paths for the globe, sampled the way the first-person
## analemma is: one point a day of a calendar year, at one mean solar hour,
## from a throwaway CelestialClock and PlanetSystem. Directions come back as
## unit vectors. The globe turns the sun and moon into the local sky; planets
## stay equatorial so they can ride the star field (GMST).
##
## auto_dst is off. A daylight-saving step would put a kink in the figure-8;
## the first-person trail uses the world's own clock, this preview does not.

const PLANETS := ["mercury", "venus", "mars", "jupiter", "saturn"]
## Radius (Earth radii) of the celestial sphere the planet paths are drawn
## on: far enough that a path reads as part of the sky, inside the Moon.
const SKY_R := 45.0
## The sky dome drawn over the orbit point, as a share of the camera range.
const DOME_SHARE := 0.11


static func is_leap(year: int) -> bool:
	return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)


## Mean solar hour (0..24) at longitude `lon` for a UTC Julian day.
## Local mean solar time = UTC + longitude/15.
static func mean_solar_hour(jd: float, lon_deg: float) -> float:
	var unix_s := (jd - 2440587.5) * 86400.0
	var utc_h := fmod(unix_s / 3600.0, 24.0)
	if utc_h < 0.0:
		utc_h += 24.0
	var h := fmod(utc_h + lon_deg / 15.0, 24.0)
	if h < 0.0:
		h += 24.0
	return h


static func year_of(jd: float) -> int:
	var unix_s := int((jd - 2440587.5) * 86400.0)
	return int(Time.get_datetime_dict_from_unix_time(unix_s).year)


## Horizon-frame unit directions (CelestialClock: +Y up, −Z north) of the
## sun at `mean_solar_hour` on each day of `year`.
static func sun_sky(lat: float, lon: float, year: int, mean_solar_hour: float) -> PackedVector3Array:
	var tc := _clock(lat, lon, year)
	var days := 366 if is_leap(year) else 365
	var out := PackedVector3Array()
	out.resize(days)
	for i in days:
		_set_doy(tc, i + 1)
		tc.day_time = tc.mean_solar_time_to_clock_time(mean_solar_hour)
		out[i] = tc.get_sun_direction()
	return out


## The moon, same days and hour as sun_sky.
static func moon_sky(lat: float, lon: float, year: int, mean_solar_hour: float) -> PackedVector3Array:
	var tc := _clock(lat, lon, year)
	var days := 366 if is_leap(year) else 365
	var out := PackedVector3Array()
	out.resize(days)
	for i in days:
		_set_doy(tc, i + 1)
		tc.day_time = tc.mean_solar_time_to_clock_time(mean_solar_hour)
		out[i] = tc.get_moon_direction()
	return out


## Equatorial unit vectors (StarSkyMath.equatorial_vector) per planet, same days.
static func planet_equatorial(lat: float, lon: float, year: int, mean_solar_hour: float) -> Dictionary:
	var tc := _clock(lat, lon, year)
	var ps := PlanetSystem.new()
	var days := 366 if is_leap(year) else 365
	var out := {}
	for pname in PLANETS:
		var pts := PackedVector3Array()
		pts.resize(days)
		out[pname] = {"points": pts, "color": ps.get(pname + "_color")}
	for i in days:
		_set_doy(tc, i + 1)
		tc.day_time = tc.mean_solar_time_to_clock_time(mean_solar_hour)
		var jd := tc.get_julian_day_utc()
		var lst := tc.get_local_sidereal_time(jd)
		for pname in PLANETS:
			var res: Dictionary = ps.calculate_planet_position(pname, jd, lst, lat)
			(out[pname].points as PackedVector3Array)[i] = StarSkyMath.equatorial_vector(
				float(res.ra), float(res.dec))
	ps.free()
	return out


## Subsolar ground track for the year centred on `jd` (same UTC time of day).
## Unit directions in the globe frame. The middle sample is `jd` itself.
static func subsolar_track(jd: float, days: int = 366) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(days)
	var half := int(days / 2)
	for i in days:
		var s := GlobeMath.subsolar_point(jd + float(i - half))
		out[i] = GlobeMath.to_unit(s[0], s[1])
	return out


## Sublunar ground track over one lunation, every 12 h, centred on `jd`.
static func sublunar_track(jd: float, samples: int = 60) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(samples)
	var half := int(samples / 2)
	for i in samples:
		var s := MoonGlobe.sublunar_point(jd + float(i - half) * 0.5)
		out[i] = GlobeMath.to_unit(s[0], s[1])
	return out


## Horizon direction (CelestialClock frame) to a globe-frame unit direction
## at a site.
static func horizon_to_globe(lat: float, lon: float, horizon: Vector3) -> Vector3:
	var up := GlobeMath.to_unit(lat, lon)
	var north := GlobeMath.north_at(lat, lon)
	var east := GlobeMath.east_at(lon)
	return (east * horizon.x + up * horizon.y - north * horizon.z).normalized()


## Equatorial (x = RA 0h, y = RA 6h, z = NCP) onto the globe frame at GMST.
## At GMST 0, RA 0 / dec 0 lands on +Z (longitude 0).
static func equatorial_to_globe(gmst_deg: float) -> Basis:
	var g := deg_to_rad(gmst_deg)
	var c := cos(g)
	var s := sin(g)
	return Basis(Vector3(-s, 0.0, c), Vector3(c, 0.0, s), Vector3(0.0, 1.0, 0.0))


## A line mesh through `points` (already in globe space) for
## globe_path.gdshader: two vertices per point, NORMAL = the tangent, UV.x =
## the side (-1 / +1), UV.y = the fraction along the path. Breaks the strip
## where a step is longer than `jump`, so a track that crosses the
## antimeridian does not slash across the disc. `closed` joins the last
## point back to the first.
static func line_mesh(points: PackedVector3Array, jump: float = 0.55, closed: bool = false) -> ArrayMesh:
	var pts := points
	if closed and points.size() > 2:
		pts = PackedVector3Array(points)
		pts.append(points[0])
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var run := 0
	var n := pts.size()
	for i in n:
		var p: Vector3 = pts[i]
		if p.length() < 1e-9:
			run = 0
			continue
		if run > 0 and pts[i - 1].distance_to(p) > jump:
			run = 0
		var prev: Vector3 = pts[i - 1] if i > 0 and pts[i - 1].distance_to(p) <= jump else p
		var nxt: Vector3 = pts[i + 1] if i + 1 < n and pts[i + 1].distance_to(p) <= jump else p
		var tangent := nxt - prev
		if tangent.length() < 1e-9:
			run = 0
			continue
		tangent = tangent.normalized()
		var along := float(i) / float(maxi(n - 1, 1))
		for side in [-1.0, 1.0]:
			verts.append(p)
			norms.append(tangent)
			uvs.append(Vector2(side, along))
		if run > 0:
			var b := verts.size() - 2
			idx.append_array(PackedInt32Array([b - 2, b - 1, b, b - 1, b + 1, b]))
		run += 1
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	if verts.size() >= 4 and idx.size() >= 3:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## Kept for older callers: the width now comes from the shader.
static func ribbon_mesh(points: PackedVector3Array, _half_width: float, jump: float = 0.55) -> ArrayMesh:
	return line_mesh(points, jump)


## The Moon's orbit over one lunation centred on `jd` (positions in the
## globe frame, Earth radii, at the true distance), every `step_days`.
## The Earth frame turns under it, so this is the Moon's path in the sky over
## the month as the globe draws it, not a fixed ellipse.
static func moon_orbit(jd: float, days: float = 27.32, step_days: float = 0.25) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := int(days / step_days) + 1
	var half := int(n / 2)
	for i in n:
		out.append(MoonGlobe.position(jd + float(i - half) * step_days))
	return out


## Equatorial unit vectors of a planet, one a day over `half_days` either
## side of `jd`, plus its position today ("now") and its colour.
static func planet_year(pname: String, jd: float, half_days: int = 183) -> Dictionary:
	var ps := PlanetSystem.new()
	var pts := PackedVector3Array()
	for k in range(-half_days, half_days + 1):
		var j := jd + float(k)
		var res: Dictionary = ps.calculate_planet_position(pname, j, 0.0, 0.0)
		pts.append(StarSkyMath.equatorial_vector(float(res.ra), float(res.dec)))
	var now_res: Dictionary = ps.calculate_planet_position(pname, jd, 0.0, 0.0)
	var col: Variant = ps.get(pname + "_color")
	var title := str(PlanetSystem.PLANET_TITLES.get(pname, pname.capitalize()))
	ps.free()
	return {"points": pts, "now": StarSkyMath.equatorial_vector(float(now_res.ra), float(now_res.dec)),
		"color": col if col is Color else Color.WHITE, "title": title}


## Day-of-year (0-based) of `jd` in its own year: where "today" sits on a
## year-long path sampled from 1 January.
static func doy_of(jd: float) -> int:
	var unix_s := int((jd - 2440587.5) * 86400.0)
	var d := Time.get_datetime_dict_from_unix_time(unix_s)
	var days := 0
	var y := int(d.year)
	var dim := [31, 29 if is_leap(y) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	for m in int(d.month) - 1:
		days += int(dim[m])
	return days + int(d.day) - 1


## The first day of each month as a fraction of the year (12 ticks).
static func month_fractions(year: int) -> PackedFloat32Array:
	var dim := [31, 29 if is_leap(year) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var total := 366.0 if is_leap(year) else 365.0
	var out := PackedFloat32Array()
	var acc := 0
	for m in 12:
		out.append(float(acc) / total)
		acc += int(dim[m])
	return out


static func _clock(lat: float, lon: float, year: int) -> CelestialClock:
	var tc := CelestialClock.new()
	tc.latitude = lat
	tc.longitude = lon
	tc.auto_dst = false
	tc.manual_dst = false
	tc.year = year
	return tc


static func _set_doy(tc: CelestialClock, doy: int) -> void:
	var m := 1
	var d := doy
	while m < 12:
		var dim := tc.get_days_in_month(m, tc.year)
		if d <= dim:
			break
		d -= dim
		m += 1
	tc.month = m
	tc.day = mini(d, tc.get_days_in_month(m, tc.year))
