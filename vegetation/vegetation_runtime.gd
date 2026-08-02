class_name VegetationRuntime
extends RefCounted

## Rebuilds MultiMesh bulk layers + hero tree instances under a terrain parent.

const VISIBILITY_BEGIN := 0.0
## Per-chunk draw distance. Chunks are ~CHUNK_SIZE_M so AABB centers stay near
## local trees — Godot visibility_range is distance to AABB *center*, not per tree.
const VISIBILITY_END := 1200.0
const GRASS_VISIBILITY_END := 600.0
const CHUNK_SIZE_M := 256.0


static func ensure_root(terrain: Node3D) -> Node3D:
	var root := terrain.get_node_or_null("Vegetation") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "Vegetation"
		terrain.add_child(root)
	return root


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


static func _register_growth(map: VegetationInstanceMap, mmi: MultiMeshInstance3D,
		idx: int, record: Dictionary, species: String, base_scale: float,
		vert_off: float, foot_y: float, align_to_surface: bool,
		x: float, z: float, yaw: float, ground_y: float = NAN) -> void:
	if map != null:
		map.add(mmi, idx, record, species, base_scale, vert_off, foot_y,
			align_to_surface, x, z, yaw, ground_y)


## Dither-fade band on every visibility-range edge. Godot's DEFAULT fade mode
## is DISABLED — a hard binary on/off, which is why whole 256 m chunks of
## forest used to pop in and out at the LOD boundary. FADE_SELF dither-fades
## each MultiMesh over the margin band instead (the legacy vegetation_scatter
## and prop_render_tuning paths already did this; the modern runtime never did).
const LOD_FADE_MARGIN_M := 24.0


## Set visibility range + dithered self-fade ON A FRESHLY BUILT node only.
## NEVER sweep visibility_range over live nodes at runtime — mass-mutating it
## hard-crashed the AMD Vulkan driver (see vegetation_shadow_policy.gd).
static func apply_visibility_range(mi: GeometryInstance3D, begin_m: float, end_m: float,
		margin_m: float = LOD_FADE_MARGIN_M) -> void:
	mi.visibility_range_begin = begin_m
	mi.visibility_range_end = end_m
	# A margin on a disabled edge (0.0 = no limit) would re-enable it.
	mi.visibility_range_begin_margin = margin_m if begin_m > 0.0 else 0.0
	mi.visibility_range_end_margin = margin_m if end_m > 0.0 else 0.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


