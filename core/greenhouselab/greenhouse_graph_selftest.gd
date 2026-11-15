extends SceneTree

## A greenhouse on the graph (offline):
##   Godot --headless --path . --script core/greenhouselab/greenhouse_graph_selftest.gd
## The definition: a bed node per bed bound to its prop, lit beds' lamps,
## fans / vents / heater on a panel, barrels, roof catchment into the tank,
## harvest + residue stores, four ports. Realized: one compound, its children
## by role. The engine: a cold night turns the heater load on and keeps the
## inside above outside; a hot sunny day turns the fans on; the beds grow from
## the inside climate (a bed takes the inside temperature); the roof fills the
## tank in rain; packed, nothing runs; a scrub back holds the state.

const EXPECTED_CHECKS := 19
const FlowEngine := preload("res://system_graph/resource_flow_engine.gd")

var _n := 0
var _fails := 0


func _ok(c: bool, what: String) -> void:
	_n += 1
	if not c:
		_fails += 1
	print("%s: %s" % ["PASS" if c else "FAIL", what])


func _initialize() -> void:
	_test_definition()
	_test_engine()
	_test_ports()
	if _n != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
		_fails += 1
	print("GREENHOUSE GRAPH SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _spec() -> Dictionary:
	var s: Dictionary = GreenhousePresets.builtin("gable_pc")["spec"].duplicate(true)
	s["heater"] = "electric_5000"
	s["fans"] = {"kind": "fan_24", "count": 1}
	s["lights"]["on"] = true
	s["beds"]["lights"] = true
	s["mass"]["barrels"] = 4
	s["rain"]["gutters"] = true
	s["rain"]["cistern_l"] = 600.0
	return s


func _test_definition() -> void:
	var d := GreenhouseDesign.solve(_spec())
	var parts := {"bed:%s" % str(d["beds"][0]["id"]): "prop_b0"}
	var def := GreenhouseGraph.definition(d, "greenhouse_t", parts)
	var items: Array = def["subgraph"]["items"]
	var roles := {}
	var bound_bed := false
	for it in items:
		var sp: Dictionary = (it as Dictionary)["specs"]
		var r := str(sp.get(GreenhouseGraph.ROLE_KEY, ""))
		roles[r] = int(roles.get(r, 0)) + 1
		if r == "bed" and str(sp.get("bound_prop_id", "")) == "prop_b0":
			bound_bed = true
	_ok(int(roles.get("bed", 0)) == (d["beds"] as Array).size() and bound_bed, "a bed node per bed (%d), bound to its prop" % int(roles.get("bed", 0)))
	_ok(int(roles.get("lights", 0)) > 0 and roles.has("fans") and roles.has("heater") and roles.has("vents"),
		"lamps, fans, heater and vent motors are loads inside")
	_ok(roles.has("barrels") and roles.has("roof") and roles.has("tank") and roles.has("harvest") and roles.has("residue"),
		"barrels, roof catchment, tank, harvest and residue stores")
	var hids := []
	for e in def["subgraph"]["exposed_ports"]:
		hids.append(str((e as Dictionary)["handle_id"]))
	hids.sort()
	_ok(hids == ["ac_in", "biomass_out", "food_out", "water_in"], "four ports: %s" % str(hids))
	var sf := _spec()
	sf["beds"]["feed"] = true
	var dff := GreenhouseGraph.definition(GreenhouseDesign.solve(sf), "greenhouse_f", {})
	var fed := 0
	var has_port := false
	for c in dff["subgraph"]["connections"]:
		if str((c as Dictionary)["target_handle"]) == "nutrients_in":
			fed += 1
	for e in dff["subgraph"]["exposed_ports"]:
		has_port = has_port or str((e as Dictionary)["handle_id"]) == "nutrients_in"
	_ok(has_port and fed == (d["beds"] as Array).size(), "a fed house feeds every bed from a store with a Nutrients in port")
	_ok(GreenhouseGraph.signature(d, parts) == GreenhouseGraph.signature(GreenhouseDesign.solve(_spec()), parts)
		and GreenhouseGraph.signature(d, parts) != GreenhouseGraph.signature(d, {}), "the signature follows the design and its parts")


func _build() -> Dictionary:
	var model := GraphModel.new()
	var d := GreenhouseDesign.solve(_spec())
	var def := GreenhouseGraph.definition(d, "greenhouse_t", {})
	model.put_definition(def)
	var cid := GraphComponentDefs.realize(model, "greenhouse_t", "root", Vector2.ZERO,
		{"greenhouse_prop_id": "gh", "gh_sig": "x", "gh_yaw": 0.0, "gh_spec": GreenhouseSpec.to_json_safe(d["spec"])})
	GraphComponentDefs.make_unique(model, cid)
	# The site's AC into the house.
	model.add_item({"id": "inv", "type": "controller", "scope_id": "root", "specs": {"name": "Inverter"}})
	model.add_connection({"id": "cac", "polarity": "ac", "scope_id": "root", "source_item_id": "inv",
		"source_handle_id": "acOutput", "target_item_id": cid, "target_handle_id": "ac_in"})
	var e = FlowEngine.new()
	e.setup(model, null)
	e.power_available_override = 1
	return {"model": model, "cid": cid, "engine": e}


func _set_weather(e, t: float, rh: float, ghi: float, rain: float = 0.0) -> void:
	e.wind_speed_override_ms = 2.0
	e.wind_temp_override_c = t
	e.wind_humidity_override_pct = rh
	e.wind_cloud_override = 0.1
	e.sun_ghi_override_wm2 = ghi
	e.sun_cloud_override = 0.1
	e.rain_rate_override_mmh = rain


func _run(g: Dictionary, h0: float, hours: float, step: float = 0.25) -> void:
	var h := h0
	while h < h0 + hours - 1e-6:
		h += step
		g["engine"].simulate_step_for_test(h, step)


func _test_engine() -> void:
	var g := _build()
	var model: GraphModel = g["model"]
	var cid := str(g["cid"])
	var e = g["engine"]
	_set_weather(e, -6.0, 80.0, 0.0)
	_run(g, 1000.0, 12.0)
	var sp: Dictionary = model.get_item(cid)["specs"]
	var kids := GreenhouseGraph.children_by_role(model, cid)
	var heater: Dictionary = kids["heater"][0]
	_ok(sp.has("gh_t_air") and float(sp["gh_t_air"]) > -6.0 + 5.0,
		"a cold night: inside %.1f °C vs outside -6 °C" % float(sp.get("gh_t_air", -99.0)))
	_ok(str(heater["specs"].get("requested_state", "")) == "on" and bool(sp.get("gh_heater", false)),
		"the heater load is switched on by the controller")
	var bed: Dictionary = model.get_item(str(kids["bed"][0]["id"]))
	_ok(absf(float(bed["specs"].get("gh_t_air", -99.0)) - float(sp["gh_t_air"])) < 0.2, "a bed reads the inside temperature")
	# A hot, sunny afternoon.
	_set_weather(e, 33.0, 30.0, 900.0)
	_run(g, 1012.0, 6.0)
	sp = model.get_item(cid)["specs"]
	kids = GreenhouseGraph.children_by_role(model, cid)
	_ok(bool(sp.get("gh_fans", false)) and str(kids["fans"][0]["specs"].get("requested_state", "")) == "on",
		"a hot day turns the fans on (inside %.1f °C)" % float(sp.get("gh_t_air", 0.0)))
	_ok(not bool(sp.get("gh_heater", true)) and str(kids["heater"][0]["specs"].get("requested_state", "")) == "off",
		"and the heater off")
	_ok(float(sp.get("gh_vent_pct", 0.0)) > 50.0, "the vents are open (%d %%)" % int(sp.get("gh_vent_pct", 0)))
	# Rain on the roof fills the tank.
	var tank_id := str(kids["tank"][0]["id"])
	var lvl0 := float(model.get_item(tank_id)["specs"]["level"])
	_set_weather(e, 14.0, 95.0, 50.0, 8.0)
	_run(g, 1018.0, 3.0)
	var lvl1 := float(model.get_item(tank_id)["specs"]["level"])
	_ok(lvl1 > lvl0 + 0.01, "rain on the roof fills the tank (%.2f → %.2f)" % [lvl0, lvl1])
	# The beds grow from the lit, warm house.
	var food_id := str(kids["harvest"][0]["id"])
	var f0 := float(model.get_item(food_id)["specs"]["level"])
	_set_weather(e, 18.0, 60.0, 600.0)
	_run(g, 1021.0, 4.0)
	var f1 := float(model.get_item(food_id)["specs"]["level"])
	_ok(f1 > f0, "the beds grow food into the harvest store (%.4f → %.4f)" % [f0, f1])
	# A scrub back holds the climate state.
	var t_before := float(model.get_item(cid)["specs"]["gh_t_air"])
	e.simulate_step_for_test(1010.0, 0.25)
	_ok(absf(float(model.get_item(cid)["specs"]["gh_t_air"]) - t_before) < 1e-3, "a scrub back holds the inside climate")
	var snap: Dictionary = e.internal_state_snapshot()
	_ok(snap.has("gh_state") and (snap["gh_state"] as Dictionary).has(cid), "the climate rides the engine snapshot")
	# Packed: nothing runs.
	var cs: Dictionary = model.get_item(cid)["specs"].duplicate(true)
	cs["packed_3d"] = true
	model.update_item(cid, {"specs": cs})
	var bs: Dictionary = model.get_item(str(kids["bed"][0]["id"]))["specs"].duplicate(true)
	bs["packed_3d"] = true
	model.update_item(str(kids["bed"][0]["id"]), {"specs": bs})
	var f2 := float(model.get_item(food_id)["specs"]["level"])
	_run(g, 1030.0, 2.0)
	_ok(not e._gh_climate.has(cid), "a packed house runs no climate")


## What is wired to its ports: a water store tops its tank up, its harvest
## leaves for a pantry.
func _test_ports() -> void:
	var g := _build()
	var model: GraphModel = g["model"]
	var cid := str(g["cid"])
	var e = g["engine"]
	model.add_item({"id": "ext_w", "type": "resource", "scope_id": "root", "specs": {"name": "Reclaimed",
		"resource_kind": "water", "capacity_qty": 5000.0, "capacity_unit": "L", "level": 1.0}})
	model.add_item({"id": "pantry", "type": "resource", "scope_id": "root", "specs": {"name": "Pantry",
		"resource_kind": "food", "capacity_qty": 1000.0, "capacity_unit": "kg", "level": 0.0}})
	model.add_connection({"id": "cw", "polarity": "resource", "resource_type": "water", "scope_id": "root",
		"source_item_id": "ext_w", "source_handle_id": "output", "target_item_id": cid, "target_handle_id": "water_in"})
	model.add_connection({"id": "cf", "polarity": "resource", "resource_type": "food", "scope_id": "root",
		"source_item_id": cid, "source_handle_id": "food_out", "target_item_id": "pantry", "target_handle_id": "input"})
	var kids := GreenhouseGraph.children_by_role(model, cid)
	var tank_id := str(kids["tank"][0]["id"])
	var sp: Dictionary = model.get_item(tank_id)["specs"].duplicate(true)
	sp["level"] = 0.05
	model.update_item(tank_id, {"specs": sp})
	_set_weather(e, 22.0, 60.0, 700.0)
	_run(g, 2000.0, 6.0)
	var lvl := float(model.get_item(tank_id)["specs"]["level"])
	var ext := float(model.get_item("ext_w")["specs"]["level"])
	_ok(lvl > 0.3 and ext < 1.0, "a water store wired to Water in tops the house's tank up (%.2f, store %.3f)" % [lvl, ext])
	var pantry := float(model.get_item("pantry")["specs"]["level"]) * 1000.0
	var crate := float(model.get_item(str(kids["harvest"][0]["id"]))["specs"]["level"]) * 500.0
	_ok(pantry > 0.0 and crate < 0.01, "the harvest leaves for the pantry wired to Food (%.3f kg there, %.4f left)" % [pantry, crate])
