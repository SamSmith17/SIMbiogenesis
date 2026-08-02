class_name GrassBuilder
extends RefCounted

## Dedicated GPU grass — shell-extruded "mat" meshes + grass.gdshader materials.
## Each mat is a stack of flat horizontal shells (a classic shell/fur-texturing
## extrusion) rather than discrete per-blade card geometry: the fragment shader
## fakes blade coverage per shell via a per-cell density/height mask, so from
## up close the swept volume of shells reads as dense individual blades
## without ever instancing a blade. LOD tiers: NEAR (many shells, full detail),
## MID (fewer shells, larger footprint), FAR (flat ground patch quad).

enum LodTier { NEAR, MID, FAR }

const GRASS_SHADER := preload("res://vegetation/grass.gdshader")

const SPECS := {
	# Mowed-lawn look: short, uniform, saturated green (see vegetation_style_config.gd
	# for the height/height_variation/lean defaults that reinforce this).
	"grass_lawn": {
		"mat_w": 0.45, "mat_h": 0.12,
		"root": Color(0.06, 0.28, 0.05), "tip": Color(0.10, 0.46, 0.09),
		"highlight": Color(0.22, 0.62, 0.16),
	},
	# Wild/meadow look: taller, more variation, olive-toward-gold tones.
	"grass_field": {
		"mat_w": 0.55, "mat_h": 0.88,
		"root": Color(0.28, 0.36, 0.08), "tip": Color(0.38, 0.48, 0.12),
		"highlight": Color(0.52, 0.58, 0.20),
	},
}

const SHELL_COUNT_NEAR := 14
const SHELL_COUNT_MID := 7
const LOD_MID_SCALE := 1.35
const LOD_FAR_PATCH_H := 0.02


static func spec_for_species(species: String, settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["grass_lawn"]).duplicate(true)
	var prefix := species if species in SPECS else "grass_lawn"
	# card_w/card_h are the mat's footprint width and overall blade height
	# (renamed in spirit from "blade width" now that geometry is a shell stack,
	# not individual blade cards — the settings dict keys are kept stable).
	base["mat_w"] = float(settings.get("%s_card_w" % prefix, base["mat_w"]))
	base["mat_h"] = float(settings.get("%s_card_h" % prefix, base["mat_h"]))
	return base


static func bulk_scale(species: String, settings: Dictionary) -> float:
	return float(settings.get("%s_bulk_scale" % species, 1.0))


static func foot_local_y() -> float:
	return 0.0


static func mesh_for_lod(species: String, settings: Dictionary, tier: LodTier) -> ArrayMesh:
	var key := "grassmesh|%s|%d|%d" % [species, tier, hash(settings)]
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ArrayMesh:
		return cached
	return VegAssetCache.store(key, _build_mesh_for_lod(species, settings, tier))


static func _build_mesh_for_lod(species: String, settings: Dictionary, tier: LodTier) -> ArrayMesh:
	var spec := spec_for_species(species, settings)
	var use_hex := false
	match tier:
		LodTier.FAR:
			return _build_hex_patch_mesh(spec) if use_hex else _build_patch_mesh(spec)
		LodTier.MID:
			if use_hex:
				return _build_hex_shell_mesh(spec, SHELL_COUNT_MID, LOD_MID_SCALE)
			return _build_shell_mesh(spec, SHELL_COUNT_MID, LOD_MID_SCALE)
		_:
			if use_hex:
				return _build_hex_shell_mesh(spec, SHELL_COUNT_NEAR, 1.0)
			return _build_shell_mesh(spec, SHELL_COUNT_NEAR, 1.0)


static func material_for_species(species: String, settings: Dictionary,
		tier: LodTier = LodTier.NEAR) -> ShaderMaterial:
	var key := "grassmat|%s|%d|%d" % [species, tier, hash(settings)]
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ShaderMaterial:
		return cached
	return VegAssetCache.store(key, _build_material_for_species(species, settings, tier))


