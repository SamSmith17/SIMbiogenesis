extends CanvasLayer
## Earthship designer: a row of U-shaped tyre-wall rooms behind a sloped,
## equator-facing greenhouse, sunk into the ground and bermed on three sides
## (core/earthshiplab/). The studio shows the building in the earth it asks
## for (StructureEarthworks over flat ground: berms, the daylight cut, the
## ramp, the opening over the rooms). Place in world stamps the same
## earthworks onto the site's terrain; Apply re-solves a placed one.
##
## Open: EarthshipLabModal-style static `open(tree, {spec, prop_id})`
## (Library → Designers → Earthships; the prop editor's "Edit Earthship…").

signal closed

const MODAL_NAME := "earthshiplab"
const WANT := Vector2(1500, 920)
const EARTH_STEP_M := 0.5
const EARTH_PAD_M := 6.0

var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _list: DesignGallery = null
var _col: DesignerColumn = null
var _light_panel: ModelLightPanel = null
var _earthship_3d: Node3D = null
var _ids: Array = []        # parallel to the gallery rows: builtin id, "lib:<name>", "" header
var _rows: Dictionary = {}  # key -> FormRow
var _checks_box: VBoxContainer = null
var _summary_box: VBoxContainer = null
var _status: Label = null
var _apply_btn: Button = null
var _place_btn: Button = null
var _earth_check: CheckButton = null
var _show_earth := true
var _roof_off := false
var _spec: Dictionary = {}
var _prop_id := ""
var _syncing := false
var _open := false
var _rebuild_pending := false


static func open(tree: SceneTree, opts: Dictionary = {}) -> Node:
	var m: Node = load("res://scenes/ui/earthshiplab_modal.gd").new()
	tree.root.add_child(m)
	m.call("open_modal", opts)
	m.connect("closed", Callable(m, "queue_free"))
	return m


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	_build_ui()


func open_modal(opts: Dictionary = {}) -> void:
	if _open:
		return
	_open = true
	visible = true
	HudLayout.claim_modal(MODAL_NAME)
	_shell.open()
	_prop_id = str(opts.get("prop_id", ""))
	_refresh_list()
	var s: Variant = opts.get("spec", null)
	if (not (s is Dictionary) or (s as Dictionary).is_empty()) and not _prop_id.is_empty():
		var rec := PlacedPropService.get_prop_record(_main(), _prop_id)
		s = rec.get(EarthshipSpec.KEY, {})
	if s is Dictionary and not (s as Dictionary).is_empty():
		_load_spec(s)
	else:
		_load_spec(EarthshipPresets.builtin("global_model"))
	_apply_btn.visible = not _prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _prop_id.is_empty() else "Place in world"


func close() -> void:
	if not _open:
		return
	if _light_panel != null:
		_light_panel.reset_studio_night()
	if _shell.is_open():
		_shell.close()
	else:
		_on_shell_closed()


func _on_shell_closed() -> void:
	if not _open:
		return
	_open = false
	visible = false
	HudLayout.release(MODAL_NAME)
	closed.emit()


func is_open() -> bool:
	return _open


func current_spec() -> Dictionary:
	var s := EarthshipSpec.resolve(_spec)
	if _light_panel != null:
		s[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
	return s


# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_shell = DesignerShell.create("Earthship designer", "house", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true,
		"left_label": "Designs", "left_w": 260.0, "right_w": 390.0})
	root.add_child(_shell)
	_shell.closed.connect(_on_shell_closed)
	_shell.name_submitted.connect(func(t: String) -> void:
		_spec["name"] = t
		_refresh_summary())
	_shell.name_edit.placeholder_text = "Design name"
	_build_left()
	_build_centre()
	_build_right()
	_shell.add_button("Save", DesignerShell.SECONDARY, _on_save, "Keep this design in your library")
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Put it on the site where you aim: the ground is dug, bermed and opened over the rooms")
	_place_btn.name = "place_world"
	_apply_btn = _shell.add_button("Apply", DesignerShell.PRIMARY, _on_apply,
		"Rebuild the placed Earthship and its earthworks to this design")
	_apply_btn.name = "apply_placed"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Pick a design · change its rooms, greenhouse and berms on the right · " +
		"the earth shows what the terrain will be dug and piled to · drag to orbit, wheel to zoom")


func _build_left() -> void:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.left.add_child(box)
	box.add_child(SectionHeader.make("Earthships", "", "Built-ins and your saved designs"))
	_list = DesignGallery.make("earthship")
	_list.name = "design_list"
	_list.set_thumbnailer(_thumb_for)
	_list.item_selected.connect(_on_list_selected)
	box.add_child(_list)


