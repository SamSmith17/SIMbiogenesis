extends RefCounted

## The ROUTE section of the edit toolbar (Shift+R): 3D runs of pipe, conduit
## and cable between machines, with the mouse on a free cursor (the toolbar's
## tool-overlay tier, so WASD and right-drag look still work).
##
##   Connect     click a port, then a port on the other machine. Shift keeps
##               chaining from the machine just reached.
##   Bend        click a run, then click it to add a bend point (a via), drag
##               a via (Shift drags it up or down), double-click or Del removes.
##   Height      drag a run up or down: the height it prefers to run at. Snaps
##               to the floor, knee, waist and head height above the ground.
##   Along wall  with a run picked, click a building or machine side: the run
##               goes along it at that height.
##   Style       click a run: its kind, size and look (the conduit modal).
##
## Every ghost is built by ConduitManager.build_control_points on the draft
## connection — the same call, obstacles and solver that build the committed
## run — so what is shown is what is made. Edits go through the graph view
## (one undo step each, the graph's own Ctrl+Z).
##
## No class_name on purpose: the toolbar preloads it (stale-class-cache rule).

const PORT_PICK_PX := 16.0
const RUN_PICK_PX := 10.0
const VIA_PICK_PX := 11.0
const DRAG_PX := 6.0
const DOUBLE_CLICK_MS := 380
const PREVIEW_S := 0.07
const PORT_RANGE_M := 120.0
## Heights above the ground a dragged leg snaps to: on the floor, knee,
## bench, head height (a run you can walk under).
const HEIGHT_SNAPS := [0.1, 0.45, 1.2, 2.4]
const SNAP_PX := 9.0

const COL_PORT := Color(0.92, 0.95, 1.0, 0.9)
const COL_PORT_OK := Color(0.45, 1.0, 0.6, 1.0)
const COL_PICK := Color(1.0, 0.86, 0.3, 1.0)
const COL_VIA := Color(1.0, 0.95, 0.75, 1.0)
const COL_BAD := Color(1.0, 0.4, 0.35, 1.0)

var ui: Control = null
var tool := ""
var _reroute_armed_ms := 0
var new_kind := ""          ## "" = what the port carries decides
var new_size := 0.0         ## the size key's value; 0 = the kind's default
var new_height := 0.0       ## preferred run height above the ground; 0 = auto
## The runs in their service colours while the tool is up (hot water red,
## cold blue, power yellow…); off = each run's own material.
var show_all := false

var _mouse := Vector2(-1.0, -1.0)
var _ports: Array = []      ## [{port, world_pos, item_id}]
var _ports_ms := -100000
var _hover := {}            ## {kind: port|via|run|wall, ...}
var _src := {}              ## Connect: the port the run starts from
var _ghost := PackedVector3Array()
var _ghost_ok := false
var _ghost_key := ""
var _ghost_acc := 0.0
var _picked := ""           ## the run being edited
var _press := {}
var _drag := {}
var _last_click_ms := 0
var _last_click_via := -1
var _prev_global := true
var _prev_preview := false
var _visibility_taken := false
var _rows: Dictionary = {}
var _edits := 0


func setup(toolbar: Control) -> void:
	ui = toolbar


func is_route_tool(id: String) -> bool:
	return id.begins_with("route_")


func activate(tool_id: String) -> void:
	tool = tool_id
	_press = {}
	_drag = {}
	_hover = {}
	if tool_id != "route_connect":
		_src = {}
		_ghost = PackedVector3Array()
	_take_visibility()
	_ports_ms = -100000
	match tool_id:
		"route_connect":
			_status("Click a port on a machine, then a port on the other one. Shift keeps chaining.")
		"route_bend":
			_status("Click a run, then click it to add a bend point; drag a point to move it (Shift: up or down).")
		"route_height":
			_status("Drag a run up or down: the height it prefers. Snaps to floor, knee, bench and head height.")
		"route_wall":
			_status("Click a run, then a building or machine side: it runs along it at that height.")
		"route_style":
			_status("Click a run to change its kind, size and look.")
		"route_lane":
			_status("Drag a run in a bundle sideways to another lane, or well clear to take it out.")


func deactivate() -> void:
	tool = ""
	_press = {}
	_drag = {}
	_src = {}
	_ghost = PackedVector3Array()
	_give_back_visibility()


func escape() -> bool:
	if not _drag.is_empty():
		_drag = {}
		_press = {}
		_ghost = PackedVector3Array()
		_status("Cancelled")
		_redraw()
		return true
	if not _src.is_empty():
		_src = {}
		_ghost = PackedVector3Array()
		_status("Run cancelled")
		_redraw()
		return true
	if not _picked.is_empty():
		_pick_run("")
		return true
	return false


# --- the world ---------------------------------------------------------------

func _gv() -> Node:
	return ServiceLocator.graph()


func _mgr() -> ConduitManager:
	var gv := _gv()
	if gv == null or not gv.has_method("_get_conduit_manager"):
		return null
	return gv.call("_get_conduit_manager") as ConduitManager


func _model() -> GraphModel:
	var gv := _gv()
	return gv.get("model") as GraphModel if gv != null else null


func _cam() -> Camera3D:
	return ui.get_viewport().get_camera_3d() if ui != null else null


func _status(msg: String) -> void:
	if ui != null:
		ui.call("_set_status", msg)


func _redraw() -> void:
	if ui != null:
		ui.call("_queue_overlay_redraw")


## Screen point of a world point, or INF behind the camera.
func _proj(p: Vector3) -> Vector2:
	var cam := _cam()
	if cam == null or cam.is_position_behind(p):
		return Vector2.INF
	return cam.unproject_position(p)


