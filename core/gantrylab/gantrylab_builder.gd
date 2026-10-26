class_name GantryLabBuilder
extends Node3D

## The gantry in 3D, built from GantryLabFrame's layout: the static frame as
## one "Mesh" (V-slot extrusions with their grooves, plates, motors, rails,
## screws, the bed, the board, enclosure panels), one Node3D per moving
## assembly parented as the layout says, the belts and delta arms rebuilt
## whenever the tool moves, and three DRIVER nodes — XDrive / YDrive /
## ZDrive — whose local position along their axis IS the tool position in
## metres. A job runtime moves the drivers; the builder turns them into the
## kinematics (CoreXY belts, delta carriages, a sliding bed) every frame.
##
## Machine frame: X → local +X, Y → local +Z, Z up. `set_tool_mm` is the one
## way to pose it (the modal calls it; `_process` calls it when a driver
## moved). Beads: `set_toolpath_preview` lays a MultiMesh of extruded points
## on the bed node (it rides a sliding or dropping bed) at TRUE scale and
## `set_preview_progress` reveals them in print order.
##
## Picking: `pick(node, origin, dir)` over per-part AABBs (machine space,
## assemblies by their live pose) → {kind, label, assembly}.

const MODEL_ID := "gantry_machine"
const MIN_BEAD_M := 0.0015
const MAX_BEADS := 4000

static var _mat_cache := {}

var _spec: Dictionary = {}
var _layout: Dictionary = {}
var _tool_mm := Vector3.ZERO
var _asm_nodes: Dictionary = {}
var _dynamic: MeshInstance3D = null
var _beads: MultiMeshInstance3D = null
var _bead_total := 0
var _drivers: Dictionary = {}
var _last_driver := Vector3(INF, INF, INF)
var _ghost := false
var _record := false
var _picks: Array = []
var follow_drivers := true


static func build_node(spec: Dictionary = {}, node_name: String = "GantryMachine", opts: Dictionary = {}) -> Node3D:
	var b := GantryLabBuilder.new()
	b.name = node_name
	b._ghost = bool(opts.get("ghost_highlight", false))
	b._record = bool(opts.get("record", false))
	b._build(GantryLabSpec.resolve(spec))
	return b


static func build_from_design(d: Dictionary, node_name: String = "GantryMachine", opts: Dictionary = {}) -> Node3D:
	return build_node(d["spec"], node_name, opts)


func spec() -> Dictionary:
	return _spec


func layout() -> Dictionary:
	return _layout


func tool_mm() -> Vector3:
	return _tool_mm


func _build(s: Dictionary) -> void:
	_spec = s
	set_meta("gantry_spec", GantryLabSpec.to_json_safe(s))
	_layout = GantryLabFrame.layout(s)
	var dims: Vector3 = _layout["dims"]
	set_meta("size_m", dims)
	set_meta("work_origin", _layout["origin"])
	var cols: Dictionary = s["colors"]
	# Static frame.
	var st := _mesh_for(_layout["static"]["beams"], _layout["static"]["parts"], _static_screws(), cols)
	st.name = "Mesh"
	add_child(st)
	_record_picks(_layout["static"]["beams"], _layout["static"]["parts"], "")
	# Assemblies, parents first.
	var asms: Dictionary = _layout["assemblies"]
	var order: Array = []
	for name in asms:
		_order_assembly(asms, str(name), order)
	for name in order:
		var asm: Dictionary = asms[name]
		var n := Node3D.new()
		n.name = str(name)
		var parent_name := str(asm.get("parent", ""))
		var parent: Node = _asm_nodes.get(parent_name, self) if not parent_name.is_empty() else self
		parent.add_child(n)
		n.position = asm["base"]
		var mi := _mesh_for(asm["beams"], asm["parts"], _assembly_screws(str(name)), cols)
		mi.name = "Mesh"
		mi.set_meta("skip_prop_collision", true)
		n.add_child(mi)
		_asm_nodes[name] = n
		_record_picks(asm["beams"], asm["parts"], str(name))
	# Belts and arms, rebuilt per pose.
	_dynamic = MeshInstance3D.new()
	_dynamic.name = "Belts"
	_dynamic.set_meta("skip_prop_collision", true)
	_dynamic.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dynamic)
	# Drivers: a Node3D per axis the job runtime slides.
	for k in ["x", "y", "z"]:
		var dn := Node3D.new()
		dn.name = "%sDrive" % k.to_upper()
		add_child(dn)
		_drivers[k] = dn
	set_tool_mm(Vector3.ZERO)
	if _record:
		set_meta("picks", _picks)


