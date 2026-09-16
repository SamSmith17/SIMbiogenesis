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

const HIGHLIGHT_COLOR := Color(0.35, 0.85, 1.0, 0.45)
const SHAPE_LABELS := {
	"brush": "Brush", "circle": "Circle", "rect": "Rect",
	"lasso": "Lasso", "polygon": "Poly",
}
const SHAPE_TIPS := {
	"brush": "Freehand sweep — hold LMB and drag",
	"circle": "Drag from the centre outward",
	"rect": "Drag corner to corner",
	"lasso": "Hold LMB and trace an outline",
	"polygon": "Click each corner; Enter or click the first corner to close",
}

var _state: ToolbarStateScript = ToolbarStateScript.new()
var _gesture: GestureScript = GestureScript.new()
var _loader: Node = null
var _active := false

# UI nodes
var _overlay: Control = null
var _strip: PanelContainer = null
var _strip_box: VBoxContainer = null
var _options: PanelContainer = null
var _options_box: HBoxContainer = null
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
## The section the last reground ran for — sculpting terrain leaves painted
## plants floating, so switching terrain -> veg re-snaps them once.
var _last_section := ""

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
		var tools := _state.tools_in_section(section)
		if not tools.is_empty():
			_set_active_tool(String(tools[0]["id"]))


## What T and V do: open into that section, SWITCH to it when the toolbar is
## already up on the other section, and close only when it is already showing
## the section asked for. Pressing V while sculpting should move you to the
## plants, not shut the toolbar.
func toggle_section(section: String) -> void:
	if _active and String(_state.tool_def(_state.active_tool).get("section", "")) == section:
		_exit_mode()
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
	if _loader != null and _loader.has_method("begin_sculpt_session"):
		_loader.call("begin_sculpt_session")
	CursorController.request_tool_overlay(OVERLAY_NAME, Callable(self, "_escape_step"))


func _exit_mode() -> void:
	if not _active:
		return
	_cancel_stroke()
	_end_water_modulate()
	_clear_locked_selection()
	_gesture.reset()
	_gesture_has_a = false
	_active = false
	visible = false
	set_process(false)
	_free_brush_ring()
	if _loader != null and _loader.has_method("end_sculpt_session"):
		_loader.call("end_sculpt_session")
	# Flush now rather than waiting out the debounce, which closing would eat.
	_save_prefs_now()
	CursorController.release_tool_overlay(OVERLAY_NAME)


## Esc (via CursorController's overlay fallback): peel one layer per press.
func _escape_step() -> void:
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
	_exit_mode()


func _cancel_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
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
	_strip.offset_right = 92.0
	_strip.offset_top = 52.0
	add_child(_strip)
	_strip_box = VBoxContainer.new()
	_strip_box.add_theme_constant_override("separation", 3)
	_strip.add_child(_strip_box)
	# Collapse control. The strip carries 13 tools, which is a tall column on a
	# short window. Session-only on purpose: a collapsed state remembered across
	# launches reads as "my tools disappeared".
	_collapse_btn = Button.new()
	_collapse_btn.custom_minimum_size = Vector2(72, 22)
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.pressed.connect(_toggle_collapsed)
	_strip_box.add_child(_collapse_btn)
	_build_strip_section("TERRAIN", "terrain")
	_build_strip_section("VEGETATION", "veg")

	# Top options bar.
	_options = PanelContainer.new()
	_options.name = "OptionsBar"
	_options.add_theme_stylebox_override("panel", UITheme.panel_style(0.92))
	_options.mouse_filter = Control.MOUSE_FILTER_STOP
	_options.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_options.offset_left = 104.0
	_options.offset_right = -12.0
	_options.offset_top = 8.0
	add_child(_options)
	_options_box = HBoxContainer.new()
	_options_box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_options.add_child(_options_box)


func _build_strip_section(title: String, section: String) -> void:
	var hdr := Label.new()
	hdr.text = title
	hdr.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hdr.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_strip_box.add_child(hdr)
	_strip_body.append(hdr)
	for t in _state.tools_in_section(section):
		var id := String(t["id"])
		var btn := Button.new()
		btn.text = String(t["label"])
		btn.tooltip_text = String(t["tooltip"])
		btn.custom_minimum_size = Vector2(72, 28)
		btn.focus_mode = Control.FOCUS_NONE
		if ToolbarStateScript.PENDING_TOOLS.has(id):
			btn.disabled = true
			btn.tooltip_text += "\n(not in the toolbar yet — Shift+T opens the classic dock)"
		else:
			btn.pressed.connect(_set_active_tool.bind(id))
		_strip_box.add_child(btn)
		_strip_body.append(btn)
		_tool_buttons[id] = btn
	_restyle_tool_buttons()
	_refresh_collapse_button()


