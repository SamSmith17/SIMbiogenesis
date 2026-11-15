extends SceneTree

## NpcWorkScheduler, the weekly rota (NPC life pass, Phase 6). Offline,
## deterministic. Carries EXPECTED_CHECKS (a runtime error aborts a test
## function while the PASS line still prints).
##
##   Godot --headless --path . --script core/population/work_scheduler_selftest.gd

const EXPECTED_CHECKS := 28
const DAY0 := 740000

var _checks := 0
var _failed := 0


func _initialize() -> void:
	print("WORK SCHEDULER SELFTEST")
	_test_collect()
	_test_plan()
	_test_constraints()
	_test_apply_and_board()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failed == 0:
		print("WORK SCHEDULER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("WORK SCHEDULER SELFTEST FAIL  (%d of %d checks failed)" % [_failed, _checks])
	quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s  %s" % [label, detail])
		print("  FAIL: %s  %s" % [label, detail])


## A camp's daily work: 20 person-hours.
func _board() -> NpcChoreBoard:
	var b := NpcChoreBoard.create_empty()
	for w in [["Cook lunch", 3.0, 2, 3, 11.0, 13.0], ["Cook dinner", 4.0, 2, 3, 16.0, 18.0],
			["Wash up", 2.0, 1, 2, 18.5, 20.0], ["Clean the toilets", 1.5, 1, 1, 10.0, 17.0],
			["Water run", 1.5, 1, 2, 10.0, 18.0], ["Tend the garden", 3.0, 1, 3, 10.0, 12.5],
			["Maintenance", 3.0, 1, 2, 14.0, 18.0], ["Sort the store", 2.0, 1, 2, 14.0, 17.0]]:
		b.add_chore(str(w[0]), float(w[1]), {"window": {"start_h": w[4], "end_h": w[5]},
			"repeat": "daily", "min_workers": w[2], "max_workers": w[3]})
	return b


## n people with neutral profiles (no chronotype, no preferences) unless told.
func _people(n: int, r: NpcRoutine, neutral: bool = true) -> Array:
	var over := {}
	var out: Array = []
	for i in n:
		var id := "ws_npc_%d" % i
		if neutral:
			var aff := {}
			for f in NpcPersona.FAMILIES:
				aff[f] = 0.0
			over[id] = {"chrono_h": 0.0, "sleep_need_h": NpcPersona.BASE_SLEEP_H, "affinities": aff}
	r.set_personas(over)
	for i in n:
		var id := "ws_npc_%d" % i
		out.append({"id": id, "offset_h": 0.0, "persona": r.persona_of(id), "skills": {}, "worked_h": 0.0})
	return out


func _test_collect() -> void:
	var b := _board()
	b.add_chore("One-off", 2.0, {"repeat": "once"})
	b.add_chore("Machine step", 1.0, {"repeat": "daily", "chore_key": "mach|x|y"})
	b.add_chore("Sam's job", 1.0, {"repeat": "daily", "assigned_to": "sam"})
	var held := b.add_chore("Paused", 1.0, {"repeat": "daily"})
	b.find(held)["held"] = true
	b.add_chore("Laundry", 2.0, {"repeat": "weekly", "repeat_dow": [NpcChoreBoard.weekday_of_day(DAY0 + 2)]})
	var duty := NpcDutyRoster.create_empty()
	duty.add_duty("Cook breakfast", 2.0, {"crew": 2, "window": {"start_h": 8.0, "end_h": 9.5}})
	var items := NpcWorkScheduler.collect(b, duty, DAY0, 7)
	var labels := {}
	for it in items:
		labels[str(it["label"])] = int(labels.get(str(it["label"]), 0)) + 1
	_check("daily chores and duties every day", int(labels.get("Cook lunch", 0)) == 7 and int(labels.get("Cook breakfast", 0)) == 7)
	_check("a weekly chore on its weekday only", int(labels.get("Laundry", 0)) == 1)
	_check("one-offs, machine steps, held and the player's own assignment stay on the open board",
		not labels.has("One-off") and not labels.has("Machine step") and not labels.has("Paused") and not labels.has("Sam's job"))
	_check("families from the label", NpcWorkScheduler.family_of("Cook dinner") == "cook"
		and NpcWorkScheduler.family_of("Clean the toilets") == "clean" and NpcWorkScheduler.family_of("Xyzzy") == "")


func _spread(planned: Dictionary, people: Array) -> Vector2:
	var m := 0.0
	var lo := INF
	var hi := -INF
	for p in people:
		var h := float(planned.get(str(p["id"]), 0.0))
		m += h
		lo = minf(lo, h)
		hi = maxf(hi, h)
	m /= float(people.size())
	return Vector2(m, hi - lo)


func _test_plan() -> void:
	var r := NpcRoutine.default_day()
	var people := _people(24, r)
	var items := NpcWorkScheduler.collect(_board(), null, DAY0, 7)
	var t0 := Time.get_ticks_usec()
	var plan := NpcWorkScheduler.plan(items, people, r, DAY0, 7)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check("every item gets a crew", (plan["unassigned"] as Array).is_empty(), str(plan["unassigned"]))
	var sp := _spread(plan["planned_h"], people)
	# Shifts come in 1-1.5 h pieces, so within 10 % of the mean plus one shift.
	_check("hours spread within 10 % of the mean (plus one shift) on a feasible fixture", sp.y <= sp.x * 0.1 + 1.0 + 1e-6,
		"mean %.2f spread %.2f" % [sp.x, sp.y])
	var avail := NpcWorkScheduler.availability(people, r, DAY0, 7)
	var bad := 0
	for key in plan["shifts"]:
		var sh: Dictionary = plan["shifts"][key]
		for a in sh["agents"]:
			var flags: PackedByteArray = avail[str(a)][int(sh["day"])]
			var k := int(floor(float(sh["start_h"]) / NpcWorkScheduler.SLOT_H))
			if flags[k] == 0:
				bad += 1
	_check("nobody is put on a shift outside their work or free time", bad == 0, "%d" % bad)
	var again := NpcWorkScheduler.plan(items, _people(24, r), r, DAY0, 7)
	_check("deterministic", JSON.stringify(again["shifts"]) == JSON.stringify(plan["shifts"]))
	# 40 people over a week.
	var r40 := NpcRoutine.default_day()
	var p40 := _people(40, r40, false)
	var b40 := _board()
	for c in b40.chores:
		(c as Dictionary)["chore_hours"] = float((c as Dictionary)["chore_hours"]) * 1.6
	var items40 := NpcWorkScheduler.collect(b40, null, DAY0, 7)
	NpcWorkScheduler.availability(p40, r40, DAY0, 7)   # warm the personal days
	t0 = Time.get_ticks_usec()
	NpcWorkScheduler.plan(items40, p40, r40, DAY0, 7)
	var ms40 := (Time.get_ticks_usec() - t0) / 1000.0
	print("  plan: 24 people %.1f ms, 40 people %.1f ms" % [ms, ms40])
	_check("40 people over a week plan in well under a frame budget's worth (< 150 ms)", ms40 < 150.0, "%.1f ms" % ms40)
	# Chronotypes: nobody sits in their own sleep for a shift.
	var pc := _people(24, r40, false)
	var plan_c := NpcWorkScheduler.plan(items, pc, r40, DAY0, 7)
	var asleep := 0
	for key in plan_c["shifts"]:
		var sh: Dictionary = plan_c["shifts"][key]
		for a in sh["agents"]:
			var h := float(sh["start_h"]) + 0.1
			var abs_h := float(int(sh["day"])) * 24.0 + h
			if r40.block_at(h, 0.0, r40.day_key(str(a), abs_h, 0.0)).get("kind") == NpcRoutine.SLEEP:
				asleep += 1
	_check("with chronotypes, no shift lands in someone's sleep", asleep == 0, "%d" % asleep)


func _test_constraints() -> void:
	var r := NpcRoutine.default_day()
	var people := _people(6, r)
	# Skills: only ws_npc_2 is qualified, so the skilled job is theirs.
	people[2]["skills"] = {"first_aid": true}
	var b := NpcChoreBoard.create_empty()
	b.add_chore("Check the first-aid kit", 1.0, {"window": {"start_h": 10.0, "end_h": 12.0},
		"repeat": "daily", "requires_skill": "first_aid"})
	var plan := NpcWorkScheduler.plan(NpcWorkScheduler.collect(b, null, DAY0, 3), people, r, DAY0, 3)
	var only_2 := true
	for key in plan["shifts"]:
		if (plan["shifts"][key]["agents"] as Array) != ["ws_npc_2"]:
			only_2 = false
	_check("skilled work goes to the skilled", only_2 and (plan["shifts"] as Dictionary).size() == 3)
	# Unavailable hours: everyone but ws_npc_4 is away 10-12 every day.
	var p2 := _people(6, r)
	for i in 6:
		if i != 4:
			p2[i]["persona"] = NpcPersona.for_id(str(p2[i]["id"]), {"unavailable": [{"day": -1, "start_h": 10.0, "end_h": 12.0}]})
	var b2 := NpcChoreBoard.create_empty()
	b2.add_chore("Morning job", 1.0, {"window": {"start_h": 10.0, "end_h": 11.0}, "repeat": "daily"})
	var plan2 := NpcWorkScheduler.plan(NpcWorkScheduler.collect(b2, null, DAY0, 2), p2, r, DAY0, 2)
	var all_4 := true
	for key in plan2["shifts"]:
		if (plan2["shifts"][key]["agents"] as Array) != ["ws_npc_4"]:
			all_4 = false
	_check("unavailable hours respected", all_4 and (plan2["shifts"] as Dictionary).size() == 2)
	# Max hours a day: nobody planned past their own cap.
	var p3 := _people(3, r)
	for i in 3:
		p3[i]["persona"] = NpcPersona.for_id(str(p3[i]["id"]), {"max_h_day": 2.0, "max_h_week": 14.0})
	var plan3 := NpcWorkScheduler.plan(NpcWorkScheduler.collect(_board(), null, DAY0, 1), p3, r, DAY0, 1)
	var over := false
	for p in p3:
		if float((plan3["planned_h"] as Dictionary).get(str(p["id"]), 0.0)) > 2.0 + 1e-6:
			over = true
	_check("nobody past their daily cap; the rest is left on the open board", not over and not (plan3["unassigned"] as Array).is_empty())
	# Preference: a keen cook does more of the cooking than a reluctant one.
	var p4 := _people(8, r)
	var keen := {}
	var loath := {}
	for f in NpcPersona.FAMILIES:
		keen[f] = 0.0
		loath[f] = 0.0
	keen["cook"] = 1.0
	loath["cook"] = -1.0
	p4[0]["persona"] = NpcPersona.for_id("ws_npc_0", {"affinities": keen})
	p4[1]["persona"] = NpcPersona.for_id("ws_npc_1", {"affinities": loath})
	var plan4 := NpcWorkScheduler.plan(NpcWorkScheduler.collect(_board(), null, DAY0, 7), p4, r, DAY0, 7)
	var cook := {"ws_npc_0": 0.0, "ws_npc_1": 0.0}
	for key in plan4["shifts"]:
		var sh: Dictionary = plan4["shifts"][key]
		if str(sh["family"]) == "cook":
			for a in sh["agents"]:
				if cook.has(str(a)):
					cook[str(a)] = float(cook[str(a)]) + float(sh["hours"])
	_check("preference: the keen cook cooks more than the reluctant one",
		float(cook["ws_npc_0"]) > float(cook["ws_npc_1"]), str(cook))
	var sp4 := _spread(plan4["planned_h"], p4)
	_check("...without running far ahead of everyone (spread under 25 % of the mean)",
		sp4.y <= sp4.x * 0.25, "mean %.2f spread %.2f" % [sp4.x, sp4.y])


func _test_apply_and_board() -> void:
	var r := NpcRoutine.default_day()
	var people := _people(6, r)
	var b := NpcChoreBoard.create_empty()
	var cid := b.add_chore("Cook lunch", 2.0, {"window": {"start_h": 11.0, "end_h": 16.0},
		"repeat": "daily", "min_workers": 1, "max_workers": 2})
	var mine := b.add_chore("Sam's job", 1.0, {"repeat": "daily", "assigned_to": "sam"})
	var plan := NpcWorkScheduler.plan(NpcWorkScheduler.collect(b, null, DAY0, 2), people, r, DAY0, 2)
	var named := NpcWorkScheduler.apply(plan, b, null, DAY0)
	var ch := b.find(cid)
	var crew: Array = ch.get("assigned_crew", [])
	_check("today's shift is written on the chore", named == 1 and crew.size() == 2
		and int(ch.get("rota_day", -1)) == DAY0 and str(ch["assigned_to"]) == str(crew[0]))
	_check("the player's own assignment is untouched", str(b.find(mine)["assigned_to"]) == "sam" and not b.find(mine).has("rota_day"))
	var start := float(ch["assign_at_h"])
	var a0 := str(crew[0])
	var a1 := str(crew[1])
	var other := ""
	for p in people:
		if not crew.has(str(p["id"])):
			other = str(p["id"])
			break
	var hour := fposmod(start, 24.0)
	_check("nobody may start long before the shift", b.available_for(a0, start - 1.0, hour - 1.0).is_empty())
	_check("both of the named crew may take it at the start",
		not b.available_for(a0, start, hour).is_empty() and not b.available_for(a1, start, hour).is_empty())
	_check("someone else may not during the hold", b.available_for(other, start + 0.5, hour + 0.5).filter(
		func(c): return str(c["id"]) == cid).is_empty())
	# A crew member who has done their share leaves the rest to the other.
	b.claim(cid, a0)
	b.credit(cid, 1.0, start + 0.5)
	var share_done := b.note_rota_work(cid, a0, 1.0, start + 0.5)
	b.release(cid, a0)
	_check("a crew member who has worked their share steps off it",
		share_done and b.available_for(a0, start + 0.6, hour + 0.6).filter(func(c): return str(c["id"]) == cid).is_empty())
	_check("...and the other still sees it", not b.available_for(a1, start + 0.6, hour + 0.6).filter(
		func(c): return str(c["id"]) == cid).is_empty())
	_check("once the hold lapses anyone may finish it", not b.available_for(other,
		start + NpcDutyRoster.ASSIGN_HOLD_H + 0.1, hour + NpcDutyRoster.ASSIGN_HOLD_H + 0.1).filter(
		func(c): return str(c["id"]) == cid).is_empty())
	# Your own shift heads your list.
	b.add_chore("Open job", 0.5, {"window": {"start_h": 0.0, "end_h": 24.0}, "repeat": "daily", "priority": 0})
	var opts := b.available_for(a1, start + 0.6, hour + 0.6, {}, 0, 3)
	_check("your own rota shift heads your list", not opts.is_empty() and str(opts[0]["id"]) == cid)
	# The next day the rota's names are cleared before the new plan.
	NpcWorkScheduler.apply({"shifts": {}}, b, null, DAY0 + 1)
	_check("yesterday's rota names expire", not b.find(cid).has("rota_day") and str(b.find(cid)["assigned_to"]) == ""
		and not b.find(cid).has("assigned_crew"))
	# The engine runs it once a day.
	var e := NpcPopulationEngine.new()
	e.configure(6, "ws", Vector2.ZERO)
	e.routine = NpcRoutine.default_day()
	e.chore_board = _board()
	var rota := e.plan_rota(float(DAY0) * 24.0 + 1.0)
	_check("the engine plans the week", not (rota.get("shifts", {}) as Dictionary).is_empty())
	_check("and only once a day", e.plan_rota(float(DAY0) * 24.0 + 5.0) == rota)
	# A duty slot takes the rota's crew and its start.
	var duty := NpcDutyRoster.create_empty()
	duty.add_duty("Cook breakfast", 2.0, {"crew": 2, "window": {"start_h": 10.0, "end_h": 12.0}})
	var ids: Array = []
	for p in people:
		ids.append(str(p["id"]))
	duty.generate(DAY0, ids, null, null, 2)
	var dplan := NpcWorkScheduler.plan(NpcWorkScheduler.collect(null, duty, DAY0, 2), people, r, DAY0, 2)
	NpcWorkScheduler.apply(dplan, null, duty, DAY0)
	var slot := duty.slot_for(DAY0, "duty_1")
	var sh: Dictionary = dplan["shifts"]["duty|duty_1|%d" % DAY0]
	_check("a duty slot takes the rota's crew and start", slot.get("agents") == sh["agents"]
		and absf(float(slot.get("start_h", -1.0)) - float(sh["start_h"])) < 1e-6)
