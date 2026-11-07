extends SceneTree

## Every TC part type side by side (NOT a selftest): one row per size given,
## the part in its own frame with its ports marked (cyan disc = clamp face,
## yellow = thread / barb), then a joined sample (the built-in designs).
## WINDOWED; point APPDATA at a scratch folder.
##   Godot --path . --windowed --resolution 1600x1000 --script res://tools/diag/tclab_parts_sheet.gd -- --out=<png> [--sizes=1.5,3] [--design=elbow_run]

var _out := "user://tclab_parts_sheet.png"
var _sizes: Array = ["1.5", "3"]
var _design := ""
var _yaw := 35.0
var _per_row := 9
var _frames := 0
var _cam: Camera3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--out="):
			_out = s.substr(6)
		elif s.begins_with("--sizes="):
			_sizes = Array(s.substr(8).split(","))
		elif s.begins_with("--design="):
			_design = s.substr(9)
		elif s.begins_with("--yaw="):
			_yaw = float(s.substr(6))
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.66, 0.70)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.82)
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.6
	world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -140, 0)
	fill.light_energy = 0.5
	world.add_child(fill)
	_cam = Camera3D.new()
	world.add_child(_cam)
	if not _design.is_empty():
		var b := TcBuilder.build_node(TcPresets.builtin(_design))
		world.add_child(b)
		var bb: AABB = TcDesign.solve(TcPresets.builtin(_design))["stats"]["bounds_mm"]
		var c := (bb.position + bb.size * 0.5) * 0.001
		var r := bb.size.length() * 0.001
		_cam.fov = 35
		var yr := deg_to_rad(_yaw)
		_cam.look_at_from_position(c + Vector3(sin(yr) * r * 1.15, r * 0.55, cos(yr) * r * 1.15), c, Vector3.UP)
		return
	var col := 0
	var row := 0
	var step := 0.0
	for s in _sizes:
		step = maxf(step, float(TcStandards.tube(str(s))["flange"]) * 0.001 * 3.6)
	var types: Array = TcParts.TYPE_ORDER.filter(func(t): return t != "vessel")
	var n := mini(types.size(), _per_row)
	for s in _sizes:
		col = 0
		for type in types:
			if col >= _per_row:
				col = 0
				row += 1
			var bpart := TcParts.build(type, str(s), {})
			var mi := MeshInstance3D.new()
			mi.mesh = TcBuilder.part_mesh(bpart)
			var bb: AABB = bpart["bounds"]
			var centre := (bb.position + bb.size * 0.5) * 0.001
			var turn := Basis(Vector3.UP, deg_to_rad(-60.0)) * Basis(Vector3.RIGHT, deg_to_rad(20.0))
			mi.transform = Transform3D(turn, Vector3(col * step, -row * step, 0) - turn * centre)
			world.add_child(mi)
			for p in bpart["ports"]:
				var m := MeshInstance3D.new()
				var cyl := CylinderMesh.new()
				var rr := float(TcStandards.tube(str(p["size"]))["r_flange"]) * 0.001 if str(p["kind"]) == "tc" else 0.008
				cyl.top_radius = rr * 0.35
				cyl.bottom_radius = rr * 0.35
				cyl.height = 0.002
				m.mesh = cyl
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.albedo_color = Color(0.2, 0.9, 1.0) if str(p["kind"]) == "tc" else Color(1.0, 0.85, 0.2)
				m.material_override = mat
				var pxf := TcBuilder.to_m(TcParts.port_xform(p))
				m.transform = Transform3D(Basis(pxf.basis.x, pxf.basis.z, -pxf.basis.y), pxf.origin + pxf.basis.z * 0.004)
				mi.add_child(m)
			col += 1
		row += 1
	var w := (n - 1) * step
	var h := (row - 1) * step
	var c2 := Vector3(w * 0.5, -h * 0.5, 0)
	_cam.fov = 40
	_cam.look_at_from_position(c2 + Vector3(0, step * 0.3, w * 0.62 + step), c2, Vector3.UP)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 8:
		root.get_texture().get_image().save_png(_out)
		print("tclab sheet: wrote ", _out)
		return true
	return false
