extends SceneTree

## Headless validation for ClimelapseSeries, the drone-path rig, the timed
## camera keyframes (ClimelapseKeyframes), the export options maths
## (ClimelapseExportOptions) and the ffmpeg frame pipe (needs ffmpeg; counted
## as skipped without it). Carries EXPECTED_CHECKS: a runtime error aborts a
## test function while the suite would still print PASS.

const HOURS_PER_YEAR := 8760.0
const EXPECTED_CHECKS := 57

var _checks := 0


func _ok(cond: bool, what: String) -> int:
	_checks += 1
	if not cond:
		print("  FAIL: ", what)
		return 1
	return 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var fails := 0
	fails += _test_series_keyframes()
	fails += _test_drone_path_interpolate()
	fails += _test_keyframes_timed()
	fails += _test_keyframes_edit_and_roundtrip()
	fails += _test_rig_pose_at()
	fails += _test_export_options()
	fails += _test_path_editing()
	fails += _test_sky_options()
	fails += await _test_frame_pipe()
	if _checks != EXPECTED_CHECKS:
		fails += 1
		print("  check count %d, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if fails == 0:
		print("climelapse_series_selftest: PASS (%d checks)" % _checks)
	else:
		print("climelapse_series_selftest: FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _test_series_keyframes() -> int:
	var fails := 0
	var start := 1940.0 * HOURS_PER_YEAR + 60.0 * 24.0
	var end := start + 24.0 * 5.0
	var series := ClimelapseSeries.new()
	series.configure(start, end, 40.0, 1)
	var guard := 0
	while not series.is_complete() and guard < 20:
		series.fill_forward_chunk(0.0, 5)
		guard += 1
	fails += _ok(series.is_complete(), "series reaches is_complete()")
	fails += _ok(series.keyframe_count() == 5, "5 keyframes, got %d" % series.keyframe_count())
	fails += _ok(series.keyframe_index_at(start + 24.0 * 3.0) == 3, "keyframe_index_at day 3")
	var sample: Dictionary = series.sample_at(start)
	fails += _ok(not sample.is_empty() and sample.has("growth_clock_h"), "sample_at carries growth_clock_h")
	var json_path := "user://climelapse_selftest.json"
	var saved := series.save_json(json_path)
	var loaded := ClimelapseSeries.load_json(json_path) if saved else null
	fails += _ok(loaded != null and loaded.keyframe_count() == series.keyframe_count(), "series JSON round trip")
	DirAccess.remove_absolute(json_path)
	return fails


func _test_drone_path_interpolate() -> int:
	var fails := 0
	var rig := ClimelapseCameraRig.new()
	rig.valid = true
	rig.add_waypoint(Vector3(0, 10, 0), 0.0, -0.3)
	rig.add_waypoint(Vector3(100, 20, 0), PI * 0.5, -0.5)
	fails += _ok(rig.has_path(), "has_path with 2 waypoints")
	var mid := rig.interpolate_at(0.5)
	fails += _ok(absf(mid.origin.x - 50.0) <= 0.01 and absf(mid.origin.y - 15.0) <= 0.01, "path midpoint %s" % str(mid.origin))
	var end := rig.interpolate_at(1.0)
	fails += _ok(absf(end.origin.x - 100.0) <= 0.01, "path end %s" % str(end.origin))
	return fails


## Keys are pinned to TIME: the camera reaches each key's pose at its hour,
## eases out of the first and into the last, holds outside them, and passes
## through an interior key without stopping.
func _test_keyframes_timed() -> int:
	var f := 0
	var kf := ClimelapseKeyframes.new()
	var a := Transform3D(Basis.IDENTITY, Vector3(0, 10, 0))
	var b := Transform3D(Basis.from_euler(Vector3(-0.3, 1.0, 0)), Vector3(100, 20, 0))
	var c := Transform3D(Basis.IDENTITY, Vector3(100, 20, 100))
	kf.set_key(1000.0, a, 70.0)
	kf.set_key(1030.0, c, 90.0)
	kf.set_key(1010.0, b, 70.0)
	f += _ok(kf.size() == 3 and kf.times()[1] == 1010.0, "keys sorted by time")
	var at_b: Transform3D = kf.sample(1010.0)["xform"]
	f += _ok(at_b.origin.distance_to(b.origin) < 1e-3, "pose at a key's hour is that key (%s)" % str(at_b.origin))
	f += _ok(absf(at_b.basis.get_euler().y - 1.0) < 1e-3, "yaw at the key")
	f += _ok((kf.sample(990.0)["xform"] as Transform3D).origin.distance_to(a.origin) < 1e-4, "holds the first pose before it")
	f += _ok((kf.sample(2000.0)["xform"] as Transform3D).origin.distance_to(c.origin) < 1e-4, "holds the last pose after it")
	var p_ease: Vector3 = (kf.sample(1000.5)["xform"] as Transform3D).origin
	f += _ok(p_ease.x < 100.0 * 0.05 * 0.5, "eases out of the first key (x %.3f at 5%%)" % p_ease.x)
	f += _ok(absf(float(kf.sample(1020.0)["fov"]) - 80.0) < 1e-3, "fov lerps between keys")
	var p1: Vector3 = (kf.sample(1010.0)["xform"] as Transform3D).origin
	var p2: Vector3 = (kf.sample(1010.1)["xform"] as Transform3D).origin
	f += _ok(p1.distance_to(p2) > 0.01, "does not stop at an interior key")
	kf.smooth = false
	var lin: Vector3 = (kf.sample(1005.0)["xform"] as Transform3D).origin
	f += _ok(lin.distance_to(Vector3(50, 15, 0)) < 1e-3, "linear mode is a straight line (%s)" % str(lin))
	var w := ClimelapseKeyframes.new()
	w.set_key(0.0, Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(170.0), 0)), Vector3.ZERO))
	w.set_key(1.0, Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(-170.0), 0)), Vector3.ZERO))
	var mid_yaw := rad_to_deg((w.sample(0.5)["xform"] as Transform3D).basis.get_euler().y)
	f += _ok(absf(absf(mid_yaw) - 180.0) < 1.0, "yaw wraps the short way (mid %.1f)" % mid_yaw)
	return f


