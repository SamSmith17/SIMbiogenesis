class_name VegetationCardFactory
extends RefCounted

## Runtime procedural card meshes + foliage materials for pine / deciduous / shrub.

const FOLIAGE_SHADER := preload("res://vegetation/foliage.gdshader")
const LEAF_CANOPY_SHADER := preload("res://vegetation/leaf_canopy.gdshader")
const BARK_SHADER := preload("res://vegetation/bark.gdshader")
const BAKED_SHRUB_MESH := "res://vegetation/baked/shrub_mesh.tres"
const BAKED_SHRUB_MAT := "res://vegetation/baked/shrub_material.tres"

const SPECS := {
	# Tree families carry v3 REAL-WORLD dims: height_m (total, exact),
	# crown_m (crown width, exact), trunk_cm (diameter), crown_base_pct
	# (where the crown starts as % of height) and a shape archetype id
	# (VegTreeArchetypes). Colors are unchanged. Non-tree families (shrub /
	# palm / cactus / grass / crops) keep the legacy width/height card dims.
	"pine": {"height_m": 17.0, "crown_m": 7.0, "trunk_cm": 45.0,
		"crown_base_pct": 8.0, "archetype": "conical",
		"top": Color(0.05, 0.14, 0.06), "bottom": Color(0.07, 0.10, 0.04),
		"highlight": Color(0.12, 0.24, 0.08),
		"bark": Color(0.16, 0.11, 0.06)},
	"spruce": {"height_m": 21.0, "crown_m": 6.0, "trunk_cm": 50.0,
		"crown_base_pct": 5.0, "archetype": "conical",
		"top": Color(0.04, 0.16, 0.08), "bottom": Color(0.06, 0.11, 0.05),
		"highlight": Color(0.10, 0.22, 0.10),
		"bark": Color(0.14, 0.10, 0.06)},
	"cedar": {"height_m": 15.0, "crown_m": 8.5, "trunk_cm": 65.0,
		"crown_base_pct": 10.0, "archetype": "conical",
		"top": Color(0.08, 0.16, 0.09), "bottom": Color(0.10, 0.12, 0.06),
		"highlight": Color(0.18, 0.28, 0.12),
		"bark": Color(0.20, 0.12, 0.08)},
	"fir": {"height_m": 23.0, "crown_m": 6.0, "trunk_cm": 55.0,
		"crown_base_pct": 5.0, "archetype": "conical",
		"top": Color(0.03, 0.12, 0.07), "bottom": Color(0.05, 0.09, 0.04),
		"highlight": Color(0.09, 0.20, 0.09),
		"bark": Color(0.15, 0.10, 0.05)},
	"redwood": {"height_m": 45.0, "crown_m": 9.0, "trunk_cm": 200.0,
		"crown_base_pct": 15.0, "archetype": "conical",
		"top": Color(0.06, 0.18, 0.08), "bottom": Color(0.08, 0.12, 0.05),
		"highlight": Color(0.14, 0.26, 0.10),
		"bark": Color(0.28, 0.12, 0.08)},
	"deciduous": {"height_m": 14.0, "crown_m": 11.0, "trunk_cm": 55.0,
		"crown_base_pct": 25.0, "archetype": "round",
		"top": Color(0.18, 0.38, 0.10), "bottom": Color(0.24, 0.16, 0.06),
		"highlight": Color(0.42, 0.52, 0.16),
		"bark": Color(0.18, 0.12, 0.07)},
	"chestnut": {"height_m": 20.0, "crown_m": 16.0, "trunk_cm": 85.0,
		"crown_base_pct": 18.0, "archetype": "spreading",
		"top": Color(0.16, 0.34, 0.09), "bottom": Color(0.22, 0.14, 0.05),
		"highlight": Color(0.38, 0.48, 0.14),
		"bark": Color(0.22, 0.14, 0.08)},
	"maple": {"height_m": 16.0, "crown_m": 12.0, "trunk_cm": 60.0,
		"crown_base_pct": 22.0, "archetype": "round",
		"top": Color(0.20, 0.40, 0.10), "bottom": Color(0.28, 0.18, 0.06),
		"highlight": Color(0.55, 0.35, 0.10),
		"bark": Color(0.20, 0.14, 0.08)},
	"cottonwood": {"height_m": 24.0, "crown_m": 14.0, "trunk_cm": 95.0,
		"crown_base_pct": 25.0, "archetype": "vase",
		"top": Color(0.22, 0.42, 0.12), "bottom": Color(0.26, 0.20, 0.08),
		"highlight": Color(0.45, 0.55, 0.18),
		"bark": Color(0.24, 0.20, 0.14)},
	"aspen": {"height_m": 15.0, "crown_m": 5.0, "trunk_cm": 25.0,
		"crown_base_pct": 40.0, "archetype": "columnar",
		"top": Color(0.25, 0.45, 0.12), "bottom": Color(0.30, 0.22, 0.08),
		"highlight": Color(0.55, 0.62, 0.20),
		"bark": Color(0.85, 0.88, 0.82)},
	"birch": {"height_m": 14.0, "crown_m": 6.0, "trunk_cm": 28.0,
		"crown_base_pct": 35.0, "archetype": "columnar",
		"top": Color(0.20, 0.40, 0.12), "bottom": Color(0.24, 0.18, 0.07),
		"highlight": Color(0.40, 0.52, 0.18),
		"bark": Color(0.92, 0.92, 0.90)},
	"beech": {"height_m": 19.0, "crown_m": 14.0, "trunk_cm": 75.0,
		"crown_base_pct": 20.0, "archetype": "spreading",
		"top": Color(0.15, 0.36, 0.10), "bottom": Color(0.22, 0.16, 0.06),
		"highlight": Color(0.38, 0.50, 0.15),
		"bark": Color(0.35, 0.30, 0.22)},
	"apple": {"height_m": 6.0, "crown_m": 6.5, "trunk_cm": 35.0,
		"crown_base_pct": 20.0, "archetype": "round",
		"top": Color(0.22, 0.42, 0.10), "bottom": Color(0.28, 0.16, 0.06),
		"highlight": Color(0.55, 0.25, 0.18),
		"bark": Color(0.22, 0.14, 0.08)},
	"pear": {"height_m": 8.0, "crown_m": 5.5, "trunk_cm": 32.0,
		"crown_base_pct": 22.0, "archetype": "vase",
		"top": Color(0.20, 0.40, 0.10), "bottom": Color(0.26, 0.15, 0.05),
		"highlight": Color(0.50, 0.55, 0.18),
		"bark": Color(0.20, 0.13, 0.07)},
	"orange": {"height_m": 5.0, "crown_m": 4.5, "trunk_cm": 25.0,
		"crown_base_pct": 18.0, "archetype": "round",
		"top": Color(0.12, 0.36, 0.10), "bottom": Color(0.18, 0.22, 0.06),
		"highlight": Color(0.95, 0.55, 0.10),
		"bark": Color(0.25, 0.16, 0.08)},
	"avocado": {"height_m": 9.0, "crown_m": 8.0, "trunk_cm": 45.0,
		"crown_base_pct": 20.0, "archetype": "round",
		"top": Color(0.08, 0.28, 0.10), "bottom": Color(0.12, 0.18, 0.06),
		"highlight": Color(0.20, 0.40, 0.12),
		"bark": Color(0.18, 0.12, 0.08)},
	"shrub": {"width": 1.4, "height": 1.15,
		"top": Color(0.12, 0.24, 0.08), "bottom": Color(0.16, 0.14, 0.06),
		"highlight": Color(0.28, 0.38, 0.14)},
	"cactus": {"width": 0.55, "height": 1.80,
		"top": Color(0.18, 0.38, 0.16), "bottom": Color(0.14, 0.28, 0.12),
		"highlight": Color(0.30, 0.48, 0.22)},
	"joshua_tree": {"width": 1.8, "height": 3.2,
		"top": Color(0.22, 0.32, 0.12), "bottom": Color(0.28, 0.24, 0.10),
		"highlight": Color(0.40, 0.42, 0.18)},
	"grass_lawn": {"width": 0.55, "height": 0.48,
		"top": Color(0.14, 0.42, 0.12), "bottom": Color(0.10, 0.32, 0.08),
		"highlight": Color(0.28, 0.58, 0.18)},
	"grass_field": {"width": 0.70, "height": 0.95,
		"top": Color(0.38, 0.48, 0.12), "bottom": Color(0.28, 0.36, 0.08),
		"highlight": Color(0.52, 0.58, 0.20)},
	"corn": {"width": 0.45, "height": 1.80,
		"top": Color(0.30, 0.55, 0.12), "bottom": Color(0.45, 0.50, 0.10),
		"highlight": Color(0.85, 0.75, 0.20)},
	"wheat": {"width": 0.50, "height": 0.95,
		"top": Color(0.55, 0.52, 0.18), "bottom": Color(0.45, 0.40, 0.12),
		"highlight": Color(0.75, 0.68, 0.25)},
	"barley": {"width": 0.48, "height": 0.85,
		"top": Color(0.50, 0.48, 0.16), "bottom": Color(0.42, 0.38, 0.12),
		"highlight": Color(0.70, 0.62, 0.22)},
	"beans": {"width": 0.55, "height": 0.55,
		"top": Color(0.20, 0.45, 0.12), "bottom": Color(0.16, 0.32, 0.08),
		"highlight": Color(0.35, 0.58, 0.18)},
	"quinoa": {"width": 0.42, "height": 1.10,
		"top": Color(0.45, 0.40, 0.22), "bottom": Color(0.35, 0.32, 0.14),
		"highlight": Color(0.70, 0.45, 0.35)},
	"squash": {"width": 0.90, "height": 0.40,
		"top": Color(0.25, 0.50, 0.12), "bottom": Color(0.20, 0.38, 0.08),
		"highlight": Color(0.85, 0.65, 0.15)},
	"tomatoes": {"width": 0.60, "height": 0.70,
		"top": Color(0.18, 0.42, 0.10), "bottom": Color(0.14, 0.30, 0.08),
		"highlight": Color(0.85, 0.20, 0.12)},
	"potatoes": {"width": 0.65, "height": 0.45,
		"top": Color(0.22, 0.40, 0.12), "bottom": Color(0.18, 0.30, 0.08),
		"highlight": Color(0.40, 0.55, 0.18)},
	"brassicas": {"width": 0.55, "height": 0.50,
		"top": Color(0.15, 0.38, 0.18), "bottom": Color(0.12, 0.28, 0.12),
		"highlight": Color(0.30, 0.55, 0.28)},
	"lettuce": {"width": 0.45, "height": 0.28,
		"top": Color(0.20, 0.55, 0.18), "bottom": Color(0.15, 0.42, 0.12),
		"highlight": Color(0.40, 0.70, 0.28)},
	# --- Phase 5: palms (palm builder; width = frond spread, height = trunk) ---
	"palm": {"width": 5.5, "height": 9.0, "trunk_w": 0.35,
		"top": Color(0.13, 0.34, 0.10), "bottom": Color(0.10, 0.24, 0.07),
		"highlight": Color(0.35, 0.52, 0.16),
		"bark": Color(0.42, 0.34, 0.24)},
	"coconut_palm": {"width": 6.5, "height": 14.0, "trunk_w": 0.35,
		"top": Color(0.14, 0.36, 0.11), "bottom": Color(0.10, 0.26, 0.08),
		"highlight": Color(0.40, 0.56, 0.18),
		"bark": Color(0.48, 0.40, 0.30)},
	"date_palm": {"width": 6.0, "height": 12.0, "trunk_w": 0.55,
		"top": Color(0.16, 0.32, 0.12), "bottom": Color(0.12, 0.24, 0.09),
		"highlight": Color(0.42, 0.50, 0.20),
		"bark": Color(0.40, 0.30, 0.20)},
	"fan_palm": {"width": 4.5, "height": 8.0, "trunk_w": 0.45,
		"top": Color(0.15, 0.35, 0.13), "bottom": Color(0.11, 0.26, 0.09),
		"highlight": Color(0.38, 0.52, 0.20),
		"bark": Color(0.38, 0.30, 0.22)},
	# --- Phase 5: cacti (cactus builder; width = body/arm spread) ---
	"saguaro": {"width": 2.6, "height": 6.0,
		"top": Color(0.16, 0.34, 0.15), "bottom": Color(0.12, 0.26, 0.11),
		"highlight": Color(0.30, 0.46, 0.22)},
	"prickly_pear": {"width": 1.6, "height": 1.2,
		"top": Color(0.19, 0.38, 0.16), "bottom": Color(0.14, 0.28, 0.12),
		"highlight": Color(0.36, 0.52, 0.24)},
	# --- Phase 5: tropical / food broadleaf variants (deciduous builder) ---
	"walnut": {"height_m": 18.0, "crown_m": 14.0, "trunk_cm": 80.0,
		"crown_base_pct": 22.0, "archetype": "spreading",
		"top": Color(0.17, 0.36, 0.10), "bottom": Color(0.22, 0.16, 0.06),
		"highlight": Color(0.40, 0.50, 0.16),
		"bark": Color(0.24, 0.18, 0.12)},
	"olive": {"height_m": 6.0, "crown_m": 6.0, "trunk_cm": 50.0,
		"crown_base_pct": 18.0, "archetype": "round",
		"top": Color(0.28, 0.38, 0.22), "bottom": Color(0.22, 0.28, 0.16),
		"highlight": Color(0.55, 0.60, 0.38),
		"bark": Color(0.32, 0.28, 0.22)},
	"mango": {"height_m": 12.0, "crown_m": 10.0, "trunk_cm": 55.0,
		"crown_base_pct": 18.0, "archetype": "round",
		"top": Color(0.10, 0.30, 0.09), "bottom": Color(0.14, 0.20, 0.07),
		"highlight": Color(0.30, 0.46, 0.14),
		"bark": Color(0.22, 0.16, 0.10)},
	"banana": {"height_m": 5.0, "crown_m": 4.0, "trunk_cm": 30.0,
		"crown_base_pct": 45.0, "archetype": "vase",
		"top": Color(0.20, 0.46, 0.14), "bottom": Color(0.16, 0.36, 0.10),
		"highlight": Color(0.45, 0.65, 0.22),
		"bark": Color(0.30, 0.36, 0.18)},
	"ficus": {"height_m": 15.0, "crown_m": 14.0, "trunk_cm": 90.0,
		"crown_base_pct": 16.0, "archetype": "spreading",
		"top": Color(0.10, 0.28, 0.09), "bottom": Color(0.14, 0.20, 0.08),
		"highlight": Color(0.26, 0.42, 0.14),
		"bark": Color(0.36, 0.32, 0.26)},
	"acacia": {"height_m": 8.0, "crown_m": 12.0, "trunk_cm": 45.0,
		"crown_base_pct": 45.0, "archetype": "vase",
		"top": Color(0.22, 0.36, 0.12), "bottom": Color(0.26, 0.24, 0.10),
		"highlight": Color(0.48, 0.54, 0.20),
		"bark": Color(0.26, 0.20, 0.14)},
}


