extends Control

## The FarmBot designer: a gantry garden robot on a raised bed of any size,
## the crops it grows (a mix, square or hex packing, rows / blocks / strips),
## what it does each day (watering, seeding, weeding, photos, soil readings,
## played move by move with FarmBotMotion's per-axis ramps), and what it costs
## against the hand work it saves. Opened from the library or a placed bed's
## "Edit FarmBot…"; Main hosts it (`open_farmbotlab`).

const MODAL_NAME := "farmbotlab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.25
const SPEEDS := [1.0, 10.0, 60.0, 300.0]

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _bound_prop_id := ""
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _entries: Array = []

# Playback
var _day := FarmBotEconomics.STEADY_FROM_DAY
var _plan: Dictionary = {}
var _job: Dictionary = {}
var _t := 0.0
var _playing := false
var _speed := 10.0

# UI
var _shell: DesignerShell
var _gallery: DesignGallery
var _tabs: TabBar
var _view_stack: Control
var _studio: StudioViewport
var _builder: FarmBotBuilder
var _plan_view: PlanView
var _day_spin: SpinBox
var _job_opt: OptionButton
var _play_btn: Button
var _speed_opt: OptionButton
var _scrub: HSlider
var _now_lbl: Label
var _kpi: Dictionary = {}
var _res: Dictionary = {}
var _checks_box: VBoxContainer
var _mix_box: VBoxContainer
var _settings: Dictionary = {}
var _bindings: Array = []
var _place_btn: Button
var _apply_btn: Button
var _status_lbl: Label


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
		spec = _prop_record(_bound_prop_id).get("farmbot_spec", {}) as Dictionary
	if spec.is_empty():
		spec = FarmBotPresets.spec("genesis_xl")
	_spec = FarmBotSpec.resolve(spec)
	_undo.clear()
	_redo.clear()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_shell.scroll_top()
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_refresh_design_list()
	_rebuild_now()
	_frame_camera()
	_show_view()


func close() -> void:
	if not _active:
		return
	_active = false
	_playing = false
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


func _process(delta: float) -> void:
	if _rebuild_timer > 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_now()
	if _playing and not _job.is_empty():
		_t += delta * _speed
		var dur := float(_job["dur_s"])
		if _t >= dur:
			_t = dur
			_playing = false
			_play_btn.text = "Play"
			UiIcons.apply(_play_btn, "play", "Play the job")
		_scrub.set_value_no_signal(_t / maxf(dur, 0.001))
		_pose()


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
	elif ke.keycode == KEY_SPACE:
		_on_play()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("FarmBot designer", "sprout", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Designs", "left_w": 240.0, "right_w": 420.0})
	add_child(_shell)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(_on_name_changed)
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_shell.set_hint("Drag to orbit · wheel to zoom · pick a day and a job, then Play (Space) to watch the robot do it · Ctrl+Z undoes")
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Place the bed and its robot with a food node on the graph; the robot works its days on the world's clock")
	_apply_btn = _shell.add_button("Apply to placed", DesignerShell.SECONDARY, _on_apply)
	_shell.add_button("Close", DesignerShell.SECONDARY, close)


func _build_left() -> void:
	var box := _shell.left
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_gallery = DesignGallery.make("farmbotlab")
	_gallery.set_thumbnailer(_thumb_for)
	_gallery.item_selected.connect(_on_design_activated)
	box.add_child(_gallery)
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
	var about := Label.new()
	about.text = "A FarmBot-style robot: a gantry on two tracks along a raised bed (FarmBot sells 3 x 1.5 m and 6 x 3 m kits; here any size), or a radial arm that turns about the middle of a keyhole bed."
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.custom_minimum_size = Vector2(120, 0)
	about.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	about.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(about)


func _build_centre() -> void:
	var col := _shell.centre
	_tabs = TabBar.new()
	_tabs.add_tab("3D")
	_tabs.add_tab("Plan")
	_tabs.tab_changed.connect(func(_i: int) -> void: _show_view())
	col.add_child(_tabs)
	_view_stack = Control.new()
	_view_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_stack.clip_contents = true
	col.add_child(_view_stack)
	_studio = StudioViewport.create({"ground": true, "person": true, "far": 400.0})
	_studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_studio.set_home(0.7, 0.42)
	_studio.dist_max = 200.0
	if _studio.ground != null:
		(_studio.ground.mesh as PlaneMesh).size = Vector2(200, 200)
	_view_stack.add_child(_studio)
	_plan_view = PlanView.new()
	_plan_view.modal = self
	_plan_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_plan_view.visible = false
	_view_stack.add_child(_plan_view)
	# The transport: day, job, play, speed, scrub, and what the robot is doing.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	col.add_child(bar)
	var dl := Label.new()
	dl.text = "Day"
	dl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	bar.add_child(dl)
	_day_spin = SpinBox.new()
	_day_spin.name = "day_spin"
	_day_spin.min_value = 0
	_day_spin.max_value = 730
	_day_spin.step = 1
	_day_spin.tooltip_text = "Days since the bed was planted: what is growing, and that day's jobs"
	_day_spin.value_changed.connect(func(v: float) -> void: _set_day(int(v)))
	bar.add_child(_day_spin)
	_job_opt = OptionButton.new()
	_job_opt.name = "job_opt"
	_job_opt.custom_minimum_size = Vector2(230, 0)
	_job_opt.fit_to_longest_item = false
	_job_opt.tooltip_text = "Which of the day's jobs to play"
	_job_opt.item_selected.connect(func(_i: int) -> void: _select_job())
	bar.add_child(_job_opt)
	_play_btn = Button.new()
	_play_btn.name = "play"
	_play_btn.text = "Play"
	UiIcons.apply(_play_btn, "play", "Play the job (Space)")
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play)
	bar.add_child(_play_btn)
	_speed_opt = OptionButton.new()
	_speed_opt.name = "speed"
	for s in SPEEDS:
		_speed_opt.add_item("%d×" % int(s))
	_speed_opt.select(1)
	_speed_opt.tooltip_text = "Playback speed (1× = the robot's real speed)"
	_speed_opt.item_selected.connect(func(i: int) -> void: _speed = float(SPEEDS[i]))
	bar.add_child(_speed_opt)
	_scrub = HSlider.new()
	_scrub.name = "scrub"
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.0005
	_scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scrub.value_changed.connect(func(v: float) -> void:
		if _job.is_empty():
			return
		_t = v * float(_job["dur_s"])
		_pose())
	bar.add_child(_scrub)
	_now_lbl = Label.new()
	_now_lbl.name = "now"
	_now_lbl.add_theme_font_override("font", UITheme.font("regular", true))
	_now_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_now_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_now_lbl.clip_text = true
	_now_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_now_lbl)


