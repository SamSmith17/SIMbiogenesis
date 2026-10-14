extends Node

## In-world routing for a graph connection.
## - Pin mode (inspector "Route in 3D"): LMB append waypoints, Enter commit.
## - Pin-edit (hang cords, ABS kit, PEX/hose/PVC/Romex/…): hover sphere + LMB
##   drag grabs/inserts a pin; surface aim moves it; release commits.
##   Ctrl+LMB opens the style modal. Click without drag cancels (no modal).
##   Hang cords keep catenary sag; kit pipes expand 45°/90°; others use their
##   normal mesh path (flex tube / pipes router) through the pins.
## - Conceptual flow: no IK spheres (click opens style).

signal route_committed(conn_id: String)
signal route_cancelled(conn_id: String)

const RAY_LEN := 800.0
const DRAG_THRESH_PX := 6.0
## Preview remesh throttle — full tube rebuild every physics frame was unusable.
const PREVIEW_MOVE_EPS_M := 0.08
const PREVIEW_INTERVAL_S := 0.08
const PREVIEW_SEGS_DRAG := 4
const PREVIEW_SEGS_KIT := 3
const DOUBLE_CLICK_MS := 550

var _player: Node3D = null
var _camera: Camera3D = null
var _manager: ConduitManager = null
var _ui: CanvasLayer = null
var _preview: MeshInstance3D = null

var _active: bool = false
var _drag_mode: bool = false
var _conn_id: String = ""
var _type_id: String = "extension_cord"
var _style_ov: Dictionary = {}  ## conduit_style (pipe_size_in etc.) for kit resolve
var _waypoints: Array = []  ## Array of Dictionary {x,y,z,pin_path?}
var _anchor_a: Vector3 = Vector3.ZERO
var _anchor_b: Vector3 = Vector3.ZERO
var _ghost_pos: Vector3 = Vector3.ZERO
var _ghost_valid: bool = false

var _drag_wp_index: int = -1  ## index into _waypoints being moved (−1 = not yet inserted)
var _drag_start_screen: Vector2 = Vector2.ZERO
var _drag_hit_point: Vector3 = Vector3.ZERO
var _drag_segment_i: int = 0
var _drag_moved: bool = false
var _pending_drag: bool = false
var _drag_rel_accum: float = 0.0  ## captured-mouse: position stays centered; use relative
var _waypoints_snapshot: Array = []  ## restore on cancel
var _preview_last_pos: Vector3 = Vector3.INF
var _preview_accum_s: float = 0.0
## True on a rebuild where the cursor had NOT moved since the last one (settled) —
## the preview then runs the full obstacle-aware A* so the ghost matches the wire it
## will commit to; false during active motion (cheap geometric route, no A*).
var _preview_settled: bool = true
var _ui_accum_s: float = 0.0
var _grab_pin_index: int = -1  ## preselected hang pin to move (−1 = insert new)
var _last_pin_click_ms: int = 0
var _last_pin_click_idx: int = -1
var _last_pin_click_cid: String = ""

## Grab-and-plug: pull a plug from one port and drop it on a compatible one to
## create a new connection (build 3D-wiring confidence). See ConduitPlugLogic.
var _plug_mode: bool = false
var _plug_src: Dictionary = {}       ## source port-hit {port, world_pos, item_id}
var _plug_target: Dictionary = {}    ## currently snapped compatible target (or {})
const PLUG_PICK_PERP_M := 0.45       ## how close the crosshair must aim at a port
var _preview_ghost_mat: StandardMaterial3D = null  ## reused — no per-frame mat alloc


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
	_style_ov = {}
	if _manager != null and not conn_id.is_empty():
		var model: GraphModel = _manager.get_graph_model()
		if model != null:
			var conn := model.get_connection(conn_id)
			_style_ov = conn.get("conduit_style", {}) as Dictionary
	_waypoints = existing_route.duplicate(true)
	_waypoints_snapshot = _waypoints.duplicate(true)
	_active = true
	_drag_mode = false
	_drag_wp_index = -1
	_pending_drag = false
	_drag_moved = false
	_update_ui()
	_refresh_preview()


## Start drag-reroute from a focused conduit (called on LMB down).
## Does NOT mutate waypoints until the drag exceeds the pixel threshold.
## grab_pin_index >= 0: reposition that existing hang pin (do not insert a new one).
func begin_drag_reroute(conn_id: String, hit_point: Vector3, segment_i: int,
		grab_pin_index: int = -1) -> void:
	if _manager == null or conn_id.is_empty():
		return
	var model: GraphModel = _manager.get_graph_model()
	if model == null:
		return
	var conn := model.get_connection(conn_id)
	if conn.is_empty() or not model.connection_is_3d_routable(conn):
		return
	var src := model.get_item(str(conn.get("source_item_id", "")))
	var tgt := model.get_item(str(conn.get("target_item_id", "")))
	var tree := get_tree()
	var main_n := _manager.get_main_node()
	var a := ConduitManager.anchor_global_for_item(
		src, tree, str(conn.get("source_handle_id", "")), main_n)
	var b := ConduitManager.anchor_global_for_item(
		tgt, tree, str(conn.get("target_handle_id", "")), main_n)
	if not is_finite(a.x) or not is_finite(b.x):
		return
	if not is_finite(hit_point.x):
		return
	_conn_id = conn_id
	_anchor_a = a
	_anchor_b = b
	_type_id = ConduitKinds.derive_type_for_connection(conn)
	_style_ov = conn.get("conduit_style", {}) as Dictionary
	# Always seed from persisted sparse route_3d — never from seated live
	# control points (those include approach stubs and soft samples; resampling
	# them created far/ghost pins and made flex runs vanish on commit).
	_waypoints = []
	if ConduitKinds.supports_pin_edit(_type_id):
		# Strip legacy pin_path so a StarShade PropBody origin can't yank the pin.
		_waypoints = ConduitKinds.strip_hang_pin_paths(
			(conn.get("route_3d", []) as Array).duplicate(true))
	elif bool(conn.get("route_locked", false)):
		_waypoints = (conn.get("route_3d", []) as Array).duplicate(true)
	_waypoints_snapshot = _waypoints.duplicate(true)
	_grab_pin_index = grab_pin_index
	# If grabbing an existing pin, anchor the drag at that pin's world position.
	if _grab_pin_index >= 0 and _grab_pin_index < _waypoints.size():
		hit_point = _wp_to_vec(_waypoints[_grab_pin_index])
	elif ConduitKinds.supports_pin_edit(_type_id) and _manager != null \
			and _manager.has_method("nearest_hang_pin"):
		var near: Dictionary = _manager.call("nearest_hang_pin", conn_id, hit_point,
			ConduitManager.HANG_PIN_GRAB_M) as Dictionary
		var ni := int(near.get("index", -1))
		if ni >= 0:
			_grab_pin_index = ni
			hit_point = near.get("position", hit_point) as Vector3
	_drag_hit_point = hit_point
	_drag_segment_i = segment_i
	_drag_wp_index = _grab_pin_index
	_active = true
	_drag_mode = true
	_drag_moved = false
	_pending_drag = true
	_drag_rel_accum = 0.0
	_ghost_pos = hit_point
	_ghost_valid = true
	_preview_last_pos = Vector3.INF
	if ConduitKinds.supports_pin_edit(_type_id) and _manager != null \
			and _manager.has_method("update_hang_hover_gizmo"):
		_manager.call("update_hang_hover_gizmo", _conn_id, hit_point, true)
	_update_ui()
	# Preview stays hidden until the drag threshold (captured look uses relative).


