class_name VehicleTow
extends RefCounted

## A trailer behind a living vehicle: the one-axle trailer model. The axle
## rolls without slipping sideways, so every step it is pulled straight toward
## the hitch and stays its tongue length L behind it (the tractrix). A tow
## vehicle driving a circle of radius R at the hitch leaves the trailer's axle
## on the smaller circle sqrt(R² − L²) — the off-tracking a driver swings wide
## for. Pure; PlacedVehicle moves the trailer's prop with it.
##
## Frame: vehicle-local like VehicleDesign (−Z the front). A drivable design
## carries `hitch` (a ball just behind its rear bumper); a trailer carries
## `coupler` (the tongue's tip, at its front) and `axle_z` (the middle of its
## axles), all vehicle-local.

## How close the hitch ball must come to a parked trailer's coupler to hitch.
const HITCH_TOL_M := 0.8
## Backing up to a trailer: slower than this to hitch it.
const HITCH_MAX_SPEED := 1.5
## Never let a trailer fold back onto the tow vehicle (a jackknife) further
## than this between the two headings.
const MAX_ARTICULATION_DEG := 80.0


## Coupler to axle centre: the trailer's effective tongue length.
static func tongue_m(trailer: Dictionary) -> float:
	var c: Vector3 = trailer.get("coupler", Vector3.ZERO)
	return absf(float(trailer.get("axle_z", 0.0)) - c.z)


## One step: the axle pulled toward the hitch, `l` behind it (2-D xz).
static func step_axle(hitch: Vector2, axle: Vector2, l: float) -> Vector2:
	var d := hitch - axle
	if d.length() < 1e-6:
		return axle
	return hitch - d.normalized() * l


## The same, with the trailer kept from folding past MAX_ARTICULATION_DEG off
## the tow vehicle's heading `tow_fwd` (unit, xz).
static func step_axle_limited(hitch: Vector2, axle: Vector2, l: float, tow_fwd: Vector2) -> Vector2:
	var a := step_axle(hitch, axle, l)
	var fwd := (hitch - a).normalized()
	if tow_fwd.length() < 1e-6 or fwd.length() < 1e-6:
		return a
	var ang := tow_fwd.angle_to(fwd)
	var lim := deg_to_rad(MAX_ARTICULATION_DEG)
	if absf(ang) <= lim:
		return a
	var f2 := tow_fwd.rotated(signf(ang) * lim)
	return hitch - f2.normalized() * l


## The yaw (Godot rotation.y) that points a vehicle's front (−Z) along `fwd`.
static func yaw_for(fwd: Vector2) -> float:
	return atan2(-fwd.x, -fwd.y)


## Where the trailer's origin goes (xz) and its yaw, with its coupler on the
## hitch and its axle at `axle`.
static func trailer_pose(trailer: Dictionary, hitch: Vector2, axle: Vector2) -> Dictionary:
	var fwd := (hitch - axle)
	fwd = fwd.normalized() if fwd.length() > 1e-6 else Vector2(0, -1)
	var c: Vector3 = trailer.get("coupler", Vector3.ZERO)
	# A local point at z lies at origin − fwd·z (local +Z is backward).
	var origin := hitch + fwd * c.z
	return {"origin": origin, "yaw": yaw_for(fwd), "fwd": fwd}


## The axle (xz) of a trailer standing at `origin` with yaw `yaw`.
static func axle_at(trailer: Dictionary, origin: Vector2, yaw: float) -> Vector2:
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	return origin - fwd * float(trailer.get("axle_z", 0.0))


## A local point on a vehicle standing at `origin` (xz) with yaw `yaw`, in xz.
static func world_xz(local: Vector3, origin: Vector2, yaw: float) -> Vector2:
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(cos(yaw), -sin(yaw))
	return origin + right * local.x - fwd * local.z


## The steady circle a trailer's axle settles on behind a hitch going round a
## circle of radius `r_hitch`.
static func steady_axle_radius(r_hitch: float, l: float) -> float:
	return sqrt(maxf(r_hitch * r_hitch - l * l, 0.0))
