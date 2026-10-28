extends Node

## Alt/Ctrl+focus a placed prop (see interaction_focus.gd — crosshair focus is
## only ever live while Alt/Ctrl is held), then either quick-click to open its
## edit panel or LMB-DRAG to reposition it: the real prop follows the crosshair's
## terrain hit point every physics frame, exactly like the initial placement
## ghost, and releasing LMB commits the new spot. Esc cancels a drag in progress.
##
## The move is triggered by DRAG DISTANCE, not a timed hold: a single click that
## doesn't move the mouse opens the modal, while any drag past DRAG_START_PX picks
## the prop up. (A timed hold used to fire even on a slow, stationary click, which
## could nudge a prop the player only meant to open — and a fast drag never
## reached the hold threshold, so it wrongly opened the modal instead of moving.)

const DRAG_START_PX := 6.0
## Reach measured to the NEAREST point of the prop's pick AABB (not its origin),
## so large structures (StarShade, pallet racks) viewed from farther back still
## grab — an origin-only 12 m cap blocked anything you had to stand back to see.
const MAX_GRAB_DISTANCE := 60.0

var _player: Node3D = null
var _camera: Camera3D = null
var _focus: Node = null
var _loader: Node = null

var _lmb_down := false
var _drag_accum := 0.0
var _hold_triggered := false      # set once a move has begun (drag detected)
var _pending_prop: PlacedProp = null
var _moving_prop: PlacedProp = null
var _moving_valid := false
# Relocatable world markers (e.g. the SoI origin pin) that aren't PlacedProps but
# implement the world_drag_commit()/world_drag_click() contract. Dragged with the
# same crosshair-follow feel; on release the marker decides what the drop means.
var _pending_marker: Node3D = null
var _moving_marker: Node3D = null
## Where a self-aiming marker wants to land (world_drag_aim). A marker that
## implements world_drag_preview(pos) is NOT moved by this controller — it
## shows the drag itself (a J string light moves every pin, or a fresh copy) —
## so the commit must be handed this point, not the marker's own position.
var _marker_target := Vector3.ZERO


func setup(player: Node3D, camera: Camera3D, focus: Node, loader: Node) -> void:
	_player = player
	_camera = camera
	_focus = focus
	_loader = loader


func is_grabbing() -> bool:
	return _moving_prop != null or _moving_marker != null


func blocks_tool_use() -> bool:
	if PlacedPropService.is_placement_active():
		return true
	if is_grabbing():
		return true
	if _lmb_down and (_pending_prop != null or _pending_marker != null):
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
	_pending_marker = null
	_moving_marker = null
	_lmb_down = false
	_drag_accum = 0.0
	_hold_triggered = false


func _physics_process(_delta: float) -> void:
	if _pending_prop != null and not is_instance_valid(_pending_prop):
		_pending_prop = null
	if _moving_prop != null and not is_instance_valid(_moving_prop):
		_moving_prop = null
	if _pending_marker != null and not is_instance_valid(_pending_marker):
		_pending_marker = null
	if _moving_marker != null and not is_instance_valid(_moving_marker):
		_moving_marker = null
	if PlacedPropService.is_placement_active():
		return
	if _is_drone_mode():
		return
	if _moving_prop != null:
		_update_move_position()
	elif _moving_marker != null:
		_update_marker_position()


func _is_drone_mode() -> bool:
	if _player != null and _player.has_method("is_fpv_drone_mode"):
		return bool(_player.call("is_fpv_drone_mode"))
	return false


func _within_grab_distance(prop: PlacedProp) -> bool:
	if _camera == null or prop == null or not is_instance_valid(prop):
		return false
	var cam := _camera.global_position
	var aabb := AABB()
	if prop.has_method("get_world_pick_aabb"):
		aabb = prop.get_world_pick_aabb()
	if aabb.size.length_squared() <= 0.0001:
		return cam.distance_to(prop.global_position) <= MAX_GRAB_DISTANCE
	# Distance to the nearest point on the world-space pick AABB.
	var mx := aabb.position + aabb.size
	var near := Vector3(
		clampf(cam.x, aabb.position.x, mx.x),
		clampf(cam.y, aabb.position.y, mx.y),
		clampf(cam.z, aabb.position.z, mx.z))
	return cam.distance_to(near) <= MAX_GRAB_DISTANCE


