class_name NpcAgent
extends RefCounted

## One simulated person: need levels (0..1, 1 = desperate), a tiny activity
## FSM (IDLE -> TRAVELING -> DOING), and a world-XZ position. Pure logic —
## no scene access; the world reaches the agent only through the `ctx`
## dictionary passed to step() (registry, position resolver, starved kinds,
## hour of day). Deterministic: the per-agent RNG is reseeded per sim-day
## from the agent id + day index, so identical tick sequences reproduce
## identical behavior (project convention: sims seed from absolute time).
##
## Daily-consumption calibration (WHO domestic-use 50-100 L/person/day + FAO
## intake; the habitat preset's ~50 L / 1.5 kg is the no-shower floor):
##   eat    3x/day x 0.5 h  x (food 1.0 kg/h + water 8 L/h)  = 1.5 kg + 12 L
##   drink  ~8x/day x 0.1 h x water 7.5 L/h                  = ~6 L
##   toilet ~5x/day x 0.15 h x water 40 L/h (flush/wash)     = ~30 L
##   shower ~1x/day x 0.2 h  x water 60 L/h (navy shower)    = ~12 L
## Totals ~60 L water, 1.5 kg food/day.

enum State { IDLE, TRAVELING, DOING }

const NEEDS: Array = ["hunger", "thirst", "bladder", "sleep", "hygiene", "enrichment"]

## Survival needs. These always preempt chores and enrichment (design
## invariant #1) and are the only needs that damage morale directly.
const CRITICAL_NEEDS: Array = ["hunger", "thirst", "bladder", "sleep"]

## Need rise per sim-hour while awake.
const RISE_PER_H: Dictionary = {
	"hunger": 1.0 / 16.0,   # 3 meals over a 16 h waking day
	"thirst": 1.0 / 5.0,
	"bladder": 1.0 / 4.0,
	"sleep": 1.0 / 16.0,
	"hygiene": 1.0 / 20.0,  # ~1 wash per waking day
	"enrichment": 1.0 / 30.0,
}

## Act when the need crosses its threshold; higher urgency wins (see _pick).
const THRESHOLD: Dictionary = {
	"hunger": 0.55,
	"thirst": 0.5,
	"bladder": 0.6,
	"sleep": 0.9,   # normally schedule-gated; 0.9 forces a nap anywhere in the day
	"hygiene": 0.7, # least urgent — skipped happily when water is short
	"enrichment": 0.3,  # low bar, but gated on free time + quiet critical needs
}

## What satisfying each need looks like: where, how long, what it consumes
## (qty per sim-hour while the activity runs — the engine turns these into
## graph tank draws).
const ACTIVITIES: Dictionary = {
	"hunger": {"space": "kitchen", "duration_h": 0.5, "consumes": {"food": 1.0, "water": 8.0}},
	"thirst": {"space": "water_point", "duration_h": 0.1, "consumes": {"water": 7.5}},
	"bladder": {"space": "restroom", "duration_h": 0.15, "consumes": {"water": 40.0}},
	"sleep": {"space": "sleep", "duration_h": -1.0, "consumes": {}},  # -1 = until wake hour
	"hygiene": {"space": "shower", "duration_h": 0.2, "consumes": {"water": 60.0}},
	# Enrichment resolves to whichever enrichment space wins the social/
	# distance score — the space type is chosen per visit, not fixed here.
	"enrichment": {"space": "fire_circle", "duration_h": 1.0, "consumes": {}},
}

## The work activity is not need-driven — it comes off the chore board.
const CHORE_ACTIVITY := "chore"

## A fire circle actually burns fuel: joy has a real cost the player must plan
## for (kg of biomass per sim-hour of gathering, per person).
const FIRE_BIOMASS_KG_H := 0.6

## Enrichment spaces score on company as well as distance, so people drift
## toward the fire that already has people at it. This is the cheapest
## emergent-behaviour win in the whole system.
const SOCIAL_PULL_M := 45.0        # metres of detour one companion is worth
const SOCIAL_PULL_CAP := 6

const SLEEP_START_H := 21.0        # eligible to head to bed from 21:00
const SLEEP_END_H := 6.0           # wake target (plus per-agent jitter)
const SLEEP_RECOVER_PER_H := 1.0 / 8.0
const URGENT := 0.95               # a need this high interrupts the current plan
const RETRY_BACKOFF_H := 0.25      # blocked (no space / starved) -> retry after
const DRINK_BLADDER_KICK := 0.12   # drinking nudges the bladder
## Below this much room in the day, nobody has the appetite for enrichment.
const ENRICHMENT_MIN_FREE_H := 1.5

