extends Control

## The J Light Studio: a right-edge dock for placing and tuning lights while
## the world stays fully visible and navigable.
##
## Runs in CursorController's TOOL-OVERLAY tier (the unified edit toolbar's
## tier): the cursor is free, RMB-hold looks, WASD still moves, and one Esc
## peels one layer (string in progress → drag → selection → close). It is NOT
## a modal — the old centred, dimmed PlacedLightModal hid exactly the thing
## being lit.
##
## The dock owns the gestures; PlacedLightService owns the data. Every gesture
## is checkpoint() → edits → commit(): one undo step and one file write.
##
## Tools:
##   Select  click a light / string pin to select (Shift adds), drag the
##           gumball, drag a pin or light along surfaces, drag a string's wire
##           to insert a pin, drag empty space to box-select.
##   Omni / Spot  click a surface to place (a spot faces out of the surface).
##   String  click to pin waypoints; double-click the last pin (or Enter) to
##           finish; Backspace drops the last pin.
##   Aim     click a surface: every selected spot turns to face it.

const OVERLAY_NAME := "light_studio"
const DOCK_W := 368.0
const DRAG_PX := 6.0
const DOUBLE_CLICK_MS := 550
const NIGHT_HOUR := 22.0
const SNAP_M := 0.25
const SNAP_DEG := 15.0
## A spot clicked onto open ground hangs this high, aimed down at the click.
const SPOT_HANG_M := 3.0

const TOOLS := [
	{"id": "select", "label": "Select", "tip": "Select, move (gumball / drag), box-select. Drag a pin: move it · Ctrl+drag: move the whole string · Shift+drag: duplicate"},
	{"id": "omni", "label": "Omni", "tip": "Click a surface to place a point light"},
	{"id": "spot", "label": "Spot", "tip": "Click a surface to place a spot (on the ground it hangs up and aims down)"},
	{"id": "mover", "label": "Mover", "tip": "Click a surface to place a moving fixture — beam, gobo spot, wash, laser, projector — that sweeps on a program"},
	{"id": "string", "label": "String", "tip": "Click to pin a string or tube light; double-click the last pin to finish"},
	{"id": "aim", "label": "Aim", "tip": "Click a surface: selected spots face it; selected movers centre their sweep on it"},
]

const ALL := ["omni", "spot", "string", "mover"]
const POINTS := ["omni", "spot", "mover"]

## Inspector rows. kinds: which light kinds show the row (a row shows only when
## EVERY selected kind has it).
const FIELDS := [
	{"key": "preset", "label": "Preset", "type": "preset", "kinds": ALL, "section": "Look"},
	{"key": "color", "label": "Colour", "type": "color", "kinds": ALL, "section": "Light"},
	{"key": "_kelvin", "label": "Temp K", "type": "kelvin", "min": 1800.0, "max": 10000.0, "step": 50.0, "kinds": ALL, "section": "Light"},
	{"key": "energy", "label": "Intensity", "type": "float", "min": 0.0, "max": 60.0, "step": 0.05, "kinds": ALL, "section": "Light"},
	{"key": "range", "label": "Range m", "type": "float", "min": 0.5, "max": 600.0, "step": 0.5, "kinds": POINTS, "section": "Light"},
	{"key": "attenuation", "label": "Falloff", "type": "float", "min": 0.1, "max": 4.0, "step": 0.05, "kinds": POINTS, "section": "Light"},
	{"key": "spot_angle", "label": "Half-angle °", "type": "float", "min": 0.3, "max": 89.0, "step": 0.1, "kinds": ["spot", "mover"], "section": "Light"},
	{"key": "spot_softness", "label": "Edge soft", "type": "float", "min": 0.05, "max": 6.0, "step": 0.05, "kinds": ["spot", "mover"], "section": "Light"},
	{"key": "show_body", "label": "Show bulb / fixture", "type": "bool", "kinds": ALL, "section": "Light"},
	{"key": "shadow_enabled", "label": "Shadows", "type": "bool", "kinds": POINTS, "section": "Light"},
	{"key": "fade_m", "label": "Fade at m", "type": "float", "min": 0.0, "max": 2000.0, "step": 5.0, "kinds": ALL, "section": "Light"},
	{"key": "schedule", "label": "On", "type": "enum", "options": ["always", "dusk_dawn"], "option_labels": ["Always", "Dusk to dawn"], "kinds": ALL, "section": "Light"},
	{"key": "watts", "label": "Rated W", "type": "float", "min": 0.0, "max": 5000.0, "step": 1.0, "kinds": POINTS, "section": "Light"},
	{"key": "fixture", "label": "Fixture", "type": "enum", "options": PlacedLightStyles.FIXTURES, "option_labels": PlacedLightStyles.FIXTURE_LABELS, "kinds": ["mover"], "section": "Fixture"},
	{"key": "program", "label": "Program", "type": "enum", "options": PlacedLightStyles.PROGRAMS, "option_labels": PlacedLightStyles.PROGRAM_LABELS, "kinds": ["mover"], "section": "Fixture"},
	{"key": "prog_speed", "label": "Cycles/min", "type": "float", "min": 0.0, "max": 120.0, "step": 0.5, "kinds": ["mover"], "section": "Fixture"},
	{"key": "pan_center", "label": "Pan °", "type": "float", "min": -180.0, "max": 180.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "tilt_center", "label": "Tilt °", "type": "float", "min": 0.0, "max": 180.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "pan_range", "label": "Pan sweep ±°", "type": "float", "min": 0.0, "max": 180.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "tilt_range", "label": "Tilt sweep ±°", "type": "float", "min": 0.0, "max": 90.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "phase_deg", "label": "Phase °", "type": "float", "min": 0.0, "max": 360.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "beam_haze", "label": "Beam in haze", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01, "kinds": ["mover"], "section": "Fixture"},
	{"key": "gobo", "label": "Gobo", "type": "enum", "options": PlacedLightStyles.GOBOS, "option_labels": PlacedLightStyles.GOBOS, "kinds": ["mover"], "section": "Fixture"},
	{"key": "gobo_spin", "label": "Gobo rpm", "type": "float", "min": -60.0, "max": 60.0, "step": 0.5, "kinds": ["mover"], "section": "Fixture"},
	{"key": "laser_beams", "label": "Laser beams", "type": "float", "min": 1.0, "max": 16.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "laser_fan_deg", "label": "Laser fan °", "type": "float", "min": 0.0, "max": 90.0, "step": 1.0, "kinds": ["mover"], "section": "Fixture"},
	{"key": "continuous", "label": "Continuous tube (rope / neon / EL)", "type": "bool", "kinds": ["string"], "section": "String"},
	{"key": "tube_diameter_mm", "label": "Tube Ø mm", "type": "float", "min": 1.0, "max": 60.0, "step": 0.5, "kinds": ["string"], "section": "String"},
	{"key": "leds_per_m", "label": "LEDs / m", "type": "float", "min": 1.0, "max": 240.0, "step": 1.0, "kinds": ["string"], "section": "String"},
	{"key": "bulb_spacing_m", "label": "Bulb spacing m", "type": "float", "min": 0.01, "max": 3.0, "step": 0.01, "kinds": ["string"], "section": "String"},
	{"key": "bulb_size", "label": "Bulb size", "type": "float", "min": 0.005, "max": 0.2, "step": 0.001, "kinds": ["string"], "section": "String"},
	{"key": "sag", "label": "Sag", "type": "float", "min": 0.0, "max": 1.5, "step": 0.01, "kinds": ["string"], "section": "String"},
	{"key": "wire_color", "label": "Wire", "type": "color", "kinds": ["string"], "section": "String"},
	{"key": "real_lights", "label": "Real lights", "type": "float", "min": 0.0, "max": 16.0, "step": 1.0, "kinds": ["string"], "section": "String"},
	{"key": "light_range", "label": "Cast m", "type": "float", "min": 0.3, "max": 30.0, "step": 0.1, "kinds": ["string"], "section": "String"},
	{"key": "watts_per_m", "label": "W per m", "type": "float", "min": 0.0, "max": 60.0, "step": 0.1, "kinds": ["string"], "section": "String"},
	{"key": "effect", "label": "Effect", "type": "effect", "kinds": ALL, "section": "Effect"},
	{"key": "fx_speed", "label": "Speed", "type": "float", "min": 0.0, "max": 60.0, "step": 0.1, "kinds": ALL, "section": "Effect"},
	{"key": "fx_span", "label": "Rainbow len", "type": "float", "min": 2.0, "max": 300.0, "step": 1.0, "kinds": ["string", "mover"], "section": "Effect"},
	{"key": "fx_gap", "label": "Chase gap", "type": "float", "min": 2.0, "max": 12.0, "step": 1.0, "kinds": ["string"], "section": "Effect"},
	{"key": "fx_saturation", "label": "Saturation", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01, "kinds": ALL, "section": "Effect"},
	{"key": "fx_direction", "label": "Reverse", "type": "direction", "kinds": ["string"], "section": "Effect"},
	{"key": "fx_pause_with_sim", "label": "Pause w/ sim", "type": "bool", "kinds": ALL, "section": "Effect"},
]

