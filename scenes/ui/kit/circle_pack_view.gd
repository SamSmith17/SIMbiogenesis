class_name CirclePackView
extends Control

## A zoomable circle-pack picture of a tree (CirclePack.layout), dark theme.
##
##   view.set_tree(tree, {fmt, padding})  lay out and show (a tree whose root
##       id matches the one showing glides to its new values; another grows
##       in from the middle, ring by ring)
##   view.zoom_to(i) / zoom_out() / zoom_home()
##
## Input: click a group to fly into it (van Wijk & Nuij 2003 smooth zoom, the
## path d3.interpolateZoom takes), click a leaf to select it, double-click to
## activate it, right-click or Backspace to go up a level, Home for the
## whole, the wheel zooms about the pointer, a drag pans.
## Drawing: groups are tinted discs with a coloured rim, leaves solid with a
## soft sheen; names sit on a dark pill at the top of a group and in the
## middle of a leaf (text in text colours, never the series colour). Every
## disc comes from ONE mipmapped 512 px texture drawn at any size (a disc
## per size, as GraphFastDraw keeps, built a new texture every frame of a
## zoom); past 512 px a disc is a polygon. Rims are anti-aliased arcs, a
## fixed pixel width at any zoom. Off-screen and sub-pixel circles skip their
## whole subtree.

signal focus_changed(index: int)
signal hovered(index: int)
signal selected(index: int)
signal activated(index: int)

const FIT := 0.94             # share of the half-size the focus circle fills
const RHO := 1.41421356       # van Wijk ρ (√2, d3's default)
const ZOOM_SPEED := 0.85      # × d3's duration
const MORPH_S := 0.7
const GROW_S := 0.45
const GROW_STAGGER_S := 0.07  # per depth
const TEX_MAX_PX := 512.0
const MAX_LABELS := 180
const LABEL_MIN_LEAF_PX := 20.0
const LABEL_MIN_GROUP_PX := 34.0

var lay: Dictionary = {}
var nodes: Array = []
## Value text: fmt.call(value, unit) -> String.
var fmt: Callable = Callable()
var focus := 0
var hover := -1
var sel := -1

var _cx := 0.0
var _cy := 0.0
var _vr := CirclePack.RADIUS
var _zoom_on := false
var _zoom_t := 0.0
var _zoom_dur := 0.6
var _zf := {}   # van Wijk parameters
var _prev: Dictionary = {}   # id -> [x, y, r] before a refresh
var _morph := 1.0
var _grow := 99.0
var _clock := 0.0
var _drag_from := Vector2.INF
var _drag_moved := false
var _font: Font = null
var _fit_cache: Dictionary = {}


static var _disc_t: Texture2D = null
static var _glow_t: Texture2D = null


## A white disc with a one-texel soft edge, mipmapped: sampled at any size it
## covers exactly the circle's pixels.
static func _disc_tex() -> Texture2D:
	if _disc_t != null:
		return _disc_t
	var n := 512
	var c := (float(n) - 1.0) * 0.5
	var rr := float(n) * 0.5 - 1.0
	var bytes := PackedByteArray()
	bytes.resize(n * n * 4)
	bytes.fill(255)
	for y in n:
		var dy := float(y) - c
		for x in n:
			var dx := float(x) - c
			bytes[(y * n + x) * 4 + 3] = int(clampf(rr - sqrt(dx * dx + dy * dy) + 0.5, 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, bytes)
	img.generate_mipmaps()
	_disc_t = ImageTexture.create_from_image(img)
	return _disc_t


## A soft radial glow (the backdrop behind the pack).
static func _glow_tex() -> Texture2D:
	if _glow_t != null:
		return _glow_t
	var g := GradientTexture2D.new()
	g.width = 256
	g.height = 256
	g.fill = GradientTexture2D.FILL_RADIAL
	g.fill_from = Vector2(0.5, 0.5)
	g.fill_to = Vector2(1.0, 0.5)
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 1))
	gr.set_color(1, Color(1, 1, 1, 0))
	g.gradient = gr
	_glow_t = g
	return _glow_t


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = get_theme_default_font()


