class_name SoiStagePose
extends RefCounted

## Camera poses for the graph's SoI lenses (Plan / Section / Globe / bubble) and
## the animated transition between them. Pure static: pinned by
## soi_stage_pose_selftest.gd.
##
## A pose is a Dictionary:
##   look     Vector3  the point the view is about (framed at the centre)
##   dir      Vector3  unit vector from `look` toward the camera
##   up       Vector3  unit screen-up hint
##   half_h   float    half the frame height AT `look` (metres)
##   ortho_w  float    0 = perspective at `fov`, 1 = orthographic
##   fov      float    perspective vertical FOV (degrees)
##   dist     float    camera distance used for the orthographic end
##
## The ortho ↔ perspective handoff is a DOLLY-ZOOM: as ortho_w rises the FOV
## narrows on a log scale toward MIN_FOV_DEG (0.2°) while the camera backs off so the
## frame height at `look` stays half_h — so the picture flattens smoothly and
## the final switch to a true orthographic camera (at ortho_w == 1) is
## invisible (at 0.2° a perspective image is within half a pixel of orthographic).

const MIN_FOV_DEG := 0.2
## Camera3D.fov's own floor; narrower poses are drawn as an equivalent FRUSTUM.
const GODOT_MIN_FOV_DEG := 1.0


static func make(look: Vector3, dir: Vector3, up: Vector3, half_h: float,
		ortho: bool, fov_deg: float, dist: float) -> Dictionary:
	return {
		"look": look,
		"dir": dir.normalized() if dir.length_squared() > 1e-12 else Vector3.UP,
		"up": up.normalized() if up.length_squared() > 1e-12 else Vector3.FORWARD,
		"half_h": maxf(half_h, 1e-4),
		"ortho_w": 1.0 if ortho else 0.0,
		"fov": fov_deg,
		"dist": maxf(dist, 0.1),
	}


## Read the pose a camera is in, about `look`.
static func from_camera(cam: Camera3D, look: Vector3) -> Dictionary:
	var to_cam := cam.global_position - look
	var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var dist := to_cam.length()
	var fov := cam.fov
	if cam.projection == Camera3D.PROJECTION_FRUSTUM and cam.near > 0.0:
		fov = rad_to_deg(2.0 * atan(cam.size * 0.5 / cam.near))
	var half_h := cam.size * 0.5 if ortho else dist * tan(deg_to_rad(fov) * 0.5)
	return make(look, to_cam, cam.global_transform.basis.y, half_h, ortho,
			fov if not ortho else 68.0, dist)


## Smoothstep ease used for every lens transition.
static func ease_t(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## Interpolate two poses at eased time `e` (0..1). `bulge` dips ortho_w toward
## perspective mid-way (a Plan → Section move swings through a 3D view rather
## than sliding flat).
static func lerp_pose(a: Dictionary, b: Dictionary, e: float, bulge: float = 0.0) -> Dictionary:
	var t := clampf(e, 0.0, 1.0)
	var da: Vector3 = a["dir"]
	var db: Vector3 = b["dir"]
	var dir: Vector3
	if da.dot(db) < -0.9999:
		# Antipodal: Vector3.slerp is undefined — swing over the top instead.
		var mid := (da.cross(Vector3.RIGHT) if absf(da.x) < 0.9 else da.cross(Vector3.FORWARD)).normalized()
		dir = (da.slerp(mid, t * 2.0) if t < 0.5 else mid.slerp(db, (t - 0.5) * 2.0))
	else:
		dir = da.slerp(db, t)
	var ua: Vector3 = a["up"]
	var ub: Vector3 = b["up"]
	var up := ua.lerp(ub, t)
	if up.length_squared() < 1e-6:
		up = ub
	var w := lerpf(float(a["ortho_w"]), float(b["ortho_w"]), t) - bulge * sin(PI * t)
	return {
		"look": (a["look"] as Vector3).lerp(b["look"] as Vector3, t),
		"dir": dir.normalized(),
		"up": up.normalized(),
		"half_h": exp(lerpf(log(float(a["half_h"])), log(float(b["half_h"])), t)),
		"ortho_w": clampf(w, 0.0, 1.0),
		"fov": lerpf(float(a["fov"]), float(b["fov"]), t),
		"dist": lerpf(float(a["dist"]), float(b["dist"]), t),
	}


## Effective perspective FOV (degrees) for a pose's ortho_w.
static func effective_fov(p: Dictionary) -> float:
	var w := float(p["ortho_w"])
	return exp(lerpf(log(maxf(float(p["fov"]), MIN_FOV_DEG)), log(MIN_FOV_DEG), w))


## Camera distance for a pose (the dolly half of the dolly-zoom).
static func camera_distance(p: Dictionary) -> float:
	if float(p["ortho_w"]) >= 0.999:
		return float(p["dist"])
	return float(p["half_h"]) / tan(deg_to_rad(effective_fov(p)) * 0.5)


## Orthonormal camera basis (+Z = dir, toward the camera) from dir + up hint.
static func basis_for(p: Dictionary) -> Basis:
	var z: Vector3 = (p["dir"] as Vector3).normalized()
	var up: Vector3 = p["up"]
	var x := up.cross(z)
	if x.length_squared() < 1e-8:
		x = Vector3.RIGHT.cross(z) if absf(z.x) < 0.9 else Vector3.FORWARD.cross(z)
	x = x.normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


## Write a pose into a camera. `scene_r` bounds near/far (the SoI radius).
static func apply(cam: Camera3D, p: Dictionary, scene_r: float) -> void:
	var d := camera_distance(p)
	var look: Vector3 = p["look"]
	cam.global_transform = Transform3D(basis_for(p), look + (p["dir"] as Vector3) * d)
	var reach := maxf(scene_r, 1.0) * 4.0
	if float(p["ortho_w"]) >= 0.999:
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = float(p["half_h"]) * 2.0
		cam.near = 0.05
		cam.far = d + reach
	else:
		var fov := effective_fov(p)
		cam.near = maxf(d - reach, 0.05)
		cam.far = d + reach
		if fov >= GODOT_MIN_FOV_DEG:
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = fov
		else:
			# Camera3D refuses a FOV under 1° (set_fov errors and KEEPS the old
			# value — the dolly then backed off for 0.2° while drawing at ~1°,
			# so the frame shrank ~5× just before the ortho switch). The same
			# symmetric perspective as a FRUSTUM has no such floor: size is the
			# near-plane height (KEEP_HEIGHT).
			cam.projection = Camera3D.PROJECTION_FRUSTUM
			cam.frustum_offset = Vector2.ZERO
			cam.size = 2.0 * cam.near * tan(deg_to_rad(fov) * 0.5)