## Tool / shape / family toggle faces now live in UITheme, shared with every
## other strip rather than hand-rolled per dock.
func _style_toggle(btn: Button, on: bool) -> void:
	UITheme.style_toggle(btn, on)


func _restyle_tool_buttons() -> void:
	for id in _tool_buttons.keys():
		_style_toggle(_tool_buttons[id], String(id) == _state.active_tool)


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	for c in _strip_body:
		c.visible = not _collapsed
	_refresh_collapse_button()
	# Without this the panel keeps the hidden children's footprint.
	_strip.reset_size()


func _refresh_collapse_button() -> void:
	if _collapse_btn == null:
		return
	_collapse_btn.text = "Tools >" if _collapsed else "Tools v"
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
	_gesture.set_mode(_state.shape_for(id))
	# Sculpting leaves painted plants hanging in the air, and this toolbar makes
	# terrain->veg a one-click move, so re-snap them on the way in (the legacy
	# veg dock does the same on every open).
	var section := String(_state.tool_def(id).get("section", ""))
	if section == "veg" and _last_section != "veg" and _loader != null 			and _loader.has_method("reground_all_vegetation"):
		_loader.call("reground_all_vegetation")
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
		var pair := SliderSpinRow.add(_options_box, String(spec["label"]),
			float(spec["min"]), float(spec["max"]), float(spec["value"]),
			_make_param_handler(key), Callable(self, "_style_row_label"),
			0, 110, 62, float(spec["step"]))
		_param_rows[key] = pair
	if String(def.get("section", "")) == "veg":
		_build_species_row()
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
	hint_lbl.text = "RMB look - WASD move - [ ] size - Esc close"
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
	exit_btn.text = "✕"
	exit_btn.tooltip_text = "Close the toolbar (Esc)"
	exit_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(exit_btn)
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


# ---------------------------------------------------------------------------
# Input — no fullscreen capture rect. The two panels STOP mouse events over
# themselves; anything reaching _unhandled_input is a world interaction. RMB is
# never consumed here — the player owns it for overlay look.
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
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
		else:
			_begin_brush(world)
		return
	var close_tol := maxf(_state.get_param("radius_m", 12.0) * 0.25, 3.0)
	var outcome := _gesture.begin(world, get_viewport().get_mouse_position(), close_tol)
	match outcome:
		GestureScript.POLY_CLOSED:
			_lock_selection(_gesture.finish_polygon())
		GestureScript.POLY_POINT:
			_set_status("Polygon: %d points — Enter to close" % _gesture.poly_points().size())
	_queue_overlay_redraw()


func _on_lmb_released() -> void:
	if _water_modulating:
		_end_water_modulate()
		return
	if _stroking:
		if _is_veg_tool():
			_end_veg_stroke()
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
	if _state.active_tool == "rain" and not bool(_basin_cache.get("valid", false)):
		var msg := "No closed basin"
		if _loader.has_method("basin_failure_message"):
			msg = str(_loader.call("basin_failure_message", _basin_cache))
		_set_status(msg)
		_water_modulating = false


func _end_water_modulate() -> void:
	if not _water_modulating:
		return
	_water_modulating = false
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


