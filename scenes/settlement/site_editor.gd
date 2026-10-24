extends Control

## THE SITE EDITOR — select, move, reshape, name and define camps and NPC
## spaces, from the festival (settlement) view AND from the graph's Site Plan.
##
## One editor for two surfaces: everything here works in SCREEN space through
## two callables the host hands over, so the festival view (a perspective
## camera over the 3D world) and the Site Plan (a lens over the graph canvas)
## share every rule, every pixel threshold and every commit:
##   ground_at(screen: Vector2) -> Vector2   world XZ under the pointer, or INF
##   to_screen(world_xz: Vector2) -> Vector2 where a ground point draws, or INF
## and, optionally,
##   pick_prop(screen: Vector2) -> String    a placed prop's id under the pointer
##
## What it edits, and where each edit lands:
##   camp   CampAreaLayer record   → TerrainLoader.update_camp_area (outline,
##          name, people, style); its seeded beds + kitchen follow the outline
##          (FestivalSeedLayout.follow_camp) and the graph re-syncs;
##   space  an AREA space          → SpaceRegistry.set_space_target / fields;
##          NpcSpaceTagRow for type, capacity and the venue line;
##   prop   a placed prop          → PlacedPropService.update_prop_record (move);
##          NpcSpaceTagRow to tag it as a space (a stage, a fire circle);
##   building an OSM building      → NpcSpaceTagRow (tag only).
## Tools: Select (click picks, drag inside = move, drag a corner = reshape,
## drag an edge's + = add a corner, the ⟳ knob = rotate, Del = delete),
## Draw space (click corners, click the first or Enter to close), Tag object
## (click a prop or building). Ctrl+Z undoes this editor's own edits.
##
## It edits PLACES, never people — the settlement view's no-orders rule holds.
## No class_name: the ui_compile selftest sweeps scenes/settlement/.

signal edit_committed(kind: String, id: String)
signal selection_changed(sel: Dictionary)
signal tool_changed(tool: String)

const TOOL_SELECT := "select"
const TOOL_DRAW := "draw"
const TOOL_TAG := "tag"
const HANDLE_PX := 9.0
const ROTATE_KNOB_PX := 46.0
const CLOSE_PX := 12.0
const DRAG_SLOP_PX := 4.0
const C_CAMP := Color(1.0, 0.72, 0.25)
const C_SEL := Color(1.0, 1.0, 1.0)
const C_HANDLE := Color(1.0, 0.86, 0.3)
const C_DRAW := Color(0.45, 0.9, 1.0)
const UNDO_MAX := 40

var host_name := "site_editor"
## Full-screen hosts (the festival view) keep the overlay above the timeline.
var clip_to_timeline := false
var _timeline: Node = null
## Nothing is drawn below this screen y (the timeline's top edge); INF = no clip.
var _clip_y := INF
var _main: Node = null
var _loader: Node = null
var _ground_at: Callable = Callable()
var _to_screen: Callable = Callable()
var _pick_prop: Callable = Callable()
var active := false
var tool := TOOL_SELECT
var new_space_type := "kitchen"

## {kind, id, ...}; camp/space carry `poly` (the live outline being edited).
var _sel: Dictionary = {}
var _drag: Dictionary = {}       # {mode, start_screen, start_world, orig, idx, moved}
var _draw_pts: PackedVector2Array = PackedVector2Array()
var _hover_world := Vector2.INF
var _undo: Array = []
var _last_pick_xz := Vector2.INF
var _last_pick_i := 0

var _dock: PanelContainer = null
var _dock_body: VBoxContainer = null
var _tool_btns: Dictionary = {}
var _type_pick: OptionButton = null
var _hint: Label = null
var _flash_gen := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)
	_build_dock()


## Hand over the surface. Call again whenever the surface changes.
func bind(main: Node, ground_at: Callable, to_screen: Callable, pick_prop: Callable = Callable()) -> void:
	_main = main
	_loader = TerrainSurfaceQuery.find_terrain_loader(main) if main != null else null
	_ground_at = ground_at
	_to_screen = to_screen
	_pick_prop = pick_prop


func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	visible = on
	set_process(on)
	if not on:
		_cancel_drag()
		_draw_pts = PackedVector2Array()
		_select({})
	_refresh_dock()
	queue_redraw()


func set_tool(t: String) -> void:
	if not [TOOL_SELECT, TOOL_DRAW, TOOL_TAG].has(t):
		return
	tool = t
	_draw_pts = PackedVector2Array()
	_cancel_drag()
	for k in _tool_btns.keys():
		(_tool_btns[k] as Button).button_pressed = k == t
	_set_hint()
	tool_changed.emit(t)
	queue_redraw()


func selection() -> Dictionary:
	return _sel


func is_busy() -> bool:
	return not _drag.is_empty() or not _draw_pts.is_empty()


