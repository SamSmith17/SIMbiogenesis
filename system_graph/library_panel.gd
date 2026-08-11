extends Control
## Categorized component library panel for the right sidebar.
## Emits item_picked(preset, screen_pos) when the user presses an item button
## (system_graph_view distinguishes click vs drag from the subsequent input).

signal item_picked(preset: Dictionary, screen_pos: Vector2)
## Emitted when a model-linked preset's "Place Model" button is pressed. The
## graph view closes and starts a ghost placement of the linked 3D model.
signal place_model_requested(preset: Dictionary)
## Emitted right after a user-authored preset is saved via "Create Custom
## Component" — unlike item_picked (which only arms a click/drag-to-place
## gesture), this is a direct "spawn it now" request since Create has no
## ambiguous click-vs-drag input to disambiguate.
signal custom_component_created(preset: Dictionary)

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
	ComponentPresets.load_user_presets()
	_build()
	_touch_scroll = _TOUCH_SCROLL_HANDLER.new()
	_touch_scroll.bind(_scroll, self)
	call_deferred("_refresh_scroll_content_height")


func rebuild() -> void:
	for child in get_children():
		child.queue_free()
	_item_btns.clear()  # buttons live under the freed tree — drop the refs
	_cat_expanded.clear()
	_cat_contents.clear()
	_cat_headers.clear()
	_build()


## While a tutorial level restricts the palette, the director installs a
## Callable(preset: Dictionary) -> bool here; it overrides the global
## ProgressStore unlocks (a level may hand out a preset whose category the
## player hasn't earned yet). Invalid Callable = inactive.
var tutorial_preset_filter: Callable = Callable()


## Re-apply unlock gating (after a ProgressStore grant / skip-tutorial /
## tutorial filter change). Full rebuild — the panel is cheap.
func refresh_gating() -> void:
	rebuild()
	call_deferred("_refresh_scroll_content_height")


func _is_category_unlocked(cat_id: String) -> bool:
	return ProgressStore.is_unlocked("category", cat_id)


## Presets of a category that survive gating: the tutorial filter when active,
## else the player's global unlocks.
func _visible_presets_for(cat_id: String) -> Array:
	var out: Array = []
	for p: Dictionary in ComponentPresets.presets_for_category(cat_id):
		if tutorial_preset_filter.is_valid():
			if not bool(tutorial_preset_filter.call(p)):
				continue
		elif not ProgressStore.is_unlocked("preset", str(p.get("label", ""))):
			continue
		out.append(p)
	return out


func _gui_input(event: InputEvent) -> void:
	if _scroll == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		var step := int(32.0 * mb.factor)
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll.scroll_vertical = maxi(0, _scroll.scroll_vertical - step)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var vbar := _scroll.get_v_scroll_bar()
			var max_v := int(vbar.max_value) if vbar != null else 99999
			_scroll.scroll_vertical = mini(max_v, _scroll.scroll_vertical + step)
			accept_event()


func _refresh_scroll_content_height() -> void:
	if _categories_vbox == null:
		return
	var h := 0.0
	for child in _categories_vbox.get_children():
		h += child.get_minimum_size().y
	_categories_vbox.custom_minimum_size.y = maxf(h, _scroll.size.y + 1.0)


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
	root.add_child(_build_custom_creator())
	root.add_child(_build_categories())


