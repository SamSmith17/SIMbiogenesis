class_name GraphFastDraw
extends RefCounted

## Cheap discs, rings and rounded rectangles for the graph canvas, drawn from
## small cached anti-aliased WHITE textures tinted by modulate — one texture /
## nine-patch command each.
##
## Measured on the shipping build (graph draw bench, 2026-10-14): one
## draw_circle ≈ 8–10 µs, an outline circle ≈ 12 µs and one draw_style_box of an
## anti-aliased rounded StyleBoxFlat ≈ 17 µs (the engine re-tessellates both on
## every call), against ≈ 0.1 µs for draw_line and 1–2 µs for draw_string. A
## port dot was five circles and a card six style boxes: 60 cards cost ~10 ms a
## draw. The textures are built once per pixel size and kept.

static var _tex: Dictionary = {}


## A filled disc of radius `r` (screen px).
static func disc(ci: CanvasItem, center: Vector2, r: float, col: Color) -> void:
	if r <= 0.25 or col.a <= 0.0:
		return
	var d := maxi(2, int(round(r * 2.0)))
	var t := _disc_tex(d, 0.0)
	var s := float(d + 2)
	ci.draw_texture_rect(t, Rect2(center - Vector2(s, s) * 0.5, Vector2(s, s)), false, col)


## A ring (circle outline) of radius `r` and stroke `width`.
static func ring(ci: CanvasItem, center: Vector2, r: float, col: Color, width: float = 1.0) -> void:
	if r <= 0.25 or col.a <= 0.0:
		return
	var d := maxi(2, int(round((r + width * 0.5) * 2.0)))
	var t := _disc_tex(d, clampf(width, 0.5, float(d) * 0.5))
	var s := float(d + 2)
	ci.draw_texture_rect(t, Rect2(center - Vector2(s, s) * 0.5, Vector2(s, s)), false, col)


## A rounded rectangle, filled. `top_only` rounds only the top corners.
static func rrect(ci: CanvasItem, rect: Rect2, radius: float, col: Color, top_only: bool = false) -> void:
	if col.a <= 0.0 or rect.size.x <= 0.5 or rect.size.y <= 0.5:
		return
	var rad := clampi(int(round(radius)), 0, int(floor(minf(rect.size.x, rect.size.y) * 0.5)))
	_nine(ci, rect, _rrect_tex(rad, 0, top_only), rad, col)


## A rounded rectangle's outline, `width` px (whole pixels, inside the rect).
static func rrect_border(ci: CanvasItem, rect: Rect2, radius: float, col: Color, width: int = 1) -> void:
	if col.a <= 0.0 or width <= 0 or rect.size.x <= 0.5 or rect.size.y <= 0.5:
		return
	var rad := clampi(int(round(radius)), 0, int(floor(minf(rect.size.x, rect.size.y) * 0.5)))
	_nine(ci, rect, _rrect_tex(rad, width, false), rad, col)


## Fill + outline (what a StyleBoxFlat with a border drew). With a border the
## two colours are baked into ONE texture per colour pair (cards use a handful
## of pairs), so it is one call, not two.
static func rrect_box(ci: CanvasItem, rect: Rect2, radius: float, fill: Color,
		border: Color = Color(0, 0, 0, 0), width: int = 0, top_only: bool = false) -> void:
	if width <= 0 or border.a <= 0.0:
		rrect(ci, rect, radius, fill, top_only)
		return
	if rect.size.x <= 0.5 or rect.size.y <= 0.5:
		return
	var rad := clampi(int(round(radius)), 0, int(floor(minf(rect.size.x, rect.size.y) * 0.5)))
	_nine(ci, rect, _rrect_two_tone(rad, width, top_only, fill, border), rad, Color.WHITE)