func _process(_delta: float) -> void:
	_clip_y = INF
	if clip_to_timeline:
		if _timeline == null or not is_instance_valid(_timeline):
			var main := get_tree().current_scene
			_timeline = main.get_node_or_null("UILayer/TimelineUI") if main != null else null
		if _timeline is Control and (_timeline as Control).is_visible_in_tree():
			_clip_y = (_timeline as Control).get_global_rect().position.y
	# The world moves under us (the camera, other editors); outlines are read
	# from the data every frame — a few hundred points.
	if not _sel.is_empty() and _drag.is_empty():
		_reload_selected_poly()
	# Redraw only when something drawn could have moved: the view (two
	# reference points through the host's own projection catch pan, zoom and
	# orbit), the pointer, a gesture, the selection or the data. _draw walks
	# every camp and space and projects each vertex, which was a per-frame
	# cost whether or not anything changed. A half-second fallback covers
	# data edited elsewhere without a count change.
	_redraw_fallback -= _delta
	var sig := _redraw_signature()
	if sig != _redraw_sig or not _drag.is_empty() or not _draw_pts.is_empty() or _redraw_fallback <= 0.0:
		_redraw_sig = sig
		_redraw_fallback = 0.5
		queue_redraw()


var _redraw_sig := ""
var _redraw_fallback := 0.0


func _redraw_signature() -> String:
	var a: Variant = _to_screen.call(Vector2.ZERO) if _to_screen.is_valid() else null
	var b: Variant = _to_screen.call(Vector2(100.0, 100.0)) if _to_screen.is_valid() else null
	var n_camps := 0
	var areas: Variant = _loader.get("camp_areas") if _loader != null and is_instance_valid(_loader) else null
	if areas != null:
		n_camps = (areas.get("areas") as Array).size()
	var reg: Variant = _loader.get("npc_spaces") if _loader != null and is_instance_valid(_loader) else null
	var rev := int(reg.get("revision")) if reg != null else -1
	return "%s|%s|%s|%s|%s|%d|%d|%s|%.0f" % [str(a), str(b), str(get_local_mouse_position()),
		str(_hover_world), str(_sel.get("id", "")), n_camps, rev, tool, _clip_y]


# ---------------------------------------------------------------------------
# Input (the host forwards; true = consumed)
# ---------------------------------------------------------------------------

func handle_input(event: InputEvent) -> bool:
	if not active:
		return false
	if event is InputEventKey and event.pressed and not event.echo:
		return _handle_key(event as InputEventKey)
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_hover_world = _ground(mm.position)
		if not _drag.is_empty():
			_drag_to(mm.position)
			return true
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if _over_dock(mb.position):
			return false
		if mb.pressed:
			return _press(mb.position, mb.double_click)
		if not _drag.is_empty():
			_release(mb.position)
			return true
	return false


func _handle_key(k: InputEventKey) -> bool:
	if k.ctrl_pressed and k.keycode == KEY_Z:
		undo()
		return true
	match k.keycode:
		KEY_ESCAPE:
			if not _drag.is_empty():
				_cancel_drag()
				return true
			if not _draw_pts.is_empty():
				_draw_pts = PackedVector2Array()
				return true
			if tool != TOOL_SELECT:
				set_tool(TOOL_SELECT)
				return true
			if not _sel.is_empty():
				_select({})
				return true
			return false   # the host leaves edit mode / the view
		KEY_ENTER, KEY_KP_ENTER:
			if tool == TOOL_DRAW and _draw_pts.size() >= 3:
				_finish_draw()
				return true
		KEY_BACKSPACE:
			if tool == TOOL_DRAW and not _draw_pts.is_empty():
				_draw_pts.remove_at(_draw_pts.size() - 1)
				return true
		KEY_DELETE:
			if not _sel.is_empty() and get_viewport().gui_get_focus_owner() == null:
				delete_selected()
				return true
	return false


func _press(s: Vector2, double: bool) -> bool:
	match tool:
		TOOL_DRAW:
			var w := _ground(s)
			if w == Vector2.INF:
				return true
			if _draw_pts.size() >= 3 and (s.distance_to(_screen(_draw_pts[0])) <= CLOSE_PX or double):
				_finish_draw()
			else:
				_draw_pts.append(w)
			return true
		TOOL_TAG:
			_tag_pick(s)
			return true
	# Select.
	if _sel.has("poly"):
		var poly: PackedVector2Array = _sel["poly"]
		var knob := _rotate_knob(poly)
		if knob != Vector2.INF and s.distance_to(knob) <= HANDLE_PX + 2.0:
			_begin_drag("rotate", s, -1)
			return true
		for i in poly.size():
			if s.distance_to(_screen(poly[i])) <= HANDLE_PX:
				if double and poly.size() > 3:
					_push_undo()
					poly.remove_at(i)
					_sel["poly"] = poly
					_commit_poly()
				else:
					_begin_drag("vertex", s, i)
				return true
		for i2 in poly.size():
			var mid := (_screen(poly[i2]) + _screen(poly[(i2 + 1) % poly.size()])) * 0.5
			if s.distance_to(mid) <= HANDLE_PX:
				var w2 := (poly[i2] + poly[(i2 + 1) % poly.size()]) * 0.5
				poly.insert(i2 + 1, w2)
				_sel["poly"] = poly
				_begin_drag("vertex", s, i2 + 1, true)
				return true
		var gw := _ground(s)
		if gw != Vector2.INF and Geometry2D.is_point_in_polygon(gw, poly):
			# A drag moves it; a click that does not move cycles to whatever
			# is underneath (handled on release).
			_begin_drag("move", s, -1)
			_drag["cycle"] = true
			return true
	if _sel.get("kind", "") == "prop":
		var pid := _prop_at(s)
		if pid == str(_sel.get("id", "")):
			_begin_drag("move_prop", s, -1)
			return true
	return _pick_at(s, false)


