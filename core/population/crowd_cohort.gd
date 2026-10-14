class_name CrowdCohort
extends RefCounted

## The LIGHT population tier: one camp's people as a discrete-event crowd.
##
## `NpcPopulationEngine` steps every agent's FSM on every substep — A* paths,
## separation, chores, crews — which is right for the camp you are standing in
## and far too much for the forty you are not. This class simulates the same
## people with the same needs, routine, venues and morale maths, but touches a
## person only when something HAPPENS to them: they arrive, they finish, a
## queue moves, a set ends, an hour of sleep passes. Between events a need is a
## line (`value + rate × dt`) and a position is a segment (`a → b` over
## `t0 → t1`), so the renderer can draw a thousand of them from two numbers
## each and never ask the CPU where anyone is.
##
## Consumption is tier-independent by construction: the activity table, the
## need rise rates, the satisfy values, the morale step and the venue rule are
## NpcAgent's / NpcMorale's / NpcVenueChoice's own, and the equivalence
## selftest pins a camp's daily totals against the full engine. What this tier
## does NOT do: A* (people walk straight lines with a per-person lane offset),
## separation, chores with effects, crews. Work is credited statistically
## (`take_work_hours`). Deterministic: every random draw is a hash of the
## person's id and a per-person counter, and due events fire in (time, index)
## order.
##
## Pure: the registry, routine, starved kinds and the hour arrive in `ctx`.

signal agent_departed(agent_id: String, display_name: String, reason: String)
signal collapse_warning(risk: float)
signal colony_collapsed()
signal colony_deserted(cause: String)
signal agent_lost(agent_id: String, display_name: String, reason: String)

const TIER := "light"
const SNAPSHOT_VERSION := 3

## States (one byte each).
const S_IDLE := 0
const S_TRAVEL := 1
const S_DOING := 2
const S_QUEUE := 3
## The circle dance round the collapsed effigy: a chain of short arc
## segments (one event each), so the GPU glides the person round the ring
## and the sim touches them every CIRCLE_STEP_H.
const S_CIRCLE := 4
const CIRCLE_STEP_H := 0.02
## Activities (one byte each); ACT_NAMES maps them to NpcAgent's strings.
const A_NONE := 0
const A_HUNGER := 1
const A_THIRST := 2
const A_BLADDER := 3
const A_SLEEP := 4
const A_HYGIENE := 5
const A_ENRICH := 6
const A_WORK := 7
const A_FREE := 8
## A SOCIAL block's stint (NpcSocial): chatting in a camp circle or out on a
## wander. Zero consumption; eases the enrichment need on completion.
const A_MINGLE := 9
## The DJ's set (the bridge casts one person per live stage; see perform()).
const A_PERFORM := 10
const ACT_NAMES: Array = ["", "hunger", "thirst", "bladder", "sleep", "hygiene",
	"enrichment", NpcAgent.CHORE_ACTIVITY, "", NpcSocial.ACTIVITY, NpcAgent.PERFORM_ACTIVITY]
const ACT_OF_NEED: Dictionary = {"hunger": A_HUNGER, "thirst": A_THIRST,
	"bladder": A_BLADDER, "sleep": A_SLEEP, "hygiene": A_HYGIENE, "enrichment": A_ENRICH}

const CATCHUP_JUMP_H := NpcPopulationEngine.CATCHUP_JUMP_H
const CATCHUP_MORALE_DRIFT := NpcPopulationEngine.CATCHUP_MORALE_DRIFT
const COLLAPSE_FLOOR_FRAC := NpcPopulationEngine.COLLAPSE_FLOOR_FRAC
const COLLAPSE_WARN_RISK := NpcPopulationEngine.COLLAPSE_WARN_RISK
const SPAWN_RING_M := NpcPopulationEngine.SPAWN_RING_M
## A heartbeat bounds how long anyone goes without a morale step.
const HEARTBEAT_H := 1.0
## Queue re-poll cadence and patience at a full space.
const QUEUE_POLL_H := 0.05
const QUEUE_MAX_H := 0.5
## Idle dawdle while free with nothing to do.
const FREE_MIN_H := 0.25
const FREE_MAX_H := 0.75
## Work is done in chunks so the heartbeat can run.
const WORK_CHUNK_H := 0.5
## A bound portapotty bank receives this much per visit (no flush water).
const PORTAPOTTY_BLACKWATER_L := 1.0
## Lane offset so a column of walkers does not share one line.
const LANE_OFFSET_M := 0.8
const MAX_EVENT_PASSES := 12

var seed_key := ""
var home := Vector2.ZERO
var home_slots := PackedVector2Array()
var routine: NpcRoutine = null
var consequence: String = NpcConsequence.DEFAULT
## Is there work on this camp's board? Without it a WORK block falls through
## to gathering, exactly as NpcAgent._step_idle does when the board is empty —
## the bridge sets it from the parked engine's board.
var has_work := false

# --- per-person arrays -------------------------------------------------------
var ids := PackedStringArray()
var alive := PackedByteArray()
var ax := PackedFloat32Array()
var az := PackedFloat32Array()
var bx := PackedFloat32Array()
var bz := PackedFloat32Array()
var t0 := PackedFloat64Array()
var t1 := PackedFloat64Array()
var needs := PackedFloat32Array()      # n × 6, NpcAgent.NEEDS order, value at need_t
var need_t := PackedFloat64Array()
var morale := PackedFloat32Array()
var quit := PackedFloat32Array()
var morale_t := PackedFloat64Array()
var state := PackedByteArray()
var act := PackedByteArray()
var space_id := PackedStringArray()
var space_type := PackedStringArray()
var end_h := PackedFloat64Array()      # when the current activity ends
var next_h := PackedFloat64Array()     # next event
var blocked := PackedByteArray()       # bitmask over NpcAgent.NEEDS
var queue_since := PackedFloat64Array()
var offset_h := PackedFloat32Array()   # routine phase offset
var rng_n := PackedInt32Array()        # per-person draw counter
## The routine block (day × 24 + start hour) this person last served, so a
## block asks for its activity ONCE: finishing breakfast inside the EAT block
## must not send them straight back for a second one.
var routine_mark := PackedFloat64Array()

var _n := 0
## The routine's wake base (NpcRoutine.wake_base_h), refreshed by _decide.
var _wake_base := NpcAgent.SLEEP_END_H
## This person's (shifted) sleep start, refreshed by _decide alongside it.
var _sleep_start_cur := NpcAgent.SLEEP_START_H
var _last_abs_h := NAN
var _starved: Dictionary = {}
var _accum: Dictionary = {}            # kind -> qty this tick (camp demand)
var _venue_flows: Dictionary = {}      # graph_item_id -> {kind: signed qty}
var _work_h := 0.0
var _initial_roster := 0
var _departures: Array = []
var _losses := 0
var _collapse_warned := false
var _collapsed := false
var _leaving: Array = []
var _catchups := 0
## People whose slot (segment / pose / alive) changed since the renderer last
## asked. Every fired event marks its person; catch-up and restore mark all.
var _dirty: Dictionary = {}
var _all_dirty := true

## LIVE venues (VenueCrowd): the slot this person holds at their venue, the
## venue's pose hint for it (VPOSE_* codes), and the venue phase they were
## seated for — a phase change re-seats them. Transient: never snapshotted
## (the next event re-derives all three).
var vslot := PackedInt32Array()
var vpose := PackedByteArray()
var vphase := PackedByteArray()
## Multi-leg routes (the nav grid's A* through the bridge's plan_path): the
## polyline this person is walking and the index of the leg in progress.
## Transient like the venue arrays. `last_space` keys the route cache.
var legs: Array = []
var leg_i := PackedInt32Array()
var last_space := PackedStringArray()
## The point a person faces while DOING something (the venue's middle, the
## conversation circle's middle, the view on a wander); NAN = toward home.
## Transient like the venue arrays.
var fx := PackedFloat32Array()
var fz := PackedFloat32Array()
const VPOSE_NONE := 0
const VPOSE_STAND := 1
const VPOSE_SIT := 2
const VPOSE_LIE := 3
const VPOSE_DANCE := 4
const VPOSE_WALK := 5
const VPOSE_CLAP := 6
const VPOSE_RAVE := 7
const VPOSE_CHEER := 8
const VPOSE_DJ := 9
const VPOSE_TALK := 10
const VPOSE_LOUNGE := 11
const VPOSE_GAZE := 12
const VPOSE_KNEEL := 13
const VPOSE_REDIRECT := 14
const VPOSE_FIREFLOW := 15
## Appended (indices are stored per person — never reorder).
const VPOSE_SWAY := 16
const VPOSE_NAMES: Array = ["", VenueCrowd.POSE_STAND, VenueCrowd.POSE_SIT, VenueCrowd.POSE_LIE,
	VenueCrowd.POSE_DANCE, VenueCrowd.POSE_WALK, VenueCrowd.POSE_CLAP, VenueCrowd.POSE_RAVE,
	VenueCrowd.POSE_CHEER, VenueCrowd.POSE_DJ, VenueCrowd.POSE_TALK, VenueCrowd.POSE_LOUNGE,
	VenueCrowd.POSE_GAZE, VenueCrowd.POSE_KNEEL, VenueCrowd.POSE_REDIRECT, VenueCrowd.POSE_FIREFLOW,
	VenueCrowd.POSE_SWAY]
## Comfort stints (NpcComfort): which kind this person is on (index into
## CKIND_NAMES; 0 = none), plus CKIND_BED when it is in their own bed.
## Transient, like the venue arrays.
var ckind := PackedByteArray()
const CKIND_NAMES: Array = ["", NpcComfort.KIND_SHADE, NpcComfort.KIND_WARM, NpcComfort.KIND_SHELTER]
const CKIND_BED := 8
## The DJ: index -> {elev (m above the ground), sid}. Transient.
var _perform: Dictionary = {}
## PEAK EXPERIENCE: when this person started peaking (abs hours), NAN when
## not. Written by the bridge's PeakField every tick (it is the authority);
## read by the renderer (the green glow) and the dots. Transient.
var peak_since := PackedFloat64Array()
## How close to a peak, quantised to NpcPeak.BUZZ_STEPS (a step change re-writes
## the slot: the green shimmer building on the body), and the peakers feeding
## it. Transient, from the bridge.
var peak_buzz := PackedByteArray()
var peak_fed := PackedByteArray()

## Pose codes read by crowd_figure.gdshader.
const POSE_STAND := 0
const POSE_WALK := 1
const POSE_SIT := 2
const POSE_LIE := 3
const POSE_DANCE := 4
const POSE_WORK := 5
const POSE_QUEUE := 6
const POSE_RAVE := 7
const POSE_TALK := 8
const POSE_CHEER := 9
const POSE_DJ := 10
## FUCK YES!!! — the peak samba (a peaker on their feet at a venue or a hang).
const POSE_PEAK := 11
## Sitting on the GROUND cross-legged (meals, venues, a cold pit) — POSE_SIT
## (a chair) is the portapotty's; propped back on the arms, legs out; the
## burn roles; looking up at the effigy.
const POSE_CROSS := 12
const POSE_LOUNGE := 13
const POSE_KNEEL := 14
const POSE_REDIRECT := 15
const POSE_FIREFLOW := 16
const POSE_GAZE := 17
## A light dance on the spot (a fire with a stage's music carrying over).
const POSE_SWAY := 18


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## Same id scheme as the full engine ("<seed_key>_npc_<i>"), so beds, names
## and colours line up whichever tier a camp is in. `slots` are where people
## sleep (household anchors); without them a ring round `home` is used.
func configure(count: int, key: String, home_pos: Vector2,
		slots: PackedVector2Array = PackedVector2Array()) -> void:
	count = clampi(count, 1, 5000)
	seed_key = key
	home = home_pos
	_n = count
	_resize()
	for i in count:
		ids[i] = "%s_npc_%d" % [key, i]
		alive[i] = 1
		var spawn := _slot_for(i)
		ax[i] = spawn.x
		az[i] = spawn.y
		bx[i] = spawn.x
		bz[i] = spawn.y
		# The full engine seeds initial needs from hash(id); mirror it.
		var r := RandomNumberGenerator.new()
		r.seed = hash(ids[i])
		for k in 6:
			needs[i * 6 + k] = r.randf_range(0.05, 0.45)
		needs[i * 6 + 5] = 1.0   # un-enriched, like NpcAgent.make
		morale[i] = NpcMorale.START_MORALE
		offset_h[i] = NpcRoutine.offset_for(ids[i])
		next_h[i] = NAN
		routine_mark[i] = -1.0
	if slots.size() > 0:
		home_slots = slots
		for i in count:
			var s := _slot_for(i)
			ax[i] = s.x
			az[i] = s.y
			bx[i] = s.x
			bz[i] = s.y
	_initial_roster = count
	_departures = []
	_last_abs_h = NAN
	if routine == null:
		routine = NpcRoutine.default_day()


