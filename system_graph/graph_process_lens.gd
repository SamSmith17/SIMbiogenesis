extends Control

## The Process lens (plans/SCADA_PROCESS_PLAN.md, Phase 3): the current
## graph scope as a process picture. A full-rect child of the graph canvas,
## shown only in GraphSiteLayout.VIEW_PROCESS. It owns a MimicCanvas (the
## same one the Process Lab's P&ID uses) fed by MimicGraphSource, and a
## faceplate. The graph canvas keeps drawing only its background under it.
##
##   setup(canvas, view)        the GraphCanvas and the SystemGraphView
##   set_active(on)             shown / hidden with the lens
##   refresh(force)             rebuild the picture if the scope changed
##   pins_data() / set_pins_data(d)     the player's drags, per scope (saved)
##
## What a click does: select the node / wire in the graph (so the inspector
## follows); on a machine, valve or pump open its faceplate (switch it); on
## a store, its faceplate carries its own inlet / outlet valves. Double-click
## a group goes inside; double-click anything else is the graph's own
## double-click (a reactor opens its process view).
##
## It never writes a node's x / y. Commands go through the tag hub (so they
## count as the operator's edit) or straight onto the item for a store's
## valves.

const MimicScript := preload("res://scenes/ui/scada/mimic_canvas.gd")
const FaceScript := preload("res://scenes/ui/scada/faceplate.gd")
const STATE_S := 0.25
const PALETTE_CLEAR := 62.0
const EMPTY_PICTURE := "Nothing is piped in this part of the graph yet.\nWire a store to a machine, or drop a valve or pump from the library (Valves & Pumps) between two stores."
const EMPTY_BOARD := "This screen is empty.\nPick a gauge, a trend or a button from Widgets (bottom bar) and click here to set it down."

var mimic: Control = null
var _canvas: Control = null
var _view: Node = null
var _face: PanelContainer = null
var _face_id := ""
var _empty: Label = null
var _doc: Dictionary = {}
var _key := ""
var _acc := 0.0
var _active := false
## scope id → {element id: Vector2}
var _pins: Dictionary = {}
## Which way the picture reads: MimicGraphSource.FLOW_RIGHT (left to right)
## or FLOW_DOWN (top to bottom). Moved things are kept apart for each.
var _flow_dir := MimicGraphSource.FLOW_RIGHT
var _flow_opt: OptionButton = null
var _last_scope := "?"
## Which kinds of line the picture shows.
var _layers: Dictionary = {MimicGraphSource.LAYER_PIPES: true}
## How equipment is drawn: a picture of its model from this view
## (MimicIcons.VIEWS) or "boxes"; `_icon_over` = a node's own choice.
var _icon_view := MimicIcons.VIEW_SIDE
var _icon_over: Dictionary = {}
var _icon_opt: OptionButton = null
## Placed prop id -> [model id, build extras] (cleared when the graph changes).
var _prop_models: Dictionary = {}
var _prop_models_rev := -1
var _icon_sig := ""
## Node id -> the picture last drawn for it: kept on screen while a new
## view is being drawn, so switching views never flashes boxes.
var _last_pic: Dictionary = {}
var _layer_btns: Dictionary = {}
## What the placed boards measure here (ScadaHub.esp_instruments).
var _instruments: Array = []


func setup(canvas: Control, view: Node) -> void:
	_canvas = canvas
	_view = view
	name = "ProcessLens"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = false
	mimic = Control.new()
	mimic.set_script(MimicScript)
	mimic.name = "ProcessMimic"
	mimic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The palette stands along the bottom: the picture fits above it.
	mimic.offset_bottom = -PALETTE_CLEAR
	add_child(mimic)
	mimic.connect("element_clicked", _on_element)
	mimic.connect("element_activated", _on_activated)
	mimic.connect("pipe_clicked", _on_pipe)
	mimic.connect("empty_clicked", _on_empty)
	mimic.connect("element_moved", _on_moved)
	mimic.connect("place_requested", _on_place)
	mimic.connect("link_requested", _on_link)
	mimic.connect("bend_moved", _on_bend_moved)
	mimic.connect("bend_removed", _on_bend_removed)
	_build_palette()
	_build_alarm_bar()
	_build_armed_bar()
	_build_screen_bar()
	_empty = Label.new()
	_empty.name = "empty_note"
	_empty.text = EMPTY_PICTURE
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_empty.custom_minimum_size = Vector2(520, 0)
	_empty.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.visible = false
	add_child(_empty)
	_empty.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	set_process(false)


func set_active(on: bool) -> void:
	_active = on
	visible = on
	set_process(on)
	if on:
		refresh(true)
	else:
		_hide_face()


func is_active() -> bool:
	return _active


func _scope() -> String:
	return str(_canvas.get("active_scope_id")) if _canvas != null else "root"


func _items() -> Array:
	return _canvas.call("_compute_visible_items") if _canvas != null else []


func _conns() -> Array:
	return _canvas.call("_compute_visible_connections") if _canvas != null else []


## Rebuild the picture when the scope or its topology changed.
func refresh(force: bool = false) -> void:
	if _canvas == null or mimic == null:
		return
	var model: Object = _canvas.get("model")
	if model == null:
		return
	var scope := _scope()
	var items := _items()
	var conns := _conns()
	var hub0: Node = _view.call("scada_hub") if _view != null and _view.has_method("scada_hub") else null
	_instruments = hub0.call("esp_instruments") if hub0 != null and hub0.has_method("esp_instruments") else []
	if hub0 != null and hub0.has_method("logic_blocks"):
		_instruments.append_array(MimicGraphSource.logic_instruments(hub0.call("logic_blocks"), hub0.call("logic_status")))
	var ins_sig := PackedStringArray()
	for ins in _instruments:
		ins_sig.append("%s>%s" % [str(ins["id"]), str(ins["item"])])
	var scr := _cur_screen()
	var pics := _icon_maps(items, int(model.get("struct_rev")))
	var world := _world_of(items, conns) if _built else {}
	var key := "%s|%d|%d|%d|%s|%s|%s|%d|%s|%s|%s" % [scope, int(model.get("struct_rev")), items.size(), conns.size(), str(_layers), ",".join(ins_sig), str(scr.get("id", "")), _wrev, _icon_sig,
		str(world.get("sig", "schematic")), _flow_dir]
	if force or key != _key:
		_key = key
		var base := MimicGraphSource.build(items, conns, _layers, _instruments, {"aspect": pics[2], "flow": _flow_dir})
		if _built:
			base = MimicWorldSource.build(base, world["positions"] as Dictionary, world["runs"] as Dictionary,
				world["editable"])
		_doc = _doc_with_widgets(base, scr)
		mimic.set("built", _built)
		mimic.call("set_doc", _doc, false)
		mimic.call("set_pins", {} if _built else _pins.get(_pin_scope(), {}))
		mimic.call("set_icons", pics[0], pics[1])
		_empty.visible = (_doc.get("elements", []) as Array).is_empty()
		_empty.text = EMPTY_PICTURE if bool(scr.get("picture", true)) else EMPTY_BOARD
		_hide_face()
		if scope != _last_scope or _built_fit:
			_last_scope = scope
			_built_fit = false
			var sel_id := str(mimic.get("selected_id"))
			if _built and not sel_id.is_empty():
				mimic.call_deferred("fit_pipe", sel_id)
			else:
				mimic.call_deferred("fit")
	var net := {}
	if bool(_layers.get(MimicGraphSource.LAYER_DATA, false)):
		var hub: Node = _view.call("scada_hub") if _view != null and _view.has_method("scada_hub") else null
		if hub != null:
			net = hub.call("net_reach")
	var mst: Dictionary = MimicGraphSource.state(items, conns, net, _instruments)
	if hub0 != null and hub0.has_method("alarm_items"):
		mst["alarm"] = hub0.call("alarm_items")
	mst["w"] = _widget_states(scr)
	mimic.call("set_state", mst)
	_refresh_alarm_bar(hub0)
	_refresh_armed_bar(hub0)
	_refresh_screen_bar()
	_refresh_checks(items, conns)
	_refresh_face()


func _process(delta: float) -> void:
	if not _active or not is_visible_in_tree():
		return
	_acc += delta
	if _acc >= STATE_S:
		_acc = 0.0
		refresh()
	var moving := true
	var rate := 60.0
	var main: Node = _view.call("_get_scene_main_node") if _view != null and _view.has_method("_get_scene_main_node") else null
	if main != null:
		var ts := float(main.get("time_scale"))
		moving = ts > 0.0
		rate = ts * 3600.0
	mimic.call("tick", delta, moving, rate)
	if _face != null and _face.visible and not _face_id.is_empty():
		var e: Dictionary = mimic.call("element_by_id", _face_id)
		if not e.is_empty():
			_face.call("place", mimic.global_position + (mimic.call("element_rect", e) as Rect2).get_center())


func fit() -> void:
	if mimic != null:
		mimic.call("fit")


# ── pins (saved with the graph) ─────────────────────────────────────────────

func pins_data() -> Dictionary:
	var out := {}
	for scope in _pins:
		var d := {}
		for id in (_pins[scope] as Dictionary):
			var v: Vector2 = _pins[scope][id]
			d[str(id)] = [snappedf(v.x, 0.1), snappedf(v.y, 0.1)]
		if not d.is_empty():
			out[str(scope)] = d
	return out


func set_pins_data(data: Variant) -> void:
	_pins = {}
	if data is Dictionary:
		for scope in data:
			if not (data[scope] is Dictionary):
				continue
			var d := {}
			for id in data[scope]:
				var a: Variant = data[scope][id]
				if a is Array and (a as Array).size() >= 2:
					d[str(id)] = Vector2(float(a[0]), float(a[1]))
			_pins[str(scope)] = d
	_key = ""
	if _active:
		refresh(true)


func _on_moved(id: String, off: Vector2) -> void:
	if _operator or _built:
		refresh(true)   # locked: it goes back where it was
		return
	if MimicWidgets.is_widget_id(id):
		var w := widget(MimicWidgets.widget_id(id))
		if not w.is_empty() and off.length() >= 0.5:
			w["x"] = float(w["x"]) + off.x
			w["y"] = float(w["y"]) + off.y
		_touch()
		return
	var scope := _pin_scope()
	var d: Dictionary = _pins.get(scope, {})
	if off.length() < 0.5:
		d.erase(id)
	else:
		d[id] = off
	_pins[scope] = d
	if _view != null and _view.has_method("_mark_dirty_for_autosave"):
		_view.call("_mark_dirty_for_autosave")


## Put everything in this scope back where the layout has it.
func reset_layout() -> void:
	_pins.erase(_pin_scope())
	if mimic != null:
		mimic.call("set_pins", {})
		mimic.call("fit")
	if _view != null and _view.has_method("_mark_dirty_for_autosave"):
		_view.call("_mark_dirty_for_autosave")


# ── clicks ──────────────────────────────────────────────────────────────────

func _item(id: String) -> Dictionary:
	var model: Object = _canvas.get("model") if _canvas != null else null
	return model.call("get_item", id) if model != null else {}


func _on_element(e: Dictionary) -> void:
	var id := str(e["id"])
	if MimicWidgets.is_widget_id(id):
		_on_widget(e)
		return
	if _canvas != null and _canvas.has_method("_select_item") and not id.begins_with("ins:"):
		_canvas.call("_select_item", id)
	var fp := _faceplate_for(id)
	if fp.is_empty():
		_hide_face()
		return
	if _face == null:
		_face = PanelContainer.new()
		_face.set_script(FaceScript)
		_face.name = "ProcessFaceplate"
		add_child(_face)
		_face.connect("dismissed", func() -> void: _face_id = "")
	_face_id = id
	_face.call("show_for", fp, mimic.global_position + (mimic.call("element_rect", e) as Rect2).get_center())


