extends Control

## The solar concentrator designer: lenses (glass, ball, Fresnel, water)
## and mirrors (parabolic trough and dish, linear Fresnel, a heliostat
## field round a tower), each built from numbers, not a model file, and
## traced ray by ray.
##
## Left:   the concentrator type (lenses, mirrors), built-in designs and the
##         player's library.
## Centre: Optics 3D — the concentrator facing the site's sun at the chosen
##         date and hour, with the traced rays (captured orange, spilled red,
##         shaded grey; a lens's rays in their wavelength's colour);
##         Ray trace 2D — the section with a fan of rays (the sun's width,
##         errors and wavelengths optional); Structure — the members, the
##         drives and the tracking axes, turning through the day;
##         Site year — the heat it makes month by month at this site from the
##         DIRECT beam only, beside the global light a solar panel would see.
## Right:  the results (efficiency chain, concentration in suns, heat), the
##         checks, the site now, every setting, the optimizer, the bill of
##         materials.
## Footer: place in the world (with its graph node), apply to a placed one.
##
## The chrome is the kit's (DesignerShell + StudioViewport + FormRow). Every
## number comes from one CspLabDesign; the 3D rays from CspLabOptics.trace
## at the sun of the chosen moment.

const MODAL_NAME := "csplab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const VIEW_RAYS := 2500
const PLAY_RAYS := 900
const PATHS := 240
const SECTION_RAYS := 28
const YEAR_BUDGET_MS := 8.0
const OPT_BUDGET_MS := 30.0

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _bound_prop_id := ""
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _library: Array = []
var _built_type := ""

# Site and the moment shown
var _lat := 35.0
var _lon := -115.0
var _year := 2026
var _month := 6
var _day := 21
var _hour := 12.0
var _site_name := "default site (35°N)"
var _sun := Vector3.UP
var _sun_dirty := true
var _ray_timer := 0.0
var _playing := false
var _at_sun: Dictionary = {}

# Jobs
var _year_job: CspLabSite.Year = null
var _year_result: Dictionary = {}
var _opt: CspLabOptimizer = null
var _opt_spec_before: Dictionary = {}

# UI
var _shell: DesignerShell
var _type_box: VBoxContainer
var _design_list: DesignGallery
var _col: DesignerColumn
var _design_entries: Array = []
var _tabs: TabBar
var _view_stack: Control
var _studio: StudioViewport
var _builder: CspLabBuilder = null
var _section: SectionCanvas
var _section_wrap: VBoxContainer
var _sec_spread: CheckBox
var _sec_errors: CheckBox
var _sec_bands: CheckBox
var _sec_site: CheckBox
var _year_wrap: VBoxContainer
var _year_canvas: YearCanvas
var _year_btn: Button
var _year_bar: ProgressBar
var _year_lbl: Label
var _month_opt: OptionButton
var _day_spin: SpinBox
var _hour_slider: HSlider
var _hour_lbl: Label
var _play_btn: Button
var _rays_chk: CheckBox
var _axes_chk: CheckBox
var _hover_lbl: Label
var _res_rows: Dictionary = {}
var _loss_box: VBoxContainer
var _warn_box: VBoxContainer
var _now_box: VBoxContainer
var _struct_box: VBoxContainer
var _bom_box: VBoxContainer
var _settings: Dictionary = {}
var _bindings: Array = []
var _obj_opt: OptionButton
var _opt_checks: Array = []
var _opt_box: VBoxContainer
var _opt_btn: Button
var _opt_bar: ProgressBar
var _opt_lbl: Label
var _place_btn: Button
var _apply_btn: Button
var _status_lbl: Label
var _template_btn: Button
var _type_why: Label
var _kpi: Dictionary = {}
var _cpc_credit: Control
const _MOTORS_PANEL := preload("res://scenes/ui/csplab_motors_panel.gd")
## Motors & Home Assistant: the drives' angles, and where they are sent.
var _motors: VBoxContainer = null
var _motors_sec: Collapsible = null
var _motors_t := 0.0
var _legend3d: RichTextLabel
var _member_lbl: Label
var _last_tab := 0

const MONTH_NAMES := ["January", "February", "March", "April", "May", "June", "July", "August",
	"September", "October", "November", "December"]
## NightHawkInLight's video the compound parabolic troughs follow.
const CPC_VIDEO_URL := "https://www.youtube.com/watch?v=8zlAI32MSsQ"


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

## opts: {spec, prop_id}.
func open(opts: Dictionary = {}) -> void:
	if _active:
		close()
	_bound_prop_id = str(opts.get("prop_id", ""))
	var spec: Dictionary = opts.get("spec", {}) as Dictionary
	if spec.is_empty() and not _bound_prop_id.is_empty():
		spec = _prop_record(_bound_prop_id).get("csplab_spec", {}) as Dictionary
	_read_site()
	if spec.is_empty():
		spec = CspLabPresets.by_id("dish_cooker")
	_spec = CspLabSpec.resolve(spec)
	_stamp_site()
	_undo.clear()
	_redo.clear()
	_year_job = null
	_year_result = {}
	_opt = null
	_library = CspLabPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_shell.scroll_top()
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_refresh_design_list()
	_built_type = ""
	_sync_time_controls()
	_rebuild_now()
	_frame_camera()
	_motors.call("reload")
	# A placed concentrator that tracks opens on its drives: that is what
	# is linked to the real motors.
	var mode := str((_spec["tracking"] as Dictionary)["mode"])
	_motors_sec.set_open(not _bound_prop_id.is_empty() and mode != "fixed" and mode != "level")


func close() -> void:
	if not _active:
		return
	_active = false
	_playing = false
	if _motors != null:
		_motors.call("flush")
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	if _studio != null:
		_studio.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_shell.close()


func is_open() -> bool:
	return _active


func _main_node() -> Node:
	return get_tree().current_scene if get_tree() != null else null


## The site and the moment shown: Main's location and clock when there is a
## world, else a desert site on the solstice.
func _read_site() -> void:
	var m := _main_node()
	if m == null:
		return
	var la: Variant = m.get("latitude")
	var lo: Variant = m.get("longitude")
	if la != null and lo != null:
		_lat = float(la)
		_lon = float(lo)
		_site_name = "this site (%s)" % _fmt_latlon(_lat, _lon)
	var y: Variant = m.get("year")
	var mo: Variant = m.get("month")
	var dd: Variant = m.get("day")
	var h: Variant = m.get("day_time")
	if y != null:
		_year = int(y)
	if mo != null:
		_month = clampi(int(mo), 1, 12)
	if dd != null:
		_day = clampi(int(dd), 1, 31)
	if h != null:
		_hour = float(h)
	# Night is no time to look at a concentrator: open on solar noon-ish.
	var sun := CspLabSite.sun_at(_lat, _lon, _year, _month, _day, _hour)
	if float(sun["el"]) < 5.0:
		_hour = 12.5


static func _fmt_latlon(la: float, lo: float) -> String:
	return SitePrivacy.coords(la, lo)


func _stamp_site() -> void:
	var site: Dictionary = _spec["site"]
	site["lat_deg"] = _lat
	site["lon_deg"] = _lon


func _ws() -> Node:
	return get_node_or_null("/root/WeatherService")


func _process(delta: float) -> void:
	if _rebuild_timer > 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_now()
	if _playing:
		_hour += delta * 1.2
		var sun := CspLabSite.sun_at(_lat, _lon, _year, _month, _day, _hour)
		if _hour > 23.5 or (_hour > 12.0 and float(sun["el"]) < -2.0):
			_playing = false
			_play_btn.text = "Play the day"
		_sync_time_controls()
		_sun_dirty = true
	_motors_t -= delta
	if _motors_t <= 0.0 and _motors != null and _motors.is_visible_in_tree():
		_motors_t = 0.4
		_motors.call("refresh")
	_ray_timer -= delta
	if _sun_dirty and _ray_timer <= 0.0:
		_ray_timer = 0.12
		_sun_dirty = false
		_update_sun()
	if _year_job != null:
		var done := _year_job.step(YEAR_BUDGET_MS)
		_year_bar.value = _year_job.progress()
		if done:
			_year_result = _year_job.result()
			_year_job = null
			_year_bar.visible = false
			_year_btn.disabled = false
			_refresh_year()
	if _opt != null:
		var t0 := Time.get_ticks_msec()
		while _opt != null and Time.get_ticks_msec() - t0 < OPT_BUDGET_MS:
			if _opt.step():
				_finish_optimize()
				break
		if _opt != null:
			_opt_bar.value = _opt.progress()
			_opt_lbl.text = I18n.f("Searching… {evals} designs tried, best {best}", {"evals": "%d" % _opt.evals, "best": _fmt_obj(_opt.best_value)})


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if ke.keycode == KEY_Z and ke.ctrl_pressed and not ke.shift_pressed:
		_undo_step()
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_Y and ke.ctrl_pressed) or (ke.keycode == KEY_Z and ke.ctrl_pressed and ke.shift_pressed):
		_redo_step()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("Solar concentrator designer", "sun", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Types & designs", "left_w": 240.0, "right_w": 410.0})
	add_child(_shell)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(_on_name_changed)
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_build_footer()


func _build_left() -> void:
	var box := _shell.left
	_type_box = VBoxContainer.new()
	_type_box.add_theme_constant_override("separation", 2)
	box.add_child(_type_box)
	for group in [["Lenses", "search", "lens"], ["Mirrors", "sun", "mirror"]]:
		_type_box.add_child(SectionHeader.make(str(group[0]), str(group[1])))
		for t in CspLabSpec.TYPES:
			if str(CspLabSpec.OPTIC[t]) != str(group[2]):
				continue
			var b := Button.new()
			b.text = str(CspLabSpec.TYPE_LABELS[t])
			b.tooltip_text = str(CspLabSpec.TYPE_WHY[t]) + "\n\nStarts a fresh design (Ctrl+Z undoes)."
			b.toggle_mode = true
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.custom_minimum_size = Vector2(0, 30)
			b.set_meta("type", t)
			b.pressed.connect(_on_type_pressed.bind(t))
			_type_box.add_child(b)
	_type_why = Label.new()
	_type_why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_type_why.custom_minimum_size = Vector2(120, 0)
	_type_why.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_type_why.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_type_why)
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = DesignGallery.make("csplab")
	_design_list.set_thumbnailer(_thumb_for)
	_design_list.item_selected.connect(_on_design_activated)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	var save := Button.new()
	save.text = "Save design"
	save.tooltip_text = "Keep this design in your library (every world)"
	UITheme.style_button(save)
	save.pressed.connect(_on_save_design)
	lib.add_child(save)
	var forget := Button.new()
	forget.text = "Forget"
	forget.tooltip_text = "Remove the selected saved design"
	UITheme.style_button(forget)
	forget.pressed.connect(_on_forget_design)
	lib.add_child(forget)
	box.add_child(lib)


