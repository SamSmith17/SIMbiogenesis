class_name HeroTreeCatalog
extends RefCounted

## Maps preset ids to imported GLB scenes; auto-scales meshes to world meters.

const DEFAULT_TARGET_HEIGHT_M := 14.0
## Hard ceiling on the world scale multiplier — belt-and-braces against a bad
## GLB/tag combination producing a skyscraper tree (mirrors ModelCatalog.MAX_WORLD_SCALE).
const MAX_HERO_WORLD_SCALE := 40.0

static var _fit_cache: Dictionary = {}


static func all_presets() -> Array[Dictionary]:
	return [
		{"id": "pine_1", "label": "Pine 1", "path": "res://Imported Models/Trees/free_tree_1.glb",
			"target_height_m": 13.0, "mesh_scale": 1.0},
		{"id": "pine_spiky", "label": "Spiky Pine", "path": "res://Imported Models/Trees/spiky_pine_trees.glb",
			"target_height_m": 11.0, "mesh_scale": 1.0},
		{"id": "pine_animated", "label": "Pine Animated", "path": "res://Imported Models/Trees/free_tree_animated_model.glb",
			"target_height_m": 12.0, "mesh_scale": 1.0},
		{"id": "deciduous_low", "label": "Deciduous Low", "path": "res://Imported Models/Trees/low_poly_tree.glb",
			"target_height_m": 16.0, "mesh_scale": 1.0},
		{"id": "deciduous_pack", "label": "Deciduous Pack", "path": "res://Imported Models/Trees/low_poly_trees_free.glb",
			"target_height_m": 15.0, "mesh_scale": 1.0},
		{"id": "deciduous_elm", "label": "Elm Deciduous", "path": "res://Imported Models/Trees/elm_trees_free_low_poly.glb",
			"target_height_m": 17.0, "mesh_scale": 1.0},
		{"id": "deciduous_pair", "label": "Deciduous Pair", "path": "res://Imported Models/Trees/low-poly_trees.glb",
			"target_height_m": 16.0, "mesh_scale": 1.0},
		{"id": "shrub_pack", "label": "Shrub Pack", "path": "res://Imported Models/Trees/low_poly_vegetation_for_games.glb",
			"target_height_m": 4.0, "mesh_scale": 1.0},
	]


static func find(preset_id: String) -> Dictionary:
	for p in all_presets():
		if str(p.get("id", "")) == preset_id:
			return p
	if not all_presets().is_empty():
		return all_presets()[0]
	return {}


static func load_scene(preset_id: String) -> PackedScene:
	var preset := find(preset_id)
	var path := str(preset.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var res: Resource = ResourceLoader.load(path)
	if res is PackedScene:
		return res as PackedScene
	return null


## Cached mesh height + local AABB foot (min Y) for grounding.
static func mesh_metrics(preset_id: String) -> Dictionary:
	if _fit_cache.has(preset_id):
		return _fit_cache[preset_id]
	var scene := load_scene(preset_id)
	if scene == null:
		return {"unit_height": 1.0, "foot_local_y": 0.0}
	var inst: Node3D = scene.instantiate() as Node3D
	if inst == null:
		return {"unit_height": 1.0, "foot_local_y": 0.0}
	var metrics := measure_instance(inst)
	inst.free()
	_fit_cache[preset_id] = metrics
	return metrics


## Combined mesh AABB in `inst`'s local space. Each mesh transform is composed up
## the node chain (NOT just mi.transform), so a GLB authored under scaled parent
## nodes measures at its true size — mi.transform alone mis-measured unit_height
## and blew up the target-height normalization (the ~300 ft hero tree). Pure math,
## no tree insertion needed; public so the selftest can feed a synthetic scene.
static func measure_instance(inst: Node3D) -> Dictionary:
	var aabb := AABB()
	var found := false
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = ModelCatalog._xform_relative_to(inst, mi) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found or aabb.size.length_squared() < 0.0001:
		return {"unit_height": 1.0, "foot_local_y": 0.0}
	return {
		"unit_height": maxf(aabb.size.y, 0.01),
		"foot_local_y": aabb.position.y,
	}


static func resolved_hero_scale(preset_id: String, user_scale: float) -> float:
	var preset := find(preset_id)
	var metrics := mesh_metrics(preset_id)
	var target := float(preset.get("target_height_m", DEFAULT_TARGET_HEIGHT_M))
	var mesh_mult := float(preset.get("mesh_scale", 1.0))
	var scale := (target / float(metrics.unit_height)) * mesh_mult * maxf(user_scale, 0.05)
	return minf(scale, MAX_HERO_WORLD_SCALE)


static func foot_local_y(preset_id: String) -> float:
	return float(mesh_metrics(preset_id).foot_local_y)


static func user_scale_for_target_height(preset_id: String, desired_height_m: float) -> float:
	var preset := find(preset_id)
	var preset_target := float(preset.get("target_height_m", DEFAULT_TARGET_HEIGHT_M))
	var mesh_mult := float(preset.get("mesh_scale", 1.0))
	var denom := preset_target * mesh_mult
	if denom <= 0.01:
		return 1.0
	return maxf(desired_height_m / denom, 0.05)


## Map OSM natural=tree tags to a hero GLB preset id.
static func preset_for_osm_tree_tags(tags: Dictionary) -> String:
	var blob := " ".join([
		str(tags.get("species", "")),
		str(tags.get("genus", "")),
		str(tags.get("taxon", "")),
		str(tags.get("taxon:cen", "")),
		str(tags.get("description", "")),
		str(tags.get("species:en", "")),
	]).to_lower()
	for token in ["aesculus hippocastanum", "aesculus", "horse chestnut", "horse-chestnut"]:
		if token in blob:
			return "deciduous_low"
	if tags.has("height") or tags.has("circumference") or tags.has("dbh"):
		return "deciduous_low"
	return ""


## Zero emission on imported hero GLB materials so trees don't bloom at night.
static func strip_night_glow(root: Node) -> void:
	if root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		_strip_mesh_emission(node as MeshInstance3D)


static func _strip_mesh_emission(mi: MeshInstance3D) -> void:
	if mi == null or mi.mesh == null:
		return
	for si in mi.mesh.get_surface_count():
		var mat := mi.get_active_material(si)
		if mat == null or not (mat is StandardMaterial3D):
			continue
		var std := mat as StandardMaterial3D
		if not std.emission_enabled and std.emission_energy_multiplier <= 0.001:
			continue
		var dup := std.duplicate() as StandardMaterial3D
		dup.emission_enabled = false
		dup.emission = Color.BLACK
		dup.emission_energy_multiplier = 0.0
		mi.set_surface_override_material(si, dup)