## Canopy LOD tiers — deciduous: NEAR = leaf shells, FAR = billboards.
## Pine: same whorl geometry both tiers; NEAR = furry billboards, FAR = plain.
enum CanopyLodTier { NEAR, FAR }
## Back-compat alias for existing call sites.
const DeciduousLodTier = CanopyLodTier


static func mesh_family(species: String) -> String:
	return VegSpeciesCatalog.mesh_family(species)


static func mesh_for_species(species: String, settings: Dictionary = {}) -> ArrayMesh:
	var key := "mesh|%s|-1|%d" % [species, hash(settings)]
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ArrayMesh:
		return cached
	return VegAssetCache.store(key, _build_mesh_for_species(species, settings))


static func _build_mesh_for_species(species: String, settings: Dictionary) -> ArrayMesh:
	var family := mesh_family(species)
	var s := VegSpeciesCatalog.settings_with_variant(species, settings, SPECS)
	# Phase 5 photocard upgrade: a PNG dropped at
	# assets/vegetation/photocards/<id>.png (or user://veg_photocards/) swaps
	# the species to textured crossed cards, no code change. Canopy families
	# (pine/deciduous) are EXEMPT here — their photocard rides the FAR tier
	# only (see mesh_for_canopy_lod): a flat card 10 m from the camera reads
	# worse than the procedural leaf shells, but it beats the crossed-puff
	# FAR cards hands down.
	if family != "pine" and family != "deciduous":
		var photo := VegSpeciesRegistry.photocard_texture(species)
		if photo != null:
			return _build_photocard_mesh(species, s, photo)
	match family:
		"deciduous":
			return mesh_for_deciduous_lod(s, CanopyLodTier.NEAR)
		"pine":
			return mesh_for_pine_lod(s, CanopyLodTier.NEAR)
		"shrub":
			return _build_shrub_mesh(_shrub_spec(s, species), s)
		"palm":
			return _build_palm_mesh(_palm_spec(s, species), s)
		"cactus":
			return _build_cactus_mesh(_cactus_spec(s, species), s, species)
		"grass_lawn":
			return _build_grass_mesh(_grass_lawn_spec(s, species))
		"grass_field":
			return _build_grass_mesh(_grass_field_spec(s, species))
	var spec: Dictionary = SPECS.get(species, SPECS.get(family, SPECS["shrub"]))
	return _build_card_mesh(float(spec["width"]), float(spec["height"]))


## True when mesh carries per-surface materials (trunk + foliage surfaces).
## Photocard meshes and palms embed their materials too.
static func mesh_has_surface_materials(species: String) -> bool:
	if VegSpeciesRegistry.photocard_texture(species) != null:
		return true
	var family := mesh_family(species)
	return family == "deciduous" or family == "pine" or family == "palm"


## NEAR = procedural leaf shells; FAR = legacy crossed-billboard canopy.
static func mesh_for_deciduous_lod(settings: Dictionary, tier: CanopyLodTier) -> ArrayMesh:
	var s := settings.duplicate(true)
	s["deciduous_leaf_shells_enabled"] = tier == CanopyLodTier.NEAR
	var sid := str(s.get("_variant_species", "deciduous"))
	return _build_deciduous_mesh(_deciduous_spec(s, sid), s)


static func mesh_for_pine_lod(settings: Dictionary, tier: CanopyLodTier) -> ArrayMesh:
	var s := settings.duplicate(true)
	var sid := str(s.get("_variant_species", "pine"))
	# FAR must be a real billboard (~8 tris). The old path only disabled fur and
	# kept the full whorl mesh — useless for large-map force_far prim budgets.
	if tier == CanopyLodTier.FAR:
		return _build_pine_far_billboard(_pine_spec(s, sid), s)
	s["pine_fur_enabled"] = true
	return _build_pine_mesh(_pine_spec(s, sid), s)


## Minimal crossed-card pine — the bake-pending stand-in tier (~8 tris).
static func _build_pine_far_billboard(spec: Dictionary, settings: Dictionary) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var trunk_w := float(spec.get("trunk_w", 0.24))
	var trunk_h := card_h * 0.94
	var trunk_verts := PackedVector3Array()
	var trunk_uvs := PackedVector2Array()
	var trunk_normals := PackedVector3Array()
	var trunk_indices := PackedInt32Array()
	for card_i in 2:
		_add_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w, trunk_h, 0.0, float(card_i) * PI * 0.5, Vector3(0.0, 0.85, 0.0))
	var foliage_verts := PackedVector3Array()
	var foliage_uvs := PackedVector2Array()
	var foliage_normals := PackedVector3Array()
	var foliage_indices := PackedInt32Array()
	for card_i in 2:
		_add_card(foliage_verts, foliage_uvs, foliage_normals, foliage_indices,
			card_w * 0.95, card_h * 0.72, trunk_h * 0.28,
			float(card_i) * PI * 0.5, Vector3(0.0, 0.72, 0.0))
	# Exact-size pass (matches the NEAR mesh so the LOD swap doesn't pop).
	var norm_arrays: Array = [trunk_verts, foliage_verts]
	_normalize_tree_surfaces(norm_arrays, float(spec.get("height_m", card_h)),
		float(spec.get("crown_m", card_w)))
	trunk_verts = norm_arrays[0]
	foliage_verts = norm_arrays[1]
	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species("pine", settings))
	var foliage_arr: Array = []
	foliage_arr.resize(Mesh.ARRAY_MAX)
	foliage_arr[Mesh.ARRAY_VERTEX] = foliage_verts
	foliage_arr[Mesh.ARRAY_TEX_UV] = foliage_uvs
	foliage_arr[Mesh.ARRAY_NORMAL] = foliage_normals
	foliage_arr[Mesh.ARRAY_INDEX] = foliage_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, foliage_arr)
	var mat_settings := settings.duplicate(true)
	mat_settings["pine_fur_strength"] = 0.0
	mesh.surface_set_material(1, material_for_species("pine", mat_settings))
	return mesh


static func deciduous_lod_enabled(settings: Dictionary) -> bool:
	return bool(settings.get("deciduous_leaf_lod_enabled", true))


static func pine_lod_enabled(settings: Dictionary) -> bool:
	if settings.has("pine_fur_lod_enabled"):
		return bool(settings.get("pine_fur_lod_enabled", true))
	return bool(settings.get("pine_needle_lod_enabled", true))


static func canopy_lod_enabled(species: String, settings: Dictionary) -> bool:
	var family := mesh_family(species)
	if family == "deciduous":
		return deciduous_lod_enabled(settings)
	if family == "pine":
		return pine_lod_enabled(settings)
	return false


static func mesh_for_canopy_lod(species: String, settings: Dictionary, tier: CanopyLodTier) -> ArrayMesh:
	var key := "mesh|%s|%d|%d" % [species, tier, hash(settings)]
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ArrayMesh:
		return cached
	var family := mesh_family(species)
	var s := VegSpeciesCatalog.settings_with_variant(species, settings, SPECS)
	var mesh: ArrayMesh
	# Photocard upgrade for the FAR tier: a real cutout beats the crossed-puff
	# cards at distance, while NEAR keeps the full procedural leaf shells.
	if tier == CanopyLodTier.FAR and (family == "pine" or family == "deciduous"):
		var photo := VegSpeciesRegistry.photocard_texture(species)
		if photo != null:
			return VegAssetCache.store(key, _build_photocard_mesh(species, s, photo))
	if family == "deciduous":
		mesh = mesh_for_deciduous_lod(s, tier)
	elif family == "pine":
		mesh = mesh_for_pine_lod(s, tier)
	else:
		mesh = mesh_for_species(species, settings)
	return VegAssetCache.store(key, mesh)


static func _configure_cutout_shadow(_mat: ShaderMaterial, _threshold: float = 0.35) -> void:
	# Alpha scissor + shadow clipping is handled in the shader render_mode
	# (ShaderMaterial has no BaseMaterial3D.transparency property in Godot 4).
	pass


static func _configure_foliage_cutout_shadow(mat: ShaderMaterial) -> void:
	_configure_cutout_shadow(mat, 0.35)


static func material_for_species(species: String, settings: Dictionary = {}) -> ShaderMaterial:
	var key := "mat|%s|%d" % [species, hash(settings)]
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ShaderMaterial:
		return cached
	return VegAssetCache.store(key, _build_material_for_species(species, settings))


static func _build_material_for_species(species: String, settings: Dictionary) -> ShaderMaterial:
	var family := mesh_family(species)
	var s := VegSpeciesCatalog.settings_with_variant(species, settings, SPECS)
	var spec: Dictionary = SPECS.get(species, SPECS.get(family, SPECS["shrub"]))
	match family:
		"deciduous":
			spec = _deciduous_spec(s, species)
		"pine":
			spec = _pine_spec(s, species)
		"shrub":
			spec = _shrub_spec(s, species)
		"palm":
			spec = _palm_spec(s, species)
		"cactus":
			spec = _cactus_spec(s, species)
		"grass_lawn":
			spec = _grass_lawn_spec(s, species)
		"grass_field":
			spec = _grass_field_spec(s, species)
	var mat := ShaderMaterial.new()
	mat.shader = FOLIAGE_SHADER
	if family == "deciduous":
		mat.set_shader_parameter("albedo_tex", _build_cluster_foliage_texture(spec, "deciduous"))
	elif family == "palm":
		mat.set_shader_parameter("albedo_tex", _build_palm_frond_texture(spec))
	elif family == "cactus":
		mat.set_shader_parameter("albedo_tex", _build_cactus_texture(spec, species))
	elif family.begins_with("grass_"):
		mat.set_shader_parameter("albedo_tex", _build_grass_blade_texture(spec))
	else:
		mat.set_shader_parameter("albedo_tex", _build_cluster_foliage_texture(spec, family))
	_apply_foliage_uniforms(mat, family, s)
	_configure_foliage_cutout_shadow(mat)
	return mat


static func bark_material_for_species(species: String, settings: Dictionary = {}) -> ShaderMaterial:
	var key := "bark|%s|%d" % [species, hash(settings)]
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ShaderMaterial:
		return cached
	return VegAssetCache.store(key, _build_bark_material_for_species(species, settings))


static func _build_bark_material_for_species(species: String, settings: Dictionary) -> ShaderMaterial:
	var family := mesh_family(species)
	var s := VegSpeciesCatalog.settings_with_variant(species, settings, SPECS)
	var spec: Dictionary
	match family:
		"deciduous":
			spec = _deciduous_spec(s, species)
		"pine":
			spec = _pine_spec(s, species)
		_:
			spec = SPECS.get(species, SPECS.get(family, SPECS["shrub"]))
	var mat := ShaderMaterial.new()
	mat.shader = BARK_SHADER
	mat.set_shader_parameter("albedo_tex", _build_bark_texture(spec))
	# Player bark tint: family key (species overrides land on it re-prefixed),
	# beating the SPECS variant fill riding bark_albedo_tint — same user-edit >
	# SPECS ladder as every other key.
	var fam_bark := "%s_bark_tint" % family
	if s.get(fam_bark) is Color:
		s = s.duplicate()
		s["bark_albedo_tint"] = s[fam_bark]
	_apply_bark_uniforms(mat, s)
	return mat


static func species_bulk_scale(species: String, settings: Dictionary) -> float:
	var family := mesh_family(species)
	match family:
		# Tree families are EXACT-size (v3: height_m is normalized into the
		# mesh) — no hidden multiplier, painted == previewed == authored.
		"pine", "deciduous":
			return 1.0
		"shrub":
			return float(settings.get("shrub_bulk_scale", 1.0))
		"grass_lawn":
			return float(settings.get("grass_lawn_bulk_scale", 1.0))
		"grass_field":
			return float(settings.get("grass_field_bulk_scale", 1.0))
	return 1.0


static var _foot_cache: Dictionary = {}


static func clear_foot_cache() -> void:
	_foot_cache.clear()
	# Every style-change site that invalidates foot heights invalidates built
	# meshes/materials for the same reason — keep the two caches in lockstep.
	VegAssetCache.clear()


static func foot_local_y(species: String, settings: Dictionary = {}) -> float:
	# Tree families always build from y=0 (v3 normalized meshes) — never pay a
	# mesh build for a constant.
	var fam := mesh_family(species)
	if fam == "deciduous" or fam == "pine":
		return 0.0
	var key := "%s:%s" % [species, _foot_settings_key(settings)]
	if _foot_cache.has(key):
		return float(_foot_cache[key])
	var mesh := mesh_for_species(species, settings)
	var foot := mesh.get_aabb().position.y if mesh != null else 0.0
	_foot_cache[key] = foot
	return foot


static func _foot_settings_key(settings: Dictionary) -> String:
	if settings.is_empty():
		return "default"
	# Whole-dict hash: the old hand-listed 13-float key silently went stale
	# whenever a shape key was added or renamed.
	return str(hash(settings))


## True when the player explicitly set `key` (family edit or species override,
## via the VegStyleStore provenance side channel) — derived macro values yield
## to explicit Advanced-slider edits.
static func _user_set(settings: Dictionary, key: String) -> bool:
	var user: Variant = settings.get(VegStyleStore.KEY_USER_FAMILY, [])
	return user is Array and key in (user as Array)


static func _derived_or_user(settings: Dictionary, key: String, derived: float) -> float:
	if _user_set(settings, key):
		return float(settings.get(key, derived))
	return derived