func _release(s: Vector2) -> void:
	var d := _drag
	_drag = {}
	if not bool(d.get("moved", false)):
		if str(d.get("mode", "")) == "vertex" and bool(d.get("inserted", false)):
			_reload_selected_poly()   # an un-dragged + adds nothing
		elif bool(d.get("cycle", false)):
			_pick_at(s, true)
		return
	match str(d.get("mode", "")):
		"move_prop":
			_commit_prop_move(d)
		_:
			_commit_poly()


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

## Everything editable under the pointer — placed objects, spaces and camps —
## smallest footprint first, a camp's own beds and kitchen last. Clicking the
## same spot again cycles.
func _pick_at(s: Vector2, cycle: bool) -> bool:
	var pid := _prop_at(s)
	var gw := _ground(s)
	var cands: Array = []
	if not pid.is_empty():
		cands.append({"kind": "prop", "id": pid, "area": _prop_area(pid), "rank": 0})
	if gw != Vector2.INF:
		for c in _camps():
			var cd: Dictionary = c
			var poly: PackedVector2Array = cd.get("polygon", PackedVector2Array())
			if poly.size() >= 3 and Geometry2D.is_point_in_polygon(gw, poly):
				cands.append({"kind": "camp", "id": str(cd["id"]), "area": CampAreaLayer.polygon_area(poly),
					"rank": 0})
		var reg := _registry()
		if reg != null:
			for rec in reg.spaces:
				var r: Dictionary = rec
				var tgt: Dictionary = r.get("target", {})
				if str(tgt.get("kind", "")) != "area":
					continue
				var sp := SpaceRegistry.poly_points(tgt.get("poly", []) as Array)
				if sp.size() < 3 or not Geometry2D.is_point_in_polygon(gw, sp):
					continue
				# A camp's own beds / kitchen rank after the camp itself.
				var linked := not str(r.get("camp_id", "")).is_empty()
				cands.append({"kind": "space", "id": str(r["id"]),
					"area": CampAreaLayer.polygon_area(sp), "rank": 1 if linked else 0})
	if cands.is_empty():
		_select({})
		_last_pick_xz = Vector2.INF
		return false
	# Smallest footprint first (a tent prop in a camp, the stage on the plaza,
	# then the camp), a camp's own beds and kitchen after everything else.
	cands.sort_custom(func(a, b) -> bool:
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) < int(b["rank"])
		return float(a["area"]) < float(b["area"]))
	var i := 0
	if cycle:
		_last_pick_i = (_last_pick_i + 1) % cands.size()
		i = _last_pick_i
	else:
		_last_pick_i = 0
	_last_pick_xz = gw
	_select({"kind": str(cands[i]["kind"]), "id": str(cands[i]["id"])})
	return true


func _prop_area(pid: String) -> float:
	var node := PlacedPropRuntime.find_by_prop_id(_main, pid)
	if node == null:
		return 1.0
	var bb: AABB = node.get_world_pick_aabb()
	return maxf(bb.size.x * bb.size.z, 1.0)


func _tag_pick(s: Vector2) -> void:
	var pid := _prop_at(s)
	if not pid.is_empty():
		_select({"kind": "prop", "id": pid})
		return
	var gw := _ground(s)
	if gw != Vector2.INF and _loader != null and _loader.has_method("pick_building_at_world"):
		var b: Dictionary = _loader.call("pick_building_at_world", gw.x, gw.y)
		if bool(b.get("valid", false)):
			var pts: PackedVector2Array = b.get("points", PackedVector2Array())
			var tag := BuildingBuilder.building_tag(pts) if pts.size() >= 3 else ""
			if not tag.is_empty():
				_select({"kind": "building", "id": tag, "poly": b.get("points", PackedVector2Array())})
				return
	_flash("Nothing to tag there — click a placed object or a building")


## The placed prop under the pointer — only when the ground point under the
## pointer is inside that prop's own footprint. A slanted lens ray crosses the
## pick box of a tall prop far beyond what you clicked (the effigy, 100 m off,
## won clicks on the camps behind it in Site Plan).
func _prop_at(s: Vector2) -> String:
	if not _pick_prop.is_valid():
		return ""
	var pid := str(_pick_prop.call(s))
	if pid.is_empty():
		return ""
	var gw := _ground(s)
	var node := PlacedPropRuntime.find_by_prop_id(_main, pid)
	if gw == Vector2.INF or node == null:
		return pid
	var bb: AABB = node.get_world_pick_aabb().grow(1.0)
	return pid if gw.x >= bb.position.x and gw.x <= bb.end.x and gw.y >= bb.position.z and gw.y <= bb.end.z else ""


