class_name NpcTierConvert
extends RefCounted

## Moves one camp's people between the FULL engine and the LIGHT crowd. Both
## tiers agree on what a person IS — an id, a position, six needs, morale and
## quit pressure — so conversion copies exactly those and lets the receiving
## tier re-plan: a converted person stands IDLE where they were and decides
## afresh on the next tick. Registry claims are released on the way out
## (the other tier re-claims when it arrives somewhere).
##
## The labour log, skills, duty slots and the chore board are NOT people —
## they stay on the full engine object, which the bridge keeps parked while a
## camp is light, so promoting it back finds the settlement's expertise and
## board exactly as left.


## Full → light. `registry` may be null (claims then simply lapse).
static func to_light(engine: NpcPopulationEngine, registry: SpaceRegistry,
		home: Vector2, slots: PackedVector2Array = PackedVector2Array()) -> CrowdCohort:
	var cohort := CrowdCohort.new()
	var n := engine.agents.size()
	var key := _seed_key_of(engine)
	cohort.configure(maxi(n, 1), key, home, slots)
	cohort.routine = engine.routine
	cohort.consequence = engine.consequence
	for i in n:
		var a: NpcAgent = engine.agents[i]
		if registry != null:
			registry.release_all_for_agent(a.id)
		cohort.ids[i] = a.id
		cohort.ax[i] = a.pos.x
		cohort.az[i] = a.pos.y
		cohort.bx[i] = a.pos.x
		cohort.bz[i] = a.pos.y
		for k in 6:
			cohort.needs[i * 6 + k] = float(a.needs.get(NpcAgent.NEEDS[k], 0.0))
		cohort.morale[i] = a.morale
		cohort.quit[i] = a.quit_pressure
		cohort.alive[i] = 1
		cohort.state[i] = CrowdCohort.S_IDLE
		cohort.next_h[i] = NAN
	cohort._initial_roster = engine._initial_roster
	cohort._departures = engine.departures()
	cohort._collapsed = engine.has_collapsed()
	cohort._collapse_warned = cohort._collapsed
	cohort._losses = engine._losses
	return cohort


## Light → full. `engine` is the camp's parked engine (board, labour, skills
## intact) or a fresh one; its roster is rebuilt from the cohort's living
## people and the departed stay departed.
static func to_full(cohort: CrowdCohort, engine: NpcPopulationEngine,
		registry: SpaceRegistry) -> NpcPopulationEngine:
	var t := cohort._last_abs_h if not is_nan(cohort._last_abs_h) else 0.0
	engine.agents = []
	for i in cohort.count():
		if cohort.alive[i] == 0:
			continue
		if registry != null:
			registry.release_all_for_agent(cohort.ids[i])
		var a := NpcAgent.make(cohort.ids[i], cohort.pos_at(i, t))
		for k in 6:
			a.needs[NpcAgent.NEEDS[k]] = cohort.needs[i * 6 + k]
		a.morale = cohort.morale[i]
		a.quit_pressure = cohort.quit[i]
		engine.agents.append(a)
	engine._initial_roster = cohort._initial_roster
	engine._departures = cohort.departures()
	engine._collapsed = cohort.has_collapsed()
	engine._collapse_warned = engine._collapsed
	engine._losses = cohort._losses
	engine._last_abs_h = NAN
	if engine.routine == null:
		engine.routine = cohort.routine if cohort.routine != null else NpcRoutine.default_day()
	engine.consequence = cohort.consequence
	if engine.chore_board == null:
		engine.chore_board = NpcChoreBoard.create_empty()
	engine._validate_assignments()
	return engine


static func _seed_key_of(engine: NpcPopulationEngine) -> String:
	if engine.agents.is_empty():
		return "camp"
	var id := str((engine.agents[0] as NpcAgent).id)
	var at := id.rfind("_npc_")
	return id.substr(0, at) if at > 0 else id
