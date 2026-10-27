extends PanelContainer

## The placed-prop EDITOR: one dock for every placed thing in the world.
##
## It replaced a two-row bottom drawer of spinboxes that locked the mouse into
## a modal. This is a right-edge dock in CursorController's TOOL-OVERLAY tier
## (the J Light Studio / T-V toolbar contract): the cursor is free, RMB still
## looks, WASD still walks, and ONE Esc closes it. The headline change is the
## GUMBALL — a LightGizmo on the prop (it is generic; nothing in it is about
## lights): drag an arrow to slide, a square to slide in a plane, a ring to
## turn. The numbers are still here for precision, under the gizmo.
##
## Every placed model opens HERE — the StarShade designer, the FDM print
## setup, the pallet-rack builder and the Linkage Lab used to replace this
## panel outright, and none of them could move or delete the prop (a
## StarShade had no Delete anywhere). They are now buttons in the "Model"
## section, so the one surface has everything: place, turn, scale, options,
## fire, the model's own tools, delete.
##
## Node name `UILayer/PlacedPropEditUI` and `open_for_prop` / `close` /
## `bind_loader` are load-bearing: terrain_loader creates it and
## interaction_focus / grab_controller open it by name.

const OVERLAY_NAME := "placed_prop_edit"
const DOCK_W := 400.0
const SNAP_M := 0.25
const SNAP_DEG := 15.0
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const _SHADOW_MODES := ["", "all", "off"]

var _loader: Node = null
var _main: Node = null
var _pv_snap_chk: CheckBox = null
var _pv_guides: MeshInstance3D = null
var _prop_id: String = ""
var _rec: Dictionary = {}
var _active := false
var _syncing := false

# --- world ---
var _gizmo: LightGizmo = null
var _dragging := false
var _drag := {}
var _local_space := false
var _tf := {}                 # live transform: x, y_offset, z, yaw, pitch, roll, scale
var _dirty_tf := false

# --- widgets ---
var _title_lbl: Label
var _sub_lbl: Label
var _hint_lbl: Label
var _scroll: ScrollContainer
var _body: VBoxContainer
var _spins := {}              # key -> SpinBox
var _space_btn: Button
var _mode_move: Button
var _mode_rotate: Button
var _collision_check: CheckBox
var _show3d_check: CheckBox
var _shadow_option: OptionButton
var _space_row: NpcSpaceTagRow
var _firepit_section: VBoxContainer = null
var _pv_section: VBoxContainer = null
var _pv_tilt: SpinBox = null
var _pv_info: Label = null
var _firepit_mode: OptionButton = null
var _firepit_below: SpinBox = null
var _model_option: OptionButton
var _packed_lbl: Label
var _pack_btn: Button
var _model_section: VBoxContainer
var _model_btns: VBoxContainer
# fire
var _burnable_check: CheckBox
var _fire_box: VBoxContainer
var _fire_status: Label
var _fire_spins := {}         # climb_h / bonfire_h / ember_h -> SpinBox (hours)
var _fire_auto_lbl: Label
var _fire_reset_btn: Button
var _fire_ignite_btn: Button
var _fire_out_btn: Button
var _fire_restore_btn: Button
var _fire_refresh_t := 0.0
# footer
var _del_btn: Button
var _del_armed := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UITheme.panel_style(0.94))
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = -DOCK_W - 10.0
	offset_right = -10.0
	offset_top = 10.0
	offset_bottom = -(HudLayout.timeline_height() + 10.0)
	_build_ui()
	set_process(false)


func bind_loader(loader: Node) -> void:
	_loader = loader


func _resolve_main() -> void:
	if _main == null or not is_instance_valid(_main):
		_main = ServiceLocator.main()
		if _main == null and get_tree() != null:
			_main = get_tree().current_scene


# ---------------------------------------------------------------------------
# open / close
# ---------------------------------------------------------------------------

func open_for_prop(prop_id: String) -> void:
	_resolve_main()
	if prop_id.is_empty() or _loader == null:
		return
	var was_open := _active
	_prop_id = prop_id
	_del_armed = false
	_load_record()
	if _rec.is_empty():
		return
	_rebuild_dynamic_sections()
	_sync_widgets()
	_refresh_pin_pick()
	if not was_open:
		_active = true
		visible = true
		move_to_front()
		set_process(true)
		CursorController.request_tool_overlay(OVERLAY_NAME, Callable(self, "_escape_step"))
		_ensure_gizmo()
		HudLayout.claim_right_dock("prop_editor", self, DOCK_W)
	_update_gizmo()
	_hint("Drag the arrows to move, the rings to turn. Shift snaps. Esc closes.")


func close() -> void:
	if not _active:
		return
	if _dragging:
		_end_drag(false)
	_flush_transform()
	_active = false
	visible = false
	set_process(false)
	HudLayout.release("prop_editor")
	_prop_id = ""
	_rec = {}
	CursorController.release_tool_overlay(OVERLAY_NAME)
	if _gizmo != null and is_instance_valid(_gizmo):
		_gizmo.hide_gizmo()


## Compatibility with every dock's force-close contract.
func _exit_mode() -> void:
	close()


func _exit_tree() -> void:
	if _active:
		close()
	if _gizmo != null and is_instance_valid(_gizmo):
		_gizmo.queue_free()


func _escape_step() -> void:
	if _dragging:
		_end_drag(false)
		return
	if _del_armed:
		_disarm_delete()
		return
	close()