# ---------------------------------------------------------------------------
# Selection + drags
# ---------------------------------------------------------------------------

func _select(sel: Dictionary) -> void:
	_sel = sel.duplicate()
	_reload_selected_poly()
	_refresh_dock()
	selection_changed.emit(_sel)
	queue_redraw()


func _reload_selected_poly() -> void:
	match str(_sel.get("kind", "")):
		"camp":
			var rec := _camp_rec(str(_sel["id"]))
			if rec.is_empty():
				_sel = {}
				_refresh_dock()
				return
			_sel["poly"] = (rec.get("polygon", PackedVector2Array()) as PackedVector2Array).duplicate()
		"space":
			var reg := _registry()
			var r: Dictionary = reg.find_by_id(str(_sel["id"])) if reg != null else {}
			if r.is_empty():
				_sel = {}
				_refresh_dock()
				return
			_sel["poly"] = SpaceRegistry.poly_points((r.get("target", {}) as Dictionary).get("poly", []) as Array)


func _begin_drag(mode: String, s: Vector2, idx: int, inserted: bool = false) -> void:
	_drag = {"mode": mode, "start_screen": s, "start_world": _ground(s), "idx": idx, "moved": false,
		"inserted": inserted, "orig": (_sel.get("poly", PackedVector2Array()) as PackedVector2Array).duplicate()}
	if mode == "move_prop":
		var rec := PlacedPropService.get_prop_record(_main, str(_sel.get("id", "")))
		_drag["orig_xz"] = Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		_drag["to_xz"] = _drag["orig_xz"]


func _drag_to(s: Vector2) -> void:
	if not bool(_drag["moved"]) and s.distance_to(_drag["start_screen"]) < DRAG_SLOP_PX:
		return
	if not bool(_drag["moved"]):
		_push_undo()
		_drag["moved"] = true
	var w := _ground(s)
	var w0: Vector2 = _drag["start_world"]
	if w == Vector2.INF or w0 == Vector2.INF:
		return
	var orig: PackedVector2Array = _drag["orig"]
	match str(_drag["mode"]):
		"move":
			var out := PackedVector2Array()
			for v in orig:
				out.append(v + (w - w0))
			_sel["poly"] = out
		"vertex":
			var p := orig.duplicate()
			p[int(_drag["idx"])] = w
			_sel["poly"] = p
		"rotate":
			var c := CampAreaLayer._inner_point(orig)
			var a := (w - c).angle() - (w0 - c).angle()
			var out2 := PackedVector2Array()
			for v2 in orig:
				out2.append(c + (v2 - c).rotated(a))
			_sel["poly"] = out2
		"move_prop":
			_drag["to_xz"] = (_drag["orig_xz"] as Vector2) + (w - w0)


func _cancel_drag() -> void:
	if _drag.is_empty():
		return
	if bool(_drag.get("moved", false)) and not _undo.is_empty():
		_undo.pop_back()
	_drag = {}
	_reload_selected_poly()


# ---------------------------------------------------------------------------
# Commits
# ---------------------------------------------------------------------------

func _commit_poly() -> void:
	var poly: PackedVector2Array = _sel.get("poly", PackedVector2Array())
	if poly.size() < 3 or CampAreaLayer.polygon_area(poly) < CampAreaLayer.MIN_AREA_M2:
		_flash("Too small — undone")
		undo()
		return
	match str(_sel.get("kind", "")):
		"camp":
			if _loader != null:
				_loader.call("update_camp_area", str(_sel["id"]), {"polygon": poly})
		"space":
			var reg := _registry()
			if reg != null and reg.set_space_target(str(_sel["id"]),
					{"kind": "area", "poly": FestivalSeedLayout.poly_to_array(poly)}):
				_save_registry()
	edit_committed.emit(str(_sel.get("kind", "")), str(_sel.get("id", "")))
	_refresh_dock()


func _commit_prop_move(d: Dictionary) -> void:
	var to: Vector2 = d.get("to_xz", Vector2.INF)
	if to == Vector2.INF:
		return
	var pid := str(_sel.get("id", ""))
	var patch := {"x": to.x, "z": to.y}
	PlacedPropService.update_prop_record(_main, pid, patch, true)
	edit_committed.emit("prop", pid)


func _finish_draw() -> void:
	var poly := _draw_pts.duplicate()
	_draw_pts = PackedVector2Array()
	if poly.size() < 3 or CampAreaLayer.polygon_area(poly) < CampAreaLayer.MIN_AREA_M2:
		_flash("Too small for a space")
		return
	var reg := _registry()
	if reg == null:
		return
	var label := SpaceTypes.label(new_space_type)
	var sid := reg.set_space_type({"kind": "area", "poly": FestivalSeedLayout.poly_to_array(poly)},
		new_space_type, SpaceRegistry.CAPACITY_AUTO, label)
	if sid.is_empty():
		_flash("Could not add the space")
		return
	_undo.append({"kind": "space_added", "id": sid})
	_save_registry()
	set_tool(TOOL_SELECT)
	_select({"kind": "space", "id": sid})
	edit_committed.emit("space", sid)