var _main: Node = null
var _active := false
var _tool := "select"
var _into_style := true

# UI
var _panel: PanelContainer = null
var _body: VBoxContainer = null
var _collapsed := false
var _tool_btns: Dictionary = {}
var _undo_btn: Button = null
var _redo_btn: Button = null
var _night_btn: Button = null
var _space_btn: Button = null
var _hint: Label = null
var _preset_row: HBoxContainer = null
var _preset_label: Label = null
var _preset_pick: OptionButton = null
var _preset_ids: Array = []
var _styles_box: VBoxContainer = null
var _groups_box: VBoxContainer = null
var _insp_box: VBoxContainer = null
var _rows: Dictionary = {}       # key -> {widget…, revert: Button, dot: Label}
var _overlay: Control = null
var _insp_sig := ""
var _syncing := false

# World gestures
var _gizmo: LightGizmo = null
var _press_pos := Vector2.ZERO
var _press_ms := 0
var _pending := {}               # what a press armed: {type, id, index, …}
var _dragging := ""              # "" | gizmo | surface | pin | wire | box
var _drag := {}                  # per-drag state
var _hover_pin: PlacedLightWaypoint = null
var _string_pts: Array = []      # in-progress string pins
var _string_preview: MeshInstance3D = null
var _string_preview_mesh: ImmediateMesh = null
var _last_pin_click_ms := -100000
var _edit_ms := -100000          # last inspector edit (checkpoint coalescing)
var _save_timer: Timer = null
var _night_saved: Variant = null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.5
	_save_timer.timeout.connect(func() -> void: PlacedLightService.commit(_main))
	add_child(_save_timer)
	_build_ui()


func bind_main(main: Node) -> void:
	_main = main


func is_panel_open() -> bool:
	return _active


func toggle_mode() -> void:
	if _active:
		close()
	else:
		open()


func open() -> void:
	if _active or _main == null:
		return
	_active = true
	visible = true
	move_to_front()
	set_process(true)
	PlacedLightService.ensure_built(_main)
	PlacedLightService.set_studio_open(true)
	PlacedLightService.add_listener(_on_model_changed)
	CursorController.request_tool_overlay(OVERLAY_NAME, Callable(self, "_escape_step"))
	_ensure_world_nodes()
	_set_tool(_tool)
	_on_model_changed()


func close() -> void:
	if not _active:
		return
	_cancel_string()
	_end_drag(false)
	if _save_timer.time_left > 0.0:
		_save_timer.stop()
		PlacedLightService.commit(_main)
	_set_night(false)
	_active = false
	visible = false
	set_process(false)
	PlacedLightService.set_studio_open(false)
	PlacedLightService.remove_listener(_on_model_changed)
	PlacedLightService.set_selection(_main, [])
	CursorController.release_tool_overlay(OVERLAY_NAME)
	if _gizmo != null:
		_gizmo.hide_gizmo()


## Compatibility with every dock's force-close contract.
func _exit_mode() -> void:
	close()


func _exit_tree() -> void:
	if _active:
		close()
	for n in [_gizmo, _string_preview]:
		if n != null and is_instance_valid(n):
			n.queue_free()


