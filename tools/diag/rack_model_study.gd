extends SceneTree
## Study a structure model next to a pallet-rack design (NOT a selftest):
## renders the same eight views of either and prints what the geometry says
## about its architecture — overall size, the vertical posts' grid (x / z
## lines), the decks' heights (big flat surfaces), sloped surfaces, materials.
## WINDOWED (it renders). Point APPDATA at a scratch folder; it writes only to
## --out.
##   Godot.exe --path . --windowed --resolution 1280x800 --script res://tools/diag/rack_model_study.gd -- --glb=<path> --out=<dir>
##   Godot.exe --path . --windowed --resolution 1280x800 --script res://tools/diag/rack_model_study.gd -- --rack-preset=<id> --out=<dir>
## --yaw=<deg> turns the model first (to line a model's faces up with a rack's).
## --dome-preset=<id> studies a DomeLabPresets design the same way (the
## helical corten home against its SketchUp source, 2026-10-26).
## --toroid-preset=<id> a ToroidLabPresets design (the reference toroid
## against "Overview Toroid structure.glb").

var _model: Node3D = null
var _out := ""
var _frames := 0
var _cam: Camera3D = null
var _bb := AABB()
var _shots: Array = []
var _shot_i := 0
var _yaw := 0.0
var _dist_k := 1.0


func _initialize() -> void:
	var glb := ""
	var preset := ""
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--glb="):
			glb = s.substr(6)
		elif s.begins_with("--rack-preset="):
			preset = s.substr(14)
		elif s.begins_with("--dome-preset="):
			preset = "dome:" + s.substr(14)
		elif s.begins_with("--toroid-preset="):
			preset = "toroid:" + s.substr(16)
		elif s.begins_with("--out="):
			_out = s.substr(6)
		elif s.begins_with("--yaw="):
			_yaw = float(s.substr(6))
		elif s.begins_with("--dist="):
			_dist_k = float(s.substr(7))
	if _out.is_empty() or (glb.is_empty() and preset.is_empty()):
		print("usage: --glb=<path> | --rack-preset=<id>, --out=<dir>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	if not glb.is_empty():
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(glb, st) != OK:
			print("load failed")
			quit(1)
			return
		_model = doc.generate_scene(st) as Node3D
	elif preset.begins_with("dome:"):
		var dp := DomeLabPresets.builtin(preset.substr(5))
		if dp.is_empty():
			print("no dome preset ", preset)
			quit(1)
			return
		_model = DomeLabBuilder.build_node(dp["spec"])
	elif preset.begins_with("toroid:"):
		var tp := ToroidLabPresets.builtin(preset.substr(7))
		if tp.is_empty():
			print("no toroid preset ", preset)
			quit(1)
			return
		_model = ToroidLabBuilder.build_node(tp["spec"])
	else:
		var d := PalletRackBuilder.design_preset(preset)
		if d.is_empty():
			print("no preset ", preset)
			quit(1)
			return
		_model = PalletRackBuilder.build_node(d["spec"])
	_model.rotation_degrees.y = _yaw
	var w := Node3D.new()
	get_root().add_child(w)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.68, 0.74)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.75)
	e.ambient_light_energy = 0.7
	env.environment = e
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	w.add_child(sun)
	w.add_child(_model)
	_cam = Camera3D.new()
	_cam.far = 2000.0
	w.add_child(_cam)


func _meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).visible:
		out.append(n)
	for c in n.get_children():
		_meshes(c, out)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_analyse()
		return false
	if _frames < 6:
		return false
	if _shot_i > 0:
		var img := get_root().get_texture().get_image()
		img.save_png("%s/%s.png" % [_out, str(_shots[_shot_i - 1][0])])
	if _shot_i >= _shots.size():
		print("study: wrote %d views to %s" % [_shots.size(), _out])
		quit(0)
		return true
	var s: Array = _shots[_shot_i]
	_place(s[1], s[2], bool(s[3]))
	_shot_i += 1
	return false


func _place(yaw_deg: float, pitch_deg: float, ortho: bool) -> void:
	var c := _bb.get_center()
	var r := _bb.size.length() * 0.5
	var yaw := deg_to_rad(yaw_deg)
	var pit := deg_to_rad(pitch_deg)
	var dir := Vector3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit))
	if ortho:
		_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_cam.size = maxf(_bb.size.x, _bb.size.z) * 1.1 * _dist_k
	else:
		_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		_cam.fov = 40.0
	var dist := r / tan(deg_to_rad(20.0)) * 1.05 * _dist_k
	var up := Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD
	_cam.look_at_from_position(c + dir * dist, c, up)


