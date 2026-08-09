extends PanelContainer

## Edit drawer for a placed prop — transform tweaks + delete/replace.
##
## Laid out as TWO rows: edit controls (model, transform, NPC space tag) above,
## actions (toggles, sub-editors, Apply/Delete/Close) below. It was one row
## until the NPC space tag was added, at which point the total ran past 1900 px
## and pushed **Apply** — which sits near the end — off the right edge of a
## 1920-wide screen, with no scroll or wrap to recover it.

const C_BG := Color(0.039, 0.055, 0.098, 0.98)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)

## Matches slim TimelineUI stack clearance when live height unavailable.
## Two rows tall (see the class comment on why it is no longer one).
const DRAWER_HEIGHT := 104.0

var _loader: Node = null
var _prop_id: String = ""
var _syncing := false

var _model_lbl: Label
var _packed_lbl: Label
var _pack_btn: Button = null
var _crew_breakdown_btn: Button = null
var _crew_rebuild_btn: Button = null
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
var _space_row: NpcSpaceTagRow
var _del_btn: Button
var _move_btn: Button
var _linkage_btn: Button
var _guide_btn: Button
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
			gv = ServiceLocator.graph()
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
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	margin.add_child(root)

	# Row 1 — what the prop IS: model, transform, and how people use it.
	var row_edit := HBoxContainer.new()
	row_edit.add_theme_constant_override("separation", 10)
	root.add_child(row_edit)
	# Row 2 — what you can DO to it, ending in Apply / Delete / Close.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	root.add_child(actions)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	left.custom_minimum_size.x = 160.0
	row_edit.add_child(left)

	_model_lbl = Label.new()
	_model_lbl.add_theme_color_override("font_color", C_TEXT)
	_model_lbl.add_theme_font_size_override("font_size", 11)
	left.add_child(_model_lbl)

	# Packed ("shipping") size + weight — PACKING_PLAN.md Phase 0.
	_packed_lbl = Label.new()
	_packed_lbl.add_theme_color_override("font_color",
		Color(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.65))
	_packed_lbl.add_theme_font_size_override("font_size", 10)
	_packed_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_packed_lbl.visible = false
	left.add_child(_packed_lbl)

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
	row_edit.add_child(fields)
	fields.add_child(_compact_field("X", _off_x))
	fields.add_child(_compact_field("Y", _off_y))
	fields.add_child(_compact_field("Z", _off_z))
	fields.add_child(_compact_field("Yaw", _yaw))
	fields.add_child(_compact_field("Pitch", _pitch))
	fields.add_child(_compact_field("Roll", _roll))
	fields.add_child(_compact_field("Scale", _scale))

	for spin_box in [_off_x, _off_y, _off_z, _yaw, _pitch, _roll, _scale]:
		spin_box.value_changed.connect(_on_spin_changed)

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

	# NPC space tag. Shared widget (scenes/ui/npc_space_tag_row.gd) so the
	# props with their own modals can offer the same control — see that file.
	_space_row = NpcSpaceTagRow.new()
	row_edit.add_child(_space_row)

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

	# PACKED ⇄ DEPLOYED (PACKING_PLAN.md Phase 5). Hidden for non-packable
	# props; Interact on a packed crate is the other unpack path.
	_pack_btn = Button.new()
	_pack_btn.tooltip_text = "Collapse to the packed shipping form / deploy it again"
	_pack_btn.pressed.connect(_on_pack_toggled)
	_pack_btn.visible = false
	actions.add_child(_pack_btn)

	_crew_breakdown_btn = Button.new()
	_crew_breakdown_btn.text = "👷 Crew breakdown"
	_crew_breakdown_btn.tooltip_text = "Queue the reverse project: strip panels → unbolt → fold & pack → load out"
	_crew_breakdown_btn.pressed.connect(_on_crew_breakdown)
	_crew_breakdown_btn.visible = false
	actions.add_child(_crew_breakdown_btn)

	_crew_rebuild_btn = Button.new()
	_crew_rebuild_btn.text = "👷 Crew rebuild"
	_crew_rebuild_btn.tooltip_text = "Queue the raise: the crew unfolds the frame, re-bolts the ring and re-mounts the panels"
	_crew_rebuild_btn.pressed.connect(_on_crew_rebuild)
	_crew_rebuild_btn.visible = false
	actions.add_child(_crew_rebuild_btn)

	_linkage_btn = Button.new()
	_linkage_btn.text = "Linkage Lab"
	_linkage_btn.tooltip_text = "Edit this structure's linkage design in place"
	_linkage_btn.pressed.connect(_on_edit_linkage)
	_linkage_btn.visible = false
	actions.add_child(_linkage_btn)

	_guide_btn = Button.new()
	_guide_btn.text = "Build guide"
	_guide_btn.tooltip_text = "Bill of materials, cut list, drill templates and assembly sequence for this structure"
	_guide_btn.pressed.connect(_on_build_guide)
	_guide_btn.visible = false
	actions.add_child(_guide_btn)

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

	var tail_spacer := Control.new()
	tail_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(tail_spacer)

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
	_refresh_packed_line(d)
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
	if _guide_btn != null:
		_guide_btn.visible = str(d.get("model_id", "")) == LinkageStructureBuilder.MODEL_ID
	if _siphon_btn != null:
		var mid := str(d.get("model_id", ""))
		var kind := str(d.get("kind", ""))
		_siphon_btn.visible = mid == "hydroturbine" or kind == "siphon_hydro" \
				or kind == "siphon_hoverboard"
	_refresh_restore_visibility()
	_space_row.bind_prop(_loader, _prop_id)

	if _del_btn != null:
		var is_osm := str(d.get("type", "")) == "osm"
		if is_osm:
			_del_btn.text = "Remove OSM"
		else:
			_del_btn.text = "Delete"
	_syncing = false


