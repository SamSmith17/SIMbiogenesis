class_name GraphNodeRendererV2
extends RefCounted

## Node visual helpers for GraphCanvasV2 overlays and badges.

const BADGE_BG   := Color(0.06, 0.09, 0.18, 0.95)
const BADGE_TEXT := Color(0.92, 0.96, 1.00, 1.0)


## Draws a pill-shaped badge anchored to the top-right corner of `rect`.
func draw_badge(canvas: CanvasItem, rect: Rect2, label: String, accent: Color) -> void:
	var fnt  := ThemeDB.fallback_font
	var fs   := 13
	var size := fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pad  := Vector2(10.0, 5.0)
	var bw   := size.x + pad.x * 2.0
	var bh   := size.y + pad.y * 2.0
	var bg   := Rect2(rect.position + Vector2(rect.size.x - bw - 5.0, 5.0), Vector2(bw, bh))

	# Pill background + accent outline
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(BADGE_BG.r, BADGE_BG.g, BADGE_BG.b, BADGE_BG.a)
	sb.set_corner_radius_all(int(bh * 0.5))
	sb.set_border_width_all(1)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	canvas.draw_style_box(sb, bg)

	# Subtle accent glow fill
	var sb_glow := StyleBoxFlat.new()
	sb_glow.bg_color = Color(accent.r, accent.g, accent.b, 0.10)
	sb_glow.set_corner_radius_all(int(bh * 0.5))
	canvas.draw_style_box(sb_glow, bg)

	canvas.draw_string(fnt, bg.position + Vector2(pad.x, pad.y + size.y - 2.0),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
		Color(accent.r * 1.35, accent.g * 1.35, accent.b * 1.35, 1.0).clamp())
