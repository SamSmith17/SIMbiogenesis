extends Control
## Inspector panel for the right sidebar.
## Call inspect_item / inspect_connection when a canvas selection changes.
## All edits are routed through GraphModel so other views stay in sync.

# ---------------------------------------------------------------------------
# Palette - redirected to UITheme (single source of truth); local const
# names kept so existing call sites are unchanged.
# ---------------------------------------------------------------------------
const C_BG      := UITheme.C_BG
const C_PANEL   := UITheme.C_PANEL_RAISED
const C_BORDER  := UITheme.C_BORDER
const C_PRIMARY := UITheme.C_PRIMARY
const C_TEXT    := UITheme.C_TEXT
const C_TEXT_S  := UITheme.C_TEXT_S
const C_TEXT_M  := UITheme.C_TEXT_M
const C_AMBER   := UITheme.C_AMBER

const _HA_PUSHER         := preload("res://system_graph/ha_automation_pusher.gd")
const _CALIBRATOR_SCRIPT := preload("res://system_graph/load_calibrator.gd")
const _CAL_GRAPH_SCRIPT  := preload("res://system_graph/calibration_graph.gd")
const _EDU_CARDS_SCRIPT  := preload("res://system_graph/graph_education_cards.gd")
const _GRAPH_CANVAS_SCRIPT := preload("res://system_graph/graph_canvas.gd")

const _TOUCH_SCROLL_HANDLER := preload("res://system_graph/touch_scroll_handler.gd")
const _PpSheetPressSource := preload("res://power_system/sources/pp_sheet_press_source.gd")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _scroll: ScrollContainer = null
var _touch_scroll: TouchScrollHandler = null
var _model:         GraphModel = null
var _item_id:       String     = ""
var _is_connection: bool       = false
var _updating_form: bool       = false   # guard against emit→rebuild loops

var _title_lbl: Label          = null
var _form_vbox: VBoxContainer  = null
## Live PP beam-extruder readout labels (updated while the item stays selected).
var _pp_ext_rate_lbl: Label = null
var _pp_ext_stick_lbl: Label = null
var _pp_ext_cuts_lbl: Label = null

## Optional: parent graph calls set_toast_callback(Callable) for automation messages.
var _toast_cb: Callable = Callable()
## Automation ID for the load section currently shown (Push reads latest from model).
var _inspect_auto_id: String = ""
## HAEntityLinker node (optional - injected by SystemGraphView).
var _ha_linker: Node = null
var _compound_enter_cb: Callable = Callable()
var _compound_ungroup_cb: Callable = Callable()
var _compound_explode_cb: Callable = Callable()
var _compound_back_cb: Callable = Callable()
var _component_save_cb: Callable = Callable()
var _component_make_unique_cb: Callable = Callable()
var _conduit_route_cb: Callable = Callable()
var _conduit_clear_cb: Callable = Callable()
var _conduit_style_cb: Callable = Callable()
var _placeholder_cb: Callable = Callable()
var _place_model_cb: Callable = Callable()
var _place_site_twin_cb: Callable = Callable()
var _set_hidden3d_cb: Callable = Callable()
var _is_hidden3d_cb: Callable = Callable()
var _hide_placeholder_twins_cb: Callable = Callable()
var _edit_ports_cb: Callable = Callable()
var _preview_refresh_cb: Callable = Callable()
var _controller_reset_cb: Callable = Callable()
var _siphon_lab_cb: Callable = Callable()
## Resyncs a processor's dangling/ghost I/O tank containers after a direct
## in-place port edit (add/remove/kind change) — SystemGraphView-injected.
var _ghost_sync_cb: Callable = Callable()
## "Save to Library" — pushes the current processor instance's config back to
## its library preset and propagates it to sibling instances on the canvas.
var _save_to_library_cb: Callable = Callable()

## Per-automation UI state. Key = automation id, value = true if the editor
## panel is expanded. Persists across inspector rebuilds for the same node.
var _auto_expanded: Dictionary = {}
## Collapsible Advanced subsections (HA twin, HA export, manual scene path...).
## Key = section id, value = expanded bool. Persists across rebuilds.
var _advanced_expanded: Dictionary = {}
## Monotonic counter used when minting fresh automation ids for new rules.
var _auto_id_counter: int = 0
## FileDialog for attaching a user GLB to the selected graph node.
var _glb_file_dialog: FileDialog = null
## FileDialog + staged parse for a Cartesian-machine G-code/STL job upload.
var _machine_file_dialog: FileDialog = null
var _pending_job_parse: Dictionary = {}
var _pending_job_item_id: String = ""

## Single shared LoadCalibrator instance.  Live progress is reported through
## these widget refs so the panel doesn't need to be rebuilt every tick.
var _calibrator: Node = null
var _cal_status_lbl: Label = null
var _cal_remaining_lbl: Label = null
var _cal_live_lbl: Label = null
var _cal_avg_lbl: Label = null
var _cal_peak_lbl: Label = null
var _cal_btn: Button = null
var _cal_graph: Control = null   # CalibrationGraph instance


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_process_input(true)
	_build_shell()
	_touch_scroll = _TOUCH_SCROLL_HANDLER.new()
	_touch_scroll.bind(_scroll, self)


func _input(event: InputEvent) -> void:
	if not visible or _touch_scroll == null:
		return
	if _touch_scroll.handle(event):
		get_viewport().set_input_as_handled()


func _build_shell() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# ---- Title strip ----
	var hdr_pc := PanelContainer.new()
	var hdr_sb := StyleBoxFlat.new()
	hdr_sb.bg_color              = C_PANEL
	hdr_sb.set_border_width(SIDE_BOTTOM, 1)
	hdr_sb.border_color          = C_BORDER
	hdr_sb.content_margin_left   = 12.0
	hdr_sb.content_margin_right  = 12.0
	hdr_sb.content_margin_top    = 10.0
	hdr_sb.content_margin_bottom = 10.0
	hdr_pc.add_theme_stylebox_override("panel", hdr_sb)
	root.add_child(hdr_pc)

	_title_lbl = Label.new()
	_title_lbl.text = "Nothing selected"
	_title_lbl.add_theme_color_override("font_color", C_TEXT_M)
	_title_lbl.add_theme_font_size_override("font_size", 12)
	_title_lbl.clip_text = true
	hdr_pc.add_child(_title_lbl)

	# ---- Scrollable form ----
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_form_vbox = VBoxContainer.new()
	_form_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form_vbox.size_flags_vertical   = Control.SIZE_SHRINK_BEGIN
	_form_vbox.add_theme_constant_override("separation", 0)
	scroll.add_child(_form_vbox)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func inspect_item(item: Dictionary, mdl: GraphModel) -> void:
	_model        = mdl
	_item_id      = item.get("id", "")
	_is_connection = false
	_rebuild_for_item(item)


func inspect_connection(conn: Dictionary, mdl: GraphModel) -> void:
	_model        = mdl
	_item_id      = conn.get("id", "")
	_is_connection = true
	_rebuild_for_connection(conn)


func clear_selection() -> void:
	_model        = null
	_item_id      = ""
	_is_connection = false
	_clear_form()
	_title_lbl.text = "Nothing selected"
	_title_lbl.add_theme_color_override("font_color", C_TEXT_M)


func set_toast_callback(cb: Callable) -> void:
	_toast_cb = cb


func set_ha_linker(linker: Node) -> void:
	_ha_linker = linker


func set_compound_callbacks(enter_cb: Callable, ungroup_cb: Callable,
		back_cb: Callable = Callable(), explode_cb: Callable = Callable()) -> void:
	_compound_enter_cb = enter_cb
	_compound_ungroup_cb = ungroup_cb
	_compound_back_cb = back_cb
	_compound_explode_cb = explode_cb


func set_component_callbacks(save_cb: Callable, make_unique_cb: Callable) -> void:
	_component_save_cb = save_cb
	_component_make_unique_cb = make_unique_cb


func set_conduit_callbacks(route_cb: Callable, clear_cb: Callable,
		style_cb: Callable = Callable()) -> void:
	_conduit_route_cb = route_cb
	_conduit_clear_cb = clear_cb
	_conduit_style_cb = style_cb


func set_placeholder_callback(cb: Callable) -> void:
	_placeholder_cb = cb


func set_place_model_callback(cb: Callable) -> void:
	_place_model_cb = cb


func set_siphon_lab_callback(cb: Callable) -> void:
	_siphon_lab_cb = cb


func set_place_site_twin_callback(cb: Callable) -> void:
	_place_site_twin_cb = cb


## cb(item_id: String, hidden: bool) -> void ; is_cb(item_id) -> bool ;
## bulk_cb(hidden: bool) -> void — hide/show a node's 3D twin + a bulk placeholder hide.
func set_hide_3d_callbacks(set_cb: Callable, is_cb: Callable, bulk_cb: Callable) -> void:
	_set_hidden3d_cb = set_cb
	_is_hidden3d_cb = is_cb
	_hide_placeholder_twins_cb = bulk_cb


func set_edit_ports_callback(cb: Callable) -> void:
	_edit_ports_cb = cb


func set_preview_refresh_callback(cb: Callable) -> void:
	_preview_refresh_cb = cb


func set_controller_reset_callback(cb: Callable) -> void:
	_controller_reset_cb = cb


func set_ghost_sync_callback(cb: Callable) -> void:
	_ghost_sync_cb = cb


func set_save_to_library_callback(cb: Callable) -> void:
	_save_to_library_cb = cb


# ---------------------------------------------------------------------------
# Form building
# ---------------------------------------------------------------------------

func _rebuild_for_item(item: Dictionary) -> void:
	_updating_form = true
	_clear_form()

	var itype: String = item.get("type", "")
	var specs: Dictionary = item.get("specs", {})
	var iname: String = specs.get("name", itype.capitalize())

	_title_lbl.text = "%s  %s" % [_type_icon(itype), iname]
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_append_education_card(item)

	match itype:
		"panel":
			_section("Specs")
			_text_field("Name",              specs.get("name", ""),    "specs/name")
			_num_field("Peak Power (W)",     specs.get("wmp",  0.0),   "specs/wmp",  0, 5000,  1.0)
			_num_field("V open-circuit",     specs.get("voc",  0.0),   "specs/voc",  0,  600,  0.1)
			_num_field("V at MPP",           specs.get("vmp",  0.0),   "specs/vmp",  0,  600,  0.1)
			_num_field("I short-circuit (A)",specs.get("isc",  0.0),   "specs/isc",  0,   50,  0.01)
			_num_field("I at MPP (A)",       specs.get("imp",  0.0),   "specs/imp",  0,   50,  0.01)
			_section("Sunlight")
			_readonly_field("Sunlight factor", "%.0f%%" % (float(specs.get("sunlight_factor", 1.0)) * 100.0))
			_readonly_field("Live output", "%.0f W" % (float(specs.get("current_output_kw", 0.0)) * 1000.0))
			_hint_label("Sunlight factor is 3D site shade (1.0 = unshaded). Place the panel on the Site Plan to enable per-node shading.")
			_section("Cost")
			_num_field("Unit Cost ($)",      specs.get("cost", 0.0),   "specs/cost", 0, 99999, 1.0)

		"plant":
			_section("Site / Area")
			_text_field("Name",              specs.get("name", ""),              "specs/name")
			if GraphSiteLayout.has_site_coords(item):
				_num_field("Site X (m east)", float(item.get("site_x_m", 0.0)), "site_x_m", -2000, 2000, 0.1)
				_num_field("Site Z (m south)", float(item.get("site_z_m", 0.0)), "site_z_m", -2000, 2000, 0.1)
			_num_field("Area (m²)",          specs.get("area_m2", 10.0),         "specs/area_m2", 0.5, 100000.0, 0.5)
			_num_field("Map icon scale", float(specs.get("map_display_scale", 1.0)),
					"specs/map_display_scale", 0.5, 8.0, 0.1)
			var plant_soi_row := _row_container()
			var plant_soi_h: HBoxContainer = plant_soi_row.get_child(0) as HBoxContainer
			plant_soi_h.add_child(_key_label("Use SoI area"))
			var plant_soi_cb := CheckBox.new()
			plant_soi_cb.button_pressed = bool(specs.get("use_soi_area", false))
			plant_soi_cb.focus_mode = Control.FOCUS_NONE
			plant_soi_cb.toggled.connect(func(on: bool) -> void: _commit_field("specs/use_soi_area", on))
			plant_soi_h.add_child(plant_soi_cb)
			_form_vbox.add_child(plant_soi_row)
			if not str(specs.get("osm_tag", "")).is_empty():
				_readonly_field("OSM tag", str(specs.get("osm_tag", "")))
			_section("Light-use efficiency")
			_num_field("LUE (g/MJ PAR)",     specs.get("lue_g_per_mj", 2.0),     "specs/lue_g_per_mj", 0.1, 5.0, 0.05)
			_num_field("Water (L/kg DM)",    specs.get("water_l_per_kg", 50.0),  "specs/water_l_per_kg", 1.0, 2000.0, 1.0)
			_num_field("Nutrients (kg/kg)",  specs.get("nutrient_kg_per_kg", 0.02), "specs/nutrient_kg_per_kg", 0.0, 1.0, 0.001)
			_section("Live")
			_readonly_field("PAR", "%.0f W/m²" % float(specs.get("par_wm2", 0.0)))
			_readonly_field("Sunlight factor", "%.0f%%" % (float(specs.get("sunlight_factor", 1.0)) * 100.0))
			_readonly_field("Biomass rate", str(specs.get("display_value", "—")))
			_readonly_field("Water draw", "%.2f L/h" % float(specs.get("water_lph", 0.0)))
			_hint_label("Sunlight factor is 3D site shade (1.0 = unshaded). Water is required; nutrients only limit growth when wired.")
			_section("Cost")
			_num_field("Unit Cost ($)",      specs.get("cost", 0.0),             "specs/cost", 0, 99999, 1.0)

		"wind":
			_section("Turbine")
			_text_field("Name",               specs.get("name", ""),              "specs/name")
			_text_field("Kind (hawt/vawt)",   specs.get("kind", "hawt"),          "specs/kind")
			_num_field("Rated Power (W)",     specs.get("rated_w", 1000.0),       "specs/rated_w",          50, 50000, 10.0)
			_num_field("Rotor Diameter (m)",  specs.get("rotor_diameter_m", 2.1), "specs/rotor_diameter_m", 0.5,   20, 0.05)
			_num_field("Peak Cp (≤0.593)",    specs.get("cp_peak", 0.42),         "specs/cp_peak",          0.05, 0.593, 0.005)
			_num_field("Generator Eff.",      specs.get("generator_efficiency", 0.90), "specs/generator_efficiency", 0.5, 1.0, 0.01)
			_section("Wind Speeds (m/s)")
			_num_field("Cut-in",              specs.get("cut_in_ms", 3.0),        "specs/cut_in_ms",        1.0,  6.0, 0.1)
			_num_field("Rated",               specs.get("rated_ms", 11.0),        "specs/rated_ms",         6.0, 20.0, 0.1)
			_num_field("Cut-out",             specs.get("cut_out_ms", 20.0),      "specs/cut_out_ms",      12.0, 40.0, 0.5)
			_section("Site / Placement")
			_num_field("Hub Height (m)",      specs.get("hub_height_m", 10.0),    "specs/hub_height_m",     2.0, 60.0, 0.5)
			_num_field("Mean Wind (m/s)",     specs.get("site_mean_wind_ms", 6.0),"specs/site_mean_wind_ms", 0.0, 15.0, 0.1)
			_num_field("Roughness z0 (m)",    specs.get("surface_roughness_m", 0.03), "specs/surface_roughness_m", 0.0001, 1.0, 0.001)
			_num_field("Altitude (m)",        specs.get("site_altitude_m", 0.0),  "specs/site_altitude_m",  0.0, 4000.0, 10.0)
			_section("Cost")
			_num_field("Unit Cost ($)",       specs.get("cost", 0.0),             "specs/cost", 0, 99999, 1.0)

		"hydro":
			_section("Turbine")
			_text_field("Name",               specs.get("name", ""),              "specs/name")
			_turbine_kind_field("Turbine kind", str(specs.get("kind", "pelton")), "specs/kind")
			_num_field("Turbine Eff. (0=auto)", specs.get("turbine_efficiency", 0.0), "specs/turbine_efficiency", 0.0, 0.95, 0.01)
			_num_field("Generator Eff.",      specs.get("generator_efficiency", 0.85), "specs/generator_efficiency", 0.5, 1.0, 0.01)
			_section("Site / Placement")
			_num_field("Gross Head (m)",      specs.get("gross_head_m", 25.0),    "specs/gross_head_m",     0.5, 300.0, 0.5)
			_num_field("Design Flow (L/s)",   specs.get("design_flow_lps", 3.0),  "specs/design_flow_lps",  0.1, 5000.0, 0.1)
			_section("Penstock")
			_num_field("Length (m)",          specs.get("penstock_length_m", 60.0),    "specs/penstock_length_m",    1.0, 2000.0, 1.0)
			_num_field("Diameter (mm)",       specs.get("penstock_diameter_mm", 63.0), "specs/penstock_diameter_mm", 20.0, 2000.0, 1.0)
			_num_field("Roughness ε (mm)",    specs.get("pipe_roughness_mm", 0.0015),  "specs/pipe_roughness_mm",    0.0005, 1.0, 0.0005)
			_section("Cost")
			_num_field("Unit Cost ($)",       specs.get("cost", 0.0),             "specs/cost", 0, 99999, 1.0)

		"battery", "smartbattery":
			_section("Specs")
			_text_field("Name",              specs.get("name", ""),      "specs/name")
			_num_field("Nominal Voltage (V)",specs.get("voltage", 12.0), "specs/voltage",  0, 1000, 0.1)
			_num_field("Capacity (Ah)",      specs.get("ah", 100.0),     "specs/ah",       0, 10000, 1.0)
			_num_field("Energy (kWh)",       specs.get("kwh", 1.2),      "specs/kwh",      0,  1000, 0.01)
			_num_field("State of Charge",    specs.get("soc", 0.8),      "specs/soc",      0,     1, 0.01)
			_section("Cost")
			_num_field("Unit Cost ($)",      specs.get("cost", 0.0),     "specs/cost", 0, 99999, 1.0)
			_section("Battery Protection")
			_num_field("Shut off below (%)", specs.get("soc_shutdown_pct", 10.0), "specs/soc_shutdown_pct", 1.0, 99.0, 1.0)
			_num_field("Resume above (%)",   specs.get("soc_resume_pct",   20.0), "specs/soc_resume_pct",   1.0, 99.0, 1.0)
			_num_field("Alert Threshold (%)", specs.get("alert_threshold_pct", 95.0), "specs/alert_threshold_pct", 0.0, 100.0, 1.0)
			_build_battery_cells_section(item)

		"controller":
			_section("Specs")
			_text_field("Name",              specs.get("name", ""),             "specs/name")
			_num_field("Max PV Voltage (V)", specs.get("max_voc", 150.0),       "specs/max_voc",         0, 1000,  1.0)
			_num_field("Charge Current (A)", specs.get("max_charge_amps", 30.0),"specs/max_charge_amps", 0,  500,  1.0)
			_num_field("Max PV Power (W)",   specs.get("max_pv_watts", 2400.0), "specs/max_pv_watts",    0, 50000, 10.0)
			if bool(specs.get("destroyed", false)):
				_section("Fault")
				_readonly_field("Status", "DESTROYED - %s" % str(specs.get("destroyed_reason", "Over-voltage")))
				var reset_btn := Button.new()
				reset_btn.text = "Reset Controller"
				reset_btn.add_theme_color_override("font_color", Color(0.4, 0.95, 0.55))
				var cid := str(item.get("id", ""))
				reset_btn.pressed.connect(func() -> void:
					if _controller_reset_cb.is_valid():
						_controller_reset_cb.call(cid)
				)
				_form_vbox.add_child(reset_btn)
			_section("Cost")
			_num_field("Unit Cost ($)",      specs.get("cost", 0.0),            "specs/cost", 0, 99999, 1.0)
			_section("Overload Protection")
			_num_field("Shutdown above (W)", specs.get("overload_watts",       3500.0), "specs/overload_watts",       100.0, 20000.0, 100.0)
			_num_field("Duration (s)",       specs.get("overload_duration_s",    10.0), "specs/overload_duration_s",    1.0,   300.0,   1.0)
			_num_field("Lockout (s)",        specs.get("overload_lockout_s",     30.0), "specs/overload_lockout_s",     1.0,  3600.0,   1.0)

		"appliance", "acload":
			_section("Specs")
			_text_field("Name",          specs.get("name", ""),       "specs/name")
			_num_field("Max Power (W)",  specs.get("max_watts", 100.0),"specs/max_watts",  0, 100000, 1.0)
			_num_field("Avg Power (W)",  specs.get("avg_watts", 50.0), "specs/avg_watts",  0, 100000, 1.0)

		"processor":
			_section("Specs")
			_text_field("Name",              specs.get("name", ""),         "specs/name")
			if str(specs.get("role", "")) == "habitat":
				_num_field("Occupants", specs.get("occupants", 1.0), "specs/occupants", 1, 64, 1.0)
				var starved: Array = specs.get("starved_kinds", []) as Array
				if starved.is_empty():
					_readonly_field("Demand status", "OK - all inputs supplied")
				else:
					var parts: PackedStringArray = PackedStringArray()
					for sk: Variant in starved:
						parts.append(ResourceKinds.display_name(str(sk)))
					_readonly_field("Demand status", "STARVED: %s" % ", ".join(parts))
			elif str(specs.get("role", "")) == "csp_concentrator":
				_build_csp_concentrator_section(specs)
			elif str(specs.get("role", "")) == "heliostat":
				_build_heliostat_section(specs)
			elif str(specs.get("role", "")) == "siphon_hydro":
				_build_siphon_hydro_section(specs)
			elif str(specs.get("role", "")) == "biodigester":
				_build_biodigester_section(specs)
			elif str(specs.get("role", "")) == "pp_beam_extruder":
				_build_pp_beam_extruder_section(specs)
			elif str(specs.get("role", "")) == "pp_sheet_press":
				_build_pp_sheet_press_section(specs)
			elif str(specs.get("role", "")) == "cartesian_machine":
				_build_cartesian_machine_section(item, specs)
			else:
				_build_processor_energy_picker(specs)
				_num_field("Power Draw (W)",     specs.get("watts", 0.0),       "specs/watts",       0, 100000, 10.0)
				_num_field("Efficiency",         specs.get("efficiency", 1.0),  "specs/efficiency",  0.0, 1.0, 0.01)
				_num_field("Energy (Wh/unit)",   specs.get("energy_wh_per_unit", 0.0), "specs/energy_wh_per_unit", 0, 100000, 1.0)
				var daily_note := str(specs.get("daily_note", ""))
				if not daily_note.is_empty():
					_readonly_field("Daily design", daily_note)
			var _role := str(specs.get("role", ""))
			if _role != "cartesian_machine" and _role != "pp_sheet_press" \
					and _role != "siphon_hydro":
				_build_process_recipe_section(specs)
			elif _role == "pp_sheet_press":
				pass  # recipe picker lives in _build_pp_sheet_press_section
			_section("Cost")
			_num_field("Unit Cost ($)",      specs.get("cost", 0.0),        "specs/cost", 0, 99999, 1.0)
			_build_save_to_library_button(item)

		"resource":
			_section("Specs")
			_text_field("Name",         specs.get("name", ""),      "specs/name")
			_build_resource_kind_picker(specs)
			var unlimited := bool(specs.get("unlimited_capacity", false))
			var unlim_row := _row_container()
			var unlim_h: HBoxContainer = unlim_row.get_child(0) as HBoxContainer
			unlim_h.add_child(_key_label("No capacity limit"))
			var unlim_cb := CheckBox.new()
			unlim_cb.button_pressed = unlimited
			unlim_cb.focus_mode = Control.FOCUS_NONE
			unlim_cb.tooltip_text = "Conceptual ∞ tank — never fills up. Prefer “Allow deficit” when you want to see stock change."
			unlim_cb.toggled.connect(func(on: bool) -> void:
				_commit_field("specs/unlimited_capacity", on)
				# Anchor at empty so absolute stock (level × 1e12) stays readable.
				if on and absf(float(specs.get("level", 0.0)) - 0.5) < 0.001:
					_commit_field("specs/level", 0.0)
				_rebuild_current_item()
			)
			unlim_h.add_child(unlim_cb)
			_form_vbox.add_child(unlim_row)

			var allow_neg := bool(specs.get("allow_negative", false))
			var neg_row := _row_container()
			var neg_h: HBoxContainer = neg_row.get_child(0) as HBoxContainer
			neg_h.add_child(_key_label("Allow deficit"))
			var neg_cb := CheckBox.new()
			neg_cb.button_pressed = allow_neg
			neg_cb.focus_mode = Control.FOCUS_NONE
			neg_cb.tooltip_text = "Stock may go negative when downstream pulls. Never blocks consumers or producers — useful for sizing real capacity while watching flow."
			neg_cb.toggled.connect(func(on: bool) -> void:
				_commit_field("specs/allow_negative", on)
				_rebuild_current_item()
			)
			neg_h.add_child(neg_cb)
			_form_vbox.add_child(neg_row)

			if unlimited and not allow_neg:
				_readonly_field("Capacity", "∞ (conceptual)")
			else:
				_num_field("Capacity", specs.get("capacity_qty", 100.0), "specs/capacity_qty", 0.001, 1e9, 1.0)
			_text_field("Capacity Unit", specs.get("capacity_unit", "L"), "specs/capacity_unit")
			if bool(specs.get("pond_storage", false)):
				_build_pond_twin_mode_section(specs)
			var stock := ResourceKinds.tank_stock_qty(specs)
			var stock_lbl := ResourceKinds.format_tank_stock(specs)
			if allow_neg and stock < 0.0:
				_readonly_field("Stock (sim)", "%s  ⚠ deficit" % stock_lbl)
			elif unlimited:
				_readonly_field("Stock (sim)", "%s  (∞ cap)" % stock_lbl)
			else:
				_readonly_field("Stock (sim)", stock_lbl)
			if not unlimited and not allow_neg:
				_readonly_field("Fill Level (sim)", "%.1f%%" % (clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * 100.0))
			_num_field("Alert Threshold (%)", specs.get("alert_threshold_pct", 95.0), "specs/alert_threshold_pct", 0.0, 100.0, 1.0)
			var scale_row := _row_container()
			var scale_h: HBoxContainer = scale_row.get_child(0) as HBoxContainer
			scale_h.add_child(_key_label("Scale with fill"))
			var scale_cb := CheckBox.new()
			scale_cb.button_pressed = bool(specs.get("scale_with_fill", true))
			scale_cb.focus_mode = Control.FOCUS_NONE
			scale_cb.toggled.connect(func(on: bool) -> void: _commit_field("specs/scale_with_fill", on))
			scale_h.add_child(scale_cb)
			_form_vbox.add_child(scale_row)
			var jit_row := _row_container()
			var jit_h: HBoxContainer = jit_row.get_child(0) as HBoxContainer
			jit_h.add_child(_key_label("Just-in-time outflow"))
			var jit_cb := CheckBox.new()
			jit_cb.button_pressed = bool(specs.get("jit_outflow", false))
			jit_cb.focus_mode = Control.FOCUS_NONE
			jit_cb.tooltip_text = "Fill connected downstream containers without overfilling; stop when they are full."
			jit_cb.toggled.connect(func(on: bool) -> void: _commit_field("specs/jit_outflow", on))
			jit_h.add_child(jit_cb)
			_form_vbox.add_child(jit_row)
			_section("Cost")
			_num_field("Unit Cost ($)", specs.get("cost", 0.0),     "specs/cost", 0, 99999, 1.0)

		"catchment":
			_section("Site / Area")
			_text_field("Name", specs.get("name", ""), "specs/name")
			if GraphSiteLayout.has_site_coords(item):
				_num_field("Site X (m east)", float(item.get("site_x_m", 0.0)), "site_x_m", -2000, 2000, 0.1)
				_num_field("Site Z (m south)", float(item.get("site_z_m", 0.0)), "site_z_m", -2000, 2000, 0.1)
			_num_field("Catchment Area (m²)", specs.get("area_m2", 10.0), "specs/area_m2", 0.0, 100000.0, 1.0)
			_num_field("Map icon scale", float(specs.get("map_display_scale", 1.0)),
					"specs/map_display_scale", 0.5, 8.0, 0.1)
			var soi_row := _row_container()
			var soi_h: HBoxContainer = soi_row.get_child(0) as HBoxContainer
			soi_h.add_child(_key_label("Use SoI area"))
			var soi_cb := CheckBox.new()
			soi_cb.button_pressed = bool(specs.get("use_soi_area", false))
			soi_cb.focus_mode = Control.FOCUS_NONE
			soi_cb.toggled.connect(func(on: bool) -> void: _commit_field("specs/use_soi_area", on))
			soi_h.add_child(soi_cb)
			_form_vbox.add_child(soi_row)
			_section("Specs")
			_text_field("Catchment kind", str(specs.get("catchment_kind", "rain")), "specs/catchment_kind")
			if str(specs.get("catchment_kind", "rain")) != "biomass":
				var runoff_default := 0.35 if str(specs.get("catchment_kind", "")) == "watershed" \
						else 0.85
				_num_field("Runoff Coefficient",
						specs.get("runoff_coeff", runoff_default), "specs/runoff_coeff", 0.0, 1.0, 0.01)
			var live_lph := float(specs.get("live_capture_lph", specs.get("live_capture_rate", 0.0)))
			if str(specs.get("catchment_kind", "rain")) == "biomass":
				_readonly_field("Live capture", "%.3f kg/h" % live_lph)
			else:
				_readonly_field("Live capture", "%.1f L/h" % live_lph)
			if str(specs.get("catchment_kind", "")) == "watershed":
				_readonly_field("Pond tag", str(specs.get("pond_tag", "")))
				if int(specs.get("cell_count", 0)) > 0:
					_readonly_field("DEM cells", str(int(specs.get("cell_count", 0))))
				_hint_label("Hillside runoff from DEM watershed → pond tank (no Rain PBI wire). Refresh from Pond settings.")
			if not str(specs.get("osm_tag", "")).is_empty():
				_readonly_field("OSM tag", str(specs.get("osm_tag", "")))
			_section("Cost")
			_num_field("Unit Cost ($)", specs.get("cost", 0.0), "specs/cost", 0, 99999, 1.0)

		"pbi":
			_section("Specs")
			_text_field("Name", specs.get("name", ""), "specs/name")
			var pbi_kind := str(specs.get("resource_kind", ""))
			_readonly_field("Kind", pbi_kind.capitalize())
			if pbi_kind == "sunlight" or pbi_kind == "solar":
				_readonly_field("Irradiance", "%.0f W/m²" % float(specs.get("irradiance_wm2", 0.0)))
				_readonly_field("SoI Flux", SolarEnergyBudget.format_kw(float(specs.get("flux_kw", 0.0))))
				_readonly_field("Sun Availability", "%.0f%%" % (float(specs.get("sun_availability", 0.0)) * 100.0))
				_readonly_field("Cloud cover", "%.0f%%" % (float(specs.get("cloud_frac", 0.0)) * 100.0))
				_hint_label("Flux = irradiance × SoI area. Optional radiant wires visualize who draws from it; they never gate receivers.")
			elif pbi_kind == "wind" or pbi_kind == "mechanical" or pbi_kind == "atmosphere" or pbi_kind == "air":
				_readonly_field("Wind speed", "%.1f m/s" % float(specs.get("wind_ms", 0.0)))
				_readonly_field("Temperature", "%.1f °C" % float(specs.get("temp_c", 20.0)))
				_readonly_field("Relative humidity", "%.0f%%" % float(specs.get("humidity_pct", 50.0)))
				_readonly_field("Cloud cover", "%.0f%%" % (float(specs.get("cloud_frac", 0.0)) * 100.0))
				_readonly_field("Kinetic flux", SolarEnergyBudget.format_kw(float(specs.get("kinetic_kw", 0.0))))
				_hint_label("Atmosphere is ambient — turbines already feel the wind. Optional dashed wires only visualize the link.")

		"shelly4pm", "spiderbox", "breaker_panel":
			_section("AC Passthrough")
			_hint_label("AC in → switched outlets. OFF channels disconnect attached loads (0 W draw).")
			_text_field("Name",                specs.get("name", ""),                   "specs/name")
			_num_field("Max Amps / Circuit",   specs.get("max_amps_per_circuit", 16.0), "specs/max_amps_per_circuit", 1.0, 100.0, 1.0)
			if itype == "breaker_panel":
				_num_field("Main amps", float(specs.get("main_amps", 100.0)), "specs/main_amps", 20.0, 400.0, 10.0)
				_readonly_field("Main breaker", "ON" if bool(specs.get("main_on", true)) else "OFF")
			_section("Circuit Names")
			var nchan := int(specs.get("channel_count", 4))
			for ci in range(clampi(nchan, 1, 8)):
				_text_field("Ch %d Name" % ci,
					specs.get("c%d_name" % ci, "Circuit %d" % ci), "specs/c%d_name" % ci)

		_:
			_section("Specs")
			_text_field("Name", specs.get("name", ""), "specs/name")

	# Automations are sim/gameplay-first - surfaced right after the core specs
	# so bound rules are visible without scrolling. HA export lives under Advanced.
	if _item_supports_automation(item):
		_build_load_automation_section(item)

	# Promote-to-parent: when this node lives inside a super-node, offer to expose
	# any of its handles as a promoted port on the enclosing compound.
	if itype != "compound":
		_build_promote_ports_section(item)

	# Look & layout - editable size + canvas position (after type specs).
	_build_appearance_section(item)

	# 3D embodiment - Place in 3D when a GLB is attached, else prompt to add one.
	# Compounds with a model_id (StarShade super-node) also get Place in 3D so
	# power conduits can anchor to the world mesh.
	var has_model_id := not str((item.get("specs", {}) as Dictionary).get("model_id", "")).is_empty()
	if itype in ["panel", "plant", "wind", "hydro", "processor", "resource", "catchment",
			"appliance", "acload", "battery", "smartbattery", "controller"] \
			or (itype == "compound" and has_model_id):
		_build_scene_link_section(item)

	if itype in ["shelly4pm", "spiderbox", "breaker_panel"]:
		_build_shelly4pm_controls_section(item)
	if itype == "compound":
		_build_compound_section(item)

	# Optional LIVE twin + calibration - tucked under Advanced so the default
	# inspector stays focused on simulation gameplay.
	if itype in ["panel", "battery", "smartbattery", "controller", "shelly4pm",
			"spiderbox", "breaker_panel", "appliance", "acload"]:
		_build_advanced_ha_twin_section(item)
	if itype in ["appliance", "acload"]:
		_build_advanced_calibration_section(item)

	_updating_form = false