## Packed ("shipping") line under the model name — PACKING_PLAN.md Phase 0.
## Linkage props compute theirs from the live design (honest-fold envelope);
## everything else resolves through PackedSpec; unknown/non-packable hides.
func _refresh_packed_line(d: Dictionary) -> void:
	if _packed_lbl == null:
		return
	var packed: Dictionary = {}
	if d.has("linkage_spec") and d.get("linkage_spec") is Dictionary:
		var p := LinkageParams.new()
		p.from_config(d.get("linkage_spec") as Dictionary)
		packed = LinkageStructureBuilder.packed_spec_for(p)
	elif d.has("container_spec") and d.get("container_spec") is Dictionary:
		packed = ContainerCatalog.packed_spec_for(
			str((d.get("container_spec") as Dictionary).get("container_id", "")))
	if packed.is_empty():
		packed = PackedSpec.for_model(str(d.get("model_id", "")))
	_packed_lbl.visible = not packed.is_empty()
	if _pack_btn != null:
		_pack_btn.visible = not packed.is_empty()
		_pack_btn.text = "Unpack" if bool(d.get("packed", false)) else "📦 Pack up"
	if _crew_breakdown_btn != null:
		# Reverse project: a DEPLOYED linkage structure only (the crew strips,
		# unbolts, folds and loads it out — packed crates just get carried).
		_crew_breakdown_btn.visible = d.get("linkage_spec") is Dictionary \
			and not bool(d.get("packed", false))
	if _crew_rebuild_btn != null:
		# The mirror: a PACKED linkage crate whose parts were already
		# fabricated — the crew raises it again (no cutting or drilling).
		# Hidden while stowed in a container: unload the delivery first.
		_crew_rebuild_btn.visible = d.get("linkage_spec") is Dictionary \
			and bool(d.get("packed", false)) \
			and str(d.get("stowed_in", "")).is_empty() \
			and not (d.get("build_state") is Dictionary)
	if packed.is_empty():
		return
	var est := "  (est.)" if str(packed.get("source", "")) == "estimated" else ""
	_packed_lbl.text = "📦 Packs to %s · %s%s" % [
		PackedSpec.format_dims(packed), PackedSpec.format_mass(packed), est]


