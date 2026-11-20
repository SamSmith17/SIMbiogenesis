extends RefCounted

## A Battery Lab bank in the world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/batterylab_world_check.gd -Label batterylab_world
## Places a 1S4P bank of 48 V 105 Ah rack packs in a cabinet and checks:
##   - the record keeps its design and the model is drawn with four packs;
##   - its graph battery is bound to it with the bank's kWh, voltage and BMS
##     current limits, and the runtime label is over it;
##   - while another battery on the site has no design the live sim has no
##     limit (the old behaviour); with every battery designed SolarUI takes
##     the summed limits, and the energy timeline uses them;
##   - a coldest-charge temperature above the air blocks charging: the
##     limit reads 0 and the label says so;
##   - re-seeding (Apply) keeps the battery's state of charge;
##   - the designer opened from the prop shows the bank;
##   - deleting the prop removes its graph battery.
## Shots of the bank.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("batterylab_world %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s).timeout


func _shot_from(main: Node, tree: SceneTree, name: String, eye: Vector3, at: Vector3) -> void:
	var cam := Camera3D.new()
	cam.fov = 50.0
	main.add_child(cam)
	cam.global_position = eye
	cam.look_at(at, Vector3.UP)
	main.call("push_camera_claim", "batterylab_world_check", {"camera_id": cam.get_instance_id()})
	await _settle(tree, 4)
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	main.call("pop_camera_claim", "batterylab_world_check")
	cam.queue_free()
	await _settle(tree, 2)