func is_panel_open() -> bool:
	return _active


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, UITheme.SPACE_SM)
	add_child(margin)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", UITheme.SPACE_SM)
	margin.add_child(outer)

	# Header
	var head := DockShell.header("", "", close)
	outer.add_child(head["row"])
	_title_lbl = head["title"]
	_sub_lbl = head["subtitle"]
	_sub_lbl.visible = true

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.clip_contents = true
	_body.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_scroll.add_child(_body)

	_build_placement_section()
	_build_display_section()
	_build_fire_section()
	_build_firepit_section()
	_build_pv_section()
	_model_section = _section("Model")
	_model_btns = VBoxContainer.new()
	_model_btns.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_model_section.add_child(_model_btns)

	# Footer
	_hint_lbl = Label.new()
	_hint_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(_hint_lbl)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", UITheme.SPACE_SM)
	outer.add_child(foot)
	var dup_btn := Button.new()
	dup_btn.text = "Duplicate"
	dup_btn.tooltip_text = "Place a copy of this prop beside it"
	UITheme.style_button(dup_btn)
	dup_btn.pressed.connect(_on_duplicate)
	foot.add_child(dup_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	_del_btn = Button.new()
	_del_btn.text = "Delete"
	_del_btn.tooltip_text = "Remove this prop from the site (asks once)"
	UITheme.style_button(_del_btn)
	_del_btn.pressed.connect(_on_delete)
	foot.add_child(_del_btn)


func _section(title: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	_body.add_child(card)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, UITheme.SPACE_SM)
	card.add_child(m)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	m.add_child(box)
	box.add_child(SectionHeader.make(title, String(SECTION_ICONS.get(title, ""))))
	return box


const SECTION_ICONS := {
	"Placement": "move", "Display": "eye", "Fire": "flame", "Firepit": "flame",
	"Solar array": "sun", "Model": "box",
}


## A label + value grid: one column of labels, one of values, so every value
## box in a section starts at the same x whatever its label says.
func _grid(parent: Control, columns: int = 4) -> GridContainer:
	var g := GridContainer.new()
	g.columns = columns
	g.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	g.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	parent.add_child(g)
	return g


func _row(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", UITheme.SPACE_SM)
	parent.add_child(h)
	return h


func _small_label(text: String, parent: Control, min_w: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", C_TEXT_S)
	if min_w > 0.0:
		l.custom_minimum_size.x = min_w
	parent.add_child(l)
	return l


func _spin(key: String, step: float, min_v: float, max_v: float, suffix: String, parent: Control) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = step
	sb.min_value = min_v
	sb.max_value = max_v
	sb.allow_greater = true
	sb.allow_lesser = true
	sb.suffix = suffix
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.custom_minimum_size.x = 64.0
	sb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	sb.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_SM)
	sb.value_changed.connect(func(_v: float) -> void: _on_tf_spin(key))
	parent.add_child(sb)
	_spins[key] = sb
	return sb


func _button(text: String, tip: String, parent: Control, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(b)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _build_placement_section() -> void:
	var box := _section("Placement")
	var modes := _row(box)
	_mode_move = Button.new()
	_mode_move.text = "Move"
	_mode_move.toggle_mode = true
	_mode_move.button_pressed = true
	_mode_move.tooltip_text = "Show the move arrows and planes on the gizmo"
	_mode_move.toggled.connect(func(_on: bool) -> void: _update_gizmo())
	modes.add_child(_mode_move)
	_mode_rotate = Button.new()
	_mode_rotate.text = "Rotate"
	_mode_rotate.toggle_mode = true
	_mode_rotate.button_pressed = true
	_mode_rotate.tooltip_text = "Show the rotation rings on the gizmo"
	_mode_rotate.toggled.connect(func(_on: bool) -> void: _update_gizmo())
	modes.add_child(_mode_rotate)
	_space_btn = Button.new()
	_space_btn.text = "World"
	_space_btn.tooltip_text = "Gizmo axes: world or the prop's own (L)"
	_space_btn.pressed.connect(_toggle_space)
	modes.add_child(_space_btn)
	for b: Button in [_mode_move, _mode_rotate, _space_btn]:
		UITheme.style_button(b)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Even columns: X / Lift / Yaw / Roll down the left, Z / Scale / Pitch on
	# the right, every value box aligned.
	var grid := _grid(box)
	_small_label("X", grid)
	_spin("x", 0.05, -1.0e6, 1.0e6, " m", grid)
	_small_label("Z", grid)
	_spin("z", 0.05, -1.0e6, 1.0e6, " m", grid)
	_small_label("Lift", grid)
	_spin("y_offset", 0.05, -50.0, 200.0, " m", grid).tooltip_text = "Height above the ground under the prop"
	_small_label("Scale", grid)
	_spin("scale", 0.05, 0.05, 50.0, "×", grid)
	_small_label("Yaw", grid)
	_spin("yaw", 1.0, -360.0, 360.0, "°", grid)
	_small_label("Pitch", grid)
	_spin("pitch", 1.0, -90.0, 90.0, "°", grid)
	_small_label("Roll", grid)
	_spin("roll", 1.0, -180.0, 180.0, "°", grid)
	var quick := _row(box)
	_button("Level", "Pitch and roll back to zero", quick, func() -> void:
		_tf["pitch"] = 0.0
		_tf["roll"] = 0.0
		_push_transform(true))
	_button("On ground", "Lift back to zero", quick, func() -> void:
		_tf["y_offset"] = 0.0
		_push_transform(true))
	_button("Free move…", "Carry it with the crosshair; click to set it down", quick, _on_free_move)
	# Points of interest (the KML pins): move the prop onto one exactly. The
	# list is rebuilt each time the editor opens on a prop.
	_pin_pick = OptionButton.new()
	_pin_pick.focus_mode = Control.FOCUS_NONE
	_pin_pick.tooltip_text = "Move this prop onto a point of interest (a Google Earth pin)"
	_pin_pick.fit_to_longest_item = false
	_pin_pick.item_selected.connect(_on_pin_picked)
	quick.add_child(_pin_pick)
	_refresh_pin_pick()


var _pin_pick: OptionButton = null


func _refresh_pin_pick() -> void:
	if _pin_pick == null or not is_instance_valid(_pin_pick):
		return
	_pin_pick.clear()
	_pin_pick.add_item("Snap to pin…")
	_pin_pick.set_item_disabled(0, true)
	var n := 0
	if _loader != null and _loader.has_method("poi_records"):
		for rec_v in (_loader.call("poi_records") as Array):
			var rec: Dictionary = rec_v
			if str(rec.get("kind", "point")) != "point":
				continue
			_pin_pick.add_item(str(rec.get("name", "pin")))
			_pin_pick.set_item_metadata(_pin_pick.item_count - 1, str(rec.get("id", "")))
			n += 1
	_pin_pick.select(0)
	_pin_pick.visible = n > 0


func _on_pin_picked(index: int) -> void:
	if index <= 0 or _loader == null or not _loader.has_method("poi_world_position"):
		return
	var pid := str(_pin_pick.get_item_metadata(index))
	_pin_pick.select(0)
	var world: Vector3 = _loader.call("poi_world_position", pid)
	if not is_finite(world.x):
		return
	_tf["x"] = world.x
	_tf["z"] = world.z
	_push_transform(true)


func _build_display_section() -> void:
	var box := _section("Display")
	var toggles := _row(box)
	_collision_check = CheckBox.new()
	_collision_check.text = "Collision"
	_collision_check.tooltip_text = "Walkable / solid"
	_collision_check.toggled.connect(_on_collision_toggled)
	toggles.add_child(_collision_check)
	_show3d_check = CheckBox.new()
	_show3d_check.text = "Show in 3D"
	_show3d_check.tooltip_text = "Hide a conceptual twin from the world without removing it"
	_show3d_check.toggled.connect(_on_show3d_toggled)
	toggles.add_child(_show3d_check)
	var shadow_row := _row(box)
	_small_label("Shadows", shadow_row, 60)
	_shadow_option = OptionButton.new()
	_shadow_option.tooltip_text = "Shadow casting for this prop (overrides the global Shadow detail setting)"
	_shadow_option.add_item("Default", 0)
	_shadow_option.add_item("All parts", 1)
	_shadow_option.add_item("Off", 2)
	_shadow_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shadow_option.clip_text = true
	_shadow_option.item_selected.connect(_on_shadow_mode_selected)
	shadow_row.add_child(_shadow_option)
	var model_row := _row(box)
	_small_label("Model", model_row, 60)
	_model_option = OptionButton.new()
	_model_option.tooltip_text = "Swap the model, keeping the placement"
	_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_option.clip_text = true  # a long model name must not widen the dock
	_model_option.fit_to_longest_item = false
	_model_option.item_selected.connect(_on_model_changed)
	model_row.add_child(_model_option)
	_space_row = NpcSpaceTagRow.new()
	_space_row.form_label_w = 60.0
	_space_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_space_row)


## FIREPIT (FirepitBuilder): when its small fire burns. Auto lights it at
## night below a temperature; the crowd gathers round exactly the pits that
## are burning (the bridge asks FirepitBuilder.lit_for, as the fire does).
## Written to the record WITHOUT a rebuild — FirepitFire re-reads it each
## second.
func _build_firepit_section() -> void:
	_firepit_section = _section("Firepit")
	var row := _row(_firepit_section)
	_small_label("Lit", row, 60)
	_firepit_mode = OptionButton.new()
	_firepit_mode.add_item("At night when cold")
	_firepit_mode.add_item("Always")
	_firepit_mode.add_item("Out")
	_firepit_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_firepit_mode.tooltip_text = "When the fire burns. People gather round a lit pit on a cold night."
	_firepit_mode.item_selected.connect(_on_firepit_mode)
	row.add_child(_firepit_mode)
	var row2 := _row(_firepit_section)
	_small_label("Below", row2, 60)
	_firepit_below = SpinBox.new()
	_firepit_below.min_value = -20.0
	_firepit_below.max_value = 35.0
	_firepit_below.step = 1.0
	_firepit_below.suffix = "°C"
	_firepit_below.tooltip_text = "At night, light it when the air is colder than this"
	_firepit_below.value_changed.connect(_on_firepit_below)
	row2.add_child(_firepit_below)
	_firepit_section.get_parent().get_parent().visible = false


func _sync_firepit() -> void:
	if _firepit_section == null:
		return
	var is_pit := str(_rec.get("model_id", "")) == FirepitBuilder.MODEL_ID
	_firepit_section.get_parent().get_parent().visible = is_pit
	if not is_pit:
		return
	_firepit_mode.selected = maxi(FirepitBuilder.MODES.find(str(_rec.get("firepit_mode", FirepitBuilder.MODE_AUTO))), 0)
	_firepit_below.set_value_no_signal(float(_rec.get("firepit_below_c", FirepitBuilder.DEFAULT_BELOW_C)))
	_firepit_below.editable = _firepit_mode.selected == 0


func _patch_firepit(patch: Dictionary) -> void:
	if _syncing or _prop_id.is_empty():
		return
	_resolve_main()
	PlacedPropService.update_prop_record(_main, _prop_id, patch, false)
	for k in patch:
		_rec[k] = patch[k]
	_firepit_below.editable = _firepit_mode.selected == 0


func _on_firepit_mode(i: int) -> void:
	_patch_firepit({"firepit_mode": str(FirepitBuilder.MODES[clampi(i, 0, FirepitBuilder.MODES.size() - 1)])})


func _on_firepit_below(v: float) -> void:
	_patch_firepit({"firepit_below_c": v})


## SOLAR ARRAY (PvArrayBuilder, a ground-mount rack bound to a graph array):
## tilt here, facing by turning the rack (the gizmo's yaw ring or "Face the
## equator"). Both drive the graph array's plane of array — and through it
## SolarUI — via sync_site_from_prop. The panel COUNT is the graph array's
## (the electrical string); the rack only draws it.
func _build_pv_section() -> void:
	_pv_section = _section("Solar array")
	var row := _row(_pv_section)
	_small_label("Tilt", row, 60)
	_pv_tilt = SpinBox.new()
	_pv_tilt.min_value = 0.0
	_pv_tilt.max_value = 60.0
	_pv_tilt.step = 1.0
	_pv_tilt.suffix = "°"
	_pv_tilt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pv_tilt.tooltip_text = "Panel tilt from flat. Latitude is a good all-year figure; steeper favours winter."
	_pv_tilt.value_changed.connect(_on_pv_tilt)
	row.add_child(_pv_tilt)
	var face := Button.new()
	face.text = "Face the equator"
	face.tooltip_text = "Turn the rack to face due south (north in the southern hemisphere)"
	UITheme.style_button(face)
	face.pressed.connect(_on_pv_face_equator)
	_pv_section.add_child(face)
	_pv_info = Label.new()
	_pv_info.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_pv_info.add_theme_color_override("font_color", C_TEXT_S)
	_pv_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pv_section.add_child(_pv_info)
	# Grid snap (PvGridSnap): racks line up edge to edge and in rows at the
	# no-shade pitch. Player prefs, shared with the placement ghost.
	var prefs := PvGridSnap.prefs()
	_pv_snap_chk = CheckBox.new()
	_pv_snap_chk.text = "Snap into rows"
	_pv_snap_chk.button_pressed = bool(prefs["enabled"])
	_pv_snap_chk.tooltip_text = ("Moving or placing a rack lines it up with the racks near it — "
		+ "edge to edge in a row, or one row behind at a pitch that does not shade it "
		+ "at the winter solstice. Racks of the same array snap first. Hold Alt to move freely.")
	_pv_snap_chk.toggled.connect(func(on: bool) -> void: PvGridSnap.set_pref("enabled", on))
	_pv_section.add_child(_pv_snap_chk)
	var row2 := _row(_pv_section)
	_small_label("Gap", row2, 60)
	var gap := SpinBox.new()
	gap.min_value = 0.0
	gap.max_value = 2.0
	gap.step = 0.01
	gap.suffix = "m"
	gap.value = float(prefs["gap_m"])
	gap.tooltip_text = "Space left between racks side by side"
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.value_changed.connect(func(v: float) -> void: PvGridSnap.set_pref("gap_m", v))
	row2.add_child(gap)
	var row3 := _row(_pv_section)
	_small_label("Row pitch", row3, 60)
	var pitch := SpinBox.new()
	pitch.min_value = 0.0
	pitch.max_value = 30.0
	pitch.step = 0.1
	pitch.suffix = "m"
	pitch.allow_lesser = false
	pitch.value = maxf(float(prefs["row_pitch_m"]), 0.0)
	pitch.tooltip_text = "Centre-to-centre distance between rows. 0 = Auto (no winter shading at this latitude)."
	pitch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pitch.value_changed.connect(func(v: float) -> void:
		PvGridSnap.set_pref("row_pitch_m", v if v > 0.0 else -1.0))
	row3.add_child(pitch)
	var line_up := Button.new()
	line_up.text = "Line up this array"
	line_up.tooltip_text = ("Put every rack that feeds the same controller into a grid anchored on "
		+ "this one (rows behind it at the row pitch)")
	UITheme.style_button(line_up)
	line_up.pressed.connect(_on_pv_line_up)
	_pv_section.add_child(line_up)
	_pv_section.get_parent().get_parent().visible = false


func _on_pv_line_up() -> void:
	if _prop_id.is_empty():
		return
	_resolve_main()
	var n := PlacedPropService.line_up_pv_array(_main, _prop_id)
	if n == 0:
		_hint("No other rack feeds this rack's controller")
	else:
		_hint("Lined up %s with this one" % UiText.count(n, "rack"))


func _sync_pv() -> void:
	if _pv_section == null:
		return
	var is_pv := str(_rec.get("model_id", "")) == PvArrayBuilder.MODEL_ID
	_pv_section.get_parent().get_parent().visible = is_pv
	if not is_pv:
		return
	var spec := PvArrayBuilder.resolve_spec(_rec.get("pv_array_spec", {}) as Dictionary)
	_pv_tilt.set_value_no_signal(float(spec["tilt_deg"]))
	var o := PvArrayBuilder.orientation_for(float(_tf.get("yaw", _rec.get("yaw", 0.0))),
			float(spec["tilt_deg"]))
	var bound := str(_rec.get("graph_item_id", ""))
	_pv_info.text = "%s · faces %.0f° (compass) at %.0f°%s" % [UiText.count(int(spec["count"]), "panel"),
			float(o["azimuth_deg"]), float(o["tilt_deg"]),
			"" if bound.is_empty() else " · drives graph array " + bound]


func _on_pv_tilt(v: float) -> void:
	if _syncing or _prop_id.is_empty():
		return
	var spec := (_rec.get("pv_array_spec", {}) as Dictionary).duplicate(true)
	spec["tilt_deg"] = v
	_resolve_main()
	# Rebuild THIS prop (the rack's geometry changes); the service tells the
	# graph, which re-orients the array and SolarUI.
	PlacedPropService.update_prop_record(_main, _prop_id, {"pv_array_spec": spec}, true)
	_rec["pv_array_spec"] = spec
	_sync_pv()


func _on_pv_face_equator() -> void:
	if _prop_id.is_empty():
		return
	_resolve_main()
	var lat := 45.0
	if _main != null and _main.get("latitude") != null:
		lat = float(_main.get("latitude"))
	_tf["yaw"] = PvArrayBuilder.yaw_for_azimuth(180.0 if lat >= 0.0 else 0.0)
	_dirty_tf = true
	_flush_transform()
	if _spins.has("yaw"):
		(_spins["yaw"] as SpinBox).set_value_no_signal(float(_tf["yaw"]))
	_sync_pv()


func _build_fire_section() -> void:
	var box := _section("Fire")
	_burnable_check = CheckBox.new()
	_burnable_check.text = "Burnable"
	_burnable_check.tooltip_text = "Can catch fire (F lights the nearest burnable prop)"
	_burnable_check.toggled.connect(_on_burnable_toggled)
	box.add_child(_burnable_check)
	_fire_box = VBoxContainer.new()
	_fire_box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	box.add_child(_fire_box)
	_fire_status = Label.new()
	_fire_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_fire_status.add_theme_color_override("font_color", C_TEXT)
	_fire_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fire_box.add_child(_fire_status)
	var tips := {
		"preroll_h": ["Pre-roll", "From ignition to the first flame. On a tagged Effigy this is the burn's run-up: the crowd gathers, the fire flow dances, the sandmen take the line (defaults to 45 min; 0 = catches at once)"],
		"climb_h": ["First flame → collapse", "How long the structure burns before it falls into its own fire"],
		"bonfire_h": ["Bonfire", "Open flame on the pile after the collapse"],
		"ember_h": ["Embers → ash", "From the last flame to cold grey ash"],
	}
	for key in ["preroll_h", "climb_h", "bonfire_h", "ember_h"]:
		var r := _row(_fire_box)
		var l := _small_label(tips[key][0], r, 120)
		l.tooltip_text = tips[key][1]
		var sb := SpinBox.new()
		sb.step = 1.0
		sb.min_value = 0.0 if key == "preroll_h" else 1.0
		sb.max_value = 48.0 * 60.0
		sb.allow_greater = true
		sb.suffix = " min"
		sb.tooltip_text = tips[key][1]
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.custom_minimum_size.x = 64.0
		sb.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_SM)
		sb.value_changed.connect(func(_v: float) -> void: _on_fire_spin(key))
		r.add_child(sb)
		_fire_spins[key] = sb
	_fire_auto_lbl = Label.new()
	_fire_auto_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_fire_auto_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_fire_auto_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fire_box.add_child(_fire_auto_lbl)
	var acts := _row(_fire_box)
	_fire_reset_btn = _button("Auto", "Back to the estimate from the structure's size and mass", acts, _on_fire_reset)
	_fire_ignite_btn = _button("Ignite", "Light it now, at the clock's current time", acts, _on_fire_ignite)
	_fire_ignite_btn.icon = UiIcons.icon("flame", 14)
	_fire_out_btn = _button("Put out", "Out, at the clock's current time (the char stays)", acts, _on_fire_put_out)
	_fire_restore_btn = _button("Restore", "Forget the fire: the structure as it was", acts, _on_fire_restore)


# ---------------------------------------------------------------------------
# record <-> widgets
# ---------------------------------------------------------------------------

func _load_record() -> void:
	_rec = {}
	if _loader == null or not _loader.has_method("get_prop_record"):
		return
	var rec: Variant = _loader.call("get_prop_record", _prop_id)
	if rec is Dictionary:
		_rec = (rec as Dictionary).duplicate(true)
	if _rec.is_empty():
		return
	var mid := str(_rec.get("model_id", ""))
	var y_off := 0.0
	if _rec.has("y_offset"):
		y_off = float(_rec["y_offset"])
	elif _rec.has("y"):
		var foot_y := ModelCatalog.foot_local_y(mid)
		var world_scale := ModelCatalog.resolved_scale(mid, float(_rec.get("scale", 1.0)))
		y_off = float(_rec["y"]) - (float(_rec.get("ground_y", 0.0)) - foot_y * world_scale)
	_tf = {
		"x": float(_rec.get("x", 0.0)), "y_offset": y_off, "z": float(_rec.get("z", 0.0)),
		"yaw": float(_rec.get("yaw", 0.0)), "pitch": float(_rec.get("pitch", 0.0)),
		"roll": float(_rec.get("roll", 0.0)), "scale": float(_rec.get("scale", 1.0)),
	}
	_dirty_tf = false


func _sync_widgets() -> void:
	_syncing = true
	var mid := str(_rec.get("model_id", ""))
	var entry := ModelCatalog.find(mid)
	_title_lbl.text = str(entry.get("label", mid)) if not entry.is_empty() else mid
	# Human words on screen; the internal id is in the tooltip for bug reports.
	var parts: PackedStringArray = ["Replaces an OSM building" if str(_rec.get("type", "")) == "osm" else "Placed"]
	var cat := str(entry.get("category", ""))
	if not cat.is_empty():
		parts.append(UiText.from_id(cat).to_lower())
	if bool(_rec.get("packed", false)):
		parts.append("packed")
	if not str(_rec.get("graph_item_id", "")).is_empty():
		parts.append("on the graph")
	_sub_lbl.text = " · ".join(parts)
	_sub_lbl.tooltip_text = "Prop id %s" % _prop_id
	_sub_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	for key in _spins:
		(_spins[key] as SpinBox).set_value_no_signal(float(_tf.get(key, 0.0)))
	_collision_check.set_pressed_no_signal(bool(_rec.get("collision_enabled", true)))
	_show3d_check.set_pressed_no_signal(not bool(_rec.get("hidden_3d", false)))
	_shadow_option.selected = maxi(_SHADOW_MODES.find(str(_rec.get("shadow_mode", ""))), 0)
	_model_option.clear()
	for m in ModelCatalog.all_models():
		_model_option.add_item(str(m.get("label", m.get("id", "?"))))
		_model_option.set_item_metadata(_model_option.item_count - 1, str(m.get("id", "")))
		if str(m.get("id", "")) == mid:
			_model_option.select(_model_option.item_count - 1)
	_space_row.bind_prop(_loader, _prop_id)
	_del_btn.text = "Remove OSM" if str(_rec.get("type", "")) == "osm" else "Delete"
	_sync_fire()
	_sync_firepit()
	_sync_pv()
	_syncing = false


## The per-model tools: whichever of the special editors applies, plus the
## shared ones. Rebuilt on every open (the model can change under us).
func _rebuild_dynamic_sections() -> void:
	for c in _model_btns.get_children():
		_model_btns.remove_child(c)
		c.queue_free()
	var mid := str(_rec.get("model_id", ""))
	var prop := _find_prop_node()
	_packed_lbl = Label.new()
	_packed_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_packed_lbl.add_theme_color_override("font_color", C_TEXT_S)
	_packed_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_model_btns.add_child(_packed_lbl)
	_refresh_packed_line()

	if ModelCatalog.is_starshade_model(mid):
		_button("StarShade design…", "Swap the design and reseed its graph", _model_btns, _on_starshade)
	if mid == PalletRackBuilder.MODEL_ID:
		_button("Edit rack…", "The parametric pallet-rack builder, bound to this rack", _model_btns, _on_pallet_rack)
	if mid == FlatpackBuilder.MODEL_ID:
		_button("Edit furniture…", "The flat-pack furniture designer, bound to this piece", _model_btns,
			_on_flatpack)
	if mid == DomeLabBuilder.MODEL_ID:
		_button("Edit dome…", "The dome & zome designer, bound to this structure", _model_btns, _on_domelab)
	if mid == ToroidLabBuilder.MODEL_ID:
		_button("Edit toroid…", "The toroid designer, bound to this structure", _model_btns, _on_toroidlab)
	if mid == GantryLabBuilder.MODEL_ID:
		_button("Edit gantry…", "The CNC gantry designer, bound to this machine (simulate and send jobs there)", _model_btns, _on_gantrylab)
	if prop != null and prop.get_node_or_null("CncMachineRuntime") != null:
		_button("Print setup…", "Part, slicer, bed preview, start", _model_btns, _on_print_setup)
	if mid == LinkageStructureBuilder.MODEL_ID:
		var deployed := bool(_rec.get("linkage_deployed", false))
		_button("Stow" if deployed else "Deploy", "Fold / unfold the structure (3 s)", _model_btns, _on_linkage_toggle)
		_button("Edit in Linkage Lab…", "The designer, bound to this structure", _model_btns, _on_edit_linkage)
		_button("Build guide…", "BOM, cut list, drill templates, crew plan", _model_btns, _on_build_guide)
		_build_rehearsal_row()
		if not bool(_rec.get("packed", false)):
			_button("Crew: break down", "Queue the crew to strip, fold and pack it", _model_btns, _on_crew_breakdown)
		elif str(_rec.get("stowed_in", "")).is_empty() and not (_rec.get("build_state") is Dictionary):
			_button("Crew: rebuild", "Queue the crew to raise the packed crate again", _model_btns, _on_crew_rebuild)
	if ModelCatalog.is_hydro_turbine(mid) or str(_rec.get("kind", "")) in ["siphon_hydro", "siphon_hoverboard"]:
		_button("Hydro Lab…", "The turbine's lab, on its graph node", _model_btns, _on_edit_siphon)
		_build_dip_tube_toggle()
	_build_material_fix_row(mid)
	_button("Connection ports…", "Where pipes and wires plug into this prop", _model_btns, _on_edit_ports)
	if not str(_rec.get("graph_item_id", "")).is_empty():
		_button("Open node in graph", "Select this prop's node in the systems graph", _model_btns, _on_open_in_graph)
	var spec := PlacedPropRuntime.packed_spec_for_record(_rec)
	if not spec.is_empty() and str(_rec.get("stowed_in", "")).is_empty():
		_pack_btn = _button("Unpack" if bool(_rec.get("packed", false)) else "Pack up",
			"Pack into its shipping form, or deploy it", _model_btns, _on_pack_toggled)
		_pack_btn.icon = UiIcons.icon("package", 14)


## User-imported models only: how SketchUp's invented gloss values are
## handled (ImportMaterialFixer). Auto = fix when the file is a SketchUp
## export; Off = the exporter's materials as they came; Force = fix anyway.
## Changing it rebuilds THIS prop now; other copies pick it up on rebuild.
func _build_material_fix_row(mid: String) -> void:
	var entry := ModelCatalog.find(mid)
	if not str(entry.get("path", "")).begins_with("user://"):
		return
	var row := _row(_model_btns)
	_small_label("Materials", row, 60)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var modes := [ImportMaterialFixer.MODE_AUTO, ImportMaterialFixer.MODE_OFF, ImportMaterialFixer.MODE_FORCE]
	var is_su := ModelCatalog.source_app_for(mid) == "sketchup"
	opt.add_item("Auto (SketchUp export: fixed)" if is_su else "Auto (not a SketchUp export)")
	opt.add_item("As exported")
	opt.add_item("Always fix gloss")
	opt.tooltip_text = "SketchUp has no gloss data, so its glTF exporters invent it (everything semi-glossy). Auto replaces it with real-world roughness by material name."
	opt.selected = maxi(modes.find(str(entry.get("material_fix", ImportMaterialFixer.MODE_AUTO))), 0)
	opt.item_selected.connect(func(i: int) -> void:
		var m := str(modes[clampi(i, 0, modes.size() - 1)])
		ModelCatalog.set_material_fix(mid, m)
		_resolve_main()
		# The mode lives on the catalog entry; writing it on the record too is
		# what triggers this prop's rebuild (an empty patch is a no-op).
		PlacedPropService.update_prop_record(_main, _prop_id, {"material_fix": m}, true))
	row.add_child(opt)


func _refresh_packed_line() -> void:
	var packed := PlacedPropRuntime.packed_spec_for_record(_rec)
	_packed_lbl.visible = not packed.is_empty()
	if packed.is_empty():
		return
	var est := "  (est.)" if str(packed.get("source", "")) == "estimated" else ""
	if bool(_rec.get("packed", false)):
		_packed_lbl.text = "Contains %s · %s%s" % [
			PlacedPropRuntime.packed_contents_label(_rec, get_tree().current_scene),
			PackedSpec.format_mass(packed), est]
	else:
		_packed_lbl.text = "Packs to %s · %s%s" % [
			PackedSpec.format_dims(packed), PackedSpec.format_mass(packed), est]


# ---------------------------------------------------------------------------
# transform: gizmo + numbers -> live preview -> commit
# ---------------------------------------------------------------------------

func _transform_patch() -> Dictionary:
	return {
		"x": float(_tf["x"]), "y_offset": float(_tf["y_offset"]), "z": float(_tf["z"]),
		"yaw": float(_tf["yaw"]), "pitch": float(_tf["pitch"]), "roll": float(_tf["roll"]),
		"scale": float(_tf["scale"]),
	}


func _on_tf_spin(key: String) -> void:
	if _syncing:
		return
	_tf[key] = (_spins[key] as SpinBox).value
	_push_transform(true)


## Show the live transform on the node now; `commit` persists it.
func _push_transform(commit: bool) -> void:
	if _loader == null or _prop_id.is_empty():
		return
	if _loader.has_method("preview_prop"):
		_loader.call("preview_prop", _prop_id, _transform_patch())
	_dirty_tf = true
	_syncing = true
	for key in _spins:
		(_spins[key] as SpinBox).set_value_no_signal(float(_tf.get(key, 0.0)))
	_syncing = false
	if commit:
		_flush_transform()
	_update_gizmo()


## Persist the live transform. Only THIS prop is rebuilt (the loader's
## update_prop_record rebuilds every prop and would pull the node out from
## under the gizmo); OSM replacements go through the loader so the building
## they replace is re-attached.
func _flush_transform() -> void:
	if not _dirty_tf or _loader == null or _prop_id.is_empty():
		return
	_dirty_tf = false
	var patch := _transform_patch()
	if str(_rec.get("type", "")) == "osm":
		if _loader.has_method("update_prop_record"):
			_loader.call("update_prop_record", _prop_id, patch)
	else:
		_resolve_main()
		PlacedPropService.update_prop_record(_main, _prop_id, patch, true)
	for k in patch:
		_rec[k] = patch[k]
	var sgv := ServiceLocator.graph()
	if sgv != null and sgv.has_method("sync_site_from_prop"):
		sgv.call("sync_site_from_prop", _prop_id)
	_sync_pv()


func _find_prop_node() -> PlacedProp:
	if _loader == null or _prop_id.is_empty():
		return null
	if _loader.has_method("_find_placed_prop_node"):
		return _loader.call("_find_placed_prop_node", _prop_id) as PlacedProp
	return null


func _ensure_gizmo() -> void:
	_resolve_main()
	if _gizmo == null or not is_instance_valid(_gizmo):
		_gizmo = LightGizmo.new()
		_gizmo.name = "PlacedPropGizmo"
		if _main != null:
			_main.add_child(_gizmo)


func _prop_basis() -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(float(_tf.get("pitch", 0.0))),
		deg_to_rad(float(_tf.get("yaw", 0.0))), deg_to_rad(float(_tf.get("roll", 0.0)))))