## Change the roster size IN PLACE: everyone already here keeps their
## position, needs, morale and plans. Growing appends new people exactly as
## configure() would mint them (same ids, seeding and beds); shrinking drops
## the highest indices and releases what they held. This is what the festival
## population slider calls — a rebuild respawned the whole camp at home.
func resize(count: int, registry: SpaceRegistry = null) -> void:
	count = clampi(count, 1, 5000)
	if count == _n:
		return
	var old := _n
	if count < old:
		for i in range(count, old):
			if registry != null:
				registry.release_all_for_agent(ids[i])
			_dirty.erase(i)
		_n = count
		_resize()
	else:
		_n = count
		_resize()
		var t := _last_abs_h
		for i in range(old, count):
			ids[i] = "%s_npc_%d" % [seed_key, i]
			alive[i] = 1
			var spawn := _slot_for(i)
			ax[i] = spawn.x
			az[i] = spawn.y
			bx[i] = spawn.x
			bz[i] = spawn.y
			t0[i] = 0.0
			t1[i] = 0.0
			var r := RandomNumberGenerator.new()
			r.seed = hash(ids[i])
			for k in 6:
				needs[i * 6 + k] = r.randf_range(0.05, 0.45)
			needs[i * 6 + 5] = 1.0
			need_t[i] = t if not is_nan(t) else 0.0
			morale[i] = NpcMorale.START_MORALE
			morale_t[i] = need_t[i]
			quit[i] = 0.0
			state[i] = S_IDLE
			act[i] = A_NONE
			space_id[i] = ""
			space_type[i] = ""
			end_h[i] = -1.0
			next_h[i] = t if not is_nan(t) else NAN
			blocked[i] = 0
			offset_h[i] = NpcRoutine.offset_for(ids[i])
			rng_n[i] = 0
			routine_mark[i] = -1.0
			vslot[i] = -1
			vpose[i] = VPOSE_NONE
			vphase[i] = 0
			legs[i] = null
			leg_i[i] = 0
			last_space[i] = ""
	_initial_roster = maxi(alive_count(), 1)
	_all_dirty = true


func _resize() -> void:
	ids.resize(_n)
	alive.resize(_n)
	ax.resize(_n)
	az.resize(_n)
	bx.resize(_n)
	bz.resize(_n)
	t0.resize(_n)
	t1.resize(_n)
	needs.resize(_n * 6)
	need_t.resize(_n)
	morale.resize(_n)
	quit.resize(_n)
	morale_t.resize(_n)
	state.resize(_n)
	act.resize(_n)
	space_id.resize(_n)
	space_type.resize(_n)
	end_h.resize(_n)
	next_h.resize(_n)
	blocked.resize(_n)
	queue_since.resize(_n)
	offset_h.resize(_n)
	rng_n.resize(_n)
	routine_mark.resize(_n)
	vslot.resize(_n)
	vpose.resize(_n)
	vphase.resize(_n)
	legs.resize(_n)
	leg_i.resize(_n)
	last_space.resize(_n)
	var old_f := fx.size()
	fx.resize(_n)
	fz.resize(_n)
	for k in range(old_f, _n):
		fx[k] = NAN
		fz[k] = NAN
	var old_c := ckind.size()
	ckind.resize(_n)
	for k in range(old_c, _n):
		ckind[k] = 0
	var old_p := peak_since.size()
	peak_since.resize(_n)
	for k in range(old_p, _n):
		peak_since[k] = NAN
	peak_buzz.resize(_n)
	peak_fed.resize(_n)
	for k in range(old_p, _n):
		peak_buzz[k] = 0
		peak_fed[k] = 0
	for k in _perform.keys():
		if int(k) >= _n:
			_perform.erase(k)


func _slot_for(i: int) -> Vector2:
	if home_slots.size() > 0:
		# More people than beds: the extras pile in beside a bed's owner
		# (the same offsets the full tier uses).
		return home_slots[i % home_slots.size()] \
			+ SpaceRegistry.pile_offset(i / home_slots.size(), 0.0)
	var ang := TAU * float(i) / float(maxi(_n, 1))
	return home + Vector2(cos(ang), sin(ang)) * SPAWN_RING_M * (0.5 + 0.5 * float(i % 3))


## Deterministic 0..1 draw: a hash of the id and a per-person counter.
func _rand(i: int) -> float:
	var k := rng_n[i]
	rng_n[i] = k + 1
	return NpcHash.unit01(ids[i], str(k))


func count() -> int:
	return _n


func alive_count() -> int:
	var c := 0
	for i in _n:
		if alive[i] == 1:
			c += 1
	return c


func agent_index(agent_id: String) -> int:
	for i in _n:
		if ids[i] == agent_id:
			return i
	return -1


# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

## Where person i is at sim time t (on their current segment).
func pos_at(i: int, t: float) -> Vector2:
	var a := Vector2(ax[i], az[i])
	if state[i] != S_TRAVEL and state[i] != S_CIRCLE:
		return a
	var span := t1[i] - t0[i]
	if span <= 1e-9:
		return Vector2(bx[i], bz[i])
	var u := clampf((t - t0[i]) / span, 0.0, 1.0)
	return a.lerp(Vector2(bx[i], bz[i]), u)


func set_starved(kinds: Array) -> void:
	_starved = {}
	for k in kinds:
		_starved[str(k)] = true


func _need_rate(i: int, k: int) -> float:
	var n := str(NpcAgent.NEEDS[k])
	var rate := float(NpcAgent.RISE_PER_H[n]) * NpcAgent.rate_scale_for(ids[i], n)
	var asleep := state[i] == S_DOING and act[i] == A_SLEEP
	if asleep:
		if n == "sleep":
			return -NpcAgent.SLEEP_RECOVER_PER_H
		if n == "hunger" or n == "thirst" or n == "bladder":
			return rate * 0.35
	return rate


## Advance person i's needs to t along their current lines.
func _materialize(i: int, t: float) -> void:
	var dt := t - need_t[i]
	if dt <= 0.0:
		need_t[i] = t
		return
	for k in 6:
		needs[i * 6 + k] = clampf(needs[i * 6 + k] + _need_rate(i, k) * dt, 0.0, 1.0)
	need_t[i] = t


func _need(i: int, name: String) -> float:
	return needs[i * 6 + NpcAgent.NEEDS.find(name)]


func _set_need(i: int, name: String, v: float) -> void:
	needs[i * 6 + NpcAgent.NEEDS.find(name)] = clampf(v, 0.0, 1.0)


func _needs_dict(i: int) -> Dictionary:
	var d := {}
	for k in 6:
		d[NpcAgent.NEEDS[k]] = needs[i * 6 + k]
	return d


func _blocked_dict(i: int) -> Dictionary:
	var d := {}
	for k in 6:
		if blocked[i] & (1 << k):
			d[NpcAgent.NEEDS[k]] = true
	return d


func _is_blocked(i: int, name: String) -> bool:
	return (blocked[i] & (1 << NpcAgent.NEEDS.find(name))) != 0


func _mark_blocked(i: int, name: String) -> void:
	blocked[i] = blocked[i] | (1 << NpcAgent.NEEDS.find(name))


func _clear_blocked(i: int, name: String) -> void:
	blocked[i] = blocked[i] & ~(1 << NpcAgent.NEEDS.find(name))


func _update_morale(i: int, t: float, ctx: Dictionary) -> void:
	var dt := t - morale_t[i]
	morale_t[i] = t
	if dt <= 0.0:
		return
	var exposure := 0.0
	if state[i] == S_DOING and act[i] == A_ENRICH and SpaceTypes.OUTDOOR_TYPES.has(space_type[i]):
		exposure = NpcWeatherGate.exposure_morale_drain(ctx.get("weather", {}),
			NpcWeatherGate.EXPOSURE_OUTDOOR)
	morale[i] = NpcMorale.step(morale[i], dt, _needs_dict(i), _blocked_dict(i),
		_need(i, "enrichment"), exposure)
	quit[i] = NpcMorale.step_quit_pressure(quit[i], morale[i], dt)
	if NpcMorale.wants_to_leave(quit[i]) and not _leaving.has(i):
		_leaving.append(i)


func _hour_at(ctx: Dictionary, t: float) -> float:
	return fposmod(float(ctx.get("hour_of_day", 12.0)) - (float(ctx.get("abs_hours", t)) - t), 24.0)


# ---------------------------------------------------------------------------
# Tick: fire every due event in (time, index) order
# ---------------------------------------------------------------------------

## ctx: {registry, hour_of_day, abs_hours, starved?, weather, meal_available}.
## Returns the camp's time-averaged demand {kind: qty/h} for the flow engine.
func tick(abs_h: float, ctx_in: Dictionary) -> Dictionary:
	if _n == 0 or alive_count() == 0:
		return {}
	var ctx := ctx_in.duplicate()
	ctx["abs_hours"] = abs_h
	if is_nan(_last_abs_h):
		_last_abs_h = abs_h
		for i in _n:
			need_t[i] = abs_h
			morale_t[i] = abs_h
			if is_nan(next_h[i]):
				next_h[i] = abs_h
		return {}
	var dt := abs_h - _last_abs_h
	if dt < 0.0:
		# Scrub back: FREEZE — nobody's state changes — but every pending
		# time moves back with the clock, so play resumes from here. Left
		# absolute, a meal begun before an 85-day rewind ended 85 days later:
		# the Walton burn had 250 people "eating" through it.
		_rebase_times(dt)
		_last_abs_h = abs_h
		return {}
	if dt == 0.0:
		return {}
	_accum = {}
	_leaving = []
	if dt > CATCHUP_JUMP_H:
		_catchups += 1
		_catch_up(abs_h, dt, ctx)
		_last_abs_h = abs_h
		_process_departures(abs_h, ctx)
		return {}
	for _pass in MAX_EVENT_PASSES:
		var due: Array = []
		for i in _n:
			if alive[i] == 1 and next_h[i] <= abs_h:
				due.append(i)
		if due.is_empty():
			break
		due.sort_custom(func(p, q):
			if absf(next_h[p] - next_h[q]) > 1e-9:
				return next_h[p] < next_h[q]
			return p < q)
		for i in due:
			var t := maxf(next_h[i], _last_abs_h)
			_fire(i, t, ctx)
	# Nobody may be left with a stale event (a bug guard, not a schedule).
	for i in _n:
		if alive[i] == 1 and next_h[i] <= abs_h:
			next_h[i] = abs_h + HEARTBEAT_H
	_process_departures(abs_h, ctx)
	_last_abs_h = abs_h
	var demand := {}
	for k in _accum:
		demand[k] = float(_accum[k]) / dt
	return demand


func _fire(i: int, t: float, ctx: Dictionary) -> void:
	_dirty[i] = true
	match state[i]:
		S_TRAVEL:
			_arrive(i, t, ctx)
		S_DOING:
			# At a LIVE venue the venue speaks first: an EVENT phase holds the
			# person (the cap moves), a phase change re-seats them, the
			# collapse starts the circle. Only then does the clock get a say.
			if act[i] == A_ENRICH and SpaceTypes.LIVE_VENUE_TYPES.has(space_type[i]) 					and _service_live_venue(i, t, ctx):
				pass
			elif act[i] == A_PERFORM and t < end_h[i] - 1e-6 and _perform.has(i) \
					and not ((_perform[i] as Dictionary).get("orbit", {}) as Dictionary).is_empty():
				_orbit_step(i, t)
			elif t >= end_h[i] - 1e-6:
				_finish_activity(i, t, ctx)
			else:
				_heartbeat(i, t, ctx)
		S_QUEUE:
			_poll_queue(i, t, ctx)
		S_CIRCLE:
			_circle_step(i, t, ctx)
		_:
			_decide(i, t, ctx)


