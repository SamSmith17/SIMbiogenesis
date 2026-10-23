class_name ClimelapseCapture
extends Node

## Video export: steps the world one frame at a time with the clock held,
## renders each instant through its own camera into an off-screen viewport at
## the chosen size, and streams the frames straight into ffmpeg
## (ClimelapseFramePipe). Options come from ClimelapseExportOptions.
##
## What used to make every export black (2026-10-22): the 3D viewport hands
## back RGB8 images, the timecode compositor built an RGBA8 frame, and
## `Image.blit_rect` refuses mismatched formats — so every frame stayed
## all-zero and ffmpeg encoded 45 s of black. The timecode is now a Label drawn
## INSIDE the capture viewport, so a frame is one image straight off the GPU
## with nothing composited on the CPU. The capture viewport also copies the
## root viewport's AA / shadow-atlas settings and the player camera's
## Environment / CameraAttributes, without which it rendered darker than the
## game.

signal capture_started()
signal capture_progress(frac: float)
signal capture_complete(success: bool, output_path: String, message: String)

## Name this export holds the world clock under (see core/clock_claims.gd).
const CLOCK_OWNER := "climelapse_export"
const DEFAULT_FPS := 30
## Frames rendered and thrown away before the first grab (shader compiles,
## TAA history, volumetric fog, streaming).
const WARMUP_FRAMES := 12
## Extra frames after a graphics-quality change (the vegetation rebuilds).
const QUALITY_SETTLE_FRAMES := 90
const MAX_FRAMES := ClimelapseExportOptions.MAX_FRAMES
const TIMECODE_BAR_FRAC := 0.048

var _active := false
var _cancel := false
var _frac := 0.0
var _frames_done := 0
var _frames_total := 0
## "warmup", "capture", "encode" — "" when idle.
var _phase := ""
var _svp: SubViewport = null
var _opts: Dictionary = {}


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


func get_options() -> Dictionary:
	return _opts


## The export viewport's live texture (for a preview in the progress window),
## or null when no export is running.
func get_preview_texture() -> Texture2D:
	return _svp.get_texture() if is_instance_valid(_svp) else null


func cancel() -> void:
	_cancel = true


## Old API kept for callers that think in "world speed": sim-hours per real
## second at 1 video second per real second.
static func hours_per_frame(time_scale: float, fps: int) -> float:
	return time_scale / float(maxi(1, fps))


static func frames_for(start_abs: float, end_abs: float, time_scale: float, fps: int = DEFAULT_FPS) -> int:
	return ClimelapseExportOptions.frame_count({"start_abs": start_abs, "end_abs": end_abs,
		"hours_per_second": time_scale, "fps": fps})


func start_capture(loader: Node, opts_in: Dictionary, camera: ClimelapseCameraRig) -> void:
	if _active:
		return
	var opts := ClimelapseExportOptions.normalize(opts_in)
	var out_mp4 := ClimelapseExportOptions.output_path(opts)
	if loader == null or str(opts.get("folder", "")).is_empty():
		capture_complete.emit(false, out_mp4, "No output folder for the export.")
		return
	if camera == null or not camera.is_valid():
		capture_complete.emit(false, out_mp4, "No active 3D camera to lock.")
		return
	var total := ClimelapseExportOptions.frame_count(opts)
	if total <= 0:
		capture_complete.emit(false, out_mp4, "Export range is empty.")
		return
	if total > MAX_FRAMES:
		capture_complete.emit(false, out_mp4, "Export would need %s frames (%s of video). Pick a faster speed or a shorter range."
			% [UiText.thousands(total), ClimelapseExportOptions.duration_label(ClimelapseExportOptions.video_seconds(opts))])
		return
	_opts = opts
	_active = true
	_cancel = false
	_frac = 0.0
	_frames_done = 0
	_frames_total = total
	_phase = "warmup"
	capture_started.emit()
	_run_capture.call_deferred(loader, opts, camera)


