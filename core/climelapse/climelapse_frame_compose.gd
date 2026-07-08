class_name ClimelapseFrameCompose
extends Node

## Expands a viewport capture with a black timecode bar (timelapse-style).

const BAR_HEIGHT := 52
const FONT_SIZE := 30


var _vp: SubViewport
var _bg: ColorRect
var _label: Label


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_bg = ColorRect.new()
	_bg.color = Color.BLACK
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp.add_child(_bg)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_vp.add_child(_label)


static func format_timecode(year: int, month: int, day: int, day_time: float = 12.0) -> String:
	var h := int(floor(day_time)) % 24
	var m := int(round(fmod(day_time, 1.0) * 60.0)) % 60
	return "%04d-%02d-%02d   %02d:%02d" % [year, month, day, h, m]


func _layout_bar(w: int) -> void:
	var sz := Vector2(w, BAR_HEIGHT)
	_vp.size = Vector2i(w, BAR_HEIGHT)
	_bg.position = Vector2.ZERO
	_bg.size = sz
	_label.position = Vector2.ZERO
	_label.size = sz


func stamp_async(src: Image, text: String) -> Image:
	var w := src.get_width()
	var src_h := src.get_height()
	if w < 1 or src_h < 1:
		return src
	_layout_bar(w)
	_label.text = text
	var tree := get_tree()
	if tree != null:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var bar_tex := _vp.get_texture()
	var out := Image.create(w, src_h + BAR_HEIGHT, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, Rect2i(0, 0, w, src_h), Vector2i(0, 0))
	if bar_tex != null:
		var bar_img := bar_tex.get_image()
		if bar_img != null and not bar_img.is_empty():
			out.blit_rect(bar_img, Rect2i(0, 0, w, BAR_HEIGHT), Vector2i(0, src_h))
			return out
	out.fill_rect(Rect2i(0, src_h, w, BAR_HEIGHT), Color.BLACK)
	return out
