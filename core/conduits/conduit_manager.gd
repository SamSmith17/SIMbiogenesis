class_name ConduitManager
extends Node3D

## Renders 3D conduits for graph connections whose endpoints are linked to
## scene nodes / bound props / site placements. Rebuilds on model changes and
## when anchor transforms move.

const SITE_CLEARANCE_M := 0.35
const FITTING_LEN_M := 0.06
const FITTING_RADIUS_SCALE := 1.6
## Elbow-collar hubs at each pipe bend (kinds with fitting_collars): a short band
## a bit wider than the pipe, wrapping the rounded corner like a real PVC fitting.
const COLLAR_RADIUS_SCALE := 1.35
const COLLAR_MIN_TURN_DEG := 22.0   ## a bend must turn at least this much to earn a collar
const COLLAR_MAX_COUNT := 12        ## safety cap for pathological many-bend routes
const PICK_MAX_DIST_M := 0.42
const VISIBILITY_RANGE_M := 100.0
const FOCUS_DIM := 0.35
const SYNC_DEBOUNCE_S := 0.1
const FOLLOW_THROTTLE_S := 0.1  ## max unlocked prop-follow rebuild rate
const DENSE_ROUTE_MIGRATE_MIN := 5  ## unlocked metro samples → clear as stale
## Cap kit/tube remeshes per frame so boot (graph restore + Sch40 MultiMesh) can't
## stall SolarUI sync / physics for a whole frame (blank HUD + frozen mid-air player).
const REMESH_BUDGET_PER_FRAME := 3

var _model: GraphModel = null
var _main: Node = null
var _instances: Dictionary = {}  ## conn_id -> MeshInstance3D
var _fittings: Dictionary = {}  ## conn_id -> Array[MeshInstance3D]
var _light_runtimes: Dictionary = {}  ## conn_id -> LightStringRuntime
var _sample_cache: Dictionary = {}  ## conn_id -> PackedVector3Array
var _last_anchors: Dictionary = {}  ## conn_id -> PackedVector3Array geom sig
var _last_cheap: Dictionary = {}  ## conn_id -> String cheap dirty key
var _fitting_sig: Dictionary = {}  ## conn_id -> String (skip recreate)
var _updating_model: bool = false
var _dense_routes_migrated: bool = false
var _focus_id: String = ""
var _global_visible: bool = false
var _global_flow_glow: bool = false
## True while the graph's 3D preview (Site Plan / Elevation CT / Hydro Lab
## section) is rendering the shared World3D into its SubViewport. See
## `_refresh_world_visibility` for why the node's own visibility rides on it.
var _preview_visible: bool = false
var _sync_pending: bool = false
var _sync_timer: float = 0.0
var _follow_timer: float = 0.0
var _obstacle_cache: Array = []
var _obstacle_cache_valid: bool = false
var _lane_map: Dictionary = {}  ## conn_id -> lane int (unused by A*; kept for tools)
var _astar_gen: int = 0  ## bumped on invalidate so paths refresh once
var _waypoint_gizmo: ConduitWaypointGizmo = null
var _pipe_kits: Dictionary = {}  ## kit_id -> PipeKit (null cached as false)
var _parts_active: Dictionary = {}  ## conn_id -> bool (GLB fittings assembled)
var _pipe_kit_warn: Dictionary = {}  ## conn_id -> last error (dedupe warnings)
var _elbow_cache: Dictionary = {}  ## conn_id -> Array[{bend_deg, transform, corner, …}]
var _discharge_vfx: Dictionary = {}  ## conn_id -> ConduitDischargeVfx (culvert outlet jet)
## Cached _any_explicit_visible() so the per-frame guard stays O(1); refreshed
## on every sync/enqueue pass (structure changes route through those).
var _explicit_seen: bool = false
var _elbow_highlight: MeshInstance3D = null
var _elbow_hl_mat: StandardMaterial3D = null
var _elbow_hl_key: String = ""  ## "cid:index" — skip redundant highlight updates
var _remesh_queue: Array = []  ## conn_id strings waiting for budgeted rebuild
const HANG_PIN_SNAP_M := 0.35
## Slightly larger than visual snap so aiming at the IK sphere grabs that pin.
const HANG_PIN_GRAB_M := 0.55


func setup(model: GraphModel, main_node: Node) -> void:
	_model = model
	_main = main_node
	_dense_routes_migrated = false  # one-time migration re-runs for a new model
	_refresh_global_prefs()
	if _model != null and _model.has_signal("changed"):
		if not _model.changed.is_connected(_on_model_changed):
			_model.changed.connect(_on_model_changed)
	_migrate_dense_unlocked_routes()
	invalidate_astar()
	_explicit_seen = _any_explicit_visible()
	_refresh_world_visibility()
	set_process(_global_visible or _explicit_seen)
	if _global_visible or _explicit_seen:
		# Never sync_all() here — graph restore also deferred SolarUI sync on the
		# same idle queue; a full Sch40 kit remesh would block that + physics.
		# With wires off, _enqueue_all_remesh keeps only the explicitly-visible
		# conns (routed penstocks / forced tailraces survive a map reload).
		_enqueue_all_remesh()
	else:
		_clear_all_instances()
		_remesh_queue.clear()


func teardown() -> void:
	if _model != null and _model.has_signal("changed"):
		if _model.changed.is_connected(_on_model_changed):
			_model.changed.disconnect(_on_model_changed)
	_clear_all_instances()
	_focus_id = ""
	_model = null
	_main = null
	set_process(false)


func _clear_all_instances() -> void:
	for cid: String in _instances.keys().duplicate():
		_remove_instance(cid)
	for vfx in _discharge_vfx.values():
		if vfx != null and is_instance_valid(vfx):
			vfx.queue_free()
	_discharge_vfx.clear()
	_instances.clear()
	_light_runtimes.clear()
	_last_anchors.clear()
	_last_cheap.clear()
	_fitting_sig.clear()
	_fittings.clear()
	_sample_cache.clear()
	_obstacle_cache.clear()
	_obstacle_cache_valid = false
	_lane_map.clear()
	invalidate_astar()


func _refresh_global_prefs() -> void:
	_global_visible = false
	_global_flow_glow = false
	# Soft lookup so headless --script selftests can compile ConduitManager
	# without the SimSettingsController autoload identifier.
	var ssc := _autoload("SimSettingsController")
	if ssc != null:
		_global_visible = bool(ssc.get("conduits_3d_visible"))
		_global_flow_glow = bool(ssc.get("conduit_flow_glow_enabled"))


func _autoload(name: String) -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		# Child name under root (not absolute "/root/..." from outside tree).
		return (loop as SceneTree).root.get_node_or_null(name)
	return null


func set_global_visibility(visible: bool) -> void:
	_global_visible = visible
	_refresh_world_visibility()
	if not visible:
		_sync_pending = false
		_remesh_queue.clear()
		_explicit_seen = _any_explicit_visible()
		if not _explicit_seen:
			_clear_all_instances()
			set_process(false)
			return
		# Wires off, but explicitly-visible conns stay: sweep everything else
		# out via the enqueue pass (its `active` set drops non-visible
		# instances) instead of clearing the lot.
		set_process(true)
		_enqueue_all_remesh()
		return
	set_process(true)
	invalidate_obstacle_cache()
	_enqueue_all_remesh()


## Told by SystemGraphView when the SoI preview service activates/deactivates
## (its `preview_active_changed`), i.e. when Site Plan / Elevation CT / the
## Hydro Lab section starts or stops rendering.
func set_preview_visibility(on: bool) -> void:
	if _preview_visible == on:
		return
	_preview_visible = on
	_refresh_world_visibility()


## Conduit materials are deliberately X-RAY (StandardMaterial3D.no_depth_test in
## ConduitKinds.make_material, `depth_test_disabled` in conduit_flow.gdshader) so
## buried runs read through the Elevation / Site CT soil bowl. That is exactly
## what made them confusing in first person: an auto-revealed culvert tailrace or
## routed penstock draws straight through the terrain, hanging over the landscape.
##
## So while the player's "Show 3D wires (world)" preference is OFF, the visuals
## are still BUILT — the rebuild is what stamps route_length_m / endpoint inverts
## for the physics, and explicitly-revealed conns must survive a map reload — but
## the node is HIDDEN, and only unhidden while the graph preview is on screen.
## The preview shares this World3D (own_world_3d = false), so hiding here hides
## it there too; the preview flag is what keeps Site / Elevation / Hydro Lab
## drawing the pipes they exist to show. Wires ON = visible everywhere, as before.
func _refresh_world_visibility() -> void:
	visible = _global_visible or _preview_visible


func set_global_flow_glow(enabled: bool) -> void:
	if _global_flow_glow == enabled:
		return
	_global_flow_glow = enabled
	_last_anchors.clear()
	_last_cheap.clear()
	if _global_visible:
		sync_all()


func invalidate_obstacle_cache() -> void:
	_obstacle_cache_valid = false
	_obstacle_cache.clear()
	invalidate_astar()


func invalidate_astar() -> void:
	_astar_gen += 1
	_last_cheap.clear()
	_last_anchors.clear()


func _on_model_changed(reason: String) -> void:
	if _updating_model:
		return
	# With global 3D wires OFF, explicitly-visible conns (visible_3d == true —
	# routed penstocks, forced culvert tailraces) still render, so structural
	# changes must still schedule a sync for them. Without this, a penstock
	# routed while wires were off simply never existed in 3D — and because the
	# measured length/inverts are stamped inside the rebuild, its physics were
	# dead too ("can't always see the tubing").
	if not _global_visible and not _any_explicit_visible():
		return
	# Tank / telemetry item writes are the hot path during flow_engine — skip.
	# Prop moves call sync_all / invalidate explicitly from SystemGraphView.
	match reason:
		"update_item", "definition":
			return
		"update_connection", "add_connection", "remove_connection", \
				"remove_item", "add_item", "clear", "deserialize":
			_schedule_sync()
		_:
			_schedule_sync()


func _schedule_sync() -> void:
	_sync_pending = true
	_sync_timer = SYNC_DEBOUNCE_S


func sync_all() -> void:
	## Full rebuild pass — prefer _enqueue_all_remesh() on boot/visibility so work
	## is spread across frames (Sch40 kit MultiMesh uploads are expensive).
	if _model == null:
		return
	_sync_pending = false
	_refresh_global_prefs()
	_explicit_seen = _any_explicit_visible()
	if not _global_visible and not _explicit_seen:
		_remesh_queue.clear()
		_clear_all_instances()
		set_process(false)
		return
	set_process(true)
	_enqueue_all_remesh()


## True when any routable connection carries an explicit `visible_3d: true` —
## those render whatever the global 3D-wires toggle says (that is what the
## explicit flag MEANS per ConduitKinds.resolve_visible_3d; the manager's
## global early-outs used to starve them anyway).
func _any_explicit_visible() -> bool:
	if _model == null:
		return false
	for conn: Dictionary in _model.connections:
		if conn.get("visible_3d") == true and _model.connection_is_3d_routable(conn):
			return true
	return false