## The gizmo sits at the prop's origin — its ground point.
func _gizmo_origin() -> Vector3:
	var prop := _find_prop_node()
	if prop != null:
		return prop.global_position
	return Vector3(float(_tf.get("x", 0.0)), 0.0, float(_tf.get("z", 0.0)))


func _update_gizmo() -> void:
	if not _active or _gizmo == null or not is_instance_valid(_gizmo):
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or _rec.is_empty():
		_gizmo.hide_gizmo()
		return
	_gizmo.world_space = not _local_space
	_gizmo.show_move = _mode_move.button_pressed
	_gizmo.show_rotate = _mode_rotate.button_pressed
	_gizmo.set_target(_gizmo_origin(), _prop_basis(), cam, {})


func _toggle_space() -> void:
	_local_space = not _local_space
	_space_btn.text = "Local" if _local_space else "World"
	_update_gizmo()


func _process(delta: float) -> void:
	if not _active:
		return
	if _dragging:
		pass
	_update_gizmo()
	_fire_refresh_t += delta
	if _fire_refresh_t >= 0.5:
		_fire_refresh_t = 0.0
		_refresh_fire_status()


func _pointer_over_ui() -> bool:
	return visible and get_global_rect().has_point(get_viewport().get_mouse_position())


func _ray(mouse: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	return {"o": cam.project_ray_origin(mouse), "d": cam.project_ray_normal(mouse), "cam": cam}


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var k := event as InputEventKey
		if k.physical_keycode == KEY_L and not k.ctrl_pressed:
			_toggle_space()
			get_viewport().set_input_as_handled()
		elif k.physical_keycode == KEY_DELETE:
			_on_delete()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		var pos := (event as InputEventMouseMotion).position
		if _dragging:
			var r := _ray(pos)
			if not r.is_empty():
				_update_gizmo_drag(r)
			get_viewport().set_input_as_handled()
		elif _gizmo != null and not _pointer_over_ui() and not CursorController.overlay_look_active():
			var r2 := _ray(pos)
			if not r2.is_empty():
				_gizmo.set_hot(_gizmo.pick(r2["o"], r2["d"]))
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if _pointer_over_ui() or CursorController.overlay_look_active():
				return
			var r := _ray(mb.position)
			if r.is_empty():
				return
			var handle := _gizmo.pick(r["o"], r["d"]) if _gizmo != null else ""
			if not handle.is_empty():
				_begin_gizmo_drag(handle, r)
				get_viewport().set_input_as_handled()
				return
			# Clicking another placed prop switches the editor to it.
			var other := _pick_prop(r)
			if other != null and other.prop_id != _prop_id:
				open_for_prop(other.prop_id)
				get_viewport().set_input_as_handled()
		elif _dragging:
			_end_drag(true)
			get_viewport().set_input_as_handled()


## Physics ray → the PlacedProp under the pointer, if any.
func _pick_prop(r: Dictionary) -> PlacedProp:
	var cam := r["cam"] as Camera3D
	var space := cam.get_world_3d().direct_space_state
	if space == null:
		return null
	var q := PhysicsRayQueryParameters3D.create(r["o"], r["o"] + (r["d"] as Vector3) * 400.0)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var n: Node = hit.get("collider") as Node
	while n != null:
		if n is PlacedProp:
			return n as PlacedProp
		n = n.get_parent()
	return null


func _begin_gizmo_drag(handle: String, r: Dictionary) -> void:
	_dragging = true
	var o := _gizmo.global_position
	_drag = {"handle": handle, "origin": o, "tf0": _tf.duplicate(), "applied": Vector3.ZERO}
	if handle.begins_with("r"):
		var n := _gizmo.axis(handle)
		var hit: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, n)
		_drag["axis"] = n
		_drag["ref"] = ((hit as Vector3) - o) if hit != null else n.cross(Vector3.UP + Vector3(0.01, 0, 0))
	elif handle.length() == 1:
		var ax := _gizmo.axis(handle)
		_drag["axis"] = ax
		_drag["s0"] = LightGizmoMath.axis_param(r["o"], r["d"], o, ax)
	else:
		var n2 := _gizmo.plane_normal(handle)
		_drag["normal"] = n2
		_drag["hit0"] = LightGizmoMath.ray_plane(r["o"], r["d"], o, n2)
	_gizmo.set_hot(handle)
	var prop := _find_prop_node()
	if prop != null and prop.has_method("set_move_highlight"):
		prop.call("set_move_highlight", true)


