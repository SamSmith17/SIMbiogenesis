class_name NpcPoseMachine
extends RefCounted

## Decides what one NPC figure should be PLAYING, frame by frame.
##
## Pure logic: no scene access, no node references, no `randf()`. The avatar
## hands it inputs and reads back a clip; everything else about the animation
## system is actuation. That split is what lets the whole transition graph be
## fuzzed offline (see `_test_pose_machine`) — an `AnimationTree` only advances
## inside a live scene tree, so its behaviour could never be proven headless,
## and "a figure can never wedge" is exactly the guarantee worth proving.
##
## ## Why this class exists
##
## Animation used to be a one-line function of `moving` and `activity`, both
## sampled per frame. `NpcAgent` sets `activity` to the INTENT the moment travel
## begins, so someone walking to bed reported `activity == "sleep"` for the
## entire walk — and the clip chosen was the lying-down one. People lay down and
## slid across the site. Choosing a pose therefore has to be a function of
## *phase* (going / arriving / doing / leaving), not of intent alone, and phase
## needs memory. Hence a machine.
##
## ## Invariants
##
## - **No back-channel to the sim.** Animation never delays, blocks or
##   repositions an agent. The sim is authoritative; this class only reacts.
## - **Always interruptible.** Aborts are evaluated before any state logic, so
##   no transition can outlive the situation that started it.
## - **Bounded.** Every one-shot carries a timer, so a missed `finished` signal
##   degrades to "the transition ends slightly late", never to a stuck figure.

enum State { IDLE, WALK_START, WALK, WALK_STOP, ENTER, POSE, EXIT }

## Blend windows. Walk-ins are quicker than settling into a pose, because a
## slow blend into a gait reads as wading.
const BLEND_DEFAULT := 0.22
const BLEND_FAST := 0.12
const BLEND_CUT := 0.0

## Minimum dwell in any state. Guards against an input that oscillates the way
## the old `moving` flag did: even if something upstream chatters, what you see
## cannot.
const MIN_STATE_S := 0.15

## Hard ceiling on any one-shot, on top of its own timer.
const MAX_ONESHOT_S := 2.5

## A transition is only worth starting if there is time for the round trip.
## A 5-minute bathroom visit is 0.67 REAL seconds at 450x — shorter than one
## sit-down — so at high time scale everyone cuts straight to the pose, and at
## 1x everyone gets the full sit-down and stand-up. One comparison, no special
## cases per activity.
const ENTER_BUDGET_FRAC := 1.2

## Morale at or below which the figure switches to the dejected gait. This is
## NpcMorale's "Over It" band, chosen because it sits ABOVE the 0.12 quit
## threshold — the point is to see trouble coming, not to watch people leave.
const SAD_MORALE := 0.30
## Hysteresis, so a morale hovering on the boundary does not flicker gaits.
const SAD_HYSTERESIS := 0.03

## How long the figure may hold position while standing up, so the world does
## not slide out from under a stand-up animation. Capped hard: the sim has
## already moved on, and this is render lag against an authoritative position.
const ANCHOR_MAX_S := 1.2
const ANCHOR_MAX_M := 3.0

var _state: int = State.IDLE
var _clip: String = ""
var _backwards := false
var _blend := BLEND_DEFAULT
var _changed := false
var _state_age := 0.0
var _shot_left := 0.0
var _anchor_age := 0.0

var _activity := ""
var _space_type := ""
var _sad := false
var _walk_variant: String = ""
## The pose currently occupied. Getting OUT of something is a property of what
## you are in, not of where you are going next — and by the time an abort runs,
## `_activity` already holds the NEW intent. Looking the exit up from that made
## waking skip the get-up entirely and walk straight out of bed.
var _current_pose: String = ""

## clip -> {"len": float, "loops": bool}. Injected so the machine can be driven
## in tests with a synthetic catalog and no art installed.
var _catalog: Dictionary = {}

## Player-authored slot -> clip overrides (Routines panel, Animations tab).
## Slots are activity names, plus the enrichment SPACE types, so "what happens
## at the fire" is answerable separately from "what happens at the workshop".
var _anim_overrides: Dictionary = {}


func set_anim_overrides(overrides: Dictionary) -> void:
	_anim_overrides = overrides