func _sync(gv: Node, tree: SceneTree) -> void:
	if gv.has_method("_sync_solar_ui_from_graph"):
		gv.call("_sync_solar_ui_from_graph")
	await _settle(tree, 4)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var gv := ServiceLocator.graph()
	var model: Variant = gv.get("model") if gv != null else null
	var sui: Node = main.get_node_or_null("UILayer/SolarUI")
	_ok(model != null and sui != null, "the site has a graph and SolarUI")
	if model == null or sui == null:
		return {"ok": false, "failures": _fails}
	var bank := BankSpec.of_pack(BattPresets.builtin("rack_48v_105"), 1, 4, "Shed bank")
	var pl := main.get_node_or_null("Player") as Node3D
	var at := Vector3.ZERO
	if pl != null:
		at = pl.global_position - pl.global_transform.basis.z * 5.0
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, BankBuilder.MODEL_ID, at.x, at.z, {"battery_bank_spec": bank})
	_ok(bool(r.get("ok", false)), "the bank is placed (%s)" % str(r.get("error", "")))
	var pid := str(r.get("prop_id", ""))
	await _settle(tree, 12)
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(rec.get("battery_bank_spec") is Dictionary and str((rec["battery_bank_spec"] as Dictionary).get("name", "")) == "Shed bank", "the record keeps its design")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid) as Node3D
	_ok(prop != null, "the bank is in the world")
	if prop == null:
		return {"ok": false, "failures": _fails}
	var bb: BankBuilder = null
	for c in prop.find_children("*", "Node3D", true, false):
		if c is BankBuilder:
			bb = c
	_ok(bb != null and bb.pack_count() == 4, "it is drawn with its four packs")
	var gid := str(rec.get("graph_item_id", ""))
	var node: Dictionary = model.call("get_item", gid) if gid != "" else {}
	_ok(not node.is_empty() and str(node.get("type", "")) == "battery", "the bank has its own graph battery")
	var d := BankDesign.solve(bank)
	if not node.is_empty():
		var sp: Dictionary = node["specs"]
		_ok(absf(float(sp.get("kwh", 0.0)) - float(d["electrical"]["wh"]) * 0.001) < 0.01, "its kWh are the bank's (%.2f)" % float(sp.get("kwh", 0.0)))
		_ok(absf(float(sp.get("voltage", 0.0)) - 51.2) < 0.01, "at 51.2 V")
		_ok(float(sp.get("max_charge_a", 0.0)) > 0.0 and float(sp.get("max_discharge_a", 0.0)) > 0.0, "with the BMS's current limits")
		_ok(str(sp.get("bound_prop_id", "")) == pid, "bound to the prop")
	var rt := prop.get_node_or_null(BatteryBankRuntime.NODE_NAME)
	_ok(rt != null, "the bank's runtime is attached")
	# Other batteries on the site with no design: no limit (the old behaviour).
	var others: Array = []
	for it: Dictionary in GraphSystems.walk_site_power(model):
		var ty := str(it.get("type", ""))
		if (ty == "battery" or ty == "smartbattery") and str(it.get("id", "")) != gid \
				and not (it.get("specs", {}) as Dictionary).has("max_charge_a"):
			others.append(str(it["id"]))
	await _sync(gv, tree)
	if not others.is_empty():
		_ok(float(sui.get("battery_max_charge_kw")) == INF, "with an undesigned battery on the site there is no designed limit")
	# Give the others a design (in memory; the sandbox is thrown away).
	for oid in others:
		var it: Dictionary = model.call("get_item", oid)
		var sp2: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		sp2["max_charge_a"] = 100.0
		sp2["max_discharge_a"] = 100.0
		sp2["charge_temp_min_c"] = 0.0
		model.call("update_item", oid, {"specs": sp2})
	await _sync(gv, tree)
	var want_kw := 0.0
	for it: Dictionary in GraphSystems.walk_site_power(model):
		var ty := str(it.get("type", ""))
		if ty == "battery" or ty == "smartbattery":
			var s3: Dictionary = it.get("specs", {})
			want_kw += float(s3.get("max_charge_a", 0.0)) * float(s3.get("voltage", 0.0)) * 0.001
	var got_kw := float(sui.get("battery_max_charge_kw"))
	_ok(absf(got_kw - want_kw) < 0.05, "SolarUI takes the summed charge limit (%.2f kW vs %.2f)" % [got_kw, want_kw])
	await _wait(tree, 1.0)
	var et: Variant = sui.get("energy_timeline")
	if et != null:
		var lim: Vector2 = sui.call("battery_limits_now")
		_ok(absf(float(et.get("max_charge_kw")) - lim.x) < 1e-6, "the energy timeline uses the live limit")
	# The cold block: a coldest-charge temperature above any air.
	var it_b: Dictionary = model.call("get_item", gid)
	var spb: Dictionary = (it_b["specs"] as Dictionary).duplicate(true)
	spb["charge_temp_min_c"] = 60.0
	model.call("update_item", gid, {"specs": spb})
	await _sync(gv, tree)
	var lim2: Vector2 = sui.call("battery_limits_now")
	_ok(lim2.x == 0.0, "colder than the BMS allows: charging blocked (limit %.2f kW)" % lim2.x)
	_ok(lim2.y > 0.0, "discharging still allowed")
	await _wait(tree, 1.2)
	if rt != null:
		print("batterylab_world: label —\n%s" % str(rt.get("text")))
		_ok(bool(rt.get("blocked_cold")) and str(rt.get("text")).find("Too cold") >= 0, "the label says it is too cold to charge")
	var bounds: AABB = bb.get_meta("bounds_m") if bb != null and bb.has_meta("bounds_m") else AABB(Vector3.ZERO, Vector3.ONE)
	var mid := prop.global_position + Vector3(0, bounds.size.y * 0.5, 0)
	await _shot_from(main, tree, "bank_front", mid + Vector3(2.4, 0.6, 3.2), mid)
	# Re-seed keeps the SOC (whatever the live sim has written onto it).
	var soc0 := float(((model.call("get_item", gid) as Dictionary)["specs"] as Dictionary).get("soc", -1.0))
	var gid2 := PlacedPropService.seed_battery_bank(main, pid)
	var it_d: Dictionary = model.call("get_item", gid2)
	var soc1 := float((it_d["specs"] as Dictionary).get("soc", -2.0))
	_ok(gid2 == gid, "re-seeding updates the same graph battery")
	_ok(absf(soc1 - soc0) < 1e-6, "and keeps its state of charge (%.3f -> %.3f)" % [soc0, soc1])
	# The designer opened from the prop.
	var ui := main.call("open_batterylab", {"prop_id": pid}) as Control
	await _settle(tree, 20)
	_ok(ui != null and str(ui.call("mode")) == "bank", "the designer opens on the bank")
	if ui != null:
		_ok(str((ui.call("bank_spec") as Dictionary).get("name", "")) == "Shed bank", "with this bank")
		main.get_viewport().get_texture().get_image().save_png("%s/designer_bank.png" % _dir)
		ui.call("close")
		await _settle(tree, 6)
	# Delete removes the graph battery.
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", pid)
		await _settle(tree, 10)
		_ok((model.call("get_item", gid) as Dictionary).is_empty(), "deleting the bank removes its graph battery")
	print("batterylab_world: %d failures" % _fails.size())
	return {"ok": _fails.is_empty(), "failures": _fails}
