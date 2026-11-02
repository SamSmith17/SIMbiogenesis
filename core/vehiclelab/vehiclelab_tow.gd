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
## Receiver hitch classes (SAE J684): the gross trailer weight each is rated
## for and the tongue weight it takes (a tenth of it). A chassis' tow
## rating picks the class a builder would fit.
const HITCH_CLASSES := [
	{"name": "Class II", "gtw_kg": 3500.0 * 0.45359237, "tongue_kg": 350.0 * 0.45359237},
	{"name": "Class III", "gtw_kg": 8000.0 * 0.45359237, "tongue_kg": 800.0 * 0.45359237},
	{"name": "Class IV", "gtw_kg": 10000.0 * 0.45359237, "tongue_kg": 1000.0 * 0.45359237},
	{"name": "Class V", "gtw_kg": 20000.0 * 0.45359237, "tongue_kg": 2000.0 * 0.45359237},
]
## A ball more than this above or below the coupler wants a drop / rise hitch.
const HITCH_HEIGHT_TOL_M := 0.08


## The hitch class a chassis rated to tow `tow_kg` carries.
static func hitch_class_for(tow_kg: float) -> Dictionary:
	for hc in HITCH_CLASSES:
		if tow_kg <= float((hc as Dictionary)["gtw_kg"]) + 1.0:
			return hc
	return HITCH_CLASSES[HITCH_CLASSES.size() - 1]


## Can this vehicle tow that trailer? Every rating the sheets give, as
## {level, text} notes (empty = nothing to say): the trailer's loaded mass
## against the tow rating, the pair against the GCWR, the tongue against the
## hitch class, the trailer's brakes, and the ball vs coupler heights.
static func tow_check(tow: Dictionary, trailer: Dictionary) -> Array:
	var out: Array = []
	if tow.is_empty() or trailer.is_empty():
		return out
	var tow_kg := float(tow.get("tow_kg", 0.0))
	var t_mass := float(trailer.get("laden_out_kg", trailer.get("laden_kg", 0.0)))
	if tow_kg <= 0.0:
		out.append({"level": "warn", "text": "%s is not rated to tow." % str(tow.get("name", "The tow vehicle"))})
	elif t_mass > tow_kg:
		out.append({"level": "warn", "text": "The trailer weighs %d kg loaded; %s is rated to tow %d." %
			[int(t_mass), str(tow.get("name", "the tow vehicle")), int(tow_kg)]})
	var gcwr := float(tow.get("gcwr_kg", 0.0))
	var pair := float(tow.get("laden_kg", 0.0)) + t_mass
	if gcwr > 0.0 and pair > gcwr:
		out.append({"level": "warn", "text": "Together %d kg, over the %d kg combination rating." % [int(pair), int(gcwr)]})
	var hc := hitch_class_for(tow_kg)
	var tongue := float(trailer.get("tongue_kg", 0.0))
	if tow_kg > 0.0 and tongue > float(hc["tongue_kg"]):
		out.append({"level": "warn", "text": "%d kg on the tongue: a %s hitch takes %d." %
			[int(tongue), str(hc["name"]), int(float(hc["tongue_kg"]))]})
	if t_mass > VehicleDesign.TRAILER_BRAKES_KG and not bool(trailer.get("brakes", false)):
		out.append({"level": "warn", "text": "A trailer this heavy needs its own brakes."})
	if tow.has("hitch") and trailer.has("coupler"):
		var dh := (tow["hitch"] as Vector3).y - (trailer["coupler"] as Vector3).y
		if absf(dh) > HITCH_HEIGHT_TOL_M:
			out.append({"level": "info", "text": "The ball sits %d cm %s the coupler: use a %s hitch." %
				[int(round(absf(dh) * 100.0)), "above" if dh > 0.0 else "below", "drop" if dh > 0.0 else "rise"]})
	return out


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
