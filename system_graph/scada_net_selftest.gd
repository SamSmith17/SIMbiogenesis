extends SceneTree

## The information domain (offline): ScadaNet's data wires, ports and reach;
## the show-only filter's Network domain; a network node's ports.
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script system_graph/scada_net_selftest.gd

const EXPECTED_CHECKS := 31

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_ports_and_domain()
	_test_reach()
	_test_checks()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("SCADA NET SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _node(id: String, role: String, on: bool = true) -> Dictionary:
	var s := ScadaNet.make_specs(role, id, 5.0)
	s["current_state"] = "on" if on else "off"
	return {"id": id, "type": "appliance", "specs": s}


func _wire(id: String, a: String, b: String, ah: String = "data", bh: String = "data", extra: Dictionary = {}) -> Dictionary:
	var c := {"id": id, "polarity": "data", "source_item_id": a, "source_handle_id": ah,
		"target_item_id": b, "target_handle_id": bh}
	c.merge(extra)
	return c


func _has_handle(hs: Array, id: String) -> bool:
	for h in hs:
		if str((h as Dictionary).get("id", "")) == id:
			return true
	return false


func _test_ports_and_domain() -> void:
	var statics := {"appliance": [{"id": "input", "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputBottom", "polarity": "load", "rx": 0.5, "ry": 1.0}]}
	var hs := GraphPortService.resolved_handles(_node("sw", ScadaNet.ROLE_SWITCH), statics)
	var n_data := 0
	for h in hs:
		if str((h as Dictionary).get("polarity", "")) == "data":
			n_data += 1
	_ok(n_data == 5, "a 5-port switch has five data ports (%d)" % n_data)
	_ok(_has_handle(hs, "input"), "and keeps its supply port")
	_ok(not _has_handle(hs, "inputBottom"), "the type's bottom port makes way for them")
	_ok(_has_handle(GraphPortService.resolved_handles(_node("ap", ScadaNet.ROLE_AP), statics), "wifi"), "an access point has a wifi port")
	var plain := {"id": "lamp", "type": "appliance", "specs": {"name": "Lamp"}}
	_ok(GraphPortService.resolved_handles(plain, statics).size() == 2, "an ordinary load is unchanged")
	var esp := {"id": "b", "type": "appliance", "specs": {"name": "Board", "model_id": "esplab_board"}}
	_ok(ScadaNet.role_of(esp) == ScadaNet.ROLE_BOARD, "a placed ESP board's node is a board")
	_ok(GraphDomainFilter.conn_domain(_wire("w", "a", "b")) == GraphDomainFilter.DATA, "a data wire is in the Network domain")
	_ok(GraphDomainFilter.handle_domain({"polarity": "data"}) == GraphDomainFilter.DATA
		and GraphDomainFilter.handle_domain({"polarity": "ac"}) == GraphDomainFilter.POWER, "ports too; power is still power")
	_ok(GraphDomainFilter.describe({GraphDomainFilter.DATA: true}) == "Network", "it is called Network")
	_ok(ScadaNet.kind_of(_wire("w", "ap", "b", "wifi")) == "wireless" and ScadaNet.kind_of(_wire("w", "a", "b")) == "ethernet"
		and ScadaNet.kind_of(_wire("w", "a", "b", "data", "data", {"data_kind": "bus_rs485"})) == "bus_rs485", "wire kinds")


func _test_reach() -> void:
	var board := _node("b1", ScadaNet.ROLE_BOARD)
	var r0 := ScadaNet.reach([board], [])
	_ok(not bool(r0["enforced"]) and bool(r0["nodes"]["b1"]["ok"]), "no server on the graph: every board is heard")
	var items := [_node("srv", ScadaNet.ROLE_SERVER), _node("sw", ScadaNet.ROLE_SWITCH), _node("ap", ScadaNet.ROLE_AP),
		board, _node("b2", ScadaNet.ROLE_BOARD), _node("b3", ScadaNet.ROLE_BOARD)]
	var conns := [_wire("w1", "srv", "sw", "data", "data_0"), _wire("w2", "sw", "b1", "data_1"),
		_wire("w3", "sw", "ap", "data_2"), _wire("w4", "ap", "b2", "wifi")]
	var r := ScadaNet.reach(items, conns)
	_ok(bool(r["enforced"]), "a server makes it count")
	_ok(bool(r["nodes"]["b1"]["ok"]) and int(r["nodes"]["b1"]["hops"]) == 2, "a board behind a switch is heard, two hops out")
	_ok(bool(r["nodes"]["b2"]["ok"]) and int(r["nodes"]["b2"]["hops"]) == 3, "a board on Wi-Fi is heard through the access point")
	_ok(not bool(r["nodes"]["b3"]["ok"]) and str(r["nodes"]["b3"]["why"]) == "not on the network", "an unwired board is not")
	items[1] = _node("sw", ScadaNet.ROLE_SWITCH, false)
	var r2 := ScadaNet.reach(items, conns)
	_ok(not bool(r2["nodes"]["b1"]["ok"]) and str(r2["nodes"]["b1"]["why"]) == "no path to the server", "an unpowered switch cuts off what is behind it")
	_ok(not bool(r2["nodes"]["b2"]["ok"]), "the Wi-Fi board too")
	items[1] = _node("sw", ScadaNet.ROLE_SWITCH)
	var chain := conns.duplicate()
	chain.append(_wire("w5", "b1", "b3"))
	_ok(not bool(ScadaNet.reach(items, chain)["nodes"]["b3"]["ok"]), "a board does not forward to another board")
	items[3] = _node("b1", ScadaNet.ROLE_BOARD, false)
	_ok(str(ScadaNet.reach(items, conns)["nodes"]["b1"]["why"]) == "no power", "a board with no power says so")
	items[3] = board
	var long := conns.duplicate(true)
	long[1]["route_length_m"] = 140.0
	_ok(bool(ScadaNet.reach(items, long)["nodes"]["b1"]["ok"]), "a length nobody routed in the world does not count")
	long[1]["visible_3d"] = true
	var r3 := ScadaNet.reach(items, long)
	_ok(not bool(r3["nodes"]["b1"]["ok"]) and str(r3["nodes"]["b1"]["why"]).contains("100 m"), "140 m of Ethernet does not work (%s)" % str(r3["nodes"]["b1"]["why"]))
	long[1]["route_length_m"] = 80.0
	_ok(bool(ScadaNet.reach(items, long)["nodes"]["b1"]["ok"]), "80 m does")
	long[1]["data_kind"] = "bus_rs485"
	long[1]["route_length_m"] = 600.0
	_ok(bool(ScadaNet.reach(items, long)["nodes"]["b1"]["ok"]), "600 m of RS-485 does")
	items[0] = _node("srv", ScadaNet.ROLE_SERVER, false)
	_ok(not bool(ScadaNet.reach(items, conns)["nodes"]["b1"]["ok"]), "a server with no power hears nobody")
	items[0] = _node("srv", ScadaNet.ROLE_SERVER)
	_ok(str(ScadaNet.reach(items, conns)) == str(ScadaNet.reach(items, conns)), "deterministic")


func _test_checks() -> void:
	var items := [_node("srv", ScadaNet.ROLE_SERVER), _node("sw", ScadaNet.ROLE_SWITCH),
		_node("b1", ScadaNet.ROLE_BOARD), _node("b2", ScadaNet.ROLE_BOARD)]
	var conns := [_wire("w1", "srv", "sw", "data", "data_0"), _wire("w2", "sw", "b1", "data_1")]
	var cs := ScadaNet.checks(items, conns)
	_ok(cs.size() == 1 and str(cs[0]["level"]) == "error" and (cs[0]["ids"] as Array) == ["b2"], "checks: the unwired board is an error")
	conns.append(_wire("w3", "sw", "b2", "data_1"))
	cs = ScadaNet.checks(items, conns)
	_ok(cs.size() == 1 and str(cs[0]["level"]) == "warn" and str(cs[0]["text"]).contains("2 cables"), "checks: two cables in one port is a warning")
	conns[2]["source_handle_id"] = "data_2"
	conns[2]["route_length_m"] = 300.0
	conns[2]["visible_3d"] = true
	cs = ScadaNet.checks(items, conns)
	var named := false
	for c in cs:
		if (c["ids"] as Array) == ["w3"]:
			named = true
	_ok(named, "checks: a cable too long names the cable")
	_ok(ScadaNet.checks([_node("b", ScadaNet.ROLE_BOARD)], []).is_empty(), "checks: nothing to say with no network")
	_ok(ScadaNet.checks([], []).is_empty(), "checks: an empty graph")
	var sw8 := ScadaNet.data_handles(ScadaNet.ROLE_SWITCH, {"ports": 8})
	_ok(sw8.size() == 8 and float(sw8[0]["rx"]) < float(sw8[7]["rx"]), "an 8-port switch spreads eight ports")
