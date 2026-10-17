extends TourStop

## Wind turbines on the real site wind: a horizontal-axis turbine yawing into
## the wind and a vertical-axis one beside it, both bound to graph nodes whose
## output follows P = ½ρAC_p·v³ at hub height.

var _placed: PackedStringArray = PackedStringArray()


func _init() -> void:
	id = "wind_turbines"
	title = "Wind turbines"
	chapter = "Systems"
	summary = "HAWTs and VAWTs that spin and yaw on the site's real wind and feed the graph."
	how = PackedStringArray(["Press U for the library → Wind, and place a turbine",
		"G shows its node: live wind at hub height and output",
		"Click a placed turbine to move it or swap its model"])
	action = "toggle_library"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("Turbine output is P = ½ρAC_p·v³ under the Betz limit, with air density " +
		"from altitude and temperature and the 10 m wind sheared to hub height. The " +
		"wind is the site's archived or forecast weather for the clock's hour, the " +
		"same wind the trees and the dust blow in, and the rotors spin and yaw to it.")


func run(ctx: TourContext) -> void:
	# A horizontal- and a vertical-axis turbine side by side on open ground.
	var f := ctx.player_forward()
	var side := f.cross(Vector3.UP)
	var at := ctx.find_flat(ctx.player_xz() + Vector2(f.x, f.z) * 20.0, 8.0, 160.0, 10.0)
	var h_at := at - side * 4.5
	h_at.y = ctx.ground_y(h_at.x, h_at.z)
	var v_at := at + side * 4.5
	v_at.y = ctx.ground_y(v_at.x, v_at.z)
	for pair in [["small_hawt", h_at], ["vawt", v_at]]:
		var pid := await ctx.place_preset(ctx.preset("WIND_TURBINES", str(pair[0])), pair[1] as Vector3)
		if not pid.is_empty():
			_placed.append(pid)
	ctx.require(_placed.size() == 2, "a HAWT and a VAWT were placed")
	var ws := ctx.autoload("WeatherService")
	var m := ctx.main
	var wind := NAN
	if ws != null and bool(ws.call("has_data")):
		wind = float(ws.call("wind_speed_ms", int(m.get("month")), int(m.get("day")), float(m.get("day_time"))))
	var centre := at + Vector3.UP * 4.0
	ctx.caption("Wind now: %s at 10 m — the rotors run on the real weather" % (
		"%.1f m/s" % wind if is_finite(wind) else "synthetic"), 3.5)
	await ctx.orbit(centre, 17.0, 1.0, -40.0, 10.0, 5.0)
	await ctx.hero(true)
	ctx.caption("Each turbine is a node on the graph: P = ½ρAC_p·v³", 3.0)
	await ctx.orbit(centre, 17.0, 1.0, 10.0, 45.0, 4.0)


func teardown(ctx: TourContext) -> void:
	for pid in _placed:
		ctx.remove_prop(pid)
	_placed = PackedStringArray()
