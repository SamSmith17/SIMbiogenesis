extends RefCounted

## "Shoreline over time" on the Bombay Beach world (sandbox; network):
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/checks/shoreline_history_check.gd -Label shoreline -Timeout 1800
## 1. Lake level: the Salton Sea gauge read (or its cached record), the lake
##    drawn as the level plane, the clock parked at 1990 / 2000 / 2010 /
##    2018 / 2026 — the plane follows the gauge, and the water edge measured
##    along a transect from the site to the lake moves seaward as the sea
##    falls. Shots per date from the same oblique camera. A backward scrub
##    reproduces the first reading (pure function of the clock).
## 2. Imagery: the distinct Wayback captures over the site listed (asserting
##    the dedupe), the 2011 capture pinned and its detail drape awaited, then
##    "follow the clock" at 2017 swapping to that year's capture. Shots of the
##    shore with each drape. Nothing is saved (the sandbox is thrown away).

var _fails: Array = []
var _dir := "user://screenshots/shoreline"


func _ok(cond: bool, what: String) -> void:
	print("shoreline-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _park(main: Node, date: String, hour: float = 11.0) -> void:
	main.set("year", date.substr(0, 4).to_int())
	main.set("month", date.substr(5, 2).to_int())
	main.set("day", date.substr(8, 2).to_int())
	main.set("day_time", hour)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s).timeout


