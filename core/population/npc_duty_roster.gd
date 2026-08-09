class_name NpcDutyRoster
extends RefCounted

## "Monday, Sam and Ava make lunch; Seva and Kirby make dinner."
##
## A DUTY is a recurring slot template. A SLOT is one generated instance of it:
## a day, a duty, and the NAMES.
##
## ## This is a generator, not a second scheduler
##
## It writes `assigned_to` onto chores the board already owns, at the start of
## each day, and then gets out of the way. `available_for`'s assignment filter,
## the panel's rendering and `assigned_hours_for` all already do the right
## thing with that field. The board stays the single source of truth for what
## work exists, which is what stops the two drifting — a second queue with its
## own idea of the schedule is how you get a UI that disagrees with the sim.
##
## ## Why a roster and not just fairer chore-picking
##
## Least-worked-first ask order was tried first and measured to change nothing:
## who works is decided by who happens to be FREE when a chore comes due, and
## the routine phase offsets make that reliably the same people. Two of six did
## all the work either way. Equal rotation needs NAMED slots — the chore is
## yours and it waits for you (for `ASSIGN_HOLD_H`, then anyone may cover).
##
## ## Persistence is split on purpose
##
## `duties` are CONFIG and live in `specs.pop_duties`, beside `pop_routine`.
## `slots` are simulation state and ride `pop_state`. Resetting a collapsed
## settlement should keep the rota the player wrote and discard who happened to
## be on last Tuesday.

const VERSION := 1
## How far ahead slots are generated. Far enough to show a week's calendar;
## near enough that a roster change does not invalidate a month of planning.
const HORIZON_DAYS := 7
## How long a rostered slot waits for its named person before anyone may cover.
## Two hours: long enough to cover a meal or a long sleep-in, short enough that
## the job still gets done the same day.
const ASSIGN_HOLD_H := 2.0

## [{duty_id, label, chore_hours, window, crew, repeat, repeat_dow,
##   repeat_days, requires_skill, exposure, priority, target}]
var duties: Array = []
## [{day, duty_id, agents: [id], chore_id, state}]
## state: planned | minted | done
var slots: Array = []


static func create_empty() -> NpcDutyRoster:
	return NpcDutyRoster.new()


func add_duty(label: String, chore_hours: float, opts: Dictionary = {}) -> String:
	var did := "duty_%d" % (duties.size() + 1)
	duties.append({
		"duty_id": did,
		"label": label if not label.is_empty() else did,
		"chore_hours": maxf(chore_hours, 0.01),
		"window": opts.get("window", {"start_h": 11.0, "end_h": 14.0}),
		"crew": maxi(int(opts.get("crew", 1)), 1),
		"repeat": NpcChoreBoard.normalize_repeat(opts.get("repeat", "daily")),
		"repeat_dow": (opts.get("repeat_dow", []) as Array).duplicate(),
		"repeat_days": maxi(int(opts.get("repeat_days", 1)), 1),
		"requires_skill": str(opts.get("requires_skill", "")),
		"exposure": str(opts.get("exposure", NpcWeatherGate.EXPOSURE_SHELTERED)),
		"priority": int(opts.get("priority", 10)),
		"target": (opts.get("target", {}) as Dictionary).duplicate(true),
	})
	return did


func find_duty(duty_id: String) -> Dictionary:
	for d in duties:
		if str((d as Dictionary).get("duty_id", "")) == duty_id:
			return d
	return {}


func remove_duty(duty_id: String) -> bool:
	for i in duties.size():
		if str((duties[i] as Dictionary).get("duty_id", "")) == duty_id:
			duties.remove_at(i)
			for j in range(slots.size() - 1, -1, -1):
				if str((slots[j] as Dictionary).get("duty_id", "")) == duty_id:
					slots.remove_at(j)
			return true
	return false


## Does this duty fall on `day`?
##
## Reuses the board's recurrence vocabulary rather than inventing a second one,
## by handing it a synthetic record whose `done_day` is the day before — which
## asks exactly "would this be due today".
static func duty_falls_on(duty: Dictionary, day: int) -> bool:
	match NpcChoreBoard.normalize_repeat(duty.get("repeat", "daily")):
		"daily":
			return true
		"once":
			return false
		"every_n":
			return posmod(day, maxi(int(duty.get("repeat_days", 1)), 1)) == 0
		"weekly":
			var dow: Array = duty.get("repeat_dow", []) as Array
			if dow.is_empty():
				return posmod(day, 7) == 0
			return dow.has(NpcChoreBoard.weekday_of_day(day))
	return false


