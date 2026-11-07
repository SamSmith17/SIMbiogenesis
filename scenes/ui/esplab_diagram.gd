extends Control

## The ESP board designer's wiring diagram: the board drawn from its data
## (two header rows, each pin coloured by what it can safely do), a card per
## part with its pins on the edge facing the board, and a wire per connection
## coloured by its net (3V3, 5V, GND, SDA, SCL, SPI, UART, 1-Wire, signals).
##
## Everything is drawn in screen space from diagram units (`_zoom`, `_pan`),
## so text stays crisp at any zoom.
##
## Input:
##   wheel           zoom about the pointer;
##   drag empty / right / middle   pan;
##   click a card    select it; drag it to move it;
##   drag a part pin onto a board pin (or the other way round)   wire it by hand;
##   double-click a wire   give it back to the tool;
##   click a board pin   select it (its functions show on the right).
##
## Signals carry everything the modal needs; the diagram never edits a spec.

signal part_clicked(iid: String)
signal part_moved(iid: String, pos: Vector2)
signal board_pin_clicked(gpio: int, label: String)
signal wire_drawn(iid: String, pin_label: String, gpio: int)
signal wire_removed(iid: String, pin_label: String)
signal empty_clicked()
signal hover_changed(text: String)

const PITCH := 24.0
const BOARD_W := 176.0
const PAD_TOP := 58.0
const PAD_BOTTOM := 26.0
const PIN_SZ := 12.0
const CARD_W := 196.0
const CARD_HEAD := 44.0
const CARD_PITCH := 20.0
const READ_H := 15.0
const GAP_X := 250.0
const GAP_Y := 22.0
const DRAG_PX := 5.0
const WIRE_PICK_PX := 6.0
const ZOOM_MIN := 0.35
const ZOOM_MAX := 3.0

const STATE_COLORS := {
	"free": Color(0.20, 0.78, 0.45), "caveat": Color(0.96, 0.66, 0.15), "input_only": Color(0.35, 0.60, 1.0),
	"reserved": Color(0.62, 0.30, 0.32), "3v3": Color(0.96, 0.42, 0.25), "5v": Color(0.90, 0.18, 0.22),
	"gnd": Color(0.48, 0.52, 0.60), "ctrl": Color(0.69, 0.60, 1.0), "nc": Color(0.25, 0.28, 0.34),
}
const STATE_WORDS := {
	"free": "free", "caveat": "has a caveat", "input_only": "input only", "reserved": "taken / never use",
	"3v3": "3.3 V", "5v": "5 V", "gnd": "ground", "ctrl": "control",
}
const NET_COLORS := {
	"3V3": Color(0.96, 0.42, 0.25), "5V": Color(0.90, 0.18, 0.22), "GND": Color(0.55, 0.60, 0.68),
	"SDA": Color(0.27, 0.56, 1.0), "SCL": Color(1.0, 0.82, 0.25), "SCK": Color(0.74, 0.45, 1.0),
	"MISO": Color(0.25, 0.85, 0.80), "MOSI": Color(1.0, 0.45, 0.75), "TX": Color(0.30, 0.90, 0.45),
	"RX": Color(0.70, 0.95, 0.30), "1-Wire": Color(0.30, 0.85, 1.0),
}
const SIGNAL_COLORS := [Color(0.98, 0.58, 0.20), Color(0.45, 0.80, 1.0), Color(0.95, 0.40, 0.55),
	Color(0.55, 0.95, 0.65), Color(0.85, 0.70, 1.0), Color(1.0, 0.90, 0.45), Color(0.40, 0.95, 0.95)]

var _d: Dictionary = {}
var _spec: Dictionary = {}
var _board: Dictionary = {}
var _chip: Dictionary = {}
var _pins: Array = []                # EspBoards.pins
var _board_rect := Rect2()
var _pin_pos := {}                   # "side:index" -> Vector2 (diagram)
var _pos := {}                       # iid -> Vector2 card top-left (diagram)
var _cards := {}                     # iid -> {rect, side, pins: {label: Vector2}}
var _wires: Array = []               # {iid, label, a, b, color, locked, net}
var _readings := {}                  # iid -> PackedStringArray
var _selected := ""
var _sel_gpio := -1
var _zoom := 1.0
var _pan := Vector2(40, 40)
var _press: Dictionary = {}          # {kind, pos, iid, label, gpio, moved, start}
var _hover_text := ""
var _ghost_to := Vector2.INF
var _font: Font


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	_font = UITheme.font("regular")
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


