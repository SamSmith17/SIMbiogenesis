class_name MoverProgram
extends RefCounted

## Moving-head (DMX "mover") geometry and sweep programs — pure.
##
## FIXTURE FRAME: the base's local +Y is its mounting axis (the surface normal
## it was placed on — up for a floor fixture, down when hung from a truss).
## The yoke PANS about +Y, the head TILTS away from it:
##   tilt 0  = beam straight along +Y,
##   tilt 90 = beam horizontal toward the base's −Z at pan 0.
##   dir(pan, tilt) = (−sin t·sin p, cos t, −sin t·cos p)
## That is the node hierarchy PlacedMoverLight builds (yoke.rotation.y = pan,
## head.rotation.x = 90° − tilt, light along the head's −Z), pinned by the
## selftest so the maths and the scene cannot disagree.
##
## PROGRAMS run on the shared PlacedLightClock, so fixtures sweep in step;
## `phase_deg` offsets one fixture within a set (the dock's "Fan phases" spreads
## a selection evenly, which is how a row of beams makes a fan).

const PROGRAMS: Array[String] = ["static", "pan_sweep", "tilt_sweep", "circle", "figure8", "wander"]


static func direction(pan_deg: float, tilt_deg: float) -> Vector3:
	var p := deg_to_rad(pan_deg)
	var t := deg_to_rad(tilt_deg)
	return Vector3(-sin(t) * sin(p), cos(t), -sin(t) * cos(p))


## Inverse of direction(): the pan/tilt (degrees) that aims along `dir`
## (fixture-local). Pan is undefined straight up; 0 there.
static func angles_for(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var tilt := rad_to_deg(acos(clampf(d.y, -1.0, 1.0)))
	var pan := 0.0
	if Vector2(d.x, d.z).length() > 1e-6:
		pan = rad_to_deg(atan2(-d.x, -d.z))
	return Vector2(pan, tilt)


## Pan/tilt (degrees) at time t (s). fields: the resolved mover style.
static func angles(fields: Dictionary, t: float) -> Vector2:
	var pc := float(fields.get("pan_center", 0.0))
	var tc := float(fields.get("tilt_center", 0.0))
	var pr := float(fields.get("pan_range", 0.0))
	var tr := float(fields.get("tilt_range", 0.0))
	# prog_speed is CYCLES PER MINUTE (how lighting desks label sweep rates).
	var cyc := float(fields.get("prog_speed", 6.0)) / 60.0 * t \
		+ float(fields.get("phase_deg", 0.0)) / 360.0
	var a := TAU * cyc
	match str(fields.get("program", "static")):
		"pan_sweep":
			return Vector2(pc + pr * sin(a), tc)
		"tilt_sweep":
			return Vector2(pc, tc + tr * sin(a))
		"circle":
			return Vector2(pc + pr * cos(a), tc + tr * sin(a))
		"figure8":
			return Vector2(pc + pr * sin(a), tc + tr * sin(2.0 * a))
		"wander":
			# A "ballyhoo": three incommensurate sines per axis — never repeats
			# visibly, deterministic, smooth (a real head cannot jump).
			var p := 0.6 * sin(a) + 0.3 * sin(a * 2.37 + 1.1) + 0.1 * sin(a * 5.13 + 2.3)
			var q := 0.6 * sin(a * 1.31 + 0.7) + 0.3 * sin(a * 3.07) + 0.1 * sin(a * 6.71 + 0.4)
			return Vector2(pc + pr * p, tc + tr * q)
		_:
			return Vector2(pc, tc)


## Base rotation (degrees, YXZ — the record's pitch/yaw/roll) that stands a
## fixture on a surface with normal `n`: its +Y along n.
static func mount_rotation(n: Vector3) -> Vector3:
	var nn := n.normalized()
	var b: Basis
	if nn.dot(Vector3.UP) < -0.999:
		b = Basis(Vector3.RIGHT, PI)   # hung upside down from a ceiling / truss
	elif nn.dot(Vector3.UP) > 0.999:
		b = Basis.IDENTITY
	else:
		b = Basis(Quaternion(Vector3.UP, nn))
	return LightGizmoMath.rotation_of(b)


## Fixture-local pan/tilt that aims the beam from `from` at world point `to`,
## for a base rotated by `rot_deg` (the Aim tool).
static func aim_angles(rot_deg: Vector3, from: Vector3, to: Vector3) -> Vector2:
	var b := LightGizmoMath.basis_of(rot_deg)
	return angles_for(b.inverse() * (to - from))