func _run_capture(loader: Node, opts: Dictionary, camera: ClimelapseCameraRig) -> void:
	var tree := get_tree()
	var out_mp4 := ClimelapseExportOptions.output_path(opts)
	if tree == null or tree.current_scene == null:
		_finish(false, out_mp4, "No active scene.")
		return
	var main := tree.current_scene
	var cc := tree.root.get_node_or_null("CursorController")
	if cc != null and cc.has_method("request_modal"):
		cc.call("request_modal", "climelapse_capture")

	# The export owns the clock: this loop places every frame's instant by hand,
	# so continuous playback (time_scale) and the analemma stepper both stay off,
	# under ONE exclusive claim carrying both. Released on every exit path via
	# _restore_world().
	var claimed := false
	if main.has_method("push_clock_claim"):
		claimed = bool(main.call("push_clock_claim", CLOCK_OWNER,
			{"time_scale": 0.0, "analemma_mode": false}, true))
	var prev := {}
	if not claimed:
		if "time_scale" in main:
			prev["time_scale"] = main.get("time_scale")
			main.set("time_scale", 0.0)
		if "analemma_mode" in main:
			prev["analemma_mode"] = main.get("analemma_mode")
			main.set("analemma_mode", false)

	# Render settings for the export only; put back by _restore_world.
	var settle_extra := 0
	if int(opts["quality"]) >= 0 and main.has_method("get_graphics_quality_level") \
			and int(main.call("get_graphics_quality_level")) != int(opts["quality"]):
		prev["quality"] = int(main.call("get_graphics_quality_level"))
		main.call("set_graphics_quality_level", int(opts["quality"]))
		settle_extra = QUALITY_SETTLE_FRAMES
	if int(opts["shadows"]) >= 0 and main.has_method("get_shadow_quality_level") \
			and int(main.call("get_shadow_quality_level")) != int(opts["shadows"]):
		prev["shadows"] = int(main.call("get_shadow_quality_level"))
		main.call("set_shadow_quality_level", int(opts["shadows"]))

	# The game window stops drawing the 3D world while the export runs (the
	# progress window shows the export's own picture), so the GPU renders the
	# world once per step, not twice.
	var root_vp := tree.root.get_viewport()
	prev["root_disable_3d"] = root_vp.disable_3d
	root_vp.disable_3d = true

	var svp := _make_viewport(root_vp, opts)
	_svp = svp
	main.add_child(svp)
	var lock_cam: Camera3D = camera.spawn_lock_camera(svp)
	var tc_label := _make_timecode(svp, opts)
	if loader.has_method("begin_climelapse_export_cull"):
		loader.call("begin_climelapse_export_cull", lock_cam)

	var pipe := ClimelapseFramePipe.new()
	var open_err := pipe.open(ClimelapseVideoEncoder.find_ffmpeg(), opts, out_mp4)
	if not open_err.is_empty():
		_teardown(loader, svp, lock_cam)
		_restore_world(main, cc, prev)
		_finish(false, out_mp4, open_err)
		return

	var total := _frames_total
	var manifest: Array = []
	var start_abs := float(opts["start_abs"])
	var end_abs := float(opts["end_abs"])
	var settle := int(opts["settle_frames"])
	var reason := ""

	for i in total:
		if _cancel:
			break
		var abs_h := minf(ClimelapseExportOptions.frame_hours(opts, i), end_abs)
		main.call("set_absolute_hours", abs_h)
		if loader.has_method("_push_growth_year"):
			loader.call("_push_growth_year")
		# Pose the camera BEFORE the render waits — posing it afterwards grabbed
		# the texture drawn from the previous frame's pose.
		var t_norm := 0.0 if total <= 1 else float(i) / float(total - 1)
		var pose := camera.pose_at(abs_h, t_norm)
		lock_cam.transform = pose.get("xform", camera.global_xform)
		lock_cam.fov = float(pose.get("fov", camera.fov))
		if tc_label != null:
			tc_label.text = ClimelapseExportOptions.timecode_at(abs_h)

		var waits := settle
		if i == 0:
			_phase = "warmup"
			waits = maxi(settle, WARMUP_FRAMES) + settle_extra
		for _w in waits:
			await tree.process_frame
		await RenderingServer.frame_post_draw
		_phase = "capture"
		if _cancel:
			break

		var img := svp.get_texture().get_image()
		if img == null or img.is_empty():
			reason = "The export viewport returned no image at frame %d." % i
			break
		if img.get_format() != Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGB8)
		while pipe.queued() >= ClimelapseFramePipe.MAX_QUEUE and not pipe.failed():
			await tree.process_frame
		if not pipe.push(img):
			reason = "ffmpeg stopped taking frames at frame %d." % i
			break
		manifest.append({"index": i, "abs_h": abs_h})
		_frames_done = i + 1
		_frac = float(_frames_done) / float(total) * 0.97
		capture_progress.emit(_frac)

	if loader.has_method("end_climelapse_export_cull"):
		loader.call("end_climelapse_export_cull")
	_phase = "encode"
	capture_progress.emit(_frac)

	if _cancel or not reason.is_empty():
		await pipe.abort(tree)
		_teardown(loader, svp, lock_cam)
		_restore_world(main, cc, prev)
		_finish(false, out_mp4, "Export cancelled." if reason.is_empty() else reason)
		return

	var res: Dictionary = await pipe.close(tree)
	_teardown(loader, svp, lock_cam)
	_restore_world(main, cc, prev)
	_write_manifest(out_mp4, opts, camera, manifest)
	if bool(res.get("ok", false)):
		_finish(true, out_mp4, "Saved %s (%s, %s at %d fps, %d × %d)" % [out_mp4,
			UiText.count(manifest.size(), "frame"),
			ClimelapseExportOptions.duration_label(float(manifest.size()) / float(int(opts["fps"]))),
			int(opts["fps"]), int(opts["width"]), int(opts["height"])])
	else:
		_finish(false, out_mp4, str(res.get("reason", "encode failed")))


