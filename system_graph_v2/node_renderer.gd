class_name GraphNodeRendererV2
extends RefCounted

## Node visual helpers for GraphCanvasV2 overlays and badges.

const BADGE_BG   := Color(0.06, 0.09, 0.18, 0.95)
const BADGE_TEXT := Color(0.92, 0.96, 1.00, 1.0)


## Draws a pill-shaped badge anchored to the top-right corner of `rect`.
## Font and padding track `zoom`, but never exceed the node — Site Plan tiny
## footprints must not keep a fixed 6–7 px floor (that looked "stuck huge").
func draw_badge(canvas: CanvasItem, rect: Rect2, label: String, accent: Color,
		zoom: float = 1.0) -> void:
	if label.is_empty() or rect.size.x < 2.0 or rect.size.y < 2.0:
		return
	var fnt := ThemeDB.fallback_font
	var ideal := 13.0 * maxf(zoom, 0.001)
	ideal = minf(ideal, rect.size.y * 0.45)
	ideal = minf(ideal, rect.size.x * 0.38)
	if ideal < 4.5:
		return
	var fs := clampi(int(round(ideal)), 4, 64)
	var size := fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pad := Vector2(float(fs) * 0.55, float(fs) * 0.28)
	var bw := size.x + pad.x * 2.0
	var bh := size.y + pad.y * 2.0
	var margin := maxf(1.0, float(fs) * 0.35)
	var bg: Rect2
	if bw <= rect.size.x + margin * 2.0:
		# Prefer top-right on the node.
		bg = Rect2(
			Vector2(rect.end.x - bw - margin, rect.position.y + margin),
			Vector2(bw, bh))
		if bg.position.x < rect.position.x - margin:
			bg.position.x = rect.position.x + margin
	else:
		# Wider than the footprint — sit centered just above so it still tracks.
		bg = Rect2(
			Vector2(rect.get_center().x - bw * 0.5, rect.position.y - bh - margin),
			Vector2(bw, bh))

	# Pill background + accent outline
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(BADGE_BG.r, BADGE_BG.g, BADGE_BG.b, BADGE_BG.a)
	sb.set_corner_radius_all(maxi(2, int(bh * 0.5)))
	sb.set_border_width_all(maxi(1, int(round(float(fs) * 0.08))))
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	canvas.draw_style_box(sb, bg)

	# Subtle accent glow fill
	var sb_glow := StyleBoxFlat.new()
	sb_glow.bg_color = Color(accent.r, accent.g, accent.b, 0.10)
	sb_glow.set_corner_radius_all(maxi(2, int(bh * 0.5)))
	canvas.draw_style_box(sb_glow, bg)

	canvas.draw_string(fnt, bg.position + Vector2(pad.x, pad.y + size.y * 0.82),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
		Color(accent.r * 1.35, accent.g * 1.35, accent.b * 1.35, 1.0).clamp())
