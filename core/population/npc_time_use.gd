class_name NpcTimeUse
extends RefCounted

## How the community spends its time (NPC life pass, Phase 9). Pure: the
## bridge samples every person's category once a tick (`step` + `record`),
## both tiers through the same two mapping functions, and this keeps hours
## per person per day for the last DAYS_KEPT days plus running totals for the
## whole session (a simkit year reads those).
##
## Categories follow the American Time Use Survey's top level where one
## exists (sleep, personal care, eating, work, leisure); walking, queueing and
## standing about have no ATUS row (the survey folds travel into each
## activity) and are shown on their own.

const CATS := ["sleep", "toilet", "wash", "eat", "drink", "work", "walk", "queue",
	"social", "venue", "idle"]

const LABELS := {
	"sleep": "Sleep", "toilet": "Toilet", "wash": "Washing", "eat": "Eating",
	"drink": "Drinking", "work": "Work", "walk": "Walking", "queue": "Queueing",
	"social": "Hanging out", "venue": "Venues & gatherings", "idle": "Idle",
}

## One colour per category for charts (dark surface).
const COLORS := {
	"sleep": Color(0.36, 0.42, 0.78), "toilet": Color(0.62, 0.52, 0.40),
	"wash": Color(0.40, 0.70, 0.86), "eat": Color(0.90, 0.66, 0.30),
	"drink": Color(0.46, 0.80, 0.84), "work": Color(0.92, 0.48, 0.34),
	"walk": Color(0.66, 0.66, 0.70), "queue": Color(0.84, 0.36, 0.42),
	"social": Color(0.56, 0.80, 0.46), "venue": Color(0.78, 0.52, 0.86),
	"idle": Color(0.42, 0.44, 0.50),
}

## BLS, American Time Use Survey 2025 annual averages, Table 1, all persons
## 15 and over, average hours per day (every day of the week, workers and
## non-workers alike). A reference to compare against, never a target.
const ATUS_2025 := {
	"sleeping": 9.03, "personal_care_other": 0.77, "eating_drinking": 1.21,
	"working": 3.32, "household": 1.99, "leisure_sports": 5.16,
}
const ATUS_SOURCE := "BLS American Time Use Survey 2025, Table 1 (all persons 15+)"

## Our categories grouped onto ATUS rows: [label, our cats, ATUS h/day or -1].
const GROUPS := [
	["Sleep", ["sleep"], 9.03],
	["Personal care", ["toilet", "wash"], 0.77],
	["Eating & drinking", ["eat", "drink"], 1.21],
	["Work (incl. household)", ["work"], 5.31],
	["Leisure & social", ["social", "venue"], 5.16],
	["Walking", ["walk"], -1.0],
	["Queueing", ["queue"], -1.0],
	["Idle", ["idle"], -1.0],
]

## Weekly work per person: up to the ATUS adult's paid work + housework
## ((3.32 + 1.99) × 7 ≈ 37 h) reads sustainable; past 50 h overloaded (an
## estimate: a 40 h job plus a full share of housework).
const SUSTAINABLE_H_WEEK := 37.0
const OVERLOADED_H_WEEK := 50.0

const DAYS_KEPT := 14
## A gap longer than this (a jump, a load) is not counted as anybody's time.
const MAX_STEP_H := 0.5
const COMPLETE_H := 23.5

## day index -> {person id: PackedFloat32Array(CATS.size())}
var days: Dictionary = {}
## day index -> hours of that day the clock was counted (a day is COMPLETE
## past COMPLETE_H; a part day is biased by its time of day: a morning has
## no sleep in it).
var day_span: Dictionary = {}
## Whole session: category -> person-hours, and person-hours in all.
var totals: Dictionary = {}
var total_h := 0.0
var _last_h := NAN


static func cat_index(cat: String) -> int:
	return CATS.find(cat)


## A full-tier person's category.
static func category_full(state: int, activity: String) -> String:
	if state == NpcAgent.State.TRAVELING:
		return "walk"
	if state != NpcAgent.State.DOING:
		return "idle"
	match activity:
		"sleep": return "sleep"
		"bladder": return "toilet"
		"hygiene": return "wash"
		"hunger": return "eat"
		"thirst": return "drink"
		NpcAgent.CHORE_ACTIVITY: return "work"
		NpcAgent.QUEUE_ACTIVITY: return "queue"
		"enrichment", NpcAgent.PERFORM_ACTIVITY: return "venue"
		NpcSocial.ACTIVITY: return "social"
	return "idle"


## A light-tier person's category (CrowdCohort's state and activity codes).
static func category_light(state: int, act: int) -> String:
	match state:
		CrowdCohort.S_TRAVEL: return "walk"
		CrowdCohort.S_QUEUE: return "queue"
		CrowdCohort.S_CIRCLE: return "venue"
		CrowdCohort.S_DOING:
			match act:
				CrowdCohort.A_SLEEP: return "sleep"
				CrowdCohort.A_BLADDER: return "toilet"
				CrowdCohort.A_HYGIENE: return "wash"
				CrowdCohort.A_HUNGER: return "eat"
				CrowdCohort.A_THIRST: return "drink"
				CrowdCohort.A_WORK: return "work"
				CrowdCohort.A_ENRICH, CrowdCohort.A_PERFORM: return "venue"
				CrowdCohort.A_MINGLE: return "social"
	return "idle"


static func day_of(abs_h: float) -> int:
	return int(floor(abs_h / 24.0))