## Wait (real seconds) until cond() is true; false on timeout.
func _until(tree: SceneTree, cond: Callable, max_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if float(Time.get_ticks_msec() - t0) / 1000.0 > max_s:
			return false
		await tree.create_timer(0.5).timeout
	return true


## Distance (m) from `from` along `dir` to the first point the lake's water
## stands on (ShorelineHistory.wet_at: the reach mask); INF within `reach`.
func _edge_distance(sh: ShorelineHistory, from: Vector2, dir: Vector2, reach: float) -> float:
	var d := 0.0
	while d <= reach:
		var p := from + dir * d
		if sh.wet_at(p.x, p.y):
			return d
		d += 5.0
	return INF


## Points of a 50 m grid round the site that lie below the drawn level but
## that the lake cannot reach (kept dry by a berm or a rise).
func _dry_pockets(sh: ShorelineHistory, loader: Node, level_y: float) -> int:
	var n := 0
	for gx in range(-60, 61):
		for gz in range(-60, 61):
			var x := gx * 50.0
			var z := gz * 50.0
			if float(loader.call("_ground_height_at", x, z)) < level_y - 0.2 and not sh.wet_at(x, z):
				n += 1
	return n


func _shoot(main: Node, cam: Camera3D, target: Vector3, back: Vector3, name: String) -> void:
	cam.global_position = target + back
	cam.look_at(target, Vector3.UP)
	await _wait(main.get_tree(), 1.2)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	print("shoreline-check shot %s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	_ok(loader != null and loader.has_method("shoreline_history"), "TerrainLoader with shoreline history")
	if loader == null:
		return {"ok": false}
	var sh: ShorelineHistory = loader.call("shoreline_history")
	main.set("time_scale", 0.0)
	var ui := main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false

	# --- 1. lake level --------------------------------------------------------
	_ok(not sh.gauge().is_empty(), "a lake gauge for the site (%s)" % str(sh.gauge().get("name", "none")))
	sh.set_lake_level(true)
	var got := await _until(tree, func() -> bool: return str(sh.gauge_status()["status"]) in ["ready", "failed"], 120.0)
	var gs := sh.gauge_status()
	_ok(got and str(gs["status"]) == "ready", "gauge record read (%s .. %s, %s)" % [gs["first"], gs["last"], gs["note"]])
	_ok(absf(float(gs["shift_m"]) - 0.534) < 0.01, "NGVD29 → NAVD88 shift at the gauge %.3f m" % float(gs["shift_m"]))
	loader.call("_attach_water")
	await _wait(tree, 0.5)
	_ok(await _until(tree, func() -> bool: return sh.spill_ready(), 120.0), "the lake reach mask was built")
	var plane := (main.get_node_or_null("Terrain") as Node).get_node_or_null("LakeLevel") as MeshInstance3D \
		if main.get_node_or_null("Terrain") != null else null
	_ok(plane != null and sh.lake_plane_active(), "the level plane stands in for the lake")
	var lake: Array = sh.get("_lake_items")
	_ok(not lake.is_empty(), "the Salton Sea's OSM body found (%d)" % lake.size())
	print("shoreline-check: DEM's own lake surface %.2f m NAVD88, centre elev %.2f" % [
		sh.dem_water_m(), float(loader.get("_built_center_elev"))])

	# Transect: from the site centre toward the nearest point of the lake.
	var dir := Vector2(0, 1)
	var best := INF
	for it_v in lake:
		var poly: PackedVector2Array = (it_v as Dictionary)["points"]
		for i in poly.size():
			var c := Geometry2D.get_closest_point_to_segment(Vector2.ZERO, poly[i], poly[(i + 1) % poly.size()])
			if c.length() < best and c.length() > 1.0:
				best = c.length()
				dir = c.normalized()
	print("shoreline-check: lake outline %.0f m from the site centre, toward (%.2f, %.2f)" % [best, dir.x, dir.y])

	var cam := Camera3D.new()
	cam.far = 12000.0
	main.add_child(cam)
	main.call("push_camera_claim", "shoreline_check", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})
	var center_elev := float(loader.get("_built_center_elev"))

	var dates := ["1990-06-01", "2000-06-01", "2010-06-01", "2018-06-01", "2026-09-01"]
	var levels: Array = []
	var edges: Array = []
	var first_target := Vector3.ZERO
	for date: String in dates:
		_park(main, date)
		await _wait(tree, 0.4)
		var lv := sh.level_now()
		var y := sh.drawn_level_m() - center_elev
		levels.append(lv)
		var e := _edge_distance(sh, Vector2.ZERO, dir, 6000.0)
		edges.append(e)
		print("shoreline-check %s: %d grid points below the level kept dry (berm / no path from the lake)" % [
			date, _dry_pockets(sh, loader, y)])
		print("shoreline-check %s: level %.2f m NAVD88 (gauge %.2f ft), plane y %.2f, water edge %.0f m along the transect" % [
			date, lv, float((sh.gauge_status()["level_info"] as Dictionary).get("ft", NAN)),
			plane.position.y if plane != null else NAN, e])
		if date == dates[0]:
			var ed := e if is_finite(e) else best
			var pe := dir * ed
			first_target = Vector3(pe.x, y, pe.y)
		await _shoot(main, cam, first_target, Vector3(-dir.x * 260.0, 160.0, -dir.y * 260.0) + Vector3(dir.y, 0, -dir.x) * 140.0,
			"level_%s" % date.substr(0, 4))
	# The Salton Sea ROSE through the 1990s (it peaked about 1995-97) and has
	# fallen since: monotone from 2000 on, and 1990 above 2026.
	for i in range(2, levels.size()):
		_ok(float(levels[i]) < float(levels[i - 1]), "the sea is lower in %s than %s (%.2f < %.2f)" % [
			dates[i], dates[i - 1], float(levels[i]), float(levels[i - 1])])
	_ok(float(levels[1]) > float(levels[0]) - 0.5, "2000 within the 1990s high stand (%.2f vs %.2f)" % [
		float(levels[1]), float(levels[0])])
	_ok(absf(float(levels[0]) - float(levels[-1])) > 3.0, "1990 → 2026 the level fell %.2f m" % (float(levels[0]) - float(levels[-1])))
	var moved := 0
	for i in range(1, edges.size()):
		if is_finite(float(edges[i])) and is_finite(float(edges[i - 1])) and float(edges[i]) > float(edges[i - 1]) + 4.0:
			moved += 1
	_ok(is_finite(float(edges[0])) and is_finite(float(edges[3])) and float(edges[3]) > float(edges[0]) + 50.0,
		"the water edge moved seaward 1990 → 2018 (%.0f m → %.0f m)" % [float(edges[0]), float(edges[3])])
	# 2026 is below the DEM's own lake: the plane sits on it, never vanishes.
	_park(main, "2026-09-01")
	await _wait(tree, 0.4)
	_ok(not sh.level_below_dem() or (plane != null and plane.visible
			and absf(plane.position.y - (sh.dem_water_m() - center_elev) - WaterBuilder.SURFACE_OFFSET_M) < 0.01),
		"a level below the DEM's lake is drawn at the DEM's lake (below: %s)" % str(sh.level_below_dem()))
	_park(main, dates[0])
	await _wait(tree, 0.4)
	_ok(is_equal_approx(sh.level_now(), float(levels[0])), "scrubbing back to 1990 gives the 1990 level again")

	# --- 2. imagery ------------------------------------------------------------
	sh.ensure_captures()
	got = await _until(tree, func() -> bool: return str(sh.captures_status()["status"]) in ["ready", "failed"], 180.0)
	var caps := sh.captures()
	_ok(got and caps.size() >= 5, "distinct Wayback captures over the site: %d (%s)" % [caps.size(), sh.captures_status()["note"]])
	var dates_c: Array = caps.map(func(c: Dictionary) -> String: return str(c["date"]))
	print("shoreline-check captures: %s" % ", ".join(PackedStringArray(caps.map(func(c: Dictionary) -> String:
		return WaybackCatalog.capture_label(c) + " [r%d]" % int(c["release"])))))
	var uniq := {}
	for d in dates_c:
		uniq[d] = true
	_ok(uniq.size() == dates_c.size(), "no capture date listed twice")
	if caps.is_empty():
		return {"ok": _fails.is_empty(), "fails": _fails}
	var img := main.get_node_or_null("/root/ImageryService")
	var shown := {"key": ""}
	var on_ready := func(key: String, _t: Variant, tag: String) -> void:
		if tag == "detail":
			shown["key"] = key
	img.connect("imagery_ready", on_ready)

	# The current drape first, at the 2026 level.
	_park(main, "2026-09-01")
	await _wait(tree, 0.5)
	await _shoot(main, cam, first_target, Vector3(-dir.x * 600.0, 520.0, -dir.y * 600.0), "drape_today")
	# Pin the oldest capture.
	var oldest: Dictionary = caps[0]
	shown["key"] = ""
	sh.set_mode("pinned", int(oldest["release"]))
	var want := "_wayback_%d" % int(oldest["release"])
	got = await _until(tree, func() -> bool: return str(shown["key"]).ends_with(want), 900.0)
	_ok(got, "the %s capture's detail drape arrived (%s)" % [oldest["date"], shown["key"]])
	_park(main, "1990-06-01")
	await _wait(tree, 2.0)
	await _shoot(main, cam, first_target, Vector3(-dir.x * 600.0, 520.0, -dir.y * 600.0), "drape_%s_level_1990" % str(oldest["date"]).substr(0, 4))
	# Follow the clock: 2017-12 → the latest capture on or before it.
	var expect := WaybackCatalog.capture_at(caps, "2017-12-01")
	_park(main, "2017-12-01")
	shown["key"] = ""
	sh.set_mode("follow")
	var want2 := "_wayback_%d" % int(expect["release"])
	got = await _until(tree, func() -> bool: return str(shown["key"]).ends_with(want2), 900.0)
	_ok(got and str(sh.shown_capture().get("date", "")) == str(expect["date"]),
		"follow at 2017-12-01 shows the %s capture" % str(expect["date"]))
	await _wait(tree, 2.0)
	await _shoot(main, cam, first_target, Vector3(-dir.x * 600.0, 520.0, -dir.y * 600.0), "drape_follow_2017")
	img.disconnect("imagery_ready", on_ready)
	main.call("pop_camera_claim", "shoreline_check")
	cam.queue_free()
	print("shoreline-check: %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