func _heartbeat(i: int, t: float, ctx: Dictionary) -> void:
	_materialize(i, t)
	_update_morale(i, t, ctx)
	# A desperate need interrupts anything but the activity serving it; free
	# time and solo work yield sooner (the full tier re-picks every substep
	# while idle, and solo work preempts at CHORE_PREEMPT_FLOOR).
	# Sleep is never interrupted: the full tier's wake test is its ONLY
	# terminator (a sleeper's bladder clamps at 1.0 and waits for morning).
	var urgent := _most_urgent(i) if act[i] != A_SLEEP else ""
	if not urgent.is_empty() and ACT_OF_NEED.get(urgent, -1) != act[i]:
		var bar := NpcAgent.URGENT
		# A mingle stint is an ACTIVITY in the full tier (only URGENT ends it
		# early), unlike a FREE dawdle, which is the full tier's idle re-pick.
		if act[i] == A_FREE:
			bar = float(NpcAgent.THRESHOLD.get(urgent, 1.0))
		elif act[i] == A_WORK:
			bar = maxf(float(NpcAgent.THRESHOLD.get(urgent, 1.0)), NpcAgent.CHORE_PREEMPT_FLOOR)
		elif act[i] == A_PERFORM:
			bar = NpcAgent.PERFORM_URGENT
		if _need(i, urgent) >= bar:
			_release(i, ctx)
			_decide(i, t, ctx)
			return
	next_h[i] = minf(end_h[i], t + HEARTBEAT_H)


func _most_urgent(i: int) -> String:
	var best := ""
	var best_x := 0.0
	for n in NpcAgent.CRITICAL_NEEDS:
		if n in NpcAgent.NON_INTERRUPTING:
			continue
		var thr := float(NpcAgent.THRESHOLD.get(n, 1.0))
		var v := _need(i, str(n))
		if v < thr:
			continue
		var x := (v - thr) / maxf(1.0 - thr, 0.01)
		if best.is_empty() or x > best_x:
			best_x = x
			best = str(n)
	return best


## Tiers 1–2 of NpcAgent._pick: the most pressing CRITICAL need past its
## threshold (sleep only in its window), else hygiene.
func _pick(i: int, hour: float, sleep_start: float = NpcAgent.SLEEP_START_H,
		early_bar: float = -1.0, stay_up: bool = false) -> String:
	if early_bar < 0.0:
		early_bar = float(NpcAgent.THRESHOLD["sleep"])
	var best := ""
	var best_v := 0.0
	for n in NpcAgent.CRITICAL_NEEDS:
		var v := _need(i, str(n))
		if n == "sleep":
			var in_window := NpcRoutine.in_sleep_window(hour, sleep_start, _wake_base)
			if not in_window and v < early_bar:
				continue
			if in_window and v < (NpcAgent.STAY_UP_BAR if stay_up else 0.25):
				continue
		elif v < (NpcAgent.BURN_HUNGER_BAR if stay_up and n == "hunger" else float(NpcAgent.THRESHOLD[n])):
			continue
		if v > best_v:
			best_v = v
			best = str(n)
	if best.is_empty() and _need(i, "hygiene") >= float(NpcAgent.THRESHOLD["hygiene"]):
		best = "hygiene"
	return best


# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------

func _decide(i: int, t: float, ctx: Dictionary) -> void:
	_materialize(i, t)
	_update_morale(i, t, ctx)
	state[i] = S_IDLE
	act[i] = A_NONE
	var hour := _hour_at(ctx, t)
	# The sleep need's window follows the routine's SLEEP block (NpcRoutine
	# .sleep_start_h), so a festival camp is up for the set and the burn.
	var r0: NpcRoutine = ctx.get("routine", routine)
	# The person's whole-day shift moves their sleep window too (as in
	# NpcAgent._personal_shift).
	var pshift := offset_h[i] + NpcRoutine.day_shift(r0.night_key(ids[i], t, offset_h[i])) if r0 != null else 0.0
	var sleep_start := fposmod(r0.sleep_start_h(NpcAgent.SLEEP_START_H) + pshift, 24.0) if r0 != null else NpcAgent.SLEEP_START_H
	_sleep_start_cur = sleep_start
	_wake_base = fposmod(r0.wake_base_h(NpcAgent.SLEEP_END_H) + pshift, 24.0) if r0 != null else NpcAgent.SLEEP_END_H
	# A burn on: this person's share of the TURNOUT stays up for it (the sleep
	# need waits until exhaustion) and leaves its routine for the effigy. It
	# never wakes anyone already asleep — a sleeper is not deciding.
	var attending := bool(ctx.get("event_active", false)) \
		and VenueCrowd.attends(ids[i], str(ctx.get("burn_key", "")))
	var bed_bar := r0.early_bed_bar(float(NpcAgent.THRESHOLD["sleep"])) if r0 != null else -1.0
	var need := _pick(i, hour, sleep_start, NpcAgent.STAY_UP_BAR if attending else bed_bar, attending)
	if not need.is_empty():
		if _go_for_need(i, t, need, ctx, hour):
			return
		# Blocked: retry later, the need keeps rising.
		next_h[i] = t + NpcAgent.RETRY_BACKOFF_H + _rand(i) * 0.2
		return
	var r: NpcRoutine = ctx.get("routine", routine)
	var rkey := r.day_key(ids[i], t, offset_h[i]) if r != null else ""
	var block := r.block_at(hour, offset_h[i], rkey) if r != null else {}
	var kind := str(block.get("kind", NpcRoutine.FREE))
	if attending:
		# The burn outranks the routine (needs still came first, above).
		kind = NpcRoutine.ENRICHMENT
	var left := r.hours_left_in_block(hour, offset_h[i], rkey) if r != null else 1.0
	# An EVENT venue (the effigy burn) pulls people out whether or not they
	# felt like gathering — the same waiver NpcAgent._wants_enrichment makes.
	var wants_venue := _need(i, "enrichment") >= float(NpcAgent.THRESHOLD["enrichment"]) \
		or bool(ctx.get("event_active", false))
	# NOTE: a block re-issues its activity for as long as it lasts, exactly as
	# NpcAgent._step_idle does (a second meal inside the same EAT block is
	# what the full tier does today — the equivalence contract follows it).
	var mark: float = floor((t - hour) / 24.0) * 24.0 + float(block.get("start_h", -1.0))
	# A festival day serves a meal / bathroom / wash block ONCE; the rest of
	# the block is leisure (NpcRoutine.serves_once, mirrored in NpcAgent).
	if r != null and NpcRoutine.ONCE_KINDS.has(kind) and absf(routine_mark[i] - mark) < 1e-6 \
			and r.serves_once():
		kind = NpcRoutine.SOCIAL
	# A festival morning: awake before the SLEEP block ends, people get up
	# and DO something (a chat, a stroll, a venue) instead of standing by
	# their beds until 09:30 (measured: 9-16 % of the crowd idle 06-12h).
	# NpcAgent._step_idle makes the same switch.
	if kind == NpcRoutine.SLEEP and r != null and r.serves_once():
		var wake0 := _wake_base + NpcHash.unit01(ids[i], "wake") * 1.5
		if not NpcRoutine.in_sleep_window(hour, sleep_start, wake0):
			kind = NpcRoutine.SOCIAL
	# Weather as an attractor on LEISURE (NpcComfort): the shade on a hot
	# afternoon, the fire on a cold night, a tarp or the tent in hard rain.
	# Never during an EVENT — the whole site turns out for the burn.
	if NpcComfort.LEISURE_KINDS.has(kind) and not bool(ctx.get("event_active", false)):
		var cm := NpcComfort.respond(ids[i], t, ctx.get("comfort", {}), kind)
		if not cm.is_empty() and _begin_comfort(i, t, cm, ctx, left):
			return
	match kind:
		NpcRoutine.SLEEP:
			# Only when the night and the need agree — the block runs past
			# the wake hour, and a just-woken person is not sent back to bed.
			var wake := _wake_base + NpcHash.unit01(ids[i], "wake") * 1.5
			var night := NpcRoutine.in_sleep_window(hour, sleep_start, wake)
			if night and _need(i, "sleep") > 0.25 and _go_for_need(i, t, "sleep", ctx, hour):
				routine_mark[i] = mark
				return
		NpcRoutine.BATHROOM:
			if _go_for_need(i, t, "bladder", ctx, hour, left):
				routine_mark[i] = mark
				return
		NpcRoutine.EAT:
			if _go_for_need(i, t, "hunger", ctx, hour, left):
				routine_mark[i] = mark
				return
		NpcRoutine.WASH:
			if _go_for_need(i, t, "hygiene", ctx, hour, left):
				routine_mark[i] = mark
				return
		NpcRoutine.WORK:
			if has_work:
				_start_work(i, t, minf(left, WORK_CHUNK_H), ctx)
				return
			# Nothing on the board: gather rather than stand still.
			if wants_venue and _go_to_venue(i, t, ctx, hour, left):
				return
		NpcRoutine.ENRICHMENT:
			if _go_to_venue(i, t, ctx, hour, left):
				routine_mark[i] = mark
				return
		NpcRoutine.SOCIAL:
			if _begin_social(i, t, ctx, hour, left):
				return
		_:
			if wants_venue and _go_to_venue(i, t, ctx, hour, left):
				return
	# Nothing to do: dawdle where we are — but not past the moment the urge
	# to gather crosses its bar. The full tier re-plans EVERY substep while
	# idle and goes to the fire right then; a fixed 15-45 min dawdle here had
	# the light tier gathering a third less (the morale gap the equivalence
	# pin sat right at). Needs are lines between events, so the crossing is
	# exact. (Only enrichment: waking at every need or block end re-issued
	# meals and cost ~20 % more food than the full tier.)
	act[i] = A_FREE
	state[i] = S_DOING
	var until := t + FREE_MIN_H + _rand(i) * (FREE_MAX_H - FREE_MIN_H)
	var ke := NpcAgent.NEEDS.find("enrichment")
	var ve := needs[i * 6 + ke]
	var te := float(NpcAgent.THRESHOLD["enrichment"])
	var re := _need_rate(i, ke)
	if re > 1e-9 and ve < te:
		until = minf(until, t + (te - ve) / re + 1e-4)
	end_h[i] = maxf(until, t + 1e-4)
	next_h[i] = end_h[i]


## A SOCIAL block (NpcSocial): a venue without the enrichment gate, a stint
## in one of the camp's conversation circles, or a wander out across the site.
## Same hashed choice and spots as NpcAgent._begin_social.
func _begin_social(i: int, t: float, ctx: Dictionary, hour: float, left: float) -> bool:
	var pick := NpcSocial.choice(ids[i], t)
	if pick == "venue" and _go_to_venue(i, t, ctx, hour, left):
		return true
	var wander := pick == "wander"
	var spot := NpcSocial.wander_spot(ids[i], home, t) if wander \
		else NpcSocial.mingle_spot(ids[i], seed_key, home, t)
	_go(i, t, spot["pos"], A_MINGLE, "", "", ctx)
	var face: Vector2 = spot["face"]
	fx[i] = face.x
	fz[i] = face.y
	vpose[i] = VPOSE_STAND if wander else VPOSE_NONE
	end_h[i] = t + left if left > 0.0 else -1.0
	return true


## A comfort stint (NpcComfort): walk to a shade / warmth spot from the
## bridge (`comfort_spot`, the same callable the full tier asks), or — for
## warmth with no fire anywhere, and for a share of the rain — into their own
## bed. Shade with nowhere to go is simply no response. Same choices as
## NpcAgent._begin_comfort.
func _begin_comfort(i: int, t: float, kind: String, ctx: Dictionary, left: float) -> bool:
	var at_bed := kind == NpcComfort.KIND_SHELTER and NpcComfort.shelters_at_bed(ids[i], t)
	var spot: Dictionary = {}
	if not at_bed:
		var f: Callable = ctx.get("comfort_spot", Callable())
		if f.is_valid():
			spot = f.call(kind, home, ids[i])
		if spot.is_empty():
			if kind == NpcComfort.KIND_SHADE:
				return false
			at_bed = true
	var pos: Vector2 = _slot_for(i) if at_bed else spot["pos"]
	var face: Vector2 = home if at_bed else spot["face"]
	var heat := float((ctx.get("comfort", {}) as Dictionary).get("heat", 0.0))
	_go(i, t, pos, A_MINGLE, "", "", ctx)
	fx[i] = face.x
	fz[i] = face.y
	vpose[i] = maxi(VPOSE_NAMES.find(NpcComfort.pose_for(kind, ids[i], heat, at_bed)), 0)
	ckind[i] = CKIND_NAMES.find(kind) | (CKIND_BED if at_bed else 0)
	end_h[i] = t + left if left > 0.0 else -1.0
	return true


