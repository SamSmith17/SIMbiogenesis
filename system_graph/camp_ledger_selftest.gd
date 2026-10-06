extends SceneTree

## Headless self-test for festival camps on the graph: CampTemplates stamped
## through GraphComponentDefs, detached, with CampLedger classifying each
## resource loop (closed / importing / surplus / open) per camp and summing
## the festival. Pure / offline. Run --import first.
##   godot --headless --path . --script system_graph/camp_ledger_selftest.gd

const EXPECTED_CHECKS := 24
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_template_stamps()
	_test_ledger_classification()
	_test_festival_sum()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("CAMP LEDGER SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CAMP LEDGER SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _stamp(model, style: String, n: int, pos: Vector2, lot_id: String) -> String:
	var def := CampTemplates.definition(style, n)
	model.put_definition(def)
	var cid: String = GraphComponentDefs.realize(model, str(def["id"]), "root", pos,
		{"camp_lot_id": lot_id, "camp_headcount": n, "name": "Camp %s" % lot_id})
	GraphComponentDefs.make_unique(model, cid)
	return cid


func _child(model, cid: String, role_or_kind: String) -> Dictionary:
	var scope := str(model.get_item(cid).get("child_scope_id", ""))
	for it in model.get_items_in_scope(scope):
		var specs: Dictionary = (it as Dictionary).get("specs", {})
		if str(specs.get("role", "")) == role_or_kind or str(specs.get("resource_kind", "")) == role_or_kind:
			return it
	return {}


func _test_template_stamps() -> void:
	var model = GraphModelScript.new()
	var cid := _stamp(model, "theme_camp", 24, Vector2(0, 0), "lot_1")
	_check("a camp stamps as a compound", not cid.is_empty()
		and str(model.get_item(cid).get("type", "")) == "compound")
	var inst: Dictionary = model.get_item(cid)
	_check("the camp is DETACHED (no definition_id)", not GraphComponentDefs.is_instance(inst))
	_check("identity rides the compound", str(inst["specs"].get("camp_lot_id", "")) == "lot_1"
		and int(inst["specs"].get("camp_headcount", 0)) == 24)
	var hab := _child(model, cid, "habitat")
	_check("the habitat is pop-driven with the headcount", not hab.is_empty()
		and bool(hab["specs"].get("pop_driven", false)) and int(hab["specs"].get("occupants", 0)) == 24)
	var water := _child(model, cid, "water")
	_check("stores scale with the headcount", absf(float(water["specs"].get("capacity_qty", 0.0))
		- CampTemplates.WATER_L_PER_PERSON * 24.0) < 1e-6)
	var handles: Array = inst.get("handles", [])
	_check("five boundary ports promoted (3 in, 2 out)", handles.size() == 5
		and int(inst["specs"].get("port_in_count", 0)) == 3 and int(inst["specs"].get("port_out_count", 0)) == 2,
		"handles=%d" % handles.size())
	var flat := GraphNesting.flat_connections(model)
	_check("interior wires resolve (habitat fed from the tanks)", flat.size() == 5, "flat=%d" % flat.size())
	var ports := CampLedger.boundary_ports(model, cid)
	_check("no boundary port is wired yet", ports.size() == 5 and not bool(ports["water_in"]["wired"]))
	_check("stamping two camps yields two independent compounds",
		_stamp(model, "rv_park", 10, Vector2(400, 0), "lot_2") != cid
		and model.get_items_in_scope("root").size() == 2)


func _test_ledger_classification() -> void:
	var model = GraphModelScript.new()
	var cid := _stamp(model, "mixed", 20, Vector2(0, 0), "lot_1")
	var scope := str(model.get_item(cid).get("child_scope_id", ""))
	var led := CampLedger.compute(model, scope)
	var rows: Dictionary = led["kinds"]
	_check("water: demanded, not made, not imported → OPEN", str(rows["water"]["status"]) == CampLedger.STATUS_OPEN)
	_check("water demand = 2.083 L/h × 20", absf(float(rows["water"]["demand"]) - 2.083 * 20.0) < 1e-6)
	_check("water runs out in two days", absf(float(rows["water"]["days_to_empty"]) - 2000.0 / (2.083 * 20.0 * 24.0)) < 1e-6,
		"days=%.3f" % float(rows["water"]["days_to_empty"]))
	_check("greywater: made, nobody takes it → SURPLUS", str(rows["greywater"]["status"]) == CampLedger.STATUS_SURPLUS
		and float(rows["greywater"]["days_to_full"]) < INF)
	_check("biomass: scraps made, firewood eaten at 0 → SURPLUS, but not a festival-level open loop",
		str(rows["biomass"]["status"]) == CampLedger.STATUS_SURPLUS and not (led["open"] as Array).has("biomass"),
		"status=%s" % str(rows["biomass"]["status"]))
	_check("open kinds = the badge", led["open"] == ["blackwater", "food", "greywater", "water"], str(led["open"]))
	# Live demand overrides the nominal rate for a pop-driven habitat.
	var hab := _child(model, cid, "habitat")
	var led2 := CampLedger.compute(model, scope, {str(hab["id"]): {"water": 10.0, "food": 0.0}})
	_check("a live demand override replaces the nominal rate",
		absf(float(led2["kinds"]["water"]["demand"]) - 10.0) < 1e-6
		and str(led2["kinds"]["food"]["status"]) == CampLedger.STATUS_IDLE)
	# Wire a Water Truck at root into the camp's water_in port: importing.
	model.add_item({"id": "truck", "type": "processor", "x": -300.0, "y": 0.0, "scope_id": "root",
		"specs": {"name": "Water Truck", "role": "import", "counts_as_import": true,
			"inputs": [], "outputs": [{"kind": "water", "rate": 200.0, "unit": "L/h"}]}})
	model.add_connection({"polarity": "resource", "resource_type": "water",
		"source_item_id": "truck", "source_handle_id": "res_out_0",
		"target_item_id": cid, "target_handle_id": "water_in"})
	var ports := CampLedger.boundary_ports(model, cid)
	_check("the wired port reads wired", bool(ports["water_in"]["wired"]))
	var open := CampLedger.open_kinds(model, cid)
	_check("a wired open loop leaves the badge", not open.has("water") and open.has("food"), str(open))
	# The import inside the camp's own scope reads as IMPORTING.
	var cid2 := _stamp(model, "mixed", 8, Vector2(500, 0), "lot_2")
	var scope2 := str(model.get_item(cid2).get("child_scope_id", ""))
	model.add_item({"id": "truck2", "type": "processor", "x": 0.0, "y": -400.0, "scope_id": scope2,
		"specs": {"name": "Water Delivery", "role": "import", "counts_as_import": true,
			"inputs": [], "outputs": [{"kind": "water", "rate": 50.0, "unit": "L/h"}]}})
	var led3 := CampLedger.compute(model, scope2)
	_check("an import inside the scope → IMPORTING", str(led3["kinds"]["water"]["status"]) == CampLedger.STATUS_IMPORTING
		and float(led3["kinds"]["water"]["net"]) > 0.0)


func _test_festival_sum() -> void:
	var model = GraphModelScript.new()
	_stamp(model, "mixed", 20, Vector2(0, 0), "lot_1")
	_stamp(model, "theme_camp", 30, Vector2(400, 0), "lot_2")
	model.add_item({"id": "shed", "type": "resource", "x": 900.0, "y": 0.0, "scope_id": "root",
		"specs": {"name": "Depot", "resource_kind": "water", "capacity_qty": 10000.0,
			"capacity_unit": "L", "level": 1.0}})
	var fest := CampLedger.festival(model)
	_check("two camps listed", (fest["camps"] as Array).size() == 2)
	_check("people summed from the compounds", int(fest["people"]) == 50)
	var water: Dictionary = fest["totals"]["water"]
	_check("festival water demand is the sum", absf(float(water["demand"]) - 2.083 * 50.0) < 1e-6)
	_check("festival stock sums the camps' stores (not root depots)",
		absf(float(water["stock"]) - CampTemplates.WATER_L_PER_PERSON * 50.0) < 1e-6)
	_check("each camp reports its open loops", ((fest["camps"] as Array)[0]["open"] as Array).has("water"))
