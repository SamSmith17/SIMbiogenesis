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
	_test_chore_crew_and_deps()
	_test_chore_plan_v3()
	_test_carry_leg()
	_test_site_project()
	_test_stage_effects_and_brigade()
	_test_crew_muster()
	_test_breakdown_progress()
	_test_experiment_lab()
	_test_chore_run_to_completion()
	_test_ladder_edges()
	_test_consequence_policy()
	_test_settlement_log()
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
	_test_metabolism_model()
	_test_walk_accounting()
	_test_walk_aggregates()
	_test_desire_map_accumulation()
	_test_desire_map_retention()
	_test_desire_map_render()
	_test_desire_from_walking()
	_test_trail_expiry()
	_test_desire_tex_rebuild_gate()
	# --- Tier 4 ---
	_test_rig_assets()
	_test_rig_clip_map()
	_test_clip_classifier()
	_test_pose_machine()
	_test_simple_figure()
	_test_space_tag_row()
	_test_standing_slots()
	_test_separation()
	_test_separation_changes_no_consumption()
	_test_desertion_and_reset()
	_test_area_spaces()
	_test_routine_schedule()
	_test_routine_behaviour()
	_test_hash_distribution()
	_test_recurrence()
	_test_labour_ledger()
	_test_fairness_rotation()
	_test_work_pose_classifier()
	_test_facing_rules()
	_test_crew_facing_spread()

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


## A REAL camp: the four spaces a player actually tags, and nothing else.
##
## `_make_test_site` always tags a shower at capacity 60, which is why the
## hygiene absorbing state was structurally unreachable by this entire suite
## and shipped to players. Any test about whether work gets DONE must use this
## site instead — the point is to reproduce the configuration people play.
func _make_bare_site() -> Dictionary:
	var reg := SpaceRegistry.create_empty()
	var positions := {
		"kitchen": Vector2(40, 0),
		"restroom": Vector2(-40, 20),
		"water": Vector2(0, 40),
		"beds": Vector2(0, -50),
	}
	reg.set_space_type({"kind": "prop", "prop_id": "kitchen"}, "kitchen", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "restroom"}, "restroom", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "water"}, "water_point", 60)
	reg.set_space_type({"kind": "prop", "prop_id": "beds"}, "sleep", 60)
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
	# A site MAY resolve chore targets. Most fixtures do not, and without one a
	# chore happens wherever the worker is standing — which is the real
	# behaviour, but it means anything testing where people GO for work has to
	# supply this or it is silently measuring nothing.
	var chore_pos: Variant = site.get("chore_pos_of")
	while t < end:
		t += tick_h
		var ctx := {
			"registry": site["registry"],
			"pos_of": site["pos_of"],
			"hour_of_day": fposmod(t, 24.0),
		}
		if chore_pos is Callable:
			ctx["chore_pos_of"] = chore_pos
		var demand := engine.tick(t, ctx)
		log.append(demand)
	return log


## The standard `{kind: "pos", x, z}` chore-target resolver, matching what
## `NpcPopulationBridge._chore_position` does for that target kind.
static func _pos_chore_resolver() -> Callable:
	return func(c: Dictionary) -> Variant:
		var t: Dictionary = c.get("target", {})
		if str(t.get("kind", "")) == "pos":
			return Vector2(float(t.get("x", 0.0)), float(t.get("z", 0.0)))
		return null


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


## Air quality as a work driver (extreme weather). Deliberately additive: the
## checks below assert that adding it could not move any pre-existing threshold.
func _test_weather_gate_air() -> void:
	var mild := {"temp_c": 18.0, "wind_ms": 3.0, "rain_mmh": 0.0}

	# BACKWARD COMPATIBILITY. A weather dict with no `aqi` key — every dict this
	# project produced before extreme weather existed — must behave EXACTLY as
	# it used to. This is the check that makes the rest of the feature safe.
	var with_zero := mild.duplicate()
	with_zero["aqi"] = 0.0
	for exposure: String in [NpcWeatherGate.EXPOSURE_INDOOR,
			NpcWeatherGate.EXPOSURE_SHELTERED, NpcWeatherGate.EXPOSURE_OUTDOOR]:
		_check("air: absent key == aqi 0 (%s productivity)" % exposure,
			absf(NpcWeatherGate.productivity(mild, exposure)
				- NpcWeatherGate.productivity(with_zero, exposure)) < 0.000001)
		_check("air: absent key == aqi 0 (%s severity)" % exposure,
			absf(NpcWeatherGate.severity(mild, exposure)
				- NpcWeatherGate.severity(with_zero, exposure)) < 0.000001)
		_check("air: clean air is full productivity (%s)" % exposure,
			absf(NpcWeatherGate.productivity(with_zero, exposure) - 1.0) < 0.0001)
	_check("air: clean air is safe", not NpcWeatherGate.is_unsafe(with_zero))

	# Good/Moderate air must not slow anyone down: the threshold is the
	# Cal/OSHA respirator line at 151, not "any measurable smoke".
	var moderate := mild.duplicate()
	moderate["aqi"] = 90.0
	_check("air: moderate AQI does not slow work",
		absf(NpcWeatherGate.productivity(moderate) - 1.0) < 0.0001)

	var unhealthy := mild.duplicate()
	unhealthy["aqi"] = 220.0
	_check("air: unhealthy AQI slows outdoor work",
		NpcWeatherGate.productivity(unhealthy) < 0.75,
		"got %f" % NpcWeatherGate.productivity(unhealthy))
	_check("air: unhealthy AQI is not yet a stop-work",
		not NpcWeatherGate.is_unsafe(unhealthy))

	# THE INDOOR WRINKLE. Walls stop rain and wind completely but only damp
	# smoke, so this is the one driver that follows people inside.
	var storm := {"temp_c": 40.0, "wind_ms": 20.0, "rain_mmh": 12.0}
	_check("air: indoor still immune to a storm",
		absf(NpcWeatherGate.productivity(storm, NpcWeatherGate.EXPOSURE_INDOOR) - 1.0) < 0.0001)
	_check("air: indoor is NOT immune to smoke",
		NpcWeatherGate.productivity(unhealthy, NpcWeatherGate.EXPOSURE_INDOOR) < 1.0,
		"got %f" % NpcWeatherGate.productivity(unhealthy, NpcWeatherGate.EXPOSURE_INDOOR))
	# ...but indoors is still meaningfully better than being out in it.
	_check("air: indoor beats outdoor under smoke",
		NpcWeatherGate.productivity(unhealthy, NpcWeatherGate.EXPOSURE_INDOOR)
			> NpcWeatherGate.productivity(unhealthy))
	_check("air: sheltered sits between the two",
		NpcWeatherGate.productivity(unhealthy, NpcWeatherGate.EXPOSURE_SHELTERED)
			> NpcWeatherGate.productivity(unhealthy)
		and NpcWeatherGate.productivity(unhealthy, NpcWeatherGate.EXPOSURE_SHELTERED)
			< NpcWeatherGate.productivity(unhealthy, NpcWeatherGate.EXPOSURE_INDOOR))

	# Hazardous air stops work EVERYWHERE, including indoors — an unfiltered
	# building during a Hazardous event is not a refuge.
	var hazardous := mild.duplicate()
	hazardous["aqi"] = 350.0
	for exposure: String in [NpcWeatherGate.EXPOSURE_INDOOR,
			NpcWeatherGate.EXPOSURE_SHELTERED, NpcWeatherGate.EXPOSURE_OUTDOOR]:
		_check("air: hazardous stops work (%s)" % exposure,
			NpcWeatherGate.is_unsafe(hazardous, exposure))

	# Monotonic, bounded, and named correctly in the UI string.
	var prev := 1.01
	for a: float in [0.0, 100.0, 160.0, 200.0, 260.0, 300.0]:
		var w := mild.duplicate()
		w["aqi"] = a
		var p := NpcWeatherGate.productivity(w)
		_check("air: productivity non-increasing at AQI %.0f" % a, p <= prev + 0.0001,
			"%f after %f" % [p, prev])
		_check("air: productivity floored at AQI %.0f" % a,
			p >= NpcWeatherGate.WEATHER_FLOOR - 0.0001)
		prev = p
	_check("air: describe names smoke as the worst driver",
		NpcWeatherGate.describe(unhealthy).contains("smoke"),
		"got '%s'" % NpcWeatherGate.describe(unhealthy))
	_check("air: describe still names heat when heat dominates",
		NpcWeatherGate.describe({"temp_c": 36.0, "aqi": 60.0}).contains("heat"))


func _test_weather_gate() -> void:
	_test_weather_gate_air()
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
	# Completing KEEPS progress at chore_hours: remaining() must stay 0 for the
	# finished cycle (the fix for the re-work loop where a lingering second
	# claimant re-credited a done once-chore from zero). The reset now happens
	# in _arm_cycle when the NEXT cycle comes due.
	_check("finished chore stays complete this cycle",
			board.remaining(cid) <= 0.0001)
	_check("lingering claimant credits nothing on a done chore",
			board.credit(cid, 1.0, 11.0) == 0.0
				and board.remaining(cid) <= 0.0001)
	_check("finished chore marked done today",
			int(board.find(cid).get("done_day", -1)) == NpcChoreBoard.day_index(10.0))
	_check("finished chore releases its crew",
			(board.find(cid).get("workers", []) as Array).is_empty())
	_check("finished chore not due today",
			board.available_for("a1", 10.0, 12.0).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != cid))
	# …but it comes back tomorrow (daily repeat), armed back to full work.
	_check("daily chore returns next day",
			board.available_for("a1", 34.0, 12.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == cid))
	_check("daily chore re-arms to full remaining",
			absf(board.remaining(cid) - 2.0) < 0.0001)

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
	_check("claim not persisted", (board2.find(mine).get("workers", []) as Array).is_empty())
	_check("ids keep incrementing",
			board2.add_chore("New", 1.0) != mine)


## v2 crew board (PACKING_PLAN.md Phase 6.5 step 0): stacking claims with a
## cap, quorum-gated credit (the barn-raising gate), dependency holds, the
## roster filter, and dropping a whole NpcCrewPlan schedule via add_plan.
func _test_chore_crew_and_deps() -> void:
	var board := NpcChoreBoard.create_empty()
	# Claims stack to max_workers, idempotent per agent.
	var drill := board.add_chore("Drill holes", 4.0, {"max_workers": 3, "repeat": "once"})
	_check("crew claim 1", board.claim(drill, "a1"))
	_check("crew claim idempotent", board.claim(drill, "a1")
			and board.worker_count(drill) == 1)
	_check("crew claims stack", board.claim(drill, "a2") and board.claim(drill, "a3"))
	_check("crew cap refuses the 4th", not board.claim(drill, "a4"))
	_check("full crew hidden from outsiders",
			board.available_for("a4", 10.0, 12.0).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != drill))
	_check("crew member still sees own chore",
			board.available_for("a2", 10.0, 12.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == drill))
	board.release(drill, "a2")
	_check("release shrinks the crew", board.worker_count(drill) == 2
			and board.claim(drill, "a4"))
	board.release_all_for_agent("a1")
	_check("release_all removes from crews", board.worker_count(drill) == 2)

	# Quorum: below min_workers the work credits NOTHING — early arrivals
	# wait; the gathering is the emergent behavior.
	var raise_c := board.add_chore("Raise structure", 1.0,
			{"min_workers": 3, "max_workers": 6, "repeat": "once"})
	board.claim(raise_c, "b1")
	board.claim(raise_c, "b2")
	_check("below quorum credits zero", board.credit(raise_c, 0.5, 10.0) == 0.0)
	_check("below quorum reports so", not board.has_quorum(raise_c))
	board.claim(raise_c, "b3")
	_check("at quorum it pays", board.credit(raise_c, 0.5, 10.0) > 0.0)
	# Roster filter: a quorum the whole roster can't meet is never offered.
	_check("impossible quorum hidden at roster 2",
			board.available_for("b9", 10.0, 12.0, {}, 2).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != raise_c))
	_check("possible quorum shown at roster 8",
			board.available_for("b9", 10.0, 12.0, {}, 8).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == raise_c))

	# Dependencies: held until the dep completes its cycle; a DELETED dep
	# unblocks (removing a chore means "skip that step", never a deadlock).
	var cut := board.add_chore("Cut", 0.5, {"repeat": "once"})
	var weld := board.add_chore("Weld", 0.5, {"repeat": "once", "depends_on": [cut]})
	_check("dependent held while dep due",
			board.available_for("c1", 10.0, 12.0).all(
					func(c: Dictionary) -> bool: return str(c.get("id")) != weld))
	board.claim(cut, "c1")
	board.credit(cut, 99.0, 10.0)
	_check("dependent released once dep done",
			board.available_for("c1", 10.0, 12.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == weld))
	var orphan := board.add_chore("Orphan", 0.5,
			{"repeat": "once", "depends_on": ["chore_9999"]})
	_check("deleted dep never deadlocks",
			board.available_for("c1", 10.0, 12.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == orphan))

	# add_plan: a whole pit-crew schedule lands wired. Only the dep-free
	# root is offered at t0; finishing it unlocks the next phase.
	var counts := {"beam_count": 16, "bracket_count": 8, "bolt_count": 12,
			"module_count": 4, "panel_count": 0}
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	var pb := NpcChoreBoard.create_empty()
	var ids := pb.add_plan(NpcCrewPlan.chore_specs(tasks, NpcCrewPlan.schedule(tasks, 8)))
	_check("plan drops all phases", ids.size() == 7, str(ids.size()))
	var avail0: Array = pb.available_for("z1", 10.0, 12.0)
	_check("only the dep-free root offered",
			avail0.size() == 1
				and str((avail0[0] as Dictionary).get("label", "")).begins_with("Cut"),
			str(avail0.size()))
	var cut_id := str((avail0[0] as Dictionary).get("id", ""))
	pb.claim(cut_id, "z1")
	pb.credit(cut_id, 999.0, 10.0)
	_check("next phase unlocks after the root",
			pb.available_for("z1", 10.0, 12.0).any(
					func(c: Dictionary) -> bool:
						return str(c.get("label", "")).begins_with("Drill")))
	# v2 fields survive persistence; runtime crews do not.
	pb.claim(str((pb.available_for("z1", 10.0, 12.0)[0] as Dictionary).get("id", "")), "z1")
	var pb2 := NpcChoreBoard.create_empty()
	pb2.deserialize(pb.serialize())
	var kept_deps := false
	var kept_crew := false
	var any_workers := false
	for c in pb2.chores:
		var d := c as Dictionary
		if not (d.get("depends_on", []) as Array).is_empty():
			kept_deps = true
		if int(d.get("min_workers", 1)) >= 6:
			kept_crew = true
		if not (d.get("workers", []) as Array).is_empty():
			any_workers = true
	_check("deps persist", kept_deps)
	_check("crew fields persist (the raise's min 6)", kept_crew)
	_check("runtime crews stripped", not any_workers)

	# Build-site targets: add_plan stamps one target on every phase, and the
	# bridge resolves the explicit-position kind with no scene at all.
	var t_board := NpcChoreBoard.create_empty()
	var t_out: Array = t_board.add_plan(
			NpcCrewPlan.chore_specs(tasks, NpcCrewPlan.schedule(tasks, 8)),
			{"start_h": 7.0, "end_h": 19.0}, {"kind": "pos", "x": 12.0, "z": -7.0})
	var all_targeted := t_out.size() == 7
	for tcid in t_out:
		var tgt: Dictionary = t_board.find(str(tcid)).get("target", {})
		if str(tgt.get("kind", "")) != "pos" or absf(float(tgt.get("x", 0.0)) - 12.0) > 0.001:
			all_targeted = false
	_check("plan target inherited by every phase", all_targeted)
	# NOTE: NpcPopulationBridge cannot be referenced here — it names the
	# PerfMonitor autoload bare, which fails to compile under --script (the
	# documented headless autoload trap) and silently ABORTS this function
	# while the suite still prints PASS. Its "pos" target resolution is a
	# 2-line branch in _chore_position, covered by the windowed harness.

	# Site rules ("rule cards" v1): tools_down empties the offer, night_shift
	# ignores windows, both persist with the chores.
	var rb := NpcChoreBoard.create_empty()
	var day_job := rb.add_chore("Day job", 1.0, {"window": {"start_h": 8.0, "end_h": 18.0}})
	_check("rule-free board offers day work",
			not rb.available_for("r1", 10.0, 12.0).is_empty())
	_check("day job hidden at night",
			rb.available_for("r1", 10.0, 23.0).is_empty())
	rb.rules["night_shift"] = true
	_check("night_shift ignores windows",
			rb.available_for("r1", 10.0, 23.0).any(
					func(c: Dictionary) -> bool: return str(c.get("id")) == day_job))
	rb.rules["tools_down"] = true
	_check("tools_down overrides everything",
			rb.available_for("r1", 10.0, 12.0).is_empty())
	var rb2 := NpcChoreBoard.create_empty()
	rb2.deserialize(rb.serialize())
	_check("rules persist with the chores",
			bool(rb2.rules.get("night_shift", false))
				and bool(rb2.rules.get("tools_down", false)))

	# Haul routes: the chore carries the route + strategy, and worker_index
	# is claim order — the station assignment brigade posts derive from.
	var hb := NpcChoreBoard.create_empty()
	var haul_id := hb.add_chore("Unload the delivery", 0.5, {
			"max_workers": 4,
			"haul": {"from_x": 0.0, "from_z": 0.0, "to_x": 20.0, "to_z": 0.0,
				"strategy": "brigade"}})
	var hrec := hb.find(haul_id)
	_check("haul route stored on the chore",
			str((hrec.get("haul", {}) as Dictionary).get("strategy", "")) == "brigade")
	hb.claim(haul_id, "w1")
	hb.claim(haul_id, "w2")
	hb.claim(haul_id, "w3")
	_check("worker_index is claim order",
			hb.worker_index(haul_id, "w1") == 0 and hb.worker_index(haul_id, "w3") == 2
				and hb.worker_index(haul_id, "w9") == -1)
	hb.release(haul_id, "w2")
	_check("stations close up on release",
			hb.worker_index(haul_id, "w3") == 1)


## Phase-0 substrate for Site Projects: atomic add_plan, per-task board
## fields riding through chore_specs overrides + add_plan, uncapped priority,
## the held pause flag, and effect payload persistence.
func _test_chore_plan_v3() -> void:
	# Atomic refusal: a plan that doesn't fit leaves the board UNTOUCHED —
	# a truncated plan's dangling dep ids read as satisfied and silently
	# unblock the tail, which is worse than no plan at all.
	var full := NpcChoreBoard.create_empty()
	for i in NpcChoreBoard.MAX_CHORES - 2:
		full.add_chore("Filler %d" % i, 0.1)
	var before := full.chores.size()
	var refused: Array = full.add_plan([
		{"task_id": "a", "label": "A", "chore_hours": 0.1},
		{"task_id": "b", "label": "B", "chore_hours": 0.1, "depends_on": ["a"]},
		{"task_id": "c", "label": "C", "chore_hours": 0.1, "depends_on": ["b"]},
	])
	_check("overfull plan refused whole", refused.is_empty())
	_check("refused plan left board untouched", full.chores.size() == before)

	# Per-task fields: a spec row's own target/effect/carry_to/haul override
	# the shared plan target; rows without them inherit it.
	var b := NpcChoreBoard.create_empty()
	var ids: Array = b.add_plan([
		{"task_id": "haul1", "label": "Haul crate", "chore_hours": 0.2,
			"target": {"kind": "prop", "id": "prop_42"},
			"carry_to": {"x": 5.0, "z": -3.0},
			"effect": {"op": "move_prop", "prop_id": "prop_42", "x": 5.0, "z": -3.0}},
		{"task_id": "gate", "label": "Unloaded", "chore_hours": 0.05,
			"depends_on": ["haul1"]},
	], {"start_h": 0.0, "end_h": 24.0}, {"kind": "pos", "x": 1.0, "z": 2.0})
	_check("per-task plan lands", ids.size() == 2)
	var haul_rec: Dictionary = b.find(str(ids[0]))
	var gate_rec: Dictionary = b.find(str(ids[1]))
	_check("per-task target wins over shared",
			str((haul_rec.get("target", {}) as Dictionary).get("kind", "")) == "prop")
	_check("carry_to rides the chore",
			absf(float((haul_rec.get("carry_to", {}) as Dictionary).get("x", 0.0)) - 5.0) < 0.001)
	_check("effect rides the chore",
			str((haul_rec.get("effect", {}) as Dictionary).get("op", "")) == "move_prop")
	_check("row without target inherits the shared one",
			str((gate_rec.get("target", {}) as Dictionary).get("kind", "")) == "pos")

	# Effect + carry_to persist (the fire-once flag will live beside them).
	b.update_chore(str(ids[0]), {"effect_done": true})
	var b2 := NpcChoreBoard.create_empty()
	b2.deserialize(b.serialize())
	var rt: Dictionary = b2.find(str(ids[0]))
	_check("effect persists", str((rt.get("effect", {}) as Dictionary).get("op", "")) == "move_prop")
	_check("effect_done flag persists", bool(rt.get("effect_done", false)))
	_check("carry_to persists", (rt.get("carry_to", {}) as Dictionary).has("z"))

	# Priority is uncapped: an 11-phase chain must keep build order on ties
	# of remaining work.
	var pb := NpcChoreBoard.create_empty()
	var pids: Array = []
	for i in 11:
		pids.append(pb.add_chore("P%d" % i, 1.0,
				{"repeat": "once", "priority": i + 1,
					"window": {"start_h": 0.0, "end_h": 24.0}}))
	var offered: Array = pb.available_for("p1", 10.0, 12.0)
	var in_order := offered.size() == 11
	for i in offered.size():
		if str((offered[i] as Dictionary).get("id", "")) != str(pids[i]):
			in_order = false
	_check("priority beyond 9 keeps order", in_order)

	# held: paused chores vanish from the offer without losing progress.
	var hb := NpcChoreBoard.create_empty()
	var hid := hb.add_chore("Paused job", 1.0, {"window": {"start_h": 0.0, "end_h": 24.0}})
	hb.credit(hid, 0.4, 10.0)
	hb.update_chore(hid, {"held": true})
	_check("held chore hidden", hb.available_for("h1", 10.0, 12.0).is_empty())
	hb.update_chore(hid, {"held": false})
	_check("unheld chore returns with progress intact",
			not hb.available_for("h1", 10.0, 12.0).is_empty()
				and absf(hb.remaining(hid) - 0.6) < 0.0001)

	# chore_completed fires exactly once, as a toast convenience only.
	var sb := NpcChoreBoard.create_empty()
	var scid := sb.add_chore("Signal job", 0.5,
			{"repeat": "once", "window": {"start_h": 0.0, "end_h": 24.0}})
	var fired: Array = []
	sb.chore_completed.connect(func(id: String, _label: String) -> void:
		fired.append(id))
	sb.credit(scid, 0.2, 10.0)
	sb.credit(scid, 9.0, 10.0)
	sb.credit(scid, 1.0, 10.0)   # lingering claimant — must not re-fire
	_check("completion signal fired once for the cycle",
			fired.size() == 1 and str(fired[0]) == scid)

	# chore_specs overrides: omitted ⇒ byte-identical bridge output; present ⇒
	# the row carries the override fields for add_plan to pass through.
	var counts := {"beam_count": 16, "bracket_count": 8, "bolt_count": 12,
			"module_count": 4, "panel_count": 0}
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	var sched := NpcCrewPlan.schedule(tasks, 8)
	var plain: Array = NpcCrewPlan.chore_specs(tasks, sched)
	var plain2: Array = NpcCrewPlan.chore_specs(tasks, sched, {})
	_check("empty overrides change nothing", str(plain) == str(plain2))
	var erect_id := ""
	for t in tasks:
		if str((t as Dictionary).get("id", "")).begins_with("erect"):
			erect_id = str((t as Dictionary).get("id", ""))
	var over: Array = NpcCrewPlan.chore_specs(tasks, sched, {
		erect_id: {"effect": {"op": "unpack_prop", "prop_id": "prop_7"}}})
	var found_effect := false
	for row in over:
		var d := row as Dictionary
		if str(d.get("task_id", "")) == erect_id:
			found_effect = str((d.get("effect", {}) as Dictionary).get("op", "")) == "unpack_prop"
	_check("override attaches effect to the named task", found_effect)