func _build_custom_creator() -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.4)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.border_color = C_BORDER
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	pc.add_theme_stylebox_override("panel", sb)
	
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	pc.add_child(vbox)
	
	var lbl := Label.new()
	lbl.text = "🆕 Create Custom Component"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	vbox.add_child(lbl)
	
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	vbox.add_child(hbox)
	
	var type_opt := OptionButton.new()
	type_opt.focus_mode = Control.FOCUS_NONE
	type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_opt.add_theme_font_size_override("font_size", 10)
	
	var types := [
		{"label": "Solar Panel", "id": "panel"},
		{"label": "Wind Turbine", "id": "wind"},
		{"label": "Hydro Turbine", "id": "hydro"},
		{"label": "Battery", "id": "battery"},
		{"label": "Controller", "id": "controller"},
		{"label": "Appliance / Load", "id": "appliance"},
		{"label": "Population", "id": "habitat"},
		{"label": "Processor", "id": "processor"},
		{"label": "Resource Container", "id": "resource"},
		{"label": "Rain Catchment", "id": "catchment"},
		{"label": "Circuit Monitor", "id": "shelly4pm"},
		{"label": "Spiderbox", "id": "spiderbox"},
		{"label": "Breaker Panel", "id": "breaker_panel"},
	]
	
	for i in types.size():
		type_opt.add_item(types[i].label, i)
	type_opt.select(0)
	hbox.add_child(type_opt)
	
	var name_ed := LineEdit.new()
	name_ed.placeholder_text = "Name..."
	name_ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_ed.add_theme_font_size_override("font_size", 10)
	
	var le_sb := StyleBoxFlat.new()
	le_sb.bg_color              = Color(C_BG.r, C_BG.g, C_BG.b, 0.7)
	le_sb.border_color          = C_BORDER
	le_sb.set_border_width_all(1)
	le_sb.set_corner_radius_all(3)
	le_sb.content_margin_left   = 6.0
	le_sb.content_margin_right  = 6.0
	le_sb.content_margin_top    = 3.0
	le_sb.content_margin_bottom = 3.0
	name_ed.add_theme_stylebox_override("normal", le_sb)
	name_ed.add_theme_stylebox_override("focus", le_sb)
	
	hbox.add_child(name_ed)
	
	var create_btn := Button.new()
	create_btn.text = " Create "
	create_btn.focus_mode = Control.FOCUS_NONE
	create_btn.add_theme_font_size_override("font_size", 10)
	create_btn.pressed.connect(func() -> void:
		var name_val := name_ed.text.strip_edges()
		if name_val.is_empty():
			return
		var type_idx := maxi(type_opt.selected, 0)
		var itype := str(types[type_idx].id)

		var preset := ComponentPresets.create_default_preset(itype, name_val)
		var cat_id := ComponentPresets._category_id_for_type_static(itype)

		ComponentPresets.save_user_preset(cat_id, preset)

		name_ed.text = ""
		rebuild()
		# Place it immediately — a definitive click, not the click-vs-drag
		# gesture item_picked exists to disambiguate for library items.
		custom_component_created.emit(preset)
	)
	hbox.add_child(create_btn)
	
	return pc


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

	# Unlock gating (Solar Bootcamp): locked categories are skipped entirely;
	# with no progress file everything is unlocked (grandfathering) and this
	# loop builds exactly what it always built. `built` (not the CATEGORIES
	# index) keys the parallel _cat_* arrays so skipped entries can't skew them.
	var filter_active := tutorial_preset_filter.is_valid()
	var built: int = 0
	for i: int in ComponentPresets.CATEGORIES.size():
		var cat: Dictionary = ComponentPresets.CATEGORIES[i]
		var cat_id := str(cat.get("id", ""))
		if not filter_active and not _is_category_unlocked(cat_id):
			continue
		var presets := _visible_presets_for(cat_id)
		if presets.is_empty() and cat_id != "my_components":
			# Fully filtered out (tutorial palette or per-preset locks) — an
			# empty header row is just noise.
			if filter_active or ComponentPresets.presets_for_category(cat_id).size() > 0:
				continue
		var expanded := built <= 1  # first two open; rest collapsed
		_cat_expanded.append(expanded)
		vbox.add_child(_build_category(cat, built, presets))
		_cat_contents[built].visible = expanded
		_cat_headers[built].text = "%s  %s  %s" % [
			cat.get("icon", ""), cat.get("label", ""), "▼" if expanded else "▶"
		]
		built += 1

	scroll.follow_focus = true
	return scroll


func _build_category(cat: Dictionary, idx: int, presets_override: Variant = null) -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("separation", 0)

	# ---- Header button ----
	var hdr := Button.new()
	hdr.text       = "%s  %s  ▼" % [cat.get("icon", ""), cat.get("label", "")]
	hdr.focus_mode = Control.FOCUS_NONE
	hdr.alignment  = HORIZONTAL_ALIGNMENT_LEFT
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# _cat_headers is keyed by the BUILT index (locked categories are skipped,
	# runtime categories appended past CATEGORIES' end), so the catalog row can
	# never be re-derived from a header index — carry the display bits on the
	# button itself for _refresh_header.
	hdr.set_meta("cat_icon", str(cat.get("icon", "")))
	hdr.set_meta("cat_label", str(cat.get("label", "")))
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

	# ---- Item buttons ---- (built-ins merged with any user-saved overrides —
	# see ComponentPresets.presets_for_category, since CATEGORIES' own
	# "presets" arrays are const/read-only and can't carry user edits).
	var cat_id_str := str(cat.get("id", ""))
	var presets: Array = presets_override if presets_override is Array \
			else ComponentPresets.presets_for_category(cat_id_str)
	for p: Dictionary in presets:
		if cat_id_str == "my_components":
			content_vbox.add_child(_make_user_component_row(p, idx))
		else:
			content_vbox.add_child(_make_item_row(p, idx))
	if cat_id_str == "my_components" and presets.is_empty():
		var hint := Label.new()
		hint.text = "Group nodes, then Inspector → Save as Component."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 10)
		hint.add_theme_color_override("font_color", C_TEXT_M)
		content_vbox.add_child(hint)

	wrapper.add_child(hdr)
	wrapper.add_child(content_pc)
	return wrapper