func _test_keyframes_edit_and_roundtrip() -> int:
	var f := 0
	var kf := ClimelapseKeyframes.new()
	kf.set_key(10.0, Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)), 60.0)
	kf.set_key(20.0, Transform3D(Basis.IDENTITY, Vector3(4, 5, 6)), 60.0)
	var i := kf.set_key(10.0 + ClimelapseKeyframes.SAME_MOMENT_H * 0.5, Transform3D(Basis.IDENTITY, Vector3(9, 9, 9)))
	f += _ok(kf.size() == 2 and i == 0, "a key at the same moment replaces it")
	var j := kf.move_key(0, 30.0)
	f += _ok(j == 1 and kf.times()[1] == 30.0, "retiming re-sorts (index %d)" % j)
	kf.repose_key(1, Transform3D(Basis.IDENTITY, Vector3(7, 7, 7)), 50.0)
	f += _ok((kf.key(1)["pos"] as Vector3) == Vector3(7, 7, 7) and kf.times()[1] == 30.0, "repose keeps the time")
	f += _ok(kf.index_near(29.0, 1.5) == 1 and kf.index_near(25.0, 1.0) == -1, "index_near tolerance")
	var path := "user://climelapse_keys_selftest.json"
	f += _ok(kf.save_json(path), "save_json")
	var back := ClimelapseKeyframes.load_json(path)
	f += _ok(back.size() == 2 and (back.key(1)["pos"] as Vector3) == Vector3(7, 7, 7)
		and absf(float(back.key(1)["fov"]) - 50.0) < 1e-6, "JSON round trip")
	DirAccess.remove_absolute(path)
	kf.remove_key(0)
	f += _ok(kf.size() == 1, "remove_key")
	var legacy := ClimelapseKeyframes.from_uniform_path([
		{"pos": Vector3.ZERO, "yaw": 0.0, "pitch": 0.0},
		{"pos": Vector3(10, 0, 0), "yaw": 0.0, "pitch": 0.0},
		{"pos": Vector3(20, 0, 0), "yaw": 0.0, "pitch": 0.0}], 100.0, 140.0)
	f += _ok(legacy.times() == PackedFloat64Array([100.0, 120.0, 140.0]), "untimed path spread over the range")
	return f


