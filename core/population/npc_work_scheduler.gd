class_name NpcWorkScheduler
extends RefCounted

## The weekly rota (NPC life pass, Phase 6). Pure and static.
##
## One planner over the RECURRING work a settlement does — duty-roster slots
## and repeating board chores — for a rolling week: who does each, and when
## inside its window. People FOLLOW it (the player's choice): today's part is
## written onto the board as assignments that wait for their crew
## (`assigned_crew`, `assigned_to`, `NpcDutyRoster.ASSIGN_HOLD_H`), and a missed
## shift opens to everyone when the hold lapses — the leftovers and the urgent
## one-offs (projects, machine steps, deploys) stay on the open board.
##
## How a crew is picked, per item, highest priority and scarcest first:
##   - only people who can: AWAKE and in a WORK or FREE block of their OWN day
##     for the whole shift (NpcRoutine.block_at with their key, so a night
##     owl is never put on the 07:00 milking), not in their unavailable hours,
##     under their max hours a day and a week (NpcPersona), not on another
##     shift then, holding the skill when the work needs one and someone does;
##   - cheapest first: hours already worked this week + hours planned, minus
##     a preference credit (affinity x hours x AFFINITY_W), plus a split-shift
##     penalty for a second, separate shift that day;
##   - the start is the window hour where the whole crew is cheapest.
## Then a local search moves single seats to whoever lowers the spread of
## weekly hours (squared deviation) net of preference, until nothing improves.
## Deterministic: no RNG; ties break on NpcHash of (person, item).

const SLOT_H := 0.25
const SLOTS := 96
const START_STEP_H := 0.5
## Preference weight: liking a job (affinity 1) is worth this many hours of
## load per hour worked. Half an hour: someone who loves cooking ends the week
## a little ahead, never far ahead (1.2 let the keen ones run ~40 % over).
const AFFINITY_W := 0.5
## A second, separate shift the same day costs this much (hours of load).
const SPLIT_W := 1.0
## Travel and hand-over buffer kept free round a shift.
const GAP_H := 0.25
const SEARCH_PASSES := 6
## Block kinds a shift may sit in.
## (SOCIAL is not: people in a SOCIAL block never pick up chores.)
const WORKABLE: Array = [NpcRoutine.WORK, NpcRoutine.FREE]

## Work families (NpcPersona.FAMILIES) by words in a job's label.
const FAMILY_WORDS: Dictionary = {
	"cook": ["cook", "meal", "kitchen", "breakfast", "lunch", "dinner", "bake", "food prep"],
	"clean": ["clean", "sweep", "scrub", "toilet", "dishes", "trash", "rubbish", "laundry", "tidy"],
	"garden": ["garden", "water the", "plant", "harvest", "weed", "greenhouse", "compost", "bed", "tend", "crop"],
	"build": ["build", "assemble", "raise", "frame", "construct", "erect", "deploy", "rack", "dome"],
	"haul": ["haul", "carry", "unload", "load", "deliver", "fetch", "fuel", "water run"],
	"machines": ["machine", "print", "reactor", "pump", "repair", "maintain", "generator", "engine", "battery"],
	"care": ["care", "first aid", "child", "kids", "medic", "check on"],
	"admin": ["admin", "plan", "inventory", "count", "ledger", "order", "schedule", "meeting"],
}


## The family a job belongs to ("" = none known).
static func family_of(label: String) -> String:
	var l := label.to_lower()
	for f in FAMILY_WORDS:
		for w in FAMILY_WORDS[f]:
			if l.contains(str(w)):
				return str(f)
	return ""


## Does a recurring board chore come round on `day`? Anchored on its last
## completion (else `today`), as NpcChoreBoard._is_due reads it.
static func chore_falls_on(chore: Dictionary, day: int, today: int) -> bool:
	var done := int(chore.get("done_day", -1))
	match NpcChoreBoard.normalize_repeat(chore.get("repeat", "daily")):
		"daily":
			return day > done
		"every_n":
			if done < 0:
				# Never done: due now, then every n days from today.
				return posmod(day - today, maxi(int(chore.get("repeat_days", 1)), 1)) == 0
			return day > done and posmod(day - done, maxi(int(chore.get("repeat_days", 1)), 1)) == 0
		"weekly":
			if day <= done:
				return false
			var dow: Array = chore.get("repeat_dow", []) as Array
			if dow.is_empty():
				return posmod(day - (done if done >= 0 else today), 7) == 0
			return dow.has(NpcChoreBoard.weekday_of_day(day))
	return false