func _build_centre() -> void:
	_studio = StudioViewport.create({"ground": false, "person": true, "ssao": true})
	_studio.set_home(0.6, 0.38)
	_studio.input_hook = func(e: InputEvent) -> bool:
		return _light_panel != null and _light_panel.handle_viewport_event(e, _studio.camera, _studio.container, _earthship_3d)
	_shell.centre.add_child(_studio)
	_earth_check = CheckButton.new()
	_earth_check.text = "Show the earth"
	_earth_check.button_pressed = true
	_earth_check.focus_mode = Control.FOCUS_NONE
	_earth_check.tooltip_text = "The berms, the cut and the ramp the terrain is shaped to"
	_earth_check.toggled.connect(func(on: bool) -> void:
		_show_earth = on
		_rebuild_preview())
	_studio.strip.add_child(_earth_check)
	var roof := CheckButton.new()
	roof.text = "Roof off"
	roof.name = "roof_off"
	roof.focus_mode = Control.FOCUS_NONE
	roof.tooltip_text = "Lift the roofs off to see the rooms, the vigas and the beds from above"
	roof.toggled.connect(func(on: bool) -> void:
		_roof_off = on
		_rebuild_preview())
	_studio.strip.add_child(roof)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio.strip.add_child(spacer)
	_studio.strip.add_child(IconButton.make("maximize-2", "Frame the Earthship", _frame))


