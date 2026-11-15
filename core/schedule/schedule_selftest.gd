extends SceneTree

## ScheduledEvents (the one list of what is scheduled) + IcsWriter (RFC 5545
## export). NPC life pass, Phase 8. Offline, deterministic. Carries
## EXPECTED_CHECKS (a runtime error aborts a test function while the PASS line
## still prints).
##
##   Godot --headless --path . --script core/schedule/schedule_selftest.gd

const EXPECTED_CHECKS := 43

var _checks := 0
var _failed := 0


func _initialize() -> void:
	print("SCHEDULE SELFTEST")
	_test_sources()
	_test_window_and_merge()
	_test_person_day()
	_test_dates()
	_test_text()
	_test_calendar_round_trip()
	_test_uid_stability()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failed == 0:
		print("SCHEDULE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SCHEDULE SELFTEST FAIL  (%d of %d checks failed)" % [_failed, _checks])
	quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s  %s" % [label, detail])
		print("  FAIL: %s  %s" % [label, detail])


const DAY := 739000   # a day index in the 2020s


func _h(day: int, hour: float) -> float:
	return float(day) * 24.0 + hour


func _test_sources() -> void:
	var dep := ScheduledEvents.from_deploy([
		{"id": "ev_1", "action": "deploy", "at_h": _h(DAY, 9.0)},
		{"id": "ev_2", "action": "arrive", "at_h": _h(DAY, 7.0)}])
	_check("deploy events keep their id, kind and hour, and can be dragged",
		dep.size() == 2 and str(dep[0]["kind"]) == "deploy" and str(dep[1]["kind"]) == "arrive"
		and is_equal_approx(float(dep[0]["at_h"]), _h(DAY, 9.0)) and bool(dep[0]["editable"])
		and not ScheduledEvents.is_span(dep[0]))
	var burns := ScheduledEvents.from_burns([{"id": "burn:p1", "prop_id": "p1",
		"at_h": _h(DAY, 21.0), "label": "Effigy"}])
	_check("a burn is an instant naming its prop", burns.size() == 1
		and str(burns[0]["kind"]) == "burn" and str(burns[0]["ref"]) == "p1"
		and str(burns[0]["label"]).contains("Effigy"))
	var stage := {"id": "sp_stage", "label": "Bass Stage", "type": "stage",
		"program": [{"day": -1, "start_h": 20.0, "end_h": 2.0, "label": "Evening set"}]}
	var quiet := {"id": "sp_q", "label": "Temple", "program": []}
	var sets := ScheduledEvents.from_programs([stage, quiet], _h(DAY, 0.0), _h(DAY + 3, 0.0))
	_check("a 20:00–02:00 set is a 6 h span on each of the three days (+ the night before's tail)",
		sets.size() == 4 and is_equal_approx(ScheduledEvents.duration_h(sets[1]), 6.0),
		"%d sets" % sets.size())
	_check("a venue with no programme has no sets", not str(sets).contains("sp_q"))
	_check("set ids are stable per space, slot and day",
		str(sets[1]["id"]) == "set:sp_stage:0:%d" % DAY
		and str((sets[1]["ref"] as Dictionary)["space_id"]) == "sp_stage")
	_check("the set is labelled venue — slot",
		str(sets[1]["label"]) == "Bass Stage — Evening set")
	var veh := ScheduledEvents.from_vehicles([
		{"id": "v1", "start_h": _h(DAY, 8.0), "park_h": _h(DAY, 8.2), "leave_h": _h(DAY + 2, 15.0),
			"gone_h": _h(DAY + 2, 15.1)},
		{"id": "v2", "start_h": NAN, "park_h": -INF, "leave_h": INF, "gone_h": INF}], {"v1": "Tool Bus"})
	_check("a vehicle with both drives has an in and an out; one with neither has none",
		veh.size() == 2 and str(veh[0]["kind"]) == "vehicle_in"
		and str(veh[1]["kind"]) == "vehicle_out" and str(veh[0]["label"]) == "Tool Bus drives in")
	var meals := ScheduledEvents.from_meals(NpcRoutine.default_day().blocks, _h(DAY, 0.0),
		_h(DAY + 1, 0.0), "hab_1")
	var lunch := 0
	for m in meals:
		if str((m as Dictionary)["label"]).begins_with("Lunch"):
			lunch += 1
	_check("the default day's meals are on the calendar, one lunch a day", meals.size() >= 2 and lunch == 1,
		"%d meals, %d lunch" % [meals.size(), lunch])
	var rota := {"shifts": {"chore|c1|%d" % DAY: {"agents": ["a1", "a2"], "start_h": 9.0,
		"end_h": 10.5, "day": DAY, "hours": 1.5, "label": "Water run", "family": "haul",
		"kind": "chore", "ref": "c1"}}}
	var shifts := ScheduledEvents.from_rota(rota, {"a1": "Spark", "a2": "Moss"}, "hab_1")
	_check("a rota shift is a span naming its crew",
		shifts.size() == 1 and (shifts[0]["who"] as Array) == ["a1", "a2"]
		and is_equal_approx(float(shifts[0]["at_h"]), _h(DAY, 9.0))
		and is_equal_approx(ScheduledEvents.duration_h(shifts[0]), 1.5)
		and str(shifts[0]["label"]) == "Water run — Spark, Moss")


