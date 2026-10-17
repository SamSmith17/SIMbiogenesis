class_name TourCaptions
extends CanvasLayer

## The tour's on-screen words: a title card per stop (chapter, name, one line,
## and how to open it), lower-third captions mid-demo, and full-screen opening
## / closing cards. Above the HUD and toasts, below the load overlay. Sized off
## the viewport height so a 1080p recording and a 720p check look the same.
##
## Screenshots hide this whole layer (`TourContext.hero`), so the README
## images stay clean while the video carries the words.

const LAYER := 95
const CARD_FADE_S := 0.3
## Clear of the timeline bar (BAR_HEIGHT 164 at 1080 rows ≈ 15 %).
const BOTTOM_CLEAR_FRAC := 0.19

var _root: Control
var _card: PanelContainer
var _card_chapter: Label
var _card_title: Label
var _card_summary: Label
var _card_keys: HBoxContainer
var _caption: PanelContainer
var _caption_label: Label
var _full: ColorRect
var _full_title: Label
var _full_sub: Label
var _card_tween: Tween
var _caption_tween: Tween
var _full_tween: Tween
## Game-time seconds (the tweens' clock, which under Movie Maker is video
## time) until which the title card is on screen; a caption asked for
## meanwhile waits for it rather than sitting on top of it.
var _t := 0.0
var _card_until := 0.0


func _process(delta: float) -> void:
	_t += delta


func _ready() -> void:
	layer = LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_card()
	_build_caption()
	_build_full()
	get_viewport().size_changed.connect(_relayout)
	_relayout()


func _k() -> float:
	var h := float(get_viewport().get_visible_rect().size.y)
	return clampf(h / 1080.0, 0.5, 2.0)


func _panel_style(alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_BG.r, UITheme.C_BG.g, UITheme.C_BG.b, alpha)
	sb.border_color = UITheme.C_PRIMARY
	sb.border_width_left = 4
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_right = 10
	sb.corner_radius_top_left = 2
	sb.corner_radius_bottom_left = 2
	sb.content_margin_left = 22
	sb.content_margin_right = 26
	sb.content_margin_top = 14
	sb.content_margin_bottom = 16
	return sb


func _label(color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_card() -> void:
	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_theme_stylebox_override("panel", _panel_style(0.86))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(v)
	_card_chapter = _label(UITheme.C_PRIMARY)
	_card_title = _label(UITheme.C_TEXT)
	_card_summary = _label(UITheme.C_TEXT_S)
	_card_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_keys = HBoxContainer.new()
	_card_keys.add_theme_constant_override("separation", 8)
	_card_keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_card_chapter)
	v.add_child(_card_title)
	v.add_child(_card_summary)
	v.add_child(_card_keys)
	_card.modulate.a = 0.0
	_card.visible = false
	_root.add_child(_card)


func _build_caption() -> void:
	_caption = PanelContainer.new()
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _panel_style(0.78)
	sb.border_color = UITheme.C_AMBER
	_caption.add_theme_stylebox_override("panel", sb)
	_caption_label = _label(UITheme.C_TEXT)
	_caption.add_child(_caption_label)
	_caption.modulate.a = 0.0
	_caption.visible = false
	_root.add_child(_caption)


func _build_full() -> void:
	_full = ColorRect.new()
	_full.color = Color(UITheme.C_BG.r, UITheme.C_BG.g, UITheme.C_BG.b, 0.88)
	_full.set_anchors_preset(Control.PRESET_FULL_RECT)
	_full.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full.add_child(c)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 12)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(v)
	_full_title = _label(UITheme.C_TEXT)
	_full_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_full_sub = _label(UITheme.C_PRIMARY)
	_full_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_full_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_full_title)
	v.add_child(_full_sub)
	_full.modulate.a = 0.0
	_full.visible = false
	_root.add_child(_full)


func _relayout() -> void:
	if _card == null:
		return
	var k := _k()
	var vp := get_viewport().get_visible_rect().size
	_card_chapter.add_theme_font_size_override("font_size", int(18 * k))
	_card_title.add_theme_font_size_override("font_size", int(46 * k))
	_card_summary.add_theme_font_size_override("font_size", int(22 * k))
	_caption_label.add_theme_font_size_override("font_size", int(24 * k))
	_full_title.add_theme_font_size_override("font_size", int(72 * k))
	_full_sub.add_theme_font_size_override("font_size", int(26 * k))
	_full_sub.custom_minimum_size.x = vp.x * 0.6
	_card_summary.custom_minimum_size.x = 0.0
	_card.custom_minimum_size = Vector2(minf(vp.x * 0.42, 820.0 * k), 0)
	_card_summary.custom_minimum_size.x = _card.custom_minimum_size.x - 48.0
	for chip in _card_keys.get_children():
		_style_chip(chip as Label)
	_place_card()
	_place_caption()


