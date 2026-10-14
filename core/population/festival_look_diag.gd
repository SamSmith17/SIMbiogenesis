extends SceneTree

## WINDOWED look check for the festival social pass (not a selftest — it needs
## a GPU): a night studio with a FIREPIT (forced lit), light-tier crowd
## figures in the new poses (DJ stood 1 m up on a box, cheer, rave, talk,
## sit) carrying glow sticks, and three full-tier stick figures (DJ / cheer /
## idle) with their glow bands — then the same by day. Writes
## user://festival_look_night.png and user://festival_look_day.png.
##   godot --path . --windowed --resolution 1280x720 --script core/population/festival_look_diag.gd

const POSES := [
	["dj", 10.0, true], ["samba", 11.0, false], ["rave", 7.0, false],
	["talk", 8.0, false], ["sit", 2.0, false], ["samba", 11.0, false],
]


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.025, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.25, 0.28, 0.4)
	e.ambient_light_energy = 0.25
	e.glow_enabled = true
	e.glow_intensity = 1.0
	e.glow_bloom = 0.05
	e.glow_hdr_threshold = 1.0
	env.environment = e
	root3d.add_child(env)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.28, 0.25, 0.2)
	ground.material_override = gm
	root3d.add_child(ground)
	# The DJ's box (a 1 m deck).
	var deck := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.4, 1.0, 1.6)
	deck.mesh = bm
	deck.position = Vector3(-3.0, 0.5, -1.0)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.12, 0.12, 0.14)
	deck.material_override = dm
	root3d.add_child(deck)
	# The firepit, lit.
	var pit := FirepitBuilder.build_node()
	pit.position = Vector3(2.5, 0.0, 1.0)
	root3d.add_child(pit)
	var fire := FirepitFire.new()
	pit.add_child(fire)
	await process_frame
	fire.set("_lit", true)
	# Light-tier crowd figures in the new poses.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = CrowdFigureMesh.mesh()
	mm.instance_count = POSES.size()
	for k in POSES.size():
		var spec: Array = POSES[k]
		var x := -3.0 + float(k) * 1.3
		var p := Vector3(x, 0.0, -1.0) if bool(spec[2]) else Vector3(x - 1.0, 0.0, 1.2)
		var elev := 1.0 if bool(spec[2]) else 0.0
		# Seeds chosen so every figure carries glow (fract(seed*13.7) < 0.72).
		var seed := 0.03 + 0.05 * float(k)
		mm.set_instance_transform(k, Transform3D(p, p, Vector3(0.0, 1.0, 0.0), Vector3(float(spec[1]), seed, -elev)))
		# The ladder: the DJ high (0.9), two at PEAK EXPERIENCE dancing the
		# samba (began 0.05 sim-h before t_rel 0: fully ramped), one raver
		# almost there (buzz 0.85: the shimmer + sparkle), a talker part way
		# (buzz 0.4) and a sitter in a fair mood with nothing building.
		var moods := [0.9, NAN, 0.85, 0.8, 0.75, NAN]
		var buzz := [0.0, 0.0, 0.85, 0.4, 0.0, 0.0]
		var m: Variant = moods[k]
		var a := NpcPeak.pack_mood(0.9, -0.05) if is_nan(float(m)) \
			else NpcPeak.pack_mood(float(m), NAN, float(buzz[k]))
		mm.set_instance_color(k, Color(Color.from_hsv(float(k) / 6.0, 0.45, 0.95), a))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	var fm := ShaderMaterial.new()
	fm.shader = load("res://core/population/crowd_figure.gdshader")
	mi.material_override = fm
	mi.custom_aabb = AABB(Vector3(-50, -5, -50), Vector3(100, 20, 100))
	root3d.add_child(mi)
	# A PEAK RIPPLE running out from the samba peaker (peak_ripple.gdshader),
	# caught half way: the ring the contagion's reach draws on the ground.
	var rmm := MultiMesh.new()
	rmm.transform_format = MultiMesh.TRANSFORM_3D
	rmm.use_custom_data = true
	var rq := QuadMesh.new()
	rq.size = Vector2(2.0, 2.0)
	rq.orientation = PlaneMesh.FACE_Y
	rmm.mesh = rq
	rmm.instance_count = 1
	var rp := Vector3(-3.0 + 1.3 - 1.0, 0.05, 1.2)
	rmm.set_instance_transform(0, Transform3D(Basis.from_scale(Vector3(4.0, 1.0, 4.0)), rp))
	rmm.set_instance_custom_data(0, Color(1.7, 1.0, 0.0, 0.0))
	var rmi := MultiMeshInstance3D.new()
	rmi.multimesh = rmm
	var rmat := ShaderMaterial.new()
	rmat.shader = load("res://core/population/peak_ripple.gdshader")
	rmi.material_override = rmat
	rmi.custom_aabb = AABB(Vector3(-50, -5, -50), Vector3(100, 20, 100))
	root3d.add_child(rmi)
	# Full-tier stick figures with glow bands.
	var figs: Array = []
	# Stick figures: the peak samba (green), a raver at buzz 0.8, a low mood.
	var flavors := ["", "rave", ""]
	var clips := [NpcRig.CLIP_PEAK_DANCE, NpcRig.CLIP_DANCE, NpcRig.CLIP_IDLE]
	for k in 3:
		var f := NpcSimpleFigure.new()
		root3d.add_child(f)
		f.setup("diag_npc_%d" % (k * 7 + 1), Color.from_hsv(0.1 + 0.3 * float(k), 0.5, 0.95))
		f.position = Vector3(3.5 + float(k) * 1.1, 0.0, -1.5)
		f.rotation.y = PI
		figs.append([f, flavors[k], clips[k]])
		f.set_mood([0.9, 0.88, 0.3][k], [1.0, 0.0, 0.0][k], 0.0, [0.0, 0.8, 0.0][k])
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.global_position = Vector3(0.0, 2.6, 8.5)
	cam.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	cam.make_current()
	for night in [1.0, 0.0]:
		RenderingServer.global_shader_parameter_set("npc_night", night)
		e.background_color = Color(0.02, 0.025, 0.05) if night > 0.5 else Color(0.55, 0.65, 0.8)
		e.ambient_light_energy = 0.25 if night > 0.5 else 1.0
		var t := 0.0
		for i in 90:
			t += 1.0 / 60.0
			RenderingServer.global_shader_parameter_set("fx_time_npc", t * 2.0)
			for pair in figs:
				(pair[0] as NpcSimpleFigure).pose(str(pair[2]), 1.0, 1.0 / 60.0, str(pair[1]))
			await process_frame
		var img := root.get_texture().get_image()
		var path := "user://festival_look_%s.png" % ("night" if night > 0.5 else "day")
		img.save_png(path)
		print("FestivalLookDiag: wrote %s" % ProjectSettings.globalize_path(path))
	quit(0)