func _on_activated(e: Dictionary) -> void:
	var id := str(e["id"])
	if MimicWidgets.is_widget_id(id):
		return
	_hide_face()
	if id.begins_with("ins:"):
		# An instrument: go to the board that reads it.
		var board := str(e.get("board", ""))
		if not board.is_empty():
			_canvas.emit_signal("item_double_tapped", board)
		return
	if str(e.get("kind", "")) == "group":
		_canvas.emit_signal("compound_open_requested", id)
	else:
		_canvas.emit_signal("item_double_tapped", id)


func _on_pipe(p: Dictionary) -> void:
	_hide_face()
	if str(p["id"]).begins_with("sig:"):
		return
	select_pipe(str(p["id"]))


# ── As built: the picture from the world ────────────────────────────────────

const BUILT_TOKEN := "@built"
var _built := false
var _built_btn: Button = null
var _built_fit := false


func built() -> bool:
	return _built


## Schematic (false) or As built (true).
func set_built(on: bool) -> void:
	if on == _built:
		return
	_built = on
	if _built_btn != null:
		_built_btn.set_pressed_no_signal(on)
	_built_fit = true
	_hide_face()
	_key = ""
	if _view != null and _view.has_method("_mark_dirty_for_autosave"):
		_view.call("_mark_dirty_for_autosave")
	if _active:
		refresh(true)


## Where every placed thing in the scope is, and every drawn run's corners.
## {positions, runs, sig}; `sig` moves when either does (so the picture is
## rebuilt as runs are re-routed or things are moved).
func _world_of(items: Array, conns: Array) -> Dictionary:
	var model: Object = _canvas.get("model") if _canvas != null else null
	var mgr: Node = _view.call("_get_conduit_manager") if _view != null and _view.has_method("_get_conduit_manager") else null
	var positions := {}
	var runs := {}
	var editable := {}
	var parts := PackedStringArray()
	for it in items:
		if not (it is Dictionary) or model == null:
			continue
		var d: Dictionary = it
		if not bool(model.call("item_has_3d_anchor", d)):
			continue
		var w: Vector3 = _canvas.call("_phys_item_world_center", d)
		if not is_finite(w.x):
			continue
		if mgr != null and mgr.has_method("ground_y_at"):
			w.y = float(mgr.call("ground_y_at", w))
		positions[str(d["id"])] = w
		parts.append("%s:%.1f,%.1f,%.1f" % [str(d["id"]), w.x, w.y, w.z])
	if mgr != null:
		for c in conns:
			if not (c is Dictionary):
				continue
			var cid := str((c as Dictionary).get("id", ""))
			var cs: PackedVector3Array = mgr.call("run_corners", cid)
			if cs.size() >= 2:
				runs[cid] = cs
				# Only the solver's runs have bends to drag (a penstock or a
				# culvert keeps its own path).
				if (mgr.call("run_info", cid) as Dictionary).has("corners"):
					editable[cid] = true
				parts.append("%s:%d" % [cid, hash(cs)])
	return {"positions": positions, "runs": runs, "editable": editable, "sig": str(hash(parts))}


## As built: a bend dragged in the picture is a bend point of the run in the
## world, at the same height (one undo step, the Route tool's own write).
func _on_bend_moved(pid: String, index: int, to: Vector2) -> void:
	var p := _pipe_doc(pid)
	if p.is_empty() or not p.has("world"):
		return
	var c3: PackedVector3Array = p["world"]
	var ci := index + 2
	if ci <= 0 or ci >= c3.size() - 1:
		return
	var was: Vector3 = c3[ci]
	var iso := MimicWorldSource.iso_of(_doc)
	var now := iso.from_2d(to, was.y)
	var vias := _vias_of(pid)
	var hit := -1
	for i in vias.size():
		if (vias[i] as Vector3).distance_to(was) < 0.35:
			hit = i
			break
	if hit >= 0:
		vias[hit] = now
	else:
		vias.append(now)
		vias.sort_custom(func(x: Vector3, y: Vector3) -> bool:
			return _param_on(c3, x) < _param_on(c3, y))
	_write_vias(pid, vias)
	_toast("Bend moved: the run is routed through it")


func _on_bend_removed(pid: String, index: int) -> void:
	var p := _pipe_doc(pid)
	if p.is_empty() or not p.has("world"):
		return
	var c3: PackedVector3Array = p["world"]
	var ci := index + 2
	if ci <= 0 or ci >= c3.size() - 1:
		return
	var was: Vector3 = c3[ci]
	var vias := _vias_of(pid)
	for i in vias.size():
		if (vias[i] as Vector3).distance_to(was) < 0.35:
			vias.remove_at(i)
			_write_vias(pid, vias)
			_toast("Bend point removed")
			return
	_toast("That bend is the router's own: drag it to make it a bend point")


func _pipe_doc(pid: String) -> Dictionary:
	for p in _doc.get("pipes", []):
		if str((p as Dictionary)["id"]) == pid:
			return p
	return {}


func _vias_of(cid: String) -> Array:
	var model: Object = _canvas.get("model") if _canvas != null else null
	var out: Array = []
	if model == null:
		return out
	for w in (model.call("get_connection", cid) as Dictionary).get("route_3d", []):
		if w is Dictionary:
			out.append(Vector3(float(w.get("x", 0.0)), float(w.get("y", 0.0)), float(w.get("z", 0.0))))
	return out


func _write_vias(cid: String, vias: Array) -> void:
	if _view == null or not _view.has_method("set_run_route"):
		return
	var out: Array = []
	for v in vias:
		out.append({"x": (v as Vector3).x, "y": (v as Vector3).y, "z": (v as Vector3).z})
	_view.call("set_run_route", cid, out, {})
	_key = ""


static func _param_on(pts: PackedVector3Array, p: Vector3) -> float:
	var best := INF
	var best_s := 0.0
	var s := 0.0
	for i in range(pts.size() - 1):
		var q := Geometry3D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
		if q.distance_to(p) < best:
			best = q.distance_to(p)
			best_s = s + pts[i].distance_to(q)
		s += pts[i].distance_to(pts[i + 1])
	return best_s


## Select a line and show its card (what it is, how long it is in 3D, Show
## in 3D). Also what Route → "Open in Process" lands on.
func select_pipe(cid: String) -> void:
	if _canvas != null and _canvas.has_method("_select_connection"):
		_canvas.call("_select_connection", cid)
	if mimic != null:
		mimic.set("selected_id", cid)
		mimic.queue_redraw()
	var fp := _pipe_faceplate(cid)
	if fp.is_empty() or not _tool.is_empty():
		return
	if _face == null:
		_face = PanelContainer.new()
		_face.set_script(FaceScript)
		_face.name = "ProcessFaceplate"
		add_child(_face)
		_face.connect("dismissed", func() -> void: _face_id = "")
	_face_id = cid
	var at: Vector2 = mimic.call("pipe_screen_point", cid, 0.5)
	if not is_finite(at.x):
		at = mimic.size * 0.5
	if _built:
		# Out of the way of the run's bend handles.
		at = Vector2(mimic.size.x - 200.0, 120.0)
	_face.call("show_for", fp, mimic.global_position + at)


## A line's card: its kind and size, its run in 3D, and the way there.
func _pipe_faceplate(cid: String) -> Dictionary:
	var model: Object = _canvas.get("model") if _canvas != null else null
	if model == null:
		return {}
	var conn: Dictionary = model.call("get_connection", cid)
	if conn.is_empty():
		return {}
	var tid := ConduitKinds.derive_type_for_connection(conn)
	var style: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var lines: Array = []
	lines.append(["Run", ConduitKinds.display_name_with_size(tid, style)])
	var svc := ServicePalette.service_for(conn)
	if not svc.is_empty():
		lines.append(["Carries", ServicePalette.label_of(svc)])
	var len_m := float(conn.get("route_length_m", 0.0))
	var in_3d: bool = bool(model.call("connection_is_3d_routable", conn))
	if conn.get("visible_3d") == true and len_m > 0.0:
		lines.append(["In 3D", ConduitLength.format(len_m)])
	elif in_3d:
		lines.append(["In 3D", "not drawn yet"])
	else:
		lines.append(["In 3D", "an end has no place in the world"])
	var btns: Array = []
	if in_3d:
		btns.append({"id": "show3d", "text": "Show in 3D",
			"tip": "Go to the run in the world, with the Route tools on it.",
			"on_press": func() -> void:
				if _view != null and _view.has_method("route_run_in_world"):
					_view.call("route_run_in_world", cid)})
	btns.append({"id": "style", "text": "Style…",
		"on_press": func() -> void:
			if _view != null and _view.has_method("open_conduit_style_modal"):
				_view.call("open_conduit_style_modal", cid)})
	var a_nm := str(_item(str(conn.get("source_item_id", ""))).get("specs", {}).get("name", "?"))
	var b_nm := str(_item(str(conn.get("target_item_id", ""))).get("specs", {}).get("name", "?"))
	return {"id": cid, "title": "%s → %s" % [a_nm, b_nm],
		"subtitle": cid, "state": "", "state_color": UITheme.C_TEXT, "lines": lines, "buttons": btns}


func _on_empty() -> void:
	_hide_face()


func _hide_face() -> void:
	if _face != null:
		_face.call("dismiss")
	_face_id = ""


## Esc: true when a tool was armed or a faceplate was open (now put away).
func dismiss_faceplate() -> bool:
	if not _widget_tool.is_empty():
		set_widget_tool("")
		return true
	if not _tool.is_empty():
		set_tool("")
		return true
	if _face != null and _face.visible:
		_hide_face()
		return true
	return false


func faceplate() -> PanelContainer:
	return _face


func _refresh_face() -> void:
	if _face == null or not _face.visible or _face_id.is_empty():
		return
	var fp := _faceplate_for(_face_id)
	if fp.is_empty():
		_hide_face()
		return
	_face.call("set_state", str(fp.get("state", "")), fp.get("state_color", UITheme.C_TEXT))


## What the faceplate of a node shows ({} = it has none). A node drawn
## from its model also gets the picture's view to switch.
func _faceplate_for(id: String) -> Dictionary:
	var fp := _faceplate_base(id)
	if id.begins_with("ins:") or MimicWidgets.is_widget_id(id):
		return fp
	var it := _item(id)
	if it.is_empty() or not (MimicGraphSource.kind_of(it) in MimicGraphSource.ICON_KINDS):
		return fp
	if str(_model_of(it)[0]).is_empty():
		return fp
	if fp.is_empty():
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		fp = {"id": id, "title": str(sp.get("name", id)), "subtitle": "node.%s" % id, "state": "",
			"state_color": UITheme.C_TEXT, "lines": [], "buttons": []}
	var view := icon_view_of(id)
	var nxt := MimicIcons.next_view(view) if view != MimicIcons.VIEW_BOXES else MimicIcons.VIEW_SIDE
	(fp["lines"] as Array).append(["Picture", str(MimicIcons.LABELS.get(view, view))])
	(fp["buttons"] as Array).append({"id": "icon_view", "text": "Show its %s" % str(MimicIcons.LABELS[nxt]).to_lower(),
		"tip": "How this node is drawn in the picture (only here; Pictures on the bottom bar sets every node).",
		"on_press": func() -> void: set_node_icon_view(id, nxt)})
	return fp


