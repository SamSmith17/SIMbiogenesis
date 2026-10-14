extends SceneTree

## WINDOWED look check for the ground / burn poses (not a selftest — it needs
## a GPU): cross-legged, lounging (feet out, propped on the arms), kneeling
## (a sandman), redirecting, fire flow and gazing — each drawn by the crowd
## shader (top row) and by the stick figure (bottom row), shot from the SIDE
## and from the FRONT so the direction every limb bends is readable. A pose
## whose legs fold the wrong way or whose arms reach backward shows up here
## and nowhere else. Writes user://ground_pose_grid.png.
##   godot --path . --windowed --resolution 1280x720 --script core/population/ground_pose_diag.gd

const WORK_CODE := 5
const CROWD := [
	["cross", 12], ["lounge", 13], ["kneel", 14], ["redirect", 15], ["fire_flow", 16], ["gaze", 17],
	["sit", 2], ["lie", 3], ["work", WORK_CODE],
]
const STICK := [NpcRig.CLIP_SIT_CROSS, NpcRig.CLIP_LOUNGE, NpcRig.CLIP_KNEEL, NpcRig.CLIP_REDIRECT,
	NpcRig.CLIP_FIREFLOW, NpcRig.CLIP_GAZE, NpcRig.CLIP_SIT, NpcRig.CLIP_SLEEP, NpcRig.CLIP_WORK]


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
	e.ambient_light_energy = 1.0
	env.environment = e
	root3d.add_child(env)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.4, 0.33)
	ground.material_override = gm
	root3d.add_child(ground)
	RenderingServer.global_shader_parameter_set("npc_night", 0.0)
	# Every figure 20 m from the next so a close camera sees one at a time:
	# crowd figures at z = 0, stick figures at z = 40, all facing +Z.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = CrowdFigureMesh.mesh()
	mm.instance_count = CROWD.size()
	for k in CROWD.size():
		var p := Vector3(float(k) * 20.0, 0.0, 0.0)
		mm.set_instance_transform(k, Transform3D(p, p, Vector3(0.0, 1.0, 0.0), Vector3(float(CROWD[k][1]), 0.9, 0.0)))
		mm.set_instance_color(k, Color(Color.from_hsv(float(k) / 6.0, 0.45, 0.95), NpcPeak.pack_mood(0.5, NAN, 0.0)))
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
		f.setup("pose_diag_%d" % k, Color.from_hsv(float(k) / 6.0, 0.5, 0.95))
		f.position = Vector3(float(k) * 20.0, 0.0, 40.0)
		figs.append(f)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 40.0
	cam.make_current()
	# Settle the procedural poses (eased targets).
	var t := 0.0
	for i in 120:
		t += 1.0 / 60.0
		RenderingServer.global_shader_parameter_set("fx_time_npc", t)
		for k in figs.size():
			(figs[k] as NpcSimpleFigure).pose(str(STICK[k]), 1.0, 1.0 / 60.0, "")
		await process_frame
	for k in figs.size():
		print("GroundPoseDiag: %-10s stick head %.2f m" % [STICK[k], (figs[k] as NpcSimpleFigure).head_height()])
	# Grid: rows crowd-side, crowd-front, stick-side, stick-front; one column
	# per pose. Side = camera on +X looking -X (figure faces RIGHT->left? no:
	# faces +Z, which is screen-RIGHT from +X... see the row label).
	const CW := 240
	const CH := 300
	var grid := Image.create(CW * CROWD.size(), CH * 4, false, Image.FORMAT_RGBA8)
	var rows := [[0.0, Vector3(4.2, 0.9, 0.0)], [0.0, Vector3(0.0, 1.1, 4.2)],
		[40.0, Vector3(4.2, 0.9, 0.0)], [40.0, Vector3(0.0, 1.1, 4.2)]]
	for r in rows.size():
		for k in CROWD.size():
			var target := Vector3(float(k) * 20.0, 0.75, float(rows[r][0]))
			cam.global_position = target + (rows[r][1] as Vector3)
			cam.look_at(target, Vector3.UP)
			for i in 3:
				t += 1.0 / 60.0
				RenderingServer.global_shader_parameter_set("fx_time_npc", t)
				for kk in figs.size():
					(figs[kk] as NpcSimpleFigure).pose(str(STICK[kk]), 1.0, 1.0 / 60.0, "")
				await process_frame
			var img := root.get_texture().get_image()
			var w := img.get_width()
			var h := img.get_height()
			var cw := int(h * 0.8)
			var cell := img.get_region(Rect2i((w - cw) / 2, 0, cw, h))
			cell.resize(CW, CH)
			cell.convert(Image.FORMAT_RGBA8)
			grid.blit_rect(cell, Rect2i(0, 0, CW, CH), Vector2i(k * CW, r * CH))
	var path := "user://ground_pose_grid.png"
	grid.save_png(path)
	print("GroundPoseDiag: wrote %s (rows: crowd side, crowd front, stick side, stick front; figures face +Z = screen-right in side views)" % ProjectSettings.globalize_path(path))
	quit(0)
