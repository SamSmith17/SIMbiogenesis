class_name LinkageGuideCharts
extends RefCounted
## Static, UITheme-styled drawers for the Linkage Build Guide — the same
## "connect a child Control's draw signal to a static painter" idiom as
## SiteReportCharts. Each function paints onto a passed Control using its
## current `size`, so cards lay out with containers and the drawings fill
## their slot.
##
## Ports `build-guide.js`'s drill-template rows (:830-960),
## `renderBracketDiagram` (:1245) and `drawDrillTemplate` (:2280).
##
## The LAYOUT MATHS is deliberately separated from the painting: Godot forbids
## `draw_*` outside `_draw`, so `hole_x` / `stagger_slots` / `drill_hole_color`
## are pure and the selftest asserts them directly (same trick as
## `SiteReportCharts.windrose_sector_at`).

## Hole colours, ported verbatim from the web guide so a printed template and
## an on-screen one read the same.
const COL_PIVOT := Color(0.906, 0.541, 0.086)     # centre pivot — orange
const COL_END := Color(0.839, 0.286, 0.243)       # end bracket holes — red
const COL_RCP_ANCHOR := Color(0.102, 0.306, 0.627) # R# / ANCH — blue
const COL_RCP_CROSS := Color(0.353, 0.133, 0.502)  # X# crossings — purple

const BAR_H := 34.0
const LABEL_H := 22.0
const PAD_X := 26.0
## Two labels closer than this collide, so the second one drops to the far side
## of the beam rather than overprinting the first.
const LABEL_MIN_GAP := 46.0


# ---------------------------------------------------------------------------
# Pure layout maths (selftest-asserted)
# ---------------------------------------------------------------------------

static func drill_hole_color(kind: String) -> Color:
	match kind:
		"pivot":
			return COL_PIVOT
		"rcp_anchor":
			return COL_RCP_ANCHOR
		"rcp_cross":
			return COL_RCP_CROSS
	return COL_END


## Pixel centre of a hole `pos_in` inches along a beam drawn `bar_w` px wide.
static func hole_x(pos_in: float, total_in: float, bar_w: float) -> float:
	if total_in <= 0.0:
		return PAD_X
	return PAD_X + clampf(pos_in / total_in, 0.0, 1.0) * bar_w


## Which side of the beam each hole's label goes on, in order. Labels start
## above and flip below whenever the previous same-side label is too close —
## the web guide's stagger rule, made assertable.
static func stagger_slots(holes: Array, total_in: float, bar_w: float) -> Array:
	var out: Array = []
	var last_above := -INF
	var last_below := -INF
	for hole in holes:
		var x := hole_x(float((hole as Dictionary).get("pos_in", 0.0)), total_in, bar_w)
		if x - last_above >= LABEL_MIN_GAP:
			out.append("above")
			last_above = x
		elif x - last_below >= LABEL_MIN_GAP:
			out.append("below")
			last_below = x
		else:
			# Both sides crowded — keep it above and let it sit tight rather
			# than inventing a third row nobody would read.
			out.append("above")
			last_above = x
	return out


## Height a drill-template Control needs for one beam.
static func template_height() -> float:
	return BAR_H + LABEL_H * 2.0 + 18.0


# ---------------------------------------------------------------------------
# Drill template — one beam drawn to scale with dimensioned hole positions
# ---------------------------------------------------------------------------

static func draw_drill_template(c: Control, entry: Dictionary, font: Font,
		metric: bool = false) -> void:
	var w := c.size.x
	if w < 80.0:
		return
	var total := float(entry.get("length_in", 0.0))
	var holes: Array = entry.get("holes", [])
	var bar_w := w - PAD_X * 2.0
	var bar_y := LABEL_H
	c.draw_rect(Rect2(PAD_X, bar_y, bar_w, BAR_H), UITheme.C_PANEL_RAISED, true)
	c.draw_rect(Rect2(PAD_X, bar_y, bar_w, BAR_H), UITheme.C_BORDER, false, 1.0)

	# Overall length caption, centred under the bar.
	var len_txt := _len_text(total, metric)
	c.draw_string(font, Vector2(PAD_X, bar_y + BAR_H + LABEL_H - 4.0),
		len_txt, HORIZONTAL_ALIGNMENT_CENTER, bar_w, UITheme.FONT_XS, UITheme.C_TEXT_M)

	var slots := stagger_slots(holes, total, bar_w)
	var mid := bar_y + BAR_H * 0.5
	for i in holes.size():
		var hole := holes[i] as Dictionary
		var x := hole_x(float(hole.get("pos_in", 0.0)), total, bar_w)
		var col := drill_hole_color(str(hole.get("kind", "end")))
		c.draw_circle(Vector2(x, mid), 5.0, col)
		c.draw_arc(Vector2(x, mid), 5.0, 0.0, TAU, 16, UITheme.C_BG, 1.5)
		# Leader line to whichever side this label landed on.
		var above: bool = i < slots.size() and str(slots[i]) == "above"
		var ly := bar_y - 4.0 if above else bar_y + BAR_H + 4.0
		c.draw_line(Vector2(x, mid), Vector2(x, ly), Color(col, 0.55), 1.0)
		var text := "%s  %s" % [str(hole.get("name", "")),
			_len_text(float(hole.get("pos_in", 0.0)), metric)]
		var ty := bar_y - 7.0 if above else bar_y + BAR_H + LABEL_H - 1.0
		c.draw_string(font, Vector2(x - 40.0, ty), text,
			HORIZONTAL_ALIGNMENT_CENTER, 80.0, UITheme.FONT_XS, col)


