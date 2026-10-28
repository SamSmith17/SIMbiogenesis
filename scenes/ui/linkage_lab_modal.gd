extends Control

## Linkage Lab — full-screen scissor-linkage designer modal (LinkageLab port).
##
## Layout mirrors the web app: 52 px topbar (FOLD slider + FOLD/UNFOLD/play/
## pause/reverse + speed + Loop + stop angle + SUN slider + Shadows; right
## cluster Save/Load/Export/Import/Units), 280 px left sidebar of collapsible
## parameter groups, center SubViewport studio hosting LinkageStructureBuilder,
## 280 px right panel with Top/Side orthographic insets + a stats HUD.
##
## State stays IMPERIAL (LinkageParams) exactly like the web app; the Units
## button only toggles the display formatting. Designs save/load as v30
## config JSON (user://linkage_designs/), interchangeable with the web app.

const MODAL_NAME := "linkage_lab"
const REBUILD_DEBOUNCE_S := 0.10
const PRESET_DIR := "res://core/linkage/presets/"
const USER_DESIGN_DIR := "user://linkage_designs/"
## Seeded into a fresh Lab so it opens on a real, correctly-oriented design
## rather than LinkageParams' bare defaults — those have the solar grid square
## to the structure and the reciprocal beams at the wrong end offset.
const DEFAULT_PRESET := PRESET_DIR + "starshade_soak_2026.json"
const SIDEBAR_W := 280.0
const RIGHT_W := 280.0
const TOPBAR_H := 52.0
## Full fold cycle takes 3 s at speed 1.0 (animation.js).
const FULL_CYCLE_S := 3.0
const DEPLOY_PAUSE_S := 1.0

const C_BG := UITheme.C_BG
const C_PANEL := UITheme.C_PANEL
const C_RAISED := UITheme.C_PANEL_RAISED
const C_BORDER := UITheme.C_BORDER
const C_PRIMARY := UITheme.C_PRIMARY
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M

const DIAMETER_OPTIONS := [0.25, 0.3125, 0.375, 0.5, 0.625, 0.75]
const DIAMETER_LABELS := ["1/4\"", "5/16\"", "3/8\"", "1/2\"", "5/8\"", "3/4\""]

var params: LinkageParams = LinkageParams.new()

var _loader: Node = null
var _active := false
var _suppress := false
var _metric := false
var _rebuild_pending := false
var _rebuild_timer := 0.0

# Animation state (port of state.animation).
var _anim_playing := false
var _anim_direction := 1.0
var _anim_pause_left := 0.0
var _anim_one_shot := false

# Studio / cameras.
var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _builder: LinkageStructureBuilder = null
var _camera: Camera3D = null
var _sun_light: DirectionalLight3D = null
var _top_vp: SubViewport = null
var _side_vp: SubViewport = null
var _top_cam: Camera3D = null
var _side_cam: Camera3D = null

# Orbit camera.
var _yaw := 0.75
var _pitch := 0.42
var _dist := 14.0
var _target := Vector3(0, 2.0, 0)
var _orbiting := false
var _panning := false

# Topbar controls.
var _fold_slider: HSlider = null
var _fold_spin: SpinBox = null
var _btn_play: Button = null
var _btn_pause: Button = null
var _speed_slider: HSlider = null
var _loop_chk: CheckBox = null
var _stop_spin: SpinBox = null
var _sun_slider: HSlider = null
var _sun_lbl: Label = null
var _shadows_chk: CheckBox = null
var _btn_units: Button = null
var _btn_place: Button = null
var _btn_apply_prop: Button = null

## Non-empty while editing a placed structure in place ("Edit in Linkage Lab").
var _bound_prop_id := ""

# Sidebar controls.
var _brackets_chk: CheckBox = null
var _bolts_chk: CheckBox = null
var _orientation_opt: OptionButton = null
var _cap_row: Control = null
var _cap_chk: CheckBox = null
var _fixed_chk: CheckBox = null
var _struct_rot: Dictionary = {}
var _arch_group: Control = null
var _arch_flip_chk: CheckBox = null
var _arch_rot: Dictionary = {}
var _array_count: Dictionary = {}
var _hlen: Dictionary = {}
var _vlen: Dictionary = {}
var _hbeam_w: SpinBox = null
var _hbeam_t: SpinBox = null
var _vlink_btn: Button = null
var _vbeam_w: SpinBox = null
var _vbeam_t: SpinBox = null
var _vsplit_box: Control = null
var _vinner_w: SpinBox = null
var _vinner_t: SpinBox = null
var _vouter_w: SpinBox = null
var _vouter_t: SpinBox = null
var _off_top: Dictionary = {}
var _off_bot: Dictionary = {}
var _vert_end: Dictionary = {}
var _hstack: Dictionary = {}
var _vstack: Dictionary = {}
var _vreverse_chk: CheckBox = null
var _hgap: Dictionary = {}
var _vgap: Dictionary = {}
var _modules: Dictionary = {}
var _bracket_w: SpinBox = null
var _bracket_d: SpinBox = null
var _bracket_h: SpinBox = null
var _bracket_wall: SpinBox = null
var _bracket_inner: SpinBox = null
var _bracket_hole_opt: OptionButton = null
var _bracket_hole_dist: SpinBox = null
var _full_detail_chk: CheckBox = null
var _spacing_note: Label = null
var _bolt_dia_opt: OptionButton = null
var _vbolt_row: Control = null
var _vbolt_len: SpinBox = null
var _vbolt_auto: CheckBox = null
var _vbolt_split_box: Control = null
var _vbolt_inner_len: SpinBox = null
var _vbolt_outer_len: SpinBox = null
var _hbolt_len: SpinBox = null
var _hbolt_auto: CheckBox = null
var _hpivot_len: SpinBox = null
var _hpivot_auto: CheckBox = null
var _pivot: Dictionary = {}
var _pivot_ang: Dictionary = {}
var _hoberman: Dictionary = {}
var _preset_opt: OptionButton = null
var _min_fold_spin: SpinBox = null
var _fab_stats: RichTextLabel = null
var _fab_cache_key := ""
var _crew_btn: Button = null
var _crew_status: Label = null
var _radial_vis: Dictionary = {}
## Radial array controls (A3, `mode.radialArray`).
var _ra: Dictionary = {}
## Enclosure controls (A4): raised floor, coverings, shade tarps.
var _fl: Dictionary = {}
var _cv: Dictionary = {}
var _sh: Dictionary = {}
var _span_rows: Array = []
var _rcp_vis: Dictionary = {}
var _panels_vis: Dictionary = {}

# Support beams group (params.support_beams).
var _sb: Dictionary = {}

# Solar panels group (params.solar_panels).
var _sp_enabled: CheckBox = null
var _sp_layout: OptionButton = null
var _sp_top: Dictionary = {}
var _sp_side: Dictionary = {}
var _sp_rect_box: Control = null
var _sp_grid_rot: Dictionary = {}
var _sp_radial_box: Control = null
var _sp_radial: Dictionary = {}
var _sp_spiral_box: Control = null
var _sp_spiral: Dictionary = {}
var _sp_pos: Dictionary = {}
var _faces_box: Control = null
var _faces_grid: GridContainer = null

# Right panel stats.
var _stat_vals: Dictionary = {}
var _anim_status_lbl: Label = null
## The build-steps dock under the 3D view (A5).
const STEPS_PANEL_SCRIPT := preload("res://scenes/ui/linkage_steps_panel.gd")
var _steps_panel: PanelContainer = null

# Save/load overlays + file dialogs.
var _save_overlay: Control = null
var _save_name_edit: LineEdit = null
var _load_overlay: Control = null
var _load_list: ItemList = null
var _load_entries: Array = []
var _export_dlg: FileDialog = null
var _import_dlg: FileDialog = null

var _presets: Array = []
var _seeded_default := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_scan_presets()
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open(config: Dictionary = {}) -> void:
	if _active:
		return
	_bound_prop_id = ""
	if not config.is_empty():
		params = LinkageParams.new()
		params.from_config(config)
	elif not _seeded_default:
		_seed_default_design()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	HudLayout.claim_modal(MODAL_NAME)
	_update_place_buttons()
	_apply_params(true)
	_sync_controls()


## Load the shipped default design on the FIRST bare open.
##
## Latched, so reopening the Lab keeps whatever the player last had on the
## bench instead of throwing their work away. A failure here is not worth
## blocking on — the Lab still opens on LinkageParams' defaults.
func _seed_default_design() -> void:
	_seeded_default = true
	var f := FileAccess.open(DEFAULT_PRESET, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("Linkage Lab: default preset %s is unreadable" % DEFAULT_PRESET)
		return
	params = LinkageParams.new()
	params.from_config(parsed as Dictionary)


## Edit-in-place: open bound to a placed structure, seeded with its spec.
## "Apply to structure" rebuilds that prop; "Place in world" stays available
## for placing a copy.
func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var main := _main_node()
	if main == null:
		return
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty():
		return
	var spec: Dictionary = rec.get("linkage_spec", {}) as Dictionary
	open(spec)
	_bound_prop_id = prop_id
	_update_place_buttons()


func _update_place_buttons() -> void:
	if _btn_apply_prop != null:
		_btn_apply_prop.visible = not _bound_prop_id.is_empty()
	if _btn_place != null:
		_btn_place.text = "Place copy" if not _bound_prop_id.is_empty() else "Place in world"


func close() -> void:
	if not _active:
		return
	_active = false
	_anim_playing = false
	if _steps_panel != null:
		_steps_panel.call("close")
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)
	HudLayout.release(MODAL_NAME)


func _process(delta: float) -> void:
	if _rebuild_pending:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_pending = false
			_apply_params(false)
	if _anim_playing:
		_step_animation(delta)


# ---------------------------------------------------------------------------
# Fold animation (port of animation.js:animateFold)
# ---------------------------------------------------------------------------

func _step_animation(delta: float) -> void:
	if _builder == null:
		return
	if _anim_pause_left > 0.0:
		_anim_pause_left -= delta
		if _anim_pause_left > 0.0:
			return
	var speed := maxf(float(_speed_slider.value), 0.05)
	var min_angle := _builder.min_fold_angle()
	var closed := _builder.closed_angle()
	var stop_rad := deg_to_rad(float(_stop_spin.value)) if _stop_spin != null else closed
	var max_angle := minf(stop_rad, closed)
	if max_angle <= min_angle:
		_anim_playing = false
		_update_anim_status()
		return
	var step := (max_angle - min_angle) / (FULL_CYCLE_S / speed) * delta * _anim_direction
	var angle := params.fold_angle + step
	var reached_end := false
	var reached_deployed := false
	if _anim_direction > 0.0 and angle >= max_angle:
		angle = max_angle
		reached_end = true
		reached_deployed = true
	elif _anim_direction < 0.0 and angle <= min_angle:
		angle = min_angle
		reached_end = true
	_set_fold_angle(angle)
	if not reached_end:
		return
	if _anim_one_shot or not _loop_chk.button_pressed:
		_anim_playing = false
		_anim_one_shot = false
	else:
		# Ping-pong with a 1 s dwell at the deployed end (web behavior).
		if reached_deployed:
			_anim_pause_left = DEPLOY_PAUSE_S
		_anim_direction *= -1.0
	_update_anim_status()


func _update_anim_status() -> void:
	if _anim_status_lbl == null:
		return
	if _anim_playing:
		_anim_status_lbl.text = "Animating — %s" % ("expanding" if _anim_direction > 0.0 else "collapsing")
	else:
		_anim_status_lbl.text = "Idle"


func _on_fold_btn() -> void:
	_anim_direction = -1.0
	_anim_one_shot = true
	_anim_playing = true
	_anim_pause_left = 0.0
	_update_anim_status()


func _on_unfold_btn() -> void:
	_anim_direction = 1.0
	_anim_one_shot = true
	_anim_playing = true
	_anim_pause_left = 0.0
	_update_anim_status()


func _on_play_btn() -> void:
	_anim_one_shot = false
	_anim_playing = true
	_anim_pause_left = 0.0
	_update_anim_status()


func _on_pause_btn() -> void:
	_anim_playing = false
	_update_anim_status()


func _on_reverse_btn() -> void:
	_anim_direction *= -1.0
	_update_anim_status()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(C_BG.r, C_BG.g, C_BG.b, 0.92)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	root.add_child(_build_topbar())

	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 6)
	root.add_child(main)

	main.add_child(_build_sidebar())
	main.add_child(_build_center())
	main.add_child(_build_right_panel())

	_build_save_load_overlays()
	_build_file_dialogs()


func _panel_wrap(inner: Control) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	pc.add_child(inner)
	return pc


# --- Topbar ---

