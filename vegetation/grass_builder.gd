class_name GrassBuilder
extends RefCounted

## Dedicated GPU grass clumps — curved multi-blade meshes + grass.gdshader materials.
## LOD tiers: NEAR (5 blades), MID (3 wider blades), FAR (flat ground patch quad).

enum LodTier { NEAR, MID, FAR }

const GRASS_SHADER := preload("res://vegetation/grass.gdshader")

const SPECS := {
	"grass_lawn": {
		"blade_w": 0.08, "blade_h": 0.42, "blade_count": 5, "segments": 3,
		"root": Color(0.10, 0.32, 0.08), "tip": Color(0.14, 0.42, 0.12),
		"highlight": Color(0.28, 0.58, 0.18),
	},
	"grass_field": {
		"blade_w": 0.11, "blade_h": 0.88, "blade_count": 5, "segments": 3,
		"root": Color(0.28, 0.36, 0.08), "tip": Color(0.38, 0.48, 0.12),
		"highlight": Color(0.52, 0.58, 0.20),
	},
}

const LOD_MID_SCALE := 1.35
const LOD_FAR_PATCH_W := 0.85
const LOD_FAR_PATCH_H := 0.02


static func spec_for_species(species: String, settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS.get(species, SPECS["grass_lawn"]).duplicate(true)
	var prefix := species if species in SPECS else "grass_lawn"
	base["blade_w"] = float(settings.get("%s_card_w" % prefix, base["blade_w"]))
	base["blade_h"] = float(settings.get("%s_card_h" % prefix, base["blade_h"]))
	return base


static func bulk_scale(species: String, settings: Dictionary) -> float:
	return float(settings.get("%s_bulk_scale" % species, 1.0))


static func foot_local_y() -> float:
	return 0.0


static func mesh_for_lod(species: String, settings: Dictionary, tier: LodTier) -> ArrayMesh:
	var spec := spec_for_species(species, settings)
	match tier:
		LodTier.FAR:
			return _build_patch_mesh(spec)
		LodTier.MID:
			return _build_clump_mesh(spec, 3, 2, LOD_MID_SCALE)
		_:
			return _build_clump_mesh(spec, int(spec["blade_count"]), int(spec["segments"]), 1.0)


static func material_for_species(species: String, settings: Dictionary,
		tier: LodTier = LodTier.NEAR) -> ShaderMaterial:
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
	mat.set_shader_parameter("hue_jitter", float(settings.get("hue_jitter", 0.04)))
	mat.set_shader_parameter("drape_match_strength", float(settings.get("drape_match_strength", 0.35)))
	if tier == LodTier.MID:
		mat.set_shader_parameter("near_full_m", 55.0)
		mat.set_shader_parameter("mid_fade_m", 120.0)
		mat.set_shader_parameter("far_patch_m", 320.0)
	elif tier == LodTier.FAR:
		mat.set_shader_parameter("near_full_m", 0.0)
		mat.set_shader_parameter("mid_fade_m", 180.0)
		mat.set_shader_parameter("far_patch_m", 350.0)
		mat.set_shader_parameter("patch_strength", 1.0)
	if settings.has("drape_tex") and settings["drape_tex"] is Texture2D:
		mat.set_shader_parameter("drape_tex", settings["drape_tex"])
		mat.set_shader_parameter("use_drape", true)
		mat.set_shader_parameter("drape_extent_m", float(settings.get("drape_extent_m", 30000.0)))
	if settings.has("haze_color"):
		pass  # grass uses patch fade instead of haze
	return mat


static func visibility_range_for_tier(tier: LodTier) -> Vector2:
	match tier:
		LodTier.NEAR:
			return Vector2(0.0, 90.0)
		LodTier.MID:
			return Vector2(75.0, 220.0)
		LodTier.FAR:
			return Vector2(200.0, 380.0)
	return Vector2(0.0, 380.0)


static func _build_clump_mesh(spec: Dictionary, blade_count: int, segments: int,
		width_scale: float) -> ArrayMesh:
	var blade_w := float(spec["blade_w"]) * width_scale
	var blade_h := float(spec["blade_h"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for bi in blade_count:
		var yaw := float(bi) * TAU / float(blade_count)
		_add_blade(verts, uvs, normals, indices, blade_w, blade_h, yaw, segments)
	return _arrays_to_mesh(verts, uvs, normals, indices)


static func _build_patch_mesh(spec: Dictionary) -> ArrayMesh:
	var w := LOD_FAR_PATCH_W
	var h := LOD_FAR_PATCH_H
	var verts := PackedVector3Array([
		Vector3(-w * 0.5, 0.0, 0.0), Vector3(w * 0.5, 0.0, 0.0),
		Vector3(w * 0.5, h, 0.0), Vector3(-w * 0.5, h, 0.0),
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var normals := PackedVector3Array()
	for _i in 4:
		normals.append(Vector3(0.0, 1.0, 0.0))
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	return _arrays_to_mesh(verts, uvs, normals, indices)


static func _add_blade(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		blade_w: float, blade_h: float, yaw: float, segments: int) -> void:
	var dx := cos(yaw)
	var dz := sin(yaw)
	var perp := Vector3(-dz, 0.0, dx)
	var half_w := blade_w * 0.5
	var curve := blade_h * 0.12
	var base := verts.size()
	for si in segments + 1:
		var t := float(si) / float(segments)
		var y := t * blade_h
		var bend := sin(t * PI * 0.5) * curve
		var center := Vector3(dx * bend, y, dz * bend)
		var left := center + perp * half_w * (1.0 - t * 0.35)
		var right := center - perp * half_w * (1.0 - t * 0.35)
		verts.append(left)
		verts.append(right)
		var v := 1.0 - t
		uvs.append(Vector2(0.0, v))
		uvs.append(Vector2(1.0, v))
		var n := (perp + Vector3(0.0, 0.25, 0.0)).normalized()
		normals.append(n)
		normals.append(n)
	for si in segments:
		var row := base + si * 2
		var next := row + 2
		indices.append_array([row, row + 1, next + 1, row, next + 1, next])


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
