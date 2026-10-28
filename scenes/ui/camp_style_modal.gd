extends Control

## Camp "Tune look…" — the camp counterpart of the vegetation Tune-look modal.
##
## Two ways in, one modal:
##   STYLE mode (toolbar "Tune look…"): a sample patch of one style. This is
##     where a preset's baseline and its named LAYOUTS are authored.
##   CAMP mode (Ctrl-aim a placed camp + click, or the Edit tool): that camp's
##     real outline, seed and heading, so single elements can be clicked,
##     turned, resized or removed, and the camp can be given settings of its own.
##
## Slider edits collect in a DELTA (a sparse style entry) that is drawn on top
## of everything saved, and the three save buttons decide where it lands:
##   This camp            -> the camp record's own override  (camp mode)
##   All <style> on map   -> this map's edit for the style
##   Global baseline      -> user://camp_styles.json, every map
## That order is also the resolution order (CampStyles.resolve): global style
## -> the camp's layout -> the map's edit -> the camp's own override.
##
## The preview is the real thing — the same CampLayoutGenerator and
## CampAreaRuntime the map uses — so what is tuned here is what gets painted.
## Closing without saving puts the saved styles back.
##
## Performance is a WARNING, never a refusal.

const MODAL_NAME := "camp_style"
const SIDEBAR_W := 420.0
const PREVIEW_SEED := 20260704
const PREVIEW_ID := "preview"
const CLICK_SLOP_PX := 5.0

var _loader: Node = null
var _style_id := CampStyles.DEFAULT_STYLE
var _camp_id := ""                 # "" = style mode
var _camp: Dictionary = {}         # working copy of the camp record
var _variant_id := ""              # layout being edited (style) / worn (camp)
var _draft: Dictionary = CampStyleStore.empty()   # global store: models + layouts
var _saved: Dictionary = CampStyleStore.empty()
var _delta: Dictionary = {}        # unsaved slider edits (a sparse entry)
var _edits: Dictionary = {}        # camp mode: per-element hand edits
var _selected_key := ""

var _viewport: SubViewport = null
var _holder: SubViewportContainer = null
var _camera: Camera3D = null
var _runtime: CampAreaRuntime = null
var _ground: MeshInstance3D = null
var _marker: MeshInstance3D = null
var _title: Label = null
var _style_opt: OptionButton = null
var _rows_box: VBoxContainer = null
var _stats_lbl: Label = null
var _warn_lbl: Label = null
var _save_row: HBoxContainer = null
var _rebuild_timer: Timer = null
var _file_dialog: FileDialog = null
var _library_popup: PopupPanel = null
var _library_list: ItemList = null
var _library_models: Array = []

# Style-mode preview knobs (density belongs to each camp, not to a style).
var _preview_density := 0.8
var _preview_size_m := 70.0
# Orbit camera.
var _focus := Vector3.ZERO
var _yaw := 0.7
var _pitch := 0.75
var _dist := 80.0
var _press_pos := Vector2.ZERO
var _pressed := false
var _dragged := false


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_rebuild_timer = Timer.new()
	_rebuild_timer.one_shot = true
	_rebuild_timer.wait_time = 0.12
	_rebuild_timer.timeout.connect(_rebuild_preview)
	add_child(_rebuild_timer)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open(style_id: String = "", camp_id: String = "") -> void:
	_saved = CampStyleStore.load_data()
	_draft = _saved.duplicate(true)
	_delta = {}
	_selected_key = ""
	_camp_id = ""
	_camp = {}
	_edits = {}
	_variant_id = ""
	_style_id = style_id if CampStyles.is_valid(style_id) else CampStyles.DEFAULT_STYLE
	if not camp_id.is_empty() and _loader != null and _loader.has_method("camp_area_info"):
		var rec: Dictionary = _loader.call("camp_area_info", camp_id)
		if not rec.is_empty():
			_camp_id = camp_id
			_camp = rec.duplicate(true)
			_style_id = str(rec.get("style", _style_id))
			_variant_id = str(rec.get("variant", ""))
			_edits = (rec.get("edits", {}) as Dictionary).duplicate(true)
	for i in _style_opt.item_count:
		if str(_style_opt.get_item_metadata(i)) == _style_id:
			_style_opt.select(i)
	_style_opt.disabled = is_camp_mode()
	_frame_camera()
	visible = true
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	_rebuild_all()


func close() -> void:
	if not visible:
		return
	visible = false
	_rebuild_timer.stop()
	if _runtime != null:
		_runtime.clear_all()
	# Whatever was being tried out, the game goes back to the SAVED styles.
	CampStyleStore.apply(_saved)
	CampMeshLibrary.clear_cache()
	CursorController.release_modal(MODAL_NAME)