func _order_assembly(asms: Dictionary, name: String, order: Array) -> void:
	if order.has(name):
		return
	var parent := str((asms[name] as Dictionary).get("parent", ""))
	if not parent.is_empty() and asms.has(parent):
		_order_assembly(asms, parent, order)
	order.append(name)


func _static_screws() -> Array:
	var out: Array = []
	for sc in _layout["screws"]:
		if str((sc as Dictionary).get("assembly", "")).is_empty():
			out.append(sc)
	return out


func _assembly_screws(name: String) -> Array:
	var out: Array = []
	for sc in _layout["screws"]:
		if str((sc as Dictionary).get("assembly", "")) == name:
			out.append(sc)
	return out


# ---------------------------------------------------------------------------
# Pose
# ---------------------------------------------------------------------------

## The one way to pose the machine: tool position in work mm.
func set_tool_mm(mm: Vector3) -> void:
	_tool_mm = mm
	var po := GantryLabFrame.pose(_spec, _layout, mm)
	for name in _asm_nodes:
		var n: Node3D = _asm_nodes[name]
		var asm: Dictionary = _layout["assemblies"][name]
		n.position = (asm["base"] as Vector3) + (po.get(name, Vector3.ZERO) as Vector3)
	_rebuild_dynamic(po)


func _process(_delta: float) -> void:
	if not follow_drivers or _drivers.is_empty():
		return
	var v := Vector3((_drivers["x"] as Node3D).position.x, (_drivers["y"] as Node3D).position.z, (_drivers["z"] as Node3D).position.y)
	if v.distance_squared_to(_last_driver) > 1e-12 or not is_finite(_last_driver.x):
		_last_driver = v
		set_tool_mm(v * 1000.0)


## Drive the machine from code the way a runtime would (sets the drivers).
func set_drivers_mm(mm: Vector3) -> void:
	if _drivers.is_empty():
		return
	(_drivers["x"] as Node3D).position = Vector3(mm.x * 0.001, 0, 0)
	(_drivers["y"] as Node3D).position = Vector3(0, 0, mm.y * 0.001)
	(_drivers["z"] as Node3D).position = Vector3(0, mm.z * 0.001, 0)


func _rebuild_dynamic(po: Dictionary) -> void:
	if _dynamic == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for b in GantryLabFrame.belt_routes(_spec, _layout, po):
		var pts: PackedVector3Array = b["points"]
		var w := 0.006
		for i in pts.size():
			var a := pts[i]
			var c := pts[(i + 1) % pts.size()]
			_bar(st, a, c, w, 0.0015)
			any = true
	for arm in GantryLabFrame.delta_arms(_layout, po):
		_bar(st, (arm as Array)[0], (arm as Array)[1], 0.006, 0.006, true)
		any = true
	if not any:
		_dynamic.mesh = null
		return
	st.generate_normals()
	var mesh := ArrayMesh.new()
	var arrays := st.commit_to_arrays()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material("belt", _spec["colors"]))
	_dynamic.mesh = mesh


# ---------------------------------------------------------------------------
# Toolpath preview (beads on the bed)
# ---------------------------------------------------------------------------

func bead_parent() -> Node3D:
	var pname := str(_layout.get("bead_parent", ""))
	if not pname.is_empty() and _asm_nodes.has(pname):
		return _asm_nodes[pname]
	return self


