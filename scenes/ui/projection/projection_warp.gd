class_name ProjectionWarp
extends Control

## Corner-pin projection mapping over any texture: the source is cut into 1, 2
## or 4 regions (full / left|right / 2x2) and each region is drawn into a quad
## whose four corners the player drags onto the physical surface. The map is a
## true PERSPECTIVE corner pin (a homography per quad, solved on the CPU and
## inverted per pixel in the shader), not two affine triangles — a Polygon2D
## quad bends its texture along the diagonal as soon as the corners stop
## being a parallelogram.
##
## One component for both projection views (the projection canvas, I, and the
## POV warp overlay, Z). Corners are stored as FRACTIONS of this control's
## size, so a window resize keeps a calibration where it was on the wall.
## Keys act only while the host is on screen:
##   toggle_projection_warp (F9)          warp on / off (when `toggle_key`)
##   toggle_projection_calibration (F10)  calibrate (drag the corners)
##   reset_projection_warp (F8)           corners back to the unwarped layout
##   Enter saves, Tab picks the next quad, Esc leaves calibration.

signal warp_changed(active: bool)
signal calibration_changed(on: bool)

const CONFIG_VERSION := 2
const HANDLE_R := 9.0
const PICK_R := 22.0
const SHADER := preload("res://scenes/ui/projection/projection_warp.gdshader")

## Where the corners are saved (user://, ConfigFile).
var config_path := "user://projection_warp.cfg"
## 1, 2 or 4 regions of the source.
var quad_count := 4
## F9 toggles the warp. False when the host has its own toggle (the POV
## overlay's Z).
var toggle_key := true
## Black outside the quads while warped (a projector shows nothing there).
var backdrop := true
## Title shown on the calibration panel.
var title := "Projection mapping"
## Called with no arguments; keys are live only while it returns true. Unset =
## live while the parent is visible in the tree.
var key_gate: Callable = Callable()

var active := false
var calibrating := false
var active_quad := 0

var _source: Texture2D = null
var _quads: Array = []          # Array[PackedVector2Array] of normalized corners
var _rects: Array = []          # ColorRect per quad (shader)
var _backdrop: ColorRect = null
var _handles: Control = null    # drawn over the quads (a parent draws under its children)
var _panel: PanelContainer = null
var _panel_label: Label = null
var _drag_quad := -1
var _drag_corner := -1
var _has_saved := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## Build after the exports above are set (call once, after add_child).
func setup(source: Texture2D) -> void:
	_source = source
	quad_count = 4 if quad_count >= 4 else (2 if quad_count >= 2 else 1)
	_backdrop = ColorRect.new()
	_backdrop.color = Color.BLACK
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	for i in quad_count:
		var r := ColorRect.new()
		r.set_anchors_preset(Control.PRESET_FULL_RECT)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := ShaderMaterial.new()
		m.shader = SHADER
		r.material = m
		add_child(r)
		_rects.append(r)
	_quads = default_quads(quad_count)
	_handles = Control.new()
	_handles.name = "Handles"
	_handles.set_anchors_preset(Control.PRESET_FULL_RECT)
	_handles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_handles.draw.connect(_draw_handles)
	add_child(_handles)
	_build_panel()
	load_config()
	if not resized.is_connected(_refresh):
		resized.connect(_refresh)
	_refresh()


func set_source(tex: Texture2D) -> void:
	_source = tex
	_refresh()


func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	if not on:
		_set_calibrating(false)
	elif not _has_saved:
		_set_calibrating(true)   # nothing saved yet: open on the handles
	_apply_visibility()
	warp_changed.emit(active)


func toggle_active() -> void:
	set_active(not active)


func toggle_calibration() -> void:
	if not active:
		set_active(true)
	_set_calibrating(not calibrating)


## The quads' corners as fractions of this control (copies).
func quads() -> Array:
	var out: Array = []
	for q in _quads:
		out.append(PackedVector2Array(q))
	return out


func set_corner(quad: int, corner: int, frac: Vector2) -> void:
	if quad < 0 or quad >= _quads.size() or corner < 0 or corner > 3:
		return
	var q: PackedVector2Array = _quads[quad]
	q[corner] = Vector2(clampf(frac.x, -0.5, 1.5), clampf(frac.y, -0.5, 1.5))
	_quads[quad] = q
	_refresh()