## v3 spec (Vegetation Overhaul v2): real-world dims + archetype-derived SC
## params. The spec carries BOTH the honest values (height_m / crown_m /
## trunk_r / crown_base) and the legacy internal fields the builders consume
## (width / height / trunk_w / trunk_h), mapped so the trunk TUBE radius equals
## exactly trunk_r. The adapter keys (adapter_settings) translate the archetype
## + macros into the builder's internal knob namespace at this one choke point.
static func _deciduous_spec(settings: Dictionary, species: String = "deciduous") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["deciduous"]).duplicate(true)
	var out := {
		"top": base.get("top", Color(0.18, 0.38, 0.10)),
		"bottom": base.get("bottom", Color(0.24, 0.16, 0.06)),
		"highlight": base.get("highlight", Color(0.42, 0.52, 0.16)),
		"bark": base.get("bark", Color(0.18, 0.12, 0.07)),
	}
	var height := clampf(float(settings.get("deciduous_height_m",
		base.get("height_m", 14.0))), 1.5, 90.0)
	var crown_w := clampf(float(settings.get("deciduous_crown_width_m",
		base.get("crown_m", 11.0))), 1.0, 60.0)
	var trunk_cm := clampf(float(settings.get("deciduous_trunk_diameter_cm",
		base.get("trunk_cm", 55.0))), 4.0, 400.0)
	var crown_base := clampf(float(settings.get("deciduous_crown_base_pct",
		base.get("crown_base_pct", 25.0))) / 100.0, 0.0, 0.9)
	var archetype := str(settings.get("deciduous_archetype", base.get("archetype", "round")))
	if not VegTreeArchetypes.is_valid(archetype):
		archetype = str(base.get("archetype", "round"))
	out["height_m"] = height
	out["crown_m"] = crown_w
	out["trunk_r"] = trunk_cm / 200.0
	out["crown_base"] = crown_base
	out["archetype"] = archetype
	var sc := VegTreeArchetypes.builder_params(archetype,
		float(settings.get("deciduous_branchiness", 0.55)),
		float(settings.get("deciduous_crookedness", 0.45)),
		float(settings.get("deciduous_droop", 0.15)),
		int(round(float(settings.get("deciduous_variant_seed", 0)))))
	out.merge(sc, true)
	var fol := VegTreeArchetypes.foliage_params(
		float(settings.get("deciduous_foliage_density", 0.65)))
	out["leaf_density"] = _derived_or_user(settings, "deciduous_leaf_density",
		float(fol["leaf_density"]))
	out["leaf_gap"] = _derived_or_user(settings, "deciduous_leaf_gap",
		float(fol["leaf_gap"]))
	out["cluster_size_mul"] = float(fol["cluster_size"])
	out["shell_delta"] = int(fol["shell_delta"])
	# Internal frame: the trunk spine ends mid-crown; the crown envelope runs
	# crown_bottom → just under the exact height (normalization trues it up).
	var crown_bottom := height * crown_base
	var spine_top := lerpf(crown_bottom, height, 0.45)
	out["trunk_h"] = spine_top
	out["height"] = height * 0.98 - spine_top  # legacy crown_h field
	# Legacy trunk_w drove the tube at 0.28×trunk_w — invert so the tube radius
	# comes out at exactly trunk_r and every internal ratio keeps working.
	out["trunk_w"] = out["trunk_r"] / 0.28
	# Envelope width at the authored crown; the exact-size pass trues up the
	# small residual from clump overhang / the radial growth fence.
	out["width"] = crown_w
	return out


## Internal-settings adapter: injects the archetype/macro-derived values into
## the builder's legacy key namespace. These keys are DERIVED — they are not
## style keys, never persisted, and exist only inside this duplicated dict.
static func _deciduous_adapter_settings(spec: Dictionary, settings: Dictionary) -> Dictionary:
	var s := settings.duplicate()
	s["deciduous_branch_count"] = float(spec.get("sc_primaries", 6))
	s["deciduous_branch_tilt_low"] = float(spec.get("sc_tilt_low", 68.0))
	s["deciduous_branch_tilt_high"] = float(spec.get("sc_tilt_high", 24.0))
	s["deciduous_branch_lateral"] = float(spec.get("sc_lateral", 0.5))
	s["deciduous_branch_gnarl"] = float(spec.get("sc_gnarl", 0.25))
	s["deciduous_branch_droop"] = float(spec.get("sc_droop", 0.12))
	# pull → the legacy spread-angle scale (remap inverse of the builder's).
	s["deciduous_branch_angle"] = remap(clampf(float(spec.get("sc_pull", 0.55)),
		0.30, 0.88), 0.30, 0.88, 8.0, 75.0)
	# node budget → the legacy detail scale (budget = 110 + 58·detail).
	s["deciduous_branch_levels"] = clampf(
		(float(spec.get("sc_node_budget", 235)) - 110.0) / 58.0, 1.0, 5.0)
	s["deciduous_skeleton_seed"] = float(spec.get("sc_seed", 0))
	# crown_base in the legacy frame = fraction of the trunk spine height.
	var spine_top := maxf(float(spec.get("trunk_h", 5.0)), 0.01)
	s["deciduous_crown_base"] = clampf(
		float(spec.get("height_m", 14.0)) * float(spec.get("crown_base", 0.25)) / spine_top,
		0.05, 0.92)
	s["deciduous_trunk_taper"] = _derived_or_user(settings, "deciduous_trunk_taper",
		float(spec.get("sc_taper", 0.55)))
	# Raw archetype envelope params, consumed directly by the SC growth.
	for sck in ["sc_attractors", "sc_env_bottom", "sc_env_mid"]:
		if spec.has(sck):
			s[sck] = spec[sck]
	s["deciduous_branch_reach"] = 1.0
	s["deciduous_clump_spread"] = 1.0
	s["deciduous_cluster_size"] = float(spec.get("cluster_size_mul", 1.0))
	s["deciduous_leaf_density"] = float(spec.get("leaf_density", 15.0))
	s["deciduous_leaf_gap"] = float(spec.get("leaf_gap", 0.08))
	s["deciduous_leaf_shell_count"] = clampf(
		float(settings.get("deciduous_leaf_shell_count", 4.0))
		+ float(spec.get("shell_delta", 0)), 2.0, 10.0)
	return s


static func _pine_spec(settings: Dictionary, species: String = "pine") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["pine"]).duplicate(true)
	var out := {
		"top": base.get("top", Color(0.05, 0.14, 0.06)),
		"bottom": base.get("bottom", Color(0.07, 0.10, 0.04)),
		"highlight": base.get("highlight", Color(0.12, 0.24, 0.08)),
		"bark": base.get("bark", Color(0.16, 0.11, 0.06)),
	}
	var height := clampf(float(settings.get("pine_height_m",
		base.get("height_m", 17.0))), 1.5, 90.0)
	var crown_w := clampf(float(settings.get("pine_crown_width_m",
		base.get("crown_m", 7.0))), 0.8, 40.0)
	var trunk_cm := clampf(float(settings.get("pine_trunk_diameter_cm",
		base.get("trunk_cm", 45.0))), 4.0, 400.0)
	out["height_m"] = height
	out["crown_m"] = crown_w
	out["trunk_r"] = trunk_cm / 200.0
	# Legacy fields the whorl builder consumes: card_w ≈ bottom bough full
	# width, card_h ≈ tree height, trunk card sized so its ~44%-opaque band
	# reads as the authored diameter.
	out["width"] = crown_w
	out["height"] = height
	out["trunk_w"] = out["trunk_r"] * 2.0 / 0.44
	# Whorl count/spacing derive from branchiness unless explicitly set.
	var b := clampf(float(settings.get("pine_branchiness", 0.5)), 0.0, 1.0)
	out["whorl_count"] = _derived_or_user(settings, "pine_whorl_count",
		round(lerpf(5.0, 12.0, b)))
	out["bough_scale"] = _derived_or_user(settings, "pine_bough_scale", 1.0)
	return out


static func _shrub_spec(settings: Dictionary, species: String = "shrub") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["shrub"]).duplicate(true)
	base["width"] = float(settings.get("shrub_card_w", base["width"]))
	base["height"] = float(settings.get("shrub_card_h", base["height"]))
	return base


static func _grass_lawn_spec(settings: Dictionary, species: String = "grass_lawn") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["grass_lawn"]).duplicate(true)
	base["width"] = float(settings.get("grass_lawn_card_w", base["width"]))
	base["height"] = float(settings.get("grass_lawn_card_h", base["height"]))
	return base


static func _grass_field_spec(settings: Dictionary, species: String = "grass_field") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["grass_field"]).duplicate(true)
	base["width"] = float(settings.get("grass_field_card_w", base["width"]))
	base["height"] = float(settings.get("grass_field_card_h", base["height"]))
	return base


## Uniformly rescale every surface so the built tree's height is EXACTLY
## height_m and its widest XZ extent lands on crown_m. Real-world sliders mean
## what they say — SC growth drift, clump overhang and legacy internal ratios
## all wash out here. XZ correction is bounded so the trunk diameter can't be
## visibly distorted by an unusual crown.
static func _normalize_tree_surfaces(vert_arrays: Array, height_m: float,
		crown_m: float) -> void:
	var max_y := 0.001
	var max_r2 := 0.000001
	for arr in vert_arrays:
		var verts: PackedVector3Array = arr
		for v in verts:
			max_y = maxf(max_y, v.y)
			max_r2 = maxf(max_r2, v.x * v.x + v.z * v.z)
	var sy := height_m / max_y
	# Clusters pre-fit their centres to the authored crown, so this correction
	# is small; the tight clamp bounds trunk-diameter distortion to ~±15%.
	var sxz := clampf(crown_m / (2.0 * sqrt(max_r2)), 0.85, 1.18)
	if absf(sy - 1.0) < 0.002 and absf(sxz - 1.0) < 0.002:
		return
	for i in vert_arrays.size():
		var verts: PackedVector3Array = vert_arrays[i]
		for j in verts.size():
			var v := verts[j]
			verts[j] = Vector3(v.x * sxz, v.y * sy, v.z * sxz)
		vert_arrays[i] = verts


