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

var _config: SoiConfig = SoiConfig.defaults()
var _lat := 0.0
var _lon := 0.0
var _loader: Node = null
var _root: Node3D = null
var _marker: Node3D = null
var _preview: Node3D = null
var _subsurface: Node3D = null
var _panel: Control = null
var _snowglobe: Node = null
var edit_mode := false
var snowglobe_active := false
var _placement_mode := false
var _globals_registered := false

## How often (real seconds) to re-check hero-tree (individually placed OSM
## `natural=tree` GLB) visibility against the SOI sphere while in Snowglobe
## mode. These trees use imported StandardMaterial3D, not a custom shader, so
## the soi_clip fragment-discard trick used by bark/foliage/grass can't reach
## them — instead we toggle each instance's `visible` from script.
const _HERO_CLIP_POLL_S := 0.2
var _hero_clip_acc := 0.0


func _ready() -> void:
	_register_shader_globals()
	set_process(false)


func _process(delta: float) -> void:
	if _placement_mode:
		_process_placement_pick()
	if snowglobe_active:
		_hero_clip_acc += delta
		if _hero_clip_acc >= _HERO_CLIP_POLL_S:
			_hero_clip_acc = 0.0
			_apply_hero_tree_clip()


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
	_ensure_world_nodes()
	_ensure_panel()
	refresh_footing()


func unbind_terrain() -> void:
	_loader = null
	if is_instance_valid(_root):
		_root.queue_free()
		_root = null
	_marker = null
	_preview = null
	_subsurface = null


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
	save_for_site()
	refresh_footing()
	soi_changed.emit()


func set_radius_m(r: float) -> void:
	_config.radius_m = clampf(r, SoiConfig.MIN_RADIUS_M, SoiConfig.MAX_RADIUS_M)
	save_for_site()
	if _preview != null and _preview.has_method("sync_transform"):
		_preview.sync_transform()
	if _subsurface != null and _subsurface.has_method("sync_transform"):
		_subsurface.sync_transform()
	_push_shader_globals()
	soi_changed.emit()


func reset_to_map_center() -> void:
	set_center_xz(0.0, 0.0)


func world_center() -> Vector3:
	var y := ground_y_at(_config.center_x, _config.center_z)
	return Vector3(_config.center_x, y, _config.center_z)


func radius_m() -> float:
	return _config.radius_m


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
	set_process(_placement_mode or snowglobe_active)


func open_panel() -> void:
	if _panel == null:
		_ensure_panel()
	if _panel != null and _panel.has_method("open_panel"):
		_panel.open_panel()


func enter_snowglobe() -> void:
	if snowglobe_active or _loader == null:
		return
	if _panel != null and _panel.has_method("close_panel"):
		_panel.close_panel()
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
	_hero_clip_acc = 999.0
	_apply_hero_tree_clip()
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
	_sync_process()
	set_clip_enabled(false)
	if _subsurface != null:
		_subsurface.visible = false
	_reset_hero_tree_visibility()
	snowglobe_active_changed.emit(false)


func set_clip_enabled(on: bool) -> void:
	if not _globals_registered:
		return
	RenderingServer.global_shader_parameter_set("soi_clip_enabled", 1.0 if on else 0.0)


func collect_save_state() -> Dictionary:
	return _config.serialize()


func apply_save_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	_config.deserialize(data)
	save_for_site()
	refresh_footing()
	soi_changed.emit()


func _register_shader_globals() -> void:
	if not RenderingServer.global_shader_parameter_get_list().has("soi_center_radius"):
		RenderingServer.global_shader_parameter_add(
			"soi_center_radius", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	if not RenderingServer.global_shader_parameter_get_list().has("soi_clip_enabled"):
		RenderingServer.global_shader_parameter_add(
			"soi_clip_enabled", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	if not RenderingServer.global_shader_parameter_get_list().has("soi_ground_y"):
		RenderingServer.global_shader_parameter_add(
			"soi_ground_y", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	if not RenderingServer.global_shader_parameter_get_list().has("soi_water_table_m"):
		RenderingServer.global_shader_parameter_add(
			"soi_water_table_m", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 15.0)
	_globals_registered = true
	set_clip_enabled(false)
	RenderingServer.global_shader_parameter_set("soi_water_table_m", 15.0)
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
