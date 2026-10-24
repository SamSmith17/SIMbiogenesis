extends SceneTree

## Headless self-test for the LIGHT population tier (core/population/
## crowd_cohort.gd, crowd_focus.gd, npc_tier_convert.gd): determinism,
## mass-exact billing, the EQUIVALENCE property against the full engine, the
## focus policy, tier conversion, queues, catch-up / scrub contracts, venue
## billing and the compact snapshot. Pure / offline. Run --import first.
##   godot --headless --path . --script core/population/crowd_cohort_selftest.gd
##
## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS, so the check COUNT is pinned.
const EXPECTED_CHECKS := 74

var _failures := 0
var _checks := 0


func _init() -> void:
	# The player's saved testing switches (user://pop_testing.cfg — "no
	# departures", "ideal supply" …) must not leak into the assertions.
	PopTestPrefs.reset_defaults()
	# A player's own names (Settings → NPC → Names) re-deal everyone's name.
	NpcDisplayPrefs.reset_custom_names_for_test()
	_test_configure_and_ids()
	_test_determinism()
	_test_mass_exact_billing()
	_test_daily_loop()
	_test_equivalence_with_full_engine()
	_test_festival_day_social()
	_test_resize_in_place()
	_test_weather_comfort()
	_test_dj_perform()
	_test_queue()
	_test_venue_billing()
	_test_scrub_and_catchup()
	_test_snapshot_roundtrip()
	_test_conversion()
	_test_focus_policy()
	_test_departures()
	_test_scale_bound()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)"
			% [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("CROWD COHORT SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("CROWD COHORT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


# --- fixtures ---------------------------------------------------------------

func _square(c: Vector2, half: float) -> Array:
	return [[c.x - half, c.y - half], [c.x + half, c.y - half], [c.x + half, c.y + half], [c.x - half, c.y + half]]


## A camp's worth of area spaces round the origin, positions cached.
func _site(with_shower: bool = true, caps: int = 30) -> SpaceRegistry:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(60, 0), 8)}, "kitchen", caps)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-60, 30), 8)}, "restroom", caps)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, 70), 8)}, "water_point", caps)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(0, -80), 8)}, "sleep", caps)
	if with_shower:
		reg.set_space_type({"kind": "area", "poly": _square(Vector2(-45, -45), 8)}, "shower", caps)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(55, 55), 8)}, "fire_circle", caps)
	_refresh(reg)
	return reg


func _refresh(reg: SpaceRegistry) -> void:
	reg.refresh_positions(func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null))


func _ctx(reg: SpaceRegistry, t: float) -> Dictionary:
	return {"registry": reg, "hour_of_day": fposmod(t, 24.0), "abs_hours": t}


## Run a cohort from t0 for `hours`, ticking every `step_h`; returns the
## integrated demand {kind: qty} and a trace string.
func _run(cohort: CrowdCohort, reg: SpaceRegistry, t0: float, hours: float,
		step_h: float, trace: bool = false) -> Dictionary:
	var totals := {}
	var tr := ""
	var t := t0
	cohort.tick(t, _ctx(reg, t))
	var end := t0 + hours
	while t < end - 1e-9:
		t = minf(t + step_h, end)
		var d := cohort.tick(t, _ctx(reg, t))
		for k in d:
			totals[k] = float(totals.get(k, 0.0)) + float(d[k]) * step_h
		if trace:
			for i in cohort.count():
				var p := cohort.pos_at(i, t)
				tr += "%d:%.2f,%.2f,%d,%d|" % [i, p.x, p.y, cohort.state[i], cohort.act[i]]
	return {"totals": totals, "trace": tr}


# --- tests ------------------------------------------------------------------

func _test_configure_and_ids() -> void:
	var c := CrowdCohort.new()
	c.configure(12, "hab_a", Vector2(10, 20))
	_check("ids follow the engine's scheme", c.ids[0] == "hab_a_npc_0" and c.ids[11] == "hab_a_npc_11")
	_check("everyone alive, un-enriched, at full count", c.alive_count() == 12
		and absf(c.needs[5] - 1.0) < 1e-6 and c.count() == 12)
	var e := NpcPopulationEngine.new()
	e.configure(12, "hab_a", Vector2(10, 20))
	var same_needs := true
	for k in 6:
		if absf(c.needs[3 * 6 + k] - float((e.agents[3] as NpcAgent).needs[NpcAgent.NEEDS[k]])) > 1e-6:
			same_needs = false
	_check("initial needs match the full engine's seeding", same_needs)
	_check("agent_index finds people", c.agent_index("hab_a_npc_7") == 7 and c.agent_index("nope") == -1)


