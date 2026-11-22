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
##   - a footer: the buttons (PRIMARY / SECONDARY / DESTRUCTIVE, as
##     ModalFrame). The verbs (`set_hint`, " · " between them) are a "?"
##     button in the header that opens them as a shortcut card;
##   - flyouts (`add_flyout_button`): a strip button that opens a searchable
##     panel over the body. Parts bins and tool palettes live there, so the
##     left column stays navigation ("adding things is a mode").
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
var _footer_sep: HSeparator = null
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
var _help_btn: Button = null
var _pop_catcher: Control = null
var _pop: PanelContainer = null
var _pop_box: VBoxContainer = null
var _pops: Dictionary = {}
var _pop_id := ""
var _is_open := false
var _folded := false
var _short := false
var _portrait := false
var _vsplit: VSplitContainer = null
var _vsplit_seeded := false
var _claimed_cursor_modal := false


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
	panel.add_theme_stylebox_override("panel", UITheme.modal_panel_style(0.99))
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
	_help_btn = IconButton.make("circle-help", "Shortcuts and how to use this", func() -> void: toggle_flyout("help"))
	_help_btn.name = "HelpButton"
	_help_btn.visible = false
	_header.add_child(_help_btn)
	if bool(opts.get("undo", false)):
		undo_btn = IconButton.make("undo-2", "Undo (Ctrl+Z)", func() -> void: undo_requested.emit())
		_header.add_child(undo_btn)
		redo_btn = IconButton.make("redo-2", "Redo (Ctrl+Y)", func() -> void: redo_requested.emit())
		_header.add_child(redo_btn)
	_close_btn = IconButton.close(close)
	_header.add_child(_close_btn)
	_root.add_child(HSeparator.new())

	# Body: three columns in landscape; VSplitContainer (3D studio top, right
	# charts/controls bottom, left folded into header) on portrait monitors.
	_body = HBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_root.add_child(_body)
	_vsplit = VSplitContainer.new()
	_vsplit.name = "PortraitSplit"
	_vsplit.visible = false
	_vsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vsplit.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_body.add_child(_vsplit)
	var lc := _scroll_column(left_w)
	_left_scroll = lc[0]
	_left_scroll.name = "LeftColumn"
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
	_right_scroll.name = "RightColumn"
	right = rc[1]
	_body.add_child(_right_scroll)

	# Footer: hint + buttons.
	_footer_sep = HSeparator.new()
	_root.add_child(_footer_sep)
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
	# The generic flyout (help card, Add palettes): same construction.
	_pop_catcher = Control.new()
	_pop_catcher.name = "FlyoutCatcher"
	_pop_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pop_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_pop_catcher.visible = false
	_pop_catcher.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			hide_flyout())
	_fly_layer.add_child(_pop_catcher)
	_pop = PanelContainer.new()
	_pop.name = "Flyout"
	_pop.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_PANEL_RAISED))
	_pop.mouse_filter = Control.MOUSE_FILTER_STOP
	_pop.visible = false
	_pop.set_meta("ui_modal", true)
	_fly_layer.add_child(_pop)
	_pop_box = VBoxContainer.new()
	_pop.add_child(_pop_box)
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


## The verbs, " · " between them. They open from the header's "?" as a
## shortcut card (they used to be one clipped line under the body).
func set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = false
	_help_btn.visible = not text.is_empty()
	if _pop_id == "help":
		_fill_help()


func hint_text() -> String:
	return _hint.text


func _fill_help() -> void:
	var box: VBoxContainer = (_pops["help"] as Dictionary)["content"]
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	box.add_child(SectionHeader.make("How to use this", "circle-help"))
	for part in _hint.text.split(" · ", false):
		var l := Label.new()
		l.text = str(part).strip_edges()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT)
		l.custom_minimum_size = Vector2(300, 0)
		box.add_child(l)


# --- flyouts ----------------------------------------------------------------

