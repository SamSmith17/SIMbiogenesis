extends Control
## Categorized component library panel for the right sidebar.
## Emits item_picked(preset, screen_pos) when the user presses an item button
## (system_graph_view distinguishes click vs drag from the subsequent input).

signal item_picked(preset: Dictionary, screen_pos: Vector2)

# ---------------------------------------------------------------------------
# Palette  (mirrors system_graph_view constants)
# ---------------------------------------------------------------------------
const C_BG      := Color(0.039, 0.055, 0.098, 1.0)
const C_SIDEBAR := Color(0.082, 0.114, 0.208, 1.0)
const C_PANEL   := Color(0.110, 0.145, 0.255, 1.0)
const C_BORDER  := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_TEXT    := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S  := Color(0.580, 0.639, 0.722, 1.0)
const C_TEXT_M  := Color(0.392, 0.447, 0.545, 1.0)

const _TOUCH_SCROLL_HANDLER := preload("res://system_graph/touch_scroll_handler.gd")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _scroll: ScrollContainer = null
var _touch_scroll: TouchScrollHandler = null
var _item_btns:    Array = []   # all item Buttons (for search filtering)
var _cat_contents: Array = []   # parallel: content PanelContainers
var _cat_expanded: Array = []   # parallel: bool (open/closed)
var _cat_headers:  Array = []   # parallel: header Buttons (for text update)
var _categories_vbox: VBoxContainer = null  # root vbox for appending runtime categories


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_process_input(true)
	_build()
	_touch_scroll = _TOUCH_SCROLL_HANDLER.new()
	_touch_scroll.bind(_scroll, self)


func _input(event: InputEvent) -> void:
	if not visible or _touch_scroll == null:
		return
	if _touch_scroll.handle(event):
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	_fill(root)
	add_child(root)

	root.add_child(_build_search_bar())
	root.add_child(_build_categories())


func _build_search_bar() -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color   = C_BG
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.border_color          = C_BORDER
	sb.content_margin_left   = 8.0
	sb.content_margin_right  = 8.0
	sb.content_margin_top    = 7.0
	sb.content_margin_bottom = 7.0
	pc.add_theme_stylebox_override("panel", sb)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	pc.add_child(hbox)

	var icon_lbl := Label.new()
	icon_lbl.text = "🔍"
	icon_lbl.add_theme_font_size_override("font_size", 13)
	hbox.add_child(icon_lbl)

	var edit := LineEdit.new()
	edit.placeholder_text       = "Search components..."
	edit.clear_button_enabled   = true
	edit.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_size_override("font_size", 11)
	edit.add_theme_color_override("font_color",             C_TEXT)
	edit.add_theme_color_override("font_placeholder_color", C_TEXT_M)

	var le_sb := StyleBoxFlat.new()
	le_sb.bg_color              = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.7)
	le_sb.border_color          = C_BORDER
	le_sb.set_border_width_all(1)
	le_sb.set_corner_radius_all(3)
	le_sb.content_margin_left   = 6.0
	le_sb.content_margin_right  = 6.0
	le_sb.content_margin_top    = 3.0
	le_sb.content_margin_bottom = 3.0
	edit.add_theme_stylebox_override("normal", le_sb)
	edit.add_theme_stylebox_override("focus",  le_sb)

	edit.text_changed.connect(_on_search)
	hbox.add_child(edit)
	return pc


func _build_categories() -> Control:
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical   = Control.SIZE_SHRINK_BEGIN
	vbox.add_theme_constant_override("separation", 0)
	scroll.add_child(vbox)
	_categories_vbox = vbox

	for i: int in ComponentPresets.CATEGORIES.size():
		var cat: Dictionary = ComponentPresets.CATEGORIES[i]
		_cat_expanded.append(true)
		vbox.add_child(_build_category(cat, i))

	return scroll


