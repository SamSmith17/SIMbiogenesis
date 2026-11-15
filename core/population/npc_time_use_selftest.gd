extends SceneTree

## Time use (NPC life pass, Phase 9): NpcTimeUse's category mappings for both
## tiers, the tick accounting (first tick, jump, scrub back), the summary
## (hours scaled to a day, part days, per person, ATUS groups), whole-session
## totals, the verdicts and the rota demand. Offline. Carries EXPECTED_CHECKS.
##
##   Godot --headless --path . --script core/population/npc_time_use_selftest.gd

const EXPECTED_CHECKS := 19

var _checks := 0
var _failed := 0


func _initialize() -> void:
	print("NPC TIME USE SELFTEST")
	_test_mappings()
	_test_accounting()
	_test_summary()
	_test_complete_days()
	_test_verdicts()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failed == 0:
		print("NPC TIME USE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("NPC TIME USE SELFTEST FAIL  (%d of %d checks failed)" % [_failed, _checks])
	quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s  %s" % [label, detail])
		print("  FAIL: %s  %s" % [label, detail])


func _test_mappings() -> void:
	var D := NpcAgent.State.DOING
	_check("full tier: each activity to its category",
		NpcTimeUse.category_full(D, "sleep") == "sleep"
		and NpcTimeUse.category_full(D, "bladder") == "toilet"
		and NpcTimeUse.category_full(D, NpcAgent.CHORE_ACTIVITY) == "work"
		and NpcTimeUse.category_full(D, NpcAgent.QUEUE_ACTIVITY) == "queue"
		and NpcTimeUse.category_full(D, NpcSocial.ACTIVITY) == "social"
		and NpcTimeUse.category_full(D, "enrichment") == "venue"
		and NpcTimeUse.category_full(NpcAgent.State.TRAVELING, "sleep") == "walk"
		and NpcTimeUse.category_full(NpcAgent.State.IDLE, "") == "idle")
	_check("light tier: each code to the same category",
		NpcTimeUse.category_light(CrowdCohort.S_DOING, CrowdCohort.A_SLEEP) == "sleep"
		and NpcTimeUse.category_light(CrowdCohort.S_DOING, CrowdCohort.A_BLADDER) == "toilet"
		and NpcTimeUse.category_light(CrowdCohort.S_DOING, CrowdCohort.A_WORK) == "work"
		and NpcTimeUse.category_light(CrowdCohort.S_QUEUE, CrowdCohort.A_BLADDER) == "queue"
		and NpcTimeUse.category_light(CrowdCohort.S_DOING, CrowdCohort.A_MINGLE) == "social"
		and NpcTimeUse.category_light(CrowdCohort.S_CIRCLE, CrowdCohort.A_ENRICH) == "venue"
		and NpcTimeUse.category_light(CrowdCohort.S_TRAVEL, CrowdCohort.A_HUNGER) == "walk")
	var every := true
	for g: Array in NpcTimeUse.GROUPS:
		for c in g[1]:
			if not NpcTimeUse.CATS.has(c):
				every = false
	var covered := {}
	for g: Array in NpcTimeUse.GROUPS:
		for c in g[1]:
			covered[c] = true
	_check("every group names real categories and every category is in a group",
		every and covered.size() == NpcTimeUse.CATS.size())
	_check("every category has a label and a colour", NpcTimeUse.CATS.all(func(c) -> bool:
		return NpcTimeUse.LABELS.has(c) and NpcTimeUse.COLORS.has(c)))


func _test_accounting() -> void:
	var tu := NpcTimeUse.new()
	var t := 240.0
	_check("the first tick credits nothing", tu.step(t) == 0.0)
	_check("a tick credits the time since the last", is_equal_approx(tu.step(t + 0.1), 0.1))
	_check("a jump is not anybody's time", tu.step(t + 5.0) == 0.0 and is_equal_approx(tu.step(t + 5.05), 0.05))
	tu.record("a", "work", 2.0, 230.0)
	tu.record("a", "sleep", 1.0, 270.0)
	tu.step(270.0)
	tu.step(252.0)
	_check("a scrub back forgets the days from the one scrubbed into",
		tu.days.has(NpcTimeUse.day_of(230.0)) and not tu.days.has(NpcTimeUse.day_of(270.0)),
		str(tu.days.keys()))
	_check("whole-session totals keep what was lived", is_equal_approx(tu.total_h, 3.0))
	var old := NpcTimeUse.new()
	old.record("a", "work", 1.0, 0.0)
	old.record("a", "work", 1.0, 24.0 * (NpcTimeUse.DAYS_KEPT + 3))
	_check("only the last DAYS_KEPT days are kept", old.days.size() == 1)


func _test_summary() -> void:
	var tu := NpcTimeUse.new()
	# Two days for "a": 8 sleep, 8 work, 8 social. Half a day for "b".
	for d in 2:
		var h := 24.0 * (100 + d) + 1.0
		tu.record("a", "sleep", 8.0, h)
		tu.record("a", "work", 8.0, h)
		tu.record("a", "social", 8.0, h)
	tu.record("b", "sleep", 6.0, 24.0 * 101 + 1.0)
	tu.record("b", "work", 6.0, 24.0 * 101 + 1.0)
	var s := tu.summary(24.0 * 101 + 12.0, 7)
	_check("two people over two days", int(s["people"]) == 2 and int(s["days"]) == 2)
	var a: Dictionary = (s["per_person"] as Array)[0]["hours"]
	_check("a person's hours add to a day", absf(a.values().reduce(func(x, y): return x + y) - 24.0) < 1e-3
		and absf(float(a["work"]) - 8.0) < 1e-3)
	var b: Dictionary = (s["per_person"] as Array)[1]["hours"]
	_check("a part day is scaled to a day", absf(float(b["work"]) - 12.0) < 1e-3)
	var mean: Dictionary = s["mean"]
	# 60 h recorded (48 + 12): work 22 of them.
	_check("the mean weights by time recorded", absf(float(mean["work"]) - 24.0 * 22.0 / 60.0) < 1e-3)
	var grp := {}
	for g in s["groups"]:
		grp[str(g["label"])] = g
	_check("the groups carry ATUS's reference", is_equal_approx(float(grp["Sleep"]["ref"]), 9.03)
		and absf(float(grp["Leisure & social"]["h"]) - float(mean["social"])) < 1e-6)


func _test_complete_days() -> void:
	# Asleep 22:00 to 06:00, working the rest; lived from midnight to 10:00 the
	# next day. The part day (a morning, mostly asleep) must not skew it.
	var tu := NpcTimeUse.new()
	var t := 0.0
	tu.step(t)
	while t < 34.0 - 1e-6:
		t += 0.25
		var dt := tu.step(t)
		var hod := fposmod(t - 0.125, 24.0)
		tu.record("a", "sleep" if hod < 6.0 or hod >= 22.0 else "work", dt, t - 0.125)
	var s := tu.summary(t, 7)
	_check("only the complete day is used once there is one",
		not bool(s["partial"]) and int(s["days"]) == 1 and absf(float(s["mean"]["sleep"]) - 8.0) < 0.01,
		"%s" % str(s["mean"]))
	tu.step(t - 2.0)
	_check("a scrub back takes the day's coverage with it", not tu.day_span.has(1) and tu.is_complete(0))


func _test_verdicts() -> void:
	_check("verdicts at the bounds", NpcTimeUse.verdict(30.0) == "sustainable"
		and NpcTimeUse.verdict(45.0) == "heavy" and NpcTimeUse.verdict(60.0) == "overloaded")
	var items := [{"hours": 14.0}, {"hours": 21.0}]
	_check("rota demand per person per week", is_equal_approx(NpcTimeUse.demand_h_week(items, 5, 7), 7.0))