func _faceplate_base(id: String) -> Dictionary:
	var model: Object = _canvas.get("model") if _canvas != null else null
	if model != null and _item(id).is_empty() and not (model.call("get_connection", id) as Dictionary).is_empty():
		return _pipe_faceplate(id)
	if MimicWidgets.is_widget_id(id):
		return _widget_faceplate(id)
	if id.begins_with("ins:"):
		for ins in _instruments:
			if "ins:" + str(ins["id"]) == id and ins.has("logic"):
				return _logic_faceplate(id, str(ins["logic"]))
			if "ins:" + str(ins["id"]) == id:
				var ok := bool(ins.get("available", false))
				return {"id": id, "title": str(ins.get("label", "Instrument")), "subtitle": str(ins["id"]),
					"state": str(ins.get("text", "")), "state_color": MimicSymbols.OPEN if ok else MimicSymbols.WARN,
					"lines": [["Reads", str(_item(str(ins["item"])).get("specs", {}).get("name", str(ins["item"])))],
						["Board", str(_item(str(ins["board"])).get("specs", {}).get("name", "a placed board"))]],
					"buttons": []}
		return {}
	var it := _item(id)
	if it.is_empty():
		return {}
	if BreakerTrip.is_breaker(it):
		var bs: Dictionary = it.get("specs", {}) as Dictionary
		var closed := BreakerTrip.is_closed(bs)
		var tripped := bool(bs.get("tripped", false))
		var fuse := bool(bs.get("fuse", false))
		var btns: Array = []
		if tripped:
			btns.append({"id": "reset", "text": "Replace the fuse" if fuse else "Reset it",
				"on_press": func() -> void: _breaker(id, true)})
		elif not fuse:
			btns.append({"id": "on", "text": "Close it", "disabled": closed, "on_press": func() -> void: _breaker(id, true)})
			btns.append({"id": "off", "text": "Open it", "disabled": not closed, "on_press": func() -> void: _breaker(id, false)})
		return {"id": id, "title": str(bs.get("name", "Breaker")), "subtitle": "Fuse" if fuse else "Breaker",
			"state": BreakerTrip.state_words(bs),
			"state_color": MimicSymbols.WARN if tripped else (MimicSymbols.OPEN if closed else MimicSymbols.CLOSED),
			"lines": [["Rated", "%s A at %d V" % [UiText.num(BreakerTrip.rating_a(bs), "", 2), int(BreakerTrip.volts(bs))]],
				["Carries now", "%s A" % UiText.num(float(bs.get("live_amps", 0.0)), "", 2)]],
			"buttons": btns}
	var specs: Dictionary = it.get("specs", {}) as Dictionary
	var nm := str(specs.get("name", id))
	var ty := str(it.get("type", ""))
	if ty == "resource":
		var in_open := bool(specs.get("input_valve_open", true))
		var out_open := bool(specs.get("output_valve_open", true))
		var lvl := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
		return {"id": id, "title": nm, "subtitle": "tank.%s.level" % id,
			"state": "%d %% full" % int(round(lvl * 100.0)), "state_color": UITheme.C_TEXT,
			"lines": [["Way in", "open" if in_open else "shut"], ["Way out", "open" if out_open else "shut"]],
			"buttons": [
				{"id": "inlet", "text": "Shut the way in" if in_open else "Open the way in",
					"on_press": func() -> void: _tank_valve(id, "input_valve_open", not in_open)},
				{"id": "outlet", "text": "Shut the way out" if out_open else "Open the way out",
					"on_press": func() -> void: _tank_valve(id, "output_valve_open", not out_open)}]}
	if ty in ["appliance", "acload"]:
		var d_on := str(specs.get("requested_state", specs.get("current_state", "on"))).to_lower() == "on"
		var d_lines: Array = [["Draws", UiText.num(float(specs.get("avg_watts", specs.get("rated_watts", 0.0))), "W")]]
		var role := ScadaNet.role_of(it)
		var hub2: Node = _view.call("scada_hub") if _view != null and _view.has_method("scada_hub") else null
		if not role.is_empty() and hub2 != null:
			var r: Dictionary = hub2.call("net_reach")
			if bool(r.get("enforced", false)) and role != ScadaNet.ROLE_SERVER:
				var why := str(hub2.call("net_fault", id))
				d_lines.append(["Network", "heard by the server" if why.is_empty() else why])
			elif role == ScadaNet.ROLE_BOARD:
				d_lines.append(["Network", "no server on the graph: always heard"])
		return {"id": id, "title": nm, "subtitle": "node.%s" % id, "state": "On" if d_on else "Off",
			"state_color": MimicSymbols.OPEN if d_on else MimicSymbols.CLOSED, "lines": d_lines,
			"buttons": [
				{"id": "on", "text": "Switch on", "disabled": d_on, "on_press": func() -> void: _switch(id, true)},
				{"id": "off", "text": "Switch off", "disabled": not d_on, "on_press": func() -> void: _switch(id, false)}]}
	if ty != "processor" or str(specs.get("role", "")) == "habitat":
		return {}
	var on := str(specs.get("requested_state", specs.get("current_state", "on"))).to_lower() == "on"
	var words := ["On", "Off", "Switch on", "Switch off"]
	var state := "On" if on else "Off"
	var lines: Array = []
	if FlowCtl.is_flowctl(specs):
		words = FlowCtl.verbs(specs)
		state = FlowCtl.state_words(specs)
		on = FlowCtl.is_on(specs)
		var unit := ResourceKinds.default_unit(str(specs.get("ctl_resource", "water")))
		lines.append(["Full flow", "%s/h" % UiText.num(float(specs.get("max_rate", 0.0)), unit, 3)])
		if FlowCtl.kind_of(specs) == FlowCtl.KIND_PUMP:
			lines.append(["Draws", UiText.num(float(specs.get("watts", 0.0)), "W")])
			lines.append(["Lifts up to", "%s m" % UiText.num(float(specs.get("max_lift_m", 0.0)), "", 2)])
		if FlowCtl.kind_of(specs) == FlowCtl.KIND_CHECK:
			return {"id": id, "title": nm, "subtitle": "One way only: nothing to switch.", "state": state,
				"state_color": MimicSymbols.OPEN, "lines": lines, "buttons": []}
	else:
		var st := str(specs.get("node_state", ""))
		if not st.is_empty() and on:
			state = st.capitalize()
		var why := str(specs.get("node_state_reason", ""))
		if not why.is_empty() and (st == "blocked" or st == "starved"):
			lines.append(["Why", why.replace("_", " ")])
	return {"id": id, "title": nm, "subtitle": "node.%s" % id, "state": state,
		"state_color": MimicSymbols.OPEN if on else MimicSymbols.CLOSED, "lines": lines,
		"buttons": [
			{"id": "on", "text": words[2], "disabled": on, "on_press": func() -> void: _switch(id, true)},
			{"id": "off", "text": words[3], "disabled": not on, "on_press": func() -> void: _switch(id, false)}]}


func _switch(id: String, on: bool) -> void:
	var hub: Node = _view.call("scada_hub") if _view != null and _view.has_method("scada_hub") else null
	if hub != null:
		hub.call("refresh")
		var done := bool(hub.call("command", "node.%s" % id, 1.0 if on else 0.0))
		var why := str(hub.get("last_refusal"))
		if not done and not why.is_empty() and _view.has_method("_show_toast"):
			_view.call("_show_toast", why, 4.0)
	_reshow_face()


