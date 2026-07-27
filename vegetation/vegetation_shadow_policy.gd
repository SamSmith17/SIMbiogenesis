class_name VegetationShadowPolicy
extends RefCounted

## Global gate for wide-area vegetation shadow casting.
##
## Trees/shrubs casting directional shadows across the whole SoI is a major GPU
## cost in normal play (each cascade re-rasterises every scattered instance), and
## it only actually matters for solar shadow analysis. So it is OFF by default and
## turned on only on demand. Grass never casts regardless.
##
## Every non-grass vegetation MultiMeshInstance is tagged into GROUP as it is
## built, so set_enabled() can flip already-scattered vegetation live — no costly
## regenerate. Builders call apply(); the solar-analysis path (or a settings
## toggle) calls set_enabled(on, get_tree()).

## Every non-grass canopy MMI joins this group (used for both the shadow gate and
## the live draw-distance cap below).
const GROUP := "veg_canopy"

static var _enabled: bool = false
## Live "hide all canopy" diagnostic state.
static var _canopy_hidden: bool = false


static func is_enabled() -> bool:
	return _enabled


## Show/hide ALL canopy (tree/shrub) MMIs live — a SAFE way to measure how much
## of the frame the trees actually cost. Grass is not in the group, so it stays.
## Uses .visible (a pure render skip, the safest per-instance op); deliberately
## does NOT touch visibility_range, which mass-mutated wedged the AMD Vulkan
## driver (hard crash). If trees dominate the GPU, this reveals it instantly.
static func set_canopy_hidden(hidden: bool, tree: SceneTree) -> void:
	_canopy_hidden = hidden
	if tree == null:
		return
	for n in tree.get_nodes_in_group(GROUP):
		var gi := n as GeometryInstance3D
		if gi != null:
			gi.visible = not hidden


static func is_canopy_hidden() -> bool:
	return _canopy_hidden


## Configure + tag a freshly built vegetation MMI. Grass is forced off and never
## tagged; trees/shrubs join GROUP and follow the current gate.
static func apply(mi: MultiMeshInstance3D, species: String) -> void:
	if mi == null:
		return
	if _is_grass(species):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return
	mi.add_to_group(GROUP)
	mi.cast_shadow = _mode()


## Toggle vegetation shadows and flip every already-built tree/shrub MMI live.
static func set_enabled(on: bool, tree: SceneTree) -> void:
	_enabled = on
	if tree == null:
		return
	var mode := _mode()
	for n in tree.get_nodes_in_group(GROUP):
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).cast_shadow = mode


static func _mode() -> int:
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _enabled \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _is_grass(species: String) -> bool:
	if species in VegetationLayer.GRASS_SPECIES:
		return true
	var fam := VegSpeciesCatalog.mesh_family(species)
	return fam in VegetationLayer.GRASS_SPECIES or fam.begins_with("grass_")
