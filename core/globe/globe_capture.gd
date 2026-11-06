class_name GlobeCapture
extends RefCounted

## --capture=globe (kind "menu"): the 3D globe on the launch hub, with REAL
## input. Puts a GlobeView over the hub at a fixed instant (2026-03-20 15:00
## UTC: the Americas lit, Europe at dusk, Asia at night), and shoots:
## the whole Earth, the night side, Mount Vernon's region, the site at ~10 km,
## the site tilted, a pole. Asserts what a PNG cannot: tiles arrived, nothing
## failed past a few, a lat/lon -> screen -> pick round trip lands within
## 1e-4°, a real drag turns the globe, a real click reports the point under
## it, a real wheel notch zooms in toward the pointer, the poles draw caps,
## and the frame time at the site. One "globe: <what> PASS|FAIL" line each.

const JD_FIXED := 2461120.125   # 2026-03-20 15:00 UTC
const MV_LAT := 48.3252
const MV_LON := -122.2469


static func run(h: Node, shots_dir: String) -> int:
	var tree := h.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	var fails := 0
	for _i in 60:
		await tree.process_frame
	var layer := CanvasLayer.new()
	layer.layer = 60
	tree.root.add_child(layer)
	var gv := GlobeView.new()
	gv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gv.time_provider = func() -> float: return JD_FIXED
	layer.add_child(gv)
	await tree.process_frame
	var clicked := []
	gv.point_clicked.connect(func(la: float, lo: float) -> void: clicked.append([la, lo]))

	gv.look_at_point(20.0, -40.0, 2.8)
	fails += await _settle_and_shoot(h, gv, shots_dir, "01_earth")
	fails += _report("whole Earth: tiles drawn",
		gv.tile_fetcher().texture_count() >= 16, gv.debug_line())

	gv.look_at_point(30.0, 80.0, 2.4)
	fails += await _settle_and_shoot(h, gv, shots_dir, "02_night_side")
	var sun := gv.sun_direction()
	fails += _report("night side faces away from the Sun",
		sun.dot(GlobeMath.to_unit(30.0, 80.0)) < -0.2, "dot %.2f" % sun.dot(GlobeMath.to_unit(30.0, 80.0)))

	gv.fly_to(MV_LAT, MV_LON, 0.02)
	var waited := 0
	while gv.is_flying() and waited < 600:
		await tree.process_frame
		waited += 1
	fails += _report("fly-to arrives", not gv.is_flying(), "%d frames" % waited)
	var c := gv.center_latlon()
	fails += _report("fly-to lands on the target",
		absf(c[0] - MV_LAT) < 1e-3 and absf(c[1] - MV_LON) < 1e-3, "%.5f, %.5f" % [c[0], c[1]])
	fails += await _settle_and_shoot(h, gv, shots_dir, "03_region")

	gv.look_at_point(MV_LAT, MV_LON, 0.0016)
	fails += await _settle_and_shoot(h, gv, shots_dir, "04_site_10km")
	var zmax := 0
	for k in gv.selected_tiles():
		zmax = maxi(zmax, k.x)
	fails += _report("site view refines to >= z12", zmax >= 12, gv.debug_line())
	# Round trip: the site's screen point picks back to the site.
	var sp := gv.latlon_to_local(MV_LAT, MV_LON)
	var back := gv.pick(sp) if sp != Vector2.INF else PackedFloat64Array()
	var ok_rt := back.size() == 2 and absf(back[0] - MV_LAT) < 1e-4 and absf(back[1] - MV_LON) < 1e-4
	fails += _report("lat/lon -> screen -> pick round trip < 1e-4 deg", ok_rt,
		str(back) if back.size() == 2 else "missed at %s" % str(sp))
	# Frame time at the site.
	var t0 := Time.get_ticks_usec()
	for _f in 120:
		await tree.process_frame
	var ms := float(Time.get_ticks_usec() - t0) / 120000.0
	fails += _report("site view frame time < 33 ms", ms < 33.0, "%.1f ms" % ms)

	# Real input on the hub's viewport.
	var vp := h.get_viewport()
	var mid := gv.get_global_rect().get_center()
	var before := gv.center_latlon()
	await HarnessInput.drag(vp, mid, mid + Vector2(-300, 120), 16)
	for _f in 30:
		await tree.process_frame
	var after := gv.center_latlon()
	var moved_km := GlobeMath.great_circle_km(before[0], before[1], after[0], after[1])
	fails += _report("a real drag turns the globe", moved_km > 1.0, "%.2f km" % moved_km)
	var here := gv.pick(mid - gv.get_global_rect().position)
	await HarnessInput.click(vp, mid)
	for _f in 3:
		await tree.process_frame
	var ok_click := clicked.size() > 0 and here.size() == 2 \
		and GlobeMath.great_circle_km(float(clicked[-1][0]), float(clicked[-1][1]), here[0], here[1]) < 0.5
	fails += _report("a real click reports the point under it", ok_click, str(clicked))
	var r0 := gv.cam_range
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.factor = 1.0
	wheel.position = mid
	wheel.global_position = mid
	vp.push_input(wheel, true)
	for _f in 60:
		await tree.process_frame
	fails += _report("a real wheel notch zooms in", gv.cam_range < r0 * 0.9,
		"%.6f -> %.6f" % [r0, gv.cam_range])

	gv.look_at_point(MV_LAT, MV_LON, 0.003)
	gv.cam_tilt = 65.0
	gv.cam_heading = 40.0
	gv.look_at_point(MV_LAT, MV_LON, 0.003)
	fails += await _settle_and_shoot(h, gv, shots_dir, "05_site_tilted")
	fails += _report("tilt kept near the ground", gv.cam_tilt > 30.0, "%.0f" % gv.cam_tilt)

	gv.cam_tilt = 0.0
	gv.look_at_point(82.0, 30.0, 1.6)
	fails += await _settle_and_shoot(h, gv, shots_dir, "06_pole")
	var fetch := gv.tile_fetcher()
	fails += _report("few tile failures", int(fetch.stats.failed) <= 12,
		"downloaded %d, from disk %d, failed %d" % [int(fetch.stats.downloaded), int(fetch.stats.from_disk), int(fetch.stats.failed)])
	layer.queue_free()
	for _f in 3:
		await tree.process_frame
	fails += await _run_mode(h, shots_dir)
	print("globe: %s — %d failure(s); shots in %s" % ["PASS" if fails == 0 else "FAIL", fails,
		ProjectSettings.globalize_path(shots_dir)])
	return fails


