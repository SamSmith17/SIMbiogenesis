extends Control

## Unified edit toolbar — Photoshop-style: a vertical tool strip on the left
## edge plus a slim options bar along the top showing the ACTIVE tool's
## parameters. Runs in CursorController's TOOL OVERLAY tier, not a modal: the
## mouse is visible for painting and the palette, WASD/jump stay live, and
## holding RMB captures the mouse for first-person look (player.gd's overlay
## branches). LMB paints; it never reaches the fire-extinguisher tool-use path
## (player gates that on has_tool_overlay()).
##
## Dispatch reuses the exact TerrainLoader surface the legacy T dock calls
## (brush_stamp / level_region_command / pond_command / rain_selection / ...),
## so the two UIs cannot drift in behaviour while they coexist. Per-tool
## parameters live in EditToolbarState — switching tools switches param sets,
## which is the fix for the old dock's shared globals.
##
## ONE DELIBERATE DIVERGENCE from the legacy dock: RMB does NOT close a polygon
## or cancel a shape here, because RMB is the camera-look button. Polygons close
## with Enter or by clicking the first vertex again.
##
## Esc routes through CursorController.pop_top_modal()'s overlay fallback into
## _escape_step(), which peels one layer per press (stroke → water hold →
## gesture → locked selection → exit) — same ladder as the legacy dock, but the
## overlay never touches the pause latch, so control returns immediately.

const OVERLAY_NAME := "edit_toolbar"

## Preload by PATH, not by class_name: the bare identifier resolves through the
## global class cache, which headless runs (and a stale editor session) may not
## have rebuilt yet — the same "Could not find type" trap the veg dock selftest
## documents. The path always works.
const ToolbarStateScript := preload("res://scenes/ui/toolbar/toolbar_state.gd")
const GestureScript := preload("res://scenes/ui/toolbar/shape_gesture_controller.gd")
const WaterToolScript := preload("res://scenes/ui/toolbar/water_tool_controller.gd")

const HIGHLIGHT_COLOR := Color(0.35, 0.85, 1.0, 0.45)
const SHAPE_LABELS := {
	"brush": "Brush", "circle": "Circle", "rect": "Rect",
	"lasso": "Lasso", "polygon": "Poly", "path": "Path",
}
const SHAPE_TIPS := {
	"brush": "Freehand sweep — hold LMB and drag",
	"circle": "Drag from the centre outward",
	"rect": "Drag corner to corner",
	"lasso": "Hold LMB and trace an outline",
	"polygon": "Click each corner; Enter or click the first corner to close",
	"path": "Click each bend; Enter finishes the road",
}

## The section key that reopens the toolbar exactly where it was closed.
const REOPEN_SECTION := "veg"
var _state: ToolbarStateScript = ToolbarStateScript.new()
var _gesture: GestureScript = GestureScript.new()
## The WATER section's tools live in their own controller (pin dragging,
## tracing, span modes); this file only delegates to it.
var _water_tools: WaterToolScript = WaterToolScript.new()
var _loader: Node = null
var _active := false

# UI nodes
var _overlay: Control = null
var _strip: PanelContainer = null
var _strip_box: VBoxContainer = null
var _options: PanelContainer = null
var _options_box: HFlowContainer = null
var _shape_row: HBoxContainer = null
var _tool_lbl: Label = null
var _status: Label = null
var _height_lbl: Label = null
var _basin_lbl: Label = null
var _undo_btn: Button = null
## tool_id -> Button (strip highlight restyle keys off the id, never an index).
var _tool_buttons: Dictionary = {}
var _shape_buttons: Dictionary = {}
## param key -> SliderSpinRow {row, slider, spin} for the ACTIVE tool's rows.
var _param_rows: Dictionary = {}

# Stroke / gesture state
var _stroking := false
var _flatten_target := NAN
var _gesture_has_a := false
var _gesture_a := Vector2.ZERO
var _cursor_hit: Variant = null
var _last_pointer_px := Vector2(-1e9, -1e9)

# Locked region selection (Pond / Rain / Drain keep one after the draw).
var _selection_locked := false
var _selection_poly := PackedVector2Array()
var _basin_cache: Dictionary = {}

# Rain / Drain hold-to-modulate
var _water_modulating := false
var _water_mod_undo_pushed := false
## Rain over ground that is not a closed basin: a storm on the water network
## (WaterNetwork.add_storm) whose end follows the held button.
var _storm_id := -1
var _storm_start_h := 0.0
## A click makes at least this much of a shower (sim hours).
const STORM_MIN_H := 0.25
## Rain fills a pond only when its hollow covers this share of the selection.
const POND_MIN_SHARE := 0.2
var _last_fill_rate_lps := 0.0

var _brush_ring: MeshInstance3D = null

# Vegetation
var _species_row: HBoxContainer = null
var _family_buttons: Dictionary = {}
var _subspecies_opt: OptionButton = null
## Veg paint/clear stamp throttle — one stamp per brush-radius of travel.
var _last_stamp := Vector2(-1e9, -1e9)
var _veg_undo_pushed := false
## A press that has not yet travelled far enough to count as a drag. Paint
## turns that into "drop ONE plant here" on release, matching the veg dock.
var _paint_click_candidate := false
var _paint_press_px := Vector2.ZERO
var _picked_plant: Dictionary = {}
## Select hover: the plant under the pointer (TerrainLoader pick descriptor).
var _hover_plant: Dictionary = {}
var _hover_ms := 0
var _lmb_shift := false
## Detect: the region being previewed, and its re-preview debounce.
var _detect_poly := PackedVector2Array()
var _detect_timer: Timer = null
var _detect_stats_lbl: Label = null
## The section the last reground ran for — sculpting terrain leaves painted
## plants floating, so switching terrain -> veg re-snaps them once.
var _last_section := ""

# Camps
var _camp_style_buttons: Dictionary = {}
## Outline(s) of the brush stroke in progress: the union of its stamps. The
## stroke commits ONE polygon on release, so a camp is never rebuilt per frame.
var _camp_stroke: Array = []
var _picked_camp := ""
var _camp_name_edit: LineEdit = null
var _camp_action_buttons: Array[Button] = []
var _camp_apply_timer: Timer = null

## Debounced write of the per-tool settings. Dragging a slider fires
## value_changed continuously, so saving inline would hit the disk every frame.
var _save_timer: Timer = null

## Strip collapse (session-only, deliberately not persisted).
var _collapse_btn: Button = null
var _collapsed := false
## Everything the collapse hides: headers and tool buttons, in build order.
var _strip_body: Array[Control] = []


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	# Restore the player's per-tool settings BEFORE the strip is built, so the
	# first open already shows their tools, radii and species.
	_state.load_from()
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 1.0
	_save_timer.timeout.connect(_save_prefs_now)
	add_child(_save_timer)
	# Editing a picked camp's sliders rebuilds that camp; debounce so a drag
	# rebuilds once when it pauses rather than on every value_changed.
	_camp_apply_timer = Timer.new()
	_camp_apply_timer.one_shot = true
	_camp_apply_timer.wait_time = 0.2
	_camp_apply_timer.timeout.connect(_apply_camp_select_params)
	add_child(_camp_apply_timer)
	_water_tools.setup(self)
	_build_ui()


## Restart the debounce. Called from every control that writes state.
func _queue_save_prefs() -> void:
	if _save_timer != null:
		_save_timer.start()


func _save_prefs_now() -> void:
	_state.save_to()


func bind_loader(loader: Node) -> void:
	_loader = loader


# ---------------------------------------------------------------------------
# Enter / exit — the string-called contract (toggle_mode/_exit_mode/
# is_panel_open) matches every other dock so terrain_loader's force-close and
# ui_compile_selftest's CONTRACTS table treat this file like its siblings.
# ---------------------------------------------------------------------------

func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


func open_with_section(section: String) -> void:
	if not _active:
		_enter_mode()
	var def := _state.tool_def(_state.active_tool)
	if def.is_empty() or String(def["section"]) != section:
		var tid := _state.tool_for_section(section)
		if not tid.is_empty():
			_set_active_tool(tid)


## What T and V do: open into that section, SWITCH to it when the toolbar is
## already up on the other section, and close only when it is already showing
## the section asked for. Pressing V while sculpting should move you to the
## plants, not shut the toolbar.
##
## V with the toolbar CLOSED reopens it exactly as it was closed — same
## section, same tool (a Water Edit session comes back as Water Edit, with the
## stream still picked). The other keys open their own section, on the tool
## last used there.
func toggle_section(section: String) -> void:
	if _active and String(_state.tool_def(_state.active_tool).get("section", "")) == section:
		_exit_mode()
		return
	if not _active and section == REOPEN_SECTION and not _state.reopen_tool.is_empty():
		_state.set_active_tool(_state.reopen_tool)
		_enter_mode()
		return
	open_with_section(section)


func is_panel_open() -> bool:
	return _active


func _enter_mode() -> void:
	if _active:
		return
	_active = true
	visible = true
	set_process(true)
	move_to_front()
	_set_active_tool(_state.active_tool)
	_update_undo_button()
	_sync_hud_claim.call_deferred()
	if _loader != null and _loader.has_method("begin_sculpt_session"):
		_loader.call("begin_sculpt_session")
	CursorController.request_tool_overlay(OVERLAY_NAME, Callable(self, "_escape_step"))


func _exit_mode() -> void:
	if not _active:
		return
	_water_tools.deactivate()
	_cancel_stroke()
	_clear_veg_hover()
	_end_detect(true)
	_clear_picked_camp()
	_end_water_modulate()
	_clear_locked_selection()
	_gesture.reset()
	_gesture_has_a = false
	_active = false
	visible = false
	set_process(false)
	HudLayout.release("edit_toolbar")
	_free_brush_ring()
	if _loader != null and _loader.has_method("end_sculpt_session"):
		_loader.call("end_sculpt_session")
	_state.reopen_tool = _state.active_tool
	# Flush now rather than waiting out the debounce, which closing would eat.
	_save_prefs_now()
	CursorController.release_tool_overlay(OVERLAY_NAME)


## Esc (via CursorController's overlay fallback): peel one layer per press.
func _escape_step() -> void:
	if _is_water_section() and _water_tools.escape():
		return
	if _stroking:
		_cancel_stroke()
		_set_status("Stroke ended")
		return
	if _water_modulating:
		_end_water_modulate()
		return
	if _gesture.cancel():
		_set_status("Cancelled")
		_queue_overlay_redraw()
		return
	if _gesture_has_a:
		_gesture_has_a = false
		_set_status("Cancelled")
		_queue_overlay_redraw()
		return
	if _selection_locked:
		_clear_locked_selection()
		_set_status("Selection cleared")
		return
	if not _detect_poly.is_empty():
		_end_detect(false)
		_set_status("Detection preview cleared")
		return
	if not _picked_place["kind"].is_empty():
		_clear_picked_place()
		_set_status("Selection cleared")
		_queue_overlay_redraw()
		return
	_exit_mode()


func _cancel_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
	if _is_camp_tool():
		# A cancelled camp stroke commits nothing — the camp only changes on release.
		_camp_stroke.clear()
		_queue_overlay_redraw()
		return
	if _loader != null:
		_loader.call("end_terrain_tile_edit")
	_update_undo_button()
	_set_status(_volume_summary())


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# World-space gesture overlay, added FIRST so the panels draw over it.
	_overlay = Control.new()
	_overlay.name = "GestureOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	# Left vertical tool strip.
	_strip = PanelContainer.new()
	_strip.name = "ToolStrip"
	_strip.add_theme_stylebox_override("panel", UITheme.panel_style(0.92))
	_strip.mouse_filter = Control.MOUSE_FILTER_STOP
	# Top-left under the options bar, not vertically centred: with equal top/
	# bottom anchors a PanelContainer grows DOWNWARD from the anchor line, so a
	# CENTER_LEFT preset reads as "starts at the middle", never centred.
	_strip.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_strip.offset_left = 8.0
	_strip.offset_right = 104.0
	_strip.offset_top = 52.0
	add_child(_strip)
	_strip_box = VBoxContainer.new()
	_strip_box.add_theme_constant_override("separation", 3)
	_strip.add_child(_strip_box)
	# Collapse control. The strip carries 13 tools, which is a tall column on a
	# short window. Session-only on purpose: a collapsed state remembered across
	# launches reads as "my tools disappeared".
	_collapse_btn = Button.new()
	_collapse_btn.custom_minimum_size = Vector2(84, 22)
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.pressed.connect(_toggle_collapsed)
	_strip_box.add_child(_collapse_btn)
	_build_strip_section("TERRAIN", "terrain")
	_build_strip_section("VEGETATION", "veg")
	_build_strip_section("CAMPS", "camps")
	_build_strip_section("PLACEMENT", "placement")
	_build_strip_section("WATER", "water")

	# Top options bar.
	_options = PanelContainer.new()
	_options.name = "OptionsBar"
	_options.add_theme_stylebox_override("panel", UITheme.panel_style(0.92))
	_options.mouse_filter = Control.MOUSE_FILTER_STOP
	_options.set_anchors_preset(Control.PRESET_TOP_WIDE)
	# Full width across the top; the strip hangs below it (_sync_hud_claim).
	_options.offset_left = 8.0
	_options.offset_right = -8.0
	_options.offset_top = 8.0
	add_child(_options)
	# A FLOW container: a tool with many options wraps onto a second row
	# instead of running off the right edge (it used to be 2500 px wide).
	_options_box = HFlowContainer.new()
	_options_box.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	_options_box.add_theme_constant_override("v_separation", 4)
	_options.add_child(_options_box)
	_options.resized.connect(_sync_hud_claim)
	_strip.resized.connect(_sync_hud_claim)


## The strip is an accordion: every section's header is a button, and only
## the ACTIVE section lists its tools — five sections of tools stacked whole
## ran down past the timeline and covered the scoreboard.
## One Lucide glyph per tool, so the strip reads at a glance and a collapsed
## (icon-only) strip still says which tool is which.
const TOOL_ICONS := {
	"raise": "chevron-up", "lower": "chevron-down", "smooth": "waves",
	"level": "minus", "ramp": "trending-up", "pond": "droplet",
	"rain": "cloud-rain", "drain": "download", "measure": "ruler",
	"veg_paint": "sprout", "veg_place": "trees", "veg_clear": "eraser",
	"veg_select": "mouse-pointer-2", "veg_detect": "sparkles",
	"camp_paint": "tent", "camp_erase": "eraser", "camp_subdivide": "layout-grid",
	"camp_select": "pencil",
	"fest_road": "route", "fest_zone": "square-dashed", "fest_lots": "layout-grid",
	"fest_assign": "users", "fest_edit": "pencil",
	"water_trace": "target", "water_draw": "pencil", "water_edit": "move",
	"water_span": "link", "water_view": "eye",
}

var _section_headers: Dictionary = {}   # section -> Button
var _section_tools: Dictionary = {}     # section -> Array[Button]


func _build_strip_section(title: String, section: String) -> void:
	var hdr := Button.new()
	hdr.text = title.capitalize()
	hdr.flat = true
	hdr.focus_mode = Control.FOCUS_NONE
	hdr.alignment = HORIZONTAL_ALIGNMENT_LEFT
	hdr.custom_minimum_size = Vector2(84, 22)
	hdr.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hdr.tooltip_text = "%s tools" % title.capitalize()
	hdr.pressed.connect(open_with_section.bind(section))
	_strip_box.add_child(hdr)
	_strip_body.append(hdr)
	_section_headers[section] = hdr
	_section_tools[section] = []
	for t in _state.tools_in_section(section):
		var id := String(t["id"])
		var btn := Button.new()
		btn.text = String(t["label"])
		btn.tooltip_text = String(t["tooltip"])
		btn.custom_minimum_size = Vector2(84, 28)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.icon = UiIcons.icon(String(TOOL_ICONS.get(id, "circle-help")), 14)
		btn.focus_mode = Control.FOCUS_NONE
		if ToolbarStateScript.PENDING_TOOLS.has(id):
			btn.disabled = true
			btn.tooltip_text += "\n(not in the toolbar yet — Shift+T opens the classic dock)"
		else:
			btn.pressed.connect(_set_active_tool.bind(id))
		_strip_box.add_child(btn)
		_strip_body.append(btn)
		_tool_buttons[id] = btn
		(_section_tools[section] as Array).append(btn)
	_restyle_tool_buttons()
	_refresh_collapse_button()


