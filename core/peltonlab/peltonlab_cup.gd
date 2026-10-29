class_name PeltonLabCup
extends RefCounted

## The one Pelton cup: the shipped STL turned into a mesh in the CUP FRAME,
## and the maths that seats a cup on a wheel. Pure static (the mesh is read
## once and cached).
##
## Cup frame (metres, the STL at its own size): the origin is the cup's PITCH
## point — on the splitter plane, half way through the cup's depth, at the
## widest station (PeltonLabParts.CUP pitch_z) — and
##   +X  across the cup (the STL's x, along the wheel's shaft)
##   +Y  out of the cup's open face (toward the oncoming jet)
##   +Z  toward the root tab (the STL's z, radially INWARD on a wheel)
## a translation and the mm → m scale of the STL's own frame, so the file's
## winding survives (an STL is counter-clockwise from outside; Godot's front
## face is clockwise, so every triangle is emitted reversed).
##
## Runner frame (what the wheel is built in): the shaft is +Y, the cups lie
## in the XZ plane, cup k sits at angle θ with its radial r̂ = (cos θ, 0, sin θ),
## and the wheel turns positively about +Y, so a cup moves along
## t = ŷ × r̂ = (sin θ, 0, −cos θ). The jet travels along +t into the cup's
## open face, which therefore faces −t.

const _SMOOTH_COS := 0.64   ## cos 50°: faces closer than this share a normal

static var _mesh: ArrayMesh = null
static var _mesh_from_file := false


## The cup mesh (cup frame, native size). Falls back to a drawn cup when the
## STL is missing (a fresh clone without the asset).
static func mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var tris := _read_stl(PeltonLabParts.CUP_STL)
	if tris.size() >= 9:
		_mesh = _mesh_from_tris(tris)
		_mesh_from_file = true
	else:
		_mesh = _fallback_mesh()
		_mesh_from_file = false
	return _mesh


static func from_file() -> bool:
	mesh()
	return _mesh_from_file


## The cup frame's origin in the STL's own coordinates (mm).
static func origin_mm() -> Vector3:
	var c := PeltonLabParts.CUP
	return Vector3(float(c["splitter_x"]), (float(c["depth_y0"]) + float(c["depth_y1"])) * 0.5,
		float(c["pitch_z"]))


## STL mm → cup frame m.
static func to_cup(p_mm: Vector3) -> Vector3:
	return (p_mm - origin_mm()) * 0.001


## Binary (or ASCII) STL → flat array of vertices in the CUP frame, already in
## Godot's winding (a, c, b per facet).
static func _read_stl(path: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 84:
		return out
	var n := bytes.decode_u32(80)
	if 84 + n * 50 == bytes.size():
		out.resize(n * 3)
		for i in n:
			var o := 84 + i * 50 + 12
			var a := to_cup(Vector3(bytes.decode_float(o), bytes.decode_float(o + 4), bytes.decode_float(o + 8)))
			var b := to_cup(Vector3(bytes.decode_float(o + 12), bytes.decode_float(o + 16), bytes.decode_float(o + 20)))
			var c := to_cup(Vector3(bytes.decode_float(o + 24), bytes.decode_float(o + 28), bytes.decode_float(o + 32)))
			out[i * 3] = a
			out[i * 3 + 1] = c
			out[i * 3 + 2] = b
		return out
	# ASCII: "vertex x y z" lines in threes.
	var verts := PackedVector3Array()
	for line in bytes.get_string_from_utf8().split("\n"):
		var t := line.strip_edges()
		if t.begins_with("vertex"):
			var p := t.split(" ", false)
			if p.size() >= 4:
				verts.append(to_cup(Vector3(float(p[1]), float(p[2]), float(p[3]))))
	for i in range(0, verts.size() - 2, 3):
		out.append(verts[i])
		out.append(verts[i + 2])
		out.append(verts[i + 1])
	return out


## Triangles → an indexed mesh with normals smoothed across gentle edges and
## kept sharp across creases (the rim, the splitter, the tab's faces).
static func _mesh_from_tris(tris: PackedVector3Array) -> ArrayMesh:
	var nt := tris.size() / 3
	var fn := PackedVector3Array()
	fn.resize(nt)
	var fa := PackedFloat32Array()
	fa.resize(nt)
	var at := {}   # welded position key -> Array of face indices
	for f in nt:
		var a := tris[f * 3]
		var b := tris[f * 3 + 1]
		var c := tris[f * 3 + 2]
		# Godot winding: the outward normal is (c − a) × (b − a).
		var cr := (c - a).cross(b - a)
		fa[f] = cr.length()
		fn[f] = cr.normalized() if cr.length() > 1e-14 else Vector3.UP
		for v in [a, b, c]:
			var key := _key(v)
			if not at.has(key):
				at[key] = []
			(at[key] as Array).append(f)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(tris.size())
	norms.resize(tris.size())
	for f in nt:
		for k in 3:
			var p := tris[f * 3 + k]
			var sum := Vector3.ZERO
			for g in at[_key(p)]:
				if fn[g].dot(fn[f]) >= _SMOOTH_COS:
					sum += fn[g] * fa[g]
			verts[f * 3 + k] = p
			norms[f * 3 + k] = sum.normalized() if sum.length() > 1e-14 else fn[f]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func _key(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * 1e6), roundi(v.y * 1e6), roundi(v.z * 1e6))