func _test_window_and_merge() -> void:
	var a := ScheduledEvents.make("x", "deploy", _h(DAY, 9.0), _h(DAY, 9.0), "X", "deploy")
	var b := ScheduledEvents.make("y", "set", _h(DAY, 20.0), _h(DAY + 1, 2.0), "Y", "set")
	var c := ScheduledEvents.make("z", "meal", _h(DAY + 2, 12.0), _h(DAY + 2, 13.0), "Z", "meal")
	_check("an instant counts on its hour, a span on any overlap",
		ScheduledEvents.overlaps(a, _h(DAY, 8.0), _h(DAY, 10.0))
		and not ScheduledEvents.overlaps(a, _h(DAY, 9.5), _h(DAY, 10.0))
		and ScheduledEvents.overlaps(b, _h(DAY + 1, 1.0), _h(DAY + 1, 3.0))
		and not ScheduledEvents.overlaps(b, _h(DAY + 1, 2.0), _h(DAY + 1, 3.0)))
	var merged := ScheduledEvents.merge([[c, a], [b, a]])
	_check("merge drops duplicate ids and sorts by start",
		merged.size() == 3 and str(merged[0]["id"]) == "x" and str(merged[2]["id"]) == "z")
	_check("in_window keeps what overlaps a day",
		ScheduledEvents.in_window(merged, _h(DAY, 0.0), _h(DAY + 1, 0.0)).size() == 2)
	var p := ScheduledEvents.make("s", "shift", _h(DAY, 9.0), _h(DAY, 10.0), "S", "rota", "", false, ["a1"])
	var mine := ScheduledEvents.for_person([a, p], "a1")
	var theirs := ScheduledEvents.for_person([a, p], "a2")
	_check("a person sees the site's events and their own shifts, not other people's",
		mine.size() == 2 and theirs.size() == 1)
	_check("find returns by id", str(ScheduledEvents.find(merged, "y").get("kind", "")) == "set")


