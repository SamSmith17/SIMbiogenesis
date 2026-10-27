extends SceneTree
## Every mesh of a GLB as one JSON row (with its radial and height range
## about the Y axis) (NOT a selftest): name, the chain of
## ancestor names, material, global AABB, and the principal axis + extent of
## its world-space vertices — what you need to read a frame's tubes, rings
## and connectors off a model. Run headless:
##   Godot --headless --path . --script tools/diag/glb_mesh_table_diag.gd -- --glb=<path> --out=<json>

var _root: Node = null
var _out := ""
var _verts_mat := ""  # --verts-mat=<substring>: also store those meshes' vertices


func _initialize() -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--glb="):
			path = str(a).substr(6)
		elif str(a).begins_with("--out="):
			_out = str(a).substr(6)
		elif str(a).begins_with("--verts-mat="):
			_verts_mat = str(a).substr(12)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		print("load failed")
		quit(1)
		return
	_root = doc.generate_scene(st)
	get_root().add_child(_root)


func _process(_d: float) -> bool:
	if _root == null:
		return true
	var rows: Array = []
	for m in _root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var chain: Array = []
		var p: Node = mi.get_parent()
		while p != null and p != _root:
			chain.push_front(str(p.name))
			p = p.get_parent()
		var xf := mi.global_transform
		var mat := mi.get_active_material(0)
		var pts := PackedVector3Array()
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var step := maxi(1, v.size() / 400)
			for i in range(0, v.size(), step):
				pts.append(xf * v[i])
		var c := Vector3.ZERO
		for q in pts:
			c += q
		c /= maxf(1.0, float(pts.size()))
		var cov := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		var m00 := 0.0; var m01 := 0.0; var m02 := 0.0; var m11 := 0.0; var m12 := 0.0; var m22 := 0.0
		for q in pts:
			var d := q - c
			m00 += d.x * d.x; m01 += d.x * d.y; m02 += d.x * d.z
			m11 += d.y * d.y; m12 += d.y * d.z; m22 += d.z * d.z
		# power iteration for the principal axis
		var ax := Vector3(1, 0.3, 0.2).normalized()
		for _i in 30:
			ax = Vector3(m00 * ax.x + m01 * ax.y + m02 * ax.z,
				m01 * ax.x + m11 * ax.y + m12 * ax.z,
				m02 * ax.x + m12 * ax.y + m22 * ax.z)
			if ax.length() < 1e-12:
				ax = Vector3.UP
				break
			ax = ax.normalized()
		var r_lo := INF; var r_hi := 0.0; var y_lo := INF; var y_hi := -INF
		for q in pts:
			var rr := Vector2(q.x, q.z).length()
			r_lo = minf(r_lo, rr); r_hi = maxf(r_hi, rr)
			y_lo = minf(y_lo, q.y); y_hi = maxf(y_hi, q.y)
		var lo := INF; var hi := -INF; var rmax := 0.0
		for q in pts:
			var t := (q - c).dot(ax)
			lo = minf(lo, t); hi = maxf(hi, t)
			rmax = maxf(rmax, ((q - c) - ax * t).length())
		var a := xf * mi.get_aabb()
		var vlist: Array = []
		if not _verts_mat.is_empty() and mat != null and str(mat.resource_name).contains(_verts_mat):
			for q in pts:
				vlist.append([snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001)])
		rows.append({"name": str(mi.name), "chain": chain, "v": vlist,
			"mat": (str(mat.resource_name) if mat != null else ""),
			"verts": pts.size(),
			"aabb": [a.position.x, a.position.y, a.position.z, a.size.x, a.size.y, a.size.z],
			"c": [c.x, c.y, c.z], "ax": [ax.x, ax.y, ax.z], "len": hi - lo, "rad": rmax,
			"r_rng": [r_lo, r_hi], "y_rng": [y_lo, y_hi]})
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(rows))
	f.close()
	print("wrote ", rows.size(), " rows to ", _out)
	quit(0)
	return true
