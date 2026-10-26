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
var _spins: Array = []
var _belt_mats: Array = []
var follow_drivers := true

const _BELT_SHADER := preload("res://core/gantrylab/gantry_belt.gdshader")
const _THREAD_SHADER := preload("res://core/gantrylab/gantry_thread.gdshader")


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
	_spin_nodes(_layout["static"]["parts"], self, cols)
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
		_spin_nodes(asm["parts"], n, cols)
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
	# Every pulley, idler, screw, coupler and wheel turns by its motor's
	# displacement over its own circumference / lead.
	var mmm := GantryLabFrame.motor_mm(_spec, mm)
	for sp in _spins:
		var spd: Dictionary = sp
		var spin: Dictionary = spd["spin"]
		var idx := clampi(int(spin["motor"]), 0, mmm.size() - 1)
		var ang := float(spin["sign"]) * float(mmm[idx]) / maxf(float(spin["per_rev_mm"]), 1e-6) * TAU
		(spd["node"] as Node3D).transform = (spd["base"] as Transform3D) * Transform3D(Basis(Vector3.UP, ang), Vector3.ZERO)
	_rebuild_dynamic(po, mmm)


## A node per spinning part, built in its own frame so the thread shader's
## +Y is the axis; `base` seats it, the pose adds the turn.
func _spin_nodes(parts: Array, parent: Node3D, cols: Dictionary) -> void:
	for p in parts:
		var pd: Dictionary = p
		if not pd.has("spin"):
			continue
		var sts: Dictionary = {}
		GantryLabDetail.emit(sts, pd, true)
		var mi := _commit(sts, cols)
		mi.name = "Spin_%s" % str(pd["label"]).validate_node_name()
		mi.set_meta("skip_prop_collision", true)
		var base := Transform3D(pd.get("basis", Basis.IDENTITY), pd["c"])
		mi.transform = base
		parent.add_child(mi)
		_spins.append({"node": mi, "base": base, "spin": pd["spin"]})


## How many parts turn (probes).
func spin_count() -> int:
	return _spins.size()


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


func _rebuild_dynamic(po: Dictionary, mm: PackedFloat32Array = PackedFloat32Array()) -> void:
	if _dynamic == null:
		return
	var mesh := ArrayMesh.new()
	var cols: Dictionary = _spec["colors"]
	# One surface per belt loop: its own material carries the tooth scroll.
	var bi := 0
	for b in GantryLabFrame.belt_routes(_spec, _layout, po):
		var bd: Dictionary = b
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		GantryLabDetail.ribbon(st, bd["points"], bd["n"], float(bd["w"]), GantryLabDetail.BELT_THICK, float(bd["inside"]))
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		while _belt_mats.size() <= bi:
			var m := ShaderMaterial.new()
			m.shader = _BELT_SHADER
			m.set_shader_parameter("albedo", cols.get("belt", Color(0.07, 0.07, 0.08)))
			_belt_mats.append(m)
		var bm: ShaderMaterial = _belt_mats[bi]
		var idx := clampi(int(bd["motor"]), 0, maxi(mm.size() - 1, 0))
		var travel := (float(mm[idx]) * 0.001 if mm.size() > 0 else 0.0) * float(bd["sign"])
		bm.set_shader_parameter("offset_m", travel)
		bm.set_shader_parameter("pitch_m", 0.003 if str(GantryLabParts.drive(str(_spec["axis"]["x"]["drive"]))["label"]).begins_with("GT3") else 0.002)
		mesh.surface_set_material(mesh.get_surface_count() - 1, bm)
		bi += 1
	# Bowden tube, filament, delta arms.
	var sts: Dictionary = {}
	for lk in GantryLabFrame.link_routes(_layout, po):
		var ld: Dictionary = lk
		GantryLabDetail.tube(GantryLabDetail._st(sts, "tube" if str(ld["kind"]) == "bowden" else "filament"), ld["points"], float(ld["r"]), 8 if str(ld["kind"]) == "bowden" else 5)
	for arm in GantryLabFrame.delta_arms(_layout, po):
		GantryLabDetail.tube(GantryLabDetail._st(sts, "carbon"), PackedVector3Array([(arm as Array)[0], (arm as Array)[1]]), 0.003, 8)
	for key in sts:
		var st: SurfaceTool = sts[key]
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(str(key), cols))
	_dynamic.mesh = mesh if mesh.get_surface_count() > 0 else null


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


