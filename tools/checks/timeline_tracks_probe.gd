extends RefCounted

## Timeline tracks: weather and Home Assistant sensors (sandbox, fake HA):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/timeline_tracks_probe.gd -Label tl_tracks
## - Tracks ▾ has Add power / weather / Home Assistant / Remove submenus, and
##   choosing an item through the menu's own handler adds the track (the old
##   handler read metadata by id, so every "＋" item did nothing);
## - a weather track fills its lane from WeatherService over a 36 h window;
## - Pick any sensor… opens the picker, a REAL click on a row adds the track,
##   and the lane fills from the fake HA's history, then a live change;
## - Remove a track removes it. Shots under screenshots/tl_tracks/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("tl-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _until(tree: SceneTree, cond: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await tree.process_frame
	return true


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/tl_tracks"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _find(root: Node, pred: Callable) -> Node:
	if bool(pred.call(root)):
		return root
	for c in root.get_children():
		var r := _find(c, pred)
		if r != null:
			return r
	return null


## Choose the item labelled `text` in `menu` through the menu's own handler.
func _choose(tl: Node, menu: PopupMenu, text: String) -> bool:
	for i in menu.item_count:
		if menu.get_item_text(i).begins_with(text):
			tl.call("_on_tracks_menu_id_pressed", menu.get_item_id(i), menu)
			return true
	return false


func _track_of(layout: Variant, source: String, channel: String) -> TimelineTrackDef:
	for t in layout.get("tracks"):
		if t is TimelineTrackDef and (t as TimelineTrackDef).source == source and (t as TimelineTrackDef).channel == channel:
			return t
	return null


func _waveform_cache_clear(tl: Node) -> void:
	var c: Variant = tl.get("_waveform_cache")
	if c is Dictionary:
		(c as Dictionary).clear()


