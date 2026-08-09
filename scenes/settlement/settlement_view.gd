class_name SettlementView
extends Node3D

## The settlement view: watch the community work, and shape the conditions it
## works under.
##
## Not a diagram and not a diorama — the same world the player walks around in,
## seen from anywhere between standing height and the whole Sphere of
## Influence, with the clock still running.
##
## ## Three rules this file exists to hold
##
## 1. **The clock is NEVER claimed.** `soi_snowglobe_camera.gd` opens with
##    `push_clock_claim("soi_snowglobe", {"time_scale": 0.0})` — it freezes the
##    sim, because it is an inspector for a frozen diorama. This view's entire
##    premise is the opposite: you are here to watch the settlement RUN. Do not
##    copy that line.
## 2. **No orders.** Selection opens a card and can follow someone; there is no
##    verb anywhere in this view that tells a person what to do. The player's
##    levers are the routine editor, the chore board, priorities, space tagging
##    and site rules — all of which shape conditions rather than issue commands.
##    The crew self-organising against those conditions is the thing worth
##    watching; an order queue would replace it with a to-do list.
## 3. **It borrows nothing from the 2D graph.** No SubViewport, no canvas
##    projection, no provider callables. A real Camera3D on the main viewport,
##    and picking through the same ladder first person uses.

const CLAIM := "settlement"
const HUD_SCRIPT := preload("res://scenes/settlement/settlement_hud.gd")
const OVERLAY_SCRIPT := preload("res://scenes/settlement/space_overlay.gd")
const DOCK_SCRIPT := preload("res://scenes/settlement/work_dock.gd")

signal closed()
signal selection_changed(sel: Dictionary)

var _main: Node = null
var _cam: SettlementCamera = null
var _active := false
var _selection: Dictionary = {}
var _follow_id := ""
var _dragging := false
var _orbiting := false
var _drag_moved := 0.0
var _hud: CanvasLayer = null
var _overlay: Node3D = null
var _dock: CanvasLayer = null
## Set only while the view is borrowed for a one-shot ground pick.
var _pick_cb := Callable()
## Prop cull reach is refreshed on zoom TRANSITIONS, never per frame —
## apply_to_all walks every placed prop.
var _last_cull_push := -1.0

## Below this drag distance a release counts as a click, not a pan.
const CLICK_SLOP_PX := 6.0
const CULL_REPUSH_FRAC := 0.35


func _ready() -> void:
	set_process(false)
	set_process_unhandled_input(false)
	visible = false


func is_open() -> bool:
	return _active


func open(main: Node, at: Vector2 = Vector2.INF) -> void:
	if _active:
		return
	_main = main
	if _cam == null:
		_cam = SettlementCamera.new()
		_cam.name = "SettlementCamera"
		add_child(_cam)
	var focus := at
	if focus == Vector2.INF:
		focus = _player_xz()
	_cam.setup(main, focus, 60.0)
	_active = true
	visible = true
	set_process(true)
	set_process_unhandled_input(true)
	# The camera claim carries the side effects too, so leaving restores them
	# even if this node is freed mid-session.
	if main.has_method("push_camera_claim"):
		main.call("push_camera_claim", CLAIM, {
			"camera_id": _cam.get_instance_id(),
			"hide_player_mesh": true,
			"shadow_max_distance": 400.0,
			"prop_cull_scale_m": _cull_for_height(_cam.height()),
		})
	_last_cull_push = _cam.height()
	# Park the player body: leaving a CharacterBody3D integrating gravity for
	# twenty sim-minutes while nobody is driving it is pure waste.
	var body := main.get_node_or_null("Player")
	if body != null:
		body.process_mode = Node.PROCESS_MODE_DISABLED
	CursorController.request_modal(CLAIM, Callable(self, "close"))
	# Avatars are culled for a first-person budget; from up here that would
	# empty the camp.
	_push_avatar_lod(true)
	if _hud == null:
		_hud = HUD_SCRIPT.new()
		_hud.name = "SettlementHud"
		add_child(_hud)
	_hud.call("bind", self, _bridge())
	_hud.call("show_hud")
	if _overlay == null:
		_overlay = OVERLAY_SCRIPT.new()
		_overlay.name = "SpaceOverlay"
		add_child(_overlay)
	_overlay.call("rebuild", main)
	_overlay.visible = true
	# The board, next to the crew working it — so retuning a priority and
	# seeing the crew re-form around it is one screen, not two.
	if _dock == null:
		_dock = DOCK_SCRIPT.new()
		_dock.name = "WorkDock"
		add_child(_dock)
	_dock.call("bind", self, _bridge())
	_dock.call("show_dock")


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	set_process(false)
	set_process_unhandled_input(false)
	_follow_id = ""
	_selection = {}
	if _hud != null and is_instance_valid(_hud):
		_hud.call("hide_hud")
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.visible = false
	if _dock != null and is_instance_valid(_dock):
		_dock.call("hide_dock")
	if _main != null:
		if _main.has_method("pop_camera_claim"):
			_main.call("pop_camera_claim", CLAIM)
		var body := _main.get_node_or_null("Player")
		if body != null:
			body.process_mode = Node.PROCESS_MODE_INHERIT
	_push_avatar_lod(false)
	CursorController.release_modal(CLAIM)
	closed.emit()


