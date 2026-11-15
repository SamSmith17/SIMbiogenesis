extends SceneTree

## WINDOWED look check (not a selftest): each built-in greenhouse with its
## beds, gantries and light racks stood inside it (GreenhouseParts), shot from
## outside (three-quarter front), inside along its length, and roof-off from
## above. One row per design; vents half open, lights on.
##   godot --path . --windowed --resolution 1280x720 --script tools/diag/greenhouse_look_diag.gd
##     -- --out=<png> [--only=market_hoop,dome_20m] [--cell=640x400] [--gantry] [--lights]
## Run with APPDATA at a scratch folder or pass --out outside user data.

var CW := 640
var CH := 400
const VIEWS := ["outside", "inside", "roof_off"]


func _initialize() -> void:
	_run()


func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if str(a) == "--" + name:
			return "1"
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
	skymat.ground_bottom_color = Color(0.36, 0.33, 0.27)
	skymat.ground_horizon_color = Color(0.55, 0.52, 0.45)
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
	sun.rotation_degrees = Vector3(-38.0, -25.0, 0.0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	root3d.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(300.0, 300.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.45, 0.3)
	ground.material_override = gm
	ground.position.y = -0.005
	root3d.add_child(ground)
	return root3d


## Show a bed's crops `days` after planting (the diag has no Main clock).
func _grow(n: Node, days: float) -> void:
	n.set_process(false)
	for mi in n.find_children("*", "MultiMeshInstance3D", true, false):
		var m := (mi as MultiMeshInstance3D).material_override
		if m is ShaderMaterial:
			(m as ShaderMaterial).set_shader_parameter("now_d", days)


func _run() -> void:
	await process_frame
	var root3d := _studio()
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.make_current()
	var cell := _arg("cell", "")
	if cell.contains("x"):
		CW = int(cell.get_slice("x", 0))
		CH = int(cell.get_slice("x", 1))
	var only := _arg("only", "")
	var subs: Array = []
	for b in GreenhousePresets.builtins():
		if only.is_empty() or (only.split(",") as Array).has(str(b["id"])):
			subs.append(b)
	var grid := Image.create(CW * VIEWS.size(), CH * subs.size(), false, Image.FORMAT_RGBA8)
	var holder := Node3D.new()
	root3d.add_child(holder)
	for k in subs.size():
		var spec := GreenhouseSpec.resolve((subs[k] as Dictionary)["spec"])
		if _arg("gantry", "") == "1":
			spec["beds"]["gantry"] = true
		if _arg("lights", "") == "1":
			spec["beds"]["lights"] = true
		var d := GreenhouseDesign.solve(spec)
		var st: Dictionary = d["stats"]
		print("GreenhouseLook: %-14s floor %.0f m² glazed %.0f m² beds %d (%.0f m²) vents %.0f %% UA %.0f W/K $%.0f" % [
			str(subs[k]["id"]), float(st["floor_area_m2"]), float(st["glazed_m2"]), int(st["beds"]),
			float(st["bed_area_m2"]), 100.0 * float(st["vent_share"]), float(st["ua_w_k"]), GreenhouseDesign.cost_usd(d)])
		for c in d["checks"]:
			print("   check %s: %s" % [str(c["level"]), str(c["text"])])
		var L := float(spec["length_m"])
		var W := float(spec["width_m"])
		var H := float(st["height_m"])
		for v in VIEWS.size():
			for c2 in holder.get_children():
				holder.remove_child(c2)
				c2.free()
			var cut := str(VIEWS[v]) == "roof_off"
			var shell := GreenhouseBuilder.build_node(spec, "G", {"cutaway": cut})
			holder.add_child(shell)
			GreenhouseBuilder.set_vents(shell, 0.5)
			for p in GreenhouseParts.parts(d):
				var pd: Dictionary = p
				var extra: Dictionary = pd["extra"]
				var n := ModelCatalog.instantiate(str(pd["model_id"]), extra)
				if n == null:
					continue
				n.position = Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
				holder.add_child(n)
				if str(pd["model_id"]) == GrowLightRack.MODEL_ID:
					GrowLightRack.set_lit(n, true)
				_grow(n, 70.0)
			var span := maxf(L, W)
			match str(VIEWS[v]):
				"outside":
					cam.fov = 50.0
					cam.position = Vector3(L * 0.55 + span * 0.35, H * 0.8 + span * 0.15, W * 0.5 + span * 0.9)
					cam.look_at(Vector3(0.0, H * 0.4, 0.0))
				"inside":
					cam.fov = 72.0
					cam.position = Vector3(L * 0.5 - 0.6, 1.6, 0.0) if str(spec["form"]) != "dome" else Vector3(0.0, 1.7, W * 0.42)
					cam.look_at(Vector3(-L * 0.3, 1.0, 0.0) if str(spec["form"]) != "dome" else Vector3(0.0, 0.8, -W * 0.2))
				"roof_off":
					cam.fov = 50.0
					cam.position = Vector3(0.0, span * 0.9 + 3.0, W * 0.6 + span * 0.3)
					cam.look_at(Vector3(0.0, 0.0, 0.0))
			for _f in 8:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_viewport().get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(CW, CH)
			grid.blit_rect(img, Rect2i(0, 0, CW, CH), Vector2i(v * CW, k * CH))
	var out := _arg("out", "user://greenhouse_look.png")
	grid.save_png(out)
	print("GreenhouseLook: wrote ", out)
	quit()