var id: String = ""
var display_name: String = ""
var pos: Vector2 = Vector2.ZERO
var needs: Dictionary = {}
var state: int = State.IDLE
var activity: String = ""          # need id or CHORE_ACTIVITY ("" when idle)
var target_space_id: String = ""
var target_space_type: String = "" # enrichment picks its type per visit
var target_pos: Vector2 = Vector2.ZERO
var activity_ends_h: float = 0.0
## Per-tier backoff after a failed attempt (need id / CHORE_ACTIVITY /
## "enrichment" -> earliest abs-hour to retry). Deliberately NOT a single
## scalar: a failed enrichment attempt must never stop someone re-evaluating
## whether they are thirsty.
var retry_at: Dictionary = {}
var morale: float = NpcMorale.START_MORALE
var quit_pressure: float = 0.0
## Needs this person currently CANNOT act on (no tagged space, all full, or
## the supply is starved). Blocked needs hurt morale ~2x — broken
## infrastructure is what breaks a community, not busy people.
var blocked: Dictionary = {}
## Space this agent is currently standing at ("" when out in the open) — the
## cache key for the next trip.
var at_space_id: String = ""
## Planned route to target_pos (empty = walk straight, the pre-3b fallback).
var path := PackedVector2Array()
var path_idx := 0
## Walking ledger for the current sim-day (Tier 3d). Rolled into
## `prev_day` at the day boundary so yesterday stays comparable.
var distance_m := 0.0
var climb_m := 0.0
var walk_kcal := 0.0
var trip_distance_m := 0.0          # since the current trip started
var need_distance: Dictionary = {}  # need -> metres walked to satisfy it
var need_trips: Dictionary = {}     # need -> completed trips
var prev_day: Dictionary = {}
var chore_id: String = ""          # chore being worked (CHORE_ACTIVITY only)
var last_exposure: String = NpcWeatherGate.EXPOSURE_INDOOR
var rng := RandomNumberGenerator.new()
var _rng_day: int = -0x7fffffff


## Deterministic first names so a person is recognisable across sessions —
## the roster reads as a community, not "npc_7". Gender-neutral / unisex so no
## assumption is implied by the figure.
const NAME_POOL: Array = [
	"Ari", "Bex", "Cass", "Dane", "Eli", "Fen", "Gale", "Harp", "Indie", "Jules",
	"Kit", "Lark", "Marlo", "Nico", "Onyx", "Pax", "Quinn", "Reese", "Sage", "Tam",
	"Uma", "Vale", "Wren", "Xan", "Yuki", "Zephy", "Ash", "Blue", "Cy", "Devi",
	"Echo", "Flint", "Gray", "Hollis", "Isa", "Juno", "Koa", "Lux", "Moss", "Nova",
	"Orin", "Pip", "Rain", "Sol", "Tobi", "Vesper", "Wilder", "Ziggy",
]

## Name + a numeric suffix only when the pool wraps, so a big roster stays
## unique and readable.
static func name_for(agent_id: String) -> String:
	var h := absi(hash(agent_id))
	var base := str(NAME_POOL[h % NAME_POOL.size()])
	var wrap := (h / NAME_POOL.size()) % 97
	return base if wrap == 0 else "%s %d" % [base, wrap + 1]


static func make(agent_id: String, spawn: Vector2) -> NpcAgent:
	var a := NpcAgent.new()
	a.id = agent_id
	a.display_name = name_for(agent_id)
	a.pos = spawn
	# Stagger initial needs deterministically so 50 agents don't all eat at
	# the same instant on day one.
	var r := RandomNumberGenerator.new()
	r.seed = hash(agent_id)
	for n in NEEDS:
		a.needs[n] = r.randf_range(0.05, 0.45)
	# A community that has not gathered yet has earned nothing: start fully
	# un-enriched so the morale ceiling begins at BASELINE_CEILING.
	a.needs["enrichment"] = 1.0
	return a