func _ray() -> Array:
	var cam := _cam()
	if cam == null:
		return []
	return [cam.project_ray_origin(_mouse), cam.project_ray_normal(_mouse)]


## While the tool is up the runs show in first person (they are x-ray and
## hidden there otherwise); with "Service colours" on, in their service colours.
func _take_visibility() -> void:
	var mgr := _mgr()
	if mgr == null or _visibility_taken:
		return
	_visibility_taken = true
	_prev_preview = bool(mgr.get("_preview_visible"))
	_prev_global = bool(mgr.get("_global_visible"))
	# Every run shows while the tool is up (they are x-ray, hidden on foot).
	if not _prev_global:
		mgr.set_global_visibility(true)
	if show_all:
		mgr.set_preview_visibility(true)


func _give_back_visibility() -> void:
	var mgr := _mgr()
	if mgr == null or not _visibility_taken:
		return
	_visibility_taken = false
	if not _prev_global and bool(mgr.get("_global_visible")):
		mgr.set_global_visibility(false)
	mgr.set_preview_visibility(_prev_preview)
	mgr.set_focus_highlight("")


func set_show_all(on: bool) -> void:
	show_all = on
	var mgr := _mgr()
	if mgr == null or not _visibility_taken:
		return
	mgr.set_preview_visibility(on or _prev_preview)


# --- per frame -----------------------------------------------------------------

func process(delta: float) -> void:
	if tool.is_empty():
		return
	var mouse := _mouse if _mouse.x >= 0.0 else ui.get_viewport().get_mouse_position()
	_mouse = mouse
	if not _drag.is_empty():
		_update_drag()
	elif not _press.is_empty() and mouse.distance_to(_press["px"]) > DRAG_PX:
		_begin_drag()
	else:
		_hover = _pick()
	if tool == "route_connect" and not _src.is_empty():
		_ghost_acc += delta
		if _ghost_acc >= PREVIEW_S:
			_ghost_acc = 0.0
			_update_connect_ghost()
	_redraw()


func _ports_now() -> Array:
	var now := Time.get_ticks_msec()
	if now - _ports_ms > 400:
		_ports_ms = now
		var mgr := _mgr()
		_ports = mgr.gather_world_ports() if mgr != null else []
	return _ports


func _pick() -> Dictionary:
	if tool == "route_connect":
		var p := _port_at(_mouse)
		return {"kind": "port", "hit": p} if not p.is_empty() else {}
	if not _picked.is_empty() and (tool == "route_bend" or tool == "route_wall"):
		var vi := _via_at(_mouse)
		if vi >= 0:
			return {"kind": "via", "index": vi}
	if tool == "route_wall" and not _picked.is_empty():
		var w := _wall_hit()
		if not w.is_empty():
			return {"kind": "wall", "hit": w}
	var r := _run_at(_mouse)
	return r


func _port_at(mouse: Vector2) -> Dictionary:
	var cam := _cam()
	if cam == null:
		return {}
	var best := PORT_PICK_PX
	var hit := {}
	for h: Variant in _ports_now():
		var d: Dictionary = h
		var wp: Vector3 = d["world_pos"]
		if wp.distance_to(cam.global_position) > PORT_RANGE_M:
			continue
		var sp := _proj(wp)
		if not is_finite(sp.x):
			continue
		var dist := sp.distance_to(mouse)
		if dist < best:
			best = dist
			hit = d
	return hit


## The run under the pointer: {kind: "run", id, point (world), param}.
func _run_at(mouse: Vector2) -> Dictionary:
	var mgr := _mgr()
	var model := _model()
	if mgr == null or model == null:
		return {}
	var best := RUN_PICK_PX
	var hit := {}
	# The picked run wins a tie with its neighbours (runs in a bundle lie a
	# few pixels apart): it is the one being worked on.
	var picked_hit := {}
	for conn: Dictionary in model.connections:
		var cid := str(conn.get("id", ""))
		var pts := mgr.get_sample_points(cid)
		if pts.size() < 2:
			continue
		var own_best := RUN_PICK_PX
		var prev := _proj(pts[0])
		for i: int in range(1, pts.size()):
			var cur := _proj(pts[i])
			if is_finite(prev.x) and is_finite(cur.x):
				var q := Geometry2D.get_closest_point_to_segment(mouse, prev, cur)
				var dist := q.distance_to(mouse)
				if dist < best or (cid == _picked and dist < own_best):
					var seg := cur - prev
					var t := 0.0 if seg.length_squared() < 1e-6 \
						else clampf((q - prev).dot(seg) / seg.length_squared(), 0.0, 1.0)
					var h := {"kind": "run", "id": cid, "point": pts[i - 1].lerp(pts[i], t),
						"seg": i - 1, "t": t}
					if dist < best:
						best = dist
						hit = h
					if cid == _picked and dist < own_best:
						own_best = dist
						picked_hit = h
			prev = cur
	return picked_hit if not picked_hit.is_empty() else hit


func _vias(cid: String) -> Array:
	var model := _model()
	if model == null:
		return []
	var out: Array = []
	for w: Variant in model.get_connection(cid).get("route_3d", []) as Array:
		if w is Dictionary:
			var d: Dictionary = w
			out.append(Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0))))
		elif w is Vector3:
			out.append(w)
	return out


func _via_at(mouse: Vector2) -> int:
	var best := VIA_PICK_PX
	var bi := -1
	var vias := _vias(_picked)
	for i: int in range(vias.size()):
		var sp := _proj(vias[i] as Vector3)
		if is_finite(sp.x) and sp.distance_to(mouse) < best:
			best = sp.distance_to(mouse)
			bi = i
	return bi


