extends Control

## The 2D process picture (plans/SCADA_PROCESS_PLAN.md, Phase 2): draws a
## MIMIC DOC (pipes + elements, picture millimetres) with its live state,
## and turns the pointer into signals. It never edits a spec and never asks
## where a number came from: the owner sets the doc, the state and the pins.
##
##   set_doc(doc)            {pipes, elements, bounds} (MimicTcSource.build)
##   set_state(state)        {cv, link, end, heater, unit, bed}
##   set_flow_signs({pipe id: -1 | 0 | +1})
##   set_pins({element id: Vector2 offset})   the player's drags
##
## A drag moves the thing dragged (and what sits on it: a vessel's probes and
## nozzle valves, an instrument's bubble) as a whole, never its neighbours.
## Each line's ends follow the things they are attached to (a graph line's
## `from` / `to`; a real pipe's ends by where they lie) and the line between
## is re-routed with straight runs and right-angle bends (MimicLayout.reroute).
##   set_icons(icons, glyphs) {element id: Texture2D}: a picture of the thing
##                           (MimicIcons, drawn instead of its box) or a
##                           pictogram in its cabinet
##   selected_cv             the volume drawn selected
##   tick(delta, moving, rate)                advances the flow marks
##
## Input: wheel zooms about the pointer, a drag on empty picture pans, a
## click selects, a drag on an element moves it (emitted on release, one
## signal), double-click an element = `element_activated`, F fits.

signal element_clicked(el: Dictionary)
signal element_activated(el: Dictionary)
signal pipe_clicked(pipe: Dictionary)
signal empty_clicked
signal element_moved(id: String, offset: Vector2)
signal hover_changed(what: Dictionary)
## Tools (the Process lens's editing). "place": a click asks to put a part
## down: `pipe` = the pipe under the pointer ({} = open space), `at` in
## picture units. "pipe": press on one thing, release on another.
signal place_requested(at: Vector2, pipe: Dictionary)
signal link_requested(from_id: String, to_id: String)
## As built: a run's bend dragged to `to` (picture units), or double-clicked
## away. `index` counts the run's interior corners (MimicWorldSource bends).
signal bend_moved(pipe_id: String, index: int, to: Vector2)
signal bend_removed(pipe_id: String, index: int)

const ZOOM_MIN := 0.05
const ZOOM_MAX := 6.0
const DRAG_PX := 5.0
const FIT_MARGIN := 46.0
const TAG_FS := 12
const REDRAW_S := 0.05
## Drawn as equipment (their own size, names and readings); the rest are
## small things that sit on lines and volumes.
const BIG := ["vessel", "holder", "dryer", "engine", "flare", "tank", "machine", "pump", "group", "source", "device"]

var doc: Dictionary = {}
var state: Dictionary = {}
var flow_signs: Dictionary = {}
var pins: Dictionary = {}
var icons: Dictionary = {}
var glyphs: Dictionary = {}
var selected_cv := -1
var selected_id := ""
## Where the last click landed (control pixels): a slider reads it.
var click_pos := Vector2.ZERO
## Value tags on every vessel and unit (off = only the hovered / selected).
var show_values := true
var show_names := true
## "" (select / move) | "place" | "pipe"
var tool := ""
## As built: things stand where they are in the world (no dragging them), and
## the selected run's bends have handles.
var built := false
const BEND_PICK_PX := 9.0
var _bend_drag := {}
## Words shown beside the pointer while a tool is armed.
var tool_hint := ""
var _link_from: Dictionary = {}
var _pointer := Vector2.ZERO

var _zoom := 0.5
var _pan := Vector2.ZERO          # picture point at the control's centre
var _phase := 0.0
## Element id -> how far it is drawn from where the doc put it (its own pin
## plus whatever it sits on).
var _off: Dictionary = {}
## Element id -> the element it moves with (a probe -> its vessel).
var _parent: Dictionary = {}
## Pipe id -> [start element id, end element id] ("" = nothing there).
var _ends: Dictionary = {}
## Pipe id -> its route in picture units after the drags.
var _route_cache: Dictionary = {}
var _hover_id := ""
var _hover_pipe := ""
var _press_pos := Vector2.ZERO
var _pressing := false
var _press_el: Dictionary = {}
var _dragging := false
var _panning := false
var _drag_off0 := Vector2.ZERO
var _fit_pending := true
var _font: Font = null
var _draw_cost_us := 0
var _line_cache: Dictionary = {}
var _line_key: Array = []
var _pin_rev := 0
## What a pipe's end can be attached to (a probe or a heater on a run is not).
const ATTACH_KINDS := ["vessel", "holder", "dryer", "engine", "flare", "tank", "machine", "pump", "group", "source",
	"device", "valve", "check", "relief", "end"]
## Equipment drawn this frame: [[screen rect, depth]] (what hides things behind it).
var _fronts: Array = []
var _redraw_acc := 0.0


func _init() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	# Equipment pictures carry mipmaps: smooth when drawn small.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_meta("mimic_canvas", true)


func _ready() -> void:
	_font = UITheme.font("medium", true)
	resized.connect(func() -> void:
		if _fit_pending:
			fit()
		queue_redraw())


## `refit` false keeps the view where it is (an edit must not move the
## picture under the pointer).
func set_doc(d: Dictionary, refit: bool = true) -> void:
	doc = d
	_line_cache.clear()
	_link_doc()
	_rebuild_pins()
	if refit:
		_fit_pending = true
		if size.x > 10.0:
			fit()
	queue_redraw()


func set_state(s: Dictionary) -> void:
	state = s
	queue_redraw()


func set_flow_signs(d: Dictionary) -> void:
	flow_signs = d


func set_icons(icon_map: Dictionary, glyph_map: Dictionary) -> void:
	icons = icon_map
	glyphs = glyph_map
	queue_redraw()


## How many elements are drawn with a picture / a pictogram (checks).
func icons_drawn() -> Vector2i:
	var a := 0
	var b := 0
	for e in doc.get("elements", []):
		var id := str(e["id"])
		if bool(e.get("icon", false)) and icons.get(id) is Texture2D:
			a += 1
		elif glyphs.get(id) is Texture2D:
			b += 1
	return Vector2i(a, b)