func _rebuild_for_connection(conn: Dictionary) -> void:
	_updating_form = true
	_clear_form()

	var polarity: String = conn.get("polarity", "positive")
	var rtype: String = str(conn.get("resource_type", ""))
	var rkind := ResourceKinds.normalize_kind(rtype)
	var is_radiant: bool = (polarity == "resource" and (rkind == "sunlight" or rkind == "wind"))
	_title_lbl.text = "  Radiant wire" if is_radiant else ("  Wire  (%s)" % polarity)
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_append_education_card_dict(_EDU_CARDS_SCRIPT.card_for_connection(conn))

	_section("Properties")
	_readonly_field("Polarity",   polarity)
	if not rtype.is_empty():
		_readonly_field("Resource kind", ResourceKinds.display_name(rtype))
	_readonly_field("Source item",  conn.get("source_item_id",   "-"))
	_readonly_field("Source port",  conn.get("source_handle_id", "-"))
	_readonly_field("Target item",  conn.get("target_item_id",   "-"))
	_readonly_field("Target port",  conn.get("target_handle_id", "-"))

	var is_res: bool = (polarity == "resource")
	if is_radiant:
		_section("Radiant Link")
		_readonly_field("Delivery", "Ambient (non-blocking)")
		_readonly_field("Live flux", SolarEnergyBudget.format_kw(float(conn.get("flow_rate", 0.0))))
		if rkind == "wind":
			_hint_label("No conduit — atmosphere isn't piped. Turbines work without this wire.")
		else:
			_hint_label("No conduit diameter — sunlight isn't piped. Dash speed tracks SoI flux.")
	elif is_res:
		_section("Conduit Info")
		_num_field("Diameter (mm)",    float(conn.get("conduit_diameter",   25.0)), "conduit_diameter",       1, 1000, 1.0)
		_num_field("Length (m)",       float(conn.get("estimated_length",  1.0)), "estimated_length", 0, 9999, 0.1)
		_num_field("Max Pressure (PSI)", float(conn.get("max_pressure",     150.0)), "max_pressure",         0,  5000, 1.0)
		_build_connection_loss_section(conn, false)
	else:
		_section("Wire Info")
		_num_field("Gauge (AWG)",    float(conn.get("wire_gauge",   12.0)), "wire_gauge",       0, 40, 1.0)
		_num_field("Length (m)",     float(conn.get("estimated_length",  1.0)), "estimated_length", 0, 9999, 0.1)
		_num_field("Max Amps",       float(conn.get("wire_amps",     20.0)), "wire_amps",         0,  500, 1.0)
		_build_connection_loss_section(conn, true)

	_section("Style Overrides")
	_text_field("Color", str(conn.get("color_override", "")), "color_override")
	_num_field("Base Thickness", float(conn.get("thickness_override", 0.0)), "thickness_override", 0, 50, 0.5)
	
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Sankey Scale (Flow)"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var cb := CheckBox.new()
	cb.button_pressed = bool(conn.get("sankey_scale", true))
	cb.toggled.connect(func(toggled_on: bool) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		_model.update_connection(_item_id, {"sankey_scale": toggled_on})
	)
	row.add_child(cb)
	_form_vbox.add_child(row)

	_build_connection_2d_route_section(conn)

	_build_connection_3d_route_section(conn)

	_updating_form = false


## Wave 8: connector-loss telemetry + per-connection simulate override.
## Electrical wires show I²R loss / voltage drop / amps; fluid conduits show
## friction pressure drop / flow derate. Overload readout turns red past 1.0×.
func _build_connection_loss_section(conn: Dictionary, electrical: bool) -> void:
	_section("Losses")
	if bool(conn.get("severed", false)):
		var sev := Label.new()
		sev.text = "BURNED OUT — no flow. Reset below."
		sev.add_theme_color_override("font_color", UITheme.C_ERROR)
		_form_vbox.add_child(sev)
		var reset_btn := Button.new()
		reset_btn.text = "Reset connector"
		reset_btn.pressed.connect(func() -> void:
			if _model != null and not _item_id.is_empty():
				_model.update_connection(_item_id, {
					"severed": false, "overload_s": 0.0, "overload_ratio": 0.0,
				})
				var refreshed := _model.get_connection(_item_id)
				if not refreshed.is_empty():
					_rebuild_for_connection(refreshed)
		)
		_form_vbox.add_child(reset_btn)
	if electrical:
		_readonly_field("Conduction loss", "%.1f W" % float(conn.get("loss_w", 0.0)))
		_readonly_field("Voltage drop", "%.1f %%" % (float(conn.get("drop_pct", 0.0)) * 100.0))
		_readonly_field("Current", "%.2f A" % float(conn.get("carried_amps", 0.0)))
	else:
		_readonly_field("Pressure drop", "%.2f psi" % float(conn.get("pressure_drop_psi", 0.0)))
		_readonly_field("Flow derate", "%.0f %%" % (float(conn.get("flow_derate", 1.0)) * 100.0))
	var ratio: float = float(conn.get("overload_ratio", 0.0))
	var ratio_row := HBoxContainer.new()
	ratio_row.add_theme_constant_override("separation", 8)
	var rl := Label.new()
	rl.text = "Overload"
	rl.add_theme_color_override("font_color", C_TEXT_S)
	rl.custom_minimum_size.x = 120.0
	ratio_row.add_child(rl)
	var rv := Label.new()
	rv.text = "%.2f× rating" % ratio
	rv.add_theme_color_override("font_color",
		UITheme.C_ERROR if ratio > 1.0 else (UITheme.C_WARN if ratio > 0.8 else C_TEXT))
	ratio_row.add_child(rv)
	_form_vbox.add_child(ratio_row)
	# Tri-state override: follow the global settings toggle, or force per-wire.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Simulate losses"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_item("Follow global setting", 0)
	opt.add_item("Always on", 1)
	opt.add_item("Always off", 2)
	var sel := 0
	if conn.has("simulate_losses"):
		sel = 1 if bool(conn.get("simulate_losses", false)) else 2
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var conn_ref := _model.get_connection(_item_id)
		if conn_ref.is_empty():
			return
		if idx == 0:
			conn_ref.erase("simulate_losses")
			_model.update_connection(_item_id, {})
		else:
			_model.update_connection(_item_id, {"simulate_losses": idx == 1})
	)
	row.add_child(opt)
	_form_vbox.add_child(row)


func _build_connection_2d_route_section(conn: Dictionary) -> void:
	_section("2D Routing")
	var wps: Array = conn.get("waypoints", []) as Array
	_readonly_field("Waypoints", str(wps.size()))
	_build_line_style_picker(conn)
	var style: String = str(conn.get("line_style", "bezier"))
	if style == "bezier":
		_build_curve_tension_slider(conn)
	else:
		_build_corner_radius_slider(conn)
	var hint := Label.new()
	if style == "orthogonal" or style == "metro":
		hint.text = "Double-click wire to select · double-click again to add bend · drag segments sideways/up-down · drag handles · RMB/Del to remove"
	else:
		hint.text = "Double-click wire to select · double-click again to add bend · drag handles · RMB or Del to remove"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", C_TEXT_M)
	hint.add_theme_font_size_override("font_size", 10)
	_form_vbox.add_child(hint)
	if wps.size() > 0:
		var clear_btn := Button.new()
		clear_btn.text = "Clear 2D waypoints"
		clear_btn.pressed.connect(func() -> void:
			if _model != null and not _item_id.is_empty():
				_model.update_connection(_item_id, {"waypoints": []})
		)
		_form_vbox.add_child(clear_btn)


func _build_curve_tension_slider(conn: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Curve angle"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0.15
	slider.max_value = 2.5
	slider.step = 0.05
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value = clampf(float(conn.get("curve_tension", 1.0)), 0.15, 2.5)
	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 36.0
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_color_override("font_color", C_TEXT_M)
	val_lbl.text = "%.2f" % slider.value
	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = "%.2f" % v
		if _updating_form or _model == null or _item_id.is_empty():
			return
		_model.update_connection(_item_id, {"curve_tension": v})
	)
	row.add_child(slider)
	row.add_child(val_lbl)
	_form_vbox.add_child(row)


func _build_corner_radius_slider(conn: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Corner radius"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 4.0
	slider.max_value = 120.0
	slider.step = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value = clampf(float(conn.get("corner_radius", 28.0)), 4.0, 120.0)
	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 36.0
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_color_override("font_color", C_TEXT_M)
	val_lbl.text = "%d" % int(slider.value)
	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = "%d" % int(v)
		if _updating_form or _model == null or _item_id.is_empty():
			return
		_model.update_connection(_item_id, {"corner_radius": v})
	)
	row.add_child(slider)
	row.add_child(val_lbl)
	_form_vbox.add_child(row)


func _build_line_style_picker(conn: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Line style"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var options: Array = [
		{"id": "bezier", "label": "Smooth bezier"},
		{"id": "orthogonal", "label": "Rounded rectilinear"},
		{"id": "metro", "label": "Metro (45° chamfer)"},
	]
	var current: String = str(conn.get("line_style", "bezier"))
	var sel := 0
	for oi: int in options.size():
		var od: Dictionary = options[oi] as Dictionary
		opt.add_item(str(od.get("label", "")), oi)
		if str(od.get("id", "")) == current:
			sel = oi
	# Unknown / legacy styles still select something sensible.
	if current != "bezier" and current != "orthogonal" and current != "metro":
		sel = 0
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var style_id := str((options[idx] as Dictionary).get("id", "bezier"))
		_model.last_line_style = style_id
		_model.update_connection(_item_id, {"line_style": style_id})
		var refreshed := _model.get_connection(_item_id)
		if not refreshed.is_empty():
			_rebuild_for_connection(refreshed)
	)
	row.add_child(opt)
	_form_vbox.add_child(row)


func _build_connection_3d_route_section(conn: Dictionary) -> void:
	_section("3D Route")
	var routable := false
	var status := "Unrouted - link both nodes to 3D scene objects"
	if _model != null:
		routable = _model.connection_is_3d_routable(conn)
		if routable:
			var global_on := true
			if is_instance_valid(SimSettingsController):
				global_on = bool(SimSettingsController.conduits_3d_visible)
			if not ConduitKinds.resolve_visible_3d(conn, global_on):
				if conn.has("visible_3d") and conn.get("visible_3d") != null \
						and not bool(conn.get("visible_3d")):
					status = "Hidden (forced off)"
				else:
					status = "Hidden by global (timeline: 3D wires)"
			elif bool(conn.get("route_locked", false)):
				var pins: Array = conn.get("route_3d", []) as Array
				status = "Locked (%d pin(s))" % pins.size()
			else:
				var tid := ConduitKinds.derive_type_for_connection(conn)
				status = "Auto pipes" if ConduitKinds.is_pipes_type(tid) \
						else "Auto route"
		else:
			var src := _model.get_item(str(conn.get("source_item_id", "")))
			var tgt := _model.get_item(str(conn.get("target_item_id", "")))
			var miss: Array = []
			if not _model.item_has_3d_anchor(src):
				miss.append("source")
			if not _model.item_has_3d_anchor(tgt):
				miss.append("target")
			if not miss.is_empty():
				status = "Unrouted - missing 3D link on: %s" % ", ".join(miss)
	_readonly_field("Status", status)
	_build_tri_state_opt(conn, "visible_3d", "Show in 3D", "Follow global / force on / force off")
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	_readonly_field("Conduit (derived)", ConduitKinds.display_name(type_id))
	_build_conduit_type_picker(conn)
	# Quick: Make physical
	var phys_row := HBoxContainer.new()
	phys_row.add_theme_constant_override("separation", 8)
	var phys_btn := Button.new()
	phys_btn.text = "Make physical"
	phys_btn.tooltip_text = "Set conduit to the suggested physical kind (extension cord, hose, pipe…)"
	phys_btn.focus_mode = Control.FOCUS_NONE
	phys_btn.add_theme_color_override("font_color", C_PRIMARY)
	phys_btn.pressed.connect(func() -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var suggested := ConduitKinds.suggested_physical_type(conn)
		_model.update_connection(_item_id, {"conduit_type": suggested})
		inspect_connection(_model.get_connection(_item_id), _model)
	)
	phys_row.add_child(phys_btn)
	var conceptual_btn := Button.new()
	conceptual_btn.text = "Make conceptual"
	conceptual_btn.focus_mode = Control.FOCUS_NONE
	conceptual_btn.pressed.connect(func() -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		_model.update_connection(_item_id, {"conduit_type": ""})
		inspect_connection(_model.get_connection(_item_id), _model)
	)
	phys_row.add_child(conceptual_btn)
	_form_vbox.add_child(phys_row)
	_build_tri_state_opt(conn, "flow_glow", "Flow glow", "Conceptual always glows; physical follows global unless forced")
	var len_m: float = float(conn.get("route_length_m", conn.get("estimated_length", 0.0)))
	_readonly_field("Run length (m)", "%.2f" % len_m if len_m > 0.001 else "-")
	var segs := ConduitKinds.segment_count_for_length(type_id, len_m)
	var max_seg: float = float(ConduitKinds.type_meta(type_id).get("max_segment_m", 0.0))
	if max_seg > 0.01 and segs > 1:
		_readonly_field("Stock segments", "%d × %.0f m  (needs coupler)" % [segs, max_seg])
	if ConduitKinds.uses_culvert_kit(type_id):
		_build_culvert_hydraulics_section(conn, type_id)
	_build_site_waypoints_editor(conn)
	var style_btn := Button.new()
	style_btn.text = "Preview style…"
	style_btn.tooltip_text = "Live 3D preview — tune type, glow, thickness, routing; save presets"
	style_btn.focus_mode = Control.FOCUS_NONE
	style_btn.add_theme_color_override("font_color", C_PRIMARY)
	style_btn.pressed.connect(func() -> void:
		if _conduit_style_cb.is_valid():
			_conduit_style_cb.call(_item_id)
	)
	_form_vbox.add_child(style_btn)
	if routable:
		var route_btn := Button.new()
		route_btn.text = "Route in 3D"
		route_btn.add_theme_color_override("font_color", C_PRIMARY)
		route_btn.pressed.connect(func() -> void:
			if _conduit_route_cb.is_valid():
				_conduit_route_cb.call(_item_id)
		)
		_form_vbox.add_child(route_btn)
		var clear_btn := Button.new()
		clear_btn.text = "Clear 3D route / reset auto"
		clear_btn.pressed.connect(func() -> void:
			if _conduit_clear_cb.is_valid():
				_conduit_clear_cb.call(_item_id)
		)
		_form_vbox.add_child(clear_btn)


## Culvert stage-discharge authoring + live Q at the linked pond level.
func _build_culvert_hydraulics_section(conn: Dictionary, type_id: String) -> void:
	var hdr := Label.new()
	hdr.text = "Culvert hydrology"
	hdr.add_theme_color_override("font_color", C_PRIMARY)
	hdr.add_theme_font_size_override("font_size", 12)
	_form_vbox.add_child(hdr)
	var meta := ConduitKinds.type_meta(type_id)
	var size_in := float(conn.get("pipe_size_in", meta.get("default_pipe_size_in", 8.0)))
	_num_field("Pipe size (in)", size_in, "pipe_size_in", 4.0, 24.0, 1.0)
	_num_field("Invert in (m)", float(conn.get("invert_in_m", 0.0)), "invert_in_m",
			-500.0, 5000.0, 0.01)
	_num_field("Invert out (m)", float(conn.get("invert_out_m", 0.0)), "invert_out_m",
			-500.0, 5000.0, 0.01)
	_num_field("Manning n", float(conn.get("manning_n", meta.get("manning_n", 0.012))),
			"manning_n", 0.008, 0.03, 0.001)
	_text_field("Inlet pond tag", str(conn.get("inlet_pond_tag", "")), "inlet_pond_tag")
	var q_lps := float(conn.get("live_q_lps", 0.0))
	var head := float(conn.get("live_head_m", 0.0))
	var pe := float(conn.get("live_pe_kw", 0.0))
	var regime := str(conn.get("live_regime", "—"))
	_readonly_field("Live Q", "%.2f L/s  ·  head %.2f m  ·  %s" % [q_lps, head, regime])
	_readonly_field("Potential power", "%.3f kW (ρgQH)" % pe)


func _build_tri_state_opt(conn: Dictionary, key: String, label: String, tip: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	lbl.tooltip_text = tip
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.tooltip_text = tip
	opt.add_item("Follow global", 0)
	opt.add_item("On", 1)
	opt.add_item("Off", 2)
	var sel := 0
	if conn.has(key) and conn.get(key) != null:
		sel = 1 if bool(conn.get(key, true)) else 2
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		if idx == 0:
			_model.update_connection(_item_id, {key: null})
		else:
			_model.update_connection(_item_id, {key: (idx == 1)})
	)
	row.add_child(opt)
	_form_vbox.add_child(row)


func _build_site_waypoints_editor(conn: Dictionary) -> void:
	if _model == null:
		return
	var src := _model.get_item(str(conn.get("source_item_id", "")))
	var tgt := _model.get_item(str(conn.get("target_item_id", "")))
	if not GraphSiteLayout.has_site_coords(src) or not GraphSiteLayout.has_site_coords(tgt):
		return
	var wps: Array = conn.get("site_waypoints", []) as Array
	_readonly_field("Site bends", str(wps.size()))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var add_btn := Button.new()
	add_btn.text = "Add midpoint bend"
	add_btn.tooltip_text = "Insert a site-metre bend halfway between endpoints (for ortho pipe/duct runs)"
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.pressed.connect(func() -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var a := GraphSiteLayout.site_xz(src)
		var b := GraphSiteLayout.site_xz(tgt)
		var mid := (a + b) * 0.5
		# Offset slightly so the bend is visible / not colinear with a pure diagonal.
		var perp := Vector2(-(b.y - a.y), b.x - a.x)
		if perp.length_squared() > 1e-4:
			perp = perp.normalized() * minf(a.distance_to(b) * 0.15, 4.0)
		else:
			perp = Vector2(1.5, 0.0)
		var next: Array = (conn.get("site_waypoints", []) as Array).duplicate(true)
		next.append(ConduitKinds.site_waypoint_dict(mid + perp))
		_model.update_connection(_item_id, {"site_waypoints": next, "route_locked": false})
		inspect_connection(_model.get_connection(_item_id), _model)
	)
	row.add_child(add_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear bends"
	clear_btn.focus_mode = Control.FOCUS_NONE
	clear_btn.pressed.connect(func() -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		_model.update_connection(_item_id, {"site_waypoints": [], "route_locked": false})
		inspect_connection(_model.get_connection(_item_id), _model)
	)
	row.add_child(clear_btn)
	_form_vbox.add_child(row)


func _build_conduit_type_picker(conn: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Conduit override"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_item("(auto)", 0)
	var current: String = str(conn.get("conduit_type", ""))
	var sel := 0
	var types: Array = ConduitKinds.all_types()
	for ti: int in types.size():
		var tid: String = str(types[ti])
		opt.add_item(ConduitKinds.display_name(tid), ti + 1)
		if tid == current:
			sel = ti + 1
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var chosen := "" if idx == 0 else str(types[idx - 1])
		_model.update_connection(_item_id, {"conduit_type": chosen})
	)
	row.add_child(opt)
	_form_vbox.add_child(row)


func _clear_form() -> void:
	_pp_ext_rate_lbl = null
	_pp_ext_stick_lbl = null
	_pp_ext_cuts_lbl = null
	for child in _form_vbox.get_children():
		_form_vbox.remove_child(child)
		child.queue_free()


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

func _section(title: String) -> void:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(C_PANEL.r * 0.85, C_PANEL.g * 0.85, C_PANEL.b * 0.85, 1.0)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.border_color          = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.25)
	sb.content_margin_left   = 12.0
	sb.content_margin_right  = 12.0
	sb.content_margin_top    =  7.0
	sb.content_margin_bottom =  7.0
	pc.add_theme_stylebox_override("panel", sb)
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = title.to_upper()
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", 10)
	pc.add_child(lbl)
	_form_vbox.add_child(pc)


## Collapsible Advanced header. Returns true when the body should be built.
func _advanced_section(section_id: String, title: String, hint: String = "") -> bool:
	var expanded: bool = bool(_advanced_expanded.get(section_id, false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var btn := Button.new()
	btn.text = "%s  %s" % ["▼" if expanded else "▶", title]
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", C_TEXT_S)
	btn.add_theme_font_size_override("font_size", 10)
	if not hint.is_empty():
		btn.tooltip_text = hint
	btn.pressed.connect(func() -> void:
		_advanced_expanded[section_id] = not expanded
		_rebuild_current_item()
	)
	row.add_child(btn)
	_form_vbox.add_child(_wrap_margin(row, 8, 2))
	return expanded


func _hint_label(text: String) -> void:
	var hint := Label.new()
	hint.text = text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", C_TEXT_M)
	hint.add_theme_font_size_override("font_size", 10)
	_form_vbox.add_child(_wrap_margin(hint, 12, 4))


## Controllable loads / processors that can turn on/off. Habitats, imports,
## and catchments are not automation targets. Passive generators (watts=0,
## empty energy_source) like woodgas still support automations — the run
## switch is what matters, not AC draw.
func _item_supports_automation(item: Dictionary) -> bool:
	var itype := str(item.get("type", ""))
	if itype in ["appliance", "acload"]:
		return true
	if itype != "processor":
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var role := str(specs.get("role", ""))
	if role in ["habitat", "import", "export"]:
		return false
	return true


func _build_appearance_section(item: Dictionary) -> void:
	_section("Appearance")
	var itype := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var def_w := _GRAPH_CANVAS_SCRIPT.default_width(itype)
	var def_h := _GRAPH_CANVAS_SCRIPT.default_height(itype)
	var cur_w := float(item.get("width", def_w))
	var cur_h := float(item.get("height", def_h))
	_num_field("Width (px)", cur_w, "width", 64.0, 640.0, 2.0)
	_num_field("Height (px)", cur_h, "height", 48.0, 480.0, 2.0)
	_num_field("Canvas X", float(item.get("x", 0.0)), "x", -99999, 99999, 0.5)
	_num_field("Canvas Y", float(item.get("y", 0.0)), "y", -99999, 99999, 0.5)
	_section("Site Plan (meters)")
	if GraphSiteLayout.has_site_coords(item):
		_num_field("Site X (m east)", float(item.get("site_x_m", 0.0)), "site_x_m", -2000, 2000, 0.1)
		_num_field("Site Z (m south)", float(item.get("site_z_m", 0.0)), "site_z_m", -2000, 2000, 0.1)
		if item.has("elevation_m"):
			_readonly_field("Ground elev (m)", "%.2f" % float(item.get("elevation_m", 0.0)))
	else:
		_hint_label("No site position yet — use View ▾ → Site Plan and drag onto the SoI disc.")
	_num_field("Footprint W (m)", float(specs.get("footprint_w_m", 0.0)),
			"specs/footprint_w_m", 0.0, 100.0, 0.1)
	_num_field("Footprint D (m)", float(specs.get("footprint_d_m", 0.0)),
			"specs/footprint_d_m", 0.0, 100.0, 0.1)
	_num_field("Map icon scale", float(specs.get("map_display_scale", 1.0)),
			"specs/map_display_scale", 0.5, 8.0, 0.1)
	_hint_label("Footprint 0 = auto from model/type. Map icon scale only affects Site Plan chip size (not sim area).")

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var reset_btn := Button.new()
	reset_btn.text = "Reset size to type default"
	reset_btn.flat = true
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.add_theme_color_override("font_color", C_PRIMARY)
	reset_btn.add_theme_font_size_override("font_size", 10)
	reset_btn.tooltip_text = "Restore %s × %s for this node type" % [str(int(def_w)), str(int(def_h))]
	reset_btn.pressed.connect(func() -> void:
		if _model == null or _item_id.is_empty():
			return
		_model.update_item(_item_id, {"width": def_w, "height": def_h})
		_rebuild_current_item()
	)
	btn_row.add_child(reset_btn)
	_form_vbox.add_child(_wrap_margin(btn_row, 12, 4))

	_hint_label("Width and height control the node footprint on the graph. Ports stay at their relative positions.")

	# Card preview camera - only when a GLB is attached.
	var model_id := str(specs.get("model_id", ""))
	if not model_id.is_empty():
		_section("Card Preview")
		_hint_label("Snapshot of the attached 3D model shown on the node card. Default is head-on.")
		_num_field("Yaw (°)", float(specs.get("card_preview_yaw_deg", 0.0)),
			"specs/card_preview_yaw_deg", -180.0, 180.0, 5.0)
		_num_field("Pitch (°)", float(specs.get("card_preview_pitch_deg", 12.0)),
			"specs/card_preview_pitch_deg", -60.0, 80.0, 1.0)
		_num_field("Distance", float(specs.get("card_preview_dist_mult", 1.9)),
			"specs/card_preview_dist_mult", 0.6, 6.0, 0.1)

		var prev_row := HBoxContainer.new()
		prev_row.add_theme_constant_override("separation", 8)
		var head_btn := Button.new()
		head_btn.text = "Reset head-on"
		head_btn.flat = true
		head_btn.focus_mode = Control.FOCUS_NONE
		head_btn.add_theme_color_override("font_color", C_PRIMARY)
		head_btn.add_theme_font_size_override("font_size", 10)
		head_btn.pressed.connect(func() -> void:
			if _model == null or _item_id.is_empty():
				return
			var it := _model.get_item(_item_id)
			var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
			sp["card_preview_yaw_deg"] = 0.0
			sp["card_preview_pitch_deg"] = 12.0
			sp["card_preview_dist_mult"] = 1.9
			_model.update_item(_item_id, {"specs": sp})
			if _preview_refresh_cb.is_valid():
				_preview_refresh_cb.call(_item_id)
			_rebuild_current_item()
		)
		prev_row.add_child(head_btn)
		var refresh_btn := Button.new()
		refresh_btn.text = "Refresh preview"
		refresh_btn.flat = true
		refresh_btn.focus_mode = Control.FOCUS_NONE
		refresh_btn.add_theme_color_override("font_color", C_AMBER)
		refresh_btn.add_theme_font_size_override("font_size", 10)
		refresh_btn.tooltip_text = "Re-render the card snapshot from the GLB"
		refresh_btn.pressed.connect(func() -> void:
			if _preview_refresh_cb.is_valid() and not _item_id.is_empty():
				_preview_refresh_cb.call(_item_id)
		)
		prev_row.add_child(refresh_btn)
		_form_vbox.add_child(_wrap_margin(prev_row, 12, 4))


func _append_education_card(item: Dictionary) -> void:
	_append_education_card_dict(_EDU_CARDS_SCRIPT.card_for_item(item))


func _append_education_card_dict(card: Dictionary) -> void:
	if card.is_empty():
		return
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.10)
	sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	pc.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	pc.add_child(col)
	var t := Label.new()
	t.text = "📘  %s" % str(card.get("title", ""))
	t.add_theme_color_override("font_color", C_PRIMARY)
	t.add_theme_font_size_override("font_size", 11)
	col.add_child(t)
	var b := Label.new()
	b.text = str(card.get("body", ""))
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_color_override("font_color", C_TEXT_S)
	b.add_theme_font_size_override("font_size", 10)
	col.add_child(b)
	_form_vbox.add_child(pc)


func _text_field(label: String, value: String, path: String) -> void:
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	hbox.add_child(_key_label(label))

	var edit := LineEdit.new()
	edit.text                  = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.alignment             = HORIZONTAL_ALIGNMENT_RIGHT
	edit.add_theme_font_size_override("font_size", 11)
	edit.add_theme_color_override("font_color", C_TEXT)
	_style_edit(edit, false)

	edit.text_submitted.connect(_on_text_commit.bind(path))
	edit.focus_exited.connect(func(): _on_text_commit(edit.text, path))

	hbox.add_child(edit)
	_form_vbox.add_child(row)


## Turbine-kind dropdown over HydroSource.KINDS (+ a "custom" entry preserving an
## unknown saved kind so old free-text values are never lost), plus a muted
## head-band hint. `path` is "specs/kind" (type-"hydro" estimator) or
## "specs/turbine_kind" (pond turbines). Rebuilds the inspector on change so the
## hint + per-kind sections refresh.
func _turbine_kind_field(label: String, current: String, path: String) -> void:
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	hbox.add_child(_key_label(label))
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur := current.strip_edges().to_lower()
	var sel_idx := 0
	var i := 0
	for k in HydroSource.KINDS.keys():
		opt.add_item(str((HydroSource.KINDS[k] as Dictionary).get("display", k)), i)
		opt.set_item_metadata(i, k)
		if k == cur:
			sel_idx = i
		i += 1
	if not HydroSource.KINDS.has(cur) and not cur.is_empty():
		opt.add_item("Custom (%s)" % current, i)
		opt.set_item_metadata(i, current)
		sel_idx = i
	opt.select(sel_idx)
	opt.item_selected.connect(func(idx: int) -> void:
		_commit_field(path, str(opt.get_item_metadata(idx)))
		_rebuild_current_item()
	)
	hbox.add_child(opt)
	_form_vbox.add_child(row)
	var band: Array = HydroSource.kind_meta(current).get("head_band", []) as Array
	if band.size() == 2:
		_readonly_field("Best head", "%.0f–%.0f m" % [float(band[0]), float(band[1])])


func _num_field(label: String, value: float, path: String,
		min_v: float, max_v: float, step: float) -> void:
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	hbox.add_child(_key_label(label))

	var sb := SpinBox.new()
	sb.min_value              = min_v
	sb.max_value              = max_v
	sb.step                   = step
	sb.value                  = value
	sb.rounded                = false
	sb.custom_minimum_size    = Vector2(92.0, 0.0)
	sb.size_flags_horizontal  = Control.SIZE_SHRINK_END
	_style_edit(sb.get_line_edit(), true)
	sb.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT

	sb.value_changed.connect(_on_num_commit.bind(path))

	hbox.add_child(sb)
	_form_vbox.add_child(row)


func _readonly_field(label: String, value: String) -> void:
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	hbox.add_child(_key_label(label))

	var lbl := Label.new()
	lbl.text                  = value
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.clip_text = true
	hbox.add_child(lbl)
	_form_vbox.add_child(row)


func _row_container() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color              = Color(0.0, 0.0, 0.0, 0.0)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.border_color          = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.25)
	sb.content_margin_left   = 12.0
	sb.content_margin_right  =  8.0
	sb.content_margin_top    =  5.0
	sb.content_margin_bottom =  5.0
	pc.add_theme_stylebox_override("panel", sb)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_child(hbox)
	return pc


