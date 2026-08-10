extends Node

## Center-screen raycast focus for Interactable nodes + OSM building pick fallback.

const RAY_LENGTH: float = 2000.0

var _player: Node3D = null
var _camera: Camera3D = null
var _focused: Interactable = null
var _crosshair: CanvasLayer = null
var _prompt_ui: CanvasLayer = null
var _loader: Node = null
var _solar_focus_idx: int = -1
var _water_focus_idx: int = -1
var _conduit_focus_id: String = ""
var _conduit_focus_hang_edit: bool = false
var _last_graph_sync_key: String = ""


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


## Cached like _loader/_crosshair. This was resolved by NAME every physics tick,
## which is a subtree lookup 60×/second for a node that never moves.
var _route_ctrl: Node = null
var _route_ctrl_looked_up := false


func _get_route_controller() -> Node:
	if _route_ctrl != null and is_instance_valid(_route_ctrl):
		return _route_ctrl
	# Re-look-up only after the cached node dies, not every miss: on a scene with
	# no ConduitRouteController the answer is permanently null, and retrying each
	# tick would reinstate the per-frame cost this cache exists to remove.
	if _route_ctrl_looked_up and _route_ctrl == null:
		return null
	_route_ctrl_looked_up = true
	_route_ctrl = _player.get_node_or_null("ConduitRouteController") if _player != null else null
	return _route_ctrl


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
	var route_ctrl: Node = _get_route_controller()
	if route_ctrl != null and route_ctrl.has_method("is_routing") \
			and bool(route_ctrl.call("is_routing")):
		_clear_focus()
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		# Do NOT clear hang gizmos — ConduitRouteController owns the drag sphere.
		if not _conduit_focus_id.is_empty():
			_conduit_focus_id = ""
			_conduit_focus_hang_edit = false
			var mgr := _conduit_manager()
			if mgr != null and mgr.has_method("set_focus_highlight"):
				mgr.call("set_focus_highlight", "")
		return
	if not _can_aim_focus():
		_clear_focus()
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		_clear_conduit_focus()
		return
	# Light place mode (J): Ctrl/Alt select is lights-only — never steal focus with
	# Man Effigy / buildings / solar while aiming a lamp.
	var light_place := PlacedLightService.is_placement_active()
	# 3D conduits are thin — hover / hang-edit IK spheres do NOT require Ctrl/Alt.
	# Prefer a wire under the crosshair before Ctrl-gated prop/OSM picks.
	if not light_place and _update_conduit_focus():
		if _focused != null:
			_focused.on_focus_exit(_player)
			_focused = null
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		_update_ui()
		_sync_graph_from_conduit_focus()
		return
	_clear_conduit_focus()
	# Props / OSM buildings / solar still require Ctrl or Alt (too easy to highlight).
	if not _should_update_focus():
		_clear_focus()
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		# In a session, people are pickable WITHOUT the modifier: possession is
		# the main thing a guest does, and making them hold Alt to look at
		# someone hides the feature entirely. Deliberately scoped to
		# multiplayer so single-player crosshair behaviour is unchanged.
		if _in_multiplayer_session():
			_update_npc_focus()
		else:
			_clear_npc_focus()
		return
	var next: Interactable = null
	# Finished mud prints sit inside the printer hull and may only have an Area3D
	# pick proxy — check them BEFORE accepting a CNC machine physics hit.
	if not light_place:
		var printed_first := _pick_printed_prop_aabb()
		if printed_first != null:
			next = printed_first
	var hit := _raycast_center()
	if next == null and hit.has("collider"):
		next = _find_interactable(hit.collider as Object)
		if next != null and not next.can_interact(_player):
			next = null
		if light_place and next != null and not (next is PlacedLight):
			next = null
		if next != null:
			var dist: float = _camera.global_position.distance_to(hit.position)
			var max_dist := next.max_distance
			if next is PlacedProp or next is PlacedLight:
				max_dist = RAY_LENGTH
			if dist > max_dist:
				next = null
		# Physics hit the printer (or its frame) — still prefer a printed prop
		# under the crosshair when the Area3D/AABB check finds one.
		if not light_place and next is PlacedProp \
				and (next as PlacedProp).get_node_or_null("CncMachineRuntime") != null:
			var printed := _pick_printed_prop_aabb()
			if printed != null:
				next = printed
	if next == null:
		if light_place:
			next = _pick_placed_light_aabb()
		else:
			# Scaled / open-frame props often miss the physics ray — AABB fallback.
			next = _pick_placed_prop_aabb()
	if next != _focused:
		if _focused != null:
			_focused.on_focus_exit(_player)
		_focused = next
		if _focused != null:
			_focused.on_focus_enter(_player)
		_update_ui()
		_sync_graph_from_world_focus()
	elif _focused != null:
		_update_ui()
	if light_place:
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		if _focused == null:
			_last_graph_sync_key = ""
		else:
			_sync_graph_from_world_focus()
		return
	if _focused == null and _update_npc_focus():
		# A person standing in front of a building wins over the building.
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		_last_graph_sync_key = ""
		return
	_clear_npc_focus()
	if _focused == null:
		# Long-range ground point under the crosshair → OSM polygon pick. Priority:
		# solar arrays (panels sit on/next to their host footprints) → buildings →
		# vegetation areas (large ground polygons; the most specific target wins).
		var ground: Variant = _ground_pick_center()
		if ground is Vector3:
			if _update_solar_focus(ground as Vector3):
				_clear_water_focus()
				_clear_building_focus()
				_clear_veg_focus()
				_sync_graph_from_world_focus()
			elif _update_water_focus(ground as Vector3):
				_clear_solar_focus()
				_clear_building_focus()
				_clear_veg_focus()
			elif _update_building_focus(ground as Vector3):
				_clear_solar_focus()
				_clear_water_focus()
				_clear_veg_focus()
			elif _update_veg_focus(ground as Vector3):
				_clear_solar_focus()
				_clear_water_focus()
				_clear_building_focus()
			else:
				_clear_water_focus()
				_clear_veg_focus()
				_last_graph_sync_key = ""
		else:
			_clear_solar_focus()
			_clear_water_focus()
			_clear_building_focus()
			_clear_veg_focus()
			_last_graph_sync_key = ""
	else:
		_clear_solar_focus()
		_clear_water_focus()
		_clear_building_focus()
		_clear_veg_focus()
		_sync_graph_from_world_focus()


