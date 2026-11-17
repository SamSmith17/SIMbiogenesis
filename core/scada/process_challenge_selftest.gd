extends SceneTree
## Challenge conditions on tags and alarms (SCADA plan, Phase 9), offline:
##   Godot --headless --path . --script core/scada/process_challenge_selftest.gd

const EXPECTED_CHECKS := 18

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _initialize() -> void:
	var rules := [{"id": "a1", "tag": "tank.t1.level", "op": ">=", "enabled": true}, {"id": "a2", "tag": "tank.t1.level", "op": "<=", "enabled": true},
		{"id": "a3", "tag": "tank.t2.level", "op": ">=", "enabled": false}, {"id": "a4", "tag": "sensor.battery_level", "op": "<=", "enabled": true}]
	_check(ProcessChallenge.watched_tags(rules) == ["tank.t1.level"], "watched stores: each tank an enabled rule reads, once")
	_check(ProcessChallenge.gate({"min_alarm_rules": 2}, rules) == "" and ProcessChallenge.gate({"min_alarm_rules": 4}, rules) == "process_no_alarms", "the gate counts enabled rules")
	_check(ProcessChallenge.gate({}, []) == "", "no gate asked for, none applied")
	var cfg := {"max_unacked_alarm_h": 0.5, "watch_lo": 10.0, "watch_hi": 95.0, "watch_grace_h": 0.25, "max_in_alarm_h": 3.0}
	var lv := [50.0]
	var read := func(_t: String) -> float: return lv[0]
	var st := {}
	var normal := {"a1": {"state": "normal", "active": false}}
	var r := ProcessChallenge.step(st, cfg, rules, normal, read, 0.1)
	_check(str(r["fail"]) == "" and str(r["note"]) == "", "a quiet plant: nothing to say")
	# An alarm left flashing.
	var unack := {"a1": {"state": "unack", "active": true}}
	st = r["state"]
	for i in 5:
		r = ProcessChallenge.step(st, cfg, rules, unack, read, 0.1)
		st = r["state"]
	_check(str(r["fail"]) == "" and str(r["note"]).contains("1 alarm"), "0.5 h unacknowledged is still inside the limit, and the note says one is waiting")
	r = ProcessChallenge.step(st, cfg, rules, unack, read, 0.1)
	_check(str(r["fail"]) == "process_alarm_ignored", "past 0.5 h it fails as ignored")
	# Acknowledged in time: the timer goes back to zero.
	st = {}
	for i in 4:
		st = ProcessChallenge.step(st, cfg, rules, unack, read, 0.1)["state"]
	var acked := {"a1": {"state": "acked", "active": true}}
	st = ProcessChallenge.step(st, cfg, rules, acked, read, 0.1)["state"]
	_check((st["unack"] as Dictionary).is_empty(), "acknowledging clears its timer")
	for i in 4:
		r = ProcessChallenge.step(st, cfg, rules, unack, read, 0.1)
		st = r["state"]
	_check(str(r["fail"]) == "", "a second 0.4 h unacknowledged does not add to the first")
	_check(absf(float(st["in_alarm_h"]) - 0.9) < 1e-6, "hours in alarm add up across both (%.2f)" % float(st["in_alarm_h"]))
	# Too long in alarm overall.
	for i in 30:
		r = ProcessChallenge.step(st, cfg, rules, acked, read, 0.1)
		st = r["state"]
	_check(str(r["fail"]) == "process_in_alarm", "3 h in alarm in all fails")
	# A watched store outside its band.
	st = {}
	lv[0] = 97.0
	r = ProcessChallenge.step(st, cfg, rules, normal, read, 0.2)
	st = r["state"]
	_check(str(r["fail"]) == "" and str(r["note"]).contains("1 store"), "a store over its limit for 0.2 h is inside the grace, and noted")
	r = ProcessChallenge.step(st, cfg, rules, normal, read, 0.1)
	_check(str(r["fail"]) == "process_store_out", "past the grace it fails")
	st = {}
	st = ProcessChallenge.step(st, cfg, rules, normal, read, 0.2)["state"]
	lv[0] = 60.0
	st = ProcessChallenge.step(st, cfg, rules, normal, read, 0.1)["state"]
	_check((st["out"] as Dictionary).is_empty(), "back inside the band clears its timer")
	lv[0] = 5.0
	r = ProcessChallenge.step(st, cfg, rules, normal, read, 0.3)
	_check(str(r["fail"]) == "process_store_out", "below the low limit counts too")
	# A jump is not judged.
	st = {}
	lv[0] = 50.0
	r = ProcessChallenge.step(st, cfg, rules, unack, read, 9.0)
	_check(str(r["fail"]) == "" and float((r["state"]["unack"] as Dictionary)["a1"]) <= 0.5, "a 9 h jump counts as half an hour at most")
	_check(ProcessChallenge.is_reason("process_store_out") and not ProcessChallenge.is_reason("ac_down") and ChallengeDef.reason_label("process_alarm_ignored").contains("acknowledged"), "its reasons have words (through ChallengeDef too)")
	var def := ChallengeCatalog.by_id("operators_watch")
	_check(def != null and int(def.process.get("min_alarm_rules", 0)) == 2 and not def.is_prebake(), "the catalog's Operator's Watch carries its conditions")
	_check(ChallengeDef.from_dict(def.to_dict()).process == def.process and ChallengeDef.from_dict({"id": "x"}).process.is_empty(), "the conditions survive a round trip; other challenges have none")
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: expected %d checks, ran %d" % [EXPECTED_CHECKS, _checks])
	print("PROCESS CHALLENGE SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAILED", _checks, _fails])
	quit(0 if _fails == 0 else 1)
