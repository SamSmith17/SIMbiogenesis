class_name VegetationRuntime
extends RefCounted

## Rebuilds MultiMesh bulk layers + hero tree instances under a terrain parent.

const VISIBILITY_BEGIN := 0.0
## Per-chunk draw distance. Chunks are ~CHUNK_SIZE_M so AABB centers stay near
## local trees — Godot visibility_range is distance to AABB *center*, not per tree.
const VISIBILITY_END := 1200.0
const GRASS_VISIBILITY_END := 600.0
## Forest-floor plants (sword fern, blackberry): knee-high, thousands of them
## under a canopy — past a couple of hundred metres they are sub-pixel.
const UNDERSTORY_VISIBILITY_END := 220.0
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


## Growth scales a plant about its FOOT in the shader. Trees stand on their
## model origin; a shrub card's foot sits at `foot_y`, so its materials are told
## where to pivot (they are cached per settings, so the value is stable).
static func stamp_growth_pivot(mesh: Mesh, override: Material, foot_y: float) -> void:
	if override is ShaderMaterial:
		(override as ShaderMaterial).set_shader_parameter("growth_pivot_y", foot_y)
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i)
		if m is ShaderMaterial:
			(m as ShaderMaterial).set_shader_parameter("growth_pivot_y", foot_y)


## Style key: seeded mesh variants per tree species (1 = one mesh per species,
## the pre-2026-10-15 look). DEFAULT_TREE_VARIANTS is what an untouched style
## draws.
const KEY_TREE_VARIANTS := "tree_variants"
const DEFAULT_TREE_VARIANTS := 3
## Runtime-only: a batch built for one variant ("v1") — names its nodes.
const KEY_BATCH_SUFFIX := "_batch_suffix"


## Which of `n` variants a tree record draws, from its position alone.
static func variant_index(d: Dictionary, n: int) -> int:
	if n <= 1:
		return 0
	var x := float(d.get("x", 0.0))
	var z := float(d.get("z", 0.0))
	var hh := sin(x * 12.9898 + z * 78.233 + 51.0 * 37.719) * 43758.5453
	return clampi(int((hh - floor(hh)) * float(n)), 0, n - 1)


## The species segment of a batch node name: "fir" or "fir_v1".
static func _batch_species_tag(species: String, settings: Dictionary) -> String:
	var suf := str(settings.get(KEY_BATCH_SUFFIX, ""))
	return species if suf.is_empty() else "%s_%s" % [species, suf]


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
		margin_m: float = LOD_FADE_MARGIN_M, end_margin_m: float = -1.0) -> void:
	mi.visibility_range_begin = begin_m
	mi.visibility_range_end = end_m
	# A margin on a disabled edge (0.0 = no limit) would re-enable it.
	# end_margin_m < 0 = the same band as the begin edge.
	var end_margin := end_margin_m if end_margin_m >= 0.0 else margin_m
	mi.visibility_range_begin_margin = margin_m if begin_m > 0.0 else 0.0
	mi.visibility_range_end_margin = end_margin if end_m > 0.0 else 0.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


static func _build_grass_bulk_batches(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, settings: Dictionary,
		chunk_x: int = 0, chunk_z: int = 0) -> void:
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
			var record_vert := float(d.get("vert_off", vert_off))
			var gy: float = float(ground_y_at.call(x, z))
			mm.set_instance_transform(i, VegetationPaint.build_transform(
				x, gy, z, yaw, scale, false, Vector3.UP, record_vert, foot_y))
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
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
			if env != null and env.has_method("register_multimesh_instance"):
				env.register_multimesh_instance(mi, species)


