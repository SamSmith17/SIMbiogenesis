extends SceneTree

## Headless self-test for the playability layer: CampProvisioning (rates,
## presets, supply sizing, days remaining, space requirements), PopTestPrefs
## (round trip against a TEMP path; defaults all off), and every guardrail
## the testing switches turn off — the flow engine's IDEAL SUPPLY (a habitat
## with no tanks is not starved; the shortfall is stamped as ideal imports
## and CampLedger reads it as IMPORTING), both tiers meeting a need with NO
## space tagged, the registry's capacity switch, no-departures and the muted
## settlement log. Every switch is reset to defaults between cases, and the
## OFF behaviour is asserted alongside the ON behaviour so a flag that leaks
## would show. Run --import first.
##   godot --headless --path . --script core/population/camp_provisioning_selftest.gd

const EXPECTED_CHECKS := 39
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const ResourceFlowEngineScript := preload("res://system_graph/resource_flow_engine.gd")

var _failures := 0
var _checks := 0


func _init() -> void:
	PopTestPrefs.reset_defaults()
	_test_rates_and_supply()
	_test_requirements()
	_test_prefs_roundtrip()
	_test_engine_ideal_supply()
	_test_ledger_reads_ideal()
	_test_cohort_ideal_no_spaces()
	_test_agent_ideal_no_spaces()
	_test_capacity_and_departures_and_mute()
	PopTestPrefs.reset_defaults()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("CAMP PROVISIONING SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CAMP PROVISIONING SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_rates_and_supply() -> void:
	var r := CampProvisioning.rates_per_hour(24)
	_check("24 people draw 50 L/day each → 50 L/h", absf(float(r["water"]) - 50.0) < 1e-9)
	_check("…and 1.5 kg food/day each → 1.5 kg/h", absf(float(r["food"]) - 1.5) < 1e-9)
	var s := CampProvisioning.supply(20, "weekend")
	_check("weekend water = 50 × 20 × 3 d × 1.25", absf(float(s["water"]["capacity"]) - 3750.0) < 1e-6)
	_check("supplies start full, waste tanks empty", float(s["water"]["stock"]) == float(s["water"]["capacity"])
		and float(s["blackwater"]["stock"]) == 0.0 and float(s["blackwater"]["capacity"]) > 0.0)
	var w := CampProvisioning.supply(20, "week")
	_check("a week stocks more than a weekend", float(w["food"]["capacity"]) > float(s["food"]["capacity"]))
	_check("an unknown preset falls back to weekend",
		CampProvisioning.supply(20, "forever") == CampProvisioning.supply(20, "weekend"))
	_check("presets are listed in order of days", CampProvisioning.PRESET_ORDER == ["bare", "weekend", "week", "fortnight"])
	var days := CampProvisioning.days_remaining({"water": float(s["water"]["stock"]), "food": 15.0}, 20)
	_check("days_remaining is the tightest supply (food 15 kg / 30 kg per day = 0.5 d)", absf(days - 0.5) < 1e-9, "%.3f" % days)
	_check("no stocks → INF", CampProvisioning.days_remaining({}, 20) == INF)
	_check("stock_summary names the days", CampProvisioning.stock_summary({"water": 3750.0}, 20).begins_with("3.8 d of water"))


func _test_requirements() -> void:
	var a := CampProvisioning.requirements(20)
	var b := CampProvisioning.requirements(200)
	_check("requirements scale with people", int(b["restroom_slots"]) > int(a["restroom_slots"])
		and int(b["kitchen_seats"]) > int(a["kitchen_seats"]) and int(b["beds"]) == 200)
	_check("portapotty units = ceil(slots / 2)", int(a["portapotty_units"]) == int(ceil(float(a["restroom_slots"]) / 2.0)))
	_check("zero people need nothing", int(CampProvisioning.requirements(0)["restroom_slots"]) == 0)
	# 316 people: ~1.3 × 316 × (5/60) / 1 h ≈ 35 slots, which is the queue the
	# Walton harness saw with 48 — the number must be in that neighbourhood.
	var w := CampProvisioning.requirements(316)
	_check("316 people need a few dozen restroom slots", int(w["restroom_slots"]) >= 25 and int(w["restroom_slots"]) <= 60, str(w["restroom_slots"]))


func _test_prefs_roundtrip() -> void:
	PopTestPrefs.reset_defaults()
	_check("defaults: every switch off, weekend preset", not PopTestPrefs.any_active()
		and PopTestPrefs.provision_preset() == "weekend")
	var path := "user://_pop_testing_selftest_%d.cfg" % Time.get_ticks_usec()
	PopTestPrefs.set_ideal_supply(true)
	PopTestPrefs.set_no_departures(true)
	PopTestPrefs.set_provision_preset("week")
	PopTestPrefs.save_to(path)
	PopTestPrefs.reset_defaults()
	_check("load_from restores the flags", PopTestPrefs.load_from(path) and PopTestPrefs.ideal_supply()
		and PopTestPrefs.no_departures() and not PopTestPrefs.mute_alarms()
		and PopTestPrefs.provision_preset() == "week")
	_check("ideal supply implies ignore_capacity", PopTestPrefs.ignore_capacity())
	PopTestPrefs.set_provision_preset("nope")
	_check("an unknown preset is refused", PopTestPrefs.provision_preset() == "weekend")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	PopTestPrefs.reset_defaults()


func _bare_habitat_model() -> Dictionary:
	var model = GraphModelScript.new()
	model.add_item({"id": "hab", "type": "processor", "x": 0.0, "y": 0.0, "width": 150.0, "height": 150.0,
		"specs": {"name": "Habitat", "role": "habitat", "occupants": 4, "watts": 0.0, "energy_source": "", "efficiency": 1.0,
			"inputs": [{"kind": "water", "rate": 2.083, "unit": "L/h"}, {"kind": "food", "rate": 0.0625, "unit": "kg/h"}],
			"outputs": [{"kind": "greywater", "rate": 1.666, "unit": "L/h"}, {"kind": "blackwater", "rate": 0.417, "unit": "L/h"}]}})
	var engine = ResourceFlowEngineScript.new()
	engine.setup(model, null)
	return {"model": model, "engine": engine}


func _test_engine_ideal_supply() -> void:
	PopTestPrefs.reset_defaults()
	var g := _bare_habitat_model()
	var engine = g["engine"]
	var model = g["model"]
	engine.simulate_step_for_test(0.0, 0.0)
	engine.simulate_step_for_test(1.0, 1.0)
	var sp: Dictionary = (model.get_item("hab") as Dictionary).get("specs", {})
	_check("OFF: a habitat with no tanks is STARVED on water and food",
		(sp.get("starved_kinds", []) as Array).has("water") and (sp.get("starved_kinds", []) as Array).has("food"))
	PopTestPrefs.set_ideal_supply(true)
	engine.simulate_step_for_test(2.0, 1.0)
	sp = (model.get_item("hab") as Dictionary).get("specs", {})
	var imp: Dictionary = sp.get("ideal_import_rates", {})
	_check("ON: nothing starved", (sp.get("starved_kinds", []) as Array).is_empty())
	_check("ON: the shortfall is stamped as ideal imports at the draw (4 × 2.083 L/h water)",
		absf(float(imp.get("water", 0.0)) - 4.0 * 2.083) < 1e-6 and absf(float(imp.get("food", 0.0)) - 4.0 * 0.0625) < 1e-6, str(imp))
	var exp: Dictionary = sp.get("ideal_export_rates", {})
	_check("ON: waste with no sink is stamped as ideal exports (greywater from the water drawn)",
		float(exp.get("greywater", 0.0)) > 0.0 and float(exp.get("blackwater", 0.0)) > 0.0, str(exp))
	PopTestPrefs.set_ideal_supply(false)
	engine.simulate_step_for_test(3.0, 1.0)
	sp = (model.get_item("hab") as Dictionary).get("specs", {})
	_check("OFF again: the ideal stamps are erased and starvation returns",
		not sp.has("ideal_import_rates") and not (sp.get("starved_kinds", []) as Array).is_empty())
	PopTestPrefs.reset_defaults()


func _test_ledger_reads_ideal() -> void:
	var g := _bare_habitat_model()
	var model = g["model"]
	var sp: Dictionary = (model.get_item("hab") as Dictionary).get("specs", {}).duplicate(true)
	sp["ideal_import_rates"] = {"water": 8.332, "food": 0.25}
	sp["ideal_export_rates"] = {"greywater": 6.6, "blackwater": 1.6}
	model.update_item("hab", {"specs": sp})
	var led := CampLedger.compute(model, "root")
	var rows: Dictionary = led["kinds"]
	_check("ledger: an ideal import makes water IMPORTING, not open",
		str(rows["water"]["status"]) == CampLedger.STATUS_IMPORTING and not (led["open"] as Array).has("water"))
	_check("ledger: an ideal export makes greywater EXPORTING and drops it off the badge",
		str(rows["greywater"]["status"]) == CampLedger.STATUS_EXPORTING and not (led["open"] as Array).has("greywater"), str(rows["greywater"]["status"]))


func _test_cohort_ideal_no_spaces() -> void:
	PopTestPrefs.reset_defaults()
	var reg := SpaceRegistry.new()   # NOTHING tagged
	var run := func() -> Dictionary:
		var c := CrowdCohort.new()
		c.configure(16, "ideal_hab", Vector2.ZERO)
		var t := 10.0
		var totals := {}
		var peak_blocked := 0
		c.tick(t, {"registry": reg, "hour_of_day": 10.0, "abs_hours": t})
		for i in 240:
			t += 0.1
			var d := c.tick(t, {"registry": reg, "hour_of_day": fposmod(t, 24.0), "abs_hours": t})
			for k in d:
				totals[k] = float(totals.get(k, 0.0)) + float(d[k]) * 0.1
			if i % 10 == 0:
				# Sampled DURING the run: with everything blocked the guarded
				# camp walks out before the day ends and the final summary
				# is of an empty roster.
				var bs: Dictionary = c.summary()["blocked"]
				var nb := 0
				for k2 in bs:
					nb += int(bs[k2])
				peak_blocked = maxi(peak_blocked, nb)
		var s := c.summary()
		return {"blocked": peak_blocked, "water": float(totals.get("water", 0.0)),
			"morale": float(s["mean_morale"]), "count": int(s["count"])}
	var off: Dictionary = run.call()
	PopTestPrefs.set_ideal_supply(true)
	var on: Dictionary = run.call()
	PopTestPrefs.reset_defaults()
	_check("light tier OFF: with nothing tagged needs are blocked", int(off["blocked"]) > 0, str(off))
	_check("light tier ON: nothing blocked over a day with nothing tagged", int(on["blocked"]) == 0, str(on))
	_check("light tier ON: the people still consume (water billed > 0)", float(on["water"]) > 0.0, "%.1f L" % float(on["water"]))
	_check("light tier ON: everyone is still there with decent morale (the guarded camp walked out)",
		int(on["count"]) == 16 and float(on["morale"]) >= 0.5, "on=%s off=%s" % [str(on), str(off)])


func _test_agent_ideal_no_spaces() -> void:
	PopTestPrefs.reset_defaults()
	var reg := SpaceRegistry.new()
	var pos_of := func(_space: Dictionary) -> Variant: return Vector2.ZERO
	var run := func() -> Dictionary:
		var e := NpcPopulationEngine.new()
		e.configure(6, "ideal_full", Vector2.ZERO)
		var t := 10.0
		var water := 0.0
		var peak_blocked := 0
		for i in 1440:   # a day in 1-minute steps
			t += 1.0 / 60.0
			var d := e.tick(t, {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t, 24.0)})
			water += float(d.get("water", 0.0)) / 60.0
			if i % 60 == 0:
				var bs: Dictionary = e.summary()["blocked"]
				var nb := 0
				for k2 in bs:
					nb += int(bs[k2])
				peak_blocked = maxi(peak_blocked, nb)
		var s := e.summary()
		return {"blocked": peak_blocked, "water": water, "morale": float(s["mean_morale"]), "count": e.agents.size()}
	var off: Dictionary = run.call()
	PopTestPrefs.set_ideal_supply(true)
	var on: Dictionary = run.call()
	PopTestPrefs.reset_defaults()
	_check("full tier OFF: with nothing tagged needs are blocked", int(off["blocked"]) > 0, str(off))
	_check("full tier ON: nothing blocked over a day with nothing tagged", int(on["blocked"]) == 0, str(on))
	_check("full tier ON: the people still consume", float(on["water"]) > 0.0, "%.1f L" % float(on["water"]))
	_check("full tier ON: everyone is still there with decent morale", int(on["count"]) == 6 and float(on["morale"]) >= 0.5,
		"on=%s off=%s" % [str(on), str(off)])


