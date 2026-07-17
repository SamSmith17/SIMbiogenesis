extends SceneTree

## One-off WINDOWED visual diagnostic for Wave 8 conduits (not part of CI).
## Builds a patio light string, a fairy string, an emissive LED strip, and a
## ground-draped extension cord over a flat floor, then screenshots to
## user://screenshots/conduit_diag/conduit_diag.png and quits.
## Run: Godot.exe.exe --path . --windowed --resolution 1280x720 --script core/conduits/conduit_visual_diag.gd

var _frames := 0


func _initialize() -> void:
	var world_root := Node3D.new()
	world_root.name = "ConduitDiag"
	root.add_child(world_root)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.65)
	e.ambient_light_energy = 0.4
	e.glow_enabled = true
	env.environment = e
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	sun.light_energy = 0.35  # dusk so the bulbs read
	world_root.add_child(sun)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.25, 0.22, 0.18)
	plane.material = fm
	floor_mesh.mesh = plane
	world_root.add_child(floor_mesh)

	_add_post(world_root, Vector3(-6, 0, 0))
	_add_post(world_root, Vector3(0, 0, -2))
	_add_post(world_root, Vector3(6, 0, 0))

	# Patio string with discrete bulbs between the posts.
	_add_light_string(world_root, "led_patio",
		[Vector3(-6, 3, 0), Vector3(0, 3, -2), Vector3(6, 3, 0)], true)
	# Fairy lights (dense tiny bulbs) hung lower.
	_add_light_string(world_root, "led_fairy",
		[Vector3(-6, 2.2, 1.5), Vector3(0, 2.2, 2.5), Vector3(6, 2.2, 1.5)], true)
	# Continuous emissive strip along the front.
	_add_light_string(world_root, "led_strip",
		[Vector3(-5, 0.5, 4.5), Vector3(5, 0.5, 4.5)], true)
	# Ground-draped extension cord (would sag through the floor undraped).
	var ground_fn := func(_pos: Vector3) -> float: return 0.0
	var cord: Dictionary = ConduitMeshBuilder.build(
		[Vector3(-6, 0.6, 3.0), Vector3(6, 0.6, 3.5)], "extension_cord",
		ConduitMeshBuilder.DEFAULT_SEGMENTS_PER_SPAN, ground_fn)
	var cord_mi := MeshInstance3D.new()
	cord_mi.mesh = cord.get("mesh")
	cord_mi.material_override = cord.get("material")
	world_root.add_child(cord_mi)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 3.2, 11.5)
	cam.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	world_root.add_child(cam)
	cam.make_current()


func _add_post(parent: Node3D, at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.06
	cyl.height = 3.2
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.22, 0.15)
	cyl.material = m
	mi.mesh = cyl
	mi.position = at + Vector3(0, 1.6, 0)
	parent.add_child(mi)


func _add_light_string(parent: Node3D, kind: String, pts: Array, lit: bool) -> void:
	var built: Dictionary = ConduitMeshBuilder.build_light_string(pts, kind)
	var mi := MeshInstance3D.new()
	mi.mesh = built.get("mesh")
	mi.material_override = built.get("material")
	parent.add_child(mi)
	var rt := LightStringRuntime.new()
	parent.add_child(rt)
	rt.configure(kind, built.get("bulb_positions", PackedVector3Array()),
		float(built.get("arc_length_m", 0.0)))
	var meta: Dictionary = ConduitKinds.type_meta(kind)
	if float(meta.get("bulb_spacing_m", 0.0)) <= 0.001:
		rt.set_strip_mesh(mi)
	# Force lit for the capture regardless of clock.
	rt.is_on = lit
	rt.call("_apply_visual_state")
	rt.set_process(false)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 30:
		var img := root.get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("user://screenshots/conduit_diag")
		img.save_png("user://screenshots/conduit_diag/conduit_diag.png")
		print("CONDUIT DIAG SAVED: user://screenshots/conduit_diag/conduit_diag.png")
	return _frames > 32
