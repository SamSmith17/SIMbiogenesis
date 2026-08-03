extends Node

## Pushes day/night + seasonal (phenology + snow) uniforms to registered
## vegetation ShaderMaterials (~5 Hz). Materials register at MultiMesh rebuild
## time. Wind is handled separately by VegetationWindDriver.

const UPDATE_INTERVAL := 0.2
const FOLIAGE_SHADER := "res://vegetation/foliage.gdshader"
const LEAF_CANOPY_SHADER := "res://vegetation/leaf_canopy.gdshader"
const GRASS_SHADER := "res://vegetation/grass.gdshader"
const BARK_SHADER := "res://vegetation/bark.gdshader"
## Phase 3b impostors share the full foliage seasonal uniform set (the shader
## masks its own bark pixels internally).
const IMPOSTOR_SHADER := "res://vegetation/veg_impostor.gdshader"

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
var _snow_depth := 0.0
var _grass_growth := 1.0
var _t_autumn := 0.0
var _t_leaf := 1.0
var _t_bud := 0.0
var _t_winter := 0.0
var _t_summer := 1.0
var _t_snow := 0.0
var _t_snow_depth := 0.0
var _t_grass_growth := 1.0


func clear_registered_materials() -> void:
	_materials.clear()
	_material_species.clear()
	_material_deciduousness.clear()
	_grass_materials.clear()
	_bark_materials.clear()
	VegetationWindDriver.clear_registered_materials()


static func _deciduousness_for(species: String) -> float:
	# Phase 5: the species registry's phenology profile is authoritative —
	# this is what makes tropical evergreens ACTUALLY evergreen (a palm used
	# to carry deciduousness 1.0 and dropped its fronds every winter).
	var reg := VegSpeciesRegistry.deciduousness(species)
	if reg >= 0.0:
		return reg
	var s := species.to_lower()
	if s.begins_with("pine") or s == "conifer" or s == "taiga" or s == "spruce" or s == "fir":
		return 0.0
	if s.begins_with("deciduous") or s == "broadleaf" or s == "oak" or s == "maple":
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
			_force_push = true
		return
	if path == BARK_SHADER:
		if not (sm in _bark_materials):
			_bark_materials.append(sm)
			_force_push = true
		return
	# leaf_canopy + the Phase 3b impostor share the full foliage seasonal
	# uniform set (deciduousness, autumn, leaf_coverage, spring_bud, winter,
	# snow_amount, sun, night).
	if path != FOLIAGE_SHADER and path != LEAF_CANOPY_SHADER and path != IMPOSTOR_SHADER:
		return
	if sm in _materials:
		if not species.is_empty():
			_material_species[sm] = species
			_material_deciduousness[sm] = _deciduousness_for(species)
		return
	_materials.append(sm)
	# A material registered mid-session has never been written to, so the next
	# frame must push even if the season has settled and nothing changed —
	# otherwise a tree scattered at runtime renders with default uniforms until
	# the weather next moves.
	_force_push = true
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
	var snap_season := false
	var tree := get_tree()
	if tree != null:
		var main: Node = tree.get_first_node_in_group("main_scene")
		if main != null and main.has_method("has_climelapse_season_override"):
			snap_season = bool(main.call("has_climelapse_season_override"))
	var k := clampf(delta * 2.5, 0.0, 1.0)
	if snap_season:
		_autumn = _t_autumn
		_leaf_coverage = _t_leaf
		_bud = _t_bud
		_winter = _t_winter
		_summer = _t_summer
		_snow = _t_snow
		_snow_depth = _t_snow_depth
		_grass_growth = _t_grass_growth
	else:
		_autumn = lerpf(_autumn, _t_autumn, k)
		_leaf_coverage = lerpf(_leaf_coverage, _t_leaf, k)
		_bud = lerpf(_bud, _t_bud, k)
		_winter = lerpf(_winter, _t_winter, k)
		_summer = lerpf(_summer, _t_summer, k)
		_snow = lerpf(_snow, _t_snow, k)
		_snow_depth = lerpf(_snow_depth, _t_snow_depth, k)
		_grass_growth = lerpf(_grass_growth, _t_grass_growth, k)
	_accum += delta
	var due := _accum >= UPDATE_INTERVAL
	if due:
		_accum = 0.0
		_poll_main()
		# The freed-material sweep is deliberately kept on THIS branch rather
		# than inside _push_uniforms(): the push is now skipped on most frames,
		# and a sweep that only ran when the push ran would stop reaping freed
		# materials as soon as the season settled — a slow leak.
		_sweep_freed()
	# _push_uniforms() used to run EVERY frame on both branches, issuing ~10
	# set_shader_parameter() calls per foliage material, ~8 per grass material
	# and 2 per bark material — thousands of RenderingServer calls per frame for
	# values that had stopped moving. The lerp above is asymptotic and never
	# lands exactly on its target, so "did it change?" has to be an epsilon
	# test, not equality. It is self-tuning: at ordinary speed the season
	# converges within a second and the push stops; at a high time scale the
	# targets keep moving and it pushes every frame, which is correct.
	if due or _uniforms_dirty():
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
	if main.has_method("get_snow_depth_m"):
		_t_snow_depth = clampf(float(main.call("get_snow_depth_m")), 0.0, SeasonModel.SNOW_DEPTH_MAX_M)


