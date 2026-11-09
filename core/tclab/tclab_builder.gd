class_name TcBuilder
extends Node3D

## Draws a solved TC design (TcDesign.solve) in METRES. One MeshInstance3D
## per part ("P_<id>", meta tc_part) sharing one ArrayMesh per unique part
## key, and one per clamp joint for its gasket and clamp ("J_<n>", meta
## tc_joint), so a selection change or a moved part never rebuilds a vertex.
## `flat` merges everything into one "Mesh" (exports, and later the world).
##
## Opts: flat (bool), selected (Array of part ids, amber overlay), marked
## (Array of part ids, red overlay — clashes), joint_selected (int).

const MODEL_ID := "tclab_assembly"
const MM := 0.001

static var _mesh_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}

var design: Dictionary = {}


## Placed assemblies draw two merged meshes (one surface per material):
## "Mesh" up to FAR_M, and "MeshFar" beyond it — every part at
## FAR_SEG_SCALE of its segments, no clamps or gaskets. MeshFar is also the
## prop's collision (Mesh carries skip_prop_collision): a fraction of the
## triangles and the same outline. Both are cached per design key, so ten
## placed reactors share one pair of meshes.
const FAR_M := 40.0
const FAR_MARGIN_M := 4.0
const FAR_SEG_SCALE := 0.3
const WORLD_CACHE_MAX := 16

static var _world_cache: Dictionary = {}
static var _world_order: Array = []
static var world_builds := 0


## The catalog ids this builder draws: the designer's own and one per
## built-in ("tclab_<builtin id>"); a record with no tc_spec builds its
## id's built-in.
static func handles(model_id: String) -> bool:
	return model_id == MODEL_ID or (model_id.begins_with("tclab_") and not TcPresets.builtin(model_id.substr(6)).is_empty())


static func spec_for_model(model_id: String) -> Dictionary:
	if model_id.begins_with("tclab_") and model_id != MODEL_ID:
		return TcPresets.builtin(model_id.substr(6))
	return {}


## The node a placed assembly is (ModelCatalog): standing on y = 0 with its
## plan centre on the origin (TcDesign.world_offset). opts.pieces: one
## MeshInstance3D per part, tagged for StructureUnits (crew builds).
static func build_node(spec: Dictionary, node_name: String = "TcAssembly", opts: Dictionary = {}) -> TcBuilder:
	var b := TcBuilder.new()
	b.name = node_name
	var d := TcDesign.solve(spec)
	b.design = d
	b.set_meta("tc_design_key", TcSpec.key_of(d["spec"]))
	if bool(opts.get("pieces", false)):
		b._build_pieces(d)
	else:
		b._build_world(d)
	return b


func _build_world(d: Dictionary) -> void:
	var meshes := world_meshes(d)
	var near := MeshInstance3D.new()
	near.name = "Mesh"
	near.mesh = meshes[0]
	near.set_meta("skip_prop_collision", true)
	near.visibility_range_end = FAR_M
	near.visibility_range_end_margin = FAR_MARGIN_M
	add_child(near)
	var far := MeshInstance3D.new()
	far.name = "MeshFar"
	far.mesh = meshes[1]
	far.visibility_range_begin = FAR_M
	far.visibility_range_begin_margin = FAR_MARGIN_M
	add_child(far)


