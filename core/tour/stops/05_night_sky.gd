extends TourStop

var _saved_date := []
## The player's own star look (their saved one can be very dim) is set aside
## for the shipped look while the stop runs, then handed back.
const SHOW_LOOK := {
	"star_trails": 0.0, "stars_brightness": 2.2, "stars_point_size": 0.5,
	"stars_saturation": 1.5, "stars_wash": 0.7, "stars_background_cut": 0.02,
	"stars_contrast": 1.4, "milkyway_gain": 2.6,
}
var _saved_look := {}


func _init() -> void:
	id = "night_sky"
	title = "The real night sky"
	chapter = "World"
	summary = "Stars, planets and the moon where they really are for this site and date."
	how = PackedStringArray(["Scrub the timeline to night",
		"Press Home to show the reference-star markers",
		"The ∞ speed preset turns on analemma mode (stars through daylight)"])
	action = "toggle_star_calibration"
	world = "mtvernon"
	budget_s = 35.0
	hour = 22.0
	blurb = ("The star field is a registered Stellarium map turned by the computed " +
		"sidereal time for the site's latitude, so constellations rise and set where " +
		"they do outside. Planets, the moon's phase, an optional zodiac overlay and " +
		"analemma planet paths all come from the same astronomy code.")


func run(ctx: TourContext) -> void:
	# A clear winter night with no moon up: the real October weather here is
	# usually overcast, and a tour shot of cloud is not a star field.
	_saved_date = [ctx.main.get("year"), ctx.main.get("month"), ctx.main.get("day")]
	ctx.main.set("year", 2026)
	ctx.main.set("month", 1)
	ctx.main.set("day", 20)
	ctx.set_hour(22.0)
	ctx.clear_sky(true)
	var stars: Variant = ctx.main.call("get_star_system") if ctx.main.has_method("get_star_system") else null
	if stars != null:
		for k in SHOW_LOOK:
			_saved_look[k] = stars.get(k)
			stars.set(k, SHOW_LOOK[k])
	ctx.run_clock(120.0)
	var p := ctx.player.global_position + Vector3.UP * 60.0
	var f := ctx.player_forward()
	var a := p + f * 100.0 + Vector3.UP * 70.0
	var b := p + f.rotated(Vector3.UP, 0.9) * 100.0 + Vector3.UP * 140.0
	ctx.hud(false)
	ctx.place_camera(p, a)
	await ctx.wait(0.8)
	ctx.caption("The sky turns with real sidereal time", 3.0)
	await ctx.fly([[p, a], [p, b]], 5.0)
	await ctx.hero()
	if stars != null:
		stars.call("set_reference_stars_visible", true)
		ctx.caption("Home: reference-star markers sit on the catalogue positions", 3.0)
		await ctx.wait(3.0)
		stars.call("set_reference_stars_visible", false)


func teardown(ctx: TourContext) -> void:
	var stars: Variant = ctx.main.call("get_star_system") if ctx.main.has_method("get_star_system") else null
	if stars != null:
		stars.call("set_reference_stars_visible", false)
		for k in _saved_look:
			stars.set(k, _saved_look[k])
	_saved_look = {}
	if _saved_date.size() == 3:
		ctx.main.set("year", _saved_date[0])
		ctx.main.set("month", _saved_date[1])
		ctx.main.set("day", _saved_date[2])
	_saved_date = []
	ctx.hud(true)