func reset_corners() -> void:
	_quads = default_quads(quad_count)
	_refresh()


func has_saved() -> bool:
	return _has_saved


# ---- pure maths ---------------------------------------------------------------

## The unwarped layout: region i of the source drawn where it is (fractions,
## corners in the order top-left, top-right, bottom-right, bottom-left).
static func default_quads(n: int) -> Array:
	var out: Array = []
	for i in n:
		var r := source_region(n, i)
		out.append(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y),
			r.end, Vector2(r.position.x, r.end.y)]))
	return out


## Region i of a source cut into n (UV rect, 0..1).
static func source_region(n: int, i: int) -> Rect2:
	if n >= 4:
		return Rect2(Vector2(0.5 * float(i % 2), 0.5 * float(i / 2)), Vector2(0.5, 0.5))
	if n == 2:
		return Rect2(Vector2(0.5 * float(i), 0.0), Vector2(0.5, 1.0))
	return Rect2(0.0, 0.0, 1.0, 1.0)


## The homography taking the unit square (0,0)(1,0)(1,1)(0,1) onto the quad
## (Heckbert 1989, "Fundamentals of Texture Mapping", §2.2.3), as a Basis whose
## COLUMNS are the matrix columns: m * Vector3(u, v, 1) = (x w, y w, w). A Basis
## is what a shader `mat3` uniform takes, column for column, so the GLSL
## `m * vec3` is the same product. Returns a zero Basis for a degenerate quad.
static func homography(q: PackedVector2Array) -> Basis:
	if q.size() != 4:
		return Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var p0 := q[0]
	var p1 := q[1]
	var p2 := q[2]
	var p3 := q[3]
	var sx := p0.x - p1.x + p2.x - p3.x
	var sy := p0.y - p1.y + p2.y - p3.y
	var a: float
	var b: float
	var d: float
	var e: float
	var g := 0.0
	var h := 0.0
	if absf(sx) < 1e-12 and absf(sy) < 1e-12:
		a = p1.x - p0.x
		b = p3.x - p0.x
		d = p1.y - p0.y
		e = p3.y - p0.y
	else:
		var dx1 := p1.x - p2.x
		var dx2 := p3.x - p2.x
		var dy1 := p1.y - p2.y
		var dy2 := p3.y - p2.y
		var den := dx1 * dy2 - dx2 * dy1
		if absf(den) < 1e-12:
			return Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		g = (sx * dy2 - dx2 * sy) / den
		h = (dx1 * sy - sx * dy1) / den
		a = p1.x - p0.x + g * p1.x
		b = p3.x - p0.x + h * p3.x
		d = p1.y - p0.y + g * p1.y
		e = p3.y - p0.y + h * p3.y
	return Basis(Vector3(a, d, g), Vector3(b, e, h), Vector3(p0.x, p0.y, 1.0))


## Apply a homography to a point (NaN when it maps to infinity).
static func apply(m: Basis, p: Vector2) -> Vector2:
	var r := m * Vector3(p.x, p.y, 1.0)
	if absf(r.z) < 1e-12:
		return Vector2(NAN, NAN)
	return Vector2(r.x / r.z, r.y / r.z)


## A quad a corner pin can draw: convex, corners in order, not collapsed.
static func is_valid_quad(q: PackedVector2Array) -> bool:
	if q.size() != 4:
		return false
	var turn := 0.0
	for i in 4:
		var a := q[i]
		var b := q[(i + 1) % 4]
		var c := q[(i + 2) % 4]
		var cr := (b - a).cross(c - b)
		if absf(cr) < 1e-9:
			return false
		if turn == 0.0:
			turn = signf(cr)
		elif signf(cr) != turn:
			return false
	return true


# ---- config ---------------------------------------------------------------------

func save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("warp", "version", CONFIG_VERSION)
	cfg.set_value("warp", "quads", quad_count)
	cfg.set_value("warp", "active", active)
	for i in _quads.size():
		cfg.set_value("warp", "q%d" % i, PackedVector2Array(_quads[i]))
	if cfg.save(config_path) == OK:
		_has_saved = true
	_update_panel()