func set_pins(p: Dictionary) -> void:
	pins = p.duplicate()
	_rebuild_pins()
	queue_redraw()


const ALARM_COLORS := {"high": Color(0.94, 0.33, 0.31), "medium": Color(0.98, 0.70, 0.22), "low": Color(0.35, 0.78, 0.98)}
var _alarm_flash := false
var _alarm_acc := 0.0
var _alarms_drawn := 0
var _widgets_drawn := 0


func widgets_drawn() -> int:
	return _widgets_drawn


## How many things were outlined as in alarm in the last draw (for checks).
func alarms_drawn() -> int:
	return _alarms_drawn


## Things in alarm (state["alarm"] = {element id: {priority, unack}}): an
## outline in the priority's colour; one nobody has acknowledged flashes
## (about once a second, real time: it must show with the clock held).
func _draw_alarms() -> void:
	_alarm_flash = false
	_alarms_drawn = 0
	var al: Dictionary = state.get("alarm", {}) as Dictionary
	if al.is_empty():
		return
	var on := fmod(float(Time.get_ticks_msec()) / 1000.0, 1.0) < 0.6
	for e in doc.get("elements", []):
		var a: Dictionary = al.get(str(e["id"]), {}) as Dictionary
		if a.is_empty():
			continue
		_alarms_drawn += 1
		var unack := bool(a.get("unack", false))
		if unack:
			_alarm_flash = true
		var col: Color = ALARM_COLORS.get(str(a.get("priority", "medium")), MimicSymbols.WARN)
		if unack and not on:
			col = Color(col, 0.25)
		var r := element_rect(e).grow(6.0)
		draw_rect(r, Color(col, col.a * 0.10), true)
		draw_rect(r, col, false, 2.5)


func tick(delta: float, moving: bool, rate: float = 1.0) -> void:
	if _alarm_flash and visible:
		_alarm_acc += delta
		if _alarm_acc >= 0.2:
			_alarm_acc = 0.0
			queue_redraw()
	if moving and visible:
		# Faster at speed, never a blur: sqrt of the lab's rate.
		_phase += delta * 42.0 * clampf(sqrt(maxf(rate, 0.0) / 60.0), 0.4, 3.0)
		# The picture is wide anti-aliased lines: 20 redraws a second is smooth
		# for marks moving ~40 px/s and a third of the cost of every frame.
		_redraw_acc += delta
		if _redraw_acc >= REDRAW_S:
			_redraw_acc = 0.0
			queue_redraw()


func draw_cost_ms() -> float:
	return float(_draw_cost_us) / 1000.0


# ── view ────────────────────────────────────────────────────────────────────

func fit() -> void:
	var b: Rect2 = doc.get("bounds", Rect2(-100, -100, 200, 200))
	for e in doc.get("elements", []):
		var c := moved_pos(e) if str(e["kind"]) != "widget" else (e["pos"] as Vector2)
		b = b.expand(c - (e["size"] as Vector2) * 0.5).expand(c + (e["size"] as Vector2) * 0.5)
	var avail := size - Vector2(FIT_MARGIN, FIT_MARGIN) * 2.0
	if avail.x < 20.0 or avail.y < 20.0 or b.size.x < 1.0 or b.size.y < 1.0:
		return
	_zoom = clampf(minf(avail.x / b.size.x, avail.y / b.size.y), ZOOM_MIN, ZOOM_MAX)
	_pan = b.get_center()
	_fit_pending = false
	queue_redraw()


## Frame one pipe (its line, padded) instead of the whole picture: As built
## opened on a run shows that run, not a site 2 km across. Falls back to fit.
func fit_pipe(id: String) -> void:
	var line := PackedVector2Array()
	for p in doc.get("pipes", []):
		if str((p as Dictionary).get("id", "")) == id:
			line = pipe_route(p as Dictionary)
			break
	if line.size() < 2:
		fit()
		return
	var b := Rect2(line[0], Vector2.ZERO)
	for q in line:
		b = b.expand(q)
	b = b.grow(maxf(maxf(b.size.x, b.size.y) * 0.35, 60.0))
	var avail := size - Vector2(FIT_MARGIN, FIT_MARGIN) * 2.0
	if avail.x < 20.0 or avail.y < 20.0:
		return
	_zoom = clampf(minf(avail.x / b.size.x, avail.y / b.size.y), ZOOM_MIN, ZOOM_MAX)
	_pan = b.get_center()
	_fit_pending = false
	queue_redraw()


func zoom() -> float:
	return _zoom


## How far an element is drawn from where the doc put it.
func offset_of(id: String) -> Vector2:
	return _off.get(id, Vector2.ZERO) as Vector2


## Where an element is drawn (picture units).
func moved_pos(e: Dictionary) -> Vector2:
	return (e["pos"] as Vector2) + offset_of(str(e["id"]))


## Picture units -> control pixels.
func to_screen(p: Vector2) -> Vector2:
	return (p - _pan) * _zoom + size * 0.5


