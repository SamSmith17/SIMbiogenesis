extends SceneTree

## Every Controller Lab built-in on one sheet (WINDOWED; APPDATA at a
## scratch folder): a row per design — front three-quarter, back
## three-quarter (heatsink, mounts), underneath (ports), and the wiring bay
## with its cover off (or the front straight on).
##   Godot --path . --windowed --resolution 360x360 --script tools/diag/ctrllab_look_diag.gd -- --out=<png> [--only=a,b] [--cell=360] [--views=front,back,bottom,bay]

var _out := "user://ctrllab_look.png"
var _only: Array = []
var _cell := 360
var _views: Array = ["front", "back", "bottom", "bay"]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--only="):
			_only = Array(a.substr(7).split(",", false))
		elif a.begins_with("--cell="):
			_cell = int(a.substr(7))
		elif a.begins_with("--views="):
			_views = Array(a.substr(8).split(",", false))
	_run.call_deferred()


func _run() -> void:
	var ids: Array = _only if not _only.is_empty() else CtrlPresets.ids()
	root.size = Vector2i(_cell, _cell)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.52, 0.55)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.82)
	e.ambient_light_energy = 0.45
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = true
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 25, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, -150, 0)
	fill.light_energy = 0.6
	world.add_child(fill)
	var under := DirectionalLight3D.new()
	under.rotation_degrees = Vector3(70, 0, 0)
	under.light_energy = 0.35
	world.add_child(under)
	var cam := Camera3D.new()
	cam.fov = 28.0
	world.add_child(cam)
	cam.current = true
	var sheet := Image.create(_views.size() * _cell, ids.size() * _cell, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for r in ids.size():
		var spec := CtrlPresets.builtin(str(ids[r]))
		var b := CtrlBuilder.build_node(spec)
		world.add_child(b)
		var ab := _mm(CtrlDesign.bounds(b.design))
		for c in _views.size():
			var v := str(_views[c])
			var target := ab.get_center()
			var span := ab.size.length()
			var dir := Vector3(0.55, 0.32, 1.0)
			b.set_cover_visible(true)
			match v:
				"back":
					dir = Vector3(-0.65, 0.3, -1.0)
				"bottom":
					dir = Vector3(0.25, -1.0, 0.55)
				"bay":
					dir = Vector3(0.12, 0.08, 1.0)
					if (b.design["faces"] as Dictionary).has("bay"):
						b.set_cover_visible(false)
						var f: Dictionary = b.design["faces"]["bay"]
						target = (f["c"] as Vector3) * CtrlBuilder.MM
						span = (f["size"] as Vector2).length() * CtrlBuilder.MM * 1.1
			dir = dir.normalized()
			var dist := span * 0.5 / tan(deg_to_rad(cam.fov * 0.5)) * 1.05
			cam.near = maxf(dist * 0.02, 0.005)
			cam.far = dist * 10.0
			var up := Vector3.UP if absf(dir.y) < 0.9 else Vector3.BACK
			cam.global_transform = Transform3D(Basis.looking_at(-dir, up), target + dir * dist)
			await process_frame
			await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(_cell, _cell)
			sheet.blit_rect(img, Rect2i(0, 0, _cell, _cell), Vector2i(c * _cell, r * _cell))
		var d: Dictionary = b.design
		print("ctrllab look row %2d: %-30s %s  %d ports  checks: %s" % [r, ids[r], d["stats"]["size_text"], (d["ports"] as Array).size(),
			", ".join((d["checks"] as Array).map(func(x): return "%s %s" % [x["level"], x["text"]]))])
		b.queue_free()
		await process_frame
	sheet.save_png(_out)
	print("ctrllab look sheet: ", ProjectSettings.globalize_path(_out))
	quit(0)


func _mm(ab: AABB) -> AABB:
	return AABB(ab.position * CtrlBuilder.MM, ab.size * CtrlBuilder.MM)