static func _report(what: String, ok: bool, detail: String = "") -> int:
	print("globe: %s %s%s" % [what, "PASS" if ok else "FAIL", "" if detail.is_empty() else " (%s)" % detail])
	return 0 if ok else 1


## Waits for the tiles to settle (nothing pending for 20 frames, or 30 s) and
## saves a PNG of the whole window.
static func _settle_and_shoot(h: Node, gv: GlobeView, dir: String, name: String) -> int:
	var tree := h.get_tree()
	var quiet := 0
	var frames := 0
	while frames < 1800 and quiet < 20:
		await tree.process_frame
		frames += 1
		quiet = quiet + 1 if gv.tile_fetcher().pending_count() == 0 else 0
	await RenderingServer.frame_post_draw
	var img := h.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, name])
	print("globe: shot %s after %d frames — %s" % [name, frames, gv.debug_line()])
	return 0


## Globe mode (Phase 2) from the launch hub with REAL input: the hub's Globe
## button, the solar zones layer, a coordinate search, a world pin, a click on
## open ground (zone + kWh match GhiService), the layer toggles, UiAudit, Esc.
static func _run_mode(h: Node, shots_dir: String) -> int:
	var tree := h.get_tree()
	var vp := h.get_viewport()
	var fails := 0
	var hub: Node = null
	for n in tree.root.find_children("*", "Control", true, false):
		if n.has_method("hub_settings_panel"):
			hub = n
			break
	var btn := hub.find_child("HubGlobeButton", true, false) as Button if hub != null else null
	fails += _report("mode: the hub has a Globe button", btn != null)
	if btn == null:
		return fails
	await HarnessInput.click(vp, HarnessInput.center_of(btn))
	for _f in 10:
		await tree.process_frame
	var gm: GlobeMode = null
	for n in tree.root.find_children("*", "Control", true, false):
		if n is GlobeMode:
			gm = n
	fails += _report("mode: a real click on Globe opens it", gm != null)
	if gm == null:
		return fails
	gm.globe.time_provider = func() -> float: return JD_FIXED
	var waited := 0
	while not gm.globe.has_overlay() and waited < 1200:
		await tree.process_frame
		waited += 1
	fails += _report("mode: the solar zones layer is on", gm.globe.has_overlay(), "%d frames" % waited)
	fails += _report("mode: saved worlds are pins", gm.world_count() > 0, "%d" % gm.world_count())
	await _settle_and_shoot(h, gm.globe, shots_dir, "07_mode_zones")

	# Search by coordinates, typed and submitted with a real Enter.
	var search := gm.find_child("Search", true, false) as LineEdit
	await HarnessInput.click(vp, HarnessInput.center_of(search))
	search.text = "48.3252, -122.2469"
	await HarnessInput.key(vp, KEY_ENTER)
	for _f in 5:
		await tree.process_frame
	var card := gm.find_child("PointCard", true, false) as Control
	fails += _report("mode: a coordinate search selects the place", card.visible and gm._sel.size() == 2
		and absf(gm._sel[0] - MV_LAT) < 1e-4 and absf(gm._sel[1] - MV_LON) < 1e-4, str(gm._sel))
	waited = 0
	while gm.globe.is_flying() and waited < 600:
		await tree.process_frame
		waited += 1
	fails += _report("mode: search flies there", not gm.globe.is_flying()
		and gm.globe.altitude_km() < 200.0, "%.1f km" % gm.globe.altitude_km())
	await _settle_and_shoot(h, gm.globe, shots_dir, "08_mode_search")

	# A world pin near the target (the sandbox has the mtvernon world).
	var pin_rec: Dictionary = {}
	var pin_pos := Vector2.INF
	for rec in gm._worlds:
		var ll := WorldLauncher.world_latlon(rec)
		var sp := gm.globe.latlon_to_local(ll[0], ll[1])
		if sp != Vector2.INF and gm.globe.get_rect().has_point(sp):
			pin_rec = rec
			pin_pos = sp
			break
	if pin_rec.is_empty():
		print("globe: mode: no world pin on screen SKIP")
	else:
		await HarnessInput.click(vp, gm.globe.get_global_transform() * pin_pos)
		for _f in 5:
			await tree.process_frame
		var play := gm.find_child("PlayWorldButton", true, false) as Button
		fails += _report("mode: a real click on a world pin offers Play", play.visible
			and str(gm._sel_world.get("id", "")) == str(pin_rec.get("id", "?")), str(pin_rec.get("name", "")))

	# Open ground off to the side: a new-world card with the picker's numbers.
	var spot := gm.globe.size * Vector2(0.3, 0.7)
	await HarnessInput.click(vp, gm.globe.get_global_transform() * spot)
	for _f in 5:
		await tree.process_frame
	var create := gm.find_child("CreateWorldButton", true, false) as Button
	var ok_card := create.visible and gm._sel.size() == 2
	var zone_ok := false
	if ok_card:
		var ghi := tree.root.get_node_or_null("GhiService")
		var g := float(ghi.call("ghi_kwh_per_m2_day", gm._sel[0], gm._sel[1])) if ghi != null else NAN
		zone_ok = gm._card_zone.text.contains("%.1f kWh" % g)
	fails += _report("mode: a click on open ground offers Create world here", ok_card, str(gm._sel))
	fails += _report("mode: the card's kWh is the picker's own number", zone_ok, gm._card_zone.text)

	var mode := gm.find_child("ZonesMode", true, false) as OptionButton
	mode.select(1)
	mode.item_selected.emit(1)
	var lights := gm.find_child("LightsToggle", true, false) as CheckBox
	await HarnessInput.click(vp, HarnessInput.center_of(lights))
	fails += _report("mode: a real click turns city lights off", not gm.globe.night_lights)
	gm.globe.look_at_point(15.0, 20.0, 2.6)
	await _settle_and_shoot(h, gm.globe, shots_dir, "09_mode_smooth")
	fails += await _run_weather(h, gm, shots_dir)
	fails += await _run_perf(h, gm)
	fails += await _run_local(h, gm, shots_dir)
	var res := UiAudit.run(tree.root.get_viewport())
	print("globe: mode audit — %s" % UiAudit.summary_line(res))
	for f in (res.get("findings", []) as Array):
		var fd: Dictionary = f
		print("    %s %s %s %s %s" % [fd.get("severity", ""), fd.get("kind", ""), str(fd.get("path", "")).get_file(),
			str(fd.get("text", fd.get("detail", ""))).left(80), str(fd.get("rect", []))])
	fails += _report("mode: UI audit clean", int(res.get("errors", 0)) == 0, "%d error(s)" % int(res.get("errors", 0)))
	for _i in 3:
		if not is_instance_valid(gm):
			break
		await HarnessInput.key(vp, KEY_ESCAPE)
		for _f in 3:
			await tree.process_frame
	fails += _report("mode: Esc closes it", not is_instance_valid(gm) or gm.is_queued_for_deletion())
	return fails