func _build_topbar() -> Control:
	# Groups that wrap as a whole onto a second row when the screen is too
	# narrow for one (the bar was 1931 px on a 1920 screen and pushed the
	# right-hand column off the edge; at UI scale 125 % it was 400 px over).
	var bar := HFlowContainer.new()
	bar.custom_minimum_size.y = TOPBAR_H
	bar.add_theme_constant_override("h_separation", 18)
	bar.add_theme_constant_override("v_separation", 4)
	var g_title := _topbar_group(bar)
	var g_fold := _topbar_group(bar)
	var g_anim := _topbar_group(bar)
	var g_sun := _topbar_group(bar)
	var g_act := _topbar_group(bar)

	var title := Label.new()
	title.text = "  Linkage Lab"
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	g_title.add_child(title)

	var fold_lbl := Label.new()
	fold_lbl.text = "FOLD:"
	fold_lbl.add_theme_color_override("font_color", C_TEXT_S)
	fold_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	g_fold.add_child(fold_lbl)
	_fold_slider = HSlider.new()
	_fold_slider.min_value = 5.0
	_fold_slider.max_value = 175.0
	_fold_slider.step = 0.1
	_fold_slider.custom_minimum_size = Vector2(190, 0)
	_fold_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fold_slider.focus_mode = Control.FOCUS_NONE
	_fold_slider.value_changed.connect(_on_fold_slider)
	g_fold.add_child(_fold_slider)
	_fold_spin = SpinBox.new()
	_fold_spin.min_value = 5.0
	_fold_spin.max_value = 175.0
	_fold_spin.step = 0.1
	_fold_spin.custom_minimum_size = Vector2(84, 0)
	_fold_spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fold_spin.suffix = "°"
	_fold_spin.value_changed.connect(_on_fold_slider)
	g_fold.add_child(_fold_spin)

	var btn_fold := _topbar_btn("FOLD", "Fold to closed position")
	btn_fold.add_theme_color_override("font_color", Color(0.95, 0.45, 0.4))
	btn_fold.pressed.connect(_on_fold_btn)
	g_anim.add_child(btn_fold)
	var btn_unfold := _topbar_btn("UNFOLD", "Unfold to open position")
	btn_unfold.add_theme_color_override("font_color", Color(0.35, 0.85, 0.55))
	btn_unfold.pressed.connect(_on_unfold_btn)
	g_anim.add_child(btn_unfold)
	_btn_play = _topbar_btn("▶", "Play animation")
	_btn_play.pressed.connect(_on_play_btn)
	g_anim.add_child(_btn_play)
	_btn_pause = _topbar_btn("⏸", "Pause animation")
	_btn_pause.pressed.connect(_on_pause_btn)
	g_anim.add_child(_btn_pause)
	var btn_rev := _topbar_btn("⟲", "Reverse direction")
	btn_rev.pressed.connect(_on_reverse_btn)
	g_anim.add_child(btn_rev)
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.1
	_speed_slider.max_value = 3.0
	_speed_slider.step = 0.1
	_speed_slider.value = 1.0
	_speed_slider.custom_minimum_size = Vector2(80, 0)
	_speed_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_speed_slider.focus_mode = Control.FOCUS_NONE
	_speed_slider.tooltip_text = "Animation speed"
	g_anim.add_child(_speed_slider)
	_loop_chk = CheckBox.new()
	_loop_chk.text = "Loop"
	_loop_chk.focus_mode = Control.FOCUS_NONE
	_loop_chk.tooltip_text = "Ping-pong animation"
	_loop_chk.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	g_anim.add_child(_loop_chk)
	_stop_spin = SpinBox.new()
	_stop_spin.min_value = 0.0
	_stop_spin.max_value = 180.0
	_stop_spin.step = 1.0
	_stop_spin.custom_minimum_size = Vector2(72, 0)
	_stop_spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_stop_spin.tooltip_text = "Close limit (deg)"
	_stop_spin.value_changed.connect(func(v: float) -> void:
		if not _suppress:
			params.animation_stop_angle = v)
	g_anim.add_child(_stop_spin)

	var sun_lbl := Label.new()
	sun_lbl.text = "SUN:"
	sun_lbl.add_theme_color_override("font_color", C_TEXT_S)
	sun_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	g_sun.add_child(sun_lbl)
	_sun_slider = HSlider.new()
	_sun_slider.min_value = 0.0
	_sun_slider.max_value = 100.0
	_sun_slider.step = 0.1
	_sun_slider.value = 50.0
	_sun_slider.custom_minimum_size = Vector2(110, 0)
	_sun_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_sun_slider.focus_mode = Control.FOCUS_NONE
	_sun_slider.tooltip_text = "Time of day (sunrise → sunset)"
	_sun_slider.value_changed.connect(func(_v: float) -> void: _update_sun())
	g_sun.add_child(_sun_slider)
	_sun_lbl = Label.new()
	_sun_lbl.text = "12:00"
	_sun_lbl.custom_minimum_size.x = 46
	_sun_lbl.add_theme_color_override("font_color", C_TEXT)
	_sun_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	g_sun.add_child(_sun_lbl)
	_shadows_chk = CheckBox.new()
	_shadows_chk.text = "Shadows"
	_shadows_chk.button_pressed = true
	_shadows_chk.focus_mode = Control.FOCUS_NONE
	_shadows_chk.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_shadows_chk.toggled.connect(func(on: bool) -> void:
		if _sun_light != null:
			_sun_light.shadow_enabled = on)
	g_sun.add_child(_shadows_chk)


	_btn_place = _topbar_btn("Place in world", "Ghost-place this structure in the 3D world (live-foldable)")
	_btn_place.add_theme_color_override("font_color", C_PRIMARY)
	_btn_place.pressed.connect(_on_place_pressed)
	g_act.add_child(_btn_place)
	_btn_apply_prop = _topbar_btn("Apply to structure", "Rebuild the placed structure with this design")
	_btn_apply_prop.add_theme_color_override("font_color", C_PRIMARY)
	_btn_apply_prop.visible = false
	_btn_apply_prop.pressed.connect(_on_apply_to_prop_pressed)
	g_act.add_child(_btn_apply_prop)
	g_act.add_child(_vsep())

	var btn_steps := _topbar_btn("🎬 Steps", "Build steps — play the fabrication + assembly sequence, edit it, save it with the design")
	btn_steps.pressed.connect(toggle_steps)
	g_act.add_child(btn_steps)
	var btn_guide := _topbar_btn("📋", "Build guide — BOM, cut list, drill templates, assembly sequence")
	btn_guide.pressed.connect(_on_build_guide_pressed)
	g_act.add_child(btn_guide)
	var btn_hw := _topbar_btn("🔩", "Hardware detail — the parts stacked at each joint")
	btn_hw.pressed.connect(_on_hardware_detail_pressed)
	g_act.add_child(btn_hw)
	var btn_save := _topbar_btn("💾", "Save design (user://linkage_designs)")
	btn_save.pressed.connect(_on_save_pressed)
	g_act.add_child(btn_save)
	var btn_load := _topbar_btn("📂", "Load design / preset")
	btn_load.pressed.connect(_on_load_pressed)
	g_act.add_child(btn_load)
	var btn_export := _topbar_btn("⬇", "Export JSON file (web-app compatible)")
	btn_export.pressed.connect(func() -> void: _export_dlg.popup_centered_ratio(0.6))
	g_act.add_child(btn_export)
	var btn_import := _topbar_btn("⬆", "Import JSON file")
	btn_import.pressed.connect(func() -> void: _import_dlg.popup_centered_ratio(0.6))
	g_act.add_child(btn_import)
	_btn_units = _topbar_btn("ft", "Toggle unit display (imperial/metric)")
	UiIcons.apply(_btn_units, "ruler")
	_btn_units.pressed.connect(_on_units_pressed)
	g_act.add_child(_btn_units)
	g_act.add_child(_vsep())
	var btn_close := IconButton.close(close)
	g_act.add_child(btn_close)

	# Icons, not emoji (several rendered as empty boxes in the default font).
	for pair in [[_btn_play, "play"], [_btn_pause, "pause"], [btn_rev, "rotate-cw"],
			[btn_guide, "list"], [btn_hw, "wrench"], [btn_save, "save"], [btn_load, "folder-open"],
			[btn_export, "download"], [btn_import, "upload"]]:
		var b: Button = pair[0]
		b.text = ""
		UiIcons.apply(b, str(pair[1]))
	btn_steps.text = "Steps"
	UiIcons.apply(btn_steps, "video")
	return _panel_wrap(bar)


func _topbar_group(bar: Container) -> HBoxContainer:
	var g := HBoxContainer.new()
	g.add_theme_constant_override("separation", 8)
	g.custom_minimum_size.y = TOPBAR_H - 8.0
	bar.add_child(g)
	return g




func _topbar_btn(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	UITheme.style_button(b)
	return b


func _vsep() -> VSeparator:
	var s := VSeparator.new()
	s.modulate = Color(1, 1, 1, 0.25)
	return s


# --- Left sidebar ---

func _build_sidebar() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = SIDEBAR_W
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var side_pad := MarginContainer.new()
	side_pad.add_theme_constant_override("margin_left", 6)
	side_pad.add_theme_constant_override("margin_right", 6)
	side_pad.add_theme_constant_override("margin_top", 4)
	side_pad.add_theme_constant_override("margin_bottom", 8)
	scroll.add_child(side_pad)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 7)
	side_pad.add_child(side)

	# Display toggles (Brackets / Bolts — collision deferred), framed like a card.
	var disp := _group(side, "Display", false)
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 16)
	disp.add_child(toggles)
	_brackets_chk = _check(toggles, "Brackets", true)
	_bolts_chk = _check(toggles, "Bolts", false)

	# Orientation + mode flags.
	var typ := _group(side, "Structure Type", false)
	var orient_lbl := Label.new()
	orient_lbl.text = "Orientation"
	orient_lbl.add_theme_color_override("font_color", C_TEXT_S)
	orient_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	typ.add_child(orient_lbl)
	_orientation_opt = OptionButton.new()
	_orientation_opt.focus_mode = Control.FOCUS_NONE
	_orientation_opt.add_item("Horizontal (Cylinder / Dome)")
	_orientation_opt.add_item("Vertical (Arch / Bridge)")
	_orientation_opt.item_selected.connect(func(_i: int) -> void: _on_param_changed())
	typ.add_child(_orientation_opt)
	_cap_row = HBoxContainer.new()
	typ.add_child(_cap_row)
	_cap_chk = _check(_cap_row, "Cap Uprights (End Supports)", false)
	_fixed_chk = _check(typ, "Fixed Straight Beams (Constant Spacing)", false)
	_struct_rot = _slider_spin(typ, "Turntable Rotation (Y-Axis)", "°", -180.0, 180.0, 0.25, 0.0, _on_struct_rot_changed)

	# Arch orientation (arch mode only).
	var arch_wrap := VBoxContainer.new()
	side.add_child(arch_wrap)
	_arch_group = arch_wrap
	var arch_g := _group(arch_wrap, "Arch Orientation", false)
	_arch_flip_chk = _check(arch_g, "Flip Upside Down", false)
	_arch_rot = _slider_spin(arch_g, "Rotation", "°", -180.0, 180.0, 1.0, 0.0, _on_param_changed_f)
	var arch_reset := Button.new()
	arch_reset.text = "Reset Orientation"
	arch_reset.focus_mode = Control.FOCUS_NONE
	arch_reset.pressed.connect(func() -> void:
		_suppress = true
		_arch_flip_chk.button_pressed = false
		(_arch_rot["slider"] as HSlider).value = 0.0
		(_arch_rot["spin"] as SpinBox).value = 0.0
		_suppress = false
		_on_param_changed())
	arch_g.add_child(arch_reset)
	_array_count = _slider_spin(arch_g, "Array Count", "", 1.0, 10.0, 1.0, 1.0, _on_param_changed_f)

	# Lumber dimensions.
	var lum := _group(side, "Lumber Dimensions", false)
	_hlen = _slider_spin(lum, "Horizontal Beam Length", "ft", 2.0, 24.0, 0.01, 8.0, _on_param_changed_f)
	_vlen = _slider_spin(lum, "Vertical Beam Length", "ft", 2.0, 24.0, 0.01, 8.0, _on_param_changed_f)
	var hwt := _wt_row(lum, "Horiz Beam (W x T)")
	_hbeam_w = hwt[0]
	_hbeam_t = hwt[1]
	var vhead := HBoxContainer.new()
	lum.add_child(vhead)
	var vlbl := Label.new()
	vlbl.text = "Vert Beam (W x T)"
	vlbl.add_theme_color_override("font_color", C_TEXT_S)
	vlbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	vlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vhead.add_child(vlbl)
	_vlink_btn = Button.new()
	_vlink_btn.text = "🔗"
	_vlink_btn.tooltip_text = "Inner/outer V-beam sizes linked — click to unlink (3-beam stacks)"
	_vlink_btn.focus_mode = Control.FOCUS_NONE
	_vlink_btn.pressed.connect(func() -> void:
		params.v_beam_dimensions_linked = not params.v_beam_dimensions_linked
		_on_param_changed())
	vhead.add_child(_vlink_btn)
	var vwt := _wt_row(lum, "")
	_vbeam_w = vwt[0]
	_vbeam_t = vwt[1]
	_vsplit_box = VBoxContainer.new()
	lum.add_child(_vsplit_box)
	var split_note := Label.new()
	split_note.text = "V-Stack inner/outer beam sizes (unlinked)"
	split_note.add_theme_color_override("font_color", C_TEXT_M)
	split_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_vsplit_box.add_child(split_note)
	var iwt := _wt_row(_vsplit_box, "V-Inner Beam (W x T)")
	_vinner_w = iwt[0]
	_vinner_t = iwt[1]
	var owt := _wt_row(_vsplit_box, "V-Outer Beam (W x T)")
	_vouter_w = owt[0]
	_vouter_t = owt[1]
	_off_top = _slider_spin(lum, "Horizontal Beam Top Extension", "in", 0.0, 48.0, 0.01, 1.5, _on_param_changed_f)
	_off_bot = _slider_spin(lum, "Horizontal Beam Bottom Extension", "in", 0.0, 48.0, 0.01, 1.5, _on_param_changed_f)
	_vert_end = _slider_spin(lum, "V-Beam End Offset", "in", 0.5, 24.0, 0.01, 1.5, _on_param_changed_f)

	# Stack configuration.
	var stk := _group(side, "Stack Configuration", false)
	_hstack = _slider_spin(stk, "Horizontal Stack Count", "", 2.0, 6.0, 1.0, 2.0, _on_param_changed_f)
	_vstack = _slider_spin(stk, "Vertical Stack Count", "", 2.0, 6.0, 1.0, 3.0, _on_param_changed_f)
	_vreverse_chk = _check(stk, "Reverse Vertical Stack Order", false)
	_hgap = _slider_spin(stk, "Horizontal Stack Gap", "in", -2.0, 1.0, 0.05, 0.0, _on_param_changed_f)
	_vgap = _slider_spin(stk, "Vertical Stack Gap", "in", -2.0, 1.0, 0.05, 0.0, _on_param_changed_f)
	_modules = _slider_spin(stk, "Module Count", "", 3.0, 40.0, 1.0, 8.0, _on_param_changed_f)

	# Hardware settings (collapsed by default like the web app).
	var hw := _group(side, "Hardware Settings", true)
	_full_detail_chk = _check(hw, "Hardware Full Detail", false)
	_full_detail_chk.tooltip_text = "Let the parametric hardware assemblies drive stack gaps and bracket dimensions. The fields below become read-outs while it is on."
	_spacing_note = Label.new()
	_spacing_note.text = "Stack gaps and bracket dims come from the hardware assemblies (🔩)."
	_spacing_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_spacing_note.add_theme_color_override("font_color", UITheme.C_AMBER)
	_spacing_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_spacing_note.visible = false
	hw.add_child(_spacing_note)
	var brd_lbl := Label.new()
	brd_lbl.text = "Bracket Dimensions"
	brd_lbl.add_theme_color_override("font_color", C_TEXT_M)
	brd_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hw.add_child(brd_lbl)
	_bracket_w = _labeled_spin(hw, "Width (in)", 0.5, 6.0, 0.01, 2.0)
	_bracket_d = _labeled_spin(hw, "Depth (in)", 0.5, 6.0, 0.01, 3.0)
	_bracket_h = _labeled_spin(hw, "Height (in)", 0.5, 12.0, 0.1, 3.0)
	_bracket_wall = _labeled_spin(hw, "Wall Thickness (in)", 0.05, 1.0, 0.01, 0.25)
	_bracket_inner = _labeled_spin(hw, "Inner Width (in)", 0.25, 5.0, 0.01, 1.5)
	_bracket_hole_opt = _diameter_option(hw, "Hole Diameter", 0.375)
	_bracket_hole_dist = _labeled_spin(hw, "Hole Position (in)", 0.5, 12.0, 0.05, 1.5)
	var bolt_lbl := Label.new()
	bolt_lbl.text = "Bolt Configuration"
	bolt_lbl.add_theme_color_override("font_color", C_TEXT_M)
	bolt_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hw.add_child(bolt_lbl)
	_bolt_dia_opt = _diameter_option(hw, "Bolt Diameter", 0.375)
	_vbolt_row = VBoxContainer.new()
	hw.add_child(_vbolt_row)
	var vb := _auto_len_row(_vbolt_row, "V-Stack Bolt Length (in)", 3.0, true)
	_vbolt_len = vb[0]
	_vbolt_auto = vb[1]
	_vbolt_split_box = VBoxContainer.new()
	hw.add_child(_vbolt_split_box)
	var vbs_note := Label.new()
	vbs_note.text = "V-Stack has inner/outer bolt sizes (odd stack > 2)"
	vbs_note.add_theme_color_override("font_color", C_TEXT_M)
	vbs_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_vbolt_split_box.add_child(vbs_note)
	var vbi := _auto_len_row(_vbolt_split_box, "Inner Bolt / Long (in)", 3.0, true)
	_vbolt_inner_len = vbi[0]
	(vbi[1] as CheckBox).disabled = true
	var vbo := _auto_len_row(_vbolt_split_box, "Outer Bolt / Short (in)", 2.0, true)
	_vbolt_outer_len = vbo[0]
	(vbo[1] as CheckBox).disabled = true
	var hb := _auto_len_row(hw, "H-Center Bolt Length (in)", 3.0, true)
	_hbolt_len = hb[0]
	_hbolt_auto = hb[1]
	var hp := _auto_len_row(hw, "H-Pivot Bolt Length (in)", 4.0, true)
	_hpivot_len = hp[0]
	_hpivot_auto = hp[1]

	# Linkage geometry.
	var geo := _group(side, "Linkage Geometry", true)
	_pivot = _slider_spin(geo, "Pivot Position", "%", 20.0, 80.0, 0.1, 41.5, _on_param_changed_f)
	_pivot_ang = _slider_spin(geo, "Pivot Angle Offset", "°", -30.0, 30.0, 0.1, 0.0, _on_param_changed_f)
	_hoberman = _slider_spin(geo, "Hoberman Bend Angle", "°", -20.0, 20.0, 0.1, 0.0, _on_param_changed_f)

	_build_support_beams_group(side)
	_build_solar_panels_group(side)
	_build_radial_group(side)
	_build_floor_group(side)
	_build_coverings_group(side)
	_build_shade_group(side)

	# Animation / visibility settings.
	var anim := _group(side, "Animation Settings", true)
	_min_fold_spin = _labeled_spin(anim, "Min Fold Angle Override (°, -1 = auto)", -1.0, 175.0, 0.1, -1.0)
	_radial_vis = _slider_spin(anim, "Radial Beams Visible Above", "°", 0.0, 180.0, 1.0, 90.0, _on_param_changed_f)
	_rcp_vis = _slider_spin(anim, "RCP Beams Visible Above", "°", 0.0, 180.0, 1.0, 90.0, _on_param_changed_f)
	_panels_vis = _slider_spin(anim, "Panels Visible Above (-1 = deployed)", "°", -1.0, 180.0, 1.0, -1.0, _on_param_changed_f)

	# Presets.
	var pre := _group(side, "Presets", false)
	_preset_opt = OptionButton.new()
	_preset_opt.focus_mode = Control.FOCUS_NONE
	_preset_opt.add_item("— choose a preset —")
	for p in _presets:
		_preset_opt.add_item(str(p["name"]))
	_preset_opt.item_selected.connect(_on_preset_selected)
	pre.add_child(_preset_opt)

	return _panel_wrap(scroll)