func camera() -> SettlementCamera:
	return _cam


func selection() -> Dictionary:
	return _selection


func following() -> String:
	return _follow_id


## Put the player where the camera is looking and hand control back. The
## round trip is what makes "watch them work, then go stand in it" real
## rather than a walk across the map.
func drop_in() -> void:
	if _main == null or _cam == null:
		return
	var p := _cam.focus
	if not _selection.is_empty() and _selection.has("pos"):
		p = _selection["pos"] as Vector2
	var body := _main.get_node_or_null("Player") as Node3D
	if body != null:
		var gy := TerrainSurfaceQuery.ground_height_at(_main, p.x, p.y)
		body.global_position = Vector3(p.x, gy + 1.0, p.y)
	close()


func _process(delta: float) -> void:
	if _cam == null:
		return
	if not _follow_id.is_empty():
		var p := _agent_pos(_follow_id)
		if p != Vector2.INF:
			_cam.look_at_xz(p)
		else:
			_follow_id = ""   # they left, or died
	# Zoom changes the useful cull reach; re-push only when it has moved
	# materially, since apply_to_all walks every prop on the map.
	var h := _cam.height()
	if _last_cull_push <= 0.0 or absf(h - _last_cull_push) / maxf(_last_cull_push, 1.0) > CULL_REPUSH_FRAC:
		_last_cull_push = h
		if _main != null and _main.has_method("push_camera_claim"):
			_main.call("push_camera_claim", CLAIM, {
				"camera_id": _cam.get_instance_id(),
				"hide_player_mesh": true,
				"shadow_max_distance": maxf(400.0, h * 3.0),
				"prop_cull_scale_m": _cull_for_height(h),
			})


