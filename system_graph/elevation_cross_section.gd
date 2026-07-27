class_name ElevationCrossSection
extends RefCounted

## Shared Elevation / Siphon Lab cross-section painters (SiteReportCharts pattern).
## Callers own DEM bake + metre→screen projection; this module only draws.

const C_TERRAIN_FILL := Color(0.18, 0.36, 0.24, 0.55)
const C_TERRAIN_LINE := Color(0.50, 0.92, 0.62, 0.95)
const C_WATER := Color(0.22, 0.52, 0.92, 0.55)
const C_WATER_LINE := Color(0.45, 0.85, 1.0, 0.95)
const C_START := Color(0.35, 0.95, 0.55, 0.95)
const C_BREAK := Color(0.95, 0.45, 0.35, 0.95)
const C_MODULE := Color(0.55, 0.58, 0.62, 0.9)
const C_CULVERT := Color(0.85, 0.65, 0.25, 0.9)


## Fill under a projected DEM polyline down to panel bottom corners.
static func draw_terrain(c: CanvasItem, line_pts: PackedVector2Array,
		panel_bl: Vector2, panel_br: Vector2, stroke_w: float = 2.0) -> void:
	if line_pts.size() < 2:
		return
	var fill := PackedVector2Array()
	for p in line_pts:
		fill.append(p)
	fill.append(panel_br)
	fill.append(panel_bl)
	if fill.size() >= 3:
		c.draw_colored_polygon(fill, C_TERRAIN_FILL)
	c.draw_polyline(line_pts, C_TERRAIN_LINE, stroke_w, true)


## Solid pond band (rectangle) floor→level — legacy / fallback when no DEM.
static func draw_pond_band(c: CanvasItem, left: Vector2, right: Vector2,
		bot_l: Vector2, bot_r: Vector2, stroke_w: float = 2.0) -> void:
	c.draw_colored_polygon(PackedVector2Array([left, right, bot_r, bot_l]), C_WATER)
	c.draw_line(left, right, C_WATER_LINE, stroke_w, true)


## Water polygon clipped to a DEM polyline: fills only where ground is below
## `level_elev_m`. Callers pass already-projected DEM samples + the waterline
## screen-Y (no Callable — typed float lambdas trip Godot's float ctor error).
## Matches the simplified elevation slope instead of a blue rectangle.
static func draw_pond_filled(c: CanvasItem, dem_screen: PackedVector2Array,
		dem_elev: PackedFloat32Array, level_elev_m: float,
		level_screen_y: float, stroke_w: float = 2.0) -> void:
	var n := mini(dem_screen.size(), dem_elev.size())
	if n < 2 or is_nan(level_elev_m):
		return
	# Walk DEM; emit water surface + bed only across submerged spans.
	var surface := PackedVector2Array()
	var bed := PackedVector2Array()
	var in_water := false
	for i in range(n):
		var g := dem_elev[i]
		var pt: Vector2 = dem_screen[i]
		var submerged := g < level_elev_m - 1e-4
		if submerged:
			if not in_water:
				# Enter water: optional bank intersection for a clean shoreline.
				if i > 0:
					var g0 := dem_elev[i - 1]
					if g0 >= level_elev_m:
						var t := (level_elev_m - g0) / maxf(g - g0, 1e-6)
						var prev: Vector2 = dem_screen[i - 1]
						var ax := prev.lerp(pt, clampf(t, 0.0, 1.0))
						var shore := Vector2(ax.x, level_screen_y)
						surface.append(shore)
						bed.append(shore)
				in_water = true
			surface.append(Vector2(pt.x, level_screen_y))
			bed.append(pt)
		elif in_water:
			# Exit: intersect uphill bank.
			var g0 := dem_elev[i - 1]
			if g0 < level_elev_m:
				var t2 := (level_elev_m - g0) / maxf(g - g0, 1e-6)
				var prev2: Vector2 = dem_screen[i - 1]
				var ax2 := prev2.lerp(pt, clampf(t2, 0.0, 1.0))
				var shore2 := Vector2(ax2.x, level_screen_y)
				surface.append(shore2)
				bed.append(shore2)
			in_water = false
			_emit_pond_poly(c, surface, bed, stroke_w)
			surface = PackedVector2Array()
			bed = PackedVector2Array()
	if in_water and surface.size() >= 2:
		_emit_pond_poly(c, surface, bed, stroke_w)