func _make_viewport(root_vp: Viewport, opts: Dictionary) -> SubViewport:
	var svp := SubViewport.new()
	svp.name = "ClimelapseExportViewport"
	svp.size = Vector2i(int(opts["width"]), int(opts["height"]))
	svp.world_3d = root_vp.world_3d
	svp.own_world_3d = false
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.transparent_bg = false
	var msaa := int(opts["msaa"])
	match msaa:
		-1: svp.msaa_3d = root_vp.msaa_3d
		0: svp.msaa_3d = Viewport.MSAA_DISABLED
		2: svp.msaa_3d = Viewport.MSAA_2X
		4: svp.msaa_3d = Viewport.MSAA_4X
		8: svp.msaa_3d = Viewport.MSAA_8X
	var taa := int(opts["taa"])
	svp.use_taa = root_vp.use_taa if taa < 0 else taa == 1
	svp.screen_space_aa = root_vp.screen_space_aa
	svp.use_debanding = root_vp.use_debanding
	svp.scaling_3d_mode = root_vp.scaling_3d_mode
	svp.scaling_3d_scale = root_vp.scaling_3d_scale
	svp.fsr_sharpness = root_vp.fsr_sharpness
	svp.positional_shadow_atlas_size = maxi(root_vp.positional_shadow_atlas_size, 4096)
	svp.mesh_lod_threshold = root_vp.mesh_lod_threshold
	svp.use_occlusion_culling = root_vp.use_occlusion_culling
	svp.texture_mipmap_bias = root_vp.texture_mipmap_bias
	return svp


## The date/time strip, drawn by the capture viewport itself.
func _make_timecode(svp: SubViewport, opts: Dictionary) -> Label:
	if not bool(opts.get("timecode", true)):
		return null
	var h := maxf(18.0, float(int(opts["height"])) * TIMECODE_BAR_FRAC)
	var layer := CanvasLayer.new()
	svp.add_child(layer)
	var bar := ColorRect.new()
	bar.color = Color(0, 0, 0, 0.62)
	bar.position = Vector2(0.0, float(int(opts["height"])) - h)
	bar.size = Vector2(float(int(opts["width"])), h)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bar)
	var lbl := Label.new()
	lbl.position = bar.position
	lbl.size = bar.size
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_font_size_override("font_size", int(h * 0.58))
	lbl.add_theme_font_override("font", UITheme.font("semibold", true))
	layer.add_child(lbl)
	return lbl


func _teardown(_loader: Node, svp: SubViewport, cam: Camera3D) -> void:
	if cam != null and is_instance_valid(cam):
		cam.queue_free()
	if svp != null and is_instance_valid(svp):
		svp.queue_free()
	_svp = null


## Hand back the clock, the render settings and the cursor exactly as found.
## Every exit path goes through here.
func _restore_world(main: Node, cursor: Node, prev: Dictionary) -> void:
	var tree := get_tree()
	if tree != null and prev.has("root_disable_3d"):
		tree.root.get_viewport().disable_3d = bool(prev["root_disable_3d"])
	if main != null and is_instance_valid(main):
		# Idempotent, so running twice (or after the fallback path) is harmless.
		if main.has_method("pop_clock_claim"):
			main.call("pop_clock_claim", CLOCK_OWNER)
		if prev.has("analemma_mode"):
			main.set("analemma_mode", prev["analemma_mode"])
		if prev.has("time_scale"):
			main.set("time_scale", prev["time_scale"])
		if prev.has("quality") and main.has_method("set_graphics_quality_level"):
			main.call("set_graphics_quality_level", int(prev["quality"]))
		if prev.has("shadows") and main.has_method("set_shadow_quality_level"):
			main.call("set_shadow_quality_level", int(prev["shadows"]))
	if cursor != null and is_instance_valid(cursor) and cursor.has_method("release_modal"):
		cursor.call("release_modal", "climelapse_capture")


func _write_manifest(mp4: String, opts: Dictionary, camera: ClimelapseCameraRig, frames: Array) -> void:
	var doc := {
		"version": 4,
		"mp4": mp4.get_file(),
		"options": opts,
		"camera_mode": camera.mode,
		"keyframes": camera.keys.to_dict() if camera.has_keys() else {},
		"frames": frames,
	}
	var path := mp4.get_basename() + ".manifest.json"
	var mf := FileAccess.open(path, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(doc, "\t"))


func _finish(ok: bool, path: String, message: String) -> void:
	_active = false
	_cancel = false
	_phase = ""
	_frac = 1.0 if ok else 0.0
	capture_progress.emit(_frac)
	capture_complete.emit(ok, path, message)
