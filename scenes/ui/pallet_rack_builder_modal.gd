extends Control

## Parametric Mars-College pallet-rack structure builder with a SubViewport studio
## preview. Drives PalletRackBuilder from catalog dropdowns, layout sliders, level
## / deck / variant / wall controls, and places the result via PlacedPropService
## as model_id "pallet_rack" + rack_spec extras.
##
## Design elements (doors, sliding doors, windows, stairs, solar / greenhouse
## slopes, railings, courtyards) are placed with the "Add to the structure"
## tools: arm one, hover the preview (a cyan ghost shows where it lands), click.
## Clicking a placed element selects it; the "Selected" card edits it, drags
## slide doors / windows / stairs along their wall, Ctrl+D duplicates, Del
## removes. Whole designs and single elements save to a library that every
## rack can reuse (PalletRackBuilder.LIBRARY_PATH).
##
## Selection is NESTED, as in SketchUp: a click selects at the open level
## (at the top: a deck level, the uprights, a wall, an element); a double-click
## opens what it hits, fading the rest, so its bays and then its single pieces
## (plywood sheets, joists, beams, solar modules, rail runs) become clickable.
## Esc, a click outside, or the breadcrumb over the preview steps back out.
## Shift / Ctrl-click adds to the selection at the same level. The card edits
## whatever is selected; a piece's colour or hidden state is stored in
## spec["part_overrides"] under its part id (PalletRackBuilder.part_tree).
##
## DRAGGING moves things: a deck bay to another bay (Alt-drag raises it
## instead), a door / window / stairs along its wall and round the corner, a
## slope or a face-side stepped module along its face and onto another face,
## a bay-stepped module or a courtyard to another cell, a slope's bay onto
## another bay (their coverings swap). A whole deck level and beams still
## rise and fall.
##
## The design PERSISTS: closing keeps a draft (user://pallet_rack_draft.json)
## that the next open restores — one for a new rack, one per placed rack
## (dropped once applied, or when the placed rack changed meanwhile). "New" /
## "Revert" starts over.
##
## FUSED racks: a placed rack whose uprights meet another's can be joined
## into one build (PalletRackBuilder.fuse_transform / fuse_specs); the build
## keeps each rack's own spec, the picker chooses which one the editor works
## on (the others draw faded), "Split off" takes one out again.

const MODAL_NAME := "pallet_rack_builder"
const REBUILD_DEBOUNCE_S := 0.10
const DRAFT_PATH := "user://pallet_rack_draft.json"
const DRAFT_SAVE_MS := 1500
const DRAFT_MAX_PROPS := 30

const C_BG := Color(0.039, 0.055, 0.098, 0.85)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S := Color(0.580, 0.639, 0.722, 1.0)

var _loader: Node = null
var _active := false
var _spec: Dictionary = {}

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _camera: Camera3D = null

var _depth_opt: OptionButton = null
var _height_opt: OptionButton = null
var _beam_opt: OptionButton = null
var _bay_slider: HSlider = null
var _bay_val: Label = null
var _col_slider: HSlider = null
var _col_val: Label = null
var _spacing_slider: HSlider = null
var _spacing_val: Label = null
var _levels_spin: SpinBox = null
var _level_box: VBoxContainer = null
var _level_spins: Array = []
var _roof_chk: CheckBox = null
var _decked_chk: CheckBox = null
var _lumber_opt: OptionButton = null
var _joist_opt: OptionButton = null
var _u_chk: CheckBox = null
var _u_row: HBoxContainer = null
var _u_bays_spin: SpinBox = null
var _u_cols_spin: SpinBox = null
var _wall_chks: Dictionary = {}
var _wall_bottom_spin: SpinBox = null
var _wall_top_spin: SpinBox = null
var _collide_chk: CheckBox = null

# ---- Fused racks + the draft ----
## The racks of the build: [{spec, xf}] (xf in rack 0's frame). _spec is the
## one being edited (_active_mod); its entry here is stale until switched away.
var _modules: Array = []
var _active_mod := 0
var _mod_box: VBoxContainer = null
var _fuse_box: VBoxContainer = null
## "Build it with a crew": the plan (PalletRackBuildPlan) and the rehearsal
## on the placed rack (PalletRackBuildSite).
var _crew_box: VBoxContainer = null
var _crew_spin: SpinBox = null
var _crew_lbl: Label = null
## Bound prop: a signature of its record's spec when the editor opened, so a
## draft is only restored over the same record.
var _base_sig := ""
var _last_draft_ms := 0
var _new_btn: Button = null
## Set by Apply / Delete: the close that follows keeps no draft.
var _draft_done := false

# ---- Design elements ----
## The armed placement tool: "" none, "step" the step dropper, else a
## TOOL_PRESETS id or "lib:<n>" (a saved element preset).
var _tool := ""
var _tool_element: Dictionary = {}
var _tool_btns: Dictionary = {}
## Ghost pick boxes of the element the armed tool would place.
var _ghost_comps: Array = []
var _insp_frame: PanelContainer = null
var _insp_box: VBoxContainer = null
var _insp_el_id := ""
var _insp_seg := -1
var _insp_fields: Dictionary = {}
var _insp_suppress := false
var _last_field_undo_ms := 0
var _el_list_box: VBoxContainer = null
var _el_list_sig := ""
var _design_opt: OptionButton = null
var _design_name: LineEdit = null
var _el_preset_opt: OptionButton = null
var _library: Dictionary = {}
var _status_lbl: Label = null
## Element to select once the rebuild that adds it lands (its pick ids exist then).
var _pending_select := ""
var _bom_lbl: Label = null
var _title_lbl: Label = null
var _place_btn: Button = null
var _apply_btn: Button = null
var _delete_btn: Button = null

## Non-empty while editing a placed rack in place ("Apply changes" rebuilds it).
var _bound_prop_id := ""
var _space_row: NpcSpaceTagRow

var _rebuild_pending := false
var _rebuild_timer := 0.0
## Light rebuild = geometry + highlight only (no UI re-read/BOM), used mid-drag
## so the preview glides at frame rate instead of stepping on the debounce.
var _rebuild_light := false
var _suppress := false
## Frame the camera to the structure only on the first build after opening — not
## on every edit, so the user's orbit/zoom is preserved while tweaking params.
var _framed := false

# Orbit camera state (RMB-drag).
## Opens on the front-right three-quarter (the camera on -Z, +X): "front" is
## the -Z face, where slopes and doors are placed by default.
var _yaw := PI - 0.75
var _pitch := 0.5
var _dist := 12.0
var _target := Vector3(0, 2.0, 0)
var _dragging := false

# ---- Per-component editor state ----
## Small dead-zone so a click reads as a select, a nudge reads as a drag.
const DRAG_THRESHOLD_PX := 1.5
const MANIP_KINDS := ["deck", "step", "beam", "wall_sheet", "element"]
## Elements that slide along their wall when dragged.
const SLIDE_TYPES := ["door", "window", "stair"]
## Elements a drag moves (railings follow their deck and stay put).
const DRAG_TYPES := ["door", "window", "stair", "lean_to", "stepped", "courtyard"]
## Fraction of the deck's far Z edge that counts as the resize grab band.
const RESIZE_EDGE_FRAC := 0.28
const UNDO_LIMIT := 40

var _sel_hud: Label = null
var _undo_btn: Button = null
var _steps_btn: Button = null
var _highlight_holder: Node3D = null
## Pick registry for the currently-built spec (refreshed on every rebuild).
var _pick_cache: Array = []
var _comp_index: Dictionary = {}
## Hover in the tool / step modes (component or slot ids).
var _hover_group: Array = []
## The editable components under the selected parts (cell / beam / wall /
## element ids) — what drags, Del and the element card act on. Derived from
## _sel_nodes by _derive_selection.
var _selection: Array = []
## The part tree of the current build (PalletRackBuilder.part_tree).
var _tree: Dictionary = {}
## The open group: part ids from the top down, [] = the whole rack.
var _ctx: Array = []
## Selected part ids, all children of the open group.
var _sel_nodes: Array = []
var _hover_node := ""
## The press of a double-click: its release must not select again.
var _press_double := false
var _crumb_row: HBoxContainer = null
var _crumb_hint: Label = null
var _show_hidden_btn: Button = null
var _parts_sig := ""
## Undo history of override snapshots (cell/beam/wall).
var _undo_stack: Array = []
## When true, LMB drops a step section on the cell slot under the cursor.
var _place_step_mode := false

# LMB gesture state.
var _lmb_down := false
var _lmb_press_pos := Vector2.ZERO
var _press_shift := false
var _manip_active := false
var _manip_mode := ""          # "deck_move" | "deck_resize" | "beam_move"
var _manip_targets: Array = []  # component ids being moved together
var _manip_start: Dictionary = {}  # id -> starting values
## The parts being dragged (their cells / beams are _manip_targets).
var _manip_nodes: Array = []


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_load_full(PalletRackBuilder.default_spec())
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open() -> void:
	if _active:
		return
	_bound_prop_id = ""
	_base_sig = ""
	# The rack being designed when the editor last closed comes back.
	var fresh: Variant = _load_draft().get("fresh")
	var restored := false
	if fresh is Dictionary and (fresh as Dictionary).get("spec") is Dictionary:
		_load_full((fresh as Dictionary)["spec"], int((fresh as Dictionary).get("module", 0)))
		restored = true
	else:
		_load_full(PalletRackBuilder.default_spec())
	# Nothing placed yet, so there is no target to tag.
	if _space_row != null:
		_space_row.bind_prop(_loader, "")
	_sync_controls()
	_apply_edit_mode_ui()
	_activate()
	if restored:
		_restore_camera(fresh as Dictionary)


## Edit an already-placed pallet rack in place. "Apply changes" rebuilds that
## prop from the edited spec; "Place in world" stays available for a fresh copy.
func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("rack_spec", {}) as Dictionary
	if spec.is_empty() and rec.has("record_extra"):
		spec = (rec.get("record_extra", {}) as Dictionary).get("rack_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_base_sig = _spec_sig(spec)
	# Unapplied edits from last time, if the placed rack has not changed since.
	var draft: Variant = (_load_draft().get("props", {}) as Dictionary).get(prop_id)
	var restored := false
	if draft is Dictionary and str((draft as Dictionary).get("base", "")) == _base_sig \
			and (draft as Dictionary).get("spec") is Dictionary:
		_load_full((draft as Dictionary)["spec"], int((draft as Dictionary).get("module", 0)))
		restored = true
	else:
		_load_full(spec)
	if _space_row != null:
		_space_row.bind_prop(_loader, prop_id)
	_sync_controls()
	_apply_edit_mode_ui()
	_activate()
	if restored:
		_restore_camera(draft as Dictionary)
		_flash("Your unapplied changes are back — Revert drops them.")


func _activate() -> void:
	_framed = false
	_selection.clear()
	_sel_nodes.clear()
	_ctx.clear()
	_hover_node = ""
	_hover_group.clear()
	_undo_stack.clear()
	_place_step_mode = false
	_tool = ""
	_tool_element = {}
	_ghost_comps = []
	_sync_tool_buttons()
	_library = PalletRackBuilder.load_library()
	_refresh_design_list()
	_refresh_element_presets()
	_reset_gesture()
	_refresh_module_ui()
	_refresh_crew_ui()
	_clear_fuse_list()
	_draft_done = false
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	_queue_rebuild(true)


func _apply_edit_mode_ui() -> void:
	var editing := not _bound_prop_id.is_empty()
	if _title_lbl != null:
		_title_lbl.text = "Edit Pallet Rack" if editing else "Pallet Rack Structure Builder"
	if _apply_btn != null:
		_apply_btn.visible = editing
	if _delete_btn != null:
		_delete_btn.visible = editing
	if _new_btn != null:
		_new_btn.text = "Revert" if editing else "New"
		_new_btn.tooltip_text = "Back to the placed rack as it is (Ctrl+Z goes back)" if editing \
			else "Start a new rack from scratch (Ctrl+Z goes back)"


func close() -> void:
	if not _active:
		return
	if not _draft_done:
		_save_draft()
	_active = false
	_bound_prop_id = ""
	_set_tool("")
	_undo_stack.clear()
	_update_undo_btn()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _process(delta: float) -> void:
	if not _rebuild_pending:
		return
	_rebuild_timer -= delta
	if _rebuild_timer <= 0.0:
		_rebuild_pending = false
		var light := _rebuild_light
		_rebuild_light = false
		_rebuild_preview(light)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Full-screen modal (mirrors the Linkage Lab layout): dim backdrop, a top bar
	# with the title + primary actions, then a large 3D viewport beside a scrollable
	# parameter sidebar.
	_dim = ColorRect.new()
	_dim.color = C_BG
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	root.add_child(_build_topbar())

	var main_row := HBoxContainer.new()
	main_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_theme_constant_override("separation", 8)
	root.add_child(main_row)

	var vp_frame := PanelContainer.new()
	vp_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_frame.add_theme_stylebox_override("panel", _card_style())
	main_row.add_child(vp_frame)
	var vp_col := VBoxContainer.new()
	vp_col.add_theme_constant_override("separation", 6)
	vp_frame.add_child(vp_col)
	vp_col.add_child(_build_crumb_bar())
	_vp_container = SubViewportContainer.new()
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.stretch = true
	_vp_container.gui_input.connect(_on_viewport_input)
	vp_col.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 720)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_viewport.own_world_3d = true
	_vp_container.add_child(_viewport)
	_build_studio_world()

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var side_frame := PanelContainer.new()
	side_frame.add_theme_stylebox_override("panel", _card_style())
	side_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_child(side_frame)
	side_frame.add_child(scroll)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.custom_minimum_size.x = 300
	side.add_theme_constant_override("separation", 6)
	scroll.add_child(side)

	_build_element_ui(side)

	_section(side, "Rack system")
	_depth_opt = _add_option(side, "Upright depth", PalletRackBuilder.DEPTH_OPTIONS_IN,
		"\"", int(_spec["upright_depth_in"]))
	_height_opt = _add_option(side, "Upright height", PalletRackBuilder.HEIGHT_OPTIONS_FT,
		"'", int(_spec["upright_height_ft"]))
	_beam_opt = _add_option(side, "Beam span", PalletRackBuilder.BEAM_OPTIONS_FT,
		"'", int(_spec["beam_span_ft"]))

	_section(side, "Layout")
	var bay_pack := _add_slider(side, "Bays across", 1, 10, int(_spec["bay_count"]))
	_bay_slider = bay_pack[0]
	_bay_val = bay_pack[1]
	var col_pack := _add_slider(side, "Columns (decked spans)", 1, 10, int(_spec["column_count"]))
	_col_slider = col_pack[0]
	_col_val = col_pack[1]
	var gap_pack := _add_float_slider(side, "Assembly spacing", PalletRackBuilder.ROW_GAP_MIN_FT, 20.0,
		PalletRackBuilder.ROW_GAP_STEP_FT, float(_spec["row_gap_ft"]), "'")
	_spacing_slider = gap_pack[0]
	_spacing_val = gap_pack[1]
	_spacing_slider.tooltip_text = "Clear space between rack rows. 4', 8', 12' and so on tile the plywood with no cut sheets."

	_section(side, "Levels")
	_levels_spin = _add_spin(side, "Deck levels", 1, 3, 1, float(_spec["deck_levels"]))
	_levels_spin.value_changed.connect(func(_v: float) -> void: _rebuild_level_spins())
	_level_box = VBoxContainer.new()
	_level_box.add_theme_constant_override("separation", 4)
	side.add_child(_level_box)
	_roof_chk = _add_check(side, "Rooftop deck", bool(_spec["roof_deck"]))

	_section(side, "Decking")
	_decked_chk = _add_check(side, "Deck the columns (2x4 + plywood)", bool(_spec["decked"]))
	_lumber_opt = _add_option(side, "Joist stock length", PalletRackBuilder.LUMBER_OPTIONS_FT,
		"'", int(_spec["lumber_len_ft"]))
	_joist_opt = _add_option(side, "Joist spacing", PalletRackBuilder.JOIST_SPACING_OPTIONS_IN,
		"\" o.c.", int(_spec["joist_spacing_in"]))

	_section(side, "Variants")
	side.add_child(_small_label("Stepped modules are in Add to the structure — place them in a bay or on a face."))
	_u_chk = _add_check(side, "U-shape (open centre bay)", bool(_spec["u_shape"]))
	_u_row = HBoxContainer.new()
	_u_row.add_theme_constant_override("separation", 8)
	side.add_child(_u_row)
	var ub := VBoxContainer.new()
	ub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_u_row.add_child(ub)
	_u_bays_spin = _add_spin(ub, "Open bays", 1, 10, 1, float(_spec["u_open_bays"]))
	var uc := VBoxContainer.new()
	uc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_u_row.add_child(uc)
	_u_cols_spin = _add_spin(uc, "Open cols", 1, 10, 1, float(_spec["u_open_cols"]))

	_section(side, "Joined racks")
	_mod_box = VBoxContainer.new()
	_mod_box.add_theme_constant_override("separation", 4)
	side.add_child(_mod_box)
	_fuse_box = VBoxContainer.new()
	_fuse_box.add_theme_constant_override("separation", 2)
	side.add_child(_fuse_box)

	_section(side, "Placement")
	_collide_chk = _add_check(side, "Solid collision (walk into it when off)", true)

	_section(side, "Walls (4x8 plywood)")
	var wall_row := GridContainer.new()
	wall_row.columns = 2
	side.add_child(wall_row)
	for face in ["front", "back", "left", "right"]:
		_wall_chks[face] = _add_check(wall_row, face.capitalize(),
			bool((_spec["walls"] as Dictionary).get(face, false)))
	var band_row := HBoxContainer.new()
	band_row.add_theme_constant_override("separation", 8)
	side.add_child(band_row)
	var bb := VBoxContainer.new()
	bb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	band_row.add_child(bb)
	_wall_bottom_spin = _add_spin(bb, "Walls from (ft)", 0.0, 20.0, 0.25, 0.0)
	var bt := VBoxContainer.new()
	bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	band_row.add_child(bt)
	_wall_top_spin = _add_spin(bt, "up to (ft, 0 = top)", 0.0, 20.0, 0.25, 0.0)
	_wall_top_spin.tooltip_text = "Where the walls stop. 0 runs them to the top of the frame; 8 walls in just the ground floor."

	_section(side, "Build it with a crew")
	_crew_box = VBoxContainer.new()
	_crew_box.add_theme_constant_override("separation", 4)
	side.add_child(_crew_box)

	_section(side, "Bill of materials")
	_bom_lbl = Label.new()
	_bom_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_bom_lbl.add_theme_font_size_override("font_size", 11)
	_bom_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_bom_lbl)

	_rebuild_level_spins()


