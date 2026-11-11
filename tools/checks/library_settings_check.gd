extends RefCounted

## The Library gallery, Settings and Help with REAL input (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/library_settings_check.gd -Label library_settings
## Library: opens on Designers, every designer card gets its picture (the
## sandbox starts with no thumbnail cache), a typed search finds cards in other
## sections, a section chip click shows that section, a card's Design… button
## opens the designer. Settings: a long page opens on one section with the rest
## folded, a slider moved by hand shows its "put it back" button and the button
## restores the value, the search opens a folded section. Help: the keys show
## first, the search narrows them, the tips are folded.
## Shots under screenshots\library_settings\.

const HI := preload("res://core/terrain/harness/harness_input.gd")

var _fails: Array = []
var _dir := "user://screenshots/library_settings"


func _ok(cond: bool, what: String) -> void:
	print("library-settings %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _shot(main: Node, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _type(vp: Viewport, tree: SceneTree, edit: LineEdit, text: String) -> void:
	edit.grab_focus()
	edit.text = text
	edit.text_changed.emit(text)
	await _frames(tree, 3)


func _pictures(lib: Control, section: String) -> Array:
	var have := 0
	var want := 0
	var missing: Array = []
	for card in ((lib.get("_sections") as Dictionary).get(section, {}) as Dictionary).get("cards", []):
		var e: Dictionary = (card as Control).get_meta("entry")
		if str(e.get("pic_model", "")).is_empty():
			continue
		want += 1
		var got := false
		for tr in (card as Node).find_children("*", "TextureRect", true, false):
			if (tr as TextureRect).texture is ImageTexture:
				got = true
		if got:
			have += 1
		else:
			missing.append(str(e.get("label", "")))
	return [have, want, missing]


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	if is_instance_valid(CursorController):
		CursorController.set_paused(true)

	# ---- Library ------------------------------------------------------------
	main.call("open_unified_library")
	await _frames(tree, 6)
	var lib: Control = main.get("unified_library_ui")
	_ok(lib != null and lib.visible, "the Library opens")
	if lib == null:
		return {"ok": false, "fails": _fails}
	_ok(str(lib.call("section_shown")) == "Designers", "it opens on Designers")
	_ok(int(lib.call("card_count", "Designers")) >= 14, "a card per designer (%d)" % int(lib.call("card_count", "Designers")))
	var thumbs: Node = lib.get("_thumbs")
	var waited := 0
	while int(thumbs.call("pending")) > 0 and waited < 2400:
		await tree.process_frame
		waited += 1
	var pics := _pictures(lib, "Designers")
	_ok(int(pics[0]) == int(pics[1]), "every designer card with a model has its picture (%d of %d after %d frames; missing %s)" % [
		pics[0], pics[1], waited, str(pics[2])])
	_shot(main, "01_library_designers")

	var search := lib.find_child("library_search", true, false) as LineEdit
	await _type(vp, tree, search, "battery")
	var graph_n := 0
	for card in ((lib.get("_sections") as Dictionary).get("Graph nodes", {}) as Dictionary).get("cards", []):
		if (card as Control).is_visible_in_tree():
			graph_n += 1
	_ok(graph_n > 0, "typing 'battery' on the Designers page finds graph nodes (%d)" % graph_n)
	_shot(main, "02_library_search")
	await _type(vp, tree, search, "")

	var chip := lib.find_child("section_vehicles", true, false) as Button
	await HI.click(vp, HI.center_of(chip))
	await _frames(tree, 4)
	_ok(str(lib.call("section_shown")) == "Vehicles" and int(lib.call("card_count", "Vehicles")) > 3,
		"a real click on Vehicles shows the vehicles (%d)" % int(lib.call("card_count", "Vehicles")))
	waited = 0
	while int(thumbs.call("pending")) > 0 and waited < 2400:
		await tree.process_frame
		waited += 1
	pics = _pictures(lib, "Vehicles")
	_ok(int(pics[0]) == int(pics[1]), "every vehicle card has its picture (%d of %d; missing %s)" % [pics[0], pics[1], str(pics[2])])
	_shot(main, "03_library_vehicles")

	chip = lib.find_child("section_designers", true, false) as Button
	await HI.click(vp, HI.center_of(chip))
	await _frames(tree, 4)
	var card: Control = lib.call("card_for", "Domes and zomes")
	_ok(card != null and card.is_visible_in_tree(), "the dome designer's card is on the page")
	if card != null:
		var verb := card.find_child("verb", true, false) as Button
		await HI.click(vp, HI.center_of(verb))
		await _frames(tree, 20)
		_ok(not lib.visible, "its Design… button closes the Library")
		var loader: Node = main.get_node_or_null("TerrainLoader")
		var dome: Control = loader.call("domelab_designer") if loader != null else null
		_ok(dome != null and dome.is_visible_in_tree(), "…and the dome designer is up")
		_shot(main, "04_dome_from_library")
		while is_instance_valid(CursorController) and CursorController.has_blocking_modal():
			if not CursorController.pop_top_modal():
				break
		await _frames(tree, 6)

	# ---- Settings -----------------------------------------------------------
	var tl: Control = main.get_node_or_null("UILayer/TimelineUI")
	var panel: Control = null
	if tl != null:
		tl.call("_on_settings_pressed")
		panel = tl.get("_settings_panel")
	await _frames(tree, 8)
	_ok(panel != null and panel.visible, "Settings opens")
	if panel != null:
		panel.call("open_page", "Environment")
		await _frames(tree, 6)
		var tabs := panel.get("_tabs") as TabContainer
		var page := tabs.get_tab_control(tabs.current_tab)
		var folds := page.find_children("*", "FoldableContainer", true, false)
		var open_n := 0
		for f in folds:
			if not (f as FoldableContainer).folded:
				open_n += 1
		_ok(folds.size() >= 4 and open_n == 1, "Environment opens on one section of %d (%d open)" % [folds.size(), open_n])
		_ok(panel.get("_force_rainbow") != null and page.is_ancestor_of(panel.get("_force_rainbow")),
			"Force rainbow lives on Environment now")
		_shot(main, "05_settings_environment")
		# A slider in the open section, moved by hand.
		var sl: HSlider = panel.get("_clouds_weight")
		var before := sl.value
		sl.value = clampf(before + 0.2, sl.min_value, sl.max_value) if before < 0.7 else before - 0.2
		await _frames(tree, 3)
		var back := sl.get_parent().find_child("revert", true, false) as Button
		_ok(back != null and back.is_visible_in_tree() and int(panel.call("changed_row_count")) >= 1,
			"a changed slider shows its put-it-back button")
		_shot(main, "06_settings_changed")
		if back != null:
			await HI.click(vp, HI.center_of(back))
			await _frames(tree, 3)
			_ok(is_equal_approx(sl.value, before) and not back.visible,
				"a real click on it restores the value (%.2f → %.2f)" % [before, sl.value])
		# Search opens a folded section.
		var hz: Control = panel.get("_hz_height")
		_ok(hz != null and not hz.is_visible_in_tree(), "the horizon rows start folded away")
		if hz != null:
			await panel.call("reveal_control", hz)
			await _frames(tree, 4)
			_ok(hz.is_visible_in_tree(), "revealing a row opens its section")
		panel.call("open_page", "Interface")
		await _frames(tree, 4)
		page = tabs.get_tab_control(tabs.current_tab)
		_ok(panel.get("_sfx_mute_chk") != null and page.is_ancestor_of(panel.get("_sfx_mute_chk")),
			"Sound lives on Interface now")
		panel.call("open_page", "Gameplay")
		await _frames(tree, 4)
		_shot(main, "07_settings_gameplay")
		panel.call("close")
		await _frames(tree, 4)

	# ---- Help ---------------------------------------------------------------
	var help: Node = null
	for n in tree.root.find_children("*", "CanvasLayer", true, false):
		if (n as Node).has_method("_keyboard_label") and (n as Node).has_method("open"):
			help = n
			break
	_ok(help != null, "the help overlay is found")
	if help != null:
		help.call("open")
		await _frames(tree, 6)
		var flow: Control = help.get("_groups_flow")
		var tips := (help as Node).find_child("tips", true, false) as FoldableContainer
		_ok(flow != null and flow.get_child_count() >= 6 and flow.get_index() == 0, "the keys come first (%d groups)" % (flow.get_child_count() if flow != null else 0))
		_ok(tips != null and tips.folded, "the tips are folded")
		_shot(main, "08_help")
		var hs := (help as Node).find_child("help_search", true, false) as LineEdit
		await _type(vp, tree, hs, "drone")
		var shown := 0
		for c in flow.get_children():
			if (c as Control).visible:
				shown += 1
		_ok(shown >= 1 and shown < flow.get_child_count(), "typing 'drone' narrows the groups (%d of %d)" % [shown, flow.get_child_count()])
		_shot(main, "09_help_search")
		help.call("close")
		await _frames(tree, 3)

	return {"ok": _fails.is_empty(), "fails": _fails}
