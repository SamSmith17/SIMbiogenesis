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
	# A SOCIAL block's stint (NpcSocial): a conversation circle in camp or a
	# wander. Consumes nothing and is NOT a need; its length is NpcSocial's.
	NpcSocial.ACTIVITY: {"space": "", "duration_h": 0.5, "consumes": {}},
	# The DJ's set: cast by the bridge (begin_perform), ends with the set.
	"perform": {"space": "", "duration_h": 1.0, "consumes": {}},
	# Nothing to do after finishing at a space: step aside from the spot just
	# used (its slot is the next person's) and hang out a few metres off
	# (_maybe_loiter). Consumes nothing; any need past its threshold ends it.
	LOITER_ACTIVITY: {"space": "", "duration_h": 0.25, "consumes": {}},
}

## Hanging out beside a space just used (see _maybe_loiter).
const LOITER_ACTIVITY := "loiter"
## Diagnostics switch (tools/diag): false = idle where you finished, as before.
static var loiter_enabled := true
## Step aside when still within LOITER_NEAR_M of the space's centre, to a spot
## LOITER_MIN_M..+LOITER_SPREAD_M out (CrowdCohort's numbers).
const LOITER_NEAR_M := 6.0
const LOITER_MIN_M := 5.0
const LOITER_SPREAD_M := 3.0

## The DJ activity (NpcPopulationBridge casts one person per live stage).
const PERFORM_ACTIVITY := "perform"

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
const PERFORM_URGENT := 0.995      # ...and this high takes the DJ off the decks
## During a burn, someone in its TURNOUT (VenueCrowd.attends) only goes to bed
## exhausted — they stay up for it. Never wakes a sleeper.
const STAY_UP_BAR := 0.99
## ...and puts off a meal until hunger is pressing (thirst and the bladder
## still come first): nobody leaves a burn to cook dinner.
const BURN_HUNGER_BAR := 0.85
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
## {music, quiet, social, art} in 0..1, hashed from the id on first use.
var _taste: Dictionary = {}
## Hours a programmed venue has left when the visit begins (-1 = none).
var _enrichment_cap_h := -1.0
## LIVE venues (VenueCrowd: the effigy, a stage with a set on): the slot this
## person holds there, the pose hint the venue gives that slot (read by the
## pose machine as an input), the venue's current label for the status line,
## and whether the venue is in an EVENT (the visit then lasts the phase).
var venue_pose := ""
var _venue_slot := -1
var _venue_label := ""
var _venue_event := false
## One-shot per visit: when an EVENT starts elsewhere, re-pick once (and go
## if the event venue wins) rather than every step -- re-picking the same
## venue every step would be a finish/claim livelock.
var _event_checked := false
## The routine block (day x 24 + start hour) whose activity this person last
## served — a festival day serves meal / bathroom / wash blocks once.
var _routine_mark: float = -1.0
## The live-venue phase this person's current seat was chosen for (-99 =
## none); a traveller re-targets when the venue moves past it.
var _venue_phase_seen := -99
## The current SOCIAL stint is a wander (look at the view), not a circle.
var _wandering := false
## The current mingle stint is a COMFORT stint (NpcComfort kind: shade /
## warm / shelter; "" = an ordinary social one), and whether it is in this
## person's own bed. Transient, cleared in _finish.
var _comfort := ""
var _comfort_bed := false
## DJ: metres the deck stands above the ground, and when the set ends.
## Transient (the bridge re-casts after a load).
var perform_elev := 0.0
## On a piece of furniture (a bench seat, a daybed): how high the person sits
## or lies while DOING the visit. Transient, like perform_elev.
var seat_elev := 0.0
var _perform_until := 0.0
## A burn ROLE ("dj", "flow", "sandman", "redirect") and, for a fire-flow
## performer, the moving lane (VenueCrowd.orbit_point). Transient.
var perform_role := ""
var _orbit: Dictionary = {}
## Turned back at a burn's line: hold this spot (no live-venue re-seat) until
## the effigy's phase moves on.
var _redirect_hold := -1
## PEAK EXPERIENCE start (abs hours), NAN when not peaking — written by the
## bridge's PeakField each tick, the authority. Transient.
var peak_since := NAN
## How close to a peak (0..1, NpcPeak buzz) and how many peakers nearby are
## feeding it — PeakField's, pushed each tick. Transient, display only.
var peak_buzz := 0.0
var peak_fed := 0
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
## The claimed sleep space's own yaw (radians; NAN = none) — a bed's long
## axis, so the sleeper lies IN it rather than at the walk-in angle. Same
## TRANSIENT lifecycle rule as face_anchor: cleared in _finish (which
## release_claims routes through) and in the engine's _catch_up.
var lie_yaw: float = NAN
## When this agent started waiting at a team-lift pickup for the rest of the
## crew (NAN = not waiting). TRANSIENT, same _finish/_catch_up lifecycle.
var pickup_wait_h: float = NAN
## How close the lift crew must stand to the load before the carry leaves.
const TEAM_LIFT_GATHER_M := 3.0
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
## Whether finishing there calls for stepping aside (_maybe_loiter): a visit
## does, waking up in one's own bed does not. Transient, like face_anchor.
var _loiter_ok := false
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
## The pool is NAME_POOL plus the player's own names (Settings → NPC →
## Names, NpcDisplayPrefs.custom_names) — adding names re-deals everyone's,
## since a name is a hash into the pool.
static func name_for(agent_id: String) -> String:
	# Just the name ("Spark", not "Spark 25"); the id stays the unique key
	# everywhere. A camp ("<seed>_npc_<i>") walks the pool with a stride
	# coprime to its size from a per-camp start, so nobody in one camp shares
	# a name until the camp outgrows the pool; other camps may repeat names,
	# the way a real crowd does.
	var pool := name_pool()
	var n := pool.size()
	var cut := agent_id.rfind("_npc_")
	if cut >= 0 and agent_id.substr(cut + 5).is_valid_int():
		var idx := int(agent_id.substr(cut + 5))
		var stride := 17
		while _gcd(stride, n) != 1:
			stride += 2
		return str(pool[posmod(absi(hash(agent_id.substr(0, cut))) + idx * stride, n)])
	return str(pool[absi(hash(agent_id)) % n])


static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := a % b
		a = b
		b = t
	return a


static var _name_pool: Array = []
static var _name_pool_gen := -1


## NAME_POOL + the custom names not already in it (cached per prefs change).
static func name_pool() -> Array:
	var gen := NpcDisplayPrefs.generation()
	if gen != _name_pool_gen or _name_pool.is_empty():
		_name_pool_gen = gen
		_name_pool = NAME_POOL.duplicate()
		var have := {}
		for n in NAME_POOL:
			have[str(n).to_lower()] = true
		for n in NpcDisplayPrefs.custom_names():
			if not have.has(n.to_lower()):
				have[n.to_lower()] = true
				_name_pool.append(n)
	return _name_pool


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
	# One source of truth with the FSM's own billing (_consumes_for), so the
	# possessed-agent path bills the same kinds — including meal-first eating.
	var consumes: Dictionary = _consumes_for(activity, ctx)
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


## Per-person scatter on the body's clock: hunger, thirst and bladder rise
## up to ±RATE_JITTER faster or slower than the table, deterministic per id
## (NpcHash), identical in both tiers. Without it a camp with the same
## schedule and the same rates trips every threshold in lockstep and the
## whole camp walks to the toilets together.
const RATE_JITTER := 0.25
const JITTERED_NEEDS: Array = ["hunger", "thirst", "bladder"]


## Words for an activity summary key (both tiers' summary()["activities"]
## and blocked needs): "hunger" -> "eating", "-> thirst" -> "going to drink",
## "queue bladder" -> "queueing for the toilet". The keys stay as they are
## (the selftests and the camp ledger read them); this is for display only.
const ACTIVITY_WORDS := {
	"hunger": ["eating", "a meal"], "thirst": ["drinking", "water"],
	"bladder": ["at the toilet", "the toilet"], "sleep": ["sleeping", "bed"],
	"hygiene": ["washing", "a shower"], "enrichment": ["out having fun", "a venue"],
	"chore": ["working", "work"], "mingle": ["hanging out", "friends"],
	"chat": ["chatting", "friends"], "wander": ["wandering", "a wander"],
	"perform": ["performing", "the stage"], "shade": ["in the shade", "shade"],
	"warm": ["warming up", "a fire"], "shelter": ["sheltering", "cover"],
	"free": ["free time", "free time"], "idle": ["idle", "nothing"],
}


static func activity_words(key: String) -> String:
	if key.begins_with("-> "):
		var w: Array = ACTIVITY_WORDS.get(key.substr(3), [])
		return "on the way to %s" % (str(w[1]) if w.size() > 1 else key.substr(3))
	if key.begins_with("queue "):
		var q: Array = ACTIVITY_WORDS.get(key.substr(6), [])
		return "queueing for %s" % (str(q[1]) if q.size() > 1 else key.substr(6))
	var d: Array = ACTIVITY_WORDS.get(key, [])
	return str(d[0]) if not d.is_empty() else key.replace("_", " ")


## Memo of rate_scale_for: it is asked per need per step (full tier) and per
## event (light tier), and each answer is a string build + hash. Pure in its
## inputs, so a memo is exact; cleared past MEMO_MAX so it cannot grow forever.
static var _rate_memo: Dictionary = {}
const RATE_MEMO_MAX := 30000


static func rate_scale_for(agent_id: String, need: String) -> float:
	if not JITTERED_NEEDS.has(need):
		return 1.0
	var key := agent_id + "|" + need
	var hit: Variant = _rate_memo.get(key)
	if hit != null:
		return hit
	var v := 1.0 + (NpcHash.unit01(agent_id, "rate_" + need) * 2.0 - 1.0) * RATE_JITTER
	if _rate_memo.size() >= RATE_MEMO_MAX:
		_rate_memo.clear()
	_rate_memo[key] = v
	return v


func _decay(dt_hours: float) -> void:
	var asleep := state == State.DOING and activity == "sleep"
	for n in NEEDS:
		var v := float(needs.get(n, 0.0))
		var rate := float(RISE_PER_H[n]) * rate_scale_for(id, n)
		if n == "sleep" and asleep:
			v -= SLEEP_RECOVER_PER_H * dt_hours
		elif asleep and (n == "hunger" or n == "thirst" or n == "bladder"):
			v += rate * 0.35 * dt_hours  # metabolic slowdown overnight
		else:
			v += rate * dt_hours
		needs[n] = clampf(v, 0.0, 1.0)


func _step_doing(abs_hours: float, dt_hours: float, ctx: Dictionary) -> Dictionary:
	if activity == CHORE_ACTIVITY:
		return _step_chore(abs_hours, dt_hours, ctx)
	# Starved supply blocks the activity: abort and retry later — the need is
	# NOT satisfied and keeps rising (the two-way-coupling payoff).
	var consumes: Dictionary = _consumes_for(activity, ctx)
	if activity != "sleep":
		var starved: Dictionary = ctx.get("starved", {})
		for kind in consumes:
			if starved.get(kind, false):
				_mark_blocked(activity, abs_hours)
				retry_at[activity] = abs_hours + RETRY_BACKOFF_H + rng.randf_range(0.0, 0.2)
				_finish(ctx, false)
				return {}
	if activity == "sleep":
		# The wake test is the ONLY terminator: one begun night can only end
		# at wake. Ending on the need bottoming out (`<= 0.02`) released the
		# bed, re-rolled the need UP in _satisfy, and the routine tier
		# re-issued sleep with no cooldown — 6-12 lie-down/get-up cycles per
		# agent per night. _decay clamps needs at 0, so a bottomed-out need is
		# safe to sleep through.
		if _hour(ctx) >= _wake_hour(ctx) and _hour(ctx) < night_from_h(_sleep_start(ctx)):
			_satisfy("sleep")
			_finish(ctx, true)
		return {}
	if activity == "enrichment" and SpaceTypes.LIVE_VENUE_TYPES.has(target_space_type):
		_update_live_venue(abs_hours, ctx)
		if state != State.DOING:
			return {}   # re-seated by a WALK: the trip's step takes over
	if activity == PERFORM_ACTIVITY and not _orbit.is_empty():
		# A fire-flow performer: round the lane with it, facing along it.
		var o_pos := VenueCrowd.orbit_point(_orbit, abs_hours)
		pos = o_pos
		target_pos = o_pos
		var tang := VenueCrowd.ccw_tangent(_orbit.get("centre", o_pos), o_pos)
		face_anchor = o_pos + tang * 10.0
	# The effigy was lit while this person was somewhere else: look round
	# ONCE, and leave for it if its pull wins.
	if (activity == "enrichment" or activity == NpcSocial.ACTIVITY) \
			and bool(ctx.get("event_active", false)) \
			and not _venue_event and not _event_checked:
		_event_checked = true
		var win := _venue_pick(ctx)
		if not win.is_empty() and float(win.get("pull", 0.0)) >= NpcVenueState.EVENT_THRESHOLD \
				and str(win.get("id", "")) != target_space_id:
			_finish(ctx, false)
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
	# The DJ plays the set through: only a need at its very top takes them
	# off the decks (CrowdCohort uses the same bar).
	var bar := PERFORM_URGENT if activity == PERFORM_ACTIVITY else URGENT
	if activity == LOITER_ACTIVITY:
		# Hanging out is the idle re-pick in all but name: any need past its
		# own threshold ends it (the light tier's FREE dawdle bar).
		bar = float(THRESHOLD.get(urgent, URGENT)) if not urgent.is_empty() else URGENT
	if not urgent.is_empty() and urgent != activity and float(needs.get(urgent, 0.0)) >= bar:
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
		# On-the-job training rides the same applied-hours: a required-skill
		# chore teaches its skill, fast beside somebody qualified, slowly alone.
		var train: Callable = ctx.get("train_skill", Callable())
		if train.is_valid():
			train.call(id, board.find(chore_id), applied)
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
	# Walking to the effigy when it is lit (or its phase moves on): the seat
	# picked at departure belongs to the OLD phase. Re-target once per phase
	# change so the walker heads for their ring seat instead of finishing the
	# trip to a stale spot first.
	if activity == "enrichment" and target_space_type == "effigy":
		_retarget_effigy(abs_hours, ctx)
	var travel_h := _remaining_travel_hours()
	if travel_h >= dt_hours:
		_walk(dt_hours, ctx)
		return {}
	# Arrived mid-step: begin the activity at the actual arrival instant
	# (space already claimed at selection time) and bill only the tail of the
	# step spent doing it.
	# Account for the last leg BEFORE teleporting to the target, or a trip
	# that completes inside one step contributes nothing.
	var final_leg := NpcNav.path_remaining_m(pos, path, path_idx) \
			if path_idx < path.size() else pos.distance_to(target_pos)
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
			var chore_rec: Dictionary = board.find(chore_id) as Dictionary
			var carry_to: Dictionary = chore_rec.get("carry_to", {})
			if not carry_to.is_empty():
				# TEAM LIFT gather gate: a multi-worker carry only leaves the
				# pickup once the whole lift crew has hands on the load —
				# otherwise the first arriver walks the crate off alone while
				# the others mime a pickup at an empty spot. Bounded wait
				# (QUORUM_WAIT_H, same patience as a muster): if the crew
				# never shows, release and back off rather than standing at a
				# crate forever.
				var min_w := int(chore_rec.get("min_workers", 1))
				if min_w > 1:
					var near_fn: Callable = ctx.get("crew_near", Callable())
					var near_n := min_w
					if near_fn.is_valid():
						near_n = int(near_fn.call(chore_id, pos, TEAM_LIFT_GATHER_M))
					if near_n < min_w:
						if is_nan(pickup_wait_h):
							pickup_wait_h = abs_hours
						face_anchor = pos   # look at the load while waiting
						if abs_hours - pickup_wait_h > QUORUM_WAIT_H:
							retry_at[CHORE_ACTIVITY] = abs_hours + RETRY_BACKOFF_H
							_finish(ctx, false)
						return {}
				pickup_wait_h = NAN
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
	if activity == PERFORM_ACTIVITY:
		# The DJ plays until the set ends — no routine block cuts it short.
		dur = 0.0
		activity_ends_h = maxf(_perform_until, arrive_abs + 1.0 / 60.0)
	if activity == NpcSocial.ACTIVITY:
		# A stint's length is NpcSocial's hash (both tiers agree on it) —
		# or NpcComfort's for a comfort stint.
		dur = 0.0
		activity_ends_h = arrive_abs + (NpcComfort.stint_h(id, arrive_abs) if not _comfort.is_empty() \
			else NpcSocial.stint_h(id, arrive_abs, _wandering))
		var r0: NpcRoutine = ctx.get("routine")
		if r0 != null and not routine_kind.is_empty():
			var left0 := r0.hours_left_in_block(_hour(ctx), routine_offset_h, _rkey(r0, ctx))
			if left0 > 0.0:
				activity_ends_h = minf(activity_ends_h, abs_hours + left0)
	if activity == LOITER_ACTIVITY:
		# Hashed, not drawn: a loiter is a cosmetic step aside, and a draw
		# here would move the RNG stream for everything after it (the
		# separation-neutrality pin measured 3 % of water from exactly that).
		dur = 0.0
		activity_ends_h = arrive_abs + 0.25 * (0.85 + 0.4 * NpcHash.unit01(id, "loiterd%d" % int(floor(arrive_abs * 4.0))))
	if dur > 0.0:
		activity_ends_h = arrive_abs + dur * rng.randf_range(0.85, 1.25)
		# Never run past the end of the scheduled block that asked for this.
		# The 5-minute bathroom visit is only 5 minutes if the schedule can
		# actually reclaim the person afterwards.
		var routine: NpcRoutine = ctx.get("routine")
		if routine != null and not routine_kind.is_empty():
			var left := routine.hours_left_in_block(_hour(ctx), routine_offset_h, _rkey(routine, ctx))
			if left > 0.0:
				activity_ends_h = minf(activity_ends_h, abs_hours + left)
		# A programmed set ends when the programme ends: nobody stands at a
		# dark stage for the rest of their hour.
		if activity == "enrichment" and _enrichment_cap_h > 0.0:
			activity_ends_h = minf(activity_ends_h, arrive_abs + _enrichment_cap_h)
	if activity == "sleep":
		# One night = one session: the wake hour is this session's absolute
		# end. Presentation-only (the wake test in _step_doing is the real
		# terminator) but the pose machine's dwell budget reads it — a stale
		# value left over from the previous activity made the lie-down snap.
		# Cross-midnight-safe via fposmod; deliberately NOT clamped to
		# hours_left_in_block (a night is one session, not a routine visit).
		activity_ends_h = abs_hours + fposmod(_wake_hour(ctx) - _hour(ctx), 24.0)
		return {}
	var consumes: Dictionary = _consumes_for(activity, ctx)
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


