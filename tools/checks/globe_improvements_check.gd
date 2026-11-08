extends RefCounted

## Globe curtains, polar caps, a year of time, city-light points and the Moon at its
## true distance (sandbox, Mount Vernon):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/globe_improvements_check.gd -Label globe_improvements
## Nothing is written into the world.

var _fails := 0
var _dir := "user://screenshots/globe_improvements"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("globe-improvements %s: %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else " (%s)" % detail])
	if not cond:
		_fails += 1


func _shoot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var gm: GlobeMode = main.call("open_globe_mode")
	for _f in 20:
		await tree.process_frame
	_ok(gm != null and main.call("globe_mode_open"), "the globe opens")
	if gm == null:
		return {"ok": false}
	# Light the pole that is in day, so the cap picture is not crushed by night.
	var now0 := gm.globe.current_jd()
	var lit := now0
	var lit_lat := GlobeMath.subsolar_point(now0)[0]
	for i in range(-180, 181, 5):
		var la := GlobeMath.subsolar_point(now0 + float(i))[0]
		if absf(la) > absf(lit_lat):
			lit_lat = la
			lit = now0 + float(i)
	gm.set_time_offset_h((lit - now0) * 24.0)
	var pole_lat := 88.0 if lit_lat > 0.0 else -88.0
	gm.globe.look_at_point(pole_lat, 0.0, 1.35)
	for _f in 20:
		await tree.process_frame
	_ok(gm.globe.poles_textured(), "the polar caps carry a picture, not a flat colour")
	await _shoot(main, "01_pole")
	# Aurora curtains, forced to a storm so the ribbons are bright.
	gm.globe.set_aurora(true, 9.0)
	gm.globe.look_at_point(64.0, -80.0, 1.55)
	for _f in 8:
		await tree.process_frame
	var span := gm.globe.aurora_curtain_span()
	_ok(span.x > 1.01 and span.y > 1.05, "the aurora curtains stand off the globe",
		"%.4f .. %.4f" % [span.x, span.y])
	await _shoot(main, "02_aurora_limb")
	# The same solstice the pole shot used, then a season and half a year from it.
	var best := lit
	gm.set_time_offset_h((best - now0) * 24.0)
	for _f in 5:
		await tree.process_frame
	var sub := GlobeMath.subsolar_point(gm.globe.current_jd())
	_ok(sub[0] > 20.0 or sub[0] < -20.0, "the year strip reaches a solstice, sun over a tropic",
		"%.2f" % sub[0])
	gm.globe.set_paths(true, false, false)
	for _f in 3:
		await tree.process_frame
	_ok(absf(gm.globe.path_marker_lat() - sub[0]) < 1.5,
		"the subsolar marker sits on that latitude", "%.2f vs %.2f" % [gm.globe.path_marker_lat(), sub[0]])
	var label := (gm.find_child("TimeLabel", true, false) as Label).text
	_ok(label.contains("UTC"), "the time strip shows the date", label)
	gm.globe.look_at_point(sub[0], sub[1], 2.5)
	for _f in 10:
		await tree.process_frame
	await _shoot(main, "03_tropic")
	gm.set_time_offset_h((best - 91.0 - now0) * 24.0)
	for _f in 3:
		await tree.process_frame
	var back := GlobeMath.subsolar_point(gm.globe.current_jd())
	_ok(absf(back[0]) < 8.0, "a season from that solstice is near an equinox", "%.2f" % back[0])
	gm.set_time_offset_h((best - 182.0 - now0) * 24.0)
	for _f in 3:
		await tree.process_frame
	var other := GlobeMath.subsolar_point(gm.globe.current_jd())
	_ok(absf(other[0]) > 20.0, "half a year from that solstice is the other tropic", "%.2f" % other[0])
	# City lights are points now: a night view over Europe should have some.
	gm.set_time_offset_h(0.0)
	var sub_now := GlobeMath.subsolar_point(gm.globe.current_jd())
	gm.globe.look_at_point(48.0, wrapf(sub_now[1] + 180.0, -180.0, 180.0), 1.6)
	var waited := 0
	while gm.globe.city_lights().point_count() == 0 and waited < 900:
		await tree.process_frame
		waited += 1
	_ok(gm.globe.city_lights().point_count() > 200, "city lights are drawn as points on the night side",
		"%d points in %d tiles" % [gm.globe.city_lights().point_count(), gm.globe.city_lights().tile_count()])
	await _shoot(main, "02b_city_lights")
	# The Moon stands at its true distance from the Earth view...
	var dist_r := gm.globe.moon_distance_km() / GlobeMath.EARTH_RADIUS_KM
	_ok(dist_r > 55.0 and dist_r < 64.0, "the Moon is drawn at its real distance", "%.1f Earth radii" % dist_r)
	# ...and the view can orbit it, with the Earth over its horizon.
	gm.globe.set_primary_body("moon")
	gm.globe.set_moon_irradiance(true)
	for _f in 12:
		await tree.process_frame
	_ok(gm.globe.primary_body() == "moon", "the Moon is the globe the view orbits")
	var cam := gm.globe.camera()
	var alt_moon := gm.globe.altitude_km()
	_ok(alt_moon > 1000.0 and alt_moon < 6000.0, "the camera stands a few Moon radii up", "%.0f km" % alt_moon)
	_ok(not cam.is_position_behind(Vector3.ZERO) and cam.is_position_in_frustum(Vector3.ZERO),
		"the Earth is in frame from the Moon (an Earthrise)")
	var ll := MoonGlobe.subsolar_latlon(gm.globe.current_jd())
	var watts := MoonGlobe.irradiance_at(ll[0], ll[1], gm.globe.current_jd())
	_ok(absf(watts - SolarIrradiance.SOLAR_CONSTANT) < 1.0,
		"the Moon's subsolar point gets the full solar constant", "%.1f" % watts)
	var search := gm.find_child("Search", true, false) as Control
	_ok(search != null and not search.visible, "place search is hidden on the Moon")
	await _shoot(main, "04_moon")
	var sel := gm.globe.pick(gm.globe.size * 0.5)
	_ok(sel.size() == 2, "a click on the Moon picks selenographic coordinates", str(sel))
	gm.globe.set_primary_body("earth")
	for _f in 8:
		await tree.process_frame
	_ok(gm.globe.primary_body() == "earth", "centring the Earth again restores it")
	_ok(search.visible, "place search is back")
	_ok(gm.globe.altitude_km() > 1000.0, "the Earth view came back where it was", "%.0f km" % gm.globe.altitude_km())
	return {"ok": _fails == 0}
