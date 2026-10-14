extends Node

## Sphere of Influence — placement, persistence, shader globals, and Snowglobe mode.

signal soi_changed
signal snowglobe_active_changed(active: bool)
signal edit_mode_changed(active: bool)

const SoiMarkerScript := preload("res://core/soi/soi_marker.gd")
const SoiPreviewScript := preload("res://core/soi/soi_preview.gd")
const SoiSubsurfaceScript := preload("res://core/soi/soi_subsurface.gd")
const SoiSnowglobeScript := preload("res://core/soi/soi_snowglobe_camera.gd")
const SoiPanelScript := preload("res://scenes/ui/soi_panel_ui.gd")
const SoiSnowglobeHudScript := preload("res://scenes/ui/soi_snowglobe_hud.gd")

var _config: SoiConfig = SoiConfig.defaults()
var _lat := 0.0
var _lon := 0.0
var _loader: Node = null
var _root: Node3D = null
var _marker: Node3D = null
var _preview: Node3D = null
var _subsurface: Node3D = null
var _section_cap: SoiSectionCap = null
## Shared rim sun (SoiRimSun) — one disc for both globes, ref-counted by owner.
var _rim_sun: SoiRimSun = null
var _rim_sun_owners: Dictionary = {}
var _panel: Control = null
var _snowglobe: Node = null
var _snowglobe_hud: CanvasLayer = null
var edit_mode := false
var snowglobe_active := false
## Set when the globe was opened over the system graph (which had to close so
## the root viewport renders 3D again); the graph reopens when the globe exits.
var _return_to_graph_after_globe := false
## Graph-editor live SoI backdrop (SubViewport) — owns clip/subsurface when
## snowglobe modal is not open.
var graph_preview_active := false
## When false, graph preview keeps clip but hides the glass dome (Site Plan).
var _graph_preview_shell_visible := true
var _placement_mode := false
var _globals_registered := false
var _save_pending := false

## How often (real seconds) to re-check hero-tree (individually placed OSM
## `natural=tree` GLB) visibility against the SOI sphere while in Snowglobe
## mode. These trees use imported StandardMaterial3D, not a custom shader, so
## the soi_clip fragment-discard trick used by bark/foliage/grass can't reach
## them — instead we toggle each instance's `visible` from script.
const _HERO_CLIP_POLL_S := 0.2
const _HERO_CLIP_POLL_LITE_S := 0.75
const _SAVE_DEBOUNCE_S := 0.35
var _hero_clip_acc := 0.0
var _save_acc := 0.0
## Lite preview: hide dense foliage MultiMeshes while Snowglobe / Site Plan
## runs so orbit/zoom stay responsive. Terrain, buildings, water stay visible.
var preview_lite := false
var _veg_hidden_nodes: Array = []


func _ready() -> void:
	_register_shader_globals()
	set_process(false)


func _process(delta: float) -> void:
	if _placement_mode:
		_process_placement_pick()
	if snowglobe_active or graph_preview_active:
		_hero_clip_acc += delta
		var poll := _HERO_CLIP_POLL_LITE_S if preview_lite else _HERO_CLIP_POLL_S
		if _hero_clip_acc >= poll:
			_hero_clip_acc = 0.0
			_apply_hero_tree_clip()
	if _save_pending:
		_save_acc += delta
		if _save_acc >= _SAVE_DEBOUNCE_S:
			_flush_pending_save()
	if not _rim_sun_owners.is_empty() and _rim_sun != null and is_instance_valid(_rim_sun):
		var tree := get_tree()
		var main := tree.current_scene if tree != null else null
		var sun := main.get("sun") as DirectionalLight3D if main != null else null
		_rim_sun.update_from(world_center(), _config.radius_m, sun)


## Vegetation look for the SoI views (veg_lighting.gdshaderinc globals):
## a self-lit fill so crowns read at preview distance under a very low world
## ambient, and no eye-level distance haze. Ref-counted by owner
## ("graph_preview", "snowglobe"); first person is back to 0 / 1 when none hold
## it (the graph's root viewport renders no 3D meanwhile, and the full-screen
## globe IS the view).
const PREVIEW_VEG_FILL := 0.28
var _veg_look_owners: Dictionary = {}


