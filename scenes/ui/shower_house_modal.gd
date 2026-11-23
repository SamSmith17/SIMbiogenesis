class_name ShowerHouseModal
extends CanvasLayer

## Shower house designer: a 1–12 stall timber or tin shower house with a shed
## roof, curtained stalls, optional batch solar water heater on the roof, and
## per-stall ceiling lights (on by default) plus custom lights and strings.
##
## Open: `ShowerHouseModal.open(tree, {spec, prop_id})` (Library → Designers →
## Shower houses; PlacedPropEditUI → "Edit shower house…").

signal closed

const MODAL_NAME := "shower_house_designer"
const WANT := Vector2(1440, 880)

var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _list: DesignGallery = null
var _col: DesignerColumn = null
var _light_panel: ModelLightPanel = null
var _rows: Dictionary = {}
var _status: Label = null
var _place_btn: Button = null
var _apply_btn: Button = null
var _presets: Array = []
var _spec: Dictionary = {}
var _prop_id := ""
var _syncing := false
var _open := false

const BUILTINS := [
	{"id": "camp_4", "name": "4-stall timber shower house", "blurb": "Single row on a slatted deck, solar batch tank on the roof, a warm bulb in each stall.",
		"spec": {"stalls": 4, "rows": 1, "style": "timber", "heater": "solar", "color": 0, "stall_lights": true}},
	{"id": "two_stall", "name": "2-stall homestead shower", "blurb": "Compact two-stall timber bathhouse with solar roof tank.",
		"spec": {"stalls": 2, "rows": 1, "style": "timber", "heater": "solar", "color": 2, "stall_lights": true}},
	{"id": "tin_6", "name": "6-stall corrugated tin house", "blurb": "Corrugated steel walls, six stalls in one row.",
		"spec": {"stalls": 6, "rows": 1, "style": "tin", "heater": "solar", "color": 1, "stall_lights": true}},
	{"id": "festival_8", "name": "8-stall back-to-back bank", "blurb": "Two rows of four stalls back to back across a plumbing chase.",
		"spec": {"stalls": 8, "rows": 2, "style": "timber", "heater": "solar", "color": 3, "stall_lights": true}},
	{"id": "festival_12", "name": "12-stall festival bathhouse", "blurb": "Full 12-stall double-sided bathhouse for large camps.",
		"spec": {"stalls": 12, "rows": 2, "style": "tin", "heater": "solar", "color": 4, "stall_lights": true}},
]


static func open(tree: SceneTree, opts: Dictionary = {}) -> Node:
	var m: Node = load("res://scenes/ui/shower_house_modal.gd").new()
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
	var main := _main()
	var s: Variant = opts.get("spec", null)
	if (not (s is Dictionary) or (s as Dictionary).is_empty()) and not _prop_id.is_empty():
		var rec := PlacedPropService.get_prop_record(main, _prop_id)
		s = rec.get("shower_spec", {})
	if s is Dictionary and not (s as Dictionary).is_empty():
		_load_spec(s as Dictionary, _prop_id)
	else:
		_load_spec((BUILTINS[0]["spec"] as Dictionary).duplicate(true), _prop_id)
	_apply_btn.visible = not _prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _prop_id.is_empty() else "Place in world"


