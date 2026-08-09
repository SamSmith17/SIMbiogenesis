class_name PlacedPropService
extends RefCounted

## Place imported / user GLB props on any map (TerrainLoader or baked terrain).

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
const PLACEMENT_RAY_LEN := 800.0

const GHOST_VALID_COLOR := Color(0.25, 1.0, 0.45, 0.45)
const GHOST_INVALID_COLOR := Color(1.0, 0.3, 0.2, 0.45)

static var _scene_layers: Dictionary = {}
static var _placement_active := false
static var _placement_prop_id := ""
static var _placement_main: Node = null
static var _placement_prep: Dictionary = {}

# Ghost preview state (transient, never persisted, never collides).
static var _ghost_node: Node3D = null
static var _ghost_model_id := ""
static var _ghost_valid := false
static var _ghost_ground_y := 0.0


static func is_placement_active() -> bool:
	# Self-heal stale cross-scene state. Placement lives in static vars that survive
	# change_scene_to_file, so importing a bundle and then loading a save / switching
	# maps without confirming would leave _placement_active = true pointing at a freed
	# scene. A freshly loaded Player must never inherit that phantom "placing" state —
	# it would otherwise suppress its normal physics grounding and drop it through the
	# world. If the owning scene is gone, the placement is not real: clear it.
	if _placement_active and not is_instance_valid(_placement_main):
		_clear_placement()
	return _placement_active


static func placement_prop_id() -> String:
	return _placement_prop_id


static func place_model(main: Node, model_id: String, near_player: bool = true,
		offset_xz: Vector2 = Vector2.ZERO) -> Dictionary:
	if main == null or model_id.is_empty():
		return {"ok": false, "error": "Missing main or model_id"}
	var xz := TerrainSurfaceQuery.placement_xz(main, near_player, offset_xz)
	var gy := TerrainSurfaceQuery.ground_height_at(main, xz.x, xz.y)
	var layer := _layer_for_main(main)
	if layer == null:
		return {"ok": false, "error": "Could not resolve placed-prop layer"}
	var prop_id := layer.add_free_prop(model_id, xz.x, NAN, xz.y, 0.0, 0.0, 0.0, 1.0, gy)
	if prop_id.is_empty():
		return {"ok": false, "error": "Failed to add prop record"}
	_save_layer(main, layer)
	_rebuild_scene_props(main, layer)
	if ModelCatalog.is_starshade_model(model_id):
		_trigger_starshade_graph_seed(main, {}, prop_id)
	return {"ok": true, "prop_id": prop_id, "x": xz.x, "z": xz.y, "ground_y": gy}