# ---------------------------------------------------------------------------
# U-bracket detail — front + side elevations with leader dimensions
# ---------------------------------------------------------------------------

static func draw_bracket_diagram(c: Control, p: LinkageParams, font: Font,
		metric: bool = false) -> void:
	var w := c.size.x
	var h := c.size.y
	if w < 160.0 or h < 90.0:
		return
	var pad := 34.0
	var cell_w := (w - pad * 3.0) * 0.5
	var cell_h := h - pad * 1.6
	# One scale for both views so they read as the same object.
	var span := maxf(maxf(p.bracket_width, p.bracket_depth), p.bracket_height)
	if span <= 0.0:
		return
	var scale := minf(cell_w, cell_h) / (span * 1.35)

	_draw_bracket_front(c, p, font, Vector2(pad, pad * 0.9), scale, metric)
	_draw_bracket_side(c, p, font, Vector2(pad * 2.0 + cell_w, pad * 0.9), scale, metric)
	c.draw_string(font, Vector2(pad, h - 6.0), "FRONT",
		HORIZONTAL_ALIGNMENT_LEFT, cell_w, UITheme.FONT_XS, UITheme.C_TEXT_M)
	c.draw_string(font, Vector2(pad * 2.0 + cell_w, h - 6.0), "SIDE",
		HORIZONTAL_ALIGNMENT_LEFT, cell_w, UITheme.FONT_XS, UITheme.C_TEXT_M)


## Front elevation: the U opening, with the side-wall bolt hole.
static func _draw_bracket_front(c: Control, p: LinkageParams, font: Font,
		origin: Vector2, scale: float, metric: bool) -> void:
	var bw := p.bracket_width * scale
	var bh := p.bracket_height * scale
	var wall := maxf(p.bracket_wall_thickness * scale, 1.5)
	var r := Rect2(origin.x, origin.y, bw, bh)
	c.draw_rect(r, Color(UITheme.C_PRIMARY, 0.10), true)
	c.draw_rect(r, UITheme.C_PRIMARY, false, 1.5)
	# The U channel: hollow interior open at the top.
	var inner := Rect2(origin.x + wall, origin.y, maxf(bw - wall * 2.0, 1.0),
		maxf(bh - wall, 1.0))
	c.draw_rect(inner, UITheme.C_BG, true)
	c.draw_rect(inner, Color(UITheme.C_BORDER, 0.8), false, 1.0)
	# Bolt hole through the side wall, measured DOWN from the top.
	var hole_y := origin.y + (p.bracket_height - p.bracket_hole_distance) * scale
	var hr := maxf(p.bracket_hole_diameter * 0.5 * scale, 2.0)
	for hx in [origin.x + wall * 0.5, origin.x + bw - wall * 0.5]:
		c.draw_circle(Vector2(hx, hole_y), hr, COL_END)
	_dim_h(c, font, origin + Vector2(0.0, bh + 12.0), bw, p.bracket_width, metric)
	_dim_v(c, font, origin + Vector2(-12.0, 0.0), bh, p.bracket_height, metric)


## Side elevation: depth and the bolt-hole height above the base.
static func _draw_bracket_side(c: Control, p: LinkageParams, font: Font,
		origin: Vector2, scale: float, metric: bool) -> void:
	var bd := p.bracket_depth * scale
	var bh := p.bracket_height * scale
	var r := Rect2(origin.x, origin.y, bd, bh)
	c.draw_rect(r, Color(UITheme.C_PRIMARY, 0.10), true)
	c.draw_rect(r, UITheme.C_PRIMARY, false, 1.5)
	var hole_y := origin.y + (p.bracket_height - p.bracket_hole_distance) * scale
	var hr := maxf(p.bracket_hole_diameter * 0.5 * scale, 2.0)
	c.draw_circle(Vector2(origin.x + bd * 0.5, hole_y), hr, COL_END)
	c.draw_line(Vector2(origin.x, hole_y), Vector2(origin.x + bd, hole_y),
		Color(COL_END, 0.35), 1.0)
	_dim_h(c, font, origin + Vector2(0.0, bh + 12.0), bd, p.bracket_depth, metric)