func _is_drone_mode() -> bool:
	var v: Variant = _player.get("is_fpv_drone_mode")
	return bool(v) if v != null else false


## Historical gate for the OSM-vegetation focus. The "only while the V dock is
## open" condition was INVERTED in practice: the dock requests a CursorController
## modal, which makes _can_aim_focus() bail long before this ran — so the
## dock-open branch was unreachable, and the feature only ever worked through
## the Ctrl/Alt path with the dock CLOSED. The veg focus now rides the same
## Ctrl/Alt gate as buildings/solar (_should_update_focus), which already
## prevents walk-past highlight noise. Kept for any external callers.
func _is_vegetation_edit_active() -> bool:
	if _is_alt_selection_active():
		return true
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


## Look-capture / pause — enough for thin conduit hover (no Ctrl required).
func _can_aim_focus() -> bool:
	if CursorController.should_capture_look():
		return true
	if CursorController.is_paused():
		return true
	return false


## Props / OSM / buildings still require Ctrl or Alt so they don't light up constantly.
func _should_update_focus() -> bool:
	if not _is_alt_selection_active():
		return false
	return _can_aim_focus()


func _is_alt_selection_active() -> bool:
	var gv := _graph_view()
	if gv != null and bool(gv.get("visible")):
		return false
	# Alt is the documented modifier; Ctrl is accepted too (common muscle memory).
	return Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_CTRL)


func is_alt_selection_active() -> bool:
	return _is_alt_selection_active()


func _raycast_center() -> Dictionary:
	var vp := get_viewport()
	if vp == null:
		return {}
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var space := _player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LENGTH)
	if _player != null:
		query.exclude = [_player]
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


## Closest PlacedProp whose world pick AABB intersects the center-screen ray.
func _pick_placed_prop_aabb() -> Interactable:
	return _pick_interactable_aabb(PlacedProp)


## Prefer finished mud/clay prints (meta printed_job_id) under the crosshair.
func _pick_printed_prop_aabb() -> Interactable:
	if _camera == null or _player == null:
		return null
	var vp := get_viewport()
	if vp == null:
		return null
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	if dir.length_squared() < 1e-10:
		return null
	dir = dir.normalized()
	var best: Interactable = null
	var best_t := RAY_LENGTH
	for node in get_tree().get_nodes_in_group("interactables"):
		if not (node is PlacedProp):
			continue
		var pp := node as PlacedProp
		if not pp.has_meta("printed_job_id") or not pp.can_interact(_player):
			continue
		var aabb := pp.get_world_pick_aabb()
		if aabb.size.length_squared() < 0.0001:
			continue
		var t := _ray_aabb_enter(origin, dir, aabb)
		if t < 0.0 or t > RAY_LENGTH:
			continue
		if t < best_t:
			best_t = t
			best = pp
	return best