## The week's recurring demand from `day0` for `days` days.
## Items: {key, kind "duty"|"chore", ref, label, family, day, hours, crew,
##   window {start_h, end_h}, skill, priority}.
static func collect(board: NpcChoreBoard, duty: NpcDutyRoster, day0: int, days: int) -> Array:
	var out: Array = []
	for offset in days:
		var day := day0 + offset
		if duty != null:
			for d in duty.duties:
				var dd: Dictionary = d
				if not NpcDutyRoster.duty_falls_on(dd, day):
					continue
				var slot := duty.slot_for(day, str(dd.get("duty_id", "")))
				if not slot.is_empty() and str(slot.get("state", "planned")) != "planned":
					continue   # minted or done: history, never re-planned
				out.append({
					"key": "duty|%s|%d" % [str(dd["duty_id"]), day], "kind": "duty",
					"ref": str(dd["duty_id"]), "label": str(dd.get("label", "")),
					"family": family_of(str(dd.get("label", ""))), "day": day,
					"hours": float(dd.get("chore_hours", 1.0)), "crew": maxi(int(dd.get("crew", 1)), 1),
					"window": dd.get("window", {"start_h": 11.0, "end_h": 14.0}),
					"skill": str(dd.get("requires_skill", "")), "priority": int(dd.get("priority", 10)),
				})
		if board != null:
			for c in board.chores:
				var ch: Dictionary = c
				if bool(ch.get("held", false)):
					continue
				var key0 := str(ch.get("chore_key", ""))
				if key0.begins_with("duty|") or key0.begins_with("mach|"):
					continue
				var rep := NpcChoreBoard.normalize_repeat(ch.get("repeat", "daily"))
				if rep == "once" or rep == "on_demand":
					continue
				# The player's own assignment stands; the rota's own is redone.
				if not str(ch.get("assigned_to", "")).is_empty() and not ch.has("rota_day"):
					continue
				if not chore_falls_on(ch, day, day0):
					continue
				out.append({
					"key": "chore|%s|%d" % [str(ch["id"]), day], "kind": "chore",
					"ref": str(ch["id"]), "label": str(ch.get("label", "")),
					"family": family_of(str(ch.get("label", ""))), "day": day,
					"hours": float(ch.get("chore_hours", 1.0)),
					"crew": maxi(int(ch.get("max_workers", 1)), 1),
					"min_crew": maxi(int(ch.get("min_workers", 1)), 1),
					"window": ch.get("window", {"start_h": 8.0, "end_h": 18.0}),
					"skill": str(ch.get("requires_skill", "")), "priority": int(ch.get("priority", 50)),
				})
	return out


## When each person can work: per person, per day, SLOTS flags (1 = free to
## work in that quarter hour). `people`: [{id, offset_h, persona, skills}].
static func availability(people: Array, routine: NpcRoutine, day0: int, days: int) -> Dictionary:
	var out := {}
	for p in people:
		var pid := str(p["id"])
		var off := float(p.get("offset_h", 0.0))
		var persona: Dictionary = p.get("persona", {})
		var per_day := {}
		var has_unavail := not (persona.get("unavailable", []) as Array).is_empty()
		var roll := routine.roll_h() if routine != null else 0.0
		for offset in days:
			var day := day0 + offset
			var flags := PackedByteArray()
			flags.resize(SLOTS)
			var wd := NpcChoreBoard.weekday_of_day(day)
			# The routine day rolls once inside a calendar day: two keys, each
			# formatted once (block_at per slot formatted one per quarter hour).
			var keys := {}
			for k in SLOTS:
				var h := (float(k) + 0.5) * SLOT_H
				var ok := true
				if routine != null:
					var abs_h := float(day) * 24.0 + h
					var di := int(floor((abs_h - off - roll) / 24.0))
					if not keys.has(di):
						var key := "%s|%d" % [pid, di]
						keys[di] = _starts_of(routine.personal_blocks(key), off + NpcRoutine.day_shift(key))
					ok = _workable_at(keys[di], h)
				if ok and has_unavail and NpcPersona.is_unavailable(persona, wd, h):
					ok = false
				flags[k] = 1 if ok else 0
			per_day[day] = flags
		out[pid] = per_day
	return out


