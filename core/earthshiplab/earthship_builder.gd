class_name EarthshipBuilder
extends RefCounted

## Draws an EarthshipDesign:
##  - "Mesh": every opaque part, one surface per material (skip_prop_collision);
##  - "Glazing": the glass, see-through, casting no shadow so the sun reaches
##    the greenhouse floor and the planters;
##  - "Bottles": the glass of the bottle walls (coloured, lit through from
##    behind), no shadow, so the sun comes through the holes in the plaster;
##  - "Plants": the greenhouse beds (garden_crop.gdshader, full grown);
##  - "CollisionMesh" (hidden): walls, floors, roofs and the glass, so the
##    rooms are walked through and the open fronts stay open.
## Options: {"cutaway": true} leaves the roofs, ceilings and what stands on
## them out (the designer's "Roof off"); {"plants": false} skips the beds.
## Metas: `earthship_spec`, `seat_spots` (beds, "lie"), `size_m`, `bottles`.

const MODEL_ID := "earthshiplab_structure"
const _CROP_SHADER := preload("res://vegetation/garden_crop.gdshader")
const _BOTTLE_SHADER := preload("res://core/earthshiplab/earthship_bottle.gdshader")

const COLORS := {
	"tyre": Color(0.11, 0.11, 0.12),
	"roof": Color(0.46, 0.43, 0.4),
	"wood": Color(0.52, 0.36, 0.22),
	"viga": Color(0.74, 0.58, 0.38),
	"door": Color(0.5, 0.31, 0.16),
	"soil": Color(0.24, 0.17, 0.11),
	"concrete": Color(0.62, 0.6, 0.56),
	"cistern": Color(0.3, 0.31, 0.32),
	"glass": Color(0.78, 0.88, 0.9),
	"pv": Color(0.08, 0.12, 0.26),
	"pvframe": Color(0.75, 0.76, 0.78),
	"grass": Color(0.33, 0.48, 0.2),
	"ceiling": Color(0.82, 0.66, 0.44),
}

static var _tex: Dictionary = {}


static func build_node(spec_in: Variant, name: String = "Earthship", opts: Dictionary = {}) -> Node3D:
	var d := EarthshipDesign.solve(spec_in)
	return build_from_design(d, name, opts)


