class_name GeodesicDomeBuilder
extends RefCounted

## Assembles a grounded Class-I 2V geodesic dome from the recycled-plastic hub
## + strut STLs (see DomeParts). Used when the player crafts the dome recipe —
## the resulting Node3D is ghost-placed via PlacedPropService like any structure.

const MODEL_ID := "geodesic_dome"
const DEFAULT_RADIUS_M := DomeParts.TARGET_RADIUS_M


static func build_node(spec: Dictionary = {}) -> Node3D:
	var radius := maxf(float(spec.get("radius_m", DEFAULT_RADIUS_M)), 1.5)
	var root := Node3D.new()
	root.name = "GeodesicDome"

	var geom := _build_2v_geometry(radius)
	var verts: PackedVector3Array = geom["verts"]
	var edges: Array = geom["edges"]  # each {a, b, kind, len}
	var valence: PackedInt32Array = geom["valence"]

	var hub4 := StlLoader.build_mesh(DomeParts.STL[DomeParts.PART_HUB_4])
	var hub5 := StlLoader.build_mesh(DomeParts.STL[DomeParts.PART_HUB_5])
	var hub6 := StlLoader.build_mesh(DomeParts.STL[DomeParts.PART_HUB_6])
	var strut_a := StlLoader.build_mesh(DomeParts.STL[DomeParts.PART_STRUT_A])
	var strut_b := StlLoader.build_mesh(DomeParts.STL[DomeParts.PART_STRUT_B])

	var hub_mat := _plastic_mat(Color(0.22, 0.24, 0.28))
	var strut_mat := _plastic_mat(Color(0.55, 0.72, 0.62))
	# Ghost highlight while placing — slightly emissive translucent tint.
	if bool(spec.get("ghost_highlight", false)):
		hub_mat = _ghost_mat(Color(0.35, 0.85, 1.0, 0.45))
		strut_mat = _ghost_mat(Color(0.45, 0.95, 0.75, 0.55))

	var hubs := Node3D.new()
	hubs.name = "Hubs"
	root.add_child(hubs)
	for i in verts.size():
		var mesh: ArrayMesh = hub6
		match int(valence[i]):
			4:
				mesh = hub4 if hub4 != null else hub6
			5:
				mesh = hub5 if hub5 != null else hub6
			_:
				mesh = hub6 if hub6 != null else hub5
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Hub_%d" % i
		mi.mesh = mesh
		mi.material_override = hub_mat
		var p := verts[i]
		mi.transform = _hub_transform(p, radius)
		hubs.add_child(mi)

	var struts := Node3D.new()
	struts.name = "Struts"
	root.add_child(struts)
	var si := 0
	for e: Dictionary in edges:
		var kind := str(e.get("kind", "A"))
		var mesh2: ArrayMesh = strut_a if kind == "A" else strut_b
		if mesh2 == null:
			mesh2 = strut_a if strut_a != null else strut_b
		if mesh2 == null:
			continue
		var ia := int(e.get("a", 0))
		var ib := int(e.get("b", 0))
		var mi2 := MeshInstance3D.new()
		mi2.name = "Strut_%s_%d" % [kind, si]
		mi2.mesh = mesh2
		mi2.material_override = strut_mat
		mi2.transform = _strut_transform(verts[ia], verts[ib], mesh2)
		struts.add_child(mi2)
		si += 1

	# Soft translucent shell so the dome reads as an enclosure in ghost/place.
	var shell := MeshInstance3D.new()
	shell.name = "ShellHint"
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.is_hemisphere = true
	sphere.radial_segments = 24
	sphere.rings = 12
	shell.mesh = sphere
	var shell_mat := StandardMaterial3D.new()
	shell_mat.albedo_color = Color(0.55, 0.78, 0.72, 0.12)
	shell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shell_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	shell_mat.roughness = 0.55
	shell.material_override = shell_mat
	root.add_child(shell)

	return root


static func _plastic_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.55
	m.metallic = 0.05
	return m