func _test_determinism() -> void:
	var a := CrowdCohort.new()
	a.configure(40, "det", Vector2.ZERO)
	var b := CrowdCohort.new()
	b.configure(40, "det", Vector2.ZERO)
	var ra := _run(a, _site(), 8.0, 48.0, 1.0 / 30.0, true)
	var rb := _run(b, _site(), 8.0, 48.0, 1.0 / 30.0, true)
	_check("two identical runs produce identical traces", ra["trace"] == rb["trace"]
		and ra["trace"].length() > 1000)
	_check("…and identical totals", JSON.stringify(ra["totals"]) == JSON.stringify(rb["totals"]))


func _test_mass_exact_billing() -> void:
	# One hungry person next to the kitchen: the integrated demand over the
	# meal equals the activity's rate × its duration, whatever the cadence.
	var reg := _site()
	for cadence in [1.0 / 60.0, 0.25]:
		var c := CrowdCohort.new()
		c.configure(1, "solo", Vector2(52, 0))
		c.needs[0] = 0.9   # hunger
		c.needs[1] = 0.0
		c.needs[2] = 0.0
		c.needs[3] = 0.0
		c.needs[4] = 0.0
		var r := _run(c, reg, 10.0, 1.5, float(cadence))
		var food := float((r["totals"] as Dictionary).get("food", 0.0))
		# duration 0.5 h × (0.85..1.25) at 1 kg/h
		_check("meal billed mass-exactly at cadence %.3f" % float(cadence),
			food >= 0.5 * 0.85 - 1e-4 and food <= 0.5 * 1.25 + 1e-4, "food=%.4f" % food)


func _test_daily_loop() -> void:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(8, "day", Vector2.ZERO)
	var saw_food := false
	var saw_water := false
	var asleep := 0
	var t := 8.0
	c.tick(t, _ctx(reg, t))
	while t < 32.0:
		t += 1.0 / 60.0
		var d := c.tick(t, _ctx(reg, t))
		saw_food = saw_food or float(d.get("food", 0.0)) > 0.0
		saw_water = saw_water or float(d.get("water", 0.0)) > 0.0
		if fposmod(t, 24.0) > 23.9 and fposmod(t, 24.0) < 23.92:
			for i in c.count():
				if c.state[i] == CrowdCohort.S_DOING and c.act[i] == CrowdCohort.A_SLEEP:
					asleep += 1
	_check("people ate (food demand seen)", saw_food)
	_check("people drank / toileted (water demand seen)", saw_water)
	_check("most people asleep at 23:55", asleep >= 5, "asleep=%d" % asleep)
	var pinned := 0
	for i in c.count():
		for k in 5:
			if c.needs[i * 6 + k] >= 0.999:
				pinned += 1
	_check("no critical / comfort need pinned when supplied", pinned == 0, "pinned=%d" % pinned)
	var s := c.summary()
	_check("summary carries the dashboard keys", s.has("mean_morale") and s.has("morale_bands")
		and s.has("activities") and str(s["tier"]) == "light" and int(s["count"]) == 8)
	_check("dots carry the host's keys", (c.agent_dots()[0] as Dictionary).has("face_yaw")
		and (c.agent_dots()[0] as Dictionary).has("status") and c.agent_dots().size() == 8)


