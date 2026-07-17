class_name ModelCatalog
extends RefCounted

## Shipped + user GLB catalog for placed props.

const USER_DIR := "user://models/"
const CATALOG_PATH := "user://models/catalog.json"
const DEFAULT_TARGET_HEIGHT_M := 3.0
const MAX_WORLD_SCALE := 50.0
## LinkageLab GLB meshes use inch coordinates (see bundle translations ~40–300).
const LINKAGELAB_INCHES_TO_M := 0.0254

static var _fit_cache: Dictionary = {}
static var _user_catalog: Array = []
static var _user_packed: Dictionary = {}
static var _catalog_loaded := false


static func all_models() -> Array[Dictionary]:
	_ensure_user_catalog()
	var out: Array[Dictionary] = []
	out.append_array(_shipped_models())
	out.append_array(_user_catalog)
	return out


static func find(model_id: String) -> Dictionary:
	for m in all_models():
		if str(m.get("id", "")) == model_id:
			return m
	return {}


## True for the shipped StarShade or any LinkageLab bundle import (user_* ids).
static func is_starshade_model(model_id: String) -> bool:
	if model_id.is_empty():
		return false
	if model_id == "starshade" or model_id.begins_with("starshade_"):
		return true
	var entry := find(model_id)
	if entry.is_empty():
		return false
	if str(entry.get("family", "")) == "starshade":
		return true
	if str(entry.get("source", "")) == "linkagelab":
		return true
	var label := str(entry.get("label", "")).to_lower()
	if label.contains("starshade") or label.contains("linkagelab"):
		return true
	var path := str(entry.get("path", "")).to_lower()
	if path.contains("starshades"):
		return true
	return false


## Designs offered by the StarShade editor (family + path heuristic).
static func starshade_designs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	for m in all_models():
		var mid := str(m.get("id", ""))
		if mid.is_empty() or seen.has(mid):
			continue
		if is_starshade_model(mid):
			seen[mid] = true
			out.append(m)
	return out


