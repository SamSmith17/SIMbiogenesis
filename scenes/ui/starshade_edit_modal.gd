extends Control

## StarShade-specific editor — swap design (catalog family), edit panel/watts
## specs, and re-seed the system graph via StarShadeGraphSeeder. A ModalFrame
## form (the kit's dialog shape): FormRows in the body, Apply / Re-seed /
## Close in the footer, the NPC space tag row under them.

const MODAL_NAME := "starshade_edit"

var _loader: Node = null
var _prop_id: String = ""
var _space_row: NpcSpaceTagRow
var _active := false
var _frame: ModalFrame = null
var _design_opt: OptionButton = null
var _designs: Array = []
var _count_spin: SpinBox = null
var _watts_spin: SpinBox = null
var _status: Label = null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open_for_prop(prop_id: String) -> void:
	if prop_id.is_empty():
		return
	_prop_id = prop_id
	_refresh_designs()
	_load_from_prop()
	if _space_row != null:
		_space_row.bind_prop(_loader, prop_id)
	_activate()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	_frame.close()
	_prop_id = ""


func _activate() -> void:
	_active = true
	visible = true
	_frame.open()


func _build_ui() -> void:
	_frame = ModalFrame.create("StarShade", "swap the design, set the PV specs, re-seed the graph",
		Vector2(560, 440), MODAL_NAME)
	add_child(_frame)
	_frame.closed.connect(close)
	var body := _frame.body
	body.add_theme_constant_override("separation", UITheme.SPACE_XS)

	_design_opt = OptionButton.new()
	_design_opt.focus_mode = Control.FOCUS_NONE
	body.add_child(FormRow.make("Design", _design_opt, "The StarShade model family this prop is built from",
		"", "starshade_design"))
	var count_row := FormRow.spin("Panel count", 1, 48, 1, "", Callable(),
		"How many PV panels the graph seeds for this structure", "panel_count")
	_count_spin = count_row.control as SpinBox
	_count_spin.value = StarShadeGraphSeeder.DEFAULT_PANEL_COUNT
	body.add_child(count_row)
	var watts_row := FormRow.spin("Watts per panel", 50, 600, 10, "W", Callable(),
		"Each panel's nameplate", "panel_watts")
	_watts_spin = watts_row.control as SpinBox
	_watts_spin.value = StarShadeGraphSeeder.DEFAULT_PANEL_WATTS
	body.add_child(watts_row)

	_status = Label.new()
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_status)

	# StarShades route here instead of the generic prop drawer, so without this
	# row they would be the one kind of prop that can never be tagged as an NPC
	# space (see npc_space_tag_row.gd).
	body.add_child(SectionHeader.make("People", "", "a space they walk to"))
	_space_row = NpcSpaceTagRow.new()
	body.add_child(_space_row)

	_frame.add_button("Lights & strings…", ModalFrame.SECONDARY, _on_lights,
		"Attach lights and strings to this StarShade in a 3D studio")
	_frame.add_button("Apply design", ModalFrame.SECONDARY, _on_apply_design,
		"Rebuild the prop with the chosen design and specs")
	_frame.add_button("Re-seed graph", ModalFrame.PRIMARY, _on_reseed,
		"Apply, then replace the structure's panels on the graph")
	_frame.add_button("Close", ModalFrame.SECONDARY, close)


func _refresh_designs() -> void:
	_designs.clear()
	if _design_opt == null:
		return
	_design_opt.clear()
	for m in ModelCatalog.starshade_designs():
		_designs.append(m)
		_design_opt.add_item(str(m.get("label", m.get("id", "?"))))


func _load_from_prop() -> void:
	if _loader == null or _prop_id.is_empty():
		return
	var layer = _loader.get("_placed_prop_layer")
	if layer == null:
		return
	var rec: Dictionary = layer.find_by_id(_prop_id) if layer.has_method("find_by_id") else {}
	if rec.is_empty():
		return
	var mid := str(rec.get("model_id", ""))
	for i in _designs.size():
		if str((_designs[i] as Dictionary).get("id", "")) == mid:
			_design_opt.select(i)
			break
	var solar: Dictionary = rec.get("solar", {}) as Dictionary
	if solar.is_empty() and rec.has("record_extra"):
		solar = (rec.get("record_extra", {}) as Dictionary).get("solar", {}) as Dictionary
	_count_spin.value = int(solar.get("panelCount", StarShadeGraphSeeder.DEFAULT_PANEL_COUNT))
	_watts_spin.value = float(solar.get("panelWatts", StarShadeGraphSeeder.DEFAULT_PANEL_WATTS))
	_status.text = I18n.f("{count_spin} on the graph", {"count_spin": UiText.count(int(_count_spin.value), "panel")})


func _on_apply_design() -> void:
	if _loader == null or _prop_id.is_empty() or _designs.is_empty():
		return
	var idx := _design_opt.selected
	if idx < 0 or idx >= _designs.size():
		return
	var mid := str((_designs[idx] as Dictionary).get("id", ""))
	var layer = _loader.get("_placed_prop_layer")
	if layer == null or not layer.has_method("update_prop"):
		return
	layer.update_prop(_prop_id, {
		"model_id": mid,
		"solar": {
			"panelCount": int(_count_spin.value),
			"panelWatts": float(_watts_spin.value),
		},
	})
	if _loader.has_method("rebuild_placed_props"):
		_loader.call("rebuild_placed_props")
	_status.text = I18n.f("Design set to {label}", {"label": str((_designs[idx] as Dictionary).get("label", mid))})


func _on_reseed() -> void:
	_on_apply_design()
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		_status.text = "No main scene"
		return
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null:
		_status.text = "System graph not found"
		return
	var model: GraphModel = sgv.get("model") as GraphModel
	if model == null:
		_status.text = "Graph model missing"
		return
	var n := int(_count_spin.value)
	var w := float(_watts_spin.value)
	if StarShadeGraphSeeder.reseed_graph(model, n, w, StarShadeGraphSeeder.STARSHADE_TAG):
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")
		_status.text = I18n.f("Re-seeded the graph: {value} × {w}", {"value": UiText.count(n, "panel"), "w": UiText.num(w, "W")})
	else:
		_status.text = "Re-seed failed"


func _on_lights() -> void:
	var pid := _prop_id
	if pid.is_empty():
		return
	var tree := get_tree()
	close()
	PropLightsModal.open(tree, pid)

