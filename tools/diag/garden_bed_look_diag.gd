extends SceneTree

## The grow beds and their crops in an empty studio (WINDOWED, not a
## selftest; point APPDATA at a scratch folder). Shoots every crop at full
## size and in fruit, a keyhole bed from above and from the path, a run of
## raised beds, and the willow and sorghum plots, to --out=<dir> (default
## user://garden_look/).
##   Godot --path . --windowed --resolution 1280x720 --script res://tools/diag/garden_bed_look_diag.gd -- --out=<dir>

var _out := "user://garden_look"
var _cam: Camera3D
var _root: Node3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out) if _out.begins_with("user://") else _out)
	_run.call_deferred()


func _studio() -> void:
	_root = Node3D.new()
	root.add_child(_root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.8
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = true
	env.environment = e
	_root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	_root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.55, 0.45)
	ground.material_override = gm
	_root.add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 45.0
	_root.add_child(_cam)
	_cam.current = true


func _set_day(bed: GrowBed, d: float) -> void:
	# The bed's own clock would put back "now"; the studio sets the day.
	bed.set_process(false)
	for c in bed.get_children():
		if c is MultiMeshInstance3D:
			((c as MultiMeshInstance3D).material_override as ShaderMaterial).set_shader_parameter("now_d", d)


func _shot(name: String, eye: Vector3, at: Vector3) -> void:
	_cam.look_at_from_position(eye, at, Vector3.UP)
	for i in 6:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_out, name])
	print("garden look: ", name)


func _run() -> void:
	_studio()
	await process_frame
	# Every crop in a row, mature (day 0.75 of its cycle from a sowing on day 0).
	var ids: Array = GardenCrops.CROPS.keys()
	var row := Node3D.new()
	_root.add_child(row)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://vegetation/garden_crop.gdshader")
	var x := 0.0
	for id in ids:
		var info := GardenCrops.info(str(id))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = GardenCrops.mesh(str(id))
		mm.instance_count = 1
		var w := maxf(float(info["spacing"]) * 1.4, 0.6)
		x += w * 0.5
		mm.set_instance_transform(0, Transform3D(Basis(), Vector3(x, 0, 0)))
		var cyc := float(info["cycle"])
		# Sown so that today is 75 % of the way through its cycle.
		mm.set_instance_custom_data(0, Color(-0.75 * cyc, cyc, float(info["mature"]), 0.5))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		row.add_child(mmi)
		x += w * 0.5
	mat.set_shader_parameter("now_d", 0.0)
	var mid := x * 0.5
	await _shot("crops_row_low", Vector3(mid, 1.3, 7.5), Vector3(mid, 0.6, 0))
	await _shot("crops_row_left", Vector3(3.0, 0.9, 3.0), Vector3(3.0, 0.4, 0))
	await _shot("crops_row_mid", Vector3(mid, 0.9, 3.0), Vector3(mid, 0.4, 0))
	await _shot("crops_row_right", Vector3(x - 3.0, 1.2, 3.5), Vector3(x - 3.0, 0.8, 0))
	row.queue_free()
	# A keyhole bed, 120 days after planting.
	var kh := GrowBed.build_node({"layout": "keyhole", "crops": "garden", "seed": 7})
	_root.add_child(kh)
	_set_day(kh, 120.0)
	await _shot("keyhole_above", Vector3(0, 22, 16), Vector3(0, 0, 0))
	await _shot("keyhole_path", Vector3(0.2, 1.6, 10.5), Vector3(0, 0.5, 2.0))
	await _shot("keyhole_ring", Vector3(6.0, 1.5, -5.5), Vector3(8.0, 0.4, -1.0))
	_set_day(kh, 10.0)
	await _shot("keyhole_day10", Vector3(0, 22, 16), Vector3(0, 0, 0))
	kh.queue_free()
	# Raised beds and the two plots.
	var beds := GrowBed.build_node({"layout": "bed", "area_m2": 50.0, "seed": 3})
	_root.add_child(beds)
	_set_day(beds, 100.0)
	await _shot("beds_50m2", Vector3(6, 4.5, 9), Vector3(0, 0.3, 0))
	beds.queue_free()
	var wil := GrowBed.build_node({"layout": "plot", "area_m2": 50.0, "crops": "willow", "seed": 2})
	_root.add_child(wil)
	_set_day(wil, 800.0)
	await _shot("plot_willow", Vector3(9, 3.5, 10), Vector3(0, 1.2, 0))
	wil.queue_free()
	var sor := GrowBed.build_node({"layout": "plot", "area_m2": 50.0, "crops": "sorghum", "seed": 5})
	_root.add_child(sor)
	_set_day(sor, 80.0)
	await _shot("plot_sorghum", Vector3(9, 3.0, 10), Vector3(0, 1.0, 0))
	quit()