func _build_topbar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _card_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	bar.add_child(row)

	_title_lbl = Label.new()
	_title_lbl.text = "Pallet Rack Structure Builder"
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_title_lbl.add_theme_font_size_override("font_size", 18)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_title_lbl)

	_sel_hud = Label.new()
	_sel_hud.text = ""
	_sel_hud.add_theme_color_override("font_color", C_PRIMARY)
	_sel_hud.add_theme_font_size_override("font_size", 11)
	_sel_hud.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_sel_hud)

	var hint := Label.new()
	hint.text = "RMB orbit  •  LMB select / drag to move  •  Alt-drag raise  •  Double-click open  •  Shift multi  •  Del remove"
	hint.add_theme_color_override("font_color", C_TEXT_S)
	hint.add_theme_font_size_override("font_size", 11)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(hint)

	# Pallet racks route here rather than to the generic prop drawer, so the tag
	# control has to live in this modal too (see npc_space_tag_row.gd). Only
	# meaningful when editing a placed rack, so it hides itself for a fresh one.
	_space_row = NpcSpaceTagRow.new()
	row.add_child(_space_row)

	_new_btn = Button.new()
	_new_btn.text = "New"
	_new_btn.focus_mode = Control.FOCUS_NONE
	_new_btn.pressed.connect(_on_new_or_revert)
	row.add_child(_new_btn)

	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.focus_mode = Control.FOCUS_NONE
	_undo_btn.disabled = true
	_undo_btn.pressed.connect(_undo)
	row.add_child(_undo_btn)

	_apply_btn = Button.new()
	_apply_btn.text = "Apply changes"
	_apply_btn.focus_mode = Control.FOCUS_NONE
	_apply_btn.add_theme_color_override("font_color", C_PRIMARY)
	_apply_btn.visible = false
	_apply_btn.pressed.connect(_on_apply_to_prop)
	row.add_child(_apply_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.focus_mode = Control.FOCUS_NONE
	_delete_btn.add_theme_color_override("font_color", Color(0.94, 0.45, 0.45))
	_delete_btn.visible = false
	_delete_btn.pressed.connect(_on_delete_prop)
	row.add_child(_delete_btn)

	_place_btn = Button.new()
	_place_btn.text = "Place in world"
	_place_btn.focus_mode = Control.FOCUS_NONE
	_place_btn.add_theme_color_override("font_color", C_PRIMARY)
	_place_btn.pressed.connect(_on_place)
	row.add_child(_place_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	return bar


func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


func _section(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", 12)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 6)
	m.add_child(lbl)
	parent.add_child(m)


func _add_option(parent: Control, label: String, values: Array, suffix: String,
		current: int) -> OptionButton:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.focus_mode = Control.FOCUS_NONE
	for i in values.size():
		var v := int(values[i])
		opt.add_item(str(v) + suffix)
		opt.set_item_metadata(i, v)
		if v == current:
			opt.select(i)
	opt.item_selected.connect(func(_i: int) -> void: _on_control_changed())
	parent.add_child(opt)
	return opt


func _add_slider(parent: Control, label: String, mn: int, mx: int,
		val: int) -> Array:
	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var val_lbl := Label.new()
	val_lbl.text = str(val)
	val_lbl.add_theme_color_override("font_color", C_TEXT)
	val_lbl.add_theme_font_size_override("font_size", 11)
	head.add_child(val_lbl)
	parent.add_child(head)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = 1
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.focus_mode = Control.FOCUS_NONE
	sl.value_changed.connect(func(v: float) -> void:
		val_lbl.text = str(int(v))
		_on_layout_changed())
	parent.add_child(sl)
	return [sl, val_lbl]


func _add_float_slider(parent: Control, label: String, mn: float, mx: float,
		step: float, val: float, suffix: String = "") -> Array:
	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var val_lbl := Label.new()
	val_lbl.text = _fmt_num(val) + suffix
	val_lbl.add_theme_color_override("font_color", C_TEXT)
	val_lbl.add_theme_font_size_override("font_size", 11)
	head.add_child(val_lbl)
	parent.add_child(head)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.focus_mode = Control.FOCUS_NONE
	sl.value_changed.connect(func(v: float) -> void:
		val_lbl.text = _fmt_num(v) + suffix
		_on_control_changed())
	parent.add_child(sl)
	return [sl, val_lbl]


func _add_spin(parent: Control, label: String, mn: float, mx: float,
		step: float, val: float) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = mn
	spin.max_value = mx
	spin.step = step
	spin.value = val
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(_v: float) -> void: _on_control_changed())
	parent.add_child(spin)
	return spin


func _add_check(parent: Control, label: String, on: bool) -> CheckBox:
	var chk := CheckBox.new()
	chk.text = label
	chk.button_pressed = on
	chk.focus_mode = Control.FOCUS_NONE
	chk.add_theme_color_override("font_color", C_TEXT)
	chk.add_theme_font_size_override("font_size", 11)
	chk.toggled.connect(func(_p: bool) -> void: _on_control_changed())
	parent.add_child(chk)
	return chk


func _rebuild_level_spins() -> void:
	if _level_box == null:
		return
	var n := int(_levels_spin.value)
	var prev: Array = []
	for sp in _level_spins:
		prev.append(float((sp as SpinBox).value))
	for c in _level_box.get_children():
		c.queue_free()
	_level_spins.clear()
	var max_h := float(_selected_meta(_height_opt, 16))
	for i in range(n):
		var v: float = prev[i] if i < prev.size() else PalletRackBuilder._default_level_height_ft(i)
		var sp := _add_spin(_level_box, "  Level %d height (ft)" % (i + 1),
			0.25, maxf(max_h - 0.5, 0.25), 0.25, clampf(float(v), 0.25, max_h))
		_level_spins.append(sp)
	_on_control_changed()


func _on_layout_changed() -> void:
	# Keep dependent control ranges in sync with bay/column counts.
	if _u_bays_spin:
		_u_bays_spin.max_value = _bay_slider.value
	if _u_cols_spin:
		_u_cols_spin.max_value = _col_slider.value
	_on_control_changed()


func _on_control_changed() -> void:
	if _suppress:
		return
	if _u_row:
		_u_row.visible = _u_chk.button_pressed
	_queue_rebuild(false)


func _on_viewport_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			# RMB is ALWAYS the camera orbit — it never manipulates geometry.
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(3.0, _dist - 1.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(80.0, _dist + 1.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if _place_step_mode:
				if mb.pressed:
					_place_step_at(mb.position)
			elif not _tool.is_empty():
				if mb.pressed:
					_tool_click(mb.position, mb.shift_pressed)
			elif mb.pressed and mb.double_click:
				_press_double = true
				_reset_gesture()
				_double_click(mb.position)
			elif mb.pressed:
				_press_double = false
				_begin_gesture(mb.position, mb.shift_pressed or mb.ctrl_pressed, mb.alt_pressed)
			elif _press_double:
				_press_double = false
			else:
				_end_gesture(mb.position)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _dragging:
			_yaw -= mm.relative.x * 0.01
			_pitch = clampf(_pitch - mm.relative.y * 0.01, 0.05, 1.4)
			_update_camera()
		elif _place_step_mode:
			_update_step_ghost(mm.position)
		elif not _tool.is_empty():
			_update_tool_ghost(mm.position)
		elif _lmb_down and not _manip_mode.is_empty():
			_update_manip(mm.position)
		else:
			_update_hover(mm.position)


## Keyboard shortcuts. Uses _input (not _unhandled_key_input) so the modal
## reliably receives Delete/Ctrl+Z even when a sidebar control had focus, but
## skips while a text field is being edited.
func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if ke.keycode == KEY_Z and ke.ctrl_pressed:
		_undo()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_DELETE or ke.keycode == KEY_BACKSPACE:
		_delete_selection()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_D and ke.ctrl_pressed:
		_duplicate_selected_element()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_S and not ke.ctrl_pressed:
		_toggle_step_on_selection()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_ESCAPE:
		# Esc backs out one layer at a time: tool → open group (one level, the
		# group it leaves selected) → selection → (modal close).
		if not _tool.is_empty():
			_set_tool("")
			get_viewport().set_input_as_handled()
		elif not _ctx.is_empty():
			_step_out()
			get_viewport().set_input_as_handled()
		elif not _sel_nodes.is_empty() or not _selection.is_empty():
			_set_selection([])
			get_viewport().set_input_as_handled()


## Flip the selected deck cells between a flat deck and a step section (a step
## rises from the level below). Applies to every selected cell.
func _toggle_step_on_selection() -> void:
	var el := _element_by_id(_selected_element_id())
	if not el.is_empty() and str(el.get("type", "")) == "stepped":
		_remove_element(str(el["id"]))
		return
	var cells: Array = []
	for id in _sel_subtree():
		if str(id).begins_with("cell:"):
			cells.append(_id_key(str(id)))
	if cells.is_empty():
		return
	_push_undo()
	var claims: Dictionary = _spec.get("_stepped_cells", {})
	var all_stepped := true
	for k in cells:
		if not claims.has(k):
			all_stepped = false
	_set_cells_stepped(cells, not all_stepped)
	_queue_rebuild(true)


## Turn deck cells ("b,c,li" keys) into bay-mode stepped modules, or back.
func _set_cells_stepped(keys: Array, on: bool) -> void:
	var claims: Dictionary = _spec.get("_stepped_cells", {})
	var els: Array = _spec.get("elements", [])
	if on:
		for k in keys:
			if claims.has(k):
				continue
			var bits := str(k).split(",")
			_erase_cell_field(str(k), "kind")
			var rec := PalletRackBuilder.make_element("stepped", {"mode": "bay",
				"bay": int(bits[0]), "col": int(bits[1]), "level": int(bits[2])})
			rec["id"] = _next_element_id()
			els.append(rec)
			claims[k] = rec["id"]
	else:
		var gone := {}
		for k in keys:
			if claims.has(k):
				gone[str(claims[k])] = true
		var kept: Array = []
		for e in els:
			if not gone.has(str((e as Dictionary).get("id", ""))):
				kept.append(e)
		els = kept
	_spec["elements"] = els
	_spec["_stepped_cells"] = claims


# ---------------------------------------------------------------------------
# Ray picking (pure math against the pick registry — no physics)
# ---------------------------------------------------------------------------

## Map a click in the SubViewportContainer's local space into the SubViewport's
## pixel space so Camera3D.project_ray_* aims where the user actually clicked.
func _to_viewport_pos(local_pos: Vector2) -> Vector2:
	if _vp_container == null or _viewport == null:
		return local_pos
	var cont := _vp_container.size
	if cont.x <= 0.0 or cont.y <= 0.0:
		return local_pos
	return local_pos * (Vector2(_viewport.size) / cont)


func _pick_at(local_pos: Vector2, kinds: Array = []) -> Dictionary:
	if _camera == null:
		return {}
	var vp := _to_viewport_pos(local_pos)
	var origin := _camera.project_ray_origin(vp)
	var dir := _camera.project_ray_normal(vp)
	return PalletRackBuilder.pick_nearest(_pick_cache, origin, dir, kinds)


## World Z where the camera ray through `local_pos` crosses the plane y=plane_y.
func _ray_plane_z(local_pos: Vector2, plane_y: float) -> float:
	if _camera == null:
		return NAN
	var vp := _to_viewport_pos(local_pos)
	var o := _camera.project_ray_origin(vp)
	var d := _camera.project_ray_normal(vp)
	if absf(d.y) < 1e-6:
		return NAN
	var t := (plane_y - o.y) / d.y
	if t < 0.0:
		return NAN
	return (o + d * t).z


func _comp_by_id(id: String) -> Dictionary:
	return _comp_index.get(id, {}) as Dictionary


# ---------------------------------------------------------------------------
# Nested selection (the part tree)
# ---------------------------------------------------------------------------

## The part under the cursor resolved to a child of the open group:
## {node, leaf, t, any} (PalletRackBuilder.pick_part).
func _pick_node(local_pos: Vector2) -> Dictionary:
	var r := _ray(local_pos)
	if r.is_empty() or _tree.is_empty():
		return {}
	return PalletRackBuilder.pick_part(_tree, r[0], r[1], _ctx)


func _tree_nodes() -> Dictionary:
	return _tree.get("nodes", {}) as Dictionary


func _node_label(id: String) -> String:
	var n: Variant = _tree_nodes().get(id)
	return str((n as Dictionary).get("label", id)) if n is Dictionary else id


func _node_has_children(id: String) -> bool:
	var n: Variant = _tree_nodes().get(id)
	return n is Dictionary and not ((n as Dictionary).get("children", []) as Array).is_empty()


## Every part id under the selected parts (themselves included).
func _sel_subtree() -> Array:
	var out: Array = []
	var seen := {}
	for n in _sel_nodes:
		for id in PalletRackBuilder.part_subtree(_tree, str(n)):
			if not seen.has(id):
				seen[id] = true
				out.append(id)
	return out


## The editable components under the selected parts.
func _derive_selection() -> void:
	var out: Array = []
	for id in _sel_subtree():
		if _comp_index.has(id):
			out.append(id)
	_selection = out


func _set_selection(nodes: Array) -> void:
	_sel_nodes = nodes.duplicate()
	_derive_selection()
	_refresh_highlight()
	_update_sel_hud()
	_refresh_inspector()
	_refresh_element_list()


## Open the group at `path` (part ids from the top, [] = the whole rack) with
## `select` selected inside it. Rebuilds: the rest of the rack draws faded.
func _set_ctx(path: Array, select: Array = []) -> void:
	_ctx = path.duplicate()
	_hover_node = ""
	_set_selection(select)
	_refresh_crumbs()
	_queue_rebuild(true)


## One level out; the group just closed stays selected (one more Esc clears).
func _step_out() -> void:
	if _ctx.is_empty():
		_set_selection([])
		return
	var left := str(_ctx[-1])
	_set_ctx(_ctx.slice(0, _ctx.size() - 1), [left])


## Open the group under the cursor; a single piece is just selected.
func _double_click(local_pos: Vector2) -> void:
	var hit := _pick_node(local_pos)
	var node := str(hit.get("node", ""))
	if node.is_empty():
		if not _ctx.is_empty():
			_step_out()
		return
	if _node_has_children(node):
		_set_ctx(_ctx + [node], [])
	else:
		_set_selection([node])


func _update_hover(local_pos: Vector2) -> void:
	var comp := _pick_at(local_pos, MANIP_KINDS)
	var hit := _pick_node(local_pos)
	var node := str(hit.get("node", ""))
	# Cursor hint: resize arrows over a deck's far edge, move arrows over a
	# draggable body, default arrow over nothing.
	if _vp_container != null:
		var shape := Control.CURSOR_ARROW
		if not node.is_empty():
			var nk := PalletRackBuilder.part_kind(node)
			var k := str(comp.get("kind", ""))
			if (k == "deck" or k == "step") and ["deck_level", "strip", "cell"].has(nk) \
					and _near_cell_z_edge(comp, local_pos):
				shape = Control.CURSOR_BDIAGSIZE
			elif ["deck_level", "strip", "cell", "beam"].has(nk):
				shape = Control.CURSOR_MOVE
			elif nk == "element" and DRAG_TYPES.has(str(comp.get("etype", ""))):
				shape = Control.CURSOR_MOVE
			elif nk == "slope_bay":
				shape = Control.CURSOR_MOVE
			else:
				shape = Control.CURSOR_POINTING_HAND
		_vp_container.mouse_default_cursor_shape = shape
	if node != _hover_node:
		_hover_node = node
		_refresh_highlight()


## Every pick id that belongs to element `el_id`.
func _element_group(el_id: String) -> Array:
	var ids: Array = []
	for c in _pick_cache:
		if str(c.get("kind", "")) == "element" and str(c.get("el_id", "")) == el_id:
			ids.append(str(c["id"]))
	return ids


# ---------------------------------------------------------------------------
# Gestures: LMB click = select, LMB drag = manipulate
# ---------------------------------------------------------------------------

func _reset_gesture() -> void:
	if _tool.is_empty() and not _ghost_comps.is_empty():
		_ghost_comps = []
		_refresh_highlight()
	_lmb_down = false
	_manip_active = false
	_manip_mode = ""
	_manip_targets = []
	_manip_start = {}
	_manip_nodes = []


func _begin_gesture(local_pos: Vector2, shift: bool, alt: bool = false) -> void:
	_lmb_down = true
	_lmb_press_pos = local_pos
	_press_shift = shift
	_manip_active = false
	_manip_mode = ""
	_manip_targets = []
	_manip_start = {}
	_manip_nodes = []
	var hit := _pick_node(local_pos)
	var node := str(hit.get("node", ""))
	if node.is_empty():
		return
	var nk := PalletRackBuilder.part_kind(node)
	var comp := _pick_at(local_pos, MANIP_KINDS)
	if nk == "element":
		var el := _element_by_id(node.get_slice(":", 1))
		if not el.is_empty():
			_begin_element_drag(node, el, local_pos)
		return
	if nk == "slope_bay":
		var sel_el := _element_by_id(node.get_slice(":", 1))
		if not sel_el.is_empty():
			_manip_mode = "seg_swap"
			_manip_nodes = [node]
			_manip_start = {"el_id": str(sel_el["id"]), "seg": int(node.get_slice(":", 2)), "target": -1}
		return
	# A deck level, a column, a bay or a beam rises and falls as one unit: every
	# cell and beam inside it. Dragging one of several selected parts drags all.
	_manip_nodes = _sel_nodes.duplicate() if (_sel_nodes.has(node) and _sel_nodes.size() > 1) \
		else [node]
	var cells: Array = []
	var beams: Array = []
	for n in _manip_nodes:
		for id in PalletRackBuilder.part_subtree(_tree, str(n)):
			if not _comp_index.has(id):
				continue
			if str(id).begins_with("cell:"):
				cells.append(id)
			elif str(id).begins_with("beam:"):
				beams.append(id)
	if cells.is_empty() and beams.is_empty():
		_manip_nodes = []
		return  # a sheet, a joist, a wall: click select / delete only, no drag
	# A bay (or several) moves to another bay; Alt-drag raises it instead.
	var all_cells := true
	for n in _manip_nodes:
		if PalletRackBuilder.part_kind(str(n)) != "cell":
			all_cells = false
	if all_cells and not alt and not cells.is_empty():
		var anchor := str(comp.get("id", "")) if cells.has(str(comp.get("id", ""))) else str(cells[0])
		var abox: AABB = (_comp_by_id(anchor))["aabb"]
		var slot_index := {}
		for sl in PalletRackBuilder.cell_slots(_spec):
			slot_index[str(sl["id"])] = sl
		_manip_mode = "cell_move"
		_manip_targets = cells
		_manip_start = {"anchor": _id_key(anchor), "plane_y": abox.position.y + abox.size.y,
			"delta": Vector2i.ZERO, "slots": slot_index}
		return
	var k := str(comp.get("kind", ""))
	if (k == "deck" or k == "step") and cells.has(str(comp.get("id", ""))) \
			and _near_cell_z_edge(comp, local_pos):
		_manip_mode = "deck_resize"
		_manip_targets = cells
	elif cells.is_empty():
		_manip_mode = "beam_move"
		_manip_targets = beams
	else:
		_manip_mode = "deck_move"
		_manip_targets = cells + beams
	_capture_manip_start()


func _end_gesture(local_pos: Vector2) -> void:
	if _manip_active:
		_finalize_manip()
	else:
		_click_select(local_pos)
	_reset_gesture()


func _click_select(local_pos: Vector2) -> void:
	var hit := _pick_node(local_pos)
	var node := str(hit.get("node", ""))
	if node.is_empty():
		# A click outside the open group (on the faded rack or on nothing)
		# closes it; at the top it clears the selection.
		if not _ctx.is_empty() and not _press_shift:
			_step_out()
		elif not _press_shift:
			_set_selection([])
		return
	if _press_shift:
		var sel := _sel_nodes.duplicate()
		if sel.has(node):
			sel.erase(node)
		else:
			sel.append(node)
		_set_selection(sel)
	else:
		_set_selection([node])


## True when the click sits in the far-Z grab band of a deck cell (edge resize).
func _near_cell_z_edge(comp: Dictionary, local_pos: Vector2) -> bool:
	var z0 := float(comp.get("z0", 0.0))
	var z1 := float(comp.get("z1", 0.0))
	if z1 <= z0:
		return false
	var box: AABB = comp["aabb"]
	var plane_y := box.position.y + box.size.y
	var zw := _ray_plane_z(local_pos, plane_y)
	if is_nan(zw):
		return false
	var band := (z1 - z0) * RESIZE_EDGE_FRAC
	return zw >= z1 - band


func _capture_manip_start() -> void:
	_manip_start = {}
	for id in _manip_targets:
		var comp := _comp_by_id(id)
		if comp.is_empty():
			continue
		if str(id).begins_with("beam:"):
			_manip_start[id] = {"dy_in": float(comp.get("dy_in", 0.0))}
		else:
			var z0 := float(comp.get("z0", 0.0))
			var z1 := float(comp.get("z1", 0.0))
			var full_units := maxi(1, int(round((z1 - z0) / PalletRackBuilder.FT
				/ PalletRackBuilder.HALF_PANEL_FT)))
			var du := int(comp.get("depth_units", -1))
			_manip_start[id] = {
				"height_ft": float(comp.get("height_ft", 0.0)),
				"z0": z0, "full_units": full_units,
				"start_units": du if du >= 0 else full_units,
			}


func _update_manip(local_pos: Vector2) -> void:
	var d := local_pos - _lmb_press_pos
	if not _manip_active:
		if d.length() < DRAG_THRESHOLD_PX:
			return
		_manip_active = true
		_push_undo()  # one undo entry per drag, capturing the pre-drag state
		# Make the moving unit the live selection so it's obvious what's dragging.
		_sel_nodes = _manip_nodes.duplicate()
		_derive_selection()
	match _manip_mode:
		"deck_move", "beam_move":
			_preview_vertical(-d.y)
		"deck_resize":
			_preview_deck_resize(local_pos)
		"cell_move":
			_preview_cell_move(local_pos)
			return
		"el_bays":
			_preview_el_bays(local_pos)
			return
		"el_cell":
			_preview_el_cell(local_pos)
			return
		"seg_swap":
			_preview_seg_swap(local_pos)
			return
		"el_slide":
			var el := _element_by_id(str(_manip_start["el_id"]))
			if el.is_empty():
				return
			# Round the corner: a ray that meets another face takes it there.
			var r := _ray(local_pos)
			var fh := PalletRackBuilder.face_hit(_spec, r[0], r[1]) if not r.is_empty() else {}
			if not fh.is_empty() and str(fh["face"]) != str(el.get("face", "")):
				el["face"] = str(fh["face"])
				_manip_start["face"] = str(fh["face"])
				_manip_start["grab_ft"] = 0.0
				el["at_ft"] = snappedf(float(fh["along_ft"]), 0.5)
			else:
				var along := _ray_face_along(local_pos, str(_manip_start.get("face", "")))
				if not is_nan(along):
					el["at_ft"] = snappedf(along - float(_manip_start["grab_ft"]), 0.5)
			_sel_hud.text = "%s at %s along the %s face  (snaps to 6\" • drag round a corner to change face)" % [
				PalletRackBuilder.ELEMENT_LABELS.get(str(el.get("type", "")), "Element"),
				PalletRackBuilder.fmt_ft(float(el["at_ft"])), str(el.get("face", ""))]
			_queue_rebuild(true, true)
			return
	_update_manip_hud()
	_queue_rebuild(true, true)  # immediate + light → glides at frame rate


## Live readout of the value being dragged (before the release snap).
func _update_manip_hud() -> void:
	if _sel_hud == null or _manip_targets.is_empty():
		return
	var id := str(_manip_targets[0])
	var key := _id_key(id)
	match _manip_mode:
		"deck_move":
			var cov: Dictionary = _spec.get("cell_overrides", {})
			var h := float((cov.get(key, {}) as Dictionary).get("height_ft", 0.0))
			_sel_hud.text = "Deck height: %s  (snaps to 1\" on release)" % _fmt_ft_in(h)
		"beam_move":
			var bov: Dictionary = _spec.get("beam_overrides", {})
			var dy := float((bov.get(key, {}) as Dictionary).get("dy_in", 0.0))
			_sel_hud.text = "Beam offset: %+.1f\"  (snaps to 1\" on release)" % dy
		"deck_resize":
			var cov2: Dictionary = _spec.get("cell_overrides", {})
			var du := int((cov2.get(key, {}) as Dictionary).get("depth_units", 0))
			var depth_ft := du * PalletRackBuilder.HALF_PANEL_FT if du > 0 \
				else _strip_full_depth_ft(id)
			_sel_hud.text = "Deck depth: %d ft" % int(round(depth_ft))


## Feet → e.g. "8' 3\"" using whole inches.
func _fmt_ft_in(ft: float) -> String:
	var total_in := int(round(ft * 12.0))
	return "%d' %d\"" % [total_in / 12, total_in % 12]


func _strip_full_depth_ft(id: String) -> float:
	var st: Dictionary = _manip_start.get(id, {})
	return float(st.get("full_units", 0)) * PalletRackBuilder.HALF_PANEL_FT


## Vertical drag → raise/lower. `px` up-positive; scaled by camera distance so
## the feel is zoom-independent. Applied live (unsnapped); snapped on release.
## Cells move via height_ft, beams via dy_in — by the SAME world delta — so a
## deck strip and its crossbeams rise/lower as one unit.
func _preview_vertical(px: float) -> void:
	var dy_world := px * _dist * 0.0055
	var max_ft := float(_spec["upright_height_ft"])
	for id in _manip_targets:
		var st: Dictionary = _manip_start.get(id, {})
		if st.is_empty():
			continue
		if str(id).begins_with("beam:"):
			_set_beam_override(_id_key(id), "dy_in",
				float(st["dy_in"]) + dy_world / PalletRackBuilder.IN)
		else:
			var h := clampf(float(st["height_ft"]) + dy_world / PalletRackBuilder.FT,
				0.25, max_ft - 0.25)
			_set_cell_override(_id_key(id), "height_ft", h)


func _preview_deck_resize(local_pos: Vector2) -> void:
	for id in _manip_targets:
		var st: Dictionary = _manip_start.get(id, {})
		if st.is_empty():
			continue
		var comp := _comp_by_id(id)
		var plane_y := float(_spec_height_ft_from_start(st)) * PalletRackBuilder.FT \
			+ PalletRackBuilder.JOIST_H
		if not comp.is_empty():
			var box: AABB = comp["aabb"]
			plane_y = box.position.y + box.size.y
		var zw := _ray_plane_z(local_pos, plane_y)
		var full_units := int(st["full_units"])
		var units := full_units
		if not is_nan(zw):
			var z0 := float(st["z0"])
			var span_units := (zw - z0) / PalletRackBuilder.FT / PalletRackBuilder.HALF_PANEL_FT
			units = clampi(int(round(span_units)), 1, full_units)
		if units >= full_units:
			_erase_cell_field(_id_key(id), "depth_units")
		else:
			_set_cell_override(_id_key(id), "depth_units", units)


func _spec_height_ft_from_start(st: Dictionary) -> float:
	return float(st.get("height_ft", 0.0))


func _finalize_manip() -> void:
	match _manip_mode:
		"cell_move":
			var dlt: Vector2i = _manip_start.get("delta", Vector2i.ZERO)
			if dlt != Vector2i.ZERO:
				var mapping := {}
				for id in _manip_targets:
					var bits := _id_key(str(id)).split(",")
					mapping[_id_key(str(id))] = "%d,%d,%s" % [int(bits[0]) + dlt.x, int(bits[1]) + dlt.y, bits[2]]
				_remap_cells(mapping)
				_sel_nodes.clear()
				for v in mapping.values():
					_sel_nodes.append("cell:" + str(v))
			_ghost_comps = []
		"seg_swap":
			_finalize_seg_swap()
			_ghost_comps = []
		"el_slide":
			# A door or window moved onto a face with no wall turns the wall on.
			var el := _element_by_id(str(_manip_start.get("el_id", "")))
			var face := str(el.get("face", ""))
			if ["door", "window"].has(str(el.get("type", ""))) and _wall_chks.has(face) \
					and not (_wall_chks[face] as CheckBox).button_pressed:
				(_wall_chks[face] as CheckBox).set_pressed_no_signal(true)
				_flash("Turned the %s wall on for it." % face)
		"deck_move", "beam_move":
			for id in _manip_targets:
				if not str(id).begins_with("cell:"):
					continue
				var key := _id_key(id)
				var cov: Dictionary = _spec.get("cell_overrides", {})
				var e: Dictionary = cov.get(key, {})
				if e.has("height_ft"):
					_set_cell_override(key, "height_ft", _snap_inch_ft(float(e["height_ft"])))
			for id in _manip_targets:
				if not str(id).begins_with("beam:"):
					continue
				var key := _id_key(id)
				var bov: Dictionary = _spec.get("beam_overrides", {})
				var e: Dictionary = bov.get(key, {})
				if e.has("dy_in"):
					var snapped := roundf(float(e["dy_in"]))
					if absf(snapped) < 0.01:
						e.erase("dy_in")
						if e.is_empty():
							bov.erase(key)
						else:
							bov[key] = e
						_spec["beam_overrides"] = bov
					else:
						_set_beam_override(key, "dy_in", snapped)
	_queue_rebuild(true)  # commit the snapped result immediately (full rebuild)


func _snap_inch_ft(ft: float) -> float:
	return roundf(ft * 12.0) / 12.0


# ---------------------------------------------------------------------------
# Override writers + delete
# ---------------------------------------------------------------------------

func _id_key(id: String) -> String:
	var colon := id.find(":")
	return id.substr(colon + 1) if colon >= 0 else id


func _set_cell_override(key: String, field: String, value: Variant) -> void:
	var cov: Dictionary = _spec.get("cell_overrides", {})
	var e: Dictionary = cov.get(key, {})
	e[field] = value
	cov[key] = e
	_spec["cell_overrides"] = cov


func _erase_cell_field(key: String, field: String) -> void:
	var cov: Dictionary = _spec.get("cell_overrides", {})
	if not cov.has(key):
		return
	var e: Dictionary = cov[key]
	e.erase(field)
	if e.is_empty():
		cov.erase(key)
	else:
		cov[key] = e
	_spec["cell_overrides"] = cov


func _set_beam_override(key: String, field: String, value: Variant) -> void:
	var bov: Dictionary = _spec.get("beam_overrides", {})
	var e: Dictionary = bov.get(key, {})
	e[field] = value
	bov[key] = e
	_spec["beam_overrides"] = bov


## spec["part_overrides"][id][field] = value; null erases it (and an emptied
## entry), so clearing an override leaves the spec as if it never had one.
func _set_part_override(id: String, field: String, value: Variant) -> void:
	var po: Dictionary = _spec.get("part_overrides", {})
	var e: Dictionary = (po.get(id, {}) as Dictionary).duplicate()
	if value == null:
		e.erase(field)
	else:
		e[field] = value
	if e.is_empty():
		po.erase(id)
	else:
		po[id] = e
	_spec["part_overrides"] = po


## Del on the selected parts, each in the way that fits it: an element goes,
## a slope bay is left off, a deck (level, column, bay) loses its decking, a
## beam or wall sheet is taken out the way the rack always did, a whole wall
## is turned off, and any other piece (or group) is hidden.
func _delete_selection() -> void:
	if _sel_nodes.is_empty() and _selection.is_empty():
		return
	_push_undo()
	var gone_elements := {}
	var nodes := _sel_nodes.duplicate()
	if nodes.is_empty():
		nodes = _selection.duplicate()
	for n in nodes:
		var id := str(n)
		match PalletRackBuilder.part_kind(id):
			"element":
				gone_elements[id.get_slice(":", 1)] = true
			"slope_bay":
				var el := _element_by_id(id.get_slice(":", 1))
				if not el.is_empty():
					var segs: Dictionary = el.get("segments", {})
					segs[id.get_slice(":", 2)] = "none"
					el["segments"] = segs
			"deck_level", "strip", "cell":
				var keys: Array = []
				for sub in PalletRackBuilder.part_subtree(_tree, id):
					if str(sub).begins_with("cell:"):
						_set_cell_override(_id_key(sub), "kind", "none")
						keys.append(_id_key(sub))
				_set_cells_stepped(keys, false)
			"beam":
				_set_beam_override(_id_key(id), "deleted", true)
			"wall_sheet":
				var wdel: Array = _spec.get("wall_sheet_deleted", [])
				if not wdel.has(_id_key(id)):
					wdel.append(_id_key(id))
				_spec["wall_sheet_deleted"] = wdel
			"wall":
				var face := _id_key(id)
				(_spec["walls"] as Dictionary)[face] = false
				if _wall_chks.has(face):
					(_wall_chks[face] as CheckBox).set_pressed_no_signal(false)
			_:
				_set_part_override(id, "hidden", true)
	if not gone_elements.is_empty():
		var kept: Array = []
		for e in (_spec.get("elements", []) as Array):
			if not gone_elements.has(str((e as Dictionary).get("id", ""))):
				kept.append(e)
		_spec["elements"] = kept
	_sel_nodes.clear()
	_selection.clear()
	_queue_rebuild(true)


## Hidden parts inside `roots` (part ids; [] = the whole rack): the ones hidden
## on their own, deleted beams and taken-out wall sheets.
func _hidden_under(roots: Array) -> Array:
	var ids: Array = []
	var nodes := _tree_nodes()
	if roots.is_empty():
		ids = nodes.keys()
	else:
		for r in roots:
			ids.append_array(PalletRackBuilder.part_subtree(_tree, str(r)))
	var out: Array = []
	for id in ids:
		if bool((nodes.get(id, {}) as Dictionary).get("hidden", false)):
			out.append(id)
	return out


## Bring back every hidden piece inside `roots` ([] = the whole rack).
func _show_hidden(roots: Array) -> void:
	var hid := _hidden_under(roots)
	if hid.is_empty():
		return
	_push_undo()
	var bov: Dictionary = _spec.get("beam_overrides", {})
	var wdel: Array = _spec.get("wall_sheet_deleted", [])
	for id in hid:
		var sid := str(id)
		_set_part_override(sid, "hidden", null)
		if sid.begins_with("beam:") and bov.has(_id_key(sid)):
			var e: Dictionary = bov[_id_key(sid)]
			e.erase("deleted")
			if e.is_empty():
				bov.erase(_id_key(sid))
		elif sid.begins_with("wall:"):
			wdel.erase(_id_key(sid))
	_spec["beam_overrides"] = bov
	_spec["wall_sheet_deleted"] = wdel
	_flash("Showing %s again." % UiText.count(hid.size(), "hidden part"))
	_queue_rebuild(true)


# ---------------------------------------------------------------------------
# Undo (button + Ctrl+Z) — snapshots the override containers before each edit.
# ---------------------------------------------------------------------------

## The whole spec: element edits, wall toggles and loaded designs change more
## than the per-part overrides, and undo has to take all of them back.
func _snapshot_overrides() -> Dictionary:
	return {"full": _full_spec(), "module": _active_mod}


func _push_undo() -> void:
	_undo_stack.append(_snapshot_overrides())
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_update_undo_btn()


func _undo() -> void:
	if _undo_stack.is_empty():
		return
	var snap: Dictionary = _undo_stack.pop_back()
	if snap.has("full"):
		_load_full(snap["full"], int(snap.get("module", 0)))
	else:
		_spec = snap
	_selection.clear()
	_sel_nodes.clear()
	_hover_group.clear()
	_sync_controls()
	_update_undo_btn()
	_queue_rebuild(true)


func _update_undo_btn() -> void:
	if _undo_btn != null:
		_undo_btn.disabled = _undo_stack.is_empty()


# ---------------------------------------------------------------------------
# Step placement tool — drop a step section onto a grid cell slot. It snaps to
# the frame lines (uprights) and merges into the structure, e.g. internal steps
# from one deck level to the one below.
# ---------------------------------------------------------------------------

func _set_step_mode(on: bool) -> void:
	if on == (_tool == "step"):
		return
	_set_tool("step" if on else "")


## Arm a placement tool ("" disarms). `element` is the template the tool
## places; the step dropper and the TOOL_PRESETS ids need none.
func _set_tool(tool: String, element: Dictionary = {}) -> void:
	_tool = tool
	_place_step_mode = tool == "step"
	_tool_element = {}
	if not tool.is_empty() and tool != "step":
		if not element.is_empty():
			_tool_element = element.duplicate(true)
		else:
			for tp in PalletRackBuilder.TOOL_PRESETS:
				if str(tp["id"]) == tool:
					_tool_element = (tp["element"] as Dictionary).duplicate(true)
		if _tool_element.is_empty():
			_tool = ""
	_ghost_comps = []
	if _steps_btn != null:
		_steps_btn.set_pressed_no_signal(_place_step_mode)
	_sync_tool_buttons()
	if not _tool.is_empty():
		_selection.clear()
		_sel_nodes.clear()
		if not _ctx.is_empty():
			_ctx.clear()
			_refresh_crumbs()
			_queue_rebuild(true)
	_hover_group.clear()
	if _vp_container != null:
		_vp_container.mouse_default_cursor_shape = Control.CURSOR_CROSS if not _tool.is_empty() \
			else Control.CURSOR_ARROW
	_refresh_highlight()
	_update_sel_hud()
	_refresh_inspector()


func _pick_slot(local_pos: Vector2) -> Dictionary:
	if _camera == null:
		return {}
	var vp := _to_viewport_pos(local_pos)
	var origin := _camera.project_ray_origin(vp)
	var dir := _camera.project_ray_normal(vp)
	return PalletRackBuilder.pick_nearest(
		PalletRackBuilder.cell_slots(_spec), origin, dir)


func _update_step_ghost(local_pos: Vector2) -> void:
	var slot := _pick_slot(local_pos)
	_hover_group = [str(slot["id"])] if not slot.is_empty() else []
	_refresh_highlight(true)


func _place_step_at(local_pos: Vector2) -> void:
	var slot := _pick_slot(local_pos)
	if slot.is_empty():
		return
	_push_undo()
	_set_cells_stepped([_id_key(str(slot["id"]))], true)
	_queue_rebuild(true)


# ---------------------------------------------------------------------------
# Highlight overlay + HUD
# ---------------------------------------------------------------------------

func _refresh_highlight(step_ghost: bool = false) -> void:
	if _highlight_holder == null:
		return
	for c in _highlight_holder.get_children():
		c.queue_free()
	for n in _sel_nodes:
		_add_node_highlight(str(n), Color(1.0, 0.6, 0.1, 0.38))
	# Where the armed tool would put its element.
	for gc in _ghost_comps:
		_add_comp_highlight(gc, Color(0.2, 0.75, 1.0, 0.42))
	# Cyan ghost while dropping a step; green for a normal hover.
	if step_ghost or not _tool.is_empty():
		var hover_col := Color(0.2, 0.75, 1.0, 0.4) if step_ghost else Color(0.2, 1.0, 0.35, 0.28)
		for id in _hover_group:
			var hc := _slot_or_comp_by_id(id) if step_ghost else _comp_by_id(id)
			if not hc.is_empty():
				_add_comp_highlight(hc, hover_col)
	elif not _hover_node.is_empty() and not _sel_nodes.has(_hover_node):
		_add_node_highlight(_hover_node, Color(0.2, 1.0, 0.35, 0.28))


## A part's highlight: a single piece shows its own oriented box(es); a group
## its bounding box, fainter, so a whole deck does not wash the view out.
func _add_node_highlight(id: String, color: Color) -> void:
	var boxes := PalletRackBuilder.part_boxes(_tree, id)
	if boxes.is_empty():
		return
	if not _node_has_children(id) and boxes.size() == 1 and (boxes[0] as Dictionary).has("obbs"):
		for ob in (boxes[0]["obbs"] as Array):
			var xf: Transform3D = (ob[0] as Transform3D).affine_inverse()
			var half: Vector3 = ob[1]
			_add_comp_highlight({"obb_xf": xf, "obb_half": half, "aabb": AABB()}, color)
		return
	var bb: AABB = boxes[0]["aabb"]
	for b in boxes:
		bb = bb.merge(b["aabb"])
	if _node_has_children(id):
		color.a *= 0.6
	_add_highlight_box(bb, color)


## A component's highlight: its oriented box when it has one (a slope bay).
func _add_comp_highlight(comp: Dictionary, color: Color) -> void:
	if not comp.has("obb_xf"):
		_add_highlight_box(comp["aabb"], color)
		return
	var xf: Transform3D = comp["obb_xf"]
	var half: Vector3 = comp["obb_half"]
	_add_highlight_box(AABB(-half, half * 2.0), color)
	var mi := _highlight_holder.get_child(_highlight_holder.get_child_count() - 1) as MeshInstance3D
	mi.transform = xf * Transform3D(Basis(), mi.position)


## Resolve an id against the full slot list (includes empty cells) for the step
## ghost, falling back to the live pick cache.
func _slot_or_comp_by_id(id: String) -> Dictionary:
	for slot in PalletRackBuilder.cell_slots(_spec):
		if str(slot["id"]) == id:
			return slot
	return _comp_by_id(id)


func _add_highlight_box(box: AABB, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size + Vector3(0.04, 0.04, 0.04)
	mi.mesh = bm
	mi.position = box.position + box.size * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	bm.material = mat
	_highlight_holder.add_child(mi)


func _update_sel_hud() -> void:
	if _sel_hud == null:
		return
	if _place_step_mode:
		_sel_hud.text = "Step tool: click a cell to drop steps  (Esc to exit)"
		return
	if not _tool.is_empty():
		_sel_hud.text = "%s: %s  (Shift-click to place several • Esc to stop)" % [
			_tool_label(), _tool_prompt()]
		return
	if _sel_nodes.is_empty():
		_sel_hud.text = "" if _ctx.is_empty() else \
			"Inside %s — click a part  (Esc or click outside to close)" % _node_label(str(_ctx[-1]))
		return
	var el := _element_by_id(_selected_element_id())
	if not el.is_empty() and _sel_nodes.size() == 1:
		_sel_hud.text = "Selected: %s  (drag to move • Del remove • Ctrl+D duplicate)" % \
			PalletRackBuilder.element_label(el, _spec) if DRAG_TYPES.has(str(el.get("type", ""))) \
			else "Selected: %s  (Del remove • Ctrl+D duplicate)" % PalletRackBuilder.element_label(el, _spec)
		if _node_has_children(str(_sel_nodes[0])):
			_sel_hud.text = _sel_hud.text.trim_suffix(")") + " • double-click to open)"
		return
	var what := _node_label(str(_sel_nodes[0])) if _sel_nodes.size() == 1 \
		else UiText.count(_sel_nodes.size(), "part")
	var tips: Array = []
	if _sel_nodes.size() == 1 and _node_has_children(str(_sel_nodes[0])):
		tips.append("double-click to open")
	tips.append("Shift-click to add")
	tips.append("Del remove")
	_sel_hud.text = "Selected: %s  (%s)" % [what, " • ".join(tips)]


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	# Deep near-black studio backdrop, matching the Linkage Lab viewport.
	e.background_color = Color(0.035, 0.043, 0.063)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.56, 0.62)
	e.ambient_light_energy = 0.55
	e.fog_enabled = true
	e.fog_light_color = Color(0.035, 0.043, 0.063)
	e.fog_light_energy = 1.0
	e.fog_density = 0.0016
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 1.2
	key.shadow_enabled = true
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, -140, 0)
	fill.light_energy = 0.35
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(300, 300)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.09, 0.10, 0.13)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_highlight_holder = Node3D.new()
	_highlight_holder.name = "Highlights"
	_studio.add_child(_highlight_holder)
	_camera = Camera3D.new()
	_camera.far = 400.0
	_studio.add_child(_camera)
	_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(
		_dist * cos(_pitch) * sin(_yaw),
		_dist * sin(_pitch),
		_dist * cos(_pitch) * cos(_yaw))
	# look_at_from_position avoids the "not inside tree" edge case if the camera
	# transform is set before it fully enters the SubViewport tree.
	_camera.look_at_from_position(_target + cp, _target, Vector3.UP)


## Compact number string ("12", "12.5") — GDScript's % has no %g specifier.
func _fmt_num(v: float) -> String:
	if absf(v - roundf(v)) < 0.001:
		return str(int(round(v)))
	return String.num(v, 2)


# ---------------------------------------------------------------------------
# Spec I/O
# ---------------------------------------------------------------------------

func _selected_meta(opt: OptionButton, fallback: int) -> int:
	if opt == null:
		return fallback
	var m = opt.get_selected_metadata()
	return int(m) if m != null else fallback


func _sync_controls() -> void:
	_suppress = true
	_select_meta(_depth_opt, int(_spec["upright_depth_in"]))
	_select_meta(_height_opt, int(_spec["upright_height_ft"]))
	_select_meta(_beam_opt, int(_spec["beam_span_ft"]))
	_select_meta(_lumber_opt, int(_spec["lumber_len_ft"]))
	_select_meta(_joist_opt, int(_spec["joist_spacing_in"]))
	if _bay_slider:
		_bay_slider.value = int(_spec["bay_count"])
		_bay_val.text = str(int(_spec["bay_count"]))
	if _col_slider:
		_col_slider.value = int(_spec["column_count"])
		_col_val.text = str(int(_spec["column_count"]))
	if _spacing_slider:
		_spacing_slider.value = float(_spec["row_gap_ft"])
		_spacing_val.text = _fmt_num(float(_spec["row_gap_ft"])) + "'"
	if _levels_spin:
		_levels_spin.value = int(_spec["deck_levels"])
	if _roof_chk:
		_roof_chk.button_pressed = bool(_spec["roof_deck"])
	if _decked_chk:
		_decked_chk.button_pressed = bool(_spec["decked"])
	if _u_chk:
		_u_chk.button_pressed = bool(_spec["u_shape"])
	if _u_bays_spin:
		_u_bays_spin.value = int(_spec["u_open_bays"])
	if _u_cols_spin:
		_u_cols_spin.value = int(_spec["u_open_cols"])
	for face in _wall_chks.keys():
		(_wall_chks[face] as CheckBox).button_pressed = \
			bool((_spec["walls"] as Dictionary).get(face, false))
	if _wall_bottom_spin:
		_wall_bottom_spin.value = float(_spec.get("wall_bottom_ft", 0.0))
	if _wall_top_spin:
		_wall_top_spin.value = maxf(float(_spec.get("wall_top_ft", -1.0)), 0.0)
	_suppress = false
	_rebuild_level_spins()


func _select_meta(opt: OptionButton, value: int) -> void:
	if opt == null:
		return
	for i in opt.item_count:
		if int(opt.get_item_metadata(i)) == value:
			opt.select(i)
			return


func _read_spec() -> Dictionary:
	var heights: Array = []
	for sp in _level_spins:
		heights.append(float((sp as SpinBox).value))
	var walls := {}
	for face in _wall_chks.keys():
		walls[face] = (_wall_chks[face] as CheckBox).button_pressed
	return PalletRackBuilder.resolve_spec({
		"upright_depth_in": _selected_meta(_depth_opt, 42),
		"upright_height_ft": _selected_meta(_height_opt, 16),
		"beam_span_ft": _selected_meta(_beam_opt, 12),
		"bay_count": int(_bay_slider.value) if _bay_slider else 3,
		"column_count": int(_col_slider.value) if _col_slider else 2,
		"row_gap_ft": float(_spacing_slider.value) if _spacing_slider else 12.0,
		"decked": _decked_chk.button_pressed if _decked_chk else true,
		"lumber_len_ft": _selected_meta(_lumber_opt, 12),
		"joist_spacing_in": _selected_meta(_joist_opt, 24),
		"deck_levels": int(_levels_spin.value) if _levels_spin else 2,
		"level_heights_ft": heights,
		"roof_deck": _roof_chk.button_pressed if _roof_chk else true,
		"walls": walls,
		"stepped_module": 0,
		"u_shape": _u_chk.button_pressed if _u_chk else false,
		"u_open_bays": int(_u_bays_spin.value) if _u_bays_spin else 1,
		"u_open_cols": int(_u_cols_spin.value) if _u_cols_spin else 1,
		# Per-component editor overrides survive control-driven rebuilds.
		"cell_overrides": (_spec.get("cell_overrides", {}) as Dictionary),
		"beam_overrides": (_spec.get("beam_overrides", {}) as Dictionary),
		"wall_sheet_deleted": (_spec.get("wall_sheet_deleted", []) as Array),
		"wall_bottom_ft": float(_wall_bottom_spin.value) if _wall_bottom_spin else 0.0,
		"wall_top_ft": (float(_wall_top_spin.value) if _wall_top_spin.value > 0.0 else -1.0) \
			if _wall_top_spin else -1.0,
		"elements": (_spec.get("elements", []) as Array),
		"part_overrides": (_spec.get("part_overrides", {}) as Dictionary),
	})


func _queue_rebuild(immediate: bool, light: bool = false) -> void:
	# A pending FULL rebuild always wins over a light one.
	if not light:
		_rebuild_light = false
	elif not _rebuild_pending:
		_rebuild_light = true
	_rebuild_pending = true
	_rebuild_timer = 0.0 if immediate else REBUILD_DEBOUNCE_S


func _rebuild_preview(light: bool = false) -> void:
	if _holder == null:
		return
	# free() (not queue_free) so the previous build is gone before the new one
	# renders — no one-frame ghost while a drag streams rebuilds at 60 fps.
	for c in _holder.get_children():
		c.free()
	if not light:
		_spec = _read_spec()
	var node := PalletRackBuilder.build_node(_full_spec(), "PalletRack",
		{"record": true, "dim_ctx": str(_ctx[-1]) if not _ctx.is_empty() else "",
			"module": _active_mod, "dim_others": _modules.size() > 1})
	_holder.add_child(node)
	_tree = node.get_meta("part_tree", {}) as Dictionary
	# An open group the edit took away (fewer columns, a removed element):
	# close back to the nearest group that still exists, and draw again.
	var nodes := _tree_nodes()
	var ctx_gone := false
	while not _ctx.is_empty() and not nodes.has(str(_ctx[-1])):
		_ctx.pop_back()
		ctx_gone = true
	if ctx_gone:
		_refresh_crumbs()
		_queue_rebuild(true)
	# Frame the structure once (on open); keep the user's orbit/zoom afterwards.
	if not _framed:
		var fb := PalletRackBuilder.fused_bounds(_full_spec(), _active_mod)
		var h := float(_spec["upright_height_ft"]) * PalletRackBuilder.FT
		var fc := fb.get_center()
		_target = Vector3(fc.x, h * 0.45, fc.y)
		_dist = maxf(fb.size.x, fb.size.y) * 0.9 + h * 0.5 + 3.0
		_update_camera()
		_framed = true
	if not light:
		_update_bom(node)
	# Refresh the pick registry + prune selection/hover to still-present ids.
	_pick_cache = PalletRackBuilder.pick_components(_spec)
	_comp_index = {}
	for comp in _pick_cache:
		_comp_index[str(comp["id"])] = comp
	var kept_nodes: Array = []
	for id in _sel_nodes:
		if nodes.has(str(id)):
			kept_nodes.append(id)
	_sel_nodes = kept_nodes
	if not nodes.has(_hover_node):
		_hover_node = ""
	_derive_selection()
	var kept_hover: Array = []
	for id in _hover_group:
		if _comp_index.has(id):
			kept_hover.append(id)
	_hover_group = kept_hover
	if not _pending_select.is_empty() and not light:
		var pend := _pending_select
		_pending_select = ""
		_select_element(pend)
	_refresh_highlight()
	if not light:
		_update_undo_btn()
		_update_sel_hud()
		_refresh_element_list()
		_refresh_inspector()
		_refresh_crumbs()
		if _active and Time.get_ticks_msec() - _last_draft_ms > DRAFT_SAVE_MS:
			_save_draft()


func _update_bom(node: Node3D) -> void:
	if _bom_lbl == null:
		return
	var b: Dictionary = node.get_meta("bom", {}) if node.has_meta("bom") else {}
	var lines: Array = ["%s   %s" % [UiText.count(int(b.get("uprights", 0)), "upright"),
			UiText.count(int(b.get("beams", 0)), "beam")],
		"%s   %s" % [UiText.count(int(b.get("lumber", 0)), "piece", "pieces") + " of lumber",
			UiText.count(int(b.get("plywood", 0)), "plywood sheet")]]
	var n_pv := int(b.get("solar_panels", 0))
	if n_pv > 0:
		lines.append("%s · %s" % [UiText.count(n_pv, "solar panel"),
			UiText.num(float(b.get("solar_watts", 0.0)), "W")])
	var extras: Array = []
	if int(b.get("glazing", 0)) > 0:
		extras.append(UiText.count(int(b["glazing"]), "glazing sheet"))
	if int(b.get("doors", 0)) > 0:
		extras.append(UiText.count(int(b["doors"]), "door"))
	if int(b.get("windows", 0)) > 0:
		extras.append(UiText.count(int(b["windows"]), "window"))
	if int(b.get("stairs", 0)) > 0:
		extras.append(UiText.count(int(b["stairs"]), "staircase"))
	if int(b.get("ladders", 0)) > 0:
		extras.append(UiText.count(int(b["ladders"]), "ladder"))
	if float(b.get("railing_ft", 0.0)) > 0.5:
		extras.append("%d ft of railing" % int(round(float(b["railing_ft"]))))
	if not extras.is_empty():
		lines.append("   ".join(extras))
	_bom_lbl.text = "\n".join(lines)


func _on_place() -> void:
	_spec = _read_spec()
	if _loader == null:
		return
	if _loader.has_method("begin_pallet_rack_placement"):
		var collide := _collide_chk.button_pressed if _collide_chk else true
		_loader.call("begin_pallet_rack_placement", _full_spec(), collide)
	close()


func _on_apply_to_prop() -> void:
	if _bound_prop_id.is_empty():
		return
	_spec = _read_spec()
	_write_bound_record({"rack_spec": PalletRackBuilder.resolve_spec(_full_spec())})
	_forget_draft(_bound_prop_id)
	_draft_done = true
	close()


## Patch the bound rack's record (rebuilding it) and re-seed its solar array.
func _write_bound_record(patch: Dictionary, prop_id: String = "") -> void:
	var pid := _bound_prop_id if prop_id.is_empty() else prop_id
	if pid.is_empty():
		return
	var main := _main_node()
	if main != null:
		PlacedPropService.update_prop_record(main, pid, patch.duplicate(true), true)
	elif _loader != null and _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", pid, patch.duplicate(true))
	# A sloped solar array on the rack is an array on the graph (or no longer is).
	if main != null:
		Callable(PlacedPropService, "seed_pallet_rack_graph").call_deferred(main, pid)


func _on_delete_prop() -> void:
	if _bound_prop_id.is_empty():
		return
	var pid := _bound_prop_id
	if _loader != null and _loader.has_method("delete_prop_by_id"):
		_loader.call("delete_prop_by_id", pid)
	_forget_draft(pid)
	_draft_done = true
	close()


func _main_node() -> Node:
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene
	if _loader != null:
		return _loader.get_parent()
	return null


func _prop_record(prop_id: String) -> Dictionary:
	if _loader != null and _loader.has_method("get_prop_record"):
		var rec: Dictionary = _loader.call("get_prop_record", prop_id)
		if not rec.is_empty():
			return rec
	var main := _main_node()
	if main != null:
		return PlacedPropService.get_prop_record(main, prop_id)
	return {}


# ---------------------------------------------------------------------------
# Design elements — the Add palette, the designs library, the inspector card
# ---------------------------------------------------------------------------

func _small_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", C_TEXT_S)
	l.add_theme_font_size_override("font_size", 11)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _small_button(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(cb)
	return b


func _build_element_ui(side: VBoxContainer) -> void:
	# The selected element's card sits on top, so it is in view the moment
	# something is clicked; hidden while nothing is selected.
	_insp_frame = PanelContainer.new()
	var sb := _card_style()
	sb.border_color = C_PRIMARY
	_insp_frame.add_theme_stylebox_override("panel", sb)
	_insp_frame.visible = false
	side.add_child(_insp_frame)
	_insp_box = VBoxContainer.new()
	_insp_box.add_theme_constant_override("separation", 4)
	_insp_frame.add_child(_insp_box)

	_section(side, "Add to the structure")
	side.add_child(_small_label("Pick one, then click the preview where it goes."))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	for tp in PalletRackBuilder.TOOL_PRESETS:
		var b := Button.new()
		b.text = str(tp["label"])
		b.tooltip_text = str(tp["tip"])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 11)
		var tid := str(tp["id"])
		b.toggled.connect(func(on: bool) -> void: _set_tool(tid if on else ""))
		grid.add_child(b)
		_tool_btns[tid] = b
	side.add_child(grid)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 4)
	_el_preset_opt = OptionButton.new()
	_el_preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_el_preset_opt.focus_mode = Control.FOCUS_NONE
	_el_preset_opt.clip_text = true
	_el_preset_opt.tooltip_text = "Elements you saved with \"Save preset\" — on any rack"
	prow.add_child(_el_preset_opt)
	prow.add_child(_small_button("Place", "Place the saved element (click where it goes)",
		_arm_element_preset))
	side.add_child(prow)

	_section(side, "In this design")
	_el_list_box = VBoxContainer.new()
	_el_list_box.add_theme_constant_override("separation", 2)
	side.add_child(_el_list_box)

	_section(side, "Designs")
	_design_opt = OptionButton.new()
	_design_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_design_opt.focus_mode = Control.FOCUS_NONE
	_design_opt.clip_text = true
	side.add_child(_design_opt)
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 4)
	var load_b := _small_button("Load", "Replace this design with the one picked (Ctrl+Z goes back)",
		_on_load_design)
	load_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drow.add_child(load_b)
	drow.add_child(_small_button("Forget", "Remove the picked saved design from your library",
		_on_forget_design))
	side.add_child(drow)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 4)
	_design_name = LineEdit.new()
	_design_name.placeholder_text = "Name this design"
	_design_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow.add_child(_design_name)
	srow.add_child(_small_button("Save design", "Save the whole rack to your library", _on_save_design))
	side.add_child(srow)
	_status_lbl = _small_label("")
	_status_lbl.add_theme_color_override("font_color", C_PRIMARY)
	side.add_child(_status_lbl)
	_refresh_design_list()
	_refresh_element_presets()
	_refresh_element_list()


