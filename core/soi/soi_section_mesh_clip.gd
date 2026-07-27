class_name SoiSectionMeshClip
extends RefCounted

## Temporarily swaps MeshInstance3D materials for a CT-aware shader so placed
## props (hydroturbine, etc.) midplane-slice with the Elevation / Siphon Lab
## section cutaway. Restores originals on clear.

const _SHADER_PATH := "res://core/soi/shaders/soi_mesh_section_clip.gdshader"
const _META_KEY := "_soi_section_orig_mats"

static var _shader: Shader = null


static func apply_to_node(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	_ensure_shader()
	if _shader == null:
		return
	_walk_apply(root)


static func clear_from_node(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	_walk_clear(root)


static func _ensure_shader() -> void:
	if _shader != null:
		return
	_shader = load(_SHADER_PATH) as Shader


static func _walk_apply(n: Node) -> void:
	if n is MeshInstance3D:
		_apply_mesh(n as MeshInstance3D)
	for c in n.get_children():
		_walk_apply(c)


static func _walk_clear(n: Node) -> void:
	if n is MeshInstance3D:
		_clear_mesh(n as MeshInstance3D)
	for c in n.get_children():
		_walk_clear(c)


static func _apply_mesh(mi: MeshInstance3D) -> void:
	# has_meta — get_meta(key, null) still errors when the key is missing.
	if mi.has_meta(_META_KEY):
		return
	var mesh := mi.mesh
	if mesh == null:
		return
	var sc := mesh.get_surface_count()
	if sc <= 0:
		return
	var originals: Array = []
	originals.resize(sc)
	for i in range(sc):
		# Preserve whether an override existed so clear can restore null.
		var override := mi.get_surface_override_material(i)
		var mat: Material = override if override != null else mi.get_active_material(i)
		originals[i] = override
		mi.set_surface_override_material(i, _make_clip_mat(mat if mat != null else null))
	mi.set_meta(_META_KEY, originals)


static func _clear_mesh(mi: MeshInstance3D) -> void:
	if not mi.has_meta(_META_KEY):
		return
	var originals: Variant = mi.get_meta(_META_KEY)
	mi.remove_meta(_META_KEY)
	if originals is Array:
		var arr: Array = originals
		for i in range(arr.size()):
			mi.set_surface_override_material(i, arr[i] as Material)


static func _make_clip_mat(src: Material) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = _shader
	var albedo := Color(0.65, 0.67, 0.70, 1.0)
	var metallic := 0.25
	var roughness := 0.55
	var emission := Color(0, 0, 0, 1)
	var emission_e := 0.0
	var albedo_tex: Texture2D = null
	if src is StandardMaterial3D:
		var st := src as StandardMaterial3D
		albedo = st.albedo_color
		metallic = st.metallic
		roughness = st.roughness
		emission = st.emission
		emission_e = st.emission_energy_multiplier
		albedo_tex = st.albedo_texture
	elif src is ShaderMaterial:
		var shm := src as ShaderMaterial
		var ac: Variant = shm.get_shader_parameter("albedo_color")
		if ac is Color:
			albedo = ac
		var at: Variant = shm.get_shader_parameter("albedo_texture")
		if at is Texture2D:
			albedo_tex = at
	sm.set_shader_parameter("albedo_color", albedo)
	sm.set_shader_parameter("metallic", metallic)
	sm.set_shader_parameter("roughness", roughness)
	sm.set_shader_parameter("emission_color", emission)
	sm.set_shader_parameter("emission_energy", emission_e)
	if albedo_tex != null:
		sm.set_shader_parameter("albedo_texture", albedo_tex)
	return sm