func _build_right() -> void:
	var box := _shell.right
	var tiles := GridContainer.new()
	tiles.columns = 2
	tiles.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	tiles.add_theme_constant_override("v_separation", UITheme.SPACE_SM)
	box.add_child(tiles)
	for kv in [["plants", "plants in the bed", "Plants at their spacing, all crops", UITheme.C_GREEN],
			["robot", "robot time a day", "How long the robot works on an average day, and its busiest", UITheme.C_PRIMARY],
			["saved", "hand work saved a year", "The hand work it does, less what it still needs a person for", UITheme.C_AMBER],
			["payback", "pays for itself in", "What it costs to buy and put up ÷ (the hours saved at your rate − running costs)", UITheme.C_GOLD]]:
		tiles.add_child(_kpi_tile(str(kv[0]), str(kv[1]), str(kv[2]), kv[3] as Color))
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_checks_box = VBoxContainer.new()
	_checks_box.add_theme_constant_override("separation", 4)
	box.add_child(_checks_box)
	var res := Collapsible.make("Labour and cost", false, "Hand work against the robot, a year at a time (the hand rates are estimates)")
	box.add_child(res)
	for r in [["hand", "Hand work it does", "The same seeding, watering, weeding and looking done by hand (estimates)"],
			["hand_split", "  of which", "Sowing · watering · weeding · looking, minutes a day"],
			["still", "Still by hand", "Refilling the seed trough, the weeds in the plants' crowns, upkeep"],
			["saved", "Saved", "Hours a year and their worth at your labour rate"],
			["running", "Running", "Electricity and spare parts a year"],
			["capital", "Kit + putting up", "The kit's price and the assembly hours at your rate"],
			["bed", "The bed", "The raised bed itself (needed with or without a robot; not in the payback)"],
			["payback", "Payback", "Years until the hours saved have paid for it"],
			["lifetime", "Over its life", "What it gains (or loses) over its lifetime"],
			["per_hour", "Cost per hour saved", "Its yearly cost ÷ the hours it saves"],
			["water", "Water a day", "What it gives the plants (the same by hand)"],
			["daily", "A day's work", "Seeds sown, weeds pulled, photos, soil readings (averaged)"],
			["busiest", "Busiest day", "The longest day of jobs in a month of steady days"],
			["power", "Power", "The electronics idling all day plus the motors while it works"]]:
		var row := FormRow.value(str(r[1]), "—", str(r[2]), "res_" + str(r[0]))
		res.body.add_child(row)
		_res[str(r[0])] = row
	var crops := Collapsible.make("Crops", true, "What grows in the bed and how it is laid out")
	box.add_child(crops)
	_mix_box = VBoxContainer.new()
	_mix_box.add_theme_constant_override("separation", 2)
	crops.body.add_child(_mix_box)
	var add := Button.new()
	add.name = "add_crop"
	add.text = "Add a crop"
	UiIcons.apply(add, "plus", "Add a crop to the mix")
	UITheme.style_button(add)
	add.pressed.connect(_on_add_crop)
	crops.body.add_child(add)
	_settings["crops"] = crops.body
	for gr in [["bed", "Bed", true], ["care", "Care schedule", false], ["tools", "Tools", false],
			["gantry", "Robot", false], ["motion", "Motion (firmware speeds)", false], ["cost", "Cost", false]]:
		var sec := Collapsible.make(str(gr[1]), bool(gr[2]))
		box.add_child(sec)
		_settings[str(gr[0])] = sec.body
	_build_rows()
	var copy := Button.new()
	copy.text = "Copy summary"
	copy.tooltip_text = "Every number and check, as text"
	UITheme.style_button(copy)
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(summary()); _status("Summary copied."))
	box.add_child(copy)
	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status_lbl)


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