func _update_gizmo_drag(r: Dictionary) -> void:
	var handle := str(_drag["handle"])
	var o: Vector3 = _drag["origin"]
	var snap := Input.is_key_pressed(KEY_SHIFT)
	var tf0: Dictionary = _drag["tf0"]
	if handle.begins_with("r"):
		var n: Vector3 = _drag["axis"]
		var hit: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, n)
		if hit == null:
			return
		var ang := LightGizmoMath.ring_angle(hit, o, n, _drag["ref"])
		if snap:
			ang = deg_to_rad(LightGizmoMath.snap(rad_to_deg(ang), SNAP_DEG))
		var rot0 := Vector3(float(tf0["pitch"]), float(tf0["yaw"]), float(tf0["roll"]))
		var rot := LightGizmoMath.rotate_by(rot0, n, ang, not _local_space)
		_tf["pitch"] = rot.x
		_tf["yaw"] = rot.y
		_tf["roll"] = rot.z
		_push_transform(false)
		_hint("Rotate %.1f°  (Shift snaps to %d°)" % [rad_to_deg(ang), int(SNAP_DEG)])
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
	_tf["x"] = float(tf0["x"]) + delta.x
	_tf["z"] = float(tf0["z"]) + delta.z
	_tf["y_offset"] = float(tf0["y_offset"]) + delta.y
	var row_hint := ""
	if str(_rec.get("model_id", "")) == PvArrayBuilder.MODEL_ID and not snap:
		_resolve_main()
		var res := PlacedPropService.pv_snap(_main, _rec.get("pv_array_spec", {}),
			float(_tf["x"]), float(_tf["z"]), float(_tf["yaw"]), _prop_id,
			PlacedPropService.pv_array_key(_main, str(_rec.get("graph_item_id", ""))))
		if bool(res.get("snapped", false)):
			_tf["x"] = float(res["x"])
			_tf["z"] = float(res["z"])
			_tf["yaw"] = float(res["yaw"])
			row_hint = "  · snapped %s" % ("into the row" if str(res.get("kind", "")) == "row" else "a row " + str(res.get("kind", "")))
		_pv_guides = PlacedPropService.draw_snap_guides(_pv_guides, _main, _main, res)
	_push_transform(false)
	_hint("Move %.2f m  (Shift snaps to %.2f m · Alt moves freely)%s" % [delta.length(), SNAP_M, row_hint])


