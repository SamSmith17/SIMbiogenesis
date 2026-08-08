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
## The roster hit zero. Separate from `colony_collapsed` (which fires while
## people remain) because it is the point where the sim stops producing any
## feedback at all — nothing moves, nothing consumes — and the player needs to
## be told rather than left wondering where everyone went.
signal colony_deserted(cause: String)
## Someone died of a critical shortage (the PERISH consequence only). A
## SEPARATE signal from agent_departed on purpose: challenge and bake code
## keys off departures, and a death must never be reported as a walk-out.
signal agent_lost(agent_id: String, display_name: String, reason: String)

## Separation is skipped above this tick length — see _separate.
const SEPARATION_MAX_DT_H := 0.1
## Cap on how far one tick of crowding may move anyone.
const MAX_PUSH_M := 0.25
## How much of a travelling agent's push is redirected sideways rather than
## along their route — 1.0 would be purely sideways.
const PERP_BIAS := 0.85

const CATCHUP_JUMP_H := 6.0
const MAX_SUBSTEP_H := 0.1        # FSM/decay granularity within one coarse tick
const MAX_SUBSTEPS := 24          # cap work per tick; beyond -> catch-up path
const SPAWN_RING_M := 12.0

## Collapse: the roster falling below this share of its starting size is the
## point of no return. It is a NARRATIVE failure, not a game over — the site
## keeps running and can be rebuilt.
const COLLAPSE_FLOOR_FRAC := 0.35
const COLLAPSE_WARN_RISK := 0.5
## Most morale a single coarse catch-up may move, in either direction.
const CATCHUP_MORALE_DRIFT := 0.12

var agents: Array = []            # of NpcAgent
var chore_board: NpcChoreBoard = null
## Who worked how much, per sim-day. Rides the snapshot, so it survives
## save/load — unlike NpcAgent's walking ledger, which does not.
var labour := NpcLabourLog.create_empty()
## The daily schedule everyone follows (per-agent phase offsets vary it).
## Editable by the player; defaults to NpcRoutine.default_day().
var routine: NpcRoutine = null
## Slot -> clip overrides authored in the Routines panel. Passed by REFERENCE
## on every dot, so 50 agents share one dictionary rather than 50 copies.
var anim_overrides: Dictionary = {}
var _last_abs_h := NAN
var _starved: Dictionary = {}     # resource kind -> true (from last flow tick)
var _initial_roster := 0
var _departures: Array = []       # [{id, name, reason, kind, abs_h}]
var _losses := 0                  # how many died (PERISH policy)
## What running out of a critical resource does to people. Player's choice,
## per habitat; see NpcConsequence. Default STRIKE == the shipped behaviour.
var consequence: String = NpcConsequence.DEFAULT
var _collapse_warned := false
var _collapsed := false
var _weather: Dictionary = {}
var _catchups := 0
var _max_dt := 0.0


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
	if routine == null:
		routine = NpcRoutine.default_day()


## Start this community over: a fresh roster at full morale, no departure
## history, no collapse. The one recovery path once everyone has walked out —
## an emptied roster CANNOT restart itself, because departures are permanent
## by design and there is no one left to have needs.
##
## Deliberately does not touch whatever drove them out. If the water tank is
## still empty the new arrivals will leave too, which is the correct outcome
## and the reason the UI names the cause next to the button.
func reset_roster(count: int, seed_key: String, home: Vector2) -> void:
	configure(count, seed_key, home)


## Has this community emptied out completely? Distinct from `collapsed`, which
## fires at COLLAPSE_FLOOR_FRAC and still leaves people on site.
func is_deserted() -> bool:
	return _initial_roster > 0 and agents.is_empty()


