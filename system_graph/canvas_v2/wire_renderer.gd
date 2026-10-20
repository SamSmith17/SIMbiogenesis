class_name GraphWireRendererV2
extends RefCounted

## Visual overlays and legends for wire semantics.

const LEGEND_BG   := Color(0.05, 0.08, 0.17, 0.94)
const LEGEND_TEXT := Color(0.90, 0.93, 0.98, 1.0)


func draw_legend(canvas: CanvasItem, origin: Vector2, entries: Array[Dictionary]) -> void:
	var fnt    := ThemeDB.fallback_font
	var fs     := 12
	var line_h := 20.0
	var width  := 230.0
	var height := 20.0 + entries.size() * line_h + 8.0
	var rect   := Rect2(origin, Vector2(width, height))

	# Rounded panel
	var sb := StyleBoxFlat.new()
	sb.bg_color = LEGEND_BG
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.22, 0.30, 0.46, 0.75)
	canvas.draw_style_box(sb, rect)

	# Title
	canvas.draw_string(fnt, origin + Vector2(10.0, 16.0),
		"WIRE TYPES", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
		Color(0.58, 0.64, 0.72, 0.90))

	for i in range(entries.size()):
		var e   := entries[i]
		var y   := origin.y + 28.0 + i * line_h
		var col := e.get("color", Color.WHITE) as Color
		var lbl := str(e.get("label", ""))

		# Colored dot with glow ring
		canvas.draw_circle(Vector2(origin.x + 12.0, y - 4.0), 5.5, Color(col.r, col.g, col.b, 0.22))
		canvas.draw_circle(Vector2(origin.x + 12.0, y - 4.0), 4.0, col)
		canvas.draw_circle(Vector2(origin.x + 12.0, y - 4.0), 2.0, Color(1.0, 1.0, 1.0, 0.45))
		canvas.draw_string(fnt, Vector2(origin.x + 24.0, y), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LEGEND_TEXT)