## Reads `config_path`. A version-1 file (absolute pixels, keys TL/TR/BL/BR,
## from before 2026-10-23) is converted: points divided by the size it was
## saved at (`canvas_size`, else this control's size), TL/TR feeding a
## two-quad layout's left/right. `legacy_path` is read when `config_path` has
## nothing (the canvas's old file name).
func load_config(legacy_path: String = "") -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(config_path)
	if err != OK and legacy_path != "":
		err = cfg.load(legacy_path)
	if err != OK:
		_has_saved = false
		return
	var ver := int(cfg.get_value("warp", "version", 0))
	var loaded := default_quads(quad_count)
	var any := false
	if ver == CONFIG_VERSION and int(cfg.get_value("warp", "quads", quad_count)) == quad_count:
		for i in quad_count:
			var q: Variant = cfg.get_value("warp", "q%d" % i, null)
			if q is PackedVector2Array and (q as PackedVector2Array).size() == 4:
				loaded[i] = q
				any = true
	elif ver == 1:
		var base: Variant = cfg.get_value("warp", "canvas_size", null)
		var sz: Vector2 = base if base is Vector2 else size
		if sz.x <= 1.0 or sz.y <= 1.0:
			sz = Vector2(1920.0, 1080.0)
		var keys: Array = ["TL", "TR", "BL", "BR"]
		for i in quad_count:
			var p: Variant = cfg.get_value("warp", keys[i], null)
			if p is PackedVector2Array and (p as PackedVector2Array).size() == 4:
				var q := PackedVector2Array()
				for v in (p as PackedVector2Array):
					q.append(Vector2(v.x / sz.x, v.y / sz.y))
				loaded[i] = q
				any = true
	_quads = loaded
	_has_saved = any
	_refresh()


# ---- drawing + input --------------------------------------------------------------

func _refresh() -> void:
	var sz := size
	for i in _rects.size():
		var r: ColorRect = _rects[i]
		var m := r.material as ShaderMaterial
		var q: PackedVector2Array = _quads[i]
		var px := PackedVector2Array()
		for v in q:
			px.append(Vector2(v.x * sz.x, v.y * sz.y))
		var h := homography(px)
		var ok := h.determinant() != 0.0 and is_valid_quad(px)
		r.visible = ok
		if ok:
			m.set_shader_parameter("h_inv", h.inverse())
			m.set_shader_parameter("uv_rect", _rect_vec(source_region(quad_count, i)))
			m.set_shader_parameter("src", _source)
	if _backdrop != null:
		_backdrop.visible = backdrop
	_redraw_handles()


func _redraw_handles() -> void:
	if _handles != null:
		_handles.queue_redraw()
	_place_panel()


## Pick a quad to work on (its corners win a pick where quads touch).
func select_quad(i: int) -> void:
	active_quad = clampi(i, 0, maxi(_quads.size() - 1, 0))
	_update_panel()
	_redraw_handles()


## The panel sits top-centre unless a corner is under it (it would be
## ungrabbable there); then mid-screen (the bottom is where the timeline is).
func _place_panel() -> void:
	if _panel == null:
		return
	_panel.reset_size()
	var w := _panel.get_combined_minimum_size().x
	var h := _panel.get_combined_minimum_size().y
	var top := Rect2(Vector2((size.x - w) * 0.5, 24.0), Vector2(w, h)).grow(HANDLE_R + 4.0)
	var blocked := false
	for q in _quads:
		for v in (q as PackedVector2Array):
			if top.has_point(Vector2(v.x * size.x, v.y * size.y)):
				blocked = true
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2((size.x - w) * 0.5, (size.y - h) * 0.5 if blocked else 24.0)


static func _rect_vec(r: Rect2) -> Vector4:
	return Vector4(r.position.x, r.position.y, r.size.x, r.size.y)


func _apply_visibility() -> void:
	visible = active
	mouse_filter = Control.MOUSE_FILTER_STOP if active and calibrating else Control.MOUSE_FILTER_IGNORE
	if _panel != null:
		_panel.visible = active and calibrating
	_update_panel()
	_redraw_handles()


func _set_calibrating(on: bool) -> void:
	if calibrating == on:
		return
	calibrating = on and active
	_drag_quad = -1
	_apply_visibility()
	calibration_changed.emit(calibrating)