func _build_category(cat: Dictionary, idx: int) -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("separation", 0)

	# ---- Header button ----
	var hdr := Button.new()
	hdr.text       = "%s  %s  ▼" % [cat.get("icon", ""), cat.get("label", "")]
	hdr.focus_mode = Control.FOCUS_NONE
	hdr.alignment  = HORIZONTAL_ALIGNMENT_LEFT
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_cat_header_style(hdr)
	_cat_headers.append(hdr)

	# ---- Content panel ----
	var content_pc := PanelContainer.new()
	content_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var csb := StyleBoxFlat.new()
	csb.bg_color              = Color(0.0, 0.0, 0.0, 0.0)
	csb.content_margin_left   = 4.0
	csb.content_margin_right  = 4.0
	csb.content_margin_top    = 4.0
	csb.content_margin_bottom = 4.0
	content_pc.add_theme_stylebox_override("panel", csb)
	_cat_contents.append(content_pc)

	var content_vbox := VBoxContainer.new()
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_vbox.add_theme_constant_override("separation", 2)
	content_pc.add_child(content_vbox)

	# Toggle expand/collapse
	hdr.pressed.connect(func():
		_cat_expanded[idx] = not _cat_expanded[idx]
		content_pc.visible  = _cat_expanded[idx]
		_cat_headers[idx].text = "%s  %s  %s" % [
			cat.get("icon", ""), cat.get("label", ""),
			"▼" if _cat_expanded[idx] else "▶"
		]
	)

	# ---- Item buttons ----
	var presets: Array = cat.get("presets", [])
	for p: Dictionary in presets:
		var btn := _make_item_btn(p, idx)
		content_vbox.add_child(btn)
		_item_btns.append(btn)

	wrapper.add_child(hdr)
	wrapper.add_child(content_pc)
	return wrapper