## Advance the agent by dt_hours ending at abs_hours. `ctx` keys:
##   registry: SpaceRegistry      pos_of: Callable(space)->Variant (Vector2|null)
##   hour_of_day: float           starved: Dictionary (resource kind -> true)
##   weather: Dictionary          board: NpcChoreBoard (optional)
##   chore_pos_of: Callable(chore)->Variant (optional)
##   abs_hours: float
## Returns the agent's consumption {kind: qty/h} AVERAGED over this step —
## rate × (fraction of the step actually spent doing the activity) — so a
## caller integrating the returned rate over dt_hours bills exactly the mass
## the activity used, regardless of how coarse the step is.
func step(abs_hours: float, dt_hours: float, ctx: Dictionary) -> Dictionary:
	_reseed_for_day(abs_hours)
	_decay(dt_hours)
	var out: Dictionary = {}
	match state:
		State.DOING:
			out = _step_doing(abs_hours, dt_hours, ctx)
		State.TRAVELING:
			out = _step_traveling(abs_hours, dt_hours, ctx)
		State.IDLE:
			_step_idle(abs_hours, ctx)
	_update_morale(dt_hours, ctx)
	return out


## Morale + quit pressure. Runs AFTER the activity step so this tick's block
## state is already known.
func _update_morale(dt_hours: float, ctx: Dictionary) -> void:
	var exposure := 0.0
	if state == State.DOING and last_exposure != NpcWeatherGate.EXPOSURE_INDOOR:
		exposure = NpcWeatherGate.exposure_morale_drain(
				ctx.get("weather", {}), last_exposure)
	morale = NpcMorale.step(morale, dt_hours, needs, blocked,
			float(needs.get("enrichment", 1.0)), exposure)
	quit_pressure = NpcMorale.step_quit_pressure(quit_pressure, morale, dt_hours)


## True when this person wants something they cannot currently get.
func is_blocked(need: String) -> bool:
	return bool(blocked.get(need, false))


func morale_band_label() -> String:
	return NpcMorale.label(morale)


## Hours left in a day after sleep, need activities and assigned chores —
## the gate on enrichment (and the number the Routines day-plan strip shows).
func free_hours(assigned_chore_h: float = 0.0) -> float:
	var sleep_h := 24.0 - SLEEP_START_H + SLEEP_END_H
	var need_h := 0.0
	for n in NEEDS:
		if n == "sleep" or n == "enrichment":
			continue
		var act: Dictionary = ACTIVITIES.get(n, {})
		var dur := float(act.get("duration_h", 0.0))
		if dur <= 0.0:
			continue
		# Visits per waking day implied by the need's rise rate.
		var visits := float(RISE_PER_H.get(n, 0.0)) * (24.0 - sleep_h)
		need_h += dur * maxf(visits, 0.0)
	return 24.0 - sleep_h - need_h - maxf(assigned_chore_h, 0.0)


func current_consumption(ctx: Dictionary) -> Dictionary:
	if state != State.DOING or activity.is_empty():
		return {}
	var consumes: Dictionary = (ACTIVITIES.get(activity, {}) as Dictionary).get("consumes", {})
	if consumes.is_empty():
		return {}
	var starved: Dictionary = ctx.get("starved", {})
	for kind in consumes:
		if starved.get(kind, false):
			return {}  # supply gone mid-activity -> consuming nothing this tick
	return consumes


# --- internals --------------------------------------------------------------

func _reseed_for_day(abs_hours: float) -> void:
	var day := int(floor(abs_hours / 24.0))
	if day != _rng_day:
		if _rng_day != -0x7fffffff:
			_roll_day()
		_rng_day = day
		rng.seed = hash(id) ^ day


## Bank today's walking ledger and start a fresh one.
func _roll_day() -> void:
	prev_day = {
		"distance_m": distance_m,
		"climb_m": climb_m,
		"walk_kcal": walk_kcal,
		"need_distance": need_distance.duplicate(),
		"need_trips": need_trips.duplicate(),
	}
	distance_m = 0.0
	climb_m = 0.0
	walk_kcal = 0.0
	need_distance = {}
	need_trips = {}


func _decay(dt_hours: float) -> void:
	var asleep := state == State.DOING and activity == "sleep"
	for n in NEEDS:
		var v := float(needs.get(n, 0.0))
		if n == "sleep" and asleep:
			v -= SLEEP_RECOVER_PER_H * dt_hours
		elif asleep and (n == "hunger" or n == "thirst" or n == "bladder"):
			v += float(RISE_PER_H[n]) * 0.35 * dt_hours  # metabolic slowdown overnight
		else:
			v += float(RISE_PER_H[n]) * dt_hours
		needs[n] = clampf(v, 0.0, 1.0)


