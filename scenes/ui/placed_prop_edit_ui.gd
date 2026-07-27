extends PanelContainer

## Edit drawer for a placed prop — transform tweaks + delete/replace.
## Height matches the slim timeline stack; fields sit in a horizontal row.

const C_BG := Color(0.039, 0.055, 0.098, 0.98)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)

## Matches slim TimelineUI stack clearance when live height unavailable.
const DRAWER_HEIGHT := 64.0

var _loader: Node = null
var _prop_id: String = ""
var _syncing := false

var _model_lbl: Label
var _model_option: OptionButton
var _off_x: SpinBox
var _off_y: SpinBox
var _off_z: SpinBox
var _yaw: SpinBox
var _pitch: SpinBox
var _roll: SpinBox
var _scale: SpinBox
var _collision_check: CheckBox
var _show3d_check: CheckBox
var _burnable_check: CheckBox
var _shadow_option: OptionButton
var _restore_btn: Button
var _space_option: OptionButton
var _space_cap: SpinBox
var _del_btn: Button
var _move_btn: Button
var _linkage_btn: Button
var _siphon_btn: Button
var _ports_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_layout_drawer()


func _layout_drawer() -> void:
	var clearance := UiScreenLayout.timeline_stack_height()
	var timeline := get_tree().get_first_node_in_group("timeline_ui")
	if timeline == null:
		var main := get_tree().current_scene
		if main != null:
			timeline = main.get_node_or_null("UILayer/TimelineUI")
	if timeline != null and timeline.has_method("get_stack_height"):
		clearance = float(timeline.call("get_stack_height"))
	UiScreenLayout.pin_above_timeline(self, DRAWER_HEIGHT, clearance)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout_drawer()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open_for_prop(prop_id: String) -> void:
	# Additive printers (mud/clay/concrete) redirect to the in-world Print modal
	# — the single choke point for both click (GrabController) and Interact key,
	# so aiming at the printer and interacting always opens the slicer modal.
	var gv := get_parent().get_node_or_null("SystemGraphView") if get_parent() != null else null
	if gv == null:
		var scene := get_tree().current_scene if get_tree() != null else null
		if scene != null:
			gv = scene.get_node_or_null("UILayer/SystemGraphView")
	if gv != null and gv.has_method("open_print_setup_for_prop"):
		if bool(gv.call("open_print_setup_for_prop", prop_id)):
			return
	_prop_id = prop_id
	_refresh_model_list()
	_load_from_layer()
	_layout_drawer()
	visible = true
	CursorController.request_modal("placed_prop_edit", Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	visible = false
	_prop_id = ""
	CursorController.release_modal("placed_prop_edit")


func _build_ui() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = C_PANEL
	panel_style.border_color = C_BORDER
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", panel_style)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	left.custom_minimum_size.x = 160.0
	root.add_child(left)

	_model_lbl = Label.new()
	_model_lbl.add_theme_color_override("font_color", C_TEXT)
	_model_lbl.add_theme_font_size_override("font_size", 11)
	left.add_child(_model_lbl)

	_model_option = OptionButton.new()
	_model_option.item_selected.connect(_on_model_changed)
	_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_model_option)

	_off_x = _spin(0.01)
	_off_y = _spin(0.01)
	_off_z = _spin(0.01)
	_yaw = _spin(1.0, -360.0, 360.0)
	_pitch = _spin(1.0, -360.0, 360.0)
	_roll = _spin(1.0, -360.0, 360.0)
	_scale = _spin(0.05, 0.05, 20.0)

	var fields := HBoxContainer.new()
	fields.add_theme_constant_override("separation", 6)
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(fields)
	fields.add_child(_compact_field("X", _off_x))
	fields.add_child(_compact_field("Y", _off_y))
	fields.add_child(_compact_field("Z", _off_z))
	fields.add_child(_compact_field("Yaw", _yaw))
	fields.add_child(_compact_field("Pitch", _pitch))
	fields.add_child(_compact_field("Roll", _roll))
	fields.add_child(_compact_field("Scale", _scale))

	for spin_box in [_off_x, _off_y, _off_z, _yaw, _pitch, _roll, _scale]:
		spin_box.value_changed.connect(_on_spin_changed)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	root.add_child(actions)

	_collision_check = CheckBox.new()
	_collision_check.text = "Collide"
	_collision_check.button_pressed = true
	_collision_check.add_theme_color_override("font_color", C_TEXT)
	_collision_check.toggled.connect(_on_collision_toggled)
	actions.add_child(_collision_check)

	# Hide this prop from the 3D world (and, since Site Plan renders the same world,
	# from Site Plan too) without deleting the node — for conceptual/placeholder twins.
	_show3d_check = CheckBox.new()
	_show3d_check.text = "Show in 3D"
	_show3d_check.tooltip_text = "Uncheck to hide this model from the 3D world and Site Plan (the graph node stays)"
	_show3d_check.button_pressed = true
	_show3d_check.add_theme_color_override("font_color", C_TEXT)
	_show3d_check.toggled.connect(_on_show3d_toggled)
	actions.add_child(_show3d_check)

	_burnable_check = CheckBox.new()
	_burnable_check.text = "Burnable"
	_burnable_check.tooltip_text = "Include this prop as fire-crisis ignition / spread geometry (F)"
	_burnable_check.button_pressed = false
	_burnable_check.add_theme_color_override("font_color", C_TEXT)
	_burnable_check.toggled.connect(_on_burnable_toggled)
	actions.add_child(_burnable_check)

	# Per-prop shadow override (Tier 2 perf). "Default" follows the global Shadow
	# detail setting; "All" forces every part to cast (e.g. a hero structure);
	# "Off" drops this prop from the shadow pass entirely.
	_shadow_option = OptionButton.new()
	_shadow_option.tooltip_text = "Shadow casting for this prop (overrides the global Shadow detail setting)"
	_shadow_option.add_item("Shadows: Default", 0)
	_shadow_option.add_item("Shadows: All parts", 1)
	_shadow_option.add_item("Shadows: Off", 2)
	_shadow_option.add_theme_color_override("font_color", C_TEXT)
	_shadow_option.item_selected.connect(_on_shadow_mode_selected)
	actions.add_child(_shadow_option)

	# NPC space tag: mark this prop as a restroom / kitchen / sleeping / water
	# point so population agents wayfind to it (stored in SpaceRegistry, not on
	# the prop record).
	_space_option = OptionButton.new()
	_space_option.tooltip_text = "Tag this prop as an NPC space (restroom, kitchen, …) — people wayfind to it"
	_space_option.add_item("Space: None", 0)
	for i in SpaceTypes.TYPES.size():
		_space_option.add_item("Space: %s" % SpaceTypes.label(SpaceTypes.TYPES[i]), i + 1)
	_space_option.add_theme_color_override("font_color", C_TEXT)
	_space_option.item_selected.connect(_on_space_type_selected)
	actions.add_child(_space_option)

	_space_cap = _spin(1.0, 1.0, 64.0)
	_space_cap.tooltip_text = "How many people can use this space at once"
	_space_cap.custom_minimum_size.x = 56.0
	_space_cap.value_changed.connect(_on_space_capacity_changed)
	_space_cap.visible = false
	actions.add_child(_space_cap)

	_move_btn = Button.new()
	_move_btn.text = "Move"
	_move_btn.tooltip_text = "Click the world to reposition; camera follows the model"
	_move_btn.pressed.connect(_on_move_pressed)
	actions.add_child(_move_btn)

	_restore_btn = Button.new()
	_restore_btn.text = "Restore"
	_restore_btn.tooltip_text = "Regenerate this structure after fire damage"
	_restore_btn.pressed.connect(_on_restore_burned)
	_restore_btn.visible = false
	actions.add_child(_restore_btn)

	_linkage_btn = Button.new()
	_linkage_btn.text = "Linkage Lab"
	_linkage_btn.tooltip_text = "Edit this structure's linkage design in place"
	_linkage_btn.pressed.connect(_on_edit_linkage)
	_linkage_btn.visible = false
	actions.add_child(_linkage_btn)

	_siphon_btn = Button.new()
	_siphon_btn.text = "Hydro Lab"
	_siphon_btn.tooltip_text = "Turbine kind, geometry, penstock, live RPM / power"
	_siphon_btn.pressed.connect(_on_edit_siphon)
	_siphon_btn.visible = false
	actions.add_child(_siphon_btn)

	_ports_btn = Button.new()
	_ports_btn.text = "Ports"
	_ports_btn.tooltip_text = "Tag 3D connection ports (plugs / inlets) on this model"
	_ports_btn.pressed.connect(_on_edit_ports)
	actions.add_child(_ports_btn)

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.pressed.connect(_on_apply)
	actions.add_child(apply_btn)
	_del_btn = Button.new()
	_del_btn.text = "Delete"
	_del_btn.pressed.connect(_on_delete)
	actions.add_child(_del_btn)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(close)
	actions.add_child(close_btn)