# --- Support Beams group (radial S beams + simplified reciprocal beams) ---

func _build_support_beams_group(side: Control) -> void:
	var g := _group(side, "Support Beams", true)
	_sb["enabled"] = _check(g, "Enable Support Beams", true)
	_sb["show_radial"] = _check(g, "Show Radial Beams", true)
	_sb["length"] = _slider_spin(g, "Radial Beam Length", "in", 12.0, 240.0, 0.5, 120.0, _on_param_changed_f)
	_sb["width"] = _labeled_spin(g, "Radial Width (in)", 0.5, 6.0, 0.01, 1.5)
	_sb["thickness"] = _labeled_spin(g, "Radial Thickness (in)", 0.5, 6.0, 0.01, 3.5)
	_sb["offset_h"] = _slider_spin(g, "Radial Offset (in/out)", "in", -120.0, 120.0, 0.1, -46.5, _on_param_changed_f)
	_sb["offset_v"] = _slider_spin(g, "Radial Height Offset", "in", -24.0, 24.0, 0.1, -6.8, _on_param_changed_f)

	var rcp_lbl := Label.new()
	rcp_lbl.text = "Reciprocal (RCP) Beams"
	rcp_lbl.add_theme_color_override("font_color", C_TEXT_M)
	rcp_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(rcp_lbl)
	_sb["par_enabled"] = _check(g, "Enable Reciprocal Beams", true)
	_sb["par_length"] = _slider_spin(g, "RCP Beam Length", "in", 12.0, 240.0, 0.5, 96.0, _on_param_changed_f)
	_sb["par_width"] = _labeled_spin(g, "RCP Width (in)", 0.5, 6.0, 0.01, 2.5)
	_sb["par_thickness"] = _labeled_spin(g, "RCP Thickness (in)", 0.5, 6.0, 0.01, 1.5)
	_sb["par_swing"] = _slider_spin(g, "RCP Swing Angle", "°", -90.0, 90.0, 0.1, 0.0, _on_param_changed_f)
	_sb["anchor_dist"] = _slider_spin(g, "Anchor Distance", "in", 0.0, 96.0, 0.1, 20.0, _on_param_changed_f)
	_sb["par_v_offset"] = _labeled_spin(g, "A/B Vertical Offset (in)", -12.0, 12.0, 0.01, -1.66)
	_sb["par_offset_v"] = _labeled_spin(g, "RCP Height Offset (in)", -12.0, 12.0, 0.01, 4.5)
	_sb["rcp_end_offset"] = _labeled_spin(g, "RCP End Overhang (in)", 0.0, 48.0, 0.1, 0.0)


# --- Radial Array group (LinkageRadialArray, A3) ---