## Where the pointer's ray first meets a building or a machine side:
## {point, normal} or {}.
func _wall_hit() -> Dictionary:
	var mgr := _mgr()
	var r := _ray()
	if mgr == null or r.is_empty():
		return {}
	var field := mgr.obstacle_field()
	var o: Vector3 = r[0]
	var d: Vector3 = r[1]
	var step := 0.25
	var prev := o
	for i: int in range(1, 800):
		var p := o + d * (step * float(i))
		var q := field.query_xz(Vector2(p.x, p.z), Vector2(p.x, p.z))
		if q.size() > 0 and field.point_blocked(p, 0.0, q):
			# Back off to the last free point and find the side we hit.
			var n := Vector3.ZERO
			var dd := prev - p
			if absf(dd.x) >= absf(dd.z):
				n = Vector3(signf(dd.x), 0, 0)
			else:
				n = Vector3(0, 0, signf(dd.z))
			return {"point": prev, "normal": n}
		prev = p
		if p.y < mgr.ground_y_at(p) - 0.5:
			return {}
	return {}


# --- input -----------------------------------------------------------------------

func handle_input(event: InputEvent) -> bool:
	if tool.is_empty():
		return false
	if event is InputEventMouse:
		_mouse = (event as InputEventMouse).position
	if event is InputEventKey and (event as InputEventKey).pressed:
		return _handle_key(event as InputEventKey)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if bool(ui.call("_pointer_over_ui")) or CursorController.overlay_look_active():
				return false
			_on_press(mb)
			return true
		if not _press.is_empty() or not _drag.is_empty():
			_on_release()
			return true
	return false


func _handle_key(key: InputEventKey) -> bool:
	if key.keycode == KEY_Z and key.ctrl_pressed:
		return false
	if (key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE) and not _picked.is_empty():
		if str(_hover.get("kind", "")) == "via":
			_remove_via(int(_hover["index"]))
			return true
	return false


func _on_press(mb: InputEventMouseButton) -> void:
	_mouse = mb.position
	_hover = _pick()
	match tool:
		"route_connect":
			_press_connect(mb.shift_pressed)
		"route_style":
			if str(_hover.get("kind", "")) == "run":
				var gv := _gv()
				if gv != null and gv.has_method("open_conduit_style_modal"):
					gv.call("open_conduit_style_modal", str(_hover["id"]))
		_:
			var kind := str(_hover.get("kind", ""))
			if kind == "via":
				var now := Time.get_ticks_msec()
				if now - _last_click_ms < DOUBLE_CLICK_MS and _last_click_via == int(_hover["index"]):
					_remove_via(int(_hover["index"]))
					_last_click_ms = 0
					return
				_last_click_ms = now
				_last_click_via = int(_hover["index"])
				_press = {"px": mb.position, "hover": _hover.duplicate(), "shift": mb.shift_pressed}
			elif kind == "wall" and tool == "route_wall":
				_add_wall_via(_hover["hit"] as Dictionary)
			elif kind == "run":
				if str(_hover["id"]) != _picked:
					_pick_run(str(_hover["id"]))
					if tool != "route_height" and tool != "route_lane":
						return
				_press = {"px": mb.position, "hover": _hover.duplicate(), "shift": mb.shift_pressed}
			else:
				if not _picked.is_empty():
					_pick_run("")


func _on_release() -> void:
	if not _drag.is_empty():
		_end_drag()
		return
	var hv: Dictionary = _press.get("hover", {}) as Dictionary
	_press = {}
	# A click (no drag) on the picked run adds a bend point there.
	if tool == "route_bend" and str(hv.get("kind", "")) == "run" and str(hv["id"]) == _picked:
		_insert_via(hv["point"] as Vector3)


func _pick_run(cid: String) -> void:
	_picked = cid
	var mgr := _mgr()
	if mgr != null:
		mgr.set_focus_highlight(cid)
	if cid.is_empty():
		_status("Click a run")
	else:
		var conn := _model().get_connection(cid)
		var len_m := float(conn.get("route_length_m", 0.0))
		_status("%s · %s · %s" % [ConduitKinds.display_name_with_size(
			ConduitKinds.derive_type_for_connection(conn), conn.get("conduit_style", {}) as Dictionary),
			ConduitLength.format(len_m) if len_m > 0.0 else "not drawn yet",
			UiText.count(_vias(cid).size(), "bend point")])
	if ui != null:
		ui.call("_rebuild_options_bar")


# --- Connect ---------------------------------------------------------------------

func _press_connect(shift: bool) -> void:
	var hit: Dictionary = _hover.get("hit", {}) as Dictionary
	if hit.is_empty():
		if not _src.is_empty():
			_status("Click a matching port on the other machine (Esc cancels)")
		return
	if _src.is_empty():
		_src = hit
		_ghost = PackedVector3Array()
		_ghost_key = ""
		_status("From %s — now click a port on the other machine" % _port_name(hit))
		return
	if str(hit.get("item_id", "")) == str(_src.get("item_id", "")):
		_status("That is the same machine — pick a port on another one")
		return
	if not ConduitPlugLogic.ports_compatible(_src, hit):
		_status("%s cannot join %s" % [_port_name(_src), _port_name(hit)])
		return
	var spec := _draft_spec(_src, hit)
	var mgr := _mgr()
	if mgr == null:
		return
	var cid := mgr.create_plug_connection(spec)
	if cid.is_empty():
		_status("Could not make that run")
		return
	_edits += 1
	var gv := _gv()
	if gv != null and gv.has_method("_schedule_graph_autosave"):
		gv.call("_schedule_graph_autosave")
	var conn := _model().get_connection(cid)
	_status("Run made · %s · %s" % [ConduitKinds.display_name_with_size(
		ConduitKinds.derive_type_for_connection(conn), conn.get("conduit_style", {}) as Dictionary),
		ConduitLength.format(float(conn.get("route_length_m", 0.0)))])
	var from_hit := hit
	_src = {}
	_ghost = PackedVector3Array()
	if ui != null:
		ui.call("_update_undo_button")
	if shift:
		var nxt := _next_free_port(from_hit)
		if not nxt.is_empty():
			_src = nxt
			_status("Chaining from %s" % _port_name(nxt))


