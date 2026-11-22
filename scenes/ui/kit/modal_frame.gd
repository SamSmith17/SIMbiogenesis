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
## Stop above the timeline bar instead of covering it (a modal about time,
## such as the video export, that wants the bar in view).
var keep_timeline := false
## Full screen, the content sits in a centred column this wide (the panel's
## own pixels) instead of running edge to edge. 0 = use the whole width (a
## chart, a wide table). Set before open().
var content_max_w := 1040.0

var _want_size := Vector2(900, 640)
var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _subtitle: Label = null
var _footer_sep: HSeparator = null
var _is_open := false
var _claimed_main_modal := false


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
	_panel.add_theme_stylebox_override("panel", UITheme.modal_panel_style(0.99))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_meta("ui_modal", true)  # UiAudit.MODAL_META
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
	v.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	_footer_sep = HSeparator.new()
	_footer_sep.visible = false
	v.add_child(_footer_sep)
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
	match kind:
		PRIMARY:
			UITheme.style_primary_button(b)
		DESTRUCTIVE:
			UITheme.style_destructive_button(b)
		_:
			UITheme.style_button(b)
	if cb.is_valid():
		b.pressed.connect(cb)
	footer.add_child(b)
	footer.visible = true
	if _footer_sep != null:
		_footer_sep.visible = true
	return b


func open() -> void:
	if _is_open:
		return
	_is_open = true
	var in_secondary := UiFit.is_secondary_window(self)
	if is_inside_tree() and get_tree() != null:
		var scope_root: Node = get_viewport() if in_secondary else get_tree().root
		var top_l := UITheme.LAYER_MODAL - 1
		for n in scope_root.find_children("*", "CanvasLayer", true, false):
			var cl := n as CanvasLayer
			if cl != self and cl.visible and cl.layer >= UITheme.LAYER_MODAL and cl.layer < UITheme.LAYER_TOAST:
				top_l = maxi(top_l, cl.layer)
		layer = top_l + 1
	_backdrop.color = UITheme.C_BG if in_secondary else Color(0, 0, 0, 0.55)
	visible = true
	_fit()
	if not in_secondary:
		UITheme.animate_open(_panel, _backdrop)
	if not get_viewport().size_changed.is_connected(_fit):
		get_viewport().size_changed.connect(_fit)
	_claimed_main_modal = not in_secondary
	if _claimed_main_modal:
		var cc := get_node_or_null("/root/CursorController")
		if cc != null:
			cc.request_modal(modal_name, close)
		var hl := get_node_or_null("/root/HudLayout")
		if hl != null:
			hl.claim_modal(modal_name)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	visible = false
	if _claimed_main_modal:
		_claimed_main_modal = false
		var cc := get_node_or_null("/root/CursorController")
		if cc != null:
			cc.release_modal(modal_name)
		var hl := get_node_or_null("/root/HudLayout")
		if hl != null:
			hl.release(modal_name)
	closed.emit()


func is_open() -> bool:
	return _is_open


func _exit_tree() -> void:
	if _is_open and _claimed_main_modal:
		_claimed_main_modal = false
		var cc := get_node_or_null("/root/CursorController")
		if cc != null:
			cc.release_modal(modal_name)
		var hl := get_node_or_null("/root/HudLayout")
		if hl != null:
			hl.release(modal_name)


## Centred, never bigger than the screen minus a margin, and above the timeline.
func _fit() -> void:
	if _panel == null or not is_inside_tree():
		return
	_panel.set_meta("ui_fit_content_max_w", content_max_w)
	if UiFit.fills_screen(_want_size, keep_timeline, _panel):
		UiFit.fill(_panel, _want_size)
		return
	_panel.scale = Vector2.ONE
	UiFit._apply_content_column(_panel, 0.0)
	var vp := get_viewport().get_visible_rect().size
	var bottom := vp.y - UiFit.timeline_clearance(self, keep_timeline)
	var avail := Vector2(vp.x - SCREEN_MARGIN * 2.0, bottom - SCREEN_MARGIN * 2.0)
	var s := Vector2(minf(_want_size.x, avail.x), minf(_want_size.y, avail.y))
	_panel.size = s
	_panel.position = Vector2((vp.x - s.x) * 0.5, SCREEN_MARGIN + (avail.y - s.y) * 0.5)