func set_preview_vegetation_look(owner: String, on: bool) -> void:
	if on:
		_veg_look_owners[owner] = true
	else:
		_veg_look_owners.erase(owner)
	var active := not _veg_look_owners.is_empty()
	RenderingServer.global_shader_parameter_set("veg_fill", PREVIEW_VEG_FILL if active else 0.0)
	RenderingServer.global_shader_parameter_set("veg_haze_mul", 0.0 if active else 1.0)


## Show the emblem's rim sun for `owner` ("snowglobe" / "graph_globe"). It is a
## world node, so whichever camera renders the SoI (the full-screen globe or the
## graph's preview SubViewport) draws it; it follows the real sun every frame.
func acquire_rim_sun(owner: String) -> void:
	_rim_sun_owners[owner] = true
	if (_rim_sun == null or not is_instance_valid(_rim_sun)) and is_instance_valid(_root):
		_rim_sun = SoiRimSun.new()
		_root.add_child(_rim_sun)
	_sync_process()


func release_rim_sun(owner: String) -> void:
	_rim_sun_owners.erase(owner)
	if _rim_sun_owners.is_empty() and _rim_sun != null and is_instance_valid(_rim_sun):
		_rim_sun.visible = false
	_sync_process()


## Hide AutoVegetation / Vegetation while SoI views are active (perf). Safe to
## call repeatedly; restores previous visibility on `false`.
func set_preview_lite(on: bool) -> void:
	if preview_lite == on:
		return
	preview_lite = on
	if on:
		_hide_vegetation_for_lite()
	else:
		_restore_vegetation_after_lite()


## Pitch-based glass opacity for full Snowglobe (0 = kill Fresnel sky bullseye
## near horizon, 1 = full glass). Preview Elevation already hard-kills glass.
func set_snowglobe_glass_opacity(opacity: float) -> void:
	if _subsurface != null and _subsurface.has_method("set_glass_opacity"):
		_subsurface.call("set_glass_opacity", clampf(opacity, 0.0, 1.0))


func _hide_vegetation_for_lite() -> void:
	_veg_hidden_nodes.clear()
	var terrain := _terrain_node()
	if terrain == null:
		return
	for nname: String in ["AutoVegetation", "Vegetation"]:
		var node := terrain.get_node_or_null(nname) as Node3D
		if node != null and node.visible:
			_veg_hidden_nodes.append(node)
			node.visible = false
	# Leaf Multimesh batches sometimes live as named siblings.
	for child in terrain.get_children():
		if not (child is Node3D):
			continue
		var nm := str(child.name)
		if nm.begins_with("Leaf") or nm.begins_with("Foliage") or nm.contains("Canopy"):
			var c3 := child as Node3D
			if c3.visible and not _veg_hidden_nodes.has(c3):
				_veg_hidden_nodes.append(c3)
				c3.visible = false


func _restore_vegetation_after_lite() -> void:
	for n: Variant in _veg_hidden_nodes:
		if n is Node3D and is_instance_valid(n):
			(n as Node3D).visible = true
	_veg_hidden_nodes.clear()


func load_for_site(lat: float, lon: float) -> void:
	_lat = lat
	_lon = lon
	_config = SoiConfig.load_for_map(lat, lon)
	_push_shader_globals()
	soi_changed.emit()


func save_for_site() -> void:
	if is_zero_approx(_lat) and is_zero_approx(_lon):
		return
	_config.save_for_map(_lat, _lon)


func bind_terrain(loader: Node) -> void:
	_loader = loader
	# Fresh map / terrain bind always opens in the full world — never inherit a
	# latched graph SoI-preview clip (autosave view_mode restore used to do that).
	clear_graph_preview_world_effects()
	_ensure_world_nodes()
	_ensure_panel()
	refresh_footing()


func unbind_terrain() -> void:
	clear_graph_preview_world_effects()
	_loader = null
	if is_instance_valid(_root):
		_root.queue_free()
		_root = null
	_marker = null
	_preview = null
	_subsurface = null
	_section_cap = null
	_rim_sun = null