static func build_from_design(d: Dictionary, name: String = "Earthship", opts: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = name
	var spec: Dictionary = d["spec"]
	var cutaway := bool(opts.get("cutaway", false))
	var tools := {}
	var glass := SurfaceTool.new()
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bottle := SurfaceTool.new()
	bottle.begin(Mesh.PRIMITIVE_TRIANGLES)
	var col := SurfaceTool.new()
	col.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bottles := 0
	for p in d["parts"]:
		var part: Dictionary = p
		if cutaway and bool(part.get("roof", false)):
			continue
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
		var cst: SurfaceTool = col if collide else null
		if part.has("box"):
			var b: Array = part["box"]
			emit_box(st, b[0], b[1])
			if cst:
				emit_box(cst, b[0], b[1])
		elif part.has("prism"):
			var xr: Array = part["x"]
			emit_prism_x(st, part["prism"], float(xr[0]), float(xr[1]))
			if cst:
				emit_prism_x(cst, part["prism"], float(xr[0]), float(xr[1]))
		elif part.has("quad"):
			var q: Array = part["quad"]
			emit_quad(st, q[0], q[1], q[2], q[3])
			if cst:
				emit_quad(cst, q[0], q[1], q[2], q[3])
		elif part.has("cyl"):
			var c: Array = part["cyl"]
			emit_cyl(st, c[0], c[1], float(part["r"]), int(part.get("sides", 10)))
			if cst:
				emit_cyl(cst, c[0], c[1], float(part["r"]), 6)
		elif part.has("obox"):
			emit_obox(st, part["obox"], part["size"])
			if cst:
				emit_obox(cst, part["obox"], part["size"])
		elif part.has("sweep"):
			emit_sweep(st, part["sweep"], float(part["t"]), float(part["yb"]))
			if cst:
				emit_sweep(cst, part["sweep"], float(part["t"]), float(part["yb"]))
		elif part.has("panel"):
			bottles += emit_panel(st, bottle, cst, part)
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
	if bottles > 0:
		var bm := bottle.commit()
		bm.surface_set_material(0, material_for("bottle", spec))
		var bi := MeshInstance3D.new()
		bi.name = "Bottles"
		bi.mesh = bm
		bi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bi.set_meta("skip_prop_collision", true)
		bi.visibility_range_end = 220.0
		root.add_child(bi)
	if bool(opts.get("plants", true)):
		var pn := build_plants(d)
		if pn != null:
			root.add_child(pn)
	var cm := MeshInstance3D.new()
	cm.name = "CollisionMesh"
	cm.mesh = col.commit()
	cm.visible = false
	root.add_child(cm)
	root.set_meta("earthship_spec", spec)
	root.set_meta("bottles", bottles)
	var spots: Array = []
	for b2 in d["beds"]:
		spots.append({"pos": b2["pos"], "yaw": deg_to_rad(float(b2["yaw"])), "kind": "lie"})
	root.set_meta("seat_spots", spots)
	var fr: Dictionary = d["frame"]
	root.set_meta("size_m", Vector3(float(fr["x1"]) - float(fr["x0"]),
		float(fr["roof"]) - float(fr["yf"]), float(fr["z_front"]) - float(fr["z_back"])))
	return root


## The greenhouse beds' plants: one MultiMesh per plant, full grown.
static func build_plants(d: Dictionary) -> Node3D:
	var spec: Dictionary = d["spec"]
	var places := EarthshipPlants.scatter(d.get("planters", []), str(spec["plants"]),
		hash(str(spec["name"])) % 10007 + 17)
	if places.is_empty():
		return null
	var root := Node3D.new()
	root.name = "Plants"
	var mat := ShaderMaterial.new()
	mat.shader = _CROP_SHADER
	mat.set_shader_parameter("now_d", 0.0)
	var ids: Array = places.keys()
	ids.sort()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var count := 0
	for id in ids:
		var list: Array = places[id]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = EarthshipPlants.mesh(str(id))
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
			# Sown 600 days of a 1000-day cycle ago: full grown, fruiting, not
			# yet going over (garden_crop.gdshader's clock).
			mm.set_instance_custom_data(i, Color(-600.0 + rng.randf_range(-40.0, 40.0), 1000.0, 0.05, rng.randf()))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Plant_%s" % str(id)
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if EarthshipPlants.casts_shadow(str(id)) \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 90.0
		mmi.visibility_range_end_margin = 10.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.set_meta("skip_prop_collision", true)
		root.add_child(mmi)
		count += list.size()
	root.set_meta("plants", count)
	return root


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

static func material_for(mat: String, spec: Dictionary) -> Material:
	match mat:
		"glass":
			var g := StandardMaterial3D.new()
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			g.cull_mode = BaseMaterial3D.CULL_DISABLED
			g.albedo_color = Color(COLORS["glass"].r, COLORS["glass"].g, COLORS["glass"].b, 0.14)
			g.metallic = 0.0
			g.metallic_specular = 0.85
			g.roughness = 0.03
			g.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			return g
		"bottle":
			var bm := ShaderMaterial.new()
			bm.shader = _BOTTLE_SHADER
			return bm
		"wood", "trim":
			var c: Color = EarthshipSpec.color_of(spec, "trim", Color(0.43, 0.29, 0.18)) if mat == "trim" else COLORS["wood"]
			return StructureMaterials.make(StructureMaterials.Kind.WOOD, c)
		"viga", "door":
			return StructureMaterials.make(StructureMaterials.Kind.WOOD, COLORS[mat])
		"pv":
			return StructureMaterials.make(StructureMaterials.Kind.PANEL, COLORS["pv"])
		"pvframe":
			return StructureMaterials.make(StructureMaterials.Kind.ALUMINIUM, COLORS["pvframe"])
		"tyre":
			return StructureMaterials.make(StructureMaterials.Kind.RUBBER, COLORS["tyre"])
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.95
	m.uv1_triplanar = true
	m.uv1_triplanar_sharpness = 0.8
	match mat:
		"plaster":
			# Hand-trowelled earth plaster: a soft, low-contrast mottle.
			m.albedo_color = EarthshipSpec.color_of(spec, "plaster", Color(0.78, 0.66, 0.5)) * Color(1.08, 1.08, 1.08)
			m.albedo_texture = _noise_tex("plaster", 0.06, Color(0.86, 0.86, 0.86), Color(1, 1, 1))
			m.uv1_scale = Vector3(0.6, 0.6, 0.6)
		"floor":
			_floor_material(m, str(spec.get("floor", "flagstone")))
		"ceiling":
			m.albedo_color = Color(1, 1, 1)
			m.albedo_texture = _planks_tex()
			m.uv1_scale = Vector3(1.0 / 1.12, 1.0 / 1.12, 1.0 / 1.12)
			m.roughness = 0.8
		"soil":
			m.albedo_color = COLORS["soil"] * Color(1.2, 1.2, 1.2)
			m.albedo_texture = _noise_tex("soil", 0.4, Color(0.7, 0.7, 0.7), Color(1, 1, 1))
			m.uv1_scale = Vector3(2.0, 2.0, 2.0)
		"grass":
			m.albedo_color = COLORS["grass"] * Color(1.15, 1.15, 1.15)
			m.albedo_texture = _noise_tex("grass", 0.5, Color(0.7, 0.78, 0.6), Color(1, 1, 1))
			m.uv1_scale = Vector3(1.5, 1.5, 1.5)
		_:
			m.albedo_color = COLORS.get(mat, Color(0.6, 0.6, 0.6))
	return m


static func _floor_material(m: StandardMaterial3D, kind: String) -> void:
	match kind:
		"earth":
			# A burnished earth floor (linseed-oiled adobe).
			m.albedo_color = Color(0.72, 0.5, 0.33)
			m.albedo_texture = _noise_tex("earthfloor", 0.12, Color(0.82, 0.82, 0.82), Color(1, 1, 1))
			m.uv1_scale = Vector3(0.5, 0.5, 0.5)
			m.roughness = 0.55
		"tile":
			m.albedo_color = Color(1, 1, 1)
			m.albedo_texture = _tile_tex()
			m.uv1_scale = Vector3(1.0 / 1.2, 1.0 / 1.2, 1.0 / 1.2)
			m.roughness = 0.6
		_:
			# Sandstone flags (the corridor photo): irregular stones in mortar.
			m.albedo_color = Color(1, 1, 1)
			m.albedo_texture = _flagstone_tex()
			m.uv1_scale = Vector3(0.45, 0.45, 0.45)
			m.roughness = 0.82


## A grey noise texture between `lo` and `hi` (multiplies the albedo colour).
static func _noise_tex(key: String, freq: float, lo: Color, hi: Color) -> Texture2D:
	if _tex.has(key):
		return _tex[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = 4
	n.seed = hash(key) % 1000
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.noise = n
	var gr := Gradient.new()
	gr.set_color(0, lo)
	gr.set_color(1, hi)
	t.color_ramp = gr
	_tex[key] = t
	return t


static func _flagstone_tex() -> Texture2D:
	if _tex.has("flag"):
		return _tex["flag"]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	n.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	n.frequency = 0.03
	n.cellular_jitter = 0.9
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	n.seed = 77
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.noise = n
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 0.07, 0.13, 0.6, 1.0])
	gr.colors = PackedColorArray([Color(0.36, 0.26, 0.19), Color(0.46, 0.34, 0.25), Color(0.76, 0.54, 0.4),
		Color(0.84, 0.62, 0.46), Color(0.9, 0.7, 0.52)])
	t.color_ramp = gr
	_tex["flag"] = t
	return t