func _build_right() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.right.add_child(box)
	_checks_box = VBoxContainer.new()
	box.add_child(_checks_box)
	box.add_child(SectionHeader.make("Dimensions", ""))
	_summary_box = VBoxContainer.new()
	_summary_box.add_theme_constant_override("separation", 2)
	box.add_child(_summary_box)
	box.add_child(SectionHeader.make("Rooms", ""))
	_spin(box, "modules", "Rooms", 1, EarthshipSpec.MAX_MODULES, 1, "", "U-shaped rooms in the row")
	_spin(box, "module_w", "Room width", 2.0, 8.0, 0.05, "m", "Inside, between the tyre walls (vigas span this)")
	_spin(box, "module_d", "Room depth", 2.0, 10.0, 0.05, "m", "Inside, from the back wall to the greenhouse")
	_spin(box, "wall_h", "Ceiling", 2.1, 4.5, 0.05, "m", "Floor to the underside of the vigas")
	_spin(box, "wall_t", "Tyre wall", 0.3, 1.5, 0.05, "m", "Rammed tyres plus plaster (a tyre is ~0.75 m)")
	_spin(box, "floor_depth", "Sunk below grade", 0.0, 3.0, 0.05, "m",
		"How far the floors sit under the ground outside")
	_spin(box, "viga_d", "Vigas", 0.12, 0.45, 0.01, "m",
		"Round log beams from the back wall to the front beam (diameter)")
	_spin(box, "viga_spacing", "Viga spacing", 0.35, 1.5, 0.05, "m", "Centre to centre, along the row")
	_option(box, "room_front", "Room fronts", [["wood", "Wood and glass"], ["glass", "Glass (double glazed)"],
		["bottle", "Bottle wall"], ["open", "Open"]], "Between each room and the greenhouse")
	_option(box, "ceiling", "Ceiling", [["boards", "Wood boards"], ["plaster", "Plaster"]], "Over the vigas")
	_option(box, "floor", "Floor", [["flagstone", "Flagstone"], ["earth", "Burnished earth"], ["tile", "Terracotta tile"]], "")
	box.add_child(SectionHeader.make("Greenhouse", ""))
	_option(box, "glazing_style", "Front", [["sloped", "Sloped glazing"], ["vertical", "Upright windows"]],
		"Sloped: one sheet of glass to the roof (classic). Upright: windows under a sloped greenhouse roof (newer Global Model)")
	_spin(box, "corridor_d", "Depth", 1.2, 8.0, 0.05, "m", "From the rooms to the glazing")
	_spin(box, "glazing_deg", "Glazing angle", 35.0, 90.0, 0.5, "°",
		"Above horizontal. Square to the winter-solstice noon sun = latitude + 23.4°")
	var best := Button.new()
	best.text = "Best for this site"
	best.name = "glazing_best"
	best.tooltip_text = "Glazing square to the winter-solstice noon sun at the world's latitude"
	UITheme.style_button(best)
	best.pressed.connect(_on_best_glazing)
	box.add_child(best)
	_spin(box, "sill_h", "Kneewall", 0.2, 1.5, 0.05, "m", "Wall under the glazing")
	_check(box, "vents", "Vents", "Awning windows low in the glazing", "The low vents that let cool air in")
	_spin(box, "planter_w", "Planter", 0.0, 3.0, 0.05, "m", "The botanical cell along the glazing (0 = none)")
	_option(box, "plants", "Planted with", [["mixed", "Food and tropicals"], ["tropical", "Tropical"],
		["garden", "Vegetables"], ["none", "Nothing yet"]], "What grows in the greywater beds")
	box.add_child(SectionHeader.make("Bottle walls", ""))
	_check(box, "bottle_ends", "Ends", "Bottle walls at the greenhouse ends",
		"Coloured bottles set in earthen walls: sunlight comes through them")
	_option(box, "bottle_pattern", "Pattern", [["scatter", "Scattered"], ["clusters", "Flowers"],
		["bands", "Bands"], ["arch", "Rainbow arch"]], "How the bottles are laid in each wall")
	_option(box, "bottle_colors", "Glass", [["mixed", "Mixed"], ["blue_green", "Blues and greens"],
		["amber", "Ambers"], ["rainbow", "Rainbow"]], "")
	_spin(box, "bottle_density", "How many", 0.0, 1.0, 0.05, "", "Share of the wall's bottle spots used")
	_option(box, "end_door", "End door", [["none", "None"], ["left", "Left end"], ["right", "Right end"],
		["both", "Both ends"]], "An arched door out through a greenhouse end wall")
	box.add_child(SectionHeader.make("Entry", ""))
	_option(box, "entry_style", "Style", [["alcove", "Doorway in the glazing"], ["vestibule", "Vestibule and wing walls"]],
		"A vestibule stands out from the glazing with curved earthen walls either side of the steps")
	box.add_child(SectionHeader.make("Earth", ""))
	_spin(box, "berm_run", "Berm slope 1:", 0.6, 5.0, 0.1, "", "Metres out for each metre of height")
	_check(box, "berm_ends", "Ends", "Berm both ends", "Earth piled against the end walls too")
	_spin(box, "front_cut", "Front cut", 0.5, 10.0, 0.1, "m", "Dug out in front of the glazing, down to the floor")
	_check(box, "ramp", "Entry ramp", "A ramp down to the door", "From the ground down into the front cut")
	_option(box, "entry", "Door", [["left", "Left room"], ["centre", "Centre"], ["right", "Right room"]],
		"Where the door through the glazing is")
	box.add_child(SectionHeader.make("Roof", ""))
	_spin(box, "pv_panels", "Solar panels", 0, 48, 1, "", "Modules along the roof's front edge (on the graph when placed)")
	_spin(box, "pv_watts", "Each", 50.0, 700.0, 10.0, "W", "")
	_spin(box, "pv_tilt", "Panel tilt", 0.0, 75.0, 1.0, "°", "Above horizontal, facing the glazing's way")
	var best_pv := Button.new()
	best_pv.text = "Best tilt for this site"
	best_pv.name = "pv_best"
	best_pv.tooltip_text = "Tilt the panels to about the world's latitude"
	UITheme.style_button(best_pv)
	best_pv.pressed.connect(_on_best_pv)
	box.add_child(best_pv)
	_check(box, "skylights", "Skylights", "A skylight over each room", "")
	_check(box, "green_roof", "Green roof", "Grass on the roof", "")
	box.add_child(SectionHeader.make("Water", ""))
	_spin(box, "cisterns", "Cisterns", 0, 8, 1, "", "Buried behind the berm, fed from the roof")
	_spin(box, "cistern_l", "Each holds", 500.0, 60000.0, 100.0, "L", "")
	box.add_child(SectionHeader.make("Lighting", ""))
	_light_panel = ModelLightPanel.new()
	_light_panel.configure_auto_toggle("Warm ceiling bulb in every room", "Hang a warm white bulb in the middle of each U-module's ceiling")
	_light_panel.bind_studio_night(_studio)
	_light_panel.auto_toggle_changed.connect(func(on: bool) -> void:
		_spec["room_lights"] = on
		_light_panel.sync_with_spec(_spec)
		_spec[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
		if _col != null:
			_col.set_summary("Lighting", _light_panel.summary_text()))
	_light_panel.lights_changed.connect(func() -> void:
		_spec[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
		if _col != null:
			_col.set_summary("Lighting", _light_panel.summary_text()))
	box.add_child(_light_panel)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status)
	_col = DesignerColumn.setup(box, "earthship", {"open": ["Rooms"], "tile_cols": 3})


func _spin(box: VBoxContainer, key: String, label: String, lo: float, hi: float, step: float,
		unit: String, tip: String) -> void:
	var row := FormRow.spin(label, lo, hi, step, unit, func(v: float) -> void: _set_field(key, v), tip, key)
	box.add_child(row)
	_rows[key] = row


func _option(box: VBoxContainer, key: String, label: String, items: Array, tip: String) -> void:
	var row := FormRow.option(label, items, func(v: Variant) -> void: _set_field(key, str(v)), tip, key)
	box.add_child(row)
	_rows[key] = row


func _check(box: VBoxContainer, key: String, label: String, text: String, tip: String) -> void:
	var row := FormRow.check(label, text, func(on: bool) -> void: _set_field(key, on), tip, key)
	box.add_child(row)
	_rows[key] = row


func _set_field(key: String, v: Variant) -> void:
	if _syncing:
		return
	_spec[key] = v
	if _light_panel != null:
		_light_panel.sync_with_spec(_spec)
		_spec[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_rebuild_pending = false
	_rebuild_preview()


func _sync_rows() -> void:
	_syncing = true
	var s := EarthshipSpec.resolve(_spec)
	for key in _rows.keys():
		var row: FormRow = _rows[key]
		if row.control is OptionButton:
			FormRow.select_meta(row.control as OptionButton, s.get(key, ""))
		elif row.control is CheckBox:
			(row.control as CheckBox).set_pressed_no_signal(bool(s.get(key, false)))
		else:
			row.set_value(float(s.get(key, 0.0)))
	_shell.name_edit.text = str(s["name"])
	_syncing = false


# --- gallery --------------------------------------------------------------

func _refresh_list() -> void:
	_list.clear()
	_ids.clear()
	_list.add_caption("Built-in")
	for b in EarthshipPresets.builtins():
		_list.add_item(str(b["label"]))
		_ids.append(str(b["id"]))
	var lib := EarthshipPresets.load_library()
	if not lib.is_empty():
		_list.add_caption("Yours")
		for d in lib:
			_list.add_item(DesignGallery.MINE_PREFIX + str((d as Dictionary).get("name", "")))
			_ids.append("lib:" + str((d as Dictionary).get("name", "")))


func _spec_for_id(id: String) -> Dictionary:
	if id.begins_with("lib:"):
		for d in EarthshipPresets.load_library():
			if "lib:" + str((d as Dictionary).get("name", "")) == id:
				return EarthshipSpec.resolve(d)
		return {}
	return EarthshipPresets.builtin(id)


func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _ids.size() or str(_ids[i]).is_empty():
		return {}
	var spec := _spec_for_id(str(_ids[i]))
	return {"key": EarthshipSpec.key_of(spec), "build": func() -> Node3D:
		return _preview_node(spec)}


func _on_list_selected(idx: int) -> void:
	if idx < 0 or idx >= _ids.size() or str(_ids[idx]).is_empty():
		return
	var spec := _spec_for_id(str(_ids[idx]))
	if not spec.is_empty():
		_load_spec(spec, false)


func _load_spec(spec: Dictionary, use_bound_prop: bool = true) -> void:
	_spec = EarthshipSpec.resolve(spec)
	_sync_rows()
	if _light_panel != null:
		_light_panel.set_auto_pressed(bool(_spec.get("room_lights", true)))
		_light_panel.load_from_context(_main() if use_bound_prop else null,
			_prop_id if use_bound_prop else "", EarthshipBuilder.MODEL_ID, _spec)
	_rebuild_preview()
	_frame()


# --- preview --------------------------------------------------------------

## The building plus the earth it asks for, over flat ground at y = 0.
func _preview_node(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "EarthshipPreview"
	var bld := EarthshipBuilder.build_node(spec, "Earthship", {"cutaway": _roof_off})
	root.add_child(bld)
	if _show_earth:
		root.add_child(earth_mesh(EarthshipDesign.earthworks(spec)))
	return root


## The ground an earthworks spec shapes, on flat ground, with its opening cut
## out (StructureEarthworks over a 0.5 m grid, at the origin, yaw 0).
static func earth_mesh(ew: Dictionary) -> MeshInstance3D:
	var pl := StructureEarthworks.placement({"id": "preview", "x": 0.0, "z": 0.0, "yaw": 0.0,
		StructureEarthworks.KEY: ew}, 0.0)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var deltas := StructureEarthworks.solve([pl], flat, EARTH_STEP_M)
	var rect := StructureEarthworks.reach_rect(pl).grow(EARTH_PAD_M)
	var i0 := floori(rect.position.x / EARTH_STEP_M)
	var j0 := floori(rect.position.y / EARTH_STEP_M)
	var i1 := ceili(rect.end.x / EARTH_STEP_M)
	var j1 := ceili(rect.end.y / EARTH_STEP_M)
	var hole: Dictionary = pl["hole"]
	var poly: PackedVector2Array = hole.get("poly", PackedVector2Array())
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(j0, j1):
		for i in range(i0, i1):
			var c := Vector2((float(i) + 0.5) * EARTH_STEP_M, (float(j) + 0.5) * EARTH_STEP_M)
			if poly.size() >= 3 and Geometry2D.is_point_in_polygon(c, poly):
				continue
			var p00 := Vector3(float(i) * EARTH_STEP_M, float(deltas.get(Vector2i(i, j), 0.0)), float(j) * EARTH_STEP_M)
			var p10 := Vector3(float(i + 1) * EARTH_STEP_M, float(deltas.get(Vector2i(i + 1, j), 0.0)), float(j) * EARTH_STEP_M)
			var p01 := Vector3(float(i) * EARTH_STEP_M, float(deltas.get(Vector2i(i, j + 1), 0.0)), float(j + 1) * EARTH_STEP_M)
			var p11 := Vector3(float(i + 1) * EARTH_STEP_M, float(deltas.get(Vector2i(i + 1, j + 1), 0.0)), float(j + 1) * EARTH_STEP_M)
			for tri in [[p00, p11, p10], [p00, p01, p11]]:
				var n: Vector3 = ((tri[2] - tri[0]).cross(tri[1] - tri[0])).normalized()
				if n.y < 0.0:
					n = -n
				for v in tri:
					st.set_normal(n)
					st.add_vertex(v)
	var mi := MeshInstance3D.new()
	mi.name = "Earth"
	mi.set_meta("studio_no_frame", true)
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.62, 0.52, 0.38)
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	return mi


func _rebuild_preview() -> void:
	var prev := _preview_node(_spec)
	_earthship_3d = prev.get_node_or_null("Earthship") as Node3D
	_studio.show_node(prev)
	if _light_panel != null and _earthship_3d != null:
		_light_panel.attach_preview(_earthship_3d)
		if _col != null:
			_col.set_summary("Lighting", _light_panel.summary_text())
	_refresh_summary()


func _frame() -> void:
	var d := EarthshipDesign.solve(_spec)
	var fr: Dictionary = d["frame"]
	var lo := Vector3(float(fr["x0"]), float(fr["yf"]), float(fr["z_back"]))
	var hi := Vector3(float(fr["x1"]), float(fr["roof"]), float(fr["z_front"]))
	_studio.reset_orbit()
	_studio.frame_aabb(AABB(lo, hi - lo), 0.4, 1.3)
	_studio.place_person(absf(float(fr["z_front"])) + 2.5)


func _refresh_summary() -> void:
	var d := EarthshipDesign.solve(_spec)
	var st: Dictionary = d["stats"]
	if _col != null:
		_col.set_tiles([
			{"caption": "Floor", "value": UiText.num(float(st["floor_area_m2"]), "m²", 3),
				"tip": "Rooms plus the greenhouse"},
			{"caption": "Sleeps", "value": str(int(st["sleeps"])), "tip": "Two to a room"},
			{"caption": "Tyres", "value": UiText.thousands(int(st["tyres"])),
				"tip": "%s courses; ~%s of rammed earth" % [str(int(st["courses"])),
					UiText.num(float(st["earth_t"]) * 1000.0, "kg", 3)]},
			{"caption": "Glazing", "value": UiText.num(float(st["glazing_m2"]), "m²", 3), "tip": "The greenhouse front"},
			{"caption": "Bottles", "value": UiText.thousands(int(st["bottles"])), "tip": "Bottle ends set in the walls"},
			{"caption": "Solar", "value": UiText.num(float(st["pv_kw"]) * 1000.0, "W", 3),
				"tip": UiText.count(int(st["pv_panels"]), "panel")}])
	for c in _summary_box.get_children():
		_summary_box.remove_child(c)
		c.queue_free()
	_summary_box.add_child(FormRow.value("Size", "%s × %s" % [UiText.num(float(st["length_m"]), "m", 3),
		UiText.num(float(st["depth_m"]), "m", 3)], "Along the row × front to back"))
	_summary_box.add_child(FormRow.value("Floors", "%s below grade" % UiText.num(-float(st["floor_y"]), "m", 2), ""))
	_summary_box.add_child(FormRow.value("Roof", "%s above grade" % UiText.num(float(st["roof_y"]), "m", 2),
		"The berms rise to here"))
	_summary_box.add_child(FormRow.value("Roof catchment", UiText.num(float(st["roof_m2"]), "m²", 3),
		"Rain on the roof runs to the cisterns"))
	_summary_box.add_child(FormRow.value("Cisterns", UiText.num(float(st["cistern_l"]), "L", 3), ""))
	_summary_box.add_child(FormRow.value("Vigas", "%s, %s of log" % [str(int(st["vigas"])),
		UiText.num(float(st["viga_m"]), "m", 3)], "Round beams spanning front to back"))
	_summary_box.add_child(FormRow.value("Beds", "%s planted" % UiText.num(float(st["planter_m2"]), "m²", 3),
		"Greywater botanical cells along the glazing"))
	for c2 in _checks_box.get_children():
		_checks_box.remove_child(c2)
		c2.queue_free()
	var warns := 0
	for chk in d["checks"]:
		var l := Label.new()
		l.text = ("⚠ " if str(chk["level"]) == "warn" else "· ") + str(chk["text"])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_WARN if str(chk["level"]) == "warn" else UITheme.C_TEXT_S)
		_checks_box.add_child(l)
		if str(chk["level"]) == "warn":
			warns += 1
	_shell.set_badge(UiText.count(warns, "warning") if warns > 0 else "Checks pass",
		"warn" if warns > 0 else "ok")


# --- actions --------------------------------------------------------------

func _main() -> Node:
	var tree := get_tree()
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.current_scene
	return main


func _on_best_glazing() -> void:
	var main := _main()
	var lat := float(main.get("latitude")) if main != null and "latitude" in main else 35.0
	_spec["glazing_deg"] = EarthshipDesign.glazing_for_lat(lat)
	_sync_rows()
	_rebuild_preview()
	_status.text = I18n.f("Glazing at {glazing_deg} for latitude {lat}.", {
		"glazing_deg": UiText.num(float(_spec["glazing_deg"]), "°", 3),
		"lat": UiText.num(absf(lat), "°", 3),
	})


func _on_best_pv() -> void:
	var main := _main()
	var lat := float(main.get("latitude")) if main != null and "latitude" in main else 35.0
	_spec["pv_tilt"] = EarthshipDesign.pv_tilt_for_lat(lat)
	_sync_rows()
	_rebuild_preview()
	_status.text = I18n.f("Panels at {pv_tilt} for latitude {lat}.", {
		"pv_tilt": UiText.num(float(_spec["pv_tilt"]), "°", 3),
		"lat": UiText.num(absf(lat), "°", 3),
	})


func _on_save() -> void:
	var name := _shell.name_edit.text.strip_edges()
	if name.is_empty():
		name = "My Earthship"
	_spec["name"] = name
	EarthshipPresets.save_design(_spec)
	_refresh_list()
	_status.text = I18n.f("Saved {name}.", {"name": name})


func _on_place() -> void:
	var main := _main()
	var js := EarthshipSpec.to_json_safe(current_spec())
	var res: Dictionary = PlacedPropService.begin_placement(main, EarthshipBuilder.MODEL_ID,
		{"record_extra": {EarthshipSpec.KEY: js,
			PropModelLights.KEY_MODEL_LIGHTS: _light_panel.serialized_items() if _light_panel != null else [],
			"collision_enabled": true}})
	if bool(res.get("ok", false)):
		close()
	else:
		_status.text = I18n.f("Could not place: {error}", {"error": str(res.get("error", "no world"))})


func _on_apply() -> void:
	if _prop_id.is_empty():
		return
	var main := _main()
	var js := EarthshipSpec.to_json_safe(current_spec())
	PlacedPropService.update_prop_record(main, _prop_id, {EarthshipSpec.KEY: js}, true)
	PlacedPropService.sync_earthship(main, _prop_id)
	if _light_panel != null:
		PropModelLights.sync_prop(main, _prop_id, _light_panel.items())
	_status.text = "Applied to the placed Earthship."