# ------------------------------------------------------------------ API

func set_design(d: Dictionary, spec: Dictionary) -> void:
	_d = d
	_spec = spec
	_board = d.get("board", {})
	_chip = EspChips.get_chip(str(_board.get("chip", "")))
	_pins = EspBoards.pins(_board)
	_layout()
	queue_redraw()


func set_selected(iid: String) -> void:
	_selected = iid
	_sel_gpio = -1
	queue_redraw()


func set_selected_pin(gpio: int) -> void:
	_sel_gpio = gpio
	_selected = ""
	queue_redraw()


func set_readings(r: Dictionary) -> void:
	_readings = r
	_layout()
	queue_redraw()


func card_positions() -> Dictionary:
	return _pos.duplicate()


## Frame the whole diagram in the control.
func fit() -> void:
	var bb := _board_rect
	for iid in _cards:
		bb = bb.merge(_cards[iid]["rect"])
	bb = bb.grow(30.0)
	var avail := size
	if avail.x < 10.0 or avail.y < 10.0 or bb.size.x <= 0.0:
		return
	_zoom = clampf(minf(avail.x / bb.size.x, avail.y / bb.size.y), ZOOM_MIN, 1.6)
	_pan = (avail - bb.size * _zoom) * 0.5 - bb.position * _zoom
	queue_redraw()


## Control-local positions, for the harness's real clicks.
func board_pin_local(gpio: int) -> Vector2:
	for p in _pins:
		if int(p["gpio"]) == gpio:
			return _scr(_pin_pos["%s:%d" % [p["side"], p["index"]]])
	return Vector2.INF


func part_pin_local(iid: String, label: String) -> Vector2:
	if _cards.has(iid) and (_cards[iid]["pins"] as Dictionary).has(label):
		return _scr(_cards[iid]["pins"][label])
	return Vector2.INF


func card_local(iid: String) -> Vector2:
	if not _cards.has(iid):
		return Vector2.INF
	var r: Rect2 = _cards[iid]["rect"]
	return _scr(r.position + Vector2(r.size.x * 0.5, 16.0))


func wire_mid_local(iid: String, label: String) -> Vector2:
	for w in _wires:
		if str(w["iid"]) == iid and str(w["label"]) == label:
			return _scr(_bez(w, 0.5))
	return Vector2.INF


func wire_count() -> int:
	return _wires.size()


# ------------------------------------------------------------------ layout

func _scr(p: Vector2) -> Vector2:
	return p * _zoom + _pan


func _dia(s: Vector2) -> Vector2:
	return (s - _pan) / _zoom