func _build_centre() -> void:
	var col := _shell.centre
	_tabs = TabBar.new()
	_tabs.add_tab("Optics 3D")
	_tabs.add_tab("Ray trace 2D")
	_tabs.add_tab("Structure")
	_tabs.add_tab("Site year")
	_tabs.tab_changed.connect(func(_i: int) -> void: _show_view())
	col.add_child(_tabs)
	_view_stack = Control.new()
	_view_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_stack.clip_contents = true
	col.add_child(_view_stack)
	_studio = StudioViewport.create({"ground": true, "person": true, "far": 900.0})
	_studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_studio.set_home(0.9, 0.32)
	_studio.dist_max = 700.0
	_studio.hovered.connect(_on_studio_hover)
	if _studio.ground != null:
		(_studio.ground.mesh as PlaneMesh).size = Vector2(600, 600)
	_view_stack.add_child(_studio)
	_builder = CspLabBuilder.new()
	_builder.name = "Concentrator"
	# The studio has its own sun: its own copy of the mirror material.
	_builder.private_mirror = true
	_builder.show_sun_marker = true
	_studio.holder.add_child(_builder)
	_legend3d = RichTextLabel.new()
	_legend3d.bbcode_enabled = true
	_legend3d.fit_content = true
	_legend3d.scroll_active = false
	_legend3d.autowrap_mode = TextServer.AUTOWRAP_OFF
	_legend3d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend3d.position = Vector2(10, 8)
	_legend3d.add_theme_font_size_override("normal_font_size", UITheme.FONT_XS)
	var lsb := UITheme.panel_style(0.82)
	lsb.content_margin_left = 8
	lsb.content_margin_right = 8
	lsb.content_margin_top = 3
	lsb.content_margin_bottom = 3
	_legend3d.add_theme_stylebox_override("normal", lsb)
	_view_stack.add_child(_legend3d)
	_member_lbl = Label.new()
	_member_lbl.position = Vector2(10, 8)
	_member_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_member_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_member_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	_member_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_member_lbl.add_theme_constant_override("outline_size", 4)
	_member_lbl.visible = false
	_view_stack.add_child(_member_lbl)
	# The moment shown, under the 3D view.
	var bar := _studio.strip
	var ml := Label.new()
	ml.text = "Day"
	bar.add_child(ml)
	_month_opt = OptionButton.new()
	for mi in 12:
		_month_opt.add_item(str(MONTH_NAMES[mi]).substr(0, 3), mi)
	_month_opt.tooltip_text = "Month"
	_month_opt.item_selected.connect(func(i: int) -> void: _month = i + 1; _sun_dirty = true; _sync_time_controls())
	bar.add_child(_month_opt)
	_day_spin = SpinBox.new()
	_day_spin.min_value = 1
	_day_spin.max_value = 31
	_day_spin.tooltip_text = "Day of the month"
	_day_spin.value_changed.connect(func(v: float) -> void: _day = int(v); _sun_dirty = true; _sync_time_controls())
	bar.add_child(_day_spin)
	_hour_slider = HSlider.new()
	_hour_slider.min_value = 0.0
	_hour_slider.max_value = 24.0
	_hour_slider.step = 0.05
	_hour_slider.custom_minimum_size = Vector2(160, 0)
	_hour_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hour_slider.tooltip_text = "Time of day (the site's clock)"
	_hour_slider.value_changed.connect(func(v: float) -> void: _hour = v; _sun_dirty = true; _sync_time_controls())
	bar.add_child(_hour_slider)
	_hour_lbl = Label.new()
	_hour_lbl.custom_minimum_size = Vector2(44, 0)
	bar.add_child(_hour_lbl)
	_play_btn = Button.new()
	_play_btn.text = "Play the day"
	_play_btn.tooltip_text = "Run the sun from now to sunset and watch it track"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play)
	bar.add_child(_play_btn)
	_rays_chk = CheckBox.new()
	_rays_chk.text = "Rays"
	_rays_chk.button_pressed = true
	_rays_chk.toggled.connect(func(_on: bool) -> void: _apply_overlays())
	bar.add_child(_rays_chk)
	_axes_chk = CheckBox.new()
	_axes_chk.text = "Axes"
	_axes_chk.tooltip_text = "The tracking axes and their names"
	_axes_chk.toggled.connect(func(_on: bool) -> void: _apply_overlays())
	bar.add_child(_axes_chk)
	bar.add_child(IconButton.make("scan", "Frame the concentrator", func() -> void: _studio.reset_orbit(); _frame_camera()))
	_hover_lbl = Label.new()
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_hover_lbl.clip_text = true
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_hover_lbl)
	# The 2D section.
	_section_wrap = VBoxContainer.new()
	_section_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_section_wrap.visible = false
	_view_stack.add_child(_section_wrap)
	var sbar := HBoxContainer.new()
	sbar.add_theme_constant_override("separation", UITheme.SPACE_MD)
	_section_wrap.add_child(sbar)
	_sec_site = _sec_check(sbar, "Site sun", "The sun of the chosen moment (else the design point: normal incidence, or noon at the equinox for a field)")
	_sec_spread = _sec_check(sbar, "Sun's width", "Each ray also from the two edges of the sun's disc")
	_sec_errors = _sec_check(sbar, "Errors", "Random rays with the surface and tracking errors")
	_sec_bands = _sec_check(sbar, "Wavelengths", "A lens bends blue more than infrared: trace all four bands in their colours")
	_section = SectionCanvas.new()
	_section.owner_modal = self
	_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_section_wrap.add_child(_section)
	# The site year.
	_year_wrap = VBoxContainer.new()
	_year_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_year_wrap.visible = false
	_view_stack.add_child(_year_wrap)
	var ybar := HBoxContainer.new()
	ybar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_year_wrap.add_child(ybar)
	_year_btn = Button.new()
	_year_btn.text = "Run the year at this site"
	_year_btn.tooltip_text = "Hour by hour, every other day: the sun, the site's weather, the direct beam, the optic's efficiency at that sun and the receiver's losses"
	UITheme.style_button(_year_btn)
	_year_btn.pressed.connect(run_year)
	ybar.add_child(_year_btn)
	_year_bar = ProgressBar.new()
	_year_bar.min_value = 0.0
	_year_bar.max_value = 1.0
	_year_bar.custom_minimum_size = Vector2(180, 0)
	_year_bar.show_percentage = false
	_year_bar.visible = false
	UITheme.style_progress(_year_bar, UITheme.C_AMBER)
	ybar.add_child(_year_bar)
	_year_lbl = Label.new()
	_year_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_year_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_year_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_year_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	ybar.add_child(_year_lbl)
	_year_canvas = YearCanvas.new()
	_year_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_year_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_year_wrap.add_child(_year_canvas)