## The settings rows: [group, key, label, kind, a, b, step, unit, tip].
const FIELDS := [
	["_", "kind", "Robot", "option", "kinds", "", 0.0, "", "Linear: FarmBot's gantry on two straight tracks along a raised bed. Radial: an arm pivoting on a post at the middle of a keyhole bed, riding a curved rail on its outer wall (for the greenhouse keyhole beds)."],
	["keyhole", "outer_r", "Outer radius", "spin", 2.0, 15.0, 0.1, " m", "The outer ring's outer edge. The greenhouse keyholes are 9.5 m (a 20 m dome)."],
	["keyhole", "ring_w", "Ring bed width", "spin", 0.4, 3.0, 0.05, " m", "Each ring bed's width (1.2 m: reached from the paths either side)"],
	["keyhole", "path_w", "Path width", "spin", 0.3, 2.0, 0.05, " m", "Between the rings"],
	["keyhole", "rings", "Rings", "spin", 1.0, 12.0, 1.0, "", "Ring beds from the outside in (fewer if they reach the centre)"],
	["keyhole", "slot_w", "Keyhole slot", "spin", 0.4, 3.0, 0.05, " m", "The path in from the door to the compost basket, cut through every ring"],
	["keyhole", "centre_r", "Centre", "spin", 0.5, 4.0, 0.05, " m", "The clear circle round the compost basket (the post and the tools are in it)"],
	["keyhole", "wall_h", "Wall height", "spin", 0.1, 1.0, 0.01, " m", "The ring beds' galvanised walls; the rail runs on the outer one"],
	["keyhole", "sweep", "Rail", "option", "sweeps", "", 0.0, "", "Stop at the slot: the rail ends either side of the path in and the arm turns back. Bridge it: a short removable section crosses the path and the arm goes all the way round."],
	["keyhole", "arms", "Arms", "spin", 1.0, 4.0, 1.0, "", "Arms on the same post and rail, each working its own sector of the bed at the same time (a big keyhole is more than one arm's day)"],
	["bed", "length_m", "Length", "spin", 1.0, 60.0, 0.1, " m", "Along the tracks (the gantry rolls this way). Genesis 3 m, XL 6 m."],
	["bed", "width_m", "Width", "spin", 0.6, 6.0, 0.1, " m", "Across the bed, under the gantry. Genesis 1.5 m, XL 3 m; past 3 m the beam sags."],
	["bed", "wall", "Walls", "option", "walls", "", 0.0, "", "What the raised bed is built of"],
	["bed", "wall_h_m", "Wall height", "spin", 0.1, 1.0, 0.01, " m", "The tracks run along the wall tops"],
	["crops", "packing", "Packing", "option", "packings", "", 0.0, "", "Hexagonal fits about 15 % more plants a square metre than a square grid at the same spacing"],
	["crops", "layout", "Layout", "option", "layouts", "", 0.0, "", "Rows: each crop a band across the bed. Blocks: each crop a lane along it. Strips: crops alternate (companion planting)."],
	["crops", "spacing_scale", "Spacing", "spin", 0.6, 2.5, 0.05, " ×", "× each crop's own spacing (intensive-bed spacings)"],
	["crops", "section_m", "Sowing section", "spin", 0.3, 6.0, 0.1, " m", "A crop is sown a section at a time, spread over its first cycle (succession)"],
	["care", "water_mm_day", "Water", "spin", 0.0, 15.0, 0.5, " mm/day", "Over the whole bed area (1 mm = 1 L a square metre)"],
	["care", "water_times", "Watering times", "text", "", "", 0.0, "", "Hours of the day, comma separated (7, 18)"],
	["care", "flow_l_min", "Nozzle flow", "spin", 0.2, 20.0, 0.1, " L/min", "How fast water leaves the watering nozzle (sets how long it dwells at each plant)"],
	["care", "weed_every_days", "Weed every", "spin", 0.0, 30.0, 1.0, " days", "0 = never. Each pass photographs the bed, then pulls what it found."],
	["care", "photo_every_days", "Photo survey every", "spin", 0.0, 30.0, 1.0, " days", "0 = never"],
	["care", "soil_every_days", "Soil readings every", "spin", 0.0, 30.0, 1.0, " days", "0 = never"],
	["care", "seed_hour", "Seeding at", "spin", 0.0, 23.5, 0.5, " h", "When the day's sowing starts"],
	["care", "weed_hour", "Weeding at", "spin", 0.0, 23.5, 0.5, " h", ""],
	["care", "photo_hour", "Photos at", "spin", 0.0, 23.5, 0.5, " h", "Soil readings follow the photos"],
	["tools", "seeder", "Seed injector", "check", "", "", 0.0, "", "Vacuum seeder: one seed at a time from the trough on the gantry"],
	["tools", "watering", "Watering nozzle", "check", "", "", 0.0, "", ""],
	["tools", "weeder", "Weeder", "check", "", "", 0.0, "", "Plunges weeds the camera finds"],
	["tools", "soil_sensor", "Soil sensor", "check", "", "", 0.0, "", "Moisture probe pushed into the soil"],
	["tools", "rotary", "Rotary tool", "check", "", "", 0.0, "", "Carried in the bay; no job uses it yet"],
	["gantry", "clearance_m", "Clearance", "spin", 0.3, 2.5, 0.05, " m", "The gantry beam's height over the soil: crops taller than this stop it"],
	["gantry", "z_travel_mm", "Z travel", "spin", 150.0, 1500.0, 10.0, " mm", "How far the tool mount moves up and down"],
	["gantry", "soil_z_mm", "Soil at Z", "spin", -1500.0, -50.0, 5.0, " mm", "The machine's Z where a tool tip touches the soil"],
	["motion", "xy_max_mm_s", "X/Y top speed", "spin", 5.0, 300.0, 1.0, " mm/s", "FarmBot default 80 mm/s (400 steps/s at 5 steps/mm)"],
	["motion", "xy_min_mm_s", "X/Y start speed", "spin", 1.0, 100.0, 1.0, " mm/s", "Default 10 mm/s"],
	["motion", "xy_ramp_mm", "X/Y ramp", "spin", 1.0, 500.0, 1.0, " mm", "Distance to reach top speed (default 60 mm)"],
	["motion", "z_max_mm_s", "Z top speed", "spin", 1.0, 100.0, 1.0, " mm/s", "Default 16 mm/s (25 steps/mm)"],
	["motion", "z_min_mm_s", "Z start speed", "spin", 0.5, 50.0, 0.5, " mm/s", ""],
	["motion", "z_ramp_mm", "Z ramp", "spin", 1.0, 200.0, 1.0, " mm", ""],
	["cost", "kit_usd", "Kit price", "spin", -1.0, 50000.0, 25.0, " $", "-1 = from its size: $3,500 for a Genesis, $4,500 for an XL (FarmBot's docs), more per metre"],
	["cost", "bed_usd_m2", "Bed", "spin", 0.0, 500.0, 5.0, " $/m²", "Building the raised bed"],
	["cost", "labor_usd_h", "Labour", "spin", 0.0, 200.0, 1.0, " $/h", "What an hour of garden work is worth to you"],
	["cost", "electricity_usd_kwh", "Electricity", "spin", 0.0, 2.0, 0.01, " $/kWh", ""],
	["cost", "lifetime_years", "Lifetime", "spin", 1.0, 30.0, 1.0, " years", ""],
	["cost", "parts_usd_year", "Spare parts", "spin", 0.0, 2000.0, 10.0, " $/year", "Belts, seals, wheels (estimate)"],
	["cost", "upkeep_h_year", "Upkeep", "spin", 0.0, 200.0, 1.0, " h/year", "Cleaning, updates, fixing jams (estimate)"],
	["cost", "assembly_h", "Assembly", "spin", 0.0, 100.0, 0.5, " h", "For a 6 m track; scaled by length. FarmBot says about 3 h for the v1.9 XL."],
]