static func place_model_at_hit(main: Node, model_id: String, hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {"ok": false, "error": "No terrain hit"}
	var pos: Vector3 = hit["position"] as Vector3
	return place_model(main, model_id, false, Vector2(pos.x, pos.z))


## Place a model at an absolute world XZ (grounds Y via TerrainSurfaceQuery).
## Optionally stamps graph_item_id / bound link extras onto the record.
static func place_model_at_xz(main: Node, model_id: String, x: float, z: float,
		extra: Dictionary = {}) -> Dictionary:
	if main == null or model_id.is_empty():
		return {"ok": false, "error": "Missing main or model_id"}
	var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
	var layer := _layer_for_main(main)
	if layer == null:
		return {"ok": false, "error": "Could not resolve placed-prop layer"}
	var prop_id := layer.add_free_prop(model_id, x, NAN, z, 0.0, 0.0, 0.0, 1.0, gy)
	if prop_id.is_empty():
		return {"ok": false, "error": "Failed to add prop record"}
	if not extra.is_empty():
		layer.update_prop(prop_id, extra.duplicate(true))
	_save_layer(main, layer)
	_rebuild_scene_props(main, layer)
	if ModelCatalog.is_starshade_model(model_id):
		_trigger_starshade_graph_seed(main, {}, prop_id)
	elif model_id == BedBuilder.MODEL_ID:
		_auto_tag_bed_space(main, prop_id)
	_notify_mp_props_edited()
	return {"ok": true, "prop_id": prop_id, "x": x, "z": z, "ground_y": gy}


## Read one prop record (works on loader AND baked maps, unlike the
## TerrainLoader-only get_prop_record path).
static func get_prop_record(main: Node, prop_id: String) -> Dictionary:
	if main == null or prop_id.is_empty():
		return {}
	var layer := _layer_for_main(main)
	if layer == null:
		return {}
	return layer.find_by_id(prop_id)


## Patch one prop record and persist. rebuild_prop=true respawns just that
## prop node from the patched record (deep edits like a linkage_spec swap);
## false persists only (cheap state like a fold angle — the live node already
## shows it).
static func update_prop_record(main: Node, prop_id: String, patch: Dictionary,
		rebuild_prop: bool = false) -> bool:
	if main == null or prop_id.is_empty() or patch.is_empty():
		return false
	var layer := _layer_for_main(main)
	if layer == null:
		return false
	if not layer.update_prop(prop_id, patch.duplicate(true)):
		return false
	_save_layer(main, layer)
	if rebuild_prop:
		var parent := _props_parent(main)
		var root := parent.get_node_or_null("PlacedProps")
		if root != null:
			for child in root.get_children():
				if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
					child.free()
					break
		var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
		PlacedPropRuntime.add_one(parent, layer.find_by_id(prop_id), gy_fn)
	_notify_mp_props_edited()
	return true


## Move an existing prop to a new world XZ and reground.
static func move_prop_xz(main: Node, prop_id: String, x: float, z: float) -> bool:
	return move_prop_at(main, prop_id, x, z, NAN)


## Move prop to world XZ; when `ground_y` is finite, pin that footing (Elevation
## CT drag) instead of resampling terrain under the new XZ. A finite
## `y_offset` also rewrites the record's stack height — a crate hauled out of a
## container stack MUST be put back down on the ground, or it arrives floating
## at the height it rode at, which no XZ-based check would ever catch.
static func move_prop_at(main: Node, prop_id: String, x: float, z: float,
		ground_y: float = NAN, y_offset: float = NAN) -> bool:
	if main == null or prop_id.is_empty():
		return false
	var layer := _layer_for_main(main)
	if layer == null:
		return false
	var gy := ground_y
	if is_nan(gy):
		gy = TerrainSurfaceQuery.ground_height_at(main, x, z)
	# Moving a crate is exactly what un-stows it, whoever moved it — a chore
	# effect or the player dragging it out. One unconditional key covers both.
	var patch := {"x": x, "z": z, "ground_y": gy, "stowed_in": null}
	if not is_nan(y_offset):
		patch["y_offset"] = y_offset
	if not layer.update_prop(prop_id, patch):
		return false
	_save_layer(main, layer)
	_reposition_scene_prop(main, layer, prop_id)
	_notify_graph_prop_moved(main, prop_id)
	_notify_mp_props_edited()
	return true


static func begin_bundle_placement(main: Node, prep: Dictionary,
		near_player: bool = true) -> Dictionary:
	if main == null or not bool(prep.get("ok", false)):
		return prep if prep.has("ok") else {"ok": false, "error": "Invalid prep"}
	var model_id := str(prep.get("model_id", ""))
	var r := begin_placement(main, model_id, prep)
	r["model_id"] = model_id
	r["ibc_attached"] = false
	return r


## Start an interactive ghost-preview placement. A translucent, NON-colliding,
## NON-persisted copy of the model follows the crosshair every frame; nothing is
## written to the layer and the player is never moved. confirm_placement() commits
## the real prop at the ghost's resting spot; cancel_placement() just discards it.
static func begin_placement(main: Node, model_id: String, prep: Dictionary = {}) -> Dictionary:
	if main == null or model_id.is_empty():
		return {"ok": false, "error": "Missing main or model_id"}
	# Tear down any prior placement (e.g. re-entering before confirming).
	_clear_placement()
	# Owning scene set BEFORE the active flag (see is_placement_active guard).
	_placement_main = main
	_placement_active = true
	_placement_prep = prep.duplicate(true)
	_placement_prop_id = ""
	_ghost_model_id = model_id
	_ghost_valid = false
	var ghost := _build_ghost(main, model_id)
	if ghost == null:
		_clear_placement()
		return {"ok": false, "error": "Could not build placement ghost"}
	_ghost_node = ghost
	# Seed the ghost at the current crosshair aim so it appears immediately.
	var cam := _player_camera(main)
	if cam != null:
		update_placement_aim(main, cam)
	return {
		"ok": true,
		"placed": true,
		"placement_active": true,
		"prop_id": "",
		"model_id": model_id,
	}


static func placement_is_valid() -> bool:
	return _placement_active and _ghost_valid


static func update_placement_aim(main: Node, camera: Camera3D) -> void:
	if not _placement_active or main == null or camera == null:
		return
	if not is_instance_valid(_ghost_node):
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, camera)
	if hit.is_empty():
		# No terrain under the crosshair — hide the ghost as clear "can't place" feedback.
		_ghost_valid = false
		_ghost_node.visible = false
		return
	var pos: Vector3 = hit["position"] as Vector3
	# Single source of truth for footing (Phase 4): rest the ghost foot on the
	# ray-hit Y directly — no second ground_height_at query that could disagree.
	var foot_y := ModelCatalog.foot_local_y(_ghost_model_id)
	var ws := ModelCatalog.resolved_scale(_ghost_model_id, 1.0)
	_ghost_node.global_position = Vector3(pos.x, pos.y - foot_y * ws, pos.z)
	_ghost_ground_y = pos.y
	_ghost_valid = true
	_ghost_node.visible = true
	_set_ghost_tint(true)