func _escape_step() -> void:
	if not _string_pts.is_empty():
		_cancel_string()
		_hint_text("String cancelled")
		return
	if not _dragging.is_empty():
		_end_drag(false)
		return
	if not PlacedLightService.selection.is_empty():
		PlacedLightService.set_selection(_main, [])
		return
	close()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_panel = PanelContainer.new()
	_panel.name = "Dock"
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.93))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -DOCK_W - 10.0
	_panel.offset_right = -10.0
	_panel.offset_top = 10.0
	_panel.offset_bottom = -180.0   # clear the timeline bar
	add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, UITheme.SPACE_SM)
	_panel.add_child(margin)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", UITheme.SPACE_SM)
	margin.add_child(outer)

	# Header.
	var head := HBoxContainer.new()
	outer.add_child(head)
	var title := Label.new()
	title.text = "Light Studio"
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	title.add_theme_color_override("font_color", UITheme.C_GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_night_btn = _small_btn(head, "☾ Night", "Preview at 22:00 (restores the time when toggled off or on close)",
		func() -> void: _set_night(_night_saved == null))
	_small_btn(head, "▾", "Collapse / expand the dock", _toggle_collapse)
	_small_btn(head, "✕", "Close (J)", close)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(_body)

	# Tools.
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 3)
	_body.add_child(tools)
	for t in TOOLS:
		var b := Button.new()
		b.text = t["label"]
		b.tooltip_text = t["tip"]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tid: String = t["id"]
		b.pressed.connect(func() -> void: _set_tool(tid))
		tools.add_child(b)
		_tool_btns[tid] = b
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 3)
	_body.add_child(row2)
	_undo_btn = _small_btn(row2, "↶ Undo", "Ctrl+Z", func() -> void: _do_undo(false))
	_redo_btn = _small_btn(row2, "↷ Redo", "Ctrl+Y", func() -> void: _do_undo(true))
	_space_btn = _small_btn(row2, "Gizmo: World", "Toggle gumball world / local axes (L)", _toggle_space)
	# What the placement tools put down: a preset becomes a STYLE (one per
	# preset per map), so everything placed from it restyles together.
	_preset_row = HBoxContainer.new()
	_preset_row.add_theme_constant_override("separation", 4)
	_body.add_child(_preset_row)
	_preset_label = _label(_preset_row, "New:", UITheme.C_TEXT_S, UITheme.FONT_SM)
	_preset_pick = OptionButton.new()
	_preset_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_pick.focus_mode = Control.FOCUS_NONE
	_preset_pick.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_preset_pick.tooltip_text = "What this tool places. A preset is saved as a style on this map — edit it once and every light placed from it follows."
	_preset_pick.item_selected.connect(_on_new_preset)
	_preset_row.add_child(_preset_pick)
	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_body.add_child(_hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(col)
	_insp_box = _section(col, "Selection")
	_styles_box = _section(col, "Styles")
	_groups_box = _section(col, "Groups")


func _section(parent: Control, title: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	parent.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)
	var hdr := Button.new()
	hdr.text = "▾ " + title
	hdr.flat = true
	hdr.alignment = HORIZONTAL_ALIGNMENT_LEFT
	hdr.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	hdr.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	hdr.focus_mode = Control.FOCUS_NONE
	v.add_child(hdr)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	v.add_child(content)
	hdr.pressed.connect(func() -> void:
		content.visible = not content.visible
		hdr.text = ("▾ " if content.visible else "▸ ") + title)
	return content


func _small_btn(parent: Control, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	UITheme.style_button(b)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _label(parent: Control, text: String, color: Color = UITheme.C_TEXT_S, fsize: int = UITheme.FONT_SM) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _toggle_collapse() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_panel.offset_bottom = -180.0 if not _collapsed else 0.0
	if _collapsed:
		_panel.anchor_bottom = 0.0
		_panel.offset_bottom = 54.0
	else:
		_panel.anchor_bottom = 1.0


func _set_tool(tid: String) -> void:
	if tid != _tool:
		_cancel_string()
	_tool = tid
	for k in _tool_btns.keys():
		var b: Button = _tool_btns[k]
		b.set_pressed_no_signal(k == tid)
		UITheme.style_toggle(b, k == tid)
	_refresh_preset_picker()
	match tid:
		"select":
			_hint_text("Click to select (Shift adds) · drag a pin to move it · Ctrl+drag moves the whole string or light · Shift+drag duplicates it · drag a wire to add a pin · the gumball fine-tunes · Del deletes")
		"omni", "spot":
			_hint_text("Click a surface to place a %s%s · drag an existing light to move it, Shift+drag to duplicate" % [tid,
				" · on the ground it hangs %.0f m up aiming down; on a wall it aims out" % SPOT_HANG_M if tid == "spot" else ""])
		"mover":
			_hint_text("Click a surface to place a moving fixture (it stands on the surface; hang it from a truss by clicking underneath) · pick its preset above · Aim centres its sweep")
		"string":
			_hint_text("Click to pin the string · double-click the last pin (or Enter) to finish · Backspace removes the last pin · Esc cancels · drag a pin to move it, Ctrl+drag the whole string, Shift+drag to duplicate")
		"aim":
			_hint_text("Click a surface: selected spots turn to face it; selected movers centre their sweep on it")


## The kind the active tool places ("" for Select / Aim).
func _tool_kind() -> String:
	return _tool if _tool in ["omni", "spot", "mover", "string"] else ""


func _refresh_preset_picker() -> void:
	if _preset_pick == null:
		return
	var kind := _tool_kind()
	_preset_row.visible = not kind.is_empty()
	if kind.is_empty():
		return
	_preset_label.text = "New %s:" % kind
	_preset_pick.clear()
	_preset_ids = [""]
	_preset_pick.add_item("Default %s style" % kind)
	for pid in PlacedLightStyles.PRESET_ORDER.get(kind, []):
		_preset_ids.append(str(pid))
		_preset_pick.add_item(PlacedLightStyles.preset_label(kind, str(pid)))
	# Show what is active now.
	var layer := _layer()
	var sid := str(PlacedLightService.active_style.get(kind, ""))
	var cur := ""
	if layer != null and layer.styles.has(sid):
		cur = str(layer.styles[sid].get("preset_id", ""))
	var at := _preset_ids.find(cur)
	_preset_pick.select(maxi(at, 0))


func _on_new_preset(i: int) -> void:
	var kind := _tool_kind()
	if kind.is_empty() or i < 0 or i >= _preset_ids.size():
		return
	PlacedLightService.style_for_preset(_main, kind, str(_preset_ids[i]))
	PlacedLightService.commit(_main)
	_hint_text("New %s lights use “%s”" % [kind, _preset_pick.get_item_text(i)])


func _hint_text(t: String) -> void:
	if _hint != null:
		_hint.text = t


func _toggle_space() -> void:
	if _gizmo == null:
		return
	_gizmo.world_space = not _gizmo.world_space
	_space_btn.text = "Gizmo: World" if _gizmo.world_space else "Gizmo: Local"


func _set_night(on: bool) -> void:
	if _main == null or not ("day_time" in _main):
		return
	if on and _night_saved == null:
		_night_saved = float(_main.get("day_time"))
		_main.set("day_time", NIGHT_HOUR)
	elif not on and _night_saved != null:
		_main.set("day_time", float(_night_saved))
		_night_saved = null
	if _night_btn != null:
		UITheme.style_toggle(_night_btn, _night_saved != null)


func _do_undo(redo: bool) -> void:
	var ok := PlacedLightService.redo(_main) if redo else PlacedLightService.undo(_main)
	_hint_text(("Redone" if redo else "Undone") if ok else "Nothing to %s" % ("redo" if redo else "undo"))


# ---------------------------------------------------------------------------
# Model → UI
# ---------------------------------------------------------------------------

func _on_model_changed() -> void:
	if not _active:
		return
	if _undo_btn != null:
		_undo_btn.disabled = not PlacedLightService.can_undo()
		_redo_btn.disabled = not PlacedLightService.can_redo()
	_rebuild_styles()
	_rebuild_groups()
	var sig := _selection_signature()
	if sig != _insp_sig:
		_insp_sig = sig
		_rebuild_inspector()
	else:
		_sync_inspector_values()


func _layer() -> PlacedLightLayer:
	return PlacedLightService.get_layer(_main)


func _selected_recs() -> Array:
	var out: Array = []
	var layer := _layer()
	if layer == null:
		return out
	for id in PlacedLightService.selection:
		var r := layer.find_light(id)
		if not r.is_empty():
			out.append(r)
	return out


func _selection_kinds() -> Array:
	var kinds: Array = []
	for r in _selected_recs():
		if not str(r["kind"]) in kinds:
			kinds.append(str(r["kind"]))
	return kinds


## What the inspector's STRUCTURE depends on (rebuild only when it changes —
## rebuilding while a slider is held would drop the grab).
func _selection_signature() -> String:
	var parts: PackedStringArray = []
	for r in _selected_recs():
		parts.append("%s:%s:%s:%s" % [r["id"], r["style_id"], str((r["overrides"] as Dictionary).keys()),
			str(r.get("graph_item_id", ""))])
	return "|".join(parts) + "#" + str(_into_style)


func _rebuild_styles() -> void:
	var layer := _layer()
	if layer == null or _styles_box == null:
		return
	for c in _styles_box.get_children():
		c.queue_free()
	var kinds := _selection_kinds()
	var ids := layer.styles.keys()
	ids.sort_custom(func(a, b) -> bool:
		return str(layer.styles[a].get("name", "")) < str(layer.styles[b].get("name", "")))
	if ids.is_empty():
		_label(_styles_box, "Place a light to start a style.", UITheme.C_TEXT_M, UITheme.FONT_XS)
	for sid in ids:
		var st: Dictionary = layer.styles[sid]
		var kind := str(st.get("kind", "omni"))
		var res := PlacedLightStyles.resolve(kind, st.get("fields", {}), {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_styles_box.add_child(row)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(14, 14)
		sw.color = PlacedLightPower.parse_color(str(res.get("color", "ffffff")))
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sw)
		var active := str(PlacedLightService.active_style.get(kind, "")) == str(sid)
		var name_btn := Button.new()
		name_btn.text = "%s%s · %s (%d)" % ["● " if active else "", str(st.get("name", "Style")),
			kind, layer.style_usage(str(sid))]
		name_btn.tooltip_text = "Click: select every light using this style\nDouble-click: rename"
		name_btn.flat = true
		name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_btn.clip_text = true
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_btn.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		name_btn.focus_mode = Control.FOCUS_NONE
		var s_id := str(sid)
		name_btn.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).double_click:
				_rename_style(s_id))
		name_btn.pressed.connect(func() -> void:
			PlacedLightService.active_style[kind] = s_id
			PlacedLightService.set_selection(_main, layer.lights_with_style(s_id)))
		row.add_child(name_btn)
		var apply := _small_btn(row, "Apply", "Give the selected %s lights this style" % kind, func() -> void:
			PlacedLightService.checkpoint(_main)
			PlacedLightService.apply_style(_main, PlacedLightService.selection.duplicate(), s_id)
			PlacedLightService.commit(_main))
		apply.disabled = not kind in kinds
		_small_btn(row, "✕", "Delete style (its lights keep their look)", func() -> void:
			PlacedLightService.checkpoint(_main)
			layer.remove_style(s_id)
			PlacedLightService.rebuild_all(_main)
			PlacedLightService.commit(_main))
	if PlacedLightService.selection.size() >= 1:
		_small_btn(_styles_box, "+ New style from selection",
			"Save the first selected light's look as a new style and apply it to the selection",
			_new_style_from_selection)


func _rename_style(sid: String) -> void:
	var layer := _layer()
	var dlg := AcceptDialog.new()
	dlg.title = "Rename style"
	var le := LineEdit.new()
	le.text = layer.style_display_name(sid)
	le.custom_minimum_size = Vector2(240, 0)
	dlg.add_child(le)
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		if not le.text.strip_edges().is_empty():
			PlacedLightService.checkpoint(_main)
			layer.styles[sid]["name"] = le.text.strip_edges()
			PlacedLightService.commit(_main)
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered()
	le.grab_focus()


func _new_style_from_selection() -> void:
	var sel := PlacedLightService.selection.duplicate()
	if sel.is_empty():
		return
	var layer := _layer()
	var first := layer.find_light(str(sel[0]))
	PlacedLightService.checkpoint(_main)
	var sid := PlacedLightService.style_from_light(_main, str(sel[0]),
		"%s %d" % [str(first["kind"]).capitalize(), layer.styles.size() + 1])
	PlacedLightService.apply_style(_main, sel, sid)
	PlacedLightService.commit(_main)


func _rebuild_groups() -> void:
	var layer := _layer()
	if layer == null or _groups_box == null:
		return
	for c in _groups_box.get_children():
		c.queue_free()
	if layer.groups.is_empty():
		_label(_groups_box, "Select lights and press “Group selection”.", UITheme.C_TEXT_M, UITheme.FONT_XS)
	for gid in layer.groups.keys():
		var g: Dictionary = layer.groups[gid]
		var members := layer.group_members(str(gid))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 3)
		_groups_box.add_child(row)
		var g_id := str(gid)
		var nb := Button.new()
		nb.text = "%s (%d)" % [str(g.get("name", "Group")), members.size()]
		nb.flat = true
		nb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		nb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nb.clip_text = true
		nb.focus_mode = Control.FOCUS_NONE
		nb.tooltip_text = "Select the group"
		nb.pressed.connect(func() -> void: PlacedLightService.set_selection(_main, layer.group_members(g_id)))
		row.add_child(nb)
		var any_on := false
		for id in members:
			if bool(layer.find_light(id).get("enabled", true)):
				any_on = true
		_small_btn(row, "⏻" if any_on else "○", "Switch the group on / off", func() -> void:
			PlacedLightService.checkpoint(_main)
			PlacedLightService.set_enabled(_main, layer.group_members(g_id), not any_on)
			PlacedLightService.commit(_main))
		_small_btn(row, "🙈" if bool(g.get("hidden", false)) else "👁", "Hide / show the group in the world",
			func() -> void:
				PlacedLightService.checkpoint(_main)
				g["hidden"] = not bool(g.get("hidden", false))
				PlacedLightService.refresh_ids(_main, layer.group_members(g_id))
				PlacedLightService.commit(_main))
		_small_btn(row, "✕", "Delete the group (keeps its lights)", func() -> void:
			PlacedLightService.checkpoint(_main)
			layer.remove_group(g_id)
			PlacedLightService.commit(_main))
	if not PlacedLightService.selection.is_empty():
		_small_btn(_groups_box, "+ Group selection", "Make a named group from the selected lights", func() -> void:
			PlacedLightService.checkpoint(_main)
			layer.add_group("Group %d" % (layer.groups.size() + 1), PlacedLightService.selection.duplicate())
			PlacedLightService.commit(_main))