func _build_radial_group(side: Control) -> void:
	var g := _group(side, "Radial Array", true)
	var hint := Label.new()
	hint.text = "Copies of the whole structure round a centre: a honeycomb of rings, or arches sweeping a bent tunnel."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(hint)
	_ra["enabled"] = _check(g, "Enable Radial Array", false)
	_ra["count"] = _labeled_spin(g, "Copies Round The Ring", 1.0, 12.0, 1.0, 6.0)
	_ra["center"] = _check(g, "Keep A Copy At The Centre", true)
	_ra["rotateCopies"] = _check(g, "Rotate Each Copy With The Ring", true)
	_ra["radiusAuto"] = _check(g, "Auto Ring Radius (copies touch)", true)
	_ra["radius"] = _labeled_spin(g, "Ring Radius (in)", 0.0, 2000.0, 0.5, 0.0)
	_ra["spacing"] = _labeled_spin(g, "Extra Spacing (in)", -120.0, 480.0, 0.1, 0.0)
	_ra["startAngle"] = _labeled_spin(g, "Start Angle (°)", -180.0, 180.0, 0.5, 0.0)
	_ra["spin"] = _labeled_spin(g, "Spin Each Copy (°)", -180.0, 180.0, 0.5, 0.0)
	_ra["heightOffset"] = _labeled_spin(g, "Ring Height Offset (in)", -240.0, 240.0, 0.5, 0.0)
	_ra["sequential"] = _check(g, "Fold Copies One At A Time", false)
	var hl := Label.new()
	hl.text = "Hidden copies (slot numbers, e.g. 3, 5)"
	hl.add_theme_color_override("font_color", C_TEXT_S)
	hl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(hl)
	var le := LineEdit.new()
	le.placeholder_text = "none"
	le.text_submitted.connect(func(_t: String) -> void: _on_param_changed())
	le.focus_exited.connect(func() -> void: _on_param_changed())
	g.add_child(le)
	_ra["hiddenSlots"] = le
	_ra["readout"] = Label.new()
	(_ra["readout"] as Label).add_theme_color_override("font_color", C_TEXT_M)
	(_ra["readout"] as Label).add_theme_font_size_override("font_size", UITheme.FONT_XS)
	(_ra["readout"] as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	g.add_child(_ra["readout"])


func _read_radial_params() -> void:
	if _ra.is_empty():
		return
	var hidden: Array = []
	for bit in (_ra["hiddenSlots"] as LineEdit).text.replace(";", ",").split(",", false):
		var t := bit.strip_edges()
		if t.is_valid_int() and int(t) >= 0 and not hidden.has(int(t)):
			hidden.append(int(t))
	LinkageRadialArray.set_config(params, {
		"enabled": (_ra["enabled"] as CheckBox).button_pressed,
		"count": int((_ra["count"] as SpinBox).value),
		"center": (_ra["center"] as CheckBox).button_pressed,
		"rotateCopies": (_ra["rotateCopies"] as CheckBox).button_pressed,
		"radiusAuto": (_ra["radiusAuto"] as CheckBox).button_pressed,
		"radius": (_ra["radius"] as SpinBox).value,
		"spacing": (_ra["spacing"] as SpinBox).value,
		"startAngle": (_ra["startAngle"] as SpinBox).value,
		"spin": (_ra["spin"] as SpinBox).value,
		"heightOffset": (_ra["heightOffset"] as SpinBox).value,
		"hiddenSlots": hidden})
	LinkageFoldSequence.set_sequential(params, (_ra["sequential"] as CheckBox).button_pressed)


func _sync_radial_controls() -> void:
	if _ra.is_empty():
		return
	var c := LinkageRadialArray.config(params)
	(_ra["enabled"] as CheckBox).button_pressed = bool(c["enabled"])
	(_ra["count"] as SpinBox).value = int(c["count"])
	(_ra["center"] as CheckBox).button_pressed = bool(c["center"])
	(_ra["rotateCopies"] as CheckBox).button_pressed = bool(c["rotateCopies"])
	(_ra["radiusAuto"] as CheckBox).button_pressed = bool(c["radiusAuto"])
	(_ra["radius"] as SpinBox).value = float(c["radius"])
	(_ra["spacing"] as SpinBox).value = float(c["spacing"])
	(_ra["startAngle"] as SpinBox).value = float(c["startAngle"])
	(_ra["spin"] as SpinBox).value = float(c["spin"])
	(_ra["heightOffset"] as SpinBox).value = float(c["heightOffset"])
	var hs: PackedStringArray = []
	for v in c["hiddenSlots"]:
		hs.append(str(int(v)))
	(_ra["hiddenSlots"] as LineEdit).text = ", ".join(hs)
	(_ra["sequential"] as CheckBox).button_pressed = LinkageFoldSequence.is_sequential(params)
	_update_radial_readout()


func _update_radial_readout() -> void:
	if _ra.is_empty():
		return
	var pl := LinkageRadialArray.deployed_plan(params)
	var lbl := _ra["readout"] as Label
	if pl.is_empty():
		lbl.text = "Off — a single structure."
		return
	lbl.text = "%s drawn (%d planned, slots 0–%d) · ring radius %s · pattern across %s" % [
		UiText.count(int(pl["visible_count"]), "copy"), (pl["slots"] as Array).size(), (pl["slots"] as Array).size() - 1,
		_fmt_len(float(pl["radius"])),
		_fmt_len(2.0 * float((_builder.last_frame() if _builder != null else {}).get("max_rad", 0.0)))]
	var sc: Dictionary = _builder.fold_schedule() if _builder != null else {}
	if not sc.is_empty():
		var moving := int(sc["active_index"])
		lbl.text += "\nFolding one at a time: %s %s" % [
			str((sc["copies"] as Array)[moving]["label"]) if moving >= 0 else "—",
			"moving" if moving >= 0 and float(sc["copies"][moving]["progress"]) > 0.0
				and float(sc["copies"][moving]["progress"]) < 1.0 else "(at rest)"]


# --- Enclosure groups (A4): raised floor, coverings, shade tarps ---

func _hint(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", C_TEXT_M)
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	parent.add_child(l)


## A labelled dropdown whose items carry ids: items = [[id, label], ...].
func _choice(parent: Control, label: String, items: Array) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	for i in items.size():
		opt.add_item(str(items[i][1]))
		opt.set_item_metadata(i, items[i][0])
	opt.item_selected.connect(func(_i: int) -> void: _on_param_changed())
	row.add_child(opt)
	return opt


static func _choice_id(opt: OptionButton) -> String:
	return str(opt.get_item_metadata(opt.selected)) if opt.selected >= 0 else ""


static func _choice_set(opt: OptionButton, id: String) -> void:
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == id:
			opt.select(i)
			return


func _build_floor_group(side: Control) -> void:
	var g := _group(side, "Raised Floor", true)
	_hint(g, "Reciprocal floor beams on the bottom ring and a plywood deck on top (cylinder mode).")
	_fl["enabled"] = _check(g, "Enable Raised Floor", false)
	_fl["parallelEnabled"] = _check(g, "Reciprocal Floor Beams", true)
	_fl["parallelLength"] = _labeled_spin(g, "Floor Beam Length (in)", 1.0, 2400.0, 0.5, 96.0)
	_fl["parallelWidth"] = _labeled_spin(g, "Floor Beam Width (in)", 0.25, 48.0, 0.125, 2.5)
	_fl["parallelThickness"] = _labeled_spin(g, "Floor Beam Thickness (in)", 0.25, 48.0, 0.125, 1.5)
	_fl["parallelSwingAngle"] = _labeled_spin(g, "Swing Angle (°)", -360.0, 360.0, 0.5, 0.0)
	_fl["anchorDist"] = _labeled_spin(g, "Anchor Along Leg (in)", -1200.0, 1200.0, 0.25, 20.0)
	_fl["parallelOffsetV"] = _labeled_spin(g, "Vertical Shift (in)", -1200.0, 1200.0, 0.125, 0.0)
	_fl["seat"] = _choice(g, "Seat", [["leg", "On each scissor leg"], ["ringTop", "On the ring's top face"]])
	_fl["radialEnabled"] = _check(g, "Radial Floor Beams", false)
	_fl["deck"] = _check(g, "Plywood Deck", true)
	_fl["deckThickness"] = _labeled_spin(g, "Deck Thickness (in)", 0.125, 6.0, 0.0625, 0.75)
	_fl["deckInset"] = _labeled_spin(g, "Deck Inset (in)", -100.0, 100.0, 0.125, 0.5)
	_fl["showBeams"] = _check(g, "Show Floor Beams", true)
	_fl["showDeck"] = _check(g, "Show Deck", true)


func _build_coverings_group(side: Control) -> void:
	var g := _group(side, "Coverings (Walls / Tables / Fabric)", true)
	_hint(g, "Plywood or fabric between the uprights, in a lower and an upper band, with optional tables (cylinder mode).")
	_cv["enabled"] = _check(g, "Enable Coverings", false)
	var leans := [["inward", "Follow inward beams"], ["outward", "Follow outward beams"], ["vertical", "Vertical"], ["custom", "Custom tilt"]]
	_cv["lowerLean"] = _choice(g, "Lower Band Lean", leans)
	_cv["upperLean"] = _choice(g, "Upper Band Lean", leans)
	_cv["splitHeightIn"] = _labeled_spin(g, "Split Height (in)", -1200.0, 1200.0, 0.25, 48.0)
	_cv["bottomIn"] = _labeled_spin(g, "Bottom (in)", -1200.0, 1200.0, 0.25, 0.0)
	_cv["bottomMode"] = _choice(g, "Bottom From", [["ground", "The ground"], ["floor", "The floor deck"]])
	_cv["mount"] = _choice(g, "Mount", [["outside", "Outside the beams"], ["centerline", "On the centreline"], ["inside", "Inside the beams"]])
	_cv["sheet"] = _choice(g, "Sheet Stock", [["4x8", "4 × 8 ft"], ["5x5", "5 × 5 ft"], ["4x10", "4 × 10 ft"]])
	_cv["sheetThickness"] = _labeled_spin(g, "Sheet Thickness (in)", 0.125, 3.0, 0.0625, 0.5)
	_cv["tableDepth"] = _labeled_spin(g, "Table Depth (in)", 1.0, 240.0, 0.5, 24.0)
	var all_row := HBoxContainer.new()
	all_row.add_theme_constant_override("separation", 4)
	g.add_child(all_row)
	var all_lbl := Label.new()
	all_lbl.text = "Every span:"
	all_lbl.add_theme_color_override("font_color", C_TEXT_S)
	all_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	all_row.add_child(all_lbl)
	for pair in [["Plywood", "plywood"], ["Fabric", "fabric"], ["Clear", "none"]]:
		var b := Button.new()
		b.text = pair[0]
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		UITheme.style_button(b)
		var kind: String = pair[1]
		b.pressed.connect(func() -> void: _set_all_spans(kind))
		all_row.add_child(b)
	_cv["spans_box"] = VBoxContainer.new()
	g.add_child(_cv["spans_box"])
	_cv["readout"] = Label.new()
	(_cv["readout"] as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(_cv["readout"] as Label).add_theme_color_override("font_color", C_TEXT_M)
	(_cv["readout"] as Label).add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(_cv["readout"])


func _build_shade_group(side: Control) -> void:
	var g := _group(side, "Roof Shade Tarps", true)
	_hint(g, "One tarp per module, laid from the outer pivots toward the centre, overlapping in the middle.")
	_sh["enabled"] = _check(g, "Enable Shade Tarps", false)
	_sh["widthMode"] = _choice(g, "Width", [["auto", "Outer pivot distance"], ["custom", "Custom"]])
	_sh["widthIn"] = _labeled_spin(g, "Custom Width (in)", 1.0, 2400.0, 0.5, 120.0)
	_sh["widthTrimIn"] = _labeled_spin(g, "Width Trim (in)", -1200.0, 1200.0, 0.25, 0.0)
	_sh["lengthMode"] = _choice(g, "Length", [["auto", "Edge to centre + overlap"], ["custom", "Custom"]])
	_sh["lengthIn"] = _labeled_spin(g, "Custom Length (in)", 1.0, 2400.0, 0.5, 240.0)
	_sh["centerOverlapIn"] = _labeled_spin(g, "Centre Overlap (in)", -1200.0, 1200.0, 0.5, 12.0)
	_sh["overhangIn"] = _labeled_spin(g, "Overhang (in)", -1200.0, 1200.0, 0.5, 6.0)
	_sh["rotationDeg"] = _labeled_spin(g, "Rotate Array (°)", -360.0, 360.0, 0.5, 0.0)
	_sh["staggerIn"] = _labeled_spin(g, "Lift Every Second (in)", -1200.0, 1200.0, 0.25, 0.0)
	_sh["liftIn"] = _labeled_spin(g, "Lift (in)", -1200.0, 1200.0, 0.25, 2.0)
	var sw: Array = []
	for d in LinkageShadeCloth.SWATCHES:
		sw.append([d["color"], d["name"]])
	_sh["color"] = _choice(g, "Colour", sw)
	_sh["opacity"] = _labeled_spin(g, "Opacity", 0.05, 1.0, 0.05, 0.75)
	_sh["readout"] = Label.new()
	(_sh["readout"] as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(_sh["readout"] as Label).add_theme_color_override("font_color", C_TEXT_M)
	(_sh["readout"] as Label).add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(_sh["readout"])


## One row per span: lower / upper cover + a table.
func _rebuild_span_rows(n: int) -> void:
	var box := _cv.get("spans_box") as VBoxContainer
	if box == null:
		return
	if _span_rows.size() == n:
		return
	for c in box.get_children():
		c.queue_free()
	_span_rows.clear()
	var covers := [["none", "—"], ["plywood", "Plywood"], ["fabric", "Fabric"]]
	for i in n:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		box.add_child(row)
		var lbl := Label.new()
		lbl.text = "Span %d" % (i + 1)
		lbl.custom_minimum_size.x = 52
		lbl.add_theme_color_override("font_color", C_TEXT_S)
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		row.add_child(lbl)
		var lower := OptionButton.new()
		var upper := OptionButton.new()
		for opt in [lower, upper]:
			opt.focus_mode = Control.FOCUS_NONE
			opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			for j in covers.size():
				opt.add_item(str(covers[j][1]))
				opt.set_item_metadata(j, covers[j][0])
			opt.item_selected.connect(func(_k: int) -> void: _on_param_changed())
			row.add_child(opt)
		lower.tooltip_text = "Lower band"
		upper.tooltip_text = "Upper band"
		var table := CheckBox.new()
		table.text = "Table"
		table.focus_mode = Control.FOCUS_NONE
		table.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		table.toggled.connect(func(_p: bool) -> void: _on_param_changed())
		row.add_child(table)
		_span_rows.append({"lower": lower, "upper": upper, "table": table})


func _set_all_spans(kind: String) -> void:
	if not (_cv["enabled"] as CheckBox).button_pressed:
		(_cv["enabled"] as CheckBox).set_pressed_no_signal(true)
	for r in _span_rows:
		_choice_set(r["lower"], kind)
		_choice_set(r["upper"], "none" if kind == "none" else kind)
	_on_param_changed()


## Write the controls into the config, over the normalised current values
## so keys the UI does not show survive. A design that never had a feature
## and leaves it at its defaults gets no key written.
func _read_enclosure_params() -> void:
	if _fl.is_empty():
		return
	var fl := LinkageFloor.config(params)
	fl["enabled"] = (_fl["enabled"] as CheckBox).button_pressed
	var fb: Dictionary = fl["beams"]
	fb["parallelEnabled"] = (_fl["parallelEnabled"] as CheckBox).button_pressed
	for k in ["parallelLength", "parallelWidth", "parallelThickness", "parallelSwingAngle", "anchorDist", "parallelOffsetV"]:
		fb[k] = (_fl[k] as SpinBox).value
	fb["seat"] = _choice_id(_fl["seat"])
	fb["radialEnabled"] = (_fl["radialEnabled"] as CheckBox).button_pressed
	fl["deck"]["enabled"] = (_fl["deck"] as CheckBox).button_pressed
	fl["deck"]["thicknessIn"] = (_fl["deckThickness"] as SpinBox).value
	fl["deck"]["insetIn"] = (_fl["deckInset"] as SpinBox).value
	fl["visibility"] = {"beams": (_fl["showBeams"] as CheckBox).button_pressed, "deck": (_fl["showDeck"] as CheckBox).button_pressed}
	_store_feature("floor", fl, LinkageFloor.normalize(null), func(c): LinkageFloor.set_config(params, c))

	var cv := LinkageCoverings.config(params)
	cv["enabled"] = (_cv["enabled"] as CheckBox).button_pressed
	for k in ["lowerLean", "upperLean", "bottomMode", "mount"]:
		cv[k] = _choice_id(_cv[k])
	cv["splitHeightIn"] = (_cv["splitHeightIn"] as SpinBox).value
	cv["bottomIn"] = (_cv["bottomIn"] as SpinBox).value
	var preset: Dictionary = LinkageCoverings.SHEET_PRESETS.get(_choice_id(_cv["sheet"]), {})
	if not preset.is_empty():
		cv["sheet"]["widthIn"] = float(preset["widthIn"])
		cv["sheet"]["lengthIn"] = float(preset["lengthIn"])
	cv["sheet"]["thicknessIn"] = (_cv["sheetThickness"] as SpinBox).value
	cv["table"]["depthIn"] = (_cv["tableDepth"] as SpinBox).value
	var spans: Array = []
	for r in _span_rows:
		spans.append({"lower": _choice_id(r["lower"]), "upper": _choice_id(r["upper"]),
			"table": (r["table"] as CheckBox).button_pressed})
	if not spans.is_empty():
		cv["spans"] = spans
	_store_feature("coverings", cv, LinkageCoverings.normalize(null, params.modules), func(c): LinkageCoverings.set_config(params, c))

	var sh := LinkageShadeCloth.config(params)
	sh["enabled"] = (_sh["enabled"] as CheckBox).button_pressed
	sh["widthMode"] = _choice_id(_sh["widthMode"])
	sh["lengthMode"] = _choice_id(_sh["lengthMode"])
	for k in ["widthIn", "widthTrimIn", "lengthIn", "centerOverlapIn", "overhangIn", "rotationDeg", "staggerIn", "liftIn", "opacity"]:
		sh[k] = (_sh[k] as SpinBox).value
	sh["color"] = _choice_id(_sh["color"])
	_store_feature("shadeCloth", sh, LinkageShadeCloth.normalize(null), func(c): LinkageShadeCloth.set_config(params, c))


func _store_feature(key: String, cfg: Dictionary, defaults: Dictionary, setter: Callable) -> void:
	if not params.extra.has(key) and JSON.stringify(cfg) == JSON.stringify(defaults):
		return
	setter.call(cfg)


func _sync_enclosure_controls() -> void:
	if _fl.is_empty():
		return
	var fl := LinkageFloor.config(params)
	var fb: Dictionary = fl["beams"]
	(_fl["enabled"] as CheckBox).button_pressed = bool(fl["enabled"])
	(_fl["parallelEnabled"] as CheckBox).button_pressed = bool(fb["parallelEnabled"])
	for k in ["parallelLength", "parallelWidth", "parallelThickness", "parallelSwingAngle", "anchorDist", "parallelOffsetV"]:
		(_fl[k] as SpinBox).value = float(fb[k])
	_choice_set(_fl["seat"], str(fb["seat"]))
	(_fl["radialEnabled"] as CheckBox).button_pressed = bool(fb["radialEnabled"])
	(_fl["deck"] as CheckBox).button_pressed = bool(fl["deck"]["enabled"])
	(_fl["deckThickness"] as SpinBox).value = float(fl["deck"]["thicknessIn"])
	(_fl["deckInset"] as SpinBox).value = float(fl["deck"]["insetIn"])
	(_fl["showBeams"] as CheckBox).button_pressed = bool(fl["visibility"]["beams"])
	(_fl["showDeck"] as CheckBox).button_pressed = bool(fl["visibility"]["deck"])

	var cv := LinkageCoverings.config(params)
	(_cv["enabled"] as CheckBox).button_pressed = bool(cv["enabled"])
	for k in ["lowerLean", "upperLean", "bottomMode", "mount"]:
		_choice_set(_cv[k], str(cv[k]))
	(_cv["splitHeightIn"] as SpinBox).value = float(cv["splitHeightIn"])
	(_cv["bottomIn"] as SpinBox).value = float(cv["bottomIn"])
	var sheet_id := "4x8"
	for pid in LinkageCoverings.SHEET_PRESETS:
		var ps: Dictionary = LinkageCoverings.SHEET_PRESETS[pid]
		if is_equal_approx(float(ps["widthIn"]), float(cv["sheet"]["widthIn"])) and is_equal_approx(float(ps["lengthIn"]), float(cv["sheet"]["lengthIn"])):
			sheet_id = pid
	_choice_set(_cv["sheet"], sheet_id)
	(_cv["sheetThickness"] as SpinBox).value = float(cv["sheet"]["thicknessIn"])
	(_cv["tableDepth"] as SpinBox).value = float(cv["table"]["depthIn"])
	_rebuild_span_rows(params.modules)
	for i in _span_rows.size():
		var sp: Dictionary = cv["spans"][i] if i < (cv["spans"] as Array).size() else LinkageCoverings.default_span()
		_choice_set(_span_rows[i]["lower"], str(sp["lower"]))
		_choice_set(_span_rows[i]["upper"], str(sp["upper"]))
		(_span_rows[i]["table"] as CheckBox).set_pressed_no_signal(bool(sp["table"]))

	var sh := LinkageShadeCloth.config(params)
	(_sh["enabled"] as CheckBox).button_pressed = bool(sh["enabled"])
	_choice_set(_sh["widthMode"], str(sh["widthMode"]))
	_choice_set(_sh["lengthMode"], str(sh["lengthMode"]))
	for k in ["widthIn", "widthTrimIn", "lengthIn", "centerOverlapIn", "overhangIn", "rotationDeg", "staggerIn", "liftIn", "opacity"]:
		(_sh[k] as SpinBox).value = float(sh[k])
	_choice_set(_sh["color"], str(sh["color"]))
	_update_enclosure_readout()


func _update_enclosure_readout() -> void:
	if _cv.is_empty() or _builder == null:
		return
	var walls: Array = _builder.last_walls()
	var n_wall := 0
	var n_fab := 0
	var n_table := 0
	var n_tarp := 0
	for w in walls:
		match str(w.get("kind", "")):
			"wall":
				if str(w.get("band", "")) != "floor":
					n_wall += 1
			"fabric":
				n_fab += 1
			"table":
				n_table += 1
			"shade":
				n_tarp += 1
	var cv := LinkageCoverings.config(params)
	if params.orientation == "vertical" and (bool(cv["enabled"]) or bool(LinkageShadeCloth.config(params)["enabled"])):
		(_cv["readout"] as Label).text = "Coverings and tarps are cylinder-mode only."
	else:
		(_cv["readout"] as Label).text = "%d plywood wall%s · %d fabric band%s · %d table%s drawn" % [
			n_wall, "" if n_wall == 1 else "s", n_fab, "" if n_fab == 1 else "s", n_table, "" if n_table == 1 else "s"]
	(_sh["readout"] as Label).text = "%d tarp%s drawn" % [n_tarp, "" if n_tarp == 1 else "s"]


# --- Solar Panels group (full layout system) ---

func _build_solar_panels_group(side: Control) -> void:
	var g := _group(side, "Solar Panels", true)
	_sp_enabled = _check(g, "Enable Solar Panels", false)

	var layout_lbl := Label.new()
	layout_lbl.text = "Layout Mode (cylinder top)"
	layout_lbl.add_theme_color_override("font_color", C_TEXT_S)
	layout_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(layout_lbl)
	_sp_layout = OptionButton.new()
	_sp_layout.focus_mode = Control.FOCUS_NONE
	_sp_layout.add_item("Rectangular Grid")
	_sp_layout.add_item("Radial / Pinwheel")
	_sp_layout.add_item("Spiral")
	_sp_layout.item_selected.connect(func(_i: int) -> void: _on_param_changed())
	g.add_child(_sp_layout)

	_sp_top = _panel_section_controls(g, "Top Panels", true)
	_sp_side = _panel_section_controls(g, "Side / Wall Panels", false)

	# Rectangular layout controls.
	_sp_rect_box = VBoxContainer.new()
	g.add_child(_sp_rect_box)
	_sp_grid_rot = _slider_spin(_sp_rect_box, "Grid Rotation", "°", -180.0, 180.0, 0.5, 0.0, _on_param_changed_f)

	# Radial layout controls (shared with spiral primaries).
	_sp_radial_box = VBoxContainer.new()
	g.add_child(_sp_radial_box)
	_sp_radial["count"] = _labeled_spin(_sp_radial_box, "Radial Panel Count", 1.0, 40.0, 1.0, 8.0)
	_sp_radial["offset"] = _slider_spin(_sp_radial_box, "Radial Distance (0 = auto)", "in", 0.0, 300.0, 0.5, 0.0, _on_param_changed_f)
	_sp_radial["rotation"] = _slider_spin(_sp_radial_box, "Pattern Rotation", "°", -180.0, 180.0, 0.5, 0.0, _on_param_changed_f)
	_sp_radial["lateral"] = _slider_spin(_sp_radial_box, "Lateral Offset", "in", -120.0, 120.0, 0.5, 0.0, _on_param_changed_f)
	_sp_radial["pinwheel"] = _slider_spin(_sp_radial_box, "Pinwheel Angle", "°", -90.0, 90.0, 0.5, 0.0, _on_param_changed_f)

	# Spiral-only arm controls.
	_sp_spiral_box = VBoxContainer.new()
	g.add_child(_sp_spiral_box)
	_sp_spiral["arm_count"] = _labeled_spin(_sp_spiral_box, "Panels Per Arm", 2.0, 8.0, 1.0, 2.0)
	_sp_spiral["sec_enabled"] = _check(_sp_spiral_box, "Secondary Panels", true)
	_sp_spiral["sec_radial"] = _labeled_spin(_sp_spiral_box, "Secondary Radial Offset (in)", -120.0, 120.0, 0.5, 24.0)
	_sp_spiral["sec_lateral"] = _labeled_spin(_sp_spiral_box, "Secondary Lateral Offset (in)", -120.0, 120.0, 0.5, 0.0)
	_sp_spiral["sec_pinwheel"] = _labeled_spin(_sp_spiral_box, "Secondary Pinwheel (°)", -90.0, 90.0, 0.5, 0.0)
	_sp_spiral["sec_rotation"] = _labeled_spin(_sp_spiral_box, "Secondary Rotation (°)", -180.0, 180.0, 0.5, 0.0)
	_sp_spiral["step_radial"] = _labeled_spin(_sp_spiral_box, "Arm Radial Step (in)", -60.0, 60.0, 0.5, 0.0)
	_sp_spiral["step_lateral"] = _labeled_spin(_sp_spiral_box, "Arm Lateral Step (in)", -60.0, 60.0, 0.5, 0.0)
	_sp_spiral["step_pinwheel"] = _labeled_spin(_sp_spiral_box, "Arm Pinwheel Step (°)", -90.0, 90.0, 0.5, 0.0)
	_sp_spiral["step_rotation"] = _labeled_spin(_sp_spiral_box, "Arm Rotation Step (°)", -90.0, 90.0, 0.5, 0.0)

	# Face-mounted positioning (arch faces + cylinder side walls).
	var pos_lbl := Label.new()
	pos_lbl.text = "Wall/Face Panel Positioning"
	pos_lbl.add_theme_color_override("font_color", C_TEXT_M)
	pos_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	g.add_child(pos_lbl)
	_sp_pos["lift"] = _labeled_spin(g, "Lift Off Face (in)", -12.0, 24.0, 0.1, 2.0)
	_sp_pos["slide"] = _labeled_spin(g, "Slide Along Face (in)", -60.0, 60.0, 0.1, 0.5)
	_sp_pos["separation"] = _labeled_spin(g, "Separation (in)", -60.0, 60.0, 0.1, 0.0)

	# Arch wall-face toggles (rebuilt per module count; arch mode only).
	_faces_box = VBoxContainer.new()
	g.add_child(_faces_box)
	var faces_lbl := Label.new()
	faces_lbl.text = "Wall Faces (2 per module)"
	faces_lbl.add_theme_color_override("font_color", C_TEXT_M)
	faces_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_faces_box.add_child(faces_lbl)
	_faces_grid = GridContainer.new()
	_faces_grid.columns = 4
	_faces_box.add_child(_faces_grid)


## One panel-spec sub-section (top or side) — enabled, dims, electrical,
## padding, grid, lift.
func _panel_section_controls(parent: Control, title: String, enabled: bool) -> Dictionary:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_color_override("font_color", C_TEXT_M)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	parent.add_child(lbl)
	var c: Dictionary = {}
	c["enabled"] = _check(parent, "Enabled", enabled)
	c["length"] = _labeled_spin(parent, "Panel Length (in)", 4.0, 120.0, 0.05, 65.0)
	c["width"] = _labeled_spin(parent, "Panel Width (in)", 4.0, 120.0, 0.05, 39.0)
	c["thickness"] = _labeled_spin(parent, "Panel Thickness (in)", 0.1, 6.0, 0.05, 1.5)
	c["watts"] = _labeled_spin(parent, "Rated Watts (Wmp)", 5.0, 1000.0, 1.0, 250.0)
	c["voc"] = _labeled_spin(parent, "Voc (V)", 1.0, 100.0, 0.1, 37.5)
	c["vmp"] = _labeled_spin(parent, "Vmp (V)", 1.0, 100.0, 0.1, 31.2)
	c["isc"] = _labeled_spin(parent, "Isc (A)", 0.1, 30.0, 0.1, 8.8)
	c["imp"] = _labeled_spin(parent, "Imp (A)", 0.1, 30.0, 0.1, 8.1)
	c["pad_x"] = _labeled_spin(parent, "Padding X (in)", -12.0, 24.0, 0.1, 2.0)
	c["pad_y"] = _labeled_spin(parent, "Padding Y (in)", -12.0, 24.0, 0.1, 2.0)
	c["rows"] = _labeled_spin(parent, "Grid Rows", 1.0, 12.0, 1.0, 2.0)
	c["cols"] = _labeled_spin(parent, "Grid Cols", 1.0, 12.0, 1.0, 2.0)
	c["lift"] = _labeled_spin(parent, "Lift (in)", -24.0, 48.0, 0.1, 0.0)
	return c


## Rebuild the arch wall-face checkbox grid for the current module count.
func _rebuild_face_toggles() -> void:
	if _faces_grid == null:
		return
	for child in _faces_grid.get_children():
		child.free()
	var num_faces := params.modules * 2
	var stored: Array = params.solar_panels["arch_wall_faces"]
	if stored.size() != num_faces:
		stored = []
	for i in range(num_faces):
		var chk := CheckBox.new()
		chk.text = str(i + 1)
		chk.button_pressed = bool(stored[i]) if not stored.is_empty() else true
		chk.focus_mode = Control.FOCUS_NONE
		chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		var face_idx := i
		chk.toggled.connect(func(on: bool) -> void:
			if _suppress:
				return
			_set_face_enabled(face_idx, on))
		_faces_grid.add_child(chk)


func _set_face_enabled(face_idx: int, on: bool) -> void:
	var num_faces := params.modules * 2
	var faces: Array = params.solar_panels["arch_wall_faces"]
	if faces.size() != num_faces:
		faces = []
		for i in range(num_faces):
			faces.append(true)
	if face_idx < faces.size():
		faces[face_idx] = on
	params.solar_panels["arch_wall_faces"] = faces
	_rebuild_pending = true
	_rebuild_timer = REBUILD_DEBOUNCE_S


func _group(parent: Control, title: String, collapsed: bool) -> VBoxContainer:
	# Card wrapper so each parameter group reads as a distinct, framed section.
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _group_card_style())
	parent.add_child(card)
	var sec := Collapsible.make(title, not collapsed)
	card.add_child(sec)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 8)
	pad.add_theme_constant_override("margin_right", 6)
	pad.add_theme_constant_override("margin_top", 2)
	pad.add_theme_constant_override("margin_bottom", 6)
	pad.add_child(content)
	sec.body.add_child(pad)
	return content


func _group_card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.55)
	sb.set_corner_radius_all(6)
	sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
	sb.set_border_width_all(1)
	sb.content_margin_left = 2.0
	sb.content_margin_right = 2.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	return sb


func _slider_spin(parent: Control, label: String, unit: String, mn: float, mx: float,
		step: float, val: float, cb: Callable) -> Dictionary:
	var head := HBoxContainer.new()
	parent.add_child(head)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	if not unit.is_empty():
		var ulbl := Label.new()
		ulbl.text = unit
		ulbl.add_theme_color_override("font_color", C_TEXT_M)
		ulbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		head.add_child(ulbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	row.add_child(sl)
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	sp.value = val
	sp.custom_minimum_size.x = 78
	row.add_child(sp)
	sl.value_changed.connect(func(v: float) -> void:
		if _suppress:
			return
		_suppress = true
		sp.value = v
		_suppress = false
		cb.call(v))
	sp.value_changed.connect(func(v: float) -> void:
		if _suppress:
			return
		_suppress = true
		sl.value = v
		_suppress = false
		cb.call(v))
	return {"slider": sl, "spin": sp}


func _wt_row(parent: Control, label: String) -> Array:
	if not label.is_empty():
		var lbl := Label.new()
		lbl.text = label
		lbl.add_theme_color_override("font_color", C_TEXT_S)
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		parent.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var w := SpinBox.new()
	w.min_value = 0.5
	w.max_value = 12.0
	w.step = 0.01
	w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	w.value_changed.connect(func(_v: float) -> void: _on_param_changed())
	row.add_child(w)
	var x := Label.new()
	x.text = "x"
	x.add_theme_color_override("font_color", C_TEXT_M)
	row.add_child(x)
	var t := SpinBox.new()
	t.min_value = 0.5
	t.max_value = 12.0
	t.step = 0.01
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.value_changed.connect(func(_v: float) -> void: _on_param_changed())
	row.add_child(t)
	return [w, t]


## Label + [slider][spinbox] control returning the SpinBox (source of truth,
## so all callers keep using `.value`). The slider mirrors it bidirectionally;
## setting `.value` externally (e.g. from _sync_controls) drags the slider along
## without re-firing the param callback (a private echo guard, independent of
## the shared _suppress flag).
func _labeled_spin(parent: Control, label: String, mn: float, mx: float, step: float,
		val: float) -> SpinBox:
	var head := HBoxContainer.new()
	parent.add_child(head)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value = clampf(val, mn, mx)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	row.add_child(sl)
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	sp.value = val
	sp.custom_minimum_size.x = 78
	row.add_child(sp)
	var echo := [false]
	sl.value_changed.connect(func(v: float) -> void:
		if echo[0]:
			return
		echo[0] = true
		sp.value = v
		echo[0] = false
		if not _suppress:
			_on_param_changed())
	sp.value_changed.connect(func(v: float) -> void:
		if echo[0]:
			return
		echo[0] = true
		sl.value = v
		echo[0] = false
		if not _suppress:
			_on_param_changed())
	return sp


func _auto_len_row(parent: Control, label: String, val: float, auto_on: bool) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var sp := SpinBox.new()
	sp.min_value = 1.0
	sp.max_value = 12.0
	sp.step = 0.25
	sp.value = val
	sp.custom_minimum_size.x = 72
	sp.editable = not auto_on
	sp.value_changed.connect(func(_v: float) -> void: _on_param_changed())
	row.add_child(sp)
	var chk := CheckBox.new()
	chk.text = "Auto"
	chk.button_pressed = auto_on
	chk.focus_mode = Control.FOCUS_NONE
	chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	chk.toggled.connect(func(on: bool) -> void:
		sp.editable = not on
		_on_param_changed())
	row.add_child(chk)
	return [sp, chk]


func _diameter_option(parent: Control, label: String, current: float) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	for i in DIAMETER_OPTIONS.size():
		opt.add_item(DIAMETER_LABELS[i])
		opt.set_item_metadata(i, DIAMETER_OPTIONS[i])
		if absf(float(DIAMETER_OPTIONS[i]) - current) < 1e-6:
			opt.select(i)
	opt.item_selected.connect(func(_i: int) -> void: _on_param_changed())
	row.add_child(opt)
	return opt


func _check(parent: Control, label: String, on: bool) -> CheckBox:
	var chk := CheckBox.new()
	chk.text = label
	chk.button_pressed = on
	chk.focus_mode = Control.FOCUS_NONE
	chk.add_theme_color_override("font_color", C_TEXT)
	chk.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	chk.toggled.connect(func(_p: bool) -> void: _on_param_changed())
	parent.add_child(chk)
	return chk


# --- Center studio viewport ---

func _build_center() -> Control:
	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_container.gui_input.connect(_on_viewport_input)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(900, 700)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_viewport.own_world_3d = true
	vp_container.add_child(_viewport)
	_build_studio_world()
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	col.add_child(vp_container)
	_steps_panel = STEPS_PANEL_SCRIPT.new()
	_steps_panel.name = "StepsPanel"
	_steps_panel.call("bind", self)
	col.add_child(_steps_panel)
	return col


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	# Deep near-black studio backdrop, matching the original LinkageLab viewport.
	e.background_color = Color(0.035, 0.043, 0.063)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.56, 0.62)
	e.ambient_light_energy = 0.55
	# Subtle depth: darken far geometry into the backdrop instead of a hard edge.
	e.fog_enabled = true
	e.fog_light_color = Color(0.035, 0.043, 0.063)
	e.fog_light_energy = 1.0
	e.fog_density = 0.0018
	env.environment = e
	_studio.add_child(env)
	_sun_light = DirectionalLight3D.new()
	_sun_light.light_energy = 1.2
	_sun_light.shadow_enabled = true
	_studio.add_child(_sun_light)
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
	_builder = LinkageStructureBuilder.new()
	_builder.name = "Linkage"
	_holder.add_child(_builder)
	_camera = Camera3D.new()
	_camera.far = 800.0
	_studio.add_child(_camera)
	_update_camera()
	_update_sun()


func _on_viewport_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(1.5, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(300.0, _dist * 1.1)
			_update_camera()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _orbiting:
			_yaw -= mm.relative.x * 0.01
			_pitch = clampf(_pitch - mm.relative.y * 0.01, -0.2, 1.45)
			_update_camera()
		elif _panning:
			var right := Vector3(cos(_yaw), 0, -sin(_yaw))
			var fwd := Vector3(-sin(_yaw), 0, -cos(_yaw))
			var k := _dist * 0.0016
			_target += right * (-mm.relative.x * k) + fwd * (mm.relative.y * k)
			_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(
		_dist * cos(_pitch) * sin(_yaw),
		maxf(_dist * sin(_pitch), 0.2),
		_dist * cos(_pitch) * cos(_yaw))
	# look_at_from_position works before the camera enters the tree (look_at
	# does not — errors during _ready/headless construction).
	_camera.look_at_from_position(_target + cp, _target)


func _update_sun() -> void:
	if _sun_light == null:
		return
	var t := float(_sun_slider.value) / 100.0 if _sun_slider != null else 0.5
	# Sunrise (east, t=0) → sunset (west, t=1); elevation arc peaks at 62 deg.
	var azimuth := lerpf(90.0, 270.0, t)
	var elevation := sin(t * PI) * 62.0 + 4.0
	_sun_light.rotation_degrees = Vector3(-elevation, 180.0 - azimuth, 0.0)
	_sun_light.light_energy = clampf(0.25 + sin(t * PI) * 1.05, 0.25, 1.3)
	if _sun_lbl != null:
		var hour := 6.0 + t * 12.0
		_sun_lbl.text = "%02d:%02d" % [int(hour), int(fmod(hour, 1.0) * 60.0)]


# --- Right panel: ortho insets + stats HUD ---

func _build_right_panel() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = RIGHT_W
	box.add_theme_constant_override("separation", 6)

	var top_pack := _ortho_inset("Top View")
	box.add_child(top_pack[0])
	_top_vp = top_pack[1]
	_top_cam = top_pack[2]

	var side_pack := _ortho_inset("Side View")
	box.add_child(side_pack[0])
	_side_vp = side_pack[1]
	_side_cam = side_pack[2]

	var stats := VBoxContainer.new()
	stats.add_theme_constant_override("separation", 2)
	stats.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stats.add_child(SectionHeader.make("Dimensions & Structure"))
	for key in ["Height", "Diameter", "Modules", "Beams", "Support Beams",
			"Brackets", "Bolts", "Panels", "Array Watts",
			"Fold Angle", "Closed Angle", "Min Fold",
			"Packed Size", "Packed Wt"]:
		var row := HBoxContainer.new()
		stats.add_child(row)
		var k := Label.new()
		k.text = key
		k.add_theme_color_override("font_color", C_TEXT_S)
		k.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(k)
		var v := Label.new()
		v.text = "—"
		v.add_theme_color_override("font_color", C_TEXT)
		v.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		row.add_child(v)
		_stat_vals[key] = v
	# Swarm-manufacturing crew plan (PACKING_PLAN.md Phase 6.5): the real
	# BOM → fabrication task graph → pit-crew schedule, live per design.
	_fab_stats = RichTextLabel.new()
	_fab_stats.bbcode_enabled = true
	_fab_stats.fit_content = true
	_fab_stats.scroll_active = false
	_fab_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fab_stats.add_theme_color_override("default_color", C_TEXT_S)
	_fab_stats.add_theme_font_size_override("normal_font_size", UITheme.FONT_XS)
	stats.add_child(_fab_stats)
	# Hand the whole build to the site's NPC crew: drops the fabrication
	# task graph onto the habitat's chore board, wired by dependencies, with
	# the build site as every phase's work position.
	_crew_btn = Button.new()
	_crew_btn.text = "👷 Queue build for crew"
	_crew_btn.focus_mode = Control.FOCUS_NONE
	_crew_btn.tooltip_text = "Adds the fabrication phases to a pop-driven habitat's chore board — the roster drills, assembles, and raises it in dependency order"
	_crew_btn.pressed.connect(_on_queue_crew_build)
	stats.add_child(_crew_btn)
	_crew_status = Label.new()
	_crew_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_crew_status.add_theme_color_override("font_color", C_TEXT_S)
	_crew_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	stats.add_child(_crew_status)
	_anim_status_lbl = Label.new()
	_anim_status_lbl.text = "Idle"
	_anim_status_lbl.add_theme_color_override("font_color", C_TEXT_M)
	_anim_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	stats.add_child(_anim_status_lbl)
	# The stats scroll: with the two 190 px insets above them they made the
	# column ~820 px tall, past the bottom of a 720p screen at UI scale 125 %.
	var stats_scroll := ScrollContainer.new()
	stats_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stats_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_scroll.add_child(stats)
	var stats_panel := _panel_wrap(stats_scroll)
	stats_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(stats_panel)
	return box


func _ortho_inset(label_text: String) -> Array:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size = Vector2(RIGHT_W, 190)
	var overlay := Control.new()
	wrap.add_child(overlay)
	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(vpc)
	var vp := SubViewport.new()
	vp.size = Vector2i(270, 180)
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	# Share the studio world so the insets track the same structure.
	vp.world_3d = _viewport.world_3d
	vpc.add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 14.0
	cam.far = 800.0
	vp.add_child(cam)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	lbl.position = Vector2(8, 4)
	overlay.add_child(lbl)
	return [wrap, vp, cam]


func _update_ortho_cams() -> void:
	if _builder == null:
		return
	var aabb := _builder.frame_aabb()
	if aabb.size.length_squared() < 0.001:
		return
	var center := aabb.get_center()
	var span_xz := maxf(aabb.size.x, aabb.size.z)
	if _top_cam != null:
		_top_cam.position = center + Vector3(0, maxf(aabb.size.y, 4.0) + 12.0, 0)
		_top_cam.rotation_degrees = Vector3(-90, 0, 0)
		_top_cam.size = span_xz * 1.2 + 1.0
	if _side_cam != null:
		_side_cam.position = center + Vector3(0, 0, span_xz + 14.0)
		_side_cam.rotation_degrees = Vector3.ZERO
		_side_cam.size = maxf(span_xz, aabb.size.y) * 1.2 + 1.0


# ---------------------------------------------------------------------------
# Save / Load / Import / Export
# ---------------------------------------------------------------------------

func _build_save_load_overlays() -> void:
	_save_overlay = _overlay_panel("Save design")
	var sv := _save_overlay.get_meta("content") as VBoxContainer
	_save_name_edit = LineEdit.new()
	_save_name_edit.placeholder_text = "design name"
	sv.add_child(_save_name_edit)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	sv.add_child(srow)
	var sbtn := Button.new()
	sbtn.text = "Save"
	sbtn.focus_mode = Control.FOCUS_NONE
	sbtn.pressed.connect(_on_save_confirm)
	srow.add_child(sbtn)
	var scancel := Button.new()
	scancel.text = "Cancel"
	scancel.focus_mode = Control.FOCUS_NONE
	scancel.pressed.connect(func() -> void: _save_overlay.visible = false)
	srow.add_child(scancel)

	_load_overlay = _overlay_panel("Load design")
	var lv := _load_overlay.get_meta("content") as VBoxContainer
	_load_list = ItemList.new()
	_load_list.custom_minimum_size = Vector2(360, 240)
	lv.add_child(_load_list)
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 8)
	lv.add_child(lrow)
	var lbtn := Button.new()
	lbtn.text = "Load"
	lbtn.focus_mode = Control.FOCUS_NONE
	lbtn.pressed.connect(_on_load_confirm)
	lrow.add_child(lbtn)
	var dbtn := Button.new()
	dbtn.text = "Delete"
	dbtn.focus_mode = Control.FOCUS_NONE
	dbtn.pressed.connect(_on_load_delete)
	lrow.add_child(dbtn)
	var lcancel := Button.new()
	lcancel.text = "Cancel"
	lcancel.focus_mode = Control.FOCUS_NONE
	lcancel.pressed.connect(func() -> void: _load_overlay.visible = false)
	lrow.add_child(lcancel)


func _overlay_panel(title_text: String) -> Control:
	var overlay := Control.new()
	overlay.visible = false
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(shade)
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, C_RAISED))
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.grow_horizontal = Control.GROW_DIRECTION_BOTH
	pc.grow_vertical = Control.GROW_DIRECTION_BOTH
	overlay.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	pc.add_child(v)
	var title := Label.new()
	title.text = title_text
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	v.add_child(title)
	overlay.set_meta("content", v)
	return overlay