func _sec_check(bar: HBoxContainer, text: String, tip: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.toggled.connect(func(_on: bool) -> void: _refresh_section())
	bar.add_child(c)
	return c


func _build_right() -> void:
	var box := _shell.right
	var tiles := GridContainer.new()
	tiles.columns = 2
	tiles.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	tiles.add_theme_constant_override("v_separation", UITheme.SPACE_SM)
	box.add_child(tiles)
	for kv in [["heat", "useful heat", "Heat delivered at the working temperature, at the design direct sunlight", UITheme.C_AMBER],
			["optical", "optical efficiency", "Absorbed ÷ direct sun on the aperture", UITheme.C_PRIMARY],
			["suns", "concentration", "Mean flux on the receiver, in suns (1 sun = 1 kW/m²)", UITheme.C_GOLD],
			["stag", "stagnation", "How hot the receiver gets with nothing drawn", UITheme.C_ERROR]]:
		tiles.add_child(_kpi_tile(str(kv[0]), str(kv[1]), str(kv[2]), kv[3] as Color))
	box.add_child(SectionHeader.make("Results", "gauge", "at the design DNI"))
	var res := VBoxContainer.new()
	res.add_theme_constant_override("separation", 1)
	box.add_child(res)
	for r in [["aperture", "Aperture", "Area of the lens / mirrors facing the sun"],
			["receiver", "Receiver", "Absorbing area and geometric concentration (aperture ÷ receiver)"],
			["suns", "Concentration", "Mean flux on the receiver in suns (1 sun = 1 kW/m²) and as a multiple of the DNI"],
			["peak", "Peak flux", "The hottest spot on the receiver"],
			["limit", "Limit", "The thermodynamic limit for the sun's half-angle (étendue)"],
			["optical", "Optical efficiency", "Absorbed ÷ direct sun on the aperture: every loss in the trace times the receiver's absorptance"],
			["intercept", "Intercept", "Of the light leaving the optic toward the receiver, the share that lands on it"],
			["heat", "Heat", "Useful heat at the working temperature"],
			["eta_th", "Thermal efficiency", "Useful heat ÷ direct sun on the aperture"],
			["stag", "Stagnation", "How hot the receiver gets with nothing drawn"],
			["steam", "Steam", "Water at 20 °C boiled at 1 atm by the useful heat"],
			["iam", "Off-axis", "One-axis tracking: optical efficiency with the sun 30° and 60° along the axis"],
			["cpc", "CPC shape", "Compound parabolic trough: acceptance, aperture and height, mirror per metre"],
			["accept", "Across the trough", "Optical efficiency with the sun tilted across the trough: inside the acceptance it stays up, beyond it falls away"]]:
		var row := FormRow.value(str(r[1]), "—", str(r[2]), "res_" + str(r[0]))
		res.add_child(row)
		_res_rows[str(r[0])] = row
	_cpc_credit = _make_cpc_credit()
	box.add_child(_cpc_credit)
	box.add_child(SectionHeader.make("Where the light goes", "chart-column"))
	_loss_box = VBoxContainer.new()
	_loss_box.add_theme_constant_override("separation", 2)
	box.add_child(_loss_box)
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_warn_box = VBoxContainer.new()
	_warn_box.add_theme_constant_override("separation", 4)
	box.add_child(_warn_box)
	var now := Collapsible.make("At the site, at the chosen moment", true)
	box.add_child(now)
	_now_box = now.body
	var groups := [["optic", "Optic"], ["receiver", "Receiver"], ["tracking", "Tracking"],
		["structure", "Structure"], ["trace", "Ray trace"], ["site", "Working conditions"]]
	for gr in groups:
		var sec := Collapsible.make(str(gr[1]), str(gr[0]) == "optic" or str(gr[0]) == "receiver")
		box.add_child(sec)
		_settings[str(gr[0])] = sec.body
		if str(gr[0]) == "structure":
			_struct_box = VBoxContainer.new()
			sec.body.add_child(_struct_box)
	var mot := Collapsible.make("Motors & Home Assistant", false,
		"Every drive's angle now, in degrees, and the Home Assistant entity a real motor follows")
	box.add_child(mot)
	_motors_sec = mot
	_motors = _MOTORS_PANEL.new()
	_motors.name = "MotorsPanel"
	_motors.call("setup", self)
	mot.body.add_child(_motors)
	var opt := Collapsible.make("Optimize", false, "Search a few numbers for the best design")
	box.add_child(opt)
	_build_optimize(opt.body)
	var bom := Collapsible.make("Bill of materials", false)
	box.add_child(bom)
	_bom_box = bom.body
	var copy := Button.new()
	copy.text = "Copy summary"
	copy.tooltip_text = "Every number and check, as text"
	UITheme.style_button(copy)
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(CspLabDesign.summary(_design)); _status("Summary copied."))
	var files := HBoxContainer.new()
	files.add_child(copy)
	_template_btn = Button.new()
	_template_btn.text = "Export profile template"
	_template_btn.tooltip_text = "A 1:1 SVG of the trough's cross-section, the absorber and the acceptance lines — print it at 100 % and trace it onto the ribs"
	UITheme.style_button(_template_btn)
	_template_btn.pressed.connect(func() -> void: export_template())
	files.add_child(_template_btn)
	box.add_child(files)
	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status_lbl)
	_col = DesignerColumn.setup(box, "csplab", {"open": ["Optic"], "fold": ["Results", "Where the light goes"], "tiles": false})
	# The four headline tiles stay first, the search under them.
	box.move_child(_col.finder, 1)


## A headline number: big value, small caption, a coloured edge.
func _kpi_tile(key: String, caption: String, tip: String, col: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := UITheme.card_style()
	sb.border_width_left = 3
	sb.border_color = col
	sb.content_margin_left = 10
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.tooltip_text = tip
	pc.name = "kpi_" + key
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(v)
	var val := Label.new()
	val.text = "—"
	val.add_theme_font_override("font", UITheme.font("semibold", true))
	val.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	val.add_theme_color_override("font_color", UITheme.C_TEXT)
	val.clip_text = true
	val.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(val)
	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	cap.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(cap)
	_kpi[key] = val
	return pc


## Where the compound parabolic troughs come from, with the video.
func _make_cpc_credit() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var l := Label.new()
	l.text = "The string-and-square method from NightHawkInLight's video, as its closed-form curves."
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	h.add_child(l)
	var b := Button.new()
	b.text = "Watch the video"
	b.tooltip_text = CPC_VIDEO_URL
	UITheme.style_button(b)
	b.pressed.connect(func() -> void: OS.shell_open(CPC_VIDEO_URL))
	h.add_child(b)
	return h


func _build_optimize(box: VBoxContainer) -> void:
	_obj_opt = OptionButton.new()
	var i := 0
	for k in CspLabSpec.OBJECTIVES:
		_obj_opt.add_item(str(CspLabSpec.OBJECTIVES[k]), i)
		_obj_opt.set_item_metadata(i, k)
		i += 1
	box.add_child(FormRow.make("Maximise", _obj_opt, "What the search makes as large as it can"))
	_opt_box = VBoxContainer.new()
	box.add_child(_opt_box)
	var row := HBoxContainer.new()
	_opt_btn = Button.new()
	_opt_btn.text = "Optimize"
	_opt_btn.tooltip_text = "Golden-section search on each ticked number in turn, twice, on the same sunlight each time"
	UITheme.style_button(_opt_btn)
	_opt_btn.pressed.connect(start_optimize)
	row.add_child(_opt_btn)
	_opt_bar = ProgressBar.new()
	_opt_bar.min_value = 0.0
	_opt_bar.max_value = 1.0
	_opt_bar.show_percentage = false
	_opt_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opt_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_opt_bar.visible = false
	UITheme.style_progress(_opt_bar, UITheme.C_PRIMARY)
	row.add_child(_opt_bar)
	box.add_child(row)
	_opt_lbl = Label.new()
	_opt_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_opt_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_opt_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	box.add_child(_opt_lbl)


func _build_footer() -> void:
	_shell.set_hint("Drag to orbit · wheel to zoom · pick a day and hour to see it track · Ray trace 2D for the section · Ctrl+Z undoes")
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Place it with its graph node: it tracks the sun and boils water into steam from the site's direct sunlight")
	_apply_btn = _shell.add_button("Apply to placed", DesignerShell.SECONDARY, _on_apply)
	_shell.add_button("Close", DesignerShell.SECONDARY, close)


# ---------------------------------------------------------------------------
# Settings rows
# ---------------------------------------------------------------------------

func _build_settings_rows() -> void:
	_bindings.clear()
	var t := str(_spec["type"])
	for gk in _settings:
		var body: VBoxContainer = _settings[gk]
		for c in body.get_children():
			if c == _struct_box:
				continue
			body.remove_child(c)
			c.queue_free()
	for fv in CspLabSpec.FIELDS:
		var f: Dictionary = fv
		if not CspLabSpec.field_shown(f, t, _spec):
			continue
		var g := str(f["g"])
		var k := str(f["k"])
		var body2: VBoxContainer = _settings[g]
		var row: FormRow
		match str(f["kind"]):
			"spin":
				row = FormRow.spin(str(f["label"]), float(f["min"]), float(f["max"]), float(f["step"]), str(f.get("unit", "")),
					_on_field.bind(g, k), str(f.get("tip", "")), "%s_%s" % [g, k])
				var unit := str(f.get("unit", ""))
				if not unit.is_empty():
					(row.control as SpinBox).suffix = " " + unit
			"option":
				row = FormRow.option(str(f["label"]), CspLabSpec.items_for(str(f["items"]), t), _on_field.bind(g, k),
					str(f.get("tip", "")), "%s_%s" % [g, k])
			"check":
				row = FormRow.check(str(f["label"]), str(f.get("text", "")), _on_field.bind(g, k), str(f.get("tip", "")), "%s_%s" % [g, k])
		if row == null:
			continue
		body2.add_child(row)
		if g == "structure" and _struct_box != null:
			body2.move_child(_struct_box, body2.get_child_count() - 1)
		_bindings.append({"g": g, "k": k, "row": row})
	# The optimizer's parameters for this type.
	for c2 in _opt_box.get_children():
		_opt_box.remove_child(c2)
		c2.queue_free()
	_opt_checks.clear()
	for pv in CspLabSpec.opt_params(_spec):
		var p: Array = pv
		var label := _field_label(str(p[0]), str(p[1]), t)
		var cb := CheckBox.new()
		cb.text = "%s (%s–%s)" % [label, _num(float(p[2])), _num(float(p[3]))]
		cb.button_pressed = true
		cb.set_meta("param", p)
		_opt_box.add_child(cb)
		_opt_checks.append(cb)
	_built_type = _rows_key()


## The settings rows depend on the type and, for a trough, its profile.
func _rows_key() -> String:
	return str(_spec["type"]) + "|" + CspLabSpec.profile_of(_spec)


func _field_label(g: String, k: String, t: String) -> String:
	for fv in CspLabSpec.FIELDS:
		var f: Dictionary = fv
		if str(f["g"]) == g and str(f["k"]) == k and CspLabSpec.field_shown(f, t, _spec):
			return str(f["label"])
	return k


func _sync_settings() -> void:
	for bv in _bindings:
		var b: Dictionary = bv
		var v: Variant = (_spec[str(b["g"])] as Dictionary).get(str(b["k"]))
		(b["row"] as FormRow).set_value(v)
	_shell.name_edit.text = str(_spec["name"])
	for c in _type_box.get_children():
		if c is Button and c.has_meta("type"):
			(c as Button).set_pressed_no_signal(str(c.get_meta("type")) == str(_spec["type"]))


func _on_field(value: Variant, g: String, k: String) -> void:
	var cur: Variant = (_spec[g] as Dictionary).get(k)
	if cur is int and (value is float or value is int):
		value = int(value)
	_edit(g, k, value)


# ---------------------------------------------------------------------------
# Spec edits, undo
# ---------------------------------------------------------------------------

func _push_undo(key: String = "") -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not key.is_empty() and key == _coalesce_key and now < _coalesce_until:
		_coalesce_until = now + 0.8
		return
	_coalesce_key = key
	_coalesce_until = now + 0.8
	_undo.append(_spec.duplicate(true))
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	_shell.set_undo_state(not _undo.is_empty(), false)


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_spec.duplicate(true))
	_spec = _undo.pop_back()
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_rebuild_now()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_spec = _redo.pop_back()
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_rebuild_now()