func close() -> void:
	if not _open:
		return
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
	var s := ShowerHouseBuilder.resolve(_spec)
	s[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
	return s


func light_panel() -> ModelLightPanel:
	return _light_panel


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_shell = DesignerShell.create("Shower house designer", "waves", {
		"name_id": MODAL_NAME, "want": WANT,
		"left_label": "Designs", "left_w": 250.0, "right_w": 390.0})
	root.add_child(_shell)
	_shell.closed.connect(_on_shell_closed)

	var lbox := VBoxContainer.new()
	lbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lbox.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.left.add_child(lbox)
	lbox.add_child(SectionHeader.make("Shower houses", "", "Single-row and back-to-back bathhouses"))
	_list = DesignGallery.make("shower_house")
	_list.name = "design_list"
	_list.set_thumbnailer(_thumb_for)
	_list.item_selected.connect(_on_list_selected)
	lbox.add_child(_list)

	_studio = StudioViewport.create({"ground": true, "person": true, "ssao": true})
	_studio.set_home(0.55, 0.32)
	_studio.input_hook = func(e: InputEvent) -> bool:
		var m := _studio.holder.get_child(0) as Node3D if _studio.holder.get_child_count() > 0 else null
		return _light_panel.handle_viewport_event(e, _studio.camera, _studio.container, m)
	_shell.centre.add_child(_studio)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.right.add_child(box)
	box.add_child(SectionHeader.make("Stalls & roof", ""))
	_rows["stalls"] = FormRow.spin("Stalls", 1, ShowerHouseBuilder.MAX_STALLS, 1, "",
		func(v: float) -> void: _set_field("stalls", int(v)), "One person per stall; everyone else queues in front", "stalls")
	box.add_child(_rows["stalls"])
	_rows["rows"] = FormRow.option("Layout", [[1, "Single row"], [2, "Two rows (back to back)"]],
		func(v: Variant) -> void: _set_field("rows", int(v)), "Two rows share a plumbing chase down the middle", "rows")
	box.add_child(_rows["rows"])
	_rows["style"] = FormRow.option("Walls", [["timber", "Slatted timber"], ["tin", "Corrugated tin"]],
		func(v: Variant) -> void: _set_field("style", str(v)), "", "style")
	box.add_child(_rows["style"])
	_rows["heater"] = FormRow.option("Roof tank", [["solar", "Batch solar collector"], ["none", "Plain header tank"]],
		func(v: Variant) -> void: _set_field("heater", str(v)), "", "heater")
	box.add_child(_rows["heater"])
	_rows["color"] = FormRow.option("Curtains", [[0, "Teal"], [1, "ochre"], [2, "Natural"], [3, "Plum"], [4, "Forest"]],
		func(v: Variant) -> void: _set_field("color", int(v)), "", "color")
	box.add_child(_rows["color"])

	box.add_child(SectionHeader.make("Lighting", ""))
	_light_panel = ModelLightPanel.new()
	_light_panel.configure_auto_toggle("Light in each stall", "A warm ceiling bulb centred inside every shower stall")
	_light_panel.auto_toggle_changed.connect(func(on: bool) -> void:
		_set_field("stall_lights", on))
	_light_panel.lights_changed.connect(_refresh_summary)
	box.add_child(_light_panel)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_status)
	_col = DesignerColumn.setup(box, "shower_house", {"open": ["Stalls & roof", "Lighting"], "finder": false, "tile_cols": 3})

	_studio.strip.add_child(_light_panel.make_night_toggle(_studio))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio.strip.add_child(spacer)
	_studio.strip.add_child(IconButton.make("maximize-2", "Frame the shower house", _frame))

	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Put this shower house on the site where you aim, with its stall lights attached")
	_place_btn.name = "place_world"
	_apply_btn = _shell.add_button("Apply", DesignerShell.PRIMARY, _on_apply,
		"Rebuild the placed shower house and update its stall lights and strings")
	_apply_btn.name = "apply_placed"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Set stalls, walls and roof tank · each stall gets a ceiling light by default · click + String or + Omni on the 3D model to add more")


func _refresh_list() -> void:
	_list.clear()
	_presets.clear()
	_list.add_caption("Built-in")
	for b in BUILTINS:
		_list.add_item(str(b["name"]))
		var s := ShowerHouseBuilder.resolve(b["spec"])
		var fp := ShowerHouseBuilder.footprint(s)
		_list.set_item_subtitle(_list.item_count - 1, "%d stalls · %.1f × %.1f m" % [int(s["stalls"]), fp.x, fp.y])
		_list.set_item_tooltip(_list.item_count - 1, str(b["blurb"]))
		_presets.append(b)


func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _presets.size() or _presets[i] == null:
		return {}
	var spec: Dictionary = (_presets[i] as Dictionary)["spec"]
	return {"key": JSON.stringify(spec), "build": func() -> Node3D:
		return ShowerHouseBuilder.build_node(spec, "Thumb")}