## Hard rain just began: everyone out in the open on LEISURE re-decides now
## (their comfort roll sends a share under cover), rather than finishing a
## chat or a set in a downpour. Needs, sleep, work and event crowds are left.
func wake_for_weather(t: float, event_active: bool = false) -> void:
	for i in _n:
		if alive[i] != 1 or not (state[i] == S_DOING or (state[i] == S_CIRCLE and space_type[i] == "fire_circle")):
			continue
		if act[i] == A_FREE or (act[i] == A_MINGLE and ckind[i] == 0) \
				or (act[i] == A_ENRICH and VenueCrowd.rain_clears(space_type[i], event_active)):
			# (A fire circle is choreographed but not an event: a downpour
			# still sends its dancers for cover.)
			end_h[i] = t
			next_h[i] = t


## Cast this person as a stage's DJ (the bridge does, once per set): walk to
## the middle of the stage and play until `until_h`, stood `elev` m up on the
## deck facing `face`. False when the id is not on this roster or has left.
func perform(agent_id: String, spot: Dictionary, until_h: float, t: float, ctx: Dictionary) -> bool:
	var i := agent_index(agent_id)
	if i < 0 or alive[i] != 1:
		return false
	_materialize(i, t)
	_release(i, ctx)
	var p: Vector2 = spot.get("pos", pos_at(i, t))
	var face: Vector2 = spot.get("face", p + Vector2(0.0, 1.0))
	_go(i, t, p, A_PERFORM, "", "", ctx)
	fx[i] = face.x
	fz[i] = face.y
	# The ROLE picks the pose: the DJ (default), a fire-flow performer, a
	# sandman kneeling at the line or turning someone back.
	match str(spot.get("role", "dj")):
		"flow":
			vpose[i] = VPOSE_FIREFLOW
		"sandman":
			vpose[i] = VPOSE_KNEEL
		"redirect":
			vpose[i] = VPOSE_REDIRECT
		_:
			vpose[i] = VPOSE_DJ
	end_h[i] = until_h
	_perform[i] = {"elev": float(spot.get("elev", 0.0)), "sid": str(spot.get("sid", "")),
		"role": str(spot.get("role", "dj")), "orbit": spot.get("orbit", {})}
	_dirty[i] = true
	return true


## The role a performer is playing ("" when not performing).
func role_of(agent_id: String) -> String:
	var i := agent_index(agent_id)
	if i < 0 or act[i] != A_PERFORM or not _perform.has(i):
		return ""
	return str((_perform[i] as Dictionary).get("role", "dj"))


## A fire-flow performer on their lane: one short arc at a time (like the
## circle dance), so the renderer glides them round and they face along it.
const ORBIT_STEP_H := 0.008


func _orbit_step(i: int, t: float) -> void:
	var orbit: Dictionary = (_perform[i] as Dictionary).get("orbit", {})
	var here := pos_at(i, t)
	var nxt := VenueCrowd.orbit_point(orbit, minf(t + ORBIT_STEP_H, end_h[i]))
	ax[i] = here.x
	az[i] = here.y
	bx[i] = nxt.x
	bz[i] = nxt.y
	t0[i] = t
	t1[i] = t + ORBIT_STEP_H
	var tang := VenueCrowd.ccw_tangent(orbit.get("centre", here), nxt)
	fx[i] = nxt.x + tang.x * 10.0
	fz[i] = nxt.y + tang.y * 10.0
	next_h[i] = minf(t + ORBIT_STEP_H, end_h[i])
	_dirty[i] = true


## Turned back at a burn's line by a sandman: walk straight out to just past
## the line (radially, away from the fire) and stay there for now. Someone on
## their way to the burn keeps their visit (they watch from that spot);
## anyone else crossing stands at the line a moment, then carries on.
func redirect_out(agent_id: String, centre: Vector2, r: float, t: float, registry: SpaceRegistry) -> bool:
	var i := agent_index(agent_id)
	if i < 0 or alive[i] != 1 or act[i] == A_PERFORM or act[i] == A_SLEEP:
		return false
	var p := pos_at(i, t)
	var d := p - centre
	if d.length() < 0.01:
		var a := NpcHash.unit01(ids[i], "redir") * TAU
		d = Vector2(cos(a), sin(a))
	var dest := centre + d.normalized() * (r + 1.2)
	_materialize(i, t)
	if not (act[i] == A_ENRICH and space_type[i] == "effigy"):
		_release(i, {"registry": registry})
		act[i] = A_MINGLE
		vpose[i] = VPOSE_STAND
		end_h[i] = t + NpcHash.unit01(ids[i], "redir_h") * 0.05 + 0.03
	legs[i] = null
	ax[i] = p.x
	az[i] = p.y
	bx[i] = dest.x
	bz[i] = dest.y
	t0[i] = t
	t1[i] = t + NpcNav.hours_for_distance(p.distance_to(dest))
	state[i] = S_TRAVEL
	fx[i] = centre.x
	fz[i] = centre.y
	next_h[i] = t1[i]
	_dirty[i] = true
	return true


## End this person's set now (a new set on the same stage cast someone else).
func end_perform(agent_id: String, t: float) -> void:
	var i := agent_index(agent_id)
	if i < 0 or act[i] != A_PERFORM:
		return
	if state[i] == S_TRAVEL:
		_release(i, {})
	end_h[i] = t
	next_h[i] = t
	_dirty[i] = true


## PEAK EXPERIENCE inputs for the bridge's PeakField: everyone alive, where
## they are, whether they are VIBING (doing something social, needs met,
## morale up — NpcPeak) and at which venue. `idx` maps back to this cohort.
func peak_inputs(t: float) -> Dictionary:
	var ids_out := PackedStringArray()
	var pos := PackedVector2Array()
	var vib := PackedByteArray()
	var sid := PackedStringArray()
	var idx := PackedInt32Array()
	for i in _n:
		if alive[i] != 1:
			continue
		ids_out.append(ids[i])
		pos.append(pos_at(i, t))
		vib.append(1 if _vibing(i) else 0)
		sid.append(space_id[i])
		idx.append(i)
	return {"ids": ids_out, "pos": pos, "vib": vib, "sid": sid, "idx": idx}


## Social, needs met (as of their last event), nothing blocked, morale up.
func _vibing(i: int) -> bool:
	if state[i] != S_DOING and state[i] != S_CIRCLE:
		return false
	match act[i]:
		A_ENRICH, A_PERFORM:
			pass
		A_MINGLE:
			# A chat, a wander, the shade or the fire with friends — not
			# sheltering from rain or warming up alone in a tent.
			var ck := int(ckind[i])
			if (ck & CKIND_BED) != 0 or (ck & 3) == 3:
				return false
		_:
			return false
	if blocked[i] != 0 or morale[i] < NpcPeak.ELIGIBLE_MORALE:
		return false
	for n in NpcAgent.CRITICAL_NEEDS:
		var k := NpcAgent.NEEDS.find(n)
		if needs[i * 6 + k] >= float(NpcAgent.THRESHOLD.get(n, 1.0)):
			return false
	return true


## The bridge's verdict for person i (NAN = not peaking). A change re-writes
## their render slot (the glow).
func set_peak(i: int, since: float) -> void:
	var cur := peak_since[i]
	if (is_nan(cur) and is_nan(since)) or cur == since:
		return
	peak_since[i] = since
	_dirty[i] = true


## How close person i is to a peak (0..1) and the peakers feeding it.
func set_buzz(i: int, buzz: float, fed: int) -> void:
	var q := NpcPeak.buzz_q(buzz)
	peak_fed[i] = clampi(fed, 0, 255)
	if peak_buzz[i] == q:
		return
	peak_buzz[i] = q
	_dirty[i] = true


func buzz_of(i: int) -> float:
	return float(peak_buzz[i]) / float(NpcPeak.BUZZ_STEPS) if i < peak_buzz.size() else 0.0


## A peak lifts morale toward NpcPeak.PEAK_MORALE.
func lift_morale(i: int, dt_h: float) -> void:
	morale[i] = NpcPeak.lift(morale[i], dt_h)


## Walking to, queueing for or doing a need (eat, drink, toilet, wash)?
func on_a_need(agent_id: String) -> bool:
	var i := agent_index(agent_id)
	if i < 0 or state[i] == S_IDLE:
		return false
	return act[i] == A_HUNGER or act[i] == A_THIRST or act[i] == A_BLADDER or act[i] == A_HYGIENE


## Is this person on their way to, or at, the decks?
func is_performing(agent_id: String) -> bool:
	var i := agent_index(agent_id)
	return i >= 0 and alive[i] == 1 and act[i] == A_PERFORM \
		and (state[i] == S_TRAVEL or state[i] == S_DOING)


## Metres above the ground this person's FEET are (the DJ on the deck).
func elev_of(i: int) -> float:
	if act[i] == A_PERFORM and state[i] == S_DOING and _perform.has(i):
		return float((_perform[i] as Dictionary).get("elev", 0.0))
	return 0.0


## Walk to a space that serves `need`. False when nothing serves it (blocked).
func _go_for_need(i: int, t: float, need: String, ctx: Dictionary, hour: float,
		cap_h: float = -1.0) -> bool:
	var a: int = ACT_OF_NEED.get(need, A_NONE)
	var consumes: Dictionary = _consumes(need, "", ctx)
	for kind in consumes:
		if _starved.has(str(kind)):
			_mark_blocked(i, need)
			return false
	if need == "sleep":
		var slot := _slot_for(i)
		_go(i, t, slot, A_SLEEP, "", "", ctx)
		return true
	var registry: SpaceRegistry = ctx.get("registry")
	var here := pos_at(i, t)
	var ideal := PopTestPrefs.ideal_supply()
	if registry == null:
		if ideal:
			_clear_blocked(i, need)
			_go(i, t, here, a, "", "", ctx)
			end_h[i] = t + cap_h if cap_h > 0.0 else -1.0
			return true
		_mark_blocked(i, need)
		return false
	var best: Dictionary = {}
	var best_d := INF
	var exists := false
	for stype in SpaceTypes.spaces_for_need(need):
		if registry.spaces_of_type(str(stype)).is_empty():
			continue
		exists = true
		var s := registry.nearest_space_by(str(stype), here, Callable(), true, ids[i])
		if s.is_empty():
			continue
		var p: Variant = registry.cached_position(str(s["id"]))
		if not (p is Vector2):
			continue
		var d := (p as Vector2).distance_squared_to(here)
		if d < best_d:
			best_d = d
			best = s
	if best.is_empty():
		if not exists:
			if ideal:
				# IDEAL SUPPLY: met where the person stands (see NpcAgent).
				_clear_blocked(i, need)
				_go(i, t, here, a, "", "", ctx)
				end_h[i] = t + cap_h if cap_h > 0.0 else -1.0
				return true
			_mark_blocked(i, need)
			return false
		# Everything is full: queue at the nearest one.
		for stype in SpaceTypes.spaces_for_need(need):
			var s2 := registry.nearest_space_by(str(stype), here, Callable(), false, ids[i])
			if not s2.is_empty() and registry.cached_position(str(s2["id"])) is Vector2:
				best = s2
				break
		if best.is_empty():
			_mark_blocked(i, need)
			return false
	_clear_blocked(i, need)
	var sid := str(best["id"])
	var centre: Vector2 = registry.cached_position(sid)
	# The slot is RESERVED now, at the decision — everyone who sets off in the
	# same tick must not be handed the same spot (they would all walk onto it).
	var slot_i := registry.reserve_slot(sid, ids[i])
	var dest := centre + SpaceRegistry.slot_offset_for_index(slot_i) + SpaceRegistry.slot_jitter(ids[i])
	_go(i, t, dest, a, sid, str(best.get("space_type", "")), ctx)
	fx[i] = centre.x
	fz[i] = centre.y
	if cap_h > 0.0:
		end_h[i] = t + cap_h   # read at arrival as the block cap
	else:
		end_h[i] = -1.0
	return true