func _end_drag(commit: bool) -> void:
	if not _dragging:
		return
	_dragging = false
	if _gizmo != null:
		_gizmo.set_hot("")
	var prop := _find_prop_node()
	if prop != null and prop.has_method("set_move_highlight"):
		prop.call("set_move_highlight", false)
	if _pv_guides != null and is_instance_valid(_pv_guides):
		_pv_guides.visible = false
	if commit:
		_flush_transform()
	else:
		_tf = (_drag["tf0"] as Dictionary).duplicate()
		_dirty_tf = true
		_push_transform(true)
	_drag = {}
	_hint("")


func _hint(text: String) -> void:
	if _hint_lbl != null:
		_hint_lbl.text = text


# ---------------------------------------------------------------------------
# display options
# ---------------------------------------------------------------------------

func _on_collision_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	_rec["collision_enabled"] = pressed
	_loader.call("update_prop_record", _prop_id, {"collision_enabled": pressed})


func _on_show3d_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	_rec["hidden_3d"] = not pressed
	_loader.call("update_prop_record", _prop_id, {"hidden_3d": not pressed})


func _on_shadow_mode_selected(idx: int) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	var mode: String = _SHADOW_MODES[clampi(idx, 0, _SHADOW_MODES.size() - 1)]
	_rec["shadow_mode"] = mode
	_loader.call("update_prop_record", _prop_id, {"shadow_mode": mode})
	var node := _find_prop_node()
	if node != null:
		node.set_meta("shadow_mode", mode)
		var radius := 0.0
		if node.has_method("get_local_pick_radius"):
			radius = float(node.call("get_local_pick_radius"))
		PropRenderTuning.apply_to_prop(node, radius)