func _key_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text                  = text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	return lbl


func _style_edit(edit: LineEdit, small: bool) -> void:
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color              = Color(C_BG.r, C_BG.g, C_BG.b, 0.8)
	sb_n.border_color          = C_BORDER
	sb_n.set_border_width_all(1)
	sb_n.set_corner_radius_all(3)
	var mg := 3.0 if small else 4.0
	sb_n.content_margin_left   = mg
	sb_n.content_margin_right  = mg
	sb_n.content_margin_top    = 2.0
	sb_n.content_margin_bottom = 2.0

	var sb_f := sb_n.duplicate() as StyleBoxFlat
	sb_f.border_color = C_PRIMARY

	edit.add_theme_stylebox_override("normal",  sb_n)
	edit.add_theme_stylebox_override("focus",   sb_f)
	edit.add_theme_stylebox_override("read_only", sb_n)
	edit.add_theme_color_override("font_color",        C_TEXT)
	edit.add_theme_color_override("cursor_color",      C_PRIMARY)
	edit.add_theme_color_override("selection_color",   Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.35))
	edit.add_theme_font_size_override("font_size", 11)


# ---------------------------------------------------------------------------
# Commit callbacks
# ---------------------------------------------------------------------------

func _on_text_commit(text: String, path: String) -> void:
	if _updating_form:
		return
	_commit_field(path, text)


func _on_num_commit(value: float, path: String) -> void:
	if _updating_form:
		return
	_commit_field(path, value)


func _commit_field(path: String, value: Variant) -> void:
	if _model == null or _item_id.is_empty():
		return
	var parts := path.split("/")

	if parts.size() == 1:
		if _is_connection:
			_model.update_connection(_item_id, { parts[0]: value })
		else:
			_model.update_item(_item_id, { parts[0]: value })

	elif parts.size() == 2:
		if _is_connection:
			var conn := _model.get_connection(_item_id)
			if conn.is_empty():
				return
			var sub: Dictionary = (conn.get(parts[0], {}) as Dictionary).duplicate()
			sub[parts[1]] = value
			_model.update_connection(_item_id, { parts[0]: sub })
		else:
			var item := _model.get_item(_item_id)
			if item.is_empty():
				return
			var sub: Dictionary = (item.get(parts[0], {}) as Dictionary).duplicate()
			sub[parts[1]] = value
			_model.update_item(_item_id, { parts[0]: sub })
			# Propagate wattage changes back to the linked scene device so that
			# the power_consumers group reflects the user-edited value.
			if path == "specs/avg_watts" or path == "specs/max_watts":
				var sdev_path: String = str(sub.get("scene_device_path", ""))
				if not sdev_path.is_empty():
					var scene_node: Node = get_tree().root.get_node_or_null(NodePath(sdev_path))
					if scene_node != null and is_instance_valid(scene_node):
						var w := float(value)
						if scene_node.get("rated_power_watts") != null:
							scene_node.set("rated_power_watts", w)
						elif scene_node.get("wattage") != null:
							scene_node.set("wattage", w)
			if path == "specs/scene_device_path":
				var sdev: String = str(sub.get("scene_device_path", ""))
				if not sdev.is_empty():
					_model.update_item(_item_id, {"device_path": sdev})
			# Card preview camera / model changes → re-render snapshot.
			if path in ["specs/card_preview_yaw_deg", "specs/card_preview_pitch_deg",
					"specs/card_preview_dist_mult", "specs/model_id"]:
				if _preview_refresh_cb.is_valid():
					_preview_refresh_cb.call(_item_id)


# ---------------------------------------------------------------------------
# Load automation (HA-style → AutomationEngine + export)
# ---------------------------------------------------------------------------

func _toast(msg: String) -> void:
	if _toast_cb.is_valid():
		_toast_cb.call(msg)


func _get_automation_engine() -> Node:
	var tr := get_tree()
	if tr == null:
		return null
	return tr.root.get_node_or_null("AutomationEngine")


## Top-level automation section - sim/gameplay first. WHEN / IF / THEN mirrors
## Home Assistant so future LIVE export stays 1:1, but no HA entity is required.
func _build_load_automation_section(item: Dictionary) -> void:
	_migrate_legacy_automation_if_needed(item)

	var pre_specs: Dictionary = item.get("specs", {}) as Dictionary
	var rule_count: int = (pre_specs.get("graph_automations", []) as Array).size()
	_section("Automation (%d)" % rule_count if rule_count > 0 else "Automation")
	_hint_label("Rules run in the simulation. Pick Upstream/Downstream nodes for fill levels and on/off states. Link Home Assistant later under Advanced if you want a live twin.")

	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var autos: Array = (specs.get("graph_automations", []) as Array)

	# Sync the engine with whatever is on the spec so rules actually fire
	# after inspecting (and after loading a saved game).
	_sync_engine_from_specs(item, autos)

	if autos.is_empty():
		_hint_label("No automations yet. Pick a preset below, or build a custom WHEN → THEN rule.")
	else:
		for i in range(autos.size()):
			_build_auto_card(item, i)

	_build_auto_add_footer(item)

	# Optional HA export / entity mapping - secondary, not required for gameplay.
	if _advanced_section("auto_ha", "Advanced · Home Assistant link",
			"Optional - map this load to an HA entity and push rules for LIVE mode"):
		_hint_label("Only needed when mirroring this load to a real Home Assistant entity. Simulation automations work without it.")
		_build_ha_entity_row(item)


## HA entity_id field (per load). Applied to every scene-node action on export.
func _build_ha_entity_row(item: Dictionary) -> void:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var lbl := Label.new()
	lbl.text = "HA entity"
	lbl.custom_minimum_size = Vector2(70, 0)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)

	var ed := LineEdit.new()
	ed.placeholder_text = "light.path_lights  (optional)"
	ed.text = str(specs.get("ha_entity_id", ""))
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_edit(ed, false)
	var commit_fn := func() -> void:
		var it := _model.get_item(_item_id)
		if it.is_empty():
			return
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["ha_entity_id"] = ed.text.strip_edges()
		_model.update_item(_item_id, {"specs": sp})
		# Re-register so SceneNodeActions pick up the new entity_id.
		var autos2: Array = (sp.get("graph_automations", []) as Array)
		_sync_engine_from_specs(_model.get_item(_item_id), autos2)
	ed.text_submitted.connect(func(_t: String) -> void: commit_fn.call())
	ed.focus_exited.connect(commit_fn)
	row.add_child(ed)

	_form_vbox.add_child(_wrap_margin(row, 12, 4))


## One automation "card": header row (enabled toggle, alias summary, trigger
## summary, expand, delete) plus an expanded editor below. HA push lives in
## the Advanced submenu so the default card stays sim-focused.
func _build_auto_card(item: Dictionary, index: int) -> void:
	var autos: Array = _get_autos()
	if index < 0 or index >= autos.size():
		return
	var aut: Dictionary = autos[index] as Dictionary
	var auto_id: String = str(aut.get("id", ""))

	var card_pc := PanelContainer.new()
	var card_sb := StyleBoxFlat.new()
	card_sb.bg_color = Color(C_PANEL.r * 0.75, C_PANEL.g * 0.75, C_PANEL.b * 0.75, 1.0)
	card_sb.set_corner_radius_all(3)
	card_sb.set_border_width_all(1)
	card_sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
	card_sb.content_margin_left = 6.0
	card_sb.content_margin_right = 6.0
	card_sb.content_margin_top = 4.0
	card_sb.content_margin_bottom = 4.0
	card_pc.add_theme_stylebox_override("panel", card_sb)
	card_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_vbox := VBoxContainer.new()
	card_vbox.add_theme_constant_override("separation", 2)
	card_pc.add_child(card_vbox)

	# ---- Header row -----------------------------------------------------
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 4)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_vbox.add_child(hdr)

	var enabled_cb := CheckBox.new()
	enabled_cb.button_pressed = bool(aut.get("enabled", true))
	enabled_cb.focus_mode = Control.FOCUS_NONE
	enabled_cb.tooltip_text = "Enable / disable this automation"
	enabled_cb.toggled.connect(func(on: bool) -> void:
		_auto_patch_field(index, ["enabled"], on)
	)
	hdr.add_child(enabled_cb)

	var expanded: bool = bool(_auto_expanded.get(auto_id, false))
	var expand_btn := Button.new()
	expand_btn.text = "▼" if expanded else "▶"
	expand_btn.flat = true
	expand_btn.focus_mode = Control.FOCUS_NONE
	expand_btn.custom_minimum_size = Vector2(18, 0)
	expand_btn.add_theme_color_override("font_color", C_TEXT_S)
	expand_btn.pressed.connect(func() -> void:
		_auto_expanded[auto_id] = not expanded
		_rebuild_current_item()
	)
	hdr.add_child(expand_btn)

	var alias_lbl := Label.new()
	alias_lbl.text = str(aut.get("alias", "Automation"))
	alias_lbl.clip_text = true
	alias_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alias_lbl.add_theme_color_override("font_color", C_TEXT)
	alias_lbl.add_theme_font_size_override("font_size", 11)
	alias_lbl.tooltip_text = _summarize_auto(aut)
	hdr.add_child(alias_lbl)

	var del_btn := Button.new()
	del_btn.text = "×"
	del_btn.flat = true
	del_btn.focus_mode = Control.FOCUS_NONE
	del_btn.tooltip_text = "Delete automation"
	del_btn.add_theme_color_override("font_color", C_TEXT_S)
	del_btn.custom_minimum_size = Vector2(18, 0)
	del_btn.pressed.connect(_on_auto_delete.bind(index))
	hdr.add_child(del_btn)

	# ---- One-line summary (when collapsed) ------------------------------
	if not expanded:
		var sum_lbl := Label.new()
		sum_lbl.text = _summarize_auto(aut)
		sum_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sum_lbl.add_theme_color_override("font_color", C_TEXT_M)
		sum_lbl.add_theme_font_size_override("font_size", 10)
		card_vbox.add_child(sum_lbl)
	else:
		# ---- Expanded editor --------------------------------------------
		var alias_edit := LineEdit.new()
		alias_edit.placeholder_text = "Name"
		alias_edit.text = str(aut.get("alias", ""))
		alias_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_edit(alias_edit, false)
		var alias_commit := func() -> void:
			_auto_patch_field(index, ["alias"], alias_edit.text)
		alias_edit.text_submitted.connect(func(_t: String) -> void: alias_commit.call())
		alias_edit.focus_exited.connect(alias_commit)
		card_vbox.add_child(alias_edit)

		# WHEN (triggers)
		_build_auto_subsection(card_vbox, "WHEN  (triggers - any fires)", Color(0.55, 0.95, 0.55),
			_AUTO_KIND_TRIGGER, index, (aut.get("triggers", []) as Array))

		# IF (conditions)
		_build_auto_subsection(card_vbox, "IF  (conditions - all must match, optional)", C_AMBER,
			_AUTO_KIND_CONDITION, index, (aut.get("conditions", []) as Array))

		# THEN (actions)
		_build_auto_subsection(card_vbox, "THEN  (actions run in order)", C_PRIMARY,
			_AUTO_KIND_ACTION, index, (aut.get("actions", []) as Array))

		# Optional HA push tucked under the rule editor.
		var push_row := HBoxContainer.new()
		push_row.add_theme_constant_override("separation", 6)
		var push_btn := Button.new()
		push_btn.text = "Push to Home Assistant..."
		push_btn.flat = true
		push_btn.focus_mode = Control.FOCUS_NONE
		push_btn.tooltip_text = "Export this rule to HA (requires HA entity under Advanced)"
		push_btn.add_theme_color_override("font_color", C_TEXT_S)
		push_btn.add_theme_font_size_override("font_size", 10)
		push_btn.pressed.connect(_on_push_auto_pressed.bind(auto_id))
		push_row.add_child(push_btn)
		card_vbox.add_child(push_row)

		var id_lbl := Label.new()
		id_lbl.text = "ID: %s" % auto_id
		id_lbl.add_theme_color_override("font_color", C_TEXT_M)
		id_lbl.add_theme_font_size_override("font_size", 9)
		card_vbox.add_child(id_lbl)

	_form_vbox.add_child(_wrap_margin(card_pc, 12, 3))


const _AUTO_KIND_TRIGGER   := "trigger"
const _AUTO_KIND_CONDITION := "condition"
const _AUTO_KIND_ACTION    := "action"


## Render a WHEN/IF/THEN subsection with its header, + button, and rows.
func _build_auto_subsection(parent: VBoxContainer, title: String, accent: Color,
		kind: String, auto_index: int, items_arr: Array) -> void:
	var spacer1 := Control.new()
	spacer1.custom_minimum_size = Vector2(0, 4)
	parent.add_child(spacer1)

	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 4)
	var lbl := Label.new()
	lbl.text = title
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 9)
	hdr.add_child(lbl)
	var add_btn := Button.new()
	add_btn.text = "+"
	add_btn.flat = true
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.custom_minimum_size = Vector2(18, 0)
	add_btn.add_theme_color_override("font_color", accent)
	add_btn.tooltip_text = "Add %s" % kind
	add_btn.pressed.connect(_on_auto_add_sub.bind(auto_index, kind))
	hdr.add_child(add_btn)
	parent.add_child(hdr)

	if items_arr.is_empty() and kind != _AUTO_KIND_CONDITION:
		var empty_lbl := Label.new()
		empty_lbl.text = "(none)"
		empty_lbl.add_theme_color_override("font_color", C_TEXT_M)
		empty_lbl.add_theme_font_size_override("font_size", 9)
		parent.add_child(empty_lbl)
		return

	for idx in range(items_arr.size()):
		_build_auto_subitem_row(parent, kind, auto_index, idx, (items_arr[idx] as Dictionary))


## Render a single trigger / condition / action row with its type dropdown,
## kind-specific fields, and a delete button.
func _build_auto_subitem_row(parent: VBoxContainer, kind: String,
		auto_index: int, sub_index: int, sub: Dictionary) -> void:
	var row_pc := PanelContainer.new()
	var row_sb := StyleBoxFlat.new()
	row_sb.bg_color = Color(C_BG.r * 1.2, C_BG.g * 1.2, C_BG.b * 1.2, 1.0)
	row_sb.set_border_width(SIDE_LEFT, 2)
	match kind:
		_AUTO_KIND_TRIGGER:
			row_sb.border_color = Color(0.3, 0.9, 0.3, 0.8)
		_AUTO_KIND_CONDITION:
			row_sb.border_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.8)
		_:
			row_sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.8)
	row_sb.set_corner_radius_all(2)
	row_sb.content_margin_left = 5.0
	row_sb.content_margin_right = 4.0
	row_sb.content_margin_top = 3.0
	row_sb.content_margin_bottom = 3.0
	row_pc.add_theme_stylebox_override("panel", row_sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	row_pc.add_child(vbox)

	# Kind picker + delete
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	var kind_opt := OptionButton.new()
	kind_opt.focus_mode = Control.FOCUS_NONE
	kind_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind_opt.add_theme_font_size_override("font_size", 10)
	for k_def in _get_kind_options(kind):
		kind_opt.add_item(k_def.get("label", ""), k_def.get("id", 0))
		if str(k_def.get("key", "")) == str(sub.get("kind", "")):
			kind_opt.select(kind_opt.item_count - 1)
	kind_opt.item_selected.connect(func(sel_idx: int) -> void:
		var id_sel: int = kind_opt.get_item_id(sel_idx)
		var new_key := ""
		for k_def in _get_kind_options(kind):
			if int(k_def.get("id", -1)) == id_sel:
				new_key = str(k_def.get("key", ""))
				break
		_on_auto_sub_kind_changed(auto_index, kind, sub_index, new_key)
	)
	top.add_child(kind_opt)

	var rm := Button.new()
	rm.text = "×"
	rm.flat = true
	rm.focus_mode = Control.FOCUS_NONE
	rm.custom_minimum_size = Vector2(18, 0)
	rm.add_theme_color_override("font_color", C_TEXT_S)
	rm.pressed.connect(_on_auto_sub_remove.bind(auto_index, kind, sub_index))
	top.add_child(rm)
	vbox.add_child(top)

	# Kind-specific fields
	var path_base: Array = [_auto_kind_to_field(kind), sub_index]
	_build_auto_sub_fields(vbox, kind, auto_index, path_base, sub)

	parent.add_child(row_pc)


## Builds the kind-specific editable fields for a trigger / condition / action.
func _build_auto_sub_fields(parent: VBoxContainer, kind: String, auto_index: int,
		path_base: Array, sub: Dictionary) -> void:
	var sub_kind: String = str(sub.get("kind", ""))

	match kind:
		_AUTO_KIND_TRIGGER:
			match sub_kind:
				"time":
					_add_spin_row(parent, "At hour", float(sub.get("at_hour", 18.0)),
						0.0, 24.0, 0.25,
						func(v: float) -> void: _auto_patch_field(auto_index, path_base + ["at_hour"], v))
				"sun":
					_add_enum_row(parent, "Event", [
							{"label": "Sunset", "key": "sunset"},
							{"label": "Sunrise", "key": "sunrise"}
						], str(sub.get("event", "sunset")),
						func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["event"], v))
					_add_spin_row(parent, "Offset (h)", float(sub.get("offset_hours", 0.0)),
						-6.0, 6.0, 0.25,
						func(v: float) -> void: _auto_patch_field(auto_index, path_base + ["offset_hours"], v))
				"numeric":
					_add_enum_row(parent, "Signal", _numeric_signal_options(),
						_numeric_signal_key(str(sub.get("entity_id", "sensor.battery_level"))),
						func(v: String) -> void:
							if v == "__custom__":
								_auto_patch_field(auto_index, path_base + ["entity_id"], "sensor.")
							else:
								_auto_patch_field(auto_index, path_base + ["entity_id"], v)
							_rebuild_current_item())
					var eid := str(sub.get("entity_id", "sensor.battery_level"))
					if _numeric_signal_key(eid) == "__custom__":
						_add_text_row(parent, "Entity id", eid,
							func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["entity_id"], v))
					_add_optional_spin_row(parent, "Above", sub.get("above", null),
						0.0, 100.0, 1.0,
						func(v: Variant) -> void: _auto_patch_field(auto_index, path_base + ["above"], v))
					_add_optional_spin_row(parent, "Below", sub.get("below", null),
						0.0, 100.0, 1.0,
						func(v: Variant) -> void: _auto_patch_field(auto_index, path_base + ["below"], v))
				"state":
					_add_enum_row(parent, "Node / device", _state_entity_options(),
						_state_entity_key(str(sub.get("entity_id", ""))),
						func(v: String) -> void:
							var patch_eid := "" if v == "__custom__" else v
							var patch_to := str(sub.get("to_state", "on"))
							if v.begins_with("tank."):
								patch_to = "overflow"
							elif v.begins_with("node."):
								patch_to = "on"
							# One commit so we don't mid-rebuild between entity and to_state.
							var autos_s: Array = _get_autos()
							if auto_index >= 0 and auto_index < autos_s.size():
								var aut_s: Dictionary = (autos_s[auto_index] as Dictionary).duplicate(true)
								_apply_path(aut_s, path_base + ["entity_id"], patch_eid)
								_apply_path(aut_s, path_base + ["to_state"], patch_to)
								autos_s[auto_index] = aut_s
								_commit_autos(autos_s)
							_rebuild_current_item())
					var seid := str(sub.get("entity_id", ""))
					if _state_entity_key(seid) == "__custom__":
						_add_text_row(parent, "Device / entity", seid,
							func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["entity_id"], v))
					_add_enum_row(parent, "To state", _state_value_options(seid),
						str(sub.get("to_state", "on")),
						func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["to_state"], v))
		_AUTO_KIND_CONDITION:
			match sub_kind:
				"time":
					_add_spin_row(parent, "After hr", float(sub.get("after_hour", 0.0)),
						0.0, 24.0, 0.25,
						func(v: float) -> void: _auto_patch_field(auto_index, path_base + ["after_hour"], v))
					_add_spin_row(parent, "Before hr", float(sub.get("before_hour", 24.0)),
						0.0, 24.0, 0.25,
						func(v: float) -> void: _auto_patch_field(auto_index, path_base + ["before_hour"], v))
				"numeric":
					_add_enum_row(parent, "Signal", _numeric_signal_options(),
						_numeric_signal_key(str(sub.get("entity_id", "sensor.battery_level"))),
						func(v: String) -> void:
							if v == "__custom__":
								_auto_patch_field(auto_index, path_base + ["entity_id"], "sensor.")
							else:
								_auto_patch_field(auto_index, path_base + ["entity_id"], v)
							_rebuild_current_item())
					var eid2 := str(sub.get("entity_id", "sensor.battery_level"))
					if _numeric_signal_key(eid2) == "__custom__":
						_add_text_row(parent, "Entity id", eid2,
							func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["entity_id"], v))
					_add_optional_spin_row(parent, "Above", sub.get("above", null),
						0.0, 100.0, 1.0,
						func(v: Variant) -> void: _auto_patch_field(auto_index, path_base + ["above"], v))
					_add_optional_spin_row(parent, "Below", sub.get("below", null),
						0.0, 100.0, 1.0,
						func(v: Variant) -> void: _auto_patch_field(auto_index, path_base + ["below"], v))
				"sun":
					_add_enum_row(parent, "Sun", [
							{"label": "Above horizon", "key": "above_horizon"},
							{"label": "Below horizon", "key": "below_horizon"}
						], str(sub.get("state", "above_horizon")),
						func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["state"], v))
				"state":
					_add_enum_row(parent, "Node / device", _state_entity_options(),
						_state_entity_key(str(sub.get("entity_id", ""))),
						func(v: String) -> void:
							var patch_eid2 := "" if v == "__custom__" else v
							var autos_c: Array = _get_autos()
							if auto_index >= 0 and auto_index < autos_c.size():
								var aut_c: Dictionary = (autos_c[auto_index] as Dictionary).duplicate(true)
								_apply_path(aut_c, path_base + ["entity_id"], patch_eid2)
								if v.begins_with("tank."):
									_apply_path(aut_c, path_base + ["states"], ["overflow"])
								elif v.begins_with("node."):
									_apply_path(aut_c, path_base + ["states"], ["on"])
								autos_c[auto_index] = aut_c
								_commit_autos(autos_c)
							_rebuild_current_item())
					var seid2 := str(sub.get("entity_id", ""))
					if _state_entity_key(seid2) == "__custom__":
						_add_text_row(parent, "Device / entity", seid2,
							func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["entity_id"], v))
					var cur_states: Array = sub.get("states", []) as Array
					var joined := ""
					for s in cur_states:
						if joined != "":
							joined += ","
						joined += str(s)
					_add_enum_row(parent, "Match state", _state_value_options(seid2),
						str(cur_states[0]) if not cur_states.is_empty() else "on",
						func(v: String) -> void:
							_auto_patch_field(auto_index, path_base + ["states"], [v])
							_rebuild_current_item())
					_add_text_row(parent, "States (csv)", joined if not joined.is_empty() else "",
						func(v: String) -> void:
							var arr: Array = []
							for part in v.split(","):
								var t := part.strip_edges()
								if not t.is_empty():
									arr.append(t)
							_auto_patch_field(auto_index, path_base + ["states"], arr))
		_AUTO_KIND_ACTION:
			match sub_kind:
				"scene_node":
					_add_enum_row(parent, "Command", [
							{"label": "Turn ON", "key": "turn_on"},
							{"label": "Turn OFF", "key": "turn_off"},
							{"label": "Toggle", "key": "toggle"}
						], str(sub.get("command", "turn_on")),
						func(v: String) -> void: _auto_patch_field(auto_index, path_base + ["command"], v))
				"delay":
					_add_spin_row(parent, "Delay (s)", float(sub.get("delay_seconds", 5.0)),
						0.0, 3600.0, 1.0,
						func(v: float) -> void: _auto_patch_field(auto_index, path_base + ["delay_seconds"], v))


## Global sensors + upstream/downstream graph neighbors for numeric triggers.
func _numeric_signal_options() -> Array:
	var opts: Array = [
		{"label": "Battery SOC %", "key": "sensor.battery_level"},
		{"label": "Solar power (W)", "key": "sensor.solar_power"},
		{"label": "Load power (W)", "key": "sensor.load_power"},
	]
	for n: Dictionary in _iter_graph_neighbors():
		var nid: String = str(n.get("id", ""))
		var nname: String = str(n.get("name", nid))
		var dir: String = str(n.get("dir", ""))
		var ity: String = str(n.get("type", ""))
		if ity == "resource":
			opts.append({
				"label": "%s: %s fill %%" % [dir, nname],
				"key": "tank.%s.level" % nid,
			})
	opts.append({"label": "Custom (HA entity…)", "key": "__custom__"})
	return opts


## Upstream/downstream + custom entity for state triggers/conditions.
func _state_entity_options() -> Array:
	var opts: Array = []
	for n: Dictionary in _iter_graph_neighbors():
		var nid: String = str(n.get("id", ""))
		var nname: String = str(n.get("name", nid))
		var dir: String = str(n.get("dir", ""))
		var ity: String = str(n.get("type", ""))
		if ity == "resource":
			opts.append({
				"label": "%s: %s (tank)" % [dir, nname],
				"key": "tank.%s" % nid,
			})
		elif ity in ["processor", "appliance", "acload"]:
			opts.append({
				"label": "%s: %s" % [dir, nname],
				"key": "node.%s" % nid,
			})
	opts.append({"label": "Custom (HA / device id…)", "key": "__custom__"})
	return opts