static func _build_deciduous_mesh(spec: Dictionary, settings_in: Dictionary) -> ArrayMesh:
	# All internal knobs come from the archetype/macro adapter — the raw style
	# dict no longer carries builder keys (Vegetation Overhaul v2).
	var settings := _deciduous_adapter_settings(spec, settings_in)
	var trunk_w := float(spec["trunk_w"])
	var trunk_h := float(spec["trunk_h"])
	var crown_w := float(spec["width"])
	var crown_h := float(spec["height"])

	var trunk_verts := PackedVector3Array()
	var trunk_uvs := PackedVector2Array()
	var trunk_normals := PackedVector3Array()
	var trunk_indices := PackedInt32Array()
	var is_near_lod := bool(settings.get("deciduous_leaf_shells_enabled", true))
	if is_near_lod:
		# NEAR: a real polygonal trunk. The old pair of crossed cards only existed
		# in two planes, so a limb emerging at any other azimuth visibly floated
		# beside the trunk instead of attaching to it — the "branches don't attach"
		# defect. A 7-sided tapered tube with a basal flare occupies the full
		# radius at every azimuth, and limb seeds start INSIDE it. Tube radius ==
		# spec.trunk_r (the authored trunk diameter, honest).
		_add_trunk_tube(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w * 0.28, trunk_h, _trunk_taper_top(settings, "deciduous"))
	else:
		# Bake-pending stand-in tier: two crossed cards, sized so the card's
		# ~44%-opaque texture band reads as the authored trunk diameter.
		for card_i in 2:
			var angle := float(card_i) * PI * 0.5
			_add_tapered_trunk_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
				float(spec.get("trunk_r", 0.28)) * 2.0 / 0.44, trunk_h, 0.0, angle,
				Vector3(0.0, 0.85, 0.0), _trunk_taper_top(settings, "deciduous"))

	# The skeleton decides where foliage goes at BOTH tiers. The stand-in tier
	# builds it with emit=false (tips only, no bark geometry) so its puffs land
	# on the same anchors the NEAR shells use — the impostor atlas is baked
	# from the NEAR mesh, so a disagreeing silhouette would pop at the LOD
	# boundary. (The old flat branch-card fan is GONE — it was the "weird thin
	# curving branches" the billboard tier showed at every distance.)
	var tips := _build_branch_skeleton(trunk_verts, trunk_uvs, trunk_normals,
		trunk_indices, trunk_w, trunk_h, crown_w, crown_h, settings, is_near_lod)
	var clusters := _clusters_from_tips(tips, crown_w, crown_h, trunk_h, settings)

	var height_m := float(spec.get("height_m", trunk_h + crown_h))
	var crown_m := float(spec.get("crown_m", crown_w))
	var mesh := ArrayMesh.new()

	if is_near_lod:
		var proxy_verts := PackedVector3Array()
		var proxy_uvs := PackedVector2Array()
		var proxy_normals := PackedVector3Array()
		var proxy_indices := PackedInt32Array()
		var use_proxy := bool(settings.get("deciduous_shadow_proxy_enabled", true))
		if use_proxy:
			var proxy_scale := float(settings.get("deciduous_shadow_proxy_scale", 1.06))
			for c in clusters:
				var pos: Vector3 = c["pos"]
				_add_cluster_cards(proxy_verts, proxy_uvs, proxy_normals, proxy_indices,
					pos, float(c["w"]) * proxy_scale, float(c["h"]) * proxy_scale,
					Vector3(0.0, 0.55, 0.0))
		var shell_arr := _build_leaf_shell_canopy(crown_w, crown_h, trunk_h, settings, clusters)
		# Exact-size pass over every surface TOGETHER (same factors everywhere).
		var shell_verts: PackedVector3Array = shell_arr[Mesh.ARRAY_VERTEX]
		var norm_arrays: Array = [trunk_verts, proxy_verts, shell_verts]
		_normalize_tree_surfaces(norm_arrays, height_m, crown_m)
		trunk_verts = norm_arrays[0]
		proxy_verts = norm_arrays[1]
		shell_arr[Mesh.ARRAY_VERTEX] = norm_arrays[2]
		var trunk_arr: Array = []
		trunk_arr.resize(Mesh.ARRAY_MAX)
		trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
		trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
		trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
		trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
		mesh.surface_set_material(0, bark_material_for_species("deciduous", settings))
		if use_proxy:
			var proxy_arr: Array = []
			proxy_arr.resize(Mesh.ARRAY_MAX)
			proxy_arr[Mesh.ARRAY_VERTEX] = proxy_verts
			proxy_arr[Mesh.ARRAY_TEX_UV] = proxy_uvs
			proxy_arr[Mesh.ARRAY_NORMAL] = proxy_normals
			proxy_arr[Mesh.ARRAY_INDEX] = proxy_indices
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, proxy_arr)
			mesh.surface_set_material(1, _deciduous_shadow_proxy_material(settings))
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shell_arr)
		var leaf_mat := leaf_canopy_material_for_species("deciduous", settings)
		leaf_mat.render_priority = 1
		mesh.surface_set_material(mesh.get_surface_count() - 1, leaf_mat)
		return mesh

	var canopy_verts := PackedVector3Array()
	var canopy_uvs := PackedVector2Array()
	var canopy_normals := PackedVector3Array()
	var canopy_indices := PackedInt32Array()
	for c in clusters:
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(canopy_verts, canopy_uvs, canopy_normals, canopy_indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.55, 0.0),
			0.0, 3, 0.0)
	var far_arrays: Array = [trunk_verts, canopy_verts]
	_normalize_tree_surfaces(far_arrays, height_m, crown_m)
	trunk_verts = far_arrays[0]
	canopy_verts = far_arrays[1]
	var trunk_arr_far: Array = []
	trunk_arr_far.resize(Mesh.ARRAY_MAX)
	trunk_arr_far[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr_far[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr_far[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr_far[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr_far)
	mesh.surface_set_material(0, bark_material_for_species("deciduous", settings))

	var canopy_arr: Array = []
	canopy_arr.resize(Mesh.ARRAY_MAX)
	canopy_arr[Mesh.ARRAY_VERTEX] = canopy_verts
	canopy_arr[Mesh.ARRAY_TEX_UV] = canopy_uvs
	canopy_arr[Mesh.ARRAY_NORMAL] = canopy_normals
	canopy_arr[Mesh.ARRAY_INDEX] = canopy_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, canopy_arr)
	mesh.surface_set_material(1, material_for_species("deciduous", settings))
	return mesh


## Nested lumpy ellipsoid shells wrapping the crown. Each vertex stores the
## crown-radial unit direction in NORMAL (reused for lighting + the fragment leaf
## grid), COLOR.r = shell depth (0 inner .. 1 outer), COLOR.g = normalized tree
## height (for wind). Stacked shells + per-shell leaf gaps read as a volumetric
## canopy of discrete leaves (see leaf_canopy.gdshader).
## `clusters` comes from the branch skeleton (_clusters_from_tips); empty falls
## back to the abstract ring layout.
static func _build_leaf_shell_canopy(crown_w: float, crown_h: float, trunk_h: float,
		settings: Dictionary, clusters_in: Array = []) -> Array:
	# NO shell-count floor. The old `maxi(..., 7)` silently promoted the LOW (3)
	# and MEDIUM (5) graphics tiers to 7 shells, so the headline deciduous
	# quality knob was inert below High while still costing shells × clusters ×
	# 64 tris. Foliage now sits on real branch tips, which breaks the volume up
	# on its own, so fewer shells still read as a dense canopy.
	var shells := clampi(int(round(float(settings.get("deciduous_leaf_shell_count", 5)))), 2, 10)
	var lump := clampf(float(settings.get("deciduous_leaf_lump", 0.18)), 0.0, 0.6)
	# 5×10 sphere: at 4×8 the clump silhouettes read as hex boxes once the
	# two-layer leaf grid made them solid (the default shell count dropped 5→4
	# to pay for the extra rounding).
	var rings := 5
	var segs := 10
	# How deep the shell stack reaches into the cluster. With MANY shells they can
	# start deep (0.42) and still overlap into a solid volume; with FEW they must
	# hug the surface or the outer shell's leaf gaps have nothing behind them and
	# the canopy reads as wireframe. This is what makes a low shell count a
	# cheaper tree rather than a broken one — it matters now that the quality
	# tiers actually reach the builder.
	var inner_frac := lerpf(0.74, 0.42, clampf((float(shells) - 2.0) / 8.0, 0.0, 1.0))
	var total_h := maxf(trunk_h + crown_h, 0.001)

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var row_stride := segs + 1

	var clusters := clusters_in
	if clusters.is_empty():
		clusters = _deciduous_cluster_layout(crown_w, crown_h, trunk_h, settings)

	for cluster in clusters:
		var center: Vector3 = cluster["pos"]
		# Bigger leaf ellipsoids so neighbouring clusters overlap into one continuous
		# canopy rather than isolated puffs with branch gaps between them.
		var rx = float(cluster["w"]) * 0.62
		var ry = float(cluster["h"]) * 0.55
		var rz = rx

		for s in shells:
			var st := float(s) / maxf(float(shells - 1), 1.0)
			var scale := lerpf(inner_frac, 1.0, st)
			var base := verts.size()
			for iy in rings + 1:
				var theta := PI * float(iy) / float(rings)
				var sin_t := sin(theta)
				var cos_t := cos(theta)
				for ix in segs + 1:
					var phi := TAU * float(ix) / float(segs)
					var dir := Vector3(sin_t * cos(phi), cos_t, sin_t * sin(phi))
					var bump := 1.0 + lump * (
						sin(dir.x * 5.1 + dir.y * 3.3 + center.x) * 0.5
						+ sin(dir.z * 4.7 - dir.y * 2.9 + center.z) * 0.5)
					var pos := Vector3(dir.x * rx, dir.y * ry, dir.z * rz) * scale * bump
					pos += center
					verts.append(pos)
					normals.append(dir)
					uvs.append(Vector2(phi / TAU, theta / PI))
					colors.append(Color(st, clampf(pos.y / total_h, 0.0, 1.0), 0.0, 1.0))
			for iy in rings:
				for ix in segs:
					var a := base + iy * row_stride + ix
					var b := a + 1
					var c := a + row_stride
					var d := c + 1
					indices.append_array([a, c, b, b, c, d])

	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	return arr


static func _deciduous_shadow_proxy_material(settings: Dictionary) -> ShaderMaterial:
	var s := settings.duplicate(true)
	s["deciduous_color_fade"] = float(settings.get("deciduous_shadow_proxy_visibility", 0.04))
	var mat := material_for_species("deciduous", s)
	mat.render_priority = 0
	return mat


static func leaf_canopy_material_for_species(species: String, settings: Dictionary = {}) -> ShaderMaterial:
	var spec: Dictionary
	match species:
		"deciduous":
			spec = _deciduous_spec(settings)
		_:
			spec = SPECS.get(species, SPECS["shrub"])
	var mat := ShaderMaterial.new()
	mat.shader = LEAF_CANOPY_SHADER
	_apply_leaf_canopy_uniforms(mat, species, spec, settings)
	_configure_cutout_shadow(mat, 0.35)
	return mat


static func _apply_leaf_canopy_uniforms(mat: ShaderMaterial, species: String,
		spec: Dictionary, settings: Dictionary) -> void:
	var top: Color = spec["top"]
	var family := mesh_family(species)
	var tint: Color = settings.get("%s_albedo_tint" % species,
		settings.get("%s_albedo_tint" % family, Color.WHITE))
	var hi: Color = settings.get("%s_highlight_tint" % species,
		settings.get("%s_highlight_tint" % family,
			spec.get("highlight", Color(0.42, 0.52, 0.16))))
	mat.set_shader_parameter("canopy_profile", 0)
	mat.set_shader_parameter("leaf_color", Vector3(top.r, top.g, top.b))
	mat.set_shader_parameter("leaf_shadow", Vector3(top.r * 0.32, top.g * 0.34, top.b * 0.30))
	mat.set_shader_parameter("albedo_tint", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("highlight_tint", Vector3(hi.r, hi.g, hi.b))
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.03)))
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.7)))
	mat.set_shader_parameter("wind_profile", 1.0)
	# No hidden clamps here. leaf_size used to be floored at 0.92 and shell_gap
	# capped at 0.12 (a guard against legacy maps that froze a sparse leaf grid),
	# which silently killed most of both sliders' travel — the VegStyleStore v2
	# migration already purged those legacy defaults-dumps, so the sliders own
	# their full range again (defaults sit at the previously-clamped look).
	mat.set_shader_parameter("cells_per_side", float(settings.get("deciduous_leaf_density", 22.0)))
	mat.set_shader_parameter("leaf_size", float(settings.get("deciduous_leaf_size", 0.95)))
	mat.set_shader_parameter("leaf_aspect", float(settings.get("deciduous_leaf_aspect", 1.9)))
	mat.set_shader_parameter("shell_gap", float(settings.get("deciduous_leaf_gap", 0.08)))
	mat.set_shader_parameter("dither_strength", float(settings.get("dither_strength", 1.0)))
	mat.set_shader_parameter("alpha_dither_min", float(settings.get("alpha_dither_min", 0.20)))
	mat.set_shader_parameter("alpha_dither_max", float(settings.get("alpha_dither_max", 0.50)))
	mat.set_shader_parameter("near_crisp_m", float(settings.get("near_crisp_m", 40.0)))
	mat.set_shader_parameter("far_dither_m", float(settings.get("far_dither_m", 120.0)))
	mat.set_shader_parameter("haze_strength", float(settings.get("haze_strength", 0.65)))
	mat.set_shader_parameter("subsurface_strength", float(settings.get("subsurface_strength", 0.15)))
	mat.set_shader_parameter("translucency_strength", float(settings.get("translucency_strength", 0.25)))
	mat.set_shader_parameter("color_variation", float(settings.get("color_variation", 0.12)))
	mat.set_shader_parameter("roughness_value", float(settings.get("foliage_roughness", 0.95)))
	mat.set_shader_parameter("ao_strength", float(settings.get("ao_strength", 0.40)))
	mat.set_shader_parameter("hue_jitter", float(settings.get("hue_jitter", 0.0)))
	
	mat.set_shader_parameter("spring_bud", float(settings.get("spring_bud", 0.0)))
	mat.set_shader_parameter("autumn", float(settings.get("autumn", 0.0)))
	if settings.has("bud_color"):
		var c: Color = settings["bud_color"]
		mat.set_shader_parameter("bud_color", Vector3(c.r, c.g, c.b))
	if settings.has("autumn_warm"):
		var c: Color = settings["autumn_warm"]
		mat.set_shader_parameter("autumn_warm", Vector3(c.r, c.g, c.b))
	if settings.has("autumn_orange"):
		var c: Color = settings["autumn_orange"]
		mat.set_shader_parameter("autumn_orange", Vector3(c.r, c.g, c.b))
	if settings.has("autumn_hot"):
		var c: Color = settings["autumn_hot"]
		mat.set_shader_parameter("autumn_hot", Vector3(c.r, c.g, c.b))
	
	if settings.has("ao_tint"):
		var aoc: Color = settings["ao_tint"]
		mat.set_shader_parameter("ao_tint", Vector3(aoc.r, aoc.g, aoc.b))
	if settings.has("haze_color"):
		var hc: Color = settings["haze_color"]
		mat.set_shader_parameter("haze_color", Vector3(hc.r, hc.g, hc.b))
	
	if settings.has("bud_color"):
		var bc: Color = settings["bud_color"]
		mat.set_shader_parameter("bud_color", Vector3(bc.r, bc.g, bc.b))
	if settings.has("autumn_warm"):
		var ac: Color = settings["autumn_warm"]
		mat.set_shader_parameter("autumn_warm", Vector3(ac.r, ac.g, ac.b))
	if settings.has("autumn_orange"):
		var ac: Color = settings["autumn_orange"]
		mat.set_shader_parameter("autumn_orange", Vector3(ac.r, ac.g, ac.b))
	if settings.has("autumn_hot"):
		var ac: Color = settings["autumn_hot"]
		mat.set_shader_parameter("autumn_hot", Vector3(ac.r, ac.g, ac.b))


static func trunk_mesh_for_forest(settings: Dictionary = {}) -> ArrayMesh:
	var spec := _deciduous_spec(settings)
	var trunk_w := float(spec["trunk_w"])
	var trunk_h := float(spec["trunk_h"]) * 0.85
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5
		_add_card(verts, uvs, normals, indices,
			trunk_w, trunk_h, 0.0, angle, Vector3(0.0, 0.85, 0.0))
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, bark_material_for_species("deciduous", settings))
	return mesh


static func _trunk_taper_top(settings: Dictionary, species: String) -> float:
	var key := "%s_trunk_taper" % species
	var default := 0.42 if species == "deciduous" else 0.38
	return clampf(float(settings.get(key, default)), 0.12, 1.0)


static func _add_tapered_trunk_card(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		card_w_base: float, card_h: float, y_base: float, angle: float, normal_lift: Vector3,
		taper_top: float, xz_offset: Vector3 = Vector3.ZERO, card_w_top: float = -1.0) -> void:
	var w_top := card_w_top if card_w_top > 0.0 else card_w_base * taper_top
	var dx_b := cos(angle) * card_w_base * 0.5
	var dz_b := sin(angle) * card_w_base * 0.5
	var dx_t := cos(angle) * w_top * 0.5
	var dz_t := sin(angle) * w_top * 0.5
	var base := verts.size()
	verts.append_array([
		Vector3(-dx_b, y_base, -dz_b) + xz_offset,
		Vector3(dx_b, y_base, dz_b) + xz_offset,
		Vector3(dx_t, y_base + card_h, dz_t) + xz_offset,
		Vector3(-dx_t, y_base + card_h, -dz_t) + xz_offset,
	])
	uvs.append_array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var card_dir := Vector3(dx_b, 0.0, dz_b).normalized()
	var face_perp := Vector3(-card_dir.z, 0.0, card_dir.x)
	var face_normal := (face_perp + normal_lift).normalized()
	for _j in 4:
		normals.append(face_normal)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _add_branch_card(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		base: Vector3, tip: Vector3, width: float) -> void:
	var dir := tip - base
	if dir.length_squared() < 1e-6:
		return
	dir = dir.normalized()
	var side := dir.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = dir.cross(Vector3.FORWARD)
	side = side.normalized() * width * 0.5
	var idx := verts.size()
	verts.append_array([
		base - side, base + side, tip + side * 0.55, tip - side * 0.55,
	])
	uvs.append_array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var face_normal := side.cross(dir).normalized()
	for _j in 4:
		normals.append(face_normal)
	indices.append_array([idx, idx + 1, idx + 2, idx, idx + 2, idx + 3])


static func _add_card(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		card_w: float, card_h: float, y_base: float, angle: float, normal_lift: Vector3,
		xz_offset: Vector3 = Vector3.ZERO) -> void:
	var dx := cos(angle) * card_w * 0.5
	var dz := sin(angle) * card_w * 0.5
	var base := verts.size()
	verts.append_array([
		Vector3(-dx, y_base, -dz) + xz_offset, Vector3(dx, y_base, dz) + xz_offset,
		Vector3(dx, y_base + card_h, dz) + xz_offset, Vector3(-dx, y_base + card_h, -dz) + xz_offset,
	])
	uvs.append_array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var card_dir := Vector3(dx, 0.0, dz).normalized()
	var face_perp := Vector3(-card_dir.z, 0.0, card_dir.x)
	var face_normal := (face_perp + normal_lift).normalized()
	for _j in 4:
		normals.append(face_normal)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


## Three crossed quads at a cluster anchor — circular alpha reads as a foliage puff.
static func _add_cluster_cards(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		center: Vector3, card_w: float, card_h: float, normal_lift: Vector3,
		base_yaw: float = 0.0, card_count: int = 3, y_offset: float = 0.0) -> void:
	var y_base := center.y - card_h * 0.20 + y_offset
	var n := clampi(card_count, 2, 4)
	for card_i in n:
		_add_card(verts, uvs, normals, indices, card_w, card_h, y_base,
			float(card_i) * TAU / float(n) + base_yaw, normal_lift,
			Vector3(center.x, 0.0, center.z))


## Deterministic seed for the branch skeleton, so identical settings always
## build the identical tree (the mesh is shared across every MultiMesh instance).
const _BRANCH_SEED := 0x2f9a37