func _edit(g: String, k: String, value: Variant) -> void:
	_push_undo("%s.%s" % [g, k])
	(_spec[g] as Dictionary)[k] = value
	_rebuild_timer = REBUILD_DELAY


## Replace the whole spec (a preset, a library design, the optimizer's answer).
func set_spec(spec: Dictionary) -> void:
	_push_undo()
	_spec = CspLabSpec.resolve(spec)
	_stamp_site()
	_section.reset_view()
	_rebuild_now()
	_frame_camera()
	if _tabs.current_tab == 2:
		_view_from_behind()


func _on_name_changed(text: String) -> void:
	if text.strip_edges().is_empty() or text == str(_spec["name"]):
		return
	_push_undo("name")
	_spec["name"] = text.strip_edges()
	_refresh_header()


func _on_type_pressed(t: String) -> void:
	if t == str(_spec["type"]):
		_sync_settings()
		return
	var s := CspLabSpec.default_spec(t)
	set_spec(s)


# ---------------------------------------------------------------------------
# Solve and refresh
# ---------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = CspLabSpec.resolve(_spec)
	_stamp_site()
	_design = CspLabDesign.solve(_spec)
	if _rows_key() != _built_type:
		_build_settings_rows()
	_sync_settings()
	_builder.rebuild(_spec, _design)
	_at_sun = {}
	_sun_dirty = true
	_ray_timer = 0.0
	_refresh_header()
	_refresh_results()
	_refresh_checks()
	_refresh_structure()
	_refresh_bom()
	_refresh_section()
	_apply_overlays()
	_template_btn.visible = str(_spec["type"]) == "parabolic_trough"
	_year_result = {}
	_refresh_year()


func _refresh_header() -> void:
	var t := str(_spec["type"])
	_type_why.text = str(CspLabSpec.TYPE_WHY[t])
	_refresh_legend()
	_shell.set_subtitle("%s · %s · %s" % [str(CspLabSpec.TYPE_LABELS[t]),
		"point focus" if str(CspLabSpec.FOCUS[t]) == "point" else "line focus", _site_name])
	var c := CspLabDesign.check_counts(_design)
	if int(c["error"]) > 0:
		_shell.set_badge(UiText.count(int(c["error"]), "problem") + " to fix", "error")
	elif int(c["warn"]) > 0:
		_shell.set_badge(UiText.count(int(c["warn"]), "warning"), "warn")
	else:
		_shell.set_badge("Checks pass", "ok")


## What the ray colours mean, over the 3D view.
func _refresh_legend() -> void:
	var mirror := str(CspLabSpec.OPTIC[str(_spec["type"])]) == "mirror"
	var lands := "[color=#ff9e26]━[/color] lands on the receiver" if mirror else "[color=#7fd0ff]━[/color] lands, in its wavelength's colour"
	_legend3d.text = I18n.f("[color=#fff299]━[/color] sunlight in   {lands}   [color=#ff4033]━[/color] misses   [color=#8c8c99]━[/color] shaded or blocked   [color=#f24dd9]━[/color] off the end   [color=#ffe066]●[/color] the sun", {"lands": lands})


func _set_res(key: String, text: String) -> void:
	(_res_rows[key] as FormRow).set_value(text)


func _refresh_results() -> void:
	var d := _design
	var g: Dictionary = d["geo"]
	var site: Dictionary = _spec["site"]
	_set_res("aperture", "%s m²" % _num(float(d["A_ap"])))
	_set_res("receiver", "%s m² · %s× geometric" % [_num(float(d["A_rec"])), _num(float(d["C_g"]))])
	_set_res("suns", "%s suns (%s× DNI)" % [_num(float(d["suns_mean"])), _num(float(d["C_mean"]))])
	_set_res("peak", "%s suns" % _num(float(d["suns_peak"])))
	_set_res("limit", "%s× (%s focus)" % [_num(float(d["C_limit"])), str(g["focus"])])
	_set_res("optical", UiText.pct(float(d["eta_opt"])))
	_set_res("intercept", UiText.pct(float(d["intercept"])))
	_set_res("heat", "%s of %s at %s °C" % [_kw(float(d["q_useful_kw"])), _kw(float(d["q_beam_kw"])), _num(float(site["op_temp_c"]))])
	_set_res("eta_th", UiText.pct(float(d["eta_th"])))
	_set_res("stag", "%s °C" % _num(float(d["stagnation_c"])))
	(_kpi["heat"] as Label).text = _kw(float(d["q_useful_kw"]))
	(_kpi["optical"] as Label).text = UiText.pct(float(d["eta_opt"]))
	(_kpi["suns"] as Label).text = "%s suns" % _num(float(d["suns_mean"]))
	(_kpi["stag"] as Label).text = "%s °C" % _num(float(d["stagnation_c"]))
	_set_res("steam", "%s kg/h" % _num(float(d["steam_kg_h"])) if float(d["steam_kg_h"]) > 0.0 else "below boiling")
	var mode := str((_spec["tracking"] as Dictionary)["mode"])
	var one_axis := mode in ["ns_horizontal", "ew_horizontal", "polar"] and not CspLabSite.is_field(_spec)
	var cpc := bool(g.get("cpc", false))
	(_res_rows["cpc"] as FormRow).visible = cpc
	_cpc_credit.visible = cpc
	(_res_rows["accept"] as FormRow).visible = cpc
	if cpc:
		var p: Dictionary = g["cpc_prof"]
		var ta := rad_to_deg(float(g["theta_a"]))
		_set_res("cpc", "±%s° · %s × %s m · mirror %s m/m" % [_num(ta), _num(float(g["a"]) * 2.0),
			_num(float(p["height"])), _num(float(p["arc_len"]))])
		var cols: Array = []
		for k in [0.5, 0.9, 1.2]:
			cols.append("%s @%s°" % [UiText.pct(CspLabDesign.across(d, ta * float(k))), "%.0f" % (ta * float(k))])
		_set_res("accept", " · ".join(PackedStringArray(cols)))
	(_res_rows["iam"] as FormRow).visible = one_axis
	if one_axis:
		_set_res("iam", "%s at 30° · %s at 60°" % [UiText.pct(CspLabDesign.iam(d, 30.0)), UiText.pct(CspLabDesign.iam(d, 60.0))])
	for c in _loss_box.get_children():
		_loss_box.remove_child(c)
		c.queue_free()
	var tr: Dictionary = d["trace"]
	var losses: Dictionary = tr["losses"]
	var rows: Array = []
	for k in losses:
		if float(losses[k]) > 0.0005:
			rows.append([str(CspLabOptics.LOSS_LABELS.get(k, k)), float(losses[k]), UITheme.C_ERROR if k == "spill" or k == "end" else UITheme.C_WARN])
	rows.append(["Absorbed by the receiver", float(d["eta_opt"]), UITheme.C_OK])
	var lost_rec := float(d["eta_capture"]) - float(d["eta_opt"])
	if lost_rec > 0.0005:
		rows.append(["Reflected off the receiver", lost_rec, UITheme.C_WARN])
	for r in rows:
		var h := HBoxContainer.new()
		var l := Label.new()
		l.text = str(r[0])
		l.custom_minimum_size = Vector2(210, 0)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		h.add_child(l)
		var pb := ProgressBar.new()
		pb.min_value = 0.0
		pb.max_value = 1.0
		pb.value = float(r[1])
		pb.show_percentage = false
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pb.custom_minimum_size = Vector2(60, 8)
		UITheme.style_progress(pb, r[2] as Color)
		h.add_child(pb)
		var v := Label.new()
		v.text = UiText.pct(float(r[1]))
		v.custom_minimum_size = Vector2(46, 0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.add_theme_font_override("font", UITheme.font("medium", true))
		v.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		h.add_child(v)
		_loss_box.add_child(h)


func _refresh_checks() -> void:
	for c in _warn_box.get_children():
		_warn_box.remove_child(c)
		c.queue_free()
	var checks: Array = _design.get("checks", []) as Array
	if checks.is_empty():
		var ok := Label.new()
		ok.text = "Nothing to fix."
		ok.add_theme_color_override("font_color", UITheme.C_OK)
		_warn_box.add_child(ok)
		return
	for cv in checks:
		var c: Dictionary = cv
		var lv := str(c["level"])
		var l := Label.new()
		l.text = ("✕ " if lv == "error" else ("! " if lv == "warn" else "· ")) + str(c["text"])
		l.tooltip_text = str(c.get("why", ""))
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_ERROR if lv == "error" else (UITheme.C_WARN if lv == "warn" else UITheme.C_TEXT_S))
		_warn_box.add_child(l)


