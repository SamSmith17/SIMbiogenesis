extends RefCounted

## Rain that looks like its real rate, on Tropical Storm Hilary at Bombay
## Beach (sandbox):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/bombay_rain_check.gd -Label <dir>
## Parks the clock on archive hours of 2023-08-20 (PDT) and shoots each from
## the player's eye, where the rain volume is centred:
##   09:00  no rain
##   10:00  0.3 mm/h  (light),    22 km/h wind
##   12:00  13.3 mm/h (heavy),    20 km/h wind
##   15:00  5.7 mm/h  (moderate), 40 km/h wind  (slanted)
## Asserts the rain the game is drawing follows the rate: bigger, faster, more
## drops for heavy rain, and slanted downwind in strong wind. Nothing is saved.

var _fails: Array = []
var _dir := "user://screenshots/bombay_rain"


func _ok(cond: bool, what: String) -> void:
	print("rain-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var ws: Node = main.get_node_or_null("/root/WeatherService")
	var solar: Node = main.find_child("SolarUI", true, false)
	var pv: Node = main.get_node_or_null("PrecipitationVfx")
	_ok(ws != null and solar != null and pv != null, "WeatherService, SolarUI and PrecipitationVfx are up")
	if ws == null or solar == null or pv == null:
		return {"ok": false}
	main.set("time_scale", 0.0)
	var ui := main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false

	main.set("year", 2023)
	main.set("month", 8)
	main.set("day", 20)
	main.set("day_time", 9.0)
	ws.call("notify_location_changed", float(main.get("latitude")), float(main.get("longitude")))
	var waited := 0.0
	while waited < 90.0 and not (int(ws.get("_data_year")) == 2023 and not bool(ws.get("_fetching"))):
		await tree.create_timer(0.5).timeout
		waited += 0.5
	_ok(int(ws.get("_data_year")) == 2023, "2023 weather loaded (%.0f s)" % waited)

	var player := main.get_node_or_null("Player") as Node3D
	var pcam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D if player != null else null
	# Stand the player on the ground (the rain volume is centred on their eye),
	# a few metres off any prop at the saved spot.
	if player != null:
		var p := player.global_position + Vector3(6.0, 0.0, 6.0)
		var gy := TerrainSurfaceQuery.ground_height_at(main, p.x, p.z)
		print("rain-check: player was at y %.1f, ground %.1f" % [player.global_position.y, gy])
		player.global_position = Vector3(p.x, gy + 0.05, p.z)
		if "velocity" in player:
			player.set("velocity", Vector3.ZERO)
		player.process_mode = Node.PROCESS_MODE_DISABLED
	var cam := Camera3D.new()
	cam.far = 4000.0
	main.add_child(cam)
	main.call("push_camera_claim", "rain_check",
		{"camera_id": cam.get_instance_id(), "hide_player_mesh": true})

	var looks := {}
	for c: Array in [["0900_dry", 9.0], ["1000_light", 10.0], ["1200_heavy", 12.0], ["1500_windy", 15.0]]:
		main.set("day_time", float(c[1]))
		# The weather blend, the particle fill (a drop lives ~4-8 s) and the
		# lighting all ease in.
		await tree.create_timer(8.0).timeout
		var rate := float(solar.call("_current_precip_rate_mmh"))
		var wind := float(ws.call("wind_speed_ms", 8, 20, float(c[1])))
		var wdir: Vector2 = pv.get("_rain_wind_dir")
		var look: Dictionary = PrecipitationVfx.rain_look(rate, wind, wdir)
		looks[c[0]] = look
		var rp: GPUParticles3D = pv.get("rain_particles")
		print("rain-check %s: rate %.2f mm/h (%s), wind %.1f km/h, drop %.2f mm, falls %.2f m/s, slant %.0f deg, streak %.3f x %.3f m, drops %.0f%% (emitting %s)" % [
			c[0], rate, look["class"], wind * 3.6, float(look["diameter_mm"]), float(look["fall_ms"]),
			float(look["slant_deg"]), float(look["width_m"]), float(look["length_m"]),
			rp.amount_ratio * 100.0, str(rp.emitting)])
		# Eye level, looking across the wind so a slant shows.
		var eye := pcam.global_position if pcam != null else Vector3(0, 2, 0)
		var across := Vector3(-wdir.y, 0.0, wdir.x)
		if across.length() < 0.1:
			across = Vector3(1, 0, 0)
		cam.global_position = eye
		cam.look_at(eye + across.normalized() * 10.0 + Vector3(0.0, -0.6, 0.0), Vector3.UP)
		await tree.create_timer(1.0).timeout
		main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, c[0]])

	var dry: Dictionary = looks["0900_dry"]
	var lt: Dictionary = looks["1000_light"]
	var hv: Dictionary = looks["1200_heavy"]
	var wn: Dictionary = looks["1500_windy"]
	_ok(str(dry["class"]) == "none", "09:00 draws no rain")
	_ok(str(lt["class"]) == "light", "10:00 is light rain (%s)" % lt["class"])
	_ok(str(hv["class"]) == "heavy", "12:00 is heavy rain (%s)" % hv["class"])
	_ok(float(hv["diameter_mm"]) > float(lt["diameter_mm"]) * 1.5
		and float(hv["fall_ms"]) > float(lt["fall_ms"]) + 1.5
		and float(hv["density"]) > float(lt["density"]) * 1.5,
		"heavy rain: bigger, faster, denser than light")
	_ok(float(wn["slant_deg"]) > float(hv["slant_deg"]) + 5.0,
		"15:00's 40 km/h wind slants the rain more than 12:00 (%.0f vs %.0f deg)" % [
			float(wn["slant_deg"]), float(hv["slant_deg"])])

	if player != null:
		player.process_mode = Node.PROCESS_MODE_INHERIT
	main.call("pop_camera_claim", "rain_check")
	cam.queue_free()
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true
	var ok := _fails.is_empty()
	print("rain-check %s (%d failures)" % ["PASS" if ok else "FAIL", _fails.size()])
	return {"ok": ok, "failures": _fails}
