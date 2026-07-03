extends Node

## Pushes day/night + seasonal (phenology + snow) uniforms to registered
## vegetation ShaderMaterials (~5 Hz). Materials register at MultiMesh rebuild
## time. Wind is handled separately by VegetationWindDriver.

const UPDATE_INTERVAL := 0.2
const FOLIAGE_SHADER := "res://vegetation/foliage.gdshader"
const LEAF_CANOPY_SHADER := "res://vegetation/leaf_canopy.gdshader"
const GRASS_SHADER := "res://vegetation/grass.gdshader"
const BARK_SHADER := "res://vegetation/bark.gdshader"

# Foliage materials (full seasonal response). Parallel arrays keep a per-material
# deciduousness so evergreens vs broadleaves react differently.
var _materials: Array[ShaderMaterial] = []
var _material_species: Dictionary = {}
var _material_deciduousness: Dictionary = {}
# Grass + bark get a lighter seasonal/snow response.
var _grass_materials: Array[ShaderMaterial] = []
var _bark_materials: Array[ShaderMaterial] = []

var _accum := 0.0
var _night_factor := 0.0
var _sun_direction := Vector3.UP
# Seasonal state (lerped toward targets so scrubbing/analemma doesn't pop).
var _autumn := 0.0
var _leaf_coverage := 1.0
var _bud := 0.0
var _winter := 0.0
var _summer := 1.0
var _snow := 0.0
var _grass_growth := 1.0
var _t_autumn := 0.0
var _t_leaf := 1.0
var _t_bud := 0.0
var _t_winter := 0.0
var _t_summer := 1.0
var _t_snow := 0.0
var _t_grass_growth := 1.0


func clear_registered_materials() -> void:
	_materials.clear()
	_material_species.clear()
	_material_deciduousness.clear()
	_grass_materials.clear()
	_bark_materials.clear()
	VegetationWindDriver.clear_registered_materials()


static func _deciduousness_for(species: String) -> float:
	var s := species.to_lower()
	if s.begins_with("pine") or s == "conifer" or s == "taiga" or s == "spruce" or s == "fir":
		return 0.0
	if s.begins_with("deciduous") or s == "broadleaf" or s == "palm" or s == "oak" or s == "maple":
		return 1.0
	if s.begins_with("shrub"):
		return 0.55
	if s.begins_with("grass"):
		return 0.0
	return 0.8


func register_material(mat: Material, species: String = "") -> void:
	if mat == null or not (mat is ShaderMaterial):
		return
	var sm := mat as ShaderMaterial
	if sm.shader == null:
		return
	VegetationWindDriver.register_material(mat)
	var path := sm.shader.resource_path
	if path == GRASS_SHADER:
		if not (sm in _grass_materials):
			_grass_materials.append(sm)
		return
	if path == BARK_SHADER:
		if not (sm in _bark_materials):
			_bark_materials.append(sm)
		return
	# leaf_canopy shares the full foliage seasonal uniform set (deciduousness,
	# autumn, leaf_coverage, spring_bud, winter, snow_amount, sun, night).
	if path != FOLIAGE_SHADER and path != LEAF_CANOPY_SHADER:
		return
	if sm in _materials:
		if not species.is_empty():
			_material_species[sm] = species
			_material_deciduousness[sm] = _deciduousness_for(species)
		return
	_materials.append(sm)
	if not species.is_empty():
		_material_species[sm] = species
		_material_deciduousness[sm] = _deciduousness_for(species)
	else:
		_material_deciduousness[sm] = 0.8


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
			_material_deciduousness.erase(sm)
			continue
		if str(_material_species.get(sm, "")) == species:
			sm.set_shader_parameter("albedo_tint", av)
			sm.set_shader_parameter("highlight_tint", hv)
		i += 1


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Smoothly approach seasonal targets every frame for pop-free transitions.
	var k := clampf(delta * 2.5, 0.0, 1.0)
	_autumn = lerpf(_autumn, _t_autumn, k)
	_leaf_coverage = lerpf(_leaf_coverage, _t_leaf, k)
	_bud = lerpf(_bud, _t_bud, k)
	_winter = lerpf(_winter, _t_winter, k)
	_summer = lerpf(_summer, _t_summer, k)
	_snow = lerpf(_snow, _t_snow, k)
	_grass_growth = lerpf(_grass_growth, _t_grass_growth, k)
	_accum += delta
	if _accum < UPDATE_INTERVAL:
		_push_uniforms()
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
	if main.has_method("get_season_signals"):
		var s: Dictionary = main.call("get_season_signals")
		_t_autumn = float(s.get("autumn", 0.0))
		_t_leaf = float(s.get("leaf_coverage", 1.0))
		_t_bud = float(s.get("bud", 0.0))
		_t_winter = float(s.get("winter", 0.0))
		_t_summer = float(s.get("summer", 1.0))
		_t_grass_growth = float(s.get("grass_growth", 1.0))
	if main.has_method("get_snow_amount"):
		_t_snow = clampf(float(main.call("get_snow_amount")), 0.0, 1.0)


func _push_uniforms() -> void:
	var sun := Vector3(_sun_direction.x, _sun_direction.y, _sun_direction.z)
	var i := 0
	while i < _materials.size():
		var sm := _materials[i]
		if not is_instance_valid(sm):
			_materials.remove_at(i)
			_material_species.erase(sm)
			_material_deciduousness.erase(sm)
			continue
		sm.set_shader_parameter("night_factor", _night_factor)
		sm.set_shader_parameter("sun_direction", sun)
		sm.set_shader_parameter("deciduousness", float(_material_deciduousness.get(sm, 0.8)))
		sm.set_shader_parameter("autumn", _autumn)
		sm.set_shader_parameter("leaf_coverage", _leaf_coverage)
		sm.set_shader_parameter("spring_bud", _bud)
		sm.set_shader_parameter("winter", _winter)
		sm.set_shader_parameter("snow_amount", _snow)
		i += 1

	i = 0
	while i < _grass_materials.size():
		var gm := _grass_materials[i]
		if not is_instance_valid(gm):
			_grass_materials.remove_at(i)
			continue
		gm.set_shader_parameter("night_factor", _night_factor)
		gm.set_shader_parameter("sun_direction", sun)
		gm.set_shader_parameter("autumn", _autumn)
		gm.set_shader_parameter("winter", _winter)
		gm.set_shader_parameter("snow_amount", _snow)
		gm.set_shader_parameter("growth", _grass_growth)
		i += 1

	i = 0
	while i < _bark_materials.size():
		var bm := _bark_materials[i]
		if not is_instance_valid(bm):
			_bark_materials.remove_at(i)
			continue
		bm.set_shader_parameter("snow_amount", _snow)
		i += 1
