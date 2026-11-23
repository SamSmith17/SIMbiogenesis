extends Control

## Inventory & Crafting panel — lists the fabricated parts stored in the per-map
## PartInventory (credited by completed CNC/printer jobs) and the RecipeCatalog
## recipes with a live have/need readout. When a recipe is satisfied, "Assemble"
## spends the parts and hands off to in-world placement of the crafted structure
## (groundwork for the full crafting mechanic). A ModalFrame with two columns
## (the parts, the recipes); the recipe editor and workflows in the footer.

const MODAL_NAME := "inventory_panel"

var _built := false
var _frame: ModalFrame = null
var _parts_box: VBoxContainer = null
var _recipes_box: VBoxContainer = null


func open() -> void:
	if not _built:
		_build_ui()
		_built = true
	refresh()
	visible = true
	_frame.open()


func close() -> void:
	visible = false
	if _frame != null:
		_frame.close()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame = ModalFrame.create("Inventory & crafting", "the parts your machines made, and what they build",
		Vector2(940, 640), MODAL_NAME)
	add_child(_frame)
	_frame.closed.connect(close)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", UITheme.SPACE_LG)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_frame.body.add_child(cols)

	# Left: parts list.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	left.add_child(SectionHeader.make("Fabricated parts", "package"))
	_parts_box = VBoxContainer.new()
	_parts_box.add_theme_constant_override("separation", 4)
	left.add_child(_parts_box)

	# Right: recipes.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	right.add_child(SectionHeader.make("Assemble", "hammer", "craft recipes"))
	_recipes_box = VBoxContainer.new()
	_recipes_box.add_theme_constant_override("separation", 8)
	right.add_child(_recipes_box)

	_frame.add_button("Recipe editor…", ModalFrame.SECONDARY, func() -> void:
		var sgv := get_tree().root.find_child("SystemGraphView", true, false)
		if sgv != null and sgv.has_method("open_process_recipe_editor"):
			sgv.call("open_process_recipe_editor", "", ""),
		"Write a process recipe for a machine")
	_frame.add_button("Workflows…", ModalFrame.SECONDARY, func() -> void:
		var sgv2 := get_tree().root.find_child("SystemGraphView", true, false)
		if sgv2 != null and sgv2.has_method("open_workflow_panel"):
			sgv2.call("open_workflow_panel"),
		"Chain recipes into a workflow")
	_frame.add_button("Close", ModalFrame.PRIMARY, close)


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
		empty.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		empty.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_parts_box.add_child(empty)
	else:
		for p: Dictionary in inv.all_parts():
			var row := Label.new()
			var mk := str(p.get("material_kind", ""))
			var suffix := "  ·  %s" % ResourceKinds.display_name(mk) if not mk.is_empty() else ""
			row.text = "%d × %s%s" % [int(p.get("qty", 0)), str(p.get("label", "")), suffix]
			row.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			_parts_box.add_child(row)

	for c in _recipes_box.get_children():
		c.queue_free()
	for r: Dictionary in RecipeCatalog.all_recipes():
		_recipes_box.add_child(_build_recipe_card(r, inv))
	_recipes_box.add_child(SectionHeader.make("Process recipes", "", "what the machines run"))
	for pr: Dictionary in ProcessRecipeCatalog.all_recipes():
		_recipes_box.add_child(KVRow.make(str(pr.get("label", "")),
			"%s · %s of labour" % [UiText.duration(float(pr.get("batch_time_hrs", 0.0))),
				UiText.duration(float(pr.get("chore_hours", 0.0)))]))


func _build_recipe_card(recipe: Dictionary, inv: PartInventory) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)

	var name_lbl := Label.new()
	name_lbl.text = str(recipe.get("label", "Recipe"))
	name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	name_lbl.add_theme_font_override("font", UITheme.font("semibold"))
	v.add_child(name_lbl)

	var note := str(recipe.get("note", ""))
	if not note.is_empty():
		var nl := Label.new()
		nl.text = note
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		nl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
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
		line.add_theme_color_override("font_color", UITheme.C_OK if ok else UITheme.C_ERROR)
		line.add_theme_font_size_override("font_size", UITheme.FONT_SM)
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
		lab_line.text = I18n.f("👷 ~{total_s} person-h · crew up to {max_crew} · {phases}", {
			"total_s": "%.1f" % (total_s / 3600.0),
			"max_crew": "%d" % max_crew,
			"phases": UiText.count(phases.size(), "phase"),
		})
		lab_line.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		lab_line.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		v.add_child(lab_line)
		btn.text = "👷 Assemble with crew…"
		btn.tooltip_text = "Pick a site; the crew builds it as a project. Parts are taken when you place the ghost and refunded if you cancel."
		btn.pressed.connect(func(): _on_assemble_crew(rid))
	btn.disabled = not can
	UITheme.style_button(btn)
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