func _refresh_structure() -> void:
	for c in _struct_box.get_children():
		_struct_box.remove_child(c)
		c.queue_free()
	var st: Dictionary = _design["structure"]
	var loads: Dictionary = st.get("loads", {}) as Dictionary
	var drv: Dictionary = st.get("drive", {}) as Dictionary
	_struct_box.add_child(SectionHeader.make("What it carries", "wrench"))
	var lines: Array = [
		["Mount", str(CspLabSpec.MOUNTS.get(str(st.get("mount", "")), ""))],
		["Structure", "%s kg of steel (optic %s kg)" % [_num(float(st["mass_kg"])), _num(float(_design["optic_mass_kg"]))]],
		["Foundations", "%s m³ of concrete (%s kg)" % [_num(float(st.get("concrete_m3", 0.0))), _num(float(st.get("concrete_kg", 0.0)))]],
		["Wind on it", "%s N" % _num(float(loads.get("wind_force_n", 0.0)))],
		["Base moment", "%s N·m" % _num(float(loads.get("base_moment_nm", 0.0)))],
		["Stress", "%s MPa (%s of allowed)" % [_num(float(loads.get("stress_mpa", 0.0))), UiText.pct(float(loads.get("utilisation", 0.0)))]],
	]
	if float(st.get("counterweight_kg", 0.0)) > 0.0:
		lines.append(["Counterweight", "%s kg on %s m arms behind the axis" % [_num(float(st["counterweight_kg"])), _num(float(st.get("cw_arm_m", 0.0)))]])
	if loads.has("deflection_mrad"):
		lines.append(["Pointing sag", "%s mrad in the tracking wind" % _num(float(loads["deflection_mrad"]))])
	if loads.has("twist_mrad"):
		lines.append(["Tube twist", "%s mrad at the ends" % _num(float(loads["twist_mrad"]))])
	if not drv.is_empty():
		lines.append(["Drive", "%s (turns %s, holds %s N·m)" % [str(drv["label"]), _num(float(drv["turn_nm"])), _num(float(drv["hold_nm"]))]])
		lines.append(["Needs", "turning %s · holding %s N·m" % [_num(float(loads.get("drive_turn_nm", 0.0))), _num(float(loads.get("drive_hold_nm", 0.0)))]])
	for l in lines:
		_struct_box.add_child(FormRow.value(str(l[0]), str(l[1])))
	var hint := Label.new()
	hint.text = "In the Structure view, point at a member to name it."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_struct_box.add_child(hint)


func _refresh_bom() -> void:
	for c in _bom_box.get_children():
		_bom_box.remove_child(c)
		c.queue_free()
	for rv in (_design.get("bom", []) as Array):
		var r: Dictionary = rv
		var unit := str(r["unit"])
		var qty := "%s %s" % [_num(float(r["qty"])), unit] if not unit.is_empty() else "×%d" % int(float(r["qty"]))
		var txt := "%s · %s kg" % [qty, _num(float(r["kg"]))] if float(r["kg"]) > 0.0 else qty
		_bom_box.add_child(FormRow.value(str(r["item"]), txt))
	_bom_box.add_child(FormRow.value("Total to lift", "%s kg (footings poured on site)" % _num(CspLabDesign.bom_mass(_design))))


# ---------------------------------------------------------------------------
# The moment shown: sun, pose, rays, the site now
# ---------------------------------------------------------------------------

func _sync_time_controls() -> void:
	_month_opt.select(clampi(_month - 1, 0, 11))
	_day_spin.max_value = CspLabSite.days_in_month(_year, _month)
	_day = clampi(_day, 1, int(_day_spin.max_value))
	_day_spin.set_value_no_signal(_day)
	_hour_slider.set_value_no_signal(_hour)
	_hour_lbl.text = "%02d:%02d" % [int(_hour) % 24, int(fmod(_hour, 1.0) * 60.0)]


func _update_sun() -> void:
	var sun := CspLabSite.sun_at(_lat, _lon, _year, _month, _day, _hour)
	_sun = sun["s"] as Vector3
	_builder.set_sun(_sun)
	var pose := _builder.last_pose
	var sl: Vector3 = pose.get("sun_local", Vector3.UP)
	var paths: Array = []
	if float(sun["el"]) > 0.0:
		var n := PLAY_RAYS if _playing else VIEW_RAYS
		var tr := CspLabOptics.trace(_design["geo"] as Dictionary, sl, n, {"seed": 9, "max_paths": PATHS})
		paths = tr["paths"]
		_at_sun = tr
	else:
		_at_sun = {}
	_builder.set_rays(paths)
	_refresh_now(sun)
	if _sec_site.button_pressed:
		_refresh_section()


func _refresh_now(sun: Dictionary) -> void:
	for c in _now_box.get_children():
		_now_box.remove_child(c)
		c.queue_free()
	var el := float(sun["el"])
	var rows: Array = [["Site", _site_name], ["Sun", "az %s°, elevation %s°" % [_num(float(sun["az"])), _num(el)]]]
	var pose := _builder.last_pose
	var angs: Dictionary = pose.get("angles", {}) as Dictionary
	var at := []
	for k in angs:
		at.append("%s %s°" % [str(k).to_lower(), _num(float(angs[k]))])
	if not at.is_empty():
		rows.append(["Tracker", ", ".join(PackedStringArray(at))])
	if el <= 0.0:
		rows.append(["Now", "The sun is down: stowed, nothing made."])
		_hover_lbl.text = "Night — stowed"
	else:
		var weather := SolarIrradiance.sample_weather(_lat, _lon, _month, _day, _hour, _ws())
		var o := CspLabSite.output_now(_design, _sun, weather, _lat)
		var src := "measured weather" if bool(weather.get("has_real", false)) else "clear sky (no weather data here)"
		rows.append(["Direct (DNI)", "%s W/m² (%s)" % [_num(float(o["dni"])), src]])
		rows.append(["Global (GHI)", "%s W/m², of it diffuse %s W/m²" % [_num(float(o["ghi"])), _num(float(o["dhi"]))]])
		rows.append(["Optical efficiency", UiText.pct(float(o["eta"]) * float((_design["geo"] as Dictionary)["alpha"]))])
		rows.append(["Heat now", "%s (steam %s kg/h)" % [_kw(float(o["thermal_kw"])), _num(float(o["steam_kg_h"]))]])
		var suns := float(_at_sun.get("mean_suns", 0.0)) * float(o["dni"]) / 1000.0
		_builder.set_glow(suns)
		_hover_lbl.text = I18n.f("{hour} · DNI {dni} W/m² · {thermal_kw}", {"hour": _hour_lbl.text, "dni": _num(float(o["dni"])), "thermal_kw": _kw(float(o["thermal_kw"]))})
	for r in rows:
		_now_box.add_child(FormRow.value(str(r[0]), str(r[1])))
	var note := Label.new()
	note.text = "A concentrator only uses the direct beam; a flat solar panel would also take the diffuse sky."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_now_box.add_child(note)
	var use := Button.new()
	use.text = "Use the game's clock"
	UITheme.style_button(use)
	use.pressed.connect(func() -> void:
		_read_site()
		_sync_time_controls()
		_sun_dirty = true)
	_now_box.add_child(use)


## The Structure view looks at the back of the optic, where the frame is:
## three-quarter on from the side away from the sun (a field keeps its view).
func _view_from_behind() -> void:
	if CspLabSite.is_field(_spec) or _sun.y <= 0.0:
		return
	var h := Vector2(_sun.x, _sun.z)
	if h.length() < 0.05:
		h = Vector2(0, 1)
	_studio.set_orbit(atan2(-h.x, -h.y) + 0.65, 0.3)
	_place_person()


## Structure view: name the member under the pointer and light it up.
func _on_studio_hover(pos: Vector2) -> void:
	if _tabs.current_tab != 2:
		return
	var r := _studio.pick_ray(pos)
	var m := {} if r.is_empty() else _builder.pick_member(r["origin"] as Vector3, r["dir"] as Vector3)
	_builder.highlight_member(m)
	if m.is_empty():
		_member_lbl.visible = false
		return
	_member_lbl.text = describe_member(m)
	_member_lbl.visible = true
	_member_lbl.reset_size()
	_member_lbl.position = (pos + Vector2(16, 12)).clamp(Vector2.ZERO, _view_stack.size - _member_lbl.size)


## A member in words: what it is, its section, its length and weight.
func describe_member(m: Dictionary) -> String:
	var lab := str(m.get("label", "Member"))
	var a: Vector3 = m["a"]
	var b: Vector3 = m["b"]
	var length := a.distance_to(b)
	var mk := str(m.get("mat", ""))
	if mk == "concrete":
		return "%s · %s × %s m, %s m deep · %s kg" % [lab, _num(float(m["w"])), _num(float(m["h"])), _num(length - 0.1), _num(float(m["mass"]))]
	if bool(m.get("box", false)):
		var kg := float(m.get("mass", 0.0))
		return "%s · %s × %s × %s m%s" % [lab, _num(float(m["w"])), _num(float(m["h"])), _num(length), (" · %s kg" % _num(kg)) if kg > 0.0 else ""]
	var mat := CspLabParts.struct_material(str((_spec["structure"] as Dictionary)["material"]))
	var tp := CspLabStructure.tube_props(float(m["d"]), float(m["t"]))
	return "%s · Ø%s × %s mm %s · %s m · %s kg" % [lab, _num(float(m["d"]) * 1000.0), _num(float(m["t"]) * 1000.0),
		str(mat["label"]).to_lower(), _num(length), _num(length * float(tp["A"]) * float(mat["density"]))]


