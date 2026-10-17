class_name ModalFrame
extends CanvasLayer

## The one modal window: a dimmed backdrop, a centred panel with a title (and
## optional subtitle), ONE close button, a scrolling body and a footer of
## primary / secondary / destructive buttons. It owns the whole modal contract
## so a new modal cannot get it half right:
##   - CursorController.request_modal on open (Esc pops it), release on close;
##   - the first-person HUD hides under it (HudLayout.claim_modal);
##   - the panel is sized to the screen, never past it, and stops above the
##     timeline; the body scrolls instead of growing.
##
##   var m := ModalFrame.create("Site Report", "Mount Vernon · 2026", Vector2(1100, 760))
##   add_child(m)                       # anywhere — it is its own CanvasLayer
##   m.body.add_child(my_content)
##   m.add_button("Recompute", ModalFrame.SECONDARY, _recompute)
##   m.add_button("Close", ModalFrame.PRIMARY, m.close)
##   m.open()
##   m.closed.connect(...)

signal closed

enum { PRIMARY, SECONDARY, DESTRUCTIVE }

const SCREEN_MARGIN := 24.0

## Fill these.
var body: VBoxContainer = null
var footer: HBoxContainer = null

var modal_name := "modal_frame"
var close_on_backdrop := true

var _want_size := Vector2(900, 640)
var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _subtitle: Label = null
var _is_open := false


static func create(title: String, subtitle: String = "", size: Vector2 = Vector2(900, 640),
		name_id: String = "") -> ModalFrame:
	var m := ModalFrame.new()
	m.modal_name = name_id if not name_id.is_empty() else "modal_" + title.to_snake_case()
	m._want_size = size
	m._build(title, subtitle)
	return m


func _build(title: String, subtitle: String) -> void:
	layer = UITheme.LAYER_MODAL
	visible = false
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.55)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(func(e: InputEvent) -> void:
		if close_on_backdrop and e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			close())
	add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.98))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	head.add_child(titles)
	_title = Label.new()
	_title.text = title
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.add_theme_font_override("font", UITheme.font("semibold"))
	_title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_title.add_theme_color_override("font_color", UITheme.C_TEXT)
	titles.add_child(_title)
	_subtitle = Label.new()
	_subtitle.text = subtitle
	_subtitle.visible = not subtitle.is_empty()
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_subtitle.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_subtitle.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	titles.add_child(_subtitle)
	var x := Button.new()
	x.focus_mode = Control.FOCUS_NONE
	x.flat = true
	x.custom_minimum_size = Vector2(32, 32)
	x.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	UiIcons.apply(x, "x", "Close (Esc)", 18)
	x.pressed.connect(close)
	head.add_child(x)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	footer = HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 8)
	footer.visible = false
	v.add_child(footer)


func set_title(title: String, subtitle: String = "") -> void:
	_title.text = title
	_subtitle.text = subtitle
	_subtitle.visible = not subtitle.is_empty()


## A footer button. PRIMARY is filled in the accent, DESTRUCTIVE in the error
## colour, SECONDARY plain.
func add_button(text: String, kind: int, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(96, 32)
	UITheme.style_button(b)
	match kind:
		PRIMARY:
			b.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		DESTRUCTIVE:
			b.add_theme_color_override("font_color", UITheme.C_ERROR)
	if cb.is_valid():
		b.pressed.connect(cb)
	footer.add_child(b)
	footer.visible = true
	return b


func open() -> void:
	if _is_open:
		return
	_is_open = true
	visible = true
	_fit()
	if not get_viewport().size_changed.is_connected(_fit):
		get_viewport().size_changed.connect(_fit)
	CursorController.request_modal(modal_name, close)
	HudLayout.claim_modal(modal_name)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	visible = false
	CursorController.release_modal(modal_name)
	HudLayout.release(modal_name)
	closed.emit()


func is_open() -> bool:
	return _is_open


func _exit_tree() -> void:
	if _is_open:
		CursorController.release_modal(modal_name)
		HudLayout.release(modal_name)


## Centred, never bigger than the screen minus a margin, and above the timeline.
func _fit() -> void:
	if _panel == null or not is_inside_tree():
		return
	var vp := get_viewport().get_visible_rect().size
	var bottom := vp.y - HudLayout.timeline_height()
	var avail := Vector2(vp.x - SCREEN_MARGIN * 2.0, bottom - SCREEN_MARGIN * 2.0)
	var s := Vector2(minf(_want_size.x, avail.x), minf(_want_size.y, avail.y))
	_panel.size = s
	_panel.position = Vector2((vp.x - s.x) * 0.5, SCREEN_MARGIN + (avail.y - s.y) * 0.5)
