class_name NpcRoutine
extends RefCounted

## A person's daily schedule: what they are *supposed* to be doing at each hour.
##
## The population sim was purely need-driven before this. That model has a
## specific failure the player can see from across the map: when an activity
## ends the agent goes IDLE and stays exactly where it finished, and because
## space selection picks the NEAREST match, standing at the restroom makes the
## restroom keep winning. Everyone pooled at the toilets. Needs alone can say
## *what* a person wants but never *where they should be next*, which is what a
## routine supplies.
##
## Needs are not replaced — they still interrupt (a desperately thirsty person
## leaves a work block), and the routine is what they return to. See
## `NpcAgent._pick` for the priority ladder that governs interruptions.
##
## Blocks are half-open [start_h, end_h) in hours-of-day and MAY wrap midnight
## (23.5 → 9.0). They are expected to tile the day with no gaps; `block_at`
## falls back to FREE for any hour left uncovered.

## Block kinds. These map to the agent's existing activities rather than
## introducing a parallel vocabulary — see `activity_for`.
const SLEEP := "sleep"
const BATHROOM := "bathroom"
const EAT := "eat"
const WASH := "wash"
const ENRICHMENT := "enrichment"
const WORK := "work"
## Nothing scheduled — needs and the chore board decide, as before.
const FREE := "free"

const KINDS: Array = [SLEEP, BATHROOM, EAT, WASH, ENRICHMENT, WORK, FREE]

const LABELS: Dictionary = {
	SLEEP: "Sleeping",
	BATHROOM: "Bathroom",
	EAT: "Eating",
	WASH: "Washing",
	ENRICHMENT: "Enrichment",
	WORK: "Work / chores",
	FREE: "Free",
}

## Block kind -> the NpcAgent activity it performs. WORK and FREE have no
## single activity (work comes off the chore board; free falls through to the
## need ladder), so they map to "".
const KIND_ACTIVITY: Dictionary = {
	SLEEP: "sleep",
	BATHROOM: "bladder",
	EAT: "hunger",
	WASH: "hygiene",
	ENRICHMENT: "enrichment",
}

## Toilet visits per day. Fixed rather than emergent because the player asked
## for a definite number and because it is what makes the waste split exact:
## each visit carries one third of the day's flush water. A need-threshold
## model produced ~6-7 visits at whatever interval the rise rate implied.
const TOILET_VISITS_PER_DAY := 3

## Water per visit, litres. 6 L is the flush volume of a standard modern
## low-flush toilet (US EPA 1.6 gal/flush ≈ 6.05 L; EU/AU dual-flush full
## volume is 6 L), so a 3-visit day is ~18 L/person — the figure that actually
## shows up in off-grid water budgets.
##
## This REPLACES the old rate-based draw (40 L/h for a 0.15 h visit = 6 L, at
## ~6.7 threshold-driven visits ≈ 40 L/person/day). Per-person toilet water
## therefore drops from ~40 L/day to ~18 L/day, which is the intended
## correction, not a rounding artifact.
const WATER_PER_VISIT_L := 6.0

## How long a bathroom visit takes. The old 0.15 h (9 min) was already a
## duration; the pooling was never about the length of the visit.
const BATHROOM_HOURS := 5.0 / 60.0

## Largest per-agent shift applied to the whole schedule, in hours. Without it
## an entire camp stands up at 09:00 exactly and walks to the toilets in one
## column. Deterministic per agent (see `offset_for`).
const MAX_PHASE_OFFSET_H := 0.5

var blocks: Array = []   # [{start_h, end_h, kind}], ordered, may wrap midnight