static func confirm_placement() -> bool:
	if not _placement_active or not is_instance_valid(_placement_main):
		_clear_placement()
		return false
	# Invalid aim (no terrain under crosshair): don't place — let the user keep aiming.
	if not _ghost_valid or not is_instance_valid(_ghost_node):
		return false
	var main := _placement_main
	var model_id := _ghost_model_id
	var gpos := _ghost_node.global_position
	var layer := _layer_for_main(main)
	if layer == null:
		_clear_placement()
		return false
	# Commit exactly one record at the ghost's resting spot, grounded on the ray-hit
	# Y, then spawn just that one real (colliding) prop — no full scene rebuild.
	var prop_id := layer.add_free_prop(model_id, gpos.x, NAN, gpos.z, 0.0, 0.0, 0.0, 1.0, _ghost_ground_y)
	if prop_id.is_empty():
		_clear_placement()
		return false
	_placement_prop_id = prop_id
	# Merge any placement-time record extras (e.g. VAWT spin binding: kind /
	# turbine_node / wind_specs) BEFORE the prop node is built so the runtime can
	# attach the spin controller as it spawns.
	var record_extra := _placement_prep.get("record_extra", {}) as Dictionary
	if not record_extra.is_empty():
		layer.update_prop(prop_id, record_extra.duplicate(true))
	# Create + bind the 2D graph node for a linked generator (VAWT), stamping the
	# resulting item id back onto the record so save/reload keeps the link.
	var graph_link := _placement_prep.get("graph_link", {}) as Dictionary
	if not graph_link.is_empty():
		# Stamp XY footprint onto the graph specs from mesh metrics × scale.
		var gl_specs: Dictionary = (graph_link.get("specs", {}) as Dictionary).duplicate(true)
		var fp := footprint_from_model(model_id, 1.0)
		if fp.x > 0.0 and fp.y > 0.0:
			gl_specs["footprint_w_m"] = fp.x
			gl_specs["footprint_d_m"] = fp.y
			gl_specs["model_id"] = model_id
			graph_link = graph_link.duplicate(true)
			graph_link["specs"] = gl_specs
		var node_id := _create_bound_graph_node(main, prop_id, graph_link)
		if not node_id.is_empty():
			layer.update_prop(prop_id, {"graph_item_id": node_id})
	_save_layer(main, layer)
	var rec := layer.find_by_id(prop_id)
	var parent := _props_parent(main)
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	var ibc := _placement_prep.get("ibc", {}) as Dictionary
	var seed_prep := _placement_prep.duplicate(true)
	# Clear the placement state BEFORE spawning the real node. _build_prop() checks
	# is_placement_active()/placement_prop_id() to keep an IN-FLIGHT ghost's real
	# record non-colliding, but by this point the placement is already committed —
	# leaving the flags set here made the just-placed prop spawn with collision
	# (and crosshair focus, which requires a physics hit) disabled until some
	# unrelated later rebuild happened to reconstruct it.
	_clear_placement()
	var prop := PlacedPropRuntime.add_one(parent, rec, gy_fn)
	if prop != null and not ibc.is_empty() and main.get_tree() != null:
		BUNDLE_IMPORTER_SCRIPT.attach_ibc_to_imported_canopy(
			main.get_tree(), model_id, ibc)
	if ModelCatalog.is_starshade_model(model_id):
		_trigger_starshade_graph_seed(main, seed_prep, prop_id)
	elif model_id == LinkageStructureBuilder.MODEL_ID:
		# Deferred so the prop's global_transform has propagated (azimuth is
		# derived from the world-space panel normal).
		Callable(PlacedPropService, "seed_linkage_graph").call_deferred(main, prop_id)
	elif model_id == BedBuilder.MODEL_ID:
		_auto_tag_bed_space(main, prop_id)
	# Keep any bound graph node's site/elevation coords in sync with the 3D twin.
	_notify_graph_prop_moved(main, prop_id)
	return true