## Tool / shape / family toggle faces now live in UITheme, shared with every
## other strip rather than hand-rolled per dock.
func _style_toggle(btn: Button, on: bool) -> void:
	UITheme.style_toggle(btn, on)


func _restyle_tool_buttons() -> void:
	for id in _tool_buttons.keys():
		_style_toggle(_tool_buttons[id], String(id) == _state.active_tool)
	_refresh_strip_sections()


func _refresh_strip_sections() -> void:
	var active := String(_state.tool_def(_state.active_tool).get("section", ""))
	for sec in _section_headers:
		var hdr: Button = _section_headers[sec]
		var open: bool = sec == active
		hdr.visible = not _collapsed
		hdr.icon = UiIcons.icon("chevron-down" if open else "chevron-right", 12)
		hdr.add_theme_color_override("font_color", UITheme.C_PRIMARY if open else UITheme.C_TEXT_S)
		hdr.add_theme_color_override("font_hover_color", UITheme.C_TEXT)
		for b in _section_tools.get(sec, []):
			(b as Control).visible = open and not _collapsed
	if _strip != null:
		_strip.reset_size()


## Tell the HUD what the toolbar covers (the strip down the left, the options
## bar across the top) so every HUD panel moves clear or tucks into a pill.
func _sync_hud_claim() -> void:
	if not _active or _strip == null or _options == null:
		return
	var top := _options.get_global_rect().end.y + 6.0
	_strip.offset_top = top
	var m := HudLayoutCore.MARGIN
	HudLayout.claim("edit_toolbar", {
		"inset": {"left": _strip.get_global_rect().end.x + 6.0 - m, "top": top - m},
		"tuck": ["top_left", "top_right"]})


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	_refresh_strip_sections()
	_refresh_collapse_button()
	# Without this the panel keeps the hidden children's footprint.
	_strip.reset_size()


func _refresh_collapse_button() -> void:
	if _collapse_btn == null:
		return
	_collapse_btn.text = "Tools"
	_collapse_btn.icon = UiIcons.icon("chevron-right" if _collapsed else "chevron-down", 12)
	_collapse_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_collapse_btn.tooltip_text = "Show the tool strip" if _collapsed \
		else "Collapse the tool strip"
	UITheme.style_toggle(_collapse_btn, false, UITheme.FONT_XS)


func _restyle_shape_buttons() -> void:
	var cur := _state.shape_for(_state.active_tool)
	for id in _shape_buttons.keys():
		_style_toggle(_shape_buttons[id], String(id) == cur)


func _set_active_tool(id: String) -> void:
	if not _state.set_active_tool(id):
		return
	# A live stroke/gesture/selection belongs to the OLD tool. Water tools share
	# a locked basin between Rain and Drain, so that one selection survives.
	_cancel_stroke()
	_end_water_modulate()
	_gesture.reset()
	_gesture_has_a = false
	if _selection_locked and not _is_water_tool():
		_clear_locked_selection()
	_picked_plant = {}
	_clear_veg_hover()
	if id != "veg_detect":
		_end_detect(true)
	_clear_picked_camp()
	_clear_picked_place()
	_gesture.set_mode(_state.shape_for(id))
	if _water_tools.is_water_tool(id):
		_water_tools.activate(id)
	else:
		_water_tools.deactivate()
	# Sculpting leaves painted plants hanging in the air, and this toolbar makes
	# terrain->veg a one-click move, so re-snap them on the way in (the legacy
	# veg dock does the same on every open).
	var section := String(_state.tool_def(id).get("section", ""))
	if section == "veg" and _last_section != "veg" and _loader != null \
			and _loader.has_method("reground_all_vegetation"):
		_loader.call("reground_all_vegetation")
	# Same for camps: a sculpted pad leaves the tents on the old surface.
	if (section == "camps" or section == "placement") and _last_section == "terrain" \
			and _loader != null and _loader.has_method("reground_camp_areas"):
		_loader.call("reground_camp_areas")
	_last_section = section
	_restyle_tool_buttons()
	_rebuild_options_bar()
	_queue_save_prefs()
	_set_status("")
	_queue_overlay_redraw()


func _set_shape(shape: String) -> void:
	if not _state.set_shape(_state.active_tool, shape):
		return
	_gesture.set_mode(shape)
	_restyle_shape_buttons()
	_queue_save_prefs()
	_queue_overlay_redraw()


## The options bar is rebuilt per tool switch (not value-resynced): rows differ
## per tool, and a rebuild cannot leave a stale row behind. Handlers are pure
## state.set_param writes, so the SliderSpinRow value_changed re-fire on build
## is idempotent.
func _rebuild_options_bar() -> void:
	_param_rows.clear()
	_shape_buttons.clear()
	_shape_row = null
	for c in _options_box.get_children():
		# Detach FIRST: queue_free defers to end of frame, so a dying row would
		# still be measured by the container alongside its replacement and the
		# bar would jump to double width for a frame.
		_options_box.remove_child(c)
		c.queue_free()
	var def := _state.tool_def(_state.active_tool)
	_tool_lbl = Label.new()
	_tool_lbl.text = String(def.get("label", "?"))
	_tool_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_tool_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_tool_lbl.custom_minimum_size = Vector2(64, 0)
	_options_box.add_child(_tool_lbl)
	for spec in _state.option_specs():
		var key := String(spec["key"])
		var pair := SliderSpinRow.add_param(_options_box, String(spec["label"]),
			float(spec["min"]), float(spec["max"]), float(spec["value"]),
			float(spec["step"]), String(spec.get("unit", "")),
			_make_param_handler(key), float(spec.get("auto_below", NAN)))
		_param_rows[key] = pair
	if String(def.get("section", "")) == "veg":
		_build_species_row()
	elif String(def.get("section", "")) == "camps":
		_build_camp_rows()
	elif String(def.get("section", "")) == "placement":
		_build_placement_rows()
	elif String(def.get("section", "")) == "water":
		_water_tools.build_rows(_options_box)
	# Shape picker — only when the tool actually offers a choice.
	var shapes: Array = def.get("shapes", [])
	if shapes.size() > 1:
		_shape_row = HBoxContainer.new()
		_shape_row.add_theme_constant_override("separation", 2)
		_options_box.add_child(_shape_row)
		for s in shapes:
			var sid := String(s)
			var sb := Button.new()
			sb.text = String(SHAPE_LABELS.get(sid, sid))
			sb.tooltip_text = String(SHAPE_TIPS.get(sid, ""))
			sb.custom_minimum_size = Vector2(52, 24)
			sb.focus_mode = Control.FOCUS_NONE
			sb.pressed.connect(_set_shape.bind(sid))
			_shape_row.add_child(sb)
			_shape_buttons[sid] = sb
		_restyle_shape_buttons()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_box.add_child(spacer)
	# The navigation contract is the least discoverable thing about this
	# toolbar: nothing on screen says the world is still yours while it is up.
	# One always-present chip carries it.
	var hint := PanelContainer.new()
	hint.add_theme_stylebox_override("panel", UITheme.chip_style(UITheme.C_LAVENDER))
	var hint_lbl := Label.new()
	hint_lbl.text = "RMB look · WASD move · [ ] size · Esc close"
	hint_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint_lbl.add_theme_color_override("font_color", UITheme.C_LAVENDER.lightened(0.35))
	hint.add_child(hint_lbl)
	_options_box.add_child(hint)
	_basin_lbl = Label.new()
	_basin_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_basin_lbl.add_theme_color_override("font_color", UITheme.C_INFO)
	_options_box.add_child(_basin_lbl)
	_height_lbl = Label.new()
	_height_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_height_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_options_box.add_child(_height_lbl)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_options_box.add_child(_status)
	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.tooltip_text = "Undo the last edit (Ctrl+Z)"
	_undo_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_undo_btn)
	_undo_btn.pressed.connect(_do_undo)
	_options_box.add_child(_undo_btn)
	_update_undo_button()
	var exit_btn := Button.new()
	IconButton.as_close(exit_btn, "Close the toolbar (Esc)")
	exit_btn.pressed.connect(_exit_mode)
	_options_box.add_child(exit_btn)


func _style_row_label(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)


func _make_param_handler(key: String) -> Callable:
	return func(v: float) -> void:
		_state.set_param(key, v)
		_queue_save_prefs()
		# In Camp Edit the sliders ARE the picked camp's settings.
		if _state.active_tool == "camp_select" and _camp_apply_timer != null:
			_camp_apply_timer.start()
		if _state.active_tool == "fest_edit" and _place_apply_timer != null:
			_place_apply_timer.start()
		if _state.active_tool == "veg_detect" and not _detect_poly.is_empty():
			_queue_detect_preview()


# ---------------------------------------------------------------------------
# Input — no fullscreen capture rect. The two panels STOP mouse events over
# themselves; anything reaching _unhandled_input is a world interaction. RMB is
# never consumed here — the player owns it for overlay look.
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if _is_water_section() and _water_tools.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		if key.keycode == KEY_Z and key.ctrl_pressed:
			_do_undo()
			get_viewport().set_input_as_handled()
			return
		if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
			if _gesture.mode == "polygon" and _gesture.poly_points().size() >= 3:
				_lock_selection(_gesture.finish_polygon())
				get_viewport().set_input_as_handled()
			elif _gesture.mode == "path" and _gesture.poly_points().size() >= 2:
				_commit_festival_road(_gesture.finish_polygon())
				get_viewport().set_input_as_handled()
			elif _state.active_tool == "veg_detect" and not _detect_poly.is_empty():
				_place_detected()
				get_viewport().set_input_as_handled()
			return
		# With a plant picked, Del / [ ] / H act on THAT plant — the bracket keys
		# resize it instead of the (nonexistent) Select brush radius.
		if _state.active_tool == "veg_select" and not _picked_plant.is_empty():
			if key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE:
				_delete_picked_plant()
				get_viewport().set_input_as_handled()
				return
			if key.physical_keycode == KEY_H:
				_convert_picked_to_hero()
				get_viewport().set_input_as_handled()
				return
			if key.physical_keycode == KEY_BRACKETLEFT or key.physical_keycode == KEY_BRACKETRIGHT:
				_resize_picked_plant(1.15 if key.physical_keycode == KEY_BRACKETRIGHT else 1.0 / 1.15)
				get_viewport().set_input_as_handled()
				return
		if _state.active_tool == "camp_select" and not _picked_camp.is_empty() \
				and (key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE):
			_delete_picked_camp()
			get_viewport().set_input_as_handled()
			return
		if _state.active_tool == "fest_edit" and not _picked_place["kind"].is_empty() \
				and (key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE):
			_delete_picked_place()
			get_viewport().set_input_as_handled()
			return
		if key.physical_keycode == KEY_BRACKETLEFT or key.physical_keycode == KEY_BRACKETRIGHT:
			_nudge_radius(key.physical_keycode == KEY_BRACKETRIGHT)
			get_viewport().set_input_as_handled()
			return
		return
	if event is InputEventMouseMotion and _gesture.is_dragging() and _gesture.mode == "lasso":
		var mm := event as InputEventMouseMotion
		var hit: Variant = _pick_at(mm.position)
		if hit is Vector3:
			var hp: Vector3 = hit
			if _gesture.motion(Vector2(hp.x, hp.z), mm.position):
				_queue_overlay_redraw()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if _pointer_over_ui() or CursorController.overlay_look_active():
				return
			_lmb_shift = mb.shift_pressed
			_on_lmb_pressed()
			get_viewport().set_input_as_handled()
		elif _stroking or _water_modulating or _gesture.is_dragging():
			_on_lmb_released()
			get_viewport().set_input_as_handled()


## Photoshop's [ ] — nudge the active tool's radius/width, whichever it has.
func _nudge_radius(grow: bool) -> void:
	for key in ["radius_m", "width_m"]:
		for spec in _state.option_specs():
			if String(spec["key"]) == key:
				var factor := 1.15 if grow else 1.0 / 1.15
				_state.set_param(key, float(spec["value"]) * factor)
				if _param_rows.has(key):
					SliderSpinRow.set_values(_param_rows[key], _state.get_param(key))
				_queue_save_prefs()
				return


func _pointer_over_ui() -> bool:
	var mouse := get_viewport().get_mouse_position()
	if _strip != null and _strip.get_global_rect().has_point(mouse):
		return true
	if _options != null and _options.get_global_rect().has_point(mouse):
		return true
	return false


## The WATER section (streams) — distinct from _is_water_tool (Rain/Drain/Pond).
func _is_water_section() -> bool:
	return String(_state.tool_def(_state.active_tool).get("section", "")) == "water"


func _is_water_tool() -> bool:
	return _state.active_tool == "rain" or _state.active_tool == "drain" \
		or _state.active_tool == "pond"


func _on_lmb_pressed() -> void:
	var hit: Variant = _pick_pointer()
	if not (hit is Vector3):
		_set_status("Aim at the terrain")
		return
	var p: Vector3 = hit
	var world := Vector2(p.x, p.z)

	# Two-click gestures own the click entirely.
	if _state.active_tool == "ramp" or _state.active_tool == "measure":
		_gesture_click(world)
		return

	# Vegetation single-shot tools own the click.
	if _state.active_tool == "veg_place":
		_place_hero_at(p)
		return
	if _state.active_tool == "veg_select":
		_pick_plant_at(world)
		return
	if _state.active_tool == "camp_select":
		_pick_camp_at(world)
		return
	if _state.active_tool == "fest_lots" or _state.active_tool == "fest_assign" \
			or _state.active_tool == "fest_edit":
		_pick_place_at(world)
		return

	# Rain/Drain: hold inside the locked basin to modulate its level.
	if (_state.active_tool == "rain" or _state.active_tool == "drain") \
			and _selection_locked and _selection_poly.size() >= 3 \
			and Geometry2D.is_point_in_polygon(world, _selection_poly):
		_begin_water_modulate()
		return

	# A click outside an existing locked selection starts a new one.
	if _selection_locked and _gesture.is_region_mode() \
			and not Geometry2D.is_point_in_polygon(world, _selection_poly):
		_clear_locked_selection()

	if _gesture.mode == "brush":
		if _is_veg_tool():
			_begin_veg_stroke(world)
		elif _is_camp_tool():
			_begin_camp_stroke(world)
		else:
			_begin_brush(world)
		return
	var close_tol := maxf(_state.get_param("radius_m", 12.0) * 0.25, 3.0)
	var outcome := _gesture.begin(world, get_viewport().get_mouse_position(), close_tol)
	match outcome:
		GestureScript.POLY_CLOSED:
			_lock_selection(_gesture.finish_polygon())
		GestureScript.POLY_POINT:
			if _gesture.mode == "path":
				_set_status("Road: %s — Enter to finish" % UiText.count(_gesture.poly_points().size(), "point"))
			else:
				_set_status("Polygon: %s — Enter to close" % UiText.count(_gesture.poly_points().size(), "point"))
	_queue_overlay_redraw()


func _on_lmb_released() -> void:
	if _water_modulating:
		_end_water_modulate()
		return
	if _stroking:
		if _is_veg_tool():
			_end_veg_stroke()
		elif _is_camp_tool():
			_end_camp_stroke()
		else:
			_stroking = false
			if _loader != null:
				_loader.call("end_terrain_tile_edit")
			_set_status(_volume_summary())
			_update_undo_button()
		return
	if _gesture.is_dragging():
		var poly := _gesture.release()
		if not poly.is_empty():
			_lock_selection(poly)
		_queue_overlay_redraw()


# ---------------------------------------------------------------------------
# Region selection — draw, validate, then apply per tool.
# ---------------------------------------------------------------------------