func _flash(text: String) -> void:
	if _status_lbl != null:
		_status_lbl.text = text


func _sync_tool_buttons() -> void:
	for tid in _tool_btns.keys():
		(_tool_btns[tid] as Button).set_pressed_no_signal(_tool == str(tid))


func _tool_label() -> String:
	if _tool.begins_with("lib:"):
		var saved: Array = _library.get("elements", [])
		var k := int(_tool.substr(4))
		return str((saved[k] as Dictionary).get("name", "Saved element")) if k < saved.size() else "Saved element"
	for tp in PalletRackBuilder.TOOL_PRESETS:
		if str(tp["id"]) == _tool:
			return str(tp["label"])
	return "Place"


func _tool_prompt() -> String:
	match str(_tool_element.get("type", "")):
		"door", "window":
			return "click a wall face where it goes"
		"stair":
			return "click the face the stairs climb, level with the deck they reach"
		"ladder":
			return "click the face the ladder climbs, level with the deck it reaches"
		"lean_to":
			return "click the face the slope leans on"
		"railing":
			return "click the deck that needs railings"
		"courtyard":
			return "click the deck cell where the courtyard starts"
		"stepped":
			return "click a deck bay to step it down to the level below, or a face for big outside steps"
	return "click the preview"


func _refresh_design_list() -> void:
	if _design_opt == null:
		return
	_design_opt.clear()
	var i := 0
	for d in PalletRackBuilder.design_presets():
		_design_opt.add_item(str(d["name"]))
		_design_opt.set_item_metadata(i, "builtin:" + str(d["id"]))
		_design_opt.set_item_tooltip(i, str(d["blurb"]))
		i += 1
	var saved: Array = _library.get("designs", [])
	for k in saved.size():
		_design_opt.add_item("Mine · " + str((saved[k] as Dictionary).get("name", "")))
		_design_opt.set_item_metadata(i, "lib:%d" % k)
		i += 1