func _build_file_dialogs() -> void:
	_export_dlg = FileDialog.new()
	_export_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_export_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_export_dlg.filters = PackedStringArray(["*.json ; LinkageLab config"])
	_export_dlg.current_file = "linkage-design.json"
	_export_dlg.file_selected.connect(_on_export_file)
	add_child(_export_dlg)
	_import_dlg = FileDialog.new()
	_import_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_import_dlg.filters = PackedStringArray(["*.json ; LinkageLab config"])
	_import_dlg.file_selected.connect(_on_import_file)
	add_child(_import_dlg)


func _scan_presets() -> void:
	_presets.clear()
	var d := DirAccess.open(PRESET_DIR)
	if d == null:
		return
	for fname in d.get_files():
		if not fname.ends_with(".json"):
			continue
		var f := FileAccess.open(PRESET_DIR + fname, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			_presets.append({
				"name": str((parsed as Dictionary).get("name", fname.get_basename())),
				"path": PRESET_DIR + fname,
				"config": parsed,
			})


func _on_preset_selected(idx: int) -> void:
	if idx <= 0 or idx > _presets.size():
		return
	var cfg: Dictionary = _presets[idx - 1]["config"]
	params = LinkageParams.new()
	params.from_config(cfg)
	_apply_params(true)
	_sync_controls()


func _on_save_pressed() -> void:
	_save_name_edit.text = ""
	_save_overlay.visible = true
	_save_name_edit.grab_focus()


func _on_save_confirm() -> void:
	var design_name := _save_name_edit.text.strip_edges()
	if design_name.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DESIGN_DIR))
	params.design_name = design_name
	var cfg := params.to_config()
	var fname := design_name.validate_filename() + ".json"
	var f := FileAccess.open(USER_DESIGN_DIR + fname, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()
	_save_overlay.visible = false


func _on_load_pressed() -> void:
	_load_list.clear()
	_load_entries.clear()
	for p in _presets:
		_load_list.add_item("Preset: %s" % str(p["name"]))
		_load_entries.append({"kind": "preset", "config": p["config"]})
	var d := DirAccess.open(USER_DESIGN_DIR)
	if d != null:
		for fname in d.get_files():
			if fname.ends_with(".json"):
				_load_list.add_item(fname.get_basename())
				_load_entries.append({"kind": "user", "path": USER_DESIGN_DIR + fname})
	_load_overlay.visible = true


func _on_load_confirm() -> void:
	var sel := _load_list.get_selected_items()
	if sel.is_empty():
		return
	var entry: Dictionary = _load_entries[sel[0]]
	var cfg: Dictionary = {}
	if entry["kind"] == "preset":
		cfg = entry["config"]
	else:
		var f := FileAccess.open(str(entry["path"]), FileAccess.READ)
		if f == null:
			return
		var parsed = JSON.parse_string(f.get_as_text())
		if not (parsed is Dictionary):
			return
		cfg = parsed
	params = LinkageParams.new()
	params.from_config(cfg)
	_apply_params(true)
	_sync_controls()
	_load_overlay.visible = false


func _on_load_delete() -> void:
	var sel := _load_list.get_selected_items()
	if sel.is_empty():
		return
	var entry: Dictionary = _load_entries[sel[0]]
	if entry["kind"] != "user":
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(str(entry["path"])))
	_on_load_pressed()