func _build_rows() -> void:
	_bindings.clear()
	for fv in FIELDS:
		var f: Array = fv
		var g := str(f[0])
		var k := str(f[1])
		var body: VBoxContainer = _settings["bed" if g == "_" or g == "keyhole" else g]
		var row: FormRow = null
		var id := "%s_%s" % [g, k]
		match str(f[3]):
			"spin":
				row = FormRow.spin(str(f[2]), float(f[4]), float(f[5]), float(f[6]), str(f[7]), _on_field.bind(g, k), str(f[8]), id)
			"option":
				row = FormRow.option(str(f[2]), _items(str(f[4])), _on_field.bind(g, k), str(f[8]), id)
			"check":
				row = FormRow.check(str(f[2]), "", _on_field.bind(g, k), str(f[8]), id)
			"text":
				row = FormRow.text_edit(str(f[2]), "7, 18", Callable(), str(f[8]), id)
				(row.control as LineEdit).text_submitted.connect(func(t: String) -> void: _on_times(t))
				(row.control as LineEdit).focus_exited.connect(func() -> void: _on_times((row.control as LineEdit).text))
		if row == null:
			continue
		body.add_child(row)
		_bindings.append({"g": g, "k": k, "row": row})


## Rows shown for one robot type only.
const KIND_ONLY := {"bed.length_m": "linear", "bed.width_m": "linear", "bed.wall": "linear", "bed.wall_h_m": "linear",
	"keyhole.outer_r": "radial", "keyhole.ring_w": "radial", "keyhole.path_w": "radial", "keyhole.rings": "radial",
	"keyhole.slot_w": "radial", "keyhole.centre_r": "radial", "keyhole.wall_h": "radial", "keyhole.sweep": "radial",
	"keyhole.arms": "radial"}


static func _items(table: String) -> Array:
	match table:
		"kinds":
			return [["linear", "Linear gantry (raised bed)"], ["radial", "Radial arm (keyhole bed)"]]
		"sweeps":
			return [["slot", "Stops at the slot"], ["full", "Bridges the slot"]]
		"walls":
			return [["concrete", "Concrete blocks"], ["galvanized", "Corrugated galvanized steel"], ["timber", "Timber"]]
		"packings":
			return [["hex", "Hexagonal"], ["square", "Square grid"]]
		"layouts":
			return [["rows", "Rows across (rings round a keyhole)"], ["blocks", "Blocks along (wedges of a keyhole)"],
				["interleave", "Alternating strips / sectors"]]
	return []


static func crop_items() -> Array:
	var out: Array = []
	for id in GardenCrops.CROPS.keys():
		var info: Dictionary = GardenCrops.CROPS[id]
		out.append([str(id), "%s (%.0f cm)" % [str(info["label"]), float(info["spacing"]) * 100.0]])
	return out


func _rebuild_mix_rows() -> void:
	for c in _mix_box.get_children():
		_mix_box.remove_child(c)
		c.queue_free()
	var mix: Array = (_spec["crops"] as Dictionary)["mix"]
	var tot := 0.0
	for e in mix:
		tot += float((e as Dictionary)["share"])
	for i in mix.size():
		var e2: Dictionary = mix[i]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(10, 18)
		sw.color = PlanView.crop_color(str(e2["crop"]))
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(sw)
		var o := OptionButton.new()
		o.name = "mix_crop_%d" % i
		var items := crop_items()
		for j in items.size():
			o.add_item(str(items[j][1]), j)
			o.set_item_metadata(j, items[j][0])
		FormRow.select_meta(o, str(e2["crop"]))
		o.fit_to_longest_item = false
		o.clip_text = true
		o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		o.item_selected.connect(func(j: int) -> void: _set_mix(i, "crop", o.get_item_metadata(j)))
		h.add_child(o)
		var sp := SpinBox.new()
		sp.name = "mix_share_%d" % i
		sp.min_value = 0
		sp.max_value = 100
		sp.step = 1
		sp.suffix = "%"
		sp.custom_minimum_size = Vector2(80, 0)
		sp.set_value_no_signal(roundf(float(e2["share"]) / maxf(tot, 0.0001) * 100.0))
		sp.tooltip_text = "Its share of the bed"
		sp.value_changed.connect(func(v: float) -> void: _set_mix(i, "share", v / 100.0))
		h.add_child(sp)
		var n := Label.new()
		n.text = str(int(((_design.get("layout", {}) as Dictionary).get("counts", {}) as Dictionary).get(str(e2["crop"]), 0)))
		n.custom_minimum_size = Vector2(34, 0)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		n.tooltip_text = "Plants of it in the bed"
		n.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		h.add_child(n)
		var rm := IconButton.make("x", "Remove this crop", func() -> void: _remove_crop(i))
		rm.disabled = mix.size() <= 1
		h.add_child(rm)
		_mix_box.add_child(h)


# ---------------------------------------------------------------------------
# Edits, undo
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


func _on_field(value: Variant, g: String, k: String) -> void:
	_push_undo("%s.%s" % [g, k])
	if g == "_":
		_spec[k] = value
		if k == "kind":
			# A new robot type re-lays everything: no debounce, and frame it.
			_rebuild_now()
			_frame_camera()
			return
	else:
		var cur: Variant = (_spec[g] as Dictionary).get(k)
		if cur is int and (value is float or value is int):
			value = int(value)
		(_spec[g] as Dictionary)[k] = value
	_rebuild_timer = REBUILD_DELAY


func _on_times(text: String) -> void:
	var times: Array = []
	for part in text.replace(";", ",").split(",", false):
		var p := part.strip_edges()
		if p.is_valid_float():
			times.append(clampf(p.to_float(), 0.0, 23.9))
	times.sort()
	if JSON.stringify(times) == JSON.stringify((_spec["care"] as Dictionary)["water_times"]):
		return
	_push_undo("care.water_times")
	(_spec["care"] as Dictionary)["water_times"] = times
	_rebuild_timer = REBUILD_DELAY


func _set_mix(i: int, key: String, value: Variant) -> void:
	var mix: Array = (_spec["crops"] as Dictionary)["mix"]
	if i < 0 or i >= mix.size():
		return
	_push_undo("mix.%d.%s" % [i, key])
	if key == "share":
		# Shares are kept as fractions of the whole; renormalise the others.
		var tot := 0.0
		for e in mix:
			tot += float((e as Dictionary)["share"])
		for e2 in mix:
			(e2 as Dictionary)["share"] = float((e2 as Dictionary)["share"]) / maxf(tot, 0.0001)
		(mix[i] as Dictionary)["share"] = clampf(float(value), 0.0, 1.0)
	else:
		(mix[i] as Dictionary)[key] = value
	_rebuild_timer = REBUILD_DELAY


