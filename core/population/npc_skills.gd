class_name NpcSkills
extends RefCounted

## Who is qualified to do what, and how somebody becomes qualified.
##
## Most work needs hands. Some work needs knowing how — commissioning a solar
## system, treating an injury, welding a frame — and until now the sim had no
## way to say so: `NpcAgent` carried no field that could hold a qualification,
## and `specs.role` is a graph-item discriminator, unrelated to people.
##
## ## Two rules that keep this from becoming a trap
##
## **Tags live OUTSIDE pop_state.** They persist in `specs.pop_skills`, the
## sibling of `pop_routine` / `pop_consequence` / `pop_anim_map`, so a "Reset
## population" does not wipe the settlement's accumulated expertise. Agent ids
## are regenerated identically by `configure`, so the tags reattach to the same
## slots by construction.
##
## **An unsatisfiable requirement must never hide the work.** The gating rule
## lives in `NpcChoreBoard.available_for` and reads: skip a required-skill
## chore for an unqualified agent ONLY when somebody else on site is qualified.
## If nobody is, it stays offerable to everyone — the work gets done badly
## rather than not at all, and the board can SAY so. A chore that silently
## vanishes because nobody can do it is the hygiene-stall bug wearing a hat.
##
## ## Training
##
## Working a required-skill chore beside somebody qualified earns progress
## toward the tag. Unsupervised practice also counts, at `SOLO_RATE` — slowly,
## but it means a settlement that loses its only electrician is set back rather
## than permanently locked out of its own solar array.

const VERSION := 1

const COOK := "cook"
const MEDIC := "medic"
const ELECTRICAL := "electrical"
const MECHANIC := "mechanic"
const WATER := "water"
const BUILD := "build"
const TAGS: Array = [COOK, MEDIC, ELECTRICAL, MECHANIC, WATER, BUILD]

const LABELS: Dictionary = {
	COOK: "Cook", MEDIC: "Medic", ELECTRICAL: "Electrical",
	MECHANIC: "Mechanic", WATER: "Water systems", BUILD: "Construction",
}

## Level at which somebody counts as qualified.
const QUALIFIED := 1.0
## Supervised sim-hours to earn a tag from nothing. Four working days beside
## someone who knows how.
const TRAIN_HOURS := 40.0
## Unsupervised practice, as a fraction of the supervised rate.
const SOLO_RATE := 0.25

## agent_id -> {tag: 0..1}
var by_agent: Dictionary = {}


static func create_empty() -> NpcSkills:
	return NpcSkills.new()


static func label(tag: String) -> String:
	return str(LABELS.get(tag, tag.capitalize()))


func level(agent_id: String, tag: String) -> float:
	return float((by_agent.get(agent_id, {}) as Dictionary).get(tag, 0.0))


func has(agent_id: String, tag: String) -> bool:
	return level(agent_id, tag) >= QUALIFIED


## Qualified tags only, in the shape available_for wants: {tag: true}.
func tags_of(agent_id: String) -> Dictionary:
	var out: Dictionary = {}
	for t in (by_agent.get(agent_id, {}) as Dictionary):
		if float((by_agent[agent_id] as Dictionary)[t]) >= QUALIFIED:
			out[str(t)] = true
	return out


func grant(agent_id: String, tag: String) -> void:
	var per: Dictionary = by_agent.get(agent_id, {})
	per[tag] = QUALIFIED
	by_agent[agent_id] = per


func revoke(agent_id: String, tag: String) -> void:
	var per: Dictionary = by_agent.get(agent_id, {})
	per.erase(tag)
	if per.is_empty():
		by_agent.erase(agent_id)
	else:
		by_agent[agent_id] = per


## Bank practice. Returns TRUE only on the tick the tag is EARNED, so the
## caller logs it exactly once rather than every tick thereafter.
func train(agent_id: String, tag: String, hours: float, supervised: bool) -> bool:
	if agent_id.is_empty() or tag.is_empty() or hours <= 0.0:
		return false
	var was := level(agent_id, tag)
	if was >= QUALIFIED:
		return false
	var rate := 1.0 if supervised else SOLO_RATE
	var now := minf(was + (hours * rate) / TRAIN_HOURS, QUALIFIED)
	var per: Dictionary = by_agent.get(agent_id, {})
	per[tag] = now
	by_agent[agent_id] = per
	return now >= QUALIFIED and was < QUALIFIED


## Which tags anybody on this roster holds. Feeds `NpcChoreBoard.skill_supply`,
## and an EMPTY result means "skills are not configured here", which makes
## every requirement inert rather than blocking.
func supply(roster_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	for a in roster_ids:
		for t in tags_of(str(a)):
			out[t] = true
	return out


## Everyone on the roster qualified for `tag`, sorted for determinism. An
## EMPTY tag means "anyone can do this", which is most work.
func qualified_pool(tag: String, roster_ids: Array) -> Array:
	var out: Array = []
	for a in roster_ids:
		if tag.is_empty() or has(str(a), tag):
			out.append(str(a))
	out.sort()
	return out


## Drop people who are not on the roster any more. Called on departure, so a
## dead id cannot be picked for a duty slot.
func forget_missing(live_ids: Array) -> int:
	var live: Dictionary = {}
	for a in live_ids:
		live[str(a)] = true
	var gone := 0
	for aid in by_agent.keys():
		if not live.has(str(aid)):
			by_agent.erase(aid)
			gone += 1
	return gone


func serialize() -> Dictionary:
	var out: Dictionary = {}
	for aid in by_agent:
		var per: Dictionary = {}
		for t in (by_agent[aid] as Dictionary):
			per[str(t)] = snappedf(float((by_agent[aid] as Dictionary)[t]), 0.001)
		out[str(aid)] = per
	return {"version": VERSION, "by_agent": out}


static func deserialize(data: Dictionary) -> NpcSkills:
	var s := NpcSkills.new()
	for aid in (data.get("by_agent", {}) as Dictionary):
		var per: Dictionary = {}
		for t in ((data["by_agent"] as Dictionary)[aid] as Dictionary):
			per[str(t)] = float(((data["by_agent"] as Dictionary)[aid] as Dictionary)[t])
		s.by_agent[str(aid)] = per
	return s
