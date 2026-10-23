class_name ClimelapseSkyDirector
extends RefCounted

## The sky and camera options of a video export, shared by the export
## (ClimelapseCapture) and the preview (ClimelapsePreview), so what the
## preview shows is what the render writes:
##   analemma     one frame per day at the sun's (or the moon's) daily instant,
##                the figure-eight drawn on the sky as it grows (main.gd's own
##                analemma, stepped once per video frame instead of per game
##                frame — analemma_export_begin / _step / _end)
##   clouds       false = main.clear_sky_override for the render
##   star_trails  1 = a long exposure that opens at dusk and grows through the
##                night (15°/h of arc, the sky's own rate), closes at dawn
##   follow       the camera keeps the sun / moon centred, or turns with the
##                sky so the stars hold still on screen
## Everything it changes is put back by end(), on every exit path.

const TRAIL_DARK_ALT_DEG := -6.0     # trails open below civil twilight
const SHADER_TRAIL_BASE_DEG := 8.0   # sky.gdshader: span = 8° + length × 40°
const SHADER_TRAIL_RANGE_DEG := 40.0
const SIDEREAL_DEG_PER_H := 15.041067

var opts: Dictionary = {}
var _prev := {}
var _night_start := NAN
var _ref_sky := Basis.IDENTITY
var _ref_set := false
var _ana_day := -1        # analemma day the clock is on (-1 = before the first)
var _ana_h := NAN         # the instant that day shows


func _init(o: Dictionary = {}) -> void:
	opts = o


func analemma() -> int:
	return int(opts.get("analemma", 0))


## Values for the clock claim the export / preview hold.
func clock_claim_values() -> Dictionary:
	return {"time_scale": 0.0, "analemma_mode": analemma() > 0}


## Before the clock claim: set the world up. Call end() to undo.
func begin(main: Node) -> void:
	_night_start = NAN
	_ref_set = false
	_ana_day = -1
	_ana_h = NAN
	if main == null:
		return
	if not bool(opts.get("clouds", true)) and "clear_sky_override" in main:
		_prev["clear_sky"] = bool(main.get("clear_sky_override"))
		main.set("clear_sky_override", true)
	var ss := _stars(main)
	if ss != null and int(opts.get("star_trails", -1)) >= 0:
		_prev["trails"] = [ss.star_trails, ss.star_trail_length]
		ss.star_trails = 0.0
	if analemma() > 0 and main.has_method("analemma_export_begin"):
		main.call("analemma_export_begin", float(opts.get("start_abs", 0.0)), analemma() - 1)
		_prev["analemma"] = true


## Put the world at frame i's instant. Returns that instant (absolute hours).
## Analemma frames must be asked for in order (0, 1, 2 …); restart() goes
## back to the first. The game's own analemma stepper walks EVERY day up to
## the frame's (≤ 7 a call), so the figure on the sky is whole however fast
## the video plays; a frame that shows the same day as the last one does not
## step at all.
func place(main: Node, i: int) -> float:
	if analemma() > 0 and main != null and main.has_method("analemma_export_step"):
		var target := ClimelapseExportOptions.analemma_day_of_frame(opts, i)
		while _ana_day < target:
			var step := mini(target - _ana_day, 7)
			_ana_h = float(main.call("analemma_export_step", step))
			_ana_day += step
		var h := _ana_h
		if is_nan(h) and main.has_method("get_absolute_hours"):
			h = float(main.call("get_absolute_hours"))
		_after_place(main, h)
		return h
	var abs_h := minf(ClimelapseExportOptions.frame_hours(opts, i), float(opts.get("end_abs", 0.0)))
	place_at(main, abs_h)
	return abs_h


## Continuous-time form (the preview between frames; non-analemma only).
func place_at(main: Node, abs_h: float) -> void:
	if main != null and main.has_method("set_absolute_hours"):
		main.call("set_absolute_hours", abs_h)
	_after_place(main, abs_h)


## Back to the first frame (the preview looping).
func restart(main: Node) -> void:
	_night_start = NAN
	_ref_set = false
	_ana_day = -1
	_ana_h = NAN
	if analemma() > 0 and main != null and main.has_method("analemma_export_begin"):
		main.call("analemma_export_begin", float(opts.get("start_abs", 0.0)), analemma() - 1)