## The need that drove the most people away — what to fix before resetting.
func departure_cause() -> String:
	var tally: Dictionary = {}
	for d in _departures:
		var r := str((d as Dictionary).get("reason", ""))
		tally[r] = int(tally.get(r, 0)) + 1
	var best := ""
	var best_n := 0
	for k in tally:
		if int(tally[k]) > best_n:
			best_n = int(tally[k])
			best = str(k)
	return best


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
	_max_dt = maxf(_max_dt, dt)
	var ctx := _make_ctx(ctx_in)
	if dt > CATCHUP_JUMP_H:
		_catchups += 1
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
		ctx["abs_hours"] = t
		# WHO ASKS FIRST — least-worked first.
		#
		# _begin_chore takes options[0] and claims it, and this loop used to
		# run in fixed array order, so agent 0 got first refusal on every
		# chore every substep forever. That is a systematic bias, not merely
		# an absence of fairness, and no amount of tuning the board's
		# comparator fixes it — the comparator is per-CHORE and this is a
		# per-PERSON problem.
		#
		# A blind rotation was tried first and is not enough: with fine ticks
		# there is only one substep, so a day-keyed offset rotates once a day
		# and two scarce jobs still land on the same few people (measured
		# spread 1.23 over four days). Ordering by the labour ledger is both
		# simpler and actually purposeful: whoever is furthest behind gets
		# first refusal, which is exactly "equal rotation until everyone has
		# contributed the same". Deterministic — _fair_ranks is a total order
		# with an id tiebreak, never a RNG.
		var ranks := _fair_ranks(t)
		ctx["fair_ranks"] = ranks
		for agent in _ask_order(ranks):
			ctx["assigned_chore_h"] = _assigned_hours_for(agent.id, t)
			var c: Dictionary = agent.step(t, sub, ctx)
			for kind in c:
				demand[kind] = float(demand.get(kind, 0.0)) + float(c[kind]) * w
	_separate(dt, ctx)
	_process_consequences(abs_hours, ctx)
	_process_departures(abs_hours, ctx)
	_last_abs_h = abs_hours
	return demand


## Each agent's position in the roster sorted by trailing-week hours, fewest
## first. Rank 0 is whoever is furthest behind.
##
## Computed ONCE per substep and handed to every agent through ctx — one sort
## of at most 64 ids, rather than the same sort repeated per agent. Ties break
## on the id so the ordering is total and reproducible.
## The roster in ask order: rank 0 (furthest behind) first.
func _ask_order(ranks: Dictionary) -> Array:
	var out: Array = agents.duplicate()
	out.sort_custom(func(x, y) -> bool:
		return int(ranks.get((x as NpcAgent).id, 0)) 			< int(ranks.get((y as NpcAgent).id, 0)))
	return out


func _fair_ranks(abs_h: float) -> Dictionary:
	var day := NpcChoreBoard.day_index(abs_h)
	var ids: Array = []
	for a in agents:
		ids.append((a as NpcAgent).id)
	ids.sort_custom(func(x: String, y: String) -> bool:
		var hx := labour.week_hours(x, day)
		var hy := labour.week_hours(y, day)
		if absf(hx - hy) > 0.01:
			return hx < hy
		return x < y)
	var out: Dictionary = {}
	for i in ids.size():
		out[str(ids[i])] = i
	return out


func _assigned_hours_for(agent_id: String, abs_h: float) -> float:
	if chore_board == null:
		return 0.0
	return chore_board.assigned_hours_for(agent_id, abs_h) \
			+ chore_board.shared_hours_per_agent(agents.size(), abs_h)


## Anyone whose quit pressure has run out walks. Departures shrink the labour
## pool AND demoralise everyone still here — that second-order term is what
## turns a bad week into a collapse rather than a soft landing.
func _process_departures(abs_hours: float, ctx: Dictionary) -> void:
	# Under PERISH the shortage kills people before it drives them away, and
	# the ordinary morale exit fires at ~24 h against a 72 h thirst window —
	# so leaving BOTH paths live would mean the policy the player chose could
	# never actually fire. Choosing "perish" is choosing this instead.
	if NpcConsequence.normalize(consequence) == NpcConsequence.PERISH:
		return
	var leaving: Array = []
	for a in agents:
		# Someone a player is currently inhabiting cannot rage-quit — the body
		# would vanish mid-step and the possession binding would dangle. Their
		# quit pressure keeps accruing, so they leave the moment they are
		# released, which keeps the consequence rather than cancelling it.
		if (a as NpcAgent).controlled_by_peer != 0:
			continue
		if NpcMorale.wants_to_leave((a as NpcAgent).quit_pressure):
			leaving.append(a)
	if leaving.is_empty():
		return
	_remove_agents(leaving, "left", abs_hours, ctx)