## The default day:
##   23:30-08:00 sleep · 08:00-08:05 bathroom · 08:05-09:00 eat
##   09:00-10:00 enrichment (yoga) · 10:00-13:00 work · 13:00-13:55 eat
##   13:55-14:00 bathroom · 14:00-18:00 work · 18:00-19:00 eat
##   19:00-19:05 bathroom · 19:05-23:00 FREE · 23:00-23:30 wash
##
## The trailing wash block: hygiene is a need the sim already models, and
## leaving it unscheduled meant it only ever fired as an interruption.
##
## TWO THINGS HERE ARE LOAD-BEARING for whether scheduled work ever finishes.
##
## 1. The evening block is **FREE, not ENRICHMENT**. Only WORK and FREE reach
##    `_begin_chore`; every other kind has a `KIND_ACTIVITY` entry, so
##    `_step_idle` calls `_begin_need(scheduled)` and returns. Typed as
##    ENRICHMENT — as it was — that four-hour block could never contribute a
##    single minute to the chore board, despite this comment calling it
##    "enrichment-or-chores" all along. FREE falls through to tier 3 (chores)
##    and then tier 4 (gathering), which is what the comment always described.
## 2. Sleep ends at 08:00, not 09:00, matching `SLEEP_END_H` (6.0) plus its
##    jitter and freeing an hour into the morning.
##
## Net: ~10.9 chore-eligible hours a day (7 WORK + 3.9 FREE) against 6 before.
## `_test_default_day_work_budget` pins that so a future routine edit cannot
## quietly re-starve the board.
static func default_day() -> NpcRoutine:
	var r := NpcRoutine.new()
	r.blocks = [
		{"start_h": 23.5, "end_h": 8.0, "kind": SLEEP},
		{"start_h": 8.0, "end_h": 8.0 + BATHROOM_HOURS, "kind": BATHROOM},
		{"start_h": 8.0 + BATHROOM_HOURS, "end_h": 9.0, "kind": EAT},
		{"start_h": 9.0, "end_h": 10.0, "kind": ENRICHMENT},
		{"start_h": 10.0, "end_h": 13.0, "kind": WORK},
		{"start_h": 13.0, "end_h": 14.0 - BATHROOM_HOURS, "kind": EAT},
		{"start_h": 14.0 - BATHROOM_HOURS, "end_h": 14.0, "kind": BATHROOM},
		{"start_h": 14.0, "end_h": 18.0, "kind": WORK},
		{"start_h": 18.0, "end_h": 19.0, "kind": EAT},
		{"start_h": 19.0, "end_h": 19.0 + BATHROOM_HOURS, "kind": BATHROOM},
		{"start_h": 19.0 + BATHROOM_HOURS, "end_h": 23.0, "kind": FREE},
		{"start_h": 23.0, "end_h": 23.5, "kind": WASH},
	]
	return r


## A FESTIVAL day: late nights at the venues, late mornings in camp. The camp
## default above sends everyone to bed at 23:30, which empties a 20:00–02:00
## stage set an hour and a half in; festival camp templates stamp this one
## instead (CampTemplates). No WORK block — the festival is the point — so
## chores on a camp board are picked up through need/free fall-through only.
static func festival_day() -> NpcRoutine:
	var r := NpcRoutine.new()
	r.blocks = [
		{"start_h": 2.5, "end_h": 9.5, "kind": SLEEP},
		{"start_h": 9.5, "end_h": 9.5 + BATHROOM_HOURS, "kind": BATHROOM},
		{"start_h": 9.5 + BATHROOM_HOURS, "end_h": 10.5, "kind": EAT},
		{"start_h": 10.5, "end_h": 13.0, "kind": FREE},
		{"start_h": 13.0, "end_h": 14.0 - BATHROOM_HOURS, "kind": EAT},
		{"start_h": 14.0 - BATHROOM_HOURS, "end_h": 14.0, "kind": BATHROOM},
		{"start_h": 14.0, "end_h": 18.0, "kind": FREE},
		{"start_h": 18.0, "end_h": 19.0, "kind": EAT},
		{"start_h": 19.0, "end_h": 19.0 + BATHROOM_HOURS, "kind": BATHROOM},
		{"start_h": 19.0 + BATHROOM_HOURS, "end_h": 2.0, "kind": ENRICHMENT},
		{"start_h": 2.0, "end_h": 2.5, "kind": WASH},
	]
	return r


## Deterministic per-agent shift so a camp does not move in lockstep. Derived
## from the agent id, so it is stable across saves and identical between runs.
static func offset_for(agent_id: String) -> float:
	# Godot's string hash for a sequence like "hab_npc_0".."hab_npc_23" is
	# nearly sequential, and taking that modulo a small number lands everyone
	# in a handful of buckets — 24 people produced 4 distinct offsets, which is
	# still a camp moving in lockstep. NpcHash avalanches the bits first so
	# neighbouring ids scatter; this call is BIT-IDENTICAL to the arithmetic
	# that used to be inline here, and the selftest pins that against a frozen
	# literal because these offsets move every downstream sim golden.
	# -MAX..+MAX, quantised finely enough to look unplanned.
	return (NpcHash.unit01(agent_id) * 2.0 - 1.0) * MAX_PHASE_OFFSET_H


## The block covering `hour_of_day` for an agent with this phase offset.
## Returns {} only when `blocks` is empty.
func block_at(hour_of_day: float, phase_offset_h: float = 0.0) -> Dictionary:
	if blocks.is_empty():
		return {}
	var h := fposmod(hour_of_day - phase_offset_h, 24.0)
	for b_v in blocks:
		var b: Dictionary = b_v
		if _covers(b, h):
			return b
	return {"start_h": h, "end_h": h, "kind": FREE}


