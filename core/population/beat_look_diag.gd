extends SceneTree

## WINDOWED look check (not a selftest) for dancing ON THE BEAT: a stage's
## music is faked into StageBeat (128 BPM) and the crowd figures (top row:
## rave, dance, sway, DJ) and stick figures (bottom row: the same four) are
## shot at three moments — mid-groove, 1.5 s before a DROP (hands up, the DJ's
## arm held up) and the drop itself (the jump) — as one grid per moment,
## user://beat_look_{groove,runup,drop}.png. Also proves the crowd shader
## compiles with the music globals (a shader error prints here).
##   godot --path . --windowed --resolution 1280x720 --script core/population/beat_look_diag.gd

const CROWD := [7, 4, 18, 10]   # CrowdCohort POSE_RAVE, DANCE, SWAY, DJ
const STICK := [["rave", NpcRig.CLIP_DANCE], ["", NpcRig.CLIP_DANCE], ["sway", NpcRig.CLIP_DANCE], ["dj", NpcRig.CLIP_DANCE]]
const MOMENTS := [["groove", 99.0, 0.0], ["runup", 1.5, 0.0], ["drop", 99.0, 1.0]]


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.6, 0.68, 0.8)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	env.environment = e
	root3d.add_child(env)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(300, 300)
	ground.mesh = pm
	root3d.add_child(ground)
	RenderingServer.global_shader_parameter_set("npc_night", 0.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = CrowdFigureMesh.mesh()
	mm.instance_count = CROWD.size()
	for k in CROWD.size():
		var p := Vector3(float(k) * 6.0, 0.0, 0.0)
		mm.set_instance_transform(k, Transform3D(p, p, Vector3(0.0, 1.0, 0.0), Vector3(float(CROWD[k]), 0.2, 0.0)))
		mm.set_instance_color(k, Color(Color.from_hsv(float(k) / 4.0, 0.45, 0.95), NpcPeak.pack_mood(0.5, NAN, 0.0)))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	var fm := ShaderMaterial.new()
	fm.shader = load("res://core/population/crowd_figure.gdshader")
	mi.material_override = fm
	mi.custom_aabb = AABB(Vector3(-50, -5, -50), Vector3(200, 20, 200))
	root3d.add_child(mi)
	var figs: Array = []
	for k in STICK.size():
		var f := NpcSimpleFigure.new()
		root3d.add_child(f)
		f.setup("beat_diag_%d" % k, Color.from_hsv(float(k) / 4.0, 0.5, 0.95))
		f.position = Vector3(float(k) * 6.0, 0.0, 12.0)
		figs.append(f)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 40.0
	cam.make_current()
	const CW := 220
	const CH := 300
	for mo in MOMENTS:
		var grid := Image.create(CW * CROWD.size(), CH * 2, false, Image.FORMAT_RGBA8)
		# Hold the moment: the beat stands at x.25 (mid-bounce) while the poses settle.
		var entry := {"sid": "diag", "pos": Vector2(9.0, 6.0), "radius": 180.0, "bpm": 128.0,
			"beat": 32.25, "stamp_us": Time.get_ticks_usec(), "running": false, "energy": 1.0,
			"build": 0.6 if str(mo[0]) == "runup" else 0.0, "until_drop": float(mo[1]),
			"since_drop": 0.0 if float(mo[2]) > 0.0 else INF, "drop_pulse": float(mo[2])}
		StageBeat.publish([entry])
		StageBeat.push_shader(Vector3(9.0, 1.0, 20.0))
		for i in 90:
			for k in figs.size():
				var fig: NpcSimpleFigure = figs[k]
				fig.set_beat(StageBeat.at(fig.global_position))
				fig.pose(str(STICK[k][1]), 1.0, 1.0 / 60.0, str(STICK[k][0]))
			await process_frame
		for r in 2:
			for k in CROWD.size():
				var target := Vector3(float(k) * 6.0, 1.0, 12.0 * r)
				cam.global_position = target + Vector3(0.0, 0.3, 4.0)
				cam.look_at(target, Vector3.UP)
				for i in 3:
					await process_frame
				var img := root.get_texture().get_image()
				var w := img.get_width()
				var h := img.get_height()
				var cw := int(float(h) * float(CW) / float(CH))
				var cell := img.get_region(Rect2i((w - cw) / 2, 0, cw, h))
				cell.resize(CW, CH)
				cell.convert(Image.FORMAT_RGBA8)
				grid.blit_rect(cell, Rect2i(0, 0, CW, CH), Vector2i(k * CW, r * CH))
		var path := "user://beat_look_%s.png" % str(mo[0])
		grid.save_png(path)
		print("BeatLookDiag: wrote %s (top: crowd rave, dance, sway, DJ; bottom: stick figures)" % ProjectSettings.globalize_path(path))
	StageBeat.clear()
	quit(0)