## Closest PlacedLight under the crosshair (light-place select mode).
func _pick_placed_light_aabb() -> Interactable:
	return _pick_interactable_aabb(PlacedLight)


func _pick_interactable_aabb(type_script: Variant) -> Interactable:
	if _camera == null or _player == null:
		return null
	var vp := get_viewport()
	if vp == null:
		return null
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	if dir.length_squared() < 1e-10:
		return null
	dir = dir.normalized()
	var best: Interactable = null
	var best_t := RAY_LENGTH
	var best_score := -INF
	for node in get_tree().get_nodes_in_group("interactables"):
		if type_script == PlacedProp and not (node is PlacedProp):
			continue
		if type_script == PlacedLight and not (node is PlacedLight):
			continue
		var it := node as Interactable
		if it == null or not it.can_interact(_player):
			continue
		var aabb := AABB()
		if it is PlacedProp:
			aabb = (it as PlacedProp).get_world_pick_aabb()
		elif it is PlacedLight:
			aabb = (it as PlacedLight).get_world_pick_aabb()
		else:
			continue
		if aabb.size.length_squared() < 0.0001:
			continue
		var t := _ray_aabb_enter(origin, dir, aabb)
		if t < 0.0 or t > RAY_LENGTH:
			continue
		# Prefer printed / non-machine props when AABBs overlap the mud printer
		# gantry (same footprint) so the finished print is independently selectable.
		var score := -t
		if it is PlacedProp:
			var pp := it as PlacedProp
			if pp.has_meta("printed_job_id"):
				score += 50.0
			elif pp.get_node_or_null("CncMachineRuntime") != null:
				score -= 20.0
			# Smaller AABB = more specific hit.
			score += 1.0 / maxf(aabb.size.length(), 0.5)
		if score > best_score or (is_equal_approx(score, best_score) and t < best_t):
			best_score = score
			best_t = t
			best = it
	return best


## Ray/AABB entry distance along `dir` (unit), or -1 if no hit in front of origin.
static func _ray_aabb_enter(origin: Vector3, dir: Vector3, aabb: AABB) -> float:
	var inv_x := 1.0 / dir.x if absf(dir.x) > 1e-8 else 1e8
	var inv_y := 1.0 / dir.y if absf(dir.y) > 1e-8 else 1e8
	var inv_z := 1.0 / dir.z if absf(dir.z) > 1e-8 else 1e8
	var mn := aabb.position
	var mx := aabb.position + aabb.size
	var tx1 := (mn.x - origin.x) * inv_x
	var tx2 := (mx.x - origin.x) * inv_x
	var ty1 := (mn.y - origin.y) * inv_y
	var ty2 := (mx.y - origin.y) * inv_y
	var tz1 := (mn.z - origin.z) * inv_z
	var tz2 := (mx.z - origin.z) * inv_z
	var enter := maxf(minf(tx1, tx2), maxf(minf(ty1, ty2), minf(tz1, tz2)))
	var exit := minf(maxf(tx1, tx2), minf(maxf(ty1, ty2), maxf(tz1, tz2)))
	if exit < enter or exit < 0.0:
		return -1.0
	return enter if enter >= 0.0 else 0.0


func _clear_focus() -> void:
	if _focused != null:
		_focused.on_focus_exit(_player)
		_focused = null
	_update_ui()
	_last_graph_sync_key = ""


func get_conduit_focus_id() -> String:
	return _conduit_focus_id


func _conduit_manager() -> Node:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.get_node_or_null("ConduitManager")