func _on_export_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(params.to_config(), "\t"))
		f.close()


func _on_import_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	params = LinkageParams.new()
	params.from_config(parsed)
	_apply_params(true)
	_sync_controls()


func _on_units_pressed() -> void:
	_metric = not _metric
	_btn_units.text = "m" if _metric else "ft"
	_update_stats()


# ---------------------------------------------------------------------------
# World placement + edit-in-place (Phase 5)
# ---------------------------------------------------------------------------

func _main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.current_scene


## Record extras carried onto the placed-prop record: the full v30 design +
## the current fold pose (the deploy runtime restores it on spawn).
func _placement_record_extra() -> Dictionary:
	var closed := _builder.closed_angle() if _builder != null else params.fold_angle
	return {
		"kind": "linkage_structure",
		"linkage_spec": params.to_config(),
		"linkage_fold_deg": rad_to_deg(params.fold_angle),
		"linkage_deployed": params.fold_angle >= closed - 0.02,
	}


func _on_place_pressed() -> void:
	var main := _main_node()
	if main == null:
		return
	var r: Dictionary = PlacedPropService.begin_placement(
		main, LinkageStructureBuilder.MODEL_ID,
		{"record_extra": _placement_record_extra()})
	if not bool(r.get("ok", false)):
		return
	# Hand off to the placed-props UI for aim + click-confirm (same flow as
	# bundle import / pallet rack). Ensure it exists on baked maps too.
	var props_ui := main.get_node_or_null("UILayer/PlacedPropsUI")
	if props_ui == null and main.has_method("_ensure_placed_props_ui"):
		main.call("_ensure_placed_props_ui")
		props_ui = main.get_node_or_null("UILayer/PlacedPropsUI")
	if props_ui != null and props_ui.has_method("notify_bundle_imported"):
		props_ui.call("notify_bundle_imported", r)
	close()


## Rebuild the bound placed structure in place with the current design.
func _on_apply_to_prop_pressed() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	if main == null:
		return
	PlacedPropService.update_prop_record(main, _bound_prop_id,
		_placement_record_extra(), true)
	# Re-seed this structure's solar array (idempotent per prop) so panel
	# count/watts/orientation edits reach the graph + SolarUI. Deferred so the
	# just-rebuilt prop node is in the tree before we read its builder.
	var pid := _bound_prop_id
	Callable(PlacedPropService, "seed_linkage_graph").call_deferred(main, pid)
	close()


# ---------------------------------------------------------------------------
# Params <-> controls
# ---------------------------------------------------------------------------

func _on_fold_slider(v: float) -> void:
	if _suppress:
		return
	_anim_playing = false
	_update_anim_status()
	_suppress = true
	_fold_slider.value = v
	_fold_spin.value = v
	_suppress = false
	_set_fold_angle(deg_to_rad(v))


## Fold-only update: no rebuild, transforms rewritten in place.
func _set_fold_angle(angle_rad: float) -> void:
	params.fold_angle = angle_rad
	if _builder != null:
		_builder.set_fold_angle(angle_rad)
	_suppress = true
	_fold_slider.value = rad_to_deg(_builder.get_fold_angle() if _builder != null else angle_rad)
	_fold_spin.value = _fold_slider.value
	_suppress = false
	_update_stats()
	if _builder != null and not _builder.fold_schedule().is_empty():
		_update_radial_readout()


func _on_struct_rot_changed(v: float) -> void:
	params.structure_rotation = v
	_apply_structure_rotation()


## Rotate the structure about its own vertical centre axis (not a corner). The
## solved ring is NOT centred on the local origin — it starts there and wraps —
## so we pivot the holder at the structure's XZ centroid and counter-translate
## the builder, keeping it visually in place while the Y rotation spins about
## the middle.
func _apply_structure_rotation() -> void:
	if _holder == null or _builder == null:
		return
	var aabb := _builder.frame_aabb()
	var c := aabb.get_center()
	_holder.position = Vector3(c.x, 0.0, c.z)
	_builder.position = Vector3(-c.x, 0.0, -c.z)
	_holder.rotation_degrees.y = params.structure_rotation


func _on_param_changed_f(_v: float) -> void:
	_on_param_changed()


func _on_param_changed() -> void:
	if _suppress:
		return
	_read_params()
	_update_conditional_visibility()
	_rebuild_pending = true
	_rebuild_timer = REBUILD_DEBOUNCE_S


func _sel_meta_f(opt: OptionButton, fallback: float) -> float:
	var m = opt.get_selected_metadata()
	return float(m) if m != null else fallback


func _read_params() -> void:
	params.show_brackets = _brackets_chk.button_pressed
	params.show_bolts = _bolts_chk.button_pressed
	_read_radial_params()
	_read_enclosure_params()
	params.orientation = "vertical" if _orientation_opt.selected == 1 else "horizontal"
	params.arch_cap_uprights = _cap_chk.button_pressed
	params.use_fixed_beams = _fixed_chk.button_pressed
	params.arch_flip_vertical = _arch_flip_chk.button_pressed
	params.arch_rotation = float((_arch_rot["spin"] as SpinBox).value)
	params.array_count = int((_array_count["spin"] as SpinBox).value)
	params.h_length_ft = float((_hlen["spin"] as SpinBox).value)
	params.v_length_ft = float((_vlen["spin"] as SpinBox).value)
	params.h_beam_w = float(_hbeam_w.value)
	params.h_beam_t = float(_hbeam_t.value)
	params.v_beam_w = float(_vbeam_w.value)
	params.v_beam_t = float(_vbeam_t.value)
	params.v_beam_inner_w = float(_vinner_w.value)
	params.v_beam_inner_t = float(_vinner_t.value)
	params.v_beam_outer_w = float(_vouter_w.value)
	params.v_beam_outer_t = float(_vouter_t.value)
	params.offset_top_in = float((_off_top["spin"] as SpinBox).value)
	params.offset_bot_in = float((_off_bot["spin"] as SpinBox).value)
	params.vert_end_offset = float((_vert_end["spin"] as SpinBox).value)
	params.h_stack_count = int((_hstack["spin"] as SpinBox).value)
	params.v_stack_count = int((_vstack["spin"] as SpinBox).value)
	params.v_stack_reverse = _vreverse_chk.button_pressed
	params.modules = int((_modules["spin"] as SpinBox).value)
	params.show_hardware_full_detail = _full_detail_chk.button_pressed
	# While the assemblies own spacing these widgets are READ-OUTS showing the
	# resolved values. Reading them back would overwrite the player's own
	# sidebar numbers with derived ones, so unticking Full Detail would not
	# restore what they had — hence the guard.
	if not LinkageHardwareSpacing.is_active(params):
		params.h_stack_gap = float((_hgap["spin"] as SpinBox).value)
		params.v_stack_gap = float((_vgap["spin"] as SpinBox).value)
		params.bracket_width = float(_bracket_w.value)
		params.bracket_depth = float(_bracket_d.value)
		params.bracket_height = float(_bracket_h.value)
		params.bracket_wall_thickness = float(_bracket_wall.value)
		params.bracket_inner_width = float(_bracket_inner.value)
		params.bracket_hole_diameter = _sel_meta_f(_bracket_hole_opt, 0.375)
		params.bracket_hole_distance = float(_bracket_hole_dist.value)
	params.bolt_diameter = _sel_meta_f(_bolt_dia_opt, 0.375)
	params.v_bolt_auto = _vbolt_auto.button_pressed
	params.h_bolt_auto = _hbolt_auto.button_pressed
	params.h_pivot_bolt_auto = _hpivot_auto.button_pressed
	if not params.v_bolt_auto:
		params.v_bolt_length = float(_vbolt_len.value)
	if not params.h_bolt_auto:
		params.h_bolt_length = float(_hbolt_len.value)
	if not params.h_pivot_bolt_auto:
		params.h_pivot_bolt_length = float(_hpivot_len.value)
	params.pivot_pct = float((_pivot["spin"] as SpinBox).value)
	params.pivot_ang = float((_pivot_ang["spin"] as SpinBox).value)
	params.hoberman_ang = float((_hoberman["spin"] as SpinBox).value)
	params.min_fold_angle_deg = float(_min_fold_spin.value)
	params.radial_visible_angle = float((_radial_vis["spin"] as SpinBox).value)
	params.rcp_visible_angle = float((_rcp_vis["spin"] as SpinBox).value)
	params.panels_visible_angle = float((_panels_vis["spin"] as SpinBox).value)
	_read_support_beam_params()
	_read_solar_panel_params()
	params.apply_auto_bolt_lengths()