## A drawn cup the size of the STL's: two half-ellipsoid bowls either side of
## the splitter and the root tab.
static func _fallback_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := PeltonLabParts.CUP
	var half_w := float(c["width_mm"]) * 0.25 * 0.001
	var depth := (float(c["depth_y1"]) - float(c["depth_y0"])) * 0.001
	var z0 := (float(c["tip_z"]) - float(c["pitch_z"])) * 0.001
	var z1 := (float(c["bowl_root_z"]) - float(c["pitch_z"])) * 0.001
	var zc := (z0 + z1) * 0.5
	var lz := (z1 - z0) * 0.5
	for side in [-1.0, 1.0]:
		var cx: float = side * half_w
		var rings := 8
		var segs := 16
		for i in rings:
			for j in segs:
				var p := []
				for di in [0, 1]:
					for dj in [0, 1]:
						var th := PI * 0.5 * float(i + di) / float(rings)   # 0 = rim, π/2 = bottom
						var ph := TAU * float(j + dj) / float(segs)
						p.append(Vector3(cx + cos(ph) * cos(th) * half_w, depth * 0.5 - sin(th) * depth,
							zc + sin(ph) * cos(th) * lz))
				st.set_normal(Vector3.UP)
				st.add_vertex(p[0])
				st.add_vertex(p[1])
				st.add_vertex(p[3])
				st.add_vertex(p[0])
				st.add_vertex(p[3])
				st.add_vertex(p[2])
	var tab_w := (float(c["tab_x1"]) - float(c["tab_x0"])) * 0.001
	GantryLabDetail.box(st, Vector3(0.0, -depth * 0.2, (z1 + (float(c["root_z"]) - float(c["pitch_z"])) * 0.001) * 0.5),
		Vector3(tab_w, depth * 0.5, (float(c["root_z"]) - float(c["bowl_root_z"])) * 0.001))
	st.generate_normals()
	return st.commit()


# ---------------------------------------------------------------------------
# Seating cups on a wheel
# ---------------------------------------------------------------------------

## The cup's radial r̂ and motion direction t at wheel angle θ (runner frame).
static func radial(theta: float) -> Vector3:
	return Vector3(cos(theta), 0.0, sin(theta))


static func tangent(theta: float) -> Vector3:
	return Vector3(sin(theta), 0.0, -cos(theta))


## Cup k's transform in the runner frame: scale k (cup_width / STL width),
## the pitch point on the pitch circle, the open face toward −t, the root tab
## inward, turned `tilt_deg` about its width axis. The cup is symmetric about
## its splitter, so its width axis runs along −Y to keep the frame proper
## (a mirror would flip every triangle's facing).
static func cup_transform(theta: float, pitch_r_m: float, k: float, tilt_deg: float = 0.0) -> Transform3D:
	var r := radial(theta)
	var t := tangent(theta)
	var b := Basis(Vector3(0.0, -1.0, 0.0), -t, -r)
	if absf(tilt_deg) > 1e-4:
		b = b * Basis(Vector3.RIGHT, deg_to_rad(tilt_deg))
	return Transform3D(b.scaled_local(Vector3.ONE * k), r * pitch_r_m)


## Wheel radius (mm) of a station at cup z (mm, STL frame) for a wheel whose
## pitch radius is pitch_r_mm and whose cups are scaled k.
static func radius_at(z_mm: float, pitch_r_mm: float, k: float) -> float:
	return pitch_r_mm + (float(PeltonLabParts.CUP["pitch_z"]) - z_mm) * k


## The tab's depth (tangential thickness, mm at native size) at cup z — the
## wedge from 24.3 mm where it leaves the bowl to 10.6 mm at the root.
static func tab_depth_mm(z_mm: float) -> float:
	var c := PeltonLabParts.CUP
	var z0 := float(c["bowl_root_z"])
	var z1 := float(c["root_z"])
	var u := clampf((z_mm - z0) / (z1 - z0), 0.0, 1.0)
	var top := lerpf(float(c["tab_y_top_bowl"]), float(c["tab_y_top_root"]), u)
	return top - float(c["depth_y0"])


## Where the tab's bolts go, in the CUP frame (native metres): the middle of
## the tab's depth at each bolt station, on the splitter plane.
static func bolt_points(count: int) -> Array:
	var out: Array = []
	var zs: Array = PeltonLabParts.CUP_BOLT_Z_TWO if count >= 2 else PeltonLabParts.CUP_BOLT_Z_ONE
	var y0 := float(PeltonLabParts.CUP["depth_y0"])
	for z in zs:
		var y := y0 + tab_depth_mm(float(z)) * 0.5
		out.append(to_cup(Vector3(float(PeltonLabParts.CUP["splitter_x"]), y, float(z))))
	return out


## Cup mass (kg) at scale k.
static func mass_kg(k: float, material_id: String) -> float:
	var v := float(PeltonLabParts.CUP["volume_mm3"]) * 1e-9 * k * k * k
	return v * float(PeltonLabParts.cup_material(material_id)["density"])