func set_tree(tree: Dictionary, opts: Dictionary = {}) -> void:
	if opts.has("fmt"):
		fmt = opts["fmt"]
	var same_root := not nodes.is_empty() and str(tree.get("id", "")) == str((nodes[0] as Dictionary)["id"])
	var old_focus_id := str((nodes[focus] as Dictionary)["id"]) if not nodes.is_empty() and focus < nodes.size() else ""
	_prev.clear()
	if same_root:
		for i in nodes.size():
			var d: Dictionary = nodes[i]
			var p := _draw_xyr(i)
			_prev[str(d["id"])] = [p.x, p.y, p.z]
	lay = CirclePack.layout(tree, {"padding": float(opts.get("padding", 7.0))})
	nodes = lay.get("nodes", []) as Array
	_fit_cache.clear()
	hover = -1
	if same_root:
		_morph = 0.0
		var fi := int((lay["index"] as Dictionary).get(old_focus_id, 0)) if not old_focus_id.is_empty() else 0
		focus = fi
		if sel >= nodes.size():
			sel = -1
		_set_camera_to(focus)
	else:
		_morph = 1.0
		_grow = 0.0
		focus = 0
		sel = -1
		_set_camera_to(0)
		var want := str(opts.get("focus_id", ""))
		if not want.is_empty() and (lay["index"] as Dictionary).has(want):
			zoom_to(int(lay["index"][want]), true)
	focus_changed.emit(focus)
	queue_redraw()


func is_empty() -> bool:
	return nodes.is_empty()


func node(i: int) -> Dictionary:
	return nodes[i] if i >= 0 and i < nodes.size() else {}


func index_of(id: String) -> int:
	return int((lay.get("index", {}) as Dictionary).get(id, -1))


## Fly to node i (a leaf: to its parent, with the leaf selected).
func zoom_to(i: int, instant: bool = false) -> void:
	if i < 0 or i >= nodes.size():
		return
	var n: Dictionary = nodes[i]
	var target := i
	if bool(n["leaf"]) and int(n["parent"]) >= 0:
		target = int(n["parent"])
		sel = i
	focus = target
	var t: Dictionary = nodes[target]
	var to := Vector3(float(t["x"]), float(t["y"]), float(t["r"]))
	if instant or not is_inside_tree():
		_cx = to.x
		_cy = to.y
		_vr = to.z
		_zoom_on = false
	else:
		_start_fly(Vector3(_cx, _cy, _vr), to)
	focus_changed.emit(focus)
	queue_redraw()


func zoom_out() -> void:
	if nodes.is_empty():
		return
	var p := int((nodes[focus] as Dictionary)["parent"])
	zoom_to(maxi(p, 0))


func zoom_home() -> void:
	zoom_to(0)


func is_flying() -> bool:
	return _zoom_on


## Where node i is drawn now: Vector3(screen x, screen y, screen r).
func screen_circle(i: int) -> Vector3:
	var p := _draw_xyr(i)
	var s := _scale()
	var c := size * 0.5 + Vector2(p.x - _cx, p.y - _cy) * s
	return Vector3(c.x, c.y, p.z * s)


## The deepest drawn node under a point (view-local), or -1.
func pick(pos: Vector2) -> int:
	if nodes.is_empty():
		return -1
	var sc := screen_circle(0)
	if Vector2(sc.x, sc.y).distance_to(pos) > sc.z:
		return -1
	var cur := 0
	var guard := 0
	while guard < 64:
		guard += 1
		var kids: PackedInt32Array = (nodes[cur] as Dictionary)["kids"]
		var next := -1
		for k in kids:
			var c := screen_circle(k)
			if c.z < 0.75:
				continue
			if Vector2(c.x, c.y).distance_to(pos) <= c.z:
				next = k
				break
		if next < 0:
			return cur
		cur = next
	return cur


func _set_camera_to(i: int) -> void:
	var t: Dictionary = nodes[i]
	_cx = float(t["x"])
	_cy = float(t["y"])
	_vr = float(t["r"])
	_zoom_on = false