## THE property the tier exists to hold: a camp consumes and feels the same
## whichever tier simulates it.
func _test_equivalence_with_full_engine() -> void:
	var days := 3.0
	var step := 1.0 / 30.0
	# Full engine.
	var reg_f := _site()
	var e := NpcPopulationEngine.new()
	e.configure(24, "eq", Vector2.ZERO)
	var pos_of := func(space: Dictionary) -> Variant:
		return reg_f.resolve_position(space, null)
	var tot_f := {}
	var t := 8.0
	e.tick(t, {"registry": reg_f, "pos_of": pos_of, "hour_of_day": 8.0})
	while t < 8.0 + days * 24.0 - 1e-9:
		t += step
		var d := e.tick(t, {"registry": reg_f, "pos_of": pos_of, "hour_of_day": fposmod(t, 24.0)})
		for k in d:
			tot_f[k] = float(tot_f.get(k, 0.0)) + float(d[k]) * step
	# Light crowd.
	var reg_l := _site()
	var c := CrowdCohort.new()
	c.configure(24, "eq", Vector2.ZERO)
	var r := _run(c, reg_l, 8.0, days * 24.0, step)
	var tot_l: Dictionary = r["totals"]
	for kind in ["water", "food"]:
		var f := float(tot_f.get(kind, 0.0))
		var l := float(tot_l.get(kind, 0.0))
		var rel := absf(f - l) / maxf(f, 1e-6)
		_check("%s over %d days within 6 %% of the full engine" % [kind, int(days)], rel <= 0.06,
			"full=%.1f light=%.1f (%.1f %%)" % [f, l, rel * 100.0])
	var mf := e.mean_morale()
	var ml := c.mean_morale()
	_check("mean morale within 0.08 of the full engine", absf(mf - ml) <= 0.08,
		"full=%.3f light=%.3f" % [mf, ml])
	# The light tier gathers a little less often (it re-plans at events, the
	# full tier every substep while idle), so the two can straddle a band
	# boundary; they must never be a whole band apart.
	_check("morale within one band", absi(NpcMorale.band(mf) - NpcMorale.band(ml)) <= 1,
		"full=%s light=%s" % [NpcMorale.label(mf), NpcMorale.label(ml)])
	_check("nobody left in either tier", e.agents.size() == 24 and c.alive_count() == 24)
	# A site with NO shower blocks hygiene in both tiers — it must not block
	# the light tier's critical loop (the stall the full tier once had).
	var reg_ns := _site(false)
	var c2 := CrowdCohort.new()
	c2.configure(10, "ns", Vector2.ZERO)
	var r2 := _run(c2, reg_ns, 8.0, 48.0, step)
	_check("no shower: people still eat and drink", float((r2["totals"] as Dictionary).get("food", 0.0)) > 1.0
		and float((r2["totals"] as Dictionary).get("water", 0.0)) > 50.0)


## The FESTIVAL day: its leisure blocks are SOCIAL (NpcSocial), not FREE. The
## two tiers must still agree on what a camp consumes and how it feels, and
## during the SOCIAL hours almost nobody may be standing idle — the bug was a
## whole festival standing where it had last eaten from late morning to dinner.
func _test_festival_day_social() -> void:
	var days := 3.0
	var step := 1.0 / 30.0
	var reg_f := _site()
	reg_f.set_space_type({"kind": "area", "poly": _square(Vector2(-70, -60), 10)}, "center_camp", 0)
	_refresh(reg_f)
	var e := NpcPopulationEngine.new()
	e.configure(24, "fq", Vector2.ZERO)
	e.routine = NpcRoutine.festival_day()
	var pos_of := func(space: Dictionary) -> Variant:
		return reg_f.resolve_position(space, null)
	var tot_f := {}
	var idle_f := 0
	var samples_f := 0
	var t := 8.0
	var ctx_f := func(tt: float) -> Dictionary:
		return {"registry": reg_f, "pos_of": pos_of, "hour_of_day": fposmod(tt, 24.0),
			"camp_home": Vector2.ZERO, "camp_seed": "fq"}
	e.tick(t, ctx_f.call(t))
	while t < 8.0 + days * 24.0 - 1e-9:
		t += step
		var d := e.tick(t, ctx_f.call(t))
		for k in d:
			tot_f[k] = float(tot_f.get(k, 0.0)) + float(d[k]) * step
		var h := fposmod(t, 24.0)
		if (h > 11.0 and h < 12.5) or (h > 14.5 and h < 17.5):
			for a in e.agents:
				samples_f += 1
				if (a as NpcAgent).state != NpcAgent.State.TRAVELING and (a as NpcAgent).activity.is_empty():
					idle_f += 1
	var reg_l := _site()
	reg_l.set_space_type({"kind": "area", "poly": _square(Vector2(-70, -60), 10)}, "center_camp", 0)
	_refresh(reg_l)
	var c := CrowdCohort.new()
	c.configure(24, "fq", Vector2.ZERO)
	c.routine = NpcRoutine.festival_day()
	var tot_l := {}
	var idle_l := 0
	var mingle_l := 0
	var samples_l := 0
	t = 8.0
	var ctx_l := func(tt: float) -> Dictionary:
		var cx := _ctx(reg_l, tt)
		cx["routine"] = c.routine
		return cx
	c.tick(t, ctx_l.call(t))
	while t < 8.0 + days * 24.0 - 1e-9:
		t += step
		var d2 := c.tick(t, ctx_l.call(t))
		for k in d2:
			tot_l[k] = float(tot_l.get(k, 0.0)) + float(d2[k]) * step
		var h2 := fposmod(t, 24.0)
		if (h2 > 11.0 and h2 < 12.5) or (h2 > 14.5 and h2 < 17.5):
			for i in c.count():
				samples_l += 1
				if c.state[i] == CrowdCohort.S_DOING and c.act[i] == CrowdCohort.A_FREE:
					idle_l += 1
				if c.act[i] == CrowdCohort.A_MINGLE:
					mingle_l += 1
	# Looser than the default-day pin above, ON PURPOSE and measured: the
	# festival day was never equivalence-pinned, and when this test first ran
	# (with the old FREE blocks) the tiers were already 10 % / 0.106 morale
	# apart. Serving festival meal blocks once (NpcRoutine.serves_once) and a
	# routine-aware wake hour brought food to ~8 % and water to ~12 %; what is
	# left is the tiers' different moments of re-deciding inside short blocks.
	# A regression past these bounds is real; closing them is open work.
	for kind in ["water", "food"]:
		var f := float(tot_f.get(kind, 0.0))
		var l := float(tot_l.get(kind, 0.0))
		var rel := absf(f - l) / maxf(f, 1e-6)
		_check("festival day: %s within 15 %% across tiers" % kind, rel <= 0.15,
			"full=%.1f light=%.1f (%.1f %%)" % [f, l, rel * 100.0])
	var mf := e.mean_morale()
	var ml := c.mean_morale()
	_check("festival day: morale within 0.15 across tiers", absf(mf - ml) <= 0.15,
		"full=%.3f light=%.3f" % [mf, ml])
	var per_day := float(tot_f.get("food", 0.0)) / (24.0 * days)
	_check("festival day: about three meals a day (%.2f kg/person/day)" % per_day,
		per_day > 1.2 and per_day < 2.0)
	var share_f := float(idle_f) / maxf(float(samples_f), 1.0)
	var share_l := float(idle_l) / maxf(float(samples_l), 1.0)
	_check("SOCIAL hours: under 10 %% idle in the full tier", share_f < 0.10, "%.1f %%" % (share_f * 100.0))
	_check("SOCIAL hours: under 10 %% idle in the light tier", share_l < 0.10, "%.1f %%" % (share_l * 100.0))
	_check("SOCIAL hours: people actually mingle (light)", mingle_l > samples_l / 10,
		"%d of %d samples" % [mingle_l, samples_l])
	var mx := NpcSocial.mingle_spot("fq_npc_3", "fq", Vector2.ZERO, 12.2)
	_check("a mingle seat sits on a circle near camp, facing its middle",
		(mx["pos"] as Vector2).length() < NpcSocial.HANGOUT_R_M + 3.0
		and (mx["pos"] as Vector2).distance_to(mx["face"]) < 3.0)