func slot_for(day: int, duty_id: String) -> Dictionary:
	for s in slots:
		var sd: Dictionary = s
		if int(sd.get("day", -1)) == day and str(sd.get("duty_id", "")) == duty_id:
			return sd
	return {}


## Fill the calendar from `from_day` forward.
##
## NEVER touches a slot that is not still `planned` — a minted or done day is
## history, and regenerating over it would rewrite who cooked yesterday.
func generate(from_day: int, roster_ids: Array, skills: NpcSkills,
		labour: NpcLabourLog, days: int = HORIZON_DAYS) -> int:
	# Drop stale plans for days we are about to re-plan, and anything before
	# the window that never got minted.
	for i in range(slots.size() - 1, -1, -1):
		var sd: Dictionary = slots[i]
		if str(sd.get("state", "planned")) != "planned":
			continue
		if int(sd.get("day", -1)) >= from_day or int(sd.get("day", -1)) < from_day - 30:
			slots.remove_at(i)
	var made := 0
	# Hours accrue as we plan, so two duties on the same day do not both pick
	# the same person just because they were level when the day began.
	var planned_h: Dictionary = {}
	for offset in days:
		var day := from_day + offset
		for d in duties:
			var duty: Dictionary = d
			if not duty_falls_on(duty, day):
				continue
			if not slot_for(day, str(duty.get("duty_id", ""))).is_empty():
				continue
			var pool := skills.qualified_pool(
				str(duty.get("requires_skill", "")), roster_ids) \
				if skills != null else roster_ids.duplicate()
			var crew := _pick_crew(pool, int(duty.get("crew", 1)), labour,
				str(duty.get("duty_id", "")), day, planned_h)
			for a in crew:
				planned_h[str(a)] = float(planned_h.get(str(a), 0.0)) \
					+ float(duty.get("chore_hours", 1.0)) / maxf(float(crew.size()), 1.0)
			slots.append({
				"day": day, "duty_id": str(duty.get("duty_id", "")),
				"agents": crew, "chore_id": "", "state": "planned",
			})
			made += 1
	slots.sort_custom(func(a, b) -> bool:
		if int((a as Dictionary).get("day", 0)) != int((b as Dictionary).get("day", 0)):
			return int((a as Dictionary).get("day", 0)) < int((b as Dictionary).get("day", 0))
		return str((a as Dictionary).get("duty_id", "")) \
			< str((b as Dictionary).get("duty_id", "")))
	return made


## Least-worked-first over the qualified pool.
##
## Provably converges: whoever is behind is picked, which raises their total,
## which puts somebody else at the bottom. Deterministic — ties break on a hash
## of (agent, duty, day), never on Array order and never on a RNG.
##
## An id-sorted tiebreak is the tempting version and it is WRONG: on day one
## everybody is at 0.0 h, so it puts the same two people on every duty forever
## — which is the bias this whole class exists to remove.
static func _pick_crew(pool: Array, n: int, labour: NpcLabourLog,
		duty_id: String, day: int, planned_h: Dictionary = {}) -> Array:
	if pool.is_empty():
		return []
	var ranked: Array = pool.duplicate()
	var salt := "%s|%d" % [duty_id, day]
	ranked.sort_custom(func(a, b) -> bool:
		var ha := (labour.total_hours(str(a)) if labour != null else 0.0) \
			+ float(planned_h.get(str(a), 0.0))
		var hb := (labour.total_hours(str(b)) if labour != null else 0.0) \
			+ float(planned_h.get(str(b), 0.0))
		if absf(ha - hb) > 0.01:
			return ha < hb
		return NpcHash.unit01(str(a), salt) < NpcHash.unit01(str(b), salt))
	return ranked.slice(0, mini(maxi(n, 1), ranked.size()))