func delete_selected() -> void:
	var kind := str(_sel.get("kind", ""))
	var id := str(_sel.get("id", ""))
	match kind:
		"camp":
			if _loader != null:
				if _loader.has_method("push_camp_undo"):
					_loader.call("push_camp_undo")
				_loader.call("delete_camp_area", id)
				_undo.append({"kind": "camp_deleted"})
		"space":
			var reg := _registry()
			if reg != null:
				var rec := reg.find_by_id(id).duplicate(true)
				if reg.remove_space(id):
					_undo.append({"kind": "space_deleted", "rec": rec})
					_save_registry()
		_:
			return
	_select({})
	edit_committed.emit(kind, id)


## Undo this editor's last edit.
func undo() -> void:
	if _undo.is_empty():
		_flash("Nothing to undo")
		return
	var u: Dictionary = _undo.pop_back()
	var reg := _registry()
	match str(u.get("kind", "")):
		"camp_poly":
			if _loader != null:
				_loader.call("update_camp_area", str(u["id"]), {"polygon": u["poly"]})
		"space_target":
			if reg != null:
				reg.set_space_target(str(u["id"]), u["target"])
				_save_registry()
		"space_added":
			if reg != null and reg.remove_space(str(u["id"])):
				_save_registry()
		"space_deleted":
			if reg != null:
				var rec: Dictionary = u["rec"]
				var sid := reg.set_space_type(rec.get("target", {}), str(rec.get("space_type", "")),
					int(rec.get("capacity", 0)), str(rec.get("label", "")))
				if not sid.is_empty():
					var f := rec.duplicate(true)
					for k in ["id", "target", "space_type"]:
						f.erase(k)
					reg.set_space_fields(sid, f)
				_save_registry()
		"camp_deleted":
			if _loader != null and _loader.has_method("undo_camps"):
				_loader.call("undo_camps")
		"prop_move":
			PlacedPropService.update_prop_record(_main, str(u["id"]), u["patch"], true)
	_reload_selected_poly()
	_refresh_dock()


func _push_undo() -> void:
	var kind := str(_sel.get("kind", ""))
	var id := str(_sel.get("id", ""))
	match kind:
		"camp":
			_undo.append({"kind": "camp_poly", "id": id,
				"poly": (_sel.get("poly", PackedVector2Array()) as PackedVector2Array).duplicate()})
		"space":
			var reg := _registry()
			if reg != null:
				_undo.append({"kind": "space_target", "id": id,
					"target": (reg.find_by_id(id).get("target", {}) as Dictionary).duplicate(true)})
		"prop":
			var rec := PlacedPropService.get_prop_record(_main, id)
			_undo.append({"kind": "prop_move", "id": id,
				"patch": {"x": float(rec.get("x", 0.0)), "z": float(rec.get("z", 0.0))}})
	while _undo.size() > UNDO_MAX:
		_undo.pop_front()


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	if not active:
		return
	var font := get_theme_default_font()
	# Every camp, outlined.
	for c in _camps():
		var cd: Dictionary = c
		if str(cd["id"]) == str(_sel.get("id", "")) and _sel.get("kind", "") == "camp":
			continue
		_draw_poly(cd.get("polygon", PackedVector2Array()), C_CAMP, 1.6, Color(C_CAMP, 0.07))
		_draw_label(cd.get("polygon", PackedVector2Array()), str(cd.get("name", "")), C_CAMP, font)
	# Every area space, in its type colour.
	var reg := _registry()
	if reg != null:
		for rec in reg.spaces:
			var r: Dictionary = rec
			var tgt: Dictionary = r.get("target", {})
			if str(tgt.get("kind", "")) != "area":
				continue
			if str(r.get("id", "")) == str(_sel.get("id", "")) and _sel.get("kind", "") == "space":
				continue
			var col := SpaceTypes.color(str(r.get("space_type", "")))
			var linked := not str(r.get("camp_id", "")).is_empty()
			var poly := SpaceRegistry.poly_points(tgt.get("poly", []) as Array)
			_draw_poly(poly, Color(col, 0.55 if linked else 0.95), 1.0 if linked else 1.6,
				Color(col, 0.0 if linked else 0.08))
			if not linked:
				_draw_label(poly, str(r.get("label", SpaceTypes.label(str(r.get("space_type", ""))))), col, font)
	# The selection, with its handles.
	if _sel.has("poly"):
		var poly2: PackedVector2Array = _sel["poly"]
		_draw_poly(poly2, C_SEL, 2.4, Color(C_SEL, 0.10))
		if _sel.get("kind", "") != "building":
			for i in poly2.size():
				var p := _screen(poly2[i])
				if p != Vector2.INF and p.y < _clip_y:
					draw_circle(p, HANDLE_PX * 0.7, C_HANDLE)
					draw_arc(p, HANDLE_PX * 0.7, 0, TAU, 16, Color.BLACK, 1.0)
				var q := _screen(poly2[(i + 1) % poly2.size()])
				if p != Vector2.INF and q != Vector2.INF:
					var m := (p + q) * 0.5
					draw_line(m - Vector2(4, 0), m + Vector2(4, 0), C_HANDLE, 1.5)
					draw_line(m - Vector2(0, 4), m + Vector2(0, 4), C_HANDLE, 1.5)
			var knob := _rotate_knob(poly2)
			if knob != Vector2.INF:
				var c0 := _screen(CampAreaLayer._inner_point(poly2))
				draw_line(c0, knob, Color(C_HANDLE, 0.6), 1.0)
				draw_arc(knob, HANDLE_PX, 0.4, TAU - 0.4, 20, C_HANDLE, 2.0)
	if _sel.get("kind", "") == "prop" and _drag.get("mode", "") == "move_prop":
		var to := _screen(_drag.get("to_xz", Vector2.INF))
		if to != Vector2.INF:
			draw_arc(to, 14.0, 0, TAU, 24, C_SEL, 2.0)
	# A space being drawn.
	if not _draw_pts.is_empty():
		var pts := PackedVector2Array()
		for w in _draw_pts:
			var sp2 := _screen(w)
			if sp2 != Vector2.INF:
				pts.append(sp2)
		if _hover_world != Vector2.INF:
			var hv := _screen(_hover_world)
			if hv != Vector2.INF:
				pts.append(hv)
		if pts.size() >= 2:
			draw_polyline(pts, C_DRAW, 2.0)
		for pp in pts:
			draw_circle(pp, 4.0, C_DRAW)
		if _draw_pts.size() >= 3:
			var first := _screen(_draw_pts[0])
			if first != Vector2.INF:
				draw_arc(first, CLOSE_PX, 0, TAU, 20, C_DRAW, 1.5)