## Space-colonization branch skeleton for deciduous trees (Runions et al. 2007,
## "Modeling Trees with a Space Colonization Algorithm"). A deterministic cloud
## of attraction points fills the crown envelope; limbs seeded at
## deciduous_primary_placements grow step by step toward whatever attractors
## they are nearest to, forking naturally where the attractor field diverges and
## stopping where space is used up. Compared with the old blind fractal fork
## recursion this gives crowns that fill their own envelope (no interpenetrating
## limbs racing off in fixed cones), natural asymmetry, and a believable bare
## structure in winter when the leaf shells drop out.
##
## Determinism: seeded RNG + array-ordered iteration, so identical settings
## always build the identical tree (the mesh is shared across every MultiMesh
## instance and the impostor bake key hashes it).
## Cost is bounded by an explicit node budget (`deciduous_branch_levels` scales
## it, ~140..320 nodes) regardless of attractor count.
## `emit` false collects TIPS ONLY (no bark geometry) — the FAR tier needs the
## same anchor points so its cards share the NEAR silhouette, without paying for
## a skeleton it never draws.
static func _build_branch_skeleton(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		trunk_w: float, trunk_h: float, crown_w: float, crown_h: float,
		settings: Dictionary, emit: bool = true) -> Array:
	var detail := clampf(float(settings.get("deciduous_branch_levels", 3.0)), 1.0, 5.0)
	var primaries := clampi(int(round(float(settings.get("deciduous_branch_count", 5)))), 2, 12)
	var max_children := clampi(int(round(float(settings.get("deciduous_branch_split", 3)))), 2, 4)
	var thick := clampf(float(settings.get("deciduous_branch_thickness", 1.0)), 0.05, 2.5)
	var reach := clampf(float(settings.get("deciduous_branch_reach", 1.0)), 0.4, 1.6)
	# Spread angle → how hard a growing limb turns toward the attractor field.
	# Low = straight poplar-like limbs that keep their heading; high = crooked
	# oak-like limbs that chase every pocket of open space.
	var fork_deg := clampf(float(settings.get("deciduous_branch_angle", 38.0)), 8.0, 75.0)
	var pull := remap(fork_deg, 8.0, 75.0, 0.30, 0.88)
	var len_ratio := clampf(float(settings.get("deciduous_branch_length_ratio", 0.72)), 0.45, 0.92)
	var droop := clampf(float(settings.get("deciduous_branch_droop", 0.12)), -0.6, 0.6)
	var gnarl := clampf(float(settings.get("deciduous_branch_gnarl", 0.22)), 0.0, 1.0)
	var lateral := clampf(float(settings.get("deciduous_branch_lateral", 0.45)), 0.0, 1.0)
	var crown_base := clampf(float(settings.get("deciduous_crown_base", 0.42)), 0.05, 0.92)
	var tilt_low := clampf(float(settings.get("deciduous_branch_tilt_low", 75.0)), 15.0, 89.0)
	var rng := RandomNumberGenerator.new()
	# Variant knob: same species + dims, a different skeleton. Deterministic —
	# variant N always grows the same tree.
	rng.seed = _BRANCH_SEED + 7919 * clampi(
		int(round(float(settings.get("deciduous_skeleton_seed", 0)))), 0, 9)

	# Crown envelope the attractors fill.
	var y0 := trunk_h * crown_base
	var y1 := trunk_h + crown_h
	var env_h := maxf(y1 - y0, 0.5)
	# Envelope sits INSIDE the authored crown: growth may overshoot to the
	# radial fence (×1.05 below), which must still land under crown_w/2 or the
	# exact-size XZ pass squeezes the whole tree (0.92 × 1.05 ≈ 0.97).
	var env_r := maxf(crown_w * 0.5 * 0.92 * reach, 0.5)
	# Step ≪ crown radius or the kill radius (1.45×step) wipes whole crown
	# regions before growth ever visits them — the first cut of this generator
	# used step ≈ 0.25×crown height and the tree filled barely half its envelope.
	var env_span := maxf(env_h, env_r * 2.0)
	var step := clampf(env_span * lerpf(0.16, 0.075, (detail - 1.0) / 4.0), 0.18, 2.2)
	var node_budget := int(110.0 + detail * 58.0)

	# Envelope profile straight from the archetype table when present (the v3
	# adapter injects sc_* keys); tilt-derived fallback keeps old callers alive.
	var attr_count := clampi(int(settings.get("sc_attractors",
		30.0 + float(primaries) * 16.0 + lateral * 30.0)), 40, 420)
	var env_bottom := clampf(float(settings.get("sc_env_bottom",
		remap(tilt_low, 15.0, 89.0, 0.15, 0.85))), 0.05, 1.0)
	var env_mid := clampf(float(settings.get("sc_env_mid",
		lerpf(0.52, 0.36, lateral))), 0.05, 0.95)
	var attractors := _sc_attractors(env_r, y0, env_h, attr_count, env_bottom,
		env_mid, lateral, rng)

	# Node soup (parallel arrays; children always index AFTER their parent, which
	# the pipe-model radius pass depends on). parent -1 = seed anchored in the
	# trunk (no segment of its own — the trunk tube is its parent geometry).
	var n_pos := PackedVector3Array()
	var n_dir := PackedVector3Array()
	var n_parent := PackedInt32Array()
	var n_children := PackedInt32Array()
	var n_depth := PackedInt32Array()
	for place in deciduous_primary_placements(trunk_w, trunk_h, settings, rng):
		var pl: Dictionary = place
		# Seed INSIDE the trunk (45% of the surface radius) so the first limb
		# segment emerges through the tube wall instead of floating beside it.
		var o: Vector3 = pl["origin"]
		var seed_pos := Vector3(o.x * 0.45, o.y, o.z * 0.45)
		n_pos.append(seed_pos)
		n_dir.append(pl["dir"])
		n_parent.append(-1)
		n_children.append(0)
		n_depth.append(0)
	# Apex leader seed: continues the trunk so the crown has a top (without it
	# the foliage stack closes over a hollow — the "heart notch" on every
	# mid-distance broadleaf).
	n_pos.append(Vector3(0.0, trunk_h * PRIMARY_BAND_TOP, 0.0))
	n_dir.append(Vector3.UP)
	n_parent.append(-1)
	n_children.append(0)
	n_depth.append(0)

	# --- growth loop -----------------------------------------------------------
	# Bounded attraction radius (a few steps) so growth expands OUTWARD through
	# the cloud instead of every attractor yanking the seeds toward the global
	# centroid on iteration one; saturated nodes (at the fork cap) are skipped in
	# the nearest search or their attractors starve forever and the loop stalls.
	var d_attract := step * 5.0
	# 1.05×step: barely above the step so each new node consumes only its own
	# neighbourhood — denser twigging for the same envelope (at 1.45 the whole
	# cloud died to ~50 nodes and winter trees had a dozen bare tips). Still
	# ≥ step so growth can never oscillate without consuming space.
	var d_kill := step * 1.05
	var floor_y := y0 * 0.72
	for _iter in 90:
		if attractors.is_empty() or n_pos.size() >= node_budget:
			break
		# Each attractor pulls its nearest growable node (within reach).
		var accum := PackedVector3Array()
		accum.resize(n_pos.size())
		var counts := PackedInt32Array()
		counts.resize(n_pos.size())
		for a in attractors:
			var best := -1
			var best_d := d_attract
			for i in n_pos.size():
				if n_children[i] >= max_children:
					continue
				var d := (a as Vector3).distance_to(n_pos[i])
				if d < best_d:
					best_d = d
					best = i
			if best >= 0:
				accum[best] = accum[best] + ((a as Vector3) - n_pos[best]).normalized()
				counts[best] = counts[best] + 1
		var grew := false
		var first_new := n_pos.size()
		for i in first_new:
			if counts[i] == 0 or n_children[i] >= max_children:
				continue
			if n_pos.size() >= node_budget:
				break
			var attract_dir := accum[i].normalized()
			var jitter := Vector3(rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0,
				rng.randf() * 2.0 - 1.0) * gnarl * 0.5
			var dir := (attract_dir * pull + n_dir[i] * (1.0 - pull)
				+ Vector3.UP * droop * 0.30 + jitter).normalized()
			# Twigs shorten with depth (len_ratio): the crown edge breaks into
			# finer structure than the limb bases.
			var seg := step * (1.0 - (1.0 - len_ratio) * 0.55 * minf(float(n_depth[i]), 4.0) / 4.0)
			var np := n_pos[i] + dir * seg
			np.y = maxf(np.y, floor_y)
			# Hard envelope ceiling + radial fence. Momentum (1-pull) lets a
			# shoot ratchet PAST the last attractors it consumed — a low
			# spread-angle style measured a skeleton 4.4 m taller than its
			# authored trunk+crown, so "12 m tall" quietly meant 15. Authored
			# dims are a contract; growth may overshoot ~6%, no more.
			np.y = minf(np.y, y1 + env_h * 0.06)
			var rad := Vector2(np.x, np.z)
			var rad_max := env_r * 1.05
			if rad.length_squared() > rad_max * rad_max:
				rad = rad.normalized() * rad_max
				np.x = rad.x
				np.z = rad.y
			n_pos.append(np)
			n_dir.append(dir)
			n_parent.append(i)
			n_children.append(0)
			n_depth.append(n_depth[i] + 1)
			n_children[i] = n_children[i] + 1
			grew = true
		if not grew:
			break
		# Consume the space the new growth reached.
		var kept: Array = []
		for a in attractors:
			var dead := false
			for i in range(first_new, n_pos.size()):
				if (a as Vector3).distance_to(n_pos[i]) < d_kill:
					dead = true
					break
			if not dead:
				kept.append(a)
		attractors = kept

	if OS.get_environment("VEG_SC_DEBUG") == "1":
		var dbg_max := 0.0
		for i in n_pos.size():
			dbg_max = maxf(dbg_max, n_pos[i].y)
		print("SC_DEBUG y1=%.2f ceil=%.2f max_node_y=%.2f nodes=%d" % [
			y1, y1 + env_h * 0.06, dbg_max, n_pos.size()])

	# --- chain smoothing -------------------------------------------------------
	# Per-step jitter + discrete attractor pulls leave visible KINKS along limb
	# runs. Two Laplacian passes over pure chain links (exactly one child) round
	# them into natural curves; forks, seeds and TIPS stay pinned, so topology,
	# foliage anchors and the envelope clamps are untouched.
	for _pass in 2:
		var smoothed := n_pos.duplicate()
		for i in n_pos.size():
			if n_children[i] != 1 or n_parent[i] < 0:
				continue
			var child := -1
			for j in range(i + 1, n_pos.size()):
				if n_parent[j] == i:
					child = j
					break
			if child < 0:
				continue
			smoothed[i] = n_pos[i] * 0.5 + (n_pos[n_parent[i]] + n_pos[child]) * 0.25
		n_pos = smoothed

	# --- pipe-model radii (da Vinci: r_parent^n = Σ r_child^n) -----------------
	var tipw := PackedFloat32Array()
	tipw.resize(n_pos.size())
	var tips: Array = []
	for i in range(n_pos.size() - 1, -1, -1):
		if n_children[i] == 0:
			tipw[i] += 1.0
			if n_depth[i] >= 1:
				tips.append(n_pos[i])
		if n_parent[i] >= 0:
			tipw[n_parent[i]] += tipw[i]
	tips.reverse()  # creation order, so downstream stride-sampling spans the crown
	if not emit:
		return tips
	# Thickness slider shapes the taper exponent (chunky limbs vs wispy twigs)
	# and the tip radius; the root radius is capped to sit inside the trunk top.
	var n_exp := lerpf(2.9, 1.9, clampf(thick / 2.5, 0.0, 1.0))
	# Slimmer than before the band-UV fix: quads now render their FULL
	# geometric width (they used to show only the texture's opaque 44%).
	var r_tip := 0.014 + 0.016 * thick
	var radii := PackedFloat32Array()
	radii.resize(n_pos.size())
	var max_r := 0.001
	for i in n_pos.size():
		radii[i] = r_tip * pow(maxf(tipw[i], 1.0), 1.0 / n_exp)
		max_r = maxf(max_r, radii[i])
	# Limb radii cap just under the trunk tube's top radius (tube r = 0.28×w).
	var cap_r := maxf(trunk_w * 0.20, 0.03)
	if max_r > cap_r:
		var fix := cap_r / max_r
		for i in n_pos.size():
			radii[i] = radii[i] * fix
	for i in n_pos.size():
		var p := n_parent[i]
		if p < 0:
			continue
		var r0 := radii[p]
		var r1 := radii[i]
		if maxf(r0, r1) >= 0.055:
			_add_branch_tube(verts, uvs, normals, indices, n_pos[p], n_pos[i], r0, r1)
		else:
			_add_branch_segment(verts, uvs, normals, indices, n_pos[p], n_pos[i],
				r0 * 2.0, r1 * 2.0)
	return tips


