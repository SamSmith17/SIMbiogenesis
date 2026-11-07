extends RefCounted

## A placed ESP board on a real world (sandbox; writes nothing to the
## player's world):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/esplab_world_check.gd -Label esplab_world
## Adds a test tank and a test pump to the graph, places a board whose
## ultrasonic and float are bound to the tank and whose relay follows the
## pump, and checks:
##   - the record keeps its design, the model is drawn on its stake, the
##     runtime is attached, and the board's own graph node draws its watts;
##   - the twin reads the world: the BME280 near the site's weather, the
##     unbound ultrasonic's ray down to the ground under its arm;
##   - the bound parts follow the graph: the water 0.6 m down at 40 %, the
##     float wet when the tank is full, the relay off when the pump is off;
##   - switching the board's graph node off makes every entity unavailable;
##   - the designer opened from the prop shows the "measures" picker, and
##     Apply (a real click) renames the board and its graph node;
##   - deleting the prop removes its graph node.
## Shots of the board from the side and above.

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String) -> void:
	print("esplab_world %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s).timeout


func _live(rt: Node, suffix: String) -> Dictionary:
	var latest: Dictionary = rt.get("latest")
	for k in latest:
		if str(k).ends_with(suffix):
			return latest[k]
	return {}


func _shot_from(main: Node, tree: SceneTree, name: String, eye: Vector3, at: Vector3) -> void:
	var ui_layer := main.get_node_or_null("UILayer") as CanvasLayer
	if ui_layer != null:
		ui_layer.visible = false
	var cam := Camera3D.new()
	cam.fov = 50.0
	main.add_child(cam)
	cam.global_position = eye
	cam.look_at(at, Vector3.UP)
	main.call("push_camera_claim", "esplab_world_check", {"camera_id": cam.get_instance_id()})
	await _settle(tree, 4)
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	main.call("pop_camera_claim", "esplab_world_check")
	cam.queue_free()
	if ui_layer != null:
		ui_layer.visible = true
	await _settle(tree, 2)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(_dir)
	var gv := ServiceLocator.graph()
	var model: Variant = gv.get("model") if gv != null else null
	_ok(model != null, "the site has a graph")
	if model == null:
		return {"ok": false}
	# A test tank and a test pump on the graph.
	var tank_id: String = model.call("generate_item_id")
	model.call("add_item", {"id": tank_id, "type": "resource", "x": 0.0, "y": 0.0, "width": 120.0, "height": 120.0,
		"scope_id": "root", "is_virtual": false,
		"specs": {"name": "ESP test tank", "kind": "water", "level": 0.4, "capacity_qty": 1000.0, "stock_l": 400.0}})
	var pump_id: String = model.call("generate_item_id")
	model.call("add_item", {"id": pump_id, "type": "appliance", "x": 160.0, "y": 0.0, "width": 160.0, "height": 104.0,
		"scope_id": "root", "is_virtual": false,
		"specs": {"name": "ESP test pump", "avg_watts": 240.0, "max_watts": 300.0, "current_state": "on", "requested_state": "on"}})
	var spec := {"name": "Tank probe", "board": "esp32_devkit_v1", "parts": [
		{"part": "jsnsr04t", "measures": {"distance": "tank.%s.distance_m" % tank_id}},
		{"part": "hcsr04"},
		{"part": "float_switch", "measures": {"float": "tank.%s.high" % tank_id}},
		{"part": "bme280"},
		{"part": "relay_1ch", "label": "Pump", "measures": {"relay": "item.%s.switch" % pump_id}},
	]}
	# Place it a few metres in front of the player.
	var pl := main.get_node_or_null("Player") as Node3D
	var at := Vector3.ZERO
	if pl != null:
		at = pl.global_position - pl.global_transform.basis.z * 4.0
	var r: Dictionary = PlacedPropService.place_model_at_xz(main, EspBuilder.MODEL_ID, at.x, at.z, {"esp_spec": spec})
	_ok(bool(r.get("ok", false)), "the board is placed (%s)" % str(r.get("error", "")))
	var pid := str(r.get("prop_id", ""))
	await _settle(tree, 10)
	var rec := PlacedPropService.get_prop_record(main, pid)
	_ok(rec.get("esp_spec") is Dictionary and str((rec["esp_spec"] as Dictionary).get("name", "")) == "Tank probe", "the record keeps its design")
	var gid := str(rec.get("graph_item_id", ""))
	var node: Dictionary = model.call("get_item", gid) if gid != "" else {}
	_ok(not node.is_empty() and str(node.get("type", "")) == "appliance", "the board has its own graph node")
	if not node.is_empty():
		var w := float((node["specs"] as Dictionary).get("avg_watts", 0.0))
		_ok(absf(w - EspBuilder.power_w(spec)) < 1e-6 and w > 0.3, "it draws the board's %.2f W" % w)
		_ok(str((node["specs"] as Dictionary).get("bound_prop_id", "")) == pid, "bound to the prop")
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid) as Node3D
	_ok(prop != null, "the prop is in the world")
	if prop == null:
		return {"ok": false, "failures": _fails}
	var board := EspLabRuntime.board_model(prop)
	_ok(board != null and board.find_children("*", "MeshInstance3D", true, false).size() >= 10, "the board is drawn with its parts")
	var rt := EspLabRuntime.of(prop)
	_ok(rt != null, "the twin's runtime is attached")
	if rt == null:
		return {"ok": false, "failures": _fails}
	await _wait(tree, 1.6)
	var lab0 := rt.call("readings_label") as Label3D
	print("esplab_world: label —\n%s" % (lab0.text if lab0 != null else "?"))
	var dist := _live(rt, "_jsn_sr04t_distance")
	_ok(bool(dist.get("available", false)) and absf(float(dist["value"]) - 0.6) < 0.06, "the bound ultrasonic reads the water 0.6 m down (%s)" % str(dist.get("text", "")))
	var ground := _live(rt, "_hc_sr04_distance")
	_ok(bool(ground.get("available", false)) and float(ground["value"]) > 0.6 and float(ground["value"]) < 1.1,
		"the unbound one reads the ground under its arm (%s)" % str(ground.get("text", "")))
	var flt := _live(rt, "_tank_float")
	_ok(bool(flt.get("available", false)) and flt["value"] == false, "the float is dry at 40 %% (%s)" % str(flt.get("text", "")))
	var relay := _live(rt, "_pump")
	_ok(relay.get("value", null) == true, "the relay follows the running pump (%s)" % str(relay.get("text", "")))
	var tmp := _live(rt, "_bme280_temperature")
	var ws := tree.root.get_node_or_null("WeatherService")
	if ws != null:
		var dd: Dictionary = CelestialClock.new().abs_hours_to_date(float(main.call("get_absolute_hours")))
		var site_t := float(ws.call("temperature_c", int(dd["month"]), int(dd["day"]), float(dd["day_time"])))
		_ok(bool(tmp.get("available", false)) and absf(float(tmp["value"]) - site_t) < 1.5, "the BME280 reads the site's air (%s vs %.1f °C)" % [str(tmp.get("text", "")), site_t])
	# Shots at midday.
	var day0: Variant = main.get("day_time")
	main.set("day_time", 12.5)
	await _wait(tree, 1.2)
	await _shot_from(main, tree, "board_side", prop.global_position + Vector3(1.4, 1.3, 1.4), prop.global_position + Vector3(0.1, 0.9, 0))
	await _shot_from(main, tree, "board_close", prop.global_position + Vector3(0.25, 1.15, 0.55), prop.global_position + Vector3(0.05, 1.0, 0.06))
	main.set("day_time", day0)
	# The tank fills: the float lifts, the ultrasonic reads its blind zone.
	# A tank's level is its timeline's (the flow engine writes specs from it).
	var ts: Dictionary = ((model.call("get_item", tank_id) as Dictionary)["specs"] as Dictionary).duplicate()
	ts["level"] = 0.95
	model.call("update_item", tank_id, {"specs": ts})
	var rf: Object = gv.get("_resource_flow")
	var tl: Object = rf.call("get_timeline", tank_id) if rf != null else null
	if tl != null:
		tl.call("set_current_level", float(main.call("get_absolute_hours")), 0.95)
	await _wait(tree, 1.3)
	flt = _live(rt, "_tank_float")
	dist = _live(rt, "_jsn_sr04t_distance")
	_ok(flt.get("value", null) == true and str(flt.get("text", "")) == "wet", "the float is wet when the tank is full (%s)" % str(flt.get("text", "")))
	_ok(absf(float(dist.get("value", 0.0)) - 0.25) < 0.02, "the ultrasonic bottoms out at its 25 cm blind zone (%s)" % str(dist.get("text", "")))
	# The pump stops: the relay follows.
	var ps: Dictionary = ((model.call("get_item", pump_id) as Dictionary)["specs"] as Dictionary).duplicate()
	ps["current_state"] = "off"
	ps["requested_state"] = "off"
	model.call("update_item", pump_id, {"specs": ps})
	await _wait(tree, 1.3)
	_ok(_live(rt, "_pump").get("value", null) == false, "the relay is off with the pump")
	# The board loses power.
	var bs: Dictionary = ((model.call("get_item", gid) as Dictionary)["specs"] as Dictionary).duplicate()
	bs["requested_state"] = "off"
	model.call("update_item", gid, {"specs": bs})
	await _wait(tree, 1.3)
	var all_down := true
	for k in (rt.get("latest") as Dictionary):
		all_down = all_down and not bool((rt.get("latest") as Dictionary)[k]["available"])
	_ok(not bool(rt.get("powered")) and all_down, "with its node off, every entity is unavailable")
	var lbl := rt.call("readings_label") as Label3D
	_ok(lbl != null and lbl.text.find("no power") >= 0, "the label says no power")
	_ok(lbl != null and lbl.global_position.distance_to(prop.global_position + Vector3(0, 1.55, 0)) < 0.05, "the label hangs over the stake")
	bs["requested_state"] = "on"
	model.call("update_item", gid, {"specs": bs})
	await _wait(tree, 1.3)
	_ok(bool(rt.get("powered")) and bool(_live(rt, "_bme280_temperature").get("available", false)), "power back, readings back")
	# The designer, opened from the prop.
	var ui: Control = main.call("open_esplab", {"prop_id": pid})
	await _settle(tree, 10)
	_ok(ui != null and str(ui.call("bound_prop_id")) == pid, "the designer opens bound to the board")
	_ok(str((ui.call("spec") as Dictionary)["name"]) == "Tank probe", "with its design")
	var apply := ui.find_child("apply_placed", true, false) as Button
	_ok(apply != null and apply.visible, "Apply to placed board is offered")
	var relay_iid := ""
	for p in (ui.call("spec") as Dictionary)["parts"]:
		if str(p["part"]) == "relay_1ch":
			relay_iid = str(p["iid"])
	ui.call("_select", {"kind": "part", "iid": relay_iid})
	await _settle(tree, 3)
	var picker := ui.find_child("measures_relay", true, false) as OptionButton
	_ok(picker != null and picker.item_count >= 3, "the relay's card offers the loads it can switch (%d)" % (picker.item_count if picker != null else 0))
	_ok(picker != null and str(picker.get_item_metadata(picker.selected)) == "item.%s.switch" % pump_id, "showing the pump it follows")
	var s2: Dictionary = (ui.call("spec") as Dictionary).duplicate(true)
	s2["name"] = "Water tank"
	ui.call("_set_spec", s2)
	await _settle(tree, 3)
	await HarnessInput.click(main.get_viewport(), HarnessInput.center_of(apply))
	await _settle(tree, 10)
	rec = PlacedPropService.get_prop_record(main, pid)
	_ok(str((rec.get("esp_spec", {}) as Dictionary).get("name", "")) == "Water tank", "Apply wrote the design to the board")
	node = model.call("get_item", gid)
	_ok(str((node.get("specs", {}) as Dictionary).get("name", "")) == "ESP · Water tank", "and renamed its graph node")
	ui.call("close")
	await _settle(tree, 3)
	prop = PlacedPropRuntime.find_by_prop_id(main, pid) as Node3D
	rt = EspLabRuntime.of(prop) if prop != null else null
	await _wait(tree, 1.3)
	_ok(rt != null and str((rt.call("design") as Dictionary).get("friendly", "")) == "Water tank", "the rebuilt board's twin has the new design")
	# Delete: the graph node goes with it.
	var loader := main.find_child("TerrainLoader", true, false)
	if loader != null:
		loader.call("delete_prop_by_id", pid)
		await _settle(tree, 6)
		_ok((model.call("get_item", gid) as Dictionary).is_empty(), "deleting the board removes its graph node")
	model.call("remove_item", tank_id)
	model.call("remove_item", pump_id)
	print("esplab_world: %d failure(s)" % _fails.size())
	return {"ok": _fails.is_empty(), "failures": _fails}