## Meal-first draw rate: 2 meals/h over the same 0.5 h sitting = 1 meal
## (~0.5 kg raw-food equivalent — the same mass the raw path bills).
const MEAL_PER_H := 2.0


## What an activity consumes right now. Enrichment is normally free, but a
## fire circle burns real biomass — joy has a cost the player must supply.
## Eating is MEAL-FIRST: when the habitat's meal input is wired to a stocked
## counter (ctx.meal_available, computed once per tick by the bridge), a
## sitting draws prepared meals; otherwise the long-standing raw-food draw —
## so a camp with no kitchen behaves byte-identically to before meals existed.
func _consumes_for(act: String, ctx: Dictionary = {}) -> Dictionary:
	var base: Dictionary = (ACTIVITIES.get(act, {}) as Dictionary).get("consumes", {})
	if act == "enrichment" and target_space_type == "fire_circle":
		return {"biomass": FIRE_BIOMASS_KG_H}
	if act == "hunger" and bool(ctx.get("meal_available", false)):
		return {"meal": MEAL_PER_H, "water": float(base.get("water", 8.0))}
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
	# Never walk to a goal inside a fire perimeter (a bed in a tent next to the
	# effigy): the nearest spot outside it instead (NpcNav.outside).
	# A burn role (a sandman's post) is the exception: it is inside the line.
	var safe := dest if not perform_role.is_empty() else NpcNav.outside(dest, ctx.get("no_go", []))
	if safe != dest:
		if target_pos == dest:
			target_pos = safe
		dest = safe
	var planner: Callable = ctx.get("plan_path", Callable())
	if not planner.is_valid():
		return
	var p: Variant = planner.call(pos, dest, from_key, to_key, hash(id))
	# A space-pair route that starts farther away than the goal is not this
	# trip's (a re-seat at the venue already reached got the camp->venue
	# route and walked back across the fire) — CrowdCohort._go does the same.
	if p is PackedVector2Array and (p as PackedVector2Array).size() > 0 \
			and (p as PackedVector2Array)[0].distance_to(pos) > pos.distance_to(dest):
		p = null
	if p is PackedVector2Array and (p as PackedVector2Array).size() > 0:
		var pv: PackedVector2Array = (p as PackedVector2Array).duplicate()
		# A space-pair route is SHARED (cached for the first walker's goal):
		# the legs joining it to THIS person's start and goal go round any
		# fire, never across it (CrowdCohort._go does the same).
		var circles: Array = ctx.get("no_go", [])
		if not circles.is_empty():
			var det_end := NpcNav.detour(pv[pv.size() - 1], dest, circles)
			if det_end.size() > 0:
				pv.append_array(det_end)
			var det_start := NpcNav.detour(pos, pv[0], circles)
			if det_start.size() > 1:
				det_start.remove_at(det_start.size() - 1)
				det_start.append_array(pv)
				pv = det_start
		path = pv
		path_idx = 0
		return
	# No route (grid baking, or the query budget spent): a straight line —
	# but never THROUGH the fire. One waypoint round the perimeter.
	var det := NpcNav.detour(pos, dest, ctx.get("no_go", []))
	if det.size() > 0:
		path = det
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
		var blk := routine.block_at(_hour(ctx), routine_offset_h, _rkey(routine, ctx))
		var kind := str(blk.get("kind", NpcRoutine.FREE))
		if _attending_burn(ctx):
			# The burn outranks the routine (critical needs came first).
			kind = NpcRoutine.ENRICHMENT
		# A festival day serves a meal / bathroom / wash block ONCE; the rest
		# of the block is leisure (NpcRoutine.serves_once — CrowdCohort does
		# the same off its routine_mark).
		var mark: float = floor((abs_hours - _hour(ctx)) / 24.0) * 24.0 + float(blk.get("start_h", -1.0))
		if NpcRoutine.ONCE_KINDS.has(kind) and absf(_routine_mark - mark) < 1e-6 and routine.meals_once():
			kind = routine.leisure_kind()
		var scheduled := NpcRoutine.activity_for(kind)
		# Mirror _pick's slept-enough guard: the SLEEP block runs to ~08:00
		# while people wake 6.0-7.5, and re-issuing sleep with the need near 0
		# walked the whole camp back to bed every tick. Fall through — NOT an
		# absorbing return — so between wake and 08:00 people drink, eat and
		# idle near the beds: the camp wakes gradually.
		if scheduled == "sleep" and float(needs.get("sleep", 0.0)) < 0.25:
			scheduled = ""
		# A festival morning: up before the SLEEP block ends, they go and do
		# something social rather than idle by their beds (CrowdCohort._decide
		# makes the same switch).
		if kind == NpcRoutine.SLEEP and routine.serves_once() \
				and not NpcRoutine.in_sleep_window(_hour(ctx), _sleep_start(ctx), _wake_hour(ctx)):
			kind = NpcRoutine.SOCIAL
			scheduled = ""
		# ALL HANDS (the site deployment schedule): while this camp has a
		# deploy or pack-up on, the board outranks every leisure block — a
		# festival day is SOCIAL all afternoon and `_begin_social` always
		# finds something to do, so without this nobody ever reached tier 3
		# and the site was never built. Sleep, meals and the other needs
		# still come first (they are above and `scheduled` below).
		if bool(ctx.get("all_hands", false)) and NpcComfort.LEISURE_KINDS.has(kind) \
				and abs_hours >= float(retry_at.get(CHORE_ACTIVITY, 0.0)) \
				and _begin_chore(abs_hours, ctx):
			routine_kind = kind
			return
		# Weather as an attractor on LEISURE (NpcComfort) — the same hashed
		# response and spots CrowdCohort._decide uses. Never during an EVENT.
		if NpcComfort.LEISURE_KINDS.has(kind) and not bool(ctx.get("event_active", false)):
			var cm := NpcComfort.respond(id, abs_hours, ctx.get("comfort", {}), kind)
			if not cm.is_empty():
				routine_kind = kind
				if _begin_comfort(cm, abs_hours, ctx):
					return
		# Nobody leaves at the bell: each person lingers a little into a new
		# block (deterministic per person, day and block), so a camp trickles
		# to dinner instead of arriving as one column.
		# The gathering block goes through VENUE CHOICE (stage / effigy /
		# fire circle by programme and taste — the same rule the light tier
		# uses), not "the nearest fire circle".
		if scheduled == "enrichment":
			routine_kind = kind
			if abs_hours >= float(retry_at.get("enrichment", 0.0)):
				_begin_enrichment(abs_hours, ctx)
				if state != State.IDLE:
					return
			scheduled = ""
		# Festival leisure: always something social (NpcSocial) — the same
		# hashed choice and spots the light tier makes in CrowdCohort.
		if kind == NpcRoutine.SOCIAL:
			routine_kind = kind
			_begin_social(abs_hours, ctx)
			if state != State.IDLE:
				return
		if not scheduled.is_empty() and abs_hours >= float(retry_at.get(scheduled, 0.0)):
			routine_kind = kind
			_begin_need(scheduled, abs_hours, ctx)
			if state != State.IDLE:
				_routine_mark = mark
			return
		if kind == NpcRoutine.WORK:
			routine_kind = kind
			if abs_hours >= float(retry_at.get(CHORE_ACTIVITY, 0.0)) \
					and _begin_chore(abs_hours, ctx):
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
		if state != State.IDLE:
			return
	# Nothing at all: do not hang about ON the spot just used.
	_maybe_loiter(abs_hours, ctx)