## Shipped models filtered by their "category" key ("structures", "nature", …).
static func models_in_category(category: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in all_models():
		if str(m.get("category", "")) == category:
			out.append(m)
	return out


static func load_scene(model_id: String) -> PackedScene:
	var entry := find(model_id)
	var path := str(entry.get("path", ""))
	if path.is_empty():
		return null
	if path.begins_with("user://"):
		return _packed_scene_for_user(path)
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = ResourceLoader.load(path)
	if res is PackedScene:
		return res as PackedScene
	return null


static func instantiate(model_id: String, extras: Dictionary = {}) -> Node3D:
	if model_id == PalletRackBuilder.MODEL_ID:
		var rack_spec: Dictionary = extras.get("rack_spec", extras) as Dictionary
		return PalletRackBuilder.build_node(rack_spec)
	if model_id == GrowBed.MODEL_ID:
		var bed_spec: Dictionary = extras.get("grow_bed_spec", extras) as Dictionary
		return GrowBed.build_node(bed_spec)
	var ps := load_scene(model_id)
	if ps == null:
		return null
	return ps.instantiate() as Node3D


static func register_user(entry: Dictionary) -> void:
	_ensure_user_catalog()
	var id := str(entry.get("id", ""))
	if id.is_empty():
		return
	invalidate_metrics(id)
	for i in _user_catalog.size():
		if str(_user_catalog[i].get("id", "")) == id:
			_user_catalog[i] = entry
			_save_user_catalog()
			return
	_user_catalog.append(entry)
	_save_user_catalog()


static func mesh_metrics(model_id: String) -> Dictionary:
	if _fit_cache.has(model_id):
		return _fit_cache[model_id]
	var inst := instantiate(model_id)
	if inst == null:
		return {"unit_height": 1.0, "foot_local_y": 0.0, "width": 1.0, "depth": 1.0}
	# Measure the combined AABB in the instance ROOT's local space. Each mesh's
	# transform is composed up the node chain to `inst` (NOT just mi.transform),
	# so a GLB authored under scaled/translated parent nodes is measured at its
	# true size. Using mi.transform alone summed un-hierarchied boxes and produced
	# a hugely inflated AABB, which made the heightM-fit scale come out far too
	# small. (No tree insertion needed — this is pure local-transform math.)
	var aabb := AABB()
	var found := false
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = _xform_relative_to(inst, mi) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	inst.free()
	if aabb.size.length_squared() < 0.0001:
		return {"unit_height": 1.0, "foot_local_y": 0.0, "width": 1.0, "depth": 1.0}
	var metrics := {
		"unit_height": maxf(aabb.size.y, 0.01),
		"foot_local_y": aabb.position.y,
		"width": maxf(aabb.size.x, 0.01),
		"depth": maxf(aabb.size.z, 0.01),
	}
	_fit_cache[model_id] = metrics
	return metrics


static func invalidate_metrics(model_id: String) -> void:
	_fit_cache.erase(model_id)


## Transform of `descendant`'s local space expressed in `ancestor`'s local space,
## composed from local transforms up the chain (excludes ancestor's own transform).
## Pure math — valid before the node enters the tree.
static func _xform_relative_to(ancestor: Node3D, descendant: Node3D) -> Transform3D:
	var t := descendant.transform
	var p := descendant.get_parent()
	while p != null and p != ancestor and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


static func resolved_scale(model_id: String, user_scale: float) -> float:
	var entry := find(model_id)
	var us := maxf(user_scale, 0.05)
	if bool(entry.get("preserve_scale", false)):
		# Height-driven fit wins: scale so the measured mesh AABB height equals the
		# bundle's declared real-world height. This is unit-agnostic — it produces a
		# correct world size whether the GLB vertex coords are inches, meters, mm, or
		# anything else, so it never depends on a guessed units multiplier.
		var ref_h := float(entry.get("reference_height_m", 0.0))
		if ref_h > 0.0:
			var metrics := mesh_metrics(model_id)
			var unit_h := maxf(metrics.unit_height, 0.01)
			return minf((ref_h / unit_h) * us, MAX_WORLD_SCALE)
		# Fallback only when no reference height was supplied: apply the declared
		# file-units→meters multiplier (see GlbDecoder for how units are resolved).
		var file_um := float(entry.get("file_units_to_meters", 1.0))
		if absf(file_um - 1.0) > 0.0001:
			return minf(file_um * us, MAX_WORLD_SCALE)
		return minf(us, MAX_WORLD_SCALE)
	var metrics := mesh_metrics(model_id)
	var target := float(entry.get("target_height_m", DEFAULT_TARGET_HEIGHT_M))
	var mesh_mult := float(entry.get("mesh_scale", 1.0))
	if target <= 0.0:
		return us
	return minf((target / metrics.unit_height) * mesh_mult * us, MAX_WORLD_SCALE)


static func foot_local_y(model_id: String) -> float:
	return float(mesh_metrics(model_id).foot_local_y)


## Fixed yaw (degrees) some models declare to align their own mesh axes onto
## world cardinal directions (e.g. the CSP trough's N-S pivot). Applied to
## BOTH the placement ghost and the real placed prop so confirming never
## visibly rotates the model out from under the player.
static func forced_yaw_deg(model_id: String) -> float:
	return float(find(model_id).get("forced_yaw_deg", 0.0))


static func scale_to_footprint(model_id: String, width_m: float, depth_m: float,
		height_m: float, user_scale: float = 1.0) -> float:
	var metrics := mesh_metrics(model_id)
	var sx: float = width_m / metrics.width
	var sz: float = depth_m / metrics.depth
	var sy: float = height_m / metrics.unit_height
	var fit: float = minf(minf(sx, sz), sy)
	return fit * maxf(user_scale, 0.05)


static func _shipped_models() -> Array[Dictionary]:
	return [
		{"id": "shiftpod", "label": "Shiftpod", "path": "res://Imported Models/Soak Terrain/Camps/Camp Components/Shiftpod.glb",
			"target_height_m": 2.5, "mesh_scale": 1.0, "category": "structures"},
		{"id": "carport", "label": "Carport", "path": "res://Imported Models/Soak Terrain/Camps/Camp Components/Carport.glb",
			"target_height_m": 3.5, "mesh_scale": 1.0, "category": "structures"},
		{"id": "ez_up", "label": "10x10 EZ-UP", "path": "res://Imported Models/Soak Terrain/Camps/Camp Components/10 x 10 EZ-UP 2.glb",
			"target_height_m": 3.0, "mesh_scale": 1.0, "category": "structures"},
		# This LinkageLab export is metre-unit (AABB height ≈ 2.4 — unlike the
		# inch-unit GLB bundles), so preserve_scale alone keeps true size.
		{"id": "starshade", "label": "StarShade", "path": "res://Imported Models/StarShades/LinkageLab_Export_1777324209080.gltf",
			"preserve_scale": true, "category": "structures", "family": "starshade"},
		{"id": "starshade_center_camp", "label": "StarShade Center Camp",
			"path": "res://Imported Models/StarShades/Center Camp.glb",
			"preserve_scale": true, "category": "structures", "family": "starshade"},
		{"id": "starshade_man_effigy", "label": "StarShade Man Effigy",
			"path": "res://Imported Models/StarShades/Man Effigy.glb",
			"preserve_scale": true, "category": "structures", "family": "starshade"},
		# Procedural — instantiate() builds via PalletRackBuilder.
		{"id": "pallet_rack", "label": "Pallet Rack (parametric)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 2.0},
		# Procedural grow bed — library "Grow Beds" → Place in world.
		{"id": "grow_bed", "label": "Grow Bed",
			"procedural": true, "preserve_scale": true, "category": "nature",
			"target_height_m": 0.5},
		{"id": "pine_1", "label": "Pine Tree", "path": "res://Imported Models/Trees/free_tree_1.glb",
			"target_height_m": 13.0, "mesh_scale": 1.0, "category": "nature"},
		# Vertical Axis Wind Turbine — authored in SketchUp, exported to GLB already
		# in metres (~11.5 m tall: 6.4 m mast + 5 m rotor). preserve_scale keeps that
		# real size. The rotor sub-node ("Component#2") spins about the vertical axis;
		# WindTurbineSpin (attached at placement) reads turbine_node to find it.
		{"id": "vawt", "label": "Vertical Axis Wind Turbine",
			"path": "res://Imported Models/Wind/VAWT.glb",
			"preserve_scale": true, "category": "structures",
			"turbine_node": "Component#2"},
		# Single-axis parabolic-trough CSP. Authored in inches (Node2 child
		# carries the 0.0254 inch→m scale baked into the GLB itself, like the
		# StarShade exports), so preserve_scale keeps true size. Component#452
		# is the fixed pedestal/base; Component#453 is the moving concentrator
		# (mirror + focal tube). The GLB's natural orientation already runs the
		# module-length / pivot axis (model local +X) along world EAST-WEST
		# (verified empirically — see csp_trough_tracker.gd class doc), which is
		# exactly what a single-axis E-W trough wants (long axis E-W, aperture
		# tilting to face the equator). So forced_yaw_deg = 0 (no yaw); the
		# concentrator only ever rotates about that E-W pivot to track the sun's
		# altitude. Kept explicit so the ghost + placed prop share one constant.
		{"id": "csp_trough", "label": "Parabolic Trough CSP",
			"path": "res://Imported Models/CSP/single_axis_csp.glb",
			"preserve_scale": true, "category": "structures",
			"csp_base_node": "Component#452", "csp_concentrator_node": "Component#453",
			"forced_yaw_deg": 0.0},
	]


static func _ensure_user_catalog() -> void:
	if _catalog_loaded:
		return
	_catalog_loaded = true
	_user_catalog = []
	if not FileAccess.file_exists(CATALOG_PATH):
		return
	var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Array):
		return
	for item in parsed as Array:
		if item is Dictionary:
			_user_catalog.append(item as Dictionary)


static func _save_user_catalog() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DIR))
	var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_user_catalog))


static func _packed_scene_for_user(path: String) -> PackedScene:
	if _user_packed.has(path):
		return _user_packed[path] as PackedScene
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return null
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(abs_path, state) != OK:
		if ResourceLoader.exists(path):
			var res: Resource = ResourceLoader.load(path)
			if res is PackedScene:
				_user_packed[path] = res
				return res as PackedScene
		return null
	var root := gltf.generate_scene(state)
	if root == null:
		return null
	_replace_importer_meshes(root, root)
	var ps := PackedScene.new()
	var err := ps.pack(root)
	root.queue_free()
	if err != OK:
		return null
	_user_packed[path] = ps
	return ps


static func _replace_importer_meshes(node: Node, root: Node) -> void:
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		if child.get_class() == "ImporterMeshInstance3D":
			var mi := MeshInstance3D.new()
			mi.name = child.name
			mi.transform = child.transform
			if child.get("mesh") != null:
				mi.mesh = child.get("mesh").get_mesh()
			node.add_child(mi)
			mi.owner = root
			node.remove_child(child)
			child.queue_free()
			child = mi
		_replace_importer_meshes(child, root)