## Vegetation Overhaul v2 LOD: every tree chunk builds exactly TWO batches —
## the real 3D mesh inside the camera-based detail range, and the baked
## impostor beyond it. The impostor is rendered FROM the NEAR mesh, so a
## distant tree matches the tuned look; the crossed-card tier survives only as
## the bake-pending stand-in (and permanently under --headless, where the
## baker never runs — deterministic selftests). The SoI ring system and the
## large-map force_far flattening are GONE: force_far was why a 30 km map
## (Mt Vernon) never showed a real 3D tree at ANY distance.
##
## Ranges are set at BUILD time only (AMD Vulkan hard-crashes on live
## visibility_range sweeps); the detail-distance slider triggers the normal
## debounced rebuild. `tree_detail_eff_m` is the loader's budget-shrunk value
## (VegLodPolicy); the raw user slider is the fallback.
static func _build_canopy_lod_bulk_batches(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, chunk_x: int = 0, chunk_z: int = 0) -> void:
	# Instance variants (2026-10-15): a stand of one species used to be ONE
	# mesh repeated, rotated and scaled. Each tree now draws one of
	# `tree_variants` seeded meshes, picked by its POSITION (so a tree keeps
	# its look when its neighbours change). The index rides a family-prefixed
	# key no style layer sets — the impostor bake key hashes family keys, so
	# each variant bakes its own silhouette.
	var n_var := clampi(int(round(float(settings.get(KEY_TREE_VARIANTS, DEFAULT_TREE_VARIANTS)))), 1, 4)
	if n_var > 1 and not settings.has(KEY_BATCH_SUFFIX):
		var fam := VegSpeciesCatalog.mesh_family(species)
		var groups: Array = []
		for _k in n_var:
			groups.append([])
		for item in records:
			if item is Dictionary:
				(groups[variant_index(item as Dictionary, n_var)] as Array).append(item)
		for k in n_var:
			if (groups[k] as Array).is_empty():
				continue
			var sk := settings.duplicate()
			sk["%s_variant_index" % fam] = k
			sk[KEY_BATCH_SUFFIX] = "v%d" % k
			_build_canopy_lod_bulk_batches(root, species, groups[k], ground_y_at,
				align_to_surface, sk, visibility_end_m, chunk_x, chunk_z)
		return
	# Overhaul v2.1: the per-species LOD LADDER — the player orders the
	# representations (mesh / photocard / impostor) and may disable any; the
	# default chain "mesh,impostor" reproduces the shipped two-band model
	# exactly. One batch per band, ranges set at BUILD time only.
	var chain := VegetationCardFactory.lod_chain(species, settings)
	if not VegetationCardFactory.canopy_lod_enabled(species, settings):
		# Style opted out of the LOD handoff: full mesh at every distance
		# (an explicit, costly choice — the budget shrink still applies).
		chain = [VegLodPolicy.REP_MESH]
	var detail_m := clampf(float(settings.get("tree_detail_eff_m",
		settings.get("tree_detail_distance_m", 220.0))), 40.0, 4000.0)
	var photo_m := clampf(float(settings.get("tree_photocard_distance_m", 700.0)),
		60.0, 8000.0)
	var far_end := VegLodPolicy.far_tier_end(chain, visibility_end_m, settings)
	var bands := VegLodPolicy.chain_bands(chain, detail_m, photo_m, far_end)
	for band_v in bands:
		var band: Dictionary = band_v
		var rep := str(band["rep"])
		var b_begin := float(band["begin_m"])
		var b_end := float(band["end_m"])
		# The handoff fade grows with distance (VegLodPolicy.fade_margin_for):
		# both sides of one boundary must use the same band, so a band's
		# begin edge uses its own begin distance and its end edge its end.
		var begin_fade := VegLodPolicy.fade_margin_for(b_begin)
		var range_begin := maxf(b_begin - begin_fade, 0.0) if b_begin > 0.0 else -1.0
		var margins := Vector2(begin_fade, VegLodPolicy.fade_margin_for(b_end))
		match rep:
			VegLodPolicy.REP_MESH:
				_build_canopy_single_batch(root, species, records, ground_y_at,
					align_to_surface, settings, b_end,
					VegetationCardFactory.CanopyLodTier.NEAR,
					chunk_x, chunk_z, range_begin, null, "", margins)
			VegLodPolicy.REP_PHOTOCARD:
				var photo_mesh := VegetationCardFactory.photocard_mesh(species, settings)
				if photo_mesh != null:
					_build_canopy_single_batch(root, species, records, ground_y_at,
						align_to_surface, settings, b_end,
						VegetationCardFactory.CanopyLodTier.FAR,
						chunk_x, chunk_z, range_begin,
						photo_mesh, "photo", margins)
			VegLodPolicy.REP_IMPOSTOR:
				var iset := VegImpostorBaker.cached_set(species, settings)
				if iset != null and iset.is_usable():
					_build_impostor_batch(root, species, records, ground_y_at,
						align_to_surface, settings, b_end, iset,
						chunk_x, chunk_z, range_begin, margins)
				else:
					# Bake pending (or permanently headless): crossed-card
					# stand-in, deterministic — the completed bake debounces
					# one rebuild through the loader.
					VegImpostorBaker.request_async(species, settings)
					_build_canopy_single_batch(root, species, records, ground_y_at,
						align_to_surface, settings, b_end,
						VegetationCardFactory.CanopyLodTier.FAR,
						chunk_x, chunk_z, range_begin, null, "", margins)


