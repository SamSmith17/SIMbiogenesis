extends Control
## Build Guide — the printable side of the Linkage Lab.
##
## Everything a crew needs to actually build the design that is open in the
## Lab: a priced bill of materials, a weight breakdown, a cut list, drill
## templates with dimensioned hole positions, the U-bracket detail drawing, the
## per-joint assembly sequence, and the crew schedule that falls out of them.
##
## Port of `js/linkage/build-guide.js:showBuildGuide` (:256). Every number
## comes from `LinkageBom` / `LinkageDrillPlan`, which are pure and offline
## testable; this file only lays them out.
##
## No `class_name` on purpose — it is loaded lazily by main.gd, so GDScript
## errors would only surface when a player opened it. `ui_compile_selftest.gd`
## sweeps scenes/ui/ and the linkage selftest force-compiles it.
##
## [b]No PDF export.[/b] The web app leans on jsPDF; GDScript has no
## equivalent, so the guide exports CSV (spreadsheet) and JSON (the v30 config
## plus a summary block) and says so in its footnote rather than pretending.

signal closed

const MODAL_NAME := "linkage_build_guide"
const EXPORT_DIR := "user://linkage_designs"

const C_BG := UITheme.C_BG
const C_PANEL := UITheme.C_PANEL
const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M
const C_PRIMARY := UITheme.C_PRIMARY

var params: LinkageParams = LinkageParams.new()

var _bom: Dictionary = {}
var _drill: Dictionary = {}
var _metric := false
var _bound_prop_id := ""
var _loader: Node = null
var _design_name := "design"

var _scroll: ScrollContainer = null
var _body: VBoxContainer = null
var _bom_tree: Tree = null
var _totals_lbl: RichTextLabel = null
var _unit_btn: Button = null
var _save_dialog: FileDialog = null
var _pending_export := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func bind_loader(loader: Node) -> void:
	_loader = loader


## Open for a design. `name_hint` labels exports.
func open(p: LinkageParams, name_hint := "") -> void:
	params = p if p != null else LinkageParams.new()
	if name_hint != "":
		_design_name = name_hint
	_bound_prop_id = ""
	_refresh()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


## Open for a linkage structure already standing in the world.
func open_for_prop(prop_id: String) -> void:
	var scene := get_tree().current_scene
	var rec: Dictionary = PlacedPropService.get_prop_record(scene, prop_id) \
		if scene != null else {}
	var p := LinkageParams.new()
	if rec.get("linkage_spec") is Dictionary:
		p.from_config(rec["linkage_spec"] as Dictionary)
	open(p, "prop_%s" % prop_id)
	_bound_prop_id = prop_id


func close() -> void:
	if not visible:
		return
	visible = false
	CursorController.release_modal(MODAL_NAME)
	closed.emit()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var k := event as InputEventKey
	if k != null and k.pressed and k.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Recompute
# ---------------------------------------------------------------------------

func _refresh() -> void:
	_bom = LinkageBom.compute(params)
	_drill = LinkageDrillPlan.compute(params)
	_rebuild_body()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(C_BG.r, C_BG.g, C_BG.b, 0.95)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_topbar())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, UITheme.SPACE_LG)
	_scroll.add_child(margin)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", UITheme.SPACE_MD)
	margin.add_child(_body)

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_USERDATA
	_save_dialog.use_native_dialog = false
	_save_dialog.size = Vector2i(760, 520)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	add_child(_save_dialog)


