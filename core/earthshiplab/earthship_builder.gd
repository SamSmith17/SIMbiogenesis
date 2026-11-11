class_name EarthshipBuilder
extends RefCounted

## Draws an EarthshipDesign: "Mesh" (every opaque part, one surface per
## material), "Glazing" (the glass: casts no shadow so the sun reaches the
## greenhouse floor; skip_prop_collision), and a hidden "CollisionMesh" the
## prop collision is built from (walls, floors, roof, the glass), so the
## rooms are walked through and the open fronts stay open.
## Metas: `earthship_spec`, `seat_spots` (beds, "lie"), `size_m`.

const MODEL_ID := "earthshiplab_structure"

const COLORS := {
	"tyre": Color(0.11, 0.11, 0.12),
	"floor": Color(0.55, 0.44, 0.33),
	"roof": Color(0.6, 0.55, 0.48),
	"wood": Color(0.52, 0.36, 0.22),
	"soil": Color(0.27, 0.2, 0.13),
	"concrete": Color(0.62, 0.6, 0.56),
	"glass": Color(0.7, 0.85, 0.9),
}


static func build_node(spec_in: Variant, name: String = "Earthship") -> Node3D:
	var d := EarthshipDesign.solve(spec_in)
	return build_from_design(d, name)


static func build_from_design(d: Dictionary, name: String = "Earthship") -> Node3D:
	var root := Node3D.new()
	root.name = name
	var spec: Dictionary = d["spec"]
	var tools := {}
	var glass := SurfaceTool.new()
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	var col := SurfaceTool.new()
	col.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in d["parts"]:
		var part: Dictionary = p
		var mat := str(part.get("mat", "plaster"))
		var st: SurfaceTool = null
		if mat == "glass":
			st = glass
		else:
			if not tools.has(mat):
				var t := SurfaceTool.new()
				t.begin(Mesh.PRIMITIVE_TRIANGLES)
				tools[mat] = t
			st = tools[mat]
		var collide := bool(part.get("col", true))
		if part.has("box"):
			var b: Array = part["box"]
			emit_box(st, b[0], b[1])
			if collide:
				emit_box(col, b[0], b[1])
		elif part.has("prism"):
			var xr: Array = part["x"]
			emit_prism_x(st, part["prism"], float(xr[0]), float(xr[1]))
			if collide:
				emit_prism_x(col, part["prism"], float(xr[0]), float(xr[1]))
		elif part.has("quad"):
			var q: Array = part["quad"]
			emit_quad(st, q[0], q[1], q[2], q[3])
			if collide:
				emit_quad(col, q[0], q[1], q[2], q[3])
	var mesh := ArrayMesh.new()
	var mats: Array = tools.keys()
	mats.sort()
	for m in mats:
		var t2: SurfaceTool = tools[m]
		t2.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material_for(str(m), spec))
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.set_meta("skip_prop_collision", true)
	root.add_child(mi)
	var gm := glass.commit()
	if gm != null and gm.get_surface_count() > 0:
		gm.surface_set_material(0, material_for("glass", spec))
		var gi := MeshInstance3D.new()
		gi.name = "Glazing"
		gi.mesh = gm
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gi.set_meta("skip_prop_collision", true)
		root.add_child(gi)
	var cm := MeshInstance3D.new()
	cm.name = "CollisionMesh"
	cm.mesh = col.commit()
	cm.visible = false
	root.add_child(cm)
	root.set_meta("earthship_spec", spec)
	var spots: Array = []
	for b2 in d["beds"]:
		spots.append({"pos": b2["pos"], "yaw": deg_to_rad(float(b2["yaw"])), "kind": "lie"})
	root.set_meta("seat_spots", spots)
	var fr: Dictionary = d["frame"]
	root.set_meta("size_m", Vector3(float(fr["x1"]) - float(fr["x0"]),
		float(fr["roof"]) - float(fr["yf"]), float(fr["z_front"]) - float(fr["z_back"])))
	return root


static func material_for(mat: String, spec: Dictionary) -> Material:
	match mat:
		"glass":
			return StructureMaterials.make(StructureMaterials.Kind.GLAZING, COLORS["glass"])
		"wood", "trim":
			var c: Color = EarthshipSpec.color_of(spec, "trim", Color(0.43, 0.29, 0.18)) if mat == "trim" else COLORS["wood"]
			return StructureMaterials.make(StructureMaterials.Kind.WOOD, c)
		"tyre":
			return StructureMaterials.make(StructureMaterials.Kind.RUBBER, COLORS["tyre"])
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.95
	match mat:
		"plaster":
			m.albedo_color = EarthshipSpec.color_of(spec, "plaster", Color(0.78, 0.66, 0.5))
		_:
			m.albedo_color = COLORS.get(mat, Color(0.6, 0.6, 0.6))
	return m


# ---------------------------------------------------------------------------
# Emitters (explicit normals; materials are double-sided)
# ---------------------------------------------------------------------------

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x + v.z, v.y) * 0.5)
		st.add_vertex(v)


static func emit_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var n := (b - a).cross(d - a).normalized()
	if n == Vector3.ZERO:
		n = Vector3.UP
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


static func emit_box(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	var p := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	_face(st, p[4], p[5], p[6], p[7], Vector3.UP)
	_face(st, p[3], p[2], p[1], p[0], Vector3.DOWN)
	_face(st, p[0], p[1], p[5], p[4], Vector3.BACK * -1.0)
	_face(st, p[2], p[3], p[7], p[6], Vector3.BACK)
	_face(st, p[1], p[2], p[6], p[5], Vector3.RIGHT)
	_face(st, p[3], p[0], p[4], p[7], Vector3.LEFT)


static func _face(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


## A side profile (z, y) pushed along x from xa to xb.
static func emit_prism_x(st: SurfaceTool, prof: PackedVector2Array, xa: float, xb: float) -> void:
	var idx := Geometry2D.triangulate_polygon(prof)
	for k in range(0, idx.size(), 3):
		var p0 := prof[idx[k]]
		var p1 := prof[idx[k + 1]]
		var p2 := prof[idx[k + 2]]
		_tri(st, Vector3(xa, p0.y, p0.x), Vector3(xa, p1.y, p1.x), Vector3(xa, p2.y, p2.x), Vector3.LEFT)
		_tri(st, Vector3(xb, p0.y, p0.x), Vector3(xb, p2.y, p2.x), Vector3(xb, p1.y, p1.x), Vector3.RIGHT)
	var n := prof.size()
	for i in n:
		var u := prof[i]
		var v := prof[(i + 1) % n]
		var e := Vector2(v.x - u.x, v.y - u.y)
		var nrm := Vector3(0.0, -e.x, e.y).normalized()
		_face(st, Vector3(xa, u.y, u.x), Vector3(xb, u.y, u.x), Vector3(xb, v.y, v.x), Vector3(xa, v.y, v.x), nrm)