func _breaker(id: String, close: bool) -> void:
	var it := _item(id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	if close:
		specs.merge(BreakerTrip.reset(), true)
	else:
		specs["closed"] = false
	(_canvas.get("model") as Object).call("update_item", id, {"specs": specs})
	_reshow_face()


func _tank_valve(id: String, key: String, open: bool) -> void:
	var it := _item(id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = open
	(_canvas.get("model") as Object).call("update_item", id, {"specs": specs})
	_reshow_face()


func _reshow_face() -> void:
	refresh()
	if _face == null or _face_id.is_empty():
		return
	var e: Dictionary = mimic.call("element_by_id", _face_id)
	var fp := _faceplate_for(_face_id)
	if e.is_empty() or fp.is_empty():
		_hide_face()
		return
	_face.call("show_for", fp, mimic.global_position + (mimic.call("element_rect", e) as Rect2).get_center())


# ── editing: the palette, placing parts, drawing pipes ──────────────────────

const TOOL_BUTTONS := [
	["store", "Store", "database", "A store. Click open space to set one down, or a pipe to put it in the line."],
	["valve", "Valve", "git-commit-horizontal", "A valve. Click a pipe to put it in the line, or open space to set one down."],
	["check", "Check valve", "arrow-right-to-line", "A one-way valve. Click a pipe to put it in the line."],
	["pump", "Pump", "fan", "A pump (needs AC power). Click a pipe to put it in the line."],
	["pipe", "Pipe", "spline", "Draw a pipe: press on what feeds it, drag to what it feeds, let go."],
	["breaker", "Breaker", "zap-off", "A 15 A breaker. Click an AC wire to put it in the line."],
	["wire", "Wire", "zap", "Draw an AC wire: press on the supply (an inverter, a panel, a breaker), drag to the load."],
	["cable", "Cable", "network", "Draw a network cable between two network devices (Wi-Fi from an access point to a board)."],
]
## Tools that draw a line from one thing to another.
const LINE_TOOLS := ["pipe", "wire", "cable"]

var _tool := ""
var _palette: PanelContainer = null
var _tool_btns: Dictionary = {}


func _build_palette() -> void:
	_palette = PanelContainer.new()
	_palette.name = "ProcessPalette"
	_palette.add_theme_stylebox_override("panel", UITheme.panel_style())
	# A bar along the bottom that wraps onto a second row on a narrow canvas.
	add_child(_palette)
	_palette.anchor_left = 0.0
	_palette.anchor_right = 1.0
	_palette.anchor_top = 1.0
	_palette.anchor_bottom = 1.0
	_palette.offset_left = 12.0
	_palette.offset_right = -12.0
	_palette.offset_bottom = -10.0
	_palette.offset_top = -10.0
	_palette.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_palette.resized.connect(_on_palette_resized)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	_palette.add_child(row)
	var show_cap := Label.new()
	show_cap.text = "Show"
	show_cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	row.add_child(show_cap)
	for lay in MimicGraphSource.LAYERS:
		var lb := Button.new()
		lb.name = "layer_%s" % str(lay)
		lb.text = str(MimicGraphSource.LAYER_LABELS[lay])
		lb.toggle_mode = true
		lb.focus_mode = Control.FOCUS_NONE
		lb.button_pressed = bool(_layers.get(lay, false))
		lb.tooltip_text = "Show the %s lines in this picture." % str(MimicGraphSource.LAYER_LABELS[lay]).to_lower()
		UITheme.style_button(lb)
		var lay_id := str(lay)
		lb.toggled.connect(func(on: bool) -> void: set_layer(lay_id, on))
		row.add_child(lb)
		_layer_btns[lay_id] = lb
	_built_btn = Button.new()
	_built_btn.name = "view_built"
	_built_btn.text = "As built"
	_built_btn.toggle_mode = true
	_built_btn.button_pressed = _built
	_built_btn.focus_mode = Control.FOCUS_NONE
	_built_btn.tooltip_text = ("Draw the system where it really is: machines at their places in the world, "
		+ "pipes and cables along their 3D runs, in a true isometric. Click a run, drag its bends.")
	UITheme.style_button(_built_btn)
	_built_btn.toggled.connect(set_built)
	row.add_child(_built_btn)
	_icon_opt = OptionButton.new()
	_icon_opt.name = "icon_view"
	_icon_opt.focus_mode = Control.FOCUS_NONE
	_icon_opt.tooltip_text = "Draw machines and devices as pictures of their 3D models, seen from this side (or as plain boxes)."
	for v in MimicIcons.VIEWS + [MimicIcons.VIEW_BOXES]:
		_icon_opt.add_item("Pictures: %s" % str(MimicIcons.LABELS[v]) if v != MimicIcons.VIEW_BOXES else "Boxes only")
		_icon_opt.set_item_metadata(_icon_opt.item_count - 1, v)
	UITheme.style_button(_icon_opt)
	_icon_opt.item_selected.connect(func(i: int) -> void: set_icon_view(str(_icon_opt.get_item_metadata(i))))
	row.add_child(_icon_opt)
	_sync_icon_opt()
	_flow_opt = OptionButton.new()
	_flow_opt.name = "flow_dir"
	_flow_opt.focus_mode = Control.FOCUS_NONE
	_flow_opt.tooltip_text = "Which way the process reads: feed on the left flowing right, or feed on top flowing down."
	_flow_opt.add_item("Flow: left to right")
	_flow_opt.set_item_metadata(0, MimicGraphSource.FLOW_RIGHT)
	_flow_opt.add_item("Flow: top to bottom")
	_flow_opt.set_item_metadata(1, MimicGraphSource.FLOW_DOWN)
	UITheme.style_button(_flow_opt)
	_flow_opt.item_selected.connect(func(i: int) -> void: set_flow_dir(str(_flow_opt.get_item_metadata(i))))
	row.add_child(_flow_opt)
	_sync_flow_opt()
	row.add_child(VSeparator.new())
	var cap := Label.new()
	cap.text = "Add"
	cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	row.add_child(cap)
	for t in TOOL_BUTTONS:
		var b := Button.new()
		b.name = "tool_%s" % str(t[0])
		b.text = str(t[1])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = str(t[3])
		UITheme.style_button(b)
		var id := str(t[0])
		b.pressed.connect(func() -> void: set_tool("" if _tool == id else id))
		row.add_child(b)
		_tool_btns[id] = b
	row.add_child(VSeparator.new())
	var rs := Button.new()
	rs.name = "reset_layout"
	rs.text = "Tidy"
	rs.focus_mode = Control.FOCUS_NONE
	rs.tooltip_text = "Put everything back where the layout has it."
	UITheme.style_button(rs)
	rs.pressed.connect(reset_layout)
	row.add_child(rs)
	var lg := Button.new()
	lg.name = "logic_btn"
	lg.text = "Logic"
	lg.focus_mode = Control.FOCUS_NONE
	lg.tooltip_text = "Control logic: on / off bands, PID loops, interlocks, timers, sequences."
	UITheme.style_button(lg)
	lg.pressed.connect(func() -> void:
		if _view != null and _view.has_method("open_logic_editor"):
			_view.call("open_logic_editor"))
	row.add_child(lg)
	row.add_child(VSeparator.new())
	_checks_btn = Button.new()
	_checks_btn.name = "checks_btn"
	_checks_btn.text = "Checks"
	_checks_btn.toggle_mode = true
	_checks_btn.focus_mode = Control.FOCUS_NONE
	_checks_btn.tooltip_text = "What a reviewer would circle on this drawing."
	UITheme.style_button(_checks_btn)
	_checks_btn.toggled.connect(func(on: bool) -> void: _show_checks(on))
	row.add_child(_checks_btn)
	_alarms_btn = Button.new()
	_alarms_btn.name = "alarms_btn"
	_alarms_btn.text = "Alarms"
	_alarms_btn.focus_mode = Control.FOCUS_NONE
	_alarms_btn.tooltip_text = "Limits on any tag: what is in alarm now, the rules, the journal."
	UITheme.style_button(_alarms_btn)
	_alarms_btn.pressed.connect(func() -> void:
		if _view != null and _view.has_method("open_alarm_panel"):
			_view.call("open_alarm_panel"))
	row.add_child(_alarms_btn)
	var hw := Button.new()
	hw.name = "hardware_btn"
	hw.text = "Hardware"
	hw.focus_mode = Control.FOCUS_NONE
	hw.tooltip_text = "Real outputs: which tags drive which Home Assistant entities, and the arm switch."
	UITheme.style_button(hw)
	hw.pressed.connect(func() -> void:
		if _view != null and _view.has_method("open_outputs_panel"):
			_view.call("open_outputs_panel"))
	row.add_child(hw)
	_widgets_menu = MenuButton.new()
	_widgets_menu.name = "widgets_menu"
	_widgets_menu.text = "Widgets"
	_widgets_menu.flat = false
	_widgets_menu.focus_mode = Control.FOCUS_NONE
	_widgets_menu.tooltip_text = "Gauges, bars, numbers, trends, lamps, buttons and sliders bound to tags. Pick one, then click the picture."
	UITheme.style_button(_widgets_menu)
	var wpm := _widgets_menu.get_popup()
	for wi in MimicWidgets.KINDS.size():
		wpm.add_item(str(MimicWidgets.KIND_WORDS[MimicWidgets.KINDS[wi]]), wi)
		wpm.set_item_tooltip(wi, str(MimicWidgets.KIND_TIPS[MimicWidgets.KINDS[wi]]))
	wpm.add_separator()
	wpm.add_check_item("Click a widget to edit it", WIDGET_EDIT_ID)
	wpm.id_pressed.connect(func(mid: int) -> void:
		if mid == WIDGET_EDIT_ID:
			set_widget_edit(not _widget_edit)
		elif mid >= 0 and mid < MimicWidgets.KINDS.size():
			set_widget_tool(str(MimicWidgets.KINDS[mid])))
	row.add_child(_widgets_menu)
	var tr := Button.new()
	tr.name = "trends_btn"
	tr.text = "Trends"
	tr.focus_mode = Control.FOCUS_NONE
	tr.tooltip_text = "Any tags over time on one chart: several pens, a cursor, pan and zoom."
	UITheme.style_button(tr)
	tr.pressed.connect(func() -> void:
		if _view != null and _view.has_method("open_trend_window"):
			_view.call("open_trend_window"))
	row.add_child(tr)
	var bc := Button.new()
	bc.name = "bootcamp_btn"
	bc.text = "Lessons"
	bc.focus_mode = Control.FOCUS_NONE
	bc.tooltip_text = "Process Bootcamp: five short lessons on a practice plant (a valve, a level by hand, a rule, a PID, an alarm). Your own graph waits and comes back after."
	UITheme.style_button(bc)
	bc.pressed.connect(func() -> void:
		if _view != null and _view.has_method("start_process_bootcamp"):
			_view.call("start_process_bootcamp"))
	row.add_child(bc)
	var tp := Button.new()
	tp.name = "templates_btn"
	tp.text = "Templates"
	tp.focus_mode = Control.FOCUS_NONE
	tp.tooltip_text = "Whole processes to drop in (a held tank, a PID loop, a guarded pump), your saved ones, and share codes."
	UITheme.style_button(tp)
	tp.pressed.connect(func() -> void:
		if _view != null and _view.has_method("open_process_library"):
			_view.call("open_process_library"))
	row.add_child(tp)
	_edit_nodes = [cap, rs, _widgets_menu, bc, tp]
	for tk in _tool_btns:
		_edit_nodes.append(_tool_btns[tk])
	_operate_btn = Button.new()
	_operate_btn.name = "operate_btn"
	_operate_btn.text = "Operate"
	_operate_btn.toggle_mode = true
	_operate_btn.focus_mode = Control.FOCUS_NONE
	_operate_btn.tooltip_text = "Operator mode: the picture fills the window, nothing can be moved or rewired, and the buttons are big enough for a touch screen. Esc leaves it."
	UITheme.style_button(_operate_btn)
	_operate_btn.toggled.connect(func(on: bool) -> void:
		if _view != null and _view.has_method("set_operator_mode"):
			_view.call("set_operator_mode", on)
		else:
			set_operator(on))
	row.add_child(_operate_btn)


## The picture fits above the palette, however many rows it takes.
func _on_palette_resized() -> void:
	if mimic != null and _palette != null:
		mimic.offset_bottom = -(_palette.size.y + 18.0)


func tool() -> String:
	return _tool


func layers() -> Dictionary:
	return _layers.duplicate()


func layer_button(id: String) -> Button:
	return _layer_btns.get(id) as Button


## Show / hide one kind of line (pipes, power, data). At least one stays on.
func set_layer(id: String, on: bool) -> void:
	_layers[id] = on
	var any := false
	for k in _layers:
		any = any or bool(_layers[k])
	if not any:
		_layers[MimicGraphSource.LAYER_PIPES] = true
	for k in _layer_btns:
		(_layer_btns[k] as Button).set_pressed_no_signal(bool(_layers.get(k, false)))
	refresh(true)
	if mimic != null:
		mimic.call("fit")


func layers_data() -> Array:
	var out: Array = []
	for k in MimicGraphSource.LAYERS:
		if bool(_layers.get(k, false)):
			out.append(k)
	if _built:
		out.append(BUILT_TOKEN)
	return out


func set_layers_data(data: Variant) -> void:
	if not (data is Array) or (data as Array).is_empty():
		return
	_layers = {}
	for k in data:
		if str(k) in MimicGraphSource.LAYERS:
			_layers[str(k)] = true
	_built = (data as Array).has(BUILT_TOKEN)
	if _built_btn != null:
		_built_btn.set_pressed_no_signal(_built)
	if _layers.is_empty():
		_layers[MimicGraphSource.LAYER_PIPES] = true
	for k in _layer_btns:
		(_layer_btns[k] as Button).set_pressed_no_signal(bool(_layers.get(k, false)))
	_key = ""


func tool_button(id: String) -> Button:
	return _tool_btns.get(id) as Button


func set_tool(id: String) -> void:
	if _operator:
		id = ""
	_tool = id
	_widget_tool = ""
	for k in _tool_btns:
		(_tool_btns[k] as Button).set_pressed_no_signal(k == id)
	_hide_face()
	var hint := ""
	if id == "pipe":
		hint = "Press on what feeds it, drag to what it feeds"
	elif id == "wire":
		hint = "Press on the supply, drag to the load"
	elif id == "cable":
		hint = "Press on one network device, drag to the other"
	elif id == "breaker":
		hint = "Click an AC wire to put the breaker in it"
	elif not id.is_empty():
		hint = "Click a pipe to put the %s in it, or open space" % str(ProcessEdit.TOOL_WORDS.get(id, id))
	# A tool needs its lines on screen.
	var need := ""
	if id in ["wire", "breaker"]:
		need = MimicGraphSource.LAYER_POWER
	elif id == "cable":
		need = MimicGraphSource.LAYER_DATA
	if not need.is_empty() and not bool(_layers.get(need, false)):
		set_layer(need, true)
	if mimic != null:
		mimic.call("set_tool", "" if id.is_empty() else ("pipe" if id in LINE_TOOLS else "place"), hint)


## One undo step round `fn` (which edits the model and returns ProcessEdit's
## result); a refusal is said in a toast and leaves no step.
func _edit(fn: Callable) -> Dictionary:
	var model: Object = _canvas.get("model") if _canvas != null else null
	if model == null:
		return {"ok": false, "id": "", "why": ""}
	if _view != null:
		_view.set("_history_suppress", true)
	var res: Dictionary = fn.call(model)
	if _view != null:
		_view.set("_history_suppress", false)
		if bool(res.get("ok", false)):
			_view.call("_push_history")
			if _view.has_method("_mark_dirty_for_autosave"):
				_view.call("_mark_dirty_for_autosave")
		elif not str(res.get("why", "")).is_empty() and _view.has_method("_show_toast"):
			_view.call("_show_toast", str(res["why"]), 3.5)
	_canvas.call("queue_redraw")
	refresh(true)
	return res


func _handles_of(item: Dictionary) -> Array:
	return _canvas.call("_resolved_handles", item) if _canvas != null else []


func _on_place(at: Vector2, pipe: Dictionary) -> void:
	if _operator:
		return
	if not _widget_tool.is_empty():
		_place_widget(at)
		return
	var t := _tool
	if t == "breaker":
		if pipe.is_empty() or str(pipe.get("style", "")) != MimicGraphSource.LAYER_POWER:
			if _view != null and _view.has_method("_show_toast"):
				_view.call("_show_toast", "A breaker goes in an AC wire: click one of the power lines.", 3.5)
			return
		var rb := _edit(func(m: Object) -> Dictionary: return ProcessEdit.split_power(m as GraphModel, str(pipe["id"])))
		if bool(rb.get("ok", false)):
			set_tool("")
			mimic.set("selected_id", str(rb["id"]))
			_canvas.call("_select_item", str(rb["id"]))
		return
	if not (t in ProcessEdit.TOOLS):
		return
	if not pipe.is_empty() and str(pipe.get("style", MimicGraphSource.LAYER_PIPES)) != MimicGraphSource.LAYER_PIPES:
		if _view != null and _view.has_method("_show_toast"):
			_view.call("_show_toast", "That is not a pipe. Click a pipe, or open space.", 3.0)
		return
	var scope := _scope()
	var res: Dictionary
	if not pipe.is_empty():
		res = _edit(func(m: Object) -> Dictionary: return ProcessEdit.split(m as GraphModel, str(pipe["id"]), t))
	else:
		# Its freeform spot: under what is already in this scope.
		var low := Vector2.ZERO
		var n := 0
		for it in _items():
			low.x += float(it.get("x", 0.0))
			low.y = maxf(low.y, float(it.get("y", 0.0)) + float(it.get("height", 100.0)))
			n += 1
		var spot := Vector2(low.x / float(maxi(n, 1)), low.y + 80.0)
		res = _edit(func(m: Object) -> Dictionary: return ProcessEdit.place(m as GraphModel, t, scope, spot))
		if bool(res.get("ok", false)):
			# Stand it where it was clicked.
			var e: Dictionary = mimic.call("element_by_id", str(res["id"]))
			if not e.is_empty():
				_on_moved(str(res["id"]), at - (e["pos"] as Vector2))
				mimic.call("set_pins", _pins.get(_pin_scope(), {}))
	if bool(res.get("ok", false)):
		set_tool("")
		mimic.set("selected_id", str(res["id"]))
		if _canvas.has_method("_select_item"):
			_canvas.call("_select_item", str(res["id"]))


func _on_link(from_id: String, to_id: String) -> void:
	if _operator:
		return
	# A part set down loose joins the line when it is piped: it takes its
	# place in the layout, so the spot it was set down at no longer applies.
	var was_loose: Array = []
	for id in [from_id, to_id]:
		if bool((mimic.call("element_by_id", id) as Dictionary).get("loose", false)):
			was_loose.append(id)
	if from_id.begins_with("ins:") or to_id.begins_with("ins:"):
		return
	var t := _tool
	var res := _edit(func(m: Object) -> Dictionary:
		if t == "wire":
			return ProcessEdit.link_power(m as GraphModel, from_id, to_id, _handles_of)
		if t == "cable":
			return ProcessEdit.link_data(m as GraphModel, from_id, to_id, _handles_of)
		return ProcessEdit.link(m as GraphModel, from_id, to_id))
	if bool(res.get("ok", false)):
		var d: Dictionary = _pins.get(_pin_scope(), {})
		for id in was_loose:
			d.erase(id)
		mimic.call("set_pins", d)
		mimic.set("selected_id", str(res["id"]))
		if _canvas.has_method("_select_connection"):
			_canvas.call("_select_connection", str(res["id"]))


# ── design checks ───────────────────────────────────────────────────────────

const CHECKS_S := 1.0

var _checks: Array = []
var _checks_btn: Button = null
var _checks_panel: PanelContainer = null
var _checks_sig := "?"
var _checks_at := -10.0


func checks() -> Array:
	return _checks


func checks_panel() -> PanelContainer:
	return _checks_panel


func _refresh_checks(items: Array, conns: Array) -> void:
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - _checks_at < CHECKS_S:
		return
	_checks_at = now
	var net_checks: Array = []
	var model: Object = _canvas.get("model") if _canvas != null else null
	if model != null:
		net_checks = ScadaNet.checks(GraphNesting.walk_items(model as GraphModel, "root"), GraphNesting.flat_connections_cached(model as GraphModel))
	_checks = ProcessChecks.run(items, conns, net_checks)
	var sig := str(_checks)
	if sig == _checks_sig:
		return
	_checks_sig = sig
	if _checks_btn != null:
		var errs := 0
		for c in _checks:
			if str(c["level"]) == "error":
				errs += 1
		_checks_btn.text = ProcessChecks.summary(_checks)
		_checks_btn.add_theme_color_override("font_color",
			UITheme.C_ERROR if errs > 0 else (UITheme.C_WARN if not _checks.is_empty() else UITheme.C_OK))
	if _checks_panel != null and _checks_panel.visible:
		_fill_checks()


## Recompute now (the harness; an edit that should show at once).
func recheck() -> void:
	_checks_at = -10.0
	_refresh_checks(_items(), _conns())


func _show_checks(on: bool) -> void:
	if _checks_panel == null:
		_checks_panel = PanelContainer.new()
		_checks_panel.name = "checks_panel"
		_checks_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
		add_child(_checks_panel)
		_checks_panel.custom_minimum_size = Vector2(minf(430.0, size.x - 24.0), 0)
	_checks_panel.visible = on
	if _checks_btn != null:
		_checks_btn.set_pressed_no_signal(on)
	if on:
		_fill_checks()


func _fill_checks() -> void:
	for c in _checks_panel.get_children():
		_checks_panel.remove_child(c)
		c.queue_free()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_checks_panel.add_child(box)
	if _checks.is_empty():
		var ok := Label.new()
		ok.text = "Nothing to fix on this drawing."
		ok.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		box.add_child(ok)
	for i in mini(_checks.size(), 8):
		var c: Dictionary = _checks[i]
		var b := Button.new()
		b.name = "check_%d" % i
		b.text = str(c["text"])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(minf(410.0, size.x - 44.0), 0)
		b.tooltip_text = "Show it"
		UITheme.style_button(b)
		b.add_theme_color_override("font_color", UITheme.C_ERROR if str(c["level"]) == "error" else UITheme.C_WARN)
		var ids: Array = c.get("ids", [])
		b.pressed.connect(func() -> void: _show_check_target(ids), CONNECT_DEFERRED)
		box.add_child(b)
	if _checks.size() > 8:
		var more := Label.new()
		more.text = "and %s more" % UiText.count(_checks.size() - 8, "item")
		more.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		box.add_child(more)
	_checks_panel.reset_size()
	await get_tree().process_frame
	if is_instance_valid(_checks_panel) and _palette != null:
		_checks_panel.reset_size()
		_checks_panel.position = Vector2(size.x - _checks_panel.size.x - 12.0,
			_palette.position.y - _checks_panel.size.y - 8.0).max(Vector2(12, 12))


## Select what a check is about, in the picture and in the graph.
func _show_check_target(ids: Array) -> void:
	if ids.is_empty() or mimic == null:
		return
	var id := str(ids[0])
	mimic.set("selected_id", id)
	mimic.queue_redraw()
	if not _item(id).is_empty():
		_canvas.call("_select_item", id)
	elif _canvas.has_method("_select_connection"):
		_canvas.call("_select_connection", id)


# ── controllers in the picture ──────────────────────────────────────────────

func _logic_faceplate(face_id: String, block_id: String) -> Dictionary:
	var hub: Node = _view.call("scada_hub") if _view != null and _view.has_method("scada_hub") else null
	if hub == null:
		return {}
	var b: Dictionary = hub.call("logic_block", block_id)
	if b.is_empty():
		return {}
	var s: Dictionary = (hub.call("logic_status") as Dictionary).get(block_id, {}) as Dictionary
	var kind := str(b.get("kind", ""))
	var btns: Array = []
	var lines: Array = [["Kind", str(ScadaLogic.KIND_LABELS.get(kind, kind))]]
	var cmd := func(what: String) -> void:
		hub.call("logic_command", block_id, what)
		_reshow_face()
	match kind:
		"pid":
			var manual := str(s.get("mode", "auto")) == "manual"
			lines.append(["Setpoint", UiText.num(float(s.get("sp", 0.0)), "", 3)])
			lines.append(["Output", "%s %%" % UiText.num(float(s.get("out", 0.0)), "", 3)])
			btns.append({"id": "auto", "text": "Auto", "disabled": not manual, "on_press": func() -> void: cmd.call("auto")})
			btns.append({"id": "manual", "text": "Manual", "disabled": manual, "on_press": func() -> void: cmd.call("manual")})
		"interlock":
			if bool(s.get("tripped", false)) and bool(b.get("latch", false)):
				btns.append({"id": "reset", "text": "Reset", "on_press": func() -> void: cmd.call("reset")})
		"duty":
			btns.append({"id": "swap", "text": "Swap lead", "on_press": func() -> void: cmd.call("swap")})
		"sequence":
			var run := str(s.get("run", "idle"))
			if run == "running":
				btns.append({"id": "hold", "text": "Hold", "on_press": func() -> void: cmd.call("hold")})
				btns.append({"id": "abort", "text": "Abort", "on_press": func() -> void: cmd.call("abort")})
			elif run == "held":
				btns.append({"id": "resume", "text": "Resume", "on_press": func() -> void: cmd.call("resume")})
				btns.append({"id": "abort", "text": "Abort", "on_press": func() -> void: cmd.call("abort")})
			else:
				btns.append({"id": "start", "text": "Start", "on_press": func() -> void: cmd.call("start")})
	btns.append({"id": "edit", "text": "Edit…", "on_press": func() -> void:
		_hide_face()
		_view.call("open_logic_editor", block_id)})
	var trend := {}
	if hub.has_method("trend"):
		var series: Array = []
		var pv_tag := str(b.get("pv", ""))
		if not pv_tag.is_empty():
			series.append({"values": hub.call("trend", pv_tag), "color": Color(0.35, 0.78, 0.98)})
		if kind == "pid":
			series.append({"values": hub.call("trend", "logic.%s.out" % block_id), "color": MimicSymbols.WARN, "lo": 0.0, "hi": 100.0})
		trend = {"label": "Last 2 h: reading (blue)%s" % (", output (amber)" if kind == "pid" else ""), "series": series}
	return {"id": face_id, "title": str(b.get("name", block_id)), "subtitle": "logic.%s" % block_id, "trend": trend,
		"state": str(s.get("text", "")),
		"state_color": MimicSymbols.WARN if str(s.get("level", "")) == "warn" else MimicSymbols.OPEN,
		"lines": lines, "buttons": btns}


# ── alarms in the lens ──────────────────────────────────────────────────────

const ALARM_COLORS := {"high": Color(0.94, 0.33, 0.31), "medium": Color(0.98, 0.70, 0.22), "low": Color(0.35, 0.78, 0.98)}

var _alarms_btn: Button = null
var _alarm_bar: PanelContainer = null
var _alarm_lbl: Label = null
var _alarm_ack: Button = null
var _alarm_sig := ""


## A strip along the top while anything is in alarm: the worst one in words,
## Acknowledge all, and the way into the alarm window.
func _build_alarm_bar() -> void:
	_alarm_bar = PanelContainer.new()
	_alarm_bar.name = "alarm_bar"
	_alarm_bar.add_theme_stylebox_override("panel", UITheme.chip_style(Color(0.12, 0.07, 0.07, 0.95)))
	_alarm_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_alarm_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_alarm_bar.offset_top = 8.0
	_alarm_bar.visible = false
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_alarm_bar.add_child(row)
	_alarm_lbl = Label.new()
	_alarm_lbl.name = "alarm_text"
	_alarm_lbl.custom_minimum_size.x = 320
	_alarm_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_alarm_lbl.clip_text = true
	row.add_child(_alarm_lbl)
	_alarm_ack = Button.new()
	_alarm_ack.name = "alarm_ack_all"
	_alarm_ack.text = "Acknowledge all"
	_alarm_ack.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_alarm_ack)
	_alarm_ack.pressed.connect(func() -> void:
		var hub: Node = _view.call("scada_hub") if _view != null else null
		if hub != null:
			hub.call("alarm_command", "", "ack_all")
			refresh())
	row.add_child(_alarm_ack)
	var open := Button.new()
	open.name = "alarm_open"
	open.text = "Alarms…"
	open.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(open)
	open.pressed.connect(func() -> void:
		if _view != null:
			_view.call("open_alarm_panel", "active"))
	row.add_child(open)
	add_child(_alarm_bar)


func alarm_bar() -> PanelContainer:
	return _alarm_bar


# ── operator mode and the ARMED bar (SCADA plan, Phase 7) ───────────────────

var _operator := false
var _operate_btn: Button = null
var _edit_nodes: Array = []
var _armed_bar: PanelContainer = null
var _armed_lbl: Label = null
var _armed_sig := ""


func operator() -> bool:
	return _operator


## Operator mode: look and operate, nothing else. The Add tools go, parts
## cannot be dragged or piped, faceplates get touch-sized buttons.
func set_operator(on: bool) -> void:
	_operator = on
	if on:
		set_tool("")
		_widget_edit = false
	for n in _edit_nodes:
		if n is CanvasItem and is_instance_valid(n):
			(n as CanvasItem).visible = not on
	if _operate_btn != null:
		_operate_btn.set_pressed_no_signal(on)
		_operate_btn.text = "Leave operator mode" if on else "Operate"
	if _face != null:
		_face.set("touch", on)
	_hide_face()
	if mimic != null and mimic.has_method("fit"):
		mimic.call_deferred("fit")


func armed_bar() -> PanelContainer:
	return _armed_bar


## How far down the lens's own bars must start to clear the lesson panel
## (the bootcamp's heads-up card stands over the top of the canvas and would
## take their clicks).
func _hud_clear() -> float:
	var td: Variant = _view.get("_tutorial_director") if _view != null else null
	if td == null or not is_instance_valid(td):
		return 0.0
	var hud: Variant = td.get("_hud")
	if hud == null or not is_instance_valid(hud) or not (hud as Control).is_visible_in_tree():
		return 0.0
	var panel: Variant = (hud as Control).get("_panel")
	var r: Rect2 = (panel as Control).get_global_rect() if panel is Control else (hud as Control).get_global_rect()
	return maxf(r.end.y - global_position.y + 6.0, 0.0)


func _build_armed_bar() -> void:
	_armed_bar = PanelContainer.new()
	_armed_bar.name = "armed_bar"
	_armed_bar.add_theme_stylebox_override("panel", UITheme.chip_style(Color(0.20, 0.08, 0.04, 0.96)))
	_armed_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_armed_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_armed_bar.offset_top = 8.0
	_armed_bar.visible = false
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_armed_bar.add_child(row)
	_armed_lbl = Label.new()
	_armed_lbl.name = "armed_text"
	_armed_lbl.add_theme_color_override("font_color", Color(0.98, 0.50, 0.30))
	_armed_lbl.add_theme_font_override("font", UITheme.font("semibold"))
	row.add_child(_armed_lbl)
	var dis := Button.new()
	dis.name = "armed_disarm"
	dis.text = "Disarm"
	dis.tooltip_text = "Put every output to its safe state and stop sending"
	dis.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(dis)
	dis.pressed.connect(func() -> void:
		var hub: Node = _view.call("scada_hub") if _view != null else null
		if hub != null:
			hub.call("disarm", "by hand")
			refresh())
	row.add_child(dis)
	var open := Button.new()
	open.name = "armed_open"
	open.text = "Hardware…"
	open.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(open)
	open.pressed.connect(func() -> void:
		if _view != null:
			_view.call("open_outputs_panel"))
	row.add_child(open)
	add_child(_armed_bar)


func _refresh_armed_bar(hub: Node) -> void:
	if _armed_bar == null or hub == null or not hub.has_method("outputs_armed"):
		return
	var armed := bool(hub.call("outputs_armed"))
	var n := 0
	if armed:
		for l in hub.call("output_links"):
			if bool(l["enabled"]):
				n += 1
	var extra := _hud_clear()
	var sig := "%s|%d|%s|%d" % [armed, n, _alarm_bar.visible if _alarm_bar != null else false, int(extra)]
	if sig == _armed_sig:
		return
	_armed_sig = sig
	_armed_bar.visible = armed
	if armed:
		_armed_lbl.text = "ARMED  ·  %s driving real devices" % UiText.count(n, "output")
		_armed_bar.reset_size()
	# The bars stack: ARMED on top, alarms under it, the picture under both.
	var bars := (1 if armed else 0) + (1 if _alarm_bar != null and _alarm_bar.visible else 0)
	if _alarm_bar != null:
		_alarm_bar.offset_top = 8.0 + (44.0 if armed else 0.0) + extra
		_alarm_bar.reset_size()
	_armed_bar.offset_top = 8.0 + extra
	if mimic != null:
		mimic.offset_top = 52.0 * float(bars) if bars > 0 else 0.0


func _refresh_alarm_bar(hub: Node) -> void:
	if _alarm_bar == null or hub == null or not hub.has_method("alarm_summary"):
		return
	var sm: Dictionary = hub.call("alarm_summary")
	var sig := str(sm)
	if sig == _alarm_sig:
		return
	_alarm_sig = sig
	var n := int(sm.get("count", 0))
	_alarm_bar.visible = n > 0
	# The picture starts under the bars (the ARMED bar's refresh, which runs
	# next, sets the offsets for both).
	_armed_sig = ""
	if _alarms_btn != null:
		_alarms_btn.text = "Alarms" if n == 0 else "Alarms (%d)" % n
	if n == 0:
		return
	var col: Color = ALARM_COLORS.get(str(sm.get("worst", "medium")), UITheme.C_WARN)
	_alarm_lbl.text = str(sm.get("text", ""))
	_alarm_lbl.tooltip_text = _alarm_lbl.text
	_alarm_lbl.add_theme_color_override("font_color", col)
	_alarm_ack.disabled = int(sm.get("unack", 0)) == 0
	_alarm_bar.reset_size()


# ── dashboard widgets and screens (SCADA plan, Phase 8) ─────────────────────
# A scope has SCREENS; the first is the process picture. A screen holds
# WIDGETS bound to tags (MimicWidgets). Saved with the graph as
# `process_screens`. Widget edits are not in the graph's undo history.

var _screens: Dictionary = {}        # scope -> MimicWidgets data
var _screen_cur: Dictionary = {}     # scope -> screen id shown
var _wrev := 0
var _widget_tool := ""
var _widget_edit := false
var _widgets_menu: MenuButton = null
var _screen_bar: PanelContainer = null
var _screen_row: HBoxContainer = null
var _screen_sig := "?"
var _ask_dlg: ConfirmationDialog = null
const WIDGET_EDIT_ID := 100


func _hub() -> Node:
	return _view.call("scada_hub") if _view != null and _view.has_method("scada_hub") else null


func _toast(text: String) -> void:
	if _view != null and _view.has_method("_show_toast"):
		_view.call("_show_toast", text, 3.5)


func _sdata(scope: String) -> Dictionary:
	if not _screens.has(scope):
		_screens[scope] = MimicWidgets.default_data()
	return _screens[scope]


func _cur_screen() -> Dictionary:
	var scope := _scope()
	var scr := MimicWidgets.screen(_sdata(scope), str(_screen_cur.get(scope, "")))
	_screen_cur[scope] = str(scr.get("id", ""))
	return scr


func _touch() -> void:
	_wrev += 1
	_key = ""
	if _view != null and _view.has_method("_mark_dirty_for_autosave"):
		_view.call("_mark_dirty_for_autosave")
	# A widget's own card stays up through an edit of it.
	var keep := _face_id if _face != null and _face.visible else ""
	if _active:
		refresh(true)
	if MimicWidgets.is_widget_id(keep) and not widget(MimicWidgets.widget_id(keep)).is_empty():
		_show_widget_face(MimicWidgets.widget_id(keep))


func screens_data() -> Dictionary:
	var out := {}
	for scope in _screens:
		var d := MimicWidgets.clean(_screens[scope])
		if not MimicWidgets.is_default(d):
			out[str(scope)] = d
	return out


func set_screens_data(data: Variant) -> void:
	_screens = {}
	_screen_cur = {}
	if data is Dictionary:
		for scope in data:
			_screens[str(scope)] = MimicWidgets.clean(data[scope])
	_wrev += 1
	_key = ""
	if _active:
		refresh(true)


func screens() -> Array:
	return _sdata(_scope())["screens"]


func screen_id() -> String:
	return str(_cur_screen().get("id", ""))


func set_screen(id: String) -> void:
	_screen_cur[_scope()] = id
	_wrev += 1
	_key = ""
	_hide_face()
	if _active:
		refresh(true)
		mimic.call_deferred("fit")


func add_screen(screen_name: String = "", picture: bool = false) -> String:
	if _operator:
		return ""
	var sd := _sdata(_scope())
	if (sd["screens"] as Array).size() >= MimicWidgets.MAX_SCREENS:
		_toast("A process can have %d screens at most." % MimicWidgets.MAX_SCREENS)
		return ""
	var id := MimicWidgets.new_screen_id(sd)
	(sd["screens"] as Array).append({"id": id, "name": screen_name if not screen_name.is_empty() else "Screen %d" % ((sd["screens"] as Array).size() + 1),
		"picture": picture, "widgets": []})
	_touch()
	set_screen(id)
	return id


func rename_screen(id: String, screen_name: String) -> void:
	var nm := screen_name.strip_edges().substr(0, 40)
	if _operator or nm.is_empty():
		return
	for s in screens():
		if str(s["id"]) == id:
			s["name"] = nm
	_touch()


func set_screen_picture(id: String, on: bool) -> void:
	if _operator:
		return
	for s in screens():
		if str(s["id"]) == id:
			s["picture"] = on
	_touch()
	mimic.call_deferred("fit")


func remove_screen(id: String) -> bool:
	if _operator:
		return false
	if not MimicWidgets.remove_screen(_sdata(_scope()), id):
		_toast("The last screen stays.")
		return false
	_touch()
	mimic.call_deferred("fit")
	return true


func widgets() -> Array:
	return _cur_screen().get("widgets", [])


func widget(id: String) -> Dictionary:
	return MimicWidgets.find(_sdata(_scope()), id)


## What a widget shows now (MimicWidgets.state).
func widget_state(id: String) -> Dictionary:
	return ((mimic.get("state") as Dictionary).get("w", {}) as Dictionary).get(MimicWidgets.ID_PREFIX + id, {}) as Dictionary


func add_widget(kind: String, at: Vector2) -> String:
	if _operator:
		return ""
	var sd := _sdata(_scope())
	var n := 0
	for s in sd["screens"]:
		n += (s["widgets"] as Array).size()
	if n >= MimicWidgets.MAX_WIDGETS:
		_toast("That is the most widgets a process can hold (%d)." % MimicWidgets.MAX_WIDGETS)
		return ""
	var id := MimicWidgets.new_widget_id(sd)
	var w := MimicWidgets.make(id, kind, at)
	# As big on screen as designed, whatever the picture's zoom.
	var z := float(mimic.call("zoom")) if mimic != null else 1.0
	var k := clampf(1.0 / maxf(z, 0.01), 1.0, MimicWidgets.SIZE_MAX)
	w["w"] = float(w["w"]) * k
	w["h"] = float(w["h"]) * k
	(_cur_screen()["widgets"] as Array).append(w)
	_touch()
	return id


func set_widget(id: String, patch: Dictionary) -> void:
	if _operator:
		return
	var w := widget(id)
	if w.is_empty():
		return
	for k in patch:
		w[k] = patch[k]
	var n := MimicWidgets.normalized(w)
	for k in n:
		w[k] = n[k]
	_touch()


func remove_widget(id: String) -> void:
	if _operator:
		return
	MimicWidgets.remove(_sdata(_scope()), id)
	_hide_face()
	_touch()


func widget_edit() -> bool:
	return _widget_edit


func set_widget_edit(on: bool) -> void:
	_widget_edit = on and not _operator
	if _widgets_menu != null:
		var pm := _widgets_menu.get_popup()
		pm.set_item_checked(pm.get_item_index(WIDGET_EDIT_ID), _widget_edit)
	_hide_face()


func widget_tool() -> String:
	return _widget_tool


## Arm the place tool for a widget kind ("" = put it away).
func set_widget_tool(kind: String) -> void:
	set_tool("")
	if _operator or not (kind in MimicWidgets.KINDS):
		_widget_tool = ""
		return
	_widget_tool = kind
	mimic.call("set_tool", "place", "Click open space to set the %s down" % str(MimicWidgets.KIND_WORDS[kind]).to_lower())


func _place_widget(at: Vector2) -> void:
	var kind := _widget_tool
	_widget_tool = ""
	mimic.call("set_tool", "", "")
	var id := add_widget(kind, at)
	if id.is_empty():
		return
	if kind in MimicWidgets.NEEDS_TAG:
		pick_widget_tag(id)
	else:
		_show_widget_face(id)


## The scope's elements + this screen's widgets, as one doc.
func _doc_with_widgets(base: Dictionary, scr: Dictionary) -> Dictionary:
	var d := base
	if not bool(scr.get("picture", true)):
		d = {"pipes": [], "elements": [], "bounds": Rect2()}
	var els: Array = (d.get("elements", []) as Array).duplicate()
	var wb := Rect2()
	var first := true
	for w in scr.get("widgets", []):
		var e := MimicWidgets.element(w)
		els.append(e)
		var r := Rect2((e["pos"] as Vector2) - (e["size"] as Vector2) * 0.5, e["size"] as Vector2)
		wb = r if first else wb.merge(r)
		first = false
	var out := d.duplicate()
	out["elements"] = els
	if not bool(scr.get("picture", true)):
		# A board of widgets: never zoomed in past a comfortable size.
		var c := wb.get_center() if not first else Vector2.ZERO
		var sz := Vector2(maxf(wb.size.x, 900.0), maxf(wb.size.y, 520.0))
		out["bounds"] = Rect2(c - sz * 0.5, sz)
	return out


func _widget_states(scr: Dictionary) -> Dictionary:
	var hub := _hub()
	var book: Object = hub.call("book") if hub != null and hub.has_method("book") else null
	var read := func(tag: String) -> float:
		return float(hub.call("read_now", tag)) if hub != null else NAN
	var info := func(tag: String) -> Dictionary:
		var t: Dictionary = book.call("tag", tag) if book != null else {}
		if t.is_empty():
			return {"label": tag, "available": false}
		var o := {"label": str(t.get("label", tag)), "unit": str(t.get("unit", "")), "binary": ScadaTags.is_bool_kind(str(t.get("kind", ""))),
			"writable": bool(t.get("writable", false)), "available": bool(t.get("available", true))}
		if t.has("hi"):
			o["lo"] = float(t.get("lo", 0.0))
			o["hi"] = float(t["hi"])
		return o
	var trend := func(tag: String) -> PackedFloat32Array:
		return hub.call("trend", tag, 2.0, 60) if hub != null and hub.has_method("trend") else PackedFloat32Array()
	var sname := func(sid: String) -> String:
		for s in screens():
			if str(s["id"]) == sid:
				return str(s["name"])
		return ""
	var out := {}
	for w in scr.get("widgets", []):
		out[MimicWidgets.ID_PREFIX + str(w["id"])] = MimicWidgets.state(w, read, info, trend, sname)
	return out


func _on_widget(e: Dictionary) -> void:
	var wid := MimicWidgets.widget_id(str(e["id"]))
	var w := widget(wid)
	if w.is_empty():
		return
	var kind := str(w["kind"])
	var unbound := (kind in MimicWidgets.NEEDS_TAG and str(w["tag"]).is_empty()) or (kind == "nav" and str(w["screen"]).is_empty())
	if not _operator and (_widget_edit or unbound):
		_show_widget_face(wid)
		return
	if kind in ["button", "slider", "nav"]:
		_hide_face()
		var frac := MimicSymbols.slider_frac(mimic.call("element_rect", e), (mimic.get("click_pos") as Vector2).x)
		var act := MimicWidgets.press(w, widget_state(wid), frac)
		if act.has("screen"):
			set_screen(str(act["screen"]))
		elif act.has("tag"):
			var hub := _hub()
			if hub == null or not bool(hub.call("command", str(act["tag"]), float(act["value"]))):
				var why := str(hub.get("last_refusal")) if hub != null else ""
				_toast(why if not why.is_empty() else "That value cannot be set from here: it is a reading, not a switch or a setting.")
			refresh()
		return
	if kind == "text":
		_hide_face()
		return
	_show_widget_face(wid)


func _show_widget_face(wid: String) -> void:
	var id := MimicWidgets.ID_PREFIX + wid
	var e: Dictionary = mimic.call("element_by_id", id)
	var fp := _widget_faceplate(id)
	if e.is_empty() or fp.is_empty():
		_hide_face()
		return
	if _face == null:
		_face = PanelContainer.new()
		_face.set_script(FaceScript)
		_face.name = "ProcessFaceplate"
		add_child(_face)
		_face.connect("dismissed", func() -> void: _face_id = "")
	_face_id = id
	mimic.set("selected_id", id)
	_face.call("show_for", fp, mimic.global_position + (mimic.call("element_rect", e) as Rect2).get_center())


func _widget_faceplate(id: String) -> Dictionary:
	var wid := MimicWidgets.widget_id(id)
	var w := widget(wid)
	if w.is_empty():
		return {}
	var st := widget_state(wid)
	var kind := str(w["kind"])
	var tag := str(w["tag"])
	var hub := _hub()
	var lines: Array = []
	var btns: Array = []
	var trend := {}
	if kind in MimicWidgets.NEEDS_TAG:
		lines.append(["Tag", tag if not tag.is_empty() else "none yet"])
		if kind in ["gauge", "bar", "slider", "trend"] and not tag.is_empty():
			lines.append(["Scale", "%s to %s%s" % [MimicWidgets.fmt(float(st.get("lo", 0.0))), MimicWidgets.fmt(float(st.get("hi", 100.0))),
				"" if float(w["hi"]) > float(w["lo"]) else " (automatic)"]])
		if not tag.is_empty() and hub != null and hub.has_method("trend"):
			trend = {"label": "Last 2 h", "series": [{"values": hub.call("trend", tag), "color": Color(0.35, 0.78, 0.98)}]}
	var editing := not _operator and (_widget_edit or (kind in MimicWidgets.NEEDS_TAG and tag.is_empty()) or (kind == "nav" and str(w["screen"]).is_empty()))
	if editing:
		if kind in MimicWidgets.NEEDS_TAG:
			btns.append({"id": "w_tag", "text": "Tag…", "tip": "Pick what this shows.", "on_press": func() -> void: pick_widget_tag(wid)})
		if kind == "nav":
			btns.append({"id": "w_screen", "text": "Next screen", "tip": "Point it at the next screen in the list.", "on_press": func() -> void:
				_cycle_nav(wid)})
		if kind == "text":
			btns.append({"id": "w_text", "text": "Text…", "on_press": func() -> void:
				_ask("The text", str(w["text"]), func(t: String) -> void: set_widget(wid, {"text": t}))})
		else:
			btns.append({"id": "w_name", "text": "Name…", "tip": "Its own name (empty = the tag's).", "on_press": func() -> void:
				_ask("Its name (empty = the tag's own)", str(w["label"]), func(t: String) -> void: set_widget(wid, {"label": t}))})
		if kind in ["gauge", "bar", "slider", "trend"]:
			btns.append({"id": "w_range", "text": "Scale…", "tip": "The ends of its scale, as \"0 to 100\". Empty = automatic.", "on_press": func() -> void:
				_ask("Scale, as \"0 to 100\" (empty = automatic)", ("%s to %s" % [MimicWidgets.fmt(float(w["lo"])), MimicWidgets.fmt(float(w["hi"]))]) if float(w["hi"]) > float(w["lo"]) else "",
					func(t: String) -> void: set_widget(wid, parse_range(t)))})
		btns.append({"id": "w_smaller", "text": "Smaller", "on_press": func() -> void:
			set_widget(wid, {"w": float(w["w"]) / 1.2, "h": float(w["h"]) / 1.2})})
		btns.append({"id": "w_bigger", "text": "Bigger", "on_press": func() -> void:
			set_widget(wid, {"w": float(w["w"]) * 1.2, "h": float(w["h"]) * 1.2})})
		btns.append({"id": "w_remove", "text": "Remove", "on_press": func() -> void: remove_widget(wid)})
	elif not tag.is_empty():
		btns.append({"id": "w_trends", "text": "Open in Trends", "on_press": func() -> void:
			_hide_face()
			if _view != null and _view.has_method("open_trend_window"):
				_view.call("open_trend_window", tag)})
	var title := str(st.get("label", ""))
	if title.is_empty():
		title = str(MimicWidgets.KIND_WORDS.get(kind, kind))
	return {"id": id, "title": title, "subtitle": str(MimicWidgets.KIND_WORDS.get(kind, kind)), "trend": trend,
		"state": str(st.get("text", "")), "state_color": MimicSymbols.TEXT if bool(st.get("avail", false)) else MimicSymbols.WARN,
		"lines": lines, "buttons": btns}


## "0 to 100", "0, 100", "0 100" → {lo, hi}; anything else = automatic.
static func parse_range(text: String) -> Dictionary:
	var t := text.to_lower().replace(" to ", " ").replace(",", " ").replace("…", " ").replace("..", " ")
	var nums: Array = []
	for p in t.split(" ", false):
		if p.is_valid_float():
			nums.append(p.to_float())
	if nums.size() >= 2 and float(nums[1]) > float(nums[0]):
		return {"lo": float(nums[0]), "hi": float(nums[1])}
	return {"lo": 0.0, "hi": 0.0}


func _cycle_nav(wid: String) -> void:
	var w := widget(wid)
	var ids: Array = []
	for s in screens():
		if str(s["id"]) != screen_id():
			ids.append(str(s["id"]))
	if ids.is_empty():
		_toast("Add another screen first (the + beside the screen tabs).")
		return
	var i := ids.find(str(w["screen"]))
	set_widget(wid, {"screen": ids[(i + 1) % ids.size()]})


## The tag list in pick mode for a widget (buttons and sliders: only tags
## the game can set).
func pick_widget_tag(wid: String) -> void:
	if _operator or _view == null or not _view.has_method("open_tag_browser"):
		return
	_hide_face()
	var w := widget(wid)
	var writes := str(w.get("kind", "")) in MimicWidgets.WRITES
	_view.call("open_tag_browser", {"title": "Pick what it switches or sets" if writes else "Pick what it shows",
		"writable": writes,
		"pick": func(t: Dictionary) -> void:
			set_widget(wid, {"tag": str(t.get("id", ""))})})


## A one-line question (a name, a text, a scale).
func _ask(title: String, initial: String, done: Callable) -> void:
	if _ask_dlg != null and is_instance_valid(_ask_dlg):
		_ask_dlg.queue_free()
	var back := _face_id if _face != null and _face.visible else ""
	_hide_face()
	_ask_dlg = ConfirmationDialog.new()
	_ask_dlg.name = "ProcessAsk"
	_ask_dlg.title = title
	_ask_dlg.min_size = Vector2i(420, 0)
	var le := LineEdit.new()
	le.name = "ask_text"
	le.text = initial
	le.select_all_on_focus = true
	_ask_dlg.add_child(le)
	_ask_dlg.register_text_enter(le)
	add_child(_ask_dlg)
	_ask_dlg.confirmed.connect(func() -> void:
		done.call(le.text)
		_ask_dlg.queue_free()
		if MimicWidgets.is_widget_id(back) and not widget(MimicWidgets.widget_id(back)).is_empty():
			_show_widget_face(MimicWidgets.widget_id(back)))
	_ask_dlg.canceled.connect(func() -> void: _ask_dlg.queue_free())
	_ask_dlg.popup_centered()
	le.grab_focus()


func ask_dialog() -> ConfirmationDialog:
	return _ask_dlg if _ask_dlg != null and is_instance_valid(_ask_dlg) else null


# The screen tabs (top-left of the picture).

func _on_screen_menu(mid: int) -> void:
	var here := screen_id()
	if mid == 1:
		_ask("Screen name", str(_cur_screen().get("name", "")), func(t: String) -> void: rename_screen(here, t))
	elif mid == 2:
		set_screen_picture(here, not bool(_cur_screen().get("picture", true)))
	elif mid == 3:
		remove_screen(here)


func screen_bar() -> PanelContainer:
	return _screen_bar


func _build_screen_bar() -> void:
	_screen_bar = PanelContainer.new()
	_screen_bar.name = "screen_bar"
	_screen_bar.add_theme_stylebox_override("panel", UITheme.chip_style(Color(0.07, 0.09, 0.14, 0.94)))
	_screen_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_screen_bar.offset_left = 12.0
	_screen_bar.offset_top = 8.0
	_screen_row = HBoxContainer.new()
	_screen_row.add_theme_constant_override("separation", 6)
	_screen_bar.add_child(_screen_row)
	add_child(_screen_bar)


func _refresh_screen_bar() -> void:
	if _screen_bar == null:
		return
	var scs := screens()
	var cur := screen_id()
	var bars := (1 if _armed_bar != null and _armed_bar.visible else 0) + (1 if _alarm_bar != null and _alarm_bar.visible else 0)
	_screen_bar.offset_top = 8.0 + 52.0 * float(bars) + _hud_clear()
	if _face != null:
		_face.set("top_clear", (_screen_bar.offset_top + _screen_bar.size.y + 4.0) if _screen_bar.visible else 52.0 * float(bars))
	var sig := "%s|%s|%s" % [cur, _operator, str(scs.map(func(s: Dictionary) -> String: return "%s=%s=%s" % [s["id"], s["name"], s["picture"]]))]
	if sig == _screen_sig:
		return
	_screen_sig = sig
	# In operator mode with one screen there is nothing to pick.
	_screen_bar.visible = not (_operator and scs.size() <= 1)
	for c in _screen_row.get_children():
		_screen_row.remove_child(c)
		c.queue_free()
	for s in scs:
		var b := Button.new()
		b.name = "screen_%s" % str(s["id"])
		b.text = str(s["name"])
		b.toggle_mode = true
		b.button_pressed = str(s["id"]) == cur
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		var sid := str(s["id"])
		b.pressed.connect(func() -> void: set_screen(sid))
		_screen_row.add_child(b)
	if _operator:
		_screen_bar.reset_size()
		return
	var add := Button.new()
	add.name = "screen_add"
	add.text = "+"
	add.tooltip_text = "Add a screen: a blank board for gauges, trends and buttons."
	add.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(add)
	add.pressed.connect(func() -> void: add_screen())
	_screen_row.add_child(add)
	var mb := MenuButton.new()
	mb.name = "screen_menu"
	mb.text = "…"
	mb.flat = false
	mb.tooltip_text = "This screen: rename, show the process picture on it, remove."
	mb.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(mb)
	var pm := mb.get_popup()
	pm.add_item("Rename this screen…", 1)
	pm.add_check_item("Show the process picture on it", 2)
	pm.set_item_checked(pm.get_item_index(2), bool(_cur_screen().get("picture", true)))
	pm.add_separator()
	pm.add_item("Remove this screen", 3)
	pm.id_pressed.connect(_on_screen_menu)
	_screen_row.add_child(mb)
	_screen_bar.reset_size()


# ── equipment pictures (MimicIcons) ─────────────────────────────────────────

## Every node's view: "side" | "front" | "three_quarter" | "top" | "boxes".
func set_icon_view(view: String) -> void:
	if not (view in MimicIcons.VIEWS or view == MimicIcons.VIEW_BOXES):
		return
	_icon_view = view
	_sync_icon_opt()
	refresh(true)


func icon_view() -> String:
	return _icon_view


## One node's own view ("" = the bar's).
func set_node_icon_view(id: String, view: String) -> void:
	if view.is_empty() or view == _icon_view:
		_icon_over.erase(id)
	else:
		_icon_over[id] = view
	_key = ""
	_reshow_face()


func icon_view_of(id: String) -> String:
	return str(_icon_over.get(id, _icon_view))


func icons_data() -> Dictionary:
	return {"view": _icon_view, "per": _icon_over.duplicate(), "flow": _flow_dir}


## Which way the picture reads (saved with the pictures' views).
func set_flow_dir(dir: String) -> void:
	dir = MimicGraphSource.FLOW_DOWN if dir == MimicGraphSource.FLOW_DOWN else MimicGraphSource.FLOW_RIGHT
	if dir == _flow_dir:
		return
	_flow_dir = dir
	_sync_flow_opt()
	_last_scope = ""
	refresh(true)
	if _view != null and _view.has_method("_mark_dirty_for_autosave"):
		_view.call("_mark_dirty_for_autosave")


func flow_dir() -> String:
	return _flow_dir


## Moved things are kept per scope and per way the picture reads.
func _pin_scope() -> String:
	return _scope() if _flow_dir == MimicGraphSource.FLOW_RIGHT else _scope() + "|down"


func _sync_flow_opt() -> void:
	if _flow_opt == null:
		return
	_flow_opt.select(1 if _flow_dir == MimicGraphSource.FLOW_DOWN else 0)


func set_icons_data(data: Variant) -> void:
	if not (data is Dictionary):
		return
	var v := str((data as Dictionary).get("view", MimicIcons.VIEW_SIDE))
	_icon_view = v if v in MimicIcons.VIEWS or v == MimicIcons.VIEW_BOXES else MimicIcons.VIEW_SIDE
	_icon_over = {}
	_flow_dir = MimicGraphSource.FLOW_DOWN if str((data as Dictionary).get("flow", "")) == MimicGraphSource.FLOW_DOWN else MimicGraphSource.FLOW_RIGHT
	_sync_flow_opt()
	var per: Variant = (data as Dictionary).get("per", {})
	if per is Dictionary:
		for k in per:
			_icon_over[str(k)] = str(per[k])
	_sync_icon_opt()
	_key = ""


func _sync_icon_opt() -> void:
	if _icon_opt == null:
		return
	for i in _icon_opt.item_count:
		if str(_icon_opt.get_item_metadata(i)) == _icon_view:
			_icon_opt.select(i)


## A node's model: its own `model_id`, else its placed prop's (with that
## prop's build options, so a designed vehicle draws as itself).
## [model id, extras]; ["", {}] when it has none.
func _model_of(it: Dictionary) -> Array:
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	var mid := str(sp.get("model_id", ""))
	if not mid.is_empty():
		return [mid, {}]
	var pid := str(sp.get("bound_prop_id", it.get("bound_prop_id", "")))
	if pid.is_empty():
		return ["", {}]
	if _prop_models.has(pid):
		return _prop_models[pid]
	var res := ["", {}]
	var main: Node = _view.call("_get_scene_main_node") if _view != null and _view.has_method("_get_scene_main_node") else null
	var loader: Node = _view.call("_find_terrain_loader", main) if main != null and _view.has_method("_find_terrain_loader") else null
	if loader != null and loader.has_method("get_prop_record"):
		var rec: Dictionary = loader.call("get_prop_record", pid)
		if not rec.is_empty() and not str(rec.get("model_id", "")).is_empty():
			res = [str(rec["model_id"]), PlacedPropRuntime.model_extras(rec)]
	_prop_models[pid] = res
	return res


## [icons {id: Texture2D}, glyphs {id: Texture2D}, aspects {id: float}] for
## the scope's nodes; `_icon_sig` changes when a picture lands.
func _icon_maps(items: Array, rev: int) -> Array:
	if rev != _prop_models_rev:
		_prop_models_rev = rev
		_prop_models = {}
	var svc: Node = _canvas.get("model_preview_service") if _canvas != null else null
	var pics := {}
	var glyphs := {}
	var aspects := {}
	var sig := PackedStringArray()
	for it in items:
		if not (it is Dictionary):
			continue
		var kind := MimicGraphSource.kind_of(it)
		if not (kind in MimicGraphSource.ICON_KINDS):
			continue
		var id := str(it.get("id", ""))
		var view := icon_view_of(id)
		var m := _model_of(it)
		var tex: Texture2D = null
		if not str(m[0]).is_empty() and view != MimicIcons.VIEW_BOXES and svc != null and svc.has_method("get_icon"):
			tex = svc.call("get_icon", str(m[0]), view, m[1]) as Texture2D
			if tex == null:
				tex = _last_pic.get(id) as Texture2D
			else:
				_last_pic[id] = tex
		if tex != null:
			pics[id] = tex
			aspects[id] = MimicIcons.aspect(tex)
			# Signed by the picture itself: when a new view's picture replaces
			# the stand-in, the picture is rebuilt with it.
			sig.append("%s:%d" % [id, tex.get_instance_id()])
		elif kind != "group":
			var g := MimicIcons.glyph_for(it)
			if not g.is_empty():
				glyphs[id] = UiIcons.icon(g, 96, 1.75)
	_icon_sig = ",".join(sig)
	return [pics, glyphs, aspects]