func _draw_poly(poly: PackedVector2Array, col: Color, w: float, fill: Color) -> void:
	if poly.size() < 3:
		return
	var pts := PackedVector2Array()
	for v in poly:
		var p := _screen(v)
		if p == Vector2.INF:
			return
		pts.append(p)
	var pieces: Array = [pts]
	if _clip_y < INF:
		var r := PackedVector2Array([Vector2(-1e5, -1e5), Vector2(1e5, -1e5), Vector2(1e5, _clip_y), Vector2(-1e5, _clip_y)])
		pieces = Geometry2D.intersect_polygons(pts, r)
	for piece in pieces:
		var pp: PackedVector2Array = piece
		if pp.size() < 3:
			continue
		if fill.a > 0.0 and not Geometry2D.triangulate_polygon(pp).is_empty():
			draw_colored_polygon(pp, fill)
		pp.append(pp[0])
		draw_polyline(pp, col, w, true)


func _draw_label(poly: PackedVector2Array, text: String, col: Color, font: Font) -> void:
	if poly.size() < 3 or text.is_empty() or font == null:
		return
	var p := _screen(CampAreaLayer._inner_point(poly))
	if p == Vector2.INF or p.y > _clip_y:
		return
	var fs := UITheme.FONT_XS
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(font, p - Vector2(sz.x * 0.5, -fs * 0.35) + Vector2(1, 1), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.7))
	draw_string(font, p - Vector2(sz.x * 0.5, -fs * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _rotate_knob(poly: PackedVector2Array) -> Vector2:
	if poly.size() < 3 or _sel.get("kind", "") == "building":
		return Vector2.INF
	var c := _screen(CampAreaLayer._inner_point(poly))
	if c == Vector2.INF:
		return Vector2.INF
	var top := INF
	for v in poly:
		var p := _screen(v)
		if p != Vector2.INF:
			top = minf(top, p.y)
	return Vector2(c.x, minf(top, c.y) - ROTATE_KNOB_PX * 0.5)


# ---------------------------------------------------------------------------
# The dock (tools + the selection's card)
# ---------------------------------------------------------------------------

func _build_dock() -> void:
	_dock = PanelContainer.new()
	_dock.add_theme_stylebox_override("panel", UITheme.panel_style(0.92))
	_dock.anchor_left = 1.0
	_dock.anchor_right = 1.0
	_dock.offset_left = -392.0
	_dock.offset_right = -12.0
	_dock.offset_top = 70.0
	_dock.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dock)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_dock.add_child(v)
	var title := Label.new()
	title.text = "Edit the site"
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	v.add_child(title)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 4)
	v.add_child(tools)
	for t in [[TOOL_SELECT, "Select", "Click a camp or space; drag to move, corners to reshape"],
			[TOOL_DRAW, "Draw space", "Click the corners of a new NPC space; click the first one (or Enter) to finish"],
			[TOOL_TAG, "Tag object", "Click a placed object or a building to make it an NPC space"]]:
		var b := Button.new()
		b.text = str(t[1])
		b.tooltip_text = str(t[2])
		b.toggle_mode = true
		b.button_pressed = str(t[0]) == tool
		UITheme.style_button(b)
		var tid := str(t[0])
		b.pressed.connect(func() -> void: set_tool(tid))
		tools.add_child(b)
		_tool_btns[tid] = b
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 6)
	v.add_child(trow)
	trow.add_child(_lbl("New spaces are"))
	_type_pick = OptionButton.new()
	for st in SpaceTypes.TYPES:
		_type_pick.add_item(SpaceTypes.label(str(st)))
		_type_pick.set_item_metadata(_type_pick.item_count - 1, str(st))
		if str(st) == new_space_type:
			_type_pick.select(_type_pick.item_count - 1)
	_type_pick.item_selected.connect(func(i: int) -> void:
		new_space_type = str(_type_pick.get_item_metadata(i)))
	trow.add_child(_type_pick)
	_hint = _lbl("")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	v.add_child(_hint)
	_dock_body = VBoxContainer.new()
	_dock_body.add_theme_constant_override("separation", 5)
	v.add_child(_dock_body)
	_set_hint()


