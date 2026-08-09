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
##   toilet  3x/day x 5 min  x water 72 L/h (one 6 L flush)   = 18 L
##   shower ~1x/day x 0.2 h  x water 60 L/h (navy shower)    = ~12 L
## Totals ~48 L water, 1.5 kg food/day. Toilet use is SCHEDULED (NpcRoutine),
## not threshold-driven, which is what fixed both the ~40 L/day of phantom
## flushes and everyone pooling at the restrooms between trips.

enum State { IDLE, TRAVELING, DOING }

const NEEDS: Array = ["hunger", "thirst", "bladder", "sleep", "hygiene", "enrichment"]

## Survival needs. These always preempt chores and enrichment (design
## invariant #1) and are the only needs that damage morale directly.
const CRITICAL_NEEDS: Array = ["hunger", "thirst", "bladder", "sleep"]

## Need rise per sim-hour while awake.
const RISE_PER_H: Dictionary = {
	"hunger": 1.0 / 16.0,   # 3 meals over a 16 h waking day
	"thirst": 1.0 / 5.0,
	# Slow enough that the routine's 3 scheduled visits actually SUFFICE. The
	# longest waking gap in the default day is ~5.1 h (09:05 -> 13:55), and at
	# the old 1/4 per hour the need crossed its threshold every ~2.4 h, so it
	# fired constantly and dragged people back to the toilets between blocks —
	# which is what kept them pooled there even after the schedule landed.
	"bladder": 1.0 / 12.0,
	"sleep": 1.0 / 16.0,
	"hygiene": 1.0 / 20.0,  # ~1 wash per waking day
	"enrichment": 1.0 / 30.0,
}

