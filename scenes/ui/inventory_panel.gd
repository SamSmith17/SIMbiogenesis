extends Control

## Inventory & Crafting panel — lists the fabricated parts stored in the per-map
## PartInventory (credited by completed CNC/printer jobs) and the RecipeCatalog
## recipes with a live have/need readout. When a recipe is satisfied, "Assemble"
## spends the parts and hands off to in-world placement of the crafted structure
## (groundwork for the full crafting mechanic). Dim-backdrop centered modal,
## following the project's modal conventions.

const MODAL_NAME := "inventory_panel"

var _built := false
var _parts_box: VBoxContainer = null
var _recipes_box: VBoxContainer = null


func open() -> void:
	if not _built:
		_build_ui()
		_built = true
	refresh()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 560)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)

	var root_v := VBoxContainer.new()
	root_v.add_theme_constant_override("separation", 10)
	panel.add_child(root_v)

	var title := Label.new()
	title.text = "Inventory & Crafting"
	title.add_theme_font_size_override("font_size", 18)
	root_v.add_child(title)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_v.add_child(cols)

	# Left: parts list.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var parts_hdr := Label.new()
	parts_hdr.text = "Fabricated Parts"
	parts_hdr.add_theme_font_size_override("font_size", 15)
	left.add_child(parts_hdr)
	var parts_scroll := ScrollContainer.new()
	parts_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(parts_scroll)
	_parts_box = VBoxContainer.new()
	_parts_box.custom_minimum_size = Vector2(320, 0)
	_parts_box.add_theme_constant_override("separation", 4)
	parts_scroll.add_child(_parts_box)

	# Right: recipes.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	var rec_hdr := Label.new()
	rec_hdr.text = "Assemble (craft recipes)"
	rec_hdr.add_theme_font_size_override("font_size", 15)
	right.add_child(rec_hdr)
	var rec_scroll := ScrollContainer.new()
	rec_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(rec_scroll)
	_recipes_box = VBoxContainer.new()
	_recipes_box.custom_minimum_size = Vector2(330, 0)
	_recipes_box.add_theme_constant_override("separation", 8)
	rec_scroll.add_child(_recipes_box)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	root_v.add_child(close_btn)


func refresh() -> void:
	if not _built:
		return
	var inv := _inventory()
	for c in _parts_box.get_children():
		c.queue_free()
	if inv == null or inv.is_empty():
		var empty := Label.new()
		empty.text = "No parts yet. Run a job on a CNC machine or printer."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(0.7, 0.75, 0.8)
		_parts_box.add_child(empty)
	else:
		for p: Dictionary in inv.all_parts():
			var row := Label.new()
			var mk := str(p.get("material_kind", ""))
			var suffix := "  ·  %s" % ResourceKinds.display_name(mk) if not mk.is_empty() else ""
			row.text = "%d ×  %s%s" % [int(p.get("qty", 0)), str(p.get("label", "")), suffix]
			_parts_box.add_child(row)

	for c in _recipes_box.get_children():
		c.queue_free()
	for r: Dictionary in RecipeCatalog.all_recipes():
		_recipes_box.add_child(_build_recipe_card(r, inv))
	var proc_hdr := Label.new()
	proc_hdr.text = "Process recipes (machines)"
	proc_hdr.add_theme_font_size_override("font_size", 13)
	proc_hdr.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_recipes_box.add_child(proc_hdr)
	for pr: Dictionary in ProcessRecipeCatalog.all_recipes():
		var line := Label.new()
		line.text = "• %s  (%.2f h, chore %.2f h)" % [
			str(pr.get("label", "")),
			float(pr.get("batch_time_hrs", 0.0)),
			float(pr.get("chore_hours", 0.0))]
		line.add_theme_font_size_override("font_size", 11)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_recipes_box.add_child(line)
	var open_ed := Button.new()
	open_ed.text = "Open recipe editor…"
	open_ed.focus_mode = Control.FOCUS_NONE
	open_ed.pressed.connect(func():
		var sgv := get_tree().root.find_child("SystemGraphView", true, false)
		if sgv != null and sgv.has_method("open_process_recipe_editor"):
			sgv.call("open_process_recipe_editor", "", "")
	)
	_recipes_box.add_child(open_ed)
	var open_wf := Button.new()
	open_wf.text = "Workflow recipes…"
	open_wf.focus_mode = Control.FOCUS_NONE
	open_wf.pressed.connect(func():
		var sgv2 := get_tree().root.find_child("SystemGraphView", true, false)
		if sgv2 != null and sgv2.has_method("open_workflow_panel"):
			sgv2.call("open_workflow_panel")
	)
	_recipes_box.add_child(open_wf)


