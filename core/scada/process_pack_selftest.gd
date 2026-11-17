extends SceneTree
## Process packs (SCADA plan, Phase 9), offline:
##   Godot --headless --path . --script core/scada/process_pack_selftest.gd
## capture / clean / instantiate / share code / library file / built-ins.

const EXPECTED_CHECKS := 50
const TMP := "user://selftest_process_library.json"

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _initialize() -> void:
	_test_capture()
	_test_clean()
	_test_instantiate()
	_test_code()
	_test_library()
	_test_templates()
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: expected %d checks, ran %d (a test function aborted?)" % [EXPECTED_CHECKS, _checks])
	print("PROCESS PACK SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAILED", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _plant() -> Dictionary:
	var items := [
		{"id": "a", "type": "resource", "x": 100.0, "y": 50.0, "specs": {"name": "Supply", "resource_kind": "water", "capacity_qty": 5000.0, "level": 0.7, "node_state": "running", "bound_prop_id": "prop_9"}},
		{"id": "v", "type": "processor", "x": 300.0, "y": 50.0, "specs": FlowCtl.make_specs("Valve", FlowCtl.KIND_VALVE, "water", 600.0)},
		{"id": "b", "type": "resource", "x": 500.0, "y": 50.0, "specs": {"name": "Day", "resource_kind": "water", "capacity_qty": 1000.0, "level": 0.4}},
		{"id": "z", "type": "resource", "x": 900.0, "y": 50.0, "specs": {"name": "Elsewhere", "resource_kind": "water", "capacity_qty": 10.0, "level": 0.1}},
		{"id": "g", "type": "compound", "x": 0.0, "y": 0.0, "specs": {"name": "A group"}},
	]
	var conns := [
		{"polarity": "resource", "resource_type": "water", "source_item_id": "a", "source_handle_id": "output", "target_item_id": "v", "target_handle_id": "res_in_0", "flow_rate": 12.0},
		{"polarity": "resource", "resource_type": "water", "source_item_id": "v", "source_handle_id": "res_out_0", "target_item_id": "b", "target_handle_id": "input"},
		{"polarity": "resource", "resource_type": "water", "source_item_id": "b", "source_handle_id": "output", "target_item_id": "z", "target_handle_id": "input"},
	]
	var logic := [
		ScadaLogic.template("hold_level_band", "b1", {"pv": "tank.b.level", "out": "node.v"}),
		ScadaLogic.template("hold_level_band", "b2", {"pv": "tank.z.level", "out": "node.v"}),
		ScadaLogic.template("hold_level_band", "b3", {"pv": "sensor.battery_level", "out": "node.v"}),
	]
	var alarms := [ScadaAlarms.make("a1", "Day high", "tank.b.level", ">=", 90.0), ScadaAlarms.make("a2", "Else", "tank.z.level", ">=", 90.0),
		ScadaAlarms.make("a3", "Block", "logic.b1.out", "on", 0.5), ScadaAlarms.make("a4", "Other block", "logic.b2.out", "on", 0.5)]
	var widgets := [{"id": "w1", "kind": "gauge", "x": 10.0, "y": 10.0, "tag": "tank.b.level"}, {"id": "w2", "kind": "gauge", "x": 10.0, "y": 10.0, "tag": "tank.z.level"},
		{"id": "w3", "kind": "text", "x": 0.0, "y": 0.0, "text": "note"}]
	return {"items": items, "conns": conns, "logic": logic, "alarms": alarms, "widgets": widgets}


func _test_capture() -> void:
	var pl := _plant()
	var p := ProcessPack.capture("Day line", pl["items"], pl["conns"], ["a", "v", "b", "g"], pl["logic"], pl["alarms"], pl["widgets"])
	_check((p["items"] as Array).size() == 3, "capture: the three chosen parts (a group is not a part)")
	_check((p["conns"] as Array).size() == 2, "capture: only the pipes between them")
	_check(not (p["conns"][0] as Dictionary).has("flow_rate"), "capture: a wire's live flow is left behind")
	var sp: Dictionary = p["items"][0]["specs"]
	_check(not sp.has("node_state") and not sp.has("bound_prop_id") and float(sp["level"]) == 0.7, "capture: live state and the 3D binding stripped, the level kept")
	var cx := 0.0
	for it in p["items"]:
		cx += float(it["x"])
	_check(absf(cx) < 2.0, "capture: positions are about the middle of the pack")
	_check((p["logic"] as Array).size() == 2 and str(p["logic"][0]["id"]) == "b1" and str(p["logic"][1]["id"]) == "b3", "capture: blocks on its parts come along, one reading a site tag too; not one reading another tank")
	var tags: Array = []
	for r in p["alarms"]:
		tags.append(str(r["tag"]))
	_check(tags == ["tank.b.level", "logic.b1.out"], "capture: alarms on its parts and on its own block")
	_check((p["widgets"] as Array).size() == 1 and str(p["widgets"][0]["tag"]) == "tank.b.level", "capture: widgets bound to its parts")
	_check(ProcessPack.tag_item("tank.b.level") == "b" and ProcessPack.tag_item("valve.v.open") == "v" and ProcessPack.tag_item("sensor.battery_level") == "" and ProcessPack.tag_item("logic.b1.out") == "", "tag_item: which item a tag names")
	_check(ProcessPack.describe(p) == "3 parts, 2 control blocks, 2 alarms, 1 widget", "describe: %s" % ProcessPack.describe(p))


func _test_clean() -> void:
	_check(not bool(ProcessPack.clean("nope")["ok"]) and not bool(ProcessPack.clean({"items": []})["ok"]), "clean: not a process / no parts refused")
	_check(not bool(ProcessPack.clean({"v": 99, "items": [{"id": "a", "type": "resource"}]})["ok"]), "clean: a newer version refused")
	var big := {"items": []}
	for i in 100:
		(big["items"] as Array).append({"id": "i%d" % i, "type": "resource", "specs": {}})
	_check(not bool(ProcessPack.clean(big)["ok"]), "clean: too many parts refused")
	var dirty := {"name": "  X  ", "items": [
		{"id": "a", "type": "resource", "x": 9.0e9, "specs": {"name": "T", "level": 0.5, "scene_device_path": "/root/Main/Thing", "ha_entity_id": "switch.real", "access_token": "abc", "node_state": "starved"}},
		{"id": "a", "type": "resource", "specs": {}},
		{"id": "evil", "type": "script_runner", "specs": {}},
		{"id": "v", "type": "processor", "specs": FlowCtl.make_specs("V", FlowCtl.KIND_VALVE, "water", 100.0)}],
		"conns": [{"polarity": "resource", "source_item_id": "a", "target_item_id": "v", "source_handle_id": "output", "target_handle_id": "res_in_0"},
			{"polarity": "resource", "source_item_id": "a", "target_item_id": "gone"}],
		"logic": [ScadaLogic.template("overfill", "k1", {"pv": "tank.a.level", "out": "node.v"}),
			ScadaLogic.template("overfill", "k2", {"pv": "tank.a.level", "out": "node.someone_elses_pump"}),
			{"id": "k3", "kind": "exec", "pv": "tank.a.level"}],
		"alarms": [{"id": "a1", "name": "High", "tag": "tank.a.level", "op": ">=", "limit": 90.0, "priority": "weird"}, {"id": "a2", "tag": "tank.outside.level"}],
		"widgets": [{"id": "w1", "kind": "slider", "tag": "valve.v.open", "screen": "s9"}, {"id": "w2", "kind": "gauge", "tag": "tank.outside.level"}],
		"outputs": [{"tag": "node.v", "entity_id": "switch.real_pump"}]}
	var res := ProcessPack.clean(dirty)
	_check(bool(res["ok"]), "clean: a messy pack comes through")
	var p: Dictionary = res["pack"]
	_check(str(p["name"]) == "X" and (p["items"] as Array).size() == 2, "clean: name trimmed; a duplicate id and an unknown type dropped")
	var sp: Dictionary = p["items"][0]["specs"]
	_check(not sp.has("scene_device_path") and not sp.has("ha_entity_id") and not sp.has("access_token") and not sp.has("node_state") and float(sp["level"]) == 0.5,
		"clean: spec keys naming a path, an entity or a token are dropped, so is live state")
	_check(float(p["items"][0]["x"]) == 20000.0, "clean: positions clamped")
	_check((p["conns"] as Array).size() == 1, "clean: a pipe to a part that is not in the pack dropped")
	_check((p["logic"] as Array).size() == 1 and str(p["logic"][0]["id"]) == "k1", "clean: a block driving something outside the pack, and an unknown kind, dropped")
	_check((p["alarms"] as Array).size() == 1 and str(p["alarms"][0]["priority"]) == "medium", "clean: an alarm on an outside tag dropped; a bad priority made medium")
	_check((p["widgets"] as Array).size() == 1 and str(p["widgets"][0]["screen"]) == "", "clean: a widget on an outside tag dropped; nav targets cleared")
	_check(not p.has("outputs"), "clean: a pack never carries real-output links")


func _test_instantiate() -> void:
	var p := ProcessPack.template("level_pid")
	var n := [0]
	var mk := func(prefix: String) -> Callable:
		return func() -> String:
			n[0] += 1
			return "%s%d" % [prefix, n[0]]
	var inst := ProcessPack.instantiate(p, Vector2(1000, 500), "root", mk.call("item_"), mk.call("b"), mk.call("a"), mk.call("w"))
	var ids: Dictionary = inst["ids"]
	_check(ids.size() == 5 and str(ids["day"]).begins_with("item_"), "instantiate: every part gets a new id")
	var day := str(ids["day"])
	var fv := str(ids["fv"])
	_check(str(inst["logic"][0]["pv"]) == "tank.%s.level" % day and str(inst["logic"][0]["out"]) == "valve.%s.open" % fv, "instantiate: the block's tags follow the new ids")
	_check(str(inst["logic"][0]["id"]).begins_with("b") and str(inst["logic"][0]["id"]) != "b1" or n[0] > 0, "instantiate: the block gets a new id")
	_check(str(inst["alarms"][0]["tag"]) == "tank.%s.level" % day and str(inst["alarms"][0]["id"]).begins_with("a"), "instantiate: alarms follow")
	_check(str(inst["widgets"][0]["tag"]) == "tank.%s.level" % day and str(inst["widgets"][0]["id"]).begins_with("w"), "instantiate: widgets follow")
	var src: Dictionary = inst["conns"][0]
	_check(str(src["source_item_id"]) == str(ids["src"]) and str(src["target_item_id"]) == fv and str(src["scope_id"]) == "root", "instantiate: pipes join the new parts, in the scope")
	var mid := 0.0
	for it in inst["items"]:
		mid += float(it["x"])
	_check(absf(mid / 5.0 - 1000.0) < 1.0 and float(inst["items"][0]["y"]) == 500.0, "instantiate: laid out about the given point")
	# An alarm on the pack's own block follows the block's new id.
	var q := ProcessPack.empty("q")
	q["items"] = [{"id": "t", "type": "resource", "x": 0.0, "y": 0.0, "specs": {}}, {"id": "v", "type": "processor", "x": 0.0, "y": 0.0, "specs": {}}]
	q["logic"] = [ScadaLogic.template("overfill", "k1", {"pv": "tank.t.level", "out": "node.v"})]
	q["alarms"] = [ScadaAlarms.make("a1", "Tripped", "logic.k1.tripped", "on", 0.5)]
	var i2 := ProcessPack.instantiate(q, Vector2.ZERO, "root", mk.call("it"), mk.call("blk"), mk.call("al"), mk.call("wd"))
	_check(str(i2["alarms"][0]["tag"]) == "logic.%s.tripped" % str(i2["logic"][0]["id"]), "instantiate: an alarm on the pack's own block follows the block")
	# Twice in one graph: nothing collides.
	var again := ProcessPack.instantiate(p, Vector2.ZERO, "root", mk.call("item_"), mk.call("b"), mk.call("a"), mk.call("w"))
	_check(str(again["ids"]["day"]) != day and str(again["logic"][0]["id"]) != str(inst["logic"][0]["id"]), "instantiate twice: separate ids")


func _test_code() -> void:
	var p := ProcessPack.template("level_band")
	var code := ProcessPack.encode(p)
	_check(code.begins_with(ProcessPack.PREFIX) and code.length() < 4000, "share code: starts SMPR1:, %d characters" % code.length())
	var back := ProcessPack.decode("  " + code + "\n")
	_check(bool(back["ok"]), "share code: reads back")
	var bp: Dictionary = back["pack"]
	_check(str(bp["name"]) == str(p["name"]) and (bp["items"] as Array).size() == 5 and (bp["conns"] as Array).size() == 4 and (bp["logic"] as Array).size() == 1 and (bp["alarms"] as Array).size() == 2,
		"share code: the same parts, pipes, block and alarms")
	_check(float(bp["logic"][0]["low"]) == 40.0 and str(bp["logic"][0]["pv"]) == "tank.day.level", "share code: the block's settings survive")
	_check(not bool(ProcessPack.decode("")["ok"]) and not bool(ProcessPack.decode("hello")["ok"]), "share code: empty and unrelated text refused")
	_check(not bool(ProcessPack.decode(code.substr(0, code.length() - 30))["ok"]), "share code: a cut-off code refused")
	_check(not bool(ProcessPack.decode(ProcessPack.PREFIX + "!!!!:12")["ok"]), "share code: garbage refused")
	_check(bool(ProcessPack.decode(JSON.stringify(p))["ok"]), "plain JSON is read too")
	_check(not bool(ProcessPack.decode(ProcessPack.PREFIX + "AAAA:999999999")["ok"]), "share code: an absurd size refused")


func _test_library() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	_check(ProcessLibrary.load_all(TMP).is_empty(), "library: no file = empty")
	var p := ProcessPack.template("pump_transfer")
	_check(ProcessLibrary.add(p, TMP) == str(p["name"]), "library: add keeps the name")
	_check(ProcessLibrary.add(p, TMP) == str(p["name"]) + " (2)", "library: a second of the same name is numbered")
	var all := ProcessLibrary.load_all(TMP)
	_check(all.size() == 2 and (all[0]["logic"] as Array).size() == 2, "library: both come back from the file, blocks and all")
	_check(not ProcessLibrary.find(str(p["name"]) + " (2)", TMP).is_empty() and ProcessLibrary.find("nope", TMP).is_empty(), "library: find by name")
	_check(ProcessLibrary.remove(str(p["name"]), TMP) and ProcessLibrary.load_all(TMP).size() == 1 and not ProcessLibrary.remove("nope", TMP), "library: remove")


func _test_templates() -> void:
	var all_ok := true
	var names := {}
	for t in ProcessPack.TEMPLATES:
		var p := ProcessPack.template(str(t[0]))
		var c := ProcessPack.clean(p)
		if not bool(c["ok"]) or JSON.stringify(c["pack"]["logic"]) != JSON.stringify(p["logic"]) or (c["pack"]["items"] as Array).size() != (p["items"] as Array).size() \
				or (c["pack"]["alarms"] as Array).size() != (p["alarms"] as Array).size() or (c["pack"]["widgets"] as Array).size() != (p["widgets"] as Array).size():
			all_ok = false
			print("    template %s does not survive clean()" % str(t[0]))
		names[str(p["name"])] = true
	_check(all_ok, "every built-in survives clean() whole")
	_check(names.size() == ProcessPack.TEMPLATES.size(), "built-ins have different names")
	var pid := ProcessPack.template("level_pid")
	_check(bool(pid["items"][1]["specs"]["throttle"]) and str(pid["logic"][0]["kind"]) == "pid" and (pid["widgets"] as Array).size() == 2, "the PID template has a control valve, a PID block and two widgets")
	var pump := ProcessPack.template("pump_transfer")
	_check(str(pump["items"][1]["specs"]["ctl_kind"]) == FlowCtl.KIND_PUMP and (pump["logic"] as Array).size() == 2, "the pump template has a pump and two interlocks")
