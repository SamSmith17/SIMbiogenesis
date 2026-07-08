extends Node

## Center-screen raycast focus for Interactable nodes + OSM building pick fallback.

const RAY_LENGTH: float = 12.0

var _player: Node3D = null
var _camera: Camera3D = null
var _focused: Interactable = null
var _crosshair: CanvasLayer = null
var _prompt_ui: CanvasLayer = null
var _loader: Node = null
var _solar_focus_idx: int = -1


func setup(player: Node3D, camera: Camera3D) -> void:
	_player = player
	_camera = camera
	call_deferred("_find_ui")
	call_deferred("_find_loader")


func _find_loader() -> void:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	_loader = tree.current_scene.get_node_or_null("TerrainLoader")


func get_focused() -> Interactable:
	return _focused


func clear_focus() -> void:
	_clear_focus()


func _physics_process(_delta: float) -> void:
	if _focused != null and not is_instance_valid(_focused):
		_focused = null
		_update_ui()
	if _player == null or _camera == null:
		return
	var route_ctrl: Node = _player.get_node_or_null("ConduitRouteController")
	if route_ctrl != null and route_ctrl.has_method("is_routing") \
			and bool(route_ctrl.call("is_routing")):
		_clear_focus()
		_clear_solar_focus()
		_clear_building_focus()
		_clear_veg_focus()
		return
	if not _should_update_focus():
		_clear_focus()
		_clear_solar_focus()
		_clear_building_focus()
		_clear_veg_focus()
		return
	# On foot, a short physics ray finds nearby Interactable props. In the FPV
	# drone there are no walkable props, so that step is skipped entirely — but
	# OSM building/solar picking runs in BOTH modes via a long-range ground ray
	# so buildings can be selected from any altitude/distance.
	var drone := _is_drone_mode()
	var next: Interactable = null
	if not drone:
		var hit := _raycast_center()
		if hit.has("collider"):
			next = _find_interactable(hit.collider as Object)
			if next != null and not next.can_interact(_player):
				next = null
			if next != null:
				var dist: float = _camera.global_position.distance_to(hit.position)
				if dist > next.max_distance:
					next = null
	if next != _focused:
		if _focused != null:
			_focused.on_focus_exit(_player)
		_focused = next
		if _focused != null:
			_focused.on_focus_enter(_player)
		_update_ui()
	elif _focused != null:
		_update_ui()
	if _focused == null:
		# Long-range ground point under the crosshair → OSM polygon pick. Priority:
		# solar arrays (panels sit on/next to their host footprints) → buildings →
		# vegetation areas (large ground polygons; the most specific target wins).
		var ground: Variant = _ground_pick_center()
		if ground is Vector3:
			if _update_solar_focus(ground as Vector3):
				_clear_building_focus()
				_clear_veg_focus()
			elif _update_building_focus(ground as Vector3):
				_clear_veg_focus()
			elif _is_vegetation_edit_active():
				_update_veg_focus(ground as Vector3)
			else:
				_clear_veg_focus()
		else:
			_clear_solar_focus()
			_clear_building_focus()
			_clear_veg_focus()
	else:
		_clear_solar_focus()
		_clear_building_focus()
		_clear_veg_focus()


func _is_drone_mode() -> bool:
	var v: Variant = _player.get("is_fpv_drone_mode")
	return bool(v) if v != null else false


## Only show/interact with the OSM-vegetation crosshair highlight while the
## vegetation paint dock (V) is already open — otherwise it lights up every
## patch of OSM-tagged vegetation the player merely walks past, which reads as
## distracting noise during normal play.
func _is_vegetation_edit_active() -> bool:
	return _loader != null and _loader.has_method("is_vegetation_edit_active") \
		and bool(_loader.call("is_vegetation_edit_active"))