func _update_conduit_focus() -> bool:
	if _camera == null:
		return false
	var mgr := _conduit_manager()
	if mgr == null or not mgr.has_method("pick_conduit"):
		return false
	var vp := get_viewport()
	if vp == null:
		return false
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var hit: Dictionary = mgr.call("pick_conduit", origin, dir)
	var cid := str(hit.get("conn_id", ""))
	var hit_pt: Vector3 = hit.get("point", Vector3.ZERO) as Vector3
	# Aiming at an existing hang IK sphere (may miss the thin wire).
	# Never acquire NEW focus from orphan pins alone — elevated leftover spheres
	# used to flash full gizmo sets while the camera panned across empty sky.
	var pin_focus := {}
	if mgr.has_method("pick_any_hang_pin"):
		pin_focus = mgr.call("pick_any_hang_pin", origin, dir) as Dictionary
	var pin_cid := str(pin_focus.get("conn_id", ""))
	if not pin_cid.is_empty():
		var pin_d := float(pin_focus.get("distance", INF))
		var wire_d := float(hit.get("distance", INF))
		if not cid.is_empty() and pin_cid == cid and pin_d <= wire_d + 0.05:
			hit_pt = pin_focus.get("position", hit_pt) as Vector3
		elif cid.is_empty() and pin_cid == _conduit_focus_id:
			cid = pin_cid
			hit_pt = pin_focus.get("position", hit_pt) as Vector3
	if cid.is_empty():
		return false
	_conduit_focus_id = cid
	if mgr.has_method("set_focus_highlight"):
		mgr.call("set_focus_highlight", cid)
	var type_id := ""
	var kind := "Conduit"
	var len_m := 0.0
	var pin_edit := false
	var pipe_pin := false
	var hang_pin := false
	var conn := _connection_dict_for_focus(cid)
	if not conn.is_empty():
		type_id = ConduitKinds.derive_type_for_connection(conn)
		var style: Dictionary = conn.get("conduit_style", {}) as Dictionary
		kind = ConduitKinds.display_name_with_size(type_id, style)
		len_m = float(conn.get("route_length_m", 0.0))
		pin_edit = ConduitKinds.supports_pin_edit(type_id)
		pipe_pin = ConduitKinds.supports_pipe_pin_edit(type_id)
		hang_pin = ConduitKinds.supports_hang_edit(type_id)
	# Cached flag: plain LMB left for ConduitRouteController drag (all pin-edit kinds).
	_conduit_focus_hang_edit = pin_edit
	# Hover IK sphere at the exact wire pick (hang / kit / PEX / hose / PVC…).
	if pin_edit and mgr.has_method("update_hang_hover_gizmo") and is_finite(hit_pt.x):
		var routing := false
		var crc := _conduit_route_controller()
		if crc != null and crc.has_method("is_routing"):
			routing = bool(crc.call("is_routing"))
		if not routing:
			mgr.call("update_hang_hover_gizmo", cid, hit_pt, false)
	elif mgr.has_method("clear_hang_gizmos"):
		mgr.call("clear_hang_gizmos")
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(true)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		var len_txt := " · %.1f m" % len_m if len_m > 0.05 else ""
		var on_pin := int(pin_focus.get("index", -1)) >= 0 and pin_cid == cid
		if pipe_pin:
			_crosshair.set_prompt_text(
				"Drag: elbow pin · Shift: axis lock · Double-click: remove · Ctrl+click: style · %s%s" % [kind, len_txt])
		elif hang_pin:
			if on_pin:
				_crosshair.set_prompt_text(
					"Drag: move pin · Double-click: remove · %s%s" % [kind, len_txt])
			else:
				_crosshair.set_prompt_text(
					"Drag: hang pin · Ctrl+click: style · Double-click pin: remove · %s%s" % [kind, len_txt])
		elif pin_edit:
			if on_pin:
				_crosshair.set_prompt_text(
					"Drag: move pin · Shift: axis lock · Double-click: remove · %s%s" % [kind, len_txt])
			else:
				_crosshair.set_prompt_text(
					"Drag: route pin · Shift: axis lock · Ctrl+click: style · %s%s" % [kind, len_txt])
		else:
			_crosshair.set_prompt_text(
				"Interact/click: style · %s%s" % [kind, len_txt])
	return true


func _conduit_route_controller() -> Node:
	# Wired as a child of Player (sibling of InteractionFocus).
	if _player != null:
		var local := _player.get_node_or_null("ConduitRouteController")
		if local != null:
			return local
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.find_child("ConduitRouteController", true, false)


func _connection_dict_for_focus(cid: String) -> Dictionary:
	if cid.is_empty():
		return {}
	var mgr := _conduit_manager()
	if mgr != null and mgr.has_method("get_graph_model"):
		var model: Variant = mgr.call("get_graph_model")
		if model != null and model.has_method("get_connection"):
			var c: Dictionary = model.call("get_connection", cid)
			if not c.is_empty():
				return c
	var gv := _graph_view()
	if gv != null:
		var model2: Variant = gv.get("model")
		if model2 != null and model2.has_method("get_connection"):
			return model2.call("get_connection", cid) as Dictionary
	return {}


