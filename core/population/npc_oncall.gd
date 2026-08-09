class_name NpcOnCall
extends RefCounted

## Who answers when something breaks.
##
## ## The honest scope, and why it is drawn here
##
## A responder can WALK THERE and DO WORK. Where a real unit of work exists —
## a machine stalled waiting on hands, a machine still crated — the role mints
## a chore and somebody finishes it, and the problem is genuinely solved.
##
## Where no such unit exists — a dead inverter, a dry pond, a failed pump —
## nothing labour can do will fix it, because the graph has no repair model.
## Inventing one here would be a lie the player pays for later: they would
## watch somebody walk to the broken thing, work for an hour, and see the
## failure persist with no explanation. So those ESCALATE instead: the
## responder walks over to look, the alarm NAMES them, and the fix stays the
## player's. That is a smaller feature than "the crew repairs it", and it is
## the one that can be told truthfully.
##
## `_service_alarms` already computes who is worst affected by a blocked need
## and throws it away. Naming a responder is where that goes.

const VERSION := 1

## MINTS REAL WORK — a responder can actually finish these.
const FIX_MACHINE_STALLED := "machine_stalled"   # recipe_waiting_kind == "crew"
const FIX_MACHINE_PACKED := "machine_packed"     # packed_3d with a bound prop
const FIXABLE: Array = [FIX_MACHINE_STALLED, FIX_MACHINE_PACKED]

## ESCALATE ONLY. Naming who is on call IS the whole feature for these.
const ESC_NEED_UNMET := "need_unmet"
const ESC_STARVED := "starved"
const ESC_COLLAPSE_RISK := "collapse_risk"
const ESCALATE: Array = [ESC_NEED_UNMET, ESC_STARVED, ESC_COLLAPSE_RISK]

const CONDITIONS: Array = FIXABLE + ESCALATE

const CONDITION_LABELS: Dictionary = {
	FIX_MACHINE_STALLED: "A machine needs hands",
	FIX_MACHINE_PACKED: "A machine is still crated",
	ESC_NEED_UNMET: "Nobody can reach something they need",
	ESC_STARVED: "A supply has run out",
	ESC_COLLAPSE_RISK: "People are starting to leave",
}

## How long a responder spends looking at something they cannot fix. Under
## `NpcWorkPose.GATE_HOURS`, so the classifier gives it the INSPECT pose for
## free — somebody standing and assessing, which is what is actually happening.
const LOOK_HOURS := 0.05

## [{role_id, label, members: [agent_id], conditions: [String],
##   requires_skill: String}]
var roles: Array = []


static func create_empty() -> NpcOnCall:
	return NpcOnCall.new()


static func is_fixable(condition: String) -> bool:
	return FIXABLE.has(condition)


func add_role(label: String, conditions: Array, opts: Dictionary = {}) -> String:
	var rid := "role_%d" % (roles.size() + 1)
	roles.append({
		"role_id": rid,
		"label": label if not label.is_empty() else rid,
		"members": (opts.get("members", []) as Array).duplicate(),
		"conditions": conditions.duplicate(),
		"requires_skill": str(opts.get("requires_skill", "")),
	})
	return rid


func find_role(role_id: String) -> Dictionary:
	for r in roles:
		if str((r as Dictionary).get("role_id", "")) == role_id:
			return r
	return {}


func remove_role(role_id: String) -> bool:
	for i in roles.size():
		if str((roles[i] as Dictionary).get("role_id", "")) == role_id:
			roles.remove_at(i)
			return true
	return false


## The first role that answers this condition, or {}. First match wins, so
## ordering the list is how a player expresses precedence.
func role_for(condition: String) -> Dictionary:
	for r in roles:
		if ((r as Dictionary).get("conditions", []) as Array).has(condition):
			return r
	return {}


## Who takes this call: the least-worked LIVE member, so being on call does not
## fall on the same person every time. Deterministic — ties break on a hash,
## never on Array order.
##
## Returns "" when the role has no live members, which is a real state the
## caller must handle: a role whose people have all left cannot respond, and
## saying so is better than silently picking somebody who never volunteered.
func next_responder(role: Dictionary, roster_ids: Array,
		labour: NpcLabourLog, skills: NpcSkills = null) -> String:
	var live: Dictionary = {}
	for a in roster_ids:
		live[str(a)] = true
	var need := str(role.get("requires_skill", ""))
	var pool: Array = []
	for m in (role.get("members", []) as Array):
		if not live.has(str(m)):
			continue
		if not need.is_empty() and skills != null and not skills.has(str(m), need):
			continue
		pool.append(str(m))
	if pool.is_empty():
		return ""
	pool.sort_custom(func(a, b) -> bool:
		var ha := labour.total_hours(str(a)) if labour != null else 0.0
		var hb := labour.total_hours(str(b)) if labour != null else 0.0
		if absf(ha - hb) > 0.01:
			return ha < hb
		return NpcHash.unit01(str(a), "oncall") < NpcHash.unit01(str(b), "oncall"))
	return str(pool[0])


