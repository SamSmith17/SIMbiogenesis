extends SceneTree

## WINDOWED look check (not a selftest — it needs a GPU) for two things only a
## picture settles:
##   1. every driveable vehicle in the catalog as the placement + riding code
##      builds it (ModelCatalog.instantiate + resolved_scale + foot, ModelRoot
##      turned by its profile's yaw_deg for a rider facing -Z), with a RED bar
##      pointing the rider's FORWARD. The vehicle's front must point the way
##      the bar does — the art's own front is not knowable from the file, and
##      a bus driven backwards is the bug this exists to catch. Prints each
##      vehicle's built size (a 2 m "bus" is a unit bug).
##   2. the player's detailed figure in its own poses (idle, walk, run, jump
##      rising, falling, driving, EUC, aiming), turned to face -Z exactly as
##      the player builds it.
## Writes user://vehicle_look.png and user://player_pose_grid.png.
##   godot --path . --windowed --resolution 1280x720 --script gameplay/vehicle_look_diag.gd

const POSES := [
	{"mode": "idle"}, {"mode": "walk", "rate": 1.0}, {"mode": "run", "rate": 1.8},
	{"mode": "air", "vy": 4.0}, {"mode": "air", "vy": -6.0}, {"mode": "drive", "steer": 0.4},
	{"mode": "euc", "lean": Vector2(0.1, 0.3)}, {"mode": "idle", "aim": true},
]


func _initialize() -> void:
	_run()


func _studio() -> Node3D:
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.7, 0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.7
	env.environment = e
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	root3d.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.4, 0.33)
	ground.material_override = gm
	root3d.add_child(ground)
	return root3d


func _run() -> void:
	await process_frame
	var root3d := _studio()
	RenderingServer.global_shader_parameter_set("npc_night", 0.0)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 45.0
	cam.make_current()

	# --- vehicles ---
	var ids: Array = []
	for m in ModelCatalog.all_models():
		if not PlacedVehicle.profile_for_model(str(m.get("id", ""))).is_empty():
			ids.append(str(m["id"]))
	var spots: Array = []
	for k in ids.size():
		var mid: String = ids[k]
		var model := ModelCatalog.instantiate(mid)
		if model == null:
			print("VehicleLookDiag: %s did not instantiate" % mid)
			spots.append(Vector3(float(k) * 30.0, 0.0, 0.0))
			continue
		var holder := Node3D.new()
		root3d.add_child(holder)
		holder.position = Vector3(float(k) * 30.0, 0.0, 0.0)
		holder.add_child(model)
		var s := ModelCatalog.resolved_scale(mid, 1.0)
		model.scale = Vector3.ONE * s
		var prof: Dictionary = PlacedVehicle.PROFILES[PlacedVehicle.profile_for_model(mid)]
		model.rotation.y = deg_to_rad(float(prof.get("yaw_deg", 0.0)))
		model.position.y = -ModelCatalog.foot_local_y(mid) * s
		var aabb := _world_aabb(model)
		print("VehicleLookDiag: %-20s scale %.4f  size L(z) %.2f  W(x) %.2f  H %.2f m  foot %.3f" % [
			mid, s, aabb.size.z, aabb.size.x, aabb.size.y, aabb.position.y])
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.12, 0.12, 4.0)
		bar.mesh = bm
		var rm := StandardMaterial3D.new()
		rm.albedo_color = Color(1, 0.1, 0.1)
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bar.material_override = rm
		bar.position = Vector3(0.0, aabb.size.y + 0.6, -2.0)
		holder.add_child(bar)
		spots.append(holder.position + Vector3(0.0, aabb.size.y * 0.5, 0.0))
		spots[k] = Vector3(spots[k].x, spots[k].y, maxf(aabb.size.z, aabb.size.x))
	const CW := 320
	const CH := 240
	var grid := Image.create(CW * maxi(ids.size(), 1), CH * 2, false, Image.FORMAT_RGBA8)
	for k in ids.size():
		var p: Vector3 = spots[k]
		var target := Vector3(p.x, p.y, 0.0)
		var reach := maxf(p.z, 1.5) * 1.3 + 1.5
		for r in 2:
			# Row 0: side, camera on +X (forward = -Z = screen RIGHT).
			# Row 1: three-quarter from front-left above.
			cam.global_position = target + (Vector3(reach, reach * 0.35, 0.0) if r == 0
				else Vector3(-reach * 0.7, reach * 0.6, -reach * 0.7))
			cam.look_at(target, Vector3.UP)
			for i in 3:
				await process_frame
			var cell := _grab(CW, CH)
			grid.blit_rect(cell, Rect2i(0, 0, CW, CH), Vector2i(k * CW, r * CH))
	grid.save_png("user://vehicle_look.png")
	print("VehicleLookDiag: wrote %s  (top: side, forward = screen RIGHT, the red bar; bottom: from the front-left)" \
		% ProjectSettings.globalize_path("user://vehicle_look.png"))

	# --- the player's figure ---
	var figs: Array = []
	for k in POSES.size():
		var f := NpcSimpleFigure.new()
		f.hi_detail = true
		root3d.add_child(f)
		f.setup("player", Color(0.55, 0.62, 0.78))
		f.rotation.y = PI
		f.position = Vector3(float(k) * 20.0, 0.0, 200.0)
		figs.append(f)
	for i in 150:
		RenderingServer.global_shader_parameter_set("fx_time_npc", float(i) / 60.0)
		for k in figs.size():
			(figs[k] as NpcSimpleFigure).pose_player(POSES[k], 1.0 / 60.0)
		await process_frame
	const PW := 220
	const PH := 300
	var pgrid := Image.create(PW * POSES.size(), PH * 2, false, Image.FORMAT_RGBA8)
	for r in 2:
		for k in POSES.size():
			var target := Vector3(float(k) * 20.0, 0.85, 200.0)
			cam.global_position = target + (Vector3(4.0, 0.4, 0.0) if r == 0 else Vector3(0.0, 0.6, -4.0))
			cam.look_at(target, Vector3.UP)
			for i in 3:
				for kk in figs.size():
					(figs[kk] as NpcSimpleFigure).pose_player(POSES[kk], 1.0 / 60.0)
				await process_frame
			pgrid.blit_rect(_grab(PW, PH), Rect2i(0, 0, PW, PH), Vector2i(k * PW, r * PH))
	pgrid.save_png("user://player_pose_grid.png")
	print("VehicleLookDiag: wrote %s  (idle, walk, run, rising, falling, drive, euc, aim; top: side, facing screen RIGHT; bottom: front)" \
		% ProjectSettings.globalize_path("user://player_pose_grid.png"))
	quit(0)


func _grab(cw: int, ch: int) -> Image:
	var img := root.get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var crop_w := mini(w, int(float(h) * float(cw) / float(ch)))
	var cell := img.get_region(Rect2i((w - crop_w) / 2, 0, crop_w, h))
	cell.resize(cw, ch)
	cell.convert(Image.FORMAT_RGBA8)
	return cell


func _world_aabb(model: Node3D) -> AABB:
	var out := AABB()
	var found := false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		b.position -= model.get_parent().global_position as Vector3
		out = b if not found else out.merge(b)
		found = true
	return out