func _clear_conduit_focus() -> void:
	# Always clear IK spheres — focus_id may already be empty (routing start /
	# look-away race) while pin orbs are still visible from the last hover.
	var had_focus := not _conduit_focus_id.is_empty()
	_conduit_focus_id = ""
	_conduit_focus_hang_edit = false
	var mgr := _conduit_manager()
	if had_focus and mgr != null and mgr.has_method("set_focus_highlight"):
		mgr.call("set_focus_highlight", "")
	if mgr != null and mgr.has_method("clear_hang_gizmos"):
		mgr.call("clear_hang_gizmos")
	if not had_focus:
		return
	if _focused != null:
		return
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(false)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		_crosshair.set_prompt_text("")


func _sync_graph_from_conduit_focus() -> void:
	var gv := _graph_view()
	if gv == null or not bool(gv.get("visible")):
		return
	if _conduit_focus_id.is_empty():
		return
	var key := "conduit:%s" % _conduit_focus_id
	if key == _last_graph_sync_key:
		return
	_last_graph_sync_key = key
	if gv.has_method("select_connection_by_id"):
		gv.call("select_connection_by_id", _conduit_focus_id)
	elif gv.has_method("inspect_connection_by_id"):
		gv.call("inspect_connection_by_id", _conduit_focus_id)


func _graph_view() -> Node:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var ui := tree.current_scene.get_node_or_null("UILayer")
	if ui == null:
		return null
	return ui.get_node_or_null("SystemGraphView")


func _sync_graph_from_world_focus() -> void:
	var gv := _graph_view()
	if gv == null or not bool(gv.get("visible")):
		return
	var key := ""
	var prop_id := ""
	var osm_tag := ""
	if _focused is PlacedProp:
		prop_id = str((_focused as PlacedProp).prop_id)
		key = "prop:%s" % prop_id
	elif _solar_focus_idx >= 0 and _loader != null:
		if _loader.has_method("get_solar_array_tag"):
			osm_tag = str(_loader.call("get_solar_array_tag", _solar_focus_idx))
		key = "solar:%s" % osm_tag
	if key == _last_graph_sync_key:
		return
	_last_graph_sync_key = key
	if key.is_empty():
		return
	if gv.has_method("select_item_by_world_binding"):
		gv.call("select_item_by_world_binding", prop_id, osm_tag, "")


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
		_crosshair.set_prompt_text("[%s / Click] Customize building" % act)
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
		# Phase 7: this opens the per-area Fill drawer (which still carries a
		# "Tune look…" button through to the all-of-type edit).
		_crosshair.set_prompt_text("[%s / Click] Fill %s" % [act, str(pick.get("kind_label", "vegetation"))])
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
			_crosshair.set_prompt_text("[%s / Click] Add solar array to graph — %d panels, %.1f kW" % [
				act, int(info.get("panel_count", 0)), float(info.get("capacity_kw", 0.0))])
	return true


func _clear_solar_focus() -> void:
	_solar_focus_idx = -1
	if _loader != null and _loader.has_method("set_solar_array_focus_idx"):
		if _loader.has_method("get_solar_array_focus_idx") \
				and int(_loader.call("get_solar_array_focus_idx")) >= 0:
			_loader.call("set_solar_array_focus_idx", -1)


func _update_water_focus(hit_pos: Vector3) -> bool:
	if _loader == null or not _loader.has_method("pick_water_at_world"):
		return false
	var pick: Dictionary = _loader.call("pick_water_at_world", hit_pos.x, hit_pos.z)
	if not bool(pick.get("valid", false)):
		_clear_water_focus()
		return false
	var idx := int(pick.get("water_idx", -1))
	_water_focus_idx = idx
	if _loader.has_method("set_water_focus_idx"):
		_loader.call("set_water_focus_idx", idx)
	if _crosshair != null and _crosshair.has_method("set_target_active"):
		_crosshair.set_target_active(true)
	if _crosshair != null and _crosshair.has_method("set_prompt_text"):
		var act := "Interact"
		if _prompt_ui != null and _prompt_ui.has_method("get_action_label"):
			act = _prompt_ui.get_action_label("interact")
		var suffix := " ✓ on graph" if bool(pick.get("added", false)) else ""
		_crosshair.set_prompt_text("[%s / Click] Pond settings — %.0f m²%s" % [
			act, float(pick.get("area_m2", 0.0)), suffix])
	return true