## Weather as an attractor (NpcComfort), in BOTH tiers: a scorching sunny
## afternoon sends a large share of a festival camp into the shade, nobody
## goes on a mild one, and the two tiers send about the same share (they ask
## the same hashed question of the same friend groups).
func _test_weather_comfort() -> void:
	var hot := func(tt: float) -> Dictionary:
		var h := fposmod(tt, 24.0)
		var ghi := maxf(0.0, sin((h - 6.0) / 13.0 * PI)) * 950.0 if h > 6.0 and h < 19.0 else 0.0
		return NpcComfort.pulls({"temp_c": 39.0, "ghi_wm2": ghi, "rain_mmh": 0.0}, h)
	var shade_at := Vector2(30.0, -20.0)
	var spot_fn := func(kind: String, _from: Vector2, aid: String) -> Dictionary:
		if kind != NpcComfort.KIND_SHADE:
			return {}
		return NpcComfort.seat_under({"pos": shade_at, "yaw": 0.0, "size": Vector3(10.0, 3.0, 10.0)}, aid)
	var step := 1.0 / 30.0
	# Full tier.
	var reg_f := _site()
	var e := NpcPopulationEngine.new()
	e.configure(40, "hc", Vector2.ZERO)
	e.routine = NpcRoutine.festival_day()
	var pos_of := func(space: Dictionary) -> Variant:
		return reg_f.resolve_position(space, null)
	var t := 9.0
	var ctx_f := func(tt: float) -> Dictionary:
		return {"registry": reg_f, "pos_of": pos_of, "hour_of_day": fposmod(tt, 24.0),
			"camp_home": Vector2.ZERO, "camp_seed": "hc", "comfort": hot.call(tt), "comfort_spot": spot_fn}
	e.tick(t, ctx_f.call(t))
	var shade_f := 0
	var n_f := 0
	while t < 17.0:
		t += step
		e.tick(t, ctx_f.call(t))
		if t > 13.0 and t < 16.0:
			for a in e.agents:
				n_f += 1
				if (a as NpcAgent)._comfort == NpcComfort.KIND_SHADE:
					shade_f += 1
	# Light tier.
	var reg_l := _site()
	var c := CrowdCohort.new()
	c.configure(40, "hc", Vector2.ZERO)
	c.routine = NpcRoutine.festival_day()
	t = 9.0
	var ctx_l := func(tt: float) -> Dictionary:
		var cx := _ctx(reg_l, tt)
		cx["routine"] = c.routine
		cx["comfort"] = hot.call(tt)
		cx["comfort_spot"] = spot_fn
		return cx
	c.tick(t, ctx_l.call(t))
	var shade_l := 0
	var n_l := 0
	var under := 0
	while t < 17.0:
		t += step
		c.tick(t, ctx_l.call(t))
		if t > 13.0 and t < 16.0:
			for i in c.count():
				n_l += 1
				if c.act[i] == CrowdCohort.A_MINGLE and (c.ckind[i] & 3) == 1:
					shade_l += 1
					if c.state[i] == CrowdCohort.S_DOING and c.pos_at(i, t).distance_to(shade_at) < 7.0:
						under += 1
	var sf := float(shade_f) / maxf(float(n_f), 1.0)
	var sl := float(shade_l) / maxf(float(n_l), 1.0)
	_check("a scorching afternoon sends many into the shade (full %.0f %%)" % (sf * 100.0), sf > 0.25)
	_check("... and in the light tier (%.0f %%)" % (sl * 100.0), sl > 0.25)
	_check("both tiers send about the same share (%.2f vs %.2f)" % [sf, sl], absf(sf - sl) < 0.2)
	_check("the light tier's shade-seekers actually stand under it", under > 0)
	var mild := NpcComfort.pulls({"temp_c": 22.0, "ghi_wm2": 900.0, "rain_mmh": 0.0}, 14.0)
	_check("a mild sunny afternoon pulls nobody into the shade", NpcComfort.is_calm(mild))


