class_name PlacedPropRuntime
extends RefCounted

## Builds PlacedProp nodes under Terrain/PlacedProps.


static func ensure_root(terrain: Node3D) -> Node3D:
	var root := terrain.get_node_or_null("PlacedProps") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "PlacedProps"
		terrain.add_child(root)
	return root


static func rebuild(terrain: Node3D, layer: PlacedPropLayer,
		ground_y_at: Callable) -> void:
	if terrain == null or layer == null:
		return
	var root := ensure_root(terrain)
	_clear_children(root)
	for item in layer.props:
		if not (item is Dictionary):
			continue
		var prop := _build_prop(item as Dictionary, ground_y_at)
		if prop != null:
			root.add_child(prop)


static func reground(terrain: Node3D, layer: PlacedPropLayer,
		ground_y_at: Callable) -> void:
	rebuild(terrain, layer, ground_y_at)


## Spawn a single prop node from one record without disturbing existing props.
## Used by the ghost-placement commit so confirming a placement doesn't free and
## rebuild every other prop in the scene.
static func add_one(terrain: Node3D, rec: Dictionary,
		ground_y_at: Callable) -> PlacedProp:
	if terrain == null or rec.is_empty():
		return null
	var root := ensure_root(terrain)
	var prop := _build_prop(rec, ground_y_at)
	if prop != null:
		root.add_child(prop)
	return prop


static func find_by_prop_id(main: Node, prop_id: String) -> PlacedProp:
	if main == null or prop_id.is_empty():
		return null
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return null
	var root := terrain.get_node_or_null("PlacedProps")
	if root == null:
		return null
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			return child as PlacedProp
	return null