func _set_hint() -> void:
	if _hint == null:
		return
	match tool:
		TOOL_DRAW:
			_hint.text = "Click corners · click the first corner or Enter to finish · Backspace removes one · Esc stops"
		TOOL_TAG:
			_hint.text = "Click a placed object or a building, then pick what kind of space it is"
		_:
			_hint.text = "Click to select (again to cycle what is underneath) · drag inside to move · drag a corner to reshape · + adds a corner · ⟳ rotates · Del deletes · Ctrl+Z undoes"


func _over_dock(s: Vector2) -> bool:
	return _dock != null and _dock.visible and _dock.get_global_rect().has_point(s)


func _refresh_dock() -> void:
	if _dock_body == null:
		return
	for c in _dock_body.get_children():
		_dock_body.remove_child(c)
		c.queue_free()
	var kind := str(_sel.get("kind", ""))
	match kind:
		"camp":
			_build_camp_card()
		"space":
			_build_space_card()
		"prop":
			_dock_body.add_child(_lbl("Placed object · drag it to move"))
			var row := NpcSpaceTagRow.new()
			_dock_body.add_child(row)
			row.bind_prop(_loader, str(_sel["id"]))
		"building":
			_dock_body.add_child(_lbl("Building"))
			var row2 := NpcSpaceTagRow.new()
			_dock_body.add_child(row2)
			row2.bind_building(_loader, str(_sel["id"]))
		_:
			_dock_body.add_child(_lbl("Nothing selected."))
	# A wide row (the space type + capacity line) must not push the dock off
	# the screen's edge.
	UiFit.tame_widths(_dock_body)


func _build_camp_card() -> void:
	var id := str(_sel["id"])
	var rec := _camp_rec(id)
	_dock_body.add_child(_section("Camp"))
	var name_e := LineEdit.new()
	name_e.text = str(rec.get("name", ""))
	name_e.placeholder_text = "Camp name"
	var commit_name := func(_t: Variant = null) -> void:
		var t := name_e.text.strip_edges()
		if not t.is_empty() and t != str(_camp_rec(id).get("name", "")) and _loader != null:
			_loader.call("update_camp_area", id, {"name": t})
	name_e.text_submitted.connect(commit_name)
	name_e.focus_exited.connect(commit_name)
	_dock_body.add_child(_row("Name", name_e))
	var ppl := SpinBox.new()
	ppl.min_value = 0
	ppl.max_value = FestivalSeedLayout.MAX_HEADCOUNT
	ppl.value = int(rec.get("headcount", 0))
	ppl.suffix = "people"
	ppl.tooltip_text = "Exactly how many people live here (0 = scenery, nobody)"
	# Debounced: each commit rebuilds the camp's meshes and re-syncs the
	# graph, and holding an arrow used to do that every step.
	var ppl_timer := Timer.new()
	ppl_timer.one_shot = true
	ppl_timer.wait_time = 0.3
	ppl.add_child(ppl_timer)
	ppl_timer.timeout.connect(func() -> void:
		if _loader != null and int(ppl.value) != int(_camp_rec(id).get("headcount", -1)):
			_loader.call("update_camp_area", id, {"headcount": int(ppl.value)}))
	ppl.value_changed.connect(func(_v: float) -> void:
		ppl_timer.start())
	_dock_body.add_child(_row("People", ppl))
	var style := OptionButton.new()
	for sid in CampStyles.STYLES.keys():
		style.add_item(CampStyles.label(str(sid)))
		style.set_item_metadata(style.item_count - 1, str(sid))
		if str(sid) == str(rec.get("style", "")):
			style.select(style.item_count - 1)
	style.item_selected.connect(func(i: int) -> void:
		if _loader != null:
			_loader.call("update_camp_area", id, {"style": str(style.get_item_metadata(i))}))
	_dock_body.add_child(_row("Style", style))
	_add_supply_rows(FestivalSeedLayout.lot_id_for_camp(id))
	_dock_body.add_child(_lbl("%s · %.0f m²" % [CampStyles.label(str(rec.get("style", ""))),
		CampAreaLayer.record_area(rec)]))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_dock_body.add_child(row)
	var tune := Button.new()
	tune.text = "Tune look…"
	tune.tooltip_text = "Tents, vehicles, density and layout of this camp, in a studio preview"
	UITheme.style_button(tune)
	tune.pressed.connect(func() -> void:
		if _loader != null:
			_loader.call("open_camp_tune_for_camp", id))
	row.add_child(tune)
	row.add_child(_delete_button())