func _on_add_crop() -> void:
	var mix: Array = (_spec["crops"] as Dictionary)["mix"]
	_push_undo()
	var used: Array = []
	for e in mix:
		used.append(str((e as Dictionary)["crop"]))
	var pick := "kale"
	for id in GardenCrops.CROPS.keys():
		if not used.has(str(id)) and float(GardenCrops.info(str(id))["height"]) < 0.8:
			pick = str(id)
			break
	mix.append({"crop": pick, "share": 1.0 / float(mix.size() + 1)})
	_rebuild_now()


func _remove_crop(i: int) -> void:
	var mix: Array = (_spec["crops"] as Dictionary)["mix"]
	if mix.size() <= 1 or i < 0 or i >= mix.size():
		return
	_push_undo()
	mix.remove_at(i)
	_rebuild_now()


## Replace the whole spec (a preset or a library design).
func set_spec(spec: Dictionary) -> void:
	_push_undo()
	_spec = FarmBotSpec.resolve(spec)
	_rebuild_now()
	_frame_camera()


## One field, by group and key (the harness and the summary use it).
func edit(g: String, k: String, value: Variant) -> void:
	_on_field(value, g, k)
	_rebuild_now()


func _on_name_changed(text: String) -> void:
	if text.strip_edges().is_empty() or text == str(_spec["name"]):
		return
	_push_undo("name")
	_spec["name"] = text.strip_edges()


# ---------------------------------------------------------------------------
# Solve and refresh
# ---------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = FarmBotSpec.resolve(_spec)
	_design = FarmBotDesign.solve(_spec)
	if _builder != null:
		_builder.queue_free()
	_builder = FarmBotBuilder.build_node(_spec, "FarmBot")
	_studio.holder.add_child(_builder)
	_sync_rows()
	_rebuild_mix_rows()
	_refresh_results()
	_refresh_checks()
	_load_day(true)
	_plan_view.queue_redraw()


func _sync_rows() -> void:
	var kind := str(_spec.get("kind", "linear"))
	for bv in _bindings:
		var b: Dictionary = bv
		var key := "%s.%s" % [str(b["g"]), str(b["k"])]
		(b["row"] as FormRow).visible = not KIND_ONLY.has(key) or str(KIND_ONLY[key]) == kind
		var v: Variant = _spec.get(str(b["k"])) if str(b["g"]) == "_" else (_spec[str(b["g"])] as Dictionary).get(str(b["k"]))
		if str(b["k"]) == "water_times":
			var parts: Array = []
			for h in (v as Array):
				parts.append(_fmt_h(float(h)))
			v = ", ".join(parts)
		(b["row"] as FormRow).set_value(v)
	_shell.name_edit.text = str(_spec["name"])
	_day_spin.set_value_no_signal(_day)


static func _fmt_h(h: float) -> String:
	return str(int(h)) if is_equal_approx(h, roundf(h)) else "%.1f" % h


func _refresh_results() -> void:
	var lay: Dictionary = _design["layout"]
	var rb: Dictionary = _design["robot"]
	var m: Dictionary = _design["money"]
	var hand: Dictionary = m["hand"]
	(_kpi["plants"] as Label).text = UiText.thousands(int(lay["total"]))
	(_kpi["robot"] as Label).text = UiText.duration(float(rb["busy_h_day"]))
	(_kpi["saved"] as Label).text = "%d h" % int(roundf(float(m["saved_h_year"])))
	var pb := float(m["payback_years"])
	(_kpi["payback"] as Label).text = "never" if is_inf(pb) else "%.1f years" % pb
	_set_res("hand", "%.0f min a day · %d h a year" % [float(hand["min_day"]), int(roundf(float(hand["h_year"])))])
	_set_res("hand_split", "%.0f · %.0f · %.0f · %.0f min" % [float(hand["sow_min"]), float(hand["water_min"]),
		float(hand["weed_min"]), float(hand["look_min"])])
	_set_res("still", "%d h a year" % int(roundf(float(m["still_h_year"]))))
	_set_res("saved", "%d h · %s a year" % [int(roundf(float(m["saved_h_year"]))), _usd(float(m["saved_usd_year"]))])
	_set_res("running", "%s a year (%.0f kWh)" % [_usd(float(m["running_usd_year"])), float(m["kwh_year"])])
	_set_res("capital", "%s + %.1f h = %s" % [_usd(float(m["kit_usd"])), float(m["assembly_h"]), _usd(float(m["capital_usd"]))])
	_set_res("bed", "%s (%.1f m²)" % [_usd(float(m["bed_usd"])), float(_design["area_m2"])])
	_set_res("payback", "never" if is_inf(pb) else "%.1f years" % pb)
	_set_res("lifetime", "%s%s" % ["+" if float(m["lifetime_net_usd"]) >= 0.0 else "−", _usd(absf(float(m["lifetime_net_usd"])))])
	var ph := float(m["usd_per_saved_h"])
	_set_res("per_hour", "—" if is_inf(ph) else "%s per hour" % _usd(ph))
	_set_res("water", "%.0f L" % float(rb["water_l_day"]))
	_set_res("daily", "%.1f seeds · %.1f weeds · %.0f photos · %.0f readings" % [float(rb["seeds_day"]),
		float(rb["weeds_day"]), float(rb["photos_day"]), float(rb["soil_day"])])
	_set_res("busiest", "%s (day %d)" % [UiText.duration(float(rb["max_busy_h"])), int(rb["worst_day"])])
	_set_res("power", "%.0f W idle, %.0f W working" % [FarmBotEconomics.IDLE_W, FarmBotEconomics.IDLE_W + FarmBotEconomics.WORK_W])
	_shell.set_subtitle("%s · %s plants · %s" % [size_line(_spec), UiText.thousands(int(lay["total"])),
		_usd(FarmBotSpec.kit_price_usd(_spec))])


func _set_res(key: String, text: String) -> void:
	if _res.has(key):
		(_res[key] as FormRow).set_value(text)


static func _usd(v: float) -> String:
	return "$" + UiText.thousands(int(roundf(v)))