## Tongue-and-groove boards running across the vigas (along the row).
static func _planks_tex() -> Texture2D:
	if _tex.has("planks"):
		return _tex["planks"]
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var boards := 8
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for b in boards:
		var base := Color(0.8, 0.63, 0.42).lerp(Color(0.86, 0.7, 0.48), rng.randf())
		var y0 := b * size / boards
		var y1 := (b + 1) * size / boards
		for y in range(y0, y1):
			for x in size:
				var grain := 0.94 + 0.06 * sin(float(x) * 0.09 + float(y) * 0.7 + float(b) * 3.0)
				var c := base * grain
				if y == y0 or y == y0 + 1:
					c = base.darkened(0.45)
				img.set_pixel(x, y, c)
	var t := ImageTexture.create_from_image(img)
	_tex["planks"] = t
	return t


## Terracotta saltillo tiles, 0.3 m.
static func _tile_tex() -> Texture2D:
	if _tex.has("tile"):
		return _tex["tile"]
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var cells := 4
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var cols: Array = []
	for k in cells * cells:
		cols.append(Color(0.72, 0.38, 0.22).lerp(Color(0.8, 0.48, 0.28), rng.randf()))
	var cs := size / cells
	for y in size:
		for x in size:
			var gx := x / cs
			var gy := y / cs
			var c: Color = cols[gy * cells + gx]
			if x % cs < 3 or y % cs < 3:
				c = Color(0.62, 0.58, 0.52)
			img.set_pixel(x, y, c)
	var t := ImageTexture.create_from_image(img)
	_tex["tile"] = t
	return t