# ---------------------------------------------------------------------------
# Marks: a part highlighted (selection, hover, clash) or a ghost (a part the
# editor is about to place). They ride their assembly's node, so they follow
# the jog; drawn see-through so a part inside the frame still shows.
# ---------------------------------------------------------------------------

var _marks: Dictionary = {}
static var _mark_mats := {}


func clear_marks(tag: String = "") -> void:
	for k in _marks.keys():
		if tag.is_empty() or str(k).begins_with(tag + ":"):
			var n: Node = _marks[k]
			if is_instance_valid(n):
				n.get_parent().remove_child(n)
				n.queue_free()
			_marks.erase(k)


static func _mark_mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if _mark_mats.has(key):
		return _mark_mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_BACK
	m.render_priority = 2
	_mark_mats[key] = m
	return m


## The beams and part dicts that belong to a part id, and its assembly.
func part_items(id: String) -> Dictionary:
	var out := {"asm": "", "beams": [], "parts": []}
	if id.is_empty():
		return out
	var groups: Array = [["", _layout["static"]]]
	for name in _layout["assemblies"]:
		groups.append([str(name), _layout["assemblies"][name]])
	for g in groups:
		var gd: Dictionary = g[1]
		for b in gd["beams"]:
			if str((b as Dictionary).get("id", "")) == id:
				out["beams"].append(b)
				out["asm"] = g[0]
		for p in gd["parts"]:
			if str((p as Dictionary).get("id", "")) == id:
				out["parts"].append(p)
				out["asm"] = g[0]
	return out


