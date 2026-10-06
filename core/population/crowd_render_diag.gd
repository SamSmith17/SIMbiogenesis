extends SceneTree

## WINDOWED renderer diagnostic for the crowd tier (not a selftest — it needs
## a GPU): stands a few crowd figures in an empty studio and renders the SAME
## mesh four ways — plain StandardMaterial with ordinary instance transforms
## (cull_back, then cull_disabled) and crowd_figure.gdshader with the slot
## layout (as shipped, then with cull_back patched to cull_disabled) — plus the
## card shader, counting the pixels each variant puts on screen. A figure that
## draws with the plain material but not with the shader is a shader/slot bug;
## one that draws only with culling off is wound inside out.
##   godot --path . --windowed --resolution 640x480 --script core/population/crowd_render_diag.gd
## Writes crowd_diag_<variant>.png next to the project (user://).

var _done := false


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.5, 0.5)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	env.environment = e
	root3d.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	root3d.add_child(light)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.global_position = Vector3(0, 1.4, 6.0)
	cam.look_at(Vector3(0, 1.0, 0), Vector3.UP)
	cam.make_current()
	await process_frame
	await process_frame
	var bg := _count_pixels()
	print("CrowdDiag: background non-grey pixels = %d" % bg)

	var mesh := CrowdFigureMesh.mesh()
	print("CrowdDiag: mesh surfaces=%d verts=%d aabb=%s" % [mesh.get_surface_count(),
		mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if mesh.get_surface_count() > 0 else 0,
		str(mesh.get_aabb())])
	var fig_src: String = (load("res://core/population/crowd_figure.gdshader") as Shader).code
	var card_src: String = (load("res://core/population/crowd_card.gdshader") as Shader).code

	# A: plain material, plain transforms, cull_back (mesh + winding sanity).
	var std := StandardMaterial3D.new()
	std.albedo_color = Color(0.9, 0.2, 0.2)
	await _variant(root3d, "A_std_cullback", mesh, std, false)
	var std2 := std.duplicate() as StandardMaterial3D
	std2.cull_mode = BaseMaterial3D.CULL_DISABLED
	await _variant(root3d, "B_std_nocull", mesh, std2, false)
	# C: the shipped figure shader with the slot layout.
	var sh := Shader.new()
	sh.code = fig_src
	var m3 := ShaderMaterial.new()
	m3.shader = sh
	await _variant(root3d, "C_figure_shader", mesh, m3, true)
	# D: same shader, culling off.
	var sh2 := Shader.new()
	sh2.code = fig_src.replace("render_mode cull_back,", "render_mode cull_disabled,")
	var m4 := ShaderMaterial.new()
	m4.shader = sh2
	await _variant(root3d, "D_figure_nocull", mesh, m4, true)
	# E: the card shader, figure_dist 0 so the cards draw at every distance.
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var sh3 := Shader.new()
	sh3.code = card_src
	var m5 := ShaderMaterial.new()
	m5.shader = sh3
	m5.set_shader_parameter("figure_dist", 0.0)
	await _variant(root3d, "E_card_shader", quad, m5, true)
	quit(0)


func _variant(parent: Node3D, label: String, mesh: Mesh, mat: Material, slots: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = 3
	var poses := [0.0, 1.0, 3.0]
	for i in 3:
		var x := -1.5 + 1.5 * float(i)
		var col := Color(0.4, 0.8, 0.9)
		if slots:
			var a := Vector3(x, 0.0, 0.0)
			var b := Vector3(x, 0.0, 0.0) if i != 1 else Vector3(x, 0.0, -0.8)
			mm.set_instance_transform(i, Transform3D(a, b, Vector3(0.0, 1.0, 0.0), Vector3(float(poses[i]), 0.3, 0.0)))
		else:
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x, 0.0, 0.0)))
		mm.set_instance_color(i, col)
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.custom_aabb = AABB(Vector3(-50, -50, -50), Vector3(100, 100, 100))
	parent.add_child(mi)
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("t_rel", 0.5)
		(mat as ShaderMaterial).set_shader_parameter("draw_mode", 1.0)
		(mat as ShaderMaterial).set_shader_parameter("lod_dist", 0.0)
	await process_frame
	await process_frame
	await process_frame
	var n := _count_pixels()
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("user://crowd_diag_%s.png" % label)
	print("CrowdDiag: %-18s non-grey pixels = %d" % [label, n])
	mi.queue_free()
	await process_frame


func _count_pixels() -> int:
	var img := root.get_viewport().get_texture().get_image()
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if absf(c.r - c.g) > 0.08 or absf(c.g - c.b) > 0.08 or c.r < 0.3 or c.r > 0.7:
				n += 1
	return n