func _scale() -> float:
	return minf(size.x, size.y) * 0.5 * FIT / maxf(_vr, 1e-6)


# --- smooth zoom (van Wijk & Nuij 2003) ------------------------------------

func _start_fly(a: Vector3, b: Vector3) -> void:
	var w0 := a.z * 2.0
	var w1 := b.z * 2.0
	var dx := b.x - a.x
	var dy := b.y - a.y
	var d2 := dx * dx + dy * dy
	var rho2 := RHO * RHO
	var rho4 := rho2 * rho2
	var z := {"x0": a.x, "y0": a.y, "w0": w0, "dx": dx, "dy": dy}
	var big_s := 0.0
	if d2 < 1e-9:
		big_s = log(maxf(w1, 1e-9) / maxf(w0, 1e-9)) / RHO
		z["flat"] = true
	else:
		var d1 := sqrt(d2)
		var b0 := (w1 * w1 - w0 * w0 + rho4 * d2) / (2.0 * w0 * rho2 * d1)
		var b1 := (w1 * w1 - w0 * w0 - rho4 * d2) / (2.0 * w1 * rho2 * d1)
		var r0 := log(sqrt(b0 * b0 + 1.0) - b0)
		var r1 := log(sqrt(b1 * b1 + 1.0) - b1)
		big_s = (r1 - r0) / RHO
		z["flat"] = false
		z["d1"] = d1
		z["r0"] = r0
	z["S"] = big_s
	_zf = z
	_zoom_t = 0.0
	_zoom_dur = clampf(absf(big_s) * ZOOM_SPEED, 0.35, 1.4)
	_zoom_on = true


func _fly_at(u: float) -> Vector3:
	var z := _zf
	var s := u * float(z["S"])
	if bool(z["flat"]):
		return Vector3(float(z["x0"]) + u * float(z["dx"]), float(z["y0"]) + u * float(z["dy"]),
			float(z["w0"]) * exp(RHO * s) * 0.5)
	var r0 := float(z["r0"])
	var ch := cosh(r0)
	var w0 := float(z["w0"])
	var uu := w0 / (RHO * RHO * float(z["d1"])) * (ch * tanh(RHO * s + r0) - sinh(r0))
	return Vector3(float(z["x0"]) + uu * float(z["dx"]), float(z["y0"]) + uu * float(z["dy"]),
		w0 * ch / cosh(RHO * s + r0) * 0.5)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_clock += delta
	var dirty := false
	if _zoom_on:
		_zoom_t += delta
		var u := clampf(_zoom_t / _zoom_dur, 0.0, 1.0)
		var e := u * u * (3.0 - 2.0 * u)
		var p := _fly_at(e)
		_cx = p.x
		_cy = p.y
		_vr = p.z
		if u >= 1.0:
			_zoom_on = false
		dirty = true
	if _morph < 1.0:
		_morph = minf(_morph + delta / MORPH_S, 1.0)
		dirty = true
	if _grow < 10.0:
		_grow += delta
		if _grow > GROW_S + GROW_STAGGER_S * 8.0:
			_grow = 99.0
		dirty = true
	if hover >= 0:
		dirty = true   # the hover glow breathes
	if dirty:
		queue_redraw()


## Layout position + radius of node i right now (value morph, growth).
func _draw_xyr(i: int) -> Vector3:
	var n: Dictionary = nodes[i]
	var x := float(n["x"])
	var y := float(n["y"])
	var r := float(n["r"])
	if _morph < 1.0:
		var e := _morph * _morph * (3.0 - 2.0 * _morph)
		var id := str(n["id"])
		if _prev.has(id):
			var p: Array = _prev[id]
			x = lerpf(float(p[0]), x, e)
			y = lerpf(float(p[1]), y, e)
			r = lerpf(float(p[2]), r, e)
		else:
			r *= e
	if _grow < 10.0:
		var g := clampf((_grow - GROW_STAGGER_S * float(n["depth"])) / GROW_S, 0.0, 1.0)
		g = 1.0 - pow(1.0 - g, 3.0)
		var pi := int(n["parent"])
		if pi >= 0:
			var pp := _draw_xyr(pi)
			x = lerpf(pp.x, x, g)
			y = lerpf(pp.y, y, g)
		r *= g
	return Vector3(x, y, r)


