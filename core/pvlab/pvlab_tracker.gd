class_name PvLabTracker
extends RefCounted

## Single-axis tracker geometry. Pure.
##
## The axis points along compass azimuth `axis_az` (0 = N, 90 = E, 180 = S),
## tilted down toward it by `axis_tilt` (a 0° axis is horizontal; a polar
## axis in the north is axis_az 180, axis_tilt = latitude). At rotation 0 the
## modules face up, tipped toward axis_az by the axis tilt; a POSITIVE
## rotation tips them toward axis_az + 90° (west, for a north–south axis) —
## the convention of pvlib.tracking.singleaxis.
##
## The ideal rotation (true tracking, the sun's projection onto the plane
## perpendicular to the axis) is Marion & Dobos, "Rotation Angle for the
## Optimum Tracking of One-Axis Trackers", NREL/TP-6A20-58891 (2013), eq. 7:
##     R = atan2(sin θz · sin(γs − γa),
##               sin θz · cos(γs − γa) · sin βa + cos θz · cos βa)
## Backtracking rotates back toward flat when the next row would shade this
## one: with ground-coverage ratio GCR (collector width / row pitch), on level
## ground, Lorenzo, Narvarte & Muñoz, Prog. Photovolt. 19 (2011), as in pvlib
## (Anderson & Mikofski 2020 add the cross-axis slope, taken as 0 here):
##     R_bt = R − sign(R) · acos(min(cos R / GCR, 1))
## Below the horizon and in high wind the tracker STOWS at `stow_deg`.

const DEFAULTS := {"axis_tilt_deg": 0.0, "max_deg": 60.0, "backtrack": true, "stow_deg": 0.0,
	"night_deg": 0.0, "stow_wind_ms": 18.0}


static func resolve(t: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate()
	for k in t:
		out[k] = t[k]
	out["axis_tilt_deg"] = clampf(float(out["axis_tilt_deg"]), 0.0, 60.0)
	out["max_deg"] = clampf(float(out["max_deg"]), 5.0, 90.0)
	out["backtrack"] = bool(out["backtrack"])
	out["stow_deg"] = clampf(float(out["stow_deg"]), -60.0, 60.0)
	out["night_deg"] = clampf(float(out["night_deg"]), -60.0, 60.0)
	out["stow_wind_ms"] = clampf(float(out["stow_wind_ms"]), 3.0, 60.0)
	return out


## Ideal (true-tracking) rotation, degrees, for the sun at compass azimuth
## `sun_az` and elevation `sun_el` (degrees).
static func ideal_angle(sun_az: float, sun_el: float, axis_az: float, axis_tilt: float) -> float:
	var zen := deg_to_rad(90.0 - sun_el)
	var dg := deg_to_rad(sun_az - axis_az)
	var ba := deg_to_rad(axis_tilt)
	var x := sin(zen) * sin(dg)
	var y := sin(zen) * cos(dg) * sin(ba) + cos(zen) * cos(ba)
	return rad_to_deg(atan2(x, y))


## The tracker's rotation (degrees) at this sun: ideal, backtracked, clamped,
## stowed at night or past the stow wind. `gcr` = 0 means no backtracking.
static func angle_at(sun_az: float, sun_el: float, axis_az: float, t: Dictionary, gcr: float = 0.0,
		wind_ms: float = 0.0) -> float:
	var tr := resolve(t)
	if sun_el <= 0.0:
		return float(tr["night_deg"])
	if wind_ms >= float(tr["stow_wind_ms"]):
		return float(tr["stow_deg"])
	var r := ideal_angle(sun_az, sun_el, axis_az, float(tr["axis_tilt_deg"]))
	# A sun behind the plane of the axis's tilt (rare: tilted axis, sun at the
	# far end) gives |R| > 90°: face up rather than turn over.
	if absf(r) > 90.0:
		r = signf(r) * (180.0 - absf(r))
	if bool(tr["backtrack"]) and gcr > 0.0:
		r = backtrack(r, gcr)
	var mx := float(tr["max_deg"])
	return clampf(r, -mx, mx)


static func backtrack(r_ideal: float, gcr: float) -> float:
	var c := cos(deg_to_rad(r_ideal)) / maxf(gcr, 1e-6)
	if c >= 1.0:
		return r_ideal
	return r_ideal - signf(r_ideal) * rad_to_deg(acos(clampf(c, -1.0, 1.0)))


## Module face normal (world, CelestialClock frame: north −Z, east +X) at
## rotation `r_deg`.
static func normal_at(r_deg: float, axis_az: float, axis_tilt: float) -> Vector3:
	var ga := deg_to_rad(axis_az)
	var ba := deg_to_rad(axis_tilt)
	var n0 := Vector3(sin(ga) * sin(ba), cos(ba), -cos(ga) * sin(ba))
	var w := Vector3(sin(ga + PI * 0.5), 0.0, -cos(ga + PI * 0.5))
	var r := deg_to_rad(r_deg)
	return (n0 * cos(r) + w * sin(r)).normalized()


## {tilt_deg, azimuth_deg} of a world normal.
static func orientation_of(n: Vector3) -> Dictionary:
	var nn := n.normalized()
	var tilt := rad_to_deg(acos(clampf(nn.y, -1.0, 1.0)))
	var az := 180.0
	if Vector2(nn.x, nn.z).length() > 1e-5:
		az = fposmod(rad_to_deg(atan2(nn.x, -nn.z)), 360.0)
	return {"tilt_deg": tilt, "azimuth_deg": az}


## Unit vector toward the sun (world frame) from compass azimuth / elevation.
static func sun_vector(sun_az: float, sun_el: float) -> Vector3:
	var a := deg_to_rad(sun_az)
	var e := deg_to_rad(sun_el)
	return Vector3(sin(a) * cos(e), sin(e), -cos(a) * cos(e))