func _analyse() -> void:
	var ms: Array = []
	_meshes(_model, ms)
	var first := true
	var posts: Array = []
	var flats: Array = []
	var slopes := {}
	var mats := {}
	var tri_area_h := {}
	for m in ms:
		var mi := m as MeshInstance3D
		var gb := mi.global_transform * mi.mesh.get_aabb()
		_bb = gb if first else _bb.merge(gb)
		first = false
		for si in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(si)
			var mn := (str(mat.resource_name) if mat != null else "-")
			mats[mn] = int(mats.get(mn, 0)) + 1
		var sz := gb.size
		if sz.y > 1.2 and sz.x < 0.2 and sz.z < 0.2:
			posts.append(gb.get_center())
		# Triangle normals: flat areas by height, sloped areas by tilt.
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var xf := mi.global_transform
			var n_tri := (idx.size() if not idx.is_empty() else v.size()) / 3
			for t in n_tri:
				var a := xf * v[idx[t * 3] if not idx.is_empty() else t * 3]
				var b := xf * v[idx[t * 3 + 1] if not idx.is_empty() else t * 3 + 1]
				var cc := xf * v[idx[t * 3 + 2] if not idx.is_empty() else t * 3 + 2]
				var nrm := (b - a).cross(cc - a)
				var area := nrm.length() * 0.5
				if area < 1e-4:
					continue
				nrm = nrm.normalized()
				if nrm.y > 0.98:
					var hk := snappedf((a.y + b.y + cc.y) / 3.0, 0.05)
					tri_area_h[hk] = float(tri_area_h.get(hk, 0.0)) + area
				elif nrm.y > 0.15 and nrm.y < 0.95:
					var tilt := int(round(rad_to_deg(acos(nrm.y)) / 5.0)) * 5
					var az := int(round(rad_to_deg(atan2(nrm.x, nrm.z)) / 45.0)) * 45
					var key := "%d° facing %d°" % [tilt, az]
					slopes[key] = float(slopes.get(key, 0.0)) + area
	print("study: %d meshes, bounds %s .. %s, size %s m" % [ms.size(), str(_bb.position.snapped(Vector3.ONE * 0.01)),
		str(_bb.end.snapped(Vector3.ONE * 0.01)), str(_bb.size.snapped(Vector3.ONE * 0.01))])
	print("study: materials ", mats)
	# Post grid: cluster x and z.
	var xs := _cluster(posts.map(func(p): return (p as Vector3).x), 0.25)
	var zs := _cluster(posts.map(func(p): return (p as Vector3).z), 0.25)
	print("study: %d vertical posts; x lines %s" % [posts.size(), str(xs)])
	print("study: z lines %s" % str(zs))
	var hs := tri_area_h.keys()
	hs.sort()
	var big: Array = []
	for h in hs:
		if float(tri_area_h[h]) > 2.0:
			big.append("%.2f m: %.0f m²" % [float(h), float(tri_area_h[h])])
	print("study: up-facing area by height: ", ", ".join(big))
	var sk := slopes.keys()
	sk.sort_custom(func(a, b): return float(slopes[a]) > float(slopes[b]))
	var sl: Array = []
	for k in sk.slice(0, 12):
		if float(slopes[k]) > 1.0:
			sl.append("%s: %.0f m²" % [k, float(slopes[k])])
	print("study: sloped areas: ", ", ".join(sl))
	var c := _bb.get_center()
	_shots = [["iso_ne", 45.0, 30.0, false], ["iso_se", 135.0, 30.0, false],
		["iso_sw", 225.0, 30.0, false], ["iso_nw", 315.0, 30.0, false],
		["front_s", 180.0, 5.0, false], ["side_e", 90.0, 5.0, false],
		["top", 0.0, 89.0, true], ["low_ne", 45.0, 12.0, false]]


## Values clustered within `tol`: "centre (count)" strings, sorted.
func _cluster(vals: Array, tol: float) -> Array:
	var v: Array = vals.duplicate()
	v.sort()
	var out: Array = []
	var cur: Array = []
	for x in v:
		if cur.is_empty() or float(x) - float(cur[-1]) <= tol:
			cur.append(x)
		else:
			out.append(cur)
			cur = [x]
	if not cur.is_empty():
		out.append(cur)
	var res: Array = []
	for g in out:
		var s := 0.0
		for x in g:
			s += float(x)
		res.append("%.2f(%d)" % [s / float(g.size()), g.size()])
	return res
