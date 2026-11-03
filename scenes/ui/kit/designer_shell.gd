class_name DesignerShell
extends Control

## THE shell for anything with a studio: the designers (dome, toroid, solar,
## Pelton, wind, flat-pack, gantry), the builders, the Tune looks, connection
## ports, machine setup, the print setup, the packing lab. It owns the whole
## modal contract so no designer gets it half right, and the layout the
## twelve copies had each drifted on:
##   - a dimmed backdrop and a centred panel fitted to the screen
##     (`UiFit.keep_fitted`, which also claims the HUD and marks the panel a
##     modal for the UI audit) and the cursor modal (Esc closes);
##   - a header: Lucide icon, title, an optional design-name field, a
##     subtitle that ellipsizes, undo / redo, THE close button;
##   - three columns: `left` (a scrolling list column), `centre` (the
##     owner's StudioViewport, tab bar and strip) and `right` (a scrolling
##     settings column); a strip over the centre carries the BREADCRUMB
##     (`set_crumbs`) and the MODE CHIP (`set_mode`: "Placing NEMA17 L ·
##     click a slot · R turns · Esc" in amber while a tool is armed);
##   - a footer: a one-sentence hint of verbs on the left and the buttons
##     (PRIMARY / SECONDARY / DESTRUCTIVE, as ModalFrame) on the right.
##
## THE 720 RULE. Below `FOLD_W` px of canvas width (a 1280×720 window at UI
## scale 1.25 is a 1536 px canvas) the left column folds into a header
## button that opens it as a popup, and the right column narrows to
## `RIGHT_W_NARROW`; below `SHORT_H` px of height the hint hides and the
## footer's buttons join the header row. Nothing in the body may carry a
## fixed minimum height — the studio takes what is left.
##
##   var shell := DesignerShell.create("Dome & zome designer", "tent",
##       {"name_id": "domelab_designer", "left_label": "Structure & designs"})
##   add_child(shell)                       # under a full-rect Control
##   shell.left.add_child(...); shell.right.add_child(...)
##   shell.centre.add_child(studio)
##   shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place)
##   shell.set_hint("Drag to orbit · wheel to zoom · click a part to pick it")
##   shell.closed.connect(_on_closed)       # Esc, the close button, close()
##   shell.open()

signal closed
signal undo_requested
signal redo_requested
signal name_submitted(text: String)
signal crumb_pressed(index: int)
signal layout_changed(folded: bool, short: bool)

enum { PRIMARY, SECONDARY, DESTRUCTIVE }

const FOLD_W := 1600.0
const SHORT_H := 900.0
const LEFT_W := 240.0
const RIGHT_W := 390.0
const RIGHT_W_NARROW := 340.0

## Fill these.
var left: VBoxContainer = null
var centre: VBoxContainer = null
var right: VBoxContainer = null
var footer: HBoxContainer = null
var panel: PanelContainer = null
var name_edit: LineEdit = null
var subtitle: Label = null
var title_label: Label = null
var badge: Button = null
var undo_btn: Button = null
var redo_btn: Button = null
var strip: HBoxContainer = null

var modal_name := "designer"
var want := Vector2(1600, 960)
var left_w := LEFT_W
var right_w := RIGHT_W

var _backdrop: ColorRect = null
var _root: VBoxContainer = null
var _header: HBoxContainer = null
var _body: HBoxContainer = null
var _left_scroll: ScrollContainer = null
var _right_scroll: ScrollContainer = null
var _footer_row: HBoxContainer = null
var _hint: Label = null
var _left_btn: Button = null
var _fly_layer: CanvasLayer = null
var _left_catcher: Control = null
var _left_flyout: PanelContainer = null
var _close_btn: Button = null
var _crumbs: HBoxContainer = null
var _mode_chip: PanelContainer = null
var _mode_lbl: Label = null
var _is_open := false
var _folded := false
var _short := false


