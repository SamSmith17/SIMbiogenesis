class_name PvLabBuilder
extends RefCounted

## The Solar designer's array in 3D. Metres; the array frame of PvLabArray
## (y up from the mounting surface, the modules facing +Z at yaw 0).
##
## One module mesh per module design (cached): the glass face drawn by
## pv_module.gdshader (the cells, exact to the millimetre), the frame's
## C-profile (or a frameless laminate, clips, a folding case), the backsheet,
## junction boxes and lead connectors. Fixed modules are one MultiMesh
## "Panels"; a tracker's modules ride a "TrackerHead<i>" node each (turned
## about its own Z by set_tracker_angle). Rack members are prisms of their
## real section (lumber, Unistrut C-channel, slotted rail, tube) merged into
## "Rack" by finish. String links are drawn as cables on the back. A hidden
## "CollisionMesh" (modules and members as solids) is what PlacedProp builds
## its collider and pick box from, and what shading rays from other rows hit.
##
## opts: overlay ({panel index: Color} tints, e.g. strings in the designer),
## tracker_deg (initial rotation), cables (default true), ghost_highlight
## (the placement ghost's tint), pieces (one MeshInstance3D per module and per
## member, tagged for StructureUnits, instead of the merged nodes).

const MODEL_ID := "pvlab_array"
const LAMINATE_M := 0.0045
const WALL_M := 0.0018
const CABLE_R_M := 0.003
const GHOST_TINT := Color(0.45, 0.85, 1.0, 0.45)
const SHADER := preload("res://core/pvlab/pv_module.gdshader")

static var _mesh_cache := {}
static var _mat_cache := {}


static func build_node(spec: Dictionary = {}, node_name: String = "PvLabArray", opts: Dictionary = {}) -> Node3D:
	return build_from_design(PvLabDesign.solve(spec), node_name, opts)


