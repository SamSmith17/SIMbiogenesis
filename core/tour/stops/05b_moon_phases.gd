extends TourStop

## One lunation as a climelapse: new moon to new moon, one frame per mean
## lunar day (the step the game's own lunar analemma takes, main.gd
## _advance_analemma_one_day), each at the moon's upper transit. Stepping by the
## lunar day keeps the moon on the meridian while its phase grows and wanes,
## and its transit hour drifts round the clock, so the sky goes from day (new
## moon at noon) to deep night (full moon at midnight) and back. A wide lens on
## the open playa: the moon over the landscape, not a close-up.

## Frames per lunation (one per lunar day) and how long each is held (s, × pace).
const STEPS := 30
const HOLD_S := 0.34
## Lens and where the camera stands.
const LENS_FOV := 62.0
const EYE_HEIGHT_M := 4.0
## The camera looks under the moon (the moon in the top of the frame, the
## horizon in it whenever the moon is not high), never under PITCH_MIN_DEG,
## and eases toward that.
const PITCH_BELOW_MOON_DEG := 24.0
const PITCH_MIN_DEG := 4.0
## The hero: a waxing gibbous night with the moon lower than this (the
## playa in the picture too), else the full moon.
const HERO_MAX_ALT_DEG := 45.0
const PITCH_MAX_DEG := 58.0
const SYNODIC_D := 29.530589
## Phase names by age in days (upper bounds).
const PHASES := [
	[1.0, "New moon"], [6.4, "Waxing crescent"], [8.4, "First quarter"],
	[13.8, "Waxing gibbous"], [15.8, "Full moon"], [21.1, "Waning gibbous"],
	[23.1, "Last quarter"], [28.5, "Waning crescent"], [99.0, "New moon"],
]

var _clock := {}
var _shot_phase := ""


func _init() -> void:
	id = "moon_phases"
	title = "Moon phases"
	chapter = "World"
	summary = "The real moon: where it stands and how much of it is lit, for any date."
	how = PackedStringArray(["Scrub the timeline across a month",
		"🎬 Video export → Analemma: moon, for a lunation like this one",
		"Settings → Sky: moon size and phase offset"])
	button = "the timeline"
	world = "burningman"
	budget_s = 45.0
	hour = 22.0
	blurb = ("The moon's position comes from Meeus's lunar theory with topocentric " +
		"parallax, and its lit fraction from the real angle between the sun and the " +
		"moon. Stepping one lunar day at a time keeps it on the meridian while it " +
		"waxes and wanes, and the sky behind it turns from day at new moon to deep " +
		"night at full, exactly as it does outside.")


func run(ctx: TourContext) -> void:
	var m := ctx.main
	var clock: Variant = m.get("clock")
	var lp := ctx.klass("LunarPosition")
	var sp := ctx.klass("SolarPosition")
	if not ctx.require(clock != null and lp != null and sp != null, "the clock and the sun/moon solvers exist"):
		return
	_clock = ctx.save_clock()
	ctx.clear_sky(true)
	m.set("time_scale", 0.0)
	var lat := float(m.get("latitude"))
	var lon := float(m.get("longitude"))
	var day0 := float(m.call("get_absolute_hours")) - float(m.get("day_time"))
	var new_h := _new_moon_after(clock, lp, sp, lat, lon, day0)
	var period := float(clock.get("moon_orbital_period")) if clock.get("moon_orbital_period") != null else 27.321661
	var lunar_day_h := 24.0 * period / (period - 1.0)
	ctx.note("new moon near abs hour %.1f · lunar day %.3f h" % [new_h, lunar_day_h])

	var cam := ctx.tour_camera()
	cam.fov = LENS_FOV
	var eye := ctx.player.global_position + Vector3.UP * EYE_HEIGHT_M
	ctx.hud(false)
	ctx.caption("One lunation, a frame per lunar day: the moon on the meridian as it waxes and wanes", 3.0)
	var look_yaw := NAN
	var look_pitch := NAN
	var last_phase := ""
	var shot := false
	var full_t := NAN
	var t_guess := _transit_near(lp, lat, lon, clock, new_h)
	for k in STEPS + 1:
		if ctx.cancelled:
			break
		var t := _transit_near(lp, lat, lon, clock, t_guess)
		t_guess = t + lunar_day_h
		m.call("set_absolute_hours", t)
		var md := _moon_dir(lp, clock, lat, lon, t)
		var yaw := atan2(-md.x, -md.z)
		var pitch := clampf(rad_to_deg(asin(clampf(md.y, -1.0, 1.0))) - PITCH_BELOW_MOON_DEG,
			PITCH_MIN_DEG, PITCH_MAX_DEG)
		if is_nan(look_yaw):
			look_yaw = yaw
			look_pitch = pitch
		var age := fposmod((t - new_h) / 24.0, SYNODIC_D)
		var phase := _phase_name(age)
		var lit := (1.0 - cos(deg_to_rad(_elongation(clock, lp, sp, lat, lon, t)))) * 0.5
		if phase != last_phase:
			last_phase = phase
			var dd: Dictionary = clock.call("abs_hours_to_date", t)
			ctx.caption("%s — %d %% lit · %d-%02d-%02d" % [phase, int(round(lit * 100.0)),
				int(dd.get("year", 0)), int(dd.get("month", 0)), int(dd.get("day", 0))], 2.4)
		# Hold the frame, easing the camera toward this day's moon.
		var span := maxf(HOLD_S * ctx.pace, 0.05)
		var e := 0.0
		while e < span and not ctx.cancelled:
			var dt := ctx.host.get_process_delta_time()
			var a := 1.0 - exp(-dt * 9.0)
			look_yaw = lerp_angle(look_yaw, yaw, a)
			look_pitch = lerpf(look_pitch, pitch, a)
			_aim(ctx, eye, look_yaw, look_pitch)
			await ctx.tree().process_frame
			e += dt
		if phase != str(_shot_phase) and phase in ["Waxing crescent", "First quarter", "Full moon", "Last quarter"]:
			_shot_phase = phase
			await ctx.shot(phase.to_lower().replace(" ", "_"))
		if is_nan(full_t) and phase == "Full moon":
			full_t = t
		# The hero: the waxing gibbous moon over a dark playa.
		var dark := _sun_alt(sp, clock, lat, lon, t) < -0.1
		if not shot and age > 9.0 and age < 14.0 and dark and md.y < sin(deg_to_rad(HERO_MAX_ALT_DEG)):
			_aim(ctx, eye, yaw, pitch)
			look_yaw = yaw
			look_pitch = pitch
			await ctx.hero()
			shot = true
	if not shot and not ctx.cancelled:
		if not is_nan(full_t):
			m.call("set_absolute_hours", full_t)
			var fd := _moon_dir(lp, clock, lat, lon, full_t)
			_aim(ctx, eye, atan2(-fd.x, -fd.z), clampf(rad_to_deg(asin(fd.y)) - PITCH_BELOW_MOON_DEG,
				PITCH_MIN_DEG, PITCH_MAX_DEG))
			await ctx.frames(3)
		await ctx.hero()
		shot = true
	ctx.require(shot, "a lunation frame was shot")