func _rebuild_inspector() -> void:
	for c in _insp_box.get_children():
		c.queue_free()
	_rows.clear()
	var recs := _selected_recs()
	if recs.is_empty():
		_label(_insp_box, "Nothing selected. Use a tool above, or click a light.", UITheme.C_TEXT_M, UITheme.FONT_XS)
		_add_quick_select_row()
		return
	var layer := _layer()
	var kinds := _selection_kinds()
	var first: Dictionary = recs[0]
	var res := layer.resolved(first)
	var sid := str(first["style_id"])
	var same_style := true
	for r in recs:
		if str(r["style_id"]) != sid:
			same_style = false
	var title := "%d selected" % recs.size() if recs.size() > 1 else \
		"%s · %s" % [str(first["kind"]).capitalize(), layer.style_display_name(sid)]
	_label(_insp_box, title, UITheme.C_TEXT, UITheme.FONT_MD)

	# Scope: edit the style (every light using it) or just the selection.
	var scope := OptionButton.new()
	var users := layer.style_usage(sid)
	scope.add_item("Edits change the STYLE (%d light%s)" % [users, "" if users == 1 else "s"] if same_style
		else "Edits change each light's STYLE")
	scope.add_item("Edits change only the selected light%s" % ("s" if recs.size() > 1 else ""))
	scope.select(0 if _into_style else 1)
	scope.focus_mode = Control.FOCUS_NONE
	scope.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	scope.item_selected.connect(func(i: int) -> void:
		_into_style = i == 0
		_insp_sig = ""
		_on_model_changed())
	_insp_box.add_child(scope)

	# Actions.
	var acts := HFlowContainer.new()
	acts.add_theme_constant_override("h_separation", 3)
	acts.add_theme_constant_override("v_separation", 3)
	_insp_box.add_child(acts)
	_small_btn(acts, "Duplicate", "Ctrl+D — copies 1 m to the side", func() -> void: _duplicate_selection(1))
	_small_btn(acts, "Array ×5", "Five copies in a row, spaced by the selection's size", func() -> void: _duplicate_selection(5))
	_small_btn(acts, "Same kind", "Select every light of this kind", func() -> void:
		var all: Array = []
		for k in kinds:
			all.append_array(PlacedLightService.group_ids_of_kind(_main, k))
		PlacedLightService.set_selection(_main, all))
	_small_btn(acts, "Make unique", "Detach the selection into its own new style", func() -> void:
		PlacedLightService.checkpoint(_main)
		var new_sid := ""
		for r in _selected_recs():
			if new_sid.is_empty():
				new_sid = layer.make_unique(str(r["id"]))
			else:
				r["style_id"] = new_sid
				r["overrides"] = {}
		PlacedLightService.refresh_ids(_main, PlacedLightService.selection.duplicate())
		PlacedLightService.commit(_main))
	var has_ov := false
	for r in recs:
		if not (r["overrides"] as Dictionary).is_empty():
			has_ov = true
	if has_ov:
		_small_btn(acts, "Push to style", "Make the selection's overrides the style's values (all users follow)",
			func() -> void:
				PlacedLightService.checkpoint(_main)
				for r in _selected_recs():
					layer.push_overrides_to_style(str(r["id"]))
				PlacedLightService.refresh_style_users(_main, sid)
				PlacedLightService.commit(_main))
	var any_on := false
	for r in recs:
		if bool(r.get("enabled", true)):
			any_on = true
	_small_btn(acts, "Turn off" if any_on else "Turn on", "Switch the selection off / on", func() -> void:
		PlacedLightService.checkpoint(_main)
		PlacedLightService.set_enabled(_main, PlacedLightService.selection.duplicate(), not any_on)
		PlacedLightService.commit(_main))
	if kinds == ["mover"] and recs.size() >= 2:
		_small_btn(acts, "Fan phases", "Spread the sweep phase evenly along the row — a set of heads becomes a fan / a wave",
			func() -> void:
				PlacedLightService.checkpoint(_main)
				PlacedLightService.fan_phases(_main, PlacedLightService.selection.duplicate())
				PlacedLightService.commit(_main))
		_small_btn(acts, "Sync phases", "Every selected fixture sweeps in unison", func() -> void:
			PlacedLightService.checkpoint(_main)
			PlacedLightService.set_field(_main, PlacedLightService.selection.duplicate(), "phase_deg", 0.0, false)
			PlacedLightService.commit(_main))
	var del := _small_btn(acts, "Delete", "Del", _delete_selection)
	del.add_theme_color_override("font_color", UITheme.C_ERROR)

	# Field rows, grouped into sections.
	var section := ""
	for f in FIELDS:
		var shows := false
		for k in kinds:
			if k in (f["kinds"] as Array):
				shows = true
		# Rows shared by every selected kind only (a spot's cone has no
		# meaning on a string).
		for k in kinds:
			if not k in (f["kinds"] as Array):
				shows = false
		# A preset list belongs to ONE kind.
		if str(f["key"]) == "preset" and kinds.size() != 1:
			shows = false
		if not shows:
			continue
		if str(f["section"]) != section:
			section = str(f["section"])
			_label(_insp_box, section, UITheme.C_AMBER, UITheme.FONT_SM)
		_add_field_row(f, res)

	if recs.size() == 1:
		_add_graph_row(first)
	_sync_inspector_values()


func _add_quick_select_row() -> void:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 3)
	_insp_box.add_child(row)
	for k in ["omni", "spot", "mover", "string"]:
		var kind: String = k
		_small_btn(row, "All %ss" % kind, "Select every %s light" % kind, func() -> void:
			PlacedLightService.set_selection(_main, PlacedLightService.group_ids_of_kind(_main, kind)))