## The slot name this person's current situation looks up. Enrichment resolves
## by space, everything else by activity.
func pose_slot() -> String:
	if _activity == "enrichment":
		return _space_type if not _space_type.is_empty() else "enrichment"
	return _activity if not _activity.is_empty() else "idle"


## Every slot the UI can bind a clip to, in the order it should be listed.
const SLOTS: Array = [
	"sleep", "hunger", "bladder", "hygiene", "thirst", "chore", "idle",
	"fire_circle", "movement", "quiet", "workshop_social",
]


func set_catalog(catalog: Dictionary) -> void:
	_catalog = catalog


## The gait this individual walks with (NpcRig.walk_variant_for). Purely
## cosmetic variety; falls back to the shared walk when unset.
func set_walk_variant(clip: String) -> void:
	_walk_variant = clip


# --- readers ----------------------------------------------------------------

func clip() -> String:
	return _clip


func backwards() -> bool:
	return _backwards


func blend_s() -> float:
	return _blend


## True on the step the clip or its direction changed, so the avatar only calls
## into the AnimationPlayer when something actually differs.
func changed() -> bool:
	return _changed


func state() -> int:
	return _state


func is_lying() -> bool:
	return _pose_is(NpcRig.CLIP_SLEEP)


func is_seated() -> bool:
	return _pose_is(NpcRig.CLIP_SIT) or _pose_is(NpcRig.CLIP_CLAP_SIT)


## Whether the figure should hold its ground this frame (standing up). Bounded
## by both time and accumulated distance; the caller supplies how far it has
## already lagged so the cap is enforced against reality, not just the clock.
func anchor(lag_m: float) -> bool:
	if _state != State.EXIT:
		return false
	return _anchor_age < ANCHOR_MAX_S and lag_m < ANCHOR_MAX_M


# --- the step ---------------------------------------------------------------

## `inp`: {in_transit: bool, activity: String, space_type: String,
##         morale: float, dwell_left_s: float, teleported: bool,
##         finished: bool}
func step(dt: float, inp: Dictionary) -> void:
	_changed = false
	dt = maxf(dt, 0.0)
	_state_age += dt
	if _state == State.EXIT:
		_anchor_age += dt
	else:
		_anchor_age = 0.0

	var in_transit := bool(inp.get("in_transit", false))
	var activity := str(inp.get("activity", ""))
	var space_type := str(inp.get("space_type", ""))
	var teleported := bool(inp.get("teleported", false))
	var dwell := float(inp.get("dwell_left_s", 0.0))
	_update_mood(float(inp.get("morale", 1.0)))

	var activity_changed := activity != _activity or space_type != _space_type
	_activity = activity
	_space_type = space_type

	# --- aborts, before any state logic -----------------------------------
	# The sim jumped (high time scale, catch-up, or a >25 m snap). Whatever the
	# figure was doing is meaningless now; cut, do not blend.
	if teleported:
		_hard_cut(_settled_clip(in_transit), BLEND_CUT)
		return

	# Something started moving mid-transition. Nothing a transition expresses
	# survives the body relocating, so drop it immediately.
	if in_transit and (_state == State.ENTER or _state == State.POSE
			or _state == State.IDLE or _state == State.WALK_STOP):
		if _state != State.ENTER or _state_age >= MIN_STATE_S:
			_begin_walk(activity)
			return

	# The destination changed while settling in. Re-derive from scratch.
	if activity_changed and (_state == State.ENTER or _state == State.POSE):
		_enter_activity(dwell)
		return

	# --- one-shot progress -------------------------------------------------
	# The timer is authoritative and `finished` only accelerates it: the signal
	# is missed when speed_scale changes after play(), when the figure is culled,
	# and always in headless tests.
	if _is_oneshot_state():
		_shot_left -= dt
		if bool(inp.get("finished", false)):
			_shot_left = minf(_shot_left, 0.0)
		if _shot_left > 0.0 and _state_age < MAX_ONESHOT_S:
			return
		_on_oneshot_done(in_transit, dwell)
		return

	# --- steady states ------------------------------------------------------
	match _state:
		State.IDLE:
			if in_transit:
				_begin_walk(activity)
			elif not _pose_clip().is_empty() and _pose_clip() != NpcRig.CLIP_IDLE:
				_enter_activity(dwell)
			else:
				_want(_idle_clip(), false, BLEND_DEFAULT)
		State.WALK:
			if not in_transit:
				_begin_stop()
			else:
				_want(_walk_clip(), false, BLEND_DEFAULT)
		State.POSE:
			if in_transit:
				_begin_walk(activity)
			else:
				_want(_pose_clip(), false, BLEND_DEFAULT)
		_:
			_want(_settled_clip(in_transit), false, BLEND_DEFAULT)


## Jump straight to the settled look for a situation, with no transition. Used
## when a figure enters the rigged LOD — acquiring one mid-transition and then
## aborting it would pop a half-lying body into view.
func snap_to_settled(activity: String, space_type: String, in_transit: bool) -> void:
	_activity = activity
	_space_type = space_type
	_hard_cut(_settled_clip(in_transit), BLEND_CUT)


# --- internals --------------------------------------------------------------

func _update_mood(morale: float) -> void:
	# Asymmetric thresholds: once dejected, morale must climb clear of the band
	# before the gait brightens again.
	if _sad:
		_sad = morale < SAD_MORALE + SAD_HYSTERESIS
	else:
		_sad = morale < SAD_MORALE


func _pose_is(want: String) -> bool:
	return _current_pose == want and (_state == State.POSE or _state == State.ENTER)


func _idle_clip() -> String:
	return NpcRig.CLIP_IDLE_SAD if _sad and _has(NpcRig.CLIP_IDLE_SAD) else NpcRig.CLIP_IDLE


func _walk_clip() -> String:
	if _sad and _has(NpcRig.CLIP_WALK_SAD):
		return NpcRig.CLIP_WALK_SAD
	if not _walk_variant.is_empty() and _has(_walk_variant):
		return _walk_variant
	return NpcRig.CLIP_WALK


## What this person does once they have arrived and settled.
func _pose_clip() -> String:
	# A player-authored choice wins over the built-in default, provided the clip
	# is actually installed — an override naming a missing clip must degrade to
	# the default rather than freezing the figure on nothing.
	var slot := pose_slot()
	if _anim_overrides.has(slot):
		var want := str(_anim_overrides[slot])
		if not want.is_empty() and _has(want):
			return want
	match _activity:
		"sleep":
			return NpcRig.CLIP_SLEEP
		"bladder", "hunger":
			# Seated: the bathroom visit and the meal both happen sitting down.
			# "bladder" had no entry at all before, so it rendered as standing.
			return NpcRig.CLIP_SIT
		"chore":
			return NpcRig.CLIP_WORK
		"enrichment":
			match _space_type:
				"movement":
					return NpcRig.CLIP_EXERCISE
				"fire_circle":
					# Dancing round the fire, not sitting clapping at it — the
					# gathering is the point, and the seated version read as a
					# much duller camp.
					return NpcRig.CLIP_DANCE
				"workshop_social":
					return NpcRig.CLIP_CLAP
				"quiet":
					return NpcRig.CLIP_SIT
			return NpcRig.CLIP_DANCE
	return _idle_clip()


## The enter/exit pair for a pose, or ["", ""] when it is entered by standing
## there. Sleep has a measured matched pair; sitting reuses the stand-up clip
## played backwards.
func _transitions_for(pose: String) -> Array:
	match pose:
		NpcRig.CLIP_SLEEP:
			return [NpcRig.CLIP_SLEEP_ENTER, NpcRig.CLIP_SLEEP_EXIT]
		NpcRig.CLIP_SIT, NpcRig.CLIP_CLAP_SIT:
			return [NpcRig.CLIP_SIT_ENTER, NpcRig.CLIP_SIT_EXIT]
	return ["", ""]


## `sit_enter` is not a file — it is `sit_exit` reversed.
static func _clip_file_for(clip: String) -> String:
	return NpcRig.CLIP_SIT_EXIT if clip == NpcRig.CLIP_SIT_ENTER else clip


static func _is_reversed(clip: String) -> bool:
	return clip == NpcRig.CLIP_SIT_ENTER


func _has(clip: String) -> bool:
	return _catalog.has(_clip_file_for(clip))


func _len_of(clip: String) -> float:
	var e: Dictionary = _catalog.get(_clip_file_for(clip), {})
	return float(e.get("len", 0.0))


func _settled_clip(in_transit: bool) -> String:
	return _walk_clip() if in_transit else _pose_clip()


func _is_oneshot_state() -> bool:
	return _state == State.WALK_START or _state == State.WALK_STOP \
		or _state == State.ENTER or _state == State.EXIT