func _test_rig_pose_at() -> int:
	var f := 0
	var rig := ClimelapseCameraRig.new()
	rig.valid = true
	rig.global_xform = Transform3D(Basis.IDENTITY, Vector3(5, 5, 5))
	f += _ok((rig.pose_at(100.0, 0.5)["xform"] as Transform3D).origin == Vector3(5, 5, 5), "no keys = locked view")
	rig.keys = ClimelapseKeyframes.new()
	rig.keys.set_key(100.0, Transform3D(Basis.IDENTITY, Vector3(1, 1, 1)))
	f += _ok((rig.pose_at(500.0, 1.0)["xform"] as Transform3D).origin == Vector3(1, 1, 1), "one key = that view")
	return f


## No keys = a still shot from where the camera is, whatever the camera
## (the drone used to sweep a near-full circle); the editor's pose maths.
func _test_path_editing() -> int:
	var f := 0
	var rig := ClimelapseCameraRig.new()
	rig.valid = true
	rig.mode = "drone"
	rig.global_xform = Transform3D(Basis(Vector3.UP, 0.7), Vector3(3, 40, -2))
	var a: Transform3D = rig.pose_at(10.0, 0.0)["xform"]
	var b: Transform3D = rig.pose_at(34.0, 1.0)["xform"]
	f += _ok(a.is_equal_approx(rig.global_xform) and b.is_equal_approx(rig.global_xform), "drone with no keys holds still")
	var kf := ClimelapseKeyframes.new()
	kf.set_key(0.0, Transform3D.IDENTITY)
	kf.set_key(10.0, Transform3D(Basis.IDENTITY, Vector3(10, 0, 0)))
	kf.set_key(20.0, Transform3D(Basis.IDENTITY, Vector3(10, 0, 10)))
	kf.set_pose(1, Vector3(9, 1, 0), 7.0, 2.0, 500.0)
	var k1 := kf.key(1)
	f += _ok(absf(float(k1["pitch"]) - ClimelapseKeyframes.MAX_PITCH) < 1e-9 and float(k1["fov"]) == ClimelapseKeyframes.MAX_FOV
		and absf(float(k1["yaw"]) - wrapf(7.0, -PI, PI)) < 1e-9 and k1["pos"] == Vector3(9, 1, 0)
		and float(k1["t"]) == 10.0, "set_pose clamps pitch / fov, wraps yaw, keeps the time")
	var east := ClimelapseKeyframes.forward(ClimelapseKeyframes.yaw_for_heading(90.0), 0.0)
	f += _ok(east.is_equal_approx(Vector3(1, 0, 0)) and absf(ClimelapseKeyframes.heading_deg(ClimelapseKeyframes.yaw_for_heading(237.5)) - 237.5) < 1e-6,
		"heading 90° faces east (+X); heading ↔ yaw round trip")
	f += _ok(ClimelapseKeyframes.forward(0.0, deg_to_rad(30.0)).y > 0.49, "positive pitch looks up")
	var cs := ClimelapseKeyframes.frustum_corners(Transform3D.IDENTITY, 90.0, 2.0, 1.0)
	f += _ok(cs.size() == 4 and cs[0].is_equal_approx(Vector3(-2, 1, -1)) and cs[2].is_equal_approx(Vector3(2, -1, -1)),
		"frustum corners: vertical fov, aspect widens (%s)" % str(cs))
	kf.set_pose(1, Vector3(10, 0, 0), 0.0, 0.0, 75.0)
	var path := kf.sample_path(11)
	var unit := true
	for smp in path:
		unit = unit and absf(((smp as Dictionary)["fwd"] as Vector3).length() - 1.0) < 1e-5
	f += _ok(path.size() == 11 and ((path[0] as Dictionary)["pos"] as Vector3).is_equal_approx(Vector3.ZERO)
		and ((path[10] as Dictionary)["pos"] as Vector3).is_equal_approx(Vector3(10, 0, 10))
		and float((path[5] as Dictionary)["t"]) == 10.0 and unit, "sample_path spans first → last key, unit view vectors")
	return f


