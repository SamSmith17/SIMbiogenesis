extends TourStop

## A lunar month in six looks: the moon found where it really is (Meeus ch. 47)
## at each phase, shot through a long lens, lit by the real sun direction.

## Telephoto field of view for the moon shots (degrees).
const LENS_FOV := 14.0
## Days after new moon for each look, and what it is called.
const LOOKS := [
	[3.5, "Waxing crescent"], [7.4, "First quarter"], [11.0, "Waxing gibbous"],
	[14.8, "Full moon"], [22.1, "Last quarter"], [25.8, "Waning crescent"],
]

var _clock := {}


func _init() -> void:
	id = "moon_phases"
	title = "Moon phases"
	chapter = "World"
	summary = "The real moon: where it stands and how much of it is lit, for any date."
	how = PackedStringArray(["Scrub the timeline across a month",
		"Settings → Sky: moon size and phase offset"])
	button = "the timeline"
	world = "mtvernon"
	budget_s = 45.0
	hour = 22.0
	blurb = ("The moon's position comes from Meeus's lunar theory with topocentric " +
		"parallax, and its lit fraction from the real angle between the sun and the " +
		"moon, so crescents, quarters and the full moon rise, transit and set on the " +
		"dates and at the bearings they do outside.")


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
	var now := float(m.call("get_absolute_hours"))
	var day0 := now - float(m.get("day_time"))
	# The next new moon: the smallest sun–moon angle over the coming 32 days.
	var new_h := day0
	var best := INF
	var h := day0
	while h < day0 + 32.0 * 24.0:
		var e := _elongation(clock, lp, sp, lat, lon, h)
		if e < best:
			best = e
			new_h = h
		h += 3.0
	ctx.note("new moon near abs hour %.0f (elongation %.1f°)" % [new_h, best])
	var eye := ctx.player.global_position + Vector3.UP * 60.0
	var cam := ctx.tour_camera()
	ctx.hud(false)
	var shot := false
	for look in LOOKS:
		if ctx.cancelled:
			break
		var t := _best_hour(clock, lp, sp, lat, lon, new_h + float(look[0]) * 24.0)
		m.call("set_absolute_hours", t)
		await ctx.frames(3)
		var md: Vector3 = clock.call("get_moon_direction")
		cam.fov = LENS_FOV
		ctx.place_camera(eye, eye + md * 100.0)
		var lit := (1.0 - cos(deg_to_rad(_elongation(clock, lp, sp, lat, lon, t)))) * 0.5
		var dd: Dictionary = clock.call("abs_hours_to_date", t)
		ctx.caption("%s — %d %% lit · %d-%02d-%02d" % [look[1], int(round(lit * 100.0)),
			int(dd.get("year", 0)), int(dd.get("month", 0)), int(dd.get("day", 0))], 2.6)
		await ctx.wait(2.6)
		await ctx.shot(str(look[1]).to_lower().replace(" ", "_"))
		if str(look[1]) == "Waxing gibbous" and not shot:
			shot = true
			await ctx.hero()
	ctx.require(shot, "the waxing gibbous moon was shot")


## Angle between the sun and the moon (degrees) at an absolute hour.
func _elongation(clock: Object, lp: Script, sp: Script, lat: float, lon: float, h: float) -> float:
	var jd := float(clock.call("abs_hours_to_julian_day_utc", h))
	var mp: Dictionary = lp.call("get_position", lat, lon, jd)
	var md: Vector3 = lp.call("direction_from_position", mp)
	var s: Dictionary = sp.call("get_position", lat, lon, jd)
	var sd: Vector3 = sp.call("direction_from_horizon", float(s.get("azimuth_deg", 0.0)), float(s.get("elevation_deg", 0.0)))
	return rad_to_deg(md.angle_to(sd))


## Within a day of `h`, the hour that shows the moon best: high, and with the
## sun as far down as possible.
func _best_hour(clock: Object, lp: Script, sp: Script, lat: float, lon: float, h: float) -> float:
	var best_t := h
	var best_s := -INF
	var t := h - 12.0
	while t <= h + 12.0:
		var jd := float(clock.call("abs_hours_to_julian_day_utc", t))
		var mp: Dictionary = lp.call("get_position", lat, lon, jd)
		var m_alt := (lp.call("direction_from_position", mp) as Vector3).y
		var s: Dictionary = sp.call("get_position", lat, lon, jd)
		var s_alt := sin(deg_to_rad(float(s.get("elevation_deg", 0.0))))
		var score := m_alt - maxf(s_alt, -0.2) * 0.8
		if m_alt > 0.15 and score > best_s:
			best_s = score
			best_t = t
		t += 0.5
	return best_t


func teardown(ctx: TourContext) -> void:
	ctx.restore_clock(_clock)
	_clock = {}
	ctx.hud(true)