static func _rrect_two_tone(rad: int, stroke: int, top_only: bool, fill: Color, border: Color) -> Texture2D:
	var key := "t%d|%d|%s|%d|%d" % [rad, stroke, top_only, fill.to_rgba32(), border.to_rgba32()]
	var hit: Variant = _tex.get(key)
	if hit != null:
		return hit
	if _tex.size() > 600:
		_tex.clear()
	var n := (rad + 2) * 2 + 2
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var h := float(n) * 0.5
	for y in n:
		for x in n:
			var p := Vector2(float(x) + 0.5 - h, float(y) + 0.5 - h)
			var rr := 0.0 if (top_only and p.y > 0.0) else float(rad)
			var q := Vector2(absf(p.x), absf(p.y)) - Vector2(h - rr, h - rr)
			var sdf := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - rr
			var cover := clampf(0.5 - sdf, 0.0, 1.0)
			var edge := clampf(sdf + float(stroke) + 0.5, 0.0, 1.0)
			# Border over fill, both premultiplied into straight alpha.
			var a := border.a * edge + fill.a * (1.0 - border.a * edge)
			var c := Color(0, 0, 0, 0)
			if a > 0.0:
				var r := (border.r * border.a * edge + fill.r * fill.a * (1.0 - border.a * edge)) / a
				var g := (border.g * border.a * edge + fill.g * fill.a * (1.0 - border.a * edge)) / a
				var b := (border.b * border.a * edge + fill.b * fill.a * (1.0 - border.a * edge)) / a
				c = Color(r, g, b, a * cover)
			img.set_pixel(x, y, c)
	var t := ImageTexture.create_from_image(img)
	_tex[key] = t
	return t


static func _nine(ci: CanvasItem, rect: Rect2, t: Texture2D, rad: int, col: Color) -> void:
	var m := float(rad + 2)
	var ts := t.get_size()
	RenderingServer.canvas_item_add_nine_patch(ci.get_canvas_item(), rect, Rect2(Vector2.ZERO, ts),
		t.get_rid(), Vector2(m, m), Vector2(m, m),
		RenderingServer.NINE_PATCH_STRETCH, RenderingServer.NINE_PATCH_STRETCH, true, col)


## White disc (stroke 0) or ring of diameter `d` px, one transparent pixel of
## margin each side.
static func _disc_tex(d: int, stroke: float) -> Texture2D:
	var key := "d%d|%.1f" % [d, stroke]
	var hit: Variant = _tex.get(key)
	if hit != null:
		return hit
	var n := d + 2
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := float(n) * 0.5
	var r := float(d) * 0.5
	for y in n:
		for x in n:
			var dist := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length()
			var a := clampf(r - dist + 0.5, 0.0, 1.0)
			if stroke > 0.0:
				a = minf(a, clampf(dist - (r - stroke) + 0.5, 0.0, 1.0))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var t := ImageTexture.create_from_image(img)
	_tex[key] = t
	return t


## White rounded square for a nine-patch: corner radius `rad`, a 2 px stretch
## band in the middle. `stroke` > 0 = outline only.
static func _rrect_tex(rad: int, stroke: int, top_only: bool) -> Texture2D:
	var key := "r%d|%d|%s" % [rad, stroke, top_only]
	var hit: Variant = _tex.get(key)
	if hit != null:
		return hit
	var n := (rad + 2) * 2 + 2
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var h := float(n) * 0.5
	for y in n:
		for x in n:
			var p := Vector2(float(x) + 0.5 - h, float(y) + 0.5 - h)
			var rr := 0.0 if (top_only and p.y > 0.0) else float(rad)
			var q := Vector2(absf(p.x), absf(p.y)) - Vector2(h - rr, h - rr)
			var sdf := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - rr
			var a := clampf(0.5 - sdf, 0.0, 1.0)
			if stroke > 0:
				a = minf(a, clampf(sdf + float(stroke) + 0.5, 0.0, 1.0))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var t := ImageTexture.create_from_image(img)
	_tex[key] = t
	return t