func _add_field_row(f: Dictionary, res: Dictionary) -> void:
	var key := str(f["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_insp_box.add_child(row)
	var dot := Label.new()
	dot.text = "●"
	dot.add_theme_color_override("font_color", UITheme.C_AMBER)
	dot.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	dot.tooltip_text = "Overridden on this light (differs from its style)"
	dot.modulate.a = 0.0
	dot.custom_minimum_size = Vector2(10, 0)
	row.add_child(dot)
	var entry := {"type": f["type"], "dot": dot}
	match str(f["type"]):
		"float", "kelvin":
			var start := 6500.0 if f["type"] == "kelvin" else float(res.get(key, f.get("min", 0.0)))
			var pair := SliderSpinRow.add(row, str(f["label"]), float(f["min"]), float(f["max"]),
				start, func(v: float) -> void: _on_field(key, v), _style_row_label,
				74, 110, 62, float(f.get("step", -1.0)))
			pair["row"].size_flags_horizontal = Control.SIZE_EXPAND_FILL
			entry["pair"] = pair
		"color":
			_style_row_label(_add_plain_label(row, str(f["label"])), str(f["label"]))
			var cp := ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(0, 22)
			cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cp.edit_alpha = false
			cp.focus_mode = Control.FOCUS_NONE
			cp.color_changed.connect(func(c: Color) -> void: _on_field(key, c.to_html(false)))
			row.add_child(cp)
			entry["picker"] = cp
		"bool":
			var cb := CheckBox.new()
			cb.text = str(f["label"])
			cb.focus_mode = Control.FOCUS_NONE
			cb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			cb.toggled.connect(func(on: bool) -> void: _on_field(key, on))
			row.add_child(cb)
			entry["check"] = cb
		"direction":
			var cb2 := CheckBox.new()
			cb2.text = str(f["label"])
			cb2.focus_mode = Control.FOCUS_NONE
			cb2.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			cb2.toggled.connect(func(on: bool) -> void: _on_field(key, -1.0 if on else 1.0))
			row.add_child(cb2)
			entry["check"] = cb2
		"enum", "preset", "effect":
			_style_row_label(_add_plain_label(row, str(f["label"])), str(f["label"]))
			var ob := OptionButton.new()
			ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ob.focus_mode = Control.FOCUS_NONE
			ob.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			var values: Array = []
			var labels: Array = []
			match str(f["type"]):
				"preset":
					var pk: String = str(_selection_kinds()[0]) if not _selection_kinds().is_empty() else "string"
					values.append("")
					labels.append("Custom")
					for p in PlacedLightStyles.PRESET_ORDER.get(pk, []):
						values.append(str(p))
						labels.append(PlacedLightStyles.preset_label(pk, str(p)))
				"effect":
					values.assign(LedEffects.EFFECTS)
					labels.assign(LedEffects.EFFECT_LABELS)
				_:
					values = f["options"]
					labels = f["option_labels"]
			for i in values.size():
				ob.add_item(str(labels[i]))
			var t := str(f["type"])
			ob.item_selected.connect(func(i: int) -> void:
				if t == "preset":
					_apply_preset(str(values[i]))
				else:
					_on_field(key, values[i]))
			row.add_child(ob)
			entry["option"] = ob
			entry["values"] = values
	var rv := Button.new()
	rv.text = "↺"
	rv.flat = true
	rv.tooltip_text = "Revert to the style's value"
	rv.focus_mode = Control.FOCUS_NONE
	rv.modulate.a = 0.0
	rv.pressed.connect(func() -> void: _revert_field(key))
	row.add_child(rv)
	entry["revert"] = rv
	_rows[key] = entry


func _add_plain_label(row: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(74, 0)
	row.add_child(l)
	return l


func _style_row_label(l: Label, text: String) -> void:
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)


func _add_graph_row(rec: Dictionary) -> void:
	_label(_insp_box, "Graph", UITheme.C_AMBER, UITheme.FONT_SM)
	var row := HBoxContainer.new()
	_insp_box.add_child(row)
	var gid := str(rec.get("graph_item_id", ""))
	var id := str(rec["id"])
	var res := _layer().resolved(rec)
	var watts := PlacedLightService.estimate_watts(_main, rec, res)
	if gid.is_empty():
		_label(row, "Not a load (~%.0f W if added)" % watts, UITheme.C_TEXT_M, UITheme.FONT_XS) \
			.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_small_btn(row, "Add to graph", "Track it as an AC load; it then lights only when the graph item is on and AC is available",
			func() -> void:
				PlacedLightService.checkpoint(_main)
				if not PlacedLightService.add_to_graph(_main, id):
					_hint_text("No systems graph on this map")
				PlacedLightService.commit(_main))
	else:
		_label(row, "Graph load %s (%.0f W)" % [gid, watts], UITheme.C_OK, UITheme.FONT_XS) \
			.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_small_btn(row, "Remove", "Remove its graph load (the light stays)", func() -> void:
			PlacedLightService.checkpoint(_main)
			PlacedLightService.remove_from_graph(_main, id)
			PlacedLightService.commit(_main))


## Push live values into the rows without rebuilding them.
func _sync_inspector_values() -> void:
	var recs := _selected_recs()
	if recs.is_empty():
		return
	var layer := _layer()
	var first: Dictionary = recs[0]
	var res := layer.resolved(first)
	_syncing = true
	for key in _rows.keys():
		var e: Dictionary = _rows[key]
		var overridden := false
		for r in recs:
			if (r["overrides"] as Dictionary).has(key):
				overridden = true
		(e["dot"] as Label).modulate.a = 1.0 if overridden else 0.0
		(e["revert"] as Button).modulate.a = 1.0 if overridden else 0.0
		(e["revert"] as Button).disabled = not overridden
		var v: Variant = res.get(key)
		match str(e["type"]):
			"float":
				SliderSpinRow.set_values(e["pair"], float(v))
			"color":
				(e["picker"] as ColorPickerButton).color = PlacedLightPower.parse_color(str(v))
			"bool":
				(e["check"] as CheckBox).set_pressed_no_signal(bool(v))
			"direction":
				(e["check"] as CheckBox).set_pressed_no_signal(float(v) < 0.0)
			"enum", "preset", "effect":
				var idx := (e["values"] as Array).find(v)
				if idx >= 0:
					(e["option"] as OptionButton).select(idx)
	_syncing = false


# ---------------------------------------------------------------------------
# UI → model
# ---------------------------------------------------------------------------

## Every inspector edit. Edits within 0.6 s of each other are ONE undo step
## (a slider drag fires dozens of value_changed), and the file is written once
## the edits pause.
func _on_field(key: String, value: Variant) -> void:
	if _syncing or PlacedLightService.selection.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _edit_ms > 600:
		PlacedLightService.checkpoint(_main)
	_edit_ms = now
	if key == "_kelvin":
		key = "color"
		value = PlacedLightStyles.kelvin_to_color(float(value)).to_html(false)
	if key == "real_lights":
		value = int(value)
	PlacedLightService.set_field(_main, PlacedLightService.selection.duplicate(), key, value, _into_style)
	_save_timer.start()
	# Override dots / the colour swatch follow the edit (no structural rebuild).
	_sync_inspector_values()
	_rebuild_styles()


func _apply_preset(preset: String) -> void:
	if _syncing:
		return
	var kinds := _selection_kinds()
	if kinds.size() != 1 or preset.is_empty():
		return
	PlacedLightService.checkpoint(_main)
	var fields := PlacedLightStyles.preset_fields(preset, str(kinds[0]))
	for k in fields.keys():
		PlacedLightService.set_field(_main, PlacedLightService.selection.duplicate(), k, fields[k], _into_style)
	PlacedLightService.commit(_main)


func _revert_field(key: String) -> void:
	var layer := _layer()
	PlacedLightService.checkpoint(_main)
	for id in PlacedLightService.selection:
		layer.revert_override(id, key)
	PlacedLightService.refresh_ids(_main, PlacedLightService.selection.duplicate())
	PlacedLightService.commit(_main)


func _delete_selection() -> void:
	var sel := PlacedLightService.selection.duplicate()
	if sel.is_empty():
		return
	PlacedLightService.checkpoint(_main)
	PlacedLightService.delete_ids(_main, sel)
	PlacedLightService.set_selection(_main, [])
	PlacedLightService.commit(_main)
	_hint_text("Deleted %d" % sel.size())


## Copies step along the camera's right by the selection's own width (≥ 1 m),
## so an array of spots lands as a tidy row.
func _duplicate_selection(count: int) -> void:
	var sel := PlacedLightService.selection.duplicate()
	if sel.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	var right := cam.global_basis.x if cam != null else Vector3.RIGHT
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 1e-6 else Vector3.RIGHT
	var layer := _layer()
	var lo := INF
	var hi := -INF
	for id in sel:
		var rec := layer.find_light(id)
		var pts: Array = PlacedLightLayer.waypoints_of(rec) if str(rec["kind"]) == "string" else [layer.position_of(rec)]
		for p in pts:
			lo = minf(lo, (p as Vector3).dot(right))
			hi = maxf(hi, (p as Vector3).dot(right))
	var step := maxf(hi - lo + 1.0, 1.0) if count > 1 or hi - lo > 0.5 else 1.0
	PlacedLightService.checkpoint(_main)
	var made: Array = []
	for k in count:
		made.append_array(PlacedLightService.duplicate_ids(_main, sel, right * step * float(k + 1)))
	PlacedLightService.set_selection(_main, made if count == 1 else sel + made)
	PlacedLightService.commit(_main)
	_hint_text("Made %d cop%s" % [made.size(), "y" if made.size() == 1 else "ies"])


# ---------------------------------------------------------------------------
# World nodes (gumball + string preview)
# ---------------------------------------------------------------------------

func _ensure_world_nodes() -> void:
	if _gizmo == null or not is_instance_valid(_gizmo):
		_gizmo = LightGizmo.new()
		_gizmo.name = "LightStudioGizmo"
		_main.add_child(_gizmo)
	if _string_preview == null or not is_instance_valid(_string_preview):
		_string_preview_mesh = ImmediateMesh.new()
		_string_preview = MeshInstance3D.new()
		_string_preview.name = "LightStudioStringPreview"
		_string_preview.top_level = true
		_string_preview.mesh = _string_preview_mesh
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.85, 0.3)
		m.no_depth_test = true
		_string_preview.material_override = m
		_main.add_child(_string_preview)


func _process(_delta: float) -> void:
	if not _active:
		return
	_update_gizmo()
	_overlay.queue_redraw()


func _update_gizmo() -> void:
	var cam := get_viewport().get_camera_3d()
	var layer := _layer()
	if _gizmo == null or cam == null or layer == null:
		return
	var sel := PlacedLightService.selection
	var drawing := _tool == "string" and not _string_pts.is_empty()
	if sel.is_empty() or drawing or _dragging in ["surface", "pin", "box", "string_move"]:
		_gizmo.hide_gizmo()
		return
	var only_strings := true
	for id in sel:
		if str(layer.find_light(id).get("kind", "")) != "string":
			only_strings = false
	var first := layer.find_light(sel[0])
	var rot := LightGizmoMath.basis_of(layer.rotation_of(first))
	_gizmo.show_rotate = true
	# A string's handle is a small one at its centre — for fine adjustment; the
	# big moves are Ctrl+drag on the string itself.
	_gizmo.size_mult = 0.6 if only_strings else 1.0
	var spot := {}
	if sel.size() == 1 and str(first["kind"]) == "spot":
		var res := layer.resolved(first)
		spot = {"angle": res.get("spot_angle", 35.0), "range": res.get("range", 12.0)}
	_gizmo.set_target(_selection_center(), Basis.IDENTITY if only_strings else rot, cam, spot)


## Centre of the selection: a light's position, a string's pin centroid.
func _selection_center() -> Vector3:
	var layer := _layer()
	var c := Vector3.ZERO
	var n := 0
	for id in PlacedLightService.selection:
		var rec := layer.find_light(id)
		if str(rec.get("kind", "")) == "string":
			for p in PlacedLightLayer.waypoints_of(rec):
				c += p
				n += 1
		elif not rec.is_empty():
			c += layer.position_of(rec)
			n += 1
	return c / float(maxi(n, 1))


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _pointer_over_ui() -> bool:
	# Popups opened by the dock's widgets (colour picker, option menus) are
	# their own windows, so world clicks never arrive through them.
	var m := get_viewport().get_mouse_position()
	return _panel != null and _panel.visible and _panel.get_global_rect().has_point(m)


func _ray(mouse: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	return {"o": cam.project_ray_origin(mouse), "d": cam.project_ray_normal(mouse), "cam": cam}


func _surface(mouse: Vector2) -> Dictionary:
	var r := _ray(mouse)
	if r.is_empty():
		return {"valid": false}
	return ConduitSurfaceAim.pick_ray(_main, r["o"], r["d"], [], (r["cam"] as Camera3D).global_position)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if _handle_key(event as InputEventKey):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_on_motion((event as InputEventMouseMotion).position)
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if _pointer_over_ui() or CursorController.overlay_look_active():
				return
			_on_press(mb)
			get_viewport().set_input_as_handled()
		elif not _pending.is_empty() or not _dragging.is_empty():
			_on_release(mb.position)
			get_viewport().set_input_as_handled()


func _handle_key(k: InputEventKey) -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is SpinBox or focus is TextEdit:
		return false
	if k.ctrl_pressed and k.keycode == KEY_Z:
		_do_undo(k.shift_pressed)
		return true
	if k.ctrl_pressed and k.keycode == KEY_Y:
		_do_undo(true)
		return true
	if k.ctrl_pressed and k.keycode == KEY_D:
		_duplicate_selection(1)
		return true
	match k.keycode:
		KEY_DELETE:
			_delete_selection()
			return true
		KEY_BACKSPACE:
			if not _string_pts.is_empty():
				_string_pts.pop_back()
				_redraw_string_preview(get_viewport().get_mouse_position())
				return true
			_delete_selection()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if _tool == "string":
				_finish_string()
				return true
	if k.physical_keycode == KEY_L:
		_toggle_space()
		return true
	return false


func _on_press(mb: InputEventMouseButton) -> void:
	_press_pos = mb.position
	_press_ms = Time.get_ticks_msec()
	_pending = {}
	var r := _ray(mb.position)
	if r.is_empty():
		return
	# The gumball wins over everything under it.
	if _gizmo != null and _gizmo.visible and not (_tool == "string" and not _string_pts.is_empty()):
		var h := _gizmo.pick(r["o"], r["d"])
		if not h.is_empty():
			_begin_gizmo_drag(h, r)
			return
	# An EXISTING pin or light under the pointer is grabbed whatever the tool:
	# a press arms select-or-drag (a drag repositions it, a click selects it)
	# instead of the tool's own action. Without this, pressing a finished
	# string's pin with the String tool still active started a NEW string from
	# it, so pins could not be moved while J was open. The one exception is a
	# string in progress, where clicks are its own pins (and a double-click on
	# its last pin finishes it).
	if _tool != "select" and not (_tool == "string" and not _string_pts.is_empty()):
		var grab := PlacedLightService.pick(_main, r["o"], r["d"], false)
		if str(grab["type"]) != "":
			_pending = {"hit": grab, "shift": mb.shift_pressed, "ctrl": mb.ctrl_pressed}
			return
	match _tool:
		"string":
			_string_click(mb)
		"aim":
			_aim_click(mb.position)
		"omni", "spot", "mover":
			_place_point(mb.position)
		_:
			var hit2 := PlacedLightService.pick(_main, r["o"], r["d"], true)
			_pending = {"hit": hit2, "shift": mb.shift_pressed, "ctrl": mb.ctrl_pressed}


func _on_motion(pos: Vector2) -> void:
	var r := _ray(pos)
	if r.is_empty():
		return
	if not _pending.is_empty() and _dragging.is_empty() and pos.distance_to(_press_pos) > DRAG_PX:
		_begin_pending_drag(pos)
	match _dragging:
		"gizmo":
			_update_gizmo_drag(r)
		"surface":
			_update_surface_drag(pos)
		"pin":
			_update_pin_drag(pos)
		"string_move":
			_update_whole_drag(pos)
		"box":
			_drag["to"] = pos
	if _dragging.is_empty():
		if _gizmo != null and _gizmo.visible:
			_gizmo.set_hot(_gizmo.pick(r["o"], r["d"]))
		if _tool == "string" and not _string_pts.is_empty():
			_redraw_string_preview(pos)
		_update_hover(r)


func _on_release(pos: Vector2) -> void:
	if _dragging.is_empty() and not _pending.is_empty():
		# A click, not a drag.
		var hit: Dictionary = _pending.get("hit", {})
		if str(hit.get("type", "")) == "":
			if not bool(_pending.get("shift", false)):
				PlacedLightService.set_selection(_main, [])
		else:
			_select_pick(hit, bool(_pending.get("shift", false)))
		_pending = {}
		return
	_pending = {}
	if _dragging == "box":
		_finish_box(pos)
	_end_drag(true)


func _select_pick(hit: Dictionary, shift: bool) -> void:
	var id := str(hit["id"])
	if shift:
		PlacedLightService.toggle_in_selection(_main, id)
	else:
		PlacedLightService.set_selection(_main, [id])


func _update_hover(r: Dictionary) -> void:
	var hit := PlacedLightService.pick(_main, r["o"], r["d"], false)
	var pin: PlacedLightWaypoint = null
	if str(hit["type"]) == "pin":
		var node := PlacedLightRuntime.find_node(_main, str(hit["id"])) as PlacedStringLight
		if node != null:
			pin = node.pin(int(hit["index"]))
	if pin != _hover_pin:
		if _hover_pin != null and is_instance_valid(_hover_pin):
			_hover_pin.set_hot(false)
		_hover_pin = pin
		if pin != null:
			pin.set_hot(true)


# -- Drags -------------------------------------------------------------------

## What a drag on a light / pin / wire does:
##   plain        a light slides along surfaces · a pin moves alone · a wire
##                grows a new pin
##   Ctrl         the WHOLE string (or the whole selection) moves as one
##   Shift        duplicate it (them), then move the copy — the copies join
##                the source's group and share its style
func _begin_pending_drag(pos: Vector2) -> void:
	var hit: Dictionary = _pending.get("hit", {})
	var t := str(hit.get("type", ""))
	var id := str(hit.get("id", ""))
	var ctrl := bool(_pending.get("ctrl", false))
	var dup := bool(_pending.get("shift", false))
	_pending = {}
	if t != "" and (ctrl or dup):
		var ids: Array = PlacedLightService.selection.duplicate() if id in PlacedLightService.selection else [id]
		var moving := PlacedLightService.begin_drag_many(_main, ids, dup)
		if moving.is_empty():
			_hint_text("Light limit reached")
			return
		if not dup:
			PlacedLightService.set_selection(_main, moving)
		_dragging = "string_move"
		_drag = {"from": null}
		_hint_text("Duplicating — drop the copy" if dup else "Moving %d as one" % moving.size())
		return
	match t:
		"light":
			if not id in PlacedLightService.selection:
				PlacedLightService.set_selection(_main, [id])
			PlacedLightService.checkpoint(_main)
			_dragging = "surface"
			_drag = {"id": id}
		"pin":
			PlacedLightService.set_selection(_main, [id])
			PlacedLightService.checkpoint(_main)
			_dragging = "pin"
			_drag = {"id": id, "index": int(hit["index"])}
		"wire":
			PlacedLightService.set_selection(_main, [id])
			PlacedLightService.checkpoint(_main)
			var at := PlacedLightService.insert_waypoint(_main, id, int(hit["index"]), hit["point"])
			if at < 0:
				_hint_text("This string has the maximum number of pins")
				return
			_dragging = "pin"
			_drag = {"id": id, "index": at}
		_:
			_dragging = "box"
			_drag = {"from": _press_pos, "to": pos}


## Whole-light / whole-string drag: everything moves by how far the surface
## point under the mouse has moved since the drag began (so a lamp hanging
## 3 m up keeps its height, and nothing jumps on the first frame).
func _update_whole_drag(pos: Vector2) -> void:
	var aim := _surface(pos)
	if not bool(aim.get("valid", false)):
		return
	var p: Vector3 = aim["position"]
	if _drag.get("from") == null:
		_drag["from"] = p
	var delta: Vector3 = p - (_drag["from"] as Vector3)
	if Input.is_key_pressed(KEY_ALT):
		delta.y = 0.0   # Alt: keep the height, slide in plan
	PlacedLightService.drag_to(_main, delta)


func _begin_gizmo_drag(handle: String, r: Dictionary) -> void:
	var layer := _layer()
	PlacedLightService.checkpoint(_main)
	_dragging = "gizmo"
	var o := _gizmo.global_position
	var start := {}
	for id in PlacedLightService.selection:
		var rec := layer.find_light(id)
		start[id] = {"pos": layer.position_of(rec), "rot": layer.rotation_of(rec),
			"pts": PlacedLightLayer.waypoints_of(rec)}
	_drag = {"handle": handle, "origin": o, "start": start, "applied": Vector3.ZERO}
	if handle.begins_with("r"):
		var n := _gizmo.axis(handle)
		var hit: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, n)
		var ref: Vector3 = ((hit as Vector3) - o) if hit != null else n.cross(Vector3.UP + Vector3(0.01, 0, 0))
		_drag["axis"] = n
		_drag["ref"] = ref
	elif handle.length() == 1:
		var ax := _gizmo.axis(handle)
		_drag["axis"] = ax
		_drag["s0"] = LightGizmoMath.axis_param(r["o"], r["d"], o, ax)
	else:
		var n2 := _gizmo.plane_normal(handle)
		_drag["normal"] = n2
		_drag["hit0"] = LightGizmoMath.ray_plane(r["o"], r["d"], o, n2)
	_gizmo.set_hot(handle)


func _update_gizmo_drag(r: Dictionary) -> void:
	var handle := str(_drag["handle"])
	var o: Vector3 = _drag["origin"]
	var snap := Input.is_key_pressed(KEY_SHIFT)
	var layer := _layer()
	if handle.begins_with("r"):
		var n: Vector3 = _drag["axis"]
		var hit: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, n)
		if hit == null:
			return
		var ang := LightGizmoMath.ring_angle(hit, o, n, _drag["ref"])
		if snap:
			ang = deg_to_rad(LightGizmoMath.snap(rad_to_deg(ang), SNAP_DEG))
		var rb := Basis(n, ang)
		for id in _drag["start"].keys():
			var st: Dictionary = _drag["start"][id]
			var rec := layer.find_light(id)
			if str(rec.get("kind", "")) == "string":
				# A string turns about the handle: every pin swings round it.
				var turned: Array = []
				for sp in st["pts"]:
					turned.append(o + rb * ((sp as Vector3) - o))
				layer.set_waypoints(id, turned)
				continue
			var new_pos: Vector3 = o + rb * ((st["pos"] as Vector3) - o)
			var rot := LightGizmoMath.rotate_by(st["rot"], n, ang, true)
			rec["x"] = new_pos.x
			rec["y"] = new_pos.y
			rec["z"] = new_pos.z
			rec["pitch"] = rot.x
			rec["yaw"] = rot.y
			rec["roll"] = rot.z
		PlacedLightService.refresh_ids(_main, _drag["start"].keys())
		_hint_text("Rotate %.1f°" % rad_to_deg(ang))
		return
	var delta := Vector3.ZERO
	if handle.length() == 1:
		var s := LightGizmoMath.axis_param(r["o"], r["d"], o, _drag["axis"])
		if is_nan(s) or is_nan(float(_drag["s0"])):
			return
		var d := s - float(_drag["s0"])
		if snap:
			d = LightGizmoMath.snap(d, SNAP_M)
		delta = (_drag["axis"] as Vector3) * d
	else:
		var hit2: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, _drag["normal"])
		if hit2 == null or _drag["hit0"] == null:
			return
		delta = (hit2 as Vector3) - (_drag["hit0"] as Vector3)
		if snap:
			delta = LightGizmoMath.snap_vec(delta, SNAP_M)
	var step: Vector3 = delta - (_drag["applied"] as Vector3)
	_drag["applied"] = delta
	PlacedLightService.translate_ids(_main, _drag["start"].keys(), step)
	_hint_text("Move %.2f m" % delta.length())


