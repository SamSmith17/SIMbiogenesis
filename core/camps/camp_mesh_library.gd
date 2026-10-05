class_name CampMeshLibrary
extends RefCounted

## Meshes for painted camps: one NEAR mesh (the textured GLB when the art is
## installed) and one cheap tinted PROXY per class, cached for the session.
##
## The geometry builders themselves stay in BrcCampGenerator (the legacy
## street-following generator still calls them directly, unchanged); this file
## adds the three things that path never had:
##   * a cache — the legacy path re-merges every GLB on every Generate;
##   * NORMALISATION — a GLB is re-centred on its footprint, stood on y = 0,
##     turned so its long axis is +X and scaled to the class's nominal length,
##     so the footprint CampLayoutGenerator reserved is the footprint drawn;
##   * the camp-component GLBs that shipped but nothing placed.

const TINT_SHADER := preload("res://vegetation/camp_tint.gdshader")

const _COMPONENTS := "res://Imported Models/Soak Terrain/Camps/Camp Components/"
## Class -> GLB. Every entry is optional: a missing file (a fresh clone without
## the imported art) falls back to the procedural shape.
const GLB_PATHS := {
	"rv": _COMPONENTS + "RV.glb",
	"shade_structure": _COMPONENTS + "Carport.glb",
	"shift_pod": _COMPONENTS + "Shiftpod.glb",
	"lotus_tent": _COMPONENTS + "Lotus tent.glb",
	"van": "res://Imported Models/GMC camper van.glb",
}
## The pop-up canopy is deliberately NOT here although its GLB ships: the model
## is one black canopy, and a field of identical black squares reads as a car
## park. The tinted shape takes a per-instance colour, which is what a festival
## looks like from any distance.
## Classes BrcCampGenerator has no procedural shape for borrow a neighbour's.
const PROXY_SHAPE := {
	"van": "rv",
	"ez_up": "shade_structure",
	"lotus_tent": "popup_tent",
	"shift_pod": "geodesic_dome",
}

static var _cache: Dictionary = {}
static var _tint_mat: ShaderMaterial = null


static func clear_cache() -> void:
	_cache.clear()


static func tint_material() -> ShaderMaterial:
	if _tint_mat == null:
		_tint_mat = ShaderMaterial.new()
		_tint_mat.shader = TINT_SHADER
	return _tint_mat


## {"near": Mesh, "near_material": Material|null, "proxy": Mesh, "has_art": bool,
##  "height": float}. `near` is the GLB when installed, else the proxy itself.
## `use_art = false` (headless selftests) never touches the imported models.
static func class_meshes(cls: String, use_art: bool = true) -> Dictionary:
	var key := "%s|%s" % [cls, use_art]
	if _cache.has(key):
		return _cache[key]
	var size := CampStyles.class_size(cls)
	var proxy: Mesh = BrcCampGenerator._procedural_mesh(str(PROXY_SHAPE.get(cls, cls)), size)
	var entry := {"near": proxy, "near_material": tint_material(), "proxy": proxy,
		"has_art": false, "height": size.y}
	if CampStyles.is_user_class(cls):
		# A library / imported model: fitted to the size measured when it was
		# added (its REAL size), with a plain box standing in at distance.
		var model_id := str((CampStyles.user_models()[cls] as Dictionary).get("model_id", ""))
		var scene := ModelCatalog.load_scene(model_id) if use_art else null
		if scene != null:
			var raw := BrcCampGenerator._merge_scene_mesh(scene)
			var fit := normalize_mesh(raw, size) if raw != null else null
			if fit != null:
				entry["near"] = fit
				entry["near_material"] = null
				entry["has_art"] = true
		_cache[key] = entry
		return entry
	if use_art and GLB_PATHS.has(cls) and ResourceLoader.exists(str(GLB_PATHS[cls])):
		var packed := load(str(GLB_PATHS[cls])) as PackedScene
		if packed != null:
			var merged := BrcCampGenerator._merge_scene_mesh(packed)
			var fitted := normalize_mesh(merged, size) if merged != null else null
			if fitted != null:
				entry["near"] = fitted
				entry["near_material"] = null  # keeps its own textured surfaces
				entry["has_art"] = true
				entry["height"] = fitted.get_aabb().size.y
	_cache[key] = entry
	return entry


## Re-centre a merged prop on its footprint, stand it on y = 0, turn its long
## horizontal axis onto +X and scale it uniformly to `nominal.x` long.
## Returns null when the mesh is degenerate.
static func normalize_mesh(mesh: ArrayMesh, nominal: Vector3) -> ArrayMesh:
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var box := mesh.get_aabb()
	var long_side := maxf(box.size.x, box.size.z)
	if long_side < 0.01 or box.size.y < 0.01:
		return null
	var turn := box.size.z > box.size.x * 1.05
	var scale := nominal.x / long_side
	var centre := box.position + box.size * 0.5
	var xf := Transform3D(Basis.IDENTITY, Vector3(-centre.x, -box.position.y, -centre.z))
	if turn:
		xf = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO) * xf
	xf = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), Vector3.ZERO) * xf
	var rot := Basis(Vector3.UP, PI * 0.5) if turn else Basis.IDENTITY
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nv := PackedVector3Array()
		nv.resize(verts.size())
		for i in verts.size():
			nv[i] = xf * verts[i]
		arr[Mesh.ARRAY_VERTEX] = nv
		var normals = arr[Mesh.ARRAY_NORMAL]
		if turn and normals != null and (normals as PackedVector3Array).size() == verts.size():
			var nn := PackedVector3Array()
			nn.resize(verts.size())
			for i in verts.size():
				nn[i] = rot * normals[i]
			arr[Mesh.ARRAY_NORMAL] = nn
		var tangents = arr[Mesh.ARRAY_TANGENT]
		if turn and tangents != null and (tangents as PackedFloat32Array).size() == verts.size() * 4:
			var tt: PackedFloat32Array = (tangents as PackedFloat32Array).duplicate()
			for i in verts.size():
				var t := rot * Vector3(tt[i * 4], tt[i * 4 + 1], tt[i * 4 + 2])
				tt[i * 4] = t.x
				tt[i * 4 + 1] = t.y
				tt[i * 4 + 2] = t.z
			arr[Mesh.ARRAY_TANGENT] = tt
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := mesh.surface_get_material(s)
		if mat != null:
			out.surface_set_material(out.get_surface_count() - 1, mat)
	return out


static func mesh_tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var n := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		if arr[Mesh.ARRAY_INDEX] != null:
			n += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		else:
			n += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## Triangles of the mesh a class draws up close (what instancing multiplies).
static func class_tris(cls: String, use_art: bool = true) -> int:
	return mesh_tris(class_meshes(cls, use_art)["near"])


## Measure a ModelCatalog model for use as a camp class: its REAL footprint
## (catalog scale applied; X = the longer horizontal side) and triangle count.
## {} when the model has no loadable scene (procedural catalog entries).
static func measure_model(model_id: String) -> Dictionary:
	var scene := ModelCatalog.load_scene(model_id)
	if scene == null:
		return {}
	var mesh := BrcCampGenerator._merge_scene_mesh(scene)
	if mesh == null:
		return {}
	var box := mesh.get_aabb().size * ModelCatalog.resolved_scale(model_id, 1.0)
	if maxf(box.x, box.z) < 0.05 or box.y < 0.05:
		return {}
	return {
		"size": Vector3(maxf(box.x, box.z), box.y, minf(box.x, box.z)),
		"tris": mesh_tris(mesh),
		"surfaces": mesh.get_surface_count(),
	}