func refresh_footing() -> void:
	if _marker != null and _marker.has_method("sync_position"):
		_marker.sync_position()
	if _preview != null and _preview.has_method("sync_transform"):
		_preview.sync_transform()
	if _subsurface != null and _subsurface.has_method("sync_transform"):
		_subsurface.sync_transform()
	_push_shader_globals()


func set_center_xz(x: float, z: float) -> void:
	_config.center_x = x
	_config.center_z = z
	_schedule_save()
	refresh_footing()
	soi_changed.emit()


func set_radius_m(r: float) -> void:
	_config.radius_m = clampf(r, SoiConfig.MIN_RADIUS_M, SoiConfig.MAX_RADIUS_M)
	_schedule_save()
	if _preview != null and _preview.has_method("sync_transform"):
		_preview.sync_transform()
	if _subsurface != null and _subsurface.has_method("sync_transform"):
		_subsurface.sync_transform()
	_push_shader_globals()
	# Hero-tree clip is expensive — refresh on next poll tick, not every slider step.
	if snowglobe_active:
		_hero_clip_acc = _HERO_CLIP_POLL_S
	soi_changed.emit()


func reset_to_map_center() -> void:
	set_center_xz(0.0, 0.0)


func _schedule_save() -> void:
	_save_pending = true
	_save_acc = 0.0
	_sync_process()


func _flush_pending_save() -> void:
	_save_pending = false
	_save_acc = 0.0
	save_for_site()
	_sync_process()


func world_center() -> Vector3:
	var y := ground_y_at(_config.center_x, _config.center_z)
	return Vector3(_config.center_x, y, _config.center_z)


func radius_m() -> float:
	return _config.radius_m


## True if world XZ lies inside the current SoI disc (horizontal).
func contains_xz(x: float, z: float) -> bool:
	var dx := x - _config.center_x
	var dz := z - _config.center_z
	var r := _config.radius_m
	return dx * dx + dz * dz <= r * r


func area_m2() -> float:
	return PI * _config.radius_m * _config.radius_m


func ground_y_at(x: float, z: float) -> float:
	if _loader != null and _loader.has_method("ground_height_at"):
		return float(_loader.call("ground_height_at", x, z))
	return 0.0


func set_edit_mode(on: bool) -> void:
	if edit_mode == on:
		return
	edit_mode = on
	if _preview != null:
		_preview.visible = on
	edit_mode_changed.emit(on)


func begin_placement_mode() -> void:
	_placement_mode = true
	_sync_process()


func cancel_placement_mode() -> void:
	_placement_mode = false
	_sync_process()


func _sync_process() -> void:
	set_process(_placement_mode or snowglobe_active or graph_preview_active or _save_pending \
			or not _rim_sun_owners.is_empty())


## Enable/disable SoI clip + glass shell for the graph SubViewport backdrop.
## No-ops while full-screen snowglobe owns the same visuals.
func set_graph_preview_active(on: bool) -> void:
	if graph_preview_active == on:
		# Force-clear clip when requesting off — guards inconsistent latches.
		if not on and not snowglobe_active:
			set_clip_enabled(false)
			if _subsurface != null:
				_subsurface.visible = false
			_reset_hero_tree_visibility()
		return
	graph_preview_active = on
	_sync_process()
	if snowglobe_active:
		return
	set_clip_enabled(on)
	if _subsurface != null:
		_subsurface.visible = on and _graph_preview_shell_visible
		if on and _subsurface.has_method("sync_transform"):
			_subsurface.sync_transform()
	if on:
		if _preview != null:
			_preview.visible = false
		set_preview_lite(true)
		_hero_clip_acc = 999.0
		_apply_hero_tree_clip()
	else:
		if not snowglobe_active:
			set_preview_lite(false)
		if _preview != null:
			_preview.visible = edit_mode
		_reset_hero_tree_visibility()


## Used on map bind / graph close so FPS never remains in clipped snowglobe mode.
func clear_graph_preview_world_effects() -> void:
	graph_preview_active = false
	_sync_process()
	if snowglobe_active:
		return
	set_preview_lite(false)
	set_clip_enabled(false)
	if _subsurface != null:
		_subsurface.visible = false
	if _preview != null:
		_preview.visible = edit_mode
	_reset_hero_tree_visibility()