func _on_play() -> void:
	_playing = not _playing
	if _playing:
		var sun := CspLabSite.sun_at(_lat, _lon, _year, _month, _day, _hour)
		if float(sun["el"]) <= 0.0 or _hour > 18.0:
			_hour = 5.0
	_play_btn.text = "Pause" if _playing else "Play the day"


func _apply_overlays() -> void:
	_builder.set_overlays(_rays_chk.button_pressed, _axes_chk.button_pressed)


func _frame_camera() -> void:
	var bb := _builder.frame_aabb()
	_studio.frame_aabb(bb, 0.45, 1.4)
	_place_person()


## The scale figure stands beyond the subject's far side from the camera,
## never between them (a 1.75 m figure hid a 0.8 m trough).
func _place_person() -> void:
	if _studio.person == null:
		return
	var bb := _builder.frame_aabb()
	var r := maxf(bb.size.x, bb.size.z) * 0.5
	var c := Vector2(bb.position.x + bb.size.x * 0.5, bb.position.z + bb.size.z * 0.5)
	var toward := Vector2(sin(_studio.yaw), cos(_studio.yaw))
	var side := Vector2(toward.y, -toward.x)
	var at := c - toward * (r * 0.6 + 0.9) + side * (r * 0.8 + 0.6)
	_studio.person.position = Vector3(at.x, 0.875, at.y)


func _show_view() -> void:
	var i := _tabs.current_tab
	_studio.visible = i == 0 or i == 2
	_studio.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if _studio.visible else SubViewport.UPDATE_DISABLED
	_section_wrap.visible = i == 1
	_year_wrap.visible = i == 3
	_legend3d.visible = i == 0
	_member_lbl.visible = false
	_builder.highlight_member({})
	if i == 2:
		_rays_chk.set_pressed_no_signal(false)
		_axes_chk.set_pressed_no_signal(true)
		_view_from_behind()
	elif i == 0:
		_rays_chk.set_pressed_no_signal(true)
		_axes_chk.set_pressed_no_signal(false)
		if _last_tab == 2:
			_studio.reset_orbit()
			_place_person()
	_last_tab = i
	_apply_overlays()
	if i == 1:
		_refresh_section()
	if i == 3:
		_refresh_year()


# ---------------------------------------------------------------------------
# The 2D section
# ---------------------------------------------------------------------------

func _section_sun() -> Vector3:
	if _sec_site.button_pressed:
		var p := _builder.last_pose
		var sl: Vector3 = p.get("sun_local", Vector3.UP)
		if sl.y > 0.0:
			return sl
	return CspLabDesign.design_sun_local(_spec)


func _refresh_section() -> void:
	if _section == null or _design.is_empty():
		return
	var g: Dictionary = _design["geo"]
	var sl := _section_sun()
	var bands: Array = [0, 1, 2, 3] if _sec_bands.button_pressed else [0]
	var paths := CspLabOptics.trace_section(g, sl, SECTION_RAYS, {"bands": bands,
		"spread": _sec_spread.button_pressed, "errors": _sec_errors.button_pressed})
	var tower := str(g["type"]) == "tower"
	var pole: Vector3 = g.get("pole", Vector3.FORWARD) as Vector3
	var lines: Array = []
	var cap := 0
	for pv in paths:
		var p: Dictionary = pv
		var pts := PackedVector2Array()
		for q in (p["pts"] as PackedVector3Array):
			pts.append(Vector2(q.dot(pole), q.y) if tower else Vector2(q.x, q.y))
		lines.append({"pts": pts, "fate": str(p["fate"]), "band": int(p["band"])})
		if str(p["fate"]) == "captured":
			cap += 1
	_section.profile = CspLabOptics.section_profile(g, sl)
	_section.rays = lines
	_section.mirror = str(g["optic_kind"]) == "mirror"
	_section.caption = "%s · %d of %d rays land on the receiver" % [
		"The chosen moment's sun" if _sec_site.button_pressed else "Design point", cap, paths.size()]
	_section.horizontal = "distance toward the pole (m)" if tower else "across the aperture (m)"
	_section.queue_redraw()


# ---------------------------------------------------------------------------
# The year
# ---------------------------------------------------------------------------

func run_year() -> void:
	_year_job = CspLabSite.Year.new(_design, _lat, _lon, _year, _ws())
	_year_bar.visible = true
	_year_bar.value = 0.0
	_year_btn.disabled = true
	_year_lbl.text = "Tracing the year…"


## Finish the year synchronously (the harness).
func run_year_now() -> Dictionary:
	run_year()
	while _year_job != null and not _year_job.step(1000.0):
		pass
	_year_result = _year_job.result() if _year_job != null else _year_result
	_year_job = null
	_year_bar.visible = false
	_year_btn.disabled = false
	_refresh_year()
	return _year_result


func _refresh_year() -> void:
	if _year_canvas == null:
		return
	_year_canvas.result = _year_result
	_year_canvas.queue_redraw()
	if _year_result.is_empty():
		if _year_job == null:
			var covered := _ws() != null and _ws().has_method("covers") and bool(_ws().call("covers", _lat, _lon))
			_year_lbl.text = I18n.f("At {site_name}, from {covered}. Run it to see the heat month by month.", {
				"site_name": _site_name,
				"covered": "the site's weather" if covered else "a cloudless clear sky (no weather data loaded here)",
			})
		return
	var r := _year_result
	var cap_kw := maxf(float(_design["q_useful_kw"]), 1e-6)
	_year_lbl.text = I18n.f("{annual_kwh} of heat a year · {run_hours} h running · direct beam {annual_dni} kWh/m² vs global {annual_ghi} kWh/m² (direct is {direct_share} of the light on the ground) · capacity factor {annual_kwh_2}", {
		"annual_kwh": _kwh(float(r["annual_kwh"])),
		"run_hours": _num(float(r["run_hours"])),
		"annual_dni": _num(float(r["annual_dni"])),
		"annual_ghi": _num(float(r["annual_ghi"])),
		"direct_share": UiText.pct(float(r["direct_share"])),
		"annual_kwh_2": UiText.pct(float(r["annual_kwh"]) / (cap_kw * 8760.0)),
	})


# ---------------------------------------------------------------------------
# Optimize
# ---------------------------------------------------------------------------

func start_optimize() -> void:
	if _opt != null:
		_opt = null
		_opt_btn.text = "Optimize"
		_opt_bar.visible = false
		_opt_lbl.text = "Stopped."
		return
	var params: Array = []
	for cb in _opt_checks:
		if (cb as CheckBox).button_pressed:
			params.append((cb as CheckBox).get_meta("param"))
	if params.is_empty():
		_opt_lbl.text = "Tick at least one number to vary."
		return
	var obj := str(_obj_opt.get_item_metadata(_obj_opt.selected))
	_opt_spec_before = _spec.duplicate(true)
	_opt = CspLabOptimizer.new(_spec, params, obj, mini(int((_spec["trace"] as Dictionary)["rays"]), 1500))
	_opt_btn.text = "Stop"
	_opt_bar.visible = true
	_opt_bar.value = 0.0


## Run the search to the end synchronously (the harness).
func optimize_now() -> Dictionary:
	if _opt == null:
		start_optimize()
	while _opt != null and not _opt.step():
		pass
	if _opt != null:
		return _finish_optimize()
	return {}


func _finish_optimize() -> Dictionary:
	var opt := _opt
	_opt = null
	_opt_btn.text = "Optimize"
	_opt_bar.visible = false
	var out := {"start": opt.start_value, "best": opt.best_value, "evals": opt.evals}
	if opt.best_value > opt.start_value + 1e-9:
		var best := opt.best_spec.duplicate(true)
		best["name"] = str(_spec["name"])
		set_spec(best)
		var changed: Array = []
		for p in opt.params:
			var a := float((_opt_spec_before[str(p[0])] as Dictionary)[str(p[1])])
			var b := float((best[str(p[0])] as Dictionary)[str(p[1])])
			if absf(a - b) > 1e-6:
				changed.append("%s %s → %s" % [_field_label(str(p[0]), str(p[1]), str(_spec["type"])).to_lower(), _num(a), _num(b)])
		_opt_lbl.text = I18n.f("Better: {start} → {best} after {evals} designs. {changed}. Ctrl+Z puts it back.", {
			"start": _fmt_obj(opt.start_value),
			"best": _fmt_obj(opt.best_value),
			"evals": "%d" % opt.evals,
			"changed": ", ".join(PackedStringArray(changed)),
		})
	else:
		_opt_lbl.text = I18n.f("Nothing better within these ranges ({evals} designs tried).", {"evals": "%d" % opt.evals})
	return out


func _fmt_obj(v: float) -> String:
	var obj := str(_obj_opt.get_item_metadata(_obj_opt.selected))
	match obj:
		"optical":
			return UiText.pct(v)
		"suns":
			return "%s×" % _num(v)
		"kw_per_m2":
			return "%s kW/m²" % _num(v)
	return _kw(v)


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------

## One design's picture for the gallery: its key and how to build it.
func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _design_entries.size():
		return {}
	var spec: Dictionary = CspLabSpec.resolve(((_design_entries[i] as Dictionary)["spec"] as Dictionary).duplicate(true))
	return {"key": JSON.stringify(spec), "build": func() -> Node3D:
		return CspLabBuilder.build_node(spec, "Thumb")}