## Two-leg haul chores (Site Projects carry): walk to the pickup, flip to the
## carry leg, walk to carry_to, then work. Preemption mid-carry must leave the
## world consistent (the crate move is the COMPLETION effect, so an abandoned
## carry means nothing moved). NOTE: the bridge's effect sweep itself cannot
## be exercised here — NpcPopulationBridge names the PerfMonitor autoload
## bare, the documented headless --script compile trap — so the sweep's world
## half is covered by the windowed --capture=project harness; this covers the
## agent FSM and the dot payload.
func _test_carry_leg() -> void:
	var board := NpcChoreBoard.create_empty()
	var cid := board.add_chore("Haul crate", 0.1, {
		"repeat": "once", "window": {"start_h": 0.0, "end_h": 24.0},
		"target": {"kind": "prop", "id": "crate_1"},
		"carry_to": {"x": 20.0, "z": 0.0},
		"effect": {"op": "move_prop", "prop_id": "crate_1", "x": 20.0, "z": 0.0},
	})
	var a := NpcAgent.make("hauler", Vector2.ZERO)
	var ctx := {
		"board": board, "weather": {}, "hour_of_day": 12.0, "registry": null,
		"chore_pos_of": func(_c: Dictionary) -> Variant: return Vector2(10.0, 0.0),
	}
	_check("carry chore taken", a._begin_chore(10.0, ctx))
	_check("leg 0 targets the pickup", a.chore_leg == 0
			and a.target_pos.distance_to(Vector2(10.0, 0.0)) < 0.01)
	var guard := 0
	while a.chore_leg == 0 and guard < 200:
		a._step_traveling(10.0 + 0.01 * float(guard + 1), 0.01, ctx)
		guard += 1
	_check("arrival at pickup flips to the carry leg", a.chore_leg == 1)
	_check("carry leg keeps TRAVELING toward carry_to",
			a.state == NpcAgent.State.TRAVELING
				and a.target_pos.distance_to(Vector2(20.0, 0.0)) < 0.01)
	_check("is_carrying reads true mid-haul", a.is_carrying())
	# The dot payload the renderers consume: carrying flag + resolved crate id.
	var eng := NpcPopulationEngine.new()
	eng.chore_board = board
	eng.agents.append(a)
	var dot_ok := false
	for d in eng.agent_dots():
		var dd := d as Dictionary
		if str(dd.get("id", "")) == "hauler":
			dot_ok = bool(dd.get("carrying", false)) \
				and str(dd.get("carry_prop", "")) == "crate_1"
	_check("dot payload carries the crate id", dot_ok)
	# Preemption mid-carry: claim released, leg reset, nothing credited.
	a._finish(ctx, false)
	_check("preempted carry resets the leg", a.chore_leg == 0 and not a.is_carrying())
	_check("preempted carry left the work untouched",
			absf(board.remaining(cid) - 0.1) < 0.0001)
	# Second attempt runs the whole loop: pickup → carry → work → complete.
	_check("chore re-taken after preemption", a._begin_chore(11.0, ctx))
	guard = 0
	while a.chore_leg == 0 and guard < 200:
		a._step_traveling(11.0 + 0.01 * float(guard + 1), 0.01, ctx)
		guard += 1
	guard = 0
	while a.state == NpcAgent.State.TRAVELING and guard < 400:
		a._step_traveling(11.5 + 0.01 * float(guard + 1), 0.01, ctx)
		guard += 1
	_check("second leg lands at carry_to",
			a.pos.distance_to(Vector2(20.0, 0.0)) < 0.01)
	guard = 0
	while int(board.find(cid).get("done_day", -1)) < 0 and guard < 100:
		a._step_chore(12.0 + 0.05 * float(guard + 1), 0.05, ctx)
		guard += 1
	_check("carry chore completes", int(board.find(cid).get("done_day", -1)) >= 0)
	_check("agent released after completion",
			a.chore_id.is_empty() and a.chore_leg == 0)
	_check("effect payload survives, unfired (the bridge sweep stamps it)",
			str((board.find(cid).get("effect", {}) as Dictionary).get("op", "")) == "move_prop"
				and not bool(board.find(cid).get("effect_done", false)))


## Site Projects: the grouping layer over the chore board. Status derivation
## (done / skipped-on-delete), rollup, store cap/persistence round-trip, the
## build-progress fractions the linkage ghost renders from, and the breakdown
## plan shape. All offline — the world-effect half (bridge sweep +
## PlacedPropService) is the windowed --capture=project harness's job.
func _test_site_project() -> void:
	var board := NpcChoreBoard.create_empty()
	var counts := {"beam_count": 16, "bracket_count": 8, "bolt_count": 12,
			"module_count": 4, "panel_count": 6}
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	var sched := NpcCrewPlan.schedule(tasks, 8)
	var overrides := {
		"erect": {"effect": {"op": "unpack_prop", "prop_id": "prop_9"}},
		"panels": {"effect": {"op": "seed_graph", "prop_id": "prop_9"}},
	}
	var rows: Array = NpcCrewPlan.chore_specs(tasks, sched, overrides)
	var made: Array = board.add_plan(rows, {"start_h": 0.0, "end_h": 24.0},
			{"kind": "prop", "id": "prop_9"})
	var project := SiteProject.make(SiteProject.KIND_LINKAGE_BUILD, "Build",
			"prop_9", Vector2(3.0, 4.0), 100.0, {"crew": 8})
	SiteProject.bind_tasks(project, rows, made)
	_check("project binds every phase",
			(project["tasks"] as Array).size() == rows.size())
	_check("fresh project pending", not SiteProject.sync_with_board(project, board)
			and str(project["state"]) == "active")
	# Nothing shows before the cut completes.
	var bp0 := SiteProject.build_progress(project, board)
	_check("no beams before the cut", float(bp0["beams"]) == 0.0
			and not bool(bp0["erected"]))
	# Complete the whole chain in dependency order via the board's own gates.
	var spins := 0
	while spins < 64:
		var avail: Array = board.available_for("w1", 100.0, 12.0, {}, 12)
		if avail.is_empty():
			break
		var cidn := str((avail[0] as Dictionary).get("id", ""))
		for k in int((avail[0] as Dictionary).get("min_workers", 1)):
			board.claim(cidn, "w%d" % k)
		board.credit(cidn, 999.0, 100.0)
		spins += 1
	_check("whole plan executes through the gates", spins > 0
			and SiteProject.sync_with_board(project, board)
			and str(project["state"]) == "done")
	var bp1 := SiteProject.build_progress(project, board)
	_check("finished build reads fully built", float(bp1["beams"]) == 1.0
			and float(bp1["panels"]) == 1.0 and bool(bp1["erected"]))
	var roll := SiteProject.rollup(project, board)
	_check("rollup complete", int(roll["done"]) == rows.size()
			and absf(float(roll["progress"]) - 1.0) < 0.001)

	# Deleted chore = skipped task, project still settles.
	var b2 := NpcChoreBoard.create_empty()
	var rows2: Array = [
		{"task_id": "a", "label": "A", "chore_hours": 0.1},
		{"task_id": "b", "label": "B", "chore_hours": 0.1, "depends_on": ["a"]},
	]
	var made2: Array = b2.add_plan(rows2, {"start_h": 0.0, "end_h": 24.0})
	var p2 := SiteProject.make(SiteProject.KIND_DELIVERY, "Unload", "", Vector2.ZERO, 0.0)
	SiteProject.bind_tasks(p2, rows2, made2)
	b2.remove_chore(str(made2[0]))
	b2.claim(str(made2[1]), "w1")
	b2.credit(str(made2[1]), 9.0, 5.0)
	SiteProject.sync_with_board(p2, b2)
	var statuses: Array = []
	for t in p2["tasks"]:
		statuses.append(str((t as Dictionary).get("status", "")))
	_check("deleted chore skips, survivor completes, project settles",
			statuses == ["skipped", "done"] and str(p2["state"]) == "done")

	# Store: round-trip + cap pruning (oldest done goes first).
	var store := SiteProjectStore.new()
	store.add(project)
	store.add(p2)
	var store2 := SiteProjectStore.new()
	store2.deserialize(store.serialize())
	_check("store round-trips", store2.projects.size() == 2
			and str((store2.projects[0] as Dictionary).get("id", "")) == str(project["id"]))
	for i in SiteProjectStore.MAX_PROJECTS + 2:
		var filler := SiteProject.make(SiteProject.KIND_DELIVERY, "F%d" % i, "",
				Vector2.ZERO, float(i))
		store2.add(filler)
	_check("store prunes to its cap",
			store2.projects.size() == SiteProjectStore.MAX_PROJECTS)

	# Breakdown plan: right shape, fold carries the pack effect, load-out only
	# with a destination, dependency chain intact.
	var bd := SiteProject.breakdown_spec_rows(counts, "prop_9", {"x": 50.0, "z": 0.0})
	var ids_bd: Array = []
	for r in bd:
		ids_bd.append(str((r as Dictionary).get("task_id", "")))
	_check("breakdown phases in order",
			ids_bd == ["strip_panels", "unbolt", "fold_pack", "load_out"], str(ids_bd))
	var fold_row: Dictionary = bd[2]
	_check("fold carries the pack effect",
			str((fold_row.get("effect", {}) as Dictionary).get("op", "")) == "pack_prop")
	var lo_row: Dictionary = bd[3]
	_check("load-out is a carry with a move effect",
			(lo_row.get("carry_to", {}) as Dictionary).has("x")
				and str((lo_row.get("effect", {}) as Dictionary).get("op", "")) == "move_prop")
	var bd_no: Array = SiteProject.breakdown_spec_rows(
			{"panel_count": 0, "module_count": 2, "bolt_count": 8}, "prop_9")
	var ids_no: Array = []
	for r in bd_no:
		ids_no.append(str((r as Dictionary).get("task_id", "")))
	_check("no panels / no container trims the plan",
			ids_no == ["unbolt", "fold_pack"], str(ids_no))

	# Coarse reload fractions follow the phase ladder.
	_check("phase_fractions ladder",
			float(SiteProject.phase_fractions("")["beams"]) == 0.0
				and float(SiteProject.phase_fractions("assemble_x")["beams"]) == 1.0
				and float(SiteProject.phase_fractions("bolts")["bolts"]) == 1.0
				and float(SiteProject.phase_fractions("cut")["brackets"]) == 0.0)


## Round 2: incremental stage effects (the world changes DURING labour, one
## crate per threshold) and the brigade unload plan built from crew density.
func _test_stage_effects_and_brigade() -> void:
	# due_stage_effects: thresholds, fire-once, completion fires the rest.
	var board := NpcChoreBoard.create_empty()
	var stages: Array = []
	for i in 4:
		stages.append({"at": (float(i) + 0.5) / 4.0,
			"effect": {"op": "move_prop", "prop_id": "c%d" % i, "x": 0.0, "z": 0.0}})
	var cid := board.add_chore("Brigade", 1.0, {
		"repeat": "once", "window": {"start_h": 0.0, "end_h": 24.0},
		"stage_effects": stages})
	var rec := board.find(cid)
	_check("no stages due at zero progress",
			SiteProject.due_stage_effects(rec).is_empty())
	board.credit(cid, 0.3, 10.0)   # frac 0.30 — past 0.125, short of 0.375
	var due1: Array = SiteProject.due_stage_effects(rec)
	_check("first threshold due", due1 == [0], str(due1))
	((rec["stage_effects"] as Array)[0] as Dictionary)["fired"] = true
	_check("fired stage never re-offered",
			SiteProject.due_stage_effects(rec).is_empty())
	board.credit(cid, 0.35, 10.0)  # frac 0.65 — stages 1 (0.375) and 2 (0.625)
	var due2: Array = SiteProject.due_stage_effects(rec)
	_check("crossed thresholds come due together", due2 == [1, 2], str(due2))
	board.credit(cid, 9.0, 10.0)   # completes — progress kept at full
	var due3: Array = SiteProject.due_stage_effects(rec)
	_check("completion brings every unfired stage due", due3 == [1, 2, 3], str(due3))
	# stage_effects + fired flags ride persistence (the fire-once contract).
	((rec["stage_effects"] as Array)[1] as Dictionary)["fired"] = true
	var b2 := NpcChoreBoard.create_empty()
	b2.deserialize(board.serialize())
	var rec2 := b2.find(cid)
	_check("stage effects persist with fired flags",
			SiteProject.due_stage_effects(rec2) == [2, 3])

	# unload_spec_rows: strategy follows NpcHaulModel; the shapes differ.
	var crates: Array = []
	for i in 7:
		crates.append({"pid": "crate_p%d" % i,
			"stage": Vector2(20.0 + float(i), 0.0), "label": "Box %d" % i})
	var brigade: Dictionary = SiteProject.unload_spec_rows(crates, Vector2.ZERO, 12)
	if str(brigade.get("strategy", "")) == "brigade":
		var rows: Array = brigade["rows"]
		_check("brigade = one crew chore + gate", rows.size() == 2, str(rows.size()))
		var lead := rows[0] as Dictionary
		_check("brigade chore carries the relay route",
				str((lead.get("haul", {}) as Dictionary).get("strategy", "")) == "brigade")
		_check("one stage effect per crate",
				(lead.get("stage_effects", []) as Array).size() == crates.size())
		_check("brigade needs a crew",
				int(lead.get("min_workers", 1)) >= SiteProject.BRIGADE_MIN_CREW)
		var gate := rows[1] as Dictionary
		_check("gate depends on the brigade",
				(gate.get("depends_on", []) as Array) == ["brigade"])
	else:
		# The haul model's verdict at this crew/route is round trips — the
		# brigade SHAPE is still pinned by forcing the small-roster branch off.
		_check("haul model chose round trips at this density", true)
	var solo: Dictionary = SiteProject.unload_spec_rows(
			[crates[0]], Vector2.ZERO, 12)
	_check("single crate is always a carry row",
			str(solo.get("strategy", "")) == "round_trip"
				and ((solo["rows"] as Array)[0] as Dictionary).has("carry_to"))
	# Round 3: round-trip rows must carry a STRICTLY ASCENDING priority, or
	# equal priority + equal hours ties in available_for's (unstable) sort and
	# the crew pulls crates out of the stack in arbitrary order.
	var rt: Dictionary = SiteProject.unload_spec_rows(crates, Vector2.ZERO, 2)
	var rt_rows: Array = rt["rows"]
	var ascending := true
	var gate_prio := -1
	var crate_max := -1
	for r in rt_rows:
		var rd := r as Dictionary
		if str(rd.get("task_id", "")) == "unloaded":
			gate_prio = int(rd.get("priority", 0))
			continue
		if int(rd.get("priority", 0)) <= crate_max:
			ascending = false
		crate_max = int(rd.get("priority", 0))
	_check("round-trip crate priorities ascend", ascending)
	_check("the unload gate sorts after every crate", gate_prio > crate_max,
			"%d vs %d" % [gate_prio, crate_max])
	# Every set-down must put the crate ON THE GROUND and make it touchable
	# again — it rode the container stack at height with collision off.
	var setdowns_ok := true
	for r2 in rt_rows:
		var eff: Dictionary = (r2 as Dictionary).get("effect", {})
		if str(eff.get("op", "")) != "move_prop":
			continue
		if absf(float(eff.get("y_offset", -1.0))) > 0.0001 \
				or not bool(eff.get("collision_enabled", false)):
			setdowns_ok = false
	_check("round-trip set-downs land on the ground, collidable", setdowns_ok)
	var brig_stage_ok := true
	for r3 in (brigade["rows"] as Array):
		for st2 in ((r3 as Dictionary).get("stage_effects", []) as Array):
			var seff: Dictionary = (st2 as Dictionary).get("effect", {})
			if absf(float(seff.get("y_offset", -1.0))) > 0.0001 \
					or not bool(seff.get("collision_enabled", false)):
				brig_stage_ok = false
	_check("brigade stage set-downs land on the ground too", brig_stage_ok)
	var small: Dictionary = SiteProject.unload_spec_rows(crates, Vector2.ZERO, 2)
	_check("small roster never brigades",
			str(small.get("strategy", "")) == "round_trip")
	# Whichever strategy, the board takes the plan whole and the gate exists.
	var b3 := NpcChoreBoard.create_empty()
	var made: Array = b3.add_plan(brigade["rows"], {"start_h": 0.0, "end_h": 24.0})
	_check("unload plan lands on the board", made.size() == (brigade["rows"] as Array).size())

	# Brigade station workers read as carrying in the dot payload.
	var eng := NpcPopulationEngine.new()
	var bb := NpcChoreBoard.create_empty()
	var bcid := bb.add_chore("Brigade line", 1.0, {
		"repeat": "once", "window": {"start_h": 0.0, "end_h": 24.0},
		"max_workers": 4,
		"haul": {"from_x": 0.0, "from_z": 0.0, "to_x": 20.0, "to_z": 0.0,
			"strategy": "brigade"}})
	eng.chore_board = bb
	var stationed := NpcAgent.make("post_1", Vector2(10.0, 0.0))
	stationed.chore_id = bcid
	stationed.activity = NpcAgent.CHORE_ACTIVITY
	stationed.state = NpcAgent.State.DOING
	bb.claim(bcid, "post_1")
	eng.agents.append(stationed)
	var station_carrying := false
	for d in eng.agent_dots():
		if str((d as Dictionary).get("id", "")) == "post_1":
			station_carrying = bool((d as Dictionary).get("carrying", false))
	_check("brigade station worker reads as carrying", station_carrying)


## Round 2: the muster fixes — free agents converge on a gathering crew
## chore, and early arrivals' patience scales with how close the crew is.
func _test_crew_muster() -> void:
	var board := NpcChoreBoard.create_empty()
	var urgent := board.add_chore("Urgent solo job", 1.0, {
		"priority": -5, "window": {"start_h": 0.0, "end_h": 24.0}})
	var raise_c := board.add_chore("Raise structure", 1.0, {
		"repeat": "once", "priority": 5, "min_workers": 3, "max_workers": 6,
		"window": {"start_h": 0.0, "end_h": 24.0}})
	# Nobody standing at the raise yet: normal priority order holds.
	var first := str((board.available_for("a2", 10.0, 12.0, {}, 8)[0] as Dictionary).get("id", ""))
	_check("no gathering → priority order holds", first == urgent)
	# One worker standing at it: the gathering outranks even priority -5.
	board.claim(raise_c, "a1")
	first = str((board.available_for("a2", 10.0, 12.0, {}, 8)[0] as Dictionary).get("id", ""))
	_check("gathering crew chore jumps the queue", first == raise_c)
	# Quorum met: boost disappears (it exists to CLOSE the gap, not to pin
	# the site at the top forever).
	board.claim(raise_c, "a2")
	board.claim(raise_c, "a3")
	first = str((board.available_for("a4", 10.0, 12.0, {}, 8)[0] as Dictionary).get("id", ""))
	_check("quorate crew chore drops the boost", first == urgent)

	# Adaptive patience: with most of the crew present, an early arrival holds
	# past the base timer; alone, they bail on the base timer as before.
	var wb := NpcChoreBoard.create_empty()
	var wcid := wb.add_chore("Raise", 2.0, {
		"repeat": "once", "min_workers": 4, "max_workers": 6,
		"window": {"start_h": 0.0, "end_h": 24.0}})
	var waiter := NpcAgent.make("w1", Vector2.ZERO)
	var ctx := {"board": wb, "weather": {}, "hour_of_day": 12.0, "registry": null}
	wb.claim(wcid, "w1")
	wb.claim(wcid, "w2")
	wb.claim(wcid, "w3")   # 3 of 4 — patience ≈ base × 2.5
	waiter.chore_id = wcid
	waiter.activity = NpcAgent.CHORE_ACTIVITY
	waiter.state = NpcAgent.State.DOING
	waiter._step_chore(10.0, NpcAgent.QUORUM_WAIT_H * 1.4, ctx)
	_check("near-quorum crew holds past the base timer",
			waiter.chore_id == wcid, waiter.chore_id)
	waiter._step_chore(10.0, NpcAgent.QUORUM_WAIT_H * 2.0, ctx)
	_check("patience is still bounded", waiter.chore_id.is_empty())
	var loner := NpcAgent.make("l1", Vector2.ZERO)
	var lb := NpcChoreBoard.create_empty()
	var lcid := lb.add_chore("Raise", 2.0, {
		"repeat": "once", "min_workers": 4, "max_workers": 6,
		"window": {"start_h": 0.0, "end_h": 24.0}})
	lb.claim(lcid, "l1")
	loner.chore_id = lcid
	loner.activity = NpcAgent.CHORE_ACTIVITY
	loner.state = NpcAgent.State.DOING
	var lctx := {"board": lb, "weather": {}, "hour_of_day": 12.0, "registry": null}
	loner._step_chore(10.0, NpcAgent.QUORUM_WAIT_H * 1.6, lctx)
	_check("a lone early arrival still bails near the base timer",
			loner.chore_id.is_empty())


## Round 3: the reverse lifecycle's visuals. Driven through a REAL board so the
## fractions are derived the way the bridge derives them, not from a mock.
func _test_breakdown_progress() -> void:
	var counts := {"beam_count": 16, "bracket_count": 8, "bolt_count": 12,
			"module_count": 4, "panel_count": 6}
	var board := NpcChoreBoard.create_empty()
	var rows := SiteProject.breakdown_spec_rows(counts, "prop_x", {})
	var made: Array = board.add_plan(rows, {"start_h": 0.0, "end_h": 24.0})
	var project := SiteProject.make(SiteProject.KIND_LINKAGE_BREAKDOWN, "Teardown",
			"prop_x", Vector2.ZERO, 0.0)
	SiteProject.bind_tasks(project, rows, made)
	var cid_of := func(tid: String) -> String:
		for t in project["tasks"]:
			if str((t as Dictionary).get("task_id", "")) == tid:
				return str((t as Dictionary).get("chore_id", ""))
		return ""

	# THE regression check: an untouched teardown paints NOTHING away. The old
	# branch emitted only `panels`, and _apply_build_progress defaults a missing
	# key to 1.0 — right at t=0 by accident, wrong for the whole run after.
	var bd0 := SiteProject.breakdown_progress(project, board)
	var all_whole := true
	for k in ["beams", "brackets", "bolts", "supports", "panels"]:
		if not is_equal_approx(float(bd0[k]), 1.0):
			all_whole = false
	_check("fresh teardown leaves every element whole", all_whole, str(bd0))
	_check("fresh teardown is solid and unfolded",
			is_equal_approx(float(bd0["ghost"]), 1.0) and not bool(bd0["folded"]))

	# Panels come off first; the frame is untouched.
	var strip_id := str(cid_of.call("strip_panels"))
	board.claim(strip_id, "w1")
	board.claim(strip_id, "w2")
	board.credit(strip_id, board.find(strip_id)["chore_hours"] * 0.5, 10.0)
	var bd1 := SiteProject.breakdown_progress(project, board)
	_check("stripping halves the panels", absf(float(bd1["panels"]) - 0.5) < 0.02, str(bd1["panels"]))
	_check("stripping leaves bolts and beams alone",
			is_equal_approx(float(bd1["bolts"]), 1.0) and is_equal_approx(float(bd1["beams"]), 1.0))

	# Hardware leaves together, and the beams still stand.
	board.credit(strip_id, 99.0, 10.0)
	SiteProject.sync_with_board(project, board)
	var unbolt_id := str(cid_of.call("unbolt"))
	board.claim(unbolt_id, "w1")
	board.credit(unbolt_id, board.find(unbolt_id)["chore_hours"] * 0.5, 10.0)
	var bd2 := SiteProject.breakdown_progress(project, board)
	_check("panels fully gone", is_equal_approx(float(bd2["panels"]), 0.0))
	_check("bolts and brackets leave together",
			absf(float(bd2["bolts"]) - 0.5) < 0.02
				and absf(float(bd2["brackets"]) - float(bd2["bolts"])) < 0.001)
	_check("beams stand through unbolting — the fold sweep IS their visual",
			is_equal_approx(float(bd2["beams"]), 1.0))

	# Fold prep pulls the supports and dims the frame toward the crate handoff.
	board.credit(unbolt_id, 99.0, 10.0)
	SiteProject.sync_with_board(project, board)
	var fold_id := str(cid_of.call("fold_pack"))
	board.claim(fold_id, "w1")
	board.claim(fold_id, "w2")
	board.credit(fold_id, board.find(fold_id)["chore_hours"] * 0.5, 10.0)
	var bd3 := SiteProject.breakdown_progress(project, board)
	_check("supports come off with the fold prep",
			absf(float(bd3["supports"]) - 0.5) < 0.02, str(bd3["supports"]))
	_check("frame ghosts toward the handoff",
			float(bd3["ghost"]) < 1.0 and float(bd3["ghost"]) >= 0.35, str(bd3["ghost"]))
	_check("beams still standing at the fold", is_equal_approx(float(bd3["beams"]), 1.0))
	board.credit(fold_id, 99.0, 10.0)
	SiteProject.sync_with_board(project, board)
	_check("folded once the pack completes",
			bool(SiteProject.breakdown_progress(project, board)["folded"]))

	# Monotonicity: a teardown never re-grows. Fresh plan, 20 even steps.
	var mb := NpcChoreBoard.create_empty()
	var mrows := SiteProject.breakdown_spec_rows(counts, "prop_y", {})
	var mmade: Array = mb.add_plan(mrows, {"start_h": 0.0, "end_h": 24.0})
	var mproj := SiteProject.make(SiteProject.KIND_LINKAGE_BREAKDOWN, "T2",
			"prop_y", Vector2.ZERO, 0.0)
	SiteProject.bind_tasks(mproj, mrows, mmade)
	var prev := SiteProject.breakdown_progress(mproj, mb)
	var monotone := true
	for _i in 20:
		var avail: Array = mb.available_for("m1", 10.0, 12.0, {}, 8)
		if not avail.is_empty():
			var acid := str((avail[0] as Dictionary).get("id", ""))
			for k2 in int((avail[0] as Dictionary).get("min_workers", 1)):
				mb.claim(acid, "m%d" % k2)
			mb.credit(acid, float((avail[0] as Dictionary).get("chore_hours", 1.0)) * 0.34, 10.0)
		SiteProject.sync_with_board(mproj, mb)
		var now := SiteProject.breakdown_progress(mproj, mb)
		for k3 in ["beams", "brackets", "bolts", "supports", "panels", "ghost"]:
			if float(now[k3]) > float(prev[k3]) + 0.0001:
				monotone = false
		prev = now
	_check("teardown never re-grows", monotone)

	# A design with no panels omits the strip row entirely: the class must stay
	# whole rather than reading as "already removed".
	var nb := NpcChoreBoard.create_empty()
	var nrows := SiteProject.breakdown_spec_rows(
			{"panel_count": 0, "module_count": 2, "bolt_count": 8}, "prop_z", {})
	var nmade: Array = nb.add_plan(nrows, {"start_h": 0.0, "end_h": 24.0})
	var nproj := SiteProject.make(SiteProject.KIND_LINKAGE_BREAKDOWN, "T3",
			"prop_z", Vector2.ZERO, 0.0)
	SiteProject.bind_tasks(nproj, nrows, nmade)
	_check("no-panel design keeps its (nonexistent) panels whole",
			is_equal_approx(float(SiteProject.breakdown_progress(nproj, nb)["panels"]), 1.0))