func _layout() -> void:
	_pin_pos.clear()
	var nl := (_board.get("left", []) as Array).size()
	var nr := (_board.get("right", []) as Array).size()
	var h := PAD_TOP + float(maxi(nl, nr)) * PITCH + PAD_BOTTOM
	_board_rect = Rect2(0, 0, BOARD_W, h)
	for p in _pins:
		var x := 0.0 if str(p["side"]) == "left" else BOARD_W
		_pin_pos["%s:%d" % [p["side"], p["index"]]] = Vector2(x, PAD_TOP + float(p["index"]) * PITCH + PITCH * 0.5)
	# Card positions: the spec's layout, else stacked on the side most of the
	# part's GPIOs are on.
	var lay: Dictionary = _spec.get("layout", {})
	var stack := {"left": PAD_TOP - 30.0, "right": PAD_TOP - 30.0}
	var keep := {}
	_cards.clear()
	var assign: Dictionary = (_d.get("wire", {}) as Dictionary).get("assign", {})
	for inst in _spec.get("parts", []):
		var iid := str(inst["iid"])
		var part := EspParts.get_part(str(inst["part"]))
		var h_card := _card_height(iid, part)
		var pos := Vector2.INF
		# A card the player moved stays put; the rest restack every layout,
		# so a card that grows (readings) pushes the ones below it down.
		if lay.has(iid):
			pos = Vector2(float(lay[iid][0]), float(lay[iid][1]))
		if pos == Vector2.INF:
			var side := _majority_side(assign.get(iid, {}))
			var x := BOARD_W + GAP_X if side == "right" else -GAP_X - CARD_W
			pos = Vector2(x, float(stack[side]))
			stack[side] = float(stack[side]) + h_card + GAP_Y
		else:
			var side2 := "left" if pos.x + CARD_W * 0.5 < BOARD_W * 0.5 else "right"
			stack[side2] = maxf(float(stack[side2]), pos.y + h_card + GAP_Y)
		keep[iid] = pos
		var rect := Rect2(pos, Vector2(CARD_W, h_card))
		var side_now := "left" if rect.get_center().x < BOARD_W * 0.5 else "right"
		var pins := {}
		var i := 0
		for pin in part.get("pins", []):
			var px := rect.end.x if side_now == "left" else rect.position.x
			pins[str(pin[0])] = Vector2(px, rect.position.y + CARD_HEAD + float(i) * CARD_PITCH + CARD_PITCH * 0.5)
			i += 1
		_cards[iid] = {"rect": rect, "side": side_now, "pins": pins, "label": str(inst["label"]), "part": part}
	_pos = keep
	_build_wires(assign)


func _card_height(iid: String, part: Dictionary) -> float:
	var n := (part.get("pins", []) as Array).size()
	var r := (_readings.get(iid, PackedStringArray()) as PackedStringArray).size()
	return CARD_HEAD + float(n) * CARD_PITCH + float(r) * READ_H + 10.0


func _majority_side(a: Dictionary) -> String:
	var n := {"left": 0, "right": 0}
	for label in a:
		var g: Variant = a[label]
		if g is int:
			for p in _pins:
				if int(p["gpio"]) == int(g):
					n[str(p["side"])] = int(n[str(p["side"])]) + 1
					break
	return "left" if int(n["left"]) > int(n["right"]) else "right"


func _build_wires(assign: Dictionary) -> void:
	_wires.clear()
	var locks: Dictionary = _spec.get("locks", {})
	var nets: Array = (_d.get("wire", {}) as Dictionary).get("nets", [])
	var net_of_gpio := {}
	for n in nets:
		if int(n["gpio"]) >= 0:
			net_of_gpio[int(n["gpio"])] = n
	for iid in _cards:
		var card: Dictionary = _cards[iid]
		var a: Dictionary = assign.get(iid, {})
		for label in card["pins"]:
			var v: Variant = a.get(label, "")
			var b: Vector2 = card["pins"][label]
			var pa := Vector2.INF
			var name := ""
			if v is int:
				pa = _gpio_pin_pos(int(v), str(card["side"]), b.y)
				var net: Dictionary = net_of_gpio.get(int(v), {})
				name = str(net.get("name", "GPIO%d" % int(v)))
			elif v is String and str(v) in ["3V3", "5V", "GND"]:
				pa = _rail_pin_pos({"3V3": "3v3", "5V": "5v", "GND": "gnd"}[str(v)], str(card["side"]), b.y)
				name = str(v)
			if pa == Vector2.INF:
				continue
			var col: Color = NET_COLORS.get(name, SIGNAL_COLORS[absi(hash(name)) % SIGNAL_COLORS.size()])
			_wires.append({"iid": iid, "label": label, "a": pa, "b": b, "color": col,
				"locked": locks.has("%s:%s" % [iid, label]), "net": name,
				"a_out": -1.0 if pa.x <= 0.5 else 1.0, "b_out": 1.0 if str(card["side"]) == "left" else -1.0})


func _gpio_pin_pos(g: int, side: String, y: float) -> Vector2:
	var best := Vector2.INF
	var bd := INF
	for p in _pins:
		if int(p["gpio"]) != g:
			continue
		var pp: Vector2 = _pin_pos["%s:%d" % [p["side"], p["index"]]]
		var d := absf(pp.y - y) + (0.0 if str(p["side"]) == side else 400.0)
		if d < bd:
			bd = d
			best = pp
	return best


func _rail_pin_pos(kind: String, side: String, y: float) -> Vector2:
	var best := Vector2.INF
	var bd := INF
	for p in _pins:
		if str(p["kind"]) != kind:
			continue
		var pp: Vector2 = _pin_pos["%s:%d" % [p["side"], p["index"]]]
		var d := absf(pp.y - y) + (0.0 if str(p["side"]) == side else 400.0)
		if d < bd:
			bd = d
			best = pp
	return best


func _bez(w: Dictionary, t: float) -> Vector2:
	var a: Vector2 = w["a"]
	var b: Vector2 = w["b"]
	var k := maxf(50.0, absf(b.x - a.x) * 0.45)
	var c0 := a + Vector2(float(w["a_out"]) * k, 0)
	var c1 := b + Vector2(float(w["b_out"]) * k, 0)
	var u := 1.0 - t
	return a * u * u * u + c0 * 3.0 * u * u * t + c1 * 3.0 * u * t * t + b * t * t * t


# ------------------------------------------------------------------ draw

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
	_draw_grid()
	if _board.is_empty():
		return
	for w in _wires:
		_draw_wire(w)
	_draw_board()
	for iid in _cards:
		_draw_card(iid)
	if not _press.is_empty() and str(_press.get("kind", "")) in ["part_pin", "board_pin"] and _ghost_to != Vector2.INF:
		var from: Vector2 = _press["anchor"]
		draw_line(_scr(from), _ghost_to, UITheme.C_AMBER, 2.0, true)
	_draw_legend()


func _draw_grid() -> void:
	var step := 40.0 * _zoom
	if step < 12.0:
		return
	var col := Color(1, 1, 1, 0.035)
	var x := fposmod(_pan.x, step)
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
		x += step
	var y := fposmod(_pan.y, step)
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
		y += step


func _text(p: Vector2, s: String, px: float, col: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	var fs := int(roundf(px * _zoom))
	if fs < 6:
		return
	var w := width * _zoom if width > 0.0 else -1.0
	var sp := _scr(p)
	if align == HORIZONTAL_ALIGNMENT_RIGHT and w < 0.0:
		var tw := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		sp.x -= tw
		align = HORIZONTAL_ALIGNMENT_LEFT
	elif align == HORIZONTAL_ALIGNMENT_CENTER and w < 0.0:
		var tw2 := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		sp.x -= tw2 * 0.5
		align = HORIZONTAL_ALIGNMENT_LEFT
	draw_string(_font, sp, s, align, w, fs, col)


func _draw_board() -> void:
	var r := Rect2(_scr(_board_rect.position), _board_rect.size * _zoom)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.27, 0.18)
	sb.border_color = Color(0.25, 0.55, 0.38)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(int(8.0 * _zoom))
	draw_style_box(sb, r)
	# The module can (antenna end up) and the board's name.
	var can := Rect2(_board_rect.position + Vector2(BOARD_W * 0.28, 8), Vector2(BOARD_W * 0.44, 30))
	draw_rect(Rect2(_scr(can.position), can.size * _zoom), Color(0.72, 0.74, 0.78))
	_text(can.position + Vector2(can.size.x * 0.5, 19), str(_chip.get("label", "")), 9.0, Color(0.15, 0.17, 0.2), HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(BOARD_W * 0.5, _board_rect.end.y - 8), str(_board.get("label", "")), 9.0, Color(0.75, 0.9, 0.8), HORIZONTAL_ALIGNMENT_CENTER)
	var used: Dictionary = (_d.get("wire", {}) as Dictionary).get("used", {})
	for p in _pins:
		var pp: Vector2 = _pin_pos["%s:%d" % [p["side"], p["index"]]]
		var st := EspBoards.pin_state(_board, p)
		var col: Color = STATE_COLORS.get(st, Color.GRAY)
		var sq := Rect2(_scr(pp - Vector2(PIN_SZ, PIN_SZ) * 0.5), Vector2(PIN_SZ, PIN_SZ) * _zoom)
		draw_rect(sq, col)
		var g := int(p["gpio"])
		if g >= 0 and used.has(g):
			draw_rect(sq.grow(2.0 * _zoom), Color(1, 1, 1, 0.9), false, maxf(1.0, 1.5 * _zoom))
		if g >= 0 and g == _sel_gpio:
			draw_rect(sq.grow(4.0 * _zoom), UITheme.C_AMBER, false, maxf(1.5, 2.0 * _zoom))
		var label := str(p["label"])
		if g >= 0 and label != str(g) and not label.ends_with(str(g)):
			label += " · %d" % g
		if str(p["side"]) == "left":
			_text(pp + Vector2(PIN_SZ * 0.5 + 5, 4), label, 10.0, UITheme.C_TEXT)
		else:
			_text(pp + Vector2(-PIN_SZ * 0.5 - 5, 4), label, 10.0, UITheme.C_TEXT, HORIZONTAL_ALIGNMENT_RIGHT)