## A bed IS a sleeping spot: placing one tags it as a capacity-1 sleep space
## so a sleeper routes to it with no manual tagging step. Registered through
## the population bridge's registry resolution when the graph view is up
## (covers built-in scenes via the scene-keyed fallback registry), else the
## loader's registry directly. Idempotent (the registry upserts by target);
## deleting the prop is cleaned by prune_dangling on the next save.
static func _auto_tag_bed_space(main: Node, prop_id: String) -> void:
	var target := {"kind": "prop", "prop_id": prop_id}
	var reg: SpaceRegistry = null
	var sgv := main.get_node_or_null("UILayer/SystemGraphView") if main != null else null
	if sgv != null and sgv.has_method("npc_population_bridge"):
		var bridge: Variant = sgv.call("npc_population_bridge")
		if bridge != null and bridge.has_method("registry_for"):
			reg = bridge.call("registry_for", main)
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if reg == null and loader != null:
		reg = loader.get("npc_spaces") as SpaceRegistry
	if reg == null:
		return
	reg.set_space_type(target, "sleep", 1, "Bed")
	if loader != null and loader.has_method("save_npc_spaces"):
		loader.call("save_npc_spaces")
	elif main != null and not str(main.scene_file_path).is_empty():
		reg.save_for_scene(str(main.scene_file_path))


## World-metre plan footprint (W×D) from ModelCatalog metrics × resolved_scale.
static func footprint_from_model(model_id: String, user_scale: float = 1.0) -> Vector2:
	if model_id.is_empty():
		return Vector2.ZERO
	var metrics := ModelCatalog.mesh_metrics(model_id)
	var ws := ModelCatalog.resolved_scale(model_id, user_scale)
	return Vector2(
		maxf(float(metrics.get("width", 0.0)) * ws, 0.0),
		maxf(float(metrics.get("depth", 0.0)) * ws, 0.0))


## Ask the SystemGraphView to create a 2D node bound to a just-placed 3D prop
## (e.g. the VAWT). Returns the new node's item id, or "" if the graph is absent.
static func _create_bound_graph_node(main: Node, prop_id: String,
		graph_link: Dictionary) -> String:
	if main == null or graph_link.is_empty():
		return ""
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("create_bound_generator_node"):
		return ""
	return str(sgv.call("create_bound_generator_node", prop_id, graph_link))


static func seed_starshade_graph(main: Node, prep: Dictionary = {}) -> void:
	_trigger_starshade_graph_seed(main, prep)


## Per-prop tag for the graph array this structure owns (idempotent: re-placing
## / re-applying replaces only THIS structure's array node).
static func linkage_array_tag(prop_id: String) -> String:
	return "linkage_%s" % prop_id


## Push a placed linkage structure's deployed panel count / watts / orientation
## into the system graph as an imported solar array, tagged per prop. Derives
## real tilt + compass azimuth from the deployed panel normals rotated into
## world space (improves on the web app's gridRotation heuristic). Idempotent.
## Queue a crew REBUILD of a packed, already-fabricated linkage crate: the
## SiteProject.rebuild_spec_rows plan (raise → re-bolt → re-mount — no
## cutting or drilling, the parts exist) plus the build-site ghost preview
## stamped onto the record, so the faint outline of what is being raised is
## visible from the moment the project is queued. One implementation, called
## by the crate's edit drawer AND the Site Projects panel — the two entry
## points must queue byte-identical projects.
## Returns {ok, error, project_id, site: Vector2}.
static func queue_linkage_rebuild(main: Node, prop_id: String) -> Dictionary:
	var out := {"ok": false, "error": "", "project_id": "", "site": Vector2.ZERO}
	if main == null or prop_id.is_empty():
		out["error"] = "no prop"
		return out
	var sgv := _system_graph_view(main)
	var bridge: Variant = sgv.call("npc_population_bridge") \
		if sgv != null and sgv.has_method("npc_population_bridge") else null
	if bridge == null:
		out["error"] = "no population bridge"
		return out
	var iid := str(bridge.call("first_crewable_habitat"))
	if iid.is_empty():
		out["error"] = "Needs a pop-driven habitat with people on site"
		return out
	var rec: Dictionary = get_prop_record(main, prop_id)
	if rec.is_empty() or not (rec.get("linkage_spec") is Dictionary):
		out["error"] = "not a linkage crate"
		return out
	if not bool(rec.get("packed", false)) \
			or not str(rec.get("stowed_in", "")).is_empty():
		out["error"] = "not a free-standing packed crate"
		return out
	var p := LinkageParams.new()
	p.from_config(rec.get("linkage_spec") as Dictionary)
	var counts := LinkageBom.fab_counts(LinkageBom.compute(p), {})
	var site := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	var rows := SiteProject.rebuild_spec_rows(counts, prop_id)
	var project_id := str(bridge.call("create_site_project", iid,
		SiteProject.KIND_LINKAGE_BUILD, "Rebuild: linkage structure",
		prop_id, site, rows, {"start_h": 7.0, "end_h": 19.0},
		{"kind": "prop", "id": prop_id}, {}))
	if project_id.is_empty():
		out["error"] = "Chore board is full — clear some chores first"
		return out
	# The ghost preview: build_state with `preview` renders the DEPLOYED frame
	# fully ghosted beside the crate, so "what are they building" is
	# answerable from minute one. The erect phase's unpack clears it.
	update_prop_record(main, prop_id,
		{"build_state": {"phase": "", "ghost": 0.14, "preview": true}}, true)
	out["ok"] = true
	out["project_id"] = project_id
	out["site"] = site
	return out


