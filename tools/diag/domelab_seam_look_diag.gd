extends SceneTree
## Folded-plate seam close-ups (NOT a selftest): builds a DomeLab plate
## design and shoots, from INSIDE the shell, a valley seam, a ridge seam, a
## node where four or more plates meet and one where three meet, each from
## two sides. How the folded flanges are judged by eye; the numbers are
## pinned by domelab_selftest's _test_plate_seams.
## WINDOWED (it renders). Point APPDATA at a scratch folder; it writes only
## to --out.
##   Godot.exe --path . --windowed --resolution 1280x800 --script res://tools/diag/domelab_seam_look_diag.gd -- --dome-preset=helical_corten --out=<dir>
## --dist=<m> sets how far the camera stands off (default 0.45).
## --library=<id or name> shoots a design from the player's Dome Lab
## library (user://domelab_library.json) instead of a preset.

var _out := ""
var _dist := 0.45
var _cam: Camera3D = null
var _lamp: OmniLight3D = null
var _shots: Array = []
var _i := 0
var _frames := 0


func _initialize() -> void:
	var preset := "helical_corten"
	var lib := ""
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--dome-preset="):
			preset = s.substr(14)
		elif s.begins_with("--out="):
			_out = s.substr(6)
		elif s.begins_with("--library="):
			lib = s.substr(10)
		elif s.begins_with("--dist="):
			_dist = float(s.substr(7))
	if _out.is_empty():
		print("usage: --dome-preset=<id> --out=<dir>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var spec: Dictionary = {}
	if not lib.is_empty():
		for des in DomeLabPresets.load_library():
			if str(des.get("id", "")) == lib or str(des.get("name", "")) == lib:
				spec = DomeLabSpec.resolve(des["spec"])
	else:
		spec = DomeLabPresets.builtin(preset).get("spec", {})
	if spec.is_empty():
		print("no dome design ", lib if not lib.is_empty() else preset)
		quit(1)
		return
	var d := DomeLabDesign.solve(spec)
	var model := DomeLabBuilder.build_from_design(d, "Dome", {})
	var w := Node3D.new()
	get_root().add_child(w)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.7, 0.8)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.75, 0.78)
	e.ambient_light_energy = 0.55
	e.ssao_enabled = true
	env.environment = e
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.9
	w.add_child(sun)
	w.add_child(model)
	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.near = 0.01
	w.add_child(_cam)
	_lamp = OmniLight3D.new()
	_lamp.omni_range = 3.0
	_lamp.light_energy = 1.2
	w.add_child(_lamp)
	_plan(d)


## Pick the seams and nodes worth looking at.
func _plan(d: Dictionary) -> void:
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var fidx := DomeLabConnectors.face_index(geo)
	var fn: PackedVector3Array = fidx["normals"]
	var cuts: Dictionary = d["panels"].get("node_cuts", {})
	var valley := -1
	var ridge := -1
	var best_v := 0.0
	var best_r := 0.0
	var ymid := 0.0
	for v in verts:
		ymid += v.y
	ymid /= verts.size()
	for ei in (d["edges"] as Array).size():
		var ed: Dictionary = d["edges"][ei]
		if (ed["faces"] as Array).size() < 2:
			continue
		var b := float(ed["flange_bend"])
		var h := (ed["mid"] as Vector3).y
		# Steepest valley; a sharp ridge near mid-height.
		if b < 0.0 and -b > best_v:
			best_v = -b
			valley = ei
		if b > 0.0 and b - absf(h - ymid) * 0.05 > best_r:
			best_r = b - absf(h - ymid) * 0.05
			ridge = ei
	var normals := {}
	for fi in faces.size():
		for id in (faces[fi] as PackedInt32Array):
			normals[int(id)] = (normals.get(int(id), Vector3.ZERO) as Vector3) + fn[fi]
	var val := {}
	for f in faces:
		for id in (f as PackedInt32Array):
			val[int(id)] = int(val.get(int(id), 0)) + 1
	var node4 := -1
	var node3 := -1
	for key in cuts:
		var vid := int(str(key).split("|")[1])
		if node4 < 0 or absf(verts[vid].y - ymid) < absf(verts[node4].y - ymid):
			node4 = vid
	for vid in val:
		if int(val[vid]) == 3 and (node3 < 0 or absf(verts[vid].y - ymid) < absf(verts[node3].y - ymid)):
			# An interior vertex (all its edges are seams).
			node3 = vid
	for spec in [["valley", valley], ["ridge", ridge]]:
		var ei := int(spec[1])
		if ei < 0:
			continue
		var ed: Dictionary = d["edges"][ei]
		var n := (fn[int(ed["faces"][0])] + fn[int(ed["faces"][1])]).normalized()
		var dir: Vector3 = ed["dir"]
		var p: Vector3 = ed["mid"]
		print("seam-look: %s seam %d, half bend %.1f°" % [spec[0], ei, rad_to_deg(float(ed["flange_bend"]))])
		_shots.append([str(spec[0]) + "_a", p - n * _dist + dir * _dist * 0.6, p - n * 0.03, dir])
		_shots.append([str(spec[0]) + "_b", p - n * _dist - dir * _dist * 0.6 + n.cross(dir) * _dist * 0.4, p - n * 0.03, dir])
	for spec in [["node_4plus", node4], ["node_3", node3]]:
		var vid := int(spec[1])
		if vid < 0:
			continue
		var n := (normals[vid] as Vector3).normalized()
		var side := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var p := verts[vid]
		print("seam-look: %s at vertex %d (%d plates)" % [spec[0], vid, int(val[vid])])
		_shots.append([str(spec[0]) + "_a", p - n * _dist + side * _dist * 0.35, p - n * 0.04, n.cross(side)])
		_shots.append([str(spec[0]) + "_b", p - n * _dist * 0.8 - side * _dist * 0.45, p - n * 0.04, n.cross(side)])


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	if _i > 0 and _frames % 4 == 0:
		get_root().get_texture().get_image().save_png("%s/%s.png" % [_out, str(_shots[_i - 1][0])])
	if _frames % 4 != 0:
		return false
	if _i >= _shots.size():
		print("seam-look: wrote %d views to %s" % [_shots.size(), _out])
		quit(0)
		return true
	var s: Array = _shots[_i]
	var up: Vector3 = s[3]
	_cam.look_at_from_position(s[1], s[2], up)
	_lamp.position = s[1]
	_i += 1
	return false
