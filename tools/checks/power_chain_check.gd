extends RefCounted

## Panels › Controller › Battery across the three labs (sandbox; run at 720
## too):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/power_chain_check.gd -Label power_chain -Timeout 900
## The Controller Lab on Mount Vernon's EG4: the chain bar names its panels
## and its battery; REAL clicks hop Controller → Battery Lab (bound to the
## graph battery) → back → solar designer (aimed at the EG4's window). A lone
## controller's "+ Add a battery" puts a bank on the graph wired to it. UiAudit
## on each lab with the bar.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("power_chain %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _audit(vp: Viewport, what: String) -> void:
	var a := UiAudit.run(vp)
	print("power_chain: ui audit, %s — %s" % [what, UiAudit.summary_line(a)])
	_ok(int(a.get("errors", 0)) == 0, "no UI audit errors on %s" % what)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var toasts := main.get_node_or_null("UILayer/ToastUI")
	if toasts != null:
		toasts.set("visible", false)
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model")
	var gid := ""
	for it: Dictionary in model.items:
		if str(it.get("type", "")) == "controller" and str((it.get("specs", {}) as Dictionary).get("name", "")).contains("6000"):
			gid = str(it["id"])
	_ok(not gid.is_empty(), "the world has its EG4 controller (%s)" % gid)
	if gid.is_empty():
		return {"ok": false, "fails": _fails}
	var ch := PowerChain.find(model, gid)
	print("power_chain: chain %s" % str(ch))
	# --- The Controller Lab on it.
	var ctrl: Control = main.call("open_ctrllab", {"graph_item_id": gid})
	await _settle(tree, 20)
	var bar: PowerChainBar = ctrl.call("chain_bar")
	var bat_btn := bar.find_child("chain_battery", true, false) as Button
	var pan_btn := bar.find_child("chain_panels", true, false) as Button
	_ok(bat_btn != null and pan_btn != null and bat_btn.tooltip_text.begins_with("Battery") and pan_btn.tooltip_text.begins_with("Panels"),
		"the bar names its panels and battery (%s | %s)" % [pan_btn.tooltip_text.get_slice("\n", 0) if pan_btn != null else "-", bat_btn.tooltip_text.get_slice("\n", 0) if bat_btn != null else "-"])
	print("power_chain: notes %s" % str(bar.checks().map(func(c): return str(c["text"]))))
	vp.get_texture().get_image().save_png("%s/ctrllab_bar.png" % dir)
	await _audit(vp, "the Controller Lab")
	# --- Hop to the battery.
	var bat_id := str((ch.get("battery", {}) as Dictionary).get("id", ""))
	if bat_btn != null:
		await HarnessInput.click(vp, HarnessInput.center_of(bat_btn))
	await _settle(tree, 25)
	var bl: Control = main.get("batterylab_ui")
	_ok(not bool(ctrl.call("is_open")) and bl != null and bool(bl.call("is_open")) and str(bl.get("_bound_graph_id")) == bat_id,
		"a click on Battery closes the Controller Lab and opens the Battery Lab bound to %s" % bat_id)
	var bbar: PowerChainBar = bl.call("chain_bar") if bl != null else null
	var c_btn := bbar.find_child("chain_controller", true, false) as Button if bbar != null else null
	var b_here := bbar.find_child("chain_battery", true, false) as Button if bbar != null else null
	_ok(c_btn != null and c_btn.tooltip_text.contains("6000") and b_here != null, "the Battery Lab's bar leads back to the EG4")
	vp.get_texture().get_image().save_png("%s/batterylab_bar.png" % dir)
	await _audit(vp, "the Battery Lab")
	# --- Back to the controller.
	if c_btn != null:
		await HarnessInput.click(vp, HarnessInput.center_of(c_btn))
	await _settle(tree, 25)
	_ok(bool(ctrl.call("is_open")) and str(ctrl.call("bound_graph_item")) == gid and not bool(bl.call("is_open")),
		"a click on Controller opens the Controller Lab on the EG4 again")
	# --- On to the panels: the solar designer, aimed at the EG4.
	bar = ctrl.call("chain_bar")
	pan_btn = bar.find_child("chain_panels", true, false) as Button
	var arrays: Array = ch.get("arrays", [])
	if pan_btn != null:
		await HarnessInput.click(vp, HarnessInput.center_of(pan_btn))
		await _settle(tree, 10)
		if arrays.size() > 1:
			var menu := bar.find_child("chain_menu", true, false) as PopupMenu
			_ok(menu != null and menu.visible and menu.item_count == arrays.size(), "several arrays: a menu lists them (%d)" % arrays.size())
			if menu != null:
				menu.id_pressed.emit(0)
	await _settle(tree, 30)
	var loader := main.get_node_or_null("TerrainLoader")
	var pv: Control = loader.call("pvlab_designer") if loader != null else null
	var tgt: Dictionary = (pv.call("spec") as Dictionary).get("target", {}) if pv != null else {}
	_ok(pv != null and bool(pv.call("is_open")) and not bool(ctrl.call("is_open")) and absf(float(tgt.get("max_voc", 0)) - 480.0) < 0.5,
		"a click on Panels opens the solar designer aimed at the EG4 (Voc limit %.0f V)" % float(tgt.get("max_voc", 0)))
	vp.get_texture().get_image().save_png("%s/pvlab_bar.png" % dir)
	await _audit(vp, "the solar designer")
	if pv != null:
		pv.call("close")
	await _settle(tree, 6)
	# --- A lone controller: + Add a battery.
	var lone := {"id": "pc_lone_ctl", "type": "controller", "label": "Lone MPPT", "x": 3000.0, "y": 3000.0,
		"width": 140.0, "height": 120.0, "scope_id": "root",
		"specs": {"name": "Lone MPPT", "controller_preset": "generic_mppt_150_50", "max_voc": 150.0, "max_charge_amps": 50.0,
			"system_voltage": 48}}
	model.add_item(lone)
	main.call("open_ctrllab", {"graph_item_id": "pc_lone_ctl"})
	await _settle(tree, 20)
	bar = ctrl.call("chain_bar")
	var add_b := bar.find_child("chain_add_battery", true, false) as Button
	_ok(add_b != null and not add_b.disabled, "a controller with no battery shows + Add a battery")
	if add_b != null:
		await HarnessInput.click(vp, HarnessInput.center_of(add_b))
	await _settle(tree, 8)
	var ch2 := PowerChain.find(model, "pc_lone_ctl")
	var nb := str((ch2.get("battery", {}) as Dictionary).get("id", ""))
	_ok(not nb.is_empty() and bar.find_child("chain_battery", true, false) != null,
		"a click puts a battery on the graph wired to it (%s), and the bar shows it" % nb)
	ctrl.call("close")
	await _settle(tree, 4)
	for c: Dictionary in model.connections.duplicate():
		if str(c.get("source_item_id", "")) == "pc_lone_ctl" or str(c.get("target_item_id", "")) == "pc_lone_ctl":
			model.remove_connection(str(c["id"]))
	if not nb.is_empty():
		model.remove_item(nb)
	model.remove_item("pc_lone_ctl")
	if toasts != null:
		toasts.set("visible", true)
	return {"ok": _fails.is_empty(), "fails": _fails}