## A strip button that opens `content` as a panel over the body. `opts`:
## `tip`, `width` (340), `search` (a box that filters the buttons inside by
## their text and tooltip; off for content with its own search),
## `close_on_pick` (a button press inside closes it; Shift keeps it open).
func add_flyout_button(id: String, text: String, icon: String, content: Control, opts: Dictionary = {}) -> Button:
	var b := IconButton.make(icon, str(opts.get("tip", "")), Callable(), text)
	b.name = "flyout_%s" % id
	b.flat = false
	UITheme.style_button(b)
	b.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	b.add_theme_color_override("icon_normal_color", UITheme.C_PRIMARY)
	b.pressed.connect(func() -> void: toggle_flyout(id))
	strip.add_child(b)
	strip.move_child(b, 0)
	_register_flyout(id, content, b, opts)
	_sync_strip()
	return b


## A flyout opened by the caller's OWN button (`anchor`, anywhere in the
## shell): connect its press to `toggle_flyout(id)`.
func add_flyout(id: String, content: Control, anchor: Control, opts: Dictionary = {}) -> void:
	_register_flyout(id, content, anchor, opts)


func _register_flyout(id: String, content: Control, anchor: Control, opts: Dictionary) -> void:
	var wrap := VBoxContainer.new()
	wrap.name = "flyout_body_%s" % id
	wrap.visible = false
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_theme_constant_override("separation", UITheme.SPACE_XS)
	var search: LineEdit = null
	if bool(opts.get("search", false)):
		search = LineEdit.new()
		search.name = "flyout_search"
		search.placeholder_text = str(opts.get("placeholder", "Search"))
		search.clear_button_enabled = true
		search.right_icon = UiIcons.icon("search", 14)
		search.text_changed.connect(func(t: String) -> void: _filter_flyout(content, t))
		wrap.add_child(search)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_child(scroll)
	if content.get_parent() != null:
		content.get_parent().remove_child(content)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	_pop_box.add_child(wrap)
	# true = any button inside; a String = only buttons whose name starts so.
	var pick: Variant = opts.get("close_on_pick", false)
	if (pick is bool and pick) or pick is String:
		for n in content.find_children("*", "BaseButton", true, false):
			if pick is String and not str(n.name).begins_with(str(pick)):
				continue
			(n as BaseButton).pressed.connect(func() -> void:
				if not Input.is_key_pressed(KEY_SHIFT):
					hide_flyout())
	_pops[id] = {"wrap": wrap, "content": content, "anchor": anchor, "search": search,
		"width": float(opts.get("width", 340.0)), "scroll": scroll}


func toggle_flyout(id: String) -> void:
	if _pop_id == id:
		hide_flyout()
	else:
		show_flyout(id)


func show_flyout(id: String) -> void:
	if id == "help" and not _pops.has("help"):
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", UITheme.SPACE_XS)
		_register_flyout("help", box, _help_btn, {"width": 340.0})
	if not _pops.has(id):
		return
	hide_left_popup()
	for k in _pops:
		((_pops[k] as Dictionary)["wrap"] as Control).visible = k == id
	_pop_id = id
	if id == "help":
		_fill_help()
	_pop_catcher.visible = true
	_pop.visible = true
	_place_pop()
	UITheme.animate_open(_pop)
	var s: Variant = (_pops[id] as Dictionary)["search"]
	if s is LineEdit:
		(s as LineEdit).grab_focus()


func hide_flyout() -> void:
	_pop_id = ""
	if _pop != null:
		_pop.visible = false
	if _pop_catcher != null:
		_pop_catcher.visible = false


## The id of the flyout that is up ("" = none).
func flyout_shown() -> String:
	return _pop_id


func flyout_scroll(id: String) -> ScrollContainer:
	return (_pops[id] as Dictionary)["scroll"] as ScrollContainer if _pops.has(id) else null


func _place_pop() -> void:
	if _pop_id.is_empty():
		return
	var info: Dictionary = _pops[_pop_id]
	var anchor := info["anchor"] as Control
	var r := anchor.get_global_rect()
	var pr := panel.get_global_rect()
	var content := info["content"] as Control
	var w := float(info["width"])
	var extra := 60.0 if info["search"] != null else 24.0
	var avail := maxf(pr.end.y - r.end.y - 12.0, 160.0)
	var h := clampf(content.get_combined_minimum_size().y + extra, 80.0, avail)
	var x := clampf(r.position.x, pr.position.x, maxf(pr.end.x - w, pr.position.x))
	_pop.global_position = Vector2(x, r.end.y + 4.0)
	_pop.size = Vector2(w, h)