## Site Plan top-down should not paint the glass dome (it fills the ortho
## view as a black disc). Perspective SoI preview keeps the shell.
func set_graph_preview_shell_visible(on: bool) -> void:
	_graph_preview_shell_visible = on
	if not graph_preview_active or snowglobe_active:
		return
	if _subsurface != null:
		_subsurface.visible = on
		if on and _subsurface.has_method("sync_transform"):
			_subsurface.sync_transform()


## Toggle only the above-ground glass. Elevation section keeps the soil bowl
## but turns glass off so the sky/clouds aren't covered by Fresnel bullseyes.
func set_graph_preview_glass_enabled(on: bool) -> void:
	if _subsurface != null and _subsurface.has_method("set_glass_enabled"):
		_subsurface.call("set_glass_enabled", on)


## Site Plan top-down: fill the below-ground bowl with the flat ground tan
## (the diagram cutaway with veins/aquifer stays for Elevation/Snowglobe).
func set_graph_preview_plain_soil(on: bool) -> void:
	if _subsurface != null and _subsurface.has_method("set_plain_soil"):
		_subsurface.call("set_plain_soil", on)


func open_panel() -> void:
	if _panel == null:
		_ensure_panel()
	if _panel != null and _panel.has_method("open_panel"):
		_panel.open_panel()


## Default entry from the SoI marker (Interact / O): open Snowglobe with radius HUD.
func open_from_marker() -> void:
	enter_snowglobe()


func enter_snowglobe() -> void:
	if snowglobe_active or _loader == null:
		return
	# The globe renders through the ROOT viewport, which the graph runs with
	# disable_3d while it is open — entered over the graph it drew nothing.
	# Close the graph first (its close path also tears down the graph preview's
	# clip latch synchronously) and bring it back when the globe exits.
	_return_to_graph_after_globe = false
	var graph := ServiceLocator.graph()
	var graph_open := graph != null and is_instance_valid(graph) \
			and (graph as CanvasItem).visible
	if graph_open and graph.has_method("close_graph_view"):
		graph.call("close_graph_view")
		_return_to_graph_after_globe = true
	if _panel != null and _panel.has_method("close_panel"):
		_panel.close_panel()
	# Hide the preview sphere so it doesn't Z-fight with the snowglobe glass dome.
	if _preview != null:
		_preview.visible = false
	if _snowglobe == null:
		_snowglobe = SoiSnowglobeScript.new()
		_snowglobe.name = "SoiSnowglobeCamera"
		add_child(_snowglobe)
	_snowglobe.enter(self, _loader)
	snowglobe_active = true
	_sync_process()
	set_clip_enabled(true)
	if _subsurface != null:
		_subsurface.visible = true
		if _subsurface.has_method("set_glass_enabled"):
			_subsurface.call("set_glass_enabled", true)
	set_preview_lite(true)
	_hero_clip_acc = 999.0
	_apply_hero_tree_clip()
	_ensure_snowglobe_hud()
	if _snowglobe_hud != null and _snowglobe_hud.has_method("show_hud"):
		_snowglobe_hud.call("show_hud")
	set_preview_vegetation_look("snowglobe", true)
	snowglobe_active_changed.emit(true)


func exit_snowglobe() -> void:
	if not snowglobe_active:
		return
	if _snowglobe != null and _snowglobe.has_method("exit"):
		_snowglobe.exit()
	else:
		_finalize_snowglobe_exit()


func _finalize_snowglobe_exit() -> void:
	if not snowglobe_active:
		return
	snowglobe_active = false
	if _save_pending:
		_flush_pending_save()
	_sync_process()
	# Restore graph-editor SoI backdrop visuals if that mode is still on.
	if graph_preview_active:
		set_clip_enabled(true)
		if _subsurface != null:
			_subsurface.visible = _graph_preview_shell_visible
			if _subsurface.has_method("sync_transform"):
				_subsurface.sync_transform()
		# Keep lite while graph Site Plan / bubble is still showing.
		set_preview_lite(true)
		_hero_clip_acc = 999.0
		_apply_hero_tree_clip()
	else:
		set_preview_lite(false)
		set_clip_enabled(false)
		if _subsurface != null:
			_subsurface.visible = false
			if _subsurface.has_method("set_glass_opacity"):
				_subsurface.call("set_glass_opacity", 1.0)
		if _preview != null:
			_preview.visible = edit_mode
		_reset_hero_tree_visibility()
	if _snowglobe_hud != null and _snowglobe_hud.has_method("hide_hud"):
		_snowglobe_hud.call("hide_hud")
	set_preview_vegetation_look("snowglobe", false)
	snowglobe_active_changed.emit(false)
	if _return_to_graph_after_globe:
		_return_to_graph_after_globe = false
		var graph := ServiceLocator.graph()
		if graph != null and is_instance_valid(graph) and graph.has_method("open_graph_view"):
			# Deferred: the snowglobe's own exit (camera pop, modal release)
			# is still unwinding on this stack.
			graph.call_deferred("open_graph_view")


