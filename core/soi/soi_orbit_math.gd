class_name SoiOrbitMath
extends RefCounted

## Orbit framing shared by the full-screen snowglobe camera and the graph's
## Globe lens, so the two open on the same composition. Pure static.


## Orbit multiple (camera distance ÷ radius) that fits the sphere snugly in the
## LIMITING field of view — vertical in landscape, horizontal in a tall frame.
## sin, not tan: the silhouette of a sphere of radius r seen from distance d
## subtends asin(r/d), so d = r / sin(half_angle).
static func fit_orbit_mult(fov_deg: float, frame_size: Vector2, fit_fraction: float,
		min_mult: float, max_mult: float, fallback: float) -> float:
	var half_v := deg_to_rad(fov_deg * 0.5)
	var half_limit := half_v
	if frame_size.y > 0.0 and frame_size.x > 0.0 and frame_size.x < frame_size.y:
		# Portrait-ish: horizontal fov is the limit.
		half_limit = atan(tan(half_v) * frame_size.x / frame_size.y)
	var target := half_limit * fit_fraction
	if target <= 0.0:
		return fallback
	return clampf(1.0 / sin(target), min_mult, max_mult)


## Entry yaw that puts the rim sun in frame, offset to the upper side like the
## emblem rather than dead behind the globe. `fallback` at night / no sun.
static func sun_facing_yaw(sun: DirectionalLight3D, fallback: float = 0.6) -> float:
	if sun == null or not is_instance_valid(sun):
		return fallback
	var dir := sun.global_transform.basis.z.normalized()
	if dir.y < -0.05:
		return fallback  # night — nothing to compose around
	# Camera sits at yaw θ on the orbit circle and looks back at the center;
	# placing the camera ~35° around from the sun's azimuth puts the disc in
	# the upper-left/right third of the frame instead of behind the sphere.
	return atan2(dir.z, dir.x) + 0.6


## Glass opacity for a viewing pitch: horizon-ish pitch kills the Fresnel sky
## bullseye, higher pitch shows the full glass dome.
const GLASS_PITCH_FADE_START := 0.55
const GLASS_PITCH_FADE_END := 0.22


static func glass_opacity_for_pitch(pitch: float) -> float:
	return clampf(inverse_lerp(GLASS_PITCH_FADE_END, GLASS_PITCH_FADE_START, pitch), 0.0, 1.0)