static func _cull_for_height(h: float) -> float:
	# Twice the camera height covers what is actually on screen at these
	# pitches, without switching culling off wholesale.
	return maxf(h * 2.0, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not _active or _cam == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				# A borrowed view always answers, even when cancelled.
				if _pick_cb.is_valid():
					_deliver_pick(Vector2.INF)
				else:
					close()
				get_viewport().set_input_as_handled()
			KEY_F:
				if _selection.get("kind", "") == "npc":
					_follow_id = str(_selection.get("agent_id", ""))
					get_viewport().set_input_as_handled()
			KEY_G:
				drop_in()
				get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_cam.zoom_by(1.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				_cam.zoom_by(-1.0)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_dragging = true
					_drag_moved = 0.0
				else:
					_dragging = false
					# A short press is a click; anything longer was a pan.
					if _drag_moved < CLICK_SLOP_PX:
						_select_at(mb.position)
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_cam.orbit_by(-mm.relative.x * 0.005)
		elif _dragging:
			_drag_moved += mm.relative.length()
			if _drag_moved >= CLICK_SLOP_PX:
				# Dragging the ground pans; following would fight it.
				_follow_id = ""
				_cam.pan_by(mm.relative, float(get_viewport().get_visible_rect().size.y))


## Borrow the view for ONE ground pick, then hand control back to whoever asked.
##
## This is not an order channel and must never become one: the callback gets a
## world XZ, nothing else, and the caller uses it to author a RULE (where a
## chore lives) rather than to command a person. Esc cancels, delivering
## `Vector2.INF`, so the caller always hears back exactly once.
## `hint` names WHAT is being placed — the same picker serves chores, duties
## and whole projects, and "this chore" was a lie for two of the three.
func pick_point_once(cb: Callable, hint: String = "this chore") -> void:
	_pick_cb = cb
	if _hud != null and is_instance_valid(_hud):
		_hud.call("set_pick_hint", "Click the spot for %s · Esc to cancel" % hint)


func _deliver_pick(p: Vector2) -> void:
	var cb := _pick_cb
	_pick_cb = Callable()
	if _hud != null and is_instance_valid(_hud):
		_hud.call("set_pick_hint", "")
	close()
	if cb.is_valid():
		cb.call(p)


## Selection is INSPECTION. It opens a card and can start a follow; it never
## issues an order.
func _select_at(screen_pos: Vector2) -> void:
	if _cam == null or _main == null:
		return
	var origin := _cam.project_ray_origin(screen_pos)
	var dir := _cam.project_ray_normal(screen_pos)
	if _pick_cb.is_valid():
		# In pick mode only the GROUND matters — clicking a person must not
		# silently attach the chore to them (that would be an order).
		var g := SiteTargetPicker.ground_hit(_main, origin, dir,
			maxf(_cam.height() * 6.0, 250.0))
		if not g.is_empty():
			var gp: Vector3 = g["point"]
			_deliver_pick(Vector2(gp.x, gp.z))
		return
	var hit := SiteTargetPicker.resolve(_main, origin, dir, {
		"max_dist_m": maxf(_cam.height() * 6.0, 250.0),
	})
	if hit.is_empty():
		_selection = {}
		selection_changed.emit(_selection)
		return
	# Carry a world XZ on every selection so the HUD can centre or drop in on
	# it without re-picking.
	if str(hit.get("kind", "")) == "npc":
		hit["pos"] = _agent_pos(str(hit.get("agent_id", "")))
		hit["detail"] = _agent_detail(str(hit.get("agent_id", "")))
	elif hit.has("point"):
		var p: Vector3 = hit["point"]
		hit["pos"] = Vector2(p.x, p.z)
	_selection = hit
	selection_changed.emit(_selection)


func _agent_pos(agent_id: String) -> Vector2:
	for d in _dots():
		if str((d as Dictionary).get("id", "")) == agent_id:
			return (d as Dictionary).get("pos", Vector2.ZERO) as Vector2
	return Vector2.INF


## The inspector card's contents, straight off the dot payload — reading it as
## DATA is fine; drawing dots over people who are right there is not.
func _agent_detail(agent_id: String) -> Dictionary:
	for d in _dots():
		var dd: Dictionary = d
		if str(dd.get("id", "")) == agent_id:
			return {
				"name": str(dd.get("name", "")),
				"status": str(dd.get("status", "")),
				"morale": float(dd.get("morale", 0.0)),
				"morale_label": str(dd.get("morale_label", "")),
				"carrying": bool(dd.get("carrying", false)),
			}
	return {}


func _dots() -> Array:
	var bridge: Variant = _bridge()
	return bridge.call("agent_dots") if bridge != null else []


func _bridge() -> Variant:
	if _main == null:
		return null
	var sgv := _main.get_node_or_null("UILayer/SystemGraphView")
	if sgv != null and sgv.has_method("npc_population_bridge"):
		return sgv.call("npc_population_bridge")
	return null


func _player_xz() -> Vector2:
	var body := _main.get_node_or_null("Player") as Node3D if _main != null else null
	if body == null:
		return Vector2.ZERO
	return Vector2(body.global_position.x, body.global_position.z)


## From a kilometre up the first-person avatar budget empties the camp, so
## widen it while this view is open and put it back on exit.
func _push_avatar_lod(open_mode: bool) -> void:
	if _main == null:
		return
	var host := _main.find_child("NpcPopulationHost", true, false)
	if host != null and host.has_method("set_view_range_scale"):
		host.call("set_view_range_scale", 8.0 if open_mode else 1.0)