## Options: want (Vector2), name_id (the cursor-modal name), name_edit (bool,
## a design-name field in the header), undo (bool), left_label (the folded
## column's button text), left_w / right_w (px), icon_color.
static func create(title: String, icon: String = "", opts: Dictionary = {}) -> DesignerShell:
	var s := DesignerShell.new()
	s.modal_name = str(opts.get("name_id", "designer_" + title.to_snake_case()))
	s.want = opts.get("want", Vector2(1600, 960))
	s.left_w = float(opts.get("left_w", LEFT_W))
	s.right_w = float(opts.get("right_w", RIGHT_W))
	s._build(title, icon, opts)
	return s


func _build(title: String, icon: String, opts: Dictionary) -> void:
	name = "DesignerShell"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.55)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	panel.add_child(_root)

	# Header.
	_header = HBoxContainer.new()
	_header.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_root.add_child(_header)
	if not icon.is_empty():
		var ic := TextureRect.new()
		ic.texture = UiIcons.icon(icon, 22)
		ic.modulate = opts.get("icon_color", UITheme.C_AMBER)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		_header.add_child(ic)
	title_label = Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title_label.add_theme_color_override("font_color", UITheme.C_TEXT)
	_header.add_child(title_label)
	if bool(opts.get("name_edit", false)):
		name_edit = LineEdit.new()
		name_edit.custom_minimum_size = Vector2(240, 0)
		name_edit.placeholder_text = "Design name"
		name_edit.text_submitted.connect(func(t: String) -> void: name_submitted.emit(t))
		name_edit.focus_exited.connect(func() -> void: name_submitted.emit(name_edit.text))
		_header.add_child(name_edit)
	# The checks' count ("2 to fix"), a button that scrolls the right column
	# to its top, where a designer keeps its checks. Hidden until set.
	badge = Button.new()
	badge.name = "ChecksBadge"
	badge.visible = false
	badge.focus_mode = Control.FOCUS_NONE
	badge.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	badge.pressed.connect(scroll_top)
	_header.add_child(badge)
	subtitle = Label.new()
	subtitle.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle.clip_text = true
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	subtitle.mouse_filter = Control.MOUSE_FILTER_PASS
	subtitle.mouse_entered.connect(func() -> void: subtitle.tooltip_text = subtitle.text)
	_header.add_child(subtitle)
	# The folded left column's button (hidden while the column shows).
	_left_btn = IconButton.make("panel-left", "", Callable(), str(opts.get("left_label", "Designs")))
	_left_btn.visible = false
	_left_btn.pressed.connect(_toggle_left_popup)
	_header.add_child(_left_btn)
	if bool(opts.get("undo", false)):
		undo_btn = IconButton.make("undo-2", "Undo (Ctrl+Z)", func() -> void: undo_requested.emit())
		_header.add_child(undo_btn)
		redo_btn = IconButton.make("redo-2", "Redo (Ctrl+Y)", func() -> void: redo_requested.emit())
		_header.add_child(redo_btn)
	_close_btn = IconButton.close(close)
	_header.add_child(_close_btn)

	# Body: three columns.
	_body = HBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_root.add_child(_body)
	var lc := _scroll_column(left_w)
	_left_scroll = lc[0]
	left = lc[1]
	_body.add_child(_left_scroll)
	centre = VBoxContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_body.add_child(centre)
	strip = HBoxContainer.new()
	strip.add_theme_constant_override("separation", UITheme.SPACE_SM)
	strip.visible = false
	centre.add_child(strip)
	_crumbs = HBoxContainer.new()
	_crumbs.add_theme_constant_override("separation", 2)
	_crumbs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.add_child(_crumbs)
	_mode_chip = PanelContainer.new()
	_mode_chip.add_theme_stylebox_override("panel", UITheme.chip_style(UITheme.C_AMBER))
	_mode_chip.visible = false
	_mode_lbl = Label.new()
	_mode_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_mode_lbl.add_theme_color_override("font_color", UITheme.C_AMBER)
	_mode_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_mode_chip.add_child(_mode_lbl)
	strip.add_child(_mode_chip)
	var rc := _scroll_column(right_w)
	_right_scroll = rc[0]
	right = rc[1]
	_body.add_child(_right_scroll)

	# Footer: hint + buttons.
	_footer_row = HBoxContainer.new()
	_footer_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_root.add_child(_footer_row)
	_hint = Label.new()
	_hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hint.visible = false
	_footer_row.add_child(_hint)
	footer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", UITheme.SPACE_SM)
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer_row.add_child(footer)

	# The folded left column's flyout: a panel over the body (not a Window —
	# an embedded popup's position runs through the window scale, a Control
	# shares the panel's canvas coordinates), with a click-catcher under it,
	# on its own CanvasLayer one above the shell's so the UI audit reads it as
	# a modal over a modal (UiAudit skips modal pairs on different layers)
	# rather than as text colliding with the column under it.
	_fly_layer = CanvasLayer.new()
	_fly_layer.name = "FlyoutLayer"
	add_child(_fly_layer)
	_left_catcher = Control.new()
	_left_catcher.name = "LeftFlyoutCatcher"
	_left_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_left_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_left_catcher.visible = false
	_left_catcher.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			hide_left_popup())
	_fly_layer.add_child(_left_catcher)
	_left_flyout = PanelContainer.new()
	_left_flyout.name = "LeftColumnFlyout"
	_left_flyout.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_PANEL_RAISED))
	_left_flyout.mouse_filter = Control.MOUSE_FILTER_STOP
	_left_flyout.visible = false
	_left_flyout.set_meta("ui_modal", true)
	_fly_layer.add_child(_left_flyout)
	resized.connect(_apply_layout)