func _on_model_changed(idx: int) -> void:
	if _syncing or _loader == null or _prop_id.is_empty() or idx < 0:
		return
	var mid := str(_model_option.get_item_metadata(idx))
	if mid.is_empty() or mid == str(_rec.get("model_id", "")):
		return
	_loader.call("update_prop_record", _prop_id, {"model_id": mid})
	open_for_prop(_prop_id)


func _on_pack_toggled() -> void:
	if _loader == null or _prop_id.is_empty() or not _loader.has_method("set_prop_packed"):
		return
	var now_packed := _loader.has_method("is_prop_packed") and bool(_loader.call("is_prop_packed", _prop_id))
	_loader.call("set_prop_packed", _prop_id, not now_packed)
	# The pack/unpack animates over a few frames; re-read once it has landed.
	get_tree().create_timer(0.2).timeout.connect(func() -> void:
		if _active and not _prop_id.is_empty():
			open_for_prop(_prop_id))


# ---------------------------------------------------------------------------
# fire
# ---------------------------------------------------------------------------

func _burn_rec() -> Dictionary:
	var b: Variant = _rec.get("burn", null)
	return b if FireTimeline.is_record(b) else {}


func _clock_hours() -> float:
	_resolve_main()
	if _main != null and _main.has_method("get_absolute_hours"):
		return float(_main.call("get_absolute_hours"))
	return 0.0


func _sync_fire() -> void:
	var burnable := bool(_rec.get("burnable", false))
	_burnable_check.set_pressed_no_signal(burnable)
	_fire_box.visible = burnable
	if not burnable:
		return
	var burn := _burn_rec()
	# Durations: the live record's while it burns, else the plan for when it
	# does (a pre-set choice, or the estimate from the geometry).
	var durations := burn if not burn.is_empty() else _fire_plan_or_estimate()
	for key in _fire_spins:
		(_fire_spins[key] as SpinBox).set_value_no_signal(round(float(durations.get(key, 0.0)) * 60.0))
	var auto: Dictionary = burn.get("auto", {}) if not burn.is_empty() else _estimate()
	_fire_auto_lbl.text = "Auto estimate: %s pre-roll · %s to collapse · %s bonfire · %s embers (%s of fuel)" % [
		FireTimeline.fmt_hours(float(auto.get("preroll_h", 0.0))),
		FireTimeline.fmt_hours(float(auto.get("climb_h", 0.0))),
		FireTimeline.fmt_hours(float(auto.get("bonfire_h", 0.0))),
		FireTimeline.fmt_hours(float(auto.get("ember_h", 0.0))),
		("%d kg" % int(float(auto.get("mass_kg", 0.0)))) if float(auto.get("mass_kg", -1.0)) > 0.0 else "unknown mass"]
	_fire_ignite_btn.visible = burn.is_empty()
	_fire_out_btn.visible = not burn.is_empty()
	_fire_restore_btn.visible = not burn.is_empty()
	_refresh_fire_status()


func _estimate() -> Dictionary:
	var prop := _find_prop_node()
	if prop == null:
		return {}
	return FireNode.estimate_for_prop(prop, _rec)


## The durations a fire lit NOW would use: the player's plan if set, else
## the estimate.
func _fire_plan_or_estimate() -> Dictionary:
	var plan: Variant = _rec.get("fire_plan", null)
	var est := _estimate()
	if plan is Dictionary:
		var out := est.duplicate()
		for k in ["preroll_h", "climb_h", "bonfire_h", "ember_h"]:
			if (plan as Dictionary).has(k):
				out[k] = float((plan as Dictionary)[k])
		return out
	return est


