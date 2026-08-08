class_name NpcLabourLog
extends RefCounted

## Who did how much work, banked per person per sim-day.
##
## The question this exists to answer is the player's: "is the load actually
## divided evenly?" Until now that was unanswerable, because `NpcChoreBoard
## .credit()` returns the hours it applied and **every caller discarded them** —
## the work went into the chore and nothing recorded who did it.
##
## ## Two design choices worth defending
##
## **Effective hours, not wall clock.** `credit()` applies
## `dt * morale_productivity * weather_productivity`, and that is what the
## chore actually received. Banking wall-clock time instead would let a
## demoralised person working in the rain read as having pulled a full shift.
##
## **No rollover step.** `bank()` writes straight into `days[agent][day]`, and
## week and month are range sums over that. `NpcAgent._roll_day` is the shape
## NOT to copy: one `prev_day` dict, no history, no week or month, and
## `snapshot()` silently drops it — so yesterday's walking ledger dies on every
## save and nothing has ever read it anyway. Three rollovers would have been
## three chances to repeat that. Here there is nothing to forget to call.

const VERSION := 1
## A month readout plus a week of margin. Older days are pruned rather than
## kept forever: this rides `pop_state`, which is re-serialized on a timer.
const KEEP_DAYS := 35

## agent_id -> { day_index: {"h": float, "by": {category: float}} }
var days: Dictionary = {}


static func create_empty() -> NpcLabourLog:
	return NpcLabourLog.new()


## Bank hours somebody actually worked. `category` is a pose family
## (NpcWorkPose.family_for), which makes "Sam does all the hauling" answerable
## for free rather than needing its own taxonomy.
func bank(agent_id: String, day: int, hours: float, category: String = "") -> void:
	if agent_id.is_empty() or hours <= 0.0:
		return
	var per_agent: Dictionary = days.get(agent_id, {})
	var rec: Dictionary = per_agent.get(day, {"h": 0.0, "by": {}})
	rec["h"] = float(rec.get("h", 0.0)) + hours
	if not category.is_empty():
		var by: Dictionary = rec.get("by", {})
		by[category] = float(by.get(category, 0.0)) + hours
		rec["by"] = by
	per_agent[day] = rec
	days[agent_id] = per_agent


## Inclusive on both ends.
func hours_between(agent_id: String, from_day: int, to_day: int) -> float:
	var per_agent: Dictionary = days.get(agent_id, {})
	var total := 0.0
	for d in per_agent:
		var day := int(d)
		if day >= from_day and day <= to_day:
			total += float((per_agent[d] as Dictionary).get("h", 0.0))
	return total


func day_hours(agent_id: String, day: int) -> float:
	return hours_between(agent_id, day, day)


## The trailing week, today included — so it is a rolling window rather than a
## calendar week nobody's chores line up with.
func week_hours(agent_id: String, day: int) -> float:
	return hours_between(agent_id, day - 6, day)


func month_hours(agent_id: String, day: int) -> float:
	return hours_between(agent_id, day - 29, day)


## Hours by pose-family category over a window: what KIND of work this is.
func by_category(agent_id: String, from_day: int, to_day: int) -> Dictionary:
	var out: Dictionary = {}
	var per_agent: Dictionary = days.get(agent_id, {})
	for d in per_agent:
		var day := int(d)
		if day < from_day or day > to_day:
			continue
		var by: Dictionary = (per_agent[d] as Dictionary).get("by", {})
		for k in by:
			out[k] = float(out.get(k, 0.0)) + float(by[k])
	return out


## Lifetime total. The seed for the duty rotation: whoever is behind goes next.
func total_hours(agent_id: String) -> float:
	var per_agent: Dictionary = days.get(agent_id, {})
	var total := 0.0
	for d in per_agent:
		total += float((per_agent[d] as Dictionary).get("h", 0.0))
	return total


## Drop days older than `before_day`. Returns how many day-records went.
func prune(before_day: int) -> int:
	var gone := 0
	for aid in days.keys():
		var per_agent: Dictionary = days[aid]
		for d in per_agent.keys():
			if int(d) < before_day:
				per_agent.erase(d)
				gone += 1
		if per_agent.is_empty():
			days.erase(aid)
	return gone


## Forget somebody entirely (they left and are not coming back).
func forget(agent_id: String) -> void:
	days.erase(agent_id)


## Is the load even, and who is at each end?
##
## Gini is the textbook answer and the wrong one here: at a roster of twelve it
## is noisy, it needs a sort, and no player can read it. "Ava 9.5 h, Kirby
## 2.0 h" is the sentence somebody actually wants, so the spread is reported
## alongside the two names that explain it.
##
## `spread` is (max - min) / mean, which is scale-free — a 2 h gap means
## something very different on a 3 h week than on a 40 h one.
static func fairness(log_ref: NpcLabourLog, agent_ids: Array,
		from_day: int, to_day: int) -> Dictionary:
	var out := {
		"min_h": 0.0, "max_h": 0.0, "mean_h": 0.0, "spread": 0.0,
		"min_id": "", "max_id": "", "label": "even", "n": 0,
	}
	if log_ref == null or agent_ids.is_empty():
		return out
	var lo := INF
	var hi := -INF
	var sum := 0.0
	for a in agent_ids:
		var aid := str(a)
		var h := log_ref.hours_between(aid, from_day, to_day)
		sum += h
		if h < lo:
			lo = h
			out["min_id"] = aid
		if h > hi:
			hi = h
			out["max_id"] = aid
	var n := agent_ids.size()
	var mean := sum / float(n)
	out["n"] = n
	out["min_h"] = lo
	out["max_h"] = hi
	out["mean_h"] = mean
	out["spread"] = (hi - lo) / maxf(mean, 0.01)
	out["label"] = "even" if out["spread"] < 0.25 \
		else ("uneven" if out["spread"] < 0.75 else "lopsided")
	return out


## ⚠ Hours are snapped to 0.01 on the way out. `NpcPopulationBridge
## ._maybe_persist` gates writes on a JSON-blob comparison, and an unrounded
## float changes on every single tick — the ledger would defeat the gate and
## rewrite pop_state every half sim-hour.
func serialize() -> Dictionary:
	var out: Dictionary = {}
	for aid in days:
		var per_agent: Dictionary = days[aid]
		var packed: Dictionary = {}
		for d in per_agent:
			var rec: Dictionary = per_agent[d]
			var by_out: Dictionary = {}
			for k in (rec.get("by", {}) as Dictionary):
				by_out[k] = snappedf(float((rec["by"] as Dictionary)[k]), 0.01)
			packed[str(d)] = {"h": snappedf(float(rec.get("h", 0.0)), 0.01),
				"by": by_out}
		out[aid] = packed
	return {"version": VERSION, "days": out}


static func deserialize(data: Dictionary) -> NpcLabourLog:
	var log_out := NpcLabourLog.new()
	var raw: Dictionary = data.get("days", {})
	for aid in raw:
		var per_agent: Dictionary = {}
		for d in (raw[aid] as Dictionary):
			var rec: Dictionary = (raw[aid] as Dictionary)[d]
			per_agent[int(str(d))] = {
				"h": float(rec.get("h", 0.0)),
				"by": (rec.get("by", {}) as Dictionary).duplicate(),
			}
		log_out.days[str(aid)] = per_agent
	return log_out
