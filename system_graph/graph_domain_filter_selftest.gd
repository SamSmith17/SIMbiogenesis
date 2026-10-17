extends SceneTree

## GraphDomainFilter (show-only views). Offline:
##   godot --headless --path . --script system_graph/graph_domain_filter_selftest.gd

const EXPECTED_CHECKS := 25

var _checks := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", what)


func _initialize() -> void:
	_test_domains()
	_test_mixed_graph()
	_test_orphans_and_compounds()
	_test_round_trip()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	print("GRAPH DOMAIN FILTER SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _test_domains() -> void:
	_ok(GraphDomainFilter.conn_domain({"polarity": "positive"}) == "power", "DC+ wire is power")
	_ok(GraphDomainFilter.conn_domain({"polarity": "pvNegative"}) == "power", "PV- wire is power")
	_ok(GraphDomainFilter.conn_domain({"polarity": "ac"}) == "power", "AC wire is power")
	_ok(GraphDomainFilter.conn_domain({"polarity": "resource", "resource_type": "water"}) == "water", "water wire")
	_ok(GraphDomainFilter.conn_domain({"polarity": "resource", "resource_type": "greywater"}) == "water", "greywater")
	_ok(GraphDomainFilter.conn_domain({"polarity": "resource", "resource_type": "electric"}) == "power",
		"an electric resource wire is power")
	_ok(GraphDomainFilter.kind_domain("potable_water") == "water", "aliases resolve")
	_ok(GraphDomainFilter.kind_domain("money") == "other", "unknown kinds are other")
	var hd := GraphDomainFilter.handles_domains([
		{"polarity": "resource", "resource_kind": "sunlight"}, {"polarity": "positive"}])
	_ok(hd.has("power") and not hd.has("ambient"), "ambient ports never decide a node's domain")


func _mixed() -> Dictionary:
	var items := [
		{"id": "pv", "type": "panel"},
		{"id": "inv", "type": "controller"},
		{"id": "bat", "type": "battery"},
		{"id": "pond", "type": "resource"},
		{"id": "tank", "type": "resource"},
		{"id": "hab", "type": "processor"},
		{"id": "sun", "type": "ambient"},
	]
	var conns := [
		{"id": "c1", "polarity": "pvPositive", "source_item_id": "pv", "target_item_id": "inv"},
		{"id": "c2", "polarity": "positive", "source_item_id": "inv", "target_item_id": "bat"},
		{"id": "c3", "polarity": "resource", "resource_type": "water", "source_item_id": "pond", "target_item_id": "tank"},
		{"id": "c4", "polarity": "resource", "resource_type": "water", "source_item_id": "tank", "target_item_id": "hab"},
		{"id": "c5", "polarity": "ac", "source_item_id": "inv", "target_item_id": "hab"},
		{"id": "c6", "polarity": "resource", "resource_type": "sunlight", "source_item_id": "sun", "target_item_id": "pv"},
	]
	var ports := {
		"pv": [{"polarity": "pvPositive"}, {"polarity": "resource", "resource_kind": "sunlight"}],
		"inv": [{"polarity": "pvPositive"}, {"polarity": "positive"}, {"polarity": "ac"}],
		"bat": [{"polarity": "positive"}],
		"pond": [{"polarity": "resource", "resource_kind": "water"}],
		"tank": [{"polarity": "resource", "resource_kind": "water"}],
		"hab": [{"polarity": "ac"}, {"polarity": "resource", "resource_kind": "water"}],
		"sun": [{"polarity": "resource", "resource_kind": "sunlight"}],
	}
	var dom := func(it: Dictionary) -> Dictionary:
		return GraphDomainFilter.handles_domains(ports.get(str(it["id"]), []))
	return {"items": items, "conns": conns, "dom": dom}


func _ids(arr: Array) -> Dictionary:
	var out := {}
	for a in arr:
		out[str((a as Dictionary)["id"])] = true
	return out


func _test_mixed_graph() -> void:
	var g := _mixed()
	var power := GraphDomainFilter.preset("power")
	var vis := _ids(GraphDomainFilter.filter_items(g["items"], g["conns"], power, g["dom"]))
	_ok(vis.has("pv") and vis.has("inv") and vis.has("bat"), "Power keeps the panel, inverter, battery")
	_ok(not vis.has("pond") and not vis.has("tank"), "Power hides the pond and the tank")
	_ok(vis.has("hab"), "a habitat with an AC load shows under Power")
	_ok(not vis.has("sun"), "the sun (ambient only) is hidden")
	var conns := _ids(GraphDomainFilter.filter_connections(g["conns"], power, vis))
	_ok(conns.has("c1") and conns.has("c2") and conns.has("c5"), "power wires stay")
	_ok(not conns.has("c3") and not conns.has("c4"), "water wires hide")
	_ok(not conns.has("c6"), "the sun's wire hides with the sun")
	var water := _ids(GraphDomainFilter.filter_items(g["items"], g["conns"], GraphDomainFilter.preset("water"), g["dom"]))
	_ok(water.has("pond") and water.has("tank") and water.has("hab") and not water.has("bat"),
		"Water shows pond, tank, habitat and hides the battery")
	var all := GraphDomainFilter.filter_items(g["items"], g["conns"], {}, g["dom"])
	_ok(all.size() == (g["items"] as Array).size(), "an empty filter shows everything")


func _test_orphans_and_compounds() -> void:
	var g := _mixed()
	var items: Array = (g["items"] as Array).duplicate()
	items.append({"id": "spare_bat", "type": "battery"})
	items.append({"id": "note", "type": "note"})
	var dom := func(it: Dictionary) -> Dictionary:
		if str(it["id"]) == "spare_bat":
			return {"power": true}
		if str(it["id"]) == "note":
			return {}
		return (g["dom"] as Callable).call(it)
	var power := GraphDomainFilter.preset("power")
	var with_unwired := _ids(GraphDomainFilter.filter_items(items, g["conns"], power, dom, true))
	var wired_only := _ids(GraphDomainFilter.filter_items(items, g["conns"], power, dom, false))
	_ok(with_unwired.has("spare_bat"), "an unwired battery shows with 'include unwired'")
	_ok(not wired_only.has("spare_bat"), "and hides without it")
	_ok(not with_unwired.has("note"), "a node with no ports is hidden by any filter")
	# A compound reports its descendants' domains through item_domains.
	var station := [{"id": "ps", "type": "compound"}]
	var cdom := func(_it: Dictionary) -> Dictionary: return {"power": true, "water": true}
	_ok(GraphDomainFilter.filter_items(station, [], power, cdom).size() == 1,
		"a compound whose children carry power shows under Power")


func _test_round_trip() -> void:
	var s := {"power": true, "water": true}
	_ok(GraphDomainFilter.from_array(GraphDomainFilter.to_array(s)) == s, "save round trip")
	_ok(GraphDomainFilter.to_array({}).is_empty(), "all saves as []")
	_ok(GraphDomainFilter.describe(GraphDomainFilter.preset("power")) == "Power", "describe")
