extends Control

## Hydro Lab stat deck — the machine's operating point as a row of big tiles
## in CAUSAL order, left to right: what the source gives → the head that
## survives the pipe → the pressure that puts behind the jet → the jet the
## nozzle makes of it → how fast the runner turns → the watts. Every tile
## carries a bar against the thing that LIMITS it (flow vs the source, net vs
## gross head, static pressure vs the pipe's rating, jet demand vs supply, rpm
## vs runaway, power vs nameplate), a one-line relation under the number, and
## a hover tip that says the rule in words. A value that moves FLASHES, so
## dragging the test flow or a nozzle size shows the chain react tile by tile.
##
## Under the tiles: an INSIGHT line (what is limiting the output right now,
## coloured by severity) and a SENSITIVITY line ("+1 m head → +12 W · +1 mm
## jet → +31 W …"), both written by the Lab from the same operating point the
## dock and the status strip read — pure _draw over pushed data, no model
## access. No class_name: ui_compile_selftest sweeps scenes/ui/.

const C_TILE := Color(0.110, 0.145, 0.255, 0.92)
const C_TILE_EDGE := Color(0.227, 0.290, 0.420, 1.0)
const C_LABEL := Color(0.580, 0.639, 0.722, 1.0)
const C_VALUE := Color(0.886, 0.910, 0.941, 1.0)
const C_SUB := Color(0.62, 0.68, 0.78, 0.9)
const C_TRACK := Color(0.04, 0.06, 0.11, 0.9)
const C_ARROW := Color(0.40, 0.50, 0.66, 0.9)
const TONES := {
	"ok": Color(0.149, 0.902, 0.467, 1.0),
	"accent": Color(0.133, 0.827, 0.933, 1.0),
	"warn": Color(0.961, 0.620, 0.043, 1.0),
	"bad": Color(0.937, 0.267, 0.267, 1.0),
	"muted": Color(0.392, 0.447, 0.545, 1.0),
}

const TILE_H := 78.0
const GAP := 14.0          ## tile gap — the arrow lives in it
const INSIGHT_H := 17.0
const SENS_H := 15.0
const FLASH_MS := 650

## [{key, label, value, unit, sub, frac, bar_text, tone, tip}]
var _tiles: Array = []
var _insight := ""
var _insight_tone := "muted"
var _sens := ""
var _prev_values: Dictionary = {}   ## key → last value string
var _flash_ms: Dictionary = {}      ## key → tick ms the value last changed
var _tile_rects: Array = []         ## Rect2 per tile, for the hover tip


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(0, TILE_H + 6.0 + INSIGHT_H + SENS_H + 4.0)


func set_tiles(tiles: Array) -> void:
	var now := Time.get_ticks_msec()
	for t: Variant in tiles:
		var td: Dictionary = t
		var key := str(td.get("key", ""))
		var v := str(td.get("value", ""))
		if _prev_values.has(key) and str(_prev_values[key]) != v:
			_flash_ms[key] = now
		_prev_values[key] = v
	_tiles = tiles
	queue_redraw()


func set_insight(text: String, tone: String = "muted") -> void:
	if text == _insight and tone == _insight_tone:
		return
	_insight = text
	_insight_tone = tone
	queue_redraw()


func set_sensitivity(text: String) -> void:
	if text == _sens:
		return
	_sens = text
	queue_redraw()


func _tone(name: String) -> Color:
	return TONES.get(name, TONES["muted"]) as Color


## Trim `text` with an ellipsis to fit `px` at `font_px` — a sub line must
## never run into the next tile on a narrow Lab.
static func _fit(fnt: Font, text: String, px: float, font_px: int) -> String:
	if fnt.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_px).x <= px:
		return text
	var t := text
	while t.length() > 1:
		t = t.substr(0, t.length() - 1)
		if fnt.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_px).x <= px:
			return t.strip_edges() + "…"
	return "…"