func _spin(step: float, min_v: float = -99999.0, max_v: float = 99999.0) -> SpinBox:
	var spin_box := SpinBox.new()
	spin_box.step = step
	spin_box.min_value = min_v
	spin_box.max_value = max_v
	spin_box.allow_greater = true
	spin_box.allow_lesser = true
	spin_box.custom_minimum_size.x = 72.0
	return spin_box


func _compact_field(label_text: String, control: Control) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(lbl)
	col.add_child(control)
	return col


func _refresh_model_list() -> void:
	_model_option.clear()
	for m in ModelCatalog.all_models():
		_model_option.add_item(str(m.get("label", m.get("id", "?"))))
		_model_option.set_item_metadata(_model_option.item_count - 1, str(m.get("id", "")))


func _load_from_layer() -> void:
	if _loader == null or not _loader.has_method("get_prop_record"):
		return
	var rec: Variant = _loader.call("get_prop_record", _prop_id)
	if not (rec is Dictionary):
		return
	var d: Dictionary = rec
	_syncing = true
	_model_lbl.text = "Prop"
	for i in _model_option.item_count:
		if str(_model_option.get_item_metadata(i)) == str(d.get("model_id", "")):
			_model_option.select(i)
			break
	_off_x.value = float(d.get("x", 0.0))
	if d.has("y_offset"):
		_off_y.value = float(d.get("y_offset", 0.0))
	elif d.has("y"):
		var foot_y := ModelCatalog.foot_local_y(str(d.get("model_id", "")))
		var user_scale := float(d.get("scale", 1.0))
		var world_scale := ModelCatalog.resolved_scale(str(d.get("model_id", "")), user_scale)
		var gy := float(d.get("ground_y", 0.0))
		var grounded_y := gy - foot_y * world_scale
		_off_y.value = float(d["y"]) - grounded_y
	else:
		_off_y.value = 0.0
	_off_z.value = float(d.get("z", 0.0))
	_yaw.value = float(d.get("yaw", 0.0))
	_pitch.value = float(d.get("pitch", 0.0))
	_roll.value = float(d.get("roll", 0.0))
	_scale.value = float(d.get("scale", 1.0))
	_collision_check.button_pressed = bool(d.get("collision_enabled", true))
	if _show3d_check != null:
		_show3d_check.button_pressed = not bool(d.get("hidden_3d", false))
	_burnable_check.button_pressed = bool(d.get("burnable", false))
	if _shadow_option != null:
		_shadow_option.selected = _shadow_mode_to_idx(str(d.get("shadow_mode", "")))
	if _linkage_btn != null:
		_linkage_btn.visible = str(d.get("model_id", "")) == LinkageStructureBuilder.MODEL_ID
	if _siphon_btn != null:
		var mid := str(d.get("model_id", ""))
		var kind := str(d.get("kind", ""))
		_siphon_btn.visible = mid == "hydroturbine" or kind == "siphon_hydro" \
				or kind == "siphon_hoverboard"
	_refresh_restore_visibility()
	_sync_space_controls()

	if _del_btn != null:
		var is_osm := str(d.get("type", "")) == "osm"
		if is_osm:
			_del_btn.text = "Remove OSM"
		else:
			_del_btn.text = "Delete"
	_syncing = false


