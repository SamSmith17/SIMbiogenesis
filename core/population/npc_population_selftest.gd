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
	# --- Tier 3 ---
	_test_nav_grid_region()
	_test_nav_grid_bake()
	_test_nav_grid_slope_vs_steps()
	_test_nav_grid_obstacles()
	_test_nav_grid_queries()
	_test_astar_basic()
	_test_astar_obstacles()
	_test_astar_steps_and_slopes()
	_test_astar_cache_and_determinism()
	_test_path_following()
	_test_agent_follows_path()
	_test_building_doors()
	_test_building_nav_entries()
	_test_building_grid_integration()
	_test_nav_layers()

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


# =============================================================================
# Tier 3a — walkable grid
# =============================================================================

## Synthetic terrain: flat, a gentle ramp, a cliff, and a staircase.
static func _flat_h(_x: float, _z: float) -> float:
	return 0.0


static func _ramp_h(x: float, _z: float) -> float:
	return x * 0.2          # 11.3 deg — a comfortable ramp


static func _cliff_h(x: float, _z: float) -> float:
	return 0.0 if x < 0.0 else 20.0


## A REAL staircase: 0.18 m rise per 0.28 m tread = 33 deg. Below the grid's
## resolution, so it reads as a 33 deg ramp — comfortably walkable, which is
## the requirement ("climb stairs without getting stuck").
static func _stairs_h(x: float, _z: float) -> float:
	return maxf(x, 0.0) * (0.18 / 0.28)


## A SINGLE 1.2 m step up onto a plateau — the step-onto-a-deck case. Between
## adjacent 0.75 m cells that is 58 deg, which would block it if slope were
## measured per cell pair; over the 3 m central-difference baseline it is
## 21.8 deg and stays walkable. This is the case the baseline exists for.
static func _step_h(x: float, _z: float) -> float:
	return 0.0 if x < 0.0 else 1.2


## A sustained ladder grade (1.2 m every 0.75 m = 58 deg). Correctly BLOCKED —
## widening the baseline cannot rescue this, because it genuinely is a cliff.
static func _ladder_h(x: float, _z: float) -> float:
	return floor(maxf(x, 0.0) / 0.75) * 1.2


func _test_nav_grid_region() -> void:
	var g := NpcNavGrid.new()
	_check("empty points rejected", not g.configure_for_points(PackedVector2Array()))

	var pts := PackedVector2Array([Vector2(-20, -10), Vector2(30, 25)])
	_check("configure from points", g.configure_for_points(pts))
	# Span 50 m + 2x30 m pad -> 110 m across, /0.75 -> ~147 cells.
	_check("region covers the span", g.nx >= int(110.0 / NpcNavGrid.CELL_M) - 1,
			"nx=%d" % g.nx)
	_check("region is square", g.nx == g.nz)
	for p in pts:
		_check("tagged point %s inside region" % p, g.contains_world(p))
	_check("pad reaches beyond the points",
			g.contains_world(Vector2(30.0 + NpcNavGrid.REGION_PAD_M - 2.0, 25.0)))

	# A single point still yields a usable minimum region.
	var g2 := NpcNavGrid.new()
	g2.configure_for_points(PackedVector2Array([Vector2(5, 5)]))
	_check("single point -> min region",
			g2.nx * g2.cell_m >= NpcNavGrid.MIN_REGION_HALF_M, "%.1f m" % (g2.nx * g2.cell_m))

	# Huge spans clamp rather than exploding the cell count.
	var g3 := NpcNavGrid.new()
	g3.configure_for_points(PackedVector2Array([Vector2(-5000, -5000), Vector2(5000, 5000)]))
	_check("huge span clamps", g3.nx <= NpcNavGrid.MAX_CELLS_AXIS, "nx=%d" % g3.nx)

	# Cell <-> world round-trip.
	var g4 := NpcNavGrid.new()
	g4.configure_region(Vector2(10.0, -4.0), 30.0)
	for probe in [Vector2(10, -4), Vector2(-8, 12), Vector2(33, -30)]:
		var c := g4.cell_of(probe)
		if not g4.in_bounds(c.x, c.y):
			continue
		var back := g4.center_of(c.x, c.y)
		_check("cell round-trip %s" % probe,
				back.distance_to(probe) <= g4.cell_m * 0.75, "%s -> %s" % [probe, back])


func _test_nav_grid_bake() -> void:
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 20.0)
	_check("not ready before bake", not g.is_ready())
	_check("nothing walkable before bake", not g.is_walkable(5, 5))

	# Chunked bake must converge, and must not finish in one call.
	g.begin_bake(Callable(self, "_flat_h"))
	var steps := 0
	var done := false
	while not done and steps < 10000:
		done = g.bake_step(64)
		steps += 1
	_check("chunked bake converges", done, "steps=%d" % steps)
	_check("chunked bake really is chunked", steps > 1, "steps=%d" % steps)
	_check("ready after bake", g.is_ready())
	_check("progress reaches 1", absf(g.bake_progress() - 1.0) < 0.001)

	# Flat ground: everything walkable, zero slope, zero height.
	_check("flat is walkable", g.is_walkable(3, 3) and g.is_walkable(g.nx - 2, g.nz - 2))
	_check("flat slope is zero", absf(g.slope_deg_at(5, 5)) < 0.001)
	_check("flat height is zero", absf(g.height_at(5, 5)) < 0.001)
	_check("all cells walkable on flat", g.walkable_cell_count() == g.cell_count(),
			"%d of %d" % [g.walkable_cell_count(), g.cell_count()])

	# Identical bakes are identical (determinism).
	var a := NpcNavGrid.new()
	a.configure_region(Vector2.ZERO, 15.0)
	a.bake_now(Callable(self, "_ramp_h"))
	var b := NpcNavGrid.new()
	b.configure_region(Vector2.ZERO, 15.0)
	b.bake_now(Callable(self, "_ramp_h"))
	var same := true
	for iz in a.nz:
		for ix in a.nx:
			if absf(a.height_at(ix, iz) - b.height_at(ix, iz)) > 0.0001 \
					or a.flags_at(ix, iz) != b.flags_at(ix, iz):
				same = false
				break
	_check("bake is deterministic", same)

	# No height source degrades to a flat, walkable grid rather than failing.
	var g2 := NpcNavGrid.new()
	g2.configure_region(Vector2.ZERO, 10.0)
	g2.bake_now(Callable())
	_check("missing height_fn still bakes", g2.is_ready() and g2.is_walkable(2, 2))