## One library row. Normally just the drag/click spawn button; for presets that
## carry a `specs.model_id` (a 3D-linked component such as the VAWT), a compact
## "Place in world" button is appended that emits place_model_requested.
func _make_item_row(preset: Dictionary, cat_idx: int) -> Control:
	var btn := _make_item_btn(preset, cat_idx)
	_item_btns.append(btn)
	# Component (super-node) presets spawn subgraphs, not a single 3D prop, so
	# they get no Place button. Every other preset can be placed — those without
	# a bespoke GLB place a procedural gray-box placeholder (F).
	if _is_component_preset(preset):
		return btn
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	var pb := _make_place_btn(preset)
	if str((preset.get("specs", {}) as Dictionary).get("model_id", "")).is_empty():
		pb.tooltip_text = "Place a gray-box placeholder for this node in the world"
	row.add_child(pb)
	return row


## True for a compound/super-node preset (has a child scope / component tree),
## which can't be represented as a single placed prop.
func _is_component_preset(preset: Dictionary) -> bool:
	if str(preset.get("type", "")) == "compound":
		return true
	return preset.has("component_tree") or preset.has("definition_id") \
			or preset.has("def_id")


## A "My Components" row: the spawn button plus compact Rename / Delete actions
## (user-authored, so editable — built-in components live under Super-nodes).
func _make_user_component_row(preset: Dictionary, cat_idx: int) -> Control:
	var btn := _make_item_btn(preset, cat_idx)
	_item_btns.append(btn)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(btn)
	var label := str(preset.get("label", ""))
	var ren := Button.new()
	ren.text = "✎"
	ren.tooltip_text = "Rename component"
	ren.focus_mode = Control.FOCUS_NONE
	ren.custom_minimum_size = Vector2(30.0, 0.0)
	ren.pressed.connect(func(): _rename_user_component(label))
	row.add_child(ren)
	var del := Button.new()
	del.text = "🗑"
	del.tooltip_text = "Delete component"
	del.focus_mode = Control.FOCUS_NONE
	del.custom_minimum_size = Vector2(30.0, 0.0)
	del.pressed.connect(func():
		ComponentPresets.remove_user_preset("my_components", label)
		rebuild())
	row.add_child(del)
	return row


func _rename_user_component(old_label: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Rename Component"
	var le := LineEdit.new()
	le.text = old_label
	le.custom_minimum_size = Vector2(260, 0)
	le.select_all()
	dlg.add_child(le)
	dlg.register_text_enter(le)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var nm := le.text.strip_edges()
		if not nm.is_empty() and nm != old_label:
			var entries := ComponentPresets.presets_for_category("my_components")
			for e_v in entries:
				var e := e_v as Dictionary
				if str(e.get("label", "")) == old_label:
					var ne := e.duplicate(true)
					ne["label"] = nm
					ComponentPresets.remove_user_preset("my_components", old_label)
					ComponentPresets.save_user_preset("my_components", ne)
					break
			rebuild()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	le.grab_focus()


func _make_place_btn(preset: Dictionary) -> Button:
	var pb := Button.new()
	pb.text = "🌍\nPlace"
	pb.tooltip_text = "Place the 3D model in the world"
	pb.focus_mode = Control.FOCUS_NONE
	pb.custom_minimum_size = Vector2(44.0, 0.0)
	pb.add_theme_font_size_override("font_size", 10)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.16)
	sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.32)
	pb.add_theme_stylebox_override("normal", sb)
	pb.add_theme_stylebox_override("hover", sb_h)
	pb.add_theme_stylebox_override("pressed", sb_h)
	pb.add_theme_color_override("font_color", C_PRIMARY)
	pb.pressed.connect(func() -> void: place_model_requested.emit(preset))
	return pb