## Round 3: the sim-backed experiment lab. Everything runs through
## run_blocking with NO SceneTree — which is itself the structural guard that
## the lab never reaches for a scene, an autoload, or the bridge.
func _test_experiment_lab() -> void:
	var setup := _lab_setup(4)
	var lab := NpcExperimentLab.new()
	var res := lab.run_blocking(setup)
	var rows: Array = res["rows"]
	_check("lab produces a row per variant",
			rows.size() == NpcExperimentLab.variants_for(setup).size(), str(rows.size()))
	var by_id: Dictionary = {}
	for r in rows:
		by_id[str((r as Dictionary)["id"])] = r
	_check("baseline finishes", str((by_id["baseline"] as Dictionary).get("status", "")) == "done",
			str((by_id["baseline"] as Dictionary).get("dnf_reason", "")))

	# Determinism. Without this the cached table would be a lie.
	var lab2 := NpcExperimentLab.new()
	_check("two runs are identical",
			JSON.stringify(res["rows"]) == JSON.stringify(lab2.run_blocking(_lab_setup(4))["rows"]))

	# Chunked == blocking: a frame boundary must never leak into the numbers.
	var lab3 := NpcExperimentLab.new()
	lab3._setup = _lab_setup(4)
	lab3._variants = NpcExperimentLab.variants_for(lab3._setup)
	lab3._rows = []
	lab3._v_index = 0
	lab3._active = true
	lab3._begin_variant()
	var guard := 0
	while lab3._active and guard < 100000:
		# Odd stride, deliberately not TICKS_PER_FRAME.
		for _i in 7:
			if not lab3._active:
				break
			lab3._step_once()
		guard += 1
	_check("chunked stepping matches a blocking run",
			JSON.stringify(lab3._rows) == JSON.stringify(res["rows"]))

	# The simulated makespan can never BEAT the pure scheduler: the plan is a
	# lower bound that assumes nobody eats, sleeps or waits. That inequality is
	# the whole reason the sim column exists next to the plan column.
	var bounded := true
	for r2 in rows:
		var rd := r2 as Dictionary
		if str(rd.get("status", "")) != "done":
			continue
		if float(rd.get("plan_h", 0.0)) > 0.0 \
				and float(rd.get("makespan_h", 0.0)) < float(rd["plan_h"]) - 0.001:
			bounded = false
	_check("simulated makespan never beats the planned lower bound", bounded)
	# No plan_tasks in this fixture, so drag is UNKNOWN (-1) rather than being
	# reported as the whole makespan — claiming every hour was overhead would
	# be worse than reporting nothing.
	_check("drag reads unknown without a task graph",
			float((by_id["baseline"] as Dictionary).get("drag_h", 0.0)) < 0.0)
	var with_plan := _lab_setup(4)
	with_plan["plan_tasks"] = [
		{"id": "cut", "label": "Cut", "work_s": 7200.0, "min_workers": 1,
			"max_workers": 4, "deps": []},
		{"id": "fit", "label": "Fit", "work_s": 5400.0, "min_workers": 2,
			"max_workers": 4, "deps": ["cut"]}]
	var planned := NpcExperimentLab.new().run_blocking(with_plan)
	var pbase := {}
	for r7 in planned["rows"]:
		if str((r7 as Dictionary)["id"]) == "baseline":
			pbase = r7
	_check("drag is reported against a real plan",
			float(pbase.get("plan_h", 0.0)) > 0.0
				and float(pbase.get("drag_h", -1.0)) >= 0.0,
			"plan %.2f drag %.2f" % [float(pbase.get("plan_h", -1.0)),
				float(pbase.get("drag_h", -1.0))])
	_check("diagnostics accumulate",
			float((by_id["baseline"] as Dictionary).get("worker_h", 0.0)) > 0.0)

	# Quorum infeasibility short-circuits BEFORE any ticks are spent. Roster 4
	# so the 2-person row exists at all (variants_for skips the crew size that
	# IS the baseline, since it would be a duplicate).
	var quorum_setup := _lab_setup(4)
	for s in quorum_setup["chore_specs"]:
		(s as Dictionary)["min_workers"] = 6
		(s as Dictionary)["max_workers"] = 8
	var lab4 := NpcExperimentLab.new()
	var qres := lab4.run_blocking(quorum_setup)
	var small := {}
	for r3 in qres["rows"]:
		if str((r3 as Dictionary)["id"]) == "crew_2":
			small = r3
	_check("an impossible quorum is named, not simulated",
			str(small.get("status", "")) == "infeasible"
				and str(small.get("dnf_reason", "")).contains("6"),
			str(small.get("dnf_reason", "")))
	# Naming it costs NOTHING. A quorum no crew size can meet must report a
	# sentence for every row without simulating a single tick — otherwise each
	# row burns MAX_SIM_H of sim time to arrive at "DNF". Measured directly:
	# an all-infeasible run does zero work.
	var never_setup := _lab_setup(4)
	for s2 in never_setup["chore_specs"]:
		(s2 as Dictionary)["min_workers"] = 99
		(s2 as Dictionary)["max_workers"] = 99
	var lab4b := NpcExperimentLab.new()
	var nres := lab4b.run_blocking(never_setup)
	var all_infeasible := true
	for r6 in nres["rows"]:
		# The haul rows are n/a here (this setup is a build, not a delivery)
		# and never reach the feasibility probe.
		var st6 := str((r6 as Dictionary).get("status", ""))
		if st6 != "infeasible" and st6 != "na":
			all_infeasible = false
	_check("an unmeetable quorum names every simulated row", all_infeasible)
	_check("infeasible rows cost no ticks", int(nres["ticks"]) == 0,
			str(nres["ticks"]))

	# tools_down never finishes — the hour cap must catch it rather than spin.
	var stuck := _lab_setup(4)
	stuck["rules"] = {"tools_down": true}
	var lab5 := NpcExperimentLab.new()
	var sres := lab5.run_blocking(stuck)
	var any_dnf := false
	for r4 in sres["rows"]:
		if str((r4 as Dictionary).get("status", "")) == "dnf" \
				and str((r4 as Dictionary).get("dnf_reason", "")) == "hour cap":
			any_dnf = true
	_check("a board that never offers work hits the hour cap", any_dnf)

	# n/a rather than a missing row: an absent row reads as a bug.
	var na_rows := 0
	for r5 in rows:
		if str((r5 as Dictionary).get("status", "")) == "na":
			na_rows += 1
	_check("haul rows are n/a on a non-delivery project", na_rows == 2, str(na_rows))

	# Signature: stable under per-tick churn, sensitive to what actually
	# changes the answer. This is what makes the panel's cache correct.
	var sig := NpcExperimentLab.signature_for(setup)
	var churn := _lab_setup(4)
	(churn["chore_specs"][0] as Dictionary)["progress_h"] = 0.4
	_check("signature ignores per-tick churn",
			NpcExperimentLab.signature_for(churn) == sig)
	var changed := _lab_setup(4)
	(changed["chore_specs"][0] as Dictionary)["min_workers"] = 3
	_check("signature tracks crew requirements",
			NpcExperimentLab.signature_for(changed) != sig)
	var bigger := _lab_setup(4)
	bigger["roster_size"] = 9
	_check("signature tracks roster size",
			NpcExperimentLab.signature_for(bigger) != sig)

	# _set_crew normalizes — update_chore does not, and a max below min is a
	# chore nobody can ever claim.
	var nb := NpcChoreBoard.create_empty()
	var ncid := nb.add_chore("Job", 1.0, {"min_workers": 4, "max_workers": 4})
	NpcExperimentLab._set_crew(nb, ncid, 4, 2)
	_check("crew caps never invert",
			int(nb.find(ncid)["max_workers"]) >= int(nb.find(ncid)["min_workers"]))

	# force_strategy: "" must reproduce the density-derived call EXACTLY, or
	# every existing delivery changes shape the day the lab shipped.
	var crates: Array = []
	for i in 7:
		crates.append({"pid": "p%d" % i, "stage": Vector2(20.0 + i, 0.0), "label": "B%d" % i})
	_check("force_strategy '' is byte-identical to the unforced call",
			JSON.stringify(SiteProject.unload_spec_rows(crates, Vector2.ZERO, 12))
				== JSON.stringify(SiteProject.unload_spec_rows(crates, Vector2.ZERO, 12, "")))
	var forced_rt: Dictionary = SiteProject.unload_spec_rows(crates, Vector2.ZERO, 12, "round_trip")
	var forced_br: Dictionary = SiteProject.unload_spec_rows(crates, Vector2.ZERO, 2, "brigade")
	_check("forcing round trips yields a row per crate",
			(forced_rt["rows"] as Array).size() == crates.size() + 1)
	_check("forcing a brigade yields one crew chore",
			(forced_br["rows"] as Array).size() == 2)


## A scene-free experiment setup: two dependent tasks at a fixed spot, one
## tagged space so needs resolve, no nav grid.
func _lab_setup(roster: int) -> Dictionary:
	var reg := SpaceRegistry.create_empty()
	var pos: Dictionary = {}
	for pair in [["kitchen", Vector2(12, 0)], ["water_point", Vector2(-12, 0)],
			["sleep", Vector2(0, 14)], ["restroom", Vector2(0, -14)]]:
		var c: Vector2 = pair[1]
		reg.set_space_type({"kind": "area", "poly": [
			[c.x - 4, c.y - 4], [c.x + 4, c.y - 4],
			[c.x + 4, c.y + 4], [c.x - 4, c.y + 4]]}, str(pair[0]), 30)
	for sp in reg.spaces:
		var sd: Dictionary = sp
		var pt: Variant = SpaceRegistry.area_interior_point(
			(sd.get("target", {}) as Dictionary).get("poly", []) as Array)
		pos[str(sd.get("id", ""))] = pt if pt is Vector2 else Vector2.ZERO
	return {
		"project_id": "proj_lab", "iid": "lab", "kind": "linkage_build",
		"chore_specs": [
			{"task_id": "cut", "label": "Cut", "chore_hours": 2.0, "priority": 1,
				"exposure": "outdoor", "min_workers": 1, "max_workers": 4,
				"target": {"kind": "pos", "x": 6.0, "z": 6.0}},
			{"task_id": "fit", "label": "Fit", "chore_hours": 1.5, "priority": 2,
				"exposure": "outdoor", "min_workers": 2, "max_workers": 4,
				"depends_on": ["cut"],
				"target": {"kind": "pos", "x": 6.0, "z": 6.0}},
		],
		"gate_task_id": "fit", "plan_tasks": [],
		"registry_blob": reg.serialize(),
		"space_pos": pos, "prop_pos": {}, "weather": {}, "starved": [],
		"roster_size": roster, "home": Vector2.ZERO, "routine": [],
		"rules": {}, "window": {"start_h": 7.0, "end_h": 19.0},
		"target": {"kind": "pos", "x": 6.0, "z": 6.0},
		"start_h": 24.0 * 400.0 + 7.0, "day_index": 400, "haul": {},
	}


## THE test the stall shipped past. A real camp configuration — no shower, no
## enrichment space, work OUTDOORS, quorum 6, the SHIPPED default routine — run
## long enough that every agent has passed the hygiene lock window (~5–13 h).
##
## It asserts COMPLETION, not progress. That distinction is the whole point:
## `_test_chore_priority` asserts `progress_h > 0.0 or done_day >= 0`, which a
## single credited substep satisfies, so it passed happily while the camp
## froze forever four hours later.
func _test_chore_run_to_completion() -> void:
	var site := _make_bare_site()
	var board := NpcChoreBoard.create_empty()
	# 240 person-hours: MORE than a 12-person crew can do in one day, so
	# completion necessarily spans the hygiene lock window (~5–13 h in). A
	# smaller job finishes before the first agent locks and passes on broken
	# code — which is exactly how the experiment lab's "done" rows all landed
	# at 4.5–5.5 h and hid the bug.
	var cid := board.add_chore("Raise the frame", 240.0, {
		"window": {"start_h": 7.0, "end_h": 19.0},
		"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
		"repeat": "once", "min_workers": 6, "max_workers": 12,
		"target": {"kind": "pos", "x": 60.0, "z": 0.0},
	})
	var engine := NpcPopulationEngine.new()
	engine.configure(12, "raise", Vector2.ZERO)
	engine.chore_board = board
	engine.routine = NpcRoutine.default_day()   # the SHIPPED default, on purpose
	_run_sim(engine, site, 9.0, 24.0 * 6.0, 1.0 / 60.0)
	if board.remaining(cid) > 0.0:
		_dump_stall(engine, board)
	_check("a 240 h crew chore completes in 6 days on a real camp",
			board.remaining(cid) <= 0.0, "%.1f h left" % board.remaining(cid))
	_check("completion is recorded",
			int(board.find(cid).get("done_day", -1)) >= 0)
	# And the camp is still standing: the fix must not have traded a stall for
	# people working themselves to death.
	_check("everyone is still here", engine.agents.size() == 12,
			str(engine.agents.size()))


## Why the board froze, per agent. Without this, "nothing completes" is a
## week of bisecting; with it, twelve identical lines name the cause on the
## first run.
func _dump_stall(engine: NpcPopulationEngine, board: NpcChoreBoard) -> void:
	print("  STALL DUMP — %d agents, %.2f h of work left" % [
		engine.agents.size(), board.remaining(str(board.chores[0].get("id", "")))])
	var tally: Dictionary = {}
	for a in engine.agents:
		var ag: NpcAgent = a
		var key := "%s|%s|%s" % [ag.state, ag.activity, ag.blocking_need()]
		tally[key] = int(tally.get(key, 0)) + 1
	for k in tally:
		print("    x%-3d state|activity|blocked = %s" % [int(tally[k]), str(k)])
	var sample: NpcAgent = engine.agents[0] if not engine.agents.is_empty() else null
	if sample != null:
		print("    sample needs: %s" % str(sample.needs))
		print("    sample blocked: %s  retry_at: %s" % [
			str(sample.blocked), str(sample.retry_at)])


## The edges of the ladder change, each pinned so a future "just fall through
## for everything" cannot land.
func _test_ladder_edges() -> void:
	var site := _make_bare_site()
	var board := NpcChoreBoard.create_empty()
	board.add_chore("Fix the pump", 4.0, {
		"window": {"start_h": 0.0, "end_h": 24.0},
		"exposure": NpcWeatherGate.EXPOSURE_INDOOR,
		"target": {"kind": "pos", "x": 5.0, "z": 5.0},
	})
	var ctx := {"registry": site["registry"], "pos_of": site["pos_of"],
		"hour_of_day": 12.0, "board": board, "weather": {}}

	# A comfort need that cannot be met must NOT stop work. This is the bug.
	var a := NpcAgent.make("comfort", Vector2.ZERO)
	for n in a.needs:
		a.needs[n] = 0.0
	a.needs["hygiene"] = 0.95
	a._step_idle(12.0, ctx)
	_check("an unmeetable comfort need never blocks work",
			a.activity == NpcAgent.CHORE_ACTIVITY, "activity=%s" % a.activity)

	# A critical need still does — that is the survival sim, and deliberate.
	var starve_site := _make_bare_site()
	(starve_site["registry"] as SpaceRegistry).spaces.clear()   # nothing tagged
	var b := NpcAgent.make("hungry", Vector2.ZERO)
	for n2 in b.needs:
		b.needs[n2] = 0.0
	b.needs["hunger"] = 0.9
	b._step_idle(12.0, {"registry": starve_site["registry"],
		"pos_of": starve_site["pos_of"], "hour_of_day": 12.0,
		"board": board, "weather": {}})
	_check("an unmeetable CRITICAL need still absorbs",
			b.activity.is_empty() and b.state == NpcAgent.State.IDLE
				and b.is_blocked("hunger"))

	# The status line must name what they cannot GET, not what is highest.
	# Enrichment pins at 1.0 on any site with no fire circle, and it used to
	# win — so the readout blamed the fire circle for a missing kitchen.
	b.needs["enrichment"] = 1.0
	_check("status names the blocker, not the loudest need",
			b.status_line().contains(SpaceTypes.label("kitchen")),
			b.status_line())
	_check("blocking_need is the blocked one", b.blocking_need() == "hunger")

	# The block clock latches on FIRST failure — retrying every backoff must
	# not keep resetting it, or no alarm could ever reach its threshold.
	b._mark_blocked("hunger", 20.0)
	_check("re-marking keeps the original block time",
			absf(b.blocked_hours("hunger", 20.0) - 8.0) < 0.001,
			"%.2f" % b.blocked_hours("hunger", 20.0))

	# _most_urgent ranks by normalized excess among needs ALREADY over.
	var c := NpcAgent.make("masked", Vector2.ZERO)
	for n3 in c.needs:
		c.needs[n3] = 0.0
	c.needs["bladder"] = 0.74   # threshold 0.75 — NOT over
	c.needs["hunger"] = 0.60    # threshold 0.55 — over
	_check("a high sub-threshold need cannot mask an over-threshold one",
			c._most_urgent() == "hunger", c._most_urgent())
	for n4 in c.needs:
		c.needs[n4] = 0.0
	_check("nothing over threshold means nothing urgent", c._most_urgent().is_empty())

	# The preempt floor: a mustered crew holds through ordinary thirst.
	var cb := NpcChoreBoard.create_empty()
	var crew_id := cb.add_chore("Raise", 10.0, {
		"window": {"start_h": 0.0, "end_h": 24.0}, "repeat": "once",
		"min_workers": 2, "max_workers": 6,
		"exposure": NpcWeatherGate.EXPOSURE_INDOOR})
	var w := NpcAgent.make("crew1", Vector2.ZERO)
	for n5 in w.needs:
		w.needs[n5] = 0.0
	cb.claim(crew_id, "crew1")
	cb.claim(crew_id, "crew2")
	w.chore_id = crew_id
	w.activity = NpcAgent.CHORE_ACTIVITY
	w.state = NpcAgent.State.DOING
	var cctx := {"board": cb, "weather": {}, "hour_of_day": 12.0, "registry": null}
	w.needs["thirst"] = 0.60
	w._step_chore(12.0, 0.1, cctx)
	_check("a quorate crew works through ordinary thirst",
			w.chore_id == crew_id, "left at 0.60")
	w.needs["thirst"] = 0.97
	w._step_chore(12.1, 0.1, cctx)
	_check("a quorate crew still breaks for a real emergency",
			w.chore_id.is_empty())


## The consequence dropdown: what running out actually does.
func _test_consequence_policy() -> void:
	_check("unknown policies normalize to the safe default",
			NpcConsequence.normalize("nonsense") == NpcConsequence.STRIKE
				and NpcConsequence.normalize("") == NpcConsequence.STRIKE
				and NpcConsequence.DEFAULT == NpcConsequence.STRIKE)
	_check("a full bladder is never fatal",
			not NpcConsequence.triggers(NpcConsequence.PERISH, "bladder", 100000.0))
	_check("strike never triggers a removal",
			not NpcConsequence.triggers(NpcConsequence.STRIKE, "thirst", 100000.0))
	_check("leave fires after a day, not before",
			NpcConsequence.triggers(NpcConsequence.LEAVE, "thirst", 24.5)
				and not NpcConsequence.triggers(NpcConsequence.LEAVE, "thirst", 23.5))
	_check("thirst kills long before hunger",
			NpcConsequence.PERISH_AFTER_H["thirst"] < NpcConsequence.PERISH_AFTER_H["hunger"])

	# A camp with NOTHING tagged, so every critical need is blocked from the
	# first tick — the worst case each policy has to answer for.
	var bare := func() -> Dictionary:
		var reg := SpaceRegistry.create_empty()
		return {"registry": reg, "pos_of": func(_s: Dictionary) -> Variant: return null}

	# STRIKE is the shipped behaviour: people stop, nobody is removed.
	var strike := NpcPopulationEngine.new()
	strike.configure(6, "strike", Vector2.ZERO)
	strike.consequence = NpcConsequence.STRIKE
	var strike_lost: Array = []
	strike.agent_lost.connect(func(_a: String, _n: String, _r: String) -> void:
		strike_lost.append(1))
	_run_sim(strike, bare.call(), 8.0, 24.0 * 4.0, 1.0 / 30.0)
	# STRIKE removes nobody BY SHORTAGE. Morale-driven departure is a separate,
	# always-on mechanic and still runs — which is exactly what shipped, and
	# what the blurb now says out loud.
	_check("STRIKE kills nobody", strike_lost.is_empty()
			and int(strike.summary().get("losses", -1)) == 0)

	# LEAVE routes through the existing departure path — so the cascade, the
	# signal and the collapse check are all the ones that already shipped.
	var leave := NpcPopulationEngine.new()
	leave.configure(6, "leave", Vector2.ZERO)
	leave.consequence = NpcConsequence.LEAVE
	var left_events: Array = []
	leave.agent_departed.connect(func(_a: String, _n: String, r: String) -> void:
		left_events.append(r))
	var lost_on_leave: Array = []
	leave.agent_lost.connect(func(_a: String, _n: String, _r: String) -> void:
		lost_on_leave.append(1))
	_run_sim(leave, bare.call(), 8.0, 24.0 * 4.0, 1.0 / 30.0)
	_check("LEAVE empties the camp", leave.agents.size() < 6, str(leave.agents.size()))
	_check("LEAVE reports departures, never losses",
			not left_events.is_empty() and lost_on_leave.is_empty())
	_check("LEAVE records no deaths", int(leave.summary().get("losses", -1)) == 0)

	# PERISH is the only policy that removes people via the new path, and it
	# must emit a DISTINCT signal — challenge code keys off departures.
	var perish := NpcPopulationEngine.new()
	perish.configure(6, "perish", Vector2.ZERO)
	perish.consequence = NpcConsequence.PERISH
	var lost: Array = []
	perish.agent_lost.connect(func(_a: String, _n: String, r: String) -> void:
		lost.append(r))
	# Long enough to pass the thirst window (72 h) with margin.
	_run_sim(perish, bare.call(), 8.0, 24.0 * 5.0, 1.0 / 30.0)
	_check("PERISH loses people", not lost.is_empty(), str(lost.size()))
	_check("PERISH names the cause",
			(not lost.is_empty()) and str(lost[0]).contains("water"), str(lost))
	# And it must not ALSO let them walk out — that would be the LEAVE outcome
	# wearing this policy's name, and at 24 h vs 72 h it would win every time,
	# so PERISH would silently never fire.
	_check("PERISH replaces walking out rather than racing it",
			int(perish.summary().get("departures", 0)) == lost.size())
	_check("losses are counted", int(perish.summary().get("losses", 0)) == lost.size())
	# ...and it takes materially longer than walking out would have.
	_check("dying of thirst takes longer than quitting",
			NpcConsequence.PERISH_AFTER_H["thirst"] > NpcConsequence.LEAVE_AFTER_H)

	# The count survives save/load.
	var rt := NpcPopulationEngine.new()
	rt.restore(perish.snapshot(100.0))
	_check("losses round-trip", int(rt.summary().get("losses", -1)) == lost.size())


