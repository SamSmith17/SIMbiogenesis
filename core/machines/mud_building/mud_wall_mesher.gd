class_name MudWallMesher
extends RefCounted

## Builds a Godot Y-up metres ArrayMesh of SOLID extruded layers by sweeping a
## nozzle cross-section (line_width × layer_height) along continuous extruding
## runs — a true ribbon loft, not a chain of separate boxes. Also writes Z-up mm STL.

## Cap stations along all runs (keeps preview / STL responsive).
const MAX_STATIONS := 28000
## Target arc length between stations on gentle curves (mm).
const STEP_MM := 55.0


static func build_mesh(spec: MudBuildingSpec) -> ArrayMesh:
	var parse := MudWallSlicer.slice(spec, {"decimate": false})
	if not bool(parse.get("ok", false)):
		return null
	return build_mesh_from_parse(parse)


## Solid bead mesh from an already-sliced path (preview / reveal / place).
static func build_mesh_from_parse(parse: Dictionary) -> ArrayMesh:
	var pts: PackedVector3Array = parse.get("points", PackedVector3Array())
	var ext: PackedInt32Array = parse.get("extruding", PackedInt32Array())
	if pts.size() < 2:
		return null
	var line_w_mm := maxf(float(parse.get("line_width_mm", 76.2)), 1.0)
	var layer_h_mm := maxf(float(parse.get("layer_height_mm", 50.0)), 1.0)
	var half_w := line_w_mm * 0.001 * 0.5
	var half_h := layer_h_mm * 0.001 * 0.5

	var bmin := pts[0]
	var bmax := pts[0]
	for p: Vector3 in pts:
		bmin = Vector3(minf(bmin.x, p.x), minf(bmin.y, p.y), minf(bmin.z, p.z))
		bmax = Vector3(maxf(bmax.x, p.x), maxf(bmax.y, p.y), maxf(bmax.z, p.z))
	var cx := (bmin.x + bmax.x) * 0.5
	var cy := (bmin.y + bmax.y) * 0.5
	var z_base := bmin.z - layer_h_mm * 0.5

	# Contiguous extruding runs (break on travel / non-extrude).
	var runs: Array = _collect_runs(pts, ext)
	if runs.is_empty():
		return null

	# Adaptive step so total stations stay under budget (never skip — that makes bricks).
	var step_mm := clampf(maxf(STEP_MM, line_w_mm * 0.55), 25.0, 120.0)
	var est := 0
	for run: Variant in runs:
		var rpts: PackedVector3Array = run
		est += maxi(int(ceil(_run_length_mm(rpts) / step_mm)) + 1, 2)
	if est > MAX_STATIONS:
		step_mm *= float(est) / float(MAX_STATIONS)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.48, 0.34)
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Per-layer albedo banding (set in vertex COLOR) so layer lines read.
	mat.vertex_color_use_as_albedo = true

	for run: Variant in runs:
		var rpts: PackedVector3Array = run
		var stations := _resample_run(rpts, step_mm)
		if stations.size() < 2:
			continue
		_sweep_run(st, stations, cx, cy, z_base, half_w, half_h, layer_h_mm)

	# Normals are authored per profile vertex (rounded bead) — don't overwrite.
	var mesh := st.commit()
	if mesh != null and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, mat)
	return mesh


static func write_stl(spec: MudBuildingSpec, path: String = "") -> String:
	var mesh := build_mesh(spec)
	if mesh == null:
		return ""
	var dst := path
	if dst.is_empty():
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path("user://machines/prints"))
		dst = "user://machines/prints/mud_building_%d.stl" % Time.get_unix_time_from_system()
	if not _write_mesh_as_stl_mm(mesh, dst):
		return ""
	return dst


static func _collect_runs(pts: PackedVector3Array, ext: PackedInt32Array) -> Array:
	var runs: Array = []
	var cur := PackedVector3Array()
	for i in range(1, pts.size()):
		var is_ext := i < ext.size() and ext[i] != 0
		if is_ext:
			if cur.is_empty():
				cur.append(pts[i - 1])
			cur.append(pts[i])
		elif not cur.is_empty():
			if cur.size() >= 2:
				runs.append(cur)
			cur = PackedVector3Array()
	if cur.size() >= 2:
		runs.append(cur)
	return runs