func is_panel_open() -> bool:
	return visible


func is_camp_mode() -> bool:
	return not _camp_id.is_empty()


# ---------------------------------------------------------------------------
# UI shell
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", UITheme.panel_style(0.98))
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 40.0
	frame.offset_top = 36.0
	frame.offset_right = -40.0
	frame.offset_bottom = -36.0
	add_child(frame)
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", UITheme.SPACE_SM)
	frame.add_child(split)

	# Preview studio — its own world, so nothing here touches the map.
	_holder = SubViewportContainer.new()
	_holder.stretch = true
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_holder.mouse_filter = Control.MOUSE_FILTER_STOP
	_holder.gui_input.connect(_on_preview_input)
	split.add_child(_holder)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_holder.add_child(_viewport)
	_build_studio()

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(SIDEBAR_W, 0)
	side.add_theme_constant_override("separation", 6)
	split.add_child(side)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_title.clip_text = true
	side.add_child(_title)

	_style_opt = OptionButton.new()
	for sid in CampStyles.STYLE_ORDER:
		_style_opt.add_item(CampStyles.label(str(sid)))
		_style_opt.set_item_metadata(_style_opt.item_count - 1, str(sid))
	_style_opt.item_selected.connect(_on_style_selected)
	side.add_child(_style_opt)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 3)
	scroll.add_child(_rows_box)

	_stats_lbl = Label.new()
	_stats_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_stats_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_stats_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_stats_lbl)
	_warn_lbl = Label.new()
	_warn_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_warn_lbl.add_theme_color_override("font_color", UITheme.C_WARN)
	_warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_warn_lbl)

	side.add_child(SectionHeader.make("Save changes to…"))
	_save_row = HBoxContainer.new()
	_save_row.add_theme_constant_override("separation", 6)
	side.add_child(_save_row)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.glb ; GLB", "*.gltf ; GLTF"])
	_file_dialog.file_selected.connect(_on_import_file)
	add_child(_file_dialog)

	_library_popup = PopupPanel.new()
	var pv := VBoxContainer.new()
	pv.custom_minimum_size = Vector2(340, 420)
	_library_popup.add_child(pv)
	var ph := Label.new()
	ph.text = "Add a model from the library"
	pv.add_child(ph)
	_library_list = ItemList.new()
	_library_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_library_list.item_activated.connect(_on_library_pick)
	pv.add_child(_library_list)
	_button(pv, "Add selected", "", func() -> void:
		var sel := _library_list.get_selected_items()
		if not sel.is_empty():
			_on_library_pick(sel[0]))
	add_child(_library_popup)


func _button(parent: Control, text: String, tip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _build_studio() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.52, 0.66, 0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.72, 0.76, 0.82)
	e.ambient_light_energy = 0.75
	env.environment = e
	_viewport.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 35.0, 0.0)
	sun.shadow_enabled = true
	_viewport.add_child(sun)
	_ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200.0, 1200.0)
	_ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.57, 0.46)
	gm.roughness = 1.0
	_ground.material_override = gm
	_viewport.add_child(_ground)
	_camera = Camera3D.new()
	_camera.far = 4000.0
	_camera.fov = 45.0
	_viewport.add_child(_camera)
	_runtime = CampAreaRuntime.new()
	_runtime.setup(null, true)
	_viewport.add_child(_runtime)
	# Selection marker: a translucent box round the picked element.
	_marker = MeshInstance3D.new()
	_marker.mesh = BoxMesh.new()
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.albedo_color = Color(1.0, 0.78, 0.2, 0.32)
	mm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_marker.material_override = mm
	_marker.visible = false
	_viewport.add_child(_marker)


## Put the camera on the thing being tuned: the camp's own outline, or the
## sample patch at the origin.
func _frame_camera() -> void:
	_focus = Vector3.ZERO
	var span := _preview_size_m
	if is_camp_mode():
		var poly: PackedVector2Array = _camp.get("polygon", PackedVector2Array())
		if poly.size() >= 3:
			var lo := poly[0]
			var hi := poly[0]
			for p in poly:
				lo = lo.min(p)
				hi = hi.max(p)
			_focus = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)
			span = maxf((hi - lo).length(), 20.0)
	_ground.position = _focus
	_dist = clampf(span * 1.15, 12.0, 900.0)
	_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var dir := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	var target := _focus + Vector3(0, 1.5, 0)
	_camera.look_at_from_position(target + dir * _dist, target, Vector3.UP)