## Deterministic attractor cloud for the space-colonization growth. The envelope
## is a crown-shaped solid of revolution: radius peaks at env_mid, narrows to a
## rounded top, and its base fullness (bottom_frac) follows the species
## archetype — a spreading chestnut keeps width right down to the crown base, a
## columnar birch pinches in. `lateral` skews the vertical density toward the
## lower crown (the spreading skirt). Points bias toward the rim (pow 0.38)
## because foliage — and therefore branch structure — concentrates on the shell.
static func _sc_attractors(env_r: float, y0: float, env_h: float,
		count: int, bottom_frac: float, t_mid: float, lateral: float,
		rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for _i in count:
		var t := pow(rng.randf(), lerpf(0.85, 1.55, lateral))
		var rr: float
		if t < t_mid:
			rr = lerpf(bottom_frac, 1.0, smoothstep(0.0, 1.0, t / maxf(t_mid, 0.01)))
		else:
			rr = lerpf(1.0, 0.20, smoothstep(0.0, 1.0, (t - t_mid) / maxf(1.0 - t_mid, 0.01)))
		var radius := env_r * rr * pow(rng.randf(), 0.38)
		var az := rng.randf() * TAU
		out.append(Vector3(cos(az) * radius, y0 + t * env_h, sin(az) * radius))
	return out


## Highest primary attachment as a fraction of trunk height (the apex leader
## starts here too).
const PRIMARY_BAND_TOP := 0.95


## Where each primary limb leaves the trunk, as pure data: [{t, origin, dir,
## height, azimuth}]. Split out of _build_fractal_branches so the distribution
## invariants (attachment spread, azimuth separation, emergence off the trunk
## SURFACE) can be asserted offline without a test re-deriving the math — which
## would pass happily against a broken generator.
##
## Pass an rng to share the generator's stream; omit it for a standalone sample.
static func deciduous_primary_placements(trunk_w: float, trunk_h: float,
		settings: Dictionary, rng: RandomNumberGenerator = null) -> Array:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.seed = _BRANCH_SEED
	var primaries := clampi(int(round(float(settings.get("deciduous_branch_count", 5)))), 2, 12)
	# NOT inherited from the legacy `deciduous_branch_base`. That key's saved
	# values (Mt Vernon has 0.62 on a 6 m trunk) were tuned when it meant "the
	# bottom of a narrow band containing EVERY limb" — reusing them here
	# reproduces the exact lollipop this rebuild exists to fix, on every map that
	# already has a tuned style. The key still exists and still feeds the FAR
	# card attach height; it just no longer decides where the crown starts.
	var crown_base := clampf(float(settings.get("deciduous_crown_base", 0.42)), 0.05, 0.92)
	# 75 deg is nearly horizontal. The lowest limbs of a broadleaf reach OUT, not
	# up; at 58-62 deg every limb still climbed, so even a low attachment put its
	# foliage high and the crown floated above a bare pole.
	var tilt_low := clampf(float(settings.get("deciduous_branch_tilt_low", 75.0)), 15.0, 89.0)
	var tilt_high := clampf(float(settings.get("deciduous_branch_tilt_high", 26.0)), 5.0, 80.0)
	var taper := _trunk_taper_top(settings, "deciduous")
	var spacing := (PRIMARY_BAND_TOP - crown_base) / maxf(float(primaries - 1), 1.0)
	# Golden-angle spacing keeps azimuths even; the jitter must stay well INSIDE
	# the resulting gap or pairs of primaries land on top of each other (the old
	# jitter was 0..34° one-sided against a 21.8° gap, and never subtracted).
	var az_jitter := (TAU / float(primaries)) * 0.35
	var out: Array = []
	for i in primaries:
		var t := float(i) / maxf(float(primaries - 1), 1.0)
		# Bases spread over the whole crown-bearing trunk, with a jitter of about
		# half the spacing so the march never reads as a regular ladder.
		var band := lerpf(crown_base, PRIMARY_BAND_TOP, t) \
			+ (rng.randf() * 2.0 - 1.0) * spacing * 0.45
		var by := trunk_h * clampf(band, 0.04, 1.0)
		var az := float(i) * TAU * 0.618034 + (rng.randf() * 2.0 - 1.0) * az_jitter
		# Low limbs splay out, high limbs reach up — the classic broadleaf spread.
		var out_tilt := deg_to_rad(lerpf(tilt_low, tilt_high, t))
		var dir := Vector3(cos(az) * sin(out_tilt), cos(out_tilt),
			sin(az) * sin(out_tilt)).normalized()
		# Emerge from the trunk SURFACE, not its centre line: with a 1.31 m trunk
		# the first ~0.65 m of every limb used to be buried inside the trunk card,
		# concentrating the visible emergence points even further.
		var radius := trunk_w * 0.5 * lerpf(1.0, taper,
			clampf(by / maxf(trunk_h, 0.01), 0.0, 1.0))
		out.append({
			"t": t, "height": by, "azimuth": fposmod(az, TAU), "radius": radius,
			"origin": Vector3(cos(az) * radius, by, sin(az) * radius), "dir": dir,
		})
	return out


## Tapered polygonal trunk tube with a basal root flare. Radial smooth normals
## make 7 sides read as round; slight per-vertex radius noise breaks the
## perfect-cylinder look. UVs: U wraps the circumference once, V runs 1 (base)
## → 0 (top) to match the bark texture orientation the cards used.
static func _add_trunk_tube(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		r_base: float, trunk_h: float, taper_top: float) -> void:
	var sides := 7
	var ring_ts: Array[float] = [0.0, 0.08, 0.25, 0.55, 1.0]
	var ring_start := verts.size()
	for t in ring_ts:
		var flare := 1.0 + 0.22 * pow(clampf(1.0 - t / 0.12, 0.0, 1.0), 1.7)
		var r := lerpf(r_base, r_base * taper_top, t) * flare
		var y := trunk_h * t
		for i in sides + 1:
			var az := TAU * float(i) / float(sides)
			# Deterministic bark irregularity (no RNG: same vertex → same bump).
			var bump := 1.0 + 0.05 * sin(az * 3.0 + t * 7.0) * (1.0 - t * 0.5)
			var dir := Vector3(cos(az), 0.0, sin(az))
			verts.append(dir * r * bump + Vector3(0.0, y, 0.0))
			# Up-tilted normals like the cards used (their lift was 0.85): pure
			# radial normals leave the camera-side face in its own shadow all
			# day and the trunk reads as a black silhouette.
			normals.append((dir + Vector3.UP * 0.55).normalized())
			# The bark texture is authored for a CARD: opaque only in the centre
			# band (|u-0.5| < ~0.11), transparent silhouette margins outside it.
			# Ping-pong U inside the opaque band so the wrap is seamless and the
			# tube never samples the transparent edges (which read as a black
			# cutout slab on the first tube attempt).
			verts_uv_pingpong(uvs, az, 1.0 - t)
	var stride := sides + 1
	for ring_i in ring_ts.size() - 1:
		for i in sides:
			var a := ring_start + ring_i * stride + i
			var b := a + 1
			var c := a + stride
			var d := c + 1
			indices.append_array([a, c, b, b, c, d])


## Bark-band UV for tube geometry: U oscillates inside the texture's opaque
## centre band instead of wrapping 0..1 (the margins are transparent card
## silhouette).
static func verts_uv_pingpong(uvs: PackedVector2Array, az: float, v: float) -> void:
	uvs.append(Vector2(0.5 + 0.10 * sin(az), v))


## Tapered 6-sided tube for one thick limb segment, with smooth radial normals.
## Only segments above the radius threshold pay for this; thin twigs stay on
## the crossed-quad path (_add_branch_segment).
static func _add_branch_tube(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, r0: float, r1: float) -> void:
	var axis := b - a
	if axis.length_squared() < 1e-8:
		return
	axis = axis.normalized()
	var side := axis.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = axis.cross(Vector3.RIGHT)
	side = side.normalized()
	var side2 := axis.cross(side).normalized()
	var sides := 6
	var base := verts.size()
	for e in 2:
		var center := a if e == 0 else b
		var r := r0 if e == 0 else r1
		# Overshoot the joint slightly so consecutive segments interpenetrate
		# instead of leaving a sliver gap at each elbow.
		center += axis * (-r0 * 0.35 if e == 0 else r1 * 0.35)
		for i in sides + 1:
			var az := TAU * float(i) / float(sides)
			var dir := side * cos(az) + side2 * sin(az)
			verts.append(center + dir * r)
			normals.append(dir)
			verts_uv_pingpong(uvs, az, 1.0 - float(e))
	var stride := sides + 1
	for i in sides:
		var v0 := base + i
		var v1 := v0 + 1
		var v2 := v0 + stride
		var v3 := v2 + 1
		indices.append_array([v0, v2, v1, v1, v2, v3])


## A limb segment as two perpendicular tapered quads (a cheap "tube") so a bough
## reads as solid bark from any view angle, not a flat card.
static func _add_branch_segment(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, w0: float, w1: float) -> void:
	var dir := b - a
	if dir.length_squared() < 1e-8:
		return
	dir = dir.normalized()
	var side1 := dir.cross(Vector3.UP)
	if side1.length_squared() < 1e-6:
		side1 = dir.cross(Vector3.RIGHT)
	side1 = side1.normalized()
	var side2 := dir.cross(side1).normalized()
	_add_branch_quad(verts, uvs, normals, indices, a, b, w0, w1, side1)
	_add_branch_quad(verts, uvs, normals, indices, a, b, w0, w1, side2)


static func _add_branch_quad(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, w0: float, w1: float, side: Vector3) -> void:
	var s0 := side * (w0 * 0.5)
	var s1 := side * (w1 * 0.5)
	var idx := verts.size()
	verts.append_array([a - s0, a + s0, b + s1, b - s1])
	# Sample the bark texture's opaque CENTRE band, not the full card width:
	# the margins are transparent silhouette feather, so a full 0..1 quad
	# rendered only ~44% of its geometric width — every twig looked thread-thin
	# and alpha-fringed regardless of the thickness slider.
	uvs.append_array([Vector2(0.40, 1.0), Vector2(0.60, 1.0), Vector2(0.60, 0.0), Vector2(0.40, 0.0)])
	var nrm := side.cross(b - a).normalized()
	for _j in 4:
		normals.append(nrm)
	indices.append_array([idx, idx + 1, idx + 2, idx, idx + 2, idx + 3])


## Foliage clusters anchored on REAL branch tips (veg overhaul: deciduous
## rebuild). The skeleton already computes where every limb ends and then threw
## the list away, so the canopy was an ellipsoid ball bolted to the trunk top
## with no relation to the branches under it — the "blob on a stick" silhouette,
## and the reason the crown had a hollow apex.
##
## Returns the same {pos, w, h} records `_deciduous_cluster_layout` produces, so
## every consumer (leaf shells, shadow proxy, FAR cards) is unchanged. Falls
## back to the abstract layout when there are no tips.
static func _clusters_from_tips(tips: Array, crown_w: float, crown_h: float,
		trunk_h: float, settings: Dictionary) -> Array:
	if tips.is_empty():
		return _deciduous_cluster_layout(crown_w, crown_h, trunk_h, settings)
	var target := clampi(int(round(float(settings.get("deciduous_cluster_count", 8)))), 3, 24)
	var size_mul := float(settings.get("deciduous_cluster_size", 1.0))
	# Clump spread pushes foliage clumps out radially from the trunk axis (>1)
	# or huddles them inward (<1), bounded so foliage never detaches far from
	# its limb. Deliberately a FRESH key: the old cluster_spread/tightness pair
	# was tuned against the abstract ring layout (Mt Vernon saved 0.67/1.12,
	# which would shrink every tip-anchored crown to 60%) — reusing those saved
	# values reproduces the exact defect on every already-tuned map.
	var radial_mul := clampf(float(settings.get("deciduous_clump_spread", 1.0)), 0.55, 1.6)
	# Cluster centres stay ON stride-picked tips (tips are appended in creation
	# order, so a stride samples across the whole crown) — clumps must CAP
	# limbs. A Lloyd-recentring experiment here averaged centres toward the
	# crown interior and rebuilt the exact floating-lollipop silhouette this
	# system exists to avoid. Unpicked tips instead grow their nearest clump
	# (bounded, below) so no twig arc pokes out naked.
	var picked: Array = []
	if tips.size() <= target:
		picked = tips.duplicate()
	else:
		var stride := float(tips.size()) / float(target)
		for i in target:
			picked.append(tips[mini(int(floor(float(i) * stride)), tips.size() - 1)])
	# Per-clump reach: how far the farthest assigned unpicked tip sits from its
	# nearest clump centre.
	var reach: Array = []
	for _i in picked.size():
		reach.append(0.0)
	if tips.size() > picked.size():
		for tip in tips:
			var t3r := tip as Vector3
			var best_r := 0
			var best_dr := INF
			for c in picked.size():
				var d := t3r.distance_squared_to(picked[c])
				if d < best_dr:
					best_dr = d
					best_r = c
			reach[best_r] = maxf(float(reach[best_r]), sqrt(best_dr))
	# Tile the crown envelope: each clump claims an equal share of the crown
	# volume, sized ~30% over its exact share so neighbours overlap into one
	# continuous canopy at ANY cluster count. The old crown_w-only formula was
	# tuned for tips huddled on a ring — once space colonization spread the tips
	# through the full 3D envelope, those clumps read as isolated puffs with sky
	# between them. Near-spherical (height follows width): a leaf mass on a
	# branch end is a rough ball, not a slice of the crown's aspect ratio.
	var crown_base_c := clampf(float(settings.get("deciduous_crown_base", 0.42)), 0.05, 0.92)
	var reach_c := clampf(float(settings.get("deciduous_branch_reach", 1.0)), 0.4, 1.6)
	var env_r := maxf(crown_w * 0.5 * reach_c, 0.5)
	var env_h := maxf(trunk_h + crown_h - trunk_h * crown_base_c, 0.5)
	var env_vol := PI * env_r * env_r * env_h * 0.55  # crown solid ≈ 55% of its cylinder
	var clump_r := 1.30 * pow(env_vol / maxf(float(picked.size()), 1.0)
		* 3.0 / (4.0 * PI), 1.0 / 3.0)
	var cw := clump_r / 0.62 * size_mul  # rx below is cw * 0.62
	var ch := cw * 0.85
	# Foliage must not reach below the trunk base: foot_local_y is hardcoded 0
	# for trees, so a shell dipping under y=0 would sink every instance by the
	# overshoot. The per-cluster floor below keeps each clump's BOTTOM
	# (centre − ry, ry ≈ h·0.55 ×1.2 lump headroom) above ground.
	var floor_base := 0.0
	var out: Array = []
	for ci in picked.size():
		var p: Vector3 = picked[ci]
		# Clusters sit slightly beyond the tip along the limb's outward lean, so
		# foliage caps the branch instead of swallowing it.
		var radial := Vector3(p.x, 0.0, p.z)
		var lean := radial.normalized() * 0.12 if radial.length_squared() > 1e-6 else Vector3.ZERO
		var pos := p + lean
		pos.x *= radial_mul
		pos.z *= radial_mul
		# Grow (bounded ×1.35) to cover this clump's farthest assigned twig tip.
		var need_w := float(reach[ci]) * 0.75 / 0.62 if ci < reach.size() else 0.0
		var cwc := clampf(maxf(cw, need_w), cw, cw * 1.35)
		var chc := cwc * 0.85
		# Shell radius ry = h·0.55, inflated up to ×(1+lump) by the surface bump.
		var lump_c := clampf(float(settings.get("deciduous_leaf_lump", 0.39)), 0.0, 0.6)
		pos.y = maxf(pos.y, floor_base + chc * 0.55 * (1.0 + lump_c) + 0.02)
		out.append({"pos": pos, "w": cwc, "h": chc})
	# Fit the crown to its authored width: clump centres + their shell radii
	# must not overhang crown_w/2, or the exact-size XZ pass has to squeeze the
	# whole tree (trunk included) to compensate. Radial squeeze of the CENTRES
	# only — clump sizes stay, so foliage keeps its volume.
	var half_w := crown_w * 0.5
	var max_ext := 0.0
	for c in out:
		var cp: Vector3 = c["pos"]
		max_ext = maxf(max_ext,
			Vector2(cp.x, cp.z).length() + float(c["w"]) * 0.62)
	if max_ext > half_w and max_ext > 0.01:
		for c in out:
			var cp: Vector3 = c["pos"]
			var r := Vector2(cp.x, cp.z).length()
			if r < 0.01:
				continue
			# Solve per-cluster: new_r + rx = half_w where new_r = r·k.
			var k := clampf((half_w - float(c["w"]) * 0.62) / r, 0.25, 1.0)
			cp.x *= k
			cp.z *= k
			c["pos"] = cp
	return out


static func _deciduous_cluster_layout(crown_w: float, crown_h: float, trunk_h: float,
		settings: Dictionary = {}) -> Array:
	var count := clampi(int(round(float(settings.get("deciduous_cluster_count", 8)))), 3, 16)
	var spread_mul := float(settings.get("deciduous_cluster_spread", 1.0))
	var size_mul := float(settings.get("deciduous_cluster_size", 1.0))
	var tightness := maxf(float(settings.get("deciduous_cluster_tightness", 1.0)), 0.35)
	var spread := crown_w * 0.45 * spread_mul / tightness
	var cw := crown_w * 0.30 * size_mul
	var ch := crown_h * 0.40 * size_mul
	var overlap_down := minf(0.25, crown_h * 0.06)
	var out: Array = [
		{"pos": Vector3(0.0, trunk_h - overlap_down, 0.0), "w": cw * 1.08, "h": ch * 0.95},
	]
	var ring_n := count - 1
	for i in ring_n:
		var t := float(i) / maxf(float(ring_n), 1.0)
		var angle := float(i) * TAU * 0.618034 * tightness
		var elev_t := lerpf(0.08, 0.82, t)
		var r := spread * lerpf(0.50, 1.0, sqrt(t))
		var y := trunk_h + crown_h * elev_t
		var sz := lerpf(1.0, 0.76, t)
		out.append({
			"pos": Vector3(cos(angle) * r * 0.55, y, sin(angle) * r * 0.55),
			"w": cw * sz,
			"h": ch * sz,
		})
	return out


## Whorls stack on the trunk axis in a tapering cone; per-tier yaw spin breaks
## vertical repeat without offsetting whorls off-center.
static func _pine_cluster_layout(card_w: float, card_h: float,
		settings: Dictionary = {}) -> Array:
	var tiers := clampi(int(round(float(settings.get("pine_whorl_count", 7)))), 3, 14)
	var bough_scale := float(settings.get("pine_bough_scale", 1.0))
	var v_spacing := maxf(float(settings.get("pine_whorl_spacing", 1.0)), 0.45)
	var jitter := float(settings.get("pine_whorl_jitter", 0.08))
	var y_curve := 1.0 / v_spacing
	var out: Array = []
	for i in tiers:
		var t := float(i) / maxf(float(tiers - 1), 1.0)
		var fi := float(i)
		var y_norm := pow(t, y_curve)
		var y := card_h * lerpf(0.20, 0.94, y_norm)
		var w := card_w * lerpf(1.08, 0.28, t) * bough_scale
		var h := card_h * lerpf(0.32, 0.12, t) * bough_scale
		var wobble := 1.0 + sin(fi * 2.41) * 0.06 * jitter
		var yaw := fi * TAU / 6.0 + sin(fi * 2.1) * 0.45 * jitter
		out.append({
			"pos": Vector3(0.0, y, 0.0),
			"w": w * wobble,
			"h": h * (1.0 + cos(fi * 3.07) * 0.05 * jitter),
			"yaw": yaw,
			"cards": 3,
		})
	return out


static func _shrub_cluster_layout(card_w: float, card_h: float,
		settings: Dictionary = {}) -> Array:
	var count := clampi(int(round(float(settings.get("shrub_cluster_count", 6)))), 3, 10)
	var spread_mul := float(settings.get("shrub_cluster_spread", 1.0))
	var size_mul := float(settings.get("shrub_cluster_size", 1.0))
	var spread := card_w * 0.38 * spread_mul
	var out: Array = []
	for i in count:
		var t := float(i) / maxf(float(count - 1), 1.0)
		var angle := float(i) * TAU * 0.618034
		var r := spread * lerpf(0.0, 1.0, t)
		var y := card_h * lerpf(0.30, 0.62, t)
		var sz := lerpf(0.92, 0.58, t) * size_mul
		out.append({
			"pos": Vector3(cos(angle) * r * 0.42, y, sin(angle) * r * 0.42),
			"w": card_w * sz,
			"h": card_h * sz,
		})
	return out


static func _build_pine_mesh(spec: Dictionary, settings: Dictionary) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var trunk_w := float(spec.get("trunk_w", 0.24))
	var trunk_h := card_h * 0.94

	var trunk_verts := PackedVector3Array()
	var trunk_uvs := PackedVector2Array()
	var trunk_normals := PackedVector3Array()
	var trunk_indices := PackedInt32Array()
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5
		_add_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w, trunk_h, 0.0, angle, Vector3(0.0, 0.85, 0.0))

	# Whorl layout reads the archetype/macro-derived whorl keys (v3): inject
	# them over a settings copy so the layout function stays unchanged.
	var lay_settings := settings.duplicate()
	if spec.has("whorl_count"):
		lay_settings["pine_whorl_count"] = float(spec["whorl_count"])
	if spec.has("bough_scale"):
		lay_settings["pine_bough_scale"] = float(spec["bough_scale"])
	var foliage_verts := PackedVector3Array()
	var foliage_uvs := PackedVector2Array()
	var foliage_normals := PackedVector3Array()
	var foliage_indices := PackedInt32Array()
	for c in _pine_cluster_layout(card_w, card_h, lay_settings):
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(foliage_verts, foliage_uvs, foliage_normals, foliage_indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.72, 0.0),
			float(c.get("yaw", 0.0)), int(c.get("cards", 3)))

	# Exact-size pass: height/crown in real metres (Vegetation Overhaul v2).
	var norm_arrays: Array = [trunk_verts, foliage_verts]
	_normalize_tree_surfaces(norm_arrays, float(spec.get("height_m", card_h)),
		float(spec.get("crown_m", card_w)))
	trunk_verts = norm_arrays[0]
	foliage_verts = norm_arrays[1]

	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species("pine", settings))

	var foliage_arr: Array = []
	foliage_arr.resize(Mesh.ARRAY_MAX)
	foliage_arr[Mesh.ARRAY_VERTEX] = foliage_verts
	foliage_arr[Mesh.ARRAY_TEX_UV] = foliage_uvs
	foliage_arr[Mesh.ARRAY_NORMAL] = foliage_normals
	foliage_arr[Mesh.ARRAY_INDEX] = foliage_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, foliage_arr)
	var mat_settings := settings.duplicate(true)
	if bool(settings.get("pine_fur_enabled", true)):
		mat_settings["pine_fur_strength"] = float(settings.get("pine_fur_strength", 0.38))
	else:
		mat_settings["pine_fur_strength"] = 0.0
	mesh.surface_set_material(1, material_for_species("pine", mat_settings))
	return mesh