## The weather layers (Phase 3) with REAL clicks: rain and the satellite of
## the day at the fixed instant (2026-03-20 15:00 UTC: a slot IMERG has),
## live clouds refused there (too old) and drawn at the real time, the time
## strip moving the data.
static func _run_weather(h: Node, gm: GlobeMode, shots_dir: String) -> int:
	var tree := h.get_tree()
	var vp := h.get_viewport()
	var fails := 0
	_select(gm.find_child("ColourBy", true, false) as OptionButton, GlobeMode.COLOUR_NONE)
	(gm.find_child("LightsToggle", true, false) as CheckBox).button_pressed = true
	gm.globe.look_at_point(20.0, -60.0, 2.6)
	await _click_toggle(vp, gm.find_child("RainToggle", true, false) as CheckBox)
	await _click_toggle(vp, gm.find_child("SatelliteToggle", true, false) as CheckBox)
	var waited := 0
	while not gm.globe.has_rain() and waited < 1800:
		await tree.process_frame
		waited += 1
	var dt := (gm.find_child("DataTimes", true, false) as Label).text
	fails += _report("weather: a real click turns rain on (IMERG at the globe's time)", gm.globe.has_rain()
		and dt.contains("Rain 2026-03-20 15:00 UTC"), dt)
	fails += _report("weather: the satellite of the day is that day's",
		gm.globe.base_layer == "daily_2026-03-20", gm.globe.base_layer)
	fails += _report("weather: live clouds are refused for an old date", not gm.globe.has_clouds()
		and dt.contains("last few hours"), dt)
	await _settle_and_shoot(h, gm.globe, shots_dir, "10_mode_satellite_rain")
	# Wind (on by default): the GFS run for that instant, streamlines drawn.
	waited = 0
	while gm.wind_line_segments() == 0 and waited < 2400:
		await tree.process_frame
		waited += 1
	dt = (gm.find_child("DataTimes", true, false) as Label).text
	fails += _report("wind: the GFS run for the globe's time (12z +3 h)", dt.contains("Wind GFS 2026-03-20 12z +3 h"), dt)
	fails += _report("wind: streamlines drawn", gm.wind_line_segments() > 10000, "%d segments" % gm.wind_line_segments())
	var wt := gm.wind_text(MV_LAT, MV_LON)
	fails += _report("wind: the hover readout names wind and temperature", wt.contains("m/s from") and wt.contains("°C"), wt)
	await _click_toggle(vp, gm.find_child("RainToggle", true, false) as CheckBox)
	await _click_toggle(vp, gm.find_child("SatelliteToggle", true, false) as CheckBox)
	_select(gm.find_child("ColourBy", true, false) as OptionButton, GlobeMode.COLOUR_TEMP)
	for _f in 10:
		await tree.process_frame
	fails += _report("wind: Colour by Temperature draws the GFS 2 m temperature", gm.globe.has_overlay()
		and (gm.find_child("Legend", true, false) as Control).visible)
	gm.globe.look_at_point(35.0, -40.0, 2.6)
	await _settle_and_shoot(h, gm.globe, shots_dir, "12_mode_wind_temperature")
	_select(gm.find_child("ColourBy", true, false) as OptionButton, GlobeMode.COLOUR_POWER)
	for _f in 10:
		await tree.process_frame
	fails += _report("wind: Colour by Wind power draws", gm.globe.has_overlay())
	await _settle_and_shoot(h, gm.globe, shots_dir, "13_mode_wind_power")
	_select(gm.find_child("ColourBy", true, false) as OptionButton, GlobeMode.COLOUR_NONE)
	await _click_toggle(vp, gm.find_child("RainToggle", true, false) as CheckBox)
	await _click_toggle(vp, gm.find_child("SatelliteToggle", true, false) as CheckBox)
	# The real time: live clouds.
	gm.globe.time_provider = func() -> float:
		return GlobeMath.jd_from_unix(Time.get_unix_time_from_system() + gm._time_offset_h * 3600.0)
	await _click_toggle(vp, gm.find_child("SatelliteToggle", true, false) as CheckBox)
	waited = 0
	while not gm.globe.has_clouds() and waited < 2400:
		await tree.process_frame
		waited += 1
	dt = (gm.find_child("DataTimes", true, false) as Label).text
	fails += _report("weather: live clouds load at the real time", gm.globe.has_clouds(), "%s (%d frames)" % [dt, waited])
	fails += _report("weather: back on the everyday imagery", gm.globe.base_layer == "esri", gm.globe.base_layer)
	gm.globe.look_at_point(10.0, 130.0, 2.6)
	await _settle_and_shoot(h, gm.globe, shots_dir, "11_mode_live_clouds")
	var slider := gm.find_child("TimeSlider", true, false) as HSlider
	slider.value = -24.0
	waited = 0
	while gm.globe.has_clouds() and waited < 300:
		await tree.process_frame
		waited += 1
	var tl := (gm.find_child("TimeLabel", true, false) as Label).text
	fails += _report("weather: the time strip goes back a day", tl.begins_with("24 h ago"), tl)
	fails += _report("weather: a day back, the live clouds stand down", not gm.globe.has_clouds())
	slider.value = 0.0
	return fails