## Grey out the stack-gap and bracket inputs while the hardware assemblies own
## them, and show the RESOLVED values so the sidebar never lies about what the
## structure is actually built to (port of `hwUpdateStructureSpacingUI`).
func _sync_hardware_spacing_ui() -> void:
	if _full_detail_chk == null:
		return
	var active := LinkageHardwareSpacing.is_active(params)
	if _spacing_note != null:
		_spacing_note.visible = active
	var tip := "Controlled by the hardware assemblies while Full Detail is on" \
		if active else ""
	var spins: Array = [_hgap["spin"], _vgap["spin"], _bracket_w, _bracket_d,
		_bracket_h, _bracket_wall, _bracket_inner, _bracket_hole_dist]
	for s in spins:
		var sb := s as SpinBox
		if sb == null:
			continue
		sb.editable = not active
		sb.modulate.a = 0.55 if active else 1.0
		sb.tooltip_text = tip
	for slider in [_hgap.get("slider"), _vgap.get("slider")]:
		var sl := slider as Range
		if sl != null:
			sl.set("editable", not active)
			(sl as Control).modulate.a = 0.55 if active else 1.0
	if _bracket_hole_opt != null:
		_bracket_hole_opt.disabled = active
		_bracket_hole_opt.tooltip_text = tip
	if not active:
		return
	# Push the resolved numbers into the read-outs.
	var sp := LinkageHardwareSpacing.resolve(params)
	if sp.is_empty():
		return
	_set_pair(_hgap, float(sp["h_stack_gap"]))
	_set_pair(_vgap, float(sp["v_stack_gap"]))
	var br: Dictionary = sp.get("bracket", {})
	if br.is_empty():
		return
	_bracket_w.value = float(br["width"])
	_bracket_d.value = float(br["depth"])
	_bracket_h.value = float(br["height"])
	_bracket_wall.value = float(br["wall_thickness"])
	_bracket_inner.value = float(br["inner_width"])
	_bracket_hole_dist.value = float(br["hole_distance"])
	_select_meta_f(_bracket_hole_opt, float(br["hole_diameter"]))


func _read_support_beam_params() -> void:
	var sb: Dictionary = params.support_beams
	sb["enabled"] = (_sb["enabled"] as CheckBox).button_pressed
	sb["show_radial"] = (_sb["show_radial"] as CheckBox).button_pressed
	sb["length"] = float((_sb["length"]["spin"] as SpinBox).value)
	sb["width"] = float((_sb["width"] as SpinBox).value)
	sb["thickness"] = float((_sb["thickness"] as SpinBox).value)
	sb["offset_h"] = float((_sb["offset_h"]["spin"] as SpinBox).value)
	sb["offset_v"] = float((_sb["offset_v"]["spin"] as SpinBox).value)
	sb["parallel_enabled"] = (_sb["par_enabled"] as CheckBox).button_pressed
	sb["parallel_length"] = float((_sb["par_length"]["spin"] as SpinBox).value)
	sb["parallel_width"] = float((_sb["par_width"] as SpinBox).value)
	sb["parallel_thickness"] = float((_sb["par_thickness"] as SpinBox).value)
	sb["parallel_swing_angle"] = float((_sb["par_swing"]["spin"] as SpinBox).value)
	sb["anchor_dist"] = float((_sb["anchor_dist"]["spin"] as SpinBox).value)
	sb["parallel_v_offset"] = float((_sb["par_v_offset"] as SpinBox).value)
	sb["parallel_offset_v"] = float((_sb["par_offset_v"] as SpinBox).value)
	sb["rcp_end_offset"] = float((_sb["rcp_end_offset"] as SpinBox).value)


func _read_solar_panel_params() -> void:
	var sp: Dictionary = params.solar_panels
	sp["enabled"] = _sp_enabled.button_pressed
	sp["layout_mode"] = ["rectangular", "radial", "spiral"][clampi(_sp_layout.selected, 0, 2)]
	_read_panel_section(sp["top_panels"], _sp_top)
	_read_panel_section(sp["side_panels"], _sp_side)
	sp["grid_rotation"] = float((_sp_grid_rot["spin"] as SpinBox).value)
	sp["radial_count"] = int((_sp_radial["count"] as SpinBox).value)
	sp["radial_offset"] = float((_sp_radial["offset"]["spin"] as SpinBox).value)
	sp["radial_rotation"] = float((_sp_radial["rotation"]["spin"] as SpinBox).value)
	sp["radial_lateral_offset"] = float((_sp_radial["lateral"]["spin"] as SpinBox).value)
	sp["pinwheel_angle"] = float((_sp_radial["pinwheel"]["spin"] as SpinBox).value)
	sp["spiral_arm_count"] = int((_sp_spiral["arm_count"] as SpinBox).value)
	sp["spiral_secondary_enabled"] = (_sp_spiral["sec_enabled"] as CheckBox).button_pressed
	sp["spiral_secondary_radial_offset"] = float((_sp_spiral["sec_radial"] as SpinBox).value)
	sp["spiral_secondary_lateral_offset"] = float((_sp_spiral["sec_lateral"] as SpinBox).value)
	sp["spiral_secondary_pinwheel"] = float((_sp_spiral["sec_pinwheel"] as SpinBox).value)
	sp["spiral_secondary_rotation"] = float((_sp_spiral["sec_rotation"] as SpinBox).value)
	sp["spiral_arm_radial_step"] = float((_sp_spiral["step_radial"] as SpinBox).value)
	sp["spiral_arm_lateral_step"] = float((_sp_spiral["step_lateral"] as SpinBox).value)
	sp["spiral_arm_pinwheel_step"] = float((_sp_spiral["step_pinwheel"] as SpinBox).value)
	sp["spiral_arm_rotation_step"] = float((_sp_spiral["step_rotation"] as SpinBox).value)
	sp["arch_panel_offset"] = float((_sp_pos["lift"] as SpinBox).value)
	sp["arch_panel_slide"] = float((_sp_pos["slide"] as SpinBox).value)
	sp["arch_panel_separation"] = float((_sp_pos["separation"] as SpinBox).value)


func _read_panel_section(sec: Dictionary, c: Dictionary) -> void:
	sec["enabled"] = (c["enabled"] as CheckBox).button_pressed
	sec["panel_length"] = float((c["length"] as SpinBox).value)
	sec["panel_width"] = float((c["width"] as SpinBox).value)
	sec["panel_thickness"] = float((c["thickness"] as SpinBox).value)
	sec["rated_watts"] = float((c["watts"] as SpinBox).value)
	sec["voc"] = float((c["voc"] as SpinBox).value)
	sec["vmp"] = float((c["vmp"] as SpinBox).value)
	sec["isc"] = float((c["isc"] as SpinBox).value)
	sec["imp"] = float((c["imp"] as SpinBox).value)
	sec["padding_x"] = float((c["pad_x"] as SpinBox).value)
	sec["padding_y"] = float((c["pad_y"] as SpinBox).value)
	sec["grid_rows"] = int((c["rows"] as SpinBox).value)
	sec["grid_cols"] = int((c["cols"] as SpinBox).value)
	sec["panel_lift"] = float((c["lift"] as SpinBox).value)


## Write params into every control without triggering rebuilds.
func _sync_controls() -> void:
	_suppress = true
	_fold_slider.value = rad_to_deg(params.fold_angle)
	_fold_spin.value = rad_to_deg(params.fold_angle)
	_stop_spin.value = params.animation_stop_angle if params.animation_stop_angle >= 0.0 \
		else rad_to_deg(_builder.closed_angle() if _builder != null else deg_to_rad(135.0))
	_brackets_chk.button_pressed = params.show_brackets
	_sync_radial_controls()
	_sync_enclosure_controls()
	_bolts_chk.button_pressed = params.show_bolts
	_orientation_opt.select(1 if params.orientation == "vertical" else 0)
	_cap_chk.button_pressed = params.arch_cap_uprights
	_fixed_chk.button_pressed = params.use_fixed_beams
	_set_pair(_struct_rot, params.structure_rotation)
	_arch_flip_chk.button_pressed = params.arch_flip_vertical
	_set_pair(_arch_rot, params.arch_rotation)
	_set_pair(_array_count, float(params.array_count))
	_set_pair(_hlen, params.h_length_ft)
	_set_pair(_vlen, params.v_length_ft)
	_hbeam_w.value = params.h_beam_w
	_hbeam_t.value = params.h_beam_t
	_vbeam_w.value = params.v_beam_w
	_vbeam_t.value = params.v_beam_t
	_vinner_w.value = params.v_beam_inner_w
	_vinner_t.value = params.v_beam_inner_t
	_vouter_w.value = params.v_beam_outer_w
	_vouter_t.value = params.v_beam_outer_t
	_set_pair(_off_top, params.offset_top_in)
	_set_pair(_off_bot, params.offset_bot_in)
	_set_pair(_vert_end, params.vert_end_offset)
	_set_pair(_hstack, float(params.h_stack_count))
	_set_pair(_vstack, float(params.v_stack_count))
	_vreverse_chk.button_pressed = params.v_stack_reverse
	_set_pair(_hgap, params.h_stack_gap)
	_set_pair(_vgap, params.v_stack_gap)
	_set_pair(_modules, float(params.modules))
	_bracket_w.value = params.bracket_width
	_bracket_d.value = params.bracket_depth
	_bracket_h.value = params.bracket_height
	_bracket_wall.value = params.bracket_wall_thickness
	_bracket_inner.value = params.bracket_inner_width
	_select_meta_f(_bracket_hole_opt, params.bracket_hole_diameter)
	_bracket_hole_dist.value = params.bracket_hole_distance
	_select_meta_f(_bolt_dia_opt, params.bolt_diameter)
	_vbolt_auto.button_pressed = params.v_bolt_auto
	_vbolt_len.value = clampf(params.v_bolt_length, 1.0, 12.0)
	_vbolt_inner_len.value = clampf(params.v_bolt_inner_length, 1.0, 12.0)
	_vbolt_outer_len.value = clampf(params.v_bolt_outer_length, 1.0, 12.0)
	_hbolt_auto.button_pressed = params.h_bolt_auto
	_hbolt_len.value = clampf(params.h_bolt_length, 1.0, 12.0)
	_hpivot_auto.button_pressed = params.h_pivot_bolt_auto
	_hpivot_len.value = clampf(params.h_pivot_bolt_length, 1.0, 12.0)
	_set_pair(_pivot, params.pivot_pct)
	_set_pair(_pivot_ang, params.pivot_ang)
	_set_pair(_hoberman, params.hoberman_ang)
	_min_fold_spin.value = params.min_fold_angle_deg
	_set_pair(_radial_vis, params.radial_visible_angle)
	_set_pair(_rcp_vis, params.rcp_visible_angle)
	_set_pair(_panels_vis, params.panels_visible_angle)
	_full_detail_chk.button_pressed = params.show_hardware_full_detail
	_sync_hardware_spacing_ui()
	_sync_support_beam_controls()
	_sync_solar_panel_controls()
	_rebuild_face_toggles()
	_suppress = false
	_update_conditional_visibility()
	_apply_structure_rotation()


func _sync_support_beam_controls() -> void:
	var sb: Dictionary = params.support_beams
	(_sb["enabled"] as CheckBox).button_pressed = bool(sb["enabled"])
	(_sb["show_radial"] as CheckBox).button_pressed = bool(sb.get("show_radial", true))
	_set_pair(_sb["length"], float(sb["length"]))
	(_sb["width"] as SpinBox).value = float(sb["width"])
	(_sb["thickness"] as SpinBox).value = float(sb["thickness"])
	_set_pair(_sb["offset_h"], float(sb["offset_h"]))
	_set_pair(_sb["offset_v"], float(sb["offset_v"]))
	(_sb["par_enabled"] as CheckBox).button_pressed = bool(sb["parallel_enabled"])
	_set_pair(_sb["par_length"], float(sb["parallel_length"]))
	(_sb["par_width"] as SpinBox).value = float(sb["parallel_width"])
	(_sb["par_thickness"] as SpinBox).value = float(sb["parallel_thickness"])
	_set_pair(_sb["par_swing"], float(sb["parallel_swing_angle"]))
	_set_pair(_sb["anchor_dist"], float(sb["anchor_dist"]))
	(_sb["par_v_offset"] as SpinBox).value = float(sb["parallel_v_offset"])
	(_sb["par_offset_v"] as SpinBox).value = float(sb["parallel_offset_v"])
	(_sb["rcp_end_offset"] as SpinBox).value = float(sb["rcp_end_offset"])


func _sync_solar_panel_controls() -> void:
	var sp: Dictionary = params.solar_panels
	_sp_enabled.button_pressed = bool(sp["enabled"])
	var mode_idx := ["rectangular", "radial", "spiral"].find(str(sp["layout_mode"]))
	_sp_layout.select(maxi(mode_idx, 0))
	_sync_panel_section(sp["top_panels"], _sp_top)
	_sync_panel_section(sp["side_panels"], _sp_side)
	_set_pair(_sp_grid_rot, float(sp["grid_rotation"]))
	(_sp_radial["count"] as SpinBox).value = float(int(sp["radial_count"]))
	_set_pair(_sp_radial["offset"], float(sp["radial_offset"]))
	_set_pair(_sp_radial["rotation"], float(sp["radial_rotation"]))
	_set_pair(_sp_radial["lateral"], float(sp["radial_lateral_offset"]))
	_set_pair(_sp_radial["pinwheel"], float(sp["pinwheel_angle"]))
	(_sp_spiral["arm_count"] as SpinBox).value = float(int(sp["spiral_arm_count"]))
	(_sp_spiral["sec_enabled"] as CheckBox).button_pressed = bool(sp["spiral_secondary_enabled"])
	(_sp_spiral["sec_radial"] as SpinBox).value = float(sp["spiral_secondary_radial_offset"])
	(_sp_spiral["sec_lateral"] as SpinBox).value = float(sp["spiral_secondary_lateral_offset"])
	(_sp_spiral["sec_pinwheel"] as SpinBox).value = float(sp["spiral_secondary_pinwheel"])
	(_sp_spiral["sec_rotation"] as SpinBox).value = float(sp["spiral_secondary_rotation"])
	(_sp_spiral["step_radial"] as SpinBox).value = float(sp["spiral_arm_radial_step"])
	(_sp_spiral["step_lateral"] as SpinBox).value = float(sp["spiral_arm_lateral_step"])
	(_sp_spiral["step_pinwheel"] as SpinBox).value = float(sp["spiral_arm_pinwheel_step"])
	(_sp_spiral["step_rotation"] as SpinBox).value = float(sp["spiral_arm_rotation_step"])
	(_sp_pos["lift"] as SpinBox).value = float(sp["arch_panel_offset"])
	(_sp_pos["slide"] as SpinBox).value = float(sp["arch_panel_slide"])
	(_sp_pos["separation"] as SpinBox).value = float(sp["arch_panel_separation"])