static func _run_length_mm(pts: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	return total


## Arc-length resample a run; keeps endpoints; denser on sharp turns.
static func _resample_run(pts: PackedVector3Array, step_mm: float) -> PackedVector3Array:
	var n := pts.size()
	if n < 2:
		return pts.duplicate()
	var lengths: PackedFloat32Array = PackedFloat32Array()
	lengths.resize(n)
	lengths[0] = 0.0
	for i in range(1, n):
		lengths[i] = lengths[i - 1] + pts[i].distance_to(pts[i - 1])
	var total := lengths[n - 1]
	if total < 1e-3:
		return PackedVector3Array([pts[0], pts[n - 1]])
	var spacing := maxf(step_mm, 8.0)
	var count := clampi(int(ceil(total / spacing)) + 1, 2, 8192)
	var out := PackedVector3Array()
	out.resize(count)
	var seg := 1
	for s in count:
		var target := total * float(s) / float(count - 1)
		while seg < n - 1 and lengths[seg] < target:
			seg += 1
		var span := lengths[seg] - lengths[seg - 1]
		var f := 0.0 if span < 1e-6 else (target - lengths[seg - 1]) / span
		out[s] = pts[seg - 1].lerp(pts[seg], clampf(f, 0.0, 1.0))
	return out


## Rounded elliptical bead (line_width × layer_height) swept along the stations —
## reads as stacked mud beads with grooved layer lines, not blocky bricks.
const PROFILE_SIDES := 8


static func _sweep_run(st: SurfaceTool, stations_mm: PackedVector3Array,
		cx: float, cy: float, z_base: float, half_w: float, half_h: float,
		layer_h_mm: float) -> void:
	var n := stations_mm.size()
	if n < 2:
		return
	var centers := PackedVector3Array()
	centers.resize(n)
	for i in n:
		centers[i] = _to_world(stations_mm[i], cx, cy, z_base)

	var rights := PackedVector3Array()
	rights.resize(n)
	var ups := PackedVector3Array()
	ups.resize(n)
	var right := Vector3(1, 0, 0)
	for i in n:
		var fwd: Vector3
		if i == 0:
			fwd = centers[1] - centers[0]
		elif i == n - 1:
			fwd = centers[n - 1] - centers[n - 2]
		else:
			fwd = centers[i + 1] - centers[i - 1]
		if fwd.length_squared() < 1e-12:
			fwd = Vector3(1, 0, 0)
		else:
			fwd = fwd.normalized()
		var up := Vector3.UP
		var r := up.cross(fwd)
		if r.length_squared() < 1e-8:
			r = right
		else:
			r = r.normalized()
			# Parallel-transport: keep twist continuous.
			if right.dot(r) < 0.0:
				r = -r
			right = r
		# Re-orthogonalize up so the bead stays flat to the bed.
		up = fwd.cross(r).normalized()
		if up.y < 0.0:
			up = -up
			r = -r
			right = r
		rights[i] = r
		ups[i] = up

	var lh := maxf(layer_h_mm, 1.0)
	var inv_w := 1.0 / maxf(half_w, 1e-5)
	var inv_h := 1.0 / maxf(half_h, 1e-5)
	# Precompute the profile (cos/sin around an ellipse in the right/up frame).
	var pc := PackedFloat32Array()
	var ps := PackedFloat32Array()
	pc.resize(PROFILE_SIDES)
	ps.resize(PROFILE_SIDES)
	for j in PROFILE_SIDES:
		var a := TAU * float(j) / float(PROFILE_SIDES)
		pc[j] = cos(a)
		ps[j] = sin(a)

	# Per-station rings of PROFILE_SIDES points (+normals) and a layer-band color.
	var ring_pos: Array = []
	var ring_nrm: Array = []
	var bands := PackedColorArray()
	bands.resize(n)
	for i in n:
		var c := centers[i]
		var r := rights[i]
		var u := ups[i]
		var pos := PackedVector3Array()
		var nrm := PackedVector3Array()
		pos.resize(PROFILE_SIDES)
		nrm.resize(PROFILE_SIDES)
		for j in PROFILE_SIDES:
			pos[j] = c + r * (half_w * pc[j]) + u * (half_h * ps[j])
			var nd := r * (pc[j] * inv_w) + u * (ps[j] * inv_h)
			nrm[j] = nd.normalized() if nd.length_squared() > 1e-12 else u
		ring_pos.append(pos)
		ring_nrm.append(nrm)
		var li := int(floor(stations_mm[i].z / lh))
		var shade := 1.0 if (li % 2 == 0) else 0.9
		bands[i] = Color(shade, shade, shade)

	# Side quads around the tube between consecutive rings.
	for i in range(n - 1):
		var p0: PackedVector3Array = ring_pos[i]
		var p1: PackedVector3Array = ring_pos[i + 1]
		var n0: PackedVector3Array = ring_nrm[i]
		var n1: PackedVector3Array = ring_nrm[i + 1]
		var c0 := bands[i]
		var c1 := bands[i + 1]
		for j in PROFILE_SIDES:
			var k := (j + 1) % PROFILE_SIDES
			_tri(st, p0[j], p0[k], p1[k], n0[j], n0[k], n1[k], c0, c0, c1)
			_tri(st, p0[j], p1[k], p1[j], n0[j], n1[k], n1[j], c0, c1, c1)

	# Fan caps at the run ends.
	var fwd0 := (centers[1] - centers[0]).normalized()
	var fwd1 := (centers[n - 1] - centers[n - 2]).normalized()
	var p_first: PackedVector3Array = ring_pos[0]
	var p_last: PackedVector3Array = ring_pos[n - 1]
	for j in PROFILE_SIDES:
		var k := (j + 1) % PROFILE_SIDES
		_tri(st, centers[0], p_first[k], p_first[j], -fwd0, -fwd0, -fwd0,
			bands[0], bands[0], bands[0])
		_tri(st, centers[n - 1], p_last[j], p_last[k], fwd1, fwd1, fwd1,
			bands[n - 1], bands[n - 1], bands[n - 1])


## Machine mm (X, Y bed, Z up) → Godot metres Y-up, centred, base seated.
static func _to_world(p: Vector3, cx: float, cy: float, z_base: float) -> Vector3:
	return Vector3((p.x - cx) * 0.001, (p.z - z_base) * 0.001, -(p.y - cy) * 0.001)


## Triangle with an authored normal + color per vertex (rounded bead sweep).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		na: Vector3, nb: Vector3, nc: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	st.set_normal(na)
	st.set_color(ca)
	st.add_vertex(a)
	st.set_normal(nb)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(nc)
	st.set_color(cc)
	st.add_vertex(c)


static func _write_mesh_as_stl_mm(mesh: ArrayMesh, path: String) -> bool:
	if mesh == null or mesh.get_surface_count() < 1:
		return false
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.size() < 3:
		return false
	var tri_count := int(verts.size() / 3)
	var buf := PackedByteArray()
	buf.resize(84 + tri_count * 50)
	buf.encode_u32(80, tri_count)
	var off := 84
	for t in tri_count:
		var i := t * 3
		var a: Vector3 = verts[i]
		var b: Vector3 = verts[i + 1]
		var c: Vector3 = verts[i + 2]
		var pa := Vector3(a.x, -a.z, a.y) * 1000.0
		var pb := Vector3(b.x, -b.z, b.y) * 1000.0
		var pc := Vector3(c.x, -c.z, c.y) * 1000.0
		var n := (pb - pa).cross(pc - pa)
		if n.length_squared() > 1e-12:
			n = n.normalized()
		else:
			n = Vector3(0, 0, 1)
		buf.encode_float(off, n.x)
		buf.encode_float(off + 4, n.y)
		buf.encode_float(off + 8, n.z)
		off += 12
		for p: Vector3 in [pa, pb, pc]:
			buf.encode_float(off, p.x)
			buf.encode_float(off + 4, p.y)
			buf.encode_float(off + 8, p.z)
			off += 12
		buf.encode_u16(off, 0)
		off += 2
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(buf)
	f.close()
	return true