func _build_space_card() -> void:
	var id := str(_sel["id"])
	var reg := _registry()
	var rec: Dictionary = reg.find_by_id(id) if reg != null else {}
	_dock_body.add_child(_section("NPC space"))
	var label_e := LineEdit.new()
	label_e.text = str(rec.get("label", ""))
	label_e.placeholder_text = SpaceTypes.label(str(rec.get("space_type", "")))
	var commit := func(_t: Variant = null) -> void:
		var r2 := _registry()
		if r2 != null and r2.set_space_fields(id, {"label": label_e.text.strip_edges()}):
			_save_registry()
	label_e.text_submitted.connect(commit)
	label_e.focus_exited.connect(commit)
	_dock_body.add_child(_row("Name", label_e))
	var tag := NpcSpaceTagRow.new()
	_dock_body.add_child(tag)
	tag.bind_target(_loader, (rec.get("target", {}) as Dictionary).duplicate(true))
	tag.space_changed.connect(func(t: String) -> void:
		if t.is_empty():
			_select({}))
	if not str(rec.get("camp_id", "")).is_empty():
		_dock_body.add_child(_lbl("Belongs to its camp — it follows when the camp moves."))
	_dock_body.add_child(_lbl("%.0f m²" % CampAreaLayer.polygon_area(_sel.get("poly", PackedVector2Array()))))
	_dock_body.add_child(_delete_button())


## Per-camp water / food / waste supply (the calculator); filled in by the
## graph view when it knows the camp.
func _add_supply_rows(camp_key: String) -> void:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("camp_supply_modes"):
		return
	var modes: Dictionary = sgv.call("camp_supply_modes", camp_key)
	if modes.is_empty():
		return
	_dock_body.add_child(_section("Supply"))
	for group in [["inputs", "Water, food, wood"], ["wastes", "Grey, black water"]]:
		var opt := OptionButton.new()
		var cur := str(modes.get(str(group[0]), "infinite"))
		for m in CampTemplates.supply_choices():
			opt.add_item(str(m[1]))
			opt.set_item_metadata(opt.item_count - 1, str(m[0]))
			if str(m[0]) == cur:
				opt.select(opt.item_count - 1)
		var g := str(group[0])
		opt.item_selected.connect(func(i: int) -> void:
			sgv.call("set_camp_supply", camp_key, {g: str(opt.get_item_metadata(i))}))
		_dock_body.add_child(_row(str(group[1]), opt))


func _delete_button() -> Button:
	var del := Button.new()
	del.text = "Delete"
	UITheme.style_button(del)
	del.add_theme_color_override("font_color", UITheme.C_ERROR)
	var armed := [false]
	del.pressed.connect(func() -> void:
		if not armed[0]:
			armed[0] = true
			del.text = "Click again to delete"
			# Disarm after a few seconds, so a stray click later never deletes.
			# A weak reference: the dock may free the button first, and a
			# lambda holding a freed object errors when the timer fires.
			var wr: WeakRef = weakref(del)
			get_tree().create_timer(3.0).timeout.connect(func() -> void:
				var b: Button = wr.get_ref()
				if b != null:
					armed[0] = false
					b.text = "Delete")
			return
		delete_selected())
	return del


func _section(t: String) -> Control:
	return SectionHeader.make(t)


func _row(label: String, ctl: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	var l := _lbl(label)
	l.custom_minimum_size.x = 92
	r.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(ctl)
	return r


func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT)
	return l


func _flash(t: String) -> void:
	if _hint != null:
		_hint.text = t
		# Only the newest flash clears the hint (an older timer would cut the
		# newer message short).
		_flash_gen += 1
		var gen := _flash_gen
		get_tree().create_timer(2.5).timeout.connect(func() -> void:
			if gen == _flash_gen:
				_set_hint())


# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------

func _camps() -> Array:
	var areas: Variant = _loader.get("camp_areas") if _loader != null else null
	return areas.get("areas") as Array if areas != null else []


func _camp_rec(id: String) -> Dictionary:
	var areas: Variant = _loader.get("camp_areas") if _loader != null else null
	return areas.call("get_area", id) if areas != null else {}


func _registry() -> SpaceRegistry:
	return _loader.get("npc_spaces") if _loader != null else null


func _save_registry() -> void:
	if _loader != null and _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")


func _ground(s: Vector2) -> Vector2:
	if not _ground_at.is_valid():
		return Vector2.INF
	var v: Variant = _ground_at.call(s)
	return v if v is Vector2 else Vector2.INF


func _screen(w: Vector2) -> Vector2:
	if w == Vector2.INF or not _to_screen.is_valid():
		return Vector2.INF
	var v: Variant = _to_screen.call(w)
	return v if v is Vector2 else Vector2.INF