## Begin pulling a plug from a source port-hit (from ConduitManager.gather_world_ports).
## Enters plug mode: a preview wire follows the crosshair and snaps to compatible
## ports; commit creates the connection.
func begin_plug(src_hit: Dictionary) -> void:
	if _manager == null or src_hit.is_empty():
		return
	var wp: Vector3 = src_hit.get("world_pos", Vector3.INF)
	if not is_finite(wp.x):
		return
	_conn_id = ""
	_plug_mode = true
	_plug_src = src_hit
	_plug_target = {}
	var port: Dictionary = src_hit.get("port", {}) as Dictionary
	_type_id = _plug_type_for_port(port)
	_style_ov = port.get("preferred_conduit_style", {}) as Dictionary
	_anchor_a = wp
	_anchor_b = wp
	_waypoints = []
	_active = true
	_drag_mode = false
	_pending_drag = false
	_drag_moved = false
	_ghost_pos = wp
	_ghost_valid = true
	_update_ui()
	_refresh_preview()


## Default conduit kind for a plug started at a port (port preference → resource).
func _plug_type_for_port(port: Dictionary) -> String:
	var pref := str(port.get("preferred_conduit_type", "")).strip_edges()
	if not pref.is_empty() and ConduitKinds.has_type(pref):
		return pref
	var kind := str(port.get("resource_kind", ""))
	if kind.is_empty():
		return "extension_cord"
	var defaults: Dictionary = ConduitKinds.RESOURCE_DEFAULTS
	return str(defaults.get(kind, "extension_cord"))


## Aim at a port under the crosshair; if found, begin plug mode from it.
## A port that ALREADY has a wire hands the click to drag-reroute of that wire
## instead — starting a fresh plug there minted a second, default-styled
## connection and read as "the port system overrules my conduit styles".
func _try_begin_plug_from_port() -> bool:
	if _ensure_manager() == null or _camera == null:
		return false
	if not _manager.has_method("gather_world_ports"):
		return false
	var vp := get_viewport()
	if vp == null:
		return false
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var ports: Array = _manager.call("gather_world_ports")
	var hit := ConduitPlugLogic.nearest_port_along_ray(origin, dir, ports, PLUG_PICK_PERP_M)
	if hit.is_empty():
		return false
	# The prop under the crosshair owns a plain click (GrabController opens its
	# editor / drags it). A PowerSpout is 0.6 m long with four ports, so aiming
	# ANYWHERE on it landed within the pick radius of one and the turbine could
	# never be clicked. A port on the aimed prop only starts a plug when the aim
	# is precise; a port behind another prop never does.
	var wp0: Vector3 = hit.get("world_pos", Vector3.INF)
	var prop_hit := _center_prop_hit()
	if not prop_hit.is_empty():
		var prop_d := float(prop_hit.get("dist", INF))
		var along := (wp0 - origin).dot(dir.normalized())
		var same_prop := _port_belongs_to_prop(hit, prop_hit.get("prop") as Node)
		if not same_prop and along > prop_d - 0.3:
			return false
		if same_prop:
			var perp := (wp0 - origin - dir.normalized() * along).length()
			if perp > PORT_PRECISE_PICK_M:
				return false
	var existing := _conn_on_port(hit)
	if not existing.is_empty():
		var wp: Vector3 = hit.get("world_pos", Vector3.INF)
		begin_drag_reroute(str(existing.get("id", "")), wp, 0)
		return true
	begin_plug(hit)
	return true


## Precise-aim radius for a port ON the prop under the crosshair (the loose
## PLUG_PICK_PERP_M still applies to ports with no prop behind them).
const PORT_PRECISE_PICK_M := 0.15
## A conduit pick within this of a prop's surface (or beyond it) is the prop.
## Same rule as InteractionFocus.CONDUIT_PROP_CLEARANCE_M.
const PROP_CLEARANCE_M := 0.6


## The placed prop (or any Interactable) under the screen centre:
## {prop, dist, point} or {}. One physics ray.
func _center_prop_hit() -> Dictionary:
	if _camera == null or _player == null:
		return {}
	var vp := get_viewport()
	if vp == null:
		return {}
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var space := _player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 200.0)
	if _player is CollisionObject3D:
		query.exclude = [(_player as CollisionObject3D).get_rid()]
	var res := space.intersect_ray(query)
	if res.is_empty():
		return {}
	var node: Node = res.get("collider") as Node
	while node != null and not (node is Interactable):
		node = node.get_parent()
	if node == null:
		return {}
	return {"prop": node, "dist": origin.distance_to(res["position"] as Vector3),
		"point": res["position"]}