func _go_to_venue(i: int, t: float, ctx: Dictionary, hour: float, left: float) -> bool:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry == null:
		return false
	var here := pos_at(i, t)
	var candidates: Array = []
	var by_id: Dictionary = {}
	for stype in SpaceTypes.ENRICHMENT_TYPES:
		if str(stype) == "fire_circle" and _starved.has("biomass"):
			continue
		for item in registry.spaces_of_type(str(stype)):
			var space: Dictionary = item
			var sid := str(space.get("id", ""))
			var p: Variant = registry.cached_position(sid)
			if not (p is Vector2):
				continue
			var st := _venue_state_of(space, ctx, hour, t)
			candidates.append({"id": sid, "type": str(stype), "pos": p,
				"draw": float(st["draw"]), "pull": float(st.get("pull", 0.0)),
				"occupants": registry.occupant_count(sid),
				"capacity": int(space.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))})
			by_id[sid] = space
	if candidates.is_empty():
		return false
	# Friends go out together: the GROUP's taste (NpcFriends), as in the full tier.
	var win := NpcVenueChoice.pick(NpcVenueChoice.taste_for(NpcFriends.key_of(ids[i])), here, candidates)
	if win.is_empty():
		return false
	var sid2 := str(win["id"])
	var stype2 := str(win["type"])
	var centre: Vector2 = win["pos"]
	var st2 := _venue_state_of(by_id[sid2], ctx, hour, t)
	var slot_i := registry.reserve_slot(sid2, ids[i])
	vslot[i] = slot_i
	vphase[i] = _phase_code(int(st2.get("phase", -1)), st2)
	vpose[i] = maxi(VPOSE_NAMES.find(VenueCrowd.venue_pose(stype2, slot_i, st2, _venue_seed(i))), 0)
	var extra2 := _venue_extra(sid2, stype2, ctx)
	var dest := VenueCrowd.venue_spot(stype2, centre, slot_i, st2, t, _venue_seed(i), extra2)
	var face := centre
	if dest == Vector2.INF:
		# An ordinary venue: the friend group's own cluster round it.
		var gs := VenueCrowd.group_spot(stype2, centre,
			float(extra2.get("r", 0.0)) + VenueCrowd.round_gap(stype2, extra2), ids[i],
			registry.cluster_index_for(sid2, ids[i]))
		dest = gs["pos"]
		face = gs["face"]
	_go(i, t, dest, A_ENRICH, sid2, stype2, ctx)
	fx[i] = face.x
	fz[i] = face.y
	var cap := left
	if bool(st2.get("programmed", false)) and float(st2.get("ends_h", -1.0)) > 0.0:
		# A set ends when the programme says; an EVENT phase holds people for
		# the whole phase, past the end of their routine block.
		cap = float(st2["ends_h"]) if bool(st2.get("event", false)) else minf(cap, float(st2["ends_h"]))
	end_h[i] = t + cap if cap > 0.0 else -1.0
	return true


## The venue's live state (bridge resolver first — it has the fire records).
func _venue_state_of(space: Dictionary, ctx: Dictionary, hour: float, t: float) -> Dictionary:
	var f: Callable = ctx.get("venue_state_of", Callable())
	if f.is_valid():
		var v: Variant = f.call(space)
		if v is Dictionary and not (v as Dictionary).is_empty():
			return v
	return NpcVenueState.resolve(space, hour, t)


func _venue_extra(sid: String, _stype: String, ctx: Dictionary) -> Dictionary:
	var f: Callable = ctx.get("venue_front_of", Callable())
	if f.is_valid():
		var v: Variant = f.call(sid)
		if v is Dictionary:
			return v
	return {}


func _venue_seed(i: int) -> float:
	return NpcHash.unit01(ids[i], "venue")


## At a LIVE venue, every heartbeat: hold the person for an EVENT phase,
## re-seat them when the phase changes (ring -> circle -> embers; set on /
## off), and start the circle dance when the pile lands. True when it took
## over the person's next event.
func _service_live_venue(i: int, t: float, ctx: Dictionary) -> bool:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry == null or space_id[i].is_empty():
		return false
	var rec := registry.find_by_id(space_id[i])
	var centre: Variant = registry.cached_position(space_id[i])
	if rec.is_empty() or not (centre is Vector2):
		return false
	var hour := _hour_at(ctx, t)
	var st := _venue_state_of(rec, ctx, hour, t)
	var phase := int(st.get("phase", -1))
	if bool(st.get("event", false)) and float(st.get("ends_h", -1.0)) > 0.0:
		end_h[i] = maxf(end_h[i], t + float(st["ends_h"]))
	var pose := VPOSE_NAMES.find(VenueCrowd.venue_pose(space_type[i], vslot[i], st, _venue_seed(i)))
	var code := _phase_code(phase, st)
	var phase_changed := vphase[i] != code
	vphase[i] = code
	vpose[i] = maxi(pose, 0)
	_dirty[i] = true
	if VenueCrowd.is_circling(space_type[i], st):
		_circle_step(i, t, ctx)
		return true
	if phase_changed:
		var spot := VenueCrowd.venue_spot(space_type[i], centre, vslot[i], st, t, _venue_seed(i),
			_venue_extra(space_id[i], space_type[i], ctx))
		if spot != Vector2.INF:
			# Walk to the new seat; the claim is kept (claim() is idempotent
			# for an occupant) and _begin_activity re-reads the cap.
			_go(i, t, spot, A_ENRICH, space_id[i], space_type[i], ctx)
			return true
	return false


## The venue-phase code kept per person: 0 = never seated (a catch-up or a
## restore left them where they stood), so a real code is never 0 — a
## stage's phase is -1, and `-1 + 1` once collided with "unset" and left the
## people the catch-up parked round the stage centre unseated for the whole
## set. The set's on/off state is folded in, so a set starting re-seats too.
func _phase_code(phase: int, st: Dictionary) -> int:
	var live := 1 if (bool(st.get("active", true)) and bool(st.get("programmed", false))) else 0
	# A fire going out (or being lit) is a phase change for its crowd too,
	# and so is a stage's music starting / stopping within earshot of it.
	var cold := 0 if VenueCrowd.fire_lit(st) else 100
	var music := 200 if VenueCrowd.fire_music(st) else 0
	return (phase + 2) * 2 + live + cold + music


## The bridge calls this when a venue's PHASE changes (the effigy lit, the
## pile landed, a set started): everyone seated there gets their next event
## NOW, so the whole ring re-seats this tick instead of trickling over the
## next hour as heartbeats come due. Without it the people who sat down at
## the unlit effigy's spiral were still sitting 11 m from the fire mid-burn.
func wake_at_venue(sid: String, t: float) -> void:
	for i in _n:
		if alive[i] == 1 and space_id[i] == sid and (state[i] == S_DOING or state[i] == S_QUEUE):
			next_h[i] = minf(next_h[i], t) if not is_nan(next_h[i]) else t


## Walk everyone standing inside a fire perimeter (centre, r) out to just
## beyond it, facing the fire — everyone EXCEPT the effigy's own crowd (`sid`),
## whom the venue re-seats, and sleepers. Called by the bridge the moment an
## effigy is lit, so nobody is left standing in the fall zone. Returns how
## many were moved.
func evacuate_from(centre: Vector2, r: float, sid: String, t: float, registry: SpaceRegistry) -> int:
	var moved := 0
	var ctx := {"registry": registry}
	for i in _n:
		# Sleepers too: nobody spends the burn in a tent inside the fall zone
		# (their bed is pushed outside the perimeter when they lie down again).
		if alive[i] != 1 or space_id[i] == sid or state[i] == S_TRAVEL or state[i] == S_CIRCLE:
			continue
		var p := pos_at(i, t)
		if p.distance_to(centre) >= r:
			continue
		_materialize(i, t)
		_release(i, ctx)
		var d := p - centre
		if d.length() < 0.01:
			var a := NpcHash.unit01(ids[i], "evac") * TAU
			d = Vector2(cos(a), sin(a))
		var dest := centre + d.normalized() * (r + 2.0)
		legs[i] = null
		ax[i] = p.x
		az[i] = p.y
		bx[i] = dest.x
		bz[i] = dest.y
		t0[i] = t
		t1[i] = t + NpcNav.hours_for_distance(p.distance_to(dest))
		state[i] = S_TRAVEL
		act[i] = A_MINGLE
		vpose[i] = VPOSE_STAND   # a short "look" stint at the perimeter
		fx[i] = centre.x
		fz[i] = centre.y
		end_h[i] = -1.0
		next_h[i] = t1[i]
		_dirty[i] = true
		moved += 1
	return moved


## An EVENT just began (the effigy lit): everyone hanging out or at some
## other venue re-decides NOW, so the pull can bring them -- otherwise a
## person two hours into a stage set would not look round until their next
## heartbeat. Needs and sleep are untouched.
func wake_for_event(t: float) -> void:
	for i in _n:
		var fire_dancer := state[i] == S_CIRCLE and space_type[i] == "fire_circle"
		if alive[i] == 1 and (state[i] == S_DOING or fire_dancer) \
				and (act[i] == A_ENRICH or act[i] == A_FREE or act[i] == A_MINGLE):
			# END the visit, not just poke it: a woken S_DOING person whose
			# end_h is still ahead only gets a heartbeat, which re-decides
			# nothing. Live-venue people are left to _service_live_venue.
			if SpaceTypes.LIVE_VENUE_TYPES.has(space_type[i]) and space_type[i] != "fire_circle":
				continue
			end_h[i] = t
			next_h[i] = t


## One arc of the circle dance: a short segment to where this slot's lane
## will be CIRCLE_STEP_H from now (VenueCrowd.effigy_slot / fire_ring_slot
## move with t), as S_CIRCLE so the renderer draws a walker/dancer gliding
## round the ring. When the circling ends (the pile burned past it, the fire
## went out) the person settles into the venue's still seat.
func _circle_step(i: int, t: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry == null or space_id[i].is_empty():
		_release(i, ctx)
		_decide(i, t, ctx)
		return
	var rec := registry.find_by_id(space_id[i])
	var centre: Variant = registry.cached_position(space_id[i])
	if rec.is_empty() or not (centre is Vector2):
		_release(i, ctx)
		_decide(i, t, ctx)
		return
	var st := _venue_state_of(rec, ctx, _hour_at(ctx, t), t)
	var phase := int(st.get("phase", -1))
	var extra := _venue_extra(space_id[i], space_type[i], ctx)
	if not VenueCrowd.is_circling(space_type[i], st):
		# The dance is over: settle into the embers spiral (the still ring
		# round a cold fire) and carry on as an ordinary visit.
		vphase[i] = _phase_code(phase, st)
		vpose[i] = maxi(VPOSE_NAMES.find(VenueCrowd.venue_pose(space_type[i], vslot[i], st, _venue_seed(i))), 0)
		var spot := VenueCrowd.venue_spot(space_type[i], centre, vslot[i], st, t, _venue_seed(i), extra)
		state[i] = S_DOING
		if spot != Vector2.INF:
			_go(i, t, spot, A_ENRICH, space_id[i], space_type[i], ctx)
		else:
			next_h[i] = minf(end_h[i], t + HEARTBEAT_H) if end_h[i] > t else t + HEARTBEAT_H
		_dirty[i] = true
		return
	if not bool(st.get("event", false)):
		# A fire dance is a visit like any other, not an event: needs and
		# morale tick as on a heartbeat, a desperate need takes them off the
		# ring (the full tier's URGENT bar for a visit), and when the visit is
		# over they leave. (The effigy's circle is an EVENT that holds people
		# for 45 minutes; a fire burns all night.)
		_materialize(i, t)
		_update_morale(i, t, ctx)
		var urgent := _most_urgent(i)
		if not urgent.is_empty() and _need(i, urgent) >= NpcAgent.URGENT:
			_release(i, ctx)
			_decide(i, t, ctx)
			return
		if t >= end_h[i] - 1e-6:   # (end_h < 0 = no cap = done now, as on a heartbeat)
			_finish_activity(i, t, ctx)
			return
	if end_h[i] > 0.0 and t >= end_h[i] - 1e-6:
		# Their routine would end the visit, but an event holds them: the
		# event cap (ends_h) is re-read above by _service_live_venue; here
		# simply extend to the end of the dance.
		end_h[i] = t + float(st.get("ends_h", CIRCLE_STEP_H))
	var here := pos_at(i, t)
	# A fire's ring is small and turns fast: shorter arcs (a sixteenth of a
	# lap) so the chord between them stays a step, not a cut across the pit.
	var fire := space_type[i] == "fire_circle"
	var step_h := VenueCrowd.FIRE_LAP_H / 16.0 if fire else CIRCLE_STEP_H
	var next := VenueCrowd.venue_spot(space_type[i], centre, vslot[i], st, t + step_h,
		_venue_seed(i), extra)
	if next == Vector2.INF:
		_release(i, ctx)
		_decide(i, t, ctx)
		return
	# Not on the ring yet (the seat they watched the burn from, or a late
	# arrival): WALK to the lane as a routed trip — a raw chord from a ring
	# seat to a lane point on the far side runs straight through the pile.
	var lane_r := next.distance_to(centre)
	var on_ring := absf(here.distance_to(centre) - lane_r) <= (1.0 if fire else 1.5)
	# Round a fire, anyone already at their ring's radius simply JOINS where
	# they stand: the seat moves on while they walk, so chasing it (as the
	# effigy's late arrivals do) never arrives — measured, it doubled the
	# light tier's consumption.
	if not on_ring or (state[i] != S_CIRCLE and not fire):
		if here.distance_to(next) > 1.5:
			_go(i, t, next, A_ENRICH, space_id[i], space_type[i], ctx)
			_dirty[i] = true
			return
	ax[i] = here.x
	az[i] = here.y
	bx[i] = next.x
	bz[i] = next.y
	t0[i] = t
	t1[i] = t + step_h
	state[i] = S_CIRCLE
	act[i] = A_ENRICH
	vpose[i] = maxi(VPOSE_NAMES.find(VenueCrowd.venue_pose(space_type[i], vslot[i], st, _venue_seed(i))), 0)
	next_h[i] = t1[i]
	_dirty[i] = true


func _start_work(i: int, t: float, hours: float, ctx: Dictionary) -> void:
	var dur := maxf(hours, 0.05)
	state[i] = S_DOING
	act[i] = A_WORK
	space_id[i] = ""
	space_type[i] = ""
	var w: Dictionary = ctx.get("weather", {})
	_work_h += dur * NpcMorale.productivity(morale[i]) \
		* NpcWeatherGate.productivity(w, NpcWeatherGate.EXPOSURE_OUTDOOR)
	end_h[i] = t + dur
	next_h[i] = minf(end_h[i], t + HEARTBEAT_H)


## Set the motion segment and the arrival event. With the nav grid baked the
## trip follows the SAME A* route the full tier walks (cached per space
## pair through the bridge), as a chain of legs — one arrival event each —
## so the light crowd walks round tents and vehicles instead of through
## them. Straight line when no route is available.
func _go(i: int, t: float, dest: Vector2, a: int, sid: String, stype: String,
		ctx: Dictionary) -> void:
	var from := pos_at(i, t)
	# Never a goal inside a fire perimeter (NpcNav.outside, as NpcAgent) —
	# except a burn role's post: the sandmen kneel just INSIDE the line.
	if a != A_PERFORM:
		dest = NpcNav.outside(dest, ctx.get("no_go", []))
	var d := from.distance_to(dest)
	# Lane offset: perpendicular to the walk, per person, so a column of
	# people heading the same way does not share one line. NOT for a
	# choreographed seat (the ring, the fan, a bed): approached tangentially
	# the offset is radial and put ring seats 0.8 m inside the perimeter.
	var choreographed := a == A_SLEEP or a == A_PERFORM or (a == A_ENRICH and SpaceTypes.LIVE_VENUE_TYPES.has(stype))
	if d > 2.0 and not choreographed:
		var dir := (dest - from) / d
		var side := (NpcHash.unit01(ids[i], "lane") * 2.0 - 1.0) * LANE_OFFSET_M
		dest += Vector2(-dir.y, dir.x) * side
	legs[i] = null
	leg_i[i] = 0
	var first := dest
	if d > 6.0:
		var planner: Callable = ctx.get("plan_path", Callable())
		if planner.is_valid():
			var from_key := str(last_space[i]) if not str(last_space[i]).is_empty() else "home|" + seed_key
			var to_key := sid if not sid.is_empty() else ("home|" + seed_key if a == A_SLEEP else "")
			var path: Variant = planner.call(from, dest, from_key, to_key, hash(ids[i]))
			# A space-pair route starts where it was first planned FROM (the
			# camp). Re-seating at the venue you are already at (ring -> circle
			# lane) got the camp->venue route and walked back to camp, straight
			# across the fire. A route that starts farther away than the goal
			# is not this trip's.
			if path is PackedVector2Array and (path as PackedVector2Array).size() >= 2 \
					and (path as PackedVector2Array)[0].distance_to(from) > from.distance_to(dest):
				path = null
			if path is PackedVector2Array and (path as PackedVector2Array).size() >= 2:
				var pv: PackedVector2Array = (path as PackedVector2Array).duplicate()
				# The planner ends on its goal CELL's centre (up to half a cell
				# off); finish on the exact seat, or a ring seat drifts inward.
				# A space-pair route is SHARED (cached for the first walker's
				# goal), so the last leg to THIS person's seat can be long —
				# round any fire, never across it.
				if pv[pv.size() - 1].distance_to(dest) > 0.1:
					var det_end := NpcNav.detour(pv[pv.size() - 1], dest, ctx.get("no_go", []))
					if det_end.size() > 0:
						pv.append_array(det_end)
					else:
						pv.append(dest)
				# ...and the first leg, from where this person actually stands.
				if pv[0].distance_to(from) > 0.5:
					var det_start := NpcNav.detour(from, pv[0], ctx.get("no_go", []))
					if det_start.size() > 1:
						det_start.remove_at(det_start.size() - 1)
						var joined := det_start.duplicate()
						joined.append_array(pv)
						pv = joined
				# Drop a leading point that is where we already stand.
				var start := 1 if pv[0].distance_to(from) < 0.5 else 0
				if pv.size() - start >= 2 or (pv.size() - start == 1 and pv[start].distance_to(dest) > 0.5):
					legs[i] = pv
					leg_i[i] = start
					first = pv[start]
	if legs[i] == null:
		# No route: a straight line, but never THROUGH the fire — one
		# waypoint round the perimeter (NpcNav.detour).
		var det := NpcNav.detour(from, dest, ctx.get("no_go", []))
		if det.size() > 0:
			legs[i] = det
			leg_i[i] = 0
			first = det[0]
	ax[i] = from.x
	az[i] = from.y
	bx[i] = first.x
	bz[i] = first.y
	t0[i] = t
	t1[i] = t + NpcNav.hours_for_distance(from.distance_to(first))
	state[i] = S_TRAVEL
	act[i] = a
	space_id[i] = sid
	space_type[i] = stype
	next_h[i] = t1[i]


## True when the person was walking a route and has just been moved onto
## its next leg (the caller returns — not an arrival yet).
func _advance_leg(i: int, t: float) -> bool:
	if legs[i] == null:
		return false
	var pv: PackedVector2Array = legs[i]
	var k := leg_i[i] + 1
	if k >= pv.size():
		legs[i] = null
		return false
	var here := Vector2(bx[i], bz[i])
	ax[i] = here.x
	az[i] = here.y
	bx[i] = pv[k].x
	bz[i] = pv[k].y
	leg_i[i] = k
	t0[i] = t
	t1[i] = t + NpcNav.hours_for_distance(here.distance_to(pv[k]))
	next_h[i] = t1[i]
	_dirty[i] = true
	return true


func _arrive(i: int, t: float, ctx: Dictionary) -> void:
	if _advance_leg(i, t):
		return
	ax[i] = bx[i]
	az[i] = bz[i]
	_materialize(i, t)
	_update_morale(i, t, ctx)
	var registry: SpaceRegistry = ctx.get("registry")
	if not space_id[i].is_empty() and registry != null:
		if not registry.claim(space_id[i], ids[i]):
			state[i] = S_QUEUE
			queue_since[i] = t
			next_h[i] = t + QUEUE_POLL_H
			return
	_begin_activity(i, t, ctx)


func _poll_queue(i: int, t: float, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry != null and registry.claim(space_id[i], ids[i]):
		_begin_activity(i, t, ctx)
		return
	if t - queue_since[i] >= QUEUE_MAX_H:
		# Gave up: the need stays, retry elsewhere after the backoff.
		var name := str(ACT_NAMES[act[i]])
		if not name.is_empty() and name != NpcAgent.CHORE_ACTIVITY:
			_mark_blocked(i, name)
		state[i] = S_IDLE
		space_id[i] = ""
		next_h[i] = t + NpcAgent.RETRY_BACKOFF_H
		return
	next_h[i] = t + QUEUE_POLL_H


func _begin_activity(i: int, t: float, ctx: Dictionary) -> void:
	# Arrived at a seat that became a fire's fall zone while walking (the
	# effigy was lit mid-trip): step out to just beyond the perimeter first.
	if space_type[i] != "effigy" and act[i] != A_PERFORM:
		var here := Vector2(ax[i], az[i])
		var safe := NpcNav.outside(here, ctx.get("no_go", []))
		if safe.distance_squared_to(here) > 1e-6:
			_go(i, t, safe, act[i], space_id[i], space_type[i], ctx)
			return
	state[i] = S_DOING
	if act[i] == A_ENRICH and SpaceTypes.LIVE_VENUE_TYPES.has(space_type[i]):
		var registry0: SpaceRegistry = ctx.get("registry")
		var rec0: Dictionary = registry0.find_by_id(space_id[i]) if registry0 != null else {}
		if not rec0.is_empty():
			var st0 := _venue_state_of(rec0, ctx, _hour_at(ctx, t), t)
			var code0 := _phase_code(int(st0.get("phase", -1)), st0)
			var centre0: Variant = registry0.cached_position(space_id[i])
			if vphase[i] != 0 and vphase[i] != code0 and centre0 is Vector2:
				# The venue changed phase while this person was walking
				# there (the effigy was lit mid-trip): their seat is from
				# the OLD phase. Walk on to the new one rather than sitting
				# down in a stale spot for the rest of the burn.
				var spot0 := VenueCrowd.venue_spot(space_type[i], centre0, vslot[i], st0, t,
					_venue_seed(i), _venue_extra(space_id[i], space_type[i], ctx))
				vphase[i] = code0
				if spot0 != Vector2.INF and spot0.distance_to(Vector2(ax[i], az[i])) > 1.0:
					_go(i, t, spot0, A_ENRICH, space_id[i], space_type[i], ctx)
					return
			vphase[i] = code0
			vpose[i] = maxi(VPOSE_NAMES.find(VenueCrowd.venue_pose(space_type[i], vslot[i], st0, _venue_seed(i))), 0)
			if bool(st0.get("event", false)) and float(st0.get("ends_h", -1.0)) > 0.0:
				end_h[i] = maxf(end_h[i], t + float(st0["ends_h"]))
			if VenueCrowd.is_circling(space_type[i], st0):
				if not bool(st0.get("event", false)):
					# A fire dance is an ordinary VISIT: the usual enrichment
					# length, capped by the block — not the whole block (that
					# danced people from 20:00 to bed without a drink, and
					# they slept thirsty).
					var cap0 := end_h[i] - t if end_h[i] > t else -1.0
					var base0 := float((NpcAgent.ACTIVITIES.get("enrichment", {}) as Dictionary).get("duration_h", 0.25))
					var d0 := base0 * (0.85 + _rand(i) * 0.4)
					if cap0 > 0.0:
						d0 = minf(d0, cap0)
					end_h[i] = t + maxf(d0, 1.0 / 60.0)
				_circle_step(i, t, ctx)
				return
	var name := str(ACT_NAMES[act[i]])
	var cap := end_h[i] - t if end_h[i] > t else -1.0
	var dur := 0.0
	if act[i] == A_SLEEP:
		var hour := _hour_at(ctx, t)
		var wake := _wake_base + NpcHash.unit01(ids[i], "wake") * 1.5
		dur = fposmod(wake - hour, 24.0)
		# A daytime sleep (need over 0.9 between the wake hour and 21:00) is
		# INSTANT in the full tier — its wake test fires on the very next
		# substep and the need resets — so it is instant here too, rather
		# than a two-hour nap the other tier never takes.
		if hour >= wake and hour < NpcAgent.night_from_h(_sleep_start_cur):
			dur = 1.0 / 60.0
	elif act[i] == A_MINGLE:
		if ckind[i] != 0:
			dur = NpcComfort.stint_h(ids[i], t)
		else:
			dur = NpcSocial.stint_h(ids[i], t, vpose[i] == VPOSE_STAND)
		if cap > 0.0:
			dur = minf(dur, cap)
	elif act[i] == A_PERFORM:
		# The set's end is the visit's end.
		dur = cap if cap > 0.0 else 1.0
	else:
		var base := float((NpcAgent.ACTIVITIES.get(name, {}) as Dictionary).get("duration_h", 0.25))
		dur = base * (0.85 + _rand(i) * 0.4)
		if cap > 0.0:
			dur = minf(dur, cap)
	dur = maxf(dur, 1.0 / 60.0)
	end_h[i] = t + dur
	next_h[i] = minf(end_h[i], t + HEARTBEAT_H)
	if act[i] == A_PERFORM and _perform.has(i) \
			and not ((_perform[i] as Dictionary).get("orbit", {}) as Dictionary).is_empty():
		next_h[i] = t   # a fire-flow performer starts round the lane at once
	# Bill the whole visit now (mass-exact; the flow engine integrates the
	# per-tick average), to the bound graph item when the space has one.
	var registry: SpaceRegistry = ctx.get("registry")
	var rec: Dictionary = registry.find_by_id(space_id[i]) if (registry != null and not space_id[i].is_empty()) else {}
	var bound := str(rec.get("graph_item_id", ""))
	if not bound.is_empty():
		match act[i]:
			A_BLADDER:
				_flow(bound, "blackwater", PORTAPOTTY_BLACKWATER_L)
			A_HUNGER:
				_flow(bound, "meal", -NpcAgent.MEAL_PER_H * dur)
			A_THIRST:
				_flow(bound, "water", -float(NpcAgent.ACTIVITIES["thirst"]["consumes"]["water"]) * dur)
			_:
				for kind in _consumes(name, space_type[i], ctx):
					_flow(bound, str(kind), -float(_consumes(name, space_type[i], ctx)[kind]) * dur)
		return
	var consumes := _consumes(name, space_type[i], ctx)
	for kind in consumes:
		_accum[str(kind)] = float(_accum.get(str(kind), 0.0)) + float(consumes[kind]) * dur


func _flow(item_id: String, kind: String, qty: float) -> void:
	var d: Dictionary = _venue_flows.get(item_id, {})
	d[kind] = float(d.get(kind, 0.0)) + qty
	_venue_flows[item_id] = d


## NpcAgent._consumes_for, for a named activity at a space type.
func _consumes(name: String, stype: String, ctx: Dictionary) -> Dictionary:
	if name.is_empty():
		return {}
	var base: Dictionary = (NpcAgent.ACTIVITIES.get(name, {}) as Dictionary).get("consumes", {})
	if name == "enrichment":
		return {"biomass": NpcAgent.FIRE_BIOMASS_KG_H} if stype == "fire_circle" else {}
	if name == "hunger" and bool(ctx.get("meal_available", false)):
		return {"meal": NpcAgent.MEAL_PER_H, "water": float(base.get("water", 8.0))}
	return base


func _finish_activity(i: int, t: float, ctx: Dictionary) -> void:
	_materialize(i, t)
	var name := str(ACT_NAMES[act[i]])
	if act[i] == A_MINGLE:
		_set_need(i, "enrichment", NpcSocial.relieved_enrichment(_need(i, "enrichment")))
	if ACT_OF_NEED.has(name):
		_set_need(i, name, _rand(i) * 0.08)
		_clear_blocked(i, name)
		if name == "thirst":
			_set_need(i, "bladder", _need(i, "bladder") + NpcAgent.DRINK_BLADDER_KICK)
	_release(i, ctx)
	_decide(i, t, ctx)


func _release(i: int, ctx: Dictionary) -> void:
	var registry: SpaceRegistry = ctx.get("registry")
	if registry != null and not space_id[i].is_empty():
		registry.release(space_id[i], ids[i])
	# Where the next route starts from (the space-pair route cache key).
	last_space[i] = space_id[i] if not space_id[i].is_empty() else ("home|" + seed_key if act[i] == A_SLEEP else last_space[i])
	space_id[i] = ""
	space_type[i] = ""
	state[i] = S_IDLE
	act[i] = A_NONE
	vslot[i] = -1
	vpose[i] = VPOSE_NONE
	vphase[i] = 0
	fx[i] = NAN
	fz[i] = NAN
	ckind[i] = 0
	_perform.erase(i)


# ---------------------------------------------------------------------------
# Departures, catch-up
# ---------------------------------------------------------------------------

func _process_departures(abs_h: float, ctx: Dictionary) -> void:
	if _leaving.is_empty():
		return
	if NpcConsequence.normalize(consequence) == NpcConsequence.PERISH or PopTestPrefs.no_departures():
		_leaving = []
		return
	var gone: Array = _leaving.duplicate()
	_leaving = []
	for i in gone:
		if alive[i] == 0:
			continue
		_release(i, ctx)
		alive[i] = 0
		_dirty[i] = true
		var name := NpcAgent.name_for(ids[i])
		_departures.append({"id": ids[i], "name": name, "reason": "left", "kind": "departed",
			"abs_h": abs_h})
		agent_departed.emit(ids[i], name, "left")
	var remaining := alive_count()
	if remaining > 0:
		var share := float(gone.size()) / float(remaining)
		var shock := NpcMorale.DEPARTURE_SHOCK * share * float(gone.size())
		for i in _n:
			if alive[i] == 1:
				morale[i] = clampf(morale[i] - shock, 0.0, 1.0)
	_check_collapse()
	if remaining == 0:
		colony_deserted.emit("left")


func _check_collapse() -> void:
	if _collapsed:
		return
	var risk := collapse_risk()
	if not _collapse_warned and risk >= COLLAPSE_WARN_RISK:
		_collapse_warned = true
		collapse_warning.emit(risk)
	if _initial_roster > 0 and alive_count() <= int(ceil(float(_initial_roster) * COLLAPSE_FLOOR_FRAC)):
		_collapsed = true
		colony_collapsed.emit()


## Shift every per-person timestamp by `d` hours (a backward scrub): the
## same positions, needs and activities, just anchored to the new clock.
func _rebase_times(d: float) -> void:
	for i in _n:
		t0[i] += d
		t1[i] += d
		need_t[i] += d
		morale_t[i] += d
		if end_h[i] > 0.0:
			end_h[i] += d
		if not is_nan(next_h[i]):
			next_h[i] += d
		if queue_since[i] > 0.0:
			queue_since[i] += d
	_all_dirty = true


func _catch_up(abs_h: float, dt: float, ctx: Dictionary) -> void:
	for i in _n:
		if alive[i] == 0:
			continue
		_release(i, ctx)
		for k in 6:
			var n := str(NpcAgent.NEEDS[k])
			var consumes: Dictionary = (NpcAgent.ACTIVITIES.get(n, {}) as Dictionary).get("consumes", {})
			var starved := false
			for kind in consumes:
				if _starved.has(str(kind)):
					starved = true
			if n == "enrichment" or starved:
				needs[i * 6 + k] = clampf(needs[i * 6 + k] + float(NpcAgent.RISE_PER_H[n]) * dt, 0.0, 1.0)
			else:
				needs[i * 6 + k] = 0.15 + _rand(i) * 0.4
		if dt >= 16.0:
			_set_need(i, "sleep", 0.05 + _rand(i) * 0.15)
		need_t[i] = abs_h
		var settled := NpcMorale.step(morale[i], minf(dt, 2.0), _needs_dict(i), {}, _need(i, "enrichment"))
		morale[i] = clampf(settled, morale[i] - CATCHUP_MORALE_DRIFT, morale[i] + CATCHUP_MORALE_DRIFT)
		quit[i] = maxf(quit[i] - NpcMorale.QUIT_DECAY_PER_H * dt, 0.0)
		morale_t[i] = abs_h
		ax[i] = bx[i]
		az[i] = bz[i]
		next_h[i] = abs_h
	_all_dirty = true


# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

## Indices whose slot changed since the last call (empty + all_dirty true
## means "rewrite everyone"). Cleared by the call.
func take_dirty() -> Dictionary:
	var out := {"all": _all_dirty, "indices": PackedInt32Array()}
	if not _all_dirty:
		var idx := PackedInt32Array()
		for k in _dirty.keys():
			idx.append(int(k))
		idx.sort()
		out["indices"] = idx
	_dirty = {}
	_all_dirty = false
	return out


func mark_all_dirty() -> void:
	_all_dirty = true


## What the body is doing, for the vertex-stage animation.
func pose_code(i: int) -> int:
	var p := _pose_code_base(i)
	if (state[i] == S_DOING or state[i] == S_CIRCLE) and not is_nan(peak_since[i]) \
			and (act[i] == A_ENRICH or act[i] == A_MINGLE) \
			and (p == POSE_STAND or p == POSE_TALK or p == POSE_DANCE or p == POSE_RAVE or p == POSE_SWAY):
		return POSE_PEAK
	return p


func _pose_code_base(i: int) -> int:
	match state[i]:
		S_TRAVEL:
			return POSE_WALK
		S_CIRCLE:
			return POSE_DANCE if vpose[i] == VPOSE_DANCE else POSE_WALK
		S_QUEUE:
			return POSE_QUEUE
		S_DOING:
			match act[i]:
				A_SLEEP: return POSE_LIE
				A_HUNGER: return POSE_CROSS
				A_WORK: return POSE_WORK
				A_MINGLE:
					match vpose[i]:
						VPOSE_STAND: return POSE_STAND
						VPOSE_SIT: return POSE_CROSS
						VPOSE_LIE: return POSE_LIE
						VPOSE_LOUNGE: return POSE_LOUNGE
					return POSE_TALK
				A_PERFORM:
					match vpose[i]:
						VPOSE_FIREFLOW: return POSE_FIREFLOW
						VPOSE_KNEEL: return POSE_KNEEL
						VPOSE_REDIRECT: return POSE_REDIRECT
					return POSE_DJ
				A_ENRICH:
					# A LIVE venue's hint for this slot wins (front rows sit
					# or lie at the burn, the fan raves at a set).
					match vpose[i]:
						VPOSE_SIT: return POSE_CROSS
						VPOSE_LIE, VPOSE_LOUNGE: return POSE_LOUNGE
						VPOSE_GAZE: return POSE_GAZE
						VPOSE_DANCE: return POSE_DANCE
						VPOSE_RAVE: return POSE_RAVE
						VPOSE_CHEER: return POSE_CHEER
						VPOSE_TALK: return POSE_TALK
						VPOSE_SWAY: return POSE_SWAY
						VPOSE_STAND, VPOSE_CLAP, VPOSE_WALK: return POSE_STAND
					var st := space_type[i]
					if st == "stage" or st == "fire_circle" or st == "movement":
						return POSE_DANCE
					if st == "temple" or st == "quiet":
						return POSE_CROSS
					# Center camp, art and workshops read as a crowd talking
					# and clapping (the full tier plays CLAP there).
					if st == "center_camp" or st == "art" or st == "workshop_social":
						return POSE_TALK
					return POSE_STAND
	return POSE_STAND


## Which way a standing person faces (radians, atan2(x, z) convention of the
## crowd shader): toward where they were going, else toward home.
func face_yaw(i: int) -> float:
	var p := Vector2(ax[i], az[i])
	var dest := Vector2(bx[i], bz[i])
	if dest.distance_squared_to(p) > 1e-4:
		return atan2(dest.x - p.x, dest.y - p.y)
	# At a venue, a circle or a view: face IT, not home.
	if not is_nan(fx[i]):
		var f := Vector2(fx[i], fz[i])
		if f.distance_squared_to(p) > 1e-4:
			return atan2(f.x - p.x, f.y - p.y)
	return atan2(home.x - p.x, home.y - p.y)

## Signed quantities billed to bound graph items since the last call
## (+ deposit, − draw). The bridge hands them to the flow engine.
func take_venue_flows() -> Dictionary:
	var out := _venue_flows
	_venue_flows = {}
	return out


## Productive person-hours worked since the last call (statistical labour).
func take_work_hours() -> float:
	var h := _work_h
	_work_h = 0.0
	return h


func mean_morale() -> float:
	var total := 0.0
	var c := 0
	for i in _n:
		if alive[i] == 1:
			total += morale[i]
			c += 1
	return total / float(c) if c > 0 else 0.0


func blocked_share() -> float:
	var c := 0
	var b := 0
	for i in _n:
		if alive[i] == 0:
			continue
		c += 1
		for n in NpcAgent.CRITICAL_NEEDS:
			if _is_blocked(i, str(n)):
				b += 1
				break
	return float(b) / float(c) if c > 0 else 0.0


func collapse_risk() -> float:
	if _initial_roster <= 0:
		return 0.0
	var lost := 1.0 - float(alive_count()) / float(_initial_roster)
	var roster_term := clampf(lost / maxf(1.0 - COLLAPSE_FLOOR_FRAC, 0.01), 0.0, 1.0)
	var morale_term := 1.0 - clampf(mean_morale() / NpcMorale.BASELINE_CEILING, 0.0, 1.0)
	return clampf(0.5 * roster_term + 0.3 * morale_term + 0.2 * blocked_share(), 0.0, 1.0)


func has_collapsed() -> bool:
	return _collapsed


func is_deserted() -> bool:
	return _n > 0 and alive_count() == 0


func departures() -> Array:
	return _departures.duplicate(true)


## Same keys the full engine's summary carries (the ones a dashboard reads).
func summary() -> Dictionary:
	var avg := {}
	var worst := {}
	for n in NpcAgent.NEEDS:
		avg[n] = 0.0
		worst[n] = 0.0
	var acts := {}
	var bands: Array = []
	bands.resize(NpcMorale.BANDS.size())
	bands.fill(0)
	var worst_m := 1.0
	var c := 0
	var blocked_counts := {}
	var t := _last_abs_h if not is_nan(_last_abs_h) else 0.0
	for i in _n:
		if alive[i] == 0:
			continue
		c += 1
		for k in 6:
			var v := clampf(needs[i * 6 + k] + _need_rate(i, k) * maxf(t - need_t[i], 0.0), 0.0, 1.0)
			avg[NpcAgent.NEEDS[k]] += v
			worst[NpcAgent.NEEDS[k]] = maxf(float(worst[NpcAgent.NEEDS[k]]), v)
			if blocked[i] & (1 << k):
				blocked_counts[NpcAgent.NEEDS[k]] = int(blocked_counts.get(NpcAgent.NEEDS[k], 0)) + 1
		var label := _activity_label(i)
		acts[label] = int(acts.get(label, 0)) + 1
		bands[NpcMorale.band(morale[i])] = int(bands[NpcMorale.band(morale[i])]) + 1
		worst_m = minf(worst_m, morale[i])
	if c > 0:
		for n in NpcAgent.NEEDS:
			avg[n] = float(avg[n]) / float(c)
	var mm := mean_morale()
	return {
		"tier": TIER, "count": c, "initial_count": _initial_roster,
		"avg_needs": avg, "worst_needs": worst, "activities": acts,
		"mean_morale": mm, "worst_morale": worst_m if c > 0 else 0.0,
		"morale_label": NpcMorale.label(mm), "morale_bands": bands,
		"blocked": blocked_counts, "blocked_share": blocked_share(),
		"collapse_risk": collapse_risk(), "collapsed": _collapsed,
		"deserted": is_deserted(), "departures": _departures.size(),
		"losses": _losses, "consequence": consequence, "catchups": _catchups,
		"walk_distance_m": 0.0, "walk_climb_m": 0.0, "walk_kcal": 0.0,
		"walk_overhead": 0.0, "walk_label": "", "need_mean_m": {},
		"departure_cause": "left" if not _departures.is_empty() else "",
	}


func _activity_label(i: int) -> String:
	var name := str(ACT_NAMES[act[i]])
	match state[i]:
		S_TRAVEL: return "-> " + (name if not name.is_empty() else "free")
		S_QUEUE: return "queue " + name
		S_DOING:
			if act[i] == A_MINGLE:
				if ckind[i] != 0:
					return str(CKIND_NAMES[ckind[i] & 3])
				return "wander" if vpose[i] == VPOSE_STAND else "chat"
			return name if not name.is_empty() else "free"
	return "idle"


func _status_line(i: int) -> String:
	var name := str(ACT_NAMES[act[i]])
	match state[i]:
		S_DOING:
			match act[i]:
				A_SLEEP: return "asleep"
				A_WORK: return "working"
				A_FREE: return "hanging out"
				A_MINGLE:
					if ckind[i] != 0:
						return NpcComfort.status_for(str(CKIND_NAMES[ckind[i] & 3]), (ckind[i] & CKIND_BED) != 0)
					return "taking in the view" if vpose[i] == VPOSE_STAND else "chatting with camp-mates"
				A_PERFORM: return "DJing"
				A_ENRICH:
					if space_type[i] == "effigy":
						return "watching the burn" if (vpose[i] == VPOSE_SIT or vpose[i] == VPOSE_LIE) else "at the effigy"
					if vpose[i] == VPOSE_RAVE:
						return "raving (Bass Stage)"
					return "%s" % SpaceTypes.label(space_type[i])
				_: return name
		S_CIRCLE:
			return "circling the fire"
		S_TRAVEL:
			if act[i] == A_SLEEP:
				return "heading home"
			if act[i] == A_MINGLE:
				match int(ckind[i] & 3):
					1: return "heading for shade"
					2: return "heading to the fire" if (ckind[i] & CKIND_BED) == 0 else "heading in to warm up"
					3: return "running for cover"
				return "wandering" if vpose[i] == VPOSE_STAND else "joining friends"
			if act[i] == A_PERFORM:
				return "heading to the decks"
			return "heading to %s" % (SpaceTypes.label(space_type[i]) if not space_type[i].is_empty() else name)
		S_QUEUE:
			return "queueing for %s" % SpaceTypes.label(space_type[i])
	return "idle"


## The dot payload the hosts already read, for every living person. One dict
## per person — Phase 4's CrowdFrame replaces this on the render side.
func agent_dots() -> Array:
	var out: Array = []
	var t := _last_abs_h if not is_nan(_last_abs_h) else 0.0
	for i in _n:
		if alive[i] == 0:
			continue
		var p := pos_at(i, t)
		var face := 0.0
		var dest := Vector2(bx[i], bz[i])
		if (state[i] == S_TRAVEL or state[i] == S_CIRCLE) and dest.distance_squared_to(p) > 1e-4:
			face = atan2(dest.x - p.x, dest.y - p.y)
		elif not is_nan(fx[i]) and Vector2(fx[i], fz[i]).distance_squared_to(p) > 1e-4:
			# The renderer's own facing (face_yaw): a venue, a sandman's view.
			face = atan2(fx[i] - p.x, fz[i] - p.y)
		else:
			face = NpcFacing.yaw_for(p, home, NpcHash.unit01(ids[i], "face") * TAU, t)
		var astate := NpcAgent.State.IDLE
		if state[i] == S_TRAVEL or state[i] == S_CIRCLE:
			astate = NpcAgent.State.TRAVELING
		elif state[i] == S_DOING or state[i] == S_QUEUE:
			astate = NpcAgent.State.DOING
		var aname := str(ACT_NAMES[act[i]])
		out.append({
			"id": ids[i], "name": NpcAgent.name_for(ids[i]), "pos": p,
			"carrying": false, "work_pose": NpcWorkPose.DIG if act[i] == A_WORK else "",
			"carry_prop": "", "color": NpcPopulationEngine.color_for_agent(ids[i]),
			"morale": morale[i], "morale_color": NpcMorale.color(morale[i]),
			"morale_label": NpcPeak.LABEL if not is_nan(peak_since[i]) else NpcMorale.label(morale[i]),
			"activity": aname, "state": astate,
			"space_type": space_type[i] if act[i] == A_ENRICH else "",
			"venue_pose": str(VPOSE_NAMES[vpose[i]]) if (act[i] == A_ENRICH or act[i] == A_MINGLE \
				or act[i] == A_PERFORM) and vpose[i] < VPOSE_NAMES.size() else "",
			"elev": elev_of(i),
			"peak_since": peak_since[i],
			"peak_buzz": buzz_of(i), "peak_fed": int(peak_fed[i]),
			"comfort": str(CKIND_NAMES[ckind[i] & 3]) if act[i] == A_MINGLE else "",
			"anim_map": {}, "ends_h": end_h[i], "status": _status_line(i),
			"trail": [], "possessed": false, "yaw": 0.0, "face_yaw": face,
			"tier": TIER,
		})
	return out


# ---------------------------------------------------------------------------
# Persistence (compact: packed arrays, base64)
# ---------------------------------------------------------------------------

func snapshot(saved_h: float) -> Dictionary:
	var t := _last_abs_h if not is_nan(_last_abs_h) else saved_h
	var pos := PackedFloat32Array()
	pos.resize(_n * 2)
	var nd := PackedFloat32Array()
	nd.resize(_n * 6)
	for i in _n:
		var p := pos_at(i, t)
		pos[i * 2] = p.x
		pos[i * 2 + 1] = p.y
		var dt := maxf(t - need_t[i], 0.0)
		for k in 6:
			nd[i * 6 + k] = clampf(needs[i * 6 + k] + _need_rate(i, k) * dt, 0.0, 1.0)
	return {
		"v": SNAPSHOT_VERSION, "tier": TIER, "n": _n, "seed_key": seed_key,
		"saved_h": snappedf(saved_h, 1.0 / 60.0),
		"home": [home.x, home.y],
		"pos": Marshalls.raw_to_base64(pos.to_byte_array()),
		"needs": Marshalls.raw_to_base64(nd.to_byte_array()),
		"morale": Marshalls.raw_to_base64(morale.to_byte_array()),
		"quit": Marshalls.raw_to_base64(quit.to_byte_array()),
		"alive": Marshalls.raw_to_base64(alive),
		"initial_roster": _initial_roster,
		"departures": _departures.duplicate(true),
		"collapsed": _collapsed, "losses": _losses,
	}


static func is_light_snapshot(snap: Dictionary) -> bool:
	return str(snap.get("tier", "")) == TIER and snap.has("pos")


func restore(snap: Dictionary) -> void:
	var n := int(snap.get("n", 0))
	seed_key = str(snap.get("seed_key", seed_key))
	var h: Array = snap.get("home", [home.x, home.y])
	home = Vector2(float(h[0]), float(h[1]))
	configure(maxi(n, 1), seed_key, home, home_slots)
	var pos := _f32(str(snap.get("pos", "")), _n * 2)
	var nd := _f32(str(snap.get("needs", "")), _n * 6)
	var mo := _f32(str(snap.get("morale", "")), _n)
	var qu := _f32(str(snap.get("quit", "")), _n)
	var al := Marshalls.base64_to_raw(str(snap.get("alive", "")))
	for i in _n:
		if pos.size() == _n * 2:
			ax[i] = pos[i * 2]
			az[i] = pos[i * 2 + 1]
			bx[i] = ax[i]
			bz[i] = az[i]
		if nd.size() == _n * 6:
			for k in 6:
				needs[i * 6 + k] = nd[i * 6 + k]
		if mo.size() == _n:
			morale[i] = mo[i]
		if qu.size() == _n:
			quit[i] = qu[i]
		if al.size() == _n:
			alive[i] = al[i]
		state[i] = S_IDLE
		next_h[i] = NAN
	_initial_roster = int(snap.get("initial_roster", _n))
	_departures = (snap.get("departures", []) as Array).duplicate(true)
	_collapsed = bool(snap.get("collapsed", false))
	_collapse_warned = _collapsed
	_losses = int(snap.get("losses", 0))
	_last_abs_h = NAN
	_all_dirty = true


static func _f32(b64: String, expect: int) -> PackedFloat32Array:
	if b64.is_empty():
		return PackedFloat32Array()
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.size() != expect * 4:
		return PackedFloat32Array()
	return bytes.to_float32_array()