## The DJ (the bridge casts one per live stage): both tiers walk the cast
## person to the decks, hold them there with the DJ pose ON the deck until
## the set ends, then let them go.
func _test_dj_perform() -> void:
	var reg := _site()
	var spot := {"pos": Vector2(20.0, 10.0), "face": Vector2(20.0, 30.0), "elev": 1.1, "sid": "s"}
	var c := CrowdCohort.new()
	c.configure(8, "dj", Vector2.ZERO)
	c.routine = NpcRoutine.festival_day()
	var t := 20.0
	c.tick(t, _ctx(reg, t))
	var who := c.ids[3]
	_check("light: the cast is accepted", c.perform(who, spot, t + 1.0, t, _ctx(reg, t)))
	_check("light: they are performing (on the way)", c.is_performing(who))
	while t < 20.6:
		t += 0.05
		c.tick(t, _ctx(reg, t))
	var i := c.agent_index(who)
	_check("light: at the decks with the DJ pose, %.1f m up" % c.elev_of(i),
		c.state[i] == CrowdCohort.S_DOING and c.pose_code(i) == CrowdCohort.POSE_DJ
		and absf(c.elev_of(i) - 1.1) < 1e-4 and c.pos_at(i, t).distance_to(spot["pos"]) < 0.5)
	while t < 21.3:
		t += 0.05
		c.tick(t, _ctx(reg, t))
	_check("light: the set over, they come down", not c.is_performing(who) and c.elev_of(i) == 0.0)
	var e := NpcPopulationEngine.new()
	e.configure(6, "djf", Vector2.ZERO)
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var ctx := func(tt: float) -> Dictionary:
		return {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(tt, 24.0)}
	t = 20.0
	e.tick(t, ctx.call(t))
	e.tick(t + 0.05, ctx.call(t + 0.05))
	t += 0.05
	var aid := (e.agents[2] as NpcAgent).id
	_check("full: the cast is accepted", e.perform(aid, spot, t + 1.0))
	while t < 20.6:
		t += 0.05
		e.tick(t, ctx.call(t))
	var a := e.find_agent(aid)
	_check("full: on the deck DJing", a.activity == NpcAgent.PERFORM_ACTIVITY
		and a.state == NpcAgent.State.DOING and absf(a.elev() - 1.1) < 1e-4
		and a.venue_pose == VenueCrowd.POSE_DJ)
	while t < 21.3:
		t += 0.05
		e.tick(t, ctx.call(t))
	_check("full: the set over, they come down", a.activity != NpcAgent.PERFORM_ACTIVITY and a.elev() == 0.0)