## The connection the tool would make between two port hits: kind and size
## from the options bar (else what the port carries), the solver, drawn.
func _draft_spec(a: Dictionary, b: Dictionary) -> Dictionary:
	var kind := new_kind
	if kind.is_empty():
		kind = _kind_for_port(a.get("port", {}) as Dictionary)
	var spec := ConduitPlugLogic.build_connection_spec(a, b, kind, [])
	spec["route_solver"] = "v2"
	spec["visible_3d"] = true
	var style: Dictionary = spec.get("conduit_style", {}) as Dictionary
	var key := ConduitSpecs.size_key(kind)
	if new_size > 0.0 and not key.is_empty():
		style[key] = new_size
	if new_height > 0.0:
		var mgr := _mgr()
		var g := 0.0
		if mgr != null:
			var pa: Vector3 = a.get("world_pos", Vector3.ZERO)
			g = mgr.ground_y_at(pa)
		style["run_height_m"] = g + new_height
	if not style.is_empty():
		spec["conduit_style"] = style
	return spec


## The port's own preferred kind, else what it carries (the plug drag's rule).
static func _kind_for_port(port: Dictionary) -> String:
	var pref := str(port.get("preferred_conduit_type", "")).strip_edges()
	if not pref.is_empty() and ConduitKinds.has_type(pref):
		return pref
	var rk := str(port.get("resource_kind", ""))
	return str(ConduitKinds.RESOURCE_DEFAULTS.get(rk, "extension_cord")) if not rk.is_empty() \
		else "extension_cord"


func _update_connect_ghost() -> void:
	var tgt: Dictionary = _hover.get("hit", {}) as Dictionary
	var mgr := _mgr()
	if mgr == null:
		return
	if tgt.is_empty() or str(tgt.get("item_id", "")) == str(_src.get("item_id", "")):
		var key0 := "free|%s" % str(_mouse.round())
		if key0 != _ghost_key:
			_ghost_key = key0
			_ghost = PackedVector3Array()
			_ghost_ok = false
		return
	var key := "%s|%s" % [str(tgt.get("item_id", "")), str((tgt.get("port", {}) as Dictionary).get("id", ""))]
	if key == _ghost_key:
		return
	_ghost_key = key
	_ghost_ok = ConduitPlugLogic.ports_compatible(_src, tgt)
	var spec := _draft_spec(_src, tgt)
	# Drawn through the committed build's own samples (a cord on the ground).
	_ghost = mgr.preview_samples(spec, mgr.build_control_points(spec))


func _next_free_port(target_hit: Dictionary) -> Dictionary:
	var model := _model()
	var used := {}
	for c: Dictionary in model.connections:
		used["%s|%s" % [c.get("source_item_id", ""), c.get("source_handle_id", "")]] = true
		used["%s|%s" % [c.get("target_item_id", ""), c.get("target_handle_id", "")]] = true
	var tp: Vector3 = target_hit.get("world_pos", Vector3.ZERO)
	var best := {}
	var best_d := INF
	for h: Variant in _ports_now():
		var d: Dictionary = h
		if str(d.get("item_id", "")) != str(target_hit.get("item_id", "")) or d == target_hit:
			continue
		var pd: Dictionary = d.get("port", {}) as Dictionary
		var hid := str(pd.get("handle_id", pd.get("id", "")))
		if used.has("%s|%s" % [d.get("item_id", ""), hid]):
			continue
		var dist := (d["world_pos"] as Vector3).distance_to(tp)
		if dist < best_d:
			best_d = dist
			best = d
	return best


func _port_name(hit: Dictionary) -> String:
	var model := _model()
	var item := model.get_item(str(hit.get("item_id", ""))) if model != null else {}
	var nm := str((item.get("specs", {}) as Dictionary).get("name", item.get("label", "machine")))
	var port: Dictionary = hit.get("port", {}) as Dictionary
	return "%s · %s" % [nm, str(port.get("label", port.get("id", "port")))]


# --- Bend / Height / Along wall --------------------------------------------------

func _begin_drag() -> void:
	var hv: Dictionary = _press.get("hover", {}) as Dictionary
	var kind := str(hv.get("kind", ""))
	if kind == "via":
		var vias := _vias(_picked)
		var i := int(hv["index"])
		_drag = {"what": "via", "index": i, "start": vias[i], "pos": vias[i],
			"vertical": bool(_press.get("shift", false))}
	elif kind == "run" and tool == "route_height" and str(hv["id"]) == _picked:
		var p: Vector3 = hv["point"]
		_drag = {"what": "height", "start": p, "pos": p, "y": p.y}
	elif kind == "run" and tool == "route_lane":
		_begin_lane_drag(hv)
	_press = {}