## Put today's slots on the board and name their people.
##
## Idempotent by `chore_key "duty|<duty_id>|<day>"`, with the SAME double
## existence check `_service_machine_chores` uses and for the same reason:
## `deserialize` renumbers chore ids, so a remembered id misses after a load
## and the minter would create a duplicate every tick.
##
## Returns the chore ids created.
func mint_day(board: NpcChoreBoard, day: int, abs_hours: float,
		roster_ids: Array, skills: NpcSkills, labour: NpcLabourLog,
		log_ref = null) -> Array:
	if board == null:
		return []
	var made: Array = []
	for s in slots:
		var slot: Dictionary = s
		if int(slot.get("day", -1)) != day:
			continue
		if str(slot.get("state", "planned")) != "planned":
			continue
		var duty := find_duty(str(slot.get("duty_id", "")))
		if duty.is_empty():
			continue
		var key := "duty|%s|%d" % [str(slot.get("duty_id", "")), day]
		if not board.find_by_key(key).is_empty():
			slot["state"] = "minted"
			continue
		var cid := str(slot.get("chore_id", ""))
		if not cid.is_empty() and not board.find(cid).is_empty():
			slot["state"] = "minted"
			continue
		# Re-pick against the LIVE roster: somebody planned three days ago may
		# have left since, and _pick_crew only ever sees ids that are here.
		var planned: Array = slot.get("agents", []) as Array
		var live: Dictionary = {}
		for a in roster_ids:
			live[str(a)] = true
		var missing: Array = []
		for a in planned:
			if not live.has(str(a)):
				missing.append(str(a))
		if not missing.is_empty():
			var pool := skills.qualified_pool(
				str(duty.get("requires_skill", "")), roster_ids) \
				if skills != null else roster_ids.duplicate()
			planned = _pick_crew(pool, int(duty.get("crew", 1)), labour,
				str(duty.get("duty_id", "")), day)
			slot["agents"] = planned
			if log_ref != null and not planned.is_empty():
				# NOTE, not ALERT: a covered shift is the system working.
				log_ref.add("duty_sub",
					"%s was down for %s but has left — %s takes it" % [
						str(missing[0]), str(duty.get("label", "the job")),
						str(planned[0])],
					abs_hours, SettlementLog.NOTE, str(slot.get("duty_id", "")))
		if planned.is_empty():
			continue
		# One chore for the whole slot, crewed by the named people. The FIRST
		# name owns the assignment (the board's assigned_to is a single id);
		# the rest reach it through the crew cap once the hold lapses, which is
		# the same path a substitute takes.
		# ⚠ "once", NEVER "daily": each slot is one day's instance and tomorrow
		# gets its own mint under its own key. A repeating mint re-arms the next
		# day ALONGSIDE the fresh one — measured as one extra duplicate of every
		# duty per day, compounding. Yesterday's done/missed instances are
		# retired by NpcOnCall.sweep_stale.
		var new_id := board.add_chore(str(duty.get("label", "Duty")),
			float(duty.get("chore_hours", 1.0)), {
				"window": duty.get("window", {"start_h": 11.0, "end_h": 14.0}),
				"repeat": "once",
				"exposure": str(duty.get("exposure", NpcWeatherGate.EXPOSURE_SHELTERED)),
				"priority": int(duty.get("priority", 10)),
				"min_workers": 1,
				"max_workers": maxi(planned.size(), 1),
				"assigned_to": str(planned[0]),
				"assign_at_h": abs_hours,
				"assign_hold_h": ASSIGN_HOLD_H,
				"requires_skill": str(duty.get("requires_skill", "")),
				"target": duty.get("target", {}),
				"chore_key": key,
			})
		if new_id.is_empty():
			continue   # board full; try again tomorrow rather than half-minting
		# assign_at_h / assign_hold_h are not add_chore parameters — they are
		# free-form record keys, so stamp them after.
		var rec := board.find(new_id)
		rec["assign_at_h"] = abs_hours
		rec["assign_hold_h"] = ASSIGN_HOLD_H
		rec["duty_crew"] = planned.duplicate()
		slot["chore_id"] = new_id
		slot["state"] = "minted"
		made.append(new_id)
	return made


## Mark yesterday's minted slots done, so the calendar can dim them and
## `generate` will not rewrite them.
func settle_day(board: NpcChoreBoard, before_day: int) -> void:
	for s in slots:
		var slot: Dictionary = s
		if int(slot.get("day", -1)) >= before_day:
			continue
		if str(slot.get("state", "")) == "minted":
			slot["state"] = "done"


## Trade two people between (or within) slots.
##
## Refuses a slot that is already done — you cannot un-cook yesterday's dinner
## — and refuses an incoming person who lacks the duty's required skill.
## Returns the affected chore ids so the caller can patch a live assignment.
func swap(day_a: int, duty_a: String, agent_a: String,
		day_b: int, duty_b: String, agent_b: String,
		skills: NpcSkills = null) -> Array:
	var sa := slot_for(day_a, duty_a)
	var sb := slot_for(day_b, duty_b)
	if sa.is_empty() or sb.is_empty():
		return []
	if str(sa.get("state", "")) == "done" or str(sb.get("state", "")) == "done":
		return []
	var la: Array = sa.get("agents", []) as Array
	var lb: Array = sb.get("agents", []) as Array
	var ia := la.find(agent_a)
	var ib := lb.find(agent_b)
	if ia < 0 or ib < 0:
		return []
	if skills != null:
		var need_a := str(find_duty(duty_a).get("requires_skill", ""))
		var need_b := str(find_duty(duty_b).get("requires_skill", ""))
		if not need_a.is_empty() and not skills.has(agent_b, need_a):
			return []
		if not need_b.is_empty() and not skills.has(agent_a, need_b):
			return []
	la[ia] = agent_b
	lb[ib] = agent_a
	var out: Array = []
	for sl in [sa, sb]:
		var cid := str((sl as Dictionary).get("chore_id", ""))
		if not cid.is_empty():
			out.append(cid)
	return out


## Why a proposed trade would be refused, in words — "" when it is allowed.
## The UI calls this BEFORE swap(): swap's return is ambiguous on its own (a
## legal trade between two slots with no minted chores also returns no ids),
## so a refusal has to be named by re-running the same checks, kept in the
## same order as swap() above.
func swap_refusal(day_a: int, duty_a: String, agent_a: String,
		day_b: int, duty_b: String, agent_b: String,
		skills: NpcSkills = null) -> String:
	var sa := slot_for(day_a, duty_a)
	var sb := slot_for(day_b, duty_b)
	if sa.is_empty() or sb.is_empty():
		return "one of the two slots is not on the rota"
	if str(sa.get("state", "")) == "done" or str(sb.get("state", "")) == "done":
		return "a finished shift cannot be traded"
	if not (sa.get("agents", []) as Array).has(agent_a) \
			or not (sb.get("agents", []) as Array).has(agent_b):
		return "one of the two people is no longer on that shift"
	if skills != null:
		var need_a := str(find_duty(duty_a).get("requires_skill", ""))
		var need_b := str(find_duty(duty_b).get("requires_skill", ""))
		if not need_a.is_empty() and not skills.has(agent_b, need_a):
			return "needs someone with the '%s' skill" % need_a
		if not need_b.is_empty() and not skills.has(agent_a, need_b):
			return "needs someone with the '%s' skill" % need_b
	return ""


## Who is on today, in words: "Sam, Ava on Lunch · Seva, Kirby on Dinner".
func today_text(day: int, name_of: Callable = Callable()) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for s in slots:
		var slot: Dictionary = s
		if int(slot.get("day", -1)) != day:
			continue
		var duty := find_duty(str(slot.get("duty_id", "")))
		var names: PackedStringArray = PackedStringArray()
		for a in (slot.get("agents", []) as Array):
			names.append(str(name_of.call(str(a))) if name_of.is_valid() else str(a))
		if names.is_empty():
			continue
		parts.append("%s on %s" % [", ".join(names), str(duty.get("label", "duty"))])
	return " · ".join(parts)


func serialize_duties() -> Dictionary:
	return {"version": VERSION, "duties": duties.duplicate(true)}


func serialize_slots() -> Dictionary:
	return {"version": VERSION, "slots": slots.duplicate(true)}


func load_duties(data: Dictionary) -> void:
	duties = (data.get("duties", []) as Array).duplicate(true)


func load_slots(data: Dictionary) -> void:
	slots = (data.get("slots", []) as Array).duplicate(true)