func _refresh_checks() -> void:
	for c in _checks_box.get_children():
		_checks_box.remove_child(c)
		c.queue_free()
	var checks: Array = _design["checks"]
	var errs := 0
	var warns := 0
	for cv in checks:
		var c: Dictionary = cv
		var lvl := str(c["level"])
		if lvl == "error":
			errs += 1
		elif lvl == "warn":
			warns += 1
		var l := Label.new()
		l.text = ("✗ " if lvl == "error" else "⚠ " if lvl == "warn" else "· ") + str(c["text"])
		l.tooltip_text = str(c.get("why", ""))
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(200, 0)
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_ERROR if lvl == "error" else UITheme.C_WARN if lvl == "warn" else UITheme.C_TEXT_S)
		_checks_box.add_child(l)
	if checks.is_empty():
		var ok := Label.new()
		ok.text = "✓ Nothing to fix."
		ok.add_theme_color_override("font_color", UITheme.C_OK)
		_checks_box.add_child(ok)
	if errs > 0:
		_shell.set_badge(UiText.count(errs, "problem") + " to fix", "error")
	elif warns > 0:
		_shell.set_badge(UiText.count(warns, "warning"), "warn")
	else:
		_shell.set_badge("Checks pass", "ok")


# ---------------------------------------------------------------------------
# The day and its jobs
# ---------------------------------------------------------------------------

func _set_day(d: int) -> void:
	_day = d
	_load_day(false)


func _load_day(keep_job: bool) -> void:
	var prev_id := str(_job.get("id", "")) if keep_job else ""
	_plan = FarmBotJobs.day_plan(_spec, _design["layout"], _day, true)
	_builder.set_days(float(_day) + 0.5)
	_job_opt.clear()
	var jobs: Array = _plan["windows"]
	var sel := 0
	for i in jobs.size():
		var j: Dictionary = jobs[i]
		var hh := float(j["start_s"]) / 3600.0
		_job_opt.add_item("%02d:%02d %s · %s" % [int(hh), int(fposmod(hh, 1.0) * 60.0), str(j["label"]),
			UiText.duration(float(j["dur_s"]) / 3600.0)], i)
		if str(j["id"]) == prev_id:
			sel = i
	if jobs.size() > 1:
		_job_opt.add_item("The whole day · %s of work" % UiText.duration(float(_plan["busy_s"]) / 3600.0), jobs.size())
	if jobs.is_empty():
		_job_opt.add_item("Nothing to do this day", 0)
		_job_opt.disabled = true
	else:
		_job_opt.disabled = false
	_job_opt.select(sel)
	_select_job()


func _select_job() -> void:
	var jobs: Array = _plan.get("windows", []) as Array
	var i := _job_opt.get_selected_id()
	if jobs.is_empty():
		_job = {}
	elif i >= jobs.size():
		_job = whole_day_job(_plan)
	else:
		_job = jobs[i]
	_t = 0.0
	_scrub.set_value_no_signal(0.0)
	_pose()
	_plan_view.queue_redraw()


## The day from its first job's start to its last job's end.
static func whole_day_job(plan: Dictionary) -> Dictionary:
	var ws: Array = plan["windows"]
	var t0 := INF
	var t1 := 0.0
	for wv in ws:
		t0 = minf(t0, float(wv["start_s"]))
		t1 = maxf(t1, float(wv["start_s"]) + float(wv["dur_s"]))
	return {"id": "day", "label": "The whole day", "start_s": t0, "dur_s": t1 - t0}


## Arm i's own job inside the window being played (its segments).
func arm_job(i: int) -> Dictionary:
	var arms: Array = _plan.get("arms", []) as Array
	if i < 0 or i >= arms.size() or _job.is_empty():
		return {}
	for jv in ((arms[i] as Dictionary)["jobs"] as Array):
		if str(jv["id"]) == str(_job["id"]):
			return jv
	return {}


func _on_play() -> void:
	if _job.is_empty():
		return
	_playing = not _playing
	if _playing and _t >= float(_job["dur_s"]) - 0.01:
		_t = 0.0
	_play_btn.text = "Pause" if _playing else "Play"
	UiIcons.apply(_play_btn, "pause" if _playing else "play", "Pause" if _playing else "Play the job (Space)")


func _pose() -> void:
	if _builder == null:
		return
	if _job.is_empty():
		for i in _builder.arms.size():
			_builder.set_arm(i, FarmBotJobs.park_pos(_spec, i), "", false)
		_now_lbl.text = "Parked over the tool bay."
		return
	var ts := float(_job["start_s"]) + _t
	var all := FarmBotJobs.sample_arms(_plan, ts)
	_builder.set_arms(all)
	var r: Dictionary = all[0]
	var p: Vector3 = r["pos"]
	var hh := ts / 3600.0
	var busy := 0
	for o in all:
		if bool((o as Dictionary).get("busy", false)):
			busy += 1
	var axes := "X %.0f  Y %.0f  Z %.0f mm" % [p.x, p.y, p.z]
	if FarmBotGeom.is_radial(_spec):
		axes = "arm %.1f°  out %.2f m  Z %.0f mm" % [rad_to_deg(FarmBotGeom.arm_angle(_spec, p.x)), p.y / 1000.0, p.z]
	var arms_txt := "" if all.size() <= 1 else " · %d of %d arms working" % [busy, all.size()]
	_now_lbl.text = I18n.f("{label} · {hh}:{hh_2}:{ts} · {act} · {tool} · {axes} · {t} of {dur_s}{arms}", {
		"label": str(_job["label"]),
		"hh": "%02d" % int(hh),
		"hh_2": "%02d" % (int(fposmod(hh, 1.0) * 60.0)),
		"ts": "%02d" % (int(fposmod(ts, 60.0))),
		"act": _act_word(str(r["act"])),
		"tool": str(FarmBotSpec.TOOL_LABELS.get(str(r["tool"]), "no tool")),
		"axes": axes,
		"t": UiText.duration(_t / 3600.0),
		"dur_s": UiText.duration(float(_job["dur_s"]) / 3600.0),
		"arms": arms_txt,
	})
	_plan_view.queue_redraw()


static func _act_word(a: String) -> String:
	match a:
		"travel":
			return "moving"
		"water":
			return "watering"
		"pick":
			return "picking a seed"
		"seed":
			return "sowing"
		"photo":
			return "taking a photo"
		"weed":
			return "weeding"
		"sense":
			return "reading the soil"
		"mount":
			return "changing tools"
	return a