# --- input ------------------------------------------------------------------

func _gui_input(ev: InputEvent) -> void:
	if nodes.is_empty():
		return
	if ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if _drag_from != Vector2.INF and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			if mm.position.distance_to(_drag_from) > 4.0 or _drag_moved:
				_drag_moved = true
				var s := _scale()
				_cx -= mm.relative.x / s
				_cy -= mm.relative.y / s
				_zoom_on = false
				queue_redraw()
			return
		var h := pick(mm.position)
		if h != hover:
			hover = h
			hovered.emit(hover)
			queue_redraw()
		return
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_wheel(mb.position, 1.0 / 1.18 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.18)
				accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			zoom_out()
			accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			grab_focus()
			if mb.double_click:
				var hd := pick(mb.position)
				if hd >= 0:
					sel = hd
					selected.emit(hd)
					activated.emit(hd)
				_drag_from = Vector2.INF
				accept_event()
				return
			_drag_from = mb.position
			_drag_moved = false
			accept_event()
			return
		# Release: a click unless it was a drag.
		var was_drag := _drag_moved
		_drag_from = Vector2.INF
		_drag_moved = false
		if was_drag:
			_update_focus_from_view()
			return
		_click(mb.position)
		accept_event()


func _unhandled_key_input(ev: InputEvent) -> void:
	if not has_focus() or not ev is InputEventKey or not (ev as InputEventKey).pressed:
		return
	var k := ev as InputEventKey
	if k.keycode == KEY_BACKSPACE:
		zoom_out()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_HOME:
		zoom_home()
		get_viewport().set_input_as_handled()


func _click(pos: Vector2) -> void:
	var i := pick(pos)
	if i < 0:
		zoom_out()
		return
	var n: Dictionary = nodes[i]
	if bool(n["leaf"]):
		sel = i
		selected.emit(i)
		var p := int(n["parent"])
		if p >= 0 and p != focus:
			zoom_to(p)
			sel = i
		queue_redraw()
		return
	if i == focus:
		# A click on the focus itself (between its children): up a level.
		if i != 0:
			zoom_out()
		return
	sel = i
	selected.emit(i)
	zoom_to(i)


func _wheel(pos: Vector2, k: float) -> void:
	var s := _scale()
	var world := Vector2(_cx, _cy) + (pos - size * 0.5) / s
	var root_r := float((nodes[0] as Dictionary)["r"])
	_vr = clampf(_vr * k, root_r * 1e-5, root_r * 1.6)
	var s2 := _scale()
	_cx = world.x - (pos.x - size.x * 0.5) / s2
	_cy = world.y - (pos.y - size.y * 0.5) / s2
	_zoom_on = false
	_update_focus_from_view()
	queue_redraw()


## After a free zoom or pan: the deepest node that holds the middle of the
## view and still fills most of it becomes the focus (the breadcrumb).
func _update_focus_from_view() -> void:
	var mid := size * 0.5
	var half := minf(size.x, size.y) * 0.5
	var cur := 0
	var guard := 0
	while guard < 64:
		guard += 1
		var next := -1
		for k in ((nodes[cur] as Dictionary)["kids"] as PackedInt32Array):
			var c := screen_circle(k)
			if c.z >= half * 0.42 and Vector2(c.x, c.y).distance_to(mid) <= c.z:
				next = k
				break
		if next < 0:
			break
		cur = next
	if cur != focus:
		focus = cur
		focus_changed.emit(focus)


# --- drawing ----------------------------------------------------------------