## Take people off the roster, for whatever reason, and apply everything that
## follows from it. Factored out of _process_departures so LOSSES (the PERISH
## consequence) reuse the ENTIRE cascade — record, signal, contagion, collapse
## check, desertion — rather than growing a parallel path that would drift
## from it. `kind` is "left" or "lost"; they emit DIFFERENT signals because
## challenge code keys off departures and must not read a death as a walk-out.
func _remove_agents(gone: Array, kind: String, abs_hours: float,
		ctx: Dictionary, reason_override: String = "") -> void:
	if gone.is_empty():
		return
	for a in gone:
		var agent: NpcAgent = a
		agent.release_claims(ctx)
		agents.erase(agent)
		var why := reason_override if not reason_override.is_empty() 			else _departure_reason(agent)
		_departures.append({
			"id": agent.id, "name": agent.display_name,
			"reason": why, "kind": kind, "abs_h": abs_hours,
		})
		if kind == "lost":
			_losses += 1
			agent_lost.emit(agent.id, agent.display_name, why)
		else:
			agent_departed.emit(agent.id, agent.display_name, why)
	# Contagion: watching people go is demoralising, scaled by how big a
	# share of the community just went.
	var share := float(gone.size()) / maxf(float(agents.size() + gone.size()), 1.0)
	var shock := NpcMorale.DEPARTURE_SHOCK * share * float(gone.size())
	for a in agents:
		var rest: NpcAgent = a
		rest.morale = clampf(rest.morale - shock, 0.0, 1.0)
	_check_collapse()
	# The last person going is the moment the sim goes silent — no movement,
	# no consumption, no further events. Announce it explicitly rather than
	# letting the world quietly empty.
	if agents.is_empty():
		colony_deserted.emit(departure_cause())


## The player's chosen consequence for running out of a critical resource.
## STRIKE (the default, and what already shipped) needs no code here at all:
## the absorbing tier-1 wait IS the strike.
func _process_consequences(abs_hours: float, ctx: Dictionary) -> void:
	var policy := NpcConsequence.normalize(consequence)
	if policy == NpcConsequence.STRIKE:
		return
	var gone: Array = []
	var why := ""
	for a in agents:
		var agent: NpcAgent = a
		if agent.controlled_by_peer != 0:
			continue   # same rule as departures: a possessed body cannot vanish
		for n in NpcAgent.CRITICAL_NEEDS:
			var h := agent.blocked_hours(str(n), abs_hours)
			if h <= 0.0 or not NpcConsequence.triggers(policy, str(n), h):
				continue
			if policy == NpcConsequence.LEAVE:
				# Route through the ONE existing exit rather than a second
				# removal path: push quit pressure over the line and let
				# _process_departures do everything it already does.
				agent.quit_pressure = maxf(agent.quit_pressure, NpcMorale.QUIT_PRESSURE_H)
			else:
				gone.append(agent)
				why = NpcConsequence.reason_for(policy, str(n))
			break
	_remove_agents(gone, "lost", abs_hours, ctx, why)


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


## Bank one credit against the person who earned it. The day index comes from
## the engine's own clock rather than the caller, so every agent in a substep
## banks to the same day whatever order they ticked in.
func _bank_labour(agent_id: String, hours: float, category: String) -> void:
	if is_nan(_last_abs_h):
		return
	labour.bank(agent_id, NpcChoreBoard.day_index(_last_abs_h), hours, category)


