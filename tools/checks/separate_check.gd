extends RefCounted

## "What can separate this?" on a real graph (resource composition plan
## Phase 5, sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/separate_check.gd -Label separate -Timeout 900
## Selects the world's urine store, a REAL click on the inspector's "What can
## separate this?", asserts the window lists water and nitrogen with Urine
## Nutrient Recovery among the ways, a REAL click on its Place adds one to
## the graph; then the same window for seawater and food scraps (a class
## answers where no machine does). Shots of each.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("separate %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _modal(tree: SceneTree) -> Node:
	for n in tree.root.get_children():
		var s: Script = n.get_script()
		if s != null and s.resource_path.ends_with("separate_modal.gd"):
			return n
	return null


func _labels(n: Node, out: PackedStringArray) -> void:
	if n is Label:
		out.append((n as Label).text)
	for c in n.get_children():
		_labels(c, out)


## Show the sidebar tab the control is on and scroll it into view.
func _bring_forward(tree: SceneTree, c: Control) -> void:
	var child: Node = c
	var p := c.get_parent()
	while p != null:
		if p is TabContainer:
			(p as TabContainer).current_tab = child.get_index()
		elif p.has_method("set_current_tab") and p.has_method("get_tab_count") and child is Control:
			pass
		child = p
		p = p.get_parent()
	await _wait(tree, 0.3)
	var q := c.get_parent()
	while q != null:
		if q is ScrollContainer:
			(q as ScrollContainer).ensure_control_visible(c)
		q = q.get_parent()
	await _wait(tree, 0.4)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _wait(tree, 0.5)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	main.set("time_scale", 0.0)
	sgv.call("open_graph_view")
	await _wait(tree, 1.0)
	var model: GraphModel = sgv.get("model")
	var urine_id := ""
	for it in GraphNesting.walk_items(model, "root"):
		var d: Dictionary = it
		if str(d.get("type", "")) == "resource" and str((d.get("specs", {}) as Dictionary).get("resource_kind", "")) == "urine":
			urine_id = str(d.get("id", ""))
			break
	_ok(not urine_id.is_empty(), "the world has a urine store")
	sgv.call("focus_graph_item", urine_id)
	await _wait(tree, 1.2)
	var insp_tab: Button = sgv.get("_insp_tab_btn")
	if insp_tab != null and insp_tab.is_visible_in_tree():
		await HarnessInput.click(vp, insp_tab.get_global_rect().get_center())
		await _wait(tree, 0.6)
	var btn := HarnessInput.find_button_revealing(sgv, "What can separate this?")
	_ok(btn != null, "the inspector offers What can separate this?")
	if btn != null:
		await _bring_forward(tree, btn)
		print("separate: button visible %s at %s" % [btn.is_visible_in_tree(), str(btn.get_global_rect())])
		await HarnessInput.click(vp, btn.get_global_rect().get_center())
		await _wait(tree, 0.8)
	var m := _modal(tree)
	_ok(m != null, "a real click opens the window")
	if m == null:
		return {"ok": false, "fails": _fails}
	var words := PackedStringArray()
	_labels(m, words)
	var all := " | ".join(words)
	_ok(all.to_lower().contains("water") and all.to_lower().contains("nitrogen"), "urine: water and nitrogen are listed")
	_ok(all.contains("Urine Nutrient Recovery"), "Urine Nutrient Recovery is a way")
	_ok(all.contains("a kind of process"), "classes of process are listed beside the machines")
	_shot(vp, dir, "01_urine")
	var before := model.items.size()
	var place := HarnessInput.find_button(m, "Place")
	var place_unr: Button = m.find_child("place_" + "Urine Nutrient Recovery".to_snake_case(), true, false)
	if place_unr != null:
		place = place_unr
	_ok(place != null, "a machine has Place")
	if place != null:
		await HarnessInput.click(vp, place.get_global_rect().get_center())
		await _wait(tree, 0.8)
		var found := false
		for it2 in model.items:
			if str(((it2 as Dictionary).get("specs", {}) as Dictionary).get("name", "")).begins_with("Urine Nutrient Recovery"):
				found = true
		_ok(model.items.size() > before and found, "Place adds it to the graph (%d → %d items, with its stores)" % [before, model.items.size()])
		_ok(_modal(tree) == null, "the window closes after Place")
		_shot(vp, dir, "02_placed")
	for k in ["seawater", "food_waste"]:
		sgv.call("open_separate", k)
		await _wait(tree, 0.8)
		var m2 := _modal(tree)
		var w2 := PackedStringArray()
		if m2 != null:
			_labels(m2, w2)
		var t2 := " | ".join(w2)
		if k == "seawater":
			_ok(t2.contains("Distill") or t2.contains("Reverse osmosis"), "seawater: distilling or RO")
		else:
			_ok(t2.contains("Drying"), "food scraps: drying (a class) gets their water out")
		_shot(vp, dir, "03_%s" % k)
		if m2 != null:
			(m2.get("_frame") as ModalFrame).close()
			await _wait(tree, 0.4)
	print("separate %s (%d failures)" % ["PASS" if _fails.is_empty() else "FAIL", _fails.size()])
	return {"ok": _fails.is_empty(), "fails": _fails}
