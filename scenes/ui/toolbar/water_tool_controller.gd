extends RefCounted

## The toolbar's WATER section — five tools over the map's WaterNetwork:
##
##   Trace  click anywhere: water's own path downhill (the drainage grid) becomes
##          a stream, ending where it joins one
##   Draw   click waypoints, Enter (or double-click) to finish; a line drawn
##          uphill is reversed so it always runs downstream
##   Edit   click a stream (OSM, yours, or a derived drainage line) to pick it;
##          drag a waypoint to move it, drag the line to insert one, Del removes
##          the hovered waypoint (or, with none hovered, deletes / hides the
##          stream), Ctrl-drag moves the whole stream. Sliders set its cross-
##          section and base flow; buttons reverse / promote / revert / delete
##   Span   click a span (between two waypoints) to make it open channel,
##          culvert or pipe
##   View   what is drawn (streams, the drainage network, flow view), the
##          drainage threshold, carving on/off and Re-carve
##
## Same pin contract as the J Light Studio: press arms, motion past DRAG_PX
## promotes to a drag, release commits ONE undo step. Picking is screen-space
## against projected waypoints / lines (the waypoints sit on the ground, so a
## pixel radius is the honest "can I click it" test at every zoom).
##
## No class_name on purpose: the toolbar preloads it (stale-class-cache rule).

const DRAG_PX := 6.0
const PIN_PICK_PX := 11.0
const LINE_PICK_PX := 9.0
const DRAW_RANGE_M := 1400.0
const DERIVED_RANGE_M := 900.0
const DOUBLE_CLICK_MS := 350

const COL_OSM := Color(0.35, 0.80, 1.0, 0.95)
const COL_USER := Color(0.40, 1.0, 0.65, 0.95)
const COL_DERIVED := Color(0.55, 0.65, 1.0, 0.55)
const COL_CULVERT := Color(1.0, 0.62, 0.25, 0.95)
const COL_PIPE := Color(0.95, 0.45, 0.95, 0.95)
const COL_PENSTOCK := Color(0.30, 0.95, 0.95, 0.95)
## How far from a reach vertex an existing PowerSpout is adopted as the
## penstock's turbine before a new one is seated at the reach's end.
const PENSTOCK_TURBINE_REACH_M := 250.0
const COL_PICK := Color(1.0, 0.92, 0.35, 1.0)
const COL_BLOCKED := Color(1.0, 0.30, 0.30, 0.95)
const KIND_CHOICES := ["stream", "river", "canal", "ditch", "drain"]

var ui: Control = null
var tool := ""

## pts3 / modes = the WAYPOINTS (pins, spans); path3 / pseg = the curved
## centreline StreamCurve made from them and, per centreline span, its
## waypoint span (what is drawn and what a line click hits).
var _lines: Array = []          # [{id, source, pts3, modes, kind, path3, pseg, curve}]
var _lines_dirty := true
var _proj: Dictionary = {}      # id -> PackedVector2Array (screen; INF = hidden)
var _proj_path: Dictionary = {} # id -> PackedVector2Array, the centreline on screen
var _picked := ""
var _hover := {}                # {kind: "pin"|"line", id, index}
var _press := {}                # armed press: {px, hover, ctrl}
var _drag := {}                 # {id, index (-1 = whole), points, modes, start}
var _draw_pts := PackedVector2Array()
var _draw_kind := "stream"
var _span_mode := "culvert"
var _last_click_ms := 0
var _cursor_world: Variant = null
var _apply_timer: Timer = null
var _pending_patch: Dictionary = {}
var _checkpointed_patch := false
var _rows: Dictionary = {}
var _connected := false
## Last pointer position seen in an event (pushed events update this even when
## the OS cursor does not move, which is what makes the harness drive work).
var _mouse := Vector2(-1.0, -1.0)
var _last_proc_mouse := Vector2(-1e9, -1e9)
var _last_proc_cam := Transform3D()


func setup(toolbar: Control) -> void:
	ui = toolbar
	_apply_timer = Timer.new()
	_apply_timer.one_shot = true
	_apply_timer.wait_time = 0.35
	_apply_timer.timeout.connect(_flush_patch)
	ui.add_child(_apply_timer)


func network() -> Node:
	var loader: Node = ui.get("_loader") if ui != null else null
	if loader == null or not loader.has_method("water_network"):
		return null
	return loader.call("water_network")


func loader() -> Node:
	return ui.get("_loader") if ui != null else null


func is_water_tool(id: String) -> bool:
	return id.begins_with("water_")


func activate(tool_id: String) -> void:
	tool = tool_id
	_press = {}
	_drag = {}
	_hover = {}
	_draw_pts = PackedVector2Array()
	_lines_dirty = true
	var wn := network()
	if wn != null and not _connected:
		wn.features_changed.connect(_mark_dirty)
		wn.network_rebuilt.connect(_mark_dirty)
		wn.drainage_changed.connect(_mark_dirty)
		_connected = true
	if tool == "water_trace" and wn != null and (wn.call("drainage") as Dictionary).is_empty():
		wn.call("request_drainage")
		_status("Analysing drainage…")


func deactivate() -> void:
	_flush_patch()
	tool = ""
	_press = {}
	_drag = {}
	_draw_pts = PackedVector2Array()


func _mark_dirty() -> void:
	_lines_dirty = true
	if ui != null:
		ui.call("_queue_overlay_redraw")


func _status(msg: String) -> void:
	if ui != null:
		ui.call("_set_status", msg)