# ---------------------------------------------------------------------------
# Emitters (explicit normals; every triangle wound so Godot's front face,
# clockwise seen from the normal's side, matches the normal)
# ---------------------------------------------------------------------------

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		var tmp := b
		b = c
		c = tmp
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x + v.z, v.y) * 0.5)
		st.add_vertex(v)


static func _tri_c(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		var tmp := b
		b = c
		c = tmp
	for v in [a, b, c]:
		st.set_color(col)
		st.set_normal(n)
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
	_face(st, p[0], p[1], p[5], p[4], Vector3.FORWARD)
	_face(st, p[2], p[3], p[7], p[6], Vector3.BACK)
	_face(st, p[1], p[2], p[6], p[5], Vector3.RIGHT)
	_face(st, p[3], p[0], p[4], p[7], Vector3.LEFT)


static func _face(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


## A box in its own frame: `xf` places its middle, the basis columns are the
## directions of `size`'s x, y and z.
static func emit_obox(st: SurfaceTool, xf: Transform3D, size: Vector3) -> void:
	var bx := xf.basis.x.normalized() * size.x * 0.5
	var by := xf.basis.y.normalized() * size.y * 0.5
	var bz := xf.basis.z.normalized() * size.z * 0.5
	var c := xf.origin
	for ax in [[bx, by, bz], [by, bz, bx], [bz, bx, by]]:
		var n: Vector3 = ax[0]
		var u: Vector3 = ax[1]
		var v: Vector3 = ax[2]
		for sgn in [-1.0, 1.0]:
			var fc: Vector3 = c + n * sgn
			var nn: Vector3 = n.normalized() * sgn
			_face(st, fc - u - v, fc + u - v, fc + u + v, fc - u + v, nn)


## A round log or tank from `a` to `b`, closed at both ends.
static func emit_cyl(st: SurfaceTool, a: Vector3, b: Vector3, r: float, sides: int) -> void:
	var ax := b - a
	if ax.length_squared() < 1e-10:
		return
	var u := ax.normalized()
	var s1 := (Vector3.RIGHT if absf(u.dot(Vector3.RIGHT)) < 0.9 else Vector3.UP).cross(u).normalized()
	var s2 := u.cross(s1).normalized()
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var o0 := s1 * cos(a0) + s2 * sin(a0)
		var o1 := s1 * cos(a1) + s2 * sin(a1)
		var nm := (o0 + o1).normalized()
		_tri(st, a + o0 * r, a + o1 * r, b + o1 * r, nm)
		_tri(st, a + o0 * r, b + o1 * r, b + o0 * r, nm)
		_tri(st, a, a + o1 * r, a + o0 * r, -u)
		_tri(st, b, b + o0 * r, b + o1 * r, u)


## A curved wall along `pts` (x, top, z) at its middle, `t` thick, from `yb`
## up to each point's top; flat ends.
static func emit_sweep(st: SurfaceTool, pts: Array, t: float, yb: float) -> void:
	var n := pts.size()
	if n < 2:
		return
	var lefts: Array = []
	var rights: Array = []
	for i in n:
		var p: Vector3 = pts[i]
		var prv: Vector3 = pts[maxi(i - 1, 0)]
		var nxt: Vector3 = pts[mini(i + 1, n - 1)]
		var d := Vector2(nxt.x - prv.x, nxt.z - prv.z).normalized()
		var side := Vector3(-d.y, 0.0, d.x) * t * 0.5
		lefts.append([p + side, side.normalized()])
		rights.append([p - side, -side.normalized()])
	for i in n - 1:
		for e in [lefts, rights]:
			var q0: Vector3 = e[i][0]
			var q1: Vector3 = e[i + 1][0]
			var nm: Vector3 = (e[i][1] + e[i + 1][1]).normalized()
			_face(st, Vector3(q0.x, yb, q0.z), Vector3(q1.x, yb, q1.z), q1, q0, nm)
		var l0: Vector3 = lefts[i][0]
		var l1: Vector3 = lefts[i + 1][0]
		var r0: Vector3 = rights[i][0]
		var r1: Vector3 = rights[i + 1][0]
		var up := (l1 - l0).cross(r0 - l0).normalized()
		if up.y < 0.0:
			up = -up
		_face(st, l0, l1, r1, r0, up)
	for k in [0, n - 1]:
		var l: Vector3 = lefts[k][0]
		var r: Vector3 = rights[k][0]
		var p2: Vector3 = pts[k]
		var p3: Vector3 = pts[1] if k == 0 else pts[n - 2]
		var out := Vector3(p2.x - p3.x, 0.0, p2.z - p3.z).normalized()
		_face(st, Vector3(l.x, yb, l.z), Vector3(r.x, yb, r.z), r, l, out)


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
	var cw := Geometry2D.is_polygon_clockwise(prof)
	for i in n:
		var u := prof[i]
		var v := prof[(i + 1) % n]
		var e := Vector2(v.x - u.x, v.y - u.y)
		var out2 := Vector2(e.y, -e.x) if not cw else Vector2(-e.y, e.x)
		var nrm := Vector3(0.0, out2.y, out2.x).normalized()
		_face(st, Vector3(xa, u.y, u.x), Vector3(xb, u.y, u.x), Vector3(xb, v.y, v.x), Vector3(xa, v.y, v.x), nrm)


## A wall (or several pieces of one) in its own plane with bottles through
## it. The faces are laid row by row on the bottle grid: a row with no
## bottle is one strip; in a row with bottles the cells between them are
## strips and each bottle cell is a ring round its hole, the hole's sides
## running through the wall, the bottle's glass in it. Returns the bottles.
static func emit_panel(st: SurfaceTool, bst: SurfaceTool, cst: SurfaceTool, part: Dictionary) -> int:
	var outs: Array = part["panel"]
	var o: Vector3 = part["o"]
	var U: Vector3 = part["u"]
	var V: Vector3 = part["v"]
	var W: Vector3 = part["w"]
	var t := float(part["t"])
	var cell := float(part["cell"])
	var go: Vector2 = part["grid_o"]
	var holes: Dictionary = part["holes"]
	var r := float(part["r"])
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for ol in outs:
		var poly: PackedVector2Array = ol
		if poly.size() < 3:
			continue
		for p in poly:
			lo = lo.min(p)
			hi = hi.max(p)
		_panel_edges(st, poly, o, U, V, W, t)
		if cst != null:
			_panel_solid(cst, poly, o, U, V, W, t)
	if lo.x == INF:
		return 0
	var rows := {}
	for key in holes.keys():
		var kk: Vector2i = key
		if not rows.has(kk.y):
			rows[kk.y] = []
		(rows[kk.y] as Array).append(kk.x)
	var j0 := floori((lo.y - go.y) / cell)
	var j1 := ceili((hi.y - go.y) / cell)
	var n_b := 0
	for j in range(j0, j1):
		var y0 := maxf(go.y + float(j) * cell, lo.y - 0.01)
		var y1 := minf(go.y + float(j + 1) * cell, hi.y + 0.01)
		if j == j0:
			y0 = lo.y - 0.01
		if j == j1 - 1:
			y1 = hi.y + 0.01
		var cols: Array = rows.get(j, [])
		cols.sort()
		var runs: Array = []
		var xa := lo.x - 0.01
		for ci in cols:
			var cx0 := go.x + float(ci) * cell
			if cx0 > xa:
				runs.append([xa, cx0])
			xa = cx0 + cell
		runs.append([xa, hi.x + 0.01])
		for run in runs:
			var ra: float = run[0]
			var rb: float = run[1]
			if rb - ra < 1e-4:
				continue
			var rect := PackedVector2Array([Vector2(ra, y0), Vector2(rb, y0), Vector2(rb, y1), Vector2(ra, y1)])
			for ol2 in outs:
				for clip in Geometry2D.intersect_polygons(ol2 as PackedVector2Array, rect):
					_panel_faces(st, clip, o, U, V, W, t)
		for ci2 in cols:
			var c0 := Vector2(go.x + float(ci2) * cell, go.y + float(j) * cell)
			var colr: Color = holes[Vector2i(ci2, j)]
			_bottle_cell(st, bst, c0, cell, r, o, U, V, W, t, colr.srgb_to_linear())
			n_b += 1
	return n_b


static func _p3(o: Vector3, U: Vector3, V: Vector3, W: Vector3, p: Vector2, w: float) -> Vector3:
	return o + U * p.x + V * p.y + W * w


static func _panel_faces(st: SurfaceTool, poly: PackedVector2Array, o: Vector3, U: Vector3, V: Vector3,
		W: Vector3, t: float) -> void:
	var idx := Geometry2D.triangulate_polygon(poly)
	for k in range(0, idx.size(), 3):
		var a := poly[idx[k]]
		var b := poly[idx[k + 1]]
		var c := poly[idx[k + 2]]
		_tri(st, _p3(o, U, V, W, a, 0.0), _p3(o, U, V, W, b, 0.0), _p3(o, U, V, W, c, 0.0), -W)
		_tri(st, _p3(o, U, V, W, a, t), _p3(o, U, V, W, b, t), _p3(o, U, V, W, c, t), W)


static func _panel_edges(st: SurfaceTool, poly: PackedVector2Array, o: Vector3, U: Vector3, V: Vector3,
		W: Vector3, t: float) -> void:
	var cw := Geometry2D.is_polygon_clockwise(poly)
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var e := b - a
		var out2 := Vector2(e.y, -e.x) if not cw else Vector2(-e.y, e.x)
		var nrm := (U * out2.x + V * out2.y).normalized()
		_face(st, _p3(o, U, V, W, a, 0.0), _p3(o, U, V, W, b, 0.0), _p3(o, U, V, W, b, t), _p3(o, U, V, W, a, t), nrm)


static func _panel_solid(st: SurfaceTool, poly: PackedVector2Array, o: Vector3, U: Vector3, V: Vector3,
		W: Vector3, t: float) -> void:
	_panel_faces(st, poly, o, U, V, W, t)
	_panel_edges(st, poly, o, U, V, W, t)


## One bottle: the wall round its hole (both faces), the hole's sides and
## the glass (an end at each face and the tube between).
static func _bottle_cell(st: SurfaceTool, bst: SurfaceTool, c0: Vector2, cell: float, r: float, o: Vector3,
		U: Vector3, V: Vector3, W: Vector3, t: float, colr: Color) -> void:
	var c := c0 + Vector2(cell, cell) * 0.5
	var half := cell * 0.5
	var angs: Array = []
	var segs := 14
	for k in segs:
		angs.append(TAU * float(k) / float(segs))
	var ca := atan2(half, half)
	for k2 in 4:
		angs.append(fposmod(ca + PI * 0.5 * float(k2), TAU))
	angs.sort()
	var ring: Array = []
	var edge: Array = []
	for a in angs:
		var af: float = a
		var d := Vector2(cos(af), sin(af))
		var tt := minf(half / maxf(absf(d.x), 1e-6), half / maxf(absf(d.y), 1e-6))
		ring.append(c + d * r)
		edge.append(c + d * tt)
	var m := angs.size()
	for i in m:
		var p0: Vector2 = ring[i]
		var p1: Vector2 = ring[(i + 1) % m]
		var e0: Vector2 = edge[i]
		var e1: Vector2 = edge[(i + 1) % m]
		for wv in [0.0, t]:
			var nn := -W if wv == 0.0 else W
			_tri(st, _p3(o, U, V, W, p0, wv), _p3(o, U, V, W, e0, wv), _p3(o, U, V, W, e1, wv), nn)
			_tri(st, _p3(o, U, V, W, p0, wv), _p3(o, U, V, W, e1, wv), _p3(o, U, V, W, p1, wv), nn)
		# The hole's side, facing its middle.
		var mid := (p0 + p1) * 0.5
		var inward := (U * (c.x - mid.x) + V * (c.y - mid.y)).normalized()
		_face(st, _p3(o, U, V, W, p0, 0.0), _p3(o, U, V, W, p1, 0.0), _p3(o, U, V, W, p1, t),
			_p3(o, U, V, W, p0, t), inward)
	# The glass: two slightly domed bottle ends and the tube.
	var rg := r * 0.94
	var gs := 10
	var cin := 0.012
	for k3 in gs:
		var a0 := TAU * float(k3) / float(gs)
		var a1 := TAU * float(k3 + 1) / float(gs)
		var q0 := c + Vector2(cos(a0), sin(a0)) * rg
		var q1 := c + Vector2(cos(a1), sin(a1)) * rg
		_tri_c(bst, _p3(o, U, V, W, c, cin - 0.006), _p3(o, U, V, W, q0, cin), _p3(o, U, V, W, q1, cin), -W, colr)
		_tri_c(bst, _p3(o, U, V, W, c, t - cin + 0.006), _p3(o, U, V, W, q0, t - cin), _p3(o, U, V, W, q1, t - cin), W, colr)
		var out := (U * (q0.x + q1.x - 2.0 * c.x) + V * (q0.y + q1.y - 2.0 * c.y)).normalized()
		var dark := colr.darkened(0.25)
		_tri_c(bst, _p3(o, U, V, W, q0, cin), _p3(o, U, V, W, q1, cin), _p3(o, U, V, W, q1, t - cin), out, dark)
		_tri_c(bst, _p3(o, U, V, W, q0, cin), _p3(o, U, V, W, q1, t - cin), _p3(o, U, V, W, q0, t - cin), out, dark)
