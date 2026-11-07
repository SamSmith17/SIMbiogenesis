extends RefCounted

## Artwork for the ESP board designer's diagram, drawn in screen space onto a
## CanvasItem: the development board itself (PCB, the WROOM-style module and
## its PCB antenna or a bare chip and its antenna, shield cans, the USB
## socket, buttons, regulator, USB-serial chip, LEDs, mounting holes, a
## screen board's display, the M5 ATOM's case) and a small glyph per part
## card (the sensor's metal can, an ultrasonic pair, a relay cube, a screen,
## a probe on its cable…).
##
## Board coordinates are millimetres from the board's top-left corner,
## scaled by `k` (screen pixels per millimetre); the diagram draws the
## header holes, silkscreen pin names and the pin-function chips on top.

const SILK := Color(0.94, 0.94, 0.91)
const GOLD := Color(0.86, 0.69, 0.32)
const GOLD_D := Color(0.62, 0.47, 0.18)
const SILVER := Color(0.80, 0.82, 0.85)
const SILVER_D := Color(0.55, 0.57, 0.61)
const CHIP := Color(0.09, 0.09, 0.10)
const CHIP_TEXT := Color(0.55, 0.56, 0.60)
const HOLE := Color(0.03, 0.03, 0.04)

## How a part's breakout looks: [PCB colour hex, glyph].
const PART_LOOK := {
	"bme280": ["4a2f7e", "can"], "bmp280": ["4a2f7e", "can"], "bme680": ["4a2f7e", "can"], "aht20": ["1f3d7a", "ic"],
	"sht31": ["1f3d7a", "ic"], "sht40": ["1f3d7a", "ic"], "shtc3": ["1f3d7a", "ic"], "htu21d": ["4a2f7e", "ic"],
	"dht22": ["1f3d7a", "dht"], "dht11": ["1f3d7a", "dht"], "ds18b20": ["1c1d20", "probe"], "max6675": ["7a1d1d", "probe"],
	"max31865": ["4a2f7e", "probe"], "scd40": ["1c1d20", "ic"], "sgp30": ["4a2f7e", "ic"], "ccs811": ["4a2f7e", "ic"],
	"pms5003": ["2a2c30", "box"], "sen55": ["2a2c30", "box"], "mhz19b": ["1b5e33", "can"],
	"bh1750": ["1f3d7a", "ic"], "veml7700": ["1f3d7a", "ic"], "ltr390": ["1f3d7a", "ic"], "tsl2561": ["1f3d7a", "ic"],
	"tsl2591": ["1f3d7a", "ic"], "ina219": ["4a2f7e", "shunt"], "ina226": ["4a2f7e", "shunt"], "ina260": ["1f3d7a", "shunt"],
	"acs712": ["7a1d1d", "terminal"], "pzem004t": ["1b5e33", "box"], "ads1115": ["1f3d7a", "ic"],
	"hcsr04": ["1f5fa8", "ultrasonic"], "jsnsr04t": ["1c1d20", "probe"], "a02yyuw": ["1c1d20", "probe"],
	"vl53l0x": ["4a2f7e", "ic"], "pir_sr501": ["1b5e33", "pir"], "rcwl0516": ["1f3d7a", "radar"], "ld2410": ["1c1d20", "radar"],
	"soil_cap": ["1c1d20", "fork"], "leak_sensor": ["7a1d1d", "fork"], "float_switch": ["2a2c30", "float"],
	"yfs201": ["2a2c30", "flow"], "rain_gauge": ["2a2c30", "bucket"], "anemometer": ["2a2c30", "cups"],
	"hx711": ["1b5e33", "loadcell"], "neo6m": ["1f3d7a", "gps"], "mpu6050": ["1f3d7a", "ic"],
	"relay_1ch": ["1f5fa8", "relay"], "mosfet": ["1f3d7a", "terminal"], "buzzer": ["1c1d20", "buzzer"],
	"ws2812": ["1c1d20", "leds"], "servo_sg90": ["2a2c30", "servo"], "button": ["2a2c30", "button"],
	"rotary_encoder": ["1f3d7a", "knob"], "ssd1306": ["1c1d20", "screen"], "sh1106": ["1c1d20", "screen"],
	"lcd1602": ["1b5e33", "lcd"], "epaper_29": ["1c1d20", "epaper"], "mcp23017": ["1f3d7a", "ic"],
	"pcf8574": ["1f3d7a", "ic"], "max485": ["1f3d7a", "terminal"], "sn65hvd230": ["1f3d7a", "terminal"],
	"inmp441": ["4a2f7e", "mic"],
}


static func hexc(s: String) -> Color:
	return Color.html("#" + s)


static func part_look(pid: String) -> Dictionary:
	var l: Array = PART_LOOK.get(pid, ["1f3d7a", "ic"])
	return {"pcb": hexc(str(l[0])), "glyph": str(l[1])}


# ------------------------------------------------------------------ primitives

static func box(ci: CanvasItem, r: Rect2, bg: Color, border: Color = Color(0, 0, 0, 0), bw: float = 0.0, radius: float = 0.0) -> void:
	if r.size.x < 0.5 or r.size.y < 0.5:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	if bw > 0.0 and border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(int(maxf(1.0, bw)))
	var rad := int(minf(radius, minf(r.size.x, r.size.y) * 0.5))
	sb.set_corner_radius_all(rad)
	sb.anti_aliasing = true
	ci.draw_style_box(sb, r)


