class_name AutoVegetationRuntime
extends RefCounted

## Renders an AutoVegetationLayer under a dedicated "AutoVegetation" terrain child
## (manual vegetation owns "Vegetation"; the two never collide). One
## MultiMeshInstance3D per slot + individual hero scenes — the same draw strategy
## as VegetationRuntime, reusing VegetationCardFactory / HeroTreeCatalog /
## VegetationPaint. Distance LOD is visibility-range cull for now; the impostor
## middle tier is a later phase.

const ROOT_NAME := "AutoVegetation"
const VISIBILITY_BEGIN := 0.0
## Wider than manual veg (900 m) because auto-veg covers ~3 km; cull beyond this.
const VISIBILITY_END := 2200.0

## Maps biome mesh slots to a card-factory species the factory understands. Slots
## already named pine/deciduous/shrub pass through; future biome slots
## (palm/conifer/taiga, added in Phase 3) fall back here until real meshes land.
const SLOT_ALIAS := {
	"conifer": "pine",
	"taiga": "pine",
	"palm": "deciduous",
	"broadleaf": "deciduous",
	"scrub": "shrub",
}

## Auto-veg drives final tree height through each record's `scale` (computed from a
## target canopy height in AutoVegetationGenerator._scale_for). The card factory's
## per-species bulk multipliers would double-apply, so they're neutralised to 1.0.
const NEUTRAL_BULK := {
	"pine_bulk_scale": 1.0,
	"deciduous_bulk_scale": 1.0,
	"shrub_bulk_scale": 1.0,
}


static func ensure_root(terrain: Node3D) -> Node3D:
	var root := terrain.get_node_or_null(ROOT_NAME) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = ROOT_NAME
		terrain.add_child(root)
	return root


static func clear(terrain: Node3D) -> void:
	if terrain == null:
		return
	var root := terrain.get_node_or_null(ROOT_NAME)
	if root != null:
		root.queue_free()


static func _clear_shader_registrations() -> void:
	var tree := Engine.get_main_loop()
	if tree == null or not (tree is SceneTree):
		return
	var root := (tree as SceneTree).root
	var env := root.get_node_or_null("VegetationEnvironmentSync")
	if env != null and env.has_method("clear_registered_materials"):
		env.clear_registered_materials()
	var wind := root.get_node_or_null("VegetationWindDriver")
	if wind != null and wind.has_method("clear_registered_materials"):
		wind.clear_registered_materials()


## Hero scenes are GLB instances (mesh + texture uploads); cap how many we spin up
## per frame in the async path so the load-completion build doesn't spike the GPU.
const HERO_CHUNK := 6


static func rebuild(terrain: Node3D, layer: AutoVegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {},
		exclusions: Array = []) -> void:
	if terrain == null or layer == null:
		return
	_clear_shader_registrations()
	var s := NEUTRAL_BULK.duplicate()
	s.merge(settings, true)
	var root := ensure_root(terrain)
	_clear_children(root)
	for slot in layer.slots():
		_build_bulk_layer(root, str(slot), layer.bulk.get(slot, []), ground_y_at, s)
	_build_hero_layer(root, layer.hero, ground_y_at, s)


## Same as rebuild() but spreads the multimesh builds and hero-scene instantiation
## across separate idle frames. Used during the initial load so
## the whole vegetation layer doesn't upload to the GPU on one frame (a spike that
## can exit the process with no error on a weaker GPU). Falls back to the
## synchronous path when no SceneTree is available (e.g. headless tools).
static func rebuild_async(terrain: Node3D, layer: AutoVegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {},
		exclusions: Array = []) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		rebuild(terrain, layer, ground_y_at, settings, exclusions)
		return
	if terrain == null or layer == null:
		return
	_clear_shader_registrations()
	var s := NEUTRAL_BULK.duplicate()
	s.merge(settings, true)
	var root := ensure_root(terrain)
	_clear_children(root)
	for slot in layer.slots():
		if not is_instance_valid(root):
			return
		_build_bulk_layer(root, str(slot), layer.bulk.get(slot, []), ground_y_at, s)
		await tree.process_frame
	if not is_instance_valid(root):
		return
	await _build_hero_layer_async(root, layer.hero, ground_y_at, s, tree)


## Re-sample ground Y under each instance (called after a heightfield rebuild).
static func reground(terrain: Node3D, layer: AutoVegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {}) -> void:
	rebuild(terrain, layer, ground_y_at, settings)


static func _resolve_species(slot: String) -> String:
	if slot in VegetationLayer.ALL_SPECIES:
		return slot
	return str(SLOT_ALIAS.get(slot, "deciduous"))


static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()


static func _build_bulk_layer(root: Node3D, slot: String, records: Array,
		ground_y_at: Callable, settings: Dictionary) -> void:
	if records.is_empty():
		return
	var species := _resolve_species(slot)
	var batches := _partition_bulk_batches(records, settings)
	for batch in batches:
		_build_bulk_batch(root, slot, species, batch["records"], ground_y_at, batch["settings"])