func _step_doing(abs_hours: float, dt_hours: float, ctx: Dictionary) -> Dictionary:
	if activity == CHORE_ACTIVITY:
		return _step_chore(abs_hours, dt_hours, ctx)
	# Starved supply blocks the activity: abort and retry later — the need is
	# NOT satisfied and keeps rising (the two-way-coupling payoff).
	var consumes: Dictionary = _consumes_for(activity)
	if activity != "sleep":
		var starved: Dictionary = ctx.get("starved", {})
		for kind in consumes:
			if starved.get(kind, false):
				blocked[activity] = true
				retry_at[activity] = abs_hours + RETRY_BACKOFF_H + rng.randf_range(0.0, 0.2)
				_finish(ctx, false)
				return {}
	if activity == "sleep":
		var wake := _hour(ctx) >= _wake_hour() and _hour(ctx) < SLEEP_START_H
		if wake or float(needs.get("sleep", 0.0)) <= 0.02:
			_satisfy("sleep")
			_finish(ctx, true)
		return {}
	# Time actually spent on the activity within this step.
	var doing_h := maxf(minf(activity_ends_h, abs_hours) - (abs_hours - dt_hours), 0.0)
	if abs_hours >= activity_ends_h:
		var billed := _scaled(consumes, doing_h, dt_hours)
		_satisfy(activity)
		_finish(ctx, true)
		return billed
	# Interrupt for a different, desperate need.
	var urgent := _most_urgent()
	if not urgent.is_empty() and urgent != activity and float(needs.get(urgent, 0.0)) >= URGENT:
		var billed_part := _scaled(consumes, doing_h, dt_hours)
		_finish(ctx, false)
		return billed_part
	return _scaled(consumes, doing_h, dt_hours)


## Work off the chore board. Progress is credited in EFFECTIVE hours —
## morale and weather both scale how much real work a sim-hour buys, which is
## what closes the "low morale slows the work that would raise morale" loop.
func _step_chore(abs_hours: float, dt_hours: float, ctx: Dictionary) -> Dictionary:
	var board = ctx.get("board")
	if board == null or chore_id.is_empty():
		_finish(ctx, false)
		return {}
	var chore: Dictionary = board.find(chore_id)
	var exposure := str(chore.get("exposure", NpcWeatherGate.EXPOSURE_OUTDOOR))
	last_exposure = exposure
	# A critical need always wins — people do not cheerfully do maintenance
	# while thirsty (design invariant #1).
	var urgent := _most_urgent()
	if chore.is_empty() or (not urgent.is_empty() \
			and float(needs.get(urgent, 0.0)) >= float(THRESHOLD.get(urgent, 1.0))):
		_finish(ctx, false)
		return {}
	var weather: Dictionary = ctx.get("weather", {})
	if NpcWeatherGate.is_unsafe(weather, exposure):
		# Conditions stopped the job: it backs up until the weather turns.
		retry_at[CHORE_ACTIVITY] = abs_hours + RETRY_BACKOFF_H
		_finish(ctx, false)
		return {}
	var effective := dt_hours * NpcMorale.productivity(morale) \
			* NpcWeatherGate.productivity(weather, exposure)
	var applied: float = board.credit(chore_id, effective, abs_hours)
	if applied < effective - 0.0001 or board.remaining(chore_id) <= 0.0:
		# Finished (credit clamps at the remaining work).
		_finish(ctx, true)
	return {}


func _step_traveling(abs_hours: float, dt_hours: float, ctx: Dictionary) -> Dictionary:
	var travel_h := _remaining_travel_hours()
	if travel_h >= dt_hours:
		_walk(dt_hours, ctx)
		return {}
	# Arrived mid-step: begin the activity at the actual arrival instant
	# (space already claimed at selection time) and bill only the tail of the
	# step spent doing it.
	# Account for the last leg BEFORE teleporting to the target, or a trip
	# that completes inside one step contributes nothing.
	var final_leg := NpcNav.path_remaining_m(pos, path, path_idx) 			if path_idx < path.size() else pos.distance_to(target_pos)
	_account_walk(final_leg, pos, target_pos, ctx)
	# Arrived: bank the walk against whatever need drove it, so "how far do
	# people have to go for water" is answerable per need.
	var leg := activity if not activity.is_empty() else CHORE_ACTIVITY
	need_distance[leg] = float(need_distance.get(leg, 0.0)) + trip_distance_m
	need_trips[leg] = int(need_trips.get(leg, 0)) + 1
	trip_distance_m = 0.0
	pos = target_pos
	_clear_path()
	state = State.DOING
	var arrive_abs := abs_hours - dt_hours + travel_h
	if activity == CHORE_ACTIVITY:
		activity_ends_h = INF   # ends when the work is done, not on a clock
		return _step_chore(abs_hours, abs_hours - arrive_abs, ctx)
	var dur := float((ACTIVITIES.get(activity, {}) as Dictionary).get("duration_h", 0.25))
	if dur > 0.0:
		activity_ends_h = arrive_abs + dur * rng.randf_range(0.85, 1.25)
	if activity == "sleep":
		return {}
	var consumes: Dictionary = _consumes_for(activity)
	var starved: Dictionary = ctx.get("starved", {})
	for kind in consumes:
		if starved.get(kind, false):
			return {}  # next step's DOING branch aborts + backs off
	var doing_h := maxf(minf(activity_ends_h, abs_hours) - arrive_abs, 0.0)
	if abs_hours >= activity_ends_h:
		var billed := _scaled(consumes, doing_h, dt_hours)
		_satisfy(activity)
		_finish(ctx, true)
		return billed
	return _scaled(consumes, doing_h, dt_hours)