func _enqueue_all_remesh() -> void:
	if _model == null:
		return
	_explicit_seen = _any_explicit_visible()
	if not _global_visible and not _explicit_seen:
		return
	_migrate_dense_unlocked_routes()
	_rebuild_lane_map()
	var active: Dictionary = {}
	var seen: Dictionary = {}
	for cid: Variant in _remesh_queue:
		seen[str(cid)] = true
	for conn: Dictionary in _model.connections:
		var cid: String = str(conn.get("id", ""))
		if cid.is_empty():
			continue
		if not _model.connection_is_3d_routable(conn):
			continue
		if not ConduitKinds.resolve_visible_3d(conn, _global_visible, _model):
			_remove_instance(cid)
			_last_anchors.erase(cid)
			_last_cheap.erase(cid)
			continue
		active[cid] = true
		if not seen.has(cid):
			_remesh_queue.append(cid)
			seen[cid] = true
	for cid: String in _instances.keys().duplicate():
		if not active.has(cid):
			_remove_instance(cid)
			_last_anchors.erase(cid)
			_last_cheap.erase(cid)
	set_process(true)


func _terrain_load_blocking() -> bool:
	## Hold kit remesh while TerrainLoader is still composing footing — avoids
	## stacking a Sch40 MultiMesh storm on top of DEM/imagery GPU work at boot.
	if _main == null:
		return false
	var tl := _main.get_node_or_null("TerrainLoader")
	if tl == null:
		return false
	if bool(tl.get("load_completed")):
		return false
	# Only block while a fetch/build sequence is actually running. Soak/Mars
	# (or idle TerrainLoader) leave load_completed false without blocking forever.
	return bool(tl.get("_load_sequence_active"))


func _drain_remesh_queue() -> void:
	if _remesh_queue.is_empty() or _model == null:
		return
	if _terrain_load_blocking():
		return
	_perf_begin("conduits_3d")
	var n := 0
	while not _remesh_queue.is_empty() and n < REMESH_BUDGET_PER_FRAME:
		var cid := str(_remesh_queue.pop_front())
		n += 1
		var conn := _model.get_connection(cid)
		if conn.is_empty():
			continue
		if not _model.connection_is_3d_routable(conn):
			continue
		if not ConduitKinds.resolve_visible_3d(conn, _global_visible, _model):
			_remove_instance(cid)
			continue
		# Dirty-key gate — force-remeshing every conn every frame + full-SoI
		# A* was stalling / TDR-crashing GPUs when 3D wires were enabled.
		_rebuild_if_dirty(conn, false)
	_apply_focus_dim()
	_perf_end("conduits_3d")


func reset_all_autoroutes() -> int:
	if _model == null:
		return 0
	var n := 0
	_updating_model = true
	for conn: Dictionary in _model.connections:
		var cid := str(conn.get("id", ""))
		if cid.is_empty():
			continue
		if bool(conn.get("route_locked", false)) \
				or not (conn.get("route_3d", []) as Array).is_empty():
			_model.update_connection(cid, {
				"route_3d": [],
				"route_locked": false,
			})
			n += 1
	_updating_model = false
	_last_anchors.clear()
	_last_cheap.clear()
	if _global_visible:
		sync_all()
	return n


func _process(delta: float) -> void:
	# With wires off, the focused conn AND explicitly-visible conns still tick.
	if _model == null \
			or (not _global_visible and _focus_id.is_empty() and not _explicit_seen):
		return
	# Lab suspend: keep queued remesh drain only (no follow/VFX storm).
	if _main != null and _main.has_method("is_world_suspended_for_lab") \
			and bool(_main.call("is_world_suspended_for_lab")):
		if _sync_pending:
			_sync_timer -= delta
			if _sync_timer <= 0.0:
				_sync_pending = false
				_enqueue_all_remesh()
		if not _remesh_queue.is_empty():
			_drain_remesh_queue()
		return
	if _sync_pending:
		_sync_timer -= delta
		if _sync_timer <= 0.0:
			_sync_pending = false
			_enqueue_all_remesh()
	# Budgeted remesh first so boot/visibility work never starves physics.
	if not _remesh_queue.is_empty():
		_drain_remesh_queue()
		return
	_follow_timer -= delta
	var do_follow := _follow_timer <= 0.0
	if do_follow:
		_follow_timer = FOLLOW_THROTTLE_S
	_perf_begin("conduits_3d")
	for conn: Dictionary in _model.connections:
		var cid: String = str(conn.get("id", ""))
		if cid.is_empty():
			continue
		var focus_only: bool = not _global_visible \
				and (cid == _focus_id or conn.get("visible_3d") == true)
		if not focus_only and not _instances.has(cid):
			continue
		if not _model.connection_is_3d_routable(conn):
			continue
		if not ConduitKinds.resolve_visible_3d(conn, _global_visible or focus_only, _model):
			continue
		if focus_only and not _instances.has(cid):
			_rebuild_if_dirty(conn, true)
		elif do_follow:
			_rebuild_if_dirty(conn, false)
		if _global_flow_glow or cid == _focus_id or conn.get("flow_glow") == true:
			_tick_flow_params(cid, conn)
		_update_discharge_vfx(delta, cid, conn)
	_perf_end("conduits_3d")


func _perf_node() -> Node:
	return _autoload("PerfMonitor")


func _perf_begin(section: String) -> void:
	var pm := _perf_node()
	if pm != null and pm.has_method("begin"):
		pm.call("begin", section)


func _perf_end(section: String) -> void:
	var pm := _perf_node()
	if pm != null and pm.has_method("end"):
		pm.call("end", section)


## Nearest conduit under a world ray. Returns {conn_id, point, segment_i, distance}.
func pick_conduit(origin: Vector3, direction: Vector3,
		max_dist: float = PICK_MAX_DIST_M) -> Dictionary:
	var best := {"conn_id": "", "point": Vector3.ZERO, "segment_i": -1, "distance": INF}
	if direction.length_squared() < 1e-12:
		return best
	for cid: String in _sample_cache.keys():
		var samples: PackedVector3Array = _sample_cache[cid] as PackedVector3Array
		var hit := ConduitKinds.ray_polyline_pick(origin, direction, samples, max_dist)
		if float(hit.get("distance", INF)) < float(best.get("distance", INF)):
			best = {
				"conn_id": cid,
				"point": hit.get("point", Vector3.ZERO),
				"segment_i": int(hit.get("segment_i", -1)),
				"distance": float(hit.get("distance", INF)),
				"t": float(hit.get("t", 0.0)),
			}
	return best


func set_focus_highlight(conn_id: String) -> void:
	if _focus_id == conn_id:
		if not conn_id.is_empty():
			set_process(true)
			force_remesh(conn_id)
		return
	_focus_id = conn_id
	_apply_focus_dim()
	if not conn_id.is_empty():
		set_process(true)
		force_remesh(conn_id)
	# Hang gizmos are cleared by InteractionFocus / route cancel — not here.
	# Clearing on "" wiped ConduitRouteController's drag sphere mid-pin-edit.


func get_focus_id() -> String:
	return _focus_id


func get_sample_points(conn_id: String) -> PackedVector3Array:
	return _sample_cache.get(conn_id, PackedVector3Array()) as PackedVector3Array


## Lightweight sample build for Elevation 2D projection — does NOT remesh.
## Uses cached samples when present; otherwise samples the control polyline.
func ensure_preview_samples(conn: Dictionary) -> PackedVector3Array:
	var cid := str(conn.get("id", ""))
	if cid.is_empty():
		return PackedVector3Array()
	var cached: PackedVector3Array = _sample_cache.get(cid, PackedVector3Array()) as PackedVector3Array
	if cached.size() >= 2:
		return cached
	var control := build_control_points(conn)
	if control.size() < 2:
		return PackedVector3Array()
	var type_id := ConduitKinds.derive_type_for_connection(conn)
	var style_ov: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var mesh_style: Dictionary = style_ov.duplicate(true)
	var rm := ConduitKinds.normalize_route_mode(
			str(style_ov.get("route_mode", ConduitKinds.type_meta(type_id).get("route_mode", ""))))
	var rm_ov := ConduitKinds.mesh_style_override(rm)
	for msk: String in rm_ov.keys():
		if not mesh_style.has(msk):
			mesh_style[msk] = rm_ov[msk]
	var segs := 6 if ConduitKinds.is_pipes_type(type_id) else 8
	var samples := ConduitMeshBuilder.sample_path(control, mesh_style, segs)
	if samples.size() >= 2:
		_sample_cache[cid] = samples
	return samples


func _ensure_waypoint_gizmo() -> ConduitWaypointGizmo:
	if _waypoint_gizmo != null and is_instance_valid(_waypoint_gizmo):
		return _waypoint_gizmo
	_waypoint_gizmo = ConduitWaypointGizmo.new()
	add_child(_waypoint_gizmo)
	return _waypoint_gizmo


## Hover / pin spheres for pin-edit wires (hang cords, kit pipes, PEX/hose/PVC…)
## — only while that wire is focused (or actively dragged). Cord-end plugs stay
## always visible. `hit_point` = crosshair∩polyline; snaps within HANG_PIN_SNAP_M.
func update_hang_hover_gizmo(conn_id: String, hit_point: Vector3,
		dragging: bool = false) -> void:
	var gizmo := _ensure_waypoint_gizmo()
	if conn_id.is_empty() or _model == null:
		gizmo.clear_all()
		gizmo.visible = false
		clear_elbow_highlight()
		return
	var conn := _model.get_connection(conn_id)
	var type_id := ConduitKinds.derive_type_for_connection(conn)
	if not ConduitKinds.supports_pin_edit(type_id):
		gizmo.clear_all()
		gizmo.visible = false
		clear_elbow_highlight()
		return
	gizmo.visible = true
	var pins := PackedVector3Array()
	for v: Vector3 in ConduitKinds.waypoints_to_vectors(
			conn.get("route_3d", []) as Array, null, false):
		pins.append(v)
	gizmo.set_pins(pins)
	var hover_pos := hit_point
	var near := nearest_hang_pin(conn_id, hit_point, HANG_PIN_SNAP_M)
	if int(near.get("index", -1)) >= 0:
		hover_pos = near.get("position", hit_point) as Vector3
	if dragging:
		gizmo.set_drag(hover_pos, true)
		gizmo.set_hover(hover_pos, false)
	else:
		gizmo.set_drag(hover_pos, false)
		gizmo.set_hover(hover_pos, true)
	# Kit pipes: cheap orb on nearest elbow (skip while dragging — drag sphere owns cue).
	if not dragging and ConduitKinds.supports_pipe_pin_edit(type_id):
		var elbow := nearest_elbow(conn_id, hover_pos, 0.85)
		if int(elbow.get("index", -1)) >= 0:
			set_elbow_highlight(conn_id, int(elbow.get("index", -1)))
		else:
			clear_elbow_highlight()
	elif dragging:
		clear_elbow_highlight()
	else:
		clear_elbow_highlight()


