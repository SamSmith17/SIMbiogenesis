class_name TourCaptions
extends CanvasLayer

## The tour's on-screen words: a title card per stop (chapter, name, one line,
## and how to open it), captions mid-demo, full-screen opening / closing
## cards, and the black curtain the tour dips through between stops. Above
## the HUD and toasts, below the load overlay. Sized off the viewport height,
## so a 1080p recording and a 720p check look the same.
##
## ONE SLOT (2026-10-29). The title card and the captions share one place:
## centred, just above the timeline bar's LIVE top edge (or the bottom of the
## screen when the bar or the whole HUD is hidden), followed every frame and
## eased, so a stop that hides the HUD or changes the bar's size moves the
## words with it. They used to sit at a fixed 81 % of the screen height (the
## card bottom-left, the caption centred, in two accent colours), which put
## every caption on the timeline's data tracks once the bar grew past the
## 15 % it was tuned for, and the card on the bottom-left HUD panels.
## Both use one style and the same entrance (fade + a short rise) and exit.
##
## Screenshots hide this whole layer (`TourContext.hero`), so the README
## images stay clean while the video carries the words.

const LAYER := 95
const CARD_FADE_S := 0.3
const CAPTION_IN_S := 0.25
const CAPTION_OUT_S := 0.3
## Gap between the slot and the timeline (or the screen edge), at 1080 rows.
const SLOT_GAP := 22.0
## How far a card or caption rises as it fades in, at 1080 rows.
const RISE_PX := 14.0
## Widest a caption may be, as a share of the screen; longer text wraps.
const CAPTION_MAX_W := 0.62
## How fast the slot follows the bar (1/s, exponential).
const SLOT_FOLLOW := 10.0

var _root: Control
var _black: ColorRect
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
var _black_tween: Tween
## The tour's mouse pointer: Movie Maker records the viewport, not the OS
## cursor, so a click or a wire drag would otherwise happen by itself.
var _pointer: _Pointer
var _pointer_tween: Tween
## Game-time seconds (the tweens' clock, which under Movie Maker is video
## time) until which the title card is on screen; a caption asked for
## meanwhile waits for it rather than sitting on top of it.
var _t := 0.0
var _card_until := 0.0
## The slot's bottom edge (screen y), eased toward `_slot_target()`.
var _slot_y := -1.0
## Each panel's current rise (px above the slot), tweened on entrance / exit.
var _card_dy := 0.0
var _caption_dy := 0.0


func _ready() -> void:
	layer = LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_black()
	_build_card()
	_build_caption()
	_build_full()
	_pointer = _Pointer.new()
	_pointer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pointer.visible = false
	_root.add_child(_pointer)
	get_viewport().size_changed.connect(_relayout)
	_relayout()


func _process(delta: float) -> void:
	_t += delta
	var target := _slot_target()
	if _slot_y < 0.0:
		_slot_y = target
	else:
		_slot_y = lerpf(_slot_y, target, 1.0 - exp(-SLOT_FOLLOW * delta))
	if _card.visible:
		_place(_card, _card_dy)
	if _caption.visible:
		_place(_caption, _caption_dy)


func _k() -> float:
	var h := float(get_viewport().get_visible_rect().size.y)
	return clampf(h / 1080.0, 0.5, 2.0)


## Bottom edge of the slot: above the timeline bar when it is on screen.
func _slot_target() -> float:
	var vp := get_viewport().get_visible_rect().size
	return vp.y - _timeline_h() - SLOT_GAP * _k()


func _timeline_h() -> float:
	var tl := ServiceLocator.timeline_ui() as CanvasItem
	if tl == null or not is_instance_valid(tl) or not tl.is_visible_in_tree():
		return 0.0
	if tl.has_method("get_stack_height"):
		return float(tl.call("get_stack_height"))
	return 0.0


func _place(p: Control, dy: float) -> void:
	var vp := get_viewport().get_visible_rect().size
	var sz := p.get_combined_minimum_size()
	p.size = sz
	p.position = Vector2(roundf((vp.x - sz.x) * 0.5), roundf(_slot_y - sz.y + dy))


func _panel_style(alpha: float) -> StyleBoxFlat:
	var k := _k()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_BG.r, UITheme.C_BG.g, UITheme.C_BG.b, alpha)
	sb.border_color = UITheme.C_PRIMARY
	sb.border_width_left = int(round(4 * k))
	sb.set_corner_radius_all(int(round(8 * k)))
	sb.corner_radius_top_left = 2
	sb.corner_radius_bottom_left = 2
	sb.content_margin_left = 22 * k
	sb.content_margin_right = 26 * k
	sb.content_margin_top = 12 * k
	sb.content_margin_bottom = 14 * k
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = int(round(10 * k))
	return sb


