extends SceneTree

## A GLB seen straight down, orthographic, to a PNG — for reading hole
## patterns off flat parts. Not a selftest. WINDOWED:
##   Godot --path . --script tools/diag/glb_topview_diag.gd -- --glb=<path> --out=<png> [--px=2400]

func _initialize() -> void:
	var glb := ""
	var out := "user://glb_topview.png"
	var px := 2400
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--glb="):
			glb = a.substr(6)
		elif a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--px="):
			px = int(a.substr(5))
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(glb, st) != OK:
		print("cannot read ", glb)
		quit(1)
		return
	var scene := doc.generate_scene(st)
	var vp := SubViewport.new()
	vp.size = Vector2i(px, px)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	vp.add_child(scene)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(1, 1, 1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	env.environment = e
	vp.add_child(env)
	# Globals resolve only once the root is in the tree (first process frame).
	await process_frame
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var bb := m.global_transform * m.get_aabb()
		lo = lo.min(bb.position)
		hi = hi.max(bb.end)
	var c := (lo + hi) * 0.5
	var size := maxf(hi.x - lo.x, hi.z - lo.z) * 1.04
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size
	vp.add_child(cam)
	cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(c.x, hi.y + 1.0, c.z))
	print("view centre (%.4f, %.4f) size %.4f m over %d px = %.3f mm/px" % [c.x, c.z, size, px, size * 1000.0 / px])
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(out)
	print("wrote ", out)
	quit()