static func _build_prop(rec: Dictionary, ground_y_at: Callable) -> PlacedProp:
	var model_id := str(rec.get("model_id", ""))
	if model_id.is_empty():
		return null
	# PACKED state (PACKING_PLAN.md Phase 5): render the honest packed form
	# instead of the deployed model. Non-packable records fall through and
	# deploy normally (the flag is meaningless for them).
	if bool(rec.get("packed", false)):
		# UNDER CONSTRUCTION (Site Projects): a packed linkage record whose
		# build project has started renders the ghost structure growing at the
		# build site instead of the crate. The record stays packed:true the
		# whole time — the erect phase's unpack effect is what deploys it.
		var bs: Variant = rec.get("build_state")
		if bs is Dictionary and not (bs as Dictionary).is_empty() \
				and rec.get("linkage_spec") is Dictionary:
			return _build_construction_prop(rec, bs as Dictionary, ground_y_at)
		var pspec := packed_spec_for_record(rec)
		if not pspec.is_empty():
			return _build_packed_prop(rec, pspec, ground_y_at)
	var extras: Dictionary = {}
	if rec.has("rack_spec"):
		extras["rack_spec"] = rec.get("rack_spec", {})
	if rec.has("linkage_spec"):
		extras["linkage_spec"] = rec.get("linkage_spec", {})
	if rec.has("box_spec"):
		extras["box_spec"] = rec.get("box_spec", {})
	if rec.has("tank_spec"):
		extras["tank_spec"] = rec.get("tank_spec", {})
	# Without this a placed container ALWAYS renders as the 20' default,
	# whatever its container_id says — and a stow plan solved against a 40'
	# interior would then put crates through the walls.
	if rec.has("container_spec"):
		extras["container_spec"] = rec.get("container_spec", {})
	if model_id == GrowBed.MODEL_ID:
		var bed_spec: Dictionary = {}
		if rec.has("grow_bed_spec"):
			bed_spec = (rec.get("grow_bed_spec", {}) as Dictionary).duplicate(true)
		if rec.has("plant_abs_h"):
			bed_spec["plant_abs_h"] = rec.get("plant_abs_h")
		if rec.has("grow_days"):
			bed_spec["grow_days"] = rec.get("grow_days")
		extras["grow_bed_spec"] = bed_spec
	if model_id == GeodesicDomeBuilder.MODEL_ID:
		var dome_spec: Dictionary = {}
		if rec.has("dome_spec"):
			dome_spec = (rec.get("dome_spec", {}) as Dictionary).duplicate(true)
		dome_spec["ghost_highlight"] = false
		if not dome_spec.has("radius_m"):
			dome_spec["radius_m"] = DomeParts.TARGET_RADIUS_M
		extras["dome_spec"] = dome_spec
	if model_id == MudBuildingStructureBuilder.MODEL_ID:
		var mud_spec: Dictionary = {}
		if rec.has("mud_spec"):
			mud_spec = (rec.get("mud_spec", {}) as Dictionary).duplicate(true)
		mud_spec["ghost_highlight"] = false
		extras["mud_spec"] = mud_spec
	var model := ModelCatalog.instantiate(model_id, extras)
	if model == null:
		return null
	if model is GrowBed:
		(model as GrowBed).configure_from_record(rec)
	var prop := PlacedProp.new()
	prop.name = "PlacedProp_%s" % str(rec.get("id", "unknown"))
	prop.prop_id = str(rec.get("id", ""))
	prop.model_id = model_id
	prop.is_osm_replacement = str(rec.get("type", "")) == "osm"
	prop.building_idx = int(rec.get("building_idx", -1))
	if ModelCatalog.is_starshade_model(model_id):
		prop.prompt = "Edit StarShade (Interact)"
	elif model_id == LinkageStructureBuilder.MODEL_ID:
		prop.prompt = "Deploy structure (Interact) / Edit (click)"
	elif model_id == PalletRackBuilder.MODEL_ID:
		prop.prompt = "Edit prop (click) / Move (drag)"
	elif model_id == GrowBed.MODEL_ID:
		prop.prompt = "Edit grow bed (click) / Move (drag)"
	elif model_id == MudBuildingStructureBuilder.MODEL_ID:
		prop.prompt = "Inspect mud building · Move (drag)"
	else:
		prop.prompt = "Edit prop (click) / Move (drag)"
	prop.add_child(model)
	model.name = "ModelRoot"
	_disable_embedded_physics(model)
	_apply_transform(prop, model, rec, ground_y_at)
	prop.setup_collision()
	# Size-scaled distance culling + shadow policy (Tier 2 perf). setup_collision
	# has populated the pick AABB, so its diagonal gives the prop's size class.
	# Use the LOCAL radius — the prop is not in the tree yet (no global_transform).
	prop.set_meta("shadow_mode", str(rec.get("shadow_mode", "")))
	PropRenderTuning.apply_to_prop(prop, prop.get_local_pick_radius())
	_maybe_attach_wind_spin(prop, rec)
	_maybe_attach_hawt_tracker(prop, rec)
	_maybe_attach_csp_tracker(prop, rec)
	_maybe_attach_heliostat_tracker(prop, rec)
	_maybe_attach_siphon_spin(prop, rec)
	_maybe_attach_cnc_runtime(prop, rec)
	_maybe_attach_pp_beam_extruder(prop, rec)
	_maybe_attach_pp_sheet_press(prop, rec)
	_maybe_attach_linkage_deploy(prop, rec)
	prop.set_burnable(bool(rec.get("burnable", false)))
	var prop_id := str(rec.get("id", ""))
	# Spawn ConnectionPort markers so ConduitManager can snap conduits to tagged plugs.
	var ports: Array = rec.get("connection_ports", []) as Array
	if ports.is_empty():
		var dims: Dictionary = {}
		if rec.has("box_spec"):
			dims = rec.get("box_spec", {}) as Dictionary
		elif rec.has("tank_spec"):
			dims = rec.get("tank_spec", {}) as Dictionary
		ports = ConnectionPortDefs.default_ports_for_model(model_id, dims)
		if ports.is_empty():
			ports = ConnectionPortDefs.load_catalog_ports(model_id)
	if not ports.is_empty():
		ConnectionPortDefs.sync_port_markers(prop, ports)
	if PlacedPropService.is_placement_active() and prop_id == PlacedPropService.placement_prop_id():
		prop.set_collision_enabled(false)
	elif not bool(rec.get("collision_enabled", true)):
		prop.set_collision_enabled(false)
	# "Hide from 3D world": conceptual/placeholder twins the player doesn't want
	# rendered. Hides the whole prop (mesh + ports) and drops collision, while the
	# record + bound graph node stay intact (unlike delete). The Site Plan disc
	# renders this same node, so it disappears there too — matched by the 2D ring
	# gate in graph_canvas (a hidden twin shows no ring).
	if bool(rec.get("hidden_3d", false)):
		prop.visible = false
		prop.set_collision_enabled(false)
	return prop