static func build_from_design(d: Dictionary, node_name: String = "PvLabArray", opts: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var s: Dictionary = d["spec"]
	root.set_meta("pvlab_spec", PvLabSpec.to_json_safe(s))
	root.set_meta("pvlab_key", PvLabSpec.key_of(s))
	var lay: Dictionary = d["layout"]
	var m: Dictionary = d["module"]
	var pieces := bool(opts.get("pieces", false))
	var ghost := bool(opts.get("ghost_highlight", false))
	var overlay: Dictionary = opts.get("overlay", {}) if opts.get("overlay") is Dictionary else {}
	var heads: Array = lay["heads"]
	var head_nodes: Array = []
	for hi in heads.size():
		var hn := Node3D.new()
		hn.name = "TrackerHead%d" % hi
		hn.position = (heads[hi] as Dictionary)["pos"]
		hn.set_meta("pvlab_head", hi)
		root.add_child(hn)
		head_nodes.append(hn)
	if pieces:
		_build_pieces(root, d, head_nodes)
	else:
		# Modules: a MultiMesh on the fixed frame, one per tracker head.
		var by_parent := {}
		for p in lay["panels"]:
			var hi2 := int(p["head"])
			if not by_parent.has(hi2):
				by_parent[hi2] = []
			(by_parent[hi2] as Array).append(p)
		for hk in by_parent:
			var parent: Node3D = root if int(hk) < 0 else head_nodes[int(hk)]
			parent.add_child(_panels_node(m, by_parent[hk], overlay))
		# Rack: fixed members on the root, head members on their head.
		var fixed: Array = []
		var on_head := {}
		for mb in d["members"]:
			var h := int(mb["head"])
			if h < 0:
				fixed.append(mb)
			else:
				if not on_head.has(h):
					on_head[h] = []
				(on_head[h] as Array).append(mb)
		if not fixed.is_empty():
			root.add_child(_members_node(fixed, s, "Rack"))
		for h2 in on_head:
			(head_nodes[int(h2)] as Node3D).add_child(_members_node(on_head[h2], s, "Rack"))
		# Hardware: every clamp, bracket, footing and bolt set.
		var hw_fixed: Array = []
		var hw_head := {}
		for hp in d.get("parts", []):
			var hh := int(hp["head"])
			if hh < 0:
				hw_fixed.append(hp)
			else:
				if not hw_head.has(hh):
					hw_head[hh] = []
				(hw_head[hh] as Array).append(hp)
		if not hw_fixed.is_empty():
			root.add_child(_parts_node(hw_fixed, s, "Hardware"))
		for h3 in hw_head:
			(head_nodes[int(h3)] as Node3D).add_child(_parts_node(hw_head[h3], s, "Hardware"))
		if bool(opts.get("hide_modules", false)):
			for pn in _all_panel_nodes(root):
				(pn as Node3D).visible = false
		if bool(opts.get("cables", true)):
			_add_cables(root, head_nodes, d)
	root.add_child(_collision_node(d))
	if heads.size() > 0:
		set_tracker_angle(root, float(opts.get("tracker_deg", 0.0)))
	if ghost:
		_apply_ghost(root)
	return root


# ---------------------------------------------------------------------------
# Module mesh
# ---------------------------------------------------------------------------

## The cell shader's uniforms for a module design.
static func cell_uniforms(module: Dictionary) -> Dictionary:
	var m := PvLabModule.resolve(module) if not module.has("version") else module
	var c: Dictionary = m["cells"]
	var tech := PvLabCells.tech(str(c["tech"]))
	var look: Dictionary = tech["look"]
	var lk: Dictionary = m["look"]
	var pc := PvLabModule.piece_mm(m)
	var paths := PvLabModule.parallel_paths(m)
	var folding := str(m["type"]) == "folding"
	var cell_col: Color = lk["cell_color"] if lk["cell_color"] is Color else look["color"]
	var glass_r := {"ar": 0.06, "textured": 0.22, "etfe": 0.35, "pet": 0.12}
	var ext := PvLabModule.grid_extent_mm(m)
	if folding:
		ext.y += float(m["folding"]["hinge_mm"]) * float(int(m["folding"]["leaves"]) - 1)
	return {
		"dims_mm": Vector2(float(m["dims_mm"]["w"]), float(m["dims_mm"]["h"])),
		"cols": int(c["cols"]), "rows": int(c["rows"]),
		"piece_mm": Vector2(float(pc["across"]), float(pc["along"])),
		"gap_mm": float(c["gap_mm"]), "split_gap_mm": float(c["split_gap_mm"]) if paths > 1 else 0.0,
		"paths": paths, "hinge_mm": float(m["folding"]["hinge_mm"]) if folding else 0.0,
		"leaves": int(m["folding"]["leaves"]) if folding else 1, "grid_mm": ext,
		"chamfer_mm": float(pc["chamfer"]),
		"pieces": int((PvLabCells.CUTS[str(c["cut"])] as Dictionary)["pieces"]),
		"film": bool(look["film"]), "metal": bool(look["metal"]), "busbars": int(c["busbars"]),
		"finger_pitch_mm": float(c["finger_pitch_mm"]), "cell_color": cell_col,
		"sheet_color": PvLabModule.SHEET_COLORS[str(m["backsheet"]["front"])],
		"hinge_color": Color(0.05, 0.05, 0.055), "grid_color": lk["grid_color"],
		"flake": float(look["flake"]) * float(lk["flake"]), "sheen": float(look["sheen"]) * float(lk["sheen"]),
		"glass_roughness": float(glass_r.get(str(m["glass"]), 0.08)),
		"cell_roughness": 0.5 if bool(look["film"]) else 0.42,
		"surface": PvLabModule.surface_id(m),
		"rear_cell_color": Color(0.3, 0.31, 0.33) if bool(tech["crystalline"]) else Color(0.12, 0.12, 0.13),
	}


static func cell_material(module: Dictionary, overlay: bool = false, back: bool = false) -> ShaderMaterial:
	var key := "%s|%s|%s" % [PvLabModule.key_of(module), overlay, back]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	var u := cell_uniforms(module)
	for k in u:
		mat.set_shader_parameter(k, u[k])
	mat.set_shader_parameter("use_overlay", overlay)
	if back:
		# The rear of a glass–glass module: the cells' grey backs behind clear
		# glass, the gaps the clear sheet.
		mat.set_shader_parameter("back_side", true)
		mat.set_shader_parameter("sheet_color", PvLabModule.SHEET_COLORS["clear"].darkened(0.35))
		mat.set_shader_parameter("sheen", 0.0)
	if _mat_cache.size() > 64:
		_mat_cache.clear()
	_mat_cache[key] = mat
	return mat


static func _std(color: Color, metallic: float, rough: float, cull_off: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = rough
	if cull_off:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func frame_material(module: Dictionary) -> StandardMaterial3D:
	var st := str(module["frame"]["style"])
	match st:
		"silver":
			return _std(Color(0.8, 0.82, 0.84), 0.85, 0.32)
		"fabric":
			return _std(Color(0.06, 0.065, 0.07), 0.0, 0.92)
		"none", "clips":
			# The laminate's edge.
			return _std(PvLabModule.SHEET_COLORS[str(module["backsheet"]["back"])].darkened(0.35), 0.0, 0.6)
		_:
			return _std(Color(0.035, 0.035, 0.04), 0.55, 0.42)


## One module as a mesh, centred, its face +Y. Surfaces: face (cells),
## frame, back, plastic (junction boxes), connector, metal (grommets).
## Cached per design.
##
## A framed module's glass sits in the frame's channel: the lip stands
## lip_mm proud of the glass and reaches overlap_mm over its edge, so the
## frame reads as a step round the face, not a flat border. A frameless
## laminate follows its corner radius (flexible and folding modules are
## rounded). A clear rear sheet (glass–glass) shows the cells' grey backs
## through it.
static func module_mesh(module: Dictionary, overlay: bool = false) -> ArrayMesh:
	var m := PvLabModule.resolve(module) if not module.has("version") else module
	var key := "%s|%s" % [PvLabModule.key_of(m), overlay]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var w := float(m["dims_mm"]["w"]) * 0.001
	var h := float(m["dims_mm"]["h"]) * 0.001
	var t := float(m["dims_mm"]["t"]) * 0.001
	var style := str(m["frame"]["style"])
	var framed := style in ["black", "silver", "fabric"]
	var face := _Acc.new()
	var frame := _Acc.new()
	var back := _Acc.new()
	var back_cells := _Acc.new()
	var plastic := _Acc.new()
	var conn := _Acc.new()
	var metal := _Acc.new()
	var clear_back := str(m["backsheet"]["back"]) == "clear"
	var y_back := 0.0
	if framed:
		var fw := minf(float(m["frame"]["width_mm"]) * 0.001, minf(w, h) * 0.2)
		var ft := maxf(float(m["frame"]["height_mm"]) * 0.001, t)
		var lip_t := float(m["frame"]["lip_mm"]) * 0.001
		var ov := minf(float(m["frame"]["overlap_mm"]) * 0.001, fw)
		if style == "fabric":
			ft = maxf(t, 0.004)
			lip_t = 0.0
			ov = 0.0
		var y_glass := ft * 0.5 - lip_t
		var gi := fw - ov  # the glass edge, under the lip
		# Glass face, UV over the whole module so the cell grid lines up.
		_face_quad(face, w, h, -w * 0.5 + gi, w * 0.5 - gi, -h * 0.5 + gi, h * 0.5 - gi, y_glass)
		y_back = y_glass - LAMINATE_M
		var bx := w * 0.5 - WALL_M
		var bz := h * 0.5 - WALL_M
		_face_quad(back_cells if clear_back else back, w, h, -bx, bx, -bz, bz, y_back, Vector3.DOWN)
		if style == "fabric":
			# The case: a fabric slab round and under the face.
			_box(frame, Vector3(0, -0.001, 0), Vector3(w, ft - 0.002, h))
			for kk in int(m["folding"]["kickstands"]):
				var kx := (float(kk) - float(int(m["folding"]["kickstands"]) - 1) * 0.5) * w * 0.6
				_box(frame, Vector3(kx, -ft * 0.5 - 0.15, h * 0.08), Vector3(0.02, 0.3, 0.004),
					Basis(Vector3.RIGHT, deg_to_rad(-35.0)))
			# Hinge stitching across each fold: a seam strip proud of the case.
			var leaves := int(m["folding"]["leaves"])
			for li in range(1, leaves):
				var zf := -h * 0.5 + h * float(li) / float(leaves)
				_box(frame, Vector3(0, ft * 0.5 - 0.0005, zf), Vector3(w - 0.01, 0.002, 0.004))
		else:
			# C-profile: the lip over the glass, the outer wall, the bottom
			# flange, on each side.
			for side in 4:
				var along_x := side < 2
				var sgn := -1.0 if side % 2 == 0 else 1.0
				var ln := w if along_x else h
				var off := (h if along_x else w) * 0.5
				var pieces_c := [
					[off - fw * 0.5, y_glass + lip_t * 0.5, fw, maxf(lip_t, 0.0012)],
					[off - WALL_M * 0.5, (y_glass - ft * 0.5) * 0.5, WALL_M, y_glass + ft * 0.5],
					[off - fw * 0.65, -ft * 0.5 + 0.001, fw * 1.3, 0.002],
				]
				for pcd in pieces_c:
					var across := float(pcd[0]) * sgn
					var yy := float(pcd[1])
					var sz_a := float(pcd[2])
					var sz_y := float(pcd[3])
					if along_x:
						_box(frame, Vector3(0, yy, across), Vector3(ln, sz_y, sz_a))
					else:
						_box(frame, Vector3(across, yy, 0), Vector3(sz_a, sz_y, ln))
	else:
		var tt := maxf(t, 0.002)
		var rr := minf(PvLabModule.corner_radius_mm(m) * 0.001, minf(w, h) * 0.25)
		var ol := _rounded_outline(w, h, rr)
		_face_poly(face, ol, w, h, tt * 0.5, Vector3.UP)
		y_back = -tt * 0.5
		_face_poly(back_cells if clear_back else back, ol, w, h, y_back, Vector3.DOWN)
		# The laminate's edges.
		for i in ol.size():
			var p0 := ol[i]
			var p1 := ol[(i + 1) % ol.size()]
			var e := p1 - p0
			var nn := Vector3(e.y, 0, -e.x).normalized()
			if nn.dot(Vector3((p0.x + p1.x) * 0.5, 0, (p0.y + p1.y) * 0.5)) < 0.0:
				nn = -nn
			frame.quad(Vector3(p0.x, -tt * 0.5, p0.y), Vector3(p1.x, -tt * 0.5, p1.y),
				Vector3(p1.x, tt * 0.5, p1.y), Vector3(p0.x, tt * 0.5, p0.y), nn)
		if style == "clips":
			for zc in [-0.25, 0.25]:
				for sx in [-1.0, 1.0]:
					_box(conn, Vector3(sx * (w * 0.5 + 0.004), 0.0, zc * h), Vector3(0.012, tt + 0.008, 0.07))
		if str(m["type"]) == "flexible":
			# Stainless corner grommets through the laminate.
			for gx in [-1.0, 1.0]:
				for gz in [-1.0, 1.0]:
					var gc := Vector3(gx * (w * 0.5 - 0.016), 0.0, gz * (h * 0.5 - 0.016))
					_cyl(metal, gc + Vector3(0, -tt * 0.5 - 0.0004, 0), gc + Vector3(0, tt * 0.5 + 0.0006, 0), 0.0065, 12)
	# Junction boxes, cable glands and lead connectors on the back.
	var jb := PvLabModule.jbox_points(m)
	var split := (jb["boxes"] as Array).size() > 1
	var bsz := Vector3(0.06, 0.018, 0.045) if split else Vector3(0.11, 0.02, 0.08)
	if str(m["type"]) == "flexible":
		bsz = Vector3(0.06, 0.012, 0.04)
	for buv in jb["boxes"]:
		var bp := Vector3(float(buv.x) * w, y_back - bsz.y * 0.5, float(buv.y) * h)
		_box(plastic, bp, bsz)
		_box(plastic, bp + Vector3(0, -bsz.y * 0.5 - 0.0015, 0), Vector3(bsz.x * 0.7, 0.003, bsz.z * 0.7))
	for kname in ["plus", "minus"]:
		var uv: Vector2 = jb[kname]
		var sx2 := 1.0 if kname == "plus" else -1.0
		var gland := Vector3(uv.x * w + sx2 * 0.02, y_back - 0.01, uv.y * h + bsz.z * 0.5)
		_cyl(plastic, gland, gland + Vector3(0, 0, 0.012), 0.006, 8)
		var cp := Vector3(uv.x * w + sx2 * 0.07, y_back - 0.012, uv.y * h + 0.04)
		_cyl(conn, cp + Vector3(0, 0, -0.03), cp + Vector3(0, 0, 0.03), 0.009, 8)
		_box(plastic, Vector3(uv.x * w + sx2 * 0.045, y_back - 0.008, uv.y * h + 0.03),
			Vector3(0.05, 0.006, 0.006))
	var mesh := ArrayMesh.new()
	_commit_to(mesh, face, cell_material(m, overlay))
	_commit_to(mesh, frame, frame_material(m))
	_commit_to(mesh, back, _std(PvLabModule.SHEET_COLORS[str(m["backsheet"]["back"])], 0.0, 0.7))
	_commit_to(mesh, back_cells, cell_material(m, false, true))
	_commit_to(mesh, plastic, _std(Color(0.04, 0.04, 0.045), 0.0, 0.6))
	var cc: Color = (PvLabModule.CONNECTORS[str(m["jbox"]["connector"])] as Dictionary)["color"]
	_commit_to(mesh, conn, _std(cc if str(m["frame"]["style"]) != "clips" else Color(0.8, 0.82, 0.84), 0.2, 0.5))
	_commit_to(mesh, metal, _std(Color(0.78, 0.8, 0.82), 0.9, 0.3))
	if _mesh_cache.size() > 48:
		_mesh_cache.clear()
	_mesh_cache[key] = mesh
	return mesh


static func _face_quad(acc: _Acc, w: float, h: float, x0: float, x1: float, z0: float, z1: float, y: float,
		nrm: Vector3 = Vector3.UP) -> void:
	var uv := func(x: float, z: float) -> Vector2:
		return Vector2(x / w + 0.5, z / h + 0.5)
	acc.quad_uv(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), nrm,
		uv.call(x0, z0), uv.call(x1, z0), uv.call(x1, z1), uv.call(x0, z1))


## A w × h rectangle (x, z) with corners rounded to `r` (m), as a loop.
static func _rounded_outline(w: float, h: float, r: float) -> PackedVector2Array:
	if r < 0.0005:
		return PackedVector2Array([Vector2(-w * 0.5, -h * 0.5), Vector2(w * 0.5, -h * 0.5),
			Vector2(w * 0.5, h * 0.5), Vector2(-w * 0.5, h * 0.5)])
	var out := PackedVector2Array()
	var cs := [Vector2(w * 0.5 - r, -h * 0.5 + r), Vector2(w * 0.5 - r, h * 0.5 - r),
		Vector2(-w * 0.5 + r, h * 0.5 - r), Vector2(-w * 0.5 + r, -h * 0.5 + r)]
	var a0 := [-PI * 0.5, 0.0, PI * 0.5, PI]
	for ci in 4:
		for k in 7:
			var a: float = float(a0[ci]) + PI * 0.5 * float(k) / 6.0
			out.append((cs[ci] as Vector2) + Vector2(cos(a), sin(a)) * r)
	return out


## A convex outline (x, z) as a fan at height y, UV over the whole module.
static func _face_poly(acc: _Acc, ol: PackedVector2Array, w: float, h: float, y: float, nrm: Vector3) -> void:
	var uv := func(p: Vector2) -> Vector2:
		return Vector2(p.x / w + 0.5, p.y / h + 0.5)
	for i in ol.size():
		var a := ol[i]
		var b := ol[(i + 1) % ol.size()]
		acc.tri(Vector3(0, y, 0), Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), nrm, uv.call(Vector2.ZERO),
			uv.call(a), uv.call(b))