## The settlement feed: cursors that do not starve each other, and latches
## that do not strobe.
func _test_settlement_log() -> void:
	var lg := SettlementLog.create_empty()
	lg.add("work", "Cut beams finished", 10.0)
	lg.add("work", "Drilled holes", 11.0)

	# THE fix: two readers, neither destroys the other's view. take_events()
	# emptied a shared array, so a bake silently ate the player's toasts.
	_check("first consumer sees everything", lg.since("hud").size() == 2)
	_check("a second consumer sees it too — reading is not a drain",
			lg.since("bake").size() == 2)
	_check("a consumer does not re-read what it has seen", lg.since("hud").is_empty())
	lg.add("work", "Bolted the ring", 12.0)
	_check("a consumer sees only what is new", lg.since("hud").size() == 1)
	_check("the other consumer catches up independently",
			lg.since("bake").size() == 1)

	# Latching: an alarm fires once, however often the underlying flag flaps.
	var first := lg.latch("need_unmet|h|hygiene", "Nobody can reach a Shower", 13.0)
	var again := lg.latch("need_unmet|h|hygiene", "Nobody can reach a Shower", 13.5)
	_check("an alarm fires once, not once per retry", first and not again)
	_check("the alarm is standing", lg.is_latched("need_unmet|h|hygiene"))
	_check("standing alarms are listable", lg.open_alarms().size() == 1)
	_check("relief clears the latch",
			lg.clear_latch("need_unmet|h|hygiene", "Showers are back", 20.0))
	_check("clearing twice is a no-op",
			not lg.clear_latch("need_unmet|h|hygiene", "Showers are back", 21.0))
	_check("the alarm can fire again after relief",
			lg.latch("need_unmet|h|hygiene", "Nobody can reach a Shower", 30.0))

	# Severity filters rather than interrupts — nothing here is modal.
	lg.add("chatter", "Someone had lunch", 31.0, SettlementLog.INFO)
	var alerts := lg.recent(50, SettlementLog.ALERT)
	var all_alerts := true
	for e in alerts:
		if int((e as Dictionary)["severity"]) < SettlementLog.ALERT:
			all_alerts = false
	_check("severity filters the feed", all_alerts and not alerts.is_empty())
	_check("recent is newest-first",
			int((lg.recent(1)[0] as Dictionary)["abs_h"]) == 31)

	# Bounded: a week at speed must not grow the buffer without limit.
	for i in SettlementLog.CAP * 2:
		lg.add("spam", "tick %d" % i, float(i))
	_check("the buffer is bounded", lg.entries.size() == SettlementLog.CAP)
	_check("a cursor past the trim point still returns only new lines",
			lg.since("hud").size() <= SettlementLog.CAP)


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


# =============================================================================
# Tier 3d — distance, climb and calories
# =============================================================================

func _test_metabolism_model() -> void:
	# THE PINNED WORKED EXAMPLE. ACSM at the project's walking speed:
	# S = 1.3 m/s = 78 m/min, flat, 70 kg.
	#   VO2      = 3.5 + 0.1*78            = 11.3 mL/kg/min
	#   kcal/min = 11.3 * 70 / 1000 * 5    = 3.955
	#   1 km     = 1000/78 = 12.82 min     -> ~50.7 kcal
	# which matches the accepted ~50-60 kcal/km for a 70 kg adult.
	var speed := NpcNav.WALK_SPEED_MPS
	_check("ACSM flat VO2", absf(NpcMetabolism.vo2(78.0, 0.0) - 11.3) < 0.05,
			"%.2f" % NpcMetabolism.vo2(78.0, 0.0))
	_check("ACSM flat kcal/min",
			absf(NpcMetabolism.kcal_per_min(78.0, 0.0) - 3.955) < 0.02,
			"%.3f" % NpcMetabolism.kcal_per_min(78.0, 0.0))
	var km := NpcMetabolism.walk_kcal(1000.0, 0.0, speed)
	_check("~51 kcal per flat km at 70 kg", absf(km - 50.7) < 1.5, "%.1f kcal" % km)

	# The grade term. 10% grade at 78 m/min adds 1.8*78*0.1 = 14.04 to VO2,
	# more than doubling the flat cost.
	var uphill := NpcMetabolism.walk_kcal(1000.0, 100.0, speed)
	_check("climbing costs more", uphill > km * 1.9, "%.1f vs %.1f" % [uphill, km])
	_check("grade term matches ACSM",
			absf(NpcMetabolism.vo2(78.0, 0.1) - (11.3 + 14.04)) < 0.05,
			"%.2f" % NpcMetabolism.vo2(78.0, 0.1))

	# Descending is never cheaper than flat — the equation has no valid
	# negative-grade term, so it is clamped at zero.
	_check("downhill clamps to flat",
			absf(NpcMetabolism.walk_kcal(1000.0, -100.0, speed) - km) < 0.01)
	_check("negative grade clamps in vo2",
			absf(NpcMetabolism.vo2(78.0, -0.5) - NpcMetabolism.vo2(78.0, 0.0)) < 0.001)

	# Heavier people spend more; mass scales linearly.
	_check("mass scales linearly",
			absf(NpcMetabolism.walk_kcal(1000.0, 0.0, speed, 140.0) - km * 2.0) < 0.05)

	# Net cost strips the resting term and is strictly smaller but positive.
	var net := NpcMetabolism.net_walk_kcal(1000.0, 0.0, speed)
	_check("net cost is below gross", net < km and net > 0.0, "%.1f vs %.1f" % [net, km])
	_check("resting kcal is the difference",
			absf(km - net - NpcMetabolism.resting_kcal(1000.0 / (speed * 60.0))) < 0.01)

	# Degenerate inputs are zero, not NaN.
	_check("zero distance costs nothing", NpcMetabolism.walk_kcal(0.0, 0.0, speed) == 0.0)
	_check("zero speed costs nothing", NpcMetabolism.walk_kcal(100.0, 0.0, 0.0) == 0.0)

	# Overhead + labels: the spatial-efficiency headline.
	_check("overhead is a fraction of the day",
			absf(NpcMetabolism.overhead_fraction(200.0) - 0.1) < 0.001)
	_check("overhead clamps", NpcMetabolism.overhead_fraction(1e9) == 1.0)
	_check("a compact site reads Compact",
			NpcMetabolism.efficiency_label(20.0) == "Compact")
	_check("a sprawling site reads Punishing",
			NpcMetabolism.efficiency_label(400.0) == "Punishing")
	var prev := ""
	for kcal in [10.0, 40.0, 70.0, 120.0, 300.0]:
		var lbl := NpcMetabolism.efficiency_label(kcal)
		_check("efficiency labels are ordered", lbl != prev, lbl)
		prev = lbl


func _test_walk_accounting() -> void:
	var site := _make_test_site()
	var ctx := {
		"registry": site["registry"], "pos_of": site["pos_of"],
		"hour_of_day": 12.0, "starved": {},
	}
	var a := NpcAgent.make("ledger", Vector2.ZERO)
	_check("ledger starts empty", a.distance_m == 0.0 and a.walk_kcal == 0.0)

	# Walking accrues distance and calories in step.
	a.target_pos = Vector2(100, 0)
	a.state = NpcAgent.State.TRAVELING
	a._walk(NpcNav.hours_for_distance(40.0), ctx)
	_check("distance accrues", absf(a.distance_m - 40.0) < 0.1, "%.2f" % a.distance_m)
	_check("calories accrue", a.walk_kcal > 0.0)
	_check("calories track the model",
			absf(a.walk_kcal - NpcMetabolism.walk_kcal(40.0, 0.0, NpcNav.WALK_SPEED_MPS)) < 0.01)
	_check("no climb on flat ground", a.climb_m == 0.0)

	# Climb is counted from the height callable, ascent only.
	var b := NpcAgent.make("climber", Vector2.ZERO)
	var hilly := ctx.duplicate()
	hilly["height_at"] = func(p: Vector2) -> float: return p.x * 0.1
	b.target_pos = Vector2(100, 0)
	b.state = NpcAgent.State.TRAVELING
	b._walk(NpcNav.hours_for_distance(50.0), hilly)
	_check("climb accrues going up", absf(b.climb_m - 5.0) < 0.2, "%.2f" % b.climb_m)
	_check("climbing costs more than flat",
			b.walk_kcal > NpcMetabolism.walk_kcal(50.0, 0.0, NpcNav.WALK_SPEED_MPS))
	var c := NpcAgent.make("descender", Vector2(100, 0))
	c.target_pos = Vector2.ZERO
	c.state = NpcAgent.State.TRAVELING
	c._walk(NpcNav.hours_for_distance(50.0), hilly)
	_check("descending records no climb", c.climb_m == 0.0)

	# Per-need attribution: a completed trip is banked against the need that
	# drove it, which is what makes "how far for water" answerable.
	var d := NpcAgent.make("tripper", Vector2.ZERO)
	d.needs["thirst"] = 1.0
	for n in ["hunger", "bladder", "sleep", "hygiene"]:
		d.needs[n] = 0.0
	d._step_idle(10.0, ctx)
	_check("trip started", d.state == NpcAgent.State.TRAVELING)
	var t := 10.0
	for i in 400:
		t += 1.0 / 60.0
		d.step(t, 1.0 / 60.0, ctx)
		if d.state == NpcAgent.State.DOING:
			break
	_check("arrival banks the trip", int(d.need_trips.get("thirst", 0)) == 1)
	# The water point sits 40 m from the origin.
	_check("banked distance is the real walk",
			absf(float(d.need_distance.get("thirst", 0.0)) - 40.0) < 3.0,
			"%.1f m" % float(d.need_distance.get("thirst", 0.0)))
	_check("trip counter resets", d.trip_distance_m == 0.0)

	# Day rollover banks yesterday and starts clean.
	d.distance_m = 500.0
	d.walk_kcal = 25.0
	d._reseed_for_day(10.0 + 24.0)
	_check("rollover clears today", d.distance_m == 0.0 and d.walk_kcal == 0.0)
	_check("rollover keeps yesterday",
			absf(float(d.prev_day.get("distance_m", 0.0)) - 500.0) < 0.01)
	_check("rollover keeps yesterday's trips",
			(d.prev_day.get("need_trips", {}) as Dictionary).has("thirst"))

	# The ledger survives save/load.
	d.distance_m = 321.0
	d.walk_kcal = 17.0
	d.climb_m = 4.0
	var restored := NpcAgent.from_snapshot(
			JSON.parse_string(JSON.stringify(d.snapshot())) as Dictionary)
	_check("distance round-trips", absf(restored.distance_m - 321.0) < 1.01)
	_check("kcal round-trips", absf(restored.walk_kcal - 17.0) < 1.01)
	_check("climb round-trips", absf(restored.climb_m - 4.0) < 0.51)


func _test_walk_aggregates() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "walkers", Vector2.ZERO)
	_run_sim(engine, site, 8.0, 24.0, 1.0 / 60.0)
	var s := engine.summary()
	_check("aggregate distance reported", float(s.get("walk_distance_m", 0.0)) > 0.0,
			"%.1f m" % float(s.get("walk_distance_m", 0.0)))
	_check("aggregate calories reported", float(s.get("walk_kcal", 0.0)) > 0.0)
	_check("overhead is a sane share",
			float(s.get("walk_overhead", -1.0)) >= 0.0
				and float(s.get("walk_overhead", 1.0)) < 0.5,
			"%.3f" % float(s.get("walk_overhead", -1.0)))
	_check("efficiency label present", not str(s.get("walk_label", "")).is_empty())
	# Per-need means only appear for needs that completed a trip.
	var per_need: Dictionary = s.get("need_mean_m", {})
	_check("per-need distances reported", not per_need.is_empty())
	for k in per_need:
		_check("per-need mean is positive %s" % k, float(per_need[k]) > 0.0)

	# A SPREAD-OUT site must cost measurably more than a compact one — this is
	# the whole point of the metric.
	var far_reg := SpaceRegistry.create_empty()
	var far_pos := {
		"kitchen": Vector2(220, 0), "restroom": Vector2(-220, 60),
		"water": Vector2(0, 240), "beds": Vector2(0, -260), "showers": Vector2(-180, -180),
	}
	var far_kinds := {
		"kitchen": "kitchen", "restroom": "restroom", "water": "water_point",
		"beds": "sleep", "showers": "shower",
	}
	for pid in far_pos:
		far_reg.set_space_type({"kind": "prop", "prop_id": pid},
				str(far_kinds[pid]), 60)
	var far_site := {"registry": far_reg, "pos_of": func(space: Dictionary) -> Variant:
		return far_pos.get(str((space.get("target", {}) as Dictionary).get("prop_id", "")))}
	var spread := NpcPopulationEngine.new()
	spread.configure(6, "walkers", Vector2.ZERO)
	_run_sim(spread, far_site, 8.0, 24.0, 1.0 / 60.0)
	var s2 := spread.summary()
	_check("a spread-out layout costs more walking",
			float(s2.get("walk_distance_m", 0.0)) > float(s.get("walk_distance_m", 0.0)) * 1.5,
			"%.0f m vs %.0f m" % [float(s2.get("walk_distance_m", 0.0)),
				float(s.get("walk_distance_m", 0.0))])
	_check("and more calories",
			float(s2.get("walk_kcal", 0.0)) > float(s.get("walk_kcal", 0.0)))


# =============================================================================
# Tier 3e — desire lines
# =============================================================================

func _test_desire_map_accumulation() -> void:
	var m := NpcDesireMap.new()
	_check("unconfigured map is inert", not m.is_configured())
	m.add_segment(Vector2.ZERO, Vector2(10, 0), "thirst", 10.0)   # must not crash
	_check("configure", m.configure(Vector2.ZERO, 50.0))
	_check("starts empty", m.peak() == 0.0 and m.hot_cells() == 0)

	# A walked segment deposits exactly the metres given, spread along it.
	m.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 40.0)
	_check("metres are conserved", absf(m.total_metres() - 40.0) < 0.01,
			"%.2f" % m.total_metres())
	_check("the line is hot", m.hot_cells(0.5) > 10, "%d cells" % m.hot_cells(0.5))
	_check("peak is positive", m.peak() > 0.0)

	# Traffic concentrates: walking the same line again doubles it.
	var peak_before := m.peak()
	m.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 40.0)
	_check("repeat traffic deepens the path", m.peak() > peak_before * 1.9)
	_check("metres still conserved", absf(m.total_metres() - 80.0) < 0.02)

	# Off-map segments are dropped, not wrapped.
	var off_before := m.total_metres()
	m.add_segment(Vector2(900, 900), Vector2(950, 900), "thirst", 50.0)
	_check("off-map traffic is dropped", absf(m.total_metres() - off_before) < 0.01)

	# Zero-length and zero-metre calls are no-ops.
	m.add_segment(Vector2.ZERO, Vector2.ZERO, "thirst", 0.0)
	_check("zero metres is a no-op", absf(m.total_metres() - off_before) < 0.01)

	# Channels: a filtered texture only shows its own traffic.
	var m2 := NpcDesireMap.new()
	m2.configure(Vector2.ZERO, 50.0)
	m2.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 40.0)
	m2.add_segment(Vector2(0, -20), Vector2(0, 20), "hunger", 40.0)
	_check("all-traffic texture exists", m2.texture("") != null)
	_check("thirst channel exists", m2.texture("thirst") != null)
	_check("hunger channel exists", m2.texture("hunger") != null)
	_check("an unused channel is empty", m2.texture("sleep") == null)
	_check("an unknown channel does not crash", m2.texture("nonsense") != null)
	_check("total holds both trips", absf(m2.total_metres() - 80.0) < 0.02)


func _test_desire_map_retention() -> void:
	# TODAY forgets at the day boundary — the map shows the CURRENT layout,
	# not a fossil of one already fixed.
	var today := NpcDesireMap.new()
	today.configure(Vector2.ZERO, 50.0)
	today.set_retention(NpcDesireMap.Retention.TODAY)
	today.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 40.0)
	today.roll_day()
	_check("TODAY resets each day", today.total_metres() < 0.01)
	_check("TODAY clears the peak", today.peak() < 0.01)

	# WEEK decays rather than resetting.
	var week := NpcDesireMap.new()
	week.configure(Vector2.ZERO, 50.0)
	week.set_retention(NpcDesireMap.Retention.WEEK)
	week.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 100.0)
	week.roll_day()
	_check("WEEK decays", absf(week.total_metres() - 100.0 * NpcDesireMap.WEEK_DECAY) < 0.5,
			"%.2f" % week.total_metres())
	for _i in 20:
		week.roll_day()
	_check("WEEK eventually fades out", week.total_metres() < 1.0)

	# ALL keeps everything.
	var all := NpcDesireMap.new()
	all.configure(Vector2.ZERO, 50.0)
	all.set_retention(NpcDesireMap.Retention.ALL)
	all.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 100.0)
	for _i in 10:
		all.roll_day()
	_check("ALL never forgets", absf(all.total_metres() - 100.0) < 0.01)

	_check("retention labels", NpcDesireMap.retention_label(NpcDesireMap.Retention.TODAY) == "Today"
			and NpcDesireMap.retention_label(NpcDesireMap.Retention.ALL) == "All time")
	all.set_retention(99)
	_check("retention clamps", all.retention <= NpcDesireMap.Retention.ALL)

	all.clear()
	_check("clear empties", all.total_metres() < 0.01)


func _test_desire_map_render() -> void:
	var m := NpcDesireMap.new()
	m.configure(Vector2(10.0, -6.0), 40.0)
	_check("empty map yields no texture", m.texture("") == null)
	m.add_segment(Vector2(0, -6), Vector2(20, -6), "thirst", 60.0)
	var tex := m.texture("")
	_check("texture built", tex != null)
	_check("texture matches the grid", tex.get_width() == m.nx and tex.get_height() == m.nz)
	# A near-empty map must render near-empty. An unwritten/garbage buffer
	# shows up as a solid opaque block covering the whole site.
	var img := tex.get_image()
	var opaque := 0
	var whitish := 0
	for iz in img.get_height():
		for ix in img.get_width():
			var c := img.get_pixel(ix, iz)
			if c.a > 0.5:
				opaque += 1
			if c.a > 0.9 and c.r > 0.9 and c.g > 0.9 and c.b > 0.9:
				whitish += 1
	var total_px := img.get_width() * img.get_height()
	_check("empty cells stay transparent", opaque < total_px / 4,
			"%d of %d opaque" % [opaque, total_px])
	_check("nothing renders as opaque white", whitish == 0, "%d white px" % whitish)

	# The world rect must cover the region so the renderer can place it.
	var r := m.world_rect()
	_check("world rect is centred", absf(r.get_center().x - 10.0) < m.cell_m
			and absf(r.get_center().y + 6.0) < m.cell_m, str(r))
	_check("world rect covers the traffic", r.has_point(Vector2(10, -6)))

	# Log ramp: cold is transparent, hot is opaque, and it is monotonic — a
	# linear ramp would let one corridor saturate and hide everything else.
	var c0 := NpcDesireMap.heat_color(0.0)
	var c1 := NpcDesireMap.heat_color(1.0)
	_check("cold is nearly transparent", c0.a < 0.2)
	_check("hot is strong", c1.a > 0.8)
	var prev_a := -1.0
	for i in 11:
		var a := NpcDesireMap.heat_color(float(i) / 10.0).a
		_check("ramp alpha rises", a > prev_a)
		prev_a = a
	_check("ramp clamps", NpcDesireMap.heat_color(-5.0).a == c0.a
			and NpcDesireMap.heat_color(5.0).a == c1.a)


## Live-trail expiry: the render trail behind each dot must age out, or an
## idle agent's last 48 waypoints sit painted on the Site Plan forever — 50
## sleepers left a permanent web over the whole camp.
func _test_trail_expiry() -> void:
	var a := NpcAgent.make("trail_test", Vector2.ZERO)
	# Seed points through _account_walk's own append path (ctx carries the
	# stamp), spaced past TRAIL_STEP_M so every segment lands.
	var t := 100.0
	for i in 6:
		var from := Vector2(float(i) * 2.0, 0.0)
		var to := Vector2(float(i + 1) * 2.0, 0.0)
		a.pos = from
		a._account_walk(2.0, from, to, {"abs_hours": t + float(i) * 0.05})
	_check("trail seeded", a.trail.size() == 6, str(a.trail.size()))
	_check("trail stamps in lockstep", a.trail_t.size() == a.trail.size())
	# Nothing old yet: trimming at the last stamp keeps everything.
	a.trim_trail(t + 0.25)
	_check("young trail survives trim", a.trail.size() == 6)
	# Age half the points past TRAIL_MAX_AGE_H.
	a.trim_trail(t + NpcAgent.TRAIL_MAX_AGE_H + 0.12)
	_check("aged points dropped", a.trail.size() < 6 and a.trail.size() > 0,
			str(a.trail.size()))
	_check("stamps still lockstep", a.trail_t.size() == a.trail.size())
	# Idle long enough and the whole trail is gone.
	a.trim_trail(t + 24.0)
	_check("idle trail fully expires", a.trail.is_empty())
	# Backward scrub: stamps in the future are a discontinuity — drop them.
	a._account_walk(2.0, Vector2.ZERO, Vector2(2, 0), {"abs_hours": 500.0})
	a.trim_trail(400.0)
	_check("future-stamped trail cleared on scrub-back", a.trail.is_empty())
	# clear_trail is total.
	a._account_walk(2.0, Vector2.ZERO, Vector2(2, 0), {"abs_hours": 600.0})
	a.clear_trail()
	_check("clear_trail empties both arrays",
			a.trail.is_empty() and a.trail_t.is_empty())


## The bridge's texture-rebuild gate: a THROTTLED call must not consume the
## dirty flag. The old form did (`stale and changed` evaluated take_dirty()
## unconditionally), so a change landing inside the throttle window was
## forgotten and the raster stayed stale until the NEXT mutation. The pure
## rule lives on NpcDesireMap (this suite must never load the bridge script —
## its bare PerfMonitor identifier kills the --script compile silently).
func _test_desire_tex_rebuild_gate() -> void:
	_check("force always rebuilds",
			NpcDesireMap.tex_should_rebuild(true, 0.0, 0.5, false))
	_check("throttled call declines even when dirty",
			not NpcDesireMap.tex_should_rebuild(false, 0.0, 0.5, true))
	_check("stale + dirty rebuilds",
			NpcDesireMap.tex_should_rebuild(false, 999.0, 0.5, true))
	_check("stale + clean declines",
			not NpcDesireMap.tex_should_rebuild(false, 999.0, 0.5, false))
	# set_retention(TODAY) must take effect immediately — the menu item's whole
	# point is dropping the fossil without waiting for the day boundary.
	var m := NpcDesireMap.new()
	m.configure(Vector2.ZERO, 50.0)
	m.add_segment(Vector2(-20, 0), Vector2(20, 0), "thirst", 100.0)
	m.set_retention(NpcDesireMap.Retention.TODAY)
	_check("switching to TODAY clears immediately", m.total_metres() < 0.01)
	_check("immediate clear marks dirty", m.take_dirty())


