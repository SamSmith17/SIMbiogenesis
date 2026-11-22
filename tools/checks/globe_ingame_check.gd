extends RefCounted

## Globe mode in a running world (sandbox, read-only): Shift+L (toggle_globe,
## a REAL key event through the viewport) opens it over the world, the 3D
## world stops drawing, the "You are here" pin is the world's own lat/lon,
## the sun follows the sim clock (moving the clock moves it), Esc closes it
## and hands disable_3d back; L alone still opens the 2D picker, not the globe.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/globe_ingame_check.gd -Label globe_ingame

var _fails := 0


func _ok(cond: bool, what: String, detail: String = "") -> void:
	if not cond:
		_fails += 1
	print("globe-ingame %s: %s%s" % ["PASS" if cond else "FAIL", what, "" if detail.is_empty() else " (%s)" % detail])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var d3_before := vp.disable_3d
	await HarnessInput.key(vp, KEY_L, false, true)
	for _f in 10:
		await tree.process_frame
	_ok(main.call("globe_mode_open"), "Shift+L opens Globe mode")
	var gm: GlobeMode = main.get("_globe_mode")
	if gm == null:
		return {"ok": false}
	_ok(vp.disable_3d, "the 3D world stops drawing behind it")
	var pick := main.get_node_or_null("UILayer/LocationPickerUI") as Control
	_ok(pick == null or not pick.visible, "Shift+L did not also open the 2D picker")
	var lat := float(main.get("latitude"))
	var lon := float(main.get("longitude"))
	var here := gm.globe.latlon_to_local(lat, lon)
	var waited := 0
	while gm.globe.is_flying() and waited < 600:
		await tree.process_frame
		waited += 1
	here = gm.globe.latlon_to_local(lat, lon)
	var back := gm.globe.pick(here) if here != Vector2.INF else PackedFloat64Array()
	_ok(back.size() == 2 and absf(back[0] - lat) < 1e-3 and absf(back[1] - lon) < 1e-3,
		"opens on the world's own site", "%s vs %.4f, %.4f" % [str(back), lat, lon])
	var s0 := gm.globe.sun_direction()
	var clock: Object = main.get("clock")
	var h0 := float(clock.call("get_absolute_hours"))
	clock.call("set_absolute_hours", h0 + 6.0)
	for _f in 40:
		await tree.process_frame
	var s1 := gm.globe.sun_direction()
	var turned := rad_to_deg(s0.angle_to(s1))
	_ok(absf(turned - 90.0) < 5.0, "the sun follows the sim clock (6 h = 90 deg)", "%.1f deg" % turned)
	clock.call("set_absolute_hours", h0)
	# Rain follows the sim clock: the slot the readout names is the one for
	# the sim's instant (or the newest one served when the sim is ahead).
	var rain := gm.find_child("RainToggle", true, false) as CheckBox
	await HarnessInput.click(vp, HarnessInput.center_of(rain))
	var waited_r := 0
	while not gm.globe.has_rain() and waited_r < 1800:
		await tree.process_frame
		waited_r += 1
	var want := GlobeWeather.iso(GlobeWeather.rain_slot(gm.globe_unix(), Time.get_unix_time_from_system()))
	var dt := (gm.find_child("DataTimes", true, false) as Label).text
	_ok(gm.globe.has_rain(), "rain loads on the sim clock", dt)
	_ok(dt.contains("Rain " + want.substr(0, 16).replace("T", " ")), "the rain slot is the sim clock's", "%s / %s" % [dt, want])
	_ok(gm.globe.has_outline("soi") and gm.globe.has_outline("map"), "the SoI ring and the map's square are drawn")
	var wind := gm.find_child("WindToggle", true, false) as CheckBox
	if wind != null and not wind.button_pressed:
		wind.button_pressed = true
	var waited_w := 0
	while gm.wind_line_segments() == 0 and waited_w < 2400:
		await tree.process_frame
		waited_w += 1
	gm.select_here()
	var txt := gm.site_weather_text()
	_ok(txt.contains("In the sim now") and txt.contains("GFS here"), "This world compares the sim's weather with GFS", txt.replace("\n", " | "))
	gm.globe.look_at_point(lat, lon, 0.004)
	var waited_d := 0
	while not gm.globe.drape_on(1) and waited_d < 900:
		await tree.process_frame
		waited_d += 1
	_ok(gm.globe.drape_on(1), "zoomed in, the world's own photos drape the globe", gm.drape_world())
	for _f in 60:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label") if harness != null else "globe_ingame")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	vp.get_texture().get_image().save_png("%s/ingame_globe.png" % dir)
	for _i in 4:
		if not main.call("globe_mode_open"):
			break
		await HarnessInput.key(vp, KEY_ESCAPE)
		for _f in 3:
			await tree.process_frame
	_ok(not main.call("globe_mode_open"), "Esc closes it")
	_ok(vp.disable_3d == d3_before, "the 3D world draws again")
	await HarnessInput.key(vp, KEY_L)
	for _f in 6:
		await tree.process_frame
	_ok(not main.call("globe_mode_open"), "plain L does not open the globe")
	if pick != null and pick.visible and pick.has_method("hide_picker"):
		pick.call("hide_picker")
	return {"ok": _fails == 0}