func _test_person_day() -> void:
	var r := NpcRoutine.default_day()
	r.set_personas({"owl": {"chrono_h": 2.0, "sleep_need_h": 8.0}})
	var segs := ScheduledEvents.person_day(r, "owl", 0.0, DAY)
	var total := 0.0
	var contiguous := true
	for i in segs.size():
		var s: Dictionary = segs[i]
		total += float(s["b"]) - float(s["a"])
		if i > 0 and not is_equal_approx(float(s["a"]), float((segs[i - 1] as Dictionary)["b"])):
			contiguous = false
	_check("a person's day tiles midnight to midnight", contiguous and is_equal_approx(total, 24.0)
		and is_equal_approx(float(segs[0]["a"]), _h(DAY, 0.0)), "%.2f h" % total)
	var by := ScheduledEvents.hours_by_kind(segs)
	_check("an owl sleeps about eight hours", absf(float(by.get(NpcRoutine.SLEEP, 0.0)) - 8.0) < 1.6,
		"%.2f h" % float(by.get(NpcRoutine.SLEEP, 0.0)))
	# The day agrees with what the routine tells the agent at each hour.
	var agree := true
	for hour in [3.0, 9.3, 13.4, 15.0, 22.0]:
		var t := _h(DAY, hour)
		var key := r.day_key("owl", t, 0.0)
		var want := str(r.block_at(hour, 0.0, key).get("kind", ""))
		var got := ""
		for s in segs:
			if t >= float(s["a"]) and t < float(s["b"]):
				got = str(s["kind"])
		if got != want:
			agree = false
	_check("person_day says what block_at says at each hour", agree)
	var shift := ScheduledEvents.make("rota:x", "shift", _h(DAY, 15.0), _h(DAY, 16.5), "Water run",
		"rota", {"chore": "Water run"}, false, ["owl"])
	var with := ScheduledEvents.person_day(r, "owl", 0.0, DAY, [shift])
	var by2 := ScheduledEvents.hours_by_kind(with)
	var tot2 := 0.0
	for s in with:
		tot2 += float(s["b"]) - float(s["a"])
	_check("a shift lies over the day: 1.5 h of shift, still 24 h in all",
		is_equal_approx(float(by2.get("shift", 0.0)), 1.5) and is_equal_approx(tot2, 24.0))
	var lbl := ""
	for s in with:
		if str(s["kind"]) == "shift":
			lbl = str(s["label"])
	_check("the shift is labelled with its chore", lbl == "Water run")


func _test_dates() -> void:
	var h := IcsWriter.abs_of(2026, 11, 14, 9, 30)
	var d := IcsWriter.date_of(h)
	_check("date_of inverts abs_of", d.year == 2026 and d.month == 11 and d.day == 14
		and d.hour == 9 and d.minute == 30)
	var clock := CelestialClock.new()
	var cd: Dictionary = clock.abs_hours_to_date(h)
	_check("the same calendar as the game's clock", int(cd["year"]) == 2026
		and int(cd["month"]) == 11 and int(cd["day"]) == 14
		and absf(float(cd["day_time"]) - 9.5) < 1e-4, str(cd))
	var leap := IcsWriter.date_of(IcsWriter.abs_of(2024, 2, 29, 23, 59))
	_check("Feb 29 of a leap year", leap.month == 2 and leap.day == 29 and leap.minute == 59)
	_check("local stamps", IcsWriter.local_stamp(h) == "20261114T093000")
	_check("UTC stamp of the epoch", IcsWriter.utc_stamp(0) == "19700101T000000Z")


func _test_text() -> void:
	var s := "Dinner, then dishes; a\\b\nnext line"
	_check("text escaping round-trips", IcsWriter.unescape_text(IcsWriter.escape_text(s)) == s)
	_check("escaping covers , ; \\ and newlines",
		IcsWriter.escape_text(s) == "Dinner\\, then dishes\\; a\\\\b\\nnext line")
	var long := "SUMMARY:" + "Cleaning the composting toilets — Spark, Moss, Ember, Sunbeam, Juniper, Óscar ✦ ✦ ✦"
	var f := IcsWriter.fold(long)
	var ok := true
	for l in f.split("\r\n"):
		if l.to_utf8_buffer().size() > 75:
			ok = false
	_check("folded lines are at most 75 octets", ok and f.contains("\r\n "))
	_check("unfolding gives the line back", f.replace("\r\n ", "") == long)
	_check("short lines are not folded", IcsWriter.fold("UID:x") == "UID:x")
	_check("file names", IcsWriter.file_name("Spark Moss / team.ics") == "Spark_Moss__team_ics")