# ---------------------------------------------------------------------------
# Preview input: drag orbits, wheel zooms, a CLICK picks an element.
# ---------------------------------------------------------------------------

func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_pressed = true
				_dragged = false
				_press_pos = mb.position
			else:
				if _pressed and not _dragged and mb.button_index == MOUSE_BUTTON_LEFT:
					_pick_element_at(mb.position)
				_pressed = false
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist / 1.12, 5.0)
			_update_camera()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.12, 1200.0)
			_update_camera()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		if not _dragged and mm.position.distance_to(_press_pos) < CLICK_SLOP_PX:
			return
		_dragged = true
		_yaw -= mm.relative.x * 0.008
		_pitch = clampf(_pitch + mm.relative.y * 0.006, 0.08, 1.5)
		_update_camera()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not is_camp_mode() or _selected_key.is_empty():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.physical_keycode:
		KEY_DELETE, KEY_BACKSPACE:
			_remove_selected()
		KEY_R:
			_edit_selected("yaw_deg", _edit_value("yaw_deg", 0.0) + (-15.0 if key.shift_pressed else 15.0))
		KEY_BRACKETRIGHT:
			_edit_selected("scale", _edit_value("scale", 1.0) * 1.1)
		KEY_BRACKETLEFT:
			_edit_selected("scale", _edit_value("scale", 1.0) / 1.1)
		_:
			return
	get_viewport().set_input_as_handled()
	_rebuild_rows()


## Which element does this preview pixel hit? Pure ray-vs-oriented-box over the
## items the last build placed — the studio has no physics to ask.
func pick_element(screen_pos: Vector2) -> String:
	if _camera == null or _runtime == null:
		return ""
	return CampLayoutGenerator.pick_item_on_ray(_runtime.area_items(PREVIEW_ID),
		_camera.project_ray_origin(screen_pos), _camera.project_ray_normal(screen_pos))


func _pick_element_at(screen_pos: Vector2) -> void:
	if not is_camp_mode():
		return
	_selected_key = pick_element(screen_pos)
	_update_marker()
	_rebuild_rows()


func _selected_item() -> Dictionary:
	if _selected_key.is_empty() or _runtime == null:
		return {}
	for it: Dictionary in _runtime.area_items(PREVIEW_ID):
		if str(it["key"]) == _selected_key:
			return it
	return {}


func _update_marker() -> void:
	var it := _selected_item()
	_marker.visible = not it.is_empty()
	if it.is_empty():
		return
	var size: Vector3 = it["size"]
	var h := maxf(size.y, 2.4)
	(_marker.mesh as BoxMesh).size = Vector3(size.x + 0.5, h + 0.3, size.z + 0.5)
	_marker.transform = Transform3D(Basis(Vector3.UP, float(it["yaw"])),
		(it["pos"] as Vector3) + Vector3(0, h * 0.5, 0))


func _edit_value(key: String, fallback: float) -> float:
	return float((_edits.get(_selected_key, {}) as Dictionary).get(key, fallback))


func _edit_selected(key: String, value: float) -> void:
	if _selected_key.is_empty():
		return
	var e: Dictionary = (_edits.get(_selected_key, {}) as Dictionary).duplicate()
	e.erase("removed")
	e[key] = clampf(value, 0.3, 3.0) if key == "scale" else fposmod(value + 180.0, 360.0) - 180.0
	_edits[_selected_key] = e
	_queue_rebuild()


func _remove_selected() -> void:
	if _selected_key.is_empty():
		return
	_edits[_selected_key] = {"removed": true}
	_selected_key = ""
	_queue_rebuild()


# ---------------------------------------------------------------------------
# What is being previewed
# ---------------------------------------------------------------------------

func _map_styles() -> Dictionary:
	if _loader != null and _loader.has_method("map_camp_style"):
		var e: Dictionary = _loader.call("map_camp_style", _style_id)
		if not e.is_empty():
			return {_style_id: e}
	return {}


## The record handed to the generator: the camp itself, or a sample patch.
func _preview_area() -> Dictionary:
	if is_camp_mode():
		var a := _camp.duplicate()
		a["id"] = PREVIEW_ID
		a["variant"] = _variant_id
		a["style_override"] = CampStyleStore.merge_entry(_camp.get("style_override", {}), _delta)
		a["edits"] = _edits
		a["light_density"] = 0.0
		return a
	var half := _preview_size_m * 0.5
	var depth := half * 0.72
	return {"id": PREVIEW_ID, "polygon": PackedVector2Array([Vector2(-half, -depth),
			Vector2(half, -depth), Vector2(half, depth), Vector2(-half, depth)]),
		"holes": [], "style": _style_id, "variant": _variant_id, "style_override": _delta,
		"density": _preview_density, "seed": PREVIEW_SEED, "heading_deg": 90.0,
		"align_jitter_deg": 5.0, "light_density": 0.0}


