extends SceneTree

## WINDOWED look check for the fabrication clips (not a selftest — it needs a
## GPU): every starter clip in core/population/anims/ played on a stick figure
## holding its tool (FabToolCatalog) by IK at a plausible work position — the
## saw on a bench, the drill over it, the driver into a post, a beam carried,
## set down and lifted overhead. Shot from the SIDE (row 1) and three-quarter
## FRONT (row 2); prints each hand's palm-to-grip error. Writes
## user://fab_pose_grid.png.
##   godot --path . --windowed --resolution 1280x720 --script core/population/fab_pose_diag.gd
## Launch with APPDATA pointed at a scratch folder so user:// is not the
## player's (the harness rules): see LINKAGE_PARITY.md.

const SPACING := 6.0
## clip id, tool id ("" = a carried beam), time in the clip, tool placement
## relative to the figure (origin, yaw deg, pitch deg), bench height (0 = none)
const SCENES := [
	["saw_cut", "circular_saw", 0.8, Vector3(-0.04, 0.83, 0.5), 0.0, 0.0, 0.8],
	["drill_hole", "drill", 0.6, Vector3(-0.02, 0.82, 0.55), 180.0, 0.0, 0.8],
	["fasten_bolt", "impact_driver", 0.3, Vector3(-0.12, 1.15, 0.4), 0.0, -90.0, 0.0],
	["wrench_nut", "wrench", 0.3, Vector3(-0.1, 0.95, 0.42), 180.0, 0.0, 0.0],
	["place_beam", "", 1.2, Vector3(0.0, 0.62, 0.45), 0.0, 0.0, 0.0],
	["carry_beam", "", 0.3, Vector3(0.0, 0.95, 0.32), 0.0, 0.0, 0.0],
	["lift_ring", "", 2.0, Vector3(0.0, 1.92, 0.15), 0.0, 0.0, 0.0],
	["hold_brace", "", 0.5, Vector3(-0.05, 1.05, 0.4), 0.0, 0.0, 0.0],
]


func _initialize() -> void:
	_run()


## A beam the hands carry: a 1.2 m 2x4 along X, grips 0.35 m either side.
func _beam_part() -> Node3D:
	var root3 := Node3D.new()
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(1.4, 0.089, 0.038)
	mi.mesh = b
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.7, 0.5)
	mi.material_override = m
	root3.add_child(mi)
	var hb := FabToolCatalog.hand_basis(Vector3(1, 0, 0), Vector3(0, 0.35, -1))
	root3.set_meta("sockets", {"grip": Transform3D(hb, Vector3(-0.32, 0, 0)), "grip2": Transform3D(hb, Vector3(0.32, 0, 0))})
	return root3


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
	e.ambient_light_energy = 0.7
	env.environment = e
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root3d.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.4, 0.33)
	ground.material_override = gm
	root3d.add_child(ground)
	RenderingServer.global_shader_parameter_set("npc_night", 0.0)
	var figs: Array = []
	var tools: Array = []
	var clips: Array = []
	for k in SCENES.size():
		var sc: Array = SCENES[k]
		var f := NpcSimpleFigure.new()
		f.hi_detail = true
		root3d.add_child(f)
		f.setup("fab_diag_%d" % k, Color.from_hsv(float(k) / 8.0, 0.5, 0.95))
		f.position = Vector3(float(k) * SPACING, 0.0, 0.0)
		figs.append(f)
		var tool: Node3D = FabToolCatalog.build(str(sc[1]), false) if not str(sc[1]).is_empty() else _beam_part()
		root3d.add_child(tool)
		tool.position = f.position + (sc[3] as Vector3)
		tool.basis = Basis.from_euler(Vector3(deg_to_rad(float(sc[5])), deg_to_rad(float(sc[4])), 0.0))
		tools.append(tool)
		if float(sc[6]) > 0.0:
			var bench := MeshInstance3D.new()
			var bb := BoxMesh.new()
			bb.size = Vector3(1.2, float(sc[6]), 0.5)
			bench.mesh = bb
			bench.position = f.position + Vector3(0.0, float(sc[6]) / 2.0 - 0.02, 0.55)
			var bm := StandardMaterial3D.new()
			bm.albedo_color = Color(0.35, 0.3, 0.25)
			bench.material_override = bm
			root3d.add_child(bench)
		clips.append(NpcAnimClip.load_clip(str(sc[0])))
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 40.0
	cam.make_current()
	var _drive := func() -> void:
		for k in figs.size():
			var f: NpcSimpleFigure = figs[k]
			var c: NpcAnimClip = clips[k]
			var tool: Node3D = tools[k]
			var s: Dictionary = tool.get_meta("sockets", {})
			f.set_clip(c, float(SCENES[k][2]), 1.0)
			if c != null:
				for pair in [[0, "hand_r"], [1, "hand_l"]]:
					var sock := str(c.ik.get(pair[1], "none"))
					if sock != "none" and s.get(sock) is Transform3D:
						f.set_hand_target(pair[0], tool.global_transform * (s[sock] as Transform3D))
					else:
						f.set_hand_target(pair[0], null)
			f.pose("idle", 1.0, 1.0 / 60.0, "")
	for i in 90:
		_drive.call()
		await process_frame
	for k in figs.size():
		var f: NpcSimpleFigure = figs[k]
		var s: Dictionary = (tools[k] as Node3D).get_meta("sockets", {})
		var errs: PackedStringArray = []
		for pair in [[0, "grip"], [1, "grip2"]]:
			if s.get(pair[1]) is Transform3D and clips[k] != null and str((clips[k] as NpcAnimClip).ik.get("hand_r" if pair[0] == 0 else "hand_l", "none")) != "none":
				var want: Transform3D = (tools[k] as Node3D).global_transform * (s[pair[1]] as Transform3D)
				errs.append("%s %.3f m" % [pair[1], f.palm_global(pair[0]).origin.distance_to(want.origin)])
		print("FabPoseDiag: %-12s %s" % [SCENES[k][0], ", ".join(errs)])
	const CW := 240
	const CH := 320
	var grid := Image.create(CW * SCENES.size(), CH * 2, false, Image.FORMAT_RGBA8)
	var views := [Vector3(3.2, 1.1, 0.4), Vector3(-1.6, 1.5, 2.6)]
	for r in views.size():
		for k in SCENES.size():
			var target := Vector3(float(k) * SPACING, 0.95, 0.25)
			cam.global_position = target + (views[r] as Vector3)
			cam.look_at(target, Vector3.UP)
			for i in 3:
				_drive.call()
				await process_frame
			var img := root.get_texture().get_image()
			var w := img.get_width()
			var h := img.get_height()
			var cw := int(h * 0.75)
			var cell := img.get_region(Rect2i((w - cw) / 2, 0, cw, h))
			cell.resize(CW, CH)
			cell.convert(Image.FORMAT_RGBA8)
			grid.blit_rect(cell, Rect2i(0, 0, CW, CH), Vector2i(k * CW, r * CH))
	var path := "user://fab_pose_grid.png"
	grid.save_png(path)
	print("FabPoseDiag: wrote %s (columns: %s)" % [ProjectSettings.globalize_path(path),
		", ".join(PackedStringArray(SCENES.map(func(s): return str(s[0])))) ])
	quit(0)
