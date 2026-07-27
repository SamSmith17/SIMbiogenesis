class_name NpcChoreBoard
extends RefCounted

## The site's work queue: non-survival jobs people do once their critical
## needs are quiet — hauling, tending machines, repairs, maintenance.
##
## Labour is expressed in `chore_hours`, the ResourceKind the process-recipe
## system already consumes, so NPC work SUPPLIES the existing ledger rather
## than forking a parallel economy.
##
## A chore record:
##   { id, label,
##     target: {kind: "prop"|"graph_item"|"space", id: "..."},
##     space_type: "",            # optional space the work happens at
##     chore_hours: 0.5,          # labour to complete one run
##     window: {start_h, end_h},  # daily availability (hour of day)
##     repeat: "daily"|"once"|"on_demand",
##     exposure: "indoor"|"sheltered"|"outdoor",
##     priority: 0,               # lower sorts first
##     assigned_to: "",           # agent id, "" = anyone free
##     progress_h: 0.0,
##     worker: "",                # agent currently on it (runtime only)
##     done_day: -1 }             # sim-day index this run completed
##
## Persistence rides the habitat item's specs (same change-gated path as
## pop_state), so a site's routines survive save/load with the graph.

const VERSION := 1
const MAX_CHORES := 64

var chores: Array = []
var _next_id := 1


static func create_empty() -> NpcChoreBoard:
	return NpcChoreBoard.new()


# --- authoring --------------------------------------------------------------

func add_chore(label: String, chore_hours: float, opts: Dictionary = {}) -> String:
	if chores.size() >= MAX_CHORES:
		return ""
	var rec := {
		"id": "chore_%d" % _next_id,
		"label": label if not label.is_empty() else "Chore %d" % _next_id,
		"target": opts.get("target", {}),
		"space_type": str(opts.get("space_type", "")),
		"chore_hours": maxf(chore_hours, 0.01),
		"window": opts.get("window", {"start_h": 8.0, "end_h": 18.0}),
		"repeat": str(opts.get("repeat", "daily")),
		"exposure": str(opts.get("exposure", NpcWeatherGate.EXPOSURE_OUTDOOR)),
		"priority": int(opts.get("priority", 0)),
		"assigned_to": str(opts.get("assigned_to", "")),
		"progress_h": 0.0,
		"worker": "",
		"done_day": -1,
	}
	_next_id += 1
	chores.append(rec)
	return str(rec["id"])


func remove_chore(chore_id: String) -> bool:
	for i in chores.size():
		if str((chores[i] as Dictionary).get("id", "")) == chore_id:
			chores.remove_at(i)
			return true
	return false


func find(chore_id: String) -> Dictionary:
	for c in chores:
		if str((c as Dictionary).get("id", "")) == chore_id:
			return c
	return {}


func update_chore(chore_id: String, patch: Dictionary) -> bool:
	var rec := find(chore_id)
	if rec.is_empty():
		return false
	for k in patch:
		rec[k] = patch[k]
	return true


# --- scheduling -------------------------------------------------------------

static func day_index(abs_hours: float) -> int:
	return int(floor(abs_hours / 24.0))


## Is this chore's daily window open at `hour_of_day`? Windows may wrap
## midnight (e.g. a 22:00-02:00 night check).
static func window_open(chore: Dictionary, hour_of_day: float) -> bool:
	var w: Dictionary = chore.get("window", {})
	var s := float(w.get("start_h", 0.0))
	var e := float(w.get("end_h", 24.0))
	var h := fposmod(hour_of_day, 24.0)
	if s <= e:
		return h >= s and h < e
	return h >= s or h < e   # wraps midnight


## Chores reset each sim-day (daily), never (once), or when re-armed
## (on_demand — the machine that needs feeding republishes it).
func _is_due(chore: Dictionary, abs_hours: float) -> bool:
	var repeat := str(chore.get("repeat", "daily"))
	var done_day := int(chore.get("done_day", -1))
	if done_day < 0:
		return true
	match repeat:
		"daily": return day_index(abs_hours) > done_day
		"once": return false
	return false   # on_demand: re-armed explicitly via rearm()


func rearm(chore_id: String) -> void:
	var rec := find(chore_id)
	if not rec.is_empty():
		rec["done_day"] = -1
		rec["progress_h"] = 0.0