static func _ghost_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true
	m.emission = Color(col.r, col.g, col.b)
	m.emission_energy_multiplier = 0.55
	m.roughness = 0.4
	return m


## Orient hub so local +Y points along the outward radial (dome normal),
## scaled so the printed STL plate matches the standing-dome chord size.
static func _hub_transform(p: Vector3, radius: float) -> Transform3D:
	var n := p.normalized() if p.length_squared() > 1e-8 else Vector3.UP
	var s := DomeParts.assembly_scale()
	var basis := _basis_from_y(n).scaled(Vector3(s, s, s))
	# Seat slightly outside the sphere so hubs sit on the strut ends.
	var origin := n * (radius + 0.02)
	return Transform3D(basis, origin)


## Lay a strut mesh from pa→pb. After StlLoader (Z-up mm → Y-up m) the long
## axis is local +X; stretch that to the geodesic chord and scale the
## cross-section with assembly_scale so hubs and struts match.
static func _strut_transform(pa: Vector3, pb: Vector3, mesh: ArrayMesh) -> Transform3D:
	var mid := (pa + pb) * 0.5
	var dir := pb - pa
	var length := dir.length()
	if length < 1e-6:
		return Transform3D(Basis.IDENTITY, mid)
	dir /= length
	var aabb := mesh.get_aabb()
	var native := maxf(aabb.size.x, 0.001)
	var sx := length / native
	var cross := DomeParts.assembly_scale()
	var basis := _basis_from_x(dir).scaled(Vector3(sx, cross, cross))
	return Transform3D(basis, mid)


## Offline counts for selftests / BOM validation.
static func geometry_counts(radius: float = DEFAULT_RADIUS_M) -> Dictionary:
	var geom := _build_2v_geometry(radius)
	var valence: PackedInt32Array = geom["valence"]
	var edges: Array = geom["edges"]
	var n4 := 0
	var n5 := 0
	var n6 := 0
	var other := 0
	for i in valence.size():
		match int(valence[i]):
			4:
				n4 += 1
			5:
				n5 += 1
			6:
				n6 += 1
			_:
				other += 1
	var na := 0
	var nb := 0
	for e: Dictionary in edges:
		if str(e.get("kind", "")) == "A":
			na += 1
		else:
			nb += 1
	return {
		"hubs": valence.size(), "hub4": n4, "hub5": n5, "hub6": n6, "hub_other": other,
		"struts": edges.size(), "strut_a": na, "strut_b": nb,
		"height_m": radius, "radius_m": radius,
	}


static func _basis_from_y(y_axis: Vector3) -> Basis:
	var y := y_axis.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-8:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


static func _basis_from_x(x_axis: Vector3) -> Basis:
	var x := x_axis.normalized()
	var y := Vector3.UP
	if absf(x.dot(y)) > 0.95:
		y = Vector3.FORWARD
	var z := x.cross(y).normalized()
	y = z.cross(x).normalized()
	return Basis(x, y, z)