## Buttons whose text or tooltip hold every word stay; a group (a container
## of buttons) with none left goes, and so does the header before it.
func _filter_flyout(content: Control, query: String) -> void:
	var words := query.to_lower().split(" ", false)
	for n in content.find_children("*", "BaseButton", true, false):
		var b := n as BaseButton
		var text := (str(b.get("text")) + " " + b.tooltip_text).to_lower()
		var ok := true
		for w in words:
			if not text.contains(w):
				ok = false
				break
		b.visible = ok
	var header: Control = null
	for c in content.get_children():
		if not (c is Control):
			continue
		if c is Container and not (c is SectionHeader):
			var any := false
			for n in c.find_children("*", "BaseButton", true, false):
				if (n as BaseButton).visible:
					any = true
					break
			(c as Control).visible = any
			if header != null:
				header.visible = any
			header = null
		else:
			header = c as Control
	_place_pop.call_deferred()


func _input(e: InputEvent) -> void:
	if _pop_id.is_empty() or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if ke.pressed and not ke.echo and ke.keycode == KEY_ESCAPE:
		hide_flyout()
		get_viewport().set_input_as_handled()


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
## A control in the header row, after the checks badge (the labs' power
## chain bar).
func add_header_widget(c: Control) -> void:
	_header.add_child(c)
	_header.move_child(c, badge.get_index() + 1)


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
	var has_fly := false
	for k in _pops:
		var an: Control = (_pops[k] as Dictionary)["anchor"]
		if an != null and an.get_parent() == strip:
			has_fly = true
	strip.visible = _mode_chip.visible or _crumbs.get_child_count() > 0 or has_fly
	# The chip's label ellipsizes (minimum width 0), so it must expand too, or
	# an empty breadcrumb row takes the whole strip and the chip is a dot.
	_mode_chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_crumbs.size_flags_horizontal = Control.SIZE_EXPAND_FILL if _crumbs.get_child_count() > 0 else Control.SIZE_SHRINK_BEGIN


func set_undo_state(can_undo: bool, can_redo: bool) -> void:
	if undo_btn != null:
		undo_btn.disabled = not can_undo
	if redo_btn != null:
		redo_btn.disabled = not can_redo


## A footer button. PRIMARY is filled in the accent, DESTRUCTIVE in the error colour.
func add_button(text: String, kind: int, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 32)
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
	return b


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

## The footer's verbs in ONE order in every designer:
## Save · Export · Apply · Place · Build with a crew · Close.
## Anything else keeps its place ahead of them.
static func verb_rank(text: String) -> int:
	var t := text.strip_edges().to_lower()
	for lead in ["👷 ", "⊕ ", "✓ "]:
		t = t.trim_prefix(lead)
	if t.begins_with("save"):
		return 0
	if t.begins_with("export"):
		return 1
	if t.begins_with("apply"):
		return 2
	if t.begins_with("place"):
		return 3
	if t.begins_with("build with a crew") or t.begins_with("queue build"):
		return 4
	if t == "close" or t == "done":
		return 9
	return -1


static func order_verbs(row: Container) -> void:
	if row == null:
		return
	var kids := row.get_children()
	var ranked: Array = []
	for i in kids.size():
		var r := verb_rank((kids[i] as Button).text) if kids[i] is Button else -1
		ranked.append([r, i, kids[i]])
	ranked.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	for i in ranked.size():
		row.move_child(ranked[i][2], i)


func open() -> void:
	if _is_open:
		return
	_is_open = true
	order_verbs(footer)
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	var in_secondary := UiFit.is_secondary_window(self)
	_claimed_cursor_modal = not in_secondary
	if _claimed_cursor_modal:
		CursorController.request_modal(modal_name, close)
	_backdrop.color = UITheme.C_BG if in_secondary else Color(0, 0, 0, 0.55)
	# The fold rule (below) is about the SCREEN: where it has FOLD_W x SHORT_H
	# to give, the zoom never takes the panel's logical size under them.
	panel.set_meta("ui_fit_fullscreen", true)
	panel.set_meta("ui_fit_min_logical", Vector2(FOLD_W, SHORT_H))
	UiFit.keep_fitted(panel, want)
	var own := get_canvas_layer_node()
	_fly_layer.layer = (own.layer if own != null else 0) + 1
	_apply_layout()
	if not in_secondary:
		UITheme.animate_open(panel, _backdrop)
	if not get_viewport().size_changed.is_connected(_apply_layout):
		get_viewport().size_changed.connect(_apply_layout)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	hide_left_popup()
	hide_flyout()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _claimed_cursor_modal:
		CursorController.release_modal(modal_name)
		_claimed_cursor_modal = false
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


