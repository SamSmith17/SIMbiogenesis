class_name ClimelapseCapture
extends Node

## Viewport frame capture for climelapse MP4 export (Phase 5).
## Drives the simulation forward frame by frame directly and captures the viewport.

signal capture_started()
signal capture_progress(frac: float)
signal capture_complete(success: bool, output_path: String, message: String)

const DEFAULT_FPS := 30
const FRAMES_SUBDIR := "_clim_frames"

var _active := false
var _cancel := false
var _frac := 0.0


func is_active() -> bool:
	return _active


func get_progress() -> float:
	return _frac


func cancel() -> void:
	_cancel = true


func start_capture(loader: Node, start_abs: float, end_abs: float, time_scale: float, output_mp4: String,
		camera: ClimelapseCameraRig, fps: int = DEFAULT_FPS) -> void:
	if _active or loader == null or output_mp4.is_empty():
		return
	if not camera.is_valid():
		capture_complete.emit(false, output_mp4, "No active 3D camera to lock.")
		return
	if time_scale <= 0.0:
		capture_complete.emit(false, output_mp4, "Time scale must be > 0.")
		return
	_active = true
	_cancel = false
	_frac = 0.0
	capture_started.emit()
	_run_capture.call_deferred(loader, start_abs, end_abs, time_scale, output_mp4, camera, fps)


func _run_capture(loader: Node, start_abs: float, end_abs: float, time_scale: float, output_mp4: String,
		camera: ClimelapseCameraRig, fps: int) -> void:
	var tree := get_tree()
	if tree == null:
		_finish(false, output_mp4, "No scene tree.")
		return
	var main := tree.current_scene
	if main == null:
		_finish(false, output_mp4, "No active scene.")
		return

	var cc := tree.root.get_node_or_null("CursorController")
	if cc != null and cc.has_method("request_modal"):
		cc.call("request_modal", "climelapse_capture")

	var prev_scale: Variant = main.get("time_scale") if "time_scale" in main else null
	if prev_scale != null:
		main.set("time_scale", 0.0)

	var hours_per_frame = time_scale / float(fps)
	var total := maxi(1, int(ceil((end_abs - start_abs) / hours_per_frame)))
	if total > 30000:
		_finish(false, output_mp4, "Export would generate %d frames. Choose a faster speed or shorter duration." % total)
		if prev_scale != null:
			main.set("time_scale", prev_scale)
		if cc != null and cc.has_method("release_modal"):
			cc.call("release_modal", "climelapse_capture")
		return

	var composer := ClimelapseFrameCompose.new()
	tree.root.add_child(composer)

	# Use a SubViewport to capture a clean 3D frame without the 2D UI
	var root_vp := tree.root.get_viewport()
	var svp := SubViewport.new()
	svp.size = root_vp.size
	svp.world_3d = root_vp.world_3d
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.transparent_bg = false
	main.add_child(svp)

	var lock_cam: Camera3D = camera.call("spawn_lock_camera", svp)
	if loader.has_method("begin_climelapse_export_cull"):
		loader.call("begin_climelapse_export_cull", lock_cam)

	var out_dir := output_mp4.get_base_dir()
	var frames_dir := out_dir.path_join(FRAMES_SUBDIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(frames_dir))

	var manifest: Array = []
	var clock := CelestialClock.new()

	for i in total:
		if _cancel:
			break
		
		# Show progress to user
		_frac = float(i) / float(total)
		capture_progress.emit(_frac)
		
		var abs_h = start_abs + i * hours_per_frame
		if main.has_method("set_absolute_hours"):
			main.call("set_absolute_hours", abs_h)
			
		# Step physics so vegetation growth catches up
		if loader.has_method("_advance_growth"):
			loader.call("_advance_growth")

		await tree.process_frame
		await RenderingServer.frame_post_draw

		# Moving hyperlapse: interpolate drone path; else hold the locked pose.
		var t_path := 0.0 if total <= 1 else float(i) / float(total - 1)
		if camera.has_path():
			lock_cam.global_transform = camera.interpolate_at(t_path)
		else:
			lock_cam.global_transform = camera.global_xform
		var tex := svp.get_texture()
		if tex != null:
			var img := tex.get_image()
			if img != null and not img.is_empty():
				var dt: Dictionary = clock.abs_hours_to_date(abs_h)
				var tc := ClimelapseFrameCompose.format_timecode(
					int(dt.get("year", 1)),
					int(dt.get("month", 1)),
					int(dt.get("day", 1)),
					fmod(abs_h, 24.0))
				img = await composer.stamp_async(img, tc)
				var frame_path := frames_dir.path_join("frame_%05d.png" % i)
				img.save_png(frame_path)
				manifest.append({
					"index": i,
					"abs_h": abs_h,
					"year": dt.get("year", 0),
					"month": dt.get("month", 1),
					"day": dt.get("day", 1),
					"timecode": tc,
				})

	if loader.has_method("end_climelapse_export_cull"):
		loader.call("end_climelapse_export_cull")

	if lock_cam != null and is_instance_valid(lock_cam):
		lock_cam.queue_free()
	if svp != null and is_instance_valid(svp):
		svp.queue_free()


	if is_instance_valid(composer):
		composer.queue_free()

	if prev_scale != null:
		main.set("time_scale", prev_scale)
	if cc != null and cc.has_method("release_modal"):
		cc.call("release_modal", "climelapse_capture")

	if _cancel:
		_finish(false, output_mp4, "Capture cancelled.")
		return
	if manifest.is_empty():
		_finish(false, output_mp4, "No frames captured.")
		return

	_frac = 0.95
	capture_progress.emit(_frac)
	var enc: Dictionary = ClimelapseVideoEncoder.encode_png_sequence(frames_dir, fps, output_mp4)
	_write_manifest(out_dir, output_mp4, start_abs, end_abs, camera, fps, manifest)

	if bool(enc.get("ok", false)):
		_cleanup_frames(frames_dir)
		_finish(true, output_mp4, "Saved %s (%d frames @ %d fps)" % [output_mp4, manifest.size(), fps])
	else:
		var msg := str(enc.get("reason", "encode failed"))
		msg += "\nPNG frames kept at: %s" % frames_dir
		_finish(false, output_mp4, msg)