func _build_topbar() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.panel_style(1.0))
	wrap.custom_minimum_size.y = 52
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	wrap.add_child(bar)

	var title := Label.new()
	title.text = "📋  BUILD GUIDE"
	title.add_theme_color_override("font_color", C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	bar.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_unit_btn = _bar_btn("Units: in / kg", _on_toggle_units)
	_unit_btn.tooltip_text = "Switch lengths between inches and millimetres. Mass is metric either way — see the footnote."
	bar.add_child(_unit_btn)
	bar.add_child(_bar_btn("📊 Export CSV", _on_export_csv))
	bar.add_child(_bar_btn("💾 Export JSON", _on_export_json))
	bar.add_child(_bar_btn("✕", close))
	return wrap


func _bar_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _rebuild_body() -> void:
	if _body == null:
		return
	for child in _body.get_children():
		child.queue_free()
	_bom_tree = null
	_totals_lbl = null

	_add_summary()
	_add_bom_card()
	_add_mass_card()
	_add_cut_list()
	_add_drill_templates()
	_add_bracket_card()
	_add_assembly_card()
	_add_crew_card()
	_add_actuator_card()
	_add_electrical_card()
	_add_warnings()
	_add_footnote()


func _card(title: String) -> VBoxContainer:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UITheme.card_style())
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(wrap)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, UITheme.SPACE_MD)
	wrap.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	margin.add_child(box)
	if title != "":
		var lbl := Label.new()
		lbl.text = title
		lbl.add_theme_color_override("font_color", C_PRIMARY)
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
		box.add_child(lbl)
	return box


func _kv_row(parent: Control, key: String, value: String, color: Color = C_TEXT) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var k := Label.new()
	k.text = key
	k.add_theme_color_override("font_color", C_TEXT_S)
	k.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := Label.new()
	v.text = value
	v.add_theme_color_override("font_color", color)
	v.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	row.add_child(v)


func _canvas(parent: Control, height: float, painter: Callable) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = height
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(c)
	c.draw.connect(func() -> void: painter.call(c))
	return c


func _font() -> Font:
	return get_theme_default_font()


# ---------------------------------------------------------------------------
# Cards
# ---------------------------------------------------------------------------

func _add_summary() -> void:
	var box := _card("")
	var dims: Dictionary = _bom.get("dims", {})
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", UITheme.SPACE_LG)
	box.add_child(grid)
	var mode := "Arch" if params.orientation == "vertical" else "Cylinder"
	var mass: Dictionary = _bom.get("mass", {})
	for pair in [
		["Modules", str(params.modules)],
		["Mode", mode],
		["Height", _len(float(dims.get("height_in", 0.0)))],
		["Diameter", _len(float(dims.get("diameter_in", 0.0)))],
		["Fold angle", "%.1f°" % rad_to_deg(params.fold_angle)],
		["Deployed at", "%.1f°" % float((_bom.get("actuator", {}) as Dictionary)
			.get("closed_angle_deg", 0.0))],
		["Est. cost", "$%s" % String.num(float(_bom.get("total_cost", 0.0)), 2)],
		["Total weight", LinkageBom.fmt_mass(float(mass.get("total_kg", 0.0)))],
	]:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		grid.add_child(cell)
		var k := Label.new()
		k.text = str(pair[0])
		k.add_theme_color_override("font_color", C_TEXT_M)
		k.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		cell.add_child(k)
		var v := Label.new()
		v.text = str(pair[1])
		v.add_theme_color_override("font_color", C_TEXT)
		v.add_theme_font_size_override("font_size", UITheme.FONT_LG)
		cell.add_child(v)

	# Shipping envelope — the same number the Site Report packing card shows.
	var spec := LinkageStructureBuilder.packed_spec_for(params)
	if not spec.is_empty():
		var ship := Label.new()
		ship.text = "📦 Folded: %s · %s" % [
			PackedSpec.format_dims_short(spec),
			LinkageBom.fmt_mass(float(spec.get("mass_kg", 0.0)))]
		ship.add_theme_color_override("font_color", C_TEXT_S)
		ship.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		box.add_child(ship)