## What an activity consumes right now. Enrichment is normally free, but a
## fire circle burns real biomass — joy has a cost the player must supply.
func _consumes_for(act: String) -> Dictionary:
	var base: Dictionary = (ACTIVITIES.get(act, {}) as Dictionary).get("consumes", {})
	if act == "enrichment" and target_space_type == "fire_circle":
		return {"biomass": FIRE_BIOMASS_KG_H}
	return base


## Sim-hours left to reach target_pos: along the planned route when there is
## one, else the straight line (grid not ready / unreachable).
func _remaining_travel_hours() -> float:
	if path_idx < path.size():
		return NpcNav.hours_for_distance(NpcNav.path_remaining_m(pos, path, path_idx))
	return NpcNav.travel_hours(pos, target_pos)


func _walk(dt_hours: float, ctx: Dictionary = {}) -> void:
	var before := pos
	var walked := 0.0
	if path_idx < path.size():
		var r := NpcNav.advance_path(pos, path, path_idx, dt_hours)
		pos = r[0]
		path_idx = r[1]
		walked = float(r[2])
	else:
		pos = NpcNav.advance(pos, target_pos, dt_hours)
		walked = before.distance_to(pos)
	_account_walk(walked, before, pos, ctx)


## Bank a walked segment into the daily ledger. Shared by the per-step walk
## and by the ARRIVAL branch — a trip short enough to finish inside one step
## never calls _walk at all, and at high time scale that is every trip, so
## missing this makes the whole walking metric read zero.
func _account_walk(walked: float, from_pos: Vector2, to_pos: Vector2,
		ctx: Dictionary) -> void:
	if walked <= 0.0:
		return
	# Ascent only — the ACSM equation has no valid negative-grade term.
	var gain := 0.0
	var height_at: Callable = ctx.get("height_at", Callable())
	if height_at.is_valid():
		gain = maxf(float(height_at.call(to_pos)) - float(height_at.call(from_pos)), 0.0)
	distance_m += walked
	climb_m += gain
	trip_distance_m += walked
	walk_kcal += NpcMetabolism.walk_kcal(walked, gain, NpcNav.WALK_SPEED_MPS)


func _clear_path() -> void:
	path = PackedVector2Array()
	path_idx = 0


## Ask the world for a route to `dest`. `ctx.plan_path` is supplied by the
## bridge; with no planner (or an unreachable target) the agent keeps the
## straight-line behaviour rather than refusing to move.
func _request_path(ctx: Dictionary, dest: Vector2, from_key: String, to_key: String) -> void:
	_clear_path()
	var planner: Callable = ctx.get("plan_path", Callable())
	if not planner.is_valid():
		return
	var p: Variant = planner.call(pos, dest, from_key, to_key, hash(id))
	if p is PackedVector2Array and (p as PackedVector2Array).size() > 0:
		path = p
		path_idx = 0


static func _scaled(consumes: Dictionary, doing_h: float, dt_hours: float) -> Dictionary:
	if consumes.is_empty() or doing_h <= 0.0 or dt_hours <= 0.0:
		return {}
	var f := clampf(doing_h / dt_hours, 0.0, 1.0)
	var out: Dictionary = {}
	for kind in consumes:
		out[kind] = float(consumes[kind]) * f
	return out