static func _hide_all_ui(root: Node) -> Array:
	var hidden: Array = []
	_hide_ui_walk(root, hidden)
	return hidden


static func _hide_ui_walk(node: Node, hidden: Array) -> void:
	if (node is CanvasLayer or node is Window) and node != node.get_tree().root:
		if node.get("visible"):
			hidden.append(node)
			node.set("visible", false)
	elif node is Control and node.get_parent() == node.get_tree().root:
		if node.get("visible"):
			hidden.append(node)
			node.set("visible", false)
	for child in node.get_children():
		_hide_ui_walk(child, hidden)


static func _hide_known_ui(hidden: Array) -> void:
	for node in hidden:
		if is_instance_valid(node):
			node.set("visible", false)


static func _restore_hidden_ui(hidden: Array) -> void:
	for node in hidden:
		if is_instance_valid(node):
			node.set("visible", true)


func _write_manifest(out_dir: String, mp4: String, start_abs: float, end_abs: float,
		camera: ClimelapseCameraRig, fps: int, frames: Array) -> void:
	var path_out: Array = []
	for wp in camera.path:
		if wp is Dictionary:
			var p: Vector3 = (wp as Dictionary).get("pos", Vector3.ZERO)
			path_out.append({
				"pos": [p.x, p.y, p.z],
				"yaw": float((wp as Dictionary).get("yaw", 0.0)),
				"pitch": float((wp as Dictionary).get("pitch", 0.0)),
			})
	var doc := {
		"version": 3,
		"fps": fps,
		"start_abs_h": start_abs,
		"end_abs_h": end_abs,
		"mp4": mp4.get_file(),
		"camera_mode": camera.mode,
		"drone_path": path_out,
		"timecode_bar_px": ClimelapseFrameCompose.BAR_HEIGHT,
		"frames": frames,
	}
	var mf := FileAccess.open(out_dir.path_join("manifest.json"), FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(doc, "\t"))


func _cleanup_frames(frames_dir: String) -> void:
	var dir := DirAccess.open(frames_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".png"):
			dir.remove(f)
		f = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(frames_dir))


func _finish(ok: bool, path: String, message: String) -> void:
	_active = false
	_cancel = false
	_frac = 1.0 if ok else 0.0
	capture_progress.emit(_frac)
	capture_complete.emit(ok, path, message)
