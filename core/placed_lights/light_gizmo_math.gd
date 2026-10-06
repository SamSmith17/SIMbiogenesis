class_name LightGizmoMath
extends RefCounted

## Pure ray maths for the Light Studio gumball and the light / waypoint picks.
## No colliders anywhere — the same approach ConduitManager uses for hang pins,
## so a handle is pickable on every map whether or not it has physics.
##
## Rotation convention (matches Node3D.rotation_degrees, Euler order YXZ):
##   rot = Vector3(pitch, yaw, roll) degrees; the light shines along -Z.

const INF_DIST := 1e20


## Parameter s along the axis line (axis_o + axis_d·s) of the point closest to
## the ray. Returns NAN when the ray runs parallel to the axis (no stable drag).
static func axis_param(ray_o: Vector3, ray_d: Vector3, axis_o: Vector3, axis_d: Vector3) -> float:
	var d1 := axis_d.normalized()
	var d2 := ray_d.normalized()
	var r := axis_o - ray_o
	var b := d1.dot(d2)
	var denom := 1.0 - b * b
	if denom < 1e-6:
		return NAN
	var c := d1.dot(r)
	var f := d2.dot(r)
	return (b * f - c) / denom


static func ray_plane(ray_o: Vector3, ray_d: Vector3, plane_o: Vector3, plane_n: Vector3) -> Variant:
	var n := plane_n.normalized()
	var denom := n.dot(ray_d)
	if absf(denom) < 1e-6:
		return null
	var t := n.dot(plane_o - ray_o) / denom
	if t < 0.0:
		return null
	return ray_o + ray_d * t


## Distance from the ray to a point, and how far along the ray it is.
static func ray_point(ray_o: Vector3, ray_d: Vector3, p: Vector3) -> Dictionary:
	var d := ray_d.normalized()
	var t := d.dot(p - ray_o)
	if t < 0.0:
		return {"dist": INF_DIST, "t": t}
	return {"dist": (ray_o + d * t).distance_to(p), "t": t}


## Distance between the ray and segment a-b (for axis-arrow picking).
static func ray_segment(ray_o: Vector3, ray_d: Vector3, a: Vector3, b: Vector3) -> Dictionary:
	var ab := b - a
	var seg_len := ab.length()
	if seg_len < 1e-6:
		return ray_point(ray_o, ray_d, a)
	var s := axis_param(ray_o, ray_d, a, ab / seg_len)
	if is_nan(s):
		s = 0.0
	s = clampf(s, 0.0, seg_len)
	var p := a + ab / seg_len * s
	var rp := ray_point(ray_o, ray_d, p)
	rp["s"] = s
	return rp


## How far the ray's hit on the ring's plane lies from the ring circle.
static func ray_ring(ray_o: Vector3, ray_d: Vector3, center: Vector3, normal: Vector3,
		radius: float) -> Dictionary:
	var hit: Variant = ray_plane(ray_o, ray_d, center, normal)
	if hit == null:
		# Edge-on ring: fall back to the distance to its centre band.
		var rp := ray_point(ray_o, ray_d, center)
		return {"dist": absf(float(rp["dist"]) - radius) if float(rp["dist"]) < INF_DIST else INF_DIST,
			"t": rp["t"]}
	var h: Vector3 = hit
	return {"dist": absf(h.distance_to(center) - radius), "t": (h - ray_o).length()}


## Signed angle (rad) of point p around `normal` measured from `ref`.
static func ring_angle(p: Vector3, center: Vector3, normal: Vector3, ref: Vector3) -> float:
	var n := normal.normalized()
	var v := p - center
	v -= n * n.dot(v)
	var r := ref - n * n.dot(ref)
	if v.length_squared() < 1e-10 or r.length_squared() < 1e-10:
		return 0.0
	return r.signed_angle_to(v, n)


## A pick radius that never falls below `min_angle_deg` on screen — a handle
## or bulb 200 m away is sub-pixel and an exact sphere test is unclickable
## (the SiteTargetPicker rule).
static func pick_radius(base_m: float, t: float, min_angle_deg: float = 0.7) -> float:
	return maxf(base_m, maxf(t, 0.0) * tan(deg_to_rad(min_angle_deg)))


static func snap(v: float, step: float) -> float:
	return v if step <= 0.0 else roundf(v / step) * step


static func snap_vec(v: Vector3, step: float) -> Vector3:
	return Vector3(snap(v.x, step), snap(v.y, step), snap(v.z, step))


## Light rotation (degrees, YXZ) that points -Z from `from` toward `to`.
static func aim_rotation(from: Vector3, to: Vector3, keep_roll: float = 0.0) -> Vector3:
	var d := to - from
	if d.length_squared() < 1e-8:
		return Vector3(-90.0, 0.0, keep_roll)
	d = d.normalized()
	var pitch := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	var yaw := rad_to_deg(atan2(-d.x, -d.z))
	return Vector3(pitch, yaw, keep_roll)


static func direction_of(rot_deg: Vector3) -> Vector3:
	return basis_of(rot_deg) * Vector3(0.0, 0.0, -1.0)


static func basis_of(rot_deg: Vector3) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y),
		deg_to_rad(rot_deg.z)))


static func rotation_of(b: Basis) -> Vector3:
	var e := b.orthonormalized().get_euler()
	return Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))


## Rotate `rot_deg` by `angle_rad` about `axis` (world space when `world`,
## else the light's own local axis).
static func rotate_by(rot_deg: Vector3, axis: Vector3, angle_rad: float, world: bool) -> Vector3:
	var b := basis_of(rot_deg)
	var r := Basis(axis.normalized(), angle_rad)
	return rotation_of(r * b if world else b * r)
