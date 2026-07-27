class_name NpcPopulationEngine
extends RefCounted

## Sim core for one habitat's population of individual NPC agents. Pure logic
## (no scene access): the caller supplies the SpaceRegistry, a space-position
## resolver Callable, and the hour-of-day each tick. Outputs aggregate
## consumption rates {resource kind: qty per sim-hour} for the flow engine's
## habitat demand override — so mass movement stays rate-based and exact at
## any time scale.
##
## Time handling mirrors the flow engine:
##  - forward tick: agents step by dt_hours (internally sub-stepped so the
##    FSM stays sane across coarse ticks)
##  - backward scrub: FREEZE (skip entirely, demand zero) — the
##    _refresh_hydro_telemetry_readonly pattern; agents are not reversible
##  - large forward jump (> CATCHUP_JUMP_H in one tick): coarse catch-up —
##    analytic need settling + agents re-plan from IDLE; no retro-integration
##    of consumption across the gap (documented v1 coarseness)

signal agent_departed(agent_id: String, display_name: String, reason: String)
signal collapse_warning(risk: float)
signal colony_collapsed()

const CATCHUP_JUMP_H := 6.0
const MAX_SUBSTEP_H := 0.1        # FSM/decay granularity within one coarse tick
const MAX_SUBSTEPS := 24          # cap work per tick; beyond -> catch-up path
const SPAWN_RING_M := 12.0

## Collapse: the roster falling below this share of its starting size is the
## point of no return. It is a NARRATIVE failure, not a game over — the site
## keeps running and can be rebuilt.
const COLLAPSE_FLOOR_FRAC := 0.35
const COLLAPSE_WARN_RISK := 0.5

var agents: Array = []            # of NpcAgent
var chore_board: NpcChoreBoard = null
var _last_abs_h := NAN
var _starved: Dictionary = {}     # resource kind -> true (from last flow tick)
var _initial_roster := 0
var _departures: Array = []       # [{id, name, reason, abs_h}]
var _collapse_warned := false
var _collapsed := false
var _weather: Dictionary = {}


## Deterministic roster: `seed_key` (e.g. the habitat item id) + index name
## the agents; spawn positions ring around `home`.
func configure(count: int, seed_key: String, home: Vector2) -> void:
	count = clampi(count, 1, 200)
	agents = []
	for i in count:
		var aid := "%s_npc_%d" % [seed_key, i]
		var ang := TAU * float(i) / float(count)
		var spawn := home + Vector2(cos(ang), sin(ang)) * SPAWN_RING_M * (0.5 + 0.5 * float(i % 3))
		agents.append(NpcAgent.make(aid, spawn))
	_last_abs_h = NAN
	_initial_roster = count
	_departures = []
	_collapse_warned = false
	_collapsed = false
	if chore_board == null:
		chore_board = NpcChoreBoard.create_empty()


func set_starved(kinds: Array) -> void:
	_starved = {}
	for k in kinds:
		_starved[str(k)] = true


func set_weather(w: Dictionary) -> void:
	_weather = w


## Advance to abs_hours; returns aggregate demand {kind: qty/h}.
## ctx_in: {registry: SpaceRegistry, pos_of: Callable, hour_of_day: float}
func tick(abs_hours: float, ctx_in: Dictionary) -> Dictionary:
	if agents.is_empty():
		return {}
	if is_nan(_last_abs_h):
		_last_abs_h = abs_hours
		return {}
	var dt := abs_hours - _last_abs_h
	if dt < 0.0:
		# Backward scrub: freeze — read-only elsewhere, no phantom demand.
		_last_abs_h = abs_hours
		return {}
	if dt == 0.0:
		return _sum_demand(_make_ctx(ctx_in))
	var ctx := _make_ctx(ctx_in)
	if dt > CATCHUP_JUMP_H:
		_catch_up(abs_hours, dt, ctx)
		_last_abs_h = abs_hours
		return _sum_demand(ctx)
	# Sub-step so need thresholds/activity durations resolve at sane
	# granularity even on coarse ticks (e.g. 450x realtime -> dt ~= 0.06 h).
	# Demand is TIME-AVERAGED over the substeps (rate x fraction of the tick
	# each agent actually spent consuming) so the flow engine — which
	# integrates this rate over the same dt — bills exactly the mass the
	# activities used, at any time scale. Billing the instantaneous end-of-
	# tick rate instead over-charged short activities ~2x at coarse dt.
	var steps := clampi(int(ceil(dt / MAX_SUBSTEP_H)), 1, MAX_SUBSTEPS)
	var sub := dt / float(steps)
	var w := 1.0 / float(steps)
	var t := _last_abs_h
	var demand: Dictionary = {}
	for i in steps:
		t += sub
		ctx["hour_of_day"] = fposmod(float(ctx_in.get("hour_of_day", 12.0)) - (abs_hours - t), 24.0)
		for a in agents:
			var agent: NpcAgent = a
			ctx["assigned_chore_h"] = _assigned_hours_for(agent.id, t)
			var c: Dictionary = agent.step(t, sub, ctx)
			for kind in c:
				demand[kind] = float(demand.get(kind, 0.0)) + float(c[kind]) * w
	_process_departures(abs_hours, ctx)
	_last_abs_h = abs_hours
	return demand


func _assigned_hours_for(agent_id: String, abs_h: float) -> float:
	if chore_board == null:
		return 0.0
	return chore_board.assigned_hours_for(agent_id, abs_h) \
			+ chore_board.shared_hours_per_agent(agents.size(), abs_h)


## Anyone whose quit pressure has run out walks. Departures shrink the labour
## pool AND demoralise everyone still here — that second-order term is what
## turns a bad week into a collapse rather than a soft landing.
func _process_departures(abs_hours: float, ctx: Dictionary) -> void:
	var leaving: Array = []
	for a in agents:
		if NpcMorale.wants_to_leave((a as NpcAgent).quit_pressure):
			leaving.append(a)
	if leaving.is_empty():
		return
	for a in leaving:
		var agent: NpcAgent = a
		agent.release_claims(ctx)
		agents.erase(agent)
		_departures.append({
			"id": agent.id, "name": agent.display_name,
			"reason": _departure_reason(agent), "abs_h": abs_hours,
		})
		agent_departed.emit(agent.id, agent.display_name, _departure_reason(agent))
	# Contagion: watching people leave is demoralising, scaled by how big a
	# share of the community just walked out.
	var share := float(leaving.size()) / maxf(float(agents.size() + leaving.size()), 1.0)
	var shock := NpcMorale.DEPARTURE_SHOCK * share * float(leaving.size())
	for a in agents:
		var rest: NpcAgent = a
		rest.morale = clampf(rest.morale - shock, 0.0, 1.0)
	_check_collapse()


## What finally drove them out — the worst blocked critical need, else the
## worst unmet one.
static func _departure_reason(agent: NpcAgent) -> String:
	var worst := ""
	var worst_v := -1.0
	for n in NpcAgent.CRITICAL_NEEDS:
		var v := float(agent.needs.get(n, 0.0))
		if agent.is_blocked(n):
			v += 1.0   # blocked needs are the real cause
		if v > worst_v:
			worst_v = v
			worst = n
	return worst


func _check_collapse() -> void:
	if _collapsed:
		return
	var risk := collapse_risk()
	if not _collapse_warned and risk >= COLLAPSE_WARN_RISK:
		_collapse_warned = true
		collapse_warning.emit(risk)
	if _initial_roster > 0 and agents.size() <= int(ceil(float(_initial_roster) * COLLAPSE_FLOOR_FRAC)):
		_collapsed = true
		colony_collapsed.emit()


