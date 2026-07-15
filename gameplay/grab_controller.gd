extends Node

## Alt+focus a placed prop (see interaction_focus.gd — crosshair focus is only
## ever live while Alt is held), then either quick-click to open its edit panel
## or hold LMB and drag to reposition it: the real prop follows the crosshair's
## terrain hit point every physics frame, exactly like the initial placement
## ghost, and releasing LMB commits the new spot. Esc cancels a drag in progress.

const HOLD_THRESHOLD_S := 0.2
const MAX_GRAB_DISTANCE := 12.0

var _player: Node3D = null
var _camera: Camera3D = null
var _focus: Node = null
var _loader: Node = null

var _lmb_down := false
var _hold_timer := 0.0
var _hold_triggered := false
var _pending_prop: PlacedProp = null
var _moving_prop: PlacedProp = null
var _moving_valid := false


func setup(player: Node3D, camera: Camera3D, focus: Node, loader: Node) -> void:
	_player = player
	_camera = camera
	_focus = focus
	_loader = loader


func is_grabbing() -> bool:
	return _moving_prop != null


func blocks_tool_use() -> bool:
	if PlacedPropService.is_placement_active():
		return true
	if is_grabbing():
		return true
	if _lmb_down and _pending_prop != null:
		return true
	if _focus != null and _focus.has_method("get_focused"):
		var focused: Variant = _focus.call("get_focused")
		if focused is Object and is_instance_valid(focused) and focused is PlacedProp \
				and (_lmb_down or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
			return true
	return false


func get_grabbed_prop() -> PlacedProp:
	return _moving_prop


func release_prop_refs() -> void:
	_pending_prop = null
	_moving_prop = null
	_lmb_down = false
	_hold_timer = 0.0
	_hold_triggered = false


func _physics_process(delta: float) -> void:
	if _pending_prop != null and not is_instance_valid(_pending_prop):
		_pending_prop = null
	if _moving_prop != null and not is_instance_valid(_moving_prop):
		_moving_prop = null
	if PlacedPropService.is_placement_active():
		return
	# Disable hold/grab in drone mode
	var drone := false
	if _player != null and _player.has_method("is_fpv_drone_mode"):
		drone = bool(_player.call("is_fpv_drone_mode"))
	if drone:
		return
	if _moving_prop != null:
		_update_move_position()
		return
	if not _lmb_down or _pending_prop == null or _hold_triggered:
		return
	# Also disable grabbing if the prop is too far away
	if _camera != null and is_instance_valid(_pending_prop):
		var dist := _camera.global_position.distance_to(_pending_prop.global_position)
		if dist > MAX_GRAB_DISTANCE:
			return
	_hold_timer += delta
	if _hold_timer >= HOLD_THRESHOLD_S:
		_start_move(_pending_prop)


func _unhandled_input(event: InputEvent) -> void:
	if PlacedPropService.is_placement_active():
		return
	if _player == null:
		return
	if is_grabbing() and event.is_action_pressed("ui_cancel"):
		_cancel_move()
		get_viewport().set_input_as_handled()
		return
	if not _can_handle_input():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_lmb_down()
		else:
			_on_lmb_up()
		if _pending_prop != null or is_grabbing():
			get_viewport().set_input_as_handled()


func _can_handle_input() -> bool:
	if CursorController.should_capture_look():
		return true
	if CursorController.is_paused() and _focus != null and _focus.has_method("get_focused"):
		var focused: Variant = _focus.call("get_focused")
		return focused is Object and is_instance_valid(focused) and focused is PlacedProp
	return false


func _on_lmb_down() -> void:
	_lmb_down = true
	_hold_timer = 0.0
	_hold_triggered = false
	_pending_prop = null
	if _focus == null or not _focus.has_method("get_focused"):
		return
	var focused: Variant = _focus.call("get_focused")
	if focused is Object and is_instance_valid(focused) and focused is PlacedProp:
		_pending_prop = focused as PlacedProp


func _on_lmb_up() -> void:
	if is_grabbing():
		_confirm_move()
	elif _pending_prop != null and not _hold_triggered:
		_open_edit_panel(_pending_prop)
	_lmb_down = false
	_hold_timer = 0.0
	_hold_triggered = false
	_pending_prop = null


func _start_move(prop: PlacedProp) -> void:
	if prop == null or is_grabbing():
		return
	_hold_triggered = true
	_moving_prop = prop
	_moving_valid = false
	prop.on_focus_exit(_player)
	if _focus != null and _focus.has_method("clear_focus"):
		_focus.call("clear_focus")
	# Disable collision for the duration of the drag: it's about to be carried
	# through walls/terrain/other props on its way to a new spot, and leaving
	# collision on would snag the player's own body against it and let the
	# crosshair raycast re-focus the very prop being moved.
	prop.set_collision_enabled(false)


## Follows the crosshair's terrain hit exactly like PlacedPropService's
## placement ghost (core/placed_models/placed_prop_service.gd:update_placement_aim) —
## same ray, same foot-grounding math — so dragging feels identical to placing
## the model fresh.
func _update_move_position() -> void:
	if _moving_prop == null or _camera == null:
		return
	var main := _main_node()
	if main == null:
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, _camera)
	if hit.is_empty():
		_moving_valid = false
		return
	var pos: Vector3 = hit["position"] as Vector3
	var model := _moving_prop.get_node_or_null("ModelRoot") as Node3D
	var foot_y := ModelCatalog.foot_local_y(_moving_prop.model_id)
	var ws := model.scale.x if model != null else 1.0
	_moving_prop.global_position = Vector3(pos.x, pos.y - foot_y * ws, pos.z)
	_moving_valid = true


func _confirm_move() -> void:
	var prop := _moving_prop
	_moving_prop = null
	if prop == null or _loader == null:
		return
	if _moving_valid and _loader.has_method("save_prop_from_node"):
		_loader.call("save_prop_from_node", prop)
	# Rebuilds from the saved record either way — restores the prop's normal
	# (or still-disabled, per its own toggle) collision state, and snaps back to
	# its last saved spot if the crosshair wasn't over valid ground on release.
	if _loader.has_method("rebuild_placed_props"):
		_loader.call("rebuild_placed_props")


func _cancel_move() -> void:
	_moving_prop = null
	_lmb_down = false
	_hold_triggered = false
	_pending_prop = null
	if _loader != null and _loader.has_method("rebuild_placed_props"):
		_loader.call("rebuild_placed_props")


func _open_edit_panel(prop: PlacedProp) -> void:
	if prop == null:
		return
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var edit_ui := tree.current_scene.get_node_or_null("UILayer/PlacedPropEditUI")
	if edit_ui != null and edit_ui.has_method("open_for_prop"):
		edit_ui.call("open_for_prop", prop.prop_id)


func _main_node() -> Node:
	if _loader != null and _loader.get_parent() != null:
		return _loader.get_parent()
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene
