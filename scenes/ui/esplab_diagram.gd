extends Control

## The ESP board designer's wiring diagram: the board drawn the way it looks
## (EspBoardArt: its PCB, module and antenna, USB socket, buttons, chips) at
## its real size, plated header holes with their silkscreen names, and
## outside each edge a pinout column like a maker's pinout chart — the GPIO
## (coloured by what it can safely do) and what it does: the net it is wired
## to, else its notable function (the board's default I2C / SPI pins, the
## console, ADC, DAC). A breakout card per part with its header and a glyph of
## the module, and a jumper wire per connection coloured by its net (3V3, 5V,
## GND, SDA, SCL, SPI, UART, 1-Wire, signals), Dupont ends and all.
##
## Everything is drawn in screen space from diagram units (`_zoom`, `_pan`),
## so text stays crisp at any zoom. One header pitch (2.54 mm) is PITCH
## diagram units; the board is drawn at that scale from its size in mm.
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

const Art := preload("res://scenes/ui/esplab_board_art.gd")

const PITCH := 24.0
const S := PITCH / 2.54                 # diagram units per mm
const HOLE_INSET_MM := 1.6
const COL_GAP := 12.0                   # board edge -> first pinout chip
const CHIP1_W := 56.0
const CHIP2_W := 64.0
const CHIP_H := 16.0
const LABEL_COL := COL_GAP + CHIP1_W + 4.0 + CHIP2_W + 12.0
const GAP_X := 170.0                    # pinout column -> part cards
const CARD_W := 210.0
const CARD_HEAD := 46.0
const CARD_PITCH := 20.0
const CARD_HOLE_IN := 11.0
const CARD_LABEL_W := 70.0
const GLYPH_MIN_H := 62.0
const READ_H := 15.0
const GAP_Y := 22.0
const DRAG_PX := 5.0
const WIRE_PICK_PX := 6.0
const ZOOM_MIN := 0.3
const ZOOM_MAX := 3.0

## A GPIO chip's colour by pin state (the pinout chart's convention: plain
## GPIOs purple, strapping / caveat pins yellow, input-only darker).
const STATE_COLORS := {
	"free": Color(0.47, 0.11, 0.55), "caveat": Color(0.86, 0.83, 0.10), "input_only": Color(0.28, 0.05, 0.33),
	"reserved": Color(0.28, 0.29, 0.31), "3v3": Color(0.94, 0.33, 0.34), "5v": Color(0.86, 0.16, 0.26),
	"gnd": Color(0.27, 0.28, 0.30), "ctrl": Color(0.13, 0.62, 0.43), "nc": Color(0.18, 0.19, 0.21),
}
const STATE_WORDS := {
	"free": "free", "caveat": "has a caveat", "input_only": "input only", "reserved": "taken / never use",
	"3v3": "3.3 V", "5v": "5 V", "gnd": "ground", "ctrl": "control",
}
## The function chip's colour (what the pin is for, when nothing is wired).
const FN_COLORS := {
	"i2c": Color(0.78, 0.13, 0.76), "spi": Color(0.0, 0.43, 0.74), "uart": Color(0.45, 0.47, 0.51),
	"usb": Color(0.40, 0.42, 0.46), "adc": Color(0.93, 0.46, 0.04), "adc2": Color(0.78, 0.37, 0.04),
	"dac": Color(0.70, 0.40, 0.04), "board": Color(0.10, 0.52, 0.58),
}
const NET_COLORS := {
	"3V3": Color(0.96, 0.36, 0.30), "5V": Color(0.90, 0.16, 0.22), "GND": Color(0.22, 0.23, 0.26),
	"SDA": Color(0.24, 0.55, 1.0), "SCL": Color(1.0, 0.80, 0.18), "SCK": Color(0.72, 0.42, 1.0),
	"MISO": Color(0.20, 0.84, 0.78), "MOSI": Color(1.0, 0.42, 0.72), "TX": Color(0.28, 0.86, 0.42),
	"RX": Color(0.66, 0.92, 0.26), "1-Wire": Color(0.28, 0.82, 1.0),
}
const SIGNAL_COLORS := [Color(0.98, 0.56, 0.18), Color(0.42, 0.78, 1.0), Color(0.95, 0.38, 0.52),
	Color(0.52, 0.94, 0.62), Color(0.82, 0.66, 1.0), Color(1.0, 0.88, 0.40), Color(0.36, 0.93, 0.93)]

var _d: Dictionary = {}
var _spec: Dictionary = {}
var _board: Dictionary = {}
var _chip: Dictionary = {}
var _look: Dictionary = {}
var _pins: Array = []                # EspBoards.pins
var _bw := 260.0
var _bh := 480.0
var _board_rect := Rect2()
var _pin_pos := {}                   # "side:index" -> Vector2 (diagram): the pinout column's outer end
var _hole_pos := {}                  # "side:index" -> Vector2 (diagram): the plated hole
var _pos := {}                       # iid -> Vector2 card top-left (diagram)
var _cards := {}                     # iid -> {rect, side, pins: {label: Vector2}}
var _wires: Array = []               # {iid, label, a, b, color, locked, net}
var _wired_gpio := {}                # gpio -> {color, text}
var _wired_key := {}                 # "side:index" of a rail pin -> wires on it
var _readings := {}                  # iid -> PackedStringArray
var _selected := ""
var _sel_gpio := -1
var _zoom := 1.0
var _pan := Vector2(40, 40)
var _press: Dictionary = {}          # {kind, pos, iid, label, gpio, moved, start}
var _hover_text := ""
var _ghost_to := Vector2.INF
var _font: Font
var _fontb: Font
var _fontn: Font


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	_font = UITheme.font("regular")
	_fontb = UITheme.font("semibold")
	_fontn = UITheme.font("regular", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


# ------------------------------------------------------------------ API

func set_design(d: Dictionary, spec: Dictionary) -> void:
	_d = d
	_spec = spec
	_board = d.get("board", {})
	_chip = EspChips.get_chip(str(_board.get("chip", "")))
	_look = EspBoards.look(str(spec.get("board", "")))
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
	var bb := _board_rect.grow_individual(LABEL_COL, 0.0, LABEL_COL, 0.0)
	for iid in _cards:
		bb = bb.merge(_cards[iid]["rect"])
	bb = bb.grow(30.0)
	var avail := size - Vector2(0, 24)
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
			var pts: PackedVector2Array = w["pts"]
			return _scr(pts[pts.size() / 2])
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
	_hole_pos.clear()
	var nl := (_board.get("left", []) as Array).size()
	var nr := (_board.get("right", []) as Array).size()
	var span := float(maxi(nl, nr)) * PITCH
	var sz: Array = _board.get("size_mm", [28.0, 52.0])
	_bw = maxf(float(sz[0]) * S, 150.0)
	# Keep the header clear of the USB end (and the module's antenna end
	# free for the antenna): the board grows rather than overlap them.
	var usb_clear := 0.0
	if str(_look.get("usb", "")) != "" and str(_look.get("module", "")) != "atom":
		usb_clear = (8.0 if str(_look.get("usb", "")).begins_with("c") else 6.5) * S
	var top_clear := usb_clear if bool(_look.get("usb_top", false)) else 8.0
	var bot_clear := 8.0 if bool(_look.get("usb_top", false)) else usb_clear
	_bh = maxf(float(sz[1]) * S, span + top_clear + bot_clear)
	_board_rect = Rect2(0, 0, _bw, _bh)
	var y0 := clampf((_bh - span) * 0.5, top_clear, _bh - span - bot_clear)
	var inset := HOLE_INSET_MM * S
	for p in _pins:
		var left := str(p["side"]) == "left"
		var y := y0 + float(p["index"]) * PITCH + PITCH * 0.5
		var key := "%s:%d" % [p["side"], p["index"]]
		_hole_pos[key] = Vector2(inset if left else _bw - inset, y)
		_pin_pos[key] = Vector2(-LABEL_COL if left else _bw + LABEL_COL, y)
	# Card positions: the spec's layout, else stacked on the side most of the
	# part's GPIOs are on.
	var lay: Dictionary = _spec.get("layout", {})
	var stack := {"left": y0 - 10.0, "right": y0 - 10.0}
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
			var x := _bw + LABEL_COL + GAP_X if side == "right" else -LABEL_COL - GAP_X - CARD_W
			pos = Vector2(x, float(stack[side]))
			stack[side] = float(stack[side]) + h_card + GAP_Y
		else:
			var side2 := "left" if pos.x + CARD_W * 0.5 < _bw * 0.5 else "right"
			stack[side2] = maxf(float(stack[side2]), pos.y + h_card + GAP_Y)
		keep[iid] = pos
		var rect := Rect2(pos, Vector2(CARD_W, h_card))
		var side_now := "left" if rect.get_center().x < _bw * 0.5 else "right"
		var pins := {}
		var i := 0
		for pin in part.get("pins", []):
			var px := rect.end.x - CARD_HOLE_IN if side_now == "left" else rect.position.x + CARD_HOLE_IN
			pins[str(pin[0])] = Vector2(px, rect.position.y + CARD_HEAD + float(i) * CARD_PITCH + CARD_PITCH * 0.5)
			i += 1
		_cards[iid] = {"rect": rect, "side": side_now, "pins": pins, "label": str(inst["label"]), "part": part,
			"pid": str(inst["part"])}
	_pos = keep
	_build_wires(assign)


func _card_body_h(part: Dictionary) -> float:
	return maxf(float((part.get("pins", []) as Array).size()) * CARD_PITCH, GLYPH_MIN_H)


func _card_height(iid: String, part: Dictionary) -> float:
	var r := (_readings.get(iid, PackedStringArray()) as PackedStringArray).size()
	return CARD_HEAD + _card_body_h(part) + (float(r) * READ_H + 14.0 if r > 0 else 0.0) + 10.0


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
	_wired_gpio.clear()
	_wired_key.clear()
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
			if not (v is int):
				var rk := _key_at(pa)
				_wired_key[rk] = int(_wired_key.get(rk, 0)) + 1
			var col: Color = NET_COLORS.get(name, SIGNAL_COLORS[absi(hash(name)) % SIGNAL_COLORS.size()])
			_wires.append({"iid": iid, "label": label, "a": pa, "b": b, "color": col,
				"locked": locks.has("%s:%s" % [iid, label]), "net": name,
				"a_out": -1.0 if pa.x < _bw * 0.5 else 1.0, "b_out": 1.0 if str(card["side"]) == "left" else -1.0})
			if v is int and not _wired_gpio.has(int(v)):
				var t := name
				if name.begins_with("GPIO"):
					t = "%s %s" % [str(card["label"]), label]
				_wired_gpio[int(v)] = {"color": col, "text": t}
	var lane := {"top": 0, "bottom": 0}
	for w in _wires:
		var a: Vector2 = w["a"]
		var b: Vector2 = w["b"]
		var cross := (a.x < _bw * 0.5) != (b.x < _bw * 0.5)
		if not cross:
			w["pts"] = _bez_pts(w)
			continue
		var end := "top" if (a.y + b.y) * 0.5 < _bh * 0.5 else "bottom"
		var i := int(lane[end])
		lane[end] = i + 1
		var off := 24.0 + 7.0 * float(i)
		var ly := -off if end == "top" else _bh + off
		var ax := a.x + float(w["a_out"]) * (18.0 + 5.0 * float(i))
		var bx := (_bw + LABEL_COL + 18.0 + 5.0 * float(i)) if b.x > _bw * 0.5 else (-LABEL_COL - 18.0 - 5.0 * float(i))
		w["pts"] = _round_path(PackedVector2Array([a, Vector2(ax, a.y), Vector2(ax, ly), Vector2(bx, ly), Vector2(bx, b.y), b]))


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


## The ends of a part's key ("side:index") at a pin-column end point.
func _key_at(pa: Vector2) -> String:
	for key in _pin_pos:
		if (_pin_pos[key] as Vector2).is_equal_approx(pa):
			return str(key)
	return ""


func _bez_pts(w: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 33:
		out.append(_bez(w, float(i) / 32.0))
	return out


## A polyline with its corners rounded (Chaikin, three passes), ends kept.
func _round_path(pts: PackedVector2Array) -> PackedVector2Array:
	var cur := pts
	for _pass in 3:
		var nxt := PackedVector2Array()
		nxt.append(cur[0])
		for i in cur.size() - 1:
			var p0 := cur[i]
			var p1 := cur[i + 1]
			nxt.append(p0.lerp(p1, 0.25))
			nxt.append(p0.lerp(p1, 0.75))
		nxt.append(cur[cur.size() - 1])
		cur = nxt
	return cur


func _bez(w: Dictionary, t: float) -> Vector2:
	var a: Vector2 = w["a"]
	var b: Vector2 = w["b"]
	var k := maxf(50.0, absf(b.x - a.x) * 0.45)
	var c0 := a + Vector2(float(w["a_out"]) * k, 0)
	var c1 := b + Vector2(float(w["b_out"]) * k, 0)
	var u := 1.0 - t
	return a * u * u * u + c0 * 3.0 * u * u * t + c1 * 3.0 * u * t * t + b * t * t * t


## The pin's notable function when nothing is wired to it: [text, colour] or [].
func _fn_tag(g: int) -> Array:
	var i2c: Array = _board.get("i2c", [])
	if i2c.size() >= 2:
		if int(i2c[0]) == g:
			return ["SDA", FN_COLORS["i2c"]]
		if int(i2c[1]) == g:
			return ["SCL", FN_COLORS["i2c"]]
	var spi: Dictionary = _board.get("spi", {})
	for k in spi:
		if int(spi[k]) == g:
			return [str(k).to_upper(), FN_COLORS["spi"]]
	var con: Array = _chip.get("console", [])
	if con.size() >= 2 and (int(con[0]) == g or int(con[1]) == g):
		return ["TX0" if int(con[0]) == g else "RX0", FN_COLORS["uart"]]
	if EspChips.is_usb(_chip, g):
		return ["USB", FN_COLORS["usb"]]
	var use := EspBoards.board_use(_board, g)
	if use != "":
		var short := use.get_slice(" ", 0).to_upper()
		for pair in [["PSRAM", "PSRAM"], ["RGB", "RGB"], ["LED", "LED"], ["button", "BTN"], ["display", "LCD"],
				["touch", "TOUCH"], ["SD card", "SD"], ["speaker", "SPK"], ["light sensor", "LDR"], ["IR", "IR"],
				["battery", "VBAT"]]:
			if use.find(str(pair[0])) >= 0:
				short = str(pair[1])
				break
		return [short.substr(0, 7), FN_COLORS["board"]]
	if (_chip.get("dac", []) as Array).has(g):
		return ["DAC", FN_COLORS["dac"]]
	if (_chip.get("adc1", []) as Array).has(g):
		return ["ADC1", FN_COLORS["adc"]]
	if (_chip.get("adc2", []) as Array).has(g):
		return ["ADC2", FN_COLORS["adc2"]]
	return []


func _chip1_text(p: Dictionary) -> String:
	var g := int(p["gpio"])
	if g >= 0:
		if str(_board.get("chip", "")) == "rp2040":
			return "GP%d" % g
		if (_chip.get("analog_only", []) as Array).has(g):
			return "A0"
		return "GPIO %d" % g
	match str(p["kind"]):
		"3v3":
			return "3.3V"
		"gnd":
			return "GND"
	return str(p["label"])


# ------------------------------------------------------------------ draw

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.055, 0.065, 0.085))
	_draw_grid()
	if _board.is_empty():
		return
	_draw_board()
	for iid in _cards:
		_draw_card(iid)
	for w in _wires:
		_draw_wire(w)
	for w2 in _wires:
		_draw_wire_ends(w2)
	if not _press.is_empty() and str(_press.get("kind", "")) in ["part_pin", "board_pin"] and _ghost_to != Vector2.INF:
		var from: Vector2 = _press["anchor"]
		draw_line(_scr(from), _ghost_to, UITheme.C_AMBER, 2.0, true)
		draw_circle(_ghost_to, 4.0, UITheme.C_AMBER)
	_draw_legend()


func _draw_grid() -> void:
	var step := 24.0 * _zoom
	while step < 14.0:
		step *= 2.0
	var col := Color(1, 1, 1, 0.07)
	var x := fposmod(_pan.x, step)
	var n := 0
	while x < size.x and n < 6000:
		var y := fposmod(_pan.y, step)
		while y < size.y and n < 6000:
			draw_rect(Rect2(x - 0.75, y - 0.75, 1.5, 1.5), col)
			y += step
			n += 1
		x += step


func _text(p: Vector2, s: String, px: float, col: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, f: Font = null) -> void:
	var font := f if f != null else _font
	var fs := int(roundf(px * _zoom))
	if fs < 6:
		return
	var w := width * _zoom if width > 0.0 else -1.0
	var sp := _scr(p)
	if align == HORIZONTAL_ALIGNMENT_RIGHT and w < 0.0:
		var tw := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		sp.x -= tw
		align = HORIZONTAL_ALIGNMENT_LEFT
	elif align == HORIZONTAL_ALIGNMENT_CENTER and w < 0.0:
		var tw2 := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		sp.x -= tw2 * 0.5
		align = HORIZONTAL_ALIGNMENT_LEFT
	if width > 0.0 and align == HORIZONTAL_ALIGNMENT_LEFT:
		s = _fit(s, fs, w, font)
		w = -1.0
	draw_string(font, sp, s, align, w, fs, col)


## Shorten a string with an ellipsis to fit `w` screen px.
func _fit(s: String, fs: int, w: float, font: Font) -> String:
	if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= w:
		return s
	var t := s
	while t.length() > 1 and font.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > w:
		t = t.substr(0, t.length() - 1)
	return t + "…"


## A rounded pinout chip with centred text (diagram coords).
func _pin_chip(r: Rect2, txt: String, bg: Color, outline: Color = Color(0, 0, 0, 0)) -> void:
	var sr := Rect2(_scr(r.position), r.size * _zoom)
	Art.box(self, sr, bg, outline if outline.a > 0.0 else bg.darkened(0.35), maxf(1.0, (1.6 if outline.a > 0.0 else 1.0) * _zoom), 3.0 * _zoom)
	var fs := int(roundf(9.5 * _zoom))
	if fs < 6:
		return
	var fg := Color(0.08, 0.08, 0.1) if bg.get_luminance() > 0.55 else Color(0.98, 0.98, 0.98)
	var t := _fit(txt, fs, sr.size.x - 6.0 * _zoom, _fontb)
	Art.text(self, _fontb, sr.get_center(), t, float(fs), fg)


func _draw_board() -> void:
	var r := Rect2(_scr(_board_rect.position), _board_rect.size * _zoom)
	var k := S * _zoom
	var title := str(_d.get("friendly", ""))
	Art.draw_board(self, r, k, _look, str(_chip.get("label", "")), title, _font, _fontb)
	var used: Dictionary = (_d.get("wire", {}) as Dictionary).get("used", {})
	var castell := bool(_look.get("castellated", false))
	for p in _pins:
		var key := "%s:%d" % [p["side"], p["index"]]
		var hp: Vector2 = _hole_pos[key]
		var ap: Vector2 = _pin_pos[key]
		var left := str(p["side"]) == "left"
		var g := int(p["gpio"])
		var st := EspBoards.pin_state(_board, p)
		var wired: Dictionary = _wired_gpio.get(g, {}) if g >= 0 else {}
		var is_used := g >= 0 and used.has(g)
		var sel := g >= 0 and g == _sel_gpio
		# Leader line from the hole out through the chips to the wire end.
		var lead := Color(0.34, 0.55, 0.85, 0.55)
		if not wired.is_empty():
			lead = Color(wired["color"], 0.95)
		elif _wired_key.has(key):
			lead = Color(NET_COLORS.get({"3v3": "3V3", "5v": "5V", "gnd": "GND"}.get(st, ""), lead), 0.95)
		var edge := Vector2(0.0 if left else _bw, hp.y)
		draw_line(_scr(edge), _scr(ap), lead, maxf(1.0, (1.6 if not wired.is_empty() else 1.0) * _zoom), true)
		# The plated hole (a castellated half-hole on the Pico).
		var hs := _scr(hp)
		if castell:
			hs = _scr(Vector2(0.9 * S if left else _bw - 0.9 * S, hp.y))
		var ring := Art.GOLD
		if str(p["kind"]) == "nc":
			ring = Art.GOLD_D
		draw_circle(hs, 0.9 * S * _zoom, ring)
		draw_circle(hs, 0.5 * S * _zoom, Art.HOLE)
		if is_used:
			var pc: Color = wired.get("color", Color(0.9, 0.9, 0.9))
			draw_circle(hs, 0.38 * S * _zoom, pc)
		if sel:
			draw_arc(hs, 1.4 * S * _zoom, 0, TAU, 28, UITheme.C_AMBER, maxf(1.5, 2.0 * _zoom), true)
		# Silkscreen name, turned like the board's own.
		var lab := str(p["label"])
		var fs := minf(8.0 * _zoom, (PITCH * 0.9 * _zoom) / maxf(1.0, _font.get_string_size(lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x) * 10.0)
		var sx := hp.x + (12.0 if left else -12.0)
		if castell:
			sx = (0.9 * S + 10.0) if left else (_bw - 0.9 * S - 10.0)
		Art.text_rot(self, _fontb, _scr(Vector2(sx, hp.y)), lab, fs, Art.SILK, -PI * 0.5)
		# The pinout column.
		var x1 := (-COL_GAP - CHIP1_W) if left else (_bw + COL_GAP)
		var c1 := Rect2(Vector2(x1, hp.y - CHIP_H * 0.5), Vector2(CHIP1_W, CHIP_H))
		var bg1: Color = STATE_COLORS.get(st, Color.GRAY)
		_pin_chip(c1, _chip1_text(p), bg1, UITheme.C_AMBER if sel else Color(0, 0, 0, 0))
		var x2 := (x1 - 4.0 - CHIP2_W) if left else (x1 + CHIP1_W + 4.0)
		var c2 := Rect2(Vector2(x2, hp.y - CHIP_H * 0.5), Vector2(CHIP2_W, CHIP_H))
		if not wired.is_empty():
			_pin_chip(c2, str(wired["text"]), wired["color"], Color(1, 1, 1, 0.85))
		elif g >= 0:
			var tag := _fn_tag(g)
			if not tag.is_empty():
				_pin_chip(c2, str(tag[0]), Color(tag[1], 0.85))
		elif st in ["3v3", "5v", "gnd"] and _wired_key.has(key):
			_pin_chip(c2, "%s × %d" % [_chip1_text(p), int(_wired_key[key])], Color(NET_COLORS.get(
				{"3v3": "3V3", "5v": "5V", "gnd": "GND"}[st], Color.GRAY), 0.9), Color(1, 1, 1, 0.6))


func _draw_card(iid: String) -> void:
	var c: Dictionary = _cards[iid]
	var rect: Rect2 = c["rect"]
	var part: Dictionary = c["part"]
	var sel := iid == _selected
	var dim := (_selected != "" and not sel) or _sel_gpio >= 0
	var look := Art.part_look(str(c["pid"]))
	var pcb: Color = look["pcb"]
	if dim:
		pcb = pcb.darkened(0.35)
	var r := Rect2(_scr(rect.position), rect.size * _zoom)
	Art.box(self, Rect2(r.position + Vector2(3, 5) * _zoom, r.size), Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), 0.0, 7.0 * _zoom)
	Art.box(self, r, pcb, pcb.lightened(0.25), maxf(1.0, 1.2 * _zoom), 7.0 * _zoom)
	Art.box(self, Rect2(r.position + Vector2(2, 2), Vector2(r.size.x - 4, r.size.y * 0.35)), Color(1, 1, 1, 0.035), Color(0, 0, 0, 0), 0.0, 6.0 * _zoom)
	if sel:
		Art.box(self, r.grow(3.0 * _zoom), Color(0, 0, 0, 0), UITheme.C_AMBER, maxf(1.5, 2.0 * _zoom), 9.0 * _zoom)
	var left := str(c["side"]) == "left"
	# Mounting holes on the corners away from the header.
	var hx := rect.position.x + 9.0 if left else rect.end.x - 9.0
	for hy in [rect.position.y + 9.0, rect.end.y - 9.0]:
		draw_circle(_scr(Vector2(hx, float(hy))), 4.2 * _zoom, Art.SILVER_D)
		draw_circle(_scr(Vector2(hx, float(hy))), 2.8 * _zoom, Color(0.04, 0.04, 0.05))
	# Name and what it is.
	var tx := rect.position.x + (20.0 if left else 16.0)
	_text(Vector2(tx, rect.position.y + 19), str(c["label"]), 12.5, Color(0.97, 0.97, 0.95), HORIZONTAL_ALIGNMENT_LEFT, CARD_W - 40.0, _fontb)
	var sub := EspParts.badge(part)
	var addr: Dictionary = (_d.get("wire", {}) as Dictionary).get("addr", {})
	if addr.has(iid):
		sub += " 0x%02X" % int(addr[iid])
	var plab := str(part.get("label", ""))
	var sub2 := plab if str(c["label"]) != plab else str(part.get("desc", ""))
	var pill_w := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x + 12.0
	var pill := Rect2(Vector2(tx, rect.position.y + 26), Vector2(pill_w, 14))
	Art.box(self, Rect2(_scr(pill.position), pill.size * _zoom), Color(0, 0, 0, 0.35), Color(1, 1, 1, 0.15), 1.0, 7.0 * _zoom)
	_text(pill.position + Vector2(6, 10.5), sub, 9.0, Color(0.85, 0.9, 1.0), HORIZONTAL_ALIGNMENT_LEFT, -1.0, _fontb)
	_text(Vector2(pill.end.x + 6, rect.position.y + 36.5), sub2, 8.5, Color(1, 1, 1, 0.55), HORIZONTAL_ALIGNMENT_LEFT,
		rect.end.x - pill.end.x - 26.0)
	# The header: plated holes with their silkscreen names.
	for label in c["pins"]:
		var pp: Vector2 = c["pins"][label]
		var role := ""
		for pin in part["pins"]:
			if str(pin[0]) == label:
				role = str(pin[1])
		var wired_col := Color(0, 0, 0, 0)
		for w in _wires:
			if str(w["iid"]) == iid and str(w["label"]) == label:
				wired_col = w["color"]
		var hs := _scr(pp)
		draw_circle(hs, 5.2 * _zoom, Art.GOLD if role != "nc" else Art.GOLD_D)
		draw_circle(hs, 3.0 * _zoom, Art.HOLE)
		if wired_col.a > 0.0:
			draw_circle(hs, 2.2 * _zoom, wired_col)
		var lc := Art.SILK if role != "nc" else Color(1, 1, 1, 0.35)
		if left:
			_text(pp + Vector2(-10, 3.5), label, 9.5, lc, HORIZONTAL_ALIGNMENT_RIGHT, -1.0, _fontb)
		else:
			_text(pp + Vector2(10, 3.5), label, 9.5, lc, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _fontb)
	# The module's glyph beside the header.
	var gy := rect.position.y + CARD_HEAD - 2.0
	var gh := _card_body_h(part)
	var gx := rect.position.x + 16.0 if left else rect.position.x + CARD_LABEL_W + 8.0
	var gw := CARD_W - CARD_LABEL_W - 26.0
	var g := Rect2(_scr(Vector2(gx, gy)), Vector2(gw, gh) * _zoom)
	Art.draw_glyph(self, g, _zoom, str(look["glyph"]), _font, pcb)
	# The twin's readings on a little display strip.
	var rd: PackedStringArray = _readings.get(iid, PackedStringArray())
	if rd.size() > 0:
		var ry := gy + gh + 6.0
		var rr := Rect2(Vector2(rect.position.x + 8, ry), Vector2(CARD_W - 16, float(rd.size()) * READ_H + 8.0))
		Art.box(self, Rect2(_scr(rr.position), rr.size * _zoom), Color(0.02, 0.05, 0.08, 0.95), Color(0.20, 0.55, 0.70, 0.55), 1.0, 4.0 * _zoom)
		var y := ry + 4.0
		for s in rd:
			_text(Vector2(rr.position.x + 8, y + 10.5), s, 10.0, Color(0.45, 0.92, 1.0), HORIZONTAL_ALIGNMENT_LEFT, rr.size.x - 16.0, _fontn)
			y += READ_H


func _wire_dim(w: Dictionary) -> bool:
	var dim := _selected != "" and str(w["iid"]) != _selected
	if _sel_gpio >= 0:
		dim = not w["a"].is_equal_approx(_gpio_pin_pos(_sel_gpio, "left", float(w["b"].y))) and \
			not w["a"].is_equal_approx(_gpio_pin_pos(_sel_gpio, "right", float(w["b"].y)))
	return dim


## A jumper wire: an insulated cable with a sheen.
func _draw_wire(w: Dictionary) -> void:
	var col: Color = w["color"]
	if _wire_dim(w):
		col.a = 0.16
	var pts := PackedVector2Array()
	for q in (w["pts"] as PackedVector2Array):
		pts.append(_scr(q))
	var wdt := maxf(1.6, (3.6 if bool(w["locked"]) else 2.8) * _zoom)
	draw_polyline(pts, Color(0, 0, 0, col.a * 0.55), wdt + maxf(1.5, 1.6 * _zoom), true)
	draw_polyline(pts, col, wdt, true)
	var hi := PackedVector2Array()
	for p in pts:
		hi.append(p + Vector2(0, -wdt * 0.22))
	draw_polyline(hi, Color(col.lightened(0.55), col.a * 0.45), maxf(1.0, wdt * 0.3), true)
	if bool(w["locked"]):
		var m := pts[pts.size() / 2]
		var dd := 5.0 * maxf(0.7, _zoom)
		draw_colored_polygon(PackedVector2Array([m + Vector2(0, -dd), m + Vector2(dd, 0), m + Vector2(0, dd), m + Vector2(-dd, 0)]), UITheme.C_AMBER)