# ---------------------------------------------------------------------------
# Line cache (world positions on the ground) + per-frame projection
# ---------------------------------------------------------------------------

func _rebuild_lines() -> void:
	_lines = []
	var wn := network()
	var ld := loader()
	if wn == null or ld == null:
		return
	for f_v in wn.call("features"):
		var f: Dictionary = f_v
		var ctrl: PackedVector2Array = f.get("ctrl_points", f["points"])
		var rec := {"id": str(f["id"]), "source": str(f["source"]),
			"pts3": _lift(ctrl, ld), "modes": f.get("ctrl_modes", f["modes"]), "kind": str(f["kind"]),
			"curve": f}
		if f.has("ctrl_seg") and (f["points"] as PackedVector2Array).size() != ctrl.size():
			rec["path3"] = _lift(f["points"], ld)
			rec["pseg"] = f["ctrl_seg"]
		_lines.append(rec)
	if tool == "water_edit" or tool == "water_trace" or tool == "water_span":
		for ch_v in wn.call("derived_channels"):
			var ch: Dictionary = ch_v
			_lines.append({"id": str(ch["id"]), "source": "derived",
				"pts3": _lift(ch["points"], ld), "modes": [], "kind": "stream",
				"order": int(ch.get("order", 1))})
	_lines_dirty = false


