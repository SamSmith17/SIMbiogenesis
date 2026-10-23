extends RefCounted

## Video export end to end on a REAL world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/clim_export_probe.gd -Label clim_export -Timeout 1500
## Ctrl-drag selection of one day → 🎬 opens the options dialog (range
## pre-filled from the selection) → speed "Max" → three camera keyframes →
## Preview (clock + camera claimed, clock walks at the export speed, both handed
## back) → Export through the dialog's own button → waits for ffmpeg. Then
## ffprobe: frame count, size, duration; three frames (04:00, 12:00, 20:00)
## pulled out as PNGs into screenshots\clim_export\ and their brightness read
## back (the 2026-10-22 bug was all-black video). Finally the world must be
## exactly as found: time_scale, analemma, no clock or camera claim, the game
## window drawing 3D again.

const LABEL := "clim_export"
var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("clim-export %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var tl_ui: Node = main.get_node_or_null("UILayer/TimelineUI")
	var solar: Node = main.get_node_or_null("UILayer/SolarUI")
	_ok(loader != null and tl_ui != null and solar != null, "loader, timeline and SolarUI are up")
	if loader == null or tl_ui == null or solar == null:
		return {"ok": false}
	var ffmpeg := ClimelapseVideoEncoder.find_ffmpeg()
	_ok(not ffmpeg.is_empty(), "ffmpeg found (%s)" % ffmpeg)
	if ffmpeg.is_empty():
		return {"ok": false}

	var scale0 := float(main.get("time_scale"))
	var analemma0 := bool(main.get("analemma_mode"))
	# One calendar day from midnight of the day the world is on.
	var now_h := float(main.call("get_absolute_hours"))
	var day0 := floorf(now_h / 24.0) * 24.0
	solar.call("set_selection_abs", day0, day0 + 24.0)

	# Three keyframes round the player: 00:00 the current view, 12:00 turned and
	# raised, 24:00 high and looking down.
	var cam := tree.root.get_viewport().get_camera_3d()
	var base := cam.global_transform
	var keys: ClimelapseKeyframes = loader.call("climelapse_keys")
	keys.clear()
	keys.set_key(day0, base, cam.fov)
	keys.set_key(day0 + 12.0, Transform3D(base.basis.rotated(Vector3.UP, deg_to_rad(70.0)),
		base.origin + Vector3(0, 25, 0)), cam.fov)
	keys.set_key(day0 + 24.0, Transform3D(Basis.from_euler(Vector3(deg_to_rad(-35.0), base.basis.get_euler().y, 0)),
		base.origin + Vector3(0, 60, 0)), cam.fov)
	loader.call("_save_climelapse_keys")
	_ok(int(loader.call("get_climelapse_path_count")) == 3, "three camera keyframes")

	# The dialog, through the timeline's own 🎬 handler.
	tl_ui.call("_on_export_clim_mp4_pressed")
	await _settle(tree, 4)
	var dlg: Node = tl_ui.get("_clim_options_dialog")
	_ok(dlg != null and is_instance_valid(dlg), "🎬 opened the export dialog")
	if dlg == null:
		return {"ok": false}
	var o0: Dictionary = dlg.call("current_options")
	_ok(absf(float(o0["start_abs"]) - day0) < 0.02 and absf(float(o0["end_abs"]) - (day0 + 24.0)) < 0.02,
		"range pre-filled from the selection (%s .. %s)" % [str(o0["start_abs"]), str(o0["end_abs"])])
	# Max speed, HD, 30 fps, into the screenshots folder.
	var speed_spin: SpinBox = dlg.get("_speed_spin")
	speed_spin.value = float(ClimelapseExportOptions.TIME_PRESETS[ClimelapseExportOptions.MAX_PRESET][1])
	var res_opt: OptionButton = dlg.get("_res_opt")
	res_opt.select(2)
	dlg.call("_on_res_preset", 2)
	var fps_opt: OptionButton = dlg.get("_fps_opt")
	fps_opt.select(ClimelapseExportOptions.FPS_CHOICES.find(30))
	var out_dir := ProjectSettings.globalize_path("user://screenshots").path_join(LABEL).replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(out_dir)
	(dlg.get("_folder_edit") as LineEdit).text = out_dir
	(dlg.get("_file_edit") as LineEdit).text = "export_24h_max.mp4"
	dlg.call("_on_changed")
	var o: Dictionary = dlg.call("current_options")
	_ok(int(o["width"]) == 1920 and int(o["height"]) == 1080 and int(o["fps"]) == 30
		and absf(float(o["hours_per_second"]) - 2.0) < 1e-6, "dialog reads back 1920×1080, 30 fps, Max")
	var want_frames := ClimelapseExportOptions.frame_count(o)
	_ok(want_frames == 361, "24 h at Max = 361 frames (%d)" % want_frames)
	var out_mp4 := ClimelapseExportOptions.output_path(o)
	if FileAccess.file_exists(out_mp4):
		DirAccess.remove_absolute(out_mp4)

	# Preview: the dialog hides, the clock walks at 2 h per real second, the
	# preview camera is current; stopping hands both back.
	dlg.call("_on_preview")
	await _settle(tree, 3)
	_ok(bool(loader.call("is_climelapse_previewing")), "preview running")
	var pcam := tree.root.get_viewport().get_camera_3d()
	_ok(pcam != null and pcam.name == "ClimelapsePreviewCam", "preview camera is current (%s)" % (pcam.name if pcam else "none"))
	_ok(str(main.call("clock_hold_owner")) == "climelapse_preview", "preview holds the clock")
	var h_a := float(main.call("get_absolute_hours"))
	var t_a := Time.get_ticks_msec()
	await _settle(tree, 45)
	var h_b := float(main.call("get_absolute_hours"))
	var real_s := float(Time.get_ticks_msec() - t_a) / 1000.0
	var rate := (h_b - h_a) / maxf(real_s, 1e-3)
	_ok(rate > 1.0 and rate < 3.0, "preview walks ~2 sim-h per real second (%.2f)" % rate)
	var mid_pose: Transform3D = pcam.global_transform
	_ok(mid_pose.origin.distance_to(base.origin) > 0.5, "preview camera moved along the keys")
	loader.call("stop_climelapse_preview")
	await _settle(tree, 4)
	_ok(not bool(loader.call("is_climelapse_previewing")), "preview stopped")
	_ok(tree.root.get_viewport().get_camera_3d() == cam, "player camera back after the preview")
	_ok(str(main.call("clock_hold_owner")).is_empty(), "no clock claim after the preview")
	_ok(absf(float(main.call("get_absolute_hours")) - now_h) < 0.05, "clock back where it was")
	_ok(is_instance_valid(dlg) and (dlg.get("_frame") as CanvasLayer).visible, "dialog shows again after the preview")

	# Export through the dialog's button.
	var t0 := Time.get_ticks_msec()
	dlg.call("_on_export")
	await _settle(tree, 3)
	_ok(bool(loader.call("is_climelapse_exporting")), "export started")
	_ok(tree.root.get_viewport().disable_3d, "game window stops drawing 3D during the export")
	var guard := 0
	while bool(loader.call("is_climelapse_exporting")) and guard < 60 * 1200:
		await tree.process_frame
		guard += 1
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	var st: Dictionary = loader.call("get_climelapse_export_stats")
	print("clim-export result: %s — %s (%.1f s)" % [str(st.get("result")), str(st.get("message")), secs])
	_ok(str(st.get("result")) == "ok", "export finished ok")
	await _settle(tree, 4)
	_ok(not tree.root.get_viewport().disable_3d, "game window draws 3D again")
	_ok(absf(float(main.get("time_scale")) - scale0) < 1e-9, "time_scale restored")
	_ok(bool(main.get("analemma_mode")) == analemma0, "analemma restored")
	_ok(str(main.call("clock_hold_owner")).is_empty(), "no clock claim after the export")
	_ok(tree.root.get_viewport().get_camera_3d() == cam, "player camera still current")

	# What is in the file.
	_ok(FileAccess.file_exists(out_mp4), "mp4 written: %s" % out_mp4)
	var ffprobe := ffmpeg.get_base_dir().path_join("ffprobe.exe") if OS.get_name() == "Windows" else "ffprobe"
	var probe: Array = []
	OS.execute(ffprobe, ["-v", "error", "-count_frames", "-show_entries",
		"stream=nb_read_frames,width,height,pix_fmt:format=duration,size", "-of", "default=nw=1", out_mp4], probe)
	var txt := str(probe[0]) if not probe.is_empty() else ""
	print("clim-export ffprobe:\n" + txt)
	_ok(txt.contains("width=1920") and txt.contains("height=1080"), "ffprobe size 1920×1080")
	_ok(txt.contains("nb_read_frames=%d" % want_frames), "ffprobe frame count %d" % want_frames)
	var dur := -1.0
	for ln in txt.split("\n"):
		if ln.begins_with("duration="):
			dur = float(ln.trim_prefix("duration="))
	_ok(absf(dur - float(want_frames) / 30.0) < 0.1, "ffprobe duration %.2f s" % dur)
	var lumas: Array = []
	for pair in [[60, "04h"], [180, "12h"], [300, "20h"]]:
		var png := out_dir.path_join("frame_%s.png" % str(pair[1]))
		OS.execute(ffmpeg, ["-v", "error", "-y", "-i", out_mp4, "-vf", "select=eq(n\\,%d)" % int(pair[0]),
			"-frames:v", "1", png], [])
		var img := Image.load_from_file(png) if FileAccess.file_exists(png) else null
		var l := _mean_luma(img)
		lumas.append(l)
		print("clim-export frame %s (n=%d): mean luma %.3f, %s" % [str(pair[1]), int(pair[0]), l, png])
	_ok(float(lumas[1]) > 0.08, "noon frame has a picture (luma %.3f)" % float(lumas[1]))
	_ok(float(lumas[1]) > float(lumas[0]), "noon brighter than 04:00")
	return {"ok": _fails.is_empty(), "fails": _fails}


static func _mean_luma(img: Image) -> float:
	if img == null or img.is_empty():
		return 0.0
	var sum := 0.0
	var n := 0
	var step := 16
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return sum / float(maxi(n, 1))