func _preview_ctx() -> Dictionary:
	var ctx := {"map_styles": _map_styles()}
	if is_camp_mode() and _loader != null and _loader.has_method("camp_preview_ctx"):
		ctx = _loader.call("camp_preview_ctx")
		ctx["map_styles"] = _map_styles()
	return ctx


## The fully resolved style on screen — what every slider shows.
func _resolved() -> Dictionary:
	return CampStyles.style_for_area(_preview_area(), _map_styles())


# ---------------------------------------------------------------------------
# Sidebar rows
# ---------------------------------------------------------------------------

func _rebuild_all() -> void:
	CampStyleStore.apply(_draft)
	_rebuild_rows()
	_rebuild_preview()


func _rebuild_rows() -> void:
	var keep := UITheme.keep_scroll(_rows_box)
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	CampStyleStore.apply(_draft)
	var res := _resolved()
	_title.text = ("%s — this camp" % str(_camp.get("name", "Camp"))) if is_camp_mode() \
		else "Camp style — tune look"

	if is_camp_mode():
		_build_selection_rows()
		_section("This camp")
		_slider("Density", 0.2, 1.0, float(_camp.get("density", 0.8)), 0.05, _camp_setter("density"))
		_slider("Heading°", 0.0, 179.0, maxf(float(_camp.get("heading_deg", 0.0)), 0.0), 1.0,
			_camp_setter("heading_deg"), "Compass bearing the rows run along")
		_slider("Align ±°", 0.0, 30.0, float(_camp.get("align_jitter_deg", 5.0)), 0.5,
			_camp_setter("align_jitter_deg"), "How far vehicles sit off the camp heading")
	else:
		_section("Preview")
		_slider("Density", 0.2, 1.0, _preview_density, 0.05, func(v: float) -> void:
			_preview_density = v
			_queue_rebuild())
		_slider("Patch m", 30.0, 160.0, _preview_size_m, 5.0, func(v: float) -> void:
			_preview_size_m = v
			_queue_rebuild())

	_build_layout_rows()

	_section("Layout")
	_slider("Spacing ×", CampStyles.SPACING_MIN, CampStyles.SPACING_MAX, float(res["spacing"]),
		0.05, _setter("spacing"), "Room between households (1 = as shipped)")
	_slider("Fill", 0.3, 1.0, float(res["fill"]), 0.02, _setter("fill"),
		"Share of plots that are occupied")
	_slider("Lane m", 0.0, 14.0, float(res["lane_w"]), 0.5, _setter("lane_w"),
		"Width of the lane between blocks of rows")
	_slider("Rows/block", 1.0, 5.0, float(res["rows_per_block"]), 1.0, _setter("rows_per_block"),
		"Rows parked back-to-back before the next lane")

	_section("Variation")
	_slider("Placement", 0.0, 1.0, float(res["pos_jitter"]), 0.05, _setter("pos_jitter"),
		"How far each household wanders inside its plot (0 = a strict grid)")
	_slider("Tent turn ±°", 0.0, 60.0, float(res["loose_jitter_deg"]), 1.0,
		_setter("loose_jitter_deg"), "How far tents and pods are pitched off square")
	_slider("Size spread", 0.0, 2.0, float(res["scale_var"]), 0.05, _setter("scale_var"),
		"How much sizes vary from one element to the next (1 = as shipped)")

	_section("Household mix", "0 = not in this style")
	var mix: Dictionary = res["templates"]
	var ids: Array = CampStyles.TEMPLATES.keys()
	ids.sort_custom(func(a: String, b: String) -> bool:
		return float(mix.get(a, 0.0)) > float(mix.get(b, 0.0)))
	for tid in ids:
		_slider(str(CampStyles.TEMPLATE_LABELS.get(tid, tid)), 0.0, 8.0, float(mix.get(tid, 0.0)),
			0.25, _mix_setter(str(tid)), "", 150)

	_section("Your models")
	var models: Dictionary = _draft["models"]
	if models.is_empty():
		_note("None yet. Add any library model, or import a GLB, and give it a share of this style.")
	for cid in models.keys():
		_model_row(str(cid), models[cid], mix)
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(add_row)
	_button(add_row, "Add from library…", "Use a model already in the model library", _open_library)
	_button(add_row, "Import GLB…", "Bring in a new .glb / .gltf file", func() -> void:
		_file_dialog.popup_centered_ratio(0.6))
	_rebuild_save_row()
	keep.call()