## Lay the extruding points of a toolpath (mm, work coordinates) as beads
## under the bed node at true scale. `extruding` may be empty (every point).
func set_toolpath_preview(points: PackedVector3Array, extruding: PackedInt32Array, line_mm: float, color: Color) -> void:
	clear_toolpath_preview()
	if points.size() < 2:
		return
	var idx: PackedInt32Array = PackedInt32Array()
	var has_ext := extruding.size() == points.size()
	for i in points.size():
		if not has_ext or extruding[i] != 0:
			idx.append(i)
	if idx.is_empty():
		for i in points.size():
			idx.append(i)
	var stride := maxi(1, int(ceil(float(idx.size()) / float(MAX_BEADS))))
	var sel: PackedInt32Array = PackedInt32Array()
	var j := 0
	while j < idx.size():
		sel.append(idx[j])
		j += stride
	var cell := maxf(line_mm * 0.001, MIN_BEAD_M)
	var box := BoxMesh.new()
	box.size = Vector3(cell, cell * 0.8, cell)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = sel.size()
	var o: Vector3 = _layout["bead_origin"]
	for n in sel.size():
		var p := points[sel[n]]
		mm.set_instance_transform(n, Transform3D(Basis(), o + Vector3(p.x, p.z, p.y) * 0.001 + Vector3(0, cell * 0.4, 0)))
	mm.visible_instance_count = 0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	_beads = MultiMeshInstance3D.new()
	_beads.name = "Beads"
	_beads.multimesh = mm
	_beads.material_override = mat
	_beads.set_meta("skip_prop_collision", true)
	_beads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bead_parent().add_child(_beads)
	_bead_total = sel.size()


func set_preview_progress(frac: float) -> void:
	if _beads == null or _beads.multimesh == null:
		return
	_beads.multimesh.visible_instance_count = clampi(int(round(float(_bead_total) * clampf(frac, 0.0, 1.0))), 0, _bead_total)


func clear_toolpath_preview() -> void:
	if _beads != null and is_instance_valid(_beads):
		_beads.get_parent().remove_child(_beads)
		_beads.queue_free()
	_beads = null
	_bead_total = 0


## Work mm → local metres (the tool tip's spot in this node's frame).
func work_to_local(mm: Vector3) -> Vector3:
	var o: Vector3 = _layout["origin"]
	return o + Vector3(mm.x, mm.z, mm.y) * 0.001


# ---------------------------------------------------------------------------
# Meshing
# ---------------------------------------------------------------------------

func _mesh_for(beams: Array, parts: Array, screws: Array, cols: Dictionary) -> MeshInstance3D:
	var sts: Dictionary = {}
	for b in beams:
		var bd: Dictionary = b
		_extrusion(_st(sts, "frame"), bd)
	for p in parts:
		var pd: Dictionary = p
		var kind := str(pd["kind"])
		var key := kind
		if kind == "bed_round":
			_cylinder(_st(sts, "bed"), (pd["c"] as Vector3) + Vector3(0, -(pd["s"] as Vector3).y * 0.5, 0), (pd["c"] as Vector3) + Vector3(0, (pd["s"] as Vector3).y * 0.5, 0), (pd["s"] as Vector3).x * 0.5, 36)
			continue
		if kind == "motor":
			_box(_st(sts, "motor"), pd["c"], pd["s"])
			# The shaft.
			var c: Vector3 = pd["c"]
			var sz: Vector3 = pd["s"]
			_cylinder(_st(sts, "rail"), c + Vector3(0, sz.y * 0.5, 0), c + Vector3(0, sz.y * 0.5 + 0.012, 0), 0.0025, 8)
			continue
		_box(_st(sts, key), pd["c"], pd["s"])
	for sc in screws:
		var sd: Dictionary = sc
		_cylinder(_st(sts, "rail"), sd["a"], sd["b"], float(sd["d_mm"]) * 0.0005, 8)
	var mesh := ArrayMesh.new()
	for key in ["frame", "plate", "motor", "rail", "bed", "tool", "board", "panel"]:
		if not sts.has(key):
			continue
		var st: SurfaceTool = sts[key]
		st.generate_normals()
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(key, cols))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _st(sts: Dictionary, key: String) -> SurfaceTool:
	if not sts.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		sts[key] = st
	return sts[key]