func _is_printed(prop: PlacedProp) -> bool:
	return prop != null and is_instance_valid(prop) and prop.has_meta("printed_job_id")


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
	# LMB held over a focused prop + mouse moved past the drag threshold → pick it
	# up. Do NOT consume the motion: the camera still turns (captured-look) so the
	# prop follows the crosshair, exactly like fresh placement.
	if event is InputEventMouseMotion:
		if _lmb_down and not _hold_triggered and not is_grabbing() and not _is_drone_mode():
			_drag_accum += (event as InputEventMouseMotion).relative.length()
			if _drag_accum >= DRAG_START_PX:
				if _pending_prop != null and _within_grab_distance(_pending_prop):
					_start_move(_pending_prop)
				elif _pending_marker != null and _within_grab_distance_node(_pending_marker):
					_start_marker_move(_pending_marker)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_lmb_down()
		else:
			_on_lmb_up()
		if _pending_prop != null or _pending_marker != null or is_grabbing():
			get_viewport().set_input_as_handled()
		return
	# Ctrl/Alt + RMB quick-opens the prop editor (Print modal for trash/mud
	# printers) without starting a drag — matches the "select with Ctrl+RMB" ask.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.pressed and not event.double_click:
		if _focus == null or not _focus.has_method("get_focused"):
			return
		var focused: Variant = _focus.call("get_focused")
		if focused is Object and is_instance_valid(focused) and focused is PlacedProp:
			_open_edit_panel(focused as PlacedProp)
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
	_drag_accum = 0.0
	_hold_triggered = false
	_pending_prop = null
	_pending_marker = null
	if _focus == null or not _focus.has_method("get_focused"):
		return
	var focused: Variant = _focus.call("get_focused")
	if focused is Object and is_instance_valid(focused) and focused is PlacedProp:
		_pending_prop = focused as PlacedProp
	elif _is_relocatable_marker(focused):
		_pending_marker = focused as Node3D


func _on_lmb_up() -> void:
	if _moving_prop != null:
		_confirm_move()
	elif _moving_marker != null:
		_confirm_marker_move()
	elif _pending_prop != null and not _hold_triggered:
		# A click with no drag → open the edit modal.
		_open_edit_panel(_pending_prop)
	elif _pending_marker != null and not _hold_triggered:
		# A click with no drag → the marker's default action (SoI: open Snowglobe).
		_click_marker(_pending_marker)
	_lmb_down = false
	_drag_accum = 0.0
	_hold_triggered = false
	_pending_prop = null
	_pending_marker = null


func _start_move(prop: PlacedProp) -> void:
	if prop == null or is_grabbing():
		return
	_hold_triggered = true
	_moving_prop = prop
	_moving_valid = false
	prop.on_focus_exit(_player)
	if _focus != null and _focus.has_method("clear_focus"):
		_focus.call("clear_focus")
	# Keep the prop visibly highlighted (amber) while it's carried, since crosshair
	# focus — and its outline — was just cleared for the drag.
	if prop.has_method("set_move_highlight"):
		prop.set_move_highlight(true)
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
	# Printed objects have no catalog entry (their mesh base already sits at y=0),
	# so their foot offset is zero.
	var foot_y := 0.0 if _is_printed(_moving_prop) else ModelCatalog.foot_local_y(_moving_prop.model_id)
	var ws := model.scale.x if model != null else 1.0
	_moving_prop.global_position = Vector3(pos.x, pos.y - foot_y * ws, pos.z)
	_moving_valid = true


func _confirm_move() -> void:
	var prop := _moving_prop
	_moving_prop = null
	if prop != null and is_instance_valid(prop) and prop.has_method("set_move_highlight"):
		prop.set_move_highlight(false)
	if prop == null or _loader == null:
		return
	# Printed (mud/clay/concrete) objects persist in their own sidecar, not the
	# placed-prop layer: write the new world transform and re-enable collision on
	# the live node (no layer rebuild — it isn't a layer prop).
	if _is_printed(prop):
		if _moving_valid and _loader.has_method("update_printed_object_transform"):
			var mr := prop.get_node_or_null("ModelRoot") as Node3D
			var xf := mr.global_transform if mr != null else prop.global_transform
			_loader.call("update_printed_object_transform", str(prop.get_meta("printed_job_id", "")), xf)
		if not _moving_valid and _loader.has_method("reload_printed_objects"):
			_loader.call("reload_printed_objects")   # bad release spot → snap back
		else:
			prop.set_collision_enabled(true)
		return
	if _moving_valid and _loader.has_method("save_prop_from_node"):
		_loader.call("save_prop_from_node", prop)
	# Rebuilds from the saved record either way — restores the prop's normal
	# (or still-disabled, per its own toggle) collision state, and snaps back to
	# its last saved spot if the crosshair wasn't over valid ground on release.
	if _loader.has_method("rebuild_placed_props"):
		_loader.call("rebuild_placed_props")


func _cancel_move() -> void:
	if _moving_marker != null:
		var marker := _moving_marker
		_moving_marker = null
		_lmb_down = false
		_drag_accum = 0.0
		_hold_triggered = false
		_pending_marker = null
		# Snap the pin back to the committed centre (drag discarded).
		if is_instance_valid(marker) and marker.has_method("world_drag_cancel"):
			marker.call("world_drag_cancel")
		elif is_instance_valid(marker) and marker.has_method("sync_position"):
			marker.call("sync_position")
		return
	var prop := _moving_prop
	if prop != null and is_instance_valid(prop) and prop.has_method("set_move_highlight"):
		prop.set_move_highlight(false)
	var printed := _is_printed(prop)
	_moving_prop = null
	_lmb_down = false
	_drag_accum = 0.0
	_hold_triggered = false
	_pending_prop = null
	if _loader == null:
		return
	if printed:
		if _loader.has_method("reload_printed_objects"):
			_loader.call("reload_printed_objects")
	elif _loader.has_method("rebuild_placed_props"):
		_loader.call("rebuild_placed_props")


