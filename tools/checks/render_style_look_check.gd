extends RefCounted

## Visual styles on a REAL world (sandbox, read-only):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/render_style_look_check.gd -Label render_style
## Shoots the same views in every style (RenderStyle.ORDER) at two hours and
## writes a sheet per view to screenshots/<label>/ (realistic first). Asserts
## the post pass compiled and is running for a styled look, and that the
## realistic look leaves the environment's adjustment off.
## --style-hours=13,18.5 picks the hours; --style-views=player,eye,mid,high.

var _fails: Array = []
var _out := ""


func _ok(cond: bool, what: String) -> void:
	print("style-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var driver := main.get_node_or_null("RenderStyle")
	_ok(driver != null, "Main made its RenderStyle driver")
	var player := main.find_child("Player", true, false) as Node3D
	var world := "world"
	var hours: Array = [13.0, 18.5]
	var views: Array = ["player", "eye", "eye2", "mid", "high"]
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--world="):
			world = s.substr(8)
		elif s.begins_with("--style-hours="):
			hours = []
			for v in s.substr(14).split(","):
				hours.append(float(v))
		elif s.begins_with("--style-views="):
			views = Array(s.substr(14).split(","))
	_out = "user://screenshots/render_style/%s" % world
	DirAccess.make_dir_recursive_absolute(_out)
	print("style-check: shots in %s" % ProjectSettings.globalize_path(_out))

	if bool(player.get("is_fpv_drone_mode")) and player.has_method("toggle_remote_drone_view"):
		player.call("toggle_remote_drone_view")
	main.set("time_scale", 0.0)
	var hidden := _hide_ui(main)
	var cam := Camera3D.new()
	cam.name = "StyleCheckCam"
	cam.fov = 70.0
	cam.far = 20000.0
	main.add_child(cam)
	var c := SiteCentre.xz(main)
	var p0 := player.global_position
	var yaw0 := player.rotation.y

	for h: float in hours:
		main.set("day_time", h)
		await _settle(tree, 6)
		for view: String in views:
			var imgs: Array = []
			for id: String in RenderStyle.ORDER:
				RenderStylePrefs.set_style(id)
				_place(main, cam, view, c, p0, yaw0)
				await _settle(tree, 40)
				if id != RenderStyle.REALISTIC and driver != null:
					var st: Dictionary = driver.call("debug_state")
					_ok(bool(st["compiled"]), "%s: post pass compiled (%s)" % [id, str(st["compile_error"])])
					_ok(bool(st["post_on"]), "%s: post pass running" % id)
					_ok(int(st["labels_mirrored"]) > 0, "%s: %d world labels drawn as 2D text (%d on screen: %s)" % [
						id, int(st["labels_mirrored"]), int(st["labels_drawn"]),
						str(driver.call("label_overlay").drawn_texts().slice(0, 4))])
					_ok(_hidden_label_count(main) == int(st["labels_mirrored"]), "%s: their 3D copies are hidden" % id)
				if id == RenderStyle.REALISTIC:
					var env: Environment = main.get("environment").environment
					_ok(not env.adjustment_enabled, "realistic: no post-tonemap adjustment")
					_ok(_hidden_label_count(main) == 0, "realistic: every 3D label is back on its own layers")
				var img := main.get_viewport().get_texture().get_image()
				img.convert(Image.FORMAT_RGB8)
				img.save_png("%s/h%02d_%s_%s.png" % [_out, int(h), view, id])
				img.resize(960, int(960.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
				imgs.append(img)
			_save_pair(imgs, "%s/pair_h%02d_%s.png" % [_out, int(h), view])
		main.call("pop_camera_claim", "style_check")

	main.call("pop_camera_claim", "style_check")
	await _measure_gpu(main, tree)
	cam.queue_free()
	RenderStylePrefs.set_style(RenderStyle.REALISTIC)
	for n in hidden:
		if is_instance_valid(n):
			n.visible = true
	return {"ok": _fails.is_empty(), "failures": _fails}


func _place(main: Node, cam: Camera3D, view: String, c: Vector2, p0: Vector3, yaw0: float) -> void:
	if view == "player":
		main.call("pop_camera_claim", "style_check")
		return
	var at := Vector3(c.x, 0.0, c.y)
	var yaw := yaw0
	var h := 1.7
	var pitch := -4.0
	match view:
		"eye":
			at = p0
			yaw = yaw0 + PI * 0.5
		"eye2":
			at = Vector3(c.x + 30.0, 0.0, c.y + 30.0)
			yaw = yaw0 + PI
			pitch = 2.0
		"mid":
			h = 28.0
			pitch = -22.0
		"high":
			h = 140.0
			pitch = -38.0
			yaw = yaw0 + PI * 0.25
	var gy := TerrainSurfaceQuery.ground_height_at(main, at.x, at.z)
	var pos := Vector3(at.x, gy + h, at.z)
	if view == "mid" or view == "high":
		pos -= Vector3(-sin(yaw), 0.0, -cos(yaw)) * h * 1.2
		pos.y = TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.z) + h
	cam.global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(pitch), yaw, 0.0)), pos)
	main.call("push_camera_claim", "style_check", {"camera_id": cam.get_instance_id()})


## GPU ms per style at the player's view (the renderer's own measurement).
func _measure_gpu(main: Node, tree: SceneTree) -> void:
	var vp := main.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var base := -1.0
	for id: String in RenderStyle.ORDER:
		RenderStylePrefs.set_style(id)
		await _settle(tree, 20)
		var sum := 0.0
		for _i in 40:
			await tree.process_frame
			sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		var ms := sum / 40.0
		print("style-check gpu %s: %.2f ms" % [id, ms])
		if base < 0.0:
			base = ms
		else:
			_ok(ms - base < 7.0, "%s costs %.2f ms over realistic" % [id, ms - base])


## All styles as one sheet: up to three across, in RenderStyle.ORDER
## (realistic first).
func _save_pair(imgs: Array, path: String) -> void:
	if imgs.is_empty():
		return
	var w: int = (imgs[0] as Image).get_width()
	var hh: int = (imgs[0] as Image).get_height()
	var cols := mini(imgs.size(), 3)
	var rows := ceili(imgs.size() / float(cols))
	var out := Image.create(w * cols, hh * rows, false, Image.FORMAT_RGB8)
	for i in imgs.size():
		out.blit_rect(imgs[i], Rect2i(0, 0, w, hh), Vector2i(w * (i % cols), hh * (i / cols)))
	out.save_png(path)


func _hidden_label_count(main: Node) -> int:
	var n := 0
	for l in main.find_children("*", "Label3D", true, false):
		if l.has_meta(StyleLabelOverlay.META_LAYERS):
			n += 1
	return n


func _hide_ui(main: Node) -> Array:
	var out: Array = []
	for n in main.find_children("*", "CanvasLayer", true, false):
		if n.has_meta(&"style_label_overlay"):
			continue
		if (n as CanvasLayer).visible:
			(n as CanvasLayer).visible = false
			out.append(n)
	return out
