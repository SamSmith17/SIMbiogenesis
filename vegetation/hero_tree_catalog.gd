class_name HeroTreeCatalog
extends RefCounted

## Maps preset ids to imported GLB scenes; auto-scales meshes to world meters.

const DEFAULT_TARGET_HEIGHT_M := 14.0

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
	var holder := Node3D.new()
	var tree := Engine.get_main_loop()
	if tree != null and tree.root != null:
		tree.root.add_child(holder)
	var inst: Node3D = scene.instantiate() as Node3D
	if inst == null:
		holder.queue_free()
		return {"unit_height": 1.0, "foot_local_y": 0.0}
	holder.add_child(inst)
	var aabb := AABB()
	var found := false
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var local: AABB = mi.transform * mi.mesh.get_aabb()
		if not found:
			aabb = local
			found = true
		else:
			aabb = aabb.merge(local)
	holder.queue_free()
	if not found:
		return {"unit_height": 1.0, "foot_local_y": 0.0}
	var metrics := {
		"unit_height": maxf(aabb.size.y, 0.01),
		"foot_local_y": aabb.position.y,
	}
	_fit_cache[preset_id] = metrics
	return metrics


static func resolved_hero_scale(preset_id: String, user_scale: float) -> float:
	var preset := find(preset_id)
	var metrics := mesh_metrics(preset_id)
	var target := float(preset.get("target_height_m", DEFAULT_TARGET_HEIGHT_M))
	var mesh_mult := float(preset.get("mesh_scale", 1.0))
	return (target / metrics.unit_height) * mesh_mult * maxf(user_scale, 0.05)


static func foot_local_y(preset_id: String) -> float:
	return float(mesh_metrics(preset_id).foot_local_y)


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