static func _build_material_for_species(species: String, settings: Dictionary,
		tier: LodTier) -> ShaderMaterial:
	var spec := spec_for_species(species, settings)
	var prefix := species if species in SPECS else "grass_lawn"
	var mat := ShaderMaterial.new()
	mat.shader = GRASS_SHADER
	var tint: Color = settings.get("%s_albedo_tint" % prefix, Color.WHITE)
	mat.set_shader_parameter("root_color", Vector3(spec["root"].r, spec["root"].g, spec["root"].b))
	mat.set_shader_parameter("tip_color", Vector3(spec["tip"].r, spec["tip"].g, spec["tip"].b))
	var hi: Color = settings.get("%s_highlight_tint" % prefix, spec["highlight"])
	mat.set_shader_parameter("highlight_color", Vector3(hi.r, hi.g, hi.b))
	mat.set_shader_parameter("albedo_tint", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.04)))
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.9)))
	mat.set_shader_parameter("wind_profile", 3.0)
	mat.set_shader_parameter("subsurface_strength", float(settings.get("subsurface_strength", 0.45)))
	# Per-species hue jitter (e.g. a mowed lawn reads more uniform than a wild
	# field) overrides the shared global hue_jitter when present.
	var default_hue_jitter := float(settings.get("hue_jitter", 0.04))
	mat.set_shader_parameter("hue_jitter", float(settings.get("%s_hue_jitter" % prefix, default_hue_jitter)))
	mat.set_shader_parameter("drape_match_strength", float(settings.get("drape_match_strength", 0.35)))
	mat.set_shader_parameter("mat_width", float(spec.get("mat_w", 0.45)))
	# Shell "fake blade" density — configurable per species (see grass.gdshader).
	mat.set_shader_parameter("cells_per_side", float(settings.get("%s_cells_per_side" % prefix, 6.0)))
	mat.set_shader_parameter("height_variation", float(settings.get("%s_height_variation" % prefix, 0.35)))
	mat.set_shader_parameter("blade_thickness", float(settings.get("%s_blade_thickness" % prefix, 0.5)))
	mat.set_shader_parameter("blade_lean", float(settings.get("%s_blade_lean" % prefix, 0.2)))
	if tier == LodTier.MID:
		mat.set_shader_parameter("near_full_m", 55.0)
		mat.set_shader_parameter("mid_fade_m", 120.0)
		mat.set_shader_parameter("far_patch_m", 320.0)
	elif tier == LodTier.FAR:
		var far_end := float(settings.get("grass_visibility_end_m", DEFAULT_FAR_VISIBILITY_M))
		mat.set_shader_parameter("near_full_m", 0.0)
		mat.set_shader_parameter("mid_fade_m", 180.0)
		mat.set_shader_parameter("far_patch_m", maxf(far_end - 30.0, 220.0))
		mat.set_shader_parameter("patch_strength", 1.0)
	if settings.has("drape_tex") and settings["drape_tex"] is Texture2D:
		mat.set_shader_parameter("drape_tex", settings["drape_tex"])
		mat.set_shader_parameter("use_drape", true)
		mat.set_shader_parameter("drape_extent_m", float(settings.get("drape_extent_m", 30000.0)))
	
	if settings.has("grass_summer_color"):
		var sc: Color = settings["grass_summer_color"]
		mat.set_shader_parameter("summer_color", Vector3(sc.r, sc.g, sc.b))
	if settings.has("grass_fall_color"):
		var fc: Color = settings["grass_fall_color"]
		mat.set_shader_parameter("dry_color", Vector3(fc.r, fc.g, fc.b))

	if settings.has("haze_color"):
		pass  # grass uses patch fade instead of haze
	return mat


## Default cull distance of the FAR patch tier. Overridable per map via the
## `grass_visibility_end_m` style key — 380 m was tuned for the manual layer's
## camp scale and made OSM meadows "down the street" pop out of existence.
const DEFAULT_FAR_VISIBILITY_M := 380.0


static func visibility_range_for_tier(tier: LodTier,
		far_end_m: float = DEFAULT_FAR_VISIBILITY_M) -> Vector2:
	var far := maxf(far_end_m, 240.0)
	match tier:
		LodTier.NEAR:
			return Vector2(0.0, 90.0)
		LodTier.MID:
			return Vector2(75.0, 220.0)
		LodTier.FAR:
			return Vector2(200.0, far)
	return Vector2(0.0, far)


