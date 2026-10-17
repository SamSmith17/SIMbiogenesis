class_name GraphCard
extends RefCounted

## ONE card anatomy for every freeform node, so a battery, a controller and a
## load read the same way: a HEADER (type icon, the node's name, a small type
## chip or an ON/OFF pill), one big HERO number (what the node is doing right
## now) with a short line under it and an optional bar, and a FOOTER status
## line. The state ring, ports and wires are drawn by the canvas around it.
##
## Before this the canvas drew cards five different ways: a battery had no
## name, a panel's name was 9 px, a controller was "CONTROLLER" over a large
## empty box (its only live readout appeared when it clipped), a load was
## "LOAD" in tiny text, and SOC text sat on the fill edge.
##
## `spec` (built by GraphCardSpecs.for_item):
##   accent: Color, icon: String, title: String, chip: String,
##   pill: {text, color} (replaces the chip, e.g. ON / OFF),
##   hero: String, hero_color: Color, sub: String,
##   bar: {frac, color, ghost: frac (a second, faded share: power offered but
##        not taken), ghost_color},
##   fill: {frac, color} (the whole body fills from the bottom — storage),
##   footer: String, footer_color: Color, sub_color: Color,
##   alert: {title, text, action} (destroyed: red hero + an action button),
##   media: String (non-empty = reserve a picture zone above the hero; the
##          canvas draws the thumbnail / miniature / panel grid into it),
##   dim: bool (off), selected: bool.
## draw() returns {action_rect: Rect2} when it drew the alert's button and
## {media_rect: Rect2} when it reserved a picture zone.
## Round tanks use draw_hub() — the same parts (name, hero, unit, flow line,
## level fill, selection) laid out in a circle, so hub ports stay on its rim.

const LOD_FULL := 0
const LOD_COMPACT := 1
const LOD_GLYPH := 2

static var _box_cache: Dictionary = {}


static func lod_for(rect: Rect2, z: float) -> int:
	if rect.size.y < 30.0 or rect.size.x < 44.0:
		return LOD_GLYPH
	if z < 0.45 or rect.size.y < 64.0:
		return LOD_COMPACT
	return LOD_FULL


## Ports sit ON the top and bottom edges; header and footer text keeps clear
## of the port band (the first cards drew port dots over the title).
static func port_inset(z: float) -> float:
	return clampf(6.0 * z, 3.0, 9.0)


static func layout(rect: Rect2, z: float) -> Dictionary:
	var lod := lod_for(rect, z)
	var inset := port_inset(z)
	var head_h := clampf(22.0 * z, 14.0, 34.0) + inset
	var foot_h := (clampf(18.0 * z, 12.0, 28.0) + inset) if lod == LOD_FULL else 0.0
	var pad := clampf(8.0 * z, 4.0, 14.0)
	var header := Rect2(rect.position, Vector2(rect.size.x, head_h))
	var footer := Rect2(Vector2(rect.position.x, rect.end.y - foot_h), Vector2(rect.size.x, foot_h))
	var body := Rect2(Vector2(rect.position.x + pad, rect.position.y + head_h),
		Vector2(maxf(1.0, rect.size.x - pad * 2.0), maxf(1.0, rect.size.y - head_h - foot_h)))
	return {"lod": lod, "header": header, "body": body, "footer": footer, "pad": pad}


## The body split for a card with a picture: {media: Rect2, hero: Rect2}, or {}
## when there is no picture or no room for one (the hero then keeps the body).
static func media_split(body: Rect2, z: float, spec: Dictionary, lod: int) -> Dictionary:
	if str(spec.get("media", "")).is_empty() or lod != LOD_FULL:
		return {}
	var has_hero := not str(spec.get("hero", "")).is_empty()
	var hero_zone := clampf(body.size.y * 0.42, 22.0 * z, 74.0 * z) if has_hero else 0.0
	var gap := 3.0 * z
	var media_h := body.size.y - hero_zone - gap * 2.0
	if media_h < 22.0:
		return {}
	var media := Rect2(Vector2(body.position.x, body.position.y + gap), Vector2(body.size.x, media_h))
	var hero := Rect2(Vector2(body.position.x, media.end.y + gap), Vector2(body.size.x, maxf(1.0, hero_zone))) \
		if has_hero else Rect2(Vector2(body.position.x, body.end.y), Vector2(body.size.x, 1.0))
	return {"media": media, "hero": hero}