func _add_bom_card() -> void:
	var box := _card("Bill of Materials")
	var hint := Label.new()
	hint.text = "Unit prices are editable — totals update live."
	hint.add_theme_color_override("font_color", C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(hint)

	_bom_tree = Tree.new()
	_bom_tree.columns = 5
	_bom_tree.column_titles_visible = true
	_bom_tree.set_column_title(0, "Item")
	_bom_tree.set_column_title(1, "Qty")
	_bom_tree.set_column_title(2, "Unit $")
	_bom_tree.set_column_title(3, "Total $")
	_bom_tree.set_column_title(4, "Mass")
	_bom_tree.set_column_expand(0, true)
	for i in range(1, 5):
		_bom_tree.set_column_expand(i, false)
		_bom_tree.set_column_custom_minimum_width(i, 96)
	_bom_tree.hide_root = true
	_bom_tree.custom_minimum_size.y = 340
	_bom_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bom_tree.item_edited.connect(_on_bom_price_edited)
	box.add_child(_bom_tree)

	_totals_lbl = RichTextLabel.new()
	_totals_lbl.bbcode_enabled = true
	_totals_lbl.fit_content = true
	_totals_lbl.scroll_active = false
	_totals_lbl.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	box.add_child(_totals_lbl)
	_fill_bom_tree()


func _fill_bom_tree() -> void:
	if _bom_tree == null:
		return
	_bom_tree.clear()
	var root := _bom_tree.create_item()
	_bom_section(root, "STRUCTURE", _bom.get("structure_items", []))
	var power: Array = _bom.get("power_items", [])
	if not power.is_empty():
		_bom_section(root, "POWER", power)
	_update_totals()


func _bom_section(root: TreeItem, title: String, items: Array) -> void:
	var head := _bom_tree.create_item(root)
	head.set_text(0, title)
	head.set_custom_color(0, C_PRIMARY)
	head.set_selectable(0, false)
	for item in items:
		var d := item as Dictionary
		var row := _bom_tree.create_item(head)
		row.set_text(0, str(d["item"]))
		row.set_text(1, str(int(d["qty"])))
		row.set_text(2, String.num(float(d["unit_cost"]), 2))
		row.set_text(3, "$%s" % String.num(float(d["total_cost"]), 2))
		row.set_text(4, LinkageBom.fmt_mass(float(d["total_mass_kg"]), true))
		row.set_custom_color(1, C_TEXT_S)
		row.set_custom_color(4, C_TEXT_S)
		# Only lines that map to a cost knob are editable — a hardware line's
		# price lives on the part, not in the cost table.
		var key := _cost_key_for(str(d["key"]))
		if key != "":
			row.set_cell_mode(2, TreeItem.CELL_MODE_STRING)
			row.set_editable(2, true)
			row.set_metadata(2, {"cost_key": key, "qty": int(d["qty"])})
			row.set_custom_color(2, UITheme.C_AMBER)
		else:
			row.set_custom_color(2, C_TEXT_M)


## Which `params.costs` entry drives a BOM line, or "" when it is not a
## table-driven price (assembly hardware carries its own per-part cost).
func _cost_key_for(line_key: String) -> String:
	match line_key:
		"h_beam", "support_radial":
			return "h_beam"
		"v_beam", "v_beam_inner", "v_beam_outer", "support_rcp":
			return "v_beam"
		"bracket":
			return "bracket"
		"bolt_v", "bolt_v_inner", "bolt_v_center", "support_bolt", "support_through":
			return "bolt_v_inner"
		"bolt_v_outer":
			return "bolt_v_outer"
		"bolt_h_center":
			return "bolt_h"
		"bolt_h_pivot":
			return "bolt_h_pivot"
		"washer_v", "support_washer":
			return "washer_v"
		"washer_h":
			return "washer_h"
		"solar_panel":
			return "solar_panel"
	return ""


func _on_bom_price_edited() -> void:
	var row := _bom_tree.get_edited()
	if row == null or _bom_tree.get_edited_column() != 2:
		return
	var meta = row.get_metadata(2)
	if not (meta is Dictionary):
		return
	var value := row.get_text(2).strip_edges().to_float()
	if value < 0.0:
		value = 0.0
	var key := str((meta as Dictionary)["cost_key"])
	# Auto lumber pricing derives beam prices by volume, so a manual edit only
	# sticks once the player takes the wheel — say so rather than silently
	# discarding the number they just typed.
	if (key == "h_beam" or key == "v_beam") and bool(params.costs["auto_lumber"]):
		params.costs["auto_lumber"] = false
	params.costs[key] = value
	_bom = LinkageBom.compute(params)
	_fill_bom_tree()


func _update_totals() -> void:
	if _totals_lbl == null:
		return
	var mass: Dictionary = _bom.get("mass", {})
	var lumber := ""
	if not bool(params.costs["auto_lumber"]):
		lumber = "  [color=#%s](manual lumber pricing)[/color]" % C_TEXT_M.to_html(false)
	_totals_lbl.text = ("Structure [b]$%s[/b] · Power [b]$%s[/b] · "
		+ "Total [b][color=#%s]$%s[/color][/b] · %s%s") % [
			String.num(float(_bom.get("structure_cost", 0.0)), 2),
			String.num(float(_bom.get("power_cost", 0.0)), 2),
			UITheme.C_AMBER.to_html(false),
			String.num(float(_bom.get("total_cost", 0.0)), 2),
			LinkageBom.fmt_mass(float(mass.get("total_kg", 0.0))), lumber]


func _add_mass_card() -> void:
	var box := _card("Weight Breakdown")
	var mass: Dictionary = _bom.get("mass", {})
	_canvas(box, 96.0, func(c: Control) -> void:
		LinkageGuideCharts.draw_mass_breakdown(c, mass, _font(), true))
	var note := Label.new()
	note.text = "Softwood 470 kg/m³ (FPL Wood Handbook), mild steel 7850 kg/m³."
	note.add_theme_color_override("font_color", C_TEXT_M)
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(note)


func _add_cut_list() -> void:
	var box := _card("Cut List")
	var c: Dictionary = _bom.get("counts", {})
	_kv_row(box, "Horizontal beams", "%d x %s" % [int(c.get("h_beams", 0)),
		LinkageBom.format_beam_spec(params.h_length_ft, params.h_beam_w, params.h_beam_t)])
	if bool(c.get("v_beams_linked", true)):
		_kv_row(box, "Vertical beams", "%d x %s" % [int(c.get("v_beams", 0)),
			LinkageBom.format_beam_spec(params.v_length_ft, params.v_beam_w, params.v_beam_t)])
	else:
		_kv_row(box, "V-beams (inner)", "%d x %s" % [int(c.get("v_beams_inner", 0)),
			LinkageBom.format_beam_spec(params.v_length_ft,
				params.v_beam_inner_w, params.v_beam_inner_t)])
		_kv_row(box, "V-beams (outer)", "%d x %s" % [int(c.get("v_beams_outer", 0)),
			LinkageBom.format_beam_spec(params.v_length_ft,
				params.v_beam_outer_w, params.v_beam_outer_t)])
	var sb: Dictionary = params.support_beams
	if int(c.get("support_radial", 0)) > 0:
		_kv_row(box, "Radial supports", "%d x %s" % [int(c["support_radial"]),
			LinkageBom.format_beam_spec(float(sb["length"]) / 12.0,
				float(sb["width"]), float(sb["thickness"]))])
	if int(c.get("support_rcp", 0)) > 0:
		_kv_row(box, "Reciprocal supports", "%d x %s" % [int(c["support_rcp"]),
			LinkageBom.format_beam_spec(float(sb["parallel_length"]) / 12.0,
				float(sb["parallel_width"]), float(sb["parallel_thickness"]))])


func _add_drill_templates() -> void:
	var box := _card("Drill Templates")
	var legend := Label.new()
	legend.text = "Holes are ⌀%s, centred on the beam width. Measure from the marked end." \
		% LinkageBom.format_bolt_spec(params.bolt_diameter, 0.0).split(" ")[0].trim_prefix("(")
	legend.add_theme_color_override("font_color", C_TEXT_M)
	legend.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(legend)
	for key in ["h_beam_top", "h_beam", "v_beam", "rcp_beam"]:
		if not _drill.has(key):
			continue
		var entry: Dictionary = _drill[key]
		var name := Label.new()
		name.text = "%s — %s" % [str(entry.get("label", key)),
			LinkageBom.format_beam_spec(float(entry.get("length_ft", 0.0)),
				params.h_beam_w, params.h_beam_t)] \
			if key.begins_with("h_beam") else "%s — %.1f ft" % [
				str(entry.get("label", key)), float(entry.get("length_ft", 0.0))]
		name.add_theme_color_override("font_color", C_TEXT_S)
		name.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		box.add_child(name)
		_canvas(box, LinkageGuideCharts.template_height(), func(c: Control) -> void:
			LinkageGuideCharts.draw_drill_template(c, entry, _font(), _metric))
	if bool(_drill.get("has_reciprocal", false)):
		var note := Label.new()
		note.text = "Blue R# holes are reciprocal anchors — top ring only. "\
			+ "Purple X# holes are where reciprocal beams cross."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", C_TEXT_M)
		note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		box.add_child(note)


func _add_bracket_card() -> void:
	var box := _card("U-Bracket Detail")
	_canvas(box, 210.0, func(c: Control) -> void:
		LinkageGuideCharts.draw_bracket_diagram(c, params, _font(), _metric))
	_kv_row(box, "Width", _len(params.bracket_width))
	_kv_row(box, "Depth", _len(params.bracket_depth))
	_kv_row(box, "Height", _len(params.bracket_height))
	_kv_row(box, "Wall thickness", _len(params.bracket_wall_thickness))
	_kv_row(box, "Inner width", _len(params.bracket_inner_width))
	_kv_row(box, "Hole ⌀", _len(params.bracket_hole_diameter))
	_kv_row(box, "Hole from base", _len(params.bracket_hole_distance))


## The payoff of porting the hardware assemblies: each joint's stack listed in
## the order it is threaded.
func _add_assembly_card() -> void:
	var steps: Array = _bom.get("assembly_steps", [])
	if steps.is_empty():
		return
	var box := _card("Assembly Sequence")
	var intro := Label.new()
	intro.text = "Each joint, in threading order. Quantities are per module — "\
		+ "multiply by %d." % params.modules
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", C_TEXT_M)
	intro.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(intro)
	for entry in steps:
		var e := entry as Dictionary
		var head := Label.new()
		head.text = "%s  (%d pieces per module)" % [str(e["label"]),
			int(e["per_module_pieces"])]
		head.add_theme_color_override("font_color", C_TEXT)
		head.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		box.add_child(head)
		var n := 0
		for step in e["steps"]:
			var s := step as Dictionary
			n += 1
			var per := int(s["per_module"])
			var qty_txt := "x%d" % int(s["qty"])
			if per > 0:
				qty_txt += "  (%d per module)" % per
			_kv_row(box, "   %d. %s  [%s]" % [n, str(s["label"]), str(s["axis"])],
				qty_txt, C_TEXT_S)


func _add_crew_card() -> void:
	var box := _card("Crew Plan")
	var counts := LinkageBom.fab_counts(_bom)
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	var reco := NpcCrewPlan.recommend_crew(tasks, 24)
	if not reco.is_empty():
		_kv_row(box, "Recommended crew", "%d people" % int(reco["n"]))
		_kv_row(box, "Build time", "%.1f h" % (float(reco["makespan_s"]) / 3600.0))
		_kv_row(box, "Crew utilisation", "%.0f%%" % (float(reco["utilization"]) * 100.0))
	var gantt := RichTextLabel.new()
	gantt.fit_content = true
	gantt.scroll_active = false
	gantt.add_theme_font_override("normal_font", ThemeDB.fallback_font)
	gantt.add_theme_font_size_override("normal_font_size", UITheme.FONT_XS)
	gantt.add_theme_color_override("default_color", C_TEXT_S)
	var crew := int(reco["n"]) if not reco.is_empty() else NpcCrewPlan.ERECT_MIN_WORKERS
	gantt.text = NpcCrewPlan.timeline_text(NpcCrewPlan.schedule(tasks, crew))
	box.add_child(gantt)


func _add_actuator_card() -> void:
	var act: Dictionary = _bom.get("actuator", {})
	if act.is_empty():
		return
	var box := _card("Actuator")
	_kv_row(box, "Pivot span, folded", _len(float(act.get("open_in", 0.0))))
	_kv_row(box, "Pivot span, deployed", _len(float(act.get("closed_in", 0.0))))
	_kv_row(box, "Required stroke", _len(float(act.get("stroke_in", 0.0))), UITheme.C_AMBER)


func _add_electrical_card() -> void:
	var power: Dictionary = _bom.get("power", {})
	if int(power.get("panel_count", 0)) <= 0:
		return
	var box := _card("Electrical")
	_kv_row(box, "Panels", str(int(power["panel_count"])))
	_kv_row(box, "Array capacity", "%.2f kW" % float(power["kw"]))
	_kv_row(box, "Per panel", "%.0f W" % float(power["watts_per_panel"]))
	_kv_row(box, "Voc / Vmp", "%.1f V / %.1f V" % [float(power["voc"]), float(power["vmp"])])
	_kv_row(box, "Isc / Imp", "%.1f A / %.1f A" % [float(power["isc"]), float(power["imp"])])
	var note := Label.new()
	note.text = "String sizing, controller matching and wire runs live in the "\
		+ "systems graph (G) — place the array there to check Voc against a controller."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", C_TEXT_M)
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(note)


func _add_warnings() -> void:
	var warnings: Array = _bom.get("warnings", [])
	if warnings.is_empty():
		return
	var box := _card("Notes")
	for w in warnings:
		var lbl := Label.new()
		lbl.text = "• %s" % str(w)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.add_theme_color_override("font_color", UITheme.C_WARN)
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		box.add_child(lbl)


func _add_footnote() -> void:
	var box := _card("")
	var lbl := Label.new()
	lbl.text = ("Estimates, not a quote: prices are per-item defaults you can edit, "
		+ "and masses come from nominal softwood and steel densities — they will "
		+ "run a few percent under the LinkageLab web app, which uses a heavier "
		+ "wood figure. Fastener counts assume every joint is fully hardwared. "
		+ "PDF export is not available in-game; use CSV or JSON.")
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", C_TEXT_M)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(lbl)


# ---------------------------------------------------------------------------
# Units + export
# ---------------------------------------------------------------------------

func _len(inches: float) -> String:
	if _metric:
		var mm := inches * 25.4
		if mm >= 1000.0:
			return "%.2f m" % (mm / 1000.0)
		return "%.0f mm" % mm
	return "%.2f\"" % inches


func _on_toggle_units() -> void:
	_metric = not _metric
	if _unit_btn != null:
		_unit_btn.text = "Units: mm / kg" if _metric else "Units: in / kg"
	_rebuild_body()


func _on_export_csv() -> void:
	_begin_export("csv", "%s_BOM.csv" % _design_name)


func _on_export_json() -> void:
	_begin_export("json", "%s_design.json" % _design_name)


func _begin_export(kind: String, suggested: String) -> void:
	_pending_export = kind
	DirAccess.make_dir_recursive_absolute(EXPORT_DIR)
	_save_dialog.filters = PackedStringArray(
		["*.csv ; Spreadsheet"] if kind == "csv" else ["*.json ; Design JSON"])
	_save_dialog.current_dir = EXPORT_DIR
	_save_dialog.current_file = suggested
	_save_dialog.popup_centered()


func _on_save_path_chosen(path: String) -> void:
	var text := ""
	match _pending_export:
		"csv":
			text = LinkageBom.to_csv(_bom, true)
		"json":
			text = JSON.stringify(LinkageBom.to_json(params, _bom), "\t")
		_:
			return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Build guide export failed: %s" % path)
		return
	f.store_string(text)
	f.close()