static func _build_shrub_mesh(spec: Dictionary, settings: Dictionary = {}) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for c in _shrub_cluster_layout(card_w, card_h, settings):
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(verts, uvs, normals, indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.65, 0.0))
	return _arrays_to_mesh(verts, uvs, normals, indices)


static func _build_grass_mesh(spec: Dictionary) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 5:
		_add_card(verts, uvs, normals, indices,
			card_w, card_h, 0.0, float(card_i) * TAU / 5.0, Vector3(0.0, 0.15, 0.0))
	return _arrays_to_mesh(verts, uvs, normals, indices)


static func _build_grass_blade_texture(spec: Dictionary) -> Texture2D:
	var w := 32
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var bottom: Color = spec["bottom"]
	var top: Color = spec["top"]
	var highlight: Color = spec["highlight"]
	for y in h:
		for x in w:
			var nx := (float(x) + 0.5) / float(w) - 0.5
			var ny := float(y) / float(h)
			var half_w := (0.44 - ny * 0.30) * 0.5
			if absf(nx) > half_w:
				continue
			var edge := 1.0 - smoothstep(half_w * 0.65, half_w, absf(nx))
			var base := bottom.lerp(top, ny)
			var lit := base.lerp(highlight, smoothstep(0.5, 1.0, ny) * 0.42)
			lit.a = edge * (0.88 + ny * 0.12)
			img.set_pixel(x, y, lit)
	img.flip_y()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _arrays_to_mesh(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array) -> ArrayMesh:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _build_card_mesh(card_w: float, card_h: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 3:
		_add_card(verts, uvs, normals, indices, card_w, card_h, 0.0,
			float(card_i) * PI / 3.0, Vector3(0.0, 0.7, 0.0))
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _build_bark_texture(spec: Dictionary) -> Texture2D:
	var size := 128
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var bark: Color = spec.get("bark", Color(0.18, 0.12, 0.07))
	var shadow := Color(0.03, 0.025, 0.02)
	var n := FastNoiseLite.new()
	n.seed = "bark".hash()
	n.frequency = 0.12
	# Elongated vertical structures — real bark breaks into ridges and furrows
	# along the trunk, not isotropic blotches.
	var n_ridge := FastNoiseLite.new()
	n_ridge.seed = "bark_ridge".hash()
	n_ridge.frequency = 0.05
	var half := float(size) * 0.5
	for y in size:
		for x in size:
			var nx := absf((float(x) - half) / half)
			var v := float(y) / float(size)
			if nx > 0.22:
				continue
			var ncol := (n.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			# Ridges: high x-frequency, low y-frequency = vertical furrows.
			var ridge := (n_ridge.get_noise_2d(float(x) * 5.5, float(y) * 0.7) + 1.0) * 0.5
			var furrow := smoothstep(0.30, 0.62, ridge)
			# Gentler vertical gradient than the old v*0.4 (which crushed the
			# lower trunk to near-black) + a faint warm lift on ridge crests.
			var c := bark.lerp(shadow, v * 0.16 + ncol * 0.12 + (1.0 - furrow) * 0.30)
			c = c.lerp(Color(bark.r * 1.35, bark.g * 1.28, bark.b * 1.15), furrow * 0.22)
			c.a = 1.0 if nx < 0.18 else smoothstep(0.22, 0.18, nx)
			if c.a > 0.05:
				img.set_pixel(x, y, c)
	img.flip_y()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_cluster_foliage_texture(spec: Dictionary, species: String) -> Texture2D:
	var size := 128 if species != "deciduous" else 160
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var n_shape := FastNoiseLite.new()
	n_shape.seed = species.hash()
	n_shape.frequency = 0.055
	var n_color := FastNoiseLite.new()
	n_color.seed = species.hash() + 17
	n_color.frequency = 0.11
	var top_color: Color = spec["top"]
	var bottom_color: Color = spec["bottom"]
	var highlight: Color = spec["highlight"]
	var shadow := Color(0.02, 0.04, 0.015)
	var circles: Array = _foliage_texture_circles(species)
	var half := float(size)
	for y in size:
		for x in size:
			var px := (float(x) + 0.5) / half
			var py := (float(y) + 0.5) / half
			var alpha := 0.0
			for c in circles:
				var cd: Dictionary = c
				var dx := px - float(cd["cx"])
				var dy := py - float(cd["cy"])
				var r := float(cd["r"])
				var dist := sqrt(dx * dx + dy * dy) / maxf(r, 0.01)
				var blob := clampf(1.0 - dist, 0.0, 1.0)
				var n := (n_shape.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
				var edge := smoothstep(0.42, 0.78, blob * (0.62 + n * 0.55))
				alpha = maxf(alpha, edge)
			if alpha < 0.03:
				continue
			var v := py
			var brown_t := clampf((v - 0.35) / 0.65, 0.0, 1.0)
			var base := top_color.lerp(bottom_color, brown_t * 0.22)
			var ncol := (n_color.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var lit := base.lerp(highlight, smoothstep(0.45, 0.95, ncol) * 0.58)
			var final := lit.lerp(shadow, brown_t * 0.16)
			final.a = alpha
			img.set_pixel(x, y, final)
	img.flip_y()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _foliage_texture_circles(species: String) -> Array:
	match species:
		"deciduous":
			return [
				{"cx": 0.50, "cy": 0.48, "r": 0.36},
				{"cx": 0.30, "cy": 0.56, "r": 0.24},
				{"cx": 0.70, "cy": 0.52, "r": 0.22},
				{"cx": 0.46, "cy": 0.34, "r": 0.18},
			]
		"pine":
			return [
				{"cx": 0.50, "cy": 0.46, "r": 0.40},
				{"cx": 0.34, "cy": 0.54, "r": 0.22},
				{"cx": 0.66, "cy": 0.50, "r": 0.18},
				{"cx": 0.48, "cy": 0.30, "r": 0.14},
			]
		"grass_lawn", "grass_field":
			return [
				{"cx": 0.50, "cy": 0.62, "r": 0.22},
				{"cx": 0.42, "cy": 0.48, "r": 0.14},
				{"cx": 0.58, "cy": 0.50, "r": 0.12},
			]
		"shrub":
			return [
				{"cx": 0.50, "cy": 0.50, "r": 0.36},
				{"cx": 0.32, "cy": 0.44, "r": 0.20},
				{"cx": 0.68, "cy": 0.46, "r": 0.18},
				{"cx": 0.44, "cy": 0.62, "r": 0.14},
			]
		_:
			return [
				{"cx": 0.50, "cy": 0.50, "r": 0.32},
				{"cx": 0.34, "cy": 0.44, "r": 0.18},
				{"cx": 0.66, "cy": 0.46, "r": 0.16},
			]


static func _build_deciduous_canopy_texture(spec: Dictionary) -> Texture2D:
	return _build_cluster_foliage_texture(spec, "deciduous")


static func _build_deciduous_texture(spec: Dictionary) -> Texture2D:
	return _build_cluster_foliage_texture(spec, "deciduous")


static func _build_texture(spec: Dictionary, species: String) -> Texture2D:
	return _build_cluster_foliage_texture(spec, species)


static func _apply_foliage_uniforms(mat: ShaderMaterial, species: String, settings: Dictionary) -> void:
	var known := ["pine", "deciduous", "shrub", "grass_lawn", "grass_field"]
	var prefix := species if species in known else mesh_family(species)
	if prefix not in known:
		prefix = "deciduous"
	var variant := str(settings.get("_variant_species", prefix))
	var spec: Dictionary = SPECS.get(variant, SPECS.get(prefix, SPECS["shrub"]))
	var tint: Color = settings.get("%s_albedo_tint" % variant,
		settings.get("%s_albedo_tint" % prefix, Color.WHITE))
	if tint == Color.WHITE:
		tint = spec.get("top", Color.WHITE)
	mat.set_shader_parameter("albedo_tint", Vector3(tint.r, tint.g, tint.b))
	var hi: Color = settings.get("%s_highlight_tint" % variant,
		settings.get("%s_highlight_tint" % prefix, spec.get("highlight", Color(0.42, 0.52, 0.16))))
	mat.set_shader_parameter("highlight_tint", Vector3(hi.r, hi.g, hi.b))
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.03)))
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.7)))
	mat.set_shader_parameter("wind_profile", _wind_profile_for_species(prefix))
	mat.set_shader_parameter("dither_strength", float(settings.get("dither_strength", 1.0)))
	mat.set_shader_parameter("alpha_dither_min", float(settings.get("alpha_dither_min", 0.20)))
	mat.set_shader_parameter("alpha_dither_max", float(settings.get("alpha_dither_max", 0.50)))
	mat.set_shader_parameter("trunk_uv_cutoff", float(settings.get("trunk_uv_cutoff", 0.0)))
	mat.set_shader_parameter("near_crisp_m", float(settings.get("near_crisp_m", 40.0)))
	mat.set_shader_parameter("far_dither_m", float(settings.get("far_dither_m", 120.0)))
	mat.set_shader_parameter("haze_strength", float(settings.get("haze_strength", 0.65)))
	mat.set_shader_parameter("lean_amount", float(settings.get("lean_amount", 0.30)))
	mat.set_shader_parameter("subsurface_strength", float(settings.get("subsurface_strength", 0.15)))
	mat.set_shader_parameter("translucency_strength", float(settings.get("translucency_strength", 0.25)))
	mat.set_shader_parameter("canopy_roundness", float(settings.get("canopy_roundness", 0.40)))
	mat.set_shader_parameter("color_variation", float(settings.get("color_variation", 0.12)))
	mat.set_shader_parameter("roughness_value", float(settings.get("foliage_roughness", 0.95)))
	mat.set_shader_parameter("ao_strength", float(settings.get("ao_strength", 0.35)))
	if settings.has("ao_tint"):
		var aoc: Color = settings["ao_tint"]
		mat.set_shader_parameter("ao_tint", Vector3(aoc.r, aoc.g, aoc.b))
	mat.set_shader_parameter("hue_jitter", float(settings.get("hue_jitter", 0.0)))
	mat.set_shader_parameter("seasonal_strength", float(settings.get("seasonal_strength", 0.0)))
	
	mat.set_shader_parameter("spring_bud", float(settings.get("spring_bud", 0.0)))
	mat.set_shader_parameter("autumn", float(settings.get("autumn", 0.0)))
	if settings.has("bud_color"):
		var c: Color = settings["bud_color"]
		mat.set_shader_parameter("bud_color", Vector3(c.r, c.g, c.b))
	if settings.has("autumn_warm"):
		var c: Color = settings["autumn_warm"]
		mat.set_shader_parameter("autumn_warm", Vector3(c.r, c.g, c.b))
	if settings.has("autumn_orange"):
		var c: Color = settings["autumn_orange"]
		mat.set_shader_parameter("autumn_orange", Vector3(c.r, c.g, c.b))
	if settings.has("autumn_hot"):
		var c: Color = settings["autumn_hot"]
		mat.set_shader_parameter("autumn_hot", Vector3(c.r, c.g, c.b))
		
	if settings.has("haze_color"):
		var hc: Color = settings["haze_color"]
		mat.set_shader_parameter("haze_color", Vector3(hc.r, hc.g, hc.b))
	if settings.has("seasonal_tint"):
		var st: Color = settings["seasonal_tint"]
		mat.set_shader_parameter("seasonal_tint", Vector3(st.r, st.g, st.b))
	if settings.has("drape_tex") and settings["drape_tex"] is Texture2D:
		mat.set_shader_parameter("drape_tex", settings["drape_tex"])
		mat.set_shader_parameter("use_drape", true)
		mat.set_shader_parameter("drape_extent_m", float(settings.get("drape_extent_m", 30000.0)))
		mat.set_shader_parameter("drape_match_strength", float(settings.get("drape_match_strength", 0.0)))
	if prefix == "pine":
		var fur := float(settings.get("pine_fur_strength", 0.0))
		mat.set_shader_parameter("fur_strength", fur)
		if fur > 0.001:
			mat.set_shader_parameter("fur_cells", float(settings.get("pine_fur_cells", 20.0)))
			mat.set_shader_parameter("fur_tuft_size", float(settings.get("pine_fur_tuft_size", 0.58)))
			mat.set_shader_parameter("fur_gap", float(settings.get("pine_fur_gap", 0.24)))
		mat.set_shader_parameter("whorl_variation_strength",
			float(settings.get("pine_whorl_variation", 0.32)))
		mat.set_shader_parameter("whorl_band_h", float(settings.get("pine_whorl_band_h", 0.62)))
		mat.set_shader_parameter("cone_sharpness", float(settings.get("pine_cone_sharpness", 0.42)))
		mat.set_shader_parameter("canopy_roundness", float(settings.get("pine_canopy_roundness", 0.52)))
	mat.set_shader_parameter("color_fade", float(settings.get("deciduous_color_fade", 1.0)))
	if prefix.begins_with("grass_"):
		mat.set_shader_parameter("near_crisp_m", 100.0)
		mat.set_shader_parameter("far_dither_m", 250.0)
		mat.set_shader_parameter("dither_strength", 0.22)
		mat.set_shader_parameter("alpha_dither_min", 0.08)
		mat.set_shader_parameter("alpha_dither_max", 0.24)
		mat.set_shader_parameter("subsurface_strength", maxf(
			float(settings.get("subsurface_strength", 0.15)), 0.42))
		mat.set_shader_parameter("lean_amount", 0.06)
		mat.set_shader_parameter("haze_strength", 0.35)