## Ground point under the crosshair via the loader's long-range (50 km) terrain
## ray — reaches the ground from drone altitude where the on-foot 12 m ray never
## would. Returns a Vector3 or null.
func _ground_pick_center() -> Variant:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return null
	var vp := get_viewport()
	if vp == null:
		return null
	var center := vp.get_visible_rect().size * 0.5
	var p: Variant = _loader.call("terrain_pick_ray", center)
	return p if p is Vector3 else null


func _should_update_focus() -> bool:
	if CursorController.should_capture_look():
		return true
	if CursorController.is_paused():
		return true
	return false


func _raycast_center() -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {}
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var space := _player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LENGTH)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	return space.intersect_ray(query)


func _find_interactable(obj: Object) -> Interactable:
	var node: Node = obj as Node
	while node != null:
		if node is Interactable:
			return node as Interactable
		node = node.get_parent()
	return null


func _clear_focus() -> void:
	if _focused != null:
		_focused.on_focus_exit(_player)
		_focused = null
	_update_ui()


func _update_building_focus(hit_pos: Vector3) -> bool:
	if _loader == null or not _loader.has_method("pick_building_at_world"):
		return false
	var pick: Dictionary = _loader.call("pick_building_at_world", hit_pos.x, hit_pos.z)
	if not bool(pick.get("valid", false)):
		_clear_building_focus()
		return false
	var idx := int(pick.get("building_idx", -1))
	if _loader.has_method("is_building_replaced") and bool(_loader.call("is_building_replaced", idx)):
		_clear_building_focus()
		return false
	if _loader.has_method("set_building_focus_idx"):
		_loader.call("set_building_focus_idx", idx)
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(true)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		var act := "Interact"
		if _prompt_ui != null and _prompt_ui.has_method("get_action_label"):
			act = _prompt_ui.get_action_label("interact")
		_crosshair.set_prompt_text("[%s] Customize building" % act)
	return true


func _clear_building_focus() -> void:
	if _loader != null and _loader.has_method("set_building_focus_idx"):
		if int(_loader.call("get_building_focus_idx")) >= 0:
			_loader.call("set_building_focus_idx", -1)
	if _focused != null:
		return
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(false)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		_crosshair.set_prompt_text("")


func _update_veg_focus(hit_pos: Vector3) -> bool:
	if _loader == null or not _loader.has_method("pick_veg_area_at_world"):
		return false
	var pick: Dictionary = _loader.call("pick_veg_area_at_world", hit_pos.x, hit_pos.z)
	if not bool(pick.get("valid", false)):
		_clear_veg_focus()
		return false
	var idx := int(pick.get("area_idx", -1))
	if _loader.has_method("set_veg_focus_idx"):
		_loader.call("set_veg_focus_idx", idx)
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(true)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		var act := "Interact"
		if _prompt_ui != null and _prompt_ui.has_method("get_action_label"):
			act = _prompt_ui.get_action_label("interact")
		_crosshair.set_prompt_text("[%s] Tune %s look" % [act, str(pick.get("kind_label", "vegetation"))])
	return true


func _clear_veg_focus() -> void:
	if _loader != null and _loader.has_method("set_veg_focus_idx") \
			and _loader.has_method("get_veg_focus_idx"):
		if int(_loader.call("get_veg_focus_idx")) >= 0:
			_loader.call("set_veg_focus_idx", -1)
	if _focused != null:
		return
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(false)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		_crosshair.set_prompt_text("")


func _update_solar_focus(hit_pos: Vector3) -> bool:
	if _loader == null or not _loader.has_method("pick_solar_array_at_world"):
		return false
	var pick: Dictionary = _loader.call("pick_solar_array_at_world", hit_pos.x, hit_pos.z)
	if not bool(pick.get("valid", false)):
		_clear_solar_focus()
		return false
	var idx := int(pick.get("array_idx", -1))
	_solar_focus_idx = idx
	if _loader.has_method("set_solar_array_focus_idx"):
		_loader.call("set_solar_array_focus_idx", idx)
	var info: Dictionary = {}
	if _loader.has_method("get_solar_array_info"):
		info = _loader.call("get_solar_array_info", idx)
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(true)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		if bool(info.get("added", false)):
			_crosshair.set_prompt_text("Solar array added (%d panels)" % int(info.get("panel_count", 0)))
		else:
			var act := "Interact"
			if _prompt_ui != null and _prompt_ui.has_method("get_action_label"):
				act = _prompt_ui.get_action_label("interact")
			_crosshair.set_prompt_text("[%s] Add solar array to graph — %d panels, %.1f kW" % [
				act, int(info.get("panel_count", 0)), float(info.get("capacity_kw", 0.0))])
	return true