func _draw() -> void:
	_tile_rects.clear()
	var fnt := ThemeDB.fallback_font
	var n := _tiles.size()
	var now := Time.get_ticks_msec()
	var any_flash := false
	if n > 0:
		var w := maxf(size.x, 1.0)
		var tile_w := (w - GAP * float(n - 1)) / float(n)
		# Fit the number to the tile: a 2-nozzle PowerSpout on a wide monitor
		# gets 26 px digits, a six-tile row on a narrow Lab still reads at 18.
		var value_px := int(clampf(tile_w / 7.5, 17.0, 26.0))
		for i in n:
			var td: Dictionary = _tiles[i]
			var x := float(i) * (tile_w + GAP)
			var rect := Rect2(x, 0.0, tile_w, TILE_H)
			_tile_rects.append(rect)
			var tone := _tone(str(td.get("tone", "muted")))
			var key := str(td.get("key", ""))
			var flash := 0.0
			if _flash_ms.has(key):
				var age := float(now - int(_flash_ms[key])) / float(FLASH_MS)
				if age < 1.0:
					flash = 1.0 - age
					any_flash = true
			# Card.
			var sb := StyleBoxFlat.new()
			sb.bg_color = C_TILE
			sb.set_corner_radius_all(7)
			sb.border_color = C_TILE_EDGE.lerp(tone, 0.35 + 0.65 * flash)
			sb.set_border_width_all(1)
			draw_style_box(sb, rect)
			if flash > 0.0:
				# A soft inner glow that decays — "this one just changed".
				draw_rect(Rect2(rect.position + Vector2(1, 1), rect.size - Vector2(2, 2)),
						Color(tone.r, tone.g, tone.b, 0.10 * flash), true)
			# Tone stripe down the left edge.
			draw_rect(Rect2(rect.position + Vector2(1.0, 8.0), Vector2(3.0, TILE_H - 16.0)),
					Color(tone.r, tone.g, tone.b, 0.85), true)
			var tx := rect.position.x + 11.0
			var inner_w := tile_w - 16.0
			# Label (small caps feel: upper-case, letter-spaced by hand).
			draw_string(fnt, Vector2(tx, rect.position.y + 15.0),
					_fit(fnt, str(td.get("label", "")).to_upper(), inner_w, 10),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_LABEL)
			# Value + unit on one baseline.
			var value := str(td.get("value", "—"))
			var unit := str(td.get("unit", ""))
			var vy := rect.position.y + 15.0 + float(value_px) + 4.0
			var vcol := C_VALUE if str(td.get("tone", "")) != "muted" else C_LABEL
			draw_string(fnt, Vector2(tx, vy), value, HORIZONTAL_ALIGNMENT_LEFT,
					-1, value_px, vcol)
			var vw := fnt.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, value_px).x
			if not unit.is_empty():
				draw_string(fnt, Vector2(tx + vw + 5.0, vy),
						_fit(fnt, unit, maxf(inner_w - vw - 5.0, 8.0), 11),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_SUB)
			# Relation line.
			draw_string(fnt, Vector2(tx, vy + 13.0), _fit(fnt, str(td.get("sub", "")), inner_w, 10),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_SUB)
			# Bar against the limit.
			var frac_v: Variant = td.get("frac", NAN)
			var frac := float(frac_v) if (frac_v is float or frac_v is int) else NAN
			var by := rect.end.y - 9.0
			var bw := inner_w
			draw_rect(Rect2(Vector2(tx, by), Vector2(bw, 4.0)), C_TRACK, true)
			if not is_nan(frac):
				var f := clampf(frac, 0.0, 1.0)
				draw_rect(Rect2(Vector2(tx, by), Vector2(bw * f, 4.0)),
						Color(tone.r, tone.g, tone.b, 0.9), true)
				if frac > 1.0:
					# Over the limit — spill a red cap past the end.
					draw_rect(Rect2(Vector2(tx + bw - 3.0, by - 1.0), Vector2(3.0, 6.0)),
							_tone("bad"), true)
			var bt := str(td.get("bar_text", ""))
			if not bt.is_empty():
				var btw := fnt.get_string_size(bt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
				draw_string(fnt, Vector2(tx + bw - btw, by - 3.0), bt,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
						Color(tone.r, tone.g, tone.b, 0.95))
			# Arrow into the next tile: the chain is the point.
			if i < n - 1:
				var ax := rect.end.x + GAP * 0.5
				var ay := rect.position.y + TILE_H * 0.5
				draw_polyline(PackedVector2Array([
					Vector2(ax - 3.0, ay - 5.0), Vector2(ax + 2.0, ay), Vector2(ax - 3.0, ay + 5.0)]),
					C_ARROW, 1.6, true)
	# Insight + sensitivity lines.
	var iy := TILE_H + 6.0
	if not _insight.is_empty():
		var icol := _tone(_insight_tone)
		draw_circle(Vector2(5.0, iy + 7.0), 3.0, icol)
		draw_string(fnt, Vector2(14.0, iy + 12.0), _fit(fnt, _insight, maxf(size.x - 16.0, 8.0), 11),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				C_VALUE if _insight_tone == "ok" or _insight_tone == "accent" else icol)
	if not _sens.is_empty():
		draw_string(fnt, Vector2(14.0, iy + INSIGHT_H + 12.0),
				_fit(fnt, _sens, maxf(size.x - 16.0, 8.0), 10),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_SUB)
	if any_flash:
		queue_redraw()


func _get_tooltip(at_position: Vector2) -> String:
	for i in mini(_tile_rects.size(), _tiles.size()):
		if (_tile_rects[i] as Rect2).has_point(at_position):
			return str((_tiles[i] as Dictionary).get("tip", ""))
	return ""