func _screen_line(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	var half := size * 0.5
	for i in pts.size():
		out[i] = (pts[i] - _pan) * _zoom + half
	return out


## A pipe's screen points, kept while the view holds still (the route and
## the transform are the cost of a redraw; the flow marks only need the line).
func _pipe_line(p: Dictionary) -> PackedVector2Array:
	var key := [_zoom, _pan, size, _pin_rev]
	if key != _line_key:
		_line_key = key
		_line_cache.clear()
	var id := str(p["id"])
	if not _line_cache.has(id):
		_line_cache[id] = _screen_line(pipe_route(p))
	return _line_cache[id]


## A pipe's route in picture units after the drags: the doc's line when
## nothing at its ends moved, moved whole when both ends moved together,
## else re-routed with right-angle bends between its moved ends.
func pipe_route(p: Dictionary) -> PackedVector2Array:
	var id := str(p["id"])
	if _route_cache.has(id):
		return _route_cache[id]
	var pts: PackedVector2Array = p["pts"]
	var ends: Array = pipe_ends(str(p["id"]))
	var da := offset_of(str(ends[0]))
	var db := offset_of(str(ends[1]))
	var out := pts
	if da != Vector2.ZERO or db != Vector2.ZERO:
		if da.distance_to(db) < 0.01:
			out = PackedVector2Array()
			out.resize(pts.size())
			for i in pts.size():
				out[i] = pts[i] + da
		else:
			var w := float(p.get("w", 10.0))
			out = MimicLayout.round_corners(pipe_corners(p), float(p.get("corner_r", w)))
	_route_cache[id] = out
	return out


## [start element id, end element id] a pipe is attached to.
func pipe_ends(id: String) -> Array:
	return _ends.get(id, ["", ""]) as Array


## A pipe's straight legs and corners after the drags (before rounding).
func pipe_corners(p: Dictionary) -> PackedVector2Array:
	var w := float(p.get("w", 10.0))
	var corners: PackedVector2Array = p.get("corners", PackedVector2Array())
	if corners.size() < 2:
		corners = MimicLayout.simplify_corners(p["pts"], maxf(w * 0.3, 4.0))
	var ends := pipe_ends(str(p["id"]))
	return MimicLayout.reroute(corners, offset_of(str(ends[0])), offset_of(str(ends[1])),
		float(p.get("stub", maxf(w * 1.6, 30.0))))


## Which element each pipe end is attached to, and what each small thing
## moves with. Once per doc.
func _link_doc() -> void:
	_parent = {}
	_ends = {}
	var by_id := {}
	var big_of_cv := {}
	for e in doc.get("elements", []):
		by_id[str(e["id"])] = e
		if str(e["kind"]) in BIG and int(e.get("cv", -1)) >= 0 and not big_of_cv.has(int(e["cv"])):
			big_of_cv[int(e["cv"])] = str(e["id"])
	for e in doc.get("elements", []):
		var id := str(e["id"])
		var kind := str(e["kind"])
		if kind == "widget" or kind in BIG:
			continue
		if kind == "instr" and by_id.has(str(e.get("reads", ""))):
			_parent[id] = str(e["reads"])
		elif int(e.get("cv", -1)) >= 0 and big_of_cv.has(int(e["cv"])) and str(big_of_cv[int(e["cv"])]) != id:
			# Screwed into a vessel or a unit (a probe, a heater, a nozzle's
			# valve or open end): goes where it goes.
			_parent[id] = big_of_cv[int(e["cv"])]
	for p in doc.get("pipes", []):
		var pid := str(p["id"])
		if p.has("from") and p.has("to"):
			_ends[pid] = [str(p["from"]) if by_id.has(str(p["from"])) else "", str(p["to"]) if by_id.has(str(p["to"])) else ""]
			continue
		var pts: PackedVector2Array = p.get("corners", p["pts"])
		if pts.size() < 2:
			continue
		var w := float(p.get("w", 10.0))
		_ends[pid] = [_attached_at(pts[0], w), _attached_at(pts[pts.size() - 1], w)]


## The smallest thing a pipe end lies on (its outline grown a little).
func _attached_at(at: Vector2, w: float) -> String:
	var best := ""
	var best_area := INF
	var margin := maxf(10.0, w * 0.7)
	for e in doc.get("elements", []):
		if not (str(e["kind"]) in ATTACH_KINDS):
			continue
		var sz: Vector2 = e["size"]
		var r := Rect2((e["pos"] as Vector2) - sz * 0.5, sz).grow(margin)
		if r.has_point(at) and r.get_area() < best_area:
			best = str(e["id"])
			best_area = r.get_area()
	return best


func _rebuild_pins() -> void:
	_pin_rev += 1
	_route_cache.clear()
	_off = {}
	for e in doc.get("elements", []):
		if str(e["kind"]) != "widget":
			_off[str(e["id"])] = _offset_chain(str(e["id"]), 0)


func _offset_chain(id: String, depth: int) -> Vector2:
	var own: Vector2 = pins.get(id, Vector2.ZERO) as Vector2
	if depth > 8 or not _parent.has(id):
		return own
	return own + _offset_chain(str(_parent[id]), depth + 1)


func element_by_id(id: String) -> Dictionary:
	for e in doc.get("elements", []):
		if str(e["id"]) == id:
			return e
	return {}


## Screen rect of an element (what is drawn and what is clicked).
func element_rect(e: Dictionary) -> Rect2:
	var kind := str(e["kind"])
	if kind == "widget":
		# A widget is not part of the rubber sheet: it stands where it was put.
		var wp: Vector2 = (e["pos"] as Vector2) + (pins.get(str(e["id"]), Vector2.ZERO) as Vector2)
		var wsz: Vector2 = (e["size"] as Vector2) * _zoom
		return Rect2((wp - _pan) * _zoom + size * 0.5 - wsz * 0.5, wsz)
	var off := offset_of(str(e["id"]))
	var c := to_screen((e["pos"] as Vector2) + off)
	var sz: Vector2 = (e["size"] as Vector2) * _zoom
	if kind == "vessel" and e.has("base") and float(e.get("shell_h", 0.0)) > 1.0:
		var base := to_screen((e["base"] as Vector2) + off)
		var w := float(e["shell_w"]) * _zoom * 1.06
		var h := float(e["shell_h"]) * _zoom
		return Rect2(base.x - w * 0.5, base.y - h, w, h)
	if kind in ["valve", "check", "relief", "end", "probe_t", "probe_p", "probe_well", "probe_l", "probe_ls"]:
		var m := maxf(sz.x, 18.0)
		return Rect2(c - Vector2(m, m) * 0.5, Vector2(m, m))
	sz = sz.max(Vector2(14, 14))
	return Rect2(c - sz * 0.5, sz)


func element_screen_center(id: String) -> Vector2:
	var e := element_by_id(id)
	return element_rect(e).get_center() if not e.is_empty() else Vector2.ZERO


func pipe_screen_point(id: String, frac: float = 0.5) -> Vector2:
	for p in doc.get("pipes", []):
		if str(p["id"]) == id:
			var sl := _pipe_line(p)
			return MimicLayout.point_at(sl, MimicLayout.length_of(sl) * frac)[0]
	return Vector2.ZERO


# ── picking ─────────────────────────────────────────────────────────────────

## A small element (a valve, an open end) standing behind a piece of
## equipment, inside its outline: not drawn and not clickable.
func _behind(e: Dictionary) -> bool:
	# Only what nobody operates: a valve, a heater, a drain or a gauge behind
	# a vessel is still drawn on it, or it could never be clicked.
	if str(e["kind"]) != "end" or not (str(e.get("role", "")) in ["coolant_in", "coolant_out", "plug", "atmosphere"]):
		return false
	var c := element_rect(e).get_center()
	for f in _fronts:
		if float(e["depth"]) > float(f[1]) + 40.0 and (f[0] as Rect2).grow(-4.0).has_point(c):
			return true
	return false


func pick_element(at: Vector2) -> Dictionary:
	# What sits ON something wins over what it sits on: a valve or an end
	# over an element, an element over the vessel; then the smaller.
	var best := {}
	var best_rank := 99
	var best_area := INF
	for e in doc.get("elements", []):
		if _behind(e):
			continue
		var r := element_rect(e).grow(3.0)
		if not r.has_point(at):
			continue
		var kind := str(e["kind"])
		var rank := 2 if kind in BIG else (1 if kind == "heater" else (-1 if kind == "widget" else 0))
		if rank < best_rank or (rank == best_rank and r.get_area() < best_area):
			best = e
			best_rank = rank
			best_area = r.get_area()
	return best


func pick_pipe(at: Vector2) -> Dictionary:
	var best := {}
	var best_d := INF
	for p in doc.get("pipes", []):
		var d := MimicLayout.distance_to_line(at, _pipe_line(p))
		var reach := maxf(float(p["w"]) * _zoom * (1.0 if int(p["shell"]) < 0 else 2.0) * 0.5, 6.0) + 3.0
		if d <= reach and d < best_d:
			best = p
			best_d = d
	return best


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_zoom_at(mb.position, 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and tool == "place":
			if mb.pressed:
				# A pipe under the pointer wins; a click on a thing does nothing
				# (parts are never set down on top of each other).
				var on := pick_pipe(mb.position)
				if not on.is_empty() or pick_element(mb.position).is_empty():
					place_requested.emit(to_picture(mb.position), on)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and tool == "pipe":
			if mb.pressed:
				_link_from = pick_element(mb.position)
			else:
				var to := pick_element(mb.position)
				if not _link_from.is_empty() and not to.is_empty() and str(to["id"]) != str(_link_from["id"]):
					link_requested.emit(str(_link_from["id"]), str(to["id"]))
				_link_from = {}
			_pointer = mb.position
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and built:
			var bh := _bend_at(mb.position)
			if mb.pressed and not bh.is_empty():
				if mb.double_click:
					bend_removed.emit(str(bh["pipe"]), int(bh["index"]))
				else:
					_bend_drag = bh
					_bend_drag["at"] = mb.position
				accept_event()
				return
			if not mb.pressed and not _bend_drag.is_empty():
				var moved: bool = (mb.position - (_bend_drag["press"] as Vector2)).length() > DRAG_PX
				if moved:
					bend_moved.emit(str(_bend_drag["pipe"]), int(_bend_drag["index"]), to_picture(mb.position))
				_bend_drag = {}
				queue_redraw()
				accept_event()
				return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				grab_focus()
				_pressing = true
				_dragging = false
				_panning = false
				_press_pos = mb.position
				_press_el = pick_element(mb.position)
				_drag_off0 = pins.get(str(_press_el.get("id", "")), Vector2.ZERO) if not _press_el.is_empty() else Vector2.ZERO
				if mb.double_click and not _press_el.is_empty():
					_pressing = false
					element_activated.emit(_press_el)
			elif _pressing:
				_pressing = false
				if _dragging and not _press_el.is_empty():
					element_moved.emit(str(_press_el["id"]), pins.get(str(_press_el["id"]), Vector2.ZERO))
				elif not _dragging and not _panning:
					_click(mb.position)
				_dragging = false
				_panning = false
			accept_event()
			return
		if (mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT):
			_panning = mb.pressed
			_press_pos = mb.position
			accept_event()
			return
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_pointer = mm.position
		if not tool.is_empty() and not _panning:
			_hover(mm.position)
			queue_redraw()
			return
		if not _bend_drag.is_empty():
			_bend_drag["at"] = mm.position
			queue_redraw()
			return
		if _pressing and not _dragging and not _panning and mm.position.distance_to(_press_pos) > DRAG_PX:
			if _press_el.is_empty() or built:
				_panning = true
			else:
				_dragging = true
		if _dragging and not _press_el.is_empty():
			pins[str(_press_el["id"])] = _drag_off0 + (mm.position - _press_pos) / _zoom
			_rebuild_pins()
			queue_redraw()
		elif _panning:
			_pan -= (mm.position - _press_pos) / _zoom
			_press_pos = mm.position
			_fit_pending = false
			queue_redraw()
		else:
			_hover(mm.position)
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_F:
			fit()
			accept_event()


## The bend handle of the selected run under `at` ({} = none).
func _bend_at(at: Vector2) -> Dictionary:
	if selected_id.is_empty():
		return {}
	for p: Variant in doc.get("pipes", []):
		var pd: Dictionary = p
		if str(pd["id"]) != selected_id or not pd.has("bends"):
			continue
		var bends: PackedVector2Array = pd["bends"]
		for i: int in range(bends.size()):
			if to_screen(bends[i]).distance_to(at) <= BEND_PICK_PX:
				return {"pipe": selected_id, "index": i, "press": at}
	return {}


## The selected run's bend handles (As built).
func _draw_bends() -> void:
	if not built or selected_id.is_empty():
		return
	for p: Variant in doc.get("pipes", []):
		var pd: Dictionary = p
		if str(pd["id"]) != selected_id or not pd.has("bends"):
			continue
		var bends: PackedVector2Array = pd["bends"]
		for i: int in range(bends.size()):
			var s := to_screen(bends[i])
			if not _bend_drag.is_empty() and int(_bend_drag["index"]) == i:
				s = _bend_drag["at"]
			draw_rect(Rect2(s - Vector2(5.5, 5.5), Vector2(11, 11)), Color(0, 0, 0, 0.7))
			draw_rect(Rect2(s - Vector2(4, 4), Vector2(8, 8)), Color(1.0, 0.86, 0.3))


## Control pixels → picture units (the inverse of to_screen).
func to_picture(p: Vector2) -> Vector2:
	return (p - size * 0.5) / _zoom + _pan


func set_tool(t: String, hint: String = "") -> void:
	tool = t
	tool_hint = hint
	_link_from = {}
	_pressing = false
	_dragging = false
	queue_redraw()


func _draw_tool() -> void:
	if tool.is_empty():
		return
	if tool == "pipe" and not _link_from.is_empty():
		var a := element_rect(_link_from).get_center()
		draw_line(a, _pointer, MimicSymbols.SELECT, 3.0, true)
		draw_circle(_pointer, 5.0, MimicSymbols.SELECT)
	elif tool == "place":
		draw_arc(_pointer, 13.0, 0.0, TAU, 28, MimicSymbols.SELECT, 2.0, true)
	if not tool_hint.is_empty() and Rect2(Vector2.ZERO, size).has_point(_pointer):
		MimicSymbols.tag(self, _pointer + Vector2(18.0, 14.0), tool_hint, _font, TAG_FS, MimicSymbols.TEXT, MimicSymbols.SELECT)


func _zoom_at(at: Vector2, factor: float) -> void:
	var before := (at - size * 0.5) / _zoom + _pan
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_pan = before - (at - size * 0.5) / _zoom
	_fit_pending = false
	queue_redraw()


func _click(at: Vector2) -> void:
	click_pos = at
	var e := pick_element(at)
	if not e.is_empty():
		selected_id = str(e["id"])
		element_clicked.emit(e)
		queue_redraw()
		return
	var p := pick_pipe(at)
	if not p.is_empty():
		selected_id = str(p["id"]) if int(p["cv"]) < 0 else ""
		pipe_clicked.emit(p)
		queue_redraw()
		return
	selected_id = ""
	empty_clicked.emit()
	queue_redraw()


func _hover(at: Vector2) -> void:
	var e := pick_element(at)
	var hid := str(e.get("id", ""))
	var hp := ""
	var what := e
	if hid.is_empty():
		var p := pick_pipe(at)
		hp = str(p.get("id", ""))
		what = p
	if hid != _hover_id or hp != _hover_pipe:
		_hover_id = hid
		_hover_pipe = hp
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not what.is_empty() else Control.CURSOR_ARROW
		hover_changed.emit(what)
		queue_redraw()


# ── drawing ─────────────────────────────────────────────────────────────────

func _cv_state(cv: int) -> Dictionary:
	return (state.get("cv", {}) as Dictionary).get(cv, {}) as Dictionary


func _draw() -> void:
	var t0 := Time.get_ticks_usec()
	draw_rect(Rect2(Vector2.ZERO, size), MimicSymbols.BG)
	_draw_grid()
	if doc.is_empty():
		_draw_cost_us = Time.get_ticks_usec() - t0
		return
	# Equipment behind its pipework reads wrong in a P&ID: pipes first (far to
	# near), then equipment, then what sits on them.
	for p in doc.get("pipes", []):
		_draw_pipe(p)
	var small: Array = []
	var widgets: Array = []
	_fronts = []
	for e in doc.get("elements", []):
		if str(e["kind"]) in BIG:
			_draw_equipment(e)
			_fronts.append([element_rect(e), float(e["depth"])])
		elif str(e["kind"]) == "widget":
			widgets.append(e)
		else:
			small.append(e)
	for e in small:
		if not _behind(e):
			_draw_small(e)
	_draw_alarms()
	_draw_tags()
	# Widgets stand over the picture.
	var view_rect := Rect2(Vector2.ZERO, size)
	var wst: Dictionary = state.get("w", {}) as Dictionary
	_widgets_drawn = 0
	for e in widgets:
		var wr := element_rect(e)
		if not wr.intersects(view_rect):
			continue
		var wid := str(e["id"])
		MimicSymbols.widget(self, wr, str(e["wkind"]), wst.get(wid, {}) as Dictionary, _font, wid == selected_id, wid == _hover_id)
		_widgets_drawn += 1
	_draw_bends()
	_draw_tool()
	_draw_cost_us = Time.get_ticks_usec() - t0


func _draw_grid() -> void:
	var step := 100.0   # mm
	while step * _zoom < 26.0:
		step *= 5.0
	var tl := (Vector2.ZERO - size * 0.5) / _zoom + _pan
	var br := (size - size * 0.5) / _zoom + _pan
	var x := floorf(tl.x / step) * step
	while x <= br.x:
		var sx := (x - _pan.x) * _zoom + size.x * 0.5
		draw_line(Vector2(sx, 0), Vector2(sx, size.y), MimicSymbols.GRID, 1.0)
		x += step
	var y := floorf(tl.y / step) * step
	while y <= br.y:
		var sy := (y - _pan.y) * _zoom + size.y * 0.5
		draw_line(Vector2(0, sy), Vector2(size.x, sy), MimicSymbols.GRID, 1.0)
		y += step


func _draw_pipe(p: Dictionary) -> void:
	var pts := _pipe_line(p)
	var cv := int(p["cv"])
	var ps: Dictionary = (state.get("pipe", {}) as Dictionary).get(str(p["id"]), {}) as Dictionary
	if str(p.get("style", "pipes")) != "pipes":
		# A power or data run.
		MimicSymbols.wire(self, pts, maxf(float(p["w"]) * _zoom, 2.0), {"selected": str(p["id"]) == selected_id,
			"hover": str(p["id"]) == _hover_pipe, "flow": int(ps.get("flow", 0)), "phase": _phase,
			"color": ps.get("color", MimicSymbols.STEEL_LIGHT), "warn": bool(ps.get("warn", false)),
			"dashed": bool(p.get("dashed", false))})
		return
	if not ps.is_empty() or cv < 0:
		# A graph line: its state is the wire's own; its jacket the service's
		# colour (hot red, cold blue, drain grey…).
		if bool(p.get("dashed", false)):
			# Not built in 3D yet: a faint dashed line, so the real runs read
			# first; full strength while hovered or picked.
			var sel := str(p["id"]) == selected_id or str(p["id"]) == _hover_pipe
			var dc: Color = ps.get("service", MimicSymbols.STEEL_LIGHT)
			MimicSymbols.wire(self, pts, maxf(float(p["w"]) * _zoom * (0.6 if sel else 0.3), 1.5), {"selected": str(p["id"]) == selected_id,
				"hover": str(p["id"]) == _hover_pipe, "flow": 0, "phase": _phase,
				"color": dc if sel else Color(dc, 0.3), "warn": false, "dashed": true})
			return
		MimicSymbols.pipe(self, pts, maxf(float(p["w"]) * _zoom, 3.0), {"selected": str(p["id"]) == selected_id,
			"hover": str(p["id"]) == _hover_pipe, "flow": int(ps.get("flow", 0)), "phase": _phase,
			"level": float(ps.get("level", 0.0)), "fill": ps.get("fill", MimicSymbols.EMPTY),
			"service": ps.get("service", Color(0, 0, 0, 0))})
		return
	var st := _cv_state(cv)
	var w := maxf(float(p["w"]) * _zoom, 3.0)
	var o := {"selected": cv == selected_cv and selected_cv >= 0, "hover": str(p["id"]) == _hover_pipe,
		"flow": int(flow_signs.get(str(p["id"]), 0)), "phase": _phase, "level": float(st.get("level", 0.0))}
	if not st.is_empty():
		var busy := absf(float(st.get("flow", 0.0))) > 1e-7 or float(st.get("t_c", 20.0)) > 45.0
		o["fill"] = MimicSymbols.heat_rgb(float(st.get("t_c", 20.0))) if busy else MimicSymbols.EMPTY
	var shell := int(p["shell"])
	if shell >= 0:
		var cs := _cv_state(shell)
		var tc := float(cs.get("t_cool_c", 15.0))
		o["shell"] = MimicSymbols.COOLANT.lerp(MimicSymbols.HOT, clampf((tc - 20.0) / 70.0, 0.0, 0.8)) if not is_nan(tc) else MimicSymbols.COOLANT
	MimicSymbols.pipe(self, pts, w, o)
	var role := str(p["role"])
	if (role == "column" or role == "filter" or role == "sight") and w >= 8.0 and pts.size() >= 2:
		# Packing / a window: marks across the bore.
		var total := MimicLayout.length_of(pts)
		var s := w * 0.6
		while s < total - w * 0.3:
			var a := MimicLayout.point_at(pts, s)
			var n := Vector2(-(a[1] as Vector2).y, (a[1] as Vector2).x) * w * 0.26
			draw_line((a[0] as Vector2) - n, (a[0] as Vector2) + n,
				Color(MimicSymbols.STEEL_LIGHT, 0.55) if role != "sight" else Color(MimicSymbols.LIQUID, 0.5), 1.5, true)
			s += w * (0.5 if role != "sight" else 0.9)


func _draw_equipment(e: Dictionary) -> void:
	var r := element_rect(e)
	var cv := int(e["cv"])
	var st := _cv_state(cv)
	var sel := (cv == selected_cv and selected_cv >= 0) or str(e["id"]) == selected_id
	var hov := str(e["id"]) == _hover_id
	var u: Dictionary = (state.get("unit", {}) as Dictionary).get(cv, {}) as Dictionary
	var es: Dictionary = (state.get("el", {}) as Dictionary).get(str(e["id"]), {}) as Dictionary
	var pic: Variant = icons.get(str(e["id"]))
	if bool(e.get("icon", false)) and pic is Texture2D:
		MimicSymbols.equipment_icon(self, r, pic as Texture2D, {"selected": sel, "hover": hov,
			"running": bool(es.get("running", false)), "warn": bool(es.get("warn", false)),
			"on": bool(es.get("open", str(e["kind"]) == "group")), "group": str(e["kind"]) == "group",
			"source": str(e["kind"]) == "source"})
		return
	var gl: Variant = glyphs.get(str(e["id"]))
	match str(e["kind"]):
		"tank":
			MimicSymbols.vessel(self, r, {"selected": sel, "hover": hov, "lid": true, "dome_h": minf(r.size.x * 0.14, 22.0 * _zoom + 4.0),
				"level": float(es.get("level", 0.0)), "liquid": es.get("color", MimicSymbols.LIQUID), "gas": MimicSymbols.EMPTY, "ticks": true})
			# Its own inlet / outlet valves show only when shut.
			var vs := maxf(26.0 * _zoom, 12.0)
			if not es.is_empty() and not bool(es.get("in_open", true)):
				MimicSymbols.port_valve(self, Vector2(r.position.x - vs * 0.2, r.get_center().y), vs, false)
			if not es.is_empty() and not bool(es.get("out_open", true)):
				MimicSymbols.port_valve(self, Vector2(r.end.x + vs * 0.2, r.get_center().y), vs, false)
		"machine", "source":
			MimicSymbols.machine(self, r, {"selected": sel, "hover": hov, "running": bool(es.get("running", false)),
				"warn": bool(es.get("warn", false)), "on": bool(es.get("open", false)),
				"accent": MimicSymbols.WARN if str(e["kind"]) == "source" else MimicSymbols.STEEL_LIGHT, "glyph": gl})
		"pump":
			MimicSymbols.pump(self, r, {"selected": sel, "hover": hov, "running": bool(es.get("running", false)),
				"warn": bool(es.get("warn", false)), "on": bool(es.get("open", false)), "phase": _phase})
		"group":
			MimicSymbols.group(self, r, sel, hov)
		"device":
			MimicSymbols.device(self, r, {"selected": sel, "hover": hov, "on": bool(es.get("open", true)),
				"warn": bool(es.get("warn", false)), "glyph": str(e.get("glyph", "box")), "pictogram": gl})
		"vessel":
			# The head: from the shell's top seam up to the top of the part
			# (its lid, or the cone / reducer a column stands on).
			var part_top := to_screen(moved_pos(e) - Vector2(0, (e["size"] as Vector2).y * 0.5)).y
			var o := {"selected": sel, "hover": hov, "lid": true, "dome_h": clampf(r.position.y - part_top, 0.0, r.size.x * 0.6),
				"jacket": int(e.get("jacket_cv", -1)) >= 0, "level": float(st.get("level", 0.0)),
				"gas": MimicSymbols.heat_rgb(float(st.get("t_c", 20.0))).darkened(0.35) if not st.is_empty() else MimicSymbols.EMPTY}
			if bool(o["jacket"]):
				o["jacket_col"] = MimicSymbols.STEEL.darkened(0.25).lerp(MimicSymbols.heat_rgb(float(st.get("wall_c", 20.0))), 0.35)
			var bed: Dictionary = state.get("bed", {}) as Dictionary
			if not bed.is_empty() and float(e.get("shell_h", 0.0)) > 1.0:
				var wet := Color(0.56, 0.42, 0.24)
				var dry := Color(0.74, 0.60, 0.38)
				var col := wet.lerp(dry, float(bed.get("dry", 0.0))).lerp(Color(0.07, 0.07, 0.08), float(bed.get("char", 0.0)))
				if bool(bed.get("plastic", false)):
					col = Color(0.80, 0.82, 0.86).lerp(Color(0.55, 0.45, 0.25), clampf((float(bed.get("t_mean_c", 20.0)) - 130.0) / 250.0, 0.0, 1.0))
				o["bed"] = {"h": float(bed.get("height_mm", 0.0)) / float(e["shell_h"]), "col": col,
					"glow": clampf((float(bed.get("t_max_c", 20.0)) - 420.0) / 380.0, 0.0, 1.0)}
			MimicSymbols.vessel(self, r, o)
		"holder":
			MimicSymbols.holder(self, r, float(u.get("fill", 0.0)), sel, hov)
		"engine":
			MimicSymbols.engine(self, r, float(u.get("kw", 0.0)) > 0.001, sel, hov, _phase)
		"dryer":
			MimicSymbols.dryer(self, r, float(u.get("fill", 0.0)), sel, hov)
		"flare":
			MimicSymbols.flare(self, r, float(u.get("kw", 0.0)), sel, hov, _phase)


func _draw_small(e: Dictionary) -> void:
	var r := element_rect(e)
	var c := r.get_center()
	var sel := str(e["id"]) == selected_id
	var hov := str(e["id"]) == _hover_id
	var kind := str(e["kind"])
	match kind:
		"valve", "check", "relief":
			var ls: Dictionary = (state.get("link", {}) as Dictionary).get(int(e["link"]), {}) as Dictionary
			if int(e["link"]) < 0:
				ls = (state.get("el", {}) as Dictionary).get(str(e["id"]), {}) as Dictionary
			MimicSymbols.valve(self, c, r.size.x, e.get("dir", Vector2.RIGHT), kind, bool(ls.get("open", true)), sel, hov)
		"heater":
			var hs: Dictionary = (state.get("heater", {}) as Dictionary).get(str(e["part"]), {}) as Dictionary
			var hoff := offset_of(str(e["id"]))
			MimicSymbols.heater(self, to_screen((e["from"] as Vector2) + hoff), to_screen((e["to"] as Vector2) + hoff), maxf(8.0 * _zoom * 2.0, 4.0),
				bool(hs.get("on", false)), float(hs.get("t_c", 20.0)), bool(hs.get("fused", false)), sel, hov)
		"instr":
			var ist: Dictionary = (state.get("el", {}) as Dictionary).get(str(e["id"]), {}) as Dictionary
			var ir := maxf(r.size.x * 0.5, 9.0)
			MimicSymbols.instrument(self, c, ir, str(e.get("letters", "I")), _font, sel, hov)
			var iv := str(ist.get("value", ""))
			if not iv.is_empty() and _font != null:
				MimicSymbols.tag(self, c + Vector2(ir + 5.0, -TAG_FS * 0.5 - 3.0), iv, _font, TAG_FS,
					MimicSymbols.WARN if bool(ist.get("warn", false)) else MimicSymbols.TEXT,
					MimicSymbols.WARN if bool(ist.get("warn", false)) else MimicSymbols.STEEL)
		"probe_t", "probe_p", "probe_well", "probe_l", "probe_ls":
			var into: Vector2 = e.get("into", Vector2.ZERO)
			var out := c - into.normalized() * maxf(r.size.x, 22.0) * 0.9 if into.length() > 0.1 else c
			draw_line(c, out, MimicSymbols.STEEL_LIGHT, 1.5, true)
			MimicSymbols.instrument(self, out, maxf(r.size.x * 0.5, 10.0), {"probe_t": "TI", "probe_p": "PI", "probe_well": "TW", "probe_l": "LT", "probe_ls": "LS"}[kind], _font, sel, hov)
		"end":
			var es: Dictionary = (state.get("end", {}) as Dictionary).get(int(e["bnd"]), {}) as Dictionary
			MimicSymbols.end(self, c, r.size.x, e.get("dir", Vector2.UP), str(e.get("role", "")), bool(es.get("open", true)),
				absf(float(es.get("flow", 0.0))) > 1e-7, sel, hov)


func _draw_tags() -> void:
	if _font == null:
		return
	var placed: Array = []
	for e in doc.get("elements", []):
		var kind := str(e["kind"])
		if kind == "widget":
			continue
		var id := str(e["id"])
		var r := element_rect(e)
		var focus := id == _hover_id or id == selected_id or (int(e["cv"]) == selected_cv and selected_cv >= 0 and kind in BIG)
		var lines: Array = []
		if kind != "vessel" and kind != "holder" and _behind(e):
			continue
		if kind in BIG:
			if show_values or focus:
				# The reading stands ON the equipment (its top), the name under it.
				var val := _equipment_value(e)
				if bool(e.get("icon", false)) and icons.get(id) is Texture2D:
					# On a picture the reading goes under it with the name (where
					# labels already keep clear of each other), never across it.
					if not val.is_empty():
						lines.append([val, MimicSymbols.TEXT])
				elif not val.is_empty():
					var vs := _font.get_string_size(val, HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FS + 1)
					MimicSymbols.tag(self, Vector2(r.get_center().x - vs.x * 0.5 - 6.0, r.position.y + 8.0), val, _font, TAG_FS + 1)
			if show_names or focus:
				lines.append([str(e["label"]), MimicSymbols.TEXT_DIM])
		elif kind == "end":
			var lab := str(e.get("label", ""))
			# Cooling water ends come in pairs on every condenser: named on hover.
			if str(e.get("role", "")).begins_with("coolant") and not focus:
				lab = ""
			if lab.is_empty() and focus:
				lab = {"atmosphere": "Open to the air", "plug": "Plugged", "feed": "Feed", "product": "Product",
					"drain": "Drain", "outlet": "Outlet", "coolant_in": "Cooling water in", "coolant_out": "Cooling water out"}.get(str(e.get("role", "")), "")
			if not lab.is_empty():
				lines.append([lab, MimicSymbols.TEXT_DIM])
		elif kind == "heater":
			var hs: Dictionary = (state.get("heater", {}) as Dictionary).get(str(e["part"]), {}) as Dictionary
			if not hs.is_empty() and (bool(hs.get("on", false)) or focus):
				var ht := "%s W" % UiText.num(float(hs.get("w", 0.0)) if bool(hs.get("on", false)) else 0.0, "", 3)
				# An element in a liquid has no temperature of its own in the model.
				if float(hs.get("t_c", 20.0)) > 40.0:
					ht += " · %d °C" % int(round(float(hs.get("t_c", 20.0))))
				lines.append([ht, MimicSymbols.TEXT])
		elif focus or (int(e["link"]) < 0 and kind in ["valve", "check"]):
			lines.append([str(e.get("label", "")), MimicSymbols.TEXT_DIM])
			if kind in ["valve", "check", "relief"]:
				var ls: Dictionary = (state.get("link", {}) as Dictionary).get(int(e["link"]), {}) as Dictionary
				if int(e["link"]) < 0:
					ls = (state.get("el", {}) as Dictionary).get(id, {}) as Dictionary
				if focus:
					lines.append(["open" if bool(ls.get("open", true)) else "closed", MimicSymbols.OPEN if bool(ls.get("open", true)) else MimicSymbols.CLOSED])
		var y := r.end.y + 4.0
		for ln in lines:
			if str(ln[0]).is_empty():
				continue
			var sz := _font.get_string_size(str(ln[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FS)
			var tr := Rect2(Vector2(r.get_center().x - sz.x * 0.5 - 6.0, y), Vector2(sz.x + 12.0, TAG_FS + 8.0))
			var clash := false
			if not focus:
				for q in placed:
					if (q as Rect2).intersects(tr):
						clash = true
						break
			if clash:
				continue
			MimicSymbols.tag(self, tr.position, str(ln[0]), _font, TAG_FS, ln[1])
			placed.append(tr)
			y += TAG_FS + 10.0
	# The hovered / selected pipe: its volume's numbers at its middle.
	for p in doc.get("pipes", []):
		var cv := int(p["cv"])
		if str(p["id"]) != _hover_pipe and str(p["id"]) != selected_id \
				and not (cv == selected_cv and selected_cv >= 0 and _first_pipe_of(cv) == str(p["id"])):
			continue
		var st := _cv_state(cv)
		var gp: Dictionary = (state.get("pipe", {}) as Dictionary).get(str(p["id"]), {}) as Dictionary
		if not gp.is_empty():
			var gl := _pipe_line(p)
			var gm: Vector2 = MimicLayout.point_at(gl, MimicLayout.length_of(gl) * 0.5)[0]
			var gt := str(p["label"])
			if gp.has("text"):
				gt = str(gp["text"])
			else:
				gt += " · %s/h" % UiText.num(float(gp.get("rate", 0.0)), str(gp.get("unit", "")), 3) if float(gp.get("rate", 0.0)) > 1e-6 else " · still"
			MimicSymbols.tag(self, gm + Vector2(10.0, -TAG_FS - 14.0), gt, _font, TAG_FS, MimicSymbols.TEXT, MimicSymbols.SELECT)
			continue
		if st.is_empty():
			continue
		var sl := _pipe_line(p)
		var mid: Vector2 = MimicLayout.point_at(sl, MimicLayout.length_of(sl) * 0.5)[0]
		var txt := "%s · %d °C" % [str(p["label"]), int(round(float(st.get("t_c", 20.0))))]
		if float(st.get("liquid_l", 0.0)) > 0.005:
			txt += " · %s L liquid" % UiText.num(float(st["liquid_l"]), "", 2)
		MimicSymbols.tag(self, mid + Vector2(10.0, -TAG_FS - 14.0), txt, _font, TAG_FS, MimicSymbols.TEXT, MimicSymbols.SELECT)


func _first_pipe_of(cv: int) -> String:
	for p in doc.get("pipes", []):
		if int(p["cv"]) == cv:
			return str(p["id"])
	return ""


func _equipment_value(e: Dictionary) -> String:
	var es: Dictionary = (state.get("el", {}) as Dictionary).get(str(e["id"]), {}) as Dictionary
	if not es.is_empty():
		return str(es.get("value", ""))
	var cv := int(e["cv"])
	var st := _cv_state(cv)
	var u: Dictionary = (state.get("unit", {}) as Dictionary).get(cv, {}) as Dictionary
	match str(e["kind"]):
		"vessel":
			if st.is_empty():
				return ""
			var bed: Dictionary = state.get("bed", {}) as Dictionary
			var t := float(bed.get("t_max_c", st.get("t_c", 20.0))) if not bed.is_empty() else float(st.get("t_c", 20.0))
			var s := "%d °C · %s kPa" % [int(round(t)), UiText.num(float(st.get("p_kpa", 0.0)), "", 2)]
			if bed.is_empty() and float(st.get("liquid_l", 0.0)) > 0.05:
				s += " · %s L" % UiText.num(float(st["liquid_l"]), "", 3)
			return s
		"holder":
			return "%d %% full" % int(round(float(u.get("fill", 0.0)) * 100.0))
		"engine":
			return "%s W" % UiText.num(float(u.get("kw", 0.0)) * 1000.0, "", 3) if float(u.get("kw", 0.0)) > 0.001 else "off"
		"dryer":
			return "%d %% used" % int(round(float(u.get("fill", 0.0)) * 100.0))
		"flare":
			return "%s kW" % UiText.num(float(u.get("kw", 0.0)), "", 2) if float(u.get("kw", 0.0)) > 0.01 else "not lit"
	return ""