func _refresh_element_presets() -> void:
	if _el_preset_opt == null:
		return
	_el_preset_opt.clear()
	var saved: Array = _library.get("elements", [])
	if saved.is_empty():
		_el_preset_opt.add_item("No saved elements yet")
		_el_preset_opt.set_item_disabled(0, true)
		return
	for k in saved.size():
		_el_preset_opt.add_item(str((saved[k] as Dictionary).get("name", "")))
		_el_preset_opt.set_item_metadata(k, k)


## Replace the design with a built-in ("builtin:<id>" or a bare id) or a saved
## one ("lib:<n>"). Undoable.
func load_design(id: String) -> bool:
	var spec: Dictionary = {}
	if id.begins_with("lib:"):
		var saved: Array = _library.get("designs", [])
		var k := int(id.substr(4))
		if k >= 0 and k < saved.size():
			spec = (saved[k] as Dictionary).get("spec", {}) as Dictionary
	else:
		spec = PalletRackBuilder.design_preset(id.trim_prefix("builtin:")).get("spec", {}) as Dictionary
	if spec.is_empty():
		return false
	_push_undo()
	_load_full(spec)
	_selection.clear()
	_sel_nodes.clear()
	_ctx.clear()
	_refresh_crumbs()
	_hover_group.clear()
	_sync_controls()
	_refresh_module_ui()
	_framed = false
	_queue_rebuild(true)
	return true