## A V-slot extrusion between a and b: the profile's rectangle with a 6 mm
## groove every 20 mm cell on every face, extruded along the beam.
func _extrusion(st: SurfaceTool, bd: Dictionary) -> void:
	var a: Vector3 = bd["a"]
	var b: Vector3 = bd["b"]
	var p := GantryLabParts.profile(str(bd["profile"]))
	var w := float(p["w_mm"]) * 0.001
	var h := float(p["h_mm"]) * 0.001
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	axis /= L
	var up: Vector3 = bd.get("up", Vector3.UP)
	var u := up - axis * up.dot(axis)
	if u.length() < 1e-6:
		u = Vector3.FORWARD - axis * Vector3.FORWARD.dot(axis)
	if u.length() < 1e-6:
		u = Vector3.RIGHT
	u = u.normalized()
	var v := axis.cross(u).normalized()
	# Cross-section outline in (v, u): width along v, height along u.
	var outline := _vslot_outline(w, h)
	var n := outline.size()
	for i in n:
		var p0: Vector2 = outline[i]
		var p1: Vector2 = outline[(i + 1) % n]
		var e := p1 - p0
		var nrm2 := Vector2(e.y, -e.x).normalized()
		var nrm := (v * nrm2.x + u * nrm2.y).normalized()
		var q0 := a + v * p0.x + u * p0.y
		var q1 := a + v * p1.x + u * p1.y
		_quad(st, q0, q0 + axis * L, q1 + axis * L, q1, nrm)
	# End caps from a triangulation of the outline.
	var tris := Geometry2D.triangulate_polygon(outline)
	for t in range(0, tris.size() - 2, 3):
		var c0: Vector2 = outline[tris[t]]
		var c1: Vector2 = outline[tris[t + 1]]
		var c2: Vector2 = outline[tris[t + 2]]
		_tri(st, a + v * c0.x + u * c0.y, a + v * c1.x + u * c1.y, a + v * c2.x + u * c2.y, -axis)
		_tri(st, b + v * c0.x + u * c0.y, b + v * c2.x + u * c2.y, b + v * c1.x + u * c1.y, axis)


static func _vslot_outline(w: float, h: float) -> PackedVector2Array:
	var slot_w := 0.0062
	var slot_d := 0.0055
	var out := PackedVector2Array()
	var hw := w * 0.5
	var hh := h * 0.5
	# Walk counter-clockwise: bottom edge (y = -hh) left→right, right edge up,
	# top edge right→left, left edge down; a groove per 20 mm cell on each.
	var cells_w := maxi(1, int(round(w / 0.02)))
	var cells_h := maxi(1, int(round(h / 0.02)))
	# bottom
	out.append(Vector2(-hw, -hh))
	for i in cells_w:
		var cx := -hw + 0.02 * (i + 0.5)
		out.append(Vector2(cx - slot_w * 0.5, -hh))
		out.append(Vector2(cx - slot_w * 0.5, -hh + slot_d))
		out.append(Vector2(cx + slot_w * 0.5, -hh + slot_d))
		out.append(Vector2(cx + slot_w * 0.5, -hh))
	out.append(Vector2(hw, -hh))
	# right
	for i in cells_h:
		var cy := -hh + 0.02 * (i + 0.5)
		out.append(Vector2(hw, cy - slot_w * 0.5))
		out.append(Vector2(hw - slot_d, cy - slot_w * 0.5))
		out.append(Vector2(hw - slot_d, cy + slot_w * 0.5))
		out.append(Vector2(hw, cy + slot_w * 0.5))
	out.append(Vector2(hw, hh))
	# top
	for i in cells_w:
		var cx := hw - 0.02 * (i + 0.5)
		out.append(Vector2(cx + slot_w * 0.5, hh))
		out.append(Vector2(cx + slot_w * 0.5, hh - slot_d))
		out.append(Vector2(cx - slot_w * 0.5, hh - slot_d))
		out.append(Vector2(cx - slot_w * 0.5, hh))
	out.append(Vector2(-hw, hh))
	# left
	for i in cells_h:
		var cy := hh - 0.02 * (i + 0.5)
		out.append(Vector2(-hw, cy + slot_w * 0.5))
		out.append(Vector2(-hw + slot_d, cy + slot_w * 0.5))
		out.append(Vector2(-hw + slot_d, cy - slot_w * 0.5))
		out.append(Vector2(-hw, cy - slot_w * 0.5))
	return out