## Drop members who are no longer on the roster, so a role cannot name a ghost.
func forget_missing(live_ids: Array) -> int:
	var live: Dictionary = {}
	for a in live_ids:
		live[str(a)] = true
	var dropped := 0
	for r in roles:
		var members: Array = (r as Dictionary).get("members", []) as Array
		for i in range(members.size() - 1, -1, -1):
			if not live.has(str(members[i])):
				members.remove_at(i)
				dropped += 1
	return dropped


## The stable identity of a response, so the minter recognises its own chore
## after a reload renumbers every id.
static func chore_key_for(condition: String, subject: String,
		role_id: String) -> String:
	return "oncall|%s|%s|%s" % [condition, subject, role_id]


## Withdraw system-minted chores whose condition has cleared, and retire the
## stale keyed ones nothing will ever look up again. This is the UN-MINT half
## every minter was missing — and the `mach|` leak was a real bug: a stalled
## machine the player fixed by hand left a phantom job on the board forever,
## because `prune_completed` deliberately skips anything with a `chore_key`.
##
## The one inviolable rule: NEVER remove a chore with progress or claimed
## workers. A worker's FSM is in DOING holding that chore_id, and `_step_chore`
## finding {} would thrash. Likewise never one with an unfired `effect` — the
## bridge's post-tick sweep still needs it.
##
##   oncall| — live while its key is in `wanted` (the conditions active this
##             tick). A cleared condition withdraws an untouched response;
##             a DONE response is retired the next day.
##   mach|   — live while `mach_live.(key)` says the machine is still waiting
##             on that step. A done one whose effect fired is retired the next
##             day (the machine moved on; a re-stall mints a fresh chore).
##   duty|   — per-day instances. A done slot is retired after
##             `keep_done_days` (so "✓ done" stays readable a while); a MISSED
##             slot (its day has passed, nobody started it) is withdrawn —
##             Wednesday's lunch cannot be cooked on Friday.
##
## Returns how many chores were removed.
static func sweep_stale(board: NpcChoreBoard, wanted: Dictionary,
		mach_live: Callable, abs_hours: float,
		keep_done_days: int = NpcChoreBoard.KEEP_DONE_DAYS) -> int:
	if board == null:
		return 0
	var today := NpcChoreBoard.day_index(abs_hours)
	var gone := 0
	for i in range(board.chores.size() - 1, -1, -1):
		var c: Dictionary = board.chores[i]
		var key := str(c.get("chore_key", ""))
		if key.is_empty():
			continue
		var is_oncall := key.begins_with("oncall|")
		var is_mach := key.begins_with("mach|")
		var is_duty := key.begins_with("duty|")
		if not (is_oncall or is_mach or is_duty):
			continue
		if float(c.get("progress_h", 0.0)) > 0.0 and int(c.get("done_day", -1)) < 0:
			continue   # in flight — someone has real work in it
		if not (c.get("workers", []) as Array).is_empty():
			continue   # claimed — an FSM holds this id
		if c.has("effect") and not bool(c.get("effect_done", false)) \
				and int(c.get("done_day", -1)) >= 0:
			continue   # completed but its world effect has not fired yet
		var done := int(c.get("done_day", -1))
		var remove := false
		if is_oncall:
			if done >= 0:
				remove = done < today
			else:
				remove = not wanted.has(key)
		elif is_mach:
			var live := mach_live.is_valid() and bool(mach_live.call(key))
			if done >= 0:
				remove = done < today
			else:
				remove = not live
		elif is_duty:
			var slot_day := int(key.get_slice("|", 2))
			if done >= 0:
				remove = done <= today - maxi(keep_done_days, 0)
			else:
				remove = slot_day < today   # missed — its day has passed
		if remove:
			board.chores.remove_at(i)
			gone += 1
	return gone


func serialize() -> Dictionary:
	return {"version": VERSION, "roles": roles.duplicate(true)}


func load_from(data: Dictionary) -> void:
	roles = (data.get("roles", []) as Array).duplicate(true)