## 0..1 — how close this community is to unwinding. Blends roster loss, mean
## morale, and how many critical channels are currently blocked.
func collapse_risk() -> float:
	if _initial_roster <= 0:
		return 0.0
	var lost := 1.0 - float(agents.size()) / float(_initial_roster)
	var roster_term := clampf(lost / maxf(1.0 - COLLAPSE_FLOOR_FRAC, 0.01), 0.0, 1.0)
	var morale_term := 1.0 - clampf(mean_morale() / NpcMorale.BASELINE_CEILING, 0.0, 1.0)
	var blocked_term := clampf(blocked_share(), 0.0, 1.0)
	return clampf(0.5 * roster_term + 0.3 * morale_term + 0.2 * blocked_term, 0.0, 1.0)


func mean_morale() -> float:
	if agents.is_empty():
		return 0.0
	var total := 0.0
	for a in agents:
		total += (a as NpcAgent).morale
	return total / float(agents.size())


## Share of the roster currently blocked on at least one critical need.
func blocked_share() -> float:
	if agents.is_empty():
		return 0.0
	var n := 0
	for a in agents:
		for need in NpcAgent.CRITICAL_NEEDS:
			if (a as NpcAgent).is_blocked(str(need)):
				n += 1
				break
	return float(n) / float(agents.size())


func departures() -> Array:
	return _departures.duplicate(true)


func has_collapsed() -> bool:
	return _collapsed


func _make_ctx(ctx_in: Dictionary) -> Dictionary:
	return {
		"registry": ctx_in.get("registry"),
		"pos_of": ctx_in.get("pos_of", Callable()),
		"chore_pos_of": ctx_in.get("chore_pos_of", Callable()),
		"hour_of_day": float(ctx_in.get("hour_of_day", 12.0)),
		"starved": _starved,
		"weather": ctx_in.get("weather", _weather),
		"board": chore_board,
		"assigned_chore_h": 0.0,
	}