func _open_edit_panel(prop: PlacedProp) -> void:
	if prop == null:
		return
	# Printed objects are move-only (no edit modal).
	if _is_printed(prop):
		return
	# Route the click to the same edit UI the Interact key uses (StarShade editor,
	# CNC print modal, pallet-rack builder, else the generic prop panel) so every
	# selectable model opens its proper editor on a no-drag click.
	if _focus != null and _focus.has_method("open_prop_edit_ui"):
		_focus.call("open_prop_edit_ui", prop)
		return
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	if prop.model_id == PalletRackBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_pallet_rack_builder_for_prop"):
			_loader.call("open_pallet_rack_builder_for_prop", prop.prop_id)
			return
	if prop.model_id == FlatpackBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_flatpack_designer_for_prop"):
			_loader.call("open_flatpack_designer_for_prop", prop.prop_id)
			return
	if prop.model_id == DomeLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_domelab_for_prop"):
			_loader.call("open_domelab_for_prop", prop.prop_id)
			return
	if prop.model_id == ToroidLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_toroidlab_for_prop"):
			_loader.call("open_toroidlab_for_prop", prop.prop_id)
			return
	if prop.model_id == PvLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_pvlab_for_prop"):
			_loader.call("open_pvlab_for_prop", prop.prop_id)
			return
	if prop.model_id == GantryLabBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_gantrylab_for_prop"):
			_loader.call("open_gantrylab_for_prop", prop.prop_id)
			return
	var edit_ui := tree.current_scene.get_node_or_null("UILayer/PlacedPropEditUI")
	if edit_ui != null and edit_ui.has_method("open_for_prop"):
		edit_ui.call("open_for_prop", prop.prop_id)


func _is_relocatable_marker(o: Variant) -> bool:
	return o is Node3D and is_instance_valid(o) and (o as Object).has_method("world_drag_commit")


func _within_grab_distance_node(node: Node3D) -> bool:
	if _camera == null or node == null or not is_instance_valid(node):
		return false
	# A marker may set its own reach (a draft outlet sits down the hill, well
	# past the 60 m a placed light is grabbed from).
	var reach := MAX_GRAB_DISTANCE
	if node.has_method("grab_distance_m"):
		reach = maxf(float(node.call("grab_distance_m")), MAX_GRAB_DISTANCE)
	return _camera.global_position.distance_to(node.global_position) <= reach


func _start_marker_move(marker: Node3D) -> void:
	if marker == null or is_grabbing():
		return
	_hold_triggered = true
	_moving_marker = marker
	_moving_valid = false
	_marker_target = marker.global_position
	# Optional: the marker decides what this drag IS from the modifiers held
	# as it starts (a J light: Ctrl+Shift = duplicate, then move the copy).
	if marker.has_method("world_drag_begin"):
		marker.call("world_drag_begin")
	# Drop crosshair focus (and its outline) for the carry, like a picked-up prop.
	if _focus != null and _focus.has_method("clear_focus"):
		_focus.call("clear_focus")


## Follows the crosshair's terrain hit exactly like the prop drag / placement
## ghost. The pin's origin sits on the ground (its mesh is built base-at-origin),
## so the terrain hit is the drop point directly — no foot offset.
func _update_marker_position() -> void:
	if _moving_marker == null or _camera == null:
		return
	var main := _main_node()
	if main == null:
		return
	# A marker may aim itself (a placed light hangs on walls and props, not
	# only the ground) — it returns the drop point, or null for "no valid spot".
	if _moving_marker.has_method("world_drag_aim"):
		var p: Variant = _moving_marker.call("world_drag_aim", _camera)
		_moving_valid = p is Vector3
		if _moving_valid:
			_marker_target = p
			if _moving_marker.has_method("world_drag_preview"):
				_moving_marker.call("world_drag_preview", p)
			else:
				_moving_marker.global_position = p
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, _camera)
	if hit.is_empty():
		_moving_valid = false
		return
	_moving_marker.global_position = hit["position"] as Vector3
	_moving_valid = true


func _confirm_marker_move() -> void:
	var marker := _moving_marker
	_moving_marker = null
	if marker == null or not is_instance_valid(marker):
		return
	if _moving_valid and marker.has_method("world_drag_commit"):
		# The marker owns what the drop means (SoI pin → new map origin).
		var previewing: bool = marker.has_method("world_drag_preview")
		var drop: Vector3 = _marker_target if previewing else marker.global_position
		marker.call("world_drag_commit", drop)
	elif marker.has_method("sync_position"):
		marker.call("sync_position")   # released off valid ground → snap back


func _click_marker(marker: Node3D) -> void:
	if marker != null and is_instance_valid(marker) and marker.has_method("world_drag_click"):
		marker.call("world_drag_click")


func _main_node() -> Node:
	if _loader != null and _loader.get_parent() != null:
		return _loader.get_parent()
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene
