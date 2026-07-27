extends SceneTree
## Offline deterministic selftest for the NPC population subsystem
## (core/population/): SpaceTypes vocabulary, SpaceRegistry tagging/queries/
## occupancy/persistence. Agent sim coverage grows with each phase.
## Run: Godot.exe.exe --headless --path . --script core/population/npc_population_selftest.gd
## (run --import first so the class_names register).

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _init() -> void:
	_test_space_types()
	_test_identity_and_readouts()
	_test_registry_crud()
	_test_registry_queries()
	_test_registry_occupancy()
	_test_registry_persistence()
	_test_nav()
	_test_agent_daily_loop()
	_test_determinism()
	_test_starvation_block()
	_test_scrub_and_catchup()
	_test_engine_snapshot()
	# --- Tier 2 ---
	_test_morale_math()
	_test_morale_supplied_vs_starved()
	_test_enrichment_ceiling()
	_test_departure_and_collapse()
	_test_weather_gate()
	_test_chore_board()
	_test_chore_priority()

	if _fails == 0:
		print("NPC POPULATION SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("NPC POPULATION SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


# --- SpaceTypes -------------------------------------------------------------

func _test_space_types() -> void:
	for t in SpaceTypes.TYPES:
		_check("label for %s" % t, not SpaceTypes.label(str(t)).is_empty())
		_check("%s valid" % t, SpaceTypes.is_valid(str(t)))
		_check("color for %s" % t, SpaceTypes.COLORS.has(t))
		_check("icon for %s" % t, SpaceTypes.ICONS.has(t))
	_check("bogus type invalid", not SpaceTypes.is_valid("discotheque"))
	# Every need must map to a real space type, and every mapped space must be
	# a declared type — the two tables cannot drift apart.
	for need in SpaceTypes.NEED_TO_SPACE:
		_check("need %s maps to a valid space" % need,
				SpaceTypes.is_valid(str(SpaceTypes.NEED_TO_SPACE[need])))
	for need in NpcAgent.NEEDS:
		_check("need %s has an activity" % need, NpcAgent.ACTIVITIES.has(need))
		_check("need %s has a rise rate" % need, NpcAgent.RISE_PER_H.has(need))
		_check("need %s has a threshold" % need, NpcAgent.THRESHOLD.has(need))
		_check("need %s has a space" % need, SpaceTypes.NEED_TO_SPACE.has(need))
		var act: Dictionary = NpcAgent.ACTIVITIES[need]
		_check("activity %s targets a real space" % need,
				SpaceTypes.is_valid(str(act.get("space", ""))))


func _test_identity_and_readouts() -> void:
	# Names are deterministic and unique across a 50-person roster.
	var seen := {}
	for i in 50:
		var n := NpcAgent.name_for("hab_npc_%d" % i)
		_check("name non-empty %d" % i, not n.is_empty())
		seen[n] = true
	_check("50 agents get distinct names", seen.size() == 50, "got %d" % seen.size())
	_check("name is stable", NpcAgent.name_for("hab_npc_3") == NpcAgent.name_for("hab_npc_3"))

	var a := NpcAgent.make("hab_npc_3", Vector2.ZERO)
	_check("agent carries display_name", a.display_name == NpcAgent.name_for("hab_npc_3"))
	_check("idle status", a.status_line() == "idle" or a.status_line().begins_with("waiting"))
	a.state = NpcAgent.State.DOING
	a.activity = "hunger"
	_check("eating status mentions kitchen", a.status_line().contains("Kitchen"), a.status_line())
	a.state = NpcAgent.State.TRAVELING
	a.activity = "hygiene"
	_check("traveling status names destination",
			a.status_line().begins_with("heading to") and a.status_line().contains("Shower"),
			a.status_line())
	a.state = NpcAgent.State.DOING
	a.activity = "sleep"
	_check("asleep status", a.status_line() == "asleep")
	# A desperate, unmet need reads as waiting rather than idle.
	var b := NpcAgent.make("hab_npc_9", Vector2.ZERO)
	b.needs["thirst"] = 1.0
	b.needs["hunger"] = 0.0
	b.needs["bladder"] = 0.0
	b.needs["sleep"] = 0.0
	b.needs["hygiene"] = 0.0
	_check("blocked agent reads as waiting", b.status_line().begins_with("waiting"), b.status_line())


# --- SpaceRegistry CRUD -----------------------------------------------------

func _prop_target(pid: String) -> Dictionary:
	return {"kind": "prop", "prop_id": pid}


func _test_registry_crud() -> void:
	var reg := SpaceRegistry.create_empty()
	_check("empty on create", reg.spaces.is_empty())

	var id1 := reg.set_space_type(_prop_target("pp_1"), "restroom", 3)
	_check("tag creates record", not id1.is_empty())
	_check("record findable", reg.find_by_id(id1).get("space_type") == "restroom")
	_check("capacity stored", int(reg.find_by_id(id1).get("capacity")) == 3)

	# Upsert: retag the same target changes type in place (same id, no dup).
	var id1b := reg.set_space_type(_prop_target("pp_1"), "kitchen", 5)
	_check("upsert keeps id", id1b == id1)
	_check("upsert no duplicate", reg.spaces.size() == 1)
	_check("upsert changed type", reg.find_by_id(id1).get("space_type") == "kitchen")
	_check("upsert changed capacity", int(reg.find_by_id(id1).get("capacity")) == 5)

	# Untag via empty type removes the record.
	var id_removed := reg.set_space_type(_prop_target("pp_1"), "")
	_check("untag returns empty id", id_removed.is_empty())
	_check("untag removed record", reg.spaces.is_empty())

	# Invalid type rejected.
	_check("invalid type rejected", reg.set_space_type(_prop_target("pp_2"), "discotheque").is_empty())
	_check("invalid type no record", reg.spaces.is_empty())

	# Building + area targets are distinct from prop targets.
	var idb := reg.set_space_type({"kind": "building", "building_tag": "b_10_20"}, "sleep")
	var idp := reg.set_space_type(_prop_target("b_10_20"), "sleep")
	_check("building/prop targets distinct", idb != idp and reg.spaces.size() == 2)

	# Fresh ids never collide after removal.
	reg.remove_space(idb)
	var idc := reg.set_space_type(_prop_target("pp_9"), "restroom")
	_check("new id unique", idc != idp)


# --- queries ----------------------------------------------------------------

func _pos_map_resolver(positions: Dictionary) -> Callable:
	return func(space: Dictionary) -> Variant:
		var pid := str((space.get("target", {}) as Dictionary).get("prop_id", ""))
		return positions.get(pid)  # null when absent -> dangling


func _test_registry_queries() -> void:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type(_prop_target("near"), "restroom", 1)
	reg.set_space_type(_prop_target("far"), "restroom", 1)
	reg.set_space_type(_prop_target("kitchen_a"), "kitchen", 2)
	var positions := {"near": Vector2(10, 0), "far": Vector2(100, 0), "kitchen_a": Vector2(0, 50)}
	var pos_of := _pos_map_resolver(positions)

	_check("spaces_of_type counts", reg.spaces_of_type("restroom").size() == 2)
	var nearest := reg.nearest_space_by("restroom", Vector2.ZERO, pos_of)
	_check("nearest picks near", str((nearest.get("target", {}) as Dictionary).get("prop_id")) == "near")

	# Capacity-full spaces are skipped when require_free.
	var near_id := str(nearest.get("id", ""))
	reg.claim(near_id, "agent_a")
	var next := reg.nearest_space_by("restroom", Vector2.ZERO, pos_of)
	_check("full space skipped", str((next.get("target", {}) as Dictionary).get("prop_id")) == "far")
	var busy := reg.nearest_space_by("restroom", Vector2.ZERO, pos_of, false)
	_check("require_free=false sees full", str((busy.get("target", {}) as Dictionary).get("prop_id")) == "near")

	# Dangling target (no resolvable position) is skipped, not crashed on.
	reg.set_space_type(_prop_target("deleted_prop"), "kitchen", 9)
	var k := reg.nearest_space_by("kitchen", Vector2.ZERO, pos_of)
	_check("dangling skipped", str((k.get("target", {}) as Dictionary).get("prop_id")) == "kitchen_a")

	# No spaces of a type -> {}.
	_check("missing type empty", reg.nearest_space_by("sleep", Vector2.ZERO, pos_of).is_empty())

	# Area target centroid resolves without a scene (pure math path).
	var area_id := reg.set_space_type({"kind": "area", "poly": [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]]}, "sleep")
	var c: Variant = reg.resolve_position(reg.find_by_id(area_id), null)
	_check("area centroid", c is Vector2 and (c as Vector2).is_equal_approx(Vector2(5, 5)))


# --- occupancy --------------------------------------------------------------

func _test_registry_occupancy() -> void:
	var reg := SpaceRegistry.create_empty()
	var sid := reg.set_space_type(_prop_target("pp_1"), "restroom", 2)
	_check("free when empty", reg.has_free_capacity(sid))
	_check("claim ok", reg.claim(sid, "a1"))
	_check("re-claim same agent idempotent", reg.claim(sid, "a1") and reg.occupant_count(sid) == 1)
	_check("claim second", reg.claim(sid, "a2"))
	_check("full at capacity", not reg.has_free_capacity(sid))
	_check("claim over capacity refused", not reg.claim(sid, "a3"))
	reg.release(sid, "a1")
	_check("release frees slot", reg.has_free_capacity(sid))
	reg.release_all_for_agent("a2")
	_check("release_all clears", reg.occupant_count(sid) == 0)
	_check("unknown space not free", not reg.has_free_capacity("sp_999"))


# --- persistence ------------------------------------------------------------

func _test_registry_persistence() -> void:
	var reg := SpaceRegistry.create_empty()
	reg.set_space_type(_prop_target("pp_1"), "restroom", 4, "Portapotty row")
	reg.set_space_type({"kind": "building", "building_tag": "b_5_7"}, "kitchen")
	reg.claim(str((reg.spaces[0] as Dictionary).get("id")), "a1")

	# serialize -> deserialize round-trip (occupancy must NOT survive).
	var blob := reg.serialize()
	var reg2 := SpaceRegistry.create_empty()
	reg2.deserialize(blob)
	_check("round-trip count", reg2.spaces.size() == 2)
	_check("round-trip fields", str((reg2.spaces[0] as Dictionary).get("label")) == "Portapotty row")
	_check("occupancy not persisted", reg2.occupant_count(str((reg2.spaces[0] as Dictionary).get("id"))) == 0)

	# Deserialize drops invalid space types (forward-compat with removed types).
	var bad := {"version": 1, "spaces": [
		{"id": "sp_1", "space_type": "restroom", "target": {"kind": "prop", "prop_id": "x"}},
		{"id": "sp_2", "space_type": "holodeck", "target": {"kind": "prop", "prop_id": "y"}},
	]}
	var reg3 := SpaceRegistry.create_empty()
	reg3.deserialize(bad)
	_check("invalid types dropped on load", reg3.spaces.size() == 1)

	# File round-trip through user:// (JSON path, real FileAccess).
	var lat := -89.1234
	var lon := 170.5678
	reg.save(lat, lon)
	var reg4 := SpaceRegistry.create_empty()
	_check("file load ok", reg4.load_for_map(lat, lon))
	_check("file round-trip count", reg4.spaces.size() == 2)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(reg.save_path_for_map(lat, lon)))


# =============================================================================
# Phase 2 — agent sim core (uncoupled)
# =============================================================================

## A tagged test site: kitchen / restroom / water point / sleep spaces at
## fixed world positions, generous capacity.
func _make_test_site() -> Dictionary:
	var reg := SpaceRegistry.create_empty()
	var positions := {
		"kitchen": Vector2(40, 0),
		"restroom": Vector2(-40, 20),
		"water": Vector2(0, 40),
		"beds": Vector2(0, -50),
		"showers": Vector2(-30, -30),
	}
	reg.set_space_type({"kind": "prop", "prop_id": "kitchen"}, "kitchen", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "restroom"}, "restroom", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "water"}, "water_point", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "beds"}, "sleep", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "showers"}, "shower", 60)
	var pos_of := func(space: Dictionary) -> Variant:
		var pid := str((space.get("target", {}) as Dictionary).get("prop_id", ""))
		return positions.get(pid)
	return {"registry": reg, "pos_of": pos_of}


## Drive the engine tick-by-tick like the game would (flow-engine cadence at
## 1x is ~0.25 s wall = tiny dt; we use 1 sim-minute ticks for speed).
## Returns {demand_log: Array of Dictionary, engine: NpcPopulationEngine}.
func _run_sim(engine: NpcPopulationEngine, site: Dictionary, start_h: float,
		hours: float, tick_h: float = 1.0 / 60.0) -> Array:
	var log: Array = []
	var t := start_h
	var end := start_h + hours
	while t < end:
		t += tick_h
		var demand := engine.tick(t, {
			"registry": site["registry"],
			"pos_of": site["pos_of"],
			"hour_of_day": fposmod(t, 24.0),
		})
		log.append(demand)
	return log


func _test_nav() -> void:
	# Normal step: moves toward dest at walk speed.
	var p := NpcNav.advance(Vector2.ZERO, Vector2(100, 0), 1.0 / 60.0)
	var expect := NpcNav.WALK_SPEED_MPS * 60.0
	_check("nav step distance", absf(p.x - expect) < 0.01 and p.y == 0.0, str(p))
	# Teleport degradation: one coarse tick covering the distance snaps to dest.
	var p2 := NpcNav.advance(Vector2.ZERO, Vector2(100, 0), 0.5)
	_check("nav teleport snaps", p2 == Vector2(100, 0))
	_check("nav zero dt holds", NpcNav.advance(Vector2(3, 4), Vector2(100, 0), 0.0) == Vector2(3, 4))


func _test_agent_daily_loop() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(8, "test_hab", Vector2.ZERO)
	_check("roster size", engine.agents.size() == 8)

	# One full day from 08:00: agents must eat, drink, and use the restroom
	# (visible as water+food demand), and sleep at night.
	var saw_food := false
	var saw_water := false
	var slept := 0
	var t := 8.0
	while t < 32.0:
		t += 1.0 / 60.0
		var demand := engine.tick(t, {
			"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": fposmod(t, 24.0),
		})
		saw_food = saw_food or float(demand.get("food", 0.0)) > 0.0
		saw_water = saw_water or float(demand.get("water", 0.0)) > 0.0
		if fposmod(t, 24.0) > 23.0 and fposmod(t, 24.0) < 23.02:
			for a in engine.agents:
				if (a as NpcAgent).activity == "sleep":
					slept += 1
	_check("agents ate (food demand seen)", saw_food)
	_check("agents drank/toileted (water demand seen)", saw_water)
	# Hygiene is satisfiable when a shower space exists (and never pins below).
	var washed := 0
	for a in engine.agents:
		if float((a as NpcAgent).needs["hygiene"]) < 0.8:
			washed += 1
	_check("agents washed", washed >= 5, "washed=%d" % washed)
	_check("most agents asleep at 23:00", slept >= 5, "asleep=%d" % slept)

	# After the day, no need should be pinned at 1.0 (everything satisfiable).
	# Enrichment is deliberately excluded: with no gathering space tagged it
	# legitimately pins at 1.0 (that is what caps morale at the baseline).
	var pinned := 0
	for a in engine.agents:
		for n in NpcAgent.NEEDS:
			if str(n) != "enrichment" and float((a as NpcAgent).needs[n]) >= 0.999:
				pinned += 1
	_check("no critical/comfort need pinned when supplied", pinned == 0, "pinned=%d" % pinned)

	# Demand rates while eating match the activity table (per agent).
	var one := NpcPopulationEngine.new()
	one.configure(1, "solo", Vector2(39, 0))  # spawn next to the kitchen
	var agent: NpcAgent = one.agents[0]
	agent.needs["hunger"] = 0.9
	agent.needs["thirst"] = 0.0
	agent.needs["bladder"] = 0.0
	agent.needs["sleep"] = 0.0
	# Demand is time-averaged per tick, so boundary ticks are partial — the
	# PEAK (mid-meal, fully doing) must hit the table rate exactly, and the
	# integral over the meal must equal duration × rate (mass-exact billing).
	var peak_food := 0.0
	var peak_water := 0.0
	var food_total := 0.0
	var tick_h := 1.0 / 60.0
	var t2 := 10.0
	while t2 < 11.5:
		t2 += tick_h
		var d := one.tick(t2, {"registry": site["registry"], "pos_of": site["pos_of"],
				"hour_of_day": fposmod(t2, 24.0)})
		peak_food = maxf(peak_food, float(d.get("food", 0.0)))
		peak_water = maxf(peak_water, float(d.get("water", 0.0)))
		food_total += float(d.get("food", 0.0)) * tick_h
	_check("eat peak food at table rate", absf(peak_food - 1.0) < 0.001, "%.3f" % peak_food)
	_check("eat peak water at table rate", absf(peak_water - 8.0) < 0.001, "%.3f" % peak_water)
	# One meal: 0.5 h × (0.85..1.25 jitter) × 1.0 kg/h → 0.42..0.63 kg total.
	_check("meal mass in jitter band", food_total > 0.40 and food_total < 0.65, "%.3f kg" % food_total)


func _test_determinism() -> void:
	var trace_a := _sim_trace()
	var trace_b := _sim_trace()
	_check("identical runs identical trajectories", trace_a == trace_b)
	_check("trace non-trivial", trace_a.length() > 100)


func _sim_trace() -> String:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(5, "det_hab", Vector2.ZERO)
	var parts: Array = []
	var t := 6.0
	while t < 78.0:  # 3 sim-days
		t += 1.0 / 30.0  # 2-min ticks
		engine.tick(t, {"registry": site["registry"], "pos_of": site["pos_of"],
				"hour_of_day": fposmod(t, 24.0)})
		if int(round(t * 30.0)) % 90 == 0:  # sample every 3 h
			for a in engine.agents:
				var ag: NpcAgent = a
				parts.append("%s|%.2f,%.2f|%s|%.3f,%.3f,%.3f,%.3f" % [
					ag.id, ag.pos.x, ag.pos.y, ag.activity,
					float(ag.needs["hunger"]), float(ag.needs["thirst"]),
					float(ag.needs["bladder"]), float(ag.needs["sleep"])])
	return "\n".join(PackedStringArray(parts))


func _test_starvation_block() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(4, "starv_hab", Vector2.ZERO)
	engine.set_starved(["food"])
	# A hungry day with no food: hunger must pin at 1.0 and no food demand
	# may ever be emitted; water activities (drink/restroom) still work.
	for a in engine.agents:
		(a as NpcAgent).needs["hunger"] = 0.8
		(a as NpcAgent).needs["sleep"] = 0.0
	var food_demand := 0.0
	var water_seen := false
	var t := 8.0
	# 6 h without food: long enough to pin hunger, short enough that nobody
	# has yet accumulated the quit pressure to walk out (that is covered by
	# _test_departure_and_collapse).
	while t < 14.0:
		t += 1.0 / 60.0
		var d := engine.tick(t, {"registry": site["registry"], "pos_of": site["pos_of"],
				"hour_of_day": fposmod(t, 24.0)})
		food_demand += float(d.get("food", 0.0))
		water_seen = water_seen or float(d.get("water", 0.0)) > 0.0
	_check("starved food never consumed", food_demand == 0.0)
	_check("water activities unaffected by food starvation", water_seen)
	var pinned := true
	for a in engine.agents:
		pinned = pinned and float((a as NpcAgent).needs["hunger"]) >= 0.999
	_check("hunger pinned at 1.0 while starved", pinned)
	_check("starvation alone did not empty the camp", engine.agents.size() == 4,
			"left=%d" % engine.agents.size())
	# Supply returns: agents recover (hunger satisfied again).
	engine.set_starved([])
	var t2 := 14.0
	while t2 < 20.0:
		t2 += 1.0 / 60.0
		engine.tick(t2, {"registry": site["registry"], "pos_of": site["pos_of"],
				"hour_of_day": fposmod(t2, 24.0)})
	var recovered := 0
	for a in engine.agents:
		if float((a as NpcAgent).needs["hunger"]) < 0.5:
			recovered += 1
	_check("agents eat once supply returns", recovered >= 3, "recovered=%d" % recovered)


func _test_scrub_and_catchup() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(3, "scrub_hab", Vector2.ZERO)
	_run_sim(engine, site, 8.0, 2.0)
	var before: Array = []
	for a in engine.agents:
		var ag: NpcAgent = a
		before.append([ag.pos, ag.needs.duplicate(true), ag.state, ag.activity])
	# Backward scrub: freeze — zero demand, state untouched.
	var d := engine.tick(5.0, {"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": 5.0})
	_check("scrub-back zero demand", d.is_empty())
	for i in engine.agents.size():
		var ag: NpcAgent = engine.agents[i]
		_check("scrub-back froze agent %d" % i,
				ag.pos == before[i][0] and ag.needs == before[i][1])
	# Large forward jump: coarse catch-up — agents re-plan from IDLE, needs
	# clamped, sleep resolved across the night, no crash.
	engine.tick(40.0, {"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": fposmod(40.0, 24.0)})
	for a in engine.agents:
		var ag: NpcAgent = a
		_check("catch-up leaves valid needs", float(ag.needs["hunger"]) <= 1.0)
		_check("catch-up slept the night", float(ag.needs["sleep"]) < 0.5)


func _test_engine_snapshot() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "snap_hab", Vector2.ZERO)
	_run_sim(engine, site, 9.0, 3.0)
	var snap := engine.snapshot(12.0)
	# JSON round-trip (snapshot must survive stringify like graph specs do).
	var snap2: Dictionary = JSON.parse_string(JSON.stringify(snap))
	var engine2 := NpcPopulationEngine.new()
	engine2.restore(snap2)
	_check("snapshot roster", engine2.agents.size() == 6)
	for i in engine.agents.size():
		var a: NpcAgent = engine.agents[i]
		var b: NpcAgent = engine2.agents[i]
		_check("snapshot pos ~equal %d" % i, (a.pos - b.pos).length() <= 0.71, "%s vs %s" % [a.pos, b.pos])
		_check("snapshot needs ~equal %d" % i,
				absf(float(a.needs["hunger"]) - float(b.needs["hunger"])) <= 0.011)
		_check("snapshot restores IDLE", b.state == NpcAgent.State.IDLE)
	# Restored engine keeps simulating without error.
	var log := _run_sim(engine2, site, 12.0, 1.0)
	_check("restored engine ticks", log.size() > 0)
	# summary() and agent_dots() shapes.
	var s := engine.summary()
	_check("summary count", int(s.get("count", 0)) == 6)
	_check("summary avg needs keys", (s.get("avg_needs", {}) as Dictionary).has("hunger"))
	var dots := engine.agent_dots()
	_check("dots per agent", dots.size() == 6)
	_check("dot payload", (dots[0] as Dictionary).has("pos") and (dots[0] as Dictionary).get("color") is Color)


# =============================================================================
# Tier 2 — morale, collapse, enrichment, chores, weather
# =============================================================================