## Sum of every agent's current consumption rates.
func _sum_demand(ctx: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for a in agents:
		var c: Dictionary = (a as NpcAgent).current_consumption(ctx)
		for kind in c:
			out[kind] = float(out.get(kind, 0.0)) + float(c[kind])
	return out


## Coarse catch-up across a big forward jump: abort in-flight activities,
## settle needs analytically (rise clamped at 1.0; sleeping pressure resolved
## if the gap crossed a night), and let agents re-plan from IDLE.
func _catch_up(abs_hours: float, dt: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	for item in agents:
		var a: NpcAgent = item
		if registry != null:
			registry.release_all_for_agent(a.id)
		a.state = NpcAgent.State.IDLE
		a.activity = ""
		a.target_space_id = ""
		a.retry_at = {}
		for n in NpcAgent.NEEDS:
			var rise := float(NpcAgent.RISE_PER_H[n]) * dt
			a.needs[n] = clampf(float(a.needs.get(n, 0.0)) + rise, 0.0, 1.0)
		if dt >= 16.0:
			# The gap contained a night: assume they slept.
			a.needs["sleep"] = a.rng.randf_range(0.05, 0.2)
		# Morale settles analytically over the gap (same pure function as the
		# per-step path), so a scrub forward can still produce departures.
		a.morale = NpcMorale.step(a.morale, dt, a.needs, a.blocked,
				float(a.needs.get("enrichment", 1.0)))
		a.quit_pressure = NpcMorale.step_quit_pressure(a.quit_pressure, a.morale, dt)
	if chore_board != null:
		for a2 in agents:
			chore_board.release_all_for_agent((a2 as NpcAgent).id)
	_process_departures(abs_hours, ctx)


# --- telemetry / UI ---------------------------------------------------------

## Aggregate view for the inspector: average + worst need levels, activity
## breakdown, blocked count.
func summary() -> Dictionary:
	var avg := {}
	var worst := {}
	var acts := {}
	var bands: Array = []
	bands.resize(NpcMorale.BANDS.size())
	bands.fill(0)
	for n in NpcAgent.NEEDS:
		avg[n] = 0.0
		worst[n] = 0.0
	var worst_morale := 1.0
	var blocked_counts := {}
	for item in agents:
		var a: NpcAgent = item
		for n in NpcAgent.NEEDS:
			var v := float(a.needs.get(n, 0.0))
			avg[n] += v
			worst[n] = maxf(float(worst[n]), v)
			if a.is_blocked(str(n)):
				blocked_counts[n] = int(blocked_counts.get(n, 0)) + 1
		var label := a.activity if a.state == NpcAgent.State.DOING else \
				("-> " + a.activity if a.state == NpcAgent.State.TRAVELING else "idle")
		acts[label] = int(acts.get(label, 0)) + 1
		bands[NpcMorale.band(a.morale)] = int(bands[NpcMorale.band(a.morale)]) + 1
		worst_morale = minf(worst_morale, a.morale)
	if not agents.is_empty():
		for n in NpcAgent.NEEDS:
			avg[n] = avg[n] / float(agents.size())
	var mean_m := mean_morale()
	return {
		"count": agents.size(),
		"initial_count": _initial_roster,
		"avg_needs": avg, "worst_needs": worst, "activities": acts,
		"mean_morale": mean_m,
		"worst_morale": worst_morale if not agents.is_empty() else 0.0,
		"morale_label": NpcMorale.label(mean_m),
		"morale_bands": bands,
		"blocked": blocked_counts,
		"blocked_share": blocked_share(),
		"collapse_risk": collapse_risk(),
		"collapsed": _collapsed,
		"departures": _departures.size(),
	}


## Dot-rendering payload (Site Plan): world XZ + per-agent color + activity.
func agent_dots() -> Array:
	var out: Array = []
	for item in agents:
		var a: NpcAgent = item
		out.append({
			"id": a.id,
			"name": a.display_name,
			"pos": a.pos,
			"color": color_for_agent(a.id),
			"morale": a.morale,
			"morale_color": NpcMorale.color(a.morale),
			"morale_label": NpcMorale.label(a.morale),
			"activity": a.activity,
			"state": a.state,
			"status": a.status_line(),
		})
	return out


## Golden-ratio hue spread -> stable distinct pastel per agent id (the
## RemotePlayerAvatar.color_for_peer idiom).
static func color_for_agent(agent_id: String) -> Color:
	var h := fposmod(float(hash(agent_id) % 1000) * 0.618033988749895, 1.0)
	return Color.from_hsv(h, 0.45, 0.95)


# --- persistence (change-gated by the caller) --------------------------------

func snapshot(saved_h: float) -> Dictionary:
	var arr: Array = []
	for a in agents:
		arr.append((a as NpcAgent).snapshot())
	var out := {
		"agents": arr,
		"saved_h": snappedf(saved_h, 1.0 / 60.0),
		"initial_roster": _initial_roster,
		"departures": _departures.duplicate(true),
		"collapsed": _collapsed,
	}
	if chore_board != null and not chore_board.chores.is_empty():
		out["chores"] = chore_board.serialize()
	return out


## Agents by id, for lookups from the 3D/interaction layer.
func find_agent(agent_id: String) -> NpcAgent:
	for a in agents:
		if (a as NpcAgent).id == agent_id:
			return a
	return null


func restore(snap: Dictionary) -> void:
	agents = []
	for item in snap.get("agents", []):
		if item is Dictionary:
			agents.append(NpcAgent.from_snapshot(item))
	_last_abs_h = NAN
	_initial_roster = int(snap.get("initial_roster", agents.size()))
	_departures = (snap.get("departures", []) as Array).duplicate(true)
	_collapsed = bool(snap.get("collapsed", false))
	_collapse_warned = _collapsed
	if chore_board == null:
		chore_board = NpcChoreBoard.create_empty()
	if snap.has("chores"):
		chore_board.deserialize(snap.get("chores", {}) as Dictionary)