static func seed_linkage_graph(main: Node, prop_id: String) -> bool:
	if main == null or prop_id.is_empty():
		return false
	var prop := _find_prop_node(main, prop_id)
	if prop == null:
		return false
	var builder := prop.get_node_or_null("ModelRoot")
	if builder == null or not builder.has_method("deployed_panel_summary"):
		return false
	var sgv := _system_graph_view(main)
	if sgv == null:
		return false
	var tag := linkage_array_tag(prop_id)
	var summary: Dictionary = builder.call("deployed_panel_summary")
	var count := int(summary.get("count", 0))
	if count <= 0:
		# No panels (or panels removed) — drop any prior array for this prop.
		if sgv.has_method("remove_imported_solar_array"):
			sgv.call("remove_imported_solar_array", tag)
		return false
	# Panel normal is builder-LOCAL; rotate into world so tilt/azimuth reflect
	# the placed prop's actual heading.
	var n_local: Vector3 = summary.get("avg_normal", Vector3.UP)
	var n_world := n_local
	if prop is Node3D:
		n_world = (prop as Node3D).global_transform.basis * n_local
	var orient: Dictionary = LinkageStructureBuilder.orientation_from_normal(n_world)
	var opts := {
		"tilt_deg": float(orient.get("tilt_deg", 0.0)),
		"voc": float(summary.get("voc", 0.0)),
		"vmp": float(summary.get("vmp", 0.0)),
		"isc": float(summary.get("isc", 0.0)),
		"imp": float(summary.get("imp", 0.0)),
		"panel_w_m": float(summary.get("panel_w_m", 0.0)),
		"panel_h_m": float(summary.get("panel_h_m", 0.0)),
		"show_picker": false,
		"auto_wire": true,
	}
	# Strip zero specs so add_imported_solar_panels falls back to its defaults.
	for k in ["voc", "vmp", "isc", "imp", "panel_w_m", "panel_h_m"]:
		if float(opts[k]) <= 0.0:
			opts.erase(k)
	var label := "Linkage Structure"
	if sgv.has_method("add_imported_solar_panels"):
		sgv.call("add_imported_solar_panels",
			count, float(summary.get("watts_per_panel", 0.0)), label, tag, opts)
	# Reflect the current deploy state onto the fresh node.
	var deployed := true
	var rt := prop.get_node_or_null("LinkageDeployRuntime")
	if rt != null and rt.has_method("is_deployed"):
		deployed = bool(rt.call("is_deployed"))
	if sgv.has_method("set_imported_array_stowed"):
		sgv.call("set_imported_array_stowed", tag, not deployed)
	return true


## Remove the graph array a deleted linkage structure owned.
static func remove_linkage_graph(main: Node, prop_id: String) -> void:
	if main == null or prop_id.is_empty():
		return
	var sgv := _system_graph_view(main)
	if sgv != null and sgv.has_method("remove_imported_solar_array"):
		sgv.call("remove_imported_solar_array", linkage_array_tag(prop_id))


static func _system_graph_view(main: Node) -> Node:
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	return sgv