## Camp mode: what is selected in the preview, and what can be done to it.
func _build_selection_rows() -> void:
	_section("Selected element")
	var it := _selected_item()
	if it.is_empty():
		_note("Click an element in the preview to turn, resize or remove it.  "
			+ "Keys: R / Shift+R turn · [ ] size · Del remove.")
	else:
		var head := HBoxContainer.new()
		_rows_box.add_child(head)
		var name_lbl := Label.new()
		name_lbl.text = _class_label(str(it["cls"]))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		head.add_child(name_lbl)
		_button(head, "Remove", "Take this element out of the camp (Del)", func() -> void:
			_remove_selected()
			_rebuild_rows())
		_button(head, "Reset", "Undo the hand edits to this element", func() -> void:
			_edits.erase(_selected_key)
			_queue_rebuild()
			_rebuild_rows())
		_slider("Turn°", -180.0, 180.0, _edit_value("yaw_deg", 0.0), 1.0, func(v: float) -> void:
			_edit_selected("yaw_deg", v))
		_slider("Size ×", 0.4, 2.5, _edit_value("scale", 1.0), 0.05, func(v: float) -> void:
			_edit_selected("scale", v))
	var removed := 0
	for k in _edits.keys():
		if bool((_edits[k] as Dictionary).get("removed", false)):
			removed += 1
	if not _edits.is_empty():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_rows_box.add_child(row)
		if removed > 0:
			_button(row, "Restore removed (%d)" % removed, "Bring back every removed element",
				func() -> void:
					for k in _edits.keys():
						if bool((_edits[k] as Dictionary).get("removed", false)):
							_edits.erase(k)
					_queue_rebuild()
					_rebuild_rows())
		_button(row, "Clear all hand edits (%d)" % _edits.size(),
			"Put every element back as the layout placed it", func() -> void:
				_edits.clear()
				_selected_key = ""
				_queue_rebuild()
				_rebuild_rows())


## Layouts: several saved looks under one style, mixed by chance.
func _build_layout_rows() -> void:
	_section("Layouts in %s" % CampStyles.label(_style_id))
	var list := CampStyles.variants(_style_id)
	var opt := OptionButton.new()
	opt.add_item("Default")
	opt.set_item_metadata(0, "")
	for v: Dictionary in list:
		opt.add_item(str(v.get("name", v.get("id", "?"))))
		opt.set_item_metadata(opt.item_count - 1, str(v.get("id", "")))
		if str(v.get("id", "")) == _variant_id:
			opt.select(opt.item_count - 1)
	opt.tooltip_text = "This camp's layout" if is_camp_mode() \
		else "The layout being edited. New camps of this style draw one by chance."
	opt.item_selected.connect(func(i: int) -> void:
		_variant_id = str(opt.get_item_metadata(i))
		# Style mode edits ONE layout at a time; unsaved sliders belong to the
		# layout they were made on.
		if not is_camp_mode():
			_delta = {}
		_selected_key = ""
		_rebuild_rows()
		_queue_rebuild())
	_rows_box.add_child(opt)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)
	_button(row, "+ New layout", "Save what is on screen as a new named layout of this style",
		_on_new_layout)
	if not _variant_id.is_empty():
		_button(row, "Delete layout", "Remove this layout (camps using it fall back to Default)",
			func() -> void:
				CampStyleStore.remove_variant(_draft, _style_id, _variant_id)
				_variant_id = ""
				_rebuild_all())
		var name_edit := LineEdit.new()
		name_edit.text = CampStyles.variant_name(_style_id, _variant_id)
		name_edit.placeholder_text = "Layout name"
		name_edit.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		name_edit.text_submitted.connect(func(t: String) -> void:
			name_edit.release_focus()
			var ve := _draft_variant()
			if not ve.is_empty() and not t.strip_edges().is_empty():
				ve["name"] = t.strip_edges()
				_rebuild_rows())
		_rows_box.add_child(name_edit)
	var weight := float((_draft["styles"] as Dictionary).get(_style_id, {}).get("default_weight", 1.0))
	if not _variant_id.is_empty():
		weight = float(_draft_variant().get("weight", 1.0))
	var set_chance := func(v: float) -> void:
		if _variant_id.is_empty():
			_draft_style()["default_weight"] = v
		else:
			_draft_variant()["weight"] = v
		_rebuild_save_row()
	_slider("Chance", 0.0, 8.0, weight, 0.25, set_chance,
		"How often a new camp of this style draws this layout, relative to the others")
	if list.is_empty():
		_note("One layout so far, so every camp of this style is laid out alike. "
			+ "Tune a second look and press “+ New layout” to mix them.")