static func _dim_h(c: Control, font: Font, at: Vector2, px: float,
		inches: float, metric: bool) -> void:
	c.draw_line(at, at + Vector2(px, 0.0), UITheme.C_TEXT_M, 1.0)
	c.draw_string(font, at + Vector2(0.0, 12.0), _len_text(inches, metric),
		HORIZONTAL_ALIGNMENT_CENTER, px, UITheme.FONT_XS, UITheme.C_TEXT_M)


static func _dim_v(c: Control, font: Font, at: Vector2, px: float,
		inches: float, metric: bool) -> void:
	c.draw_line(at, at + Vector2(0.0, px), UITheme.C_TEXT_M, 1.0)
	c.draw_string(font, at + Vector2(-34.0, px * 0.5), _len_text(inches, metric),
		HORIZONTAL_ALIGNMENT_RIGHT, 30.0, UITheme.FONT_XS, UITheme.C_TEXT_M)


# ---------------------------------------------------------------------------
# Mass breakdown — a stacked proportion bar with a legend
# ---------------------------------------------------------------------------

## Rows worth showing, in the order the guide lists them.
const MASS_ROWS := [
	["h_beams_kg", "Horizontal beams"],
	["v_beams_kg", "Vertical beams"],
	["brackets_kg", "Brackets"],
	["bolts_kg", "Bolts"],
	["washers_kg", "Washers"],
	["support_kg", "Support beams"],
	["hardware_kg", "Assembly hardware"],
	["panels_kg", "Solar panels"],
]

const MASS_COLORS := [
	Color(0.545, 0.400, 0.196),   # softwood
	Color(0.694, 0.529, 0.290),
	Color(0.427, 0.478, 0.545),   # steel
	Color(0.612, 0.639, 0.686),
	Color(0.769, 0.788, 0.816),
	Color(0.404, 0.310, 0.180),
	Color(0.133, 0.827, 0.933),   # hardware — primary
	Color(0.961, 0.620, 0.043),   # panels — amber
]


static func draw_mass_breakdown(c: Control, mass: Dictionary, font: Font,
		metric: bool = true) -> void:
	var w := c.size.x
	if w < 60.0:
		return
	var total := float(mass.get("total_kg", 0.0))
	if total <= 0.0:
		return
	var bar_h := 20.0
	var x := 0.0
	for i in MASS_ROWS.size():
		var kg := float(mass.get(str(MASS_ROWS[i][0]), 0.0))
		if kg <= 0.0:
			continue
		var seg := (kg / total) * w
		c.draw_rect(Rect2(x, 0.0, seg, bar_h), MASS_COLORS[i], true)
		x += seg
	c.draw_rect(Rect2(0.0, 0.0, w, bar_h), UITheme.C_BORDER, false, 1.0)

	# Legend, two columns, only for the buckets that carry mass.
	var y := bar_h + 14.0
	var col_w := w * 0.5
	var col := 0
	for i in MASS_ROWS.size():
		var kg := float(mass.get(str(MASS_ROWS[i][0]), 0.0))
		if kg <= 0.0:
			continue
		var lx := col * col_w
		c.draw_rect(Rect2(lx, y - 8.0, 8.0, 8.0), MASS_COLORS[i], true)
		c.draw_string(font, Vector2(lx + 13.0, y),
			"%s  %s (%.0f%%)" % [str(MASS_ROWS[i][1]),
				LinkageBom.fmt_mass(kg, metric), kg / total * 100.0],
			HORIZONTAL_ALIGNMENT_LEFT, col_w - 16.0, UITheme.FONT_XS, UITheme.C_TEXT_S)
		col += 1
		if col > 1:
			col = 0
			y += 15.0
	if col == 1:
		y += 15.0


# ---------------------------------------------------------------------------

## Inches, or mm/cm when the reader prefers metric.
static func _len_text(inches: float, metric: bool) -> String:
	if metric:
		var mm := inches * 25.4
		if mm >= 1000.0:
			return "%.2f m" % (mm / 1000.0)
		return "%.0f mm" % mm
	return "%.2f\"" % inches