## Values last written to the shaders, so a frame that changed nothing can skip
## the whole push. Seeded to NAN so the first frame always pushes.
var _pushed: Dictionary = {}
## Below this, a change is invisible on screen — every one of these uniforms is
## a 0..1 season blend or a normalised direction.
const UNIFORM_EPS := 1.0e-4
## Set when a material is registered mid-session: it has never been written to,
## so it needs one push regardless of whether the season moved.
var _force_push := true


func _uniforms_dirty() -> bool:
	if _force_push:
		_force_push = false
		return true
	if _pushed.is_empty():
		return true
	if absf(float(_pushed.get("night", 1e9)) - _night_factor) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("autumn", 1e9)) - _autumn) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("leaf", 1e9)) - _leaf_coverage) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("bud", 1e9)) - _bud) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("winter", 1e9)) - _winter) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("summer", 1e9)) - _summer) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("snow", 1e9)) - _snow) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("depth", 1e9)) - _snow_depth) > UNIFORM_EPS: return true
	if absf(float(_pushed.get("growth", 1e9)) - _grass_growth) > UNIFORM_EPS: return true
	# The sun sweeps continuously, so this is usually what keeps the push alive
	# during the day — and correctly so, since the foliage lighting follows it.
	var last_sun: Vector3 = _pushed.get("sun", Vector3(1e9, 0.0, 0.0))
	return last_sun.distance_squared_to(_sun_direction) > UNIFORM_EPS * UNIFORM_EPS


## Reap materials whose owning mesh has been freed. Split out of _push_uniforms
## so it keeps running on the 0.2 s cadence even when the push is skipped.
func _sweep_freed() -> void:
	var i := 0
	while i < _materials.size():
		var sm := _materials[i]
		if not is_instance_valid(sm):
			_materials.remove_at(i)
			_material_species.erase(sm)
			_material_deciduousness.erase(sm)
			continue
		i += 1
	i = 0
	while i < _grass_materials.size():
		if not is_instance_valid(_grass_materials[i]):
			_grass_materials.remove_at(i)
			continue
		i += 1
	i = 0
	while i < _bark_materials.size():
		if not is_instance_valid(_bark_materials[i]):
			_bark_materials.remove_at(i)
			continue
		i += 1


func _push_uniforms() -> void:
	var sun := Vector3(_sun_direction.x, _sun_direction.y, _sun_direction.z)
	_pushed = {
		"night": _night_factor, "autumn": _autumn, "leaf": _leaf_coverage,
		"bud": _bud, "winter": _winter, "summer": _summer, "snow": _snow,
		"depth": _snow_depth, "growth": _grass_growth, "sun": _sun_direction,
	}
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
		sm.set_shader_parameter("snow_depth_m", _snow_depth)
		sm.set_shader_parameter("summer", _summer)
		i += 1

	i = 0
	while i < _grass_materials.size():
		var gm := _grass_materials[i]
		if not is_instance_valid(gm):
			_grass_materials.remove_at(i)
			continue
		gm.set_shader_parameter("night_factor", _night_factor)
		gm.set_shader_parameter("sun_direction", sun)
		gm.set_shader_parameter("summer", _summer)
		gm.set_shader_parameter("autumn", _autumn)
		gm.set_shader_parameter("winter", _winter)
		gm.set_shader_parameter("snow_amount", _snow)
		gm.set_shader_parameter("snow_depth_m", _snow_depth)
		gm.set_shader_parameter("growth", _grass_growth)
		i += 1

	i = 0
	while i < _bark_materials.size():
		var bm := _bark_materials[i]
		if not is_instance_valid(bm):
			_bark_materials.remove_at(i)
			continue
		bm.set_shader_parameter("snow_amount", _snow)
		bm.set_shader_parameter("snow_depth_m", _snow_depth)
		# Bark darkens with the canopy at dusk (it received no night uniform
		# before — lit trunks poked out of near-black foliage).
		bm.set_shader_parameter("night_factor", _night_factor)
		i += 1