func set_clip_enabled(on: bool) -> void:
	if not _globals_registered:
		return
	RenderingServer.global_shader_parameter_set("soi_clip_enabled", 1.0 if on else 0.0)
	if not on:
		set_section_cutaway(false, Vector3.ZERO, Vector3.FORWARD)


## CT-style half-plane cutaway used by Elevation 3D section preview.
## `plane_n` should point toward the section camera (that half is discarded).
func set_section_cutaway(on: bool, plane_origin: Vector3 = Vector3.ZERO,
		plane_n: Vector3 = Vector3.FORWARD) -> void:
	if not _globals_registered:
		return
	var n := plane_n
	if n.length_squared() < 1e-8:
		n = Vector3.FORWARD
	else:
		n = n.normalized()
	RenderingServer.global_shader_parameter_set(
			"soi_section_plane",
			Vector4(plane_origin.x, plane_origin.y, plane_origin.z, 1.0 if on else 0.0))
	RenderingServer.global_shader_parameter_set(
			"soi_section_normal", Vector4(n.x, n.y, n.z, 0.0))
	_sync_section_cap(on, plane_origin, n)


## Fill the cut with solid strata (SoiSectionCap) whenever a section is open —
## without it the cutaway left the plane open and the sky showed through the
## ground. Only for the graph's preview (Elevation CT / Hydro Lab); the
## full-screen globe has no cutaway.
func _sync_section_cap(on: bool, plane_origin: Vector3, n: Vector3) -> void:
	if _section_cap == null or not is_instance_valid(_section_cap):
		return
	if not on or snowglobe_active or not graph_preview_active:
		_section_cap.visible = false
		return
	_section_cap.sync_cut(world_center(), _config.radius_m, plane_origin, n,
			Callable(self, "ground_y_at"))


## Top-edge lip of the cut cap (metres) — scaled by the section's zoom so no
## sliver of sky shows between the cap and the terrain mesh at deep zoom.
func set_section_cap_lip(lip_m: float) -> void:
	if _section_cap != null and is_instance_valid(_section_cap):
		_section_cap.set_lip(lip_m)


func set_section_cap_reveal(t: float) -> void:
	if _section_cap != null and is_instance_valid(_section_cap):
		_section_cap.set_reveal(t)


func section_cap_node() -> Node3D:
	return _section_cap


func collect_save_state() -> Dictionary:
	return _config.serialize()


func apply_save_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	_config.deserialize(data)
	save_for_site()
	refresh_footing()
	soi_changed.emit()


## Declared in project.godot [shader_globals] → already registered. (The
## old guard used global_shader_parameter_get_list, which is editor-only and
## returns [] in a running game, so every add errored on boot.)
static func _global_declared(name: String) -> bool:
	return ProjectSettings.has_setting("shader_globals/" + name)