## A closed cylinder from a to b.
static func _cyl(acc: _Acc, a: Vector3, b: Vector3, r: float, seg: int = 10) -> void:
	var ax := b - a
	if ax.length() < 1e-6:
		return
	var zn := ax.normalized()
	var ref := Vector3.UP if absf(zn.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var x := ref.cross(zn).normalized()
	var y := zn.cross(x).normalized()
	for k in seg:
		var a0 := TAU * float(k) / float(seg)
		var a1 := TAU * float(k + 1) / float(seg)
		var o0 := (x * cos(a0) + y * sin(a0)) * r
		var o1 := (x * cos(a1) + y * sin(a1)) * r
		acc.quad(a + o0, a + o1, b + o1, b + o0, (o0 + o1).normalized())
		acc.tri(a, a + o0, a + o1, -zn)
		acc.tri(b, b + o0, b + o1, zn)


static func _box(acc: _Acc, c: Vector3, size: Vector3, b: Basis = Basis.IDENTITY) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var p := func(x: float, y: float, z: float) -> Vector3:
		return c + b * Vector3(x, y, z)
	acc.quad(p.call(-hx, hy, -hz), p.call(hx, hy, -hz), p.call(hx, hy, hz), p.call(-hx, hy, hz), b * Vector3.UP)
	acc.quad(p.call(-hx, -hy, -hz), p.call(hx, -hy, -hz), p.call(hx, -hy, hz), p.call(-hx, -hy, hz), b * Vector3.DOWN)
	acc.quad(p.call(-hx, -hy, hz), p.call(hx, -hy, hz), p.call(hx, hy, hz), p.call(-hx, hy, hz), b * Vector3.BACK)
	acc.quad(p.call(-hx, -hy, -hz), p.call(hx, -hy, -hz), p.call(hx, hy, -hz), p.call(-hx, hy, -hz), b * Vector3.FORWARD)
	acc.quad(p.call(hx, -hy, -hz), p.call(hx, -hy, hz), p.call(hx, hy, hz), p.call(hx, hy, -hz), b * Vector3.RIGHT)
	acc.quad(p.call(-hx, -hy, -hz), p.call(-hx, -hy, hz), p.call(-hx, hy, hz), p.call(-hx, hy, -hz), b * Vector3.LEFT)


static func _commit_to(mesh: ArrayMesh, acc: _Acc, mat: Material) -> void:
	if acc.v.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = acc.v
	arr[Mesh.ARRAY_NORMAL] = acc.n
	arr[Mesh.ARRAY_TEX_UV] = acc.uv
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


# ---------------------------------------------------------------------------
# Modules, rack, cables
# ---------------------------------------------------------------------------

static func _panels_node(m: Dictionary, panels: Array, overlay: Dictionary) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = module_mesh(m, true)
	mm.instance_count = panels.size()
	var ids := PackedInt32Array()
	for i in panels.size():
		var p: Dictionary = panels[i]
		mm.set_instance_transform(i, p["xf"])
		var c: Color = overlay.get(int(p["index"]), Color(0, 0, 0, 0))
		mm.set_instance_custom_data(i, c)
		ids.append(int(p["index"]))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Panels"
	mmi.multimesh = mm
	mmi.set_meta("panel_ids", ids)
	mmi.set_meta("skip_prop_collision", true)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mmi


## Tint modules (panel index → Color, alpha = strength); others clear.
static func set_overlay(root: Node, colors: Dictionary) -> void:
	for mmi in _all_panel_nodes(root):
		var ids: PackedInt32Array = mmi.get_meta("panel_ids")
		var mm := (mmi as MultiMeshInstance3D).multimesh
		for i in ids.size():
			mm.set_instance_custom_data(i, colors.get(int(ids[i]), Color(0, 0, 0, 0)))


static func _all_panel_nodes(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		if c is MultiMeshInstance3D and c.has_meta("panel_ids"):
			out.append(c)
		elif c is Node3D and c.has_meta("pvlab_head"):
			for cc in c.get_children():
				if cc is MultiMeshInstance3D and cc.has_meta("panel_ids"):
					out.append(cc)
	return out


## Turn every tracker head to `r_deg` (positive tips the modules toward −X).
static func set_tracker_angle(root: Node, r_deg: float) -> void:
	for c in root.get_children():
		if c is Node3D and c.has_meta("pvlab_head"):
			(c as Node3D).basis = Basis(Vector3(0, 0, 1), deg_to_rad(r_deg))
	root.set_meta("pvlab_tracker_deg", r_deg)


static func tracker_angle(root: Node) -> float:
	return float(root.get_meta("pvlab_tracker_deg", 0.0))


## A member's section outline (metres) in its (x = across, y = up) plane.
static func profile_outline(profile_id: String) -> PackedVector2Array:
	var p := PvLabRack.profile(profile_id)
	var w := float(p["w"]) * 0.001
	var h := float(p["h"]) * 0.001
	var hw := w * 0.5
	var hh := h * 0.5
	match str(p["shape"]):
		"channel":
			var t := 0.0027
			var s := 0.011
			var lip := 0.007
			return PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(s, hh),
				Vector2(s, hh - lip), Vector2(s - t, hh - lip), Vector2(s - t, hh - t), Vector2(hw - t, hh - t),
				Vector2(hw - t, -hh + t), Vector2(-hw + t, -hh + t), Vector2(-hw + t, hh - t), Vector2(-s + t, hh - t),
				Vector2(-s + t, hh - lip), Vector2(-s, hh - lip), Vector2(-s, hh), Vector2(-hw, hh)])
		"rail":
			var g := 0.004
			return PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(g, hh),
				Vector2(g, hh - 0.007), Vector2(-g, hh - 0.007), Vector2(-g, hh), Vector2(-hw, hh)])
		"tube_round":
			var out := PackedVector2Array()
			for k in 12:
				var a := TAU * float(k) / 12.0
				out.append(Vector2(cos(a) * hw, sin(a) * hh))
			return out
		_:
			return PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])


