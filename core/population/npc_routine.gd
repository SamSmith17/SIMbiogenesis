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
## Festival leisure: ALWAYS doing something social (NpcSocial) — a venue
## without the enrichment gate, a conversation circle in camp, or a wander.
## FREE in a festival left people standing where they had last eaten.
const SOCIAL := "social"

const KINDS: Array = [SLEEP, BATHROOM, EAT, WASH, ENRICHMENT, WORK, FREE, SOCIAL]

const LABELS: Dictionary = {
	SLEEP: "Sleeping",
	BATHROOM: "Bathroom",
	EAT: "Eating",
	WASH: "Washing",
	ENRICHMENT: "Enrichment",
	WORK: "Work / chores",
	FREE: "Free",
	SOCIAL: "Hanging out",
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
## instead (CampTemplates). No WORK block — the festival is the point. The two
## daytime leisure blocks are SOCIAL, not FREE: FREE only reached a venue past
## the enrichment threshold, so from late morning to dinner the whole festival
## stood where it had last eaten. SOCIAL always does something (NpcSocial).
static func festival_day() -> NpcRoutine:
	var r := NpcRoutine.new()
	r.blocks = [
		{"start_h": 2.5, "end_h": 9.5, "kind": SLEEP},
		{"start_h": 9.5, "end_h": 9.5 + BATHROOM_HOURS, "kind": BATHROOM},
		{"start_h": 9.5 + BATHROOM_HOURS, "end_h": 10.5, "kind": EAT},
		{"start_h": 10.5, "end_h": 13.0, "kind": SOCIAL},
		{"start_h": 13.0, "end_h": 14.0 - BATHROOM_HOURS, "kind": EAT},
		{"start_h": 14.0 - BATHROOM_HOURS, "end_h": 14.0, "kind": BATHROOM},
		{"start_h": 14.0, "end_h": 18.0, "kind": SOCIAL},
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
## The sleep NEED may send someone to bed this long before the routine's
## SLEEP block begins. 2.5 h puts the default day (bed 23:30) at the
## long-standing 21:00 exactly, and a festival camp (bed 02:30) at midnight
## — before this the fixed 21:00 had most of a festival asleep through the
## headline set.
const EARLY_BED_H := 2.5


## People wake this long before their SLEEP block ends (plus up to 1.5 h of
## per-person jitter), so the default day (block ends 08:00) wakes at the
## long-standing 06:00 exactly. The wake hour used to be that FIXED 06:00 for
## everyone: a festival camp (bed 02:30, block to 09:30) slept about four hours
## and then stood round its beds until the block ended.
const WAKE_BEFORE_END_H := 2.0


## Does this routine serve each meal / bathroom / wash block ONCE, handing
## the rest of the block to SOCIAL? True for any routine with a SOCIAL block
## (the festival day). The default day keeps re-issuing a block's activity for
## as long as it lasts (a second meal inside the same EAT block — a
## calibration both tiers mirror); a festival camp eats three meals a day, and
## the tiers re-issued at different moments, which split their food bills.
func serves_once() -> bool:
	for b in blocks:
		if str((b as Dictionary).get("kind", "")) == SOCIAL:
			return true
	return false


## Before the sleep window opens, the sleep NEED alone sends someone to bed
## at its ordinary threshold — and a festival-goer up since 08:00 crosses it
## around 21:00, so half the crowd went to bed during the headline set
## (measured: 46 % asleep 21:00-24:00). On a FESTIVAL day (serves_once) only
## real exhaustion does it before the window; the default day is unchanged.
const FESTIVAL_LATE_BED_BAR := 0.97


## The sleep need's bar OUTSIDE the sleep window.
func early_bed_bar(default_bar: float) -> float:
	return FESTIVAL_LATE_BED_BAR if serves_once() else default_bar


## Kinds `serves_once` applies to.
const ONCE_KINDS: Array = [BATHROOM, EAT, WASH]


## The base wake hour: WAKE_BEFORE_END_H before the first SLEEP block ends,
## or `fallback` when the routine has none.
func wake_base_h(fallback: float) -> float:
	for b in blocks:
		if str((b as Dictionary).get("kind", "")) == SLEEP:
			return fposmod(float((b as Dictionary).get("end_h", fallback + WAKE_BEFORE_END_H))
				- WAKE_BEFORE_END_H, 24.0)
	return fallback


## When the sleep need's window opens: EARLY_BED_H before the first SLEEP
## block, or `fallback` when the routine has none.
func sleep_start_h(fallback: float) -> float:
	for b in blocks:
		if str((b as Dictionary).get("kind", "")) == SLEEP:
			return fposmod(float((b as Dictionary).get("start_h", fallback)) - EARLY_BED_H, 24.0)
	return fallback


## Is `hour` inside the sleep window [start, end), wrapping midnight when
## start > end (21:00 → 06:00) and plain when it does not (00:00 → 06:00)?
static func in_sleep_window(hour: float, start: float, end: float) -> bool:
	if start > end:
		return hour >= start or hour < end
	return hour >= start and hour < end


## PERSONAL SCHEDULES. The routine is a shape, not a timetable: each person
## lives their own version of it, different every day, so a camp does not
## stand up, eat and queue for the toilets in the same ten minutes. On top of
## the fixed per-person `offset_for` shift, the whole day shifts by up to
## MAX_DAY_SHIFT_H more (a new draw every day), and a SHORT block (under
## SHORT_BLOCK_H: the 5-minute bathroom visits) floats as a unit up to
## MAX_FLOAT_JITTER_H inside its neighbours (FLOAT_SHARE of each, so nothing
## reorders or vanishes). The sleep window and the wake hour move with the
## shift (NpcAgent._personal_shift / CrowdCohort._decide). Drawn from NpcHash on "<id>|<routine day>", so both
## tiers see the same day for the same person; the routine day rolls at
## `roll_h()` (the middle of the night's sleep), never mid-evening.
## ⚠ Do NOT jitter ordinary block boundaries independently: tried, it drifted
## the two tiers' morale apart past the equivalence pin (the tiers meet block
## boundaries at different moments — substeps vs events — the same trap as the
## "linger" attempts in CLAUDE.md). A whole-day shift is what both tiers
## already read identically (it is just a bigger phase offset).
const MAX_DAY_SHIFT_H := 0.6
const MAX_FLOAT_JITTER_H := 0.75
const SHORT_BLOCK_H := 0.3
const FLOAT_SHARE := 0.45
const PERSONAL_CACHE_MAX := 8192
var _personal: Dictionary = {}
var _roll_h := NAN


## The jitter key for `agent_id` at absolute sim hour `abs_h` ("" = none:
## the shared schedule). Pass it to block_at / hours_left_in_block.
func day_key(agent_id: String, abs_h: float, phase_offset_h: float = 0.0) -> String:
	if agent_id.is_empty():
		return ""
	return "%s|%d" % [agent_id, int(floor((abs_h - phase_offset_h - roll_h()) / 24.0))]


## The same person-day for the SLEEP WINDOW and the wake hour, rolling at
## midday instead: a night must keep one shift from bedtime to waking, or a
## person who just woke finds the window moved under them and goes back to
## bed (one night = one sleep session is pinned by the selftest). The key of
## the night that ENDS this morning, i.e. the routine day it belongs to.
func night_key(agent_id: String, abs_h: float, phase_offset_h: float = 0.0) -> String:
	if agent_id.is_empty():
		return ""
	return "%s|%d" % [agent_id, int(floor((abs_h - phase_offset_h - roll_h() + 12.0) / 24.0))]


## Where the routine day rolls over: the middle of the longest SLEEP block
## (05:30 on the default day, 06:00 on a festival day), else 04:00.
func roll_h() -> float:
	if is_nan(_roll_h):
		_roll_h = 4.0
		var best := -1.0
		for b in blocks:
			var bd: Dictionary = b
			if str(bd.get("kind", "")) != SLEEP:
				continue
			var s := float(bd.get("start_h", 0.0))
			var l := fposmod(float(bd.get("end_h", 0.0)) - s, 24.0)
			if l > best:
				best = l
				_roll_h = fposmod(s + l * 0.5, 24.0)
	return _roll_h


## This person's blocks for the day `key` names (cached).
func personal_blocks(key: String) -> Array:
	if key.is_empty() or blocks.size() < 2:
		return blocks
	var cached: Variant = _personal.get(key, null)
	if cached != null:
		return cached
	if _personal.size() >= PERSONAL_CACHE_MAX:
		_personal.clear()
	var n := blocks.size()
	var len_of: Array = []
	for b in blocks:
		var bd: Dictionary = b
		var l := fposmod(float(bd.get("end_h", 0.0)) - float(bd.get("start_h", 0.0)), 24.0)
		len_of.append(24.0 if (l <= 0.0 and n == 1) else l)
	# Each block's START moves by `shift[k]`; its end is the next block's start.
	var shift: Array = []
	shift.resize(n)
	shift.fill(0.0)
	var floated: Array = []
	floated.resize(n)
	floated.fill(false)
	for k in n:
		var prev := (k - 1 + n) % n
		var next := (k + 1) % n
		if float(len_of[k]) < SHORT_BLOCK_H and float(len_of[prev]) >= SHORT_BLOCK_H \
				and float(len_of[next]) >= SHORT_BLOCK_H:
			var reach := minf(MAX_FLOAT_JITTER_H, FLOAT_SHARE * minf(float(len_of[prev]), float(len_of[next])))
			var s := (NpcHash.unit01(key, "float%d" % k) * 2.0 - 1.0) * reach
			shift[k] = s
			shift[next] = s   # the short block moves whole: its end too
			floated[k] = true
			floated[next] = true
	var out: Array = []
	for k in n:
		var bd: Dictionary = (blocks[k] as Dictionary).duplicate()
		bd["start_h"] = fposmod(float(bd.get("start_h", 0.0)) + float(shift[k]), 24.0)
		bd["end_h"] = fposmod(float(bd.get("end_h", 0.0)) + float(shift[(k + 1) % n]), 24.0)
		out.append(bd)
	_personal[key] = out
	return out


## This person's extra whole-day shift for the day `key` names (0 for "").
static func day_shift(key: String) -> float:
	if key.is_empty():
		return 0.0
	return (NpcHash.unit01(key, "day") * 2.0 - 1.0) * MAX_DAY_SHIFT_H


func block_at(hour_of_day: float, phase_offset_h: float = 0.0, key: String = "") -> Dictionary:
	if blocks.is_empty():
		return {}
	var h := fposmod(hour_of_day - phase_offset_h - day_shift(key), 24.0)
	for b_v in personal_blocks(key):
		var b: Dictionary = b_v
		if _covers(b, h):
			return b
	return {"start_h": h, "end_h": h, "kind": FREE}


## Sim-hours until the current block ends (0 when it is ending now). Used to
## cut an activity short at the block boundary so people move on.
func hours_left_in_block(hour_of_day: float, phase_offset_h: float = 0.0, key: String = "") -> float:
	var b := block_at(hour_of_day, phase_offset_h, key)
	if b.is_empty():
		return 0.0
	var h := fposmod(hour_of_day - phase_offset_h - day_shift(key), 24.0)
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
	r._migrate_legacy_festival()
	return r


## Camps saved before SOCIAL existed carry the old festival day verbatim (its
## two daytime leisure blocks typed FREE), in their specs AND in the camp
## component definitions. Recognise THAT exact shape — the late SLEEP block
## (02:30-09:30), the 19:05-02:00 ENRICHMENT, no WORK — and retype those two
## FREE blocks, so a reloaded festival stops standing around. A routine the
## player authored is left alone unless it is that shape exactly.
func _migrate_legacy_festival() -> void:
	var sleep_ok := false
	var enrich_ok := false
	var free_idx: Array = []
	for i in blocks.size():
		var b: Dictionary = blocks[i]
		var k := str(b["kind"])
		var a := float(b["start_h"])
		var e := float(b["end_h"])
		if k == WORK or k == SOCIAL:
			return
		if k == SLEEP and absf(a - 2.5) < 0.01 and absf(e - 9.5) < 0.01:
			sleep_ok = true
		elif k == ENRICHMENT and absf(a - (19.0 + BATHROOM_HOURS)) < 0.01 and absf(e - 2.0) < 0.01:
			enrich_ok = true
		elif k == FREE and ((absf(a - 10.5) < 0.01 and absf(e - 13.0) < 0.01)
				or (absf(a - 14.0) < 0.01 and absf(e - 18.0) < 0.01)):
			free_idx.append(i)
	if sleep_ok and enrich_ok and free_idx.size() == 2:
		for i in free_idx:
			blocks[i]["kind"] = SOCIAL


## Keep blocks in clock order. A midnight-wrapping block sorts to the front by
## its start hour like any other; `_covers` handles the wrap, so ordering is
## only for display and editing.
func sort_blocks() -> void:
	blocks.sort_custom(func(a, b): return float(a["start_h"]) < float(b["start_h"]))
	invalidate_personal()


## Forget the cached personal schedules (call after editing `blocks`).
func invalidate_personal() -> void:
	_personal.clear()
	_roll_h = NAN


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