## A personal day as sorted [start hour (clock time, shifted), workable] —
## the blocks tile the day, so the block at h is the last start <= h.
static func _starts_of(blocks: Array, shift: float) -> Array:
	var out: Array = []
	for b in blocks:
		var bd: Dictionary = b
		if is_equal_approx(float(bd.get("start_h", 0.0)), float(bd.get("end_h", 0.0))):
			continue
		out.append([fposmod(float(bd.get("start_h", 0.0)) + shift, 24.0),
			WORKABLE.has(str(bd.get("kind", NpcRoutine.FREE)))])
	out.sort_custom(func(a, b) -> bool: return float(a[0]) < float(b[0]))
	return out


static func _workable_at(starts: Array, h: float) -> bool:
	if starts.is_empty():
		return true
	var best: Array = starts[starts.size() - 1]   # before the first start: the wrapping one
	for e in starts:
		if float(e[0]) <= h:
			best = e
		else:
			break
	return bool(best[1])


## Plan the week. `people`: [{id, offset_h, persona, skills: {tag: true},
## worked_h}]. Returns {shifts: {key: {agents, start_h, end_h, day}},
## planned_h: {id: h}, unassigned: [key]}.
static func plan(items: Array, people: Array, routine: NpcRoutine, day0: int, days: int) -> Dictionary:
	var avail := availability(people, routine, day0, days)
	var by_id := {}
	var load := {}
	var skill_supply := {}
	for p in people:
		by_id[str(p["id"])] = p
		load[str(p["id"])] = float(p.get("worked_h", 0.0))
		for t in (p.get("skills", {}) as Dictionary):
			skill_supply[str(t)] = true
	var busy := {}       # id -> [Vector3(day, start, end)]
	var day_h := {}      # id -> {day: hours}
	var week_h := {}     # id -> planned hours
	var shifts := {}
	var unassigned: Array = []
	# Scarcest first within a priority: count who could do it at all.
	var order: Array = items.duplicate()
	var cand_n := {}
	for it in order:
		var n := 0
		for p in people:
			if _qualified(it, p, skill_supply):
				n += 1
		cand_n[str(it["key"])] = n
	# Day first: only today's part is ever applied, and it is redone tomorrow.
	# Scarcity across the week first let next week's scarce jobs fill the
	# least-worked person's plan, so they looked busy when today's work was
	# handed out — and again tomorrow, for ever (they stood idle in WORK
	# blocks while the plan "gave" them 9 h).
	order.sort_custom(func(a, b) -> bool:
		if int(a["day"]) != int(b["day"]):
			return int(a["day"]) < int(b["day"])
		if int(a["priority"]) != int(b["priority"]):
			return int(a["priority"]) < int(b["priority"])
		var ca := float(cand_n[str(a["key"])]) / float(maxi(int(a["crew"]), 1))
		var cb := float(cand_n[str(b["key"])]) / float(maxi(int(b["crew"]), 1))
		if absf(ca - cb) > 1e-6:
			return ca < cb
		return str(a["key"]) < str(b["key"]))
	for it in order:
		var crew_n := maxi(int(it["crew"]), 1)
		var min_n := clampi(int(it.get("min_crew", crew_n)), 1, crew_n)
		var dur := float(it["hours"]) / float(crew_n)
		var w: Dictionary = it["window"]
		var ws := float(w.get("start_h", 0.0))
		var we := float(w.get("end_h", 24.0))
		if we <= ws:
			we += 24.0
		var best_cost := INF
		var best_crew: Array = []
		var best_start := ws
		var start := ws
		# About nine candidate starts at most, whatever the window.
		var step := maxf(START_STEP_H, snappedf((we - ws - dur) / 8.0, START_STEP_H))
		# Tie-breaks, once per item (everyone level is the common case).
		var tie := {}
		var quals: Array = []
		for p in people:
			if _qualified(it, p, skill_supply):
				quals.append(p)
				tie[str(p["id"])] = NpcHash.unit01(str(p["id"]), str(it["key"]))
		while start + dur <= we + 1e-6 or (start == ws):
			# The crew_n cheapest, kept sorted by insertion (n is 1-4).
			var ranked: Array = []
			for p in quals:
				var pid := str(p["id"])
				if not _fits(pid, it, start, dur, avail, busy, day_h, week_h, p):
					continue
				var c0 := _cost(pid, it, start, dur, load, week_h, busy, p)
				var t0 := float(tie[pid])
				var at := ranked.size()
				while at > 0:
					var prev: Array = ranked[at - 1]
					if float(prev[0]) < c0 - 1e-9 or (absf(float(prev[0]) - c0) <= 1e-9 and float(prev[2]) <= t0):
						break
					at -= 1
				if at < crew_n:
					ranked.insert(at, [c0, pid, t0])
					if ranked.size() > crew_n:
						ranked.pop_back()
			var n := mini(crew_n, ranked.size())
			if n >= min_n and n < crew_n:
				# Short-handed: each works a bigger share — check that fits too.
				var d_short := float(it["hours"]) / float(n)
				for k in n:
					if not _fits(str(ranked[k][1]), it, start, d_short, avail, busy, day_h, week_h, by_id[str(ranked[k][1])]):
						n = -1
						break
			if n >= min_n:
				var c := 0.0
				var crew: Array = []
				for k in n:
					c += float(ranked[k][0])
					crew.append(str(ranked[k][1]))
				c /= float(n)
				c += float(crew_n - n) * 2.0   # short-handed costs
				if c < best_cost - 1e-9:
					best_cost = c
					best_crew = crew
					best_start = start
			start += step
			if dur <= 0.0 or start > we:
				break
		if best_crew.is_empty():
			unassigned.append(str(it["key"]))
			continue
		var d := float(it["hours"]) / float(best_crew.size())
		for pid in best_crew:
			_book(str(pid), it, best_start, d, busy, day_h, week_h)
		shifts[str(it["key"])] = {"agents": best_crew, "start_h": fposmod(best_start, 24.0),
			"end_h": fposmod(best_start + d, 24.0), "day": int(it["day"]), "hours": d,
			"label": str(it["label"]), "family": str(it["family"]), "kind": str(it["kind"]),
			"ref": str(it["ref"])}
	_improve(items, shifts, people, by_id, avail, busy, day_h, week_h, load, skill_supply)
	return {"shifts": shifts, "planned_h": week_h, "unassigned": unassigned}