func _draw() -> void:
	var bg := UITheme.C_BG
	draw_rect(Rect2(Vector2.ZERO, size), bg)
	# A faint glow behind the middle: depth without a frame.
	var mid := size * 0.5
	var big := minf(size.x, size.y) * 0.6
	draw_texture_rect(_glow_tex(), Rect2(mid - Vector2(big, big), Vector2(big, big) * 2.0), false,
		Color(0.16, 0.24, 0.42, 0.35))
	if nodes.is_empty():
		var f := _font if _font != null else get_theme_default_font()
		draw_string(f, Vector2(0, size.y * 0.5), "Nothing to show here", HORIZONTAL_ALIGNMENT_CENTER,
			size.x, UITheme.FONT_MD, UITheme.C_TEXT_M)
		return
	PerfSpan.begin("pack_draw")
	var view := Rect2(Vector2.ZERO, size)
	var labels: Array = []
	_draw_node(0, view, labels)
	_draw_labels(labels)
	PerfSpan.end("pack_draw")


func _draw_node(i: int, view: Rect2, labels: Array) -> void:
	var c := screen_circle(i)
	var r := c.z
	if r < 0.6:
		return
	var ctr := Vector2(c.x, c.y)
	# Off screen: skip the whole subtree.
	if ctr.x + r < view.position.x or ctr.x - r > view.end.x or ctr.y + r < view.position.y or ctr.y - r > view.end.y:
		return
	var n: Dictionary = nodes[i]
	var col: Color = n["color"]
	var depth := int(n["depth"])
	var leaf := bool(n["leaf"])
	var is_hover := i == hover
	var is_sel := i == sel
	if leaf:
		if is_hover:
			_disc(ctr, r * 1.12 + 3.0, Color(col, 0.22 + 0.08 * sin(_clock * 4.0)))
		_disc(ctr, r, col.lightened(0.06 if not is_hover else 0.2))
		if r > 6.0:
			# A soft sheen toward the top left.
			_disc(ctr + Vector2(-r * 0.22, -r * 0.26), r * 0.55, Color(1, 1, 1, 0.07))
	else:
		if depth == 0:
			_disc(ctr, r, Color(0.12, 0.17, 0.30, 0.55))
			_ring(ctr, r, Color(0.45, 0.55, 0.75, 0.35), 1.5)
		else:
			var a := 0.16 + 0.05 * minf(float(depth - 1), 3.0)
			if is_hover:
				a += 0.08
				_disc(ctr, r * 1.04 + 2.0, Color(col, 0.10 + 0.05 * sin(_clock * 4.0)))
			_disc(ctr, r, Color(col.darkened(0.25), a))
			_ring(ctr, r, Color(col.lightened(0.1), 0.75 if not is_hover else 1.0), 2.0 if is_hover else 1.4)
	if is_sel:
		_ring(ctr, r + 2.5, UITheme.C_TEXT, 2.0)
	# Label candidates.
	if leaf:
		if r >= LABEL_MIN_LEAF_PX:
			labels.append([r, i, ctr, true])
	elif depth > 0 and r >= LABEL_MIN_GROUP_PX:
		labels.append([r, i, ctr, false])
	if not leaf:
		for k in (n["kids"] as PackedInt32Array):
			_draw_node(k, view, labels)


func _disc(ctr: Vector2, r: float, col: Color) -> void:
	if r * 2.0 <= TEX_MAX_PX:
		draw_texture_rect(_disc_tex(), Rect2(ctr - Vector2(r, r), Vector2(r, r) * 2.0), false, col)
	else:
		draw_circle(ctr, r, col, true, -1.0, true)


func _ring(ctr: Vector2, r: float, col: Color, w: float) -> void:
	var pts := clampi(int(r * 0.45), 24, 720)
	draw_arc(ctr, r, 0.0, TAU, pts, col, w, true)