## The festival population slider resizes a roster IN PLACE: survivors keep
## exactly where they are and what they feel; new people get configure()'s ids.
func _test_resize_in_place() -> void:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(20, "rs", Vector2.ZERO)
	_run(c, reg, 8.0, 6.0, 1.0 / 30.0)
	var before := []
	for i in 10:
		before.append([c.ids[i], c.pos_at(i, 14.0), c.morale[i], c.needs[i * 6]])
	c.resize(10, reg)
	var same := c.count() == 10
	for i in 10:
		var b: Array = before[i]
		same = same and c.ids[i] == str(b[0]) and c.pos_at(i, 14.0) == (b[1] as Vector2) \
			and is_equal_approx(c.morale[i], float(b[2])) and is_equal_approx(c.needs[i * 6], float(b[3]))
	_check("shrinking keeps the survivors exactly", same)
	c.resize(30, reg)
	_check("growing appends configure()'s ids", c.count() == 30 and c.ids[29] == "rs_npc_29"
		and c.alive_count() == 30)
	var r := _run(c, reg, 14.0, 4.0, 1.0 / 30.0)
	_check("the grown crowd simulates (water billed)", float((r["totals"] as Dictionary).get("water", 0.0)) > 1.0)
	var e := NpcPopulationEngine.new()
	e.configure(12, "rs", Vector2.ZERO)
	var keep_pos := (e.agents[3] as NpcAgent).pos
	e.resize(6, "rs", Vector2.ZERO, reg)
	_check("full tier shrinks to the lowest ids", e.agents.size() == 6
		and (e.agents[3] as NpcAgent).id == "rs_npc_3" and (e.agents[3] as NpcAgent).pos == keep_pos)
	e.resize(9, "rs", Vector2.ZERO, reg)
	var ids := {}
	for a in e.agents:
		ids[(a as NpcAgent).id] = true
	_check("full tier grows with unique ids", e.agents.size() == 9 and ids.size() == 9)


func _test_queue() -> void:
	# Capacity-2 restroom, 6 people who all need it: everyone is served, the
	# order is deterministic, and at most 2 are inside at once.
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(20, 0), 4)}, "restroom", 2)
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-80, 0), 4)}, "sleep", 10)
	_refresh(reg)
	var c := CrowdCohort.new()
	c.configure(6, "q", Vector2.ZERO)
	for i in 6:
		for k in 6:
			c.needs[i * 6 + k] = 0.0
		c.needs[i * 6 + 2] = 0.9   # bladder
	var t := 10.0
	c.tick(t, _ctx(reg, t))
	var max_inside := 0
	var queued_seen := 0
	var served := {}
	for _s in 120:
		t += 0.5 / 60.0
		c.tick(t, _ctx(reg, t))
		var inside := 0
		for i in 6:
			if c.state[i] == CrowdCohort.S_DOING and c.act[i] == CrowdCohort.A_BLADDER:
				inside += 1
				served[i] = true
			if c.state[i] == CrowdCohort.S_QUEUE:
				queued_seen += 1
		max_inside = maxi(max_inside, inside)
	_check("a full space makes people queue", queued_seen > 0)
	_check("never more inside than the capacity", max_inside <= 2, "max=%d" % max_inside)
	_check("everyone is served in the end", served.size() == 6, "served=%d" % served.size())
	_check("occupancy is released after the visit", reg.occupant_count(reg.spaces[0]["id"]) == 0)


func _test_venue_billing() -> void:
	# A restroom bound to a blackwater tank bills the TANK, not the camp.
	var reg := SpaceRegistry.create_empty()
	var sid := reg.set_space_type({"kind": "area", "poly": _square(Vector2(20, 0), 4)}, "restroom", 10)
	reg.set_space_fields(sid, {"graph_item_id": "tank_black"})
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-80, 0), 4)}, "sleep", 10)
	_refresh(reg)
	var c := CrowdCohort.new()
	c.configure(3, "vb", Vector2.ZERO)
	for i in 3:
		for k in 6:
			c.needs[i * 6 + k] = 0.0
		c.needs[i * 6 + 2] = 0.9
	var r := _run(c, reg, 10.0, 1.0, 1.0 / 60.0)
	var flows := c.take_venue_flows()
	_check("a bound portapotty bank receives blackwater", flows.has("tank_black")
		and absf(float((flows["tank_black"] as Dictionary).get("blackwater", 0.0)) - 3.0 * CrowdCohort.PORTAPOTTY_BLACKWATER_L) < 1e-6,
		str(flows))
	_check("…and the camp is not billed flush water", float((r["totals"] as Dictionary).get("water", 0.0)) < 1e-6)
	_check("flows are taken once", c.take_venue_flows().is_empty())