func _on_spin_changed(_v: float = 0.0) -> void:
	if _syncing:
		return
	_preview_live()


func _on_model_changed(_idx: int) -> void:
	if _syncing:
		return
	_preview_live()


func _on_collision_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, {"collision_enabled": pressed})


func _on_show3d_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	# hidden_3d is the inverse of "Show in 3D". update_prop_record persists + rebuilds
	# the prop so PlacedPropRuntime applies ModelRoot.visible immediately.
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, {"hidden_3d": not pressed})


func _on_burnable_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, {"burnable": pressed})
	FireNode.invalidate_flammable_mesh_cache()


func _space_registry() -> SpaceRegistry:
	if _loader == null:
		return null
	var reg: Variant = _loader.get("npc_spaces")
	return reg as SpaceRegistry if reg is SpaceRegistry else null


func _space_target() -> Dictionary:
	return {"kind": "prop", "prop_id": _prop_id}


func _sync_space_controls() -> void:
	if _space_option == null:
		return
	var reg := _space_registry()
	_space_option.visible = reg != null
	_space_cap.visible = false
	if reg == null:
		return
	var rec := reg.space_for_target(_space_target())
	var idx := SpaceTypes.TYPES.find(str(rec.get("space_type", ""))) if not rec.is_empty() else -1
	_space_option.selected = idx + 1  # 0 = None
	if idx >= 0:
		_space_cap.visible = true
		_space_cap.set_value_no_signal(float(int(rec.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))))


func _on_space_type_selected(idx: int) -> void:
	if _syncing or _prop_id.is_empty():
		return
	var reg := _space_registry()
	if reg == null:
		return
	var space_type: String = "" if idx <= 0 else str(SpaceTypes.TYPES[idx - 1])
	reg.set_space_type(_space_target(), space_type, int(_space_cap.value))
	if _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")
	_sync_space_controls()