## [near, far] ArrayMesh in the prop's frame, cached per design key.
static func world_meshes(d: Dictionary) -> Array:
	var key := TcSpec.key_of(d["spec"])
	if _world_cache.has(key):
		_world_order.erase(key)
		_world_order.append(key)
		return _world_cache[key]
	world_builds += 1
	var res: Dictionary = d["res"]
	var shift := Transform3D(Basis.IDENTITY, TcDesign.world_offset(d))
	var g := TcGeom.new()
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if not pd.is_empty():
			g.merge((pd["built"] as Dictionary)["geo"], shift * (pd["xf"] as Transform3D))
	for jd in res["joints"]:
		if str(jd["kind"]) == "tc" and jd.has("frame") and bool(jd["ok"]):
			g.merge(joint_geo(str(jd["size"]), float(jd["gap"]), str(jd["clamp"]), str(jd["gasket"])),
				shift * (jd["frame"] as Transform3D))
	var gf := TcGeom.new()
	TcGeom.seg_scale = FAR_SEG_SCALE
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var b: Dictionary = pd["built"]
		var lo := TcParts.build(str(b["type"]), str(b["size"]), b["params"])
		gf.merge(lo["geo"], shift * (pd["xf"] as Transform3D))
	TcGeom.seg_scale = 1.0
	var out := [geo_to_mesh(g, null), geo_to_mesh(gf, null)]
	_world_cache[key] = out
	_world_order.append(key)
	while _world_order.size() > WORLD_CACHE_MAX:
		_world_cache.erase(_world_order.pop_front())
	return out


## Crew builds: one tagged MeshInstance3D per part, the vessel first and the
## fittings outward joint by joint; clamps ride with their fittings.
func _build_pieces(d: Dictionary) -> void:
	var res: Dictionary = d["res"]
	var shift := Transform3D(Basis.IDENTITY, TcDesign.world_offset(d))
	var depth := TcDesign.part_depths(d)
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var b: Dictionary = pd["built"]
		var mi := MeshInstance3D.new()
		mi.name = "P_%s" % id
		mi.mesh = part_mesh(b)
		mi.transform = to_m(shift * (pd["xf"] as Transform3D))
		var t := str(b["type"])
		var cat := str((TcParts.TYPES.get(t, {}) as Dictionary).get("category", ""))
		var words := ["a fitting", "fittings"]
		var kind := "parts"
		if t == "vessel":
			words = ["the vessel", "vessels"]
			kind = "frames"
		elif t == "spool":
			words = ["a spool", "spools"]
		elif cat in ["valves", "actuators"]:
			words = ["a valve", "valves"]
		elif cat == "columns":
			words = ["a column", "columns"]
		StructureUnits.tag_piece(mi, kind, words, int(depth.get(id, 0)))
		add_child(mi)
	for jd in res["joints"]:
		if str(jd["kind"]) != "tc" or not jd.has("frame") or not bool(jd["ok"]):
			continue
		var mj := MeshInstance3D.new()
		mj.name = "J_%d" % int(jd["index"])
		mj.mesh = joint_mesh(str(jd["size"]), float(jd["gap"]), str(jd["clamp"]), str(jd["gasket"]))
		mj.transform = to_m(shift * (jd["frame"] as Transform3D))
		StructureUnits.tag_piece(mj, "parts", ["a clamp", "clamps"], 0)
		add_child(mj)


func build(d: Dictionary, opts: Dictionary = {}) -> void:
	design = d
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var res: Dictionary = d.get("res", {})
	if res.is_empty():
		return
	if bool(opts.get("flat", false)):
		var g := TcGeom.new()
		_merge_all(g, res)
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = geo_to_mesh(g, null)
		add_child(mi)
		return
	var sel: Array = opts.get("selected", [])
	var marked: Array = opts.get("marked", [])
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var b: Dictionary = pd["built"]
		if bool(opts.get("cutaway", false)) and str(b["type"]) == "vessel":
			var cp: Dictionary = (b["params"] as Dictionary).duplicate()
			cp["cutaway"] = true
			b = TcParts.build("vessel", str(b["size"]), cp)
		var mi := MeshInstance3D.new()
		mi.name = "P_%s" % id
		mi.set_meta("tc_part", id)
		mi.mesh = part_mesh(b)
		mi.transform = to_m(pd["xf"])
		if id in sel:
			mi.material_overlay = overlay_material(Color(1.0, 0.72, 0.18))
		elif id in marked:
			mi.material_overlay = overlay_material(Color(1.0, 0.25, 0.2))
		add_child(mi)
	var jsel := int(opts.get("joint_selected", -1))
	for jd in res["joints"]:
		if str(jd["kind"]) != "tc" or not jd.has("frame") or not bool(jd["ok"]):
			continue
		var mi := MeshInstance3D.new()
		mi.name = "J_%d" % int(jd["index"])
		mi.set_meta("tc_joint", int(jd["index"]))
		mi.mesh = joint_mesh(str(jd["size"]), float(jd["gap"]), str(jd["clamp"]), str(jd["gasket"]))
		mi.transform = to_m(jd["frame"])
		if int(jd["index"]) == jsel:
			mi.material_overlay = overlay_material(Color(0.3, 0.85, 1.0))
		add_child(mi)