## Resolve a record's packed spec — same precedence as the edit drawer:
## live linkage design > container variant > model catalog entry.
static func packed_spec_for_record(rec: Dictionary) -> Dictionary:
	if rec.get("linkage_spec") is Dictionary:
		var p := LinkageParams.new()
		p.from_config(rec.get("linkage_spec") as Dictionary)
		var s := LinkageStructureBuilder.packed_spec_for(p)
		if not s.is_empty():
			return s
	if rec.get("container_spec") is Dictionary:
		var c := ContainerCatalog.packed_spec_for(
			str((rec.get("container_spec") as Dictionary).get("container_id", "")))
		if not c.is_empty():
			return c
	return PackedSpec.for_model(str(rec.get("model_id", "")))


## The PACKED build: a PackedFormBuilder crate at the record's spot. Yaw-only
## transform at USER scale (the crate is authored in real metres — the
## catalog's GLB unit-compensation scale must NOT apply), no behavior
## runtimes (trackers/spinners animate deployed geometry that doesn't
## exist), no connection ports (plugs live on the deployed model).
static func _build_packed_prop(rec: Dictionary, pspec: Dictionary,
		ground_y_at: Callable) -> PlacedProp:
	var model := PackedFormBuilder.build_node(pspec)
	var prop := PlacedProp.new()
	prop.name = "PlacedProp_%s" % str(rec.get("id", "unknown"))
	prop.prop_id = str(rec.get("id", ""))
	prop.model_id = str(rec.get("model_id", ""))
	prop.is_osm_replacement = str(rec.get("type", "")) == "osm"
	prop.building_idx = int(rec.get("building_idx", -1))
	prop.prompt = "Stowed — unload the delivery first" \
		if not str(rec.get("stowed_in", "")).is_empty() \
		else "Unpack (Interact) / Edit (click)"
	prop.add_child(model)
	model.name = "ModelRoot"
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	model.rotation = Vector3(0.0, deg_to_rad(float(rec.get("yaw", 0.0))), 0.0)
	model.scale = Vector3.ONE * float(rec.get("scale", 1.0))
	var gy: float = float(ground_y_at.call(x, z)) if ground_y_at.is_valid() \
		else float(rec.get("ground_y", 0.0))
	prop.position = Vector3(x, gy, z)
	if rec.has("y_offset"):
		prop.position.y += float(rec["y_offset"])
	prop.setup_collision()
	prop.set_meta("shadow_mode", str(rec.get("shadow_mode", "")))
	prop.set_meta("packed", true)
	PropRenderTuning.apply_to_prop(prop, prop.get_local_pick_radius())
	prop.set_burnable(bool(rec.get("burnable", false)))
	if not bool(rec.get("collision_enabled", true)):
		prop.set_collision_enabled(false)
	if bool(rec.get("hidden_3d", false)):
		prop.visible = false
		prop.set_collision_enabled(false)
	return prop