## Sweep a member's section from a to b.
static func _member_mesh(acc: _Acc, mb: Dictionary) -> void:
	var a: Vector3 = mb["a"]
	var b: Vector3 = mb["b"]
	var ax := b - a
	if ax.length() < 1e-4:
		return
	var z := ax.normalized()
	var up: Vector3 = mb["up"]
	var y := (up - z * up.dot(z))
	if y.length() < 1e-4:
		y = Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		y = (y - z * y.dot(z))
	y = y.normalized()
	var x := y.cross(z).normalized()
	var ol := profile_outline(str(mb["profile"]))
	var n := ol.size()
	# Outline orientation: outward normals need it counter-clockwise in (x, y).
	var area := 0.0
	for i in n:
		area += ol[i].x * ol[(i + 1) % n].y - ol[(i + 1) % n].x * ol[i].y
	if area < 0.0:
		ol.reverse()
	for i in n:
		var p0 := ol[i]
		var p1 := ol[(i + 1) % n]
		var e := p1 - p0
		var nrm2 := Vector2(e.y, -e.x).normalized()
		var nw := x * nrm2.x + y * nrm2.y
		var q0 := a + x * p0.x + y * p0.y
		var q1 := a + x * p1.x + y * p1.y
		acc.quad(q0, q1, q1 + ax, q0 + ax, nw)
	var tris := Geometry2D.triangulate_polygon(ol)
	for k in range(0, tris.size(), 3):
		var c0 := ol[tris[k]]
		var c1 := ol[tris[k + 1]]
		var c2 := ol[tris[k + 2]]
		acc.tri(a + x * c0.x + y * c0.y, a + x * c1.x + y * c1.y, a + x * c2.x + y * c2.y, -z)
		acc.tri(b + x * c0.x + y * c0.y, b + x * c1.x + y * c1.y, b + x * c2.x + y * c2.y, z)


static func look_material(look: String, s: Dictionary) -> Material:
	var cols: Dictionary = s["colors"]
	match look:
		"lumber":
			return StructureMaterials.make(StructureMaterials.Kind.WOOD, cols["lumber"])
		"alu":
			return StructureMaterials.make(StructureMaterials.Kind.ALUMINIUM, cols["alu"])
		"concrete":
			var m := StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols["concrete"])
			m.roughness = 0.95
			m.metallic = 0.0
			return m
		"black_alu", "black":
			var mb := StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.05, 0.05, 0.055))
			mb.metallic = 0.4
			mb.roughness = 0.45
			return mb
		"steel":
			return StructureMaterials.make(StructureMaterials.Kind.GALVANISED, Color(0.62, 0.64, 0.66))
		"tin":
			var mt := StructureMaterials.make(StructureMaterials.Kind.GALVANISED, Color(0.82, 0.78, 0.66))
			mt.metallic = 0.85
			return mt
		"plastic":
			return StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.05, 0.05, 0.05))
		"yellow":
			return StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.95, 0.75, 0.1))
		_:
			return StructureMaterials.make(StructureMaterials.Kind.GALVANISED, cols["galv"])


static func _members_node(members: Array, s: Dictionary, node_name: String) -> MeshInstance3D:
	var accs := {}
	for mb in members:
		var look := str(PvLabRack.profile(str(mb["profile"]))["look"])
		if not accs.has(look):
			accs[look] = _Acc.new()
		_member_mesh(accs[look], mb)
	var mesh := ArrayMesh.new()
	for look2 in accs:
		_commit_to(mesh, accs[look2], look_material(str(look2), s))
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.set_meta("skip_prop_collision", true)
	return mi