static func to_m(xf_mm: Transform3D) -> Transform3D:
	return Transform3D(xf_mm.basis, xf_mm.origin * MM)


## Everything in one TcGeom (mm): parts, gaskets, clamps.
static func _merge_all(g: TcGeom, res: Dictionary) -> void:
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if not pd.is_empty():
			g.merge((pd["built"] as Dictionary)["geo"], pd["xf"])
	for jd in res["joints"]:
		if str(jd["kind"]) == "tc" and jd.has("frame") and bool(jd["ok"]):
			g.merge(joint_geo(str(jd["size"]), float(jd["gap"]), str(jd["clamp"]), str(jd["gasket"])), jd["frame"])


static func merged_geo(d: Dictionary) -> TcGeom:
	var g := TcGeom.new()
	_merge_all(g, d.get("res", {}))
	return g


static func part_mesh(b: Dictionary) -> ArrayMesh:
	var key := str(b["key"])
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var m := geo_to_mesh(b["geo"], null)
	_store(key, m)
	return m


static var _joint_geo_cache: Dictionary = {}


## A clamp joint's gasket + clamp (mm), cached by what draws it.
static func joint_geo(size: String, gap: float, clamp_type: String, gasket: String) -> TcGeom:
	var key := "%s|%.2f|%s|%s" % [TcStandards.clamp_class(size), gap, clamp_type, gasket]
	if _joint_geo_cache.has(key):
		return _joint_geo_cache[key]
	var g := TcGeom.new()
	g.gasket(Transform3D.IDENTITY, size, gap, "gasket_" + gasket)
	g.clamp(Transform3D.IDENTITY, size, gap, clamp_type, "hardware")
	if _joint_geo_cache.size() > 64:
		_joint_geo_cache.clear()
	_joint_geo_cache[key] = g
	return g


static func joint_mesh(size: String, gap: float, clamp_type: String, gasket: String) -> ArrayMesh:
	var key := "J|%s|%.2f|%s|%s" % [TcStandards.clamp_class(size), gap, clamp_type, gasket]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var m := geo_to_mesh(joint_geo(size, gap, clamp_type, gasket), null)
	_store(key, m)
	return m


static func _store(key: String, m: ArrayMesh) -> void:
	if _mesh_cache.size() > 300:
		_mesh_cache.clear()
	_mesh_cache[key] = m


