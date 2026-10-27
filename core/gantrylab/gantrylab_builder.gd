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

static var _mat_cache := {}

var _spec: Dictionary = {}
var _layout: Dictionary = {}
var _tool_mm := Vector3.ZERO
var _asm_nodes: Dictionary = {}
var _dynamic: MeshInstance3D = null
var _beads: MultiMeshInstance3D = null
var _bead_total := 0
var _roads: Array = []                 # {a, dir, len, rise, layer} (bead-parent space, m)
var _road_cum := PackedFloat32Array()  # length printed before each road
var _road_len_total := 0.0
var _road_w := 0.0004
var _road_h := 0.0002
var _partial := -1                     # the road drawn part-way, -1 none
var _partial_len := 0.0
var _shown := 0                        # roads drawn whole (0.._shown-1)
const _HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
var _mv_road := PackedInt32Array()     # per move: the road it prints, -1 travel
var _mv_before := PackedInt32Array()   # per move: roads finished before it
var _mv_off := PackedFloat32Array()    # per move: where on its road it starts
var _mv_len := PackedFloat32Array()
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
	_scene_nodes(_layout["static"]["parts"], self)
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
		_scene_nodes(asm["parts"], n)
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


## Parts drawn from a model (the flake extruder): the GLB instanced with its
## nozzle tip on the part's origin, the exporter's leftovers stripped.
static var _scene_cache := {}


func _scene_nodes(parts: Array, parent: Node3D) -> void:
	for p in parts:
		var pd: Dictionary = p
		if not pd.has("scene"):
			continue
		var sc: Dictionary = pd["scene"]
		var path := str(sc["path"])
		if not _scene_cache.has(path):
			_scene_cache[path] = load(path)
		var ps: PackedScene = _scene_cache[path] as PackedScene
		if ps == null:
			continue
		var inst := ps.instantiate() as Node3D
		if inst == null:
			continue
		for nm in sc.get("strip", []):
			var dead := inst.find_child(str(nm), true, false)
			if dead != null:
				dead.get_parent().remove_child(dead)
				dead.free()
		inst.name = "Model_%s" % str(pd.get("label", "tool")).validate_node_name()
		inst.set_meta("skip_prop_collision", true)
		var base := Transform3D(pd.get("basis", Basis.IDENTITY), pd["c"])
		inst.transform = base * Transform3D(Basis.IDENTITY, -(sc["tip"] as Vector3))
		parent.add_child(inst)


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
# Print preview: the extruded roads, laid as the nozzle lays them
# ---------------------------------------------------------------------------

func bead_parent() -> Node3D:
	var pname := str(_layout.get("bead_parent", ""))
	if not pname.is_empty() and _asm_nodes.has(pname):
		return _asm_nodes[pname]
	return self