## Finished at a space with nothing to do next, still standing on its slot
## (which is the next person's now): walk a few metres off and hang out there
## (LOITER_ACTIVITY). The light tier does the same (CrowdCohort._loiter_spot).
## Only from a space: an idler already clear of one stays put.
func _maybe_loiter(abs_hours: float, ctx: Dictionary) -> void:
	if at_space_id.is_empty() or not _loiter_ok or controlled_by_peer != 0 or not loiter_enabled:
		return
	var registry: SpaceRegistry = ctx.get("registry")
	if registry == null:
		return
	var c: Variant = registry.cached_position(at_space_id)
	if not (c is Vector2):
		var pos_of: Callable = ctx.get("pos_of", Callable())
		var space := registry.find_by_id(at_space_id)
		c = pos_of.call(space) if (pos_of.is_valid() and not space.is_empty()) else null
		if not (c is Vector2):
			return
	if pos.distance_to(c) > LOITER_NEAR_M:
		at_space_id = ""   # already clear of it; no more checks
		return
	var q := int(floor(abs_hours * 4.0))
	var a := NpcHash.unit01(id, "loiter%d" % q) * TAU
	var r := LOITER_MIN_M + NpcHash.unit01(id, "loiterr%d" % q) * LOITER_SPREAD_M
	var spot: Vector2 = (c as Vector2) + Vector2(cos(a), sin(a)) * r
	var walkable: Callable = ctx.get("walkable", Callable())
	if walkable.is_valid() and not bool(walkable.call(spot)):
		return
	trip_distance_m = 0.0
	activity = LOITER_ACTIVITY
	target_space_id = ""
	target_space_type = ""
	lie_yaw = NAN
	target_pos = spot
	face_anchor = Vector2.INF   # look wherever (the projection path)
	last_exposure = NpcWeatherGate.EXPOSURE_OUTDOOR
	_request_path(ctx, target_pos, at_space_id, "")
	state = State.TRAVELING