func _test_nav_grid_slope_vs_steps() -> void:
	# A gentle ramp is fully walkable.
	var ramp := NpcNavGrid.new()
	ramp.configure_region(Vector2.ZERO, 20.0)
	ramp.bake_now(Callable(self, "_ramp_h"))
	_check("ramp slope ~11 deg", absf(ramp.slope_deg_at(20, 20) - 11.3) < 1.0,
			"%.1f" % ramp.slope_deg_at(20, 20))
	_check("ramp fully walkable", ramp.walkable_cell_count() == ramp.cell_count())
	_check("ramp height climbs", ramp.height_at(30, 10) > ramp.height_at(10, 10))

	# REQUIREMENT: a real staircase (33 deg) must be fully climbable.
	var stairs := NpcNavGrid.new()
	stairs.configure_region(Vector2(10.0, 0.0), 8.0)
	stairs.bake_now(Callable(self, "_stairs_h"))
	var mid := stairs.nz / 2
	var blocked_on_stairs := 0
	for ix in range(2, stairs.nx - 2):
		if not stairs.is_walkable(ix, mid):
			blocked_on_stairs += 1
	_check("a real staircase is fully walkable", blocked_on_stairs == 0,
			"%d blocked" % blocked_on_stairs)
	_check("staircase reads ~33 deg",
			absf(stairs.slope_deg_at(stairs.nx / 2, mid) - 32.7) < 1.5,
			"%.1f deg" % stairs.slope_deg_at(stairs.nx / 2, mid))

	# THE CASE THE BASELINE EXISTS FOR: a single 1.2 m step onto a deck is
	# 58 deg between adjacent cells but 38.7 deg over the baseline, so it
	# stays walkable instead of stranding people at the bottom of it.
	var step := NpcNavGrid.new()
	step.configure_region(Vector2.ZERO, 10.0)
	step.bake_now(Callable(self, "_step_h"))
	var smid := step.nz / 2
	var sface := step.cell_of(Vector2(0.0, 0.0)).x
	_check("a single 1.2 m step is NOT blocked", step.is_walkable(sface, smid),
			"slope=%.1f deg" % step.slope_deg_at(sface, smid))
	# atan(1.2 / 3.0) = 21.8 deg — comfortably under the 50 deg cliff limit.
	_check("the step reads ~22 deg over the 3 m baseline",
			absf(step.slope_deg_at(sface, smid) - 21.8) < 2.0,
			"%.1f deg" % step.slope_deg_at(sface, smid))
	_check("ground either side of the step is walkable",
			step.is_walkable(sface - 4, smid) and step.is_walkable(sface + 4, smid))

	# A sustained ladder grade is correctly refused — the baseline is not a
	# licence to climb anything.
	var ladder := NpcNavGrid.new()
	ladder.configure_region(Vector2(10.0, 0.0), 8.0)
	ladder.bake_now(Callable(self, "_ladder_h"))
	var blocked_on_ladder := 0
	for ix in range(2, ladder.nx - 2):
		if not ladder.is_walkable(ix, ladder.nz / 2):
			blocked_on_ladder += 1
	_check("a sustained 58 deg ladder IS blocked", blocked_on_ladder > 0,
			"%d blocked" % blocked_on_ladder)

	# A real cliff DOES block.
	var cliff := NpcNavGrid.new()
	cliff.configure_region(Vector2.ZERO, 15.0)
	cliff.bake_now(Callable(self, "_cliff_h"))
	var mid_z := cliff.nz / 2
	var face := cliff.cell_of(Vector2(0.0, 0.0)).x
	_check("cliff face blocked", not cliff.is_walkable(face, mid_z),
			"slope=%.1f" % cliff.slope_deg_at(face, mid_z))
	_check("cliff face flagged steep",
			(cliff.flags_at(face, mid_z) & NpcNavGrid.F_STEEP) != 0)
	_check("flat ground away from the cliff is walkable",
			cliff.is_walkable(2, mid_z) and cliff.is_walkable(cliff.nx - 3, mid_z))


func _test_nav_grid_obstacles() -> void:
	var box := PackedVector2Array([
		Vector2(-5, -5), Vector2(5, -5), Vector2(5, 5), Vector2(-5, 5)])

	# Solid stamping blocks the interior.
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 20.0)
	g.bake_now(Callable(self, "_flat_h"),
			[{"poly": box, "flags": NpcNavGrid.F_BLOCKED}])
	_check("solid obstacle blocks its centre", not g.is_walkable_world(Vector2.ZERO))
	_check("solid obstacle leaves outside clear", g.is_walkable_world(Vector2(12, 0)))
	_check("solid obstacle blocked a sane number of cells",
			g.cell_count() - g.walkable_cell_count() > 100)

	# Wall-band stamping leaves the interior walkable (the 3c building model).
	var w := NpcNavGrid.new()
	w.configure_region(Vector2.ZERO, 20.0)
	w.bake_now(Callable(self, "_flat_h"),
			[{"poly": box, "flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_WALL, "band_m": 0.6}])
	_check("wall band blocks the edge", not w.is_walkable_world(Vector2(5, 0)))
	_check("wall band leaves the interior walkable", w.is_walkable_world(Vector2.ZERO))
	_check("wall band leaves outside walkable", w.is_walkable_world(Vector2(12, 0)))
	var wc := w.cell_of(Vector2(5, 0))
	_check("wall cells carry F_WALL", (w.flags_at(wc.x, wc.y) & NpcNavGrid.F_WALL) != 0)

	# Punching a door reopens the wall and flags it.
	w.clear_flags_in_circle(Vector2(5, 0), 1.2,
			NpcNavGrid.F_BLOCKED | NpcNavGrid.F_WALL, NpcNavGrid.F_DOOR)
	_check("door punched through the wall", w.is_walkable_world(Vector2(5, 0)))
	_check("door cells flagged", (w.flags_at(wc.x, wc.y) & NpcNavGrid.F_DOOR) != 0)
	_check("wall away from the door still blocks", not w.is_walkable_world(Vector2(5, 4)))

	# Interior marking must not block.
	var i := NpcNavGrid.new()
	i.configure_region(Vector2.ZERO, 20.0)
	i.bake_now(Callable(self, "_flat_h"))
	i.stamp_polygon_interior(box, NpcNavGrid.F_INTERIOR | NpcNavGrid.F_STRUCTURE)
	var ic := i.cell_of(Vector2.ZERO)
	_check("interior flagged", (i.flags_at(ic.x, ic.y) & NpcNavGrid.F_INTERIOR) != 0)
	_check("interior stays walkable", i.is_walkable_world(Vector2.ZERO))

	# Off-grid / degenerate polygons are a no-op, not a crash.
	var o := NpcNavGrid.new()
	o.configure_region(Vector2.ZERO, 10.0)
	o.bake_now(Callable(self, "_flat_h"))
	var far := PackedVector2Array([
		Vector2(900, 900), Vector2(910, 900), Vector2(910, 910), Vector2(900, 910)])
	_check("off-grid polygon stamps nothing", o.stamp_polygon(far, NpcNavGrid.F_BLOCKED) == 0)
	_check("degenerate polygon ignored",
			o.stamp_polygon(PackedVector2Array([Vector2.ZERO, Vector2.ONE]),
					NpcNavGrid.F_BLOCKED) == 0)


func _test_nav_grid_queries() -> void:
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 20.0)
	var box := PackedVector2Array([
		Vector2(-3, -3), Vector2(3, -3), Vector2(3, 3), Vector2(-3, 3)])
	g.bake_now(Callable(self, "_ramp_h"), [{"poly": box, "flags": NpcNavGrid.F_BLOCKED}])

	# Out-of-bounds reads are safe and read as blocked.
	_check("oob is blocked", not g.is_walkable(-1, 0) and not g.is_walkable(g.nx, 0))
	_check("oob flags read blocked", (g.flags_at(-5, -5) & NpcNavGrid.F_BLOCKED) != 0)
	_check("oob height safe", g.height_at(-5, -5) == 0.0)

	# A destination inside an obstacle must resolve to a legal spot nearby —
	# tagged spaces often sit inside the very prop that defines them.
	var near := g.nearest_walkable(Vector2.ZERO, 10.0)
	_check("nearest_walkable escapes an obstacle",
			near.x >= 0 and g.is_walkable(near.x, near.y))
	var np := g.center_of(near.x, near.y)
	_check("nearest_walkable stays close", np.length() < 8.0, "%.1f m" % np.length())
	_check("nearest_walkable is a no-op when already clear",
			g.nearest_walkable(Vector2(12, 12), 5.0) == g.cell_of(Vector2(12, 12)))
	_check("nearest_walkable gives up cleanly", g.nearest_walkable(Vector2.ZERO, 0.5).x == -1)

	# World height sampling tracks the ramp.
	_check("height_at_world follows the ramp",
			g.height_at_world(Vector2(10, 0)) > g.height_at_world(Vector2(-10, 0)))

	# Fingerprints: stable input -> stable key; any change -> rebuild.
	var fp := NpcNavGrid.compose_fingerprint(1, 2, 3, 4, Vector2.ZERO, 20.0)
	_check("fingerprint stable",
			fp == NpcNavGrid.compose_fingerprint(1, 2, 3, 4, Vector2.ZERO, 20.0))
	for changed in [
		NpcNavGrid.compose_fingerprint(2, 2, 3, 4, Vector2.ZERO, 20.0),
		NpcNavGrid.compose_fingerprint(1, 9, 3, 4, Vector2.ZERO, 20.0),
		NpcNavGrid.compose_fingerprint(1, 2, 9, 4, Vector2.ZERO, 20.0),
		NpcNavGrid.compose_fingerprint(1, 2, 3, 9, Vector2.ZERO, 20.0),
		NpcNavGrid.compose_fingerprint(1, 2, 3, 4, Vector2(5, 0), 20.0),
		NpcNavGrid.compose_fingerprint(1, 2, 3, 4, Vector2.ZERO, 40.0),
	]:
		_check("fingerprint changes on input change", changed != fp)
	var fg := NpcNavGrid.new()
	fg.configure_region(Vector2.ZERO, 10.0)
	_check("unbaked grid needs rebuild", fg.needs_rebuild(fp))
	fg.bake_now(Callable(self, "_flat_h"), [], fp)
	_check("baked grid matches its fingerprint", not fg.needs_rebuild(fp))
	_check("baked grid rebuilds on a new fingerprint", fg.needs_rebuild(fp + "x"))


# =============================================================================
# Tier 3b — A* and path following
# =============================================================================

## A grid with a full-height wall at x=0 and one gap at z=0. Getting from the
## left half to the right half REQUIRES routing through the gap.
func _walled_grid() -> NpcNavGrid:
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 20.0)
	g.bake_now(Callable(self, "_flat_h"))
	var wall := PackedVector2Array([
		Vector2(-0.4, -20), Vector2(0.4, -20), Vector2(0.4, 20), Vector2(-0.4, 20)])
	g.stamp_polygon(wall, NpcNavGrid.F_BLOCKED)
	g.clear_flags_in_circle(Vector2(0, 0), 1.5, NpcNavGrid.F_BLOCKED, 0)
	return g


## Does the ROUTE (not merely one of its waypoints) come within `radius` of
## `point`? Smoothing collapses straight runs, so a doorway the path clearly
## goes through may have no waypoint on it at all.
func _path_passes_near(from_xz: Vector2, path: PackedVector2Array, point: Vector2,
		radius: float) -> bool:
	var prev := from_xz
	for p in path:
		if Geometry2D.get_closest_point_to_segment(point, prev, p).distance_to(point) <= radius:
			return true
		prev = p
	return false


func _path_is_walkable(g: NpcNavGrid, from_xz: Vector2, path: PackedVector2Array) -> bool:
	var prev := from_xz
	for p in path:
		var steps := maxi(int(prev.distance_to(p) / (g.cell_m * 0.5)), 1)
		for s in range(steps + 1):
			var q := prev.lerp(p, float(s) / float(steps))
			if not g.is_walkable_world(q):
				return false
		prev = p
	return true


func _test_astar_basic() -> void:
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 20.0)
	g.bake_now(Callable(self, "_flat_h"))
	var q := NpcNavQuery.new()
	q.setup(g)
	_check("query ready on a baked grid", q.is_ready())

	# Open ground: the route is essentially the straight line, and smoothing
	# should collapse it to a couple of points rather than 40 cell centres.
	var from_xz := Vector2(-15, -15)
	var to_xz := Vector2(15, 15)
	var path := q.find_path(from_xz, to_xz)
	_check("open path found", path.size() > 0)
	_check("path ends at the destination", path[path.size() - 1].distance_to(to_xz) < 0.01)
	_check("open path is smoothed, not a cell staircase", path.size() <= 4,
			"%d points" % path.size())
	var len_m := NpcNavQuery.path_length(path, from_xz)
	var direct := from_xz.distance_to(to_xz)
	_check("open path is near-direct", len_m < direct * 1.15,
			"%.1f m vs %.1f m" % [len_m, direct])

	# An unready grid must decline rather than crash or block.
	var raw := NpcNavGrid.new()
	raw.configure_region(Vector2.ZERO, 10.0)
	var q2 := NpcNavQuery.new()
	q2.setup(raw)
	_check("unready grid declines", not q2.is_ready())
	_check("unready query returns empty", q2.find_path(Vector2.ZERO, Vector2(5, 5)).is_empty())


func _test_astar_obstacles() -> void:
	var g := _walled_grid()
	var q := NpcNavQuery.new()
	q.setup(g)

	var from_xz := Vector2(-12, -10)
	var to_xz := Vector2(12, -10)
	var path := q.find_path(from_xz, to_xz)
	_check("path around a wall found", path.size() > 0)
	_check("route never crosses a wall", _path_is_walkable(g, from_xz, path))
	# It must detour through the gap at z=0, so it is meaningfully longer than
	# the 24 m straight line that the wall blocks.
	var len_m := NpcNavQuery.path_length(path, from_xz)
	_check("route detours through the gap", len_m > from_xz.distance_to(to_xz) * 1.2,
			"%.1f m vs %.1f m direct" % [len_m, from_xz.distance_to(to_xz)])
	var passes_gap := false
	for p in path:
		if absf(p.x) < 1.0 and absf(p.y) < 2.0:
			passes_gap = true
	_check("route goes through the opening", passes_gap)

	# Sealing the gap makes the far side genuinely unreachable: the query must
	# report failure so the agent falls back, not hang.
	g.stamp_polygon(PackedVector2Array([
		Vector2(-0.4, -20), Vector2(0.4, -20), Vector2(0.4, 20), Vector2(-0.4, 20)]),
		NpcNavGrid.F_BLOCKED)
	var q3 := NpcNavQuery.new()
	q3.setup(g)
	_check("sealed wall makes the far side unreachable",
			q3.find_path(from_xz, to_xz).is_empty())
	_check("failure is counted", int(q3.stats().get("fails", 0)) > 0)


func _test_astar_steps_and_slopes() -> void:
	# A 1.2 m step is at the limit and must be traversable.
	var ok := NpcNavGrid.new()
	ok.configure_region(Vector2.ZERO, 10.0)
	ok.bake_now(Callable(self, "_step_h"))
	var q := NpcNavQuery.new()
	q.setup(ok)
	var p := q.find_path(Vector2(-6, 0), Vector2(6, 0))
	_check("a 1.2 m step is traversable", p.size() > 0)

	# A 1.6 m step exceeds STEP_UP_M and must NOT be climbed.
	var tall := NpcNavGrid.new()
	tall.configure_region(Vector2.ZERO, 10.0)
	tall.bake_now(func(x: float, _z: float) -> float: return 0.0 if x < 0.0 else 1.6)
	var q2 := NpcNavQuery.new()
	q2.setup(tall)
	_check("a 1.6 m step is refused", q2.find_path(Vector2(-6, 0), Vector2(6, 0)).is_empty())

	# Dropping is more permissive than climbing (STEP_DOWN_M > STEP_UP_M): a
	# 2 m drop is fine downhill but must not be climbable back up.
	var ledge := NpcNavGrid.new()
	ledge.configure_region(Vector2.ZERO, 10.0)
	ledge.bake_now(func(x: float, _z: float) -> float: return 2.0 if x < 0.0 else 0.0)
	var q3 := NpcNavQuery.new()
	q3.setup(ledge)
	_check("a 2 m drop is walkable downhill",
			q3.find_path(Vector2(-6, 0), Vector2(6, 0)).size() > 0)
	_check("the same 2 m ledge cannot be climbed",
			q3.find_path(Vector2(6, 0), Vector2(-6, 0)).is_empty())

	# A real staircase is climbable end to end — the headline requirement.
	var stairs := NpcNavGrid.new()
	stairs.configure_region(Vector2(10.0, 0.0), 9.0)
	stairs.bake_now(Callable(self, "_stairs_h"))
	var q4 := NpcNavQuery.new()
	q4.setup(stairs)
	_check("a staircase is climbable", q4.find_path(Vector2(3, 0), Vector2(17, 0)).size() > 0)

	# Climb is penalised, not forbidden. A conical hill sits between the two
	# points: going over it is shorter but costs CLIMB_COST_PER_M per metre
	# climbed, so the route should bulge around the flank instead. (Walking
	# ALONG a ridge crest would be flat and prove nothing — the hill has to be
	# in the way.)
	var hill := NpcNavGrid.new()
	hill.configure_region(Vector2.ZERO, 20.0)
	hill.bake_now(func(x: float, z: float) -> float:
		return maxf(6.0 - Vector2(x, z).length() * 0.5, 0.0))
	var q5 := NpcNavQuery.new()
	q5.setup(hill)
	var over := q5.find_path(Vector2(-15, 0), Vector2(15, 0))
	_check("a crossable hill still yields a path", over.size() > 0)
	var peak := 0.0
	var strays := false
	for pt in over:
		peak = maxf(peak, maxf(6.0 - pt.length() * 0.5, 0.0))
		if absf(pt.y) > 2.0:
			strays = true
	_check("climb cost routes around the hill rather than over the summit",
			strays and peak < 5.0, "detour=%s peak=%.1f m" % [strays, peak])


func _test_astar_cache_and_determinism() -> void:
	var g := _walled_grid()
	var q := NpcNavQuery.new()
	q.setup(g)
	var a := Vector2(-12, -10)
	var b := Vector2(12, -10)

	# First trip is a miss, the second is a hit.
	var p1 := q.path_between_spaces("sp_a", "sp_b", a, b, 0)
	_check("first space-pair query misses", int(q.stats().get("misses", 0)) == 1)
	var p2 := q.path_between_spaces("sp_a", "sp_b", a, b, 0)
	_check("second space-pair query hits", int(q.stats().get("hits", 0)) == 1)
	_check("cached route is identical", p1 == p2)
	_check("cache holds the route", int(q.stats().get("cached", 0)) == 1)

	# Unkeyed trips (agent mid-walk) bypass the cache but still route.
	var p3 := q.path_between_spaces("", "", a, b, 0)
	_check("unkeyed query still routes", p3.size() > 0)
	_check("unkeyed query does not grow the cache",
			int(q.stats().get("cached", 0)) == 1)

	# Lane jitter never moves the destination and never leaves walkable ground,
	# even squeezing through the 1.5 m gap.
	var lane := q.path_between_spaces("sp_a", "sp_b", a, b, 12345)
	_check("lane jitter keeps the destination exact",
			lane[lane.size() - 1].distance_to(b) < 0.01)
	_check("lane jitter stays walkable", _path_is_walkable(g, a, lane))
	# ...and it declines to spread people out in a pinch point: the only
	# interior waypoint here IS the gap, so the route must stay on the
	# centreline rather than clipping the jamb.
	var pinched := true
	for i in range(1, lane.size() - 1):
		if lane[i].distance_to(p1[i]) > 0.01:
			pinched = false
	_check("lane jitter declines in a doorway", pinched)

	# In open ground it DOES spread, which is what gives a desire line width.
	var open_g := NpcNavGrid.new()
	open_g.configure_region(Vector2.ZERO, 30.0)
	open_g.bake_now(Callable(self, "_flat_h"))
	var oq := NpcNavQuery.new()
	oq.setup(open_g)
	var oa := Vector2(-20, -20)
	var ob := Vector2(20, 20)
	var base_path := oq.path_between_spaces("sp_x", "sp_y", oa, ob, 0)
	var offset := 0.0
	for seed_i in [7717, 4242, 99991]:
		var lane_p := oq.path_between_spaces("sp_x", "sp_y", oa, ob, seed_i)
		_check("open-ground lane stays walkable", _path_is_walkable(open_g, oa, lane_p))
		_check("open-ground lane keeps the destination",
				lane_p[lane_p.size() - 1].distance_to(ob) < 0.01)
		for i in range(1, mini(lane_p.size(), base_path.size()) - 1):
			offset = maxf(offset, lane_p[i].distance_to(base_path[i]))
	_check("open ground actually spreads people out",
			offset > 0.05 or base_path.size() < 3,
			"max offset %.2f m over %d pts" % [offset, base_path.size()])

	# Invalidation clears the cache.
	q.invalidate()
	_check("invalidate empties the cache", int(q.stats().get("cached", 0)) == 0)

	# Determinism: a fresh query object on an identically built grid must
	# produce byte-identical routes, or replays diverge.
	var g2 := _walled_grid()
	var qb := NpcNavQuery.new()
	qb.setup(g2)
	_check("paths are deterministic across instances",
			qb.find_path(a, b) == q.find_path(a, b))


