extends Node

## In-world routing mode for a single graph connection. Raycast-pins waypoints
## onto geometry; Enter commits route_3d to GraphModel via ConduitManager.

signal route_committed(conn_id: String)
signal route_cancelled(conn_id: String)

const RAY_LEN := 800.0

var _player: Node3D = null
var _camera: Camera3D = null
var _manager: ConduitManager = null
var _ui: CanvasLayer = null
var _preview: MeshInstance3D = null

var _active: bool = false
var _conn_id: String = ""
var _type_id: String = "extension_cord"
var _waypoints: Array = []  ## Array of Dictionary {x,y,z,pin_path?}
var _anchor_a: Vector3 = Vector3.ZERO
var _anchor_b: Vector3 = Vector3.ZERO
var _ghost_pos: Vector3 = Vector3.ZERO
var _ghost_valid: bool = false


func setup(player: Node3D, camera: Camera3D, manager: ConduitManager,
		ui: CanvasLayer = null) -> void:
	_player = player
	_camera = camera
	_manager = manager
	_ui = ui
	_ensure_preview()


func is_routing() -> bool:
	return _active


func begin_route(conn_id: String, anchor_a: Vector3, anchor_b: Vector3,
		type_id: String, existing_route: Array) -> void:
	_conn_id = conn_id
	_anchor_a = anchor_a
	_anchor_b = anchor_b
	_type_id = type_id
	_waypoints = existing_route.duplicate(true)
	_active = true
	_update_ui()
	_refresh_preview()


func cancel_route() -> void:
	if not _active:
		return
	_active = false
	_hide_preview()
	if _ui != null and _ui.has_method("hide_route"):
		_ui.call("hide_route")
	route_cancelled.emit(_conn_id)
	_conn_id = ""


func commit_route() -> void:
	if not _active or _manager == null:
		return
	_manager.commit_route(_conn_id, _waypoints.duplicate(true))
	_active = false
	_hide_preview()
	if _ui != null and _ui.has_method("hide_route"):
		_ui.call("hide_route")
	route_committed.emit(_conn_id)
	_conn_id = ""


func _ensure_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		return
	_preview = MeshInstance3D.new()
	_preview.name = "ConduitRoutePreview"
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _manager != null:
		_manager.add_child(_preview)
	else:
		add_child(_preview)
	_preview.visible = false


func _physics_process(_delta: float) -> void:
	if not _active:
		return
	var hit := _raycast_center()
	if hit.has("position"):
		_ghost_pos = hit["position"] as Vector3
		_ghost_valid = true
	else:
		_ghost_valid = false
	_refresh_preview()
	_update_ui()


func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				commit_route()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				cancel_route()
				get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and _ghost_valid:
			var pin_path := ""
			if event is InputEventMouseButton:
				var hit := _raycast_center()
				if hit.has("collider"):
					var col: Object = hit["collider"]
					if col is Node:
						pin_path = str((col as Node).get_path())
			_waypoints.append(ConduitKinds.waypoint_dict(_ghost_pos, pin_path))
			_refresh_preview()
			_update_ui()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if not _waypoints.is_empty():
				_waypoints.pop_back()
				_refresh_preview()
				_update_ui()
			get_viewport().set_input_as_handled()


func _raycast_center() -> Dictionary:
	if _player == null or _camera == null:
		return {}
	var vp := get_viewport()
	if vp == null:
		return {}
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var world: World3D = _player.get_world_3d()
	if world == null:
		return {}
	var space := world.direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LEN)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query)


func _control_points_for_preview() -> Array:
	var pts: Array = [_anchor_a]
	for wp: Vector3 in ConduitKinds.waypoints_to_vectors(_waypoints):
		pts.append(wp)
	if _ghost_valid:
		pts.append(_ghost_pos)
	pts.append(_anchor_b)
	return pts


func _refresh_preview() -> void:
	_ensure_preview()
	if not _active or _preview == null:
		return
	var control := _control_points_for_preview()
	if control.size() < 2:
		_preview.visible = false
		return
	var built: Dictionary = ConduitMeshBuilder.build(control, _type_id)
	_preview.mesh = built.get("mesh", null)
	var mat: Material = built.get("material", null)
	if mat is StandardMaterial3D:
		var pm := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
		pm.albedo_color = pm.albedo_color.lerp(Color(0.2, 1.0, 0.5), 0.35)
		pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pm.albedo_color.a = 0.75
		_preview.material_override = pm
	else:
		_preview.material_override = mat
	_preview.visible = true


func _hide_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.visible = false


func _update_ui() -> void:
	if _ui == null or not _ui.has_method("show_route"):
		return
	var control := _control_points_for_preview()
	var built: Dictionary = ConduitMeshBuilder.build(control, _type_id) if control.size() >= 2 else {}
	var len_m: float = float(built.get("arc_length_m", 0.0))
	_ui.call("show_route", _type_id, _waypoints.size(), len_m, _ghost_valid)