func _want(clip: String, backwards: bool, blend: float) -> void:
	if clip == _clip and backwards == _backwards:
		return
	_clip = clip
	_backwards = backwards
	_blend = blend
	_changed = true


func _hard_cut(clip: String, blend: float) -> void:
	_current_pose = "" if _clip_is_walk(clip) else clip
	_go(State.POSE if not _clip_is_walk(clip) else State.WALK)
	_want(clip, _is_reversed(clip), blend)
	_blend = blend


func _clip_is_walk(clip: String) -> bool:
	return clip == NpcRig.CLIP_WALK or clip == NpcRig.CLIP_WALK_SAD \
		or clip == NpcRig.CLIP_WALK_ALT or clip == NpcRig.CLIP_WALK_ALT2


func _go(new_state: int) -> void:
	_state = new_state
	_state_age = 0.0


func _begin_oneshot(new_state: int, clip: String, blend: float) -> void:
	_go(new_state)
	_shot_left = minf(maxf(_len_of(clip), 0.05), MAX_ONESHOT_S)
	_want(clip, _is_reversed(clip), blend)


## Start walking. Uses the wind-up clip when one exists and there is a real
## journey ahead; a stride that begins from a standstill without it reads as a
## snap.
func _begin_walk(_activity: String) -> void:
	# Leaving a seated or lying pose gets its stand-up first.
	var pair := _transitions_for(_current_pose)
	if (_state == State.POSE or _state == State.ENTER) 			and not String(pair[1]).is_empty() and _has(String(pair[1])):
		_begin_oneshot(State.EXIT, String(pair[1]), BLEND_FAST)
		return
	_current_pose = ""
	if _has(NpcRig.CLIP_WALK_START) and _state != State.WALK:
		_begin_oneshot(State.WALK_START, NpcRig.CLIP_WALK_START, BLEND_FAST)
		return
	_go(State.WALK)
	_want(_walk_clip(), false, BLEND_FAST)


func _begin_stop() -> void:
	if _has(NpcRig.CLIP_WALK_STOP):
		_begin_oneshot(State.WALK_STOP, NpcRig.CLIP_WALK_STOP, BLEND_FAST)
		return
	_settle_or_enter()


## Arrived and stopped: either settle into the pose, or play the way into it.
func _settle_or_enter(dwell_left_s: float = 0.0) -> void:
	_enter_activity(dwell_left_s)


func _enter_activity(dwell_left_s: float) -> void:
	var pose := _pose_clip()
	var pair := _transitions_for(pose)
	var enter := String(pair[0])
	var exit_clip := String(pair[1])
	# Remember what is being occupied. The way OUT is looked up from this, not
	# from `_activity`, which by then holds wherever the person is headed next.
	_current_pose = pose
	if not enter.is_empty() and _has(enter) \
			and _budget_allows(enter, exit_clip, dwell_left_s):
		_begin_oneshot(State.ENTER, enter, BLEND_DEFAULT)
		return
	_go(State.POSE)
	_want(pose, false, BLEND_DEFAULT)


## Is there time to get into the pose AND back out of it before the activity
## ends? If not, cutting straight to the pose is the honest answer — half a
## sit-down that gets aborted looks worse than no sit-down at all.
func _budget_allows(enter: String, exit_clip: String, dwell_left_s: float) -> bool:
	if dwell_left_s == INF:
		return true
	var need := (_len_of(enter) + _len_of(exit_clip)) * ENTER_BUDGET_FRAC
	return dwell_left_s > need


func _on_oneshot_done(in_transit: bool, dwell_left_s: float) -> void:
	match _state:
		State.WALK_START:
			_go(State.WALK)
			_want(_walk_clip(), false, BLEND_FAST)
		State.WALK_STOP:
			_enter_activity(dwell_left_s)
		State.ENTER:
			_go(State.POSE)
			_want(_pose_clip(), false, BLEND_DEFAULT)
		State.EXIT:
			_current_pose = ""
			if in_transit:
				_go(State.WALK)
				_want(_walk_clip(), false, BLEND_FAST)
			else:
				_go(State.IDLE)
				_want(_idle_clip(), false, BLEND_DEFAULT)
		_:
			_go(State.IDLE)
			_want(_idle_clip(), false, BLEND_DEFAULT)
