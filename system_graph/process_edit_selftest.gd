extends SceneTree

## Editing a process line (offline): ProcessEdit's place / split / link on a
## real GraphModel, and the flow engine running what they build.
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script system_graph/process_edit_selftest.gd

const EXPECTED_CHECKS := 30

const _MODEL := preload("res://system_graph/data/graph_model.gd")
const _ENGINE := preload("res://system_graph/resource_flow_engine.gd")

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_place_and_link()
	_test_split()
	_test_refusals()
	_test_machines()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("PROCESS EDIT SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _store(model: GraphModel, id: String, kind: String, level: float, x: float) -> void:
	model.add_item({"id": id, "type": "resource", "x": x, "y": 0.0,
		"specs": {"name": id, "resource_kind": kind, "capacity_qty": 1000.0, "capacity_unit": "L", "level": level}})


func _specs(model: GraphModel, id: String) -> Dictionary:
	return model.get_item(id).get("specs", {}) as Dictionary


func _run(model: GraphModel, hours: float) -> void:
	var engine = _ENGINE.new()
	engine.setup(model, null)
	engine.power_available_override = 1
	engine.simulate_step_for_test(0.0, 0.0)
	var steps := int(round(hours / 0.05))
	for i in steps:
		engine.simulate_step_for_test(float(i + 1) * 0.05, 0.05)


func _test_place_and_link() -> void:
	var model: GraphModel = _MODEL.new()
	_store(model, "a", "greywater", 0.8, 0.0)
	_store(model, "b", "greywater", 0.0, 400.0)
	var r := ProcessEdit.place(model, "valve", "root", Vector2(200, 200))
	_ok(bool(r["ok"]) and not model.get_item(str(r["id"])).is_empty(), "place: a valve is added")
	var v := str(r["id"])
	_ok(FlowCtl.is_flowctl(_specs(model, v)) and bool(_specs(model, v).get(ProcessEdit.SHOW_KEY, false)), "place: it is a flow control, shown before it is piped")
	_ok(str(_specs(model, v).get("ctl_resource", "")) == "water", "place: on a water line until piped")
	var doc := MimicGraphSource.build(model.get_items_in_scope("root"), model.get_connections_in_scope("root"))
	_ok((doc["elements"] as Array).size() == 1, "place: only the new valve is in the picture (unpiped stores are not)")
	var l1 := ProcessEdit.link(model, "a", v)
	_ok(bool(l1["ok"]), "link: store → valve")
	_ok(str(_specs(model, v).get("ctl_resource", "")) == "greywater", "link: the unpiped valve takes the store's kind")
	_ok(str((_specs(model, v).get("inputs", [{}])[0] as Dictionary).get("kind", "")) == "greywater", "link: and its ports with it")
	var l2 := ProcessEdit.link(model, v, "b")
	_ok(bool(l2["ok"]) and model.get_connections_in_scope("root").size() == 2, "link: valve → store")
	var c := model.get_connection(str(l2["id"]))
	_ok(str(c.get("resource_type", "")) == "greywater" and str(c.get("source_handle_id", "")) == "res_out_0"
		and str(c.get("target_handle_id", "")) == "input", "link: the wire's kind and handles")
	_run(model, 0.25)
	_ok(float(_specs(model, "b").get("level", 0.0)) > 0.05, "the built line carries (b %.2f)" % float(_specs(model, "b").get("level", 0.0)))
	var total := float(_specs(model, "a").get("level", 0.0)) + float(_specs(model, "b").get("level", 0.0))
	_ok(absf(total - 0.8) < 1e-4, "and mass is exact (%.5f)" % total)
	# A lens-placed store takes the kind of what is piped into it.
	var s := ProcessEdit.place(model, "store", "root", Vector2(600, 0))
	var l3 := ProcessEdit.link(model, "b", str(s["id"]))
	_ok(not bool(l3["ok"]) or str(_specs(model, str(s["id"])).get("resource_kind", "")) == "greywater", "link: a new store takes the kind piped into it")
	_ok(bool(l3["ok"]), "link: store → new store is allowed (the engine moves nothing without a pump or valve)")


func _test_split() -> void:
	var model: GraphModel = _MODEL.new()
	_store(model, "a", "water", 0.8, 0.0)
	_store(model, "b", "water", 0.1, 400.0)
	model.add_connection({"id": "w", "polarity": "resource", "resource_type": "water", "source_item_id": "a",
		"source_handle_id": "output", "target_item_id": "b", "target_handle_id": "input"})
	var r := ProcessEdit.split(model, "w", "pump")
	_ok(bool(r["ok"]), "split: a pump goes into the pipe")
	var p := str(r["id"])
	_ok(model.get_connection("w").is_empty() and model.get_connections_in_scope("root").size() == 2, "split: one pipe became two")
	var into := false
	var out := false
	for c in model.get_connections_in_scope("root"):
		if str(c["source_item_id"]) == "a" and str(c["target_item_id"]) == p and str(c["target_handle_id"]) == "res_in_0":
			into = true
		if str(c["source_item_id"]) == p and str(c["target_item_id"]) == "b" and str(c["source_handle_id"]) == "res_out_0":
			out = true
	_ok(into and out, "split: a → pump → b on the pump's ports")
	_ok(FlowCtl.kind_of(_specs(model, p)) == FlowCtl.KIND_PUMP and not _specs(model, p).has(ProcessEdit.SHOW_KEY), "split: it is a pump")
	_ok(is_equal_approx(float(model.get_item(p).get("x", 0.0)), 200.0), "split: it stands between the two on the graph")
	var doc := MimicGraphSource.build(model.get_items_in_scope("root"), model.get_connections_in_scope("root"))
	var xs := {}
	for e in doc["elements"]:
		xs[str(e["id"])] = (e["pos"] as Vector2).x
	_ok(float(xs["a"]) < float(xs[p]) and float(xs[p]) < float(xs["b"]), "split: and between them in the picture")
	# A pump needs power: an inverter on its supply port.
	model.add_item({"id": "inv", "type": "controller", "x": 200.0, "y": -200.0, "specs": {"name": "Inverter"}})
	model.add_connection({"id": "pw", "polarity": "ac", "source_item_id": "inv", "source_handle_id": "ac_out",
		"target_item_id": p, "target_handle_id": "power_in"})
	_run(model, 0.5)
	_ok(float(_specs(model, "b").get("level", 0.0)) > 0.3, "the pumped line carries (b %.2f)" % float(_specs(model, "b").get("level", 0.0)))
	var r2 := ProcessEdit.split(model, "nope", "valve")
	_ok(not bool(r2["ok"]) and not str(r2["why"]).is_empty(), "split: no pipe, no part, and it says so")
	# A store in a line.
	var first := str((model.get_connections_in_scope("root")[0] as Dictionary)["id"])
	var r3 := ProcessEdit.split(model, first, "store")
	_ok(bool(r3["ok"]) and str(_specs(model, str(r3["id"])).get("resource_kind", "")) == "water"
		and model.get_connections_in_scope("root").size() == 4, "split: a store can go in a line too")


func _test_refusals() -> void:
	var model: GraphModel = _MODEL.new()
	_store(model, "a", "water", 0.8, 0.0)
	_store(model, "g", "greywater", 0.1, 400.0)
	var r := ProcessEdit.link(model, "a", "g")
	_ok(not bool(r["ok"]) and str(r["why"]).contains("does not take"), "link: water into a greywater store is refused in words (%s)" % str(r["why"]))
	_ok(model.get_connections_in_scope("root").is_empty(), "link: and nothing is made")
	_ok(not bool(ProcessEdit.link(model, "a", "a")["ok"]), "link: not to itself")
	_store(model, "b", "water", 0.1, 800.0)
	ProcessEdit.link(model, "a", "b")
	_ok(not bool(ProcessEdit.link(model, "a", "b")["ok"]), "link: not twice")
	_ok(not bool(ProcessEdit.place(model, "rocket", "root", Vector2.ZERO)["ok"]), "place: unknown parts are refused")


func _test_machines() -> void:
	var model: GraphModel = _MODEL.new()
	_store(model, "w", "water", 0.8, 0.0)
	_store(model, "g", "greywater", 0.0, 800.0)
	model.add_item({"id": "m", "type": "processor", "x": 400.0, "y": 0.0, "specs": {"name": "Washer",
		"inputs": [{"kind": "biomass", "rate": 1.0}, {"kind": "water", "rate": 10.0}],
		"outputs": [{"kind": "heat", "rate": 1.0}, {"kind": "greywater", "rate": 9.0}]}})
	var r1 := ProcessEdit.link(model, "w", "m")
	_ok(bool(r1["ok"]) and str(model.get_connection(str(r1["id"])).get("target_handle_id", "")) == "res_in_1", "link: a store joins the machine's matching input")
	var r2 := ProcessEdit.link(model, "m", "g")
	_ok(bool(r2["ok"]) and str(model.get_connection(str(r2["id"])).get("source_handle_id", "")) == "res_out_1"
		and str(model.get_connection(str(r2["id"])).get("resource_type", "")) == "greywater", "link: a machine's matching output joins the store")
	var r3 := ProcessEdit.link(model, "g", "m")
	_ok(not bool(r3["ok"]), "link: a machine refuses what it does not take")
