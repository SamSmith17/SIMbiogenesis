class_name VegetationRuntime
extends RefCounted

## Rebuilds MultiMesh bulk layers + hero tree instances under a terrain parent.

const VISIBILITY_BEGIN := 0.0
const VISIBILITY_END := 900.0
const GRASS_VISIBILITY_END := 380.0


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


static func _register_growth(map: VegetationInstanceMap, mmi: MultiMeshInstance3D,
		idx: int, record: Dictionary, species: String, base_scale: float,
		vert_off: float, foot_y: float, align_to_surface: bool,
		x: float, z: float, yaw: float, ground_y: float = NAN) -> void:
	if map != null:
		map.add(mmi, idx, record, species, base_scale, vert_off, foot_y,
			align_to_surface, x, z, yaw, ground_y)


static func _build_grass_bulk_batches(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, settings: Dictionary,
		growth_map: VegetationInstanceMap = null) -> void:
	var species_scale := GrassBuilder.bulk_scale(species, settings)
	var foot_y := GrassBuilder.foot_local_y()
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var grass_far := float(settings.get("grass_visibility_end_m",
		GrassBuilder.DEFAULT_FAR_VISIBILITY_M))
	for tier in [GrassBuilder.LodTier.NEAR, GrassBuilder.LodTier.MID, GrassBuilder.LodTier.FAR]:
		var mesh := GrassBuilder.mesh_for_lod(species, settings, tier)
		var mat := GrassBuilder.material_for_species(species, settings, tier)
		var vis := GrassBuilder.visibility_range_for_tier(tier, grass_far)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = records.size()
		var pending: Array = []
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
			var base_scale := scale
			if species != "grass_lawn":
				scale *= VegetationGrowth.instance_scale_mult(species, d, settings)
			var record_vert := float(d.get("vert_off", vert_off))
			var gy: float = float(ground_y_at.call(x, z))
			mm.set_instance_transform(i, VegetationPaint.build_transform(
				x, gy, z, yaw, scale, false, Vector3.UP, record_vert, foot_y))
			if growth_map != null:
				pending.append({
					"record": d, "base_scale": base_scale, "vert_off": record_vert,
					"x": x, "z": z, "yaw": yaw, "ground_y": gy,
				})
			i += 1
		mm.instance_count = i
		if i == 0:
			continue
		var mi := MultiMeshInstance3D.new()
		mi.name = "Bulk_%s_%s" % [species, tier]
		mi.multimesh = mm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_begin = vis.x
		mi.visibility_range_end = vis.y
		root.add_child(mi)
		if growth_map != null:
			for j in pending.size():
				var p: Dictionary = pending[j]
				_register_growth(growth_map, mi, j, p["record"], species,
					float(p["base_scale"]), float(p["vert_off"]), foot_y, false,
					float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
			if env != null and env.has_method("register_multimesh_instance"):
				env.register_multimesh_instance(mi, species)


static func _build_canopy_lod_bulk_batches(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, growth_map: VegetationInstanceMap = null) -> void:
	if not VegetationCardFactory.canopy_lod_enabled(species, settings):
		_build_canopy_single_batch(root, species, records, ground_y_at, align_to_surface,
			settings, visibility_end_m, VegetationCardFactory.CanopyLodTier.NEAR, growth_map)
		return
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	for tier in [VegetationCardFactory.CanopyLodTier.NEAR,
			VegetationCardFactory.CanopyLodTier.FAR]:
		var mesh := VegetationCardFactory.mesh_for_canopy_lod(species, settings, tier)
		var vis := VegetationCardFactory.canopy_visibility_range_for_tier(
			species, tier, settings, visibility_end_m)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = records.size()
		var pending: Array = []
		var i := 0
		for item in records:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var x := float(d.get("x", 0.0))
			var z := float(d.get("z", 0.0))
			var yaw := float(d.get("yaw", 0.0))
			var base_scale := float(d.get("scale", 1.0)) * species_scale
			var scale := base_scale * VegetationGrowth.instance_scale_mult(species, d, settings)
			var record_vert := float(d.get("vert_off", vert_off))
			var gy: float = float(ground_y_at.call(x, z))
			mm.set_instance_transform(i, VegetationPaint.build_transform(
				x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
			if growth_map != null:
				pending.append({
					"record": d, "base_scale": base_scale, "vert_off": record_vert,
					"x": x, "z": z, "yaw": yaw, "ground_y": gy,
				})
			i += 1
		mm.instance_count = i
		if i == 0:
			continue
		var mi := MultiMeshInstance3D.new()
		mi.name = "Bulk_%s_%d" % [species, tier]
		mi.multimesh = mm
		mi.material_override = null
		# Both tiers cast shadows so tree outlines read clearly for solar analysis.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.visibility_range_begin = vis.x
		mi.visibility_range_end = vis.y
		root.add_child(mi)
		if growth_map != null:
			for j in pending.size():
				var p: Dictionary = pending[j]
				_register_growth(growth_map, mi, j, p["record"], species,
					float(p["base_scale"]), float(p["vert_off"]), foot_y, align_to_surface,
					float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
			if env != null and env.has_method("register_multimesh_instance"):
				env.register_multimesh_instance(mi, species)


static func _build_canopy_single_batch(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, tier: VegetationCardFactory.CanopyLodTier,
		growth_map: VegetationInstanceMap = null) -> void:
	var mesh := VegetationCardFactory.mesh_for_canopy_lod(species, settings, tier)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = records.size()
	var pending: Array = []
	var i := 0
	for item in records:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var base_scale := float(d.get("scale", 1.0)) * species_scale
		var scale := base_scale * VegetationGrowth.instance_scale_mult(species, d, settings)
		var record_vert := float(d.get("vert_off", vert_off))
		var gy: float = float(ground_y_at.call(x, z))
		mm.set_instance_transform(i, VegetationPaint.build_transform(
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
		if growth_map != null:
			pending.append({
				"record": d, "base_scale": base_scale, "vert_off": record_vert,
				"x": x, "z": z, "yaw": yaw, "ground_y": gy,
			})
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "Bulk_%s" % species
	mi.multimesh = mm
	mi.material_override = null
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.visibility_range_begin = VISIBILITY_BEGIN
	mi.visibility_range_end = visibility_end_m
	root.add_child(mi)
	if growth_map != null:
		for j in pending.size():
			var p: Dictionary = pending[j]
			_register_growth(growth_map, mi, j, p["record"], species,
				float(p["base_scale"]), float(p["vert_off"]), foot_y, align_to_surface,
				float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var env := (tree as SceneTree).root.get_node_or_null("VegetationEnvironmentSync")
		if env != null and env.has_method("register_multimesh_instance"):
			env.register_multimesh_instance(mi, species)


static func _build_deciduous_bulk_batches(root: Node3D, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		visibility_end_m: float, growth_map: VegetationInstanceMap = null) -> void:
	_build_canopy_lod_bulk_batches(root, "deciduous", records, ground_y_at,
		align_to_surface, settings, visibility_end_m, growth_map)


static func rebuild(terrain: Node3D, layer: VegetationLayer,
		ground_y_at: Callable, align_to_surface: bool = false,
		settings: Dictionary = {}, growth_map: VegetationInstanceMap = null) -> void:
	if terrain == null or layer == null:
		return
	if growth_map != null:
		growth_map.clear()
	_clear_shader_registrations()
	var s := layer.get_settings()
	if not settings.is_empty():
		s = settings.duplicate(true)
	var root := ensure_root(terrain)
	_clear_children(root)
	for species in VegetationLayer.ALL_SPECIES:
		_build_bulk_layer(root, species, layer.bulk.get(species, []), ground_y_at,
			align_to_surface, s, growth_map)
	_build_hero_layer(root, layer.hero, ground_y_at, s)
	# _clear_shader_registrations() above wipes ALL registrations, including the
	# auto-vegetation layer's — which this rebuild doesn't touch. Without this,
	# any manual-layer rebuild that runs after auto-vegetation has already
	# registered (e.g. the load-sequence's deferred manual rebuild, which
	# intentionally runs after auto-scatter) permanently drops auto-scattered
	# trees/grass from seasonal + wind uniform updates.
	AutoVegetationRuntime.reregister_existing(terrain)


static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()


## Re-registers already-built manual-layer batches with VegetationEnvironmentSync
## + VegetationWindDriver, without rebuilding meshes. Mirrors
## AutoVegetationRuntime.reregister_existing() — see that function's comment
## for why this is needed (both rebuild paths clear ALL registrations).
static func reregister_existing(terrain: Node3D) -> void:
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
	var n := mi.name
	if not n.begins_with("Bulk_"):
		return ""
	var rest := n.substr(5)
	for gs in VegetationLayer.GRASS_SPECIES:
		if rest.begins_with(gs + "_"):
			return gs
	if rest.ends_with("_0") or rest.ends_with("_1"):
		var base := rest.substr(0, rest.length() - 2)
		if base in VegetationLayer.ALL_SPECIES:
			return base
	return rest


static func _visibility_end_for_species(species: String) -> float:
	if species in VegetationLayer.GRASS_SPECIES:
		return GRASS_VISIBILITY_END
	return VISIBILITY_END


static func _casts_shadow(species: String) -> int:
	if species in VegetationLayer.GRASS_SPECIES:
		return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON


static func _build_bulk_layer(root: Node3D, species: String, records: Array,
		ground_y_at: Callable, align_to_surface: bool, settings: Dictionary,
		growth_map: VegetationInstanceMap = null) -> void:
	if records.is_empty():
		return
	var batches := _partition_bulk_batches(records, settings)
	for batch in batches:
		_build_bulk_batch(root, species, batch["records"], ground_y_at, align_to_surface,
			batch["settings"], growth_map)


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
		growth_map: VegetationInstanceMap = null) -> void:
	if records.is_empty():
		return
	if species in VegetationLayer.GRASS_SPECIES:
		_build_grass_bulk_batches(root, species, records, ground_y_at, settings, growth_map)
		return
	if species == "deciduous" or species == "pine":
		_build_canopy_lod_bulk_batches(root, species, records, ground_y_at, align_to_surface,
			settings, _visibility_end_for_species(species), growth_map)
		return
	var mesh := VegetationCardFactory.mesh_for_species(species, settings)
	var use_surface := VegetationCardFactory.mesh_has_surface_materials(species)
	var mat: ShaderMaterial = null
	if not use_surface:
		mat = VegetationCardFactory.material_for_species(species, settings)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = records.size()
	var pending: Array = []
	var i := 0
	for item in records:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var base_scale := float(d.get("scale", 1.0)) * species_scale
		var scale := base_scale * VegetationGrowth.instance_scale_mult(species, d, settings)
		var record_vert := float(d.get("vert_off", vert_off))
		var gy: float = float(ground_y_at.call(x, z))
		mm.set_instance_transform(i, VegetationPaint.build_transform(
			x, gy, z, yaw, scale, align_to_surface, Vector3.UP, record_vert, foot_y))
		if growth_map != null:
			pending.append({
				"record": d, "base_scale": base_scale, "vert_off": record_vert,
				"x": x, "z": z, "yaw": yaw, "ground_y": gy,
			})
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "Bulk_%s" % species
	mi.multimesh = mm
	if use_surface:
		mi.material_override = null
	else:
		mi.material_override = mat
	mi.cast_shadow = _casts_shadow(species)
	mi.visibility_range_begin = VISIBILITY_BEGIN
	mi.visibility_range_end = _visibility_end_for_species(species)
	root.add_child(mi)
	if growth_map != null:
		for j in pending.size():
			var p: Dictionary = pending[j]
			_register_growth(growth_map, mi, j, p["record"], species,
				float(p["base_scale"]), float(p["vert_off"]), foot_y, align_to_surface,
				float(p["x"]), float(p["z"]), float(p["yaw"]), float(p["ground_y"]))
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


static func reground(terrain: Node3D, layer: VegetationLayer,
		ground_y_at: Callable) -> void:
	rebuild(terrain, layer, ground_y_at, false)