func _draft_style() -> Dictionary:
	var styles: Dictionary = _draft["styles"]
	if not styles.has(_style_id):
		styles[_style_id] = {}
	return styles[_style_id]


func _draft_variant() -> Dictionary:
	for v in (_draft_style().get("variants", []) as Array):
		if str((v as Dictionary).get("id", "")) == _variant_id:
			return v
	return {}


func _on_new_layout() -> void:
	# Everything on screen for this style, minus the map/camp layers, becomes
	# the new layout: the current layout's own entry plus the unsaved sliders.
	var base := {}
	for k in _draft_variant().keys():
		if k != "id" and k != "name" and k != "weight":
			base[k] = _draft_variant()[k]
	var vid := CampStyleStore.add_variant(_draft, _style_id, "",
		CampStyleStore.merge_entry(base, _delta))
	if vid.is_empty():
		_warn_lbl.text = "Layout limit reached (%d) — delete one first" % CampStyleStore.MAX_VARIANTS
		return
	_variant_id = vid
	_delta = {}
	_rebuild_all()


func _class_label(cls: String) -> String:
	if CampStyles.is_user_class(cls):
		return str((CampStyles.user_models()[cls] as Dictionary).get("label", cls))
	return cls.replace("_", " ").capitalize()


func _section(text: String, note: String = "") -> void:
	_rows_box.add_child(SectionHeader.make(text, "", note))


func _note(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_rows_box.add_child(l)


func _slider(label: String, lo: float, hi: float, value: float, step: float,
		handler: Callable, tip: String = "", label_w: int = 96) -> void:
	var pair := SliderSpinRow.add(_rows_box, label, lo, hi, clampf(value, lo, hi), handler,
		Callable(self, "_style_row_label"), label_w, 120, 62, step)
	if not tip.is_empty():
		(pair["row"] as Control).tooltip_text = tip


func _style_row_label(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.clip_text = true


func _setter(key: String) -> Callable:
	return func(v: float) -> void:
		_delta[key] = v
		_queue_rebuild()


func _camp_setter(key: String) -> Callable:
	return func(v: float) -> void:
		_camp[key] = v
		if key == "heading_deg":
			_camp["heading_auto"] = false
		_queue_rebuild()


func _mix_setter(template_id: String) -> Callable:
	return func(v: float) -> void:
		if not _delta.has("templates"):
			_delta["templates"] = {}
		(_delta["templates"] as Dictionary)[template_id] = v
		_queue_rebuild()


func _model_row(class_id: String, model: Dictionary, mix: Dictionary) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UITheme.card_style())
	_rows_box.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	box.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var sz: Array = model["size"]
	var name_lbl := Label.new()
	name_lbl.text = "%s  ·  %.1f × %.1f × %.1f m  ·  %s tris" % [str(model["label"]),
		float(sz[0]), float(sz[2]), float(sz[1]), CampStyleStore._k(int(model["tris"]))]
	name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	name_lbl.clip_text = true
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_lbl)
	var mode := OptionButton.new()
	mode.add_item("Aligned")
	mode.add_item("Loose")
	mode.add_item("Any way")
	mode.select(int(model["mode"]))
	mode.tooltip_text = "Aligned: parks square to the camp (±jitter). Loose: roughly square. Any way: random."
	mode.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	mode.item_selected.connect(func(i: int) -> void:
		model["mode"] = i
		CampStyleStore.apply(_draft)
		_queue_rebuild())
	head.add_child(mode)
	var rm_btn := _button(head, "", "Remove this model from every camp style", func() -> void:
		CampStyleStore.remove_model(_draft, class_id)
		if _delta.has("templates"):
			(_delta["templates"] as Dictionary).erase(CampStyles.MODEL_TEMPLATE_PREFIX + class_id)
		_rebuild_all())
	IconButton.style(rm_btn, "trash-2", "Remove this model from every camp style")
	var tid := CampStyles.MODEL_TEMPLATE_PREFIX + class_id
	var pair := SliderSpinRow.add(v, "Share", 0.0, 8.0, float(mix.get(tid, 0.0)), _mix_setter(tid),
		Callable(self, "_style_row_label"), 60, 140, 62, 0.25)
	(pair["row"] as Control).tooltip_text = "This model's weight in the %s mix (0 = not used here)" \
		% CampStyles.label(_style_id)
	for w in CampStyleStore.model_warnings(Vector3(float(sz[0]), float(sz[1]), float(sz[2])),
			int(model["tris"])):
		var wl := Label.new()
		wl.text = "⚠ " + str(w)
		wl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		wl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		wl.add_theme_color_override("font_color", UITheme.C_WARN)
		v.add_child(wl)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