## The UNDER-CONSTRUCTION build (Site Projects): the ghost linkage structure
## at its STOWED fold, revealed element class by element class as the crew's
## real labour progresses. Coarse fractions come from the record's
## build_state (stamped by the set_build_phase chore effects, so a fresh
## load renders roughly right); NpcPopulationBridge refines them live each
## population tick. No deploy runtime (the raise IS the erect phase's unpack
## effect), no connection ports, no graph presence.
static func _build_construction_prop(rec: Dictionary, build_state: Dictionary,
		ground_y_at: Callable) -> PlacedProp:
	var params := LinkageParams.new()
	params.from_config(rec.get("linkage_spec") as Dictionary)
	params.fold_angle = maxf(LinkageKinematics.effective_min_fold_angle(params),
		LinkageKinematics.MIN_FOLD_ANGLE)
	var builder := LinkageStructureBuilder.new()
	builder.name = "ModelRoot"
	builder.collision_mesh_enabled = false   # walk-through while it grows
	builder.set_params(params)
	var fr := SiteProject.phase_fractions(str(build_state.get("phase", "")))
	builder.set_build_progress(fr)
	builder.set_ghost_alpha(clampf(float(build_state.get("ghost",
		float(fr.get("ghost", 0.2)))), 0.05, 1.0))
	# The kit crate stays standing beside the growing frame — early phases
	# (cut/drill) reveal no geometry at all, and a build site with nothing on
	# it reads as a bug, not as a work in progress. It vanishes with the whole
	# prop rebuild when the erect phase unpacks.
	var pspec := packed_spec_for_record(rec)
	if not pspec.is_empty():
		var crate := PackedFormBuilder.build_node(pspec)
		crate.name = "KitCrate"
		crate.position = Vector3(float(pspec.get("w_m", 1.0)) * 0.5 + 2.0, 0.0, 0.0)
		builder.add_child(crate)
	var prop := PlacedProp.new()
	prop.name = "PlacedProp_%s" % str(rec.get("id", "unknown"))
	prop.prop_id = str(rec.get("id", ""))
	prop.model_id = str(rec.get("model_id", ""))
	prop.prompt = "Under construction — see the crew's project"
	prop.add_child(builder)
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	builder.rotation = Vector3(0.0, deg_to_rad(float(rec.get("yaw", 0.0))), 0.0)
	var gy: float = float(ground_y_at.call(x, z)) if ground_y_at.is_valid() \
		else float(rec.get("ground_y", 0.0))
	prop.position = Vector3(x, gy, z)
	prop.setup_collision()
	prop.set_meta("shadow_mode", str(rec.get("shadow_mode", "")))
	prop.set_meta("packed", true)
	prop.set_meta("under_construction", true)
	PropRenderTuning.apply_to_prop(prop, prop.get_local_pick_radius())
	prop.set_collision_enabled(false)
	if bool(rec.get("hidden_3d", false)):
		prop.visible = false
	return prop