func _make_item_btn(preset: Dictionary, cat_idx: int) -> Button:
	var lbl:       String = preset.get("label", "?")
	var icon:      String = preset.get("icon",  "")
	var hint:      String = _spec_hint(preset)
	var disabled:  bool  = bool(preset.get("disabled", false))

	var btn := Button.new()
	btn.text       = "%s  %s" % [icon, lbl] if hint.is_empty() else "%s  %s\n%s" % [icon, lbl, hint]
	btn.focus_mode = Control.FOCUS_NONE
	btn.alignment  = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size.y = 36.0
	btn.set_meta("search_label", lbl.to_lower())
	btn.set_meta("cat_idx", cat_idx)

	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color              = Color(C_BG.r, C_BG.g, C_BG.b, 0.35)
	sb_n.set_corner_radius_all(4)
	sb_n.set_border_width_all(1)
	sb_n.border_color          = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.40)
	sb_n.content_margin_left   = 10.0
	sb_n.content_margin_right  =  8.0
	sb_n.content_margin_top    =  7.0
	sb_n.content_margin_bottom =  7.0

	var sb_h := sb_n.duplicate() as StyleBoxFlat
	sb_h.bg_color     = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.95)
	sb_h.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.65)
	sb_h.set_border_width(SIDE_LEFT, 3)

	var sb_p := sb_h.duplicate() as StyleBoxFlat
	sb_p.bg_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.18)

	btn.add_theme_stylebox_override("normal",  sb_n)
	btn.add_theme_stylebox_override("hover",   sb_h)
	btn.add_theme_stylebox_override("pressed", sb_p)
	btn.add_theme_color_override("font_color", C_TEXT)
	btn.add_theme_font_size_override("font_size", 12)
	btn.disabled = disabled
	if disabled:
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.modulate = Color(1, 1, 1, 0.45)

	if not disabled:
		btn.button_down.connect(_on_btn_down.bind(preset))

	# Packed ("shipping") size on hover — PACKING_PLAN.md Phase 0. Tooltip, not
	# a third text line: the buttons are already two lines tall.
	var packed := PackedSpec.for_preset_specs(str(preset.get("type", "")),
		preset.get("specs", {}))
	if not packed.is_empty():
		btn.tooltip_text = "Packs to: %s · %s%s" % [
			PackedSpec.format_dims(packed), PackedSpec.format_mass(packed),
			"  (est.)" if str(packed.get("source", "")) == "estimated" else ""]

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
		if old_cat != null:
			old_cat.queue_free()
		call_deferred("_refresh_scroll_content_height")
		return
	var cat := {"label": "In Model", "icon": "🏗", "presets": display_presets}
	var cat_ctrl := _build_category(cat, idx)
	cat_ctrl.name = "InModelCategory"
	cat_ctrl.set_meta("cat_idx", idx)
	_categories_vbox.add_child(cat_ctrl)
	call_deferred("_refresh_scroll_content_height")


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
			if str(specs.get("role", "")) == "habitat":
				var n: int = int(specs.get("occupants", 1))
				return "%d person%s · %.0f L/day" % [
					n, "s" if n != 1 else "",
					float(specs.get("occupants", 1.0)) * 2.083 * 24.0]
			if str(specs.get("processor_template", "")) == "ibc_biodigester":
				return "5 gal/d + 1 kg/d → effluent + biogas"
			if str(specs.get("processor_template", "")) == "home_biogas_2" \
					or str(specs.get("role", "")) == "biodigester":
				return "6 L food/d → 0.3–0.4 m³ biogas"
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
	# idx is the BUILT index, not a ComponentPresets.CATEGORIES index — indexing
	# the catalog with it misnamed headers whenever a category was locked/skipped
	# and went out of range for the runtime "In Model" / "Scene Objects" rows.
	var hdr: Button = _cat_headers[idx]
	_cat_headers[idx].text = "%s  %s  %s" % [
		str(hdr.get_meta("cat_icon", "")), str(hdr.get_meta("cat_label", "")),
		"▼" if _cat_expanded[idx] else "▶"
	]


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

func _apply_cat_header_style(btn: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(C_SIDEBAR.r, C_SIDEBAR.g, C_SIDEBAR.b, 1.0)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.set_border_width(SIDE_TOP, 1)
	sb.border_color          = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.7)
	sb.content_margin_left   = 12.0
	sb.content_margin_right  = 10.0
	sb.content_margin_top    =  9.0
	sb.content_margin_bottom =  9.0
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = C_PANEL
	sb_h.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.35)
	btn.add_theme_stylebox_override("normal",  sb)
	btn.add_theme_stylebox_override("hover",   sb_h)
	btn.add_theme_stylebox_override("pressed", sb_h)
	btn.add_theme_color_override("font_color",      C_PRIMARY)
	btn.add_theme_font_size_override("font_size", 12)
	btn.custom_minimum_size.y = 34.0


func _fill(ctrl: Control) -> void:
	ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