## Push a placed/moved prop's world position into any bound graph node so
## Site/Elevation views track the 3D twin (D: 2D↔3D position sync). Deferred so
## the prop's global_transform has propagated before we read it.
static func _notify_graph_prop_moved(main: Node, prop_id: String) -> void:
	if main == null or prop_id.is_empty():
		return
	var sgv := _system_graph_view(main)
	if sgv != null and sgv.has_method("sync_site_from_prop"):
		Callable(sgv, "sync_site_from_prop").call_deferred(prop_id)


static func _find_prop_node(main: Node, prop_id: String) -> Node:
	var parent := _props_parent(main)
	if parent == null:
		return null
	var root := parent.get_node_or_null("PlacedProps")
	if root == null:
		return null
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			return child
	return null


static func _trigger_starshade_graph_seed(main: Node, prep: Dictionary = {},
		prop_id: String = "") -> void:
	if main == null:
		return
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if StarShadeGraphSeeder.try_seed_from_main(main, loader, prop_id):
		_stamp_starshade_graph_item_on_prop(main, prop_id)
		return
	var solar: Dictionary = prep.get("solar", {}) as Dictionary
	var panel_count := int(solar.get("panelCount", 0))
	if panel_count <= 0:
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("seed_starshade_system"):
		return
	var model: GraphModel = sgv.get("model") as GraphModel
	if model == null:
		return
	if bool(sgv.call("seed_starshade_system",
			panel_count, float(solar.get("panelWatts", 220.0)), "linkagelab_import")):
		if not prop_id.is_empty():
			StarShadeGraphSeeder.bind_starshade_prop(model, prop_id)
			_stamp_starshade_graph_item_on_prop(main, prop_id)
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")


static func _stamp_starshade_graph_item_on_prop(main: Node, prop_id: String) -> void:
	if main == null or prop_id.is_empty():
		return
	var layer := _layer_for_main(main)
	if layer == null:
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null:
		return
	var model: GraphModel = sgv.get("model") as GraphModel
	if model == null:
		return
	for item: Dictionary in model.items:
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("bound_prop_id", "")) == prop_id:
			layer.update_prop(prop_id, {"graph_item_id": str(item.get("id", ""))})
			_save_layer(main, layer)
			return


static func cancel_placement() -> void:
	# Ghost-based: nothing was ever written to the layer, so just discard it.
	_clear_placement()


# ==================== GHOST PREVIEW ====================

static func _build_ghost(main: Node, model_id: String) -> Node3D:
	var parent := _props_parent(main)
	if parent == null:
		return null
	var existing := parent.get_node_or_null("PlacementGhost")
	if existing != null:
		existing.free()
	var extras: Dictionary = {}
	if model_id == PalletRackBuilder.MODEL_ID:
		var rec_extra: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
		if rec_extra.has("rack_spec"):
			extras["rack_spec"] = rec_extra["rack_spec"]
		elif _placement_prep.has("rack_spec"):
			extras["rack_spec"] = _placement_prep["rack_spec"]
	elif model_id == LinkageStructureBuilder.MODEL_ID:
		var rec_extra3: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
		if rec_extra3.has("linkage_spec"):
			extras["linkage_spec"] = rec_extra3["linkage_spec"]
		elif _placement_prep.has("linkage_spec"):
			extras["linkage_spec"] = _placement_prep["linkage_spec"]
	elif model_id == ScadPartBuilder.MODEL_ID:
		var rec_extra_scad: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
		if rec_extra_scad.has("scad_spec"):
			extras["scad_spec"] = rec_extra_scad["scad_spec"]
		elif _placement_prep.has("scad_spec"):
			extras["scad_spec"] = _placement_prep["scad_spec"]
	elif model_id == GrowBed.MODEL_ID:
		var rec_extra2: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
		if rec_extra2.has("grow_bed_spec"):
			extras["grow_bed_spec"] = rec_extra2["grow_bed_spec"]
		elif rec_extra2.has("plant_abs_h"):
			extras["grow_bed_spec"] = {"plant_abs_h": rec_extra2["plant_abs_h"]}
	elif model_id == ModelCatalog.GENERIC_BOX_ID:
		var rec_extra4: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
		if rec_extra4.has("box_spec"):
			extras["box_spec"] = rec_extra4["box_spec"]
		elif _placement_prep.has("box_spec"):
			extras["box_spec"] = _placement_prep["box_spec"]
	elif model_id == GeodesicDomeBuilder.MODEL_ID:
		var dome_spec: Dictionary = {}
		if _placement_prep.has("dome_spec"):
			dome_spec = (_placement_prep["dome_spec"] as Dictionary).duplicate(true)
		else:
			var rec_extra5: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
			if rec_extra5.has("dome_spec"):
				dome_spec = (rec_extra5["dome_spec"] as Dictionary).duplicate(true)
		if dome_spec.is_empty():
			dome_spec = {"radius_m": DomeParts.TARGET_RADIUS_M, "ghost_highlight": true}
		else:
			dome_spec["ghost_highlight"] = bool(dome_spec.get("ghost_highlight", true))
		extras["dome_spec"] = dome_spec
	elif model_id == MudBuildingStructureBuilder.MODEL_ID:
		var mud_spec: Dictionary = {}
		if _placement_prep.has("mud_spec"):
			mud_spec = (_placement_prep["mud_spec"] as Dictionary).duplicate(true)
		else:
			var rec_extra6: Dictionary = _placement_prep.get("record_extra", {}) as Dictionary
			if rec_extra6.has("mud_spec"):
				mud_spec = (rec_extra6["mud_spec"] as Dictionary).duplicate(true)
		mud_spec["ghost_highlight"] = true
		extras["mud_spec"] = mud_spec
	var model := ModelCatalog.instantiate(model_id, extras)
	if model == null:
		return null
	var ghost := Node3D.new()
	ghost.name = "PlacementGhost"
	parent.add_child(ghost)
	ghost.add_child(model)
	model.name = "GhostModel"
	ghost.scale = Vector3.ONE * ModelCatalog.resolved_scale(model_id, 1.0)
	# Some models (e.g. the CSP trough) declare a fixed yaw that aligns their
	# mesh axes to world cardinals; apply it to the ghost too so the preview
	# already shows the same orientation PlacedPropRuntime will force on
	# confirm — otherwise the model visibly snaps/rotates the instant it's placed.
	var forced_yaw := ModelCatalog.forced_yaw_deg(model_id)
	if absf(forced_yaw) > 0.0001:
		model.rotation.y = deg_to_rad(forced_yaw)
	_disable_node_physics(model)
	_apply_ghost_tint_to(ghost, GHOST_VALID_COLOR)
	ghost.visible = false
	return ghost