func _sync_panel_section(sec: Dictionary, c: Dictionary) -> void:
	(c["enabled"] as CheckBox).button_pressed = bool(sec["enabled"])
	(c["length"] as SpinBox).value = float(sec["panel_length"])
	(c["width"] as SpinBox).value = float(sec["panel_width"])
	(c["thickness"] as SpinBox).value = float(sec["panel_thickness"])
	(c["watts"] as SpinBox).value = float(sec["rated_watts"])
	(c["voc"] as SpinBox).value = float(sec["voc"])
	(c["vmp"] as SpinBox).value = float(sec["vmp"])
	(c["isc"] as SpinBox).value = float(sec["isc"])
	(c["imp"] as SpinBox).value = float(sec["imp"])
	(c["pad_x"] as SpinBox).value = float(sec["padding_x"])
	(c["pad_y"] as SpinBox).value = float(sec["padding_y"])
	(c["rows"] as SpinBox).value = float(int(sec["grid_rows"]))
	(c["cols"] as SpinBox).value = float(int(sec["grid_cols"]))
	(c["lift"] as SpinBox).value = float(sec["panel_lift"])


func _set_pair(pair: Dictionary, v: float) -> void:
	(pair["slider"] as HSlider).value = v
	(pair["spin"] as SpinBox).value = v


func _select_meta_f(opt: OptionButton, value: float) -> void:
	for i in opt.item_count:
		if absf(float(opt.get_item_metadata(i)) - value) < 1e-6:
			opt.select(i)
			return


func _update_conditional_visibility() -> void:
	var is_arch := params.orientation == "vertical"
	if _arch_group != null:
		_arch_group.visible = is_arch
	if _cap_row != null:
		_cap_row.visible = is_arch
	var split := params.needs_split_v_beam_dimensions()
	if _vlink_btn != null:
		_vlink_btn.visible = split
		_vlink_btn.text = "🔗" if params.v_beam_dimensions_linked else "⛓"
	if _vsplit_box != null:
		_vsplit_box.visible = split and not params.is_v_beam_dimensions_linked()
	var split_bolts := params.needs_split_v_bolts()
	if _vbolt_split_box != null:
		_vbolt_split_box.visible = split_bolts
	if _vbolt_row != null:
		_vbolt_row.visible = not split_bolts
	# Panel layout sub-controls follow the selected mode; the wall-face grid
	# matters whenever the arch/side-wall layout is in play.
	if _sp_layout != null:
		var mode := _sp_layout.selected
		if _sp_rect_box != null:
			_sp_rect_box.visible = mode == 0 and not is_arch
		if _sp_radial_box != null:
			_sp_radial_box.visible = mode >= 1 and not is_arch
		if _sp_spiral_box != null:
			_sp_spiral_box.visible = mode == 2 and not is_arch
	if _faces_box != null:
		var side_on := (_sp_side.get("enabled") as CheckBox).button_pressed if not _sp_side.is_empty() else false
		_faces_box.visible = is_arch or side_on
		if _faces_grid != null and _faces_grid.get_child_count() != params.modules * 2:
			_rebuild_face_toggles()


# ---------------------------------------------------------------------------
# Rebuild + stats
# ---------------------------------------------------------------------------

func _apply_params(fit_camera: bool) -> void:
	if _builder == null:
		return
	_builder.set_params(params)
	# Auto lengths may have been recomputed; reflect them in the disabled fields.
	_suppress = true
	_vbolt_len.value = clampf(params.v_bolt_length, 1.0, 12.0)
	_vbolt_inner_len.value = clampf(params.v_bolt_inner_length, 1.0, 12.0)
	_vbolt_outer_len.value = clampf(params.v_bolt_outer_length, 1.0, 12.0)
	_hbolt_len.value = clampf(params.h_bolt_length, 1.0, 12.0)
	_hpivot_len.value = clampf(params.h_pivot_bolt_length, 1.0, 12.0)
	_suppress = false
	_apply_structure_rotation()
	if fit_camera:
		_fit_camera()
	_update_ortho_cams()
	_update_stats()
	_update_radial_readout()
	_update_enclosure_readout()
	if _steps_panel != null:
		_steps_panel.call("on_params_changed")


## Show / hide the build-steps dock (playback seats every part on exit).
func toggle_steps() -> void:
	if _steps_panel != null:
		_anim_playing = false
		_steps_panel.call("toggle")


func steps_panel() -> PanelContainer:
	return _steps_panel


func _fit_camera() -> void:
	var aabb := _builder.frame_aabb()
	if aabb.size.length_squared() < 0.001:
		return
	_target = aabb.get_center()
	_dist = maxf(aabb.size.length() * 0.85, 4.0)
	_update_camera()


func _fmt_len(inches: float) -> String:
	if _metric:
		return "%.2f m" % (inches * 0.0254)
	var feet := int(inches / 12.0)
	var rem := inches - feet * 12.0
	return "%d' %.1f\"" % [feet, rem]


func _update_stats() -> void:
	if _builder == null or _stat_vals.is_empty():
		return
	var s := _builder.get_stats()
	if s.is_empty():
		return
	(_stat_vals["Height"] as Label).text = _fmt_len(float(s["max_height_in"]))
	(_stat_vals["Diameter"] as Label).text = _fmt_len(float(s["max_diameter_in"]))
	(_stat_vals["Modules"] as Label).text = str(int(s["module_count"]))
	(_stat_vals["Beams"] as Label).text = str(int(s["beam_count"]))
	(_stat_vals["Support Beams"] as Label).text = str(int(s.get("support_beam_count", 0)))
	(_stat_vals["Brackets"] as Label).text = str(int(s["bracket_count"]))
	(_stat_vals["Bolts"] as Label).text = str(int(s["bolt_count"]))
	var panel_count := int(s.get("panel_count", 0))
	(_stat_vals["Panels"] as Label).text = str(panel_count)
	var watts := float(s.get("panel_watts", 0.0))
	(_stat_vals["Array Watts"] as Label).text = ("%.0f W" % watts) if panel_count > 0 else "—"
	(_stat_vals["Fold Angle"] as Label).text = "%.1f°" % float(s["fold_angle_deg"])
	(_stat_vals["Closed Angle"] as Label).text = "%.1f°" % rad_to_deg(_builder.closed_angle())
	var min_fold_deg := rad_to_deg(_builder.min_fold_angle())
	(_stat_vals["Min Fold"] as Label).text = "%.1f°" % min_fold_deg
	# Packed ("shipping") envelope + weight — solved at the effective minimum
	# fold angle, never the live slider angle (PACKING_PLAN.md Phase 0/0.5).
	var packed := _builder.packed_spec()
	var pw := float(packed.get("w_m", 0.0)) / 0.0254
	var pd := float(packed.get("d_m", 0.0)) / 0.0254
	var ph := float(packed.get("h_m", 0.0)) / 0.0254
	(_stat_vals["Packed Size"] as Label).text = "—" if packed.is_empty() \
		else "%s × %s × %s" % [_fmt_len(pw), _fmt_len(pd), _fmt_len(ph)]
	(_stat_vals["Packed Wt"] as Label).text = PackedSpec.format_mass(packed)
	# Honest-fold clamp: the slider floor tracks the physical minimum so a
	# design can no longer be dragged through itself (the brackets/outer
	# V-beams used to intersect below this angle, faking smaller shipping
	# dims). The Min Fold Angle Override spin stays the escape hatch for
	# hardware that genuinely folds tighter than the V-overlap model.
	var floor_deg := clampf(min_fold_deg, 5.0, 175.0)
	if absf(_fold_slider.min_value - floor_deg) > 0.01:
		_fold_slider.min_value = floor_deg
		_fold_spin.min_value = floor_deg
	_update_fab_stats(s)


## Fabrication + crew readout — the swarm-manufacturing planner over the
## design's REAL part counts (PACKING_PLAN.md Phase 6.5). Cached on the
## counts because _update_stats runs per fold tick and the schedule sweep
## (recommend_crew iterates crew sizes) is worth ~a millisecond, not per
## frame. An infeasible small crew is shown honestly — the raise needs
## hands, and that constraint is the lesson.
func _update_fab_stats(s: Dictionary) -> void:
	if _fab_stats == null:
		return
	# The hardware assemblies change the assemble phase, so they belong in the
	# cache key alongside the part counts.
	var key := "%s|%s|%s|%s|%s|%s" % [s.get("beam_count", 0), s.get("bracket_count", 0),
		s.get("bolt_count", 0), s.get("module_count", 0), s.get("panel_count", 0),
		LinkageHardware.hash_key(params.hardware_assemblies)]
	if key == _fab_cache_key:
		return
	_fab_cache_key = key
	var counts := _fab_counts(s)
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	var beams := int(counts.get("beam_count", 0))
	var holes := beams * NpcCrewPlan.HOLES_PER_BEAM
	var head := "[b]🔧 Fabrication[/b] — %s · %s · %s · %s\n" % [
		UiText.count(beams, "beam"), UiText.count(holes, "hole"),
		UiText.count(int(counts.get("bracket_count", 0)), "bracket"),
		UiText.count(int(counts.get("bom_bolt_count", 0)), "bolt")]
	var rows: Array = []
	for n: int in [2, 6, 12]:
		var r := NpcCrewPlan.schedule(tasks, n)
		if bool(r["feasible"]):
			rows.append("%d ppl %.1f h" % [n, float(r["makespan_s"]) / 3600.0])
		else:
			rows.append("%d ppl — (raise needs %d)" % [n, NpcCrewPlan.ERECT_MIN_WORKERS])
	var reco := NpcCrewPlan.recommend_crew(tasks, 24)
	var tail := ""
	if not reco.is_empty():
		var rbest := NpcCrewPlan.schedule(tasks, int(reco["n"]))
		var bottleneck := ""
		for row in rbest.get("timeline", []):
			if str((row as Dictionary)["id"]) == str(rbest.get("bottleneck_id", "")):
				bottleneck = str((row as Dictionary)["label"])
		tail = "\nBest crew [b]%d[/b] → %.1f h · %.0f%% busy · bottleneck: %s" % [
			int(reco["n"]), float(reco["makespan_s"]) / 3600.0,
			float(reco["utilization"]) * 100.0, bottleneck]
	_fab_stats.text = head + " · ".join(rows) + tail


## Open the Build Guide over the Lab. It lives on its own CanvasLayer one band
## higher, and CursorController keeps a modal STACK, so the Lab stays exactly
## as it was underneath — Esc pops the guide back off.
func _on_build_guide_pressed() -> void:
	var main := ServiceLocator.main()
	if main == null or not main.has_method("open_linkage_build_guide"):
		return
	var hint := "prop_%s" % _bound_prop_id if not _bound_prop_id.is_empty() else "design"
	main.call("open_linkage_build_guide", params.to_config(), hint)


## Open the Hardware Detail editor on THIS design's assembly graph. It edits
## `params.hardware_assemblies` in place, so closing it re-solves the structure
## — visibly re-spacing it when Hardware Full Detail is on.
func _on_hardware_detail_pressed() -> void:
	var main := ServiceLocator.main()
	if main == null or not main.has_method("open_linkage_hardware_editor"):
		return
	var modal: Variant = main.call("open_linkage_hardware_editor", params)
	if modal is Node and not (modal as Node).is_connected("closed", _on_hardware_closed):
		(modal as Node).connect("closed", _on_hardware_closed)


func _on_hardware_closed() -> void:
	# Spacing is content-keyed and the editor mutated the graph in place, so
	# the cache has to go before anything re-solves.
	LinkageHardwareSpacing.clear_cache()
	_sync_controls()
	_apply_params(false)


## Crew-planner input for the current design: the builder's live geometry
## counts, sharpened by the bill of materials. The BOM supplies the real bolt
## total (the solver only emits bolt geometry when "show bolts" is on) and the
## per-joint hardware stacks that split the assemble phase.
func _fab_counts(s: Dictionary) -> Dictionary:
	return LinkageBom.fab_counts(LinkageBom.compute(params), s)


## Hand this design to the site's crew: the same crew build every structure
## gets (SiteDeployDirector.queue_item — the deploy schedule's path). The
## nearest camp with board room takes it ALL HANDS; on the build site
## (PalletRackBuildSite) the kit is laid out in a yard, the frame goes up
## folded in the Lab's own step order (bottom ring, V modules, top ring,
## supports) as the crew's labour is credited, and the finish unpacks it and
## the deploy sweep opens it about its own middle.
func _on_queue_crew_build() -> void:
	if _builder == null or _crew_status == null:
		return
	var sgv: Node = ServiceLocator.graph()
	var sd: Object = sgv.call("site_deploy") if sgv != null and sgv.has_method("site_deploy") else null
	if sd == null:
		_crew_status.text = "No population running — load a map first."
		return
	var scene := get_tree().current_scene
	# The crew builds FROM a packed kit crate: the edited prop when it is
	# still packed; otherwise a fresh crate where the player stands.
	var crate_id := ""
	if not _bound_prop_id.is_empty():
		var brec: Dictionary = PlacedPropService.get_prop_record(scene, _bound_prop_id)
		if bool(brec.get("packed", false)):
			crate_id = _bound_prop_id
	var fresh := crate_id.is_empty()
	if fresh:
		var player := scene.find_child("Player", true, false) as Node3D \
			if scene != null else null
		var px := player.global_position.x + 8.0 if player != null else 0.0
		var pz := player.global_position.z if player != null else 0.0
		var placed: Dictionary = PlacedPropService.place_model_at_xz(scene,
			LinkageStructureBuilder.MODEL_ID, px, pz,
			{"packed": true, "linkage_spec": params.to_config()})
		if not bool(placed.get("ok", false)):
			_crew_status.text = "Couldn't place the kit crate — %s" % str(placed.get("error", ""))
			return
		crate_id = str(placed.get("prop_id", ""))
	var q: Dictionary = sd.call("queue_item", "prop", crate_id, SiteDeploySchedule.ACTION_DEPLOY)
	if not bool(q.get("ok", false)):
		_crew_status.text = "The crew can't take it — %s." % str(q.get("error", ""))
		var loader := TerrainSurfaceQuery.find_terrain_loader(scene) if fresh else null
		if loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", crate_id)
		return
	var pspec := LinkageStructureBuilder.packed_spec_for(params)
	var hours := SiteDeployPlanner.labour_hours(float(pspec.get("mass_kg", -1.0)))
	var eta_txt := "about %s of crew work" % UiText.duration(hours)
	# No auto-jump: close the Lab and offer a Watch chip (opens the settlement
	# view over the build site). notify_crew_queued also nudges a paused clock
	# — a frozen sim was the #1 "nothing is happening" report.
	var watch := _crate_site(scene, crate_id)
	close()
	if sgv.has_method("notify_crew_queued"):
		sgv.call("notify_crew_queued", watch, "👷 Build queued for the crew", eta_txt)


func _crate_site(scene: Node, crate_id: String) -> Vector2:
	var rec: Dictionary = PlacedPropService.get_prop_record(scene, crate_id) \
		if scene != null else {}
	return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