static func _qualified(it: Dictionary, p: Dictionary, skill_supply: Dictionary) -> bool:
	var sk := str(it.get("skill", ""))
	if sk.is_empty() or not skill_supply.has(sk):
		return true   # nobody has it: anyone may (the board's rule)
	return bool((p.get("skills", {}) as Dictionary).get(sk, false))


static func _fits(pid: String, it: Dictionary, start: float, dur: float, avail: Dictionary,
		busy: Dictionary, day_h: Dictionary, week_h: Dictionary, p: Dictionary,
		ignore: Variant = null) -> bool:
	var day := int(it["day"])
	var persona: Dictionary = p.get("persona", {})
	var mine: Dictionary = day_h.get(pid, {})
	if float(mine.get(day, 0.0)) + dur > float(persona.get("max_h_day", 24.0)) + 1e-6:
		return false
	if float(week_h.get(pid, 0.0)) + dur > float(persona.get("max_h_week", 168.0)) + 1e-6:
		return false
	var flags_by_day: Dictionary = avail.get(pid, {})
	var k0 := int(floor(start / SLOT_H + 1e-6))
	var k1 := int(ceil((start + dur) / SLOT_H - 1e-6))
	for k in range(k0, maxi(k1, k0 + 1)):
		var dd := day + int(floor(float(k) / float(SLOTS)))
		var flags: PackedByteArray = flags_by_day.get(dd, PackedByteArray())
		if flags.is_empty() or flags[posmod(k, SLOTS)] == 0:
			return false
	var s := float(day) * 24.0 + start
	var e := s + dur
	for b in busy.get(pid, []):
		var bv: Vector3 = b
		if ignore is Vector3 and bv.is_equal_approx(ignore):
			continue
		var bs := bv.x * 24.0 + bv.y
		var be := bv.x * 24.0 + bv.z
		if s < be + GAP_H and e > bs - GAP_H:
			return false
	return true