## Analemma framing, star-trail exposure, and the follow-cam maths.
func _test_sky_options() -> int:
	var f := 0
	var o := ClimelapseExportOptions.normalize({"start_abs": 41.0 * 24.0 + 10.0, "end_abs": 71.0 * 24.0 + 3.0,
		"analemma": 1, "analemma_days": 1, "fps": 30})
	f += _ok(ClimelapseExportOptions.frame_count(o) == 31, "analemma: one frame per calendar day (got %d)" % ClimelapseExportOptions.frame_count(o))
	o["analemma_days"] = 7
	f += _ok(ClimelapseExportOptions.frame_count(o) == 5 and absf(ClimelapseExportOptions.frame_hours(o, 1) - (48.0 * 24.0 + 12.0)) < 1e-9,
		"analemma every 7 days: 5 frames, frame 1 a week on")
	var day := ClimelapseSkyDirector.trail_state(NAN, 100.0, 10.0)
	var dusk := ClimelapseSkyDirector.trail_state(NAN, 100.0, -10.0)
	var later := ClimelapseSkyDirector.trail_state(float(dusk["night_start"]), 102.0, -30.0)
	f += _ok(float(day["trails"]) == 0.0 and is_nan(float(day["night_start"])) and float(dusk["trails"]) == 0.0
		and float(later["trails"]) == 1.0 and absf(float(later["length"]) - (2.0 * ClimelapseSkyDirector.SIDEREAL_DEG_PER_H - 8.0) / 40.0) < 1e-6,
		"star trails: closed by day, open at dusk, grow at the sky's rate")
	var s0 := StarSkyMath.equatorial_to_world_basis(30.0, 48.3)
	var s1 := StarSkyMath.equatorial_to_world_basis(75.0, 48.3)
	var cam := Basis(Vector3.UP, 1.1) * Basis(Vector3.RIGHT, 0.4)
	var star := Vector3(0.3, -0.5, 0.81).normalized()
	var seen0 := cam.inverse() * (s0 * star)
	var cam1 := ClimelapseSkyDirector.follow_stars_basis(cam, s0, s1)
	var seen1 := cam1.inverse() * (s1 * star)
	f += _ok(seen0.is_equal_approx(seen1) and not (s0 * star).is_equal_approx(s1 * star),
		"follow the stars: a star keeps its place in the frame while the sky turns")
	var d := Vector3(1, 1, -2).normalized()
	var lb := ClimelapseSkyDirector.look_basis(d, Basis.IDENTITY)
	f += _ok((-lb.z).is_equal_approx(d) and absf(lb.x.y) < 1e-6, "follow the sun: looks at it with the horizon level")
	return f


func _test_export_options() -> int:
	var f := 0
	var o := ClimelapseExportOptions.normalize({"start_abs": 1000.0, "end_abs": 1024.0,
		"hours_per_second": 2.0, "fps": 30, "width": 1921, "height": 1081,
		"folder": "C:\\Videos", "file_name": "a/b:c"})
	f += _ok(int(o["width"]) == 1920 and int(o["height"]) == 1080, "size rounds to even")
	f += _ok(absf(ClimelapseExportOptions.hours_per_frame(o) - 2.0 / 30.0) < 1e-9, "hours per frame")
	f += _ok(ClimelapseExportOptions.frame_count(o) == 361, "24 h at Max, 30 fps = 361 frames (got %d)" % ClimelapseExportOptions.frame_count(o))
	f += _ok(absf(ClimelapseExportOptions.frame_hours(o, 360) - 1024.0) < 1e-6, "last frame lands on the end")
	f += _ok(ClimelapseExportOptions.output_path(o) == "C:/Videos/b_c.mp4", "output path (%s)" % ClimelapseExportOptions.output_path(o))
	f += _ok(float(ClimelapseExportOptions.TIME_PRESETS[ClimelapseExportOptions.MAX_PRESET][1]) == 2.0
		and str(ClimelapseExportOptions.TIME_PRESETS[ClimelapseExportOptions.MAX_PRESET][0]).begins_with("Max"),
		"Max preset == the bar's Max (2 h/s)")
	f += _ok(ClimelapseExportOptions.preset_for_rate(24.0) == 7 and ClimelapseExportOptions.preset_for_rate(3.3) == -1, "preset_for_rate")
	f += _ok(ClimelapseExportOptions.frame_count({"start_abs": 5.0, "end_abs": 5.0}) == 0, "empty range = 0 frames")
	f += _ok(ClimelapseExportOptions.format_timecode(2024, 4, 18, 13.5) == "2024-04-18   13:30", "timecode")
	var tc := ClimelapseExportOptions.format_timecode(2024, 4, 18, 23.9999)
	f += _ok(tc == "2024-04-18   00:00" or tc == "2024-04-18   23:59", "timecode wraps cleanly (%s)" % tc)
	var args := ClimelapseExportOptions.ffmpeg_pipe_args(o, "C:/Videos/x.mp4")
	f += _ok(args.has("rawvideo") and args.has("rgb24") and args.has("1920x1080") and args.has("yuv420p")
		and args[args.size() - 1] == "C:/Videos/x.mp4", "ffmpeg pipe args")
	var bad := ClimelapseExportOptions.normalize({"fps": 999, "msaa": 3, "settle_frames": 0, "quality": 9})
	f += _ok(int(bad["fps"]) == 120 and int(bad["msaa"]) == -1 and int(bad["settle_frames"]) == 1
		and int(bad["quality"]) == 3, "normalize clamps")
	var cfg := "user://climelapse_export_selftest.cfg"
	ClimelapseExportOptions.save_prefs(o, cfg)
	var back := ClimelapseExportOptions.load_prefs(cfg)
	f += _ok(int(back["width"]) == 1920 and float(back["hours_per_second"]) == 2.0
		and str(back["folder"]) == "C:/Videos", "prefs round trip")
	DirAccess.remove_absolute(cfg)
	return f


