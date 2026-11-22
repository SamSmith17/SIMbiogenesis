extends RefCounted

## The Controller Lab on the graph and in the world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/ctrllab_world_check.gd -Label ctrllab_world -Timeout 900
## Opens the Lab on the world's own graph controller (Mount Vernon's EG4
## 6000XP) through the inspector's "Design this controller…", a REAL click on
## Apply: the node keeps its wires and gains PV 2, AC in, generator in and
## data. Then the unit is placed beside the player bound to that node (its
## 3D ports from the design, the battery + port on the BAT + stud), a battery
## bank is placed and its main cables run to the unit's studs. The screen on
## the unit shows live numbers. Delete takes the placed unit away again.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("ctrllab_world %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


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
	# --- The world's controller.
	var gid := ""
	for it: Dictionary in model.items:
		if str(it.get("type", "")) == "controller" and not bool(it.get("is_virtual", false)):
			var nm := str((it.get("specs", {}) as Dictionary).get("name", it.get("label", "")))
			print("ctrllab_world: controller %s \"%s\" (%s) in %s" % [it["id"], nm, str(it.get("label", "")), str(it.get("scope_id", ""))])
			if gid.is_empty() or nm.contains("EG4") or nm.contains("6000"):
				gid = str(it["id"])
	_ok(not gid.is_empty(), "the world has a graph controller (%s)" % gid)
	if gid.is_empty():
		return {"ok": false, "fails": _fails}
	var before: Dictionary = model.get_item(gid).duplicate(true)
	var wires_before := 0
	for c: Dictionary in model.connections:
		if str(c.get("source_item_id", "")) == gid or str(c.get("target_item_id", "")) == gid:
			wires_before += 1
	# The inspector's button, as a player presses it: the graph open, the
	# controller selected.
	if main.has_method("open_graph_view"):
		main.call("open_graph_view")
	elif gv.has_method("open_graph_view"):
		gv.call("open_graph_view")
	await _settle(tree, 20)
	gv.call("select_item_by_id", gid)
	await _settle(tree, 12)
	var insp: Node = gv.get("_inspector_panel")
	var btn: Button = insp.find_child("design_controller", true, false) as Button if insp != null else null
	_ok(btn != null, "the inspector has Design this controller…")
	if btn != null:
		var sc := btn.get_parent()
		while sc != null and not (sc is ScrollContainer):
			sc = sc.get_parent()
		if sc != null:
			(sc as ScrollContainer).ensure_control_visible(btn)
		await _settle(tree, 3)
		vp.get_texture().get_image().save_png("%s/inspector.png" % dir)
		await HarnessInput.click(vp, HarnessInput.center_of(btn))
	await _settle(tree, 20)
	var ui: Control = main.get("ctrllab_ui")
	_ok(ui != null and bool(ui.call("is_open")), "the Controller Lab opened on it")
	var s: Dictionary = ui.call("spec")
	_ok(str(s.get("id", "")) == "eg4_6000xp" and str(ui.call("bound_graph_item")) == gid,
		"it opens on the 6000XP design, bound to the node (%s)" % str(s.get("id", "")))
	var ab := ui.find_child("apply", true, false) as Button
	_ok(ab != null and not ab.disabled, "Apply is there and enabled")
	await HarnessInput.click(vp, HarnessInput.center_of(ab))
	await _settle(tree, 8)
	var after: Dictionary = model.get_item(gid)
	var hids: Array = (after.get("handles", []) as Array).map(func(h): return str(h["id"]))
	var sp: Dictionary = after.get("specs", {})
	_ok(hids.has("pvPositive2") and hids.has("acInput") and hids.has("genInput") and hids.has("data") and hids.has("batteryPositive"),
		"Apply gives the node its terminals: %s" % ", ".join(hids))
	_ok(sp.get("controller_spec") is Dictionary and str(sp.get("controller_preset", "")) == "eg4_6000xp"
		and absf(float(sp.get("max_voc", 0)) - 480.0) < 0.1 and float(sp.get("soc", sp.get("max_voc", 1))) != 0.0,
		"its numbers and design are written (Voc %.0f V)" % float(sp.get("max_voc", 0)))
	var lost := 0
	var ids := {}
	for h in hids:
		ids[h] = true
	for c: Dictionary in model.connections:
		if str(c.get("source_item_id", "")) == gid and not ids.has(str(c.get("source_handle_id", ""))):
			lost += 1
		elif str(c.get("target_item_id", "")) == gid and not ids.has(str(c.get("target_handle_id", ""))):
			lost += 1
	_ok(lost == 0, "every wire it had still lands on a terminal (%d wires, %d lost)" % [wires_before, lost])
	ui.call("close")
	await _settle(tree, 4)
	if gv.has_method("close_graph_view"):
		gv.call("close_graph_view")
	await _settle(tree, 10)
	# --- Placed beside the player, bound to that node.
	var player := main.get_node_or_null("Player") as Node3D
	var at := player.global_position + (-player.global_transform.basis.z) * 3.0 if player != null else Vector3.ZERO
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, CtrlBuilder.MODEL_ID, at.x, at.z,
		{"controller_spec": s, "graph_item_id": gid, "collision_enabled": true})
	_ok(bool(r.get("ok", false)), "the unit is placed")
	var pid := str(r.get("prop_id", ""))
	await _settle(tree, 30)
	var rec := PlacedPropService.get_prop_record(main, pid)
	var it2: Dictionary = model.get_item(gid)
	_ok(str(rec.get("graph_item_id", "")) == gid and str((it2.get("specs", {}) as Dictionary).get("bound_prop_id", "")) == pid,
		"the placed unit takes the graph controller over (bound both ways)")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	var mroot := prop.get_node_or_null("ModelRoot") as Node3D if prop != null else null
	_ok(mroot != null and mroot.find_children("*", "CtrlBuilder", true, false).size() + (1 if mroot is CtrlBuilder else 0) > 0,
		"the prop is the designed unit")
	var ports := ConnectionPortDefs.resolve_ports_for_prop(main, pid, CtrlBuilder.MODEL_ID)
	var port_ids: Array = ports.map(func(p): return str(p["handle_id"]))
	_ok(port_ids.has("batteryPositive") and port_ids.has("pvPositive2") and port_ids.has("acInput"),
		"its 3D ports are its terminals (%d)" % ports.size())
	# --- A bank placed near it: its cables land on the studs.
	var bank_at := at + Vector3(1.6, 0, 0.4)
	var rb: Dictionary = PlacedPropService.place_model_at_xz(main, BankBuilder.MODEL_ID, bank_at.x, bank_at.z,
		{"battery_bank_spec": BankSpec.of_pack(BattPresets.builtin("rack_48v_105"), 1, 1), "collision_enabled": true})
	var bpid := str(rb.get("prop_id", ""))
	await _settle(tree, 40)
	var bcid := ""
	var bconn: Dictionary = {}
	for c: Dictionary in model.connections:
		if str(c.get("bank_main", "")) == bpid and str(c.get("source_handle_id", "")) == "batteryPositive":
			bcid = str(c.get("id", ""))
			bconn = c
	_ok(not bcid.is_empty() and str(bconn.get("source_item_id", "")) == gid,
		"the bank's + cable runs to the unit's controller (%s)" % str(bconn.get("source_item_id", "")))
	var mgr: Node = gv.call("_get_conduit_manager") if gv.has_method("_get_conduit_manager") else null
	prop = PlacedPropRuntime.find_by_prop_id(main, pid)
	mroot = prop.get_node_or_null("ModelRoot") as Node3D if prop != null else null
	ports = ConnectionPortDefs.resolve_ports_for_prop(main, pid, CtrlBuilder.MODEL_ID)
	var stud_w := Vector3.INF
	for p in ports:
		if str(p["handle_id"]) == "batteryPositive" and mroot != null:
			stud_w = mroot.global_transform * Vector3(float(p["x"]), float(p["y"]), float(p["z"]))
	print("ctrllab_world: ports %s, stud %s, cable %s visible_3d %s" % [str(port_ids), str(stud_w), bcid, str(bconn.get("visible_3d", false))])
	var near := INF
	for _t in 60:
		await _settle(tree, 5)
		if mgr != null and not bcid.is_empty():
			var pts: PackedVector3Array = mgr.call("run_corners", bcid)
			if pts.size() >= 2 and stud_w != Vector3.INF:
				near = minf(pts[0].distance_to(stud_w), pts[pts.size() - 1].distance_to(stud_w))
				break
	_ok(near < 0.6, "the cable's end is at the BAT + stud (%.2f m off)" % near)
	# --- The screen (the prop may have been rebuilt since).
	prop = PlacedPropRuntime.find_by_prop_id(main, pid)
	mroot = prop.get_node_or_null("ModelRoot") as Node3D if prop != null else null
	var rt := prop.get_node_or_null(CtrlRuntime.NODE_NAME) if prop != null else null
	print("ctrllab_world: runtime %s" % str(rt))
	await _settle(tree, 40)
	var txt := str(rt.get("text")) if rt != null else ""
	_ok(rt != null and txt.contains("PV") and txt.contains("BAT"), "the unit's screen shows live numbers (%s)" % txt.replace("\n", " · "))
	var cam := vp.get_camera_3d()
	if cam != null and mroot != null:
		var c := mroot.global_transform.origin + Vector3(0, 0.45, 0)
		var old := cam.global_transform
		cam.global_transform = Transform3D(Basis.looking_at(-(Vector3(0.2, 0.15, 1.0).normalized()), Vector3.UP), c + Vector3(0.2, 0.15, 1.0).normalized() * 1.6)
		cam.global_transform = cam.global_transform.looking_at(c, Vector3.UP)
		await _settle(tree, 6)
		vp.get_texture().get_image().save_png("%s/placed_unit.png" % dir)
		cam.global_transform = old
	# --- Delete the bank and the unit: their nodes go.
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", bpid)
		loader.call("delete_prop_by_id", pid)
	await _settle(tree, 10)
	_ok(PlacedPropService.get_prop_record(main, pid).is_empty(), "the unit is deleted")
	# Put the world's controller back as it was (the sandbox is thrown away,
	# but the rest of a run may read it).
	model.update_item(gid, {"specs": before.get("specs", {}), "handles": before.get("handles", [])})
	if toasts != null:
		toasts.set("visible", true)
	return {"ok": _fails.is_empty(), "fails": _fails}