func _lock_selection(poly: PackedVector2Array) -> void:
	var reason := GestureScript.rejection_reason(poly)
	if not reason.is_empty():
		_set_status(reason)
		_queue_overlay_redraw()
		return
	if _loader == null:
		return
	# Vegetation regions apply IMMEDIATELY and never lock — only the water
	# tools keep a selection alive after the draw. Veg also does not need the
	# hi-res detail patch, so the sculpt gate below must not apply to it.
	if _is_veg_tool():
		_apply_veg_region(poly)
		_queue_overlay_redraw()
		return
	# Camp regions also apply at once, and need no detail patch either.
	if _is_camp_tool():
		_apply_camp_region(poly)
		_queue_overlay_redraw()
		return
	if _is_placement_tool():
		_apply_placement_region(poly)
		_queue_overlay_redraw()
		return
	if not bool(_loader.call("can_sculpt_detail")):
		_set_status("Sculpting needs the hi-res detail patch")
		return
	_selection_locked = true
	_selection_poly = poly.duplicate()
	var area := VegetationPaint.polygon_area(poly)
	match _state.active_tool:
		"level":
			# Level applies immediately on release (draw → graded).
			_apply_level_region()
			_clear_locked_selection()
		"pond":
			var depth := _state.get_param("depth_m", 1.2)
			if bool(_loader.call("pond_command", _selection_poly, depth,
					"Sculpted Pond", 0.85, true)):
				_set_status("Basin carved %.1f m — switch to Rain to fill · Esc clears" % depth)
				_loader.call("update_sculpt_selection_highlight", _selection_poly)
				_refresh_basin_preview()
			else:
				_set_status("Pond needs a larger outline (min ~80 m²) — draw again")
				_clear_locked_selection()
		"rain", "drain":
			_loader.call("update_sculpt_selection_highlight", _selection_poly)
			_refresh_basin_preview()
			if bool(_basin_cache.get("valid", false)):
				_set_status("Basin locked — hold LMB to %s · Esc clears" % (
					"fill" if _state.active_tool == "rain" else "drain"))
			else:
				var msg := "No closed basin"
				if _loader.has_method("basin_failure_message"):
					msg = str(_loader.call("basin_failure_message", _basin_cache))
				_set_status(msg)
		_:
			_loader.call("update_sculpt_selection_highlight", _selection_poly)
			_set_status("Selection locked (%.0f m²) — Esc clears" % area)
	_update_undo_button()
	_queue_overlay_redraw()


func _clear_locked_selection() -> void:
	_end_water_modulate()
	_selection_locked = false
	_selection_poly = PackedVector2Array()
	_basin_cache = {}
	if _loader != null and _loader.has_method("clear_sculpt_selection_highlight"):
		_loader.call("clear_sculpt_selection_highlight")
	if _basin_lbl != null:
		_basin_lbl.text = ""
	_queue_overlay_redraw()


## Level the locked outline to its centroid's ground height, feathered out to
## natural terrain at the rim (one undo step).
func _apply_level_region() -> void:
	if _loader == null or _selection_poly.size() < 3:
		return
	var c := _poly_centroid(_selection_poly)
	var target := float(_loader.call("ground_height_at", c.x, c.y))
	var feather := lerpf(24.0, 2.0, _state.get_param("hardness", 0.5))
	_loader.call("level_region_command", _selection_poly, target, feather)
	_set_status("Leveled the pad to the centre height · %s" % _volume_summary())
	_update_undo_button()


func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))


# ---------------------------------------------------------------------------
# Rain / Drain hold-to-modulate
# ---------------------------------------------------------------------------

func _refresh_basin_preview() -> void:
	_basin_cache = {}
	if _loader == null or not _selection_locked or _selection_poly.size() < 3:
		if _basin_lbl != null:
			_basin_lbl.text = ""
		return
	if not _loader.has_method("analyze_selection_basin"):
		return
	_basin_cache = _loader.call("analyze_selection_basin", _selection_poly)
	_update_basin_label()


func _update_basin_label() -> void:
	if _basin_lbl == null:
		return
	if not bool(_basin_cache.get("valid", false)):
		_basin_lbl.text = str(_basin_cache.get("reason", ""))
		return
	var rate_txt := ""
	if _water_modulating and absf(_last_fill_rate_lps) > 0.5:
		rate_txt = " · %.0f L/s" % _last_fill_rate_lps
	_basin_lbl.text = "Lvl %.2f / spill %.2f m · %.0f L (%.0f%%)%s" % [
		float(_basin_cache.get("level_m", 0.0)),
		float(_basin_cache.get("spill_m", 0.0)),
		float(_basin_cache.get("stock_l", 0.0)),
		float(_basin_cache.get("fill_frac", 0.0)) * 100.0,
		rate_txt,
	]


func _begin_water_modulate() -> void:
	if _loader == null or not _selection_locked:
		return
	_water_modulating = true
	_water_mod_undo_pushed = false
	_last_fill_rate_lps = 0.0
	_refresh_basin_preview()
	# A pond is filled only when the hollow is a real part of what was drawn: a
	# wide area over a stream holds some 20 cm dimple in the channel bed, and
	# filling that instead of raining on the area is not what anyone meant.
	var basin_share := float(_basin_cache.get("area_m2", 0.0)) 		/ maxf(BuildingBuilder.footprint_area_m2(_selection_poly), 1.0)
	if _state.active_tool == "rain" and (not bool(_basin_cache.get("valid", false))
			or basin_share < POND_MIN_SHARE):
		# Open ground: rain a storm there. Its runoff finds the streams below.
		if not _begin_storm():
			var msg := "No closed basin"
			if _loader.has_method("basin_failure_message"):
				msg = str(_loader.call("basin_failure_message", _basin_cache))
			_set_status(msg)
			_water_modulating = false


func _water_net() -> Node:
	if _loader == null or not _loader.has_method("water_network"):
		return null
	return _loader.call("water_network") as Node


func _begin_storm() -> bool:
	var wn := _water_net()
	if wn == null:
		return false
	var now := float(wn.call("_now_h"))
	if not is_finite(now):
		return false
	_storm_start_h = now
	_storm_id = int(wn.call("add_storm", _selection_poly, _state.get_param("storm_mmh", 40.0),
		now, now + STORM_MIN_H))
	_set_status(_storm_status(wn, now))
	return true


func _storm_status(wn: Node, now: float) -> String:
	var reach := float(wn.call("storm_reach_m2", _storm_id))
	var mmh := _state.get_param("storm_mmh", 40.0)
	var txt := "Storm %.0f mm/h" % mmh
	if reach <= 0.0:
		var dr: Dictionary = wn.call("drainage")
		txt += " — no stream drains this ground" if not dr.is_empty() \
			else " — working out where it drains…"
	else:
		txt += " — %.1f ha of it runs off into the streams below" % (reach / 10000.0)
	if SimFxRate.is_paused(_loader.get("_main") as Node):
		txt += " · the clock is paused: run it to watch the water come down"
	else:
		txt += " · %.0f min so far" % ((maxf(now, _storm_start_h + STORM_MIN_H) - _storm_start_h) * 60.0)
	return txt


func _end_water_modulate() -> void:
	if not _water_modulating:
		return
	_water_modulating = false
	if _storm_id >= 0:
		var wn := _water_net()
		if wn != null:
			var now := float(wn.call("_now_h"))
			wn.call("extend_storm", _storm_id, maxf(now, _storm_start_h + STORM_MIN_H))
			_set_status(_storm_status(wn, now).replace(" so far", "") + " — it runs off for a while yet")
		_storm_id = -1
		return
	_last_fill_rate_lps = 0.0
	_refresh_basin_preview()
	_update_undo_button()
	if bool(_basin_cache.get("valid", false)):
		_set_status("Water at %.2f m · %.0f L (%.0f%%)" % [
			float(_basin_cache.get("level_m", 0.0)),
			float(_basin_cache.get("stock_l", 0.0)),
			float(_basin_cache.get("fill_frac", 0.0)) * 100.0])
	_update_basin_label()


func _tick_water_modulate(delta: float) -> void:
	if _loader == null or not _selection_locked or _selection_poly.size() < 3:
		_end_water_modulate()
		return
	if _storm_id >= 0:
		var wn := _water_net()
		if wn != null:
			var now := float(wn.call("_now_h"))
			wn.call("extend_storm", _storm_id, maxf(now, _storm_start_h + STORM_MIN_H))
			_set_status(_storm_status(wn, now))
		return
	# One undo snapshot per HOLD, not per frame.
	if not _water_mod_undo_pushed:
		if _loader.has_method("push_sculpt_undo"):
			_loader.call("push_sculpt_undo")
		_water_mod_undo_pushed = true
	var step := maxf(_state.get_param("rate_mps", 0.15), 0.01) * clampf(delta, 0.0, 0.05)
	var result: Dictionary = {}
	if _state.active_tool == "rain" and _loader.has_method("rain_selection"):
		result = _loader.call("rain_selection", _selection_poly, step)
	elif _state.active_tool == "drain" and _loader.has_method("drain_selection"):
		result = _loader.call("drain_selection", _selection_poly, step)
	else:
		_end_water_modulate()
		return
	if not bool(result.get("ok", false)):
		var msg := str(result.get("reason", "failed"))
		if _loader.has_method("basin_failure_message"):
			msg = str(_loader.call("basin_failure_message", result))
		_set_status(msg)
		_end_water_modulate()
		return
	if bool(result.get("removed", false)):
		_set_status("Pond drained dry and removed")
		_basin_cache = result
		_update_basin_label()
		_end_water_modulate()
		return
	_last_fill_rate_lps = float(result.get("delta_stock_l", 0.0)) / maxf(delta, 1e-4)
	_basin_cache = {
		"valid": true,
		"level_m": float(result.get("level_m", 0.0)),
		"spill_m": float(result.get("spill_m", 0.0)),
		"floor_m": float(result.get("floor_m", 0.0)),
		"stock_l": float(result.get("stock_l", 0.0)),
		"capacity_l": float(result.get("capacity_l", 0.0)),
		"fill_frac": float(result.get("fill_frac", 0.0)),
	}
	_update_basin_label()
	if bool(result.get("at_spill", false)) and _state.active_tool == "rain":
		_set_status("At spill — rain stopped rising")


# ---------------------------------------------------------------------------
# Soft brush — same amount formulas and loader calls as the legacy dock, so a
# stroke feels identical in both UIs while they coexist.
# ---------------------------------------------------------------------------

func _begin_brush(world: Vector2) -> void:
	if _loader == null or not bool(_loader.call("can_sculpt_detail")):
		_set_status("Sculpting needs the hi-res detail patch")
		return
	_loader.call("begin_terrain_tile_edit")
	_stroking = true
	if _state.active_tool == "level":
		_flatten_target = float(_loader.call("ground_height_at", world.x, world.y))
	_apply_brush_at(world, get_process_delta_time())


func _apply_brush_at(world: Vector2, dt: float) -> void:
	if _loader == null:
		return
	var strength := _state.get_param("strength", 6.0)
	var amount := 0.0
	match _state.active_tool:
		"raise", "lower":
			amount = strength * clampf(dt, 0.0, 0.05)
		"smooth", "level":
			amount = clampf(strength / 25.0, 0.0, 1.0) * clampf(dt * 6.0, 0.0, 1.0)
	var ty := _flatten_target if _state.active_tool == "level" else NAN
	_loader.call("brush_stamp", _brush_op_name(), Vector3(world.x, 0.0, world.y),
		_state.get_param("radius_m", 12.0), amount,
		_state.get_param("hardness", 0.5), ty)


func _brush_op_name() -> String:
	match _state.active_tool:
		"raise": return "raise"
		"lower": return "lower"
		"smooth": return "smooth"
		"level": return "flatten"
		_: return "raise"


## "top 12 m · berm +1.5 m · sides 1:2" for the status line.
func _ramp_summary() -> String:
	var h := _state.get_param("height_m", 0.0)
	var kind := "on grade" if absf(h) < 0.05 else ("berm %+.1f m" % h if h > 0.0 else "channel %.1f m" % h)
	return "top %.1f m · %s · sides 1:%.1f" % [_state.get_param("width_m", 12.0), kind,
		_state.get_param("side_run", 2.0)]


## First click anchors; second completes the ramp grade / measure readout.
func _gesture_click(world: Vector2) -> void:
	if not _gesture_has_a:
		_gesture_a = world
		_gesture_has_a = true
		if _state.active_tool == "ramp":
			_set_status("Ramp: click the far end (%s)" % _ramp_summary())
		else:
			_set_status("Measure: click the second point")
		_queue_overlay_redraw()
		return
	var a := _gesture_a
	_gesture_has_a = false
	if _state.active_tool == "ramp":
		if _loader != null:
			_loader.call("ramp_command", Vector3(a.x, 0.0, a.y),
				Vector3(world.x, 0.0, world.y), _state.get_param("width_m", 12.0),
				_state.get_param("height_m", 0.0), _state.get_param("side_run", 2.0))
			_set_status("Ramp graded (%s) — %s" % [_ramp_summary(), _volume_summary()])
			_update_undo_button()
	else:
		var ya := 0.0
		var yb := 0.0
		if _loader != null:
			ya = float(_loader.call("ground_height_at", a.x, a.y))
			yb = float(_loader.call("ground_height_at", world.x, world.y))
		var horiz := a.distance_to(world)
		var slope_pct := 0.0 if horiz < 0.01 else (yb - ya) / horiz * 100.0
		_set_status("Distance %.1f m · Δelev %.2f m · slope %.1f%%" % [horiz, yb - ya, slope_pct])
	_queue_overlay_redraw()


# ---------------------------------------------------------------------------
# Per-frame: cursor pick, stroke tick, brush ring, height readout — gated on
# pointer movement or an active drag (the legacy dock's idle-cost fix).
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active:
		return
	if _is_water_section():
		_water_tools.process(delta)
		_update_height_readout()
		return
	var mouse := get_viewport().get_mouse_position() if get_viewport() != null else Vector2.ZERO
	var busy := _stroking or _water_modulating or _gesture.is_dragging()
	if not busy and mouse.is_equal_approx(_last_pointer_px):
		return
	_last_pointer_px = mouse
	_cursor_hit = _pick_pointer()
	if _state.active_tool == "veg_select" and not busy:
		_update_veg_hover()
	if _water_modulating:
		_tick_water_modulate(delta)
	elif _stroking and _cursor_hit is Vector3:
		var p: Vector3 = _cursor_hit
		if _is_veg_tool():
			_stamp_veg_at(Vector2(p.x, p.z))
		elif _is_camp_tool():
			_stamp_camp_at(Vector2(p.x, p.z))
		else:
			_apply_brush_at(Vector2(p.x, p.z), delta)
	elif _gesture.is_dragging() and _cursor_hit is Vector3:
		var c: Vector3 = _cursor_hit
		_gesture.update_drag(Vector2(c.x, c.z))
	_update_brush_ring()
	_update_height_readout()
	_queue_overlay_redraw()


func _pick_pointer() -> Variant:
	var vp := get_viewport()
	if vp == null:
		return null
	var pos := vp.get_mouse_position()
	# RMB-look holds the mouse captured — paint lands at the crosshair centre,
	# same fallback the legacy docks use.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		pos = vp.get_visible_rect().size * 0.5
	return _pick_at(pos)


func _pick_at(screen_pos: Vector2) -> Variant:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return null
	return _loader.call("terrain_pick_ray", screen_pos)


func _update_height_readout() -> void:
	if _height_lbl == null or _loader == null:
		return
	if not (_cursor_hit is Vector3):
		_height_lbl.text = ""
		return
	var p: Vector3 = _cursor_hit
	var gy := float(_loader.call("ground_height_at", p.x, p.z))
	var d := 0.0
	if _loader.has_method("terrain_edit_delta_at"):
		d = float(_loader.call("terrain_edit_delta_at", p.x, p.z))
	if absf(d) >= 0.05:
		_height_lbl.text = "Ground %.1f m · edited %+.1f m" % [gy, d]
	else:
		_height_lbl.text = "Ground %.1f m" % gy


# ---------------------------------------------------------------------------
# Overlay — projected gesture outlines (the 2D half of the feedback; the 3D
# half is the brush ring and the loader's draped selection highlight).
# ---------------------------------------------------------------------------

