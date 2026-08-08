class_name NpcWorkPose
extends RefCounted

## Which WORK a chore is, expressed as a pose family.
##
## A chore record has no `kind` field, and adding one would mean every producer
## remembering to set it. It does not need one: the work is already named by
## what it DOES — `haul.strategy`, `carry_to`, a `chore_key` prefixed `mach|`,
## and above all `effect.op` plus `effect.phase`, which carries the real
## fabrication phase names the Linkage Lab stamps (`cut`, `drill`, `assemble*`,
## `brackets`, `bolts`, `fold_test`), while `erect` and `panels` arrive as
## `unpack_prop` and `seed_graph`.
##
## Deliberately NOT used: the chore `label` (free text a player can rename, so
## a pose that depended on it would break the moment somebody typed something),
## and `SiteProject.kind` (bridge-side, unreachable from a pure classifier, and
## redundant — the effect vocabulary already names the work more precisely).
##
## Pure static: a Dictionary in, a String out. It lives here rather than inside
## `NpcPoseMachine` because the machine is a state machine over PHASES of an
## activity, not a taxonomy of jobs — and because this has to be callable from
## `NpcPopulationEngine.agent_dots()`, which is where the chore record and the
## board are actually in hand.
##
## ## Why seven, and why these seven
##
## Families are chosen to differ in SILHOUETTE at ~60 m, the distance the
## settlement view's "block" stop puts you at. Anything you can only tell apart
## by looking at the hands is not a family, it is a detail — and details cost
## the same to maintain while reading as noise.

const HAUL_HOLD := "haul_hold"   ## brigade post: load hugged, arms forward
const LIFT := "lift"             ## deep squat-and-stand — the crate family
const DIG := "dig"               ## stooped, staggered feet, rocking. The default.
const OVERHEAD := "overhead"     ## arms up and alternating — raises, panels
const DRILL := "drill"           ## braced push with a periodic recoil
const BENCH := "bench"           ## upright, forearms level — machine tending
const INSPECT := "inspect"       ## hand to brow, slow turn — a gate chore

const FAMILIES: Array = [HAUL_HOLD, LIFT, DIG, OVERHEAD, DRILL, BENCH, INSPECT]

## Logical clips — NOT files. `NpcPoseMachine._clip_file_for` aliases every one
## of them onto `NpcRig.CLIP_WORK`, exactly as it already does for
## `sit_enter`→`sit_exit` and `carry`→`walk`. So the rigged Mixamo body plays
## its single `work` clip precisely as it does today, while `NpcSimpleFigure`
## — which already matches the LOGICAL name first, before the file mapping
## collapses it — draws the real family. That asymmetry is deliberate and
## permanent until somebody authors more Mixamo clips: the FBX folder is
## gitignored, so the stick figure is the normal state on a fresh clone and is
## where the expressiveness belongs.
const CLIP_BY_FAMILY: Dictionary = {
	HAUL_HOLD: NpcRig.CLIP_CARRY_IDLE,
	LIFT: "work_lift",
	DIG: "work_dig",
	OVERHEAD: "work_overhead",
	DRILL: "work_drill",
	BENCH: "work_bench",
	INSPECT: "work_inspect",
}

## Procedural transitions. Also not files — see `merge_catalog`.
const CLIP_WORK_ENTER := "work_enter"
const CLIP_WORK_EXIT := "work_exit"

## Authored lengths for the synthetic entries, in seconds. The exit is longer
## than the enter because straightening up out of a stoop is the transition
## that actually reads; squaring up to start is half a beat.
const ENTER_LEN_S := 0.35
const EXIT_LEN_S := 0.45
## Nominal loop length for the work families. Only used for budget maths — the
## stick figure drives itself from its own phase accumulator.
const WORK_LEN_S := 1.6

## Below this a chore is a checkpoint, not a job — the "delivery unloaded" gate
## row is 0.05 h. Somebody looking it over reads better than somebody digging
## for three seconds.
const GATE_HOURS := 0.06


