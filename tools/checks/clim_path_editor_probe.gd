extends RefCounted

## The video export's camera-path editor and sky options on a real world:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/clim_path_editor_probe.gd -Label clim_path -Timeout 1200
## 1. No keyframes: a short export holds the camera still (first frame == last
##    frame of the camera's pose; the drone used to sweep a near-full circle).
## 2. Three keys in front of the player. A REAL click on a key's diamond on the
##    timeline's CLIM lane opens the editor on that key: path view + gizmo up.
## 3. REAL drags on the gizmo: the green ring pans (heading moves by the angle
##    dragged), the red ring tilts, an arrow moves the key; the fields follow.
## 4. A REAL click on another key's marker in the world selects it.
## 5. Look through: the claimed camera sits on the key; a drag pans it; off
##    gives the player camera back.
## 6. Revert puts the keys back; Done closes (overlay, view, gizmo gone).
## 7. Preview with "follow the sun": the preview camera looks at the sun.
## 8. An analemma export (every 7 days, clear sky, star trails growing,
##    follow the stars): the frame count, the world switched over during it
##    and handed back after (clouds, analemma, trails, clock claim).
## Shots under screenshots\clim_path\.

const LABEL := "clim_path"

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("clim-path %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/%s" % LABEL
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var vp := main.get_viewport()
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var tl_ui: Node = main.get_node_or_null("UILayer/TimelineUI")
	_ok(loader != null and tl_ui != null, "loader and timeline are up")
	if loader == null or tl_ui == null:
		return {"ok": false}
	var ffmpeg := ClimelapseVideoEncoder.find_ffmpeg()
	var out_dir := ProjectSettings.globalize_path("user://screenshots").path_join(LABEL).replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var cam := vp.get_camera_3d()
	var base := cam.global_transform
	var now_h := float(main.call("get_absolute_hours"))
	var keys: ClimelapseKeyframes = loader.call("climelapse_keys")
	var saved_keys := keys.duplicate_keys()

	# --- 1. no keys = a still shot -----------------------------------------------
	keys.clear()
	loader.call("_save_climelapse_keys")
	var rig := ClimelapseCameraRig.snapshot_from_tree(tree)
	var p0: Transform3D = rig.pose_at(now_h, 0.0)["xform"]
	var p1: Transform3D = rig.pose_at(now_h + 24.0, 1.0)["xform"]
	_ok(p0.is_equal_approx(p1) and p0.origin.distance_to(base.origin) < 0.01,
		"no keyframes: the export camera holds the current view (mode %s)" % rig.mode)

	# --- 2. three keys; a click on the timeline opens the editor -----------------
	var fwd := -base.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var yaw0 := atan2(-fwd.x, -fwd.z)
	var eye := base.origin
	var t_keys := [now_h + 0.5, now_h + 6.0, now_h + 12.0]
	keys.set_key(t_keys[0], Transform3D(Basis.from_euler(Vector3(0, yaw0 + 0.3, 0)), eye + fwd * 16.0 - right * 9.0 + Vector3.UP * 7.0))
	# Key 2 faces across the view, so both of its rings face the camera.
	keys.set_key(t_keys[1], Transform3D(Basis.from_euler(Vector3(deg_to_rad(-10.0), yaw0 + PI * 0.5, 0)), eye + fwd * 16.0 + Vector3.UP * 7.0))
	keys.set_key(t_keys[2], Transform3D(Basis.from_euler(Vector3(0, yaw0 - 0.3, 0)), eye + fwd * 16.0 + right * 9.0 + Vector3.UP * 7.0))
	loader.call("_save_climelapse_keys")
	var seeded := keys.duplicate_keys()
	await _settle(tree, 4)
	var track: Control = tl_ui.get("_track")
	var lane: Rect2 = tl_ui.get("_clim_lane_rect")
	_ok(track != null and lane.size.x > 0.0, "the timeline's CLIM lane is drawn")
	var editor: Node = null
	if track != null and lane.size.x > 0.0:
		var win: PackedFloat64Array = tl_ui.call("_track_window")
		var lx := (float(t_keys[1]) - win[0]) / win[1] * lane.size.x
		var local := Vector2(lx, lane.position.y + lane.size.y * 0.5)
		var at := track.get_global_transform_with_canvas() * local
		_ok(int(tl_ui.call("_clim_key_at", local)) == 1, "the diamond of key 2 is under the click point")
		await HarnessInput.click(vp, at)
		await _settle(tree, 4)
	editor = main.get_node_or_null("UILayer/ClimelapsePathEditor")
	_ok(editor != null and bool(loader.call("is_climelapse_path_editing")), "a click on a CLIM key opened the camera-path editor")
	if editor == null or not bool(loader.call("is_climelapse_path_editing")):
		loader.call("open_climelapse_path_editor", 1)
		await _settle(tree, 4)
		editor = main.get_node_or_null("UILayer/ClimelapsePathEditor")
	_ok(int(editor.call("selected")) == 1, "the editor opened on that key (%d)" % int(editor.call("selected")))
	var view: ClimelapsePathView = editor.call("path_view")
	var giz: LightGizmo = editor.call("gizmo")
	await _settle(tree, 3)
	_ok(view != null and view.visible and giz != null and giz.visible, "path view and gizmo are up")
	_ok(giz != null and giz.global_position.distance_to(ClimelapseKeyframes.key_transform(keys.key(1)).origin) < 0.01,
		"the gizmo sits on the selected key")
	_ok(CursorController.has_tool_overlay(), "the editor runs in the tool-overlay tier (free cursor)")
	_shot(main, "01_editor_open")

	# --- 3. gizmo drags -------------------------------------------------------------
	cam = vp.get_camera_3d()
	var o := giz.global_position
	var R := LightGizmo.RING_R * giz.handle_scale()
	var to_cam := cam.global_position - o
	to_cam.y = 0.0
	var kyaw := float(keys.key(1)["yaw"])
	var xb := Basis(Vector3.UP, kyaw)
	# A point on the yaw ring halfway between the key's side and back axes, on
	# the near side; drag it 30° round.
	var u := (xb.x * signf(xb.x.dot(to_cam)) + xb.z * signf(xb.z.dot(to_cam))).normalized()
	var a := cam.unproject_position(o + u * R)
	var b := cam.unproject_position(o + u.rotated(Vector3.UP, deg_to_rad(30.0)) * R)
	var head0 := ClimelapseKeyframes.heading_deg(kyaw)
	await HarnessInput.drag(vp, a, b, 10)
	await _settle(tree, 2)
	var head1 := ClimelapseKeyframes.heading_deg(float(keys.key(1)["yaw"]))
	var dh := wrapf(head1 - head0, -180.0, 180.0)
	_ok(absf(dh + 30.0) < 2.0, "green ring: pan by the angle dragged (heading %+.1f°, want -30°)" % dh)
	_ok(absf(float((editor.get("_pan_spin") as SpinBox).value) - head1) < 0.6, "the Pan field follows (%.1f°)" % head1)
	_shot(main, "02_after_pan")
	# Tilt: the ring about the key's side axis, a point between up and the side
	# facing the camera, dragged 20° round.
	kyaw = float(keys.key(1)["yaw"])
	xb = Basis(Vector3.UP, kyaw)
	var pitch0 := float(keys.key(1)["pitch"])
	await _settle(tree, 2)
	o = giz.global_position
	R = LightGizmo.RING_R * giz.handle_scale()
	var zs := signf(xb.z.dot(cam.global_position - o))
	var v := (Vector3.UP + xb.z * zs).normalized()
	a = cam.unproject_position(o + v * R)
	b = cam.unproject_position(o + v.rotated(xb.x, deg_to_rad(20.0)) * R)
	await HarnessInput.drag(vp, a, b, 10)
	await _settle(tree, 2)
	var dp := rad_to_deg(float(keys.key(1)["pitch"]) - pitch0)
	_ok(absf(absf(dp) - 20.0) < 2.0, "red ring: tilt by the angle dragged (%+.1f°)" % dp)
	# Move: the up arrow, dragged up the screen.
	var pos0 := ClimelapseKeyframes.key_transform(keys.key(1)).origin
	o = giz.global_position
	var sc := giz.handle_scale()
	a = cam.unproject_position(o + Vector3.UP * sc * 0.7)
	b = cam.unproject_position(o + Vector3.UP * sc * 1.7)
	await HarnessInput.drag(vp, a, b, 8)
	await _settle(tree, 2)
	var dy := ClimelapseKeyframes.key_transform(keys.key(1)).origin.y - pos0.y
	_ok(absf(dy - sc) < sc * 0.15, "up arrow: the key rose %.2f m (want %.2f)" % [dy, sc])
	var on_disk := ClimelapseKeyframes.load_json(WorldPaths.site_file("climelapse_keys", float(loader.get("_lat")), float(loader.get("_lon"))))
	_ok(on_disk.size() == 3 and absf(float(on_disk.key(1)["yaw"]) - float(keys.key(1)["yaw"])) < 1e-6,
		"the edits were saved on release")

	# --- 4. click another key's marker ------------------------------------------------
	var m0 := cam.unproject_position(ClimelapseKeyframes.key_transform(keys.key(0)).origin)
	await HarnessInput.click(vp, m0)
	await _settle(tree, 3)
	_ok(int(editor.call("selected")) == 0, "a click on key 1's marker selects it (%d)" % int(editor.call("selected")))
	_shot(main, "03_key1_selected")

	# --- 5. look through ----------------------------------------------------------------
	editor.call("set_look_through", true)
	await _settle(tree, 3)
	var lc := vp.get_camera_3d()
	var kx := ClimelapseKeyframes.key_transform(keys.key(0))
	_ok(lc != null and lc != cam and lc.global_transform.is_equal_approx(kx), "look through: the camera sits on the key")
	_shot(main, "04_look_through")
	var h_before := ClimelapseKeyframes.heading_deg(float(keys.key(0)["yaw"]))
	var mid := vp.get_visible_rect().size * Vector2(0.35, 0.5)
	await HarnessInput.drag(vp, mid, mid + Vector2(100, 0), 8)
	await _settle(tree, 2)
	var dl := wrapf(ClimelapseKeyframes.heading_deg(float(keys.key(0)["yaw"])) - h_before, -180.0, 180.0)
	_ok(absf(dl - rad_to_deg(100.0 * 0.0035)) < 1.0, "look through: dragging right pans right (%+.1f°)" % dl)
	editor.call("set_look_through", false)
	await _settle(tree, 2)
	_ok(vp.get_camera_3d() == cam, "look through off: the player camera is back")

	# --- 6. revert + done -----------------------------------------------------------------
	editor.call("_on_revert")
	await _settle(tree, 2)
	keys = loader.call("climelapse_keys")
	var same := keys.size() == seeded.size()
	for i in mini(keys.size(), seeded.size()):
		same = same and is_equal_approx(float(keys.key(i)["yaw"]), float(seeded.key(i)["yaw"])) \
			and ClimelapseKeyframes.key_transform(keys.key(i)).origin.is_equal_approx(ClimelapseKeyframes.key_transform(seeded.key(i)).origin)
	_ok(same, "Revert puts the keys back")
	editor.call("close")
	await _settle(tree, 2)
	_ok(not bool(loader.call("is_climelapse_path_editing")) and not CursorController.has_tool_overlay()
		and not view.visible and not giz.visible, "Done closes: overlay released, path and gizmo hidden")

	# --- 7. preview, following the sun ------------------------------------------------------
	var day0 := floorf(now_h / 24.0) * 24.0
	var po := ClimelapseExportOptions.load_prefs()
	po["start_abs"] = day0 + 11.0
	po["end_abs"] = day0 + 14.0
	po["follow"] = "sun"
	po["analemma"] = 0
	_ok(bool(loader.call("start_climelapse_preview", po)), "preview with follow the sun")
	await _settle(tree, 12)
	var pcam := vp.get_camera_3d()
	var clock: Object = main.get("clock")
	var sun_dir: Vector3 = clock.call("get_sun_direction")
	var look := -pcam.global_transform.basis.z
	_ok(look.dot(sun_dir.normalized()) > 0.999 and absf(pcam.global_transform.basis.x.y) < 1e-3,
		"the preview camera looks at the sun, horizon level (dot %.4f)" % look.dot(sun_dir.normalized()))
	_shot(main, "05_follow_sun")
	loader.call("stop_climelapse_preview")
	await _settle(tree, 4)
	_ok(vp.get_camera_3d() == cam and absf(float(main.call("get_absolute_hours")) - now_h) < 0.05,
		"preview stopped: player camera and clock back")

	# --- 8. analemma export with the sky options --------------------------------------------
	if ffmpeg.is_empty():
		_ok(false, "ffmpeg found")
	else:
		var ss: StarSystem = main.call("get_star_system")
		var trails0 := [ss.star_trails, ss.star_trail_length] if ss != null else [0.0, 0.0]
		var clear0 := bool(main.get("clear_sky_override"))
		var ana0 := bool(main.get("analemma_mode"))
		# Through the real dialog: no keyframes (a still shot), the camera
		# following the sun so the figure stays in frame.
		var ana_keys: ClimelapseKeyframes = loader.call("climelapse_keys")
		ana_keys.clear()
		loader.call("_save_climelapse_keys")
		tl_ui.call("_on_export_clim_mp4_pressed")
		await _settle(tree, 4)
		var dlg: Node = tl_ui.get("_clim_options_dialog")
		_ok(dlg != null and is_instance_valid(dlg), "the export dialog opened")
		if dlg == null:
			return {"ok": false, "fails": _fails}
		var spd_opt: OptionButton = dlg.get("_speed_opt")
		_ok(spd_opt.item_count == ClimelapseExportOptions.TIME_PRESETS.size() + 1
			and str(spd_opt.get_item_text(spd_opt.item_count - 2)) == "Year per second",
			"clock speeds run up to a year per second (%d choices)" % spd_opt.item_count)
		(dlg.get("_analemma_opt") as OptionButton).select(1)
		(dlg.get("_clouds_opt") as OptionButton).select(1)
		(dlg.get("_trails_opt") as OptionButton).select(1)
		(dlg.get("_follow_opt") as OptionButton).select(1)
		dlg.call("_on_changed")
		var o1: Dictionary = dlg.call("current_options")
		_ok(int(ClimelapseExportOptions.analemma_days_in(o1)) == ClimelapseExportOptions.ANALEMMA_YEAR_DAYS,
			"choosing the analemma widens the range to a year (%d days)" % int(ClimelapseExportOptions.analemma_days_in(o1)))
		var spin: SpinBox = dlg.get("_speed_spin")
		_ok(bool(dlg.get("_speed_ana")) and spin.suffix == " days/s" and not (dlg.get("_max_btn") as Button).visible
			and spd_opt.item_count == ClimelapseExportOptions.ANALEMMA_PRESETS.size() + 1,
			"the speed row is in days per second of video")
		var res_opt: OptionButton = dlg.get("_res_opt")
		res_opt.select(ClimelapseExportOptions.RES_PRESETS.size() + 1)
		dlg.call("_on_res_preset", ClimelapseExportOptions.RES_PRESETS.size() + 1)
		(dlg.get("_w_spin") as SpinBox).value = 640
		(dlg.get("_h_spin") as SpinBox).value = 360
		(dlg.get("_fps_opt") as OptionButton).select(ClimelapseExportOptions.FPS_CHOICES.find(30))
		(dlg.get("_settle_spin") as SpinBox).value = 1
		(dlg.get("_folder_edit") as LineEdit).text = out_dir
		(dlg.get("_file_edit") as LineEdit).text = "analemma_year.mp4"
		dlg.call("_on_changed")
		# A typed video length sets the speed.
		(dlg.get("_length_spin") as SpinBox).value = 2.0
		await _settle(tree, 2)
		var eo: Dictionary = dlg.call("current_options")
		var want := ClimelapseExportOptions.frame_count(eo)
		_ok(want == 60 and absf(ClimelapseExportOptions.video_seconds(eo) - 2.0) < 0.02,
			"a 2 s video of the year: %d frames at %.1f days/s" % [want, float(eo["analemma_days_per_second"])])
		_ok(absf(spin.value - float(eo["analemma_days_per_second"])) < 0.01, "the speed field shows the speed the length gave")
		var shot_dlg := main.get_viewport().get_texture().get_image()
		shot_dlg.save_png("user://screenshots/%s/06_dialog_analemma.png" % LABEL)
		dlg.call("_on_export")
		await _settle(tree, 3)
		eo["file_name"] = "analemma_year.mp4"
		var out_mp4 := ClimelapseExportOptions.output_path(eo)
		_ok(bool(loader.call("is_climelapse_exporting")), "analemma export started from the dialog")
		var saw_clear := false
		var saw_ana := false
		var saw_ext := false
		var guard := 0
		while bool(loader.call("is_climelapse_exporting")) and guard < 60 * 600:
			saw_clear = saw_clear or bool(main.get("clear_sky_override"))
			saw_ana = saw_ana or bool(main.get("analemma_mode"))
			saw_ext = saw_ext or bool(main.get("analemma_external_step"))
			await tree.process_frame
			guard += 1
		var st: Dictionary = loader.call("get_climelapse_export_stats")
		_ok(str(st.get("result")) == "ok", "analemma export finished ok (%s)" % str(st.get("message")))
		_ok(saw_clear and saw_ana and saw_ext, "during the export: clear sky %s, analemma %s, stepped by the export %s" % [saw_clear, saw_ana, saw_ext])
		await _settle(tree, 4)
		_ok(bool(main.get("clear_sky_override")) == clear0 and bool(main.get("analemma_mode")) == ana0
			and not bool(main.get("analemma_external_step")), "after: clouds and analemma handed back")
		_ok(ss == null or (is_equal_approx(ss.star_trails, float(trails0[0])) and is_equal_approx(ss.star_trail_length, float(trails0[1]))),
			"after: star trails as they were")
		var trail: PackedVector3Array = main.get("_analemma_trail")
		_ok(trail.size() >= ClimelapseExportOptions.ANALEMMA_YEAR_DAYS - 1,
			"the figure on the sky got every day of the year (%d points), as in the game" % trail.size())
		_ok(str(main.call("clock_hold_owner")).is_empty() and vp.get_camera_3d() == cam, "after: no clock claim, player camera current")
		var ffprobe := ffmpeg.get_base_dir().path_join("ffprobe.exe") if OS.get_name() == "Windows" else "ffprobe"
		var probe: Array = []
		OS.execute(ffprobe, ["-v", "error", "-count_frames", "-show_entries", "stream=nb_read_frames,width,height",
			"-of", "default=nw=1", out_mp4], probe)
		var txt := str(probe[0]) if not probe.is_empty() else ""
		_ok(txt.contains("nb_read_frames=%d" % want) and txt.contains("width=640"), "ffprobe: %s" % txt.replace("\n", " "))
		for n in [0, 30, 59]:
			OS.execute(ffmpeg, ["-v", "error", "-y", "-i", out_mp4, "-vf", "select=eq(n\\,%d)" % n,
				"-frames:v", "1", out_dir.path_join("analemma_frame_%d.png" % n)], [])

	loader.call("restore_climelapse_keys", saved_keys)
	return {"ok": _fails.is_empty(), "fails": _fails}
