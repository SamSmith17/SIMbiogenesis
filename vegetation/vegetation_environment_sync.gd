extends Node

## Pushes day/night uniforms to registered vegetation ShaderMaterials (~5 Hz).
## Materials register at MultiMesh / forest canopy rebuild time.

const UPDATE_INTERVAL := 0.2
const FOLIAGE_SHADER := "res://vegetation/foliage.gdshader"

var _materials: Array[ShaderMaterial] = []
var _material_species: Dictionary = {}
var _accum := 0.0
var _night_factor := 0.0
var _sun_direction := Vector3.UP


func clear_registered_materials() -> void:
	_materials.clear()
	_material_species.clear()
	VegetationWindDriver.clear_registered_materials()


func register_material(mat: Material, species: String = "") -> void:
	if mat == null or not (mat is ShaderMaterial):
		return
	var sm := mat as ShaderMaterial
	if sm.shader == null:
		return
	VegetationWindDriver.register_material(mat)
	var path := sm.shader.resource_path
	if path != FOLIAGE_SHADER:
		return
	if sm in _materials:
		if not species.is_empty():
			_material_species[sm] = species
		return
	_materials.append(sm)
	if not species.is_empty():
		_material_species[sm] = species


func register_mesh(mesh: Mesh, species: String = "") -> void:
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		register_material(mesh.surface_get_material(i), species)


func register_multimesh_instance(mi: MultiMeshInstance3D, species: String = "") -> void:
	if mi == null:
		return
	var resolved := species
	if resolved.is_empty() and mi.name.begins_with("Bulk_"):
		resolved = mi.name.substr(5)
	register_material(mi.material_override, resolved)
	if mi.multimesh != null:
		register_mesh(mi.multimesh.mesh, resolved)


func register_mesh_instance(mi: MeshInstance3D, species: String = "") -> void:
	if mi == null:
		return
	register_material(mi.material_override, species)
	if mi.mesh != null:
		register_mesh(mi.mesh, species)


func apply_species_tints(species: String, albedo: Color, highlight: Color) -> void:
	var av := Vector3(albedo.r, albedo.g, albedo.b)
	var hv := Vector3(highlight.r, highlight.g, highlight.b)
	var i := 0
	while i < _materials.size():
		var sm := _materials[i]
		if not is_instance_valid(sm):
			_materials.remove_at(i)
			_material_species.erase(sm)
			continue
		if str(_material_species.get(sm, "")) == species:
			sm.set_shader_parameter("albedo_tint", av)
			sm.set_shader_parameter("highlight_tint", hv)
		i += 1


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_accum += delta
	if _accum < UPDATE_INTERVAL:
		return
	_accum = 0.0
	_poll_main()
	_push_uniforms()


func _poll_main() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		return
	if main.has_method("get_vegetation_night_factor"):
		_night_factor = float(main.call("get_vegetation_night_factor"))
	if main.has_method("get_vegetation_sun_direction"):
		var dir: Variant = main.call("get_vegetation_sun_direction")
		if dir is Vector3 and (dir as Vector3).length_squared() > 1e-6:
			_sun_direction = (dir as Vector3).normalized()


func _push_uniforms() -> void:
	var sun := Vector3(_sun_direction.x, _sun_direction.y, _sun_direction.z)
	var i := 0
	while i < _materials.size():
		var sm := _materials[i]
		if not is_instance_valid(sm):
			_materials.remove_at(i)
			_material_species.erase(sm)
			continue
		sm.set_shader_parameter("night_factor", _night_factor)
		sm.set_shader_parameter("sun_direction", sun)
		i += 1