static func _cost(pid: String, it: Dictionary, start: float, dur: float, load: Dictionary,
		week_h: Dictionary, busy: Dictionary, p: Dictionary) -> float:
	var c := float(load.get(pid, 0.0)) + float(week_h.get(pid, 0.0)) + dur
	var fam := str(it.get("family", ""))
	if not fam.is_empty():
		c -= AFFINITY_W * dur * NpcPersona.affinity(p.get("persona", {}), fam)
	var day := int(it["day"])
	for b in busy.get(pid, []):
		var bv: Vector3 = b
		if int(bv.x) != day:
			continue
		# A separate shift the same day (not back to back) is a split day.
		if absf(start - bv.z) > GAP_H + 0.26 and absf(start + dur - bv.y) > GAP_H + 0.26:
			c += SPLIT_W
	return c


static func _book(pid: String, it: Dictionary, start: float, dur: float, busy: Dictionary,
		day_h: Dictionary, week_h: Dictionary) -> void:
	var day := int(it["day"])
	if not busy.has(pid):
		busy[pid] = []
	(busy[pid] as Array).append(Vector3(day, start, start + dur))
	if not day_h.has(pid):
		day_h[pid] = {}
	day_h[pid][day] = float((day_h[pid] as Dictionary).get(day, 0.0)) + dur
	week_h[pid] = float(week_h.get(pid, 0.0)) + dur


static func _unbook(pid: String, it: Dictionary, start: float, dur: float, busy: Dictionary,
		day_h: Dictionary, week_h: Dictionary) -> void:
	var day := int(it["day"])
	var arr: Array = busy.get(pid, [])
	for i in arr.size():
		if (arr[i] as Vector3).is_equal_approx(Vector3(day, start, start + dur)):
			arr.remove_at(i)
			break
	if day_h.has(pid):
		day_h[pid][day] = float((day_h[pid] as Dictionary).get(day, 0.0)) - dur
	week_h[pid] = float(week_h.get(pid, 0.0)) - dur


## Move single seats to whoever lowers the spread of total hours, net of
## preference, until a pass changes nothing.
static func _improve(items: Array, shifts: Dictionary, people: Array, by_id: Dictionary,
		avail: Dictionary, busy: Dictionary, day_h: Dictionary, week_h: Dictionary,
		load: Dictionary, skill_supply: Dictionary) -> void:
	var item_of := {}
	for it in items:
		item_of[str(it["key"])] = it
	var keys: Array = shifts.keys()
	keys.sort()
	for _pass in SEARCH_PASSES:
		var moved := false
		for key in keys:
			var sh: Dictionary = shifts[key]
			var it: Dictionary = item_of[key]
			var crew: Array = sh["agents"]
			var d := float(sh["hours"])
			var start := float(it["window"].get("start_h", 0.0))
			# The booked start (window-relative, never wrapped).
			start = _booked_start(it, sh)
			for ci in crew.size():
				var a := str(crew[ci])
				var la := float(load.get(a, 0.0)) + float(week_h.get(a, 0.0))
				var aff_a := NpcPersona.affinity(by_id[a].get("persona", {}), str(it["family"]))
				var best_b := ""
				var best_delta := -1e-6
				for p in people:
					var b := str(p["id"])
					if crew.has(b):
						continue
					# The cheap score first: most people cannot improve it.
					var lb := float(load.get(b, 0.0)) + float(week_h.get(b, 0.0))
					var aff_b := NpcPersona.affinity(p.get("persona", {}), str(it["family"]))
					var delta := 2.0 * d * (lb - la + d) \
						+ 2.0 * AFFINITY_W * d * (aff_a - aff_b)
					if delta >= best_delta:
						continue
					if not _qualified(it, p, skill_supply):
						continue
					if not _fits(b, it, start, d, avail, busy, day_h, week_h, p):
						continue
					best_delta = delta
					best_b = b
				if best_b != "":
					_unbook(a, it, start, d, busy, day_h, week_h)
					_book(best_b, it, start, d, busy, day_h, week_h)
					crew[ci] = best_b
					moved = true
		if not moved:
			break