func _clear_water_focus() -> void:
	_water_focus_idx = -1
	if _loader != null and _loader.has_method("set_water_focus_idx"):
		if _loader.has_method("get_water_focus_idx") \
				and int(_loader.call("get_water_focus_idx")) >= 0:
			_loader.call("set_water_focus_idx", -1)


## Simulated people under the crosshair. Pure software ray-vs-sphere over the
## `npc_avatars` group — NpcAvatars deliberately carry NO collider (a moving
## StaticBody would shove the player around), and 50 dot products per frame is
## far cheaper than adding a physics layer. Shows the person's name + what
## they're doing; read-only (no interact action yet).
const NPC_PICK_RANGE_M := 60.0

var _npc_focus_id: String = ""


func _in_multiplayer_session() -> bool:
	var mp := get_node_or_null("/root/MultiplayerSession")
	return mp != null and bool(mp.call("is_active"))


## Ask the host to let us inhabit the focused person. Returns true when the
## input was consumed (including a refusal — the player gets told why).
## No-op outside multiplayer, so single-player Interact is unchanged.
func _try_possess_npc() -> bool:
	var mp := get_node_or_null("/root/MultiplayerSession")
	if mp == null or not bool(mp.call("is_active")):
		return false
	if bool(mp.call("is_possessing")):
		mp.call("release_possession")
		return true
	var res: Dictionary = mp.call("request_possess", _npc_focus_id)
	return true if bool(res.get("ok", false)) else true


func _update_npc_focus() -> bool:
	var tree := get_tree()
	if tree == null or _camera == null:
		return false
	var avatars := tree.get_nodes_in_group("npc_avatars")
	if avatars.is_empty():
		return false
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var best: NpcAvatar = null
	var best_t := INF
	for node in avatars:
		var av := node as NpcAvatar
		if av == null or not is_instance_valid(av) or not av.visible:
			continue
		var to_center: Vector3 = av.pick_center() - origin
		var t := to_center.dot(dir)
		if t <= 0.0 or t > NPC_PICK_RANGE_M or t >= best_t:
			continue
		if (to_center - dir * t).length() > NpcAvatar.PICK_RADIUS_M:
			continue
		best_t = t
		best = av
	if best == null:
		return false
	_npc_focus_id = best.agent_id
	var host := best.get_parent()
	if host != null and host.has_method("set_focus_agent"):
		host.call("set_focus_agent", best.agent_id)
	if _crosshair != null:
		if _crosshair.has_method("set_target_active"):
			_crosshair.set_target_active(true)
		if _crosshair.has_method("set_prompt_text"):
			# "Marlo — Over It · heading to Water Point"
			var parts: PackedStringArray = PackedStringArray([best.display_name])
			var tail: PackedStringArray = PackedStringArray()
			if not best.morale_label.is_empty():
				tail.append(best.morale_label)
			if not best.status_text.is_empty():
				tail.append(best.status_text)
			if not tail.is_empty():
				parts.append(" · ".join(tail))
			# In a session the crosshair also has to say the person is playable
			# — the pick has been read-only since it was written, so nobody
			# would guess Interact does anything here.
			var hint := _possession_hint(best.agent_id)
			if not hint.is_empty():
				parts.append(hint)
			_crosshair.set_prompt_text(" — ".join(parts))
	return true


func _possession_hint(agent_id: String) -> String:
	var mp := get_node_or_null("/root/MultiplayerSession")
	if mp == null or not bool(mp.call("is_active")):
		return ""
	var holder := int(mp.call("possessor_of", agent_id))
	if holder != 0:
		var peers: Dictionary = mp.get("peers") as Dictionary
		var who := str((peers.get(holder, {}) as Dictionary).get("name", "someone"))
		if str(mp.get("my_agent_id")) == agent_id:
			return "[Interact] leave this body"
		return "played by %s" % who
	if bool(mp.call("is_possessing")):
		return "[Interact] leave your current body first"
	return "[Interact] play as them"


func _clear_npc_focus() -> void:
	if _npc_focus_id.is_empty():
		return
	_npc_focus_id = ""
	var tree := get_tree()
	if tree != null:
		for node in tree.get_nodes_in_group("npc_avatars"):
			var host := (node as Node).get_parent()
			if host != null and host.has_method("set_focus_agent"):
				host.call("set_focus_agent", "")
			break