func _open_library() -> void:
	_library_models.clear()
	_library_list.clear()
	for m in ModelCatalog.listed_models():
		# Only models with a file can be merged into one instanced mesh.
		if str(m.get("path", "")).is_empty():
			continue
		_library_models.append(m)
		_library_list.add_item(str(m.get("label", m.get("id", "?"))))
	_library_popup.popup_centered()


func _on_library_pick(index: int) -> void:
	if index < 0 or index >= _library_models.size():
		return
	_library_popup.hide()
	var m: Dictionary = _library_models[index]
	_add_model(str(m.get("id", "")), str(m.get("label", m.get("id", "model"))))


func _on_import_file(path: String) -> void:
	var entry := ModelImporter.import_from_path(path)
	if entry.is_empty():
		_warn_lbl.text = "Could not import %s" % path.get_file()
		return
	_add_model(str(entry.get("id", "")), str(entry.get("label", "Imported model")))


func _add_model(model_id: String, label: String) -> void:
	var measured := CampMeshLibrary.measure_model(model_id)
	if measured.is_empty():
		_warn_lbl.text = "%s has no mesh that can be instanced as camp geometry" % label
		return
	var cid := CampStyleStore.add_model(_draft, model_id, label, measured)
	if cid.is_empty():
		_warn_lbl.text = "Model limit reached (%d) — remove one first" % CampStyleStore.MAX_MODELS
		return
	# A newly added model starts with a modest share of what is on screen, so
	# adding it visibly does something.
	if not _delta.has("templates"):
		_delta["templates"] = {}
	var tid := CampStyles.MODEL_TEMPLATE_PREFIX + cid
	if float((_delta["templates"] as Dictionary).get(tid, 0.0)) <= 0.0:
		(_delta["templates"] as Dictionary)[tid] = 2.0
	_rebuild_all()


# ---------------------------------------------------------------------------
# Draft -> preview
# ---------------------------------------------------------------------------

func _has_changes() -> bool:
	if not _delta.is_empty() or JSON.stringify(_draft) != JSON.stringify(_saved):
		return true
	if not is_camp_mode() or _loader == null:
		return false
	var rec: Dictionary = _loader.call("camp_area_info", _camp_id)
	for k in ["density", "heading_deg", "align_jitter_deg", "variant"]:
		if str(rec.get(k, "")) != str(_camp.get(k, "") if k != "variant" else _variant_id):
			return true
	return JSON.stringify(rec.get("edits", {})) != JSON.stringify(CampAreaLayer._clean_edits(_edits))


func _queue_rebuild() -> void:
	if _rebuild_timer != null:
		_rebuild_timer.start()


func _on_style_selected(index: int) -> void:
	_style_id = str(_style_opt.get_item_metadata(index))
	_variant_id = ""
	_delta = {}
	_rebuild_all()


func _rebuild_preview() -> void:
	if not visible or _runtime == null:
		return
	CampStyleStore.apply(_draft)
	CampMeshLibrary.clear_cache()
	var area := _preview_area()
	_runtime.clear_all()
	var stats := _runtime.rebuild_area(area, _preview_ctx(), true)
	var counts := {}
	var tris := {}
	for it: Dictionary in _runtime.area_items(PREVIEW_ID):
		var cls := str(it["cls"])
		counts[cls] = int(counts.get(cls, 0)) + 1
		if not tris.has(cls):
			tris[cls] = CampMeshLibrary.class_tris(cls, true)
	var area_m2 := maxf(CampAreaLayer.record_area(area), 1.0)
	var cost := CampStyleStore.layout_cost(counts, tris, area_m2)
	var resolved := _resolved()
	_stats_lbl.text = "%s in %s on %.2f ha  ·  plot %.1f × %.1f m  ·  ~%s tris/ha up close" % [
		UiText.count(int(stats.get("structures", 0)), "structure"),
		UiText.count(int(stats.get("households", 0)), "household"), area_m2 / 10000.0,
		float(resolved["cell_u"]), float(resolved["cell_v"]),
		CampStyleStore._k(int(cost["tris_per_ha"]))]
	var warnings: Array = cost["warnings"]
	if int(stats.get("structures", 0)) == 0:
		warnings.append("Nothing fits here — the area is smaller than one household, or too steep.")
	if not is_camp_mode() and not _map_styles().is_empty():
		warnings.append("This map has its own edit for %s, drawn on top of the global look." \
			% CampStyles.label(_style_id))
	_warn_lbl.text = "\n".join(PackedStringArray(warnings.map(func(w: Variant) -> String:
		return "⚠ " + str(w))))
	if _selected_item().is_empty():
		_selected_key = ""
	_update_marker()
	_update_camera()
	_rebuild_save_row()