func _test_path_following() -> void:
	# advance_path consumes waypoints and reports distance walked.
	var path := PackedVector2Array([Vector2(10, 0), Vector2(10, 10)])
	var r := NpcNav.advance_path(Vector2.ZERO, path, 0, NpcNav.hours_for_distance(4.0))
	_check("walk advances toward the first waypoint",
			(r[0] as Vector2).distance_to(Vector2(4, 0)) < 0.01, str(r[0]))
	_check("walk stays on the first leg", int(r[1]) == 0)
	_check("walk reports distance", absf(float(r[2]) - 4.0) < 0.01)

	# Crossing a waypoint continues along the next leg in the same step.
	var r2 := NpcNav.advance_path(Vector2.ZERO, path, 0, NpcNav.hours_for_distance(15.0))
	_check("walk turns the corner", int(r2[1]) == 1)
	_check("walk position follows the dogleg",
			(r2[0] as Vector2).distance_to(Vector2(10, 5)) < 0.01, str(r2[0]))

	# TELEPORT DEGRADATION: one huge step swallows the whole route and simply
	# arrives — the invariant that keeps mass exact at 450x.
	var r3 := NpcNav.advance_path(Vector2.ZERO, path, 0, 10.0)
	_check("a huge step arrives at the end",
			(r3[0] as Vector2).distance_to(Vector2(10, 10)) < 0.01)
	_check("a huge step consumes the route", int(r3[1]) >= path.size())

	# Remaining distance drives the arrival check.
	_check("path_remaining_m sums the legs",
			absf(NpcNav.path_remaining_m(Vector2.ZERO, path, 0) - 20.0) < 0.01)
	_check("path_remaining_m respects the index",
			absf(NpcNav.path_remaining_m(Vector2(10, 0), path, 1) - 10.0) < 0.01)
	_check("path_remaining_m is zero when done",
			NpcNav.path_remaining_m(Vector2(10, 10), path, 2) == 0.0)


func _test_agent_follows_path() -> void:
	# An agent handed a planner must walk the dogleg rather than the straight
	# line, and must still arrive.
	var site := _make_test_site()
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 60.0)
	g.bake_now(Callable(self, "_flat_h"))
	var q := NpcNavQuery.new()
	q.setup(g)
	var planned := [0]
	var ctx := {
		"registry": site["registry"], "pos_of": site["pos_of"],
		"hour_of_day": 12.0, "starved": {},
		"plan_path": func(from_xz: Vector2, to_xz: Vector2, fk: String, tk: String,
				seed: int) -> Variant:
			planned[0] += 1
			return q.path_between_spaces(fk, tk, from_xz, to_xz, seed),
	}
	var a := NpcAgent.make("walker", Vector2.ZERO)
	a.needs["thirst"] = 1.0
	for n in ["hunger", "bladder", "sleep", "hygiene"]:
		a.needs[n] = 0.0
	a._step_idle(10.0, ctx)
	_check("agent planned a route", planned[0] > 0)
	_check("agent is travelling", a.state == NpcAgent.State.TRAVELING)
	_check("agent holds a path", a.path.size() > 0)

	# Walk it out; the agent must reach the water point and start drinking.
	var t := 10.0
	for i in 400:
		t += 1.0 / 60.0
		a.step(t, 1.0 / 60.0, ctx)
		if a.state == NpcAgent.State.DOING:
			break
	_check("agent arrived and began the activity", a.state == NpcAgent.State.DOING,
			"state=%d" % a.state)
	_check("arrival clears the path", a.path.is_empty())
	_check("agent reached the water point", a.pos.distance_to(Vector2(0, 40)) < 1.0,
			str(a.pos))

	# With no planner at all the agent still works (pre-3b straight lines).
	var b := NpcAgent.make("straight", Vector2.ZERO)
	b.needs["thirst"] = 1.0
	for n in ["hunger", "bladder", "sleep", "hygiene"]:
		b.needs[n] = 0.0
	var bare := {"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": 12.0, "starved": {}}
	b._step_idle(10.0, bare)
	_check("no planner still starts the trip", b.state == NpcAgent.State.TRAVELING)
	_check("no planner means no path", b.path.is_empty())
	var t2 := 10.0
	for i in 400:
		t2 += 1.0 / 60.0
		b.step(t2, 1.0 / 60.0, bare)
		if b.state == NpcAgent.State.DOING:
			break
	_check("straight-line fallback still arrives", b.state == NpcAgent.State.DOING)

	# A planner that declines (budget spent / not ready) must not strand anyone.
	var c := NpcAgent.make("declined", Vector2.ZERO)
	c.needs["thirst"] = 1.0
	for n in ["hunger", "bladder", "sleep", "hygiene"]:
		c.needs[n] = 0.0
	var declining := {"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": 12.0, "starved": {},
			"plan_path": func(_a: Vector2, _b: Vector2, _c: String, _d: String,
					_e: int) -> Variant: return null}
	c._step_idle(10.0, declining)
	var t3 := 10.0
	for i in 400:
		t3 += 1.0 / 60.0
		c.step(t3, 1.0 / 60.0, declining)
		if c.state == NpcAgent.State.DOING:
			break
	_check("a declined plan falls back to straight-line",
			c.state == NpcAgent.State.DOING)


# =============================================================================
# Tier 3c — buildings, doors, upper levels
# =============================================================================

## A 12x8 m building, CCW open ring, centred on the origin.
func _house_poly() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-6, -4), Vector2(6, -4), Vector2(6, 4), Vector2(-6, 4)])