func _aim(ctx: TourContext, eye: Vector3, yaw: float, pitch_deg: float) -> void:
	var p := deg_to_rad(pitch_deg)
	var dir := Vector3(-sin(yaw) * cos(p), sin(p), -cos(yaw) * cos(p))
	ctx.place_camera(eye, eye + dir * 100.0)


func _phase_name(age_d: float) -> String:
	for ph in PHASES:
		if age_d < float(ph[0]):
			return str(ph[1])
	return "New moon"


func _moon_dir(lp: Script, clock: Object, lat: float, lon: float, h: float) -> Vector3:
	var jd := float(clock.call("abs_hours_to_julian_day_utc", h))
	return lp.call("direction_from_position", lp.call("get_position", lat, lon, jd)) as Vector3


func _sun_alt(sp: Script, clock: Object, lat: float, lon: float, h: float) -> float:
	var jd := float(clock.call("abs_hours_to_julian_day_utc", h))
	var s: Dictionary = sp.call("get_position", lat, lon, jd)
	return sin(deg_to_rad(float(s.get("elevation_deg", 0.0))))


## The moon's upper transit (highest point) within 3 h of `h`.
func _transit_near(lp: Script, lat: float, lon: float, clock: Object, h: float) -> float:
	var best_t := h
	var best_y := -INF
	var t := h - 3.0
	while t <= h + 3.0:
		var y := _moon_dir(lp, clock, lat, lon, t).y
		if y > best_y:
			best_y = y
			best_t = t
		t += 0.1
	return best_t


## The next new moon after `h0`: the smallest sun–moon angle over 32 days,
## coarse then fine.
func _new_moon_after(clock: Object, lp: Script, sp: Script, lat: float, lon: float, h0: float) -> float:
	var best_h := h0
	var best := INF
	var h := h0
	while h < h0 + 32.0 * 24.0:
		var e := _elongation(clock, lp, sp, lat, lon, h)
		if e < best:
			best = e
			best_h = h
		h += 3.0
	var c := best_h
	h = c - 3.0
	while h <= c + 3.0:
		var e := _elongation(clock, lp, sp, lat, lon, h)
		if e < best:
			best = e
			best_h = h
		h += 0.25
	return best_h


## Angle between the sun and the moon (degrees) at an absolute hour.
func _elongation(clock: Object, lp: Script, sp: Script, lat: float, lon: float, h: float) -> float:
	var jd := float(clock.call("abs_hours_to_julian_day_utc", h))
	var mp: Dictionary = lp.call("get_position", lat, lon, jd)
	var md: Vector3 = lp.call("direction_from_position", mp)
	var s: Dictionary = sp.call("get_position", lat, lon, jd)
	var sd: Vector3 = sp.call("direction_from_horizon", float(s.get("azimuth_deg", 0.0)), float(s.get("elevation_deg", 0.0)))
	return rad_to_deg(md.angle_to(sd))


func teardown(ctx: TourContext) -> void:
	ctx.restore_clock(_clock)
	_clock = {}
	ctx.hud(true)
