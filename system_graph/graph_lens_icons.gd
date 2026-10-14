class_name GraphLensIcons
extends RefCounted

## Small procedural icons for the graph's lens switcher (Freeform / Site Plan /
## Elevation / Globe). Drawn in code rather than font glyphs: the fallback font
## does not reliably carry geometric symbols like ◐ or ◍, and a tofu box in the
## main toolbar reads as broken. White on transparent — the Button tints them
## through its icon_*_color theme colours. Rasterised at SS× and box-filtered
## down, so the strokes are antialiased. Cached per (kind, size).

const SS := 4
static var _cache: Dictionary = {}


static func icon(kind: String, px: int = 16) -> Texture2D:
	var key := "%s|%d" % [kind, px]
	if _cache.has(key):
		return _cache[key] as Texture2D
	var n := px * SS
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var s := float(n) / 16.0  # author in a 16-unit box
	match kind:
		"freeform":
			# Three nodes and their wires.
			_line(img, Vector2(4, 5) * s, Vector2(12, 5) * s, 1.3 * s)
			_line(img, Vector2(4, 5) * s, Vector2(8, 12) * s, 1.3 * s)
			_line(img, Vector2(12, 5) * s, Vector2(8, 12) * s, 1.3 * s)
			_disc(img, Vector2(4, 5) * s, 2.6 * s)
			_disc(img, Vector2(12, 5) * s, 2.6 * s)
			_disc(img, Vector2(8, 12) * s, 2.6 * s)
		"site":
			# The SoI from above: a ring, a parcel and a path.
			_ring(img, Vector2(8, 8) * s, 6.4 * s, 1.3 * s)
			_rect(img, Rect2(Vector2(5.0, 5.2) * s, Vector2(3.4, 2.8) * s))
			_line(img, Vector2(8.4, 9.6) * s, Vector2(12.0, 11.0) * s, 1.1 * s)
			_disc(img, Vector2(10.5, 6.2) * s, 1.0 * s)
		"elevation":
			# A side-on cut: ring with the lower half solid under a ridge line.
			_ring(img, Vector2(8, 8) * s, 6.4 * s, 1.3 * s)
			_ground(img, Vector2(8, 8) * s, 6.4 * s, s)
		"globe":
			# A sphere with an equator and a meridian.
			_ring(img, Vector2(8, 8) * s, 6.4 * s, 1.3 * s)
			_ellipse(img, Vector2(8, 8) * s, Vector2(6.4, 2.3) * s, 1.0 * s)
			_ellipse(img, Vector2(8, 8) * s, Vector2(2.6, 6.4) * s, 1.0 * s)
		_:
			_disc(img, Vector2(8, 8) * s, 4.0 * s)
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


static func _plot(img: Image, x: int, y: int, a: float) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	var c := img.get_pixel(x, y)
	img.set_pixel(x, y, Color(1, 1, 1, maxf(c.a, clampf(a, 0.0, 1.0))))


static func _disc(img: Image, c: Vector2, r: float) -> void:
	for y in range(int(c.y - r) - 1, int(c.y + r) + 2):
		for x in range(int(c.x - r) - 1, int(c.x + r) + 2):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			_plot(img, x, y, r - d + 0.5)


static func _ring(img: Image, c: Vector2, r: float, w: float) -> void:
	for y in range(int(c.y - r - w) - 1, int(c.y + r + w) + 2):
		for x in range(int(c.x - r - w) - 1, int(c.x + r + w) + 2):
			var d := absf(Vector2(x + 0.5, y + 0.5).distance_to(c) - r)
			_plot(img, x, y, w * 0.5 - d + 0.5)


static func _ellipse(img: Image, c: Vector2, rad: Vector2, w: float) -> void:
	var steps := 160
	var prev := c + Vector2(rad.x, 0)
	for i in range(1, steps + 1):
		var t := TAU * float(i) / float(steps)
		var p := c + Vector2(cos(t) * rad.x, sin(t) * rad.y)
		_line(img, prev, p, w)
		prev = p


static func _line(img: Image, a: Vector2, b: Vector2, w: float) -> void:
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(w, w)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(w, w)
	var ab := b - a
	var len2 := maxf(ab.length_squared(), 1e-6)
	for y in range(int(lo.y) - 1, int(hi.y) + 2):
		for x in range(int(lo.x) - 1, int(hi.x) + 2):
			var p := Vector2(x + 0.5, y + 0.5)
			var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			_plot(img, x, y, w * 0.5 - d + 0.5)


static func _rect(img: Image, r: Rect2) -> void:
	for y in range(int(r.position.y), int(r.end.y)):
		for x in range(int(r.position.x), int(r.end.x)):
			_plot(img, x, y, 1.0)


## Fill the circle below a gentle ridge line (the section's ground).
static func _ground(img: Image, c: Vector2, r: float, s: float) -> void:
	for y in range(int(c.y - r) - 1, int(c.y + r) + 2):
		for x in range(int(c.x - r) - 1, int(c.x + r) + 2):
			var p := Vector2(x + 0.5, y + 0.5)
			if p.distance_to(c) > r:
				continue
			var u := (p.x - (c.x - r)) / (2.0 * r)
			var ridge := c.y + (0.6 - 1.6 * sin(u * PI) + 0.5 * sin(u * TAU * 1.5)) * s
			if p.y >= ridge:
				_plot(img, x, y, 0.85)