## First click anchors; second completes the ramp grade / measure readout.
func _gesture_click(world: Vector2) -> void:
	if not _gesture_has_a:
		_gesture_a = world
		_gesture_has_a = true
		if _state.active_tool == "ramp":
			_set_status("Ramp: click the far end (width %.0f m)" % _state.get_param("width_m", 12.0))
		else:
			_set_status("Measure: click the second point")
		_queue_overlay_redraw()
		return
	var a := _gesture_a
	_gesture_has_a = false
	if _state.active_tool == "ramp":
		if _loader != null:
			_loader.call("ramp_command", Vector3(a.x, 0.0, a.y),
				Vector3(world.x, 0.0, world.y), _state.get_param("width_m", 12.0))
			_set_status("Ramp graded — %s" % _volume_summary())
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
	var mouse := get_viewport().get_mouse_position() if get_viewport() != null else Vector2.ZERO
	var busy := _stroking or _water_modulating or _gesture.is_dragging()
	if not busy and mouse.is_equal_approx(_last_pointer_px):
		return
	_last_pointer_px = mouse
	_cursor_hit = _pick_pointer()
	if _water_modulating:
		_tick_water_modulate(delta)
	elif _stroking and _cursor_hit is Vector3:
		var p: Vector3 = _cursor_hit
		if _is_veg_tool():
			_stamp_veg_at(Vector2(p.x, p.z))
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
		return
	var mode := _gesture.mode
	if mode == "lasso" and _gesture.lasso_screen().size() >= 2:
		_overlay.draw_polyline(_gesture.lasso_screen(), col, 2.0, true)
		return
	if mode == "polygon" and _gesture.poly_points().size() >= 1:
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
	if _is_veg_tool():
		if _loader.has_method("undo_vegetation") and bool(_loader.call("undo_vegetation")):
			_picked_plant = {}
			_set_status("Undid last vegetation edit")
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
	if _is_veg_tool():
		can = _loader.has_method("can_undo_vegetation") 			and bool(_loader.call("can_undo_vegetation"))
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
	_restyle_family_buttons()
	_refresh_subspecies()


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
		_subspecies_opt.add_item("— mix —")
		_subspecies_opt.disabled = true
		_state.set_veg_species("")
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
	var params := {
		"preset": _state.veg_preset_index(),
		"spacing_m": _effective_spacing(),
		"scale_min": scales.x,
		"scale_max": scales.y,
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
	return params


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
	var rng := RandomNumberGenerator.new()
	rng.seed = VEG_SEED ^ int(Time.get_ticks_usec())
	return VegetationPaint.pick_species(_state.veg_preset_index(),
		float(MIX_WEIGHTS["pine"]), float(MIX_WEIGHTS["deciduous"]),
		float(MIX_WEIGHTS["shrub"]), rng,
		float(MIX_WEIGHTS["grass_lawn"]), float(MIX_WEIGHTS["grass_field"]))


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

static func _picked_label(desc: Dictionary) -> String:
	var species := str(desc.get("species", ""))
	var nm := VegSpeciesCatalog.label_for(species) if not species.is_empty() else "plant"
	if str(desc.get("kind", "")) == "hero":
		nm = "%s (hero)" % nm
	return "%s x%.2f, %.1f m away" % [nm, float(desc.get("scale", 1.0)),
		float(desc.get("dist_m", 0.0))]


func _pick_plant_at(world_xz: Vector2) -> void:
	if _loader == null or not _loader.has_method("pick_plant_at"):
		return
	var desc: Dictionary = _loader.call("pick_plant_at", world_xz, PICK_RADIUS_M)
	if desc.is_empty():
		_picked_plant = {}
		_set_status("No painted plant within %.0f m (auto-scattered OSM trees are not individually editable)"
			% PICK_RADIUS_M)
		return
	_picked_plant = desc
	_set_status("%s · Del deletes · [ / ] resize · H → hero" % _picked_label(desc))


func _delete_picked_plant() -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("delete_plant_at"):
		return
	_push_veg_undo("delete plant")
	var at := Vector2(float(_picked_plant.get("x", 0.0)), float(_picked_plant.get("z", 0.0)))
	var gone: Dictionary = _loader.call("delete_plant_at", at, PICK_RADIUS_M)
	if gone.is_empty():
		_set_status("Nothing deleted — pick a plant first")
		return
	_picked_plant = {}
	_set_status("Deleted %s — Undo restores it" % _picked_label(gone))


## Promote the picked card plant to a hero GLB at the same spot and apparent
## size. The SPECIES chooses the model, so a pine becomes a pine.
func _convert_picked_to_hero() -> void:
	if _picked_plant.is_empty() or _loader == null \
			or not _loader.has_method("convert_plant_to_hero_at"):
		return
	if str(_picked_plant.get("kind", "")) == "hero":
		_set_status("Already a hero tree")
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
	var changed: Dictionary = _loader.call("scale_plant_at", at, factor, PICK_RADIUS_M)
	if changed.is_empty():
		return
	# Re-read the record so the readout shows the NEW scale, not the old one.
	_picked_plant = _loader.call("pick_plant_at", at, PICK_RADIUS_M)
	_set_status("Resized %s" % _picked_label(_picked_plant))