func _clear_solar_focus() -> void:
	_solar_focus_idx = -1
	if _loader != null and _loader.has_method("set_solar_array_focus_idx"):
		if _loader.has_method("get_solar_array_focus_idx") \
				and int(_loader.call("get_solar_array_focus_idx")) >= 0:
			_loader.call("set_solar_array_focus_idx", -1)


func _update_ui() -> void:
	if _crosshair != null:
		if _crosshair.has_method("set_target_active"):
			_crosshair.set_target_active(_focused != null)
		if _crosshair.has_method("set_prompt_text"):
			if _focused != null:
				var lbl := _focused.get_prompt_text()
				if _prompt_ui != null and _prompt_ui.has_method("get_action_label"):
					lbl = "[%s] %s" % [_prompt_ui.get_action_label(_focused.get_action_name()), lbl]
				_crosshair.set_prompt_text(lbl)
			else:
				_crosshair.set_prompt_text("")


func _find_ui() -> void:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var ui_layer := tree.current_scene.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	_crosshair = ui_layer.get_node_or_null("CrosshairUI")
	_prompt_ui = ui_layer.get_node_or_null("InteractionPromptUI")


func _unhandled_input(event: InputEvent) -> void:
	if _player == null:
		return
	if not CursorController.should_capture_look():
		return
	var is_interact := event.is_action_pressed("interact")
	var is_veg_edit := event.is_action_pressed("vegetation_area_edit")
	if not is_interact and not is_veg_edit:
		return
	# NOTE: "vegetation_area_edit" shares the O key with "interact" (see
	# project.godot), so both fire on the same keypress. A genuinely focused
	# Interactable (SoI marker, placed prop, etc.) must win — vegetation-area
	# tuning is only reached via the _try_open_veg_area() fallback below once
	# nothing else (interactable / solar / building) is focused. Do NOT
	# short-circuit on is_veg_edit here, or focused Interactables never get
	# their interact() call.
	if _focused != null and is_instance_valid(_focused):
		if _focused is PlacedProp:
			return
		_focused.interact(_player)
		get_viewport().set_input_as_handled()
		return
	# No interactable under the crosshair — add a targeted OSM solar array to the graph.
	if _solar_focus_idx >= 0 and _loader != null \
			and _loader.has_method("add_solar_array_to_graph"):
		if _loader.has_method("is_solar_array_added") \
				and bool(_loader.call("is_solar_array_added", _solar_focus_idx)):
			return
		if bool(_loader.call("add_solar_array_to_graph", _solar_focus_idx)):
			get_viewport().set_input_as_handled()
		return
	# Focused OSM building → open the Building Builder modal.
	if _loader != null and _loader.has_method("get_building_focus_idx") \
			and _loader.has_method("open_building_builder"):
		var bidx := int(_loader.call("get_building_focus_idx"))
		if bidx >= 0:
			_loader.call("open_building_builder", bidx)
			get_viewport().set_input_as_handled()
			return
	# Otherwise a focused OSM veg area → open its Tune look modal.
	_try_open_veg_area()


func _try_open_veg_area() -> bool:
	if _loader == null or not _loader.has_method("get_veg_focus_idx") \
			or not _loader.has_method("open_veg_area_modal"):
		return false
	var vidx := int(_loader.call("get_veg_focus_idx"))
	if vidx < 0:
		return false
	_loader.call("open_veg_area_modal", vidx)
	get_viewport().set_input_as_handled()
	return true
