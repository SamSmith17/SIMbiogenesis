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
## Per-chunk draw distance (batches are spatially chunked ~256 m so AABB centers
## stay local — a single site-wide MultiMesh was culled while standing in edge trees).
const VISIBILITY_END := 1200.0

## Maps biome mesh slots to a card-factory species the factory understands.
## Slots with real SPECS entries (incl. Phase 5's palm/cactus families) pass
## through _resolve_species before this table is consulted.
const SLOT_ALIAS := {
	"conifer": "pine",
	"taiga": "pine",
	"broadleaf": "deciduous",
	"scrub": "shrub",
	# Named sub-species / crops keep their SPECS ids when present; biome aliases
	# above map to a base family. Extra aliases for common OSM labels:
	"crop": "wheat",
	"farmland": "wheat",
	"orchard_tree": "apple",
}

## Auto-veg drives final tree height through each record's `scale` (computed from a
## target canopy height in AutoVegetationGenerator._scale_for). The card factory's
## per-species bulk multipliers would double-apply, so they're neutralised to 1.0.
## The neutral values must WIN over the style dict — merging the other way let the
## style's deciduous_bulk_scale 1.6 overwrite the 1.0 and every auto deciduous tree
## rendered ×1.6 its OSM-derived height ("trees look wrong on first load").
## grass_field is neutralised for the same reason: the generator already bakes
## grass_field_bulk_scale into each record's scale (_scatter_grass_polygon), so the
## runtime multiplying it again squared the factor (×1.5625). grass_lawn is exempt —
## _build_grass_bulk_batches never applies the runtime multiplier to lawn.
## auto_tree_scale is the user-facing whole-forest size knob that replaces the old
## accidental oversizing (rebuild-only — no re-scatter needed to change it).
const NEUTRAL_BULK := {
	"pine_bulk_scale": 1.0,
	"deciduous_bulk_scale": 1.0,
	"shrub_bulk_scale": 1.0,
	"grass_field_bulk_scale": 1.0,
}


## Style dict with the per-species bulk multipliers forced neutral (see NEUTRAL_BULK)
## and the auto_tree_scale knob routed through the tree bulk keys the builders read.
static func neutralized_settings(settings: Dictionary) -> Dictionary:
	var s := settings.duplicate()
	s.merge(NEUTRAL_BULK, true)
	var tree_scale := clampf(float(settings.get("auto_tree_scale", 1.0)), 0.2, 3.0)
	if not is_equal_approx(tree_scale, 1.0):
		s["pine_bulk_scale"] = tree_scale
		s["deciduous_bulk_scale"] = tree_scale
		s["shrub_bulk_scale"] = tree_scale
	return s

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


## Re-registers already-built auto-vegetation batches with
## VegetationEnvironmentSync + VegetationWindDriver, without rebuilding meshes.
##
## Needed because the manual-layer rebuild (VegetationRuntime.rebuild(), driven
## by terrain_loader's deferred _start_manual_veg_rebuild) unconditionally
## clears ALL shader registrations via _clear_shader_registrations() — and on a
## fresh site the manual layer is usually empty, so nothing re-registers after
## it clears. Since that manual rebuild is deliberately deferred until the load
## sequence fully completes (i.e. AFTER auto-vegetation scatter already
## registered its batches), auto-scattered trees/grass would otherwise silently
## stop receiving seasonal (autumn/winter/snow) and wind uniform updates for
## the rest of the session. Call this right after any manual-layer rebuild.
static func reregister_existing(terrain: Node3D) -> void:
	# NOTE: a FREED terrain can't be guarded here — passing it to this typed
	# Node3D parameter throws "previously freed" at the call boundary. Callers
	# that run after an await MUST is_instance_valid(terrain) before calling.
	if terrain == null:
		return
	var root := terrain.get_node_or_null(ROOT_NAME) as Node3D
	if root == null:
		return
	for child in root.get_children():
		if child is MultiMeshInstance3D:
			_register_multimesh(child as MultiMeshInstance3D, _species_for_node(child as MultiMeshInstance3D))


static func _species_for_node(mi: MultiMeshInstance3D) -> String:
	return VegetationRuntime.species_from_bulk_name(mi.name)


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
		exclusions: Array = [], growth_map: VegetationInstanceMap = null) -> void:
	if terrain == null or layer == null:
		return
	if growth_map != null:
		growth_map.clear()
	_clear_shader_registrations()
	var s := neutralized_settings(settings)
	var root := ensure_root(terrain)
	_clear_children(root)
	for slot in layer.slots():
		_build_bulk_layer(root, str(slot), layer.bulk.get(slot, []), ground_y_at, s, growth_map)
	_build_hero_layer(root, layer.hero, ground_y_at, s)
	# See VegetationRuntime.rebuild()'s matching comment: _clear_shader_registrations()
	# above wipes the manual layer's registrations too, which this rebuild doesn't touch.
	VegetationRuntime.reregister_existing(terrain)


