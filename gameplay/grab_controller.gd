extends Node

## LMB hold to carry placed props; quick click opens edit panel.

const HOLD_THRESHOLD_S := 0.2

var _player: Node3D = null
var _camera: Camera3D = null
var _focus: Node = null
var _loader: Node = null
var _hold_anchor: Marker3D = null

var _lmb_down := false
var _hold_timer := 0.0
var _hold_triggered := false
var _pending_prop: PlacedProp = null
var _grabbed_prop: PlacedProp = null


func setup(player: Node3D, camera: Camera3D, focus: Node, loader: Node) -> void:
	_player = player
	_camera = camera
	_focus = focus
	_loader = loader
	_hold_anchor = Marker3D.new()
	_hold_anchor.name = "PropHoldAnchor"
	_hold_anchor.position = Vector3(0.0, 0.5, -1.2)
	player.add_child(_hold_anchor)


func is_grabbing() -> bool:
	return _grabbed_prop != null


func blocks_tool_use() -> bool:
	if PlacedPropService.is_placement_active():
		return true
	if is_grabbing():
		return true
	if _lmb_down and _pending_prop != null:
		return true
	if _focus != null and _focus.has_method("get_focused"):
		var focused: Variant = _focus.call("get_focused")
		if focused is PlacedProp and (_lmb_down or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
			return true
	return false


func get_grabbed_prop() -> PlacedProp:
	return _grabbed_prop


func _physics_process(delta: float) -> void:
	if PlacedPropService.is_placement_active():
		return
	if not _lmb_down or _pending_prop == null or _hold_triggered:
		if _grabbed_prop != null and _hold_anchor != null:
			_grabbed_prop.global_transform = _hold_anchor.global_transform
		return
	_hold_timer += delta
	if _hold_timer >= HOLD_THRESHOLD_S:
		_start_grab(_pending_prop)


func _unhandled_input(event: InputEvent) -> void:
	if PlacedPropService.is_placement_active():
		return
	if _player == null:
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
		return focused is PlacedProp
	return false


func _on_lmb_down() -> void:
	_lmb_down = true
	_hold_timer = 0.0
	_hold_triggered = false
	_pending_prop = null
	if _focus == null or not _focus.has_method("get_focused"):
		return
	var focused: Variant = _focus.call("get_focused")
	if focused is PlacedProp:
		_pending_prop = focused as PlacedProp


func _on_lmb_up() -> void:
	if is_grabbing():
		_drop_grabbed()
	elif _pending_prop != null and not _hold_triggered:
		_open_edit_panel(_pending_prop)
	_lmb_down = false
	_hold_timer = 0.0
	_hold_triggered = false
	_pending_prop = null


func _start_grab(prop: PlacedProp) -> void:
	if prop == null or is_grabbing():
		return
	_hold_triggered = true
	_grabbed_prop = prop
	prop.on_focus_exit(_player)
	if _focus != null and _focus.has_method("clear_focus"):
		_focus.call("clear_focus")
	prop.global_transform = _hold_anchor.global_transform


func _drop_grabbed() -> void:
	if _grabbed_prop == null or _loader == null:
		_grabbed_prop = null
		return
	var prop := _grabbed_prop
	_grabbed_prop = null
	if _loader.has_method("save_prop_from_node"):
		_loader.call("save_prop_from_node", prop)
	if _loader.has_method("rebuild_placed_props"):
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