func set_hang_drag_gizmo(pos: Vector3, on: bool) -> void:
	var gizmo := _ensure_waypoint_gizmo()
	gizmo.visible = on or gizmo.visible
	if on:
		gizmo.visible = true
	gizmo.set_drag(pos, on)
	if on:
		gizmo.set_hover(pos, false)


func clear_hang_gizmos() -> void:
	if _waypoint_gizmo != null and is_instance_valid(_waypoint_gizmo):
		_waypoint_gizmo.clear_all()
		_waypoint_gizmo.visible = false
	clear_elbow_highlight()


## Nearest cached kit elbow to a world point. {index, position, bend_deg, transform}.
func nearest_elbow(conn_id: String, world_point: Vector3,
		max_dist_m: float = 0.85) -> Dictionary:
	var out := {"index": -1, "position": Vector3.ZERO, "bend_deg": 0.0}
	var elbows: Array = _elbow_cache.get(conn_id, []) as Array
	if elbows.is_empty():
		return out
	var best_i := -1
	var best_d := max_dist_m
	var best: Dictionary = {}
	for i: int in range(elbows.size()):
		var e: Dictionary = elbows[i]
		var corner: Vector3 = e.get("corner", Vector3.ZERO) as Vector3
		if corner == Vector3.ZERO:
			var xf: Transform3D = e.get("transform", Transform3D()) as Transform3D
			corner = xf.origin
		var d := corner.distance_to(world_point)
		if d <= best_d:
			best_d = d
			best_i = i
			best = e
			best["corner"] = corner
	if best_i < 0:
		return out
	return {
		"index": best_i,
		"position": best.get("corner", Vector3.ZERO) as Vector3,
		"bend_deg": float(best.get("bend_deg", 0.0)),
		"transform": best.get("transform", Transform3D()) as Transform3D,
		"distance": best_d,
	}


## Cheap unshaded orb at the elbow corner (no GLB duplicate / clearcoat).
func set_elbow_highlight(conn_id: String, elbow_index: int) -> void:
	var elbows: Array = _elbow_cache.get(conn_id, []) as Array
	if elbow_index < 0 or elbow_index >= elbows.size():
		clear_elbow_highlight()
		return
	var key := "%s:%d" % [conn_id, elbow_index]
	var e: Dictionary = elbows[elbow_index]
	var corner: Vector3 = e.get("corner", Vector3.ZERO) as Vector3
	if corner == Vector3.ZERO:
		var xf0: Transform3D = e.get("transform", Transform3D()) as Transform3D
		corner = xf0.origin
	# Same fitting — only refresh position (handles moving props), skip allocs.
	if key == _elbow_hl_key and _elbow_highlight != null \
			and is_instance_valid(_elbow_highlight) and _elbow_highlight.visible:
		_elbow_highlight.global_position = corner
		return
	_elbow_hl_key = key
	if _elbow_highlight == null or not is_instance_valid(_elbow_highlight):
		_elbow_highlight = MeshInstance3D.new()
		_elbow_highlight.name = "ElbowHighlight"
		_elbow_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sm := SphereMesh.new()
		sm.radius = 0.11
		sm.height = 0.22
		sm.radial_segments = 10
		sm.rings = 6
		_elbow_highlight.mesh = sm
		add_child(_elbow_highlight)
	if _elbow_hl_mat == null:
		_elbow_hl_mat = StandardMaterial3D.new()
		_elbow_hl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_elbow_hl_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_elbow_hl_mat.albedo_color = Color(1.0, 0.4, 0.12, 0.75)
		_elbow_hl_mat.emission_enabled = true
		_elbow_hl_mat.emission = Color(1.0, 0.45, 0.15)
		_elbow_hl_mat.emission_energy_multiplier = 1.4
		_elbow_hl_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_elbow_highlight.material_override = _elbow_hl_mat
	_elbow_highlight.global_position = corner
	_elbow_highlight.visible = true


func clear_elbow_highlight() -> void:
	_elbow_hl_key = ""
	if _elbow_highlight != null and is_instance_valid(_elbow_highlight):
		_elbow_highlight.visible = false


## Nearest persisted hang pin to a world point. {index, position} or index -1.
func nearest_hang_pin(conn_id: String, world_point: Vector3,
		max_dist_m: float = HANG_PIN_SNAP_M) -> Dictionary:
	var out := {"index": -1, "position": Vector3.ZERO}
	if _model == null or conn_id.is_empty():
		return out
	var conn := _model.get_connection(conn_id)
	if conn.is_empty():
		return out
	var best_i := -1
	var best_d := max_dist_m
	var best_p := Vector3.ZERO
	var i := 0
	for v: Vector3 in ConduitKinds.waypoints_to_vectors(
			conn.get("route_3d", []) as Array, null, false):
		var d := v.distance_to(world_point)
		if d <= best_d:
			best_d = d
			best_i = i
			best_p = v
		i += 1
	if best_i < 0:
		return out
	return {"index": best_i, "position": best_p, "distance": best_d}


## Ray vs hang-pin spheres (so aiming at the IK orb grabs that pin, not a new insert).
## Returns {index, position, distance} or index -1.
func pick_hang_pin(conn_id: String, origin: Vector3, direction: Vector3,
		grab_radius_m: float = HANG_PIN_GRAB_M) -> Dictionary:
	var out := {"index": -1, "position": Vector3.ZERO, "distance": INF}
	if _model == null or conn_id.is_empty() or direction.length_squared() < 1e-12:
		return out
	var dir := direction.normalized()
	var conn := _model.get_connection(conn_id)
	if conn.is_empty():
		return out
	var best_i := -1
	var best_perp := grab_radius_m
	var best_p := Vector3.ZERO
	var i := 0
	for v: Vector3 in ConduitKinds.waypoints_to_vectors(
			conn.get("route_3d", []) as Array, null, false):
		var to_p := v - origin
		var along := to_p.dot(dir)
		if along < 0.05 or along > 80.0:
			i += 1
			continue
		var closest := origin + dir * along
		var perp := closest.distance_to(v)
		if perp <= best_perp:
			best_perp = perp
			best_i = i
			best_p = v
		i += 1
	if best_i < 0:
		return out
	return {"index": best_i, "position": best_p, "distance": best_perp}


## Find the nearest pin under the crosshair across all pin-edit connections
## (hang cords, kit pipes, flex/rigid tubes). Returns {conn_id, index, …} or empty.
func pick_any_hang_pin(origin: Vector3, direction: Vector3,
		grab_radius_m: float = HANG_PIN_GRAB_M) -> Dictionary:
	var best := {"conn_id": "", "index": -1, "position": Vector3.ZERO, "distance": INF}
	if _model == null or direction.length_squared() < 1e-12:
		return best
	for conn: Dictionary in _model.connections:
		var type_id := ConduitKinds.derive_type_for_connection(conn)
		if not ConduitKinds.supports_pin_edit(type_id):
			continue
		if (conn.get("route_3d", []) as Array).is_empty():
			continue
		# Prefer currently rendered wires when the global 3D toggle is on.
		var cid0 := str(conn.get("id", ""))
		if _global_visible and not _instances.has(cid0) \
				and not ConduitKinds.resolve_visible_3d(conn, true, _model):
			continue
		var cid := str(conn.get("id", ""))
		var hit := pick_hang_pin(cid, origin, direction, grab_radius_m)
		var idx := int(hit.get("index", -1))
		if idx < 0:
			continue
		var d := float(hit.get("distance", INF))
		if d < float(best.get("distance", INF)):
			best = {
				"conn_id": cid,
				"index": idx,
				"position": hit.get("position", Vector3.ZERO),
				"distance": d,
			}
	return best


func _apply_focus_dim() -> void:
	for cid: String in _instances.keys():
		var inst: MeshInstance3D = _instances[cid]
		if inst == null or not is_instance_valid(inst):
			continue
		var focused := (not _focus_id.is_empty()) and cid == _focus_id
		var dimmed := (not _focus_id.is_empty()) and not focused
		inst.transparency = FOCUS_DIM if dimmed else 0.0
		var mat: Material = inst.material_override
		if mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			var conn := _model.get_connection(cid) if _model != null else {}
			var type_id: String = ConduitKinds.derive_type_for_connection(conn)
			var style_ov: Dictionary = conn.get("conduit_style", {}) as Dictionary
			var quiet := not _global_flow_glow and not focused
			var base_boost := float(style_ov.get("emission_energy",
				0.55 if ConduitKinds.is_conceptual_type(type_id) else 1.2))
			if quiet and ConduitKinds.is_conceptual_type(type_id):
				base_boost = minf(base_boost, 0.55)
			sm.set_shader_parameter("emission_boost", 2.4 if focused else base_boost)
			if quiet:
				sm.set_shader_parameter("flow_strength", 0.0)
		# End plugs / collars stay visible — only IK hang spheres are focus-gated.
		for f: Variant in _fittings.get(cid, []) as Array:
			if f is GeometryInstance3D:
				var gi := f as GeometryInstance3D
				gi.visible = true
				gi.transparency = FOCUS_DIM if dimmed else 0.0
		# GLB pipe-part MultiMeshes (ABS kit) follow the same dim policy.
		var parts_host := get_node_or_null("PipeParts_%s" % cid)
		if parts_host != null:
			for c in parts_host.get_children():
				if c is GeometryInstance3D:
					(c as GeometryInstance3D).transparency = FOCUS_DIM if dimmed else 0.0


func _tick_flow_params(cid: String, conn: Dictionary) -> void:
	const Q_REF_LPS := 8.0
	var amps: float = absf(float(conn.get("carried_amps", 0.0)))
	var rate_lph: float = absf(float(conn.get("flow_rate", 0.0)))
	var live_q: float = absf(float(conn.get("live_q_lps", 0.0)))
	var activity: float = maxf(amps / 15.0, maxf(live_q / Q_REF_LPS, (rate_lph / 3600.0) / Q_REF_LPS))
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	var glow_on := ConduitKinds.resolve_flow_glow(conn, type_id, _global_flow_glow) \
			or cid == _focus_id
	var strength: float = 0.0
	if glow_on:
		strength = 0.45 + clampf(activity, 0.0, 1.0) * 0.55
		if ConduitKinds.is_conceptual_type(type_id):
			strength = maxf(strength, 0.5)
		if live_q > 0.02:
			strength = maxf(strength, 0.7)
	var speed: float = 0.5 + clampf(activity, 0.0, 1.5) * 1.6
	# Pulse emission on PE culvert rings (StandardMaterial — survives SoI CT clip).
	var pulse := 0.9 + 0.55 * sin(Time.get_ticks_msec() * 0.001 * (2.0 + speed * 3.0))
	var emit_e := (1.2 + strength * 3.5) * pulse if glow_on else 0.0
	for host_name in ["CulvertParts_%s" % cid, "PipeParts_%s" % cid]:
		var host := get_node_or_null(host_name) as Node3D
		if host == null:
			continue
		for c in host.get_children():
			if not (c is GeometryInstance3D):
				continue
			var gi := c as GeometryInstance3D
			var mat: Material = gi.material_override
			if mat is StandardMaterial3D:
				var sm0 := mat as StandardMaterial3D
				if glow_on:
					sm0.emission_enabled = true
					sm0.emission = Color(0.12, 0.78, 1.0, 1.0)
					sm0.emission_energy_multiplier = emit_e
					sm0.albedo_color = Color(0.4, 0.75, 0.98, 1.0).lerp(
							Color(0.65, 0.9, 1.0, 1.0), clampf(activity, 0.0, 1.0))
				continue
			if mat is ShaderMaterial:
				var sm := mat as ShaderMaterial
				sm.set_shader_parameter("flow_strength", strength)
				sm.set_shader_parameter("flow_speed", speed)
	var inst: MeshInstance3D = _instances.get(cid, null)
	if inst != null and inst.material_override is ShaderMaterial:
		var smi := inst.material_override as ShaderMaterial
		smi.set_shader_parameter("flow_strength", strength)
		smi.set_shader_parameter("flow_speed", speed)