func _overlay_mesh(beams: Array, parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in beams:
		var bd: Dictionary = b
		GantryLabDetail.extrusion(st, bd["a"], bd["b"], str(bd["profile"]), bd.get("up", Vector3.UP))
	for p in parts:
		var tmp: Dictionary = {}
		GantryLabDetail.emit(tmp, p)
		for k in tmp:
			var arr := (tmp[k] as SurfaceTool).commit_to_arrays()
			var vs: Variant = arr[Mesh.ARRAY_VERTEX]
			var ns: Variant = arr[Mesh.ARRAY_NORMAL]
			if vs == null:
				continue
			var vv: PackedVector3Array = vs
			for i in vv.size():
				if ns != null:
					st.set_normal((ns as PackedVector3Array)[i])
				st.add_vertex(vv[i])
	return st.commit()


## Highlight a part by id in a colour (tag groups marks: "sel", "hover", "clash").
func mark_part(tag: String, id: String, color: Color) -> void:
	var key := "%s:%s" % [tag, id]
	if _marks.has(key):
		return
	var it := part_items(id)
	if (it["beams"] as Array).is_empty() and (it["parts"] as Array).is_empty():
		return
	var mi := MeshInstance3D.new()
	mi.name = "Mark_%s" % key.validate_node_name()
	mi.mesh = _overlay_mesh(it["beams"], it["parts"])
	mi.material_override = _mark_mat(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("skip_prop_collision", true)
	var parent: Node3D = _asm_nodes.get(str(it["asm"]), self) if not str(it["asm"]).is_empty() else self
	parent.add_child(mi)
	_marks[key] = mi


## A ghost from part dicts / beams already in machine space (zero pose),
## riding assembly `asm`.
func mark_ghost(tag: String, beams: Array, parts: Array, asm: String, color: Color) -> void:
	clear_marks(tag)
	var mi := MeshInstance3D.new()
	mi.name = "Ghost_%s" % tag
	mi.mesh = _overlay_mesh(beams, parts)
	mi.material_override = _mark_mat(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("skip_prop_collision", true)
	var parent: Node3D = _asm_nodes.get(asm, self) if not asm.is_empty() else self
	parent.add_child(mi)
	_marks["%s:ghost" % tag] = mi


## Where an assembly sits now (its offset from the zero pose).
func assembly_offset(asm: String) -> Vector3:
	if asm.is_empty() or not _asm_nodes.has(asm):
		return Vector3.ZERO
	var po := GantryLabFrame.pose(_spec, _layout, _tool_mm)
	return GantryLabFrame.assembly_origin(_layout, po, asm)


## Work mm → local metres (the tool tip's spot in this node's frame).
func work_to_local(mm: Vector3) -> Vector3:
	var o: Vector3 = _layout["origin"]
	return o + Vector3(mm.x, mm.z, mm.y) * 0.001


# ---------------------------------------------------------------------------
# Meshing
# ---------------------------------------------------------------------------

func _mesh_for(beams: Array, parts: Array, _screws: Array, cols: Dictionary) -> MeshInstance3D:
	var sts: Dictionary = {}
	for b in beams:
		var bd: Dictionary = b
		GantryLabDetail.extrusion(GantryLabDetail._st(sts, "frame"), bd["a"], bd["b"], str(bd["profile"]), bd.get("up", Vector3.UP))
	for p in parts:
		var pd: Dictionary = p
		if pd.has("spin"):
			continue  # its own node, see _spin_nodes
		GantryLabDetail.emit(sts, pd)
	return _commit(sts, cols)


## Every material key's SurfaceTool into one ArrayMesh (a surface each).
func _commit(sts: Dictionary, cols: Dictionary) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var keys: Array = sts.keys()
	keys.sort()
	for key in keys:
		var st: SurfaceTool = sts[key]
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(str(key), cols))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _material(key: String, cols: Dictionary) -> Material:
	var ck := "%s|%s|%s|%s" % [key, str(cols.get("frame", "")), str(cols.get("plate", "")), "g" if _ghost else "s"]
	if _mat_cache.has(ck):
		return _mat_cache[ck]
	var m: Material = _make_material(key, cols)
	if _ghost and m is StandardMaterial3D:
		var sm := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color = Color(sm.albedo_color.r, sm.albedo_color.g, sm.albedo_color.b, 0.55)
		sm.emission_enabled = true
		sm.emission = Color(0.2, 0.7, 0.9) * 0.25
		m = sm
	_mat_cache[ck] = m
	return m


static func _plain(albedo: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metallic
	m.roughness = roughness
	return m


static func _thread_mat(lead_m: float, starts: int, duty: float, depth: float, albedo: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _THREAD_SHADER
	m.set_shader_parameter("lead_m", lead_m)
	m.set_shader_parameter("starts", starts)
	m.set_shader_parameter("duty", duty)
	m.set_shader_parameter("depth", depth)
	m.set_shader_parameter("albedo", albedo)
	return m


func _make_material(key: String, cols: Dictionary) -> Material:
	if key.begins_with("thread|"):
		# thread|<lead m>|<starts>
		var parts := key.split("|")
		return _thread_mat(float(parts[1]) if parts.size() > 1 else 0.008, int(parts[2]) if parts.size() > 2 else 4, 0.5, 0.7, Color(0.78, 0.79, 0.8))
	match key:
		"frame":
			return StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, cols.get("frame", Color(0.16, 0.17, 0.19)))
		"plate":
			return StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, cols.get("plate", Color(0.72, 0.74, 0.78)))
		"motor":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.09, 0.09, 0.1))
		"alu":
			return _plain(Color(0.8, 0.81, 0.83), 0.85, 0.35)
		"chrome", "rail":
			return _plain(Color(0.84, 0.85, 0.87), 0.95, 0.2)
		"steel":
			return _plain(Color(0.22, 0.22, 0.24), 0.7, 0.45)
		"black":
			return StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.08, 0.08, 0.09))
		"brass":
			return _plain(Color(0.82, 0.64, 0.3), 0.9, 0.35)
		"delrin":
			return _plain(Color(0.9, 0.9, 0.86), 0.0, 0.5)
		"pcb":
			return _plain(Color(0.1, 0.33, 0.2), 0.1, 0.6)
		"screen":
			return _plain(Color(0.08, 0.14, 0.32), 0.0, 0.3)
		"led":
			var l := _plain(Color(0.9, 0.2, 0.15), 0.0, 0.5)
			l.emission_enabled = true
			l.emission = Color(0.8, 0.1, 0.05)
			return l
		"blue":
			return _plain(Color(0.2, 0.35, 0.75), 0.6, 0.5)
		"green":
			return _plain(Color(0.2, 0.55, 0.25), 0.0, 0.6)
		"white":
			return _plain(Color(0.92, 0.92, 0.9), 0.0, 0.6)
		"rubber":
			return _plain(Color(0.05, 0.05, 0.05), 0.0, 0.95)
		"galv":
			return StructureMaterials.make(StructureMaterials.Kind.GALVANISED, Color(0.7, 0.72, 0.74))
		"glass":
			var g := _plain(Color(0.75, 0.85, 0.9, 0.35), 0.0, 0.05)
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			return g
		"heater":
			return _plain(Color(0.35, 0.12, 0.1), 0.0, 0.7)
		"bed":
			return StructureMaterials.make(StructureMaterials.Kind.PANEL, cols.get("bed", Color(0.22, 0.23, 0.26)))
		"mdf":
			return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.62, 0.5, 0.36))
		"honey":
			return _plain(Color(0.75, 0.55, 0.2), 0.3, 0.7)
		"concrete":
			return _plain(Color(0.55, 0.54, 0.52), 0.0, 0.95)
		"tool":
			var tool := GantryLabParts.tool(str(_spec["tool"]["id"]))
			var tc := Color(0.75, 0.3, 0.2)
			match str(tool["process"]):
				"subtractive":
					tc = Color(0.3, 0.45, 0.7)
				"mark":
					tc = Color(0.5, 0.25, 0.7)
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, tc)
		"tool_teal":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.1, 0.5, 0.55))
		"wire_red":
			return _plain(Color(0.8, 0.12, 0.1), 0.0, 0.7)
		"board":
			return StructureMaterials.make(StructureMaterials.Kind.PANEL, Color(0.1, 0.35, 0.2))
		"panel":
			var pm := _plain(Color(0.7, 0.8, 0.9, 0.3), 0.0, 0.1)
			pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			pm.cull_mode = BaseMaterial3D.CULL_DISABLED
			return pm
		"tube":
			var t := _plain(Color(0.95, 0.95, 0.95, 0.75), 0.0, 0.3)
			t.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			return t
		"filament":
			return _plain(Color(0.9, 0.45, 0.1), 0.0, 0.4)
		"carbon":
			return _plain(Color(0.1, 0.1, 0.11), 0.3, 0.35)
		"clay":
			return _plain(Color(0.45, 0.33, 0.22), 0.0, 0.9)
		"coupler":
			return _thread_mat(0.008, 1, 0.12, 0.9, Color(0.8, 0.81, 0.83))
		"spring":
			return _thread_mat(0.0028, 1, 0.45, 1.0, Color(0.75, 0.72, 0.4))
		"belt":
			return _plain(cols.get("belt", Color(0.08, 0.08, 0.09)), 0.0, 0.9)
	return _plain(Color(0.5, 0.5, 0.5), 0.0, 0.7)


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