func _update_ui() -> void:
	if _crosshair != null:
		if _crosshair.has_method("set_target_active"):
			_crosshair.set_target_active(_focused != null)
		if _crosshair.has_method("set_prompt_text"):
			if _focused != null:
				var lbl := _focused.get_prompt_text()
				if _focused is PlacedProp:
					var pp := _focused as PlacedProp
					if pp.has_meta("packed"):
						# A packed crate is visually anonymous — say what is
						# INSIDE it, plus the runtime's own action prompt
						# ("Unpack (Interact)…" / "Stowed — unload the
						# delivery first" / "Under construction…"), which the
						# old "Edit prop" fallthrough was discarding.
						var main := get_tree().current_scene
						var rec := PlacedPropService.get_prop_record(main, pp.prop_id)
						var contents := PlacedPropRuntime.packed_contents_label(rec, main)
						lbl = "📦 %s — %s" % [contents, pp.get_prompt_text()] \
							if not contents.is_empty() else pp.get_prompt_text()
					elif pp.has_meta("printed_job_id"):
						lbl = "Inspect · Move (drag)"
					elif pp.get_node_or_null("CncMachineRuntime") != null \
							and _is_fdm_printer_prop(pp):
						lbl = "Print setup"
					else:
						lbl = "Edit prop"
				if _prompt_ui != null and _prompt_ui.has_method("get_action_label"):
					lbl = "[%s / Click] %s" % [_prompt_ui.get_action_label(_focused.get_action_name()), lbl]
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
	var is_click: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	var is_interact := event.is_action_pressed("interact")
	var is_veg_edit := event.is_action_pressed("vegetation_area_edit")
	# Hang-edit wires: plain LMB is owned by ConduitRouteController (drag).
	# Ctrl/Meta+LMB opens the style modal. Interact always opens style.
	var conduit_ctrl_click := is_click and not _conduit_focus_id.is_empty() \
			and event is InputEventMouseButton \
			and ((event as InputEventMouseButton).ctrl_pressed \
				or (event as InputEventMouseButton).meta_pressed)
	var conduit_plain_click := is_click and not _conduit_focus_id.is_empty() \
			and not conduit_ctrl_click
	# Cached at focus time (ConduitManager model) — do not depend on graph UI.
	var hang_focus := _conduit_focus_hang_edit
	var conduit_style_click := conduit_ctrl_click \
			or (conduit_plain_click and not hang_focus)
	# Hang-edit plain LMB: leave unhandled for ConduitRouteController drag.
	if hang_focus and conduit_plain_click and not is_interact:
		return
	if not is_interact and not is_veg_edit \
			and not (is_click and _is_alt_selection_active()) \
			and not conduit_style_click:
		return
	# NOTE: "vegetation_area_edit" shares the O key with "interact" (see
	# project.godot), so both fire on the same keypress. A genuinely focused
	# Interactable (SoI marker, placed prop, etc.) must win — vegetation-area
	# tuning is only reached via the _try_open_veg_area() fallback below once
	# nothing else (interactable / solar / building) is focused. Do NOT
	# short-circuit on is_veg_edit here, or focused Interactables never get
	# their interact() call.
	# Possess the person under the crosshair (multiplayer only). Placed after
	# the focused-Interactable block so a prop or SoI marker still wins, and
	# before the ground-pick fallbacks so aiming at someone is unambiguous.
	# `_npc_focus_id` has always been computed here and never read — this is the
	# first consumer.
	if is_interact and not _npc_focus_id.is_empty() and _focused == null:
		if _try_possess_npc():
			get_viewport().set_input_as_handled()
			return
	if _focused != null and is_instance_valid(_focused):
		if _focused is PlacedProp:
			if is_click:
				# A left-click on a focused prop is owned by GrabController, which
				# distinguishes a quick click (open the edit panel) from a hold+drag
				# (reposition it like a fresh placement) — leave the event unhandled
				# so it reaches GrabController's own _unhandled_input.
				return
			_open_placed_prop_edit(_focused as PlacedProp)
			get_viewport().set_input_as_handled()
			return
		# Relocatable markers (the SoI pin) hand a left-click to GrabController, which
		# tells a quick click (open) from a hold+drag (relocate) — same as a prop.
		# The interact KEY still falls through to interact() below.
		if is_click and _focused.has_method("world_drag_commit"):
			return
		_focused.interact(_player)
		get_viewport().set_input_as_handled()
		return
	# Focused 3D conduit → style modal (Interact always; Ctrl+LMB for hang-edit;
	# plain LMB for non-hang-edit kinds only).
	if not _conduit_focus_id.is_empty() and (is_interact or conduit_style_click):
		var gv := _graph_view()
		if gv != null and gv.has_method("open_conduit_style_modal"):
			gv.call("open_conduit_style_modal", _conduit_focus_id)
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
	# Aimed at a still-water body → open the pond settings modal (override volume /
	# fill level, add-to-graph / remove / delete). Ponds are no longer auto-added.
	if _water_focus_idx >= 0 and _loader != null \
			and _loader.has_method("open_pond_editor"):
		_loader.call("open_pond_editor", _water_focus_idx)
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
	# Otherwise a focused OSM veg area → open its per-area Fill drawer.
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