func _queue_overlay_redraw() -> void:
	if _overlay != null:
		_overlay.queue_redraw()


func _draw_overlay() -> void:
	if not _active or _overlay == null:
		return
	if _is_water_section():
		_water_tools.draw(_overlay)
		return
	var col := _tool_color()
	# Two-click gesture line (Ramp / Measure).
	if (_state.active_tool == "ramp" or _state.active_tool == "measure") and _gesture_has_a:
		var cursor_w := _gesture_a
		if _cursor_hit is Vector3:
			cursor_w = Vector2((_cursor_hit as Vector3).x, (_cursor_hit as Vector3).z)
		var line := _project_poly(PackedVector2Array([_gesture_a, cursor_w]))
		if line.size() == 2:
			_overlay.draw_polyline(line, col, 2.5, true)
			_overlay.draw_circle(line[0], 4.0, col)
			_overlay.draw_circle(line[1], 4.0, col)
		# The ramp's flat top: its two edges, dashed.
		if _state.active_tool == "ramp" and _gesture_a.distance_to(cursor_w) > 0.5:
			var n := (cursor_w - _gesture_a).normalized().orthogonal() * _state.get_param("width_m", 12.0) * 0.5
			for side in [n, -n]:
				var edge := _project_poly(PackedVector2Array([_gesture_a + side, cursor_w + side]))
				if edge.size() == 2:
					_overlay.draw_dashed_line(edge[0], edge[1], col, 1.5, 8.0)
		return
	# Camp brush stroke in progress: the outline that will be committed.
	if _stroking and _is_camp_tool():
		for ring: PackedVector2Array in _camp_stroke:
			var cpts := _project_poly(ring)
			if cpts.size() >= 3:
				cpts.append(cpts[0])
				_overlay.draw_polyline(cpts, col, 2.0, true)
		return
	if _is_placement_tool():
		_draw_placement_overlay()
	var mode := _gesture.mode
	if mode == "lasso" and _gesture.lasso_screen().size() >= 2:
		_overlay.draw_polyline(_gesture.lasso_screen(), col, 2.0, true)
		return
	if (mode == "polygon" or mode == "path") and _gesture.poly_points().size() >= 1:
		var pts := _project_poly(_gesture.poly_points())
		if pts.size() >= 2:
			_overlay.draw_polyline(pts, col, 2.0, true)
		for sp in pts:
			_overlay.draw_circle(sp, 3.0, col)
		return
	if _gesture.is_dragging() and _gesture.preview_world().size() >= 3:
		var pts2 := _project_poly(_gesture.preview_world())
		if pts2.size() >= 3:
			pts2.append(pts2[0])
			_overlay.draw_polyline(pts2, col, 2.0, true)
		return
	if _state.active_tool == "veg_detect" and _detect_poly.size() >= 3:
		var dpts := _project_poly(_detect_poly)
		if dpts.size() >= 3:
			dpts.append(dpts[0])
			_overlay.draw_polyline(dpts, Color(0.35, 1.0, 0.45, 0.85), 2.0, true)
		return
	if _selection_locked and _selection_poly.size() >= 3:
		var pts3 := _project_poly(_selection_poly)
		if pts3.size() >= 3:
			pts3.append(pts3[0])
			_overlay.draw_polyline(pts3, HIGHLIGHT_COLOR, 2.5, true)
		return


func _project_poly(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cam := get_viewport().get_camera_3d()
	if cam == null or _loader == null:
		return out
	for p in poly:
		var y := float(_loader.call("ground_height_at", p.x, p.y))
		var wp := Vector3(p.x, y + 0.3, p.y)
		if cam.is_position_behind(wp):
			continue
		out.append(cam.unproject_position(wp))
	return out


func _tool_color() -> Color:
	match _state.active_tool:
		"raise": return Color(0.4, 0.9, 0.5, 0.9)
		"lower": return Color(0.95, 0.6, 0.3, 0.9)
		"smooth": return Color(0.6, 0.8, 0.95, 0.9)
		"level": return Color(0.85, 0.85, 0.4, 0.9)
		"rain": return Color(0.35, 0.75, 1.0, 0.9)
		"drain": return Color(0.55, 0.7, 0.85, 0.9)
		"pond": return Color(0.3, 0.55, 0.95, 0.9)
		"veg_paint": return Color(0.45, 0.85, 0.45, 0.9)
		"veg_clear": return Color(0.95, 0.45, 0.45, 0.9)
		"veg_select", "veg_place": return Color(0.85, 0.75, 0.35, 0.9)
		"camp_paint": return Color(1.0, 0.72, 0.25, 0.9)
		"camp_erase": return Color(0.95, 0.45, 0.45, 0.9)
		"camp_subdivide": return Color(0.9, 0.55, 0.95, 0.9)
		"fest_road": return Color(0.95, 0.9, 0.7, 0.9)
		"fest_zone", "fest_lots": return Color(0.9, 0.55, 0.95, 0.9)
		"fest_assign", "fest_edit": return Color(0.85, 0.75, 0.35, 0.9)
		_: return Color(0.35, 0.65, 1.0, 0.9)


# ---------------------------------------------------------------------------
# 3D brush ring (world-space decal at the cursor, sized to the brush radius)
# ---------------------------------------------------------------------------

func _ensure_brush_ring() -> MeshInstance3D:
	if _brush_ring != null and is_instance_valid(_brush_ring):
		return _brush_ring
	var main: Node = _loader.get_parent() if _loader != null else null
	if main == null:
		return null
	var ring := MeshInstance3D.new()
	ring.name = "ToolbarBrushRing"
	var torus := TorusMesh.new()
	torus.outer_radius = 1.0
	torus.inner_radius = 0.94
	torus.rings = 48
	ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.3, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 2
	ring.material_override = mat
	ring.top_level = true
	ring.visible = false
	main.add_child(ring)
	_brush_ring = ring
	return ring


func _update_brush_ring() -> void:
	var show := _active and _gesture.mode == "brush" and (_cursor_hit is Vector3)
	var ring := _ensure_brush_ring()
	if ring == null:
		return
	if not show:
		ring.visible = false
		return
	var p: Vector3 = _cursor_hit
	ring.visible = true
	ring.global_position = Vector3(p.x, p.y + 0.15, p.z)
	var r := maxf(_state.get_param("radius_m", 12.0), 0.5)
	ring.scale = Vector3(r, maxf(r * 0.02, 0.15), r)


func _free_brush_ring() -> void:
	if _brush_ring != null and is_instance_valid(_brush_ring):
		_brush_ring.queue_free()
	_brush_ring = null


# ---------------------------------------------------------------------------
# Undo / status
# ---------------------------------------------------------------------------

## Terrain and vegetation keep SEPARATE undo stacks in the loader, so Undo
## follows the active tool's section rather than guessing.
func _do_undo() -> void:
	if _loader == null:
		return
	if _is_water_section():
		_set_status("Undid last water edit — re-carving…" if _water_tools.undo() else "Nothing to undo")
		_update_undo_button()
		return
	if _is_veg_tool():
		if _loader.has_method("undo_vegetation") and bool(_loader.call("undo_vegetation")):
			_picked_plant = {}
			_set_status("Undid last vegetation edit")
		else:
			_set_status("Nothing to undo")
	elif _is_camp_tool():
		if _loader.has_method("undo_camps") and bool(_loader.call("undo_camps")):
			_clear_picked_camp()
			_set_status("Undid last camp edit — %s" % _camp_totals())
		else:
			_set_status("Nothing to undo")
	elif _is_placement_tool():
		if _loader.has_method("undo_placement") and bool(_loader.call("undo_placement")):
			_clear_picked_place()
			_refresh_place_readout()
			_refresh_roster_options()
			_set_status("Undid last placement edit — %s" % _place_summary_text())
			_queue_overlay_redraw()
		else:
			_set_status("Nothing to undo")
	elif bool(_loader.call("undo_terrain_sculpt")):
		_set_status("Undone — %s" % _volume_summary())
		if _selection_locked:
			_refresh_basin_preview()
	_update_undo_button()


func _update_undo_button() -> void:
	if _undo_btn == null or _loader == null:
		return
	var can := false
	if _is_water_section():
		can = _water_tools.can_undo()
	elif _is_veg_tool():
		can = _loader.has_method("can_undo_vegetation") \
				and bool(_loader.call("can_undo_vegetation"))
	elif _is_camp_tool():
		can = _loader.has_method("can_undo_camps") and bool(_loader.call("can_undo_camps"))
	elif _is_placement_tool():
		can = _loader.has_method("can_undo_placement") and bool(_loader.call("can_undo_placement"))
	else:
		can = bool(_loader.call("can_undo_terrain_sculpt"))
	_undo_btn.disabled = not can


func _volume_summary() -> String:
	if _loader == null or not _loader.has_method("edit_volume_estimate"):
		return ""
	var v: Dictionary = _loader.call("edit_volume_estimate")
	return "cut %.0f m³ · fill %.0f m³" % [
		float(v.get("cut_m3", 0.0)), float(v.get("fill_m3", 0.0))]


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg


# ---------------------------------------------------------------------------
# Vegetation — species picker, scatter dispatch, per-plant editing.
# Every loader call here is the one the legacy veg dock makes, with the same
# parameter dict, so the two UIs paint identically while they coexist.
# ---------------------------------------------------------------------------

const PICK_RADIUS_M := 6.0
## A press that travels less than this is a click, not a drag.
const SINGLE_CLICK_PX := 6.0
const VEG_SEED := 1337
## MIX weights — the veg dock's defaults, kept identical so a MIX scatter comes
## out the same from either UI.
const MIX_WEIGHTS := {
	"pine": 0.3, "deciduous": 0.3, "shrub": 0.2,
	"grass_lawn": 0.1, "grass_field": 0.1,
}


func _is_veg_tool() -> bool:
	return String(_state.tool_def(_state.active_tool).get("section", "")) == "veg"


## Family buttons + subspecies dropdown — the "what am I painting" half of the
## options bar. Family picks the mesh archetype; the dropdown narrows it to a
## real species (spruce vs fir), which is what the style store keys its
## per-species overrides on.
func _build_species_row() -> void:
	_species_row = HBoxContainer.new()
	_species_row.add_theme_constant_override("separation", 2)
	_options_box.add_child(_species_row)
	_family_buttons.clear()
	for f in ToolbarStateScript.VEG_FAMILIES:
		var fid := String(f["id"])
		var b := Button.new()
		b.text = String(f["label"])
		b.custom_minimum_size = Vector2(48, 24)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_family_pressed.bind(fid))
		_species_row.add_child(b)
		_family_buttons[fid] = b
	_subspecies_opt = OptionButton.new()
	_subspecies_opt.custom_minimum_size = Vector2(118, 24)
	_subspecies_opt.focus_mode = Control.FOCUS_NONE
	_subspecies_opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_subspecies_opt.item_selected.connect(_on_subspecies_selected)
	_species_row.add_child(_subspecies_opt)
	# The species look editor. It used to be reachable only from the legacy
	# Shift+V dock and the library, so plain V offered no way to tune a tree.
	var tune := Button.new()
	tune.text = "Tune look…"
	tune.tooltip_text = "Preview this species and edit its size, shape, colour and foliage"
	tune.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(tune)
	tune.pressed.connect(_open_veg_tune_look)
	_species_row.add_child(tune)
	_restyle_family_buttons()
	_refresh_subspecies()
	if _state.active_tool == "veg_detect":
		_build_detect_rows()


func _restyle_family_buttons() -> void:
	for fid in _family_buttons.keys():
		_style_toggle(_family_buttons[fid], String(fid) == _state.veg_family)


func _on_family_pressed(family_id: String) -> void:
	if not _state.set_veg_family(family_id):
		return
	_restyle_family_buttons()
	_refresh_subspecies()
	_queue_save_prefs()


## MIX has no single species (the scatter rolls one per instance), so the
## dropdown reads "— mix —" and disables rather than showing a false selection.
func _refresh_subspecies() -> void:
	if _subspecies_opt == null:
		return
	_subspecies_opt.clear()
	if _state.is_mix_family():
		# The Mix family paints a whole mix (VegMix): this map's own mix, or a
		# preset / saved mix. Tune look… edits and previews it.
		_subspecies_opt.disabled = false
		_state.set_veg_species("")
		var choices: Array = [["map", "This map's mix"]]
		choices.append_array(VegMix.choices())
		var sel := 0
		for i in choices.size():
			var c: Array = choices[i]
			_subspecies_opt.add_item(str(c[1]))
			_subspecies_opt.set_item_metadata(i, "mix:" + str(c[0]))
			if str(c[0]) == _state.veg_mix_id:
				sel = i
		_subspecies_opt.select(sel)
		return
	_subspecies_opt.disabled = false
	var ids: Array = VegSpeciesCatalog.subspecies_for_family(_state.veg_family)
	if ids.is_empty():
		return
	var select_idx := 0
	for i in ids.size():
		var sid := String(ids[i])
		_subspecies_opt.add_item(VegSpeciesCatalog.label_for(sid))
		_subspecies_opt.set_item_metadata(i, sid)
		if sid == _state.veg_species:
			select_idx = i
	_subspecies_opt.select(select_idx)
	_state.set_veg_species(String(_subspecies_opt.get_item_metadata(select_idx)))


func _on_subspecies_selected(idx: int) -> void:
	if _subspecies_opt == null or _subspecies_opt.disabled:
		return
	var sid := str(_subspecies_opt.get_item_metadata(idx))
	if sid.begins_with("mix:"):
		_state.veg_mix_id = sid.substr(4)
		_queue_save_prefs()
		return
	if sid.is_empty() or not VegSpeciesCatalog.is_paintable(sid):
		return
	_state.set_veg_species(sid)
	_queue_save_prefs()


## Density scales SPACING, not a count — the same rule the generator's area
## fill uses, so "twice as dense" means the same thing everywhere.
func _effective_spacing() -> float:
	var base := VegetationPaint.default_spacing_for_preset(_state.veg_preset_index())
	return maxf(0.35, base / maxf(_state.get_param("density", 1.0), 0.25))


func _scatter_params() -> Dictionary:
	var scales: Vector2 = VegetationStyleConfig.scales_from_size_var(_state.size_var_fraction())
	var brush_scale := clampf(_state.get_param("scale", 1.0), 0.1, 5.0)
	var params := {
		"preset": _state.veg_preset_index(),
		"spacing_m": _effective_spacing(),
		"scale_min": scales.x * brush_scale,
		"scale_max": scales.y * brush_scale,
		"density": _state.get_param("density", 1.0),
		"size_var": _state.size_var_fraction(),
		"scale": brush_scale,
		"seed": VEG_SEED,
		"mix_pine": float(MIX_WEIGHTS["pine"]),
		"mix_deciduous": float(MIX_WEIGHTS["deciduous"]),
		"mix_shrub": float(MIX_WEIGHTS["shrub"]),
		"mix_grass_lawn": float(MIX_WEIGHTS["grass_lawn"]),
		"mix_grass_field": float(MIX_WEIGHTS["grass_field"]),
		"plant_young": false,
	}
	if not _state.is_mix_family() and VegSpeciesCatalog.is_paintable(_state.veg_species):
		params["species"] = _state.veg_species
	if _state.is_mix_family():
		params["mix"] = _active_mix()
	return params


## The paint brush as the Tune-look modal sees it.
func get_veg_brush() -> Dictionary:
	return {
		"density": _state.get_tool_param_value("veg_paint", "density"),
		"size_var": clampf(_state.get_tool_param_value("veg_paint", "size_var") / 100.0, 0.0, 0.5),
		"scale": _state.get_tool_param_value("veg_paint", "scale"),
		"mix_id": _state.veg_mix_id,
		"family": _state.veg_family,
	}


