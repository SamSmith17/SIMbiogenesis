class_name ClimelapseCapture
extends Node

## Viewport frame capture for climelapse MP4 export (Phase 5).
## Drives the simulation forward frame by frame directly and captures the viewport.

signal capture_started()
signal capture_progress(frac: float)
signal capture_complete(success: bool, output_path: String, message: String)

## Name this export holds the world clock under (see core/clock_claims.gd).
const CLOCK_OWNER := "climelapse_export"
const DEFAULT_FPS := 30
const FRAMES_SUBDIR := "_clim_frames"

## Safety net only — one hour of 30 fps video. The UI asks for confirmation long
## before this, so hitting it means something is genuinely wrong with the range.
const MAX_FRAMES := 108000

var _active := false
var _cancel := false
var _frac := 0.0
var _frames_done := 0
var _frames_total := 0
## "capture" while stepping the sim, "encode" while ffmpeg runs, "" when idle.
var _phase := ""


func is_active() -> bool:
	return _active


func get_progress() -> float:
	return _frac


func get_frames_done() -> int:
	return _frames_done


func get_frames_total() -> int:
	return _frames_total


func get_phase() -> String:
	return _phase


func cancel() -> void:
	_cancel = true


## Sim-hours advanced per exported frame. `time_scale` is the world clock's
## sim-hours-per-real-second, so a 30 fps export of a "450×" (0.125 h/s) session
## walks 0.125/30 h per frame — the video plays back at exactly the speed the
## player had selected.
static func hours_per_frame(time_scale: float, fps: int) -> float:
	return time_scale / float(maxi(1, fps))


## Frame count an export of this range would produce. Pure — the UI calls it to
## show the estimate (and the confirmation prompt) BEFORE anything starts.
static func frames_for(start_abs: float, end_abs: float, time_scale: float, fps: int = DEFAULT_FPS) -> int:
	if time_scale <= 0.0 or end_abs <= start_abs:
		return 0
	return maxi(1, int(ceil((end_abs - start_abs) / hours_per_frame(time_scale, fps))))