func _test_morale_math() -> void:
	# Bands are ordered, exhaustive, and boundary-exact.
	_check("band 1.0 is Fuck Yes", NpcMorale.label(1.0) == "Fuck Yes")
	_check("band 0.0 is Fuck This", NpcMorale.label(0.0) == "Fuck This")
	_check("band boundary 0.85", NpcMorale.band(0.85) == 0 and NpcMorale.band(0.8499) == 1)
	_check("band boundary 0.12", NpcMorale.band(0.12) == 4 and NpcMorale.band(0.1199) == 5)
	for i in NpcMorale.BANDS.size() - 1:
		_check("bands descend %d" % i,
				float((NpcMorale.BANDS[i] as Dictionary)["min"])
				> float((NpcMorale.BANDS[i + 1] as Dictionary)["min"]))

	# Comfortable needs cost nothing; deprivation is superlinear.
	var calm := {"sleep": 0.5, "thirst": 0.5, "hunger": 0.5, "bladder": 0.5}
	_check("no pressure below pain threshold", NpcMorale.pressure(calm) == 0.0)
	var half := {"thirst": 0.875}   # halfway from 0.75 to 1.0
	var full := {"thirst": 1.0}
	var p_half := NpcMorale.pressure(half)
	var p_full := NpcMorale.pressure(full)
	_check("pressure rises with deprivation", p_full > p_half and p_half > 0.0)
	_check("pressure is superlinear (quarter at half)",
			absf(p_half - p_full * 0.25) < 0.0001, "%.4f vs %.4f" % [p_half, p_full * 0.25])
	_check("thirst at 1.0 costs its weight",
			absf(p_full - float(NpcMorale.WEIGHT["thirst"])) < 0.0001)

	# Blocked needs hurt ~2x — the thesis of the design.
	var blocked_p := NpcMorale.pressure(full, {"thirst": true})
	_check("blocked need costs 2x", absf(blocked_p - p_full * NpcMorale.BLOCKED_MULT) < 0.0001)

	# Comfort needs never apply critical pressure.
	_check("hygiene applies no pressure", NpcMorale.pressure({"hygiene": 1.0}) == 0.0)
	_check("enrichment applies no pressure", NpcMorale.pressure({"enrichment": 1.0}) == 0.0)

	# Ceiling: needs alone cap at BASELINE_CEILING; enrichment lifts it to 1.0.
	_check("unenriched ceiling", absf(NpcMorale.ceiling(1.0) - NpcMorale.BASELINE_CEILING) < 0.0001)
	_check("fully enriched ceiling", absf(NpcMorale.ceiling(0.0) - 1.0) < 0.0001)

	# Recovery is slower than collapse (asymmetry is what makes it a game).
	_check("loss outpaces recovery",
			NpcMorale.pressure(full) > NpcMorale.RECOVERY_PER_H)
	# Above the earned ceiling, morale sinks back toward it.
	_check("above-ceiling decays",
			NpcMorale.delta_per_hour(0.95, calm, {}, 1.0) < 0.0)
	# Productivity: low morale slows work, high morale speeds it.
	_check("productivity floor", absf(NpcMorale.productivity(0.0) - NpcMorale.PRODUCTIVITY_MIN) < 0.0001)
	_check("productivity peak", absf(NpcMorale.productivity(1.0) - NpcMorale.PRODUCTIVITY_MAX) < 0.0001)
	_check("productivity rises with morale", NpcMorale.productivity(0.9) > NpcMorale.productivity(0.3))

	# Quit pressure accrues only below the threshold and bleeds off above it.
	var qp := NpcMorale.step_quit_pressure(0.0, 0.0, 1.0)
	_check("quit pressure accrues", absf(qp - NpcMorale.QUIT_THRESHOLD) < 0.0001)
	_check("quit pressure decays when rescued",
			NpcMorale.step_quit_pressure(0.5, 0.6, 1.0) < 0.5)
	_check("quit pressure never negative",
			NpcMorale.step_quit_pressure(0.01, 1.0, 10.0) == 0.0)
	_check("wants_to_leave at threshold",
			NpcMorale.wants_to_leave(NpcMorale.QUIT_PRESSURE_H))


func _test_morale_supplied_vs_starved() -> void:
	# A fully supplied community holds at/above the baseline ceiling band and
	# nobody leaves; a starved one falls.
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(8, "morale_ok", Vector2.ZERO)
	_run_sim(engine, site, 8.0, 72.0, 1.0 / 30.0)
	var mean_ok := engine.mean_morale()
	_check("supplied 3-day mean morale healthy", mean_ok >= 0.70, "%.3f" % mean_ok)
	_check("supplied run has no departures", engine.departures().is_empty())
	_check("supplied run not collapsed", not engine.has_collapsed())
	_check("supplied run low collapse risk", engine.collapse_risk() < 0.35,
			"%.2f" % engine.collapse_risk())

	# Unenriched: cannot exceed the ceiling however well supplied.
	_check("unenriched capped at baseline",
			mean_ok <= NpcMorale.BASELINE_CEILING + 0.001, "%.3f" % mean_ok)

	# No water tagged at all -> blocked thirst -> morale collapses. Sampled at
	# 8 h, BEFORE anyone has accumulated the quit pressure to walk (past that
	# the roster empties and these aggregates read 0 by definition).
	var dry := _make_test_site()
	(dry["registry"] as SpaceRegistry).set_space_type({"kind": "prop", "prop_id": "water"}, "")
	var engine2 := NpcPopulationEngine.new()
	engine2.configure(8, "morale_dry", Vector2.ZERO)
	_run_sim(engine2, dry, 8.0, 8.0, 1.0 / 30.0)
	_check("no water -> morale falls", engine2.mean_morale() < 0.4, "%.3f" % engine2.mean_morale())
	_check("no water -> agents blocked", engine2.blocked_share() > 0.5,
			"%.2f" % engine2.blocked_share())
	_check("no water -> blocked on thirst",
			int((engine2.summary().get("blocked", {}) as Dictionary).get("thirst", 0)) > 0)

	# A BRIEF outage dips morale, then recovers fully with nobody leaving.
	var engine3 := NpcPopulationEngine.new()
	engine3.configure(6, "morale_blip", Vector2.ZERO)
	_run_sim(engine3, site, 8.0, 24.0, 1.0 / 30.0)
	engine3.set_starved(["water", "food"])
	_run_sim(engine3, site, 32.0, 6.0, 1.0 / 30.0)
	var dip := engine3.mean_morale()
	engine3.set_starved([])
	_run_sim(engine3, site, 38.0, 48.0, 1.0 / 30.0)
	_check("brief outage dips morale", dip < 0.7, "%.3f" % dip)
	_check("brief outage recovers", engine3.mean_morale() > dip + 0.1,
			"%.3f -> %.3f" % [dip, engine3.mean_morale()])
	_check("brief outage costs nobody", engine3.departures().is_empty(),
			"lost %d" % engine3.departures().size())