func _make_item_btn(preset: Dictionary, cat_idx: int) -> Button:
	var lbl:       String = preset.get("label", "?")
	var icon:      String = preset.get("icon",  "")
	var hint:      String = _spec_hint(preset)
	var disabled:  bool  = bool(preset.get("disabled", false))

	var btn := Button.new()
	btn.text       = "%s %s\n    %s" % [icon, lbl, hint]
	btn.focus_mode = Control.FOCUS_NONE
	btn.alignment  = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.set_meta("search_label", lbl.to_lower())
	btn.set_meta("cat_idx", cat_idx)

	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color              = Color(0.0, 0.0, 0.0, 0.0)
	sb_n.set_border_width(SIDE_BOTTOM, 1)
	sb_n.border_color          = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.30)
	sb_n.content_margin_left   = 10.0
	sb_n.content_margin_right  =  8.0
	sb_n.content_margin_top    =  6.0
	sb_n.content_margin_bottom =  6.0

	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color     = C_PANEL
	sb_h.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.45)
	sb_h.set_border_width(SIDE_LEFT, 2)

	btn.add_theme_stylebox_override("normal",  sb_n)
	btn.add_theme_stylebox_override("hover",   sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	btn.add_theme_color_override("font_color", C_TEXT)
	btn.add_theme_font_size_override("font_size", 11)
	btn.disabled = disabled
	if disabled:
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if not disabled:
		btn.button_down.connect(_on_btn_down.bind(preset))

	return btn


func _on_btn_down(preset: Dictionary) -> void:
	var mp := get_viewport().get_mouse_position()
	item_picked.emit(preset, mp)


## Scene power consumers not yet placed on the graph — optional drag-to-add.
func populate_in_model(presets: Array) -> void:
	if _categories_vbox == null:
		return
	var old_cat: Node = _categories_vbox.get_node_or_null("InModelCategory")
	if old_cat != null:
		var ci: int = int(old_cat.get_meta("cat_idx", -1))
		if ci >= 0:
			var i := _item_btns.size() - 1
			while i >= 0:
				var b: Button = _item_btns[i] as Button
				if b != null and int(b.get_meta("cat_idx", -1)) == ci:
					_item_btns.remove_at(i)
				i -= 1
		old_cat.queue_free()
	var idx: int = _cat_expanded.size()
	_cat_expanded.append(true)
	var display_presets: Array = presets.duplicate()
	if display_presets.is_empty():
		display_presets.append({
			"type": "appliance",
			"label": "All scene loads are on the graph",
			"icon": "✓",
			"disabled": true,
			"specs": {},
		})
	var cat := {"label": "In Model", "icon": "🏗", "presets": display_presets}
	var cat_ctrl := _build_category(cat, idx)
	cat_ctrl.name = "InModelCategory"
	cat_ctrl.set_meta("cat_idx", idx)
	# Move In Model near the top (after built-in categories).
	_categories_vbox.add_child(cat_ctrl)
	_categories_vbox.move_child(cat_ctrl, mini(2, _categories_vbox.get_child_count() - 1))


## Back-compat alias.
func populate_scene_devices(presets: Array) -> void:
	populate_in_model(presets)


func populate_graph_linkables(presets: Array) -> void:
	if _categories_vbox == null or presets.is_empty():
		return
	var old_cat: Node = _categories_vbox.get_node_or_null("GraphLinkablesCategory")
	if old_cat != null:
		var ci: int = int(old_cat.get_meta("cat_idx", -1))
		if ci >= 0:
			var i := _item_btns.size() - 1
			while i >= 0:
				var b: Button = _item_btns[i] as Button
				if b != null and int(b.get_meta("cat_idx", -1)) == ci:
					_item_btns.remove_at(i)
				i -= 1
		old_cat.queue_free()
	var idx: int = _cat_expanded.size()
	_cat_expanded.append(true)
	var cat := {"label": "Scene Objects (3D)", "icon": "🌍", "presets": presets}
	var cat_ctrl := _build_category(cat, idx)
	cat_ctrl.name = "GraphLinkablesCategory"
	cat_ctrl.set_meta("cat_idx", idx)
	_categories_vbox.add_child(cat_ctrl)


# ---------------------------------------------------------------------------
# Spec hint (second line of item button)
# ---------------------------------------------------------------------------

func _spec_hint(preset: Dictionary) -> String:
	var specs: Dictionary = preset.get("specs", {})
	match preset.get("type", ""):
		"panel":
			return "%.0f W  •  $%.0f" % [
				float(specs.get("wmp",  0.0)),
				float(specs.get("cost", 0.0))]
		"battery":
			return "%.0fV  %.0f Ah  •  $%.0f" % [
				float(specs.get("voltage", 0.0)),
				float(specs.get("ah",      0.0)),
				float(specs.get("cost",    0.0))]
		"controller":
			return "%.0f A  •  $%.0f" % [
				float(specs.get("max_charge_amps", 0.0)),
				float(specs.get("cost",            0.0))]
		"appliance", "acload":
			return "%.0f W avg" % float(specs.get("avg_watts", specs.get("max_watts", 0.0)))
		"processor":
			return "%.0f W" % float(specs.get("watts", 0.0))
		"resource":
			return ResourceKinds.display_name(str(specs.get("resource_kind", "water")))
		"catchment":
			return "%.0f m²" % float(specs.get("area_m2", 0.0))
		_:
			return ""


# ---------------------------------------------------------------------------
# Search / filter
# ---------------------------------------------------------------------------

func _on_search(text: String) -> void:
	var term := text.to_lower().strip_edges()
	var cat_has_match: Array = []
	for _i in _cat_contents.size():
		cat_has_match.append(false)

	for btn: Button in _item_btns:
		var search_label: String = btn.get_meta("search_label", "") as String
		var show: bool = term.is_empty() or search_label.contains(term)
		btn.visible = show
		if show:
			var ci: int = int(btn.get_meta("cat_idx", 0))
			if ci < cat_has_match.size():
				cat_has_match[ci] = true

	for i: int in _cat_contents.size():
		if term.is_empty():
			_cat_contents[i].visible = _cat_expanded[i]
		else:
			_cat_contents[i].visible = cat_has_match[i]
			# Auto-expand if matches found, update header arrow
			if cat_has_match[i] and not _cat_expanded[i]:
				_cat_expanded[i] = true
				_refresh_header(i)


func _refresh_header(idx: int) -> void:
	if idx >= _cat_headers.size():
		return
	var cat: Dictionary = ComponentPresets.CATEGORIES[idx]
	_cat_headers[idx].text = "%s  %s  %s" % [
		cat.get("icon", ""), cat.get("label", ""),
		"▼" if _cat_expanded[idx] else "▶"
	]


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

func _apply_cat_header_style(btn: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(C_PANEL.r * 0.80, C_PANEL.g * 0.80, C_PANEL.b * 0.80, 1.0)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.border_color          = C_BORDER
	sb.content_margin_left   = 10.0
	sb.content_margin_right  =  8.0
	sb.content_margin_top    =  8.0
	sb.content_margin_bottom =  8.0
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = C_PANEL
	btn.add_theme_stylebox_override("normal",  sb)
	btn.add_theme_stylebox_override("hover",   sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	btn.add_theme_color_override("font_color",      C_TEXT_S)
	btn.add_theme_font_size_override("font_size", 11)


func _fill(ctrl: Control) -> void:
	ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