## Build Class-I frequency-2 icosahedral hemisphere (vertex zenith) + A/B edges.
## Targets the classic grounded 2V kit: 26 hubs / 65 struts (35A + 30B).
static func _build_2v_geometry(radius: float) -> Dictionary:
	var raw: Array = _icosahedron_verts_pole_up()
	var faces: Array = _icosahedron_faces()
	var unit_verts: Array = []
	var idx_of: Dictionary = {}
	var face_tris: Array = []

	var add_pt := func(p: Vector3) -> int:
		var n := p.normalized()
		var key := "%d_%d_%d" % [
			int(round(n.x * 1e5)), int(round(n.y * 1e5)), int(round(n.z * 1e5))]
		if idx_of.has(key):
			return int(idx_of[key])
		var i := unit_verts.size()
		idx_of[key] = i
		unit_verts.append(n)
		return i

	for f: Array in faces:
		var a: Vector3 = raw[int(f[0])]
		var b: Vector3 = raw[int(f[1])]
		var c: Vector3 = raw[int(f[2])]
		var ia: int = int(add_pt.call(a))
		var ib: int = int(add_pt.call(b))
		var ic: int = int(add_pt.call(c))
		var iab: int = int(add_pt.call((a + b).normalized()))
		var ibc: int = int(add_pt.call((b + c).normalized()))
		var ica: int = int(add_pt.call((c + a).normalized()))
		face_tris.append_array([
			[ia, iab, ica], [ib, ibc, iab], [ic, ica, ibc], [iab, ibc, ica]])

	# y=0 is a clean equatorial strut ring when a vertex is at zenith.
	var y_cut := -1e-4
	var keep: Array = []
	var new_verts := PackedVector3Array()
	for i in unit_verts.size():
		var v: Vector3 = unit_verts[i]
		if v.y >= y_cut:
			keep.append(new_verts.size())
			new_verts.append(v * radius)
		else:
			keep.append(-1)

	var edge_set: Dictionary = {}
	var add_edge := func(i0: int, i1: int) -> void:
		var a0 := int(keep[i0])
		var a1 := int(keep[i1])
		if a0 < 0 or a1 < 0 or a0 == a1:
			return
		var lo := mini(a0, a1)
		var hi := maxi(a0, a1)
		var k := "%d_%d" % [lo, hi]
		if not edge_set.has(k):
			edge_set[k] = {"a": lo, "b": hi}

	for tri: Array in face_tris:
		add_edge.call(int(tri[0]), int(tri[1]))
		add_edge.call(int(tri[1]), int(tri[2]))
		add_edge.call(int(tri[2]), int(tri[0]))

	var len_a := radius * DomeParts.CF_A
	var len_b := radius * DomeParts.CF_B
	var edges_out: Array = []
	var valence := PackedInt32Array()
	valence.resize(new_verts.size())
	for i in valence.size():
		valence[i] = 0
	for k: String in edge_set.keys():
		var e: Dictionary = edge_set[k]
		var pa := new_verts[int(e["a"])]
		var pb := new_verts[int(e["b"])]
		var L := pa.distance_to(pb)
		var kind := "A" if absf(L - len_a) <= absf(L - len_b) else "B"
		e["kind"] = kind
		e["len"] = L
		edges_out.append(e)
		valence[int(e["a"])] = int(valence[int(e["a"])]) + 1
		valence[int(e["b"])] = int(valence[int(e["b"])]) + 1

	# Base ring (lowest kept band) is always 4-way in the kit — force that so
	# hub meshes match the BOM even if a few edges were clipped oddly.
	_assign_base_four_way(new_verts, valence)

	return {"verts": new_verts, "edges": edges_out, "valence": valence}


## Mark the lowest latitude ring as 4-way hubs (grounded dome base).
static func _assign_base_four_way(verts: PackedVector3Array, valence: PackedInt32Array) -> void:
	if verts.is_empty():
		return
	var min_y := INF
	for i in verts.size():
		min_y = minf(min_y, verts[i].y)
	var band := min_y + maxf(absf(min_y) * 0.02, 0.02)
	for i in verts.size():
		if verts[i].y <= band:
			valence[i] = 4


## Regular icosahedron with one vertex rotated to +Y (zenith).
static func _icosahedron_verts_pole_up() -> Array:
	var pts := _icosahedron_verts()
	var top_i := 0
	var top_y := -INF
	for i in pts.size():
		var y := (pts[i] as Vector3).y
		if y > top_y:
			top_y = y
			top_i = i
	var top: Vector3 = pts[top_i]
	if top.distance_to(Vector3.UP) < 1e-5:
		return pts
	var axis := top.cross(Vector3.UP)
	if axis.length_squared() < 1e-10:
		return pts
	var rot := Basis(axis.normalized(), top.angle_to(Vector3.UP))
	for i in pts.size():
		pts[i] = (rot * (pts[i] as Vector3)).normalized()
	return pts


static func _icosahedron_verts() -> Array:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var pts: Array = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in pts.size():
		pts[i] = (pts[i] as Vector3).normalized()
	return pts


static func _icosahedron_faces() -> Array:
	return [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