func _begin_need(need: String, abs_hours: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	var pos_of: Callable = ctx.get("pos_of", Callable())
	var ideal := PopTestPrefs.ideal_supply()
	if registry == null or not pos_of.is_valid():
		if ideal:
			_begin_virtual_need(need)
			return
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	var space_type := str((ACTIVITIES[need] as Dictionary).get("space", ""))
	# Assignment-aware: my own assigned space (a bed with my name on it) wins
	# outright; someone else's stays theirs while they are on the roster.
	# Bed is HOME: a sleeper looks for the sleep space nearest their own camp
	# (not nearest wherever the evening left them — that put people to bed in
	# the neighbours' camp), and a crowd already asleep there is no reason to
	# go elsewhere: sleepers pile up.
	var from := pos
	var spread := true
	if need == "sleep":
		spread = false
		var ch: Variant = ctx.get("camp_home", null)
		if ch is Vector2:
			from = ch
	var space := registry.nearest_space_by(space_type, from, pos_of, true, id,
		ctx.get("agent_live", Callable()), spread)
	if space.is_empty():
		if ideal:
			_begin_virtual_need(need)
			return
		# Nothing tagged for this need (or everything is full) — this is a
		# BLOCKED need, and it costs double morale.
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H + rng.randf_range(0.0, 0.15)
		return
	var sid := str(space.get("id", ""))
	if not registry.claim(sid, id):
		if ideal:
			_begin_virtual_need(need)
			return
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	var p: Variant = pos_of.call(space)
	if not (p is Vector2):
		registry.release(sid, id)
		if ideal:
			_begin_virtual_need(need)
			return
		_mark_blocked(need, abs_hours)
		retry_at[need] = abs_hours + RETRY_BACKOFF_H
		return
	_clear_blocked(need)
	trip_distance_m = 0.0
	activity = need
	var from_key := at_space_id
	target_space_id = sid
	target_space_type = space_type
	# A sleep space with an orientation (a bed) fixes the lying yaw — the
	# sleeper lies ALONG it, not at whatever angle they walked in on.
	lie_yaw = NAN
	if need == "sleep":
		var yaw_of: Callable = ctx.get("yaw_of", Callable())
		if yaw_of.is_valid():
			lie_yaw = float(yaw_of.call(space))
	# Stand in this agent's own slot rather than on the space's centre point,
	# or every occupant converges on one spot. Purely positional — the space is
	# already claimed, so this changes nobody's consumption.
	target_pos = _standing_spot(registry, sid, p, ctx)
	# A sleep AREA with shelters in it (a camp): lie down INSIDE a tent, pod,
	# van or RV — slot k wraps round the beds — rather than on the ground.
	if need == "sleep":
		var bed_of: Callable = ctx.get("bed_spot_of", Callable())
		var bed: Variant = null
		if bed_of.is_valid():
			bed = bed_of.call(sid, registry.slot_index_for(sid, id))
		if bed is Dictionary and not (bed as Dictionary).is_empty():
			target_pos = (bed as Dictionary).get("pos", target_pos)
			lie_yaw = float((bed as Dictionary).get("yaw", lie_yaw))
		elif str((space.get("target", {}) as Dictionary).get("kind", "")) == "area":
			# A bare sleep AREA (no shelters): lie in rows along one axis
			# (SpaceRegistry.lying_offset_for_index) rather than 0.9 m apart
			# on the standing spiral at random yaws, which lay people through
			# each other.
			var yaw := SpaceRegistry.lying_yaw_for(sid)
			var lying: Vector2 = (p as Vector2) + SpaceRegistry.lying_offset_for_index(registry.slot_index_for(sid, id), yaw)
			var walkable: Callable = ctx.get("walkable", Callable())
			if not walkable.is_valid() or bool(walkable.call(lying)):
				target_pos = lying
				lie_yaw = yaw
	# Look at the space, not back down the corridor we walked in. The CENTRE,
	# deliberately, not our own slot — occupants of a fire circle should face
	# each other. Recomputed from the final position every tick, so the
	# unwalkable-slot fallback (which returns the plain centre) degrades to the
	# projection path rather than to a meaningless zero-length vector.
	face_anchor = p
	_take_seat(ctx, sid, registry.slot_index_for(sid, id))
	last_exposure = NpcWeatherGate.EXPOSURE_SHELTERED
	_request_path(ctx, p, from_key, sid)
	state = State.TRAVELING


## IDEAL SUPPLY (PopTestPrefs): the need is met where the person stands —
## no space, no claim, no walk. The activity still runs for its duration and
## still consumes, so the demand it generates is the optimal demand curve;
## only the WHERE is waived.
func _begin_virtual_need(need: String) -> void:
	_clear_blocked(need)
	trip_distance_m = 0.0
	activity = need
	target_space_id = ""
	target_space_type = str((ACTIVITIES.get(need, {}) as Dictionary).get("space", ""))
	lie_yaw = NAN
	target_pos = pos
	face_anchor = Vector2.INF
	last_exposure = NpcWeatherGate.EXPOSURE_SHELTERED
	_clear_path()
	state = State.TRAVELING


## Enrichment can be satisfied at ANY enrichment space; pick by distance minus
## a social pull toward spaces that already have people at them.
func _begin_enrichment(abs_hours: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	var pos_of: Callable = ctx.get("pos_of", Callable())
	if registry == null or not pos_of.is_valid():
		retry_at["enrichment"] = abs_hours + RETRY_BACKOFF_H
		return
	# ONE venue rule for every tier (NpcVenueChoice): a venue's programme says
	# what it is doing now, the person's taste says how much that appeals,
	# distance and company do the rest. A fire circle with no fuel is skipped
	# rather than looped on.
	var win := _venue_pick(ctx)
	var best: Dictionary = registry.find_by_id(str(win.get("id", ""))) if not win.is_empty() else {}
	var best_type := str(win.get("type", ""))
	var best_pos: Vector2 = win.get("pos", Vector2.ZERO) if not win.is_empty() else Vector2.ZERO
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
	var st2 := _venue_state(best, ctx)
	_venue_slot = registry.slot_index_for(sid2, id)
	_venue_label = str(st2.get("label", ""))
	_venue_event = bool(st2.get("event", false))
	# A LIVE venue (effigy, stage with a set on) seats people by choreography
	# — the ring round the fire, the fan in front of the speakers — rather
	# than the registry's packing spiral.
	var extra2 := _venue_extra(sid2, best_type, ctx)
	var live := VenueCrowd.venue_spot(best_type, best_pos, _venue_slot, st2,
		float(ctx.get("abs_hours", 0.0)), _venue_seed(), extra2)
	face_anchor = best_pos
	if live != Vector2.INF:
		target_pos = live
	else:
		# An ordinary venue: the friend group's own cluster round it (the
		# same spot CrowdCohort._go_to_venue gives this person).
		var gs := VenueCrowd.group_spot(best_type, best_pos,
			float(extra2.get("r", 0.0)) + VenueCrowd.round_gap(best_type, extra2), id,
			registry.cluster_index_for(sid2, id))
		target_pos = gs["pos"]
		face_anchor = gs["face"]
		_take_seat(ctx, sid2, _venue_slot)
	venue_pose = VenueCrowd.venue_pose(best_type, _venue_slot, st2, _venue_seed())
	_venue_phase_seen = int(st2.get("phase", -1))
	last_exposure = NpcWeatherGate.EXPOSURE_OUTDOOR if SpaceTypes.OUTDOOR_TYPES.has(best_type) \
			else NpcWeatherGate.EXPOSURE_SHELTERED
	# A programmed set (or a fire's phase) ends when IT says, not when the
	# hour is up.
	if bool(st2.get("programmed", false)) and float(st2.get("ends_h", -1.0)) > 0.0:
		_enrichment_cap_h = float(st2["ends_h"])
	else:
		_enrichment_cap_h = -1.0
	state = State.TRAVELING


## The winning venue for this person right now (NpcVenueChoice over every
## enrichment space), or {} when none is reachable.
func _venue_pick(ctx: Dictionary) -> Dictionary:
	var registry: SpaceRegistry = ctx.get("registry")
	var pos_of: Callable = ctx.get("pos_of", Callable())
	if registry == null or not pos_of.is_valid():
		return {}
	var starved: Dictionary = ctx.get("starved", {})
	var candidates: Array = []
	for stype in SpaceTypes.ENRICHMENT_TYPES:
		if str(stype) == "fire_circle" and bool(starved.get("biomass", false)):
			continue
		for item in registry.spaces_of_type(str(stype)):
			var space: Dictionary = item
			var sid := str(space.get("id", ""))
			var p: Variant = registry._position_for(space, pos_of)
			if not (p is Vector2):
				continue
			var st := _venue_state(space, ctx)
			candidates.append({"id": sid, "type": str(stype), "pos": p,
				"draw": float(st["draw"]), "pull": float(st.get("pull", 0.0)),
				"occupants": registry.occupant_count(sid),
				"capacity": int(space.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))})
	if _taste.is_empty():
		# Friends go out together: the GROUP's taste (NpcFriends).
		_taste = NpcVenueChoice.taste_for(NpcFriends.key_of(id))
	return NpcVenueChoice.pick(_taste, pos, candidates)


## The venue's live state: the bridge's per-tick resolver when present (it
## has the fire records), else the programme alone.
func _venue_state(space: Dictionary, ctx: Dictionary) -> Dictionary:
	var f: Callable = ctx.get("venue_state_of", Callable())
	if f.is_valid():
		var v: Variant = f.call(space)
		if v is Dictionary and not (v as Dictionary).is_empty():
			return v
	return NpcVenueState.resolve(space, _hour(ctx), float(ctx.get("abs_hours", 0.0)))


## Stage geometry from the bridge ({front, fwd}); {} for everything else.
func _venue_extra(sid: String, _stype: String, ctx: Dictionary) -> Dictionary:
	var f: Callable = ctx.get("venue_front_of", Callable())
	if f.is_valid():
		var v: Variant = f.call(sid)
		if v is Dictionary:
			return v
	return {}


func _venue_seed() -> float:
	return NpcHash.unit01(id, "venue")


## Re-seat this person at a LIVE venue every step: the fire's phase can change
## under them (ring -> circle -> embers), the circle itself MOVES, and a set
## can start or end. While the venue is in an EVENT the visit lasts the phase
## — the cap tracks the phase end, so the camp does not drift home mid-burn.
func _update_live_venue(abs_hours: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry == null or target_space_id.is_empty():
		return
	var space := registry.find_by_id(target_space_id)
	if space.is_empty():
		return
	var centre: Variant = registry.cached_position(target_space_id)
	if not (centre is Vector2):
		var pos_of: Callable = ctx.get("pos_of", Callable())
		centre = pos_of.call(space) if pos_of.is_valid() else null
		if not (centre is Vector2):
			return
	var st := _venue_state(space, ctx)
	if _venue_slot < 0:
		_venue_slot = registry.slot_index_for(target_space_id, id)
	if _redirect_hold >= 0:
		# Turned back at the line: watch from here until the phase moves on.
		if int(st.get("phase", -1)) == _redirect_hold:
			return
		_redirect_hold = -1
	var spot := VenueCrowd.venue_spot(target_space_type, centre, _venue_slot, st, abs_hours,
		_venue_seed(), _venue_extra(target_space_id, target_space_type, ctx))
	if spot != Vector2.INF and target_space_type != "effigy":
		# Another venue's crowd (a stage fan) never spills into a burning
		# effigy's fall zone: the seat moves to just outside it.
		spot = NpcNav.outside(spot, ctx.get("no_go", []))
	if spot != Vector2.INF:
		target_pos = spot
		# Round a burning fire — or the effigy's closing circle — the seat
		# MOVES: someone already at their ring's radius goes round with it.
		# Walking after it never arrives (the seat moves on while they walk,
		# and a walk skips the end-of-visit check) — measured, the fire's
		# dancers never went to bed; on the effigy circle, with a big full
		# tier (long substeps) the seat outran its walkers every step and they
		# chased it, facing in across the ring instead of along it. Late
		# arrivals off the ring still walk to it. (The light tier: S_CIRCLE
		# people on the ring keep circling — CrowdCohort._circle_step.)
		var ring_tol := 1.0 if target_space_type == "fire_circle" else 1.5
		var on_ring := VenueCrowd.is_circling(target_space_type, st) \
			and absf(pos.distance_to(centre) - spot.distance_to(centre)) <= ring_tol
		if not on_ring and pos.distance_to(spot) > RESEAT_WALK_M:
			# A phase change moved the seat across the venue (ring -> lane):
			# WALK there along a routed path — a teleport glides the body
			# straight through the fire. The claim and activity are kept;
			# arrival re-enters DOING and the next step re-seats as usual.
			_request_path(ctx, spot, at_space_id, target_space_id)
			state = State.TRAVELING
			return
		pos = spot
	venue_pose = VenueCrowd.venue_pose(target_space_type, _venue_slot, st, _venue_seed())
	_venue_phase_seen = int(st.get("phase", -1))
	_venue_label = str(st.get("label", ""))
	face_anchor = centre
	if VenueCrowd.is_circling(target_space_type, st) and spot != Vector2.INF:
		# Walking/dancing ROUND the fire: face the way the circle goes (the
		# light tier faces along its arc), not in at the centre.
		face_anchor = spot + VenueCrowd.ccw_tangent(centre, spot) * 10.0
	_venue_event = bool(st.get("event", false))
	if _venue_event and float(st.get("ends_h", -1.0)) > 0.0:
		activity_ends_h = maxf(activity_ends_h, abs_hours + float(st["ends_h"]))


## A traveller bound for the effigy: if its phase moved on since the seat was
## chosen (lit mid-trip), head for the new seat now.
func _retarget_effigy(abs_hours: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry == null or target_space_id.is_empty():
		return
	var space := registry.find_by_id(target_space_id)
	if space.is_empty():
		return
	var st := _venue_state(space, ctx)
	var ph := int(st.get("phase", -1))
	if ph == _venue_phase_seen:
		return
	_venue_phase_seen = ph
	var centre: Variant = registry.cached_position(target_space_id)
	if not (centre is Vector2):
		return
	if _venue_slot < 0:
		_venue_slot = registry.slot_index_for(target_space_id, id)
	var spot := VenueCrowd.venue_spot(target_space_type, centre, _venue_slot, st, abs_hours,
		_venue_seed(), _venue_extra(target_space_id, target_space_type, ctx))
	if spot == Vector2.INF or spot.distance_to(target_pos) <= RESEAT_WALK_M:
		return
	target_pos = spot
	venue_pose = VenueCrowd.venue_pose(target_space_type, _venue_slot, st, _venue_seed())
	_venue_event = bool(st.get("event", false))
	if _venue_event and float(st.get("ends_h", -1.0)) > 0.0:
		_enrichment_cap_h = float(st["ends_h"])
	_request_path(ctx, spot, at_space_id, target_space_id)


## A SOCIAL block (NpcSocial): a venue WITHOUT the enrichment gate, a stint in
## one of the camp's conversation circles, or a wander across the site. The
## choice and the spots are hashes of (id, camp, hour) — CrowdCohort makes the
## identical choice for the same person, so the tiers agree.
func _begin_social(abs_hours: float, ctx: Dictionary) -> void:
	var pick := NpcSocial.choice(id, abs_hours)
	if pick == "venue":
		_begin_enrichment(abs_hours, ctx)
		if state != State.IDLE:
			return
	var home_v: Variant = ctx.get("camp_home", null)
	var home: Vector2 = home_v if home_v is Vector2 else pos
	var seed_key := str(ctx.get("camp_seed", ""))
	if seed_key.is_empty():
		# Ids are "<seed>_npc_<i>" in both tiers; recover the camp's seed.
		var cut := id.rfind("_npc_")
		seed_key = id.substr(0, cut) if cut > 0 else id
	_wandering = pick == "wander"
	var spot := NpcSocial.wander_spot(id, home, abs_hours) if _wandering \
		else NpcSocial.mingle_spot(id, seed_key, home, abs_hours, int(ctx.get("camp_n", 0)))
	activity = NpcSocial.ACTIVITY
	target_space_id = ""
	target_space_type = ""
	target_pos = spot["pos"]
	face_anchor = spot["face"]
	venue_pose = "" if _wandering else "talk"
	last_exposure = NpcWeatherGate.EXPOSURE_OUTDOOR
	_request_path(ctx, target_pos, at_space_id, "")
	state = State.TRAVELING


## A comfort stint (NpcComfort): a shade / warmth spot from the bridge, or
## this person's own bed (a share of the rain; warmth with no fire about).
## Mirrors CrowdCohort._begin_comfort — same response, spot and length.
func _begin_comfort(kind: String, abs_hours: float, ctx: Dictionary) -> bool:
	var home_v: Variant = ctx.get("camp_home", null)
	var home: Vector2 = home_v if home_v is Vector2 else pos
	var at_bed := kind == NpcComfort.KIND_SHELTER and NpcComfort.shelters_at_bed(id, abs_hours)
	var spot: Dictionary = {}
	if not at_bed:
		var f: Callable = ctx.get("comfort_spot", Callable())
		if f.is_valid():
			spot = f.call(kind, home, id)
		if spot.is_empty():
			if kind == NpcComfort.KIND_SHADE:
				return false
			at_bed = true
	var dest := home
	var face := home
	if at_bed:
		var bf: Callable = ctx.get("home_bed_of", Callable())
		var b: Variant = bf.call(id) if bf.is_valid() else null
		dest = b if b is Vector2 else home + Vector2(cos(face_phase), sin(face_phase)) * 3.0
	else:
		dest = spot["pos"]
		face = spot["face"]
	var heat := float((ctx.get("comfort", {}) as Dictionary).get("heat", 0.0))
	activity = NpcSocial.ACTIVITY
	_comfort = kind
	_comfort_bed = at_bed
	_wandering = false
	target_space_id = ""
	target_space_type = ""
	target_pos = dest
	face_anchor = face
	venue_pose = NpcComfort.pose_for(kind, id, heat, at_bed)
	last_exposure = NpcWeatherGate.EXPOSURE_SHELTERED if kind != NpcComfort.KIND_WARM or at_bed \
		else NpcWeatherGate.EXPOSURE_OUTDOOR
	_request_path(ctx, target_pos, at_space_id, "")
	state = State.TRAVELING
	return true


## The clock moved back `d` hours (a scrub): move this person's pending
## times with it — state untouched (NpcPopulationEngine.tick).
func rebase_time(d: float) -> void:
	if activity_ends_h > 0.0:
		activity_ends_h += d
	if not is_nan(pickup_wait_h):
		pickup_wait_h += d
	for k in retry_at:
		retry_at[k] = float(retry_at[k]) + d


## Hard rain just began: leave an ordinary chat / dawdle / non-choreographed
## venue now so the next decision can take cover (CrowdCohort.wake_for_weather).
func wake_for_weather(ctx: Dictionary) -> bool:
	if state != State.DOING or controlled_by_peer != 0:
		return false
	var leisure := (activity == NpcSocial.ACTIVITY and _comfort.is_empty()) \
		or (activity == "enrichment" and VenueCrowd.rain_clears(target_space_type,
			bool(ctx.get("event_active", false))))
	if not leisure:
		return false
	_finish(ctx, false)
	return true


## Cast as a stage's DJ: walk to the middle of the stage and play until
## `until_h`, `spot.elev` m up on the deck, facing `spot.face`.
func begin_perform(spot: Dictionary, until_h: float, ctx: Dictionary) -> void:
	if controlled_by_peer != 0:
		return
	_finish(ctx, false)
	activity = PERFORM_ACTIVITY
	routine_kind = ""
	target_space_id = ""
	target_space_type = ""
	target_pos = spot.get("pos", pos)
	face_anchor = spot.get("face", target_pos + Vector2(0.0, 1.0))
	perform_role = str(spot.get("role", "dj"))
	match perform_role:
		"flow":
			venue_pose = VenueCrowd.POSE_FIREFLOW
		"sandman":
			venue_pose = VenueCrowd.POSE_KNEEL
		"redirect":
			venue_pose = VenueCrowd.POSE_REDIRECT
		_:
			venue_pose = VenueCrowd.POSE_DJ
	_orbit = spot.get("orbit", {})
	perform_elev = float(spot.get("elev", 0.0))
	_perform_until = until_h
	_venue_label = str(spot.get("label", ""))
	last_exposure = NpcWeatherGate.EXPOSURE_SHELTERED
	_request_path(ctx, target_pos, at_space_id, "")
	state = State.TRAVELING


## Social, needs met, nothing blocked, morale up (NpcPeak) — the same test
## CrowdCohort._vibing makes.
func vibing() -> bool:
	if state != State.DOING:
		return false
	if activity == NpcSocial.ACTIVITY:
		if _comfort_bed or _comfort == NpcComfort.KIND_SHELTER:
			return false
	elif activity != "enrichment" and activity != PERFORM_ACTIVITY:
		return false
	if morale < NpcPeak.ELIGIBLE_MORALE:
		return false
	return NpcPeak.needs_met(needs, blocked)


## Metres above the ground this person's FEET are (the DJ on the deck, or a
## seat on a bench or daybed).
func elev() -> float:
	if state != State.DOING:
		return 0.0
	if activity == PERFORM_ACTIVITY:
		return perform_elev
	return seat_elev


## A space on furniture offers seats (or beds): take slot `k`'s spot, the way
## it faces and its height. False when the space has none.
func _take_seat(ctx: Dictionary, sid: String, k: int) -> bool:
	seat_elev = 0.0
	var seat_of: Callable = ctx.get("seat_spot_of", Callable())
	if not seat_of.is_valid():
		return false
	var spot: Variant = seat_of.call(sid, k)
	if not (spot is Dictionary) or (spot as Dictionary).is_empty():
		return false
	var sp: Dictionary = spot
	var yaw := float(sp.get("yaw", 0.0))
	target_pos = sp.get("pos", target_pos)
	seat_elev = float(sp.get("elev", 0.0))
	# Godot's forward is -Z: a seat's yaw turns it to face (-sin, -cos).
	face_anchor = target_pos + Vector2(-sin(yaw), -cos(yaw)) * FACE_PROJECT_M
	if str(sp.get("kind", "")) == "lie":
		lie_yaw = yaw
	return true


## Part of a burn's turnout right now (VenueCrowd.attends)?
func _attending_burn(ctx: Dictionary) -> bool:
	return bool(ctx.get("event_active", false)) \
		and VenueCrowd.attends(id, str(ctx.get("burn_key", "")))


## Turned back at a burn's line by a sandman (the bridge's call): walk
## straight out past it, away from the fire. Someone bound for the burn
## watches from there until the phase moves on; anyone else stands at the line
## a moment and then carries on with their day.
func redirect_out(centre: Vector2, r: float, ctx: Dictionary) -> bool:
	if controlled_by_peer != 0 or activity == PERFORM_ACTIVITY or activity == "sleep":
		return false
	var d := pos - centre
	if d.length() < 0.01:
		d = Vector2(cos(NpcHash.unit01(id, "redir") * TAU), sin(NpcHash.unit01(id, "redir") * TAU))
	var dest := centre + d.normalized() * (r + 1.2)
	if activity == "enrichment" and target_space_type == "effigy":
		var space: Dictionary = (ctx.get("registry") as SpaceRegistry).find_by_id(target_space_id) \
			if ctx.get("registry") != null else {}
		_redirect_hold = int(_venue_state(space, ctx).get("phase", -1)) if not space.is_empty() else -1
		target_pos = dest
		face_anchor = centre
		_clear_path()
		state = State.TRAVELING
		return true
	_finish(ctx, false)
	activity = NpcSocial.ACTIVITY
	_wandering = true
	target_pos = dest
	face_anchor = centre
	venue_pose = ""
	_clear_path()
	state = State.TRAVELING
	return true


## Walk out of a fire perimeter (the bridge calls this for anyone standing
## inside a burning effigy's safe radius who is not AT the effigy — those
## re-seat themselves). True when they were moved.
func evacuate_from(centre: Vector2, r: float, ctx: Dictionary) -> bool:
	if controlled_by_peer != 0 or pos.distance_to(centre) >= r:
		return false
	# Sleepers too: nobody spends the burn in a tent inside the fall zone.
	if target_space_type == "effigy":
		return false
	var d := pos - centre
	if d.length() < 0.01:
		d = Vector2(cos(NpcHash.unit01(id, "evac") * TAU), sin(NpcHash.unit01(id, "evac") * TAU))
	var dest := centre + d.normalized() * (r + 2.0)
	_finish(ctx, false)
	# Stand at the perimeter and watch for a stint, then decide as usual.
	activity = NpcSocial.ACTIVITY
	_wandering = true
	target_pos = dest
	face_anchor = centre
	venue_pose = ""
	_clear_path()   # a straight radial walk: the nav marks the circle blocked
	state = State.TRAVELING
	return true


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
			var in_window := NpcRoutine.in_sleep_window(_hour(ctx), _sleep_start(ctx), _wake_base(ctx))
			var r_bar: NpcRoutine = ctx.get("routine")
			var early_bar := r_bar.early_bed_bar(float(THRESHOLD["sleep"])) if r_bar != null \
				else float(THRESHOLD["sleep"])
			# In a burn's turnout: stay up for it (CrowdCohort._decide too).
			var up := _attending_burn(ctx)
			if up:
				early_bar = STAY_UP_BAR
			if not in_window and v < early_bar:
				continue
			if in_window and v < (STAY_UP_BAR if up else 0.25):
				continue  # slept enough — don't go straight back to bed
		elif v < (BURN_HUNGER_BAR if n == "hunger" and _attending_burn(ctx) else float(THRESHOLD[n])):
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
	# An EVENT (the effigy burn — NpcVenueState.event) pulls people out whether
	# or not they felt like gathering; only the free-time gate still applies.
	if not bool(ctx.get("event_active", false)) \
			and float(needs.get("enrichment", 0.0)) < float(THRESHOLD["enrichment"]):
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
	if need == NpcSocial.ACTIVITY:
		needs["enrichment"] = NpcSocial.relieved_enrichment(float(needs.get("enrichment", 0.0)))
		return
	if need.is_empty() or not needs.has(need):
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
	lie_yaw = NAN
	pickup_wait_h = NAN
	venue_pose = ""
	_venue_slot = -1
	_venue_label = ""
	_venue_event = false
	_event_checked = false
	_venue_phase_seen = -99
	_wandering = false
	_comfort = ""
	_comfort_bed = false
	perform_elev = 0.0
	seat_elev = 0.0
	_perform_until = 0.0
	perform_role = ""
	_orbit = {}
	_redirect_hold = -1
	# Remember the space we finished at: the next trip starts there, which is
	# what lets the space-pair route cache hit.
	at_space_id = target_space_id
	# Step aside after a space VISIT only — never away from one's own bed
	# (waking up in a tent), nor again after hanging out.
	_loiter_ok = activity != "sleep" and activity != LOITER_ACTIVITY
	activity = ""
	activity_ends_h = 0.0
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


## A live-venue re-seat beyond this is walked (routed), not teleported.
const RESEAT_WALK_M := 4.0

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


func _wake_hour(ctx: Dictionary = {}) -> float:
	# Per-agent jittered wake time off the ROUTINE's wake base (NpcRoutine
	# .wake_base_h — 06:00 for the default day, 07:30 for a festival).
	return _wake_base(ctx) + (float(hash(id) % 97) / 97.0) * 1.5


func _wake_base(ctx: Dictionary) -> float:
	var r: NpcRoutine = ctx.get("routine")
	return fposmod(r.wake_base_h(SLEEP_END_H) + _personal_shift(r, ctx), 24.0) if r != null else SLEEP_END_H


## How far this person's whole day sits from the routine as written: the
## phase offset plus their personal shift (NpcRoutine.day_shift). The sleep
## window and the wake hour move WITH it, or a person shifted an hour later
## wakes inside their own SLEEP block (the tiers then disagree on what to do).
func _personal_shift(r: NpcRoutine, ctx: Dictionary) -> float:
	return routine_offset_h + NpcRoutine.day_shift(
		r.night_key(id, float(ctx.get("abs_hours", 0.0)), routine_offset_h))


func _hour(ctx: Dictionary) -> float:
	return fposmod(float(ctx.get("hour_of_day", 12.0)), 24.0)


## This person's routine day (NpcRoutine.personal_blocks): the same key the
## light tier computes, so both tiers live the same personal schedule.
func _rkey(r: NpcRoutine, ctx: Dictionary) -> String:
	return r.day_key(id, float(ctx.get("abs_hours", 0.0)), routine_offset_h)


## When the sleep need may send this person to bed: the routine's SLEEP
## block start when it has one, else SLEEP_START_H.
## When "night" begins for the instant-daytime-nap rule: SLEEP_START_H, or
## this person's own (shifted) sleep start when that falls earlier in the
## evening — a bedtime of 20:30 is a night, not a nap that ends at once.
## (A routine whose sleep starts after midnight keeps SLEEP_START_H.)
static func night_from_h(sleep_start: float) -> float:
	return sleep_start if sleep_start > 12.0 and sleep_start < SLEEP_START_H else SLEEP_START_H


func _sleep_start(ctx: Dictionary) -> float:
	var r: NpcRoutine = ctx.get("routine")
	return fposmod(r.sleep_start_h(SLEEP_START_H) + _personal_shift(r, ctx), 24.0) if r != null else SLEEP_START_H


# --- readouts ---------------------------------------------------------------

## Player-facing one-liner: what this person is doing right now.
func status_line() -> String:
	match state:
		State.DOING:
			if activity == "sleep":
				return "asleep"
			if activity == CHORE_ACTIVITY:
				return "working"
			if activity == PERFORM_ACTIVITY:
				return "DJing" + ((" (%s)" % _venue_label) if not _venue_label.is_empty() else "")
			if activity == NpcSocial.ACTIVITY:
				if not _comfort.is_empty():
					return NpcComfort.status_for(_comfort, _comfort_bed)
				return "taking in the view" if _wandering else "chatting with camp-mates"
			if activity == LOITER_ACTIVITY:
				return "hanging out"
			if activity == "enrichment":
				if target_space_type == "effigy":
					match venue_pose:
						VenueCrowd.POSE_DANCE, VenueCrowd.POSE_WALK:
							return "circling the fire"
						VenueCrowd.POSE_SIT, VenueCrowd.POSE_LIE:
							return "watching the burn"
					return ("%s (Effigy)" % _venue_label) if not _venue_label.is_empty() \
						else "at the effigy"
				if target_space_type == "stage" and venue_pose == VenueCrowd.POSE_RAVE:
					return "raving (Bass Stage)"
				return "%s (%s)" % [_enrich_verb(target_space_type),
						SpaceTypes.label(target_space_type)]
			return "%s (%s)" % [_verb(activity), SpaceTypes.label(_space_of(activity))]
		State.TRAVELING:
			if activity == CHORE_ACTIVITY:
				return "carrying a load" if chore_leg == 1 else "heading to work"
			if activity == PERFORM_ACTIVITY:
				return "heading to the decks"
			if activity == LOITER_ACTIVITY:
				return "stepping aside"
			if activity == NpcSocial.ACTIVITY:
				match _comfort:
					NpcComfort.KIND_SHADE: return "heading for shade"
					NpcComfort.KIND_WARM: return "heading in to warm up" if _comfort_bed else "heading to the fire"
					NpcComfort.KIND_SHELTER: return "running for cover"
				return "wandering" if _wandering else "joining friends"
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
		"stage": return "at the bass stage"
		"effigy": return "at the effigy"
		"temple": return "at the temple"
		"center_camp": return "at center camp"
		"art": return "looking at art"
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