func _box(st: SurfaceTool, c: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var p := [c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(-h.x, h.y, -h.z),
		c + Vector3(-h.x, -h.y, h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z)]
	_quad(st, p[0], p[1], p[2], p[3], Vector3(0, 0, -1))
	_quad(st, p[5], p[4], p[7], p[6], Vector3(0, 0, 1))
	_quad(st, p[4], p[0], p[3], p[7], Vector3(-1, 0, 0))
	_quad(st, p[1], p[5], p[6], p[2], Vector3(1, 0, 0))
	_quad(st, p[3], p[2], p[6], p[7], Vector3(0, 1, 0))
	_quad(st, p[4], p[5], p[1], p[0], Vector3(0, -1, 0))


## A rectangular bar from a to b, w wide (horizontal-ish) and t thick.
func _bar(st: SurfaceTool, a: Vector3, b: Vector3, w: float, t: float, round_: bool = false) -> void:
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	axis /= L
	var u := Vector3.UP - axis * Vector3.UP.dot(axis)
	if u.length() < 1e-6:
		u = Vector3.RIGHT - axis * Vector3.RIGHT.dot(axis)
	u = u.normalized()
	var v := axis.cross(u).normalized()
	var ring: Array = []
	if round_:
		for i in 8:
			var ang := TAU * i / 8
			ring.append(u * (cos(ang) * w * 0.5) + v * (sin(ang) * w * 0.5))
	else:
		ring = [v * (w * 0.5) + u * (t * 0.5), v * (-w * 0.5) + u * (t * 0.5), v * (-w * 0.5) + u * (-t * 0.5), v * (w * 0.5) + u * (-t * 0.5)]
	var n := ring.size()
	for i in n:
		var r0: Vector3 = ring[i]
		var r1: Vector3 = ring[(i + 1) % n]
		_quad(st, a + r0, b + r0, b + r1, a + r1, (r0 + r1).normalized())


func _cylinder(st: SurfaceTool, a: Vector3, b: Vector3, r: float, sides: int) -> void:
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	axis /= L
	var u := Vector3.UP - axis * Vector3.UP.dot(axis)
	if u.length() < 1e-6:
		u = Vector3.RIGHT - axis * Vector3.RIGHT.dot(axis)
	u = u.normalized()
	var v := axis.cross(u).normalized()
	var ring: Array = []
	for i in sides:
		var ang := TAU * i / sides
		ring.append(u * (cos(ang) * r) + v * (sin(ang) * r))
	for i in sides:
		var r0: Vector3 = ring[i]
		var r1: Vector3 = ring[(i + 1) % sides]
		_quad(st, a + r0, b + r0, b + r1, a + r1, (r0 + r1).normalized())
	for i in range(1, sides - 1):
		_tri(st, a + ring[0], a + ring[i + 1], a + ring[i], -axis)
		_tri(st, b + ring[0], b + ring[i], b + ring[i + 1], axis)


func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3) -> void:
	_tri(st, p0, p1, p2, n)
	_tri(st, p0, p2, p3, n)


func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, n: Vector3) -> void:
	# Godot's front face winds clockwise seen from outside.
	var g := (p1 - p0).cross(p2 - p0)
	if g.dot(n) > 0.0:
		var tmp := p1
		p1 = p2
		p2 = tmp
	st.set_normal(n)
	st.add_vertex(p0)
	st.set_normal(n)
	st.add_vertex(p1)
	st.set_normal(n)
	st.add_vertex(p2)