## OUTER-ring impostor batch: one camera-facing baked quad per tree (2 tris vs
## ~86 for FAR cards, ~5,000 for the leaf tier). Same record/transform/growth
## plumbing as the card batches; the quad mesh carries its own surface
## material (veg_impostor.gdshader), registered with the env sync so the
## seasonal uniforms stay tier-consistent.
static func _build_impostor_batch(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, iset: VegImpostorSet,
		chunk_x: int = 0, chunk_z: int = 0,
		range_begin: float = -1.0, margins: Vector2 = Vector2(-1.0, -1.0)) -> void:
	var mesh := VegImpostorBaker.quad_mesh_for(iset)
	VegImpostorBaker.stamp_snag(mesh, species, settings)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Growth rides the instance, not the transform: the shader scales each
	# plant from its birth year (veg_growth.gdshaderinc). Must be set while
	# instance_count is still 0.
	mm.use_custom_data = true
	var growth_bp := VegetationGrowth.batch_params(species, settings)
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
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, 0.0))
		mm.set_instance_custom_data(i, VegetationGrowth.custom_for(growth_bp, d))
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "Bulk_%s_imp_%d_%d" % [_batch_species_tag(species, settings), chunk_x, chunk_z]
	mi.multimesh = mm
	# A regrown generation stands up to a metre off the original spot
	# (veg_growth.gdshaderinc), outside the AABB the transforms imply.
	mi.extra_cull_margin = 2.0
	mi.material_override = null
	# A 2-tri billboard casts a plank shadow — never cast from impostors.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	apply_visibility_range(mi,
		range_begin if range_begin >= 0.0 else VISIBILITY_BEGIN, visibility_end_m,
		margins.x if margins.x >= 0.0 else LOD_FADE_MARGIN_M, margins.y)
	root.add_child(mi)
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
		if env != null and env.has_method("register_multimesh_instance"):
			env.register_multimesh_instance(mi, species)


static func _build_canopy_single_batch(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, tier: VegetationCardFactory.CanopyLodTier,
		chunk_x: int = 0, chunk_z: int = 0,
		range_begin: float = -1.0, mesh_override: ArrayMesh = null,
		name_tag: String = "", margins: Vector2 = Vector2(-1.0, -1.0)) -> void:
	var mesh := mesh_override if mesh_override != null \
			else VegetationCardFactory.mesh_for_canopy_lod(species, settings, tier)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Growth rides the instance, not the transform: the shader scales each
	# plant from its birth year (veg_growth.gdshaderinc). Must be set while
	# instance_count is still 0.
	mm.use_custom_data = true
	var growth_bp := VegetationGrowth.batch_params(species, settings)
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
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
		mm.set_instance_custom_data(i, VegetationGrowth.custom_for(growth_bp, d))
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	var sp_tag := _batch_species_tag(species, settings)
	mi.name = "Bulk_%s_%d_%d_%d" % [sp_tag, tier, chunk_x, chunk_z] \
			if name_tag.is_empty() \
			else "Bulk_%s_%s_%d_%d" % [sp_tag, name_tag, chunk_x, chunk_z]
	mi.multimesh = mm
	# A regrown generation stands up to a metre off the original spot
	# (veg_growth.gdshaderinc), outside the AABB the transforms imply.
	mi.extra_cull_margin = 2.0
	mi.material_override = null
	VegetationShadowPolicy.apply(mi, species)
	apply_visibility_range(mi,
		range_begin if range_begin >= 0.0 else VISIBILITY_BEGIN, visibility_end_m,
		margins.x if margins.x >= 0.0 else LOD_FADE_MARGIN_M, margins.y)
	root.add_child(mi)
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
		if env != null and env.has_method("register_multimesh_instance"):
			env.register_multimesh_instance(mi, species)


