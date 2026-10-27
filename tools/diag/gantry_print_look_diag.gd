extends SceneTree

## The gantry print preview on its own (WINDOWED, not a selftest): a machine,
## its calibration cube planned and laid as roads at a fraction of the job,
## shot from beside the bed. How the bead look is judged.
##   Godot --path . --windowed --resolution 900x700 --script tools/diag/gantry_print_look_diag.gd -- --preset=i3_220 --frac=0.5 --out=<png>

var _frames := 0
var _b: GantryLabBuilder = null
var _cam: Camera3D = null
var _out := ""
var _svp: SubViewport = null


func _initialize() -> void:
	var preset := "i3_220"
	var frac := 0.5
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			preset = a.substr(9)
		elif a.begins_with("--frac="):
			frac = float(a.substr(7))
		elif a.begins_with("--out="):
			_out = a.substr(6)
	var spec := GantryLabSpec.resolve((GantryLabPresets.builtin(preset)["spec"] as Dictionary).duplicate(true))
	var w := Node3D.new()
	_svp = SubViewport.new()
	_svp.own_world_3d = true
	_svp.msaa_3d = Viewport.MSAA_4X
	_svp.size = Vector2i(900, 640)
	_svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_svp)
	_svp.add_child(w)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.36, 0.38)
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment.ambient_light_energy = 0.6
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.shadow_enabled = true
	w.add_child(sun)
	_b = GantryLabBuilder.build_node(spec, "M", {}) as GantryLabBuilder
	w.add_child(_b)
	var design := GantryLabDesign.solve(spec)
	var text := GantryLabSamples.text(spec, "cube")
	var parse := GantryLabGcode.parse(text)
	var plan := GantryLabMotion.plan(parse, design["limits"])
	var tool := GantryLabParts.tool(str(spec["tool"]["id"]))
	var line := float(tool["nozzle_mm"]) * 1.12
	_b.set_print_preview(plan["moves"], line, GantryLabBuilder.layer_guess_mm(plan["moves"], line), Color(0.85, 0.55, 0.2))
	var smp := GantryLabMotion.sample(plan, float(plan["total_s"]) * frac)
	_b.set_tool_mm(smp["pos"])
	_b.set_print_progress(int(smp["i"]), float(smp["s"]))
	print("roads %d  layer %.2f mm  line %.2f mm  at %s" % [_b.road_count(), GantryLabBuilder.layer_guess_mm(plan["moves"], line), line, str(smp["pos"])])
	_cam = Camera3D.new()
	_cam.fov = 40.0
	_cam.near = 0.005
	w.add_child(_cam)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		var c := _b.print_centre_global()
		var span := 0.06 if float(_b.road_transform(0).basis.z.length()) < 0.002 else 0.9
		_cam.look_at_from_position(c + Vector3(span * 0.7, span * 0.45, span * 0.8), c, Vector3.UP)
		print("centre %s" % str(c))
	if _frames == 12:
		var img := _svp.get_texture().get_image()
		if not _out.is_empty():
			img.save_png(_out)
			print("saved %s" % _out)
		return true
	return false