## Same as rebuild() but spreads the multimesh builds and hero-scene instantiation
## across separate idle frames. Used during the initial load so
## the whole vegetation layer doesn't upload to the GPU on one frame (a spike that
## can exit the process with no error on a weaker GPU). Falls back to the
## synchronous path when no SceneTree is available (e.g. headless tools).
static func rebuild_async(terrain: Node3D, layer: AutoVegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {},
		exclusions: Array = [], growth_map: VegetationInstanceMap = null) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		rebuild(terrain, layer, ground_y_at, settings, exclusions, growth_map)
		return
	if terrain == null or layer == null:
		return
	if growth_map != null:
		growth_map.clear()
	_clear_shader_registrations()
	var s := neutralized_settings(settings)
	var root := ensure_root(terrain)
	_clear_children(root)
	for slot in layer.slots():
		if not is_instance_valid(root):
			return
		_build_bulk_layer(root, str(slot), layer.bulk.get(slot, []), ground_y_at, s, growth_map)
		await tree.process_frame
	if not is_instance_valid(root):
		return
	await _build_hero_layer_async(root, layer.hero, ground_y_at, s, tree)
	# The hero build awaits across frames; the terrain may have been torn down
	# meanwhile (seasonal reground / rebuild during fast-forwarded plant growth).
	if not is_instance_valid(terrain) or not is_instance_valid(root):
		return
	VegetationRuntime.reregister_existing(terrain)


## Re-sample ground Y under each instance (called after a heightfield rebuild).
## Thread the live settings AND growth map — see VegetationRuntime.reground()'s
## comment for the bug a bare rebuild causes.
static func reground(terrain: Node3D, layer: AutoVegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {},
		growth_map: VegetationInstanceMap = null) -> void:
	rebuild(terrain, layer, ground_y_at, settings, [], growth_map)


static func _resolve_species(slot: String) -> String:
	if VegetationCardFactory.SPECS.has(slot):
		return slot
	if slot in VegetationLayer.ALL_SPECIES:
		return slot
	return str(SLOT_ALIAS.get(slot, "deciduous"))


## Auto (OSM) forests span ~3 km and are viewed from the drone, so the manual
## leaf/fur NEAR reach (deciduous ~100 m) drops them to the leafless FAR billboard
## tier at typical altitudes — the "auto trees have no leaves / wrong branches" bug.
## Copy the batch settings with the canopy LOD near/far distances remapped to the
## auto-only overrides so the leaf-shell NEAR tier stays alive much farther out.
## The manual (painted) render path never calls this, so its close-up reach is
## unchanged. Falls back to the manual keys, then hardcoded generous defaults.
static func _with_auto_lod_reach(species: String, settings: Dictionary) -> Dictionary:
	var np := "deciduous" if species == "deciduous" else "pine"
	# Precedence: the single Tune-look slider (auto_foliage_lod_reach_m) → a
	# per-species auto override → the manual near reach → a generous fallback.
	var near := float(settings.get("auto_foliage_lod_reach_m",
		settings.get("%s_auto_lod_near_m" % np,
			settings.get("%s_lod_near_m" % np, 300.0))))
	var s := settings.duplicate()
	# Spatial chunking (~256 m) keeps each MultiMesh AABB local, so NEAR/FAR
	# canopy LOD works again for auto forests (site-wide batches used to cull the
	# leaf tier). Keep auto's longer near-reach so drone views stay leafy.
	s["%s_lod_near_m" % np] = near
	s["%s_lod_far_begin_m" % np] = maxf(near - 20.0, 10.0)
	s["near_crisp_m"] = maxf(near, float(settings.get("near_crisp_m", 40.0)))
	s["far_dither_m"] = VISIBILITY_END + 60.0
	return s


static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()


static func _build_bulk_layer(root: Node3D, slot: String, records: Array,
		ground_y_at: Callable, settings: Dictionary,
		growth_map: VegetationInstanceMap = null) -> void:
	if records.is_empty():
		return
	var species := _resolve_species(slot)
	var batches := _partition_bulk_batches(records, settings)
	for batch in batches:
		var chunks := VegetationRuntime._partition_spatial_chunks(batch["records"] as Array)
		for chunk in chunks:
			_build_bulk_batch(root, slot, species, chunk["records"], ground_y_at,
				batch["settings"], growth_map, int(chunk["cx"]), int(chunk["cz"]))


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
			s.merge(VegetationLayer.coerce_card_colors(card as Dictionary), true)
		var key := _batch_settings_key(s)
		if key not in groups:
			groups[key] = {"settings": s, "records": []}
		(groups[key]["records"] as Array).append(d)
	var out: Array = []
	for key in groups:
		out.append(groups[key])
	return out


