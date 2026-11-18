extends SceneTree

## Grass shader A/B (WINDOWED, not a selftest; point APPDATA at a scratch
## folder). A field of the shell grass (NEAR / MID / FAR tiers with the
## runtime's own visibility ranges) in an empty studio, drawn with the shader
## as shipped and with variants built from it at run time:
##   ship      grass.gdshader as it is (writes ALPHA: the transparent pass)
##   s04       + ALPHA_SCISSOR_THRESHOLD = 0.04 (the discard's own cut)
##   s50       + ALPHA_SCISSOR_THRESHOLD = 0.5  (the soft edge's middle)
## Each variant is shot from the same cameras (close, eye height, across the
## field) and its GPU time over 90 frames is printed, so the picture and the
## cost can be compared. PNGs to --out=<dir> (default user://grass_ab/).
##   Godot --path . --windowed --resolution 1280x720 --script res://tools/diag/grass_scissor_diag.gd -- --out=<dir> [--species=grass_field|grass_lawn] [--only=ship,s50]

var _out := "user://grass_ab"
var _species := "grass_field"
var _only: PackedStringArray = PackedStringArray()
var _cam: Camera3D
var _root: Node3D
var _batches: Array = []   # [MultiMeshInstance3D, tier]

const VARIANTS := {
	"ship": "",
	"s04": "ALPHA_SCISSOR_THRESHOLD = 0.04;",
	"s50": "ALPHA_SCISSOR_THRESHOLD = 0.5;",
	# Diagnostics: still the transparent pass, but no partial alpha.
	"a1": "ALPHA = 1.0;",
}

const SHOTS := [
	# name, camera position, look-at point
	["close", Vector3(0.0, 0.55, 2.0), Vector3(0.0, 0.15, -1.5)],
	["eye", Vector3(0.0, 1.7, 0.0), Vector3(0.0, 0.0, -14.0)],
	["across", Vector3(0.0, 1.7, 0.0), Vector3(0.0, 1.2, -120.0)],
	["above", Vector3(0.0, 9.0, 6.0), Vector3(0.0, 0.0, -20.0)],
]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--species="):
			_species = a.substr(10)
		elif a.begins_with("--only="):
			_only = a.substr(7).split(",", false)
	var abs_out := ProjectSettings.globalize_path(_out) if _out.begins_with("user://") else _out
	DirAccess.make_dir_recursive_absolute(abs_out)
	_out = abs_out
	_run.call_deferred()


func _studio() -> void:
	_root = Node3D.new()
	root.add_child(_root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.8
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = true
	env.environment = e
	_root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	_root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.30, 0.20)
	ground.material_override = gm
	_root.add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 1200.0
	_root.add_child(_cam)
	_cam.current = true


## The field: x -30..30 m, z +4..-200 m, one mat every `spacing` m, jittered
## by a hash so it does not read as a grid. Each tier gets its own batch with
## the runtime's visibility range, as VegetationRuntime builds them.
func _field() -> void:
	var tiers := [GrassBuilder.LodTier.NEAR, GrassBuilder.LodTier.MID, GrassBuilder.LodTier.FAR]
	var spacing := 0.42
	var xs: Array = []
	var x := -30.0
	while x <= 30.0:
		xs.append(x)
		x += spacing
	for tier in tiers:
		var range_v: Vector2 = GrassBuilder.visibility_range_for_tier(tier)
		var z0 := 4.0
		var z1 := -minf(range_v.y + 10.0, 230.0)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = GrassBuilder.mesh_for_lod(_species, {}, tier)
		var xfs: Array = []
		var z := z0
		var row := 0
		while z >= z1:
			for xv in xs:
				var h := hash(Vector2i(int(xv * 100.0), row))
				var jx := (float(h & 1023) / 1023.0 - 0.5) * spacing * 0.6
				var jz := (float((h >> 10) & 1023) / 1023.0 - 0.5) * spacing * 0.6
				var yaw := float((h >> 20) & 1023) / 1023.0 * TAU
				xfs.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(float(xv) + jx, 0.0, z + jz)))
			z -= spacing
			row += 1
		mm.instance_count = xfs.size()
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_begin = range_v.x
		mmi.visibility_range_end = range_v.y
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(mmi)
		_batches.append([mmi, tier])
		print("grassab: tier %d  %d instances  range %.0f-%.0f m" % [tier, xfs.size(), range_v.x, range_v.y])


func _variant_shader(code_line: String) -> Shader:
	var base: Shader = GrassBuilder.GRASS_SHADER
	if code_line.is_empty():
		return base
	var sh := Shader.new()
	var code := base.code
	var at := code.rfind("ALPHA = alpha;")
	if at < 0:
		push_error("grassab: no 'ALPHA = alpha;' in grass.gdshader")
		return base
	sh.code = code.insert(at + "ALPHA = alpha;".length(), "\n\t" + code_line)
	return sh


func _apply_variant(code_line: String) -> void:
	var sh := _variant_shader(code_line)
	for b in _batches:
		var mmi: MultiMeshInstance3D = b[0]
		var base_mat: ShaderMaterial = GrassBuilder.material_for_species(_species, {}, b[1])
		var mat := base_mat.duplicate() as ShaderMaterial
		mat.shader = sh
		mmi.material_override = mat


func _look(pos: Vector3, at: Vector3) -> void:
	_cam.global_position = pos
	_cam.look_at(at, Vector3.UP)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _gpu_ms(frames: int) -> float:
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	await _frames(4)
	var total := 0.0
	for _i in frames:
		await process_frame
		total += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return total / float(frames)


func _run() -> void:
	_studio()
	_field()
	await _frames(10)
	var lines: Array = []
	for vid in VARIANTS:
		if not _only.is_empty() and not _only.has(vid):
			continue
		_apply_variant(VARIANTS[vid])
		await _frames(30)
		for shot in SHOTS:
			_look(shot[1], shot[2])
			await _frames(20)
			var ms: float = await _gpu_ms(90)
			var img := root.get_texture().get_image()
			var path := _out.path_join("%s_%s_%s.png" % [_species, shot[0], vid])
			img.save_png(path)
			var line := "grassab: %-6s %-7s gpu %.2f ms" % [vid, shot[0], ms]
			print(line)
			lines.append(line)
	var f := FileAccess.open(_out.path_join("grass_ab_%s.txt" % _species), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("grassab: DONE -> %s" % _out)
	quit()