func _draw_handles() -> void:
	if not (active and calibrating):
		return
	var sz := size
	for i in _quads.size():
		var q: PackedVector2Array = _quads[i]
		var col := UITheme.C_AMBER if i == active_quad else UITheme.C_PRIMARY
		var w := 3.0 if i == active_quad else 1.5
		var pts := PackedVector2Array()
		for v in q:
			pts.append(Vector2(v.x * sz.x, v.y * sz.y))
		pts.append(pts[0])
		_handles.draw_polyline(pts, col, w, true)
		var c := (pts[0] + pts[1] + pts[2] + pts[3]) * 0.25
		_handles.draw_string(UITheme.font("semibold"), c + Vector2(-6, 8), str(i + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 28, col)
		for k in 4:
			_handles.draw_circle(pts[k], HANDLE_R + 3.0, Color(0, 0, 0, 0.7))
			_handles.draw_circle(pts[k], HANDLE_R, col)


func _gui_input(event: InputEvent) -> void:
	if not (active and calibrating):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var hit := _pick(mb.position)
			if hit.x >= 0:
				_drag_quad = hit.x
				_drag_corner = hit.y
				select_quad(hit.x)
		else:
			_drag_quad = -1
		accept_event()
	elif event is InputEventMouseMotion and _drag_quad >= 0:
		var p := (event as InputEventMouseMotion).position
		set_corner(_drag_quad, _drag_corner, Vector2(p.x / maxf(size.x, 1.0), p.y / maxf(size.y, 1.0)))
		accept_event()


## The corner under a point: (quad, corner), active quad first; (-1, -1).
func _pick(p: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := PICK_R
	var order: Array = [active_quad]
	for i in _quads.size():
		if i != active_quad:
			order.append(i)
	for i in order:
		var q: PackedVector2Array = _quads[i]
		for k in 4:
			var d := p.distance_to(Vector2(q[k].x * size.x, q[k].y * size.y))
			if d < best_d - 0.5:
				best_d = d
				best = Vector2i(i, k)
	return best


func _keys_live() -> bool:
	if key_gate.is_valid():
		return bool(key_gate.call())
	var p := get_parent() as CanvasItem
	return p != null and p.is_visible_in_tree()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey or event is InputEventAction) or not event.is_pressed() or event.is_echo():
		return
	if not _keys_live():
		return
	var k := event as InputEventKey
	var code := k.keycode if k != null else KEY_NONE
	if toggle_key and event.is_action_pressed(&"toggle_projection_warp"):
		toggle_active()
	elif event.is_action_pressed(&"toggle_projection_calibration"):
		toggle_calibration()
	elif event.is_action_pressed(&"reset_projection_warp") and active:
		reset_corners()
	elif calibrating and (code == KEY_ENTER or code == KEY_KP_ENTER):
		save_config()
	elif calibrating and code == KEY_TAB:
		select_quad((active_quad + 1) % maxi(_quads.size(), 1))
	elif calibrating and code == KEY_ESCAPE:
		_set_calibrating(false)
	else:
		return
	get_viewport().set_input_as_handled()


# ---- calibration panel -------------------------------------------------------------

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.94))
	_panel.visible = false
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_panel.add_child(v)
	var t := Label.new()
	t.text = title
	t.add_theme_font_override("font", UITheme.font("semibold"))
	t.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	t.add_theme_color_override("font_color", UITheme.C_TEXT)
	v.add_child(t)
	_panel_label = Label.new()
	_panel_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_label.custom_minimum_size = Vector2(500, 0)   # autowrap needs a width to measure against
	_panel_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_panel_label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	v.add_child(_panel_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	for spec in [["Next quad", func() -> void: select_quad((active_quad + 1) % maxi(_quads.size(), 1))],
		["Reset", reset_corners],
		["Save", save_config],
		["Done", func() -> void: _set_calibrating(false)],
		["Turn off warp", func() -> void: set_active(false)]]:
		var b := Button.new()
		b.text = str(spec[0])
		UITheme.style_button(b)
		b.pressed.connect(spec[1])
		row.add_child(b)


func _update_panel() -> void:
	if _panel_label == null:
		return
	var sizes := "Quad %d of %d" % [active_quad + 1, _quads.size()] if _quads.size() > 1 else "One quad"
	_panel_label.text = "%s · %s. Drag the corners onto the surface. Tab next quad · F8 reset · Enter save · Esc done." % [
		sizes, "saved" if _has_saved else "not saved yet"]
	_place_panel()