## The pipe on its own: 12 coloured RGB8 frames through ffmpeg; the result is
## probed for frame count and size, and its middle frame read back must not be
## black (the 2026-10-22 bug was 1350 all-black frames).
func _test_frame_pipe() -> int:
	var f := 0
	var ffmpeg := ClimelapseVideoEncoder.find_ffmpeg()
	if ffmpeg.is_empty():
		print("  SKIP frame pipe: no ffmpeg")
		_checks += 5
		return 0
	var dir := OS.get_user_data_dir().path_join("climelapse_pipe_selftest")
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir.path_join("pipe.mp4")
	var o := ClimelapseExportOptions.normalize({"width": 160, "height": 90, "fps": 12, "crf": 18})
	var pipe := ClimelapseFramePipe.new()
	f += _ok(pipe.open(ffmpeg, o, out).is_empty(), "ffmpeg starts")
	for i in 12:
		var img := Image.create(160, 90, false, Image.FORMAT_RGB8)
		img.fill(Color(0.2 + 0.05 * i, 0.6, 0.3))
		while pipe.queued() >= ClimelapseFramePipe.MAX_QUEUE:
			await process_frame
		pipe.push(img)
	var wrong := Image.create(10, 10, false, Image.FORMAT_RGB8)
	f += _ok(not pipe.push(wrong), "a frame of the wrong size is refused")
	var res: Dictionary = await pipe.close(self)
	f += _ok(bool(res.get("ok", false)) and int(res.get("frames", 0)) == 12, "pipe closes ok with 12 frames (%s)" % str(res))
	var probe: Array = []
	var ffprobe := ffmpeg.get_base_dir().path_join("ffprobe.exe") if OS.get_name() == "Windows" else "ffprobe"
	OS.execute(ffprobe, ["-v", "error", "-count_frames", "-show_entries",
		"stream=nb_read_frames,width,height", "-of", "csv=p=0", out], probe)
	var line := str(probe[0]).strip_edges() if not probe.is_empty() else ""
	f += _ok(line == "160,90,12" or not FileAccess.file_exists(ffprobe), "ffprobe: '%s' (%s)" % [line, ffprobe])
	var png := dir.path_join("mid.png")
	OS.execute(ffmpeg, ["-v", "error", "-y", "-ss", "0.5", "-i", out, "-frames:v", "1", png], [])
	var mid := Image.load_from_file(png) if FileAccess.file_exists(png) else null
	var c := mid.get_pixel(80, 45) if mid != null else Color.BLACK
	f += _ok(c.g > 0.4 and c.r > 0.3, "a decoded frame has the picture (%s)" % str(c))
	for fn in ["pipe.mp4", "mid.png"]:
		DirAccess.remove_absolute(dir.path_join(fn))
	DirAccess.remove_absolute(dir)
	return f