## The Tune-look modal hands its brush back: density, size variation, plant
## scale, and either a mix ("mix_id") or a species.
func set_veg_brush(b: Dictionary) -> void:
	if b.has("density"):
		_state.set_tool_param("veg_paint", "density", float(b["density"]))
	if b.has("size_var"):
		_state.set_tool_param("veg_paint", "size_var", float(b["size_var"]) * 100.0)
	if b.has("scale"):
		_state.set_tool_param("veg_paint", "scale", float(b["scale"]))
	if b.has("mix_id"):
		_state.set_veg_family("mix")
		_state.veg_mix_id = str(b["mix_id"])
	elif b.has("species"):
		var sid := str(b["species"])
		var fam := VegSpeciesCatalog.mesh_family(sid)
		for f in ToolbarStateScript.VEG_FAMILIES:
			if String(f["id"]) == fam:
				_state.set_veg_family(fam)
				break
		_state.set_veg_species(sid)
	_queue_save_prefs()
	if visible and _is_veg_tool():
		_rebuild_options_bar()


## The mix the Mix family paints: this map's own, or the chosen preset.
func _active_mix() -> Dictionary:
	if _state.veg_mix_id != "map":
		var m := VegMix.preset(_state.veg_mix_id)
		if not m.is_empty():
			return m
	if _loader != null and _loader.has_method("get_paint_mix"):
		return _loader.call("get_paint_mix")
	return VegMix.preset("mixed_woodland")


func _species_label() -> String:
	if not _state.is_mix_family() and not _state.veg_species.is_empty():
		return VegSpeciesCatalog.label_for(_state.veg_species).to_lower()
	return _state.veg_family


func _push_veg_undo(label: String) -> void:
	if _loader != null and _loader.has_method("push_vegetation_undo"):
		_loader.call("push_vegetation_undo", label)
	_update_undo_button()


# --- Paint / Clear strokes -------------------------------------------------

func _begin_veg_stroke(world: Vector2) -> void:
	_stroking = true
	_veg_undo_pushed = false
	_last_stamp = Vector2(-1e9, -1e9)
	# Remember the press so a stroke that never really moves can resolve as
	# "drop ONE plant here" instead of a one-stamp scatter.
	_paint_click_candidate = _state.active_tool == "veg_paint"
	_paint_press_px = get_viewport().get_mouse_position()
	_stamp_veg_at(world)


func _end_veg_stroke() -> void:
	var was_click := _paint_click_candidate \
		and get_viewport().get_mouse_position().distance_to(_paint_press_px) < SINGLE_CLICK_PX
	_stroking = false
	_paint_click_candidate = false
	_veg_undo_pushed = false
	_last_stamp = Vector2(-1e9, -1e9)
	if was_click and _cursor_hit is Vector3:
		_place_single_plant_at(_cursor_hit as Vector3)
	_update_undo_button()
	if _loader != null and _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")


## One stamp per brush-radius of travel — sampling every frame would place
## thousands of overlapping plants under a slow drag.
func _stamp_veg_at(world: Vector2) -> void:
	if _loader == null:
		return
	var radius := _state.get_param("radius_m", 4.0)
	var min_step := maxf(radius * 0.45, _effective_spacing() * 0.85)
	if _last_stamp.x > -1e8 and world.distance_to(_last_stamp) < min_step:
		return
	_last_stamp = world
	if not _veg_undo_pushed:
		_push_veg_undo("brush")
		_veg_undo_pushed = true
	var poly := VegetationPaint.circle_polygon(world, radius, 24)
	if _state.active_tool == "veg_clear":
		_clear_veg_in(poly)
	elif _state.active_tool == "veg_paint":
		if _loader.has_method("populate_vegetation"):
			var n := int(_loader.call("populate_vegetation", poly, _scatter_params()))
			if n > 0:
				_set_status("Painted %d %s" % [n, _species_label()])


## Region (circle / rect / lasso / polygon) apply for the veg tools.
func _apply_veg_region(poly: PackedVector2Array) -> void:
	if _loader == null:
		return
	match _state.active_tool:
		"veg_paint":
			if not _loader.has_method("populate_vegetation"):
				return
			_push_veg_undo("paint")
			var n := int(_loader.call("populate_vegetation", poly, _scatter_params()))
			if n > 0:
				_set_status("Painted %d %s" % [n, _species_label()])
			else:
				_set_status("No vegetation placed (~%.0f m2) — widen the area or raise density"
					% VegetationPaint.polygon_area(poly))
		"veg_clear":
			_push_veg_undo("clear")
			_clear_veg_in(poly)
			_set_status("Cleared ~%.0f m2" % VegetationPaint.polygon_area(poly))
		"veg_detect":
			_detect_poly = poly.duplicate()
			_run_detect_preview()
	if _loader.has_method("clear_vegetation_highlight"):
		_loader.call("clear_vegetation_highlight")
	_update_undo_button()


## Clear BOTH layers: hand-painted plants and the auto-scattered OSM forest.
## Erasing only one leaves the other standing and reads as "clear did nothing".
func _clear_veg_in(poly: PackedVector2Array) -> void:
	if _loader.has_method("clear_vegetation_in_polygon"):
		_loader.call("clear_vegetation_in_polygon", poly)
	if _loader.has_method("clear_auto_vegetation_in_polygon"):
		_loader.call("clear_auto_vegetation_in_polygon", poly)


# --- Single placements -----------------------------------------------------

func _resolve_single_species() -> String:
	if not _state.is_mix_family() and VegSpeciesCatalog.is_paintable(_state.veg_species):
		return _state.veg_species
	if not _state.is_mix_family():
		return _state.veg_family
	# One plant from the mix: its canopy pick at a random draw (the patch noise
	# needs a position, but a single click is a single tree — the plain
	# weights are the honest answer).
	var rng := RandomNumberGenerator.new()
	rng.seed = VEG_SEED ^ int(Time.get_ticks_usec())
	var mix := VegMix.normalized(_active_mix())
	mix["patchiness"] = 0.0
	var sid := VegMix.pick_tree(mix, 0.0, 0.0, rng.randf())
	return sid if not sid.is_empty() else "deciduous"


func _place_single_plant_at(p: Vector3) -> void:
	if _loader == null or not _loader.has_method("place_single_vegetation"):
		return
	var species := _resolve_single_species()
	if species.is_empty():
		return
	_push_veg_undo("place one")
	if bool(_loader.call("place_single_vegetation", species, p.x, p.z, _scatter_params())):
		_set_status("Placed 1 %s — click to add more, drag to scatter" % _species_label())
	else:
		_set_status("Could not place %s (capacity reached?)" % _species_label())


func _place_hero_at(p: Vector3) -> void:
	if _loader == null or not _loader.has_method("place_hero_tree"):
		return
	# Hero placement pushes an undo entry — a misplaced 20 m tree is otherwise
	# only removable by hunting for it.
	_push_veg_undo("place hero")
	if bool(_loader.call("place_hero_tree", _state.hero_preset, p.x, p.z,
			_state.get_param("hero_scale", 1.0), p.y)):
		_set_status("Placed hero %s" % _state.hero_preset)
	else:
		_set_status("Could not place hero tree (limit reached?)")
	_update_undo_button()


# --- Select: per-plant editing ---------------------------------------------

func _pick_plant_at(world_xz: Vector2) -> void:
	if _loader == null or not _loader.has_method("veg_pick_near"):
		return
	# The plant the pointer is over (a ray through the crowns), else the one
	# nearest the ground point — painted or OSM forest alike.
	var desc: Dictionary = _hover_plant
	if desc.is_empty():
		desc = _loader.call("veg_pick_at_screen", _pointer_screen())
	if desc.is_empty():
		desc = _loader.call("veg_pick_near", world_xz, PICK_RADIUS_M)
	if desc.is_empty():
		_picked_plant = {}
		_set_status("No plant within %.0f m" % PICK_RADIUS_M)
		return
	_picked_plant = desc
	var keys := "Del deletes · [ / ] resize"
	if str(desc.get("source", "")) == "painted" and str(desc.get("kind", "")) != "hero":
		keys += " · H → hero"
	_set_status("%s · %s" % [_select_label(desc), keys])
	if _lmb_shift or str(desc.get("kind", "")) == "hero":
		return
	if _loader.has_method("open_vegetation_instance_editor"):
		_loader.call("open_vegetation_instance_editor", desc)


static func _select_label(desc: Dictionary) -> String:
	return "%s (%s) · %.0f m" % [str(desc.get("label", "plant")),
		str(desc.get("source_label", "")), float(desc.get("height_m", 0.0))]


func _pointer_screen() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		return vp.get_visible_rect().size * 0.5
	return vp.get_mouse_position()


## Select hover: label + ring on the plant under the pointer, every plant of
## its species glowing. 20 Hz at most — the pick is a grid walk, but it runs
## on every pointer move.
func _update_veg_hover() -> void:
	if _loader == null or not _loader.has_method("veg_pick_at_screen"):
		return
	var now := Time.get_ticks_msec()
	if now - _hover_ms < 50:
		# Throttled: force a re-run next frame, or the pointer's final resting
		# place (no further motion) would never be picked.
		_last_pointer_px = Vector2(-1e9, -1e9)
		return
	_hover_ms = now
	if _pointer_over_ui() or CursorController.has_blocking_modal():
		_clear_veg_hover()
		return
	var desc: Dictionary = _loader.call("veg_pick_at_screen", _pointer_screen())
	_hover_plant = desc
	_loader.call("set_veg_hover", desc)
	if not desc.is_empty() and _picked_plant.is_empty():
		_set_status("%s — click to tune this tree, Shift+click to select" % _select_label(desc))


func _clear_veg_hover() -> void:
	_hover_plant = {}
	if _loader != null and _loader.has_method("clear_veg_hover"):
		_loader.call("clear_veg_hover")


func _delete_picked_plant() -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("delete_plant_at"):
		return
	_push_veg_undo("delete plant")
	var gone := _picked_plant
	if not bool(_loader.call("delete_veg_plant", _picked_plant)):
		_set_status("Nothing deleted — pick a plant first")
		return
	_picked_plant = {}
	_clear_veg_hover()
	_set_status("Deleted %s — Undo restores it" % _select_label(gone))


## Promote the picked card plant to a hero GLB at the same spot and apparent
## size. The SPECIES chooses the model, so a pine becomes a pine.
func _convert_picked_to_hero() -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("convert_plant_to_hero_at"):
		return
	if str(_picked_plant.get("kind", "")) == "hero":
		_set_status("Already a hero tree")
		return
	if str(_picked_plant.get("source", "painted")) != "painted":
		_set_status("Only painted plants become hero models (this one is OSM forest)")
		return
	_push_veg_undo("convert to hero")
	var at := Vector2(float(_picked_plant.get("x", 0.0)), float(_picked_plant.get("z", 0.0)))
	var res: Dictionary = _loader.call("convert_plant_to_hero_at", at, PICK_RADIUS_M)
	if res.is_empty():
		_set_status("Could not convert (hero limit reached?)")
		return
	_picked_plant = _loader.call("pick_plant_at", at, PICK_RADIUS_M)
	_set_status("Converted to hero %s at %.1f m" % [
		str(res.get("preset", "")), float(res.get("height_m", 0.0))])


func _resize_picked_plant(factor: float) -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("scale_plant_at"):
		return
	_push_veg_undo("resize plant")
	var at := Vector2(float(_picked_plant.get("x", 0.0)), float(_picked_plant.get("z", 0.0)))
	if not bool(_loader.call("scale_veg_plant", _picked_plant, factor)):
		return
	# Re-read the record so the readout shows the NEW size, not the old one.
	var again: Dictionary = _loader.call("veg_pick_near", at, 0.6)
	if not again.is_empty():
		_picked_plant = again
	_set_status("Resized %s" % _select_label(_picked_plant))


# --- Detect: plants from the satellite photo ---------------------------------
# Draw a region (or take the whole hi-res area) → the green it finds is laid on
# the ground as a preview → Plant (or Enter) adds them as painted plants of the
# chosen type. Every slider re-runs the preview. TerrainLoader + VegColorDetect
# do the work; this only turns gestures into calls.

func _build_detect_rows() -> void:
	var whole := Button.new()
	whole.text = "Whole hi-res area"
	whole.tooltip_text = "Detect over the whole square the sharpest photo covers"
	whole.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(whole)
	whole.pressed.connect(_detect_whole_area)
	_options_box.add_child(whole)
	var plant := Button.new()
	plant.text = "Plant them"
	plant.tooltip_text = "Add what the preview found as painted plants (Enter). Undo takes them back."
	plant.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(plant)
	plant.pressed.connect(_place_detected)
	_options_box.add_child(plant)
	_detect_stats_lbl = Label.new()
	_detect_stats_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_detect_stats_lbl.add_theme_color_override("font_color", UITheme.C_OK)
	_detect_stats_lbl.text = "Draw an area to find the plants in the photo"
	_options_box.add_child(_detect_stats_lbl)


func _detect_params() -> Dictionary:
	var p := _scatter_params()
	for k in ["sensitivity", "max_luma", "min_patch_m2", "single_max_d_m", "shrub_below_m"]:
		p[k] = _state.get_param(k, float(VegColorDetect.DEFAULTS.get(k, 0.0)))
	return p


func _detect_whole_area() -> void:
	if _loader == null or not _loader.has_method("veg_detect_whole_area"):
		return
	var poly: PackedVector2Array = _loader.call("veg_detect_whole_area")
	if poly.size() < 3:
		_set_status("No satellite photo loaded yet")
		return
	_detect_poly = poly
	_run_detect_preview()


func _queue_detect_preview() -> void:
	if _detect_timer == null:
		_detect_timer = Timer.new()
		_detect_timer.one_shot = true
		_detect_timer.wait_time = 0.3
		_detect_timer.timeout.connect(_run_detect_preview)
		add_child(_detect_timer)
	_detect_timer.start()


func _run_detect_preview() -> void:
	if _detect_poly.size() < 3 or _loader == null:
		return
	_set_detect_text("Looking for green in the photo…")
	await get_tree().process_frame
	if _detect_poly.size() < 3:
		return
	var st: Dictionary = _loader.call("preview_veg_detect", _detect_poly, _detect_params())
	_set_detect_text(_detect_summary(st))
	_queue_overlay_redraw()


func _place_detected() -> void:
	if _detect_poly.size() < 3 or _loader == null:
		_set_status("Draw an area first")
		return
	_push_veg_undo("detect")
	var st: Dictionary = _loader.call("place_detected_vegetation", _detect_poly, _detect_params())
	var added := int(st.get("added", 0))
	var parts: Array = []
	var by: Dictionary = st.get("by_species", {})
	for sid in by:
		parts.append(UiText.count(int(by[sid]), VegSpeciesCatalog.label_for(str(sid)).to_lower()))
	var msg := "Planted %s" % (", ".join(parts) if not parts.is_empty() else "nothing")
	if int(st.get("skipped", 0)) > 0:
		msg += " · %d skipped (road, building, water or a plant already there)" % int(st["skipped"])
	_set_status(msg)
	_set_detect_text(msg)
	_detect_poly = PackedVector2Array()
	_update_undo_button()
	_queue_overlay_redraw()


func _detect_summary(st: Dictionary) -> String:
	if st.has("error"):
		return str(st["error"])
	var area := float(st.get("area_m2", 0.0))
	var green := float(st.get("green_m2", 0.0))
	var pct := 100.0 * green / maxf(area, 1.0)
	var how := "auto cut %.2f" % float(st.get("cut", 0.0))
	if bool(st.get("auto", true)) and not bool(st.get("auto_split", false)):
		how = "no clear green/ground split — default cut"
	var res := float(st.get("mpp", INF))
	var res_txt := (" · photo %.2f m/px" % res) if is_finite(res) else ""
	return "%s green (%.0f %%) · %s → %s%s · %s · Enter or Plant them" % [
		UiText.num(green, "m²"), pct, UiText.count(int(st.get("patches", 0)), "patch", "patches"),
		UiText.count(int(st.get("plants", 0)), "plant"),
		(" (%d canopy)" % int(st.get("canopy", 0))) if int(st.get("canopy", 0)) > 0 else "",
		how + res_txt]


func _set_detect_text(t: String) -> void:
	if _detect_stats_lbl != null and is_instance_valid(_detect_stats_lbl):
		_detect_stats_lbl.text = t
	_set_status(t)


