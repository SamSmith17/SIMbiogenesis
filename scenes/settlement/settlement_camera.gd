class_name SettlementCamera
extends Camera3D

## The settlement view's camera: one continuous scale from standing on the
## ground to seeing the whole Sphere of Influence.
##
## ## One scalar
##
## Everything is a function of `_h` — the camera's height above the ground
## under its focus point. Pitch, near/far, pan speed and prop-cull reach all
## derive from it, so there is exactly one number to reason about and no mode
## boundary to fall off.
##
## ## Perspective the whole way, deliberately
##
## An orthographic top-down would be the conventional choice for the far end,
## but switching projection mid-zoom is a visible discontinuity, and ortho
## un-projection is precisely the maths that makes picking on the 2D Site Plan
## fiddly. The Site Plan still exists for a true plan view; this is the view
## where you watch people work, and it should look like the world because it
## IS the world — same viewport, same culling, same shadows as first person.

## Ground level, near enough to eye height to read as standing there.
const EYE_H := 1.7
## Beyond ~3x the SoI radius there is nothing further to see.
const GLOBE_H_MULT := 3.0
const FALLBACK_GLOBE_H := 1500.0
const FOV_DEG := 68.0          # matches the snowglobe lens, so the two read as one
const ZOOM_STEP := 0.12        # per wheel notch, multiplicative
const ZOOM_SMOOTH := 9.0
const PAN_SMOOTH := 12.0
## Pitch is interpolated on log(height) so the wheel feels linear.
const PITCH_LOW_H := 12.0      # street level: nearly horizontal
const PITCH_HIGH_H := 400.0    # above this, essentially straight down
const PITCH_AT_LOW := -0.12    # rad
const PITCH_AT_HIGH := -1.40   # ~80 deg; never a full 90 or the world flattens

var focus: Vector2 = Vector2.ZERO          # world XZ the camera orbits
var yaw: float = 0.0

var _h := 60.0
var _h_target := 60.0
var _focus_target: Vector2 = Vector2.ZERO
var _main: Node = null
var _max_h := FALLBACK_GLOBE_H


func setup(main: Node, start_focus: Vector2, start_h: float = 60.0) -> void:
	_main = main
	focus = start_focus
	_focus_target = start_focus
	_h = clampf(start_h, EYE_H, _resolve_max_h())
	_h_target = _h
	_max_h = _resolve_max_h()
	fov = FOV_DEG
	projection = PROJECTION_PERSPECTIVE
	_apply(true)


func _resolve_max_h() -> float:
	var soi := _main.get_node_or_null("/root/SoiService") if _main != null else null
	if soi != null and soi.has_method("radius_m"):
		var r := float(soi.call("radius_m"))
		if r > 1.0:
			return r * GLOBE_H_MULT
	return FALLBACK_GLOBE_H


## Wheel notches: positive zooms IN. Exponential so every notch feels the same
## at every scale — a linear step is imperceptible at 1 km and violent at 2 m.
func zoom_by(notches: float) -> void:
	_h_target = clampf(_h_target * pow(1.0 - ZOOM_STEP, notches), EYE_H, _max_h)


## Drag-pan, in screen pixels. Speed scales with height so a given drag always
## moves the same fraction of the view.
func pan_by(delta_px: Vector2, viewport_h: float) -> void:
	var per_px := (2.0 * _h * tan(deg_to_rad(FOV_DEG * 0.5))) / maxf(viewport_h, 1.0)
	var right := Vector2(cos(yaw), -sin(yaw))
	var fwd := Vector2(sin(yaw), cos(yaw))
	_focus_target -= right * delta_px.x * per_px
	_focus_target += fwd * delta_px.y * per_px


func orbit_by(delta_rad: float) -> void:
	yaw = fposmod(yaw + delta_rad, TAU)


func look_at_xz(p: Vector2) -> void:
	_focus_target = p


func height() -> float:
	return _h


func height_frac() -> float:
	return clampf((log(_h) - log(EYE_H)) / maxf(log(_max_h) - log(EYE_H), 0.001), 0.0, 1.0)


## A human-readable scale, for the HUD. The player should never see "_h".
func scale_label() -> String:
	if _h < 8.0:
		return "Ground"
	if _h < 40.0:
		return "Street"
	if _h < 150.0:
		return "Block"
	if _h < 600.0:
		return "Camp"
	return "Site"


func _process(delta: float) -> void:
	var k := minf(delta * ZOOM_SMOOTH, 1.0)
	_h = lerpf(_h, _h_target, k)
	focus = focus.lerp(_focus_target, minf(delta * PAN_SMOOTH, 1.0))
	_apply(false)


func _apply(_immediate: bool) -> void:
	var pitch := _pitch_for(_h)
	# Ground under the FOCUS, not under the camera: at a shallow pitch the two
	# are far apart, and following the camera's own ground would make the view
	# lurch every time a hill passed beneath it.
	var gy := TerrainSurfaceQuery.ground_height_at(_main, focus.x, focus.y) \
		if _main != null else 0.0
	var target := Vector3(focus.x, gy, focus.y)
	# Sit back along the view direction so the focus stays centred as pitch
	# changes — a purely vertical offset would swing the target off screen.
	var back := _h / maxf(tan(-pitch), 0.05)
	var dir := Vector3(sin(yaw), 0.0, cos(yaw))
	global_position = target + Vector3(0.0, _h, 0.0) - dir * back
	# Never let the camera drop below the ground it is flying over.
	var cam_ground := TerrainSurfaceQuery.ground_height_at(
		_main, global_position.x, global_position.z) if _main != null else 0.0
	global_position.y = maxf(global_position.y, cam_ground + 1.2)
	look_at(target, Vector3.UP)
	near = clampf(_h * 0.02, 0.05, 0.5)
	far = maxf(4000.0, _h * 12.0)


static func _pitch_for(h: float) -> float:
	var t := clampf((log(maxf(h, 0.01)) - log(PITCH_LOW_H))
		/ maxf(log(PITCH_HIGH_H) - log(PITCH_LOW_H), 0.001), 0.0, 1.0)
	return lerpf(PITCH_AT_LOW, PITCH_AT_HIGH, t)