## Water jet at a culvert's outlet mouth, driven by the live flow. Only culvert
## connections get one; the node is created lazily the first time real flow
## appears (so idle culverts spawn no particles) and thereafter self-idles when
## flow stops. Position/direction come from the cached sample polyline
## (source→target order, so the last point is the outlet mouth). Freed per-cid
## in _remove_instance.
func _update_discharge_vfx(delta: float, cid: String, conn: Dictionary) -> void:
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	if not ConduitKinds.uses_culvert_kit(type_id) \
			and str(conn.get("conduit_type", "")) != "culvert_pipe":
		return
	var live_q: float = absf(float(conn.get("live_q_lps", 0.0)))
	var vfx: ConduitDischargeVfx = _discharge_vfx.get(cid, null)
	if vfx == null and live_q <= ConduitDischargeVfx.Q_MIN_LPS:
		return  # never flowed — don't spawn a particle node for a dry culvert
	var samples := get_sample_points(cid)
	if samples.size() < 2:
		return
	var mouth: Vector3 = samples[samples.size() - 1]
	var dir: Vector3 = mouth - samples[samples.size() - 2]
	if vfx == null:
		vfx = ConduitDischargeVfx.new()
		vfx.name = "DischargeVfx_%s" % cid
		add_child(vfx)
		_discharge_vfx[cid] = vfx
	vfx.set_flow(delta, live_q, mouth, dir)


## Resolve global anchor for a graph item.
## Order: tagged port (handle) → conduit_anchor → bound prop → scene path → site.
static func anchor_global_for_item(item: Dictionary, tree: SceneTree,
		handle_id: String = "", main: Node = null) -> Vector3:
	if tree == null or item.is_empty():
		return Vector3.INF
	var main_node: Node = main
	if main_node == null:
		main_node = tree.current_scene
	# 1) Tagged connection port for this handle (or first port).
	var port_anchor := _port_anchor_for_item(item, handle_id, main_node)
	if is_finite(port_anchor.x):
		return port_anchor
	# 2/3/4) Bound prop or scene node with conduit_anchor children.
	var node := _resolve_item_node3d(item, tree, main_node)
	if node != null:
		var tagged := ConnectionPortDefs.find_anchor_node(node, handle_id)
		if tagged != null:
			return tagged.global_position
		return _anchor_from_node(node)
	# 5) Site plan fallback.
	return _site_anchor_for_item(item, main_node)


static func _port_anchor_for_item(item: Dictionary, handle_id: String,
		main: Node) -> Vector3:
	var info := resolve_port_binding(item, handle_id, main)
	return info.get("pos", Vector3.INF) as Vector3


## {port, model_root, pos, approach, outward} — empty port if unbound.
static func resolve_port_binding(item: Dictionary, handle_id: String,
		main: Node) -> Dictionary:
	var out := {
		"port": {},
		"model_root": null,
		"pos": Vector3.INF,
		"approach": Vector3.INF,
		"outward": Vector3.ZERO,
	}
	if main == null or item.is_empty():
		return out
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	var ports := ConnectionPortDefs.resolve_ports_for_item(item, main)
	if ports.is_empty():
		return out
	var port := ConnectionPortDefs.find_port_for_handle(ports, handle_id)
	if port.is_empty() and handle_id.is_empty() and not ports.is_empty():
		port = ports[0] as Dictionary
	if port.is_empty():
		return out
	var prop: PlacedProp = null
	if not prop_id.is_empty():
		prop = PlacedPropRuntime.find_by_prop_id(main, prop_id)
	if prop == null:
		return out
	var model_root := prop.get_node_or_null("ModelRoot") as Node3D
	if model_root == null:
		model_root = prop
	var pos := ConnectionPortDefs.world_pos_for_port(port, model_root)
	var outward := ConnectionPortDefs.world_outward_for_port(port, model_root)
	var approach := ConnectionPortDefs.world_approach_point(port, model_root)
	out["port"] = port
	out["model_root"] = model_root
	out["pos"] = pos
	out["approach"] = approach
	out["outward"] = outward
	return out


static func _resolve_item_node3d(item: Dictionary, tree: SceneTree,
		main: Node) -> Node3D:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	if not prop_id.is_empty() and main != null:
		var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id)
		if prop != null:
			return prop
	var path := _scene_path_from_item(item)
	if path.is_empty():
		return null
	var node: Node = tree.root.get_node_or_null(NodePath(path))
	if node is Node3D and is_instance_valid(node):
		return node as Node3D
	return null


static func _site_anchor_for_item(item: Dictionary, main: Node) -> Vector3:
	if not GraphSiteLayout.has_site_coords(item):
		return Vector3.INF
	var center := Vector3.ZERO
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root_n: Node = (loop as SceneTree).root
		if root_n != null:
			var svc := root_n.get_node_or_null("SoiService")
			if svc != null and svc.has_method("world_center"):
				center = svc.call("world_center") as Vector3
	var site := GraphSiteLayout.site_xz(item)
	var wxz := GraphSiteLayout.site_to_world_xz(site, center)
	var gy := 0.0
	if item.has("elevation_m"):
		gy = float(item.get("elevation_m", 0.0))
	elif main != null and main.is_inside_tree():
		gy = TerrainSurfaceQuery.ground_height_at(main, wxz.x, wxz.y)
	return Vector3(wxz.x, gy + SITE_CLEARANCE_M, wxz.y)