func _update_surface_drag(pos: Vector2) -> void:
	var aim := _surface(pos)
	if not bool(aim.get("valid", false)):
		return
	var layer := _layer()
	var id := str(_drag["id"])
	var rec := layer.find_light(id)
	if rec.is_empty():
		return
	var target: Vector3 = (aim["position"] as Vector3) + (aim["normal"] as Vector3) * 0.2
	var delta := target - layer.position_of(rec)
	# Every selected light rides along (a group moves together).
	PlacedLightService.translate_ids(_main, PlacedLightService.selection.duplicate(), delta)


func _update_pin_drag(pos: Vector2) -> void:
	var aim := _surface(pos)
	if not bool(aim.get("valid", false)):
		return
	var p: Vector3 = aim["position"]
	if Input.is_key_pressed(KEY_SHIFT):
		# Axis lock: keep the pin's height, slide in XZ (or the reverse when the
		# aim is mostly vertical) — the conduit pins' Shift rule.
		var cur: Vector3 = PlacedLightLayer.waypoints_of(_layer().find_light(str(_drag["id"])))[int(_drag["index"])]
		p.y = cur.y
	PlacedLightService.set_waypoint(_main, str(_drag["id"]), int(_drag["index"]), p)


func _finish_box(pos: Vector2) -> void:
	var cam := get_viewport().get_camera_3d()
	var layer := _layer()
	if cam == null or layer == null:
		return
	var rect := Rect2(_drag["from"], Vector2.ZERO).expand(pos)
	var ids: Array = PlacedLightService.selection.duplicate() if Input.is_key_pressed(KEY_SHIFT) else []
	for rec in layer.lights:
		var pts: Array = PlacedLightLayer.waypoints_of(rec) if str(rec["kind"]) == "string" else [layer.position_of(rec)]
		for p in pts:
			if cam.is_position_behind(p):
				continue
			if rect.has_point(cam.unproject_position(p)):
				if not str(rec["id"]) in ids:
					ids.append(str(rec["id"]))
				break
	PlacedLightService.set_selection(_main, ids)
	_hint_text("%d selected" % ids.size())