func _show_view() -> void:
	var i := _tabs.current_tab
	_studio.visible = i == 0
	_studio.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if (i == 0 and _active) else SubViewport.UPDATE_DISABLED
	_plan_view.visible = i == 1
	_plan_view.queue_redraw()


func _frame_camera() -> void:
	var b: Dictionary = _spec["bed"]
	var L := float(b["length_m"])
	var W := float(b["width_m"])
	var h := float(b["wall_h_m"]) + float((_spec["gantry"] as Dictionary)["clearance_m"])
	_studio.frame_aabb(AABB(Vector3(-L * 0.5, 0.0, -W * 0.5), Vector3(L, h + 0.3, W)), 0.42, 1.25)
	_studio.place_person(maxf(L, W) * 0.5 + 0.8)


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------

func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _entries.size():
		return {}
	var spec: Dictionary = FarmBotSpec.resolve(((_entries[i] as Dictionary)["spec"] as Dictionary).duplicate(true))
	return {"key": FarmBotSpec.key_of(spec), "build": func() -> Node3D:
		var n := FarmBotBuilder.build_node(spec, "Thumb")
		n.set_days(float(FarmBotEconomics.STEADY_FROM_DAY))
		return n}


func _refresh_design_list() -> void:
	_gallery.clear()
	_entries.clear()
	var b := FarmBotPresets.builtins()
	for id in FarmBotPresets.ORDER:
		var s: Dictionary = b[id]
		_gallery.add_item(str(s["name"]))
		_gallery.set_item_subtitle(_gallery.item_count - 1, size_line(s))
		_entries.append({"spec": s, "builtin": true, "id": str(id)})
	var lib := FarmBotPresets.load_library()
	for id2 in lib.keys():
		var s2: Dictionary = lib[id2]
		_gallery.add_item("★ " + str(s2.get("name", id2)))
		_entries.append({"spec": s2, "builtin": false, "id": str(id2)})


## "6.0 × 3.0 m", or a keyhole's diameter and arms.
static func size_line(spec: Dictionary) -> String:
	var s := FarmBotSpec.resolve(spec)
	if FarmBotGeom.is_radial(s):
		var n := FarmBotGeom.arm_count(s)
		return "keyhole Ø%.0f m · %s" % [2.0 * float(FarmBotGeom.keyhole(s)["outer_r"]), UiText.count(n, "arm")]
	return "%.1f × %.1f m" % [float(s["bed"]["length_m"]), float(s["bed"]["width_m"])]


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		return
	set_spec(((_entries[idx] as Dictionary)["spec"] as Dictionary).duplicate(true))


func _on_save_design() -> void:
	var nm := str(_spec["name"])
	var id := "fb_" + nm.to_lower().replace(" ", "_").left(40)
	if FarmBotPresets.save_to_library(id, _spec):
		_refresh_design_list()
		_status("Saved “%s” to your library." % nm)
	else:
		_status("Could not write the library file.")