func _draw_labels(cands: Array) -> void:
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	var placed: Array = []
	var n_drawn := 0
	var f := _font if _font != null else get_theme_default_font()
	for cd in cands:
		if n_drawn >= MAX_LABELS:
			break
		var r := float(cd[0])
		var i := int(cd[1])
		var ctr: Vector2 = cd[2]
		var leaf := bool(cd[3])
		var n: Dictionary = nodes[i]
		var nm := str(n["name"])
		var val := _value_text(i)
		if leaf:
			var fs := clampi(int(r * 0.32), UITheme.FONT_XS, UITheme.FONT_LG + 2)
			var w := r * 1.7
			var t := _fit(nm, fs, w)
			if t.is_empty():
				continue
			var show_val := r >= 32.0 and not val.is_empty()
			var h := float(fs) * (2.2 if show_val else 1.2)
			var rect := Rect2(ctr - Vector2(w * 0.5, h * 0.5), Vector2(w, h))
			if _overlaps(rect, placed):
				continue
			placed.append(rect)
			var y := ctr.y + (float(fs) * 0.35 if not show_val else -float(fs) * 0.2)
			_text(f, Vector2(ctr.x - w * 0.5, y), t, fs, w, Color(1, 1, 1, 0.96), true)
			if show_val:
				var vs := maxi(fs - 2, UITheme.FONT_XS)
				_text(f, Vector2(ctr.x - w * 0.5, y + float(fs) * 1.05), _fit(val, vs, w), vs, w,
					Color(1, 1, 1, 0.72), true)
		else:
			# A group: a dark pill at the top inside its rim.
			var fs2 := clampi(int(r * 0.075) + 9, UITheme.FONT_XS, UITheme.FONT_LG)
			var maxw := minf(r * 1.5, 320.0)
			var txt := nm if val.is_empty() or r < 70.0 else "%s · %s" % [nm, val]
			var t2 := _fit(txt, fs2, maxw - 16.0)
			if t2.is_empty():
				continue
			var tw := f.get_string_size(t2, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
			var ph := float(fs2) + 8.0
			var py := ctr.y - r + ph * 0.5 + maxf(r * 0.06, 4.0)
			if r < 70.0:
				py = ctr.y
			var prect := Rect2(Vector2(ctr.x - tw * 0.5 - 8.0, py - ph * 0.5), Vector2(tw + 16.0, ph))
			if _overlaps(prect, placed):
				continue
			placed.append(prect)
			var hov := i == hover or i == focus
			GraphFastDraw.rrect(self, prect, ph * 0.5, Color(0.04, 0.06, 0.11, 0.82 if hov else 0.7))
			GraphFastDraw.rrect_border(self, prect, ph * 0.5, Color((n["color"] as Color).lightened(0.2), 0.75), 1)
			_text(f, Vector2(prect.position.x, py + float(fs2) * 0.36), t2, fs2, prect.size.x, UITheme.C_TEXT, true)
		n_drawn += 1


func _text(f: Font, pos: Vector2, t: String, fs: int, w: float, col: Color, shadow: bool) -> void:
	if shadow:
		draw_string(f, pos + Vector2(0, 1), t, HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color(0, 0, 0, 0.55))
	draw_string(f, pos, t, HORIZONTAL_ALIGNMENT_CENTER, w, fs, col)


static func _overlaps(r: Rect2, placed: Array) -> bool:
	for p in placed:
		if (p as Rect2).intersects(r):
			return true
	return false


## The text cut to fit `w` px (… at the end), "" when not even 3 letters fit.
func _fit(t: String, fs: int, w: float) -> String:
	var key := "%s|%d|%d" % [t, fs, int(w / 6.0)]
	if _fit_cache.has(key):
		return _fit_cache[key]
	var f := _font if _font != null else get_theme_default_font()
	var out := t
	if f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > w:
		out = ""
		var n := t.length() - 1
		while n >= 3:
			var cand := t.substr(0, n).strip_edges() + "…"
			if f.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= w:
				out = cand
				break
			n -= maxi(1, n / 8)
	if _fit_cache.size() > 4000:
		_fit_cache.clear()
	_fit_cache[key] = out
	return out


func _value_text(i: int) -> String:
	var n: Dictionary = nodes[i]
	if fmt.is_valid():
		return str(fmt.call(float(n["value"]), str(n["unit"])))
	return UiText.num(float(n["value"]), str(n["unit"]))


## The value as the view writes it (the side panel uses the same words).
func value_text(i: int) -> String:
	return _value_text(i) if i >= 0 and i < nodes.size() else ""