## Suggested to-state / match-state values for a selected entity key.
func _state_value_options(entity_id: String) -> Array:
	if entity_id.begins_with("tank."):
		return [
			{"label": "OK (not overflowing)", "key": "ok"},
			{"label": "Overflowing", "key": "overflow"},
		]
	if entity_id.begins_with("node."):
		return [
			{"label": "On", "key": "on"},
			{"label": "Off", "key": "off"},
			{"label": "Starved", "key": "starved"},
			{"label": "Blocked", "key": "blocked"},
		]
	return [
		{"label": "On", "key": "on"},
		{"label": "Off", "key": "off"},
	]


## Immediate upstream/downstream graph neighbors of the inspected item.
## Returns [{id, name, type, dir}] where dir is "Upstream" or "Downstream".
func _iter_graph_neighbors() -> Array:
	var out: Array = []
	if _model == null or _item_id.is_empty():
		return out
	var seen: Dictionary = {}
	for conn: Dictionary in _model.connections:
		var src := str(conn.get("source_item_id", ""))
		var tgt := str(conn.get("target_item_id", ""))
		var other := ""
		var dir := ""
		if src == _item_id:
			other = tgt
			dir = "Downstream"
		elif tgt == _item_id:
			other = src
			dir = "Upstream"
		else:
			continue
		if other.is_empty() or seen.has(other):
			continue
		seen[other] = true
		var it := _model.get_item(other)
		if it.is_empty():
			continue
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		out.append({
			"id": other,
			"name": str(specs.get("name", other)),
			"type": str(it.get("type", "")),
			"dir": dir,
		})
	return out


## Map a stored entity_id onto the Signal picker key (or __custom__).
func _numeric_signal_key(entity_id: String) -> String:
	for o: Dictionary in _numeric_signal_options():
		if str(o.get("key", "")) == entity_id:
			return entity_id
	if entity_id in ["sensor.battery_level", "sensor.solar_power", "sensor.load_power"]:
		return entity_id
	return "__custom__"


func _state_entity_key(entity_id: String) -> String:
	if entity_id.is_empty():
		return "__custom__"
	for o: Dictionary in _state_entity_options():
		if str(o.get("key", "")) == entity_id:
			return entity_id
	return "__custom__"


## Available "kinds" (trigger type, condition type, action type) for the dropdown.
func _get_kind_options(kind: String) -> Array:
	match kind:
		_AUTO_KIND_TRIGGER:
			return [
				{"id": 0, "key": "time",    "label": "Time of day"},
				{"id": 1, "key": "sun",     "label": "Sunrise / sunset"},
				{"id": 2, "key": "numeric", "label": "Fill level / power signal"},
				{"id": 3, "key": "state",   "label": "Graph / device state"},
			]
		_AUTO_KIND_CONDITION:
			return [
				{"id": 0, "key": "time",    "label": "Time window"},
				{"id": 1, "key": "sun",     "label": "Sun above/below horizon"},
				{"id": 2, "key": "numeric", "label": "Fill level / power signal"},
				{"id": 3, "key": "state",   "label": "Graph / device state"},
			]
		_:
			return [
				{"id": 0, "key": "scene_node", "label": "Turn this load on/off/toggle"},
				{"id": 1, "key": "delay",      "label": "Delay (seconds)"},
			]


func _auto_kind_to_field(kind: String) -> String:
	match kind:
		_AUTO_KIND_TRIGGER:
			return "triggers"
		_AUTO_KIND_CONDITION:
			return "conditions"
		_:
			return "actions"


# ---------------------------------------------------------------------------
# Small editable row helpers (used by subitem field builders)
# ---------------------------------------------------------------------------

func _small_label(txt: String) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.custom_minimum_size = Vector2(68, 0)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 10)
	return lbl