func _end_drag(commit: bool) -> void:
	var was := _dragging
	_dragging = ""
	_drag = {}
	if _gizmo != null:
		_gizmo.set_hot("")
	if was == "string_move":
		if commit:
			PlacedLightService.end_drag(_main)
		else:
			PlacedLightService.cancel_drag(_main)
		return
	if commit and was in ["gizmo", "surface", "pin"]:
		PlacedLightService.commit(_main)


# -- Placement ---------------------------------------------------------------

func _place_point(mouse: Vector2) -> void:
	var aim := _surface(mouse)
	if not bool(aim.get("valid", false)):
		_hint_text("Aim at a surface")
		return
	var n: Vector3 = aim["normal"]
	var hit: Vector3 = aim["position"]
	var pos: Vector3 = hit + n * 0.4
	var rot := Vector3.ZERO
	if _tool == "spot":
		if n.y > 0.7:
			# Clicked the GROUND: a spot there would shine at the sky. Hang it
			# above the spot clicked and point it down at it (re-aim with Aim).
			pos = hit + Vector3(0.0, SPOT_HANG_M, 0.0)
			rot = LightGizmoMath.aim_rotation(pos, hit)
		else:
			# A wall / post: mount just off it, aimed out and a little down.
			pos = hit + n * 0.25
			var out := Vector3(n.x, 0.0, n.z).normalized() if Vector2(n.x, n.z).length() > 0.1 else n
			rot = LightGizmoMath.aim_rotation(pos, pos + out + Vector3(0.0, -tan(deg_to_rad(30.0)), 0.0))
	elif _tool == "mover":
		# A fixture STANDS on what it was clicked on — a floor head beams up,
		# one clicked under a truss or roof hangs from it and beams down.
		pos = hit + n * 0.01
		rot = MoverProgram.mount_rotation(n)
	PlacedLightService.checkpoint(_main)
	var id := PlacedLightService.add_point_light(_main, _tool, pos, rot)
	if id.is_empty():
		_hint_text("Light limit reached (%d)" % PlacedLightLayer.MAX_LIGHTS)
		return
	PlacedLightService.set_selection(_main, [id])
	PlacedLightService.commit(_main)