func _update_drag() -> void:
	var r := _ray()
	if r.is_empty():
		return
	var o: Vector3 = r[0]
	var d: Vector3 = r[1]
	var start: Vector3 = _drag["start"]
	if str(_drag["what"]) == "lane":
		_update_lane_drag(o, d)
		return
	if str(_drag["what"]) == "via" and not bool(_drag.get("vertical", false)):
		# Slide in the via's own horizontal plane.
		if absf(d.y) < 1e-4:
			return
		var t := (start.y - o.y) / d.y
		if t <= 0.0:
			return
		var p := o + d * t
		_drag["pos"] = Vector3(snappedf(p.x, 0.05), start.y, snappedf(p.z, 0.05))
	else:
		# Up or down on the vertical plane through the point, facing the camera.
		var cam := _cam()
		var n := cam.global_transform.basis.z
		n.y = 0.0
		if n.length_squared() < 1e-6:
			return
		n = n.normalized()
		var denom := n.dot(d)
		if absf(denom) < 1e-5:
			return
		var t2 := n.dot(start - o) / denom
		var y := (o + d * t2).y
		y = _snap_height(start, y)
		_drag["y"] = y
		_drag["pos"] = Vector3(start.x, y, start.z)
	_update_drag_ghost()


func _snap_height(at: Vector3, y: float) -> float:
	var mgr := _mgr()
	var g := mgr.ground_y_at(at) if mgr != null else 0.0
	var best := y
	var best_px := SNAP_PX
	for s: float in HEIGHT_SNAPS:
		var sy := g + s
		var a := _proj(Vector3(at.x, y, at.z))
		var b := _proj(Vector3(at.x, sy, at.z))
		if is_finite(a.x) and is_finite(b.x) and a.distance_to(b) < best_px:
			best_px = a.distance_to(b)
			best = sy
	if best == y:
		best = snappedf(y - g, 0.05) + g
	return best


## The run as it would be with the drag applied, built by the same call.
func _update_drag_ghost() -> void:
	var mgr := _mgr()
	var model := _model()
	if mgr == null or model == null:
		return
	var conn := model.get_connection(_picked).duplicate(true)
	conn.erase("id")
	conn["route_solver"] = "v2"
	if str(_drag["what"]) == "via":
		var vias := _vias(_picked)
		vias[int(_drag["index"])] = _drag["pos"]
		conn["route_3d"] = _via_dicts(vias)
	else:
		var st: Dictionary = (conn.get("conduit_style", {}) as Dictionary).duplicate()
		st["run_height_m"] = float(_drag["y"])
		conn["conduit_style"] = st
	_ghost = PackedVector3Array()
	for p: Variant in mgr.build_control_points(conn):
		if p is Vector3:
			_ghost.append(p as Vector3)
	_ghost_ok = true


func _end_drag() -> void:
	var what := str(_drag.get("what", ""))
	var gv := _gv()
	if what == "lane":
		_end_lane_drag()
		_drag = {}
		_ghost = PackedVector3Array()
		return
	if what == "via":
		var vias := _vias(_picked)
		vias[int(_drag["index"])] = _drag["pos"]
		_write_route(vias, {})
		_status("Bend point moved")
	elif what == "height":
		var mgr := _mgr()
		var y := float(_drag["y"])
		var g := mgr.ground_y_at(_drag["start"] as Vector3) if mgr != null else 0.0
		_write_route(_vias(_picked), {"run_height_m": y})
		_status("Runs %.2f m above the ground" % (y - g))
	_drag = {}
	_ghost = PackedVector3Array()
	if gv != null:
		_redraw()


func _insert_via(p: Vector3) -> void:
	var vias := _vias(_picked)
	var mgr := _mgr()
	var samples := mgr.get_sample_points(_picked) if mgr != null else PackedVector3Array()
	var at := _param_on(samples, p)
	var idx := vias.size()
	for i: int in range(vias.size()):
		if _param_on(samples, vias[i] as Vector3) > at:
			idx = i
			break
	vias.insert(idx, p)
	_write_route(vias, {})
	_status("Bend point added · drag it to move, double-click to remove")


func _remove_via(i: int) -> void:
	var vias := _vias(_picked)
	if i < 0 or i >= vias.size():
		return
	vias.remove_at(i)
	_write_route(vias, {})
	_hover = {}
	_status("Bend point removed")


func _add_wall_via(w: Dictionary) -> void:
	if _picked.is_empty():
		return
	var p: Vector3 = w["point"]
	var n: Vector3 = w["normal"]
	var conn := _model().get_connection(_picked)
	var type_id := ConduitKinds.derive_type_for_connection(conn)
	var off := ConduitSpecs.od_m(type_id, conn.get("conduit_style", {}) as Dictionary) * 0.5 + 0.09
	var via := p + n * off
	var vias := _vias(_picked)
	vias.append(via)
	# Order the new via with the others along the run.
	var mgr := _mgr()
	var samples := mgr.get_sample_points(_picked)
	vias.sort_custom(func(x: Vector3, y: Vector3) -> bool:
		return _param_on(samples, x) < _param_on(samples, y))
	_write_route(vias, {"wall_hug": true, "run_height_m": via.y})
	_status("Runs along that side at %.2f m" % (via.y - mgr.ground_y_at(via)))


## Where along a polyline a point falls (arc length of the nearest point).
static func _param_on(pts: PackedVector3Array, p: Vector3) -> float:
	var best := INF
	var best_s := 0.0
	var s := 0.0
	for i: int in range(pts.size() - 1):
		var q := Geometry3D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
		var dd := q.distance_to(p)
		if dd < best:
			best = dd
			best_s = s + pts[i].distance_to(q)
		s += pts[i].distance_to(pts[i + 1])
	return best_s