static func _booked_start(it: Dictionary, sh: Dictionary) -> float:
	var ws := float((it["window"] as Dictionary).get("start_h", 0.0))
	var s := float(sh["start_h"])
	if s < ws - 1e-6:
		s += 24.0   # the window wraps midnight and the shift is after it
	return s


## The people the engine plans for; `worked_h` = the last six days' work
## (NpcLabourLog), so the plan evens out across weeks, not only inside one.
static func people_of(engine, today: int) -> Array:
	var out: Array = []
	var r: NpcRoutine = engine.routine
	for a in engine.agents:
		var ag: NpcAgent = a
		if ag.controlled_by_peer != 0:
			continue   # a player is living this person's day
		out.append({
			"id": ag.id, "offset_h": ag.routine_offset_h,
			"persona": r.persona_of(ag.id) if r != null else NpcPersona.for_id(ag.id),
			"skills": engine.skills.tags_of(ag.id) if engine.skills != null else {},
			"worked_h": engine.labour.hours_between(ag.id, today - 6, today - 1)
				if engine.labour != null else 0.0,
		})
	return out


## Write the plan onto the duty slots (every planned day) and today's
## recurring chores (who, and from when). Returns how many chores it named.
static func apply(rota: Dictionary, board: NpcChoreBoard, duty: NpcDutyRoster, today: int) -> int:
	var shifts: Dictionary = rota.get("shifts", {})
	if duty != null:
		for s in duty.slots:
			var slot: Dictionary = s
			if str(slot.get("state", "planned")) != "planned":
				continue
			var sh: Dictionary = shifts.get("duty|%s|%d" % [str(slot.get("duty_id", "")), int(slot.get("day", -1))], {})
			if sh.is_empty():
				continue
			slot["agents"] = (sh["agents"] as Array).duplicate()
			slot["start_h"] = float(sh["start_h"])
	if board == null:
		return 0
	# Yesterday's rota names expire: the plan is redone every day.
	for c in board.chores:
		var ch: Dictionary = c
		if ch.has("rota_day") and int(ch["rota_day"]) != today:
			ch["assigned_to"] = ""
			for k in ["assigned_crew", "assign_at_h", "assign_hold_h", "rota_day", "rota_worked"]:
				ch.erase(k)
	var named := 0
	for key in shifts:
		var sh: Dictionary = shifts[key]
		if str(sh.get("kind", "")) != "chore" or int(sh.get("day", -1)) != today:
			continue
		var ch := board.find(str(sh["ref"]))
		if ch.is_empty() or int(ch.get("done_day", -1)) >= today:
			continue
		if not (ch.get("workers", []) as Array).is_empty():
			continue   # already under way: leave whoever is on it
		var crew: Array = sh["agents"]
		ch["assigned_to"] = str(crew[0])
		ch["assigned_crew"] = crew.duplicate()
		var w: Dictionary = ch.get("window", {})
		var start := float(sh["start_h"])
		if start < float(w.get("start_h", 0.0)) - 1e-6:
			start += 24.0
		ch["assign_at_h"] = float(today) * 24.0 + start
		ch["assign_hold_h"] = NpcDutyRoster.ASSIGN_HOLD_H
		ch["rota_day"] = today
		ch.erase("rota_worked")
		named += 1
	board._rev += 1
	return named