func _test_scrub_and_catchup() -> void:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(10, "sc", Vector2.ZERO)
	_run(c, reg, 8.0, 3.0, 1.0 / 30.0)
	var before := c.needs.duplicate()
	var d := c.tick(9.0, _ctx(reg, 9.0))   # backward
	_check("scrub back: empty demand, needs frozen", d.is_empty() and c.needs == before)
	var jump := c.tick(40.0, _ctx(reg, 40.0))   # +31 h in one tick
	_check("a >6 h jump takes the coarse path (empty demand, everyone idle)", jump.is_empty()
		and c.state[0] == CrowdCohort.S_IDLE and c._catchups == 1)
	var ok := true
	for i in c.count():
		for k in 5:
			var v := c.needs[i * 6 + k]
			if v < 0.0 or v > 0.6:
				ok = false
	_check("catch-up lands needs mid-cycle (coped, not neglected)", ok)
	# Starved supply is exempt: the need keeps rising through the jump.
	var c2 := CrowdCohort.new()
	c2.configure(2, "st", Vector2.ZERO)
	c2.set_starved(["water"])
	c2.tick(8.0, _ctx(reg, 8.0))
	c2.needs[1] = 0.3
	c2.tick(20.0, _ctx(reg, 20.0))
	_check("a starved need keeps rising through a jump", c2.needs[1] >= 0.99, "thirst=%.2f" % c2.needs[1])


func _test_snapshot_roundtrip() -> void:
	var reg := _site()
	var c := CrowdCohort.new()
	c.configure(30, "snap", Vector2(5, 5))
	_run(c, reg, 8.0, 6.0, 1.0 / 30.0)
	var snap := c.snapshot(14.0)
	var json := JSON.stringify(snap)
	_check("snapshot is compact (< 80 B per person)", json.length() < 80 * 30 + 400, "%d bytes" % json.length())
	var back := CrowdCohort.new()
	back.restore(JSON.parse_string(json))
	_check("restore: count, ids, positions, needs, morale survive",
		back.count() == 30 and back.ids[29] == "snap_npc_29"
		and absf(back.needs[7 * 6 + 1] - clampf(c.needs[7 * 6 + 1] + c._need_rate(7, 1) * maxf(14.0 - c.need_t[7], 0.0), 0.0, 1.0)) < 1e-4
		and absf(back.morale[3] - c.morale[3]) < 1e-6
		and back.pos_at(5, 14.0).distance_to(c.pos_at(5, 14.0)) < 1e-3)
	_check("restored people are IDLE and re-plan (no billing for the gap)",
		back.state[0] == CrowdCohort.S_IDLE and back.tick(14.5, _ctx(reg, 14.5)).is_empty())
	_check("is_light_snapshot discriminates", CrowdCohort.is_light_snapshot(snap)
		and not CrowdCohort.is_light_snapshot({"agents": []}))


func _test_conversion() -> void:
	var reg := _site()
	var e := NpcPopulationEngine.new()
	e.configure(12, "cv", Vector2.ZERO)
	var pos_of := func(space: Dictionary) -> Variant:
		return reg.resolve_position(space, null)
	var t := 8.0
	e.tick(t, {"registry": reg, "pos_of": pos_of, "hour_of_day": 8.0})
	for _s in 90:
		t += 1.0 / 30.0
		e.tick(t, {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t, 24.0)})
	var a3: NpcAgent = e.agents[3]
	var c := NpcTierConvert.to_light(e, reg, Vector2.ZERO)
	_check("to_light keeps ids, positions, needs, morale", c.ids[3] == a3.id
		and Vector2(c.ax[3], c.az[3]).distance_to(a3.pos) < 1e-4
		and absf(c.needs[3 * 6 + 1] - float(a3.needs["thirst"])) < 1e-6
		and absf(c.morale[3] - a3.morale) < 1e-6)
	var claims := 0
	for s in reg.spaces:
		claims += reg.occupant_count(str((s as Dictionary)["id"]))
	_check("to_light releases every registry claim", claims == 0, "claims=%d" % claims)
	_run(c, reg, t, 2.0, 1.0 / 30.0)
	var e2 := NpcTierConvert.to_full(c, NpcPopulationEngine.new(), reg)
	_check("to_full rebuilds the roster from the crowd", e2.agents.size() == 12
		and (e2.agents[3] as NpcAgent).id == "cv_npc_3"
		and absf((e2.agents[3] as NpcAgent).morale - c.morale[3]) < 1e-6
		and (e2.agents[3] as NpcAgent).state == NpcAgent.State.IDLE)
	var t2 := t + 2.0
	e2.tick(t2, {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t2, 24.0)})
	var d := e2.tick(t2 + 0.1, {"registry": reg, "pos_of": pos_of, "hour_of_day": fposmod(t2 + 0.1, 24.0)})
	_check("the promoted engine runs on", d is Dictionary)