func _make_ctx(ctx_in: Dictionary) -> Dictionary:
	# NOTE: this rebuilds the dict rather than mutating the caller's, so every
	# key the agents need must be forwarded explicitly. Forgetting one fails
	# silently — `plan_path` was dropped here once and agents just kept
	# walking straight lines with a perfectly good nav grid sitting idle.
	return {
		"registry": ctx_in.get("registry"),
		"pos_of": ctx_in.get("pos_of", Callable()),
		"chore_pos_of": ctx_in.get("chore_pos_of", Callable()),
		"plan_path": ctx_in.get("plan_path", Callable()),
		"height_at": ctx_in.get("height_at", Callable()),
		"walkable": ctx_in.get("walkable", Callable()),
		"routine": routine,
		"trace": ctx_in.get("trace", Callable()),
		"hour_of_day": float(ctx_in.get("hour_of_day", 12.0)),
		"starved": _starved,
		"weather": ctx_in.get("weather", _weather),
		"board": chore_board,
		"assigned_chore_h": 0.0,
		# Refreshed per substep below, alongside hour_of_day. NpcAgent._walk
		# stamps every live-trail point with this, and it was never forwarded
		# — so every stamp read 0.0 and trim_trail dropped the whole trail on
		# the next step. Exactly the silent-omission failure this function's
		# header warns about, found when the fair-share rotation changed which
		# agent happened to end a run mid-stride.
		"abs_hours": _last_abs_h,
		# Per-agent labour banking. It belongs HERE and not in the bridge's
		# ctx for exactly the reason the note above gives: this function
		# rebuilds the dict from scratch, and a key added anywhere else
		# never arrives.
		"bank_labour": _bank_labour,
		"roster_size": agents.size(),
	}


## Push apart anyone standing inside someone else. Standing slots
## (SpaceRegistry.slot_offset) handle people who have ARRIVED somewhere; this
## handles the rest — corridors converging, two routes crossing, a queue
## forming outside a full space.
##
## Strictly cosmetic: it moves positions only, never state, and the displacement
## is deliberately NOT banked into the walking/kcal ledger. Folding it in would
## make the spatial-efficiency numbers depend on how crowded the site is, which
## defeats the point of measuring layouts.
func _separate(dt: float, ctx: Dictionary) -> void:
	# Above this the agents teleport (one tick covers the whole remaining
	# distance), so their exact position is already an approximation and
	# nudging it is noise on top of noise.
	if dt > SEPARATION_MAX_DT_H or agents.size() < 2:
		return
	var walkable: Callable = ctx.get("walkable", Callable())
	var gap := SpaceRegistry.PERSONAL_SPACE_M
	# O(n^2) on purpose: the roster caps at 64, so this is at most ~2k pairs of
	# vector math per tick. A spatial hash would be faster in principle and
	# would also introduce bucket-ordering questions that the determinism
	# guarantee then has to answer.
	var push: Array[Vector2] = []
	push.resize(agents.size())
	push.fill(Vector2.ZERO)
	for i in range(agents.size()):
		var a: NpcAgent = agents[i]
		for j in range(i + 1, agents.size()):
			var b: NpcAgent = agents[j]
			var d := b.pos - a.pos
			var dist := d.length()
			if dist >= gap:
				continue
			var n: Vector2
			if dist > 0.0001:
				n = d / dist
			else:
				# Exactly coincident (a fresh roster spawns everyone on one
				# point). Derive a direction from the ids so the split is
				# deterministic instead of arbitrary.
				var ang := NpcHash.unit01(a.id + b.id, "split") * TAU
				n = Vector2(cos(ang), sin(ang))
				dist = 0.0
			var half := (gap - dist) * 0.5
			push[i] -= n * half
			push[j] += n * half
	for i in range(agents.size()):
		var p := push[i]
		if p == Vector2.ZERO:
			continue
		var agent: NpcAgent = agents[i]
		# A possessed person PUSHES others but is never pushed: their position
		# is authored by a remote player's input, and quietly moving it would
		# fight that input every tick.
		if agent.controlled_by_peer != 0:
			continue
		# Bias the push SIDEWAYS for anyone under way. Shoving someone straight
		# back down their own route reads as barging and, worse, feeds back into
		# arrival time; sliding them past each other is both what people do and
		# nearly free of any effect on when they get there.
		if agent.state == NpcAgent.State.TRAVELING:
			var travel := agent.target_pos - agent.pos
			if travel.length() > 0.001:
				var fwd := travel.normalized()
				var perp := p - fwd * p.dot(fwd)
				p = p.lerp(perp, PERP_BIAS)
		if p.length() > MAX_PUSH_M:
			p = p.normalized() * MAX_PUSH_M
		var dest := agent.pos + p
		# Never let crowding squeeze someone through a wall or off a ledge.
		if walkable.is_valid() and not bool(walkable.call(dest)):
			continue
		agent.pos = dest