func _test_capacity_and_departures_and_mute() -> void:
	PopTestPrefs.reset_defaults()
	var reg := SpaceRegistry.new()
	var sid: String = reg.set_space_type({"kind": "area", "poly": [[-2, -2], [2, -2], [2, 2], [-2, 2]]}, "restroom", 1)
	_check("capacity 1: the second claim is refused", reg.claim(sid, "a") and not reg.claim(sid, "b"))
	reg.ignore_capacity = true
	_check("ignore_capacity: the second claim succeeds", reg.claim(sid, "b"))
	reg.ignore_capacity = false
	# Departures: an agent at the quit threshold leaves normally, stays under the switch.
	var e := NpcPopulationEngine.new()
	e.configure(4, "quit_hab", Vector2.ZERO)
	for a in e.agents:
		(a as NpcAgent).quit_pressure = NpcMorale.QUIT_PRESSURE_H + 1.0
	PopTestPrefs.set_no_departures(true)
	e.tick(10.0, {"registry": reg, "pos_of": func(_s: Dictionary) -> Variant: return Vector2.ZERO, "hour_of_day": 10.0})
	e.tick(10.25, {"registry": reg, "pos_of": func(_s: Dictionary) -> Variant: return Vector2.ZERO, "hour_of_day": 10.25})
	_check("no_departures: everyone at the quit threshold stays", e.agents.size() == 4, "%d left" % e.agents.size())
	PopTestPrefs.set_no_departures(false)
	e.tick(10.5, {"registry": reg, "pos_of": func(_s: Dictionary) -> Variant: return Vector2.ZERO, "hour_of_day": 10.5})
	_check("switch off: they leave", e.agents.size() < 4, "%d left" % e.agents.size())
	# Mute: the log records nothing while muted, everything after.
	var lg := SettlementLog.new()
	PopTestPrefs.set_mute_alarms(true)
	lg.add("departed", "muted line", 10.0)
	_check("mute_alarms: nothing recorded", lg.recent(10).is_empty())
	PopTestPrefs.set_mute_alarms(false)
	lg.add("departed", "live line", 10.0)
	_check("unmuted: recorded again", lg.recent(10).size() == 1)
	PopTestPrefs.reset_defaults()