## Sim-hours until the current block ends (0 when it is ending now). Used to
## cut an activity short at the block boundary so people move on.
func hours_left_in_block(hour_of_day: float, phase_offset_h: float = 0.0) -> float:
	var b := block_at(hour_of_day, phase_offset_h)
	if b.is_empty():
		return 0.0
	var h := fposmod(hour_of_day - phase_offset_h, 24.0)
	var end_h := float(b.get("end_h", h))
	var left := end_h - h
	if left < 0.0:
		left += 24.0   # the block wraps midnight
	return maxf(left, 0.0)


static func _covers(b: Dictionary, h: float) -> bool:
	var s := float(b.get("start_h", 0.0))
	var e := float(b.get("end_h", 0.0))
	if is_equal_approx(s, e):
		return false
	if s < e:
		return h >= s and h < e
	# Wraps midnight.
	return h >= s or h < e


## The NpcAgent activity for a block kind, or "" when the block does not name
## one (WORK defers to the chore board, FREE to the need ladder).
static func activity_for(kind: String) -> String:
	return str(KIND_ACTIVITY.get(kind, ""))


## How many bathroom blocks the day contains — the count the waste split is
## divided by, read from the routine rather than assumed, so an edited routine
## stays mass-correct.
func toilet_visits_per_day() -> int:
	var n := 0
	for b_v in blocks:
		if str((b_v as Dictionary).get("kind", "")) == BATHROOM:
			n += 1
	return n


## Litres of flush water for ONE visit, given the day's total split evenly
## across however many bathroom blocks this routine actually has. Falls back to
## the nominal per-visit volume when a routine schedules none (needs then drive
## bathroom trips as interruptions, as before).
func water_per_visit_l() -> float:
	var n := toilet_visits_per_day()
	if n <= 0:
		return WATER_PER_VISIT_L
	return (WATER_PER_VISIT_L * float(TOILET_VISITS_PER_DAY)) / float(n)


## Total scheduled hours for a kind across the day — the Routines panel reads
## this, and the selftest uses it to prove the day tiles to 24 h.
func hours_of(kind: String) -> float:
	var total := 0.0
	for b_v in blocks:
		var b: Dictionary = b_v
		if str(b.get("kind", "")) != kind:
			continue
		var s := float(b.get("start_h", 0.0))
		var e := float(b.get("end_h", 0.0))
		var d := e - s
		if d < 0.0:
			d += 24.0
		total += d
	return total


func total_hours() -> float:
	var t := 0.0
	for k in KINDS:
		t += hours_of(str(k))
	return t


# --- persistence / editing --------------------------------------------------

func to_array() -> Array:
	var out: Array = []
	for b_v in blocks:
		var b: Dictionary = b_v
		out.append({
			"start_h": snappedf(float(b.get("start_h", 0.0)), 0.001),
			"end_h": snappedf(float(b.get("end_h", 0.0)), 0.001),
			"kind": str(b.get("kind", FREE)),
		})
	return out


static func from_array(arr: Array) -> NpcRoutine:
	var r := NpcRoutine.new()
	for b_v in arr:
		if not (b_v is Dictionary):
			continue
		var b: Dictionary = b_v
		var kind := str(b.get("kind", FREE))
		if not (kind in KINDS):
			continue
		r.blocks.append({
			"start_h": fposmod(float(b.get("start_h", 0.0)), 24.0),
			"end_h": fposmod(float(b.get("end_h", 0.0)), 24.0),
			"kind": kind,
		})
	if r.blocks.is_empty():
		return default_day()
	r.sort_blocks()
	return r


## Keep blocks in clock order. A midnight-wrapping block sorts to the front by
## its start hour like any other; `_covers` handles the wrap, so ordering is
## only for display and editing.
func sort_blocks() -> void:
	blocks.sort_custom(func(a, b): return float(a["start_h"]) < float(b["start_h"]))


func duplicate_routine() -> NpcRoutine:
	return from_array(to_array())


## Human-readable time, for the editor and tooltips.
static func format_hour(h: float) -> String:
	var hh := int(floor(fposmod(h, 24.0)))
	var mm := int(round((fposmod(h, 24.0) - float(hh)) * 60.0))
	if mm >= 60:
		mm -= 60
		hh = (hh + 1) % 24
	return "%02d:%02d" % [hh, mm]