static func _via_dicts(vias: Array) -> Array:
	var out: Array = []
	for v: Variant in vias:
		var p: Vector3 = v
		out.append({"x": p.x, "y": p.y, "z": p.z})
	return out


func _write_route(vias: Array, style_patch: Dictionary) -> void:
	var gv := _gv()
	if gv == null or not gv.has_method("set_run_route"):
		return
	gv.call("set_run_route", _picked, _via_dicts(vias), style_patch)
	_edits += 1
	if ui != null:
		ui.call("_update_undo_button")


# --- Lane --------------------------------------------------------------------------

## Pressing a run in a bundle: its lane, the bundle's order, the sideways
## direction at the point pressed and the lane pitch.
func _begin_lane_drag(hv: Dictionary) -> void:
	var mgr := _mgr()
	var cid := str(hv["id"])
	var b := mgr.bundle_of(cid) if mgr != null else {}
	if b.is_empty():
		_status("That run is not in a bundle: lay two runs along the same line and they share one")
		return
	var pts := mgr.get_sample_points(cid)
	var si := int(hv.get("seg", 0))
	var dir := Vector3.RIGHT
	if si + 1 < pts.size():
		dir = pts[si + 1] - pts[si]
	dir.y = 0.0
	if dir.length_squared() < 1e-8:
		dir = Vector3.RIGHT
	dir = dir.normalized()
	var info := mgr.run_info(cid)
	var pitch := float(info.get("od", 0.03)) + ConduitBundler.GAP_M
	var side := Vector3(dir.z, 0.0, -dir.x)
	# "Sideways" is toward the next lane as drawn (the leg under the pointer
	# can be a riser or a bend, whose own perpendicular means nothing here).
	var members: Array = b["members"]
	var lane := int(b["lane"])
	var nb_lane := lane + 1 if lane + 1 < members.size() else lane - 1
	if nb_lane >= 0 and nb_lane < members.size():
		var at: Vector3 = hv["point"]
		var near := Vector3.INF
		for q: Vector3 in mgr.get_sample_points(str(members[nb_lane])):
			if not is_finite(near.x) or q.distance_to(at) < near.distance_to(at):
				near = q
		var d2 := near - at
		d2.y = 0.0
		if is_finite(near.x) and d2.length() > 0.005 and d2.length() < 1.0:
			side = d2.normalized() * (1.0 if nb_lane > lane else -1.0)
			pitch = d2.length()
	_pick_run(cid)
	_drag = {"what": "lane", "start": hv["point"], "pos": hv["point"], "side": side,
		"pitch": pitch, "lane": int(b["lane"]), "lanes": int(b["lanes"]), "side_m": side,
		"members": b["members"], "target": int(b["lane"]), "out": false}


func _update_lane_drag(o: Vector3, d: Vector3) -> void:
	var start: Vector3 = _drag["start"]
	if absf(d.y) < 1e-4:
		return
	var t := (start.y - o.y) / d.y
	if t <= 0.0:
		return
	var p := o + d * t
	_drag["pos"] = p
	var side: Vector3 = _drag["side"]
	var off := (p - start).dot(side)
	var pitch := float(_drag["pitch"])
	var lanes := int(_drag["lanes"])
	var lane := int(_drag["lane"])
	# Well clear of the bundle: out of it.
	var clear := float(lanes) * pitch * 0.5 + 0.8
	_drag["out"] = absf(off) > clear
	_drag["target"] = clampi(lane + roundi(off / pitch), 0, lanes - 1)


func _end_lane_drag() -> void:
	var gv := _gv()
	if gv == null or not gv.has_method("set_lane_order"):
		return
	var cid := _picked
	var members: Array = (_drag["members"] as Array).duplicate()
	if bool(_drag["out"]):
		var vias := _vias(cid)
		vias.append(_drag["pos"])
		var mgr := _mgr()
		var samples := mgr.get_sample_points(cid)
		vias.sort_custom(func(x: Vector3, y: Vector3) -> bool:
			return _param_on(samples, x) < _param_on(samples, y))
		members.erase(cid)
		gv.call("set_lane_order", members, {cid: {"lane_free": true, "route_3d": _via_dicts(vias)}})
		_status("Taken out of the bundle: it runs on its own through where you let go")
	else:
		var target := int(_drag["target"])
		if target == int(_drag["lane"]):
			return
		members.erase(cid)
		members.insert(target, cid)
		gv.call("set_lane_order", members)
		_status("Moved to lane %d of %d" % [target + 1, members.size()])
	_edits += 1
	if ui != null:
		ui.call("_update_undo_button")


# --- undo / options / draw -------------------------------------------------------

func can_undo() -> bool:
	return _edits > 0


func undo() -> bool:
	var gv := _gv()
	if gv == null or _edits <= 0 or not gv.has_method("_do_undo"):
		return false
	gv.call("_do_undo")
	_edits -= 1
	var mgr := _mgr()
	if mgr != null:
		mgr.sync_all()
	return true


## Kinds the Connect tool offers: everything a player lays as a 3D run.
const NEW_KINDS := ["", "pvc_pipe", "abs_dwv", "copper_type_l", "pex_blue", "pex_red",
	"garden_hose", "emt_conduit", "romex", "extension_cord", "dc_solar", "ethernet",
	"ducting", "conceptual_flow"]


