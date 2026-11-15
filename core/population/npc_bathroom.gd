class_name NpcBathroom
extends RefCounted

## How often people go, and for how long (NPC life pass, Phase 4). Pure and
## static: both tiers ask the same questions with the same answers.
##
## Before this everyone went exactly three times a day, at the same three
## scheduled blocks, for five minutes each, and peeing was not told from the
## rest. A healthy adult urinates ~4-7 times a day (most commonly 6-7; the
## user's design range is 3-6) and has 1-2 bowel movements a day, most often
## in the morning after waking or eating (the gastro-colic reflex). So:
##   - each person has their own pee count (3-6, NpcHash), which sets how fast
##     their bladder fills while awake — the trips then come when it fills,
##     staggered across the camp instead of three columns a day;
##   - each person has 1 or 2 poos a day at their own hours: the first an hour
##     or so after waking, a second (for some) in the afternoon or evening;
##   - a pee takes ~2.5 minutes in a stall (door, wash), a poo 6-11.
## The routine's BATHROOM blocks become soft anchors: go before you leave if
## there is anything in it (see SOFT_BAR), not a forced visit.

## The bladder threshold a need-driven trip fires at (NpcAgent.THRESHOLD).
const THRESHOLD := 0.75
## A routine BATHROOM block sends someone only past this much need.
const SOFT_BAR := 0.3
## Waking hours the pee count is spread over.
const AWAKE_H := 16.0
## Drinks nudge the bladder (NpcAgent.DRINK_BLADDER_KICK x ~8 a day): about
## this many of the day's trips come from that alone, so the steady fill rate
## covers the rest.
const DRINK_TRIPS := 0.6

## Asleep, the kidneys make far less (antidiuretic hormone peaks at night):
## the bladder fills at this share of its waking rate. At the old shared 0.35
## a faster waking fill ran a sleeper from ~0.4 to ~0.9 by morning — past
## morale's pain line all night.
const SLEEP_FACTOR := 0.15

const PEE_H := 2.5 / 60.0
const POOP_MIN_H := 6.0 / 60.0
const POOP_SPREAD_H := 5.0 / 60.0

const PEES_MIN := 3
const PEES_MAX := 6
## Share of people with two bowel movements a day.
const TWO_POOP_SHARE := 0.35


static func pees_per_day(person: String) -> int:
	var span := PEES_MAX - PEES_MIN + 1
	return PEES_MIN + mini(int(NpcHash.unit01(person, "pees") * float(span)), span - 1)


static func poops_per_day(person: String) -> int:
	return 2 if NpcHash.unit01(person, "poops") < TWO_POOP_SHARE else 1


## Bladder fill per waking hour (NpcAgent.RISE_PER_H units).
static func bladder_rise(person: String) -> float:
	return maxf(THRESHOLD * (float(pees_per_day(person)) - DRINK_TRIPS) / AWAKE_H, 0.02)


## The day's poo times (hours of the day, may pass 24) for someone who wakes
## at `wake_h`, keyed by an integer day so each day differs.
static func poop_hours(person: String, day: int, wake_h: float) -> Array:
	var key := "%s|%d" % [person, day]
	var out: Array = [wake_h + 0.3 + NpcHash.unit01(key, "poo1") * 1.7]
	if poops_per_day(person) >= 2:
		out.append(wake_h + 6.0 + NpcHash.unit01(key, "poo2") * 7.0)
	return out


## The first poo time after `after_abs` and at or before `now_abs` (absolute
## hours), or NAN. `wake_h` is the person's usual wake hour of the day.
static func poop_due(person: String, after_abs: float, now_abs: float, wake_h: float) -> float:
	if is_nan(after_abs) or now_abs <= after_abs:
		return NAN
	var d0 := int(floor(after_abs / 24.0)) - 1
	var d1 := int(floor(now_abs / 24.0))
	for d in range(d0, d1 + 1):
		for h: float in poop_hours(person, d, wake_h):
			var at := float(d) * 24.0 + h
			if at > after_abs and at <= now_abs:
				return at
	return NAN


## The next poo time after `after_abs` (absolute hours), for timing a wake-up.
static func next_poop(person: String, after_abs: float, wake_h: float) -> float:
	var d0 := int(floor(after_abs / 24.0)) - 1
	var best := INF
	for d in range(d0, d0 + 3):
		for h: float in poop_hours(person, d, wake_h):
			var at := float(d) * 24.0 + h
			if at > after_abs and at < best:
				best = at
	return best


## How long this visit takes (hours): a poo or a pee, varied per visit.
static func visit_h(person: String, poop: bool, visit_key: String) -> float:
	var u := NpcHash.unit01(person, "visit|" + visit_key)
	if poop:
		return POOP_MIN_H + u * POOP_SPREAD_H
	return PEE_H * (0.8 + 0.4 * u)