static func _lift(pts: PackedVector2Array, ld: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = Vector3(pts[i].x, float(ld.call("ground_height_at", pts[i].x, pts[i].y)) + 0.3, pts[i].y)
	return out


func _line(id: String) -> Dictionary:
	for l in _lines:
		if str((l as Dictionary)["id"]) == id:
			return l
	return {}


func _project_all() -> void:
	_proj = {}
	_proj_path = {}
	var cam := ui.get_viewport().get_camera_3d() if ui != null else null
	if cam == null:
		return
	var cp := cam.global_position
	for l_v in _lines:
		var l: Dictionary = l_v
		var pts3: PackedVector3Array = l["pts3"]
		var path3: Variant = l.get("path3", null)
		if _drag.get("id", "") == l["id"]:
			pts3 = _lift(_drag["points"], loader())
			path3 = _drag_path3(l)
		var range_m := DERIVED_RANGE_M if str(l["source"]) == "derived" else DRAW_RANGE_M
		var near := false
		for p in pts3:
			if Vector2(p.x - cp.x, p.z - cp.z).length() < range_m:
				near = true
				break
		if not near:
			continue
		_proj[l["id"]] = _unproject(cam, pts3)
		if path3 is PackedVector3Array:
			_proj_path[l["id"]] = _unproject(cam, path3)


static func _unproject(cam: Camera3D, pts3: PackedVector3Array) -> PackedVector2Array:
	var sp := PackedVector2Array()
	sp.resize(pts3.size())
	for i in pts3.size():
		sp[i] = Vector2(INF, INF) if cam.is_position_behind(pts3[i]) else cam.unproject_position(pts3[i])
	return sp


## The dragged stream's centreline, re-curved from the waypoints as they move
## (null when the stream is drawn straight).
func _drag_path3(l: Dictionary) -> Variant:
	var f: Dictionary = l.get("curve", {})
	var sm := float(f.get("smooth", 0.0))
	var me := float(f.get("meander", 0.0))
	if StreamCurve.is_identity(sm, me):
		return null
	var probe := {"id": f.get("id", ""), "points": _drag["points"], "modes": _drag["modes"],
		"section": f.get("section", {}), "own_smooth": sm, "own_meander": me}
	StreamNetwork.curve_feature(probe, {})
	_drag["pseg"] = probe["ctrl_seg"]
	return _lift(probe["points"], loader())


## Screen centreline of a line + its per-span waypoint index (the waypoint
## polyline itself when the stream is straight).
func _screen_path(id: String) -> Array:
	if _proj_path.has(id):
		var l := _line(id)
		var pseg: Variant = _drag.get("pseg", null) if _drag.get("id", "") == id else l.get("pseg", null)
		if pseg is PackedInt32Array:
			return [_proj_path[id], pseg]
	return [_proj.get(id, PackedVector2Array()), null]


# ---------------------------------------------------------------------------
# Per-frame
# ---------------------------------------------------------------------------

func process(_delta: float) -> void:
	if tool.is_empty():
		return
	if _lines_dirty:
		_rebuild_lines()
	var mouse := _mouse if _mouse.x >= 0.0 else ui.get_viewport().get_mouse_position()
	# Idle gate (the other toolbar sections have had one since the legacy
	# dock): with nothing dragging and neither the pointer nor the camera
	# moved, the raycast, the per-vertex projection of every line in range,
	# the segment pick, the readout and the overlay redraw are all the same
	# as last frame.
	var cam := ui.get_viewport().get_camera_3d()
	var cam_xf: Transform3D = cam.global_transform if cam != null else Transform3D()
	var idle := _drag.is_empty() and _press.is_empty() and not _lines_dirty \
		and mouse.is_equal_approx(_last_proc_mouse) and cam_xf.is_equal_approx(_last_proc_cam)
	if idle:
		return
	_last_proc_mouse = mouse
	_last_proc_cam = cam_xf
	_cursor_world = ui.call("_pick_at", mouse)
	if not _drag.is_empty():
		_update_drag(mouse)
	elif not _press.is_empty() and mouse.distance_to(_press["px"]) > DRAG_PX:
		_begin_drag_from_press(mouse)
	_project_all()
	if _drag.is_empty():
		_hover = _pick(mouse)
	_update_readout()
	ui.call("_queue_overlay_redraw")


func _pick(mouse: Vector2) -> Dictionary:
	# Pins of the picked stream first — they are what the player drags.
	if not _picked.is_empty() and _proj.has(_picked) and (tool == "water_edit"):
		var sp: PackedVector2Array = _proj[_picked]
		var best := PIN_PICK_PX
		var bi := -1
		for i in sp.size():
			var d := sp[i].distance_to(mouse)
			if d < best:
				best = d
				bi = i
		if bi >= 0:
			return {"kind": "pin", "id": _picked, "index": bi}
	var best_d := LINE_PICK_PX
	var hit := {}
	for id in _proj.keys():
		# The line the player SEES is the curved centreline; a hit on it maps
		# back to the waypoint span it belongs to (what insert / span modes use).
		var sp_seg := _screen_path(str(id))
		var sp2: PackedVector2Array = sp_seg[0]
		var pseg: Variant = sp_seg[1]
		for i in range(sp2.size() - 1):
			if not is_finite(sp2[i].x) or not is_finite(sp2[i + 1].x):
				continue
			var q := Geometry2D.get_closest_point_to_segment(mouse, sp2[i], sp2[i + 1])
			var d := q.distance_to(mouse)
			# Prefer the picked stream and real streams over derived lines.
			if str(id).begins_with("dc_"):
				d += 2.0
			if d < best_d:
				best_d = d
				var span := i
				if pseg is PackedInt32Array and i < (pseg as PackedInt32Array).size():
					span = (pseg as PackedInt32Array)[i]
				hit = {"kind": "line", "id": str(id), "index": span}
	return hit


func _update_readout() -> void:
	var wn := network()
	if wn == null or not (_cursor_world is Vector3):
		return
	if not _drag.is_empty():
		return
	var id := str(_hover.get("id", _picked))
	if id.is_empty() or id.begins_with("dc_"):
		if id.begins_with("dc_"):
			var ch: Dictionary = wn.call("derived_channel", id)
			if not ch.is_empty():
				_status("Drainage line · order %d · catchment %.1f ha — Edit: click to pick, drag to promote" % [
					int(ch.get("order", 1)), float(ch.get("area_m2", 0.0)) / 10000.0])
		return
	var c: Vector3 = _cursor_world
	var st: Dictionary = wn.call("state_near", id, Vector2(c.x, c.z))
	if st.is_empty():
		return
	var f: Dictionary = wn.call("feature", id)
	var msg := "%s · Q %s · depth %.2f m · %.2f m/s" % [
		str(f.get("name", id)), _fmt_q(float(st.get("q_lps", 0.0))),
		float(st.get("depth_m", 0.0)), float(st.get("velocity_ms", 0.0))]
	if st.has("run"):
		var run: Dictionary = st["run"]
		msg += " · %s ⌀%.2f m, holds %s" % [str(run["mode"]), float(run["d"]),
			_fmt_q(float(run["capacity_lps"]))]
		if bool(run.get("surcharged", false)):
			msg += " · ⚠ SURCHARGED — needs a bigger barrel"
		if float(run.get("min_cover_m", 1.0)) < BuriedWaterBuilder.MIN_COVER_M:
			msg += " · ⚠ shallow cover"
	elif bool(st.get("blocked", false)):
		msg += " · ⚠ runs uphill here — carve deeper or make it a culvert"
	_status(msg)


static func _fmt_q(lps: float) -> String:
	if lps >= 1000.0:
		return "%.2f m³/s" % (lps / 1000.0)
	return "%.0f L/s" % lps


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

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
		return false   # the toolbar's own undo routes to undo() below
	if tool == "water_draw":
		if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
			_finish_draw()
			return true
		if key.keycode == KEY_BACKSPACE and not _draw_pts.is_empty():
			_draw_pts.remove_at(_draw_pts.size() - 1)
			_status("Draw: %s" % UiText.count(_draw_pts.size(), "point"))
			return true
	if tool == "water_edit" and (key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE):
		if str(_hover.get("kind", "")) == "pin" and str(_hover.get("id", "")) == _picked:
			_remove_pin(_picked, int(_hover["index"]))
			return true
		if not _picked.is_empty():
			_delete_picked()
			return true
	return false


func _on_press(mb: InputEventMouseButton) -> void:
	var mouse := mb.position
	match tool:
		"water_trace":
			_trace_at_cursor()
		"water_draw":
			var now := Time.get_ticks_msec()
			if now - _last_click_ms < DOUBLE_CLICK_MS and _draw_pts.size() >= 2:
				_finish_draw()
				_last_click_ms = 0
				return
			_last_click_ms = now
			if _cursor_world is Vector3:
				var c: Vector3 = _cursor_world
				_draw_pts.append(Vector2(c.x, c.z))
				_status("Draw: %s — Enter or double-click to finish, Backspace drops one" % UiText.count(_draw_pts.size(), "point"))
		"water_span":
			if str(_hover.get("kind", "")) == "line" and not str(_hover["id"]).begins_with("dc_") \
					and _span_mode == WaterFeatureLayer.MODE_PENSTOCK:
				_make_penstock_run(str(_hover["id"]), int(_hover["index"]))
			elif str(_hover.get("kind", "")) == "line" and not str(_hover["id"]).begins_with("dc_"):
				var wn := network()
				wn.call("checkpoint")
				var nid := str(wn.call("set_span_mode", str(_hover["id"]), int(_hover["index"]), _span_mode))
				wn.call("commit")
				_picked = nid
				_lines_dirty = true
				_status("Span %d → %s (re-carving…)" % [int(_hover["index"]) + 1, _span_mode])
				ui.call("_update_undo_button")
		"water_edit":
			_press = {"px": mouse, "hover": _hover.duplicate(), "ctrl": mb.ctrl_pressed}


## The Penstock span: the reach from vertex `seg` downstream becomes the
## penstock of the nearest PowerSpout (seated at the stream's end when there
## is none). Water-side: those spans go mode "penstock" (no channel, no
## barrel). Graph-side: an intake at the reach's head BOUND to this stream,
## a poly_penstock routed along the creek, the turbine fed by its flow.
func _make_penstock_run(id: String, seg: int) -> void:
	var wn := network()
	var gv: Node = ServiceLocator.graph()
	if wn == null or gv == null or not gv.has_method("tap_stream_for_turbine"):
		_status("Penstock needs the systems graph")
		return
	var ep: Dictionary = wn.call("editable_points", id)
	var pts: PackedVector2Array = ep.get("points", PackedVector2Array())
	if pts.size() < 2 or seg < 0 or seg >= pts.size() - 1:
		return
	# The turbine: the PowerSpout nearest any vertex downstream of the span.
	var turbine_id := ""
	var exit_i := pts.size() - 1
	var best := INF
	for i in range(seg + 1, pts.size()):
		var near: Array = gv.call("hydro_turbines_near", pts[i], PENSTOCK_TURBINE_REACH_M)
		if near.is_empty():
			continue
		var d := float((near[0] as Dictionary).get("dist", INF))
		if d < best:
			best = d
			exit_i = i
			turbine_id = str(((near[0] as Dictionary).get("item", {}) as Dictionary).get("id", ""))
	var seated := false
	if turbine_id.is_empty():
		var end := pts[pts.size() - 1]
		var dir := (end - pts[pts.size() - 2]).normalized()
		var side := Vector2(-dir.y, dir.x) * 3.0
		turbine_id = str(gv.call("place_powerspout_at", end + side))
		exit_i = pts.size() - 1
		seated = not turbine_id.is_empty()
		if turbine_id.is_empty():
			_status("Couldn't seat a PowerSpout at the stream's end")
			return
	if exit_i <= seg:
		_status("The turbine sits upstream of that span — pick a span above it")
		return
	# The ONE stream-tap routine (also behind the Site Plan drop, the 3D plug
	# drag and the Lab): marks the spans, places + binds the intake, routes.
	var conn := str(gv.call("tap_stream_for_turbine", id, seg, turbine_id, "res_in_0"))
	_picked = id
	_lines_dirty = true
	ui.call("_update_undo_button")
	var f: Dictionary = wn.call("feature", id)
	var fname := str(f.get("name", ""))
	if fname.is_empty():
		fname = str(f.get("kind", "stream")).capitalize()
	if conn.is_empty():
		_status("The graph could not route that reach")
		return
	var drop := 0.0
	var ld := loader()
	if ld != null and ld.has_method("ground_height_at"):
		drop = float(ld.call("ground_height_at", pts[seg].x, pts[seg].y)) \
			- float(ld.call("ground_height_at", pts[exit_i].x, pts[exit_i].y))
	_status("%s → penstock: %s, %.0f m of head%s. Open the Hydro Lab on the turbine to see it run." % [
		fname, UiText.count(exit_i - seg, "span"), maxf(drop, 0.0), " — PowerSpout seated at the stream's end" if seated else ""])


## Select a stream from outside (the crosshair's Interact on a creek).
func pick_feature(id: String) -> void:
	if id.is_empty():
		return
	_picked = id
	_lines_dirty = true
	if ui != null:
		ui.call("_rebuild_options_bar")
	var f: Dictionary = network().call("feature", id) if network() != null else {}
	_status("%s picked — drag pins to edit, or use the Culvert tool's Penstock chip to tap it for a turbine" % (
		str(f.get("name", "")) if not str(f.get("name", "")).is_empty() else "Stream"))


func _on_release() -> void:
	if not _drag.is_empty():
		_end_drag()
		_press = {}
		return
	if _press.is_empty():
		return
	# A click, not a drag: pick what was under the pointer.
	var h: Dictionary = _press["hover"]
	_press = {}
	var new_pick := str(h.get("id", ""))
	if new_pick != _picked:
		_picked = new_pick
		ui.call("_rebuild_options_bar")
	if _picked.is_empty():
		_status("Click a stream to edit it")


# ---------------------------------------------------------------------------
# Drag (Edit)
# ---------------------------------------------------------------------------

func _begin_drag_from_press(mouse: Vector2) -> void:
	var h: Dictionary = _press.get("hover", {})
	var ctrl := bool(_press.get("ctrl", false))
	_press = {}
	var id := str(h.get("id", ""))
	if id.is_empty():
		return
	var wn := network()
	var ep: Dictionary = wn.call("editable_points", id)
	if ep.is_empty():
		return
	var pts: PackedVector2Array = (ep["points"] as PackedVector2Array).duplicate()
	var modes: Array = (ep["modes"] as Array).duplicate()
	var index := -1
	if ctrl:
		index = -1
	elif str(h.get("kind", "")) == "pin":
		index = int(h["index"])
	elif str(h.get("kind", "")) == "line":
		# Dragging a line inserts a waypoint there and drags it.
		var c: Variant = ui.call("_pick_at", mouse)
		if not (c is Vector3):
			return
		var seg := int(h["index"])
		var r := WaterFeatureLayer.insert_point(pts, modes, seg, Vector2((c as Vector3).x, (c as Vector3).z))
		pts = r["points"]
		modes = r["modes"]
		index = seg + 1
	var start: Variant = ui.call("_pick_at", mouse)
	_drag = {"id": id, "index": index, "points": pts, "modes": modes,
		"orig": pts.duplicate(), "start": start}
	_picked = id


func _update_drag(mouse: Vector2) -> void:
	var c: Variant = ui.call("_pick_at", mouse)
	if not (c is Vector3):
		return
	var w := Vector2((c as Vector3).x, (c as Vector3).z)
	var index := int(_drag["index"])
	if index >= 0:
		var pts: PackedVector2Array = _drag["points"]
		pts[index] = w
		_drag["points"] = pts
	elif _drag["start"] is Vector3:
		var s: Vector3 = _drag["start"]
		var d := w - Vector2(s.x, s.z)
		var orig: PackedVector2Array = _drag["orig"]
		var moved := PackedVector2Array()
		for p in orig:
			moved.append(p + d)
		_drag["points"] = moved
	_status("Dragging — release to commit (Esc cancels)")


func _end_drag() -> void:
	var wn := network()
	if wn == null or _drag.is_empty():
		_drag = {}
		return
	wn.call("checkpoint")
	var nid := str(wn.call("apply_points", str(_drag["id"]), _drag["points"], _drag["modes"]))
	wn.call("commit")
	var was := str(_drag["id"])
	_drag = {}
	_lines_dirty = true
	if nid != _picked or was.begins_with("dc_"):
		_picked = nid
		ui.call("_rebuild_options_bar")
	_status("Moved — re-carving the channel…")
	ui.call("_update_undo_button")


func _remove_pin(id: String, index: int) -> void:
	var wn := network()
	var ep: Dictionary = wn.call("editable_points", id)
	if ep.is_empty() or (ep["points"] as PackedVector2Array).size() <= WaterFeatureLayer.MIN_POINTS:
		_status("A stream needs at least two waypoints")
		return
	var r := WaterFeatureLayer.remove_point(ep["points"], ep["modes"], index)
	wn.call("checkpoint")
	_picked = str(wn.call("apply_points", id, r["points"], r["modes"]))
	wn.call("commit")
	_hover = {}
	_lines_dirty = true
	_status("Waypoint removed")
	ui.call("_update_undo_button")


func cancel_drag() -> bool:
	if _drag.is_empty() and _press.is_empty():
		return false
	_drag = {}
	_press = {}
	_lines_dirty = true
	_status("Cancelled")
	return true


# ---------------------------------------------------------------------------
# Trace / Draw
# ---------------------------------------------------------------------------

func _trace_at_cursor() -> void:
	var wn := network()
	if wn == null or not (_cursor_world is Vector3):
		_status("Aim at the terrain")
		return
	if (wn.call("drainage") as Dictionary).is_empty():
		wn.call("request_drainage")
		_status("Still analysing drainage — try again in a moment")
		return
	var c: Vector3 = _cursor_world
	var path: PackedVector2Array = wn.call("trace_from", Vector2(c.x, c.z))
	if path.size() < 2:
		_status("Water runs straight off the map edge here")
		return
	wn.call("checkpoint")
	var r: Dictionary = wn.call("add_user_stream", path, "stream")
	wn.call("commit")
	_picked = str(r["id"])
	_lines_dirty = true
	var ld := loader()
	var drop := float(ld.call("ground_height_at", path[0].x, path[0].y)) \
		- float(ld.call("ground_height_at", path[path.size() - 1].x, path[path.size() - 1].y))
	_status("Traced %.0f m, falls %.1f m — Edit to reshape it" % [
		StreamNetwork.polyline_length(path), drop])
	ui.call("_update_undo_button")


func _finish_draw() -> void:
	if _draw_pts.size() < 2:
		_status("Draw at least two points")
		return
	var wn := network()
	wn.call("checkpoint")
	var r: Dictionary = wn.call("add_user_stream", _draw_pts, _draw_kind)
	wn.call("commit")
	_picked = str(r["id"])
	_draw_pts = PackedVector2Array()
	_lines_dirty = true
	_status("Stream added%s — carving…" % (" (reversed to run downhill)" if bool(r["reversed"]) else ""))
	ui.call("_update_undo_button")


# ---------------------------------------------------------------------------
# Picked-stream actions
# ---------------------------------------------------------------------------

func _delete_picked() -> void:
	var wn := network()
	if wn == null or _picked.is_empty():
		return
	var src := str(WaterNetwork.source_of(_picked))
	wn.call("checkpoint")
	wn.call("delete_feature", _picked)
	wn.call("commit")
	_status("Hidden the mapped waterway (Revert brings it back)" if src == "osm" else "Stream deleted")
	_picked = ""
	_lines_dirty = true
	ui.call("_rebuild_options_bar")
	ui.call("_update_undo_button")


func _action(what: String) -> void:
	var wn := network()
	if wn == null or _picked.is_empty():
		return
	wn.call("checkpoint")
	match what:
		"reverse":
			_picked = str(wn.call("reverse_feature", _picked))
			_status("Reversed")
		"promote":
			_picked = str(wn.call("promote_derived", _picked))
			_status("Promoted to a stream — it will be carved")
		"revert":
			wn.call("revert_osm", _picked)
			_status("Reverted to the OSM data")
		"delete":
			_delete_picked()
			return
	wn.call("commit")
	_lines_dirty = true
	ui.call("_rebuild_options_bar")
	ui.call("_update_undo_button")


## Slider / field edits debounce into ONE checkpointed patch.
func _queue_patch(patch: Dictionary) -> void:
	for k in patch.keys():
		if k == "section":
			var sec: Dictionary = _pending_patch.get("section", {})
			for sk in (patch["section"] as Dictionary).keys():
				sec[sk] = patch["section"][sk]
			_pending_patch["section"] = sec
		else:
			_pending_patch[k] = patch[k]
	_apply_timer.start()


func _flush_patch() -> void:
	if _pending_patch.is_empty() or _picked.is_empty():
		_pending_patch = {}
		return
	var wn := network()
	if wn == null:
		return
	if WaterNetwork.source_of(_picked) == "derived":
		wn.call("checkpoint")
		_picked = str(wn.call("promote_derived", _picked))
	else:
		wn.call("checkpoint")
	# Merge a partial section edit over the stream's current section.
	if _pending_patch.has("section"):
		var f: Dictionary = wn.call("feature", _picked)
		var cur: Dictionary = (f.get("section", {}) as Dictionary).duplicate()
		for k in (_pending_patch["section"] as Dictionary).keys():
			cur[k] = _pending_patch["section"][k]
		_pending_patch["section"] = cur
	wn.call("set_feature_fields", _picked, _pending_patch)
	wn.call("commit")
	_pending_patch = {}
	_status("Updated — re-carving…")
	ui.call("_update_undo_button")


# ---------------------------------------------------------------------------
# Options rows
# ---------------------------------------------------------------------------

func build_rows(box: Container) -> void:
	_rows = {}
	var wn := network()
	if wn == null:
		var l := Label.new()
		l.text = "Water tools need a generated map"
		box.add_child(l)
		return
	match tool:
		"water_draw":
			_kind_chips(box, _draw_kind, func(k: String) -> void:
				_draw_kind = k
				ui.call("_rebuild_options_bar"))
		"water_span":
			for m in WaterFeatureLayer.MODES:
				var tip := "Click a span to make it: %s" % m
				if m == WaterFeatureLayer.MODE_PENSTOCK:
					tip = ("Click a span: from there DOWN to your PowerSpout the stream becomes its "
						+ "penstock (intake at the span's upstream end, pipe along the creek, "
						+ "turbine fed by this stream's flow). No turbine within %.0f m: one is seated "
						+ "at the stream's end.") % PENSTOCK_TURBINE_REACH_M
				var b := _chip(box, {"surface": "Open", "culvert": "Culvert", "pipe": "Pipe",
					"penstock": "Penstock"}[m], m == _span_mode, tip)
				b.pressed.connect(func() -> void:
					_span_mode = m
					ui.call("_rebuild_options_bar"))
		"water_view":
			_build_view_rows(box, wn)
		"water_edit":
			_build_edit_rows(box, wn)


func _build_edit_rows(box: Container, wn: Node) -> void:
	if _picked.is_empty():
		var l := Label.new()
		l.text = "Click a stream · drag waypoints · drag a line to add one · Del removes"
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		box.add_child(l)
		return
	var src := WaterNetwork.source_of(_picked)
	if src == "derived":
		var b := _chip(box, "Promote to stream", false, "Make this drainage line a stream (it will be carved)")
		b.pressed.connect(_action.bind("promote"))
		return
	var f: Dictionary = wn.call("feature", _picked)
	var name_edit := LineEdit.new()
	name_edit.text = str(f.get("name", ""))
	name_edit.custom_minimum_size = Vector2(110, 0)
	name_edit.text_submitted.connect(func(t: String) -> void: _queue_patch({"name": t}))
	box.add_child(name_edit)
	if src == "user":
		_kind_chips(box, str(f.get("kind", "stream")), func(k: String) -> void:
			_queue_patch({"kind": k}))
	var sec: Dictionary = f.get("section", {})
	for spec in [["bed_w", "Bed width", 0.3, 40.0, 0.1, "m"], ["depth", "Depth", 0.1, 5.0, 0.05, "m"],
			["bank_slope", "Bank slope 1:", 0.5, 6.0, 0.1, ""]]:
		var key: String = spec[0]
		var pair := SliderSpinRow.add_param(box, String(spec[1]), float(spec[2]), float(spec[3]),
			float(sec.get(key, 1.0)), float(spec[4]), String(spec[5]),
			func(v: float) -> void: _queue_patch({"section": {key: v}}))
		_rows[key] = pair
	SliderSpinRow.add_param(box, "Base flow", 0.0, 20000.0, float(f.get("base_lps", 25.0)), 1.0, "L/s",
		func(v: float) -> void: _queue_patch({"base_lps": v}), NAN, 92, 76)
	# This stream's curve: its own values, or the map's (View tool) until set.
	var own := bool(f.get("curve_own", false))
	SliderSpinRow.add_param(box, "Smoothing", 0.0, 100.0, float(f.get("smooth", 0.0)) * 100.0, 1.0, "%",
		func(v: float) -> void: _queue_patch({"smooth": v / 100.0}), NAN, 92, 64)
	SliderSpinRow.add_param(box, "Meander", 0.0, 100.0, float(f.get("meander", 0.0)) * 100.0, 1.0, "%",
		func(v: float) -> void: _queue_patch({"meander": v / 100.0}), NAN, 92, 64)
	if own:
		_chip(box, "Use map curve", false,
			"Drop this stream's own smoothing / meander and follow the map's (View tool)").pressed.connect(
			func() -> void:
				_queue_patch({"smooth": null, "meander": null})
				_flush_patch()
				ui.call("_rebuild_options_bar"))
	var carve := CheckBox.new()
	carve.text = "Carve"
	carve.button_pressed = bool(f.get("carve", true))
	carve.focus_mode = Control.FOCUS_NONE
	carve.toggled.connect(func(on: bool) -> void: _queue_patch({"carve": on}))
	box.add_child(carve)
	_chip(box, "Reverse", false, "Flip which way it flows").pressed.connect(_action.bind("reverse"))
	if src == "osm" and bool(f.get("overridden", false)):
		_chip(box, "Revert", false, "Drop your edits and use the OSM data").pressed.connect(_action.bind("revert"))
	_chip(box, "Hide" if src == "osm" else "Delete", false,
		"Hide this mapped waterway" if src == "osm" else "Delete this stream").pressed.connect(_action.bind("delete"))


func _build_view_rows(box: Container, wn: Node) -> void:
	var lay: WaterFeatureLayer = wn.get("layer")
	var cur := str(lay.setting("display_mode"))
	for m in [["off", "Off"], ["osm", "Mapped"], ["all", "All streams"], ["flow", "Flow view"]]:
		var b := _chip(box, String(m[1]), cur == String(m[0]), "Water display: %s" % m[1])
		var mode: String = m[0]
		b.pressed.connect(func() -> void:
			wn.call("set_display_mode", mode)
			ui.call("_rebuild_options_bar"))
	var dr := CheckBox.new()
	dr.text = "Drainage"
	dr.tooltip_text = "Draw the derived drainage network on the ground"
	dr.button_pressed = bool(lay.setting("show_drainage"))
	dr.focus_mode = Control.FOCUS_NONE
	dr.toggled.connect(func(on: bool) -> void: wn.call("set_show_drainage", on))
	box.add_child(dr)
	SliderSpinRow.add_param(box, "Min catchment", 0.1, 100.0, float(lay.setting("min_catchment_ha")),
		0.1, "ha", func(v: float) -> void: wn.call("set_min_catchment_ha", v))
	# Map-wide curve for every stream without its own (Edit sets one stream).
	var cd := StreamNetwork.curve_defaults(lay.settings)
	var sm_row: Array = []
	var me_row: Array = []
	var push := func() -> void:
		if sm_row.is_empty() or me_row.is_empty():
			return
		wn.call("set_curve_defaults", float((sm_row[0] as Range).value) / 100.0,
			float((me_row[0] as Range).value) / 100.0)
		_status("Re-curving the streams…")
	var sm_pair: Variant = SliderSpinRow.add_param(box, "Smoothing", 0.0, 100.0, cd.x * 100.0, 1.0, "%",
		func(_v: float) -> void: push.call(), NAN, 92, 64)
	var me_pair: Variant = SliderSpinRow.add_param(box, "Meander", 0.0, 100.0, cd.y * 100.0, 1.0, "%",
		func(_v: float) -> void: push.call(), NAN, 92, 64)
	sm_row.append(_range_of(sm_pair))
	me_row.append(_range_of(me_pair))
	var cv := CheckBox.new()
	cv.text = "Carve channels"
	cv.tooltip_text = "Cut mapped and drawn streams into the hi-res terrain"
	cv.button_pressed = bool(lay.setting("carve_enabled"))
	cv.focus_mode = Control.FOCUS_NONE
	cv.toggled.connect(func(on: bool) -> void: wn.call("set_carve_enabled", on))
	box.add_child(cv)
	var dry := CheckBox.new()
	dry.text = "Dry between storms"
	dry.tooltip_text = ("Streams without a base flow of their own carry nothing until rain "
		+ "reaches them (a desert wash). Rain — the weather's, or the Terrain Rain tool "
		+ "held over open ground — fills them from the top down as it runs off.")
	dry.button_pressed = bool(lay.setting("dry_between_storms"))
	dry.focus_mode = Control.FOCUS_NONE
	dry.toggled.connect(func(on: bool) -> void: wn.call("set_dry_between_storms", on))
	box.add_child(dry)
	var bu := CheckBox.new()
	bu.text = "Show buried"
	bu.tooltip_text = "Show culverts and pipes through the ground"
	bu.button_pressed = bool(lay.setting("show_buried"))
	bu.focus_mode = Control.FOCUS_NONE
	bu.toggled.connect(func(on: bool) -> void: wn.call("set_show_buried", on))
	box.add_child(bu)
	_chip(box, "Reset erosion", false,
		"Fill back what floods have cut into the channel beds (big storms deepen them)").pressed.connect(
		func() -> void:
			wn.call("reset_erosion")
			_status("Erosion reset — re-carving the channels…"))
	_chip(box, "Re-carve", false, "Recompute every channel from scratch").pressed.connect(
		func() -> void:
			wn.call("invalidate_cache")
			wn.call("request_rebuild", true)
			_status("Re-carving every channel…"))


## The value Range of a SliderSpinRow.add_param result.
static func _range_of(pair: Variant) -> Range:
	if pair is Range:
		return pair
	if pair is Array:
		for x in (pair as Array):
			if x is Range:
				return x
	if pair is Dictionary:
		for x in (pair as Dictionary).values():
			if x is Range:
				return x
	return null


func _kind_chips(box: Container, current: String, on_pick: Callable) -> void:
	for k in KIND_CHOICES:
		var b := _chip(box, String(k).capitalize(), k == current, "Kind: %s (sets the default cross-section)" % k)
		b.pressed.connect(func() -> void: on_pick.call(k))


func _chip(box: Container, text: String, on: bool, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_toggle(b, on, UITheme.FONT_XS)
	box.add_child(b)
	return b


# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

func draw(canvas: Control) -> void:
	if tool.is_empty():
		return
	var wn := network()
	for id in _proj.keys():
		var sp_seg := _screen_path(str(id))
		var sp: PackedVector2Array = sp_seg[0]
		var pseg: Variant = sp_seg[1]
		var l := _line(str(id))
		if l.is_empty():
			continue
		var src := str(l["source"])
		var base := COL_DERIVED if src == "derived" else (COL_USER if src == "user" else COL_OSM)
		var w := 1.5 if src == "derived" else 2.5
		if str(id) == _picked:
			w = 4.0
		var modes: Array = l["modes"]
		if _drag.get("id", "") == id:
			modes = _drag["modes"]
		var hovered := str(_hover.get("id", "")) == str(id) and str(_hover.get("kind", "")) == "line"
		for i in range(sp.size() - 1):
			if not is_finite(sp[i].x) or not is_finite(sp[i + 1].x):
				continue
			var col := base
			var span := i
			if pseg is PackedInt32Array and i < (pseg as PackedInt32Array).size():
				span = (pseg as PackedInt32Array)[i]
			if span < modes.size():
				if str(modes[span]) == "culvert":
					col = COL_CULVERT
				elif str(modes[span]) == "pipe":
					col = COL_PIPE
				elif str(modes[span]) == WaterFeatureLayer.MODE_PENSTOCK:
					col = COL_PENSTOCK
			if str(id) == _picked:
				col = col.lerp(COL_PICK, 0.35)
			if hovered and int(_hover.get("index", -1)) == span and tool == "water_span":
				col = COL_PICK
			canvas.draw_line(sp[i], sp[i + 1], col, w + (1.5 if hovered else 0.0), true)
		# Direction ticks on real streams: a chevron every few vertices.
		if src != "derived":
			for i in range(1, sp.size(), 4 if pseg == null else 24):
				if not is_finite(sp[i].x) or not is_finite(sp[i - 1].x):
					continue
				var d := (sp[i] - sp[i - 1])
				if d.length() < 8.0:
					continue
				d = d.normalized()
				var m := (sp[i] + sp[i - 1]) * 0.5
				var nrm := Vector2(-d.y, d.x)
				canvas.draw_line(m, m - d * 7.0 + nrm * 5.0, base, 1.5, true)
				canvas.draw_line(m, m - d * 7.0 - nrm * 5.0, base, 1.5, true)
	# Picked stream: waypoints + the stations flagged as running uphill.
	if not _picked.is_empty() and _proj.has(_picked) and tool == "water_edit":
		var sp2: PackedVector2Array = _proj[_picked]
		if _proj_path.has(_picked):
			for i in range(sp2.size() - 1):
				if is_finite(sp2[i].x) and is_finite(sp2[i + 1].x):
					canvas.draw_dashed_line(sp2[i], sp2[i + 1], Color(1, 1, 1, 0.35), 1.0, 6.0)
		for i in sp2.size():
			if not is_finite(sp2[i].x):
				continue
			var hot := str(_hover.get("kind", "")) == "pin" and int(_hover.get("index", -1)) == i
			canvas.draw_circle(sp2[i], 6.5 if hot else 5.0, COL_PICK if hot else Color(1, 1, 1, 0.95))
			canvas.draw_circle(sp2[i], 3.0, Color(0.1, 0.25, 0.4, 1.0))
		if wn != null:
			_draw_blocked(canvas, wn)
	if tool == "water_draw" and not _draw_pts.is_empty():
		var pts := _draw_pts.duplicate()
		if _cursor_world is Vector3:
			var c: Vector3 = _cursor_world
			pts.append(Vector2(c.x, c.z))
		var sp3 := _project_world(pts)
		if sp3.size() >= 2:
			canvas.draw_polyline(sp3, COL_USER, 2.5, true)
		for p in sp3:
			canvas.draw_circle(p, 4.0, COL_USER)


func _draw_blocked(canvas: Control, wn: Node) -> void:
	var prof: Dictionary = wn.call("profile", _picked)
	var blocked: PackedByteArray = prof.get("blocked", PackedByteArray())
	var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
	var flagged := PackedVector2Array()
	for i in range(0, pts.size(), 2):
		if i < blocked.size() and blocked[i] == 1:
			flagged.append(pts[i])
	for p in _project_world(flagged):
		canvas.draw_circle(p, 3.5, COL_BLOCKED)


func _project_world(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cam := ui.get_viewport().get_camera_3d()
	var ld := loader()
	if cam == null or ld == null:
		return out
	for p in pts:
		var wp := Vector3(p.x, float(ld.call("ground_height_at", p.x, p.y)) + 0.3, p.y)
		if not cam.is_position_behind(wp):
			out.append(cam.unproject_position(wp))
	return out


# ---------------------------------------------------------------------------
# Esc / undo
# ---------------------------------------------------------------------------

## One layer per Esc: a drag, then a draw in progress, then the pick.
func escape() -> bool:
	if cancel_drag():
		return true
	if not _draw_pts.is_empty():
		_draw_pts = PackedVector2Array()
		_status("Cancelled")
		return true
	if not _picked.is_empty():
		_picked = ""
		ui.call("_rebuild_options_bar")
		return true
	return false


func can_undo() -> bool:
	var wn := network()
	return wn != null and bool(wn.call("can_undo"))


func undo() -> bool:
	var wn := network()
	if wn == null or not bool(wn.call("undo")):
		return false
	_lines_dirty = true
	return true