## Chores this agent could pick up right now, best first. Filters by
## assignment, due-ness, window, live worker, and weather safety; sorts by
## player priority then remaining work (finish what's nearly done).
func available_for(agent_id: String, abs_hours: float, hour_of_day: float,
		weather: Dictionary = {}) -> Array:
	var out: Array = []
	for c in chores:
		var chore: Dictionary = c
		var assigned := str(chore.get("assigned_to", ""))
		if not assigned.is_empty() and assigned != agent_id:
			continue
		var worker := str(chore.get("worker", ""))
		if not worker.is_empty() and worker != agent_id:
			continue
		if not _is_due(chore, abs_hours):
			continue
		if not window_open(chore, hour_of_day):
			continue
		if NpcWeatherGate.is_unsafe(weather, str(chore.get("exposure", "outdoor"))):
			continue
		out.append(chore)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := int(a.get("priority", 0))
		var pb := int(b.get("priority", 0))
		if pa != pb:
			return pa < pb
		return _remaining(a) < _remaining(b))
	return out


static func _remaining(chore: Dictionary) -> float:
	return maxf(float(chore.get("chore_hours", 0.0)) - float(chore.get("progress_h", 0.0)), 0.0)


func remaining(chore_id: String) -> float:
	return _remaining(find(chore_id))


func claim(chore_id: String, agent_id: String) -> bool:
	var rec := find(chore_id)
	if rec.is_empty():
		return false
	var worker := str(rec.get("worker", ""))
	if not worker.is_empty() and worker != agent_id:
		return false
	rec["worker"] = agent_id
	return true


func release(chore_id: String, agent_id: String) -> void:
	var rec := find(chore_id)
	if not rec.is_empty() and str(rec.get("worker", "")) == agent_id:
		rec["worker"] = ""


func release_all_for_agent(agent_id: String) -> void:
	for c in chores:
		if str((c as Dictionary).get("worker", "")) == agent_id:
			(c as Dictionary)["worker"] = ""


## Credit `hours` of effective labour. Returns the chore_hours actually
## applied (never more than what was left), so the ledger stays mass-exact.
func credit(chore_id: String, hours: float, abs_hours: float) -> float:
	var rec := find(chore_id)
	if rec.is_empty() or hours <= 0.0:
		return 0.0
	var left := _remaining(rec)
	var applied := minf(hours, left)
	rec["progress_h"] = float(rec.get("progress_h", 0.0)) + applied
	if _remaining(rec) <= 0.0001:
		rec["done_day"] = day_index(abs_hours)
		rec["progress_h"] = 0.0
		rec["worker"] = ""
	return applied


## Total labour a given agent is on the hook for today — feeds the day-plan
## strip and the free-time calculation that gates enrichment.
func assigned_hours_for(agent_id: String, abs_hours: float) -> float:
	var total := 0.0
	for c in chores:
		var chore: Dictionary = c
		if str(chore.get("assigned_to", "")) != agent_id:
			continue
		if not _is_due(chore, abs_hours):
			continue
		total += _remaining(chore)
	return total


## Unassigned due work, spread across the roster — what "anyone free" costs
## each person on average.
func shared_hours_per_agent(roster_size: int, abs_hours: float) -> float:
	if roster_size <= 0:
		return 0.0
	var total := 0.0
	for c in chores:
		var chore: Dictionary = c
		if not str(chore.get("assigned_to", "")).is_empty():
			continue
		if not _is_due(chore, abs_hours):
			continue
		total += _remaining(chore)
	return total / float(roster_size)


## Backlog: due work whose window has already closed today.
func backlog_hours(abs_hours: float, hour_of_day: float) -> float:
	var total := 0.0
	for c in chores:
		var chore: Dictionary = c
		if not _is_due(chore, abs_hours):
			continue
		if window_open(chore, hour_of_day):
			continue
		var w: Dictionary = chore.get("window", {})
		if fposmod(hour_of_day, 24.0) > float(w.get("end_h", 24.0)):
			total += _remaining(chore)
	return total


# --- persistence ------------------------------------------------------------

func serialize() -> Dictionary:
	var out: Array = []
	for c in chores:
		var rec: Dictionary = (c as Dictionary).duplicate(true)
		rec.erase("worker")   # runtime-only claim
		out.append(rec)
	return {"version": VERSION, "next_id": _next_id, "chores": out}


func deserialize(data: Dictionary) -> void:
	chores = []
	_next_id = int(data.get("next_id", 1))
	for item in data.get("chores", []):
		if not (item is Dictionary):
			continue
		var rec: Dictionary = (item as Dictionary).duplicate(true)
		rec["worker"] = ""
		chores.append(rec)
		var n := str(rec.get("id", "")).trim_prefix("chore_").to_int()
		_next_id = maxi(_next_id, n + 1)