func _draw_card(iid: String) -> void:
	var c: Dictionary = _cards[iid]
	var rect: Rect2 = c["rect"]
	var part: Dictionary = c["part"]
	var sel := iid == _selected
	var dim := _selected != "" and not sel
	var r := Rect2(_scr(rect.position), rect.size * _zoom)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.20, 0.36) if not dim else Color(0.10, 0.14, 0.24)
	sb.border_color = UITheme.C_AMBER if sel else Color(0.30, 0.42, 0.62)
	sb.set_border_width_all(2 if sel else 1)
	sb.set_corner_radius_all(int(6.0 * _zoom))
	draw_style_box(sb, r)
	_text(rect.position + Vector2(10, 17), str(c["label"]), 12.0, UITheme.C_TEXT, HORIZONTAL_ALIGNMENT_LEFT)
	var sub := EspParts.badge(part)
	var addr: Dictionary = (_d.get("wire", {}) as Dictionary).get("addr", {})
	if addr.has(iid):
		sub += " 0x%02X" % int(addr[iid])
	if str(c["label"]) != str(part.get("label", "")):
		sub += " · " + str(part["label"])
	_text(rect.position + Vector2(10, 33), sub, 9.0, UITheme.C_TEXT_S, HORIZONTAL_ALIGNMENT_LEFT, CARD_W - 20.0)
	var left := str(c["side"]) == "left"
	for label in c["pins"]:
		var pp: Vector2 = c["pins"][label]
		var role := ""
		for pin in part["pins"]:
			if str(pin[0]) == label:
				role = str(pin[1])
		var col := UITheme.C_TEXT_M
		for w in _wires:
			if str(w["iid"]) == iid and str(w["label"]) == label:
				col = w["color"]
		var dot := Rect2(_scr(pp - Vector2(5, 5)), Vector2(10, 10) * _zoom)
		draw_rect(dot, col if role != "nc" else Color(0.3, 0.3, 0.35))
		if left:
			_text(pp + Vector2(-10, 4), label, 10.0, UITheme.C_TEXT if role != "nc" else UITheme.C_TEXT_M, HORIZONTAL_ALIGNMENT_RIGHT)
		else:
			_text(pp + Vector2(10, 4), label, 10.0, UITheme.C_TEXT if role != "nc" else UITheme.C_TEXT_M)
	var rd: PackedStringArray = _readings.get(iid, PackedStringArray())
	var y := rect.position.y + CARD_HEAD + float((part["pins"] as Array).size()) * CARD_PITCH + 6.0
	for s in rd:
		_text(Vector2(rect.position.x + 10, y + 10), s, 10.0, UITheme.C_PRIMARY, HORIZONTAL_ALIGNMENT_LEFT, CARD_W - 20.0)
		y += READ_H