# ---------------------------------------------------------------------------
# Saving — three scopes
# ---------------------------------------------------------------------------

func _rebuild_save_row() -> void:
	if _save_row == null:
		return
	for c in _save_row.get_children():
		_save_row.remove_child(c)
		c.queue_free()
	var mark := " •" if _has_changes() else ""
	if is_camp_mode():
		_button(_save_row, "This camp" + mark,
			"Keep these settings and hand edits on this one camp", _save_to_camp)
	if _loader != null and _loader.has_method("save_map_camp_style"):
		_button(_save_row, "All %s here" % CampStyles.label(_style_id),
			"Apply the changed settings to every %s camp on THIS map" % CampStyles.label(_style_id),
			_save_to_map)
	_button(_save_row, "Global baseline",
		"Make this the %s look for every map (the starting point for new camps)" \
			% CampStyles.variant_name(_style_id, _variant_id) if not _variant_id.is_empty() \
			else "Make this the baseline for every map (the starting point for new camps)",
		_save_to_global)
	_button(_save_row, "Close", "Close; unsaved changes are dropped (Esc)", close)


## Models and layouts live in the global file whichever scope the sliders go
## to: a camp cannot use a model or wear a layout that was never stored.
func _persist_draft() -> void:
	if JSON.stringify(_draft) == JSON.stringify(_saved):
		return
	_saved = CampStyleStore.normalize(_draft)
	_draft = _saved.duplicate(true)
	if _loader != null and _loader.has_method("apply_camp_styles"):
		_loader.call("apply_camp_styles", _saved)
	else:
		CampStyleStore.save_data(_saved)


func _camp_patch() -> Dictionary:
	var patch := {"variant": _variant_id, "edits": _edits.duplicate(true),
		"density": float(_camp.get("density", 0.8)),
		"align_jitter_deg": float(_camp.get("align_jitter_deg", 5.0))}
	# Only a heading the player actually moved is written: writing it back
	# unchanged would silently turn an auto heading into a manual one.
	var live: Dictionary = _loader.call("camp_area_info", _camp_id)
	if absf(float(live.get("heading_deg", 0.0)) - float(_camp.get("heading_deg", 0.0))) > 0.01:
		patch["heading_deg"] = float(_camp.get("heading_deg", 0.0))
	return patch


func _after_save() -> void:
	_delta = {}
	if is_camp_mode() and _loader != null:
		var rec: Dictionary = _loader.call("camp_area_info", _camp_id)
		_camp = rec.duplicate(true)
		_edits = (rec.get("edits", {}) as Dictionary).duplicate(true)
		_variant_id = str(rec.get("variant", ""))
	_rebuild_all()


func _save_to_camp() -> void:
	if not is_camp_mode() or _loader == null:
		return
	_persist_draft()
	var patch := _camp_patch()
	patch["style_override"] = CampStyleStore.merge_entry(_camp.get("style_override", {}), _delta)
	_loader.call("push_camp_undo")
	_loader.call("update_camp_area", _camp_id, patch)
	_after_save()


func _save_to_map() -> void:
	if _loader == null or not _loader.has_method("save_map_camp_style"):
		return
	_persist_draft()
	_loader.call("push_camp_undo")
	# The camp's own hand edits and layout are its own whatever the scope.
	if is_camp_mode():
		_loader.call("update_camp_area", _camp_id, _camp_patch())
	_loader.call("save_map_camp_style", _style_id,
		CampStyleStore.merge_entry(_loader.call("map_camp_style", _style_id), _delta))
	_after_save()


func _save_to_global() -> void:
	var target := _draft_style() if _variant_id.is_empty() else _draft_variant()
	if target.is_empty() and not _variant_id.is_empty():
		target = _draft_style()
	var merged := CampStyleStore.merge_entry(target, _delta)
	for k in merged.keys():
		target[k] = merged[k]
	_persist_draft()
	if is_camp_mode() and _loader != null:
		_loader.call("push_camp_undo")
		_loader.call("update_camp_area", _camp_id, _camp_patch())
	_after_save()