func _place_card() -> void:
	var vp := get_viewport().get_visible_rect().size
	_card.reset_size()
	var sz := _card.get_combined_minimum_size()
	_card.size = sz
	_card.position = Vector2(vp.x * 0.035, vp.y * (1.0 - BOTTOM_CLEAR_FRAC) - sz.y)


func _place_caption() -> void:
	var vp := get_viewport().get_visible_rect().size
	_caption.reset_size()
	var sz := _caption.get_combined_minimum_size()
	_caption.size = sz
	_caption.position = Vector2((vp.x - sz.x) * 0.5, vp.y * (1.0 - BOTTOM_CLEAR_FRAC) - sz.y)


func _style_chip(l: Label) -> void:
	if l == null:
		return
	var k := _k()
	l.add_theme_font_size_override("font_size", int(20 * k))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_AMBER.r, UITheme.C_AMBER.g, UITheme.C_AMBER.b, 0.18)
	sb.border_color = UITheme.C_AMBER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	l.add_theme_stylebox_override("normal", sb)


## The stop's title card. `keys` = ["G", "Click 📊"] chips. Non-blocking;
## fades itself out after `hold_s`.
func show_card(chapter_text: String, title: String, summary: String, keys: PackedStringArray,
		hold_s: float) -> void:
	_card_chapter.text = chapter_text.to_upper()
	_card_title.text = title
	_card_summary.text = summary
	_card_summary.visible = not summary.is_empty()
	for c in _card_keys.get_children():
		c.queue_free()
		_card_keys.remove_child(c)
	for k in keys:
		var l := _label(UITheme.C_GOLD)
		l.text = k
		_style_chip(l)
		_card_keys.add_child(l)
	_card_keys.visible = not keys.is_empty()
	_card.visible = true
	_card_until = _t + hold_s + CARD_FADE_S * 2.0
	_place_card.call_deferred()
	if _card_tween != null and _card_tween.is_valid():
		_card_tween.kill()
	_card.modulate.a = 0.0
	_card_tween = create_tween()
	_card_tween.tween_property(_card, "modulate:a", 1.0, CARD_FADE_S)
	_card_tween.tween_interval(maxf(hold_s, 0.1))
	_card_tween.tween_property(_card, "modulate:a", 0.0, CARD_FADE_S)
	_card_tween.tween_callback(func() -> void: _card.visible = false)


## A lower-third caption mid-demo. Replaces any caption already up.
func show_caption(text: String, hold_s: float) -> void:
	_caption_label.text = text
	_caption.visible = true
	_place_caption.call_deferred()
	if _caption_tween != null and _caption_tween.is_valid():
		_caption_tween.kill()
	_caption.modulate.a = 0.0
	_caption_tween = create_tween()
	var lead := maxf(_card_until - _t, 0.0)
	if lead > 0.0:
		_caption_tween.tween_interval(lead)
	_caption_tween.tween_property(_caption, "modulate:a", 1.0, 0.2)
	_caption_tween.tween_interval(maxf(hold_s, 0.1))
	_caption_tween.tween_property(_caption, "modulate:a", 0.0, 0.3)
	_caption_tween.tween_callback(func() -> void: _caption.visible = false)


## Full-screen card (tour opening / closing). Non-blocking.
func show_full(title: String, sub: String, hold_s: float) -> void:
	_full_title.text = title
	_full_sub.text = sub
	_full.visible = true
	if _full_tween != null and _full_tween.is_valid():
		_full_tween.kill()
	_full.modulate.a = 0.0
	_full_tween = create_tween()
	_full_tween.tween_property(_full, "modulate:a", 1.0, 0.5)
	_full_tween.tween_interval(maxf(hold_s, 0.1))
	_full_tween.tween_property(_full, "modulate:a", 0.0, 0.6)
	_full_tween.tween_callback(func() -> void: _full.visible = false)


func clear_all() -> void:
	_card_until = 0.0
	for t in [_card_tween, _caption_tween, _full_tween]:
		if t != null and (t as Tween).is_valid():
			(t as Tween).kill()
	for c: CanvasItem in [_card, _caption, _full]:
		c.modulate.a = 0.0
		c.visible = false