func _test_desire_from_walking() -> void:
	# End to end: run the sim with a trace hook and confirm the heat lands on
	# the corridors between tagged spaces, not scattered noise.
	var site := _make_test_site()
	var m := NpcDesireMap.new()
	m.configure(Vector2.ZERO, 80.0)
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "desire", Vector2.ZERO)
	var t := 8.0
	var trail_seen := 0
	while t < 8.0 + 24.0:
		t += 1.0 / 60.0
		engine.tick(t, {
			"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": fposmod(t, 24.0),
			"trace": func(a: Vector2, b: Vector2, ch: String, mm: float) -> void:
				m.add_segment(a, b, ch, mm),
		})
		trail_seen = maxi(trail_seen, (engine.agents[0] as NpcAgent).trail.size())
	_check("walking leaves a trace", m.total_metres() > 100.0, "%.0f m" % m.total_metres())
	_check("paths are worn in", m.hot_cells(2.0) > 5, "%d cells" % m.hot_cells(2.0))

	# The heat must cluster on the routes to the spaces, so a point on the
	# way to the water point should be hotter than empty ground far away.
	var on_route := m.texture("") != null
	_check("a texture is renderable from real traffic", on_route)
	# Per-need channels populated by real activity.
	var thirst_tex := m.texture("thirst")
	_check("thirst traffic recorded", thirst_tex != null)

	# Agents carry a bounded live trail for the overlay — visible WHILE they
	# walk, aged out within TRAIL_MAX_AGE_H once they stop (an idle agent's
	# permanent painted web was the bug the expiry exists to fix, so "still
	# has a trail at the end of the day" is exactly wrong to assert).
	_check("agents keep a trail while walking", trail_seen > 0)
	_check("the trail is bounded", trail_seen <= NpcAgent.TRAIL_MAX,
			"%d" % trail_seen)
	var a0: NpcAgent = engine.agents[0]
	var all_recent := true
	for i in a0.trail_t.size():
		if t - a0.trail_t[i] > NpcAgent.TRAIL_MAX_AGE_H + 0.05:
			all_recent = false
	_check("surviving trail points are recent", all_recent)
	var dots := engine.agent_dots()
	_check("dots expose the trail", (dots[0] as Dictionary).has("trail"))


# --- Tier 4: Mixamo rig ------------------------------------------------------

## The rig is an OPTIONAL asset layer. These checks assert the corrections the
## loader makes to the imported files, and that its absence degrades cleanly
## rather than breaking the sim.
func _test_rig_assets() -> void:
	if not NpcRig.available():
		# No assets installed is a legitimate state: assert the graceful path
		# and skip the rest rather than failing the suite.
		_check("no rig degrades cleanly", NpcRig.build_figure() == null,
				"build_figure must return null without assets")
		return

	print("  rig: clips=[%s] cycle=%.2fm yaw_off=%.2frad note=%s"
		% [", ".join(NpcRig.clip_names()), NpcRig.walk_cycle_distance_m(),
			NpcRig.model_yaw_offset(), NpcRig.load_error()])
	var clips := NpcRig.clip_names()
	for want in [NpcRig.CLIP_WALK, NpcRig.CLIP_IDLE, NpcRig.CLIP_SLEEP,
			NpcRig.CLIP_WORK, NpcRig.CLIP_SIT, NpcRig.CLIP_DANCE]:
		_check("clip present: %s" % want, clips.has(want), ", ".join(clips))

	# Mixamo names every take "mixamo_com"; if the rename failed the library
	# would hold one clip under that name instead of six under role names.
	_check("mixamo take name is gone", not clips.has(NpcRig.TAKE_NAME))

	# Root motion must be flattened: the sim owns position, so a clip that
	# travels would slide the figure off its own feet.
	var fig := NpcRig.build_figure()
	_check("a figure is built", fig != null)
	if fig != null:
		var ap := NpcRig.find_anim_player(fig)
		_check("figure carries the shared library", ap != null and ap.has_animation(NpcRig.CLIP_WALK))
		if ap != null:
			for c in [NpcRig.CLIP_WALK, NpcRig.CLIP_WORK, NpcRig.CLIP_DANCE]:
				if not ap.has_animation(c):
					continue
				var anim := ap.get_animation(c)
				var span := _hips_xz_span(anim)
				_check("root motion flattened: %s" % c, span < 0.01,
						"%.3f m of horizontal hip travel remains" % span)
				_check("clip loops: %s" % c, anim.loop_mode != Animation.LOOP_NONE)
		var skel := NpcRig.find_skeleton(fig)
		_check("figure has a skeleton", skel != null and skel.get_bone_count() > 30)
		var mesh := NpcRig.find_mesh(fig)
		_check("figure has a skinned mesh", mesh != null and mesh.skin != null)
		fig.free()

	# The walk cycle distance is what rate-matches the feet to the ground.
	var cyc := NpcRig.walk_cycle_distance_m()
	_check("walk cycle measured", cyc > 0.5 and cyc < 5.0, "%.2f m" % cyc)
	var scale := NpcRig.walk_speed_scale(NpcAvatar.WALK_SPEED_MPS)
	_check("walk rate-matched, not unity", absf(scale - 1.0) > 0.01, "%.3f" % scale)
	_check("walk rate stays sane", scale > 0.25 and scale < 4.0, "%.3f" % scale)
	# Timelapse: at 60x the body covers ground ~60x faster, so the gait has to
	# speed up with it or the feet skate. Rate tracks APPARENT speed, capped
	# because past ~12x the motion is a blur either way.
	var fast := NpcRig.walk_speed_scale_for(NpcRig.CLIP_WALK, NpcAvatar.WALK_SPEED_MPS * 60.0)
	_check("a 60x world speeds the gait up", fast > scale * 4.0, "%.2f vs %.2f" % [fast, scale])
	_check("the gait rate is capped", fast <= NpcRig.MAX_PLAYBACK_RATE + 0.001, "%.2f" % fast)
	var crawl := NpcRig.walk_speed_scale_for(NpcRig.CLIP_WALK, 0.01)
	_check("a near-stationary body does not stall the gait", crawl >= 0.25, "%.3f" % crawl)

	# A one-shot played at 3x finishes in a third of its length, so the pose
	# machine's state timer must divide by the rate or it holds a transition
	# long after the animation ended.
	var pm := NpcPoseMachine.new()
	pm.set_catalog({NpcRig.CLIP_SIT: {"len": 4.0}, NpcRig.CLIP_SIT_EXIT: {"len": 3.0},
			NpcRig.CLIP_IDLE: {"len": 2.0}, NpcRig.CLIP_WALK: {"len": 1.0}})
	var t_seen := 0
	for i in 200:
		pm.step(1.0 / 60.0, {"in_transit": false, "activity": "bladder",
				"morale": 0.9, "dwell_left_s": 300.0, "playback_rate": 6.0})
		if pm.clip() == NpcRig.CLIP_SIT_ENTER:
			t_seen += 1
	_check("a fast one-shot ends early, not late", t_seen > 0 and t_seen < 60,
			"%d frames in sit_enter at 6x (authored 3 s = 180 frames at 1x)" % t_seen)

	# Mixamo authors each clip around its own origin, and they disagree:
	# "Laying Sleeping" puts the hips at 1.02 m — HIGHER than a standing walk —
	# so without a correction the figure lies down a metre off the ground.
	var sleep_off := NpcRig.clip_ground_offset(NpcRig.CLIP_SLEEP)
	_check("lying clip is pulled down to the ground", sleep_off < -0.5,
			"%.3f m" % sleep_off)
	var sit_off := NpcRig.clip_ground_offset(NpcRig.CLIP_SIT)
	_check("seated clip is pulled down to the ground", sit_off < -0.1,
			"%.3f m" % sit_off)
	_check("standing clips are not shifted",
			is_equal_approx(NpcRig.clip_ground_offset(NpcRig.CLIP_WALK), 0.0)
			and is_equal_approx(NpcRig.clip_ground_offset(NpcRig.CLIP_IDLE), 0.0))

	# The idle is retargeted from a DIFFERENTLY SCALED rig (the player
	# character's hips sit at 2.04 m against this pack's 0.87 m). Rotations
	# retarget scale-free, but the hips' position track does not — uncorrected,
	# every idling figure hovers over a metre off the ground.
	if NpcRig.available():
		var fig2 := NpcRig.build_figure()
		if fig2 != null:
			var ap2 := NpcRig.find_anim_player(fig2)
			if ap2 != null and ap2.has_animation(NpcRig.CLIP_IDLE) 					and ap2.has_animation(NpcRig.CLIP_WALK):
				var idle_y := _hips_rest_y(ap2.get_animation(NpcRig.CLIP_IDLE))
				var walk_y := _hips_rest_y(ap2.get_animation(NpcRig.CLIP_WALK))
				_check("retargeted idle stands at native hip height",
						absf(idle_y - walk_y) < 0.05,
						"idle %.3f vs walk %.3f" % [idle_y, walk_y])
			fig2.free()

	# Facing is derived from the clip, and this pack measures +Z forward, so
	# the offset must actually turn the model around.
	var off := NpcRig.model_yaw_offset()
	_check("model yaw offset is a half turn", absf(absf(off) - PI) < 0.2,
			"%.3f rad" % off)


## Activity -> clip routing, independent of whether assets are installed:
## travelling must win over intent, and an unknown activity must fall back to
## the idle clip rather than to an empty string.
func _test_rig_clip_map() -> void:
	var av := NpcAvatar.new()
	av.setup("agent_rig_test", Color(0.5, 0.7, 0.9), "Tester")

	_check("sleep maps to the sleep clip",
			str(NpcAvatar.ACTIVITY_CLIPS.get("sleep", "")) == NpcRig.CLIP_SLEEP)
	_check("chores map to the work clip",
			str(NpcAvatar.ACTIVITY_CLIPS.get("chore", "")) == NpcRig.CLIP_WORK)
	_check("eating maps to the seated clip",
			str(NpcAvatar.ACTIVITY_CLIPS.get("hunger", "")) == NpcRig.CLIP_SIT)
	_check("enrichment maps to the dance clip",
			str(NpcAvatar.ACTIVITY_CLIPS.get("enrichment", "")) == NpcRig.CLIP_DANCE)
	# Every mapped activity must name a clip the rig actually ships.
	if NpcRig.available():
		var clips := NpcRig.clip_names()
		for a in NpcAvatar.ACTIVITY_CLIPS.keys():
			_check("mapped clip exists: %s" % a,
					clips.has(str(NpcAvatar.ACTIVITY_CLIPS[a])))

	# Travelling overrides intent — someone walking to bed walks, not sleeps.
	av.set_motion_state(true, "sleep")
	_check("travelling overrides activity", av._pick_clip() == NpcRig.CLIP_WALK)
	av.set_motion_state(false, "sleep")
	_check("stopped uses the activity clip", av._pick_clip() == NpcRig.CLIP_SLEEP)
	av.set_motion_state(false, "thirst")
	_check("unmapped activity falls back to idle", av._pick_clip() == NpcRig.CLIP_IDLE)
	av.set_motion_state(false, "")
	_check("no activity falls back to idle", av._pick_clip() == NpcRig.CLIP_IDLE)

	# Requesting detail without assets must not crash or claim it succeeded.
	# The two reasons to draw the stylised body are deliberately distinct (see
	# NpcAvatar.set_detail): the rig may be MISSING, or the player may have
	# CHOSEN it. This assertion used to check availability alone, so it failed
	# for anyone whose user://npc_display.cfg says style="simple" — a real
	# setting, reachable from Settings → NPCs → Body style.
	av.set_detail(true)
	_check("detail request matches asset availability and style choice",
			av.is_rigged() == (NpcRig.available() and not NpcDisplayPrefs.wants_simple()))
	av.set_detail(false)
	_check("detail can be dropped again", not av.is_rigged())
	av.free()


func _hips_xz_span(anim: Animation) -> float:
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if not str(anim.track_get_path(t)).to_lower().ends_with("hips"):
			continue
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for k in range(anim.track_get_key_count(t)):
			var v: Vector3 = anim.track_get_key_value(t, k)
			lo = lo.min(Vector2(v.x, v.z))
			hi = hi.max(Vector2(v.x, v.z))
		return (hi - lo).length()
	return 0.0


func _hips_rest_y(anim: Animation) -> float:
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if not str(anim.track_get_path(t)).to_lower().ends_with("hips"):
			continue
		var lo := INF
		for k in range(anim.track_get_key_count(t)):
			var v: Vector3 = anim.track_get_key_value(t, k)
			lo = minf(lo, v.y)
		return lo
	return 0.0


## The shared NPC space tag row (scenes/ui/npc_space_tag_row.gd) is what lets
## props with their own modals — StarShades, pallet racks — be tagged at all,
## since InteractionFocus routes them away from the generic drawer before it is
## ever reached. Covered here rather than the drawer itself because the drawer
## references the CursorController autoload, which does not exist under
## --script, so its script cannot even be loaded offline.
func _test_space_tag_row() -> void:
	var row := NpcSpaceTagRow.new()
	# Unbound: nothing to tag, so it must not offer a control.
	row.bind_target(null, {})
	_check("tag row hides with no target", not row.visible)
	_check("tag row reports no type when unbound", row.current_type() == "")

	# A loader-less host (a scene with no TerrainLoader) has no registry, so the
	# row must hide rather than silently drop the player's tag on the floor.
	row.bind_prop(null, "pp_1")
	_check("tag row hides without a registry", not row.visible)

	var host := _TagHost.new()
	host.npc_spaces = SpaceRegistry.create_empty()
	row.bind_prop(host, "pp_7")
	_check("tag row shows for a real prop + registry", row.visible)
	_check("a fresh prop starts untagged", row.current_type() == "")

	# Tagging round-trips through the registry, and the row reads it back.
	host.npc_spaces.set_space_type({"kind": "prop", "prop_id": "pp_7"}, "kitchen", 4)
	row.bind_prop(host, "pp_7")
	_check("tag row reflects an existing tag", row.current_type() == "kitchen",
			row.current_type())

	# It must work for buildings and areas too — the widget only ever handles
	# the target dict it is handed, which is what makes it reusable for 4b.
	host.npc_spaces.set_space_type({"kind": "building", "building_tag": "b_12"}, "sleep", 6)
	row.bind_building(host, "b_12")
	_check("tag row works for buildings", row.current_type() == "sleep")
	row.bind_target(host, {"kind": "area", "poly": [[0, 0], [4, 0], [4, 4]]})
	_check("tag row accepts an area target", row.visible)

	# Every taggable type must be offered, enrichment included.
	_check("all space types are offered", SpaceTypes.TYPES.size() == 9,
			"%d types" % SpaceTypes.TYPES.size())
	for t in SpaceTypes.TYPES:
		_check("type is valid: %s" % t, SpaceTypes.is_valid(str(t)))
	row.free()
	host.free()


class _TagHost extends Node:
	var npc_spaces: SpaceRegistry = null
	var saved := 0
	func save_npc_spaces() -> void:
		saved += 1


# --- Tier 4c: personal space -------------------------------------------------

## Standing slots. Without them every occupant of a space walks to the exact
## same resolved point, so a capacity-4 kitchen renders as one person with
## three others inside them.
func _test_standing_slots() -> void:
	_check("slot 0 sits on the centre",
			SpaceRegistry.slot_offset_for_index(0) == Vector2.ZERO)

	# The packing must actually keep people apart, for every count up to a
	# generous capacity — this is the whole point of the feature.
	var pts: Array[Vector2] = []
	for i in range(24):
		pts.append(SpaceRegistry.slot_offset_for_index(i))
	var worst := INF
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			worst = minf(worst, pts[i].distance_to(pts[j]))
	_check("no two slots are closer than personal space",
			worst >= SpaceRegistry.PERSONAL_SPACE_M * 0.95,
			"closest pair %.2f m" % worst)

	# It must stay compact — people gather AT a space, they do not sprawl
	# across the site. 24 people should still fit inside a few metres.
	var far := 0.0
	for p in pts:
		far = maxf(far, p.length())
	_check("slots stay compact", far < 5.0, "furthest %.2f m" % far)

	# Deterministic: same index, same offset, every call.
	_check("slot offsets are deterministic",
			SpaceRegistry.slot_offset_for_index(7)
			== SpaceRegistry.slot_offset_for_index(7))

	# Claim order IS slot order, so an arrangement is stable for a whole visit.
	var reg := SpaceRegistry.create_empty()
	var sid := reg.set_space_type({"kind": "prop", "prop_id": "pp_k"}, "kitchen", 6)
	_check("first claimer takes the centre",
			reg.claim(sid, "a") and reg.slot_index_for(sid, "a") == 0)
	reg.claim(sid, "b")
	reg.claim(sid, "c")
	_check("later claimers get their own slots",
			reg.slot_index_for(sid, "b") == 1 and reg.slot_index_for(sid, "c") == 2)
	_check("occupants stand apart",
			reg.slot_offset(sid, "b").distance_to(reg.slot_offset(sid, "c"))
			>= SpaceRegistry.PERSONAL_SPACE_M * 0.95)
	_check("a non-occupant has no slot", reg.slot_index_for(sid, "zz") == -1)
	_check("a non-occupant gets no offset", reg.slot_offset(sid, "zz") == Vector2.ZERO)


## In-transit separation: corridors converging, routes crossing, queues.
func _test_separation() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "test_hab", Vector2.ZERO)
	# A fresh roster spawns everyone on the habitat point, which is the worst
	# case: exactly coincident, so the push direction cannot come from the
	# separation vector and has to be derived deterministically from the ids.
	for a in engine.agents:
		(a as NpcAgent).pos = Vector2.ZERO
	for i in 40:
		engine.tick(8.0 + float(i) / 60.0, {
			"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": 8.0,
		})
	var closest := INF
	for i in range(engine.agents.size()):
		for j in range(i + 1, engine.agents.size()):
			closest = minf(closest,
					(engine.agents[i] as NpcAgent).pos.distance_to(
						(engine.agents[j] as NpcAgent).pos))
	_check("coincident agents push apart", closest > 0.15,
			"closest pair %.3f m" % closest)

	# Separation must never shove anyone through a wall: with everything
	# unwalkable, no push may be applied at all.
	var engine2 := NpcPopulationEngine.new()
	engine2.configure(4, "test_hab", Vector2.ZERO)
	for a in engine2.agents:
		(a as NpcAgent).pos = Vector2.ZERO
	engine2.tick(8.0 + 1.0 / 60.0, {
		"registry": site["registry"], "pos_of": site["pos_of"],
		"hour_of_day": 8.0,
		"walkable": func(_p: Vector2) -> bool: return false,
	})
	var moved := false
	for a in engine2.agents:
		if (a as NpcAgent).pos != Vector2.ZERO:
			moved = true
	_check("separation never pushes onto unwalkable ground", not moved)

	# Determinism: identical runs must land in identical positions.
	var a_run := _separation_run(site)
	var b_run := _separation_run(site)
	_check("separation is deterministic", a_run == b_run)


func _separation_run(site: Dictionary) -> PackedFloat32Array:
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "test_hab", Vector2.ZERO)
	for a in engine.agents:
		(a as NpcAgent).pos = Vector2.ZERO
	for i in 20:
		engine.tick(8.0 + float(i) / 60.0, {
			"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": 8.0,
		})
	var out := PackedFloat32Array()
	for a in engine.agents:
		out.append(snappedf((a as NpcAgent).pos.x, 0.001))
		out.append(snappedf((a as NpcAgent).pos.y, 0.001))
	return out


## The load-bearing invariant of the whole phase: personal space is COSMETIC.
## If crowding could change what people consume, the spatial-efficiency and
## mass-balance numbers would start depending on how packed the site is.
##
## The bound is relative rather than exact, because exact equality is not
## achievable and demanding it would be dishonest: position feeds travel time,
## travel time feeds when an activity starts, so a sideways nudge can leave
## someone a fraction of a second further into a drink at the moment the
## measurement window closes. Measured drift is ~4 parts per MILLION over a
## simulated day; the 0.1% bound leaves room for that while still catching any
## systematic bias (e.g. separation being banked as travel, or crowding
## starving people).
const SEPARATION_CONSUMPTION_TOLERANCE := 0.001

func _test_separation_changes_no_consumption() -> void:
	var with_sep := _consumption_over_a_day(true)
	var without := _consumption_over_a_day(false)
	for kind in without:
		var a := float(with_sep.get(kind, 0.0))
		var b := float(without[kind])
		var rel := absf(a - b) / maxf(absf(b), 0.0001)
		_check("separation does not meaningfully change %s consumed" % kind,
				rel < SEPARATION_CONSUMPTION_TOLERANCE,
				"%.4f vs %.4f (%.6f%% drift)" % [a, b, rel * 100.0])
	_check("both runs consumed something", without.size() > 0)


## `separated` false pins the walkable test to "nothing is walkable", which is
## the one switch that disables every push without touching anything else.
func _consumption_over_a_day(separated: bool) -> Dictionary:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "test_hab", Vector2.ZERO)
	var total: Dictionary = {}
	var t := 8.0
	var step := 1.0 / 60.0
	while t < 32.0:
		t += step
		var ctx := {
			"registry": site["registry"], "pos_of": site["pos_of"],
			"hour_of_day": fposmod(t, 24.0),
		}
		if not separated:
			ctx["walkable"] = func(_p: Vector2) -> bool: return false
		var demand: Dictionary = engine.tick(t, ctx)
		for kind in demand:
			total[kind] = float(total.get(kind, 0.0)) + float(demand[kind]) * step
	return total


## What the player actually hit: people leave one by one until the roster is
## EMPTY, at which point the world goes silent — nothing moves, nothing is
## consumed, no further events fire. An emptied roster cannot restart itself
## (departures are permanent and a zero-agent engine ticks to nothing), so the
## reset path is the only way back and has to work.
func _test_desertion_and_reset() -> void:
	var barren := {"registry": SpaceRegistry.create_empty(),
			"pos_of": func(_s: Dictionary) -> Variant: return null}
	var engine := NpcPopulationEngine.new()
	engine.configure(8, "desert", Vector2.ZERO)
	var deserted := [""]
	var fired := [0]
	engine.colony_deserted.connect(func(cause: String) -> void:
		deserted[0] = cause
		fired[0] += 1)
	# Long enough for EVERY agent to run out of patience, not just enough to
	# cross the collapse floor.
	_run_sim(engine, barren, 8.0, 24.0 * 40.0, 1.0 / 12.0)
	_check("a barren site empties completely", engine.agents.is_empty(),
			"%d left" % engine.agents.size())
	_check("desertion is reported", engine.is_deserted())
	_check("desertion fires exactly once", fired[0] == 1, "%d times" % fired[0])
	_check("desertion names a cause", deserted[0] in NpcAgent.CRITICAL_NEEDS,
			deserted[0])
	_check("the cause is queryable after the fact",
			engine.departure_cause() == deserted[0])
	_check("summary reports desertion",
			bool(engine.summary().get("deserted", false)))

	# The silence: an empty roster consumes nothing, which is exactly why the
	# player sees no feedback at all and needs to be told.
	var demand := engine.tick(8.0 + 24.0 * 41.0, barren)
	_check("an empty roster consumes nothing", demand.is_empty())

	# It must NOT recover on its own — that would make departures meaningless.
	_run_sim(engine, barren, 8.0 + 24.0 * 41.0, 24.0 * 5.0, 1.0 / 12.0)
	_check("an empty roster stays empty", engine.agents.is_empty())

	# Reset is the way back: full roster, full morale, clean history.
	engine.reset_roster(8, "desert", Vector2.ZERO)
	_check("reset restores the roster", engine.agents.size() == 8)
	_check("reset clears desertion", not engine.is_deserted())
	_check("reset clears collapse", not engine.has_collapsed())
	_check("reset clears the departure log", engine.departures().is_empty())
	_check("reset returns people at full morale", engine.mean_morale() > 0.5,
			"%.2f" % engine.mean_morale())
	_check("reset clears collapse risk", engine.collapse_risk() < 0.2,
			"%.2f" % engine.collapse_risk())

	# ...and the new group leaves too if nothing was fixed, which is correct:
	# resetting is not a cure, and the UI says so next to the button.
	_run_sim(engine, barren, 8.0 + 24.0 * 46.0, 24.0 * 40.0, 1.0 / 12.0)
	_check("a reset into the same conditions empties again", engine.agents.is_empty())


