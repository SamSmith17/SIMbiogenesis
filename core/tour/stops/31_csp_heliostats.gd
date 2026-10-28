extends TourStop

## Concentrated solar: a parabolic trough on its east–west tracking axis and a
## dual-axis heliostat, placed side by side and swept through a summer day so
## both follow the real sun and their focal points glow with the live DNI.

## A clear summer date (the trough's tracking reads best with a high sun).
const DATE := [2026, 7, 18]

var _placed: PackedStringArray = PackedStringArray()
var _clock := {}
var _date := []


func _init() -> void:
	id = "csp_heliostats"
	title = "Concentrated solar: troughs and heliostats"
	chapter = "Systems"
	summary = "Mirrors that track the real sun and boil water into steam on the graph."
	how = PackedStringArray(["Press U for the library → Solar Concentrators, and place one",
		"G shows its node: tracking angle, DNI, thermal output, water in → steam out",
		"Scrub the timeline: the trough tilts and the heliostat turns with the sun"])
	action = "toggle_library"
	world = "burningman"
	budget_s = 45.0
	hour = 9.0
	blurb = ("A parabolic trough tilts on a single east–west axis to follow the sun's " +
		"altitude; a dual-axis heliostat points its whole dish at the sun. Both use the " +
		"real sun position and the clear-sky or measured direct irradiance, and on the " +
		"graph they turn water into steam at the rate their optics and receiver allow. " +
		"The focal line glows with the live concentrated flux.")


func run(ctx: TourContext) -> void:
	var m := ctx.main
	_clock = ctx.save_clock()
	_date = [m.get("year"), m.get("month"), m.get("day")]
	m.set("year", DATE[0])
	m.set("month", DATE[1])
	m.set("day", DATE[2])
	ctx.set_hour(9.0)
	ctx.clear_sky(true)
	var f := ctx.player_forward()
	var side := f.cross(Vector3.UP)
	var at := ctx.find_flat(ctx.player_xz() + Vector2(f.x, f.z) * 25.0, 14.0, 200.0, 10.0)
	var trough := await ctx.place_preset(ctx.preset("CSP_CONCENTRATORS", "csp_trough"), at)
	if not trough.is_empty():
		_placed.append(trough)
	var h_at := at + side * 13.0
	h_at.y = ctx.ground_y(h_at.x, h_at.z)
	var helio := await ctx.place_preset(ctx.preset("CSP_CONCENTRATORS", "heliostat"), h_at)
	if not helio.is_empty():
		_placed.append(helio)
	if not ctx.require(_placed.size() == 2, "a trough and a heliostat were placed"):
		return
	var centre := (at + h_at) * 0.5 + Vector3.UP * 2.0
	var eye := centre - f * 26.0 + Vector3.UP * 8.0
	ctx.place_camera(eye, centre)
	await ctx.wait(1.5)
	ctx.caption("Morning: the trough tilts on its east–west axis, the heliostat faces the low sun", 3.5)
	await ctx.wait(1.5)
	ctx.caption("Through the day — both track the real sun", 3.5)
	await ctx.scrub(9.0, 13.0, 5.0)
	await ctx.orbit(centre, 26.0, 8.0, 0.0, 35.0, 4.0)
	await ctx.hero(true)
	ctx.caption("Into the afternoon", 2.5)
	await ctx.scrub(13.0, 17.5, 4.0)


func teardown(ctx: TourContext) -> void:
	for pid in _placed:
		ctx.remove_prop(pid)
	_placed = PackedStringArray()
	var m := ctx.main
	if _date.size() == 3:
		m.set("year", _date[0])
		m.set("month", _date[1])
		m.set("day", _date[2])
	_date = []
	ctx.restore_clock(_clock)
	_clock = {}