## Act when the need crosses its threshold; higher urgency wins (see _pick).
const THRESHOLD: Dictionary = {
	"hunger": 0.55,
	"thirst": 0.5,
	# Raised alongside the slower rise so a scheduled day never trips it; the
	# need now escalates only when a visit is MISSED (blocked space, starved
	# supply, an overrunning chore), which is the honest use of a threshold.
	"bladder": 0.75,
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
	# 5 minutes and one 6 L flush. The rate is per sim-hour, so
	# 72 L/h x (5/60) h = 6.0 L per visit — see NpcRoutine.WATER_PER_VISIT_L
	# for the source of the 6 L figure. Scheduled routines give 3 visits/day
	# (~18 L); adding a bathroom block adds a flush, which is the honest model.
	"bladder": {"space": "restroom", "duration_h": NpcRoutine.BATHROOM_HOURS,
		"consumes": {"water": NpcRoutine.WATER_PER_VISIT_L / NpcRoutine.BATHROOM_HOURS}},
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
const QUORUM_WAIT_H := 0.5         # give a crew chore this long to gather hands
## Floor on the need level that pulls someone off SOLO work. Crew work at
## quorum uses URGENT instead — see _step_chore. Without a floor, the raw
## thresholds apply (thirst 0.5), and at rise 0.2/h that is a preemption every
## ~2.5 h per person, which repeatedly collapsed six-person musters.
const CHORE_PREEMPT_FLOOR := 0.80
## Drinking still nudges the bladder, but at ~8 drinks/day the old 0.12 added
## ~1.0 of need per day on its own — more than the rise itself — which alone
## forced extra unscheduled trips.
const DRINK_BLADDER_KICK := 0.06
## Below this much room in the day, nobody has the appetite for enrichment.
const ENRICHMENT_MIN_FREE_H := 1.5
## Live trail: how many recent points to keep, and how far apart to sample.
const TRAIL_MAX := 48
const TRAIL_STEP_M := 1.5
## Trail points older than this many sim-hours age out. Without an age cap the
## count bound alone let an idle agent's last 48 waypoints sit painted on the
## Site Plan forever — 50 sleepers left a permanent web over the whole camp.
const TRAIL_MAX_AGE_H := 0.5

var id: String = ""
var display_name: String = ""
var pos: Vector2 = Vector2.ZERO
var needs: Dictionary = {}
var state: int = State.IDLE
var activity: String = ""          # need id or CHORE_ACTIVITY ("" when idle)
var target_space_id: String = ""
var target_space_type: String = "" # enrichment picks its type per visit
var target_pos: Vector2 = Vector2.ZERO
## Where this person LOOKS while standing still: the work site, the far end of
## a relay line, or the centre of the space they came to. `agent_dots()` turns
## it into a bearing each tick; see NpcFacing for why it is re-derived rather
## than latched. Vector2.INF = no opinion, fall back to the agent's own phase.
##
## TRANSIENT — never snapshotted, the same rule chore_id/target_pos already
## follow, because activities do not survive save/load and the agent re-plans
## from IDLE. It must be cleared in THREE places (_finish, release_claims via
## _finish, and the engine's _catch_up); missing the third leaves a restored
## agent staring at a point across the map.
var face_anchor: Vector2 = Vector2.INF
## Stable per-agent heading, 0..TAU. Doubles as the fallback bearing when there
## is no anchor (so a fresh roster does not all face world north) and as the
## idle-drift phase offset (so nobody wanders in step).
var face_phase: float = 0.0
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
## need -> abs-hour the block STARTED (cleared when it clears). The alarm
## source: `blocked` itself flaps every RETRY_BACKOFF_H, so an alarm keyed on
## it would strobe; a latch on duration is what makes "nobody can wash" a
## single quiet line instead of a stream.
var blocked_since: Dictionary = {}
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
## Recent positions for the live trail render. Runtime only — never
## persisted, and bounded so 50 people cost nothing. `trail_t` carries the
## abs-hour stamp of each point (lockstep with `trail`) so points can age out.
var trail := PackedVector2Array()
var trail_t := PackedFloat32Array()
var chore_id: String = ""          # chore being worked (CHORE_ACTIVITY only)
var chore_wait_h := 0.0            # time spent at a crew chore below quorum
## Two-leg haul chores (Site Projects): 0 = walking to the chore target (the
## pickup — usually a crate prop), 1 = CARRYING to the chore's `carry_to`
## point. Like chore_id, deliberately not persisted: activities re-plan from
## IDLE after a load, and the crate itself only moves via the completion
## effect, so an abandoned carry leaves the world exactly consistent.
var chore_leg := 0
## Deterministic shift applied to this person's whole daily schedule so a camp
## does not stand up and walk to the toilets in one column (NpcRoutine).
var routine_offset_h: float = 0.0
## Block kind this agent is currently fulfilling ("" = acting on a need).
var routine_kind: String = ""
var last_exposure: String = NpcWeatherGate.EXPOSURE_INDOOR
## Multiplayer possession: the peer id driving this person, or 0 for the FSM.
## TRANSIENT — deliberately absent from snapshot()/from_snapshot(). Persisting
## it would restore an agent frozen with no controller after a reload.
var controlled_by_peer: int = 0
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
	# Everyone's whole day is shifted a little, so a camp does not stand up at
	# 09:00 and walk to the toilets in one column.
	a.routine_offset_h = NpcRoutine.offset_for(agent_id)
	# Cached once: agent_dots() reads this every tick for every agent and must
	# not be hashing strings 50x a tick to get it.
	a.face_phase = NpcHash.unit01(agent_id, "face") * TAU
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
	trim_trail(abs_hours)
	_decay(dt_hours)
	# A possessed person is driven by a remote player, so the FSM must not pick
	# their destinations — but they are still a person: needs keep rising,
	# morale keeps moving, and `current_consumption` still bills whatever they
	# are doing. Skipping the whole step instead would make possession a way to
	# opt out of the resource economy.
	if controlled_by_peer != 0:
		var billed: Dictionary = current_consumption(ctx)
		_update_morale(dt_hours, ctx)
		return billed
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


## Latch a block, keeping the FIRST failure's timestamp — re-marking an
## already-blocked need must not restart its clock, or the retry cadence
## (every RETRY_BACKOFF_H) would keep resetting it and no alarm could ever
## reach its threshold.
func _mark_blocked(need: String, abs_hours: float) -> void:
	blocked[need] = true
	if not blocked_since.has(need):
		blocked_since[need] = abs_hours


func _clear_blocked(need: String) -> void:
	blocked.erase(need)
	blocked_since.erase(need)


## How long this need has been unsatisfiable, in sim-hours (0 when it isn't).
func blocked_hours(need: String, abs_hours: float) -> float:
	if not bool(blocked.get(need, false)):
		return 0.0
	return maxf(abs_hours - float(blocked_since.get(need, abs_hours)), 0.0)


## The need this person actually cannot get — the honest answer to "why is
## nobody working". Distinct from `_worst_need()`, which returns the HIGHEST
## need and therefore used to blame enrichment (pinned at 1.0 on any site with
## no fire circle) while a missing shower was the real cause.
func blocking_need() -> String:
	var best := ""
	var best_v := -1.0
	for n in blocked:
		if not bool(blocked[n]):
			continue
		var v := float(needs.get(str(n), 0.0))
		if v > best_v:
			best_v = v
			best = str(n)
	return best


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
				_mark_blocked(activity, abs_hours)
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
	# while thirsty (design invariant #1). But the BAR depends on whether this
	# is crew work: a chore at quorum sheds one worker and everybody else's
	# credit drops to zero, so a barn-raising was being dissolved every ~2.5 h
	# by ordinary thirst (threshold 0.5 at rise 0.2/h). Solo work still yields
	# readily; a mustered crew holds out for a real emergency.
	var urgent := _most_urgent()
	var bar := URGENT if bool(board.has_quorum(chore_id)) else CHORE_PREEMPT_FLOOR
	if chore.is_empty() or (not urgent.is_empty() \
			and float(needs.get(urgent, 0.0)) >= maxf(float(THRESHOLD.get(urgent, 1.0)), bar)):
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
	# Bank it against the PERSON. This return value was discarded for the
	# whole life of the chore board, which is why "is the load divided
	# evenly" had no answer. Note credit() returns 0.0 below quorum and that
	# labour genuinely is lost — banking the wait would reward standing at a
	# stalled barn-raising, which is worse than no metric at all.
	if applied > 0.0:
		var bank: Callable = ctx.get("bank_labour", Callable())
		if bank.is_valid():
			bank.call(id, applied, NpcWorkPose.family_for(board.find(chore_id)))
	if board.remaining(chore_id) <= 0.0:
		# Finished (by this credit, or a crewmate's).
		_finish(ctx, true)
		return {}
	if applied <= 0.0 and not bool(board.has_quorum(chore_id)):
		# Crew chore below quorum: the work pays nothing yet, so stand at the
		# site and wait for hands — the gathering IS the behavior. Bounded:
		# if the crew never materializes (everyone else is eating, or the
		# roster is stretched), release and back off through the normal
		# per-tier retry so this can never become the quorum-wait livelock.
		# Patience scales with how CLOSE the crew is: 5 of 6 hands standing
		# at the raise should hold the line while the sixth walks over, not
		# all bail on the base timer and restart the muster from zero.
		chore_wait_h += dt_hours
		var min_w := maxi(int(chore.get("min_workers", 1)), 1)
		var crew_frac := float(board.worker_count(chore_id)) / float(min_w)
		if chore_wait_h >= QUORUM_WAIT_H * (1.0 + 2.0 * clampf(crew_frac, 0.0, 1.0)):
			retry_at[CHORE_ACTIVITY] = abs_hours + RETRY_BACKOFF_H
			_finish(ctx, false)
		return {}
	chore_wait_h = 0.0
	if applied < effective - 0.0001:
		# Credit clamped at the remaining work — the chore just completed.
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
	# Captured before `pos` is overwritten: _settle_face_anchor below needs the
	# direction we came in from, and in one line's time there will not be one.
	var arrival_from := pos
	pos = target_pos
	_clear_path()
	# Two-leg haul: arriving at the PICKUP switches to the carry leg and walks
	# on to `carry_to`. The crate itself never moves here — the move is the
	# chore's COMPLETION effect — so a carry preempted by a need leaves the
	# world consistent and the next claimant walks to the crate's real spot.
	if activity == CHORE_ACTIVITY and chore_leg == 0:
		var board = ctx.get("board")
		if board != null and not chore_id.is_empty():
			var carry_to: Dictionary = (board.find(chore_id) as Dictionary).get("carry_to", {})
			if not carry_to.is_empty():
				chore_leg = 1
				target_pos = Vector2(float(carry_to.get("x", pos.x)),
					float(carry_to.get("z", pos.y)))
				face_anchor = target_pos
				_request_path(ctx, target_pos, "", "")
				return {}
	_settle_face_anchor(target_pos - arrival_from, _chore_is_shared(ctx))
	state = State.DOING
	var arrive_abs := abs_hours - dt_hours + travel_h
	if activity == CHORE_ACTIVITY:
		activity_ends_h = INF   # ends when the work is done, not on a clock
		return _step_chore(abs_hours, abs_hours - arrive_abs, ctx)
	var dur := float((ACTIVITIES.get(activity, {}) as Dictionary).get("duration_h", 0.25))
	if dur > 0.0:
		activity_ends_h = arrive_abs + dur * rng.randf_range(0.85, 1.25)
		# Never run past the end of the scheduled block that asked for this.
		# The 5-minute bathroom visit is only 5 minutes if the schedule can
		# actually reclaim the person afterwards.
		var routine: NpcRoutine = ctx.get("routine")
		if routine != null and not routine_kind.is_empty():
			var left := routine.hours_left_in_block(_hour(ctx), routine_offset_h)
			if left > 0.0:
				activity_ends_h = minf(activity_ends_h, abs_hours + left)
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
	# Desire lines: report the segment against whatever need drove this trip,
	# so the map can be filtered by need later.
	var trace: Callable = ctx.get("trace", Callable())
	if trace.is_valid():
		trace.call(from_pos, to_pos,
				activity if not activity.is_empty() else CHORE_ACTIVITY, walked)
	if trail.is_empty() or trail[trail.size() - 1].distance_to(to_pos) >= TRAIL_STEP_M:
		trail.append(to_pos)
		trail_t.append(float(ctx.get("abs_hours", 0.0)))
		if trail.size() > TRAIL_MAX:
			trail = trail.slice(trail.size() - TRAIL_MAX)
			trail_t = trail_t.slice(trail_t.size() - TRAIL_MAX)


func _clear_path() -> void:
	path = PackedVector2Array()
	path_idx = 0


func clear_trail() -> void:
	trail = PackedVector2Array()
	trail_t = PackedFloat32Array()


## Age out live-trail points (called every step). A backward scrub leaves
## stamps in the future — treat that as a discontinuity and drop the whole
## trail rather than painting a route the rewound world hasn't walked yet.
func trim_trail(now_h: float) -> void:
	if trail_t.is_empty():
		if not trail.is_empty():
			trail = PackedVector2Array()
		return
	if trail_t[trail_t.size() - 1] > now_h + 0.001:
		clear_trail()
		return
	var cutoff := now_h - TRAIL_MAX_AGE_H
	var drop := 0
	while drop < trail_t.size() and trail_t[drop] < cutoff:
		drop += 1
	if drop > 0:
		trail = trail.slice(drop)
		trail_t = trail_t.slice(drop)


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
##
## Tier 2 is DIFFERENT and the distinction is load-bearing. A comfort need must
## never stop work: hygiene rises forever (`_decay` raises it every hour, even
## during sleep) and only a COMPLETED shower lowers it, so on a site with no
## shower tagged an absorbing tier-2 return meant the agent re-picked hygiene
## every tick and tiers 2.5/3/4 became permanently unreachable. Needs seed at
## randf(0.05, 0.45), so every agent in the camp locked between hour ~5 and
## hour ~13 and never worked again — the "I schedule tasks but they never
## complete" bug. POPULATION_PLAN.md §4 only ever promised absorbing behaviour
## for tier 1; tier 2 inherited it by accident.
func _step_idle(abs_hours: float, ctx: Dictionary) -> void:
	# Tiers 1-2: needs. Retried on their OWN backoff — never suppressed by an
	# unrelated tier having failed. Needs still outrank the schedule: a
	# desperately thirsty person leaves their work block.
	var need := _pick(ctx)
	if not need.is_empty():
		if abs_hours >= float(retry_at.get(need, 0.0)):
			_begin_need(need, abs_hours, ctx)
		if state != State.IDLE:
			return   # actually went somewhere — done for this tick
		if CRITICAL_NEEDS.has(need):
			return   # tier 1 still absorbs, by design
		# Tier 2 is blocked or backed off: go be useful instead of freezing.
	# Tier 2.5: the daily routine. This is what stops people idling wherever
	# they last finished — without somewhere to be next, and with space
	# selection preferring the NEAREST match, everyone pooled at the restroom.
	var routine: NpcRoutine = ctx.get("routine")
	if routine != null:
		var kind := str(routine.block_at(_hour(ctx), routine_offset_h).get("kind", NpcRoutine.FREE))
		var scheduled := NpcRoutine.activity_for(kind)
		if not scheduled.is_empty() and abs_hours >= float(retry_at.get(scheduled, 0.0)):
			routine_kind = kind
			_begin_need(scheduled, abs_hours, ctx)
			return
		if kind == NpcRoutine.WORK:
			routine_kind = kind
			if abs_hours >= float(retry_at.get(CHORE_ACTIVITY, 0.0)) 					and _begin_chore(abs_hours, ctx):
				return
			# Nothing on the board during a work block — fall through to
			# gathering rather than standing still.
		routine_kind = kind
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
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	var space_type := str((ACTIVITIES[need] as Dictionary).get("space", ""))
	var space := registry.nearest_space_by(space_type, pos, pos_of)
	if space.is_empty():
		# Nothing tagged for this need (or everything is full) — this is a
		# BLOCKED need, and it costs double morale.
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H + rng.randf_range(0.0, 0.15)
		return
	var sid := str(space.get("id", ""))
	if not registry.claim(sid, id):
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	var p: Variant = pos_of.call(space)
	if not (p is Vector2):
		registry.release(sid, id)
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	_clear_blocked(need)
	trip_distance_m = 0.0
	activity = need
	var from_key := at_space_id
	target_space_id = sid
	target_space_type = space_type
	# Stand in this agent's own slot rather than on the space's centre point,
	# or every occupant converges on one spot. Purely positional — the space is
	# already claimed, so this changes nobody's consumption.
	target_pos = _standing_spot(registry, sid, p, ctx)
	# Look at the space, not back down the corridor we walked in. The CENTRE,
	# deliberately, not our own slot — occupants of a fire circle should face
	# each other. Recomputed from the final position every tick, so the
	# unwalkable-slot fallback (which returns the plain centre) degrades to the
	# projection path rather than to a meaningless zero-length vector.
	face_anchor = p
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
	target_pos = _standing_spot(registry, sid2, best_pos, ctx)
	face_anchor = best_pos
	last_exposure = NpcWeatherGate.EXPOSURE_OUTDOOR if best_type == "fire_circle" \
			else NpcWeatherGate.EXPOSURE_SHELTERED
	state = State.TRAVELING


func _begin_chore(abs_hours: float, ctx: Dictionary) -> bool:
	var board = ctx.get("board")
	if board == null:
		return false
	var weather: Dictionary = ctx.get("weather", {})
	var options: Array = board.available_for(id, abs_hours, _hour(ctx), weather,
		int(ctx.get("roster_size", 0)),
		int((ctx.get("fair_ranks", {}) as Dictionary).get(id, 0)),
		_my_skills(ctx))
	if options.is_empty():
		return false
	var chore: Dictionary = options[0]
	var cid := str(chore.get("id", ""))
	if not board.claim(cid, id):
		return false
	trip_distance_m = 0.0
	chore_id = cid
	chore_wait_h = 0.0
	chore_leg = 0
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
	# Face the job. A crew all stand on this one point, so this alone would
	# still be degenerate — what saves it is that the separation pass spreads
	# them to ~0.9 m spacing and the bearing is re-derived from the FINAL
	# position each tick, which turns that spread into a spread of facings.
	face_anchor = target_pos
	# Brigade haul: this worker takes a STATION post along the route rather
	# than clustering at the target. Station = claim-order slot over the
	# chore's max_workers positions, so the line forms stably as people
	# arrive and never reshuffles under someone already walking to a post.
	var haul: Dictionary = chore.get("haul", {})
	if not haul.is_empty() and str(haul.get("strategy", "")) == "brigade":
		var slot: int = board.worker_index(cid, id)
		if slot >= 0:
			var from := Vector2(float(haul.get("from_x", target_pos.x)),
				float(haul.get("from_z", target_pos.y)))
			var to := Vector2(float(haul.get("to_x", target_pos.x)),
				float(haul.get("to_z", target_pos.y)))
			var slots := maxi(int(chore.get("max_workers", 1)), 1)
			# Down the line, not at it: a relay faces where the load is going.
			# Set before target_pos moves onto the station, so the anchor is
			# the route's far end and not this worker's own post.
			face_anchor = to
			target_pos = from.lerp(to, (float(slot) + 0.5) / float(slots))
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


## The most pressing need AMONG THOSE ALREADY PAST THEIR OWN THRESHOLD, ranked
## by normalized excess. Ranking on the raw level instead let a high-threshold
## need mask a lower-numbered one that was genuinely over: bladder 0.74
## (threshold 0.75) beat hunger 0.60 (threshold 0.55), so the caller tested
## bladder, found it under, and silently ignored the hunger. Returns "" when
## nothing is actually over.
func _most_urgent() -> String:
	var best := ""
	var best_x := 0.0
	for n in CRITICAL_NEEDS:
		if n in NON_INTERRUPTING:
			continue
		var thr := float(THRESHOLD.get(n, 1.0))
		var v := float(needs.get(n, 0.0))
		if v < thr:
			continue
		var x := (v - thr) / maxf(1.0 - thr, 0.01)
		if best.is_empty() or x > best_x:
			best_x = x
			best = n
	return best


func _satisfy(need: String) -> void:
	if need.is_empty():
		return
	needs[need] = rng.randf_range(0.0, 0.08)
	_clear_blocked(need)
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
	chore_leg = 0
	face_anchor = Vector2.INF
	# Remember the space we finished at: the next trip starts there, which is
	# what lets the space-pair route cache hit.
	at_space_id = target_space_id
	activity = ""
	target_space_id = ""
	target_space_type = ""
	last_exposure = NpcWeatherGate.EXPOSURE_INDOOR
	_clear_path()
	state = State.IDLE


## The point this agent actually walks to inside a claimed space: the space's
## resolved centre plus its own packing slot, nudged back onto walkable ground
## if the slot lands in a wall or off a ledge.
##
## The A* planner already snaps an unreachable GOAL to the nearest walkable
## cell, so this only matters for the straight-line fallback before the nav
## grid has finished baking — but that is also the window where the site looks
## worst, so it is worth the one query.
func _standing_spot(registry, space_id: String, centre: Vector2,
		ctx: Dictionary) -> Vector2:
	var spot: Vector2 = centre + (registry.slot_offset(space_id, id) as Vector2)
	var walkable: Callable = ctx.get("walkable", Callable())
	if walkable.is_valid() and not bool(walkable.call(spot)):
		return centre
	return spot


## Mid-haul second leg: walking a pickup's contents to `carry_to`. The Site
## Plan and 3D layers read this off the dot payload to draw the carried box.
func is_carrying() -> bool:
	return state == State.TRAVELING and activity == CHORE_ACTIVITY and chore_leg == 1


## Drop every claim this person holds (departure / roster rebuild).
func release_claims(ctx: Dictionary) -> void:
	_finish(ctx, false)


## Distance to project a fallback anchor. Far enough that later crowding
## rotates the bearing by ~1.4° rather than swinging it, near enough to stay
## inside any sane map.
const FACE_PROJECT_M := 8.0


## Guarantee a usable anchor before anyone stands still.
##
## A SOLO worker ends up standing exactly on their anchor, at which point the
## bearing to it is undefined. Projecting the arrival heading forward is the
## honest answer: they keep looking the way they came in, which is what a
## person does when they stop somewhere with nothing in particular to face.
##
## ⚠ But a SHARED job must keep its real anchor even though the whole crew is
## also standing on it. The separation pass spreads them to ~0.9 m around the
## point within a few ticks, and from there the inward bearings are both
## meaningful and naturally different — a huddle around the work. Projecting
## here instead would freeze each of them on their own approach heading, which
## scatters the facings without aiming any of them, and is how the first
## version of this looked "fixed" while every worker faced out into a field.
func _settle_face_anchor(heading: Vector2, shared: bool) -> void:
	if face_anchor != Vector2.INF:
		if shared:
			return
		if pos.distance_to(face_anchor) >= NpcFacing.MIN_ANCHOR_M:
			return
	var d := heading
	if d.length() < 0.001:
		# Arrived without travelling (already standing there). Use the agent's
		# own phase so the camp still faces every which way.
		d = Vector2(0.0, -1.0).rotated(face_phase)
	face_anchor = pos + d.normalized() * FACE_PROJECT_M


## Is more than one person working this chore? Decides whether the arrival
## overrides the job's anchor (see _settle_face_anchor).
func _chore_is_shared(ctx: Dictionary) -> bool:
	if activity != CHORE_ACTIVITY or chore_id.is_empty():
		return false
	var board = ctx.get("board")
	if board == null:
		return false
	var chore: Dictionary = board.find(chore_id)
	if chore.is_empty():
		return false
	# max_workers, not the live count: the second person may still be walking,
	# and the first one must not spend that time aimed off into the distance.
	return int(chore.get("max_workers", 1)) > 1


## This person's qualified tags, for the board's skill gate. Allocated per
## pick attempt rather than per frame — chore selection runs on the backoff
## cadence, not every tick.
func _my_skills(ctx: Dictionary) -> Dictionary:
	var sk = ctx.get("skills")
	return sk.tags_of(id) if sk != null else {}


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
				return "carrying a load" if chore_leg == 1 else "heading to work"
			var dest := target_space_type if not target_space_type.is_empty() \
					else _space_of(activity)
			return "heading to %s" % SpaceTypes.label(dest)
	# What they CANNOT GET wins over what they merely want most. Reporting
	# _worst_need() here blamed whichever need happened to be highest — on a
	# site with no fire circle that is enrichment pinned at 1.0 — while the
	# actual blocker (a missing shower) went unnamed. The whole stall was
	# invisible for exactly this reason.
	var stuck := blocking_need()
	if not stuck.is_empty():
		return "waiting — no %s" % SpaceTypes.label(_space_of(stuck))
	var top := _worst_need()
	if not top.is_empty() and float(needs.get(top, 0.0)) >= float(THRESHOLD.get(top, 1.0)):
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


## The space type that satisfies a need. Public because the alarm layer needs
## to name what is missing ("nobody can reach a Shower"), not just which need
## is stuck.
static func space_of(need: String) -> String:
	return str(SpaceTypes.NEED_TO_SPACE.get(need, ""))


static func _space_of(need: String) -> String:
	return space_of(need)


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
	var out := {
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
	# Only stored when it differs from the deterministic default — a renamed
	# agent needs to survive save/load, but the common case (everyone still
	# has their generated name) shouldn't bloat every snapshot with it.
	if display_name != name_for(id):
		out["display_name"] = display_name
	return out


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
	if snap.has("display_name"):
		a.display_name = str(snap["display_name"])
	# Activities don't survive save/load (spaces are re-claimed on demand);
	# the agent re-plans from IDLE on the first tick.
	return a