func _aim_click(mouse: Vector2) -> void:
	var aim := _surface(mouse)
	var layer := _layer()
	if not bool(aim.get("valid", false)) or layer == null:
		return
	var target: Vector3 = aim["position"]
	var n := 0
	PlacedLightService.checkpoint(_main)
	for id in PlacedLightService.selection:
		var rec := layer.find_light(id)
		match str(rec.get("kind", "")):
			"spot":
				var rot := LightGizmoMath.aim_rotation(layer.position_of(rec), target, float(rec.get("roll", 0.0)))
				PlacedLightService.set_rotation(_main, id, rot)
				n += 1
			"mover":
				# A mover keeps its mount; its SWEEP is centred on the target.
				var lift := Vector3(0.0, PlacedMoverLight.BASE_H + PlacedMoverLight.YOKE_H, 0.0)
				var head := layer.position_of(rec) + LightGizmoMath.basis_of(layer.rotation_of(rec)) * lift
				var pt := MoverProgram.aim_angles(layer.rotation_of(rec), head, target)
				PlacedLightService.set_field(_main, [id], "pan_center", snappedf(pt.x, 0.1), false)
				PlacedLightService.set_field(_main, [id], "tilt_center", snappedf(pt.y, 0.1), false)
				n += 1
	PlacedLightService.commit(_main)
	_hint_text("Aimed %d light%s" % [n, "" if n == 1 else "s"] if n > 0 else "Select spots or movers first")


func _string_click(mb: InputEventMouseButton) -> void:
	var r := _ray(mb.position)
	var now := Time.get_ticks_msec()
	# Double-click the LAST pin ends the string.
	if not _string_pts.is_empty():
		var last: Vector3 = _string_pts[_string_pts.size() - 1]
		var rp := LightGizmoMath.ray_point(r["o"], r["d"], last)
		if float(rp["dist"]) <= LightGizmoMath.pick_radius(0.3, float(rp["t"])):
			if mb.double_click or now - _last_pin_click_ms <= DOUBLE_CLICK_MS:
				_finish_string()
			else:
				_hint_text("Double-click this pin to finish the string")
			_last_pin_click_ms = now
			return
	var aim := _surface(mb.position)
	if not bool(aim.get("valid", false)):
		return
	if _string_pts.size() >= PlacedLightLayer.MAX_WAYPOINTS_PER_STRING:
		_hint_text("Maximum %d pins — double-click the last one to finish" % PlacedLightLayer.MAX_WAYPOINTS_PER_STRING)
		return
	_string_pts.append(aim["position"])
	_last_pin_click_ms = now
	_redraw_string_preview(mb.position)
	_hint_text("%d pin%s · double-click the last pin (or Enter) to finish" % [
		_string_pts.size(), "" if _string_pts.size() == 1 else "s"])


func _finish_string() -> void:
	if _string_pts.size() < 2:
		_hint_text("A string needs at least two pins")
		return
	PlacedLightService.checkpoint(_main)
	var id := PlacedLightService.add_string(_main, _string_pts.duplicate())
	_string_pts.clear()
	_redraw_string_preview(Vector2(-1, -1))
	if id.is_empty():
		_hint_text("Light or pin limit reached")
		return
	PlacedLightService.set_selection(_main, [id])
	PlacedLightService.commit(_main)
	_hint_text("String placed — tune it on the right, or keep clicking to start another")


func _cancel_string() -> void:
	_string_pts.clear()
	_redraw_string_preview(Vector2(-1, -1))


func _redraw_string_preview(mouse: Vector2) -> void:
	if _string_preview_mesh == null:
		return
	_string_preview_mesh.clear_surfaces()
	if _string_pts.is_empty():
		return
	var pts: Array = _string_pts.duplicate()
	if mouse.x >= 0.0:
		var aim := _surface(mouse)
		if bool(aim.get("valid", false)):
			pts.append(aim["position"])
	var layer := _layer()
	var fields := PlacedLightStyles.defaults("string")
	var sid := str(PlacedLightService.active_style.get("string", ""))
	if layer != null and layer.styles.has(sid):
		fields = PlacedLightStyles.resolve("string", layer.styles[sid].get("fields", {}), {})
	var geo := LightStringGeometry.build(pts, fields)
	var samples: PackedVector3Array = geo["samples"]
	_string_preview_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(1, samples.size()):
		_string_preview_mesh.surface_add_vertex(samples[i - 1])
		_string_preview_mesh.surface_add_vertex(samples[i])
	# Pin crosses.
	for p in _string_pts:
		var v: Vector3 = p
		for ax in [Vector3(0.2, 0, 0), Vector3(0, 0.2, 0), Vector3(0, 0, 0.2)]:
			_string_preview_mesh.surface_add_vertex(v - ax)
			_string_preview_mesh.surface_add_vertex(v + ax)
	_string_preview_mesh.surface_end()


func _draw_overlay() -> void:
	if _dragging == "box" and _drag.has("from"):
		var rect := Rect2(_drag["from"], Vector2.ZERO).expand(_drag.get("to", _drag["from"]))
		_overlay.draw_rect(rect, Color(1.0, 0.85, 0.3, 0.12), true)
		_overlay.draw_rect(rect, Color(1.0, 0.85, 0.3, 0.8), false, 1.5)
