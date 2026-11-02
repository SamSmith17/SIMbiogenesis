extends SceneTree

## WINDOWED look check (not a selftest — it needs a GPU): every built-in
## living vehicle (VehiclePresets) as the builder draws it, from the FRONT,
## the curb SIDE and the REAR, one row per preset, in an empty studio. The
## things only a picture settles — wheels inside their arches, the grille
## and the lights on the nose, the step under a bus door, windows over the
## beds and not the shower, propane on a trailer's tongue, the windshield
## at a real height. Prints each preset's size and the number of wheel
## meshes shared.
##   godot --path . --windowed --resolution 1280x720 --script tools/diag/vehicle_preset_grid_diag.gd
##     [-- --out=<png>] [-- --only=van,rv]
## Writes user://vehicle_preset_grid.png (run with APPDATA at a scratch
## folder, or the PNG lands in the player's user data).

const CW := 360
const CH := 240


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
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.7, 0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.6
	env.environment = e
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_energy = 1.2
	root3d.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(800, 800)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.5, 0.47, 0.42)
	ground.material_override = gm
	root3d.add_child(ground)
	return root3d


func _run() -> void:
	await process_frame
	var root3d := _studio()
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 40.0
	cam.make_current()
	var only := _arg("only", "")
	var ids: Array = []
	for b in VehiclePresets.builtins():
		var id := str((b as Dictionary)["id"])
		if only.is_empty() or only.split(",").has(id):
			ids.append(id)
	var holders: Array = []
	var sizes: Array = []
	for k in ids.size():
		var id: String = ids[k]
		var spec := VehiclePresets.builtin(id)
		var d := VehicleDesign.solve(spec)
		var model := VehicleBuilder.build_from_design(d)
		var holder := Node3D.new()
		root3d.add_child(holder)
		holder.position = Vector3(0.0, 0.0, float(k) * 40.0)
		holder.add_child(model)
		holders.append(holder)
		sizes.append(Vector3(float(d["width_m"]), float(d.get("overall_h_m", d["height_m"])), float(d["length_m"])))
		var meshes := {}
		for w in model.get_node("Wheels").get_children():
			var mi := (w as Node3D).get_node("Mesh") as MeshInstance3D
			meshes[mi.mesh.get_instance_id()] = true
		print("VehiclePresetGrid: %-15s %.1f x %.2f x %.2f m, %d wheels on %d meshes, %d lugs, arches at %s" % [id,
			float(d["length_m"]), float(d["width_m"]), float(d.get("overall_h_m", d["height_m"])),
			(d["wheels"] as Array).size(), meshes.size(), int(d.get("lug_count", 0)),
			str((d["axles"] as Array).map(func(a): return "%.1f" % (float((a as Dictionary)["zf"]) - float(d["half_len"]))))])
	await process_frame
	var grid := Image.create(CW * 3, CH * maxi(ids.size(), 1), false, Image.FORMAT_RGBA8)
	for k in ids.size():
		var c: Vector3 = (holders[k] as Node3D).position
		var sz: Vector3 = sizes[k]
		var target := c + Vector3(0.0, sz.y * 0.45, 0.0)
		for v in 3:
			var reach := 0.0
			var from := Vector3.ZERO
			match v:
				0:   # the front, a little from the curb side and above
					reach = maxf(sz.x, sz.y) * 1.3 + 3.5 + sz.z * 0.15
					from = target + Vector3(reach * 0.35, reach * 0.3, -reach)
				1:   # the curb side (forward = -Z = screen LEFT)
					reach = sz.z * 1.05 + 3.0
					from = target + Vector3(reach, reach * 0.22, 0.0)
				2:   # the rear
					reach = maxf(sz.x, sz.y) * 1.3 + 3.5 + sz.z * 0.15
					from = target + Vector3(-reach * 0.35, reach * 0.3, reach)
			cam.global_position = from
			cam.look_at(target, Vector3.UP)
			for i in 3:
				await process_frame
			grid.blit_rect(_grab(CW, CH), Rect2i(0, 0, CW, CH), Vector2i(v * CW, k * CH))
	var out := _arg("out", "user://vehicle_preset_grid.png")
	grid.save_png(out)
	print("VehiclePresetGrid: wrote %s  (columns: front / curb side (forward = LEFT) / rear; rows: %s)" % [
		ProjectSettings.globalize_path(out), ", ".join(PackedStringArray(ids))])
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