## The priority ladder (POPULATION_PLAN.md §4), evaluated top-down:
##   1. critical need past threshold   2. comfort need (hygiene)
##   3. assigned chore                 4. enrichment (free time + all quiet)
## An agent BLOCKED on tier 1 does NOT fall through to chores — it waits and
## retries. Hungry people do not cheerfully do maintenance; that stall is
## exactly where the morale damage comes from.
func _step_idle(abs_hours: float, ctx: Dictionary) -> void:
	# Tiers 1-2: needs. Retried on their OWN backoff — never suppressed by an
	# unrelated tier having failed.
	var need := _pick(ctx)
	if not need.is_empty():
		if abs_hours >= float(retry_at.get(need, 0.0)):
			_begin_need(need, abs_hours, ctx)
		return
	# Tier 3: work the board.
	if abs_hours >= float(retry_at.get(CHORE_ACTIVITY, 0.0)) and _begin_chore(abs_hours, ctx):
		return
	# Tier 4: gathering — what lifts morale past the baseline ceiling.
	if abs_hours >= float(retry_at.get("enrichment", 0.0)) and _wants_enrichment(ctx):
		_begin_enrichment(abs_hours, ctx)


func _begin_need(need: String, abs_hours: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	var pos_of: Callable = ctx.get("pos_of", Callable())
	if registry == null or not pos_of.is_valid():
		blocked[need] = true
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	var space_type := str((ACTIVITIES[need] as Dictionary).get("space", ""))
	var space := registry.nearest_space_by(space_type, pos, pos_of)
	if space.is_empty():
		# Nothing tagged for this need (or everything is full) — this is a
		# BLOCKED need, and it costs double morale.
		blocked[need] = true
		retry_at[need] = abs_hours + RETRY_BACKOFF_H + rng.randf_range(0.0, 0.15)
		return
	var sid := str(space.get("id", ""))
	if not registry.claim(sid, id):
		blocked[need] = true
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	var p: Variant = pos_of.call(space)
	if not (p is Vector2):
		registry.release(sid, id)
		blocked[need] = true
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	blocked.erase(need)
	trip_distance_m = 0.0
	activity = need
	var from_key := at_space_id
	target_space_id = sid
	target_space_type = space_type
	target_pos = p
	last_exposure = NpcWeatherGate.EXPOSURE_SHELTERED
	_request_path(ctx, p, from_key, sid)
	state = State.TRAVELING


## Enrichment can be satisfied at ANY enrichment space; pick by distance minus
## a social pull toward spaces that already have people at them.
func _begin_enrichment(abs_hours: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	var pos_of: Callable = ctx.get("pos_of", Callable())
	if registry == null or not pos_of.is_valid():
		retry_at["enrichment"] = abs_hours + RETRY_BACKOFF_H
		return
	var starved: Dictionary = ctx.get("starved", {})
	var best: Dictionary = {}
	var best_type := ""
	var best_pos := Vector2.ZERO
	var best_score := INF
	for stype in SpaceTypes.ENRICHMENT_TYPES:
		# No fuel, no fire — head somewhere else rather than looping on a
		# gathering the graph cannot supply.
		if str(stype) == "fire_circle" and bool(starved.get("biomass", false)):
			continue
		for item in registry.spaces_of_type(str(stype)):
			var space: Dictionary = item
			var sid := str(space.get("id", ""))
			if not registry.has_free_capacity(sid):
				continue
			var p: Variant = pos_of.call(space)
			if not (p is Vector2):
				continue
			var company := mini(registry.occupant_count(sid), SOCIAL_PULL_CAP)
			var score := ((p as Vector2) - pos).length() - float(company) * SOCIAL_PULL_M
			if score < best_score:
				best_score = score
				best = space
				best_type = str(stype)
				best_pos = p
	if best.is_empty():
		# No enrichment space tagged. NOT a blocked critical need — it simply
		# means this community is capped at NpcMorale.BASELINE_CEILING.
		retry_at["enrichment"] = abs_hours + RETRY_BACKOFF_H * 4.0
		return
	var sid2 := str(best.get("id", ""))
	if not registry.claim(sid2, id):
		retry_at["enrichment"] = abs_hours + RETRY_BACKOFF_H
		return
	activity = "enrichment"
	target_space_id = sid2
	target_space_type = best_type
	target_pos = best_pos
	last_exposure = NpcWeatherGate.EXPOSURE_OUTDOOR if best_type == "fire_circle" \
			else NpcWeatherGate.EXPOSURE_SHELTERED
	state = State.TRAVELING


func _begin_chore(abs_hours: float, ctx: Dictionary) -> bool:
	var board = ctx.get("board")
	if board == null:
		return false
	var weather: Dictionary = ctx.get("weather", {})
	var options: Array = board.available_for(id, abs_hours, _hour(ctx), weather)
	if options.is_empty():
		return false
	var chore: Dictionary = options[0]
	var cid := str(chore.get("id", ""))
	if not board.claim(cid, id):
		return false
	trip_distance_m = 0.0
	chore_id = cid
	activity = CHORE_ACTIVITY
	target_space_id = ""
	target_space_type = str(chore.get("space_type", ""))
	last_exposure = str(chore.get("exposure", NpcWeatherGate.EXPOSURE_OUTDOOR))
	# Where the work happens: the caller resolves prop / graph-item positions;
	# with no resolvable site, the work happens where the person stands.
	target_pos = pos
	var chore_pos_of: Callable = ctx.get("chore_pos_of", Callable())
	if chore_pos_of.is_valid():
		var p: Variant = chore_pos_of.call(chore)
		if p is Vector2:
			target_pos = p
	# Work sites are not tagged spaces, so this never keys the shared cache.
	_request_path(ctx, target_pos, "", "")
	state = State.TRAVELING
	return true


func _has_free_time(ctx: Dictionary) -> bool:
	return free_hours(float(ctx.get("assigned_chore_h", 0.0))) >= ENRICHMENT_MIN_FREE_H


## Tiers 1-2 of the priority ladder: the most urgent CRITICAL need past its
## threshold, else the comfort need (hygiene). Chores (tier 3) and enrichment
## (tier 4) are chosen by _step_idle only when this returns "".
##
## Tiers matter: comparing raw levels across needs livelocks. Hygiene pinned
## at 1.00 would out-score thirst at 0.99, the agent would start a shower, get
## interrupted by the desperate thirst, and repeat forever — dying of thirst
## while trying to wash.
func _pick(ctx: Dictionary) -> String:
	var best := ""
	var best_score := 0.0
	for n in CRITICAL_NEEDS:
		var v := float(needs.get(n, 0.0))
		if n == "sleep":
			var in_window := _hour(ctx) >= SLEEP_START_H or _hour(ctx) < SLEEP_END_H
			if not in_window and v < float(THRESHOLD["sleep"]):
				continue
			if in_window and v < 0.25:
				continue  # slept enough — don't go straight back to bed
		elif v < float(THRESHOLD[n]):
			continue
		if v > best_score:
			best_score = v
			best = n
	if not best.is_empty():
		return best
	# Tier 2: comfort, only once nothing critical is calling.
	if float(needs.get("hygiene", 0.0)) >= float(THRESHOLD["hygiene"]):
		return "hygiene"
	return ""


## Tier 4 — worth gathering right now? (Tier 3, chores, is checked first.)
func _wants_enrichment(ctx: Dictionary) -> bool:
	if not _critical_all_quiet():
		return false
	if float(needs.get("hygiene", 0.0)) >= float(THRESHOLD["hygiene"]):
		return false
	if float(needs.get("enrichment", 0.0)) < float(THRESHOLD["enrichment"]):
		return false
	return _has_free_time(ctx)


func _critical_all_quiet() -> bool:
	for n in CRITICAL_NEEDS:
		if float(needs.get(n, 0.0)) >= float(THRESHOLD.get(n, 1.0)):
			return false
	return true


## ONLY a critical need may interrupt an in-progress activity, and sleep ends
## on its own wake check rather than by interruption. Comfort needs are never
## emergencies — nobody abandons a meal to shower, and an un-enriched person
## pinned at 1.0 must not cancel every activity they start (that livelocks the
## whole FSM: the agent restarts an action every tick and completes nothing).
const NON_INTERRUPTING: Array = ["sleep", "hygiene", "enrichment"]


func _most_urgent() -> String:
	var best := ""
	var best_v := 0.0
	for n in CRITICAL_NEEDS:
		if n in NON_INTERRUPTING:
			continue
		var v := float(needs.get(n, 0.0))
		if v > best_v:
			best_v = v
			best = n
	return best


func _satisfy(need: String) -> void:
	if need.is_empty():
		return
	needs[need] = rng.randf_range(0.0, 0.08)
	blocked.erase(need)
	if need == "thirst":
		needs["bladder"] = clampf(float(needs.get("bladder", 0.0)) + DRINK_BLADDER_KICK, 0.0, 1.0)


func _finish(ctx: Dictionary, _completed: bool) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry != null and not target_space_id.is_empty():
		registry.release(target_space_id, id)
	var board = ctx.get("board")
	if board != null and not chore_id.is_empty():
		board.release(chore_id, id)
	chore_id = ""
	# Remember the space we finished at: the next trip starts there, which is
	# what lets the space-pair route cache hit.
	at_space_id = target_space_id
	activity = ""
	target_space_id = ""
	target_space_type = ""
	last_exposure = NpcWeatherGate.EXPOSURE_INDOOR
	_clear_path()
	state = State.IDLE


## Drop every claim this person holds (departure / roster rebuild).
func release_claims(ctx: Dictionary) -> void:
	_finish(ctx, false)


func _wake_hour() -> float:
	# Per-agent jittered wake time, stable within a day (rng is day-seeded).
	return SLEEP_END_H + (float(hash(id) % 97) / 97.0) * 1.5


func _hour(ctx: Dictionary) -> float:
	return fposmod(float(ctx.get("hour_of_day", 12.0)), 24.0)


# --- readouts ---------------------------------------------------------------

## Player-facing one-liner: what this person is doing right now.
func status_line() -> String:
	match state:
		State.DOING:
			if activity == "sleep":
				return "asleep"
			if activity == CHORE_ACTIVITY:
				return "working"
			if activity == "enrichment":
				return "%s (%s)" % [_enrich_verb(target_space_type),
						SpaceTypes.label(target_space_type)]
			return "%s (%s)" % [_verb(activity), SpaceTypes.label(_space_of(activity))]
		State.TRAVELING:
			if activity == CHORE_ACTIVITY:
				return "heading to work"
			var dest := target_space_type if not target_space_type.is_empty() \
					else _space_of(activity)
			return "heading to %s" % SpaceTypes.label(dest)
	var top := _worst_need()
	if not top.is_empty() and float(needs.get(top, 0.0)) >= float(THRESHOLD.get(top, 1.0)):
		# Wants something but can't get it — no tagged space, all full, or the
		# supply is starved.
		return "waiting — needs %s" % SpaceTypes.label(_space_of(top))
	return "idle"


## The need closest to desperate right now (drives the crosshair readout).
func _worst_need() -> String:
	var best := ""
	var best_v := -1.0
	for n in NEEDS:
		var v := float(needs.get(n, 0.0))
		if v > best_v:
			best_v = v
			best = n
	return best


static func _space_of(need: String) -> String:
	return str(SpaceTypes.NEED_TO_SPACE.get(need, ""))


static func _verb(need: String) -> String:
	match need:
		"hunger": return "eating"
		"thirst": return "drinking"
		"bladder": return "using the restroom"
		"hygiene": return "washing"
		"sleep": return "sleeping"
		"enrichment": return "unwinding"
	return "busy"


static func _enrich_verb(space_type: String) -> String:
	match space_type:
		"fire_circle": return "at the fire"
		"movement": return "dancing"
		"quiet": return "resting"
		"workshop_social": return "making things"
	return "unwinding"


# --- persistence ------------------------------------------------------------

func snapshot() -> Dictionary:
	var rounded_needs := {}
	for n in NEEDS:
		rounded_needs[n] = snappedf(float(needs.get(n, 0.0)), 0.01)
	return {
		"id": id,
		"x": snappedf(pos.x, 0.5), "z": snappedf(pos.y, 0.5),
		"needs": rounded_needs,
		"activity": activity,
		"morale": snappedf(morale, 0.01),
		"quit_pressure": snappedf(quit_pressure, 0.01),
		"distance_m": snappedf(distance_m, 1.0),
		"climb_m": snappedf(climb_m, 0.5),
		"walk_kcal": snappedf(walk_kcal, 1.0),
	}


static func from_snapshot(snap: Dictionary) -> NpcAgent:
	var a := NpcAgent.make(str(snap.get("id", "npc")),
			Vector2(float(snap.get("x", 0.0)), float(snap.get("z", 0.0))))
	var saved: Dictionary = snap.get("needs", {})
	for n in NEEDS:
		if saved.has(n):
			a.needs[n] = clampf(float(saved[n]), 0.0, 1.0)
	a.morale = clampf(float(snap.get("morale", NpcMorale.START_MORALE)), 0.0, 1.0)
	a.quit_pressure = maxf(float(snap.get("quit_pressure", 0.0)), 0.0)
	a.distance_m = maxf(float(snap.get("distance_m", 0.0)), 0.0)
	a.climb_m = maxf(float(snap.get("climb_m", 0.0)), 0.0)
	a.walk_kcal = maxf(float(snap.get("walk_kcal", 0.0)), 0.0)
	# Activities don't survive save/load (spaces are re-claimed on demand);
	# the agent re-plans from IDLE on the first tick.
	return a