static func _build_grass_bulk_batches(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, settings: Dictionary,
		growth_map: VegetationInstanceMap = null, chunk_x: int = 0, chunk_z: int = 0) -> void:
	var species_scale := GrassBuilder.bulk_scale(species, settings)
	var foot_y := GrassBuilder.foot_local_y()
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var grass_far := float(settings.get("grass_visibility_end_m", GRASS_VISIBILITY_END))
	for tier in [GrassBuilder.LodTier.NEAR, GrassBuilder.LodTier.MID, GrassBuilder.LodTier.FAR]:
		var mesh := GrassBuilder.mesh_for_lod(species, settings, tier)
		var mat := GrassBuilder.material_for_species(species, settings, tier)
		var vis := GrassBuilder.visibility_range_for_tier(tier, grass_far)
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
			var scale := float(d.get("scale", 1.0))
			if species != "grass_lawn":
				scale *= species_scale
			var base_scale := scale
			if species != "grass_lawn":
				scale *= VegetationGrowth.instance_scale_mult(species, d, settings)
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
			continue
		var mi := MultiMeshInstance3D.new()
		mi.name = "Bulk_%s_%s_%d_%d" % [species, tier, chunk_x, chunk_z]
		mi.multimesh = mm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		apply_visibility_range(mi, vis.x, vis.y)
		root.add_child(mi)
		if growth_map != null:
			for j in pending.size():
				var p: Dictionary = pending[j]
				_register_growth(growth_map, mi, j, p["record"], species,
					float(p["base_scale"]), float(p["vert_off"]), foot_y, false,
					float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
			if env != null and env.has_method("register_multimesh_instance"):
				env.register_multimesh_instance(mi, species)


static func _build_canopy_lod_bulk_batches(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, growth_map: VegetationInstanceMap = null,
		chunk_x: int = 0, chunk_z: int = 0) -> void:
	if not VegetationCardFactory.canopy_lod_enabled(species, settings):
		_build_canopy_single_batch(root, species, records, ground_y_at, align_to_surface,
			settings, visibility_end_m, VegetationCardFactory.CanopyLodTier.NEAR, growth_map,
			chunk_x, chunk_z)
		return
	# Phase 3a: static SoI-centred detail rings. Only chunks in the NEAR ring
	# carry the expensive leaf-shell tier (+ its far pair); MID/OUTER chunks
	# build the cheap FAR card mesh only, full-range. Tier is a property of
	# the CHUNK's distance to the site core, not the camera — the high-detail
	# region does not move with the player.
	var ring := VegTierRings.ring_for_chunk_settings(chunk_x, chunk_z, CHUNK_SIZE_M, settings)
	if ring != VegTierRings.RING_NEAR:
		_build_canopy_single_batch(root, species, records, ground_y_at, align_to_surface,
			settings, visibility_end_m, VegetationCardFactory.CanopyLodTier.FAR, growth_map,
			chunk_x, chunk_z)
		return
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	for tier in [VegetationCardFactory.CanopyLodTier.NEAR,
			VegetationCardFactory.CanopyLodTier.FAR]:
		var mesh := VegetationCardFactory.mesh_for_canopy_lod(species, settings, tier)
		var vis := VegetationCardFactory.canopy_visibility_range_for_tier(
			species, tier, settings, visibility_end_m)
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
				x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
			if growth_map != null:
				pending.append({
					"record": d, "base_scale": base_scale, "vert_off": record_vert,
					"x": x, "z": z, "yaw": yaw, "ground_y": gy,
				})
			i += 1
		mm.instance_count = i
		if i == 0:
			continue
		var mi := MultiMeshInstance3D.new()
		mi.name = "Bulk_%s_%d_%d_%d" % [species, tier, chunk_x, chunk_z]
		mi.multimesh = mm
		mi.material_override = null
		# Shadow casting is globally gated (off by default; on for solar analysis).
		VegetationShadowPolicy.apply(mi, species)
		apply_visibility_range(mi, vis.x, vis.y)
		root.add_child(mi)
		if growth_map != null:
			for j in pending.size():
				var p: Dictionary = pending[j]
				_register_growth(growth_map, mi, j, p["record"], species,
					float(p["base_scale"]), float(p["vert_off"]), foot_y, align_to_surface,
					float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
			if env != null and env.has_method("register_multimesh_instance"):
				env.register_multimesh_instance(mi, species)


static func _build_canopy_single_batch(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, tier: VegetationCardFactory.CanopyLodTier,
		growth_map: VegetationInstanceMap = null, chunk_x: int = 0, chunk_z: int = 0) -> void:
	var mesh := VegetationCardFactory.mesh_for_canopy_lod(species, settings, tier)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
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
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
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
	mi.name = "Bulk_%s_%d_%d" % [species, chunk_x, chunk_z]
	mi.multimesh = mm
	mi.material_override = null
	VegetationShadowPolicy.apply(mi, species)
	apply_visibility_range(mi, VISIBILITY_BEGIN, visibility_end_m)
	root.add_child(mi)
	if growth_map != null:
		for j in pending.size():
			var p: Dictionary = pending[j]
			_register_growth(growth_map, mi, j, p["record"], species,
				float(p["base_scale"]), float(p["vert_off"]), foot_y, align_to_surface,
				float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
		if env != null and env.has_method("register_multimesh_instance"):
			env.register_multimesh_instance(mi, species)


static func _build_deciduous_bulk_batches(root: Node3D, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, growth_map: VegetationInstanceMap = null) -> void:
	_build_canopy_lod_bulk_batches(root, "deciduous", records, ground_y_at,
		align_to_surface, settings, visibility_end_m, growth_map)


static func rebuild(terrain: Node3D, layer: VegetationLayer,
		ground_y_at: Callable, align_to_surface: bool = false,
		settings: Dictionary = {}, growth_map: VegetationInstanceMap = null) -> void:
	if terrain == null or layer == null:
		return
	if growth_map != null:
		growth_map.clear()
	_clear_shader_registrations()
	var s := layer.get_settings()
	if not settings.is_empty():
		s = settings.duplicate(true)
	var root := ensure_root(terrain)
	_clear_children(root)
	for species in layer.species_keys():
		_build_bulk_layer(root, species, layer.bulk.get(species, []), ground_y_at,
			align_to_surface, s, growth_map)
	_build_hero_layer(root, layer.hero, ground_y_at, s)
	# _clear_shader_registrations() above wipes ALL registrations, including the
	# auto-vegetation layer's — which this rebuild doesn't touch. Without this,
	# any manual-layer rebuild that runs after auto-vegetation has already
	# registered (e.g. the load-sequence's deferred manual rebuild, which
	# intentionally runs after auto-scatter) permanently drops auto-scattered
	# trees/grass from seasonal + wind uniform updates.
	AutoVegetationRuntime.reregister_existing(terrain)


static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()


## Re-registers already-built manual-layer batches with VegetationEnvironmentSync
## + VegetationWindDriver, without rebuilding meshes. Mirrors
## AutoVegetationRuntime.reregister_existing() — see that function's comment
## for why this is needed (both rebuild paths clear ALL registrations).
static func reregister_existing(terrain: Node3D) -> void:
	# NOTE: a FREED terrain can't be guarded here — passing it to this typed
	# Node3D parameter throws "previously freed" at the call boundary. Callers
	# that run after an await MUST is_instance_valid(terrain) before calling.
	if terrain == null:
		return
	var root := terrain.get_node_or_null("Vegetation") as Node3D
	if root == null:
		return
	var tree := Engine.get_main_loop()
	if not (tree is SceneTree):
		return
	var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
	for child in root.get_children():
		if child is MultiMeshInstance3D and env != null and env.has_method("register_multimesh_instance"):
			env.register_multimesh_instance(child as MultiMeshInstance3D, _species_for_node(child as MultiMeshInstance3D))


static func _species_for_node(mi: MultiMeshInstance3D) -> String:
	return species_from_bulk_name(mi.name)


## Recover species/slot from MultiMesh names like Bulk_<id>[_tier][_cx_cz].
static func species_from_bulk_name(n: String) -> String:
	if not n.begins_with("Bulk_"):
		return ""
	var rest := n.substr(5)
	var known: Array[String] = []
	for sid in VegSpeciesCatalog.all_selectable_ids():
		known.append(sid)
	for sid in VegSpeciesCatalog.BASE_FAMILIES:
		if sid not in known:
			known.append(sid)
	for sid in VegetationLayer.ALL_SPECIES:
		if sid not in known:
			known.append(sid)
	known.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	for sid in known:
		if rest == sid or rest.begins_with(sid + "_"):
			return sid
	# Fallback: strip trailing numeric chunk/tier tokens.
	var parts := rest.split("_")
	while parts.size() > 1 and str(parts[parts.size() - 1]).is_valid_int():
		parts.remove_at(parts.size() - 1)
	return "_".join(parts)


static func _visibility_end_for_species(species: String) -> float:
	var fam := VegSpeciesCatalog.mesh_family(species)
	if fam in VegetationLayer.GRASS_SPECIES or fam.begins_with("grass_"):
		return GRASS_VISIBILITY_END
	return VISIBILITY_END


static func _casts_shadow(species: String) -> int:
	var fam := VegSpeciesCatalog.mesh_family(species)
	if fam in VegetationLayer.GRASS_SPECIES or fam.begins_with("grass_"):
		return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON


static func _chunk_key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / CHUNK_SIZE_M)), int(floor(z / CHUNK_SIZE_M)))