func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for p in CspLabPresets.builtins():
		_design_list.add_item(str((p as Dictionary)["label"]))
		_design_list.set_item_tooltip(_design_list.item_count - 1, str((p as Dictionary).get("blurb", "")))
		_design_list.set_item_subtitle(_design_list.item_count - 1, str((p as Dictionary).get("blurb", "")))
		_design_entries.append({"spec": (p as Dictionary)["spec"], "builtin": true, "id": str((p as Dictionary)["id"])})
	for dv in _library:
		var d: Dictionary = dv
		_design_list.add_item("★ " + str(d["name"]))
		_design_entries.append({"spec": d["spec"], "builtin": false, "id": str(d["id"])})


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _design_entries.size():
		return
	set_spec(((_design_entries[idx] as Dictionary)["spec"] as Dictionary).duplicate(true))


func _on_save_design() -> void:
	var nm := str(_spec["name"])
	var replaced := false
	for dv in _library:
		if str((dv as Dictionary)["name"]) == nm:
			(dv as Dictionary)["spec"] = CspLabSpec.to_json_safe(_spec)
			replaced = true
	if not replaced:
		_library.append({"id": "csp_%d" % int(Time.get_unix_time_from_system()), "name": nm, "spec": CspLabSpec.to_json_safe(_spec)})
	CspLabPresets.save_library(_library)
	_refresh_design_list()
	_status("Saved “%s” to your library." % nm)


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		_status("Pick a saved design (★) to forget.")
		return
	var e: Dictionary = _design_entries[sel[0]]
	if bool(e["builtin"]):
		_status("Built-in designs can't be forgotten.")
		return
	_library = _library.filter(func(x: Variant) -> bool: return str((x as Dictionary)["id"]) != str(e["id"]))
	CspLabPresets.save_library(_library)
	_refresh_design_list()
	_status("Forgotten.")


# ---------------------------------------------------------------------------
# World
# ---------------------------------------------------------------------------

func _graph() -> Node:
	var main := _main_node()
	return main.find_child("SystemGraphView", true, false) if main != null else null