static func _emit_pond_poly(c: CanvasItem, surface: PackedVector2Array,
		bed: PackedVector2Array, stroke_w: float) -> void:
	if surface.size() < 2 or bed.size() < 2:
		return
	var poly := PackedVector2Array()
	for p in surface:
		poly.append(p)
	for i in range(bed.size() - 1, -1, -1):
		poly.append(bed[i])
	if poly.size() >= 3:
		c.draw_colored_polygon(poly, C_WATER)
	if surface.size() >= 2:
		c.draw_polyline(surface, C_WATER_LINE, stroke_w, true)


## Start / break / module elevation ticks with labels.
## `label_px` caps font size (Siphon Lab CT uses smaller labels so they don't
## dominate the terrain when the window is zoomed into the pond).
static func draw_level_ticks(c: CanvasItem, start_l: Vector2, start_r: Vector2,
		break_l: Vector2, break_r: Vector2, module_rect: Rect2 = Rect2(),
		label_px: int = 11) -> void:
	c.draw_line(start_l, start_r, C_START, 1.5, true)
	c.draw_line(break_l, break_r, C_BREAK, 1.5, true)
	var fnt := ThemeDB.fallback_font
	var fs := clampi(label_px, 8, 14)
	c.draw_string(fnt, start_r + Vector2(4, 4), "start (prime)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_START)
	c.draw_string(fnt, break_r + Vector2(4, 4), "break (air)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_BREAK)
	if module_rect.size.x > 1.0 and module_rect.size.y > 1.0:
		c.draw_rect(module_rect, C_MODULE, true)
		c.draw_rect(module_rect, Color(0.85, 0.88, 0.92, 1.0), false, 1.5)
		c.draw_string(fnt, module_rect.position + Vector2(2, -4), "module",
				HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(fs - 1, 8),
				Color(0.85, 0.88, 0.92, 0.85))


## Culvert chord to ∞ sink + optional intake stub.
static func draw_hydro_links(c: CanvasItem, intake_a: Vector2, intake_b: Vector2,
		culvert_a: Vector2, culvert_b: Vector2) -> void:
	c.draw_line(intake_a, intake_b, Color(0.7, 0.75, 0.8, 0.95), 3.0, true)
	c.draw_line(culvert_a, culvert_b, C_CULVERT, 3.0, true)
	c.draw_string(ThemeDB.fallback_font, culvert_b + Vector2(-6, -6), "∞",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.95, 0.8, 0.35, 0.95))


## Procedural scrolling outflow streaks along a culvert chord (no fluid solver).
## `phase` is seconds (or any monotonically increasing float); `q_lps` scales
## speed/width; only draws when primed and flowing.
static func draw_outflow_streaks(c: CanvasItem, from: Vector2, to: Vector2,
		q_lps: float, primed: bool, phase: float) -> void:
	if not primed or q_lps < 0.01:
		return
	var dir := to - from
	var len := dir.length()
	if len < 4.0:
		return
	dir /= len
	var perp := Vector2(-dir.y, dir.x)
	var speed := clampf(q_lps * 0.35, 0.4, 4.0)
	var n_streaks := clampi(int(ceil(q_lps * 0.8)), 3, 10)
	var w := clampf(1.2 + q_lps * 0.15, 1.2, 4.0)
	for i in n_streaks:
		var base := fmod(phase * speed + float(i) * 0.17, 1.0)
		var t0 := base
		var t1 := minf(base + 0.12, 1.0)
		var a := from + dir * (len * t0) + perp * sin(float(i) * 1.7) * (w * 0.8)
		var b := from + dir * (len * t1) + perp * sin(float(i) * 1.7 + 0.4) * (w * 0.8)
		var a_col := 0.35 + 0.45 * (1.0 - absf(base - 0.5) * 2.0)
		c.draw_line(a, b, Color(0.55, 0.88, 1.0, a_col), w, true)
	c.draw_circle(from.lerp(to, 0.15), maxf(2.5, w), C_WATER_LINE)
	c.draw_circle(from.lerp(to, 0.75), maxf(2.5, w * 0.9), Color(0.95, 0.8, 0.35, 0.9))