func _refresh_fire_status() -> void:
	if not _fire_box.visible:
		return
	var burn := _burn_rec()
	if burn.is_empty():
		var plan: Variant = _rec.get("fire_plan", null)
		_fire_status.text = "Not burning. %s" % (
			"Durations set by you." if plan is Dictionary else "Durations will be estimated when it catches.")
		return
	var t := _clock_hours()
	var st := FireTimeline.state_at(burn, t)
	var name := FireTimeline.phase_name(st)
	var line := ""
	match name:
		"none":
			line = "Lit at +%s from now." % FireTimeline.fmt_hours(float(burn["ignited_h"]) - t)
		"pre-roll":
			var pre := float(burn.get("preroll_h", 0.0))
			var stage := str(VenueCrowd.effigy_phase(burn, t).get("stage", ""))
			var doing := {VenueCrowd.STAGE_GATHER: "the crowd is gathering",
				VenueCrowd.STAGE_FLOW: "the fire flow is dancing",
				VenueCrowd.STAGE_SANDMEN: "the sandmen are taking the line"}
			line = "Lit — %s; flames in %s (gather %s · fire flow %s · sandmen %s)." % [
				str(doing.get(stage, "the crowd is forming the perimeter")),
				FireTimeline.fmt_hours(float(st["flame_in_h"])),
				FireTimeline.fmt_hours(pre * VenueCrowd.GATHER_FRAC),
				FireTimeline.fmt_hours(pre * (VenueCrowd.FLOW_END_FRAC - VenueCrowd.GATHER_FRAC)),
				FireTimeline.fmt_hours(pre * (1.0 - VenueCrowd.FLOW_END_FRAC))]
		"burning":
			line = "Burning — %d%% up, collapse in %s%s." % [int(float(st["progress"]) * 100.0),
				FireTimeline.fmt_hours(FireTimeline.climb_h(burn) - float(st["burn_h"])),
				" (held by the extinguisher)" if bool(st["held"]) else ""]
		"collapsing":
			line = "Collapsing."
		"bonfire":
			line = "Bonfire — flames for another %s." % FireTimeline.fmt_hours(
				FireTimeline.bonfire_h(burn) - float(st["age_h"]))
		"embers":
			line = "Embers — ash in %s." % FireTimeline.fmt_hours(
				FireTimeline.bonfire_h(burn) + FireTimeline.ember_h(burn) - float(st["age_h"]))
		"ash":
			line = "Burned to ash."
		"out":
			line = "Put out %s ago." % FireTimeline.fmt_hours(t - float(burn.get("out_h", t)))
	_fire_status.text = line


func _on_burnable_toggled(pressed: bool) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	_rec["burnable"] = pressed
	_loader.call("update_prop_record", _prop_id, {"burnable": pressed})
	FireNode.invalidate_flammable_mesh_cache()
	_syncing = true
	_sync_fire()
	_syncing = false


## A duration edit: onto the live burn record (the FireNode re-reads it) or
## onto the plan for a fire that has not started.
func _on_fire_spin(key: String) -> void:
	if _syncing or _loader == null or _prop_id.is_empty():
		return
	var hours := (_fire_spins[key] as SpinBox).value / 60.0
	var burn := _burn_rec()
	if not burn.is_empty():
		FireTimeline.set_duration(burn, key, hours)
		_rec["burn"] = burn
		_loader.call("set_prop_burn_record", _prop_id, burn)
	else:
		var plan: Dictionary = (_rec.get("fire_plan", {}) as Dictionary).duplicate() if _rec.get("fire_plan") is Dictionary else {}
		plan[key] = hours
		_rec["fire_plan"] = plan
		_loader.call("set_prop_fire_plan", _prop_id, plan)
	_refresh_fire_status()


func _on_fire_reset() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var burn := _burn_rec()
	if not burn.is_empty():
		FireTimeline.reset_to_auto(burn)
		_rec["burn"] = burn
		_loader.call("set_prop_burn_record", _prop_id, burn)
	else:
		_rec.erase("fire_plan")
		_loader.call("set_prop_fire_plan", _prop_id, {})
	_syncing = true
	_sync_fire()
	_syncing = false


func _on_fire_ignite() -> void:
	var prop := _find_prop_node()
	if prop == null:
		return
	var tree := get_tree()
	var manager := tree.get_first_node_in_group("crisis_event_manager")
	if manager == null and tree.current_scene != null:
		manager = tree.current_scene.get_node_or_null("CrisisEventManager")
	if manager == null or not manager.has_method("trigger_event_manual"):
		_hint("No crisis manager on this map")
		return
	var ev := FireEvent.new()
	var roots: Array[Node3D] = [prop]
	manager.call("trigger_event_manual", ev, {"structure": prop, "burnable_roots": roots,
		"restrict_to_structure": true, "prefer_bottom": true})
	get_tree().create_timer(0.3).timeout.connect(func() -> void:
		if _active and not _prop_id.is_empty():
			_load_record()
			_syncing = true
			_sync_fire()
			_syncing = false)


func _on_fire_put_out() -> void:
	var burn := _burn_rec()
	if burn.is_empty() or _loader == null:
		return
	FireTimeline.put_out(burn, _clock_hours())
	_rec["burn"] = burn
	_loader.call("set_prop_burn_record", _prop_id, burn)
	_refresh_fire_status()


func _on_fire_restore() -> void:
	var prop := _find_prop_node()
	if prop != null and prop.has_method("restore_after_burn"):
		prop.call("restore_after_burn")
	elif _loader != null and _loader.has_method("clear_prop_burn_record"):
		_loader.call("clear_prop_burn_record", _prop_id)
	_rec.erase("burn")
	_syncing = true
	_sync_fire()
	_syncing = false


# ---------------------------------------------------------------------------
# model tools
# ---------------------------------------------------------------------------

func _graph() -> Node:
	return ServiceLocator.graph()


func _on_starshade() -> void:
	var pid := _prop_id
	if _loader != null and _loader.has_method("open_starshade_editor"):
		close()
		_loader.call("open_starshade_editor", pid)


func _on_pallet_rack() -> void:
	var pid := _prop_id
	if _loader != null and _loader.has_method("open_pallet_rack_builder_for_prop"):
		close()
		_loader.call("open_pallet_rack_builder_for_prop", pid)


func _on_flatpack() -> void:
	var pid := _prop_id
	if _loader != null and _loader.has_method("open_flatpack_designer_for_prop"):
		close()
		_loader.call("open_flatpack_designer_for_prop", pid)


func _on_domelab() -> void:
	var pid := _prop_id
	if _loader != null and _loader.has_method("open_domelab_for_prop"):
		close()
		_loader.call("open_domelab_for_prop", pid)


func _on_toroidlab() -> void:
	var pid := _prop_id
	if _loader != null and _loader.has_method("open_toroidlab_for_prop"):
		close()
		_loader.call("open_toroidlab_for_prop", pid)


func _on_gantrylab() -> void:
	var pid := _prop_id
	if _loader != null and _loader.has_method("open_gantrylab_for_prop"):
		close()
		_loader.call("open_gantrylab_for_prop", pid)


func _on_print_setup() -> void:
	var pid := _prop_id
	var gv := _graph()
	if gv != null and gv.has_method("open_print_setup_for_prop"):
		close()
		gv.call("open_print_setup_for_prop", pid)


func _on_linkage_toggle() -> void:
	var prop := _find_prop_node()
	if prop == null:
		return
	var deploy := prop.get_node_or_null("LinkageDeployRuntime")
	if deploy != null and deploy.has_method("toggle_deploy"):
		deploy.call("toggle_deploy")
		get_tree().create_timer(3.2).timeout.connect(func() -> void:
			if _active and not _prop_id.is_empty():
				open_for_prop(_prop_id))


func _on_edit_linkage() -> void:
	var pid := _prop_id
	_resolve_main()
	if _main != null and _main.has_method("open_linkage_lab_for_prop"):
		close()
		_main.call("open_linkage_lab_for_prop", pid)


## "Rehearse build": a crew of N builds this structure from bare ground,
## following the world clock (speed it up to watch it go up quickly; scrub
## back to see it again). The record rides the prop (build_run).
func _build_rehearsal_row() -> void:
	var run = _rec.get(LinkageBuildSite.RECORD_KEY)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_model_btns.add_child(row)
	var lbl := Label.new()
	lbl.text = "Crew"
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(lbl)
	var crew := SpinBox.new()
	crew.min_value = 1
	crew.max_value = 40
	var crew_n0: int = LinkageBuildSite.DEFAULT_CREW
	if run is Dictionary:
		crew_n0 = int((run as Dictionary).get("crew_n", LinkageBuildSite.DEFAULT_CREW))
	crew.value = crew_n0
	crew.tooltip_text = "How many people build it"
	row.add_child(crew)
	var go := _button("Rehearse build" if not (run is Dictionary) else "Restart build",
		"Watch a crew cut, drill, place, bolt, lift and deploy it, on the world clock", row,
		func() -> void:
			_resolve_main()
			if _main != null and LinkageBuildSite.start_rehearsal(_main, _prop_id, int(crew.value)):
				open_for_prop(_prop_id))
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if run is Dictionary:
		var line := Label.new()
		line.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		line.add_theme_color_override("font_color", C_TEXT_S)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_model_btns.add_child(line)
		var tick := func() -> void:
			_resolve_main()
			var site := LinkageBuildSite.site_for(_main, _prop_id) if _main != null else null
			line.text = site.progress_line() if site != null else ""
		tick.call()
		var timer := Timer.new()
		timer.wait_time = 0.5
		timer.autostart = true
		timer.timeout.connect(tick)
		line.add_child(timer)
		_button("End rehearsal", "Clear the build; the structure stands as before", _model_btns,
			func() -> void:
				_resolve_main()
				if _main != null:
					LinkageBuildSite.clear_rehearsal(_main, _prop_id)
					open_for_prop(_prop_id))