## Picks an OptionButton item by id the way a click does (select + signal).
static func _select(ob: OptionButton, id: int) -> void:
	var i := ob.get_item_index(id)
	ob.select(i)
	ob.item_selected.emit(i)


## Phase 6: fly in to Mount Vernon (the callback stands in for the launch)
## and land on the world's own cached photos.
static func _run_local(h: Node, gm: GlobeMode, shots_dir: String) -> int:
	var tree := h.get_tree()
	var fails := 0
	# Local noon at Mount Vernon (2026-03-20 20:00 UTC) so the photos are lit.
	gm.globe.time_provider = func() -> float: return JD_FIXED + 5.0 / 24.0
	gm.globe.look_at_point(30.0, -100.0, 2.6)
	for _f in 10:
		await tree.process_frame
	var landed := [false]
	gm.fly_in(MV_LAT, MV_LON, func() -> void: landed[0] = true)
	var waited := 0
	while not landed[0] and waited < 1200:
		await tree.process_frame
		waited += 1
	fails += _report("local: fly in lands and then hands over", landed[0], "%d frames" % waited)
	fails += _report("local: the card stops saying Flying in", not gm._status.text.begins_with("Flying"), gm._status.text)
	fails += _report("local: it lands low and leaning", gm.globe.altitude_km() < 3.0 and gm.globe.cam_tilt > 40.0,
		"%.2f km, tilt %.0f" % [gm.globe.altitude_km(), gm.globe.cam_tilt])
	waited = 0
	while not gm.globe.drape_on(1) and waited < 600:
		await tree.process_frame
		waited += 1
	fails += _report("local: the world's own photos drape the globe", gm.drape_world() == "48.3252,-122.2469"
		and gm.globe.drape_on(0) and gm.globe.drape_on(1), "%s (%d frames)" % [gm.drape_world(), waited])
	await _settle_and_shoot(h, gm.globe, shots_dir, "14_fly_in")
	gm.globe.cam_tilt = 0.0
	gm.globe.look_at_point(MV_LAT, MV_LON, 0.0004)
	await _settle_and_shoot(h, gm.globe, shots_dir, "15_drape_topdown")
	# The same view with the photos off: the globe's own z17 tiles.
	gm.globe.set_drape(0, null)
	gm.globe.set_drape(1, null)
	await _settle_and_shoot(h, gm.globe, shots_dir, "16_tiles_only_topdown")
	gm._drape_world = ""
	gm.globe.look_at_point(MV_LAT, MV_LON, 2.6)
	waited = 0
	while gm.globe.drape_on(1) and waited < 300:
		await tree.process_frame
		waited += 1
	fails += _report("local: the photos come off again from orbit", not gm.globe.drape_on(1))
	return fails