func _register_shader_globals() -> void:
	if not _global_declared("soi_center_radius"):
		RenderingServer.global_shader_parameter_add(
			"soi_center_radius", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	if not _global_declared("soi_clip_enabled"):
		RenderingServer.global_shader_parameter_add(
			"soi_clip_enabled", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	if not _global_declared("soi_ground_y"):
		RenderingServer.global_shader_parameter_add(
			"soi_ground_y", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	if not _global_declared("soi_water_table_m"):
		RenderingServer.global_shader_parameter_add(
			"soi_water_table_m", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 15.0)
	if not _global_declared("soi_section_plane"):
		RenderingServer.global_shader_parameter_add(
			"soi_section_plane", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	if not _global_declared("soi_section_normal"):
		RenderingServer.global_shader_parameter_add(
			"soi_section_normal", RenderingServer.GLOBAL_VAR_TYPE_VEC4,
			Vector4(0.0, 0.0, 1.0, 0.0))
	_globals_registered = true
	set_clip_enabled(false)
	RenderingServer.global_shader_parameter_set("soi_water_table_m", 15.0)
	set_section_cutaway(false)
	_push_shader_globals()


func _push_shader_globals() -> void:
	if not _globals_registered:
		return
	var c := world_center()
	RenderingServer.global_shader_parameter_set(
		"soi_center_radius", Vector4(c.x, c.y, c.z, _config.radius_m))
	RenderingServer.global_shader_parameter_set("soi_ground_y", c.y)


func _ensure_world_nodes() -> void:
	if _loader == null:
		return
	var terrain := _loader.get_parent() if _loader.get_parent() is Node3D else null
	if terrain == null:
		return
	if is_instance_valid(_root):
		return
	_root = Node3D.new()
	_root.name = "SoI"
	terrain.add_child(_root)
	_marker = SoiMarkerScript.new()
	_marker.name = "SoiMarker"
	_root.add_child(_marker)
	_preview = SoiPreviewScript.new()
	_preview.name = "SoiPreview"
	_preview.visible = false
	_root.add_child(_preview)
	_subsurface = SoiSubsurfaceScript.new()
	_subsurface.name = "SoiSubsurface"
	_subsurface.visible = false
	_root.add_child(_subsurface)
	_section_cap = SoiSectionCap.new()
	_section_cap.name = "SoiSectionCap"
	_root.add_child(_section_cap)
	refresh_footing()


func _ensure_panel() -> void:
	if is_instance_valid(_panel):
		return
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main == null:
		return
	var ui := main.get_node_or_null("UILayer")
	if ui == null:
		return
	_panel = SoiPanelScript.new()
	_panel.name = "SoiPanelUI"
	ui.add_child(_panel)


func _ensure_snowglobe_hud() -> void:
	if is_instance_valid(_snowglobe_hud):
		return
	_snowglobe_hud = SoiSnowglobeHudScript.new()
	_snowglobe_hud.name = "SoiSnowglobeHud"
	add_child(_snowglobe_hud)
	if _snowglobe_hud.has_method("bind_service"):
		_snowglobe_hud.call("bind_service", self)


func _process_placement_pick() -> void:
	if not Input.is_action_just_pressed("interact"):
		return
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	var cam := _active_camera()
	if main == null or cam == null:
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, cam)
	if hit.is_empty():
		return
	var p: Vector3 = hit["position"] as Vector3
	set_center_xz(p.x, p.z)
	cancel_placement_mode()
	if _panel != null and _panel.has_method("on_placement_done"):
		_panel.on_placement_done()


## Individually-placed OSM hero trees (VegetationRuntime / AutoVegetationRuntime
## both name their container "HeroTrees", one per instanced GLB) render with
## imported StandardMaterial3D, so they can't honor the soi_clip shader
## uniform like the bulk bark/foliage/leaf-canopy/grass materials do. Hide any
## instance whose world position falls outside the sphere while Snowglobe is
## active; _reset_hero_tree_visibility() undoes this on exit.
func _apply_hero_tree_clip() -> void:
	var terrain := _terrain_node()
	if terrain == null:
		return
	var center := world_center()
	var r := _config.radius_m
	for heroes in terrain.find_children("HeroTrees", "Node3D", true, false):
		for child in (heroes as Node3D).get_children():
			if child is Node3D:
				var c3 := child as Node3D
				c3.visible = c3.global_position.distance_to(center) <= r


func _reset_hero_tree_visibility() -> void:
	var terrain := _terrain_node()
	if terrain == null:
		return
	for heroes in terrain.find_children("HeroTrees", "Node3D", true, false):
		for child in (heroes as Node3D).get_children():
			if child is Node3D:
				(child as Node3D).visible = true


func _terrain_node() -> Node3D:
	if _loader == null:
		return null
	return _loader.get_parent() if _loader.get_parent() is Node3D else null


func _active_camera() -> Camera3D:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_viewport().get_camera_3d()