## Batch by the FULL settings content (matches VegetationRuntime._partition_bulk_batches).
## The old partial key hashed only tint/wind keys, so records carrying per-instance
## card_settings (shape, LOD, leaf density) were merged into a batch built from a
## DIFFERENT record's settings — some trees then rendered with the wrong mesh/LOD
## (e.g. billboards instead of leaf canopy) and ignored their own edits. Hashing the
## whole dict keeps identical settings in one batch while giving each distinct
## look its own correctly-built MultiMesh.
static func _batch_settings_key(settings: Dictionary) -> int:
	return hash(settings)


static func _build_bulk_batch(root: Node3D, slot: String, species: String, records: Array,
		ground_y_at: Callable, settings: Dictionary,
		growth_map: VegetationInstanceMap = null, chunk_x: int = 0, chunk_z: int = 0) -> void:
	if records.is_empty():
		return
	var family := VegetationCardFactory.mesh_family(species)
	var batch_settings := VegSpeciesCatalog.settings_with_variant(
		species, settings, VegetationCardFactory.SPECS)
	if family in VegetationLayer.GRASS_SPECIES or family.begins_with("grass_"):
		# Grass builder keys on family id (lawn/field); variant dims live in settings.
		VegetationRuntime._build_grass_bulk_batches(root, family, records, ground_y_at,
			batch_settings, growth_map, chunk_x, chunk_z)
		return
	if family == "deciduous" or family == "pine":
		var tree_end := float(batch_settings.get("auto_visibility_end_m", VISIBILITY_END))
		var lod_settings := _with_auto_lod_reach(family, batch_settings)
		# Ring dispatch (Phase 3) lives inside _build_canopy_lod_bulk_batches:
		# NEAR ring = leaf pair (EXEMPT from force_far — the bounded high-cost
		# core is the point of the static ring, even on a 30 km map), MID =
		# FAR cards, OUTER = impostor quad. auto_force_far_canopy demotes MID
		# to OUTER there ("impostor-only mode") instead of flattening the map.
		VegetationRuntime._build_canopy_lod_bulk_batches(root, species, records, ground_y_at,
			false, lod_settings, tree_end, growth_map,
			chunk_x, chunk_z)
		return
	var mesh := VegetationCardFactory.mesh_for_species(species, batch_settings)
	var use_surface_mats := VegetationCardFactory.mesh_has_surface_materials(species)
	var mat: ShaderMaterial = null
	if not use_surface_mats:
		mat = VegetationCardFactory.material_for_species(species, batch_settings)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, batch_settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, batch_settings)
	var vert_off := VegetationLayer.vertical_offset_for(family, batch_settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = records.size()
	var pending: Array = []
	var i := 0
	for item in records:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var base_scale := float(d.get("scale", 1.0)) * species_scale
		var scale := base_scale * VegetationGrowth.instance_scale_mult(species, d, settings)
		var record_vert := float(d.get("vert_off", vert_off))
		var gy: float = float(ground_y_at.call(x, z))
		mm.set_instance_transform(i, VegetationPaint.build_transform(
			x, gy, z, yaw, scale, false, Vector3.UP, record_vert, foot_y))
		if growth_map != null:
			pending.append({
				"record": d, "base_scale": base_scale, "vert_off": record_vert,
				"x": x, "z": z, "yaw": yaw, "ground_y": gy,
			})
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "Bulk_%s_%d_%d" % [slot, chunk_x, chunk_z]
	mi.multimesh = mm
	if use_surface_mats:
		mi.material_override = null
	else:
		mi.material_override = mat
	# Shadow casting is gated globally (off by default — big GPU win in play,
	# toggled on for solar analysis). Grass never casts.
	VegetationShadowPolicy.apply(mi, species)
	var vis_end := float(settings.get("grass_visibility_end_m",
		VegetationRuntime.GRASS_VISIBILITY_END)) if species in VegetationLayer.GRASS_SPECIES \
		else float(settings.get("auto_visibility_end_m", VISIBILITY_END))
	VegetationRuntime.apply_visibility_range(mi, VISIBILITY_BEGIN, vis_end)
	root.add_child(mi)
	if growth_map != null:
		for j in pending.size():
			var p: Dictionary = pending[j]
			VegetationRuntime._register_growth(growth_map, mi, j, p["record"], species,
				float(p["base_scale"]), float(p["vert_off"]), foot_y, false,
				float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
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