func _build_recipe_card(recipe: Dictionary, inv: PartInventory) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)

	var name_lbl := Label.new()
	name_lbl.text = str(recipe.get("label", "Recipe"))
	name_lbl.add_theme_font_size_override("font_size", 14)
	v.add_child(name_lbl)

	var note := str(recipe.get("note", ""))
	if not note.is_empty():
		var nl := Label.new()
		nl.text = note
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_font_size_override("font_size", 11)
		nl.modulate = Color(0.7, 0.75, 0.82)
		v.add_child(nl)

	var req: Dictionary = recipe.get("requires", {})
	for pid in req:
		var need := int(req[pid])
		var have := inv.count(str(pid)) if inv != null else 0
		var line := Label.new()
		var ok := have >= need
		var plabel := DomeParts.label_for(str(pid)) if DomeParts.LABELS.has(str(pid)) \
			else (DomeParts.label_for(DomeParts.PART_BEAM) if PartInventory.is_beam_feedstock(str(pid)) \
				else str(pid))
		line.text = "%s  %d / %d %s" % [
			("✓" if ok else "✗"), have, need, plabel]
		line.modulate = Color(0.6, 0.85, 0.6) if ok else Color(0.9, 0.6, 0.6)
		line.add_theme_font_size_override("font_size", 12)
		v.add_child(line)

	var can := RecipeCatalog.can_craft(inv, str(recipe.get("id", "")))
	var rid := str(recipe.get("id", ""))
	var phases: Array = (recipe.get("labour", {}) as Dictionary).get("phases", [])
	var btn := Button.new()
	if phases.is_empty():
		btn.text = "🔨 Assemble & place"
		btn.pressed.connect(func(): _on_assemble(rid))
	else:
		# Crew-assembled: a labour summary so the card says what it will cost
		# in person-hours, and the button routes through the site-project flow
		# (parts are debited at placement COMMIT, refunded on cancel).
		var total_s := 0.0
		var max_crew := 1
		for ph in phases:
			total_s += float((ph as Dictionary).get("work_s", 0.0))
			max_crew = maxi(max_crew, int((ph as Dictionary).get("max_workers", 1)))
		var lab_line := Label.new()
		lab_line.text = "👷 ~%.1f person-h · crew up to %d · %d phases" % [
			total_s / 3600.0, max_crew, phases.size()]
		lab_line.add_theme_font_size_override("font_size", 11)
		lab_line.modulate = Color(0.7, 0.75, 0.82)
		v.add_child(lab_line)
		btn.text = "👷 Assemble with crew…"
		btn.tooltip_text = "Pick a site; the crew builds it as a project. Parts are taken when you place the ghost and refunded if you cancel."
		btn.pressed.connect(func(): _on_assemble_crew(rid))
	btn.disabled = not can
	v.add_child(btn)
	return card


## Crew flow: parts are NOT spent here — the commit hook debits them once a
## site is actually picked (cancelling the placement costs nothing).
func _on_assemble_crew(recipe_id: String) -> void:
	var inv := _inventory()
	if inv == null or not RecipeCatalog.can_craft(inv, recipe_id):
		return
	var recipe := RecipeCatalog.find(recipe_id)
	var out: Dictionary = recipe.get("output", {})
	var model_id := str(out.get("model_id", ""))
	var label := str(out.get("label", "structure"))
	var sgv := _system_graph_view()
	if sgv != null and sgv.has_method("place_crafted_model") and not model_id.is_empty():
		close()
		sgv.call("place_crafted_model", model_id, label, recipe_id)


func _on_assemble(recipe_id: String) -> void:
	var inv := _inventory()
	if inv == null:
		return
	if not RecipeCatalog.spend(inv, recipe_id):
		return
	var loader := _terrain_loader()
	if loader != null and loader.has_method("save_part_inventory"):
		loader.call("save_part_inventory")
	var recipe := RecipeCatalog.find(recipe_id)
	var out: Dictionary = recipe.get("output", {})
	var model_id := str(out.get("model_id", ""))
	var label := str(out.get("label", "structure"))
	refresh()
	var sgv := _system_graph_view()
	if sgv != null and sgv.has_method("place_crafted_model") and not model_id.is_empty():
		close()
		sgv.call("place_crafted_model", model_id, label)


func _inventory() -> PartInventory:
	var loader := _terrain_loader()
	if loader != null and loader.has_method("get_part_inventory"):
		return loader.call("get_part_inventory") as PartInventory
	return null


func _terrain_loader() -> Node:
	var m := _main()
	if m == null:
		return null
	return m.find_child("TerrainLoader", true, false)


func _system_graph_view() -> Node:
	var m := _main()
	if m == null:
		return null
	return ServiceLocator.graph()


func _main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m != null:
		return m
	return tree.current_scene