func _on_place() -> void:
	var gv := _graph()
	if gv != null and gv.has_method("place_designed_csp"):
		if bool(gv.call("place_designed_csp", CspLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a world with the systems graph.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	if main == null:
		return
	PlacedPropService.update_prop_record(main, _bound_prop_id, {"csplab_spec": CspLabSpec.to_json_safe(_spec)}, true)
	var gv := _graph()
	var rec := _prop_record(_bound_prop_id)
	var gid := str(rec.get("graph_item_id", ""))
	if gv != null and not gid.is_empty() and gv.has_method("apply_csp_design"):
		gv.call("apply_csp_design", gid, CspLabSpec.to_json_safe(_spec))
	_status("Applied to the placed concentrator.")
	close()


func _prop_record(prop_id: String) -> Dictionary:
	var main := _main_node()
	if main == null:
		return {}
	var rec0 := PlacedPropService.get_prop_record(main, prop_id)
	if not rec0.is_empty():
		return rec0.duplicate(true)
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("get_prop_record"):
		var r: Variant = loader.call("get_prop_record", prop_id)
		if r is Dictionary:
			return (r as Dictionary).duplicate(true)
	return {}


## The motors panel's data: the bound placed concentrator's live drives
## (its runtime, on the world's clock) or the studio's at the chosen moment.
func motors_source() -> Dictionary:
	var out := {"prop_id": _bound_prop_id, "name": str(_spec.get("name", "concentrator")), "live": false,
		"status": "", "chans": []}
	var rt := bound_runtime()
	if rt != null:
		out["live"] = true
		out["chans"] = rt.channels
		out["status"] = rt.ha_status
		return out
	if _builder != null and not _design.is_empty():
		out["chans"] = CspLabActuators.channels(_design, _builder.last_pose)
	return out


func motors_main() -> Node:
	return _main_node()


## The runtime on the bound placed concentrator (null when unbound).
func bound_runtime() -> CspLabRuntime:
	if _bound_prop_id.is_empty():
		return null
	var main := _main_node()
	if main == null:
		return null
	return CspLabRuntime.of(PlacedPropRuntime.find_by_prop_id(main, _bound_prop_id))


func motors_panel() -> VBoxContainer:
	return _motors


func motors_section() -> Collapsible:
	return _motors_sec


## The trough's profile as a 1:1 SVG template (user://csplab_designs/).
## Returns the file's absolute path ("" on failure).
func export_template() -> String:
	var g: Dictionary = _design["geo"]
	if str(g["type"]) != "parabolic_trough":
		return ""
	var right := PackedVector2Array()
	var absorber := {}
	var ta := 0.0
	if bool(g.get("cpc", false)):
		right = (g["cpc_prof"] as Dictionary)["right"]
		ta = float(g["theta_a"])
		if str(g["profile"]) == "cpc_tube":
			absorber = {"kind": "tube", "y": float(g["rec_y"]), "r": float(g["rec_r"]), "r_mirror": float(g["r_mirror"])}
		else:
			absorber = {"kind": "flat", "a": float(g["rec_r"]), "y": 0.0}
	else:
		var a := float(g["a"])
		var f := float(g["f"])
		for i in 61:
			var x := a * float(i) / 60.0
			right.append(Vector2(x, x * x / (4.0 * f)))
		absorber = {"kind": "tube", "y": float(g["rec_y"]), "r": float(g["rec_r"])}
	var title := "%s — %s" % [str(_spec["name"]), str(CspLabSpec.TROUGH_PROFILES.get(str(g["profile"]), ""))]
	var svg := CspLabCpc.svg_template(right, absorber, ta, title)
	DirAccess.make_dir_recursive_absolute("user://csplab_designs")
	var path := "user://csplab_designs/%s_profile.svg" % str(_spec["name"]).to_snake_case().validate_filename()
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		_status("Couldn't write the template.")
		return ""
	fa.store_string(svg)
	fa.close()
	var abs_path := ProjectSettings.globalize_path(path)
	_status("Template written: %s (print at 100 %%)." % abs_path)
	return abs_path


func _status(text: String) -> void:
	_status_lbl.text = text


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

static func _num(v: float) -> String:
	var a := absf(v)
	if a >= 1000.0:
		return UiText.thousands(int(roundf(v)))
	if a >= 100.0:
		return "%.0f" % v
	if a >= 10.0:
		return "%.1f" % v
	if a >= 1.0:
		return "%.2f" % v
	if a >= 0.01:
		return "%.3f" % v
	if a == 0.0:
		return "0"
	return "%.4f" % v


static func _kw(kw: float) -> String:
	return "%s W" % _num(kw * 1000.0) if absf(kw) < 1.0 else "%s kW" % _num(kw)


static func _kwh(kwh: float) -> String:
	return "%s MWh" % _num(kwh / 1000.0) if kwh >= 10000.0 else "%s kWh" % _num(kwh)


# ---------------------------------------------------------------------------
# Accessors (the harness, the tour)
# ---------------------------------------------------------------------------

func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func builder() -> CspLabBuilder:
	return _builder


func studio() -> StudioViewport:
	return _studio


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


func set_moment(month: int, day: int, hour: float) -> void:
	_month = month
	_day = day
	_hour = hour
	_sync_time_controls()
	_update_sun()


func at_sun() -> Dictionary:
	return _at_sun


func year_result() -> Dictionary:
	return _year_result


func section_counts() -> Vector2i:
	var cap := 0
	for r in _section.rays:
		if str((r as Dictionary)["fate"]) == "captured":
			cap += 1
	return Vector2i(cap, _section.rays.size())


func control_for(g: String, k: String) -> Control:
	for bv in _bindings:
		if str((bv as Dictionary)["g"]) == g and str((bv as Dictionary)["k"]) == k:
			return ((bv as Dictionary)["row"] as FormRow).control
	return null


func shell() -> DesignerShell:
	return _shell


# ---------------------------------------------------------------------------
# Canvases
# ---------------------------------------------------------------------------

class SectionCanvas:
	extends Control
	var owner_modal: Control = null
	var profile: Array = []
	var rays: Array = []
	var mirror := true
	var caption := ""
	var horizontal := ""
	var _hover := Vector2.INF
	var _xf_scale := 1.0
	var _xf_off := Vector2.ZERO
	## The view on top of the fit: px = fit_px · zoom + pan.
	var zoom := 1.0
	var pan := Vector2.ZERO
	var _drag := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		clip_contents = true
		mouse_exited.connect(func() -> void: _hover = Vector2.INF; queue_redraw())

	func reset_view() -> void:
		zoom = 1.0
		pan = Vector2.ZERO
		queue_redraw()

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion:
			var mm := e as InputEventMouseMotion
			_hover = mm.position
			if _drag:
				pan += mm.relative
			queue_redraw()
		elif e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				var k := 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
				var nz := clampf(zoom * k, 0.5, 60.0)
				k = nz / zoom
				zoom = nz
				pan = mb.position - (mb.position - pan) * k
				accept_event()
				queue_redraw()
			elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
				if mb.double_click:
					reset_view()
				_drag = mb.pressed
				accept_event()

	func _to_px(p: Vector2) -> Vector2:
		return Vector2(p.x * _xf_scale + _xf_off.x, -p.y * _xf_scale + _xf_off.y)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.045, 0.07))
		if profile.is_empty():
			return
		# Fit everything (profile and rays) with a margin, y up.
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for pv in profile:
			for q in ((pv as Dictionary)["pts"] as PackedVector2Array):
				lo = lo.min(q)
				hi = hi.max(q)
		for rv in rays:
			var pts: PackedVector2Array = (rv as Dictionary)["pts"]
			for k in range(1, pts.size()):
				lo = lo.min(pts[k])
				hi = hi.max(pts[k])
		var span := (hi - lo).max(Vector2(0.05, 0.05))
		var pad := 36.0
		_xf_scale = minf((size.x - pad * 2.0) / span.x, (size.y - pad * 2.0 - 24.0) / span.y)
		var mid := (lo + hi) * 0.5
		_xf_off = Vector2(size.x * 0.5 - mid.x * _xf_scale, size.y * 0.5 + 10.0 + mid.y * _xf_scale)
		_xf_off = _xf_off * zoom + pan
		_xf_scale *= zoom
		# The grid covers what is on screen.
		var vlo := Vector2((0.0 - _xf_off.x) / _xf_scale, -(size.y - _xf_off.y) / _xf_scale)
		var vhi := Vector2((size.x - _xf_off.x) / _xf_scale, -(0.0 - _xf_off.y) / _xf_scale)
		_grid(vlo, vhi)
		# Rays under the optic outline.
		for rv2 in rays:
			var r: Dictionary = rv2
			var pts2: PackedVector2Array = r["pts"]
			var fate := str(r["fate"])
			var bc: Color = CspLabParts.band(int(r["band"]))["color"]
			for k2 in pts2.size() - 1:
				var c: Color
				if k2 == 0:
					c = Color(1.0, 0.95, 0.6, 0.35)
				elif fate == "captured":
					c = Color(1.0, 0.62, 0.15, 0.85) if mirror else Color(bc.r, bc.g, bc.b, 0.85)
				elif fate == "shaded" or fate == "blocked":
					c = Color(0.55, 0.55, 0.6, 0.6)
				elif fate == "end":
					c = Color(0.95, 0.3, 0.85, 0.8)
				else:
					c = Color(1.0, 0.25, 0.2, 0.75)
				draw_line(_to_px(pts2[k2]), _to_px(pts2[k2 + 1]), c, 1.2, true)
		for pv2 in profile:
			var p: Dictionary = pv2
			var pts3 := PackedVector2Array()
			for q2 in (p["pts"] as PackedVector2Array):
				pts3.append(_to_px(q2))
			var kind := str(p["kind"])
			var closed := bool(p.get("closed", false))
			var col := Color(0.85, 0.88, 0.95)
			var width := 3.0
			match kind:
				"lens":
					col = Color(0.6, 0.85, 0.95)
					width = 1.5
				"water":
					col = Color(0.35, 0.6, 0.95)
					width = 1.5
				"receiver":
					col = Color(1.0, 0.5, 0.15)
					width = 2.0
				"tower":
					col = Color(0.5, 0.52, 0.56)
					width = 2.0
				"ground":
					col = Color(0.45, 0.38, 0.28)
					width = 2.0
				"guide":
					col = Color(0.35, 0.6, 1.0, 0.7)
					width = 1.0
			if closed and pts3.size() >= 3 and (kind == "lens" or kind == "water" or kind == "receiver"):
				var fill := Color(col.r, col.g, col.b, 0.18 if kind != "receiver" else 0.9)
				if kind == "receiver":
					fill = Color(0.12, 0.08, 0.06, 0.95)
				if Geometry2D.triangulate_polygon(pts3).size() > 0:
					draw_colored_polygon(pts3, fill)
			if closed and pts3.size() >= 2:
				pts3.append(pts3[0])
			if kind == "guide":
				for gi in range(pts3.size() - 1):
					draw_dashed_line(pts3[gi], pts3[gi + 1], col, width, 6.0)
			elif pts3.size() >= 2:
				draw_polyline(pts3, col, width, true)
		var f := ThemeDB.fallback_font
		draw_string(f, Vector2(12, 20), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT_S)
		draw_rect(Rect2(Vector2(0, size.y - 22), Vector2(size.x, 22)), Color(0.035, 0.045, 0.07, 0.9))
		var tail := "   ·   wheel zooms, drag pans, double-click resets" + ("   (×%s)" % str(snappedf(zoom, 0.1)) if absf(zoom - 1.0) > 0.01 else "")
		draw_string(f, Vector2(12, size.y - 10), "→ " + horizontal + "   ↑ height (m)" + tail, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)
		_legend(f)
		if _hover != Vector2.INF:
			var w := Vector2((_hover.x - _xf_off.x) / _xf_scale, -(_hover.y - _xf_off.y) / _xf_scale)
			draw_string(f, _hover + Vector2(12, -8), "%.3f, %.3f m" % [w.x, w.y], HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT)

	## What the colours mean, top right.
	func _legend(f: Font) -> void:
		var items: Array = [[Color(1.0, 0.95, 0.6, 0.8), "sunlight in"],
			[Color(1.0, 0.62, 0.15) if mirror else Color(0.5, 0.82, 1.0), "lands on the receiver" if mirror else "lands (by wavelength)"],
			[Color(1.0, 0.25, 0.2), "misses"], [Color(0.55, 0.55, 0.6), "shaded / blocked"],
			[Color(0.35, 0.6, 1.0), "acceptance / guides"]]
		var y := 16.0
		var w := 0.0
		for it in items:
			w = maxf(w, f.get_string_size(str(it[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS).x)
		var x := size.x - w - 34.0
		draw_rect(Rect2(Vector2(x - 8, 6), Vector2(w + 36, items.size() * 15.0 + 8)), Color(0.02, 0.03, 0.05, 0.75))
		for it2 in items:
			draw_line(Vector2(x, y - 4), Vector2(x + 16, y - 4), it2[0] as Color, 2.0)
			draw_string(f, Vector2(x + 22, y), str(it2[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_S)
			y += 15.0

	func _grid(lo: Vector2, hi: Vector2) -> void:
		var span := maxf(hi.x - lo.x, hi.y - lo.y)
		var step := pow(10.0, floorf(log(span) / log(10.0)))
		if span / step < 4.0:
			step *= 0.5
		var f := ThemeDB.fallback_font
		var c := Color(1, 1, 1, 0.05)
		var x := floorf((lo.x - step) / step) * step
		while x <= hi.x + step:
			var px := _to_px(Vector2(x, 0)).x
			draw_line(Vector2(px, 0), Vector2(px, size.y), c, 1.0)
			draw_string(f, Vector2(px + 2, size.y - 24), str(snappedf(x, 0.0001)), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)
			x += step
		var y := floorf((lo.y - step) / step) * step
		while y <= hi.y + step:
			var py := _to_px(Vector2(0, y)).y
			draw_line(Vector2(0, py), Vector2(size.x, py), c, 1.0)
			draw_string(f, Vector2(4, py - 2), str(snappedf(y, 0.0001)), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)
			y += step


class YearCanvas:
	extends Control
	var result: Dictionary = {}
	const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.045, 0.07))
		var f := ThemeDB.fallback_font
		if result.is_empty():
			draw_string(f, Vector2(16, 30), "Run the year to see the heat month by month.", HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_MD, UITheme.C_TEXT_M)
			return
		var heat: PackedFloat64Array = result["monthly_kwh"]
		var dni: PackedFloat64Array = result["monthly_dni"]
		var ghi: PackedFloat64Array = result["monthly_ghi"]
		var top := 0.0
		var top2 := 0.0
		for i in 12:
			top = maxf(top, heat[i])
			top2 = maxf(top2, maxf(dni[i], ghi[i]))
		top = maxf(top, 1e-6) * 1.15
		top2 = maxf(top2, 1e-6) * 1.15
		var l := 56.0
		var r := size.x - 56.0
		var t := 40.0
		var b := size.y - 36.0
		var bw := (r - l) / 12.0
		draw_line(Vector2(l, b), Vector2(r, b), UITheme.C_BORDER, 1.0)
		var pd := PackedVector2Array()
		var pg := PackedVector2Array()
		for i in 12:
			var x0 := l + bw * i + bw * 0.18
			var h := (b - t) * heat[i] / top
			draw_rect(Rect2(Vector2(x0, b - h), Vector2(bw * 0.64, h)), Color(1.0, 0.55, 0.15, 0.9))
			draw_string(f, Vector2(x0, b - h - 4), _short(heat[i]), HORIZONTAL_ALIGNMENT_LEFT, bw * 0.9, UITheme.FONT_XS, UITheme.C_TEXT_S)
			draw_string(f, Vector2(l + bw * i + bw * 0.25, b + 16), str(MONTHS[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)
			var cx := l + bw * (i + 0.5)
			pd.append(Vector2(cx, b - (b - t) * dni[i] / top2))
			pg.append(Vector2(cx, b - (b - t) * ghi[i] / top2))
		draw_polyline(pg, Color(0.6, 0.65, 0.75), 2.0, true)
		draw_polyline(pd, Color(1.0, 0.9, 0.3), 2.5, true)
		for p in pd:
			draw_circle(p, 3.0, Color(1.0, 0.9, 0.3))
		draw_string(f, Vector2(l, 22), "■ heat (kWh)", HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, Color(1.0, 0.55, 0.15))
		draw_string(f, Vector2(l + 120, 22), "— direct beam DNI (kWh/m²)", HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, Color(1.0, 0.9, 0.3))
		draw_string(f, Vector2(l + 340, 22), "— global on the ground, what PV sees (kWh/m²)", HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, Color(0.6, 0.65, 0.75))
		draw_string(f, Vector2(r + 6, t + 10), _short(top2 / 1.15), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_M)

	func _short(v: float) -> String:
		if v >= 1000.0:
			return "%.1fk" % (v / 1000.0)
		return "%.0f" % v