func _material(key: String, cols: Dictionary) -> Material:
	var ck := "%s|%s|%s" % [key, str(cols.get("frame", "")), "g" if _ghost else "s"]
	if _mat_cache.has(ck):
		return _mat_cache[ck]
	var m: StandardMaterial3D
	match key:
		"frame":
			m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, cols.get("frame", Color(0.16, 0.17, 0.19)))
		"plate":
			m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, cols.get("plate", Color(0.72, 0.74, 0.78)))
		"motor":
			m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.09, 0.09, 0.1))
		"rail":
			m = StandardMaterial3D.new()
			m.albedo_color = Color(0.82, 0.83, 0.85)
			m.metallic = 0.9
			m.roughness = 0.25
		"bed":
			m = StructureMaterials.make(StructureMaterials.Kind.PANEL, cols.get("bed", Color(0.22, 0.23, 0.26)))
		"tool":
			var tool := GantryLabParts.tool(str(_spec["tool"]["id"]))
			var tc := Color(0.75, 0.3, 0.2)
			match str(tool["process"]):
				"subtractive":
					tc = Color(0.3, 0.45, 0.7)
				"mark":
					tc = Color(0.5, 0.25, 0.7)
			m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, tc)
		"board":
			m = StructureMaterials.make(StructureMaterials.Kind.PANEL, Color(0.1, 0.35, 0.2))
		"panel":
			m = StandardMaterial3D.new()
			m.albedo_color = Color(0.7, 0.8, 0.9, 0.3)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		"belt":
			m = StandardMaterial3D.new()
			m.albedo_color = cols.get("belt", Color(0.08, 0.08, 0.09))
			m.roughness = 0.9
		_:
			m = StandardMaterial3D.new()
	if _ghost:
		m = m.duplicate()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(m.albedo_color.r, m.albedo_color.g, m.albedo_color.b, 0.55)
		m.emission_enabled = true
		m.emission = Color(0.2, 0.7, 0.9) * 0.25
	_mat_cache[ck] = m
	return m


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

func _record_picks(beams: Array, parts: Array, assembly: String) -> void:
	if not _record:
		return
	for b in beams:
		var bd: Dictionary = b
		var a: Vector3 = bd["a"]
		var c: Vector3 = bd["b"]
		var p := GantryLabParts.profile(str(bd["profile"]))
		var r := maxf(float(p["w_mm"]), float(p["h_mm"])) * 0.0005
		var lo := Vector3(minf(a.x, c.x), minf(a.y, c.y), minf(a.z, c.z)) - Vector3.ONE * r
		var hi := Vector3(maxf(a.x, c.x), maxf(a.y, c.y), maxf(a.z, c.z)) + Vector3.ONE * r
		_picks.append({"kind": "beam", "label": "%s (%s, %.0f mm)" % [str(bd["label"]), str(p["label"]), a.distance_to(c) * 1000.0], "aabb": AABB(lo, hi - lo), "assembly": assembly, "group": str(bd["group"])})
	for pt in parts:
		var pd: Dictionary = pt
		var s: Vector3 = pd["s"]
		_picks.append({"kind": str(pd["kind"]), "label": str(pd["label"]), "aabb": AABB((pd["c"] as Vector3) - s * 0.5, s), "assembly": assembly, "group": ""})


func _asm_local_transform(name: String) -> Transform3D:
	var n: Node3D = _asm_nodes.get(name, null)
	if n == null:
		return Transform3D.IDENTITY
	var xf := n.transform
	var parent := str((_layout["assemblies"][name] as Dictionary).get("parent", ""))
	if not parent.is_empty():
		xf = _asm_local_transform(parent) * xf
	return xf


## Nearest picked part along a ray in the builder's LOCAL frame.
static func pick(node: Node3D, origin: Vector3, dir: Vector3) -> Dictionary:
	if node == null or not node.has_meta("picks"):
		return {}
	var b := node as GantryLabBuilder
	var best := {}
	var best_t := INF
	for p in node.get_meta("picks"):
		var pd: Dictionary = p
		var o := origin
		var d := dir
		var asm := str(pd["assembly"])
		if not asm.is_empty() and b != null and b._asm_nodes.has(asm):
			# The assembly's transform relative to the builder, from LOCAL
			# transforms (a studio node may be picked before it is in a tree).
			var xf := b._asm_local_transform(asm).affine_inverse()
			o = xf * origin
			d = (xf.basis * dir).normalized()
		var hit: Variant = (pd["aabb"] as AABB).intersects_ray(o, d)
		if hit == null:
			continue
		var t := (hit as Vector3).distance_to(o)
		if t < best_t:
			best_t = t
			best = {"kind": str(pd["kind"]), "label": str(pd["label"]), "assembly": asm, "group": str(pd["group"]), "t": t}
	return best