func _test_enrichment_ceiling() -> void:
	# With a fire circle tagged, morale can climb past BASELINE_CEILING.
	var site := _make_test_site()
	var reg: SpaceRegistry = site["registry"]
	reg.set_space_type({"kind": "prop", "prop_id": "fire"}, "fire_circle", 30)
	site["pos_of"] = func(space: Dictionary) -> Variant:
		var pid := str((space.get("target", {}) as Dictionary).get("prop_id", ""))
		var positions := {
			"kitchen": Vector2(40, 0), "restroom": Vector2(-40, 20),
			"water": Vector2(0, 40), "beds": Vector2(0, -50),
			"showers": Vector2(-30, -30), "fire": Vector2(20, 20),
		}
		return positions.get(pid)
	var engine := NpcPopulationEngine.new()
	engine.configure(8, "enrich", Vector2.ZERO)
	_run_sim(engine, site, 8.0, 96.0, 1.0 / 30.0)
	_check("enrichment lifts morale past baseline",
			engine.mean_morale() > NpcMorale.BASELINE_CEILING,
			"%.3f" % engine.mean_morale())
	var gathered := 0
	for a in engine.agents:
		if float((a as NpcAgent).needs["enrichment"]) < 0.6:
			gathered += 1
	_check("people actually gathered", gathered >= 4, "gathered=%d" % gathered)

	# Enrichment NEVER preempts a critical need (design invariant #1).
	var agent := NpcAgent.make("inv_1", Vector2.ZERO)
	agent.needs["thirst"] = 1.0
	agent.needs["enrichment"] = 1.0
	agent.needs["hunger"] = 0.0
	agent.needs["bladder"] = 0.0
	agent.needs["sleep"] = 0.0
	agent.needs["hygiene"] = 0.0
	var ctx := {"registry": reg, "pos_of": site["pos_of"], "hour_of_day": 12.0}
	# _pick covers tiers 1-2 only; enrichment is tier 4 (_wants_enrichment).
	_check("thirst beats enrichment", agent._pick(ctx) == "thirst")
	_check("no enrichment while thirsty", not agent._wants_enrichment(ctx))
	agent.needs["thirst"] = 0.0
	_check("nothing critical calling", agent._pick(ctx).is_empty())
	_check("enrichment wanted when all quiet", agent._wants_enrichment(ctx))
	# Comfort needs also outrank it.
	agent.needs["hygiene"] = 1.0
	_check("hygiene outranks enrichment", agent._pick(ctx) == "hygiene"
			and not agent._wants_enrichment(ctx))
	agent.needs["hygiene"] = 0.0

	# Social clustering: an occupied fire outscores an empty nearer one.
	var social := SpaceRegistry.create_empty()
	var near_id := social.set_space_type({"kind": "prop", "prop_id": "near"}, "fire_circle", 10)
	var far_id := social.set_space_type({"kind": "prop", "prop_id": "far"}, "movement", 10)
	var spos := {"near": Vector2(10, 0), "far": Vector2(60, 0)}
	var spos_of := func(space: Dictionary) -> Variant:
		return spos.get(str((space.get("target", {}) as Dictionary).get("prop_id", "")))
	for i in 5:
		social.claim(far_id, "crowd_%d" % i)
	var joiner := NpcAgent.make("joiner", Vector2.ZERO)
	joiner.needs["enrichment"] = 1.0
	joiner._begin_enrichment(10.0, {"registry": social, "pos_of": spos_of, "hour_of_day": 14.0})
	_check("people drift toward company", joiner.target_space_id == far_id,
			"went to %s (near=%s far=%s)" % [joiner.target_space_id, near_id, far_id])


func _test_departure_and_collapse() -> void:
	# Nothing tagged at all: every critical need is blocked -> people leave ->
	# the colony collapses. This is the cascade, end to end.
	var barren := {"registry": SpaceRegistry.create_empty(),
			"pos_of": func(_s: Dictionary) -> Variant: return null}
	var engine := NpcPopulationEngine.new()
	engine.configure(10, "collapse", Vector2.ZERO)
	var departed: Array = []
	engine.agent_departed.connect(func(_id: String, who: String, _r: String) -> void:
		departed.append(who))
	var warned := [false]
	engine.collapse_warning.connect(func(_risk: float) -> void: warned[0] = true)
	var collapsed := [false]
	engine.colony_collapsed.connect(func() -> void: collapsed[0] = true)
	_run_sim(engine, barren, 8.0, 24.0 * 10.0, 1.0 / 12.0)
	_check("barren site loses people", departed.size() > 0, "departed=%d" % departed.size())
	_check("departure signal names them", departed.is_empty() or not str(departed[0]).is_empty())
	_check("collapse warning fired", warned[0])
	_check("colony collapsed", collapsed[0] and engine.has_collapsed())
	_check("roster shrank past the floor",
			engine.agents.size() <= int(ceil(10.0 * NpcPopulationEngine.COLLAPSE_FLOOR_FRAC)),
			"left=%d" % engine.agents.size())
	# Roster loss (0.5) + zero morale (0.3); the blocked term reads 0 once
	# nobody is left to be blocked, so 0.8 is the ceiling for an empty camp.
	_check("collapse risk maxed", engine.collapse_risk() >= 0.8, "%.2f" % engine.collapse_risk())
	_check("departures logged", engine.departures().size() == departed.size())
	var reason := str((engine.departures()[0] as Dictionary).get("reason", ""))
	_check("departure has a cause", reason in NpcAgent.CRITICAL_NEEDS, reason)

	# Higher morale = more buffer: a community that starts at Fuck Yes takes
	# strictly longer to lose its first person than one starting at Coping.
	var t_high := _hours_to_first_departure(0.95)
	var t_low := _hours_to_first_departure(0.55)
	_check("resilience buys time", t_high > t_low, "high=%.1fh low=%.1fh" % [t_high, t_low])

	# Departure shock: survivors lose morale when someone walks.
	var shock_engine := NpcPopulationEngine.new()
	shock_engine.configure(4, "shock", Vector2.ZERO)
	for a in shock_engine.agents:
		(a as NpcAgent).morale = 0.6
	(shock_engine.agents[0] as NpcAgent).morale = 0.0
	(shock_engine.agents[0] as NpcAgent).quit_pressure = NpcMorale.QUIT_PRESSURE_H
	shock_engine._process_departures(10.0, {"registry": null})
	_check("survivors take a morale hit",
			(shock_engine.agents[0] as NpcAgent).morale < 0.6)