func _label(color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_black() -> void:
	_black = ColorRect.new()
	_black.color = Color(0, 0, 0, 1)
	_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_black.modulate.a = 0.0
	_black.visible = false
	_root.add_child(_black)


func _build_card() -> void:
	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	for l: Label in [_card_chapter, _card_title, _card_summary]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_keys.alignment = BoxContainer.ALIGNMENT_CENTER
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
	_caption_label = _label(UITheme.C_TEXT)
	_caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
	_card.add_theme_stylebox_override("panel", _panel_style(0.88))
	_caption.add_theme_stylebox_override("panel", _panel_style(0.84))
	_card_chapter.add_theme_font_size_override("font_size", int(17 * k))
	_card_title.add_theme_font_size_override("font_size", int(44 * k))
	_card_summary.add_theme_font_size_override("font_size", int(22 * k))
	_caption_label.add_theme_font_size_override("font_size", int(26 * k))
	_full_title.add_theme_font_size_override("font_size", int(72 * k))
	_full_sub.add_theme_font_size_override("font_size", int(26 * k))
	_full_sub.custom_minimum_size.x = vp.x * 0.6
	var card_w := minf(vp.x * 0.46, 860.0 * k)
	_card.custom_minimum_size = Vector2(card_w, 0)
	_card_summary.custom_minimum_size.x = card_w - 48.0 * k
	for chip in _card_keys.get_children():
		_style_chip(chip as Label)
	_size_caption()


## A caption is as wide as its text, up to CAPTION_MAX_W of the screen; past
## that it wraps onto a second line instead of running off the screen.
func _size_caption() -> void:
	var vp := get_viewport().get_visible_rect().size
	var k := _k()
	var font := _caption_label.get_theme_font("font")
	var fs := _caption_label.get_theme_font_size("font_size")
	var text_w := font.get_string_size(_caption_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if font != null else 0.0
	var max_w := vp.x * CAPTION_MAX_W - 48.0 * k
	if text_w > max_w:
		_caption_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_caption_label.custom_minimum_size.x = max_w
	else:
		_caption_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_caption_label.custom_minimum_size.x = 0.0
	_caption.reset_size()


func _style_chip(l: Label) -> void:
	if l == null:
		return
	var k := _k()
	l.add_theme_font_size_override("font_size", int(19 * k))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_AMBER.r, UITheme.C_AMBER.g, UITheme.C_AMBER.b, 0.16)
	sb.border_color = UITheme.C_AMBER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	l.add_theme_stylebox_override("normal", sb)


func _set_card_dy(v: float) -> void:
	_card_dy = v


func _set_caption_dy(v: float) -> void:
	_caption_dy = v


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
	# The card owns the slot while it is up: a caption still showing from
	# before goes now rather than sitting under it.
	_hide_caption_now()
	_card.reset_size()
	_card.visible = true
	_card_until = _t + hold_s + CARD_FADE_S * 2.0
	if _card_tween != null and _card_tween.is_valid():
		_card_tween.kill()
	var rise := RISE_PX * _k()
	_card.modulate.a = 0.0
	_card_dy = rise
	_place(_card, _card_dy)
	_card_tween = create_tween()
	_card_tween.set_parallel(true)
	_card_tween.tween_property(_card, "modulate:a", 1.0, CARD_FADE_S)
	_card_tween.tween_method(_set_card_dy, rise, 0.0, CARD_FADE_S + 0.1) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_card_tween.chain().tween_interval(maxf(hold_s, 0.1))
	_card_tween.chain().tween_property(_card, "modulate:a", 0.0, CARD_FADE_S)
	_card_tween.tween_method(_set_card_dy, 0.0, rise * 0.5, CARD_FADE_S) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_card_tween.chain().tween_callback(func() -> void: _card.visible = false)


## A caption mid-demo, in the same slot as the card (it waits for the card to
## go). Replaces any caption already up.
func show_caption(text: String, hold_s: float) -> void:
	_caption_label.text = text
	_size_caption()
	_caption.visible = true
	if _caption_tween != null and _caption_tween.is_valid():
		_caption_tween.kill()
	var rise := RISE_PX * _k()
	var was_up := _caption.modulate.a > 0.5
	_caption_tween = create_tween()
	var lead := maxf(_card_until - _t, 0.0)
	if was_up and lead <= 0.0:
		# Caption to caption: a quick crossfade in place, no second rise.
		_caption_tween.tween_property(_caption, "modulate:a", 0.0, 0.12)
		_caption_tween.tween_property(_caption, "modulate:a", 1.0, 0.18)
	else:
		_caption.modulate.a = 0.0
		_caption_dy = rise
		if lead > 0.0:
			_caption_tween.tween_interval(lead)
		_caption_tween.tween_property(_caption, "modulate:a", 1.0, CAPTION_IN_S)
		_caption_tween.parallel().tween_method(_set_caption_dy, rise, 0.0, CAPTION_IN_S + 0.1) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_caption_tween.tween_interval(maxf(hold_s, 0.1))
	_caption_tween.tween_property(_caption, "modulate:a", 0.0, CAPTION_OUT_S)
	_caption_tween.tween_callback(func() -> void: _caption.visible = false)
	_place(_caption, _caption_dy)


func _hide_caption_now() -> void:
	if _caption_tween != null and _caption_tween.is_valid():
		_caption_tween.kill()
	_caption.modulate.a = 0.0
	_caption.visible = false


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


## The curtain between stops: fade to black over `seconds` (0 = at once).
## Cards and captions draw over it.
func dip_to_black(seconds: float) -> void:
	_fade_black(1.0, seconds)


## Lift the curtain over `seconds`.
func reveal(seconds: float) -> void:
	_fade_black(0.0, seconds)


func is_dark() -> bool:
	return _black.visible and _black.modulate.a > 0.01


func _fade_black(to: float, seconds: float) -> void:
	if _black_tween != null and _black_tween.is_valid():
		_black_tween.kill()
	_black.visible = true
	if seconds <= 0.0:
		_black.modulate.a = to
		_black.visible = to > 0.0
		return
	_black_tween = create_tween()
	_black_tween.tween_property(_black, "modulate:a", to, seconds) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if to <= 0.0:
		_black_tween.tween_callback(func() -> void: _black.visible = false)


## Show the pointer at a viewport point (`pressed` draws the press ring).
func pointer_at(pos: Vector2, pressed: bool = false) -> void:
	if _pointer_tween != null and _pointer_tween.is_valid():
		_pointer_tween.kill()
	_pointer.visible = true
	_pointer.modulate.a = 1.0
	_pointer.k = _k()
	_pointer.position = pos
	if _pointer.pressed != pressed:
		_pointer.pressed = pressed
		_pointer.queue_redraw()


func pointer_hide(seconds: float = 0.3) -> void:
	if not _pointer.visible:
		return
	if _pointer_tween != null and _pointer_tween.is_valid():
		_pointer_tween.kill()
	_pointer_tween = create_tween()
	_pointer_tween.tween_property(_pointer, "modulate:a", 0.0, maxf(seconds, 0.01))
	_pointer_tween.tween_callback(func() -> void: _pointer.visible = false)


## Fade every card and caption out over `seconds` (the curtain stays as it is).
func fade_words(seconds: float) -> void:
	pointer_hide(seconds)
	_card_until = 0.0
	for pair in [[_card, _card_tween], [_caption, _caption_tween]]:
		var c: CanvasItem = pair[0]
		var tw: Tween = pair[1]
		if tw != null and tw.is_valid():
			tw.kill()
		if not c.visible:
			continue
		var t := create_tween()
		t.tween_property(c, "modulate:a", 0.0, maxf(seconds, 0.01))
		t.tween_callback(func() -> void: c.visible = false)


func clear_all() -> void:
	_card_until = 0.0
	for t in [_card_tween, _caption_tween, _full_tween, _black_tween]:
		if t != null and (t as Tween).is_valid():
			(t as Tween).kill()
	for c: CanvasItem in [_card, _caption, _full, _black, _pointer]:
		c.modulate.a = 0.0
		c.visible = false


## A plain arrow pointer drawn at its tip (the Control's origin).
class _Pointer extends Control:
	var pressed := false
	var k := 1.0

	func _draw() -> void:
		var s := 1.5 * k
		var pts := PackedVector2Array([Vector2(0, 0), Vector2(0, 17), Vector2(4.2, 13.2),
			Vector2(7.2, 20), Vector2(10, 18.8), Vector2(7, 12.2), Vector2(12.4, 12.2)])
		for i in pts.size():
			pts[i] *= s
		if pressed:
			draw_arc(Vector2.ZERO, 15.0 * k, 0.0, TAU, 32, Color(UITheme.C_PRIMARY, 0.9), 3.0 * k, true)
		draw_colored_polygon(pts, Color(1, 1, 1, 1))
		var loop := pts.duplicate()
		loop.append(pts[0])
		draw_polyline(loop, Color(0.05, 0.07, 0.12, 1), 1.6 * k, true)