static func _set_ghost_tint(valid: bool) -> void:
	if not is_instance_valid(_ghost_node):
		return
	_apply_ghost_tint_to(_ghost_node, GHOST_VALID_COLOR if valid else GHOST_INVALID_COLOR)


static func _apply_ghost_tint_to(ghost: Node3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for node in ghost.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override = mat
	# Procedural MultiMesh models (linkage structures) tint the same way.
	for node in ghost.find_children("*", "MultiMeshInstance3D", true, false):
		(node as MultiMeshInstance3D).material_override = mat


static func _disable_node_physics(model: Node3D) -> void:
	for node in model.find_children("*", "CollisionObject3D", true, false):
		var co := node as CollisionObject3D
		co.collision_layer = 0
		co.collision_mask = 0


static func _destroy_ghost() -> void:
	if is_instance_valid(_ghost_node):
		_ghost_node.queue_free()
	_ghost_node = null
	_ghost_model_id = ""
	_ghost_valid = false
	_ghost_ground_y = 0.0


static func _player_camera(main: Node) -> Camera3D:
	if main == null:
		return null
	var player := main.get_node_or_null("Player")
	if player == null:
		return null
	return player.get_node_or_null("CameraArm/Camera3D") as Camera3D


static func _clear_placement() -> void:
	_destroy_ghost()
	_placement_active = false
	_placement_prop_id = ""
	_placement_main = null
	_placement_prep = {}


static func _layer_for_main(main: Node) -> PlacedPropLayer:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.get("_placed_prop_layer") != null:
		return loader.get("_placed_prop_layer") as PlacedPropLayer
	# Prefer the map lat/lon file when a TerrainLoader exists but has not
	# attached its layer yet — NEVER invent an empty scene-keyed layer that
	# _save_layer would then write over placed_props_<lat>_<lon>.json.
	if loader != null and "_lat" in loader and "_lon" in loader:
		var lat := float(loader.get("_lat"))
		var lon := float(loader.get("_lon"))
		if not (is_nan(lat) or is_nan(lon)):
			var map_layer := PlacedPropLayer.create_empty()
			map_layer.load_for_map(lat, lon)
			loader.set("_placed_prop_layer", map_layer)
			return map_layer
	var key := _layer_key(main)
	if _scene_layers.has(key):
		return _scene_layers[key] as PlacedPropLayer
	var layer := PlacedPropLayer.create_empty()
	layer.load_for_scene(key)
	_scene_layers[key] = layer
	return layer


## If in-memory props look like a wholesale replacement of the on-disk set
## (zero shared ids — e.g. Site-twin bootstrap on an empty layer), union the
## disk props back in. Normal edits/deletes share ids with disk and are left
## alone so intentional removes still persist.
static func _merge_disk_props_if_disjoint(layer: PlacedPropLayer, lat: float, lon: float) -> void:
	if layer == null or is_nan(lat) or is_nan(lon):
		return
	var disk := PlacedPropLayer.create_empty()
	if not disk.load_for_map(lat, lon) or disk.props.is_empty():
		return
	var mem_ids: Dictionary = {}
	for item in layer.props:
		if item is Dictionary:
			var mid := str((item as Dictionary).get("id", ""))
			if not mid.is_empty():
				mem_ids[mid] = true
	var overlap := 0
	for item2 in disk.props:
		if not (item2 is Dictionary):
			continue
		var did := str((item2 as Dictionary).get("id", ""))
		if not did.is_empty() and mem_ids.has(did):
			overlap += 1
	if overlap > 0:
		return
	for item3 in disk.props:
		if item3 is Dictionary:
			layer.props.append(item3)


static func _save_layer(main: Node, layer: PlacedPropLayer) -> void:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and "_lat" in loader and "_lon" in loader:
		var lat := float(loader.get("_lat"))
		var lon := float(loader.get("_lon"))
		# Fresh/no-cache: memory starts empty — always merge disk first.
		if bool(loader.get("_user_overlays_ephemeral")):
			_merge_disk_props_if_disjoint(layer, lat, lon)
			# Also pull disk when memory is empty but ids aren't "disjoint"
			# in the overlap sense (both empty overlap=0 already handled).
			if layer.props.is_empty():
				var disk := PlacedPropLayer.create_empty()
				if disk.load_for_map(lat, lon):
					layer.props = disk.props
			if loader.get("_user_overlays_ephemeral") != null:
				loader.set("_user_overlays_ephemeral", false)
		else:
			# Guard against Site-twin / fallback-layer wipes (disjoint sets).
			_merge_disk_props_if_disjoint(layer, lat, lon)
		layer.save(lat, lon)
		return
	layer.save_for_scene(_layer_key(main))


static func _rebuild_scene_props(main: Node, layer: PlacedPropLayer) -> void:
	var parent := _props_parent(main)
	if parent == null:
		return
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	PlacedPropRuntime.rebuild(parent, layer, gy_fn)


## Reposition just the ONE moved prop's live scene node instead of freeing and
## rebuilding every placed prop. Two reasons: (1) cost — a Site Plan drag can
## fire this every frame-ish, and a full free+rebuild of every prop for a
## single XZ change is wasteful; (2) correctness — Godot's node delete queue
## (queue_free) and its deferred-call queue (call_deferred) are DIFFERENT
## queues with no guaranteed relative flush order. _notify_graph_prop_moved
## schedules a call_deferred read of this prop's world position (to sync the
## 2D graph node); with a full rebuild, that deferred read could run BEFORE
## the old (stale, pre-move) node instance was actually freed, find it first
## in props_parent's children, and write the OLD position back onto the graph
## node — the 2D node "snapping back" right after a correct 3D move. Updating
## the existing node in place has no such race: there is only ever one node.
static func _reposition_scene_prop(main: Node, layer: PlacedPropLayer, prop_id: String) -> void:
	var rec := layer.find_by_id(prop_id)
	if rec.is_empty():
		return
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id)
	if prop != null and is_instance_valid(prop):
		PlacedPropRuntime.apply_record_to_prop(prop, rec, gy_fn)
		return
	# No live node yet (e.g. moved before the scene finished attaching) — spawn it.
	var parent := _props_parent(main)
	if parent != null:
		PlacedPropRuntime.add_one(parent, rec, gy_fn)


static func _notify_mp_props_edited() -> void:
	# Soft lookup — keeps this class compilable in headless --script selftests
	# that pull PlacedPropService via ConduitManager without MP autoloads.
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return
	var mp: Node = (loop as SceneTree).root.get_node_or_null("/root/MultiplayerSession")
	if mp == null or not mp.has_method("notify_props_edited"):
		return
	if mp.has_method("is_active") and not bool(mp.call("is_active")):
		return
	mp.call("notify_props_edited")


static func _props_parent(main: Node) -> Node3D:
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain != null:
		return terrain
	return main as Node3D


static func _layer_key(main: Node) -> String:
	if main == null:
		return "unknown"
	return main.scene_file_path if not main.scene_file_path.is_empty() else main.name