static func _scene_path_from_item(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var p: String = str(specs.get("scene_device_path", ""))
	if not p.is_empty():
		return p
	return str(item.get("device_path", ""))


static func _anchor_from_node(node: Node) -> Vector3:
	if node is Node3D:
		var tagged := ConnectionPortDefs.find_anchor_node(node, "")
		if tagged != null:
			return tagged.global_position
		# Prefer mid-height of model AABB when available.
		var model := (node as Node3D).get_node_or_null("ModelRoot") as Node3D
		if model != null:
			var aabb := _mesh_aabb(model)
			if aabb.size.length_squared() > 1e-6:
				return model.to_global(aabb.get_center())
		return (node as Node3D).global_position + Vector3(0.0, 0.5, 0.0)
	return Vector3.INF


static func _mesh_aabb(root: Node3D) -> AABB:
	var acc := AABB()
	var any := false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var local := mi.get_aabb()
		var xf: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
		var world_local := xf * local
		if not any:
			acc = world_local
			any = true
		else:
			acc = acc.merge(world_local)
	return acc if any else AABB()


func build_control_points(conn: Dictionary) -> Array:
	var src := _model.get_item(str(conn.get("source_item_id", "")))
	var tgt := _model.get_item(str(conn.get("target_item_id", "")))
	var tree: SceneTree = null
	if is_inside_tree():
		tree = get_tree()
	elif Engine.get_main_loop() is SceneTree:
		tree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return []
	var src_h := str(conn.get("source_handle_id", ""))
	var tgt_h := str(conn.get("target_handle_id", ""))
	var a: Vector3 = anchor_global_for_item(src, tree, src_h, _main)
	var b: Vector3 = anchor_global_for_item(tgt, tree, tgt_h, _main)
	if not is_finite(a.x) or not is_finite(b.x):
		return []
	var locked := bool(conn.get("route_locked", false))
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	# End/approach/seat resolution + the route-mode cascade now live in the shared
	# ConduitRouteDispatch so the drag preview and this committed build stay in
	# lockstep (see conduit_route_dispatch.gd). Committed routes always run the full
	# obstacle-aware A* (allow_astar = true).
	var ends := ConduitRouteDispatch.resolve_route_ends(a, b, src, tgt, src_h, tgt_h, type_id, _main)
	# Hang / kit-pipe pins are surface XYZ — never rebind to collider origins
	# (StarShade PropBody sits near the ground; resolving pin_path yanked runs).
	var resolve_pins := not ConduitKinds.supports_pin_edit(type_id)
	var wps: Array = ConduitKinds.waypoints_to_vectors(
		conn.get("route_3d", []) as Array, tree, resolve_pins) if locked else []
	var style_ov: Dictionary = conn.get("conduit_style", {}) as Dictionary
	return ConduitRouteDispatch.control_points(ends, type_id, style_ov, wps, locked,
		_cached_obstacles([]), true, SITE_CLEARANCE_M, Callable(self, "ground_y_at"))


## Sparse chain: [port_a,] approach_a, leave_shoulder, pins…, arrive_shoulder, approach_b [,port_b].
## Leave/arrive shoulders keep port↔approach colinear so kit elbows land before the stub.
static func _approach_chain(port_a: Vector3, port_b: Vector3,
		a_route: Vector3, b_route: Vector3, wps: Array,
		seat_a: bool, seat_b: bool, out_a: Vector3, out_b: Vector3,
		shoulder_m: float = 0.22) -> Array:
	var chain: Array = []
	if seat_a:
		chain.append(port_a)
	chain.append(a_route)
	if seat_a and out_a.length_squared() > 1e-8:
		chain.append(a_route + out_a.normalized() * shoulder_m)
	for wp: Variant in wps:
		if wp is Vector3:
			chain.append(wp as Vector3)
	if seat_b and out_b.length_squared() > 1e-8:
		chain.append(b_route + out_b.normalized() * shoulder_m)
	chain.append(b_route)
	if seat_b:
		chain.append(port_b)
	return chain


## Seat true ports onto a mid path between approaches. When `legalize`, force
## leave/arrive along outward then run PipeFittingExpander so seat corners stay kit-legal.
static func _seat_approaches_legal(port_a: Vector3, port_b: Vector3, mid: Array,
		seat_a: bool, seat_b: bool, out_a: Vector3, out_b: Vector3,
		legalize: bool, fit_step: float, shoulder_m: float = 0.22) -> Array:
	var step := fit_step if fit_step > 0.5 else 45.0
	var pts: Array = []
	for p: Variant in mid:
		if p is Vector3:
			pts.append(p as Vector3)
	if pts.is_empty():
		# No mid path — fall back to a straight run between the two ports.
		pts = [port_a, port_b]
	# Force leave along +outward_a so port→approach→leave is colinear.
	if seat_a and out_a.length_squared() > 1e-8 and pts.size() >= 1:
		var oa := out_a.normalized()
		var approach_a: Vector3 = pts[0] as Vector3
		var need_leave := true
		if pts.size() >= 2:
			var d1: Vector3 = (pts[1] as Vector3) - approach_a
			if d1.length_squared() > 1e-8 and d1.normalized().dot(oa) > 0.85:
				need_leave = false
		if need_leave:
			var leave := approach_a + oa * shoulder_m
			var rest: Array = [leave]
			for i: int in range(1, pts.size()):
				rest.append(pts[i])
			if legalize:
				var exp := PipeFittingExpander.expand(rest, step)
				pts = [approach_a]
				for p: Vector3 in exp:
					if pts.is_empty() \
							or (pts[pts.size() - 1] as Vector3).distance_to(p) > 0.02:
						pts.append(p)
			else:
				var rebuilt_leave: Array = [approach_a, leave]
				for i: int in range(1, pts.size()):
					rebuilt_leave.append(pts[i])
				pts = rebuilt_leave
	# Force arrive along −outward_b (from free space into the socket).
	if seat_b and out_b.length_squared() > 1e-8 and pts.size() >= 1:
		var ob := out_b.normalized()
		var approach_b: Vector3 = pts[pts.size() - 1] as Vector3
		var need_arrive := true
		if pts.size() >= 2:
			var d_in: Vector3 = approach_b - (pts[pts.size() - 2] as Vector3)
			if d_in.length_squared() > 1e-8 and d_in.normalized().dot(-ob) > 0.85:
				need_arrive = false
		if need_arrive:
			var arrive := approach_b + ob * shoulder_m
			var head: Array = []
			for i: int in range(pts.size() - 1):
				head.append(pts[i])
			head.append(arrive)
			if legalize:
				var exp2 := PipeFittingExpander.expand(head, step)
				pts = []
				for p: Vector3 in exp2:
					pts.append(p)
				pts.append(approach_b)
			else:
				pts = head
				pts.append(approach_b)
	var seated := _with_port_seats(port_a, port_b, pts, seat_a, seat_b)
	if legalize and seated.size() >= 3:
		var packed := PackedVector3Array()
		for p: Variant in seated:
			if p is Vector3:
				packed.append(p as Vector3)
		return _packed_to_array(PipeFittingExpander.legalize_corners(packed, step))
	return seated


## Prepend/append true port seats so the final segments run along −outward.
static func _with_port_seats(port_a: Vector3, port_b: Vector3, mid: Array,
		seat_a: bool, seat_b: bool) -> Array:
	var out: Array = []
	if seat_a:
		out.append(port_a)
	for p: Variant in mid:
		if p is Vector3:
			var v: Vector3 = p as Vector3
			if out.is_empty() or (out[out.size() - 1] as Vector3).distance_to(v) > 0.02:
				out.append(v)
	if seat_b:
		if out.is_empty() or (out[out.size() - 1] as Vector3).distance_to(port_b) > 0.02:
			out.append(port_b)
	if out.size() < 2:
		return [port_a, port_b]
	return out


## Unlocked A* path on a *local* A–B corridor (soft elbows). Empty → caller
## falls back to ConduitPipesRouter.
func autoroute_points(a: Vector3, b: Vector3,
		elbow_radius_frac: float = ConduitPipesRouter.DEFAULT_ELBOW_FRAC) -> Array:
	var packed := ConduitAStar.route_local(
		a, b, _cached_obstacles([]), elbow_radius_frac, SITE_CLEARANCE_M)
	return _packed_to_array(packed)


## Public accessor for the cached prop-obstacle set — lets the drag preview
## (conduit_route_controller) feed the SAME obstacles the committed route uses into
## ConduitRouteDispatch, so a settled preview bends around props exactly like the
## wire it commits to. Cheap: hits the shared cache (rebuilt only on invalidation).
func route_obstacles() -> Array:
	return _cached_obstacles([])


## Site clearance the route A* uses — exposed so the preview can call the shared
## dispatch with the same value.
func route_site_clearance_m() -> float:
	return SITE_CLEARANCE_M


static func _packed_to_array(packed: PackedVector3Array) -> Array:
	var out: Array = []
	for p: Vector3 in packed:
		out.append(p)
	return out


func _soi_center() -> Vector3:
	var svc := _autoload("SoiService")
	if svc != null and svc.has_method("world_center"):
		return svc.call("world_center") as Vector3
	return Vector3.ZERO


## Clear manual 3D waypoints and re-run A* / pipes. Keeps site_waypoints (2D).
func reset_autoroute(conn_id: String) -> void:
	if _model == null or conn_id.is_empty():
		return
	_updating_model = true
	_model.update_connection(conn_id, {
		"route_3d": [],
		"route_locked": false,
	})
	_updating_model = false
	force_remesh(conn_id)


## Force a remesh of one connection (style modal Apply / kit size change).
## Bypasses the cheap dirty-key short-circuit so Sch40 elbows always reseat.
func force_remesh(conn_id: String) -> void:
	if _model == null or conn_id.is_empty():
		return
	_last_anchors.erase(conn_id)
	_last_cheap.erase(conn_id)
	var conn := _model.get_connection(conn_id)
	if conn.is_empty():
		return
	# Focused Lab culvert AND explicitly-visible conns remesh even when the
	# global 3D wires toggle is off.
	if not _global_visible and conn_id != _focus_id \
			and conn.get("visible_3d") != true:
		return
	if not _model.connection_is_3d_routable(conn):
		return
	_explicit_seen = _explicit_seen or conn.get("visible_3d") == true
	set_process(true)
	_rebuild_if_dirty(conn, true)


func _site_to_world(site: Vector2) -> Vector2:
	return GraphSiteLayout.site_to_world_xz(site, _soi_center())


## Grab-and-plug: create a new graph connection from a ConduitPlugLogic spec and
## immediately build its 3D wire. Returns the new connection id (or "").
func create_plug_connection(spec: Dictionary) -> String:
	if _model == null:
		return ""
	var si := str(spec.get("source_item_id", ""))
	var ti := str(spec.get("target_item_id", ""))
	if si.is_empty() or ti.is_empty() or si == ti:
		return ""
	if _model.get_item(si).is_empty() or _model.get_item(ti).is_empty():
		return ""
	var conn: Dictionary = spec.duplicate(true)
	conn.erase("id")  # let the model mint a fresh id
	_updating_model = true
	_model.add_connection(conn)
	_updating_model = false
	var cid := str(conn.get("id", ""))
	if cid.is_empty():
		return ""
	_last_anchors.erase(cid)
	_last_cheap.erase(cid)
	var live := _model.get_connection(cid)
	if not live.is_empty() and _global_visible:
		_rebuild_if_dirty(live, true)
	return cid


## All live in-world connection ports as plug-hits for ConduitPlugLogic:
## [{port, world_pos, item_id}] — resolved from every graph item bound to a placed
## prop (reuses ConnectionPortDefs port resolution + marker transforms).
func gather_world_ports() -> Array:
	var out: Array = []
	if _model == null:
		return []
	for it: Dictionary in _model.items:
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var pid := str(specs.get("bound_prop_id", ""))
		if pid.is_empty():
			continue
		var prop := PlacedPropRuntime.find_by_prop_id(_main, pid)
		if prop == null:
			continue
		var model_root := prop.get_node_or_null("ModelRoot") as Node3D
		if model_root == null:
			continue
		var ports: Array = ConnectionPortDefs.resolve_ports_for_item(it, _main)
		for p: Variant in ports:
			if not (p is Dictionary):
				continue
			var wp: Vector3 = ConnectionPortDefs.world_pos_for_port(p as Dictionary, model_root)
			if not is_finite(wp.x):
				continue
			out.append({"port": p, "world_pos": wp, "item_id": str(it.get("id", ""))})
	return out


func preview_mesh(control_points: Array, type_id: String) -> Dictionary:
	var ground_fn := Callable()
	if ConduitKinds.is_ground_drape_type(type_id):
		ground_fn = Callable(self, "ground_y_at")
	return ConduitMeshBuilder.build(control_points, type_id,
		ConduitMeshBuilder.DEFAULT_SEGMENTS_PER_SPAN, ground_fn)


## Cheap dirty key: endpoints + lock/type/style — no pathfind.
func _cheap_dirty_key(conn: Dictionary) -> String:
	var tree: SceneTree = null
	if is_inside_tree():
		tree = get_tree()
	elif Engine.get_main_loop() is SceneTree:
		tree = Engine.get_main_loop() as SceneTree
	if tree == null or _model == null:
		return ""
	var src := _model.get_item(str(conn.get("source_item_id", "")))
	var tgt := _model.get_item(str(conn.get("target_item_id", "")))
	var a: Vector3 = anchor_global_for_item(
		src, tree, str(conn.get("source_handle_id", "")), _main)
	var b: Vector3 = anchor_global_for_item(
		tgt, tree, str(conn.get("target_handle_id", "")), _main)
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	var style_ov: Dictionary = conn.get("conduit_style", {}) as Dictionary
	# site_waypoints intentionally omitted — 2D site bends do not dirty 3D mesh.
	# Hash route_3d (not just count) so hang-edit pin moves rebuild the mesh.
	var route_key := str((conn.get("route_3d", []) as Array).hash())
	var kit_id := ConduitKinds.pipe_kit_id(type_id, style_ov)
	var kit_rev := 0
	if not kit_id.is_empty():
		if ConduitKinds.uses_culvert_kit(type_id):
			var ckit := _get_culvert_kit(kit_id)
			if ckit != null:
				kit_rev = ckit.revision
		else:
			var kit := _get_pipe_kit(kit_id)
			if kit != null:
				kit_rev = kit.revision
	return "%s|%s|%d|%s|%s|%s|%d|%s|%d" % [
		_v3_key(a), _v3_key(b),
		1 if bool(conn.get("route_locked", false)) else 0,
		type_id,
		str(style_ov.hash()) if not style_ov.is_empty() else "",
		route_key,
		_astar_gen,
		kit_id,
		kit_rev,
	]


static func _v3_key(v: Vector3) -> String:
	# Quantize to ~2 cm so tiny jitter doesn't remesh every frame.
	return "%.2f,%.2f,%.2f" % [v.x, v.y, v.z]


func _rebuild_if_dirty(conn: Dictionary, force: bool = false) -> void:
	var cid: String = str(conn.get("id", ""))
	if cid.is_empty():
		return
	var cheap := _cheap_dirty_key(conn)
	if not force and _last_cheap.get(cid, "") == cheap and _instances.has(cid):
		_apply_severed_state(cid, bool(conn.get("severed", false)))
		return
	var control := build_control_points(conn)
	if control.size() < 2:
		_remove_instance(cid)
		_last_cheap.erase(cid)
		return
	var severed: bool = bool(conn.get("severed", false))
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	var style_ov: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var glow_on := ConduitKinds.resolve_flow_glow(conn, type_id, _global_flow_glow)
	var sig := _control_signature(control)
	var style_hash := str(style_ov.hash()) if not style_ov.is_empty() else ""
	var glow_key := "%s|%s|%d|%s" % [cid, type_id, 1 if glow_on else 0, style_hash]
	var geom_same := _last_anchors.has(cid) and (_last_anchors[cid] as PackedVector3Array) == sig
	var glow_same := str(get_meta("_glow_%s" % cid, "")) == glow_key
	_last_cheap[cid] = cheap
	if geom_same and glow_same and _instances.has(cid):
		_apply_severed_state(cid, severed)
		return
	_last_anchors[cid] = sig
	set_meta("_glow_%s" % cid, glow_key)
	var tint := Color(0, 0, 0, 0)
	if style_ov.has("color"):
		tint = style_ov["color"] as Color
	elif ConduitKinds.is_conceptual_type(type_id):
		tint = ConduitKinds.flow_tint_for_connection(conn)
	# ABS DWV (etc.): assemble real straight + elbow GLB parts when the kit loads.
	if _try_rebuild_pipe_parts(cid, conn, type_id, control, tint, severed):
		return
	PipePartsAssembler.clear(self, cid)
	CulvertAssembler.clear(self, cid)
	_parts_active.erase(cid)
	# Pipes / rigid runs are already elbowed — do not re-drape samples.
	var ground_fn := Callable()
	var rm := ConduitKinds.normalize_route_mode(
		str(style_ov.get("route_mode", ConduitKinds.type_meta(type_id).get("route_mode", ""))))
	var is_pipes := rm == "pipes" or ConduitKinds.is_pipes_type(type_id)
	# Merge route-mode sag behaviour (taut = straight, catenary = overhead hang)
	# under any explicit conduit_style so the tube samples match the routing.
	var mesh_style: Dictionary = style_ov.duplicate(true)
	var rm_ov := ConduitKinds.mesh_style_override(rm)
	for msk: String in rm_ov.keys():
		if not mesh_style.has(msk):
			mesh_style[msk] = rm_ov[msk]
	# Draw the tube at its STYLED nominal size. The mesh builder reads radius_m
	# straight off the kind meta, so without this every poly penstock rendered
	# at the kind's single fallback radius and a 2" run looked identical to a
	# 1" one — the diameter is the main thing the player is tuning.
	if not mesh_style.has("radius_m"):
		var od := ConduitKinds.outer_diameter_m(type_id, style_ov)
		if od > 0.0 and ConduitKinds.has_size_options(type_id):
			mesh_style["radius_m"] = od * 0.5
	# Hang-edit with locked mid pins: span-wise catenary (not whole-run ground-snake).
	# Still pass terrain so sag that hits the ground rests on it (no under-mesh).
	var hang_sag := ConduitKinds.conn_uses_hang_sag(conn)
	if hang_sag:
		var hang_ov := ConduitKinds.mesh_style_override("catenary")
		for hk: String in hang_ov.keys():
			mesh_style[hk] = hang_ov[hk]
		mesh_style["terrain_clamp"] = true
		ground_fn = Callable(self, "ground_y_at")
	var no_drape := rm == "taut" or rm == "catenary" or hang_sag
	if not is_pipes and not hang_sag and not no_drape \
			and (ConduitKinds.is_ground_drape_type(type_id) \
			or bool(style_ov.get("ground_drape", false))):
		ground_fn = Callable(self, "ground_y_at")
	elif not is_pipes and not hang_sag and ConduitKinds.supports_hang_edit(type_id) \
			and rm != "taut":
		# Patio / hang-edit catenary: free sag in air, clamp where it meets terrain.
		mesh_style["terrain_clamp"] = true
		ground_fn = Callable(self, "ground_y_at")
	var is_light: bool = ConduitKinds.is_light_type(type_id)
	# Contour routes carry ~1 m control spacing already — default per-span
	# tessellation on 160 spans would be thousands of ring segments.
	var is_contour := rm == "contour"
	var segs := 8 if is_pipes \
			else (2 if is_contour else ConduitMeshBuilder.DEFAULT_SEGMENTS_PER_SPAN)
	var built: Dictionary
	if is_light:
		built = ConduitMeshBuilder.build_light_string(control, type_id, segs, ground_fn, mesh_style)
	else:
		built = ConduitMeshBuilder.build(control, type_id, segs, ground_fn, mesh_style)
	var use_flow := ConduitKinds.is_conceptual_type(type_id) or glow_on \
			or bool(style_ov.get("use_flow_shader", false))
	# Quiet conceptual: low emission, no marching pulse unless glow/focus.
	var flow_str := 0.0
	if glow_on:
		flow_str = float(style_ov.get("flow_strength_default", 0.7))
	elif ConduitKinds.is_conceptual_type(type_id):
		flow_str = 0.0
	var emission := float(style_ov.get("emission_energy",
		0.55 if ConduitKinds.is_conceptual_type(type_id) else 1.6))
	if glow_on:
		emission = maxf(emission, 1.8)
	var inst: MeshInstance3D = _instances.get(cid, null)
	if inst == null or not is_instance_valid(inst):
		inst = MeshInstance3D.new()
		inst.name = "Conduit_%s" % cid
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.visibility_range_end = VISIBILITY_RANGE_M
		inst.visibility_range_end_margin = 8.0
		add_child(inst)
		_instances[cid] = inst
	inst.mesh = built.get("mesh", null)
	if use_flow:
		var sm: ShaderMaterial
		if inst.material_override is ShaderMaterial:
			sm = inst.material_override as ShaderMaterial
			ConduitKinds.apply_flow_material_params(
				sm, type_id, tint, flow_str, 1.0, emission)
		else:
			sm = ConduitKinds.make_flow_material(type_id, tint, flow_str, 1.0)
			sm.set_shader_parameter("emission_boost", emission)
			inst.material_override = sm
		if style_ov.has("flow_color"):
			sm.set_shader_parameter("flow_color", style_ov["flow_color"])
	else:
		# Reuse the StandardMaterial3D across rebuilds — make_material() is a pure
		# function of (type_id, tint), so only reallocate when those change (a
		# fresh material every remesh churned the heap during follow/drag).
		var mat_key := "%s|%s" % [type_id, tint.to_html(true)]
		if not (inst.material_override is StandardMaterial3D) \
				or str(inst.get_meta("cond_mat_key", "")) != mat_key:
			inst.material_override = ConduitKinds.make_material(type_id, tint)
			inst.set_meta("cond_mat_key", mat_key)
	inst.transparency = 0.0
	inst.visible = true
	var samples: PackedVector3Array = built.get("sample_points", PackedVector3Array())
	_sample_cache[cid] = samples
	_sync_light_runtime(cid, conn, type_id, built, inst)
	_sync_end_fittings(cid, conn, type_id, control, samples)
	_apply_severed_state(cid, severed)
	var arc: float = float(built.get("arc_length_m", 0.0))
	_write_length_back(cid, arc)
	# Contour (penstock) runs also persist their endpoint elevations — the
	# intake/outlet inverts the flow engine feeds HydroReach (same keys culvert
	# conns already carry, same semantics).
	if is_contour and control.size() >= 2:
		_write_contour_inverts(cid, (control[0] as Vector3).y,
				(control[control.size() - 1] as Vector3).y)


## Persist a contour run's endpoint elevations onto the connection
## (change-gated like _write_length_back).
func _write_contour_inverts(conn_id: String, inv_in_m: float, inv_out_m: float) -> void:
	if _model == null:
		return
	var conn := _model.get_connection(conn_id)
	if conn.is_empty():
		return
	if absf(float(conn.get("invert_in_m", NAN)) - inv_in_m) < 0.01 \
			and absf(float(conn.get("invert_out_m", NAN)) - inv_out_m) < 0.01:
		return
	_updating_model = true
	_model.update_connection(conn_id, {
		"invert_in_m": inv_in_m,
		"invert_out_m": inv_out_m,
	})
	_updating_model = false


## Plug/socket capsules at endpoints + mid-couplers when over max_segment_m.
func _sync_end_fittings(cid: String, conn: Dictionary, type_id: String,
		control: Array, samples: PackedVector3Array = PackedVector3Array()) -> void:
	# Conceptual / light: no fittings (keeps the ribbon tidy).
	if ConduitKinds.is_conceptual_type(type_id) or ConduitKinds.is_light_type(type_id):
		_clear_fittings(cid)
		_fitting_sig.erase(cid)
		return
	if control.size() < 2:
		return
	var meta: Dictionary = ConduitKinds.type_meta(type_id)
	var radius: float = float(meta.get("radius_m", 0.01)) * FITTING_RADIUS_SCALE
	var a: Vector3 = control[0] as Vector3
	var b: Vector3 = control[control.size() - 1] as Vector3
	# Align plugs to the *sampled* tube tangent (ground-snake), not the sparse
	# control chord — otherwise red capsules sit rotated off the cord.
	# Outward = into the run from each endpoint (capsule Y follows this).
	var out_a := Vector3.FORWARD
	var out_b := Vector3.FORWARD
	if samples.size() >= 2:
		var d0: Vector3 = samples[1] - samples[0]
		var d1: Vector3 = samples[samples.size() - 2] - samples[samples.size() - 1]
		if d0.length_squared() > 1e-8:
			out_a = d0.normalized()
		if d1.length_squared() > 1e-8:
			out_b = d1.normalized()
		a = samples[0]
		b = samples[samples.size() - 1]
	else:
		out_a = ((control[1] as Vector3) - a).normalized()
		out_b = ((control[control.size() - 2] as Vector3) - b).normalized()
	var mid_key := ""
	if samples.size() >= 3:
		mid_key = _v3_key(samples[samples.size() / 2])
	var q_key := ""
	if samples.size() >= 5:
		q_key = _v3_key(samples[samples.size() / 4])
	var fsig := "%s|%s|%s|%s|%s|%d|%.3f" % [
		type_id, _v3_key(a), _v3_key(b), mid_key, q_key, samples.size(), radius]
	if _fitting_sig.get(cid, "") == fsig and _fittings.has(cid):
		# Plugs are never focus-gated — restore visibility if a prior build hid them.
		for f: Variant in _fittings.get(cid, []) as Array:
			if f is GeometryInstance3D:
				(f as GeometryInstance3D).visible = true
		return
	_clear_fittings(cid)
	var fittings: Array = []
	fittings.append(_make_fitting(a, out_a, radius, type_id))
	fittings.append(_make_fitting(b, out_b, radius, type_id))
	# Flexible / ground-drape: keep tube tangents. Rigid: snap to tagged ports.
	if not ConduitKinds.is_flexible_type(type_id) \
			and not ConduitKinds.is_ground_drape_type(type_id):
		_orient_fitting_to_port(fittings[0] as MeshInstance3D, conn, true)
		_orient_fitting_to_port(fittings[1] as MeshInstance3D, conn, false)
	var arc: float = 0.0
	if samples.size() >= 2:
		arc = ConduitKinds.polyline_length_m(samples)
	else:
		var packed := PackedVector3Array()
		for p: Variant in control:
			if p is Vector3:
				packed.append(p as Vector3)
		arc = ConduitKinds.polyline_length_m(packed)
	var segs := ConduitKinds.segment_count_for_length(type_id, arc)
	if segs > 1 and samples.size() >= 2:
		for si: int in range(1, segs):
			var along: float = arc * (float(si) / float(segs))
			var pos := _point_along_samples(samples, along)
			var tang := _tangent_along_samples(samples, along)
			fittings.append(_make_fitting(pos, tang, radius * 1.15, type_id, true))
	# Elbow collar sleeves at each bend for collared pipe kinds (PVC / duct / ABS):
	# a short, slightly wider tube that FOLLOWS the pipe through the bend, so it
	# reads as a real swept elbow hub regardless of the bend's 3D orientation
	# (vertical risers, sharp turns) — unlike a single diagonal cylinder.
	if bool(meta.get("fitting_collars", false)) and samples.size() >= 3:
		var collar_r := float(meta.get("radius_m", 0.01)) * COLLAR_RADIUS_SCALE
		var bends := _detect_bend_points(samples, COLLAR_MIN_TURN_DEG)
		var cn := 0
		for bd: Variant in bends:
			if cn >= COLLAR_MAX_COUNT:
				break
			var collar := _make_collar_sleeve(bd as Dictionary, samples, collar_r, type_id)
			if collar != null:
				fittings.append(collar)
				cn += 1
	_fittings[cid] = fittings
	_fitting_sig[cid] = fsig


## Detect bend regions in a sampled polyline: walk it accumulating consecutive
## turning; a cluster whose total turn ≥ min_turn_deg is one elbow. Returns
## [{pos, dir}] at each bend's midpoint (dir = through-direction of the elbow).
static func _detect_bend_points(pts: PackedVector3Array, min_turn_deg: float) -> Array:
	var out: Array = []
	if pts.size() < 3:
		return out
	var i := 1
	while i < pts.size() - 1:
		var acc := 0.0
		var j := i
		var start_dir := Vector3.ZERO
		var end_dir := Vector3.ZERO
		while j < pts.size() - 1:
			var d0: Vector3 = pts[j] - pts[j - 1]
			var d1: Vector3 = pts[j + 1] - pts[j]
			if d0.length() < 1e-4 or d1.length() < 1e-4:
				break
			var ang := rad_to_deg(d0.angle_to(d1))
			if ang < 1.0:
				break
			if acc <= 0.0:
				start_dir = d0.normalized()
			acc += ang
			end_dir = d1.normalized()
			j += 1
		if acc >= min_turn_deg:
			var mid_i: int = (i + j) / 2
			var through := start_dir + end_dir
			if through.length_squared() < 1e-6:
				through = pts[mid_i] - pts[maxi(mid_i - 1, 0)]
			out.append({
				"pos": pts[mid_i], "dir": through.normalized(),
				"i0": i - 1, "i1": j,  # sample range spanning the bend (incl. lead-in)
			})
			i = j + 1
		else:
			i += 1
	return out


## A short wider tube sleeve that follows the pipe through one bend (real PVC/ABS
## elbow hub). Built over the bend's sample sub-range so it always hugs the pipe,
## with no orientation guesswork. Returns null if the range is degenerate.
func _make_collar_sleeve(bend: Dictionary, samples: PackedVector3Array,
		radius: float, type_id: String) -> MeshInstance3D:
	var n := samples.size()
	var i0: int = clampi(int(bend.get("i0", 0)) - 1, 0, n - 1)
	var i1: int = clampi(int(bend.get("i1", 0)) + 1, 0, n - 1)
	if i1 - i0 < 1:
		return null
	var sub := PackedVector3Array()
	for k: int in range(i0, i1 + 1):
		sub.append(samples[k])
	if sub.size() < 2:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "Elbow"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = VISIBILITY_RANGE_M
	mi.mesh = ConduitMeshBuilder.build_tube(sub, radius, 12)
	mi.material_override = ConduitKinds.make_fitting_material(type_id)
	add_child(mi)  # sample verts are world-space → identity transform renders in place
	return mi


static func _point_along_samples(samples: PackedVector3Array, dist: float) -> Vector3:
	var walked := 0.0
	for i: int in range(samples.size() - 1):
		var a: Vector3 = samples[i]
		var b: Vector3 = samples[i + 1]
		var seg := a.distance_to(b)
		if walked + seg >= dist:
			var t := (dist - walked) / seg if seg > 1e-9 else 0.0
			return a.lerp(b, t)
		walked += seg
	return samples[samples.size() - 1]


static func _tangent_along_samples(samples: PackedVector3Array, dist: float) -> Vector3:
	var walked := 0.0
	for i: int in range(samples.size() - 1):
		var a: Vector3 = samples[i]
		var b: Vector3 = samples[i + 1]
		var seg := a.distance_to(b)
		if walked + seg >= dist:
			var d := b - a
			return d.normalized() if d.length_squared() > 1e-8 else Vector3.FORWARD
		walked += seg
	return Vector3.FORWARD


func _orient_fitting_to_port(fitting: MeshInstance3D, conn: Dictionary, is_src: bool) -> void:
	if fitting == null or _model == null:
		return
	var item_id := str(conn.get("source_item_id" if is_src else "target_item_id", ""))
	var handle_id := str(conn.get("source_handle_id" if is_src else "target_handle_id", ""))
	var item := _model.get_item(item_id)
	var ports := ConnectionPortDefs.resolve_ports_for_item(item, _main)
	var port := ConnectionPortDefs.find_port_for_handle(ports, handle_id)
	if port.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop := PlacedPropRuntime.find_by_prop_id(_main, str(specs.get("bound_prop_id", "")))
	if prop == null:
		return
	var model_root := prop.get_node_or_null("ModelRoot") as Node3D
	if model_root == null:
		return
	var n := ConnectionPortDefs.world_normal_for_port(port, model_root)
	if n.length_squared() < 1e-8:
		return
	fitting.look_at(fitting.global_position + n, Vector3.UP)


func _make_fitting(pos: Vector3, outward: Vector3, radius: float,
		type_id: String, mid_coupler: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Coupler" if mid_coupler else "Plug"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = VISIBILITY_RANGE_M
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = (FITTING_LEN_M * (1.4 if mid_coupler else 1.0)) + radius * 2.0
	mi.mesh = mesh
	mi.material_override = ConduitKinds.make_fitting_material(type_id)
	add_child(mi)
	mi.global_position = pos
	var dir := outward
	if dir.length_squared() < 1e-8:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
	if absf(dir.dot(Vector3.UP)) < 0.999:
		mi.look_at(pos + dir, Vector3.UP)
		mi.rotate_object_local(Vector3.RIGHT, -PI * 0.5)
	return mi


func _clear_fittings(cid: String) -> void:
	var arr: Array = _fittings.get(cid, []) as Array
	for f: Variant in arr:
		if f is Node and is_instance_valid(f):
			(f as Node).queue_free()
	_fittings.erase(cid)


## Wave 8 burnout: scorched charcoal material on severed conduits + lights out.
func _apply_severed_state(cid: String, severed: bool) -> void:
	var inst: MeshInstance3D = _instances.get(cid, null)
	if inst != null and is_instance_valid(inst):
		var was: bool = bool(inst.get_meta("severed", false))
		if was != severed:
			inst.set_meta("severed", severed)
			if severed:
				var scorched := StandardMaterial3D.new()
				scorched.albedo_color = Color(0.09, 0.07, 0.06, 1.0)
				scorched.roughness = 1.0
				inst.material_override = scorched
			else:
				_last_anchors.erase(cid)
				_last_cheap.erase(cid)
				var conn2 := _model.get_connection(cid) if _model != null else {}
				if not conn2.is_empty():
					_rebuild_if_dirty(conn2, true)
	var rt: Node = _light_runtimes.get(cid, null)
	if rt != null and is_instance_valid(rt) and rt.has_method("set_severed"):
		rt.call("set_severed", severed)


## Terrain height under a world position. Prefers TerrainSurfaceQuery footing.
func ground_y_at(pos: Vector3) -> float:
	if _main != null and _main.is_inside_tree():
		return TerrainSurfaceQuery.ground_height_at(_main, pos.x, pos.z)
	if not is_inside_tree():
		return 0.0
	var world := get_world_3d()
	if world == null:
		return 0.0
	var space := world.direct_space_state
	if space == null:
		return 0.0
	var from := Vector3(pos.x, pos.y + 50.0, pos.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 300.0)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := space.intersect_ray(query)
	if hit.has("position"):
		return (hit["position"] as Vector3).y
	return 0.0


func _sync_light_runtime(cid: String, conn: Dictionary, type_id: String,
		built: Dictionary, tube: MeshInstance3D) -> void:
	var is_light: bool = ConduitKinds.is_light_type(type_id)
	var rt: Node = _light_runtimes.get(cid, null)
	if not is_light:
		if rt != null and is_instance_valid(rt):
			rt.queue_free()
		_light_runtimes.erase(cid)
		return
	if rt == null or not is_instance_valid(rt):
		rt = LightStringRuntime.new()
		rt.name = "Lights_%s" % cid
		add_child(rt)
		_light_runtimes[cid] = rt
	var bulbs: PackedVector3Array = built.get("bulb_positions", PackedVector3Array())
	var arc: float = float(built.get("arc_length_m", 0.0))
	(rt as LightStringRuntime).configure(type_id, bulbs, arc)
	var meta: Dictionary = ConduitKinds.type_meta(type_id)
	if float(meta.get("bulb_spacing_m", 0.0)) <= 0.001:
		(rt as LightStringRuntime).set_strip_mesh(tube)
	(rt as LightStringRuntime).set_severed(bool(conn.get("severed", false)))


func _control_signature(control: Array) -> PackedVector3Array:
	var sig := PackedVector3Array()
	for p: Variant in control:
		if p is Vector3:
			sig.append(p)
	return sig


func _write_length_back(conn_id: String, length_m: float) -> void:
	if _model == null:
		return
	var conn := _model.get_connection(conn_id)
	if conn.is_empty():
		return
	var prev: float = float(conn.get("route_length_m", 0.0))
	var prev_est: float = float(conn.get("estimated_length", 0.0))
	if absf(prev - length_m) < 0.001 and absf(prev_est - length_m) < 0.001:
		return
	_updating_model = true
	_model.update_connection(conn_id, {
		"route_length_m": length_m,
		"estimated_length": length_m,
	})
	_updating_model = false


func clear_route(conn_id: String) -> void:
	if _model == null:
		return
	_updating_model = true
	_model.update_connection(conn_id, {
		"route_3d": [],
		"route_length_m": 0.0,
		"route_locked": false,
		"site_waypoints": [],
	})
	_updating_model = false
	_last_anchors.erase(conn_id)
	_last_cheap.erase(conn_id)
	var conn := _model.get_connection(conn_id)
	if not conn.is_empty() and _global_visible:
		_rebuild_if_dirty(conn, true)


func commit_route(conn_id: String, waypoints: Array) -> void:
	if _model == null:
		return
	var route: Array = waypoints.duplicate(true)
	var conn0 := _model.get_connection(conn_id)
	var type_id := ConduitKinds.derive_type_for_connection(conn0)
	# Hang / kit-pipe pins are free surface XYZ — never persist collider pin_path
	# (rebuild would snap to PropBody origin near the ground on StarShade / buildings).
	if ConduitKinds.supports_pin_edit(type_id):
		route = ConduitKinds.strip_hang_pin_paths(route)
	# Lock only when the user actually placed mid pins — empty = stay auto.
	var locked := not route.is_empty()
	_updating_model = true
	_model.update_connection(conn_id, {
		"route_3d": route,
		"route_locked": locked,
	})
	_updating_model = false
	_last_anchors.erase(conn_id)
	_last_cheap.erase(conn_id)
	var conn := _model.get_connection(conn_id)
	if not conn.is_empty() and _global_visible:
		_rebuild_if_dirty(conn, true)


func get_instance(conn_id: String) -> MeshInstance3D:
	return _instances.get(conn_id, null)


func get_graph_model() -> GraphModel:
	return _model


func get_main_node() -> Node:
	return _main


func _get_pipe_kit(kit_id: String) -> PipeKit:
	if kit_id.is_empty() or kit_id.begins_with(CulvertKit.FAMILY):
		return null
	if _pipe_kits.has(kit_id):
		var cached: Variant = _pipe_kits[kit_id]
		return cached as PipeKit if cached is PipeKit else null
	var kit := PipeKit.load_kit(kit_id)
	# Cache misses too — avoids re-parsing JSON every dirty-key check.
	_pipe_kits[kit_id] = kit if kit != null else false
	return kit


func _get_culvert_kit(kit_id: String) -> CulvertKit:
	if kit_id.is_empty():
		return null
	var cache_key := "culvert:%s" % kit_id
	if _pipe_kits.has(cache_key):
		var cached: Variant = _pipe_kits[cache_key]
		return cached as CulvertKit if cached is CulvertKit else null
	var kit := CulvertKit.load_kit(kit_id)
	_pipe_kits[cache_key] = kit if kit != null else false
	return kit


## Assemble GLB straights/elbows (Sch40) or PE culvert rings. Returns true on success.
func _try_rebuild_pipe_parts(cid: String, conn: Dictionary, type_id: String,
		control: Array, tint: Color, severed: bool) -> bool:
	var style_ov: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var kit_id := ConduitKinds.pipe_kit_id(type_id, style_ov)
	if kit_id.is_empty():
		return false
	if ConduitKinds.uses_culvert_kit(type_id):
		return _try_rebuild_culvert(cid, conn, type_id, control, tint, severed, kit_id)
	var kit := _get_pipe_kit(kit_id)
	if kit == null:
		return false
	var sharp := PackedVector3Array()
	for p: Variant in control:
		if p is Vector3:
			sharp.append(p as Vector3)
	# Merge colinear adjacent straights in the plan stage via planner; assembler
	# already batches elbows per bend key into MultiMesh.
	var bom := PipePartsPlanner.plan(sharp, kit)
	if not bool(bom.get("ok", false)):
		var err := str(bom.get("error", "plan failed"))
		if str(_pipe_kit_warn.get(cid, "")) != err:
			_pipe_kit_warn[cid] = err
			push_warning("PipeParts %s: %s — falling back to procedural tube" % [cid, err])
		return false
	_pipe_kit_warn.erase(cid)
	CulvertAssembler.clear(self, cid)
	var mat := ConduitKinds.make_pipe_kit_material(type_id, tint)
	var applied: Dictionary = PipePartsAssembler.apply(self, cid, bom, kit, mat)
	var cl: PackedVector3Array = applied.get("centerline", PackedVector3Array()) as PackedVector3Array
	if cl.size() < 2:
		PipePartsAssembler.clear(self, cid)
		_elbow_cache.erase(cid)
		return false
	_parts_active[cid] = true
	_sample_cache[cid] = cl
	_elbow_cache[cid] = applied.get("elbows", []) as Array
	_finish_parts_instance(cid, conn, type_id, mat, severed, cl, "PipeParts_%s" % cid)
	return true


func _try_rebuild_culvert(cid: String, conn: Dictionary, type_id: String,
		control: Array, tint: Color, severed: bool, kit_id: String) -> bool:
	var kit := _get_culvert_kit(kit_id)
	if kit == null:
		return false
	var path := PackedVector3Array()
	for p: Variant in control:
		if p is Vector3:
			path.append(p as Vector3)
	if path.size() < 2:
		return false
	PipePartsAssembler.clear(self, cid)
	# Keep StandardMaterial3D for PE rings — conduit_flow.gdshader runs SoI
	# section clip and discards the barrel on the Elev/Siphon Lab cut plane.
	var mat := ConduitKinds.make_pipe_kit_material(type_id, tint)
	var glow_on := ConduitKinds.resolve_flow_glow(conn, type_id, _global_flow_glow) \
			or cid == _focus_id
	if glow_on and mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		sm.emission_enabled = true
		sm.emission = Color(0.15, 0.8, 1.0, 1.0)
		sm.emission_energy_multiplier = 3.6
		sm.albedo_color = Color(0.4, 0.78, 1.0, 1.0)
	var applied: Dictionary = CulvertAssembler.apply(self, cid, path, kit, mat)
	if not bool(applied.get("ok", false)):
		var err := "culvert assemble failed"
		if str(_pipe_kit_warn.get(cid, "")) != err:
			_pipe_kit_warn[cid] = err
			push_warning("Culvert %s: %s — falling back to procedural tube" % [cid, err])
		CulvertAssembler.clear(self, cid)
		return false
	_pipe_kit_warn.erase(cid)
	var cl: PackedVector3Array = applied.get("centerline", PackedVector3Array()) as PackedVector3Array
	_parts_active[cid] = true
	_sample_cache[cid] = cl
	_elbow_cache[cid] = []  # no discrete elbows — wide PE arcs
	_finish_parts_instance(cid, conn, type_id, mat, severed, cl, "CulvertParts_%s" % cid)
	return true


func _finish_parts_instance(cid: String, conn: Dictionary, type_id: String,
		mat: Material, severed: bool, cl: PackedVector3Array, host_name: String) -> void:
	# Keep a silent MeshInstance3D so focus-dim / pick bookkeeping still work.
	var inst: MeshInstance3D = _instances.get(cid, null)
	if inst == null or not is_instance_valid(inst):
		inst = MeshInstance3D.new()
		inst.name = "Conduit_%s" % cid
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.visibility_range_end = VISIBILITY_RANGE_M
		add_child(inst)
		_instances[cid] = inst
	inst.mesh = null
	inst.visible = false
	inst.material_override = mat
	_clear_fittings(cid)
	_fitting_sig.erase(cid)
	_sync_light_runtime(cid, conn, type_id, {"bulb_positions": PackedVector3Array()}, inst)
	_apply_severed_state(cid, severed)
	var parts_host := get_node_or_null(host_name) as Node3D
	if parts_host != null:
		var focused := (not _focus_id.is_empty()) and cid == _focus_id
		var dimmed := (not _focus_id.is_empty()) and not focused
		for c in parts_host.get_children():
			if c is GeometryInstance3D:
				(c as GeometryInstance3D).transparency = FOCUS_DIM if dimmed else 0.0
	var arc := ConduitKinds.polyline_length_m(cl)
	_write_length_back(cid, arc)


func _remove_instance(conn_id: String) -> void:
	PipePartsAssembler.clear(self, conn_id)
	CulvertAssembler.clear(self, conn_id)
	_parts_active.erase(conn_id)
	_pipe_kit_warn.erase(conn_id)
	_elbow_cache.erase(conn_id)
	clear_elbow_highlight()
	_clear_fittings(conn_id)
	_sample_cache.erase(conn_id)
	_last_cheap.erase(conn_id)
	_fitting_sig.erase(conn_id)
	if has_meta("_glow_%s" % conn_id):
		remove_meta("_glow_%s" % conn_id)
	var rt: Node = _light_runtimes.get(conn_id, null)
	if rt != null and is_instance_valid(rt):
		rt.queue_free()
	_light_runtimes.erase(conn_id)
	var vfx: Node = _discharge_vfx.get(conn_id, null)
	if vfx != null and is_instance_valid(vfx):
		vfx.queue_free()
	_discharge_vfx.erase(conn_id)
	if not _instances.has(conn_id):
		return
	var inst: MeshInstance3D = _instances[conn_id]
	_instances.erase(conn_id)
	if is_instance_valid(inst):
		inst.queue_free()


func _cached_obstacles(_ignore_prop_ids: Array = []) -> Array:
	if not _obstacle_cache_valid:
		# Shared cache (all props). Per-connection ignore would force a full
		# scene walk; a short jog near the host footprint is acceptable.
		_obstacle_cache = ConduitPathfinder.collect_prop_obstacles(_main, [])
		_obstacle_cache_valid = true
	return _obstacle_cache


func _rebuild_lane_map() -> void:
	_lane_map.clear()
	if _model == null:
		return
	_lane_map = ConduitPathfinder.assign_lanes(_model)


## One-time cleanup of legacy dense auto-routes: pipes-kit connections that saved
## a long unlocked route_3d are cleared so the router re-derives them. Idempotent
## per model — gated so it doesn't re-scan every full remesh (visibility toggles).
func _migrate_dense_unlocked_routes() -> void:
	if _model == null or _dense_routes_migrated:
		return
	_dense_routes_migrated = true
	# Collect ids first — mutating _model.connections mid-iteration is fragile.
	var to_clear: Array[String] = []
	for conn: Dictionary in _model.connections:
		if bool(conn.get("route_locked", false)):
			continue
		var type_id := ConduitKinds.derive_type_for_connection(conn)
		if not ConduitKinds.is_pipes_type(type_id):
			continue
		var wps: Array = conn.get("route_3d", []) as Array
		if wps.size() < DENSE_ROUTE_MIGRATE_MIN:
			continue
		to_clear.append(str(conn.get("id", "")))
	if to_clear.is_empty():
		return
	_updating_model = true
	for cid in to_clear:
		_model.update_connection(cid, {
			"route_3d": [],
			"route_locked": false,
		})
	_updating_model = false