func _record_picks(beams: Array, parts: Array, assembly: String) -> void:
	if not _record:
		return
	var by_id := {}
	for b in beams:
		var bd: Dictionary = b
		var a: Vector3 = bd["a"]
		var c: Vector3 = bd["b"]
		var p := GantryLabParts.profile(str(bd["profile"]))
		var bb: AABB
		if bd.has("pick_aabb"):
			bb = bd["pick_aabb"]
		else:
			var r := maxf(float(p["w_mm"]), float(p["h_mm"])) * 0.0005
			var lo := Vector3(minf(a.x, c.x), minf(a.y, c.y), minf(a.z, c.z)) - Vector3.ONE * r
			var hi := Vector3(maxf(a.x, c.x), maxf(a.y, c.y), maxf(a.z, c.z)) + Vector3.ONE * r
			bb = AABB(lo, hi - lo)
		_picks.append({"kind": "beam", "label": "%s (%s, %.0f mm)" % [str(bd["label"]), str(p["label"]), a.distance_to(c) * 1000.0], "aabb": bb,
			"assembly": assembly, "group": str(bd["group"]), "id": str(bd.get("id", ""))})
	for pt in parts:
		var pd: Dictionary = pt
		if bool(pd.get("no_pick", false)):
			continue
		var bb2: AABB
		if pd.has("pick_aabb"):
			bb2 = pd["pick_aabb"]
		else:
			var s3: Vector3 = pd["s"]
			var pc: Vector3 = pd.get("pick_c", pd["c"])
			bb2 = AABB(pc - s3 * 0.5, s3)
		var id := str(pd.get("id", ""))
		if not id.is_empty() and by_id.has(id):
			continue
		by_id[id] = true
		_picks.append({"kind": str(pd["kind"]), "label": str(pd["label"]), "aabb": bb2, "assembly": assembly, "group": "", "id": id})


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
			best = {"kind": str(pd["kind"]), "label": str(pd["label"]), "assembly": asm, "group": str(pd["group"]), "t": t, "id": str(pd.get("id", "")),
				"point": origin + dir.normalized() * t}
	return best