static func _build_deciduous_bulk_batches(root: Node3D, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float) -> void:
	_build_canopy_lod_bulk_batches(root, "deciduous", records, ground_y_at,
		align_to_surface, settings, visibility_end_m)


static func rebuild(terrain: Node3D, layer: VegetationLayer,
		ground_y_at: Callable, align_to_surface: bool = false,
		settings: Dictionary = {}) -> void:
	if terrain == null or layer == null:
		return
	_clear_shader_registrations()
	var s := layer.get_settings()
	if not settings.is_empty():
		s = settings.duplicate(true)
	var root := ensure_root(terrain)
	_clear_children(root)
	for species in layer.species_keys():
		_build_bulk_layer(root, species, layer.bulk.get(species, []), ground_y_at,
			align_to_surface, s)
	_build_hero_layer(root, layer.hero, ground_y_at, s)
	# _clear_shader_registrations() above wipes ALL registrations, including the
	# auto-vegetation layer's — which this rebuild doesn't touch. Without this,
	# any manual-layer rebuild that runs after auto-vegetation has already
	# registered (e.g. the load-sequence's deferred manual rebuild, which
	# intentionally runs after auto-scatter) permanently drops auto-scattered
	# trees/grass from seasonal + wind uniform updates.
	AutoVegetationRuntime.reregister_existing(terrain)


## Detach BEFORE freeing: a queue_freed batch stays in the tree until the end
## of the frame, so the rebuild's new "Bulk_<species>_…" nodes collided with
## it and were auto-renamed "@MultiMeshInstance3D@…" — which broke everything
## that finds a batch by its name (chunk_of_batch_node for incremental chunk
## rebuilds, leaf-fall, the harness checks).
static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		root.remove_child(child)
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


## main.gd's day_ambient — the denominator turning the live scene ambient
## into a 0..1 "fraction of full daylight".
const DAY_AMBIENT_REF := 0.3
## The lit canopy tiers' night_darkness leaves ~35% of albedo, which the
## scene ambient then scales in the PBR pass.
const NIGHT_FLOOR_DARKNESS := 0.35


## Brightness floor for the UNSHADED impostor tier once night_factor
## saturates: (scene ambient / day ambient) × the lit tiers' night_darkness
## leftover — i.e. the same composition a LIT tree lands on at that instant.
## VegetationEnvironmentSync pushes this as `night_ambient_mul` every poll.
## The hard-coded 0.30 floor this replaced left the far forest ~2 orders of
## magnitude brighter than the near tier at full night (glowing cutouts on a
## dark horizon, near blooming once the night glow_hdr_threshold drops).
static func impostor_night_floor(ambient_energy: float) -> float:
	return clampf(ambient_energy / DAY_AMBIENT_REF, 0.004, 1.0) * NIGHT_FLOOR_DARKNESS


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
	if species in VegSpeciesCatalog.UNDERSTORY_IDS:
		return UNDERSTORY_VISIBILITY_END
	return VISIBILITY_END


static func _casts_shadow(species: String) -> int:
	var fam := VegSpeciesCatalog.mesh_family(species)
	if fam in VegetationLayer.GRASS_SPECIES or fam.begins_with("grass_"):
		return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON


static func _chunk_key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / CHUNK_SIZE_M)), int(floor(z / CHUNK_SIZE_M)))


## Public form of the chunk key — the unit an incremental rebuild works in.
static func chunk_key_at(x: float, z: float) -> Vector2i:
	return _chunk_key(x, z)


## Every 256 m chunk a polygon can touch, as a Vector2i→true set. Computed from
## the polygon's AABB, so it is a SUPERSET for concave outlines: rebuilding a
## chunk the fill never reached costs a little time and changes nothing, while
## missing one would leave stale trees on screen.
##
## The saving scales with how local the edit is — an orchard covers one or two
## chunks out of hundreds. A very large outline (a 1,700 ha forest) legitimately
## spans most of the map and approaches a full rebuild, which is the honest cost
## of that edit rather than a failure of this path.
static func chunk_keys_for_polygon(poly: PackedVector2Array) -> Dictionary:
	var out := {}
	if poly.size() < 3:
		return out
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.y)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.y)
	var c0 := _chunk_key(mn.x, mn.y)
	var c1 := _chunk_key(mx.x, mx.y)
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			out[Vector2i(cx, cz)] = true
	return out