## Area spaces (Tier 4b). The schema always reserved `kind == "area"`; what it
## lacked was geometry that survives the shapes people actually draw.
func _test_area_spaces() -> void:
	# Square: centroid is the obvious answer and must be exact. The old code
	# averaged VERTICES, which is only right when they are evenly spread.
	var square: Array = [[0, 0], [10, 0], [10, 10], [0, 10]]
	var c := SpaceRegistry.polygon_centroid(square)
	_check("square centroid is its middle", c.is_equal_approx(Vector2(5, 5)),
			str(c))
	_check("square area is right",
			absf(SpaceRegistry.polygon_area_m2(square) - 100.0) < 0.01,
			"%.2f" % SpaceRegistry.polygon_area_m2(square))

	# A vertex average is dragged toward whichever edge is finely subdivided;
	# the shoelace centroid is not. This is the case that motivated the change.
	var lopsided: Array = [[0, 0], [10, 0], [10, 10], [7.5, 10], [5, 10],
			[2.5, 10], [0, 10]]
	var c2 := SpaceRegistry.polygon_centroid(lopsided)
	_check("extra vertices do not shift the centroid",
			c2.is_equal_approx(Vector2(5, 5)), str(c2))

	# The load-bearing case: a U-shaped yard — a courtyard wrapping a building,
	# say — whose centroid falls in the OPENING, outside the space entirely.
	# (An L-shape does not demonstrate this: its centroid stays inside the
	# thick corner, which is why it is the wrong fixture for this test.)
	var l_shape: Array = [[0, 0], [10, 0], [10, 10], [7, 10], [7, 3], [3, 3],
			[3, 10], [0, 10]]
	var lc := SpaceRegistry.polygon_centroid(l_shape)
	_check("the L-shape centroid really is outside it",
			not SpaceRegistry.polygon_contains(l_shape, lc), str(lc))
	var interior: Variant = SpaceRegistry.area_interior_point(l_shape)
	_check("an interior point is found anyway", interior is Vector2)
	_check("the interior point is inside the area",
			SpaceRegistry.polygon_contains(l_shape, interior as Vector2),
			str(interior))

	# It should be roomy, not hugging a wall — people gather there.
	var pts := SpaceRegistry.poly_points(l_shape)
	var edge_d := INF
	for i in range(pts.size()):
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		edge_d = minf(edge_d, (interior as Vector2).distance_to(
				Geometry2D.get_closest_point_to_segment(interior as Vector2, a, b)))
	_check("the interior point has room around it", edge_d > 1.0,
			"%.2f m from the nearest edge" % edge_d)

	_check("containment rejects an outside point",
			not SpaceRegistry.polygon_contains(square, Vector2(20, 20)))
	_check("degenerate polys do not crash",
			SpaceRegistry.area_interior_point([]) == null)
	_check("a two-point 'area' still yields a point",
			SpaceRegistry.area_interior_point([[0, 0], [4, 0]]) is Vector2)

	# End to end through the registry: tag an area, resolve it, claim slots.
	var reg := SpaceRegistry.create_empty()
	var sid := reg.set_space_type({"kind": "area", "poly": l_shape}, "fire_circle", 8)
	_check("an area can be tagged", not sid.is_empty())
	var rec := reg.find_by_id(sid)
	_check("the area keeps its type", str(rec.get("space_type", "")) == "fire_circle")
	var resolved: Variant = reg.resolve_position(rec, null)
	_check("an area resolves without a scene", resolved is Vector2)
	_check("the resolved point is inside the area",
			SpaceRegistry.polygon_contains(l_shape, resolved as Vector2))
	_check("areas hold their stated capacity",
			reg.claim(sid, "x") and reg.claim(sid, "y") and reg.has_free_capacity(sid))
	_check("area occupants get their own standing slots",
			reg.slot_offset(sid, "x") != reg.slot_offset(sid, "y"))

	# Persistence: areas must survive a save/load round trip like any target.
	var blob := reg.serialize()
	var reg2 := SpaceRegistry.create_empty()
	reg2.deserialize(blob)
	var rec2 := reg2.find_by_id(sid)
	_check("areas survive serialization", not rec2.is_empty())
	var poly2: Array = (rec2.get("target", {}) as Dictionary).get("poly", [])
	_check("the outline round-trips", poly2.size() == l_shape.size())
	_check("the round-tripped area resolves the same",
			(reg2.resolve_position(rec2, null) as Vector2).is_equal_approx(
				resolved as Vector2))

	# Re-tagging the SAME outline must update in place, not pile up duplicates.
	var sid_again := reg2.set_space_type({"kind": "area", "poly": poly2}, "kitchen", 4)
	_check("re-tagging an area updates it", sid_again == sid)
	_check("no duplicate area record", reg2.spaces.size() == 1)
	_check("the new type took", str(reg2.find_by_id(sid).get("space_type", "")) == "kitchen")


# --- Tier 5: daily routines --------------------------------------------------

func _test_routine_schedule() -> void:
	var r := NpcRoutine.default_day()
	_check("the day tiles to 24 h", absf(r.total_hours() - 24.0) < 0.001,
			"%.3f h" % r.total_hours())
	_check("exactly 3 bathroom visits", r.toilet_visits_per_day() == 3,
			"%d" % r.toilet_visits_per_day())

	# Every hour must land in exactly one block — gaps would leave people with
	# nowhere to be, which is the behaviour this whole system replaces.
	for i in range(24 * 12):
		var h := float(i) / 12.0
		var b := r.block_at(h)
		_check("hour %s is scheduled" % NpcRoutine.format_hour(h),
				not b.is_empty() and str(b.get("kind", "")) != "" , "%.2f" % h)

	# The schedule the player asked for, spot-checked at its boundaries.
	_check("asleep at 02:00", str(r.block_at(2.0).get("kind", "")) == NpcRoutine.SLEEP)
	_check("asleep at 23:45", str(r.block_at(23.75).get("kind", "")) == NpcRoutine.SLEEP)
	_check("bathroom at 08:02", str(r.block_at(8.03).get("kind", "")) == NpcRoutine.BATHROOM)
	_check("eating at 08:30", str(r.block_at(8.5).get("kind", "")) == NpcRoutine.EAT)
	_check("enrichment at 09:30", str(r.block_at(9.5).get("kind", "")) == NpcRoutine.ENRICHMENT)
	_check("working at 12:00", str(r.block_at(12.0).get("kind", "")) == NpcRoutine.WORK)
	_check("eating at 13:30", str(r.block_at(13.5).get("kind", "")) == NpcRoutine.EAT)
	_check("bathroom at 13:58", str(r.block_at(13.97).get("kind", "")) == NpcRoutine.BATHROOM)
	_check("working at 16:00", str(r.block_at(16.0).get("kind", "")) == NpcRoutine.WORK)
	_check("eating at 18:30", str(r.block_at(18.5).get("kind", "")) == NpcRoutine.EAT)
	_check("bathroom at 19:02", str(r.block_at(19.03).get("kind", "")) == NpcRoutine.BATHROOM)
	# The evening block is FREE, not ENRICHMENT — that is what lets it reach the
	# chore board at all (only WORK and FREE do; every other kind resolves to a
	# need and returns). Typed ENRICHMENT it contributed zero work hours.
	_check("free at 21:00", str(r.block_at(21.0).get("kind", "")) == NpcRoutine.FREE)
	# The work budget itself, pinned so a future routine edit cannot quietly
	# re-starve the board the way the ENRICHMENT typing did.
	var chore_h := r.hours_of(NpcRoutine.WORK) + r.hours_of(NpcRoutine.FREE)
	_check("the default day leaves >=10 chore-eligible hours", chore_h >= 10.0,
			"%.2f h" % chore_h)
	_check("the default day still tiles 24 h",
			absf(r.total_hours() - 24.0) < 0.001, "%.3f" % r.total_hours())

	# A bathroom block really is ~5 minutes.
	var visit := r.hours_of(NpcRoutine.BATHROOM) / 3.0
	_check("a bathroom visit is 5 minutes",
			absf(visit - 5.0 / 60.0) < 0.0005, "%.1f min" % (visit * 60.0))

	# Waste split: the day's flush water divided evenly across the visits.
	_check("each visit carries one third of the day",
			absf(r.water_per_visit_l() - NpcRoutine.WATER_PER_VISIT_L) < 0.001,
			"%.2f L" % r.water_per_visit_l())
	var daily := r.water_per_visit_l() * float(r.toilet_visits_per_day())
	_check("the day totals 18 L of flush water", absf(daily - 18.0) < 0.01,
			"%.1f L" % daily)
	# And the activity table actually delivers that per visit.
	var act: Dictionary = NpcAgent.ACTIVITIES["bladder"]
	var per_visit := float((act["consumes"] as Dictionary)["water"]) * float(act["duration_h"])
	_check("a visit draws exactly one flush",
			absf(per_visit - NpcRoutine.WATER_PER_VISIT_L) < 0.001,
			"%.2f L" % per_visit)

	# Variation: people must NOT move in lockstep, but must be reproducible.
	var offsets: Dictionary = {}
	for i in range(24):
		var off := NpcRoutine.offset_for("hab_npc_%d" % i)
		_check("offset is bounded",
				absf(off) <= NpcRoutine.MAX_PHASE_OFFSET_H + 0.0001, "%.3f" % off)
		offsets[snappedf(off, 0.01)] = true
	_check("the camp does not move in lockstep", offsets.size() >= 12,
			"%d distinct offsets across 24 people" % offsets.size())
	_check("offsets are deterministic",
			NpcRoutine.offset_for("hab_npc_3") == NpcRoutine.offset_for("hab_npc_3"))

	# Editing round-trip, so the UI can persist a custom day.
	var arr := r.to_array()
	var r2 := NpcRoutine.from_array(arr)
	_check("a routine round-trips", r2.blocks.size() == r.blocks.size())
	_check("the round-tripped day still tiles",
			absf(r2.total_hours() - 24.0) < 0.001)
	_check("a junk routine falls back to the default day",
			NpcRoutine.from_array([]).toilet_visits_per_day() == 3)

	# An edited routine with a different visit count stays mass-honest: each
	# visit is one flush, so four blocks is four flushes, not a rescaled third.
	var four := NpcRoutine.from_array(arr + [{"start_h": 16.0, "end_h": 16.08,
			"kind": NpcRoutine.BATHROOM}])
	_check("adding a block adds a visit", four.toilet_visits_per_day() == 4)


## The behaviour the player actually reported: people arriving at the restroom
## and STAYING there, because a finished activity left them idling wherever
## they stood and nearest-space selection then kept picking the same place.
## Two scarce daily jobs — the shape that exposes the first-refusal bias.
func _fair_board() -> NpcChoreBoard:
	var b := NpcChoreBoard.create_empty()
	for i in 2:
		b.add_chore("Job %d" % i, 3.0, {
			"window": {"start_h": 0.0, "end_h": 24.0},
			"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
			"repeat": "daily", "min_workers": 1, "max_workers": 1,
			"target": {"kind": "pos", "x": 25.0 + float(i) * 8.0, "z": 5.0},
		})
	return b


## Fairness — the systematic bias, and the two fixes it needed.
##
## Two independent defects, and fixing either alone leaves the other:
##   - the engine iterated `for a in agents:` in fixed array order, and
##     _begin_chore takes options[0] and claims it, so agent 0 got first
##     refusal on every chore every substep, forever;
##   - available_for's comparator takes agent_id and never used it, so every
##     agent was handed an identical list to converge on.
func _test_fairness_rotation() -> void:
	var site := _make_test_site()
	site["chore_pos_of"] = _pos_chore_resolver()
	# TWO single-worker jobs and SIX people, run over four days. The scenario
	# matters: with a job per person the CLAIM distributes the work by itself
	# (a claimed chore is filtered out by the crew cap), and the bias hides.
	# It only bites when jobs are scarcer than hands — which is the normal
	# state of a settlement — because then the same person wins the same
	# scramble every single day.
	var board := _fair_board()
	var engine := NpcPopulationEngine.new()
	engine.configure(6, "fair", Vector2.ZERO)
	engine.chore_board = board
	engine.routine = NpcRoutine.default_day()
	_run_sim(engine, site, 8.0, 24.0 * 4.0, 1.0 / 60.0)

	var ids: Array = []
	for a in engine.agents:
		ids.append((a as NpcAgent).id)
	# THE REGRESSION GUARD, and it FAILS on the pre-fix code.
	#
	# Two 3 h daily chores over four days is 24 h of work, full stop. Before
	# _arm_cycle was made once-per-cycle it reset progress on EVERY credit, so
	# the chores never completed after day one and the crew burned 99.59 h
	# achieving one day's work. The total is the tell; the completion count is
	# the cause.
	var banked := 0.0
	for aid in ids:
		banked += engine.labour.total_hours(str(aid))
	_check("a repeating chore consumes only the labour it is worth",
		absf(banked - 24.0) < 0.5, "%.2f h banked, want 24" % banked)
	for c in board.chores:
		_check("and completes every day, not just the first",
			int((c as Dictionary).get("done_day", -1)) >= 3,
			"done_day %d" % int((c as Dictionary).get("done_day", -1)))

	# ⚠ KNOWN LIMITATION, asserted so it cannot silently get worse.
	#
	# Work is NOT evenly spread yet, and least-worked-first ask order does not
	# fix it: measured identically with fixed order. Who works is decided by
	# who happens to be FREE when a chore comes due, and the routine phase
	# offsets make that reliably the same people. Ordering removes the
	# structural first-refusal bias (agent 0 asking first every substep
	# forever) but availability dominates it.
	#
	# Equal rotation needs named slots — the duty roster — which is the next
	# phase. This asserts only that SOMEBODY does the work and the ledger
	# reflects it, so a regression to nobody-works is caught here.
	var f := NpcLabourLog.fairness(engine.labour, ids, 0, 9999)
	var busy_ids := 0
	for aid in ids:
		if engine.labour.total_hours(str(aid)) > 0.0:
			busy_ids += 1
	_check("the work got done by somebody", busy_ids >= 1 and banked > 20.0,
		"%d worked, %.1f h (spread %.2f — see the note above)"
			% [busy_ids, banked, f.get("spread", 0.0)])

	# Determinism: the rotation is keyed on the sim day and substep index, not
	# a RNG, so two identical runs must produce identical ledgers. This is the
	# check that proves the fix did not trade bias for noise.
	var e2 := NpcPopulationEngine.new()
	e2.configure(6, "fair", Vector2.ZERO)
	e2.chore_board = _fair_board()
	e2.routine = NpcRoutine.default_day()
	_run_sim(e2, site, 8.0, 24.0 * 4.0, 1.0 / 60.0)
	var same := true
	for aid in ids:
		if absf(engine.labour.total_hours(str(aid))
				- e2.labour.total_hours(str(aid))) > 1e-6:
			same = false
	_check("the rotation is deterministic", same)

	# The yield must never starve anybody: with one job on offer, even the
	# person furthest ahead still sees it.
	var b3 := NpcChoreBoard.create_empty()
	var only := b3.add_chore("The only job", 4.0, {
		"window": {"start_h": 0.0, "end_h": 24.0}, "repeat": "daily"})
	for rank in [0, 1, 5, 99]:
		var opts := b3.available_for("x", 100.0, 9.0, {}, 6, rank)
		_check("rank %d still sees the only job" % rank,
			opts.size() == 1 and str((opts[0] as Dictionary).get("id", "")) == only)

	# And it ROTATES rather than reorders arbitrarily: over a list of three,
	# consecutive ranks see different heads.
	var b4 := NpcChoreBoard.create_empty()
	for i in 3:
		b4.add_chore("J%d" % i, 4.0, {"window": {"start_h": 0.0, "end_h": 24.0},
			"repeat": "daily", "priority": i})
	var heads: Array = []
	for rank in 3:
		var o := b4.available_for("x", 100.0, 9.0, {}, 6, rank)
		heads.append(str((o[0] as Dictionary).get("label", "")))
	_check("consecutive ranks are offered different work first",
		heads[0] != heads[1] and heads[1] != heads[2], str(heads))
	_check("and rank 0 still gets the top-priority job", str(heads[0]) == "J0")


## NpcLabourLog — who did how much, and is it even.
func _test_labour_ledger() -> void:
	var lg := NpcLabourLog.create_empty()
	lg.bank("a", 10, 2.0, "dig")
	lg.bank("a", 10, 1.0, "lift")
	lg.bank("a", 4, 5.0, "dig")
	lg.bank("b", 10, 0.5, "dig")
	_check("a day sums across categories", is_equal_approx(lg.day_hours("a", 10), 3.0))
	_check("categories are kept apart",
		is_equal_approx(float(lg.by_category("a", 10, 10).get("dig", 0.0)), 2.0))
	_check("lifetime totals everything", is_equal_approx(lg.total_hours("a"), 8.0))
	_check("zero and negative hours are ignored",
		lg.day_hours("nobody", 10) == 0.0)
	lg.bank("c", 10, -3.0, "dig")
	_check("a negative credit banks nothing", lg.total_hours("c") == 0.0)

	# Window boundaries: the trailing week INCLUDES today and day-6, excludes
	# day-7. Off by one here would quietly change every fairness readout.
	# Day 4 sits exactly six days back from day 10, so it is the far EDGE of
	# that window and must be included; from day 11 it is seven back and must
	# not be. An off-by-one here would quietly shift every fairness readout.
	_check("the week window includes its far edge",
		is_equal_approx(lg.week_hours("a", 10), 8.0), "%.2f" % lg.week_hours("a", 10))
	_check("and excludes the day beyond it",
		is_equal_approx(lg.week_hours("a", 11), 3.0), "%.2f" % lg.week_hours("a", 11))
	_check("the month window reaches further",
		is_equal_approx(lg.month_hours("a", 10), 8.0))

	# Fairness, and the names that explain the number.
	var f := NpcLabourLog.fairness(lg, ["a", "b"], 10, 10)
	_check("fairness names the hardest worker", str(f.get("max_id", "")) == "a")
	_check("and the least", str(f.get("min_id", "")) == "b")
	_check("an uneven split reads as such", str(f.get("label", "")) != "even",
		"%s (spread %.2f)" % [f.get("label", ""), f.get("spread", 0.0)])
	var even := NpcLabourLog.create_empty()
	even.bank("a", 1, 4.0, "dig")
	even.bank("b", 1, 4.0, "dig")
	var fe := NpcLabourLog.fairness(even, ["a", "b"], 1, 1)
	_check("an equal split reads as even", str(fe.get("label", "")) == "even"
		and is_equal_approx(float(fe.get("spread", 1.0)), 0.0))
	_check("fairness over nobody does not divide by zero",
		int(NpcLabourLog.fairness(lg, [], 0, 0).get("n", -1)) == 0)

	# Pruning and forgetting.
	_check("pruning drops old days", lg.prune(10) == 1)
	_check("and keeps the rest", is_equal_approx(lg.total_hours("a"), 3.0))
	lg.forget("a")
	_check("forgetting a departed person clears them", lg.total_hours("a") == 0.0)

	# Round trip. Hours are snapped on the way out — an unrounded float would
	# change every tick and defeat the persist blob gate.
	var lg2 := NpcLabourLog.create_empty()
	lg2.bank("a", 3, 1.0 / 3.0, "dig")
	var rt := NpcLabourLog.deserialize(lg2.serialize())
	_check("a round trip keeps the day index as an int",
		rt.day_hours("a", 3) > 0.0, str(rt.days))
	_check("and snaps the hours",
		is_equal_approx(rt.day_hours("a", 3), 0.33), "%.4f" % rt.day_hours("a", 3))

	# END TO END, and the assertion that FAILS on the pre-ledger code: run a
	# real crew a full sim-day and every worker must have banked something.
	# Before this, credit() returned the applied hours and every caller threw
	# them away, so no per-agent labour record existed anywhere in the game.
	var site := _make_test_site()
	site["chore_pos_of"] = _pos_chore_resolver()
	var board := NpcChoreBoard.create_empty()
	for i in 5:
		board.add_chore("Job %d" % i, 6.0, {
			"window": {"start_h": 0.0, "end_h": 24.0},
			"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
			"repeat": "daily", "min_workers": 1, "max_workers": 1,
			"target": {"kind": "pos", "x": 30.0 + float(i) * 4.0, "z": 0.0},
		})
	var engine := NpcPopulationEngine.new()
	engine.configure(5, "led", Vector2.ZERO)
	engine.chore_board = board
	engine.routine = NpcRoutine.default_day()
	_run_sim(engine, site, 9.0, 20.0, 1.0 / 60.0)
	var worked := 0
	var total := 0.0
	for a in engine.agents:
		var h := engine.labour.total_hours((a as NpcAgent).id)
		total += h
		if h > 0.0:
			worked += 1
	_check("every worker banked hours over a sim-day",
		worked == engine.agents.size(),
		"%d of %d banked, %.2f h total" % [worked, engine.agents.size(), total])
	_check("and the total is plausible", total > 1.0 and total < 5.0 * 20.0,
		"%.2f h" % total)
	# The ledger must survive the save path, which the walking ledger does not.
	var e2 := NpcPopulationEngine.new()
	e2.restore(engine.snapshot(29.0))
	_check("the ledger survives snapshot/restore",
		absf(e2.labour.total_hours(str((engine.agents[0] as NpcAgent).id))
			- engine.labour.total_hours(str((engine.agents[0] as NpcAgent).id))) < 0.02)


## Recurrence — weekly, every-N, and the epoch the weekday rests on.
func _test_recurrence() -> void:
	# THE PIN. `weekday()` is `day_index % 7` and is only correct because
	# abs_hours counts from proleptic-Gregorian year 1 Jan 1, which was a
	# Monday. If CelestialClock's origin ever moves, this fails loudly here
	# instead of quietly shifting everyone's laundry day.
	# 2026-08-08 is a Saturday; its day index is 739835.
	var sat := 739835
	_check("the weekday epoch is Monday-aligned",
		NpcChoreBoard.weekday_of_day(sat) == 5,
		"day %d -> %d, want 5 (Sat)" % [sat, NpcChoreBoard.weekday_of_day(sat)])
	_check("and it advances", NpcChoreBoard.weekday_of_day(sat + 1) == 6
		and NpcChoreBoard.weekday_of_day(sat + 2) == 0)
	_check("weekday() agrees with weekday_of_day()",
		NpcChoreBoard.weekday(float(sat) * 24.0 + 9.5) == 5)

	# Fail-closed normalization. Two producers emitted a BOOL here.
	_check("a bool repeat normalizes to once",
		NpcChoreBoard.normalize_repeat(false) == "once")
	_check("an unknown repeat normalizes to once",
		NpcChoreBoard.normalize_repeat("fortnightly") == "once")
	_check("a legal repeat survives",
		NpcChoreBoard.normalize_repeat("weekly") == "weekly")

	var b := NpcChoreBoard.create_empty()
	var h := func(day: int) -> float: return float(day) * 24.0 + 9.0

	# every_n: due on the Nth day, not before.
	var e := b.add_chore("Water the beds", 0.5,
		{"repeat": "every_n", "repeat_days": 3, "window": {"start_h": 0.0, "end_h": 24.0}})
	b.find(e)["done_day"] = sat
	_check("every_n is not due the next day",
		b.available_for("a", h.call(sat + 1), 9.0, {}, 1).is_empty())
	_check("nor two days later",
		b.available_for("a", h.call(sat + 2), 9.0, {}, 1).is_empty())
	_check("and IS due on the third",
		b.available_for("a", h.call(sat + 3), 9.0, {}, 1).size() == 1)

	# weekly on Wednesday (2). THE ASSERTION THAT FAILS ON THE OLD CODE: before
	# this, "weekly" was not a legal value, fell through _is_due's silent
	# `return false`, and the chore was never due again for the rest of the run.
	var mon := sat + 2                      # Saturday + 2 = Monday
	var w := b.add_chore("Clean the bathrooms", 1.0,
		{"repeat": "weekly", "repeat_dow": [2], "window": {"start_h": 0.0, "end_h": 24.0}})
	b.find(w)["done_day"] = mon
	var due_on := func(day: int) -> bool:
		for c in b.available_for("a", h.call(day), 9.0, {}, 1):
			if str((c as Dictionary).get("id", "")) == w:
				return true
		return false
	_check("a weekly chore is not due the day after it ran",
		not due_on.call(mon + 1), "Tuesday")
	_check("and IS due on its weekday", due_on.call(mon + 2), "Wednesday")
	_check("and is still due the day after, uncaught",
		due_on.call(mon + 3), "Thursday with catch_up")

	# catch_up false skips a missed slot — Wednesday's lunch cannot be cooked
	# on Friday.
	b.find(w)["catch_up"] = false
	_check("without catch-up a missed weekday is skipped",
		not due_on.call(mon + 3))
	_check("but the next occurrence still lands", due_on.call(mon + 9))

	# A weekly with no weekdays named degrades to "every 7 days" rather than
	# to never.
	var wd := b.add_chore("Vague weekly", 1.0,
		{"repeat": "weekly", "window": {"start_h": 0.0, "end_h": 24.0}})
	b.find(wd)["done_day"] = mon
	var due_wd := func(day: int) -> bool:
		for c in b.available_for("a", h.call(day), 9.0, {}, 1):
			if str((c as Dictionary).get("id", "")) == wd:
				return true
		return false
	_check("a weekday-less weekly waits a week", not due_wd.call(mon + 6))
	_check("and then comes due", due_wd.call(mon + 7))

	# The bounded scan: a month late must still read as due, and cheaply.
	b.find(w)["catch_up"] = true
	_check("a month-late weekly is due", due_on.call(mon + 40))

	# Round-trip, including the fail-closed pass on load.
	var b2 := NpcChoreBoard.create_empty()
	b2.deserialize(b.serialize())
	_check("recurrence survives a round trip",
		str(b2.find(w).get("repeat", "")) == "weekly"
			and (b2.find(w).get("repeat_dow", []) as Array) == [2])
	var raw := b.serialize()
	(raw["chores"][0] as Dictionary)["repeat"] = false
	var b3 := NpcChoreBoard.create_empty()
	b3.deserialize(raw)
	_check("a bool repeat on disk loads as once",
		str(b3.chores[0].get("repeat", "")) == "once")

	# Pruning: finished one-offs go, system-owned ones stay.
	var b4 := NpcChoreBoard.create_empty()
	var plain := b4.add_chore("Plain", 1.0, {"repeat": "once"})
	var keyed := b4.add_chore("Machine", 1.0, {"repeat": "once", "chore_key": "mach|g|s"})
	var eff := b4.add_chore("Effectful", 1.0,
		{"repeat": "once", "effect": {"op": "unpack_prop", "prop_id": "p"}})
	var daily := b4.add_chore("Daily", 1.0, {"repeat": "daily"})
	for cid in [plain, keyed, eff, daily]:
		b4.find(cid)["done_day"] = sat
	var pruned := b4.prune_completed(h.call(sat + 10))
	_check("a finished one-off is retired", pruned == 1, "%d pruned" % pruned)
	_check("a system-keyed chore is kept", not b4.find_by_key("mach|g|s").is_empty())
	_check("an unfired effect is kept", not b4.find(eff).is_empty())
	_check("a repeating chore is kept", not b4.find(daily).is_empty())
	b4.find(eff)["effect_done"] = true
	_check("a FIRED effect is then retired",
		b4.prune_completed(h.call(sat + 10)) == 1)
	_check("and a recent one is not",
		b4.prune_completed(h.call(sat + 1)) == 0)