static func _wind_profile_for_species(species: String) -> float:
	match species:
		"pine":
			return 0.0
		"deciduous":
			return 1.0
		"shrub":
			return 2.0
		"grass_lawn", "grass_field":
			return 3.0
	return 1.0


static func _apply_bark_uniforms(mat: ShaderMaterial, settings: Dictionary) -> void:
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.03)) * 0.3)
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.7)))
	mat.set_shader_parameter("wind_profile", 0.15)
	mat.set_shader_parameter("roughness_value", float(settings.get("bark_roughness", 0.98)))
	mat.set_shader_parameter("bark_ao_strength", float(settings.get("bark_ao_strength", 0.28)))
	mat.set_shader_parameter("bark_color_jitter", float(settings.get("bark_color_jitter", 0.06)))
	if settings.has("bark_albedo_tint"):
		var c: Color = settings["bark_albedo_tint"]
		mat.set_shader_parameter("albedo_tint", Vector3(c.r, c.g, c.b))


# ==================== PHASE 5: PALM / CACTUS / PHOTOCARD ====================


static func _palm_spec(settings: Dictionary, species: String = "palm") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["palm"]).duplicate(true)
	base["width"] = float(settings.get("palm_card_w", base["width"]))
	base["height"] = float(settings.get("palm_card_h", base["height"]))
	base["trunk_w"] = float(settings.get("palm_trunk_w", base.get("trunk_w", 0.35)))
	return base


static func _cactus_spec(settings: Dictionary, species: String = "cactus") -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["cactus"]).duplicate(true)
	base["width"] = float(settings.get("cactus_card_w", base["width"]))
	base["height"] = float(settings.get("cactus_card_h", base["height"]))
	return base


## Oriented tapered quad from `origin` along `dir` — the palm frond primitive.
## UV v runs 0 (base) -> 1 (tip) so the frond texture's rachis points outward.
static func _add_frond_quad(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		origin: Vector3, dir: Vector3, length: float, base_w: float, tip_w: float) -> void:
	var base := verts.size()
	var d := dir.normalized()
	var side := d.cross(Vector3.UP)
	if side.length() < 0.01:
		side = Vector3.RIGHT
	side = side.normalized()
	var tip := origin + d * length
	verts.append_array([
		origin - side * base_w * 0.5, origin + side * base_w * 0.5,
		tip + side * tip_w * 0.5, tip - side * tip_w * 0.5,
	])
	uvs.append_array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	var n := side.cross(d).normalized()
	if n.y < 0.0:
		n = -n
	for _j in 4:
		normals.append(n)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


## Palm: 2 crossed tapered trunk cards (bark surface 0) + a radial crown of
## arched fronds (foliage surface 1). ~2 + N*2 quads per tree (N=9 default) —
## between pine (23) and shrub (18) in cost. Frond droop and count are
## deterministic per species so the shared mesh is stable across rebuilds.
static func _build_palm_mesh(spec: Dictionary, settings: Dictionary) -> ArrayMesh:
	var trunk_h := float(spec["height"])
	var trunk_w := float(spec.get("trunk_w", 0.35))
	var spread := float(spec["width"])
	var species := str(settings.get("_variant_species", "palm"))
	var trunk_verts := PackedVector3Array()
	var trunk_uvs := PackedVector2Array()
	var trunk_normals := PackedVector3Array()
	var trunk_indices := PackedInt32Array()
	for card_i in 2:
		_add_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w, trunk_h, 0.0, float(card_i) * PI * 0.5, Vector3(0.0, 0.85, 0.0))
	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species(species, settings))

	var fv := PackedVector3Array()
	var fu := PackedVector2Array()
	var fn := PackedVector3Array()
	var fi := PackedInt32Array()
	var frond_n := clampi(int(round(float(settings.get("palm_frond_count", 9.0)))), 5, 14)
	var frond_len := spread * 0.52
	var frond_w := frond_len * 0.34
	var crown := Vector3(0.0, trunk_h, 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = species.hash()
	# Upper arcing ring + a lower drooping ring — the two-tier crown that
	# makes a palm silhouette read at a glance.
	for i in frond_n:
		var az := TAU * float(i) / float(frond_n) + rng.randf_range(-0.12, 0.12)
		var pitch := deg_to_rad(rng.randf_range(8.0, 26.0))
		var dir := Vector3(cos(az) * cos(pitch), sin(pitch), sin(az) * cos(pitch))
		_add_frond_quad(fv, fu, fn, fi, crown, dir, frond_len, frond_w * 0.5, frond_w)
	for i in frond_n:
		var az2 := TAU * (float(i) + 0.5) / float(frond_n) + rng.randf_range(-0.12, 0.12)
		var pitch2 := deg_to_rad(rng.randf_range(-34.0, -14.0))
		var dir2 := Vector3(cos(az2) * cos(pitch2), sin(pitch2), sin(az2) * cos(pitch2))
		_add_frond_quad(fv, fu, fn, fi, crown, dir2, frond_len * 1.08, frond_w * 0.5, frond_w)
	var f_arr: Array = []
	f_arr.resize(Mesh.ARRAY_MAX)
	f_arr[Mesh.ARRAY_VERTEX] = fv
	f_arr[Mesh.ARRAY_TEX_UV] = fu
	f_arr[Mesh.ARRAY_NORMAL] = fn
	f_arr[Mesh.ARRAY_INDEX] = fi
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, f_arr)
	mesh.surface_set_material(1, material_for_species(species, settings))
	return mesh


## Cactus: columnar body as crossed cards; saguaro-style species get side-arm
## cards, prickly pear gets a pad cluster. Single foliage-family surface (the
## runtime applies material_for_species as an override, like shrubs).
static func _build_cactus_mesh(spec: Dictionary, settings: Dictionary,
		species: String = "cactus") -> ArrayMesh:
	var w := float(spec["width"])
	var h := float(spec["height"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	if species == "prickly_pear":
		# A low cluster of oval pads.
		_add_cluster_cards(verts, uvs, normals, indices,
			Vector3(0.0, h * 0.45, 0.0), w * 0.8, h * 0.9, Vector3(0.0, 0.5, 0.0), 0.0, 4)
		_add_cluster_cards(verts, uvs, normals, indices,
			Vector3(w * 0.28, h * 0.3, w * 0.15), w * 0.55, h * 0.6,
			Vector3(0.0, 0.5, 0.0), 0.7, 3)
		return _arrays_to_mesh(verts, uvs, normals, indices)
	# Columnar body.
	var body_w := w if species != "saguaro" else w * 0.34
	for card_i in 2:
		_add_card(verts, uvs, normals, indices, body_w, h, 0.0,
			float(card_i) * PI * 0.5, Vector3(0.0, 0.35, 0.0))
	if species == "saguaro" or species == "joshua_tree":
		# Two asymmetric arms: vertical cards offset from the trunk, starting
		# mid-height — the classic silhouette.
		var arm_w := body_w * 0.72
		var arm_h := h * 0.45
		for arm in [[-w * 0.32, h * 0.42, 0.35], [w * 0.30, h * 0.55, -0.5]]:
			for card_i in 2:
				_add_card(verts, uvs, normals, indices, arm_w, arm_h, float(arm[1]),
					float(card_i) * PI * 0.5 + float(arm[2]), Vector3(0.0, 0.35, 0.0),
					Vector3(float(arm[0]), 0.0, float(arm[0]) * 0.4))
	return _arrays_to_mesh(verts, uvs, normals, indices)


## Feathered palm-frond texture: dark central rachis, angled leaflet stripes
## whose alpha gaps give the classic serrated silhouette. v runs base->tip.
static func _build_palm_frond_texture(spec: Dictionary) -> Texture2D:
	var w := 96
	var h := 160
	var img := Image.create(w, h, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var top: Color = spec["top"]
	var bottom: Color = spec["bottom"]
	var highlight: Color = spec["highlight"]
	for y in h:
		var v := float(y) / float(h)
		# Frond narrows toward the tip.
		var half_w := (0.46 - v * 0.30) * 0.5
		for x in w:
			var u := (float(x) + 0.5) / float(w) - 0.5
			var au := absf(u)
			if au > half_w:
				continue
			# Central rachis strip.
			if au < 0.022:
				var rc := bottom.darkened(0.35)
				rc.a = 1.0
				img.set_pixel(x, y, rc)
				continue
			# Leaflets: stripes angled away from the rachis; the sin gap makes
			# the serration. Leaflet phase follows distance along the frond.
			var leaflet := sin((v * 30.0 + au * 26.0) * PI)
			if leaflet < -0.15:
				continue
			var lit := bottom.lerp(top, clampf(v * 1.2, 0.0, 1.0))
			lit = lit.lerp(highlight, clampf(leaflet, 0.0, 1.0) * 0.35)
			lit.a = smoothstep(half_w, half_w * 0.85, au)
			img.set_pixel(x, y, lit)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Ribbed columnar cactus texture (vertical ridge shading, rounded top alpha).
static func _build_cactus_texture(spec: Dictionary, species: String) -> Texture2D:
	var w := 64
	var h := 128
	var img := Image.create(w, h, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var top: Color = spec["top"]
	var bottom: Color = spec["bottom"]
	var highlight: Color = spec["highlight"]
	var pear := species == "prickly_pear"
	for y in h:
		var v := float(y) / float(h)
		for x in w:
			var u := (float(x) + 0.5) / float(w) - 0.5
			var au := absf(u)
			var half_w := 0.42
			# Rounded top (and rounded pad shape for prickly pear).
			if pear:
				var dy := (v - 0.5) * 1.15
				if u * u + dy * dy > 0.42 * 0.42:
					continue
			else:
				if v > 0.86:
					var cap := sqrt(maxf(0.0, 1.0 - pow((v - 0.86) / 0.14, 2.0)))
					half_w = 0.42 * cap
				if au > half_w:
					continue
			# Vertical ribs.
			var rib := 0.5 + 0.5 * sin(u * TAU * (5.0 if pear else 7.0))
			var c := bottom.lerp(top, v * 0.8 + 0.1)
			c = c.lerp(highlight, rib * 0.28)
			c = c.darkened((1.0 - rib) * 0.22)
			c.a = 1.0
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Photocard: 3 crossed cards carrying a REAL photo/render texture, sized from
## the species SPECS. Rides foliage.gdshader so wind + seasonal uniforms apply
## (the texture's own colors carry realism; autumn ramp still recolors).
static func _build_photocard_mesh(species: String, settings: Dictionary,
		photo: Texture2D) -> ArrayMesh:
	var family := mesh_family(species)
	var spec: Dictionary = SPECS.get(species, SPECS.get(family, SPECS["shrub"]))
	# Tree families are v3 real-unit (the photocard frames the WHOLE tree at
	# exactly its authored height); other families keep the legacy card dims.
	var w: float
	var full_h: float
	if family == "deciduous":
		var d := _deciduous_spec(settings, species)
		w = float(d["crown_m"])
		full_h = float(d["height_m"])
	elif family == "pine":
		var p := _pine_spec(settings, species)
		w = float(p["crown_m"])
		full_h = float(p["height_m"])
	else:
		w = float(spec.get("width", 8.0))
		full_h = float(spec.get("height", 8.0)) + float(spec.get("trunk_h", 0.0))
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 3:
		_add_card(verts, uvs, normals, indices, w, full_h, 0.0,
			float(card_i) * PI / 3.0, Vector3(0.0, 0.55, 0.0))
	var mesh := _arrays_to_mesh(verts, uvs, normals, indices)
	var mat := ShaderMaterial.new()
	mat.shader = FOLIAGE_SHADER
	mat.set_shader_parameter("albedo_tex", photo)
	_apply_foliage_uniforms(mat, family, settings)
	_configure_foliage_cutout_shadow(mat)
	mesh.surface_set_material(0, mat)
	return mesh