## Advance the clock; returns the hours to credit everybody this tick (0 for
## the first tick, a jump, or a scrub back). A scrub back forgets the days
## from the one scrubbed into (their hours are about to be lived again).
func step(abs_h: float) -> float:
	if is_nan(_last_h):
		_last_h = abs_h
		return 0.0
	var dt := abs_h - _last_h
	_last_h = abs_h
	if dt < 0.0:
		var d0 := day_of(abs_h)
		for d in days.keys():
			if int(d) >= d0:
				days.erase(d)
		for d in day_span.keys():
			if int(d) >= d0:
				day_span.erase(d)
		return 0.0
	if dt > MAX_STEP_H:
		return 0.0
	# Coverage, split at midnight.
	var d1 := day_of(abs_h)
	var into := abs_h - float(d1) * 24.0
	day_span[d1] = float(day_span.get(d1, 0.0)) + minf(dt, into)
	if dt > into:
		day_span[d1 - 1] = float(day_span.get(d1 - 1, 0.0)) + (dt - into)
	return dt


func record(id: String, cat: String, h: float, abs_h: float) -> void:
	if h <= 0.0:
		return
	var ci := cat_index(cat)
	if ci < 0:
		ci = cat_index("idle")
	var d := day_of(abs_h)
	var dd: Dictionary = days.get(d, {})
	if dd.is_empty():
		days[d] = dd
		_prune(d)
	var row: PackedFloat32Array = dd.get(id, PackedFloat32Array())
	if row.is_empty():
		row.resize(CATS.size())
	row[ci] += h
	dd[id] = row
	totals[CATS[ci]] = float(totals.get(CATS[ci], 0.0)) + h
	total_h += h


func _prune(newest: int) -> void:
	for d in days.keys():
		if int(d) <= newest - DAYS_KEPT:
			days.erase(d)
	for d in day_span.keys():
		if int(d) <= newest - DAYS_KEPT:
			day_span.erase(d)


func is_complete(day: int) -> bool:
	return float(day_span.get(day, 0.0)) >= COMPLETE_H


## The last `n_days` days up to `abs_h`: hours a day per category (each
## person's recorded time scaled to 24 h), per person, the ATUS groups, work
## per person per week and its verdict. Only COMPLETE days are used once there
## is one in the window (`partial` false); before that, whatever was measured
## (`partial` true: a part day is biased by its time of day).
## `only` (id -> true) limits it to those people (one camp).
func summary(abs_h: float, n_days: int = 7, only: Dictionary = {}) -> Dictionary:
	var d1 := day_of(abs_h)
	var per: Dictionary = {}
	var measured_days := 0
	var any_complete := false
	for d in range(d1 - n_days + 1, d1 + 1):
		if days.has(d) and is_complete(d):
			any_complete = true
	for d in range(d1 - n_days + 1, d1 + 1):
		var dd: Dictionary = days.get(d, {})
		if dd.is_empty():
			continue
		if any_complete and not is_complete(d):
			continue
		measured_days += 1
		for id in dd:
			if not only.is_empty() and not only.has(id):
				continue
			var row: PackedFloat32Array = dd[id]
			var acc: PackedFloat32Array = per.get(id, PackedFloat32Array())
			if acc.is_empty():
				acc.resize(CATS.size())
			for i in CATS.size():
				acc[i] += row[i]
			per[id] = acc
	var people: Array = []
	var mean := {}
	for c in CATS:
		mean[c] = 0.0
	var all_h := 0.0
	var sum_cat := PackedFloat32Array()
	sum_cat.resize(CATS.size())
	for id in per:
		var acc: PackedFloat32Array = per[id]
		var tot := 0.0
		for i in CATS.size():
			tot += acc[i]
			sum_cat[i] += acc[i]
		all_h += tot
		var hours := {}
		for i in CATS.size():
			hours[CATS[i]] = 24.0 * acc[i] / maxf(tot, 1e-6)
		people.append({"id": str(id), "hours": hours, "recorded_h": tot,
			"work_h_week": 7.0 * 24.0 * acc[cat_index("work")] / maxf(tot, 1e-6)})
	people.sort_custom(func(a, b) -> bool: return str(a["id"]) < str(b["id"]))
	if all_h > 0.0:
		for i in CATS.size():
			mean[CATS[i]] = 24.0 * sum_cat[i] / all_h
	var groups: Array = []
	for g: Array in GROUPS:
		var h := 0.0
		for c in g[1]:
			h += float(mean[c])
		groups.append({"label": g[0], "cats": g[1], "h": h, "ref": float(g[2])})
	var work_week := 7.0 * float(mean["work"])
	return {
		"people": people.size(), "days": measured_days, "recorded_h": all_h,
		"partial": not any_complete,
		"mean": mean, "per_person": people, "groups": groups,
		"work_h_week": work_week, "verdict": verdict(work_week),
		"leisure_h_day": float(mean["social"]) + float(mean["venue"]),
	}


## Whole-session totals as hours per person per day.
func totals_per_day() -> Dictionary:
	var out := {}
	for c in CATS:
		out[c] = 24.0 * float(totals.get(c, 0.0)) / total_h if total_h > 0.0 else 0.0
	return out


static func verdict(work_h_week: float) -> String:
	if work_h_week <= SUSTAINABLE_H_WEEK:
		return "sustainable"
	if work_h_week <= OVERLOADED_H_WEEK:
		return "heavy"
	return "overloaded"


static func verdict_color(v: String) -> Color:
	match v:
		"sustainable": return Color(0.48, 0.80, 0.50)
		"heavy": return Color(0.95, 0.72, 0.30)
	return Color(0.92, 0.38, 0.36)


## The work a site's rota asks of each person per week: the person-hours of
## the planned recurring items over `horizon_days`, over the headcount.
static func demand_h_week(items: Array, people: int, horizon_days: int) -> float:
	if people <= 0 or horizon_days <= 0:
		return 0.0
	var h := 0.0
	for it in items:
		h += float((it as Dictionary).get("hours", 0.0))
	return h / float(people) * 7.0 / float(horizon_days)