func _on_load_design() -> void:
	if _design_opt == null or _design_opt.selected < 0:
		return
	var meta: Variant = _design_opt.get_selected_metadata()
	if meta != null and load_design(str(meta)):
		_flash("Loaded \"%s\" — Ctrl+Z goes back." % _design_opt.get_item_text(_design_opt.selected))


func _on_save_design() -> void:
	var name := _design_name.text.strip_edges() if _design_name != null else ""
	if name.is_empty():
		_flash("Type a name for the design first.")
		return
	_spec = _read_spec()
	var saved: Array = _library.get("designs", [])
	var rec := {"name": name, "spec": _full_spec()}
	var replaced := false
	for k in saved.size():
		if str((saved[k] as Dictionary).get("name", "")) == name:
			saved[k] = rec
			replaced = true
	if not replaced:
		saved.append(rec)
	_library["designs"] = saved
	if PalletRackBuilder.save_library(_library):
		_flash("Saved \"%s\" to your library." % name)
	else:
		_flash("Could not write the library file.")
	_refresh_design_list()


func _on_forget_design() -> void:
	if _design_opt == null or _design_opt.selected < 0:
		return
	var meta := str(_design_opt.get_selected_metadata())
	if not meta.begins_with("lib:"):
		_flash("Built-in designs stay; only your saved ones can be forgotten.")
		return
	var saved: Array = _library.get("designs", [])
	var k := int(meta.substr(4))
	if k < 0 or k >= saved.size():
		return
	var name := str((saved[k] as Dictionary).get("name", ""))
	saved.remove_at(k)
	_library["designs"] = saved
	PalletRackBuilder.save_library(_library)
	_refresh_design_list()
	_flash("Forgot \"%s\"." % name)


func _save_element_preset(name: String) -> void:
	var el := _element_by_id(_insp_el_id)
	if el.is_empty():
		return
	var tmpl := el.duplicate(true)
	tmpl.erase("id")
	if name.strip_edges().is_empty():
		name = PalletRackBuilder.element_label(el, _spec)
	var saved: Array = _library.get("elements", [])
	var rec := {"name": name.strip_edges(), "element": tmpl}
	var replaced := false
	for k in saved.size():
		if str((saved[k] as Dictionary).get("name", "")) == rec["name"]:
			saved[k] = rec
			replaced = true
	if not replaced:
		saved.append(rec)
	_library["elements"] = saved
	PalletRackBuilder.save_library(_library)
	_refresh_element_presets()
	_flash("Saved \"%s\" — place it on any rack from Add to the structure." % rec["name"])


func _arm_element_preset() -> void:
	if _el_preset_opt == null or _el_preset_opt.selected < 0:
		return
	var meta: Variant = _el_preset_opt.get_selected_metadata()
	if meta == null:
		return
	var saved: Array = _library.get("elements", [])
	var k := int(meta)
	if k < 0 or k >= saved.size():
		return
	_set_tool("lib:%d" % k, (saved[k] as Dictionary).get("element", {}) as Dictionary)


# ---- Placing ----

func _ray(local_pos: Vector2) -> Array:
	if _camera == null:
		return []
	var vp := _to_viewport_pos(local_pos)
	return [_camera.project_ray_origin(vp), _camera.project_ray_normal(vp)]


func _ray_face_along(local_pos: Vector2, face: String) -> float:
	var r := _ray(local_pos)
	if r.is_empty():
		return NAN
	return PalletRackBuilder.face_plane_along_ft(_spec, face, r[0], r[1])


## The element the armed tool would place under the cursor, or {"_select": id}
## when that spot already has one (a face's slope, a deck's railing), or {}.
func _tool_candidate(local_pos: Vector2) -> Dictionary:
	var r := _ray(local_pos)
	if r.is_empty() or _tool_element.is_empty():
		return {}
	var el := _tool_element.duplicate(true)
	var t := str(el.get("type", ""))
	match t:
		"door", "window", "stair", "lean_to", "ladder":
			var hit := PalletRackBuilder.face_hit(_spec, r[0], r[1])
			if hit.is_empty():
				return {}
			var face := str(hit["face"])
			el["face"] = face
			if t == "lean_to":
				# Several slopes share a face on their own bays: the one over
				# the bay clicked is selected, else a new one fills the free run
				# of bays round it.
				var seg := PalletRackBuilder.face_segment_at(_spec, face, float(hit["along_ft"]))
				var owner := _slope_over(face, seg, "")
				if not owner.is_empty():
					return {"_select": owner}
				var nseg := PalletRackBuilder.face_segment_count(_spec, face)
				var lo := seg
				while lo > 0 and _slope_over(face, lo - 1, "").is_empty():
					lo -= 1
				var hi := seg
				while hi < nseg - 1 and _slope_over(face, hi + 1, "").is_empty():
					hi += 1
				el["seg_from"] = lo
				el["seg_to"] = hi
				return el
			el["at_ft"] = snappedf(float(hit["along_ft"]), 0.5)
			var y: float = hit["y"]
			if t == "stair" or t == "ladder":
				el["to_level"] = _first_raised_floor(PalletRackBuilder.floor_at(_spec, y + 0.6))
			else:
				var fl := PalletRackBuilder.floor_at(_spec, y)
				el["floor"] = fl
				if t == "window":
					var fy := PalletRackBuilder.floor_y(_spec, fl)
					var h := float(el.get("height_ft", 2.5))
					el["sill_ft"] = clampf(snappedf((y - fy) / PalletRackBuilder.FT - h * 0.5, 0.25),
						0.0, 10.0)
			return el
		"stepped":
			# A deck bay under the cursor (empty slots too) becomes steps; a
			# face nearer than any bay gets big steps outside it.
			var slot := PalletRackBuilder.pick_nearest(PalletRackBuilder.cell_slots(_spec), r[0], r[1])
			var t_slot := INF if slot.is_empty() else PalletRackBuilder.ray_hits_component(r[0], r[1], slot)
			var fh := PalletRackBuilder.face_hit(_spec, r[0], r[1])
			var t_face := INF if fh.is_empty() else float(fh["t"])
			if slot.is_empty() and fh.is_empty():
				return {}
			if t_slot <= t_face + 0.05:
				var key := "%d,%d,%d" % [int(slot["bay"]), int(slot["col"]), int(slot["level"])]
				var claims: Dictionary = _spec.get("_stepped_cells", {})
				if claims.has(key):
					return {"_select": str(claims[key])}
				el["mode"] = "bay"
				el["bay"] = int(slot["bay"])
				el["col"] = int(slot["col"])
				el["level"] = int(slot["level"])
				return el
			var face_s := str(fh["face"])
			var seg := PalletRackBuilder.face_segment_at(_spec, face_s, float(fh["along_ft"]))
			el["mode"] = "face"
			el["face"] = face_s
			el["seg_from"] = seg
			el["seg_to"] = seg
			el["to_level"] = _first_raised_floor(PalletRackBuilder.floor_at(_spec, float(fh["y"]) + 0.6))
			return el
		"railing", "courtyard":
			var comp := PalletRackBuilder.pick_nearest(_pick_cache, r[0], r[1], ["deck", "step"])
			if comp.is_empty():
				return {}
			if t == "railing":
				var lv := int(comp.get("level", 0))
				for e in (_spec.get("elements", []) as Array):
					if str(e.get("type", "")) == "railing" and int(e.get("floor", -9)) == lv:
						return {"_select": str(e.get("id", ""))}
				el["floor"] = lv
			else:
				el["bay0"] = int(comp.get("bay", 0))
				el["col0"] = int(comp.get("col", 0))
			return el
	return {}


## Stairs climb to a raised deck: never the ground, never a 6" ground deck.
func _first_raised_floor(fl: int) -> int:
	for o in PalletRackBuilder.floor_options(_spec):
		if int(o["floor"]) >= maxi(fl, 0) and float(o["y_ft"]) > 2.0:
			return int(o["floor"])
	return maxi(fl, 0)


func _update_tool_ghost(local_pos: Vector2) -> void:
	var cand := _tool_candidate(local_pos)
	_ghost_comps = []
	_hover_group = []
	if cand.has("_select"):
		_hover_group = _element_group(str(cand["_select"]))
	elif not cand.is_empty():
		_ghost_comps = PalletRackBuilder.element_components(_spec, cand)
	_refresh_highlight()


func _tool_click(local_pos: Vector2, keep_tool: bool) -> void:
	var cand := _tool_candidate(local_pos)
	if cand.is_empty():
		_flash("Nothing to put it on there — aim at the structure.")
		return
	if cand.has("_select"):
		_set_tool("")
		_select_element(str(cand["_select"]))
		_flash("There is one there already — it is selected.")
		return
	var t := str(cand.get("type", ""))
	_push_undo()
	if t == "door" or t == "window":
		var face := str(cand.get("face", ""))
		if _wall_chks.has(face) and not (_wall_chks[face] as CheckBox).button_pressed:
			(_wall_chks[face] as CheckBox).set_pressed_no_signal(true)
			_flash("Turned the %s wall on for it." % face)
	add_element(cand, false)
	if not keep_tool:
		_set_tool("")


## Add an element to the design (selected once it is built). Returns its id.
func add_element(el: Dictionary, undo: bool = true) -> String:
	if undo:
		_push_undo()
	var rec := el.duplicate(true)
	rec["id"] = _next_element_id()
	var els: Array = _spec.get("elements", [])
	els.append(rec)
	_spec["elements"] = els
	_pending_select = str(rec["id"])
	_queue_rebuild(true)
	return str(rec["id"])


func _next_element_id() -> String:
	var n := 1
	for e in (_spec.get("elements", []) as Array):
		var id := str((e as Dictionary).get("id", ""))
		if id.begins_with("e") and id.substr(1).is_valid_int():
			n = maxi(n, int(id.substr(1)) + 1)
	return "e%d" % n