func start_capture(loader: Node, start_abs: float, end_abs: float, time_scale: float, output_mp4: String,
		camera: ClimelapseCameraRig, fps: int = DEFAULT_FPS) -> void:
	if _active:
		return
	if loader == null or output_mp4.is_empty():
		capture_complete.emit(false, output_mp4, "No output path for the export.")
		return
	if not camera.is_valid():
		capture_complete.emit(false, output_mp4, "No active 3D camera to lock.")
		return
	if time_scale <= 0.0:
		capture_complete.emit(false, output_mp4, "Time scale must be > 0.")
		return
	if end_abs <= start_abs:
		capture_complete.emit(false, output_mp4, "Export range is empty.")
		return
	_active = true
	_cancel = false
	_frac = 0.0
	_frames_done = 0
	_frames_total = frames_for(start_abs, end_abs, time_scale, fps)
	_phase = "capture"
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

	# The export owns the clock for its duration: this loop places every frame's
	# instant by hand, so BOTH continuous playback (time_scale) and the analemma
	# stepper (a calendar day per rendered frame) have to be off. Leaving
	# analemma_mode on is what used to make an export "just play at ∞ speed".
	# One EXCLUSIVE claim carrying BOTH values — they are a pair here, and a
	# claim cannot half-restore the way two private "prev_" fields could. While
	# it is held, a UI speed change or another subsystem's claim is a logged
	# no-op. Released on every exit path via _restore_world().
	var claimed := false
	if main.has_method("push_clock_claim"):
		claimed = bool(main.call("push_clock_claim", CLOCK_OWNER,
			{"time_scale": 0.0, "analemma_mode": false}, true))
	var prev_scale: Variant = null
	var prev_analemma: Variant = null
	if not claimed:
		# Fallback for a Main without the claim API (older save/scene shells).
		prev_scale = main.get("time_scale") if "time_scale" in main else null
		prev_analemma = main.get("analemma_mode") if "analemma_mode" in main else null
		if prev_scale != null:
			main.set("time_scale", 0.0)
		if prev_analemma != null:
			main.set("analemma_mode", false)

	var h_per_frame := hours_per_frame(time_scale, fps)
	var total := maxi(1, _frames_total if _frames_total > 0 else frames_for(start_abs, end_abs, time_scale, fps))
	_frames_total = total
	if total > MAX_FRAMES:
		_restore_world(main, cc, prev_scale, prev_analemma)
		_finish(false, output_mp4, "Export would need %s frames (%s of video). Pick a faster speed or a shorter range."
			% [_thousands(total), _duration_label(total, fps)])
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
	# Clear stale PNGs first: ffmpeg encodes the whole frame_%05d sequence found
	# on disk, so leftovers from a longer earlier (or cancelled) run would be
	# appended to this video.
	_erase_frames(frames_dir)

	var manifest: Array = []
	var clock := CelestialClock.new()

	for i in total:
		if _cancel:
			break

		_frames_done = i
		_frac = float(i) / float(total)
		capture_progress.emit(_frac)

		var abs_h = start_abs + i * h_per_frame
		if main.has_method("set_absolute_hours"):
			main.call("set_absolute_hours", abs_h)

		# Step physics so vegetation growth catches up
		if loader.has_method("_push_growth_year"):
			loader.call("_push_growth_year")

		# Pose the camera BEFORE the render waits — setting it afterwards
		# captured the texture drawn from the PREVIOUS frame's pose, so a moving
		# hyperlapse lagged its path by one frame.
		var t_path := 0.0 if total <= 1 else float(i) / float(total - 1)
		if camera.has_path():
			lock_cam.global_transform = camera.interpolate_at(t_path)
		else:
			lock_cam.global_transform = camera.global_xform

		await tree.process_frame
		await RenderingServer.frame_post_draw

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

	_restore_world(main, cc, prev_scale, prev_analemma)

	if _cancel:
		_finish(false, output_mp4, "Export cancelled — %s left at %s (cleared by the next export)"
			% [UiText.count(manifest.size(), "partial frame"), frames_dir])
		return
	if manifest.is_empty():
		_finish(false, output_mp4, "No frames captured.")
		return

	_frames_done = manifest.size()
	_phase = "encode"
	_frac = 0.95
	capture_progress.emit(_frac)
	var enc: Dictionary = ClimelapseVideoEncoder.encode_png_sequence(frames_dir, fps, output_mp4)
	_write_manifest(out_dir, output_mp4, start_abs, end_abs, camera, fps, manifest)

	if bool(enc.get("ok", false)):
		_cleanup_frames(frames_dir)
		_finish(true, output_mp4, "Saved %s (%s @ %d fps)" % [output_mp4, UiText.count(manifest.size(), "frame"), fps])
	else:
		var msg := str(enc.get("reason", "encode failed"))
		msg += "\nPNG frames kept at: %s" % frames_dir
		_finish(false, output_mp4, msg)


## Hand the clock back exactly as the export found it (playback speed + analemma
## stepper) and release the cursor. Every exit path goes through here.
func _restore_world(main: Node, cursor: Node, prev_scale: Variant, prev_analemma: Variant) -> void:
	if main != null and is_instance_valid(main):
		# Idempotent, so running twice (or after the fallback path) is harmless.
		if main.has_method("pop_clock_claim"):
			main.call("pop_clock_claim", CLOCK_OWNER)
		if prev_analemma != null:
			main.set("analemma_mode", prev_analemma)
		if prev_scale != null:
			main.set("time_scale", prev_scale)
	if cursor != null and is_instance_valid(cursor) and cursor.has_method("release_modal"):
		cursor.call("release_modal", "climelapse_capture")


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


## Playback length of an exported frame count, e.g. "2m 14s".
static func _duration_label(frames: int, fps: int) -> String:
	var secs := int(round(float(frames) / float(maxi(1, fps))))
	if secs < 60:
		return "%ds" % secs
	return "%dm %02ds" % [secs / 60, secs % 60]


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


func _erase_frames(frames_dir: String) -> void:
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


func _cleanup_frames(frames_dir: String) -> void:
	_erase_frames(frames_dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(frames_dir))


func _finish(ok: bool, path: String, message: String) -> void:
	_active = false
	_cancel = false
	_phase = ""
	_frac = 1.0 if ok else 0.0
	capture_progress.emit(_frac)
	capture_complete.emit(ok, path, message)