func _test_building_doors() -> void:
	var poly := _house_poly()

	# A declared door converts to a world point on its wall.
	var doors := NpcBuildingNav.declared_doors(poly,
			[{"kind": "door", "edge": 0, "u_m": 6.0, "w_m": 1.0}])
	_check("declared door resolves", doors.size() == 1)
	_check("door sits on its edge", absf(doors[0].y + 4.0) < 0.01, str(doors[0]))
	_check("door sits at u along the edge", absf(doors[0].x) < 0.01, str(doors[0]))

	# Windows are not doors, and out-of-range edges are ignored rather than
	# crashing on a stale style.
	_check("windows are not doors", NpcBuildingNav.declared_doors(poly,
			[{"kind": "window", "edge": 0, "u_m": 3.0}]).is_empty())
	_check("bogus edge ignored", NpcBuildingNav.declared_doors(poly,
			[{"kind": "door", "edge": 99, "u_m": 3.0}]).is_empty())

	# Auto-door faces whatever attracts it, and is deterministic.
	var north := NpcBuildingNav.auto_door(poly, Vector2(0, 40))
	_check("auto door faces the attractor", absf(north.y - 4.0) < 0.01, str(north))
	var east := NpcBuildingNav.auto_door(poly, Vector2(40, 0))
	_check("auto door follows the attractor", absf(east.x - 6.0) < 0.01, str(east))
	_check("auto door is deterministic",
			NpcBuildingNav.auto_door(poly, Vector2(0, 40)) == north)
	_check("auto door lands on the footprint edge",
			absf(NpcBuildingNav._signed_area(poly)) > 0.0)

	# Nearest road point drives the attractor in the real path.
	var roads := [{"points": PackedVector2Array([Vector2(-30, 20), Vector2(30, 20)])}]
	var rp: Variant = NpcBuildingNav.nearest_road_point(roads, Vector2.ZERO)
	_check("nearest road point found", rp is Vector2 and absf((rp as Vector2).y - 20.0) < 0.01)
	_check("distant roads are ignored",
			NpcBuildingNav.nearest_road_point(roads, Vector2(0, 900)) == null)