func _draw_wire(w: Dictionary) -> void:
	var dim := _selected != "" and str(w["iid"]) != _selected
	if _sel_gpio >= 0:
		dim = not w["a"].is_equal_approx(_gpio_pin_pos(_sel_gpio, "left", float(w["b"].y))) and \
			not w["a"].is_equal_approx(_gpio_pin_pos(_sel_gpio, "right", float(w["b"].y)))
	var col: Color = w["color"]
	if dim:
		col.a = 0.18
	var pts := PackedVector2Array()
	for i in 25:
		pts.append(_scr(_bez(w, float(i) / 24.0)))
	var wdt := maxf(1.5, (3.0 if bool(w["locked"]) else 2.0) * _zoom)
	draw_polyline(pts, Color(0, 0, 0, col.a * 0.5), wdt + 2.0, true)
	draw_polyline(pts, col, wdt, true)
	if bool(w["locked"]):
		draw_rect(Rect2(pts[12] - Vector2(4, 4), Vector2(8, 8)), UITheme.C_AMBER)


func _draw_legend() -> void:
	var x := 10.0
	var y := size.y - 12.0
	for st in ["free", "caveat", "input_only", "reserved", "3v3", "5v", "gnd"]:
		draw_rect(Rect2(x, y - 9, 9, 9), STATE_COLORS[st])
		var t: String = STATE_WORDS[st]
		draw_string(_font, Vector2(x + 13, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_S)
		x += 13.0 + _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS).x + 14.0


# ------------------------------------------------------------------ hit tests

func _hit_part_pin(s: Vector2) -> Dictionary:
	for iid in _cards:
		for label in _cards[iid]["pins"]:
			if _scr(_cards[iid]["pins"][label]).distance_to(s) <= maxf(7.0, 8.0 * _zoom):
				return {"iid": iid, "label": label, "pos": _cards[iid]["pins"][label]}
	return {}


func _hit_board_pin(s: Vector2) -> Dictionary:
	for p in _pins:
		var pp: Vector2 = _pin_pos["%s:%d" % [p["side"], p["index"]]]
		if _scr(pp).distance_to(s) <= maxf(7.0, 9.0 * _zoom):
			return {"pin": p, "pos": pp}
	return {}


func _hit_card(s: Vector2) -> String:
	var keys := _cards.keys()
	keys.reverse()
	for iid in keys:
		var r: Rect2 = _cards[iid]["rect"]
		if Rect2(_scr(r.position), r.size * _zoom).has_point(s):
			return str(iid)
	return ""


func _hit_wire(s: Vector2) -> Dictionary:
	var best := {}
	var bd := WIRE_PICK_PX
	for w in _wires:
		var prev := _scr(_bez(w, 0.0))
		for i in range(1, 25):
			var cur := _scr(_bez(w, float(i) / 24.0))
			var d := Geometry2D.get_closest_point_to_segment(s, prev, cur).distance_to(s)
			if d < bd:
				bd = d
				best = w
			prev = cur
	return best