## A TcGeom (mm) as an ArrayMesh in metres, a surface per material key.
static func geo_to_mesh(g: TcGeom, override: Material) -> ArrayMesh:
	var am := ArrayMesh.new()
	var mats := g.get_mats()
	var keys := mats.keys()
	keys.sort()
	for k in keys:
		var src: PackedVector3Array = mats[k]["v"]
		if src.is_empty():
			continue
		var v: PackedVector3Array = Transform3D(Basis.from_scale(Vector3.ONE * MM), Vector3.ZERO) * src
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = mats[k]["n"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		am.surface_set_name(am.get_surface_count() - 1, str(k))   # the material key (the process views swap by it)
		am.surface_set_material(am.get_surface_count() - 1, override if override != null else material_for(str(k)))
	return am


static func material_for(key: String) -> Material:
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m: StandardMaterial3D = null
	if key == "steel":
		m = StructureMaterials.make(StructureMaterials.Kind.STAINLESS, Color(0.80, 0.81, 0.83))
	elif key == "hardware":
		m = StructureMaterials.make(StructureMaterials.Kind.STAINLESS, Color(0.70, 0.71, 0.73))
		m.roughness = 0.42
	elif key.begins_with("gasket_"):
		var g: Dictionary = TcStandards.GASKETS.get(key.substr(7), TcStandards.GASKETS["epdm"])
		m = StructureMaterials.make(StructureMaterials.Kind.RUBBER, g["color"])
	elif key == "brass":
		m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, Color(0.78, 0.62, 0.32))
	elif key == "copper":
		m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, Color(0.80, 0.45, 0.28))
	elif key == "glass":
		m = StructureMaterials.make(StructureMaterials.Kind.GLAZING, Color(0.85, 0.92, 0.95, 0.30))
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_BACK
	elif key == "dark":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.09, 0.09, 0.10))
	elif key == "handle":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.78, 0.14, 0.10))
	elif key == "dial":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.95, 0.95, 0.92))
	elif key == "actuator":
		m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.20, 0.38, 0.62))
	elif key == "ceramic":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.86, 0.82, 0.74))
	elif key == "mesh":
		m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, Color(0.42, 0.43, 0.45))
	elif key == "insulation":
		m = StructureMaterials.make(StructureMaterials.Kind.FABRIC, Color(0.88, 0.86, 0.80))
	elif key == "can":
		m = StructureMaterials.make(StructureMaterials.Kind.GALVANISED, Color(0.62, 0.63, 0.62))
	elif key == "char":
		m = StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.45, 0.31, 0.19))
	elif key == "desiccant":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.80, 0.86, 0.95))
	elif key == "carbon":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.08, 0.08, 0.09))
	elif key == "drum":
		# A blue polyethylene barrel.
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.10, 0.27, 0.62))
	elif key == "drum_dark":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.07, 0.17, 0.40))
	elif key == "bell":
		# The gasometer's float (a lighter barrel, so it reads apart from its base).
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.20, 0.46, 0.82))
	elif key == "bell_trim":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.16, 0.16, 0.17))
	elif key == "pvc":
		m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.90, 0.90, 0.87))
	elif key == "water":
		m = StructureMaterials.make(StructureMaterials.Kind.GLAZING, Color(0.30, 0.50, 0.62, 0.55))
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif key == "frame":
		m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.10, 0.10, 0.11))
	elif key == "engine":
		m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, Color(0.34, 0.35, 0.37))
	else:
		m = StructureMaterials.make(StructureMaterials.Kind.STAINLESS, Color(0.8, 0.8, 0.8))
	_mat_cache[key] = m
	return m


static func overlay_material(c: Color) -> Material:
	var key := "overlay|%s" % c.to_html()
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, 0.38)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_BACK
	m.no_depth_test = false
	_mat_cache[key] = m
	return m


## A see-through ghost of one part (placement preview).
static func ghost_node(type: String, size: String, params: Dictionary, ok: bool = true) -> MeshInstance3D:
	var b := TcParts.build(type, size, params)
	var mi := MeshInstance3D.new()
	mi.name = "Ghost"
	var key := "ghost|%s|%s" % [str(b["key"]), "ok" if ok else "bad"]
	var mesh: ArrayMesh = _mesh_cache.get(key, null)
	if mesh == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.35, 0.9, 1.0, 0.45) if ok else Color(1.0, 0.3, 0.25, 0.45)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mesh = geo_to_mesh(b["geo"], m)
		_store(key, mesh)
	mi.mesh = mesh
	return mi


## Every triangle of the design (mm), for the winding check and STL.
static func triangles_mm(d: Dictionary) -> PackedVector3Array:
	var g := merged_geo(d)
	var out := PackedVector3Array()
	var mats := g.get_mats()
	for k in mats:
		out.append_array(mats[k]["v"])
	return out