func _on_list_selected(idx: int) -> void:
	if idx < 0 or idx >= _presets.size() or _presets[idx] == null:
		return
	var spec: Dictionary = ((_presets[idx] as Dictionary)["spec"] as Dictionary).duplicate(true)
	_load_spec(spec, "")


func _load_spec(spec: Dictionary, bound_prop: String) -> void:
	_spec = ShowerHouseBuilder.resolve(spec)
	_sync_rows()
	_light_panel.set_auto_pressed(bool(_spec.get("stall_lights", true)))
	_light_panel.load_from_context(_main(), bound_prop, ShowerHouseBuilder.MODEL_ID, _spec)
	_rebuild_preview(true)


func _set_field(key: String, val: Variant) -> void:
	if _syncing:
		return
	_spec[key] = val
	if key == "stalls" and int(val) < 2:
		_spec["rows"] = 1
	_spec = ShowerHouseBuilder.resolve(_spec)
	_sync_rows()
	_light_panel.set_auto_pressed(bool(_spec.get("stall_lights", true)))
	_light_panel.sync_with_spec(_spec)
	_rebuild_preview(false)


func _sync_rows() -> void:
	_syncing = true
	var s := ShowerHouseBuilder.resolve(_spec)
	(_rows["stalls"] as FormRow).set_value(float(s["stalls"]))
	FormRow.select_meta((_rows["rows"] as FormRow).control as OptionButton, int(s["rows"]))
	FormRow.select_meta((_rows["style"] as FormRow).control as OptionButton, str(s["style"]))
	FormRow.select_meta((_rows["heater"] as FormRow).control as OptionButton, str(s["heater"]))
	FormRow.select_meta((_rows["color"] as FormRow).control as OptionButton, int(s["color"]))
	_syncing = false


func _rebuild_preview(reframe: bool) -> void:
	var node := ShowerHouseBuilder.build_node(_spec, "ShowerHouse")
	_studio.show_node(node)
	_light_panel.attach_preview(node)
	if reframe:
		_frame()
	_refresh_summary()


func _frame() -> void:
	var fp := ShowerHouseBuilder.footprint(_spec)
	_studio.reset_orbit()
	_studio.frame_aabb(AABB(Vector3(-fp.x * 0.5, 0.0, -fp.y * 0.5), Vector3(fp.x, 3.0, fp.y)), 0.4, 1.35)
	_studio.place_person(fp.x * 0.5 + 1.2)


func _refresh_summary() -> void:
	var s := ShowerHouseBuilder.resolve(_spec)
	var fp := ShowerHouseBuilder.footprint(s)
	_shell.set_subtitle("%d stalls · %.1f × %.1f m · %s" % [int(s["stalls"]), fp.x, fp.y, str(s["style"])])
	if _col != null:
		_col.set_tiles([
			{"caption": "Stalls", "value": str(int(s["stalls"])), "tip": UiText.count(int(s["rows"]), "row")},
			{"caption": "Footprint", "value": "%.1f × %.1f m" % [fp.x, fp.y], "tip": "Deck and roof overhang"},
			{"caption": "Lights", "value": _light_panel.summary_text(), "tip": "Attached to the house"},
		])
		_col.set_summary("Lighting", _light_panel.summary_text())


func _on_place() -> void:
	var main := _main()
	var s := current_spec()
	var res: Dictionary = PlacedPropService.begin_placement(main, ShowerHouseBuilder.MODEL_ID, {
		"record_extra": {
			"shower_spec": s,
			PropModelLights.KEY_MODEL_LIGHTS: _light_panel.serialized_items(),
			"collision_enabled": true,
		}
	})
	if bool(res.get("ok", false)):
		close()
	else:
		_status.text = I18n.f("Could not place: {error}", {"error": str(res.get("error", "no world"))})


func _on_apply() -> void:
	if _prop_id.is_empty():
		return
	var main := _main()
	var s := current_spec()
	PlacedPropService.update_prop_record(main, _prop_id, {"shower_spec": s}, true)
	PlacedPropService._auto_tag_shower_house(main, _prop_id)
	PropModelLights.sync_prop(main, _prop_id, _light_panel.items())
	_status.text = "Applied to the placed shower house."


func _main() -> Node:
	var tree := get_tree()
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.current_scene
	return main