static func _partition_bulk_batches(records: Array, base_settings: Dictionary) -> Array:
	var groups: Dictionary = {}
	for item in records:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var s := base_settings.duplicate()
		if d.has("vert_off"):
			s["vertical_offset_m"] = float(d["vert_off"])
		var card: Variant = d.get("card_settings", {})
		if card is Dictionary and not (card as Dictionary).is_empty():
			s.merge(card, true)
		var key := _batch_settings_key(s)
		if key not in groups:
			groups[key] = {"settings": s, "records": []}
		(groups[key]["records"] as Array).append(d)
	var out: Array = []
	for key in groups:
		out.append(groups[key])
	return out


static func _batch_settings_key(settings: Dictionary) -> int:
	var h := 0
	for k in ["vertical_offset_m", "foliage_tint", "seasonal_tint", "drape_match_strength",
			"haze_color", "wind_strength", "wind_speed"]:
		if settings.has(k):
			h = h ^ hash(settings[k])
	return h


static func _build_bulk_batch(root: Node3D, slot: String, species: String, records: Array,
		ground_y_at: Callable, settings: Dictionary) -> void:
	if records.is_empty():
		return
	if species in VegetationLayer.GRASS_SPECIES:
		VegetationRuntime._build_grass_bulk_batches(root, species, records, ground_y_at, settings)
		return
	var mesh := VegetationCardFactory.mesh_for_species(species, settings)
	var use_surface_mats := VegetationCardFactory.mesh_has_surface_materials(species)
	var mat: ShaderMaterial = null
	if not use_surface_mats:
		mat = VegetationCardFactory.material_for_species(species, settings)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = records.size()
	var i := 0
	for item in records:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var scale := float(d.get("scale", 1.0)) * species_scale
		var record_vert := float(d.get("vert_off", vert_off))
		var gy: float = float(ground_y_at.call(x, z))
		mm.set_instance_transform(i, VegetationPaint.build_transform(
			x, gy, z, yaw, scale, false, Vector3.UP, record_vert, foot_y))
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "Bulk_%s" % slot
	mi.multimesh = mm
	if use_surface_mats:
		mi.material_override = null
	else:
		mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if species in VegetationLayer.GRASS_SPECIES:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = VegetationRuntime.GRASS_VISIBILITY_END
	else:
		mi.visibility_range_end = VISIBILITY_END
	mi.visibility_range_begin = VISIBILITY_BEGIN
	root.add_child(mi)
	_register_multimesh(mi, species)


static func _register_multimesh(mi: MultiMeshInstance3D, species: String = "") -> void:
	var tree := Engine.get_main_loop()
	if tree == null or not (tree is SceneTree):
		return
	var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
	if env != null and env.has_method("register_multimesh_instance"):
		env.register_multimesh_instance(mi, species)


static func _build_hero_layer(root: Node3D, records: Array,
		ground_y_at: Callable, settings: Dictionary) -> void:
	if records.is_empty():
		return
	var heroes := Node3D.new()
	heroes.name = "HeroTrees"
	root.add_child(heroes)
	var vert_off := float(settings.get("vertical_offset_m", 0.0))
	var idx := 0
	for item in records:
		_build_hero_instance(heroes, item, ground_y_at, vert_off, idx)
		idx += 1


## Frame-budgeted hero instantiation: HERO_CHUNK GLB scenes per idle frame.
static func _build_hero_layer_async(root: Node3D, records: Array,
		ground_y_at: Callable, settings: Dictionary, tree: SceneTree) -> void:
	if records.is_empty():
		return
	var heroes := Node3D.new()
	heroes.name = "HeroTrees"
	root.add_child(heroes)
	var vert_off := float(settings.get("vertical_offset_m", 0.0))
	var idx := 0
	for item in records:
		if not is_instance_valid(heroes):
			return
		_build_hero_instance(heroes, item, ground_y_at, vert_off, idx)
		idx += 1
		if tree != null and idx % HERO_CHUNK == 0:
			await tree.process_frame


static func _build_hero_instance(heroes: Node3D, item: Variant,
		ground_y_at: Callable, vert_off: float, idx: int) -> void:
	if not (item is Dictionary):
		return
	var d: Dictionary = item
	var preset := str(d.get("preset", "pine_1"))
	var scene := HeroTreeCatalog.load_scene(preset)
	if scene == null:
		return
	var inst: Node3D = scene.instantiate() as Node3D
	if inst == null:
		return
	var x := float(d.get("x", 0.0))
	var z := float(d.get("z", 0.0))
	var yaw := float(d.get("yaw", 0.0))
	var user_scale := float(d.get("scale", 1.0))
	var gy: float = float(d.get("ground_y", ground_y_at.call(x, z)))
	var world_scale := HeroTreeCatalog.resolved_hero_scale(preset, user_scale)
	var foot_y := HeroTreeCatalog.foot_local_y(preset)
	var hero_vert := float(d.get("vert_off", vert_off))
	inst.name = "Hero_%d" % idx
	heroes.add_child(inst)
	HeroTreeCatalog.strip_night_glow(inst)
	inst.scale = Vector3.ONE * world_scale
	inst.rotation = Vector3(0.0, yaw, 0.0)
	inst.position = Vector3(
		x,
		gy + hero_vert - foot_y * world_scale - VegetationPaint.GROUND_SINK_M,
		z)