## The pose family for a chore. TOTAL — never returns "", so every caller can
## use the result without a fallback of its own.
static func family_for(chore: Dictionary) -> String:
	if chore.is_empty():
		return DIG

	# 1. A relay post. Subsumes the pose machine's old `carrying` special case:
	#    a DOING agent flagged carrying IS the brigade station worker, since
	#    `is_carrying()` is TRAVELING-only. One rule, not two.
	var haul: Dictionary = chore.get("haul", {})
	if str(haul.get("strategy", "")) == "brigade":
		return HAUL_HOLD

	# 2. A brigade whose haul dict went missing but whose stage effects still
	#    move crates one at a time. Same job, so the same pose.
	var stages: Array = chore.get("stage_effects", []) as Array
	if not stages.is_empty():
		var all_moves := true
		for st in stages:
			var eff: Dictionary = (st as Dictionary).get("effect", {})
			if str(eff.get("op", "")) != "move_prop":
				all_moves = false
				break
		if all_moves:
			return HAUL_HOLD

	# 3. A round-trip carry leg: pick it up, put it down.
	if chore.has("carry_to"):
		return LIFT

	# 4. Machine-minted labour (NpcPopulationBridge keys these `mach|<gid>|<step>`).
	if str(chore.get("chore_key", "")).begins_with("mach|"):
		return BENCH

	# 5. What the completed work DOES to the world is the best name for it.
	var effect: Dictionary = chore.get("effect", {})
	match str(effect.get("op", "")):
		"recipe_step_done":
			return BENCH
		"unpack_prop", "pack_prop", "move_prop", "remove_prop", "spawn_prop":
			return LIFT
		"seed_graph":
			return OVERHEAD          # mounting panels
		"set_build_phase":
			return _family_for_phase(str(effect.get("phase", "")))

	# 6. Crew work is a raise or a mount — either way, arms up.
	if int(chore.get("min_workers", 1)) >= 2:
		return OVERHEAD

	# 7. A checkpoint with no world effect.
	if float(chore.get("chore_hours", 1.0)) <= GATE_HOURS and effect.is_empty():
		return INSPECT

	# 8. Work at a tagged space is bench work.
	if not str(chore.get("space_type", "")).is_empty():
		return BENCH

	return DIG


## The Linkage Lab's fabrication phases, which are `NpcCrewPlan.linkage_fab_tasks`
## ids stamped through `set_build_phase`.
static func _family_for_phase(phase: String) -> String:
	if phase == "cut" or phase == "drill":
		return DRILL
	if phase == "fold_test":
		return LIFT
	if phase.begins_with("assemble") or phase == "brackets" or phase == "bolts":
		return OVERHEAD
	return DIG


static func clip_for(family: String) -> String:
	return str(CLIP_BY_FAMILY.get(family, CLIP_BY_FAMILY[DIG]))


static func is_work_clip(clip: String) -> bool:
	return clip.begins_with("work_") and clip != CLIP_WORK_ENTER \
		and clip != CLIP_WORK_EXIT


## Add the synthetic entries to a rig catalog.
##
## ⚠ This must be applied at `NpcAvatar.setup`, NOT inside `NpcRig.catalog()`.
## `catalog()` answers "what animation art is actually installed", other callers
## depend on that meaning, and the whole point here is clips that exist without
## any art at all.
##
## Without this the transitions silently vanish on exactly the body they were
## written for: `NpcPoseMachine._has()` reads the catalog, `Imported Models/NPC/`
## is gitignored, so on a fresh clone the catalog is EMPTY and every `_has`
## guard skips. (The same condition means `sleep_enter`/`sit_enter` do not play
## on a fresh clone either — a real gap, but widening this merge to cover them
## would change sleep and sit behaviour for every player without the art, which
## is a separate decision and not this one.)
static func merge_catalog(base: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	out[CLIP_WORK_ENTER] = {"len": ENTER_LEN_S, "loops": false}
	out[CLIP_WORK_EXIT] = {"len": EXIT_LEN_S, "loops": false}
	for fam in FAMILIES:
		var c := clip_for(str(fam))
		if is_work_clip(c):
			out[c] = {"len": WORK_LEN_S, "loops": true}
	return out
