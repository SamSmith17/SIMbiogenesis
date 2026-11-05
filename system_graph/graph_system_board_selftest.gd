extends SceneTree

## Headless self-test for the Festival board's data (GraphSystemBoard) and
## the alerts rail's latch (GraphSystemAlerts), plans/GRAPH_SYSTEMS_UX_PLAN.md
## Phase 3. Pure / offline. Run --import first.
##   godot --headless --path . --script system_graph/graph_system_board_selftest.gd

const EXPECTED_CHECKS := 46

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_rows()
	_test_sort_filter_totals()
	_test_overlays()
	_test_alerts()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("GRAPH SYSTEM BOARD SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("GRAPH SYSTEM BOARD SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _camp(id: String, name: String, people: int, morale: float, ac: bool, soc: float,
		open: Array = []) -> Dictionary:
	return {"id": id, "type": "compound", "child_scope_id": "s_" + id,
		"specs": {"camp_lot_id": "lot_" + id, "name": name, "camp_present": people,
			"camp_headcount": people, "camp_morale": morale, "camp_ac": ac, "camp_soc": soc,
			"battery_kwh": 10.0, "camp_open": open}}


func _ledger(water_stock: float, water_demand_h: float, food_days: float = INF) -> Dictionary:
	var k := {}
	if water_stock >= 0.0:
		k["water"] = {"stock": water_stock, "capacity": 1000.0, "unit": "L",
			"days_to_empty": water_stock / (water_demand_h * 24.0) if water_demand_h > 0.0 else INF,
			"days_to_full": INF, "status": "importing"}
	if is_finite(food_days):
		k["food"] = {"stock": 10.0, "capacity": 50.0, "unit": "kg",
			"days_to_empty": food_days, "days_to_full": INF, "status": "importing"}
	return {"kinds": k, "open": []}


func _test_rows() -> void:
	var good := GraphSystemBoard.row(_camp("a", "Camp A", 12, 0.8, true, 0.7), {}, _ledger(900.0, 2.0))
	_check("camp row kind / name / people", good["kind"] == "camp" and good["name"] == "Camp A" and int(good["people"]) == 12)
	_check("camp soc from the stamped camp_soc", is_equal_approx(float(good["soc"]), 0.7))
	_check("a healthy camp is ok", str(good["level"]) == "ok", str(good["reasons"]))
	_check("water days from the ledger", is_equal_approx(float(good["water_days"]), 900.0 / 48.0))
	_check("stores listed", (good["stores"] as Array).size() == 1)
	var dark := GraphSystemBoard.row(_camp("b", "Camp B", 8, 0.8, false, 0.05), {}, _ledger(900.0, 2.0))
	_check("no power is critical", str(dark["level"]) == "crit" and (dark["reasons"] as Array).has("no power"))
	var dry := GraphSystemBoard.row(_camp("c", "Camp C", 8, 0.8, true, 0.7), {}, _ledger(20.0, 2.0))
	_check("under a day of water is critical", str(dry["level"]) == "crit", str(dry["reasons"]))
	_check("the reason says hours", str((dry["reasons"] as Array)[0]).ends_with("h left"), str(dry["reasons"]))
	var low := GraphSystemBoard.row(_camp("d", "Camp D", 8, 0.8, true, 0.1), {}, _ledger(900.0, 2.0))
	_check("a low battery warns", str(low["level"]) == "warn")
	var sad := GraphSystemBoard.row(_camp("e", "Camp E", 8, 0.3, true, 0.7), {}, _ledger(900.0, 2.0))
	_check("low morale is critical", str(sad["level"]) == "crit")
	var open := GraphSystemBoard.row(_camp("f", "Camp F", 8, 0.8, true, 0.7, ["food"]), {}, _ledger(900.0, 2.0))
	_check("an open loop with nothing stored warns and is named", str(open["level"]) == "warn" and str(open["reasons"]).contains("food"))
	var covered := GraphSystemBoard.row(_camp("h", "Camp H", 8, 0.8, true, 0.7, ["water"]), {}, _ledger(900.0, 2.0))
	_check("an open loop covered by a week of stores is fine", str(covered["level"]) == "ok", str(covered["reasons"]))
	var lk := _ledger(900.0, 2.0)
	(lk["kinds"] as Dictionary)["blackwater"] = {"stock": 190.0, "capacity": 200.0, "unit": "L",
		"days_to_empty": INF, "days_to_full": 0.2, "status": "surplus"}
	var full := GraphSystemBoard.row(_camp("i", "Camp I", 8, 0.8, true, 0.7), {}, lk)
	_check("a waste tank nearly full is critical", str(full["level"]) == "crit" and str(full["reasons"]).contains("blackwater full"), str(full["reasons"]))
	_check("crit outranks warn on attention", float(dry["attention"]) > float(low["attention"]))
	# Live power state wins over the stamped keys.
	var live := GraphSystemBoard.row(_camp("g", "Camp G", 8, 0.8, true, 0.7),
		{"soc_kwh": 1.0, "pv_kw": 0.0, "load_kw": 0.5, "ac_available": true, "hours_left": 2.0}, {})
	_check("live soc from the power state", is_equal_approx(float(live["soc"]), 0.1))
	_check("hours left from the power state", is_equal_approx(float(live["hours_left"]), 2.0))
	# A vehicle row.
	var veh_item := {"id": "v", "type": "compound", "child_scope_id": "s_v",
		"specs": {"vehicle_prop_id": "prop_1", "name": "Tool Bus"}}
	var veh := GraphSystemBoard.row(veh_item, {"soc_kwh": 4.0, "cap_kwh": 8.0, "pv_kw": 0.4,
		"load_kw": 0.1, "ac_available": true}, {})
	_check("vehicle row", veh["kind"] == "vehicle" and is_equal_approx(float(veh["soc"]), 0.5) and str(veh["level"]) == "ok")
	# The site's own system.
	var site := GraphSystemBoard.row({}, {}, {}, {"name": "Your system", "soc": 0.6, "kwh": 12.0,
		"cap_kwh": 20.0, "pv_kw": 0.0, "load_kw": 2.0, "ac": true})
	_check("site row", site["kind"] == "site" and is_equal_approx(float(site["hours_left"]), 6.0))
	_check("fmt_days", GraphSystemBoard.fmt_days(INF) == "lasting" and GraphSystemBoard.fmt_days(2.04) == "2.0 days")
	_check("fmt_full", GraphSystemBoard.fmt_full(0.0) == "full now" and GraphSystemBoard.fmt_full(0.2) == "full in 5 h"
		and GraphSystemBoard.fmt_full(INF) == "room to spare")


func _rows() -> Array:
	return [
		GraphSystemBoard.row(_camp("a", "Camp A", 12, 0.8, true, 0.7), {}, _ledger(900.0, 2.0)),
		GraphSystemBoard.row(_camp("b", "Camp B", 8, 0.8, false, 0.05), {}, _ledger(900.0, 2.0)),
		GraphSystemBoard.row(_camp("c", "Camp C", 4, 0.8, true, 0.7), {}, _ledger(20.0, 2.0)),
		GraphSystemBoard.row(_camp("d", "Camp D", 6, 0.8, true, 0.1), {}, _ledger(900.0, 2.0)),
		GraphSystemBoard.row({"id": "v", "type": "compound", "child_scope_id": "s_v",
			"specs": {"vehicle_prop_id": "p", "name": "Bus"}}, {"soc_kwh": 4.0, "cap_kwh": 8.0,
			"ac_available": true}, {}),
	]


func _test_sort_filter_totals() -> void:
	var rows := _rows()
	var by_att := GraphSystemBoard.sorted(rows, "attention")
	_check("attention puts the critical first", str((by_att[0] as Dictionary)["level"]) == "crit"
		and str((by_att[by_att.size() - 1] as Dictionary)["level"]) == "ok")
	var by_name := GraphSystemBoard.sorted(rows, "name", false)
	_check("name ascending", str((by_name[0] as Dictionary)["name"]) == "Bus")
	var by_people := GraphSystemBoard.sorted(rows, "people")
	_check("people descending", int((by_people[0] as Dictionary)["people"]) == 12)
	var by_water := GraphSystemBoard.sorted(rows, "water", false)
	_check("water ascending: no-data first, then the driest",
		str((by_water[0] as Dictionary)["id"]) == "v" and str((by_water[1] as Dictionary)["id"]) == "c")
	_check("filter attention", GraphSystemBoard.filtered(rows, "attention").size() == 3)
	_check("filter vehicles", GraphSystemBoard.filtered(rows, "vehicle").size() == 1)
	_check("filter all", GraphSystemBoard.filtered(rows, "all").size() == 5)
	var t := GraphSystemBoard.totals(rows)
	_check("totals count", int(t["systems"]) == 5 and int(t["camps"]) == 4 and int(t["vehicles"]) == 1)
	_check("totals people + levels", int(t["people"]) == 30 and int(t["crit"]) == 2 and int(t["warn"]) == 1)
	_check("totals power + short water", int(t["no_power"]) == 1 and int(t["short_water"]) == 1)


func _test_overlays() -> void:
	var rows := _rows()
	var a: Dictionary = rows[0]
	_check("soc overlay value", is_equal_approx(GraphSystemBoard.overlay_value(a, "soc"), 0.7))
	_check("soc bins", GraphSystemBoard.overlay_bin("soc", 0.1) == 0 and GraphSystemBoard.overlay_bin("soc", 0.9) == 3)
	_check("water bins", GraphSystemBoard.overlay_bin("water", 0.4) == 0 and GraphSystemBoard.overlay_bin("water", INF) == 3)
	_check("no data is NAN and bin -1", is_nan(GraphSystemBoard.overlay_value(rows[4], "water"))
		and GraphSystemBoard.overlay_bin("water", NAN) == -1)
	_check("margin: no power is the worst bin", GraphSystemBoard.overlay_bin("margin",
		GraphSystemBoard.overlay_value(rows[1], "margin")) == 0)
	_check("legend has four bins", GraphSystemBoard.legend("morale").size() == 4)
	_check("overlay_values keyed by id", GraphSystemBoard.overlay_values(rows, "soc").size() == 5
		and GraphSystemBoard.overlay_values(rows, "none").is_empty())


func _row(id: String, level: String, reason: String = "x") -> Dictionary:
	return {"id": id, "name": id, "kind": "camp", "level": level, "reasons": [reason]}


func _test_alerts() -> void:
	var al := GraphSystemAlerts.new()
	# First sight: a warn baseline is not news; a critical one is.
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "ok")], 0.0)
	_check("nothing shown before the hold", al.entries().is_empty())
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "ok")], 3.0)
	var e := al.entries()
	_check("a critical system is shown after the hold", e.size() == 1 and str((e[0] as Dictionary)["id"]) == "b")
	# c goes bad: shown only after HOLD_S, newest first.
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "warn")], 4.0)
	_check("a fresh warning waits for the hold", al.entries().size() == 1)
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "warn")], 6.5)
	e = al.entries()
	_check("then it is shown, newest first", e.size() == 2 and str((e[0] as Dictionary)["id"]) == "c")
	# A flicker back to ok and bad again does not strobe the entry.
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "ok")], 7.0)
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "warn")], 8.0)
	_check("a short recovery keeps the entry", al.entries().size() == 2)
	# Recovering for CLEAR_S drops it.
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "ok")], 9.0)
	al.update([_row("a", "warn"), _row("b", "crit"), _row("c", "ok")], 15.0)
	_check("a lasting recovery clears the entry", al.entries().size() == 1)
	# The baseline warning that gets worse is news.
	al.update([_row("a", "crit"), _row("b", "crit"), _row("c", "ok")], 16.0)
	al.update([_row("a", "crit"), _row("b", "crit"), _row("c", "ok")], 19.0)
	_check("a baseline warning that turns critical is shown", al.entries().size() == 2)
	# Dismiss: gone until it gets worse (it cannot, it is critical).
	al.dismiss("b")
	al.update([_row("a", "crit"), _row("b", "crit"), _row("c", "ok")], 25.0)
	_check("a dismissed entry stays dismissed", al.entries().size() == 1)
	# A system that disappears drops its entry.
	al.update([_row("b", "crit"), _row("c", "ok")], 26.0)
	_check("a removed system leaves the rail", al.entries().is_empty())