func _element_by_id(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for e in (_spec.get("elements", []) as Array):
		if e is Dictionary and str((e as Dictionary).get("id", "")) == id:
			return e
	return {}


## The element the element card edits: a selected element, or the element of
## a selected slope bay. Pieces inside an element (a module, a rail run) get
## the parts card instead.
func _selected_element_id() -> String:
	for id in _sel_nodes:
		var k := PalletRackBuilder.part_kind(str(id))
		if k == "element" or k == "slope_bay":
			return str(id).get_slice(":", 1)
	return ""


## The slope bay picked on its own (-1 = the whole element).
func _selected_seg() -> int:
	if _sel_nodes.size() != 1 or PalletRackBuilder.part_kind(str(_sel_nodes[0])) != "slope_bay":
		return -1
	return int(str(_sel_nodes[0]).get_slice(":", 2))


func select_element(id: String) -> void:
	_select_element(id)


func _select_element(id: String) -> void:
	# Elements sit at the top of the rack: close any open group first.
	if not _ctx.is_empty():
		_ctx.clear()
		_refresh_crumbs()
		_queue_rebuild(true)
	_set_selection(["el:" + id])


func _remove_element(id: String) -> void:
	_push_undo()
	var kept: Array = []
	for e in (_spec.get("elements", []) as Array):
		if str((e as Dictionary).get("id", "")) != id:
			kept.append(e)
	_spec["elements"] = kept
	_selection.clear()
	_sel_nodes.clear()
	_queue_rebuild(true)


func _duplicate_selected_element() -> void:
	var el := _element_by_id(_selected_element_id())
	if el.is_empty():
		return
	var cp := el.duplicate(true)
	cp.erase("id")
	match str(el.get("type", "")):
		"door", "window", "stair":
			cp["at_ft"] = float(el.get("at_ft", 0.0)) + float(el.get("width_ft", 3.0)) + 1.0
		"lean_to":
			var placed := false
			var faces: Array = [str(el.get("face", "front"))]
			for f in PalletRackBuilder.FACES:
				if not faces.has(f):
					faces.append(f)
			for f in faces:
				var nseg := PalletRackBuilder.face_segment_count(_spec, str(f))
				for i in nseg:
					if _slope_over(str(f), i, "").is_empty():
						var j := i
						while j + 1 < nseg and _slope_over(str(f), j + 1, "").is_empty():
							j += 1
						cp["face"] = f
						cp["seg_from"] = i
						cp["seg_to"] = j
						placed = true
						break
				if placed:
					break
			if not placed:
				_flash("Every bay of every face already has a slope.")
				return
		"railing":
			cp["floor"] = int(el.get("floor", 0)) + 1
		"courtyard":
			cp["bay0"] = int(el.get("bay0", 0)) + int(el.get("bays", 1))
		"stepped":
			if str(el.get("mode", "")) == "bay":
				cp["bay"] = int(el.get("bay", 0)) + 1
			else:
				var span := int(el.get("seg_to", 0)) - int(el.get("seg_from", 0)) + 1
				cp["seg_from"] = int(el.get("seg_from", 0)) + span
				cp["seg_to"] = int(el.get("seg_to", 0)) + span
	add_element(cp)
	_flash("Duplicated — drag or edit the copy.")


func _mirror_selected_element() -> void:
	var el := _element_by_id(_selected_element_id())
	if el.is_empty() or not el.has("face"):
		return
	add_element(PalletRackBuilder.mirror_element(el, _spec))
	_flash("Mirrored onto the %s." % str(PalletRackBuilder.OPPOSITE_FACE.get(str(el["face"]), "")))


# ---- The element list ----

func _refresh_element_list() -> void:
	if _el_list_box == null:
		return
	var els: Array = _spec.get("elements", [])
	var sel := _selected_element_id()
	var sig := sel + "#"
	for e in els:
		sig += str(e.get("id", "")) + "|" + PalletRackBuilder.element_label(e, _spec) + ";"
	if sig == _el_list_sig:
		return
	_el_list_sig = sig
	for c in _el_list_box.get_children():
		_el_list_box.remove_child(c)
		c.queue_free()
	if els.is_empty():
		_el_list_box.add_child(_small_label("Nothing added yet — a bare rack."))
		return
	for e in els:
		var eid := str(e.get("id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		var b := Button.new()
		b.text = PalletRackBuilder.element_label(e, _spec)
		b.tooltip_text = b.text
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 11)
		b.add_theme_color_override("font_color", C_PRIMARY if eid == sel else C_TEXT)
		b.pressed.connect(func() -> void: _select_element(eid))
		row.add_child(b)
		row.add_child(IconButton.make("trash-2", "Remove", func() -> void: _remove_element(eid)))
		_el_list_box.add_child(row)


# ---- The inspector card ----

func _refresh_inspector() -> void:
	if _insp_box == null:
		return
	var el_id := _selected_element_id()
	var seg := _selected_seg()
	var el := _element_by_id(el_id)
	if el.is_empty():
		_insp_el_id = ""
		if _sel_nodes.is_empty() or _tree.is_empty():
			_parts_sig = ""
			_insp_frame.visible = false
		else:
			_refresh_parts_card()
		return
	_parts_sig = ""
	if el_id == _insp_el_id and seg == _insp_seg \
			and str(el.get("type", "")) == str(_insp_fields.get("_type", "")) \
			and _vis_sig(el) == str(_insp_fields.get("_vis", "")):
		_sync_inspector_values(el)
		return
	_insp_el_id = el_id
	_insp_seg = seg
	for c in _insp_box.get_children():
		_insp_box.remove_child(c)
		c.queue_free()
	var t := str(el.get("type", ""))
	_insp_fields = {"_type": t, "_vis": _vis_sig(el)}
	_insp_frame.visible = true
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "Selected · " + str(PalletRackBuilder.ELEMENT_LABELS.get(t, t))
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(IconButton.close(func() -> void: _set_selection([]), "Deselect (Esc)"))
	_insp_box.add_child(head)
	if seg >= 0:
		var segs: Dictionary = el.get("segments", {})
		var cur := str(segs.get(str(seg), el.get("surface", "solar")))
		var opt := _insp_option(PalletRackBuilder.SLOPE_SURFACES, cur)
		opt.item_selected.connect(func(i: int) -> void: _on_seg_surface(str(opt.get_item_metadata(i))))
		_insp_row("This bay (%d)" % (seg + 1), opt)
		_insp_fields["_seg"] = opt
		_insp_box.add_child(_small_label("Click the slope away from this bay to edit the whole array."))
	for f in (PalletRackBuilder.ELEMENT_FIELDS.get(t, []) as Array):
		if not PalletRackBuilder.field_visible(f, el):
			continue
		if f.has("section"):
			var sec := Label.new()
			sec.text = str(f["section"])
			sec.add_theme_color_override("font_color", C_PRIMARY)
			sec.add_theme_font_size_override("font_size", 11)
			_insp_box.add_child(sec)
		_add_insp_field(f, el)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 4)
	brow.add_child(_small_button("Duplicate", "A copy beside it (Ctrl+D)", _duplicate_selected_element))
	if el.has("face"):
		brow.add_child(_small_button("Mirror", "A copy on the opposite face", _mirror_selected_element))
	var del := _small_button("Delete", "Remove it (Del)", func() -> void: _remove_element(el_id))
	del.add_theme_color_override("font_color", Color(0.94, 0.45, 0.45))
	brow.add_child(del)
	_insp_box.add_child(brow)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 4)
	var name_le := LineEdit.new()
	name_le.placeholder_text = "Preset name"
	name_le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prow.add_child(name_le)
	prow.add_child(_small_button("Save preset", "Keep this element in your library for any rack",
		func() -> void: _save_element_preset(name_le.text)))
	_insp_box.add_child(prow)


## Which of the element's fields show — the card is rebuilt when it changes.
func _vis_sig(el: Dictionary) -> String:
	var sig := ""
	for f in (PalletRackBuilder.ELEMENT_FIELDS.get(str(el.get("type", "")), []) as Array):
		sig += "1" if PalletRackBuilder.field_visible(f, el) else "0"
	return sig


func _insp_row(label: String, ctrl: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = label
	lbl.tooltip_text = label
	lbl.custom_minimum_size.x = 112
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctrl)
	_insp_box.add_child(row)


func _insp_option(values: Array, current: Variant, labels: Array = []) -> OptionButton:
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.clip_text = true
	opt.add_theme_font_size_override("font_size", 11)
	for i in values.size():
		var label := str(labels[i]) if i < labels.size() \
			else str(PalletRackBuilder.OPTION_LABELS.get(str(values[i]), str(values[i]).capitalize()))
		opt.add_item(label)
		opt.set_item_metadata(i, values[i])
		if str(values[i]) == str(current):
			opt.select(i)
	return opt


## The floors a field offers: every floor, decks only ("level"), or the
## slope's attachment ("attach": the top of the frame, then the decks).
func _floor_choices(kind: String) -> Array:
	var vals: Array = []
	var labels: Array = []
	if kind == "attach":
		vals.append(-1)
		labels.append("Top of the frame")
	for o in PalletRackBuilder.floor_options(_spec):
		if int(o["floor"]) < 0 and kind != "floor":
			continue
		vals.append(int(o["floor"]))
		labels.append(str(o["label"]))
	return [vals, labels]


func _add_insp_field(f: Dictionary, el: Dictionary) -> void:
	var key := str(f["key"])
	var kind := str(f["kind"])
	var ctrl: Control = null
	match kind:
		"face":
			var opt := _insp_option(PalletRackBuilder.FACES, el.get(key, "front"))
			opt.item_selected.connect(func(i: int) -> void: _on_field_changed(key, str(opt.get_item_metadata(i))))
			ctrl = opt
		"floor", "level", "attach":
			var ch := _floor_choices(kind)
			var opt := _insp_option(ch[0], int(el.get(key, 0)), ch[1])
			opt.item_selected.connect(func(i: int) -> void: _on_field_changed(key, int(opt.get_item_metadata(i))))
			ctrl = opt
		"option":
			var opt := _insp_option(f.get("options", []) as Array, el.get(key, ""))
			opt.item_selected.connect(func(i: int) -> void: _on_field_changed(key, str(opt.get_item_metadata(i))))
			ctrl = opt
		"pv_model":
			var labels: Array = []
			for mid in PalletRackBuilder.PV_MODULE_ORDER:
				labels.append(str((PalletRackBuilder.PV_MODULES.get(mid, {}) as Dictionary).get("label", "Custom")))
			var opt := _insp_option(PalletRackBuilder.PV_MODULE_ORDER, el.get(key, "custom"), labels)
			opt.item_selected.connect(func(i: int) -> void: _on_pv_model(str(opt.get_item_metadata(i))))
			ctrl = opt
		"bool":
			var chk := CheckBox.new()
			chk.focus_mode = Control.FOCUS_NONE
			chk.button_pressed = bool(el.get(key, false))
			chk.toggled.connect(func(on: bool) -> void: _on_field_changed(key, on))
			ctrl = chk
		"color":
			var cpb := ColorPickerButton.new()
			cpb.edit_alpha = false
			cpb.custom_minimum_size.y = 22
			var hex := str(el.get(key, "#ffffff"))
			cpb.color = Color.html(hex) if Color.html_is_valid(hex) else Color.WHITE
			cpb.color_changed.connect(func(c: Color) -> void: _on_field_changed(key, "#" + c.to_html(false)))
			ctrl = cpb
		_:
			var sp := SpinBox.new()
			sp.add_theme_font_size_override("font_size", 11)
			_config_spin(sp, f)
			sp.value = _spin_value(f, el)
			sp.value_changed.connect(func(v: float) -> void: _on_spin_field(f, v))
			ctrl = sp
	if f.has("tip"):
		ctrl.tooltip_text = str(f["tip"])
	_insp_fields[key] = ctrl
	_insp_row(str(f["label"]), ctrl)


func _config_spin(sp: SpinBox, f: Dictionary) -> void:
	var kind := str(f["kind"])
	var face := str(_element_by_id(_insp_el_id).get("face", "front"))
	match kind:
		"along":
			sp.min_value = 0.0
			sp.max_value = PalletRackBuilder.face_length_ft(_spec, face)
			sp.step = 0.5
			sp.suffix = "ft"
		"seg":
			sp.min_value = 1
			sp.max_value = PalletRackBuilder.face_segment_count(_spec, face)
			sp.step = 1
		"bay":
			sp.min_value = 1
			sp.max_value = int(_spec.get("bay_count", 1))
			sp.step = 1
		"col":
			sp.min_value = 1
			sp.max_value = int(_spec.get("column_count", 1))
			sp.step = 1
		"int":
			sp.min_value = float(f.get("min", 1))
			sp.max_value = float(f.get("max", 10))
			sp.step = 1
		_:
			sp.min_value = float(f.get("min", 0.0))
			sp.max_value = float(f.get("max", 100.0))
			sp.step = float(f.get("step", 0.25))
			sp.suffix = str(f.get("unit", "ft"))


## The spin box shows bays / grid cells 1-based, and "to bay" as the last bay
## when the slope runs to the end (-1 in the record).
func _spin_value(f: Dictionary, el: Dictionary) -> float:
	var key := str(f["key"])
	match str(f["kind"]):
		"seg":
			var v := int(el.get(key, 0))
			if key == "seg_to" and v < 0:
				return float(PalletRackBuilder.face_segment_count(_spec, str(el.get("face", "front"))))
			return float(v + 1)
		"bay", "col":
			return float(int(el.get(key, 0)) + 1)
	return float(el.get(key, 0.0))


func _on_spin_field(f: Dictionary, v: float) -> void:
	var key := str(f["key"])
	match str(f["kind"]):
		"seg":
			var nseg := PalletRackBuilder.face_segment_count(_spec,
				str(_element_by_id(_insp_el_id).get("face", "front")))
			if key == "seg_to" and int(v) >= nseg:
				_on_field_changed(key, -1)
			else:
				_on_field_changed(key, int(v) - 1)
		"bay", "col":
			_on_field_changed(key, int(v) - 1)
		"int":
			_on_field_changed(key, int(v))
		_:
			_on_field_changed(key, v)


func _on_field_changed(key: String, value: Variant) -> void:
	if _insp_suppress:
		return
	var el := _element_by_id(_insp_el_id)
	if el.is_empty():
		return
	# One undo step per burst of edits (a spin box held down, a colour dragged).
	var now := Time.get_ticks_msec()
	if now - _last_field_undo_ms > 800:
		_push_undo()
	_last_field_undo_ms = now
	el[key] = value
	if key == "face":
		_insp_el_id = ""  # ranges (position, bays) depend on the face: rebuild the card
	# A size or rating typed in is no longer the preset module.
	if PalletRackBuilder.PV_MODULE_KEYS.values().has(key):
		el["panel_model"] = "custom"
	_queue_rebuild(true)


## A module preset picked: its size and ratings fill the slope's fields.
func _on_pv_model(model: String) -> void:
	if _insp_suppress:
		return
	var el := _element_by_id(_insp_el_id)
	if el.is_empty():
		return
	_push_undo()
	PalletRackBuilder.apply_pv_module(el, model)
	_queue_rebuild(true)


func _on_seg_surface(surface: String) -> void:
	var el := _element_by_id(_insp_el_id)
	if el.is_empty() or _insp_seg < 0:
		return
	_push_undo()
	var segs: Dictionary = el.get("segments", {})
	if surface == str(el.get("surface", "")):
		segs.erase(str(_insp_seg))
	else:
		segs[str(_insp_seg)] = surface
	el["segments"] = segs
	_queue_rebuild(true)


## Pull resolved values (clamps, a drag) back into the card without echoing.
func _sync_inspector_values(el: Dictionary) -> void:
	_insp_suppress = true
	var t := str(el.get("type", ""))
	for f in (PalletRackBuilder.ELEMENT_FIELDS.get(t, []) as Array):
		var key := str(f["key"])
		var ctrl: Variant = _insp_fields.get(key)
		if ctrl == null or not is_instance_valid(ctrl):
			continue
		if ctrl is SpinBox:
			_config_spin(ctrl as SpinBox, f)
			(ctrl as SpinBox).set_value_no_signal(_spin_value(f, el))
		elif ctrl is CheckBox:
			(ctrl as CheckBox).set_pressed_no_signal(bool(el.get(key, false)))
		elif ctrl is OptionButton:
			var opt := ctrl as OptionButton
			for i in opt.item_count:
				if str(opt.get_item_metadata(i)) == str(el.get(key, "")):
					opt.select(i)
					break
	_insp_suppress = false


# ---------------------------------------------------------------------------
# Breadcrumb (the open group) + the parts card
# ---------------------------------------------------------------------------

func _build_crumb_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	_crumb_row = HBoxContainer.new()
	_crumb_row.add_theme_constant_override("separation", 2)
	_crumb_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_crumb_row)
	_crumb_hint = Label.new()
	_crumb_hint.add_theme_color_override("font_color", C_TEXT_S)
	_crumb_hint.add_theme_font_size_override("font_size", 11)
	_crumb_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(_crumb_hint)
	_show_hidden_btn = _small_button("Show hidden", "Bring back the parts hidden in here",
		func() -> void: _show_hidden(_ctx.slice(_ctx.size() - 1) if not _ctx.is_empty() else []))
	_show_hidden_btn.visible = false
	bar.add_child(_show_hidden_btn)
	_refresh_crumbs()
	return bar


## Rack › Level 2 deck › Bay 2 — each crumb closes back to that level.
func _refresh_crumbs() -> void:
	if _crumb_row == null:
		return
	for c in _crumb_row.get_children():
		_crumb_row.remove_child(c)
		c.queue_free()
	var path: Array = [""]
	path.append_array(_ctx)
	for i in path.size():
		if i > 0:
			var sep := Label.new()
			sep.text = "›"
			sep.add_theme_color_override("font_color", C_TEXT_S)
			_crumb_row.add_child(sep)
		var id := str(path[i])
		var b := Button.new()
		b.text = "Rack" if id.is_empty() else _node_label(id)
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		var here := i == path.size() - 1
		b.add_theme_color_override("font_color", C_PRIMARY if here else C_TEXT)
		b.tooltip_text = "You are here" if here else "Close back to %s" % b.text
		var depth := i
		b.pressed.connect(func() -> void:
			if depth < _ctx.size():
				_set_ctx(_ctx.slice(0, depth), [_ctx[depth]]))
		_crumb_row.add_child(b)
	if _crumb_hint != null:
		_crumb_hint.text = "Double-click a part to open it" if _ctx.is_empty() \
			else "Esc or click outside to close"
	if _show_hidden_btn != null:
		var n := _hidden_under(_ctx.slice(_ctx.size() - 1) if not _ctx.is_empty() else []).size()
		_show_hidden_btn.visible = n > 0
		_show_hidden_btn.text = "Show %s" % UiText.count(n, "hidden part")


## Default colours the card's swatch starts from (the builder's materials).
func _kind_color(kind: String) -> Color:
	match kind:
		"beam":
			return Color(0.86, 0.36, 0.13)
		"upright":
			return Color(0.18, 0.45, 0.50)
		"joist", "tread", "rail_run", "slope_frame":
			return Color(0.72, 0.55, 0.34)
	return Color(0.80, 0.66, 0.42)


## Can a colour go on part `id`? Glazing and modules have none of their own.
func _paintable(id: String) -> bool:
	var k := PalletRackBuilder.part_kind(id)
	if not PalletRackBuilder.PAINTABLE_KINDS.has(k):
		return false
	if k == "slope_sheet":
		var el := _element_by_id(id.get_slice(":", 1))
		var segs: Dictionary = el.get("segments", {})
		return str(segs.get(id.get_slice(":", 2), el.get("surface", ""))) == "plywood"
	return true


