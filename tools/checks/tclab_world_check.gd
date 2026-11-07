extends RefCounted

## Tri-clamp assemblies in the world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/tclab_world_check.gd -Label tclab_world -Timeout 900
## The designer on the biochar reactor, a REAL click on Place in world (the
## ghost is the reactor, not a default), the placed prop (its design on the
## record, collision, its height), the graph's Biochar Reactor node made and
## bound to it, its labelled ends as connection ports with the node's
## handles, a 3D pipe from the woodgas port ending on the fitting, pack →
## its computed crate → unpack, the designer opened from the prop and Apply
## rebuilding it, then ten reactors in front of the player and what they
## cost a frame (draw calls, primitives, frame time), deleted again (their
## graph nodes go too).

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("tclab-world %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _graph(main: Node) -> Node:
	var g := ServiceLocator.graph()
	return g if g != null else main.find_child("SystemGraphView", true, false)


## {draw calls, primitives, median frame ms} over `n` frames.
func _frame_cost(tree: SceneTree, n: int) -> Dictionary:
	var ms: Array = []
	var dc := 0.0
	var prim := 0.0
	for _i in n:
		var t0 := Time.get_ticks_usec()
		await tree.process_frame
		ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		dc += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prim += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	ms.sort()
	return {"draws": dc / n, "prims": prim / n, "ms": ms[ms.size() / 2]}


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var vp := main.get_viewport()
	var loader: Node = main.get_node_or_null("Terrain/TerrainLoader")
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	var player := main.find_child("Player", true, false) as Node3D
	_ok(loader != null and player != null, "a map with a player")
	if loader == null or player == null:
		return {"ok": false, "failures": _fails}
	var cam := vp.get_camera_3d()
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.1 else Vector3.FORWARD
	var side := fwd.cross(Vector3.UP).normalized()
	var at := player.global_position + fwd * 6.0

	# The designer: the reactor, then a REAL click on Place in world.
	var ui: Control = main.call("open_tclab", {})
	await _settle(tree, 12)
	ui.call("load_builtin", "biochar_reactor")
	await _settle(tree, 8)
	var spec: Dictionary = (ui.call("spec") as Dictionary).duplicate(true)
	_ok(str(spec.get("binds", "")) == "Biochar Reactor", "the reactor preset is bound to the Biochar Reactor node")
	var note := ui.find_child("world_note", true, false) as Label
	_ok(note != null and note.text.contains("3 of them"), "the designer says which ends become the node's ports (%s)" % (note.text if note else ""))
	var place_btn := ui.find_child("place_world", true, false) as Button
	_ok(place_btn != null and place_btn.is_visible_in_tree(), "Place in world is offered")
	if place_btn != null and place_btn.is_visible_in_tree():
		await HarnessInput.click(vp, HarnessInput.center_of(place_btn))
	await _settle(tree, 10)
	_ok(PlacedPropService.is_placement_active() and not bool(ui.call("is_open")), "a click starts placing and closes the designer")
	var ghost := main.find_child("PlacementGhost", true, false) as Node3D
	var gm := ghost.find_child("Mesh", true, false) as MeshInstance3D if ghost != null else null
	var want_h := float((TcDesign.solve(spec)["stats"]["bounds_mm"] as AABB).size.y) * 0.001
	_ok(gm != null and absf(gm.mesh.get_aabb().size.y - want_h) < 0.02,
		"the ghost is the reactor (%.2f m tall, design %.2f)" % [gm.mesh.get_aabb().size.y if gm else -1.0, want_h])
	await _shot(main, "00_ghost")
	PlacedPropService.cancel_placement()
	await _settle(tree, 4)

	# Placed through the same prep the button uses.
	var pid := PlacedPropService.place_prepped_at(main, TcBuilder.MODEL_ID,
		{"record_extra": {"tc_spec": spec, "collision_enabled": true}}, at.x, at.z, rad_to_deg(atan2(fwd.x, fwd.z)) + 180.0)
	await _settle(tree, 20)
	_ok(not pid.is_empty(), "the reactor is placed")
	if pid.is_empty():
		return {"ok": false, "failures": _fails}
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(rec.get("tc_spec") is Dictionary and str((rec["tc_spec"] as Dictionary).get("name", "")) == str(spec["name"]), "the record carries its design")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	_ok(prop != null and prop.get_node_or_null("PropBody") != null, "it has collision")
	if prop != null:
		var bb: AABB = prop.get_world_pick_aabb()
		_ok(absf(bb.size.y - want_h) < 0.1, "it stands %.2f m tall in the world (design %.2f)" % [bb.size.y, want_h])
	# The graph node.
	var sgv := _graph(main)
	var gid := str(rec.get("graph_item_id", ""))
	var item: Dictionary = (sgv.get("model").call("get_item", gid) as Dictionary) if sgv != null and not gid.is_empty() else {}
	_ok(not item.is_empty() and str((item.get("specs", {}) as Dictionary).get("name", "")) == str(spec["name"]),
		"a Biochar Reactor node is made and bound to it (%s)" % gid)
	_ok(str((item.get("specs", {}) as Dictionary).get("bound_prop_id", "")) == pid
		and ((item.get("specs", {}) as Dictionary).get("outputs", []) as Array).size() == 3, "it carries the reactor's inputs and outputs")
	# Ports.
	var ports := ConnectionPortDefs.resolve_ports_for_prop(main, pid)
	_ok(ports.size() == (spec["labels"] as Dictionary).size(), "every labelled end is a connection port (%d)" % ports.size())
	var gas := ConduitManager.resolve_port_binding(item, "res_out_2", main)
	var gas_port: Dictionary = gas.get("port", {})
	var model_root := prop.get_node_or_null("ModelRoot") as Node3D
	var tcb: Node3D = null
	if model_root != null:
		for n in model_root.find_children("*", "Node3D", true, false):
			if n is TcBuilder:
				tcb = n
				break
		if tcb == null and model_root is TcBuilder:
			tcb = model_root
	print("tclab-world port: builder %s, gas %s" % [str(tcb), str(gas.get("pos", "none"))])
	var face := Vector3.INF
	var d := TcDesign.solve(spec)
	for op in d["res"]["open"]:
		var lab: Dictionary = (spec["labels"] as Dictionary).get(str(op["ref"]), {})
		if str(lab.get("kind", "")) == "woodgas" and tcb != null:
			face = tcb.global_transform * (((op["xf"] as Transform3D).origin + TcDesign.world_offset(d)) * 0.001)
	_ok(not gas_port.is_empty() and is_finite((gas["pos"] as Vector3).x) and (gas["pos"] as Vector3).distance_to(face) < 0.01,
		"the woodgas output's port is ON the woodgas fitting (%.3f m off)" % ((gas["pos"] as Vector3).distance_to(face) if is_finite(face.x) else -1.0))
	# A pipe from it to a gas store 5 m away.
	var tank_pos := at + side * 5.0
	var gm2: Object = sgv.get("model")
	var tid: String = gm2.call("generate_item_id")
	gm2.call("add_item", {"id": tid, "type": "resource", "x": 300.0, "y": 0.0, "width": 110.0, "height": 110.0,
		"scope_id": "root", "is_virtual": false, "site_x_m": tank_pos.x, "site_z_m": tank_pos.z,
		"specs": {"name": "Woodgas store", "resource_kind": "woodgas", "capacity": 2000.0, "stock": 0.0}})
	var cid: String = str(gm2.call("generate_connection_id"))
	gm2.call("add_connection", {"id": cid, "scope_id": "root", "source_item_id": gid, "source_handle_id": "res_out_2",
		"target_item_id": tid, "target_handle_id": "input", "polarity": "resource", "resource_type": "woodgas", "visible_3d": true})
	await _settle(tree, 6)
	var cm := main.find_child("ConduitManager", true, false)
	if cm != null and cm.has_method("sync_all"):
		cm.call("sync_all")
	await _settle(tree, 10)
	var samples: PackedVector3Array = (cm.get("_sample_cache") as Dictionary).get(cid, PackedVector3Array()) if cm != null else PackedVector3Array()
	var near := INF
	for p in samples:
		near = minf(near, p.distance_to(face))
	print("tclab-world pipe: %d samples, conduits %s" % [samples.size(), str((cm.get("_sample_cache") as Dictionary).keys()) if cm != null else "no manager"])
	_ok(not samples.is_empty() and near < 0.35, "a 3D pipe from the woodgas output starts on the fitting (%.2f m)" % near)
	var cam2 := Camera3D.new()
	main.add_child(cam2)
	cam2.global_position = at + side * 2.0 - fwd * 2.4 + Vector3(0, 1.6, 0)
	cam2.look_at(at + Vector3(0, 0.5, 0), Vector3.UP)
	var prev := vp.get_camera_3d()
	cam2.current = true
	await _settle(tree, 8)
	await _shot(main, "01_placed_with_pipe")
	gm2.call("remove_item", tid)
	await _settle(tree, 4)
	# Pack and unpack.
	loader.call("set_prop_packed", pid, true)
	await _settle(tree, 10)
	var ps := PlacedPropRuntime.packed_spec_for_record(PlacedPropService.get_prop_record(main, pid))
	_ok(str(ps.get("source", "")) == "computed" and float(ps.get("mass_kg", 0.0)) > 30.0,
		"it packs as its computed kit (%s, %.0f kg, %d units)" % [PackedSpec.format_dims_short(ps), float(ps.get("mass_kg", 0.0)), int(ps.get("units", 0))])
	await _shot(main, "02_packed")
	loader.call("set_prop_packed", pid, false)
	await _settle(tree, 10)
	_ok(not bool(PlacedPropService.get_prop_record(main, pid).get("packed", false)), "and unpacks")
	# The designer bound to the placed prop: Apply rebuilds it.
	ui = main.call("open_tclab", {"prop_id": pid})
	await _settle(tree, 12)
	_ok(str(ui.call("bound_prop_id")) == pid and bool((ui.get("_apply_btn") as Control).visible), "the designer opens bound to the placed reactor")
	var s2: Dictionary = (ui.call("spec") as Dictionary).duplicate(true)
	s2["name"] = "Reactor (edited)"
	ui.call("_set_spec", s2)
	await _settle(tree, 4)
	ui.call("_on_apply")
	await _settle(tree, 14)
	_ok(str((PlacedPropService.get_prop_record(main, pid).get("tc_spec", {}) as Dictionary).get("name", "")) == "Reactor (edited)",
		"Apply writes the design back onto the placed reactor")
	_ok(str(PlacedPropService.get_prop_record(main, pid).get("graph_item_id", "")) == gid, "and keeps its graph node")
	# Ten in front of the player: what they cost.
	cam2.global_position = player.global_position + Vector3(0, 1.7, 0) - fwd * 1.0
	cam2.look_at(player.global_position + fwd * 20.0 + Vector3(0, 0.8, 0), Vector3.UP)
	loader.call("delete_prop_by_id", pid)
	await _settle(tree, 20)
	_ok(gm2.call("get_item", gid).is_empty(), "deleting it removes its graph node")
	var before := await _frame_cost(tree, 90)
	var ten: Array = []
	for i in 10:
		var p := player.global_position + fwd * (6.0 + float(i / 5) * 5.0) + side * (float(i % 5) - 2.0) * 1.6
		var id := PlacedPropService.place_prepped_at(main, "tclab_biochar_reactor", {}, p.x, p.z, 0.0)
		if not id.is_empty():
			ten.append(id)
	await _settle(tree, 30)
	_ok(ten.size() == 10, "ten reactors placed from the catalog id")
	var after := await _frame_cost(tree, 120)
	print("tclab-world cost: before %.0f draws, %.0fk prims, %.1f ms · ten reactors %.0f draws, %.0fk prims, %.1f ms · %d world builds" % [
		float(before["draws"]), float(before["prims"]) / 1000.0, float(before["ms"]),
		float(after["draws"]), float(after["prims"]) / 1000.0, float(after["ms"]), TcBuilder.world_builds])
	_ok(float(after["draws"]) - float(before["draws"]) <= 10 * 16, "ten reactors add at most a surface per material each in draw calls (+%.0f)" % (float(after["draws"]) - float(before["draws"])))
	await _shot(main, "03_ten_reactors")
	var nodes := 0
	for id in ten:
		var r2 := PlacedPropService.get_prop_record(main, str(id))
		if not str(r2.get("graph_item_id", "")).is_empty():
			nodes += 1
	_ok(nodes == 10, "each made its own Biochar Reactor node (%d)" % nodes)
	for id in ten:
		loader.call("delete_prop_by_id", str(id))
	await _settle(tree, 10)
	if prev != null and is_instance_valid(prev):
		prev.current = true
	cam2.queue_free()
	print("tclab-world: %d failures" % _fails.size())
	return {"ok": _fails.is_empty(), "failures": _fails}