## A real click on a check box, retried once when a stray real mouse motion
## ate it (the harness click race: the press and release a frame apart).
static func _click_toggle(vp: Viewport, cb: CheckBox) -> void:
	var before := cb.button_pressed
	await HarnessInput.click(vp, HarnessInput.center_of(cb))
	if cb.button_pressed == before:
		print("globe: click on %s did not land, retrying" % cb.name)
		await HarnessInput.click(vp, HarnessInput.center_of(cb))


## Phase 7 budget, every layer on at the real time (live clouds, rain, wind
## streamlines, solar zones, city lights), at three views: median frame time,
## the globe viewport's measured GPU time, tiles drawn, textures held, VRAM.
const PERF_FRAME_MS := 33.0
const PERF_GPU_MS := 12.0
const PERF_VRAM_MB := 2048.0


static func _run_perf(h: Node, gm: GlobeMode) -> int:
	var tree := h.get_tree()
	var fails := 0
	var gv := gm.globe
	for name in ["RainToggle", "WindToggle", "CloudsToggle", "LightsToggle"]:
		var cb := gm.find_child(name, true, false) as CheckBox
		if cb != null and not cb.button_pressed:
			cb.button_pressed = true
	_select(gm.find_child("ColourBy", true, false) as OptionButton, GlobeMode.COLOUR_ZONES)
	var waited := 0
	while (not gv.has_clouds() or not gv.has_rain() or gm.wind_line_segments() == 0) and waited < 2400:
		await tree.process_frame
		waited += 1
	print("globe: perf layers — clouds %s, rain %s, wind %d segments (%d frames)" % [
		gv.has_clouds(), gv.has_rain(), gm.wind_line_segments(), waited])
	var rid := gv._vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var views := [["whole Earth", 20.0, -40.0, 2.8, 0.0], ["region", MV_LAT, MV_LON, 0.05, 0.0],
		["site, tilted", MV_LAT, MV_LON, 0.004, 60.0]]
	for v in views:
		gv.cam_tilt = float(v[4])
		gv.look_at_point(float(v[1]), float(v[2]), float(v[3]))
		for _f in 120:
			await tree.process_frame
		var ft := PackedFloat64Array()
		var gpu := PackedFloat64Array()
		var t := Time.get_ticks_usec()
		for _f in 120:
			await tree.process_frame
			var now := Time.get_ticks_usec()
			ft.append(float(now - t) / 1000.0)
			t = now
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		ft.sort()
		gpu.sort()
		var f_med := ft[ft.size() / 2]
		var g_med := gpu[gpu.size() / 2]
		var vram := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
		var tiles := gv.selected_tiles().size()
		var tex := gv.tile_fetcher().texture_count()
		var detail := "frame %.1f ms (p95 %.1f), globe GPU %.2f ms, %d tiles, %d textures, VRAM %.0f MB" % [
			f_med, ft[int(ft.size() * 0.95)], g_med, tiles, tex, vram]
		fails += _report("perf %s: within budget" % str(v[0]), f_med < PERF_FRAME_MS and g_med < PERF_GPU_MS
			and tiles <= GlobeQuadtree.DEFAULT_MAX_TILES and tex <= 900 and vram < PERF_VRAM_MB, detail)
	RenderingServer.viewport_set_measure_render_time(rid, false)
	gv.cam_tilt = 0.0
	return fails