func _on_build_guide() -> void:
	var pid := _prop_id
	_resolve_main()
	if _main != null and _main.has_method("open_linkage_build_guide_for_prop"):
		close()
		_main.call("open_linkage_build_guide_for_prop", pid)


## "Show dip tube": a SIPHON turbine's 6″ dip tube drawn in the world, off
## by default (it is under water). Lives on the GRAPH item's specs
## (`show_dip_tube`) — the Lab's Siphon section carries the same box.
func _build_dip_tube_toggle() -> void:
	var graph_id := str(_rec.get("graph_item_id", ""))
	var gv := _graph()
	if gv == null or graph_id.is_empty():
		return
	var model: Variant = gv.get("model")
	if model == null or not (model as Object).has_method("get_item"):
		return
	var item: Dictionary = model.call("get_item", graph_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if bool(HydroSource.kind_meta(str(specs.get("turbine_kind", "siphon"))).get("has_penstock", false)):
		return
	var cb := CheckBox.new()
	cb.text = "Show dip tube"
	cb.tooltip_text = "Draw the 6″ dip tube hanging straight down from the intake fitting into the pond (off by default — it is under water)"
	cb.set_pressed_no_signal(bool(specs.get("show_dip_tube", false)))
	cb.toggled.connect(func(on: bool) -> void:
		var it: Dictionary = model.call("get_item", graph_id)
		if it.is_empty():
			return
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp["show_dip_tube"] = on
		model.call("update_item", graph_id, {"specs": sp}))
	_model_btns.add_child(cb)


func _on_edit_siphon() -> void:
	var graph_id := str(_rec.get("graph_item_id", ""))
	var gv := _graph()
	if gv == null:
		return
	if gv.has_method("open_siphon_lab") and not graph_id.is_empty():
		close()
		gv.visible = true
		gv.call("open_siphon_lab", graph_id)
	elif gv.has_method("_show_toast"):
		gv.call("_show_toast", "Bind this prop to a hydro turbine graph node first")


func _on_open_in_graph() -> void:
	var graph_id := str(_rec.get("graph_item_id", ""))
	var gv := _graph()
	if gv == null or graph_id.is_empty() or not gv.has_method("open_node_in_graph"):
		return
	close()
	gv.call("open_node_in_graph", graph_id)


func _on_edit_ports() -> void:
	var pid := _prop_id
	var gv := _graph()
	if gv != null and gv.has_method("open_connection_ports_for_prop"):
		close()
		gv.call("open_connection_ports_for_prop", pid)


## Queue the REVERSE Site Project on a deployed linkage structure: strip
## panels → unbolt → fold & pack (the stow sweep) → haul the crate to the
## nearest container's door when one stands within reach.
func _on_crew_breakdown() -> void:
	if _prop_id.is_empty():
		return
	var scene := get_tree().current_scene
	var sgv: Node = _graph()
	var bridge: Variant = sgv.call("npc_population_bridge") \
		if sgv != null and sgv.has_method("npc_population_bridge") else null
	if bridge == null:
		return
	var iid := str(bridge.call("first_crewable_habitat"))
	if iid.is_empty():
		if sgv.has_method("_show_toast"):
			sgv.call("_show_toast", "Needs a pop-driven habitat with people on site")
		return
	var rec: Dictionary = PlacedPropService.get_prop_record(scene, _prop_id)
	if rec.is_empty() or not (rec.get("linkage_spec") is Dictionary):
		return
	var p := LinkageParams.new()
	p.from_config(rec.get("linkage_spec") as Dictionary)
	var counts: Dictionary = {}
	var prop := _find_prop_node()
	if prop != null:
		var mr := prop.get_node_or_null("ModelRoot")
		if mr != null and mr.has_method("get_stats"):
			counts = LinkageBom.fab_counts(LinkageBom.compute(p), mr.call("get_stats") as Dictionary)
	if counts.is_empty():
		counts = LinkageBom.fab_counts(LinkageBom.compute(p), {})
	var site := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	var loadout: Dictionary = {}
	if _loader != null and _loader.has_method("placed_prop_records"):
		var best_d := 200.0
		for r in (_loader.call("placed_prop_records") as Array):
			var cr := r as Dictionary
			if str(cr.get("model_id", "")) != "cargo_container":
				continue
			var cpos := Vector2(float(cr.get("x", 0.0)), float(cr.get("z", 0.0)))
			var dist := site.distance_to(cpos)
			if dist < best_d:
				best_d = dist
				var yaw := deg_to_rad(float(cr.get("yaw", 0.0)))
				var door := cpos + Vector2(sin(yaw), cos(yaw)) * 5.0
				loadout = {"x": door.x, "z": door.y}
	var rows := SiteProject.breakdown_spec_rows(counts, _prop_id, loadout)
	var project_id := str(bridge.call("create_site_project", iid,
		SiteProject.KIND_LINKAGE_BREAKDOWN, "Breakdown: linkage structure",
		_prop_id, site, rows, {"start_h": 7.0, "end_h": 19.0},
		{"kind": "prop", "id": _prop_id}, {}))
	if project_id.is_empty():
		if sgv.has_method("_show_toast"):
			sgv.call("_show_toast", "Chore board is full — clear some chores first")
		return
	if sgv.has_method("notify_crew_queued"):
		sgv.call("notify_crew_queued", site, "👷 Breakdown queued — %s" % UiText.count(rows.size(), "phase"))


func _on_crew_rebuild() -> void:
	if _prop_id.is_empty():
		return
	var sgv: Node = _graph()
	var res := PlacedPropService.queue_linkage_rebuild(get_tree().current_scene, _prop_id)
	if not bool(res.get("ok", false)):
		if sgv != null and sgv.has_method("_show_toast") and not str(res.get("error", "")).is_empty():
			sgv.call("_show_toast", str(res.get("error", "")))
		return
	if sgv != null and sgv.has_method("notify_crew_queued"):
		sgv.call("notify_crew_queued", res.get("site", Vector2.ZERO), "👷 Rebuild queued — the crew raises it again")


# ---------------------------------------------------------------------------
# footer
# ---------------------------------------------------------------------------

func _on_free_move() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var pid := _prop_id
	close()
	if _loader.has_method("begin_prop_reposition"):
		_loader.call("begin_prop_reposition", pid)


## A copy one footprint over, selected.
func _on_duplicate() -> void:
	if _loader == null or _prop_id.is_empty() or _rec.is_empty():
		return
	_flush_transform()
	_resolve_main()
	var mid := str(_rec.get("model_id", ""))
	var metrics := ModelCatalog.mesh_metrics(mid)
	var w := maxf(float(metrics.get("width", 2.0)) * ModelCatalog.resolved_scale(mid, float(_rec.get("scale", 1.0))), 1.0) + 0.5
	var yaw := deg_to_rad(float(_rec.get("yaw", 0.0)))
	var side := Vector2(cos(yaw), -sin(yaw)) * w
	var copy := _rec.duplicate(true)
	for k in ["id", "burn", "graph_item_id", "stowed_in", "packed", "build_state"]:
		copy.erase(k)
	copy["x"] = float(_rec.get("x", 0.0)) + side.x
	copy["z"] = float(_rec.get("z", 0.0)) + side.y
	if not _loader.has_method("duplicate_prop_record"):
		_hint("This map cannot duplicate props")
		return
	var new_id := str(_loader.call("duplicate_prop_record", copy))
	if not new_id.is_empty():
		open_for_prop(new_id)
		_hint("Copied. This is the copy.")


func _on_delete() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	if not _del_armed:
		_del_armed = true
		_del_btn.text = "Confirm delete?"
		_del_btn.add_theme_color_override("font_color", UITheme.C_ERROR)
		_hint("Click again to delete, Esc to keep it.")
		return
	var pid := _prop_id
	_disarm_delete()
	if _loader.has_method("delete_prop_by_id"):
		_loader.call("delete_prop_by_id", pid)
	close()


func _disarm_delete() -> void:
	_del_armed = false
	if _del_btn != null:
		_del_btn.text = "Remove OSM" if str(_rec.get("type", "")) == "osm" else "Delete"
		_del_btn.remove_theme_color_override("font_color")