static func draw(ci: CanvasItem, rect: Rect2, z: float, spec: Dictionary) -> Dictionary:
	var out := {}
	var lay := layout(rect, z)
	var lod: int = lay["lod"]
	var accent: Color = spec.get("accent", GraphTheme.TEXT_DIM)
	var a := 0.55 if bool(spec.get("dim", false)) else 1.0
	var radius := int(clampf(9.0 * z, 4.0, 14.0))
	# Shadow + body.
	_sb(ci, Rect2(rect.position + Vector2(0, 3.0 * z), rect.size), GraphTheme.CARD_SHADOW, radius)
	_sb(ci, rect, _fade(GraphTheme.CARD_BG, a), radius, _fade(GraphTheme.CARD_BORDER, a), 1)
	if lod == LOD_GLYPH:
		_draw_icon(ci, str(spec.get("icon", "box")), rect.get_center(), minf(rect.size.x, rect.size.y) * 0.6, _fade(accent, a))
		_draw_selection(ci, rect, radius, z, spec)
		return out
	var header: Rect2 = lay["header"]
	var body: Rect2 = lay["body"]
	var footer: Rect2 = lay["footer"]
	var pad: float = lay["pad"]
	# Storage fill rises from the bottom of the WHOLE body area (behind text).
	var fill: Dictionary = spec.get("fill", {})
	if not fill.is_empty():
		var inner := Rect2(Vector2(rect.position.x + 2.0, header.end.y),
			Vector2(rect.size.x - 4.0, rect.end.y - header.end.y - 2.0))
		var fh := inner.size.y * clampf(float(fill.get("frac", 0.0)), 0.0, 1.0)
		if fh > 1.0:
			var fc: Color = fill.get("color", GraphTheme.OK)
			_sb(ci, Rect2(Vector2(inner.position.x, inner.end.y - fh), Vector2(inner.size.x, fh)), Color(fc.r, fc.g, fc.b, 0.22 * a), maxi(2, radius - 2))
			ci.draw_line(Vector2(inner.position.x + 2.0, inner.end.y - fh),
				Vector2(inner.end.x - 2.0, inner.end.y - fh), Color(fc.r, fc.g, fc.b, 0.85 * a),
				maxf(1.0, 1.5 * z))
	# Header: band, accent strip, icon, title, chip / pill.
	_sb(ci, header, _fade(GraphTheme.CARD_HEADER, a), radius, Color(0, 0, 0, 0), 0, true)
	ci.draw_rect(Rect2(header.position + Vector2(radius * 0.6, 0.0), Vector2(header.size.x - radius * 1.2, maxf(2.0, 2.5 * z))),
		_fade(accent, a))
	var inset := port_inset(z)
	# Text row of the header: below the port band.
	var hrow := Rect2(header.position + Vector2(0.0, inset), Vector2(header.size.x, header.size.y - inset))
	var hfs := clampi(int(round(hrow.size.y * 0.5)), 8, 17)
	var ix := header.position.x + pad
	var icon_px := float(hfs) + 2.0
	_draw_icon(ci, str(spec.get("icon", "box")), Vector2(ix + icon_px * 0.5, hrow.get_center().y + 1.0),
		icon_px, _fade(accent, a))
	var right_w := 0.0
	var pill: Dictionary = spec.get("pill", {})
	var chip := str(spec.get("chip", ""))
	var small_fs := maxi(7, hfs - 3)
	var semibold := UITheme.font("semibold")
	if not pill.is_empty():
		right_w = _draw_pill(ci, str(pill.get("text", "")), pill.get("color", GraphTheme.TEXT_DIM),
			Vector2(header.end.x - pad, hrow.get_center().y), small_fs, a)
	elif not chip.is_empty() and lod == LOD_FULL and header.size.x > 120.0:
		var cw := semibold.get_string_size(chip, HORIZONTAL_ALIGNMENT_LEFT, -1, small_fs).x
		ci.draw_string(semibold, Vector2(header.end.x - pad - cw, hrow.get_center().y + small_fs * 0.36),
			chip, HORIZONTAL_ALIGNMENT_LEFT, -1, small_fs, _fade(GraphTheme.TEXT_MUTED, a))
		right_w = cw + 6.0
	var tx := ix + icon_px + 5.0
	var tw := header.end.x - pad - right_w - tx
	var title := UiText.fit(semibold, str(spec.get("title", "")), hfs, tw, "graph card title")
	ci.draw_string(semibold, Vector2(tx, hrow.get_center().y + hfs * 0.36), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, hfs, _fade(GraphTheme.TEXT, a))
	# Alert (destroyed): replaces the hero.
	var alert: Dictionary = spec.get("alert", {})
	var num := UITheme.font("semibold", true)
	if not alert.is_empty():
		# Centred in the body: the state overlay's reason chip sits on the
		# card's top edge, and the alert title used to collide with it.
		var afs := clampi(int(round(minf(body.size.y * 0.2, body.size.x * 0.16))), 9, 24)
		var rfs := maxi(8, int(afs * 0.6))
		var cy := body.position.y + body.size.y * 0.42
		var at := UiText.fit(semibold, str(alert.get("title", "")), afs, body.size.x, "graph card alert")
		var aw := semibold.get_string_size(at, HORIZONTAL_ALIGNMENT_LEFT, -1, afs).x
		ci.draw_string(semibold, Vector2(body.get_center().x - aw * 0.5, cy), at,
			HORIZONTAL_ALIGNMENT_LEFT, -1, afs, GraphTheme.ERROR)
		var rt := UiText.fit(UITheme.font(), str(alert.get("text", "")), rfs, body.size.x, "graph card alert")
		var rw := UITheme.font().get_string_size(rt, HORIZONTAL_ALIGNMENT_LEFT, -1, rfs).x
		ci.draw_string(UITheme.font(), Vector2(body.get_center().x - rw * 0.5, cy + rfs + 5.0 * z), rt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, rfs, GraphTheme.TEXT_DIM)
		var act := str(alert.get("action", ""))
		if not act.is_empty():
			var bh := clampf(22.0 * z, 16.0, 30.0)
			var bw := minf(body.size.x, clampf(88.0 * z, 60.0, 130.0))
			var br := Rect2(Vector2(rect.get_center().x - bw * 0.5, rect.end.y - bh - inset - pad * 0.6), Vector2(bw, bh))
			_sb(ci, br, Color(0.12, 0.40, 0.22, 0.98), int(bh * 0.3), Color(0.35, 0.85, 0.45, 0.95), 1)
			var bfs := clampi(int(bh * 0.48), 8, 15)
			var bt := semibold.get_string_size(act, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
			ci.draw_string(semibold, Vector2(br.get_center().x - bt * 0.5, br.get_center().y + bfs * 0.36),
				act, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, Color(0.92, 1.0, 0.94))
			out["action_rect"] = br
		_draw_selection(ci, rect, radius, z, spec)
		return out
	# Picture zone (GLB thumbnail, group miniature, panel grid) above the hero.
	var split := media_split(body, z, spec, lod)
	if split.has("media"):
		out["media_rect"] = split["media"]
		body = split["hero"]
	# Hero number (+ the line under it).
	var bar: Dictionary = spec.get("bar", {})
	var bar_h := clampf(6.0 * z, 3.0, 9.0) if not bar.is_empty() and lod == LOD_FULL else 0.0
	var sub := str(spec.get("sub", "")) if lod == LOD_FULL else ""
	var avail_h := body.size.y - bar_h - (4.0 * z if bar_h > 0.0 else 0.0)
	var hero_fs := clampi(int(round(minf(avail_h * (0.46 if not sub.is_empty() else 0.62), body.size.x * 0.26))), 9, 44)
	var sub_fs := clampi(int(round(hero_fs * 0.42)), 8, 16)
	var block_h := float(hero_fs) + (float(sub_fs) + 3.0 * z if not sub.is_empty() else 0.0)
	var top := body.position.y + maxf(2.0, (avail_h - block_h) * 0.5)
	var hero := str(spec.get("hero", ""))
	var hero_col: Color = spec.get("hero_color", GraphTheme.TEXT)
	var hw := num.get_string_size(hero, HORIZONTAL_ALIGNMENT_LEFT, -1, hero_fs).x
	if hw > body.size.x:
		# Shrink the number to fit before ever cutting it ("1.36…" hid the
		# unit — the one thing a number on a small card must keep).
		hero_fs = maxi(8, int(floor(float(hero_fs) * body.size.x / hw)))
		hw = num.get_string_size(hero, HORIZONTAL_ALIGNMENT_LEFT, -1, hero_fs).x
	if hw > body.size.x:
		hero = UiText.fit(num, hero, hero_fs, body.size.x, "graph card hero")
		hw = num.get_string_size(hero, HORIZONTAL_ALIGNMENT_LEFT, -1, hero_fs).x
	ci.draw_string(num, Vector2(body.get_center().x - hw * 0.5, top + hero_fs * 0.86), hero,
		HORIZONTAL_ALIGNMENT_LEFT, -1, hero_fs, _fade(hero_col, a))
	if not sub.is_empty():
		var reg := UITheme.font("regular", true)
		var st := UiText.fit(reg, sub, sub_fs, body.size.x, "graph card sub")
		var sw := reg.get_string_size(st, HORIZONTAL_ALIGNMENT_LEFT, -1, sub_fs).x
		ci.draw_string(reg, Vector2(body.get_center().x - sw * 0.5, top + hero_fs + 2.0 * z + sub_fs * 0.86), st,
			HORIZONTAL_ALIGNMENT_LEFT, -1, sub_fs, _fade(spec.get("sub_color", GraphTheme.TEXT_DIM), a))
	if bar_h > 0.0:
		var br2 := Rect2(Vector2(body.position.x, body.end.y - bar_h - 2.0 * z), Vector2(body.size.x, bar_h))
		_sb(ci, br2, GraphTheme.CARD_TRACK, int(bar_h * 0.5))
		var frac := clampf(float(bar.get("frac", 0.0)), 0.0, 1.0)
		var ghost := clampf(float(bar.get("ghost", 0.0)), 0.0, 1.0)
		if ghost > frac:
			var gc: Color = bar.get("ghost_color", GraphTheme.WARN)
			_sb(ci, Rect2(br2.position, Vector2(br2.size.x * ghost, bar_h)), Color(gc.r, gc.g, gc.b, 0.35 * a), int(bar_h * 0.5))
		if frac > 0.0:
			var bc: Color = bar.get("color", accent)
			_sb(ci, Rect2(br2.position, Vector2(maxf(bar_h, br2.size.x * frac), bar_h)), _fade(bc, a), int(bar_h * 0.5))
	# Footer status line.
	var foot := str(spec.get("footer", ""))
	if lod == LOD_FULL and not foot.is_empty() and footer.size.y > 0.0:
		var frow := Rect2(footer.position, Vector2(footer.size.x, footer.size.y - inset))
		var ffs := clampi(int(round(frow.size.y * 0.58)), 7, 14)
		var reg2 := UITheme.font("regular", true)
		var ft := UiText.fit(reg2, foot, ffs, footer.size.x - pad * 2.0, "graph card footer")
		ci.draw_line(Vector2(footer.position.x + pad, footer.position.y), Vector2(footer.end.x - pad, footer.position.y),
			Color(1, 1, 1, 0.06), 1.0)
		ci.draw_string(reg2, Vector2(footer.position.x + pad, frow.get_center().y + ffs * 0.38), ft,
			HORIZONTAL_ALIGNMENT_LEFT, -1, ffs, _fade(spec.get("footer_color", GraphTheme.TEXT_DIM), a))
	_draw_selection(ci, rect, radius, z, spec)
	return out


## A round tank (resource hub). Ports sit on the circle (GraphHubPorts), so the
## card is the circle: the name in one or two balanced lines, the hero quantity,
## its unit, the flow line, a level fill rising from the bottom. A name that
## cannot fit inside is drawn as a caption beside the circle (ports are on top
## and bottom, the sides are free). Returns {}.
static func draw_hub(ci: CanvasItem, rect: Rect2, z: float, spec: Dictionary) -> Dictionary:
	var c := GraphHubPorts.circle_center(rect.position, rect.size)
	var r := GraphHubPorts.circle_radius(rect.size)
	var accent: Color = spec.get("accent", GraphTheme.TEXT_DIM)
	var a := 0.55 if bool(spec.get("dim", false)) else 1.0
	GraphFastDraw.disc(ci, c + Vector2(0.0, 3.0 * z), r, GraphTheme.CARD_SHADOW)
	GraphFastDraw.disc(ci, c, r, _fade(GraphTheme.CARD_BG, a))
	GraphFastDraw.ring(ci, c, r, Color(accent.r, accent.g, accent.b, 0.85 * a), maxf(1.5, 2.0 * z))
	var inner_r := maxf(4.0, r - maxf(3.0, 4.0 * z))
	GraphFastDraw.disc(ci, c, inner_r, Color(0.04, 0.07, 0.12, 0.98 * a))
	var fill: Dictionary = spec.get("fill", {})
	if not fill.is_empty():
		fill_circle_level(ci, c, inner_r - 1.0, float(fill.get("frac", 0.0)),
			_fade(fill.get("color", accent), a))
	if r * 2.0 < 30.0:
		_draw_icon(ci, str(spec.get("icon", "droplet")), c, r * 1.1, _fade(Color(1, 1, 1, 0.9), a))
		_draw_hub_selection(ci, c, r, z, spec)
		return {}
	var semibold := UITheme.font("semibold")
	var num := UITheme.font("semibold", true)
	var reg := UITheme.font("regular", true)
	var hero := str(spec.get("hero", ""))
	var sub := str(spec.get("sub", ""))
	var foot := str(spec.get("footer", ""))
	var hero_fs := maxi(10, int(round(22.0 * z)))
	var name_fs := maxi(8, int(round(11.0 * z)))
	var sub_fs := maxi(8, int(round(10.0 * z)))
	var foot_fs := maxi(8, int(round(10.0 * z)))
	var sp := 2.0 * z
	var lsp := 4.0 * z
	var line_w := inner_r * 1.7
	var name := str(spec.get("title", ""))
	var fit := hub_name_lines(semibold, name, name_fs, line_w)
	var lines: PackedStringArray = fit["lines"]
	name_fs = int(fit["size"])
	var inside := bool(fit["fits"])
	if inside:
		# Width alone is not enough: the top lines sit where the circle is
		# narrower. Test each line against the chord at its own height.
		var stack_h := float(name_fs * lines.size()) + sp * float(lines.size() - 1) + lsp \
			+ hero_fs + sp + sub_fs + ((lsp + foot_fs) if not foot.is_empty() else 0.0)
		var y := c.y - stack_h * 0.5
		for nl in lines:
			if semibold.get_string_size(nl, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fs).x > _chord(c, inner_r, y, name_fs):
				inside = false
				break
			y += name_fs + sp
	var plate := Color(0.03, 0.05, 0.09, 0.85)
	if not inside:
		var cap_fs := maxi(9, int(round(11.0 * z)))
		var cap_pos := Vector2(c.x + r + 5.0 * z, c.y + semibold.get_ascent(cap_fs) * 0.5 - 1.0)
		ci.draw_string_outline(semibold, cap_pos, name, HORIZONTAL_ALIGNMENT_LEFT, -1, cap_fs, 3, plate)
		ci.draw_string(semibold, cap_pos, name, HORIZONTAL_ALIGNMENT_LEFT, -1, cap_fs,
			_fade(Color(0.86, 0.88, 0.92, 0.92), a))
		lines = PackedStringArray()
	var name_h := float(name_fs * lines.size()) + sp * float(maxi(lines.size() - 1, 0))
	var total_h := (name_h + lsp if not lines.is_empty() else 0.0) + hero_fs \
		+ ((sp + sub_fs) if not sub.is_empty() else 0.0) + ((lsp + foot_fs) if not foot.is_empty() else 0.0)
	var y := c.y - total_h * 0.5
	for nl in lines:
		var line := UiText.fit(semibold, nl, name_fs, minf(line_w, _chord(c, inner_r, y, name_fs)), "resource_hub")
		_hub_text(ci, semibold, line, name_fs, Vector2(c.x, y), _fade(Color(0.92, 0.93, 0.96), a), plate)
		y += name_fs + sp
	if not lines.is_empty():
		y += lsp - sp
	hero = UiText.fit(num, hero, hero_fs, line_w, "resource_hub")
	_hub_text(ci, num, hero, hero_fs, Vector2(c.x, y), _fade(spec.get("hero_color", Color.WHITE), a), plate)
	y += hero_fs
	if not sub.is_empty():
		y += sp
		_hub_text(ci, reg, UiText.fit(reg, sub, sub_fs, line_w, "resource_hub"), sub_fs, Vector2(c.x, y),
			_fade(Color(0.85, 0.86, 0.90, 0.92), a), plate)
		y += sub_fs
	if not foot.is_empty():
		y += lsp
		_hub_text(ci, reg, UiText.fit(reg, foot, foot_fs, line_w, "resource_hub"), foot_fs, Vector2(c.x, y),
			_fade(spec.get("footer_color", GraphTheme.TEXT_DIM), a), plate)
	_draw_hub_selection(ci, c, r, z, spec)
	return {}


## Width of the circle's chord across a text line whose top is `y`.
static func _chord(c: Vector2, r: float, y: float, fs: int) -> float:
	var dy := maxf(absf(y - c.y), absf(y + fs - c.y))
	return 2.0 * sqrt(maxf(r * r - dy * dy, 0.0)) * 0.94


## Centred text whose TOP is at `top`, on a thin dark outline so it reads over
## the level fill (ONE outline pass — the old hub drew each line twice in its
## own colour, which thickened it without adding contrast).
static func _hub_text(ci: CanvasItem, f: Font, text: String, fs: int, top: Vector2, col: Color, plate: Color) -> void:
	if text.is_empty():
		return
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := Vector2(top.x - w * 0.5, top.y + f.get_ascent(fs))
	ci.draw_string_outline(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(2, int(round(fs * 0.18))), plate)
	ci.draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


static func _draw_hub_selection(ci: CanvasItem, c: Vector2, r: float, z: float, spec: Dictionary) -> void:
	if not bool(spec.get("selected", false)):
		return
	var s := GraphTheme.SELECTED
	GraphFastDraw.ring(ci, c, r + maxf(2.0, 3.0 * z), Color(s.r, s.g, s.b, 0.95), 2.0)


## A hub's name as 1–2 lines that fit `width`: one line if it fits, else the
## word break that balances two lines best, shrinking the font by up to 20 %.
## Returns {lines: PackedStringArray, size: int, fits: bool}.
static func hub_name_lines(fnt: Font, name: String, size: int, width: float) -> Dictionary:
	var min_size := maxi(7, int(floor(float(size) * 0.8)))
	var words := name.split(" ", false)
	var fs := size
	while fs >= min_size:
		if fnt.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
			return {"lines": PackedStringArray([name]), "size": fs, "fits": true}
		var best := PackedStringArray()
		var best_w := INF
		for i in range(1, words.size()):
			var a := " ".join(words.slice(0, i))
			var b := " ".join(words.slice(i))
			var w := maxf(fnt.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x,
					fnt.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
			if w < best_w:
				best_w = w
				best = PackedStringArray([a, b])
		if not best.is_empty() and best_w <= width:
			return {"lines": best, "size": fs, "fits": true}
		fs -= 1
	if words.size() > 1:
		@warning_ignore("integer_division")
		var half := words.size() / 2
		return {"lines": PackedStringArray([" ".join(words.slice(0, half)),
				" ".join(words.slice(half))]), "size": min_size, "fits": false}
	return {"lines": PackedStringArray([name]), "size": min_size, "fits": false}


## Fill the lower `level` of a circle (a tank's level), clipped to the chord.
static func fill_circle_level(ci: CanvasItem, c: Vector2, r: float, level: float, col: Color) -> void:
	level = clampf(level, 0.0, 1.0)
	if level >= 0.999:
		GraphFastDraw.disc(ci, c, r, col)
		return
	if level <= 0.001 or r < 2.0:
		return
	var water_y := c.y + r - 2.0 * r * level
	var dy := water_y - c.y
	var half_chord := sqrt(maxf(0.0, r * r - dy * dy))
	var pts := PackedVector2Array([Vector2(c.x - half_chord, water_y), Vector2(c.x + half_chord, water_y)])
	var a0 := atan2(dy, half_chord)
	var a1 := PI - a0
	for i in range(1, 24):
		var ang := lerpf(a0, a1, float(i) / 24.0)
		pts.append(c + Vector2(cos(ang), sin(ang)) * r)
	ci.draw_colored_polygon(pts, col)


static func _draw_selection(ci: CanvasItem, rect: Rect2, radius: int, z: float, spec: Dictionary) -> void:
	if not bool(spec.get("selected", false)):
		return
	var c := GraphTheme.SELECTED
	_sb(ci, rect.grow(maxf(2.0, 3.0 * z)), Color(c.r, c.g, c.b, 0.10), radius + 3, Color(c.r, c.g, c.b, 0.95), 2)


## Right-aligned pill ending at `right_mid`. Returns the width used.
static func _draw_pill(ci: CanvasItem, text: String, col: Color, right_mid: Vector2, fs: int, a: float) -> float:
	var f := UITheme.font("semibold")
	var tw := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var h := float(fs) + 6.0
	var r := Rect2(Vector2(right_mid.x - tw - 12.0, right_mid.y - h * 0.5), Vector2(tw + 12.0, h))
	_sb(ci, r, Color(col.r, col.g, col.b, 0.18 * a), int(h * 0.5), Color(col.r, col.g, col.b, 0.75 * a), 1)
	ci.draw_string(f, Vector2(r.position.x + 6.0, right_mid.y + fs * 0.36), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, _fade(col, a))
	return r.size.x + 6.0


static func _draw_icon(ci: CanvasItem, name: String, center: Vector2, px: float, col: Color) -> void:
	var ipx := clampi(int(round(px)), 8, 64)
	var tex := UiIcons.icon(name, ipx)
	if tex == null:
		return
	ci.draw_texture_rect(tex, Rect2(center - Vector2(ipx, ipx) * 0.5, Vector2(ipx, ipx)), false, col)


static func _fade(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * a)


## A rounded box (fill + optional border) through GraphFastDraw — the same
## arguments _box takes. A StyleBoxFlat draw costs ~17 µs; this is two
## texture calls.
static func _sb(ci: CanvasItem, rect: Rect2, bg: Color, radius: int, border: Color = Color(0, 0, 0, 0),
		bw: int = 0, top_only: bool = false) -> void:
	GraphFastDraw.rrect_box(ci, rect, float(radius), bg, border, bw, top_only)


## Cached rounded StyleBoxFlat. `top_only` rounds only the top corners (header).
static func _box(bg: Color, radius: int, border: Color = Color(0, 0, 0, 0), bw: int = 0,
		top_only: bool = false) -> StyleBoxFlat:
	# A hashed key: the formatted-string key (two to_html calls and a format
	# per box, six boxes a card) was measurable at 60 cards.
	var key := hash([bg, radius, border, bw, top_only])
	var sb: StyleBoxFlat = _box_cache.get(key)
	if sb != null:
		return sb
	if _box_cache.size() > 512:
		_box_cache.clear()
	sb = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = 0 if top_only else radius
	sb.corner_radius_bottom_right = 0 if top_only else radius
	sb.corner_detail = 6
	sb.anti_aliasing = true
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	_box_cache[key] = sb
	return sb