func build_rows(box: Container) -> void:
	_rows.clear()
	if tool == "route_connect":
		var k := OptionButton.new()
		k.focus_mode = Control.FOCUS_NONE
		for kid: String in NEW_KINDS:
			k.add_item("Kind: by what it carries" if kid.is_empty() else ConduitKinds.display_name(kid))
			k.set_item_metadata(k.item_count - 1, kid)
			if kid == new_kind:
				k.select(k.item_count - 1)
		k.item_selected.connect(func(i: int) -> void:
			new_kind = str(k.get_item_metadata(i))
			new_size = 0.0
			ui.call("_rebuild_options_bar"))
		box.add_child(k)
		_rows["kind"] = k
		if not new_kind.is_empty() and ConduitSpecs.has_sizes(new_kind):
			var s := OptionButton.new()
			s.focus_mode = Control.FOCUS_NONE
			for r: Variant in ConduitSpecs.table(new_kind)["rows"] as Array:
				var rd: Dictionary = r
				s.add_item(str(rd["label"]))
				s.set_item_metadata(s.item_count - 1, float(rd["value"]))
				if is_equal_approx(float(rd["value"]), new_size):
					s.select(s.item_count - 1)
			s.item_selected.connect(func(i: int) -> void:
				new_size = float(s.get_item_metadata(i)))
			box.add_child(s)
			_rows["size"] = s
		var h := OptionButton.new()
		h.focus_mode = Control.FOCUS_NONE
		for pair: Array in [[0.0, "Height: as the ports are"], [0.1, "On the floor"],
				[0.45, "Knee height"], [1.2, "Bench height"], [2.4, "Overhead"]]:
			h.add_item(str(pair[1]))
			h.set_item_metadata(h.item_count - 1, float(pair[0]))
			if is_equal_approx(float(pair[0]), new_height):
				h.select(h.item_count - 1)
		h.item_selected.connect(func(i: int) -> void:
			new_height = float(h.get_item_metadata(i)))
		box.add_child(h)
		_rows["height"] = h
	elif not _picked.is_empty():
		var lbl := Label.new()
		var conn := _model().get_connection(_picked)
		var tid := ConduitKinds.derive_type_for_connection(conn)
		var spec := ConduitSpecs.for_run(conn)
		lbl.text = "%s · %s · bends %.0f mm" % [ConduitKinds.display_name_with_size(tid,
			conn.get("conduit_style", {}) as Dictionary), ConduitLength.format(float(spec["length_m"])),
			float(spec["bend_radius_m"]) * 1000.0]
		box.add_child(lbl)
		var style_btn := Button.new()
		style_btn.text = "Style…"
		style_btn.focus_mode = Control.FOCUS_NONE
		style_btn.pressed.connect(func() -> void:
			var gv := _gv()
			if gv != null:
				gv.call("open_conduit_style_modal", _picked))
		box.add_child(style_btn)
		var proc_btn := Button.new()
		proc_btn.name = "OpenInProcess"
		proc_btn.text = "Open in Process"
		proc_btn.tooltip_text = "Show this run in the graph's Process lens"
		proc_btn.focus_mode = Control.FOCUS_NONE
		proc_btn.pressed.connect(func() -> void:
			var gv := _gv()
			if gv != null and gv.has_method("open_run_in_process"):
				var cid := _picked
				ui.call("_exit_mode")
				gv.call("open_run_in_process", cid))
		box.add_child(proc_btn)
		var bd := _mgr().bundle_of(_picked) if _mgr() != null else {}
		if not bd.is_empty():
			var lane_lbl := Label.new()
			lane_lbl.text = "Lane %d of %d" % [int(bd["lane"]) + 1, int(bd["lanes"])]
			box.add_child(lane_lbl)
		if bool((conn.get("conduit_style", {}) as Dictionary).get("lane_free", false)):
			var rejoin := Button.new()
			rejoin.text = "Back into its bundle"
			rejoin.focus_mode = Control.FOCUS_NONE
			rejoin.pressed.connect(func() -> void:
				var gv2 := _gv()
				if gv2 != null:
					gv2.call("set_lane_order", [], {_picked: {"lane_free": false}})
					_edits += 1
					_status("Back in its bundle"))
			box.add_child(rejoin)
		var clear_btn := Button.new()
		clear_btn.text = "Clear bend points"
		clear_btn.focus_mode = Control.FOCUS_NONE
		clear_btn.pressed.connect(func() -> void:
			_write_route([], {"run_height_m": null, "wall_hug": null})
			_status("Bend points cleared · routed afresh"))
		box.add_child(clear_btn)
	if tool != "route_connect" and _picked.is_empty():
		var gv3 := _gv()
		var pinned: Array = gv3.call("pinned_runs_to_reroute") if gv3 != null \
				and gv3.has_method("pinned_runs_to_reroute") else []
		if not pinned.is_empty():
			var rr := Button.new()
			rr.name = "ReroutePinned"
			rr.focus_mode = Control.FOCUS_NONE
			var armed := Time.get_ticks_msec() - _reroute_armed_ms < 4000
			rr.text = ("Re-route %d pinned run%s? Click again" if armed else "Re-route pinned runs (%d)…") \
					% ([pinned.size(), "" if pinned.size() == 1 else "s"] if armed else [pinned.size()])
			rr.tooltip_text = ("Runs whose path you pinned keep it exactly. This puts them on the router: " +
				"square, real bends, round what is in the way, passing through your pinned points. " +
				"Penstocks, culverts and siphons are never touched. Ctrl+Z takes it back.")
			rr.pressed.connect(func() -> void:
				if Time.get_ticks_msec() - _reroute_armed_ms >= 4000:
					_reroute_armed_ms = Time.get_ticks_msec()
					ui.call("_rebuild_options_bar")
					return
				_reroute_armed_ms = 0
				var n: int = gv3.call("reroute_pinned_runs", pinned)
				_edits += 1
				_status("%s re-routed" % UiText.count(n, "run"))
				ui.call("_rebuild_options_bar"))
			box.add_child(rr)
	var all := CheckBox.new()
	all.text = "Service colours"
	all.tooltip_text = "Show every run in the colour of what it carries: hot water red, cold blue, drain grey, power yellow, data green"
	all.button_pressed = show_all
	all.focus_mode = Control.FOCUS_NONE
	all.toggled.connect(func(on: bool) -> void:
		set_show_all(on))
	box.add_child(all)


