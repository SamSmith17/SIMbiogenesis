class_name NpcConsequence
extends RefCounted

## What happens to people when a critical resource runs out — the player's
## choice, not the sim's.
##
## Real settlements facing an empty water tank do all three of these: some
## crews down tools, some walk out, and in the worst case people die. Shipping
## only one of those as an unavoidable default would be a design decision made
## on the player's behalf, and a total-party-kill default would be a grim one.
## So it is a setting.
##
## STRIKE is the default for two reasons: it is the least morbid, and it is
## EXACTLY the behaviour that already shipped — a critical need that cannot be
## met absorbs the agent at tier 1 of the priority ladder, which is deliberate
## (POPULATION_PLAN.md §4). That means an existing save behaves byte-identically
## until the player changes the dropdown, which is a property the selftest
## asserts rather than a claim.
##
## Pure data + pure decisions; the engine owns the accumulator and the removal.

const STRIKE := "strike"
const LEAVE := "leave"
const PERISH := "perish"
const DEFAULT := STRIKE

const POLICIES: Array = [STRIKE, LEAVE, PERISH]

const LABELS: Dictionary = {
	STRIKE: "Down tools",
	LEAVE: "Walk out",
	PERISH: "Perish",
}

## Honest about what each policy does and does not cover. Morale-driven
## departure is a SEPARATE, always-on mechanic (people leave places that are
## miserable, shortage or not) — except under PERISH, which replaces it.
const BLURBS: Dictionary = {
	STRIKE: "People stop working until the shortage is fixed. Nobody dies of it — though low morale can still drive people away.",
	LEAVE: "A day without a critical resource and people pack up and go — sooner than unhappiness alone would move them.",
	PERISH: "People can die of thirst, hunger or exhaustion. They stay to the end rather than walking out. Grim, and permanent.",
}

## Sim-hours of an unmet critical need before LEAVE fires.
const LEAVE_AFTER_H := 24.0

## Sim-hours before PERISH fires, per need. Roughly the real survival windows:
## ~3 days without water, ~3 weeks without food, ~10 days without sleep. A full
## bladder is never fatal, which is why it is INF rather than absent — an
## absent key would read as 0 through `.get(k, 0.0)` and kill instantly.
const PERISH_AFTER_H: Dictionary = {
	"thirst": 72.0,
	"hunger": 504.0,
	"sleep": 240.0,
	"bladder": INF,
}


static func normalize(v: Variant) -> String:
	var s := str(v)
	return s if POLICIES.has(s) else DEFAULT


static func label(policy: String) -> String:
	return str(LABELS.get(normalize(policy), LABELS[DEFAULT]))


static func blurb(policy: String) -> String:
	return str(BLURBS.get(normalize(policy), BLURBS[DEFAULT]))


## Does `hours` of this unmet need trigger the policy? STRIKE never does — the
## absorbing tier-1 wait IS the strike, and it needs no extra mechanism.
static func triggers(policy: String, need: String, hours: float) -> bool:
	match normalize(policy):
		LEAVE:
			return hours >= LEAVE_AFTER_H
		PERISH:
			return hours >= float(PERISH_AFTER_H.get(need, INF))
	return false


## Player-facing reason string for the log and the roster readout.
static func reason_for(_policy: String, need: String) -> String:
	var texts: Dictionary = {"thirst": "no water", "hunger": "no food",
		"sleep": "nowhere to sleep", "bladder": "no restroom"}
	return str(texts.get(need, "no %s" % need))