static func text(ci: CanvasItem, font: Font, center: Vector2, s: String, px: float, col: Color, max_w: float = -1.0) -> void:
	var fs := int(roundf(px))
	if fs < 5 or s == "":
		return
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	if max_w > 0.0 and w > max_w:
		fs = int(floorf(float(fs) * max_w / w))
		if fs < 5:
			return
		w = font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	ci.draw_string(font, center + Vector2(-w * 0.5, fs * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## Text centred on a point and turned by `angle` (radians).
static func text_rot(ci: CanvasItem, font: Font, center: Vector2, s: String, px: float, col: Color, angle: float) -> void:
	var fs := int(roundf(px))
	if fs < 5 or s == "":
		return
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	ci.draw_set_transform(center, angle, Vector2.ONE)
	ci.draw_string(font, Vector2(-w * 0.5, fs * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A rectangle in board millimetres -> screen.
static func mm(r: Rect2, k: float, x: float, y: float, w: float, h: float) -> Rect2:
	return Rect2(r.position + Vector2(x, y) * k, Vector2(w, h) * k)


static func pt(r: Rect2, k: float, x: float, y: float) -> Vector2:
	return r.position + Vector2(x, y) * k


# ------------------------------------------------------------------ the board

## Draw a development board into screen rect `r` at `k` px per mm.
static func draw_board(ci: CanvasItem, r: Rect2, k: float, look: Dictionary, chip_label: String, title: String,
		font: Font, fontb: Font) -> void:
	var W := r.size.x / k
	var H := r.size.y / k
	var pcb := hexc(str(look.get("pcb", "1c1d20")))
	var mod := str(look.get("module", "wroom"))
	var usb_top := bool(look.get("usb_top", false))
	# Shadow, board, edge highlight.
	box(ci, Rect2(r.position + Vector2(3, 5) * maxf(0.4, k * 0.25), r.size), Color(0, 0, 0, 0.35), Color(0, 0, 0, 0), 0.0, 1.4 * k)
	if mod == "atom":
		_atom(ci, r, k, W, H, look, fontb)
		return
	box(ci, r, pcb, pcb.lightened(0.22), maxf(1.0, 0.22 * k), 1.0 * k)
	box(ci, Rect2(r.position + Vector2(2, 2), Vector2(r.size.x - 4, r.size.y * 0.42)), Color(1, 1, 1, 0.035), Color(0, 0, 0, 0), 0.0, 1.0 * k)
	if bool(look.get("holes", false)) and W > 20.0:
		for c in [Vector2(2.6, 2.6), Vector2(W - 2.6, 2.6), Vector2(2.6, H - 2.6), Vector2(W - 2.6, H - 2.6)]:
			ci.draw_circle(pt(r, k, c.x, c.y), 1.55 * k, SILVER_D)
			ci.draw_circle(pt(r, k, c.x, c.y), 1.1 * k, HOLE)
	# Usable middle strip (clear of the header holes).
	var x0 := 4.4
	var x1 := W - 4.4
	var mid := (x1 - x0)
	var bottom_zone := 0.0 if usb_top else 6.5
	var top_zone := 6.5 if usb_top else 0.0
	var free_y := 1.2 + top_zone
	match mod:
		"wroom", "mini_module":
			var mw := minf(18.0 if mod == "wroom" else 13.2, mid + 1.5)
			var mh := minf(25.5 if mod == "wroom" else 16.6, H * 0.52)
			var my := 1.0 if not usb_top else H - mh - 1.0
			_wroom(ci, mm(r, k, (W - mw) * 0.5, my, mw, mh), k, str(look.get("module_label", "")), fontb, mod == "mini_module")
			free_y = my + mh + 1.2
		"esp12":
			var mw2 := minf(16.0, mid + 3.0)
			var mh2 := minf(24.0, H * 0.6)
			_esp12(ci, mm(r, k, (W - mw2) * 0.5, 1.0, mw2, mh2), k, str(look.get("module_label", "")), fontb)
			free_y = 1.0 + mh2 + 1.2
		"chip", "esp01":
			var ah := 4.5 if str(look.get("antenna", "pcb")) == "pcb" else 3.0
			var ay := 0.8 if not usb_top else H - ah - 0.8
			if str(look.get("antenna", "pcb")) == "pcb":
				_meander(ci, mm(r, k, x0 - 1.5, ay, mid + 3.0, ah), k)
			else:
				_ceramic(ci, mm(r, k, W * 0.5 - 2.6, ay + 0.6, 5.2, 1.8), k)
			var cs := clampf(mid * 0.42, 4.0, 7.0)
			var cy := ay + ah + 2.5
			_qfn(ci, mm(r, k, (W - cs) * 0.5, cy, cs, cs), k, str(look.get("chip_label", chip_label)), font)
			_crystal(ci, mm(r, k, W * 0.5 + cs * 0.5 + 0.6, cy + cs * 0.15, 2.6, 2.0), k)
			free_y = cy + cs + 1.2
			if mod == "esp01":
				_soic(ci, mm(r, k, W * 0.5 - 2.5, free_y + 0.5, 5.0, 4.0), k, "25Q80", font)
				free_y += 5.2
		"can":
			var cw := mid + 2.0
			var cy2 := 7.5 if usb_top else 1.5
			var ch := minf(11.0, H - cy2 - 3.0)
			_can(ci, mm(r, k, (W - cw) * 0.5, cy2, cw, ch), k, str(look.get("module_label", "")), chip_label, fontb, font)
			free_y = cy2 + ch + 1.0
		"pico":
			_qfn(ci, mm(r, k, W * 0.5 - 3.5, H * 0.38, 7.0, 7.0), k, "RP2040", font)
			_soic(ci, mm(r, k, W * 0.5 - 2.5, H * 0.38 + 8.2, 5.0, 4.0), k, "W25Q16", font)
			var cw2 := minf(9.0, mid)
			_can(ci, mm(r, k, (W - cw2) * 0.5, H * 0.62, cw2, 8.0), k, "", "CYW43439", fontb, font)
			_meander(ci, mm(r, k, x0, H - 6.5, mid, 4.5), k)
			_button(ci, pt(r, k, W * 0.36, 10.0), k, "BOOTSEL", font, Color(0.95, 0.95, 0.95))
			var lc := pt(r, k, W * 0.66, 8.6)
			ci.draw_rect(Rect2(lc - Vector2(0.8, 0.5) * k, Vector2(1.6, 1.0) * k), Color(0.92, 0.9, 0.85))
			ci.draw_rect(Rect2(lc - Vector2(0.45, 0.35) * k, Vector2(0.9, 0.7) * k), Color(0.3, 1.0, 0.45))
			text(ci, fontb, pt(r, k, W * 0.5, H * 0.30), "Raspberry Pi Pico W", 1.25 * k, SILK, mid * k)
			_usb(ci, r, k, W, H, str(look.get("usb", "")), true)
			return
		"screen":
			var sx := 3.6
			var sy := 3.0
			var sw := W - 7.2
			var sh := H - 3.0 - bottom_zone - 4.0
			_screen(ci, mm(r, k, sx, sy, sw, sh), k, str(look.get("screen", "")), title, font, fontb)
			free_y = sy + sh + 0.8
	# Silkscreen name, then the small parts under the module.
	var zone_end := H - bottom_zone - 0.8
	if not usb_top and mod != "screen" and zone_end - free_y > 9.0:
		var yl := free_y + 0.8
		if bool(look.get("reg", false)):
			_sot223(ci, mm(r, k, x0 + 0.6, yl + 2.5, 5.6, 3.4), k, "AMS1117", font)
		var br := str(look.get("bridge", ""))
		if br != "":
			if br.begins_with("CH340"):
				_soic(ci, mm(r, k, x1 - 6.4, yl + 2.2, 5.6, 4.4), k, br, font)
			else:
				_qfn(ci, mm(r, k, x1 - 5.6, yl + 2.0, 4.8, 4.8), k, br, font)
		_leds(ci, r, k, W, yl + 0.3, look)
		_passives(ci, r, k, x0, yl + 8.6, x1, zone_end - 0.4, pcb)
	elif mod != "screen" and mod != "pico":
		_leds(ci, r, k, W, minf(free_y + 0.4, H - bottom_zone - 2.0), look)
	# The board's name in silkscreen, small, where there is room.
	var lab := chip_label
	if mod in ["wroom", "esp12", "mini_module", "screen"]:
		lab = ""
	if lab != "" and not usb_top and free_y < H - bottom_zone - 3.0:
		text(ci, fontb, pt(r, k, W * 0.5, H - bottom_zone - 1.8), lab, 1.2 * k, SILK)
	_usb(ci, r, k, W, H, str(look.get("usb", "")), usb_top)
	_buttons(ci, r, k, W, H, look, usb_top, font)


static func _wroom(ci: CanvasItem, m: Rect2, k: float, label: String, fontb: Font, mini: bool) -> void:
	# The module's own PCB, its antenna end up.
	box(ci, m, Color(0.08, 0.08, 0.09), Color(0.2, 0.2, 0.22), 1.0, 0.4 * k)
	var ant_h := (6.2 if not mini else 4.2) * k
	_meander(ci, Rect2(m.position + Vector2(1.0 * k, 0.7 * k), Vector2(m.size.x - 2.0 * k, ant_h - 1.2 * k)), k)
	# Castellated pads down both sides and along the bottom.
	var pad := Color(GOLD, 0.95)
	var y := m.position.y + ant_h + 0.6 * k
	while y < m.end.y - 1.0 * k:
		ci.draw_rect(Rect2(Vector2(m.position.x - 0.15 * k, y), Vector2(0.7 * k, 0.55 * k)), pad)
		ci.draw_rect(Rect2(Vector2(m.end.x - 0.55 * k, y), Vector2(0.7 * k, 0.55 * k)), pad)
		y += 1.27 * k
	var x := m.position.x + 1.6 * k
	while x < m.end.x - 1.6 * k:
		ci.draw_rect(Rect2(Vector2(x, m.end.y - 0.55 * k), Vector2(0.55 * k, 0.7 * k)), pad)
		x += 1.27 * k
	# The shield can.
	var can := Rect2(m.position + Vector2(0.9 * k, ant_h + 0.3 * k), Vector2(m.size.x - 1.8 * k, m.size.y - ant_h - 1.5 * k))
	_metal(ci, can, k)
	var cx := can.get_center().x
	text(ci, fontb, Vector2(cx, can.position.y + can.size.y * 0.30), label, 1.25 * k, Color(0.22, 0.23, 0.26))
	# A Wi-Fi mark and the certification line.
	var wy := can.position.y + can.size.y * 0.52
	box(ci, Rect2(Vector2(cx - 2.2 * k, wy - 0.8 * k), Vector2(4.4 * k, 1.6 * k)), Color(0.40, 0.42, 0.46), Color(0, 0, 0, 0), 0.0, 0.8 * k)
	text(ci, fontb, Vector2(cx, wy), "Wi-Fi", 1.05 * k, Color(0.92, 0.93, 0.95))
	text(ci, fontb, Vector2(cx, can.position.y + can.size.y * 0.75), "CE  FCC", 0.9 * k, Color(0.40, 0.42, 0.46))
	ci.draw_circle(can.position + Vector2(1.1, can.size.y / k - 1.1) * k, 0.45 * k, Color(0.18, 0.18, 0.2))


static func _metal(ci: CanvasItem, r: Rect2, k: float) -> void:
	box(ci, r, SILVER, SILVER_D, maxf(1.0, 0.15 * k), 0.35 * k)
	# A soft diagonal sheen.
	var pts := PackedVector2Array([r.position + Vector2(r.size.x * 0.55, 0), r.position + Vector2(r.size.x * 0.8, 0),
		r.position + Vector2(r.size.x * 0.35, r.size.y), r.position + Vector2(r.size.x * 0.1, r.size.y)])
	ci.draw_colored_polygon(pts, Color(1, 1, 1, 0.12))


## A PCB antenna: a gold meander inside its keep-out.
static func _meander(ci: CanvasItem, r: Rect2, k: float) -> void:
	var col := Color(GOLD, 0.9)
	var w := maxf(1.0, 0.35 * k)
	var steps := maxi(3, int(r.size.x / (1.6 * k)))
	var dx := r.size.x / float(steps)
	var pts := PackedVector2Array()
	pts.append(Vector2(r.position.x, r.end.y))
	for i in steps:
		var x := r.position.x + dx * float(i)
		var top := i % 2 == 0
		pts.append(Vector2(x, r.position.y if top else r.end.y))
		pts.append(Vector2(x + dx, r.position.y if top else r.end.y))
	ci.draw_polyline(pts, col, w, true)


static func _ceramic(ci: CanvasItem, r: Rect2, k: float) -> void:
	box(ci, r, Color(0.93, 0.88, 0.76), Color(0.7, 0.66, 0.55), 1.0, 0.2 * k)
	ci.draw_rect(Rect2(r.position, Vector2(0.6 * k, r.size.y)), SILVER)
	ci.draw_rect(Rect2(Vector2(r.end.x - 0.6 * k, r.position.y), Vector2(0.6 * k, r.size.y)), SILVER)


## A QFN chip with its pin ticks and pin-1 dot.
static func _qfn(ci: CanvasItem, r: Rect2, k: float, label: String, font: Font) -> void:
	var n := maxi(3, int(r.size.x / (0.5 * k)) - 1)
	var tick := Vector2(0.18 * k, 0.45 * k)
	for i in n:
		var t := (float(i) + 1.0) / float(n + 1)
		var x := r.position.x + r.size.x * t
		var y := r.position.y + r.size.y * t
		ci.draw_rect(Rect2(Vector2(x - tick.x * 0.5, r.position.y - tick.y * 0.6), tick), SILVER_D)
		ci.draw_rect(Rect2(Vector2(x - tick.x * 0.5, r.end.y - tick.y * 0.4), tick), SILVER_D)
		ci.draw_rect(Rect2(Vector2(r.position.x - tick.y * 0.6, y - tick.x * 0.5), Vector2(tick.y, tick.x)), SILVER_D)
		ci.draw_rect(Rect2(Vector2(r.end.x - tick.y * 0.4, y - tick.x * 0.5), Vector2(tick.y, tick.x)), SILVER_D)
	box(ci, r, CHIP, Color(0.2, 0.2, 0.22), 1.0, 0.25 * k)
	ci.draw_circle(r.position + Vector2(0.8, 0.8) * k, 0.3 * k, Color(0.3, 0.3, 0.33))
	text(ci, font, r.get_center(), label, minf(1.0 * k, r.size.x * 0.9 / maxf(1.0, float(label.length())) * 1.7), CHIP_TEXT)


## An SOIC chip: legs on two sides.
static func _soic(ci: CanvasItem, r: Rect2, k: float, label: String, font: Font) -> void:
	var n := 4
	for i in n:
		var x := r.position.x + r.size.x * (float(i) + 0.5) / float(n)
		ci.draw_rect(Rect2(Vector2(x - 0.2 * k, r.position.y - 0.7 * k), Vector2(0.4 * k, 0.8 * k)), SILVER_D)
		ci.draw_rect(Rect2(Vector2(x - 0.2 * k, r.end.y - 0.1 * k), Vector2(0.4 * k, 0.8 * k)), SILVER_D)
	box(ci, r, CHIP, Color(0.2, 0.2, 0.22), 1.0, 0.2 * k)
	ci.draw_circle(r.position + Vector2(0.7, 0.7) * k, 0.25 * k, Color(0.3, 0.3, 0.33))
	text(ci, font, r.get_center(), label, minf(0.95 * k, r.size.x * 0.9 / maxf(1.0, float(label.length())) * 1.7), CHIP_TEXT)


## A SOT-223 regulator: body, tab, three legs.
static func _sot223(ci: CanvasItem, r: Rect2, k: float, label: String, font: Font) -> void:
	ci.draw_rect(Rect2(Vector2(r.get_center().x - 1.5 * k, r.position.y - 1.2 * k), Vector2(3.0 * k, 1.4 * k)), SILVER_D)
	for i in 3:
		var x := r.position.x + r.size.x * (0.2 + 0.3 * float(i))
		ci.draw_rect(Rect2(Vector2(x - 0.35 * k, r.end.y - 0.1 * k), Vector2(0.7 * k, 1.2 * k)), SILVER_D)
	box(ci, r, CHIP, Color(0.2, 0.2, 0.22), 1.0, 0.2 * k)
	text(ci, font, r.get_center(), label, minf(0.9 * k, r.size.x * 0.9 / maxf(1.0, float(label.length())) * 1.7), CHIP_TEXT)


static func _crystal(ci: CanvasItem, r: Rect2, k: float) -> void:
	_metal(ci, r, k)


static func _can(ci: CanvasItem, r: Rect2, k: float, label: String, sub: String, fontb: Font, font: Font) -> void:
	_metal(ci, r, k)
	if label != "":
		text(ci, fontb, r.get_center() - Vector2(0, r.size.y * 0.12), label, 1.9 * k, Color(0.25, 0.26, 0.3))
		text(ci, font, r.get_center() + Vector2(0, r.size.y * 0.22), sub, 1.0 * k, Color(0.35, 0.36, 0.4))
	else:
		text(ci, font, r.get_center(), sub, 1.0 * k, Color(0.35, 0.36, 0.4))


static func _esp12(ci: CanvasItem, m: Rect2, k: float, label: String, fontb: Font) -> void:
	box(ci, m, Color(0.07, 0.11, 0.20), Color(0.2, 0.26, 0.38), 1.0, 0.3 * k)
	var ant_h := 7.0 * k
	_meander(ci, Rect2(m.position + Vector2(1.2 * k, 0.8 * k), Vector2(m.size.x - 2.4 * k, ant_h - 1.6 * k)), k)
	var y := m.position.y + ant_h + 0.8 * k
	while y < m.end.y - 0.8 * k:
		ci.draw_rect(Rect2(Vector2(m.position.x - 0.2 * k, y), Vector2(0.8 * k, 0.9 * k)), GOLD)
		ci.draw_rect(Rect2(Vector2(m.end.x - 0.6 * k, y), Vector2(0.8 * k, 0.9 * k)), GOLD)
		y += 2.0 * k
	var can := Rect2(m.position + Vector2(1.5 * k, ant_h + 0.4 * k), Vector2(m.size.x - 3.0 * k, m.size.y - ant_h - 1.6 * k))
	_metal(ci, can, k)
	text(ci, fontb, can.get_center() - Vector2(0, can.size.y * 0.12), label, 1.15 * k, Color(0.22, 0.23, 0.26))
	text(ci, fontb, can.get_center() + Vector2(0, can.size.y * 0.14), "Wi-Fi", 0.95 * k, Color(0.35, 0.36, 0.4))


static func _screen(ci: CanvasItem, r: Rect2, k: float, model: String, title: String, font: Font, fontb: Font) -> void:
	box(ci, r, Color(0.02, 0.02, 0.03), Color(0.25, 0.26, 0.28), 1.0, 0.6 * k)
	var g := r.grow(-1.2 * k)
	box(ci, g, Color(0.03, 0.07, 0.13), Color(0, 0, 0, 0), 0.0, 0.3 * k)
	# A little status UI on the glass.
	var bar := Rect2(g.position + Vector2(0.8, 0.8) * k, Vector2(g.size.x - 1.6 * k, 3.2 * k))
	box(ci, bar, Color(0.08, 0.35, 0.55, 0.85), Color(0, 0, 0, 0), 0.0, 0.4 * k)
	text(ci, fontb, bar.get_center(), title, minf(1.6 * k, bar.size.x / maxf(1.0, float(title.length())) * 1.7), Color(0.9, 0.97, 1.0))
	var y := bar.end.y + 2.2 * k
	var widths := [0.72, 0.55, 0.64, 0.4]
	var i := 0
	while y < g.end.y - 4.0 * k and i < 4:
		box(ci, Rect2(Vector2(g.position.x + 1.2 * k, y), Vector2((g.size.x - 2.4 * k) * float(widths[i]), 1.4 * k)),
			Color(0.20, 0.75, 0.95, 0.55), Color(0, 0, 0, 0), 0.0, 0.5 * k)
		y += 3.2 * k
		i += 1
	text(ci, font, Vector2(g.get_center().x, g.end.y - 1.6 * k), model, 1.0 * k, Color(0.45, 0.55, 0.65))
	var pts := PackedVector2Array([g.position, g.position + Vector2(g.size.x * 0.35, 0), g.position + Vector2(0, g.size.y * 0.35)])
	ci.draw_colored_polygon(pts, Color(1, 1, 1, 0.05))


static func _atom(ci: CanvasItem, r: Rect2, k: float, W: float, H: float, look: Dictionary, fontb: Font) -> void:
	box(ci, r, Color(0.20, 0.21, 0.24), Color(0.36, 0.38, 0.42), maxf(1.0, 0.25 * k), 2.6 * k)
	var face := r.grow(-1.6 * k)
	box(ci, face, Color(0.88, 0.89, 0.91), Color(0.7, 0.71, 0.74), 1.0, 2.0 * k)
	var btn := face.grow(-3.4 * k)
	box(ci, btn, Color(0.80, 0.81, 0.84), Color(0.66, 0.67, 0.7), 1.0, 1.6 * k)
	text(ci, fontb, btn.get_center(), "M5", 3.4 * k, Color(0.55, 0.56, 0.6))
	ci.draw_circle(pt(r, k, W * 0.5, 4.4), 0.9 * k, Color(0.25, 0.75, 1.0, 0.9))
	ci.draw_circle(pt(r, k, W * 0.5, 4.4), 1.8 * k, Color(0.25, 0.75, 1.0, 0.18))
	# The USB-C socket is in the case's bottom face: only its mouth shows.
	var mouth := mm(r, k, W * 0.5 - 4.4, H - 1.2, 8.8, 2.4)
	box(ci, mouth, SILVER, SILVER_D, 1.0, 1.0 * k)
	box(ci, mouth.grow(-0.5 * k), Color(0.12, 0.12, 0.14), Color(0, 0, 0, 0), 0.0, 0.7 * k)


static func _usb(ci: CanvasItem, r: Rect2, k: float, W: float, H: float, kind: String, top: bool) -> void:
	if kind == "":
		return
	var xs: Array = [W * 0.5]
	if kind == "c2":
		xs = [W * 0.3, W * 0.7]
	for xc in xs:
		var micro := kind == "micro"
		var w := 7.6 if micro else 8.8
		var d := 5.4 if micro else 7.2
		var y := -1.3 if top else H - d + 1.3
		var body := mm(r, k, float(xc) - w * 0.5, y, w, d)
		box(ci, body, SILVER, SILVER_D, 1.0, (0.6 if micro else 1.4) * k)
		var mouth_y := body.position.y + 0.5 * k if top else body.end.y - 2.0 * k
		box(ci, Rect2(Vector2(body.position.x + 0.8 * k, mouth_y), Vector2(body.size.x - 1.6 * k, 1.5 * k)),
			Color(0.12, 0.12, 0.14), Color(0, 0, 0, 0), 0.0, (0.2 if micro else 0.7) * k)
		var sheen := Rect2(body.position + Vector2(0.6 * k, (2.4 if top else 0.6) * k), Vector2(body.size.x - 1.2 * k, 0.6 * k))
		ci.draw_rect(sheen, Color(1, 1, 1, 0.22))


static func _buttons(ci: CanvasItem, r: Rect2, k: float, W: float, H: float, look: Dictionary, top: bool, font: Font) -> void:
	var names: Array = look.get("buttons", [])
	if names.is_empty() or str(look.get("module", "")) == "pico":
		return
	if top and W < 20.0:
		return    # a XIAO's buttons are too small to show beside its USB socket
	var y := 8.2 if top else H - 4.4
	if str(look.get("usb", "")) == "c2":
		y = H - 10.0
	var xs: Array = [W * 0.24, W * 0.76] if names.size() > 1 else [W * 0.24]
	if W < 20.0:
		y = H - 8.0
	for i in mini(names.size(), xs.size()):
		_button(ci, pt(r, k, float(xs[i]), y), k, str(names[i]), font, Color(0.10, 0.10, 0.11))


static func _button(ci: CanvasItem, c: Vector2, k: float, label: String, font: Font, cap: Color) -> void:
	var s := 3.4 * k
	box(ci, Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), SILVER, SILVER_D, 1.0, 0.25 * k)
	ci.draw_circle(c, 1.15 * k, cap)
	ci.draw_circle(c + Vector2(-0.3, -0.3) * k, 0.45 * k, Color(1, 1, 1, 0.12))
	text(ci, font, c + Vector2(0, 2.7 * k), label, 0.95 * k, SILK)


static func _leds(ci: CanvasItem, r: Rect2, k: float, W: float, y: float, look: Dictionary) -> void:
	var leds: Array = look.get("leds", [])
	var cols := {"power": Color(1.0, 0.18, 0.15), "gpio": Color(0.25, 0.6, 1.0), "rgb": Color(0.95, 0.95, 0.95)}
	var i := 0
	for l in leds:
		var x := W * (0.38 + 0.24 * float(i))
		var c := pt(r, k, x, y + 0.6)
		ci.draw_rect(Rect2(c - Vector2(0.8, 0.5) * k, Vector2(1.6, 1.0) * k), Color(0.92, 0.9, 0.85))
		var col: Color = cols.get(str(l), Color.WHITE)
		if str(l) == "power":
			ci.draw_circle(c, 1.4 * k, Color(col, 0.25))
		ci.draw_rect(Rect2(c - Vector2(0.45, 0.35) * k, Vector2(0.9, 0.7) * k), col)
		i += 1


## A few deterministic SMD resistors / capacitors in a zone.
static func _passives(ci: CanvasItem, r: Rect2, k: float, x0: float, y0: float, x1: float, y1: float, pcb: Color) -> void:
	if y1 - y0 < 2.0:
		return
	var cols := [Color(0.08, 0.08, 0.09), Color(0.72, 0.58, 0.38), Color(0.08, 0.08, 0.09)]
	var n := 0
	var y := y0
	while y < y1 - 1.0 and n < 14:
		var x := x0 + 1.0 + fmod(float(n) * 2.9, 3.0)
		while x < x1 - 2.0 and n < 14:
			var c := pt(r, k, x, y)
			ci.draw_rect(Rect2(c, Vector2(1.6, 0.8) * k), SILVER_D)
			ci.draw_rect(Rect2(c + Vector2(0.3, 0) * k, Vector2(1.0, 0.8) * k), cols[n % 3])
			x += 4.3 + float(n % 3)
			n += 1
		y += 2.6


# ------------------------------------------------------------------ part glyphs

## The glyph of a part, drawn inside screen rect `g`.
static func draw_glyph(ci: CanvasItem, g: Rect2, z: float, glyph: String, font: Font, pcb: Color) -> void:
	var s := minf(g.size.x, g.size.y)
	var c := g.get_center()
	match glyph:
		"can":
			_metal(ci, Rect2(c - Vector2(s, s) * 0.18, Vector2(s, s) * 0.36), s * 0.1)
			ci.draw_circle(c + Vector2(s * 0.08, -s * 0.08), maxf(1.0, s * 0.035), Color(0.1, 0.1, 0.12))
			_mini_ic(ci, Rect2(c + Vector2(-s * 0.42, s * 0.18), Vector2(s * 0.18, s * 0.12)))
		"ic":
			var r := Rect2(c - Vector2(s, s) * 0.22, Vector2(s, s) * 0.44)
			for i in 4:
				var t := (float(i) + 0.5) / 4.0
				ci.draw_rect(Rect2(Vector2(r.position.x - s * 0.06, r.position.y + r.size.y * t - s * 0.015), Vector2(s * 0.06, s * 0.03)), SILVER_D)
				ci.draw_rect(Rect2(Vector2(r.end.x, r.position.y + r.size.y * t - s * 0.015), Vector2(s * 0.06, s * 0.03)), SILVER_D)
			box(ci, r, CHIP, Color(0.22, 0.22, 0.25), 1.0, s * 0.03)
			ci.draw_circle(r.position + Vector2(s, s) * 0.05, maxf(1.0, s * 0.025), Color(0.32, 0.32, 0.35))
		"shunt":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.35, -s * 0.32), Vector2(s * 0.3, s * 0.14)), Color(0.08, 0.08, 0.09))
			_terminal(ci, Rect2(c + Vector2(-s * 0.4, s * 0.05), Vector2(s * 0.5, s * 0.3)))
			_mini_ic(ci, Rect2(c + Vector2(s * 0.15, -s * 0.2), Vector2(s * 0.22, s * 0.22)))
		"terminal":
			_terminal(ci, Rect2(c + Vector2(-s * 0.4, -s * 0.15), Vector2(s * 0.8, s * 0.36)))
			_mini_ic(ci, Rect2(c + Vector2(-s * 0.12, -s * 0.42), Vector2(s * 0.24, s * 0.2)))
		"probe":
			var pts := PackedVector2Array()
			for i in 13:
				var t := float(i) / 12.0
				pts.append(c + Vector2(-s * 0.4 + s * 0.6 * t, sin(t * PI * 2.0) * s * 0.12))
			ci.draw_polyline(pts, Color(0.06, 0.06, 0.07), maxf(2.0, s * 0.07), true)
			box(ci, Rect2(c + Vector2(s * 0.18, -s * 0.07), Vector2(s * 0.3, s * 0.14)), SILVER, SILVER_D, 1.0, s * 0.07)
		"box":
			var r2 := Rect2(c - Vector2(s * 0.45, s * 0.32), Vector2(s * 0.9, s * 0.64))
			_metal(ci, r2, s * 0.08)
			for i in 5:
				var x := r2.position.x + r2.size.x * (0.15 + 0.08 * float(i))
				ci.draw_line(Vector2(x, r2.position.y + r2.size.y * 0.2), Vector2(x, r2.end.y - r2.size.y * 0.2), Color(0.3, 0.31, 0.34), maxf(1.0, s * 0.02))
			ci.draw_circle(r2.position + r2.size * Vector2(0.72, 0.5), r2.size.y * 0.32, Color(0.25, 0.26, 0.28))
			ci.draw_circle(r2.position + r2.size * Vector2(0.72, 0.5), r2.size.y * 0.1, Color(0.5, 0.52, 0.56))
		"ultrasonic":
			for dx in [-0.24, 0.24]:
				var cc := c + Vector2(s * float(dx), 0)
				ci.draw_circle(cc, s * 0.2, SILVER)
				ci.draw_circle(cc, s * 0.16, Color(0.12, 0.12, 0.13))
				for ring in [0.11, 0.06]:
					ci.draw_arc(cc, s * float(ring), 0, TAU, 20, Color(0.3, 0.3, 0.32), maxf(1.0, s * 0.015), true)
		"dht":
			var r3 := Rect2(c - Vector2(s * 0.24, s * 0.36), Vector2(s * 0.48, s * 0.72))
			box(ci, r3, Color(0.92, 0.93, 0.95), Color(0.7, 0.72, 0.75), 1.0, s * 0.04)
			for yy in 4:
				for xx in 3:
					ci.draw_rect(Rect2(r3.position + Vector2(r3.size.x * (0.18 + 0.25 * float(xx)), r3.size.y * (0.12 + 0.18 * float(yy))), Vector2(s * 0.07, s * 0.07)), Color(0.55, 0.57, 0.62))
		"pir":
			ci.draw_circle(c, s * 0.38, Color(0.93, 0.94, 0.95))
			for i in 8:
				var a := TAU * float(i) / 8.0
				ci.draw_line(c, c + Vector2(cos(a), sin(a)) * s * 0.38, Color(0.78, 0.79, 0.82), maxf(1.0, s * 0.012))
			ci.draw_arc(c, s * 0.2, 0, TAU, 24, Color(0.78, 0.79, 0.82), maxf(1.0, s * 0.012), true)
		"radar":
			for yy in 2:
				for xx in 3:
					box(ci, Rect2(c + Vector2(-s * 0.38 + s * 0.27 * float(xx), -s * 0.3 + s * 0.34 * float(yy)), Vector2(s * 0.18, s * 0.18)), GOLD, GOLD_D, 1.0, s * 0.01)
		"fork":
			for dx in [-0.17, 0.07]:
				box(ci, Rect2(c + Vector2(s * float(dx), -s * 0.45), Vector2(s * 0.12, s * 0.9)), pcb.lightened(0.1), GOLD_D, 1.0, s * 0.05)
				ci.draw_line(c + Vector2(s * (float(dx) + 0.06), -s * 0.4), c + Vector2(s * (float(dx) + 0.06), s * 0.4), Color(GOLD, 0.7), maxf(1.0, s * 0.02))
		"float":
			ci.draw_line(c + Vector2(0, -s * 0.45), c + Vector2(0, s * 0.45), SILVER_D, maxf(2.0, s * 0.05))
			box(ci, Rect2(c - Vector2(s * 0.22, s * 0.14), Vector2(s * 0.44, s * 0.28)), Color(0.9, 0.9, 0.92), Color(0.6, 0.6, 0.65), 1.0, s * 0.13)
		"flow":
			box(ci, Rect2(c - Vector2(s * 0.45, s * 0.14), Vector2(s * 0.9, s * 0.28)), Color(0.78, 0.62, 0.28), Color(0.55, 0.42, 0.15), 1.0, s * 0.05)
			ci.draw_circle(c, s * 0.2, Color(0.12, 0.12, 0.13))
			ci.draw_line(c + Vector2(-s * 0.12, 0), c + Vector2(s * 0.12, 0), Color(0.3, 0.7, 1.0), maxf(1.5, s * 0.03))
		"bucket":
			var pts2 := PackedVector2Array([c + Vector2(-s * 0.35, -s * 0.3), c + Vector2(s * 0.35, -s * 0.3), c + Vector2(s * 0.08, s * 0.1), c + Vector2(-s * 0.08, s * 0.1)])
			ci.draw_colored_polygon(pts2, Color(0.82, 0.84, 0.88))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.05, s * 0.1), Vector2(s * 0.1, s * 0.25)), Color(0.6, 0.62, 0.66))
			ci.draw_circle(c + Vector2(0, -s * 0.15), s * 0.03, Color(0.3, 0.6, 1.0))
		"cups":
			for i in 3:
				var a2 := TAU * float(i) / 3.0 - PI * 0.5
				var e := c + Vector2(cos(a2), sin(a2)) * s * 0.3
				ci.draw_line(c, e, SILVER_D, maxf(1.5, s * 0.03))
				ci.draw_circle(e, s * 0.1, Color(0.9, 0.9, 0.92))
			ci.draw_circle(c, s * 0.06, Color(0.3, 0.3, 0.33))
		"loadcell":
			box(ci, Rect2(c - Vector2(s * 0.45, s * 0.12), Vector2(s * 0.9, s * 0.24)), Color(0.78, 0.8, 0.83), SILVER_D, 1.0, s * 0.02)
			for dx in [-0.3, 0.3]:
				ci.draw_circle(c + Vector2(s * float(dx), 0), s * 0.05, Color(0.3, 0.3, 0.32))
			ci.draw_rect(Rect2(c - Vector2(s * 0.08, s * 0.08), Vector2(s * 0.16, s * 0.16)), Color(0.15, 0.4, 0.75))
		"gps":
			box(ci, Rect2(c - Vector2(s, s) * 0.3, Vector2(s, s) * 0.6), Color(0.86, 0.80, 0.66), Color(0.6, 0.55, 0.45), 1.0, s * 0.03)
			box(ci, Rect2(c - Vector2(s, s) * 0.2, Vector2(s, s) * 0.4), Color(0.80, 0.82, 0.85), SILVER_D, 1.0, s * 0.02)
			ci.draw_circle(c + Vector2(s * 0.08, -s * 0.08), s * 0.04, Color(0.5, 0.45, 0.3))
		"relay":
			var r4 := Rect2(c - Vector2(s * 0.42, s * 0.3), Vector2(s * 0.6, s * 0.6))
			box(ci, r4, Color(0.13, 0.42, 0.85), Color(0.08, 0.28, 0.6), 1.0, s * 0.03)
			text(ci, font, r4.get_center() - Vector2(0, s * 0.06), "SRD-05VDC", s * 0.08, Color(0.9, 0.95, 1.0))
			text(ci, font, r4.get_center() + Vector2(0, s * 0.08), "10A 250VAC", s * 0.06, Color(0.85, 0.9, 1.0))
			_terminal(ci, Rect2(Vector2(r4.end.x + s * 0.04, c.y - s * 0.3), Vector2(s * 0.2, s * 0.6)), true)
		"buzzer":
			ci.draw_circle(c, s * 0.34, Color(0.08, 0.08, 0.09))
			ci.draw_arc(c, s * 0.34, 0, TAU, 32, Color(0.3, 0.3, 0.32), maxf(1.0, s * 0.02), true)
			ci.draw_circle(c, s * 0.06, Color(0.25, 0.25, 0.27))
		"leds":
			var cols := [Color(1, 0.25, 0.3), Color(0.3, 1, 0.45), Color(0.3, 0.55, 1)]
			for i in 3:
				var cc2 := c + Vector2(s * (-0.3 + 0.3 * float(i)), 0)
				box(ci, Rect2(cc2 - Vector2(s, s) * 0.11, Vector2(s, s) * 0.22), Color(0.95, 0.95, 0.95), Color(0.75, 0.75, 0.78), 1.0, s * 0.02)
				ci.draw_circle(cc2, s * 0.07, cols[i])
				ci.draw_circle(cc2, s * 0.14, Color(cols[i], 0.25))
		"servo":
			box(ci, Rect2(c - Vector2(s * 0.42, s * 0.22), Vector2(s * 0.84, s * 0.44)), Color(0.15, 0.38, 0.8), Color(0.1, 0.25, 0.55), 1.0, s * 0.04)
			ci.draw_circle(c + Vector2(-s * 0.18, 0), s * 0.12, Color(0.92, 0.92, 0.94))
			ci.draw_line(c + Vector2(-s * 0.18, 0), c + Vector2(s * 0.1, -s * 0.2), Color(0.92, 0.92, 0.94), maxf(2.0, s * 0.07), true)
		"button":
			box(ci, Rect2(c - Vector2(s, s) * 0.26, Vector2(s, s) * 0.52), SILVER, SILVER_D, 1.0, s * 0.03)
			ci.draw_circle(c, s * 0.17, Color(0.85, 0.2, 0.2))
		"knob":
			ci.draw_circle(c, s * 0.34, SILVER_D)
			ci.draw_circle(c, s * 0.28, SILVER)
			for i in 12:
				var a3 := TAU * float(i) / 12.0
				ci.draw_line(c + Vector2(cos(a3), sin(a3)) * s * 0.28, c + Vector2(cos(a3), sin(a3)) * s * 0.34, Color(0.4, 0.41, 0.44), maxf(1.0, s * 0.015))
			ci.draw_line(c, c + Vector2(0, -s * 0.24), Color(0.3, 0.3, 0.32), maxf(1.5, s * 0.03))
		"mic":
			ci.draw_circle(c, s * 0.24, SILVER)
			ci.draw_circle(c, s * 0.05, Color(0.1, 0.1, 0.12))
		"screen", "lcd", "epaper":
			var r5 := Rect2(c - Vector2(s * 0.48, s * 0.34), Vector2(s * 0.96, s * 0.68))
			var bg := Color(0.02, 0.02, 0.03)
			var fg := Color(0.3, 0.85, 1.0)
			if glyph == "lcd":
				bg = Color(0.32, 0.62, 0.18)
				fg = Color(0.08, 0.2, 0.05)
			elif glyph == "epaper":
				bg = Color(0.86, 0.86, 0.82)
				fg = Color(0.1, 0.1, 0.1)
			box(ci, r5, Color(0.08, 0.08, 0.09), Color(0.25, 0.25, 0.27), 1.0, s * 0.03)
			var gl := r5.grow(-s * 0.05)
			box(ci, gl, bg, Color(0, 0, 0, 0), 0.0, s * 0.02)
			if glyph == "lcd":
				for row in 2:
					for col in 10:
						ci.draw_rect(Rect2(gl.position + Vector2(gl.size.x * (0.05 + 0.092 * float(col)), gl.size.y * (0.2 + 0.4 * float(row))), Vector2(gl.size.x * 0.07, gl.size.y * 0.3)), Color(fg, 0.35 if (row + col) % 3 != 0 else 0.85))
			else:
				for row2 in 3:
					ci.draw_rect(Rect2(gl.position + Vector2(gl.size.x * 0.08, gl.size.y * (0.18 + 0.27 * float(row2))), Vector2(gl.size.x * (0.8 - 0.18 * float(row2)), gl.size.y * 0.12)), Color(fg, 0.8))
		_:
			_mini_ic(ci, Rect2(c - Vector2(s, s) * 0.2, Vector2(s, s) * 0.4))


static func _mini_ic(ci: CanvasItem, r: Rect2) -> void:
	box(ci, r, CHIP, Color(0.22, 0.22, 0.25), 1.0, minf(r.size.x, r.size.y) * 0.08)


## Green screw terminals: one per slot along the long side.
static func _terminal(ci: CanvasItem, r: Rect2, vertical: bool = false) -> void:
	box(ci, r, Color(0.12, 0.55, 0.32), Color(0.07, 0.36, 0.2), 1.0, minf(r.size.x, r.size.y) * 0.08)
	var n := 3 if vertical else 2
	for i in n:
		var t := (float(i) + 0.5) / float(n)
		var c := r.position + (Vector2(r.size.x * 0.5, r.size.y * t) if vertical else Vector2(r.size.x * t, r.size.y * 0.5))
		var rad := minf(r.size.x, r.size.y) * (0.3 if vertical else 0.28)
		ci.draw_circle(c, rad, SILVER)
		ci.draw_line(c - Vector2(rad * 0.6, 0), c + Vector2(rad * 0.6, 0), Color(0.3, 0.3, 0.33), maxf(1.0, rad * 0.2))
