extends SceneTree

## The gantry catalog's parts drawn in a row, three-quarter view, to a PNG —
## how a new catalog part's drawing is checked. Not a selftest. WINDOWED:
##   Godot --path . --script tools/diag/gantry_parts_look_diag.gd -- [--refs=a,b] [--out=<png>]

const DEFAULT_REFS := ["joining_plate_t", "joining_plate_90", "cube_corner", "corner_3way", "inside_corner",
	"nema17_flat", "nema23_flat", "nut_block_8", "mini_v_plate", "coupler_5_6", "corner_bracket"]
const COLORS := {"plate": Color(0.55, 0.57, 0.6), "black": Color(0.08, 0.08, 0.09), "alu": Color(0.75, 0.77, 0.8),
	"chrome": Color(0.85, 0.85, 0.88), "delrin": Color(0.1, 0.1, 0.1)}


func _initialize() -> void:
	var refs: Array = DEFAULT_REFS
	var out := "user://gantry_parts_look.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--refs="):
			refs = Array(a.substr(7).split(","))
		elif a.begins_with("--out="):
			out = a.substr(6)
	var vp := SubViewport.new()
	vp.size = Vector2i(2400, 900)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.93, 0.94, 0.96)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.5
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	vp.add_child(sun)
	var x := 0.0
	for r in refs:
		var ref := str(r)
		var sts := {}
		for d in GantryLabCatalog.draw(ref, {}):
			GantryLabDetail.emit(sts, d)
		var root := Node3D.new()
		root.position = Vector3(x, 0, 0)
		vp.add_child(root)
		for k in sts:
			var st: SurfaceTool = sts[k]
			var mi := MeshInstance3D.new()
			mi.mesh = st.commit()
			var mat := StandardMaterial3D.new()
			mat.albedo_color = COLORS.get(str(k), Color(0.6, 0.4, 0.3))
			mat.cull_mode = BaseMaterial3D.CULL_BACK
			mi.material_override = mat
			root.add_child(mi)
		var lbl := Label3D.new()
		lbl.text = GantryLabCatalog.label_of(ref, GantryLabCatalog.params_of(ref, {}))
		lbl.font_size = 18
		lbl.pixel_size = 0.0004
		lbl.position = Vector3(0, -0.012, 0.05)
		lbl.rotation_degrees = Vector3(-90, 0, 0)
		lbl.modulate = Color.BLACK
		root.add_child(lbl)
		x += 0.11
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 0.42
	vp.add_child(cam)
	var c := Vector3(x * 0.5 - 0.055, 0, 0)
	cam.look_at_from_position(c + Vector3(0.0, 0.5, 0.45), c, Vector3.UP)
	for _i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(out)
	print("wrote ", ProjectSettings.globalize_path(out))
	quit()