func _on_forget_design() -> void:
	var sel := _gallery.get_selected_items()
	if sel.is_empty():
		_status("Pick a saved design (★) to forget.")
		return
	var e: Dictionary = _entries[sel[0]]
	if bool(e["builtin"]):
		_status("Built-in designs can't be forgotten.")
		return
	FarmBotPresets.forget(str(e["id"]))
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
	if gv != null and gv.has_method("place_designed_farmbot"):
		if bool(gv.call("place_designed_farmbot", FarmBotSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a world with the systems graph.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	if main == null:
		return
	PlacedPropService.update_prop_record(main, _bound_prop_id, {"farmbot_spec": FarmBotSpec.to_json_safe(_spec)}, true)
	var gv := _graph()
	var rec := _prop_record(_bound_prop_id)
	var gid := str(rec.get("graph_item_id", ""))
	if gv != null and not gid.is_empty() and gv.has_method("apply_farmbot_design"):
		gv.call("apply_farmbot_design", gid, FarmBotSpec.to_json_safe(_spec))
	_status("Applied to the placed bed.")
	close()


func _prop_record(prop_id: String) -> Dictionary:
	var main := _main_node()
	if main == null:
		return {}
	var rec0 := PlacedPropService.get_prop_record(main, prop_id)
	if not rec0.is_empty():
		return rec0.duplicate(true)
	return {}


func _status(text: String) -> void:
	_status_lbl.text = text


## Every number and check, as text.
func summary() -> String:
	var lines: Array = []
	var b: Dictionary = _spec["bed"]
	lines.append("%s — %.1f x %.1f m bed (%s), %d plants" % [str(_spec["name"]), float(b["length_m"]), float(b["width_m"]),
		str(b["wall"]), int(_design["layout"]["total"])])
	lines.append("Crops: " + JSON.stringify(_design["layout"]["counts"]))
	for k in ["hand", "hand_split", "still", "saved", "running", "capital", "bed", "payback", "lifetime", "per_hour", "water", "daily", "busiest", "power"]:
		var r: FormRow = _res[k]
		lines.append("%s: %s" % [r.label.text.strip_edges(), (r.control as Label).text])
	for cv in (_design["checks"] as Array):
		lines.append("[%s] %s" % [str(cv["level"]), str(cv["text"])])
	lines.append("Hand-work rates and power are estimates (FarmBotEconomics); motion is FarmBot OS's default speeds.")
	return "\n".join(lines)


# Harness access
func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func builder() -> FarmBotBuilder:
	return _builder


func studio() -> StudioViewport:
	return _studio


func plan() -> Dictionary:
	return _plan


func job() -> Dictionary:
	return _job


func play_time() -> float:
	return _t


func set_play_time(t: float) -> void:
	_t = t
	_pose()


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


# ---------------------------------------------------------------------------
# The plan view: the bed from above, every plant, the robot and its path.
# ---------------------------------------------------------------------------

class PlanView:
	extends Control
	var modal: Node = null

	const PALETTE := [Color(0.55, 0.85, 0.35), Color(0.95, 0.55, 0.2), Color(0.85, 0.3, 0.45), Color(0.95, 0.85, 0.3),
		Color(0.35, 0.75, 0.9), Color(0.6, 0.45, 0.85), Color(0.3, 0.6, 0.35), Color(0.9, 0.4, 0.3),
		Color(0.75, 0.9, 0.6), Color(0.45, 0.55, 0.95), Color(0.95, 0.7, 0.75), Color(0.6, 0.8, 0.8)]

	## One colour per crop, the same everywhere (the order of GardenCrops).
	static func crop_color(id: String) -> Color:
		var i := GardenCrops.CROPS.keys().find(id)
		return PALETTE[maxi(i, 0) % PALETTE.size()]

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if modal == null:
			return
		var d: Dictionary = modal.call("design")
		if d.is_empty():
			return
		var s: Dictionary = d["spec"]
		var L := float(s["bed"]["length_m"])
		var W := float(s["bed"]["width_m"])
		var pad := 30.0
		var k := minf((size.x - 2.0 * pad) / L, (size.y - 2.0 * pad - 20.0) / W)
		var o := Vector2((size.x - L * k) * 0.5, (size.y - W * k) * 0.5)
		var bed := Rect2(o, Vector2(L * k, W * k))
		draw_rect(bed.grow(4.0), Color(0.5, 0.5, 0.48))
		draw_rect(bed, Color(0.27, 0.19, 0.12))
		var lay: Dictionary = d["layout"]
		var radial := FarmBotGeom.is_radial(s)
		var f := func(x: float, z: float) -> Vector2: return o + Vector2((x + L * 0.5) * k, (z + W * 0.5) * k)
		if radial:
			# A keyhole: the path floor, then each ring sector.
			draw_rect(bed, Color(0.36, 0.3, 0.22))
		for sv in (lay["sections"] as Array):
			var sec: Dictionary = sv
			var c := crop_color(str(sec["crop"]))
			if str(sec.get("shape", "rect")) == "sector":
				draw_colored_polygon(_sector_poly(f, float(sec["r0"]), float(sec["r1"]), float(sec["a0"]),
					float(sec["a1"])), Color(0.27, 0.19, 0.12).lerp(c, 0.18))
			else:
				var rc: Rect2 = sec["rect"]
				draw_rect(Rect2(f.call(rc.position.x, rc.position.y), rc.size * k), Color(c, 0.12))
		for pv in (lay["plants"] as Array):
			var p: Dictionary = pv
			var r := maxf(GardenCrops.spacing(str(p["crop"])) * float(s["crops"]["spacing_scale"]) * 0.38 * k, 1.5)
			draw_circle(f.call(float(p["x"]), float(p["z"])), r, crop_color(str(p["crop"])))
		if not radial:
			var bay := FarmBotLayout.toolbay_rect(s)
			draw_rect(Rect2(f.call(bay.position.x, bay.position.y), bay.size * k), Color(0.1, 0.1, 0.1, 0.8))
		else:
			# The rail and the tool ring.
			var sw := FarmBotGeom.sweep(s)
			var rr := FarmBotGeom.rail_r(s)
			var rail := PackedVector2Array()
			for j in 97:
				var a := sw.x + sw.y * float(j) / 96.0
				rail.append(f.call(sin(a) * rr, cos(a) * rr))
			draw_polyline(rail, Color(0.8, 0.8, 0.82), 2.0)
			draw_arc(f.call(0.0, 0.0), FarmBotGeom.tool_r(s) * k, 0.0, TAU, 40, Color(0.1, 0.1, 0.1), 2.0)
		# Each arm's path in this job: everything it visits, the part done
		# brighter.
		var job: Dictionary = modal.call("job")
		var t := float(modal.call("play_time"))
		if not job.is_empty():
			var t_abs := float(job["start_s"]) + t
			var n_arms := ((modal.call("plan") as Dictionary).get("arms", []) as Array).size()
			for ai in n_arms:
				var aj: Dictionary = modal.call("arm_job", ai)
				if aj.is_empty():
					continue
				var segs: Array = aj["segs"]
				var step := maxi(segs.size() / 3000, 1)
				var i := 0
				while i < segs.size():
					var sg: Dictionary = segs[i]
					if str(sg["k"]) == "move":
						var a3: Vector3 = sg["a"]
						var b3: Vector3 = sg["b"]
						var pa := FarmBotGeom.to_bed(s, a3.x, a3.y)
						var pb := FarmBotGeom.to_bed(s, b3.x, b3.y)
						var done := float(aj["start_s"]) + float(sg["t0"]) <= t_abs
						draw_line(f.call(pa.x, pa.y), f.call(pb.x, pb.y),
							Color(1.0, 0.85, 0.3, 0.75) if done else Color(1.0, 1.0, 1.0, 0.18), 1.0)
					i += step
		# The gantry (or arms) and the tool mount.
		var bld: Node = modal.call("builder")
		if bld != null:
			for e in (bld as FarmBotBuilder).arms:
				var mp: Vector3 = (e as Dictionary)["pos"]
				var tip := FarmBotGeom.to_bed(s, mp.x, mp.y)
				if radial:
					var ang := FarmBotGeom.arm_angle(s, mp.x)
					var rr2 := FarmBotGeom.rail_r(s)
					draw_line(f.call(0.0, 0.0), f.call(sin(ang) * rr2, cos(ang) * rr2), Color(0.05, 0.05, 0.05), 5.0)
				else:
					var gx := o.x + mp.x / 1000.0 * k
					draw_line(Vector2(gx, o.y - 10.0), Vector2(gx, o.y + W * k + 10.0), Color(0.05, 0.05, 0.05), 5.0)
				draw_circle(f.call(tip.x, tip.y), 6.0, Color.WHITE)
				draw_arc(f.call(tip.x, tip.y), 6.0, 0.0, TAU, 20, Color(0.1, 0.1, 0.1), 1.5)
		var font := get_theme_default_font()
		var note := "tool bay bottom left" if not radial else "tools round the post, the rail on the outer wall"
		draw_string(font, Vector2(o.x, o.y + W * k + 22.0), "%.1f m × %.1f m · %s · the yellow path is done, the white still to come" % [L, W, note],
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_S)

	static func _sector_poly(f: Callable, r0: float, r1: float, a0: float, a1: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		var n := maxi(int((a1 - a0) / 0.05), 2)
		for j in n + 1:
			var a := lerpf(a0, a1, float(j) / float(n))
			pts.append(f.call(sin(a) * r1, cos(a) * r1))
		for j2 in n + 1:
			var a2 := lerpf(a1, a0, float(j2) / float(n))
			pts.append(f.call(sin(a2) * r0, cos(a2) * r0))
		return pts
