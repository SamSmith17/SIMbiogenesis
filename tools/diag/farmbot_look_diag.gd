extends SceneTree

## A FarmBot on its bed in an empty studio (WINDOWED, not a selftest; point
## APPDATA at a scratch folder). Shoots the Genesis XL from the four sides,
## close up on the tool mount mid-job and the tool bay, then a long custom bed,
## to --out=<dir> (default user://farmbot_look/).
##   Godot --path . --windowed --resolution 1280x720 --script res://tools/diag/farmbot_look_diag.gd -- --out=<dir>

var _out := "user://farmbot_look"
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
	sky.sky_material = ProceduralSkyMaterial.new()
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
	gm.albedo_color = Color(0.55, 0.52, 0.45)
	ground.material_override = gm
	_root.add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 45.0
	_root.add_child(_cam)
	_cam.current = true


func _shot(name: String, eye: Vector3, at: Vector3) -> void:
	_cam.look_at_from_position(eye, at, Vector3.UP)
	for i in 6:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_out, name])
	print("farmbot look: ", name)


func _run() -> void:
	_studio()
	await process_frame
	var fb := FarmBotBuilder.build_node(FarmBotPresets.spec("genesis_xl"))
	_root.add_child(fb)
	fb.set_days(150.0)
	# Mid-watering over a plant in the middle of the bed.
	var lay: Dictionary = fb.design["layout"]
	var p: Dictionary = (lay["plants"] as Array)[(lay["plants"] as Array).size() / 2]
	var m := FarmBotLayout.to_machine(fb.spec, float(p["x"]), float(p["z"]))
	var soil := float(fb.spec["gantry"]["soil_z_mm"])
	fb.set_machine(Vector3(m.x, m.y, soil + FarmBotJobs.WATER_ABOVE_SOIL_MM), "watering", true)
	await _shot("xl_front", Vector3(0, 3.2, 7.5), Vector3(0, 0.6, 0))
	await _shot("xl_end", Vector3(-7.0, 2.4, 1.5), Vector3(0, 0.7, 0))
	await _shot("xl_above", Vector3(0.5, 9.0, 3.0), Vector3(0, 0, 0))
	var tip := fb.tip_local()
	await _shot("xl_mount", tip + Vector3(0.9, 0.6, 1.1), tip + Vector3(0, 0.2, 0))
	# The tool bay with the seeder about to be picked up.
	var sl := FarmBotJobs.slot_of(fb.spec, "seeder")
	fb.set_machine(Vector3(sl.x, sl.y, FarmBotJobs.SAFE_Z_MM), "", false)
	var bay := fb.machine_to_local(sl)
	await _shot("xl_toolbay", bay + Vector3(0.8, 0.7, -1.2), bay + Vector3(0.2, 0.2, 0))
	# Seeding: the seeder picking from the trough at the far side.
	fb.set_machine(Vector3(m.x, fb.spec["bed"]["width_m"] * 1000.0 - FarmBotJobs.TROUGH_IN_MM,
		soil + FarmBotJobs.TOOL_ABOVE_SOIL_MM), "seeder", false)
	await _shot("xl_trough", fb.tip_local() + Vector3(1.0, 0.5, 1.2), fb.tip_local())
	fb.set_days(12.0)
	await _shot("xl_day12", Vector3(0, 3.2, 7.5), Vector3(0, 0.6, 0))
	fb.queue_free()
	var lo := FarmBotBuilder.build_node(FarmBotPresets.spec("market_row_18"))
	_root.add_child(lo)
	lo.set_days(160.0)
	await _shot("market_row", Vector3(-11.0, 4.0, 6.0), Vector3(0, 0.4, 0))
	lo.queue_free()
	# The radial arms over the greenhouse keyhole, mid-watering on a steady day.
	var kh := FarmBotBuilder.build_node(FarmBotPresets.spec("keyhole_dome_20m"))
	_root.add_child(kh)
	kh.set_days(150.0)
	var plan := FarmBotJobs.day_plan(kh.spec, kh.design["layout"], 123, true)
	kh.set_arms(FarmBotJobs.sample_arms(plan, 7.0 * 3600.0 + 1500.0))
	await _shot("keyhole_above", Vector3(0.0, 24.0, 15.0), Vector3(0, 0, 0))
	await _shot("keyhole_slot", Vector3(0.0, 2.6, 13.0), Vector3(0, 0.6, 2.0))
	await _shot("keyhole_side", Vector3(14.0, 4.5, -6.0), Vector3(0, 0.7, 0))
	var a0: Dictionary = kh.arms[0]
	var ktip := kh.machine_to_local(a0["pos"])
	await _shot("keyhole_carriage", ktip + Vector3(1.6, 1.1, 1.4), ktip + Vector3(0, 0.4, 0))
	var rr := FarmBotGeom.rail_r(kh.spec)
	var ang := FarmBotGeom.arm_angle(kh.spec, (a0["pos"] as Vector3).x)
	var wheel := Vector3(sin(ang) * rr, 0.5, cos(ang) * rr)
	await _shot("keyhole_wheel", wheel + Vector3(1.4, 0.8, 1.6), wheel)
	for i in kh.arms.size():
		kh.set_arm(i, FarmBotJobs.park_pos(kh.spec, i), "", false)
	await _shot("keyhole_post", Vector3(2.4, 2.2, 2.6), Vector3(0, 0.6, 0))
	kh.queue_free()
	var ks := FarmBotBuilder.build_node(FarmBotPresets.spec("keyhole_small_6m"))
	_root.add_child(ks)
	ks.set_days(150.0)
	await _shot("keyhole_small", Vector3(5.0, 4.0, 6.0), Vector3(0, 0.5, 0))
	quit()
