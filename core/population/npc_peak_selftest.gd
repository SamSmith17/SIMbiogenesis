extends SceneTree

## PEAK EXPERIENCE (FUCK YES!) selftest — offline, deterministic.
##   godot --headless --path . --script core/population/npc_peak_selftest.gd
## Pins NpcPeak's rules, PeakField's onset / contagion / hold / time rules and
## score, the per-map score file, the tiers' "vibing" test and the renderer's
## mood packing. Carries EXPECTED_CHECKS (a runtime error aborts a test
## function while the suite still prints PASS).

const EXPECTED_CHECKS := 43

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_rules()
	_test_lone_and_cluster()
	_test_contagion()
	_test_hold()
	_test_time_and_score()
	_test_persistence()
	_test_tiers_and_packing()
	_test_charge()
	_test_fun_meter()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("NPC PEAK SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("NPC PEAK SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


## A cluster chunk: `n` people at `at` (spread over ~2 m), all vibing.
func _cluster(prefix: String, n: int, at: Vector2, sid: String = "") -> Dictionary:
	var ids := PackedStringArray()
	var pos := PackedVector2Array()
	var vib := PackedByteArray()
	var sids := PackedStringArray()
	for i in n:
		ids.append("%s_npc_%d" % [prefix, i])
		pos.append(at + Vector2(fposmod(float(i) * 0.7, 2.0), fposmod(float(i) * 1.3, 2.0)))
		vib.append(1)
		sids.append(sid)
	return {"ids": ids, "pos": pos, "vib": vib, "sid": sids}


func _run(field: PeakField, chunks: Array, t0: float, hours: float, step: float) -> float:
	var t := t0
	field.step(t, chunks)
	while t < t0 + hours - 1e-9:
		t += step
		field.step(t, chunks)
	return t


func _test_rules() -> void:
	_check("no critical mass below MASS_MIN, full at MASS_FULL",
		NpcPeak.mass(0) == 0.0 and NpcPeak.mass(int(NpcPeak.MASS_MIN)) == 0.0 and NpcPeak.mass(int(NpcPeak.MASS_FULL)) == 1.0 and NpcPeak.mass(12) > 0.0)
	_check("peakers nearby raise the rate (contagion), capped",
		NpcPeak.rate_h(20, 3) > NpcPeak.rate_h(20, 0) and NpcPeak.rate_h(20, 50) == NpcPeak.rate_h(20, NpcPeak.CONTAGION_CAP))
	var one := NpcPeak.onset_chance(1.3, 0.2)
	var ten := 1.0 - pow(1.0 - NpcPeak.onset_chance(1.3, 0.02), 10.0)
	_check("the onset chance is dt-exact (one 0.2 h step == ten 0.02 h steps)", absf(one - ten) < 1e-9)
	var ok_needs := {"hunger": 0.2, "thirst": 0.3, "bladder": 0.1, "sleep": 0.2}
	var thirsty := ok_needs.duplicate()
	thirsty["thirst"] = 0.95
	_check("needs met only with every critical need under its threshold and nothing blocked",
		NpcPeak.needs_met(ok_needs, {}) and not NpcPeak.needs_met(thirsty, {})
		and not NpcPeak.needs_met(ok_needs, {"hunger": true}))
	_check("venue moments boost the onset (live set, its closer, the burn)",
		NpcPeak.venue_boost("stage", {"active": true, "programmed": true}) == NpcPeak.BOOST_LIVE_SET
		and NpcPeak.venue_boost("stage", {"active": true, "programmed": true, "peak": true}) == NpcPeak.BOOST_SET_PEAK
		and NpcPeak.venue_boost("effigy", {"phase": VenueCrowd.EffigyPhase.BURNING, "cheer": true}) == NpcPeak.BOOST_BURN
		and NpcPeak.venue_boost("art", {}) == 1.0)
	_check("a peak lifts morale toward PEAK_MORALE and never past it",
		NpcPeak.lift(0.8, 0.1) > 0.8 and NpcPeak.lift(0.9, 10.0) == NpcPeak.PEAK_MORALE
		and NpcPeak.lift(0.97, 1.0) == 0.97)


func _test_lone_and_cluster() -> void:
	var f := PeakField.new()
	_run(f, [_cluster("lone", 1, Vector2(500, 500))], 100.0, 50.0, 0.05)
	_check("a lone person never peaks (50 sim-h)", f.total == 0)
	var g := PeakField.new()
	var c := _cluster("crowd", 20, Vector2.ZERO)
	var t := _run(g, [c], 100.0, 1.0, 0.05)
	_check("a 20-person vibing crowd starts peaking within a sim-hour (%d)" % g.total, g.total >= 1)
	_run(g, [c], t, 3.0, 0.05)
	_check("...and most of it is peaking within four (%d of 20)" % g.peaking_count(), g.peaking_count() >= 12)
	var four := PeakField.new()
	_run(four, [_cluster("pair", 2, Vector2.ZERO)], 100.0, 30.0, 0.05)
	_check("two friends chatting never reach critical mass", four.total == 0)
	var ev := g.take_events()
	_check("each onset is an event with a name", not ev.is_empty() and not str((ev[0] as Dictionary).get("name", "")).is_empty())
	_check("events are taken once", g.take_events().is_empty())


## A crowd with one peaker already in it sparks more onsets than an identical
## crowd without — summed over many crowds so the hash noise averages out.
func _test_contagion() -> void:
	var seeded := 0
	var plain := 0
	for trial in 200:
		var a := PeakField.new()
		var ca := _cluster("sa%d" % trial, 12, Vector2.ZERO)
		a.step(10.0, [ca])
		a.active["sa%d_npc_0" % trial] = {"since": 10.0, "sid": ""}
		var before := a.total
		_run(a, [ca], 10.0, 0.1, 0.05)
		seeded += a.total - before
		var b := PeakField.new()
		var cb := _cluster("sa%d" % trial, 12, Vector2.ZERO)
		_run(b, [cb], 10.0, 0.1, 0.05)
		plain += b.total
	_check("one peaker in a crowd sparks more onsets (seeded %d vs plain %d)" % [seeded, plain],
		float(seeded) > float(plain) * 1.4)
	# Distance: a peaker far away does not help.
	var far := PeakField.new()
	var crowd := _cluster("far", 12, Vector2.ZERO)
	far.step(10.0, [crowd])
	var other := _cluster("away", 12, Vector2(200, 200))
	far.active["away_npc_0"] = {"since": 10.0, "sid": ""}
	_check("contagion is LOCAL: a peaker 280 m away is no neighbour",
		PeakField._cell(Vector2(200, 200)).distance_to(PeakField._cell(Vector2.ZERO)) > 2.0)


func _test_hold() -> void:
	var f := PeakField.new()
	var c := _cluster("hold", 10, Vector2.ZERO)
	f.step(50.0, [c])
	f.active["hold_npc_0"] = {"since": 50.0, "sid": ""}
	var stop := c.duplicate(true)
	var sv: PackedByteArray = stop["vib"]
	sv[0] = 0
	stop["vib"] = sv   # packed arrays are values: write the copy back
	f.step(50.02, [stop])
	_check("a peak holds through MIN_HOLD_H even if the person stops vibing", f.is_peaking("hold_npc_0"))
	f.step(50.1, [stop])
	_check("...and rides a short GRACE_H past it (walking back to the same stage)", f.is_peaking("hold_npc_0"))
	f.step(50.25, [stop])
	_check("...then ends", not f.is_peaking("hold_npc_0"))
	var g := PeakField.new()
	var crowd := _cluster("thin", 10, Vector2.ZERO)
	g.step(50.0, [crowd])
	g.active["thin_npc_0"] = {"since": 50.0, "sid": ""}
	var alone := _cluster("thin", 1, Vector2.ZERO)
	g.step(50.1, [alone])
	g.step(50.25, [alone])
	_check("a peak ends when the crowd thins out", not g.is_peaking("thin_npc_0"))
	g.step(50.2, [_cluster("gone", 3, Vector2.ZERO)])
	_check("someone no longer on site is no longer peaking", g.peaking_count() == 0)


func _test_time_and_score() -> void:
	var a := PeakField.new()
	var b := PeakField.new()
	var c := _cluster("det", 16, Vector2.ZERO)
	_run(a, [c], 100.0, 2.0, 0.05)
	_run(b, [c], 100.0, 2.0, 0.05)
	_check("identical runs, identical peaks", a.total == b.total and a.active.keys() == b.active.keys())
	var total := a.total
	var active := a.peaking_count()
	a.step(101.0, [c])   # scrub back
	_check("a scrub back freezes the field (no score, nobody ends)", a.total == total and a.peaking_count() == active)
	a.step(115.0, [c])   # > CATCHUP_H forward
	_check("a long jump clears every peak without scoring", a.peaking_count() == 0 and a.total == total)
	_check("today's count and the best concurrent are kept", a.today(101.0) > 0 and a.best >= active)


func _test_persistence() -> void:
	var f := PeakField.new()
	f.total = 1284
	f.best = 46
	f.by_day = {4100: 120, 4101: 7}
	var path := "user://peak_selftest_tmp.json"
	_check("the score saves", f.save(path))
	var g := PeakField.new()
	_check("...and loads back exactly", g.load_from(path) and g.total == 1284 and g.best == 46
		and int(g.by_day.get(4100, 0)) == 120 and int(g.by_day.get(4101, 0)) == 7)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# The LIVE state rides along: a reloaded world picks its crowd up mid-peak.
	var h := PeakField.new()
	h.step(100.0, [])
	h.active = {"p1": {"since": 99.5, "sid": "stage", "lapse": 99.9}}
	h.charge = {"p2": 0.37}
	h.episode = {"p1": 2}
	h.save(path)
	var k := PeakField.new()
	k.load_from(path)
	_check("live peaks survive a reload", k.peaking_count() == 1
		and is_equal_approx(float(k.active["p1"]["since"]), 99.5) and str(k.active["p1"]["sid"]) == "stage"
		and is_equal_approx(float(k.active["p1"]["lapse"]), 99.9) and int(k.episode.get("p1", 0)) == 2)
	_check("charge survives a reload (the green outline)", is_equal_approx(float(k.charge.get("p2", 0.0)), 0.37))
	k.step(100.0 + PeakField.CATCHUP_H + 1.0, [])
	_check("a reload far from the saved hour drops the live state", k.peaking_count() == 0 and k.charge.is_empty())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check("a missing score file loads as nothing", not PeakField.new().load_from("user://nope_peak.json"))


func _test_tiers_and_packing() -> void:
	var c := CrowdCohort.new()
	c.configure(3, "vt", Vector2.ZERO)
	for i in 3:
		for k in 6:
			c.needs[i * 6 + k] = 0.1
		c.morale[i] = 0.8
	c.state[0] = CrowdCohort.S_DOING
	c.act[0] = CrowdCohort.A_ENRICH
	c.state[1] = CrowdCohort.S_DOING
	c.act[1] = CrowdCohort.A_SLEEP
	c.state[2] = CrowdCohort.S_DOING
	c.act[2] = CrowdCohort.A_ENRICH
	c.morale[2] = 0.5
	var inp := c.peak_inputs(0.0)
	var vib: PackedByteArray = inp["vib"]
	_check("light tier: at a venue with needs met and morale up = vibing; asleep or glum = not",
		vib[0] == 1 and vib[1] == 0 and vib[2] == 0)
	var a := NpcAgent.make("va_npc_0", Vector2.ZERO)
	a.state = NpcAgent.State.DOING
	a.activity = "enrichment"
	for n in a.needs:
		a.needs[n] = 0.1
	a.morale = 0.8
	var v1 := a.vibing()
	a.needs["thirst"] = 0.99
	_check("full tier: the same test (and a thirsty person is not vibing)", v1 and not a.vibing())
	var packed := NpcPeak.pack_mood(0.63, NAN)
	var pk := NpcPeak.pack_mood(0.9, 3.25)
	var u1 := NpcPeak.unpack_mood(packed)
	var u2 := NpcPeak.unpack_mood(pk)
	_check("mood packing round-trips (morale, and a peak's start)",
		absf(float(u1["morale"]) - 0.63) < 1e-6 and is_nan(float(u1["peak_rel"]))
		and absf(float(u2["peak_rel"]) - 3.25) < 1e-5)
	_check("a peak that began long before the time base still reads as a peak",
		not is_nan(float(NpcPeak.unpack_mood(NpcPeak.pack_mood(0.9, -50.0))["peak_rel"])))
	var withbuzz := NpcPeak.unpack_mood(NpcPeak.pack_mood(0.81, NAN, 0.5))
	_check("mood packing carries the buzz (31 steps) beside the morale",
		absf(float(withbuzz["buzz"]) - 16.0 / 31.0) < 1e-6 and absf(float(withbuzz["morale"]) - 0.81) < 1e-5
		and NpcPeak.pack_mood(1.0, NAN, 1.0) < NpcPeak.PEAK_ALPHA_MIN)


## The Fun Meter's needle (scenes/ui/fun_meter.gd): the mean mood across the
## six bands, pushed into the FUCK YES zone only by people actually peaking.
func _test_fun_meter() -> void:
	var fm: GDScript = load("res://scenes/ui/fun_meter.gd")
	var zone := float(fm.get("ZONE_FY")) if fm.get("ZONE_FY") != null else 0.86
	var happy: float = fm.call("needle_for", 1.0, 0.0)
	var glum: float = fm.call("needle_for", 0.2, 0.0)
	_check("the needle follows the mood and never reaches FUCK YES on mood alone (%.2f / %.2f)" % [glum, happy],
		glum < happy and happy <= zone + 1e-6)
	_check("a quarter of the crowd peaking pins it in the FUCK YES zone",
		float(fm.call("needle_for", 0.7, 0.25)) >= 0.999 and float(fm.call("needle_for", 0.7, 0.05)) > float(fm.call("needle_for", 0.7, 0.0)))


## The CHARGE toward a peak: what the shimmer and the meter show.
func _test_charge() -> void:
	# Thresholds are Exp(1) — that is what keeps the charge model a Poisson
	# onset with the same hazard as before.
	var sum := 0.0
	for i in 2000:
		sum += NpcPeak.threshold("thr_npc_%d" % i, 0)
	var mean := sum / 2000.0
	_check("thresholds are Exp(1): mean %.3f over 2000 people" % mean, mean > 0.9 and mean < 1.1)
	_check("a new episode draws a new threshold", NpcPeak.threshold("ep_npc_0", 0) != NpcPeak.threshold("ep_npc_0", 1))
	# A crowd fills; a lone person stays empty.
	var f := PeakField.new()
	var crowd := _cluster("bz", 20, Vector2.ZERO)
	var lone := _cluster("bzl", 1, Vector2(600, 600))
	_run(f, [crowd, lone], 10.0, 0.3, 0.05)
	var top := 0.0
	for id in (crowd["ids"] as PackedStringArray):
		if not f.is_peaking(id):
			top = maxf(top, f.buzz_of(id))
	_check("a vibing crowd builds charge toward FUCK YES (top %.2f); a lone person none" % top,
		top > 0.05 and f.buzz_of("bzl_npc_0") == 0.0)
	# A peaker FEEDS the people round them: they are flagged and fill faster.
	var g := PeakField.new()
	var h := PeakField.new()
	var cg := _cluster("fd", 12, Vector2.ZERO)
	g.step(10.0, [cg])
	h.step(10.0, [cg])
	g.active["fd_npc_0"] = {"since": 10.0, "sid": ""}
	g.step(10.1, [cg])
	h.step(10.1, [cg])
	_check("a peaker nearby feeds a neighbour's charge (fed by %d; %.4f vs %.4f alone)"
		% [g.fed_by("fd_npc_5"), float(g.charge.get("fd_npc_5", 0.0)), float(h.charge.get("fd_npc_5", 0.0))],
		g.fed_by("fd_npc_5") == 1 and float(g.charge.get("fd_npc_5", 0.0)) > float(h.charge.get("fd_npc_5", 0.0)) * 1.9)
	# The player's contagion multiplier.
	_check("contagion 0 = no spread (a peaker adds nothing); 2 = twice the boost",
		NpcPeak.rate_h(20, 3, 1.0, 0.0) == NpcPeak.rate_h(20, 0)
		and absf(NpcPeak.rate_h(20, 1, 1.0, 2.0) - NpcPeak.rate_h(20, 0) * 3.0) < 1e-9)
	var off := PeakField.new()
	off.contagion = 0.0
	off.step(10.0, [cg])
	off.active["fd_npc_0"] = {"since": 10.0, "sid": ""}
	off.step(10.1, [cg])
	_check("...and the field honours it", absf(float(off.charge.get("fd_npc_5", 0.0)) - float(h.charge.get("fd_npc_5", 0.0))) < 1e-12)
	# Out of the crowd the charge leaks away.
	var q := NpcPeak.charge_step(0.5, 0.0, NpcPeak.CHARGE_LEAK_H)
	_check("charge leaks away out of the crowd (%.3f after one time constant)" % q,
		absf(q - 0.5 / exp(1.0)) < 1e-9 and NpcPeak.charge_step(0.5, 2.0, 0.1) == 0.7)