## Chunk a batch node's name encodes, or null when it carries none. Names are
## built as Bulk_<slot>[_<tier>|_imp]_<cx>_<cz> across the three builders, so the
## chunk is always the last two underscore-separated integers.
static func chunk_of_batch_node(node_name: String) -> Variant:
	var parts := node_name.split("_")
	if parts.size() < 3:
		return null
	var cz_tok := str(parts[parts.size() - 1])
	var cx_tok := str(parts[parts.size() - 2])
	if not cz_tok.is_valid_int() or not cx_tok.is_valid_int():
		return null
	return Vector2i(cx_tok.to_int(), cz_tok.to_int())


static func _build_bulk_layer(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary) -> void:
	if records.is_empty():
		return
	var batches := _partition_bulk_batches(records, settings)
	for batch in batches:
		var chunks := _partition_spatial_chunks(batch["records"] as Array)
		for chunk in chunks:
			_build_bulk_batch(root, species, chunk["records"], ground_y_at, align_to_surface,
				batch["settings"], chunk["cx"], chunk["cz"])


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
		chunk_x: int = 0, chunk_z: int = 0) -> void:
	if records.is_empty():
		return
	var family := VegSpeciesCatalog.mesh_family(species)
	var batch_settings := VegSpeciesCatalog.settings_with_variant(
		species, settings, VegetationCardFactory.SPECS)
	if family in VegetationLayer.GRASS_SPECIES or family.begins_with("grass_"):
		_build_grass_bulk_batches(root, family, records, ground_y_at, batch_settings, chunk_x, chunk_z)
		return
	if family == "deciduous" or family == "pine":
		var tree_end := float(batch_settings.get("auto_visibility_end_m",
			_visibility_end_for_species(species)))
		# Overhaul v2: force_far is GONE — painted trees always get the real 3D
		# mesh inside the (budget-shrunk) detail range, impostors beyond. On
		# large maps the budget shrink in VegLodPolicy is the prim guard.
		_build_canopy_lod_bulk_batches(root, species, records, ground_y_at, align_to_surface,
			batch_settings, tree_end, chunk_x, chunk_z)
		return
	var mesh := VegetationCardFactory.mesh_for_species(species, batch_settings)
	var use_surface := VegetationCardFactory.mesh_has_surface_materials(species)
	var mat: ShaderMaterial = null
	if not use_surface:
		mat = VegetationCardFactory.material_for_species(species, batch_settings)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, batch_settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, batch_settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, batch_settings)
	stamp_growth_pivot(mesh, mat, foot_y)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Growth rides the instance, not the transform: the shader scales each
	# plant from its birth year (veg_growth.gdshaderinc). Must be set while
	# instance_count is still 0.
	mm.use_custom_data = true
	var growth_bp := VegetationGrowth.batch_params(species, settings)
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
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
		mm.set_instance_custom_data(i, VegetationGrowth.custom_for(growth_bp, d))
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "Bulk_%s_%d_%d" % [species, chunk_x, chunk_z]
	mi.multimesh = mm
	# A regrown generation stands up to a metre off the original spot
	# (veg_growth.gdshaderinc), outside the AABB the transforms imply.
	mi.extra_cull_margin = 2.0
	if use_surface:
		mi.material_override = null
	else:
		mi.material_override = mat
	VegetationShadowPolicy.apply(mi, species)
	apply_visibility_range(mi, VISIBILITY_BEGIN, _visibility_end_for_species(species))
	root.add_child(mi)
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
## the caller's live settings: regrounding with `{}` rebuilt the manual layer
## with no style at all — no tints/drape/seasonal uniforms, no growth data, and
## the default 200 m NEAR canopy reach where the load-time build used FAR
## billboards. That was the "pressing V suddenly shows full-detail trees" bug.
static func reground(terrain: Node3D, layer: VegetationLayer,
		ground_y_at: Callable, settings: Dictionary = {}) -> void:
	rebuild(terrain, layer, ground_y_at, false, settings)