func _on_space_capacity_changed(v: float) -> void:
	if _syncing or _prop_id.is_empty():
		return
	var reg := _space_registry()
	if reg == null:
		return
	var rec := reg.space_for_target(_space_target())
	if rec.is_empty():
		return
	reg.set_space_type(_space_target(), str(rec.get("space_type", "")), int(v))
	if _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")


const _SHADOW_MODES := ["", "all", "off"]

func _shadow_mode_to_idx(mode: String) -> int:
	var i := _SHADOW_MODES.find(mode)
	return i if i >= 0 else 0

func _on_shadow_mode_selected(idx: int) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	var mode: String = _SHADOW_MODES[clampi(idx, 0, _SHADOW_MODES.size() - 1)]
	# Persist on the record so it survives reload…
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, {"shadow_mode": mode})
	# …and apply to the live node immediately without a full rebuild.
	var node := _find_prop_node()
	if node != null:
		node.set_meta("shadow_mode", mode)
		var radius := 0.0
		if node.has_method("get_local_pick_radius"):
			radius = float(node.call("get_local_pick_radius"))
		PropRenderTuning.apply_to_prop(node, radius)


func _refresh_restore_visibility() -> void:
	if _restore_btn == null:
		return
	var prop := _find_prop_node()
	_restore_btn.visible = prop != null and prop.has_method("has_burned_geometry") and bool(prop.call("has_burned_geometry"))


func _find_prop_node() -> Node:
	if _loader == null or _prop_id.is_empty():
		return null
	if _loader.has_method("_find_placed_prop_node"):
		return _loader.call("_find_placed_prop_node", _prop_id)
	return null


func _on_restore_burned() -> void:
	var prop := _find_prop_node()
	if prop == null or not prop.has_method("restore_after_burn"):
		return
	var n: int = int(prop.call("restore_after_burn"))
	_refresh_restore_visibility()
	_model_lbl.text = "Restored (%d)" % n if n > 0 else "Nothing to restore"


func _transform_patch() -> Dictionary:
	var model_id := ""
	if _model_option.selected >= 0:
		model_id = str(_model_option.get_item_metadata(_model_option.selected))
	return {
		"model_id": model_id,
		"x": _off_x.value, "y_offset": _off_y.value, "z": _off_z.value,
		"yaw": _yaw.value, "pitch": _pitch.value, "roll": _roll.value,
		"scale": _scale.value,
	}


func _preview_live() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("preview_prop"):
		_loader.call("preview_prop", _prop_id, _transform_patch())


func _on_apply() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var patch := _transform_patch()
	if _loader.has_method("update_prop_record"):
		_loader.call("update_prop_record", _prop_id, patch)
	_model_lbl.text = "Model: %s" % str(patch.get("model_id", ""))


func _on_delete() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("delete_prop_by_id"):
		_loader.call("delete_prop_by_id", _prop_id)
	close()


func _on_move_pressed() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var pid := _prop_id
	close()
	if _loader.has_method("begin_prop_reposition"):
		_loader.call("begin_prop_reposition", pid)


## "Edit in Linkage Lab": reopen the designer bound to this placed structure.
func _on_edit_linkage() -> void:
	if _prop_id.is_empty():
		return
	var pid := _prop_id
	close()
	var main := get_tree().current_scene
	if main != null and main.has_method("open_linkage_lab_for_prop"):
		main.call("open_linkage_lab_for_prop", pid)


## Open Siphon Lab for the bound graph item (or toast if unbound).
func _on_edit_siphon() -> void:
	if _prop_id.is_empty() or _loader == null:
		return
	var rec: Variant = _loader.call("get_prop_record", _prop_id) if _loader.has_method("get_prop_record") else {}
	var graph_id := ""
	if rec is Dictionary:
		graph_id = str((rec as Dictionary).get("graph_item_id", ""))
	close()
	var gv := get_parent().get_node_or_null("SystemGraphView") if get_parent() != null else null
	if gv == null:
		var scene := get_tree().current_scene if get_tree() != null else null
		if scene != null:
			gv = scene.get_node_or_null("UILayer/SystemGraphView")
	if gv != null and gv.has_method("open_siphon_lab") and not graph_id.is_empty():
		gv.visible = true
		gv.call("open_siphon_lab", graph_id)
	elif gv != null and gv.has_method("_show_toast"):
		gv.call("_show_toast", "Bind this prop to a Siphon Hydroturbine graph node first")


func _on_edit_ports() -> void:
	if _prop_id.is_empty():
		return
	var pid := _prop_id
	close()
	var gv := get_parent().get_node_or_null("SystemGraphView") if get_parent() != null else null
	if gv == null:
		var scene := get_tree().current_scene if get_tree() != null else null
		if scene != null:
			gv = scene.get_node_or_null("UILayer/SystemGraphView")
	if gv != null and gv.has_method("open_connection_ports_for_prop"):
		gv.call("open_connection_ports_for_prop", pid)