func _on_pack_toggled() -> void:
	if _loader == null or _prop_id.is_empty() \
			or not _loader.has_method("set_prop_packed"):
		return
	var now_packed := _loader.has_method("is_prop_packed") \
		and bool(_loader.call("is_prop_packed", _prop_id))
	_loader.call("set_prop_packed", _prop_id, not now_packed)
	_load_from_layer()


## Queue the REVERSE Site Project on a deployed linkage structure: strip
## panels → unbolt → fold & pack (the stow sweep) → haul the crate to the
## nearest container's door when one stands within reach. The chore board's
## dependency gates run it; effects land through the bridge's post-tick sweep.
func _on_crew_breakdown() -> void:
	if _prop_id.is_empty():
		return
	var scene := get_tree().current_scene
	var sgv: Node = ServiceLocator.graph()
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
	# Fab counts from the live builder standing at the prop (same sharpening
	# the Lab's queue-build uses); a missing node degrades to BOM-only counts.
	var counts: Dictionary = {}
	var root := scene.find_child("PlacedProps", true, false) if scene != null else null
	if root != null:
		for child in root.get_children():
			if child is PlacedProp and str((child as PlacedProp).prop_id) == _prop_id:
				var mr := child.get_node_or_null("ModelRoot")
				if mr != null and mr.has_method("get_stats"):
					counts = LinkageBom.fab_counts(LinkageBom.compute(p),
						mr.call("get_stats") as Dictionary)
				break
	if counts.is_empty():
		counts = LinkageBom.fab_counts(LinkageBom.compute(p), {})
	var site := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	# Load-out destination: the nearest cargo container's door, if one stands
	# within 200 m — otherwise the crate stays at the fold site.
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
	if sgv.has_method("watch_site_at"):
		sgv.call("watch_site_at", site,
			"👷 Breakdown project queued — %d phases" % rows.size())


## The mirror of _on_crew_breakdown: raise a packed, already-fabricated
## linkage crate again. Same crew plumbing; the rows come from
## SiteProject.rebuild_spec_rows (raise → bolt ring → mount panels — the
## parts exist, so no cutting or drilling), and the raise's unpack effect IS
## the deploy sweep the player would otherwise trigger by hand with Interact.
func _on_crew_rebuild() -> void:
	if _prop_id.is_empty():
		return
	var scene := get_tree().current_scene
	var sgv: Node = ServiceLocator.graph()
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
	var counts := LinkageBom.fab_counts(LinkageBom.compute(p), {})
	var site := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	var rows := SiteProject.rebuild_spec_rows(counts, _prop_id)
	var project_id := str(bridge.call("create_site_project", iid,
		SiteProject.KIND_LINKAGE_BUILD, "Rebuild: linkage structure",
		_prop_id, site, rows, {"start_h": 7.0, "end_h": 19.0},
		{"kind": "prop", "id": _prop_id}, {}))
	if project_id.is_empty():
		if sgv.has_method("_show_toast"):
			sgv.call("_show_toast", "Chore board is full — clear some chores first")
		return
	if sgv.has_method("watch_site_at"):
		sgv.call("watch_site_at", site,
			"👷 Rebuild queued — the crew raises it again (%d phases)" % rows.size())


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


## "Build guide": the BOM / cut list / drill templates for this structure,
## without having to open the designer first.
func _on_build_guide() -> void:
	if _prop_id.is_empty():
		return
	var pid := _prop_id
	close()
	var main := get_tree().current_scene
	if main != null and main.has_method("open_linkage_build_guide_for_prop"):
		main.call("open_linkage_build_guide_for_prop", pid)


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
			gv = ServiceLocator.graph()
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
			gv = ServiceLocator.graph()
	if gv != null and gv.has_method("open_connection_ports_for_prop"):
		gv.call("open_connection_ports_for_prop", pid)
