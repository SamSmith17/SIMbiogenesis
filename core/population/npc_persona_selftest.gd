extends SceneTree

## NpcPersona + the person's own night (NPC life pass, Phase 5). Offline,
## deterministic. Carries EXPECTED_CHECKS (a runtime error aborts a test
## function while the PASS line still prints).
##
##   Godot --headless --path . --script core/population/npc_persona_selftest.gd

const EXPECTED_CHECKS := 27

var _checks := 0
var _failed := 0


func _initialize() -> void:
	print("NPC PERSONA SELFTEST")
	_test_distributions()
	_test_overrides()
	_test_sleep_shift()
	_test_night_move()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failed == 0:
		print("NPC PERSONA SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("NPC PERSONA SELFTEST FAIL  (%d of %d checks failed)" % [_failed, _checks])
	quit(1 if _failed > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s  %s" % [label, detail])
		print("  FAIL: %s  %s" % [label, detail])


func _moments(xs: Array) -> Vector2:
	var m := 0.0
	for x in xs:
		m += float(x)
	m /= float(xs.size())
	var v := 0.0
	for x in xs:
		v += (float(x) - m) * (float(x) - m)
	return Vector2(m, sqrt(v / float(xs.size())))


func _test_distributions() -> void:
	var chrono: Array = []
	var need: Array = []
	var owls := 0
	var larks := 0
	var aff_min := 9.0
	var aff_max := -9.0
	for k in 3000:
		var p := NpcPersona.for_id("pp_npc_%d" % k)
		chrono.append(p["chrono_h"])
		need.append(p["sleep_need_h"])
		match NpcPersona.chronotype_label(p):
			"Night owl":
				owls += 1
			"Early bird":
				larks += 1
		for f in NpcPersona.FAMILIES:
			aff_min = minf(aff_min, NpcPersona.affinity(p, f))
			aff_max = maxf(aff_max, NpcPersona.affinity(p, f))
	var c := _moments(chrono)
	var n := _moments(need)
	_check("chronotype centred on the routine", absf(c.x) < 0.06, "mean %.3f" % c.x)
	_check("chronotype sd about an hour (MCTQ)", absf(c.y - NpcPersona.CHRONO_SD_H) < 0.08, "sd %.3f" % c.y)
	_check("chronotype clamped", chrono.min() >= -NpcPersona.CHRONO_MAX_H and chrono.max() <= NpcPersona.CHRONO_MAX_H)
	_check("sleep need about 8 h", absf(n.x - NpcPersona.BASE_SLEEP_H) < 0.05, "mean %.3f" % n.x)
	_check("sleep need sd about 0.6 h", absf(n.y - NpcPersona.SLEEP_SD_H) < 0.06, "sd %.3f" % n.y)
	_check("sleep need inside 6.5-9.5 h", need.min() >= NpcPersona.SLEEP_MIN_H and need.max() <= NpcPersona.SLEEP_MAX_H)
	# |chrono| >= 0.75 SD: ~22.7 % each side of a normal.
	_check("owls and larks about a fifth each", absf(owls / 3000.0 - 0.227) < 0.04 and absf(larks / 3000.0 - 0.227) < 0.04,
		"%d owls %d larks" % [owls, larks])
	_check("affinities span -1..1", aff_min >= -1.0 and aff_max <= 1.0 and aff_min < -0.8 and aff_max > 0.8)
	_check("a profile is deterministic", NpcPersona.for_id("pp_npc_7") == NpcPersona.for_id("pp_npc_7"))
	_check("bathroom counts are NpcBathroom's",
		int(NpcPersona.for_id("pp_npc_7")["pees_per_day"]) == NpcBathroom.pees_per_day("pp_npc_7"))


func _test_overrides() -> void:
	var base := NpcPersona.for_id("ov_npc_1")
	var p := NpcPersona.for_id("ov_npc_1", {"chrono_h": 1.5, "sleep_need_h": 20.0, "bogus": 3,
		"affinities": {"cook": 1.0, "nonsense": 1.0}, "skills": ["first aid", "  "],
		"unavailable": [{"day": 2, "start_h": 9.0, "end_h": 12.0}, {"start_h": 5.0, "end_h": 5.0}]})
	_check("an override wins", float(p["chrono_h"]) == 1.5)
	_check("an override is clamped", float(p["sleep_need_h"]) == NpcPersona.SLEEP_MAX_H)
	_check("unknown fields dropped", not p.has("bogus"))
	_check("affinity override merges, unknown family dropped",
		float(p["affinities"]["cook"]) == 1.0 and not (p["affinities"] as Dictionary).has("nonsense")
		and float(p["affinities"]["build"]) == float(base["affinities"]["build"]))
	_check("blank skills dropped", (p["skills"] as Array) == ["first aid"])
	_check("zero-length unavailable dropped", (p["unavailable"] as Array).size() == 1)
	_check("unavailable on its weekday only",
		NpcPersona.is_unavailable(p, 2, 10.0) and not NpcPersona.is_unavailable(p, 3, 10.0)
		and not NpcPersona.is_unavailable(p, 2, 13.0))
	_check("overrides do not touch the generated profile",
		NpcPersona.for_id("ov_npc_1") == base and not bool(base["overridden"]) and bool(p["overridden"]))


func _test_sleep_shift() -> void:
	var s := NpcPersona.sleep_shift({"chrono_h": 1.0, "sleep_need_h": 9.0})
	_check("an owl needing 9 h: bed +0.5, wake +1.5", s.is_equal_approx(Vector2(0.5, 1.5)), str(s))
	var r := NpcRoutine.default_day()
	r.set_personas({"a": {"chrono_h": -2.0, "sleep_need_h": 8.0}})
	_check("a lark's sleep window opens 2 h early",
		absf(r.person_sleep_start("a", 21.0) - fposmod(r.sleep_start_h(21.0) - 2.0, 24.0)) < 1e-6)
	_check("and the wake base moves with it",
		absf(r.person_wake_base("a", 6.0) - fposmod(r.wake_base_h(6.0) - 2.0, 24.0)) < 1e-6)


func _tiles(pb: Array) -> bool:
	var total := 0.0
	for b in pb:
		total += fposmod(float(b["end_h"]) - float(b["start_h"]), 24.0)
	if absf(total - 24.0) > 1e-4:
		return false
	for h10 in 240:
		var h := float(h10) / 10.0
		var hits := 0
		for b in pb:
			if NpcRoutine._covers(b, h):
				hits += 1
		if hits != 1:
			return false
	return true


func _kind_at(pb: Array, h: float) -> String:
	for b in pb:
		if NpcRoutine._covers(b, h):
			return str(b["kind"])
	return ""


func _after_sleep(pb: Array) -> String:
	for b in pb:
		if str(b["kind"]) == NpcRoutine.SLEEP:
			return _kind_at(pb, fposmod(float(b["end_h"]) + 0.01, 24.0))
	return ""


func _test_night_move() -> void:
	var r := NpcRoutine.default_day()
	r.set_personas({
		"owl": {"chrono_h": 2.0, "sleep_need_h": 8.0},
		"lark": {"chrono_h": -2.0, "sleep_need_h": 8.0},
	})
	var owl := r.personal_blocks("owl|5")
	var lark := r.personal_blocks("lark|5")
	_check("an owl's day still tiles", _tiles(owl))
	_check("a lark's day still tiles", _tiles(lark))
	# (The bathroom after waking floats up to ~25 min with the day's jitter.)
	_check("the owl sleeps till about 10:00 (routine 08:00 + 2 h), then the bathroom",
		_kind_at(owl, 9.5) == NpcRoutine.SLEEP and _kind_at(owl, 10.5) != NpcRoutine.SLEEP
		and _after_sleep(owl) == NpcRoutine.BATHROOM)
	_check("the owl is still up at 01:00, washing before bed",
		_kind_at(owl, 0.5) != NpcRoutine.SLEEP and _kind_at(owl, 1.2) == NpcRoutine.WASH)
	_check("the lark is in bed by 22:00 and up about 06:00",
		_kind_at(lark, 22.0) == NpcRoutine.SLEEP and _kind_at(lark, 5.5) == NpcRoutine.SLEEP
		and _kind_at(lark, 6.5) != NpcRoutine.SLEEP and _after_sleep(lark) == NpcRoutine.BATHROOM
		and _kind_at(lark, 7.0) == NpcRoutine.FREE)
	_check("lunch and the afternoon's work stay where the community put them",
		_kind_at(owl, 13.5) == NpcRoutine.EAT and _kind_at(lark, 13.5) == NpcRoutine.EAT
		and _kind_at(owl, 15.0) == NpcRoutine.WORK and _kind_at(lark, 15.0) == NpcRoutine.WORK)