## Sim-hours until the first person quits a barren site, from a given start
## morale. Used to prove resilience is a real buffer.
func _hours_to_first_departure(start_morale: float) -> float:
	var barren := {"registry": SpaceRegistry.create_empty(),
			"pos_of": func(_s: Dictionary) -> Variant: return null}
	var engine := NpcPopulationEngine.new()
	engine.configure(4, "buffer_%d" % int(start_morale * 100.0), Vector2.ZERO)
	for a in engine.agents:
		(a as NpcAgent).morale = start_morale
	var t := 8.0
	var tick := 1.0 / 12.0
	while t < 8.0 + 24.0 * 30.0:
		t += tick
		engine.tick(t, {"registry": barren["registry"], "pos_of": barren["pos_of"],
				"hour_of_day": fposmod(t, 24.0)})
		if not engine.departures().is_empty():
			return t - 8.0
	return 24.0 * 30.0


func _test_weather_gate() -> void:
	var mild := {"temp_c": 18.0, "wind_ms": 3.0, "rain_mmh": 0.0}
	_check("mild weather is full productivity",
			absf(NpcWeatherGate.productivity(mild) - 1.0) < 0.0001)
	_check("mild weather is safe", not NpcWeatherGate.is_unsafe(mild))
	_check("missing data reads comfortable",
			absf(NpcWeatherGate.productivity({}) - 1.0) < 0.0001)

	# Indoor work ignores the weather entirely.
	var storm := {"temp_c": 40.0, "wind_ms": 20.0, "rain_mmh": 12.0}
	_check("indoor immune to storms",
			absf(NpcWeatherGate.productivity(storm, NpcWeatherGate.EXPOSURE_INDOOR) - 1.0) < 0.0001)
	_check("indoor never unsafe", not NpcWeatherGate.is_unsafe(storm, NpcWeatherGate.EXPOSURE_INDOOR))
	_check("outdoor storm is unsafe", NpcWeatherGate.is_unsafe(storm))

	# Each driver degrades independently, and they MULTIPLY.
	var hot := {"temp_c": 32.0, "wind_ms": 0.0, "rain_mmh": 0.0}
	var windy := {"temp_c": 18.0, "wind_ms": 11.5, "rain_mmh": 0.0}
	var both := {"temp_c": 32.0, "wind_ms": 11.5, "rain_mmh": 0.0}
	var p_hot := NpcWeatherGate.productivity(hot)
	var p_windy := NpcWeatherGate.productivity(windy)
	_check("heat degrades", p_hot < 1.0 and p_hot > NpcWeatherGate.WEATHER_FLOOR)
	_check("wind degrades", p_windy < 1.0)
	_check("drivers multiply",
			absf(NpcWeatherGate.productivity(both) - p_hot * p_windy) < 0.0001)
	_check("cold degrades too", NpcWeatherGate.productivity({"temp_c": 0.0}) < 1.0)
	_check("productivity floored",
			NpcWeatherGate.productivity({"temp_c": 37.0, "wind_ms": 14.5, "rain_mmh": 4.9})
			>= NpcWeatherGate.WEATHER_FLOOR)

	# Shelter relieves both productivity and exposure.
	_check("shelter beats full exposure",
			NpcWeatherGate.productivity(hot, NpcWeatherGate.EXPOSURE_SHELTERED) > p_hot)
	_check("sheltered survives heavy rain",
			not NpcWeatherGate.is_unsafe({"temp_c": 18.0, "rain_mmh": 8.0},
					NpcWeatherGate.EXPOSURE_SHELTERED))
	_check("exposed does not",
			NpcWeatherGate.is_unsafe({"temp_c": 18.0, "rain_mmh": 8.0}))

	# Exposure morale drain scales with severity and is zero indoors.
	_check("no exposure drain indoors",
			NpcWeatherGate.exposure_morale_drain(storm, NpcWeatherGate.EXPOSURE_INDOOR) == 0.0)
	_check("exposure drain outdoors",
			NpcWeatherGate.exposure_morale_drain(hot, NpcWeatherGate.EXPOSURE_OUTDOOR) > 0.0)
	_check("describe reports stoppage",
			NpcWeatherGate.describe(storm).contains("unsafe"))