## `release`: the tool is being put down — also drop the CPU photo copies.
func _end_detect(release: bool) -> void:
	_detect_poly = PackedVector2Array()
	if _loader == null:
		return
	if release and _loader.has_method("release_veg_detect_cache"):
		_loader.call("release_veg_detect_cache")
	elif _loader.has_method("clear_veg_detect_preview"):
		_loader.call("clear_veg_detect_preview")
	_queue_overlay_redraw()


# ---------------------------------------------------------------------------
# Camps — paint / erase / plots / edit. The loader owns the camp layer
# (core/camps/); this file only turns gestures into its commands.
# ---------------------------------------------------------------------------

## Stamps closer together than this fraction of the brush radius are skipped.
const CAMP_STAMP_STEP := 0.4


func _is_camp_tool() -> bool:
	return String(_state.tool_def(_state.active_tool).get("section", "")) == "camps"


func _camp_params() -> Dictionary:
	return {
		"style": _state.camp_style_for_tool(),
		"density": _state.get_param("density", 0.8),
		"heading_deg": _state.get_param("heading_deg", -1.0),
		"align_jitter_deg": _state.get_param("align_jitter_deg", 5.0),
		"light_density": _state.get_param("light_density", 1.0),
	}


func _camp_totals() -> String:
	if _loader == null or not _loader.has_method("camp_areas_summary"):
		return ""
	var s: Dictionary = _loader.call("camp_areas_summary")
	return "%s, %s" % [UiText.count(int(s.get("areas", 0)), "camp"), UiText.count(int(s.get("structures", 0)), "structure")]


func _push_camp_undo() -> void:
	if _loader != null and _loader.has_method("push_camp_undo"):
		_loader.call("push_camp_undo")
	_update_undo_button()


# --- Options bar rows -------------------------------------------------------

func _build_camp_rows() -> void:
	_camp_style_buttons.clear()
	_camp_action_buttons.clear()
	_camp_name_edit = null
	var tool_id := _state.active_tool
	if tool_id != "camp_erase":
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		_options_box.add_child(row)
		for s in ToolbarStateScript.CAMP_STYLES:
			var sid := String(s["id"])
			# "Varied" (one style per plot) only exists for the Plots tool.
			if sid == "varied" and tool_id != "camp_subdivide":
				continue
			var b := Button.new()
			b.text = String(s["label"])
			b.tooltip_text = CampStyles.label(sid)
			b.custom_minimum_size = Vector2(48, 24)
			b.focus_mode = Control.FOCUS_NONE
			b.pressed.connect(_on_camp_style_pressed.bind(sid))
			row.add_child(b)
			_camp_style_buttons[sid] = b
		_restyle_camp_style_buttons()
		var tune := Button.new()
		tune.text = "Tune look…"
		tune.tooltip_text = "Preview a camp style and edit its mix, spacing and models"
		tune.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(tune)
		tune.pressed.connect(_open_camp_tune_look)
		_options_box.add_child(tune)
	if tool_id == "camp_select":
		_camp_name_edit = LineEdit.new()
		_camp_name_edit.placeholder_text = "click a camp"
		_camp_name_edit.custom_minimum_size = Vector2(120, 24)
		_camp_name_edit.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		_camp_name_edit.text_submitted.connect(_on_camp_name_submitted)
		_options_box.add_child(_camp_name_edit)
		for spec in [["Reseed", "Roll a different arrangement for this camp", "_reseed_picked_camp"],
				["Delete", "Delete this camp (Del)", "_delete_picked_camp"]]:
			var ab := Button.new()
			ab.text = String(spec[0])
			ab.tooltip_text = String(spec[1])
			ab.focus_mode = Control.FOCUS_NONE
			UITheme.style_button(ab)
			ab.pressed.connect(Callable(self, String(spec[2])))
			_options_box.add_child(ab)
			_camp_action_buttons.append(ab)
		_sync_camp_select_controls()


func _restyle_camp_style_buttons() -> void:
	var cur := _state.camp_style_for_tool()
	if _state.active_tool == "camp_select":
		# In Edit the row shows the PICKED camp's style, not the brush's.
		cur = str(_picked_camp_info().get("style", ""))
	for sid in _camp_style_buttons.keys():
		_style_toggle(_camp_style_buttons[sid], String(sid) == cur)


func _on_camp_style_pressed(style_id: String) -> void:
	if _state.active_tool == "camp_select":
		if _picked_camp.is_empty() or _loader == null:
			_set_status("Click a camp first")
			return
		_push_camp_undo()
		_loader.call("update_camp_area", _picked_camp, {"style": style_id})
		_restyle_camp_style_buttons()
		_report_picked_camp()
		return
	if not _state.set_camp_style(style_id):
		return
	_restyle_camp_style_buttons()
	_queue_save_prefs()


# --- Brush strokes ----------------------------------------------------------

func _begin_camp_stroke(world: Vector2) -> void:
	_stroking = true
	_camp_stroke.clear()
	_last_stamp = Vector2(-1e9, -1e9)
	_stamp_camp_at(world)


## Grow the stroke outline by one brush circle. Nothing is built yet.
func _stamp_camp_at(world: Vector2) -> void:
	var radius := _state.get_param("radius_m", 12.0)
	if _last_stamp.x > -1e8 and world.distance_to(_last_stamp) < radius * CAMP_STAMP_STEP:
		return
	_last_stamp = world
	var acc := VegetationPaint.circle_polygon(world, radius, 20)
	var rest: Array = []
	for ring: PackedVector2Array in _camp_stroke:
		var outers: Array = []
		for piece: PackedVector2Array in Geometry2D.merge_polygons(acc, ring):
			# Clockwise pieces are holes (a stroke that loops back on itself);
			# a looped stroke simply fills its middle.
			if not Geometry2D.is_polygon_clockwise(piece):
				outers.append(piece)
		if outers.size() == 1:
			acc = outers[0]
		else:
			rest.append(ring)
	rest.append(acc)
	_camp_stroke = rest
	_queue_overlay_redraw()


func _end_camp_stroke() -> void:
	_stroking = false
	_last_stamp = Vector2(-1e9, -1e9)
	var rings := _camp_stroke.duplicate()
	_camp_stroke.clear()
	if _loader == null or rings.is_empty():
		return
	_push_camp_undo()
	for ring: PackedVector2Array in rings:
		_commit_camp_polygon(ring)
	_update_undo_button()
	_queue_overlay_redraw()


## Region (circle / rect / lasso / polygon) apply for the camp tools.
func _apply_camp_region(poly: PackedVector2Array) -> void:
	if _loader == null:
		return
	_push_camp_undo()
	if _state.active_tool == "camp_subdivide":
		var params := _camp_params()
		params["plot_w_m"] = _state.get_param("plot_w_m", 30.0)
		params["plot_d_m"] = _state.get_param("plot_d_m", 22.0)
		params["lane_w_m"] = _state.get_param("lane_w_m", 6.0)
		var ids: Array = _loader.call("subdivide_camp_zone", poly, params)
		if ids.is_empty():
			_set_status("Zone too small for one plot — draw it larger or shrink the plot size")
		else:
			_set_status("Zone split into %s — %s" % [UiText.count(ids.size(), "plot"), _camp_totals()])
	else:
		_commit_camp_polygon(poly)
	_update_undo_button()


func _commit_camp_polygon(poly: PackedVector2Array) -> void:
	if _state.active_tool == "camp_erase":
		var n := int(_loader.call("erase_camps_in_polygon", poly))
		_set_status("Erased from %d camp%s — %s" % [n, "" if n == 1 else "s", _camp_totals()]
			if n > 0 else "No camp there to erase")
		return
	var id := str(_loader.call("paint_camp_area", poly, _camp_params()))
	if id.is_empty():
		_set_status("Too small for a camp — paint a larger area")
		return
	var info: Dictionary = _loader.call("camp_area_info", id)
	var stats: Dictionary = info.get("stats", {})
	if bool(stats.get("over_budget", false)):
		_set_status("Camp budget reached — erase some camps or lower density")
	elif int(info.get("structures", 0)) == 0:
		_set_status("%s: nothing fits (too small, too steep, or on a road/building)"
			% str(info.get("name", "Camp")))
	else:
		_set_status("%s — %s, %s, %.0f m2" % [str(info.get("name", "Camp")),
			UiText.count(int(info.get("structures", 0)), "structure"), CampStyles.label(str(info.get("style", ""))),
			float(info.get("area_m2", 0.0))])


# --- Edit (select) ----------------------------------------------------------

func _picked_camp_info() -> Dictionary:
	if _picked_camp.is_empty() or _loader == null or not _loader.has_method("camp_area_info"):
		return {}
	return _loader.call("camp_area_info", _picked_camp)


func _pick_camp_at(world: Vector2) -> void:
	if _loader == null or not _loader.has_method("camp_area_at"):
		return
	var id := str(_loader.call("camp_area_at", world))
	if id.is_empty():
		_clear_picked_camp()
		_set_status("No camp here — click inside a painted camp")
		return
	_picked_camp = id
	_loader.call("update_camp_highlight", id)
	_sync_camp_select_controls()
	_report_picked_camp()


func _clear_picked_camp() -> void:
	if _camp_apply_timer != null:
		_camp_apply_timer.stop()
	if _picked_camp.is_empty():
		return
	_picked_camp = ""
	if _loader != null and _loader.has_method("clear_camp_highlight"):
		_loader.call("clear_camp_highlight")
	_sync_camp_select_controls()


func _report_picked_camp() -> void:
	var info := _picked_camp_info()
	if info.is_empty():
		return
	_set_status("%s — %s, %s, heading %.0f%s" % [str(info.get("name", "")),
		UiText.count(int(info.get("structures", 0)), "structure"), CampStyles.label(str(info.get("style", ""))),
		float(info.get("heading_deg", 0.0)),
		" (auto)" if bool(info.get("heading_auto", false)) else ""])


## Load the picked camp's settings into the Edit tool's sliders. Setting a
## slider re-fires its handler, which queues an apply — harmless, because the
## apply compares against the record and finds nothing to change.
func _sync_camp_select_controls() -> void:
	var info := _picked_camp_info()
	var have := not info.is_empty()
	if _camp_name_edit != null and is_instance_valid(_camp_name_edit):
		_camp_name_edit.editable = have
		_camp_name_edit.text = str(info.get("name", "")) if have else ""
	for b in _camp_action_buttons:
		if is_instance_valid(b):
			b.disabled = not have
	if have and _state.active_tool == "camp_select":
		for key in ["density", "heading_deg", "align_jitter_deg", "light_density", "headcount"]:
			_state.set_param(key, float(info.get(key, _state.get_param(key))))
			if _param_rows.has(key):
				SliderSpinRow.set_values(_param_rows[key], _state.get_param(key))
	_restyle_camp_style_buttons()


## Push the Edit sliders onto the picked camp — only the values that differ.
func _apply_camp_select_params() -> void:
	if _state.active_tool != "camp_select" or _loader == null:
		return
	var info := _picked_camp_info()
	if info.is_empty():
		return
	var patch := {}
	for key in ["density", "align_jitter_deg", "light_density"]:
		if absf(float(info.get(key, 0.0)) - _state.get_param(key)) > 0.001:
			patch[key] = _state.get_param(key)
	var people := int(round(_state.get_param("headcount", 0.0)))
	if people != int(info.get("headcount", 0)):
		patch["headcount"] = people
	var heading := _state.get_param("heading_deg", -1.0)
	if heading < 0.0:
		if not bool(info.get("heading_auto", false)):
			patch["heading_deg"] = -1.0
	elif absf(float(info.get("heading_deg", 0.0)) - heading) > 0.01:
		patch["heading_deg"] = heading
	if patch.is_empty():
		return
	_push_camp_undo()
	_loader.call("update_camp_area", _picked_camp, patch)
	_loader.call("update_camp_highlight", _picked_camp)
	# An auto heading resolves to a number; show it.
	_sync_camp_select_controls()
	_report_picked_camp()


func _on_camp_name_submitted(text: String) -> void:
	if _camp_name_edit != null:
		_camp_name_edit.release_focus()
	if _picked_camp.is_empty() or _loader == null or text.strip_edges().is_empty():
		return
	_push_camp_undo()
	_loader.call("update_camp_area", _picked_camp, {"name": text.strip_edges()})
	_report_picked_camp()


func _reseed_picked_camp() -> void:
	if _picked_camp.is_empty() or _loader == null:
		return
	_push_camp_undo()
	_loader.call("update_camp_area", _picked_camp, {"seed": randi() & 0x7fffffff})
	_report_picked_camp()


func _delete_picked_camp() -> void:
	if _picked_camp.is_empty() or _loader == null:
		return
	var gone := str(_picked_camp_info().get("name", "Camp"))
	_push_camp_undo()
	_loader.call("delete_camp_area", _picked_camp)
	_clear_picked_camp()
	_set_status("Deleted %s — %s" % [gone, _camp_totals()])


## Open the vegetation Tune-look modal on the species the toolbar is painting
## (the family's generic id when no subspecies is picked; Mix opens on the
## deciduous family, the dominant tree in the default mix).
func _open_veg_tune_look() -> void:
	if _loader == null or not _loader.has_method("open_vegetation_preview_editor"):
		return
	if _state.is_mix_family():
		# The mix editor (Tune look → Mixed woodland), on the mix the brush paints.
		_loader.call("open_vegetation_preview_editor", int(VegetationPaint.Preset.MIX), "")
		return
	var sp := _state.veg_species
	if sp.is_empty() or not VegSpeciesCatalog.is_paintable(sp):
		sp = _state.veg_family
	_loader.call("open_vegetation_preview_editor", -1, sp)


func _open_camp_tune_look() -> void:
	if _loader == null or not _loader.has_method("open_camp_style_modal"):
		return
	var sid := _state.camp_style_for_tool()
	# With a camp picked in Edit, tune THAT camp (its own elements and settings).
	if _state.active_tool == "camp_select" and not _picked_camp.is_empty() \
			and _loader.has_method("open_camp_tune_for_camp"):
		_loader.call("open_camp_tune_for_camp", _picked_camp)
		return
	if sid == "varied":
		sid = "mixed"
	_loader.call("open_camp_style_modal", sid)


# ---------------------------------------------------------------------------
# Placement — festival roads, theme-camp zones, fair lots, roster assignment.
# The loader owns the layer (core/camps/festival_*); this file only turns
# gestures into its commands and draws the overlay. Undo here snapshots BOTH
# the placement layer and the camp layer (a lot is a camp record too).
# ---------------------------------------------------------------------------

## {kind: ""|"road"|"zone"|"lot", id}
var _picked_place := {"kind": "", "id": ""}
var _place_style_buttons: Dictionary = {}
var _place_feature_buttons: Dictionary = {}
var _place_surface_opt: OptionButton = null
var _place_name_edit: LineEdit = null
var _place_roster_opt: OptionButton = null
var _place_readout: Label = null
var _place_equalise_btn: Button = null
var _place_cutnow_btn: Button = null
var _place_lock_btn: Button = null
var _place_action_buttons: Array[Button] = []
var _place_apply_timer: Timer = null
## Roster entry picked in the Assign tool ("" = none).
var _place_roster_pick := ""
## Lot colours by fairness (usable / zone mean).
const LOT_FAIR_GREEN := Color(0.45, 0.9, 0.5, 0.9)
const LOT_FAIR_AMBER := Color(0.95, 0.75, 0.3, 0.9)
const LOT_FAIR_RED := Color(0.95, 0.4, 0.4, 0.9)
const ZONE_COLOR := Color(0.9, 0.55, 0.95, 0.8)
const ROAD_COLOR := Color(0.95, 0.9, 0.7, 0.85)


func _is_placement_tool() -> bool:
	return String(_state.tool_def(_state.active_tool).get("section", "")) == "placement"


func _ensure_place_timer() -> void:
	if _place_apply_timer != null:
		return
	_place_apply_timer = Timer.new()
	_place_apply_timer.one_shot = true
	_place_apply_timer.wait_time = 0.25
	_place_apply_timer.timeout.connect(_apply_place_edit_params)
	add_child(_place_apply_timer)