func draw(canvas: Control) -> void:
	if tool.is_empty():
		return
	var font := ThemeDB.fallback_font
	if tool == "route_connect":
		var cam := _cam()
		for h: Variant in _ports_now():
			var d: Dictionary = h
			var wp: Vector3 = d["world_pos"]
			if cam != null and wp.distance_to(cam.global_position) > PORT_RANGE_M:
				continue
			var sp := _proj(wp)
			if not is_finite(sp.x):
				continue
			var ok := _src.is_empty() or ConduitPlugLogic.ports_compatible(_src, d)
			var col := COL_PORT if _src.is_empty() else (COL_PORT_OK if ok else Color(0.6, 0.6, 0.6, 0.45))
			canvas.draw_circle(sp, 4.5, Color(0, 0, 0, 0.55))
			canvas.draw_circle(sp, 3.2, col)
		if not _src.is_empty():
			var ss := _proj(_src["world_pos"] as Vector3)
			if is_finite(ss.x):
				canvas.draw_arc(ss, 9.0, 0.0, TAU, 24, COL_PICK, 2.5, true)
		var hv: Dictionary = _hover.get("hit", {}) as Dictionary
		if not hv.is_empty():
			var hs := _proj(hv["world_pos"] as Vector3)
			if is_finite(hs.x):
				canvas.draw_arc(hs, 8.0, 0.0, TAU, 24, COL_PORT_OK, 2.0, true)
				_label(canvas, font, hs + Vector2(12, -10), _port_name(hv))
	# The picked run, its bend points.
	if not _picked.is_empty():
		var mgr := _mgr()
		if mgr != null:
			_polyline(canvas, mgr.get_sample_points(_picked), Color(COL_PICK, 0.55), 5.0)
		var vias := _vias(_picked)
		for i: int in range(vias.size()):
			var sp := _proj(vias[i] as Vector3)
			if not is_finite(sp.x):
				continue
			var hov := str(_hover.get("kind", "")) == "via" and int(_hover["index"]) == i
			var r := 7.0 if hov else 5.5
			canvas.draw_rect(Rect2(sp - Vector2(r, r), Vector2(r, r) * 2.0), Color(0, 0, 0, 0.6))
			canvas.draw_rect(Rect2(sp - Vector2(r - 1.5, r - 1.5), Vector2(r - 1.5, r - 1.5) * 2.0),
				COL_VIA if not hov else COL_PICK)
	elif str(_hover.get("kind", "")) == "run":
		var mgr2 := _mgr()
		if mgr2 != null:
			_polyline(canvas, mgr2.get_sample_points(str(_hover["id"])), Color(COL_PICK, 0.4), 4.0)
	if str(_hover.get("kind", "")) == "wall":
		var w: Dictionary = _hover["hit"]
		var wsp := _proj(w["point"] as Vector3)
		if is_finite(wsp.x):
			canvas.draw_circle(wsp, 6.0, Color(0.4, 0.9, 1.0, 0.9))
			_label(canvas, font, wsp + Vector2(10, -10), "Run along here")
	# The ghost: what will be made.
	if _ghost.size() >= 2:
		_polyline(canvas, _ghost, COL_PORT_OK if _ghost_ok else COL_BAD, 4.0)
		var len_m := 0.0
		for i: int in range(_ghost.size() - 1):
			len_m += _ghost[i].distance_to(_ghost[i + 1])
		var tip := _proj(_ghost[_ghost.size() - 1])
		if is_finite(tip.x):
			_label(canvas, font, tip + Vector2(12, 8), ConduitLength.format(len_m))
	if not _drag.is_empty() and str(_drag["what"]) == "lane":
		var lp := _proj(_drag["pos"] as Vector3)
		if is_finite(lp.x):
			_label(canvas, font, lp + Vector2(14, -14), "Out of the bundle" if bool(_drag["out"])
				else "Lane %d of %d" % [int(_drag["target"]) + 1, int(_drag["lanes"])])
	if not _drag.is_empty() and str(_drag["what"]) == "height":
		var mgr3 := _mgr()
		var pos: Vector3 = _drag["pos"]
		var g := mgr3.ground_y_at(pos) if mgr3 != null else 0.0
		var hp := _proj(pos)
		if is_finite(hp.x):
			_label(canvas, font, hp + Vector2(14, -14), "%.2f m above the ground" % (pos.y - g))


func _polyline(canvas: Control, pts: PackedVector3Array, col: Color, w: float) -> void:
	var prev := Vector2.INF
	for p: Vector3 in pts:
		var sp := _proj(p)
		if is_finite(prev.x) and is_finite(sp.x):
			canvas.draw_line(prev, sp, col, w, true)
		prev = sp


func _label(canvas: Control, font: Font, at: Vector2, text: String) -> void:
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM)
	canvas.draw_rect(Rect2(at - Vector2(4, size.y - 2), size + Vector2(8, 6)), Color(0.05, 0.07, 0.1, 0.82))
	canvas.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, Color(0.95, 0.96, 1.0))