func _test_chore_board() -> void:
	var board := NpcChoreBoard.create_empty()
	var cid := board.add_chore("Haul water", 2.0, {
		"window": {"start_h": 8.0, "end_h": 18.0},
		"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
	})
	_check("chore created", not cid.is_empty() and board.chores.size() == 1)
	_check("remaining starts full", absf(board.remaining(cid) - 2.0) < 0.0001)

	# Windows, including one that wraps midnight.
	_check("window open midday", NpcChoreBoard.window_open(board.find(cid), 12.0))
	_check("window shut at night", not NpcChoreBoard.window_open(board.find(cid), 22.0))
	var night := board.add_chore("Night check", 0.5, {"window": {"start_h": 22.0, "end_h": 2.0}})
	_check("wrapping window open at 23", NpcChoreBoard.window_open(board.find(night), 23.0))
	_check("wrapping window open at 01", NpcChoreBoard.window_open(board.find(night), 1.0))
	_check("wrapping window shut at 12", not NpcChoreBoard.window_open(board.find(night), 12.0))

	# Claims are exclusive.
	_check("claim works", board.claim(cid, "a1"))
	_check("second claimant refused", not board.claim(cid, "a2"))
	board.release(cid, "a1")
	_check("release frees it", board.claim(cid, "a2"))
	board.release_all_for_agent("a2")

	# Credit is mass-exact and never over-applies.
	var applied := board.credit(cid, 0.5, 10.0)
	_check("credit applies", absf(applied - 0.5) < 0.0001)
	_check("progress tracked", absf(board.remaining(cid) - 1.5) < 0.0001)
	var over := board.credit(cid, 99.0, 10.0)
	_check("credit clamps to remaining", absf(over - 1.5) < 0.0001)
	# Completing resets progress for the next run, so `remaining` returns the
	# full job again — "done" is tracked by done_day, not by remaining == 0.
	_check("finished chore rearms for next time",
			absf(board.remaining(cid) - 2.0) < 0.0001)
	_check("finished chore marked done today",
			int(board.find(cid).get("done_day", -1)) == NpcChoreBoard.day_index(10.0))
	_check("finished chore releases its worker",
			str(board.find(cid).get("worker", "")).is_empty())
	_check("finished chore not due today",
			board.available_for("a1", 10.0, 12.0).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != cid))
	# …but it comes back tomorrow (daily repeat).
	_check("daily chore returns next day",
			board.available_for("a1", 34.0, 12.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == cid))

	# Assignment filtering + unsafe-weather skip.
	var mine := board.add_chore("Mine only", 1.0, {"assigned_to": "a1"})
	_check("assignee sees it",
			board.available_for("a1", 10.0, 12.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == mine))
	_check("others do not",
			board.available_for("a9", 10.0, 12.0).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != mine))
	var storm := {"temp_c": 40.0, "wind_ms": 20.0, "rain_mmh": 12.0}
	var outdoor := board.add_chore("Roof work", 1.0, {"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR})
	_check("storm hides outdoor work",
			board.available_for("a1", 10.0, 12.0, storm).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != outdoor))

	# Priority ordering.
	board.update_chore(outdoor, {"priority": -5, "exposure": NpcWeatherGate.EXPOSURE_INDOOR})
	var ordered := board.available_for("a1", 34.0, 12.0)
	_check("priority sorts first", not ordered.is_empty()
			and str((ordered[0] as Dictionary).get("id")) == outdoor)

	# Day-plan inputs.
	_check("assigned hours counted",
			absf(board.assigned_hours_for("a1", 34.0) - 1.0) < 0.0001)
	_check("shared work spreads", board.shared_hours_per_agent(4, 34.0) > 0.0)

	# Serialization drops the runtime claim but keeps the queue.
	board.claim(mine, "a1")
	var blob := board.serialize()
	var board2 := NpcChoreBoard.create_empty()
	board2.deserialize(blob)
	_check("chores round-trip", board2.chores.size() == board.chores.size())
	_check("claim not persisted", str((board2.find(mine)).get("worker", "")).is_empty())
	_check("ids keep incrementing",
			board2.add_chore("New", 1.0) != mine)


func _test_chore_priority() -> void:
	# The ladder: a critical need always preempts work; a quiet agent works.
	var site := _make_test_site()
	var board := NpcChoreBoard.create_empty()
	board.add_chore("Tend the beds", 3.0, {
		"window": {"start_h": 0.0, "end_h": 24.0},
		"exposure": NpcWeatherGate.EXPOSURE_INDOOR,
	})
	var engine := NpcPopulationEngine.new()
	engine.configure(5, "chores", Vector2.ZERO)
	engine.chore_board = board
	_run_sim(engine, site, 9.0, 8.0, 1.0 / 60.0)
	_check("work got done", board.chores.any(func(c: Dictionary) -> bool:
			return float(c.get("progress_h", 0.0)) > 0.0 or int(c.get("done_day", -1)) >= 0))

	# A thirsty worker drops the chore rather than finishing it.
	var worker := NpcAgent.make("w1", Vector2.ZERO)
	var board2 := NpcChoreBoard.create_empty()
	var cid := board2.add_chore("Long job", 10.0, {"window": {"start_h": 0.0, "end_h": 24.0}})
	var ctx := {
		"registry": site["registry"], "pos_of": site["pos_of"],
		"hour_of_day": 12.0, "board": board2, "weather": {},
	}
	worker._begin_chore(10.0, ctx)
	_check("agent took the chore", worker.activity == NpcAgent.CHORE_ACTIVITY)
	worker.state = NpcAgent.State.DOING
	worker.needs["thirst"] = 1.0
	worker._step_chore(10.5, 0.5, ctx)
	_check("critical need preempts work", worker.activity == "",
			"still %s" % worker.activity)
	_check("chore released on preempt", str(board2.find(cid).get("worker", "")).is_empty())

	# Morale and weather scale how much work a sim-hour buys.
	var slow := NpcAgent.make("slow", Vector2.ZERO)
	slow.morale = 0.0
	var fast := NpcAgent.make("fast", Vector2.ZERO)
	fast.morale = 1.0
	for pair in [[slow, "slow"], [fast, "fast"]]:
		var a: NpcAgent = (pair as Array)[0]
		var b := NpcChoreBoard.create_empty()
		var c := b.add_chore("Job", 100.0, {"window": {"start_h": 0.0, "end_h": 24.0},
				"exposure": NpcWeatherGate.EXPOSURE_INDOOR})
		var cx := {"board": b, "weather": {}, "hour_of_day": 12.0, "registry": null}
		a._begin_chore(10.0, cx)
		a.state = NpcAgent.State.DOING
		a._step_chore(11.0, 1.0, cx)
		var done := 100.0 - b.remaining(c)
		if str((pair as Array)[1]) == "slow":
			_check("low morale works slowly",
					absf(done - NpcMorale.PRODUCTIVITY_MIN) < 0.001, "%.3f" % done)
		else:
			_check("high morale works fast",
					absf(done - NpcMorale.PRODUCTIVITY_MAX) < 0.001, "%.3f" % done)

	# Weather scaling applies on top.
	var wet := NpcAgent.make("wet", Vector2.ZERO)
	wet.morale = 1.0
	var b3 := NpcChoreBoard.create_empty()
	var c3 := b3.add_chore("Outside job", 100.0, {"window": {"start_h": 0.0, "end_h": 24.0},
			"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR})
	var rain := {"temp_c": 18.0, "wind_ms": 0.0, "rain_mmh": 3.0}
	var cx3 := {"board": b3, "weather": rain, "hour_of_day": 12.0, "registry": null}
	wet._begin_chore(10.0, cx3)
	wet.state = NpcAgent.State.DOING
	wet._step_chore(11.0, 1.0, cx3)
	var wet_done := 100.0 - b3.remaining(c3)
	_check("rain slows outdoor work",
			absf(wet_done - NpcMorale.PRODUCTIVITY_MAX * NpcWeatherGate.productivity(rain)) < 0.001,
			"%.3f" % wet_done)

	# Free time: over-scheduling shows as negative headroom.
	var busy := NpcAgent.make("busy", Vector2.ZERO)
	_check("free time positive when unbooked", busy.free_hours(0.0) > 0.0)
	_check("over-scheduling goes negative", busy.free_hours(20.0) < 0.0)
	_check("no enrichment without free time",
			not busy._has_free_time({"assigned_chore_h": 20.0}))
