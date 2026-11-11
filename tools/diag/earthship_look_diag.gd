extends SceneTree

## WINDOWED look check (not a selftest): each built-in Earthship over flat
## ground with its earthworks, shot from outside (three-quarter front),
## inside the greenhouse looking along it, inside a room toward the
## greenhouse, and roof-off from above. One row per design.
##   godot --path . --windowed --resolution 1280x720 --script tools/diag/earthship_look_diag.gd
##     -- --out=<png> [--only=global_model,muro_di_gomme] [--cell=640x400]
## Run with APPDATA at a scratch folder or pass --out outside user data.

var CW := 640
var CH := 400
const VIEWS := ["outside", "greenhouse", "room", "roof_off"]


func _initialize() -> void:
	_run()


func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--%s=" % name):
			return str(a).substr(name.length() + 3)
	return def


func _studio() -> Node3D:
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var skymat := ProceduralSkyMaterial.new()
	skymat.sky_top_color = Color(0.32, 0.5, 0.82)
	skymat.sky_horizon_color = Color(0.72, 0.78, 0.86)
	var sky := Sky.new()
	sky.sky_material = skymat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	# A winter-ish sun from the south-west (+z is the glazing side; a
	# DirectionalLight shines along its -Z).
	sun.rotation_degrees = Vector3(-34.0, -25.0, 0.0)
	sun.light_energy = 1.7
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	root3d.add_child(sun)
	return root3d


func _run() -> void:
	await process_frame
	var root3d := _studio()
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 55.0
	cam.make_current()
	var cell := _arg("cell", "")
	if cell.contains("x"):
		CW = int(cell.get_slice("x", 0))
		CH = int(cell.get_slice("x", 1))
	var only := _arg("only", "")
	var subs: Array = []
	for b in EarthshipPresets.builtins():
		if only.is_empty() or (only.split(",") as Array).has(str(b["id"])):
			subs.append(b)
	var grid := Image.create(CW * VIEWS.size(), CH * subs.size(), false, Image.FORMAT_RGBA8)
	var holder := Node3D.new()
	root3d.add_child(holder)
	for k in subs.size():
		var spec := EarthshipSpec.resolve((subs[k] as Dictionary)["spec"])
		var d := EarthshipDesign.solve(spec)
		var fr: Dictionary = d["frame"]
		var st: Dictionary = d["stats"]
		print("EarthshipLook: %-16s bottles %d vigas %d pv %d plants? planters %d" % [str(subs[k]["id"]),
			int(st["bottles"]), int(st["vigas"]), int(st["pv_panels"]), (d["planters"] as Array).size()])
		for v in VIEWS.size():
			for c in holder.get_children():
				holder.remove_child(c)
				c.free()
			var cut := str(VIEWS[v]) == "roof_off"
			holder.add_child(EarthshipBuilder.build_node(spec, "E", {"cutaway": cut}))
			var earth: MeshInstance3D = load("res://scenes/ui/earthshiplab_modal.gd").earth_mesh(EarthshipDesign.earthworks(spec))
			holder.add_child(earth)
			var yf := float(fr["yf"])
			var x0 := float(fr["x0"])
			var x1 := float(fr["x1"])
			var g := float(spec["corridor_d"])
			var ex := float(d["entry_x"])
			match str(VIEWS[v]):
				"outside":
					var reach := (x1 - x0) * 0.75 + 6.0
					cam.fov = 50.0
					cam.position = Vector3(reach * 0.45, 3.5 + reach * 0.18, float(fr["z_front"]) + reach * 0.85)
					cam.look_at(Vector3(0.0, yf + 1.2, 0.0))
				"greenhouse":
					cam.fov = 70.0
					var zc := (0.0 + g - float(spec["planter_w"])) * 0.5
					cam.position = Vector3(x0 + float(spec["wall_t"]) + 0.6, yf + 1.6, zc)
					cam.look_at(Vector3(x1, yf + 1.3, zc + 0.2))
				"room":
					var r0: Dictionary = (d["rooms"] as Array)[0]
					var rx := (float(r0["x0"]) + float(r0["x1"])) * 0.5
					cam.fov = 75.0
					cam.position = Vector3(rx - 1.2, yf + 1.5, float(r0["z0"]) + 0.8)
					cam.look_at(Vector3(rx + 0.6, yf + 1.7, g))
				"roof_off":
					cam.fov = 50.0
					var span := (x1 - x0)
					cam.position = Vector3(0.0, span * 0.85 + 4.0, float(fr["z_front"]) + span * 0.35)
					cam.look_at(Vector3(0.0, yf, (float(fr["z_back"]) + float(fr["z_front"])) * 0.5))
			for _f in 8:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_viewport().get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(CW, CH)
			grid.blit_rect(img, Rect2i(0, 0, CW, CH), Vector2i(v * CW, k * CH))
	var out := _arg("out", "user://earthship_look.png")
	grid.save_png(out)
	print("EarthshipLook: wrote ", out)
	quit()