func _open_placed_prop_edit(prop: PlacedProp) -> void:
	if prop == null:
		return
	# PACKED crate (PACKING_PLAN.md Phase 5): Interact = unpack in place.
	# Repacking lives in the edit drawer — a crate has no other interaction,
	# but a deployed prop's Interact is already spoken for (linkage fold,
	# StarShade edit…), so packing must never hijack it.
	# A crew BUILD SITE (Site Projects) is packed too, but its deploy is the
	# erect phase's effect — Interact must not shortcut the whole build.
	if bool(prop.get_meta("packed", false)):
		if bool(prop.get_meta("under_construction", false)):
			open_prop_edit_ui(prop)
			return
		if _loader != null and _loader.has_method("set_prop_packed"):
			_loader.call("set_prop_packed", str(prop.prop_id), false)
		return
	# Linkage Lab structures: Interact = live deploy/stow fold toggle (the
	# quick-click edit panel — GrabController's path — still reaches
	# PlacedPropEditUI, which offers "Edit in Linkage Lab").
	var deploy := prop.get_node_or_null("LinkageDeployRuntime")
	if deploy != null and deploy.has_method("toggle_deploy"):
		deploy.call("toggle_deploy")
		return
	open_prop_edit_ui(prop)


func _is_fdm_printer_prop(prop: PlacedProp) -> bool:
	if prop == null:
		return false
	var mid := str(prop.model_id)
	if mid == "mud_printer" or mid == "trash_printer":
		return true
	var gv := _graph_view()
	if gv == null or gv.get("model") == null:
		return false
	var runtime := prop.get_node_or_null("CncMachineRuntime")
	if runtime == null:
		return false
	var item_id := str(runtime.get("graph_item_id"))
	if item_id.is_empty():
		return false
	var item: Dictionary = gv.model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	return str(specs.get("machine_role", "")) == "fdm_printer"


## Opens the proper editor for a placed prop — shared by the Interact key
## (interaction_focus) and a no-drag click (GrabController), so every selectable
## model opens the same UI either way. Printed (mud/clay) objects are move-only.
func open_prop_edit_ui(prop: PlacedProp) -> void:
	if prop == null:
		return
	if prop.has_meta("printed_job_id"):
		return
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	# Any FDM printer: open the shared Print Setup modal (part/STL, slicer,
	# bed preview, start). Falls through for non-printer machines.
	if prop.get_node_or_null("CncMachineRuntime") != null:
		var gv := _graph_view()
		if gv != null and gv.has_method("open_print_setup_for_prop"):
			if bool(gv.call("open_print_setup_for_prop", prop.prop_id)):
				return
	# StarShade props open the dedicated modal (design swap + graph reseed).
	if ModelCatalog.is_starshade_model(prop.model_id):
		if _loader != null and _loader.has_method("open_starshade_editor"):
			_loader.call("open_starshade_editor", prop.prop_id)
			return
	# Pallet racks open the parametric builder bound to this rack for editing.
	if prop.model_id == PalletRackBuilder.MODEL_ID:
		if _loader != null and _loader.has_method("open_pallet_rack_builder_for_prop"):
			_loader.call("open_pallet_rack_builder_for_prop", prop.prop_id)
			return
	var edit_ui := tree.current_scene.get_node_or_null("UILayer/PlacedPropEditUI")
	if edit_ui != null and edit_ui.has_method("open_for_prop"):
		edit_ui.call("open_for_prop", prop.prop_id)