func _test_building_nav_entries() -> void:
	var poly := _house_poly()

	# A normal building becomes walls + interior + a door.
	var entry := NpcBuildingNav.nav_entry(poly, [], Vector2(0, 40), true)
	_check("building uses a wall band", float(entry.get("band_m", 0.0)) > 0.0)
	_check("building marks its interior", entry.has("interior_flags"))
	_check("building gets an auto door",
			(entry.get("doors", PackedVector2Array()) as PackedVector2Array).size() == 1)
	_check("wall band carries F_WALL",
			(int(entry.get("flags", 0)) & NpcNavGrid.F_WALL) != 0)

	# A declared door wins over the auto one.
	var entry2 := NpcBuildingNav.nav_entry(poly,
			[{"kind": "door", "edge": 2, "u_m": 6.0, "w_m": 1.0}], Vector2(0, 40), true)
	var d2: PackedVector2Array = entry2.get("doors", PackedVector2Array())
	_check("declared door replaces the auto door",
			d2.size() == 1 and absf(d2[0].y - 4.0) < 0.01, str(d2))

	# Auto-doors off + no declared door = a solid block (no way in).
	var solid := NpcBuildingNav.nav_entry(poly, [], Vector2(0, 40), false)
	_check("no doors means solid", not solid.has("band_m"))
	_check("solid block has no interior", not solid.has("interior_flags"))

	# A shed is too small to be worth entering...
	var shed := PackedVector2Array([
		Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
	_check("a tiny shed is solid",
			not NpcBuildingNav.nav_entry(shed, [], Vector2(0, 40), true).has("band_m"))
	# ...unless the player tagged it as an NPC space, which must always be
	# enterable however small it is.
	_check("a tagged shed is forced enterable",
			NpcBuildingNav.nav_entry(shed, [], Vector2(0, 40), true, true).has("band_m"))

	# Degenerate input is ignored, not fatal.
	_check("degenerate footprint yields nothing",
			NpcBuildingNav.nav_entry(PackedVector2Array([Vector2.ZERO]), [],
					Vector2.ZERO, true).is_empty())


func _test_building_grid_integration() -> void:
	var poly := _house_poly()
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 25.0)
	var entry := NpcBuildingNav.nav_entry(poly, [], Vector2(0, 40), true)
	g.bake_now(Callable(self, "_flat_h"), [entry])

	# Walls block, the interior is walkable, and the door is open.
	_check("wall blocks", not g.is_walkable_world(Vector2(-6, 0)))
	_check("interior is walkable", g.is_walkable_world(Vector2.ZERO))
	_check("interior is flagged",
			(g.flags_at(g.cell_of(Vector2.ZERO).x, g.cell_of(Vector2.ZERO).y)
				& NpcNavGrid.F_INTERIOR) != 0)
	var door: Vector2 = (entry["doors"] as PackedVector2Array)[0]
	_check("door is walkable", g.is_walkable_world(door))
	_check("door is flagged",
			(g.flags_at(g.cell_of(door).x, g.cell_of(door).y) & NpcNavGrid.F_DOOR) != 0)
	_check("wall away from the door still blocks",
			not g.is_walkable_world(Vector2(-4, 4)))

	# THE REQUIREMENT: an agent outside can path to a point inside.
	var q := NpcNavQuery.new()
	q.setup(g)
	var inside := q.find_path(Vector2(0, 18), Vector2.ZERO)
	_check("agents can path INTO a building", inside.size() > 0)
	_check("the route through the building is walkable",
			_path_is_walkable(g, Vector2(0, 18), inside))
	# Check the LINE, not the waypoints: smoothing legitimately collapses a
	# straight run through the doorway to its two endpoints.
	_check("the route uses the door",
			_path_passes_near(Vector2(0, 18), inside, door, 1.5), str(inside))

	# And straight through, in one side and out the other, once there are two
	# doors — which is what "pathfind through buildings" means.
	var two := NpcBuildingNav.nav_entry(poly, [
		{"kind": "door", "edge": 0, "u_m": 6.0, "w_m": 1.0},
		{"kind": "door", "edge": 2, "u_m": 6.0, "w_m": 1.0}], Vector2.ZERO, true)
	var g2 := NpcNavGrid.new()
	g2.configure_region(Vector2.ZERO, 25.0)
	g2.bake_now(Callable(self, "_flat_h"), [two])
	var q2 := NpcNavQuery.new()
	q2.setup(g2)
	var through := q2.find_path(Vector2(0, -18), Vector2(0, 18))
	_check("agents can path THROUGH a building", through.size() > 0)
	_check("the through-route is walkable",
			_path_is_walkable(g2, Vector2(0, -18), through))
	_check("the through-route really goes inside",
			_path_passes_near(Vector2(0, -18), through, Vector2.ZERO, 4.0), str(through))

	# A solid (door-less) building must be routed AROUND, never through.
	var g3 := NpcNavGrid.new()
	g3.configure_region(Vector2.ZERO, 25.0)
	g3.bake_now(Callable(self, "_flat_h"),
			[NpcBuildingNav.nav_entry(poly, [], Vector2.ZERO, false)])
	var q3 := NpcNavQuery.new()
	q3.setup(g3)
	var around := q3.find_path(Vector2(0, -18), Vector2(0, 18))
	_check("a sealed building still yields a route around", around.size() > 0)
	for p in around:
		_check("the route never enters a sealed building",
				not (absf(p.x) < 5.5 and absf(p.y) < 3.5), str(p))


func _test_nav_layers() -> void:
	# Without a surfaces_fn the grid stays single-layer.
	var flat := NpcNavGrid.new()
	flat.configure_region(Vector2.ZERO, 10.0)
	flat.bake_now(Callable(self, "_flat_h"))
	_check("no surfaces_fn means one layer", flat.layers == 1)
	_check("no upper surfaces", flat.upper_surface_cells() == 0)

	# A deck 1.0 m above the ground inside a structure footprint. 1.0 m is
	# within STEP_UP_M, so it should be reachable from the ground.
	var deck := PackedVector2Array([
		Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)])
	var g := NpcNavGrid.new()
	g.configure_region(Vector2.ZERO, 15.0)
	g.bake_now(Callable(self, "_flat_h"),
			[{"poly": deck, "flags": NpcNavGrid.F_STRUCTURE, "interior_flags": NpcNavGrid.F_STRUCTURE}],
			"",
			func(x: float, z: float) -> PackedFloat32Array:
				if absf(x) <= 4.0 and absf(z) <= 4.0:
					return PackedFloat32Array([1.0])
				return PackedFloat32Array())
	_check("surfaces_fn allocates layers", g.layers == NpcNavGrid.MAX_LAYERS)
	_check("deck cells gained an upper surface", g.upper_surface_cells() > 50,
			"%d" % g.upper_surface_cells())
	var dc := g.cell_of(Vector2.ZERO)
	_check("upper surface is walkable", g.is_walkable(dc.x, dc.y, 1))
	_check("upper surface carries its height",
			absf(g.height_at(dc.x, dc.y, 1) - 1.0) < 0.01)
	# Off the structure there is no second storey to walk on.
	var oc := g.cell_of(Vector2(10, 10))
	_check("open ground has no upper layer", not g.is_walkable(oc.x, oc.y, 1))

	# The A* must be able to step up onto it (an inter-layer move is just a
	# move whose height delta passes the step limit).
	var q := NpcNavQuery.new()
	q.setup(g)
	_check("agents can reach an upper surface",
			q.find_path(Vector2(-10, 0), Vector2.ZERO).size() > 0)

	# Leniency has a limit. A 4 m deck still registers as a surface, but its
	# delta from the ground below is beyond STEP_UP_M, so the connection rule
	# in NpcNavQuery refuses the move. (The gate itself is proven by the
	# 1.2 m-passes / 1.6 m-refused cases above; asserting it through
	# find_path would prove nothing, because nearest_walkable simply resolves
	# the goal to a legal spot outside the footprint.)
	var high := NpcNavGrid.new()
	high.configure_region(Vector2.ZERO, 15.0)
	high.bake_now(Callable(self, "_flat_h"),
			[{"poly": deck, "flags": NpcNavGrid.F_STRUCTURE,
				"interior_flags": NpcNavGrid.F_STRUCTURE}],
			"",
			func(x: float, z: float) -> PackedFloat32Array:
				if absf(x) <= 4.0 and absf(z) <= 4.0:
					return PackedFloat32Array([4.0])
				return PackedFloat32Array())
	var hc := high.cell_of(Vector2.ZERO)
	_check("a 4 m deck still registers as a surface", high.upper_surface_cells() > 50)
	_check("but it sits beyond the step limit",
			high.height_at(hc.x, hc.y, 1) - high.height_at(hc.x, hc.y, 0)
				> NpcNavQuery.STEP_UP_M + NpcNavQuery.STEP_EPS)
	_check("whereas the 1 m deck is within it",
			g.height_at(dc.x, dc.y, 1) - g.height_at(dc.x, dc.y, 0)
				<= NpcNavQuery.STEP_UP_M + NpcNavQuery.STEP_EPS)
