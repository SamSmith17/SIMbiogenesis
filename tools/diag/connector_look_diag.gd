extends SceneTree

## Every ConnectorCatalog entry shot one by one from a three-quarter view and
## laid out on one sheet (WINDOWED; point APPDATA at a scratch folder).
##   Godot --path . --windowed --resolution 900x900 --script tools/diag/connector_look_diag.gd -- --out=<png> [--only=a,b] [--cell=220]

var _out := "user://connector_look.png"
var _only: Array = []
var _cell := 220


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--only="):
			_only = Array(a.substr(7).split(",", false))
		elif a.begins_with("--cell="):
			_cell = int(a.substr(7))
	_run.call_deferred()


func _run() -> void:
	var ids: Array = _only if not _only.is_empty() else ConnectorCatalog.ids()
	root.size = Vector2i(_cell, _cell)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.2, 0.22, 0.25)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.6)
	e.ambient_light_energy = 0.9
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 1.6
	world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -140, 0)
	fill.light_energy = 0.5
	world.add_child(fill)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	world.add_child(cam)
	cam.current = true
	var cols := int(ceil(sqrt(float(ids.size()))))
	var rows := int(ceil(float(ids.size()) / float(cols)))
	var sheet := Image.create(cols * _cell, rows * _cell, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for i in ids.size():
		var id := str(ids[i])
		var mi := MeshInstance3D.new()
		var g := BattParts.Geo.new()
		var r := ConnectorParts.build(g, id, Transform3D.IDENTITY)
		mi.mesh = g.commit()
		world.add_child(mi)
		var ab: AABB = mi.mesh.get_aabb()
		var c := ab.get_center()
		var span := maxf(ab.size.length(), 0.004)
		var dir := Vector3(0.6, 0.45, 1.0).normalized()
		cam.size = span * 1.15
		cam.near = 0.0005
		cam.far = span * 10.0
		cam.global_transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), c + dir * span * 3.0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		img.resize(_cell, _cell)
		sheet.blit_rect(img, Rect2i(0, 0, _cell, _cell), Vector2i((i % cols) * _cell, (i / cols) * _cell))
		print("connector look %2d (row %d col %d): %s  %d tris  %d pins  %d labels" % [i, i / cols, i % cols, id,
			g.tri_count(), (r["pins"] as Array).size(), (r["labels"] as Array).size()])
		mi.queue_free()
	sheet.save_png(_out)
	print("connector look sheet: ", ProjectSettings.globalize_path(_out))
	quit(0)
