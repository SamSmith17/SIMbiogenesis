extends RefCounted

## Wind-blown dust on the Bombay Beach world, from its own weather (sandbox):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/bombay_dust_check.gd -Label <dir>
## Switches extreme weather on IN MEMORY (the world saves it off), parks the
## clock at hours picked from the site's 2024 Open-Meteo archive and asserts
## what the dust rule says about each, then shoots eye-level + oblique views
## (the case list in run() says which archive hour each one is). Then the two
## hazards forced side by side at a calm hour (the look swap):
##   force_smoke / force_dust at severity 0.7.
## Also checks the resolved severity is a pure function of the clock (forward
## then reversed). Nothing is saved.

var _fails: Array = []
var _dir := "user://screenshots/bombay_dust"


func _ok(cond: bool, what: String) -> void:
	print("dust-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _park(main: Node, y: int, mo: int, d: int, h: float) -> void:
	main.set("year", y)
	main.set("month", mo)
	main.set("day", d)
	main.set("day_time", h)


func _dump(xw: Node, label: String) -> Dictionary:
	var s: Dictionary = xw.call("current")
	var dd: Dictionary = xw.call("dust_drivers_now")
	var mph := float(dd.get("wind_ms", NAN)) / HazardEvaluators.MPH_TO_MS
	print("dust-check %s: wind %.1f mph, rain in window %.2f mm, ground x%.2f, wind-dust %.3f | hazard id=%s sev=%.3f src=%s vis=%.0f m layer=%.0f m bias=%.2f" % [
		label, mph, float(dd.get("rain_prev_mm", NAN)), float(dd.get("ground", 1.0)),
		float(dd.get("severity", 0.0)), str(s.get("id", "")), float(s.get("severity", 0.0)),
		str(s.get("source", "")), float(s.get("visibility_m", 0.0)),
		float(s.get("haze_layer_m", 0.0)), float(s.get("horizon_bias", 0.0))])
	return {"state": s, "drivers": dd}


func _shoot(main: Node, cam: Camera3D, eye: Vector3, fwd: Vector3, name: String) -> void:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	# Eye level, looking along the playa with some sky in frame.
	cam.global_position = eye
	cam.look_at(eye + fwd * 100.0 + Vector3(0.0, 8.0, 0.0), Vector3.UP)
	await _frames(tree, 45)
	vp.get_texture().get_image().save_png("%s/%s_eye.png" % [_dir, name])
	# Oblique from 70 m up: a low layer reads as a layer from here.
	cam.global_position = eye - fwd * 120.0 + Vector3(0.0, 70.0, 0.0)
	cam.look_at(eye + fwd * 250.0, Vector3.UP)
	await _frames(tree, 45)
	vp.get_texture().get_image().save_png("%s/%s_high.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var xw: Node = main.get_node_or_null("/root/ExtremeWeather")
	_ok(xw != null, "ExtremeWeather autoload is up")
	if xw == null:
		return {"ok": false}

	print("dust-check: world saves extreme weather %s; dust_storm opted in = %s; Drama = %.2f" % [
		"ON" if bool(xw.call("is_enabled")) else "OFF",
		str(ExtremeWeatherPrefs.is_enabled("dust_storm")), ExtremeWeatherPrefs.intensity])
	# In memory only: the snapshot is never saved by this script.
	xw.call("set_enabled", true)
	ExtremeWeatherPrefs.set_enabled("dust_storm", true)
	var drama := ExtremeWeatherPrefs.intensity
	main.set("time_scale", 0.0)
	var ui := main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false

	var cam := Camera3D.new()
	cam.far = 6000.0
	main.add_child(cam)
	main.call("push_camera_claim", "dust_check",
		{"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var player := main.get_node_or_null("Player") as Node3D
	var p := player.global_position if player != null else Vector3.ZERO
	var gy := TerrainSurfaceQuery.ground_height_at(main, p.x, p.z)
	if not is_finite(gy):
		gy = p.y
	var eye := Vector3(p.x, gy + 1.7, p.z)
	# Toward the open ground away from town: the player's facing, flattened.
	var fwd := Vector3(0, 0, -1)
	if player != null:
		fwd = -player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)

	# Feb 7 2024: rain fell around Feb 6 15:00-16:00, so 15:00 is still inside
	# the 24 h window and 17:00 just outside it. The Apr 14 pair is a DAYLIGHT
	# storm (15:00 28.5 mph, 12:00 6.3 mph). Leap-year archives are read on the
	# right day after Feb 29 (WeatherService.hour_index); before that fix the
	# clock's Apr 14 showed the archive's Apr 13.
	var cases := [
		{"name": "feb07_1200_calm_wet", "d": [2024, 2, 7, 12.0], "want": "none"},
		{"name": "feb07_1500_windy_rained", "d": [2024, 2, 7, 15.0], "want": "none"},
		{"name": "feb07_1700_windy_dry", "d": [2024, 2, 7, 17.0], "want": "dust"},
		{"name": "feb07_2300_breezy_dry", "d": [2024, 2, 7, 23.0], "want": "light"},
		{"name": "apr14_1200_calm", "d": [2024, 4, 14, 12.0], "want": "none"},
		{"name": "apr14_1500_storm", "d": [2024, 4, 14, 15.0], "want": "storm"},
	]
	for c: Dictionary in cases:
		var d: Array = c["d"]
		_park(main, int(d[0]), int(d[1]), int(d[2]), float(d[3]))
		xw.call("clear_forced")
		xw.call("invalidate")
		# Director tick (0.25 s) + the environment's easing.
		await tree.create_timer(1.5).timeout
		var ws := main.get_node_or_null("/root/WeatherService")
		print("dust-check %s: clock %d-%02d-%02d %.2f h (abs %.2f); WeatherService year %s, wind(m,d,h)=%.1f mph" % [
			c["name"], int(main.get("year")), int(main.get("month")), int(main.get("day")),
			float(main.get("day_time")), float(main.call("get_absolute_hours")),
			str(ws.get("_sim_year")) if ws != null else "-",
			float(ws.call("wind_speed_ms", int(d[1]), int(d[2]), float(d[3]))) / HazardEvaluators.MPH_TO_MS if ws != null else NAN])
		var r := _dump(xw, str(c["name"]))
		var s: Dictionary = r["state"]
		var dd: Dictionary = r["drivers"]
		var wind_sev := float(dd.get("severity", 0.0))
		match str(c["want"]):
			"dust":
				_ok(str(s.get("id", "")) == "dust_storm" and wind_sev > 0.2,
					"%s raises dust (wind-blown %.3f, hazard %.2f)" % [
						c["name"], wind_sev, float(s.get("severity", 0.0))])
			"storm":
				_ok(str(s.get("id", "")) == "dust_storm" and wind_sev > 0.4,
					"%s raises a dust storm (wind-blown %.3f, hazard %.2f)" % [
						c["name"], wind_sev, float(s.get("severity", 0.0))])
			"none":
				_ok(wind_sev < 0.005, "%s raises no wind-blown dust (%.3f)" % [c["name"], wind_sev])
			"light":
				_ok(wind_sev > 0.02 and wind_sev < 0.3,
					"%s raises light dust (%.3f)" % [c["name"], wind_sev])
		await _shoot(main, cam, eye, fwd, str(c["name"]))

	# The look swap, side by side at the calm hour.
	_park(main, 2024, 4, 14, 12.0)
	for f: Array in [["force_smoke", "wildfire_smoke", 0.7], ["force_dust", "dust_storm", 0.7],
			["force_dust_full", "dust_storm", 1.0]]:
		xw.call("force_hazard", f[1], float(f[2]), 24.0)
		await tree.create_timer(2.5).timeout
		_dump(xw, str(f[0]))
		await _shoot(main, cam, eye, fwd, str(f[0]))
	# Across the wind at full strength: the streaks and gust bands run
	# left-right through the frame.
	xw.call("force_hazard", "dust_storm", 1.0, 24.0)
	var across := Vector3(-fwd.z, 0.0, fwd.x)
	if main.has_method("_frame_wind_xz"):
		var w2: Vector2 = main.call("_frame_wind_xz", 4.0)
		if w2.length() > 0.05:
			across = Vector3(-w2.y, 0.0, w2.x).normalized()
	await tree.create_timer(2.0).timeout
	await _shoot(main, cam, eye, across, "force_dust_full_crosswind")
	xw.call("clear_forced")

	# Pure function of the clock: a week of windy-season hours forward, then the
	# same instants reversed.
	_park(main, 2024, 4, 14, 0.0)
	var t0 := float(main.call("get_absolute_hours"))
	var inst: Array[float] = []
	var fw: Array[float] = []
	for i in 56:
		var t := t0 + float(i) * 3.0
		inst.append(t)
		fw.append(float((xw.call("resolve_at", t) as Dictionary).get("severity", 0.0)))
	var dusty := 0
	var bad := 0
	for i in range(inst.size() - 1, -1, -1):
		var again := float((xw.call("resolve_at", inst[i]) as Dictionary).get("severity", 0.0))
		if absf(again - fw[i]) > 0.000001:
			bad += 1
		if again > 0.005:
			dusty += 1
	_ok(bad == 0, "resolved severity identical forward and reversed (%d mismatches)" % bad)
	print("dust-check: %d of %d sampled hours 2024-04-14..21 are dusty (Drama %.2f)" % [dusty, inst.size(), drama])

	main.call("pop_camera_claim", "dust_check")
	cam.queue_free()
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true
	var ok := _fails.is_empty()
	print("dust-check %s (%d failures)" % ["PASS" if ok else "FAIL", _fails.size()])
	return {"ok": ok, "failures": _fails}
