extends SceneTree

## Offline: which Tune-look sliders actually change what a species renders?
## For every species page and every shape + shader slider, builds the NEAR mesh
## through the same call the preview makes, at the slider's min and max, and
## compares a signature of the geometry + every material uniform. A slider
## whose min and max build the same tree is DEAD for that species.
## Godot --headless --path . --script tools/checks/tune_look_slider_probe.gd

const EDITOR := "res://scenes/ui/vegetation_preview_editor.gd"
const SPECIES := {"pine": ["douglas_fir", "pine"], "deciduous": ["maple", "deciduous"],
	"shrub": ["salal", "shrub"]}


func _initialize() -> void:
	var ed: Script = load(EDITOR)
	var shape: Dictionary = ed.get_script_constant_map()["SPECIES_SHAPE_SLIDERS"]
	var shader: Array = ed.get_script_constant_map()["SHADER_SLIDERS"]
	var base := VegetationStyleConfig.defaults()
	var dead_total := 0
	for fam in SPECIES:
		var keys: Array = []
		for s in shape.get(fam, []):
			keys.append(s)
		for s in shader:
			keys.append(s)
		for sid in SPECIES[fam]:
			var dead: Array = []
			for spec in keys:
				var k := str(spec["key"])
				if k.begins_with("auto_") or k.begins_with("tree_"):
					continue  # map-level LOD / scatter knobs, not the tree
				if k.ends_with("_growth_years"):
					continue  # changes the age curve in the world, not the grown tree
				if k in ed.call("builder_hidden_keys", fam, base):
					continue  # not shown for the current builder
				if fam == "shrub" and k.begins_with("bark_"):
					continue  # shrubs have no bark surface
				var lo := base.duplicate()
				lo[k] = float(spec["min"])
				var hi := base.duplicate()
				hi[k] = float(spec["max"])
				# A family key edited on the family page is a user family edit.
				lo[VegStyleStore.KEY_USER_FAMILY] = [k]
				hi[VegStyleStore.KEY_USER_FAMILY] = [k]
				if _sig(sid, lo) == _sig(sid, hi):
					dead.append(k)
			dead_total += dead.size()
			print("slider_probe %-12s dead (%d): %s" % [sid, dead.size(), ", ".join(dead)])
	print("slider_probe: %d dead slider/species pairs" % dead_total)
	quit()


func _sig(sid: String, s: Dictionary) -> int:
	VegAssetCache.clear()
	var fam := VegSpeciesCatalog.mesh_family(sid)
	var m: Mesh
	if fam == "pine" or fam == "deciduous":
		m = VegetationCardFactory.mesh_for_canopy_lod(sid, s, VegetationCardFactory.CanopyLodTier.NEAR)
	else:
		m = VegetationCardFactory.mesh_for_species(sid, s)
	var parts: Array = []
	for si in m.get_surface_count():
		var arr := m.surface_get_arrays(si)
		parts.append(hash(arr[Mesh.ARRAY_VERTEX]))
		var mat := m.surface_get_material(si) as ShaderMaterial
		if mat == null:
			mat = VegetationCardFactory.material_for_species(sid, s)
		if mat != null:
			for u in mat.shader.get_shader_uniform_list():
				var v: Variant = mat.get_shader_parameter(str(u["name"]))
				if not (v is Object):
					parts.append(str(v))
	parts.append(VegetationCardFactory.species_bulk_scale(sid, s))
	parts.append(VegetationLayer.vertical_offset_for(fam, VegSpeciesCatalog.settings_with_variant(
		sid, s, VegetationCardFactory.SPECS)))
	return hash(parts)