func _cal(evs: Array, dst: bool) -> String:
	return IcsWriter.calendar(evs, {"name": "Walton camp", "key": "w1",
		"tz": {"std_offset_h": -8.0, "dst": dst}, "now_unix": 1763100000,
		"desc_of": func(ev): return "kind %s" % str(ev["kind"])})


func _test_calendar_round_trip() -> void:
	var t := IcsWriter.abs_of(2026, 7, 4, 20, 0)
	var evs: Array = [
		ScheduledEvents.make("set:s:0:1", "set", t, t + 6.0, "Bass Stage — Evening, late", "set"),
		ScheduledEvents.make("ev_1", "deploy", t - 11.0, t - 11.0, "Deploy", "deploy"),
	]
	var txt := _cal(evs, true)
	_check("lines end CRLF and the file starts and ends a VCALENDAR",
		txt.begins_with("BEGIN:VCALENDAR\r\n") and txt.ends_with("END:VCALENDAR\r\n")
		and not txt.replace("\r\n", "").contains("\n"))
	var p := IcsWriter.parse(txt)
	var e0: Dictionary = (p["events"] as Array)[0] if (p["events"] as Array).size() > 0 else {}
	var e1: Dictionary = (p["events"] as Array)[1] if (p["events"] as Array).size() > 1 else {}
	_check("two events come back, sorted by start", (p["events"] as Array).size() == 2
		and str(e0.get("UID", "")) == "w1-ev_1@simbiogenesis")
	_check("the set's summary survives escaping", str(e1.get("SUMMARY", "")) == "Bass Stage — Evening, late")
	_check("local start and end with the site zone", str(e1.get("DTSTART", "")) == "20260704T200000"
		and str(e1.get("DTEND", "")) == "20260705T020000")
	_check("an instant is written as a quarter hour", str(e0.get("DTEND", "")) == "20260704T091500")
	_check("the calendar name and the time zone", str(p["name"]) == "Walton camp"
		and str(p["tzid"]) == IcsWriter.TZID and txt.contains("DTSTART;TZID=%s:" % IcsWriter.TZID))
	_check("a DST site writes the US daylight rule, -0800 / -0700",
		txt.contains("RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU") and txt.contains("TZOFFSETTO:-0700")
		and txt.contains("TZOFFSETTO:-0800"))
	var nodst := _cal(evs, false)
	_check("a site without DST writes one fixed offset", not nodst.contains("DAYLIGHT")
		and nodst.contains("TZOFFSETTO:-0800"))
	_check("descriptions come from the callable", str(e1.get("DESCRIPTION", "")) == "kind set")
	_check("DTSTAMP is the given now", txt.contains("DTSTAMP:%s" % IcsWriter.utc_stamp(1763100000)))


func _test_uid_stability() -> void:
	var t := IcsWriter.abs_of(2026, 7, 4, 9, 0)
	var a: Array = [ScheduledEvents.make("rota:h:chore|c1|7", "shift", t, t + 1.0, "Water run", "rota")]
	var b: Array = [ScheduledEvents.make("rota:h:chore|c1|7", "shift", t + 1.0, t + 2.0, "Water run — later", "rota")]
	var ua := str(((IcsWriter.parse(_cal(a, true))["events"] as Array)[0] as Dictionary)["UID"])
	var ub := str(((IcsWriter.parse(_cal(b, true))["events"] as Array)[0] as Dictionary)["UID"])
	_check("a moved event keeps its UID (an import updates it)", ua == ub and not ua.is_empty())
	_check("UIDs never carry ; , or spaces", not ua.contains(";") and not ua.contains(",")
		and not ua.contains(" "))
	_check("the same events make the same file", _cal(a, true) == _cal(a, true))