func _push_place_undo() -> void:
	if _loader != null and _loader.has_method("push_placement_undo"):
		_loader.call("push_placement_undo")
	_update_undo_button()


func _place_summary_text(zone_id: String = "") -> String:
	if _loader == null or not _loader.has_method("placement_summary"):
		return ""
	var s: Dictionary = _loader.call("placement_summary", zone_id)
	if s.is_empty():
		return ""
	var txt := "%s · %s · %s · ~%s" % [
		UiText.count(int(s.get("roads", 0)), "road"), UiText.count(int(s.get("zones", 0)), "zone"),
		UiText.count(int(s.get("lots", 0)), "lot"), UiText.count(int(s.get("people", 0)), "person")]
	if int(s.get("roster", 0)) > 0:
		txt += " · roster %d/%d placed" % [int(s.get("roster", 0)) - int(s.get("unplaced", 0)),
			int(s.get("roster", 0))]
	return txt


func _zone_readout(zone_id: String) -> String:
	if _loader == null:
		return ""
	var info: Dictionary = _loader.call("placement_info", "zone", zone_id)
	if info.is_empty():
		return ""
	var st: Dictionary = info.get("stats", {})
	if st.is_empty():
		return "%s — %.0f m², not cut yet" % [str(info.get("name", "Zone")), float(info.get("area_m2", 0.0))]
	return "%s — usable %.0f / %.0f m² · %s · %.0f–%.0f m² (max/min %.2f, Gini %.2f) · ~%s" % [
		str(info.get("name", "Zone")), float(st.get("usable_m2", 0.0)), float(st.get("raw_m2", 0.0)),
		UiText.count(int(st.get("lots", 0)), "lot"), float(st.get("usable_min", 0.0)), float(st.get("usable_max", 0.0)),
		float(st.get("ratio_max_min", 0.0)), float(st.get("gini", 0.0)), UiText.count(int(st.get("capacity_people", 0)), "person")]


# --- Options bar rows -------------------------------------------------------

func _build_placement_rows() -> void:
	_ensure_place_timer()
	_place_style_buttons.clear()
	_place_feature_buttons.clear()
	_place_action_buttons.clear()
	_place_surface_opt = null
	_place_name_edit = null
	_place_roster_opt = null
	_place_equalise_btn = null
	_place_cutnow_btn = null
	_place_lock_btn = null
	var tool_id := _state.active_tool
	match tool_id:
		"fest_road":
			_place_surface_opt = OptionButton.new()
			_place_surface_opt.custom_minimum_size = Vector2(84, 24)
			_place_surface_opt.focus_mode = Control.FOCUS_NONE
			_place_surface_opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			for s in ToolbarStateScript.PLACEMENT_SURFACES:
				_place_surface_opt.add_item(String(s).capitalize())
			_place_surface_opt.select(ToolbarStateScript.PLACEMENT_SURFACES.find(_state.placement_surface))
			_place_surface_opt.item_selected.connect(func(i: int) -> void:
				_state.set_placement_surface(String(ToolbarStateScript.PLACEMENT_SURFACES[i]))
				_queue_save_prefs())
			_options_box.add_child(_place_surface_opt)
			_place_name_edit = LineEdit.new()
			_place_name_edit.placeholder_text = "road name"
			_place_name_edit.custom_minimum_size = Vector2(110, 24)
			_place_name_edit.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			_options_box.add_child(_place_name_edit)
		"fest_zone":
			_build_place_style_chips(true)
			_build_place_feature_chips()
			_place_equalise_btn = Button.new()
			_place_equalise_btn.focus_mode = Control.FOCUS_NONE
			_place_equalise_btn.custom_minimum_size = Vector2(96, 24)
			_place_equalise_btn.tooltip_text = "Equalise lots by USABLE ground (slope + obstacles count) or by raw area"
			_place_equalise_btn.pressed.connect(func() -> void:
				_state.set_placement_equalise("raw" if _state.placement_equalise == "usable" else "usable")
				_refresh_place_toggle_buttons()
				_queue_save_prefs())
			_options_box.add_child(_place_equalise_btn)
			_place_cutnow_btn = Button.new()
			_place_cutnow_btn.focus_mode = Control.FOCUS_NONE
			_place_cutnow_btn.custom_minimum_size = Vector2(72, 24)
			_place_cutnow_btn.tooltip_text = "Cut a drawn zone into lots at once (off: draw now, cut with the Lots tool)"
			_place_cutnow_btn.pressed.connect(func() -> void:
				_state.placement_subdivide_now = not _state.placement_subdivide_now
				_refresh_place_toggle_buttons()
				_queue_save_prefs())
			_options_box.add_child(_place_cutnow_btn)
			_refresh_place_toggle_buttons()
		"fest_lots":
			_add_place_action("Cut all zones", "Re-cut every zone with its own settings", "_cut_all_zones")
		"fest_assign":
			_place_roster_opt = OptionButton.new()
			_place_roster_opt.custom_minimum_size = Vector2(140, 24)
			_place_roster_opt.focus_mode = Control.FOCUS_NONE
			_place_roster_opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			_place_roster_opt.item_selected.connect(_on_roster_selected)
			_options_box.add_child(_place_roster_opt)
			_refresh_roster_options()
			_place_name_edit = LineEdit.new()
			_place_name_edit.placeholder_text = "new camp name"
			_place_name_edit.custom_minimum_size = Vector2(110, 24)
			_place_name_edit.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			_place_name_edit.text_submitted.connect(_on_roster_name_submitted)
			_options_box.add_child(_place_name_edit)
			_build_place_style_chips(false)
			_build_place_feature_chips()
			_add_place_action("+ Add", "Add the named camp to the roster (style + needs from the chips; Enter in the box does the same)", "_add_roster_from_bar")
			_add_place_action("Auto-assign", "Place the whole roster: largest first, best fit, needs honoured", "_auto_assign")
			_add_place_action("Clear all", "Clear every automatic assignment (manual ones stay)", "_clear_assignments")
		"fest_edit":
			_place_name_edit = LineEdit.new()
			_place_name_edit.placeholder_text = "click a road / zone / lot"
			_place_name_edit.custom_minimum_size = Vector2(120, 24)
			_place_name_edit.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			_place_name_edit.text_submitted.connect(_on_place_name_submitted)
			_options_box.add_child(_place_name_edit)
			_build_place_style_chips(false)
			_place_lock_btn = Button.new()
			_place_lock_btn.focus_mode = Control.FOCUS_NONE
			_place_lock_btn.custom_minimum_size = Vector2(60, 24)
			_place_lock_btn.tooltip_text = "Lock this lot: a re-cut never moves it"
			_place_lock_btn.pressed.connect(_toggle_picked_lock)
			_options_box.add_child(_place_lock_btn)
			_add_place_action("Re-cut", "Cut this zone again with its current settings", "_recut_picked_zone")
			_add_place_action("Road: edge", "Add a road just inside the zone edge nearest the pointer", "_road_from_picked_edge")
			_add_place_action("Road: spine", "Add a road down the middle of this zone", "_road_from_picked_spine")
			_add_place_action("Flatten", "Grade this road's corridor (a TERRAIN undo entry)", "_flatten_picked_road")
			_add_place_action("Delete", "Delete this road / zone (Del)", "_delete_picked_place")
			_sync_place_edit_controls()
	_place_readout = Label.new()
	_place_readout.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_place_readout.add_theme_color_override("font_color", UITheme.C_INFO)
	_options_box.add_child(_place_readout)
	_place_readout.text = _place_summary_text()


func _add_place_action(text: String, tip: String, method: String) -> void:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(Callable(self, method))
	_options_box.add_child(b)
	_place_action_buttons.append(b)


## Style chips: multi-select (the zone's allowed mix) or single (a lot's camp).
func _build_place_style_chips(multi: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	_options_box.add_child(row)
	for s in ToolbarStateScript.CAMP_STYLES:
		var sid := String(s["id"])
		if sid == "varied":
			continue
		var b := Button.new()
		b.text = String(s["label"])
		b.tooltip_text = CampStyles.label(sid) + (" (toggle; first on = default)" if multi else "")
		b.custom_minimum_size = Vector2(46, 24)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_place_style_pressed.bind(sid, multi))
		row.add_child(b)
		_place_style_buttons[sid] = b
	_restyle_place_style_buttons()


func _build_place_feature_chips() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	_options_box.add_child(row)
	for f in ToolbarStateScript.PLACEMENT_FEATURES:
		var fid := String(f)
		var b := Button.new()
		b.text = fid
		b.tooltip_text = "Zone offers / camp needs: %s" % fid
		b.custom_minimum_size = Vector2(44, 24)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func() -> void:
			_state.toggle_placement_feature(fid)
			_restyle_place_feature_buttons()
			_queue_save_prefs())
		row.add_child(b)
		_place_feature_buttons[fid] = b
	_restyle_place_feature_buttons()


func _restyle_place_style_buttons() -> void:
	var on: Array = _state.placement_styles
	if _state.active_tool == "fest_edit":
		var info := _picked_place_info()
		var ac: Dictionary = info.get("assigned_camp", {}) if _picked_place["kind"] == "lot" else {}
		on = [str(ac.get("style", ""))] if not ac.is_empty() else []
	elif _state.active_tool == "fest_assign":
		on = [str(_state.placement_styles[0])] if not _state.placement_styles.is_empty() else []
	for sid in _place_style_buttons.keys():
		_style_toggle(_place_style_buttons[sid], on.has(String(sid)))


func _restyle_place_feature_buttons() -> void:
	for fid in _place_feature_buttons.keys():
		_style_toggle(_place_feature_buttons[fid], _state.placement_features.has(String(fid)))


func _refresh_place_toggle_buttons() -> void:
	if _place_equalise_btn != null and is_instance_valid(_place_equalise_btn):
		_place_equalise_btn.text = "Equal: usable" if _state.placement_equalise == "usable" else "Equal: raw"
		UITheme.style_toggle(_place_equalise_btn, _state.placement_equalise == "usable", UITheme.FONT_XS)
	if _place_cutnow_btn != null and is_instance_valid(_place_cutnow_btn):
		_place_cutnow_btn.text = "Cut now"
		UITheme.style_toggle(_place_cutnow_btn, _state.placement_subdivide_now, UITheme.FONT_XS)


func _on_place_style_pressed(style_id: String, multi: bool) -> void:
	if _state.active_tool == "fest_edit":
		if _picked_place["kind"] != "lot" or _loader == null:
			_set_status("Click a lot first")
			return
		_push_place_undo()
		_loader.call("update_lot_camp", str(_picked_place["id"]), {"style": style_id})
		_restyle_place_style_buttons()
		_report_picked_place()
		return
	if multi:
		if not _state.toggle_placement_style(style_id):
			return
	else:
		# Single pick: put it first (= default / the roster entry's style).
		_state.placement_styles.erase(style_id)
		_state.placement_styles.push_front(style_id)
	_restyle_place_style_buttons()
	_queue_save_prefs()


# --- Gestures ---------------------------------------------------------------

func _commit_festival_road(pts: PackedVector2Array) -> void:
	if _loader == null:
		return
	var reason := GestureScript.path_rejection_reason(pts)
	if not reason.is_empty():
		_set_status(reason)
		return
	_push_place_undo()
	var name := _place_name_edit.text.strip_edges() if _place_name_edit != null else ""
	var params := {"width_m": _state.get_param("width_m", 8.0),
		"surface": _state.placement_surface,
		"flatten": _state.get_param("flatten", 0.0) >= 0.5}
	if not name.is_empty():
		params["name"] = name
	var id := str(_loader.call("add_festival_road", pts, params))
	if id.is_empty():
		_set_status("Road refused (two points at least, 200 roads at most)")
		return
	var info: Dictionary = _loader.call("placement_info", "road", id)
	_set_status("%s — %.0f m long, %.0f m wide%s" % [str(info.get("name", "Road")),
		float(info.get("length_m", 0.0)), float(info.get("width_m", 0.0)),
		" · flattened" if bool(info.get("flattened", false)) else ""])
	_refresh_place_readout()
	_update_undo_button()
	_queue_overlay_redraw()


## Region apply for the Zone tool.
func _apply_placement_region(poly: PackedVector2Array) -> void:
	if _loader == null or _state.active_tool != "fest_zone":
		return
	_push_place_undo()
	var id := str(_loader.call("add_placement_zone", poly, {
		"spec": _state.placement_zone_spec(),
		"features": _state.placement_features.duplicate(),
		"subdivide": _state.placement_subdivide_now,
	}))
	if id.is_empty():
		_set_status("Too small for a zone — draw a larger area")
		return
	var info: Dictionary = _loader.call("placement_info", "zone", id)
	var roads: Array = info.get("road_ids", [])
	if roads.is_empty():
		_set_status("%s drawn with NO road in reach — lots use a plain grid; draw a Road, then Re-cut" % str(info.get("name", "Zone")))
	else:
		_set_status(_zone_readout(id))
	_refresh_place_readout()
	_update_undo_button()


func _refresh_place_readout(zone_id: String = "") -> void:
	if _place_readout != null and is_instance_valid(_place_readout):
		_place_readout.text = _place_summary_text(zone_id)


# --- Picking -----------------------------------------------------------------

func _picked_place_info() -> Dictionary:
	if _picked_place["kind"].is_empty() or _loader == null or not _loader.has_method("placement_info"):
		return {}
	return _loader.call("placement_info", str(_picked_place["kind"]), str(_picked_place["id"]))


func _pick_place_at(world: Vector2) -> void:
	if _loader == null or not _loader.has_method("placement_pick_at"):
		return
	var pick: Dictionary = _loader.call("placement_pick_at", world)
	var kind := str(pick.get("kind", ""))
	if kind.is_empty():
		_clear_picked_place()
		_set_status("Nothing here — click a road, zone or lot")
		return
	match _state.active_tool:
		"fest_lots":
			# Lots tool: click a zone (or a lot of it) to cut it.
			var zid := str(pick["id"]) if kind == "zone" else str(
				(_loader.call("placement_info", "lot", str(pick["id"])) as Dictionary).get("zone_id", ""))
			if zid.is_empty():
				_set_status("Click inside a zone to cut it")
				return
			_push_place_undo()
			var res: Dictionary = _loader.call("subdivide_placement_zone", zid)
			_picked_place = {"kind": "zone", "id": zid}
			_highlight_picked_place()
			_set_status(_zone_readout(zid) + ("" if (res.get("warnings", []) as Array).is_empty()
				else " · " + str(res["warnings"][0])))
			_refresh_place_readout()
			_update_undo_button()
		"fest_assign":
			if kind != "lot":
				_set_status("Click a lot to assign it")
				return
			_picked_place = {"kind": "lot", "id": str(pick["id"])}
			_highlight_picked_place()
			if _place_roster_pick.is_empty():
				# No roster pick: clicking an assigned lot clears it.
				var info: Dictionary = _loader.call("placement_info", "lot", str(pick["id"]))
				if not (info.get("assigned_camp", {}) as Dictionary).is_empty():
					_push_place_undo()
					_loader.call("clear_lot_assignment", str(pick["id"]))
					_set_status("%s cleared" % str(info.get("name", "Lot")))
				else:
					_set_status("Pick a camp in the roster box, then click a lot")
			else:
				_push_place_undo()
				_loader.call("assign_lot", str(pick["id"]), _place_roster_pick)
				var info2: Dictionary = _loader.call("placement_info", "lot", str(pick["id"]))
				_set_status("%s → %s (%d people)" % [str(info2.get("name", "Lot")),
					str((info2.get("assigned_camp", {}) as Dictionary).get("name", "")),
					int((info2.get("assigned_camp", {}) as Dictionary).get("headcount", 0))])
			_refresh_place_readout()
			_update_undo_button()
		_:
			_picked_place = {"kind": kind, "id": str(pick["id"])}
			_highlight_picked_place()
			_sync_place_edit_controls()
			_report_picked_place()