func _test_focus_policy() -> void:
	var camps := [
		{"id": "a", "home": Vector2(0, 0), "count": 60},
		{"id": "b", "home": Vector2(300, 0), "count": 60},
		{"id": "c", "home": Vector2(600, 0), "count": 60},
	]
	var small := [{"id": "a", "home": Vector2(0, 0), "count": 60}]
	var pend := {}
	var t1 := CrowdFocus.decide(small, Vector2(900, 0), "", {}, pend, 0.0)
	_check("a site inside the budget is FULL everywhere (today's maps unchanged)",
		str(t1["a"]) == CrowdFocus.TIER_FULL)
	var t2 := CrowdFocus.decide(camps, Vector2(10, 0), "", {}, pend, 0.0)
	_check("over budget: the camp you stand in is full, the rest light",
		str(t2["a"]) == CrowdFocus.TIER_FULL and str(t2["b"]) == CrowdFocus.TIER_LIGHT
		and str(t2["c"]) == CrowdFocus.TIER_LIGHT)
	var t3 := CrowdFocus.decide(camps, Vector2(10, 0), "c", t2, pend, 0.0)
	var t3b := CrowdFocus.decide(camps, Vector2(10, 0), "c", t3, pend, 1.0)
	_check("a watched camp is promoted (after the hysteresis)",
		str(t3b["c"]) == CrowdFocus.TIER_FULL and str(t3b["a"]) == CrowdFocus.TIER_FULL)
	var t4 := CrowdFocus.decide(camps, Vector2(130, 0), "", t2, pend, 0.0)
	_check("walking just past the line does not demote at once (hysteresis)",
		str(t4["a"]) == CrowdFocus.TIER_FULL)
	var t5 := CrowdFocus.decide(camps, Vector2(300, 0), "", t4, pend, 0.0)
	var t6 := CrowdFocus.decide(camps, Vector2(300, 0), "", t5, pend, 1.0)
	_check("…but a real move swaps the focus", str(t6["b"]) == CrowdFocus.TIER_FULL
		and str(t6["a"]) == CrowdFocus.TIER_LIGHT)


func _test_departures() -> void:
	# No water anywhere, supply starved: thirst blocks, morale falls, people
	# leave, the collapse fires — the same cascade as the full tier.
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type({"kind": "area", "poly": _square(Vector2(-80, 0), 4)}, "sleep", 10)
	_refresh(reg)
	var c := CrowdCohort.new()
	c.configure(10, "dep", Vector2.ZERO)
	c.set_starved(["water", "food"])
	var left := [0]
	var collapsed := [false]
	c.agent_departed.connect(func(_a, _n, _r): left[0] += 1)
	c.colony_collapsed.connect(func(): collapsed[0] = true)
	_run(c, reg, 8.0, 24.0 * 6.0, 0.1)
	_check("starved people leave", left[0] > 0, "left=%d" % left[0])
	_check("the collapse fires below the floor", collapsed[0] and c.has_collapsed())
	_check("alive count tracks departures", c.alive_count() == 10 - left[0])


func _test_scale_bound() -> void:
	# 2000 people, one sim-day at 0.1 h ticks: must finish in bounded time.
	var reg := _site(true, 400)
	var c := CrowdCohort.new()
	c.configure(2000, "big", Vector2.ZERO)
	var t_start := Time.get_ticks_msec()
	var r := _run(c, reg, 8.0, 24.0, 0.1)
	var ms := Time.get_ticks_msec() - t_start
	print("  crowd: 2000 people × 1 sim-day at 0.1 h ticks = %d ms (%.2f ms per tick)" % [ms, float(ms) / 240.0])
	_check("2000 people × 1 day runs (bounded)", ms < 60000, "%d ms" % ms)
	_check("…and they ate", float((r["totals"] as Dictionary).get("food", 0.0)) > 100.0)