## Sum of every agent's current consumption rates.
func _sum_demand(ctx: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for a in agents:
		var c: Dictionary = (a as NpcAgent).current_consumption(ctx)
		for kind in c:
			out[kind] = float(out.get(kind, 0.0)) + float(c[kind])
	return out


## Does satisfying `need` depend on a resource that is currently starved?
func _need_is_starved(need: String) -> bool:
	var act: Dictionary = NpcAgent.ACTIVITIES.get(need, {})
	for kind in (act.get("consumes", {}) as Dictionary):
		if _starved.get(kind, false):
			return true
	return false


## Coarse catch-up across a big forward jump (a timeline scrub, or a frame
## hitch). Abort in-flight activities and resume from a PLAUSIBLE state.
##
## The model matters: a skipped span is time the community LIVED THROUGH but
## the sim did not simulate, so it is assumed to have been coped with —
## needs land at ordinary mid-day levels rather than pinned, morale drifts
## gently, and quit pressure bleeds off. Treating the gap as total neglect
## instead (needs clamped to 1.0, morale integrated over the whole span)
## meant a single 12.8 h jump emptied a perfectly healthy camp — morale 0.75,
## nothing blocked — in one tick.
##
## This hides nothing real: if supply is genuinely broken, the very next
## simulated ticks block the activities and the cascade starts properly.
func _catch_up(abs_hours: float, dt: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	for item in agents:
		var a: NpcAgent = item
		# A possessed person did not "live through" the skipped span the way an
		# NPC did — a human is driving them right now. Resetting their state and
		# rerolling their needs mid-possession would yank the body out from
		# under the player.
		if a.controlled_by_peer != 0:
			continue
		if registry != null:
			registry.release_all_for_agent(a.id)
		a.state = NpcAgent.State.IDLE
		a.activity = ""
		a.target_space_id = ""
		a.retry_at = {}
		a._clear_path()
		# Where they were looking is as invalid as where they were walking.
		a.face_anchor = Vector2.INF
		# The skipped span is a discontinuity — a trail bridging it would paint
		# a walk that never happened.
		a.clear_trail()
		for n in NpcAgent.NEEDS:
			# "Coped" means coped WITH WHAT WAS THERE. A need whose supply is
			# currently starved cannot have been met during the skipped span,
			# so it keeps rising — otherwise a jump would quietly feed a camp
			# whose food tank is empty.
			if _need_is_starved(str(n)):
				a.needs[n] = clampf(float(a.needs.get(n, 0.0))
						+ float(NpcAgent.RISE_PER_H[n]) * dt, 0.0, 1.0)
			else:
				a.needs[n] = a.rng.randf_range(0.15, 0.55)
		if dt >= 16.0 and not _need_is_starved("sleep"):
			a.needs["sleep"] = a.rng.randf_range(0.05, 0.2)
		# Enrichment is not "coped with" — it is earned by gathering, and no
		# gathering was simulated.
		a.needs["enrichment"] = clampf(
				float(a.needs.get("enrichment", 1.0))
					+ float(NpcAgent.RISE_PER_H["enrichment"]) * dt, 0.0, 1.0)
		# Morale eases toward whatever the (now moderate) needs support,
		# capped so a long skip neither rescues nor destroys a community.
		var settled := NpcMorale.step(a.morale, minf(dt, 2.0), a.needs, {},
				float(a.needs.get("enrichment", 1.0)))
		a.morale = clampf(settled, a.morale - CATCHUP_MORALE_DRIFT,
				a.morale + CATCHUP_MORALE_DRIFT)
		a.quit_pressure = maxf(a.quit_pressure - NpcMorale.QUIT_DECAY_PER_H * dt, 0.0)
	if chore_board != null:
		for a2 in agents:
			chore_board.release_all_for_agent((a2 as NpcAgent).id)
	_process_consequences(abs_hours, ctx)
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
	# Walking ledger: what this layout costs the people living in it.
	var dist := 0.0
	var climb := 0.0
	var kcal := 0.0
	var per_need: Dictionary = {}
	var per_need_trips: Dictionary = {}
	for item2 in agents:
		var a2: NpcAgent = item2
		dist += a2.distance_m
		climb += a2.climb_m
		kcal += a2.walk_kcal
		for k in a2.need_distance:
			per_need[k] = float(per_need.get(k, 0.0)) + float(a2.need_distance[k])
			per_need_trips[k] = int(per_need_trips.get(k, 0)) 					+ int(a2.need_trips.get(k, 0))
	var n := maxf(float(agents.size()), 1.0)
	# Mean metres walked per COMPLETED trip, split by need — the diagnostic
	# that points at which space is misplaced rather than just saying the
	# layout is bad.
	var need_mean: Dictionary = {}
	for k in per_need:
		var trips := int(per_need_trips.get(k, 0))
		if trips > 0:
			need_mean[k] = float(per_need[k]) / float(trips)
	var mean_m := mean_morale()
	return {
		"walk_distance_m": dist / n,
		"walk_climb_m": climb / n,
		"walk_kcal": kcal / n,
		"walk_overhead": NpcMetabolism.overhead_fraction(kcal / n),
		"walk_label": NpcMetabolism.efficiency_label(kcal / n),
		"need_mean_m": need_mean,
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
		"deserted": is_deserted(),
		"departure_cause": departure_cause(),
		"departures": _departures.size(),
		"losses": _losses,
		"consequence": consequence,
		"catchups": _catchups,
		"max_dt": _max_dt,
	}


## Dot-rendering payload (Site Plan): world XZ + per-agent color + activity.
func agent_dots() -> Array:
	var out: Array = []
	for item in agents:
		var a: NpcAgent = item
		# Mid-haul carry: the renderers hide the real crate and show a box on
		# the body. carry_prop is resolved HERE (board target, kind "prop")
		# so the hosts stay dumb consumers of the dot payload.
		var carrying := a.is_carrying()
		var carry_prop := ""
		if carrying and chore_board != null:
			var tgt: Dictionary = (chore_board.find(a.chore_id) as Dictionary).get("target", {})
			if str(tgt.get("kind", "")) == "prop":
				carry_prop = str(tgt.get("id", ""))
		elif not carrying and a.state == NpcAgent.State.DOING \
				and not a.chore_id.is_empty() and chore_board != null:
			# Brigade station worker: standing a post on the relay line with
			# crates flowing through their hands — reads as carrying (box in
			# a hold pose), but no single crate is theirs to hide.
			var haul: Dictionary = (chore_board.find(a.chore_id) as Dictionary).get("haul", {})
			carrying = str(haul.get("strategy", "")) == "brigade"
		out.append({
			"id": a.id,
			"name": a.display_name,
			"pos": a.pos,
			"carrying": carrying,
			# WHICH work, as a pose family. Classified here because the board and
			# chore_id are already in hand; the host forwards it and the pose
			# machine reads it as an INPUT, which is what keeps the machine pure.
			"work_pose": NpcWorkPose.family_for(chore_board.find(a.chore_id))
				if (chore_board != null and not a.chore_id.is_empty()) else "",
			"carry_prop": carry_prop,
			"color": color_for_agent(a.id),
			"morale": a.morale,
			"morale_color": NpcMorale.color(a.morale),
			"morale_label": NpcMorale.label(a.morale),
			"activity": a.activity,
			"state": a.state,
			# Which enrichment space they went to, so the 3D layer can tell a
			# yoga block from a fire circle. Already tracked per agent; it was
			# simply never exposed.
			"space_type": a.target_space_type,
			"anim_map": anim_overrides,
			# When the current activity ends, in absolute sim-hours. The 3D
			# layer converts to wall-clock with the live time scale to decide
			# whether there is time to animate sitting down at all.
			"ends_h": a.activity_ends_h,
			"status": a.status_line(),
			"trail": a.trail,
			# Multiplayer possession. `yaw` is the driving player's own look
			# direction, published in their presence packet — a person can look
			# where they like while walking, so it must not be derived from the
			# direction of travel the way an NPC's is.
			"possessed": a.controlled_by_peer != 0,
			"yaw": float(a.get_meta("possessed_yaw", 0.0)),
			# Which way a STATIONARY person is turned. Derived here, on the
			# same cadence as the position, because it has to be recomputed
			# from the FINAL position: _separate spreads an arrived crowd by
			# increments the host's own travel-delta test can never see, and
			# re-deriving is precisely what turns that positional spread into
			# a spread of FACINGS. A travelling agent ignores it — the host
			# uses its rendered heading, the only thing that agrees with its
			# own smoothing.
			"face_yaw": NpcFacing.yaw_for(a.pos, a.face_anchor,
				a.face_phase, _last_abs_h),
		})
	return out


## Golden-ratio hue spread -> stable distinct pastel per agent id (the
## RemotePlayerAvatar.color_for_peer idiom). The single choke-point both the
## 2D Site Plan dots and the 3D avatars read tint from (via agent_dots()), so
## gating the "show tint colors" player pref here — instead of in each
## renderer — covers both for free.
static func color_for_agent(agent_id: String) -> Color:
	if not NpcDisplayPrefs.colors_enabled():
		return Color.BLACK
	var h := fposmod(float(hash(agent_id) % 1000) * 0.618033988749895, 1.0)
	return Color.from_hsv(h, 0.45, 0.95)


# --- persistence (change-gated by the caller) --------------------------------

func snapshot(saved_h: float) -> Dictionary:
	var arr: Array = []
	for a in agents:
		arr.append((a as NpcAgent).snapshot())
	# `saved_h` is written but deliberately NOT read back by restore(), which is
	# why restore() sets _last_abs_h = NAN instead. Using it to derive "how much
	# sim time passed while this was saved" and integrating that gap is exactly
	# the behaviour the design forbids — a restored roster must not be billed
	# for time it did not live through (see the coarse-catch-up rules in
	# POPULATION_PLAN.md). It is kept purely as provenance: when a save behaves
	# oddly, knowing WHEN the snapshot was taken is the first thing you want.
	var out := {
		"agents": arr,
		"saved_h": snappedf(saved_h, 1.0 / 60.0),
		"initial_roster": _initial_roster,
		"departures": _departures.duplicate(true),
		"collapsed": _collapsed,
		"losses": _losses,
	}
	if chore_board != null and not chore_board.chores.is_empty():
		out["chores"] = chore_board.serialize()
	if not labour.days.is_empty():
		out["labour"] = labour.serialize()
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
	_losses = int(snap.get("losses", 0))
	_initial_roster = int(snap.get("initial_roster", agents.size()))
	_departures = (snap.get("departures", []) as Array).duplicate(true)
	_collapsed = bool(snap.get("collapsed", false))
	_collapse_warned = _collapsed
	if chore_board == null:
		chore_board = NpcChoreBoard.create_empty()
	if routine == null:
		routine = NpcRoutine.default_day()
	if snap.has("chores"):
		chore_board.deserialize(snap.get("chores", {}) as Dictionary)
	labour = NpcLabourLog.deserialize(snap.get("labour", {}) as Dictionary)