func _highlight_picked_place() -> void:
	if _loader == null:
		return
	var info := _picked_place_info()
	var kind := str(_picked_place["kind"])
	if info.is_empty():
		_loader.call("clear_placement_highlight")
		return
	var poly := PackedVector2Array()
	if kind == "road":
		poly = TerrainRoadFlatten.road_corridor_polygon(info["points"], float(info["half_width_m"]))
	else:
		poly = info.get("polygon", PackedVector2Array())
	_loader.call("update_placement_highlight", poly)


func _clear_picked_place() -> void:
	if _place_apply_timer != null:
		_place_apply_timer.stop()
	if _picked_place["kind"].is_empty():
		return
	_picked_place = {"kind": "", "id": ""}
	if _loader != null and _loader.has_method("clear_placement_highlight"):
		_loader.call("clear_placement_highlight")
	_sync_place_edit_controls()


func _report_picked_place() -> void:
	var info := _picked_place_info()
	if info.is_empty():
		return
	match str(_picked_place["kind"]):
		"road":
			_set_status("%s — %.0f m, %.0f m wide, %s%s" % [str(info.get("name", "Road")),
				float(info.get("length_m", 0.0)), float(info.get("width_m", 0.0)),
				str(info.get("surface", "")), " · flattened" if bool(info.get("flattened", false)) else ""])
		"zone":
			_set_status(_zone_readout(str(_picked_place["id"])))
		"lot":
			var ac: Dictionary = info.get("assigned_camp", {})
			var who := "unassigned"
			if not ac.is_empty():
				who = "%s · %s · %s" % [str(ac.get("name", "")),
					CampStyles.label(str(ac.get("style", ""))), UiText.count(int(ac.get("headcount", 0)), "person")]
			_set_status("%s (%s) — usable %.0f of %.0f m² · front %.0f m · slope %.1f° · fairness %.2f · %s · %s%s" % [
				str(info.get("name", "Lot")), str(info.get("size_class", "")),
				float(info.get("usable_m2", 0.0)), float(info.get("raw_m2", 0.0)),
				float(info.get("frontage_m", 0.0)), float(info.get("mean_slope_deg", 0.0)),
				float(info.get("fairness", 0.0)), UiText.count(int(info.get("structures", 0)), "structure"), who,
				" · LOCKED" if bool(info.get("locked", false)) else ""])


## Load the picked thing's settings into the Edit tool's controls.
func _sync_place_edit_controls() -> void:
	if _state.active_tool != "fest_edit":
		return
	var info := _picked_place_info()
	var have := not info.is_empty()
	var kind := str(_picked_place["kind"])
	if _place_name_edit != null and is_instance_valid(_place_name_edit):
		_place_name_edit.editable = have
		var nm := ""
		if have:
			nm = str((info.get("assigned_camp", {}) as Dictionary).get("name", info.get("name", ""))) \
				if kind == "lot" else str(info.get("name", ""))
		_place_name_edit.text = nm
	for b in _place_action_buttons:
		if not is_instance_valid(b):
			continue
		match b.text:
			"Re-cut": b.disabled = not (kind == "zone" or kind == "lot")
			"Road: edge", "Road: spine": b.disabled = kind != "zone"
			"Flatten": b.disabled = kind != "road"
			"Delete": b.disabled = not (kind == "road" or kind == "zone")
			_: b.disabled = not have
	if _place_lock_btn != null and is_instance_valid(_place_lock_btn):
		_place_lock_btn.disabled = kind != "lot"
		var locked := kind == "lot" and bool(info.get("locked", false))
		_place_lock_btn.text = "Locked" if locked else "Lock"
		UITheme.style_toggle(_place_lock_btn, locked, UITheme.FONT_XS)
	if have:
		if kind == "road":
			_state.set_param("width_m", float(info.get("width_m", 8.0)))
			if _param_rows.has("width_m"):
				SliderSpinRow.set_values(_param_rows["width_m"], _state.get_param("width_m"))
		elif kind == "lot":
			var ac: Dictionary = info.get("assigned_camp", {})
			var hc := int(ac.get("headcount", 0)) if not ac.is_empty() else 0
			_state.set_param("headcount", float(hc))
			if _param_rows.has("headcount"):
				SliderSpinRow.set_values(_param_rows["headcount"], _state.get_param("headcount"))
	_restyle_place_style_buttons()


## Debounced push of the Edit rows onto the picked road / lot.
func _apply_place_edit_params() -> void:
	if _state.active_tool != "fest_edit" or _loader == null:
		return
	var info := _picked_place_info()
	if info.is_empty():
		return
	match str(_picked_place["kind"]):
		"road":
			var w := _state.get_param("width_m", 8.0)
			if absf(float(info.get("width_m", 0.0)) - w) > 0.01:
				_push_place_undo()
				_loader.call("update_festival_road", str(_picked_place["id"]), {"width_m": w})
				_highlight_picked_place()
				_report_picked_place()
		"lot":
			var hc := int(round(_state.get_param("headcount", 0.0)))
			var ac: Dictionary = info.get("assigned_camp", {})
			var cur := int(ac.get("headcount", 0)) if not ac.is_empty() else 0
			if hc != cur:
				_push_place_undo()
				_loader.call("update_lot_camp", str(_picked_place["id"]), {"headcount": hc})
				_refresh_place_readout()
				_report_picked_place()


func _on_place_name_submitted(text: String) -> void:
	var info := _picked_place_info()
	if info.is_empty() or _loader == null:
		return
	var nm := text.strip_edges()
	if nm.is_empty():
		return
	_push_place_undo()
	match str(_picked_place["kind"]):
		"road": _loader.call("update_festival_road", str(_picked_place["id"]), {"name": nm})
		"zone": _loader.call("update_placement_zone", str(_picked_place["id"]), {"name": nm})
		"lot": _loader.call("update_lot_camp", str(_picked_place["id"]), {"name": nm})
	_report_picked_place()


func _toggle_picked_lock() -> void:
	if _picked_place["kind"] != "lot" or _loader == null:
		return
	var info := _picked_place_info()
	_push_place_undo()
	_loader.call("set_lot_locked", str(_picked_place["id"]), not bool(info.get("locked", false)))
	_sync_place_edit_controls()
	_report_picked_place()


func _recut_picked_zone() -> void:
	if _loader == null:
		return
	var info := _picked_place_info()
	var zid := str(_picked_place["id"]) if _picked_place["kind"] == "zone" else str(info.get("zone_id", ""))
	if zid.is_empty():
		return
	_push_place_undo()
	_loader.call("subdivide_placement_zone", zid)
	_picked_place = {"kind": "zone", "id": zid}
	_highlight_picked_place()
	_sync_place_edit_controls()
	_set_status(_zone_readout(zid))
	_refresh_place_readout()


func _road_from_picked_edge() -> void:
	if _picked_place["kind"] != "zone" or _loader == null:
		return
	var info := _picked_place_info()
	var poly: PackedVector2Array = info.get("polygon", PackedVector2Array())
	# The edge nearest the pointer, else the longest one.
	var edge_i := 0
	var best := INF
	if _cursor_hit is Vector3:
		var p := Vector2((_cursor_hit as Vector3).x, (_cursor_hit as Vector3).z)
		for i in poly.size():
			var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()]))
			if d < best:
				best = d
				edge_i = i
	else:
		var longest := -1.0
		for i in poly.size():
			var l := poly[i].distance_squared_to(poly[(i + 1) % poly.size()])
			if l > longest:
				longest = l
				edge_i = i
	_push_place_undo()
	var rid := str(_loader.call("road_from_zone_edge", str(_picked_place["id"]), edge_i, 6.0,
		{"width_m": _state.get_param("width_m", 8.0), "surface": _state.placement_surface}))
	if rid.is_empty():
		_set_status("Could not place an edge road")
		return
	_loader.call("subdivide_placement_zone", str(_picked_place["id"]))
	_set_status("Edge road added — " + _zone_readout(str(_picked_place["id"])))
	_refresh_place_readout()
	_queue_overlay_redraw()


func _road_from_picked_spine() -> void:
	if _picked_place["kind"] != "zone" or _loader == null:
		return
	_push_place_undo()
	var rid := str(_loader.call("road_from_zone_spine", str(_picked_place["id"]),
		{"width_m": _state.get_param("width_m", 8.0), "surface": _state.placement_surface}))
	if rid.is_empty():
		_set_status("Could not place a spine road")
		return
	_loader.call("subdivide_placement_zone", str(_picked_place["id"]))
	_set_status("Spine road added — " + _zone_readout(str(_picked_place["id"])))
	_refresh_place_readout()
	_queue_overlay_redraw()


func _flatten_picked_road() -> void:
	if _picked_place["kind"] != "road" or _loader == null:
		return
	if bool(_loader.call("flatten_festival_road", str(_picked_place["id"]))):
		_set_status("Road graded — Undo in the TERRAIN section takes it back")
	else:
		_set_status("Grading needs the hi-res detail patch")


func _delete_picked_place() -> void:
	if _loader == null:
		return
	var kind := str(_picked_place["kind"])
	var info := _picked_place_info()
	if info.is_empty() or not (kind == "road" or kind == "zone"):
		return
	_push_place_undo()
	if kind == "road":
		_loader.call("delete_festival_road", str(_picked_place["id"]))
	else:
		_loader.call("delete_placement_zone", str(_picked_place["id"]))
	_set_status("Deleted %s" % str(info.get("name", kind)))
	_clear_picked_place()
	_refresh_place_readout()
	_queue_overlay_redraw()


func _cut_all_zones() -> void:
	if _loader == null:
		return
	_push_place_undo()
	var r: Dictionary = _loader.call("subdivide_all_placement_zones")
	_set_status("Cut %s into %s" % [UiText.count(int(r.get("zones", 0)), "zone"), UiText.count(int(r.get("lots", 0)), "lot")])
	_refresh_place_readout()
	_queue_overlay_redraw()


# --- Roster ------------------------------------------------------------------

func _roster_entries() -> Array:
	if _loader == null:
		return []
	var layer: Variant = _loader.get("placement")
	if layer == null:
		return []
	return layer.get("roster")


func _refresh_roster_options() -> void:
	if _place_roster_opt == null or not is_instance_valid(_place_roster_opt):
		return
	_place_roster_opt.clear()
	_place_roster_opt.add_item("— pick a camp —")
	_place_roster_opt.set_item_metadata(0, "")
	var placed: Dictionary = {}
	var layer: Variant = _loader.get("placement") if _loader != null else null
	if layer != null:
		for l in layer.get("lots"):
			placed[str(((l as Dictionary).get("assigned_camp", {}) as Dictionary).get("roster_id", ""))] = true
	var sel := 0
	for e in _roster_entries():
		var d: Dictionary = e
		var idx := _place_roster_opt.item_count
		_place_roster_opt.add_item("%s%s (%s, %d)" % ["✓ " if placed.has(str(d["id"])) else "",
			str(d.get("name", "")), str(d.get("size_class", "")), int(d.get("headcount", 0))])
		_place_roster_opt.set_item_metadata(idx, str(d["id"]))
		if str(d["id"]) == _place_roster_pick:
			sel = idx
	_place_roster_opt.select(sel)
	if sel == 0:
		_place_roster_pick = ""


func _on_roster_selected(i: int) -> void:
	_place_roster_pick = str(_place_roster_opt.get_item_metadata(i))
	if _place_roster_pick.is_empty():
		_set_status("Click an assigned lot to clear it")
	else:
		_set_status("Click a lot to give it to this camp")


func _on_roster_name_submitted(_text: String) -> void:
	_add_roster_from_bar()


func _add_roster_from_bar() -> void:
	if _loader == null or _place_name_edit == null:
		return
	var layer: Variant = _loader.get("placement")
	if layer == null:
		return
	var nm := _place_name_edit.text.strip_edges()
	if nm.is_empty():
		_set_status("Type a camp name first")
		return
	var style := str(_state.placement_styles[0]) if not _state.placement_styles.is_empty() else "mixed"
	var hc := int(round(_state.get_tool_param_value("fest_edit", "headcount")))
	var id := str(layer.call("add_roster_entry", {"name": nm, "style": style,
		"headcount": hc, "requirements": _state.placement_features.duplicate(),
		"size_class": "M"}))
	if id.is_empty():
		_set_status("Roster is full")
		return
	_loader.call("_save_placement")
	_place_name_edit.text = ""
	_place_roster_pick = id
	_refresh_roster_options()
	_set_status("%s added to the roster — click a lot, or Auto-assign" % nm)


func _auto_assign() -> void:
	if _loader == null:
		return
	_push_place_undo()
	var res: Dictionary = _loader.call("assign_placement", "")
	var unplaced: Array = res.get("unplaced", [])
	_set_status("Auto-assigned — %s unplaced%s" % [UiText.count(unplaced.size(), "camp"),
		"" if unplaced.is_empty() else ": " + str(res.get("warnings", [""])[0])])
	_refresh_roster_options()
	_refresh_place_readout()
	_queue_overlay_redraw()


func _clear_assignments() -> void:
	if _loader == null:
		return
	var layer: Variant = _loader.get("placement")
	if layer == null:
		return
	_push_place_undo()
	var n := 0
	for l in (layer.get("lots") as Array).duplicate():
		var ac: Dictionary = (l as Dictionary).get("assigned_camp", {})
		if not ac.is_empty() and not bool(ac.get("manual", false)):
			_loader.call("clear_lot_assignment", str((l as Dictionary)["lot_id"]))
			n += 1
	_set_status("Cleared %s" % UiText.count(n, "automatic assignment"))
	_refresh_roster_options()
	_refresh_place_readout()
	_queue_overlay_redraw()


# --- Overlay -----------------------------------------------------------------

## Roads, zones and lots, drawn whenever a placement tool is up: lots coloured
## by fairness (usable ÷ zone mean), assigned lots filled, locked lots marked,
## and the picked lot's unusable cells hatched.
func _draw_placement_overlay() -> void:
	if _loader == null:
		return
	var layer: Variant = _loader.get("placement")
	if layer == null:
		return
	var font := ThemeDB.fallback_font
	for r in layer.get("roads"):
		var rd: Dictionary = r
		var pts := _project_poly(rd["points"])
		if pts.size() >= 2:
			var w := maxf(2.0, float(rd["half_width_m"]) * 2.0 * _px_per_m(rd["points"][0]))
			_overlay.draw_polyline(pts, Color(ROAD_COLOR, 0.35), w, false)
			_overlay.draw_polyline(pts, ROAD_COLOR, 1.5, true)
	for z in layer.get("zones"):
		var zd: Dictionary = z
		var pts := _project_poly(zd["polygon"])
		if pts.size() >= 3:
			pts.append(pts[0])
			_overlay.draw_polyline(pts, ZONE_COLOR, 1.5, true)
	for l in layer.get("lots"):
		var ld: Dictionary = l
		var pts := _project_poly(ld["polygon"])
		if pts.size() < 3:
			continue
		var fair := float(ld.get("fairness", 1.0))
		var col := LOT_FAIR_GREEN
		if absf(fair - 1.0) > 0.15:
			col = LOT_FAIR_RED
		elif absf(fair - 1.0) > 0.05:
			col = LOT_FAIR_AMBER
		var ac: Dictionary = ld.get("assigned_camp", {})
		if not ac.is_empty() and not str(ac.get("roster_id", "")).is_empty():
			_overlay.draw_colored_polygon(pts, Color(col, 0.15))
		var ring := pts.duplicate()
		ring.append(ring[0])
		_overlay.draw_polyline(ring, col, 2.5 if bool(ld.get("locked", false)) else 1.2, true)
		var label_at := _project_poly(PackedVector2Array([CampAreaLayer._inner_point(ld["polygon"])]))
		if label_at.size() == 1:
			var txt := str(ld.get("name", ""))
			if not ac.is_empty():
				txt += " " + str(ac.get("name", ""))
			if bool(ld.get("locked", false)):
				txt = "🔒 " + txt
			_overlay.draw_string(font, label_at[0] + Vector2(-10, 4), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, col)


## Screen pixels per world metre near a world point (for road widths).
func _px_per_m(world: Vector2) -> float:
	var a := _project_poly(PackedVector2Array([world, world + Vector2(1.0, 0.0)]))
	if a.size() != 2:
		return 0.0
	return a[0].distance_to(a[1])