## String links as cables on the back of the modules, sagging a little.
static func _add_cables(root: Node3D, head_nodes: Array, d: Dictionary) -> void:
	var lay: Dictionary = d["layout"]
	var leads: Array = d["wiring"]["leads"]
	var by_head := {}
	for st in d["wiring"]["strings"]:
		for ln in st["links"]:
			var pa: Dictionary = (lay["panels"] as Array)[int(ln["from"])]
			var pb: Dictionary = (lay["panels"] as Array)[int(ln["to"])]
			var ha := int(pa["head"])
			if ha != int(pb["head"]):
				continue
			var a: Vector3 = (leads[int(ln["from"])] as Dictionary)["plus"]
			var b: Vector3 = (leads[int(ln["to"])] as Dictionary)["minus"]
			if ha >= 0:
				var hp: Vector3 = ((lay["heads"] as Array)[ha] as Dictionary)["pos"]
				a -= hp
				b -= hp
			if not by_head.has(ha):
				by_head[ha] = _Acc.new()
			var mid := (a + b) * 0.5 + Vector3(0, -0.06 - a.distance_to(b) * 0.04, 0)
			_cable(by_head[ha], [a, a.lerp(mid, 0.5) + Vector3(0, -0.015, 0), mid, mid.lerp(b, 0.5) + Vector3(0, -0.015, 0), b])
	for hk in by_head:
		var mesh := ArrayMesh.new()
		_commit_to(mesh, by_head[hk], _std((d["spec"]["colors"] as Dictionary)["cable"], 0.0, 0.55))
		var mi := MeshInstance3D.new()
		mi.name = "Cables"
		mi.mesh = mesh
		mi.set_meta("skip_prop_collision", true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if int(hk) < 0:
			root.add_child(mi)
		else:
			(head_nodes[int(hk)] as Node3D).add_child(mi)


static func _cable(acc: _Acc, pts: Array) -> void:
	for i in range(pts.size() - 1):
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var z := (b - a)
		if z.length() < 1e-4:
			continue
		var zn := z.normalized()
		var ref := Vector3.UP if absf(zn.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var x := ref.cross(zn).normalized()
		var y := zn.cross(x).normalized()
		for k in 6:
			var a0 := TAU * float(k) / 6.0
			var a1 := TAU * float(k + 1) / 6.0
			var o0 := (x * cos(a0) + y * sin(a0)) * CABLE_R_M
			var o1 := (x * cos(a1) + y * sin(a1)) * CABLE_R_M
			acc.quad(a + o0, a + o1, b + o1, b + o0, (o0 + o1).normalized())


# ---------------------------------------------------------------------------
# Hardware parts (PvLabHardware): clamps, brackets, footings, bolts
# ---------------------------------------------------------------------------

## The look a part is drawn in (its finish).
static func part_look(p: Dictionary) -> String:
	var t := str(p["type"])
	var look := str(PvLabHardware.part(t)["look"])
	if t in ["mid_clamp", "end_clamp"] and str((p["params"] as Dictionary).get("finish", "silver")) == "black":
		return "black_alu"
	if t == "end_cap" and bool((p["params"] as Dictionary).get("yellow", false)):
		return "yellow"
	return look


## Draw one part into per-look accumulators ({look: _Acc}); fasteners go to
## "steel". Local frame: x along the rail or member it holds, y off the
## surface it sits on.
static func emit_part(accs: Dictionary, p: Dictionary) -> void:
	var xf: Transform3D = p["xf"]
	var pr: Dictionary = p["params"]
	var acc := _acc_for(accs, part_look(p))
	var steel := _acc_for(accs, "steel")
	var bx := func(a: _Acc, c: Vector3, sz: Vector3) -> void:
		_box(a, xf * c, sz, xf.basis)
	var bxr := func(a: _Acc, c: Vector3, sz: Vector3, lb: Basis) -> void:
		_box(a, xf * c, sz, xf.basis * lb)
	var cy := func(a: _Acc, c0: Vector3, c1: Vector3, r: float, seg: int) -> void:
		_cyl(a, xf * c0, xf * c1, r, seg)
	match str(p["type"]):
		"end_clamp":
			var t := float(pr.get("t", 0.035))
			bx.call(acc, Vector3(0.014, t * 0.5, 0), Vector3(0.024, t, 0.04))
			bx.call(acc, Vector3(0.0085, t + 0.002, 0), Vector3(0.035, 0.004, 0.04))
			cy.call(steel, Vector3(0.016, t + 0.004, 0), Vector3(0.016, t + 0.009, 0), 0.0065, 6)
		"mid_clamp":
			var t2 := float(pr.get("t", 0.035))
			var g := maxf(float(pr.get("gap", 0.02)) - 0.001, 0.003)
			bx.call(acc, Vector3(0, t2 * 0.5, 0), Vector3(g, t2, 0.03))
			bx.call(acc, Vector3(0, t2 + 0.002, 0), Vector3(g + 0.024, 0.004, 0.04))
			cy.call(steel, Vector3(0, t2 + 0.004, 0), Vector3(0, t2 + 0.009, 0), 0.0065, 6)
		"end_cap":
			bx.call(acc, Vector3(0.002, 0, 0), Vector3(0.004, float(pr["h"]) + 0.002, float(pr["w"]) + 0.002))
		"ground_lug":
			bx.call(acc, Vector3(0, 0.003, 0), Vector3(0.02, 0.006, 0.016))
			cy.call(acc, Vector3(0, 0.006, -0.008), Vector3(0, 0.006, 0.008), 0.004, 8)
			cy.call(steel, Vector3(-0.006, 0.006, 0), Vector3(-0.006, 0.011, 0), 0.0055, 6)
		"rail_splice":
			var hh := float(pr["h"])
			var ww := float(pr["w"])
			bx.call(acc, Vector3.ZERO, Vector3(0.2, hh + 0.004, ww + 0.004))
			for sx in [-0.07, -0.03, 0.03, 0.07]:
				cy.call(steel, Vector3(sx, 0, ww * 0.5 + 0.002), Vector3(sx, 0, ww * 0.5 + 0.006), 0.005, 6)
		"rail_bracket", "strut_fitting":
			var rw := float(pr.get("rail_w", 0.04))
			var wid := 0.041 if str(p["type"]) == "strut_fitting" else 0.04
			var th := 0.006 if str(p["type"]) == "strut_fitting" else 0.004
			var zl := rw * 0.5 + th * 0.5
			bx.call(acc, Vector3(0, 0.025, zl), Vector3(wid, 0.05, th))
			bx.call(acc, Vector3(0, th * 0.5, zl + 0.025), Vector3(wid, th, 0.05))
			cy.call(steel, Vector3(0, 0.03, zl + th * 0.5), Vector3(0, 0.03, zl + th * 0.5 + 0.006), 0.0075, 6)
			cy.call(steel, Vector3(0, th, zl + 0.032), Vector3(0, th + 0.006, zl + 0.032), 0.0075, 6)
		"hurricane_tie":
			var rw2 := float(pr.get("rail_w", 0.038))
			var rh := float(pr.get("rail_h", 0.089))
			var ph := float(pr.get("purl_h", 0.089))
			bx.call(acc, Vector3(0, rh * 0.3, rw2 * 0.5 + 0.001), Vector3(0.035, rh * 0.6, 0.0015))
			bx.call(acc, Vector3(0.02, -ph * 0.3, rw2 * 0.5 + 0.015), Vector3(0.0015, ph * 0.6, 0.03))
		"post_bracket", "post_cap":
			var lw := float(pr.get("leg_w", 0.06))
			var ph2 := float(pr.get("purl_h", 0.06))
			var th2 := 0.004 if str(p["type"]) == "post_bracket" else 0.0015
			for sx2 in [-1.0, 1.0]:
				bx.call(acc, Vector3(sx2 * (lw * 0.5 + th2 * 0.5), -0.05 + ph2 * 0.35, 0), Vector3(th2, 0.1 + ph2 * 0.7, lw * 0.8))
				cy.call(steel, Vector3(sx2 * (lw * 0.5 + th2), -0.035, 0), Vector3(sx2 * (lw * 0.5 + th2 + 0.006), -0.035, 0),
					0.008, 6)
			bx.call(acc, Vector3(0, -0.001, 0), Vector3(lw + th2 * 2.0, 0.002, lw * 0.8))
		"strut_gusset":
			var lw2 := float(pr.get("leg_w", 0.0413))
			bx.call(acc, Vector3(lw2 * 0.5 + 0.003, -0.05, 0), Vector3(0.006, 0.1, 0.0413))
			bx.call(acc, Vector3(lw2 * 0.5 + 0.03, -0.003, 0), Vector3(0.06, 0.006, 0.0413))
			bxr.call(acc, Vector3(lw2 * 0.5 + 0.02, -0.025, 0), Vector3(0.05, 0.004, 0.006),
				Basis(Vector3.BACK, deg_to_rad(45.0)))
			for yy in [-0.025, -0.07]:
				cy.call(steel, Vector3(lw2 * 0.5 + 0.006, yy, 0), Vector3(lw2 * 0.5 + 0.012, yy, 0), 0.008, 6)
		"ground_screw":
			cy.call(acc, Vector3(0, -1.25, 0), Vector3(0, 0.1, 0), 0.038, 10)
			cy.call(acc, Vector3(0, -1.32, 0), Vector3(0, -1.25, 0), 0.02, 8)
			for k in 10:
				var a := TAU * float(k) / 4.0
				var yk := -1.2 + float(k) * 0.035
				bxr.call(acc, Vector3(cos(a) * 0.05, yk, sin(a) * 0.05), Vector3(0.03, 0.004, 0.03),
					Basis(Vector3.UP, -a) * Basis(Vector3.RIGHT, deg_to_rad(18.0)))
			bx.call(acc, Vector3(0, 0.106, 0), Vector3(0.18, 0.012, 0.18))
			for c4 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				cy.call(steel, Vector3(c4.x * 0.065, 0.112, c4.y * 0.065), Vector3(c4.x * 0.065, 0.12, c4.y * 0.065), 0.009, 6)
		"pier":
			cy.call(acc, Vector3(0, -0.9, 0), Vector3(0, 0.08, 0), 0.15, 16)
			var steel_b := _acc_for(accs, "galv")
			_box(steel_b, xf * Vector3(0, 0.086, 0), Vector3(0.14, 0.012, 0.14), xf.basis)
			cy.call(steel, Vector3(0, 0.092, 0), Vector3(0, 0.11, 0), 0.01, 6)
		"base_plate":
			bx.call(acc, Vector3(0, 0.005, 0), Vector3(0.15, 0.01, 0.15))
			for c5 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				cy.call(steel, Vector3(c5.x * 0.055, 0.01, c5.y * 0.055), Vector3(c5.x * 0.055, 0.02, c5.y * 0.055), 0.008, 6)
		"post_base":
			bx.call(acc, Vector3(0, 0.026, 0), Vector3(0.1, 0.003, 0.1))
			for sx3 in [-1.0, 1.0]:
				bx.call(acc, Vector3(sx3 * 0.046, 0.066, 0), Vector3(0.002, 0.08, 0.09))
			bx.call(acc, Vector3(0, 0.012, 0), Vector3(0.04, 0.024, 0.04))
		"l_foot":
			var hgt := float(pr.get("h", 0.11))
			var rw3 := float(pr.get("rail_w", 0.03))
			# Black-coated flashing under the shingles, its raised cone round the lag.
			var flash := _acc_for(accs, "black_alu")
			_box(flash, xf * Vector3(0, 0.0004, 0), Vector3(0.23, 0.0008, 0.3), xf.basis)
			_cyl(flash, xf * Vector3(0, 0.0, 0.04), xf * Vector3(0, 0.025, 0.04), 0.022, 12)
			bx.call(acc, Vector3(0, 0.003, 0.04), Vector3(0.04, 0.006, 0.07))
			var top := hgt + float(pr.get("rail_h", 0.04)) * 0.5
			bx.call(acc, Vector3(rw3 * 0.5 + 0.003, top * 0.5, 0.0), Vector3(0.006, top, 0.04))
			cy.call(steel, Vector3(0, 0.006, 0.05), Vector3(0, 0.014, 0.05), 0.009, 6)
			cy.call(steel, Vector3(rw3 * 0.5 + 0.006, hgt + 0.012, 0), Vector3(rw3 * 0.5 + 0.012, hgt + 0.012, 0), 0.0075, 6)
		"ballast_bracket":
			for sx4 in [-1.0, 1.0]:
				bx.call(acc, Vector3(sx4 * 0.035, 0.04, 0), Vector3(0.004, 0.08, 0.06))
			bx.call(acc, Vector3(0, 0.003, 0), Vector3(0.1, 0.006, 0.06))
		"brace_bolt":
			cy.call(steel, Vector3(0, -0.025, 0), Vector3(0, 0.025, 0), 0.005, 6)
			cy.call(steel, Vector3(0, 0.022, 0), Vector3(0, 0.03, 0), 0.0095, 6)
			cy.call(steel, Vector3(0, -0.03, 0), Vector3(0, -0.022, 0), 0.0095, 6)
		"bearing":
			cy.call(acc, Vector3(-0.04, 0, 0), Vector3(0.04, 0, 0), 0.078, 14)
			for sz in [-1.0, 1.0]:
				bx.call(acc, Vector3(0, -0.11, sz * 0.05), Vector3(0.12, 0.13, 0.006))
			bx.call(acc, Vector3(0, -0.175, 0), Vector3(0.14, 0.008, 0.12))
			for c6 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				cy.call(steel, Vector3(c6.x * 0.045, -0.12, c6.y * 0.05), Vector3(c6.x * 0.045, -0.12, c6.y * 0.058), 0.009, 6)
		"slew_drive":
			cy.call(acc, Vector3(-0.06, 0, 0), Vector3(0.06, 0, 0), 0.14, 18)
			bx.call(acc, Vector3(0, -0.04, 0.17), Vector3(0.1, 0.18, 0.12))
			cy.call(acc, Vector3(-0.05, -0.02, 0.24), Vector3(0.14, -0.02, 0.24), 0.045, 10)
			var galv := _acc_for(accs, "galv")
			for sz2 in [-1.0, 1.0]:
				_box(galv, xf * Vector3(0, -0.2, sz2 * 0.07), Vector3(0.16, 0.12, 0.008), xf.basis)
			_box(galv, xf * Vector3(0, -0.6, 0.09), Vector3(0.22, 0.28, 0.1), xf.basis)
		"tube_clamp":
			var galv2 := _acc_for(accs, "galv")
			for sx5 in [-1.0, 1.0]:
				cy.call(steel, Vector3(sx5 * 0.058, -0.062, 0), Vector3(sx5 * 0.058, 0.062, 0), 0.006, 6)
			cy.call(steel, Vector3(-0.058, -0.064, 0), Vector3(0.058, -0.064, 0), 0.006, 6)
			_box(galv2, xf * Vector3(0, 0.054, 0), Vector3(0.14, 0.008, 0.05), xf.basis)
		"module_bolts":
			var mw := float(pr["w"])
			var mh := float(pr["h"])
			for c7 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				var bp := Vector3(c7.x * (mw * 0.5 - 0.012), 0.0, c7.y * mh * 0.3)
				cy.call(steel, bp, bp + Vector3(0, -0.006, 0), 0.0065, 6)
		"pole_cap":
			cy.call(acc, Vector3(0, -0.25, 0), Vector3(0, 0.0, 0), 0.07, 14)
			bx.call(acc, Vector3(0, 0.006, 0), Vector3(0.25, 0.012, 0.25))
			for c8 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				cy.call(steel, Vector3(c8.x * 0.1, 0.012, c8.y * 0.1), Vector3(c8.x * 0.1, 0.02, c8.y * 0.1), 0.009, 6)
		"u_bolt":
			var ph3 := float(pr.get("purl_h", 0.04))
			for sx6 in [-1.0, 1.0]:
				cy.call(acc, Vector3(sx6 * 0.03, -0.06, 0), Vector3(sx6 * 0.03, ph3, 0), 0.005, 6)
			cy.call(acc, Vector3(-0.03, ph3, 0), Vector3(0.03, ph3, 0), 0.005, 6)
		_:
			bx.call(acc, Vector3.ZERO, p["size"])


static func _acc_for(accs: Dictionary, look: String) -> _Acc:
	if not accs.has(look):
		accs[look] = _Acc.new()
	return accs[look]


static func _parts_node(parts: Array, s: Dictionary, node_name: String) -> MeshInstance3D:
	var accs := {}
	for p in parts:
		emit_part(accs, p)
	var mesh := ArrayMesh.new()
	for look in accs:
		_commit_to(mesh, accs[look], look_material(str(look), s))
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.set_meta("skip_prop_collision", true)
	return mi


## A see-through amber copy of the given parts and members (the designer's
## selection), drawn over everything.
static func highlight_node(d: Dictionary, part_ids: Array, member_ids: Array, tracker_deg: float = 0.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Highlight"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.72, 0.15, 0.55)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.1)
	mat.emission_energy_multiplier = 0.6
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var lay: Dictionary = d["layout"]
	var acc := _Acc.new()
	var parts: Array = d.get("parts", [])
	for pi in part_ids:
		if int(pi) < 0 or int(pi) >= parts.size():
			continue
		var p: Dictionary = (parts[int(pi)] as Dictionary).duplicate()
		var hx := PvLabArray.head_xf(lay, int(p["head"]), tracker_deg) if int(p["head"]) >= 0 else Transform3D.IDENTITY
		p["xf"] = hx * (p["xf"] as Transform3D)
		var accs := {}
		emit_part(accs, p)
		for k in accs:
			var a: _Acc = accs[k]
			acc.v.append_array(a.v)
			acc.n.append_array(a.n)
			acc.uv.append_array(a.uv)
	var members: Array = d["members"]
	for mi in member_ids:
		if int(mi) < 0 or int(mi) >= members.size():
			continue
		var mb: Dictionary = (members[int(mi)] as Dictionary).duplicate()
		if int(mb["head"]) >= 0:
			var hx2 := PvLabArray.head_xf(lay, int(mb["head"]), tracker_deg)
			mb["a"] = hx2 * (mb["a"] as Vector3)
			mb["b"] = hx2 * (mb["b"] as Vector3)
			mb["up"] = hx2.basis * (mb["up"] as Vector3)
		_member_mesh(acc, mb)
	var mesh := ArrayMesh.new()
	_commit_to(mesh, acc, mat)
	var mesh_i := MeshInstance3D.new()
	mesh_i.mesh = mesh
	mesh_i.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh_i)
	return root


## Ray pick against everything in the array (its frame): the nearest of a
## module, a rack member or a part: {kind: "panel" | "member" | "part",
## index, t} or {}. `modules` false skips the modules (they are hidden).
static func pick_any(d: Dictionary, origin: Vector3, dir: Vector3, tracker_deg: float = 0.0,
		modules: bool = true) -> Dictionary:
	var best := {}
	var best_t := INF
	if modules:
		var hp := pick_panel(d, origin, dir, tracker_deg)
		if not hp.is_empty():
			best = {"kind": "panel", "index": int(hp["panel"]), "t": float(hp["t"])}
			best_t = float(hp["t"])
	var lay: Dictionary = d["layout"]
	var parts: Array = d.get("parts", [])
	for i in parts.size():
		var p: Dictionary = parts[i]
		var xf: Transform3D = p["xf"]
		if int(p["head"]) >= 0:
			xf = PvLabArray.head_xf(lay, int(p["head"]), tracker_deg) * xf
		var sz: Vector3 = p["size"]
		# The box sits on the part's surface (y from 0 up), except footings.
		var c := Vector3(0, sz.y * 0.5, 0)
		if str(p["type"]) in ["ground_screw", "pier"]:
			c = Vector3(0, -sz.y * 0.5 + 0.12, 0)
		elif str(p["type"]) in ["bearing", "slew_drive", "tube_clamp", "end_cap", "rail_splice", "post_bracket",
				"post_cap", "strut_gusset"]:
			c = Vector3.ZERO
		var inv := (xf * Transform3D(Basis.IDENTITY, c)).affine_inverse()
		var t := _ray_box(inv * origin, inv.basis * dir, (sz * 0.5).max(Vector3(0.015, 0.015, 0.015)))
		if t >= 0.0 and t < best_t - 0.002:
			best_t = t
			best = {"kind": "part", "index": i, "t": t}
	var members: Array = d["members"]
	for j in members.size():
		var mb: Dictionary = members[j]
		var a: Vector3 = mb["a"]
		var b: Vector3 = mb["b"]
		var up: Vector3 = mb["up"]
		if int(mb["head"]) >= 0:
			var hx := PvLabArray.head_xf(lay, int(mb["head"]), tracker_deg)
			a = hx * a
			b = hx * b
			up = hx.basis * up
		if a.distance_to(b) < 1e-3:
			continue
		var z := (b - a).normalized()
		var y := up - z * up.dot(z)
		if y.length() < 1e-4:
			y = Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
			y = y - z * y.dot(z)
		y = y.normalized()
		var pr := PvLabRack.profile(str(mb["profile"]))
		var half := Vector3(maxf(float(pr["w"]) * 0.0005, 0.012), maxf(float(pr["h"]) * 0.0005, 0.012), a.distance_to(b) * 0.5)
		var xfm := Transform3D(Basis(y.cross(z).normalized(), y, z), (a + b) * 0.5).affine_inverse()
		var t2 := _ray_box(xfm * origin, xfm.basis * dir, half)
		# Members lose ties to the parts on them.
		if t2 >= 0.0 and t2 < best_t - 0.01:
			best_t = t2
			best = {"kind": "member", "index": j, "t": t2}
	return best


# ---------------------------------------------------------------------------
# Collision, pieces, ghost, picking
# ---------------------------------------------------------------------------

## A hidden solid of the modules (at rotation 0 on a tracker) and the members:
## PlacedProp builds its collider and pick box from it.
static func _collision_node(d: Dictionary) -> MeshInstance3D:
	var acc := _Acc.new()
	var lay: Dictionary = d["layout"]
	var m: Dictionary = d["module"]
	var w := float(m["dims_mm"]["w"]) * 0.001
	var h := float(m["dims_mm"]["h"]) * 0.001
	var t := maxf(float(m["dims_mm"]["t"]) * 0.001, 0.02)
	for p in lay["panels"]:
		var xf := PvLabArray.panel_xf(lay, p, 0.0)
		_box(acc, xf.origin, Vector3(w, t, h), xf.basis)
	for mb in d["members"]:
		var hi := int(mb["head"])
		var off := Vector3.ZERO
		if hi >= 0:
			off = ((lay["heads"] as Array)[hi] as Dictionary)["pos"]
		var a: Vector3 = (mb["a"] as Vector3) + off
		var b: Vector3 = (mb["b"] as Vector3) + off
		var pr := PvLabRack.profile(str(mb["profile"]))
		var sz := Vector3(maxf(float(pr["w"]) * 0.001, 0.03), maxf(float(pr["h"]) * 0.001, 0.03), a.distance_to(b))
		if sz.z < 1e-3:
			continue
		var z := (b - a).normalized()
		var up: Vector3 = mb["up"]
		var y := (up - z * up.dot(z))
		if y.length() < 1e-4:
			y = Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
			y = y - z * y.dot(z)
		y = y.normalized()
		_box(acc, (a + b) * 0.5, sz, Basis(y.cross(z).normalized(), y, z))
	var mesh := ArrayMesh.new()
	_commit_to(mesh, acc, _std(Color.WHITE, 0.0, 1.0))
	var mi := MeshInstance3D.new()
	mi.name = "CollisionMesh"
	mi.visible = false
	mi.mesh = mesh
	return mi


static func _build_pieces(root: Node3D, d: Dictionary, head_nodes: Array) -> void:
	var lay: Dictionary = d["layout"]
	var mesh := module_mesh(d["module"], false)
	for p in lay["panels"]:
		var mi := MeshInstance3D.new()
		mi.name = "Module%d" % int(p["index"])
		mi.mesh = mesh
		mi.transform = p["xf"]
		mi.set_meta("skip_prop_collision", true)
		StructureUnits.tag_piece(mi, "sheets", ["a module", "modules"], 3)
		var hi := int(p["head"])
		if hi < 0:
			root.add_child(mi)
		else:
			(head_nodes[hi] as Node3D).add_child(mi)
	var orders := {"foot": 0, "pole": 0, "leg": 0, "ballast": 0, "base": 0, "standoff": 0, "bearing": 1,
		"brace": 1, "tube": 1, "purlin": 1, "rail": 2, "mrail": 2}
	var words := {"foot": ["a ground screw", "ground screws"], "pole": ["the pole", "poles"],
		"leg": ["a leg", "legs"], "ballast": ["a ballast block", "ballast blocks"], "base": ["a tray", "trays"],
		"standoff": ["an L-foot", "L-feet"], "bearing": ["a bearing", "bearings"], "brace": ["a brace", "braces"],
		"tube": ["the torque tube", "torque tubes"], "purlin": ["a purlin", "purlins"], "rail": ["a rail", "rails"],
		"mrail": ["a module rail", "module rails"]}
	var s: Dictionary = d["spec"]
	for mb in d["members"]:
		var look := str(PvLabRack.profile(str(mb["profile"]))["look"])
		var acc := _Acc.new()
		_member_mesh(acc, mb)
		var pm := ArrayMesh.new()
		_commit_to(pm, acc, look_material(look, s))
		if pm.get_surface_count() == 0:
			continue
		var mi2 := MeshInstance3D.new()
		mi2.mesh = pm
		mi2.set_meta("skip_prop_collision", true)
		var kind := str(mb["kind"])
		var pk := "beams" if kind in ["rail", "purlin", "tube", "brace", "mrail"] else ("frames" if kind in ["leg", "pole"] else "parts")
		StructureUnits.tag_piece(mi2, pk, words.get(kind, ["a part", "parts"]), int(orders.get(kind, 1)))
		var hi2 := int(mb["head"])
		if hi2 < 0:
			root.add_child(mi2)
		else:
			(head_nodes[hi2] as Node3D).add_child(mi2)
	# Hardware: footings first, then the joints, the rail fittings, and the
	# clamps with the modules they hold.
	var part_orders := {"ground_screw": 0, "pier": 0, "base_plate": 0, "post_base": 0, "ballast_bracket": 0,
		"l_foot": 0, "pole_cap": 0, "bearing": 1, "slew_drive": 1, "post_bracket": 1, "post_cap": 1,
		"strut_gusset": 1, "rail_bracket": 2, "strut_fitting": 2, "hurricane_tie": 2, "u_bolt": 2,
		"brace_bolt": 2, "rail_splice": 2, "end_cap": 2, "ground_lug": 2, "tube_clamp": 2}
	for hp in d.get("parts", []):
		var accs := {}
		emit_part(accs, hp)
		var hm := ArrayMesh.new()
		for look in accs:
			_commit_to(hm, accs[look], look_material(str(look), s))
		if hm.get_surface_count() == 0:
			continue
		var mi3 := MeshInstance3D.new()
		mi3.mesh = hm
		mi3.set_meta("skip_prop_collision", true)
		var lab := str(PvLabHardware.part(str(hp["type"]))["label"]).to_lower()
		StructureUnits.tag_piece(mi3, "parts", ["a " + lab, lab + "s"], int(part_orders.get(str(hp["type"]), 3)))
		var hi3 := int(hp["head"])
		if hi3 < 0:
			root.add_child(mi3)
		else:
			(head_nodes[hi3] as Node3D).add_child(mi3)


static func _apply_ghost(root: Node) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GHOST_TINT
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D and n.name != "CollisionMesh":
			(n as GeometryInstance3D).material_override = mat
		for c in n.get_children():
			stack.append(c)


## Ray pick against the modules, in the array's frame: {panel, t} or {}.
static func pick_panel(d: Dictionary, origin: Vector3, dir: Vector3, tracker_deg: float = 0.0) -> Dictionary:
	var lay: Dictionary = d["layout"]
	var m: Dictionary = d["module"]
	var half := Vector3(float(m["dims_mm"]["w"]) * 0.0005, maxf(float(m["dims_mm"]["t"]) * 0.0005, 0.01),
		float(m["dims_mm"]["h"]) * 0.0005)
	var best := {}
	var best_t := INF
	for p in lay["panels"]:
		var xf := PvLabArray.panel_xf(lay, p, tracker_deg)
		var inv := xf.affine_inverse()
		var o := inv * origin
		var dd := inv.basis * dir
		var t := _ray_box(o, dd, half)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = {"panel": int(p["index"]), "t": t}
	return best


static func _ray_box(o: Vector3, d: Vector3, half: Vector3) -> float:
	var tmin := -INF
	var tmax := INF
	for i in 3:
		if absf(d[i]) < 1e-9:
			if absf(o[i]) > half[i]:
				return -1.0
			continue
		var t1 := (-half[i] - o[i]) / d[i]
		var t2 := (half[i] - o[i]) / d[i]
		tmin = maxf(tmin, minf(t1, t2))
		tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)


## Triangle soup with explicit normals. Godot's front face is CLOCKWISE seen
## from outside — cross(b − a, c − a) · n < 0 — and tri() swaps any
## triangle given the other way round, so emitters only need the normal.
class _Acc:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()

	func tri(a: Vector3, b: Vector3, c: Vector3, nrm: Vector3, ua := Vector2.ZERO, ub := Vector2.ZERO,
			uc := Vector2.ZERO) -> void:
		if (b - a).cross(c - a).dot(nrm) > 0.0:
			v.append_array([a, c, b])
			uv.append_array([ua, uc, ub])
		else:
			v.append_array([a, b, c])
			uv.append_array([ua, ub, uc])
		var nn := nrm.normalized()
		n.append_array([nn, nn, nn])

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3) -> void:
		tri(a, b, c, nrm)
		tri(a, c, d, nrm)

	func quad_uv(a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3, ua: Vector2, ub: Vector2,
			uc: Vector2, ud: Vector2) -> void:
		tri(a, b, c, nrm, ua, ub, uc)
		tri(a, c, d, nrm, ua, uc, ud)