func _after_place(main: Node, abs_h: float) -> void:
	if int(opts.get("star_trails", -1)) != 1:
		return
	var ss := _stars(main)
	var clock: Object = main.get("clock") if main != null else null
	if ss == null or clock == null:
		return
	var alt := rad_to_deg(asin(clampf((clock.call("get_sun_direction") as Vector3).y, -1.0, 1.0)))
	var st := trail_state(_night_start, abs_h, alt)
	_night_start = float(st["night_start"])
	ss.star_trails = float(st["trails"])
	ss.star_trail_length = float(st["length"])


## The camera for this instant: the keyed / locked pose, turned to follow.
func camera_pose(main: Node, base: Dictionary) -> Dictionary:
	var kind := str(opts.get("follow", "none"))
	if kind == "none" or main == null:
		return base
	var clock: Object = main.get("clock")
	if clock == null:
		return base
	var xf: Transform3D = base.get("xform", Transform3D.IDENTITY)
	var out := base.duplicate()
	match kind:
		"sun":
			xf.basis = look_basis(clock.call("get_sun_direction") as Vector3, xf.basis)
		"moon":
			xf.basis = look_basis(clock.call("get_moon_direction") as Vector3, xf.basis)
		"stars":
			var sky := sky_basis(clock)
			if not _ref_set:
				_ref_sky = sky
				_ref_set = true
			xf.basis = follow_stars_basis(xf.basis, _ref_sky, sky)
	out["xform"] = xf
	return out


func end(main: Node) -> void:
	if main == null or not is_instance_valid(main):
		_prev = {}
		return
	if _prev.has("clear_sky") and "clear_sky_override" in main:
		main.set("clear_sky_override", bool(_prev["clear_sky"]))
	var ss := _stars(main)
	if ss != null and _prev.has("trails"):
		ss.star_trails = float(_prev["trails"][0])
		ss.star_trail_length = float(_prev["trails"][1])
	if _prev.has("analemma") and main.has_method("analemma_export_end"):
		main.call("analemma_export_end")
	_prev = {}


static func _stars(main: Node) -> StarSystem:
	if main == null or not main.has_method("get_star_system"):
		return null
	return main.call("get_star_system") as StarSystem


# --- pure maths (selftested) ----------------------------------------------------

## A camera basis looking along `dir` with the horizon level. Straight up or
## down keeps the old basis's heading.
static func look_basis(dir: Vector3, old: Basis) -> Basis:
	if dir.length_squared() < 1e-12:
		return old
	var d := dir.normalized()
	if absf(d.y) > 0.999:
		var fwd := -old.z
		fwd.y = 0.0
		if fwd.length_squared() < 1e-9:
			fwd = Vector3.FORWARD
		return Basis.looking_at(d, fwd.normalized())
	return Basis.looking_at(d, Vector3.UP)


## Rotation of the sky at the clock's instant (equatorial → world).
static func sky_basis(clock: Object) -> Basis:
	var jd := float(clock.call("get_julian_day_utc"))
	var lst := float(clock.call("get_local_sidereal_time", jd))
	return StarSkyMath.equatorial_to_world_basis(lst, float(clock.get("latitude")))


## The camera turned with the sky since `ref_sky`: a star centred at the
## reference instant stays centred (the horizon rolls, as on a tracking mount).
static func follow_stars_basis(cam: Basis, ref_sky: Basis, sky_now: Basis) -> Basis:
	return (sky_now * ref_sky.inverse()) * cam


## Long-exposure trails: closed in daylight (above `TRAIL_DARK_ALT_DEG`),
## opening at dusk and growing at the sky's rate through the night.
## Returns {trails 0..1, length 0..1, night_start (abs hours or NAN)}.
static func trail_state(night_start: float, abs_h: float, sun_alt_deg: float) -> Dictionary:
	if sun_alt_deg > TRAIL_DARK_ALT_DEG:
		return {"trails": 0.0, "length": 0.0, "night_start": NAN}
	var start := abs_h if is_nan(night_start) or night_start > abs_h else night_start
	var arc := (abs_h - start) * SIDEREAL_DEG_PER_H
	return {
		"trails": clampf(arc / SHADER_TRAIL_BASE_DEG, 0.0, 1.0),
		"length": clampf((arc - SHADER_TRAIL_BASE_DEG) / SHADER_TRAIL_RANGE_DEG, 0.0, 1.0),
		"night_start": start,
	}