## Dupont housings on both ends of a jumper.
func _draw_wire_ends(w: Dictionary) -> void:
	var col: Color = w["color"]
	var a_dim := 0.16 if _wire_dim(w) else 1.0
	for end in [[w["a"], float(w["a_out"]), false], [w["b"], float(w["b_out"]), true]]:
		var p: Vector2 = end[0]
		var dir: float = end[1]
		var at_card: bool = end[2]
		var hl := 13.0
		var c := p + Vector2(dir * (hl * 0.5 - (6.0 if at_card else 1.0)), 0)
		var r := Rect2(_scr(c - Vector2(hl * 0.5, 4.5)), Vector2(hl, 9.0) * _zoom)
		Art.box(self, r, Color(0.06, 0.06, 0.07, a_dim), Color(0.25, 0.25, 0.28, a_dim), 1.0, 1.5 * _zoom)
		var band := Rect2(r.position + Vector2((r.size.x * 0.62 if dir > 0.0 else r.size.x * 0.18), r.size.y * 0.22),
			Vector2(r.size.x * 0.2, r.size.y * 0.56))
		draw_rect(band, Color(col, a_dim))


func _draw_legend() -> void:
	var x := 10.0
	var y := size.y - 20.0
	var items := [["GPIO", STATE_COLORS["free"], "free"], ["GPIO", STATE_COLORS["caveat"], "caveat"],
		["GPI", STATE_COLORS["input_only"], "input only"], ["", STATE_COLORS["reserved"], "taken"],
		["3.3V", STATE_COLORS["3v3"], ""], ["5V", STATE_COLORS["5v"], ""], ["GND", STATE_COLORS["gnd"], ""],
		["ADC", FN_COLORS["adc"], ""], ["SDA", FN_COLORS["i2c"], "I²C default"], ["MOSI", FN_COLORS["spi"], "SPI default"]]
	var bg := Rect2(4, y - 4, size.x - 8, 20)
	draw_rect(bg, Color(0.04, 0.05, 0.07, 0.85))
	for it in items:
		var t := str(it[0])
		var w := maxf(14.0, _fontb.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x + 10.0)
		var cr := Rect2(x, y, w, 13)
		var col: Color = it[1]
		Art.box(self, cr, col, col.darkened(0.35), 1.0, 3.0)
		if t != "":
			var fg := Color(0.08, 0.08, 0.1) if col.get_luminance() > 0.55 else Color.WHITE
			Art.text(self, _fontb, cr.get_center(), t, 9.0, fg)
		x += w + 4.0
		var words := str(it[2])
		if words != "":
			draw_string(_font, Vector2(x, y + 10), words, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_S)
			x += _font.get_string_size(words, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS).x
		x += 10.0


# ------------------------------------------------------------------ hit tests

func _hit_part_pin(s: Vector2) -> Dictionary:
	for iid in _cards:
		for label in _cards[iid]["pins"]:
			if _scr(_cards[iid]["pins"][label]).distance_to(s) <= maxf(7.0, 8.0 * _zoom):
				return {"iid": iid, "label": label, "pos": _cards[iid]["pins"][label]}
	return {}


## A board pin is its whole row: the hole, the pinout chips, the wire end.
func _hit_board_pin(s: Vector2) -> Dictionary:
	var d := _dia(s)
	for p in _pins:
		var key := "%s:%d" % [p["side"], p["index"]]
		var pp: Vector2 = _pin_pos[key]
		var hp: Vector2 = _hole_pos[key]
		var x0 := minf(pp.x, hp.x) - 8.0
		var x1 := maxf(pp.x, hp.x) + 8.0
		if d.x >= x0 and d.x <= x1 and absf(d.y - pp.y) <= PITCH * 0.45:
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
		var wp: PackedVector2Array = w["pts"]
		var prev := _scr(wp[0])
		for i in range(1, wp.size()):
			var cur := _scr(wp[i])
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