func _port_belongs_to_prop(port_hit: Dictionary, prop: Node) -> bool:
	if prop == null or _manager == null:
		return false
	var model: GraphModel = _manager.get_graph_model()
	if model == null:
		return false
	var item := model.get_item(str(port_hit.get("item_id", "")))
	var pid := str((item.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
	return not pid.is_empty() and prop is PlacedProp and str(prop.get("prop_id")) == pid


## True when a conduit pick point sits at or behind the prop under the
## crosshair (every run ends at a port on its prop, so its last samples always
## pass within the pick radius of the prop body).
func _conduit_pick_occluded(origin: Vector3, pick_pt: Vector3) -> bool:
	if not is_finite(pick_pt.x):
		return false
	var prop_hit := _center_prop_hit()
	if prop_hit.is_empty():
		return false
	return origin.distance_to(pick_pt) > float(prop_hit["dist"]) - PROP_CLEARANCE_M


## The connection already wired to a port hit's (item, handle), or {}.
func _conn_on_port(port_hit: Dictionary) -> Dictionary:
	if _manager == null:
		return {}
	var model: GraphModel = _manager.get_graph_model()
	if model == null:
		return {}
	var iid := str(port_hit.get("item_id", ""))
	var handle := str((port_hit.get("port", {}) as Dictionary).get("handle_id", ""))
	if iid.is_empty() or handle.is_empty():
		return {}
	for conn: Dictionary in model.connections:
		if (str(conn.get("source_item_id", "")) == iid \
				and str(conn.get("source_handle_id", "")) == handle) \
				or (str(conn.get("target_item_id", "")) == iid \
				and str(conn.get("target_handle_id", "")) == handle):
			return conn
	return {}


## Refresh the snapped target while pulling a plug: nearest compatible port to the
## crosshair, else free-air ghost at the raycast hit.
func _update_plug_target() -> void:
	if _manager == null or not _manager.has_method("gather_world_ports"):
		return
	var vp := get_viewport()
	if vp == null or _camera == null:
		return
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	var src_item := str(_plug_src.get("item_id", ""))
	var candidates: Array = []
	for h: Variant in _manager.call("gather_world_ports"):
		if not (h is Dictionary):
			continue
		# Skip ports on the source item so a plug can't loop back to itself.
		if str((h as Dictionary).get("item_id", "")) == src_item and not src_item.is_empty():
			continue
		candidates.append(h)
	var best := ConduitPlugLogic.nearest_port_along_ray(origin, dir, candidates, PLUG_PICK_PERP_M)
	if not best.is_empty() and ConduitPlugLogic.ports_compatible(_plug_src, best):
		_plug_target = best
		_anchor_b = best.get("world_pos", _anchor_b)
		_ghost_pos = _anchor_b
		_ghost_valid = true
	else:
		_plug_target = {}
		var hit := _raycast_center()
		if hit.has("position"):
			_ghost_pos = hit["position"] as Vector3
			_anchor_b = _ghost_pos
			_ghost_valid = true
		else:
			_ghost_valid = false


func _commit_plug() -> void:
	if _manager == null:
		_cancel_plug()
		return
	if _plug_target.is_empty():
		# Released in open ground. A penstock is EXPECTED to end there — the
		# uphill water source is a place, not an existing machine — so create
		# the intake and connect to it. Every other kind still needs a port at
		# the far end, but say so instead of silently dropping the run (the run
		# vanishing with no feedback read as "dragging pipe is broken").
		if _contour_mode() and _ghost_valid:
			if _commit_penstock_to_new_intake(_ghost_pos):
				_cancel_plug()
				return
		elif not _ghost_valid:
			_toast("Aim at the ground or a matching port, then release")
		else:
			_toast("Nothing to plug into there — release on a matching port")
		_cancel_plug()
		return
	var spec := ConduitPlugLogic.build_connection_spec(_plug_src, _plug_target, _type_id, [])
	if _manager.has_method("create_plug_connection"):
		_manager.call("create_plug_connection", spec)
	_cancel_plug()


## Drop the far end of a penstock in open terrain: mint a Stream Intake there
## (a real prop + graph node — conduits have no free endpoints, both ends must
## resolve to an item with a 3D anchor) and wire it to the turbine port the
## drag started from. Returns false if the graph view can't service it.
func _commit_penstock_to_new_intake(world_pos: Vector3) -> bool:
	var sgv := _graph_view_node()
	if sgv == null or not sgv.has_method("create_penstock_intake_at"):
		_toast("Can't place an intake here")
		return false
	var src_item := str(_plug_src.get("item_id", ""))
	var src_handle := str((_plug_src.get("port", {}) as Dictionary).get("handle_id", ""))
	# A plug pulled OFF a stream intake's own port used to mint a second intake
	# wired to the first (its port also prefers poly_penstock).
	if _ensure_manager() != null:
		var model: GraphModel = _manager.get_graph_model()
		if model != null and ResourceFlowEngine.is_stream_intake(model.get_item(src_item)):
			_toast("Drag from the TURBINE's penstock port to move the intake")
			return false
	# The drop point decides the source: a pond on the graph, a stream (within
	# 8 m of its line) or bare ground (a spring) — the same resolver the Lab
	# and the toolbar use, so a plug dropped in a creek taps the creek.
	var source: Dictionary = sgv.call("resolve_hydro_source_at", Vector2(world_pos.x, world_pos.z)) \
		if sgv.has_method("resolve_hydro_source_at") else {"kind": "spring", "world_pos": world_pos}
	if str(source.get("kind", "")) == "spring":
		source["world_pos"] = world_pos
	var opts: Dictionary = _style_ov.duplicate(true)
	opts["handle_id"] = src_handle
	var conn_id := str(sgv.call("route_penstock_to_source", src_item, source, opts)) \
		if sgv.has_method("route_penstock_to_source") else ""
	return not conn_id.is_empty()


func _graph_view_node() -> Node:
	var sgv := ServiceLocator.graph()
	if sgv != null:
		return sgv
	if _manager != null and _manager.has_method("get_main_node"):
		var main: Node = _manager.call("get_main_node")
		if main != null:
			return main.find_child("SystemGraphView", true, false)
	return null


func _toast(msg: String) -> void:
	var sgv := _graph_view_node()
	if sgv != null and sgv.has_method("_show_toast"):
		sgv.call("_show_toast", msg)


func _cancel_plug() -> void:
	_plug_mode = false
	_plug_src = {}
	_plug_target = {}
	_active = false
	_hide_preview()
	if _ui != null and _ui.has_method("hide_route"):
		_ui.call("hide_route")
	_conn_id = ""


func cancel_route() -> void:
	if _plug_mode:
		_cancel_plug()
		return
	if not _active:
		return
	# Restore pre-drag waypoints (drag mode may have mutated a working copy).
	_waypoints = _waypoints_snapshot.duplicate(true)
	_active = false
	_drag_mode = false
	_pending_drag = false
	_drag_moved = false
	_drag_wp_index = -1
	_hide_preview()
	ConduitSurfaceAim.clear_caches()
	if _manager != null and _manager.has_method("clear_hang_gizmos"):
		_manager.call("clear_hang_gizmos")
	if _ui != null and _ui.has_method("hide_route"):
		_ui.call("hide_route")
	route_cancelled.emit(_conn_id)
	_conn_id = ""
	_grab_pin_index = -1
	_preview_last_pos = Vector3.INF


func commit_route() -> void:
	if not _active or _manager == null:
		return
	_manager.commit_route(_conn_id, _waypoints.duplicate(true))
	var done_id := _conn_id
	_active = false
	_drag_mode = false
	_pending_drag = false
	_drag_moved = false
	_drag_wp_index = -1
	_grab_pin_index = -1
	_hide_preview()
	ConduitSurfaceAim.clear_caches()
	if _manager.has_method("clear_hang_gizmos"):
		_manager.call("clear_hang_gizmos")
	if _ui != null and _ui.has_method("hide_route"):
		_ui.call("hide_route")
	route_committed.emit(done_id)
	_conn_id = ""
	_preview_last_pos = Vector3.INF


func _insert_or_nearest_waypoint(hit: Vector3, _segment_i: int) -> int:
	# Snap to an existing pin when close (tighter for pin-edit grab spheres).
	var snap_m := 0.35 if ConduitKinds.supports_pin_edit(_type_id) else 0.6
	for i: int in _waypoints.size():
		var p := _wp_to_vec(_waypoints[i])
		if p.distance_to(hit) < snap_m:
			_waypoints[i] = ConduitKinds.waypoint_dict(hit)
			return i
	# Insert along the route polyline (approaches when stubs active — matches preview).
	var ends := _preview_route_ends()
	var a_end: Vector3 = ends.get("a_route", _anchor_a) as Vector3
	var b_end: Vector3 = ends.get("b_route", _anchor_b) as Vector3
	var control: Array = [a_end]
	for wp: Variant in _waypoints:
		control.append(_wp_to_vec(wp))
	control.append(b_end)
	var best_span := 0
	var best_d := INF
	for i: int in range(control.size() - 1):
		var d := _dist_point_segment(hit, control[i] as Vector3, control[i + 1] as Vector3)
		if d < best_d:
			best_d = d
			best_span = i
	# best_span 0 = between a and first wp → insert at waypoints[0]
	var insert_at := clampi(best_span, 0, _waypoints.size())
	_waypoints.insert(insert_at, ConduitKinds.waypoint_dict(hit))
	return insert_at


func _wp_to_vec(wp: Variant) -> Vector3:
	if wp is Vector3:
		return wp as Vector3
	if wp is Dictionary:
		return Vector3(float(wp.get("x", 0.0)), float(wp.get("y", 0.0)),
			float(wp.get("z", 0.0)))
	return Vector3.ZERO


func _dist_point_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _ensure_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		return
	_preview = MeshInstance3D.new()
	_preview.name = "ConduitRoutePreview"
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ghost's vertices are WORLD-space, so it must sit at global identity —
	# top_level gives it that under any parent, including this controller, which
	# rides the moving Player. Parenting here rather than under ConduitManager
	# also keeps the drag ghost alive when the manager hides its runs in first
	# person (ConduitManager._refresh_world_visibility): the feedback you are
	# dragging must show even when the finished wire will not.
	_preview.top_level = true
	add_child(_preview)
	_preview.visible = false


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if _plug_mode:
		_update_plug_target()
		_refresh_preview_throttled(delta, true)
		_update_ui_throttled(delta)
		return
	# Pending LMB (not yet dragged): keep the wire pick frozen — no surface aim,
	# no remesh (those were freezing the game on click).
	if _drag_mode and not _drag_moved:
		_ghost_pos = _drag_hit_point
		_ghost_valid = true
		return
	var shift_axis := _drag_mode and _drag_moved \
			and ConduitKinds.supports_pin_edit(_type_id) \
			and Input.is_key_pressed(KEY_SHIFT)
	var hit := {}
	if shift_axis:
		# Axis lock ignores surface snap — free-air along camera ray, then clamp.
		hit = _free_air_aim_center()
		if hit.has("position"):
			_ghost_pos = _axis_lock_from_drag_start(hit["position"] as Vector3)
			_ghost_valid = true
		else:
			_ghost_valid = false
	else:
		hit = _aim_center()
		if hit.has("position"):
			_ghost_pos = hit["position"] as Vector3
			_ghost_valid = true
		else:
			_ghost_valid = false
	# Only move the working waypoint after the drag threshold — keeps the bend
	# anchored at the focused pick until the player actually drags.
	if _drag_mode and _drag_moved and _drag_wp_index >= 0 and _ghost_valid:
		# Pin-edit: XYZ only — pin_path to a PropBody snaps rebuilds to ground.
		if ConduitKinds.supports_pin_edit(_type_id):
			_waypoints[_drag_wp_index] = ConduitKinds.waypoint_dict(_ghost_pos)
		else:
			_waypoints[_drag_wp_index] = ConduitKinds.waypoint_dict(_ghost_pos,
				str(hit.get("pin_path", _pin_path_from_hit(hit))))
		if _manager != null and _manager.has_method("set_hang_drag_gizmo") \
				and ConduitKinds.supports_pin_edit(_type_id):
			_manager.call("set_hang_drag_gizmo", _ghost_pos, true)
	_refresh_preview_throttled(delta, _drag_mode)
	_update_ui_throttled(delta)


func _refresh_preview_throttled(delta: float, force_move_gate: bool) -> void:
	_preview_accum_s += delta
	var moved := _ghost_valid and _ghost_pos.distance_to(_preview_last_pos) >= PREVIEW_MOVE_EPS_M
	if force_move_gate and not moved and _preview_accum_s < PREVIEW_INTERVAL_S:
		return
	if not force_move_gate and _preview_accum_s < PREVIEW_INTERVAL_S and not moved:
		return
	_preview_accum_s = 0.0
	# Settle-gate the expensive A* pass: rebuilds triggered purely by the time
	# interval (cursor not moving) run full-fidelity routing; rebuilds driven by
	# cursor motion stay cheap.
	_preview_settled = not moved
	if _ghost_valid:
		_preview_last_pos = _ghost_pos
	_refresh_preview()


func _update_ui_throttled(delta: float) -> void:
	_ui_accum_s += delta
	if _ui_accum_s < 0.1:
		return
	_ui_accum_s = 0.0
	_update_ui()


func _input(event: InputEvent) -> void:
	# Style / other modals own the mouse — never start a hang-drag under them
	# (center-ray picks still hit the wire and were eating every modal click).
	if CursorController.has_blocking_modal():
		return
	# Nothing STARTS here unless the crosshair owns the mouse: with the prop
	# editor's tool overlay up (free cursor) the screen centre still pointed at
	# the turbine, so every click on the dock's buttons and gizmo was taken by
	# a centre-ray port pick and never reached them. A route already in
	# progress keeps its release / Esc handling.
	if not _active and not CursorController.should_capture_look():
		return
	# Start a plug-pull (aim at a port) or drag-reroute (aim at a conduit).
	if event is InputEventMouseButton:
		var mb0 := event as InputEventMouseButton
		if mb0.button_index == MOUSE_BUTTON_LEFT and mb0.pressed \
				and not mb0.ctrl_pressed and not mb0.meta_pressed:
			# OS double-click often fires the 2nd press while a pending hang
			# drag is still active — allow pin delete before the early _active gate.
			if _active and _drag_mode and not _drag_moved \
					and ConduitKinds.supports_pin_edit(_type_id):
				if _try_hang_pin_double_delete_at(mb0.position):
					get_viewport().set_input_as_handled()
					return
		if not _active and mb0.button_index == MOUSE_BUTTON_LEFT and mb0.pressed:
			# Ctrl/Meta+LMB on a pin-edit wire → style modal (not drag).
			if mb0.ctrl_pressed or mb0.meta_pressed:
				if _try_open_style_from_hang_focus():
					get_viewport().set_input_as_handled()
				return
			# A port under the crosshair starts a plug; else fall back to reroute.
			if _try_begin_plug_from_port():
				get_viewport().set_input_as_handled()
				return
			if _try_begin_drag_from_focus(mb0.position):
				get_viewport().set_input_as_handled()
				return
	if not _active:
		return
	# Plug mode: LMB drops the plug (commit if on a compatible port), Esc cancels.
	if _plug_mode:
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE):
			_cancel_plug()
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton:
			var pmb := event as InputEventMouseButton
			if pmb.button_index == MOUSE_BUTTON_LEFT and not pmb.pressed:
				_commit_plug()
				get_viewport().set_input_as_handled()
			elif pmb.button_index == MOUSE_BUTTON_RIGHT and pmb.pressed:
				_cancel_plug()
				get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				if not _drag_mode:
					commit_route()
					get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				cancel_route()
				get_viewport().set_input_as_handled()
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if _drag_mode:
			if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
				if _drag_moved and _drag_wp_index >= 0:
					commit_route()
				else:
					# Click without drag: pin-edit cancels quietly; others open style.
					var open_id := _conn_id
					var was_pin := ConduitKinds.supports_pin_edit(_type_id)
					cancel_route()
					if not was_pin:
						_open_style_modal(open_id)
				get_viewport().set_input_as_handled()
			return
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_LEFT and _ghost_valid:
				var aim := _aim_center()
				var pin_path := str(aim.get("pin_path", _pin_path_from_hit(aim)))
				_waypoints.append(ConduitKinds.waypoint_dict(_ghost_pos, pin_path))
				_refresh_preview()
				_update_ui()
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_RIGHT:
				if not _waypoints.is_empty():
					_waypoints.pop_back()
					_refresh_preview()
					_update_ui()
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _drag_mode:
		var mm := event as InputEventMouseMotion
		if _pending_drag:
			# Captured FPS mouse keeps event.position pinned at the crosshair —
			# screen-delta never grows. Accumulate relative motion instead.
			_drag_rel_accum += mm.relative.length()
			var screen_delta := mm.position.distance_to(_drag_start_screen)
			if _drag_rel_accum >= DRAG_THRESH_PX or screen_delta >= DRAG_THRESH_PX:
				_activate_drag_move()


## Insert/move the working pin and start live preview / surface aim.
func _activate_drag_move() -> void:
	if _drag_moved:
		return
	_drag_moved = true
	_pending_drag = false
	# Repositioning an existing pin: keep its index. Otherwise insert/snap.
	if _grab_pin_index >= 0 and _grab_pin_index < _waypoints.size():
		_drag_wp_index = _grab_pin_index
	else:
		_drag_wp_index = _insert_or_nearest_waypoint(_drag_hit_point, _drag_segment_i)
	_ghost_pos = _drag_hit_point
	_ghost_valid = true
	if _drag_wp_index >= 0:
		_waypoints[_drag_wp_index] = ConduitKinds.waypoint_dict(_ghost_pos)
	_preview_last_pos = Vector3.INF
	_preview_accum_s = PREVIEW_INTERVAL_S  # force immediate remesh next tick
	_refresh_preview()
	_update_ui()


func _ensure_manager() -> ConduitManager:
	if _manager != null and is_instance_valid(_manager):
		return _manager
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene != null:
		_manager = scene.get_node_or_null("ConduitManager") as ConduitManager
	if _manager == null and tree.root != null:
		_manager = tree.root.find_child("ConduitManager", true, false) as ConduitManager
	return _manager


func _try_begin_drag_from_focus(screen_pos: Vector2) -> bool:
	if _active:
		return false
	if _player == null or _camera == null:
		return false
	if _ensure_manager() == null:
		return false
	var pick := _resolve_hang_drag_pick(screen_pos)
	if pick.is_empty():
		return false
	var cid := str(pick.get("conn_id", ""))
	var type_id := str(pick.get("type_id", ""))
	var grab_idx := int(pick.get("grab_idx", -1))
	var hit_pt: Vector3 = pick.get("hit_pt", Vector3.ZERO) as Vector3
	var seg_i := int(pick.get("seg_i", 0))
	if ConduitKinds.supports_pin_edit(type_id) and grab_idx >= 0:
		if _register_pin_click(cid, grab_idx):
			_delete_hang_pin(cid, grab_idx)
			return true
	_drag_start_screen = screen_pos
	begin_drag_reroute(cid, hit_pt, seg_i, grab_idx)
	return true


## Second LMB while a pending (unmoved) pin drag is active → delete that pin.
func _try_hang_pin_double_delete_at(screen_pos: Vector2) -> bool:
	if _ensure_manager() == null:
		return false
	var pick := _resolve_hang_drag_pick(screen_pos)
	if pick.is_empty():
		return false
	var cid := str(pick.get("conn_id", ""))
	var grab_idx := int(pick.get("grab_idx", -1))
	if grab_idx < 0 or cid.is_empty():
		return false
	# Same pin as the pending grab, or a registered double-click window.
	var same_pending := (_conn_id == cid and (_grab_pin_index == grab_idx \
			or _drag_wp_index == grab_idx))
	if not same_pending and not _register_pin_click(cid, grab_idx):
		return false
	if same_pending:
		_last_pin_click_idx = -1
		_last_pin_click_cid = ""
	_delete_hang_pin(cid, grab_idx)
	return true


## Resolve pin-edit / legacy drag pick under the crosshair.
## Returns {conn_id, type_id, grab_idx, hit_pt, seg_i} or {}.
func _resolve_hang_drag_pick(screen_pos: Vector2) -> Dictionary:
	if _camera == null or _player == null or _manager == null:
		return {}
	var focus := _player.get_node_or_null("InteractionFocus")
	var cid := ""
	if focus != null and focus.has_method("get_conduit_focus_id"):
		cid = str(focus.call("get_conduit_focus_id"))
	var vp := get_viewport()
	var origin: Vector3
	var dir: Vector3
	if vp != null:
		var center := vp.get_visible_rect().size * 0.5
		origin = _camera.project_ray_origin(center)
		dir = _camera.project_ray_normal(center)
	else:
		origin = _camera.project_ray_origin(screen_pos)
		dir = _camera.project_ray_normal(screen_pos)
	var hit: Dictionary = _manager.pick_conduit(origin, dir, 0.55)
	if not str(hit.get("conn_id", "")).is_empty() \
			and _conduit_pick_occluded(origin, hit.get("point", Vector3.INF) as Vector3):
		hit = {}
	# The END of a draft pipe is its OutletEndMarker's (GrabController moves
	# the outlet); a drag there must not insert a waypoint.
	if not str(hit.get("conn_id", "")).is_empty() and _manager.has_method("is_outlet_terminal_pick") \
			and bool(_manager.call("is_outlet_terminal_pick", str(hit.get("conn_id", "")),
				hit.get("point", Vector3.INF) as Vector3)):
		return {}
	if cid.is_empty():
		cid = str(hit.get("conn_id", ""))
	# Prefer a pin under the crosshair even when wire focus is empty/stale.
	if cid.is_empty() and _manager.has_method("pick_any_hang_pin"):
		var any_pin: Dictionary = _manager.call("pick_any_hang_pin", origin, dir) as Dictionary
		cid = str(any_pin.get("conn_id", ""))
	if cid.is_empty():
		return {}
	var model: GraphModel = _manager.get_graph_model()
	var type_id := ""
	if model != null:
		var conn := model.get_connection(cid)
		type_id = ConduitKinds.derive_type_for_connection(conn)
		if not ConduitKinds.supports_pin_edit(type_id):
			if focus == null or str(focus.call("get_conduit_focus_id")) != cid:
				return {}
	var grab_idx := -1
	var hit_pt: Vector3 = hit.get("point", Vector3.ZERO) as Vector3
	var seg_i := int(hit.get("segment_i", 0))
	if ConduitKinds.supports_pin_edit(type_id) \
			and _manager.has_method("pick_hang_pin"):
		var pin_hit: Dictionary = _manager.call("pick_hang_pin", cid, origin, dir) as Dictionary
		var pi := int(pin_hit.get("index", -1))
		if pi >= 0:
			grab_idx = pi
			hit_pt = pin_hit.get("position", hit_pt) as Vector3
	if grab_idx < 0:
		if str(hit.get("conn_id", "")) != cid:
			var samples := _manager.get_sample_points(cid)
			if samples.size() < 2:
				return {}
			hit = ConduitKinds.ray_polyline_pick(origin, dir, samples, 0.55)
			hit["conn_id"] = cid
		hit_pt = hit.get("point", Vector3.ZERO) as Vector3
		seg_i = int(hit.get("segment_i", 0))
		if str(hit.get("conn_id", "")).is_empty() or not is_finite(hit_pt.x):
			return {}
		if float(hit.get("distance", INF)) > 0.55:
			return {}
		if ConduitKinds.supports_pin_edit(type_id) \
				and _manager.has_method("nearest_hang_pin"):
			var near: Dictionary = _manager.call("nearest_hang_pin", cid, hit_pt,
				ConduitManager.HANG_PIN_GRAB_M) as Dictionary
			var ni := int(near.get("index", -1))
			if ni >= 0:
				grab_idx = ni
				hit_pt = near.get("position", hit_pt) as Vector3
	return {
		"conn_id": cid,
		"type_id": type_id,
		"grab_idx": grab_idx,
		"hit_pt": hit_pt,
		"seg_i": seg_i,
	}


## Returns true when this press completes a double-click on the same pin.
func _register_pin_click(cid: String, pin_idx: int) -> bool:
	var now := Time.get_ticks_msec()
	var is_dbl := (cid == _last_pin_click_cid and pin_idx == _last_pin_click_idx \
			and pin_idx >= 0 and (now - _last_pin_click_ms) <= DOUBLE_CLICK_MS)
	_last_pin_click_ms = now
	_last_pin_click_idx = pin_idx
	_last_pin_click_cid = cid
	return is_dbl


func _delete_hang_pin(cid: String, pin_idx: int) -> void:
	if _manager == null or cid.is_empty() or pin_idx < 0:
		return
	if _active and _conn_id == cid:
		cancel_route()
	var model: GraphModel = _manager.get_graph_model()
	if model == null:
		return
	var conn := model.get_connection(cid)
	if conn.is_empty():
		return
	var wps: Array = ConduitKinds.strip_hang_pin_paths(
		(conn.get("route_3d", []) as Array).duplicate(true))
	if pin_idx >= wps.size():
		return
	wps.remove_at(pin_idx)
	_manager.commit_route(cid, wps)
	_last_pin_click_idx = -1
	_last_pin_click_cid = ""
	_last_pin_click_ms = 0
	# Immediate free of pin/drag spheres — InteractionFocus repaints next frame.
	if _manager.has_method("clear_hang_gizmos"):
		_manager.call("clear_hang_gizmos")
	route_committed.emit(cid)


func _pin_path_from_hit(hit: Dictionary) -> String:
	if hit.has("pin_path") and not str(hit.get("pin_path", "")).is_empty():
		return str(hit.get("pin_path", ""))
	if hit.has("collider"):
		var col: Object = hit["collider"]
		if col is Node:
			return str((col as Node).get_path())
	return ""


## Pin-edit kinds use hybrid surface aim. Legacy non-pin drag (if any) keeps a
## physics ray clamped to the live conduit so look-away can't invent far pins.
const FLEX_DRAG_MAX_M := 3.5

func _aim_center() -> Dictionary:
	if ConduitKinds.supports_pin_edit(_type_id):
		return _surface_aim_center()
	var hit := _raycast_center()
	if hit.is_empty():
		hit = _free_air_aim_center()
	return _clamp_aim_to_conduit(hit)


func _clamp_aim_to_conduit(hit: Dictionary) -> Dictionary:
	if hit.is_empty() or not hit.has("position"):
		return hit
	var pos: Vector3 = hit["position"] as Vector3
	var nearest := _nearest_on_live_conduit(pos)
	if not is_finite(nearest.x):
		return hit
	var d := pos.distance_to(nearest)
	if d <= FLEX_DRAG_MAX_M:
		return hit
	# Pull back toward the conduit — keep a short offset in the aim direction.
	var dir := pos - nearest
	if dir.length_squared() < 1e-8:
		hit["position"] = nearest
	else:
		hit["position"] = nearest + dir.normalized() * FLEX_DRAG_MAX_M
	hit["clamped"] = true
	return hit


func _nearest_on_live_conduit(pos: Vector3) -> Vector3:
	var samples := PackedVector3Array()
	if _manager != null and not _conn_id.is_empty():
		samples = _manager.get_sample_points(_conn_id)
	if samples.size() < 2:
		var control := _control_points_for_preview()
		for p: Variant in control:
			if p is Vector3:
				samples.append(p as Vector3)
	if samples.size() < 2:
		return Vector3.INF
	var best := samples[0]
	var best_d := pos.distance_squared_to(best)
	for i: int in range(samples.size() - 1):
		var a: Vector3 = samples[i]
		var b: Vector3 = samples[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 < 1e-12 else clampf((pos - a).dot(ab) / len2, 0.0, 1.0)
		var q := a + ab * t
		var d2 := pos.distance_squared_to(q)
		if d2 < best_d:
			best_d = d2
			best = q
	return best


## Free-air point along the center ray (used by Shift+axis lock).
func _free_air_aim_center() -> Dictionary:
	if _camera == null:
		return {}
	var vp := get_viewport()
	if vp == null:
		return {}
	var center := vp.get_visible_rect().size * 0.5
	var origin := _camera.project_ray_origin(center)
	var dir := _camera.project_ray_normal(center)
	# Depth: keep roughly the same distance as the drag start from the camera.
	var depth := origin.distance_to(_drag_hit_point)
	depth = clampf(depth, 0.5, 40.0)
	return {"valid": true, "position": origin + dir * depth}


## Project aim onto the dominant world axis from drag start (Shift+drag).
func _axis_lock_from_drag_start(aim: Vector3) -> Vector3:
	var origin := _drag_hit_point
	var delta := aim - origin
	var ax := absf(delta.x)
	var ay := absf(delta.y)
	var az := absf(delta.z)
	# Prefer the axis most aligned with camera forward when two deltas are close.
	var cam_bias := Vector3.ZERO
	if _camera != null:
		var fwd := -_camera.global_transform.basis.z
		cam_bias = Vector3(absf(fwd.x), absf(fwd.y), absf(fwd.z))
	var score_x := ax + cam_bias.x * 0.05
	var score_y := ay + cam_bias.y * 0.05
	var score_z := az + cam_bias.z * 0.05
	if score_y >= score_x and score_y >= score_z:
		return Vector3(origin.x, aim.y, origin.z)
	if score_x >= score_z:
		return Vector3(aim.x, origin.y, origin.z)
	return Vector3(origin.x, origin.y, aim.z)


func _surface_aim_center() -> Dictionary:
	if _camera == null:
		return {}
	var main: Node = null
	if _manager != null and _manager.has_method("get_main_node"):
		main = _manager.call("get_main_node") as Node
	if main == null and _player != null:
		main = _player.get_parent()
	var aim := ConduitSurfaceAim.pick(main, _camera)
	if not bool(aim.get("valid", false)):
		return {}
	# Shape like PhysicsRayQueryParameters result for callers.
	return {
		"valid": true,
		"position": aim.get("position", Vector3.ZERO),
		"normal": aim.get("normal", Vector3.UP),
		"pin_path": str(aim.get("pin_path", "")),
		"source": str(aim.get("source", "")),
	}


func _try_open_style_from_hang_focus() -> bool:
	if _player == null:
		return false
	var focus := _player.get_node_or_null("InteractionFocus")
	if focus == null or not focus.has_method("get_conduit_focus_id"):
		return false
	var cid := str(focus.call("get_conduit_focus_id"))
	if cid.is_empty():
		return false
	if _ensure_manager() == null:
		return false
	var model: GraphModel = _manager.get_graph_model()
	if model == null:
		return false
	var conn := model.get_connection(cid)
	var type_id := ConduitKinds.derive_type_for_connection(conn)
	if not ConduitKinds.supports_pin_edit(type_id):
		return false
	_open_style_modal(cid)
	return true


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
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {}
	hit["valid"] = true
	return hit


func _control_points_for_preview() -> Array:
	var ends := _preview_route_ends()
	var a0: Vector3 = ends.get("a", _anchor_a) as Vector3
	var b0: Vector3 = ends.get("b", _anchor_b) as Vector3
	var a_route: Vector3 = ends.get("a_route", a0) as Vector3
	var b_route: Vector3 = ends.get("b_route", b0) as Vector3
	var seat_a := bool(ends.get("seat_a", false))
	var seat_b := bool(ends.get("seat_b", false))
	var out_a: Vector3 = ends.get("out_a", Vector3.ZERO) as Vector3
	var out_b: Vector3 = ends.get("out_b", Vector3.ZERO) as Vector3
	# Plug pull keeps its own straight/cord handling (drapes to ground for the cord
	# visual) — a distinct interaction, not routed through the shared dispatch.
	if _plug_mode:
		var step := ConduitKinds.fitting_step_deg(_type_id)
		if step < 0.5:
			step = 45.0
		# Contour kinds (poly penstock) must preview through the SHARED dispatch
		# with a ground callable, or the ghost is a straight chord while the
		# committed run hugs the terrain — the drag would lie about what you get.
		if _contour_mode():
			return ConduitRouteDispatch.control_points(
				{"a": a0, "b": b0, "a_route": a_route, "b_route": b_route,
					"seat_a": seat_a, "seat_b": seat_b,
					"out_a": out_a, "out_b": out_b},
				_type_id, _style_ov, [], false, [], _preview_settled,
				0.6, _ground_fn())
		if ConduitKinds.uses_pipe_kit(_type_id):
			var plug_chain := ConduitManager._approach_chain(
				a0, b0, a_route, b_route, [], seat_a, seat_b, out_a, out_b)
			return ConduitManager._packed_to_array(
				PipeFittingExpander.expand(plug_chain, step))
		if ConduitKinds.is_pipes_type(_type_id) and _manager != null:
			var packed := ConduitPipesRouter.route(
				a_route, b_route, [], Callable(_manager, "ground_y_at"),
				0.12, ConduitPipesRouter.DEFAULT_ELBOW_FRAC, [],
				ConduitKinds.fitting_step_deg(_type_id))
			return ConduitManager._seat_approaches_legal(a0, b0,
				ConduitManager._packed_to_array(packed), seat_a, seat_b,
				out_a, out_b, true, step)
		return ConduitManager._seat_approaches_legal(a0, b0, [a_route, b_route],
			seat_a, seat_b, out_a, out_b, false, 0.0)
	# Everything else runs through the SAME dispatch the committed wire uses, so the
	# ghost matches on drop. Live working waypoints + the ghost cursor act as pins.
	var resolve_pins := not ConduitKinds.supports_pin_edit(_type_id)
	var wps: Array = ConduitKinds.waypoints_to_vectors(_waypoints, null, resolve_pins)
	if _ghost_valid and not _drag_mode:
		wps.append(_ghost_pos)
	elif _drag_mode and _drag_moved and _ghost_valid and _drag_wp_index < 0 \
			and ConduitKinds.supports_pipe_pin_edit(_type_id):
		wps.append(_ghost_pos)
	# Obstacles + A* only on a settled preview (see _preview_settled) — full fidelity
	# at rest, cheap during active dragging.
	var obstacles: Array = []
	if _preview_settled and _manager != null and _manager.has_method("route_obstacles"):
		obstacles = _manager.call("route_obstacles")
	var clearance := 0.6
	if _manager != null and _manager.has_method("route_site_clearance_m"):
		clearance = float(_manager.call("route_site_clearance_m"))
	# has_pins (live waypoints) drives pin routing inside the dispatch; the conn's
	# actual lock state only gates ortho.
	var locked := false
	if _manager != null and _manager.has_method("get_graph_model") and not _conn_id.is_empty():
		var m: GraphModel = _manager.get_graph_model()
		if m != null:
			locked = bool(m.get_connection(_conn_id).get("route_locked", false))
	return ConduitRouteDispatch.control_points(ends, _type_id, _style_ov, wps, locked,
		obstacles, _preview_settled, clearance, _ground_fn())


## True port seats + approach route ends for the active connection — delegates to the
## shared resolver so preview and commit derive ends identically.
func _preview_route_ends() -> Dictionary:
	var out := {
		"a": _anchor_a, "b": _anchor_b,
		"a_route": _anchor_a, "b_route": _anchor_b,
		"seat_a": false, "seat_b": false,
		"out_a": Vector3.ZERO, "out_b": Vector3.ZERO,
	}
	if _manager == null:
		return out
	var model: GraphModel = _manager.get_graph_model() if _manager.has_method("get_graph_model") else null
	if model == null or _conn_id.is_empty():
		return out
	var conn := model.get_connection(_conn_id)
	if conn.is_empty():
		return out
	var src := model.get_item(str(conn.get("source_item_id", "")))
	var tgt := model.get_item(str(conn.get("target_item_id", "")))
	var main_n: Node = _manager.get_main_node() if _manager.has_method("get_main_node") else null
	return ConduitRouteDispatch.resolve_route_ends(_anchor_a, _anchor_b, src, tgt,
		str(conn.get("source_handle_id", "")), str(conn.get("target_handle_id", "")),
		_type_id, main_n)


## True when the active kind routes along the ground (poly penstock).
func _contour_mode() -> bool:
	return ConduitKinds.normalize_route_mode(str(_style_ov.get("route_mode",
			ConduitKinds.type_meta(_type_id).get("route_mode", "")))) == "contour"


func _ground_fn() -> Callable:
	# Hang-edit / ground-drape: sample against live terrain (catenary clamps
	# where sag meets the ground; unlocked cords still use ground-snake).
	# Contour (poly penstock): the router itself consumes the ground samples.
	# Kit pipes never use ground clamp / catenary.
	if _manager == null:
		return Callable()
	var rm := ConduitKinds.normalize_route_mode(str(_style_ov.get("route_mode",
			ConduitKinds.type_meta(_type_id).get("route_mode", ""))))
	if rm == "contour" \
			or ConduitKinds.supports_hang_edit(_type_id) \
			or ConduitKinds.is_ground_drape_type(_type_id):
		return Callable(_manager, "ground_y_at")
	return Callable()


func _preview_mesh_style() -> Dictionary:
	var style: Dictionary = ConduitKinds.type_meta(_type_id).duplicate(true)
	for k: Variant in _style_ov.keys():
		style[k] = _style_ov[k]
	# Ghost matches the committed tube thickness for size-listed kinds (see the
	# matching radius stamp in ConduitManager._rebuild_if_dirty).
	if not _style_ov.has("radius_m") and ConduitKinds.has_size_options(_type_id):
		var od := ConduitKinds.outer_diameter_m(_type_id, _style_ov)
		if od > 0.0:
			style["radius_m"] = od * 0.5
	# Catenary sag is hang-edit cords only — never kit pipes.
	if ConduitKinds.supports_hang_edit(_type_id) and not _waypoints.is_empty():
		var hang_ov := ConduitKinds.mesh_style_override("catenary")
		for k: String in hang_ov.keys():
			style[k] = hang_ov[k]
		style["terrain_clamp"] = true
	elif ConduitKinds.supports_hang_edit(_type_id):
		style["terrain_clamp"] = true
	if ConduitKinds.supports_pipe_pin_edit(_type_id):
		style["elbow_radius_frac"] = 0.0
		style["flexible"] = false
		style["sag_amount"] = 0.0
		style["clearcoat"] = 0.0  # no clearcoat during ghost preview
		style.erase("terrain_clamp")
		# Ghost tube OD matches the sized Sch40 kit (not type-meta fallback).
		var kit_id := ConduitKinds.pipe_kit_id(_type_id, _style_ov)
		var kit := PipeKit.load_kit(kit_id) if not kit_id.is_empty() else null
		if kit != null and kit.nominal_od_m > 0.001:
			style["radius_m"] = kit.nominal_od_m * 0.5
	return style


func _refresh_preview() -> void:
	_ensure_preview()
	if not _active or _preview == null:
		return
	# Before the drag threshold, keep the preview hidden so the live conduit
	# (still showing the committed route) is what the player sees.
	if _drag_mode and not _drag_moved:
		_preview.visible = false
		return
	var control := _control_points_for_preview()
	if control.size() < 2:
		_preview.visible = false
		return
	var style := _preview_mesh_style()
	# Cheap tube while dragging / kit pin-edit — avoid dense remesh + clearcoat.
	var segs := PREVIEW_SEGS_DRAG if _drag_mode else ConduitMeshBuilder.DEFAULT_SEGMENTS_PER_SPAN
	if ConduitKinds.supports_pipe_pin_edit(_type_id):
		segs = PREVIEW_SEGS_KIT
	var built: Dictionary
	# Skip light-string bulb rebuild during drag — tube only (bulbs refresh on commit).
	if ConduitKinds.is_light_type(_type_id) and not _drag_mode:
		built = ConduitMeshBuilder.build_light_string(
			control, _type_id, segs, _ground_fn(), style)
	else:
		built = ConduitMeshBuilder.build(
			control, _type_id, segs, _ground_fn(), style)
	_preview.mesh = built.get("mesh", null)
	_preview.material_override = _ghost_preview_material(built.get("material", null))
	_preview.visible = true


## One shared unshaded ghost mat — never allocate a new material each remesh.
func _ghost_preview_material(src: Variant) -> Material:
	if _preview_ghost_mat == null:
		_preview_ghost_mat = StandardMaterial3D.new()
		_preview_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_preview_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_preview_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var base := Color(0.25, 0.95, 0.55, 0.7)
	if src is StandardMaterial3D:
		base = (src as StandardMaterial3D).albedo_color.lerp(Color(0.2, 1.0, 0.5), 0.35)
		base.a = 0.7
	_preview_ghost_mat.albedo_color = base
	_preview_ghost_mat.clearcoat_enabled = false
	return _preview_ghost_mat


func _hide_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.visible = false
		_preview.mesh = null


func _open_style_modal(conn_id: String) -> void:
	if conn_id.is_empty():
		return
	# Drop any in-progress route HUD so it can't sit above the style modal.
	if _active:
		cancel_route()
	elif _ui != null and _ui.has_method("hide_route"):
		_ui.call("hide_route")
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var gv := ServiceLocator.graph()
	if gv == null:
		gv = tree.root.find_child("SystemGraphView", true, false)
	if gv != null and gv.has_method("open_conduit_style_modal"):
		gv.call("open_conduit_style_modal", conn_id)


func _update_ui() -> void:
	if _ui == null:
		return
	var len_m := 0.0
	var control := _control_points_for_preview()
	if control.size() >= 2:
		var packed := PackedVector3Array()
		for p: Variant in control:
			if p is Vector3:
				packed.append(p as Vector3)
		len_m = ConduitKinds.polyline_length_m(packed)
	if _ui.has_method("show_route_ex"):
		_ui.call("show_route_ex", _type_id, _waypoints.size(), len_m, _ghost_valid, _drag_mode)
	elif _ui.has_method("show_route"):
		_ui.call("show_route", _type_id, _waypoints.size(), len_m, _ghost_valid)