## Short screen: the footer has joined the header row.
func is_short() -> bool:
	return _short


## Portrait screen: 3D studio stacked on top, right column stacked below.
func is_portrait_layout() -> bool:
	return _portrait


func _exit_tree() -> void:
	if _is_open and _claimed_cursor_modal:
		CursorController.release_modal(modal_name)
		_claimed_cursor_modal = false


# ---------------------------------------------------------------------------
# The 720 rule + Portrait vertical split
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	if not is_inside_tree() or not _is_open:
		return
	# The fold rule reads the panel's LOGICAL size: full screen, it is the
	# screen divided by the zoom UiFit gives it.
	var vp := UiFit.fill_logical_size(panel, want) if UiFit.fills_screen(want) else get_viewport().get_visible_rect().size
	var portrait := vp.y > vp.x * 1.05
	# Half a pixel of slack: 1920 / 1.2 is 1599.9999 in float.
	var fold := portrait or (vp.x < FOLD_W - 0.5)
	var short := (not portrait) and (vp.y < SHORT_H - 0.5)
	var changed := fold != _folded or short != _short or portrait != _portrait
	_folded = fold
	_short = short
	_portrait = portrait
	# The left column: in the body, or in the header's popup.
	if fold and _left_scroll.get_parent() != _left_flyout:
		if _left_scroll.get_parent() != null:
			_left_scroll.get_parent().remove_child(_left_scroll)
		_left_flyout.add_child(_left_scroll)
		_left_scroll.custom_minimum_size = Vector2(left_w, 0)
	elif not fold and _left_scroll.get_parent() != _body:
		hide_left_popup()
		if _left_scroll.get_parent() != null:
			_left_scroll.get_parent().remove_child(_left_scroll)
		_body.add_child(_left_scroll)
		_body.move_child(_left_scroll, 0)
	# Portrait vertical split: 3D studio + strip on top, charts/controls below.
	if portrait and centre.get_parent() != _vsplit:
		if centre.get_parent() != null:
			centre.get_parent().remove_child(centre)
		if _right_scroll.get_parent() != null:
			_right_scroll.get_parent().remove_child(_right_scroll)
		_vsplit.add_child(centre)
		_vsplit.add_child(_right_scroll)
		_vsplit.visible = true
		centre.custom_minimum_size = Vector2(0, 260)
		_right_scroll.custom_minimum_size = Vector2(0, 240)
		_right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if not _vsplit_seeded:
			_vsplit_seeded = true
			_vsplit.split_offset = int(clampf((vp.y - 120.0) * 0.44 - 260.0, 0.0, 600.0))
	elif not portrait and centre.get_parent() == _vsplit:
		_vsplit.remove_child(centre)
		_vsplit.remove_child(_right_scroll)
		_vsplit.visible = false
		_body.add_child(centre)
		_body.add_child(_right_scroll)
		if not fold and _left_scroll.get_parent() == _body:
			_body.move_child(_left_scroll, 0)
		centre.custom_minimum_size = Vector2.ZERO
		_right_scroll.size_flags_horizontal = Control.SIZE_FILL
	if _left_flyout.visible:
		_place_flyout()
	if _pop.visible:
		_place_pop()
	_left_btn.visible = fold
	if not portrait:
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
	_hint.visible = false
	_footer_row.visible = not short
	if _footer_sep != null:
		_footer_sep.visible = not short
	if changed:
		layout_changed.emit(fold, short)


func _toggle_left_popup() -> void:
	if _left_flyout.visible:
		hide_left_popup()
		return
	hide_flyout()
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