func _add_spin_row(parent: VBoxContainer, label: String, value: float,
		min_v: float, max_v: float, step: float, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(_small_label(label))
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = value
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_edit(sb.get_line_edit(), true)
	sb.value_changed.connect(func(v: float) -> void: commit.call(v))
	row.add_child(sb)
	parent.add_child(row)


## Spin row where the value is optional (null = unbounded). Shown as a checkbox
## next to the spin; checking it enables the bound, unchecking clears it.
func _add_optional_spin_row(parent: VBoxContainer, label: String, current: Variant,
		min_v: float, max_v: float, step: float, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(_small_label(label))

	var active: bool = current != null and not (current is String)
	var cb := CheckBox.new()
	cb.button_pressed = active
	cb.focus_mode = Control.FOCUS_NONE
	row.add_child(cb)

	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = float(current) if active else 50.0
	sb.editable = active
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_edit(sb.get_line_edit(), true)
	row.add_child(sb)

	cb.toggled.connect(func(on: bool) -> void:
		sb.editable = on
		if on:
			commit.call(sb.value)
		else:
			commit.call(null)
	)
	sb.value_changed.connect(func(v: float) -> void:
		if cb.button_pressed:
			commit.call(v)
	)
	parent.add_child(row)


func _add_text_row(parent: VBoxContainer, label: String, value: String, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(_small_label(label))
	var ed := LineEdit.new()
	ed.text = value
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_edit(ed, false)
	var do_commit := func() -> void: commit.call(ed.text)
	ed.text_submitted.connect(func(_t: String) -> void: do_commit.call())
	ed.focus_exited.connect(do_commit)
	row.add_child(ed)
	parent.add_child(row)


func _add_enum_row(parent: VBoxContainer, label: String, options: Array,
		current_key: String, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(_small_label(label))
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 10)
	var keys: Array = []
	for i in range(options.size()):
		var o: Dictionary = options[i] as Dictionary
		opt.add_item(str(o.get("label", "")), i)
		keys.append(str(o.get("key", "")))
		if str(o.get("key", "")) == current_key:
			opt.select(i)
	opt.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and idx < keys.size():
			commit.call(keys[idx])
	)
	row.add_child(opt)
	parent.add_child(row)


# ---------------------------------------------------------------------------
# Add-automation footer: standard presets + custom
# ---------------------------------------------------------------------------

## Popup menu of pre-defined "standard" automation templates.
const _TEMPLATES := [
	{
		"label": "☀ Sunset ON  /  Sunrise OFF  (lights)",
		"specs": [
			{"alias": "On at sunset",
			 "triggers":   [{"kind": "sun", "event": "sunset",  "offset_hours": 0.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_on"}]},
			{"alias": "Off at sunrise",
			 "triggers":   [{"kind": "sun", "event": "sunrise", "offset_hours": 0.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_off"}]},
		],
	},
	{
		"label": "☀ On at sunset",
		"specs": [
			{"alias": "On at sunset",
			 "triggers":   [{"kind": "sun", "event": "sunset", "offset_hours": 0.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_on"}]},
		],
	},
	{
		"label": "☾ Off at sunrise",
		"specs": [
			{"alias": "Off at sunrise",
			 "triggers":   [{"kind": "sun", "event": "sunrise", "offset_hours": 0.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_off"}]},
		],
	},
	{
		"label": "☀ Solar dump load  (ON >99% SOC / OFF <95%)",
		"specs": [
			{"alias": "Solar dump: on above 99% battery",
			 "triggers":   [{"kind": "numeric", "entity_id": "sensor.battery_level", "above": 99.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_on"}]},
			{"alias": "Solar dump: off below 95% battery",
			 "triggers":   [{"kind": "numeric", "entity_id": "sensor.battery_level", "below": 95.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_off"}]},
		],
	},
	{
		"label": "🔋 On above 80% SOC  /  Off below 20%",
		"specs": [
			{"alias": "On above 80% battery",
			 "triggers":   [{"kind": "numeric", "entity_id": "sensor.battery_level", "above": 80.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_on"}]},
			{"alias": "Off below 20% battery",
			 "triggers":   [{"kind": "numeric", "entity_id": "sensor.battery_level", "below": 20.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_off"}]},
		],
	},
	{
		"label": "🔋↓ Load shedding - off below 20% SOC",
		"specs": [
			{"alias": "Off below 20% battery",
			 "triggers":   [{"kind": "numeric", "entity_id": "sensor.battery_level", "below": 20.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_off"}]},
		],
	},
	{
		"label": "⏰ On at 18:00  /  Off at 23:00",
		"specs": [
			{"alias": "On at 18:00",
			 "triggers":   [{"kind": "time", "at_hour": 18.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_on"}]},
			{"alias": "Off at 23:00",
			 "triggers":   [{"kind": "time", "at_hour": 23.0}],
			 "conditions": [],
			 "actions":    [{"kind": "scene_node", "command": "turn_off"}]},
		],
	},
]


func _build_auto_add_footer(item: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var std_btn := MenuButton.new()
	std_btn.text = "+ Preset..."
	std_btn.flat = true
	std_btn.focus_mode = Control.FOCUS_NONE
	std_btn.add_theme_color_override("font_color", C_PRIMARY)
	std_btn.add_theme_font_size_override("font_size", 11)
	std_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var popup := std_btn.get_popup()
	popup.clear()
	for i in range(_TEMPLATES.size()):
		var tpl: Dictionary = _TEMPLATES[i] as Dictionary
		popup.add_item(str(tpl.get("label", "Template")), i)
	popup.id_pressed.connect(_on_template_picked)
	row.add_child(std_btn)

	var custom_btn := Button.new()
	custom_btn.text = "+ Custom rule"
	custom_btn.flat = true
	custom_btn.focus_mode = Control.FOCUS_NONE
	custom_btn.add_theme_color_override("font_color", C_PRIMARY)
	custom_btn.add_theme_font_size_override("font_size", 11)
	custom_btn.pressed.connect(_on_add_custom_automation)
	row.add_child(custom_btn)

	_form_vbox.add_child(_wrap_margin(row, 12, 8))


func _wrap_margin(ctrl: Control, h: int, v: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left", h)
	mc.add_theme_constant_override("margin_right", h)
	mc.add_theme_constant_override("margin_top", v)
	mc.add_theme_constant_override("margin_bottom", v)
	mc.add_child(ctrl)
	return mc


# ---------------------------------------------------------------------------
# Automation mutation callbacks
# ---------------------------------------------------------------------------

func _on_template_picked(tpl_idx: int) -> void:
	if tpl_idx < 0 or tpl_idx >= _TEMPLATES.size():
		return
	var tpl: Dictionary = _TEMPLATES[tpl_idx] as Dictionary
	var autos: Array = _get_autos()
	for s in (tpl.get("specs", []) as Array):
		var spec: Dictionary = (s as Dictionary).duplicate(true)
		spec["id"] = _generate_auto_id()
		spec["enabled"] = true
		autos.append(spec)
		_auto_expanded[spec["id"]] = false
	_commit_autos(autos)
	_rebuild_current_item()
	_toast("Added %d automation(s)" % (tpl.get("specs", []) as Array).size())


func _on_add_custom_automation() -> void:
	var autos: Array = _get_autos()
	var new_id := _generate_auto_id()
	var spec := {
		"id":         new_id,
		"alias":      "New automation",
		"enabled":    true,
		"triggers":   [{"kind": "time", "at_hour": 18.0}],
		"conditions": [],
		"actions":    [{"kind": "scene_node", "command": "turn_on"}],
	}
	autos.append(spec)
	_auto_expanded[new_id] = true
	_commit_autos(autos)
	_rebuild_current_item()


func _on_auto_delete(index: int) -> void:
	var autos: Array = _get_autos()
	if index < 0 or index >= autos.size():
		return
	var removed: Dictionary = autos[index] as Dictionary
	autos.remove_at(index)
	var removed_id := str(removed.get("id", ""))
	if not removed_id.is_empty():
		var eng := _get_automation_engine()
		if eng != null and eng.has_method("unregister_automation"):
			eng.call("unregister_automation", removed_id)
		_auto_expanded.erase(removed_id)
	_commit_autos(autos)
	_rebuild_current_item()


func _on_auto_add_sub(auto_index: int, kind: String) -> void:
	var autos: Array = _get_autos()
	if auto_index < 0 or auto_index >= autos.size():
		return
	var aut: Dictionary = (autos[auto_index] as Dictionary).duplicate(true)
	var field := _auto_kind_to_field(kind)
	var arr: Array = (aut.get(field, []) as Array).duplicate(true)
	arr.append(_default_sub_spec(kind))
	aut[field] = arr
	autos[auto_index] = aut
	_commit_autos(autos)
	_rebuild_current_item()


func _on_auto_sub_remove(auto_index: int, kind: String, sub_index: int) -> void:
	var autos: Array = _get_autos()
	if auto_index < 0 or auto_index >= autos.size():
		return
	var aut: Dictionary = (autos[auto_index] as Dictionary).duplicate(true)
	var field := _auto_kind_to_field(kind)
	var arr: Array = (aut.get(field, []) as Array).duplicate(true)
	if sub_index < 0 or sub_index >= arr.size():
		return
	arr.remove_at(sub_index)
	aut[field] = arr
	autos[auto_index] = aut
	_commit_autos(autos)
	_rebuild_current_item()


func _on_auto_sub_kind_changed(auto_index: int, kind: String, sub_index: int, new_kind: String) -> void:
	var autos: Array = _get_autos()
	if auto_index < 0 or auto_index >= autos.size():
		return
	var aut: Dictionary = (autos[auto_index] as Dictionary).duplicate(true)
	var field := _auto_kind_to_field(kind)
	var arr: Array = (aut.get(field, []) as Array).duplicate(true)
	if sub_index < 0 or sub_index >= arr.size():
		return
	var fresh := _default_sub_spec(kind)
	fresh["kind"] = new_kind
	# Preserve a few common fields where it makes sense
	var old: Dictionary = arr[sub_index] as Dictionary
	if old.has("alias"):
		fresh["alias"] = old["alias"]
	arr[sub_index] = _reset_sub_for_kind(fresh, new_kind)
	aut[field] = arr
	autos[auto_index] = aut
	_commit_autos(autos)
	_rebuild_current_item()


func _on_push_auto_pressed(auto_id: String) -> void:
	var eng := _get_automation_engine()
	if eng == null or not eng.has_method("get_automation"):
		_toast("AutomationEngine not found")
		return
	var automation: Automation = eng.get_automation(auto_id) as Automation
	if automation == null:
		_toast("Automation not registered yet")
		return
	var pusher: RefCounted = _HA_PUSHER.new() as RefCounted
	var res: Dictionary = pusher.call("push", automation, get_tree()) as Dictionary
	_toast(str(res.get("message", "Done")))


## Generic "patch one field" - path is an array like ["alias"] or
## ["triggers", 0, "at_hour"]. Commits to the model and re-registers the
## automation so the engine sees the change immediately.
func _auto_patch_field(auto_index: int, path: Array, value: Variant) -> void:
	var autos: Array = _get_autos()
	if auto_index < 0 or auto_index >= autos.size():
		return
	var aut: Dictionary = (autos[auto_index] as Dictionary).duplicate(true)
	_apply_path(aut, path, value)
	autos[auto_index] = aut
	_commit_autos(autos)


## Walks `target` along `path` (keys or ints) and writes `value` at the leaf.
## Intermediate arrays/dicts are duplicated as we descend so we don't mutate
## shared references.
func _apply_path(target: Variant, path: Array, value: Variant) -> void:
	if path.is_empty():
		return
	var cur: Variant = target
	for i in range(path.size() - 1):
		var key: Variant = path[i]
		if cur is Dictionary:
			var d := cur as Dictionary
			var nxt: Variant = d.get(key)
			if nxt is Dictionary:
				nxt = (nxt as Dictionary).duplicate(true)
			elif nxt is Array:
				nxt = (nxt as Array).duplicate(true)
			d[key] = nxt
			cur = nxt
		elif cur is Array:
			var a := cur as Array
			var idx := int(key)
			if idx < 0 or idx >= a.size():
				return
			var nxt2: Variant = a[idx]
			if nxt2 is Dictionary:
				nxt2 = (nxt2 as Dictionary).duplicate(true)
			elif nxt2 is Array:
				nxt2 = (nxt2 as Array).duplicate(true)
			a[idx] = nxt2
			cur = nxt2
	var leaf: Variant = path[path.size() - 1]
	if cur is Dictionary:
		if value == null:
			(cur as Dictionary).erase(leaf)
		else:
			(cur as Dictionary)[leaf] = value
	elif cur is Array:
		(cur as Array)[int(leaf)] = value


# ---------------------------------------------------------------------------
# Spec <-> Automation resource conversion
# ---------------------------------------------------------------------------

## Create a working copy of the current item's automations array. Callers
## should pass the result back to `_commit_autos` when done mutating.
func _get_autos() -> Array:
	var it := _model.get_item(_item_id)
	if it.is_empty():
		return []
	var specs: Dictionary = it.get("specs", {}) as Dictionary
	return (specs.get("graph_automations", []) as Array).duplicate(true)


## Persist `autos` to the model's specs and refresh engine registrations.
func _commit_autos(autos: Array) -> void:
	var it := _model.get_item(_item_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	specs["graph_automations"] = autos
	_model.update_item(_item_id, {"specs": specs})
	_sync_engine_from_specs(_model.get_item(_item_id), autos)


func _generate_auto_id() -> String:
	_auto_id_counter += 1
	var base := str(_item_id).replace(" ", "_")
	return "graph_autom_%s_%d_%d" % [base, Time.get_ticks_msec(), _auto_id_counter]


## One-time conversion from the legacy single-automation fields
## (graph_automation_id/alias + engine-stored Automation) to the new
## graph_automations array on the spec. Only writes to the model when there's
## actually something to migrate (avoids spurious undo entries on first-time
## inspection of loads that never had an automation).
func _migrate_legacy_automation_if_needed(item: Dictionary) -> void:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if specs.has("graph_automations"):
		return
	var legacy_id: String = str(specs.get("graph_automation_id", ""))
	var has_legacy: bool = not legacy_id.is_empty() \
		or specs.has("automation_alias")
	if not has_legacy:
		# Nothing to migrate - don't touch the model.
		return
	var autos: Array = []
	if not legacy_id.is_empty():
		var eng := _get_automation_engine()
		if eng != null and eng.has_method("get_automation"):
			var aut: Automation = eng.get_automation(legacy_id) as Automation
			if aut != null:
				var spec := _automation_to_spec(aut)
				spec["id"] = legacy_id
				autos.append(spec)
	var new_specs: Dictionary = specs.duplicate(true)
	new_specs["graph_automations"] = autos
	new_specs.erase("graph_automation_id")
	new_specs.erase("automation_alias")
	_model.update_item(_item_id, {"specs": new_specs})


## Re-register all automations on this load in the engine, using the current
## HA entity id and device path from the item. Call after any spec change.
func _sync_engine_from_specs(item: Dictionary, autos: Array) -> void:
	var eng := _get_automation_engine()
	if eng == null or not eng.has_method("register_automation"):
		return
	var device_path: String = item.get("device_path", "") as String
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var ha_entity: String = str(specs.get("ha_entity_id", "")).strip_edges()
	for s in autos:
		var spec: Dictionary = s as Dictionary
		var aid: String = str(spec.get("id", ""))
		if aid.is_empty():
			continue
		if eng.has_method("unregister_automation"):
			eng.call("unregister_automation", aid)
		var aut := _spec_to_automation(spec, aid, device_path, ha_entity)
		if aut != null:
			eng.call("register_automation", aut)


## Public helper so SystemGraphView can re-register all automations on a
## freshly deserialized model (e.g. after loading a save). Walks all items
## and re-syncs any with a graph_automations array.
func sync_all_load_automations(mdl: GraphModel) -> void:
	if mdl == null:
		return
	for it: Dictionary in mdl.items:
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var autos: Array = specs.get("graph_automations", []) as Array
		if autos.is_empty():
			continue
		_sync_engine_from_specs(it, autos)


## Public helper so SystemGraphView can unregister all automations belonging
## to a graph item BEFORE removing it from the model. Prevents stale
## automation entries in the engine from firing after the item is gone.
func unregister_item_automations(item: Dictionary) -> void:
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var autos: Array = specs.get("graph_automations", []) as Array
	if autos.is_empty():
		return
	var eng := _get_automation_engine()
	if eng == null or not eng.has_method("unregister_automation"):
		return
	for s: Variant in autos:
		var aid: String = str((s as Dictionary).get("id", ""))
		if not aid.is_empty():
			eng.call("unregister_automation", aid)


func _spec_to_automation(spec: Dictionary, auto_id: String,
		device_path: String, ha_entity_id: String) -> Automation:
	var aut := Automation.new()
	aut.automation_id = auto_id
	aut.alias = str(spec.get("alias", "Automation"))
	aut.enabled = bool(spec.get("enabled", true))
	aut.mode = "single"
	for ts in (spec.get("triggers", []) as Array):
		var trg := _spec_to_trigger(ts as Dictionary)
		if trg != null:
			aut.triggers.append(trg)
	for cs in (spec.get("conditions", []) as Array):
		var cnd := _spec_to_condition(cs as Dictionary)
		if cnd != null:
			aut.conditions.append(cnd)
	for ac in (spec.get("actions", []) as Array):
		var act := _spec_to_action(ac as Dictionary, device_path, ha_entity_id)
		if act != null:
			aut.actions.append(act)
	return aut


func _spec_to_trigger(s: Dictionary) -> AutomationTrigger:
	match str(s.get("kind", "time")):
		"time":
			var tt := TimeTrigger.new()
			tt.at_hour = float(s.get("at_hour", 12.0))
			return tt
		"sun":
			var sr := SunTrigger.new()
			sr.event = (SunTrigger.SunEvent.SUNRISE
				if str(s.get("event", "sunset")) == "sunrise"
				else SunTrigger.SunEvent.SUNSET)
			sr.offset_hours = float(s.get("offset_hours", 0.0))
			return sr
		"numeric":
			var nt := NumericStateTrigger.new()
			nt.entity_id = str(s.get("entity_id", "sensor.battery_level"))
			nt.above = float(s.get("above", -INF)) if s.has("above") and s.get("above") != null else -INF
			nt.below = float(s.get("below", INF))  if s.has("below") and s.get("below") != null else  INF
			return nt
		"state":
			var st := StateTrigger.new()
			st.entity_id  = str(s.get("entity_id", ""))
			st.to_state   = str(s.get("to_state", ""))
			st.from_state = str(s.get("from_state", ""))
			return st
	return null


func _spec_to_condition(s: Dictionary) -> AutomationCondition:
	match str(s.get("kind", "time")):
		"time":
			var tc := TimeCondition.new()
			tc.after_hour  = float(s.get("after_hour", 0.0))
			tc.before_hour = float(s.get("before_hour", 24.0))
			return tc
		"numeric":
			var nc := NumericStateCondition.new()
			nc.entity_id = str(s.get("entity_id", "sensor.battery_level"))
			nc.above = float(s.get("above", -INF)) if s.has("above") and s.get("above") != null else -INF
			nc.below = float(s.get("below", INF))  if s.has("below") and s.get("below") != null else  INF
			return nc
		"sun":
			var sc := SunCondition.new()
			sc.sun_state = (SunCondition.SunState.ABOVE_HORIZON
				if str(s.get("state", "above_horizon")) == "above_horizon"
				else SunCondition.SunState.BELOW_HORIZON)
			return sc
		"state":
			var st := StateCondition.new()
			st.entity_id = str(s.get("entity_id", ""))
			var states: Array = s.get("states", []) as Array
			var states_s: Array[String] = []
			for ss in states:
				states_s.append(str(ss))
			st.states = states_s
			return st
	return null


func _spec_to_action(s: Dictionary, device_path: String, ha_entity_id: String) -> AutomationAction:
	match str(s.get("kind", "scene_node")):
		"scene_node":
			var sn := SceneNodeAction.new()
			sn.node_path = device_path
			sn.ha_entity_id = ha_entity_id
			match str(s.get("command", "turn_on")):
				"turn_off":
					sn.command = SceneNodeAction.NodeCommand.TURN_OFF
				"toggle":
					sn.command = SceneNodeAction.NodeCommand.TOGGLE
				_:
					sn.command = SceneNodeAction.NodeCommand.TURN_ON
			return sn
		"delay":
			var d := DelayAction.new()
			d.delay_seconds = float(s.get("delay_seconds", 5.0))
			return d
	return null


func _automation_to_spec(aut: Automation) -> Dictionary:
	var trigs: Array = []
	for t in aut.triggers:
		trigs.append(_trigger_to_spec(t))
	var conds: Array = []
	for c in aut.conditions:
		conds.append(_condition_to_spec(c))
	var acts: Array = []
	for a in aut.actions:
		acts.append(_action_to_spec(a))
	return {
		"id":         aut.automation_id,
		"alias":      aut.alias,
		"enabled":    aut.enabled,
		"triggers":   trigs,
		"conditions": conds,
		"actions":    acts,
	}


func _trigger_to_spec(t: AutomationTrigger) -> Dictionary:
	if t is TimeTrigger:
		return {"kind": "time", "at_hour": (t as TimeTrigger).at_hour}
	if t is SunTrigger:
		var st := t as SunTrigger
		return {"kind": "sun",
			"event": ("sunrise" if st.event == SunTrigger.SunEvent.SUNRISE else "sunset"),
			"offset_hours": st.offset_hours}
	if t is NumericStateTrigger:
		var nt := t as NumericStateTrigger
		var d: Dictionary = {"kind": "numeric", "entity_id": nt.entity_id}
		if nt.above > -INF:
			d["above"] = nt.above
		if nt.below < INF:
			d["below"] = nt.below
		return d
	if t is StateTrigger:
		var sr := t as StateTrigger
		return {"kind": "state", "entity_id": sr.entity_id,
			"to_state": sr.to_state, "from_state": sr.from_state}
	return {"kind": "time", "at_hour": 12.0}


func _condition_to_spec(c: AutomationCondition) -> Dictionary:
	if c is TimeCondition:
		var tc := c as TimeCondition
		return {"kind": "time", "after_hour": tc.after_hour, "before_hour": tc.before_hour}
	if c is NumericStateCondition:
		var nc := c as NumericStateCondition
		var d: Dictionary = {"kind": "numeric", "entity_id": nc.entity_id}
		if nc.above > -INF:
			d["above"] = nc.above
		if nc.below < INF:
			d["below"] = nc.below
		return d
	if c is SunCondition:
		var sc := c as SunCondition
		return {"kind": "sun",
			"state": ("above_horizon" if sc.sun_state == SunCondition.SunState.ABOVE_HORIZON else "below_horizon")}
	if c is StateCondition:
		var stc := c as StateCondition
		var states_out: Array = []
		for s in stc.states:
			states_out.append(s)
		return {"kind": "state", "entity_id": stc.entity_id, "states": states_out}
	return {"kind": "time", "after_hour": 0.0, "before_hour": 24.0}


func _action_to_spec(a: AutomationAction) -> Dictionary:
	if a is SceneNodeAction:
		var sn := a as SceneNodeAction
		var cmd := "turn_on"
		match sn.command:
			SceneNodeAction.NodeCommand.TURN_OFF:
				cmd = "turn_off"
			SceneNodeAction.NodeCommand.TOGGLE:
				cmd = "toggle"
		return {"kind": "scene_node", "command": cmd}
	if a is DelayAction:
		return {"kind": "delay", "delay_seconds": (a as DelayAction).delay_seconds}
	return {"kind": "scene_node", "command": "turn_on"}


## Default fresh spec for a new trigger / condition / action subitem.
func _default_sub_spec(kind: String) -> Dictionary:
	match kind:
		_AUTO_KIND_TRIGGER:
			return {"kind": "time", "at_hour": 18.0}
		_AUTO_KIND_CONDITION:
			return {"kind": "time", "after_hour": 0.0, "before_hour": 24.0}
		_:
			return {"kind": "scene_node", "command": "turn_on"}


## When the user changes a subitem's kind via the dropdown, rebuild its spec
## with sane defaults for the new kind (but preserve any alias it had).
func _reset_sub_for_kind(sub: Dictionary, new_kind: String) -> Dictionary:
	var preserved := {}
	if sub.has("alias"):
		preserved["alias"] = sub["alias"]
	var fresh: Dictionary
	match new_kind:
		"time":
			fresh = {"kind": "time", "at_hour": 18.0, "after_hour": 0.0, "before_hour": 24.0}
		"sun":
			fresh = {"kind": "sun", "event": "sunset", "offset_hours": 0.0, "state": "above_horizon"}
		"numeric":
			fresh = {"kind": "numeric", "entity_id": "sensor.battery_level"}
		"state":
			fresh = {"kind": "state", "entity_id": "", "to_state": "on", "states": []}
		"scene_node":
			fresh = {"kind": "scene_node", "command": "turn_on"}
		"delay":
			fresh = {"kind": "delay", "delay_seconds": 5.0}
		_:
			fresh = {"kind": new_kind}
	for k: Variant in preserved.keys():
		fresh[k] = preserved[k]
	return fresh


## Short one-line summary of an automation (used as a row subtitle + tooltip).
func _summarize_auto(aut: Dictionary) -> String:
	var trigs: Array = aut.get("triggers", []) as Array
	var acts:  Array = aut.get("actions",  []) as Array
	var conds: Array = aut.get("conditions", []) as Array
	var when_s := ""
	for t in trigs:
		var td: Dictionary = t as Dictionary
		var piece := _summarize_trigger(td)
		if not piece.is_empty():
			when_s += ("  or  " if not when_s.is_empty() else "") + piece
	if when_s.is_empty():
		when_s = "(no trigger)"
	var then_s := ""
	for a in acts:
		var ad: Dictionary = a as Dictionary
		var piece := _summarize_action(ad)
		if not piece.is_empty():
			then_s += (" → " if not then_s.is_empty() else "") + piece
	if then_s.is_empty():
		then_s = "(no action)"
	var txt := "When %s  →  %s" % [when_s, then_s]
	if not conds.is_empty():
		txt += "\nIf: %d condition(s)" % conds.size()
	return txt


func _summarize_trigger(t: Dictionary) -> String:
	match str(t.get("kind", "")):
		"time":
			return "time %s" % _fmt_hour(float(t.get("at_hour", 0.0)))
		"sun":
			var event := str(t.get("event", "sunset"))
			var off := float(t.get("offset_hours", 0.0))
			if absf(off) < 0.01:
				return event
			return "%s %s%.1fh" % [event, ("+" if off > 0 else ""), off]
		"numeric":
			var ent := str(t.get("entity_id", ""))
			var friendly := ent.trim_prefix("sensor.")
			match ent:
				"sensor.battery_level":
					friendly = "battery SOC"
				"sensor.solar_power":
					friendly = "solar W"
				"sensor.load_power":
					friendly = "load W"
				_:
					if ent.begins_with("tank.") and ent.ends_with(".level"):
						friendly = "fill %s" % ent.trim_prefix("tank.").trim_suffix(".level")
					elif ent.begins_with("resource.") and ent.ends_with(".level"):
						friendly = ent.trim_prefix("resource.").trim_suffix(".level") + " fill"
			var parts: Array = []
			if t.has("above") and t.get("above") != null:
				parts.append("> %.0f" % float(t.get("above")))
			if t.has("below") and t.get("below") != null:
				parts.append("< %.0f" % float(t.get("below")))
			return "%s %s" % [friendly, " ".join(PackedStringArray(parts))]
		"state":
			return "%s = %s" % [str(t.get("entity_id", "")), str(t.get("to_state", ""))]
	return ""


func _summarize_action(a: Dictionary) -> String:
	match str(a.get("kind", "")):
		"scene_node":
			match str(a.get("command", "turn_on")):
				"turn_off":
					return "turn off"
				"toggle":
					return "toggle"
				_:
					return "turn on"
		"delay":
			return "wait %.0fs" % float(a.get("delay_seconds", 0.0))
	return ""


func _fmt_hour(h: float) -> String:
	var hi := int(h)
	var mi := int(round((h - hi) * 60.0))
	if mi >= 60:
		mi = 0
		hi += 1
	return "%02d:%02d" % [hi, mi]


## Resyncs the current processor's dangling/ghost I/O tank containers (name +
## kind) to match a just-committed port edit. No-op if SystemGraphView hasn't
## injected the callback or nothing is selected.
func _sync_ghost_containers() -> void:
	if _ghost_sync_cb.is_valid() and not _item_id.is_empty():
		_ghost_sync_cb.call(_item_id)


## Ask the inspector to rebuild itself for the currently-selected load item.
func _rebuild_current_item() -> void:
	if _model == null or _item_id.is_empty() or _is_connection:
		return
	var it := _model.get_item(_item_id)
	if it.is_empty():
		return
	_rebuild_for_item(it)


# ---------------------------------------------------------------------------
# Home Assistant entity linking (panel / battery / controller)
# ---------------------------------------------------------------------------

## Role definitions per node type. role_id → {label, required, unit}
const _HA_ROLES := {
	# Load nodes: link any power-monitoring plug / clamp / Shelly entity.
	# Live power writes to avg_watts so the canvas shows real wattage.
	"appliance": [
		{"id": "power",   "label": "Live Power",       "required": false, "unit": "W"},
		{"id": "energy",  "label": "Total Energy",     "required": false, "unit": "kWh"},
		{"id": "voltage", "label": "Voltage",          "required": false, "unit": "V"},
		{"id": "current", "label": "Current",          "required": false, "unit": "A"},
		{"id": "switch",  "label": "Switch / State",   "required": false, "unit": ""},
	],
	"acload": [
		{"id": "power",   "label": "Live Power",       "required": false, "unit": "W"},
		{"id": "energy",  "label": "Total Energy",     "required": false, "unit": "kWh"},
		{"id": "voltage", "label": "Voltage",          "required": false, "unit": "V"},
		{"id": "current", "label": "Current",          "required": false, "unit": "A"},
		{"id": "switch",  "label": "Switch / State",   "required": false, "unit": ""},
	],
	"panel": [
		{"id": "power",   "label": "Total PV Power",       "required": true,  "unit": "W"},
		{"id": "voltage", "label": "String Voltage",       "required": false, "unit": "V"},
		{"id": "current", "label": "String Current",       "required": false, "unit": "A"},
	],
	"battery": [
		{"id": "soc",     "label": "State of Charge",      "required": true,  "unit": "%"},
		{"id": "voltage", "label": "Battery Voltage",      "required": false, "unit": "V"},
		{"id": "power",   "label": "Battery Power",        "required": false, "unit": "W"},
		{"id": "current", "label": "Battery Current",      "required": false, "unit": "A"},
	],
	"smartbattery": [
		{"id": "soc",     "label": "State of Charge",      "required": true,  "unit": "%"},
		{"id": "voltage", "label": "Battery Voltage",      "required": false, "unit": "V"},
		{"id": "power",   "label": "Battery Power",        "required": false, "unit": "W"},
		{"id": "current", "label": "Battery Current",      "required": false, "unit": "A"},
	],
	"controller": [
		{"id": "ac_power","label": "Inverter AC Output",   "required": true,  "unit": "W"},
		{"id": "voltage", "label": "AC Voltage",           "required": false, "unit": "V"},
		{"id": "current", "label": "AC Current",           "required": false, "unit": "A"},
	],
	# Shelly Pro 4PM: power sensor, switch state, and energy for each of 4 circuits.
	# Default entity IDs match the ESPHome integration naming used in InverterBridge.
	"shelly4pm": [
		{"id": "c0_power",  "label": "Ch 0 - Power",   "required": false, "unit": "W",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_0_power"},
		{"id": "c0_switch", "label": "Ch 0 - Switch",  "required": false, "unit": "",
			"placeholder": "switch.shellypro4pm_ece334ed2e80_output_0"},
		{"id": "c0_energy", "label": "Ch 0 - Energy",  "required": false, "unit": "kWh",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_0_energy"},
		{"id": "c1_power",  "label": "Ch 1 - Power",   "required": false, "unit": "W",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_1_power"},
		{"id": "c1_switch", "label": "Ch 1 - Switch",  "required": false, "unit": "",
			"placeholder": "switch.shellypro4pm_ece334ed2e80_output_1"},
		{"id": "c1_energy", "label": "Ch 1 - Energy",  "required": false, "unit": "kWh",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_1_energy"},
		{"id": "c2_power",  "label": "Ch 2 - Power",   "required": false, "unit": "W",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_2_power"},
		{"id": "c2_switch", "label": "Ch 2 - Switch",  "required": false, "unit": "",
			"placeholder": "switch.shellypro4pm_ece334ed2e80_output_2"},
		{"id": "c2_energy", "label": "Ch 2 - Energy",  "required": false, "unit": "kWh",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_2_energy"},
		{"id": "c3_power",  "label": "Ch 3 - Power",   "required": false, "unit": "W",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_3_power"},
		{"id": "c3_switch", "label": "Ch 3 - Switch",  "required": false, "unit": "",
			"placeholder": "switch.shellypro4pm_ece334ed2e80_output_3"},
		{"id": "c3_energy", "label": "Ch 3 - Energy",  "required": false, "unit": "kWh",
			"placeholder": "sensor.shellypro4pm_ece334ed2e80_output_3_energy"},
	],
}


func _build_processor_energy_picker(specs: Dictionary) -> void:
	ResourceKinds.new().migrate_processor_specs(specs)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Energy Input"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var options: Array = [
		{"id": "ac", "label": "Electric (AC - top port)"},
		{"id": "thermal", "label": "Thermal (top port)"},
		{"id": "mechanical", "label": "Mechanical (top port)"},
		{"id": "", "label": "None (no energy port)"},
	]
	var current: String = str(specs.get("energy_source", "ac"))
	var sel := 0
	for oi: int in options.size():
		var od: Dictionary = options[oi] as Dictionary
		opt.add_item(str(od.get("label", "")), oi)
		if str(od.get("id", "")) == current:
			sel = oi
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var item := _model.get_item(_item_id)
		var sub: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		sub["energy_source"] = str((options[idx] as Dictionary).get("id", ""))
		_model.update_item(_item_id, {"specs": sub})
	)
	row.add_child(opt)
	_form_vbox.add_child(row)


## Precious Plastic sheet press: thickness setpoint + cycle telemetry
## (SystemGraphView._tick_graph_pp_sheet_press / PpSheetPressSource).
func _build_pp_sheet_press_section(specs: Dictionary) -> void:
	_num_field("Sheet Thickness (mm)", specs.get("sheet_thickness_mm", 8.0),
			"specs/sheet_thickness_mm", 5.0, 20.0, 0.5)
	_num_field("Peak Heater Power (W)", specs.get("peak_watts", 5000.0),
			"specs/peak_watts", 1000.0, 15000.0, 100.0)
	_num_field("Z Stroke (m)", specs.get("z_stroke_m", 0.12),
			"specs/z_stroke_m", 0.02, 0.5, 0.01)
	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 8)
	var auto_lbl := Label.new()
	auto_lbl.text = "Auto-cycle"
	auto_lbl.add_theme_color_override("font_color", C_TEXT_S)
	auto_lbl.custom_minimum_size.x = 120.0
	auto_row.add_child(auto_lbl)
	var auto_cb := CheckButton.new()
	auto_cb.button_pressed = bool(specs.get("auto_cycle", true))
	auto_cb.focus_mode = Control.FOCUS_NONE
	auto_cb.toggled.connect(func(on: bool) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var item := _model.get_item(_item_id)
		var sub: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		sub["auto_cycle"] = on
		_model.update_item(_item_id, {"specs": sub})
	)
	auto_row.add_child(auto_cb)
	_form_vbox.add_child(auto_row)

	# Preview mass / cycle from the pure physics helper.
	var thick := float(specs.get("sheet_thickness_mm", 8.0))
	var job := _PpSheetPressSource.derive_job(specs)
	_readonly_field("Sheet mass", "%.2f kg (1 m² × %.1f mm)" % [
		float(job.get("material_kg", 0.0)), thick])
	_readonly_field("Cycle time", "%.0f min  (melt %.0f + cool %.0f)" % [
		float(job.get("duration_hr", 0.0)) * 60.0,
		float(job.get("melt_hr", 0.0)) * 60.0,
		float(job.get("cool_hr", 0.0)) * 60.0])
	_readonly_field("Throughput", "%.1f kg/h  ·  ~%.1f kWh/h avg" % [
		float(job.get("throughput_kg_h", 0.0)),
		float(job.get("avg_kwh_per_h", 0.0))])
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Daily design", daily_note)

	_section("Live Press")
	var phase := str(specs.get("job_phase", "idle"))
	var prog := float(specs.get("job_progress", 0.0))
	_readonly_field("Phase", "%s  (%.0f%%)" % [phase, prog * 100.0])
	_readonly_field("Live draw", "%.0f W" % float(specs.get("watts", 0.0)))
	_readonly_field("Sheets pressed", "%d" % int(specs.get("sheets_pressed_total", 0)))

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var start_btn := Button.new()
	start_btn.text = "Press sheet"
	start_btn.focus_mode = Control.FOCUS_NONE
	start_btn.disabled = bool(specs.get("job_active", false))
	start_btn.pressed.connect(func():
		var v := _machine_view()
		if v != null and v.has_method("start_pp_sheet_press_job"):
			v.call("start_pp_sheet_press_job", _item_id)
			_rebuild_current_item()
	)
	btn_row.add_child(start_btn)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.focus_mode = Control.FOCUS_NONE
	cancel_btn.disabled = not bool(specs.get("job_active", false))
	cancel_btn.pressed.connect(func():
		var v := _machine_view()
		if v != null and v.has_method("cancel_pp_sheet_press_job"):
			v.call("cancel_pp_sheet_press_job", _item_id)
			_rebuild_current_item()
	)
	btn_row.add_child(cancel_btn)
	_form_vbox.add_child(btn_row)
	var inv_btn := Button.new()
	inv_btn.text = "Open Inventory…"
	inv_btn.focus_mode = Control.FOCUS_NONE
	inv_btn.pressed.connect(func():
		var v := _machine_view()
		if v != null and v.has_method("open_inventory_panel"):
			v.call("open_inventory_panel")
	)
	_form_vbox.add_child(inv_btn)

	_build_sheet_recipe_picker(specs)


## Precious Plastic beam extruder: cut length + live extrusion telemetry
## (SystemGraphView._tick_graph_pp_extruder / PpBeamExtruderSource).
func _build_pp_beam_extruder_section(specs: Dictionary) -> void:
	_num_field("Power Draw (W)", specs.get("watts", 1200.0), "specs/watts", 0, 20000, 10.0)
	_num_field("Flake Rate (kg/h)", specs.get("flake_kg_h", 5.0), "specs/flake_kg_h", 0.1, 50.0, 0.1)
	_num_field("kg per metre", specs.get("kg_per_m", 1.17), "specs/kg_per_m", 0.1, 20.0, 0.01)
	_num_field("Cut Length (m)", specs.get("cut_length_m", 2.0), "specs/cut_length_m", 0.1, 20.0, 0.05)
	_text_field("Part id", specs.get("job_part_id", "dome_beam"), "specs/job_part_id")
	_text_field("Part label", specs.get("job_part_label", "Recycled Plastic Beam"), "specs/job_part_label")
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Daily design", daily_note)

	_section("Live Extrusion")
	_pp_ext_rate_lbl = _live_readonly_field("Extrude rate", "")
	_pp_ext_stick_lbl = _live_readonly_field("Current stick", "")
	_pp_ext_cuts_lbl = _live_readonly_field("Beams cut", "")
	_update_pp_extruder_live_labels(specs)
	var inv_btn := Button.new()
	inv_btn.text = "Open Inventory…"
	inv_btn.focus_mode = Control.FOCUS_NONE
	inv_btn.pressed.connect(func():
		var v := _machine_view()
		if v != null and v.has_method("open_inventory_panel"):
			v.call("open_inventory_panel")
	)
	_form_vbox.add_child(inv_btn)


func current_item_id() -> String:
	return _item_id


## Called by SystemGraphView each extruder poll while this node is selected.
func refresh_pp_extruder_live() -> void:
	if _model == null or _item_id.is_empty():
		return
	var item := _model.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("role", "")) != "pp_beam_extruder":
		return
	_update_pp_extruder_live_labels(specs)


func _live_readonly_field(label: String, initial: String) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var key := Label.new()
	key.text = label
	key.add_theme_color_override("font_color", C_TEXT_S)
	key.custom_minimum_size.x = 120.0
	row.add_child(key)
	var val := Label.new()
	val.text = initial
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.add_theme_color_override("font_color", C_TEXT)
	row.add_child(val)
	_form_vbox.add_child(row)
	return val


func _update_pp_extruder_live_labels(specs: Dictionary) -> void:
	var mph := float(specs.get("meters_per_hour", 0.0))
	if mph <= 0.0:
		var kg_h := float(specs.get("flake_kg_h", 5.0))
		var kg_m := maxf(float(specs.get("kg_per_m", 1.17)), 0.001)
		mph = kg_h / kg_m
	if _pp_ext_rate_lbl != null and is_instance_valid(_pp_ext_rate_lbl):
		_pp_ext_rate_lbl.text = "%.2f m/h" % mph
	if _pp_ext_stick_lbl != null and is_instance_valid(_pp_ext_stick_lbl):
		_pp_ext_stick_lbl.text = "%.3f m (%.0f%% of cut)" % [
			float(specs.get("extruded_length_m", 0.0)),
			float(specs.get("extrude_fill_fraction", 0.0)) * 100.0]
	if _pp_ext_cuts_lbl != null and is_instance_valid(_pp_ext_cuts_lbl):
		_pp_ext_cuts_lbl.text = "%d" % int(specs.get("beams_cut_total", 0))


## HomeBiogas 2.0 biodigester: feed mode / daily setpoint plus read-only live
## telemetry written each tick by SystemGraphView._tick_graph_biodigester (see
## power_system/sources/home_biogas_source.gd for the physics).
func _build_biodigester_section(specs: Dictionary) -> void:
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 8)
	var mode_lbl := Label.new()
	mode_lbl.text = "Feed Type"
	mode_lbl.add_theme_color_override("font_color", C_TEXT_S)
	mode_lbl.custom_minimum_size.x = 120.0
	mode_row.add_child(mode_lbl)
	var mode_opt := OptionButton.new()
	mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_opt.add_item("Food waste (max 6 L/day)", 0)
	mode_opt.add_item("Animal manure (max 15 L/day)", 1)
	var is_manure := str(specs.get("feed_mode", "food")).to_lower() == "manure"
	mode_opt.select(1 if is_manure else 0)
	mode_opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var item := _model.get_item(_item_id)
		var sub: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var new_mode := "manure" if idx == 1 else "food"
		sub["feed_mode"] = new_mode
		var mode_max := float(sub.get("max_manure_l_day", 15.0)) if new_mode == "manure" \
				else float(sub.get("max_food_l_day", 6.0))
		sub["daily_feed_l"] = minf(float(sub.get("daily_feed_l", mode_max)), mode_max)
		var inputs: Array = (sub.get("inputs", []) as Array).duplicate(true)
		if not inputs.is_empty():
			var inp0: Dictionary = (inputs[0] as Dictionary).duplicate(true)
			inp0["kind"] = "manure" if new_mode == "manure" else "food_waste"
			inputs[0] = inp0
			sub["inputs"] = inputs
		_model.update_item(_item_id, {"specs": sub})
		_rebuild_current_item()
	)
	mode_row.add_child(mode_opt)
	_form_vbox.add_child(mode_row)

	var feed_max := float(specs.get("max_manure_l_day", 15.0)) if is_manure \
			else float(specs.get("max_food_l_day", 6.0))
	_num_field("Daily Feed (L)", specs.get("daily_feed_l", feed_max),
			"specs/daily_feed_l", 0.0, feed_max, 0.1)
	_num_field("CH₄ Fraction", specs.get("ch4_fraction", 0.625),
			"specs/ch4_fraction", 0.5, 0.75, 0.01)
	_readonly_field("Digester Volume", "%.0f L" % float(specs.get("digester_volume_l", 1200.0)))
	_readonly_field("Gas Storage", "%.0f L (%.2f m³)" % [
		float(specs.get("gas_storage_l", 700.0)),
		float(specs.get("gas_storage_l", 700.0)) / 1000.0])
	_readonly_field("Dimensions", "%.0f × %.0f × %.0f cm" % [
		float(specs.get("dim_l_cm", 210.0)),
		float(specs.get("dim_w_cm", 115.0)),
		float(specs.get("dim_h_cm", 130.0))])
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Daily design", daily_note)

	_section("Live Telemetry")
	_readonly_field("Ambient Temp", "%.1f °C" % float(specs.get("ambient_temp_c", 20.0)))
	_readonly_field("Temp Factor", "%.0f%%" % (float(specs.get("temp_factor", 1.0)) * 100.0))
	_readonly_field("Feed Load", "%.0f%% of max" % (float(specs.get("feed_fraction", 0.0)) * 100.0))
	_readonly_field("Biogas", "%.3f m³/h (%.2f m³/day)" % [
		float(specs.get("biogas_m3_h", 0.0)),
		float(specs.get("biogas_m3_day", float(specs.get("biogas_m3_h", 0.0)) * 24.0))])
	_readonly_field("Methane", "%.2f m³/day" % float(specs.get("methane_m3_day", 0.0)))
	_readonly_field("Fertilizer", "%.2f L/h" % float(specs.get("fertilizer_lph", 0.0)))
	_readonly_field("Cooking Gas", "~%.1f h/day (single burner)" % float(specs.get("cooking_hours_day", 0.0)))


## Siphon micro-hydro: open Siphon Lab for levels; compact live telemetry here.
func _build_siphon_hydro_section(specs: Dictionary) -> void:
	var lab_btn := Button.new()
	lab_btn.text = "Open Hydro Lab…"
	lab_btn.tooltip_text = "Turbine kind, geometry, penstock, live RPM / power"
	lab_btn.pressed.connect(func() -> void:
		if _siphon_lab_cb.is_valid() and not _item_id.is_empty():
			_siphon_lab_cb.call(_item_id))
	_form_vbox.add_child(lab_btn)
	var kind := str(specs.get("turbine_kind", "siphon"))
	_turbine_kind_field("Turbine kind", kind, "specs/turbine_kind")
	var has_penstock := bool(HydroSource.kind_meta(kind).get("has_penstock", false))
	_num_field("Intake Ø (mm)", specs.get("intake_diameter_mm", 150.0),
			"specs/intake_diameter_mm", 50.0, 400.0, 5.0)
	_num_field("Outlet Ø (mm)", specs.get("outlet_diameter_mm", 200.0),
			"specs/outlet_diameter_mm", 50.0, 600.0, 5.0)
	if has_penstock:
		# Penstock turbine (pelton/turgo/run-of-river): pond drains through a
		# pressurized pipe; Q is set by penstock delivery vs. turbine design flow.
		_num_field("Penstock length (m)", specs.get("penstock_length_m", 60.0),
				"specs/penstock_length_m", 1.0, 2000.0, 1.0)
		_num_field("Penstock Ø (mm)", specs.get("penstock_diameter_mm", 63.0),
				"specs/penstock_diameter_mm", 20.0, 2000.0, 1.0)
		_num_field("Roughness ε (mm)", specs.get("pipe_roughness_mm", 0.0015),
				"specs/pipe_roughness_mm", 0.0005, 1.0, 0.0005)
		_num_field("Design flow (L/s)", specs.get("design_flow_lps", 5.0),
				"specs/design_flow_lps", 0.1, 5000.0, 0.1)
		_num_field("Turbine η (0=auto)", specs.get("turbine_efficiency", 0.0),
				"specs/turbine_efficiency", 0.0, 0.95, 0.01)
	else:
		# Siphon: orifice-limited barrel + hydraulic efficiency.
		_num_field("Barrel length (m)", specs.get("barrel_length_m", 20.0),
				"specs/barrel_length_m", 1.0, 500.0, 0.5)
		_num_field("Hydraulic η", specs.get("hydraulic_efficiency", 0.6),
				"specs/hydraulic_efficiency", 0.1, 1.0, 0.01)
	_num_field("Max power (W, 0=uncapped)", specs.get("max_power_w", 0.0),
			"specs/max_power_w", 0.0, 50000.0, 10.0)
	_num_field("Generator η", specs.get("generator_efficiency", 0.7),
			"specs/generator_efficiency", 0.1, 1.0, 0.01)
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Wiring", daily_note)
	_section("Live Telemetry")
	_readonly_field("Siphon", "PRIMED" if bool(specs.get("siphon_primed", false)) else "broken / dry")
	_readonly_field("Flow", "%.2f L/s" % float(specs.get("live_q_lps", 0.0)))
	_readonly_field("Head", "%.2f m" % float(specs.get("live_head_m", 0.0)))
	_readonly_field("RPM", "%.0f" % float(specs.get("live_rpm", 0.0)))
	_readonly_field("PE potential", "%.0f W" % float(specs.get("live_pe_w", 0.0)))
	_readonly_field("DC output", "%.0f W" % (float(specs.get("current_output_kw", 0.0)) * 1000.0))
	_readonly_field("Regime", str(specs.get("live_regime", "—")))
	_readonly_field("Hint", "Siphon Lab → Bind pond + ∞ outlet · DC +/- → 48V battery")


## Parabolic-trough CSP fields: geometry/optics inputs plus read-only live
## telemetry written each tick by SystemGraphView._tick_graph_csp (see
## power_system/sources/csp_trough_source.gd for the physics).
func _build_csp_concentrator_section(specs: Dictionary) -> void:
	_num_field("Aperture Width (m)",   specs.get("aperture_width_m", 5.0),   "specs/aperture_width_m",   0.5, 20.0, 0.1)
	_num_field("Module Length (m)",    specs.get("module_length_m", 12.0),   "specs/module_length_m",    0.5, 100.0, 0.5)
	_num_field("Focal Length (m)",     specs.get("focal_length_m", 1.7),     "specs/focal_length_m",     0.1, 10.0, 0.05)
	_num_field("Optical Efficiency",   specs.get("optical_efficiency", 0.75),"specs/optical_efficiency", 0.0, 1.0, 0.01)
	_num_field("Thermal Efficiency",   specs.get("thermal_efficiency", 0.85),"specs/thermal_efficiency", 0.0, 1.0, 0.01)
	_num_field("Feedwater Temp (°C)",  specs.get("feedwater_temp_c", 20.0),  "specs/feedwater_temp_c",   0.0, 99.0, 1.0)
	_num_field("Max Tracking Angle (°)", specs.get("max_tracking_angle_deg", 110.0),
			"specs/max_tracking_angle_deg", 30.0, 120.0, 1.0)
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Daily design", daily_note)

	_section("Live Telemetry")
	_readonly_field("Tracking Angle", "%.1f°" % float(specs.get("tracking_angle_deg", 0.0)))
	_readonly_field("Incidence cos(θ)", "%.3f" % float(specs.get("cos_incidence", 0.0)))
	_readonly_field("DNI", "%.0f W/m²" % float(specs.get("dni_wm2", 0.0)))
	_readonly_field("End Loss", "%.1f%%" % (float(specs.get("end_loss_frac", 0.0)) * 100.0))
	_readonly_field("Thermal Output", "%.2f kW" % float(specs.get("thermal_output_kw", 0.0)))
	_readonly_field("Steam Output", "%.2f kg/h" % float(specs.get("steam_kg_h", 0.0)))


## Cartesian CNC machine (CNC router / flake 3D printer): editable machine
## params, a job upload/start/cancel flow, live scrub-safe job telemetry (owned
## by SystemGraphView._tick_graph_tools), and buttons to load a real G-code/STL
## file + configure the X/Y/Z axis tagging (Machine Setup modal).
func _build_cartesian_machine_section(item: Dictionary, specs: Dictionary) -> void:
	var iid := str(item.get("id", ""))
	var role := str(specs.get("machine_role", "generic"))
	_num_field("Power Draw (W)", specs.get("watts", 900.0), "specs/watts", 0, 20000, 10.0)
	_num_field("Speed Factor", specs.get("speed_factor", 1.0), "specs/speed_factor", 0.05, 100.0, 0.05)
	if role == "fdm_printer":
		_num_field("Feedstock Ø (mm)", specs.get("filament_diameter_mm", 3.0), "specs/filament_diameter_mm", 0.1, 20.0, 0.1)
		_num_field("Flake Density (g/cm³)", specs.get("flake_density_g_cm3", 0.95), "specs/flake_density_g_cm3", 0.1, 3.0, 0.01)
	_section("Work Volume (mm)")
	_num_field("X travel", specs.get("work_x_mm", 600.0), "specs/work_x_mm", 10, 100000, 1.0)
	_num_field("Y travel", specs.get("work_y_mm", 600.0), "specs/work_y_mm", 10, 100000, 1.0)
	_num_field("Z travel", specs.get("work_z_mm", 600.0), "specs/work_z_mm", 10, 100000, 1.0)
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Design", daily_note)

	_section("Job")
	var active := bool(specs.get("job_active", false))
	var is_router := role == "cnc_router" or str(specs.get("model_id", "")) == "cnc_router"
	if active:
		var progress := clampf(float(specs.get("job_progress", 0.0)), 0.0, 1.0)
		var dur := float(specs.get("job_duration_hr", 0.0))
		_readonly_field("Job", str(specs.get("job_name", "Job")))
		_readonly_field("Progress", "%.0f%%" % (progress * 100.0))
		_readonly_field("Machine time left", "%.2f h" % (dur * (1.0 - progress)))
		var mkind := str(specs.get("job_material_kind", ""))
		if not mkind.is_empty():
			_readonly_field("Material", "%.3f kg %s" % [
				float(specs.get("job_material_qty", 0.0)), ResourceKinds.display_name(mkind)])
		_readonly_field("Energy (job)", "%.2f kWh" % float(specs.get("job_energy_kwh", 0.0)))
		var cancel_btn := Button.new()
		cancel_btn.text = "⏹ Cancel job"
		cancel_btn.pressed.connect(func():
			var v := _machine_view()
			if v != null and v.has_method("cancel_machine_job"):
				v.call("cancel_machine_job", iid)
			_rebuild_current_item()
		)
		_form_vbox.add_child(cancel_btn)
	else:
		if bool(specs.get("job_completed", false)):
			_readonly_field("Last job", "%s ✓ (%d× %s)" % [
				str(specs.get("job_name", "Job")),
				int(specs.get("job_part_count", 1)),
				str(specs.get("job_part_label", "part"))])
		if is_router:
			_build_cnc_cut_presets(iid)
		_text_field("Part name", specs.get("job_part_label", ""), "specs/job_part_label")
		_text_field("Part id", specs.get("job_part_id", ""), "specs/job_part_id")
		_num_field("Part count", specs.get("job_part_count", 1), "specs/job_part_count", 1, 1000, 1.0)
		# Staged file summary + Start, if a file was loaded for THIS node.
		if _pending_job_item_id == iid and not _pending_job_parse.is_empty():
			var pj := _pending_job_parse
			_readonly_field("Loaded", "%s • %d pts" % [
				str(pj.get("kind", "job")).to_upper(), int(pj.get("point_count", 0))])
			_readonly_field("Est. time", "%.2f h @ 1×" % float(pj.get("est_time_hr", 0.0)))
			var bmin: Vector3 = pj.get("bounds_min", Vector3.ZERO)
			var bmax: Vector3 = pj.get("bounds_max", Vector3.ZERO)
			var sz := bmax - bmin
			_readonly_field("Size (mm)", "%.0f × %.0f × %.0f" % [sz.x, sz.y, sz.z])
			var start_btn := Button.new()
			start_btn.text = "▶ Start job"
			start_btn.pressed.connect(func():
				var it := _model.get_item(iid)
				var sp: Dictionary = it.get("specs", {}) as Dictionary
				var v := _machine_view()
				if v != null and v.has_method("start_machine_job"):
					v.call("start_machine_job", iid, _pending_job_parse,
						str(sp.get("job_part_id", "")), str(sp.get("job_part_label", "")),
						int(sp.get("job_part_count", 1)))
				_pending_job_parse = {}
				_pending_job_item_id = ""
				_rebuild_current_item()
			)
			_form_vbox.add_child(start_btn)
		var load_btn := Button.new()
		load_btn.text = "📂 Load G-code / STL…"
		load_btn.pressed.connect(func():
			_pending_job_item_id = iid
			_ensure_machine_file_dialog()
			_machine_file_dialog.popup_centered_ratio(0.6)
		)
		_form_vbox.add_child(load_btn)

	_section("3D Machine")
	var setup_btn := Button.new()
	setup_btn.text = "🔧 Configure axes…"
	setup_btn.tooltip_text = "Tag which model sub-node is each X/Y/Z axis and calibrate travel."
	setup_btn.pressed.connect(func():
		var v := _machine_view()
		if v != null and v.has_method("open_machine_setup"):
			v.call("open_machine_setup", str(specs.get("model_id", "")), iid)
	)
	_form_vbox.add_child(setup_btn)

	var inv_btn := Button.new()
	inv_btn.text = "🧩 Inventory & crafting…"
	inv_btn.pressed.connect(func():
		var v := _machine_view()
		if v != null and v.has_method("open_inventory_panel"):
			v.call("open_inventory_panel")
	)
	_form_vbox.add_child(inv_btn)


## Built-in cut ops: debit one recycled-plastic beam → mill A/B dome strut.
func _build_cnc_cut_presets(item_id: String) -> void:
	_section("Cut presets (beam → strut)")
	var inv := _part_inventory()
	var beams := inv.count_beam_feedstock() if inv != null else 0
	_readonly_field("Beam stock", "%d recycled plastic beam(s)" % beams)
	var note := Label.new()
	note.text = "Mills rounded ends + bolt holes. Alternate path to printing struts on the trash printer."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	note.modulate = Color(0.7, 0.75, 0.82)
	_form_vbox.add_child(note)
	for p: Dictionary in CncCutPresets.all():
		var pid := str(p.get("id", ""))
		var need := maxi(int(p.get("consume_qty", 1)), 1)
		var btn := Button.new()
		btn.text = "✂ %s" % str(p.get("label", pid))
		btn.tooltip_text = str(p.get("note", ""))
		btn.disabled = beams < need
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_cnc_cut_preset_pressed.bind(item_id, pid))
		_form_vbox.add_child(btn)
	if beams <= 0:
		var hint := Label.new()
		hint.text = "No beam feedstock yet — cut beams on the PP Beam Extruder (or load beams labeled “Recycled Plastic Beam”)."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		hint.modulate = Color(0.9, 0.7, 0.55)
		_form_vbox.add_child(hint)
		# Legacy: extruder used to auto-tag long cuts as finished struts.
		if inv != null:
			var as_n := inv.count("dome_strut_a")
			var bs_n := inv.count("dome_strut_b")
			if as_n + bs_n > 0:
				var conv := Button.new()
				conv.text = "↩ Reclaim %d strut(s) as beam stock" % (as_n + bs_n)
				conv.tooltip_text = "If these came from the beam extruder (not the trash printer), convert them back to CNC feedstock."
				conv.focus_mode = Control.FOCUS_NONE
				conv.pressed.connect(func():
					_reclaim_struts_as_beams(inv)
					_rebuild_current_item()
				)
				_form_vbox.add_child(conv)


func _on_cnc_cut_preset_pressed(item_id: String, preset_id: String) -> void:
	var v := _machine_view()
	if v == null or not v.has_method("start_cnc_cut_preset"):
		_toast("CNC cut presets unavailable")
		return
	var result: Dictionary = v.call("start_cnc_cut_preset", item_id, preset_id)
	if bool(result.get("ok", false)):
		_toast("Cutting %s (1 beam)" % str(result.get("produce", "strut")))
	else:
		_toast(str(result.get("error", "cut failed")))
	_rebuild_current_item()


func _reclaim_struts_as_beams(inv: PartInventory) -> void:
	if inv == null:
		return
	var n := 0
	for pid: String in ["dome_strut_a", "dome_strut_b"]:
		var q := inv.count(pid)
		if q <= 0:
			continue
		if inv.remove_part(pid, q):
			inv.add_part("pp_beam", q, {
				"label": DomeParts.label_for(DomeParts.PART_BEAM),
				"material_kind": "plastic_flake",
				"source": "reclaim_strut",
			})
			n += q
	if n <= 0:
		return
	var tree := get_tree()
	var main := tree.get_first_node_in_group("main_scene") if tree != null else null
	if main == null and tree != null:
		main = tree.root.find_child("Main", true, false)
	var loader := main.find_child("TerrainLoader", true, false) if main != null else null
	if loader != null and loader.has_method("save_part_inventory"):
		loader.call("save_part_inventory")
	_toast("Reclaimed %d beam(s) for CNC cutting" % n)


func _part_inventory() -> PartInventory:
	var tree := get_tree()
	if tree == null:
		return null
	var main := tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.root.find_child("Main", true, false)
	if main == null:
		return null
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("get_part_inventory"):
		return loader.call("get_part_inventory") as PartInventory
	return null


func _ensure_machine_file_dialog() -> void:
	if _machine_file_dialog != null and is_instance_valid(_machine_file_dialog):
		return
	_machine_file_dialog = FileDialog.new()
	_machine_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_machine_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_machine_file_dialog.filters = PackedStringArray([
		"*.gcode, *.gco, *.g, *.nc, *.ngc, *.tap ; G-code",
		"*.stl ; STL mesh"])
	_machine_file_dialog.title = "Load machine job (G-code / STL)"
	_machine_file_dialog.file_selected.connect(_on_machine_file_selected)
	add_child(_machine_file_dialog)


func _on_machine_file_selected(path: String) -> void:
	var ext := path.get_extension().to_lower()
	var parse: Dictionary
	if ext == "stl":
		parse = StlLoader.parse_file(path)
	else:
		parse = Toolpath.parse_file(path)
	if not bool(parse.get("ok", false)):
		_toast("Could not parse job: %s" % str(parse.get("error", "unknown")))
		return
	_pending_job_parse = parse
	# Default the part name from the filename if the user hasn't set one.
	if _model != null and not _pending_job_item_id.is_empty():
		var it := _model.get_item(_pending_job_item_id)
		if not it.is_empty():
			var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
			if str(sp.get("job_part_label", "")).is_empty():
				var base := path.get_file().get_basename()
				sp["job_part_label"] = base
				sp["job_part_id"] = base.to_snake_case()
				_model.update_item(_pending_job_item_id, {"specs": sp})
	_toast("Loaded job (%d pts) — set part name + Start" % int(parse.get("point_count", 0)))
	_rebuild_current_item()


## Finds the SystemGraphView (owns machine job scheduling + setup modal) by
## walking up the parent chain, falling back to the known UILayer path.
func _machine_view() -> Node:
	var n: Node = self
	while n != null:
		if n.has_method("start_machine_job"):
			return n
		n = n.get_parent()
	var tree := get_tree()
	if tree != null:
		var m := tree.get_first_node_in_group("main_scene")
		if m != null:
			return m.get_node_or_null("UILayer/SystemGraphView")
	return null


func _build_heliostat_section(specs: Dictionary) -> void:
	_num_field("Mirror Area (m²)",     specs.get("mirror_area_m2", 19.36),   "specs/mirror_area_m2",     1.0, 500.0, 0.1)
	_num_field("Focal Box Size (m)",   specs.get("focal_box_size_m", 0.5),   "specs/focal_box_size_m",   0.05, 5.0, 0.05)
	_num_field("Optical Efficiency",   specs.get("optical_efficiency", 0.80),"specs/optical_efficiency", 0.0, 1.0, 0.01)
	_num_field("Receiver Absorptivity",specs.get("receiver_absorptivity", 0.95),"specs/receiver_absorptivity", 0.0, 1.0, 0.01)
	_num_field("Receiver Emissivity",  specs.get("receiver_emissivity", 0.90),"specs/receiver_emissivity", 0.01, 1.0, 0.01)
	_num_field("Convection h (W/m²K)", specs.get("conv_coeff_w_m2k", 10.0),  "specs/conv_coeff_w_m2k",   0.0, 100.0, 1.0)
	_num_field("Operating Temp (°C)",  specs.get("operating_temp_c", 250.0), "specs/operating_temp_c",   20.0, 2000.0, 5.0)
	_num_field("Thermal Efficiency",   specs.get("thermal_efficiency", 0.85),"specs/thermal_efficiency", 0.0, 1.0, 0.01)
	_num_field("Feedwater Temp (°C)",  specs.get("feedwater_temp_c", 20.0),  "specs/feedwater_temp_c",   0.0, 99.0, 1.0)
	var daily_note := str(specs.get("daily_note", ""))
	if not daily_note.is_empty():
		_readonly_field("Daily design", daily_note)

	_section("Live Telemetry")
	_readonly_field("Incidence cos(θ)", "%.3f" % float(specs.get("cos_incidence", 0.0)))
	_readonly_field("DNI", "%.0f W/m²" % float(specs.get("dni_wm2", 0.0)))
	_readonly_field("Concentration", "%.0f×" % float(specs.get("concentration_ratio", 0.0)))
	_readonly_field("Focal Flux", "%.1f kW/m²" % float(specs.get("focal_flux_kw_m2", 0.0)))
	_readonly_field("Focal Temp", "%.0f °C" % float(specs.get("focal_temp_c", 0.0)))
	_readonly_field("Incident Power", "%.2f kW" % float(specs.get("incident_kw", 0.0)))
	_readonly_field("Thermal Output", "%.2f kW" % float(specs.get("thermal_output_kw", 0.0)))
	_readonly_field("Steam Output", "%.2f kg/h" % float(specs.get("steam_kg_h", 0.0)))


## "Save to Library": pushes this processor instance's current config (specs
## minus per-instance state) back to its ComponentPresets library entry, then
## live-updates every other placed instance of the same template to match.
func _build_save_to_library_button(item: Dictionary) -> void:
	_form_vbox.add_child(Control.new())
	var btn := Button.new()
	btn.text = "💾 Save to Library"
	btn.tooltip_text = "Update this component's library preset with the current settings, and apply them to every other instance on the canvas."
	var iid := str(item.get("id", ""))
	btn.pressed.connect(func():
		if _save_to_library_cb.is_valid():
			_save_to_library_cb.call(iid)
	)
	_form_vbox.add_child(btn)


## Process recipes replace Batch Cycle Mode: pick a catalog recipe, run/cancel,
## edit/create via modal. I/O still editable when a recipe (or legacy batch) is active.
func _build_process_recipe_section(specs: Dictionary) -> void:
	ResourceKinds.new().migrate_processor_specs(specs)
	_section("Process Recipe")
	var role := str(specs.get("role", "processor"))
	var recipes: Array = ProcessRecipeCatalog.recipes_for_role(role)
	# Also show generic processor recipes when role is specialized-empty.
	if recipes.is_empty():
		recipes = ProcessRecipeCatalog.recipes_for_role("processor")

	var selected := str(specs.get("selected_recipe_id", specs.get("active_recipe_id", "")))
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_item("(none — continuous)", 0)
	var ids: Array = [""]
	var sel_idx := 0
	for i in recipes.size():
		var r: Dictionary = recipes[i] as Dictionary
		var rid := str(r.get("id", ""))
		opt.add_item(str(r.get("label", rid)), i + 1)
		ids.append(rid)
		if rid == selected:
			sel_idx = i + 1
	# Legacy batch without a named recipe.
	if selected.is_empty() and bool(specs.get("batch_mode", false)):
		opt.add_item("Legacy batch cycle", ids.size())
		ids.append(ProcessRecipe.EPHEMERAL_ID)
		sel_idx = ids.size() - 1
	opt.select(sel_idx)
	opt.item_selected.connect(func(idx: int):
		var rid2 := str(ids[idx]) if idx >= 0 and idx < ids.size() else ""
		if rid2.is_empty():
			specs["selected_recipe_id"] = ""
			specs["batch_mode"] = false
			specs.erase("active_recipe_id")
			_commit_field("specs", specs)
			_rebuild_current_item()
			return
		if rid2 == ProcessRecipe.EPHEMERAL_ID:
			specs["batch_mode"] = true
			specs["selected_recipe_id"] = ProcessRecipe.EPHEMERAL_ID
			_commit_field("specs", specs)
			_rebuild_current_item()
			return
		var v := _machine_view()
		if v != null and v.has_method("apply_process_recipe"):
			v.call("apply_process_recipe", _item_id, rid2)
		_rebuild_current_item()
	)
	_form_vbox.add_child(opt)

	var recipe := ProcessRecipeCatalog.find(selected)
	if recipe.is_empty() and bool(specs.get("batch_mode", false)):
		recipe = ProcessRecipe.from_batch_specs(specs)
	if not recipe.is_empty():
		_readonly_field("Batch time", "%.2f h" % float(recipe.get("batch_time_hrs", 1.0)))
		_readonly_field("Chore hours", "%.2f h" % float(recipe.get("chore_hours", 0.0)))
		var steps: Array = recipe.get("steps", []) as Array
		if not steps.is_empty():
			var step_bits: PackedStringArray = PackedStringArray()
			for s: Variant in steps:
				if s is Dictionary:
					step_bits.append(str((s as Dictionary).get("label", "")))
			_readonly_field("Steps", " → ".join(step_bits))
		var note := str(recipe.get("note", ""))
		if not note.is_empty():
			_readonly_field("Note", note)

	if bool(specs.get("recipe_waiting_chore", false)):
		var banner := Label.new()
		banner.text = "Waiting: %s" % str(specs.get("recipe_waiting_label", "chore"))
		banner.add_theme_color_override("font_color", UITheme.C_WARN)
		banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_form_vbox.add_child(banner)
		var conf := Button.new()
		conf.text = "Confirm chore"
		conf.focus_mode = Control.FOCUS_NONE
		conf.pressed.connect(func():
			var v2 := _machine_view()
			if v2 != null and v2.has_method("confirm_recipe_chore"):
				v2.call("confirm_recipe_chore", _item_id)
			_rebuild_current_item()
		)
		_form_vbox.add_child(conf)

	var prog := float(specs.get("recipe_progress", 0.0))
	if bool(specs.get("recipe_running", false)) or prog > 0.0:
		_readonly_field("Progress", "%.0f%%" % (prog * 100.0))

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var start_btn := Button.new()
	start_btn.text = "Start recipe"
	start_btn.focus_mode = Control.FOCUS_NONE
	start_btn.disabled = selected.is_empty() and not bool(specs.get("batch_mode", false))
	start_btn.pressed.connect(func():
		var v3 := _machine_view()
		if v3 != null and v3.has_method("start_process_recipe"):
			v3.call("start_process_recipe", _item_id)
		_rebuild_current_item()
	)
	btn_row.add_child(start_btn)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.focus_mode = Control.FOCUS_NONE
	cancel_btn.disabled = not bool(specs.get("recipe_running", false))
	cancel_btn.pressed.connect(func():
		var v4 := _machine_view()
		if v4 != null and v4.has_method("cancel_process_recipe"):
			v4.call("cancel_process_recipe", _item_id)
		_rebuild_current_item()
	)
	btn_row.add_child(cancel_btn)
	_form_vbox.add_child(btn_row)

	var edit_row := HBoxContainer.new()
	edit_row.add_theme_constant_override("separation", 8)
	var edit_btn := Button.new()
	edit_btn.text = "Edit recipe…"
	edit_btn.focus_mode = Control.FOCUS_NONE
	edit_btn.disabled = selected.is_empty() or selected == ProcessRecipe.EPHEMERAL_ID
	edit_btn.pressed.connect(func():
		var v5 := _machine_view()
		if v5 != null and v5.has_method("open_process_recipe_editor"):
			v5.call("open_process_recipe_editor", selected, role)
	)
	edit_row.add_child(edit_btn)
	var new_btn := Button.new()
	new_btn.text = "New recipe…"
	new_btn.focus_mode = Control.FOCUS_NONE
	new_btn.pressed.connect(func():
		var v6 := _machine_view()
		if v6 != null and v6.has_method("open_process_recipe_editor"):
			v6.call("open_process_recipe_editor", "", role)
	)
	edit_row.add_child(new_btn)
	var save_leg := Button.new()
	save_leg.text = "Save as recipe…"
	save_leg.focus_mode = Control.FOCUS_NONE
	save_leg.tooltip_text = "Save the current I/O + cycle time as a named user recipe."
	save_leg.pressed.connect(func():
		var ephemeral := ProcessRecipe.from_batch_specs(specs)
		ephemeral["id"] = ""
		ephemeral["label"] = str(specs.get("name", "Custom recipe"))
		ephemeral["compatible_roles"] = [role] if not role.is_empty() else ["processor"]
		var saved := ProcessRecipeCatalog.save_user_recipe(ephemeral)
		var v7 := _machine_view()
		if v7 != null and v7.has_method("apply_process_recipe"):
			v7.call("apply_process_recipe", _item_id, str(saved.get("id", "")))
		_rebuild_current_item()
	)
	edit_row.add_child(save_leg)
	_form_vbox.add_child(edit_row)

	# I/O editor (recipe-driven modes when a recipe/batch is selected).
	var recipe_active := not recipe.is_empty() or bool(specs.get("batch_mode", false)) \
			or not selected.is_empty()
	_section("Inputs")
	var inputs: Array = specs.get("inputs", []) as Array
	for i in inputs.size():
		_build_io_row(specs, "inputs", i, recipe_active)
	var add_in_btn := Button.new()
	add_in_btn.text = "+ Add Input"
	add_in_btn.pressed.connect(func():
		var arr: Array = specs.get("inputs", []) as Array
		arr.append({"kind": "electric", "rate": 1000.0, "qty": 1000.0, "mode": "continuous"})
		specs["inputs"] = arr
		_commit_field("specs", specs)
		_sync_ghost_containers()
		_rebuild_current_item()
	)
	_form_vbox.add_child(add_in_btn)
	_form_vbox.add_child(Control.new())

	_section("Outputs")
	var outputs: Array = specs.get("outputs", []) as Array
	for i in outputs.size():
		_build_io_row(specs, "outputs", i, recipe_active)
	var add_out_btn := Button.new()
	add_out_btn.text = "+ Add Output"
	add_out_btn.pressed.connect(func():
		var arr2: Array = specs.get("outputs", []) as Array
		arr2.append({"kind": "water", "rate": 0.0, "qty": 0.0, "mode": "end_batch",
			"delay_hrs": 0.0, "duration_hrs": 1.0})
		specs["outputs"] = arr2
		_commit_field("specs", specs)
		_sync_ghost_containers()
		_rebuild_current_item()
	)
	_form_vbox.add_child(add_out_btn)
	_form_vbox.add_child(Control.new())


func _build_sheet_recipe_picker(specs: Dictionary) -> void:
	_section("Process Recipe")
	var recipes: Array = ProcessRecipeCatalog.recipes_for_role("pp_sheet_press")
	var selected := str(specs.get("selected_recipe_id", ""))
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_item("(manual thickness)", 0)
	var ids: Array = [""]
	var sel_idx := 0
	for i in recipes.size():
		var r: Dictionary = recipes[i] as Dictionary
		var rid := str(r.get("id", ""))
		opt.add_item(str(r.get("label", rid)), i + 1)
		ids.append(rid)
		if rid == selected:
			sel_idx = i + 1
	opt.select(sel_idx)
	opt.item_selected.connect(func(idx: int):
		var rid2 := str(ids[idx]) if idx >= 0 and idx < ids.size() else ""
		if rid2.is_empty():
			specs["selected_recipe_id"] = ""
			_commit_field("specs", specs)
			_rebuild_current_item()
			return
		var v := _machine_view()
		if v != null and v.has_method("apply_process_recipe"):
			v.call("apply_process_recipe", _item_id, rid2)
		_rebuild_current_item()
	)
	_form_vbox.add_child(opt)
	var recipe := ProcessRecipeCatalog.find(selected)
	if not recipe.is_empty():
		_readonly_field("Recipe chore", "%.2f h — %s" % [
			float(recipe.get("chore_hours", 0.0)),
			str(recipe.get("note", ""))])
	var edit_btn := Button.new()
	edit_btn.text = "Edit / New recipe…"
	edit_btn.focus_mode = Control.FOCUS_NONE
	edit_btn.pressed.connect(func():
		var v2 := _machine_view()
		if v2 != null and v2.has_method("open_process_recipe_editor"):
			v2.call("open_process_recipe_editor", selected, "pp_sheet_press")
	)
	_form_vbox.add_child(edit_btn)

func _build_io_row(specs: Dictionary, arr_name: String, idx: int, batch_mode: bool) -> void:
	var arr: Array = specs.get(arr_name, []) as Array
	var io: Dictionary = arr[idx] as Dictionary
	
	var row_ctr := _row_container()
	var vbox := VBoxContainer.new()
	row_ctr.add_child(vbox)
	
	var header := HBoxContainer.new()
	var title_lbl := Label.new()
	title_lbl.text = ("In %d" % (idx+1)) if arr_name == "inputs" else ("Out %d" % (idx+1))
	title_lbl.add_theme_color_override("font_color", C_TEXT_S)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_lbl)
	
	var del_btn := Button.new()
	del_btn.text = "X"
	del_btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	del_btn.pressed.connect(func():
		arr.remove_at(idx)
		_commit_field("specs", specs)
		_rebuild_current_item()
	)
	header.add_child(del_btn)
	vbox.add_child(header)
	
	var hbox1 := HBoxContainer.new()
	var kind_opt := OptionButton.new()
	kind_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var kinds := ResourceKinds.all_kinds()
	if not kinds.has("electric"): kinds.append("electric")
	var cur_kind := str(io.get("kind", ""))
	var sel := 0
	for ki in kinds.size():
		var k := str(kinds[ki])
		kind_opt.add_item(ResourceKinds.display_name(k), ki)
		if k == cur_kind: sel = ki
	kind_opt.select(sel)
	kind_opt.item_selected.connect(func(id: int):
		var old_io_kind := str(io.get("kind", ""))
		var new_io_kind := str(kinds[id])
		io["kind"] = new_io_kind
		_commit_field("specs", specs)
		# dc_electricity swaps this row's single port for a +/- pair (or vice
		# versa) — drop any stale customized port geometry so it doesn't
		# linger with the wrong polarity/role alongside the new topology.
		if (new_io_kind == "dc_electricity" or old_io_kind == "dc_electricity") \
				and _model != null and not _item_id.is_empty():
			_model.update_item(_item_id, {"handles": []})
		_sync_ghost_containers()
		_rebuild_current_item()
	)
	hbox1.add_child(kind_opt)
	
	var qty_spin := SpinBox.new()
	qty_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qty_spin.prefix = "Qty:"
	qty_spin.min_value = 0.0
	qty_spin.max_value = 999999.0
	qty_spin.step = 0.01
	qty_spin.value = float(io.get("rate", 0.0))
	qty_spin.value_changed.connect(func(v: float):
		io["rate"] = v
		_commit_field("specs", specs)
	)
	hbox1.add_child(qty_spin)
	vbox.add_child(hbox1)
	
	if batch_mode:
		var hbox2 := HBoxContainer.new()
		var mode_opt := OptionButton.new()
		mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mode_vals := ["continuous", "frontloaded"] if arr_name == "inputs" else ["continuous", "delayed", "end_batch"]
		var mode_names := ["Continuous", "Frontloaded"] if arr_name == "inputs" else ["Continuous", "Delayed", "End Batch"]
		var cur_mode := str(io.get("mode", "continuous"))
		var msel := 0
		for mi in mode_vals.size():
			mode_opt.add_item(mode_names[mi], mi)
			if mode_vals[mi] == cur_mode: msel = mi
		mode_opt.select(msel)
		mode_opt.item_selected.connect(func(id: int):
			io["mode"] = mode_vals[id]
			_commit_field("specs", specs)
			_rebuild_current_item()
		)
		hbox2.add_child(mode_opt)
		vbox.add_child(hbox2)
		
		if cur_mode == "delayed":
			var dbox := HBoxContainer.new()
			var d_spin := SpinBox.new()
			d_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			d_spin.prefix = "Delay:"
			d_spin.step = 0.01
			d_spin.value = float(io.get("delay_hrs", 0.0))
			d_spin.value_changed.connect(func(v: float): io["delay_hrs"] = v; _commit_field("specs", specs))
			dbox.add_child(d_spin)
			var dur_spin := SpinBox.new()
			dur_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			dur_spin.prefix = "Dur:"
			dur_spin.step = 0.01
			dur_spin.value = float(io.get("duration_hrs", 1.0))
			dur_spin.value_changed.connect(func(v: float): io["duration_hrs"] = v; _commit_field("specs", specs))
			dbox.add_child(dur_spin)
			vbox.add_child(dbox)
			
	_form_vbox.add_child(row_ctr)

## Pond tank twin: Capacity Auto (terrain bathymetry) / Manual (L) and Fill Auto
## (water surface) / Manual (%). Mirrors the Pond settings modal.
func _build_pond_twin_mode_section(specs: Dictionary) -> void:
	_section("Pond twin")
	var cap_mode := str(specs.get("capacity_mode", "auto"))
	var fill_mode := str(specs.get("fill_mode", "auto"))
	var cap_row := _row_container()
	var cap_h: HBoxContainer = cap_row.get_child(0) as HBoxContainer
	cap_h.add_child(_key_label("Capacity mode"))
	var cap_opt := OptionButton.new()
	cap_opt.add_item("Auto (terrain)", 0)
	cap_opt.add_item("Manual (L)", 1)
	cap_opt.select(1 if cap_mode == "manual" else 0)
	cap_opt.focus_mode = Control.FOCUS_NONE
	cap_opt.item_selected.connect(func(idx: int) -> void:
		_commit_field("specs/capacity_mode", "manual" if idx == 1 else "auto")
		_rebuild_current_item()
	)
	cap_h.add_child(cap_opt)
	_form_vbox.add_child(cap_row)
	var fill_row := _row_container()
	var fill_h: HBoxContainer = fill_row.get_child(0) as HBoxContainer
	fill_h.add_child(_key_label("Fill mode"))
	var fill_opt := OptionButton.new()
	fill_opt.add_item("Auto (water surface)", 0)
	fill_opt.add_item("Manual (%)", 1)
	fill_opt.select(1 if fill_mode == "manual" else 0)
	fill_opt.focus_mode = Control.FOCUS_NONE
	fill_opt.item_selected.connect(func(idx: int) -> void:
		_commit_field("specs/fill_mode", "manual" if idx == 1 else "auto")
		_rebuild_current_item()
	)
	fill_h.add_child(fill_opt)
	_form_vbox.add_child(fill_row)
	if specs.has("stock_l"):
		_readonly_field("Stock (terrain)", "%.0f L" % float(specs.get("stock_l", 0.0)))
	if fill_mode == "manual":
		_num_field("Fill (0–1)", specs.get("level", 0.0), "specs/level", 0.0, 1.0, 0.01)
	_readonly_field("Hint", "T → Rain/Drain scrubs level in-world")


func _build_resource_kind_picker(specs: Dictionary) -> void:
	ResourceKinds.new().migrate_resource_specs(specs)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Resource Kind"
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.custom_minimum_size.x = 120.0
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var kinds: Array = ResourceKinds.all_kinds()
	var current: String = str(specs.get("resource_kind", "water"))
	var sel := 0
	for ki: int in kinds.size():
		var kid: String = str(kinds[ki])
		opt.add_item(ResourceKinds.display_name(kid), ki)
		if kid == current:
			sel = ki
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if _updating_form or _model == null or _item_id.is_empty():
			return
		var kind_id: String = str(kinds[idx])
		var item := _model.get_item(_item_id)
		var sub: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var old_kind := str(sub.get("resource_kind", "water"))
		sub["resource_kind"] = kind_id
		sub["capacity_unit"] = ResourceKinds.default_unit(kind_id)
		var updates: Dictionary = {"specs": sub}
		# dc_electricity swaps the single generic in/out pair for a +/- pair
		# (or vice versa) — drop any customized port geometry (rotated hub
		# ports, extra drop-to-body ports) so it doesn't linger with the
		# wrong polarity/role alongside the new topology.
		if kind_id == "dc_electricity" or old_kind == "dc_electricity":
			updates["handles"] = []
		_model.update_item(_item_id, updates)
	)
	row.add_child(opt)
	_form_vbox.add_child(row)


func _build_scene_link_section(item: Dictionary) -> void:
	_section("Place in 3D")
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var model_id := str(specs.get("model_id", ""))
	var bound_id := str(specs.get("bound_prop_id", ""))
	var path_val: String = str(specs.get("scene_device_path", item.get("device_path", "")))
	var is_placeholder := bool(specs.get("graph_placeholder", false))
	var is_ibc := bool(specs.get("ibc_tank_link", false))
	var bind := GraphEmbodiment.binding_kind(item)

	# Status chip
	var status := "No 3D model attached"
	if not bound_id.is_empty():
		var entry := ModelCatalog.find(model_id) if not model_id.is_empty() else {}
		var label := str(entry.get("label", model_id)) if not entry.is_empty() else model_id
		status = "Placed in world" + (" - %s" % label if not label.is_empty() else "")
	elif not model_id.is_empty():
		var entry2 := ModelCatalog.find(model_id)
		var label2 := str(entry2.get("label", model_id)) if not entry2.is_empty() else model_id
		status = "GLB ready - %s" % label2
	elif is_ibc:
		status = "IBC tank mesh linked"
	elif is_placeholder or bind == "scene":
		status = "Scene node linked (placeholder or device)"
	elif bind == "solar":
		status = "OSM solar array linked"
	_readonly_field("Status", status)

	# Show/hide this node's 3D twin (works even when the prop is hidden, since you
	# can't click an invisible prop in the world to un-hide it). Only when embodied.
	if not bound_id.is_empty() and _set_hidden3d_cb.is_valid():
		var show_chk := CheckBox.new()
		show_chk.text = "Show in 3D world"
		show_chk.tooltip_text = "Uncheck to hide this model from the 3D world and Site Plan (keeps the node)"
		show_chk.focus_mode = Control.FOCUS_NONE
		var hidden_now := bool(_is_hidden3d_cb.call(_item_id)) if _is_hidden3d_cb.is_valid() else false
		show_chk.button_pressed = not hidden_now  # assign before connect → no spurious emit
		show_chk.toggled.connect(func(pressed: bool) -> void:
			if not _item_id.is_empty() and _set_hidden3d_cb.is_valid():
				_set_hidden3d_cb.call(_item_id, not pressed)
		)
		_form_vbox.add_child(show_chk)

	# Bulk cleanup for the "conceptual storage not ready for 3D" case.
	if _hide_placeholder_twins_cb.is_valid():
		var bulk_btn := Button.new()
		bulk_btn.text = "Hide all placeholder twins"
		bulk_btn.tooltip_text = "Hide every generic box/tank placeholder from the 3D world + Site Plan"
		bulk_btn.flat = true
		bulk_btn.focus_mode = Control.FOCUS_NONE
		bulk_btn.pressed.connect(func() -> void:
			if _hide_placeholder_twins_cb.is_valid():
				_hide_placeholder_twins_cb.call(true)
		)
		_form_vbox.add_child(bulk_btn)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)

	if not model_id.is_empty() and _place_model_cb.is_valid():
		var place_btn := Button.new()
		place_btn.text = "Place in 3D" if bound_id.is_empty() else "Re-place in 3D"
		place_btn.tooltip_text = "Close the graph and place this node's GLB in the world"
		place_btn.focus_mode = Control.FOCUS_NONE
		place_btn.add_theme_color_override("font_color", C_PRIMARY)
		place_btn.pressed.connect(func() -> void:
			if _place_model_cb.is_valid() and not _item_id.is_empty():
				_place_model_cb.call(_item_id)
		)
		btn_row.add_child(place_btn)

		if GraphSiteLayout.has_site_coords(item) and _place_site_twin_cb.is_valid():
			var site_btn := Button.new()
			site_btn.text = "Place 3D twin at site"
			site_btn.tooltip_text = "Place/move the GLB at the Site Plan coordinates (ground level)"
			site_btn.focus_mode = Control.FOCUS_NONE
			site_btn.add_theme_color_override("font_color", C_PRIMARY)
			site_btn.pressed.connect(func() -> void:
				if _place_site_twin_cb.is_valid() and not _item_id.is_empty():
					_place_site_twin_cb.call(_item_id)
			)
			btn_row.add_child(site_btn)

		if _edit_ports_cb.is_valid():
			var ports_btn := Button.new()
			ports_btn.text = "Edit 3D ports…"
			ports_btn.tooltip_text = "Tag plugs / inlets on the model geometry for 3D conduit endpoints"
			ports_btn.focus_mode = Control.FOCUS_NONE
			ports_btn.add_theme_color_override("font_color", C_PRIMARY)
			ports_btn.pressed.connect(func() -> void:
				if _edit_ports_cb.is_valid() and not _item_id.is_empty():
					_edit_ports_cb.call(_item_id)
			)
			btn_row.add_child(ports_btn)

		var change_btn := Button.new()
		change_btn.text = "Change GLB..."
		change_btn.flat = true
		change_btn.focus_mode = Control.FOCUS_NONE
		change_btn.add_theme_color_override("font_color", C_TEXT_S)
		change_btn.add_theme_font_size_override("font_size", 10)
		change_btn.tooltip_text = "Import a different GLB/GLTF from your computer"
		change_btn.pressed.connect(_on_choose_glb_pressed)
		btn_row.add_child(change_btn)
	else:
		var add_btn := Button.new()
		add_btn.text = "Add GLB from computer..."
		add_btn.tooltip_text = "Import a .glb / .gltf and attach it to this node"
		add_btn.focus_mode = Control.FOCUS_NONE
		add_btn.add_theme_color_override("font_color", C_PRIMARY)
		add_btn.pressed.connect(_on_choose_glb_pressed)
		btn_row.add_child(add_btn)

		if _placeholder_cb.is_valid():
			var ph_btn := Button.new()
			ph_btn.text = "Use cube placeholder"
			ph_btn.flat = true
			ph_btn.focus_mode = Control.FOCUS_NONE
			ph_btn.add_theme_color_override("font_color", C_TEXT_S)
			ph_btn.add_theme_font_size_override("font_size", 10)
			ph_btn.tooltip_text = "Spawn a temporary cube in the world (no GLB)"
			ph_btn.pressed.connect(func() -> void:
				if _placeholder_cb.is_valid() and not _item_id.is_empty():
					_placeholder_cb.call(_item_id)
			)
			btn_row.add_child(ph_btn)

	_form_vbox.add_child(_wrap_margin(btn_row, 12, 6))

	if not model_id.is_empty():
		_hint_label("Attached model id: %s" % model_id)

	# Manual scene path + device_path under Advanced.
	if _advanced_section("scene_manual", "Advanced · Scene node path",
			"Manual NodePath binding for existing scene devices"):
		_text_field("Scene Node Path", path_val, "specs/scene_device_path")
		_readonly_field("device_path", str(item.get("device_path", "-")))


func _ensure_glb_file_dialog() -> void:
	if _glb_file_dialog != null and is_instance_valid(_glb_file_dialog):
		return
	_glb_file_dialog = FileDialog.new()
	_glb_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_glb_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_glb_file_dialog.filters = PackedStringArray(["*.glb ; GLB", "*.gltf ; GLTF"])
	_glb_file_dialog.title = "Attach GLB to graph node"
	_glb_file_dialog.file_selected.connect(_on_glb_file_selected)
	add_child(_glb_file_dialog)


func _on_choose_glb_pressed() -> void:
	_ensure_glb_file_dialog()
	_glb_file_dialog.popup_centered_ratio(0.6)


func _on_glb_file_selected(path: String) -> void:
	if _model == null or _item_id.is_empty():
		return
	var entry := ModelImporter.import_from_path(path)
	if entry.is_empty():
		_toast("Could not import GLB - check the file path")
		return
	var mid := str(entry.get("id", ""))
	if mid.is_empty():
		_toast("Import failed - no model id")
		return
	var item := _model.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["model_id"] = mid
	# Fresh GLB attachment - clear stale placeholder / prior prop binding.
	specs.erase("graph_placeholder")
	specs.erase("bound_prop_id")
	_model.update_item(_item_id, {"specs": specs})
	_toast("Attached “%s” - Place in 3D when ready" % str(entry.get("label", mid)))
	if _preview_refresh_cb.is_valid():
		_preview_refresh_cb.call(_item_id)
	_rebuild_current_item()


func _build_advanced_ha_twin_section(item: Dictionary) -> void:
	if not _advanced_section("ha_twin", "Advanced · Live twin (Home Assistant)",
			"Optional - mirror real HA sensors into this node in LIVE mode"):
		return
	_hint_label("Simulation does not need these links. Use them only when connected to Home Assistant.")
	_build_ha_link_section(item)


func _build_advanced_calibration_section(item: Dictionary) -> void:
	if not _advanced_section("calibrate", "Advanced · Load calibration",
			"Measure real load behavior from HA / meters"):
		return
	_build_load_calibration_section(item)


func _build_ha_link_section(item: Dictionary) -> void:
	# Section title is provided by the Advanced wrapper - keep body only.
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var links: Dictionary = (specs.get("ha_links", {}) as Dictionary)
	var live: Dictionary  = (specs.get("ha_live",  {}) as Dictionary)
	var itype: String = item.get("type", "") as String
	var roles: Array = _HA_ROLES.get(itype, []) as Array

	var edits: Dictionary = {}   # role → LineEdit
	for role_def: Dictionary in roles:
		var rid: String = role_def.get("id", "") as String
		var lbl_txt: String = role_def.get("label", rid) as String
		var unit_s: String = role_def.get("unit", "") as String
		var required: bool = bool(role_def.get("required", false))

		var title_row := HBoxContainer.new()
		title_row.add_theme_constant_override("separation", 6)
		var lbl := Label.new()
		var suffix: String = "*" if required else ""
		lbl.text = "%s%s  (%s)" % [lbl_txt, suffix, unit_s]
		lbl.add_theme_color_override("font_color", C_PRIMARY if required else C_TEXT_S)
		lbl.add_theme_font_size_override("font_size", 10)
		title_row.add_child(lbl)
		var live_entry: Dictionary = (live.get(rid, {}) as Dictionary)
		if not live_entry.is_empty():
			var live_lbl := Label.new()
			live_lbl.text = "  live: %.2f %s" % [float(live_entry.get("value", 0.0)), str(live_entry.get("unit", unit_s))]
			live_lbl.add_theme_color_override("font_color", Color(0.27, 0.9, 0.42))
			live_lbl.add_theme_font_size_override("font_size", 10)
			title_row.add_child(live_lbl)
		_form_vbox.add_child(_wrap_margin(title_row, 12, 2))

		var edit := LineEdit.new()
		var ph_override: String = role_def.get("placeholder", "") as String
		edit.placeholder_text = ph_override if not ph_override.is_empty() else "sensor.my_%s_%s" % [itype, rid]
		var saved_val: String = str(links.get(rid, ""))
		# When the placeholder IS the real entity ID (e.g. shelly4pm), treat it
		# as the default value so the field appears pre-filled rather than empty.
		edit.text = saved_val if not saved_val.is_empty() else ph_override
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_edit(edit, false)
		_form_vbox.add_child(_wrap_margin(edit, 12, 2))
		edits[rid] = edit

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var save_btn := Button.new()
	save_btn.text = "Save & Subscribe"
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.flat = true
	save_btn.add_theme_color_override("font_color", C_PRIMARY)
	save_btn.pressed.connect(_on_ha_links_save.bind(item.get("id", "") as String, edits, itype))
	btn_row.add_child(save_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear links"
	clear_btn.focus_mode = Control.FOCUS_NONE
	clear_btn.flat = true
	clear_btn.add_theme_color_override("font_color", C_AMBER)
	clear_btn.pressed.connect(_on_ha_links_clear.bind(item.get("id", "") as String, edits))
	btn_row.add_child(clear_btn)
	_form_vbox.add_child(_wrap_margin(btn_row, 12, 8))


## Shelly Pro 4PM circuit switch controls.
## Shows a row per circuit with the live state and a Toggle button that calls
## InverterBridge.toggle_shelly_output(i) via the autoload singleton.
func _build_shelly4pm_controls_section(item: Dictionary) -> void:
	_section("Circuit Switch Controls")
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var itype := str(item.get("type", "shelly4pm"))
	var nchan := clampi(int(specs.get("channel_count", 4)), 1, 8)
	if itype == "breaker_panel":
		var main_row := HBoxContainer.new()
		main_row.add_theme_constant_override("separation", 6)
		var main_lbl := Label.new()
		main_lbl.text = "Main breaker"
		main_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		main_lbl.add_theme_color_override("font_color", C_TEXT_S)
		main_row.add_child(main_lbl)
		var main_on := bool(specs.get("main_on", true))
		var main_state := Label.new()
		main_state.text = "● ON" if main_on else "○ OFF"
		main_state.add_theme_color_override("font_color",
			Color(0.27, 0.9, 0.42) if main_on else C_TEXT_M)
		main_row.add_child(main_state)
		var main_btn := Button.new()
		main_btn.text = "Toggle"
		main_btn.focus_mode = Control.FOCUS_NONE
		main_btn.flat = true
		main_btn.add_theme_color_override("font_color", C_PRIMARY)
		var capt_id := str(item.get("id", ""))
		main_btn.pressed.connect(func() -> void:
			_simulate_passthrough_flag(capt_id, "main_on"))
		main_row.add_child(main_btn)
		_form_vbox.add_child(_wrap_margin(main_row, 12, 3))
	for ci: int in nchan:
		var ci_name  := specs.get("c%d_name" % ci, "Circuit %d" % ci) as String
		var ci_on    := bool(specs.get("c%d_on" % ci, false))
		var ci_power := float(specs.get("c%d_power_w" % ci, 0.0))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		# Circuit label
		var lbl := Label.new()
		lbl.text = ci_name
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", C_TEXT_S)
		lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(lbl)

		# Wattage
		var watt_lbl := Label.new()
		watt_lbl.text = "%.0fW" % ci_power
		watt_lbl.add_theme_color_override("font_color", C_AMBER if ci_on else C_TEXT_M)
		watt_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(watt_lbl)

		# ON / OFF badge
		var state_lbl := Label.new()
		state_lbl.text = "● ON" if ci_on else "○ OFF"
		state_lbl.add_theme_color_override("font_color",
			Color(0.27, 0.9, 0.42) if ci_on else C_TEXT_M)
		state_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(state_lbl)

		# Toggle button - behaviour depends on global SimMode:
		#   LIVE     → talk to HA via InverterBridge (the real switch flips,
		#              and the linker mirrors the new state back into specs).
		#   SIMULATE → flip the simulated c%d_on bit directly so the canvas
		#              and any downstream simulation reflect the change
		#              without affecting the user's real network.
		var btn := Button.new()
		btn.text = "Toggle"
		btn.focus_mode = Control.FOCUS_NONE
		btn.flat = true
		btn.add_theme_color_override("font_color", C_PRIMARY)
		var circuit_idx := ci   # capture by value
		var captured_item_id: String = item.get("id", "") as String
		btn.pressed.connect(func() -> void:
			var sm: Node = get_node_or_null("/root/SimMode")
			var is_live: bool = sm != null and bool(sm.call("is_live"))
			var it0 := _model.get_item(captured_item_id) if _model != null else {}
			var ty0 := str(it0.get("type", ""))
			if is_live and ty0 == "shelly4pm":
				var br: Node = get_node_or_null("/root/InverterBridge")
				if br != null and br.has_method("toggle_shelly_output"):
					br.toggle_shelly_output(circuit_idx)
			else:
				_simulate_shelly_toggle(captured_item_id, circuit_idx)
		)
		row.add_child(btn)

		_form_vbox.add_child(_wrap_margin(row, 12, 3))


## Flip a Shelly 4PM / Spiderbox / breaker circuit on/off in the graph model —
## used in SIMULATE (and for non-HA passthrough types), so wired loads shed when
## the channel is OFF.
func _simulate_shelly_toggle(item_id: String, circuit_idx: int) -> void:
	_simulate_passthrough_flag(item_id, "c%d_on" % circuit_idx)


func _simulate_passthrough_flag(item_id: String, key: String) -> void:
	if _model == null or item_id.is_empty() or key.is_empty():
		return
	var it := _model.get_item(item_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = not bool(specs.get(key, false))
	_model.update_item(item_id, {"specs": specs})
	_rebuild_for_item(_model.get_item(item_id))


func _on_ha_links_save(item_id: String, edits: Dictionary, itype: String) -> void:
	if _model == null or item_id.is_empty():
		return
	var it := _model.get_item(item_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var links: Dictionary = (specs.get("ha_links", {}) as Dictionary).duplicate(true)
	var missing_required: Array[String] = []
	var roles: Array = _HA_ROLES.get(itype, []) as Array
	for role_def: Dictionary in roles:
		var rid: String = role_def.get("id", "") as String
		var edit: LineEdit = edits.get(rid, null) as LineEdit
		if edit == null:
			continue
		var val: String = edit.text.strip_edges()
		if val.is_empty():
			links.erase(rid)
			if bool(role_def.get("required", false)):
				missing_required.append(rid)
		else:
			links[rid] = val
	specs["ha_links"] = links
	_model.update_item(item_id, {"specs": specs})

	if not missing_required.is_empty():
		var psa := PackedStringArray(missing_required)
		_toast("Saved. Missing required: %s" % ", ".join(psa))
	if _ha_linker != null and _ha_linker.has_method("refresh_subscriptions"):
		_ha_linker.call("refresh_subscriptions")
	var note: String = "Linked %d sensor(s)" % links.size()
	if _ha_linker != null and _ha_linker.has_method("is_live"):
		var live_ok: bool = bool(_ha_linker.call("is_live"))
		note += "; HA %s" % ("connected" if live_ok else "offline")
	_toast(note)


func _on_ha_links_clear(item_id: String, edits: Dictionary) -> void:
	for rid: String in edits.keys():
		var e: LineEdit = edits[rid] as LineEdit
		if e != null:
			e.text = ""
	if _model == null or item_id.is_empty():
		return
	var it := _model.get_item(item_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	specs["ha_links"] = {}
	_model.update_item(item_id, {"specs": specs})
	if _ha_linker != null and _ha_linker.has_method("refresh_subscriptions"):
		_ha_linker.call("refresh_subscriptions")
	_toast("Cleared HA links")


# ---------------------------------------------------------------------------
# Load behavior calibration
# ---------------------------------------------------------------------------

const _LOAD_TYPE_OPTIONS := [
	{"key": "unknown",   "label": "Unknown",                                  "hint": "Just record min / avg / max."},
	{"key": "resistive", "label": "Resistive (heaters, LEDs, kettles)",      "hint": "Single steady wattage. 30 s is plenty."},
	{"key": "inductive", "label": "Inductive (fridges, motors, pumps)",      "hint": "Captures startup surge + run wattage. Run for several cycles for best accuracy."},
	{"key": "battery",   "label": "Battery-powered (phones, laptops, EUCs)", "hint": "Constant charge until full. Set capacity for full-charge ETA."},
	{"key": "batch",     "label": "Batch (coffee maker, oven, wash cycle)",  "hint": "Energy per batch. Run exactly one batch during the window."},
]


func _build_load_calibration_section(item: Dictionary) -> void:
	# When nested under Advanced, the wrapper already provides the title.
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var item_id: String = item.get("id", "") as String
	var current_type: String = str(specs.get("load_type", "unknown"))
	var window_s: float = float(specs.get("calibration_window_s", 30.0))
	var capacity_wh: float = float(specs.get("battery_capacity_wh", 0.0))
	var batch_output: String = str(specs.get("batch_output", ""))
	var batch_count: float = float(specs.get("batch_count", 1.0))
	var calib: Dictionary = (specs.get("load_calibration", {}) as Dictionary)

	# ---- Type dropdown ----
	var type_row := _row_container()
	var type_hbox: HBoxContainer = type_row.get_child(0)
	type_hbox.add_child(_key_label("Type"))
	var type_opt := OptionButton.new()
	type_opt.focus_mode = Control.FOCUS_NONE
	type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_opt.add_theme_font_size_override("font_size", 11)
	for i: int in _LOAD_TYPE_OPTIONS.size():
		var def: Dictionary = _LOAD_TYPE_OPTIONS[i]
		type_opt.add_item(str(def.get("label", "")), i)
		if str(def.get("key", "")) == current_type:
			type_opt.select(i)
	type_opt.item_selected.connect(func(idx: int) -> void:
		var key: String = str(_LOAD_TYPE_OPTIONS[idx].get("key", "unknown"))
		_set_spec(item_id, "load_type", key)
		# Re-render so type-specific fields appear/disappear.
		var refreshed := _model.get_item(item_id)
		if not refreshed.is_empty():
			_rebuild_for_item(refreshed)
	)
	type_hbox.add_child(type_opt)
	_form_vbox.add_child(type_row)

	# Hint label for the selected type.
	var hint_text: String = ""
	for def: Dictionary in _LOAD_TYPE_OPTIONS:
		if str(def.get("key", "")) == current_type:
			hint_text = str(def.get("hint", ""))
			break
	if not hint_text.is_empty():
		var hint := Label.new()
		hint.text = hint_text
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_color_override("font_color", C_TEXT_M)
		hint.add_theme_font_size_override("font_size", 10)
		_form_vbox.add_child(_wrap_margin(hint, 12, 4))

	# ---- Window length ----
	_num_field("Window (s)", window_s, "specs/calibration_window_s", 1.0, 86400.0, 1.0)

	# ---- Type-specific fields ----
	if current_type == "battery":
		_num_field("Battery Capacity (Wh)", capacity_wh,
			"specs/battery_capacity_wh", 0.0, 1000000.0, 1.0)
	elif current_type == "batch":
		_text_field("Batch Output", batch_output, "specs/batch_output")
		_num_field("Units / Batch", batch_count,
			"specs/batch_count", 0.001, 100000.0, 0.5)

	# ---- Live progress display ----
	var live_card := PanelContainer.new()
	var live_sb := StyleBoxFlat.new()
	live_sb.bg_color = Color(C_PANEL.r * 0.7, C_PANEL.g * 0.7, C_PANEL.b * 0.7, 1.0)
	live_sb.set_border_width_all(1)
	live_sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.18)
	live_sb.set_corner_radius_all(4)
	live_sb.content_margin_left   = 10.0
	live_sb.content_margin_right  = 10.0
	live_sb.content_margin_top    = 6.0
	live_sb.content_margin_bottom = 6.0
	live_card.add_theme_stylebox_override("panel", live_sb)
	var live_box := VBoxContainer.new()
	live_box.add_theme_constant_override("separation", 2)
	live_card.add_child(live_box)

	_cal_status_lbl    = _cal_make_label("Idle.", C_TEXT_S, 11)
	_cal_remaining_lbl = _cal_make_label("Time remaining: -", C_TEXT_M, 10)
	_cal_live_lbl      = _cal_make_label("Live: - W", C_TEXT, 10)
	_cal_avg_lbl       = _cal_make_label("Average: - W", C_TEXT, 10)
	_cal_peak_lbl      = _cal_make_label("Peak: - W", C_TEXT, 10)
	live_box.add_child(_cal_status_lbl)
	live_box.add_child(_cal_remaining_lbl)
	live_box.add_child(_cal_live_lbl)
	live_box.add_child(_cal_avg_lbl)
	live_box.add_child(_cal_peak_lbl)

	# ---- Live waveform graph ----
	_cal_graph = _CAL_GRAPH_SCRIPT.new()
	_cal_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cal_graph.custom_minimum_size = Vector2(0, 110)
	live_box.add_child(_cal_graph)
	# If a calibration is already running for this same item, seed the graph
	# with the current buffer so it appears immediately.  The next progress
	# tick (within one frame) will refresh statistics + the now-line.
	if _calibrator != null and _calibrator.is_running() \
			and _calibrator.current_item_id() == item_id:
		_cal_graph.set_data(_calibrator.get_samples(),
			_calibrator.get_duration_s(), 0.0, 0.0, 0.0, 0.0)

	_form_vbox.add_child(_wrap_margin(live_card, 12, 4))

	# ---- Action button ----
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	_cal_btn = Button.new()
	_cal_btn.focus_mode = Control.FOCUS_NONE
	_cal_btn.flat = true
	_cal_btn.add_theme_color_override("font_color", C_PRIMARY)
	_cal_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cal_btn.text = _calibrate_button_text(item_id)
	_cal_btn.pressed.connect(_on_calibrate_pressed.bind(item_id))
	btn_row.add_child(_cal_btn)
	_form_vbox.add_child(_wrap_margin(btn_row, 12, 4))

	# ---- Last-calibration summary ----
	if not calib.is_empty():
		_render_calibration_summary(calib)


func _cal_make_label(txt: String, color: Color, fsize: int) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", fsize)
	return l


func _calibrate_button_text(item_id: String) -> String:
	if _calibrator != null and _calibrator.is_running() \
			and _calibrator.current_item_id() == item_id:
		return "■  Stop calibration"
	return "▶  Calibrate Load"


func _render_calibration_summary(calib: Dictionary) -> void:
	var ctype: String = str(calib.get("type", "unknown"))
	_section("Calibration Result (%s)" % ctype.capitalize())

	# Embedded saved waveform trace (if any).
	var trace: Array = (calib.get("trace", []) as Array)
	if not trace.is_empty():
		var graph: Control = _CAL_GRAPH_SCRIPT.new()
		graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		graph.custom_minimum_size = Vector2(0, 110)
		_form_vbox.add_child(_wrap_margin(graph, 12, 4))
		graph.set_data(trace,
			float(calib.get("duration_s", 30.0)),
			float(calib.get("avg_w", 0.0)),
			float(calib.get("peak_w", 0.0)),
			0.0, -1.0)

	var ts: int = int(calib.get("calibrated_at", 0))
	var dt := Time.get_datetime_string_from_unix_time(ts) if ts > 0 else "-"
	_readonly_field("Calibrated", dt)
	_readonly_field("Samples",    str(int(calib.get("sample_count", 0))))
	_readonly_field("Window",     "%.0f s" % float(calib.get("duration_s", 0.0)))
	_readonly_field("Min / Avg / Max",
		"%.0f / %.0f / %.0f W" % [
			float(calib.get("min_w", 0.0)),
			float(calib.get("avg_w", 0.0)),
			float(calib.get("max_w", 0.0)),
		])
	match ctype:
		"resistive":
			_readonly_field("Steady draw", "%.0f W" % float(calib.get("steady_w", 0.0)))
		"inductive":
			_readonly_field("Run draw",     "%.0f W" % float(calib.get("run_w", 0.0)))
			_readonly_field("Surge draw",   "%.0f W" % float(calib.get("surge_w", 0.0)))
			_readonly_field("Surge length", "%.2f s" % float(calib.get("surge_duration_s", 0.0)))
		"battery":
			_readonly_field("Charge draw",  "%.0f W" % float(calib.get("charge_w", 0.0)))
			var cap_wh := float(calib.get("capacity_wh", 0.0))
			if cap_wh > 0.0:
				_readonly_field("Capacity",     "%.0f Wh" % cap_wh)
				var eta_s := float(calib.get("estimated_full_s", 0.0))
				_readonly_field("Full-charge ETA", _format_duration(eta_s))
		"batch":
			_readonly_field("Energy / batch", "%.1f Wh" % float(calib.get("batch_energy_wh", 0.0)))
			_readonly_field("Duration",       _format_duration(float(calib.get("batch_duration_s", 0.0))))
			var bo := str(calib.get("batch_output", ""))
			if not bo.is_empty():
				_readonly_field("Output",     bo)
			var bc := float(calib.get("batch_count", 0.0))
			if bc > 0.0:
				_readonly_field("Wh / unit",  "%.2f" % float(calib.get("wh_per_unit", 0.0)))


func _format_duration(s: float) -> String:
	if s <= 0.0:
		return "-"
	if s < 60.0:
		return "%.0f s" % s
	if s < 3600.0:
		return "%.1f min" % (s / 60.0)
	return "%.2f h" % (s / 3600.0)


func _on_calibrate_pressed(item_id: String) -> void:
	_ensure_calibrator()
	if _calibrator.is_running():
		_calibrator.cancel()
		return
	if _model == null:
		return
	var item := _model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var links: Dictionary = (specs.get("ha_links", {}) as Dictionary)
	var power_eid: String = str(links.get("power", ""))
	if power_eid.is_empty():
		_toast("Link a 'Live Power' HA sensor first.")
		return
	var ok: bool = _calibrator.start({
		"item_id":         item_id,
		"load_type":       str(specs.get("load_type", "unknown")),
		"duration_s":      float(specs.get("calibration_window_s", 30.0)),
		"power_role":      "power",
		"switch_entity":   str(links.get("switch", "")),
		"capacity_wh":     float(specs.get("battery_capacity_wh", 0.0)),
		"batch_output":    str(specs.get("batch_output", "")),
		"batch_count":     float(specs.get("batch_count", 1.0)),
	})
	if not ok:
		_toast("Calibrator could not start.")
		return
	if _cal_btn != null:
		_cal_btn.text = "■  Stop calibration"
	if _cal_status_lbl != null:
		_cal_status_lbl.text = "Recording..."
		_cal_status_lbl.add_theme_color_override("font_color", C_AMBER)


func _ensure_calibrator() -> void:
	if _calibrator != null and is_instance_valid(_calibrator):
		return
	_calibrator = _CALIBRATOR_SCRIPT.new()
	_calibrator.name = "LoadCalibrator"
	add_child(_calibrator)
	_calibrator.setup(_model, _ha_linker)
	_calibrator.progress.connect(_on_calibrator_progress)
	_calibrator.completed.connect(_on_calibrator_completed)
	_calibrator.cancelled.connect(_on_calibrator_cancelled)


func _on_calibrator_progress(remaining_s: float, samples: int,
		current_w: float, avg_w: float, peak_w: float) -> void:
	if _cal_remaining_lbl != null:
		_cal_remaining_lbl.text = "Time remaining: %s   (%d samples)" % [
			_format_duration(remaining_s), samples
		]
	if _cal_live_lbl != null:
		_cal_live_lbl.text = "Live: %.1f W" % current_w
	if _cal_avg_lbl != null:
		_cal_avg_lbl.text = "Average: %.1f W" % avg_w
	if _cal_peak_lbl != null:
		_cal_peak_lbl.text = "Peak: %.1f W" % peak_w
	if _cal_graph != null and is_instance_valid(_cal_graph) \
			and _calibrator != null:
		var dur: float = _calibrator.get_duration_s()
		var elapsed: float = maxf(0.0, dur - remaining_s)
		_cal_graph.set_data(_calibrator.get_samples(),
			dur, avg_w, peak_w, current_w, elapsed)


func _on_calibrator_completed(item_id: String, _results: Dictionary) -> void:
	_toast("Calibration complete.")
	if _model == null:
		return
	var it := _model.get_item(item_id)
	if not it.is_empty() and item_id == _item_id:
		_rebuild_for_item(it)


func _on_calibrator_cancelled(_item_id: String) -> void:
	if _cal_status_lbl != null:
		_cal_status_lbl.text = "Cancelled."
		_cal_status_lbl.add_theme_color_override("font_color", C_TEXT_M)
	if _cal_btn != null:
		_cal_btn.text = "▶  Calibrate Load"


## Tiny helper used by the load-type dropdown to commit a single spec field
## without rebuilding the entire form.
func _set_spec(item_id: String, key: String, value: Variant) -> void:
	if _model == null or item_id.is_empty():
		return
	var it := _model.get_item(item_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = value
	_model.update_item(item_id, {"specs": specs})


func _build_compound_section(item: Dictionary) -> void:
	_section("Nested Graph")
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var kind: String = str(specs.get("compound_kind", ""))
	_readonly_field("Child nodes", str(int(specs.get("child_count", 0))))
	_readonly_field("Input ports", str(int(specs.get("port_in_count", 0))))
	_readonly_field("Output ports", str(int(specs.get("port_out_count", 0))))
	if kind == "array":
		_readonly_field("Kind", "Solar Array")
		_readonly_field("Topology", str(specs.get("array_topology", "-")))
		_readonly_field("Panels", str(int(specs.get("array_panel_units", specs.get("child_count", 0)))))
		_readonly_field("Vmp / Voc", "%.1fV / %.1fV" % [float(specs.get("array_equiv_vmp", 0.0)), float(specs.get("array_equiv_voc", 0.0))])
		_readonly_field("Imp / Isc", "%.1fA / %.1fA" % [float(specs.get("array_equiv_imp", 0.0)), float(specs.get("array_equiv_isc", 0.0))])
		_readonly_field("Array Power", "%.0fW" % float(specs.get("array_equiv_wmp", 0.0)))
		_build_array_module_dims_editor(item)
		_build_array_bulk_panel_editor(item)
	elif kind == "battery_bank":
		_readonly_field("Kind", "Battery Bank")
	elif kind == "load_group":
		_readonly_field("Kind", "Load Group")
		_readonly_field("Combined draw", "%.0f W" % float(specs.get("avg_watts", 0.0)))
		_readonly_field("Rated max", "%.0f W" % float(specs.get("max_watts", 0.0)))
		_readonly_field("Summary", str(specs.get("summary", "")))
	# Promoted ports (the super-node's external interface) with live net flow.
	if kind == "":
		_build_exposed_ports_editor(item)
	var def_id := str(specs.get("definition_id", ""))
	var is_component := not def_id.is_empty()
	var has_identity := is_component \
		or not str(specs.get("bound_prop_id", "")).is_empty() \
		or not str(specs.get("starshade_tag", "")).is_empty() \
		or (bool(specs.get("node_banner", false)) and not str(specs.get("model_id", "")).is_empty())
	var enter_label := "Expand"
	if kind == "array":
		enter_label = "Expand → Panels"
	elif kind == "battery_bank" or bool(specs.get("display_as_battery", false)) \
			or def_id.contains("battery_bank"):
		enter_label = "Expand → Batteries"
	elif kind == "load_group":
		enter_label = "Expand → Loads"
	elif is_component:
		enter_label = "Expand (keep identity)"
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	var enter_btn := Button.new()
	enter_btn.text = enter_label
	enter_btn.tooltip_text = "Open children inside this super-node. Collapse (Esc) returns without losing identity or 3D binding."
	enter_btn.focus_mode = Control.FOCUS_NONE
	enter_btn.flat = true
	enter_btn.add_theme_color_override("font_color", C_PRIMARY)
	enter_btn.pressed.connect(func():
		if _compound_enter_cb.is_valid():
			_compound_enter_cb.call(item.get("id", "") as String)
	)
	hbox.add_child(enter_btn)
	if has_identity:
		var explode_btn := Button.new()
		explode_btn.text = "Explode…"
		explode_btn.tooltip_text = "Destructive: dissolves the shell and drops StarShade / 3D binding. Prefer Expand/Collapse."
		explode_btn.focus_mode = Control.FOCUS_NONE
		explode_btn.flat = true
		explode_btn.add_theme_color_override("font_color", C_AMBER)
		explode_btn.pressed.connect(func():
			if _compound_explode_cb.is_valid():
				_compound_explode_cb.call(item.get("id", "") as String)
			elif _compound_ungroup_cb.is_valid():
				_compound_ungroup_cb.call(item.get("id", "") as String)
		)
		hbox.add_child(explode_btn)
	else:
		var ungroup_btn := Button.new()
		ungroup_btn.text = "Ungroup"
		ungroup_btn.focus_mode = Control.FOCUS_NONE
		ungroup_btn.flat = true
		ungroup_btn.add_theme_color_override("font_color", C_AMBER)
		ungroup_btn.pressed.connect(func():
			if _compound_ungroup_cb.is_valid():
				_compound_ungroup_cb.call(item.get("id", "") as String)
		)
		hbox.add_child(ungroup_btn)
	if kind == "":
		var cid := str(item.get("id", ""))
		var is_instance := not str((item.get("specs", {}) as Dictionary).get("definition_id", "")).is_empty()
		var save_btn := Button.new()
		save_btn.text = "Save as Component"
		save_btn.focus_mode = Control.FOCUS_NONE
		save_btn.flat = true
		save_btn.add_theme_color_override("font_color", C_PRIMARY)
		save_btn.pressed.connect(func():
			if _component_save_cb.is_valid():
				_component_save_cb.call(cid)
			else:
				_save_compound_as_preset(item))
		hbox.add_child(save_btn)
		if is_instance:
			var uniq_btn := Button.new()
			uniq_btn.text = "Make Unique"
			uniq_btn.focus_mode = Control.FOCUS_NONE
			uniq_btn.flat = true
			uniq_btn.add_theme_color_override("font_color", C_AMBER)
			uniq_btn.pressed.connect(func():
				if _component_make_unique_cb.is_valid():
					_component_make_unique_cb.call(cid))
			hbox.add_child(uniq_btn)
	_form_vbox.add_child(row)
	if kind == "" and not str((item.get("specs", {}) as Dictionary).get("definition_id", "")).is_empty():
		var lbl := Label.new()
		lbl.text = "⟳ Linked component — edits sync to all instances"
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", C_TEXT_M)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_form_vbox.add_child(lbl)


## Serialize a user super-node's child subgraph into the user library as a
## reusable subgraph-template preset (mirror of the built-in COMPOUNDS entries).
func _save_compound_as_preset(item: Dictionary) -> void:
	if _model == null:
		return
	var child_scope := str(item.get("child_scope_id", ""))
	if child_scope.is_empty():
		return
	var kids: Array = _model.get_items_in_scope(child_scope)
	if kids.is_empty():
		return
	for k_v in kids:
		if str((k_v as Dictionary).get("type", "")) == "compound":
			if _toast_cb.is_valid():
				_toast_cb.call("Ungroup nested super-nodes before saving as preset")
			return
	var cx := float(item.get("x", 0.0))
	var cy := float(item.get("y", 0.0))
	var id_map: Dictionary = {}
	var tpl_items: Array = []
	var i := 0
	for k_v in kids:
		var k := k_v as Dictionary
		var lid := "n%d" % i
		i += 1
		id_map[str(k.get("id", ""))] = lid
		tpl_items.append({
			"local_id": lid, "type": str(k.get("type", "")),
			"dx": float(k.get("x", 0.0)) - cx, "dy": float(k.get("y", 0.0)) - cy,
			"specs": (k.get("specs", {}) as Dictionary).duplicate(true),
		})
	var tpl_conns: Array = []
	for c_v in _model.get_connections_in_scope(child_scope):
		var c := c_v as Dictionary
		var s := str(id_map.get(str(c.get("source_item_id", "")), ""))
		var t := str(id_map.get(str(c.get("target_item_id", "")), ""))
		if s.is_empty() or t.is_empty():
			continue
		tpl_conns.append({
			"source": s, "source_handle": str(c.get("source_handle_id", "")),
			"target": t, "target_handle": str(c.get("target_handle_id", "")),
			"polarity": c.get("polarity", "ac"),
			"resource_type": c.get("resource_type", ""),
		})
	var tpl_eps: Array = []
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	for ep_v in (specs.get("exposed_ports", []) as Array):
		var ep := ep_v as Dictionary
		var child_local := str(id_map.get(str(ep.get("child_item_id", "")), ""))
		if child_local.is_empty():
			continue
		tpl_eps.append({
			"handle_id": str(ep.get("handle_id", "")), "child": child_local,
			"child_handle": str(ep.get("child_handle_id", "")),
			"direction": str(ep.get("direction", "in")),
			"polarity": str(ep.get("polarity", "ac")),
			"kind": str(ep.get("kind", "")), "label": str(ep.get("label", "")),
		})
	var name_s := str(specs.get("name", "Super Node"))
	var preset := {
		"type": "compound", "label": name_s, "icon": "🧩",
		"width": float(item.get("width", 200.0)), "height": float(item.get("height", 130.0)),
		"specs": {"name": name_s, "compound_kind": "",
			"summary": str(specs.get("summary", "Nested graph"))},
		"subgraph": {"items": tpl_items, "connections": tpl_conns, "exposed_ports": tpl_eps},
	}
	ComponentPresets.save_user_preset("supernodes", preset)
	if _toast_cb.is_valid():
		_toast_cb.call("Saved '%s' to Super-nodes library" % name_s)


## Lists each promoted port of a generic super-node with its direction, resource
## kind, live net flow (read off the real boundary wire), an editable label, and
## a remove button (drops the port + its handle + boundary wire).
## For a node inside a super-node, list its handles with an Expose/Hide toggle
## that promotes (or unpromotes) that port on the enclosing compound.
func _build_promote_ports_section(item: Dictionary) -> void:
	if _model == null:
		return
	var scope_id := str(item.get("scope_id", "root"))
	if scope_id == "root":
		return
	var sc: Dictionary = _model.get_scope(scope_id)
	var owner := str(sc.get("owner_compound_id", ""))
	if owner.is_empty():
		return
	var comp := _model.get_item(owner)
	if comp.is_empty() or not GraphNesting.is_transparent_compound(comp):
		return
	var handles: Array = item.get("handles", []) as Array
	if handles.is_empty():
		return
	var iid := str(item.get("id", ""))
	var eps: Array = (comp.get("specs", {}) as Dictionary).get("exposed_ports", []) as Array
	_section("Promote to Super-node")
	for h_v in handles:
		var h := h_v as Dictionary
		var hid := str(h.get("id", ""))
		if hid.is_empty():
			continue
		var already := ""
		for ep_v in eps:
			var ep := ep_v as Dictionary
			if str(ep.get("child_item_id", "")) == iid and str(ep.get("child_handle_id", "")) == hid:
				already = str(ep.get("handle_id", ""))
				break
		var row := _row_container()
		var hbox: HBoxContainer = row.get_child(0)
		hbox.add_child(_key_label(hid))
		var btn := Button.new()
		btn.focus_mode = Control.FOCUS_NONE
		btn.flat = true
		if already.is_empty():
			btn.text = "Expose"
			btn.add_theme_color_override("font_color", C_PRIMARY)
			btn.pressed.connect(func(): _expose_child_port(owner, iid, h))
		else:
			btn.text = "Hide"
			btn.add_theme_color_override("font_color", C_AMBER)
			var promoted := already
			btn.pressed.connect(func(): _remove_exposed_port(owner, promoted))
		hbox.add_child(btn)
		_form_vbox.add_child(row)


## Infer in/out when promoting a child handle. Controllers' acOutput (and similar
## AC source ports) have no explicit direction field — defaulting to "in" put
## them on the top edge and broke supernode AC wiring UX.
func _infer_expose_direction(handle: Dictionary) -> String:
	var explicit := str(handle.get("direction", "")).to_lower()
	if explicit == "in" or explicit == "out":
		return explicit
	var hid := str(handle.get("id", "")).to_lower()
	var pol := str(handle.get("polarity", "")).to_lower()
	# Known AC / DC source ports.
	if hid in ["acoutput", "acoutputleft", "acoutputtop", "acoutputbottom",
			"ac_out", "output", "positive", "negative", "pvpositive", "pvnegative"]:
		return "out"
	if hid.begins_with("out_") or hid.begins_with("circuit_"):
		return "out"
	if hid in ["power_in", "ac_in", "input", "pv_in"]:
		return "in"
	if hid.begins_with("in_") or hid.begins_with("res_in_"):
		return "in"
	if hid.begins_with("res_out_"):
		return "out"
	# Fall back to geometry: bottom half → out, top half → in.
	var ry := float(handle.get("ry", 0.0))
	if ry >= 0.6:
		return "out"
	if pol == "ac" and ry >= 0.5:
		return "out"
	return "in"


## Add a new promoted port on `compound_id` fronting (child_id, handle).
func _expose_child_port(compound_id: String, child_id: String, handle: Dictionary) -> void:
	if _model == null:
		return
	var comp := _model.get_item(compound_id)
	if comp.is_empty():
		return
	var specs: Dictionary = (comp.get("specs", {}) as Dictionary).duplicate(true)
	var eps: Array = (specs.get("exposed_ports", []) as Array).duplicate(true)
	var pol := str(handle.get("polarity", "ac"))
	var direction := _infer_expose_direction(handle)
	var base := "%s_%s" % [direction, pol]
	var idx := 1
	var new_hid := "%s_%d" % [base, idx]
	var existing: Dictionary = {}
	for ep_v in eps:
		existing[str((ep_v as Dictionary).get("handle_id", ""))] = true
	while existing.has(new_hid):
		idx += 1
		new_hid = "%s_%d" % [base, idx]
	eps.append({
		"handle_id": new_hid,
		"child_item_id": child_id,
		"child_handle_id": str(handle.get("id", "")),
		"polarity": pol,
		"kind": str(handle.get("resource_kind", "")),
		"label": "",
		"direction": direction,
	})
	specs["exposed_ports"] = eps
	var handles: Array = (comp.get("handles", []) as Array).duplicate(true)
	handles.append({
		"id": new_hid, "polarity": pol, "direction": direction,
		"rx": 0.5, "ry": 0.0 if direction == "in" else 1.0,
	})
	var in_n := 0
	var out_n := 0
	for hh in handles:
		if str((hh as Dictionary).get("direction", "")) == "out":
			out_n += 1
		else:
			in_n += 1
	specs["port_in_count"] = in_n
	specs["port_out_count"] = out_n
	_model.update_item(compound_id, {"specs": specs, "handles": handles})
	_model.changed.emit("reset")


func _build_exposed_ports_editor(item: Dictionary) -> void:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var eps: Array = specs.get("exposed_ports", []) as Array
	if eps.is_empty():
		return
	_section("Promoted Ports")
	var compound_id := str(item.get("id", ""))
	var scope_id := str(item.get("scope_id", "root"))
	for ep_v in eps:
		var ep := ep_v as Dictionary
		var hid := str(ep.get("handle_id", ""))
		var dir := "→ out" if str(ep.get("direction", "in")) == "out" else "in →"
		var kind_s := str(ep.get("kind", ""))
		var flow := _exposed_port_flow(compound_id, hid, scope_id)
		var label := str(ep.get("label", ""))
		if label.is_empty():
			label = hid
		var row := _row_container()
		var hbox: HBoxContainer = row.get_child(0)
		hbox.add_child(_key_label("%s %s" % [dir, ("· " + kind_s) if not kind_s.is_empty() else ""]))
		var name_edit := LineEdit.new()
		name_edit.text = label
		name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_edit.text_submitted.connect(func(t: String):
			_rename_exposed_port(compound_id, hid, t))
		name_edit.focus_exited.connect(func():
			_rename_exposed_port(compound_id, hid, name_edit.text))
		hbox.add_child(name_edit)
		if flow > 0.001:
			var flbl := Label.new()
			flbl.text = "%.1f" % flow
			flbl.add_theme_color_override("font_color", C_PRIMARY)
			hbox.add_child(flbl)
		var rm := Button.new()
		rm.text = "✕"
		rm.focus_mode = Control.FOCUS_NONE
		rm.flat = true
		rm.add_theme_color_override("font_color", C_AMBER)
		rm.pressed.connect(func():
			_remove_exposed_port(compound_id, hid))
		hbox.add_child(rm)
		_form_vbox.add_child(row)


func _exposed_port_flow(compound_id: String, handle_id: String, scope_id: String) -> float:
	if _model == null:
		return 0.0
	for conn: Dictionary in _model.get_connections_in_scope(scope_id):
		if (str(conn.get("source_item_id", "")) == compound_id and str(conn.get("source_handle_id", "")) == handle_id) \
				or (str(conn.get("target_item_id", "")) == compound_id and str(conn.get("target_handle_id", "")) == handle_id):
			return absf(float(conn.get("flow_rate", 0.0)))
	return 0.0


func _rename_exposed_port(compound_id: String, handle_id: String, new_label: String) -> void:
	if _model == null:
		return
	var it := _model.get_item(compound_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var eps: Array = (specs.get("exposed_ports", []) as Array).duplicate(true)
	for ep_v in eps:
		var ep := ep_v as Dictionary
		if str(ep.get("handle_id", "")) == handle_id:
			ep["label"] = new_label
	specs["exposed_ports"] = eps
	_model.update_item(compound_id, {"specs": specs})


func _remove_exposed_port(compound_id: String, handle_id: String) -> void:
	if _model == null:
		return
	var it := _model.get_item(compound_id)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var eps: Array = []
	for ep_v in (specs.get("exposed_ports", []) as Array):
		if str((ep_v as Dictionary).get("handle_id", "")) != handle_id:
			eps.append(ep_v)
	specs["exposed_ports"] = eps
	var handles: Array = []
	for h_v in (it.get("handles", []) as Array):
		if str((h_v as Dictionary).get("id", "")) != handle_id:
			handles.append(h_v)
	var in_n := 0
	var out_n := 0
	for h_v in handles:
		if str((h_v as Dictionary).get("direction", "")) == "out":
			out_n += 1
		else:
			in_n += 1
	specs["port_in_count"] = in_n
	specs["port_out_count"] = out_n
	_model.update_item(compound_id, {"specs": specs, "handles": handles})
	for conn: Dictionary in _model.connections_for_item(compound_id):
		if (str(conn.get("source_item_id", "")) == compound_id and str(conn.get("source_handle_id", "")) == handle_id) \
				or (str(conn.get("target_item_id", "")) == compound_id and str(conn.get("target_handle_id", "")) == handle_id):
			_model.remove_connection(str(conn.get("id", "")))
	_model.changed.emit("reset")


func _build_array_module_dims_editor(item: Dictionary) -> void:
	## Leaf OSM-style arrays (no nested panel children) expose module geometry so
	## the player can re-tile by area. Nested arrays keep the bulk panel editor.
	var panel_ids := _collect_compound_panel_ids(item)
	if not panel_ids.is_empty():
		return
	_section("Module Dimensions (Auto-tile)")
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var mount_opt := OptionButton.new()
	mount_opt.focus_mode = Control.FOCUS_NONE
	var mount_ids: Array[String] = SolarArrayBuilder.MOUNT_STYLES
	var cur_mount := SolarArrayBuilder.resolve_mount_style(
		str(specs.get("mount_style", SolarArrayBuilder.MOUNT_ROOF)))
	var cur_idx := 0
	for i in mount_ids.size():
		var mid := mount_ids[i]
		var label := str(SolarArrayBuilder.mount_defaults(mid).get("label", mid))
		mount_opt.add_item(label)
		if mid == cur_mount:
			cur_idx = i
	mount_opt.select(cur_idx)
	var mount_row := _row_container()
	var mount_hbox: HBoxContainer = mount_row.get_child(0)
	mount_hbox.add_child(_key_label("Mount style"))
	mount_opt.size_flags_horizontal = Control.SIZE_SHRINK_END
	mount_hbox.add_child(mount_opt)
	_form_vbox.add_child(mount_row)
	var w_sb := _num_input_row("Panel width (m)", float(specs.get("panel_w_m", SolarArrayBuilder.PANEL_W)), 0.2, 4.0, 0.01)
	var h_sb := _num_input_row("Panel height (m)", float(specs.get("panel_h_m", SolarArrayBuilder.PANEL_H)), 0.2, 4.0, 0.01)
	var watts_sb := _num_input_row("Panel watts", float(specs.get("wmp", SolarArrayBuilder.PANEL_WATTS)), 1.0, 1000.0, 1.0)
	var gap_sb := _num_input_row("Row gap (m)", float(specs.get("row_gap_m", SolarArrayBuilder.ROW_GAP)), 0.0, 2.0, 0.01)
	var voc_sb := _num_input_row("Panel Voc (V)", float(specs.get("voc", SolarArrayBuilder.PANEL_VOC)), 1.0, 100.0, 0.1)
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	var btn := Button.new()
	btn.text = "Retile from footprint"
	btn.focus_mode = Control.FOCUS_NONE
	btn.flat = true
	btn.add_theme_color_override("font_color", C_PRIMARY)
	btn.pressed.connect(func():
		var mstyle := mount_ids[mount_opt.selected] if mount_opt.selected >= 0 else cur_mount
		_retile_array_from_dims(item, {
			"panel_w_m": w_sb.value,
			"panel_h_m": h_sb.value,
			"panel_watts": watts_sb.value,
			"row_gap_m": gap_sb.value,
			"voc": voc_sb.value,
			"mount_style": mstyle,
		})
	)
	hbox.add_child(btn)
	_form_vbox.add_child(row)


func _retile_array_from_dims(item: Dictionary, dims: Dictionary) -> void:
	if _model == null or item.is_empty():
		return
	var item_id := str(item.get("id", ""))
	var sp: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var spec := SolarArrayBuilder.resolve_panel_spec(dims)
	sp["panel_w_m"] = float(spec["panel_w_m"])
	sp["panel_h_m"] = float(spec["panel_h_m"])
	sp["row_gap_m"] = float(spec["row_gap_m"])
	sp["gap_x_m"] = float(spec["gap_x_m"])
	sp["wmp"] = float(spec["panel_watts"])
	sp["voc"] = float(spec["voc"])
	sp["vmp"] = float(spec["vmp"])
	sp["isc"] = float(spec["isc"])
	sp["imp"] = float(spec["imp"])
	if dims.has("mount_style"):
		var mstyle := SolarArrayBuilder.resolve_mount_style(str(dims["mount_style"]))
		sp["mount_style"] = mstyle
		var mdefs := SolarArrayBuilder.mount_defaults(mstyle)
		sp["tilt_deg"] = float(mdefs["tilt_deg"])
	var count := int(sp.get("array_panel_units", sp.get("panel_count", 0)))
	var foot: Variant = sp.get("footprint_xz", [])
	var poly := PackedVector2Array()
	if foot is Array:
		for p in foot as Array:
			if p is Array and (p as Array).size() >= 2:
				poly.append(Vector2(float((p as Array)[0]), float((p as Array)[1])))
	if poly.size() >= 3:
		var tilt := float(sp.get("tilt_deg", 35.0))
		count = SolarArrayBuilder.count_panels_for_footprint(poly, tilt, spec)
	sp["panel_count"] = count
	sp["array_panel_units"] = count
	# Generous Voc budget when no controller is bound; wire/picker re-ranks later.
	var topo := SolarArrayIntelligence.best_series_parallel(count, float(spec["voc"]), 500.0)
	var equiv := SolarArrayIntelligence.build_array_equiv_specs(
			count, float(spec["panel_watts"]), float(spec["voc"]),
			float(spec["vmp"]), float(spec["imp"]), float(spec["isc"]), topo)
	for k in equiv.keys():
		sp[k] = equiv[k]
	sp["summary"] = "%s  •  %.0fW  %.1fV  %.1fA" % [
		str(equiv.get("array_topology", "Array")),
		float(equiv.get("array_equiv_wmp", 0.0)),
		float(equiv.get("array_equiv_vmp", 0.0)),
		float(equiv.get("array_equiv_imp", 0.0)),
	]
	_model.update_item(item_id, {"specs": sp})
	_toast("Retiled array: %d panels @ %.0f W" % [count, float(spec["panel_watts"])])
	_rebuild_current_item()


func _build_array_bulk_panel_editor(item: Dictionary) -> void:
	_section("Panel Template (Bulk Edit)")
	var panel_ids := _collect_compound_panel_ids(item)
	if panel_ids.is_empty():
		_readonly_field("Nested panels", "none (leaf array — use Module Dimensions)")
		return
	_readonly_field("Panels Found", str(panel_ids.size()))
	var first_panel := _model.get_item(panel_ids[0] as String)
	var first_specs: Dictionary = first_panel.get("specs", {}) as Dictionary
	var wmp_sb := _num_input_row("Peak Power (W)", float(first_specs.get("wmp", 220.0)), 0.0, 5000.0, 1.0)
	var voc_sb := _num_input_row("V open-circuit", float(first_specs.get("voc", 50.0)), 0.0, 600.0, 0.1)
	var vmp_sb := _num_input_row("V at MPP", float(first_specs.get("vmp", 41.0)), 0.0, 600.0, 0.1)
	var isc_sb := _num_input_row("I short-circuit (A)", float(first_specs.get("isc", 6.2)), 0.0, 50.0, 0.01)
	var imp_sb := _num_input_row("I at MPP (A)", float(first_specs.get("imp", 5.4)), 0.0, 50.0, 0.01)
	var cost_sb := _num_input_row("Unit Cost ($)", float(first_specs.get("cost", 0.0)), 0.0, 99999.0, 1.0)
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	var btn := Button.new()
	btn.text = "Apply To All Panels In Array"
	btn.focus_mode = Control.FOCUS_NONE
	btn.flat = true
	btn.add_theme_color_override("font_color", C_PRIMARY)
	btn.pressed.connect(func():
		var template := {
			"wmp": wmp_sb.value,
			"voc": voc_sb.value,
			"vmp": vmp_sb.value,
			"isc": isc_sb.value,
			"imp": imp_sb.value,
			"cost": cost_sb.value,
		}
		_apply_panel_template_to_array(item, template)
	)
	hbox.add_child(btn)
	_form_vbox.add_child(row)


func _num_input_row(label: String, value: float,
		min_v: float, max_v: float, step: float) -> SpinBox:
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	hbox.add_child(_key_label(label))
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = value
	sb.rounded = false
	sb.custom_minimum_size = Vector2(92.0, 0.0)
	sb.size_flags_horizontal = Control.SIZE_SHRINK_END
	_style_edit(sb.get_line_edit(), true)
	sb.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(sb)
	_form_vbox.add_child(row)
	return sb


func _collect_compound_panel_ids(compound_item: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if _model == null or compound_item.is_empty():
		return out
	var root_scope_id: String = str(compound_item.get("child_scope_id", ""))
	if root_scope_id.is_empty():
		return out
	var seen_scopes: Dictionary = {}
	var stack: Array[String] = []
	stack.append(root_scope_id)
	while not stack.is_empty():
		var scope_id: String = stack.pop_back()
		if seen_scopes.has(scope_id):
			continue
		seen_scopes[scope_id] = true
		for it in _model.get_items_in_scope(scope_id):
			var iid: String = str(it.get("id", ""))
			var itype: String = str(it.get("type", ""))
			if itype == "panel" and not bool(it.get("is_virtual", false)):
				out.append(iid)
			elif itype == "compound":
				var child_scope_id: String = str(it.get("child_scope_id", ""))
				if not child_scope_id.is_empty():
					stack.append(child_scope_id)
	return out


func _apply_panel_template_to_array(compound_item: Dictionary, template: Dictionary) -> void:
	if _model == null or compound_item.is_empty():
		return
	var panel_ids := _collect_compound_panel_ids(compound_item)
	if panel_ids.is_empty():
		_toast("No real panel nodes found in this array")
		return
	for panel_id: String in panel_ids:
		var it := _model.get_item(panel_id)
		if it.is_empty():
			continue
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["wmp"] = float(template.get("wmp", sp.get("wmp", 0.0)))
		sp["voc"] = float(template.get("voc", sp.get("voc", 0.0)))
		sp["vmp"] = float(template.get("vmp", sp.get("vmp", 0.0)))
		sp["isc"] = float(template.get("isc", sp.get("isc", 0.0)))
		sp["imp"] = float(template.get("imp", sp.get("imp", 0.0)))
		sp["cost"] = float(template.get("cost", sp.get("cost", 0.0)))
		_model.update_item(panel_id, {"specs": sp})
	var comp_id: String = str(compound_item.get("id", ""))
	var comp_now := _model.get_item(comp_id)
	if not comp_now.is_empty():
		var csp: Dictionary = (comp_now.get("specs", {}) as Dictionary).duplicate(true)
		var series: int = maxi(1, int(csp.get("array_series", 1)))
		var parallel: int = maxi(1, int(csp.get("array_parallel", 1)))
		var panel_units: int = maxi(1, int(csp.get("array_panel_units", panel_ids.size())))
		var panel_wmp: float = float(template.get("wmp", 0.0))
		var panel_voc: float = float(template.get("voc", 0.0))
		var panel_vmp: float = float(template.get("vmp", 0.0))
		var panel_isc: float = float(template.get("isc", 0.0))
		var panel_imp: float = float(template.get("imp", 0.0))
		csp["array_panel_units"] = panel_units
		csp["array_equiv_wmp"] = panel_wmp * float(panel_units)
		csp["array_equiv_vmp"] = panel_vmp * float(series)
		csp["array_equiv_voc"] = panel_voc * float(series)
		csp["array_equiv_imp"] = panel_imp * float(parallel)
		csp["array_equiv_isc"] = panel_isc * float(parallel)
		csp["summary"] = "%s  •  %.0fW  %.1fV  %.1fA" % [
			str(csp.get("array_topology", "Array")),
			float(csp.get("array_equiv_wmp", 0.0)),
			float(csp.get("array_equiv_vmp", 0.0)),
			float(csp.get("array_equiv_imp", 0.0)),
		]
		_model.update_item(comp_id, {"specs": csp})
	_toast("Applied panel template to %d panel(s)" % panel_ids.size())
	_rebuild_current_item()


func _build_battery_cells_section(item: Dictionary) -> void:
	_section("Cell Expansion")
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var row := _row_container()
	var hbox: HBoxContainer = row.get_child(0)
	var expand_btn := Button.new()
	expand_btn.text = "Expand to Cells"
	expand_btn.focus_mode = Control.FOCUS_NONE
	expand_btn.flat = true
	expand_btn.add_theme_color_override("font_color", C_PRIMARY)
	expand_btn.pressed.connect(func():
		var it := _model.get_item(_item_id)
		if it.is_empty():
			return
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["cell_view_mode"] = true
		_model.update_item(_item_id, {"specs": sp})
		_rebuild_current_item()
	)
	hbox.add_child(expand_btn)
	var collapse_btn := Button.new()
	collapse_btn.text = "Collapse Cells"
	collapse_btn.focus_mode = Control.FOCUS_NONE
	collapse_btn.flat = true
	collapse_btn.add_theme_color_override("font_color", C_TEXT_S)
	collapse_btn.pressed.connect(func():
		var it := _model.get_item(_item_id)
		if it.is_empty():
			return
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["cell_view_mode"] = false
		_model.update_item(_item_id, {"specs": sp})
		_rebuild_current_item()
	)
	hbox.add_child(collapse_btn)
	var mode_lbl := Label.new()
	mode_lbl.text = "Mode: Expanded" if bool(specs.get("cell_view_mode", false)) else "Mode: Summary"
	mode_lbl.add_theme_color_override("font_color", C_TEXT_M)
	mode_lbl.add_theme_font_size_override("font_size", 10)
	mode_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(mode_lbl)
	_form_vbox.add_child(row)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _type_icon(itype: String) -> String:
	match itype:
		"panel":                return "☀"
		"wind":                 return "🌬"
		"hydro":                return ""
		"battery":              return "🔋"
		"controller":           return "🎛"
		"appliance", "acload":  return "🏠"
		"processor":            return "🌀"
		"resource":             return "🪣"
		"shelly4pm":            return "📊"
		"spiderbox":            return "🕷"
		"breaker_panel":        return "🔌"
		"plant":                return "🌱"
		"catchment":            return "🌧"
		_:                      return ""