func _refresh_parts_card() -> void:
	var sub := _sel_subtree()
	var cells: Array = []
	var beams: Array = []
	var paint_ids: Array = []
	for id in sub:
		var sid := str(id)
		if sid.begins_with("cell:"):
			cells.append(sid)
		elif sid.begins_with("beam:") and _comp_index.has(sid):
			beams.append(sid)
		if _paintable(sid):
			paint_ids.append(sid)
	var hidden_n := _hidden_under(_sel_nodes).size()
	var sig := ",".join(_sel_nodes) + "#%d#%d#%d" % [cells.size(), paint_ids.size(), hidden_n]
	if sig == _parts_sig and _insp_frame.visible:
		_sync_parts_values(cells, beams, paint_ids)
		return
	_parts_sig = sig
	_insp_el_id = ""
	for c in _insp_box.get_children():
		_insp_box.remove_child(c)
		c.queue_free()
	_insp_fields = {"_type": "_parts"}
	_insp_frame.visible = true
	var one := _sel_nodes.size() == 1
	var first := str(_sel_nodes[0])
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "Selected · " + (_node_label(first) if one else UiText.count(_sel_nodes.size(), "part"))
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(title)
	head.add_child(IconButton.close(func() -> void: _set_selection([]), "Deselect (Esc)"))
	_insp_box.add_child(head)
	var where: Array = ["Rack"]
	for id in PalletRackBuilder.part_path(_tree, first).slice(0, -1):
		where.append(_node_label(str(id)))
	_insp_box.add_child(_small_label(" › ".join(where)))
	if not cells.is_empty():
		var kinds := ["deck", "step", "none"]
		var opt := _insp_option(kinds, _cell_kind(cells[0]), ["Deck", "Steps", "No deck"])
		opt.item_selected.connect(func(i: int) -> void:
			_on_cells_field("kind", str(opt.get_item_metadata(i))))
		_insp_row("Decking", opt)
		_insp_fields["_kind"] = opt
		var sp := SpinBox.new()
		sp.add_theme_font_size_override("font_size", 11)
		sp.min_value = 0.25
		sp.max_value = maxf(float(_spec.get("upright_height_ft", 16)) - 0.25, 0.25)
		sp.step = 1.0 / 12.0
		sp.suffix = "ft"
		sp.value = _cell_height_ft(cells[0])
		sp.value_changed.connect(func(v: float) -> void: _on_cells_field("height_ft", v))
		_insp_row("Deck height", sp)
		_insp_fields["_height"] = sp
	elif not beams.is_empty():
		var bsp := SpinBox.new()
		bsp.add_theme_font_size_override("font_size", 11)
		bsp.min_value = -24.0
		bsp.max_value = 24.0
		bsp.step = 1.0
		bsp.suffix = "in"
		bsp.value = float((_comp_by_id(beams[0])).get("dy_in", 0.0))
		bsp.value_changed.connect(func(v: float) -> void: _on_beams_offset(beams, v))
		_insp_row("Beam offset", bsp)
		_insp_fields["_beam_dy"] = bsp
	if not paint_ids.is_empty():
		var crow := HBoxContainer.new()
		crow.add_theme_constant_override("separation", 4)
		var cpb := ColorPickerButton.new()
		cpb.edit_alpha = false
		cpb.custom_minimum_size = Vector2(60, 22)
		cpb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cpb.color = _current_color(first, paint_ids)
		cpb.color_changed.connect(func(c: Color) -> void: _on_parts_color("#" + c.to_html(false)))
		crow.add_child(cpb)
		crow.add_child(_small_button("Default", "Back to the material's own colour",
			func() -> void: _on_parts_color("")))
		_insp_row("Colour", crow)
		_insp_fields["_color"] = cpb
	if hidden_n > 0:
		_insp_box.add_child(_small_button("Show %s inside" % UiText.count(hidden_n, "hidden part"),
			"Bring back what is hidden inside the selection", func() -> void: _show_hidden(_sel_nodes)))
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 4)
	if one and _node_has_children(first):
		brow.add_child(_small_button("Open", "Open it to select its parts (double-click)",
			func() -> void: _set_ctx(_ctx + [first], [])))
	var del := _small_button(_delete_label(), "Del", _delete_selection)
	del.add_theme_color_override("font_color", Color(0.94, 0.45, 0.45))
	brow.add_child(del)
	_insp_box.add_child(brow)


func _delete_label() -> String:
	var kinds := {}
	for n in _sel_nodes:
		kinds[PalletRackBuilder.part_kind(str(n))] = true
	if kinds.size() == 1:
		match str(kinds.keys()[0]):
			"deck_level", "strip", "cell":
				return "Remove the decking"
			"wall":
				return "Turn the wall off"
	return "Hide"


func _cell_kind(cell_id: String) -> String:
	if (_spec.get("_stepped_cells", {}) as Dictionary).has(_id_key(cell_id)):
		return "step"
	var comp := _comp_by_id(cell_id)
	if not comp.is_empty():
		return str(comp.get("kind", "deck"))
	var cov: Dictionary = (_spec.get("cell_overrides", {}) as Dictionary).get(_id_key(cell_id), {})
	return str(cov.get("kind", "none"))


func _cell_height_ft(cell_id: String) -> float:
	var comp := _comp_by_id(cell_id)
	if not comp.is_empty():
		return float(comp.get("height_ft", 0.0))
	var cov: Dictionary = (_spec.get("cell_overrides", {}) as Dictionary).get(_id_key(cell_id), {})
	if cov.has("height_ft"):
		return float(cov["height_ft"])
	var li := int(_id_key(cell_id).get_slice(",", 2))
	var lv := PalletRackBuilder._levels(_spec)
	return float(lv[mini(li, lv.size() - 1)]["y"]) / PalletRackBuilder.FT if not lv.is_empty() else 0.5


func _current_color(first: String, paint_ids: Array) -> Color:
	var ov := PalletRackBuilder.merged_override(_spec, PalletRackBuilder.part_path(_tree, first))
	# The swatch shows the surface the group is mostly made of: its sheets
	# before its beams.
	var probe := first if _paintable(first) else str(paint_ids[0])
	if not _paintable(first):
		for id in paint_ids:
			if ["sheet", "wall_sheet", "slope_sheet"].has(PalletRackBuilder.part_kind(str(id))):
				probe = str(id)
				break
	if not ov.has("color"):
		ov = PalletRackBuilder.merged_override(_spec, PalletRackBuilder.part_path(_tree, probe))
	var hex := str(ov.get("color", ""))
	return Color.html(hex) if Color.html_is_valid(hex) else _kind_color(PalletRackBuilder.part_kind(probe))


## One undo step per burst of edits (a spin box held down, a colour dragged).
func _push_undo_burst() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_field_undo_ms > 800:
		_push_undo()
	_last_field_undo_ms = now


func _on_cells_field(field: String, value: Variant) -> void:
	if _insp_suppress:
		return
	_push_undo_burst()
	if field == "kind":
		var keys: Array = []
		for id in _sel_subtree():
			if str(id).begins_with("cell:"):
				keys.append(_id_key(str(id)))
		_set_cells_stepped(keys, str(value) == "step")
		if str(value) != "step":
			for k in keys:
				_set_cell_override(str(k), "kind", value)
		_queue_rebuild(true)
		return
	for id in _sel_subtree():
		if str(id).begins_with("cell:"):
			if field == "height_ft":
				_set_cell_override(_id_key(id), field, _snap_inch_ft(float(value)))
			else:
				_set_cell_override(_id_key(id), field, value)
	_queue_rebuild(true)


func _on_beams_offset(beams: Array, dy_in: float) -> void:
	if _insp_suppress:
		return
	_push_undo_burst()
	for id in beams:
		_set_beam_override(_id_key(id), "dy_in", roundf(dy_in))
	_queue_rebuild(true)


## Paint the selection ("" = back to the default). A group's colour covers
## everything in it, so the colours set on its pieces before are cleared.
func _on_parts_color(hex: String) -> void:
	if _insp_suppress:
		return
	_push_undo_burst()
	for n in _sel_nodes:
		for id in PalletRackBuilder.part_subtree(_tree, str(n)):
			_set_part_override(str(id), "color", null)
		if not hex.is_empty():
			_set_part_override(str(n), "color", hex)
	_queue_rebuild(true)


func _sync_parts_values(cells: Array, beams: Array, paint_ids: Array) -> void:
	_insp_suppress = true
	var hs: Variant = _insp_fields.get("_height")
	if hs is SpinBox and is_instance_valid(hs) and not cells.is_empty():
		(hs as SpinBox).set_value_no_signal(_cell_height_ft(cells[0]))
	var ko: Variant = _insp_fields.get("_kind")
	if ko is OptionButton and is_instance_valid(ko) and not cells.is_empty():
		var opt := ko as OptionButton
		for i in opt.item_count:
			if str(opt.get_item_metadata(i)) == _cell_kind(cells[0]):
				opt.select(i)
	var bd: Variant = _insp_fields.get("_beam_dy")
	if bd is SpinBox and is_instance_valid(bd) and not beams.is_empty():
		(bd as SpinBox).set_value_no_signal(float(_comp_by_id(beams[0]).get("dy_in", 0.0)))
	var cp: Variant = _insp_fields.get("_color")
	if cp is ColorPickerButton and is_instance_valid(cp) and not paint_ids.is_empty() \
			and not (cp as ColorPickerButton).get_popup().visible:
		(cp as ColorPickerButton).color = _current_color(str(_sel_nodes[0]), paint_ids)
	_insp_suppress = false


# ---------------------------------------------------------------------------
# The build's racks (fused) + the draft that survives closing
# ---------------------------------------------------------------------------

## Load a whole build (a spec with its "fused" racks); edit rack `active`.
func _load_full(spec: Dictionary, active: int = 0) -> void:
	var mods := PalletRackBuilder.rack_modules(PalletRackBuilder.resolve_spec(spec))
	_modules = []
	for m in mods:
		var ms: Dictionary = (m["spec"] as Dictionary).duplicate(true)
		ms.erase("fused")
		_modules.append({"spec": ms, "xf": m["xf"]})
	_active_mod = clampi(active, 0, _modules.size() - 1)
	_spec = (_modules[_active_mod]["spec"] as Dictionary).duplicate(true)


## The whole build as one spec: rack 0 with the others as its "fused" list.
func _full_spec() -> Dictionary:
	if _modules.size() <= 1:
		var one := _spec.duplicate(true)
		one["fused"] = []
		return one
	var root: Dictionary = _mod_spec(0).duplicate(true)
	var fused: Array = []
	for i in range(1, _modules.size()):
		var ms: Dictionary = _mod_spec(i).duplicate(true)
		ms.erase("fused")
		ms.erase("_stepped_cells")
		var xf: Transform3D = _modules[i]["xf"]
		fused.append({"spec": ms, "x": xf.origin.x, "z": xf.origin.z,
			"yaw": PalletRackBuilder.snap_quarter_deg(rad_to_deg(xf.basis.get_euler().y))})
	root["fused"] = fused
	return root


## Rack i's spec as it stands (the edited one is _spec).
func _mod_spec(i: int) -> Dictionary:
	if i == _active_mod:
		return _spec
	return _modules[i]["spec"] as Dictionary


## Edit another rack of a fused build.
func _switch_module(i: int) -> void:
	if i == _active_mod or i < 0 or i >= _modules.size():
		return
	_spec = _read_spec()
	_modules[_active_mod]["spec"] = _spec.duplicate(true)
	_active_mod = i
	_spec = (_modules[i]["spec"] as Dictionary).duplicate(true)
	_selection.clear()
	_sel_nodes.clear()
	_ctx.clear()
	_hover_group.clear()
	_refresh_crumbs()
	_sync_controls()
	_refresh_module_ui()
	_framed = false
	_queue_rebuild(true)


func _spec_sig(spec: Dictionary) -> String:
	var s := PalletRackBuilder.resolve_spec(spec)
	s.erase("_stepped_cells")
	return str(JSON.stringify(s, "", true).hash())


func _load_draft() -> Dictionary:
	if not FileAccess.file_exists(DRAFT_PATH):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRAFT_PATH))
	return data as Dictionary if data is Dictionary else {}


func _write_draft(d: Dictionary) -> void:
	var f := FileAccess.open(DRAFT_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(d))
	f.close()


## Keep what is on screen: the new rack's design, or a placed rack's unapplied
## edits (none kept when they match the placed rack).
func _save_draft() -> void:
	_last_draft_ms = Time.get_ticks_msec()
	var d := _load_draft()
	var full := _full_spec()
	var entry := {"spec": full, "module": _active_mod, "t": int(Time.get_unix_time_from_system()),
		"cam": [_yaw, _pitch, _dist, _target.x, _target.y, _target.z]}
	if _bound_prop_id.is_empty():
		d["fresh"] = entry
	else:
		var props: Dictionary = d.get("props", {}) if d.get("props") is Dictionary else {}
		if _spec_sig(full) == _base_sig:
			props.erase(_bound_prop_id)
		else:
			entry["base"] = _base_sig
			props[_bound_prop_id] = entry
		# Only the most recent few placed racks keep a draft.
		while props.size() > DRAFT_MAX_PROPS:
			var oldest := ""
			var oldest_t := INF
			for k in props.keys():
				var t := float((props[k] as Dictionary).get("t", 0.0)) if props[k] is Dictionary else 0.0
				if t < oldest_t:
					oldest_t = t
					oldest = str(k)
			props.erase(oldest)
		d["props"] = props
	_write_draft(d)


func _forget_draft(prop_id: String) -> void:
	if prop_id.is_empty():
		return
	var d := _load_draft()
	if d.get("props") is Dictionary and (d["props"] as Dictionary).has(prop_id):
		(d["props"] as Dictionary).erase(prop_id)
		_write_draft(d)


func _restore_camera(entry: Dictionary) -> void:
	var cam: Variant = entry.get("cam")
	if not (cam is Array) or (cam as Array).size() < 6:
		return
	_yaw = float(cam[0])
	_pitch = clampf(float(cam[1]), 0.05, 1.4)
	_dist = clampf(float(cam[2]), 3.0, 80.0)
	_target = Vector3(float(cam[3]), float(cam[4]), float(cam[5]))
	_framed = true
	_update_camera()


## "New" starts a fresh rack; "Revert" (a placed rack) goes back to it as placed.
func _on_new_or_revert() -> void:
	_push_undo()
	var editing := not _bound_prop_id.is_empty()
	if editing:
		var rec := _prop_record(_bound_prop_id)
		var spec: Dictionary = rec.get("rack_spec", {}) as Dictionary
		if spec.is_empty() and rec.has("record_extra"):
			spec = (rec.get("record_extra", {}) as Dictionary).get("rack_spec", {}) as Dictionary
		_load_full(spec)
		_base_sig = _spec_sig(spec)
	else:
		_load_full(PalletRackBuilder.default_spec())
	_selection.clear()
	_sel_nodes.clear()
	_ctx.clear()
	_hover_group.clear()
	_refresh_crumbs()
	_sync_controls()
	_refresh_module_ui()
	_clear_fuse_list()
	_framed = false
	_queue_rebuild(true)
	_flash(("Back to the placed rack." if editing else "A new rack.") + " Ctrl+Z goes back.")


## A placed rack's world transform (y ignored).
func _rec_xf(rec: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(float(rec.get("yaw", 0.0)))),
		Vector3(float(rec.get("x", 0.0)), 0.0, float(rec.get("z", 0.0))))


func _xf_patch(xf: Transform3D) -> Dictionary:
	return {"x": xf.origin.x, "z": xf.origin.z,
		"yaw": fposmod(rad_to_deg(xf.basis.get_euler().y), 360.0)}


func _rec_spec(rec: Dictionary) -> Dictionary:
	var spec: Dictionary = rec.get("rack_spec", {}) as Dictionary
	if spec.is_empty() and rec.has("record_extra"):
		spec = (rec.get("record_extra", {}) as Dictionary).get("rack_spec", {}) as Dictionary
	return spec


## The rack picker of a fused build, and Split off.
func _refresh_module_ui() -> void:
	if _mod_box == null:
		return
	for c in _mod_box.get_children():
		_mod_box.remove_child(c)
		c.queue_free()
	if _modules.size() > 1:
		_mod_box.add_child(_small_label("This build joins %s where their uprights meet. Edit one at a time — the others show faded." %
			UiText.count(_modules.size(), "rack")))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.add_theme_font_size_override("font_size", 11)
		for i in _modules.size():
			var ms := _mod_spec(i)
			opt.add_item("Rack %d · %s × %s" % [i + 1, UiText.count(int(ms.get("bay_count", 1)), "bay"),
				UiText.count(int(ms.get("column_count", 1)), "column")])
		opt.select(_active_mod)
		opt.item_selected.connect(func(i: int) -> void: _switch_module(i))
		row.add_child(opt)
		if not _bound_prop_id.is_empty():
			row.add_child(_small_button("Split off", "Take this rack out of the build; it stays where it is as its own rack",
				_split_active))
		_mod_box.add_child(row)
	elif _bound_prop_id.is_empty():
		_mod_box.add_child(_small_label("Place two racks so a frame of one stands on a frame of the other, then edit one of them here to join them."))
	if not _bound_prop_id.is_empty():
		_mod_box.add_child(_small_button("Find racks to join",
			"Placed racks whose uprights meet this one's (within 2 ft, square to it)", _find_fuse_candidates))


func _refresh_crew_ui() -> void:
	if _crew_box == null:
		return
	var crew := int(_crew_spin.value) if _crew_spin != null else PalletRackBuildSite.DEFAULT_CREW
	for c in _crew_box.get_children():
		_crew_box.remove_child(c)
		c.queue_free()
	_crew_box.add_child(_small_label("People carry every piece from the piles, two raise each frame and hold it while two more seat the beams, then the joists, sheets, steps and walls go in."))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := _small_label("Crew")
	row.add_child(lbl)
	_crew_spin = SpinBox.new()
	_crew_spin.min_value = PalletRackBuildSite.MIN_CREW
	_crew_spin.max_value = 24
	_crew_spin.step = 1
	_crew_spin.value = crew
	_crew_spin.suffix = "people"
	_crew_spin.tooltip_text = "Six is the fewest who can build a rack: two holding each of two frames, two seating the beams."
	_crew_spin.value_changed.connect(func(_v: float) -> void: _crew_lbl.text = "")
	row.add_child(_crew_spin)
	row.add_child(_small_button("Plan", "How long this crew takes, and what holds it up", _on_plan_build))
	_crew_box.add_child(row)
	_crew_lbl = _small_label("")
	_crew_box.add_child(_crew_lbl)
	if _bound_prop_id.is_empty():
		_crew_box.add_child(_small_label("Place the rack, then edit it here to watch a crew build it."))
		return
	var rec := _prop_record(_bound_prop_id)
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", 6)
	b.add_child(_small_button("Rehearse the build", "Close the editor and watch the crew build this rack where it stands. It follows the world clock: speed it up, or scrub back.",
		_on_rehearse_build))
	if rec.get(PalletRackBuildSite.RECORD_KEY) is Dictionary:
		b.add_child(_small_button("End rehearsal", "Stop the rehearsal; the rack stands as built", _on_end_rehearsal))
	_crew_box.add_child(b)


func _on_plan_build() -> void:
	_spec = _read_spec()
	var t0 := Time.get_ticks_msec()
	var tl := PalletRackBuildSite.plan_for(_full_spec(), int(_crew_spin.value))
	var blocked: Array = tl["blocked"]
	if not blocked.is_empty():
		_crew_lbl.text = "This crew can't finish it: %s can't start (too few hands to hold the frames while the beams go on)." % UiText.count(blocked.size(), "job")
		return
	_crew_lbl.text = "%s: about %s, %s. The longest chain of steps alone takes %s." % [
		UiText.count(int(tl["crew"]), "person", "people"), UiText.duration(float(tl["makespan"]) / 3600.0),
		UiText.count((tl["jobs"] as Array).size(), "job"), UiText.duration(PalletRackBuildPlan.critical_path(tl) / 3600.0)]
	if Time.get_ticks_msec() - t0 > 400:
		_crew_lbl.text += " (planned in %.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0)


func _on_rehearse_build() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	if main == null:
		return
	_spec = _read_spec()
	var pid := _bound_prop_id
	# The crew builds what is in the editor: unapplied edits go on first.
	if _spec_sig(_full_spec()) != _base_sig:
		_write_bound_record({"rack_spec": PalletRackBuilder.resolve_spec(_full_spec())})
		_forget_draft(pid)
	_draft_done = true
	var crew := int(_crew_spin.value)
	close()
	if not PalletRackBuildSite.start_rehearsal(main, pid, crew):
		push_warning("PalletRackBuilder: could not start a rehearsal on %s" % pid)


