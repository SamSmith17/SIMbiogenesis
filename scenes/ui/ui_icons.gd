class_name UiIcons
extends RefCounted

## UI icons (Lucide, ISC — see CREDITS.md), drawn white so a control's
## modulate / icon colour tints them. Built as DPITexture from the markup in
## UiIconData, so they re-rasterise crisply at any UI scale instead of being
## a fixed bitmap stretched by content_scale_factor.
##
##   button.icon = UiIcons.icon("save")          # 16 px
##   UiIcons.apply(button, "undo-2", "Undo")     # icon + tooltip, theme colours
##
## An unknown name returns null and warns once, so a typo shows up as a
## missing icon in the tour's screenshots rather than a crash.

const DEFAULT_PX := 16

static var _cache: Dictionary = {}
static var _warned: Dictionary = {}


static func has(name: String) -> bool:
	return UiIconData.ICONS.has(name)


static func icon(name: String, px: int = DEFAULT_PX, stroke: float = 2.0) -> Texture2D:
	var key := "%s|%d|%.2f" % [name, px, stroke]
	if _cache.has(key):
		return _cache[key]
	var markup := str(UiIconData.ICONS.get(name, ""))
	if markup.is_empty():
		if not _warned.has(name):
			_warned[name] = true
			push_warning("UiIcons: no icon named '%s' (add assets/ui/icons/%s.svg, run tools/ui_icons_build.py)" % [name, name])
		return null
	var svg := ("<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' "
		+ "fill='none' stroke='#ffffff' stroke-width='%s' stroke-linecap='round' stroke-linejoin='round'>%s</svg>") % [
		String.num(stroke, 2), markup]
	var tex := DPITexture.create_from_string(svg, float(px) / 24.0)
	_cache[key] = tex
	return tex


## Give a Button an icon (and, when it has no text, a tooltip so it is never
## a mystery glyph). Returns the button for chaining.
static func apply(b: Button, name: String, tooltip: String = "", px: int = DEFAULT_PX) -> Button:
	b.icon = icon(name, px)
	b.expand_icon = false
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	return b