## Builds a stack of `shell_count` flat horizontal quads ("shells") from y=0 to
## y=mat_h, each shrinking slightly toward the top so the silhouette reads as a
## rounded tuft rather than a cylinder. Each shell's vertex COLOR.r carries its
## normalized height (0 at the ground, 1 at the tip) — the fragment shader uses
## it both for wind sway (as the old per-blade top_mask) and to fake individual
## blade coverage per shell (see grass.gdshader).
static func _build_shell_mesh(spec: Dictionary, shell_count: int, width_scale: float) -> ArrayMesh:
	var mat_w := float(spec["mat_w"]) * width_scale
	var mat_h := float(spec["mat_h"])
	var half := mat_w * 0.5
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var denom := maxf(float(shell_count - 1), 1.0)
	for si in shell_count:
		var t := float(si) / denom
		var y := t * mat_h
		var w := half * (1.0 - t * 0.18)
		var base := verts.size()
		verts.append(Vector3(-w, y, -w))
		verts.append(Vector3(w, y, -w))
		verts.append(Vector3(w, y, w))
		verts.append(Vector3(-w, y, w))
		uvs.append(Vector2(0.0, 0.0))
		uvs.append(Vector2(1.0, 0.0))
		uvs.append(Vector2(1.0, 1.0))
		uvs.append(Vector2(0.0, 1.0))
		for _i in 4:
			normals.append(Vector3(0.0, 1.0, 0.0))
			colors.append(Color(t, 0.0, 0.0, 1.0))
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	return _arrays_to_mesh(verts, uvs, normals, indices, colors)


## Flat-top hex shell stack for mowed lawn — mats tile edge-to-edge on a hex grid.
static func _build_hex_shell_mesh(spec: Dictionary, shell_count: int, width_scale: float) -> ArrayMesh:
	var mat_w := float(spec["mat_w"]) * width_scale
	var mat_h := float(spec["mat_h"])
	var circum := mat_w / sqrt(3.0)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var denom := maxf(float(shell_count - 1), 1.0)
	for si in shell_count:
		var t := float(si) / denom
		var y := t * mat_h
		var r := circum * (1.0 - t * 0.18)
		var base := verts.size()
		verts.append(Vector3(0.0, y, 0.0))
		uvs.append(Vector2(0.5, 0.5))
		normals.append(Vector3(0.0, 1.0, 0.0))
		colors.append(Color(t, 0.0, 0.0, 1.0))
		for vi in 6:
			var ang := PI / 6.0 + float(vi) * TAU / 6.0
			verts.append(Vector3(cos(ang) * r, y, sin(ang) * r))
			uvs.append(Vector2(0.5 + cos(ang) * 0.5, 0.5 + sin(ang) * 0.5))
			normals.append(Vector3(0.0, 1.0, 0.0))
			colors.append(Color(t, 0.0, 0.0, 1.0))
		for vi in 6:
			var a := base
			var b := base + 1 + vi
			var c := base + 1 + ((vi + 1) % 6)
			indices.append_array([a, b, c])
	return _arrays_to_mesh(verts, uvs, normals, indices, colors)


static func _build_hex_patch_mesh(spec: Dictionary) -> ArrayMesh:
	var mat_w := float(spec["mat_w"])
	var circum := mat_w / sqrt(3.0)
	var h := LOD_FAR_PATCH_H
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.append(Vector3(0.0, h, 0.0))
	uvs.append(Vector2(0.5, 0.5))
	normals.append(Vector3(0.0, 1.0, 0.0))
	colors.append(Color(1.0, 0.0, 0.0, 1.0))
	for vi in 6:
		var ang := PI / 6.0 + float(vi) * TAU / 6.0
		verts.append(Vector3(cos(ang) * circum, h, sin(ang) * circum))
		uvs.append(Vector2(0.5 + cos(ang) * 0.5, 0.5 + sin(ang) * 0.5))
		normals.append(Vector3(0.0, 1.0, 0.0))
		colors.append(Color(1.0, 0.0, 0.0, 1.0))
	var indices := PackedInt32Array()
	for vi in 6:
		indices.append_array([0, 1 + vi, 1 + ((vi + 1) % 6)])
	return _arrays_to_mesh(verts, uvs, normals, indices, colors)


## Flat HORIZONTAL ground patch for the field FAR tier, sized to the mat
## footprint so scattered patches tile into continuous ground from a distance.
## (Previously a tiny VERTICAL 0.85×0.02 sliver — distant meadows read as
## detached green flecks that never overlapped instead of a grassy field.)
static func _build_patch_mesh(spec: Dictionary) -> ArrayMesh:
	var w := float(spec["mat_w"])
	var half := w * 0.5
	var h := LOD_FAR_PATCH_H
	var verts := PackedVector3Array([
		Vector3(-half, h, -half), Vector3(half, h, -half),
		Vector3(half, h, half), Vector3(-half, h, half),
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for _i in 4:
		normals.append(Vector3(0.0, 1.0, 0.0))
		colors.append(Color(1.0, 0.0, 0.0, 1.0))
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	return _arrays_to_mesh(verts, uvs, normals, indices, colors)


static func _arrays_to_mesh(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		colors: PackedColorArray = PackedColorArray()) -> ArrayMesh:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	if not colors.is_empty():
		arr[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