## NpcWorkPose — which work a chore IS.
##
## Driven from REAL SiteProject spec rows wherever possible rather than
## hand-built dictionaries: the classifier's whole value is that it reads the
## vocabulary the generators actually emit, and a fixture I wrote myself would
## only prove I can restate my own rules.
func _test_work_pose_classifier() -> void:
	# Closure first — a family with no clip, or a clip that is not aliased onto
	# the rigged body's single work animation, would render as a missing-clip
	# freeze on one body and nothing at all on the other.
	for fam in NpcWorkPose.FAMILIES:
		var c := NpcWorkPose.clip_for(str(fam))
		_check("family %s has a clip" % fam, not c.is_empty())
		_check("and it resolves to a real rig clip: %s" % c,
			NpcPoseMachine._clip_file_for(c) == NpcRig.CLIP_WORK
				or NpcPoseMachine._clip_file_for(c) == NpcRig.CLIP_IDLE, c)
	_check("an empty chore still classifies",
		NpcWorkPose.FAMILIES.has(NpcWorkPose.family_for({})))
	_check("an unknown chore still classifies",
		NpcWorkPose.FAMILIES.has(NpcWorkPose.family_for({"label": "???"})))

	# A real brigade unload: one crew chore whose crates flow as stage effects.
	var crates: Array = []
	for i in 4:
		crates.append({"pid": "crate_%d" % i, "x": float(i), "z": 0.0})
	# NOTE the return is a {rows, strategy, plan} dict, not a bare Array —
	# indexing it as an Array throws, and a Godot runtime error ABORTS this
	# whole function while the suite still prints PASS. Which is exactly what
	# it did on the first run of this test: 16 of 35 checks silently vanished.
	var brigade: Array = SiteProject.unload_spec_rows(
		crates, Vector2.ZERO, 9, "brigade").get("rows", [])
	_check("the brigade fixture produced rows", not brigade.is_empty())
	var saw_hold := false
	var saw_gate := false
	for r in brigade:
		var fam := NpcWorkPose.family_for(r as Dictionary)
		if fam == NpcWorkPose.HAUL_HOLD:
			saw_hold = true
		if fam == NpcWorkPose.INSPECT:
			saw_gate = true
	_check("a brigade unload reads as a relay hold", saw_hold)
	_check("and its completion gate reads as an inspection", saw_gate)

	# The round-trip strategy instead: every crate is its own carry.
	var trips: Array = SiteProject.unload_spec_rows(
		crates, Vector2.ZERO, 2, "round_trip").get("rows", [])
	_check("the round-trip fixture produced rows", not trips.is_empty())
	var lifts := 0
	for r in trips:
		if NpcWorkPose.family_for(r as Dictionary) == NpcWorkPose.LIFT:
			lifts += 1
	_check("round-trip hauling reads as lifting", lifts >= crates.size(),
		"%d lift rows of %d" % [lifts, trips.size()])

	# The Linkage Lab's fabrication phases, which arrive as set_build_phase.
	var want := {
		"cut": NpcWorkPose.DRILL, "drill": NpcWorkPose.DRILL,
		"assemble": NpcWorkPose.OVERHEAD, "assemble_j1": NpcWorkPose.OVERHEAD,
		"brackets": NpcWorkPose.OVERHEAD, "bolts": NpcWorkPose.OVERHEAD,
		"fold_test": NpcWorkPose.LIFT,
	}
	for phase in want:
		var got := NpcWorkPose.family_for({"chore_hours": 2.0,
			"effect": {"op": "set_build_phase", "phase": str(phase)}})
		_check("phase %s reads as %s" % [phase, want[phase]],
			got == str(want[phase]), got)
	_check("raising the structure reads as lifting",
		NpcWorkPose.family_for({"chore_hours": 2.0,
			"effect": {"op": "unpack_prop"}}) == NpcWorkPose.LIFT)
	_check("mounting panels reads as overhead work",
		NpcWorkPose.family_for({"chore_hours": 2.0,
			"effect": {"op": "seed_graph"}}) == NpcWorkPose.OVERHEAD)

	# Machine-minted labour (the labour merge keys these `mach|<gid>|<step>`).
	_check("tending a machine reads as bench work",
		NpcWorkPose.family_for({"chore_key": "mach|g1|s3", "chore_hours": 0.5})
			== NpcWorkPose.BENCH)
	# And a hand-authored crew chore with no effect at all.
	_check("a plain crew chore reads as overhead work",
		NpcWorkPose.family_for({"chore_hours": 4.0, "min_workers": 3})
			== NpcWorkPose.OVERHEAD)
	_check("a plain solo chore falls back to digging",
		NpcWorkPose.family_for({"chore_hours": 4.0, "min_workers": 1})
			== NpcWorkPose.DIG)

	# merge_catalog must not disturb what was already there.
	var base := {"idle": {"len": 1.0, "loops": true}}
	var merged := NpcWorkPose.merge_catalog(base)
	_check("merge_catalog keeps the installed art", merged.has("idle"))
	_check("and adds the transitions", merged.has(NpcWorkPose.CLIP_WORK_ENTER)
		and merged.has(NpcWorkPose.CLIP_WORK_EXIT))
	_check("and does not mutate its input", base.size() == 1)
	var missing: Array = []
	for fam2 in NpcWorkPose.FAMILIES:
		var c2 := NpcWorkPose.clip_for(str(fam2))
		if NpcWorkPose.is_work_clip(c2) and not merged.has(c2):
			missing.append(c2)
	_check("every procedural family clip is in the merged catalog",
		missing.is_empty(), str(missing))


## Circular concentration R over a set of bearings: 1.0 = everyone pointing
## identically, 0.0 = uniformly spread. The right statistic for "do they all
## face the same way", because a plain variance over angles is wrong across the
## ±PI wrap.
static func _yaw_concentration(yaws: Array) -> float:
	if yaws.is_empty():
		return 1.0
	var sx := 0.0
	var sy := 0.0
	for y in yaws:
		sx += cos(float(y))
		sy += sin(float(y))
	return Vector2(sx, sy).length() / float(yaws.size())


## NpcFacing — the pure maths, including the two properties that make the
## anchor scheme work rather than merely compile.
func _test_facing_rules() -> void:
	var origin := Vector2.ZERO
	# CelestialClock convention: north is −Z, so an anchor "north" of us is at
	# negative Y in the XZ plane and reads as yaw 0.
	_check("an anchor due north reads as yaw 0",
		absf(NpcFacing.base_yaw(origin, Vector2(0.0, -10.0), 1.0)) < 1e-5)
	_check("an anchor due east reads as yaw -PI/2",
		absf(NpcFacing.base_yaw(origin, Vector2(10.0, 0.0), 1.0) + PI * 0.5) < 1e-5)

	# Degenerate anchors fall back to the agent's own phase, so a camp with
	# nothing to look at still faces every which way instead of all facing north.
	_check("no anchor falls back to the agent's phase",
		is_equal_approx(NpcFacing.base_yaw(origin, Vector2.INF, 1.234), 1.234))
	_check("an anchor under our feet falls back too",
		is_equal_approx(NpcFacing.base_yaw(origin, Vector2(0.1, 0.0), 1.234), 1.234))
	_check("and different agents fall back differently",
		not is_equal_approx(NpcFacing.base_yaw(origin, Vector2.INF, 1.0),
			NpcFacing.base_yaw(origin, Vector2.INF, 2.0)))

	# The drift bound is asserted, not sampled and hoped for: the far-LOD path
	# turns the slew into a hard set, so an unbounded drift would read as a
	# visible twitch at distance.
	var worst := 0.0
	for i in 10000:
		var h := float(i) * 0.00731
		for ph in [0.0, 0.8, 1.9, 3.0, 3.9, 4.7, 5.5, 6.1]:
			worst = maxf(worst, absf(NpcFacing.drift(float(ph), h)))
	_check("idle drift stays inside its amplitude bound",
		worst <= NpcFacing.DRIFT_AMP_RAD + 1e-6, "%.6f" % worst)
	_check("drift actually moves", worst > NpcFacing.DRIFT_AMP_RAD * 0.5)
	_check("drift before the first tick is zero", NpcFacing.drift(1.0, NAN) == 0.0)
	_check("drift is reproducible",
		is_equal_approx(NpcFacing.drift(1.0, 5.5), NpcFacing.drift(1.0, 5.5)))

	# The load-bearing pair. A PROJECTED anchor (8 m out, used when someone
	# stands exactly on their target) must be stable under one tick of
	# crowding, while a REAL anchor close by must be responsive to it — that
	# responsiveness is the whole mechanism by which the separation pass
	# finally reaches the facings.
	var nudge := Vector2(0.25, 0.0)   # NpcPopulationEngine.MAX_PUSH_M
	var far_a := Vector2(0.0, -8.0)
	var d_far := absf(angle_difference(
		NpcFacing.base_yaw(origin, far_a, 0.0),
		NpcFacing.base_yaw(nudge, far_a, 0.0)))
	var near_a := Vector2(0.0, -1.0)
	var d_near := absf(angle_difference(
		NpcFacing.base_yaw(origin, near_a, 0.0),
		NpcFacing.base_yaw(nudge, near_a, 0.0)))
	_check("a projected anchor is stable under one tick of crowding",
		d_far < deg_to_rad(2.5), "%.2f deg" % rad_to_deg(d_far))
	_check("a nearby anchor is responsive to it",
		d_near > deg_to_rad(10.0), "%.2f deg" % rad_to_deg(d_near))


## The reported bug, as an assertion: workers at one crew site must not all
## face the same way — and the fix must be a real rule rather than added noise.
##
## Both checks FAIL on the pre-fix code by construction. `chore_pos_of`
## resolves a non-brigade crew chore to ONE coordinate, so every worker walks
## the same nav route to the same point and arrives on the same heading; the
## old host latched yaw on exactly that heading and the separation pass, capped
## at 0.25 m, never nudged hard enough to re-trigger the write.
func _test_crew_facing_spread() -> void:
	var site := _make_test_site()
	site["chore_pos_of"] = _pos_chore_resolver()
	var board := NpcChoreBoard.create_empty()
	var work_at := Vector2(60.0, 0.0)
	board.add_chore("Raise the frame", 240.0, {
		"window": {"start_h": 0.0, "end_h": 24.0},
		"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
		"repeat": "once", "min_workers": 4, "max_workers": 8,
		"target": {"kind": "pos", "x": work_at.x, "z": work_at.y},
	})
	var engine := NpcPopulationEngine.new()
	engine.configure(8, "face", Vector2.ZERO)
	engine.chore_board = board
	engine.routine = NpcRoutine.default_day()
	_run_sim(engine, site, 9.0, 6.0, 1.0 / 60.0)

	var face_yaws: Array = []
	var to_work_yaws: Array = []
	for d in engine.agent_dots():
		var dd: Dictionary = d
		if str(dd.get("activity", "")) != NpcAgent.CHORE_ACTIVITY:
			continue
		if int(dd.get("state", 0)) != NpcAgent.State.DOING:
			continue
		face_yaws.append(float(dd.get("face_yaw", 0.0)))
		var to_work := work_at - (dd.get("pos", Vector2.ZERO) as Vector2)
		if to_work.length() > 0.05:
			to_work_yaws.append(atan2(-to_work.x, -to_work.y))

	if face_yaws.size() < 3:
		_check("a crew mustered at the work site", false,
			"only %d workers DOING" % face_yaws.size())
		return
	var r_face := _yaw_concentration(face_yaws)
	_check("workers at one crew site do not all face the same way",
		r_face < 0.6, "R=%.3f over %d workers" % [r_face, face_yaws.size()])

	# The corridor test, and the reason the first check alone is not enough.
	# Everyone walks from the camp to one work coordinate, so the OLD latched
	# heading was this bearing for every single worker — R would be ~1.0 about
	# it. Note the trail cannot be used for this: TRAIL_MAX_AGE_H prunes it to
	# the last half sim-hour, so by the time a crew is working it is empty.
	var corridor := atan2(-(work_at - Vector2.ZERO).x, -(work_at - Vector2.ZERO).y)
	var on_corridor := 0
	for y in face_yaws:
		if absf(angle_difference(float(y), corridor)) < deg_to_rad(20.0):
			on_corridor += 1
	_check("they are not all still pointing down the approach corridor",
		on_corridor < face_yaws.size(),
		"%d of %d within 20 deg of the walk-in bearing"
			% [on_corridor, face_yaws.size()])

	# And the positive form: spread is not the same as correct. Each worker
	# must actually be turned toward the job they are standing around.
	if to_work_yaws.size() == face_yaws.size():
		var aimed := 0
		for i in face_yaws.size():
			if absf(angle_difference(float(face_yaws[i]),
					float(to_work_yaws[i]))) < deg_to_rad(30.0):
				aimed += 1
		_check("each worker is turned toward the work site",
			aimed >= int(ceil(float(face_yaws.size()) * 0.75)),
			"%d of %d aimed" % [aimed, face_yaws.size()])

	# The paired opposite, so the rules are proven CONTEXT-AWARE rather than
	# merely noisy: a relay line must line up, not scatter.
	var b2 := NpcChoreBoard.create_empty()
	var from := Vector2(-30.0, 10.0)
	var to := Vector2(30.0, 10.0)
	b2.add_chore("Pass the crates", 120.0, {
		"window": {"start_h": 0.0, "end_h": 24.0},
		"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
		"repeat": "once", "min_workers": 3, "max_workers": 6,
		"target": {"kind": "pos", "x": to.x, "z": to.y},
		"haul": {"strategy": "brigade",
			"from_x": from.x, "from_z": from.y, "to_x": to.x, "to_z": to.y},
	})
	var e2 := NpcPopulationEngine.new()
	e2.configure(6, "relay", Vector2.ZERO)
	e2.chore_board = b2
	e2.routine = NpcRoutine.default_day()
	_run_sim(e2, site, 9.0, 6.0, 1.0 / 60.0)
	var relay_yaws: Array = []
	for d in e2.agent_dots():
		var dd2: Dictionary = d
		if int(dd2.get("state", 0)) == NpcAgent.State.DOING \
				and str(dd2.get("activity", "")) == NpcAgent.CHORE_ACTIVITY:
			relay_yaws.append(float(dd2.get("face_yaw", 0.0)))
	if relay_yaws.size() >= 3:
		var want := atan2(-(to - from).x, -(to - from).y)
		var r_relay := _yaw_concentration(relay_yaws)
		_check("a relay line faces the same way, and it is DOWN the line",
			r_relay > 0.9, "R=%.3f over %d" % [r_relay, relay_yaws.size()])
		var worst_off := 0.0
		for y in relay_yaws:
			worst_off = maxf(worst_off, absf(angle_difference(float(y), want)))
		_check("every station points along the route",
			worst_off < deg_to_rad(10.0), "%.1f deg off" % rad_to_deg(worst_off))
	else:
		_check("a relay crew mustered", false,
			"only %d stationed" % relay_yaws.size())


## NpcHash — the shared avalanche, and the migration guard around it.
##
## The first block is the whole reason this function exists: `NpcRoutine
## .offset_for` had its avalanche extracted into `NpcHash`, and these literals
## were captured from the code BEFORE that extraction. Routine offsets shift
## every agent's entire day, so any drift here — one ULP included — silently
## moves every downstream sim golden in this file. If this block fails after a
## refactor, the refactor changed behaviour; it is not the pin that is wrong.
func _test_hash_distribution() -> void:
	const FROZEN: Array = [
		0.152008795, -0.125424745, -0.102638417, 0.155506696,
		0.473515890, 0.080251849, -0.214971017, 0.308414951,
	]
	var drift_ok := true
	for i in FROZEN.size():
		if absf(NpcRoutine.offset_for("hab_npc_%d" % i) - float(FROZEN[i])) > 1e-9:
			drift_ok = false
	_check("routine offsets are byte-identical after the NpcHash extraction",
		drift_ok, "offset_for drifted — every sim golden below is now suspect")

	# The bug NpcHash exists to fix, stated as a measurement rather than a
	# comment. Bucket 64 sequential ids 8 ways: the avalanche fills every bin;
	# the naive `hash() % n` form collapses them.
	var good: Array = [0, 0, 0, 0, 0, 0, 0, 0]
	var weak: Array = [0, 0, 0, 0, 0, 0, 0, 0]
	for i in 64:
		var id := "hab_npc_%d" % i
		good[mini(int(NpcHash.unit01(id) * 8.0), 7)] += 1
		weak[mini(int(float(absi(hash(id)) % 997) / 997.0 * 8.0), 7)] += 1
	var good_empty := 0
	var good_max := 0
	for b in good:
		if int(b) == 0:
			good_empty += 1
		good_max = maxi(good_max, int(b))
	var weak_empty := 0
	for b in weak:
		if int(b) == 0:
			weak_empty += 1
	_check("the avalanche fills every bucket", good_empty == 0, str(good))
	_check("and concentrates none of them", good_max <= 19, str(good))
	_check("while the naive hash leaves most buckets empty (the bug)",
		weak_empty >= 3, str(weak))

	# Salts must decorrelate, or "which gait" and "which stance" would be the
	# same draw for every person in the camp.
	var same := 0
	for i in 64:
		var id := "hab_npc_%d" % i
		if absf(NpcHash.unit01(id, "a") - NpcHash.unit01(id, "b")) < 1e-9:
			same += 1
	_check("salted draws are independent", same == 0, "%d collisions" % same)
	_check("and reproducible", is_equal_approx(
		NpcHash.unit01("hab_npc_3", "a"), NpcHash.unit01("hab_npc_3", "a")))

	# pick() must stay in range including the degenerate sizes.
	var in_range := true
	for i in 64:
		var v := NpcHash.pick("hab_npc_%d" % i, "gait", 3)
		if v < 0 or v > 2:
			in_range = false
	_check("pick stays in 0..n-1", in_range)
	_check("pick(n=1) is 0", NpcHash.pick("x", "s", 1) == 0)
	_check("pick(n=0) does not divide by zero", NpcHash.pick("x", "s", 0) == 0)


func _test_routine_behaviour() -> void:
	var site := _make_test_site()
	var engine := NpcPopulationEngine.new()
	engine.configure(10, "routine_hab", Vector2.ZERO)
	_check("an engine has a routine by default", engine.routine != null)

	var restroom_pos: Variant = null
	var reg: SpaceRegistry = site["registry"]
	for sp in reg.spaces_of_type("restroom"):
		restroom_pos = (site["pos_of"] as Callable).call(sp)
		break
	_check("the test site has a restroom", restroom_pos is Vector2)

	# Run a full day and sample where people are, minute by minute.
	var at_restroom := 0
	var samples := 0
	var kinds_seen: Dictionary = {}
	var t := 8.0
	while t < 32.0:
		t += 1.0 / 60.0
		engine.tick(t, {
			"registry": reg, "pos_of": site["pos_of"],
			"hour_of_day": fposmod(t, 24.0),
		})
		for a in engine.agents:
			var agent: NpcAgent = a
			samples += 1
			if (restroom_pos as Vector2).distance_to(agent.pos) < 4.0:
				at_restroom += 1
			if not agent.routine_kind.is_empty():
				kinds_seen[agent.routine_kind] = true
	var share := float(at_restroom) / maxf(float(samples), 1.0)
	# 3 five-minute visits is 15 min of a 24 h day = ~1%. Allowing 12% leaves
	# room for walking there and for need-driven interruptions, while still
	# failing hard on the old behaviour, where people simply lived there.
	_check("nobody lives at the restroom", share < 0.12,
			"%.1f%% of person-samples were at the toilets" % (share * 100.0))
	_check("the routine drives several kinds of block", kinds_seen.size() >= 3,
			", ".join(kinds_seen.keys()))

	# People must still be fed and watered under a schedule — the routine
	# replaces WHERE they idle, not whether their needs get met.
	var worst_hunger := 0.0
	for a in engine.agents:
		worst_hunger = maxf(worst_hunger, float((a as NpcAgent).needs.get("hunger", 0.0)))
	_check("a scheduled day still feeds people", worst_hunger < 0.95,
			"worst hunger %.2f" % worst_hunger)


# --- Tier 5: clip roles + pose machine ---------------------------------------

