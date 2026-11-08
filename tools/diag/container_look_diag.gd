extends SceneTree

## WINDOWED look check (not a selftest — it needs a GPU): the ISO container
## as CargoContainerBuilder draws it, beside the IBC tote and the other
## intermodal units, in an empty studio. The things only a picture settles —
## the corrugation reading as pressed steel, the door gear at the right
## height, the hinges on the posts, the pockets through the bottom rail,
## the doors swinging back along the sides, the cutaway pieces.
##   godot --path . --windowed --resolution 1280x720 --script tools/diag/container_look_diag.gd
##     [-- --out=<png>] [-- --cell=640x400]
## One row per subject, one column per view. Run with APPDATA at a scratch
## folder or pass --out somewhere outside user data.

var CW := 640
var CH := 400
const VIEWS := ["front", "door", "side", "top"]


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
	var skymat := ProceduralSkyMaterial.new()
	skymat.sky_top_color = Color(0.62, 0.68, 0.78)
	skymat.sky_horizon_color = Color(0.42, 0.42, 0.44)
	var sky := Sky.new()
	sky.sky_material = skymat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	root3d.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(800, 800)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.3, 0.29, 0.27)
	gm.roughness = 0.95
	ground.material_override = gm
	root3d.add_child(ground)
	return root3d


func _subjects() -> Array:
	var out: Array = []
	out.append({"name": "20ft closed", "node": CargoContainerBuilder.build_node({"container_id": "container_20"}),
		"size": Vector3(2.438, 2.591, 6.058)})
	out.append({"name": "20ft open (blue)", "node": CargoContainerBuilder.build_node(
		{"container_id": "container_20", "paint": "blue", "doors_open_deg": CargoContainerBuilder.DOORS_FOLDED_DEG}),
		"size": Vector3(2.438, 2.591, 6.058)})
	var cut := CargoContainerBuilder.build_from_entry(IntermodalUnits.resolve("iso_20"), "Cut",
		{"cutaway": true, "doors_open_deg": CargoContainerBuilder.DOORS_FOLDED_DEG, "paint": "green"})
	for g in ["Roof", "WallR"]:
		var n := cut.get_node_or_null(g)
		if n != null:
			n.visible = false
	out.append({"name": "20ft cutaway (roof + right wall off)", "node": cut,
		"size": Vector3(2.438, 2.591, 6.058)})
	out.append({"name": "40ft HC", "node": CargoContainerBuilder.build_node({"container_id": "container_40hc", "paint": "rust"}),
		"size": Vector3(2.438, 2.896, 12.192)})
	out.append({"name": "IBC 1000 L (%s)" % ("glb" if IbcBuilder.has_model() else "procedural"),
		"node": IbcBuilder.build(IntermodalUnits.resolve("ibc_1000")), "size": Vector3(1.0, 1.16, 1.2)})
	out.append({"name": "GMA pallet + drum + gaylord", "node": _trio(), "size": Vector3(3.6, 1.2, 1.3)})
	return out


func _trio() -> Node3D:
	var n := Node3D.new()
	var k := 0
	for tid in ["pallet_gma", "drum_55_steel", "gaylord_48"]:
		var u := IntermodalUnitBuilder.build_node({"template": tid})
		u.position = Vector3(-1.3 + 1.3 * float(k), 0.0, 0.0)
		n.add_child(u)
		k += 1
	return n


func _run() -> void:
	await process_frame
	var root3d := _studio()
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 38.0
	cam.make_current()
	var subs := _subjects()
	var holders: Array = []
	for k in subs.size():
		var s: Dictionary = subs[k]
		var holder := Node3D.new()
		root3d.add_child(holder)
		holder.position = Vector3(0.0, 0.0, float(k) * 60.0)
		holder.add_child(s["node"])
		holders.append(holder)
		var tri := 0
		for m in (s["node"] as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(i)
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				tri += (idx.size() if idx != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		print("ContainerLook: %-40s %d triangles" % [str(s["name"]), tri])
	await process_frame
	var cell := _arg("cell", "")
	if cell.contains("x"):
		CW = int(cell.get_slice("x", 0))
		CH = int(cell.get_slice("x", 1))
	var grid := Image.create(CW * VIEWS.size(), CH * subs.size(), false, Image.FORMAT_RGBA8)
	for k in subs.size():
		var c: Vector3 = (holders[k] as Node3D).position
		var sz: Vector3 = (subs[k] as Dictionary)["size"]
		var target := c + Vector3(0.0, sz.y * 0.45, 0.0)
		for v in VIEWS.size():
			var reach := 0.0
			var from := Vector3.ZERO
			match str(VIEWS[v]):
				"front":   # the front end, three-quarter from the left
					reach = maxf(sz.x, sz.y) * 1.2 + 2.5 + sz.z * 0.25
					from = target + Vector3(-reach * 0.6, reach * 0.38, -reach * 0.8)
				"door":    # the door end, three-quarter from the right
					reach = maxf(sz.x, sz.y) * 1.2 + 2.5 + sz.z * 0.25
					from = target + Vector3(reach * 0.6, reach * 0.32, reach * 0.8)
				"side":    # the side, nearly square on
					reach = sz.z * 0.9 + 2.5
					from = target + Vector3(reach, reach * 0.18, reach * 0.12)
				"top":
					reach = sz.z * 0.75 + 2.5
					from = target + Vector3(reach * 0.25, reach * 0.9, reach * 0.3)
			cam.position = from
			cam.look_at(target, Vector3.UP)
			await process_frame
			await process_frame
			await process_frame
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(CW, CH, Image.INTERPOLATE_LANCZOS)
			grid.blit_rect(img, Rect2i(0, 0, CW, CH), Vector2i(v * CW, k * CH))
	var out := _arg("out", "user://container_look.png")
	var err := grid.save_png(out)
	print("ContainerLook: wrote %s (%s)" % [out, error_string(err)])
	quit(0 if err == OK else 1)