func _on_end_rehearsal() -> void:
	var main := _main_node()
	if main == null or _bound_prop_id.is_empty():
		return
	PalletRackBuildSite.clear_rehearsal(main, _bound_prop_id)
	_refresh_crew_ui()
	_flash("Rehearsal ended.")


func _clear_fuse_list() -> void:
	if _fuse_box == null:
		return
	for c in _fuse_box.get_children():
		_fuse_box.remove_child(c)
		c.queue_free()


## List the placed racks that can join this one.
func _find_fuse_candidates() -> void:
	_clear_fuse_list()
	if _bound_prop_id.is_empty() or _loader == null or not _loader.has_method("placed_prop_records"):
		return
	var rec_a := _prop_record(_bound_prop_id)
	var xf_a := _rec_xf(rec_a)
	var full := _full_spec()
	var found := 0
	var nearest_reason := ""
	var nearest_d := INF
	for rec in (_loader.call("placed_prop_records") as Array):
		if not (rec is Dictionary) or str(rec.get("model_id", "")) != PalletRackBuilder.MODEL_ID:
			continue
		var pid := str(rec.get("id", ""))
		if pid == _bound_prop_id or pid.is_empty():
			continue
		var xf_b := _rec_xf(rec)
		var dist := xf_a.origin.distance_to(xf_b.origin)
		var res := PalletRackBuilder.fuse_transform(full, xf_a, _rec_spec(rec), xf_b)
		if not bool(res.get("ok", false)):
			if dist < nearest_d:
				nearest_d = dist
				nearest_reason = str(res.get("reason", ""))
			continue
		found += 1
		var label := "Join the rack %s away · %s shared" % [UiText.num(dist, "m", 2),
			UiText.count(int(res["shared"]), "upright")]
		var rel := {"x": float(res["x"]), "z": float(res["z"]), "yaw": float(res["yaw"])}
		var b := _small_button(label, "It becomes part of this build; Split off takes it out again",
			func() -> void: _join_rack(pid, rel))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_fuse_box.add_child(b)
	if found == 0:
		_fuse_box.add_child(_small_label("No placed rack meets this one." +
			((" The nearest (%s away): %s." % [UiText.num(nearest_d, "m", 2), nearest_reason])
				if not nearest_reason.is_empty() else "")))


## Fuse placed rack `pid_b` into this build at `rel` (its place in rack 0's
## frame): it leaves the world as its own prop and this rack is rebuilt with
## it. Applied at once (the other prop is gone), so Ctrl+Z history is cleared.
func _join_rack(pid_b: String, rel: Dictionary) -> void:
	var rec_b := _prop_record(pid_b)
	if rec_b.is_empty():
		return
	_spec = _read_spec()
	var keep := _active_mod
	var full := PalletRackBuilder.fuse_specs(_full_spec(), _rec_spec(rec_b), rel)
	if _loader != null and _loader.has_method("delete_prop_by_id"):
		_loader.call("delete_prop_by_id", pid_b)
	_forget_draft(pid_b)
	_write_bound_record({"rack_spec": full})
	_base_sig = _spec_sig(full)
	_load_full(full, keep)
	_undo_stack.clear()
	_update_undo_btn()
	_sync_controls()
	_refresh_module_ui()
	_clear_fuse_list()
	_framed = false
	_queue_rebuild(true)
	_flash("Joined — the shared uprights are drawn once. Split off takes it out again.")


## Take the edited rack out of the build as its own placed rack, where it stands.
func _split_active() -> void:
	if _bound_prop_id.is_empty() or _modules.size() < 2 or _loader == null:
		return
	_spec = _read_spec()
	var res := PalletRackBuilder.split_fused(_full_spec(), _active_mod)
	if res.is_empty():
		return
	var rec := _prop_record(_bound_prop_id)
	var xf_a := _rec_xf(rec)
	var copy := rec.duplicate(true)
	for k in ["graph_item_id", "burn", "stowed_in"]:
		copy.erase(k)
	copy.merge(_xf_patch(xf_a * (res["module_xf"] as Transform3D)), true)
	copy["rack_spec"] = res["module"]
	var new_id := ""
	if _loader.has_method("duplicate_prop_record"):
		new_id = str(_loader.call("duplicate_prop_record", copy))
	var patch := {"rack_spec": res["rest"]}
	if res["rest_xf"] != Transform3D.IDENTITY:
		patch.merge(_xf_patch(xf_a * (res["rest_xf"] as Transform3D)), true)
	_write_bound_record(patch)
	if not new_id.is_empty():
		var main := _main_node()
		if main != null:
			Callable(PlacedPropService, "seed_pallet_rack_graph").call_deferred(main, new_id)
	_base_sig = _spec_sig(res["rest"])
	_load_full(res["rest"], 0)
	_undo_stack.clear()
	_update_undo_btn()
	_sync_controls()
	_refresh_module_ui()
	_clear_fuse_list()
	_framed = false
	_queue_rebuild(true)
	_flash("Split off — it stands on its own now.")


# ---------------------------------------------------------------------------
# Dragging things to new places (bays, faces, cells)
# ---------------------------------------------------------------------------

## Where the camera ray through `local_pos` meets the plane y = plane_y
## (rack-local); Vector3(NAN, NAN, NAN) when it does not.
func _ray_plane_hit(local_pos: Vector2, plane_y: float) -> Vector3:
	var r := _ray(local_pos)
	if r.is_empty():
		return Vector3(NAN, NAN, NAN)
	var o: Vector3 = r[0]
	var d: Vector3 = r[1]
	if absf(d.y) < 1e-6:
		return Vector3(NAN, NAN, NAN)
	var t := (plane_y - o.y) / d.y
	if t < 0.0:
		return Vector3(NAN, NAN, NAN)
	return o + d * t


## Start dragging a whole element: doors / windows / stairs slide along their
## wall (and round corners), slopes and face steps move bay by bay along a face
## (and onto another), bay steps and courtyards move cell by cell.
func _begin_element_drag(node: String, el: Dictionary, local_pos: Vector2) -> void:
	var t := str(el.get("type", ""))
	var eid := str(el["id"])
	if SLIDE_TYPES.has(t):
		var along := _ray_face_along(local_pos, str(el.get("face", "front")))
		if is_nan(along):
			return
		_manip_mode = "el_slide"
		_manip_nodes = [node]
		_manip_targets = _element_group(eid)
		_manip_start = {"el_id": eid, "at_ft": float(el.get("at_ft", 0.0)),
			"grab_ft": along - float(el.get("at_ft", 0.0)), "face": str(el.get("face", ""))}
		return
	var bays_mode := t == "lean_to" or (t == "stepped" and str(el.get("mode", "")) == "face")
	if bays_mode:
		var face := str(el.get("face", "front"))
		var nseg := PalletRackBuilder.face_segment_count(_spec, face)
		var from := int(el.get("seg_from", 0))
		var to := int(el.get("seg_to", -1))
		if to < 0:
			to = nseg - 1
		var along := _ray_face_along(local_pos, face)
		var grab := from if is_nan(along) else PalletRackBuilder.face_segment_at(_spec, face, along)
		_manip_mode = "el_bays"
		_manip_nodes = [node]
		_manip_targets = _element_group(eid)
		_manip_start = {"el_id": eid, "span": maxi(to - from, 0),
			"grab_off": clampi(grab - from, 0, maxi(to - from, 0))}
		return
	if t == "courtyard" or t == "stepped":
		var plane_y := 0.0
		if t == "stepped":
			plane_y = PalletRackBuilder.floor_y(_spec, int(el.get("level", 0)))
		var p := _ray_plane_hit(local_pos, plane_y)
		var gc := Vector2i(-1, -1) if is_nan(p.x) else PalletRackBuilder.grid_cell_at(_spec, p.x, p.z)
		var b0 := int(el.get("bay0" if t == "courtyard" else "bay", 0))
		var c0 := int(el.get("col0" if t == "courtyard" else "col", 0))
		_manip_mode = "el_cell"
		_manip_nodes = [node]
		_manip_targets = _element_group(eid)
		_manip_start = {"el_id": eid, "plane_y": plane_y, "b0": b0, "c0": c0,
			"grab": gc if gc.x >= 0 else Vector2i(b0, c0)}


## Can `el` move onto `face`? A slope needs some bay there no other slope covers.
func _face_free_for(el: Dictionary, face: String) -> bool:
	if str(el.get("type", "")) != "lean_to":
		return true
	for i in PalletRackBuilder.face_segment_count(_spec, face):
		if _slope_over(face, i, str(el.get("id", ""))).is_empty():
			return true
	return false


## The id of the slope covering bay `seg` of `face` ("" none), `skip` ignored.
func _slope_over(face: String, seg: int, skip: String) -> String:
	var nseg := PalletRackBuilder.face_segment_count(_spec, face)
	for e in (_spec.get("elements", []) as Array):
		if str(e.get("type", "")) != "lean_to" or str(e.get("face", "")) != face \
				or str(e.get("id", "")) == skip:
			continue
		var a := int(e.get("seg_from", 0))
		var b := int(e.get("seg_to", -1))
		if b < 0:
			b = nseg - 1
		if seg >= a and seg <= b:
			return str(e.get("id", ""))
	return ""


func _preview_el_bays(local_pos: Vector2) -> void:
	var el := _element_by_id(str(_manip_start["el_id"]))
	var r := _ray(local_pos)
	if el.is_empty() or r.is_empty():
		return
	var face := str(el.get("face", "front"))
	var along := NAN
	var fh := PalletRackBuilder.face_hit(_spec, r[0], r[1])
	if not fh.is_empty() and (str(fh["face"]) == face or _face_free_for(el, str(fh["face"]))):
		face = str(fh["face"])
		along = float(fh["along_ft"])
	else:
		along = PalletRackBuilder.face_plane_along_ft(_spec, face, r[0], r[1])
	if is_nan(along):
		return
	var nseg := PalletRackBuilder.face_segment_count(_spec, face)
	var span := mini(int(_manip_start["span"]), nseg - 1)
	var seg := PalletRackBuilder.face_segment_at(_spec, face, along)
	var from := clampi(seg - mini(int(_manip_start["grab_off"]), span), 0, maxi(nseg - 1 - span, 0))
	if str(el.get("type", "")) == "lean_to":
		for i in range(from, from + span + 1):
			if not _slope_over(face, i, str(el["id"])).is_empty():
				return  # another slope is there: stay put
	el["face"] = face
	el["seg_from"] = from
	el["seg_to"] = from + span
	_sel_hud.text = "%s on the %s face, %s  (drag onto another face to move it there)" % [
		PalletRackBuilder.ELEMENT_LABELS.get(str(el.get("type", "")), "Element"), face,
		("bay %d" % (from + 1)) if span == 0 else ("bays %d–%d" % [from + 1, from + span + 1])]
	_queue_rebuild(true, true)


func _preview_el_cell(local_pos: Vector2) -> void:
	var el := _element_by_id(str(_manip_start["el_id"]))
	if el.is_empty():
		return
	var p := _ray_plane_hit(local_pos, float(_manip_start["plane_y"]))
	if is_nan(p.x):
		return
	var gc := PalletRackBuilder.grid_cell_at(_spec, p.x, p.z)
	if gc.x < 0:
		return
	var grab: Vector2i = _manip_start["grab"]
	var nb := int(_spec.get("bay_count", 1))
	var nc := int(_spec.get("column_count", 1))
	var b := int(_manip_start["b0"]) + gc.x - grab.x
	var c := int(_manip_start["c0"]) + gc.y - grab.y
	if str(el.get("type", "")) == "courtyard":
		b = clampi(b, 0, nb - int(el.get("bays", 1)))
		c = clampi(c, 0, nc - int(el.get("cols", 1)))
		el["bay0"] = b
		el["col0"] = c
	else:
		b = clampi(b, 0, nb - 1)
		c = clampi(c, 0, nc - 1)
		# Never onto a cell another stepped module already stands in.
		var key := "%d,%d,%d" % [b, c, int(el.get("level", 0))]
		var owner := str((_spec.get("_stepped_cells", {}) as Dictionary).get(key, ""))
		if not owner.is_empty() and owner != str(el["id"]):
			return
		el["bay"] = b
		el["col"] = c
	_sel_hud.text = "%s at bay %d, column %d" % [
		PalletRackBuilder.ELEMENT_LABELS.get(str(el.get("type", "")), "Element"), b + 1, c + 1]
	_queue_rebuild(true, true)


## A bay drag: the target cells show as a cyan ghost; the move lands on release.
func _preview_cell_move(local_pos: Vector2) -> void:
	var p := _ray_plane_hit(local_pos, float(_manip_start["plane_y"]))
	if is_nan(p.x):
		return
	var gc := PalletRackBuilder.grid_cell_at(_spec, p.x, p.z)
	if gc.x < 0:
		return
	var ab := str(_manip_start["anchor"]).split(",")
	var dlt := Vector2i(gc.x - int(ab[0]), gc.y - int(ab[1]))
	var nb := int(_spec.get("bay_count", 1))
	var nc := int(_spec.get("column_count", 1))
	var slots: Dictionary = _manip_start["slots"]
	var ghosts: Array = []
	for id in _manip_targets:
		var bits := _id_key(str(id)).split(",")
		var b := int(bits[0]) + dlt.x
		var c := int(bits[1]) + dlt.y
		if b < 0 or b >= nb or c < 0 or c >= nc:
			return
		var sid := "cell:%d,%d,%s" % [b, c, bits[2]]
		if not slots.has(sid):
			return  # cut away (a courtyard, the U)
		ghosts.append(slots[sid])
	_manip_start["delta"] = dlt
	_ghost_comps = ghosts if dlt != Vector2i.ZERO else []
	_refresh_highlight()
	if dlt == Vector2i.ZERO:
		_sel_hud.text = "Drag onto another bay to move it there  (Alt-drag raises or lowers)"
	else:
		var tb := str(_manip_start["anchor"]).split(",")
		_sel_hud.text = "Move to bay %d, column %d  (release to drop; what is there swaps in)" % [
			int(tb[0]) + dlt.x + 1, int(tb[1]) + dlt.y + 1]


## Move deck cells: `mapping` "b,c,li" -> "b,c,li". The cells displaced from
## the targets go to the cells left behind, so nothing is lost. Their
## overrides, their pieces' colours / hidden flags and the stepped modules
## standing in them all move.
func _remap_cells(mapping: Dictionary) -> void:
	var srcs: Array = mapping.keys()
	var dsts: Array = mapping.values()
	var vacated: Array = []
	for k in srcs:
		if not dsts.has(k):
			vacated.append(k)
	var displaced: Array = []
	for k in dsts:
		if not srcs.has(k):
			displaced.append(k)
	vacated.sort()
	displaced.sort()
	var m := mapping.duplicate()
	for i in mini(vacated.size(), displaced.size()):
		m[displaced[i]] = vacated[i]
	# Cell overrides.
	var cov: Dictionary = _spec.get("cell_overrides", {})
	var moved := {}
	for k in m.keys():
		if cov.has(k):
			moved[m[k]] = cov[k]
	for k in m.keys():
		cov.erase(k)
	for k in moved.keys():
		cov[k] = moved[k]
	_spec["cell_overrides"] = cov
	# Part overrides of the cells and their pieces.
	var po: Dictionary = _spec.get("part_overrides", {})
	var po_new := {}
	for id in po.keys():
		var sid := str(id)
		var nid := sid
		for pre in ["cell:", "ply:", "joist:", "tread:"]:
			if sid.begins_with(pre):
				var rest := sid.substr(pre.length())
				var key := rest.get_slice(":", 0)
				if m.has(key):
					nid = pre + str(m[key]) + rest.substr(key.length())
				break
		po_new[nid] = po[id]
	_spec["part_overrides"] = po_new
	# Stepped modules standing in moved cells.
	for e in (_spec.get("elements", []) as Array):
		if str(e.get("type", "")) != "stepped" or str(e.get("mode", "")) != "bay":
			continue
		var ek := "%d,%d,%d" % [int(e["bay"]), int(e["col"]), int(e["level"])]
		if m.has(ek):
			var nb := str(m[ek]).split(",")
			e["bay"] = int(nb[0])
			e["col"] = int(nb[1])


func _preview_seg_swap(local_pos: Vector2) -> void:
	var el := _element_by_id(str(_manip_start["el_id"]))
	if el.is_empty():
		return
	var face := str(el.get("face", "front"))
	var along := _ray_face_along(local_pos, face)
	if is_nan(along):
		return
	var nseg := PalletRackBuilder.face_segment_count(_spec, face)
	var from := int(el.get("seg_from", 0))
	var to := int(el.get("seg_to", -1))
	if to < 0:
		to = nseg - 1
	var j := clampi(PalletRackBuilder.face_segment_at(_spec, face, along), from, to)
	_manip_start["target"] = j
	var src := int(_manip_start["seg"])
	_ghost_comps = []
	if j != src:
		var c := _comp_by_id("el:%s:%d" % [str(el["id"]), j])
		if not c.is_empty():
			_ghost_comps = [c]
		_sel_hud.text = "Swap bay %d with bay %d  (release to swap their coverings)" % [src + 1, j + 1]
	else:
		_sel_hud.text = "Drag onto another bay of the slope to swap them"
	_refresh_highlight()


## Swap two slope bays: their coverings and everything set on their pieces.
func _finalize_seg_swap() -> void:
	var el := _element_by_id(str(_manip_start.get("el_id", "")))
	var i := int(_manip_start.get("seg", -1))
	var j := int(_manip_start.get("target", -1))
	if el.is_empty() or j < 0 or i == j:
		return
	var segs: Dictionary = el.get("segments", {})
	var base := str(el.get("surface", "solar"))
	var si := str(segs.get(str(i), base))
	var sj := str(segs.get(str(j), base))
	segs.erase(str(i))
	segs.erase(str(j))
	if sj != base:
		segs[str(i)] = sj
	if si != base:
		segs[str(j)] = si
	el["segments"] = segs
	var pre_i := "el:%s:%d" % [str(el["id"]), i]
	var pre_j := "el:%s:%d" % [str(el["id"]), j]
	var po: Dictionary = _spec.get("part_overrides", {})
	var po_new := {}
	for id in po.keys():
		var sid := str(id)
		var nid := sid
		if sid == pre_i or sid.begins_with(pre_i + ":"):
			nid = pre_j + sid.substr(pre_i.length())
		elif sid == pre_j or sid.begins_with(pre_j + ":"):
			nid = pre_i + sid.substr(pre_j.length())
		po_new[nid] = po[id]
	_spec["part_overrides"] = po_new
	_sel_nodes = [pre_j]