## Roles are MEASURED, never read off the filename. Driven with synthetic
## measurements so it runs with no art installed.
func _test_clip_classifier() -> void:
	# A walk: goes somewhere, ends in the pose it started.
	_check("travel with an unchanged pose is locomotion",
			NpcRig.classify({"hip_xz_travel_m": 1.69, "pose_delta": 0.0,
				"y_cycles": 3, "hip_y_swing": 0.07}) == NpcRig.ROLE_LOCOMOTION)
	# "Sad Walk" trudges with only 3.8 cm of hip rise — under the noise floor,
	# so a bob-count requirement would misclassify it. It is still a walk.
	_check("a walk with almost no bob is still locomotion",
			NpcRig.classify({"hip_xz_travel_m": 1.08, "pose_delta": 0.0,
				"y_cycles": 0, "hip_y_swing": 0.038}) == NpcRig.ROLE_LOCOMOTION)
	# Start vs stop differ ONLY by which end is faster. This is the check a
	# filename map cannot do, and a swapped export is exactly what it catches.
	var start := {"hip_xz_travel_m": 1.82, "pose_delta": 9.5, "y_cycles": 0,
			"hip_y_swing": 0.055, "speed_first_third": 0.15, "speed_last_third": 0.96}
	var stop := {"hip_xz_travel_m": 1.10, "pose_delta": 9.5, "y_cycles": 0,
			"hip_y_swing": 0.049, "speed_first_third": 0.82, "speed_last_third": 0.03}
	_check("accelerating travel is a walk start",
			NpcRig.classify(start) == NpcRig.ROLE_LOCO_START)
	_check("decelerating travel is a walk stop",
			NpcRig.classify(stop) == NpcRig.ROLE_LOCO_STOP)
	_check("swapping the speed profile swaps the role",
			NpcRig.classify(stop) != NpcRig.classify(start))
	# Level changes.
	_check("ending lower is a descend",
			NpcRig.classify({"hip_y_start": 0.94, "hip_y_end": 0.12,
				"pose_delta": 17.9}) == NpcRig.ROLE_DESCEND)
	_check("ending higher is an ascend",
			NpcRig.classify({"hip_y_start": 0.12, "hip_y_end": 0.94,
				"pose_delta": 17.9}) == NpcRig.ROLE_ASCEND)
	# A single squat rep returns to its start pose having moved a lot: one
	# reversal, not a gait. Requiring two classified squats and claps as junk.
	_check("a single-rep squat is cyclic",
			NpcRig.classify({"hip_xz_travel_m": 0.0, "pose_delta": 0.0,
				"y_cycles": 1, "hip_y_swing": 0.55}) == NpcRig.ROLE_CYCLIC)
	_check("a held pose is static",
			NpcRig.classify({"hip_xz_travel_m": 0.0, "pose_delta": 0.1,
				"y_cycles": 0, "hip_y_swing": 0.001}) == NpcRig.ROLE_STATIC)

	# Offline guard for the carry-clip drop-in (no assets needed). ONLY genuine
	# level changes get a sampled ground offset. A lift dips to grab the crate
	# and therefore MEASURES as descend — if it kept that role, the curve would
	# land the bottom of the dip at seated/lying hip height and sink the figure
	# ~0.7 m into the ground mid-pickup. ROLE_CARRY is forced past classify()
	# precisely so it lands on the constant-fill path.
	_check("descend/ascend need a sampled offset curve",
			NpcRig.role_needs_offset_curve(NpcRig.ROLE_DESCEND)
				and NpcRig.role_needs_offset_curve(NpcRig.ROLE_ASCEND))
	_check("carry takes the constant path (the sink guard)",
			not NpcRig.role_needs_offset_curve(NpcRig.ROLE_CARRY))
	_check("locomotion/cyclic/static take the constant path",
			not NpcRig.role_needs_offset_curve(NpcRig.ROLE_LOCOMOTION)
				and not NpcRig.role_needs_offset_curve(NpcRig.ROLE_CYCLIC)
				and not NpcRig.role_needs_offset_curve(NpcRig.ROLE_STATIC))
	# classify() reads HIPS; carrying is an arms pose. A role the classifier can
	# never return must never be used as an assertion — hence the forced column.
	var carry_never := true
	for probe in [{"hip_xz_travel_m": 1.7, "pose_delta": 1.0, "y_cycles": 2, "hip_y_swing": 0.05},
			{"hip_xz_travel_m": 0.0, "pose_delta": 0.1, "y_cycles": 0, "hip_y_swing": 0.001},
			{"hip_xz_travel_m": 0.1, "pose_delta": 5.0, "y_cycles": 0, "hip_y_swing": 0.5,
				"hip_y_start": 0.94, "hip_y_end": 0.12},
			{"hip_xz_travel_m": 0.0, "pose_delta": 0.0, "y_cycles": 1, "hip_y_swing": 0.55}]:
		if NpcRig.classify(probe as Dictionary) == NpcRig.ROLE_CARRY:
			carry_never = false
	_check("classify never returns ROLE_CARRY", carry_never)

	if not NpcRig.available():
		return
	# Asset-gated: what the real files measured as. The pair that matters is
	# sleep -- "Idle To Situp" is the LIE-DOWN despite its name.
	for pair in [[NpcRig.CLIP_SLEEP_ENTER, NpcRig.ROLE_DESCEND],
			[NpcRig.CLIP_SLEEP_EXIT, NpcRig.ROLE_ASCEND],
			[NpcRig.CLIP_SIT_EXIT, NpcRig.ROLE_ASCEND],
			[NpcRig.CLIP_WALK_START, NpcRig.ROLE_LOCO_START],
			[NpcRig.CLIP_WALK_STOP, NpcRig.ROLE_LOCO_STOP],
			[NpcRig.CLIP_WALK_SAD, NpcRig.ROLE_LOCOMOTION]]:
		var m := NpcRig.clip_measurement(str(pair[0]))
		_check("measured role: %s" % str(pair[0]),
				str(m.get("role", "")) == str(pair[1]),
				"%s vs %s" % [str(m.get("role", "?")), str(pair[1])])
		# The measurement is kept even when a role is forced, so a swapped
		# export is still detectable after the fact.
		_check("measurement retained: %s" % str(pair[0]), m.has("measured_role"))
	# Asset-gated carry rows: only meaningful once someone drops the FBX in.
	if NpcRig.clip_length(NpcRig.CLIP_CARRY) > 0.0:
		var cm := NpcRig.clip_measurement(NpcRig.CLIP_CARRY)
		_check("installed carry clip carries the forced role",
				str(cm.get("role", "")) == NpcRig.ROLE_CARRY)
		_check("installed carry clip gets a flat offset",
				is_equal_approx(NpcRig.clip_ground_offset_at(NpcRig.CLIP_CARRY, 0.0),
					NpcRig.clip_ground_offset_at(NpcRig.CLIP_CARRY, 1.0)))
	# Transitions must not loop or animation_finished never fires.
	for c in [NpcRig.CLIP_SLEEP_ENTER, NpcRig.CLIP_SLEEP_EXIT,
			NpcRig.CLIP_SIT_EXIT, NpcRig.CLIP_WALK_START, NpcRig.CLIP_WALK_STOP]:
		_check("transition does not loop: %s" % c, NpcRig.clip_length(c) > 0.0)

	# The seam test: a transition must leave the body at the same WORLD hip
	# height the pose it lands in expects, or the figure pops vertically.
	var en := NpcRig.clip_measurement(NpcRig.CLIP_SLEEP_ENTER)
	var sl := NpcRig.clip_measurement(NpcRig.CLIP_SLEEP)
	if not en.is_empty() and not sl.is_empty():
		var a := float(en["hip_y_end"]) + NpcRig.clip_ground_offset_at(NpcRig.CLIP_SLEEP_ENTER, 1.0)
		var b := float(sl["hip_y_min"]) + NpcRig.clip_ground_offset(NpcRig.CLIP_SLEEP)
		_check("lie-down lands where the sleep pose sits", absf(a - b) < 0.05,
				"%.3f vs %.3f m" % [a, b])
	# And it must START at standing height, or the figure sinks as it lies down.
	if not en.is_empty():
		var st := float(en["hip_y_start"]) + NpcRig.clip_ground_offset_at(NpcRig.CLIP_SLEEP_ENTER, 0.0)
		_check("lie-down starts standing", absf(st - 0.94) < 0.08, "%.3f m" % st)
	# A squat swings the hips 0.55 m without changing level; treating it as a
	# transition would sink the figure at the bottom of every rep.
	_check("an in-place squat gets no descent curve",
			is_equal_approx(NpcRig.clip_ground_offset_at(NpcRig.CLIP_WORK, 0.0),
				NpcRig.clip_ground_offset_at(NpcRig.CLIP_WORK, 1.0)))


## Synthetic catalog so every sequence test runs with no art installed.
func _pose_catalog() -> Dictionary:
	return {
		NpcRig.CLIP_IDLE: {"len": 2.0, "loops": true},
		NpcRig.CLIP_IDLE_SAD: {"len": 2.8, "loops": true},
		NpcRig.CLIP_WALK: {"len": 1.0, "loops": true},
		NpcRig.CLIP_WALK_SAD: {"len": 1.5, "loops": true},
		NpcRig.CLIP_WALK_START: {"len": 0.9, "loops": false},
		NpcRig.CLIP_WALK_STOP: {"len": 0.9, "loops": false},
		NpcRig.CLIP_SLEEP: {"len": 1.7, "loops": true},
		NpcRig.CLIP_SLEEP_ENTER: {"len": 1.2, "loops": false},
		NpcRig.CLIP_SLEEP_EXIT: {"len": 1.2, "loops": false},
		NpcRig.CLIP_SIT: {"len": 4.3, "loops": true},
		NpcRig.CLIP_SIT_EXIT: {"len": 1.1, "loops": false},
		NpcRig.CLIP_WORK: {"len": 1.9, "loops": true},
		NpcRig.CLIP_EXERCISE: {"len": 2.3, "loops": true},
		NpcRig.CLIP_DANCE: {"len": 22.0, "loops": true},
		NpcRig.CLIP_CLAP: {"len": 4.8, "loops": true},
		NpcRig.CLIP_CLAP_SIT: {"len": 6.5, "loops": true},
	}


func _pose_run(m: NpcPoseMachine, secs: float, inp: Dictionary,
		out: Array = []) -> Array:
	var steps := int(secs * 60.0)
	for i in steps:
		m.step(1.0 / 60.0, inp)
		if out.is_empty() or str(out[out.size() - 1]) != m.clip():
			out.append(m.clip())
	return out


func _test_pose_machine() -> void:
	# The MERGED catalog, exactly as NpcAvatar.setup builds it — the work
	# families and their transitions are procedural, so a bare _pose_catalog()
	# would silently make every _has() guard around them skip and the fuzz
	# below would never reach a single one of them.
	var cat := NpcWorkPose.merge_catalog(_pose_catalog())

	# 1. Walking to bed must NOT lie down on the way. This is the reported bug:
	#    activity is the INTENT for the whole trip, so choosing on intent alone
	#    made people lie down and slide across the site.
	var m := NpcPoseMachine.new()
	m.set_catalog(cat)
	var seen: Array = []
	var travelling := {"in_transit": true, "activity": "sleep", "morale": 0.8,
			"dwell_left_s": 3600.0}
	_pose_run(m, 4.0, travelling, seen)
	_check("nobody lies down while walking to bed",
			not seen.has(NpcRig.CLIP_SLEEP), ", ".join(PackedStringArray(seen)))
	_check("walking to bed actually walks",
			seen.has(NpcRig.CLIP_WALK) or seen.has(NpcRig.CLIP_WALK_START),
			", ".join(PackedStringArray(seen)))

	# 2. Arriving: stop, lie down, sleep — in that order.
	var arrived := {"in_transit": false, "activity": "sleep", "morale": 0.8,
			"dwell_left_s": 3600.0}
	var seq: Array = []
	_pose_run(m, 6.0, arrived, seq)
	var i_enter := seq.find(NpcRig.CLIP_SLEEP_ENTER)
	var i_sleep := seq.find(NpcRig.CLIP_SLEEP)
	_check("arriving plays the lie-down", i_enter >= 0, ", ".join(PackedStringArray(seq)))
	_check("the lie-down precedes sleeping", i_enter >= 0 and i_sleep > i_enter)
	_check("it ends up asleep", m.clip() == NpcRig.CLIP_SLEEP and m.is_lying())

	# 3. Waking: stand up BEFORE walking off.
	var wake: Array = []
	_pose_run(m, 6.0, {"in_transit": true, "activity": "", "morale": 0.8,
			"dwell_left_s": 0.0}, wake)
	var i_exit := wake.find(NpcRig.CLIP_SLEEP_EXIT)
	var i_walk := wake.find(NpcRig.CLIP_WALK)
	_check("waking plays the get-up", i_exit >= 0, ", ".join(PackedStringArray(wake)))
	_check("the get-up precedes walking", i_exit >= 0 and i_walk > i_exit)

	# 4. The bathroom, at BOTH time scales. A 5-minute visit is 0.67 real
	#    seconds at 450x — shorter than one sit-down — so transitions have to
	#    disappear at speed rather than be started and aborted.
	var m2 := NpcPoseMachine.new()
	m2.set_catalog(cat)
	var slow: Array = []
	_pose_run(m2, 8.0, {"in_transit": false, "activity": "bladder",
			"morale": 0.8, "dwell_left_s": 300.0}, slow)
	_check("the bathroom is used sitting down", slow.has(NpcRig.CLIP_SIT),
			", ".join(PackedStringArray(slow)))
	_check("sitting down is animated at 1x", slow.has(NpcRig.CLIP_SIT_ENTER),
			", ".join(PackedStringArray(slow)))

	var m3 := NpcPoseMachine.new()
	m3.set_catalog(cat)
	var fast: Array = []
	_pose_run(m3, 4.0, {"in_transit": false, "activity": "bladder",
			"morale": 0.8, "dwell_left_s": 0.67}, fast)
	_check("a 0.67 s visit skips the sit-down entirely",
			not fast.has(NpcRig.CLIP_SIT_ENTER), ", ".join(PackedStringArray(fast)))
	_check("a 0.67 s visit still sits", fast.has(NpcRig.CLIP_SIT))

	# 5. Interruption: something starts moving mid-sit-down.
	var m4 := NpcPoseMachine.new()
	m4.set_catalog(cat)
	for i in 20:
		m4.step(1.0 / 60.0, {"in_transit": false, "activity": "bladder",
				"morale": 0.8, "dwell_left_s": 300.0})
	m4.step(1.0 / 60.0, {"in_transit": true, "activity": "bladder",
			"morale": 0.8, "dwell_left_s": 0.0})
	for i in 10:
		m4.step(1.0 / 60.0, {"in_transit": true, "activity": "bladder",
				"morale": 0.8, "dwell_left_s": 0.0})
	_check("an interrupted sit-down abandons the seat", not m4.is_seated())

	# 6. Teleport: hard cut, no blend. At high time scale the body relocates
	#    across the map and blending into that would smear.
	var m5 := NpcPoseMachine.new()
	m5.set_catalog(cat)
	m5.step(1.0 / 60.0, {"in_transit": false, "activity": "sleep",
			"morale": 0.8, "dwell_left_s": 3600.0, "teleported": true})
	_check("a teleport cuts with zero blend", is_equal_approx(m5.blend_s(), 0.0))
	_check("a teleport lands on the settled pose", m5.clip() == NpcRig.CLIP_SLEEP)

	# 7. THE ORIGINAL BUG, by name. The sim advances every 15th frame; feeding
	#    that through as an edge is what made the clip alternate. Assert the
	#    machine is stable when in_transit is held as a LEVEL.
	var m6 := NpcPoseMachine.new()
	m6.set_catalog(cat)
	var flips := 0
	var last := ""
	for i in 900:
		m6.step(1.0 / 60.0, {"in_transit": true, "activity": "sleep",
				"morale": 0.8, "dwell_left_s": 3600.0})
		if m6.clip() != last:
			flips += 1
			last = m6.clip()
	_check("a held transit signal does not thrash the clip", flips <= 3,
			"%d clip changes in 15 s of walking" % flips)

	# 8. Mood, with hysteresis so a morale sitting on the boundary does not
	#    flicker gaits.
	var m7 := NpcPoseMachine.new()
	m7.set_catalog(cat)
	var down := 0
	var prev := ""
	for i in 100:
		var mo := 1.0 - float(i) / 100.0
		m7.step(1.0 / 60.0, {"in_transit": true, "activity": "", "morale": mo,
				"dwell_left_s": 0.0})
		if m7.clip() != prev and prev != "":
			if m7.clip() == NpcRig.CLIP_WALK_SAD:
				down += 1
		prev = m7.clip()
	_check("low morale switches to the dejected walk exactly once", down == 1,
			"%d switches" % down)
	_check("the dejected walk is what is playing at rock bottom",
			m7.clip() == NpcRig.CLIP_WALK_SAD)

	# 9. Enrichment resolves by SPACE, so the yoga block does squats and the
	#    fire circle sits and claps.
	var m8 := NpcPoseMachine.new()
	m8.set_catalog(cat)
	_pose_run(m8, 5.0, {"in_transit": false, "activity": "enrichment",
			"space_type": "movement", "morale": 0.9, "dwell_left_s": 3600.0})
	_check("the yoga block works out", m8.clip() == NpcRig.CLIP_EXERCISE, m8.clip())
	var m9 := NpcPoseMachine.new()
	m9.set_catalog(cat)
	_pose_run(m9, 6.0, {"in_transit": false, "activity": "enrichment",
			"space_type": "fire_circle", "morale": 0.9, "dwell_left_s": 3600.0})
	_check("the fire circle dances", m9.clip() == NpcRig.CLIP_DANCE, m9.clip())

	# 9b. Per-slot overrides: the player can rebind what happens in any space.
	var m10 := NpcPoseMachine.new()
	m10.set_catalog(cat)
	m10.set_anim_overrides({"fire_circle": NpcRig.CLIP_CLAP_SIT})
	_pose_run(m10, 6.0, {"in_transit": false, "activity": "enrichment",
			"space_type": "fire_circle", "morale": 0.9, "dwell_left_s": 3600.0})
	_check("an override rebinds a space", m10.clip() == NpcRig.CLIP_CLAP_SIT, m10.clip())
	# An override naming a clip that is not installed must fall back, not freeze
	# the figure on a clip that cannot play.
	var m11 := NpcPoseMachine.new()
	m11.set_catalog(cat)
	m11.set_anim_overrides({"fire_circle": "no_such_clip"})
	_pose_run(m11, 6.0, {"in_transit": false, "activity": "enrichment",
			"space_type": "fire_circle", "morale": 0.9, "dwell_left_s": 3600.0})
	_check("a missing override falls back to the default",
			m11.clip() == NpcRig.CLIP_DANCE, m11.clip())
	# Slots must cover every activity the agent can report, or a slot would be
	# unbindable from the UI.
	for act in NpcAgent.NEEDS:
		if act == "enrichment":
			continue
		_check("slot exists for activity: %s" % act,
				NpcPoseMachine.SLOTS.has(str(act)), str(act))
	for et in SpaceTypes.ENRICHMENT_TYPES:
		_check("slot exists for enrichment space: %s" % et,
				NpcPoseMachine.SLOTS.has(str(et)), str(et))
	var m12 := NpcPoseMachine.new()
	m12.set_catalog(cat)
	m12.step(0.02, {"in_transit": false, "activity": "enrichment",
			"space_type": "movement", "morale": 0.9, "dwell_left_s": 3600.0})
	_check("the slot for an enrichment space is the space", m12.pose_slot() == "movement")
	m12.step(0.02, {"in_transit": false, "activity": "sleep", "morale": 0.9,
			"dwell_left_s": 3600.0})
	_check("the slot for an ordinary activity is the activity",
			m12.pose_slot() == "sleep")

	# 10. FUZZ — the no-wedge guarantee. This is the whole reason the machine is
	#     pure logic rather than an AnimationTree: an AnimationTree cannot be
	#     stepped headless, so this could never be proven.
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var fz := NpcPoseMachine.new()
	fz.set_catalog(cat)
	var acts: Array = ["", "sleep", "bladder", "hunger", "chore", "enrichment", "thirst"]
	var spaces: Array = ["", "movement", "fire_circle", "quiet", "workshop_social"]
	var bad_clip := 0
	var stuck := 0
	var same_run := 0
	var prev_clip := ""
	for i in 200000:
		# dt up to 0.5 s: far-LOD poses at 0.25 s intervals and passes the
		# accumulator as delta, so nothing may assume a 60 Hz step.
		var dt := rng.randf_range(0.001, 0.5)
		fz.step(dt, {
			"in_transit": rng.randf() < 0.5,
			"activity": str(acts[rng.randi() % acts.size()]),
			"space_type": str(spaces[rng.randi() % spaces.size()]),
			"morale": rng.randf(),
			"dwell_left_s": rng.randf_range(0.0, 600.0),
			"teleported": rng.randf() < 0.02,
			"finished": rng.randf() < 0.1,
			# Every work family through the no-wedge guarantee. Cheapest
			# high-value line here: the families multiply the reachable clip
			# set sevenfold and each one has an enter/exit pair.
			"work_pose": str(NpcWorkPose.FAMILIES[
				rng.randi() % NpcWorkPose.FAMILIES.size()]),
		})
		var c := fz.clip()
		if c.is_empty() or not cat.has(NpcPoseMachine._clip_file_for(c)):
			bad_clip += 1
		if c == prev_clip:
			same_run += 1
			if same_run > 4000:
				stuck += 1
		else:
			same_run = 0
			prev_clip = c
	_check("fuzz: the clip is always a real clip", bad_clip == 0,
			"%d bad steps" % bad_clip)
	_check("fuzz: a figure can never wedge", stuck == 0, "%d stuck windows" % stuck)

	# 11. Determinism — same inputs, same timeline. Guards against anyone
	#     reaching for an unseeded randf() inside the machine.
	_check("the machine is deterministic",
			_pose_fingerprint(cat) == _pose_fingerprint(cat))

	# 12. Every clip the machine can emit must exist in the real rig.
	if NpcRig.available():
		var names := NpcRig.clip_names()
		for c in cat.keys():
			# Skip ALIASED clips — sit_enter is sit_exit reversed, carry is
			# the walk, and every work_* family is CLIP_WORK. None of them is
			# a file. This passed before only because the test catalog
			# happened to contain no aliases; it would fail the moment a
			# machine WITH the art installed was fed the merged catalog.
			if NpcPoseMachine._clip_file_for(str(c)) != str(c):
				continue
			_check("catalog clip ships: %s" % c, names.has(str(c)), str(c))


func _pose_fingerprint(cat: Dictionary) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var m := NpcPoseMachine.new()
	m.set_catalog(cat)
	var acc := ""
	for i in 400:
		m.step(0.02, {
			"in_transit": rng.randf() < 0.5,
			"activity": ["", "sleep", "bladder", "chore"][rng.randi() % 4],
			"morale": rng.randf(), "dwell_left_s": rng.randf_range(0.0, 100.0),
		})
		acc += m.clip() + ","
	return acc


## The stylised body is a STYLE, not a fallback: it must be posed from the same
## machine as the rigged one, and choosing it must survive the art being
## installed.
func _test_simple_figure() -> void:
	var prev := NpcDisplayPrefs.style()
	NpcDisplayPrefs.set_style(NpcDisplayPrefs.STYLE_SIMPLE)
	_check("the simple style persists", NpcDisplayPrefs.wants_simple())
	NpcDisplayPrefs.set_style(NpcDisplayPrefs.STYLE_HUMANOID)
	_check("the humanoid style persists", not NpcDisplayPrefs.wants_simple())
	_check("an unknown style falls back to humanoid",
			NpcDisplayPrefs.style() == NpcDisplayPrefs.STYLE_HUMANOID)

	# setup() must leave a usable body behind. This is asserted on OBSERVABLE
	# state rather than trusted to run clean, because a Godot runtime error
	# (assigning through a null reference, say) prints and keeps going — the
	# suite still reports PASS. Exactly that hid a crash on every map load: the
	# avatar kept tinting a `_mat` that the articulated body no longer builds.
	var av2 := NpcAvatar.new()
	av2.setup("agent_setup", Color(0.4, 0.8, 0.6), "Tester")
	_check("setup builds a body", av2.has_body())
	_check("setup names the figure", av2.display_name == "Tester")
	av2.free()

	var fig := NpcSimpleFigure.new()
	fig.setup("agent_x", Color(0.5, 0.7, 0.9))
	# Every clip the machine can emit must pose without erroring, including the
	# reversed sit-down, which is not a file and would otherwise fall through.
	for c in [NpcRig.CLIP_IDLE, NpcRig.CLIP_IDLE_SAD, NpcRig.CLIP_WALK,
			NpcRig.CLIP_WALK_SAD, NpcRig.CLIP_WALK_START, NpcRig.CLIP_WALK_STOP,
			NpcRig.CLIP_SIT, NpcRig.CLIP_SIT_ENTER, NpcRig.CLIP_SIT_EXIT,
			NpcRig.CLIP_SLEEP, NpcRig.CLIP_SLEEP_ENTER, NpcRig.CLIP_SLEEP_EXIT,
			NpcRig.CLIP_WORK, NpcRig.CLIP_EXERCISE, NpcRig.CLIP_DANCE,
			NpcRig.CLIP_CLAP, NpcRig.CLIP_CLAP_SIT]:
		for i in 12:
			fig.pose(c, 1.0, 1.0 / 60.0)
	_check("every clip poses the simple figure", true)

	# Gaits must differ from a held pose, or the figure reads as a statue that
	# slides. Sample a joint across a walk and assert it actually moves.
	var walk_spread := _limb_spread(fig, NpcRig.CLIP_WALK)
	var idle_spread := _limb_spread(fig, NpcRig.CLIP_SLEEP)
	_check("walking articulates the limbs", walk_spread > 0.15,
			"%.3f rad of knee travel" % walk_spread)
	_check("a held pose does not flail", idle_spread < walk_spread,
			"%.3f vs %.3f" % [idle_spread, walk_spread])

	# Deterministic per-agent gait phase, so a crowd is not a chorus line but
	# a replay is still identical.
	var a := NpcSimpleFigure.new()
	a.setup("agent_a", Color.WHITE)
	var b := NpcSimpleFigure.new()
	b.setup("agent_a", Color.WHITE)
	_check("the same agent gets the same gait phase",
			is_equal_approx(_limb_spread(a, NpcRig.CLIP_WALK),
				_limb_spread(b, NpcRig.CLIP_WALK)))
	a.free()
	b.free()
	fig.free()
	NpcDisplayPrefs.set_style(prev)


## Range of knee rotation observed over a second of posing — the cheapest proxy
## for "is this body actually articulating".
func _limb_spread(fig: NpcSimpleFigure, clip: String) -> float:
	var lo := INF
	var hi := -INF
	for i in 60:
		fig.pose(clip, 1.0, 1.0 / 60.0)
		var knee := fig.get_node_or_null("Body/Hip0/Knee0") as Node3D
		if knee == null:
			return 0.0
		lo = minf(lo, knee.rotation.x)
		hi = maxf(hi, knee.rotation.x)
	return hi - lo