func _redraw(tl: Node) -> void:
	var tr: Variant = tl.get("_track")
	if tr is CanvasItem:
		(tr as CanvasItem).queue_redraw()


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var tl: Node = main.get_node_or_null("UILayer/TimelineUI")
	_ok(tl != null, "the timeline exists")
	if tl == null:
		return {"ok": false, "fails": _fails}
	tl.call("_setup_tracks_menu")
	tl.call("_rebuild_tracks_menu")
	var subs: Dictionary = tl.get("_tracks_subs")
	_ok(subs.has("power") and subs.has("weather") and subs.has("ha") and subs.has("remove"), "Tracks ▾ has its submenus")
	var wx: PopupMenu = subs.get("weather")
	_ok(wx != null and wx.item_count >= 8, "the weather submenu lists %d variables" % (wx.item_count if wx != null else 0))
	var layout: Variant = tl.get("_track_layout")
	var view: Variant = tl.get("_track_view")
	# A 36 h window ending a little after NOW, held still.
	var now_h := HaObservedStore.now_abs_hours()
	# HA tracks are real time, so put the playhead at NOW (the timeline keeps
	# its window around the playhead).
	if main.has_method("set_absolute_hours"):
		main.call("set_absolute_hours", now_h)
	main.set("time_scale", 0.0)
	await _settle(tree, 5)
	view.set("follow_playhead", false)
	view.call("set_span", 36.0)
	view.set("start", now_h - 33.0)

	# ---- power: the menu path that never worked ----
	_ok(_choose(tl, subs["power"], "Net (simulated)"), "the power submenu offers Net (simulated)")
	_ok(_track_of(layout, "sim", "net_kw") != null, "choosing it adds the track (the id-as-index bug is gone)")

	# ---- weather ----
	_ok(_choose(tl, wx, "Temperature"), "choose Weather → Temperature")
	_ok(_choose(tl, wx, "Wind speed"), "choose Weather → Wind speed")
	_ok(_choose(tl, wx, "Solar radiation"), "choose Weather → Solar radiation")
	var tt := _track_of(layout, "weather", "wx_temp_c")
	_ok(tt != null and tt.enabled, "the temperature track is on the timeline")
	_redraw(tl)
	await _settle(tree, 20)
	var cache: Dictionary = tl.get("_waveform_cache")
	var tbd: Dictionary = (cache.get(tt.id, {}) as Dictionary).get("bins", {}) if tt != null else {}
	var tb: PackedFloat32Array = tbd.get("mean", PackedFloat32Array())
	var finite := 0
	var lo := INF
	var hi := -INF
	for v in tb:
		if not is_nan(v):
			finite += 1
			lo = minf(lo, v)
			hi = maxf(hi, v)
	var ws := tree.root.get_node_or_null("WeatherService")
	var has_wx := ws != null and bool(ws.call("has_data"))
	print("tl-check: weather data loaded=%s, temperature bins %d finite, %.1f…%.1f °C" % [has_wx, finite, lo, hi])
	if has_wx:
		_ok(finite >= tb.size() * 0.8 and hi > lo, "the temperature lane is drawn from the weather data (%d / %d bins)" % [finite, tb.size()])
		_ok(lo > -50.0 and hi < 55.0, "…with plausible temperatures")
	else:
		print("tl-check: SKIP no weather data in this sandbox")

	# ---- any Home Assistant sensor ----
	var svc: Node = tree.root.get_node_or_null("HomeAssistant")
	var tok := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJwcm9iZTAxMjM0NTY3ODlhYmNkZWYiLCJpYXQiOjE3MDAwMDAwMDB9.probeprobeprobeprobeprobeprobeprobeprobe_-xy"
	var srv := HaFakeServer.new()
	srv.token = tok
	var now_u := Time.get_unix_time_from_system()
	srv.set_entity("sensor.probe_outdoor", "14.2", {"unit_of_measurement": "°C", "device_class": "temperature", "friendly_name": "Probe outdoor"})
	srv.set_entity("sensor.probe_weather", "Sunny", {"friendly_name": "Probe forecast text"})
	# A sawtooth (a reading every 10 min, 0..5 per hour) on a slow swell: the
	# shape that used to turn smooth at some zoom levels.
	var hist: Array = []
	for k in 180:
		hist.append({"s": "%.2f" % (10.0 + float(k % 6) + 2.0 * sin(float(k) / 30.0)), "lu": now_u - (30.0 - float(k) / 6.0) * 3600.0})
	srv.history["sensor.probe_outdoor"] = hist
	main.add_child(srv)
	srv.start(38900 + randi() % 200)
	svc.call("connect_with", srv.url(), tok, "Probe", false)
	await _until(tree, func() -> bool: return bool(svc.call("is_authed")) and int(svc.call("catalog_size")) >= 2, 5.0)
	_ok(bool(svc.call("is_authed")), "connected to the fake Home Assistant")
	tl.call("_rebuild_tracks_menu")
	var ha: PopupMenu = subs["ha"]
	_ok(not ha.is_item_disabled(0), "Pick any sensor… is enabled once connected")
	_choose(tl, ha, "Pick any sensor")
	await _settle(tree, 20)
	var picker: Node = _find(tl, func(n: Node) -> bool:
		return n.get_script() != null and str((n.get_script() as Script).resource_path).ends_with("ha_entity_picker.gd"))
	_ok(picker != null, "the sensor picker opens")
	if picker != null:
		var list: VBoxContainer = picker.get("_list")
		var texts: Array = []
		for c in list.get_children():
			texts.append((c as Button).text)
		_ok(texts.size() == 1 and str(texts[0]).begins_with("Probe outdoor"), "it lists the numeric sensor, not the text one (%s)" % str(texts))
		_shot(main, "01_picker")
		if not texts.is_empty():
			HarnessInput.click(main.get_viewport(), HarnessInput.center_of(list.get_child(0) as Control))
			await _settle(tree, 10)
	var et := _track_of(layout, "ha_entity", "sensor.probe_outdoor")
	_ok(et != null and et.label == "HA: Probe outdoor", "clicking the sensor adds its track")
	_ok(bool(svc.call("is_tracked", "sensor.probe_outdoor")), "…and the service records it")
	_redraw(tl)
	var filled := await _until(tree, func() -> bool:
		_redraw(tl)
		return int(svc.call("entity_reading_count", "sensor.probe_outdoor")) >= 170, 5.0)
	_ok(filled, "the window is filled from Home Assistant's history (%d readings)" % int(svc.call("entity_reading_count", "sensor.probe_outdoor")))
	await _settle(tree, 70)
	var ebd: Dictionary = (cache.get(et.id, {}) as Dictionary).get("bins", {}) if et != null else {}
	var eb: PackedFloat32Array = ebd.get("mean", PackedFloat32Array())
	var ef := 0
	for v in eb:
		if not is_nan(v):
			ef += 1
	_ok(ef >= eb.size() * 0.6, "the sensor lane has values across the window (%d / %d bins)" % [ef, eb.size()])
	_shot(main, "02_timeline_tracks")

	# ---- zoom: the same data at five zoom levels keeps its shape ----
	var ranges := {}
	for span in [6.0, 12.0, 36.0, 96.0, 168.0]:
		view.call("set_span", span)
		view.set("start", now_h - span * 0.9)
		_redraw(tl)
		await _settle(tree, 25)
		var ebz: Dictionary = (cache.get(et.id, {}) as Dictionary).get("bins", {})
		var tbz: Dictionary = (cache.get(tt.id, {}) as Dictionary).get("bins", {})
		var er := TimelineBinning.value_range(ebz)
		var trz := TimelineBinning.value_range(tbz)
		ranges[span] = [er, trz]
		print("tl-check: span %5.0f h: bin %.3f h, sensor range %.2f..%.2f, temperature range %.2f..%.2f" % [
			span, float(ebz.get("w", 0.0)), er.x, er.y, trz.x, trz.y])
		_shot(main, "03_zoom_%03dh" % int(span))
	# The visible window always holds the 30 h of readings at 36 h and wider,
	# so the band must span the same values there.
	var ok_band := true
	var ref: Vector2 = (ranges[36.0] as Array)[0]
	for span in [96.0, 168.0]:
		var r: Vector2 = (ranges[span] as Array)[0]
		ok_band = ok_band and absf(r.x - ref.x) < 0.05 and absf(r.y - ref.y) < 0.05
	_ok(ok_band, "zooming out keeps the sensor's full range (the sawtooth stays a band)")
	# Anchored bins: a pan by a fraction of a bin leaves every shared bin alone.
	view.call("set_span", 36.0)
	view.set("start", now_h - 33.0)
	_redraw(tl)
	await _settle(tree, 25)
	var b_a: Dictionary = (cache.get(tt.id, {}) as Dictionary).get("bins", {}).duplicate(true)
	view.set("start", now_h - 33.0 + float(b_a.get("w", 0.1)) * 0.37)
	_waveform_cache_clear(tl)
	_redraw(tl)
	await _settle(tree, 25)
	var b_b: Dictionary = (cache.get(tt.id, {}) as Dictionary).get("bins", {})
	var same := true
	var off := int(b_b.get("i0", 0)) - int(b_a.get("i0", 0))
	for k in int(b_b.get("n", 0)):
		var ka := k + off
		if ka < 0 or ka >= int(b_a.get("n", 0)):
			continue
		var x: float = (b_a["mean"] as PackedFloat32Array)[ka]
		var y: float = (b_b["mean"] as PackedFloat32Array)[k]
		if not (is_nan(x) and is_nan(y)) and x != y:
			same = false
	_ok(same, "panning by a fraction of a bin does not resample (temperature bins identical)")
	# Cost of the power lanes over a week (the heaviest case).
	var sol: Node = ServiceLocator.solar_ui()
	if sol != null:
		var g := TimelineBinning.grid(now_h - 168.0, now_h, TimelineBinning.bin_width(168.0, 1800.0, 1.0 / 60.0))
		var t0 := Time.get_ticks_usec()
		for ch in ["solar_kw", "load_kw", "soc_pct"]:
			sol.call("get_timeline_bins", "live", ch, TimelineBinning.bin_width(168.0, 1800.0, 1.0 / 60.0), int(g["i0"]), int(g["n"]))
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("tl-check: three power lanes over a week: %.1f ms" % ms)
		_ok(ms < 40.0, "binning a week of three power lanes stays cheap (%.1f ms)" % ms)

	# ---- remove ----
	tl.call("_rebuild_tracks_menu")
	var n0 := (layout.get("tracks") as Array).size()
	_ok(_choose(tl, subs["remove"], "HA: Probe outdoor"), "Remove a track lists the sensor track")
	_ok((layout.get("tracks") as Array).size() == n0 - 1 and _track_of(layout, "ha_entity", "sensor.probe_outdoor") == null, "…and removes it")
	for spec in [["weather", "wx_temp_c"], ["weather", "wx_wind_ms"], ["weather", "wx_ghi_wm2"], ["sim", "net_kw"]]:
		var t := _track_of(layout, spec[0], spec[1])
		if t != null:
			layout.call("remove_track", t.id)
	tl.call("_tracks_changed")
	view.set("follow_playhead", true)
	svc.call("disconnect_ha")
	srv.stop()
	srv.queue_free()
	return {"ok": _fails.is_empty(), "fails": _fails}