# ------------------------------------------------------------------ input

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_zoom_at(mb.position, 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_press = {"kind": "pan", "pos": mb.position} if mb.pressed else {}
			accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		accept_event()
		if mb.pressed:
			grab_focus()
			_on_press(mb.position, mb.double_click)
		else:
			_on_release(mb.position)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if not _press.is_empty():
			_on_drag(mm.position, mm.relative)
		else:
			_update_hover(mm.position)


func _zoom_at(s: Vector2, f: float) -> void:
	var before := _dia(s)
	_zoom = clampf(_zoom * f, ZOOM_MIN, ZOOM_MAX)
	_pan = s - before * _zoom
	queue_redraw()


func _on_press(s: Vector2, double: bool) -> void:
	if double:
		var w := _hit_wire(s)
		if not w.is_empty() and _hit_part_pin(s).is_empty():
			wire_removed.emit(str(w["iid"]), str(w["label"]))
			_press = {}
			return
	var pp := _hit_part_pin(s)
	if not pp.is_empty():
		_press = {"kind": "part_pin", "pos": s, "iid": pp["iid"], "label": pp["label"], "anchor": pp["pos"], "moved": false}
		return
	var bp := _hit_board_pin(s)
	if not bp.is_empty():
		_press = {"kind": "board_pin", "pos": s, "pin": bp["pin"], "anchor": bp["pos"], "moved": false}
		return
	var iid := _hit_card(s)
	if iid != "":
		_press = {"kind": "card", "pos": s, "iid": iid, "start": _pos[iid], "moved": false}
		return
	var w2 := _hit_wire(s)
	if not w2.is_empty():
		_press = {"kind": "wire", "pos": s, "iid": w2["iid"], "moved": false}
		return
	_press = {"kind": "empty", "pos": s, "moved": false}


func _on_drag(s: Vector2, rel: Vector2) -> void:
	var kind := str(_press.get("kind", ""))
	if not bool(_press.get("moved", true)) and s.distance_to(_press["pos"]) > DRAG_PX:
		_press["moved"] = true
	match kind:
		"pan", "empty":
			_pan += rel
			queue_redraw()
		"card":
			if bool(_press["moved"]):
				var p: Vector2 = _press["start"] + (s - _press["pos"]) / _zoom
				_pos[_press["iid"]] = p.snapped(Vector2(2, 2))
				var lay: Dictionary = _spec.get("layout", {})
				lay[_press["iid"]] = [_pos[_press["iid"]].x, _pos[_press["iid"]].y]
				_spec["layout"] = lay
				_layout()
				queue_redraw()
		"part_pin", "board_pin":
			if bool(_press["moved"]):
				_ghost_to = s
				_update_hover(s)
				queue_redraw()


func _on_release(s: Vector2) -> void:
	var p := _press
	_press = {}
	_ghost_to = Vector2.INF
	queue_redraw()
	if p.is_empty():
		return
	var moved := bool(p.get("moved", false))
	match str(p["kind"]):
		"card":
			if moved:
				part_moved.emit(str(p["iid"]), _pos[p["iid"]])
			else:
				part_clicked.emit(str(p["iid"]))
		"wire":
			if not moved:
				part_clicked.emit(str(p["iid"]))
		"empty":
			if not moved:
				empty_clicked.emit()
		"part_pin":
			if moved:
				var bp := _hit_board_pin(s)
				if not bp.is_empty() and int(bp["pin"]["gpio"]) >= 0:
					wire_drawn.emit(str(p["iid"]), str(p["label"]), int(bp["pin"]["gpio"]))
			else:
				part_clicked.emit(str(p["iid"]))
		"board_pin":
			var pin: Dictionary = p["pin"]
			if moved:
				var tp := _hit_part_pin(s)
				if not tp.is_empty() and int(pin["gpio"]) >= 0:
					wire_drawn.emit(str(tp["iid"]), str(tp["label"]), int(pin["gpio"]))
			else:
				board_pin_clicked.emit(int(pin["gpio"]), str(pin["label"]))


func _update_hover(s: Vector2) -> void:
	var t := ""
	var bp := _hit_board_pin(s)
	if not bp.is_empty():
		var p: Dictionary = bp["pin"]
		var g := int(p["gpio"])
		if g >= 0:
			var f := EspChips.functions_of(str(_board["chip"]), g)
			var use := EspBoards.board_use(_board, g)
			t = "%s (GPIO%d): %s%s" % [p["label"], g, ", ".join(f), ("; board: " + use) if use != "" else ""]
		else:
			t = "%s: %s" % [p["label"], STATE_WORDS.get(str(p["kind"]), str(p["kind"]))]
	else:
		var pp := _hit_part_pin(s)
		if not pp.is_empty():
			var c: Dictionary = _cards[pp["iid"]]
			var role := ""
			for pin in c["part"]["pins"]:
				if str(pin[0]) == str(pp["label"]):
					role = str(pin[1])
			t = "%s %s (%s): drag it onto a board pin to wire it by hand" % [c["label"], pp["label"], role]
		else:
			var w := _hit_wire(s)
			if not w.is_empty():
				t = "%s %s → %s%s · double-click to give it back to the tool" % [
					_cards[w["iid"]]["label"], w["label"], w["net"], " (wired by hand)" if bool(w["locked"]) else ""]
	if t != _hover_text:
		_hover_text = t
		hover_changed.emit(t)