## Attach the live fold controller for a placed Linkage Lab structure.
## Keyed on model_id (not record kind) so every placement path — designer
## modal, library catalog, save reload — gets a foldable prop.
static func _maybe_attach_linkage_deploy(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != LinkageStructureBuilder.MODEL_ID:
		return
	var deploy := LinkageDeployRuntime.new()
	deploy.name = "LinkageDeployRuntime"
	deploy.configure(rec)
	prop.add_child(deploy)


## Attach the rotor-spin controller for a placed VAWT (record kind == "vawt").
static func _maybe_attach_wind_spin(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "vawt":
		return
	var specs: Dictionary = rec.get("wind_specs", {}) as Dictionary
	if specs.is_empty():
		return
	var spin := WindTurbineSpin.new()
	spin.name = "WindTurbineSpin"
	spin.configure(specs, str(rec.get("turbine_node", "")),
		str(rec.get("graph_item_id", "")))
	prop.add_child(spin)


## Attach propeller spin for a placed siphon hydroturbine.
static func _maybe_attach_siphon_spin(prop: PlacedProp, rec: Dictionary) -> void:
	var kind := str(rec.get("kind", ""))
	var model_id := str(rec.get("model_id", ""))
	if kind != "siphon_hydro" and kind != "siphon_hoverboard" \
			and model_id != "hydroturbine":
		return
	if prop.get_node_or_null("SiphonTurbineSpin") != null:
		return
	var spin := SiphonTurbineSpin.new()
	spin.name = "SiphonTurbineSpin"
	spin.configure(str(rec.get("graph_item_id", "")),
			str(rec.get("turbine_node",
				ModelCatalog.find("hydroturbine").get("turbine_node", ""))))
	prop.add_child(spin)


## Attach the dual-axis (yaw + blade spin) controller for a placed small HAWT
## (record kind == "hawt"). See hawt_tracker.gd for the yaw-to-wind-direction
## + blade-RPM-from-wind-speed physics.
static func _maybe_attach_hawt_tracker(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "hawt":
		return
	var specs: Dictionary = rec.get("wind_specs", {}) as Dictionary
	if specs.is_empty():
		return
	var tracker := HawtTracker.new()
	tracker.name = "HawtTracker"
	tracker.configure(specs, str(rec.get("hawt_yaw_node", "turbine vane assembly")),
		str(rec.get("hawt_blade_node", "Nosecone and Blades")),
		str(rec.get("graph_item_id", "")))
	prop.add_child(tracker)


## Attach the sun-tracking controller for a placed parabolic-trough CSP
## (record kind == "csp_trough"). Purely visual — the 2D graph node's live
## thermal/steam telemetry is computed centrally by
## SystemGraphView._tick_graph_csp so it stays correct even if this prop's
## script hasn't bound yet.
static func _maybe_attach_csp_tracker(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "csp_trough":
		return
	var specs: Dictionary = rec.get("csp_specs", {}) as Dictionary
	var tracker := CspTroughTracker.new()
	tracker.name = "CspTroughTracker"
	tracker.configure(specs, str(rec.get("csp_base_node", "Component#452")),
		str(rec.get("csp_concentrator_node", "Component#453")))
	prop.add_child(tracker)


## Attach the dual-axis sun-tracking controller for a placed dish heliostat
## (record kind == "heliostat"). Purely visual — the 2D graph node's live focal
## temperature / thermal / steam telemetry is computed centrally by
## SystemGraphView._tick_graph_heliostat. See gameplay/heliostat_tracker.gd.
static func _maybe_attach_heliostat_tracker(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "heliostat":
		return
	var specs: Dictionary = rec.get("helio_specs", {}) as Dictionary
	var tracker := HeliostatTracker.new()
	tracker.name = "HeliostatTracker"
	tracker.configure(specs,
		str(rec.get("helio_base_node", "fixed base")),
		str(rec.get("helio_azimuth_node", "horizontal rotating assembly")),
		str(rec.get("helio_altitude_node", "Vertical Rotating Assembly")),
		str(rec.get("helio_mirror_node", "Mirror array")),
		str(rec.get("helio_focal_node", "solar collector area")))
	prop.add_child(tracker)


## Attach the generalized Cartesian X/Y/Z motion driver for a placed CNC machine
## (record kind == "cartesian_machine"). Purely visual — the 2D graph node's
## live job progress / energy / material telemetry is computed centrally by
## SystemGraphView._tick_graph_tools, and this reads that progress back to trace
## the toolpath. See gameplay/cnc_machine_runtime.gd.
static func _maybe_attach_cnc_runtime(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "cartesian_machine":
		return
	var runtime := CncMachineRuntime.new()
	runtime.name = "CncMachineRuntime"
	runtime.configure(str(rec.get("model_id", "")),
		rec.get("machine_profile", {}) as Dictionary,
		str(rec.get("graph_item_id", "")))
	prop.add_child(runtime)


## Attach the grow/cut beam animation for a Precious Plastic beam extruder
## (record kind == "pp_beam_extruder"). Length comes from
## SystemGraphView._tick_graph_pp_extruder; see gameplay/pp_beam_extruder_runtime.gd.
static func _maybe_attach_pp_beam_extruder(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "pp_beam_extruder" \
			and str(rec.get("model_id", "")) != "pp_beam_extruder":
		return
	var runtime := PpBeamExtruderRuntime.new()
	runtime.name = "PpBeamExtruderRuntime"
	# Plastic stick only — mold (`beam#1`) must stay visible at rest.
	var names := PackedStringArray()
	names.append(str(rec.get("beam_mesh_name",
		ModelCatalog.find("pp_beam_extruder").get("beam_mesh_name", "Recycled Plastic Beam"))))
	runtime.configure(str(rec.get("graph_item_id", "")), names)
	prop.add_child(runtime)


## Attach Z-axis compression + sheet-reveal for a Precious Plastic sheet press.
static func _maybe_attach_pp_sheet_press(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "pp_sheet_press" \
			and str(rec.get("model_id", "")) != "pp_sheet_press":
		return
	var runtime := PpSheetPressRuntime.new()
	runtime.name = "PpSheetPressRuntime"
	var stroke := float(rec.get("z_stroke_m",
		ModelCatalog.find("pp_sheet_press").get("z_stroke_m", 0.12)))
	runtime.configure(str(rec.get("graph_item_id", "")), stroke)
	prop.add_child(runtime)


static func apply_record_to_prop(prop: PlacedProp, rec: Dictionary,
		ground_y_at: Callable) -> void:
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	if bool(rec.get("packed", false)):
		# A crate is authored in real metres, so it must be repositioned the
		# way _build_packed_prop places it — yaw only, USER scale, no catalog
		# unit-compensation or foot offset. Running the deployed path here
		# would rescale the crate by the model's GLB compensation factor.
		_apply_packed_transform(prop, model, rec, ground_y_at)
	else:
		_apply_transform(prop, model, rec, ground_y_at)
	prop.setup_collision()
	prop.set_burnable(bool(rec.get("burnable", false)))
	if not bool(rec.get("collision_enabled", true)):
		prop.set_collision_enabled(false)
	# Hide-from-3D toggle (see _build_prop) — live-apply so the inspector/edit-UI
	# checkbox takes effect without a full rebuild.
	var hide := bool(rec.get("hidden_3d", false))
	prop.visible = not hide
	if hide:
		prop.set_collision_enabled(false)


## Packed-crate placement, matching _build_packed_prop exactly (the two must
## never drift — one builds, the other moves).
static func _apply_packed_transform(prop: PlacedProp, model: Node3D,
		rec: Dictionary, ground_y_at: Callable) -> void:
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	model.rotation = Vector3(0.0, deg_to_rad(float(rec.get("yaw", 0.0))), 0.0)
	model.scale = Vector3.ONE * float(rec.get("scale", 1.0))
	var gy: float = float(ground_y_at.call(x, z)) if ground_y_at.is_valid() \
		else float(rec.get("ground_y", 0.0))
	prop.position = Vector3(x, gy, z)
	if rec.has("y_offset"):
		prop.position.y += float(rec["y_offset"])


static func _apply_transform(_prop: PlacedProp, model: Node3D, rec: Dictionary,
		ground_y_at: Callable) -> void:
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	var yaw := deg_to_rad(float(rec.get("yaw", 0.0)))
	var pitch := deg_to_rad(float(rec.get("pitch", 0.0)))
	var roll := deg_to_rad(float(rec.get("roll", 0.0)))
	var user_scale := float(rec.get("scale", 1.0))
	var world_scale := ModelCatalog.resolved_scale(str(rec.get("model_id", "")), user_scale)
	var foot_y := ModelCatalog.foot_local_y(str(rec.get("model_id", "")))
	# Prefer live footing so reload after DEM/mean-elev changes doesn't float.
	var gy: float
	if ground_y_at.is_valid():
		gy = float(ground_y_at.call(x, z))
	else:
		gy = float(rec.get("ground_y", 0.0))
	model.scale = Vector3.ONE * world_scale
	model.rotation = Vector3(pitch, yaw, roll)
	var grounded_y := gy - foot_y * world_scale
	_prop.position = Vector3(x, grounded_y, z)
	if rec.has("y_offset"):
		_prop.position.y += float(rec["y_offset"])
	elif rec.has("y") and not rec.has("ground_y"):
		# Legacy absolute y — only when no ground_y was ever recorded.
		_prop.position.y = float(rec["y"])


static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()


static func _disable_embedded_physics(model: Node3D) -> void:
	if model == null:
		return
	for node in model.find_children("*", "CollisionObject3D", true, false):
		if node is CollisionObject3D:
			var co := node as CollisionObject3D
			co.collision_layer = 0
			co.collision_mask = 0