## The print as ROADS: one rounded bead per extruding move (straight runs of
## short moves merged), `line_mm` wide and `layer_mm` tall, its top at the
## nozzle tip's height, laid in path order under the bed node at true scale.
## `moves` = [{p0, p1, e_mm}] in work mm (the planner's moves, or a toolpath's
## points paired up). Each layer is shaded a touch apart so the layer lines
## read. Progress is by move: `set_print_progress(i, s)` shows every road
## before move i and the current one grown to the nozzle.
func set_print_preview(moves: Array, line_mm: float, layer_mm: float, color: Color, mottle: float = 0.0) -> void:
	clear_toolpath_preview()
	var w := maxf(line_mm, 0.05) * 0.001
	var h := clampf(layer_mm, 0.02, maxf(line_mm, 0.05)) * 0.001
	var o: Vector3 = _layout["bead_origin"]
	var n := moves.size()
	_mv_road = PackedInt32Array()
	_mv_road.resize(n)
	_mv_before = PackedInt32Array()
	_mv_before.resize(n)
	_mv_off = PackedFloat32Array()
	_mv_off.resize(n)
	_mv_len = PackedFloat32Array()
	_mv_len.resize(n)
	_roads = []
	var cur := -1           # the road the last extruding move extended
	var layer_zs := {}
	for i in n:
		var mv: Dictionary = moves[i]
		_mv_road[i] = -1
		_mv_before[i] = _roads.size()
		var a: Vector3 = mv["p0"]
		var b: Vector3 = mv["p1"]
		var flat := Vector2(b.x - a.x, b.y - a.y)
		if float(mv.get("e_mm", 0.0)) <= 0.0 or flat.length() < 1e-4:
			cur = -1
			continue
		var la := o + Vector3(a.x, a.z, a.y) * 0.001
		var lb := o + Vector3(b.x, b.z, b.y) * 0.001
		var dir := Vector3(lb.x - la.x, 0.0, lb.z - la.z).normalized()
		var seg_len := la.distance_to(lb)
		# Extend the road we are on when this move carries straight on.
		if cur >= 0:
			var rd: Dictionary = _roads[cur]
			var end: Vector3 = (rd["a"] as Vector3) + (rd["dir"] as Vector3) * float(rd["len"])
			if end.distance_to(la) < 1e-5 and (rd["dir"] as Vector3).dot(dir) > 0.9995 and absf(la.y - lb.y) < 1e-6:
				_mv_road[i] = cur
				_mv_off[i] = float(rd["len"])
				_mv_len[i] = seg_len
				rd["len"] = float(rd["len"]) + seg_len
				_mv_before[i] = cur
				continue
		cur = _roads.size()
		var zkey := int(round(a.z * 100.0))
		if not layer_zs.has(zkey):
			layer_zs[zkey] = layer_zs.size()
		_roads.append({"a": la, "dir": dir, "len": seg_len, "rise": (lb.y - la.y) / maxf(seg_len, 1e-9), "layer": int(layer_zs[zkey])})
		_mv_road[i] = cur
		_mv_off[i] = 0.0
		_mv_len[i] = seg_len
		_mv_before[i] = cur
	_road_w = w
	_road_h = h
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _road_mesh()
	mm.instance_count = _roads.size()
	_road_len_total = 0.0
	_road_cum = PackedFloat32Array()
	for k in _roads.size():
		var rd: Dictionary = _roads[k]
		_road_cum.append(_road_len_total)
		_road_len_total += float(rd["len"])
		mm.set_instance_transform(k, _HIDDEN)
		# Alternate layers a few percent apart: the layer lines read like a print's.
		var shade := 1.0 if int(rd["layer"]) % 2 == 0 else 0.86
		var c := Color(shade, shade, shade)
		if mottle > 0.0:
			# Mixed flake: each stretch of road a little different in colour.
			var hsh := hash(k * 7919 + int(rd["layer"]))
			c = Color(shade * (1.0 + mottle * (float(hsh & 255) / 255.0 - 0.5)), shade * (1.0 + mottle * (float((hsh >> 8) & 255) / 255.0 - 0.5)),
				shade * (1.0 + mottle * (float((hsh >> 16) & 255) / 255.0 - 0.5)))
		mm.set_instance_color(k, c)
	# Every road stays in the draw (an unprinted one at zero size): the engine
	# drops roads written while `visible_instance_count` hid them, so growing
	# that count showed only the road being laid.
	mm.visible_instance_count = -1
	_shown = 0
	# Bound the WHOLE print: the engine's own box is taken once, while only
	# the first few roads show, and the rest would be culled as it grows.
	if not _roads.is_empty():
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for rd in _roads:
			var a: Vector3 = (rd as Dictionary)["a"]
			var b: Vector3 = a + (rd["dir"] as Vector3) * float(rd["len"]) + Vector3.UP * float(rd["rise"]) * float(rd["len"])
			lo = lo.min(a.min(b))
			hi = hi.max(a.max(b))
		var pad := Vector3.ONE * (w + h)
		mm.custom_aabb = AABB(lo - pad, hi - lo + pad * 2.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.75
	mat.metallic_specular = 0.25
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beads = MultiMeshInstance3D.new()
	_beads.name = "Beads"
	_beads.multimesh = mm
	_beads.material_override = mat
	_beads.set_meta("skip_prop_collision", true)
	_beads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	bead_parent().add_child(_beads)
	_bead_total = _roads.size()
	_partial = -1


## A road's transform drawn `len` metres long: a unit road (x 0..1, y and z
## -0.5..0.5) stretched along its direction, `w` wide and `h` tall with its top
## at the nozzle, reaching half a width past each end so corners close.
func _road_xf(rd: Dictionary, length: float) -> Transform3D:
	var dir: Vector3 = rd["dir"]
	var side := dir.cross(Vector3.UP)
	var a: Vector3 = rd["a"]
	var x := (dir + Vector3.UP * float(rd["rise"])) * (length + _road_w)
	var origin := a - dir * (_road_w * 0.5) + Vector3.DOWN * (_road_h * 0.5)
	return Transform3D(Basis(x, Vector3.UP * _road_h, side * _road_w), origin)


## The bead's cross-section: flat on the layer below and above, rounded at
## the sides (an extruded road, not a box), capped at both ends.
static var _road_mesh_cache: ArrayMesh = null


static func _road_mesh() -> ArrayMesh:
	if _road_mesh_cache != null:
		return _road_mesh_cache
	var prof: Array = []   # (z, y) round the section
	var steps := 6
	for i in steps + 1:
		var t := -PI * 0.5 + PI * float(i) / float(steps)
		prof.append(Vector2(0.5 - 0.22 + 0.22 * cos(t), 0.5 * sin(t)))
	for i in steps + 1:
		var t := PI * 0.5 + PI * float(i) / float(steps)
		prof.append(Vector2(-0.5 + 0.22 + 0.22 * cos(t), 0.5 * sin(t)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var np := prof.size()
	for i in np:
		var p0: Vector2 = prof[i]
		var p1: Vector2 = prof[(i + 1) % np]
		var e := p1 - p0
		var nrm := Vector3(0.0, -e.x, e.y).normalized()
		var v00 := Vector3(0.0, p0.y, p0.x)
		var v01 := Vector3(1.0, p0.y, p0.x)
		var v10 := Vector3(0.0, p1.y, p1.x)
		var v11 := Vector3(1.0, p1.y, p1.x)
		for v in [v00, v10, v11, v00, v11, v01]:
			st.set_normal(nrm)
			st.add_vertex(v)
	for xe in [0.0, 1.0]:
		var nrm2 := Vector3(-1.0 if xe == 0.0 else 1.0, 0, 0)
		for i in range(1, np - 1):
			var a: Vector2 = prof[0]
			var b: Vector2 = prof[i]
			var c: Vector2 = prof[i + 1]
			var tri := [Vector3(xe, a.y, a.x), Vector3(xe, b.y, b.x), Vector3(xe, c.y, c.x)]
			if xe == 0.0:
				tri = [tri[0], tri[2], tri[1]]
			for v in tri:
				st.set_normal(nrm2)
				st.add_vertex(v)
	_road_mesh_cache = st.commit()
	return _road_mesh_cache


## The old point-list form (the in-world job runtime): consecutive points
## pair into moves, `extruding[i]` says whether the move INTO point i prints.
func set_toolpath_preview(points: PackedVector3Array, extruding: PackedInt32Array, line_mm: float, color: Color, layer_mm: float = -1.0) -> void:
	var moves: Array = []
	var has_ext := extruding.size() == points.size()
	for i in range(1, points.size()):
		moves.append({"p0": points[i - 1], "p1": points[i], "e_mm": 1.0 if (not has_ext or extruding[i] != 0) else 0.0})
	set_print_preview(moves, line_mm, layer_mm if layer_mm > 0.0 else layer_guess_mm(moves, line_mm), color)


## The layer height a program prints at: the most common step between the
## heights its extruding moves sit at (half the line when it cannot tell).
static func layer_guess_mm(moves: Array, line_mm: float) -> float:
	var zs := {}
	for mv in moves:
		var m: Dictionary = mv
		if float(m.get("e_mm", 0.0)) > 0.0:
			zs[snappedf(float((m["p1"] as Vector3).z), 0.001)] = true
	var ks: Array = zs.keys()
	ks.sort()
	var counts := {}
	for i in range(1, ks.size()):
		var dz := snappedf(float(ks[i]) - float(ks[i - 1]), 0.01)
		if dz > 0.0:
			counts[dz] = int(counts.get(dz, 0)) + 1
	var best := -1.0
	var bn := 0
	for k in counts:
		if int(counts[k]) > bn:
			bn = int(counts[k])
			best = float(k)
	if best <= 0.0:
		if ks.size() == 1 and float(ks[0]) > 0.0:
			return minf(float(ks[0]), line_mm)
		return line_mm * 0.5
	return minf(best, line_mm)


## Show the print up to move `i`, `s` (0..1) of the way along it.
func set_print_progress(i: int, s: float) -> void:
	if _beads == null or _beads.multimesh == null:
		return
	var mm := _beads.multimesh
	_restore_partial()
	if i < 0:
		_set_shown(0)
		return
	if i >= _mv_road.size():
		_set_shown(_bead_total)
		return
	var k := _mv_road[i]
	if k < 0:
		_set_shown(clampi(_mv_before[i], 0, _bead_total))
		return
	var length := float(_mv_off[i]) + float(_mv_len[i]) * clampf(s, 0.0, 1.0)
	_grow(k, length)


## Show the print up to `frac` of its printed length (the job runtime).
func set_preview_progress(frac: float) -> void:
	if _beads == null or _beads.multimesh == null:
		return
	_restore_partial()
	var target := clampf(frac, 0.0, 1.0) * _road_len_total
	if frac >= 1.0 - 1e-6:
		_set_shown(_bead_total)
		return
	if _bead_total == 0 or target <= 0.0:
		_set_shown(0)
		return
	var lo := 0
	var hi := _bead_total - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if float(_road_cum[mid]) <= target:
			lo = mid
		else:
			hi = mid - 1
	_grow(lo, target - float(_road_cum[lo]))


## Roads 0..k-1 whole, road k drawn `length` metres from its start.
func _grow(k: int, length: float) -> void:
	var mm := _beads.multimesh
	var rd: Dictionary = _roads[k]
	if length < float(rd["len"]) - 1e-6:
		_set_shown(k)
		mm.set_instance_transform(k, _road_xf(rd, maxf(length, 0.0)))
		_partial = k
		_partial_len = maxf(length, 0.0)
	else:
		_set_shown(k + 1)


## Draw roads 0..n-1 whole and hide the rest, rewriting only those that change.
func _set_shown(n: int) -> void:
	var mm := _beads.multimesh
	n = clampi(n, 0, _bead_total)
	if n > _shown:
		for k in range(_shown, n):
			mm.set_instance_transform(k, _road_xf(_roads[k], float(_roads[k]["len"])))
	elif n < _shown:
		for k in range(n, _shown):
			mm.set_instance_transform(k, _HIDDEN)
	_shown = n


## Put the part-drawn road back as it should be at `_shown` (hidden or whole).
func _restore_partial() -> void:
	if _partial >= 0 and _partial < _roads.size() and _beads != null:
		_beads.multimesh.set_instance_transform(_partial, _road_xf(_roads[_partial], float(_roads[_partial]["len"])) if _partial < _shown else _HIDDEN)
	_partial = -1


## How many roads show (whole or being laid).
func roads_shown() -> int:
	return _shown + (1 if _partial >= _shown else 0)


## Road k as drawn now (the MultiMesh keeps no transforms headless).
func road_transform(k: int) -> Transform3D:
	if k < 0 or k >= _roads.size():
		return Transform3D.IDENTITY
	return _road_xf(_roads[k], _partial_len if k == _partial else float(_roads[k]["len"]))


## The middle of the print in world space (probes, cameras).
func print_centre_global() -> Vector3:
	if _roads.is_empty() or _beads == null:
		return global_position
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for rd in _roads:
		var a: Vector3 = (rd as Dictionary)["a"]
		lo = lo.min(a)
		hi = hi.max(a)
	return _beads.global_transform * ((lo + hi) * 0.5)


## How many roads the preview holds (probes, tests).
func road_count() -> int:
	return _bead_total


func clear_toolpath_preview() -> void:
	if _beads != null and is_instance_valid(_beads):
		_beads.get_parent().remove_child(_beads)
		_beads.queue_free()
	_beads = null
	_bead_total = 0
	_roads = []
	_partial = -1
	_shown = 0


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
		var pd: Dictionary = p
		if pd.has("scene"):
			# A model-drawn part is marked by its envelope.
			var env: AABB = (pd["scene"] as Dictionary)["env"]
			var bs: Basis = pd.get("basis", Basis.IDENTITY)
			pd = {"kind": "box", "c": (pd["c"] as Vector3) + bs * env.get_center(), "basis": bs, "s": env.size}
		GantryLabDetail.emit(tmp, pd)
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
		if pd.has("spin") or pd.has("scene"):
			continue  # its own node, see _spin_nodes / _scene_nodes
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