static func _build_bulk_layer(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		growth_map: VegetationInstanceMap = null) -> void:
	if records.is_empty():
		return
	var batches := _partition_bulk_batches(records, settings)
	for batch in batches:
		var chunks := _partition_spatial_chunks(batch["records"] as Array)
		for chunk in chunks:
			_build_bulk_batch(root, species, chunk["records"], ground_y_at, align_to_surface,
				batch["settings"], growth_map, chunk["cx"], chunk["cz"])


## Split records into ~CHUNK_SIZE_M cells so MultiMesh AABB centers stay local.
static func _partition_spatial_chunks(records: Array) -> Array:
	var groups: Dictionary = {}
	for item in records:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var ck := _chunk_key(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		if ck not in groups:
			groups[ck] = []
		(groups[ck] as Array).append(d)
	var out: Array = []
	for ck in groups:
		out.append({"cx": ck.x, "cz": ck.y, "records": groups[ck]})
	return out


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
		var key := hash(s)
		if key not in groups:
			groups[key] = {"settings": s, "records": []}
		(groups[key]["records"] as Array).append(d)
	var out: Array = []
	for key in groups:
		out.append(groups[key])
	return out


static func _build_bulk_batch(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		growth_map: VegetationInstanceMap = null, chunk_x: int = 0, chunk_z: int = 0) -> void:
	if records.is_empty():
		return
	var family := VegSpeciesCatalog.mesh_family(species)
	var batch_settings := VegSpeciesCatalog.settings_with_variant(
		species, settings, VegetationCardFactory.SPECS)
	if family in VegetationLayer.GRASS_SPECIES or family.begins_with("grass_"):
		_build_grass_bulk_batches(root, family, records, ground_y_at, batch_settings, growth_map,
			chunk_x, chunk_z)
		return
	if family == "deciduous" or family == "pine":
		var tree_end := float(batch_settings.get("auto_visibility_end_m",
			_visibility_end_for_species(species)))
		# Large world maps force FAR billboards only (same flag as AutoVegetation).
		# Near-spawn manual paint was the Mt. Vernon orbit prim bomb once auto
		# forests were thinned — leafy NEAR shells × dual MultiMeshes.
		if bool(batch_settings.get("auto_force_far_canopy", false)):
			_build_canopy_single_batch(root, species, records, ground_y_at,
				align_to_surface, batch_settings, tree_end,
				VegetationCardFactory.CanopyLodTier.FAR, growth_map, chunk_x, chunk_z)
			return
		_build_canopy_lod_bulk_batches(root, species, records, ground_y_at, align_to_surface,
			batch_settings, tree_end, growth_map, chunk_x, chunk_z)
		return
	var mesh := VegetationCardFactory.mesh_for_species(species, batch_settings)
	var use_surface := VegetationCardFactory.mesh_has_surface_materials(species)
	var mat: ShaderMaterial = null
	if not use_surface:
		mat = VegetationCardFactory.material_for_species(species, batch_settings)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, batch_settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, batch_settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, batch_settings)
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
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
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
	mi.name = "Bulk_%s_%d_%d" % [species, chunk_x, chunk_z]
	mi.multimesh = mm
	if use_surface:
		mi.material_override = null
	else:
		mi.material_override = mat
	VegetationShadowPolicy.apply(mi, species)
	apply_visibility_range(mi, VISIBILITY_BEGIN, _visibility_end_for_species(species))
	root.add_child(mi)
	if growth_map != null:
		for j in pending.size():
			var p: Dictionary = pending[j]
			_register_growth(growth_map, mi, j, p["record"], species,
				float(p["base_scale"]), float(p["vert_off"]), foot_y, align_to_surface,
				float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
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
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var preset := str(d.get("preset", "pine_1"))
		var scene := HeroTreeCatalog.load_scene(preset)
		if scene == null:
			continue
		var inst: Node3D = scene.instantiate() as Node3D
		if inst == null:
			continue
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var user_scale := float(d.get("scale", 1.0))
		var gy: float = float(d.get("ground_y", ground_y_at.call(x, z)))
		var world_scale := HeroTreeCatalog.resolved_hero_scale(preset, user_scale)
		var foot_y := HeroTreeCatalog.foot_local_y(preset)
		inst.name = "Hero_%d" % idx
		heroes.add_child(inst)
		HeroTreeCatalog.strip_night_glow(inst)
		inst.scale = Vector3.ONE * world_scale
		inst.rotation = Vector3(0.0, yaw, 0.0)
		inst.position = Vector3(
			x,
			gy + vert_off - foot_y * world_scale - VegetationPaint.GROUND_SINK_M,
			z)
		idx += 1


## Re-sample ground Y under each instance (after a heightfield edit). MUST thread
## the caller's live settings + growth map: regrounding with `{}` rebuilt the
## manual layer with no style at all — no tints/drape/seasonal uniforms, every
## growth multiplier back to 1.0 (full-size), and the default 200 m NEAR canopy
## reach where the load-time build used FAR billboards. That was the "pressing V
## suddenly shows full-detail trees" bug, and the skipped growth-map rebuild left
## `_manual_growth_map` pointing at freed MultiMeshes (manual growth died).
static func reground(terrain: Node3D, layer: VegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {},
		growth_map: VegetationInstanceMap = null) -> void:
	rebuild(terrain, layer, ground_y_at, false, settings, growth_map)