func _scroll_column(width: float) -> Array:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(width, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(box)
	return [scroll, box]


# ---------------------------------------------------------------------------
# Words
# ---------------------------------------------------------------------------

func set_title(title: String, sub: String = "") -> void:
	title_label.text = title
	subtitle.text = sub


func set_subtitle(text: String) -> void:
	subtitle.text = text


## The one sentence of verbs under the body.
func set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = not text.is_empty() and not _short


## The header's checks badge: `text` "" hides it; `level` "error" | "warn" |
## "ok" colours it. A click scrolls the right column to the checks.
func set_badge(text: String, level: String = "warn", tip: String = "") -> void:
	if badge == null:
		return
	badge.visible = not text.is_empty()
	badge.text = text
	badge.tooltip_text = tip
	var c := UITheme.C_ERROR if level == "error" else (UITheme.C_WARN if level == "warn" else UITheme.C_OK)
	UITheme.style_button(badge)
	badge.add_theme_color_override("font_color", c)
	badge.add_theme_color_override("font_hover_color", c)


## An amber chip in the strip while a tool is armed; "" clears it.
func set_mode(text: String) -> void:
	_mode_lbl.text = text
	_mode_chip.visible = not text.is_empty()
	_sync_strip()


## The nested-selection path over the studio; [] clears it. The last crumb
## is the open level; earlier crumbs are buttons that emit `crumb_pressed`.
func set_crumbs(crumbs: Array) -> void:
	for c in _crumbs.get_children():
		_crumbs.remove_child(c)
		c.queue_free()
	for i in crumbs.size():
		if i > 0:
			var sep := Label.new()
			sep.text = "›"
			sep.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			_crumbs.add_child(sep)
		if i == crumbs.size() - 1:
			var l := Label.new()
			l.text = str(crumbs[i])
			l.add_theme_font_override("font", UITheme.font("semibold"))
			l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			l.add_theme_color_override("font_color", UITheme.C_TEXT)
			_crumbs.add_child(l)
		else:
			var b := Button.new()
			b.text = str(crumbs[i])
			b.flat = true
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			b.pressed.connect(func() -> void: crumb_pressed.emit(i))
			_crumbs.add_child(b)
	_sync_strip()


func _sync_strip() -> void:
	strip.visible = _mode_chip.visible or _crumbs.get_child_count() > 0


func set_undo_state(can_undo: bool, can_redo: bool) -> void:
	if undo_btn != null:
		undo_btn.disabled = not can_undo
	if redo_btn != null:
		redo_btn.disabled = not can_redo


## A footer button. PRIMARY is the accent, DESTRUCTIVE the error colour.
func add_button(text: String, kind: int, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 32)
	UITheme.style_button(b)
	match kind:
		PRIMARY:
			b.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		DESTRUCTIVE:
			b.add_theme_color_override("font_color", UITheme.C_ERROR)
	if cb.is_valid():
		b.pressed.connect(cb)
	footer.add_child(b)
	return b


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func open() -> void:
	if _is_open:
		return
	_is_open = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	CursorController.request_modal(modal_name, close)
	UiFit.keep_fitted(panel, want)
	var own := get_canvas_layer_node()
	_fly_layer.layer = (own.layer if own != null else 0) + 1
	_apply_layout()
	if not get_viewport().size_changed.is_connected(_apply_layout):
		get_viewport().size_changed.connect(_apply_layout)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	hide_left_popup()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	CursorController.release_modal(modal_name)
	closed.emit()


func is_open() -> bool:
	return _is_open


## Both columns back to the top (a reopen on another subject).
func scroll_top() -> void:
	if _left_scroll != null:
		_left_scroll.set_deferred("scroll_vertical", 0)
	if _right_scroll != null:
		_right_scroll.set_deferred("scroll_vertical", 0)


func is_folded() -> bool:
	return _folded


func _exit_tree() -> void:
	if _is_open:
		CursorController.release_modal(modal_name)


# ---------------------------------------------------------------------------
# The 720 rule
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	if not is_inside_tree() or not _is_open:
		return
	var vp := get_viewport().get_visible_rect().size
	var fold := vp.x < FOLD_W
	var short := vp.y < SHORT_H
	var changed := fold != _folded or short != _short
	_folded = fold
	_short = short
	# The left column: in the body, or in the header's popup.
	if fold and _left_scroll.get_parent() != _left_flyout:
		_body.remove_child(_left_scroll)
		_left_flyout.add_child(_left_scroll)
		_left_scroll.custom_minimum_size = Vector2(left_w, 0)
	elif not fold and _left_scroll.get_parent() != _body:
		hide_left_popup()
		_left_flyout.remove_child(_left_scroll)
		_body.add_child(_left_scroll)
		_body.move_child(_left_scroll, 0)
	if _left_flyout.visible:
		_place_flyout()
	_left_btn.visible = fold
	_right_scroll.custom_minimum_size = Vector2(RIGHT_W_NARROW if fold else right_w, 0)
	# The footer: its own row, or in the header.
	if short and footer.get_parent() != _header:
		_footer_row.remove_child(footer)
		_header.add_child(footer)
		_header.move_child(footer, _close_btn.get_index())
		footer.size_flags_horizontal = Control.SIZE_SHRINK_END
	elif not short and footer.get_parent() != _footer_row:
		_header.remove_child(footer)
		_footer_row.add_child(footer)
		footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.visible = not _hint.text.is_empty() and not short
	_footer_row.visible = not short
	if changed:
		layout_changed.emit(fold, short)


func _toggle_left_popup() -> void:
	if _left_flyout.visible:
		hide_left_popup()
		return
	_left_catcher.visible = true
	_left_flyout.visible = true
	_place_flyout()


## Under the header button, as tall as the column needs within the panel.
func _place_flyout() -> void:
	var r := _left_btn.get_global_rect()
	var pr := panel.get_global_rect()
	var avail := pr.end.y - r.end.y - 12.0
	var content_h := _left_scroll.get_combined_minimum_size().y
	var inner: Control = _left_scroll.get_child(0) if _left_scroll.get_child_count() > 0 else null
	if inner != null:
		content_h = inner.get_combined_minimum_size().y + 20.0
	var h := clampf(content_h, 120.0, maxf(avail, 160.0))
	var w := left_w + 24.0
	var x := clampf(r.position.x, pr.position.x, maxf(pr.end.x - w, pr.position.x))
	_left_flyout.global_position = Vector2(x, r.end.y + 4.0)
	_left_flyout.size = Vector2(w, h)


## Show the folded left column (for the harness / a tool that needs it).
func show_left_popup() -> void:
	if _folded and not _left_flyout.visible:
		_toggle_left_popup()


func hide_left_popup() -> void:
	if _left_flyout != null:
		_left_flyout.visible = false
	if _left_catcher != null:
		_left_catcher.visible = false


func left_popup_shown() -> bool:
	return _left_flyout != null and _left_flyout.visible
